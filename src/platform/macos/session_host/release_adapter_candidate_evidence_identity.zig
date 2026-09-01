//! Final-address common identity shared by baseline and upgrade evidence authoring.
//!
//! All durable values are copied from typed candidate/product/tree authorities. A later writer
//! must revalidate those authorities and cannot substitute caller-provided release or digest data.

const std = @import("std");
const evidence = @import("release_evidence");
const context_mod = @import("release_adapter_context");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const source_tree = @import("release_adapter_github_source_tree");
const scalar_identity = @import("release_adapter_identity");

pub const View = struct {
    common: evidence.Common,
    designated_requirement_sha256: []const u8,
};

pub const CandidateEvidenceIdentity = struct {
    owner: ?*CandidateEvidenceIdentity = null,
    test_uuid: [36]u8 = @splat(0),
    repository_id: u64 = 0,
    release_id: u64 = 0,
    tag: [context_mod.max_value_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    source_tree: [40]u8 = @splat(0),
    workflow_ref: [context_mod.max_value_bytes]u8 = @splat(0),
    workflow_ref_len: usize = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,
    dmg_sha256: [64]u8 = @splat(0),
    executable_sha256: [64]u8 = @splat(0),
    designated_requirement_sha256: [64]u8 = @splat(0),

    pub fn revalidate(self: *const @This(), context: context_mod.Context, files: *const candidate_files.CandidateFiles, product: *const candidate_product.CandidateProduct, paths: candidate_product.Paths, source: *const source_tree.SourceTreeAuthority) !View {
        if (self.owner != self) return error.InvalidOwner;
        try validateTrustedContext(context);
        const files_view = files.revalidate(.{ .dmg = paths.dmg, .frozen_executable = paths.frozen_executable }) catch return error.CandidateChanged;
        const product_view = product.revalidate(files, paths) catch return error.CandidateChanged;
        const source_view = source.value() orelse return error.InvalidSource;
        const derived_common = self.common();
        if (context.repository.id != self.repository_id or context.build.run_id != self.run_id or context.build.run_attempt != self.run_attempt or
            !std.mem.eql(u8, files_view.build.workflow_ref, context.build.workflow_ref) or files_view.build.run_id != context.build.run_id or files_view.build.run_attempt != context.build.run_attempt or
            !std.mem.eql(u8, product_view.build.workflow_ref, context.build.workflow_ref) or product_view.build.run_id != context.build.run_id or product_view.build.run_attempt != context.build.run_attempt or
            !std.mem.eql(u8, context.tag, derived_common.release.tag) or !std.mem.eql(u8, context.source_commit, derived_common.source.commit) or
            !std.mem.eql(u8, context.build.workflow_ref, derived_common.build.workflow_ref) or product_view.release_id != self.release_id or
            !std.mem.eql(u8, product_view.tag, derived_common.release.tag) or !std.mem.eql(u8, product_view.source_commit, derived_common.source.commit) or
            !std.mem.eql(u8, product_view.dmg_sha256, derived_common.candidate.dmg_sha256) or
            !std.mem.eql(u8, product_view.frozen_sha256, derived_common.candidate.executable_sha256) or
            !std.mem.eql(u8, source_view.commit, derived_common.source.commit) or !std.mem.eql(u8, source_view.tree, derived_common.source.tree) or
            !std.mem.eql(u8, product_view.apple.signing().designated_requirement_sha256, &self.designated_requirement_sha256))
            return error.BindingMismatch;
        try evidence.validateCommon(derived_common);
        return .{ .common = derived_common, .designated_requirement_sha256 = &self.designated_requirement_sha256 };
    }

    pub fn deinit(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        self.* = .{};
    }

    fn common(self: *const @This()) evidence.Common {
        return .{
            .test_uuid = &self.test_uuid,
            .repository = .{ .id = self.repository_id, .owner = "ohah", .name = "maru" },
            .release = .{ .id = self.release_id, .tag = self.tag[0..self.tag_len], .version = self.tag[1..self.tag_len] },
            .source = .{ .commit = &self.source_commit, .tree = &self.source_tree },
            .build = .{ .workflow_ref = self.workflow_ref[0..self.workflow_ref_len], .run_id = self.run_id, .run_attempt = self.run_attempt },
            .candidate = .{ .dmg_sha256 = &self.dmg_sha256, .executable_sha256 = &self.executable_sha256 },
        };
    }
};

pub fn compose(context: context_mod.Context, test_uuid: []const u8, files: *const candidate_files.CandidateFiles, product: *const candidate_product.CandidateProduct, paths: candidate_product.Paths, source: *const source_tree.SourceTreeAuthority, result: *CandidateEvidenceIdentity) !void {
    if (!pristine(result)) return error.InvalidOwner;
    const result_bytes = std.mem.asBytes(result);
    if (overlaps(result_bytes, test_uuid) or overlaps(result_bytes, paths.dmg) or overlaps(result_bytes, paths.frozen_executable) or overlaps(result_bytes, paths.dmg_work) or
        objectsOverlap(CandidateEvidenceIdentity, result, candidate_files.CandidateFiles, files) or
        objectsOverlap(CandidateEvidenceIdentity, result, candidate_product.CandidateProduct, product) or
        objectsOverlap(CandidateEvidenceIdentity, result, source_tree.SourceTreeAuthority, source)) return error.InvalidOwner;
    for ([_][]const u8{ context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref }) |authority_bytes|
        if (overlaps(result_bytes, authority_bytes)) return error.InvalidOwner;
    try validateTrustedContext(context);
    const files_view = files.revalidate(.{ .dmg = paths.dmg, .frozen_executable = paths.frozen_executable }) catch return error.CandidateChanged;
    const product_view = product.revalidate(files, paths) catch return error.CandidateChanged;
    const source_view = source.value() orelse return error.InvalidSource;
    if (product_view.release_id == 0 or !std.mem.eql(u8, files_view.build.workflow_ref, context.build.workflow_ref) or
        files_view.build.run_id != context.build.run_id or files_view.build.run_attempt != context.build.run_attempt or
        !std.mem.eql(u8, product_view.build.workflow_ref, context.build.workflow_ref) or product_view.build.run_id != context.build.run_id or product_view.build.run_attempt != context.build.run_attempt or
        !std.mem.eql(u8, product_view.tag, context.tag) or
        !std.mem.eql(u8, product_view.source_commit, context.source_commit) or
        !std.mem.eql(u8, source_view.commit, context.source_commit)) return error.BindingMismatch;
    if (test_uuid.len != result.test_uuid.len) return error.InvalidUuid;
    if (context.tag.len > result.tag.len or context.build.workflow_ref.len > result.workflow_ref.len) return error.BindingMismatch;
    const common: evidence.Common = .{
        .test_uuid = test_uuid,
        .repository = .{ .id = context.repository.id, .owner = context.repository.owner, .name = context.repository.name },
        .release = .{ .id = product_view.release_id, .tag = context.tag, .version = context.tag[1..] },
        .source = .{ .commit = context.source_commit, .tree = source_view.tree },
        .build = .{ .workflow_ref = context.build.workflow_ref, .run_id = context.build.run_id, .run_attempt = context.build.run_attempt },
        .candidate = .{ .dmg_sha256 = product_view.dmg_sha256, .executable_sha256 = product_view.frozen_sha256 },
    };
    try evidence.validateCommon(common);
    const requirement = product_view.apple.signing().designated_requirement_sha256;
    if (!scalar_identity.lowerHex(requirement, 64)) return error.BindingMismatch;

    @memcpy(&result.test_uuid, test_uuid);
    result.repository_id = context.repository.id;
    result.release_id = product_view.release_id;
    result.tag_len = context.tag.len;
    @memcpy(result.tag[0..result.tag_len], context.tag);
    @memcpy(&result.source_commit, context.source_commit);
    @memcpy(&result.source_tree, source_view.tree);
    result.workflow_ref_len = context.build.workflow_ref.len;
    @memcpy(result.workflow_ref[0..result.workflow_ref_len], context.build.workflow_ref);
    result.run_id = context.build.run_id;
    result.run_attempt = context.build.run_attempt;
    @memcpy(&result.dmg_sha256, product_view.dmg_sha256);
    @memcpy(&result.executable_sha256, product_view.frozen_sha256);
    @memcpy(&result.designated_requirement_sha256, requirement);
    result.owner = result;
}

fn validateTrustedContext(context: context_mod.Context) !void {
    if (!context.protected_tag or context.repository.id == 0 or !std.mem.eql(u8, context.repository.owner, "ohah") or
        !std.mem.eql(u8, context.repository.name, "maru") or !scalar_identity.canonicalTag(context.tag) or
        !scalar_identity.lowerHex(context.source_commit, 40) or context.build.run_id == 0 or context.build.run_attempt == 0) return error.BindingMismatch;
    var expected_storage: [context_mod.max_value_bytes]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_storage, "ohah/maru/.github/workflows/release.yml@refs/tags/{s}", .{context.tag}) catch return error.BindingMismatch;
    if (!std.mem.eql(u8, context.build.workflow_ref, expected)) return error.BindingMismatch;
}

fn pristine(result: *const CandidateEvidenceIdentity) bool {
    return result.owner == null and result.repository_id == 0 and result.release_id == 0 and result.tag_len == 0 and
        result.workflow_ref_len == 0 and result.run_id == 0 and result.run_attempt == 0 and
        allZero(&result.test_uuid) and allZero(&result.tag) and allZero(&result.source_commit) and allZero(&result.source_tree) and
        allZero(&result.workflow_ref) and allZero(&result.dmg_sha256) and allZero(&result.executable_sha256) and
        allZero(&result.designated_requirement_sha256);
}
fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}
fn objectsOverlap(comptime A: type, a: *const A, comptime B: type, b: *const B) bool {
    return overlaps(@as([*]const u8, @ptrCast(a))[0..@sizeOf(A)], @as([*]const u8, @ptrCast(b))[0..@sizeOf(B)]);
}
