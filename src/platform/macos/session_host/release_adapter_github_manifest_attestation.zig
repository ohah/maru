//! Strict predecessor manifest parse, successor cross-binding, and artifact attestation composition.

const std = @import("std");
const manifest = @import("release_manifest");
const context = @import("release_adapter_context");
const attestation = @import("release_adapter_github_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const manifest_file = @import("release_adapter_github_manifest_file");

pub const Error = error{ InvalidPredecessor, FileChanged, InvalidOwner };
pub const TrustedContext = context.Context;

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
    trusted_context: TrustedContext,
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
    return authenticateWith(&authority, &executor, allocator, trusted_context, predecessor, bytes, file, cli.path, token, output, budget_ns, result);
}

pub fn authenticateWith(
    authority: anytype,
    executor: anytype,
    allocator: std.mem.Allocator,
    trusted_context: TrustedContext,
    predecessor: manifest.Predecessor,
    bytes: []const u8,
    file: *const manifest_file.ManifestFile,
    executable: [:0]const u8,
    token: []const u8,
    output: []u8,
    budget_ns: i128,
    result: *AuthenticatedManifest,
) !void {
    if (result.owner != null or result.parsed != null or result.observed != null) return error.InvalidOwner;
    var parsed = try manifest.parseCanonical(allocator, bytes);
    errdefer parsed.deinit();
    const candidate = parsed.value();
    context.bindManifest(trusted_context, candidate.*) catch return error.InvalidPredecessor;
    if (!trusted_context.protected_tag) return error.InvalidPredecessor;
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
        .context = trusted_context,
        .subject_name = expected_name,
        .subject_sha256 = predecessor.manifest_sha256,
    };
    try authority.revalidate(allocator, executable);
    var observed = try attestation.verifyWith(executor, allocator, executable, token, before.path, expected, output, budget_ns);
    errdefer observed.deinit(allocator);
    const after = file.revalidate() catch return error.FileChanged;
    if (before.device != after.device or before.inode != after.inode or before.size != after.size or
        !std.mem.eql(u8, before.sha256, after.sha256)) return error.FileChanged;
    result.* = .{ .owner = result, .parsed = parsed, .observed = observed };
}
