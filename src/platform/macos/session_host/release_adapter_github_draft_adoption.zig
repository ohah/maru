//! Converts a reauthenticated mutable release into the existing ready draft authority.
//!
//! The process boundary cannot carry the original draft owner. Reusing the current-release
//! authentication graph here keeps publication on one authority type without a second lookup or
//! remote mutation path.

const std = @import("std");
const manifest_mod = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const current_mod = @import("release_adapter_github_current_release_authority");
const draft_mod = @import("release_adapter_github_draft_creation");

pub const Error = manifest_mod.ParseError || context_mod.Error || error{
    InvalidOwner,
    InvalidCurrentAuthority,
    CurrentAuthorityMismatch,
    StorageAlias,
};

pub fn adopt(
    context: context_mod.Context,
    candidate: manifest_mod.Manifest,
    current: *const current_mod.CurrentReleaseAuthority,
    result: *draft_mod.DraftAuthority,
) Error!void {
    const result_bytes = std.mem.asBytes(result);
    if (rangesOverlap(result_bytes, std.mem.asBytes(current)) or
        manifest_mod.aliasesStorage(&candidate, result_bytes) or
        contextAliases(context, result_bytes)) return error.StorageAlias;
    if (!pristine(result)) return error.InvalidOwner;

    if (current.owner != current or current.tag_len == 0 or current.tag_len > current.tag.len)
        return error.InvalidCurrentAuthority;
    const observed = current.value() orelse return error.InvalidCurrentAuthority;
    try manifest_mod.validateIntrinsic(candidate);
    if (candidate.role != .a or candidate.predecessor != null) return error.InvalidRolePolicy;
    try context_mod.bindManifest(context, candidate);
    if (!context.protected_tag or
        observed.repository_id != context.repository.id or
        observed.run_id != context.build.run_id or
        observed.run_attempt != context.build.run_attempt or
        !std.mem.eql(u8, observed.source_commit, context.source_commit) or
        observed.release_id != candidate.release.id or
        !std.mem.eql(u8, observed.tag, candidate.release.tag) or
        observed.job_id == 0 or observed.deployment_id == 0 or observed.environment_id == 0 or
        !observed.protected_environment) return error.CurrentAuthorityMismatch;

    if (observed.tag.len > result.tag.len or observed.source_commit.len != result.source_commit.len)
        return error.CurrentAuthorityMismatch;
    var ready: draft_mod.DraftAuthority = .{
        .status = .cleanup_required,
        .id = observed.release_id,
        .tag_len = observed.tag.len,
    };
    @memcpy(ready.tag[0..ready.tag_len], observed.tag);
    @memcpy(&ready.source_commit, observed.source_commit);
    result.* = ready;
    errdefer result.* = .{};
    try result.publish();
}

fn pristine(result: *const draft_mod.DraftAuthority) bool {
    return result.owner == null and result.status == .empty and result.id == 0 and result.tag_len == 0 and
        allZero(&result.tag) and allZero(&result.source_commit);
}

fn contextAliases(context: context_mod.Context, candidate: []const u8) bool {
    inline for (.{
        context.repository.owner,
        context.repository.name,
        context.tag,
        context.source_commit,
        context.build.workflow_ref,
    }) |value| if (rangesOverlap(candidate, value)) return true;
    return false;
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
