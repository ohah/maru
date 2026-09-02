//! Trusted baseline-A evidence publication from one revalidated candidate identity.

const std = @import("std");
const builtin = @import("builtin");
const evidence = @import("release_evidence");
const evidence_files = @import("release_evidence_files");
const context_mod = @import("release_adapter_context");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const candidate_identity = @import("release_adapter_candidate_evidence_identity");
const source_tree = @import("release_adapter_github_source_tree");

pub const PublishedEvidence = evidence_files.PublishedEvidence;
pub const IdentityView = candidate_identity.View;
pub const Paths = struct {
    default_false: [:0]const u8,
    signed_app_quit: [:0]const u8,
    output: [:0]const u8,
};

pub fn publish(
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    identity: *const candidate_identity.CandidateEvidenceIdentity,
    files: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    candidate_paths: candidate_product.Paths,
    source: *const source_tree.SourceTreeAuthority,
    paths: Paths,
    result: *PublishedEvidence,
) !void {
    try validateConcreteAliases(result, context, identity, files, product, candidate_paths, source);
    var authority = Authority{
        .context = context,
        .identity = identity,
        .files = files,
        .product = product,
        .candidate_paths = candidate_paths,
        .source = source,
    };
    try publishFromAuthority(allocator, &authority, paths, result);
}

pub fn publishWith(allocator: std.mem.Allocator, authority: anytype, paths: Paths, result: *PublishedEvidence) !void {
    if (!builtin.is_test) @compileError("publishWith is a test-only seam");
    try publishFromAuthority(allocator, authority, paths, result);
}

fn publishFromAuthority(allocator: std.mem.Allocator, authority: anytype, paths: Paths, result: *PublishedEvidence) !void {
    try validateInputs(authority, paths, result);
    const initial = try authority.revalidate();
    var snapshot: Snapshot = .{};
    try snapshot.capture(initial);
    var validator = PublicationValidator(@TypeOf(authority)){
        .authority = authority,
        .expected = &snapshot,
    };
    try evidence_files.publishBaselineOwnedValidated(allocator, .{
        .common = snapshot.common(),
        .default_false_path = paths.default_false,
        .signed_app_quit_path = paths.signed_app_quit,
        .output_path = paths.output,
    }, &validator, result);
}

const Authority = struct {
    context: context_mod.Context,
    identity: *const candidate_identity.CandidateEvidenceIdentity,
    files: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    candidate_paths: candidate_product.Paths,
    source: *const source_tree.SourceTreeAuthority,

    pub fn revalidate(self: *@This()) !IdentityView {
        return self.identity.revalidate(
            self.context,
            self.files,
            self.product,
            self.candidate_paths,
            self.source,
        );
    }
};

fn PublicationValidator(comptime AuthorityType: type) type {
    return struct {
        authority: AuthorityType,
        expected: *const Snapshot,

        pub fn validate(self: *@This()) !void {
            const current = try self.authority.revalidate();
            if (!self.expected.matches(current)) return error.AuthorityChanged;
        }
    };
}

const Snapshot = struct {
    test_uuid: [36]u8 = @splat(0),
    repository_id: u64 = 0,
    release_id: u64 = 0,
    tag: [context_mod.max_value_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    source_tree_sha: [40]u8 = @splat(0),
    workflow_ref: [context_mod.max_value_bytes]u8 = @splat(0),
    workflow_ref_len: usize = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,
    dmg_sha256: [64]u8 = @splat(0),
    executable_sha256: [64]u8 = @splat(0),
    designated_requirement_sha256: [64]u8 = @splat(0),

    fn capture(self: *@This(), view: IdentityView) !void {
        try evidence.validateCommon(view.common);
        if (view.common.test_uuid.len != self.test_uuid.len or
            view.common.repository.owner.len != "ohah".len or
            view.common.repository.name.len != "maru".len or
            view.common.release.tag.len > self.tag.len or
            view.common.source.commit.len != self.source_commit.len or
            view.common.source.tree.len != self.source_tree_sha.len or
            view.common.build.workflow_ref.len > self.workflow_ref.len or
            view.common.candidate.dmg_sha256.len != self.dmg_sha256.len or
            view.common.candidate.executable_sha256.len != self.executable_sha256.len or
            view.designated_requirement_sha256.len != self.designated_requirement_sha256.len)
            return error.InvalidIdentity;
        self.repository_id = view.common.repository.id;
        self.release_id = view.common.release.id;
        @memcpy(&self.test_uuid, view.common.test_uuid);
        self.tag_len = view.common.release.tag.len;
        @memcpy(self.tag[0..self.tag_len], view.common.release.tag);
        @memcpy(&self.source_commit, view.common.source.commit);
        @memcpy(&self.source_tree_sha, view.common.source.tree);
        self.workflow_ref_len = view.common.build.workflow_ref.len;
        @memcpy(self.workflow_ref[0..self.workflow_ref_len], view.common.build.workflow_ref);
        self.run_id = view.common.build.run_id;
        self.run_attempt = view.common.build.run_attempt;
        @memcpy(&self.dmg_sha256, view.common.candidate.dmg_sha256);
        @memcpy(&self.executable_sha256, view.common.candidate.executable_sha256);
        @memcpy(&self.designated_requirement_sha256, view.designated_requirement_sha256);
        try evidence.validateCommon(self.common());
    }

    fn common(self: *const @This()) evidence.Common {
        return .{
            .test_uuid = &self.test_uuid,
            .repository = .{ .id = self.repository_id, .owner = "ohah", .name = "maru" },
            .release = .{ .id = self.release_id, .tag = self.tag[0..self.tag_len], .version = self.tag[1..self.tag_len] },
            .source = .{ .commit = &self.source_commit, .tree = &self.source_tree_sha },
            .build = .{ .workflow_ref = self.workflow_ref[0..self.workflow_ref_len], .run_id = self.run_id, .run_attempt = self.run_attempt },
            .candidate = .{ .dmg_sha256 = &self.dmg_sha256, .executable_sha256 = &self.executable_sha256 },
        };
    }

    fn matches(self: *const @This(), view: IdentityView) bool {
        const expected = self.common();
        const current = view.common;
        return current.repository.id == expected.repository.id and
            current.release.id == expected.release.id and
            current.build.run_id == expected.build.run_id and
            current.build.run_attempt == expected.build.run_attempt and
            equal(current.test_uuid, expected.test_uuid) and
            equal(current.repository.owner, expected.repository.owner) and
            equal(current.repository.name, expected.repository.name) and
            equal(current.release.tag, expected.release.tag) and
            equal(current.release.version, expected.release.version) and
            equal(current.source.commit, expected.source.commit) and
            equal(current.source.tree, expected.source.tree) and
            equal(current.build.workflow_ref, expected.build.workflow_ref) and
            equal(current.candidate.dmg_sha256, expected.candidate.dmg_sha256) and
            equal(current.candidate.executable_sha256, expected.candidate.executable_sha256) and
            equal(view.designated_requirement_sha256, &self.designated_requirement_sha256);
    }
};

fn validateInputs(authority: anytype, paths: Paths, result: *const PublishedEvidence) !void {
    if (result.owner != null or result.fd >= 0 or result.parent_fd >= 0) return error.InvalidOwner;
    const result_bytes = std.mem.asBytes(result);
    if (overlaps(result_bytes, std.mem.asBytes(authority)) or
        overlaps(result_bytes, paths.default_false) or
        overlaps(result_bytes, paths.signed_app_quit) or
        overlaps(result_bytes, paths.output))
        return error.InvalidOwner;
}

fn validateConcreteAliases(
    result: *const PublishedEvidence,
    context: context_mod.Context,
    identity: *const candidate_identity.CandidateEvidenceIdentity,
    files: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    paths: candidate_product.Paths,
    source: *const source_tree.SourceTreeAuthority,
) !void {
    const result_bytes = std.mem.asBytes(result);
    const values = [_][]const u8{
        context.repository.owner,
        context.repository.name,
        context.tag,
        context.source_commit,
        context.build.workflow_ref,
        paths.dmg,
        paths.frozen_executable,
        paths.dmg_work,
        std.mem.asBytes(identity),
        std.mem.asBytes(files),
        std.mem.asBytes(product),
        std.mem.asBytes(source),
    };
    for (values) |value| if (overlaps(result_bytes, value)) return error.InvalidOwner;
}

fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
