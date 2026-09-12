//! Strict second app frame for the Notification Center release scenario.
//!
//! The first app frame proves callback -> attach. This frame proves that the attached product
//! observed one exact remote generation before and after attach, preserved its existing marker,
//! and round-tripped a runner-owned marker through PTY input. Callers never supply outcome bools.

const std = @import("std");
const evidence = @import("release_evidence");
const app_receipt = @import("release_adapter_notification_app_receipt");
const helper_receipt = @import("release_adapter_notification_helper_receipt");

pub const schema = "maru.session-host-notification-continuity-receipt.v1";
pub const max_receipt_bytes: usize = 2048;

pub const Expected = struct {
    visible_nonce: []const u8,
    app: app_receipt.Expected,
    app_receipt_bytes: []const u8,
    helper_receipt_bytes: []const u8,
    submitted_at_ns: u64,
    before_marker: []const u8,
    after_marker: []const u8,
};

pub const Observed = struct {
    scenario: evidence.NotificationCenterScenarioInput,
    connection_generation: u64,
};

const Wire = struct {
    schema: []const u8,
    scenario: []const u8,
    request_identifier: []const u8,
    host_id: []const u8,
    runtime_id: []const u8,
    event_id: u64,
    attached_at_ns: u64,
    connection_generation_before: u64,
    connection_generation_after: u64,
    host_pid_before: u64,
    host_pid_after: u64,
    child_pid_before: u64,
    child_pid_after: u64,
    before_marker: []const u8,
    after_marker: []const u8,
    before_observed_at_ns: u64,
    input_sent_at_ns: u64,
    after_observed_at_ns: u64,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, expected: Expected) !Observed {
    if (bytes.len == 0 or bytes.len > max_receipt_bytes) return error.ReceiptTooLarge;
    try validateExpected(expected);
    const helper_observed = try helper_receipt.parse(allocator, expected.helper_receipt_bytes, .{
        .visible_nonce = expected.visible_nonce,
        .deadline_ns = expected.app.deadline_ns,
    });
    if (helper_observed.clicked_at_ns != expected.app.clicked_at_ns or
        helper_observed.observed_at_ns <= expected.submitted_at_ns) return error.EvidenceMismatch;
    var app_expected = expected.app;
    app_expected.clicked_at_ns = helper_observed.clicked_at_ns;
    const app_observed = try app_receipt.parse(allocator, expected.app_receipt_bytes, app_expected);
    var parsed = std.json.parseFromSlice(Wire, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidReceipt,
    };
    defer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(u8, value.schema, schema) or
        !std.mem.eql(u8, value.scenario, expected.app.scenario.wire()) or
        !std.mem.eql(u8, value.request_identifier, expected.app.request_identifier) or
        !std.mem.eql(u8, value.host_id, expected.app.host_id) or
        !std.mem.eql(u8, value.runtime_id, expected.app.runtime_id) or
        value.event_id != expected.app.event_id or value.attached_at_ns != app_observed.attach_at_ns or
        value.connection_generation_before == 0 or
        value.connection_generation_after != value.connection_generation_before or
        value.host_pid_before == 0 or value.host_pid_before > std.math.maxInt(i32) or
        value.host_pid_after != value.host_pid_before or
        value.child_pid_before == 0 or value.child_pid_before > std.math.maxInt(i32) or
        value.child_pid_after != value.child_pid_before or
        !std.mem.eql(u8, value.before_marker, expected.before_marker) or
        !std.mem.eql(u8, value.after_marker, expected.after_marker) or
        value.before_observed_at_ns <= app_observed.callback_at_ns or
        value.before_observed_at_ns >= value.attached_at_ns or
        value.input_sent_at_ns <= value.attached_at_ns or
        value.after_observed_at_ns <= value.input_sent_at_ns or
        value.after_observed_at_ns >= expected.app.deadline_ns)
        return error.EvidenceMismatch;

    var canonical_storage: [max_receipt_bytes]u8 = undefined;
    const canonical = std.fmt.bufPrint(&canonical_storage, "{{\"schema\":\"{s}\",\"scenario\":\"{s}\",\"request_identifier\":\"{s}\",\"host_id\":\"{s}\",\"runtime_id\":\"{s}\",\"event_id\":{d},\"attached_at_ns\":{d},\"connection_generation_before\":{d},\"connection_generation_after\":{d},\"host_pid_before\":{d},\"host_pid_after\":{d},\"child_pid_before\":{d},\"child_pid_after\":{d},\"before_marker\":\"{s}\",\"after_marker\":\"{s}\",\"before_observed_at_ns\":{d},\"input_sent_at_ns\":{d},\"after_observed_at_ns\":{d}}}", .{ schema, value.scenario, value.request_identifier, value.host_id, value.runtime_id, value.event_id, value.attached_at_ns, value.connection_generation_before, value.connection_generation_after, value.host_pid_before, value.host_pid_after, value.child_pid_before, value.child_pid_after, value.before_marker, value.after_marker, value.before_observed_at_ns, value.input_sent_at_ns, value.after_observed_at_ns }) catch return error.InvalidReceipt;
    if (!std.mem.eql(u8, bytes, canonical)) return error.NonCanonicalReceipt;
    return .{
        .connection_generation = value.connection_generation_before,
        .scenario = .{
            .host_id = expected.app.host_id,
            .runtime_id = expected.app.runtime_id,
            .event_id = expected.app.event_id,
            .request_identifier = expected.app.request_identifier,
            .visible_nonce = expected.visible_nonce,
            .daemon_pid_before = value.host_pid_before,
            .daemon_pid_after = value.host_pid_after,
            .child_pid_before = value.child_pid_before,
            .child_pid_after = value.child_pid_after,
            .submitted_at_ns = expected.submitted_at_ns,
            .delivered_at_ns = helper_observed.observed_at_ns,
            .clicked_at_ns = helper_observed.clicked_at_ns,
            .callback_at_ns = app_observed.callback_at_ns,
            .attached_at_ns = app_observed.attach_at_ns,
            .os_delivered = true,
            .actual_click = true,
            .exact_attach = true,
            .screen_before_preserved = true,
            .screen_after_writable = true,
        },
    };
}

fn validateExpected(expected: Expected) !void {
    try app_receipt.validateExpected(expected.app);
    try helper_receipt.validateExpected(.{
        .visible_nonce = expected.visible_nonce,
        .deadline_ns = expected.app.deadline_ns,
    });
    if (expected.app_receipt_bytes.len == 0 or expected.helper_receipt_bytes.len == 0 or
        expected.submitted_at_ns == 0 or
        !scalar(expected.before_marker) or !scalar(expected.after_marker) or
        std.mem.eql(u8, expected.before_marker, expected.after_marker)) return error.InvalidExpected;
    const suffix = switch (expected.app.scenario) {
        .gui_zero => "-gui-zero",
        .gui_live_then_quit => "-gui-live-then-quit",
    };
    if (!std.mem.endsWith(u8, expected.visible_nonce, suffix)) return error.InvalidExpected;
}

fn scalar(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}
