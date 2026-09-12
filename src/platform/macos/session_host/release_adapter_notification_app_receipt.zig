//! Final-address parser and publisher for one app-owned Notification Center receipt.
//!
//! The app writes one bounded JSON document as the first inherited-socket frame. This leaf accepts only the
//! app's canonical byte rendering, binds it back to runner-owned identity and helper click time,
//! and delegates durable publication to the existing exclusive 0600 file boundary.

const std = @import("std");
const files = @import("release_adapter_files");

pub const schema = "maru.session-host-notification-app-receipt.v1";
pub const max_receipt_bytes: usize = 1024;

pub const Error = error{
    InvalidExpected,
    ReceiptTooLarge,
    InvalidReceipt,
    NonCanonicalReceipt,
    IdentityMismatch,
    InvalidTimeline,
    AttachKindMismatch,
} || std.mem.Allocator.Error || files.Error;

pub const Scenario = enum {
    gui_zero,
    gui_live_then_quit,

    pub fn wire(self: @This()) []const u8 {
        return switch (self) {
            .gui_zero => "gui-zero",
            .gui_live_then_quit => "gui-live-then-quit",
        };
    }

    fn requiredAttach(self: @This()) AttachKind {
        return switch (self) {
            .gui_zero => .recovered,
            .gui_live_then_quit => .bound,
        };
    }
};

pub const AttachKind = enum {
    bound,
    recovered,

    pub fn wire(self: @This()) []const u8 {
        return switch (self) {
            .bound => "bound",
            .recovered => "recovered",
        };
    }
};

pub const Expected = struct {
    scenario: Scenario,
    request_identifier: []const u8,
    host_id: []const u8,
    runtime_id: []const u8,
    event_id: u64,
    clicked_at_ns: u64,
    deadline_ns: u64,
};

pub const Observed = struct {
    callback_at_ns: u64,
    attach_at_ns: u64,
    attach_kind: AttachKind,
};

const Wire = struct {
    schema: []const u8,
    scenario: []const u8,
    request_identifier: []const u8,
    host_id: []const u8,
    runtime_id: []const u8,
    event_id: u64,
    callback_at_ns: u64,
    attach_at_ns: u64,
    attach_kind: []const u8,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, expected: Expected) Error!Observed {
    if (bytes.len == 0 or bytes.len > max_receipt_bytes) return error.ReceiptTooLarge;
    try validateExpected(expected);

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
        !std.mem.eql(u8, value.scenario, expected.scenario.wire()) or
        !std.mem.eql(u8, value.request_identifier, expected.request_identifier) or
        !std.mem.eql(u8, value.host_id, expected.host_id) or
        !std.mem.eql(u8, value.runtime_id, expected.runtime_id) or
        value.event_id != expected.event_id)
        return error.IdentityMismatch;

    const attach_kind: AttachKind = if (std.mem.eql(u8, value.attach_kind, "bound"))
        .bound
    else if (std.mem.eql(u8, value.attach_kind, "recovered"))
        .recovered
    else
        return error.InvalidReceipt;
    if (attach_kind != expected.scenario.requiredAttach()) return error.AttachKindMismatch;
    if (value.callback_at_ns <= expected.clicked_at_ns or
        value.attach_at_ns <= value.callback_at_ns or
        value.attach_at_ns >= expected.deadline_ns)
        return error.InvalidTimeline;

    var canonical_storage: [max_receipt_bytes]u8 = undefined;
    const canonical = std.fmt.bufPrint(
        &canonical_storage,
        "{{\"schema\":\"{s}\",\"scenario\":\"{s}\",\"request_identifier\":\"{s}\",\"host_id\":\"{s}\",\"runtime_id\":\"{s}\",\"event_id\":{d},\"callback_at_ns\":{d},\"attach_at_ns\":{d},\"attach_kind\":\"{s}\"}}",
        .{
            schema,
            expected.scenario.wire(),
            expected.request_identifier,
            expected.host_id,
            expected.runtime_id,
            expected.event_id,
            value.callback_at_ns,
            value.attach_at_ns,
            attach_kind.wire(),
        },
    ) catch return error.InvalidReceipt;
    if (!std.mem.eql(u8, bytes, canonical)) return error.NonCanonicalReceipt;
    return .{
        .callback_at_ns = value.callback_at_ns,
        .attach_at_ns = value.attach_at_ns,
        .attach_kind = attach_kind,
    };
}

pub fn parseAndPublish(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: Expected,
    output_path: [:0]const u8,
) Error!Observed {
    var publisher = FilesystemPublisher{};
    return parseAndPublishInternal(&publisher, allocator, bytes, expected, output_path);
}

pub fn parseAndPublishWith(
    publisher: anytype,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: Expected,
    output_path: [:0]const u8,
) !Observed {
    if (!@import("builtin").is_test) @compileError("parseAndPublishWith is a test-only seam");
    return parseAndPublishInternal(publisher, allocator, bytes, expected, output_path);
}

fn parseAndPublishInternal(
    publisher: anytype,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: Expected,
    output_path: [:0]const u8,
) !Observed {
    const observed = try parse(allocator, bytes, expected);
    try publisher.publish(output_path, bytes);
    return observed;
}

const FilesystemPublisher = struct {
    fn publish(_: *@This(), output_path: [:0]const u8, bytes: []const u8) files.Error!void {
        try files.publishSummaryExclusive(output_path, bytes);
    }
};

pub fn validateExpected(expected: Expected) Error!void {
    if (!lowerHex(expected.host_id, 32) or !lowerHex(expected.runtime_id, 32) or
        allZero(expected.host_id) or allZero(expected.runtime_id) or
        expected.event_id == 0 or expected.clicked_at_ns == 0 or
        expected.deadline_ns <= expected.clicked_at_ns)
        return error.InvalidExpected;
    var request_storage: [128]u8 = undefined;
    const canonical_request = std.fmt.bufPrint(
        &request_storage,
        "maru-{s}-{s}-{d}",
        .{ expected.host_id, expected.runtime_id, expected.event_id },
    ) catch return error.InvalidExpected;
    if (!std.mem.eql(u8, expected.request_identifier, canonical_request)) return error.InvalidExpected;
}

fn allZero(value: []const u8) bool {
    for (value) |byte| if (byte != '0') return false;
    return true;
}

fn lowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
