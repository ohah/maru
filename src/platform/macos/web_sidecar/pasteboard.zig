//! macOS 클립보드(`NSPasteboard`)에 쓴다(W6c — 우클릭 메뉴의 링크 주소·이미지 주소·이미지 복사). sidecar 는 샌드박스 밖이라
//! 다른 앱처럼 쓸 수 있다(착수 전 실측 — 백그라운드 프로세스가 글·PNG 를 쓰고 다시 읽었다). Objective-C 런타임을 직접 부른다.
//!
//! `name` 이 있으면 그 이름의 클립보드(`pasteboardWithName:`)를 쓴다 — 판정자 전용(`MARU_WEB_TEST_PASTEBOARD`)이다. 판정을 돌려도
//! 사용자의 클립보드를 덮어쓰지 않고, 판정자가 같은 이름으로 읽어 확인한다.

const std = @import("std");

const Id = ?*anyopaque;
const Sel = ?*anyopaque;

extern fn objc_getClass(name: [*:0]const u8) Id;
extern fn sel_registerName(name: [*:0]const u8) Sel;
extern fn objc_msgSend() void;
extern fn objc_autoreleasePoolPush() ?*anyopaque;
extern fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

const utf8_encoding: usize = 4; // NSUTF8StringEncoding

pub const string_type = "public.utf8-plain-text";
pub const url_type = "public.url";
pub const png_type = "public.png";

fn msg0(receiver: Id, selector: [*:0]const u8) Id {
    const f: *const fn (Id, Sel) callconv(.c) Id = @ptrCast(&objc_msgSend);
    return f(receiver, sel_registerName(selector));
}

/// NSString(+1 — 호출자가 `release`).
fn nsString(bytes: []const u8) Id {
    const alloc = msg0(objc_getClass("NSString"), "alloc");
    const f: *const fn (Id, Sel, [*]const u8, usize, usize) callconv(.c) Id = @ptrCast(&objc_msgSend);
    return f(alloc, sel_registerName("initWithBytes:length:encoding:"), bytes.ptr, bytes.len, utf8_encoding);
}

fn release(object: Id) void {
    if (object != null) _ = msg0(object, "release");
}

fn board(name: ?[]const u8) Id {
    const class = objc_getClass("NSPasteboard");
    const n = name orelse return msg0(class, "generalPasteboard");
    const ns = nsString(n);
    defer release(ns);
    const f: *const fn (Id, Sel, Id) callconv(.c) Id = @ptrCast(&objc_msgSend);
    return f(class, sel_registerName("pasteboardWithName:"), ns);
}

fn setString(pb: Id, text: []const u8, kind: [:0]const u8) bool {
    const value = nsString(text);
    defer release(value);
    const kind_ns = nsString(kind);
    defer release(kind_ns);
    const f: *const fn (Id, Sel, Id, Id) callconv(.c) u8 = @ptrCast(&objc_msgSend);
    return value != null and f(pb, sel_registerName("setString:forType:"), value, kind_ns) != 0;
}

/// 글을 쓴다(그 클립보드의 원래 내용은 지운다). `as_url` 이면 URL 형식도 함께 — 다른 앱이 링크로 붙여 넣는다.
pub fn writeText(name: ?[]const u8, text: []const u8, as_url: bool) bool {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    const pb = board(name) orelse return false;
    _ = msg0(pb, "clearContents");
    const ok = setString(pb, text, string_type);
    return if (as_url) setString(pb, text, url_type) and ok else ok;
}

/// PNG 바이트를 쓴다. macOS 가 TIFF 형식도 함께 내준다(실측).
pub fn writePng(name: ?[]const u8, png: []const u8) bool {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    const pb = board(name) orelse return false;
    _ = msg0(pb, "clearContents");
    const make: *const fn (Id, Sel, [*]const u8, usize) callconv(.c) Id = @ptrCast(&objc_msgSend);
    const data = make(objc_getClass("NSData"), sel_registerName("dataWithBytes:length:"), png.ptr, png.len);
    if (data == null) return false;
    const kind = nsString(png_type);
    defer release(kind);
    const f: *const fn (Id, Sel, Id, Id) callconv(.c) u8 = @ptrCast(&objc_msgSend);
    return f(pb, sel_registerName("setData:forType:"), data, kind) != 0;
}

/// 클립보드 변경 번호(`changeCount`) — 누가 쓰면 오른다.
pub fn changeCount(name: ?[]const u8) isize {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    const pb = board(name) orelse return -1;
    const f: *const fn (Id, Sel) callconv(.c) isize = @ptrCast(&objc_msgSend);
    return f(pb, sel_registerName("changeCount"));
}

/// 그 형식의 글을 `out` 에 읽는다(판정자). 없으면 null.
pub fn readText(name: []const u8, kind: [:0]const u8, out: []u8) ?[]const u8 {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    const pb = board(name) orelse return null;
    const kind_ns = nsString(kind);
    defer release(kind_ns);
    const get: *const fn (Id, Sel, Id) callconv(.c) Id = @ptrCast(&objc_msgSend);
    const value = get(pb, sel_registerName("stringForType:"), kind_ns) orelse return null;
    const utf8: *const fn (Id, Sel) callconv(.c) ?[*:0]const u8 = @ptrCast(&objc_msgSend);
    const bytes = std.mem.span(utf8(value, sel_registerName("UTF8String")) orelse return null);
    const n = @min(bytes.len, out.len);
    @memcpy(out[0..n], bytes[0..n]);
    return out[0..n];
}

/// 그 형식의 바이트 수(판정자 — PNG 가 들어 있는가). 없으면 0.
pub fn dataLength(name: []const u8, kind: [:0]const u8) usize {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    const pb = board(name) orelse return 0;
    const kind_ns = nsString(kind);
    defer release(kind_ns);
    const get: *const fn (Id, Sel, Id) callconv(.c) Id = @ptrCast(&objc_msgSend);
    const data = get(pb, sel_registerName("dataForType:"), kind_ns) orelse return 0;
    const length: *const fn (Id, Sel) callconv(.c) usize = @ptrCast(&objc_msgSend);
    return length(data, sel_registerName("length"));
}

/// 판정자가 쓴 이름의 클립보드를 비우고 놓는다(`releaseGlobally`).
pub fn dispose(name: []const u8) void {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    const pb = board(name) orelse return;
    _ = msg0(pb, "clearContents");
    _ = msg0(pb, "releaseGlobally");
}
