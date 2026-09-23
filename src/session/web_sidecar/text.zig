//! sidecar 가 보낼 글을 상한 안으로 줄이는 도구(W1a).

const std = @import("std");
const max_text_bytes = @import("wire.zig").max_text_bytes;

/// `text` 를 `max` 바이트 안의 가장 긴 UTF-8 접두로 자른다(글자 중간에서 자르지 않는다). sidecar 가 페이지
/// 제목처럼 길이를 통제할 수 없는 글을 `max_text_bytes` 로 줄일 때 쓴다. `text` 는 유효한 UTF-8 이어야 한다.
pub fn clampUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    // 이어지는 바이트(10xxxxxx) 위에서 끝나지 않게, 글자의 첫 바이트까지 물러난다.
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

test "clampUtf8 never splits a character" {
    try std.testing.expectEqualStrings("abc", clampUtf8("abc", 8));
    try std.testing.expectEqualStrings("가", clampUtf8("가나", 5)); // 한글은 3바이트 — 5 에서 자르면 둘째 글자 중간
    try std.testing.expectEqualStrings("가나", clampUtf8("가나", 6));
    try std.testing.expectEqualStrings("", clampUtf8("가", 2));
    const long = "제목" ** 1000;
    const clamped = clampUtf8(long, max_text_bytes);
    try std.testing.expect(clamped.len <= max_text_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clamped));
}
