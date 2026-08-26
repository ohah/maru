//! P4 N2a notification presentation/admission contract. This gate is intentionally written before
//! the product implementation: untrusted PTY bytes must become bounded display text before the
//! RuntimeManager can put them in the host journal.

const std = @import("std");
const admission = @import("notification_admission");

test "P4 N2a notification sanitizer is UTF-8 safe and role-aware" {
    const allocator = std.testing.allocator;
    const title = try admission.sanitizeOwned(
        allocator,
        " build\x1b[31m\n done\xc2\x9b2K\xff ",
        .single_line,
        64,
    );
    defer allocator.free(title);
    try std.testing.expectEqualStrings("build done\xef\xbf\xbd", title);
    try std.testing.expect(std.unicode.utf8ValidateSlice(title));

    const body = try admission.sanitizeOwned(allocator, "one\r\ntwo\x00\x07\ncaf\xc3\xa9", .multi_line, 64);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("one\ntwo\ncaf\xc3\xa9", body);
    try std.testing.expect(std.unicode.utf8ValidateSlice(body));
}

test "P4 N2a notification sanitizer removes terminal string controls as one unit" {
    const allocator = std.testing.allocator;
    const body = try admission.sanitizeOwned(
        allocator,
        "safe\x1b]0;spoof\x07 body\x1bPsecret\x1b\\ end\x1b]unterminated",
        .multi_line,
        64,
    );
    defer allocator.free(body);
    try std.testing.expectEqualStrings("safe body end", body);
}

test "P4 N2a notification sanitizer applies cap after normalization without partial output" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.NormalizedTooLarge,
        admission.sanitizeOwned(allocator, "a\xff", .single_line, 3),
    );
    const exact = try admission.sanitizeOwned(allocator, "a\xff", .single_line, 4);
    defer allocator.free(exact);
    try std.testing.expectEqualStrings("a\xef\xbf\xbd", exact);
}

test "P4 N2a notification sanitizer gives an empty title the stable Maru fallback before journal admission" {
    try std.testing.expectEqualStrings("Maru", admission.titleOrFallback(""));
    try std.testing.expectEqualStrings("Deploy", admission.titleOrFallback("Deploy"));
}
