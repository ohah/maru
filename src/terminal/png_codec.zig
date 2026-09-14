//! wuffs PNG 디코더로 가는 Zig 쪽 문. C 셰임(`png_wuffs.c`)이 노출하는 평평한 함수 셋만 부른다.
//!
//! **왜 별도 모듈인가.** C 번역 단위를 `maru` 모듈에 직접 매달면 그 모듈에 붙는 **다른** C·ObjC
//! 파일까지 wuffs 셰임 헤더(`wuffs_cshim/`)를 보게 된다 — 그쪽은 진짜 libc 헤더가 필요하다.
//! 모듈을 갈라 두면 셰임 include 경로가 이 파일 하나에만 닿는다.
//!
//! **할당은 여기서 하지 않는다.** 호출자(`png.zig`)가 코어의 이미지 총량 회계 안에서 버퍼를 쥐고
//! 들어온다. 디코더 구조체까지 호출자가 준다 — 그래야 libc 할당자가 전혀 필요 없고
//! wasm32-freestanding 에서 링크가 선다(`png_wuffs.c` 머리말).

const std = @import("std");

/// C 셰임의 반환 코드와 1:1. 열린 enum이 아니다 — 셰임이 이 넷만 낸다.
pub const Status = enum(i32) {
    ok = 0,
    malformed = 1,
    unsupported = 2,
    too_big = 3,
};

/// `probe`가 알려주는 것 — 치수와 임시 버퍼 크기.
///
/// **픽셀 버퍼 크기는 여기 없다.** 호출자가 `width*height*4` 로 직접 계산한다 — 그 산술이 총량
/// 회계와 같은 자리에 있어야 하고, 계산이 어긋나면 `decode` 가 `.too_big` 으로 거절한다.
pub const Probe = struct {
    width: u32,
    height: u32,
    /// wuffs 가 디코드 중 쓰는 임시 버퍼. PNG 는 스캔라인 하나 정도라 작다(실측: 2×2 에서 6 B).
    workbuf_len: u64,
};

extern fn maru_png_decoder_size() usize;
extern fn maru_png_probe(
    dec_mem: [*]u8,
    dec_len: usize,
    src: [*]const u8,
    src_len: usize,
    out_w: *u32,
    out_h: *u32,
    out_workbuf_len: *u64,
) i32;
extern fn maru_png_decode(
    dec_mem: [*]u8,
    dec_len: usize,
    src: [*]const u8,
    src_len: usize,
    pixels: [*]u8,
    pixels_len: usize,
    workbuf: [*]u8,
    workbuf_len: usize,
) i32;

/// 디코더 구조체가 요구하는 바이트 수(실측 44,632 B — 스택에 두기엔 크다).
pub fn decoderSize() usize {
    return maru_png_decoder_size();
}

/// 디코더 구조체 정렬. wuffs 구조체 안에 u64·SIMD 필드가 있으므로 넉넉히 잡는다.
pub const decoder_align: std.mem.Alignment = .@"16";

fn toStatus(rc: i32) Status {
    return switch (rc) {
        0 => .ok,
        1 => .malformed,
        2 => .unsupported,
        else => .too_big,
    };
}

/// 머리(IHDR 등)만 읽는다. 픽셀은 건드리지 않으므로 **큰 이미지를 거절하기 전에** 부를 수 있다.
pub fn probe(decoder: []u8, src: []const u8) union(enum) { ok: Probe, err: Status } {
    if (src.len == 0) return .{ .err = .malformed };
    var out: Probe = .{ .width = 0, .height = 0, .workbuf_len = 0 };
    const rc = maru_png_probe(
        decoder.ptr,
        decoder.len,
        src.ptr,
        src.len,
        &out.width,
        &out.height,
        &out.workbuf_len,
    );
    if (rc != 0) return .{ .err = toStatus(rc) };
    return .{ .ok = out };
}

/// `probe`가 알려준 크기의 버퍼에 RGBA 로 푼다. `pixels`·`workbuf`는 그 길이여야 한다.
pub fn decode(decoder: []u8, src: []const u8, pixels: []u8, workbuf: []u8) Status {
    if (src.len == 0) return .malformed;
    return toStatus(maru_png_decode(
        decoder.ptr,
        decoder.len,
        src.ptr,
        src.len,
        pixels.ptr,
        pixels.len,
        workbuf.ptr,
        workbuf.len,
    ));
}
