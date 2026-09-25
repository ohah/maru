//! 웹 OSR sidecar 제어 채널의 닫힌 필드 규칙(W1a) — browser id 0 금지, view 크기·scale(NaN 거절), bool 0/1,
//! URL·글 상한과 UTF-8, 제어 문자 거절. encode 와 decode 가 **같은 검사 함수**(`validSize`·`checkUrl`·`checkText`)를
//! 지나야 한쪽만 느슨해지지 않는다.

const std = @import("std");
const wire = @import("wire.zig");
const message = @import("message.zig");

const Cursor = wire.Cursor;
const ReadCursor = wire.ReadCursor;
const Error = wire.Error;
const max_url_bytes = wire.max_url_bytes;
const max_text_bytes = wire.max_text_bytes;
const max_ime_text_bytes = wire.max_ime_text_bytes;
const BrowserId = message.BrowserId;
const ViewSize = message.ViewSize;
const Hello = message.Hello;
const Modifiers = message.Modifiers;
const Point = message.Point;
const Mouse = message.Mouse;
const TextRange = message.TextRange;
const Rect = message.Rect;
const max_pointer_extent = message.max_pointer_extent;

/// view 크기 상한(DIP). 가장 큰 Mac 화면(6K — 3008 DIP)의 다섯 배 남짓이라 view 로는 넉넉하다. 물리 픽셀(DIP × scale)
/// 상한은 픽셀 링이 따로 본다(W2 — IOSurface·Metal 텍스처 한도).
pub const max_view_extent: u32 = 16 * 1024;
pub const min_scale: f32 = 0.5;
pub const max_scale: f32 = 8.0;

pub fn writeBrowser(cursor: *Cursor, browser: BrowserId) Error!void {
    if (browser == 0) return error.InvalidBrowserId;
    try cursor.writeU64(browser);
}

pub fn readBrowser(cursor: *ReadCursor) Error!BrowserId {
    const browser = try cursor.readU64();
    if (browser == 0) return error.InvalidBrowserId;
    return browser;
}

pub fn validSize(size: ViewSize) bool {
    if (size.width == 0 or size.width > max_view_extent) return false;
    if (size.height == 0 or size.height > max_view_extent) return false;
    // NaN 은 두 비교가 모두 거짓이라 여기서 걸린다.
    return size.scale >= min_scale and size.scale <= max_scale;
}

pub fn writeSize(cursor: *Cursor, size: ViewSize) Error!void {
    if (!validSize(size)) return error.InvalidViewSize;
    try cursor.writeU32(size.width);
    try cursor.writeU32(size.height);
    try cursor.writeU32(@bitCast(size.scale));
}

pub fn readSize(cursor: *ReadCursor) Error!ViewSize {
    const size: ViewSize = .{
        .width = try cursor.readU32(),
        .height = try cursor.readU32(),
        .scale = @bitCast(try cursor.readU32()),
    };
    if (!validSize(size)) return error.InvalidViewSize;
    return size;
}

pub fn readBool(cursor: *ReadCursor) Error!bool {
    return switch (try cursor.readByte()) {
        0 => false,
        1 => true,
        else => error.InvalidBool,
    };
}

/// 입력 필드(W4). 좌표·스크롤 양은 `max_pointer_extent` 안, 수식자는 정의된 비트만, 범위는 없음이거나 순서가 맞고 글
/// 상한 안.
pub fn writeModifiers(cursor: *Cursor, modifiers: Modifiers) Error!void {
    if (modifiers._reserved != 0) return error.InvalidModifiers;
    try cursor.writeU16(@bitCast(modifiers));
}

pub fn readModifiers(cursor: *ReadCursor) Error!Modifiers {
    const modifiers: Modifiers = @bitCast(try cursor.readU16());
    if (modifiers._reserved != 0) return error.InvalidModifiers;
    return modifiers;
}

pub fn writeExtent(cursor: *Cursor, value: i32) Error!void {
    if (@abs(value) > max_pointer_extent) return error.InvalidCoordinate;
    try cursor.writeU32(@bitCast(value));
}

pub fn readExtent(cursor: *ReadCursor) Error!i32 {
    const value: i32 = @bitCast(try cursor.readU32());
    if (@abs(value) > max_pointer_extent) return error.InvalidCoordinate;
    return value;
}

pub fn writePoint(cursor: *Cursor, point: Point) Error!void {
    try writeExtent(cursor, point.x);
    try writeExtent(cursor, point.y);
}

pub fn readPoint(cursor: *ReadCursor) Error!Point {
    return .{ .x = try readExtent(cursor), .y = try readExtent(cursor) };
}

/// down·up 은 1 번째 이상의 클릭, move·leave 는 0.
pub fn validClickCount(mouse: Mouse) bool {
    return switch (mouse.kind) {
        .down, .up => mouse.click_count >= 1,
        .move, .leave => mouse.click_count == 0,
    };
}

/// `selection` 은 조합 글 안의 위치(글 상한 안), `replacement` 는 입력칸 전체 글 안의 위치라 순서만 본다(적대 검증 — 5000 자
/// 입력칸 끝의 조합이 거절됐다). 둘 다 「없음」이거나 순서가 맞아야 하고, 한쪽만 최댓값인 반쪽 「없음」은 거절한다.
pub const RangeKind = enum { selection, replacement };

pub fn validRange(range: TextRange, kind: RangeKind) bool {
    if (range.isNone()) return true;
    if (range.start > range.end or range.end == std.math.maxInt(u32)) return false;
    return switch (kind) {
        .selection => range.end <= max_ime_text_bytes,
        .replacement => true,
    };
}

pub fn writeRange(cursor: *Cursor, range: TextRange, kind: RangeKind) Error!void {
    if (!validRange(range, kind)) return error.InvalidRange;
    try cursor.writeU32(range.start);
    try cursor.writeU32(range.end);
}

pub fn readRange(cursor: *ReadCursor, kind: RangeKind) Error!TextRange {
    const range: TextRange = .{ .start = try cursor.readU32(), .end = try cursor.readU32() };
    if (!validRange(range, kind)) return error.InvalidRange;
    return range;
}

/// IME 글: 상한은 `max_ime_text_bytes`, UTF-8, 탭·줄바꿈(LF·CR)을 뺀 제어 문자는 거절한다 — 받아쓰기 「줄 바꿈」이 `\n` 을
/// 넣는다(적대 검증). 제목용 `checkText` 와 따로 둔다.
pub fn checkImeText(text: []const u8) Error!void {
    if (text.len > max_ime_text_bytes) return error.TextTooLarge;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    for (text) |byte| {
        if (byte == '\t' or byte == '\n' or byte == '\r') continue;
        if (byte < 0x20 or byte == 0x7f) return error.ControlCharacter;
    }
}

pub fn writeImeText(cursor: *Cursor, text: []const u8) Error!void {
    try checkImeText(text);
    try cursor.writeU32(@intCast(text.len));
    try cursor.writeBytes(text);
}

pub fn readImeText(cursor: *ReadCursor) Error![]const u8 {
    const len = try cursor.readU32();
    if (len > max_ime_text_bytes) return error.TextTooLarge;
    const text = try cursor.readBytes(len);
    try checkImeText(text);
    return text;
}

/// 대화상자 글(W5a): 상한은 제목과 같은 `max_text_bytes`, UTF-8, 탭·줄바꿈(LF·CR)을 뺀 제어 문자는 거절한다 — 대화상자
/// 문구는 여러 줄이 흔하다. 제목(`checkText`)은 한 줄이라 따로 둔다.
pub fn checkDialogText(text: []const u8) Error!void {
    if (text.len > max_text_bytes) return error.TextTooLarge;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    for (text) |byte| {
        if (byte == '\t' or byte == '\n' or byte == '\r') continue;
        if (byte < 0x20 or byte == 0x7f) return error.ControlCharacter;
    }
}

pub fn writeDialogText(cursor: *Cursor, text: []const u8) Error!void {
    try checkDialogText(text);
    try cursor.writeU32(@intCast(text.len));
    try cursor.writeBytes(text);
}

pub fn readDialogText(cursor: *ReadCursor) Error![]const u8 {
    const len = try cursor.readU32();
    if (len > max_text_bytes) return error.TextTooLarge;
    const text = try cursor.readBytes(len);
    try checkDialogText(text);
    return text;
}

/// 파일 경로(W5a): 비지 않고, 절대 경로이고, `max_text_bytes` 안이고, UTF-8 이며 제어 문자가 없다. 경로는 maru 가 열기
/// 창에서 받은 것이라 sidecar 쪽은 이 규칙만 본다(파일이 있는지는 렌더러가 읽을 때 드러난다).
pub fn checkPath(path: []const u8) Error!void {
    if (path.len == 0 or path[0] != '/') return error.InvalidPath;
    if (path.len > max_text_bytes) return error.TextTooLarge;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidUtf8;
    if (hasControl(path)) return error.ControlCharacter;
}

pub fn writePath(cursor: *Cursor, path: []const u8) Error!void {
    try checkPath(path);
    try cursor.writeU32(@intCast(path.len));
    try cursor.writeBytes(path);
}

pub fn readPath(cursor: *ReadCursor) Error![]const u8 {
    const len = try cursor.readU32();
    if (len > max_text_bytes) return error.TextTooLarge;
    const path = try cursor.readBytes(len);
    try checkPath(path);
    return path;
}

/// 요청 번호는 0 이 아니다(browser id 와 같은 규칙 — 0 은 「없음」으로 남긴다).
pub fn writeRequest(cursor: *Cursor, browser: BrowserId, request: u32) Error!void {
    try writeBrowser(cursor, browser);
    if (request == 0) return error.InvalidRequestId;
    try cursor.writeU32(request);
}

pub fn readRequest(cursor: *ReadCursor) Error!message.Request {
    const browser = try readBrowser(cursor);
    const request = try cursor.readU32();
    if (request == 0) return error.InvalidRequestId;
    return .{ .browser = browser, .request = request };
}

/// 출처 상한 — 호스트 이름(253)과 scheme·포트가 들어간다. 대화상자 제목에 들어가므로 짧게 둔다.
pub const max_origin_bytes: usize = 255;

/// 출처: 빈 글(불투명 출처 — maru 는 「이 페이지」로 보인다)이거나 `scheme://host[:port]`. scheme 은 소문자·숫자·`+.-`,
/// 호스트는 글자·숫자·`.-_`·IPv6 대괄호(`[::1]`)와 유니코드 IDN(CEF 가 안전할 때만 유니코드로 준다), 포트는 숫자다. 경로·질의·
/// 사용자 정보(`@`)·공백·제어 문자는 거절한다 — 제목의 출처 자리에 사이트가 고른 글이 들어가면 위장이 된다(적대 검증).
pub fn checkOrigin(origin: []const u8) Error!void {
    if (origin.len == 0) return;
    if (origin.len > max_origin_bytes) return error.InvalidOrigin;
    if (!std.unicode.utf8ValidateSlice(origin)) return error.InvalidUtf8;
    const sep = std.mem.indexOf(u8, origin, "://") orelse return error.InvalidOrigin;
    if (sep == 0) return error.InvalidOrigin;
    for (origin[0..sep], 0..) |byte, i| {
        const ok = std.ascii.isLower(byte) or (i > 0 and (std.ascii.isDigit(byte) or byte == '+' or byte == '.' or byte == '-'));
        if (!ok) return error.InvalidOrigin;
    }
    var host = origin[sep + 3 ..];
    if (host.len == 0) return error.InvalidOrigin;
    // 포트: 마지막 `:` 뒤가 숫자면 뗀다(IPv6 대괄호 안의 `:` 는 `]` 뒤가 아니면 포트가 아니다).
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        const after_bracket = std.mem.lastIndexOfScalar(u8, host, ']');
        if (after_bracket == null or after_bracket.? < colon) {
            const port = host[colon + 1 ..];
            if (port.len == 0 or port.len > 5) return error.InvalidOrigin;
            for (port) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidOrigin;
            host = host[0..colon];
        }
    }
    if (host.len == 0) return error.InvalidOrigin;
    if (host[0] == '[') {
        if (host[host.len - 1] != ']') return error.InvalidOrigin;
        for (host[1 .. host.len - 1]) |byte| if (!(std.ascii.isHex(byte) or byte == ':' or byte == '.')) return error.InvalidOrigin;
        return;
    }
    var it = std.unicode.Utf8View.initUnchecked(host).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x80) {
            const byte: u8 = @intCast(cp);
            if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_')) return error.InvalidOrigin;
        } else if (deceptive(cp)) return error.InvalidOrigin;
    }
}

/// IDN 호스트에 들어가면 제목을 속이는 글자 — C1 제어, 방향 제어(U+202E 등), 줄·문단 구분(NSAlert 에서 줄바꿈으로 보인다),
/// 폭 없는 글자, 빗금 닮은꼴(U+2044·U+2215·U+FF0F — 호스트 안에 가짜 경로를 그린다). CEF 의 보안 표시는 이런 글을 안 주지만
/// sidecar 는 믿지 않는다(적대 검증).
fn deceptive(cp: u21) bool {
    return (cp >= 0x80 and cp <= 0x9f) or (cp >= 0x200b and cp <= 0x200f) or (cp >= 0x2028 and cp <= 0x202e) or
        (cp >= 0x2060 and cp <= 0x206f) or cp == 0xfeff or cp == 0x2044 or cp == 0x2215 or cp == 0xff0f or cp == 0x00ad;
}

pub fn writeOrigin(cursor: *Cursor, origin: []const u8) Error!void {
    try checkOrigin(origin);
    try cursor.writeU32(@intCast(origin.len));
    try cursor.writeBytes(origin);
}

pub fn readOrigin(cursor: *ReadCursor) Error![]const u8 {
    const len = try cursor.readU32();
    if (len > max_origin_bytes) return error.InvalidOrigin;
    const origin = try cursor.readBytes(len);
    try checkOrigin(origin);
    return origin;
}

pub fn writeRect(cursor: *Cursor, rect: Rect) Error!void {
    try writeExtent(cursor, rect.x);
    try writeExtent(cursor, rect.y);
    if (rect.width > max_pointer_extent or rect.height > max_pointer_extent) return error.InvalidCoordinate;
    try cursor.writeU32(rect.width);
    try cursor.writeU32(rect.height);
}

pub fn readRect(cursor: *ReadCursor) Error!Rect {
    const rect: Rect = .{
        .x = try readExtent(cursor),
        .y = try readExtent(cursor),
        .width = try cursor.readU32(),
        .height = try cursor.readU32(),
    };
    if (rect.width > max_pointer_extent or rect.height > max_pointer_extent) return error.InvalidCoordinate;
    return rect;
}

pub fn readHello(cursor: *ReadCursor) Error!Hello {
    return .{ .instance = try cursor.readU64(), .nonce = try cursor.readU64() };
}

/// C0 제어 문자와 DEL. 제목·설명은 웹 페이지가 통제하는 글이라 ESC·OSC·NUL 이 maru 의 UI·로그·터미널 제목으로
/// 흘러가면 주입이 된다(적대 검증) — sidecar 는 `text.replaceControl` 로 치환해 보내고, 받는 쪽은 남아 있으면 거절한다.
/// URL 은 제어 문자를 퍼센트 인코딩해야 하므로 날것이 있으면 거절한다.
fn hasControl(bytes: []const u8) bool {
    for (bytes) |byte| if (byte < 0x20 or byte == 0x7f) return true;
    return false;
}

pub fn checkUrl(url: []const u8) Error!void {
    if (url.len == 0) return error.EmptyUrl;
    if (url.len > max_url_bytes) return error.UrlTooLarge;
    if (!std.unicode.utf8ValidateSlice(url)) return error.InvalidUtf8;
    if (hasControl(url)) return error.ControlCharacter;
}

pub fn checkText(text: []const u8) Error!void {
    if (text.len > max_text_bytes) return error.TextTooLarge;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (hasControl(text)) return error.ControlCharacter;
}

pub fn writeUrl(cursor: *Cursor, url: []const u8) Error!void {
    try checkUrl(url);
    try cursor.writeU32(@intCast(url.len));
    try cursor.writeBytes(url);
}

pub fn readUrl(cursor: *ReadCursor) Error![]const u8 {
    const len = try cursor.readU32();
    // 길이만으로 거절할 수 있으면 본문을 읽기 전에 거절한다(같은 상한을 checkUrl 이 다시 본다).
    if (len > max_url_bytes) return error.UrlTooLarge;
    const url = try cursor.readBytes(len);
    try checkUrl(url);
    return url;
}

pub fn writeText(cursor: *Cursor, text: []const u8) Error!void {
    try checkText(text);
    try cursor.writeU32(@intCast(text.len));
    try cursor.writeBytes(text);
}

pub fn readText(cursor: *ReadCursor) Error![]const u8 {
    const len = try cursor.readU32();
    if (len > max_text_bytes) return error.TextTooLarge;
    const text = try cursor.readBytes(len);
    try checkText(text);
    return text;
}

/// bootstrap 이름은 1~127 바이트의 출력 가능한 ASCII(공백 제외)만 받는다 — 이름이 곧 신뢰 경계의 주소라 느슨하게 받지 않는다.
fn validService(name: []const u8) bool {
    if (name.len == 0 or name.len > wire.max_service_bytes) return false;
    for (name) |byte| if (byte <= 0x20 or byte >= 0x7f) return false;
    return true;
}

pub fn writeService(cursor: *Cursor, name: []const u8) Error!void {
    if (!validService(name)) return error.InvalidServiceName;
    try cursor.writeByte(@intCast(name.len));
    try cursor.writeBytes(name);
}

pub fn readService(cursor: *ReadCursor) Error![]const u8 {
    const len = try cursor.readByte();
    const name = try cursor.readBytes(len);
    if (!validService(name)) return error.InvalidServiceName;
    return name;
}
