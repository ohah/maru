const std = @import("std");
const subject = @import("release_adapter_notification_candidate_product");
const app_receipt = @import("release_adapter_notification_app_receipt");
const dmg = @import("release_adapter_dmg_authority");

const zero_uuid = "123e4567-e89b-42d3-a456-426614174000";
const live_uuid = "123e4567-e89b-42d3-a456-426614174001";
const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "mounted candidate alone supplies executable paths to both notification scenarios" {
    const candidate = mounted();
    const source = inputs();
    const result = subject.materializeForTest(&source, candidate);
    try std.testing.expectEqualStrings(candidate.main_path, result.gui_zero.app_executable);
    try std.testing.expectEqualStrings(candidate.main_path, result.gui_live_then_quit.app_executable);
    try std.testing.expectEqualStrings(candidate.helper_path, result.gui_zero.helper_executable);
    try std.testing.expectEqualStrings(candidate.helper_path, result.gui_live_then_quit.helper_executable);
    try std.testing.expectEqualStrings(sha, result.candidate_dmg_sha256);
}

test "caller scenario identity and mounted executable identity remain separate axes" {
    var candidate = mounted();
    candidate.main_path = "/private/tmp/mount-b/Maru.app/Contents/MacOS/maru-macos-app";
    candidate.helper_path = "/private/tmp/mount-b/Maru.app/Contents/Helpers/maru-session-host-notification-center-helper";
    const source = inputs();
    const result = subject.materializeForTest(&source, candidate);
    try std.testing.expectEqualStrings(zero_uuid, result.gui_zero.runner_nonce);
    try std.testing.expectEqualStrings("/private/tmp/mn-123e4567e89b42d3a456426614174000", result.gui_zero.runner_root);
    try std.testing.expectEqualStrings(candidate.main_path, result.gui_zero.app_executable);
    try std.testing.expectEqualStrings(candidate.helper_path, result.gui_zero.helper_executable);
}

test "product adapter owns caller strings before the mount callback" {
    var version = "1.2.3".*;
    var dmg_path = "/private/tmp/candidate.dmg".*;
    var work_path = "/private/tmp/dmg-work".*;
    var executable_sha = sha.*;
    var runner_nonce = zero_uuid.*;
    var request_identifier = "maru-11111111111111111111111111111111-22222222222222222222222222222222-1".*;
    var before_marker = "before-zero".*;
    var source = inputs();
    source.expected_version = &version;
    source.candidate_dmg = @ptrCast(dmg_path[0..]);
    source.private_dmg_work = @ptrCast(work_path[0..]);
    source.candidate_executable_sha256 = &executable_sha;
    source.gui_zero.runner_nonce = &runner_nonce;
    source.gui_zero.app_expected.request_identifier = &request_identifier;
    source.gui_zero.before_marker = &before_marker;
    var adapter: subject.Adapter = .{};
    try adapter.init(std.testing.allocator, std.testing.io, source);
    version[0] = '9';
    dmg_path[13] = 'X';
    work_path[13] = 'X';
    executable_sha[0] = 'f';
    runner_nonce[0] = '9';
    request_identifier[0] = 'X';
    before_marker[0] = 'X';
    try std.testing.expectEqualStrings("1.2.3", adapter.inputs.expected_version);
    try std.testing.expectEqualStrings("/private/tmp/candidate.dmg", adapter.inputs.candidate_dmg);
    try std.testing.expectEqualStrings("/private/tmp/dmg-work", adapter.inputs.private_dmg_work);
    try std.testing.expectEqualStrings(sha, adapter.inputs.candidate_executable_sha256);
    try std.testing.expectEqualStrings(zero_uuid, adapter.inputs.gui_zero.runner_nonce);
    try std.testing.expectEqualStrings("maru-11111111111111111111111111111111-22222222222222222222222222222222-1", adapter.inputs.gui_zero.app_expected.request_identifier);
    try std.testing.expectEqualStrings("before-zero", adapter.inputs.gui_zero.before_marker);
    try adapter.cleanup();
}

test "product adapter input capture is allocation-failure atomic" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCapture, .{});
}

fn allocationCapture(allocator: std.mem.Allocator) !void {
    var adapter: subject.Adapter = .{};
    adapter.init(allocator, std.testing.io, inputs()) catch |err| {
        try std.testing.expect(adapter.owner == null);
        return err;
    };
    try adapter.cleanup();
}

fn inputs() subject.Inputs {
    return .{
        .candidate_dmg = "/private/tmp/candidate.dmg",
        .private_dmg_work = "/private/tmp/dmg-work",
        .expected_dmg = .{ .size = 10, .sha256 = sha.* },
        .expected_version = "1.2.3",
        .test_uuid = zero_uuid,
        .candidate_executable_sha256 = sha,
        .designated_requirement_sha256 = sha,
        .gui_zero = scenario(.gui_zero, zero_uuid, 1),
        .gui_live_then_quit = scenario(.gui_live_then_quit, live_uuid, 2),
        .output_path = "/private/tmp/notification-center.json",
        .budget_ns = std.time.ns_per_min,
    };
}

fn scenario(kind: app_receipt.Scenario, uuid: []const u8, event: u64) subject.Scenario {
    const zero = kind == .gui_zero;
    return .{
        .runner_nonce = uuid,
        .runner_root = if (zero) "/private/tmp/mn-123e4567e89b42d3a456426614174000" else "/private/tmp/mn-123e4567e89b42d3a456426614174001",
        .output_path = if (zero) "/private/tmp/zero.json" else "/private/tmp/live.json",
        .app_expected = .{ .scenario = kind, .request_identifier = if (zero) "maru-11111111111111111111111111111111-22222222222222222222222222222222-1" else "maru-11111111111111111111111111111111-22222222222222222222222222222222-2", .host_id = "11111111111111111111111111111111", .runtime_id = "22222222222222222222222222222222", .event_id = event, .clicked_at_ns = 1, .deadline_ns = 100 },
        .helper_expected = .{ .visible_nonce = if (zero) zero_uuid ++ "-gui-zero" else live_uuid ++ "-gui-live-then-quit", .deadline_ns = 100 },
        .submitted_at_ns = 1,
        .before_marker = if (zero) "before-zero" else "before-live",
        .after_marker = if (zero) "after-zero" else "after-live",
        .budget_ns = std.time.ns_per_min,
    };
}

fn mounted() dmg.MountedCandidate {
    return .{
        .cli_path = "/private/tmp/extracted/maru",
        .app_bundle_path = "/private/tmp/mount/Maru.app",
        .main_path = "/private/tmp/mount/Maru.app/Contents/MacOS/maru-macos-app",
        .mounted_cli_path = "/private/tmp/mount/Maru.app/Contents/MacOS/maru",
        .helper_path = "/private/tmp/mount/Maru.app/Contents/Helpers/maru-session-host-notification-center-helper",
        .main_sha256 = sha,
        .cli_sha256 = sha,
        .helper_sha256 = sha,
        .designated_requirement_sha256 = sha,
        .team_id = "TEAMID0000",
    };
}
