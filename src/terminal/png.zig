//! PNG 디코드 (kitty graphics `f=100` · `window.background-image` F2-1).
//!
//! **전 color type·bit depth·인터레이스를 받는다** — palette(3)·grayscale(0/4)·truecolor(2/6),
//! 8/16-bit, Adam7 모두. 디코드는 **wuffs**(Google, 메모리 안전 코덱 언어에서 생성된 C)가 하고
//! 여기서는 ⑴ 총량 회계 ⑵ 버퍼 소유 ⑶ 에러 환산만 한다. 배선은 `png_codec.zig`.
//!
//! **왜 손으로 안 짜나.** 예전 이 파일은 8-bit truecolor 만 푸는 clean-room 디코더였고 나머지는
//! `error.Unsupported` 로 거절했다 — 즉 화면에 이미지가 그냥 안 떴다. 남은 변종을 손으로 채우려면
//! 색 변환·인터레이스·16-bit 를 전부 우리가 지켜야 하는데, 그 코드가 다루는 것은 **신뢰 경계 밖의
//! 바이너리**(PTY·원격)다. wuffs 는 그 자리를 위해 만들어진 물건이고 Ghostty 도 같은 선택을 했다.
//!
//! **출력은 언제나 RGBA 8-bit**(`bpp = 4`)다. 색 종류 분기가 코어에서 사라졌다.

const std = @import("std");
const png_codec = @import("png_codec");

pub const Image = struct {
    width: u32,
    height: u32,
    bpp: u8, // 언제나 4(RGBA) — wuffs 가 색 종류를 흡수한다
    data: []u8, // 호출자 소유(width*height*4)
};

pub const Error = error{ Unsupported, Malformed } || std.mem.Allocator.Error;

/// 디코드 픽셀 상한 — 악의적 대형 PNG 거부(이미지 저장소 320MB 한계와 정합).
const max_output_bytes: usize = 320 * 1000 * 1000;

/// PNG 바이트를 **RGBA** 픽셀로 디코드한다. 성공 시 Image(픽셀 소유). malformed·과대 이미지는 에러.
///
/// 두 단계다: ① 머리만 읽어 치수와 필요한 버퍼 크기를 받고 ② 총량 한계를 넘지 않을 때만 할당해
/// 푼다. 그래서 **10만×10만 PNG 헤더 하나로 메모리를 요구받지 않는다** — 거절이 할당보다 앞선다.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Image {
    const decoder = try allocator.alignedAlloc(u8, png_codec.decoder_align, png_codec.decoderSize());
    defer allocator.free(decoder);

    const info = switch (png_codec.probe(decoder, bytes)) {
        .ok => |p| p,
        .err => |st| return statusError(st),
    };
    // **총량 회계를 픽셀 수로 센다.** `w`·`h` 는 신뢰 경계 밖에서 온 값이고 wuffs 는 16,777,215
    // 까지 통과시킨다(실측: 16777215×16777215 헤더가 probe 를 지난다 — 1.13 PB 짜리 이미지다).
    // 여기서 자르고 나면 뒤따르는 `cells * 4` 가 **무슨 값이 와도** u64 안이다. 오늘은 wuffs 의
    // 내부 상한 덕에 그 곱이 넘칠 일이 없지만, 그 상한은 **우리가 소유한 불변식이 아니다** —
    // 상류가 넓히면 조용히 #531(치수 곱 오버플로 crash)이 돌아온다. 순서로 막아 둔다.
    const cells = @as(u64, info.width) * @as(u64, info.height); // u32×u32 는 u64 안이다
    if (cells == 0 or cells > max_output_bytes / 4) return error.Unsupported;

    // **버퍼 크기를 우리가 정한다.** 호출자(렌더러)가 stride 를 폭에서 계산하므로 `data.len` 은
    // 반드시 `w*h*4` 여야 한다. 그래서 그 값으로 잡고, 만약 wuffs 가 더 필요로 하면 디코드가
    // `.too_big` 으로 **거절한다** — 어긋난 stride 로 조용히 그리는 대신 fail-closed 다.
    // workbuf 는 스캔라인 규모다(실측: 2×2 에서 6 B). 그래도 상한은 같은 회계로 묶고, **거절은
    // 전부 할당 앞에 모아 둔다** — 하나라도 뒤로 새면 「거절이 먼저」라는 계약이 그 갈래에서만 깨진다.
    if (info.workbuf_len > max_output_bytes) return error.Unsupported;

    const pixels = try allocator.alloc(u8, @intCast(cells * 4));
    errdefer allocator.free(pixels);
    const workbuf = try allocator.alloc(u8, @intCast(info.workbuf_len));
    defer allocator.free(workbuf);

    switch (png_codec.decode(decoder, bytes, pixels, workbuf)) {
        .ok => {},
        else => |st| return statusError(st),
    }
    return .{ .width = info.width, .height = info.height, .bpp = 4, .data = pixels };
}

fn statusError(st: png_codec.Status) Error {
    return switch (st) {
        // `ok` 는 호출자가 이미 걸러 낸다 — 여기 오면 셰임 계약이 깨진 것이라 malformed 로 본다.
        .ok, .malformed => error.Malformed,
        .unsupported, .too_big => error.Unsupported,
    };
}

/// zlib 스트림을 정확히 expected 바이트로 inflate한다(더/덜이면 malformed). 메모리는 expected로 바운드.
/// kitty graphics의 zlib(o=z) 픽셀 경로(`kitty.zig`)가 쓴다. 정확히 expected로 풀려야 하고,
/// 부족하면(short)·더 풀리면(over-long) malformed로 거부해 zlib bomb를 expected 바이트로 바운드한다.
/// **PNG 자신은 이걸 안 쓴다** — IDAT 은 wuffs 안에서 풀린다. 이름이 `png.zig` 에 남은 것은 호출자가
/// 여기를 보고 있어서다.
pub fn inflateExact(allocator: std.mem.Allocator, compressed: []const u8, expected: usize) Error![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&in, .zlib, &window);
    const out = try allocator.alloc(u8, expected);
    errdefer allocator.free(out);
    decomp.reader.readSliceAll(out) catch return error.Malformed; // 부족하면 malformed
    // 더 풀리면(over-long) 불일치 — 거부(한 바이트만 더 시도해 메모리 바운드 유지).
    var extra: [1]u8 = undefined;
    const n = decomp.reader.readSliceShort(&extra) catch 0;
    if (n != 0) return error.Malformed;
    return out;
}

// ── 판정자 ───────────────────────────────────────────────────────────────────
//
// 변종별 픽셀 값은 `core.zig` 의 kitty `f=100` 판정자들이 잰다(프로토콜 경로 전체를 지난다).
// 여기서는 **그 경로로는 안 보이는 것** 둘만 본다: 거절이 할당보다 앞서는가, 그리고 셰임의
// 디코더 버퍼 계약이 실제로 「이만큼 이상」인가.

/// 요청된 **가장 큰 단일 할당**을 기록하는 래퍼. 「거절이 할당보다 앞선다」를 결과가 아니라
/// 동작으로 재기 위해 필요하다 — 결과만 보면 17 GB 를 잡아 놓고 실패해도 똑같이 초록이다.
const PeakAllocator = struct {
    inner: std.mem.Allocator,
    peak: usize = 0,

    fn allocator(self: *PeakAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        if (len > self.peak) self.peak = len;
        return self.inner.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > self.peak) self.peak = new_len;
        return self.inner.rawResize(buf, a, new_len, ra);
    }
    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > self.peak) self.peak = new_len;
        return self.inner.rawRemap(buf, a, new_len, ra);
    }
    fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(buf, a, ra);
    }
};

/// 68 바이트 PNG 가 65535×65535 RGBA 라고 말한다 — 픽셀로는 17.2 GB 다.
const huge_header_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF,
    0x08, 0x06, 0x00, 0x00, 0x00, 0xB6, 0x05, 0xD9, 0x50, 0x00, 0x00, 0x00,
    0x0B, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, 0x40, 0x05, 0x00,
    0x00, 0x10, 0x00, 0x01, 0xAA, 0x19, 0xF8, 0x82, 0x00, 0x00, 0x00, 0x00,
    0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

/// 16,777,215 × 16,777,215 RGBA — **probe 를 통과하는** 최대 치수다(실측). 픽셀로는 1.13 PB 이고
/// `w*h*4` 는 u64 를 넘길 수 있는 자리다.
const max_dims_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0xFF,
    0x08, 0x06, 0x00, 0x00, 0x00, 0xA6, 0x57, 0xAE, 0xD3, 0x00, 0x00, 0x00,
    0x0B, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, 0x80, 0x00, 0x00,
    0x00, 0x08, 0x00, 0x01, 0x24, 0xFC, 0x04, 0x72, 0x00, 0x00, 0x00, 0x00,
    0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

test "PNG: probe 가 통과시키는 최대 치수도 거절한다 (16,777,215² = 1.13 PB)" {
    // **이것이 「거절선 앞의 마지막 한 칸」이다.** 이보다 큰 헤더는 wuffs 가 먼저 거절하므로
    // 우리 코드에 도달하지 못한다(실측: 2^31-1 은 probe 에서 막힌다). 즉 우리 게이트가 실제로
    // 물어야 하는 가장 큰 값이 여기다. 거절이 없으면 1.13 PB 를 요구한다(실측: OutOfMemory).
    var peak: PeakAllocator = .{ .inner = std.testing.allocator };
    try std.testing.expectError(error.Unsupported, decode(peak.allocator(), &max_dims_png));
    try std.testing.expect(peak.peak < 1 << 20);
}

test "PNG: 과대 헤더는 픽셀 버퍼를 잡기 전에 거절한다 (결과가 아니라 동작을 잰다)" {
    var peak: PeakAllocator = .{ .inner = std.testing.allocator };
    try std.testing.expectError(error.Unsupported, decode(peak.allocator(), &huge_header_png));

    // 거절이 할당보다 **앞서야** 한다. 디코더 구조체(≈45 KB) 말고는 아무것도 잡지 않는다.
    // 이 단언이 없으면 17 GB 를 요청해 놓고 실패해도 판정자가 초록으로 남는다(실측: 그 변이가
    // `core.zig` 쪽 판정자를 통과했다).
    try std.testing.expect(peak.peak < 1 << 20);
    try std.testing.expect(peak.peak >= png_codec.decoderSize());
}

test "PNG: 디코더 버퍼 계약은 «이만큼 이상» 이다 (셰임이 정확한 크기를 맞춘다)" {
    // wuffs 의 `initialize` 는 크기가 **정확히** 같기를 요구한다. 셰임이 그 차이를 흡수하지 않으면
    // 넉넉히 준 버퍼가 거절당한다 — 제품은 딱 맞게 주므로 이 갈래는 여기서만 드러난다.
    const gray_2x2 = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
        0x08, 0x00, 0x00, 0x00, 0x00, 0x57, 0xDD, 0x52, 0xF8, 0x00, 0x00, 0x00,
        0x0E, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x70, 0x60, 0x68,
        0xF8, 0x0F, 0x00, 0x03, 0x05, 0x01, 0xC0, 0x4E, 0x33, 0x5B, 0xE9, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };
    const roomy = try std.testing.allocator.alignedAlloc(u8, png_codec.decoder_align, png_codec.decoderSize() + 4096);
    defer std.testing.allocator.free(roomy);
    switch (png_codec.probe(roomy, &gray_2x2)) {
        .ok => |info| {
            try std.testing.expectEqual(@as(u32, 2), info.width);
            try std.testing.expectEqual(@as(u32, 2), info.height);
        },
        .err => return error.RoomyDecoderBufferRejected,
    }

    // **음성 대조**: 모자란 버퍼는 거절한다 — 위가 「크기를 아예 안 본다」로 통과한 게 아니다.
    switch (png_codec.probe(roomy[0 .. png_codec.decoderSize() - 1], &gray_2x2)) {
        .ok => return error.ShortDecoderBufferAccepted,
        .err => |st| try std.testing.expectEqual(png_codec.Status.unsupported, st),
    }
}
