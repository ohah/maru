//! IOSurface 호출(W2). 링의 세 장은 BGRA 8 비트(바이트당 4) — CEF 가 그리기마다 넘기는 surface 와 같은 형식이다.

const std = @import("std");
const mach = @import("mach.zig");

pub const Ref = *anyopaque;

extern "c" fn IOSurfaceCreate(properties: *anyopaque) ?Ref;
extern "c" fn IOSurfaceCreateMachPort(surface: Ref) mach.Port;
extern "c" fn IOSurfaceLookupFromMachPort(port: mach.Port) ?Ref;
extern "c" fn IOSurfaceLock(surface: Ref, options: u32, seed: ?*u32) i32;
extern "c" fn IOSurfaceUnlock(surface: Ref, options: u32, seed: ?*u32) i32;
extern "c" fn IOSurfaceGetBaseAddress(surface: Ref) [*]u8;
extern "c" fn IOSurfaceGetBytesPerRow(surface: Ref) usize;
extern "c" fn IOSurfaceGetWidth(surface: Ref) usize;
extern "c" fn IOSurfaceGetHeight(surface: Ref) usize;
extern "c" fn CFRelease(object: *anyopaque) void;
extern "c" fn CFDictionaryCreateMutable(allocator: ?*anyopaque, capacity: isize, keys: ?*const anyopaque, values: ?*const anyopaque) ?*anyopaque;
extern "c" fn CFDictionarySetValue(dict: *anyopaque, key: *const anyopaque, value: *const anyopaque) void;
extern "c" fn CFNumberCreate(allocator: ?*anyopaque, kind: isize, value: *const anyopaque) ?*anyopaque;
extern "c" const kIOSurfaceWidth: *const anyopaque;
extern "c" const kIOSurfaceHeight: *const anyopaque;
extern "c" const kIOSurfaceBytesPerElement: *const anyopaque;
extern "c" const kIOSurfacePixelFormat: *const anyopaque;
extern "c" const kCFTypeDictionaryKeyCallBacks: anyopaque;
extern "c" const kCFTypeDictionaryValueCallBacks: anyopaque;

const kCFNumberSInt32Type: isize = 3;
pub const lock_read_only: u32 = 1;
const pixel_format_bgra: i32 = 0x42475241; // 'BGRA'

pub fn create(pixels_wide: u32, pixels_high: u32) error{IOSurfaceFailed}!Ref {
    const dict = CFDictionaryCreateMutable(null, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.IOSurfaceFailed;
    defer CFRelease(dict);
    const w: i32 = @intCast(pixels_wide);
    const h: i32 = @intCast(pixels_high);
    const bpe: i32 = 4;
    const format: i32 = pixel_format_bgra;
    const pairs = [_]struct { key: *const anyopaque, value: *const i32 }{
        .{ .key = kIOSurfaceWidth, .value = &w },
        .{ .key = kIOSurfaceHeight, .value = &h },
        .{ .key = kIOSurfaceBytesPerElement, .value = &bpe },
        .{ .key = kIOSurfacePixelFormat, .value = &format },
    };
    for (pairs) |pair| {
        const number = CFNumberCreate(null, kCFNumberSInt32Type, pair.value) orelse return error.IOSurfaceFailed;
        defer CFRelease(number);
        CFDictionarySetValue(dict, pair.key, number);
    }
    return IOSurfaceCreate(dict) orelse error.IOSurfaceFailed;
}

pub fn release(surface: Ref) void {
    CFRelease(surface);
}

/// 보낼 권리를 새로 만든다 — 메시지에 `move_send` 로 실어 넘긴다.
pub fn machPort(surface: Ref) mach.Port {
    return IOSurfaceCreateMachPort(surface);
}

/// 받은 권리에서 surface 를 되찾는다(참조 하나를 쥔다 — `release` 로 푼다).
pub fn fromMachPort(port: mach.Port) ?Ref {
    return IOSurfaceLookupFromMachPort(port);
}

pub fn width(surface: Ref) usize {
    return IOSurfaceGetWidth(surface);
}

pub fn height(surface: Ref) usize {
    return IOSurfaceGetHeight(surface);
}

/// `src` 의 픽셀을 `dst` 로 옮긴다(C3 — CPU memcpy). 두 장의 줄 간격이 달라도 줄마다 옮기고, 크기가 다르면 겹치는
/// 부분만 옮긴다. 콜백 안에서 부른다 — CEF 풀 버퍼는 콜백이 돌아가면 다시 쓰인다.
pub fn copy(src: Ref, dst: Ref) void {
    _ = IOSurfaceLock(src, lock_read_only, null);
    defer _ = IOSurfaceUnlock(src, lock_read_only, null);
    _ = IOSurfaceLock(dst, 0, null);
    defer _ = IOSurfaceUnlock(dst, 0, null);
    const rows = @min(height(src), height(dst));
    const row_bytes = @min(width(src), width(dst)) * 4;
    const src_stride = IOSurfaceGetBytesPerRow(src);
    const dst_stride = IOSurfaceGetBytesPerRow(dst);
    const src_base = IOSurfaceGetBaseAddress(src);
    const dst_base = IOSurfaceGetBaseAddress(dst);
    if (src_stride == dst_stride and row_bytes == src_stride) {
        @memcpy(dst_base[0 .. rows * dst_stride], src_base[0 .. rows * src_stride]);
        return;
    }
    for (0..rows) |row| {
        @memcpy(dst_base[row * dst_stride ..][0..row_bytes], src_base[row * src_stride ..][0..row_bytes]);
    }
}

/// 한 픽셀(BGRA 를 0xAARRGGBB 로). 판정자가 찢어짐을 볼 때 쓴다 — 호출자가 잠근다.
pub fn pixel(surface: Ref, x: usize, y: usize) u32 {
    const base = IOSurfaceGetBaseAddress(surface);
    const at = base + y * IOSurfaceGetBytesPerRow(surface) + x * 4;
    return @as(u32, at[3]) << 24 | @as(u32, at[2]) << 16 | @as(u32, at[1]) << 8 | at[0];
}

pub fn lockRead(surface: Ref) void {
    _ = IOSurfaceLock(surface, lock_read_only, null);
}

pub fn unlockRead(surface: Ref) void {
    _ = IOSurfaceUnlock(surface, lock_read_only, null);
}
