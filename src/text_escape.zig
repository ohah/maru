//! 라인 기반 텍스트 포맷의 따옴표 문자열 escape 단일 출처. maru.workspace.v2·maru.trace.v1·snapshot이 cwd/title/
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

/// writeEscaped의 **역연산** — escape된 값을 원문으로 되돌려 w에 쓴다(reader가 쓴다). `\\`→`\`, `\"`→`"`,
/// `\n`→개행, `\r`→CR, `\t`→Tab. writer가 내는 5종만 실제로 나오지만, 알 수 없는 escape(`\x`)는 그 문자를
/// 그대로 두고(backslash 무시) 끝의 고립된 `\`는 버려, 손상 입력에서도 crash 없이 관대하게 처리한다.
pub fn writeUnescaped(w: *std.Io.Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\') {
            try w.writeByte(s[i]);
            continue;
        }
        if (i + 1 >= s.len) break; // 끝의 고립 '\' — 버린다
        i += 1;
        try w.writeByte(switch (s[i]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => s[i], // '\\'·'"'·그 외는 그 문자 그대로(backslash만 제거)
        });
    }
}

/// writeUnescaped를 새 버퍼로 반환한다(호출자 소유). reader가 따옴표 값(cwd 등)을 원문으로 복원할 때 쓴다.
/// allocating writer라 유일한 실패는 OOM — Writer의 WriteFailed를 OutOfMemory로 좁혀 호출자 error set을 단순화한다.
pub fn unescapeAlloc(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    writeUnescaped(&out.writer, s) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

test "writeEscaped: 특수문자만 escape, 나머지는 그대로" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeEscaped(&w, "a\\b\"c\nd\re\tf g");
    try std.testing.expectEqualStrings("a\\\\b\\\"c\\nd\\re\\tf g", w.buffered());
}

test "writeUnescaped: escape 역연산, writeEscaped와 round-trip" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeUnescaped(&w, "a\\\\b\\\"c\\nd\\re\\tf g");
    try std.testing.expectEqualStrings("a\\b\"c\nd\re\tf g", w.buffered());

    // round-trip: 임의 값을 escape→unescape하면 원문.
    const original = "path/with space \"q\" \\slash\n\ttab";
    var eb: [128]u8 = undefined;
    var ew = std.Io.Writer.fixed(&eb);
    try writeEscaped(&ew, original);
    const escaped = try std.testing.allocator.dupe(u8, ew.buffered());
    defer std.testing.allocator.free(escaped);
    const back = try unescapeAlloc(std.testing.allocator, escaped);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(original, back);

    // 관대성: 끝의 고립 '\'·알 수 없는 escape는 crash 없이 처리(손상 입력).
    var db: [32]u8 = undefined;
    var dw = std.Io.Writer.fixed(&db);
    try writeUnescaped(&dw, "ok\\");
    try std.testing.expectEqualStrings("ok", dw.buffered());
    var db2: [32]u8 = undefined;
    var dw2 = std.Io.Writer.fixed(&db2);
    try writeUnescaped(&dw2, "a\\xb");
    try std.testing.expectEqualStrings("axb", dw2.buffered());
}
