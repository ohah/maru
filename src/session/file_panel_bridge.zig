//! FP4 파일 패널 브리지의 OS-중립 경로·용량·MIME 정책.
//!
//! 실제 파일 I/O와 realpath 검증은 platform 어댑터가 맡지만, 브리지에서 받은 상대 경로를 어떤 형태로
//! 허용할지는 이 모듈이 단일 출처다. `readAsset`은 핀된 Markdown 파일의 디렉터리 아래만 읽으며 `..`는
//! 정상화하지 않고 거부한다. 따라서 호출자가 기준 디렉터리를 임의로 넓힐 수 없다.

const std = @import("std");

/// Markdown 본문과 상대 asset에 공통으로 적용하는 단일 파일 읽기 상한. base64 응답은 이보다 커질 수 있다.
pub const max_file_bytes: usize = 8 * 1024 * 1024;

/// 사용자가 도크로 열 수 있는 v1 파일 종류. 확장자 분류를 Zig 한 곳에 두어 터미널 링크와 NSOpenPanel이
/// 서로 다른 파일 집합을 열지 않게 한다.
pub const OpenKind = enum { markdown, html };

pub fn openKindForPath(path: []const u8) ?OpenKind {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".md")) return .markdown;
    if (std.ascii.eqlIgnoreCase(ext, ".html")) return .html;
    return null;
}

/// Markdown URI의 로컬 `.md`/`.html` 링크를 현재 핀 파일 기준 절대 경로로 바꾼다. 외부 scheme과
/// protocol-relative URL은 받지 않으며, fragment/query는 파일 선택에 관여하지 않으므로 제거한다.
pub fn resolveMarkdownFileLink(
    gpa: std.mem.Allocator,
    source_path: []const u8,
    href: []const u8,
) (std.mem.Allocator.Error || error{InvalidLink})![]u8 {
    if (!std.fs.path.isAbsolute(source_path) or openKindForPath(source_path) != .markdown or href.len == 0 or
        href.len > std.fs.max_path_bytes or std.mem.startsWith(u8, href, "//")) return error.InvalidLink;

    var suffix = href.len;
    if (std.mem.indexOfScalar(u8, href, '?')) |i| suffix = @min(suffix, i);
    if (std.mem.indexOfScalar(u8, href, '#')) |i| suffix = @min(suffix, i);
    const encoded = href[0..suffix];
    if (encoded.len == 0 or encoded.len > std.fs.max_path_bytes) return error.InvalidLink;

    // `scheme:`은 로컬 파일 링크가 아니다. ':'가 첫 slash보다 앞에 있고 RFC 3986 scheme 문법이면 거부한다.
    if (std.mem.indexOfScalar(u8, encoded, ':')) |colon| {
        const slash = std.mem.indexOfScalar(u8, encoded, '/') orelse encoded.len;
        if (colon < slash and colon > 0 and std.ascii.isAlphabetic(encoded[0])) {
            var valid_scheme = true;
            for (encoded[1..colon]) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) valid_scheme = false;
            }
            if (valid_scheme) return error.InvalidLink;
        }
    }

    const decoded_buf = try gpa.alloc(u8, encoded.len);
    defer gpa.free(decoded_buf);
    var read: usize = 0;
    var written: usize = 0;
    while (read < encoded.len) {
        const byte = encoded[read];
        if (byte == '\\' or byte < 0x20 or byte == 0x7f) return error.InvalidLink;
        if (byte != '%') {
            decoded_buf[written] = byte;
            read += 1;
            written += 1;
            continue;
        }
        if (read + 2 >= encoded.len) return error.InvalidLink;
        const hi = std.fmt.charToDigit(encoded[read + 1], 16) catch return error.InvalidLink;
        const lo = std.fmt.charToDigit(encoded[read + 2], 16) catch return error.InvalidLink;
        const decoded = hi * 16 + lo;
        if (decoded == '\\' or decoded < 0x20 or decoded == 0x7f) return error.InvalidLink;
        decoded_buf[written] = decoded;
        read += 3;
        written += 1;
    }
    const decoded = decoded_buf[0..written];
    if (!std.unicode.utf8ValidateSlice(decoded) or std.mem.startsWith(u8, decoded, "//")) return error.InvalidLink;

    const absolute = if (std.fs.path.isAbsolute(decoded))
        try std.fs.path.resolve(gpa, &.{decoded})
    else
        try std.fs.path.resolve(gpa, &.{ std.fs.path.dirname(source_path) orelse "/", decoded });
    errdefer gpa.free(absolute);
    if (openKindForPath(absolute) == null) {
        return error.InvalidLink;
    }
    return absolute;
}

pub const PathError = error{
    Empty,
    Absolute,
    Traversal,
    InvalidCharacter,
    InvalidUtf8,
    TooLong,
};

/// `readAsset(relpath)`의 입력을 `/` 구분 상대 경로로 정규화한다.
///
/// - 절대 경로, `..` segment, 역슬래시, NUL/ASCII 제어문자를 거부한다.
/// - 빈 segment와 `.` segment는 제거한다.
/// - URL percent decoding은 web shell이 먼저 수행하지만, decoded 결과도 이 함수가 다시 검증한다.
pub fn normalizeAssetPath(raw: []const u8, out: []u8) PathError![]const u8 {
    if (raw.len == 0) return error.Empty;
    if (raw[0] == '/') return error.Absolute;
    if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;

    for (raw) |byte| {
        if (byte == '\\' or byte < 0x20 or byte == 0x7f) return error.InvalidCharacter;
    }

    var written: usize = 0;
    var segments = std.mem.splitScalar(u8, raw, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) return error.Traversal;

        const needed = segment.len + @intFromBool(written != 0);
        if (needed > out.len -| written) return error.TooLong;
        if (written != 0) {
            out[written] = '/';
            written += 1;
        }
        @memcpy(out[written..][0..segment.len], segment);
        written += segment.len;
    }
    if (written == 0) return error.Empty;
    return out[0..written];
}

/// data URL을 만들 때 쓰는 보수적 MIME. 알 수 없는 확장자는 실행되지 않는 octet-stream으로 내린다.
pub fn mimeForPath(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, ".avif")) return "image/avif";
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return "image/svg+xml";
    return "application/octet-stream";
}

const testing = std.testing;

test "normalizeAssetPath: relative path normalization retains unicode and spaces" {
    var out: [256]u8 = undefined;
    try testing.expectEqualStrings("images/한글 그림.png", try normalizeAssetPath("./images//한글 그림.png", &out));
}

test "normalizeAssetPath: rejects traversal, absolute, backslash, controls, invalid utf8, and empty" {
    var out: [256]u8 = undefined;
    try testing.expectError(error.Traversal, normalizeAssetPath("../secret", &out));
    try testing.expectError(error.Traversal, normalizeAssetPath("images/../../secret", &out));
    try testing.expectError(error.Absolute, normalizeAssetPath("/etc/passwd", &out));
    try testing.expectError(error.InvalidCharacter, normalizeAssetPath("images\\secret.png", &out));
    try testing.expectError(error.InvalidCharacter, normalizeAssetPath("images/\x00secret.png", &out));
    try testing.expectError(error.InvalidCharacter, normalizeAssetPath("images/\x1fsecret.png", &out));
    try testing.expectError(error.Empty, normalizeAssetPath("", &out));
    try testing.expectError(error.Empty, normalizeAssetPath(".", &out));
    try testing.expectError(error.InvalidUtf8, normalizeAssetPath("bad\xff.png", &out));
}

test "normalizeAssetPath: reports too long without partial success" {
    var out: [3]u8 = undefined;
    try testing.expectError(error.TooLong, normalizeAssetPath("four", &out));
}

test "mimeForPath: known image extensions and inert fallback" {
    try testing.expectEqualStrings("image/png", mimeForPath("a.PNG"));
    try testing.expectEqualStrings("image/jpeg", mimeForPath("a.jpeg"));
    try testing.expectEqualStrings("image/svg+xml", mimeForPath("a.svg"));
    try testing.expectEqualStrings("application/octet-stream", mimeForPath("a.html"));
}

test "openKindForPath: md and html only, case-insensitive" {
    try testing.expectEqual(OpenKind.markdown, openKindForPath("/tmp/readme.MD").?);
    try testing.expectEqual(OpenKind.html, openKindForPath("/tmp/page.HTML").?);
    try testing.expect(openKindForPath("/tmp/page.htm") == null);
    try testing.expect(openKindForPath("/tmp/readme.md.txt") == null);
    try testing.expect(openKindForPath("/tmp/.md") == null);
}

test "resolveMarkdownFileLink: resolves relative and absolute supported links with URI suffixes" {
    const relative = try resolveMarkdownFileLink(
        testing.allocator,
        "/workspace/docs/current.md",
        "../guide/next%20step.md#usage",
    );
    defer testing.allocator.free(relative);
    try testing.expectEqualStrings("/workspace/guide/next step.md", relative);

    const absolute = try resolveMarkdownFileLink(
        testing.allocator,
        "/workspace/docs/current.md",
        "/tmp/page.HTML?mode=preview",
    );
    defer testing.allocator.free(absolute);
    try testing.expectEqualStrings("/tmp/page.HTML", absolute);
}

test "resolveMarkdownFileLink: rejects non-file, malformed, and unsupported targets" {
    const cases = [_][]const u8{
        "",
        "#section",
        "https://example.com/next.md",
        "//example.com/next.md",
        "next.txt",
        "next%2.md",
        "next\\file.md",
        "next\x00file.md",
    };
    for (cases) |href| {
        try testing.expectError(
            error.InvalidLink,
            resolveMarkdownFileLink(testing.allocator, "/workspace/docs/current.md", href),
        );
    }
}
