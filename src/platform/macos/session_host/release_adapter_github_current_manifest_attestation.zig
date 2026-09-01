//! Authenticates one current role-B manifest against current release authority and artifact provenance.

const std = @import("std");
const manifest = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const current_mod = @import("release_adapter_github_current_release_authority");
const attestation = @import("release_adapter_github_attestation");
const file_mod = @import("release_adapter_github_manifest_file");
const cli_authority = @import("release_adapter_github_cli_authority");

pub const Error = error{ InvalidOwner, InvalidCurrent, InvalidManifest, FileChanged };
pub const Cli = struct { path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable };

pub const AuthorityView = struct {
    repository_id: u64,
    run_id: u64,
    run_attempt: u64,
    source_commit: []const u8,
    release_id: u64,
    tag: []const u8,
    protected_environment: bool,
};

pub const View = struct { manifest: *const manifest.Manifest, authority: AuthorityView };

pub const AuthenticatedCurrentManifest = struct {
    owner: ?*AuthenticatedCurrentManifest = null,
    parsed: ?manifest.Parsed = null,
    observed: ?attestation.Observed = null,
    repository_id: u64 = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,
    source_commit: [40]u8 = @splat(0),
    release_id: u64 = 0,
    tag: [manifest.max_scalar_string_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    protected_environment: bool = false,

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self) return null;
        const parsed = if (self.parsed) |*parsed_value| parsed_value.value() else return null;
        return .{ .manifest = parsed, .authority = .{
            .repository_id = self.repository_id,
            .run_id = self.run_id,
            .run_attempt = self.run_attempt,
            .source_commit = &self.source_commit,
            .release_id = self.release_id,
            .tag = self.tag[0..self.tag_len],
            .protected_environment = self.protected_environment,
        } };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) Error!void {
        if (self.owner != self) return error.InvalidOwner;
        if (self.observed) |*observed_value| observed_value.deinit(allocator);
        if (self.parsed) |*parsed_value| parsed_value.deinit();
        self.* = .{};
    }
};

const RealAuthority = struct {
    pinned: *const cli_authority.PinnedExecutable,
    pub fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};

const RealAttestor = struct {
    pub fn verify(_: *@This(), executor: anytype, allocator: std.mem.Allocator, executable: []const u8, token: []const u8, artifact_path: []const u8, expected: attestation.Expected, output: []u8, budget_ns: i128) !attestation.Observed {
        return attestation.verifyWith(executor, allocator, executable, token, artifact_path, expected, output, budget_ns);
    }
};

pub fn authenticate(io: std.Io, allocator: std.mem.Allocator, context: context_mod.Context, current: *const current_mod.CurrentReleaseAuthority, bytes: []const u8, file: *const file_mod.ManifestFile, cli: Cli, token: []const u8, output: []u8, budget_ns: i128, result: *AuthenticatedCurrentManifest) !void {
    var attestor = RealAttestor{};
    var authority = RealAuthority{ .pinned = cli.pinned };
    var executor = attestation.BoundedExecutor{ .io = io };
    return authenticateWith(&attestor, &authority, &executor, allocator, context, current, bytes, file, cli.path, token, output, budget_ns, result);
}

pub fn authenticateWith(attestor: anytype, authority: anytype, executor: anytype, allocator: std.mem.Allocator, context: context_mod.Context, current: *const current_mod.CurrentReleaseAuthority, bytes: []const u8, file: *const file_mod.ManifestFile, executable: [:0]const u8, token: []const u8, output: []u8, budget_ns: i128, result: *AuthenticatedCurrentManifest) !void {
    if (result.owner != null or result.parsed != null or result.observed != null) return error.InvalidOwner;
    var parsed = try manifest.parseCanonical(allocator, bytes);
    errdefer parsed.deinit();
    const candidate = parsed.value();
    context_mod.bindManifest(context, candidate.*) catch return error.InvalidManifest;
    const current_view = current.value() orelse return error.InvalidCurrent;
    if (candidate.role != .b or candidate.predecessor == null or
        current_view.repository_id != candidate.repository.id or current_view.run_id != candidate.build.run_id or
        current_view.run_attempt != candidate.build.run_attempt or !std.mem.eql(u8, current_view.source_commit, candidate.source.commit) or
        current_view.release_id != candidate.release.id or !std.mem.eql(u8, current_view.tag, candidate.release.tag) or
        !current_view.protected_environment) return error.InvalidCurrent;
    const before = file.revalidate() catch return error.FileChanged;
    var name_storage: [manifest.max_asset_name_bytes]u8 = undefined;
    const name = std.fmt.bufPrint(&name_storage, "Maru-{s}-session-host-release.json", .{candidate.release.version}) catch return error.InvalidManifest;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const sha = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, std.fs.path.basename(before.path), name) or before.size != bytes.len or !std.mem.eql(u8, before.sha256, &sha)) return error.InvalidManifest;
    try authority.revalidate(allocator, executable);
    var observed = try attestor.verify(executor, allocator, executable, token, before.path, .{ .context = context, .subject_name = name, .subject_sha256 = &sha }, output, budget_ns);
    errdefer observed.deinit(allocator);
    const after = file.revalidate() catch return error.FileChanged;
    if (before.device != after.device or before.inode != after.inode or before.size != after.size or !std.mem.eql(u8, before.sha256, after.sha256)) return error.FileChanged;
    if (current_view.tag.len > result.tag.len) return error.InvalidCurrent;
    result.* = .{ .owner = result, .parsed = parsed, .observed = observed, .repository_id = current_view.repository_id, .run_id = current_view.run_id, .run_attempt = current_view.run_attempt, .release_id = current_view.release_id, .tag_len = current_view.tag.len, .protected_environment = true };
    @memcpy(&result.source_commit, current_view.source_commit);
    @memcpy(result.tag[0..result.tag_len], current_view.tag);
}
