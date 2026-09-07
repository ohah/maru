//! Authority-bound executable copy for one immutable predecessor or current candidate source.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

const copy_buffer_bytes: usize = 64 * 1024;
const max_executable_bytes: u64 = 2 * 1024 * 1024 * 1024 - 1;

pub const SourceKind = enum { predecessor_download, current_candidate };

pub const View = struct {
    source_fd: c.fd_t,
    source_size: u64,
    source_sha256: [64]u8,
    source_kind: SourceKind,
    destination_dir_fd: c.fd_t,
    destination_path: []const u8,
    destination_leaf: [:0]const u8,
};

pub const Observation = struct {
    path: []const u8,
    size: u64,
    mode: u32,
    sha256: [64]u8,
};

pub const Materialized = struct {
    owner: ?*Materialized = null,
    fd: c.fd_t = -1,
    dir_fd: c.fd_t = -1,
    present: bool = false,
    source_device: u64 = 0,
    source_inode: u64 = 0,
    dir_device: u64 = 0,
    dir_inode: u64 = 0,
    device: u64 = 0,
    inode: u64 = 0,
    size: u64 = 0,
    sha256: [64]u8 = @splat(0),
    path_len: usize = 0,
    path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    leaf_len: usize = 0,
    leaf: [std.fs.max_name_bytes:0]u8 = @splat(0),

    pub fn revalidate(self: *const @This(), authority: anytype) !Observation {
        const current = try authority.revalidate();
        return self.revalidateView(current);
    }

    pub fn cleanup(self: *@This()) !void {
        if (self.owner != self or self.fd < 0 or self.dir_fd < 0) return error.InvalidOwner;
        if (self.present) {
            _ = validateDestination(self) catch return error.CleanupFailed;
            if (c.unlinkat(self.dir_fd, self.leaf[0..].ptr, 0) != 0) return error.CleanupFailed;
            self.present = false;
        }
        if (c.fsync(self.dir_fd) != 0) return error.CleanupFailed;
        _ = c.close(self.fd);
        _ = c.close(self.dir_fd);
        self.* = .{};
    }

    fn revalidateView(self: *const @This(), current: View) !Observation {
        if (self.owner != self or self.fd < 0 or self.dir_fd < 0) return error.InvalidOwner;
        try validateView(current);
        if (!sameDestination(self, current)) return error.AuthorityChanged;
        try validateBoundAuthorities(self, current);
        const observed = try validateDestination(self);
        return .{ .path = self.path[0..self.path_len], .size = observed.size, .mode = observed.mode, .sha256 = self.sha256 };
    }
};

pub fn materializeWith(authority: anytype, result: *Materialized) !void {
    if (!builtin.is_test) @compileError("materializeWith is a test-only seam");
    return materialize(authority, result);
}

pub fn materialize(authority: anytype, result: *Materialized) !void {
    if (!pristine(result) or overlaps(std.mem.asBytes(result), std.mem.asBytes(authority)))
        return error.InvalidOwner;
    const initial = try authority.revalidate();
    try validateView(initial);
    const source_stat = try validateSource(initial);
    const dir_stat = try validateDirectory(initial.destination_dir_fd);
    try snapshotDestination(result, initial);
    result.source_device = @intCast(source_stat.dev);
    result.source_inode = @intCast(source_stat.ino);
    result.dir_device = @intCast(dir_stat.dev);
    result.dir_inode = @intCast(dir_stat.ino);

    result.dir_fd = c.fcntl(initial.destination_dir_fd, c.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (result.dir_fd < 0) return error.CreateFailed;
    result.owner = result;
    const owned_dir = validateDirectory(result.dir_fd) catch {
        abort(result) catch return error.CleanupFailed;
        return error.CreateFailed;
    };
    if (owned_dir.dev != dir_stat.dev or owned_dir.ino != dir_stat.ino) {
        abort(result) catch return error.CleanupFailed;
        return error.AuthorityChanged;
    }

    materializeOwned(authority, result, initial) catch |err| {
        abort(result) catch return error.CleanupFailed;
        return err;
    };
}

fn materializeOwned(authority: anytype, result: *Materialized, initial: View) !void {
    result.fd = c.openat(result.dir_fd, result.leaf[0..].ptr, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .EXCL = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, @as(c.mode_t, 0o600));
    if (result.fd < 0) return if (posix.errno(-1) == .EXIST) error.DestinationExists else error.CreateFailed;
    result.present = true;

    var created: posix.Stat = undefined;
    if (c.fstat(result.fd, &created) != 0 or !posix.S.ISREG(created.mode) or created.nlink != 1)
        return error.CreateFailed;
    result.device = @intCast(created.dev);
    result.inode = @intCast(created.ino);
    result.size = initial.source_size;
    result.sha256 = initial.source_sha256;
    try copyExact(initial.source_fd, result.fd, initial.source_size);
    if (c.fchmod(result.fd, 0o500) != 0 or c.fsync(result.fd) != 0 or c.fsync(result.dir_fd) != 0)
        return error.SyncFailed;

    const current = try authority.revalidate();
    if (!sameView(initial, current)) return error.AuthorityChanged;
    try validateBoundAuthorities(result, current);
    _ = try validateDestination(result);
}

const Destination = struct { size: u64, mode: u32 };

fn validateDestination(result: *const Materialized) !Destination {
    if (!result.present) return error.FileChanged;
    var held: posix.Stat = undefined;
    var named: posix.Stat = undefined;
    if (c.fstat(result.fd, &held) != 0 or
        c.fstatat(result.dir_fd, result.leaf[0..].ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !sameFile(held, result) or !sameFile(named, result)) return error.FileChanged;
    const digest = try hashExact(result.fd, result.size);
    if (!std.mem.eql(u8, &digest, &result.sha256)) return error.FileChanged;
    return .{ .size = result.size, .mode = @intCast(held.mode) };
}

fn sameFile(stat: posix.Stat, result: *const Materialized) bool {
    return posix.S.ISREG(stat.mode) and stat.nlink == 1 and stat.mode & 0o777 == 0o500 and
        stat.dev == result.device and stat.ino == result.inode and stat.size >= 0 and
        @as(u64, @intCast(stat.size)) == result.size;
}

fn validateSource(view: View) !posix.Stat {
    var stat: posix.Stat = undefined;
    if (c.fstat(view.source_fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.nlink != 1 or
        stat.mode & 0o777 != sourceMode(view.source_kind) or stat.size < 0 or @as(u64, @intCast(stat.size)) != view.source_size)
        return error.InvalidAuthority;
    const digest = try hashExact(view.source_fd, view.source_size);
    if (!std.mem.eql(u8, &digest, &view.source_sha256)) return error.InvalidAuthority;
    return stat;
}

fn validateDirectory(fd: c.fd_t) !posix.Stat {
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISDIR(stat.mode) or stat.mode & 0o777 != 0o700)
        return error.InvalidAuthority;
    return stat;
}

fn validateBoundAuthorities(result: *const Materialized, view: View) !void {
    const source = try validateSource(view);
    const submitted_dir = try validateDirectory(view.destination_dir_fd);
    const held_dir = try validateDirectory(result.dir_fd);
    if (source.dev != result.source_device or source.ino != result.source_inode or
        submitted_dir.dev != result.dir_device or submitted_dir.ino != result.dir_inode or
        held_dir.dev != result.dir_device or held_dir.ino != result.dir_inode)
        return error.AuthorityChanged;
}

fn copyExact(source: c.fd_t, destination: c.fd_t, size_u64: u64) !void {
    const size = std.math.cast(usize, size_u64) orelse return error.InvalidAuthority;
    var buffer: [copy_buffer_bytes]u8 = undefined;
    var offset: usize = 0;
    while (offset < size) {
        const wanted = @min(buffer.len, size - offset);
        const count = c.pread(source, &buffer, wanted, @intCast(offset));
        if (count < 0) {
            if (posix.errno(-1) == .INTR) continue;
            return error.ReadFailed;
        }
        if (count == 0) return error.SourceChanged;
        const count_usize: usize = @intCast(count);
        var written: usize = 0;
        while (written < count_usize) {
            const n = c.write(destination, buffer[written..count_usize].ptr, count_usize - written);
            if (n < 0) {
                if (posix.errno(-1) == .INTR) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            written += @intCast(n);
        }
        offset += @intCast(count);
    }
    var extra: [1]u8 = undefined;
    if (c.pread(source, &extra, 1, @intCast(size)) != 0) return error.SourceChanged;
}

fn hashExact(fd: c.fd_t, size_u64: u64) ![64]u8 {
    const size = std.math.cast(usize, size_u64) orelse return error.InvalidAuthority;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [copy_buffer_bytes]u8 = undefined;
    var offset: usize = 0;
    while (offset < size) {
        const count = c.pread(fd, &buffer, @min(buffer.len, size - offset), @intCast(offset));
        if (count <= 0) return error.ReadFailed;
        hasher.update(buffer[0..@intCast(count)]);
        offset += @intCast(count);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn validateView(view: View) !void {
    if (view.source_fd < 0 or view.destination_dir_fd < 0 or view.source_size == 0 or
        view.source_size > max_executable_bytes or
        view.destination_path.len < 2 or view.destination_path.len >= std.fs.max_path_bytes or
        !std.fs.path.isAbsolute(view.destination_path) or view.destination_leaf.len == 0 or
        view.destination_leaf.len > std.fs.max_name_bytes or
        !std.mem.eql(u8, std.fs.path.basename(view.destination_path), view.destination_leaf) or
        !std.mem.eql(u8, view.destination_leaf, destinationName(view.source_kind)) or
        !lowerHex(&view.source_sha256)) return error.InvalidAuthority;
    var source: posix.Stat = undefined;
    var destination: posix.Stat = undefined;
    if (c.fstat(view.source_fd, &source) != 0 or c.fstat(view.destination_dir_fd, &destination) != 0 or
        !posix.S.ISREG(source.mode) or !posix.S.ISDIR(destination.mode) or
        (source.dev == destination.dev and source.ino == destination.ino)) return error.InvalidAuthority;
}

fn snapshotDestination(result: *Materialized, view: View) !void {
    result.path_len = view.destination_path.len;
    @memcpy(result.path[0..result.path_len], view.destination_path);
    result.path[result.path_len] = 0;
    result.leaf_len = view.destination_leaf.len;
    @memcpy(result.leaf[0..result.leaf_len], view.destination_leaf);
    result.leaf[result.leaf_len] = 0;
}

fn sameDestination(result: *const Materialized, view: View) bool {
    return std.mem.eql(u8, result.path[0..result.path_len], view.destination_path) and
        std.mem.eql(u8, result.leaf[0..result.leaf_len], view.destination_leaf);
}

fn sameView(a: View, b: View) bool {
    return a.source_fd == b.source_fd and a.source_size == b.source_size and a.source_kind == b.source_kind and
        std.mem.eql(u8, &a.source_sha256, &b.source_sha256) and
        a.destination_dir_fd == b.destination_dir_fd and
        std.mem.eql(u8, a.destination_path, b.destination_path) and
        std.mem.eql(u8, a.destination_leaf, b.destination_leaf);
}

fn sourceMode(kind: SourceKind) u32 {
    return switch (kind) {
        .predecessor_download => 0o400,
        .current_candidate => 0o600,
    };
}

fn destinationName(kind: SourceKind) []const u8 {
    return switch (kind) {
        .predecessor_download => "predecessor-executable",
        .current_candidate => "current-executable",
    };
}

fn abort(result: *Materialized) !void {
    if (result.fd >= 0 and result.present) {
        var held: posix.Stat = undefined;
        var named: posix.Stat = undefined;
        if (c.fstat(result.fd, &held) != 0 or
            c.fstatat(result.dir_fd, result.leaf[0..].ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            held.dev != named.dev or held.ino != named.ino or
            c.unlinkat(result.dir_fd, result.leaf[0..].ptr, 0) != 0) return error.CleanupFailed;
        result.present = false;
    }
    if (result.dir_fd >= 0) {
        if (c.fsync(result.dir_fd) != 0) return error.CleanupFailed;
    }
    if (result.fd >= 0) _ = c.close(result.fd);
    if (result.dir_fd >= 0) _ = c.close(result.dir_fd);
    result.* = .{};
}

fn pristine(result: *const Materialized) bool {
    return result.owner == null and result.fd < 0 and result.dir_fd < 0 and !result.present and
        result.source_device == 0 and result.source_inode == 0 and result.dir_device == 0 and result.dir_inode == 0 and
        result.device == 0 and result.inode == 0 and result.size == 0 and result.path_len == 0 and result.leaf_len == 0 and
        std.mem.allEqual(u8, &result.sha256, 0) and std.mem.allEqual(u8, &result.path, 0) and
        std.mem.allEqual(u8, &result.leaf, 0);
}

fn lowerHex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
