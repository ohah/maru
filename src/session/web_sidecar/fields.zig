//! 웹 OSR sidecar 제어 채널의 닫힌 필드 규칙(W1a) — browser id 0 금지, view 크기·scale(NaN 거절), bool 0/1,
//! URL·글 상한과 UTF-8. encode 와 decode 가 같은 함수를 지나야 한쪽만 느슨해지지 않는다.

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

/// view 크기 상한(DIP). 5K 화면 전체의 두 배를 넘는 view 는 없다.
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

pub fn writeUrl(cursor: *Cursor, url: []const u8) Error!void {
    if (url.len == 0) return error.EmptyUrl;
    if (url.len > max_url_bytes) return error.UrlTooLarge;
    if (!std.unicode.utf8ValidateSlice(url)) return error.InvalidUtf8;
    try cursor.writeU32(@intCast(url.len));
    try cursor.writeBytes(url);
}

pub fn readUrl(cursor: *ReadCursor) Error![]const u8 {
    const len = try cursor.readU32();
    if (len == 0) return error.EmptyUrl;
    if (len > max_url_bytes) return error.UrlTooLarge;
    const url = try cursor.readBytes(len);
    if (!std.unicode.utf8ValidateSlice(url)) return error.InvalidUtf8;
    return url;
}

pub fn writeText(cursor: *Cursor, text: []const u8) Error!void {
    if (text.len > max_text_bytes) return error.TextTooLarge;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    try cursor.writeU32(@intCast(text.len));
    try cursor.writeBytes(text);
}

pub fn readText(cursor: *ReadCursor) Error![]const u8 {
    const len = try cursor.readU32();
    if (len > max_text_bytes) return error.TextTooLarge;
    const text = try cursor.readBytes(len);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return text;
}
