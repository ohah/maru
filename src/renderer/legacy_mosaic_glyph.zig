//! Symbols for Legacy Computing — **블록 모자이크** 합성: sextant(U+1FB00~1FB3B, 2열×3행 6칸)·octant(U+1CD00~
//! 1CDE5, 2열×4행 8칸). 각 코드포인트는 하위 칸들의 켜짐 패턴이고, 켜진 칸마다 셀 하위 격자 사각형을 채운다
//! (Teletext·PETSCII식 터미널 그래픽). block_glyph(2×2 quadrant)을 더 잘게 쪼갠 격으로 셀 격자에 칼같이 스냅된다.
//!
//! 베이스 = Unicode "Symbols for Legacy Computing"(sextant)·"…Supplement"(octant)의 코드포인트↔패턴 배정.
//! sextant는 64패턴 중 이미 인코딩된 4개(space·▌·▐·█ = 패턴 0·21·42·63)를 건너뛴 60개라 닫힌 공식이 있다.
//! octant는 256패턴 중 이미 인코딩된 26개(space·반칸·4분면·full)를 건너뛴 230개를 **마스크 오름차순**으로 배정한다
//! (Unicode BLOCK OCTANT-* 이름 순서가 정확히 그러함을 확인). skip 집합만 데이터로 두고 표는 comptime 생성.
//! Ghostty font/sprite 동작만 비교(코드·데이터 파일 미복사 — clean-room). 중립 모듈.

const std = @import("std");
const gp = @import("glyph_pixels.zig");

/// cp가 sextant(2×3 모자이크, U+1FB00~1FB3B)인지.
pub fn isSextant(cp: u32) bool {
    return cp >= 0x1FB00 and cp <= 0x1FB3B;
}

/// cp가 octant(2×4 모자이크, U+1CD00~1CDE5)인지.
pub fn isOctant(cp: u32) bool {
    return cp >= 0x1CD00 and cp <= 0x1CDE5;
}

/// cp가 이 모듈이 합성하는 블록 모자이크(sextant·octant)인지. 그 밖이면 폰트 폴백.
pub fn isLegacyMosaic(cp: u32) bool {
    return isSextant(cp) or isOctant(cp);
}

// octant에서 건너뛰는 26개 패턴 — 이미 별도 코드포인트로 인코딩된 것들(space·반칸·4분면·full block). 이 26개를
// 제외한 230개를 마스크 오름차순으로 U+1CD00부터 배정(Unicode 표준 순서)이라 skip 집합만 데이터로 둔다. 배열
// **순서는 무의미**(membership만 씀)하므로 의미별로 묶었다. 셀=bit+1, 2열×4행(좌열 1·3·5·7, 우열 2·4·6·8).
const octant_skip = [_]u8{
    0, // space(빈 칸)
    255, // █ full block(8칸 전부)
    15, // ▀ upper half(상2행)
    240, // ▄ lower half(하2행)
    85, // ▌ left half(좌열)
    170, // ▐ right half(우열)
    5, 10, 80, 160, // ▘▝▖▗ 단일 4분면(상좌·상우·하좌·하우)
    90, 165, // ▞▚ 대각 4분면쌍
    95, 175, 245, 250, // ▛▜▙▟ 3-quadrant
    1, 2, 64, 128, // 모서리 1/8(상좌·상우·하좌·하우 단일 칸)
    3, 192, // 상·하 1/4(한 행)
    20, 40, // 중간 두 행의 좌·우열 칸쌍
    63, 252, // upper·lower 3/4
};

/// idx(0~229) → octant 마스크(0~255 중 skip 제외 마스크 오름차순). comptime 생성(파일 미복사).
const octant_mask = blk: {
    @setEvalBranchQuota(10000); // 256패턴 × skip 검사라 기본 1000 분기 한도를 넘는다.
    var table: [230]u8 = undefined;
    var n: usize = 0;
    var v: u9 = 0;
    while (v < 256) : (v += 1) {
        var skipped = false;
        for (octant_skip) |s| {
            if (@as(u9, s) == v) {
                skipped = true;
                break;
            }
        }
        if (!skipped) {
            table[n] = @intCast(v);
            n += 1;
        }
    }
    if (n != 230) @compileError("octant 표 230개가 아님 — skip 집합 확인");
    break :blk table;
};

/// cp 블록 모자이크를 width×height RGBA8 슬롯에 coverage로 채운다(흰색 불투명). 채운 픽셀 수 반환.
/// isLegacyMosaic(cp) 가정. 버퍼 계약 위반 시 빈 글리프로 degrade.
pub fn fillCoverage(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) u32 {
    const w = width_px;
    const h = height_px;
    if (!gp.slotFits(w, h, bytes_per_row, pixels)) return 0;
    gp.clear(pixels, h, bytes_per_row);

    if (isSextant(cp)) {
        // 64패턴 중 {0,21,42,63}(space·▌·▐·█)을 건너뛴 60개 → pattern = idx + idx/20 + 1.
        const idx = cp - 0x1FB00;
        const pattern = idx + idx / 20 + 1;
        return fillGrid(pixels, bytes_per_row, w, h, 2, 3, pattern);
    }
    if (isOctant(cp)) {
        const idx = cp - 0x1CD00;
        return fillGrid(pixels, bytes_per_row, w, h, 2, 4, octant_mask[idx]);
    }
    return 0;
}

/// cols×rows 하위 격자에서 mask의 켜진 칸(bit b → 열 b%cols·행 b/cols)을 사각형으로 채운다(row-major). 칸 경계는
/// 정수 나눗셈으로 스냅(마지막 열/행이 w/h에 정확히 닿음). 칸끼리 안 겹쳐 회계 단순.
fn fillGrid(pixels: []u8, bytes_per_row: usize, w: u32, h: u32, cols: u32, rows: u32, mask: u32) u32 {
    var count: u32 = 0;
    var b: u32 = 0;
    while (b < cols * rows) : (b += 1) {
        if ((mask >> @as(u5, @intCast(b))) & 1 == 0) continue;
        const col = b % cols;
        const row = b / cols;
        const x0 = col * w / cols;
        const x1 = (col + 1) * w / cols;
        const y0 = row * h / rows;
        const y1 = (row + 1) * h / rows;
        count += gp.fillRect(pixels, bytes_per_row, x0, y0, x1, y1);
    }
    return count;
}

test "isSextant·isOctant·isLegacyMosaic 범위" {
    try std.testing.expect(isSextant(0x1FB00));
    try std.testing.expect(isSextant(0x1FB3B));
    try std.testing.expect(!isSextant(0x1FB3C)); // smooth mosaic(후속)
    try std.testing.expect(isOctant(0x1CD00));
    try std.testing.expect(isOctant(0x1CDE5));
    try std.testing.expect(!isOctant(0x1CDE6));
    try std.testing.expect(isLegacyMosaic(0x1FB00) and isLegacyMosaic(0x1CD00));
    try std.testing.expect(!isLegacyMosaic(0x2588)); // block(별도 모듈)
}

test "octant 표: 230개·마스크 오름차순·첫=4(OCTANT-3)·끝=254(OCTANT-2345678)" {
    try std.testing.expectEqual(@as(usize, 230), octant_mask.len);
    try std.testing.expectEqual(@as(u8, 4), octant_mask[0]); // U+1CD00 = 셀3 = bit2
    try std.testing.expectEqual(@as(u8, 254), octant_mask[229]); // U+1CDE5 = 셀2~8
    var i: usize = 1;
    while (i < octant_mask.len) : (i += 1) {
        try std.testing.expect(octant_mask[i] > octant_mask[i - 1]); // 오름차순
    }
}

test "fillCoverage: sextant tl·octant 셀3/셀2~8가 올바른 하위 격자 칸을 채운다" {
    const w: u32 = 8;
    const h: u32 = 24; // 2×3·2×4 둘 다 정수로 떨어지게(h/3=8, h/4=6)
    const bpr: usize = w * 4;
    var pixels: [24 * 8 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;

    // sextant U+1FB00 = pattern 1 = bit0 = tl(좌상, 2×3의 col0row0 = x[0,4] y[0,8]).
    _ = fillCoverage(0x1FB00, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 1, 1)); // tl 안
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 6, 1)); // tr 빔
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 1, 20)); // bl 빔

    // octant U+1CD00 = 마스크 4 = 셀3 = 2×4의 col0row1 = x[0,4] y[6,12].
    _ = fillCoverage(0x1CD00, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 1, 8)); // 셀3 안
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 1, 1)); // 셀1(좌상) 빔
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 6, 1)); // 셀2(우상) 빔

    // octant U+1CDE5 = 마스크 254 = 셀2~8(셀1만 꺼짐). 셀1 좌상만 빈다.
    _ = fillCoverage(0x1CDE5, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 1, 1)); // 셀1 빔
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 6, 1)); // 셀2 채움
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 1, 22)); // 셀7 채움
}
