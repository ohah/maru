//! Read an OS locale tag verbatim; i18n owns preference and language policy.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
extern "kernel32" fn GetUserDefaultLocaleName(buffer: [*]u16, capacity: c_int) callconv(abi.winapi) c_int;

/// Microsoft returns a UTF-16 count including NUL (zero means failure).
/// https://learn.microsoft.com/en-us/windows/win32/api/winnls/nf-winnls-getuserdefaultlocalename
pub fn decode(out: []u8, wide: []const u16, reported: c_int) ?[]const u8 {
    if (reported <= 0) return null;
    const n: usize = @intCast(reported);
    if (n > wide.len or wide[n - 1] != 0) return null;
    if (std.mem.indexOfScalar(u16, wide[0 .. n - 1], 0) != null) return null;
    // std.unicode's fixed-buffer converter assumes enough output space.
    // Validate UTF-16 and capacity before invoking it, including exact fits.
    var iterator = std.unicode.Utf16LeIterator.init(wide[0 .. n - 1]);
    var needed: usize = 0;
    while (iterator.nextCodepoint() catch return null) |cp| {
        const bytes = std.unicode.utf8CodepointSequenceLength(cp) catch return null;
        if (bytes > out.len - needed) return null;
        needed += bytes;
    }
    const used = std.unicode.utf16LeToUtf8(out, wide[0 .. n - 1]) catch return null;
    return out[0..used];
}
pub fn read(out: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    var wide: [85]u16 = undefined; // LOCALE_NAME_MAX_LENGTH, including NUL.
    const n = GetUserDefaultLocaleName(&wide, wide.len);
    return decode(out, &wide, n);
}
test "Windows locale converts the counted tag without its terminator" {
    var out: [255]u8 = undefined;
    try std.testing.expectEqualStrings("ko-KR", decode(&out, &.{ 'k', 'o', '-', 'K', 'R', 0 }, 6).?);
    try std.testing.expectEqualStrings("", decode(&out, &.{0}, 1).?);
}
test "Windows locale rejects failed negative and out of buffer counts" {
    var out: [255]u8 = undefined;
    try std.testing.expect(decode(&out, &.{0}, 0) == null);
    try std.testing.expect(decode(&out, &.{0}, -1) == null);
    try std.testing.expect(decode(&out, &.{0}, 2) == null);
}
test "Windows locale rejects missing embedded terminators and malformed UTF16" {
    var out: [255]u8 = undefined;
    try std.testing.expect(decode(&out, &.{ 'k', 'o' }, 2) == null);
    try std.testing.expect(decode(&out, &.{ 'k', 0, 'o', 0 }, 4) == null);
    try std.testing.expect(decode(&out, &.{ 0xd800, 0 }, 2) == null);
}
test "Windows locale preserves raw Unicode and reports output exhaustion" {
    var out: [255]u8 = undefined;
    try std.testing.expectEqualStrings("ko-X-\xed\x95\x9c", decode(&out, &.{ 'k', 'o', '-', 'X', '-', 0xd55c, 0 }, 7).?);
    try std.testing.expect(decode(out[0..2], &.{ 'k', 'o', '-', 'K', 'R', 0 }, 6) == null);
}
test "Windows locale adapter agrees with the actual native API" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var wide: [85]u16 = undefined;
    var expected: [255]u8 = undefined;
    var actual: [255]u8 = undefined;
    const n = GetUserDefaultLocaleName(&wide, wide.len);
    try std.testing.expect(n > 0);
    try std.testing.expectEqualStrings(decode(&expected, &wide, n).?, read(&actual).?);
}
