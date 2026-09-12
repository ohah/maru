//! Strict receipt boundary for the separately signed Notification Center Accessibility helper.

const std = @import("std");

pub const schema = "maru.session-host-notification-center-helper.v1";
pub const max_receipt_bytes: usize = 512;

pub const Error = error{
    InvalidExpected,
    ReceiptTooLarge,
    InvalidReceipt,
    NonCanonicalReceipt,
    IdentityMismatch,
    InvalidTimeline,
} || std.mem.Allocator.Error;

pub const Expected = struct {
    visible_nonce: []const u8,
    deadline_ns: u64,
};

pub const Observed = struct {
    observed_at_ns: u64,
    clicked_at_ns: u64,
};

const Wire = struct {
    schema: []const u8,
    result: []const u8,
    visible_nonce: []const u8,
    observed_at_ns: u64,
    clicked_at_ns: u64,
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
        !std.mem.eql(u8, value.result, "clicked") or
        !std.mem.eql(u8, value.visible_nonce, expected.visible_nonce))
        return error.IdentityMismatch;
    if (value.observed_at_ns == 0 or value.clicked_at_ns <= value.observed_at_ns or
        value.clicked_at_ns >= expected.deadline_ns)
        return error.InvalidTimeline;

    var canonical_storage: [max_receipt_bytes]u8 = undefined;
    const canonical = std.fmt.bufPrint(
        &canonical_storage,
        "{{\"schema\":\"{s}\",\"result\":\"clicked\",\"visible_nonce\":\"{s}\",\"observed_at_ns\":{d},\"clicked_at_ns\":{d}}}\n",
        .{ schema, expected.visible_nonce, value.observed_at_ns, value.clicked_at_ns },
    ) catch return error.InvalidReceipt;
    if (!std.mem.eql(u8, bytes, canonical)) return error.NonCanonicalReceipt;
    return .{ .observed_at_ns = value.observed_at_ns, .clicked_at_ns = value.clicked_at_ns };
}

pub fn validateExpected(expected: Expected) Error!void {
    if (!canonicalVisibleNonce(expected.visible_nonce) or expected.deadline_ns == 0) return error.InvalidExpected;
}

fn canonicalVisibleNonce(value: []const u8) bool {
    const zero_suffix = "-gui-zero";
    const live_suffix = "-gui-live-then-quit";
    const uuid = if (std.mem.endsWith(u8, value, zero_suffix))
        value[0 .. value.len - zero_suffix.len]
    else if (std.mem.endsWith(u8, value, live_suffix))
        value[0 .. value.len - live_suffix.len]
    else
        return false;
    if (uuid.len != 36 or uuid[8] != '-' or uuid[13] != '-' or uuid[18] != '-' or uuid[23] != '-' or
        uuid[14] != '4' or (uuid[19] != '8' and uuid[19] != '9' and uuid[19] != 'a' and uuid[19] != 'b')) return false;
    for (uuid, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) continue;
        if (!std.ascii.isHex(byte) or std.ascii.toLower(byte) != byte) return false;
    }
    return true;
}
