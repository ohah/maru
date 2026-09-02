//! Authenticated predecessor manifest to locally authenticated release assets composition.

const std = @import("std");
const manifest = @import("release_manifest");
const git = @import("release_adapter_github_git");
const resolver = @import("release_adapter_git_resolver");
const download = @import("release_adapter_github_download");
const release_attestation = @import("release_adapter_github_release_attestation");
const manifest_attestation = @import("release_adapter_github_manifest_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");

pub const Error = error{ InvalidOwner, InvalidManifest, FileChanged, CleanupFailed, TagRefMismatch };

// Legacy leaves require a positive scalar before they delegate to capture. The
// deadline guard discards this marker and supplies a fresh shared remaining value.
const delegated_budget_marker: i128 = 1;

pub const View = struct {
    source_commit: []const u8,
    downloads: *const download.DownloadedSet,
};

pub const AuthenticatedPredecessorAssets = struct {
    owner: ?*AuthenticatedPredecessorAssets = null,
    downloads: download.DownloadedSet = .{},
    source_commit: [40]u8 = @splat(0),

    pub fn value(self: *const AuthenticatedPredecessorAssets) ?View {
        if (self.owner != self) return null;
        return .{ .source_commit = &self.source_commit, .downloads = &self.downloads };
    }

    pub const EvidenceView = struct {
        source_commit: []const u8,
        assets: [3]download.DownloadedAsset,
    };

    pub fn revalidateEvidence(self: *const AuthenticatedPredecessorAssets) !EvidenceView {
        const current = self.value() orelse return error.InvalidOwner;
        try current.downloads.revalidate();
        return .{ .source_commit = current.source_commit, .assets = .{
            current.downloads.asset(.universal_dmg) orelse return error.FileChanged,
            current.downloads.asset(.frozen_product_executable) orelse return error.FileChanged,
            current.downloads.asset(.evidence_summary) orelse return error.FileChanged,
        } };
    }

    pub fn cleanup(self: *AuthenticatedPredecessorAssets) !void {
        if (self.owner != self) return error.InvalidOwner;
        self.downloads.cleanup() catch return error.CleanupFailed;
        self.owner = null;
        self.source_commit = @splat(0);
    }
};

pub const Cli = struct { path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable };

const RealAuthority = struct {
    pinned: *const cli_authority.PinnedExecutable,
    fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};

pub fn compose(io: std.Io, allocator: std.mem.Allocator, authenticated: *const manifest_attestation.AuthenticatedManifest, ref_observation: git.RefObservation, tag_observations: []const git.TagObservation, cli: Cli, token: []const u8, workdir: [:0]const u8, output: []u8, budget_ns: i128, result: *AuthenticatedPredecessorAssets) !void {
    var authority = RealAuthority{ .pinned = cli.pinned };
    var executor = download.BoundedExecutor{ .io = io };
    return composeWith(&authority, &executor, allocator, authenticated, ref_observation, tag_observations, cli.path, token, workdir, output, budget_ns, result);
}

pub fn composeUntil(io: std.Io, allocator: std.mem.Allocator, authenticated: *const manifest_attestation.AuthenticatedManifest, ref_observation: git.RefObservation, tag_observations: []const git.TagObservation, cli: Cli, token: []const u8, workdir: [:0]const u8, output: []u8, deadline: *deadline_mod.Deadline, result: *AuthenticatedPredecessorAssets) !void {
    const pinned_bytes = std.mem.asBytes(cli.pinned);
    if (rangesOverlap(std.mem.asBytes(deadline), pinned_bytes) or
        rangesOverlap(std.mem.asBytes(result), pinned_bytes) or
        rangesOverlap(output, pinned_bytes)) return error.InvalidOwner;
    var authority = RealAuthority{ .pinned = cli.pinned };
    var executor = download.BoundedExecutor{ .io = io };
    return composeUntilWith(&authority, &executor, deadline, allocator, authenticated, ref_observation, tag_observations, cli.path, token, workdir, output, result);
}

pub fn composeWith(authority: anytype, executor: anytype, allocator: std.mem.Allocator, authenticated: anytype, ref_observation: git.RefObservation, tag_observations: []const git.TagObservation, executable: [:0]const u8, token: []const u8, workdir: [:0]const u8, output: []u8, budget_ns: i128, result: *AuthenticatedPredecessorAssets) !void {
    try validateInputs(authenticated, ref_observation, tag_observations, executable, token, workdir, output, result);
    const candidate = authenticated.value() orelse return error.InvalidManifest;
    const manifest_evidence = authenticated.evidenceView() orelse return error.InvalidManifest;
    if (manifest.aliasesStorage(candidate, output) or manifest.aliasesStorage(candidate, std.mem.asBytes(result)))
        return error.InvalidOwner;
    var guarded = Guarded(@TypeOf(authority), @TypeOf(executor)){ .authority = authority, .executor = executor, .allocator = allocator };
    return composeGuarded(&guarded, allocator, candidate, manifest_evidence.subject_name, manifest_evidence.subject_sha256, ref_observation, tag_observations, executable, token, workdir, output, budget_ns, result);
}

pub fn composeUntilWith(authority: anytype, executor: anytype, deadline: anytype, allocator: std.mem.Allocator, authenticated: anytype, ref_observation: git.RefObservation, tag_observations: []const git.TagObservation, executable: [:0]const u8, token: []const u8, workdir: [:0]const u8, output: []u8, result: *AuthenticatedPredecessorAssets) !void {
    try validateInputs(authenticated, ref_observation, tag_observations, executable, token, workdir, output, result);
    if (aliasesInputs(std.mem.asBytes(deadline), authenticated, ref_observation, tag_observations, executable, token, workdir, output, result, true))
        return error.InvalidOwner;
    const candidate = authenticated.value() orelse return error.InvalidManifest;
    const manifest_evidence = authenticated.evidenceView() orelse return error.InvalidManifest;
    if (manifest.aliasesStorage(candidate, output) or manifest.aliasesStorage(candidate, std.mem.asBytes(deadline)) or
        manifest.aliasesStorage(candidate, std.mem.asBytes(result)))
        return error.InvalidOwner;
    var guarded = DeadlineGuarded(@TypeOf(authority), @TypeOf(executor), @TypeOf(deadline)){ .authority = authority, .executor = executor, .deadline = deadline, .allocator = allocator };
    return composeGuarded(&guarded, allocator, candidate, manifest_evidence.subject_name, manifest_evidence.subject_sha256, ref_observation, tag_observations, executable, token, workdir, output, delegated_budget_marker, result);
}

fn composeGuarded(guarded: anytype, allocator: std.mem.Allocator, candidate: *const manifest.Manifest, manifest_name: []const u8, manifest_sha256: []const u8, ref_observation: git.RefObservation, tag_observations: []const git.TagObservation, executable: [:0]const u8, token: []const u8, workdir: [:0]const u8, output: []u8, budget_ns: i128, result: *AuthenticatedPredecessorAssets) !void {
    const expected_download: download.Expected = .{ .tag = candidate.release.tag, .assets = candidate.assets };
    download.downloadAllWith(&result.downloads, guarded, executable, token, workdir, expected_download, budget_ns) catch |err| {
        if (result.downloads.owner != null) result.downloads.cleanup() catch return error.CleanupFailed;
        return err;
    };
    finish(guarded, allocator, candidate, manifest_name, manifest_sha256, ref_observation, tag_observations, executable, token, output, budget_ns, result) catch |err| {
        result.downloads.cleanup() catch return error.CleanupFailed;
        return err;
    };
}

fn DeadlineGuarded(comptime Authority: type, comptime Executor: type, comptime Deadline: type) type {
    return struct {
        authority: Authority,
        executor: Executor,
        deadline: Deadline,
        allocator: std.mem.Allocator,
        pub fn capture(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, _: i128) ![]const u8 {
            _ = try self.deadline.remaining();
            var storage: [std.fs.max_path_bytes:0]u8 = undefined;
            const executable_z = std.fmt.bufPrintZ(&storage, "{s}", .{executable}) catch return error.InvalidPath;
            try self.authority.revalidate(self.allocator, executable_z);
            const budget_ns = try self.deadline.remaining();
            return self.executor.capture(executable, args, environment, output, budget_ns);
        }
        pub fn validatePublication(self: *@This()) !void {
            _ = try self.deadline.remaining();
        }
    };
}

fn finish(executor: anytype, allocator: std.mem.Allocator, candidate: *const manifest.Manifest, manifest_name: []const u8, manifest_sha256: []const u8, ref_observation: git.RefObservation, tag_observations: []const git.TagObservation, executable: [:0]const u8, token: []const u8, output: []u8, budget_ns: i128, result: *AuthenticatedPredecessorAssets) !void {
    if (!std.mem.eql(u8, ref_observation.tag, candidate.release.tag)) return error.TagRefMismatch;
    const expected: release_attestation.Expected = .{ .repository = candidate.repository, .release_id = candidate.release.id, .tag = candidate.release.tag, .tag_ref_sha = ref_observation.target.sha, .assets = candidate.assets, .manifest = .{ .name = manifest_name, .sha256 = manifest_sha256 } };
    try result.downloads.revalidate();
    var release = try release_attestation.verifyWith(executor, allocator, executable, token, .release, expected, output, budget_ns);
    release.deinit();
    try result.downloads.revalidate();
    for (candidate.assets) |asset| {
        const local = result.downloads.asset(asset.role) orelse return error.FileChanged;
        try result.downloads.revalidate();
        var observed = try release_attestation.verifyWith(executor, allocator, executable, token, .{ .asset = .{ .path = local.path, .expected = asset } }, expected, output, budget_ns);
        observed.deinit();
        try result.downloads.revalidate();
    }
    const rows = try allocator.alloc(resolver.Sha, tag_observations.len);
    defer allocator.free(rows);
    var backing: resolver.Backing = undefined;
    try backing.init(rows);
    var chain: resolver.Resolver = undefined;
    try chain.init(candidate.source.commit, &backing);
    try chain.acceptRef(ref_observation, candidate.release.tag);
    for (tag_observations) |observation| try chain.acceptTag(observation);
    const resolved = try chain.result();
    if (!std.mem.eql(u8, resolved.commitSha(), candidate.source.commit)) return error.TagRefMismatch;
    try executor.validatePublication();
    @memcpy(&result.source_commit, resolved.commitSha());
    result.owner = result;
}

fn Guarded(comptime Authority: type, comptime Executor: type) type {
    return struct {
        authority: Authority,
        executor: Executor,
        allocator: std.mem.Allocator,
        pub fn capture(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) ![]const u8 {
            var storage: [std.fs.max_path_bytes:0]u8 = undefined;
            const executable_z = std.fmt.bufPrintZ(&storage, "{s}", .{executable}) catch return error.InvalidPath;
            try self.authority.revalidate(self.allocator, executable_z);
            return self.executor.capture(executable, args, environment, output, budget_ns);
        }
        pub fn validatePublication(_: *@This()) !void {}
    };
}

fn validateInputs(authenticated: anytype, ref_observation: git.RefObservation, tag_observations: []const git.TagObservation, executable: []const u8, token: []const u8, workdir: []const u8, output: []const u8, result: *const AuthenticatedPredecessorAssets) Error!void {
    if (aliasesResult(std.mem.asBytes(result), authenticated, ref_observation, tag_observations, executable, token, workdir, output) or
        result.owner != null or result.downloads.owner != null or
        aliasesInputs(output, authenticated, ref_observation, tag_observations, executable, token, workdir, output, result, false))
        return error.InvalidOwner;
}

fn aliasesResult(candidate: []const u8, authenticated: anytype, ref_observation: git.RefObservation, tag_observations: []const git.TagObservation, executable: []const u8, token: []const u8, workdir: []const u8, output: []const u8) bool {
    if (rangesOverlap(candidate, std.mem.asBytes(authenticated)) or
        rangesOverlap(candidate, executable) or rangesOverlap(candidate, token) or rangesOverlap(candidate, workdir) or
        rangesOverlap(candidate, output) or rangesOverlap(candidate, ref_observation.tag) or
        rangesOverlap(candidate, ref_observation.target.sha) or
        rangesOverlap(candidate, std.mem.sliceAsBytes(tag_observations))) return true;
    for (tag_observations) |observation| {
        if (rangesOverlap(candidate, observation.tag) or rangesOverlap(candidate, observation.object_sha) or
            rangesOverlap(candidate, observation.target.sha)) return true;
    }
    return false;
}

fn aliasesInputs(candidate: []const u8, authenticated: anytype, ref_observation: git.RefObservation, tag_observations: []const git.TagObservation, executable: []const u8, token: []const u8, workdir: []const u8, output: []const u8, result: *const AuthenticatedPredecessorAssets, include_output: bool) bool {
    if (rangesOverlap(candidate, std.mem.asBytes(result)) or
        rangesOverlap(candidate, std.mem.asBytes(authenticated)) or
        rangesOverlap(candidate, executable) or rangesOverlap(candidate, token) or rangesOverlap(candidate, workdir) or
        (include_output and rangesOverlap(candidate, output)) or
        rangesOverlap(candidate, ref_observation.tag) or rangesOverlap(candidate, ref_observation.target.sha) or
        rangesOverlap(candidate, std.mem.sliceAsBytes(tag_observations))) return true;
    for (tag_observations) |observation| {
        if (rangesOverlap(candidate, observation.tag) or rangesOverlap(candidate, observation.object_sha) or
            rangesOverlap(candidate, observation.target.sha)) return true;
    }
    return false;
}

/// Compatibility boundary for tag-chain transport; the exhaustive inventory is owned by the
/// manifest schema rather than duplicated in this composition.
pub fn aliasesManifestStorage(candidate: []const u8, value: *const manifest.Manifest) bool {
    return manifest.aliasesStorage(value, candidate);
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
