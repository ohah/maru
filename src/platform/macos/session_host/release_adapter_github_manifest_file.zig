//! Untrusted predecessor manifest bytes를 attestation용 descriptor-owned file로 materialize한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const manifest = @import("release_manifest");
const identity = @import("release_adapter_identity");
const safe_open = @import("safe_open");

const prefix = "Maru-";
const suffix = "-session-host-release.json";
const f_preallocate: c_int = 42;
const f_allocate_all: c_uint = 0x00000004;
const f_peof_posmode: c_int = 3;

const FStore = extern struct {
    flags: c_uint,
    posmode: c_int,
    offset: i64,
    length: i64,
    bytes_allocated: i64,
};

pub const Error = error{
    InvalidObserved,
    InvalidPath,
    DestinationExists,
    CreateFailed,
    InsufficientSpace,
    WriteFailed,
    DigestMismatch,
    ChangedDuringWrite,
    SyncFailed,
    CleanupFailed,
};

pub const Observation = struct {
    path: []const u8,
    device: u64,
    inode: u64,
    size: u64,
    sha256: []const u8,
};

pub const Input = struct {
    name: []const u8,
    sha256: []const u8,
    bytes: []const u8,
};

pub const ManifestFile = struct {
    owner: ?*ManifestFile = null,
    parent_fd: c.fd_t = -1,
    dir_fd: c.fd_t = -1,
    work_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    dir_name: [std.fs.max_name_bytes:0]u8 = @splat(0),
    file_name: [std.fs.max_name_bytes:0]u8 = @splat(0),
    file_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    parent_device: u64 = 0,
    parent_inode: u64 = 0,
    dir_device: u64 = 0,
    dir_inode: u64 = 0,
    file_device: u64 = 0,
    file_inode: u64 = 0,
    file_size: u64 = 0,
    sha256: [64]u8 = @splat(0),
    file_present: bool = false,

    pub fn observation(self: *const ManifestFile) ?Observation {
        if (self.owner != self or !self.file_present) return null;
        return .{
            .path = std.mem.sliceTo(&self.file_path, 0),
            .device = self.file_device,
            .inode = self.file_inode,
            .size = self.file_size,
            .sha256 = &self.sha256,
        };
    }

    pub fn revalidate(self: *const ManifestFile) Error!Observation {
        const observed = self.observation() orelse return error.ChangedDuringWrite;
        const work_path = std.mem.sliceTo(&self.work_path, 0);
        const slash = std.mem.lastIndexOfScalar(u8, work_path, '/') orelse return error.ChangedDuringWrite;
        var parent_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const parent_path = if (slash == 0) "/" else std.fmt.bufPrintZ(&parent_storage, "{s}", .{work_path[0..slash]}) catch return error.ChangedDuringWrite;
        const current_parent = safe_open.openAbsoluteNoFollow(parent_path, true) catch return error.ChangedDuringWrite;
        defer _ = c.close(current_parent);
        var parent_stat: posix.Stat = undefined;
        var dir_by_name: posix.Stat = undefined;
        if (c.fstat(current_parent, &parent_stat) != 0 or !posix.S.ISDIR(parent_stat.mode) or
            parent_stat.dev != self.parent_device or parent_stat.ino != self.parent_inode or
            c.fstatat(current_parent, self.dir_name[0..].ptr, &dir_by_name, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !posix.S.ISDIR(dir_by_name.mode) or dir_by_name.dev != self.dir_device or dir_by_name.ino != self.dir_inode or
            dir_by_name.mode & 0o777 != 0o700)
            return error.ChangedDuringWrite;
        var dir_stat: posix.Stat = undefined;
        if (self.dir_fd < 0 or c.fstat(self.dir_fd, &dir_stat) != 0 or !posix.S.ISDIR(dir_stat.mode) or
            dir_stat.dev != self.dir_device or dir_stat.ino != self.dir_inode or dir_stat.mode & 0o777 != 0o700)
            return error.ChangedDuringWrite;
        const fd = c.openat(self.dir_fd, self.file_name[0..].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
        if (fd < 0) return error.ChangedDuringWrite;
        defer _ = c.close(fd);
        var stat: posix.Stat = undefined;
        if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.dev != self.file_device or
            stat.ino != self.file_inode or stat.size != self.file_size or stat.nlink != 1 or stat.mode & 0o777 != 0o400)
            return error.ChangedDuringWrite;
        var bytes: [manifest.max_manifest_bytes]u8 = undefined;
        var count: usize = 0;
        while (count < self.file_size) {
            const amount = c.pread(fd, bytes[count..].ptr, self.file_size - count, @intCast(count));
            if (amount < 0) {
                if (posix.errno(-1) == .INTR) continue;
                return error.ChangedDuringWrite;
            }
            if (amount == 0) return error.ChangedDuringWrite;
            count += @intCast(amount);
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes[0..count], &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &hex, &self.sha256)) return error.ChangedDuringWrite;
        return observed;
    }

    pub fn cleanup(self: *ManifestFile) Error!void {
        if (self.owner != self) return error.CleanupFailed;
        if (self.file_present) {
            var by_name: posix.Stat = undefined;
            if (self.dir_fd < 0 or c.fstatat(self.dir_fd, self.file_name[0..].ptr, &by_name, posix.AT.SYMLINK_NOFOLLOW) != 0 or
                !posix.S.ISREG(by_name.mode) or by_name.dev != self.file_device or by_name.ino != self.file_inode or
                c.unlinkat(self.dir_fd, self.file_name[0..].ptr, 0) != 0)
                return error.CleanupFailed;
            self.file_present = false;
        }
        if (self.dir_fd >= 0) {
            if (c.fsync(self.dir_fd) != 0) return error.CleanupFailed;
            _ = c.close(self.dir_fd);
            self.dir_fd = -1;
        }
        if (self.parent_fd >= 0) {
            var by_name: posix.Stat = undefined;
            if (c.fstatat(self.parent_fd, self.dir_name[0..].ptr, &by_name, posix.AT.SYMLINK_NOFOLLOW) != 0 or
                !posix.S.ISDIR(by_name.mode) or by_name.dev != self.dir_device or by_name.ino != self.dir_inode or
                c.unlinkat(self.parent_fd, self.dir_name[0..].ptr, posix.AT.REMOVEDIR) != 0 or c.fsync(self.parent_fd) != 0)
                return error.CleanupFailed;
            _ = c.close(self.parent_fd);
            self.parent_fd = -1;
        }
        self.owner = null;
    }
};

pub fn materialize(file: *ManifestFile, workdir: [:0]const u8, observed: Input) Error!void {
    if (file.owner != null or file.parent_fd >= 0 or file.dir_fd >= 0) return error.CreateFailed;
    try validateObserved(observed);
    createWorkDir(file, workdir) catch |err| {
        if (file.owner != null) file.cleanup() catch return error.CleanupFailed;
        return err;
    };
    writeManifest(file, observed) catch |err| {
        file.cleanup() catch return error.CleanupFailed;
        return err;
    };
}

fn validateObserved(observed: Input) Error!void {
    if (observed.bytes.len == 0 or observed.bytes.len > manifest.max_manifest_bytes or
        !identity.lowerHex(observed.sha256, 64) or !canonicalManifestName(observed.name))
        return error.InvalidObserved;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(observed.bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, observed.sha256)) return error.InvalidObserved;
}

fn canonicalManifestName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, suffix) or name.len > std.fs.max_name_bytes) return false;
    const version = name[prefix.len .. name.len - suffix.len];
    var tag_storage: [manifest.max_scalar_string_bytes]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_storage, "v{s}", .{version}) catch return false;
    return identity.canonicalTag(tag);
}

fn createWorkDir(file: *ManifestFile, path: [:0]const u8) Error!void {
    if (path.len < 2 or path[0] != '/') return error.InvalidPath;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidPath;
    const leaf = path[slash + 1 ..];
    if (!validComponent(leaf)) return error.InvalidPath;
    _ = std.fmt.bufPrintZ(&file.work_path, "{s}", .{path}) catch return error.InvalidPath;
    _ = std.fmt.bufPrintZ(&file.dir_name, "{s}", .{leaf}) catch return error.InvalidPath;
    var parent_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent = if (slash == 0) "/" else std.fmt.bufPrintZ(&parent_storage, "{s}", .{path[0..slash]}) catch return error.InvalidPath;
    file.parent_fd = safe_open.openAbsoluteNoFollow(parent, true) catch return error.InvalidPath;
    file.owner = file;
    var parent_stat: posix.Stat = undefined;
    if (c.fstat(file.parent_fd, &parent_stat) != 0 or !posix.S.ISDIR(parent_stat.mode)) return error.CreateFailed;
    file.parent_device = @intCast(parent_stat.dev);
    file.parent_inode = @intCast(parent_stat.ino);
    if (c.mkdirat(file.parent_fd, file.dir_name[0..].ptr, 0o700) != 0) {
        const err: Error = if (posix.errno(-1) == .EXIST) error.DestinationExists else error.CreateFailed;
        _ = c.close(file.parent_fd);
        file.parent_fd = -1;
        file.owner = null;
        return err;
    }
    var by_name: posix.Stat = undefined;
    if (c.fstatat(file.parent_fd, file.dir_name[0..].ptr, &by_name, posix.AT.SYMLINK_NOFOLLOW) != 0 or !posix.S.ISDIR(by_name.mode)) return error.SyncFailed;
    file.dir_device = @intCast(by_name.dev);
    file.dir_inode = @intCast(by_name.ino);
    file.dir_fd = c.openat(file.parent_fd, file.dir_name[0..].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (file.dir_fd < 0) return error.CreateFailed;
    var by_fd: posix.Stat = undefined;
    if (c.fstat(file.dir_fd, &by_fd) != 0 or !posix.S.ISDIR(by_fd.mode) or by_name.dev != by_fd.dev or by_name.ino != by_fd.ino or
        by_fd.mode & 0o777 != 0o700 or c.fsync(file.dir_fd) != 0 or c.fsync(file.parent_fd) != 0)
        return error.SyncFailed;
}

fn writeManifest(file: *ManifestFile, observed: Input) Error!void {
    const name = std.fmt.bufPrintZ(&file.file_name, "{s}", .{observed.name}) catch return error.InvalidObserved;
    _ = std.fmt.bufPrintZ(&file.file_path, "{s}/{s}", .{ std.mem.sliceTo(&file.work_path, 0), observed.name }) catch return error.InvalidPath;
    const fd = c.openat(file.dir_fd, name.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return if (posix.errno(-1) == .EXIST) error.DestinationExists else error.CreateFailed;
    defer _ = c.close(fd);
    var initial: posix.Stat = undefined;
    if (c.fstat(fd, &initial) != 0 or !posix.S.ISREG(initial.mode) or initial.nlink != 1) return error.CreateFailed;
    file.file_device = @intCast(initial.dev);
    file.file_inode = @intCast(initial.ino);
    file.file_size = observed.bytes.len;
    @memcpy(&file.sha256, observed.sha256);
    file.file_present = true;
    try reserveExact(fd, observed.bytes.len);
    var written: usize = 0;
    while (written < observed.bytes.len) {
        const amount = c.pwrite(fd, observed.bytes[written..].ptr, observed.bytes.len - written, @intCast(written));
        if (amount < 0) {
            if (posix.errno(-1) == .INTR) continue;
            return error.WriteFailed;
        }
        if (amount == 0) return error.WriteFailed;
        written += @intCast(amount);
    }
    var readback: [manifest.max_manifest_bytes]u8 = undefined;
    var read_count: usize = 0;
    while (read_count < observed.bytes.len) {
        const amount = c.pread(fd, readback[read_count..].ptr, observed.bytes.len - read_count, @intCast(read_count));
        if (amount < 0) {
            if (posix.errno(-1) == .INTR) continue;
            return error.WriteFailed;
        }
        if (amount == 0) return error.WriteFailed;
        read_count += @intCast(amount);
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(readback[0..read_count], &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, observed.sha256)) return error.DigestMismatch;
    if (c.fsync(fd) != 0) return error.SyncFailed;
    var final: posix.Stat = undefined;
    var final_by_name: posix.Stat = undefined;
    if (c.fstat(fd, &final) != 0 or !posix.S.ISREG(final.mode) or final.nlink != 1 or final.dev != initial.dev or final.ino != initial.ino or
        final.size != observed.bytes.len or c.fstatat(file.dir_fd, name.ptr, &final_by_name, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !posix.S.ISREG(final_by_name.mode) or final_by_name.dev != final.dev or final_by_name.ino != final.ino)
        return error.ChangedDuringWrite;
    if (c.fchmod(fd, 0o400) != 0 or c.fsync(fd) != 0 or c.fsync(file.dir_fd) != 0) return error.SyncFailed;
    var sealed: posix.Stat = undefined;
    var sealed_dir: posix.Stat = undefined;
    if (c.fstatat(file.dir_fd, name.ptr, &sealed, posix.AT.SYMLINK_NOFOLLOW) != 0 or !posix.S.ISREG(sealed.mode) or
        sealed.dev != final.dev or sealed.ino != final.ino or sealed.size != observed.bytes.len or sealed.nlink != 1 or sealed.mode & 0o777 != 0o400 or
        c.fstat(file.dir_fd, &sealed_dir) != 0 or !posix.S.ISDIR(sealed_dir.mode) or sealed_dir.dev != file.dir_device or sealed_dir.ino != file.dir_inode)
        return error.ChangedDuringWrite;
}

fn reserveExact(fd: c.fd_t, len: usize) Error!void {
    const exact = std.math.cast(i64, len) orelse return error.InsufficientSpace;
    var store: FStore = .{ .flags = f_allocate_all, .posmode = f_peof_posmode, .offset = 0, .length = exact, .bytes_allocated = 0 };
    if (c.fcntl(fd, f_preallocate, &store) < 0 or store.bytes_allocated < exact or c.ftruncate(fd, exact) != 0) return error.InsufficientSpace;
}

fn validComponent(value: []const u8) bool {
    return value.len > 0 and value.len <= std.fs.max_name_bytes and !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..") and
        std.mem.indexOfScalar(u8, value, '/') == null;
}
