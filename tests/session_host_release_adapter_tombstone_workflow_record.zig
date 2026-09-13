const std = @import("std");
const context_mod = @import("release_adapter_context");
const leaf_mod = @import("release_adapter_tombstone_evidence");
const record = @import("release_adapter_tombstone_workflow_record");

const sha = "0123456789abcdef0123456789abcdef01234567";
const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const context: context_mod.Context = .{ .repository = .{ .id = 1257870483, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = sha, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 3, .run_attempt = 2 }, .protected_tag = true };

fn leaf() leaf_mod.Record {
    return .{ .schema = leaf_mod.schema, .test_uuid = "123e4567-e89b-42d3-a456-426614174000", .result = .passed, .candidate_dmg_sha256 = digest, .candidate_executable_sha256 = digest, .designated_requirement_sha256 = digest, .runtime_handle = "1234567890abcdef1234567890abcdef:fedcba0987654321fedcba0987654321", .runtime_state = .ended, .relaunch_count = 2, .normal_quit_count = 2, .final_checkpoint_count = 2, .checkpoint_first_sha256 = digest, .checkpoint_second_sha256 = digest, .probe_count = 0, .attach_count = 0, .spawn_count = 0, .output_event_count = 0, .terminal_input_event_count = 0, .cleanup_complete = true };
}
fn authority() record.Authority {
    return .{ .repository_id = context.repository.id, .run_id = 3, .run_attempt = 2, .source_commit = sha, .job_id = 4, .deployment_id = 5, .environment_id = 6, .protected_environment = true };
}
fn attestation() record.Attestation {
    return .{ .verified = true, .run_id = 3, .run_attempt = 2, .subject_name = "tombstone-relaunch.json", .subject_sha256 = digest, .self_hosted = true };
}

test "protected attempt and self-hosted attestation produce canonical tombstone verdict" {
    const bytes = try record.encode(std.testing.allocator, context, leaf(), "tombstone-relaunch.json", digest, authority(), attestation());
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parse(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(digest, parsed.value.checkpoint_sha256);
}

test "authority attestation and leaf drift publish nothing" {
    var a = authority();
    a.run_attempt = 1;
    try std.testing.expectError(error.AuthorityMismatch, record.encode(std.testing.allocator, context, leaf(), "tombstone-relaunch.json", digest, a, attestation()));
    var t = attestation();
    t.self_hosted = false;
    try std.testing.expectError(error.AttestationMismatch, record.encode(std.testing.allocator, context, leaf(), "tombstone-relaunch.json", digest, authority(), t));
    var l = leaf();
    l.normal_quit_count = 1;
    try std.testing.expectError(error.InvalidEvidence, record.encode(std.testing.allocator, context, l, "tombstone-relaunch.json", digest, authority(), attestation()));
}
