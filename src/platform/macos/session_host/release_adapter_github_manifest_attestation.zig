//! Strict predecessor manifest parse, successor cross-binding, and artifact attestation composition.

const std = @import("std");
const manifest = @import("release_manifest");
const context = @import("release_adapter_context");
const attestation = @import("release_adapter_github_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const manifest_file = @import("release_adapter_github_manifest_file");
const deadline_mod = @import("release_adapter_deadline");

pub const Error = error{ InvalidPredecessor, InvalidPublishedManifest, FileChanged, InvalidOwner };

pub const AuthenticatedManifest = struct {
    owner: ?*AuthenticatedManifest = null,
    parsed: ?manifest.Parsed = null,
    observed: ?attestation.Observed = null,

    pub fn value(self: *const AuthenticatedManifest) ?*const manifest.Manifest {
        if (self.owner != self) return null;
        return if (self.parsed) |*parsed| parsed.value() else null;
    }

    pub fn deinit(self: *AuthenticatedManifest, allocator: std.mem.Allocator) Error!void {
        if (self.owner != self) return error.InvalidOwner;
        if (self.observed) |*observed| observed.deinit(allocator);
        if (self.parsed) |*parsed| parsed.deinit();
        self.observed = null;
        self.parsed = null;
        self.owner = null;
    }
};

pub const Cli = struct {
    path: [:0]const u8,
    pinned: *const cli_authority.PinnedExecutable,
};

const RealAuthority = struct {
    pinned: *const cli_authority.PinnedExecutable,
    fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};

pub fn authenticate(
    io: std.Io,
    allocator: std.mem.Allocator,
    predecessor: manifest.Predecessor,
    bytes: []const u8,
    file: *const manifest_file.ManifestFile,
    cli: Cli,
    token: []const u8,
    output: []u8,
    budget_ns: i128,
    result: *AuthenticatedManifest,
) !void {
    var authority = RealAuthority{ .pinned = cli.pinned };
    var executor = attestation.BoundedExecutor{ .io = io };
    return authenticateWith(&authority, &executor, allocator, predecessor, bytes, file, cli.path, token, output, budget_ns, result);
}

pub fn authenticateUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    predecessor: manifest.Predecessor,
    bytes: []const u8,
    file: *const manifest_file.ManifestFile,
    cli: Cli,
    token: []const u8,
    output: []u8,
    deadline: *deadline_mod.Deadline,
    result: *AuthenticatedManifest,
) !void {
    const pinned_bytes = std.mem.asBytes(cli.pinned);
    if (rangesOverlap(std.mem.asBytes(deadline), pinned_bytes) or
        aliasesInputs(pinned_bytes, predecessor, bytes, file, cli.path, token, output, result, true))
        return error.InvalidOwner;
    var authority = RealAuthority{ .pinned = cli.pinned };
    var executor = attestation.BoundedExecutor{ .io = io };
    return authenticateUntilWith(&authority, &executor, deadline, allocator, predecessor, bytes, file, cli.path, token, output, result);
}

pub fn authenticatePublishedUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    trusted: context.Context,
    bytes: []const u8,
    file: *const manifest_file.ManifestFile,
    cli: Cli,
    token: []const u8,
    output: []u8,
    deadline: *deadline_mod.Deadline,
    result: *AuthenticatedManifest,
) !void {
    const pinned_bytes = std.mem.asBytes(cli.pinned);
    if (rangesOverlap(std.mem.asBytes(deadline), pinned_bytes) or
        aliasesPublishedInputs(pinned_bytes, trusted, bytes, file, cli.path, token, output, result, true, true))
        return error.InvalidOwner;
    var authority = RealAuthority{ .pinned = cli.pinned };
    var executor = attestation.BoundedExecutor{ .io = io };
    return authenticatePublishedUntilWith(&authority, &executor, deadline, allocator, trusted, bytes, file, cli.path, token, output, result);
}

pub fn authenticateWith(
    authority: anytype,
    executor: anytype,
    allocator: std.mem.Allocator,
    predecessor: manifest.Predecessor,
    bytes: []const u8,
    file: *const manifest_file.ManifestFile,
    executable: [:0]const u8,
    token: []const u8,
    output: []u8,
    budget_ns: i128,
    result: *AuthenticatedManifest,
) !void {
    var fixed = FixedBudget{ .value = budget_ns };
    return authenticateUntilWith(authority, executor, &fixed, allocator, predecessor, bytes, file, executable, token, output, result);
}

pub fn authenticateUntilWith(
    authority: anytype,
    executor: anytype,
    deadline: anytype,
    allocator: std.mem.Allocator,
    predecessor: manifest.Predecessor,
    bytes: []const u8,
    file: *const manifest_file.ManifestFile,
    executable: [:0]const u8,
    token: []const u8,
    output: []u8,
    result: *AuthenticatedManifest,
) !void {
    const deadline_bytes = std.mem.asBytes(deadline);
    const result_bytes = std.mem.asBytes(result);
    if (aliasesInputs(deadline_bytes, predecessor, bytes, file, executable, token, output, result, true) or
        aliasesInputs(result_bytes, predecessor, bytes, file, executable, token, output, result, false) or
        aliasesOutput(output, predecessor, bytes, file, executable, token, result))
        return error.InvalidOwner;
    if (result.owner != null or result.parsed != null or result.observed != null) return error.InvalidOwner;
    var parsed = try manifest.parseCanonical(allocator, bytes);
    errdefer parsed.deinit();
    const candidate = parsed.value();
    if (aliasesParsedPredecessor(candidate, deadline_bytes, result_bytes, predecessor, bytes, file, executable, token, output))
        return error.InvalidOwner;
    const candidate_context: context.Context = .{
        .repository = candidate.repository,
        .tag = candidate.release.tag,
        .source_commit = candidate.source.commit,
        .build = candidate.build,
        .protected_tag = false,
    };
    context.bindManifest(candidate_context, candidate.*) catch return error.InvalidPredecessor;
    const before = file.revalidate() catch return error.FileChanged;
    var name_storage: [manifest.max_asset_name_bytes]u8 = undefined;
    const expected_name = std.fmt.bufPrint(&name_storage, "Maru-{s}-session-host-release.json", .{candidate.release.version}) catch return error.InvalidPredecessor;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    if (candidate.role != .a or candidate.predecessor != null or
        candidate.release.id != predecessor.release_id or
        !std.mem.eql(u8, candidate.release.tag, predecessor.tag) or
        !std.mem.eql(u8, candidate.source.commit, predecessor.commit) or
        !std.mem.eql(u8, &digest_hex, predecessor.manifest_sha256) or
        !std.mem.eql(u8, before.sha256, predecessor.manifest_sha256) or
        !std.mem.eql(u8, std.fs.path.basename(before.path), expected_name)) return error.InvalidPredecessor;
    const expected: attestation.Expected = .{
        .context = candidate_context,
        .subject_name = expected_name,
        .subject_sha256 = predecessor.manifest_sha256,
        .tag_protection = .historical_unavailable,
    };
    try attestAndPublish(authority, executor, deadline, allocator, parsed, file, before, executable, token, output, expected, result);
}

/// Authenticates the role-A release published by the current trusted tag run. This is deliberately
/// separate from B -> A predecessor consumption: no successor predecessor scope is invented.
pub fn authenticatePublishedUntilWith(
    authority: anytype,
    executor: anytype,
    deadline: anytype,
    allocator: std.mem.Allocator,
    trusted: context.Context,
    bytes: []const u8,
    file: *const manifest_file.ManifestFile,
    executable: [:0]const u8,
    token: []const u8,
    output: []u8,
    result: *AuthenticatedManifest,
) !void {
    const deadline_bytes = std.mem.asBytes(deadline);
    const result_bytes = std.mem.asBytes(result);
    if (aliasesPublishedInputs(deadline_bytes, trusted, bytes, file, executable, token, output, result, true, true) or
        aliasesPublishedInputs(result_bytes, trusted, bytes, file, executable, token, output, result, false, true) or
        aliasesPublishedInputs(output, trusted, bytes, file, executable, token, output, result, true, false))
        return error.InvalidOwner;
    if (result.owner != null or result.parsed != null or result.observed != null) return error.InvalidOwner;
    var parsed = try manifest.parseCanonical(allocator, bytes);
    errdefer parsed.deinit();
    const candidate = parsed.value();
    if (aliasesParsedPublished(candidate, deadline_bytes, result_bytes, trusted, bytes, file, executable, token, output))
        return error.InvalidOwner;
    if (!trusted.protected_tag or candidate.role != .a or candidate.predecessor != null)
        return error.InvalidPublishedManifest;
    context.bindManifest(trusted, candidate.*) catch return error.InvalidPublishedManifest;

    const before = file.revalidate() catch return error.FileChanged;
    var name_storage: [manifest.max_asset_name_bytes]u8 = undefined;
    const expected_name = std.fmt.bufPrint(&name_storage, "Maru-{s}-session-host-release.json", .{candidate.release.version}) catch
        return error.InvalidPublishedManifest;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, before.sha256, &digest_hex) or
        !std.mem.eql(u8, std.fs.path.basename(before.path), expected_name)) return error.InvalidPublishedManifest;

    const expected: attestation.Expected = .{
        .context = trusted,
        .subject_name = expected_name,
        .subject_sha256 = &digest_hex,
    };
    try attestAndPublish(authority, executor, deadline, allocator, parsed, file, before, executable, token, output, expected, result);
}

fn attestAndPublish(
    authority: anytype,
    executor: anytype,
    deadline: anytype,
    allocator: std.mem.Allocator,
    parsed: manifest.Parsed,
    file: *const manifest_file.ManifestFile,
    before: manifest_file.Observation,
    executable: [:0]const u8,
    token: []const u8,
    output: []u8,
    expected: attestation.Expected,
    result: *AuthenticatedManifest,
) !void {
    _ = try deadline.remaining();
    try authority.revalidate(allocator, executable);
    const budget_ns = try deadline.remaining();
    var observed = try attestation.verifyWith(executor, allocator, executable, token, before.path, expected, output, budget_ns);
    errdefer observed.deinit(allocator);
    const after = file.revalidate() catch return error.FileChanged;
    if (before.device != after.device or before.inode != after.inode or before.size != after.size or
        !std.mem.eql(u8, before.sha256, after.sha256)) return error.FileChanged;
    _ = try deadline.remaining();
    result.* = .{ .owner = result, .parsed = parsed, .observed = observed };
}

const FixedBudget = struct {
    value: i128,
    pub fn remaining(self: *@This()) !i128 {
        if (self.value <= 0) return error.InvalidBudget;
        return self.value;
    }
};

fn aliasesInputs(
    candidate: []const u8,
    predecessor: manifest.Predecessor,
    bytes: []const u8,
    file: *const manifest_file.ManifestFile,
    executable: [:0]const u8,
    token: []const u8,
    output: []const u8,
    result: *const AuthenticatedManifest,
    include_result: bool,
) bool {
    if ((include_result and rangesOverlap(candidate, std.mem.asBytes(result))) or
        rangesOverlap(candidate, std.mem.asBytes(file)) or
        rangesOverlap(candidate, bytes) or rangesOverlap(candidate, executable) or
        rangesOverlap(candidate, token) or rangesOverlap(candidate, output)) return true;
    inline for (.{
        predecessor.tag,
        predecessor.commit,
        predecessor.manifest_sha256,
    }) |value| if (rangesOverlap(candidate, value)) return true;
    return false;
}

fn aliasesOutput(
    output: []const u8,
    predecessor: manifest.Predecessor,
    bytes: []const u8,
    file: *const manifest_file.ManifestFile,
    executable: [:0]const u8,
    token: []const u8,
    result: *const AuthenticatedManifest,
) bool {
    if (rangesOverlap(output, std.mem.asBytes(result)) or rangesOverlap(output, std.mem.asBytes(file)) or
        rangesOverlap(output, bytes) or rangesOverlap(output, executable) or rangesOverlap(output, token)) return true;
    inline for (.{ predecessor.tag, predecessor.commit, predecessor.manifest_sha256 }) |value|
        if (rangesOverlap(output, value)) return true;
    return false;
}

fn aliasesPublishedInputs(
    candidate: []const u8,
    trusted: context.Context,
    bytes: []const u8,
    file: *const manifest_file.ManifestFile,
    executable: [:0]const u8,
    token: []const u8,
    output: []const u8,
    result: *const AuthenticatedManifest,
    include_result: bool,
    include_output: bool,
) bool {
    if ((include_result and rangesOverlap(candidate, std.mem.asBytes(result))) or
        (include_output and rangesOverlap(candidate, output)) or
        rangesOverlap(candidate, std.mem.asBytes(file)) or rangesOverlap(candidate, bytes) or
        rangesOverlap(candidate, executable) or rangesOverlap(candidate, token)) return true;
    inline for (.{ trusted.repository.owner, trusted.repository.name, trusted.tag, trusted.source_commit, trusted.build.workflow_ref }) |value|
        if (rangesOverlap(candidate, value)) return true;
    return false;
}

fn aliasesParsedPredecessor(
    value: *const manifest.Manifest,
    deadline: []const u8,
    result: []const u8,
    predecessor: manifest.Predecessor,
    bytes: []const u8,
    file: *const manifest_file.ManifestFile,
    executable: [:0]const u8,
    token: []const u8,
    output: []const u8,
) bool {
    inline for (.{ deadline, result, bytes, std.mem.asBytes(file), executable, token, output, predecessor.tag, predecessor.commit, predecessor.manifest_sha256 }) |candidate|
        if (manifest.aliasesStorage(value, candidate)) return true;
    return false;
}

fn aliasesParsedPublished(
    value: *const manifest.Manifest,
    deadline: []const u8,
    result: []const u8,
    trusted: context.Context,
    bytes: []const u8,
    file: *const manifest_file.ManifestFile,
    executable: [:0]const u8,
    token: []const u8,
    output: []const u8,
) bool {
    inline for (.{ deadline, result, bytes, std.mem.asBytes(file), executable, token, output, trusted.repository.owner, trusted.repository.name, trusted.tag, trusted.source_commit, trusted.build.workflow_ref }) |candidate|
        if (manifest.aliasesStorage(value, candidate)) return true;
    return false;
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}
