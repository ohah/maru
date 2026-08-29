//! ImageIO 디코드 바인딩(IG3-b) — 계약 [docs/agent-image-gallery.md](../../../docs/agent-image-gallery.md) §5.1.
//!
//! **왜 ObjC 파일이 아니라 Zig extern 인가.** ImageIO 는 C API 다(Objective-C 가 아니다) — `.m` 파일을
//! 새로 만들면 build.zig 의 **29곳**에 붙여야 하고 그 목록이 곧 드리프트 자리가 된다. 여기서는 함수
//! 선언만 두고 프레임워크 링크는 최종 앱이 한다(이 라이브러리는 static 이라 링크를 안 한다).
//!
//! **왜 `terminal/png.zig` 를 안 쓰나.** 그것은 kitty graphics 용 **이식 가능 코어**라 8-bit truecolor PNG
//! 만 받는다(실측 코퍼스의 97.8%). 뷰어는 platform 에 살므로 그 제약이 없고, ImageIO 는 **62종**을
//! 디코드한다 — jpeg(1.9%)·webp·heic·avif 까지 공짜다. WebKit 도 같은 ImageIO 를 쓰므로 네이티브가
//! 웹뷰보다 커버리지가 좁아지지 않는다.
//!
//! **크기는 여기서 정하지 않는다.** 서브샘플 계수는 [`image_scale`](../../session/image_scale.zig) 이
//! 계산하고 이 모듈은 받아 쓴다 — 상한 초과 텍스처는 `nil` 이 아니라 abort 라, 그 계산은 CI 가 보는
//! 순수 함수여야 한다.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ Unsupported, DecodeFailed, OutOfMemory };

/// 디코드 결과. 픽셀은 **호출자 소유**(RGBA8, premultiplied)다.
pub const Decoded = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` 바이트. `allocator.free` 로 푼다.
    pixels: []u8,

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

// ── CoreFoundation / CoreGraphics / ImageIO ──────────────────────────────────────
//
// 정적 라이브러리라 여기서 링크하지 않는다 — 심볼은 최종 앱 링크가 푼다(AppKit 이 이 셋을 끌고 온다).

const CFRef = ?*anyopaque;

const CGFloat = f64; // 64-bit 에서 CGFloat 은 double 이다
const CGPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
const CGSize = extern struct { width: CGFloat = 0, height: CGFloat = 0 };
const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };

/// `kCGImageAlphaPremultipliedLast` — RGBA 순서, 알파가 마지막. 렌더러가 기대하는 배치다.
const alpha_premultiplied_last: u32 = 1;
/// `kCFNumberIntType`.
const cf_number_int: c_int = 9;

extern fn CFRelease(cf: CFRef) void;
extern fn CFDataCreate(allocator: CFRef, bytes: [*]const u8, length: c_long) CFRef;
extern fn CFNumberCreate(allocator: CFRef, theType: c_int, valuePtr: *const anyopaque) CFRef;
extern fn CFDictionaryCreate(
    allocator: CFRef,
    keys: [*]const ?*const anyopaque,
    values: [*]const ?*const anyopaque,
    numValues: c_long,
    keyCallBacks: ?*const anyopaque,
    valueCallBacks: ?*const anyopaque,
) CFRef;
extern const kCFTypeDictionaryKeyCallBacks: anyopaque;
extern const kCFTypeDictionaryValueCallBacks: anyopaque;

extern fn CGImageSourceCreateWithData(data: CFRef, options: CFRef) CFRef;
extern fn CGImageSourceCreateImageAtIndex(isrc: CFRef, index: usize, options: CFRef) CFRef;
extern fn CGImageSourceCopyPropertiesAtIndex(isrc: CFRef, index: usize, options: CFRef) CFRef;
extern fn CFDictionaryGetValue(theDict: CFRef, key: ?*const anyopaque) CFRef;
extern fn CFNumberGetValue(number: CFRef, theType: c_int, valuePtr: *anyopaque) bool;
extern const kCGImagePropertyPixelWidth: CFRef;
extern const kCGImagePropertyPixelHeight: CFRef;
extern const kCGImageSourceSubsampleFactor: CFRef;

extern fn CGImageGetWidth(image: CFRef) usize;
extern fn CGImageGetHeight(image: CFRef) usize;
extern fn CGImageRelease(image: CFRef) void;

extern fn CGColorSpaceCreateDeviceRGB() CFRef;
extern fn CGColorSpaceRelease(space: CFRef) void;
extern fn CGBitmapContextCreate(
    data: ?*anyopaque,
    width: usize,
    height: usize,
    bitsPerComponent: usize,
    bytesPerRow: usize,
    space: CFRef,
    bitmapInfo: u32,
) CFRef;
extern fn CGContextRelease(c: CFRef) void;
extern fn CGContextDrawImage(c: CFRef, rect: CGRect, image: CFRef) void;

/// **디코드하지 않고** 크기만 읽는다. 서브샘플 계수를 고르려면 크기를 먼저 알아야 하는데,
/// 그것을 알자고 원본을 통째로 푸는 것은 앞뒤가 바뀐 일이다 — 21 MPx 짜리면 그 한 번이 84 MB 다.
///
/// 실측(2026-08-29): 메타데이터만 읽는 비용은 0.0 ms 대였다(같은 벤치의 「메타데이터만」 행).
pub fn probeSize(bytes: []const u8) Error!struct { width: u32, height: u32 } {
    if (!builtin.target.os.tag.isDarwin()) return error.Unsupported;
    if (bytes.len == 0) return error.DecodeFailed;

    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.DecodeFailed;
    defer CFRelease(data);
    const source = CGImageSourceCreateWithData(data, null) orelse return error.DecodeFailed;
    defer CFRelease(source);

    const props = CGImageSourceCopyPropertiesAtIndex(source, 0, null) orelse return error.DecodeFailed;
    defer CFRelease(props);

    var w: c_int = 0;
    var h: c_int = 0;
    const wv = CFDictionaryGetValue(props, kCGImagePropertyPixelWidth) orelse return error.DecodeFailed;
    const hv = CFDictionaryGetValue(props, kCGImagePropertyPixelHeight) orelse return error.DecodeFailed;
    if (!CFNumberGetValue(wv, cf_number_int, &w)) return error.DecodeFailed;
    if (!CFNumberGetValue(hv, cf_number_int, &h)) return error.DecodeFailed;
    if (w <= 0 or h <= 0) return error.DecodeFailed;
    return .{ .width = @intCast(w), .height = @intCast(h) };
}

/// 이미지 바이트를 RGBA8 로 푼다. `subsample` 은 1·2·4·8 만 뜻이 있다(`image_scale` 이 고른 값).
///
/// **크기는 ImageIO 가 정한다.** 서브샘플을 넣어도 결과 크기를 우리가 계산해 믿지 않고, 디코드된
/// `CGImage` 에게 물어본다 — 두 값이 갈리면 버퍼가 모자라거나 남는다.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, subsample: u8) Error!Decoded {
    if (!builtin.target.os.tag.isDarwin()) return error.Unsupported;
    if (bytes.len == 0) return error.DecodeFailed;

    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.DecodeFailed;
    defer CFRelease(data);

    const source = CGImageSourceCreateWithData(data, null) orelse return error.DecodeFailed;
    defer CFRelease(source);

    // 서브샘플 옵션은 1 일 때 만들지 않는다 — 빈 딕셔너리를 넘기는 것과 같고, 만드는 비용만 든다.
    var options: CFRef = null;
    defer if (options) |o| CFRelease(o);
    if (subsample > 1) {
        const factor: c_int = subsample;
        const number = CFNumberCreate(null, cf_number_int, &factor) orelse return error.DecodeFailed;
        defer CFRelease(number);
        const key: ?*const anyopaque = kCGImageSourceSubsampleFactor;
        const value: ?*const anyopaque = number;
        options = CFDictionaryCreate(
            null,
            @ptrCast(&key),
            @ptrCast(&value),
            1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        );
    }

    const image = CGImageSourceCreateImageAtIndex(source, 0, options) orelse return error.DecodeFailed;
    defer CGImageRelease(image);

    const w = CGImageGetWidth(image);
    const h = CGImageGetHeight(image);
    if (w == 0 or h == 0) return error.DecodeFailed;
    // 곱셈 오버플로우 방어. 상한 자체는 `image_scale` 이 이미 걸렀지만, 그 계산을 안 거친 호출도
    // 여기서 죽지 않아야 한다.
    const pixels_len = std.math.mul(usize, w, h) catch return error.DecodeFailed;
    const bytes_len = std.math.mul(usize, pixels_len, 4) catch return error.DecodeFailed;

    const out = allocator.alloc(u8, bytes_len) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    @memset(out, 0);

    const space = CGColorSpaceCreateDeviceRGB() orelse return error.DecodeFailed;
    defer CGColorSpaceRelease(space);

    const ctx = CGBitmapContextCreate(out.ptr, w, h, 8, w * 4, space, alpha_premultiplied_last) orelse
        return error.DecodeFailed;
    defer CGContextRelease(ctx);

    // **여기서 실제 픽셀이 만들어진다.** `CGImage` 는 지연 디코드라 만들기만 해서는 비용이 안 든다 —
    // 실측에서 「전체 디코드 0.0 ms」로 보였던 것이 그 함정이었다(2026-08-29).
    CGContextDrawImage(ctx, .{ .size = .{
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
    } }, image);

    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = out };
}

// ── 테스트 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 2×2 RGBA PNG — 빨강·초록 / 파랑·흰색. 합성이라 사용자 기록을 fixture 로 쓰지 않는다(계약 §6).
const png_2x2 = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d,
    0x24, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x0c, 0x81, 0x34, 0x18, 0x00, 0x00, 0x49, 0xc8, 0x09, 0xf7, 0xf9, 0xab, 0xb6, 0x0d, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

test "PNG 을 RGBA8 로 푼다 — 픽셀 값까지 본다" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    var img = try decode(testing.allocator, &png_2x2, 1);
    defer img.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), img.width);
    try testing.expectEqual(@as(u32, 2), img.height);
    try testing.expectEqual(@as(usize, 2 * 2 * 4), img.pixels.len);

    // **값을 본다.** 크기만 보면 «검은 이미지» 도 통과한다 — 실제로 그리는지 확인하는 것이 요점이다.
    // 첫 픽셀은 빨강(255,0,0,255). CoreGraphics 는 좌하단 원점이라 행 순서가 뒤집힐 수 있어
    // 「빨강이 어딘가에 있다」로 본다.
    var saw_red = false;
    var i: usize = 0;
    while (i + 3 < img.pixels.len) : (i += 4) {
        if (img.pixels[i] > 200 and img.pixels[i + 1] < 60 and img.pixels[i + 2] < 60) saw_red = true;
    }
    try testing.expect(saw_red);
}

test "서브샘플 계수를 넘겨도 죽지 않는다 — 작은 이미지는 그대로 온다" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    // 2×2 에 1/8 을 걸면 ImageIO 가 더 줄일 것이 없어 원본을 준다. **우리가 계산한 크기를 믿지 않고
    // `CGImage` 에게 묻는** 이유가 이것이다 — 믿었다면 버퍼가 어긋난다.
    var img = try decode(testing.allocator, &png_2x2, 8);
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, img.width * img.height * 4), img.pixels.len);
    try testing.expect(img.width >= 1 and img.height >= 1);
}

test "빈 바이트·쓰레기 바이트는 error 다 — 지어내지 않는다" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    try testing.expectError(error.DecodeFailed, decode(testing.allocator, &.{}, 1));
    try testing.expectError(error.DecodeFailed, decode(testing.allocator, "not an image at all", 1));
}

test "probeSize 는 디코드 없이 크기를 준다" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    const size = try probeSize(&png_2x2);
    try testing.expectEqual(@as(u32, 2), size.width);
    try testing.expectEqual(@as(u32, 2), size.height);
    try testing.expectError(error.DecodeFailed, probeSize("garbage"));
}
