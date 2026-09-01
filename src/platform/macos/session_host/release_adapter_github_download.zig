//! GitHub predecessor release assets의 descriptor-owned download boundary.
//!
//! `gh`에는 pathname을 주지 않는다. 이 모듈이 nofollow 디렉터리와 파일을 독점 생성하고 정확한
//! 크기를 예약한 뒤, 그 파일의 shared mapping을 bounded stdout capture의 유일한 목적지로 제공한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const manifest = @import("release_manifest");
const identity = @import("release_adapter_identity");
const process = @import("bounded_process");
const safe_open = @import("safe_open");
const download_command = @import("release_adapter_github_download_command");
const release_files = @import("release_adapter_files");

const max_assets = @typeInfo(manifest.AssetRole).@"enum".fields.len;
const max_args = 9;
const max_token_bytes = manifest.max_scalar_string_bytes;
const ms_sync: i32 = 0x10;
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
    InvalidExpected,
    InvalidPath,
    InvalidToken,
    InvalidBudget,
    InvalidCapture,
    DestinationExists,
    CreateFailed,
    InsufficientSpace,
    MapFailed,
    SizeMismatch,
    DigestMismatch,
    ChangedDuringDownload,
    FileChanged,
    SyncFailed,
    CleanupFailed,
} || process.Error;

pub const Expected = struct {
    tag: []const u8,
    assets: []const manifest.Asset,
};

pub const PlanStorage = download_command.PlanStorage;
pub const Plan = download_command.Plan;

const FileRecord = struct {
    role: manifest.AssetRole = .universal_dmg,
    name: [std.fs.max_name_bytes:0]u8 = @splat(0),
    path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    device: u64 = 0,
    inode: u64 = 0,
    size: u64 = 0,
    sha256: [64]u8 = @splat(0),
    present: bool = false,
};

pub const DownloadedAsset = struct {
    role: manifest.AssetRole,
    path: []const u8,
    device: u64,
    inode: u64,
    size: u64,
    sha256: []const u8,
};

pub const DownloadedSet = struct {
    owner: ?*DownloadedSet = null,
    parent_fd: c.fd_t = -1,
    dir_fd: c.fd_t = -1,
    work_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    dir_name: [std.fs.max_name_bytes:0]u8 = @splat(0),
    dir_device: u64 = 0,
    dir_inode: u64 = 0,
    files: [max_assets]FileRecord = @splat(.{}),
    file_count: usize = 0,

    pub fn count(self: *const DownloadedSet) usize {
        return self.file_count;
    }

    pub fn asset(self: *const DownloadedSet, role: manifest.AssetRole) ?DownloadedAsset {
        if (self.owner != self) return null;
        for (self.files[0..self.file_count]) |*record| {
            if (record.role != role) continue;
            return .{
                .role = role,
                .path = std.mem.sliceTo(&record.path, 0),
                .device = record.device,
                .inode = record.inode,
                .size = record.size,
                .sha256 = &record.sha256,
            };
        }
        return null;
    }

    pub fn revalidate(self: *const DownloadedSet) Error!void {
        if (self.owner != self or self.parent_fd < 0 or self.dir_fd < 0 or self.file_count != max_assets)
            return error.FileChanged;
        const work_path = std.mem.sliceTo(&self.work_path, 0);
        var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_storage, "{s}", .{work_path}) catch return error.FileChanged;
        const reopened = safe_open.openAbsoluteNoFollow(path_z, true) catch return error.FileChanged;
        defer _ = c.close(reopened);
        var path_dir: posix.Stat = undefined;
        var held_dir: posix.Stat = undefined;
        if (c.fstat(reopened, &path_dir) != 0 or c.fstat(self.dir_fd, &held_dir) != 0 or
            !posix.S.ISDIR(path_dir.mode) or path_dir.dev != self.dir_device or path_dir.ino != self.dir_inode or
            held_dir.dev != self.dir_device or held_dir.ino != self.dir_inode or held_dir.mode & 0o777 != 0o700)
            return error.FileChanged;
        for (self.files[0..self.file_count]) |*record| {
            if (!record.present) return error.FileChanged;
            const fd = c.openat(self.dir_fd, record.name[0..].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
            if (fd < 0) return error.FileChanged;
            defer _ = c.close(fd);
            var observed: posix.Stat = undefined;
            if (c.fstat(fd, &observed) != 0 or !posix.S.ISREG(observed.mode) or observed.dev != record.device or
                observed.ino != record.inode or observed.size != record.size or observed.nlink != 1 or observed.mode & 0o777 != 0o400)
                return error.FileChanged;
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            var bytes: [64 * 1024]u8 = undefined;
            while (true) {
                const read_count = c.read(fd, &bytes, bytes.len);
                if (read_count < 0) return error.FileChanged;
                if (read_count == 0) break;
                hasher.update(bytes[0..@intCast(read_count)]);
            }
            var digest: [32]u8 = undefined;
            hasher.final(&digest);
            const hex = std.fmt.bytesToHex(digest, .lower);
            if (!std.mem.eql(u8, &hex, &record.sha256)) return error.FileChanged;
        }
    }

    pub fn cleanup(self: *DownloadedSet) Error!void {
        if (self.owner != self) return error.CleanupFailed;
        var failed = false;
        if (self.dir_fd >= 0) {
            var index = self.file_count;
            while (index > 0) {
                index -= 1;
                const record = &self.files[index];
                if (!record.present) continue;
                var observed: posix.Stat = undefined;
                if (c.fstatat(self.dir_fd, record.name[0..].ptr, &observed, posix.AT.SYMLINK_NOFOLLOW) != 0 or
                    !posix.S.ISREG(observed.mode) or observed.dev != record.device or observed.ino != record.inode or
                    c.unlinkat(self.dir_fd, record.name[0..].ptr, 0) != 0)
                {
                    failed = true;
                    continue;
                }
                record.present = false;
            }
            if (c.fsync(self.dir_fd) != 0) failed = true;
            if (failed) return error.CleanupFailed;
            _ = c.close(self.dir_fd);
            self.dir_fd = -1;
        }
        if (self.parent_fd >= 0) {
            var observed: posix.Stat = undefined;
            if (c.fstatat(self.parent_fd, self.dir_name[0..].ptr, &observed, posix.AT.SYMLINK_NOFOLLOW) != 0 or
                !posix.S.ISDIR(observed.mode) or observed.dev != self.dir_device or observed.ino != self.dir_inode or
                c.unlinkat(self.parent_fd, self.dir_name[0..].ptr, posix.AT.REMOVEDIR) != 0)
                return error.CleanupFailed;
            if (c.fsync(self.parent_fd) != 0) return error.CleanupFailed;
            _ = c.close(self.parent_fd);
            self.parent_fd = -1;
        }
        self.owner = null;
        self.file_count = 0;
    }
};

pub fn plan(storage: *PlanStorage, tag: []const u8, asset: manifest.Asset) Error!Plan {
    if (!identity.canonicalTag(tag) or !validAsset(asset)) return error.InvalidExpected;
    return download_command.plan(storage, tag, asset.name) catch return error.InvalidExpected;
}

pub fn validateExpected(expected: Expected) Error!void {
    if (!identity.canonicalTag(expected.tag) or expected.assets.len != max_assets) return error.InvalidExpected;
    var seen: [max_assets]bool = @splat(false);
    for (expected.assets, 0..) |asset, index| {
        if (!validAsset(asset)) return error.InvalidExpected;
        const role: usize = @intFromEnum(asset.role);
        if (seen[role]) return error.InvalidExpected;
        seen[role] = true;
        for (expected.assets[0..index]) |prior| if (std.mem.eql(u8, prior.name, asset.name)) return error.InvalidExpected;
    }
    for (seen) |value| if (!value) return error.InvalidExpected;
}

pub fn downloadAllWith(set: *DownloadedSet, executor: anytype, executable: []const u8, token: []const u8, workdir: [:0]const u8, expected: Expected, budget_ns: i128) Error!void {
    if (set.owner != null or set.parent_fd >= 0 or set.dir_fd >= 0) return error.CreateFailed;
    if (executable.len < 2 or executable[0] != '/' or !validScalar(executable)) return error.InvalidPath;
    if (!validScalar(token)) return error.InvalidToken;
    if (budget_ns <= 0) return error.InvalidBudget;
    try validateExpected(expected);
    createWorkDir(set, workdir) catch |err| {
        if (set.owner != null) set.cleanup() catch return error.CleanupFailed;
        return err;
    };
    downloadAssets(set, executor, executable, token, expected, budget_ns) catch |err| {
        set.cleanup() catch return error.CleanupFailed;
        return err;
    };
}

pub fn downloadAll(set: *DownloadedSet, io: std.Io, executable: []const u8, token: []const u8, workdir: [:0]const u8, expected: Expected, budget_ns: i128) Error!void {
    var executor = BoundedExecutor{ .io = io };
    return downloadAllWith(set, &executor, executable, token, workdir, expected, budget_ns);
}

fn downloadAssets(set: *DownloadedSet, executor: anytype, executable: []const u8, token: []const u8, expected: Expected, budget_ns: i128) Error!void {
    var token_storage: ["GH_TOKEN=".len + max_token_bytes]u8 = undefined;
    const token_entry = std.fmt.bufPrint(&token_storage, "GH_TOKEN={s}", .{token}) catch return error.InvalidToken;
    const environment = [_][]const u8{ token_entry, "GH_PROMPT_DISABLED=1" };
    for (0..max_assets) |role_index| {
        const role: manifest.AssetRole = @enumFromInt(role_index);
        var selected: ?manifest.Asset = null;
        for (expected.assets) |asset| if (asset.role == role) {
            selected = asset;
            break;
        };
        const asset = selected orelse return error.InvalidExpected;
        try downloadOne(set, executor, executable, &environment, expected.tag, asset, budget_ns);
    }
}

fn downloadOne(set: *DownloadedSet, executor: anytype, executable: []const u8, environment: []const []const u8, tag: []const u8, asset: manifest.Asset, budget_ns: i128) Error!void {
    const record = &set.files[set.file_count];
    const name = std.fmt.bufPrintZ(&record.name, "{s}", .{asset.name}) catch return error.InvalidExpected;
    const work_path = std.mem.sliceTo(&set.work_path, 0);
    _ = std.fmt.bufPrintZ(&record.path, "{s}/{s}", .{ work_path, asset.name }) catch return error.InvalidPath;
    const fd = c.openat(set.dir_fd, name.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return if (posix.errno(-1) == .EXIST) error.DestinationExists else error.CreateFailed;
    defer _ = c.close(fd);
    var initial: posix.Stat = undefined;
    if (c.fstat(fd, &initial) != 0 or !posix.S.ISREG(initial.mode) or initial.nlink != 1) return error.CreateFailed;
    record.device = @intCast(initial.dev);
    record.inode = @intCast(initial.ino);
    record.role = asset.role;
    record.size = asset.size;
    @memcpy(&record.sha256, asset.sha256);
    record.present = true;
    set.file_count += 1;
    const size: usize = @intCast(asset.size);
    try reserveExact(fd, size);
    const mapped = posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch return error.MapFailed;
    defer posix.munmap(mapped);
    var storage: PlanStorage = undefined;
    const request = try plan(&storage, tag, asset);
    const captured = executor.capture(executable, request.args, environment, mapped, budget_ns) catch |narrow_err| switch (@as(anyerror, narrow_err)) {
        error.InvalidExecutable => return error.InvalidExecutable,
        error.InvalidBudget => return error.InvalidBudget,
        error.PipeFailed => return error.PipeFailed,
        error.SpawnSetupFailed => return error.SpawnSetupFailed,
        error.SpawnFailed => return error.SpawnFailed,
        error.ProcessGroupFailed => return error.ProcessGroupFailed,
        error.CaptureFailed => return error.CaptureFailed,
        error.OutputTooLarge => return error.OutputTooLarge,
        error.TimedOut => return error.TimedOut,
        error.WaitFailed => return error.WaitFailed,
        error.ChildFailed => return error.ChildFailed,
        else => return error.CaptureFailed,
    };
    if (captured.ptr != mapped.ptr) return error.InvalidCapture;
    if (captured.len != mapped.len) return error.SizeMismatch;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(mapped, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, asset.sha256)) return error.DigestMismatch;
    posix.msync(mapped, ms_sync) catch return error.SyncFailed;
    if (c.fsync(fd) != 0) return error.SyncFailed;
    var final: posix.Stat = undefined;
    var final_by_name: posix.Stat = undefined;
    if (c.fstat(fd, &final) != 0 or !posix.S.ISREG(final.mode) or final.nlink != 1 or
        final.dev != initial.dev or final.ino != initial.ino or final.size != asset.size or
        c.fstatat(set.dir_fd, name.ptr, &final_by_name, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !posix.S.ISREG(final_by_name.mode) or final_by_name.dev != final.dev or final_by_name.ino != final.ino)
        return error.ChangedDuringDownload;
    if (c.fchmod(fd, 0o400) != 0 or c.fsync(fd) != 0 or c.fsync(set.dir_fd) != 0) return error.SyncFailed;
    var sealed_by_name: posix.Stat = undefined;
    var sealed_dir: posix.Stat = undefined;
    if (c.fstatat(set.dir_fd, name.ptr, &sealed_by_name, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !posix.S.ISREG(sealed_by_name.mode) or sealed_by_name.dev != final.dev or sealed_by_name.ino != final.ino or
        sealed_by_name.size != asset.size or sealed_by_name.nlink != 1 or sealed_by_name.mode & 0o777 != 0o400 or
        c.fstat(set.dir_fd, &sealed_dir) != 0 or !posix.S.ISDIR(sealed_dir.mode) or
        sealed_dir.dev != set.dir_device or sealed_dir.ino != set.dir_inode)
        return error.ChangedDuringDownload;
}

fn createWorkDir(set: *DownloadedSet, path: [:0]const u8) Error!void {
    if (path.len < 2 or path[0] != '/') return error.InvalidPath;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidPath;
    const leaf = path[slash + 1 ..];
    if (!validComponent(leaf)) return error.InvalidPath;
    _ = std.fmt.bufPrintZ(&set.work_path, "{s}", .{path}) catch return error.InvalidPath;
    _ = std.fmt.bufPrintZ(&set.dir_name, "{s}", .{leaf}) catch return error.InvalidPath;
    var parent_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent = if (slash == 0) "/" else std.fmt.bufPrintZ(&parent_storage, "{s}", .{path[0..slash]}) catch return error.InvalidPath;
    set.parent_fd = safe_open.openAbsoluteNoFollow(parent, true) catch return error.InvalidPath;
    set.owner = set;
    if (c.mkdirat(set.parent_fd, set.dir_name[0..].ptr, 0o700) != 0) {
        const create_error: Error = if (posix.errno(-1) == .EXIST) error.DestinationExists else error.CreateFailed;
        _ = c.close(set.parent_fd);
        set.parent_fd = -1;
        set.owner = null;
        return create_error;
    }
    var by_name: posix.Stat = undefined;
    if (c.fstatat(set.parent_fd, set.dir_name[0..].ptr, &by_name, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !posix.S.ISDIR(by_name.mode)) return error.SyncFailed;
    set.dir_device = @intCast(by_name.dev);
    set.dir_inode = @intCast(by_name.ino);
    set.dir_fd = c.openat(set.parent_fd, set.dir_name[0..].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (set.dir_fd < 0) return error.CreateFailed;
    var by_fd: posix.Stat = undefined;
    if (c.fstat(set.dir_fd, &by_fd) != 0 or !posix.S.ISDIR(by_fd.mode) or by_name.dev != by_fd.dev or
        by_name.ino != by_fd.ino or by_fd.mode & 0o777 != 0o700 or c.fsync(set.dir_fd) != 0 or c.fsync(set.parent_fd) != 0)
        return error.SyncFailed;
}

fn reserveExact(fd: c.fd_t, len: usize) Error!void {
    const exact = std.math.cast(i64, len) orelse return error.InsufficientSpace;
    var store: FStore = .{ .flags = f_allocate_all, .posmode = f_peof_posmode, .offset = 0, .length = exact, .bytes_allocated = 0 };
    if (c.fcntl(fd, f_preallocate, &store) < 0 or store.bytes_allocated < exact or c.ftruncate(fd, exact) != 0)
        return error.InsufficientSpace;
}

fn validAsset(asset: manifest.Asset) bool {
    return asset.size > 0 and asset.size <= release_files.max_release_asset_bytes and identity.lowerHex(asset.sha256, 64) and validComponent(asset.name);
}

fn validComponent(value: []const u8) bool {
    return value.len > 0 and value.len <= std.fs.max_name_bytes and !std.mem.eql(u8, value, ".") and
        !std.mem.eql(u8, value, "..") and std.mem.indexOfScalar(u8, value, '/') == null and validScalar(value);
}

fn validScalar(value: []const u8) bool {
    if (value.len == 0 or value.len > max_token_bytes) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

pub const BoundedExecutor = struct {
    io: std.Io,
    pub fn capture(self: *@This(), executable: []const u8, child_args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) Error![]const u8 {
        var executable_storage: [max_token_bytes + 1]u8 = undefined;
        const executable_z = std.fmt.bufPrintZ(&executable_storage, "{s}", .{executable}) catch return error.InvalidPath;
        var args_storage: [max_args][manifest.max_scalar_string_bytes + 1]u8 = undefined;
        var argv: [max_args + 1:null]?[*:0]const u8 = @splat(null);
        argv[0] = executable_z.ptr;
        for (child_args, 0..) |arg, index| argv[index + 1] = (std.fmt.bufPrintZ(&args_storage[index], "{s}", .{arg}) catch return error.InvalidExpected).ptr;
        var environment_storage: [2]["GH_TOKEN=".len + max_token_bytes + 1]u8 = undefined;
        var envp: [2:null]?[*:0]const u8 = @splat(null);
        for (environment, 0..) |entry, index| envp[index] = (std.fmt.bufPrintZ(&environment_storage[index], "{s}", .{entry}) catch return error.InvalidToken).ptr;
        return process.runCaptureEnvironmentStdout(self.io, executable_z, &argv, &envp, output, budget_ns);
    }
};
