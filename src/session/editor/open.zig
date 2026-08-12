//! 읽어 온 파일 bytes를 **화면에 그릴 수 있는 상태**로 만든다 — N1의 "화면에 파일이 뜬다"에서
//! 문서 쪽 절반이다([native-editor-document-model.md](../../../docs/native-editor-document-model.md) §3.5).
//!
//! **파일을 직접 읽지 않는다.** L2는 OS를 모르므로(§2 레이어) 읽기는 platform이 하고 여기는 bytes를
//! 받는다 — `document.open`이 이미 그 형태이고, 이 모듈은 거기에 **논리행 인덱스**를 묶어 뷰가
//! 필요로 하는 것을 한 번에 준다.
//!
//! **왜 묶는 자리가 필요한가**: `document`는 인코딩·줄바꿈만 알고 `line_index`는 offset만 안다.
//! 화면을 그리려면 둘이 함께 필요한데(줄을 잘라 넘기려면 인덱스가, BOM 보정에는 문서가), 호출자마다
//! 둘을 각각 만들면 **BOM을 뺀 content로 인덱스를 세워야 한다**는 규칙이 여러 곳에 복제된다.

const std = @import("std");
const document = @import("document.zig");
const line_index = @import("line_index.zig");

pub const OpenError = document.OpenError || std.mem.Allocator.Error;

/// 열린 파일 하나. **bytes를 복사하지 않는다** — 호출자가 준 버퍼를 문서가 빌려 쓰므로, 이 값이
/// 사는 동안 그 버퍼가 살아 있어야 한다.
pub const OpenFile = struct {
    doc: document.Document,
    lines: line_index.LineIndex,

    pub fn deinit(self: *OpenFile) void {
        self.lines.deinit();
    }

    pub fn lineCount(self: OpenFile) usize {
        return self.lines.lineCount();
    }

    /// 화면에 그릴 줄 하나의 **내용**(줄바꿈 제외). 범위를 넘으면 `null`.
    ///
    /// `content.Row.bytes`가 바로 이것을 받는다 — 줄바꿈이 들어가면 렌더가 제어 문자를 만나고,
    /// §3.8의 가시화가 그것을 `<U+000A>`로 그려 화면이 어지러워진다.
    pub fn lineText(self: OpenFile, index: usize) ?[]const u8 {
        const l = self.lines.line(index) orelse return null;
        return self.doc.content[l.start..l.contentEnd()];
    }
};

/// bytes를 문서로 해석하고 논리행 인덱스를 세운다.
///
/// **인덱스는 `doc.content` 기준이다**(BOM을 뺀 뒤). 원본 bytes로 세우면 첫 줄이 BOM 3바이트만큼
/// 길어져 화면과 offset이 어긋난다 — `Document.fileOffset`이 그 보정을 맡는 것과 짝이다.
pub fn open(allocator: std.mem.Allocator, bytes: []const u8, read_only: bool) OpenError!OpenFile {
    const doc = try document.open(bytes, read_only);
    const lines = try line_index.build(allocator, doc.content);
    return .{ .doc = doc, .lines = lines };
}

const testing = std.testing;

test "줄 내용에 줄바꿈이 들어가지 않는다" {
    var f = try open(testing.allocator, "first\nsecond\r\nthird", false);
    defer f.deinit();

    try testing.expectEqual(@as(usize, 3), f.lineCount());
    try testing.expectEqualStrings("first", f.lineText(0).?);
    try testing.expectEqualStrings("second", f.lineText(1).?); // CRLF의 \r까지 빠진다
    try testing.expectEqualStrings("third", f.lineText(2).?);
    try testing.expect(f.lineText(3) == null);
}

test "BOM은 문서에서 빠지고 인덱스도 그 기준이다" {
    var f = try open(testing.allocator, document.utf8_bom ++ "line1\nline2", false);
    defer f.deinit();

    // 첫 줄이 BOM 3바이트만큼 길어지면 화면과 offset이 어긋난다.
    try testing.expectEqualStrings("line1", f.lineText(0).?);
    try testing.expect(f.doc.format.has_bom);
    // 파일 offset으로 되돌리면 BOM만큼 밀린다.
    try testing.expectEqual(@as(usize, 3), f.doc.fileOffset(0));
}

test "빈 파일도 열린다 — 한 줄짜리 빈 문서다" {
    var f = try open(testing.allocator, "", false);
    defer f.deinit();
    try testing.expectEqual(@as(usize, 1), f.lineCount());
    try testing.expectEqualStrings("", f.lineText(0).?);
}

test "UTF-8이 아니면 열지 않는다 — 다른 인코딩을 추측하지 않는다" {
    try testing.expectError(error.NotUtf8, open(testing.allocator, "\xff\xfe bad", false));
}

test "읽기 전용 여부는 호출자가 정한 대로 실린다" {
    var ro = try open(testing.allocator, "x", true);
    defer ro.deinit();
    try testing.expect(ro.doc.read_only);

    var rw = try open(testing.allocator, "x", false);
    defer rw.deinit();
    try testing.expect(!rw.doc.read_only);
}

test "줄바꿈 형식이 보존된다 — 저장할 때 원본을 지키기 위해" {
    var crlf = try open(testing.allocator, "a\r\nb\r\n", false);
    defer crlf.deinit();
    try testing.expectEqual(line_index.LineEnding.crlf, crlf.doc.format.dominant_ending);
    try testing.expect(crlf.doc.format.ends_with_newline);
    try testing.expect(!crlf.doc.format.mixed_endings);

    var mixed = try open(testing.allocator, "a\r\nb\nc", false);
    defer mixed.deinit();
    try testing.expect(mixed.doc.format.mixed_endings); // 섞였다는 사실을 남긴다
    try testing.expect(!mixed.doc.format.ends_with_newline);
}

test "적대적 입력도 열린다 — 화면에서 가시화하는 것이 §3.8의 몫이다" {
    // BiDi 제어 문자·ZWSP가 있어도 파일을 여는 것은 막지 않는다. 보이게 하는 것은 렌더의 일이다.
    var f = try open(testing.allocator, "if (level == \u{202E}admin) {\nconst a\u{200B}b = 1;", false);
    defer f.deinit();
    try testing.expectEqual(@as(usize, 2), f.lineCount());
    try testing.expect(std.mem.indexOf(u8, f.lineText(0).?, "\u{202E}") != null);
}
