//! Release provenance adapter의 로컬 파일 권위 경계.
//!
//! Pathname을 검사한 뒤 다시 여는 대신 absolute path의 모든 component를 `openat(O_NOFOLLOW)`로 내려가고,
//! 최종 fd에서 type·size·identity·bytes·SHA를 한 번에 만든다. Summary는 같은 안전한 parent fd에 temp를
//! 완전히 기록한 뒤 `RENAME_EXCL`로만 게시하므로 기존 결과를 덮어쓰지 않는다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const safe_open = @import("safe_open");
const identity = @import("release_adapter_identity");

extern "c" fn renameatx_np(
    from_dir_fd: c_int,
    from: [*:0]const u8,
    to_dir_fd: c_int,
    to: [*:0]const u8,
    flags: c_uint,
) c_int;

const rename_excl: c_uint = 0x00000004;
const summary_cap: usize = 1024 * 1024;

pub const Error = error{
    InvalidOwner,
    InvalidExpected,
    UnsafePath,
    NotRegular,
    NotExecutable,
    TooLarge,
    SizeMismatch,
    DigestMismatch,
    ReadFailed,
    FileChanged,
    ChangedDuringRead,
    PathAlias,
    DestinationExists,
    CreateFailed,
    WriteFailed,
    SyncFailed,
    PublishFailed,
} || std.mem.Allocator.Error;

pub const Identity = struct {
    device: u64,
    inode: u64,
};

pub const ExecutableExpected = struct {
    size: u64,
    sha256: [64]u8,
};

pub const ExecutableObservation = struct {
    identity: Identity,
    size: u64,
    mode: u32,
    sha256: [64]u8,
};

const FileFingerprint = struct {
    identity: Identity,
    size: u64,
    mode: u32,
    link_count: u64,
    modified_sec: i64,
    modified_nsec: i64,
    changed_sec: i64,
    changed_nsec: i64,
};

/// Final-address descriptor owner for the large frozen executable asset. Unlike `Input`, this
/// keeps no heap copy: the held fd and a streaming digest are the authority consumed later.
pub const PinnedExecutableFile = struct {
    owner: ?*PinnedExecutableFile = null,
    fd: c.fd_t = -1,
    path_len: usize = 0,
    path_sha256: [32]u8 = @splat(0),
    fingerprint: FileFingerprint = undefined,
    sha256: [64]u8 = @splat(0),

    pub fn value(self: *const @This()) ?ExecutableObservation {
        if (self.owner != self or self.fd < 0) return null;
        return .{
            .identity = self.fingerprint.identity,
            .size = self.fingerprint.size,
            .mode = self.fingerprint.mode,
            .sha256 = self.sha256,
        };
    }

    pub fn deinit(self: *@This()) Error!void {
        if (self.owner != self or self.fd < 0) return error.InvalidOwner;
        _ = c.close(self.fd);
        self.* = .{};
    }
};

pub const Input = struct {
    bytes: []u8,
    size: u64,
    mode: u32,
    sha256: [64]u8,
    identity: Identity,

    pub fn deinit(self: *Input, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn readInputAlloc(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    cap: usize,
) Error!Input {
    const fd = safe_open.openAbsoluteNoFollow(path, false) catch return error.UnsafePath;
    defer _ = c.close(fd);
    var before: posix.Stat = undefined;
    if (c.fstat(fd, &before) != 0) return error.ReadFailed;
    if (!posix.S.ISREG(before.mode)) return error.NotRegular;
    if (before.size < 0 or @as(u64, @intCast(before.size)) > cap) return error.TooLarge;
    const size: usize = @intCast(before.size);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < size) {
        const count = c.pread(fd, bytes[offset..].ptr, size - offset, @intCast(offset));
        if (count < 0) {
            if (posix.errno(-1) == .INTR) continue;
            return error.ReadFailed;
        }
        if (count == 0) return error.ChangedDuringRead;
        offset += @intCast(count);
    }
    var extra: [1]u8 = undefined;
    while (true) {
        const extra_count = c.pread(fd, &extra, 1, @intCast(size));
        if (extra_count < 0) {
            if (posix.errno(-1) == .INTR) continue;
            return error.ReadFailed;
        }
        if (extra_count != 0) return error.ChangedDuringRead;
        break;
    }
    var after: posix.Stat = undefined;
    if (c.fstat(fd, &after) != 0 or before.dev != after.dev or before.ino != after.ino or
        before.mode != after.mode or
        before.size != after.size or before.mtimespec.sec != after.mtimespec.sec or
        before.mtimespec.nsec != after.mtimespec.nsec or
        before.ctimespec.sec != after.ctimespec.sec or
        before.ctimespec.nsec != after.ctimespec.nsec) return error.ChangedDuringRead;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{
        .bytes = bytes,
        .size = @intCast(size),
        .mode = @intCast(before.mode),
        .sha256 = std.fmt.bytesToHex(digest, .lower),
        .identity = .{ .device = @intCast(before.dev), .inode = @intCast(before.ino) },
    };
}

pub fn pinExecutable(
    result: *PinnedExecutableFile,
    path: [:0]const u8,
    expected: ExecutableExpected,
    max_bytes: u64,
) Error!void {
    if (result.owner != null or result.fd >= 0) return error.InvalidOwner;
    if (expected.size == 0 or max_bytes == 0 or expected.size > max_bytes or
        !identity.lowerHex(&expected.sha256, 64)) return error.InvalidExpected;
    const fd = safe_open.openAbsoluteNoFollow(path, false) catch return error.UnsafePath;
    var keep = false;
    defer {
        if (!keep) _ = c.close(fd);
    }
    var before_stat: posix.Stat = undefined;
    if (c.fstat(fd, &before_stat) != 0) return error.ReadFailed;
    const before = try executableFingerprint(before_stat);
    if (before.size != expected.size) return error.SizeMismatch;
    const actual = try hashExact(fd, expected.size);
    var after_stat: posix.Stat = undefined;
    if (c.fstat(fd, &after_stat) != 0) return error.ReadFailed;
    const after = try executableFingerprint(after_stat);
    if (!sameFingerprint(before, after)) return error.FileChanged;
    if (!std.mem.eql(u8, &actual, &expected.sha256)) return error.DigestMismatch;
    result.* = .{
        .owner = result,
        .fd = fd,
        .path_len = path.len,
        .fingerprint = before,
        .sha256 = actual,
    };
    std.crypto.hash.sha2.Sha256.hash(path, &result.path_sha256, .{});
    keep = true;
}

pub fn revalidateExecutable(
    pinned: *const PinnedExecutableFile,
    path: [:0]const u8,
) Error!ExecutableObservation {
    const expected = pinned.value() orelse return error.InvalidOwner;
    var path_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &path_digest, .{});
    if (path.len != pinned.path_len or !std.mem.eql(u8, &path_digest, &pinned.path_sha256))
        return error.FileChanged;

    const current_fd = safe_open.openAbsoluteNoFollow(path, false) catch return error.FileChanged;
    defer _ = c.close(current_fd);
    var held_before_stat: posix.Stat = undefined;
    var path_before_stat: posix.Stat = undefined;
    if (c.fstat(pinned.fd, &held_before_stat) != 0 or c.fstat(current_fd, &path_before_stat) != 0)
        return error.FileChanged;
    const held_before = executableFingerprint(held_before_stat) catch return error.FileChanged;
    const path_before = executableFingerprint(path_before_stat) catch return error.FileChanged;
    if (!sameFingerprint(pinned.fingerprint, held_before) or
        !sameFingerprint(pinned.fingerprint, path_before)) return error.FileChanged;

    const actual = hashExact(pinned.fd, expected.size) catch return error.FileChanged;
    var held_after_stat: posix.Stat = undefined;
    var path_after_stat: posix.Stat = undefined;
    if (c.fstat(pinned.fd, &held_after_stat) != 0 or c.fstat(current_fd, &path_after_stat) != 0)
        return error.FileChanged;
    const held_after = executableFingerprint(held_after_stat) catch return error.FileChanged;
    const path_after = executableFingerprint(path_after_stat) catch return error.FileChanged;
    if (!sameFingerprint(pinned.fingerprint, held_after) or
        !sameFingerprint(pinned.fingerprint, path_after) or
        !std.mem.eql(u8, &actual, &expected.sha256)) return error.FileChanged;

    // Reopen after hashing as well. The later composition consumes only this pinned observation,
    // never the pathname, but this closes a replacement that races the first reopen.
    const final_fd = safe_open.openAbsoluteNoFollow(path, false) catch return error.FileChanged;
    defer _ = c.close(final_fd);
    var final_stat: posix.Stat = undefined;
    if (c.fstat(final_fd, &final_stat) != 0) return error.FileChanged;
    const final = executableFingerprint(final_stat) catch return error.FileChanged;
    if (!sameFingerprint(pinned.fingerprint, final)) return error.FileChanged;
    return expected;
}

fn executableFingerprint(stat: posix.Stat) Error!FileFingerprint {
    if (!posix.S.ISREG(stat.mode)) return error.NotRegular;
    if (stat.mode & 0o111 == 0) return error.NotExecutable;
    if (stat.size < 0) return error.SizeMismatch;
    return .{
        .identity = .{ .device = @intCast(stat.dev), .inode = @intCast(stat.ino) },
        .size = @intCast(stat.size),
        .mode = @intCast(stat.mode),
        .link_count = @intCast(stat.nlink),
        .modified_sec = stat.mtimespec.sec,
        .modified_nsec = stat.mtimespec.nsec,
        .changed_sec = stat.ctimespec.sec,
        .changed_nsec = stat.ctimespec.nsec,
    };
}

fn sameFingerprint(left: FileFingerprint, right: FileFingerprint) bool {
    return left.identity.device == right.identity.device and left.identity.inode == right.identity.inode and
        left.size == right.size and left.mode == right.mode and left.link_count == right.link_count and
        left.modified_sec == right.modified_sec and left.modified_nsec == right.modified_nsec and
        left.changed_sec == right.changed_sec and left.changed_nsec == right.changed_nsec;
}

fn hashExact(fd: c.fd_t, expected_size: u64) Error![64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (offset < expected_size) {
        const wanted: usize = @intCast(@min(@as(u64, buffer.len), expected_size - offset));
        const count = c.pread(fd, &buffer, wanted, @intCast(offset));
        if (count < 0) {
            if (posix.errno(-1) == .INTR) continue;
            return error.ReadFailed;
        }
        if (count == 0) return error.SizeMismatch;
        const len: usize = @intCast(count);
        hash.update(buffer[0..len]);
        offset += len;
    }
    var extra: [1]u8 = undefined;
    while (true) {
        const count = c.pread(fd, &extra, 1, @intCast(expected_size));
        if (count < 0) {
            if (posix.errno(-1) == .INTR) continue;
            return error.ReadFailed;
        }
        if (count != 0) return error.SizeMismatch;
        break;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn requireDistinct(identities: []const Identity) Error!void {
    for (identities, 0..) |left, index| {
        for (identities[index + 1 ..]) |right| {
            if (left.device == right.device and left.inode == right.inode) return error.PathAlias;
        }
    }
}

pub fn publishSummaryExclusive(path: [:0]const u8, bytes: []const u8) Error!void {
    if (bytes.len == 0 or bytes.len > summary_cap) return error.TooLarge;
    var leaf_buf: [std.fs.max_name_bytes:0]u8 = undefined;
    const parent = try openParent(path, &leaf_buf);
    defer _ = c.close(parent.fd);
    var existing: posix.Stat = undefined;
    if (c.fstatat(parent.fd, parent.leaf.ptr, &existing, posix.AT.SYMLINK_NOFOLLOW) == 0)
        return error.DestinationExists;
    if (posix.errno(-1) != .NOENT) return error.UnsafePath;

    var temp_buf: [96:0]u8 = undefined;
    var temp: [:0]const u8 = undefined;
    var fd: c.fd_t = -1;
    for (0..8) |_| {
        var nonce: u64 = undefined;
        c.arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(u64));
        temp = std.fmt.bufPrintZ(&temp_buf, ".maru-release-summary-{x}.tmp", .{nonce}) catch
            return error.CreateFailed;
        fd = c.openat(parent.fd, temp.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, @as(c.mode_t, 0o600));
        if (fd >= 0) break;
        if (posix.errno(-1) != .EXIST) return error.CreateFailed;
    }
    if (fd < 0) return error.CreateFailed;
    var published = false;
    defer {
        if (fd >= 0) _ = c.close(fd);
        if (!published) _ = c.unlinkat(parent.fd, temp.ptr, 0);
    }
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0) {
            if (posix.errno(-1) == .INTR) continue;
            return error.WriteFailed;
        }
        if (count == 0) return error.WriteFailed;
        offset += @intCast(count);
    }
    if (c.fchmod(fd, 0o600) != 0 or c.fsync(fd) != 0) return error.SyncFailed;
    const closing_fd = fd;
    fd = -1;
    if (c.close(closing_fd) != 0) return error.SyncFailed;
    if (renameatx_np(parent.fd, temp.ptr, parent.fd, parent.leaf.ptr, rename_excl) != 0) {
        if (posix.errno(-1) == .EXIST) return error.DestinationExists;
        return error.PublishFailed;
    }
    published = true;
    if (c.fsync(parent.fd) != 0) {
        if (c.unlinkat(parent.fd, parent.leaf.ptr, 0) == 0) _ = c.fsync(parent.fd);
        return error.SyncFailed;
    }
}

pub fn createWorkDirExclusive(path: [:0]const u8) Error!void {
    var leaf_buf: [std.fs.max_name_bytes:0]u8 = undefined;
    const parent = try openParent(path, &leaf_buf);
    defer _ = c.close(parent.fd);
    if (c.mkdirat(parent.fd, parent.leaf.ptr, 0o700) != 0) {
        if (posix.errno(-1) == .EXIST) return error.DestinationExists;
        return error.CreateFailed;
    }
    var keep = false;
    defer {
        if (!keep) _ = c.unlinkat(parent.fd, parent.leaf.ptr, posix.AT.REMOVEDIR);
    }
    var created: posix.Stat = undefined;
    if (c.fstatat(parent.fd, parent.leaf.ptr, &created, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !posix.S.ISDIR(created.mode) or
        c.fchmodat(parent.fd, parent.leaf.ptr, 0o700, @intCast(posix.AT.SYMLINK_NOFOLLOW)) != 0)
        return error.SyncFailed;
    const dir_fd = c.openat(parent.fd, parent.leaf.ptr, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .DIRECTORY = true,
        .NOFOLLOW = true,
    }, @as(c.mode_t, 0));
    if (dir_fd < 0) return error.CreateFailed;
    defer _ = c.close(dir_fd);
    var stat: posix.Stat = undefined;
    if (c.fstat(dir_fd, &stat) != 0 or !posix.S.ISDIR(stat.mode) or
        created.dev != stat.dev or created.ino != stat.ino or stat.mode & 0o777 != 0o700 or
        c.fsync(dir_fd) != 0)
        return error.SyncFailed;
    if (c.fsync(parent.fd) != 0) return error.SyncFailed;
    keep = true;
}

const Parent = struct {
    fd: c.fd_t,
    leaf: [:0]const u8,
};

fn openParent(path: [:0]const u8, leaf_buf: *[std.fs.max_name_bytes:0]u8) Error!Parent {
    if (path.len < 2 or path[0] != '/') return error.UnsafePath;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.UnsafePath;
    const leaf = path[slash + 1 ..];
    if (!validComponent(leaf)) return error.UnsafePath;
    const leaf_z = std.fmt.bufPrintZ(leaf_buf, "{s}", .{leaf}) catch return error.UnsafePath;
    var parent_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent_path = if (slash == 0)
        "/"
    else
        std.fmt.bufPrintZ(&parent_buf, "{s}", .{path[0..slash]}) catch return error.UnsafePath;
    return .{
        .fd = safe_open.openAbsoluteNoFollow(parent_path, true) catch return error.UnsafePath,
        .leaf = leaf_z,
    };
}

fn validComponent(component: []const u8) bool {
    return component.len != 0 and component.len <= std.fs.max_name_bytes and
        !std.mem.eql(u8, component, ".") and !std.mem.eql(u8, component, "..") and
        std.mem.indexOfScalar(u8, component, 0) == null;
}
