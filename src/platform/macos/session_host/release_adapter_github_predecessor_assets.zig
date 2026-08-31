//! Authenticated predecessor manifest to locally authenticated release assets composition.

const std = @import("std");
const manifest = @import("release_manifest");
const git = @import("release_adapter_github_git");
const resolver = @import("release_adapter_git_resolver");
const download = @import("release_adapter_github_download");
const release_attestation = @import("release_adapter_github_release_attestation");
const manifest_attestation = @import("release_adapter_github_manifest_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");

pub const Error = error{ InvalidOwner, InvalidManifest, FileChanged, CleanupFailed, TagRefMismatch };

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

pub fn composeWith(authority: anytype, executor: anytype, allocator: std.mem.Allocator, authenticated: anytype, ref_observation: git.RefObservation, tag_observations: []const git.TagObservation, executable: [:0]const u8, token: []const u8, workdir: [:0]const u8, output: []u8, budget_ns: i128, result: *AuthenticatedPredecessorAssets) !void {
    if (result.owner != null or result.downloads.owner != null) return error.InvalidOwner;
    const candidate = authenticated.value() orelse return error.InvalidManifest;
    var guarded = Guarded(@TypeOf(authority), @TypeOf(executor)){ .authority = authority, .executor = executor, .allocator = allocator };
    const expected_download: download.Expected = .{ .tag = candidate.release.tag, .assets = candidate.assets };
    download.downloadAllWith(&result.downloads, &guarded, executable, token, workdir, expected_download, budget_ns) catch |err| {
        if (result.downloads.owner != null) result.downloads.cleanup() catch return error.CleanupFailed;
        return err;
    };
    finish(&guarded, allocator, candidate, ref_observation, tag_observations, executable, token, output, budget_ns, result) catch |err| {
        result.downloads.cleanup() catch return error.CleanupFailed;
        return err;
    };
}

fn finish(executor: anytype, allocator: std.mem.Allocator, candidate: *const manifest.Manifest, ref_observation: git.RefObservation, tag_observations: []const git.TagObservation, executable: [:0]const u8, token: []const u8, output: []u8, budget_ns: i128, result: *AuthenticatedPredecessorAssets) !void {
    if (!std.mem.eql(u8, ref_observation.tag, candidate.release.tag)) return error.TagRefMismatch;
    const expected: release_attestation.Expected = .{ .repository = candidate.repository, .release_id = candidate.release.id, .tag = candidate.release.tag, .tag_ref_sha = ref_observation.target.sha, .assets = candidate.assets };
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
    };
}
