//! Chromium 탭에서 이미지를 끌어내 Finder 에 놓을 때 만들 파일의 이름(W6d③ — docs/plans/web-osr-backend.md W6). 이름은 페이지가
//! 정한 주소·`Content-Disposition` 에서 Chromium 이 만든다 — Chromium 이 이미 경로 구분자를 `_` 로, 숨김 이름의 앞 점을 빼고, 확장자를
//! 이미지 형식에 맞춘다(착수 전 실측: `x.command` → `x.png`, `../../evil.command` → `_.._evil.png`, `.hidden` → `hidden.png`). 그래도
//! maru 가 한 겹 더 막는다 — 실행되는 파일(`.command`·`.app` 등)이 Finder 에 생기면 더블클릭 한 번이 실행이다.
//!
//! - 경로 구분자(`/`·`\`·`:` — Finder 는 `:` 를 경로로 보인다)·제어 문자·방향 바꿈 문자는 `_`.
//! - 앞의 점·빈칸과 뒤의 점·빈칸은 뺀다(숨김 파일·Finder 가 지우는 끝).
//! - 확장자는 이미지 허용 목록에 있어야 한다 — 아니면 파일을 만들지 않는다(주소만 간다).
//! - 255 바이트(APFS 이름 상한)를 넘으면 확장자를 남기고 앞부분을 글자 경계에서 자른다. 앞부분이 비면 `image`.

const std = @import("std");

/// 이미지 허용 목록(소문자). Chromium 이 이미지 MIME 으로 고르는 확장자들.
pub const image_extensions = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico", "tif", "tiff", "avif", "heic", "heif" };

pub const max_name_bytes = 255;

/// 안전한 파일 이름을 `out` 에 만든다. 이미지 확장자가 아니거나 UTF-8 이 아니면 null.
pub fn safeFileName(name: []const u8, out: *[max_name_bytes]u8) ?[]const u8 {
    if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) return null;
    // 1. 위험한 글자를 `_` 로 옮겨 적는다(글자 단위).
    var tmp: [4096]u8 = undefined;
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(name).iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return null;
        const bad = cp < 0x20 or cp == 0x7f or cp == '/' or cp == '\\' or cp == ':' or (cp >= 0x80 and cp < 0xa0) or
            (cp >= 0x200e and cp <= 0x200f) or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069);
        const piece: []const u8 = if (bad) "_" else slice;
        if (n + piece.len > tmp.len) return null;
        @memcpy(tmp[n .. n + piece.len], piece);
        n += piece.len;
    }
    // 2. 앞의 점·빈칸, 뒤의 점·빈칸.
    var cleaned = std.mem.trim(u8, tmp[0..n], " .");
    // 3. 확장자(마지막 점 뒤).
    const dot = std.mem.lastIndexOfScalar(u8, cleaned, '.') orelse return null;
    const ext = cleaned[dot + 1 ..];
    if (!isImageExtension(ext)) return null;
    var stem = std.mem.trimEnd(u8, cleaned[0..dot], " .");
    // 4. 길이 — 확장자를 남기고 앞부분을 글자 경계에서.
    const room = max_name_bytes - ext.len - 1;
    if (stem.len > room) {
        var end = room;
        while (end > 0 and stem[end] & 0xC0 == 0x80) end -= 1;
        stem = stem[0..end];
    }
    if (stem.len == 0) stem = "image";
    cleaned = undefined;
    @memcpy(out[0..stem.len], stem);
    out[stem.len] = '.';
    @memcpy(out[stem.len + 1 .. stem.len + 1 + ext.len], ext);
    return out[0 .. stem.len + 1 + ext.len];
}

pub fn isImageExtension(ext: []const u8) bool {
    if (ext.len == 0 or ext.len > 5) return false;
    var lower: [5]u8 = undefined;
    for (ext, 0..) |byte, i| lower[i] = std.ascii.toLower(byte);
    for (image_extensions) |allowed| if (std.mem.eql(u8, allowed, lower[0..ext.len])) return true;
    return false;
}

test "image file names keep safe names and refuse executables, paths, hidden names and control characters" {
    var out: [max_name_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("cat.png", safeFileName("cat.png", &out).?);
    try std.testing.expectEqualStrings("한글 이름.png", safeFileName("한글 이름.png", &out).?);
    try std.testing.expectEqualStrings("Photo.JPG", safeFileName("Photo.JPG", &out).?);
    // Chromium 이 이미 바꾼 이름(실측)도 그대로 안전하다.
    try std.testing.expectEqualStrings("_.._evil.png", safeFileName("_.._evil.png", &out).?);
    // 실행 파일·이미지 아닌 확장자·확장자 없음은 파일을 만들지 않는다.
    try std.testing.expect(safeFileName("x.command", &out) == null);
    try std.testing.expect(safeFileName("run.app", &out) == null);
    try std.testing.expect(safeFileName("image.png.command", &out) == null);
    try std.testing.expect(safeFileName("noext", &out) == null);
    try std.testing.expect(safeFileName("", &out) == null);
    // 경로·숨김·제어·방향 바꿈.
    try std.testing.expectEqualStrings("_.._etc_passwd.png", safeFileName("/../etc/passwd.png", &out).?);
    try std.testing.expectEqualStrings("a_b_c.png", safeFileName("a:b\\c.png", &out).?);
    try std.testing.expectEqualStrings("hidden.png", safeFileName(".hidden.png", &out).?);
    try std.testing.expectEqualStrings("a_b.png", safeFileName("a\nb.png", &out).?);
    // U+202E(오른쪽에서 왼쪽으로 덮어쓰기)로 「gnp.exe」처럼 보이게 하는 이름.
    try std.testing.expectEqualStrings("evil_gnp.png", safeFileName("evil\u{202E}gnp.png", &out).?);
    try std.testing.expect(safeFileName("...png", &out) == null); // 앞 점을 빼면 확장자가 없다
    try std.testing.expectEqualStrings("a.png", safeFileName("a... .png", &out).?);
    try std.testing.expectEqualStrings("_.png", safeFileName("_ .png", &out).?);
    try std.testing.expect(safeFileName("bad\xffname.png", &out) == null);
    // 255 바이트 — 확장자를 남기고 글자 경계에서 자른다.
    const long = "가" ** 120 ++ ".png";
    const cut = safeFileName(long, &out).?;
    try std.testing.expect(cut.len <= max_name_bytes and std.mem.endsWith(u8, cut, ".png") and std.unicode.utf8ValidateSlice(cut));
}
