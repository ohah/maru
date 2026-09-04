//! Production binding for one post-publish predecessor verification transaction.
//!
//! The caller owns this object because an indeterminate filesystem cleanup must retain exact retry
//! capabilities. Borrowed workflow authority is scrubbed before any such retry is exposed.

const std = @import("std");
const phase = @import("release_adapter_verify_predecessor_phase");
const workspace_mod = @import("release_adapter_pre_publish_workspace");
const bootstrap_mod = @import("release_adapter_executable_bootstrap");
const deadline_mod = @import("release_adapter_deadline");
const github_transport = @import("release_adapter_github_transport");
const files = @import("release_adapter_files");
const candidate_mod = @import("release_adapter_github_current_manifest_candidate");
const manifest_file_mod = @import("release_adapter_github_manifest_file");
const manifest_attestation = @import("release_adapter_github_manifest_attestation");
const assets_mod = @import("release_adapter_github_tag_chain_transport");
const summary_mod = @import("release_adapter_summary");

pub const Error = error{ InvalidOwner, InvalidBootstrap, InvalidCommand, InvalidBuffer, CleanupFailed };

pub const Buffers = struct {
    github_response: []u8 = &.{},
    attestation: []u8 = &.{},
};

pub const Execution = struct {
    owner: ?*Execution = null,
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,
    bootstrap: ?*bootstrap_mod.Bootstrap = null,
    token: []const u8 = "",
    budget_ns: i128 = 0,
    buffers: Buffers = .{},

    deadline: deadline_mod.Deadline = .{},
    workspace: workspace_mod.Workspace = .{},
    candidate: candidate_mod.CurrentManifestCandidate = .{},
    manifest_input: ?files.Input = null,
    manifest_file: manifest_file_mod.ManifestFile = .{},
    authenticated: manifest_attestation.AuthenticatedManifest = .{},
    assets: assets_mod.Result = .{},
    prepared_summary: ?[]u8 = null,

    pub fn retryCleanup(self: *@This()) Error!void {
        if (self.owner != self) return error.InvalidOwner;
        self.clearBorrowed();
        self.releasePrepared();
        var clean = true;
        self.cleanupAssets(&self.deadline) catch {
            clean = false;
        };
        self.cleanupAuthenticated(&self.deadline) catch {
            clean = false;
        };
        self.cleanupMaterialized(&self.deadline) catch {
            clean = false;
        };
        self.cleanupCandidate(&self.deadline) catch {
            clean = false;
        };
        self.cleanupWorkspace(&self.deadline) catch {
            clean = false;
        };
        self.cleanupDeadline(&self.deadline) catch {
            clean = false;
        };
        if (!clean or self.hasLiveOwners()) return error.CleanupFailed;
        self.* = .{};
    }

    fn boundCommand(self: *@This()) !bootstrap_mod.VerifyPredecessor {
        if (self.owner != self) return error.InvalidOwner;
        const bootstrap = self.bootstrap orelse return error.InvalidBootstrap;
        const view = bootstrap.value() orelse return error.InvalidBootstrap;
        return switch (view.command) {
            .verify_predecessor => |value| value,
            .pre_publish, .publish_candidate => error.InvalidCommand,
        };
    }

    pub fn startDeadline(self: *@This()) !*deadline_mod.Deadline {
        try deadline_mod.start(self.budget_ns, &self.deadline);
        return &self.deadline;
    }

    pub fn prepareWorkspace(self: *@This(), _: *deadline_mod.Deadline) !void {
        const command = try self.boundCommand();
        var storage: [std.fs.max_path_bytes:0]u8 = undefined;
        try workspace_mod.prepare(&self.workspace, try copyPath(&storage, command.work_dir));
    }

    pub fn prepareCandidate(self: *@This(), _: *deadline_mod.Deadline) !void {
        const command = try self.boundCommand();
        const view = self.bootstrap.?.value() orelse return error.InvalidBootstrap;
        var storage: [std.fs.max_path_bytes:0]u8 = undefined;
        try candidate_mod.read(self.allocator, view.context, try copyPath(&storage, command.manifest), &self.candidate);
    }

    pub fn materializeManifest(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.manifest_input != null) return error.InvalidOwner;
        var input = try self.candidate.takeInput();
        errdefer input.deinit(self.allocator);
        var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const workdir = try self.workspace.childPath(.current_manifest, &path_storage);
        const command = try self.boundCommand();
        try manifest_file_mod.materialize(&self.manifest_file, workdir, .{
            .name = std.fs.path.basename(command.manifest),
            .sha256 = &input.sha256,
            .bytes = input.bytes,
        });
        self.manifest_input = input;
    }

    pub fn authenticateManifest(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const input = self.manifest_input orelse return error.InvalidOwner;
        const bootstrap = self.bootstrap orelse return error.InvalidBootstrap;
        const view = bootstrap.value() orelse return error.InvalidBootstrap;
        try manifest_attestation.authenticatePublishedUntil(
            self.io,
            self.allocator,
            view.context,
            input.bytes,
            &self.manifest_file,
            .{ .path = view.github_cli, .pinned = &bootstrap.cli },
            self.token,
            self.buffers.attestation,
            deadline,
            &self.authenticated,
        );
    }

    pub fn authenticateAssets(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const workdir = try self.workspace.childPath(.predecessor_assets, &path_storage);
        const bootstrap = self.bootstrap orelse return error.InvalidBootstrap;
        const view = bootstrap.value() orelse return error.InvalidBootstrap;
        try assets_mod.authenticateUntil(
            self.io,
            self.allocator,
            &self.authenticated,
            .{ .path = view.github_cli, .pinned = &bootstrap.cli },
            self.token,
            workdir,
            self.buffers.github_response,
            deadline,
            &self.assets,
        );
    }

    pub fn prepareSummary(self: *@This(), _: *deadline_mod.Deadline) ![]u8 {
        if (self.prepared_summary != null) return error.InvalidOwner;
        const bytes = try summary_mod.encodePredecessor(self.allocator, &self.authenticated, &self.assets);
        self.prepared_summary = bytes;
        return bytes;
    }

    pub fn validatePublication(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        if (deadline != &self.deadline) return error.InvalidOwner;
        _ = try deadline.remaining();
    }

    pub fn publishSummary(self: *@This(), prepared: []u8) !void {
        try self.validatePrepared(prepared);
        const command = try self.boundCommand();
        var storage: [std.fs.max_path_bytes:0]u8 = undefined;
        try files.publishSummaryExclusive(try copyPath(&storage, command.summary_out), prepared);
    }

    pub fn releaseSummary(self: *@This(), prepared: []u8) void {
        self.validatePrepared(prepared) catch unreachable;
        self.allocator.free(prepared);
        self.prepared_summary = null;
    }

    pub fn cleanupAssets(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.assets.owner != null) try self.assets.cleanup();
    }
    pub fn cleanupAuthenticated(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.authenticated.owner != null) try self.authenticated.deinit(self.allocator);
    }
    pub fn cleanupMaterialized(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.manifest_file.owner != null) try self.manifest_file.cleanup();
        if (self.manifest_input) |*input| input.deinit(self.allocator);
        self.manifest_input = null;
    }
    pub fn cleanupCandidate(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.candidate.owner != null) try self.candidate.deinit(self.allocator);
    }
    pub fn cleanupWorkspace(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.workspace.owner != null) try self.workspace.cleanup();
    }
    pub fn cleanupDeadline(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        if (deadline != &self.deadline) return error.InvalidOwner;
        if (self.deadline.owner != null) try self.deadline.deinit();
    }

    fn validatePrepared(self: *const @This(), prepared: []u8) !void {
        const canonical = self.prepared_summary orelse return error.InvalidOwner;
        if (canonical.ptr != prepared.ptr or canonical.len != prepared.len) return error.InvalidOwner;
    }

    fn releasePrepared(self: *@This()) void {
        if (self.prepared_summary) |bytes| {
            self.allocator.free(bytes);
            self.prepared_summary = null;
        }
    }

    fn hasLiveOwners(self: *const @This()) bool {
        return self.deadline.owner != null or self.workspace.owner != null or self.candidate.owner != null or
            self.manifest_input != null or self.manifest_file.owner != null or self.authenticated.owner != null or
            self.assets.owner != null or self.prepared_summary != null;
    }

    fn clearBorrowed(self: *@This()) void {
        self.bootstrap = null;
        self.token = "";
        self.budget_ns = 0;
        self.buffers = .{};
    }
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    bootstrap: *bootstrap_mod.Bootstrap,
    token: []const u8,
    budget_ns: i128,
    buffers: Buffers,
    result: *Execution,
) !void {
    if (result.owner != null or result.hasLiveOwners()) return error.InvalidOwner;
    const view = bootstrap.value() orelse return error.InvalidBootstrap;
    const command = switch (view.command) {
        .verify_predecessor => |value| value,
        .pre_publish, .publish_candidate => return error.InvalidCommand,
    };
    try github_transport.validateToken(token);
    try validateBuffers(buffers, result, bootstrap, view, command, token);
    result.* = .{
        .owner = result,
        .io = io,
        .allocator = allocator,
        .bootstrap = bootstrap,
        .token = token,
        .budget_ns = budget_ns,
        .buffers = buffers,
    };
    phase.runWith(result) catch |err| {
        if (result.hasLiveOwners()) result.clearBorrowed() else result.* = .{};
        return err;
    };
    result.* = .{};
}

fn validateBuffers(
    buffers: Buffers,
    result: *Execution,
    bootstrap: *bootstrap_mod.Bootstrap,
    view: bootstrap_mod.View,
    command: bootstrap_mod.VerifyPredecessor,
    token: []const u8,
) Error!void {
    const values = [_][]u8{ buffers.github_response, buffers.attestation };
    const result_bytes = std.mem.asBytes(result);
    const bootstrap_bytes = std.mem.asBytes(bootstrap);
    const borrowed = [_][]const u8{
        token,                         view.github_cli,              view.context.tag, view.context.source_commit, view.context.build.workflow_ref,
        view.context.repository.owner, view.context.repository.name, command.repo,     command.tag,                command.manifest,
        command.work_dir,              command.summary_out,
    };
    if (rangesOverlap(result_bytes, bootstrap_bytes)) return error.InvalidBuffer;
    for (borrowed) |value| if (rangesOverlap(result_bytes, value)) return error.InvalidBuffer;
    for (values, 0..) |value, index| {
        if (rangesOverlap(value, result_bytes) or rangesOverlap(value, bootstrap_bytes) or
            rangesOverlap(value, token) or rangesOverlap(value, view.github_cli) or
            rangesOverlap(value, view.context.tag) or rangesOverlap(value, view.context.source_commit) or
            rangesOverlap(value, view.context.build.workflow_ref) or rangesOverlap(value, view.context.repository.owner) or
            rangesOverlap(value, view.context.repository.name) or rangesOverlap(value, command.repo) or
            rangesOverlap(value, command.tag) or rangesOverlap(value, command.manifest) or
            rangesOverlap(value, command.work_dir) or rangesOverlap(value, command.summary_out)) return error.InvalidBuffer;
        for (values[index + 1 ..]) |right| if (rangesOverlap(value, right)) return error.InvalidBuffer;
    }
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}

fn copyPath(storage: *[std.fs.max_path_bytes:0]u8, value: []const u8) ![:0]const u8 {
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidBootstrap;
    return std.fmt.bufPrintZ(storage, "{s}", .{value}) catch return error.InvalidBootstrap;
}
