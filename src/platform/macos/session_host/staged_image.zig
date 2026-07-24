//! Upgrade target/rollback self-image를 owner-only directory에 고정하는 파일 원자성 경계.

const std = @import("std");
const c = std.c;
const posix = std.posix;

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
        _ = c.unlink(self.path.ptr);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

pub fn stage(
    allocator: std.mem.Allocator,
    source_path: [:0]const u8,
    owner_dir: [:0]const u8,
    final_name: []const u8,
) Error!StagedImage {
    try validateLeaf(final_name);
    const dir_fd = try openOwnerDir(owner_dir);
    defer _ = c.close(dir_fd);
    const source_fd = c.open(source_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (source_fd < 0) return error.OpenFailed;
    defer _ = c.close(source_fd);
    try validateRegular(source_fd);

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

    const out_fd = c.open(
        tmp_path.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o700),
    );
    if (out_fd < 0) return error.OpenFailed;
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
            return error.ReadFailed;
        }
        if (read_count == 0) break;
        const chunk = buffer[0..@intCast(read_count)];
        hasher.update(chunk);
        total = std.math.add(u64, total, chunk.len) catch return error.InvalidSource;
        try writeAll(out_fd, chunk);
    }
    if (c.fsync(out_fd) != 0) return error.SyncFailed;
    _ = c.close(out_fd);
    out_open = false;
    if (c.rename(tmp_path.ptr, final_path.ptr) != 0) return error.RenameFailed;
    if (c.fsync(dir_fd) != 0) return error.SyncFailed;

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const identity = try inspect(final_path);
    if (identity.size != total or !std.mem.eql(u8, &identity.sha256, &digest)) return error.HashMismatch;
    return .{ .allocator = allocator, .path = final_path, .identity = identity };
}

pub fn inspect(path: [:0]const u8) Error!Identity {
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or
        stat.mode & 0o022 != 0 or stat.size < 0)
        return error.InvalidSource;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read_count = c.read(fd, &buffer, buffer.len);
        if (read_count < 0) {
            if (posix.errno(read_count) == .INTR) continue;
            return error.ReadFailed;
        }
        if (read_count == 0) break;
        const chunk = buffer[0..@intCast(read_count)];
        hasher.update(chunk);
        total = std.math.add(u64, total, chunk.len) catch return error.InvalidSource;
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
    inject_before_rename: bool,
) Error!void {
    const dir_fd = try openOwnerDir(owner_dir);
    defer _ = c.close(dir_fd);
    const actual = try inspect(staged_path);
    if (!identityEqual(expected, actual)) return error.HashMismatch;
    if (inject_before_rename) return error.InjectedPromotionFailure;

    // destination replace가 한 번의 atomic rename이므로 current path는 old/new 중 하나로 항상 존재한다.
    if (c.rename(staged_path.ptr, current_path.ptr) != 0) return error.RenameFailed;
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

fn validateRegular(fd: c.fd_t) Error!void {
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or
        stat.mode & 0o022 != 0 or stat.size < 0)
        return error.InvalidSource;
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

    try writeFixture(source, "version-n");
    var first = try stage(std.testing.allocator, source, dir, "target-n");
    defer first.deinit();
    try promote(dir, first.path, first.identity, current, previous, false);
    try std.testing.expectEqual(@as(u64, 9), (try inspect(current)).size);

    try writeFixture(source, "version-n-plus-one");
    var second = try stage(std.testing.allocator, source, dir, "target-n-plus-one");
    defer second.deinit();
    try std.testing.expectError(error.InjectedPromotionFailure, promote(dir, second.path, second.identity, current, previous, true));
    const before = try inspect(current);
    try std.testing.expect(std.mem.eql(u8, &before.sha256, &first.identity.sha256));
    try promote(dir, second.path, second.identity, current, previous, false);
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
    try std.testing.expectError(error.OpenFailed, stage(std.testing.allocator, link, dir, "target"));
    try std.testing.expectError(error.InvalidName, stage(std.testing.allocator, source, dir, "../escape"));
}
