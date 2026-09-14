//! CR6d-v2a의 두 제품 PPM이 같은 복구 surface의 실제 preedit 변화를 증명하는지 검증한다.

const std = @import("std");
const subject = @import("support/session_host_cr6d_pixel.zig");

const black = "\x00\x00\x00";
const white = "\xff\xff\xff";

fn capture(ppm: []const u8, generation: u64) subject.Capture {
    return .{
        .runtime_id = "0123456789abcdef0123456789abcdef",
        .surface_id = 7,
        .frame_generation = generation,
        .cursor = .{ .x = 1, .y = 0, .w = 1, .h = 1 },
        .cursor_screen = .{ .x = 101, .y = 200, .w = 10, .h = 20 },
        .first_rect = .{ .x = 101, .y = 200, .w = 10, .h = 20 },
        .ppm = ppm,
    };
}

test "CR6d-v2a accepts a same-surface marked pixel beginning in the cursor cell" {
    const before = "P6\n4 2\n255\n" ++ black ** 8;
    const marked = "P6\n4 2\n255\n" ++ black ++ white ** 2 ++ black ** 5;
    const result = try subject.validate(std.testing.allocator, capture(before, 10), capture(marked, 11));
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", &result.runtime_id);
    try std.testing.expectEqual(@as(u64, 7), result.surface_id);
    try std.testing.expectEqual(@as(u64, 10), result.before_generation);
    try std.testing.expectEqual(@as(u64, 11), result.marked_generation);
    try std.testing.expect(!std.mem.eql(u8, &result.before_digest, &result.marked_digest));
    try std.testing.expectEqual(@as(usize, 2), result.changed_pixels);
    try std.testing.expectEqual(subject.Rect{ .x = 1, .y = 0, .w = 2, .h = 1 }, result.changed_bounds);
}

test "CR6d-v2a rejects identity generation anchor and off-interest substitutions" {
    const before = "P6\n4 2\n255\n" ++ black ** 8;
    const in_cell = "P6\n4 2\n255\n" ++ black ++ white ++ black ** 6;
    const outside = "P6\n4 2\n255\n" ++ black ** 3 ++ white ++ black ** 4;

    var foreign = capture(in_cell, 11);
    foreign.surface_id = 8;
    try std.testing.expectError(error.IdentityMismatch, subject.validate(std.testing.allocator, capture(before, 10), foreign));
    try std.testing.expectError(error.GenerationMismatch, subject.validate(std.testing.allocator, capture(before, 10), capture(in_cell, 10)));

    var wrong_anchor = capture(in_cell, 11);
    wrong_anchor.first_rect.x += 1;
    try std.testing.expectError(error.AnchorMismatch, subject.validate(std.testing.allocator, capture(before, 10), wrong_anchor));
    try std.testing.expectError(error.PixelOutsideInterest, subject.validate(std.testing.allocator, capture(before, 10), capture(outside, 11)));
}

test "CR6d-v2a rejects missing pixels malformed captures and oversized identities" {
    const before = "P6\n4 2\n255\n" ++ black ** 8;
    const same = capture(before, 11);
    try std.testing.expectError(error.NoMarkedPixelChange, subject.validate(std.testing.allocator, capture(before, 10), same));

    var malformed = capture("P3\n1 1\n255\n\x00\x00\x00", 11);
    try std.testing.expectError(error.InvalidCapture, subject.validate(std.testing.allocator, capture(before, 10), malformed));
    malformed = capture(before ++ "hidden", 11);
    try std.testing.expectError(error.InvalidCapture, subject.validate(std.testing.allocator, capture(before, 10), malformed));
    malformed = capture(before, 11);
    malformed.runtime_id = "0123456789abcdef0123456789abcdefx";
    try std.testing.expectError(error.InvalidIdentity, subject.validate(std.testing.allocator, capture(before, 10), malformed));
    malformed.runtime_id = "00000000000000000000000000000000";
    try std.testing.expectError(error.InvalidIdentity, subject.validate(std.testing.allocator, capture(before, 10), malformed));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    const before = "P6\n4 2\n255\n" ++ black ** 8;
    const marked = "P6\n4 2\n255\n" ++ black ++ white ** 2 ++ black ** 5;
    _ = try subject.validate(allocator, capture(before, 10), capture(marked, 11));
}

test "CR6d-v2a allocation failure never publishes a partial verdict" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
