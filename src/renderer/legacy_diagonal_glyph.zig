//! 대각선 **stroke** 글리프: 코너 대각선 U+1FBA0~1FBAE(다이아몬드 변 — 중앙선과 모서리중점을 잇는 선분 조합
//! 15개)와 cell 대각선 U+1FBD0~1FBDF(셀 정렬점 사이 대각 선분 16개). 채움이 아니라 **light 두께 선분 stroke**
//! (공유 `glyph_pixels.fillSegment`). 끝점이 셀 모서리·모서리중점·중앙이라 격자에 스냅돼 이웃 셀과 이어진다.
//!
//! 모든 끝점은 3×3 정렬 격자(0=UL,1=UC,2=UR,3=ML,4=MC,5=MR,6=LL,7=LC,8=LR; col=p%3·row=p/3 → x=col·½w·
//! y=row·½h)의 한 점이라 코너·cell 둘 다 점-쌍 선분으로 통일된다.
//!
//! 베이스 = Unicode "Symbols for Legacy Computing"의 대각선 도형(코너=중앙선↔모서리중점, cell=정렬점↔정렬점,
//! 이름에서 코드포인트↔선분 유도). Ghostty 동작만 비교(코드 미복사 — clean-room). 중립 모듈.

const std = @import("std");
const gp = @import("glyph_pixels.zig");

/// cp가 대각선 stroke 글리프인지(U+1FBA0~1FBAE·U+1FBD0~1FBDF). 그 밖이면 폰트 폴백.
pub fn isLegacyDiagonal(cp: u32) bool {
    return (cp >= 0x1FBA0 and cp <= 0x1FBAE) or (cp >= 0x1FBD0 and cp <= 0x1FBDF);
}

const Seg = struct { a: u8, b: u8 };

// 코너 대각선(U+1FBA0~1FBAE): 중앙선↔모서리중점 4선분의 조합. bit tl=1(UC-ML)·tr=2(UC-MR)·bl=4(LC-ML)·
// br=8(LC-MR). 코드포인트 순 마스크(Unicode 이름: 단일 4 → 두 변 6쌍 → 세 변 4 → 네 변).
const corner_mask = [15]u4{ 1, 2, 4, 8, 5, 10, 12, 3, 9, 6, 14, 13, 11, 7, 15 };
const corner_seg = [4]Seg{
    .{ .a = 1, .b = 3 }, // tl: UC-ML
    .{ .a = 1, .b = 5 }, // tr: UC-MR
    .{ .a = 7, .b = 3 }, // bl: LC-ML
    .{ .a = 7, .b = 5 }, // br: LC-MR
};

// cell 대각선(U+1FBD0~1FBDF): 정렬점 사이 선분 1~2개. Unicode 이름의 from→to(2-선분은 중간점 경유).
const cell_diag = [16][]const Seg{
    &.{.{ .a = 5, .b = 6 }}, // 🯐 1FBD0 MR→LL
    &.{.{ .a = 2, .b = 3 }}, // 🯑 1FBD1 UR→ML
    &.{.{ .a = 0, .b = 5 }}, // 🯒 1FBD2 UL→MR
    &.{.{ .a = 3, .b = 8 }}, // 🯓 1FBD3 ML→LR
    &.{.{ .a = 0, .b = 7 }}, // 🯔 1FBD4 UL→LC
    &.{.{ .a = 1, .b = 8 }}, // 🯕 1FBD5 UC→LR
    &.{.{ .a = 2, .b = 7 }}, // 🯖 1FBD6 UR→LC
    &.{.{ .a = 1, .b = 6 }}, // 🯗 1FBD7 UC→LL
    &.{ .{ .a = 0, .b = 4 }, .{ .a = 4, .b = 2 } }, // 🯘 1FBD8 UL→MC→UR
    &.{ .{ .a = 2, .b = 4 }, .{ .a = 4, .b = 8 } }, // 🯙 1FBD9 UR→MC→LR
    &.{ .{ .a = 6, .b = 4 }, .{ .a = 4, .b = 8 } }, // 🯚 1FBDA LL→MC→LR
    &.{ .{ .a = 0, .b = 4 }, .{ .a = 4, .b = 6 } }, // 🯛 1FBDB UL→MC→LL
    &.{ .{ .a = 0, .b = 7 }, .{ .a = 7, .b = 2 } }, // 🯜 1FBDC UL→LC→UR
    &.{ .{ .a = 2, .b = 3 }, .{ .a = 3, .b = 8 } }, // 🯝 1FBDD UR→ML→LR
    &.{ .{ .a = 6, .b = 1 }, .{ .a = 1, .b = 8 } }, // 🯞 1FBDE LL→UC→LR
    &.{ .{ .a = 0, .b = 5 }, .{ .a = 5, .b = 6 } }, // 🯟 1FBDF UL→MR→LL
};

/// cp 대각선 글리프를 width×height RGBA8 슬롯에 coverage로 stroke한다(light 두께). 채운 픽셀 수 반환.
/// isLegacyDiagonal(cp) 가정. 버퍼 계약 위반 시 빈 글리프로 degrade.
pub fn fillCoverage(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) u32 {
    const w = width_px;
    const h = height_px;
    if (!gp.slotFits(w, h, bytes_per_row, pixels)) return 0;
    gp.clear(pixels, h, bytes_per_row);

    // light 두께(box_glyph와 같은 공식 — 최소 1).
    var t: u32 = (h + 8) / 16;
    if (t < 1) t = 1;

    var count: u32 = 0;
    if (cp >= 0x1FBA0 and cp <= 0x1FBAE) {
        const m = corner_mask[cp - 0x1FBA0];
        for (corner_seg, 0..) |s, b| {
            if ((m >> @as(u2, @intCast(b))) & 1 != 0) count += drawSeg(pixels, bytes_per_row, w, h, s, t);
        }
    } else if (cp >= 0x1FBD0 and cp <= 0x1FBDF) {
        for (cell_diag[cp - 0x1FBD0]) |s| {
            count += drawSeg(pixels, bytes_per_row, w, h, s, t);
        }
    }
    return count;
}

/// 정렬점 두 개를 잇는 선분을 light 두께로 stroke. 점 p: col=p%3(0·½·1)·row=p/3(0·½·1) → (col·½w, row·½h).
fn drawSeg(pixels: []u8, bytes_per_row: usize, w: u32, h: u32, s: Seg, t: u32) u32 {
    const fw = @as(f32, @floatFromInt(w));
    const fh = @as(f32, @floatFromInt(h));
    const x0 = @as(f32, @floatFromInt(s.a % 3)) * fw / 2.0;
    const y0 = @as(f32, @floatFromInt(s.a / 3)) * fh / 2.0;
    const x1 = @as(f32, @floatFromInt(s.b % 3)) * fw / 2.0;
    const y1 = @as(f32, @floatFromInt(s.b / 3)) * fh / 2.0;
    return gp.fillSegment(pixels, bytes_per_row, w, h, x0, y0, x1, y1, t);
}

test "isLegacyDiagonal 범위·표 크기" {
    try std.testing.expect(isLegacyDiagonal(0x1FBA0));
    try std.testing.expect(isLegacyDiagonal(0x1FBAE));
    try std.testing.expect(isLegacyDiagonal(0x1FBD0));
    try std.testing.expect(isLegacyDiagonal(0x1FBDF));
    try std.testing.expect(!isLegacyDiagonal(0x1FB9F)); // corner-shade(별도)
    try std.testing.expect(!isLegacyDiagonal(0x1FBAF));
    try std.testing.expect(!isLegacyDiagonal(0x1FBCF));
    try std.testing.expect(!isLegacyDiagonal(0x1FBE0));
    try std.testing.expectEqual(@as(usize, 15), corner_mask.len);
    try std.testing.expectEqual(@as(usize, 16), cell_diag.len);
}

test "fillCoverage: 코너·cell 대각선이 올바른 선분을 긋는다" {
    const w: u32 = 32;
    const h: u32 = 32;
    const bpr: usize = w * 4;
    var pixels: [32 * 32 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;

    // 🮠 U+1FBA0 = tl(UC(16,0)-ML(0,16)): 그 선 위(8,8) 채움, 우상(30,1) 빔.
    _ = fillCoverage(0x1FBA0, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 8, 8)); // 선 위
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 30, 1)); // 선 밖

    // 🮮 U+1FBAE = 네 변 모두(다이아몬드 외곽): 변(8,8) 채움, 중앙(16,16) 빔(내부는 stroke 아님).
    _ = fillCoverage(0x1FBAE, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 8, 8)); // tl 변 위
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 16, 16)); // 중앙 빔

    // 🯒 U+1FBD2 = UL(0,0)-MR(32,16) 대각: 선 위(16,8) 채움, 좌하(1,30) 빔.
    _ = fillCoverage(0x1FBD2, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 16, 8)); // 선 위
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 1, 30)); // 선 밖
}
