//! 입력기의 UTF-16 위치 ↔ 편집기 문서의 UTF-8 byte 위치(native-editor.md §11).
//!
//! LSP 위치 변환은 오래된 서버 위치를 줄 끝에 묶지만, 입력기 범위는 곧 지울 글자를 정한다.
//! 그래서 범위 밖이나 글자 중간을 다른 위치로 보정하지 않고 거부한다. `NSNotFound` 같은 OS
//! 표현은 L4에서 optional로 바꾼다 — 이 모듈의 0은 실제 문서 시작이다.

const std = @import("std");

pub const Utf16Range = struct {
    location: u64,
    length: u64,
};

pub const ByteRange = struct {
    start: usize,
    end: usize,
};

/// 다음 scalar의 끝. 문서는 열 때 UTF-8을 검증하지만, 입력기에서 받은 새 조합도 같은 함수를
/// 타므로 잘린 sequence나 잘못된 continuation을 성공한 위치로 취급하지 않는다.
fn scalarEnd(bytes: []const u8, start: usize) ?usize {
    const len = std.unicode.utf8ByteSequenceLength(bytes[start]) catch return null;
    if (len > bytes.len - start) return null;
    const end = start + len;
    _ = std.unicode.utf8Decode(bytes[start..end]) catch return null;
    return end;
}

/// UTF-16 code unit 수. 잘못된 UTF-8이면 길이도 유효하지 않다.
pub fn utf16Length(bytes: []const u8) ?u64 {
    return utf16Offset(bytes, bytes.len);
}

/// UTF-16 위치를 byte 위치로 옮긴다. 서로게이트 쌍 중간은 문서의 scalar 경계가 아니므로 거부한다.
/// 위치까지의 UTF-8을 검사한다. 뒤쪽 내용은 문서를 연 경로의 검증을 따른다.
pub fn byteOffset(bytes: []const u8, offset: u64) ?usize {
    var byte: usize = 0;
    var units: u64 = 0;
    while (units < offset) {
        if (byte == bytes.len) return null;
        const end = scalarEnd(bytes, byte) orelse return null;
        // UTF-8의 4 byte scalar만 UTF-16에서 두 code unit을 차지한다.
        units += if (end - byte == 4) 2 else 1;
        byte = end;
    }
    return if (units == offset) byte else null;
}

/// byte 위치를 UTF-16 위치로 옮긴다. continuation byte 안으로 들어간 위치는 거부한다.
pub fn utf16Offset(bytes: []const u8, offset: usize) ?u64 {
    if (offset > bytes.len) return null;
    var byte: usize = 0;
    var units: u64 = 0;
    while (byte < offset) {
        const end = scalarEnd(bytes, byte) orelse return null;
        if (end > offset) return null;
        units += if (end - byte == 4) 2 else 1;
        byte = end;
    }
    return units;
}

/// 끝을 덧셈하기 전에 overflow를 검사한다. length를 별도로 바꾸므로 문서 앞부분을 두 번 훑지 않는다.
pub fn byteRange(bytes: []const u8, range: Utf16Range) ?ByteRange {
    _ = std.math.add(u64, range.location, range.length) catch return null;
    const start = byteOffset(bytes, range.location) orelse return null;
    const len = byteOffset(bytes[start..], range.length) orelse return null;
    return .{ .start = start, .end = start + len };
}

/// 선택 방향은 호출자가 소유한다. 여기서는 문서 순서로 정렬된 반열림 범위만 받는다.
pub fn utf16Range(bytes: []const u8, range: ByteRange) ?Utf16Range {
    if (range.start > range.end or range.end > bytes.len) return null;
    const location = utf16Offset(bytes, range.start) orelse return null;
    const length = utf16Length(bytes[range.start..range.end]) orelse return null;
    return .{ .location = location, .length = length };
}

const testing = std.testing;

test "ETI1 UTF16 positions count Hangul non-BMP NFD and line endings without changing document bytes" {
    const content = "A가😀e\u{0301}\r\nZ";
    const boundaries = [_]struct { byte: usize, units: u64 }{
        .{ .byte = 0, .units = 0 },
        .{ .byte = 1, .units = 1 },
        .{ .byte = 4, .units = 2 },
        .{ .byte = 8, .units = 4 },
        .{ .byte = 9, .units = 5 },
        .{ .byte = 11, .units = 6 },
        .{ .byte = 12, .units = 7 },
        .{ .byte = 13, .units = 8 },
        .{ .byte = 14, .units = 9 },
    };
    for (boundaries) |boundary| {
        try testing.expectEqual(@as(?usize, boundary.byte), byteOffset(content, boundary.units));
        try testing.expectEqual(@as(?u64, boundary.units), utf16Offset(content, boundary.byte));
    }
    try testing.expectEqual(@as(?u64, 9), utf16Length(content));
    try testing.expectEqual(@as(?u64, 0), utf16Length(""));
    try testing.expectEqual(@as(?usize, 0), byteOffset("", 0));
}

test "ETI2 UTF16 ranges replace whole scalars and allow insertion at document end" {
    const content = "A가😀Z";
    const units: Utf16Range = .{ .location = 1, .length = 3 };
    const bytes: ByteRange = .{ .start = 1, .end = 8 };
    try testing.expectEqual(bytes, byteRange(content, units).?);
    try testing.expectEqual(units, utf16Range(content, bytes).?);
    try testing.expectEqualStrings("가😀", content[bytes.start..bytes.end]);
    try testing.expectEqual(ByteRange{ .start = 9, .end = 9 }, byteRange(content, .{ .location = 5, .length = 0 }).?);
    try testing.expectEqual(Utf16Range{ .location = 5, .length = 0 }, utf16Range(content, .{ .start = 9, .end = 9 }).?);
}

test "ETI3 surrogate and continuation interiors are rejected at either range boundary" {
    const content = "A가😀Z";
    try testing.expectEqual(@as(?usize, null), byteOffset(content, 3));
    for ([_]usize{ 2, 3, 5, 6, 7 }) |inside| {
        try testing.expectEqual(@as(?u64, null), utf16Offset(content, inside));
        try testing.expectEqual(@as(?Utf16Range, null), utf16Range(content, .{ .start = inside, .end = 8 }));
        try testing.expectEqual(@as(?Utf16Range, null), utf16Range(content, .{ .start = 1, .end = inside }));
    }
    try testing.expectEqual(@as(?ByteRange, null), byteRange(content, .{ .location = 3, .length = 0 }));
    try testing.expectEqual(@as(?ByteRange, null), byteRange(content, .{ .location = 2, .length = 1 }));
}

test "ETI4 out-of-range reversed and overflowing ranges are rejected without clamping" {
    try testing.expectEqual(@as(?usize, null), byteOffset("a", 2));
    try testing.expectEqual(@as(?u64, null), utf16Offset("a", 2));
    try testing.expectEqual(@as(?ByteRange, null), byteRange("a", .{ .location = 1, .length = 1 }));
    try testing.expectEqual(@as(?ByteRange, null), byteRange("a", .{ .location = std.math.maxInt(u64), .length = 1 }));
    try testing.expectEqual(@as(?ByteRange, null), byteRange("a", .{ .location = 1, .length = std.math.maxInt(u64) }));
    try testing.expectEqual(@as(?Utf16Range, null), utf16Range("a", .{ .start = 1, .end = 0 }));
    try testing.expectEqual(@as(?Utf16Range, null), utf16Range("a", .{ .start = 0, .end = 2 }));
    try testing.expectEqual(@as(?Utf16Range, null), utf16Range("a", .{ .start = std.math.maxInt(usize), .end = std.math.maxInt(usize) }));
}

test "ETI5 malformed UTF8 cannot become a length or a traversed input range" {
    const invalid = [_][]const u8{ "\x80", "\xc0\xaf", "\xe3\x81", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xf0\x28\x8c\xbc" };
    for (invalid) |bytes| {
        try testing.expectEqual(@as(?u64, null), utf16Length(bytes));
        try testing.expectEqual(@as(?usize, null), byteOffset(bytes, 1));
        try testing.expectEqual(@as(?ByteRange, null), byteRange(bytes, .{ .location = 0, .length = 1 }));
        try testing.expectEqual(@as(?Utf16Range, null), utf16Range(bytes, .{ .start = 0, .end = bytes.len }));
    }
}
