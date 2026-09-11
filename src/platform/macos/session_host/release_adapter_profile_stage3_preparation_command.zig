//! Sealed executable owner for the upgrade-B stage-3 fresh-process command.

const std = @import("std");
const builtin = @import("builtin");
const phase = @import("release_adapter_profile_stage3_preparation_command_phase");
const bootstrap_mod = @import("release_adapter_executable_bootstrap");
const profile_mod = @import("release_adapter_profile_endorsement");
const prerequisite_mod = @import("release_adapter_candidate_prerequisite_product");
const pre_publish_workspace = @import("release_adapter_pre_publish_workspace");
const manifest_input_mod = @import("release_adapter_profile_predecessor_manifest_input");
const upgrade_workspace_mod = @import("release_adapter_candidate_upgrade_workspace");
const source_authority = @import("release_adapter_source_directory_authority");
const zig_authority = @import("release_adapter_zig_toolchain_authority");
const upgrade_mod = @import("release_adapter_profile_upgrade_execution");
const stage3_product = @import("release_adapter_profile_stage3_preparation_product");
const timing_mod = @import("release_adapter_profile_upgrade_timing_artifact");
const deadline_mod = @import("release_adapter_deadline");
const outcome_contract = @import("release_adapter_command_outcome");
const release_manifest = @import("release_manifest");
const github_transport = @import("release_adapter_github_transport");
const github_attestation = @import("release_adapter_github_attestation");

pub const Bootstrap = bootstrap_mod.Bootstrap;
pub const Environment = profile_mod.Environment;
pub const Outcome = outcome_contract.Stage3;
pub const exitCode = outcome_contract.stage3ExitCode;
pub const stderrLine = outcome_contract.stage3StderrLine;
pub const max_github_response_bytes: usize = github_transport.max_capture_bytes;
pub const max_manifest_download_bytes: usize = release_manifest.max_manifest_bytes;
pub const max_attestation_response_bytes: usize = github_attestation.max_response_bytes;
const max_token_bytes: usize = 4 * 1024;

pub const Buffers = struct {
    github_response: []u8,
    manifest_download: []u8,
    attestation_response: []u8,
};

const StoredPath = struct {
    len: usize = 0,
    bytes: [std.fs.max_path_bytes:0]u8 = @splat(0),
    fn set(self: *@This(), path: []const u8) !void {
        if (path.len == 0 or path.len >= self.bytes.len or std.mem.indexOfScalar(u8, path, 0) != null)
            return error.InvalidBootstrap;
        @memcpy(self.bytes[0..path.len], path);
        self.bytes[path.len] = 0;
        self.len = path.len;
    }
    fn value(self: *const @This()) [:0]const u8 {
        return self.bytes[0..self.len :0];
    }
};

const Paths = struct {
    dmg: StoredPath = .{},
    frozen: StoredPath = .{},
    dmg_bundle: StoredPath = .{},
    frozen_bundle: StoredPath = .{},
    dmg_work: StoredPath = .{},
    signed_cli_ssh: StoredPath = .{},
    manifest: StoredPath = .{},
    source_root: StoredPath = .{},
    zig: StoredPath = .{},
    predecessor_workspace: StoredPath = .{},
    upgrade_workspace: StoredPath = .{},
    durable: StoredPath = .{},
    timing: StoredPath = .{},
};

pub const Execution = struct {
    owner: ?*Execution = null,
    transaction: phase.Transaction = .{},
    profile: profile_mod.Owner = .{},
    prerequisite: prerequisite_mod.Execution = .{},
    predecessor_workspace: pre_publish_workspace.Workspace = .{},
    manifest_input: manifest_input_mod.ProfileManifestInput = .{},
    upgrade_workspace: upgrade_workspace_mod.Workspace = .{},
    source: source_authority.SourceDirectory = .{},
    toolchain: zig_authority.ZigToolchainAuthority = .{},
    upgrade: upgrade_mod.ProfileUpgradeExecution = .{},
    product: stage3_product.Execution = .{},
    timing: timing_mod.Artifact = .{},
    paths: Paths = .{},
    bootstrap_sha256: [32]u8 = @splat(0),
    paths_sha256: [32]u8 = @splat(0),
    seal: [32]u8 = @splat(0),
    bootstrap: ?*Bootstrap = null,
    environment: ?Environment = null,
    token: []const u8 = "",
    buffers: ?Buffers = null,
    budget_ns: i128 = 0,
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and self.transaction.isPristineForComposition() and
            self.profile.isPristineForComposition() and self.prerequisite.isPristineForComposition() and
            self.predecessor_workspace.owner == null and self.manifest_input.owner == null and
            self.upgrade_workspace.owner == null and self.source.owner == null and self.toolchain.owner == null and
            self.upgrade.isPristineForComposition() and self.product.isPristineForComposition() and
            self.timing.isPristineForComposition() and pathsPristine(&self.paths) and
            allZero(&self.bootstrap_sha256) and allZero(&self.paths_sha256) and allZero(&self.seal) and !self.hasBorrowed();
    }
    pub fn needsAudit(self: *const @This()) bool {
        return self.validSeal() and self.transaction.needsAudit() and !self.hasBorrowed();
    }
    pub fn localCleanupComplete(self: *const @This()) bool {
        return self.needsAudit() and self.transaction.localCleanupComplete();
    }
    pub fn retryCleanup(self: *@This()) !void {
        if (!self.validSeal() or !self.transaction.needsCleanup() or self.hasBorrowed()) return error.InvalidOwner;
        var product = Product{ .execution = self };
        try phase.retryCleanupWith(&product, &self.transaction);
        self.* = .{};
    }
    pub fn retryAuditCleanup(self: *@This()) !void {
        if (!self.needsAudit() or self.localCleanupComplete()) return error.InvalidOwner;
        var product = Product{ .execution = self };
        try phase.retryAuditCleanupWith(&product, &self.transaction);
    }
    fn hasBorrowed(self: *const @This()) bool {
        return self.bootstrap != null or self.environment != null or self.token.len != 0 or
            self.buffers != null or self.budget_ns != 0;
    }
    fn clearBorrowed(self: *@This()) void {
        self.bootstrap = null;
        self.environment = null;
        self.token = "";
        self.buffers = null;
        self.budget_ns = 0;
    }
    fn validSeal(self: *const @This()) bool {
        const digest = pathsDigest(&self.paths) catch return false;
        return self.owner == self and std.mem.eql(u8, &digest, &self.paths_sha256) and
            std.mem.eql(u8, &self.seal, &driverSeal(self));
    }
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    bootstrap: *Bootstrap,
    environment: Environment,
    token: []const u8,
    buffers: Buffers,
    budget_ns: i128,
    execution: *Execution,
) !void {
    if (!execution.isPristineForComposition() or budget_ns <= 0) return error.InvalidOwner;
    try validateBuffers(execution, bootstrap, environment, token, buffers);
    const view = try bootstrapView(bootstrap);
    const command = switch (view.command) {
        .prepare_profile_candidate => |value| value,
        else => return error.InvalidCommand,
    };
    try validateAliases(execution, view, command, token, buffers);
    var paths: Paths = .{};
    try copyPaths(&paths, command);
    execution.* = .{
        .owner = execution,
        .paths = paths,
        .bootstrap_sha256 = bootstrapDigest(view),
        .paths_sha256 = try pathsDigest(&paths),
        .bootstrap = bootstrap,
        .environment = environment,
        .token = token,
        .buffers = buffers,
        .budget_ns = budget_ns,
        .io = io,
        .allocator = allocator,
    };
    execution.seal = driverSeal(execution);
    var product = Product{ .execution = execution };
    phase.executeWith(&product, &execution.transaction) catch |err| {
        execution.clearBorrowed();
        return err;
    };
    execution.clearBorrowed();
    execution.* = .{};
}

pub fn runOutcome(io: std.Io, allocator: std.mem.Allocator, bootstrap: *Bootstrap, environment: Environment, token: []const u8, buffers: Buffers, budget_ns: i128, execution: *Execution) Outcome {
    run(io, allocator, bootstrap, environment, token, buffers, budget_ns, execution) catch return settleExecution(execution);
    return .success;
}

const Product = struct {
    execution: *Execution,
    fn require(self: *@This()) !struct { bootstrap_mod.View, bootstrap_mod.PrepareProfileCandidate } {
        if (!self.execution.validSeal()) return error.AuthorityChanged;
        const view = try bootstrapView(self.execution.bootstrap.?);
        if (!std.mem.eql(u8, &self.execution.bootstrap_sha256, &bootstrapDigest(view))) return error.AuthorityChanged;
        const command = switch (view.command) {
            .prepare_profile_candidate => |value| value,
            else => return error.AuthorityChanged,
        };
        return .{ view, command };
    }
    pub fn validatePreflight(self: *@This()) !void {
        _ = try self.require();
    }
    pub fn bindProfile(self: *@This()) !void {
        const current = try self.require();
        try profile_mod.bindFromEnvironment(self.execution.allocator, current[0].context, self.execution.environment.?, &self.execution.profile);
        if ((try self.execution.profile.revalidateEnvironment(self.execution.allocator, current[0].context, self.execution.environment.?)).profile() != .upgrade_b)
            return error.ProfileMismatch;
    }
    pub fn runPrerequisite(self: *@This()) !void {
        const current = try self.require();
        const b = self.execution.buffers.?;
        try prerequisite_mod.run(self.execution.io, self.execution.allocator, .{
            .context = current[0].context,
            .test_uuid = current[1].test_uuid,
            .paths = .{ .dmg = self.execution.paths.dmg.value(), .frozen_executable = self.execution.paths.frozen.value(), .dmg_work = self.execution.paths.dmg_work.value() },
            .bundles = .{ .dmg_bundle = self.execution.paths.dmg_bundle.value(), .frozen_bundle = self.execution.paths.frozen_bundle.value() },
            .cli = .{ .path = current[0].github_cli, .pinned = &self.execution.bootstrap.?.cli },
        }, self.execution.token, b.github_response, self.execution.budget_ns, &self.execution.prerequisite);
    }
    pub fn prerequisiteNeedsAudit(self: *@This()) bool {
        return self.execution.prerequisite.needsAudit();
    }
    pub fn preparePredecessorWorkspace(self: *@This()) !void {
        _ = try self.require();
        try pre_publish_workspace.prepare(&self.execution.predecessor_workspace, self.execution.paths.predecessor_workspace.value());
    }
    pub fn authenticateManifest(self: *@This()) !void {
        const current = try self.require();
        const b = self.execution.buffers.?;
        var deadline: deadline_mod.Deadline = .{};
        try deadline_mod.start(self.execution.budget_ns, &deadline);
        manifest_input_mod.authenticateUntil(self.execution.io, self.execution.allocator, current[0].context, self.execution.environment.?, &self.execution.profile, &self.execution.predecessor_workspace, .{ .path = current[0].github_cli, .pinned = &self.execution.bootstrap.?.cli }, self.execution.token, b.manifest_download, b.attestation_response, &deadline, &self.execution.manifest_input) catch |err| {
            deadline.deinit() catch return error.CleanupFailed;
            return err;
        };
        try deadline.deinit();
    }
    pub fn prepareUpgradeWorkspace(self: *@This()) !void {
        _ = try self.require();
        try upgrade_workspace_mod.prepare(&self.execution.upgrade_workspace, self.execution.paths.upgrade_workspace.value());
    }
    pub fn bindAuthorities(self: *@This()) !void {
        const current = try self.require();
        try source_authority.prepareCurrent(&self.execution.source, self.execution.bootstrap.?);
        var digest: [64]u8 = undefined;
        @memcpy(&digest, current[1].zig_sha256);
        try zig_authority.bind(current[0].context, current[0].runner, self.execution.paths.zig.value(), .{ .size = current[1].zig_size, .sha256 = digest }, &self.execution.toolchain);
    }
    pub fn runProfileUpgrade(self: *@This()) !void {
        const current = try self.require();
        const source = try self.execution.source.value();
        const paths = try self.execution.upgrade_workspace.value();
        _ = paths;
        try upgrade_mod.run(self.execution.io, self.execution.allocator, .{
            .context = current[0].context,
            .environment = self.execution.environment.?,
            .profile = &self.execution.profile,
            .manifest_input = &self.execution.manifest_input,
            .predecessor_workspace = &self.execution.predecessor_workspace,
            .cli = .{ .path = current[0].github_cli, .pinned = &self.execution.bootstrap.?.cli },
            .token = self.execution.token,
            .response = self.execution.buffers.?.github_response,
            .candidate = &self.execution.prerequisite.identity,
            .files = &self.execution.prerequisite.files,
            .product = &self.execution.prerequisite.product,
            .candidate_paths = .{ .dmg = self.execution.paths.dmg.value(), .frozen_executable = self.execution.paths.frozen.value(), .dmg_work = self.execution.paths.dmg_work.value() },
            .signed_cli_ssh = self.execution.paths.signed_cli_ssh.value(),
            .source = &self.execution.prerequisite.source,
            .workspace = &self.execution.upgrade_workspace,
            .toolchain = &self.execution.toolchain,
            .source_directory_fd = source.fd,
        }, self.execution.budget_ns, &self.execution.upgrade);
    }
    pub fn prepareDurable(self: *@This()) !void {
        const current = try self.require();
        try stage3_product.run(self.execution.allocator, .{
            .context = current[0].context,
            .environment = self.execution.environment.?,
            .profile = &self.execution.profile,
            .upgrade = &self.execution.upgrade,
            .manifest_input = &self.execution.manifest_input,
            .candidate = &self.execution.prerequisite.identity,
            .files = &self.execution.prerequisite.files,
            .product = &self.execution.prerequisite.product,
            .candidate_paths = .{ .dmg = self.execution.paths.dmg.value(), .frozen_executable = self.execution.paths.frozen.value(), .dmg_work = self.execution.paths.dmg_work.value() },
            .source = &self.execution.prerequisite.source,
            .compatibility = &self.execution.prerequisite.compatibility,
            .workspace = &self.execution.upgrade_workspace,
            .manifest = self.execution.paths.manifest.value(),
            .durable_preparation = self.execution.paths.durable.value(),
        }, self.execution.budget_ns, &self.execution.product);
    }
    pub fn durableRetained(self: *@This()) bool {
        return self.execution.product.retainedCommit();
    }
    pub fn publishTiming(self: *@This()) !void {
        const current = try self.require();
        try timing_mod.publish(self.execution.allocator, current[0].context, &self.execution.upgrade, self.execution.paths.timing.value(), &self.execution.timing);
    }
    pub fn timingNeedsAudit(self: *@This()) bool {
        return self.execution.timing.phase == .audit_required;
    }
    pub fn closeTimingRetaining(self: *@This()) !void {
        _ = try self.require();
        try self.execution.timing.closeRetaining();
    }
    pub fn cleanup(self: *@This(), stage: phase.Stage) !void {
        return switch (stage) {
            .timing => cleanupTiming(self.execution),
            .durable => cleanupProduct(self.execution),
            .profile_upgrade => cleanupUpgrade(self.execution),
            .authorities => cleanupAuthorities(self.execution),
            .upgrade_workspace => cleanupUpgradeWorkspace(self.execution),
            .manifest_input => cleanupManifestInput(self.execution),
            .predecessor_workspace => cleanupPredecessorWorkspace(self.execution),
            .prerequisite => cleanupPrerequisite(self.execution),
            .profile => cleanupProfile(self.execution),
            else => error.InvalidOwner,
        };
    }
};

fn cleanupTiming(e: *Execution) !void {
    if (!e.timing.isPristineForComposition()) try e.timing.cleanup();
}
fn cleanupProduct(e: *Execution) !void {
    if (e.product.isPristineForComposition()) return;
    if (e.product.transaction.needsAudit()) {
        if (!e.product.localCleanupComplete()) try e.product.retryAuditCleanup();
        return;
    }
    if (e.product.transaction.needsCleanup()) return e.product.retryCleanup();
    return error.DependencyLive;
}
fn cleanupUpgrade(e: *Execution) !void {
    if (e.upgrade.isPristineForComposition()) return;
    if (e.upgrade.ownsSuccessfulOutputs()) return e.upgrade.cleanup();
    return upgrade_mod.retryCleanup(&e.upgrade);
}
fn cleanupAuthorities(e: *Execution) !void {
    var failed = false;
    if (e.toolchain.owner != null) e.toolchain.deinit() catch {
        failed = true;
    };
    if (e.source.owner != null) e.source.deinit() catch {
        failed = true;
    };
    if (failed) return error.CleanupFailed;
}
fn cleanupUpgradeWorkspace(e: *Execution) !void {
    if (e.upgrade_workspace.owner != null) try e.upgrade_workspace.cleanup();
}
fn cleanupManifestInput(e: *Execution) !void {
    if (e.manifest_input.owner != null) try e.manifest_input.deinit(e.allocator);
}
fn cleanupPredecessorWorkspace(e: *Execution) !void {
    if (e.predecessor_workspace.owner != null) try e.predecessor_workspace.cleanup();
}
fn cleanupPrerequisite(e: *Execution) !void {
    if (e.prerequisite.isPristineForComposition()) return;
    if (e.prerequisite.ownsCompletePrerequisites()) return e.prerequisite.cleanup();
    if (e.prerequisite.transaction.needsCleanup()) return e.prerequisite.retryCleanup();
    return error.DependencyLive;
}
fn cleanupProfile(e: *Execution) !void {
    if (e.profile.owner != null) try e.profile.deinit();
}

fn settleExecution(execution: anytype) Outcome {
    if (execution.owner == null) return .local_failure;
    if (execution.needsAudit()) {
        if (!execution.localCleanupComplete()) execution.retryAuditCleanup() catch return .cleanup_failed;
        return .audit_required;
    }
    execution.retryCleanup() catch return .cleanup_failed;
    return .local_failure;
}

fn bootstrapView(bootstrap: *Bootstrap) !bootstrap_mod.View {
    if (bootstrap.owner != bootstrap or bootstrap.cli_path_len >= bootstrap.cli_path_storage.len or
        bootstrap.cli_path_storage[bootstrap.cli_path_len] != 0) return error.InvalidBootstrap;
    return bootstrap.value() orelse error.InvalidBootstrap;
}
fn copyPaths(paths: *Paths, command: bootstrap_mod.PrepareProfileCandidate) !void {
    try paths.dmg.set(command.dmg);
    try paths.frozen.set(command.frozen_executable);
    try paths.dmg_bundle.set(command.candidate_dmg_bundle);
    try paths.frozen_bundle.set(command.candidate_frozen_bundle);
    try paths.dmg_work.set(command.dmg_work);
    try paths.signed_cli_ssh.set(command.signed_cli_ssh);
    try paths.manifest.set(command.manifest);
    try paths.source_root.set(command.source_root);
    try paths.zig.set(command.zig);
    try paths.predecessor_workspace.set(command.predecessor_workspace);
    try paths.upgrade_workspace.set(command.upgrade_workspace);
    try paths.durable.set(command.durable_preparation);
    try paths.timing.set(command.timing_output);
}
fn validateBuffers(execution: *Execution, bootstrap: *Bootstrap, environment: Environment, token: []const u8, buffers: Buffers) !void {
    if (!validScalar(token, max_token_bytes) or buffers.github_response.len == 0 or buffers.github_response.len > max_github_response_bytes or
        buffers.manifest_download.len == 0 or buffers.manifest_download.len > max_manifest_download_bytes or
        buffers.attestation_response.len == 0 or buffers.attestation_response.len > max_attestation_response_bytes) return error.InvalidOwner;
    const regions = [_][]const u8{ std.mem.asBytes(execution), std.mem.asBytes(bootstrap), token, buffers.github_response, buffers.manifest_download, buffers.attestation_response };
    for (regions, 0..) |left, index| for (regions[index + 1 ..]) |right| if (overlaps(left, right)) return error.InvalidOwner;
    const pointer = @intFromPtr(environment.context);
    for (regions) |region| if (pointer >= @intFromPtr(region.ptr) and pointer < @intFromPtr(region.ptr) + region.len) return error.InvalidOwner;
}
fn validateAliases(execution: *Execution, view: bootstrap_mod.View, command: bootstrap_mod.PrepareProfileCandidate, token: []const u8, buffers: Buffers) !void {
    const protected = [_][]const u8{ std.mem.asBytes(execution), token, buffers.github_response, buffers.manifest_download, buffers.attestation_response };
    const borrowed = [_][]const u8{
        view.context.repository.owner,   view.context.repository.name, view.context.tag,          view.context.source_commit,
        view.context.build.workflow_ref, view.github_cli,              command.repo,              command.tag,
        command.test_uuid,               command.dmg,                  command.frozen_executable, command.candidate_dmg_bundle,
        command.candidate_frozen_bundle, command.dmg_work,             command.signed_cli_ssh,    command.manifest,
        command.source_root,             command.zig,                  command.zig_sha256,        command.predecessor_workspace,
        command.upgrade_workspace,       command.durable_preparation,  command.timing_output,
    };
    for (borrowed, 0..) |value, index| {
        for (protected) |region| if (overlaps(value, region)) return error.InvalidOwner;
        for (borrowed[0..index]) |prior| if (overlaps(value, prior)) return error.InvalidOwner;
    }
}
fn pathsDigest(paths: *const Paths) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    try hashPath(&hash, &paths.dmg);
    try hashPath(&hash, &paths.frozen);
    try hashPath(&hash, &paths.dmg_bundle);
    try hashPath(&hash, &paths.frozen_bundle);
    try hashPath(&hash, &paths.dmg_work);
    try hashPath(&hash, &paths.signed_cli_ssh);
    try hashPath(&hash, &paths.manifest);
    try hashPath(&hash, &paths.source_root);
    try hashPath(&hash, &paths.zig);
    try hashPath(&hash, &paths.predecessor_workspace);
    try hashPath(&hash, &paths.upgrade_workspace);
    try hashPath(&hash, &paths.durable);
    try hashPath(&hash, &paths.timing);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}
fn hashPath(hash: *std.crypto.hash.sha2.Sha256, path: *const StoredPath) !void {
    if (path.len == 0 or path.len >= path.bytes.len or path.bytes[path.len] != 0) return error.InvalidPath;
    hash.update(path.bytes[0..path.len]);
    hash.update(&.{0});
}
fn bootstrapDigest(view: bootstrap_mod.View) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashSlice(&hash, view.context.repository.owner);
    hashSlice(&hash, view.context.repository.name);
    hash.update(std.mem.asBytes(&view.context.repository.id));
    hashSlice(&hash, view.context.tag);
    hashSlice(&hash, view.context.source_commit);
    hashSlice(&hash, view.context.build.workflow_ref);
    hash.update(std.mem.asBytes(&view.context.build.run_id));
    hash.update(std.mem.asBytes(&view.context.build.run_attempt));
    hash.update(std.mem.asBytes(&view.context.protected_tag));
    hashSlice(&hash, view.github_cli);
    hash.update(&view.runner.workflow_sha);
    hash.update(&view.cli.path_sha256);
    hash.update(std.mem.asBytes(&view.cli.path_len));
    hash.update(std.mem.asBytes(&view.cli.identity.device));
    hash.update(std.mem.asBytes(&view.cli.identity.inode));
    hash.update(std.mem.asBytes(&view.cli.size));
    hash.update(std.mem.asBytes(&view.cli.mode));
    hash.update(&view.cli.sha256);
    switch (view.command) {
        .prepare_profile_candidate => |c| {
            hashSlice(&hash, c.repo);
            hashSlice(&hash, c.tag);
            hashSlice(&hash, c.test_uuid);
            hashSlice(&hash, c.dmg);
            hashSlice(&hash, c.frozen_executable);
            hashSlice(&hash, c.candidate_dmg_bundle);
            hashSlice(&hash, c.candidate_frozen_bundle);
            hashSlice(&hash, c.dmg_work);
            hashSlice(&hash, c.manifest);
            hashSlice(&hash, c.source_root);
            hashSlice(&hash, c.zig);
            hash.update(std.mem.asBytes(&c.zig_size));
            hashSlice(&hash, c.zig_sha256);
            hashSlice(&hash, c.predecessor_workspace);
            hashSlice(&hash, c.upgrade_workspace);
            hashSlice(&hash, c.durable_preparation);
            hashSlice(&hash, c.timing_output);
        },
        else => hash.update(@tagName(view.command)),
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}
fn driverSeal(e: *const Execution) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const address = @intFromPtr(e);
    hash.update(std.mem.asBytes(&address));
    hash.update(&e.bootstrap_sha256);
    hash.update(&e.paths_sha256);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}
fn hashSlice(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hash.update(value);
    hash.update(&.{0});
}
fn validScalar(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
fn pathsPristine(paths: *const Paths) bool {
    return pathPristine(&paths.dmg) and pathPristine(&paths.frozen) and
        pathPristine(&paths.dmg_bundle) and pathPristine(&paths.frozen_bundle) and
        pathPristine(&paths.dmg_work) and pathPristine(&paths.signed_cli_ssh) and pathPristine(&paths.manifest) and
        pathPristine(&paths.source_root) and pathPristine(&paths.zig) and
        pathPristine(&paths.predecessor_workspace) and pathPristine(&paths.upgrade_workspace) and
        pathPristine(&paths.durable) and pathPristine(&paths.timing);
}
fn pathPristine(path: *const StoredPath) bool {
    return path.len == 0 and allZero(&path.bytes);
}
fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const le = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const re = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < re and @intFromPtr(right.ptr) < le;
}
fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

pub const testing_api = if (builtin.is_test) struct {
    pub fn settle(execution: anytype) Outcome {
        return settleExecution(execution);
    }
} else struct {};
