//! Product composition for one read-only protected-run remote Release verdict.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const timing_artifact = @import("release_adapter_live_timing_artifact");
const timing_transport = @import("release_adapter_live_timing_transport");
const fence_mod = @import("release_adapter_remote_release_fence");
const assets_mod = @import("release_adapter_remote_release_assets");
const observation_mod = @import("release_adapter_remote_release_observation");
const verdict_mod = @import("release_adapter_remote_release_verdict");
const pass_record = @import("release_adapter_remote_release_pass_record");
const pass_file = @import("release_adapter_remote_release_pass_file");
const files_mod = @import("release_adapter_files");
const cli_authority = @import("release_adapter_github_cli_authority");
const github_transport = @import("release_adapter_github_transport");
const attestation = @import("release_adapter_github_attestation");
const deadline_mod = @import("release_adapter_deadline");

pub const max_token_bytes: usize = 16 * 1024;

pub const Command = struct {
    cli_path: []const u8,
    cli_sha256: []const u8,
    timing_workspace: []const u8,
    release_workspace: []const u8,
    record_path: ?[]const u8 = null,
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len != 5 and args.len != 6) return error.InvalidArguments;
    const records = std.mem.eql(u8, args[0], "verify-and-record");
    if (!std.mem.eql(u8, args[0], "verify") and !records) return error.InvalidCommand;
    if (records != (args.len == 6)) return error.InvalidArguments;
    if (!absoluteScalar(args[1]) or !absoluteScalar(args[3]) or !absoluteScalar(args[4])) return error.InvalidPath;
    if (!lowerHex(args[2], 64)) return error.InvalidSha256;
    if (!siblingWorkspaces(args[3], args[4])) return error.AliasedWorkspace;
    if (records and (!absoluteScalar(args[5]) or !siblingWorkspaces(args[3], args[5]) or !siblingWorkspaces(args[4], args[5]) or
        !std.mem.eql(u8, std.fs.path.basename(args[5]), pass_file.final_name))) return error.InvalidPath;
    return .{ .cli_path = args[1], .cli_sha256 = args[2], .timing_workspace = args[3], .release_workspace = args[4], .record_path = if (records) args[5] else null };
}

pub fn verify(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: *const context_mod.Context,
    runner: cli_authority.RunnerAuthority,
    command: Command,
    token: []const u8,
    timing_metadata: []u8,
    release_metadata: []u8,
    attestation_output: []u8,
    budget_ns: i128,
) !void {
    try context_mod.validateTrusted(context.*);
    if (!std.mem.eql(u8, &runner.workflow_sha, context.source_commit)) return error.ContextMismatch;
    if (!absoluteScalar(command.cli_path) or !absoluteScalar(command.timing_workspace) or !absoluteScalar(command.release_workspace) or
        !lowerHex(command.cli_sha256, 64) or !siblingWorkspaces(command.timing_workspace, command.release_workspace)) return error.InvalidArguments;
    if (command.record_path) |path| if (!absoluteScalar(path) or !siblingWorkspaces(command.timing_workspace, path) or
        !siblingWorkspaces(command.release_workspace, path) or !std.mem.eql(u8, std.fs.path.basename(path), pass_file.final_name)) return error.InvalidArguments;
    if (!disjointInputs(context, command, token, timing_metadata, release_metadata, attestation_output)) return error.AliasedInput;
    try github_transport.validateToken(token);
    if (timing_metadata.len == 0 or timing_metadata.len > timing_artifact.response_cap or
        release_metadata.len == 0 or release_metadata.len > github_transport.max_response_bytes or
        attestation_output.len == 0 or attestation_output.len > attestation.max_response_bytes) return error.InvalidBuffer;

    var cli_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const cli_path = std.fmt.bufPrintZ(&cli_storage, "{s}", .{command.cli_path}) catch return error.InvalidPath;
    var timing_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const timing_workspace = std.fmt.bufPrintZ(&timing_storage, "{s}", .{command.timing_workspace}) catch return error.InvalidPath;
    var release_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const release_workspace = std.fmt.bufPrintZ(&release_storage, "{s}", .{command.release_workspace}) catch return error.InvalidPath;
    var record_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const record_path: ?[:0]const u8 = if (command.record_path) |path|
        std.fmt.bufPrintZ(&record_storage, "{s}", .{path}) catch return error.InvalidPath
    else
        null;
    const pinned = try cli_authority.pin(allocator, cli_path, command.cli_sha256);

    var deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(budget_ns, &deadline);
    var transaction = RealTransaction{
        .io = io,
        .allocator = allocator,
        .context = context,
        .cli_path = cli_path,
        .pinned = &pinned,
        .token = token,
        .timing_workspace = timing_workspace,
        .release_workspace = release_workspace,
        .timing_metadata = timing_metadata,
        .release_metadata = release_metadata,
        .attestation_output = attestation_output,
        .deadline = &deadline,
        .record_path = record_path,
    };
    if (record_path != null) try composeAndRecordWith(&transaction) else try composeWith(&transaction);
}

pub fn composeWith(operations: anytype) !void {
    var completed: u8 = 0;
    var cleanup_attempted = false;
    errdefer if (!cleanup_attempted) operations.cleanup(completed) catch {};
    try operations.fetchTiming();
    completed = 1;
    try operations.beginRelease();
    completed = 2;
    try operations.downloadAssets();
    completed = 3;
    try operations.observeRelease();
    completed = 4;
    try operations.bindVerdict();
    completed = 5;
    try operations.revalidateVerdict();
    completed = 6;
    cleanup_attempted = true;
    try operations.cleanup(completed);
}

pub fn composeAndRecordWith(operations: anytype) !void {
    var completed: u8 = 0;
    var cleanup_attempted = false;
    errdefer if (!cleanup_attempted) operations.cleanup(completed) catch {};
    try operations.fetchTiming();
    completed = 1;
    try operations.beginRelease();
    completed = 2;
    try operations.downloadAssets();
    completed = 3;
    try operations.observeRelease();
    completed = 4;
    try operations.bindVerdict();
    completed = 5;
    try operations.revalidateVerdict();
    try operations.freezeRecord();
    completed = 6;
    cleanup_attempted = true;
    operations.cleanup(completed) catch |err| {
        operations.discardRecord() catch {};
        return err;
    };
    try operations.publishRecord();
}

const RealTransaction = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    context: *const context_mod.Context,
    cli_path: [:0]const u8,
    pinned: *const cli_authority.PinnedExecutable,
    token: []const u8,
    timing_workspace: [:0]const u8,
    release_workspace: [:0]const u8,
    timing_metadata: []u8,
    release_metadata: []u8,
    attestation_output: []u8,
    deadline: *deadline_mod.Deadline,
    record_path: ?[:0]const u8,
    timing: timing_artifact.Provenance = .{},
    release_fence: fence_mod.Fence = .{},
    assets: assets_mod.Assets = .{},
    observation: observation_mod.Observation = .{},
    verdict: verdict_mod.Verdict = .{},
    record: pass_record.Owner = .{},
    frozen_record: pass_record.Frozen = .{},

    fn fetchTiming(self: *@This()) !void {
        try timing_transport.fetchUntil(self.io, self.allocator, .{ .path = self.cli_path, .pinned = self.pinned }, self.token, expected(self.context.*), self.timing_workspace, self.timing_metadata, self.deadline, &self.timing);
    }

    fn beginRelease(self: *@This()) !void {
        try fence_mod.beginUntil(self.io, self.allocator, self.context.*, self.cli_path, self.pinned, self.token, self.release_metadata, self.deadline, &self.release_fence);
    }

    fn downloadAssets(self: *@This()) !void {
        try assets_mod.downloadUntil(self.io, self.allocator, &self.release_fence, .{ .path = self.cli_path, .pinned = self.pinned }, self.token, self.release_workspace, self.deadline, &self.assets);
    }

    fn observeRelease(self: *@This()) !void {
        try observation_mod.composeUntil(self.io, self.allocator, self.context.*, &self.release_fence, &self.assets, .{ .path = self.cli_path, .pinned = self.pinned }, self.token, self.release_metadata, self.attestation_output, self.deadline, &self.observation);
    }

    fn bindVerdict(self: *@This()) !void {
        try verdict_mod.bind(self.context, &self.timing, &self.observation, &self.verdict);
    }

    fn revalidateVerdict(self: *@This()) !void {
        _ = self.verdict.value() orelse return error.InvalidVerdict;
    }

    fn freezeRecord(self: *@This()) !void {
        try pass_record.encode(self.allocator, self.context, &self.verdict, &self.record);
        errdefer self.record.deinit(self.allocator) catch {};
        try pass_record.freeze(self.allocator, &self.record, &self.frozen_record);
        try self.record.deinit(self.allocator);
    }

    fn publishRecord(self: *@This()) !void {
        const path = self.record_path orelse return error.InvalidArguments;
        defer self.frozen_record.deinit(self.allocator) catch {};
        var published: files_mod.PinnedReleaseFile = .{};
        try pass_file.publish(self.allocator, &self.frozen_record, path, &published);
        try published.deinit();
    }

    fn discardRecord(self: *@This()) !void {
        try self.frozen_record.deinit(self.allocator);
    }

    fn cleanup(self: *@This(), completed: u8) !void {
        // Stop at the first failed child cleanup: every remaining owner may still be
        // part of that child's authority graph and must not be invalidated underneath it.
        if (completed >= 5) try self.verdict.deinit();
        if (completed >= 4) try self.observation.deinit(self.allocator);
        if (completed >= 3) try self.assets.deinit();
        if (completed >= 2) try self.release_fence.deinit();
        if (completed >= 1) try self.timing.deinit();
        try self.deadline.deinit();
    }
};

fn expected(context: context_mod.Context) timing_artifact.Expected {
    return .{ .repository_id = context.repository.id, .run_id = context.build.run_id, .run_attempt = context.build.run_attempt, .source_sha = context.source_commit };
}

fn absoluteScalar(value: []const u8) bool {
    if (value.len < 2 or value[0] != '/') return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn siblingWorkspaces(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return false;
    const left_slash = std.mem.lastIndexOfScalar(u8, left, '/') orelse return false;
    const right_slash = std.mem.lastIndexOfScalar(u8, right, '/') orelse return false;
    const left_name = left[left_slash + 1 ..];
    const right_name = right[right_slash + 1 ..];
    if (left_name.len == 0 or right_name.len == 0 or std.mem.eql(u8, left_name, ".") or std.mem.eql(u8, left_name, "..") or
        std.mem.eql(u8, right_name, ".") or std.mem.eql(u8, right_name, "..")) return false;
    return std.mem.eql(u8, left[0..left_slash], right[0..right_slash]);
}

fn disjointInputs(context: *const context_mod.Context, command: Command, token: []const u8, timing_metadata: []u8, release_metadata: []u8, attestation_output: []u8) bool {
    const inputs = [_][]const u8{
        std.mem.asBytes(context),  context.repository.owner, context.repository.name,
        context.tag,               context.source_commit,    context.build.workflow_ref,
        command.cli_path,          command.cli_sha256,       command.timing_workspace,
        command.release_workspace, token,                    timing_metadata,
        release_metadata,          attestation_output,       command.record_path orelse "",
    };
    for (inputs, 0..) |input, index| for (inputs[0..index]) |prior| if (overlaps(input, prior)) return false;
    return true;
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return @intFromPtr(a.ptr) < @intFromPtr(b.ptr) + b.len and @intFromPtr(b.ptr) < @intFromPtr(a.ptr) + a.len;
}

fn lowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
