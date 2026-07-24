//! Upgrade target/rollback self-image를 owner-only directory에 고정하는 파일 원자성 경계.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const limits = @import("upgrade_limits.zig");
extern "c" fn renamex_np(from: [*:0]const u8, to: [*:0]const u8, flags: c_uint) c_int;
const rename_swap: c_uint = 0x00000002;
const rename_excl: c_uint = 0x00000004;
pub const max_staged_image_bytes = limits.max_staged_image_bytes;

pub const Error = error{
    InvalidDirectory,
    InvalidName,
    InvalidSource,
    OpenFailed,
    ReadFailed,
    WriteFailed,
    SyncFailed,
    RenameFailed,
    HashMismatch,
    StorageUnavailable,
    InjectedPromotionFailure,
    OutOfMemory,
};

pub const Identity = struct {
    dev: i64,
    ino: u64,
    size: u64,
    sha256: [32]u8,
};

pub const StagedImage = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    identity: Identity,

    pub fn deinit(self: *StagedImage) void {
        removeOwnedExact(self.path, self.identity.dev, self.identity.ino);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

pub const PromotionFailpoint = enum {
    none,
    before_swap,
    mutate_staged_after_inspect,
};

pub fn stage(
    allocator: std.mem.Allocator,
    source_path: [:0]const u8,
    owner_dir: [:0]const u8,
    final_name: []const u8,
) Error!StagedImage {
    return stageImpl(allocator, source_path, owner_dir, final_name, false, max_staged_image_bytes);
}

/// Upgrade attempt leaf는 idempotency key의 disk identity이므로 기존 leaf를 덮어쓰지 않는다. Rollback image
/// rotation처럼 의도적으로 교체하는 `stage`와 API를 분리해 호출자가 overwrite 의미를 추측하지 않게 한다.
pub fn stageExclusive(
    allocator: std.mem.Allocator,
    source_path: [:0]const u8,
    owner_dir: [:0]const u8,
    final_name: []const u8,
) Error!StagedImage {
    return stageImpl(allocator, source_path, owner_dir, final_name, true, max_staged_image_bytes);
}

fn stageImpl(
    allocator: std.mem.Allocator,
    source_path: [:0]const u8,
    owner_dir: [:0]const u8,
    final_name: []const u8,
    exclusive: bool,
    max_bytes: u64,
) Error!StagedImage {
    try validateLeaf(final_name);
    const dir_fd = try openOwnerDir(owner_dir);
    defer _ = c.close(dir_fd);
    const source_fd = c.open(source_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (source_fd < 0) return error.InvalidSource;
    defer _ = c.close(source_fd);
    const source_size = try validateRegular(source_fd);
    if (source_size > max_bytes) return error.InvalidSource;

    const final_path = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ owner_dir, final_name }, 0) catch return error.OutOfMemory;
    errdefer allocator.free(final_path);
    const tmp_path = std.fmt.allocPrintSentinel(
        allocator,
        "{s}/.{s}.tmp-{d}",
        .{ owner_dir, final_name, c.getpid() },
        0,
    ) catch return error.OutOfMemory;
    defer allocator.free(tmp_path);
    _ = c.unlink(tmp_path.ptr);
    var exclusive_object: ?ObjectIdentity = null;
    errdefer {
        if (exclusive_object) |object| removeOwnedExact(final_path, object.dev, object.ino);
    }

    const out_fd = c.open(
        tmp_path.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o700),
    );
    if (out_fd < 0) return error.StorageUnavailable;
    var out_open = true;
    defer {
        if (out_open) _ = c.close(out_fd);
    }
    errdefer _ = c.unlink(tmp_path.ptr);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read_count = c.read(source_fd, &buffer, buffer.len);
        if (read_count < 0) {
            if (posix.errno(read_count) == .INTR) continue;
            return error.InvalidSource;
        }
        if (read_count == 0) break;
        const chunk = buffer[0..@intCast(read_count)];
        hasher.update(chunk);
        total = std.math.add(u64, total, chunk.len) catch return error.InvalidSource;
        if (total > max_bytes) return error.InvalidSource;
        writeAll(out_fd, chunk) catch return error.StorageUnavailable;
    }
    if (c.fsync(out_fd) != 0) return error.StorageUnavailable;
    const staged_object = try objectForFd(out_fd);
    _ = c.close(out_fd);
    out_open = false;
    if ((if (exclusive)
        renamex_np(tmp_path.ptr, final_path.ptr, rename_excl)
    else
        c.rename(tmp_path.ptr, final_path.ptr)) != 0)
        return error.StorageUnavailable;
    if (exclusive) exclusive_object = staged_object;
    if (c.fsync(dir_fd) != 0) return error.StorageUnavailable;

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const identity = inspect(final_path) catch return error.StorageUnavailable;
    if (identity.size != total or !std.mem.eql(u8, &identity.sha256, &digest)) return error.StorageUnavailable;
    exclusive_object = null;
    return .{ .allocator = allocator, .path = final_path, .identity = identity };
}

pub fn inspect(path: [:0]const u8) Error!Identity {
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    return inspectFd(fd);
}

/// 이미 open된 executable inode를 pathname 재해석 없이 검증한다. `pread`라 caller의 fd offset을 바꾸지 않으며,
/// target executor가 보유한 pinned fd와 같은 object를 hash할 수 있다.
pub fn inspectFd(fd: c.fd_t) Error!Identity {
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or
        stat.mode & 0o022 != 0 or stat.mode & 0o111 == 0 or stat.size < 0 or
        @as(u64, @intCast(stat.size)) > max_staged_image_bytes)
        return error.InvalidSource;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read_count = c.pread(fd, &buffer, buffer.len, @intCast(total));
        if (read_count < 0) {
            if (posix.errno(read_count) == .INTR) continue;
            return error.ReadFailed;
        }
        if (read_count == 0) break;
        const chunk = buffer[0..@intCast(read_count)];
        hasher.update(chunk);
        total = std.math.add(u64, total, chunk.len) catch return error.InvalidSource;
        if (total > max_staged_image_bytes) return error.InvalidSource;
    }
    if (total != @as(u64, @intCast(stat.size))) return error.InvalidSource;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{
        .dev = stat.dev,
        .ino = @intCast(stat.ino),
        .size = total,
        .sha256 = digest,
    };
}

/// 성공한 target을 다음 rollback self-image로 회전한다. promotion 전 failpoint는 current를 전혀 바꾸지 않는다.
pub fn promote(
    owner_dir: [:0]const u8,
    staged_path: [:0]const u8,
    expected: Identity,
    current_path: [:0]const u8,
    previous_path: [:0]const u8,
    failpoint: PromotionFailpoint,
) Error!void {
    const dir_fd = try openOwnerDir(owner_dir);
    defer _ = c.close(dir_fd);
    const actual = try inspect(staged_path);
    if (!identityEqual(expected, actual)) return error.HashMismatch;
    const displaced_identity = try inspect(current_path);
    if (failpoint == .before_swap) return error.InjectedPromotionFailure;
    if (failpoint == .mutate_staged_after_inspect) {
        const fd = c.open(staged_path.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0));
        if (fd < 0) return error.OpenFailed;
        defer _ = c.close(fd);
        try writeAll(fd, "mutated-after-inspect");
        if (c.fsync(fd) != 0) return error.SyncFailed;
    }

    // staged와 current 이름을 원자적으로 교환한 뒤 양쪽 inode/hash를 재검증한다. inspect 뒤 staged leaf가
    // 교체됐다면 current에 올라간 객체가 expected와 다르므로 즉시 swap-back하고 capability를 철회한다.
    if (renamex_np(staged_path.ptr, current_path.ptr, rename_swap) != 0) return error.RenameFailed;
    const promoted_identity = inspect(current_path) catch {
        if (renamex_np(staged_path.ptr, current_path.ptr, rename_swap) != 0) return error.RenameFailed;
        return error.HashMismatch;
    };
    const old_current_identity = inspect(staged_path) catch {
        if (renamex_np(staged_path.ptr, current_path.ptr, rename_swap) != 0) return error.RenameFailed;
        return error.HashMismatch;
    };
    if (!identityEqual(expected, promoted_identity) or !identityEqual(displaced_identity, old_current_identity)) {
        if (renamex_np(staged_path.ptr, current_path.ptr, rename_swap) != 0) return error.RenameFailed;
        return error.HashMismatch;
    }
    if (c.fsync(dir_fd) != 0) return error.SyncFailed;
    if (c.unlink(staged_path.ptr) != 0) return error.RenameFailed;
    if (c.fsync(dir_fd) != 0) return error.SyncFailed;
    _ = c.unlink(previous_path.ptr); // 과거 구현 residue만 정리하며 rollback 권위로 쓰지 않는다.
    if (c.fsync(dir_fd) != 0) return error.SyncFailed;
}

pub fn identityEqual(a: Identity, b: Identity) bool {
    return a.dev == b.dev and a.ino == b.ino and a.size == b.size and
        std.mem.eql(u8, &a.sha256, &b.sha256);
}

fn validateLeaf(name: []const u8) Error!void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, 0) != null)
        return error.InvalidName;
}

fn openOwnerDir(path: [:0]const u8) Error!c.fd_t {
    var stat: posix.Stat = undefined;
    if (c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !posix.S.ISDIR(stat.mode) or stat.uid != c.getuid() or stat.mode & 0o077 != 0)
        return error.InvalidDirectory;
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.InvalidDirectory;
    return fd;
}

fn validateRegular(fd: c.fd_t) Error!u64 {
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or
        stat.mode & 0o022 != 0 or stat.mode & 0o111 == 0 or stat.size < 0)
        return error.InvalidSource;
    return @intCast(stat.size);
}

const ObjectIdentity = struct {
    dev: i64,
    ino: u64,
};

fn inspectObject(path: [:0]const u8) Error!ObjectIdentity {
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    return objectForFd(fd);
}

fn objectForFd(fd: c.fd_t) Error!ObjectIdentity {
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid())
        return error.InvalidSource;
    return .{ .dev = stat.dev, .ino = @intCast(stat.ino) };
}

/// Path를 먼저 exclusive tomb으로 옮기고 tomb inode를 대조한다. inspect(path)→unlink(path)처럼 두 syscall 사이
/// replacement generation을 지우지 않으며, content/mode가 손상돼도 우리가 만든 dev/ino면 회수한다.
fn removeOwnedExact(path: [:0]const u8, expected_dev: i64, expected_ino: u64) void {
    var tomb_buf: [2048]u8 = undefined;
    const tomb = std.fmt.bufPrintZ(&tomb_buf, "{s}.delete-{d}", .{ path, c.getpid() }) catch return;
    _ = c.unlink(tomb.ptr);
    if (renamex_np(path.ptr, tomb.ptr, rename_excl) != 0) return;
    const actual = inspectObject(tomb) catch {
        _ = renamex_np(tomb.ptr, path.ptr, rename_excl);
        return;
    };
    if (actual.dev != expected_dev or actual.ino != expected_ino) {
        _ = renamex_np(tomb.ptr, path.ptr, rename_excl);
        return;
    }
    _ = c.unlink(tomb.ptr);
}

fn writeAll(fd: c.fd_t, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (written < 0) {
            if (posix.errno(written) == .INTR) continue;
            return error.WriteFailed;
        }
        if (written == 0) return error.WriteFailed;
        offset += @intCast(written);
    }
}

fn writeFixture(path: [:0]const u8, bytes: []const u8) !void {
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o700));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    try writeAll(fd, bytes);
}

test "staged image copies hashes and atomically rotates two consecutive versions" {
    var dir_buf: [192]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-stage-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    defer _ = c.rmdir(dir.ptr);
    var source_buf: [224]u8 = undefined;
    const source = try std.fmt.bufPrintZ(&source_buf, "{s}/source", .{dir});
    var current_buf: [224]u8 = undefined;
    const current = try std.fmt.bufPrintZ(&current_buf, "{s}/self-current", .{dir});
    var previous_buf: [224]u8 = undefined;
    const previous = try std.fmt.bufPrintZ(&previous_buf, "{s}/self-previous", .{dir});
    defer {
        _ = c.unlink(source.ptr);
        _ = c.unlink(current.ptr);
        _ = c.unlink(previous.ptr);
    }

    try writeFixture(source, "version-old");
    var seed = try stage(std.testing.allocator, source, dir, "self-current");
    defer seed.deinit();
    try writeFixture(source, "version-n");
    var first = try stage(std.testing.allocator, source, dir, "target-n");
    defer first.deinit();
    try promote(dir, first.path, first.identity, current, previous, .none);
    try std.testing.expectEqual(@as(u64, 9), (try inspect(current)).size);

    try writeFixture(source, "version-n-plus-one");
    var second = try stage(std.testing.allocator, source, dir, "target-n-plus-one");
    defer second.deinit();
    try std.testing.expectError(error.InjectedPromotionFailure, promote(dir, second.path, second.identity, current, previous, .before_swap));
    const before = try inspect(current);
    try std.testing.expect(std.mem.eql(u8, &before.sha256, &first.identity.sha256));
    try std.testing.expectError(
        error.HashMismatch,
        promote(dir, second.path, second.identity, current, previous, .mutate_staged_after_inspect),
    );
    const after_race = try inspect(current);
    try std.testing.expect(std.mem.eql(u8, &after_race.sha256, &first.identity.sha256));
    second.deinit();
    try writeFixture(source, "version-n-plus-one");
    second = try stage(std.testing.allocator, source, dir, "target-n-plus-one");
    try promote(dir, second.path, second.identity, current, previous, .none);
    const after = try inspect(current);
    try std.testing.expect(std.mem.eql(u8, &after.sha256, &second.identity.sha256));
}

test "staged image rejects symlink sources and unsafe owner directories" {
    var dir_buf: [192]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-stage-sec-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    defer _ = c.rmdir(dir.ptr);
    var source_buf: [224]u8 = undefined;
    const source = try std.fmt.bufPrintZ(&source_buf, "{s}/source", .{dir});
    var link_buf: [224]u8 = undefined;
    const link = try std.fmt.bufPrintZ(&link_buf, "{s}/link", .{dir});
    defer {
        _ = c.unlink(source.ptr);
        _ = c.unlink(link.ptr);
    }
    try writeFixture(source, "safe");
    if (c.symlink(source.ptr, link.ptr) != 0) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidSource, stage(std.testing.allocator, link, dir, "target"));
    try std.testing.expectError(error.InvalidName, stage(std.testing.allocator, source, dir, "../escape"));
}

test "staged image enforces cap and cap plus one during copy" {
    var dir_buf: [192]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-stage-cap-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    defer _ = c.rmdir(dir.ptr);
    var source_buf: [224]u8 = undefined;
    const source = try std.fmt.bufPrintZ(&source_buf, "{s}/source", .{dir});
    defer _ = c.unlink(source.ptr);

    try writeFixture(source, "12345678");
    var exact = try stageImpl(std.testing.allocator, source, dir, "exact", true, 8);
    exact.deinit();
    try writeFixture(source, "123456789");
    try std.testing.expectError(
        error.InvalidSource,
        stageImpl(std.testing.allocator, source, dir, "too-large", true, 8),
    );
}

test "staged image cleanup removes corrupted owned inode but preserves replacement generation" {
    var dir_buf: [192]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-stage-cleanup-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    defer _ = c.rmdir(dir.ptr);
    var source_buf: [224]u8 = undefined;
    const source = try std.fmt.bufPrintZ(&source_buf, "{s}/source", .{dir});
    defer _ = c.unlink(source.ptr);
    try writeFixture(source, "owned-image");

    var corrupted = try stageExclusive(std.testing.allocator, source, dir, "corrupted");
    const corrupted_path = try std.testing.allocator.dupeZ(u8, corrupted.path);
    defer std.testing.allocator.free(corrupted_path);
    try std.testing.expect(c.chmod(corrupted.path.ptr, 0o600) == 0);
    corrupted.deinit();
    try std.testing.expect(c.access(corrupted_path.ptr, c.F_OK) != 0);

    var replaced = try stageExclusive(std.testing.allocator, source, dir, "replaced");
    const replaced_path = try std.testing.allocator.dupeZ(u8, replaced.path);
    defer std.testing.allocator.free(replaced_path);
    var original_buf: [256]u8 = undefined;
    const original = try std.fmt.bufPrintZ(&original_buf, "{s}.original", .{replaced_path});
    defer _ = c.unlink(original.ptr);
    defer _ = c.unlink(replaced_path.ptr);
    try std.testing.expect(c.rename(replaced.path.ptr, original.ptr) == 0);
    try writeFixture(replaced_path, "replacement");
    replaced.deinit();
    try std.testing.expect(c.access(replaced_path.ptr, c.F_OK) == 0);
}
