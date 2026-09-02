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
pub const max_release_asset_bytes: u64 = 2 * 1024 * 1024 * 1024 - 1;

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

const DirectoryFingerprint = struct {
    identity: Identity,
    mode: u32,
    modified_sec: i64,
    modified_nsec: i64,
    changed_sec: i64,
    changed_nsec: i64,
};

pub const PathMutationSeal = struct {
    identity: Identity,
    mode: u32,
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
    parent_fd: c.fd_t = -1,
    path_len: usize = 0,
    path_sha256: [32]u8 = @splat(0),
    fingerprint: FileFingerprint = undefined,
    parent_fingerprint: DirectoryFingerprint = undefined,
    sha256: [64]u8 = @splat(0),

    pub fn value(self: *const @This()) ?ExecutableObservation {
        if (self.owner != self or self.fd < 0 or self.parent_fd < 0) return null;
        return .{
            .identity = self.fingerprint.identity,
            .size = self.fingerprint.size,
            .mode = self.fingerprint.mode,
            .sha256 = self.sha256,
        };
    }

    pub fn deinit(self: *@This()) Error!void {
        if (self.owner != self or self.fd < 0 or self.parent_fd < 0) return error.InvalidOwner;
        _ = c.close(self.fd);
        _ = c.close(self.parent_fd);
        self.* = .{};
    }

    pub fn pathMutationSeal(self: *const @This()) Error!PathMutationSeal {
        if (self.value() == null) return error.InvalidOwner;
        var stat: posix.Stat = undefined;
        if (c.fstat(self.parent_fd, &stat) != 0) return error.FileChanged;
        return mutationSeal(try directoryFingerprint(stat));
    }

    pub fn validatePathMutationSeal(self: *const @This(), seal: PathMutationSeal) Error!void {
        if (self.value() == null) return error.InvalidOwner;
        var stat: posix.Stat = undefined;
        if (c.fstat(self.parent_fd, &stat) != 0) return error.FileChanged;
        if (!sameMutationSeal(seal, mutationSeal(try directoryFingerprint(stat))))
            return error.FileChanged;
    }

    /// Revalidates the held executable and parent vnode without reopening a caller pathname.
    pub fn revalidateHeld(self: *const @This()) Error!ExecutableObservation {
        const expected = self.value() orelse return error.InvalidOwner;
        var before_stat: posix.Stat = undefined;
        var parent_stat: posix.Stat = undefined;
        if (c.fstat(self.fd, &before_stat) != 0 or c.fstat(self.parent_fd, &parent_stat) != 0)
            return error.FileChanged;
        const before = try executableFingerprint(before_stat);
        if (!sameFingerprint(self.fingerprint, before) or
            !sameDirectoryAuthority(self.parent_fingerprint, try directoryFingerprint(parent_stat)))
            return error.FileChanged;
        const digest = hashExact(self.fd, expected.size) catch return error.FileChanged;
        var after_stat: posix.Stat = undefined;
        if (c.fstat(self.fd, &after_stat) != 0) return error.FileChanged;
        const after = try executableFingerprint(after_stat);
        if (!sameFingerprint(self.fingerprint, after) or !std.mem.eql(u8, &digest, &self.sha256))
            return error.FileChanged;
        return expected;
    }
};

/// Manifest-independent authority for one large release asset. It derives size and digest from a
/// held no-follow fd, so pre-manifest composition never needs caller-provided file observations.
pub const PinnedReleaseFile = struct {
    owner: ?*PinnedReleaseFile = null,
    fd: c.fd_t = -1,
    parent_fd: c.fd_t = -1,
    path_len: usize = 0,
    path_sha256: [32]u8 = @splat(0),
    fingerprint: FileFingerprint = undefined,
    parent_fingerprint: DirectoryFingerprint = undefined,
    sha256: [64]u8 = @splat(0),
    executable: bool = false,

    pub fn value(self: *const @This()) ?ExecutableObservation {
        if (self.owner != self or self.fd < 0 or self.parent_fd < 0) return null;
        return .{ .identity = self.fingerprint.identity, .size = self.fingerprint.size, .mode = self.fingerprint.mode, .sha256 = self.sha256 };
    }

    pub fn executableDirectoryDescriptor(self: *const @This()) Error!c.fd_t {
        if (self.value() == null or !self.executable or self.parent_fd < 0) return error.InvalidOwner;
        return self.parent_fd;
    }

    pub fn heldDescriptor(self: *const @This()) Error!c.fd_t {
        if (self.value() == null or self.fd < 0) return error.InvalidOwner;
        return self.fd;
    }

    pub fn pathMutationSeal(self: *const @This()) Error!PathMutationSeal {
        if (self.value() == null or !self.executable) return error.InvalidOwner;
        var stat: posix.Stat = undefined;
        if (c.fstat(self.parent_fd, &stat) != 0) return error.FileChanged;
        return mutationSeal(try directoryFingerprint(stat));
    }

    pub fn validatePathMutationSeal(self: *const @This(), seal: PathMutationSeal) Error!void {
        if (self.value() == null or !self.executable) return error.InvalidOwner;
        var stat: posix.Stat = undefined;
        if (c.fstat(self.parent_fd, &stat) != 0 or
            !sameMutationSeal(seal, mutationSeal(try directoryFingerprint(stat))))
            return error.FileChanged;
    }

    pub fn revalidate(self: *const @This(), path: [:0]const u8) Error!ExecutableObservation {
        const expected = self.value() orelse return error.InvalidOwner;
        var path_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(path, &path_digest, .{});
        if (path.len != self.path_len or !std.mem.eql(u8, &path_digest, &self.path_sha256)) return error.FileChanged;
        const current_fd = safe_open.openAbsoluteNoFollow(path, false) catch return error.FileChanged;
        defer _ = c.close(current_fd);
        var held_stat: posix.Stat = undefined;
        var path_stat: posix.Stat = undefined;
        var parent_stat: posix.Stat = undefined;
        if (c.fstat(self.fd, &held_stat) != 0 or c.fstat(current_fd, &path_stat) != 0 or c.fstat(self.parent_fd, &parent_stat) != 0)
            return error.FileChanged;
        const held = releaseFingerprint(held_stat, self.executable) catch return error.FileChanged;
        const reopened = releaseFingerprint(path_stat, self.executable) catch return error.FileChanged;
        if (!sameFingerprint(self.fingerprint, held) or !sameFingerprint(self.fingerprint, reopened) or
            !sameDirectoryAuthority(self.parent_fingerprint, directoryFingerprint(parent_stat) catch return error.FileChanged))
            return error.FileChanged;
        const digest = hashExact(self.fd, expected.size) catch return error.FileChanged;
        var after: posix.Stat = undefined;
        if (c.fstat(self.fd, &after) != 0 or !sameFingerprint(self.fingerprint, releaseFingerprint(after, self.executable) catch return error.FileChanged) or
            !std.mem.eql(u8, &digest, &self.sha256)) return error.FileChanged;
        const final_fd = safe_open.openAbsoluteNoFollow(path, false) catch return error.FileChanged;
        defer _ = c.close(final_fd);
        var final_stat: posix.Stat = undefined;
        var parent_final: posix.Stat = undefined;
        if (c.fstat(final_fd, &final_stat) != 0 or c.fstat(self.parent_fd, &parent_final) != 0 or
            !sameFingerprint(self.fingerprint, releaseFingerprint(final_stat, self.executable) catch return error.FileChanged) or
            !sameDirectoryAuthority(self.parent_fingerprint, directoryFingerprint(parent_final) catch return error.FileChanged))
            return error.FileChanged;
        return expected;
    }

    /// Reads bytes from the already-held publication inode. The pathname participates only in
    /// proving that the durable leaf still names that inode before and after the read.
    pub fn readHeldAlloc(self: *const @This(), allocator: std.mem.Allocator, path: [:0]const u8, cap: usize) Error!Input {
        const before = try self.revalidate(path);
        if (before.size > cap) return error.TooLarge;
        const size: usize = @intCast(before.size);
        const bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);
        var offset: usize = 0;
        while (offset < size) {
            const count = c.pread(self.fd, bytes[offset..].ptr, size - offset, @intCast(offset));
            if (count < 0) {
                if (posix.errno(-1) == .INTR) continue;
                return error.ReadFailed;
            }
            if (count == 0) return error.ChangedDuringRead;
            offset += @intCast(count);
        }
        var extra: [1]u8 = undefined;
        while (true) {
            const count = c.pread(self.fd, &extra, 1, @intCast(size));
            if (count < 0) {
                if (posix.errno(-1) == .INTR) continue;
                return error.ReadFailed;
            }
            if (count != 0) return error.ChangedDuringRead;
            break;
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        const after = try self.revalidate(path);
        if (before.identity.device != after.identity.device or before.identity.inode != after.identity.inode or
            before.size != after.size or before.mode != after.mode or
            !std.mem.eql(u8, &before.sha256, &after.sha256) or
            !std.mem.eql(u8, &digest_hex, &self.sha256)) return error.ChangedDuringRead;
        return .{ .bytes = bytes, .size = before.size, .mode = before.mode, .sha256 = digest_hex, .identity = before.identity };
    }

    pub fn deinit(self: *@This()) Error!void {
        if (self.owner != self or self.fd < 0 or self.parent_fd < 0) return error.InvalidOwner;
        _ = c.close(self.fd);
        _ = c.close(self.parent_fd);
        self.* = .{};
    }
};

pub fn pinReleaseFileObserved(result: *PinnedReleaseFile, path: [:0]const u8, require_executable: bool, max_bytes: u64) Error!void {
    if (result.owner != null or result.fd >= 0 or result.parent_fd >= 0) return error.InvalidOwner;
    if (max_bytes == 0) return error.InvalidExpected;
    var leaf_storage: [std.fs.max_name_bytes:0]u8 = undefined;
    const parent = try openParent(path, &leaf_storage);
    var keep_parent = false;
    defer {
        if (!keep_parent) _ = c.close(parent.fd);
    }
    var parent_stat: posix.Stat = undefined;
    if (c.fstat(parent.fd, &parent_stat) != 0) return error.ReadFailed;
    const parent_fingerprint = try directoryFingerprint(parent_stat);
    const fd = safe_open.openAbsoluteNoFollow(path, false) catch return error.UnsafePath;
    var keep_fd = false;
    defer {
        if (!keep_fd) _ = c.close(fd);
    }
    var before_stat: posix.Stat = undefined;
    var leaf_stat: posix.Stat = undefined;
    if (c.fstat(fd, &before_stat) != 0 or c.fstatat(parent.fd, parent.leaf.ptr, &leaf_stat, posix.AT.SYMLINK_NOFOLLOW) != 0)
        return error.ReadFailed;
    const before = try releaseFingerprint(before_stat, require_executable);
    const leaf = try releaseFingerprint(leaf_stat, require_executable);
    if (!sameFingerprint(before, leaf)) return error.FileChanged;
    if (before.link_count != 1) return error.PathAlias;
    if (before.size == 0 or before.size > max_bytes) return error.TooLarge;
    const digest = try hashExact(fd, before.size);
    var after_stat: posix.Stat = undefined;
    var parent_after: posix.Stat = undefined;
    if (c.fstat(fd, &after_stat) != 0 or c.fstat(parent.fd, &parent_after) != 0 or
        !sameFingerprint(before, try releaseFingerprint(after_stat, require_executable)) or
        !sameDirectoryFingerprint(parent_fingerprint, try directoryFingerprint(parent_after))) return error.FileChanged;
    var path_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &path_digest, .{});
    result.* = .{ .owner = result, .fd = fd, .parent_fd = parent.fd, .path_len = path.len, .path_sha256 = path_digest, .fingerprint = before, .parent_fingerprint = parent_fingerprint, .sha256 = digest, .executable = require_executable };
    keep_fd = true;
    keep_parent = true;
}

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
    if (result.owner != null or result.fd >= 0 or result.parent_fd >= 0) return error.InvalidOwner;
    if (expected.size == 0 or max_bytes == 0 or expected.size > max_bytes or
        !identity.lowerHex(&expected.sha256, 64)) return error.InvalidExpected;
    var leaf_storage: [std.fs.max_name_bytes:0]u8 = undefined;
    const parent = try openParent(path, &leaf_storage);
    var keep_parent = false;
    defer {
        if (!keep_parent) _ = c.close(parent.fd);
    }
    var parent_before_stat: posix.Stat = undefined;
    if (c.fstat(parent.fd, &parent_before_stat) != 0) return error.ReadFailed;
    const parent_before = try directoryFingerprint(parent_before_stat);
    const fd = safe_open.openAbsoluteNoFollow(path, false) catch return error.UnsafePath;
    var keep = false;
    defer {
        if (!keep) _ = c.close(fd);
    }
    var before_stat: posix.Stat = undefined;
    if (c.fstat(fd, &before_stat) != 0) return error.ReadFailed;
    const before = try executableFingerprint(before_stat);
    var leaf_stat: posix.Stat = undefined;
    if (c.fstatat(parent.fd, parent.leaf.ptr, &leaf_stat, posix.AT.SYMLINK_NOFOLLOW) != 0)
        return error.FileChanged;
    const leaf = try executableFingerprint(leaf_stat);
    if (!sameFingerprint(before, leaf)) return error.FileChanged;
    if (before.size != expected.size) return error.SizeMismatch;
    const actual = try hashExact(fd, expected.size);
    var after_stat: posix.Stat = undefined;
    if (c.fstat(fd, &after_stat) != 0) return error.ReadFailed;
    const after = try executableFingerprint(after_stat);
    if (!sameFingerprint(before, after)) return error.FileChanged;
    var parent_after_stat: posix.Stat = undefined;
    if (c.fstat(parent.fd, &parent_after_stat) != 0 or
        !sameDirectoryFingerprint(parent_before, try directoryFingerprint(parent_after_stat)))
        return error.FileChanged;
    if (!std.mem.eql(u8, &actual, &expected.sha256)) return error.DigestMismatch;
    result.* = .{
        .owner = result,
        .fd = fd,
        .parent_fd = parent.fd,
        .path_len = path.len,
        .fingerprint = before,
        .parent_fingerprint = parent_before,
        .sha256 = actual,
    };
    std.crypto.hash.sha2.Sha256.hash(path, &result.path_sha256, .{});
    keep = true;
    keep_parent = true;
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

    var parent_before_stat: posix.Stat = undefined;
    if (c.fstat(pinned.parent_fd, &parent_before_stat) != 0 or
        !sameDirectoryAuthority(pinned.parent_fingerprint, directoryFingerprint(parent_before_stat) catch return error.FileChanged))
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
    var parent_after_stat: posix.Stat = undefined;
    if (c.fstat(pinned.parent_fd, &parent_after_stat) != 0 or
        !sameDirectoryAuthority(pinned.parent_fingerprint, directoryFingerprint(parent_after_stat) catch return error.FileChanged))
        return error.FileChanged;
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

fn releaseFingerprint(stat: posix.Stat, require_executable: bool) Error!FileFingerprint {
    if (!posix.S.ISREG(stat.mode)) return error.NotRegular;
    if (require_executable and stat.mode & 0o111 == 0) return error.NotExecutable;
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

fn directoryFingerprint(stat: posix.Stat) Error!DirectoryFingerprint {
    if (!posix.S.ISDIR(stat.mode)) return error.UnsafePath;
    return .{
        .identity = .{ .device = @intCast(stat.dev), .inode = @intCast(stat.ino) },
        .mode = @intCast(stat.mode),
        .modified_sec = stat.mtimespec.sec,
        .modified_nsec = stat.mtimespec.nsec,
        .changed_sec = stat.ctimespec.sec,
        .changed_nsec = stat.ctimespec.nsec,
    };
}

fn sameDirectoryFingerprint(left: DirectoryFingerprint, right: DirectoryFingerprint) bool {
    return left.identity.device == right.identity.device and left.identity.inode == right.identity.inode and
        left.mode == right.mode and left.modified_sec == right.modified_sec and
        left.modified_nsec == right.modified_nsec and left.changed_sec == right.changed_sec and
        left.changed_nsec == right.changed_nsec;
}

fn sameDirectoryAuthority(left: DirectoryFingerprint, right: DirectoryFingerprint) bool {
    return left.identity.device == right.identity.device and left.identity.inode == right.identity.inode and
        left.mode == right.mode;
}

fn mutationSeal(value: DirectoryFingerprint) PathMutationSeal {
    return .{
        .identity = value.identity,
        .mode = value.mode,
        .modified_sec = value.modified_sec,
        .modified_nsec = value.modified_nsec,
        .changed_sec = value.changed_sec,
        .changed_nsec = value.changed_nsec,
    };
}

fn sameMutationSeal(left: PathMutationSeal, right: PathMutationSeal) bool {
    return left.identity.device == right.identity.device and left.identity.inode == right.identity.inode and
        left.mode == right.mode and left.modified_sec == right.modified_sec and
        left.modified_nsec == right.modified_nsec and left.changed_sec == right.changed_sec and
        left.changed_nsec == right.changed_nsec;
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
    var published: PinnedReleaseFile = .{};
    try publishSummaryOwnedExclusive(&published, path, bytes);
    try published.deinit();
}

/// Publishes a summary without reopening it to derive manifest metadata. The held temporary-file
/// descriptor becomes the final leaf descriptor after the exclusive rename, so size and digest
/// authority cross the publication boundary without a pathname TOCTOU window.
pub fn publishSummaryOwnedExclusive(result: *PinnedReleaseFile, path: [:0]const u8, bytes: []const u8) Error!void {
    if (result.owner != null or result.fd >= 0 or result.parent_fd >= 0) return error.InvalidOwner;
    if (bytes.len == 0 or bytes.len > summary_cap) return error.TooLarge;
    var leaf_buf: [std.fs.max_name_bytes:0]u8 = undefined;
    const parent = try openParent(path, &leaf_buf);
    var keep_parent = false;
    defer {
        if (!keep_parent) _ = c.close(parent.fd);
    }
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
            .ACCMODE = .RDWR,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, @as(c.mode_t, 0o600));
        if (fd >= 0) break;
        if (posix.errno(-1) != .EXIST) return error.CreateFailed;
    }
    if (fd < 0) return error.CreateFailed;
    var temp_exists = true;
    var final_exists = false;
    var keep_fd = false;
    defer {
        var removed = false;
        if (temp_exists) removed = unlinkHeldLeaf(parent.fd, temp, fd);
        if (final_exists) removed = unlinkHeldLeaf(parent.fd, parent.leaf, fd) or removed;
        if (removed) _ = c.fsync(parent.fd);
        if (!keep_fd) _ = c.close(fd);
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
    var before_stat: posix.Stat = undefined;
    if (c.fstat(fd, &before_stat) != 0) return error.ReadFailed;
    const before = try releaseFingerprint(before_stat, false);
    if (before.link_count != 1 or before.size != bytes.len or before.mode & 0o777 != 0o600)
        return error.FileChanged;
    const digest = try hashExact(fd, before.size);
    if (renameatx_np(parent.fd, temp.ptr, parent.fd, parent.leaf.ptr, rename_excl) != 0) {
        if (posix.errno(-1) == .EXIST) return error.DestinationExists;
        return error.PublishFailed;
    }
    temp_exists = false;
    final_exists = true;
    if (c.fsync(parent.fd) != 0) return error.SyncFailed;

    const final_fd = safe_open.openAbsoluteNoFollow(path, false) catch return error.FileChanged;
    defer _ = c.close(final_fd);
    var held_stat: posix.Stat = undefined;
    var final_stat: posix.Stat = undefined;
    var parent_stat: posix.Stat = undefined;
    if (c.fstat(fd, &held_stat) != 0 or c.fstat(final_fd, &final_stat) != 0 or c.fstat(parent.fd, &parent_stat) != 0)
        return error.FileChanged;
    const held = releaseFingerprint(held_stat, false) catch return error.FileChanged;
    const reopened = releaseFingerprint(final_stat, false) catch return error.FileChanged;
    const final_digest = hashExact(fd, held.size) catch return error.FileChanged;
    // rename may legitimately advance ctime, so bind the pre-rename observation by inode, size,
    // mode and a second digest while requiring the post-rename held/reopened fingerprints exactly.
    if (before.identity.device != held.identity.device or before.identity.inode != held.identity.inode or
        before.size != held.size or before.mode != held.mode or !sameFingerprint(held, reopened) or held.link_count != 1 or held.size != bytes.len or
        held.mode & 0o777 != 0o600 or !std.mem.eql(u8, &digest, &final_digest))
        return error.FileChanged;
    const parent_fingerprint = directoryFingerprint(parent_stat) catch return error.FileChanged;
    var path_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &path_digest, .{});
    result.* = .{
        .owner = result,
        .fd = fd,
        .parent_fd = parent.fd,
        .path_len = path.len,
        .path_sha256 = path_digest,
        .fingerprint = held,
        .parent_fingerprint = parent_fingerprint,
        .sha256 = digest,
        .executable = false,
    };
    keep_fd = true;
    keep_parent = true;
    final_exists = false;
}

/// A failed publication may race with a pathname replacement. Only remove the leaf if it still
/// names the inode held by this operation; leaving residue is safer than deleting foreign data.
fn unlinkHeldLeaf(parent_fd: c.fd_t, leaf: [:0]const u8, held_fd: c.fd_t) bool {
    var held: posix.Stat = undefined;
    var path: posix.Stat = undefined;
    if (c.fstat(held_fd, &held) != 0 or
        c.fstatat(parent_fd, leaf.ptr, &path, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        held.dev != path.dev or held.ino != path.ino)
        return false;
    return c.unlinkat(parent_fd, leaf.ptr, 0) == 0;
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
