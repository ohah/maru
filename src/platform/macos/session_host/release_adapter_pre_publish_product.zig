//! Production binding for one pre-publish validation transaction.
//!
//! The execution object is caller-owned because a filesystem cleanup failure must retain exact
//! retry capabilities instead of losing them with a local stack frame.

const std = @import("std");
const phase = @import("release_adapter_pre_publish_phase");
const workspace_mod = @import("release_adapter_pre_publish_workspace");
const bootstrap_mod = @import("release_adapter_executable_bootstrap");
const deadline_mod = @import("release_adapter_deadline");
const apple_transport = @import("release_adapter_apple_transport");
const candidate_mod = @import("release_adapter_github_current_manifest_candidate");
const current_release_mod = @import("release_adapter_github_current_release_authority");
const current_input_mod = @import("release_adapter_github_current_manifest_input");
const predecessor_input_mod = @import("release_adapter_github_predecessor_manifest_input");
const predecessor_assets_mod = @import("release_adapter_github_tag_chain_transport");
const product_mod = @import("release_adapter_github_current_product");
const evidence_mod = @import("release_adapter_github_current_evidence");
const asset_files_mod = @import("release_adapter_github_current_asset_files");
const asset_attestation_mod = @import("release_adapter_github_current_asset_attestation");
const compatibility_mod = @import("release_adapter_github_current_compatibility");
const observation_mod = @import("release_adapter_github_current_observation");
const summary_publication = @import("release_adapter_summary_publication");
const github_transport = @import("release_adapter_github_transport");

pub const Error = error{ InvalidOwner, InvalidBootstrap, InvalidCommand, InvalidBuffer, CleanupFailed };

pub const Buffers = struct {
    github_response: []u8 = &.{},
    manifest_download: []u8 = &.{},
    attestation: []u8 = &.{},
    compatibility: []u8 = &.{},
};

const BoundCli = struct {
    path: [:0]const u8,
    pinned: *const current_release_mod.PinnedExecutable,
};

pub const Execution = struct {
    owner: ?*Execution = null,
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,
    bootstrap: ?*bootstrap_mod.Bootstrap = null,
    token: []const u8 = "",
    budget_ns: i128 = 0,
    buffers: Buffers = .{},
    apple_storage: ?*apple_transport.Storage = null,

    deadline: deadline_mod.Deadline = .{},
    workspace: workspace_mod.Workspace = .{},
    candidate: candidate_mod.CurrentManifestCandidate = .{},
    current_release: current_release_mod.CurrentReleaseAuthority = .{},
    current_input: current_input_mod.CurrentManifestInput = .{},
    predecessor_input: predecessor_input_mod.PredecessorManifestInput = .{},
    predecessor_assets: predecessor_assets_mod.Result = .{},
    product: product_mod.CurrentProduct = .{},
    evidence: evidence_mod.CurrentEvidence = .{},
    asset_files: asset_files_mod.CurrentAssetFiles = .{},
    asset_attestations: asset_attestation_mod.CurrentAssetAttestations = .{},
    compatibility: compatibility_mod.CurrentCompatibility = .{},
    observation: observation_mod.CurrentObservation = .{},

    pub fn retryCleanup(self: *@This()) Error!void {
        if (self.owner != self) return error.InvalidOwner;
        self.clearBorrowed();
        var clean = true;
        self.cleanupObservation();
        self.cleanupCompatibility(&self.deadline) catch {
            clean = false;
        };
        self.cleanupAssetAttestations(&self.deadline) catch {
            clean = false;
        };
        self.cleanupAssetFiles(&self.deadline) catch {
            clean = false;
        };
        self.cleanupEvidence(&self.deadline) catch {
            clean = false;
        };
        self.cleanupProduct(&self.deadline) catch {
            clean = false;
        };
        self.cleanupPredecessorAssets(&self.deadline) catch {
            clean = false;
        };
        self.cleanupPredecessorInput(&self.deadline) catch {
            clean = false;
        };
        self.cleanupCurrentInput(&self.deadline) catch {
            clean = false;
        };
        self.cleanupCurrentRelease(&self.deadline) catch {
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

    fn boundCommand(self: *@This()) !bootstrap_mod.PrePublish {
        if (self.owner != self) return error.InvalidOwner;
        const bootstrap = self.bootstrap orelse return error.InvalidBootstrap;
        const view = bootstrap.value() orelse return error.InvalidBootstrap;
        return switch (view.command) {
            .pre_publish => |value| value,
            else => error.InvalidCommand,
        };
    }

    fn boundCli(self: *@This()) !BoundCli {
        const bootstrap = self.bootstrap orelse return error.InvalidBootstrap;
        const view = bootstrap.value() orelse return error.InvalidBootstrap;
        return .{ .path = view.github_cli, .pinned = &bootstrap.cli };
    }

    pub fn startDeadline(self: *@This()) !*deadline_mod.Deadline {
        try deadline_mod.start(self.budget_ns, &self.deadline);
        return &self.deadline;
    }

    pub fn prepareWorkspace(self: *@This(), _: *deadline_mod.Deadline) !void {
        const command_value = try self.boundCommand();
        var storage: [std.fs.max_path_bytes:0]u8 = undefined;
        try workspace_mod.prepare(&self.workspace, try copyPath(&storage, command_value.work_dir));
    }

    pub fn prepareCandidate(self: *@This(), _: *deadline_mod.Deadline) !void {
        const command_value = try self.boundCommand();
        const view = self.bootstrap.?.value() orelse return error.InvalidBootstrap;
        var storage: [std.fs.max_path_bytes:0]u8 = undefined;
        try candidate_mod.read(self.allocator, view.context, try copyPath(&storage, command_value.manifest), &self.candidate);
    }

    pub fn authenticateCurrentRelease(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const candidate = self.candidate.value() orelse return error.InvalidBootstrap;
        const view = self.bootstrap.?.value() orelse return error.InvalidBootstrap;
        const bound_cli = try self.boundCli();
        try current_release_mod.authenticateUntil(self.io, self.allocator, view.context, candidate.*, .{ .path = bound_cli.path, .pinned = bound_cli.pinned }, self.token, self.buffers.github_response, deadline, &self.current_release);
    }

    pub fn authenticateCurrentInput(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const workdir = try self.workspace.childPath(.current_manifest, &path_storage);
        const view = self.bootstrap.?.value() orelse return error.InvalidBootstrap;
        const bound_cli = try self.boundCli();
        try current_input_mod.authenticateCandidateUntil(self.io, self.allocator, view.context, &self.current_release, &self.candidate, workdir, .{ .path = bound_cli.path, .pinned = bound_cli.pinned }, self.token, self.buffers.attestation, deadline, &self.current_input);
    }

    pub fn authenticatePredecessorInput(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const bound_cli = try self.boundCli();
        try predecessor_input_mod.authenticateUntil(self.io, self.allocator, predecessor_input_mod.Current.from(&self.current_input), &self.workspace, .{ .path = bound_cli.path, .pinned = bound_cli.pinned }, self.token, self.buffers.manifest_download, self.buffers.attestation, deadline, &self.predecessor_input);
    }

    pub fn authenticatePredecessorAssets(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const workdir = try self.workspace.childPath(.predecessor_assets, &path_storage);
        const bound_cli = try self.boundCli();
        try predecessor_assets_mod.authenticateUntil(self.io, self.allocator, &self.predecessor_input.authenticated, .{ .path = bound_cli.path, .pinned = bound_cli.pinned }, self.token, workdir, self.buffers.github_response, deadline, &self.predecessor_assets);
    }

    pub fn observeProduct(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const command_value = try self.boundCommand();
        const dmg_work = try self.workspace.childPath(.dmg, &path_storage);
        var dmg_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        var frozen_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        try product_mod.observeUntil(self.allocator, self.io, &self.current_input, .{ .dmg = try copyPath(&dmg_storage, command_value.dmg), .dmg_work = dmg_work, .frozen_executable = try copyPath(&frozen_storage, command_value.frozen_executable) }, self.apple_storage orelse return error.InvalidBootstrap, deadline, &self.product);
    }

    pub fn composeEvidence(self: *@This(), _: *deadline_mod.Deadline) !void {
        const command_value = try self.boundCommand();
        var storage: [std.fs.max_path_bytes:0]u8 = undefined;
        try evidence_mod.compose(self.allocator, &self.current_input, &self.predecessor_input.authenticated, try copyPath(&storage, command_value.evidence), &self.evidence);
    }

    pub fn composeAssetFiles(self: *@This(), _: *deadline_mod.Deadline) !void {
        var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const command_value = try self.boundCommand();
        const workdir = try self.workspace.childPath(.current_assets, &path_storage);
        var dmg_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        var frozen_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        try asset_files_mod.compose(&self.current_input, &self.product, &self.evidence, .{ .dmg = try copyPath(&dmg_storage, command_value.dmg), .frozen_executable = try copyPath(&frozen_storage, command_value.frozen_executable), .workdir = workdir }, &self.asset_files);
    }

    pub fn attestAssets(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const bound_cli = try self.boundCli();
        try asset_attestation_mod.composeUntil(self.io, self.allocator, &self.current_input, &self.asset_files, .{ .path = bound_cli.path, .pinned = bound_cli.pinned }, self.token, self.buffers.attestation, deadline, &self.asset_attestations);
    }

    pub fn composeCompatibility(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const command_value = try self.boundCommand();
        var storage: [std.fs.max_path_bytes:0]u8 = undefined;
        try compatibility_mod.composeUntil(self.io, &self.current_input, &self.product, try copyPath(&storage, command_value.frozen_executable), self.buffers.compatibility, deadline, &self.compatibility);
    }

    pub fn composeObservation(self: *@This(), _: *deadline_mod.Deadline) !void {
        try observation_mod.compose(self.allocator, &self.current_input, &self.predecessor_input.authenticated, &self.predecessor_assets, &self.product, &self.evidence, &self.asset_files, &self.asset_attestations, &self.compatibility, &self.observation);
    }

    pub fn validatePublication(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        if (deadline != &self.deadline) return error.InvalidOwner;
        _ = try deadline.remaining();
    }

    pub fn publishSummary(self: *@This()) !void {
        const command_value = try self.boundCommand();
        var storage: [std.fs.max_path_bytes:0]u8 = undefined;
        try summary_publication.publishPrePublish(self.allocator, &self.observation, try copyPath(&storage, command_value.summary_out));
    }

    pub fn cleanupObservation(self: *@This()) void {
        if (self.observation.owner != null) self.observation.deinit() catch unreachable;
    }
    pub fn cleanupCompatibility(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.compatibility.owner != null) try self.compatibility.deinit();
    }
    pub fn cleanupAssetAttestations(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.asset_attestations.owner != null) try self.asset_attestations.deinit(self.allocator);
    }
    pub fn cleanupAssetFiles(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.asset_files.owner != null) try self.asset_files.deinit();
    }
    pub fn cleanupEvidence(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.evidence.owner != null) try self.evidence.deinit(self.allocator);
    }
    pub fn cleanupProduct(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.product.owner != null) try self.product.deinit(self.allocator);
    }
    pub fn cleanupPredecessorAssets(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.predecessor_assets.owner != null) try self.predecessor_assets.cleanup();
    }
    pub fn cleanupPredecessorInput(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.predecessor_input.owner != null) try self.predecessor_input.deinit(self.allocator);
    }
    pub fn cleanupCurrentInput(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.current_input.owner != null) try self.current_input.deinit(self.allocator);
    }
    pub fn cleanupCurrentRelease(self: *@This(), _: *deadline_mod.Deadline) !void {
        if (self.current_release.owner != null) try self.current_release.deinit();
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

    fn hasLiveOwners(self: *const @This()) bool {
        return self.deadline.owner != null or self.workspace.owner != null or self.candidate.owner != null or
            self.current_release.owner != null or self.current_input.owner != null or self.predecessor_input.owner != null or
            self.predecessor_assets.owner != null or self.product.owner != null or self.evidence.owner != null or
            self.asset_files.owner != null or self.asset_attestations.owner != null or self.compatibility.owner != null or
            self.observation.owner != null;
    }

    fn clearBorrowed(self: *@This()) void {
        self.bootstrap = null;
        self.token = "";
        self.budget_ns = 0;
        self.buffers = .{};
        self.apple_storage = null;
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, bootstrap: *bootstrap_mod.Bootstrap, token: []const u8, budget_ns: i128, buffers: Buffers, apple_storage: *apple_transport.Storage, result: *Execution) !void {
    if (result.owner != null or result.hasLiveOwners()) return error.InvalidOwner;
    const view = bootstrap.value() orelse return error.InvalidBootstrap;
    const command_value = switch (view.command) {
        .pre_publish => |value| value,
        else => return error.InvalidCommand,
    };
    try github_transport.validateToken(token);
    try validateBuffers(buffers, apple_storage, result, bootstrap, view, command_value, token);
    result.* = .{ .owner = result, .io = io, .allocator = allocator, .bootstrap = bootstrap, .token = token, .budget_ns = budget_ns, .buffers = buffers, .apple_storage = apple_storage };
    phase.runWith(result) catch |err| {
        if (result.hasLiveOwners()) result.clearBorrowed() else result.* = .{};
        return err;
    };
    result.* = .{};
}

fn validateBuffers(buffers: Buffers, apple_storage: *apple_transport.Storage, result: *Execution, bootstrap: *bootstrap_mod.Bootstrap, view: bootstrap_mod.View, command: bootstrap_mod.PrePublish, token: []const u8) Error!void {
    const values = [_][]u8{ buffers.github_response, buffers.manifest_download, buffers.attestation, buffers.compatibility };
    const apple_bytes = std.mem.asBytes(apple_storage);
    const result_bytes = std.mem.asBytes(result);
    const bootstrap_bytes = std.mem.asBytes(bootstrap);
    const borrowed = [_][]const u8{
        token,                         view.github_cli,              view.context.tag,          view.context.source_commit, view.context.build.workflow_ref,
        view.context.repository.owner, view.context.repository.name, command.repo,              command.tag,                command.manifest,
        command.evidence,              command.dmg,                  command.frozen_executable, command.work_dir,           command.summary_out,
    };
    if (rangesOverlap(result_bytes, bootstrap_bytes)) return error.InvalidBuffer;
    for (borrowed) |value| if (rangesOverlap(result_bytes, value)) return error.InvalidBuffer;
    if (rangesOverlap(apple_bytes, result_bytes) or rangesOverlap(apple_bytes, bootstrap_bytes) or
        rangesOverlap(apple_bytes, token) or rangesOverlap(apple_bytes, view.github_cli) or
        rangesOverlap(apple_bytes, view.context.tag) or rangesOverlap(apple_bytes, view.context.source_commit) or
        rangesOverlap(apple_bytes, view.context.build.workflow_ref) or rangesOverlap(apple_bytes, view.context.repository.owner) or
        rangesOverlap(apple_bytes, view.context.repository.name) or rangesOverlap(apple_bytes, command.repo) or
        rangesOverlap(apple_bytes, command.tag) or rangesOverlap(apple_bytes, command.manifest) or rangesOverlap(apple_bytes, command.evidence) or
        rangesOverlap(apple_bytes, command.dmg) or rangesOverlap(apple_bytes, command.frozen_executable) or
        rangesOverlap(apple_bytes, command.work_dir) or rangesOverlap(apple_bytes, command.summary_out))
        return error.InvalidBuffer;
    for (values, 0..) |value, index| {
        if (rangesOverlap(value, result_bytes) or rangesOverlap(value, bootstrap_bytes) or
            rangesOverlap(value, token) or rangesOverlap(value, view.github_cli) or rangesOverlap(value, view.context.tag) or
            rangesOverlap(value, view.context.source_commit) or rangesOverlap(value, view.context.build.workflow_ref) or
            rangesOverlap(value, view.context.repository.owner) or rangesOverlap(value, view.context.repository.name) or
            rangesOverlap(value, command.repo) or rangesOverlap(value, command.tag) or rangesOverlap(value, command.manifest) or
            rangesOverlap(value, command.evidence) or rangesOverlap(value, command.dmg) or
            rangesOverlap(value, command.frozen_executable) or rangesOverlap(value, command.work_dir) or
            rangesOverlap(value, command.summary_out)) return error.InvalidBuffer;
        if (rangesOverlap(value, apple_bytes)) return error.InvalidBuffer;
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
