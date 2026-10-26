//! Commit-message text admission, shared by legacy insertion and native ranges.
//! LF/TAB are meaningful; CR, other controls, DEL and malformed UTF-8 are skipped.
const std = @import("std");
pub fn sanitizeOwned(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, bytes.len);
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1;
            continue;
        };
        if (i + n > bytes.len) break;
        const cp = std.unicode.utf8Decode(bytes[i..][0..n]) catch {
            i += n;
            continue;
        };
        if (cp == '\n' or cp == '\t' or (cp >= 0x20 and cp != 0x7f)) out.appendSliceAssumeCapacity(bytes[i..][0..n]);
        i += n;
    }
    return out.toOwnedSlice(a);
}

test "scm commit IME model sanitation preserves LF TAB and verbatim NFD" {
    const a = std.testing.allocator;
    const text = try sanitizeOwned(a, "fix\r\n\t한\x1b\x00\x7f!");
    defer a.free(text);
    try std.testing.expectEqualStrings("fix\n\t한!", text);
}

test "scm commit IME model sanitation drops invalid bytes and truncated tail" {
    const a = std.testing.allocator;
    const text = try sanitizeOwned(a, "a\xffb\xed\xa0\x80c\xe2\x82");
    defer a.free(text);
    try std.testing.expectEqualStrings("abc", text);
}

test "scm commit IME model filtered payload remains empty" {
    const a = std.testing.allocator;
    const text = try sanitizeOwned(a, "\r\x1b\x7f");
    defer a.free(text);
    try std.testing.expectEqualStrings("", text);
}

test "scm commit IME model sanitation frees every failed allocation" {
    const Scenario = struct {
        fn run(a: std.mem.Allocator) !void {
            const text = try sanitizeOwned(a, "one\r\ntwo\t\x1b三");
            defer a.free(text);
            try std.testing.expectEqualStrings("one\ntwo\t三", text);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}
