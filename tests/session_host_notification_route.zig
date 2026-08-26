const std = @import("std");

const c = @cImport({
    @cInclude("session_host_notification_route.h");
});

test "P4 N2b3 canonical notification route identifier matches daemon and GUI contract" {
    var out: [c.MARU_SESSION_HOST_NOTIFICATION_IDENTIFIER_CAP]u8 = undefined;
    const len = c.maru_session_host_notification_format_identifier(
        0x0011223344556677,
        0x8899aabbccddeeff,
        0xfedcba9876543210,
        0x0123456789abcdef,
        18446744073709551615,
        @ptrCast(&out),
        out.len,
    );
    try std.testing.expectEqualStrings(
        "maru-00112233445566778899aabbccddeeff-fedcba98765432100123456789abcdef-18446744073709551615",
        out[0..len],
    );
}

test "P4 N2b3 canonical notification route identifier fails closed on short or null output" {
    var short: [8]u8 = [_]u8{'x'} ** 8;
    try std.testing.expectEqual(@as(usize, 0), c.maru_session_host_notification_format_identifier(1, 2, 3, 4, 5, @ptrCast(&short), short.len));
    try std.testing.expectEqual(@as(u8, 0), short[0]);
    try std.testing.expectEqual(@as(usize, 0), c.maru_session_host_notification_format_identifier(1, 2, 3, 4, 5, null, 0));
}

test "P4 N3 persisted notification route decoder rejects malformed incoherent and overflow input" {
    const hid = "00112233445566778899aabbccddeeff";
    const rid = "fedcba98765432100123456789abcdef";
    const eid = "18446744073709551615";
    const identifier = "maru-00112233445566778899aabbccddeeff-fedcba98765432100123456789abcdef-18446744073709551615";
    var hid_hi: u64 = 0;
    var hid_lo: u64 = 0;
    var rid_hi: u64 = 0;
    var rid_lo: u64 = 0;
    var event_id: u64 = 0;
    try std.testing.expectEqual(@as(c_int, 1), c.maru_session_host_notification_parse_route(
        hid.ptr,
        hid.len,
        rid.ptr,
        rid.len,
        eid.ptr,
        eid.len,
        identifier.ptr,
        identifier.len,
        &hid_hi,
        &hid_lo,
        &rid_hi,
        &rid_lo,
        &event_id,
    ));
    try std.testing.expectEqual(@as(u64, 0x0011223344556677), hid_hi);
    try std.testing.expectEqual(@as(u64, 0x8899aabbccddeeff), hid_lo);
    try std.testing.expectEqual(@as(u64, 0xfedcba9876543210), rid_hi);
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), rid_lo);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), event_id);

    const Case = struct { hid: []const u8, rid: []const u8, eid: []const u8, identifier: []const u8 };
    for ([_]Case{
        .{ .hid = "00112233445566778899aabbccddee", .rid = rid, .eid = eid, .identifier = identifier },
        .{ .hid = "00112233445566778899AABBCCDDEEFF", .rid = rid, .eid = eid, .identifier = identifier },
        .{ .hid = "00000000000000000000000000000000", .rid = rid, .eid = eid, .identifier = identifier },
        .{ .hid = hid, .rid = "00000000000000000000000000000000", .eid = eid, .identifier = identifier },
        .{ .hid = hid, .rid = rid, .eid = "0", .identifier = identifier },
        .{ .hid = hid, .rid = rid, .eid = "01", .identifier = identifier },
        .{ .hid = hid, .rid = rid, .eid = "18446744073709551616", .identifier = identifier },
        .{ .hid = hid, .rid = rid, .eid = "1.0", .identifier = identifier },
        .{ .hid = hid, .rid = rid, .eid = eid, .identifier = "maru-incoherent" },
    }) |case| try std.testing.expectEqual(@as(c_int, 0), c.maru_session_host_notification_parse_route(
        case.hid.ptr,
        case.hid.len,
        case.rid.ptr,
        case.rid.len,
        case.eid.ptr,
        case.eid.len,
        case.identifier.ptr,
        case.identifier.len,
        &hid_hi,
        &hid_lo,
        &rid_hi,
        &rid_lo,
        &event_id,
    ));
}
