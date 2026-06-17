//! Braille Patterns(U+2800~28FF) 글리프 합성 — 한 셀에 2열×4행 8점, 코드포인트 **하위 8비트가 점 비트마스크**다
//! (`U+2800 + mask`). btop·plotille 같은 TUI가 셀 격자에 칼같이 스냅된 고밀도 점으로 그래프를 그리므로 폰트
//! 폴백 대신 직접 그린다(폰트 글리프는 셀에 안 맞아 점 간격·정렬이 흔들린다). 둥근 점(거리 ≤ r)으로 채운다.
//!
//! 점 번호(Unicode 표준):  점1 점4 / 점2 점5 / 점3 점6 / 점7 점8 → 2열×4행. bitN(0-기준) = 점(N+1).
//! 베이스 = Unicode Braille Patterns dot 번호. Ghostty font/sprite 동작만 비교(코드 미복사 — clean-room). 중립 모듈.

const std = @import("std");
const gp = @import("glyph_pixels.zig");

/// cp가 Braille 패턴(U+2800~28FF)인지. 그 밖이면 false → 폰트 폴백.
pub fn isBraille(cp: u32) bool {
    return cp >= 0x2800 and cp <= 0x28FF;
}

// bit(0~7) → (열 0|1, 행 0~3). 점1~3=좌열 위에서 3, 점4~6=우열 위에서 3, 점7=좌열 맨아래, 점8=우열 맨아래.
const dot_col = [8]u32{ 0, 0, 0, 1, 1, 1, 0, 1 };
const dot_row = [8]u32{ 0, 1, 2, 0, 1, 2, 3, 3 };

/// cp Braille 글리프를 width×height RGBA8 슬롯에 coverage로 채운다(흰색 불투명 0xFFFFFFFF — 셰이더가 alpha를
/// coverage로 읽어 전경색으로). 채운 픽셀 수 반환. isBraille(cp) 가정. 버퍼 계약 위반 시 빈 글리프로 degrade.
/// U+2800(mask=0)은 점이 하나도 없어 빈 셀(0px)로 둔다.
pub fn fillCoverage(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) u32 {
    const w = width_px;
    const h = height_px;
    if (!gp.slotFits(w, h, bytes_per_row, pixels)) return 0;
    if (!isBraille(cp)) return 0;
    gp.clear(pixels, h, bytes_per_row);

    const mask: u8 = @truncate(cp - 0x2800);
    if (mask == 0) return 0; // 빈 점 패턴(공백)

    const fw = @as(f32, @floatFromInt(w));
    const fh = @as(f32, @floatFromInt(h));
    // 점 중심: 열 c∈{0,1}→(2c+1)/4·w(=¼·¾), 행 r∈{0..3}→(2r+1)/8·h(=⅛·⅜·⅝·⅞). 미리 계산.
    var cxs: [8]f32 = undefined;
    var cys: [8]f32 = undefined;
    for (0..8) |b| {
        cxs[b] = (@as(f32, @floatFromInt(2 * dot_col[b] + 1)) / 4.0) * fw;
        cys[b] = (@as(f32, @floatFromInt(2 * dot_row[b] + 1)) / 8.0) * fh;
    }
    // 점 반지름: 점 간격(가로 ¼w·세로 ⅛h… pitch=½w·¼h)의 ~0.38배라 점이 분리되고 셀 경계에 안 닿는다(최소 0.5px).
    const r = @max(0.5, @min(fw / 2.0, fh / 4.0) * 0.38);
    const r2 = r * r;

    var count: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const row_off = @as(usize, y) * bytes_per_row;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            var lit = false;
            for (0..8) |b| {
                if ((mask >> @as(u3, @intCast(b))) & 1 == 0) continue;
                const dx = px - cxs[b];
                const dy = py - cys[b];
                if (dx * dx + dy * dy <= r2) {
                    lit = true;
                    break;
                }
            }
            if (lit) {
                gp.setPixel(pixels, row_off + @as(usize, x) * 4);
                count += 1;
            }
        }
    }
    return count;
}

test "isBraille: U+2800~28FF만" {
    try std.testing.expect(isBraille(0x2800)); // 빈 점
    try std.testing.expect(isBraille(0x2801)); // 점1
    try std.testing.expect(isBraille(0x28FF)); // 8점 전부
    try std.testing.expect(!isBraille(0x27FF)); // 범위 밖
    try std.testing.expect(!isBraille(0x2900)); // 범위 밖
    try std.testing.expect(!isBraille(0x2500)); // box-drawing
}

test "fillCoverage: 점 위치가 비트마스크대로(좌상=점1·우하=점8), 빈 패턴은 0" {
    const w: u32 = 8;
    const h: u32 = 16;
    const bpr: usize = w * 4;
    var pixels: [16 * 8 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;
    // 점 중심: 열 x=2·6, 행 y=2·6·10·14.

    // U+2801 = 점1만(좌상, (2,2)). 그 점은 켜지고 점8 자리(우하 (6,14))는 빈다.
    _ = fillCoverage(0x2801, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 2, 2));
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 6, 14));

    // U+2880 = 점8만(우하, (6,14)). 그 점은 켜지고 점1 자리(좌상)는 빈다.
    _ = fillCoverage(0x2880, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 6, 14));
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 2, 2));

    // U+28FF = 8점 전부. 점들은 켜지되 셀 중앙(점 사이 gap)은 비어 점 패턴임을 확인.
    const full = fillCoverage(0x28FF, w, h, bpr, &pixels);
    try std.testing.expect(full > 0);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 2, 2)); // 점1
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 6, 14)); // 점8
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 4, 8)); // 중앙 gap(점 아님)

    // U+2800 = 빈 패턴 → 아무것도 안 그림.
    try std.testing.expectEqual(@as(u32, 0), fillCoverage(0x2800, w, h, bpr, &pixels));
}
