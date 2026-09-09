//! Fetches one current-attempt pass artifact through an already-pinned GitHub CLI.
//!
//! Endpoint, argv, environment and temporary-file lifetime are closed here so callers can only
//! receive the credential-free `Provenance` value owner.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const artifact = @import("release_adapter_remote_release_pass_artifact");
const context_mod = @import("release_adapter_context");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");
const process = @import("bounded_process");
const safe_open = @import("safe_open");

const repository = "ohah/maru";
const archive_leaf: [:0]const u8 = "pass-artifact.zip";
const max_token_bytes: usize = 16 * 1024;
const max_args: usize = 11;
pub const metadata_attempts: usize = 5;
pub const metadata_retry_ns: i128 = 250 * std.time.ns_per_ms;

pub const Cli = struct {
    path: [:0]const u8,
    pinned: *const PinnedExecutable,
};

pub const PinnedExecutable = cli_authority.PinnedExecutable;

pub fn fetch(
    io: std.Io,
    allocator: std.mem.Allocator,
    cli: Cli,
    token: []const u8,
    context: *const context_mod.Context,
    workspace_path: [:0]const u8,
    metadata_buffer: []u8,
    budget_ns: i128,
    result: *artifact.Provenance,
) !void {
    var deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(budget_ns, &deadline);
    fetchUntil(io, allocator, cli, token, context, workspace_path, metadata_buffer, &deadline, result) catch |err| {
        deadline.deinit() catch {};
        return err;
    };
    _ = deadline.remaining() catch |err| {
        result.deinit(allocator) catch {};
        deadline.deinit() catch {};
        return err;
    };
    deadline.deinit() catch |err| {
        result.deinit(allocator) catch {};
        return err;
    };
}

pub fn fetchUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    cli: Cli,
    token: []const u8,
    context: *const context_mod.Context,
    workspace_path: [:0]const u8,
    metadata_buffer: []u8,
    deadline: *deadline_mod.Deadline,
    result: *artifact.Provenance,
) !void {
    var operations = SystemOperations{ .io = io };
    return fetchWith(&operations, allocator, cli, token, context, workspace_path, metadata_buffer, deadline, result);
}

pub fn fetchWithForTest(
    operations: anytype,
    allocator: std.mem.Allocator,
    cli: Cli,
    token: []const u8,
    context: *const context_mod.Context,
    workspace_path: [:0]const u8,
    metadata_buffer: []u8,
    deadline: *deadline_mod.Deadline,
    result: *artifact.Provenance,
) !void {
    if (!builtin.is_test) @compileError("fetchWithForTest is a test-only seam");
    return fetchWith(operations, allocator, cli, token, context, workspace_path, metadata_buffer, deadline, result);
}

fn fetchWith(
    operations: anytype,
    allocator: std.mem.Allocator,
    cli: Cli,
    token: []const u8,
    context: *const context_mod.Context,
    workspace_path: [:0]const u8,
    metadata_buffer: []u8,
    deadline: *deadline_mod.Deadline,
    result: *artifact.Provenance,
) !void {
    try validateInputs(cli, token, context, workspace_path, metadata_buffer, deadline, result);

    var workspace: Workspace = .{};
    try workspace.prepare(workspace_path);
    fetchPrepared(operations, allocator, cli, token, context, metadata_buffer, deadline, result, &workspace) catch |err| {
        workspace.cleanup() catch return error.CleanupFailed;
        return err;
    };
    workspace.cleanup() catch |err| {
        result.deinit(allocator) catch {};
        return err;
    };
    _ = deadline.remaining() catch |err| {
        result.deinit(allocator) catch {};
        return err;
    };
}

fn fetchPrepared(
    operations: anytype,
    allocator: std.mem.Allocator,
    cli: Cli,
    token: []const u8,
    context: *const context_mod.Context,
    metadata_buffer: []u8,
    deadline: *deadline_mod.Deadline,
    result: *artifact.Provenance,
    workspace: *Workspace,
) !void {
    try workspace.createArchive();

    const expected: artifact.Expected = .{ .repository_id = context.repository.id, .run_id = context.build.run_id, .run_attempt = context.build.run_attempt, .source_sha = context.source_commit };

    var plan_storage: PlanStorage = undefined;
    const list = try listPlan(&plan_storage, expected);
    var metadata: artifact.Metadata = .{};
    var found = false;
    for (0..metadata_attempts) |attempt| {
        try operations.revalidateCli(allocator, cli.path, cli.pinned);
        const list_budget = try deadline.remaining();
        const metadata_bytes = try operations.capture(cli.path, token, list.args, metadata_buffer, list_budget);
        if (!borrowedFrom(metadata_bytes, metadata_buffer)) return error.InvalidCapture;
        try operations.revalidateCli(allocator, cli.path, cli.pinned);
        artifact.selectMetadata(allocator, metadata_bytes, expected, &metadata) catch |err| switch (err) {
            error.NotFound => {
                if (attempt + 1 == metadata_attempts) return error.ArtifactNotVisible;
                const wait_budget = try deadline.remaining();
                if (wait_budget <= metadata_retry_ns) return error.TimedOut;
                try operations.waitRetry(metadata_retry_ns);
                continue;
            },
            else => return err,
        };
        found = true;
        break;
    }
    if (!found) return error.ArtifactNotVisible;
    defer metadata.deinit() catch {};
    const selected = metadata.value() orelse return error.InvalidCapture;
    if (selected.archive_size > artifact.archive_cap) return error.InvalidCapture;

    const download = try downloadPlan(&plan_storage, selected.artifact_id);
    try operations.revalidateCli(allocator, cli.path, cli.pinned);
    const download_budget = try deadline.remaining();
    const digest = try operations.download(cli.path, token, download.args, workspace.archive_fd, selected.archive_size, download_budget);
    try operations.revalidateCli(allocator, cli.path, cli.pinned);
    if (digest.size != selected.archive_size or !std.mem.eql(u8, &digest.sha256, &selected.archive_sha256))
        return error.InvalidCapture;
    try workspace.sealArchive(selected.archive_size);

    var archive_storage: [artifact.archive_cap]u8 = undefined;
    const archive_bytes = try workspace.readArchive(&archive_storage, selected.archive_size);
    try artifact.bindArchive(allocator, context, &metadata, archive_bytes, result);
}

const Plan = struct { args: []const []const u8 };

const PlanStorage = struct {
    endpoint: [512]u8 = undefined,
    name: [96]u8 = undefined,
    args: [max_args][]const u8 = undefined,
};

fn listPlan(storage: *PlanStorage, expected: artifact.Expected) !Plan {
    if (expected.run_id == 0 or expected.run_attempt == 0) return error.InvalidInput;
    const name = std.fmt.bufPrint(&storage.name, "session-host-release-remote-pass-{d}", .{expected.run_attempt}) catch
        return error.InvalidInput;
    const endpoint = std.fmt.bufPrint(&storage.endpoint, "repos/{s}/actions/runs/{d}/artifacts?per_page=100&name={s}", .{ repository, expected.run_id, name }) catch
        return error.InvalidInput;
    return command(storage, endpoint);
}

fn downloadPlan(storage: *PlanStorage, artifact_id: u64) !Plan {
    if (artifact_id == 0) return error.InvalidInput;
    const endpoint = std.fmt.bufPrint(&storage.endpoint, "repos/{s}/actions/artifacts/{d}/zip", .{ repository, artifact_id }) catch
        return error.InvalidInput;
    return command(storage, endpoint);
}

fn command(storage: *PlanStorage, endpoint: []const u8) Plan {
    const values = [_][]const u8{
        "api",                                 "--method", "GET",                              "--hostname", "github.com", "--header",
        "Accept: application/vnd.github+json", "--header", "X-GitHub-Api-Version: 2022-11-28", endpoint,
    };
    for (values, 0..) |value, index| storage.args[index] = value;
    return .{ .args = storage.args[0..values.len] };
}

fn validateInputs(
    cli: Cli,
    token: []const u8,
    context: *const context_mod.Context,
    workspace_path: []const u8,
    metadata_buffer: []u8,
    deadline: *deadline_mod.Deadline,
    result: *const artifact.Provenance,
) !void {
    if (!result.isPristineForComposition()) return error.InvalidOwner;
    if (cli.path.len < 2 or cli.path[0] != '/' or std.mem.indexOfScalar(u8, cli.path, 0) != null or
        workspace_path.len < 2 or workspace_path[0] != '/' or std.mem.indexOfScalar(u8, workspace_path, 0) != null or
        context.repository.id == 0 or context.build.run_id == 0 or context.build.run_attempt == 0 or !lowerHex(context.source_commit, 40) or
        metadata_buffer.len < artifact.response_cap) return error.InvalidInput;
    if (token.len == 0 or token.len > max_token_bytes) return error.InvalidToken;
    for (token) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidToken;
    const output = std.mem.asBytes(result);
    if (overlaps(output, token) or overlaps(output, cli.path) or overlaps(output, workspace_path) or
        overlaps(output, context.source_commit) or overlaps(output, std.mem.asBytes(context)) or overlaps(output, metadata_buffer) or
        overlaps(output, std.mem.asBytes(deadline)) or overlaps(output, std.mem.asBytes(cli.pinned)) or
        overlaps(metadata_buffer, token) or overlaps(metadata_buffer, cli.path) or overlaps(metadata_buffer, workspace_path) or
        overlaps(metadata_buffer, context.source_commit) or overlaps(metadata_buffer, std.mem.asBytes(context)) or overlaps(metadata_buffer, std.mem.asBytes(deadline)) or
        overlaps(metadata_buffer, std.mem.asBytes(cli.pinned))) return error.InvalidOwner;
    try context_mod.validateTrusted(context.*);
    _ = try deadline.remaining();
}

const SystemOperations = struct {
    io: std.Io,

    fn revalidateCli(_: *@This(), allocator: std.mem.Allocator, path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable) !void {
        try cli_authority.revalidate(allocator, path, pinned);
    }

    fn capture(self: *@This(), executable: [:0]const u8, token: []const u8, args: []const []const u8, output: []u8, budget_ns: i128) ![]const u8 {
        var argv_storage: [max_args + 1:null]?[*:0]const u8 = @splat(null);
        var arg_storage: [max_args][512:0]u8 = undefined;
        argv_storage[0] = executable.ptr;
        for (args, 0..) |arg, index| {
            const value = std.fmt.bufPrintZ(&arg_storage[index], "{s}", .{arg}) catch return error.InvalidInput;
            argv_storage[index + 1] = value.ptr;
        }
        var environment_storage: ["GH_TOKEN=".len + max_token_bytes + 1]u8 = undefined;
        defer @memset(&environment_storage, 0);
        const token_entry = std.fmt.bufPrintZ(&environment_storage, "GH_TOKEN={s}", .{token}) catch return error.InvalidToken;
        const environment: [2:null]?[*:0]const u8 = .{ token_entry.ptr, "GH_PROMPT_DISABLED=1" };
        return process.runCaptureEnvironmentStdout(self.io, executable, &argv_storage, &environment, output, budget_ns);
    }

    fn download(self: *@This(), executable: [:0]const u8, token: []const u8, args: []const []const u8, output_fd: c.fd_t, expected_size: u64, budget_ns: i128) !process.Digest {
        var argv_storage: [max_args + 1:null]?[*:0]const u8 = @splat(null);
        var arg_storage: [max_args][512:0]u8 = undefined;
        argv_storage[0] = executable.ptr;
        for (args, 0..) |arg, index| {
            const value = std.fmt.bufPrintZ(&arg_storage[index], "{s}", .{arg}) catch return error.InvalidInput;
            argv_storage[index + 1] = value.ptr;
        }
        var environment_storage: ["GH_TOKEN=".len + max_token_bytes + 1]u8 = undefined;
        defer @memset(&environment_storage, 0);
        const token_entry = std.fmt.bufPrintZ(&environment_storage, "GH_TOKEN={s}", .{token}) catch return error.InvalidToken;
        const environment: [2:null]?[*:0]const u8 = .{ token_entry.ptr, "GH_PROMPT_DISABLED=1" };
        return process.runWriteEnvironmentStdout(self.io, executable, &argv_storage, &environment, output_fd, expected_size, budget_ns);
    }

    fn waitRetry(self: *@This(), delay_ns: i128) !void {
        if (delay_ns <= 0 or @mod(delay_ns, std.time.ns_per_ms) != 0) return error.InvalidDelay;
        try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(@divExact(delay_ns, std.time.ns_per_ms))), .awake);
    }
};

const Workspace = struct {
    parent_fd: c.fd_t = -1,
    dir_fd: c.fd_t = -1,
    archive_fd: c.fd_t = -1,
    dir_present: bool = false,
    archive_present: bool = false,
    dir_device: u64 = 0,
    dir_inode: u64 = 0,
    archive_device: u64 = 0,
    archive_inode: u64 = 0,
    dir_name: [std.fs.max_name_bytes:0]u8 = undefined,

    fn prepare(self: *@This(), path: [:0]const u8) !void {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidWorkspace;
        const leaf = path[slash + 1 ..];
        if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..") or leaf.len > std.fs.max_name_bytes)
            return error.InvalidWorkspace;
        var parent_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const parent = if (slash == 0) "/" else std.fmt.bufPrintZ(&parent_storage, "{s}", .{path[0..slash]}) catch return error.InvalidWorkspace;
        self.parent_fd = safe_open.openAbsoluteNoFollow(parent, true) catch return error.InvalidWorkspace;
        _ = std.fmt.bufPrintZ(&self.dir_name, "{s}", .{leaf}) catch return error.InvalidWorkspace;
        if (c.mkdirat(self.parent_fd, self.dir_name[0..].ptr, 0o700) != 0) {
            const err: anyerror = if (posix.errno(-1) == .EXIST) error.WorkspaceExists else error.CreateFailed;
            _ = c.close(self.parent_fd);
            self.parent_fd = -1;
            return err;
        }
        self.dir_present = true;
        var named: posix.Stat = undefined;
        if (c.fstatat(self.parent_fd, self.dir_name[0..].ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or !posix.S.ISDIR(named.mode))
            return self.failPrepare(error.FileChanged);
        self.dir_device = @intCast(named.dev);
        self.dir_inode = @intCast(named.ino);
        self.dir_fd = c.openat(self.parent_fd, self.dir_name[0..].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
        if (self.dir_fd < 0) return self.failPrepare(error.CreateFailed);
        var stat: posix.Stat = undefined;
        if (c.fstat(self.dir_fd, &stat) != 0 or !posix.S.ISDIR(stat.mode) or
            stat.dev != named.dev or stat.ino != named.ino) return self.failPrepare(error.FileChanged);
        if (c.fchmodat(self.parent_fd, self.dir_name[0..].ptr, 0o700, @intCast(posix.AT.SYMLINK_NOFOLLOW)) != 0 or
            c.fstat(self.dir_fd, &stat) != 0 or stat.mode & 0o777 != 0o700) return self.failPrepare(error.FileChanged);
    }

    fn failPrepare(self: *@This(), err: anyerror) anyerror {
        self.cleanup() catch return error.CleanupFailed;
        return err;
    }

    fn createArchive(self: *@This()) !void {
        self.archive_fd = c.openat(self.dir_fd, archive_leaf.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
        if (self.archive_fd < 0) return error.CreateFailed;
        self.archive_present = true;
        var stat: posix.Stat = undefined;
        if (c.fstat(self.archive_fd, &stat) != 0 or !posix.S.ISREG(stat.mode)) return error.CreateFailed;
        self.archive_device = @intCast(stat.dev);
        self.archive_inode = @intCast(stat.ino);
        if (c.fchmod(self.archive_fd, 0o600) != 0) return error.CreateFailed;
    }

    fn sealArchive(self: *@This(), expected_size: u64) !void {
        if (c.fsync(self.archive_fd) != 0) return error.SyncFailed;
        var held: posix.Stat = undefined;
        var named: posix.Stat = undefined;
        if (c.fstat(self.archive_fd, &held) != 0 or c.fstatat(self.dir_fd, archive_leaf.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !posix.S.ISREG(held.mode) or !posix.S.ISREG(named.mode) or held.dev != named.dev or held.ino != named.ino or
            held.mode & 0o777 != 0o600 or held.nlink != 1 or held.size < 0 or @as(u64, @intCast(held.size)) != expected_size)
            return error.FileChanged;
    }

    fn readArchive(self: *@This(), storage: *[artifact.archive_cap]u8, expected_size: u64) ![]const u8 {
        const size: usize = @intCast(expected_size);
        var used: usize = 0;
        while (used < size) {
            const amount = c.pread(self.archive_fd, storage[used..size].ptr, size - used, @intCast(used));
            if (amount < 0 and posix.errno(amount) == .INTR) continue;
            if (amount <= 0) return error.ReadFailed;
            used += @intCast(amount);
        }
        var extra: [1]u8 = undefined;
        if (c.pread(self.archive_fd, &extra, 1, @intCast(size)) != 0) return error.FileChanged;
        return storage[0..size];
    }

    fn cleanup(self: *@This()) !void {
        var failed = false;
        if (self.archive_fd >= 0) {
            if (c.close(self.archive_fd) != 0) failed = true;
            self.archive_fd = -1;
        }
        if (self.archive_present) {
            var named: posix.Stat = undefined;
            if (c.fstatat(self.dir_fd, archive_leaf.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
                !posix.S.ISREG(named.mode) or named.dev != self.archive_device or named.ino != self.archive_inode or named.nlink != 1)
                failed = true
            else if (c.unlinkat(self.dir_fd, archive_leaf.ptr, 0) != 0)
                failed = true
            else
                self.archive_present = false;
        }
        if (self.dir_fd >= 0) {
            if (c.fsync(self.dir_fd) != 0 or c.close(self.dir_fd) != 0) failed = true;
            self.dir_fd = -1;
        }
        if (self.dir_present) {
            var named: posix.Stat = undefined;
            if (c.fstatat(self.parent_fd, self.dir_name[0..].ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
                !posix.S.ISDIR(named.mode) or named.dev != self.dir_device or named.ino != self.dir_inode)
                failed = true
            else if (c.unlinkat(self.parent_fd, self.dir_name[0..].ptr, posix.AT.REMOVEDIR) != 0)
                failed = true
            else
                self.dir_present = false;
        }
        if (self.parent_fd >= 0) {
            if (c.fsync(self.parent_fd) != 0 or c.close(self.parent_fd) != 0) failed = true;
            self.parent_fd = -1;
        }
        if (failed) return error.CleanupFailed;
        self.* = .{};
    }
};

fn borrowedFrom(value: []const u8, storage: []const u8) bool {
    if (value.len == 0) return false;
    const value_end = std.math.add(usize, @intFromPtr(value.ptr), value.len) catch return false;
    const storage_end = std.math.add(usize, @intFromPtr(storage.ptr), storage.len) catch return false;
    return @intFromPtr(value.ptr) >= @intFromPtr(storage.ptr) and value_end <= storage_end;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn lowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
