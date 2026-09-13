//! Filesystem and remote-authority composition for the protected Notification Center verdict.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const evidence = @import("release_evidence");
const record = @import("release_adapter_notification_workflow_record");
const current = @import("release_adapter_github_current_authority");
const attestation = @import("release_adapter_github_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");
const bundle_contract = @import("release_adapter_attestation_bundle_contract");

pub const final_name = "session-host-notification-workflow-pass.json";

pub const Command = struct {
    cli_path: [:0]const u8,
    cli_sha256: []const u8,
    evidence_path: [:0]const u8,
    bundle_path: [:0]const u8,
    output_path: [:0]const u8,
};

pub fn verify(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    command: Command,
    token: []const u8,
    budget_ns: i128,
) !void {
    const pinned_cli = try cli_authority.pin(allocator, command.cli_path, command.cli_sha256);
    var deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(budget_ns, &deadline);
    defer deadline.deinit() catch {};
    var remote = Remote{ .io = io, .allocator = allocator, .context = context, .cli = .{ .path = command.cli_path, .pinned = &pinned_cli }, .token = token, .deadline = &deadline };
    try verifyWith(allocator, context, command, &remote);
}

pub fn verifyWith(allocator: std.mem.Allocator, context: context_mod.Context, command: Command, remote: anytype) !void {
    try context_mod.validateTrusted(context);
    if (!exactOutput(command.output_path) or !pairwiseDistinct([_][]const u8{ command.cli_path, command.evidence_path, command.bundle_path, command.output_path })) return error.InvalidPath;

    var evidence_file: files.PinnedReleaseFile = .{};
    try files.pinReleaseFileObserved(&evidence_file, command.evidence_path, false, evidence.max_evidence_bytes);
    defer evidence_file.deinit() catch {};
    var bundle_file: files.PinnedReleaseFile = .{};
    try files.pinReleaseFileObserved(&bundle_file, command.bundle_path, false, bundle_contract.max_bytes);
    defer bundle_file.deinit() catch {};
    const evidence_observation = evidence_file.value() orelse return error.InvalidEvidence;
    const bundle_observation = bundle_file.value() orelse return error.InvalidBundle;
    if (evidence_observation.identity.device == bundle_observation.identity.device and
        evidence_observation.identity.inode == bundle_observation.identity.inode) return error.InvalidPath;
    var input = try evidence_file.readHeldAlloc(allocator, command.evidence_path, evidence.max_evidence_bytes);
    defer input.deinit(allocator);
    var leaf = try evidence.parseNotificationCenterLeaf(allocator, input.bytes);
    defer leaf.deinit();

    const authority = try remote.authenticate();
    const attested = try remote.attest(command.evidence_path, command.bundle_path, std.fs.path.basename(command.evidence_path), &evidence_observation.sha256);
    _ = try evidence_file.revalidate(command.evidence_path);
    _ = try bundle_file.revalidate(command.bundle_path);
    try remote.revalidateCli();

    const bytes = try record.encode(allocator, context, leaf.value, std.fs.path.basename(command.evidence_path), &evidence_observation.sha256, authority, attested);
    defer allocator.free(bytes);
    var parsed = try record.parse(allocator, bytes);
    parsed.deinit();
    _ = try evidence_file.revalidate(command.evidence_path);
    _ = try bundle_file.revalidate(command.bundle_path);
    try remote.revalidateCli();
    var published: files.PinnedReleaseFile = .{};
    try files.publishSummaryOwnedExclusiveMode(&published, command.output_path, bytes, 0o400);
    defer published.deinit() catch {};
}

const Remote = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    cli: current.Cli,
    token: []const u8,
    deadline: *deadline_mod.Deadline,
    response: [65536]u8 = undefined,

    fn authenticate(self: *@This()) !record.Authority {
        var result: current.CurrentGitHubAuthority = .{};
        try current.authenticateProfilePhaseUntil(self.io, self.allocator, self.context, self.cli, self.token, &self.response, self.deadline, .notification_product, .completed, &result);
        defer result.deinit() catch {};
        const value = result.value() orelse return error.InvalidAuthority;
        if (!std.mem.eql(u8, value.source_commit, self.context.source_commit)) return error.InvalidAuthority;
        return .{ .repository_id = value.repository_id, .run_id = value.run_id, .run_attempt = value.run_attempt, .source_commit = self.context.source_commit, .job_id = value.job_id, .deployment_id = value.deployment_id, .environment_id = value.environment_id, .protected_environment = value.protected_environment };
    }

    fn attest(self: *@This(), evidence_path: []const u8, bundle_path: []const u8, name: []const u8, sha256: []const u8) !record.Attestation {
        try cli_authority.revalidate(self.allocator, self.cli.path, self.cli.pinned);
        var output: [attestation.max_response_bytes]u8 = undefined;
        var observed = try attestation.verifyBundle(self.io, self.allocator, self.cli.path, evidence_path, bundle_path, .{ .context = self.context, .subject_name = name, .subject_sha256 = sha256, .runner_environment = .self_hosted }, &output, try self.deadline.remaining());
        defer observed.deinit(self.allocator);
        try cli_authority.revalidate(self.allocator, self.cli.path, self.cli.pinned);
        if (!std.mem.eql(u8, observed.subject_name, name) or !std.mem.eql(u8, observed.subject_sha256, sha256)) return error.InvalidAttestation;
        return .{ .verified = observed.verified, .run_id = observed.run_id, .run_attempt = observed.run_attempt, .subject_name = name, .subject_sha256 = sha256, .self_hosted = true };
    }

    fn revalidateCli(self: *@This()) !void {
        try cli_authority.revalidate(self.allocator, self.cli.path, self.cli.pinned);
    }
};

fn exactOutput(path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(path), final_name) and path.len > final_name.len + 1 and path[0] == '/';
}

fn pairwiseDistinct(paths: [4][]const u8) bool {
    for (paths, 0..) |path, index| {
        if (path.len < 2 or path[0] != '/') return false;
        for (paths[0..index]) |earlier| if (std.mem.eql(u8, path, earlier)) return false;
    }
    return true;
}
