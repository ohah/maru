//! 최소 PNG 디코더 (kitty graphics `f=100`용, K3c). **8-bit truecolor만** 지원한다:
//! color type 2(RGB, bpp=3)·6(RGBA, bpp=4), bit depth 8, non-interlaced. 나머지 변종
//! (grayscale 0/4·palette 3·16-bit·Adam7 interlace)은 `error.Unsupported`로 graceful 거부한다
//! (깨진 이미지/크래시 대신). 풀 PNG(전 color type·16-bit)는 라이브러리 벤더링 백로그
//! (docs/plans/terminal-input-and-protocols.md "kitty graphics PNG 백로그") — Ghostty도 wuffs C 라이브러리로 처리한다.
//!
//! clean-room: PNG 명세(W3C PNG, RFC 2083)에서 직접 작성했다 — 청크 구조(length+type+data+CRC),
//! IHDR 필드, IDAT zlib 스트림, 스캔라인 필터(None/Sub/Up/Average/Paeth). IDAT 압축 해제는 Zig
//! 표준 `std.compress.flate(.zlib)`를 쓴다. 신뢰 불가 입력(PTY/원격)이므로 모든 길이·범위·곱을
//! 검증해 OOB read/overflow를 막는다(코덱 메모리 안전).

const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    bpp: u8, // 3(RGB) / 4(RGBA)
    data: []u8, // 호출자 소유(width*height*bpp)
};

pub const Error = error{ Unsupported, Malformed } || std.mem.Allocator.Error;

const signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
/// 디코드 픽셀 상한 — 악의적 대형 PNG 거부(이미지 저장소 320MB 한계와 정합).
const max_output_bytes: usize = 320 * 1000 * 1000;

/// PNG 바이트를 RGB/RGBA 픽셀로 디코드한다. 성공 시 Image(픽셀 소유). 미지원 변종·malformed는 에러.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) return error.Malformed;

    var width: u32 = 0;
    var height: u32 = 0;
    var bpp: u8 = 0;
    var have_ihdr = false;
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(allocator);

    var pos: usize = 8;
    while (pos + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const ctype = bytes[pos + 4 ..][0..4];
        const data_start = pos + 8;
        const data_end = std.math.add(usize, data_start, len) catch return error.Malformed;
        if (data_end + 4 > bytes.len) return error.Malformed; // 데이터 + CRC(4)가 버퍼 안이어야
        const data = bytes[data_start..data_end];

        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (have_ihdr or len != 13) return error.Malformed;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            const bit_depth = data[8];
            const color_type = data[9];
            const comp_method = data[10];
            const filter_method = data[11];
            const interlace = data[12];
            if (width == 0 or height == 0) return error.Malformed;
            if (comp_method != 0 or filter_method != 0) return error.Malformed; // PNG 표준은 0만 정의
            if (interlace != 0) return error.Unsupported; // Adam7 미지원(K3c)
            if (bit_depth != 8) return error.Unsupported; // 8-bit만(K3c)
            bpp = switch (color_type) {
                2 => 3, // truecolor RGB
                6 => 4, // truecolor + alpha RGBA
                else => return error.Unsupported, // grayscale(0/4)·palette(3)는 미지원(K3c)
            };
            have_ihdr = true;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            if (!have_ihdr) return error.Malformed;
            try idat.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            break;
        }
        // 그 외(ancillary: tEXt/pHYs/gAMA 등) 청크는 건너뛴다.
        pos = data_end + 4; // + CRC
    }
    if (!have_ihdr or idat.items.len == 0) return error.Malformed;

    // 출력/필터 버퍼 크기(오버플로·상한 검증).
    const row_bytes = std.math.mul(usize, width, bpp) catch return error.Malformed;
    const out_size = std.math.mul(usize, row_bytes, height) catch return error.Malformed;
    if (out_size == 0 or out_size > max_output_bytes) return error.Unsupported;
    const filtered_stride = row_bytes + 1; // 행마다 필터바이트 1 + row_bytes
    const filtered_size = std.math.mul(usize, filtered_stride, height) catch return error.Malformed;

    // IDAT(zlib) 스트림을 필터된 스캔라인으로 inflate(정확히 filtered_size — 메모리 바운드).
    const filtered = try inflateExact(allocator, idat.items, filtered_size);
    defer allocator.free(filtered);

    // 언필터 → 픽셀(필터바이트 제거).
    const out = try allocator.alloc(u8, out_size);
    errdefer allocator.free(out);
    try unfilter(filtered, out, height, row_bytes, bpp);

    return .{ .width = width, .height = height, .bpp = bpp, .data = out };
}

/// zlib 스트림을 정확히 expected 바이트로 inflate한다(더/덜이면 malformed). 메모리는 expected로 바운드.
/// kitty graphics의 zlib(o=z) 픽셀 경로(core.zig)와 PNG의 IDAT 경로가 같은 exact-inflate를 공유한다 —
/// 둘 다 정확히 expected로 풀려야 하고, 부족하면(short)·더 풀리면(over-long) malformed로 거부해 zlib
/// bomb를 expected 바이트로 바운드한다.
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

/// 필터된 스캔라인을 in-place 재구성해 out(필터바이트 없는 픽셀)으로 푼다. 필터: 0 None/1 Sub/2 Up/
/// 3 Average/4 Paeth. a=왼쪽 픽셀, b=위 픽셀, c=좌상단 픽셀(경계는 0). 베이스: PNG 명세 §9 Filtering.
fn unfilter(filtered: []const u8, out: []u8, height: u32, row_bytes: usize, bpp: u8) Error!void {
    const stride = row_bytes + 1;
    var r: usize = 0;
    while (r < height) : (r += 1) {
        const ft = filtered[r * stride];
        const src = filtered[r * stride + 1 ..][0..row_bytes];
        const dst = out[r * row_bytes ..][0..row_bytes];
        const prev: ?[]const u8 = if (r == 0) null else out[(r - 1) * row_bytes ..][0..row_bytes];
        var i: usize = 0;
        while (i < row_bytes) : (i += 1) {
            const raw = src[i];
            const a: u8 = if (i >= bpp) dst[i - bpp] else 0;
            const b: u8 = if (prev) |p| p[i] else 0;
            const c: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
            dst[i] = switch (ft) {
                0 => raw,
                1 => raw +% a,
                2 => raw +% b,
                3 => raw +% @as(u8, @intCast((@as(u16, a) + @as(u16, b)) / 2)),
                4 => raw +% paeth(a, b, c),
                else => return error.Malformed, // 알 수 없는 필터 타입
            };
        }
    }
}

/// PNG Paeth predictor(명세 §9.4) — a/b/c 중 p=a+b-c에 가장 가까운 값.
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = iabs(p - @as(i32, a));
    const pb = iabs(p - @as(i32, b));
    const pc = iabs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn iabs(x: i32) i32 {
    return if (x < 0) -x else x;
}
