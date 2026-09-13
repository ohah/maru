//! Canonical durable verdict for one protected signed-tombstone product attempt.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const evidence = @import("release_adapter_tombstone_evidence");

pub const schema = "maru.session-host-tombstone-workflow-pass.v1";
pub const max_bytes: usize = 8 * 1024;

pub const Authority = struct { repository_id: u64, run_id: u64, run_attempt: u64, source_commit: []const u8, job_id: u64, deployment_id: u64, environment_id: u64, protected_environment: bool };
pub const Attestation = struct { verified: bool, run_id: u64, run_attempt: u64, subject_name: []const u8, subject_sha256: []const u8, self_hosted: bool };
pub const Record = struct {
    schema: []const u8,
    result: enum { passed },
    repository_id: u64,
    source_sha: []const u8,
    workflow_ref: []const u8,
    run_id: u64,
    run_attempt: u64,
    job_id: u64,
    deployment_id: u64,
    environment_id: u64,
    evidence_name: []const u8,
    evidence_sha256: []const u8,
    test_uuid: []const u8,
    candidate_dmg_sha256: []const u8,
    candidate_executable_sha256: []const u8,
    designated_requirement_sha256: []const u8,
    runtime_handle: []const u8,
    checkpoint_sha256: []const u8,
};

pub fn encode(allocator: std.mem.Allocator, context: context_mod.Context, leaf: evidence.Record, name: []const u8, digest: []const u8, authority: Authority, attested: Attestation) ![]u8 {
    try context_mod.validateTrusted(context);
    if (!authority.protected_environment or authority.repository_id != context.repository.id or authority.run_id != context.build.run_id or
        authority.run_attempt != context.build.run_attempt or !std.mem.eql(u8, authority.source_commit, context.source_commit) or
        authority.job_id == 0 or authority.deployment_id == 0 or authority.environment_id == 0) return error.AuthorityMismatch;
    if (!attested.verified or !attested.self_hosted or attested.run_id != context.build.run_id or attested.run_attempt != context.build.run_attempt or
        !std.mem.eql(u8, attested.subject_name, name) or !std.mem.eql(u8, attested.subject_sha256, digest)) return error.AttestationMismatch;
    if (!std.mem.eql(u8, name, "tombstone-relaunch.json") or !lowerHex(digest, 64)) return error.EvidenceMismatch;
    const canonical_leaf = try evidence.encode(allocator, leaf);
    defer allocator.free(canonical_leaf);
    const value: Record = .{ .schema = schema, .result = .passed, .repository_id = context.repository.id, .source_sha = context.source_commit, .workflow_ref = context.build.workflow_ref, .run_id = context.build.run_id, .run_attempt = context.build.run_attempt, .job_id = authority.job_id, .deployment_id = authority.deployment_id, .environment_id = authority.environment_id, .evidence_name = name, .evidence_sha256 = digest, .test_uuid = leaf.test_uuid, .candidate_dmg_sha256 = leaf.candidate_dmg_sha256, .candidate_executable_sha256 = leaf.candidate_executable_sha256, .designated_requirement_sha256 = leaf.designated_requirement_sha256, .runtime_handle = leaf.runtime_handle, .checkpoint_sha256 = leaf.checkpoint_first_sha256 };
    return encodeRecord(allocator, value);
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Record) {
    if (bytes.len == 0 or bytes.len > max_bytes or bytes[bytes.len - 1] != '\n') return error.NonCanonical;
    var parsed = std.json.parseFromSlice(Record, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false, .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(u8, value.schema, schema) or value.repository_id == 0 or value.run_id == 0 or value.run_attempt == 0 or
        value.job_id == 0 or value.deployment_id == 0 or value.environment_id == 0 or !lowerHex(value.source_sha, 40) or
        value.workflow_ref.len == 0 or !std.mem.eql(u8, value.evidence_name, "tombstone-relaunch.json") or
        !lowerHex(value.evidence_sha256, 64) or !canonicalUuid(value.test_uuid) or !runtimeHandle(value.runtime_handle) or
        !lowerHex(value.candidate_dmg_sha256, 64) or
        !lowerHex(value.candidate_executable_sha256, 64) or !lowerHex(value.designated_requirement_sha256, 64) or
        !lowerHex(value.checkpoint_sha256, 64)) return error.InvalidRecord;
    const canonical = try encodeRecord(allocator, value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, bytes)) return error.NonCanonical;
    return parsed;
}

fn encodeRecord(allocator: std.mem.Allocator, value: Record) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    try json.write(value);
    try output.writer.writeByte('\n');
    if (output.writer.end > max_bytes) return error.RecordTooLarge;
    return output.toOwnedSlice();
}

fn lowerHex(value: []const u8, expected: usize) bool {
    if (value.len != expected) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn canonicalUuid(value: []const u8) bool {
    if (value.len != 36 or value[8] != '-' or value[13] != '-' or value[18] != '-' or value[23] != '-' or
        value[14] != '4' or (value[19] != '8' and value[19] != '9' and value[19] != 'a' and value[19] != 'b')) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) continue;
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn runtimeHandle(value: []const u8) bool {
    return value.len == 65 and value[32] == ':' and lowerHex(value[0..32], 32) and lowerHex(value[33..], 32);
}
