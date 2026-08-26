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
