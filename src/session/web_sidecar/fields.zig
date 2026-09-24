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
const BrowserId = message.BrowserId;
const ViewSize = message.ViewSize;
const Hello = message.Hello;

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
