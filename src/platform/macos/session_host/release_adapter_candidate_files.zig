//! Post-draft authority binding one created release to pre-draft attested candidate bytes.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const attestation_mod = @import("release_adapter_candidate_attestation");
const draft_mod = @import("release_adapter_github_draft_creation");
const identity = @import("release_adapter_identity");

pub const max_tag_bytes = context_mod.max_value_bytes;

pub const Paths = attestation_mod.Paths;
pub const BuildView = struct { workflow_ref: []const u8, run_id: u64, run_attempt: u64 };
pub const View = struct { release_id: u64, tag: []const u8, source_commit: []const u8, build: BuildView, dmg: files.ExecutableObservation, frozen: files.ExecutableObservation };

pub const CandidateFiles = struct {
    owner: ?*CandidateFiles = null,
    attestation: ?*const attestation_mod.CandidateAttestation = null,
    release_id: u64 = 0,

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self) return null;
        const attested = (self.attestation orelse return null).value() orelse return null;
        return .{ .release_id = self.release_id, .tag = attested.tag, .source_commit = attested.source_commit, .build = .{ .workflow_ref = attested.build.workflow_ref, .run_id = attested.build.run_id, .run_attempt = attested.build.run_attempt }, .dmg = attested.dmg, .frozen = attested.frozen };
    }
    pub fn revalidate(self: *const @This(), paths: Paths) !View {
        const current = self.value() orelse return error.InvalidOwner;
        const attested = try (self.attestation orelse return error.InvalidOwner).revalidate(paths);
        return .{ .release_id = current.release_id, .tag = attested.tag, .source_commit = attested.source_commit, .build = .{ .workflow_ref = attested.build.workflow_ref, .run_id = attested.build.run_id, .run_attempt = attested.build.run_attempt }, .dmg = attested.dmg, .frozen = attested.frozen };
    }
    pub fn deinit(self: *@This()) !void {
        if (self.owner != self or self.attestation == null) return error.InvalidOwner;
        self.* = .{};
    }
};

pub fn observe(context: context_mod.Context, draft: *const draft_mod.DraftAuthority, attested: *const attestation_mod.CandidateAttestation, paths: Paths, result: *CandidateFiles) !void {
    if (result.owner != null or result.attestation != null or
        objectsOverlap(CandidateFiles, result, draft_mod.DraftAuthority, draft) or
        objectsOverlap(CandidateFiles, result, attestation_mod.CandidateAttestation, attested)) return error.InvalidOwner;
    const draft_view = draft.value() orelse return error.InvalidDraft;
    if (!context.protected_tag or context.repository.id == 0 or draft_view.id == 0 or !std.mem.eql(u8, context.repository.owner, "ohah") or
        !std.mem.eql(u8, context.repository.name, "maru") or !identity.canonicalTag(context.tag) or !identity.lowerHex(context.source_commit, 40) or
        !std.mem.eql(u8, context.tag, draft_view.tag) or !std.mem.eql(u8, context.source_commit, draft_view.source_commit)) return error.AuthorityMismatch;
    const attested_view = attested.revalidate(paths) catch return error.InvalidAttestation;
    if (!std.mem.eql(u8, context.tag, attested_view.tag) or !std.mem.eql(u8, context.source_commit, attested_view.source_commit) or
        !std.mem.eql(u8, context.build.workflow_ref, attested_view.build.workflow_ref) or context.build.run_id != attested_view.build.run_id or
        context.build.run_attempt != attested_view.build.run_attempt) return error.AuthorityMismatch;
    try files.requireDistinct(&.{ attested_view.dmg.identity, attested_view.frozen.identity });
    result.release_id = draft_view.id;
    result.attestation = attested;
    result.owner = result;
}

fn objectsOverlap(comptime A: type, a: *const A, comptime B: type, b: *const B) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    return a_start < b_start + @sizeOf(B) and b_start < a_start + @sizeOf(A);
}
