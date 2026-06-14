//! 라인 기반 텍스트 포맷의 따옴표 문자열 escape 단일 출처. maru.workspace.v1·maru.trace.v1·snapshot이 cwd/title/
//! command/codepoint 같은 값을 한 줄·한 토큰으로 안전하게 보관하려고 같은 규칙을 쓴다(`\` `"`·개행/CR/Tab → `\\`
//! `\"` `\n` `\r` `\t`, 나머지는 그대로). 각 파일에 복제돼 있던 걸 여기로 모아, 규칙이 한 곳에서만 정의되게 한다
//! (한 reader/writer만 고치고 다른 포맷이 조용히 갈라지는 drift 방지). reader는 같은 규칙으로 unescape한다.
//!
//! 경계: app·observability 어느 facade에도 속하지 않는 중립 leaf다(둘 다 상대 import). 새 escape 케이스(예: `\0`)가
//! 필요하면 여기 한 곳만 고친다.

const std = @import("std");

/// 따옴표로 감싼 값 안의 특수문자를 escape해 w에 쓴다.
pub fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |b| switch (b) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(b),
    };
}

test "writeEscaped: 특수문자만 escape, 나머지는 그대로" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeEscaped(&w, "a\\b\"c\nd\re\tf g");
    try std.testing.expectEqualStrings("a\\\\b\\\"c\\nd\\re\\tf g", w.buffered());
}
