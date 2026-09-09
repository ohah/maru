//! Contract tests for the credential-free final remote release verdict binding.

const std = @import("std");
const verdict = @import("release_adapter_remote_release_verdict");
const observation = @import("release_adapter_remote_release_observation");
const timing = @import("release_adapter_live_timing_artifact");
const evidence = @import("release_evidence");
const asset_tests = @import("session_host_release_adapter_remote_release_assets.zig");
const observation_tests = @import("session_host_release_adapter_remote_release_observation.zig");
const timing_tests = @import("session_host_release_adapter_live_timing_artifact.zig");

test "baseline timing and attested Release publish one current-attempt verdict" {
    var fixture: observation_tests.Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var remote: observation.Observation = .{};
    try fixture.compose(std.testing.allocator, &remote);
    defer remote.deinit(std.testing.allocator) catch {};
    var provenance: timing.Provenance = .{};
    try timing_tests.makeProvenance(std.testing.allocator, &provenance);
    defer provenance.deinit() catch {};
    var context = asset_tests.context();
    var result: verdict.Verdict = .{};
    try verdict.bind(&context, &provenance, &remote, &result);
    const value = result.value() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(evidence.Profile.baseline_a, value.profile);
    try std.testing.expectEqual(@as(u64, 88), value.release_id);
    try std.testing.expectEqual(@as(u64, 987), value.timing_artifact_id);
    try std.testing.expectEqual(@as(u64, 333), value.run_id);
    try std.testing.expectEqual(@as(u64, 2), value.run_attempt);
    try std.testing.expectEqual(@as(u64, 1000), value.duration_ms);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    copied.owner = null;
    try result.deinit();
    try std.testing.expect(result.value() == null);
}

test "upgrade profile comes only from authenticated Release evidence" {
    var fixture: observation_tests.Fixture = undefined;
    try fixture.init(.upgrade_b);
    defer fixture.deinit();
    var remote: observation.Observation = .{};
    try fixture.compose(std.testing.allocator, &remote);
    defer remote.deinit(std.testing.allocator) catch {};
    var provenance: timing.Provenance = .{};
    try timing_tests.makeProvenance(std.testing.allocator, &provenance);
    defer provenance.deinit() catch {};
    var context = asset_tests.context();
    var result: verdict.Verdict = .{};
    try verdict.bind(&context, &provenance, &remote, &result);
    defer result.deinit() catch {};
    try std.testing.expectEqual(evidence.Profile.upgrade_b, result.value().?.profile);
}

test "identity drift and dirty output fail without consuming upstream owners" {
    var fixture: observation_tests.Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var remote: observation.Observation = .{};
    try fixture.compose(std.testing.allocator, &remote);
    defer remote.deinit(std.testing.allocator) catch {};
    var provenance: timing.Provenance = .{};
    try timing_tests.makeProvenance(std.testing.allocator, &provenance);
    defer provenance.deinit() catch {};
    var context = asset_tests.context();
    var dirty: verdict.Verdict = .{ .timing_owner = &provenance };
    try std.testing.expectError(error.InvalidOwner, verdict.bind(&context, &provenance, &remote, &dirty));
    var result: verdict.Verdict = .{};
    context.build.run_attempt += 1;
    try std.testing.expectError(error.BindingMismatch, verdict.bind(&context, &provenance, &remote, &result));
    context.build.run_attempt -= 1;
    context.build.run_id += 1;
    try std.testing.expectError(error.BindingMismatch, verdict.bind(&context, &provenance, &remote, &result));
    context.build.run_id -= 1;
    context.repository.id += 1;
    try std.testing.expectError(error.BindingMismatch, verdict.bind(&context, &provenance, &remote, &result));
    context.repository.id -= 1;
    var foreign_source: [40]u8 = undefined;
    @memcpy(&foreign_source, context.source_commit);
    foreign_source[0] = if (foreign_source[0] == 'f') 'e' else 'f';
    context.source_commit = &foreign_source;
    try std.testing.expectError(error.BindingMismatch, verdict.bind(&context, &provenance, &remote, &result));
    try std.testing.expect(provenance.value() != null);
    try std.testing.expect(remote.value() != null);
}

test "context timing and Release drift revoke a published verdict" {
    var fixture: observation_tests.Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var remote: observation.Observation = .{};
    try fixture.compose(std.testing.allocator, &remote);
    defer remote.deinit(std.testing.allocator) catch {};
    var provenance: timing.Provenance = .{};
    try timing_tests.makeProvenance(std.testing.allocator, &provenance);
    defer provenance.deinit() catch {};
    var context = asset_tests.context();
    var result: verdict.Verdict = .{};
    try verdict.bind(&context, &provenance, &remote, &result);
    defer result.deinit() catch {};
    context.protected_tag = false;
    try std.testing.expect(result.value() == null);
    context.protected_tag = true;
    provenance.repository_id += 1;
    try std.testing.expect(result.value() == null);
    provenance.repository_id -= 1;
    fixture.assets.result.file_count -= 1;
    try std.testing.expect(result.value() == null);
    fixture.assets.result.file_count += 1;
}

test "verdict cleanup remains possible after caller-owned graph drift" {
    var fixture: observation_tests.Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var remote: observation.Observation = .{};
    try fixture.compose(std.testing.allocator, &remote);
    defer remote.deinit(std.testing.allocator) catch {};
    var provenance: timing.Provenance = .{};
    try timing_tests.makeProvenance(std.testing.allocator, &provenance);
    defer provenance.deinit() catch {};
    var context = asset_tests.context();
    var result: verdict.Verdict = .{};
    try verdict.bind(&context, &provenance, &remote, &result);
    fixture.assets.result.file_count -= 1;
    try std.testing.expect(result.value() == null);
    try result.deinit();
    try std.testing.expect(result.value() == null);
    fixture.assets.result.file_count += 1;
}
