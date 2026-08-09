//! 파일을 문서로 여는 계약 — **원문을 바꾸지 않는다**([native-editor.md](../../../docs/native-editor.md) §3.5).
//!
//! 편집기가 파일을 열었다 저장하기만 해도 내용이 달라지면 diff가 통째로 물들고 사용자는 자기가
//! 무엇을 바꿨는지 알 수 없게 된다. 그래서 이 모듈은 **무엇을 보존해야 하는지를 값으로 만든다** —
//! BOM 유무, 파일이 쓰던 줄바꿈, 파일 끝 개행 유무. 저장 경로가 이 값들을 되돌린다.
//!
//! **파일을 읽지 않는다.** 이 모듈은 이미 읽은 bytes를 해석할 뿐이다(L2는 filesystem을 모른다) —
//! 실제 읽기·쓰기는 [editor-surface.md](../../../docs/editor-surface.md)의 저장 계약이 소유한다.

const std = @import("std");
const line_index = @import("line_index.zig");

/// UTF-8 BOM. 내용의 일부가 아니라 **파일 속성**으로 다룬다(§3.5) — 문서 offset 0은 BOM 뒤다.
pub const utf8_bom = "\xEF\xBB\xBF";

/// 저장할 때 되돌려야 하는 파일 속성들.
pub const FileFormat = struct {
    /// BOM이 있었는가. 있으면 저장 시 다시 붙인다.
    has_bom: bool,
    /// 이 파일이 쓰던 줄바꿈. **새로 삽입되는 줄에만** 쓴다 — 기존 줄의 줄바꿈은 건드리지 않는다(§3.5).
    dominant_ending: line_index.LineEnding,
    /// 파일이 개행으로 끝났는가. **임의로 더하거나 지우지 않는다**(§3.5).
    ends_with_newline: bool,
    /// 줄바꿈이 섞여 있었는가. 저장 시 정규화 유혹을 막기 위해 사실로 남긴다 — 섞인 파일을 한 쪽으로
    /// 통일하면 안 건드린 줄까지 diff에 뜬다.
    mixed_endings: bool,
};

/// 왜 열 수 없는지. **열지 못하는 이유는 하나뿐이다** — UTF-8이 아닌 것(§3.5).
///
/// 권한 없음은 여기 없다. 쓸 수 없는 파일은 **읽기 전용으로 연다**(보는 것은 되어야 한다).
pub const OpenError = error{
    /// UTF-8 디코드 실패. 다른 인코딩을 추측해 변환하지 않는다 — 잘못 추측하면 저장 시 파일이 깨진다.
    NotUtf8,
};

/// 연 문서. `content`는 **BOM을 뺀** bytes이며 입력 버퍼를 빌려 쓴다(복사하지 않는다).
pub const Document = struct {
    content: []const u8,
    format: FileFormat,
    /// 쓸 수 없는 파일인가. 편집 연산을 막는 근거이며, **여는 것 자체는 막지 않는다**(§3.5).
    read_only: bool,

    /// 문서 offset을 파일 offset으로 옮긴다. BOM이 있으면 그만큼 밀린다.
    pub fn fileOffset(self: Document, doc_offset: usize) usize {
        return doc_offset + if (self.format.has_bom) utf8_bom.len else 0;
    }
};

/// 이미 읽은 bytes를 문서로 해석한다.
///
/// `read_only`는 호출자가 판정해 넘긴다 — 권한 조회는 filesystem 일이고 이 모듈은 그것을 모른다.
pub fn open(bytes: []const u8, read_only: bool) OpenError!Document {
    // **UTF-8 검사가 먼저다.** 줄바꿈을 세기 전에 해야 잘못된 bytes에서 나온 통계를 쓰지 않는다.
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.NotUtf8;

    const has_bom = std.mem.startsWith(u8, bytes, utf8_bom);
    const content = if (has_bom) bytes[utf8_bom.len..] else bytes;

    var lf: usize = 0;
    var crlf: usize = 0;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] != '\n') continue;
        if (i > 0 and content[i - 1] == '\r') crlf += 1 else lf += 1;
    }

    return .{
        .content = content,
        .format = .{
            .has_bom = has_bom,
            // **다수 쪽을 파일의 것으로 본다**(§3.5). 동수이거나 줄바꿈이 아예 없으면 LF로 둔다 —
            // 새 줄에만 쓰이는 값이라 보수적인 기본값이 안전하다.
            .dominant_ending = if (crlf > lf) .crlf else .lf,
            .ends_with_newline = content.len > 0 and content[content.len - 1] == '\n',
            .mixed_endings = lf > 0 and crlf > 0,
        },
        .read_only = read_only,
    };
}

const testing = std.testing;

test "빈 파일도 열린다" {
    const doc = try open("", false);
    try testing.expectEqual(@as(usize, 0), doc.content.len);
    try testing.expect(!doc.format.has_bom);
    try testing.expect(!doc.format.ends_with_newline);
}

test "UTF-8이 아니면 열지 않는다 — 추측해서 변환하지 않는다" {
    // 0xFF는 UTF-8에 나올 수 없는 byte다(Latin-1 등 다른 인코딩).
    try testing.expectError(error.NotUtf8, open("hello\xFFworld", false));
}

test "잘린 다중 byte 시퀀스도 거부한다" {
    // "가"의 첫 두 byte만 있다 — 파일이 잘렸거나 다른 인코딩이다.
    try testing.expectError(error.NotUtf8, open("\xEA\xB0", false));
}

test "BOM은 내용에서 빠지고 속성으로 기억된다 — offset 0은 BOM 뒤다" {
    const doc = try open(utf8_bom ++ "hello", false);

    try testing.expect(doc.format.has_bom);
    try testing.expectEqualStrings("hello", doc.content);
    // 문서 offset 0은 파일 offset 3이다.
    try testing.expectEqual(@as(usize, 3), doc.fileOffset(0));
    try testing.expectEqual(@as(usize, 5), doc.fileOffset(2));
}

test "BOM이 없으면 offset이 그대로다" {
    const doc = try open("hello", false);
    try testing.expectEqual(@as(usize, 0), doc.fileOffset(0));
}

test "BOM만 있는 파일" {
    const doc = try open(utf8_bom, false);
    try testing.expect(doc.format.has_bom);
    try testing.expectEqual(@as(usize, 0), doc.content.len);
}

test "LF 파일" {
    const doc = try open("a\nb\n", false);
    try testing.expectEqual(line_index.LineEnding.lf, doc.format.dominant_ending);
    try testing.expect(!doc.format.mixed_endings);
    try testing.expect(doc.format.ends_with_newline);
}

test "CRLF 파일 — 한 줄만 고쳐도 전 줄이 바뀌면 diff가 물든다" {
    const doc = try open("a\r\nb\r\n", false);
    try testing.expectEqual(line_index.LineEnding.crlf, doc.format.dominant_ending);
    try testing.expect(!doc.format.mixed_endings);
}

test "혼재 파일은 다수 쪽을 따르고 섞였다는 사실을 남긴다" {
    // CRLF 둘, LF 하나.
    const doc = try open("a\r\nb\r\nc\nd", false);
    try testing.expectEqual(line_index.LineEnding.crlf, doc.format.dominant_ending);
    try testing.expect(doc.format.mixed_endings);
}

test "동수면 LF로 둔다 — 새 줄에만 쓰이므로 보수적 기본값이 안전하다" {
    const doc = try open("a\r\nb\n", false);
    try testing.expectEqual(line_index.LineEnding.lf, doc.format.dominant_ending);
    try testing.expect(doc.format.mixed_endings);
}

test "파일 끝 개행 유무를 그대로 기억한다" {
    const with = try open("a\n", false);
    const without = try open("a", false);

    try testing.expect(with.format.ends_with_newline);
    try testing.expect(!without.format.ends_with_newline);
}

test "쓸 수 없는 파일도 열린다 — 보는 것은 되어야 한다" {
    const doc = try open("secret", true);
    try testing.expect(doc.read_only);
    try testing.expectEqualStrings("secret", doc.content);
}

test "BOM과 CRLF가 함께 있는 파일(Windows 관례)" {
    const doc = try open(utf8_bom ++ "a\r\nb\r\n", false);

    try testing.expect(doc.format.has_bom);
    try testing.expectEqual(line_index.LineEnding.crlf, doc.format.dominant_ending);
    try testing.expect(doc.format.ends_with_newline);
    try testing.expectEqualStrings("a\r\nb\r\n", doc.content);
}

test "BOM을 뗀 내용이 줄 인덱스와 맞물린다" {
    const doc = try open(utf8_bom ++ "a\nb", false);
    var idx = try line_index.build(testing.allocator, doc.content);
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 2), idx.lineCount());
    // 줄 인덱스의 offset은 **문서 기준**이라 BOM을 세지 않는다.
    try testing.expectEqual(@as(usize, 0), idx.line(0).?.start);
    try testing.expectEqual(@as(usize, 2), idx.line(1).?.start);
}
