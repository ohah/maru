//! Authenticated current/predecessor manifests and one local evidence summary composition.
//!
//! Caller pathnames are staging inputs. Every semantic expectation is derived from the two
//! authenticated manifests, and success retains owned bytes plus the strict parsed evidence.

const std = @import("std");
const manifest = @import("release_manifest");
const evidence = @import("release_evidence");
const files = @import("release_adapter_files");
const current_input = @import("release_adapter_github_current_manifest_input");
const predecessor_mod = @import("release_adapter_github_manifest_attestation");

pub const Error = error{
    InvalidOwner,
    InvalidCurrent,
    InvalidPredecessor,
    InvalidSummary,
    EvidenceMismatch,
} || files.Error || evidence.Error || manifest.ParseError;

pub const View = struct {
    evidence: *const evidence.Parsed,
    summary_size: u64,
    summary_sha256: []const u8,
    summary_identity: files.Identity,
};

pub const CurrentEvidence = struct {
    owner: ?*CurrentEvidence = null,
    input: ?files.Input = null,
    parsed: ?evidence.Parsed = null,

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self) return null;
        const input = if (self.input) |*owned_input| owned_input else return null;
        const parsed = if (self.parsed) |*owned_parsed| owned_parsed else return null;
        return .{
            .evidence = parsed,
            .summary_size = input.size,
            .summary_sha256 = &input.sha256,
            .summary_identity = input.identity,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) Error!void {
        if (self.owner != self or self.input == null or self.parsed == null)
            return error.InvalidOwner;
        self.parsed.?.deinit();
        self.parsed = null;
        self.input.?.deinit(allocator);
        self.input = null;
        self.owner = null;
    }
};

pub fn compose(
    allocator: std.mem.Allocator,
    current: *const current_input.CurrentManifestInput,
    predecessor: *const predecessor_mod.AuthenticatedManifest,
    summary_path: [:0]const u8,
    result: *CurrentEvidence,
) Error!void {
    if (result.owner != null or result.input != null or result.parsed != null)
        return error.InvalidOwner;
    const current_view = current.value() orelse return error.InvalidCurrent;
    const current_file = if (current.input) |*value| value else return error.InvalidCurrent;
    const predecessor_manifest = predecessor.value() orelse return error.InvalidPredecessor;
    const current_manifest = current_view.manifest;
    if (!current_view.authority.protected_environment or
        current_view.authority.repository_id != current_manifest.repository.id or
        current_view.authority.run_id != current_manifest.build.run_id or
        current_view.authority.run_attempt != current_manifest.build.run_attempt or
        current_view.authority.release_id != current_manifest.release.id or
        !std.mem.eql(u8, current_view.authority.source_commit, current_manifest.source.commit) or
        !std.mem.eql(u8, current_view.authority.tag, current_manifest.release.tag))
        return error.InvalidCurrent;

    const predecessor_expected = current_manifest.predecessor orelse return error.InvalidCurrent;
    if (current_manifest.role != .b or predecessor_manifest.role != .a or
        predecessor_manifest.predecessor != null or
        predecessor_expected.release_id != predecessor_manifest.release.id or
        !std.mem.eql(u8, predecessor_expected.tag, predecessor_manifest.release.tag) or
        !std.mem.eql(u8, predecessor_expected.commit, predecessor_manifest.source.commit))
        return error.InvalidPredecessor;

    const predecessor_bytes = try manifest.writeCanonical(allocator, predecessor_manifest.*);
    defer allocator.free(predecessor_bytes);
    var predecessor_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(predecessor_bytes, &predecessor_digest, .{});
    const predecessor_sha = std.fmt.bytesToHex(predecessor_digest, .lower);
    if (!std.mem.eql(u8, &predecessor_sha, predecessor_expected.manifest_sha256))
        return error.InvalidPredecessor;

    const summary_asset = assetForRole(current_manifest.assets, .evidence_summary) orelse
        return error.InvalidSummary;
    const current_dmg = assetForRole(current_manifest.assets, .universal_dmg) orelse
        return error.InvalidCurrent;
    const current_executable = assetForRole(current_manifest.assets, .frozen_product_executable) orelse
        return error.InvalidCurrent;
    const predecessor_dmg = assetForRole(predecessor_manifest.assets, .universal_dmg) orelse
        return error.InvalidPredecessor;
    const predecessor_executable = assetForRole(predecessor_manifest.assets, .frozen_product_executable) orelse
        return error.InvalidPredecessor;
    if (!std.fs.path.isAbsolute(summary_path) or
        !std.mem.eql(u8, std.fs.path.basename(summary_path), summary_asset.name) or
        !std.mem.eql(u8, summary_asset.name, current_manifest.evidence.summary_name) or
        !std.mem.eql(u8, summary_asset.sha256, current_manifest.evidence.summary_sha256) or
        !std.mem.eql(u8, current_manifest.evidence.result, "passed") or
        summary_asset.size == 0 or summary_asset.size > evidence.max_evidence_bytes)
        return error.InvalidSummary;

    var input = try files.readInputAlloc(allocator, summary_path, evidence.max_evidence_bytes);
    errdefer input.deinit(allocator);
    if (sameIdentity(input.identity, current_file.identity)) return error.PathAlias;
    if (input.size != summary_asset.size or !std.mem.eql(u8, &input.sha256, summary_asset.sha256))
        return error.InvalidSummary;

    var parsed = try evidence.parseCanonical(allocator, input.bytes);
    errdefer parsed.deinit();
    evidence.bind(parsed.value(), .{ .upgrade_b = .{
        .common = .{
            .test_uuid = current_manifest.evidence.test_uuid,
            .repository = .{ .id = current_manifest.repository.id, .owner = current_manifest.repository.owner, .name = current_manifest.repository.name },
            .release = .{ .id = current_manifest.release.id, .tag = current_manifest.release.tag, .version = current_manifest.release.version },
            .source = .{ .commit = current_manifest.source.commit, .tree = current_manifest.source.tree },
            .build = .{ .workflow_ref = current_manifest.build.workflow_ref, .run_id = current_manifest.build.run_id, .run_attempt = current_manifest.build.run_attempt },
            .candidate = .{ .dmg_sha256 = current_dmg.sha256, .executable_sha256 = current_executable.sha256 },
        },
        .predecessor = .{
            .release_id = predecessor_manifest.release.id,
            .tag = predecessor_manifest.release.tag,
            .commit = predecessor_manifest.source.commit,
            .manifest_sha256 = &predecessor_sha,
            .dmg_sha256 = predecessor_dmg.sha256,
            .executable_sha256 = predecessor_executable.sha256,
        },
        .designated_requirement_sha256 = current_manifest.signing.designated_requirement_sha256,
    } }) catch return error.EvidenceMismatch;

    result.input = input;
    result.parsed = parsed;
    result.owner = result;
}

fn assetForRole(assets: []const manifest.Asset, role: manifest.AssetRole) ?manifest.Asset {
    var found: ?manifest.Asset = null;
    for (assets) |asset| {
        if (asset.role != role) continue;
        if (found != null) return null;
        found = asset;
    }
    return found;
}

fn sameIdentity(left: files.Identity, right: files.Identity) bool {
    return left.device == right.device and left.inode == right.inode;
}
