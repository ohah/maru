//! Exact-ID, descriptor-owned downloads for the current immutable GitHub Release.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const metadata = @import("release_adapter_remote_release_metadata");
const fence_mod = @import("release_adapter_remote_release_fence");
const cli_authority = @import("release_adapter_github_cli_authority");
const transport = @import("release_adapter_github_transport");
const deadline_mod = @import("release_adapter_deadline");
const process = @import("bounded_process");
const safe_open = @import("safe_open");

const count = metadata.asset_count;
const max_args = 8;
const max_token_bytes = transport.max_token_bytes;

pub const PinnedExecutable = cli_authority.PinnedExecutable;
pub const Role = metadata.Role;
pub const Cli = struct { path: [:0]const u8, pinned: *const PinnedExecutable };

pub const Asset = struct {
    role: Role,
    id: u64,
    name: []const u8,
    path: [:0]const u8,
    device: u64,
    inode: u64,
    size: u64,
    sha256: []const u8,
};

pub const View = struct { assets: [count]Asset };

const Record = struct {
    id: u64 = 0,
    name: [metadata.max_name_bytes:0]u8 = @splat(0),
    name_len: usize = 0,
    path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    path_len: usize = 0,
    device: u64 = 0,
    inode: u64 = 0,
    size: u64 = 0,
    sha256: [64]u8 = @splat(0),
    present: bool = false,
};

pub const Assets = struct {
    owner: ?*@This() = null,
    fence_owner: ?*const fence_mod.Fence = null,
    deadline_owner: ?*deadline_mod.Deadline = null,
    pinned_owner: ?*const PinnedExecutable = null,
    parent_fd: c.fd_t = -1,
    dir_fd: c.fd_t = -1,
    dir_name: [std.fs.max_name_bytes:0]u8 = @splat(0),
    work_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    work_path_len: usize = 0,
    dir_device: u64 = 0,
    dir_inode: u64 = 0,
    files: [count]Record = @splat(.{}),
    file_count: usize = 0,
    dir_present: bool = false,
    complete: bool = false,
    seal: [32]u8 = @splat(0),

    pub fn value(self: *const @This()) ?View {
        if (!validOwner(self) or !self.complete or self.file_count != count) return null;
        var result: View = undefined;
        for (&result.assets, 0..) |*asset, index| {
            const file = &self.files[index];
            if (!file.present) return null;
            asset.* = .{ .role = @enumFromInt(index), .id = file.id, .name = file.name[0..file.name_len], .path = file.path[0..file.path_len :0], .device = file.device, .inode = file.inode, .size = file.size, .sha256 = &file.sha256 };
        }
        return result;
    }

    pub fn revalidate(self: *@This()) !View {
        const view = self.value() orelse return error.InvalidOwner;
        _ = self.fence_owner.?.candidateFor(self.deadline_owner.?, self.pinned_owner.?) orelse return error.InvalidFence;
        try validateDirectory(self);
        for (&self.files) |*file| try validateFile(self.dir_fd, file);
        return view;
    }

    pub fn openAssetDescriptor(self: *@This(), role: Role) !c.fd_t {
        _ = try self.revalidate();
        const file = &self.files[@intFromEnum(role)];
        const fd = c.openat(self.dir_fd, file.name[0..].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
        if (fd < 0) return error.FileChanged;
        errdefer _ = c.close(fd);
        try validateFd(fd, file);
        return fd;
    }

    pub fn deinit(self: *@This()) !void {
        if (!validOwner(self)) return error.InvalidOwner;
        try cleanup(self);
    }
};

pub fn downloadUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    release_fence: *const fence_mod.Fence,
    cli: Cli,
    token: []const u8,
    workspace: [:0]const u8,
    deadline: *deadline_mod.Deadline,
    result: *Assets,
) !void {
    var operations = SystemOperations{ .io = io };
    return downloadCore(&operations, allocator, release_fence, cli, token, workspace, deadline, result);
}

pub fn downloadUntilWith(
    operations: anytype,
    allocator: std.mem.Allocator,
    release_fence: *const fence_mod.Fence,
    cli: Cli,
    token: []const u8,
    workspace: [:0]const u8,
    deadline: *deadline_mod.Deadline,
    result: *Assets,
) !void {
    return downloadCore(operations, allocator, release_fence, cli, token, workspace, deadline, result);
}

const Frozen = struct {
    release_id: u64,
    ids: [count]u64,
    names: [count][metadata.max_name_bytes]u8 = @splat(@splat(0)),
    name_lens: [count]usize,
    sizes: [count]u64,
    sha256: [count][64]u8,

    fn asset(self: *const @This(), index: usize) metadata.Asset {
        return .{ .id = self.ids[index], .name = self.names[index][0..self.name_lens[index]], .size = self.sizes[index], .sha256 = &self.sha256[index] };
    }
};

fn downloadCore(operations: anytype, allocator: std.mem.Allocator, release_fence: *const fence_mod.Fence, cli: Cli, token: []const u8, workspace: [:0]const u8, deadline: *deadline_mod.Deadline, result: *Assets) !void {
    try validateInputs(release_fence, cli, token, workspace, deadline, result);
    const initial = release_fence.candidateFor(deadline, cli.pinned) orelse return error.InvalidFence;
    var frozen: Frozen = undefined;
    freeze(&frozen, initial);
    try prepare(result, workspace, release_fence, deadline, cli.pinned);

    for (0..count) |index| {
        const before = release_fence.candidateFor(deadline, cli.pinned) orelse return fail(result, error.InvalidFence);
        if (!same(&frozen, before)) return fail(result, error.InvalidFence);
        const expected = frozen.asset(index);
        createFile(result, index, expected) catch |err| return fail(result, err);
        operations.revalidateCli(allocator, cli.path, cli.pinned) catch |err| return fail(result, err);
        var plan: Plan = .{};
        makePlan(&plan, expected.id) catch |err| return fail(result, err);
        const download_fd = resultFileFd(result, index) catch |err| return fail(result, err);
        defer _ = c.close(download_fd);
        const budget = deadline.remaining() catch |err| return fail(result, err);
        const observed = operations.download(cli.path, token, &plan.args, download_fd, expected.size, budget) catch |err| return fail(result, err);
        operations.revalidateCli(allocator, cli.path, cli.pinned) catch |err| return fail(result, err);
        if (observed.size != expected.size or !std.mem.eql(u8, &observed.sha256, expected.sha256)) return fail(result, error.ContentMismatch);
        sealFile(result, index) catch |err| return fail(result, err);
        const after = release_fence.candidateFor(deadline, cli.pinned) orelse return fail(result, error.InvalidFence);
        if (!same(&frozen, after)) return fail(result, error.InvalidFence);
    }
    _ = deadline.remaining() catch |err| return fail(result, err);
    const final = release_fence.candidateFor(deadline, cli.pinned) orelse return fail(result, error.InvalidFence);
    if (!same(&frozen, final)) return fail(result, error.InvalidFence);
    validateDirectory(result) catch |err| return fail(result, err);
    for (result.files, 0..) |file, index| for (result.files[0..index]) |prior|
        if (file.device == prior.device and file.inode == prior.inode) return fail(result, error.AssetAlias);
    result.complete = true;
    result.seal = ownerSeal(result);
}

fn resultFileFd(result: *Assets, index: usize) !c.fd_t {
    const file = &result.files[index];
    const fd = c.openat(result.dir_fd, file.name[0..].ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.FileChanged;
    return fd;
}

const Plan = struct { endpoint: [96]u8 = undefined, endpoint_len: usize = 0, args: [max_args][]const u8 = undefined };

fn makePlan(result: *Plan, id: u64) !void {
    if (id == 0) return error.InvalidAsset;
    const endpoint = std.fmt.bufPrint(&result.endpoint, "repos/ohah/maru/releases/assets/{d}", .{id}) catch return error.InvalidAsset;
    result.endpoint_len = endpoint.len;
    const values = [_][]const u8{ "api", "--method", "GET", "--hostname", "github.com", "--header", "Accept: application/octet-stream", result.endpoint[0..result.endpoint_len] };
    for (values, 0..) |value, index| result.args[index] = value;
}

fn validateInputs(release_fence: *const fence_mod.Fence, cli: Cli, token: []const u8, workspace: []const u8, deadline: *deadline_mod.Deadline, result: *const Assets) !void {
    if (!pristine(result)) return error.InvalidOwner;
    if (cli.path.len < 2 or cli.path[0] != '/' or std.mem.indexOfScalar(u8, cli.path, 0) != null or
        workspace.len < 2 or workspace[0] != '/' or std.mem.indexOfScalar(u8, workspace, 0) != null) return error.InvalidInput;
    try transport.validateToken(token);
    const output = std.mem.asBytes(result);
    inline for (.{ std.mem.asBytes(release_fence), std.mem.asBytes(deadline), std.mem.asBytes(cli.pinned), cli.path, token, workspace }) |input|
        if (overlaps(output, input)) return error.InvalidOwner;
    const inputs = [_][]const u8{ std.mem.asBytes(release_fence), std.mem.asBytes(deadline), std.mem.asBytes(cli.pinned), cli.path, token, workspace };
    for (inputs, 0..) |input, index| for (inputs[0..index]) |prior|
        if (overlaps(input, prior)) return error.InvalidOwner;
    _ = try deadline.remaining();
}

fn freeze(result: *Frozen, view: metadata.View) void {
    result.* = .{ .release_id = view.release_id, .ids = undefined, .name_lens = undefined, .sizes = undefined, .sha256 = undefined };
    for (view.assets, 0..) |asset, index| {
        result.ids[index] = asset.id;
        result.name_lens[index] = asset.name.len;
        @memcpy(result.names[index][0..asset.name.len], asset.name);
        result.sizes[index] = asset.size;
        @memcpy(&result.sha256[index], asset.sha256);
    }
}

fn same(frozen: *const Frozen, view: metadata.View) bool {
    if (frozen.release_id != view.release_id) return false;
    for (view.assets, 0..) |asset, index| {
        const expected = frozen.asset(index);
        if (asset.id != expected.id or asset.size != expected.size or !std.mem.eql(u8, asset.name, expected.name) or !std.mem.eql(u8, asset.sha256, expected.sha256)) return false;
    }
    return true;
}

fn prepare(result: *Assets, path: [:0]const u8, release_fence: *const fence_mod.Fence, deadline: *deadline_mod.Deadline, pinned: *const PinnedExecutable) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidWorkspace;
    const leaf = path[slash + 1 ..];
    if (!validComponent(leaf)) return error.InvalidWorkspace;
    var parent_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent = if (slash == 0) "/" else std.fmt.bufPrintZ(&parent_storage, "{s}", .{path[0..slash]}) catch return error.InvalidWorkspace;
    result.parent_fd = safe_open.openAbsoluteNoFollow(parent, true) catch return error.InvalidWorkspace;
    result.owner = result;
    result.fence_owner = release_fence;
    result.deadline_owner = deadline;
    result.pinned_owner = pinned;
    _ = std.fmt.bufPrintZ(&result.dir_name, "{s}", .{leaf}) catch return fail(result, error.InvalidWorkspace);
    const work_path = std.fmt.bufPrintZ(&result.work_path, "{s}", .{path}) catch return fail(result, error.InvalidWorkspace);
    result.work_path_len = work_path.len;
    result.seal = ownerSeal(result);
    if (c.mkdirat(result.parent_fd, result.dir_name[0..].ptr, 0o700) != 0) return fail(result, if (posix.errno(-1) == .EXIST) error.WorkspaceExists else error.CreateFailed);
    result.dir_present = true;
    var named: posix.Stat = undefined;
    if (c.fstatat(result.parent_fd, result.dir_name[0..].ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or !posix.S.ISDIR(named.mode)) return fail(result, error.FileChanged);
    result.dir_device = @intCast(named.dev);
    result.dir_inode = @intCast(named.ino);
    result.dir_fd = c.openat(result.parent_fd, result.dir_name[0..].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (result.dir_fd < 0) return fail(result, error.CreateFailed);
    validateDirectory(result) catch |err| return fail(result, err);
}

fn createFile(result: *Assets, index: usize, expected: metadata.Asset) !void {
    const file = &result.files[index];
    file.id = expected.id;
    file.name_len = expected.name.len;
    @memcpy(file.name[0..file.name_len], expected.name);
    const path = std.fmt.bufPrintZ(&file.path, "{s}/{s}", .{ result.work_path[0..result.work_path_len], expected.name }) catch return error.InvalidAsset;
    file.path_len = path.len;
    file.size = expected.size;
    @memcpy(&file.sha256, expected.sha256);
    const fd = c.openat(result.dir_fd, file.name[0..].ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.CreateFailed;
    defer _ = c.close(fd);
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.nlink != 1) return error.CreateFailed;
    file.device = @intCast(stat.dev);
    file.inode = @intCast(stat.ino);
    file.present = true;
    result.file_count += 1;
    result.seal = ownerSeal(result);
}

fn sealFile(result: *Assets, index: usize) !void {
    const file = &result.files[index];
    const fd = c.openat(result.dir_fd, file.name[0..].ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.FileChanged;
    defer _ = c.close(fd);
    if (c.fsync(fd) != 0 or c.fchmod(fd, 0o400) != 0 or c.fsync(fd) != 0 or c.fsync(result.dir_fd) != 0 or c.fsync(result.parent_fd) != 0) return error.SyncFailed;
    try validateFile(result.dir_fd, file);
}

fn validateDirectory(result: *const Assets) !void {
    if (result.parent_fd < 0 or result.dir_fd < 0 or !result.dir_present) return error.FileChanged;
    var held: posix.Stat = undefined;
    var named: posix.Stat = undefined;
    if (c.fstat(result.dir_fd, &held) != 0 or c.fstatat(result.parent_fd, result.dir_name[0..].ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !posix.S.ISDIR(held.mode) or !posix.S.ISDIR(named.mode) or held.dev != named.dev or held.ino != named.ino or
        held.dev != result.dir_device or held.ino != result.dir_inode or held.mode & 0o777 != 0o700) return error.FileChanged;
}

fn validateFile(dir_fd: c.fd_t, file: *const Record) !void {
    const fd = c.openat(dir_fd, file.name[0..].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.FileChanged;
    defer _ = c.close(fd);
    try validateFd(fd, file);
}

fn validateFd(fd: c.fd_t, file: *const Record) !void {
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.dev != file.device or stat.ino != file.inode or
        stat.nlink != 1 or stat.mode & 0o777 != 0o400 or stat.size < 0 or @as(u64, @intCast(stat.size)) != file.size) return error.FileChanged;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: i64 = 0;
    while (true) {
        const amount = c.pread(fd, &buffer, buffer.len, offset);
        if (amount < 0 and posix.errno(amount) == .INTR) continue;
        if (amount < 0) return error.FileChanged;
        if (amount == 0) break;
        hasher.update(buffer[0..@intCast(amount)]);
        offset += amount;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), &file.sha256)) return error.FileChanged;
}

fn cleanup(result: *Assets) !void {
    if (result.owner != result) return error.InvalidOwner;
    var failed = false;
    var index = result.file_count;
    while (index > 0) {
        index -= 1;
        const file = &result.files[index];
        if (!file.present) continue;
        var named: posix.Stat = undefined;
        if (c.fstatat(result.dir_fd, file.name[0..].ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0) {
            if (posix.errno(-1) == .NOENT) file.present = false else failed = true;
        } else if (!posix.S.ISREG(named.mode) or named.dev != file.device or named.ino != file.inode) {
            failed = true;
        } else if (c.unlinkat(result.dir_fd, file.name[0..].ptr, 0) != 0) {
            failed = true;
        } else file.present = false;
    }
    if (failed) {
        result.seal = ownerSeal(result);
        return error.CleanupFailed;
    }
    if (result.dir_fd >= 0) {
        if (c.fsync(result.dir_fd) != 0 or c.close(result.dir_fd) != 0) {
            result.seal = ownerSeal(result);
            return error.CleanupFailed;
        }
        result.dir_fd = -1;
    }
    if (result.dir_present) {
        var named: posix.Stat = undefined;
        if (c.fstatat(result.parent_fd, result.dir_name[0..].ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !posix.S.ISDIR(named.mode) or named.dev != result.dir_device or named.ino != result.dir_inode or
            c.unlinkat(result.parent_fd, result.dir_name[0..].ptr, posix.AT.REMOVEDIR) != 0)
        {
            result.seal = ownerSeal(result);
            return error.CleanupFailed;
        }
        result.dir_present = false;
    }
    if (result.parent_fd >= 0) {
        if (c.fsync(result.parent_fd) != 0 or c.close(result.parent_fd) != 0) {
            result.seal = ownerSeal(result);
            return error.CleanupFailed;
        }
        result.parent_fd = -1;
    }
    result.* = .{};
}

fn fail(result: *Assets, err: anyerror) anyerror {
    cleanup(result) catch return error.CleanupFailed;
    return err;
}

fn pristine(result: *const Assets) bool {
    if (!(result.owner == null and result.fence_owner == null and result.deadline_owner == null and result.pinned_owner == null and
        result.parent_fd < 0 and result.dir_fd < 0 and result.file_count == 0 and !result.dir_present and !result.complete and
        result.work_path_len == 0 and result.dir_device == 0 and result.dir_inode == 0 and
        std.mem.allEqual(u8, std.mem.asBytes(&result.dir_name), 0) and
        std.mem.allEqual(u8, std.mem.asBytes(&result.work_path), 0) and
        std.mem.allEqual(u8, &result.seal, 0))) return false;
    for (&result.files) |*file| if (!recordPristine(file)) return false;
    return true;
}

fn recordPristine(file: *const Record) bool {
    return file.id == 0 and file.name_len == 0 and file.path_len == 0 and file.device == 0 and file.inode == 0 and file.size == 0 and
        !file.present and std.mem.allEqual(u8, std.mem.asBytes(&file.name), 0) and
        std.mem.allEqual(u8, std.mem.asBytes(&file.path), 0) and std.mem.allEqual(u8, &file.sha256, 0);
}

fn validOwner(result: *const Assets) bool {
    return result.owner == result and result.fence_owner != null and result.deadline_owner != null and result.pinned_owner != null and
        result.file_count <= count and result.work_path_len > 0 and result.work_path_len <= result.work_path.len and
        std.crypto.timing_safe.eql([32]u8, result.seal, ownerSeal(result));
}

fn ownerSeal(result: *const Assets) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host.remote-release-assets.v1");
    const address = @intFromPtr(result);
    const fence_address = @intFromPtr(result.fence_owner);
    const deadline_address = @intFromPtr(result.deadline_owner);
    const pinned_address = @intFromPtr(result.pinned_owner);
    hash.update(std.mem.asBytes(&address));
    hash.update(std.mem.asBytes(&fence_address));
    hash.update(std.mem.asBytes(&deadline_address));
    hash.update(std.mem.asBytes(&pinned_address));
    hash.update(std.mem.asBytes(&result.parent_fd));
    hash.update(std.mem.asBytes(&result.dir_fd));
    hash.update(std.mem.asBytes(&result.dir_present));
    hash.update(std.mem.asBytes(&result.dir_device));
    hash.update(std.mem.asBytes(&result.dir_inode));
    hash.update(std.mem.asBytes(&result.work_path_len));
    if (result.work_path_len <= result.work_path.len) hash.update(result.work_path[0..result.work_path_len]);
    hash.update(std.mem.asBytes(&result.file_count));
    for (result.files[0..result.file_count]) |file| {
        hash.update(std.mem.asBytes(&file.id));
        hash.update(std.mem.asBytes(&file.name_len));
        if (file.name_len <= file.name.len) hash.update(file.name[0..file.name_len]);
        hash.update(std.mem.asBytes(&file.path_len));
        if (file.path_len <= file.path.len) hash.update(file.path[0..file.path_len]);
        hash.update(std.mem.asBytes(&file.device));
        hash.update(std.mem.asBytes(&file.inode));
        hash.update(std.mem.asBytes(&file.size));
        hash.update(&file.sha256);
        hash.update(std.mem.asBytes(&file.present));
    }
    hash.update(std.mem.asBytes(&result.complete));
    var out: [32]u8 = undefined;
    hash.final(&out);
    return out;
}

const SystemOperations = struct {
    io: std.Io,
    pub fn revalidateCli(_: *@This(), allocator: std.mem.Allocator, path: [:0]const u8, pinned: *const PinnedExecutable) !void {
        try cli_authority.revalidate(allocator, path, pinned);
    }
    pub fn download(self: *@This(), executable: [:0]const u8, token: []const u8, args: []const []const u8, fd: c.fd_t, expected_size: u64, budget: i128) !process.Digest {
        if (fd < 0) return error.CreateFailed;
        var argv: [max_args + 1:null]?[*:0]const u8 = @splat(null);
        var storage: [max_args][128:0]u8 = undefined;
        argv[0] = executable.ptr;
        for (args, 0..) |arg, index| argv[index + 1] = (std.fmt.bufPrintZ(&storage[index], "{s}", .{arg}) catch return error.InvalidAsset).ptr;
        var token_storage: ["GH_TOKEN=".len + max_token_bytes + 1]u8 = undefined;
        defer @memset(&token_storage, 0);
        const token_entry = std.fmt.bufPrintZ(&token_storage, "GH_TOKEN={s}", .{token}) catch return error.InvalidToken;
        const environment: [2:null]?[*:0]const u8 = .{ token_entry.ptr, "GH_PROMPT_DISABLED=1" };
        return process.runWriteEnvironmentStdout(self.io, executable, &argv, &environment, fd, expected_size, budget);
    }
};

fn validComponent(value: []const u8) bool {
    if (value.len == 0 or value.len > std.fs.max_name_bytes or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..") or std.mem.indexOfScalar(u8, value, '/') != null) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
