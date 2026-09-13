const std = @import("std");
const context_mod = @import("release_adapter_context");
const evidence = @import("release_evidence");
const record = @import("release_adapter_notification_workflow_record");

const sha = "0123456789abcdef0123456789abcdef01234567";
const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const context: context_mod.Context = .{ .repository = .{ .id = 1257870483, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = sha, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 3, .run_attempt = 2 }, .protected_tag = true };

fn leaf() evidence.NotificationCenterGate {
    const scenario: evidence.NotificationCenterScenarioInput = .{ .host_id = "h", .runtime_id = "r", .event_id = 1, .request_identifier = "q", .visible_nonce = "n", .daemon_pid_before = 1, .daemon_pid_after = 1, .child_pid_before = 2, .child_pid_after = 2, .submitted_at_ns = 1, .delivered_at_ns = 2, .clicked_at_ns = 3, .callback_at_ns = 4, .attached_at_ns = 5, .os_delivered = true, .actual_click = true, .exact_attach = true, .screen_before_preserved = true, .screen_after_writable = true };
    return .{ .schema = "maru.session-host-notification-center.v1", .test_uuid = "123e4567-e89b-42d3-a456-426614174000", .result = .passed, .candidate_dmg_sha256 = digest, .candidate_executable_sha256 = digest, .designated_requirement_sha256 = digest, .permission = .authorized, .gui_zero = scenario, .gui_live_then_quit = scenario, .cleanup_complete = true };
}

fn authority() record.Authority {
    return .{ .repository_id = context.repository.id, .run_id = 3, .run_attempt = 2, .source_commit = sha, .job_id = 4, .deployment_id = 5, .environment_id = 6, .protected_environment = true };
}
fn attestation() record.Attestation {
    return .{ .verified = true, .run_id = 3, .run_attempt = 2, .subject_name = "notification-center.json", .subject_sha256 = digest, .self_hosted = true };
}

test "exact protected attempt and self-hosted attestation produce canonical record" {
    const bytes = try record.encode(std.testing.allocator, context, leaf(), "notification-center.json", digest, authority(), attestation());
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parse(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 4), parsed.value.job_id);
    try std.testing.expectEqualStrings(digest, parsed.value.evidence_sha256);
}

test "authority attestation and evidence drift publish nothing" {
    var a = authority();
    a.run_attempt = 1;
    try std.testing.expectError(error.AuthorityMismatch, record.encode(std.testing.allocator, context, leaf(), "notification-center.json", digest, a, attestation()));
    var t = attestation();
    t.self_hosted = false;
    try std.testing.expectError(error.AttestationMismatch, record.encode(std.testing.allocator, context, leaf(), "notification-center.json", digest, authority(), t));
    var l = leaf();
    l.cleanup_complete = false;
    try std.testing.expectError(error.EvidenceMismatch, record.encode(std.testing.allocator, context, l, "notification-center.json", digest, authority(), attestation()));
}

test "canonical parser rejects intrinsic candidate identity drift" {
    const bytes = try record.encode(std.testing.allocator, context, leaf(), "notification-center.json", digest, authority(), attestation());
    defer std.testing.allocator.free(bytes);
    const hostile = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(hostile);
    const uuid = std.mem.indexOf(u8, hostile, "123e4567-e89b-42d3-a456-426614174000") orelse return error.UuidMissing;
    hostile[uuid + 14] = '1';
    try std.testing.expectError(error.InvalidRecord, record.parse(std.testing.allocator, hostile));
}
