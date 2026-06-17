//! **edge wedge·corner 삼각형** 합성: edge wedge U+1FB68~1FB6F(한 변을 밑변, 셀 중앙을 꼭짓점으로 하는 삼각형
//! — solid 4 + 반전 4)·bowtie U+1FB9A/1FB9B(두 wedge가 중앙에서 맞닿은 모래시계)·corner 삼각형(셀을 대각으로
//! 가른 반쪽 — solid ◢◣◤◥ U+25E2~25E5 + 50% 음영 🮜🮝🮞🮟 U+1FB9C~1FB9F). 정점이 셀 모서리·중앙이라 격자에
//! 칼같이 스냅된다(point-in-triangle 채움, 공유 `glyph_pixels.fillTriangle`/`fillTriangleAlpha`).
//!
//! 베이스 = Unicode "Symbols for Legacy Computing"(wedge·corner-shade)·"Geometric Shapes"(◢◣◤◥) 도형 정의.
//! Ghostty font/sprite 동작만 비교(코드 미복사 — clean-room). 중립 모듈.

const std = @import("std");
const gp = @import("glyph_pixels.zig");

/// wedge 방향 — 밑변이 되는 셀 변. 꼭짓점은 항상 셀 중앙이고 반대편을 가리킨다.
const Edge = enum { left, top, right, bottom };

/// 대각으로 가른 반쪽 삼각형의 채워진 모서리(◤=ul·◥=ur·◢=lr·◣=ll).
const Corner = enum { ul, ur, lr, ll };

/// cp가 edge wedge/bowtie인지(U+1FB68~1FB6F·U+1FB9A~1FB9B). 그 밖이면 폰트 폴백.
pub fn isLegacyWedge(cp: u32) bool {
    return (cp >= 0x1FB68 and cp <= 0x1FB6F) or (cp >= 0x1FB9A and cp <= 0x1FB9B);
}

/// cp가 대각 반쪽 corner 삼각형인지 — ◢◣◤◥(U+25E2~25E5, solid)·🮜🮝🮞🮟(U+1FB9C~1FB9F, 50% 음영).
pub fn isCornerTriangle(cp: u32) bool {
    return (cp >= 0x25E2 and cp <= 0x25E5) or (cp >= 0x1FB9C and cp <= 0x1FB9F);
}

/// cp wedge/bowtie/corner 삼각형을 width×height RGBA8 슬롯에 coverage로 채운다. 채운 픽셀 수 반환.
/// isLegacyWedge(cp) 또는 isCornerTriangle(cp) 가정. 버퍼 계약 위반 시 빈 글리프로 degrade.
pub fn fillCoverage(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) u32 {
    const w = width_px;
    const h = height_px;
    if (!gp.slotFits(w, h, bytes_per_row, pixels)) return 0;
    gp.clear(pixels, h, bytes_per_row);

    return switch (cp) {
        // 반전 wedge(U+1FB68~1FB6B): 삼각형 바깥(셀에서 wedge를 뺀 나머지)을 채운다.
        0x1FB68 => fillWedge(pixels, bytes_per_row, w, h, .left, true), // 🭨
        0x1FB69 => fillWedge(pixels, bytes_per_row, w, h, .top, true), // 🭩
        0x1FB6A => fillWedge(pixels, bytes_per_row, w, h, .right, true), // 🭪
        0x1FB6B => fillWedge(pixels, bytes_per_row, w, h, .bottom, true), // 🭫
        // solid wedge(U+1FB6C~1FB6F): 밑변=한 변, 꼭짓점=중앙.
        0x1FB6C => fillWedge(pixels, bytes_per_row, w, h, .left, false), // 🭬 ▶
        0x1FB6D => fillWedge(pixels, bytes_per_row, w, h, .top, false), // 🭭 ▼
        0x1FB6E => fillWedge(pixels, bytes_per_row, w, h, .right, false), // 🭮 ◀
        0x1FB6F => fillWedge(pixels, bytes_per_row, w, h, .bottom, false), // 🭯 ▲
        // bowtie: 두 solid wedge가 중앙에서 맞닿음.
        0x1FB9A => fillWedge(pixels, bytes_per_row, w, h, .top, false) +
            fillWedge(pixels, bytes_per_row, w, h, .bottom, false), // 🮚 세로 모래시계
        0x1FB9B => fillWedge(pixels, bytes_per_row, w, h, .left, false) +
            fillWedge(pixels, bytes_per_row, w, h, .right, false), // 🮛 가로 모래시계
        // solid corner 삼각형 ◢◣◤◥(U+25E2~25E5): 셀을 대각으로 가른 반쪽(alpha=0xFF).
        0x25E2 => fillCorner(pixels, bytes_per_row, w, h, .lr, 0xFF), // ◢ 우하
        0x25E3 => fillCorner(pixels, bytes_per_row, w, h, .ll, 0xFF), // ◣ 좌하
        0x25E4 => fillCorner(pixels, bytes_per_row, w, h, .ul, 0xFF), // ◤ 좌상
        0x25E5 => fillCorner(pixels, bytes_per_row, w, h, .ur, 0xFF), // ◥ 우상
        // 음영 corner 삼각형 🮜🮝🮞🮟(U+1FB9C~1FB9F): 같은 반쪽을 50% alpha(0x80)로.
        0x1FB9C => fillCorner(pixels, bytes_per_row, w, h, .ul, 0x80), // 🮜 좌상 음영
        0x1FB9D => fillCorner(pixels, bytes_per_row, w, h, .ur, 0x80), // 🮝 우상 음영
        0x1FB9E => fillCorner(pixels, bytes_per_row, w, h, .lr, 0x80), // 🮞 우하 음영
        0x1FB9F => fillCorner(pixels, bytes_per_row, w, h, .ll, 0x80), // 🮟 좌하 음영
        else => 0,
    };
}

// corner → 반쪽 삼각형 세 꼭짓점 {ax,ay,bx,by,cx,cy}(셀 분수). 셀 모서리 셋으로 대각 반쪽. 순서는 Corner enum과 일치.
const corner_tri = [4][6]f32{
    .{ 0, 0, 1, 0, 0, 1 }, // ◤ ul 좌상: 좌상·우상·좌하
    .{ 0, 0, 1, 0, 1, 1 }, // ◥ ur 우상: 좌상·우상·우하
    .{ 1, 0, 0, 1, 1, 1 }, // ◢ lr 우하: 우상·좌하·우하
    .{ 0, 0, 0, 1, 1, 1 }, // ◣ ll 좌하: 좌상·좌하·우하
};

/// 대각 반쪽 corner 삼각형을 alpha로 채운다 — ◤=ul·◥=ur·◢=lr·◣=ll. 빗변은 셀 대각선이라 격자에 스냅된다.
fn fillCorner(pixels: []u8, bytes_per_row: usize, w: u32, h: u32, corner: Corner, alpha: u8) u32 {
    const fw = @as(f32, @floatFromInt(w));
    const fh = @as(f32, @floatFromInt(h));
    const c = corner_tri[@intFromEnum(corner)];
    return gp.fillTriangleAlpha(pixels, bytes_per_row, w, h, c[0] * fw, c[1] * fh, c[2] * fw, c[3] * fh, c[4] * fw, c[5] * fh, false, alpha);
}

// edge → 밑변 두 끝점 {ax,ay,bx,by}(셀 분수: x·fw, y·fh). 순서는 Edge enum과 일치.
const edge_base = [4][4]f32{
    .{ 0, 0, 0, 1 }, // left 좌변
    .{ 0, 0, 1, 0 }, // top 상변
    .{ 1, 0, 1, 1 }, // right 우변
    .{ 0, 1, 1, 1 }, // bottom 하변
};

/// edge wedge를 채운다 — 밑변 = edge가 가리키는 셀 변(두 꼭짓점), 세 번째 꼭짓점 = 셀 중앙. invert면 바깥.
fn fillWedge(pixels: []u8, bytes_per_row: usize, w: u32, h: u32, edge: Edge, invert: bool) u32 {
    const fw = @as(f32, @floatFromInt(w));
    const fh = @as(f32, @floatFromInt(h));
    const e = edge_base[@intFromEnum(edge)];
    return gp.fillTriangle(pixels, bytes_per_row, w, h, fw / 2.0, fh / 2.0, e[0] * fw, e[1] * fh, e[2] * fw, e[3] * fh, invert);
}

test "isLegacyWedge·isCornerTriangle 범위" {
    try std.testing.expect(isLegacyWedge(0x1FB68));
    try std.testing.expect(isLegacyWedge(0x1FB6F));
    try std.testing.expect(isLegacyWedge(0x1FB9A));
    try std.testing.expect(isLegacyWedge(0x1FB9B));
    try std.testing.expect(!isLegacyWedge(0x1FB67)); // smooth mosaic(별도 모듈)
    try std.testing.expect(!isLegacyWedge(0x1FB70));
    try std.testing.expect(!isLegacyWedge(0x1FB99));
    try std.testing.expect(!isLegacyWedge(0x1FB9C)); // corner-shade는 isCornerTriangle
    // corner 삼각형: ◢◣◤◥(25E2~25E5)·🮜🮝🮞🮟(1FB9C~1FB9F).
    try std.testing.expect(isCornerTriangle(0x25E2));
    try std.testing.expect(isCornerTriangle(0x25E5));
    try std.testing.expect(isCornerTriangle(0x1FB9C));
    try std.testing.expect(isCornerTriangle(0x1FB9F));
    try std.testing.expect(!isCornerTriangle(0x25E1));
    try std.testing.expect(!isCornerTriangle(0x25E6));
    try std.testing.expect(!isCornerTriangle(0x1FB9B)); // bowtie는 isLegacyWedge
    try std.testing.expect(!isCornerTriangle(0x1FBA0));
}

test "fillCoverage: solid/반전 wedge·bowtie가 올바른 영역을 채운다" {
    const w: u32 = 8;
    const h: u32 = 16;
    const bpr: usize = w * 4;
    var pixels: [16 * 8 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;
    // 셀 중앙 (4,8).

    // 🭬 U+1FB6C left solid: 밑변=좌변·꼭짓점=중앙 → 좌-중앙 채움, 우측은 빔.
    _ = fillCoverage(0x1FB6C, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 1, 8)); // 좌-중앙 안
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 7, 8)); // 우-중앙 밖
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 7, 0)); // 우상 밖

    // 🭨 U+1FB68 left 반전: 위 wedge의 보색 → 좌-중앙 빔, 우측 채움.
    _ = fillCoverage(0x1FB68, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 1, 8)); // 좌-중앙 빔
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 7, 8)); // 우-중앙 채움

    // 🮚 U+1FB9A 세로 bowtie(top+bottom): 상-중앙·하-중앙 채움, 좌-중앙·우-중앙 빔.
    _ = fillCoverage(0x1FB9A, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 4, 1)); // 상-중앙
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 4, 14)); // 하-중앙
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 1, 8)); // 좌-중앙 빔
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 7, 8)); // 우-중앙 빔
}

test "fillCoverage: corner 삼각형 ◢◣◤◥(solid)·🮜🮝🮞🮟(50% alpha)" {
    const w: u32 = 8;
    const h: u32 = 8; // 정사각이라 대각선이 모서리↔모서리
    const bpr: usize = w * 4;
    var pixels: [8 * 8 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;

    // ◤ U+25E4 좌상 solid: 좌상 모서리 채움(alpha 0xFF), 우하 모서리 빔.
    _ = fillCoverage(0x25E4, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, 0)); // 좌상
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 7, 7)); // 우하 빔

    // ◢ U+25E2 우하 solid: 우하 채움, 좌상 빔.
    _ = fillCoverage(0x25E2, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 7, 7)); // 우하
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, 0)); // 좌상 빔

    // 🮜 U+1FB9C 좌상 50% 음영: 좌상 모서리가 alpha=0x80, 우하 빔.
    _ = fillCoverage(0x1FB9C, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0x80), a(&pixels, bpr, 0, 0)); // 좌상 음영
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 7, 7)); // 우하 빔
}
