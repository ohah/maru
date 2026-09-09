//! Proves that a durable remote pass record can only be projected from the sealed current verdict.

const std = @import("std");
const pass = @import("release_adapter_remote_release_pass_record");
const verdict_mod = @import("release_adapter_remote_release_verdict");
const observation = @import("release_adapter_remote_release_observation");
const timing = @import("release_adapter_live_timing_artifact");
const evidence = @import("release_evidence");
const asset_tests = @import("session_host_release_adapter_remote_release_assets.zig");
const observation_tests = @import("session_host_release_adapter_remote_release_observation.zig");
const timing_tests = @import("session_host_release_adapter_live_timing_artifact.zig");

pub const Fixture = struct {
    source: observation_tests.Fixture = undefined,
    remote: observation.Observation = .{},
    timing: timing.Provenance = .{},
    verdict: verdict_mod.Verdict = .{},
    context: @TypeOf(asset_tests.context()) = undefined,

    pub fn init(self: *@This(), profile: evidence.Profile) !void {
        self.* = .{};
        try self.source.init(profile);
        errdefer self.source.deinit();
        try self.source.compose(std.testing.allocator, &self.remote);
        errdefer self.remote.deinit(std.testing.allocator) catch {};
        try timing_tests.makeProvenance(std.testing.allocator, &self.timing);
        errdefer self.timing.deinit() catch {};
        self.context = asset_tests.context();
        try verdict_mod.bind(&self.context, &self.timing, &self.remote, &self.verdict);
    }

    pub fn deinit(self: *@This()) void {
        self.verdict.deinit() catch {};
        self.timing.deinit() catch {};
        self.remote.deinit(std.testing.allocator) catch {};
        self.source.deinit();
    }
};

test "baseline verdict projects exact canonical pass record" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var owner: pass.Owner = .{};
    try pass.encode(std.testing.allocator, &fixture.context, &fixture.verdict, &owner);
    defer owner.deinit(std.testing.allocator) catch {};
    const bytes = owner.value() orelse return error.TestUnexpectedResult;
    var parsed = try pass.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    const value = parsed.value();
    try std.testing.expectEqual(evidence.Profile.baseline_a, value.profile);
    try std.testing.expectEqual(pass.Result.passed, value.result);
    try std.testing.expectEqual(@as(u64, 88), value.release.id);
    try std.testing.expectEqual(@as(u64, 987), value.timing_artifact_id);
    try std.testing.expectEqual(@as(u64, 1000), value.duration_ms);
}

test "upgrade profile comes from authenticated verdict" {
    var fixture: Fixture = undefined;
    try fixture.init(.upgrade_b);
    defer fixture.deinit();
    var owner: pass.Owner = .{};
    try pass.encode(std.testing.allocator, &fixture.context, &fixture.verdict, &owner);
    defer owner.deinit(std.testing.allocator) catch {};
    var parsed = try pass.parseCanonical(std.testing.allocator, owner.value().?);
    defer parsed.deinit();
    try std.testing.expectEqual(evidence.Profile.upgrade_b, parsed.value().profile);
}

test "frozen record survives source cleanup and rejects copies or byte drift" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var owner: pass.Owner = .{};
    try pass.encode(std.testing.allocator, &fixture.context, &fixture.verdict, &owner);
    var frozen: pass.Frozen = .{};
    try pass.freeze(std.testing.allocator, &owner, &frozen);
    try owner.deinit(std.testing.allocator);
    try fixture.verdict.deinit();
    try std.testing.expect(frozen.value() != null);
    var copied = frozen;
    try std.testing.expect(copied.value() == null);
    copied.owner = null;
    frozen.bytes.?[0] ^= 1;
    try std.testing.expect(frozen.value() == null);
    frozen.bytes.?[0] ^= 1;
    try frozen.deinit(std.testing.allocator);
}

test "noncanonical duplicate unknown missing and trailing records fail closed" {
    const canonical =
        "{\"schema\":\"maru.session-host-release-remote-pass.v1\",\"profile\":\"baseline_a\",\"result\":\"passed\",\"repository\":{\"id\":42,\"owner\":\"ohah\",\"name\":\"maru\"},\"release\":{\"id\":88,\"tag\":\"v1.2.3\"},\"source_sha\":\"0123456789abcdef0123456789abcdef01234567\",\"workflow_ref\":\"ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3\",\"run_id\":333,\"run_attempt\":2,\"timing_artifact_id\":987,\"duration_ms\":1000}\n";
    var parsed = try pass.parseCanonical(std.testing.allocator, canonical);
    parsed.deinit();
    const reordered = "{\"profile\":\"baseline_a\",\"schema\":\"maru.session-host-release-remote-pass.v1\",\"result\":\"passed\",\"repository\":{\"id\":42,\"owner\":\"ohah\",\"name\":\"maru\"},\"release\":{\"id\":88,\"tag\":\"v1.2.3\"},\"source_sha\":\"0123456789abcdef0123456789abcdef01234567\",\"workflow_ref\":\"ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3\",\"run_id\":333,\"run_attempt\":2,\"timing_artifact_id\":987,\"duration_ms\":1000}\n";
    try std.testing.expectError(error.NonCanonical, pass.parseCanonical(std.testing.allocator, reordered));
    const trailing = canonical ++ "x";
    try std.testing.expectError(error.NonCanonical, pass.parseCanonical(std.testing.allocator, trailing));
    const unknown = canonical[0 .. canonical.len - 2] ++ ",\"extra\":1}\n";
    try std.testing.expectError(error.InvalidJson, pass.parseCanonical(std.testing.allocator, unknown));
    const duplicate = canonical[0 .. canonical.len - 2] ++ ",\"duration_ms\":1000}\n";
    try std.testing.expectError(error.InvalidJson, pass.parseCanonical(std.testing.allocator, duplicate));
    const missing =
        "{\"schema\":\"maru.session-host-release-remote-pass.v1\",\"profile\":\"baseline_a\",\"result\":\"passed\",\"repository\":{\"id\":42,\"owner\":\"ohah\",\"name\":\"maru\"},\"release\":{\"id\":88,\"tag\":\"v1.2.3\"},\"source_sha\":\"0123456789abcdef0123456789abcdef01234567\",\"workflow_ref\":\"ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3\",\"run_id\":333,\"run_attempt\":2,\"timing_artifact_id\":987}\n";
    try std.testing.expectError(error.InvalidJson, pass.parseCanonical(std.testing.allocator, missing));
}

test "copy and upstream drift revoke pass record without consuming inputs" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var owner: pass.Owner = .{};
    try pass.encode(std.testing.allocator, &fixture.context, &fixture.verdict, &owner);
    defer owner.deinit(std.testing.allocator) catch {};
    var copied = owner;
    try std.testing.expect(copied.value() == null);
    copied.owner = null;
    fixture.context.protected_tag = false;
    try std.testing.expect(owner.value() == null);
    fixture.context.protected_tag = true;
    try std.testing.expect(owner.value() != null);
    fixture.timing.repository_id += 1;
    try std.testing.expect(owner.value() == null);
    fixture.timing.repository_id -= 1;
    try std.testing.expect(owner.value() != null);
}

test "dirty output and allocation failure publish no owner" {
    var fixture: Fixture = undefined;
    try fixture.init(.baseline_a);
    defer fixture.deinit();
    var dirty: pass.Owner = .{ .context_owner = &fixture.context };
    try std.testing.expectError(error.InvalidOwner, pass.encode(std.testing.allocator, &fixture.context, &fixture.verdict, &dirty));
    var source: pass.Owner = .{};
    try pass.encode(std.testing.allocator, &fixture.context, &fixture.verdict, &source);
    defer source.deinit(std.testing.allocator) catch {};
    const aliased: *pass.Frozen = @ptrCast(@alignCast(source.bytes.?.ptr));
    try std.testing.expectError(error.InvalidOwner, pass.freeze(std.testing.allocator, &source, aliased));
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var result: pass.Owner = .{};
        pass.encode(failing.allocator(), &fixture.context, &fixture.verdict, &result) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(result.owner == null and result.bytes == null and result.parsed == null);
            continue;
        };
        try result.deinit(failing.allocator());
        break;
    }
    try std.testing.expect(fail_index > 0);

    fail_index = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var frozen: pass.Frozen = .{};
        pass.freeze(failing.allocator(), &source, &frozen) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(frozen.owner == null and frozen.bytes == null and frozen.parsed == null);
            try std.testing.expect(source.value() != null);
            continue;
        };
        try frozen.deinit(failing.allocator());
        break;
    }
    try std.testing.expect(fail_index > 0);
}
