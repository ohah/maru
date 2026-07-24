//! Host lifetime 동안 exact old executable을 rollback 권위로 보존하고 성공 target으로 원자 회전한다.

const std = @import("std");
const staged_image = @import("staged_image.zig");
const attempt_record = @import("upgrade_attempt_record.zig");
const host_manifest = @import("host_manifest.zig");

pub const current_leaf = "rollback-current";
const previous_residue_leaf = "rollback-previous";

pub const Authority = struct {
    image: staged_image.StagedImage,
    displaced: ?staged_image.StagedImage = null,
    valid: bool = true,

    pub fn prepare(
        allocator: std.mem.Allocator,
        executable_path: [:0]const u8,
        expected_running_identity: staged_image.Identity,
        owner_dir: [:0]const u8,
    ) staged_image.Error!Authority {
        const source = try staged_image.inspect(executable_path);
        if (!staged_image.identityEqual(source, expected_running_identity))
            return error.HashMismatch;
        var image = try staged_image.stage(
            allocator,
            executable_path,
            owner_dir,
            current_leaf,
        );
        errdefer image.deinit();
        if (image.identity.size != expected_running_identity.size or
            !std.mem.eql(u8, &image.identity.sha256, &expected_running_identity.sha256))
            return error.HashMismatch;
        return .{ .image = image };
    }

    pub fn deinit(self: *Authority) void {
        if (self.displaced) |*image| image.deinit();
        self.image.deinit();
        self.* = undefined;
    }

    /// Borrowed view: path backing은 `Authority.deinit` 전까지만 유효하다. Promote 뒤에도 path
    /// pointer는 살아 있지만 identity snapshot은 더는 current authority를 뜻하지 않을 수 있다.
    /// 저장하거나 비동기 callback에 넘길 caller는 attempt record bytes로 encode해 ownership을 끊는다.
    pub fn record(self: *const Authority) attempt_record.ImageView {
        std.debug.assert(self.valid);
        return .{
            .path = self.image.path,
            .sha256 = self.image.identity.sha256,
            .dev = self.image.identity.dev,
            .ino = self.image.identity.ino,
            .size = self.image.identity.size,
        };
    }

    pub fn revalidate(self: *const Authority) bool {
        return self.valid and validateRecord(self.record());
    }

    pub const PromotionOutcome = enum {
        promoted,
        unchanged_failure,
        promoted_needs_poison,
        indeterminate,
    };

    /// Target authority commit 뒤에만 호출한다. `promoted_needs_poison`은 swap은 끝났지만 cleanup/durability 단계가
    /// 실패한 상태라 current identity는 새 target으로 reconcile하되 다음 upgrade capability를 철회해야 한다.
    pub fn promoteTarget(
        self: *Authority,
        owner_dir: [:0]const u8,
        target_path: [:0]const u8,
        target_identity: staged_image.Identity,
        failpoint: staged_image.PromotionFailpoint,
    ) PromotionOutcome {
        if (!self.valid or self.displaced != null) return .indeterminate;
        const previous_identity = self.image.identity;
        // Swap 뒤 실패해도 target leaf로 밀려난 old current의 cleanup owner를 잃지 않도록
        // destructive rename 전에 독립 path ownership을 확보한다.
        const displaced_path = self.image.allocator.dupeZ(u8, target_path) catch
            return .unchanged_failure;
        var displaced_path_owned = true;
        defer if (displaced_path_owned) self.image.allocator.free(displaced_path);
        const previous = std.fmt.allocPrintSentinel(
            self.image.allocator,
            "{s}/{s}",
            .{ owner_dir, previous_residue_leaf },
            0,
        ) catch return .unchanged_failure;
        defer self.image.allocator.free(previous);
        staged_image.promote(
            owner_dir,
            target_path,
            target_identity,
            self.image.path,
            previous,
            failpoint,
        ) catch {
            const current = staged_image.inspect(self.image.path) catch {
                self.valid = false;
                return .indeterminate;
            };
            if (staged_image.identityEqual(current, target_identity)) {
                self.image.identity = target_identity;
                // Later failure may happen before or after `promote` unlinks this leaf.
                // Exact dev/ino cleanup is harmless when it is already absent and refuses
                // to remove any replacement object, so Authority keeps the handle either way.
                self.displaced = .{
                    .allocator = self.image.allocator,
                    .path = displaced_path,
                    .identity = previous_identity,
                };
                displaced_path_owned = false;
                return .promoted_needs_poison;
            }
            if (staged_image.identityEqual(current, previous_identity))
                return .unchanged_failure;
            self.valid = false;
            return .indeterminate;
        };
        self.image.identity = target_identity;
        return .promoted;
    }
};

pub fn validateRecord(record: attempt_record.ImageView) bool {
    var path_buf: [@import("upgrade_limits.zig").max_target_path_bytes + 1]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}", .{record.path}) catch return false;
    const actual = staged_image.inspect(path) catch return false;
    return staged_image.identityEqual(.{
        .dev = record.dev,
        .ino = record.ino,
        .size = record.size,
        .sha256 = record.sha256,
    }, actual);
}

pub fn validateCanonicalRecord(
    record: attempt_record.ImageView,
    session_dir: []const u8,
    host_id: u128,
) bool {
    var host_dir_buf: [768]u8 = undefined;
    const host_dir = host_manifest.hostDirPathIn(&host_dir_buf, session_dir, host_id) catch return false;
    var expected_buf: [@import("upgrade_limits.zig").max_target_path_bytes + 1]u8 = undefined;
    const expected = std.fmt.bufPrintZ(&expected_buf, "{s}/{s}", .{ host_dir, current_leaf }) catch
        return false;
    return std.mem.eql(u8, record.path, expected) and validateRecord(record);
}

test "rollback image pins expected executable and reconciles post-swap failure" {
    const c = std.c;
    var dir_buf: [192]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(
        &dir_buf,
        "/tmp/maru-rollback-image-{d}-{d}",
        .{ c.getpid(), std.Io.Clock.awake.now(std.testing.io).nanoseconds },
    );
    if (c.mkdir(dir.ptr, 0o700) != 0) return error.TestUnexpectedResult;
    defer _ = c.rmdir(dir.ptr);
    var old_buf: [256]u8 = undefined;
    const old = try std.fmt.bufPrintZ(&old_buf, "{s}/old", .{dir});
    var target_buf: [256]u8 = undefined;
    const target = try std.fmt.bufPrintZ(&target_buf, "{s}/target", .{dir});
    try writeFixture(old, "old-image");
    try writeFixture(target, "new-image");
    defer _ = c.unlink(old.ptr);
    defer _ = c.unlink(target.ptr);

    const running_identity = try staged_image.inspect(old);
    var wrong_identity = running_identity;
    wrong_identity.sha256[0] ^= 1;
    try std.testing.expectError(
        error.HashMismatch,
        Authority.prepare(std.testing.allocator, old, wrong_identity, dir),
    );
    var authority = try Authority.prepare(std.testing.allocator, old, running_identity, dir);
    var authority_open = true;
    defer if (authority_open) authority.deinit();
    const old_record = authority.record();
    try std.testing.expect(authority.revalidate());
    var staged = try staged_image.stageExclusive(std.testing.allocator, target, dir, "attempt-target");
    defer staged.deinit();
    const target_path = staged.path;
    try std.testing.expectEqual(
        Authority.PromotionOutcome.unchanged_failure,
        authority.promoteTarget(dir, target_path, try staged_image.inspect(target_path), .before_swap),
    );
    try std.testing.expect(validateRecord(old_record));
    const target_identity = try staged_image.inspect(target_path);
    try std.testing.expectEqual(
        Authority.PromotionOutcome.promoted_needs_poison,
        authority.promoteTarget(dir, target_path, target_identity, .after_swap),
    );
    try std.testing.expect(authority.revalidate());
    try std.testing.expect(!validateRecord(old_record));
    authority.deinit();
    authority_open = false;
    try std.testing.expectError(error.OpenFailed, staged_image.inspect(target_path));
}

fn writeFixture(path: [:0]const u8, bytes: []const u8) !void {
    const c = std.c;
    const posix = std.posix;
    const fd = c.open(
        path.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o700),
    );
    if (fd < 0) return error.WriteFailed;
    defer _ = c.close(fd);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (count < 0) {
            if (posix.errno(count) == .INTR) continue;
            return error.WriteFailed;
        }
        if (count == 0) return error.WriteFailed;
        offset += @intCast(count);
    }
    if (c.fsync(fd) != 0) return error.WriteFailed;
}
