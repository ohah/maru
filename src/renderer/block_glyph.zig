//! Block Elements(U+2580~U+259F) 글리프 합성 — 폰트 글리프 대신 셀 박스에 정확한 사각형 coverage를 직접
//! 채워 **이음매 없이 타일링**한다(폰트 글리프는 셀에 딱 안 맞아 gap·흐림이 생긴다 — Claude 로고/TUI 보더).
//!
//! 동작 토대: rasterizer 슬롯은 cell_width×cell_height(device px)이고 셀 셰이더가 nearest 샘플 + alpha
//! coverage(`mix(bg, fg, cov)`)라, 슬롯 alpha를 셀 격자에 정수 픽셀로 채우면 1:1 픽셀-퍼펙트로 셀을 채운다.
//! 베이스 = Unicode Block Elements 기하(eighth band·half·full·quadrant). Ghostty `font/sprite/draw/box.zig`가
//! 같은 합성을 하는지 **동작만** 비교했고 자료구조/코드는 옮기지 않았다(clean-room).
//!
//! 범위: **U+2580~259F 전체** — eighth/half/full(U+2580~2590)·shade ░▒▓(U+2591~2593, 균일 alpha)·upper·right
//! eighth(U+2594·2595)·quadrant(U+2596~259F). box-drawing(U+2500~257F)·Powerline·Braille은 별도 모듈.
//! 중립 모듈(platform 무관) — 어느 rasterizer 백엔드든 codepoint→coverage로 재사용한다.

const std = @import("std");
const gp = @import("glyph_pixels.zig"); // 슬롯 검증·clear·fillRect·균일 alpha 공유 프리미티브(단일 출처).

/// cp가 합성 대상 block element인지(U+2580~259F 연속 — shade ░▒▓ 포함). 이 범위면 fillCoverage가 폰트 대신 직접 그린다.
pub fn isBlockElement(cp: u32) bool {
    return cp >= 0x2580 and cp <= 0x259F;
}

/// cp 블록을 width×height RGBA8 슬롯에 coverage로 채운다 — 채운 픽셀은 흰색 불투명(0xFFFFFFFF, 셀 셰이더가
/// alpha를 coverage로 읽어 전경색으로 칠함), 나머지는 0. 슬롯을 먼저 비우고 해당 사각형(들)만 채운다.
/// 채운 픽셀 수를 돌려준다(rasterizer의 non_clear_pixels 회계). 좌표는 정수 픽셀(셀 격자 스냅 — 선명).
/// isBlockElement(cp) 가정. 슬롯 버퍼가 계약(bytes_per_row≥w*4, len≥h*bpr)을 안 지키면 비운 채 0(안전 degrade).
pub fn fillCoverage(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) u32 {
    const w = width_px;
    const h = height_px;
    // 슬롯이 w×h×4를 담는지 확인 — 어긋나면 OOB 쓰기(메모리 손상)이므로 빈 글리프로 안전 degrade.
    if (!gp.slotFits(w, h, bytes_per_row, pixels)) return 0;
    gp.clear(pixels, h, bytes_per_row);

    switch (cp) {
        0x2580 => return gp.fillRect(pixels, bytes_per_row, 0, 0, w, h / 2), // ▀ upper half
        0x2581...0x2587 => { // ▁▂▃▄▅▆▇ lower k/8 (k=1..7)
            const k = cp - 0x2580;
            return gp.fillRect(pixels, bytes_per_row, 0, h - h * k / 8, w, h);
        },
        0x2588 => return gp.fillRect(pixels, bytes_per_row, 0, 0, w, h), // █ full
        0x2589...0x258F => { // ▉▊▋▌▍▎▏ left k/8 (2589=7/8 … 258F=1/8)
            const k = 8 - (cp - 0x2588);
            return gp.fillRect(pixels, bytes_per_row, 0, 0, w * k / 8, h);
        },
        0x2590 => return gp.fillRect(pixels, bytes_per_row, w / 2, 0, w, h), // ▐ right half
        // 음영 ░▒▓ — 셀 전체 균일 alpha(셰이더가 fg를 그 비율로 blend). 점 dither가 아니라 부분 coverage라
        // 어느 크기든 깔끔하고 셀 격자에 흔들림 없다. 0x40/0x80/0xC0 = ¼/½/¾(Unicode LIGHT/MEDIUM/DARK SHADE).
        0x2591 => return gp.fillUniformAlpha(pixels, w, h, bytes_per_row, 0x40), // ░ light 25%
        0x2592 => return gp.fillUniformAlpha(pixels, w, h, bytes_per_row, 0x80), // ▒ medium 50%
        0x2593 => return gp.fillUniformAlpha(pixels, w, h, bytes_per_row, 0xC0), // ▓ dark 75%
        0x2594 => return gp.fillRect(pixels, bytes_per_row, 0, 0, w, h / 8), // ▔ upper 1/8
        0x2595 => return gp.fillRect(pixels, bytes_per_row, w - w / 8, 0, w, h), // ▕ right 1/8
        0x2596...0x259F => { // quadrants ▖▗▘▙▚▛▜▝▞▟ — 4분면 마스크(UL=1·UR=2·LL=4·LR=8)
            const masks = [_]u4{ 4, 8, 1, 13, 9, 7, 11, 2, 6, 14 };
            const m = masks[cp - 0x2596];
            const mx = w / 2;
            const my = h / 2;
            var count: u32 = 0;
            if (m & 1 != 0) count += gp.fillRect(pixels, bytes_per_row, 0, 0, mx, my); // UL
            if (m & 2 != 0) count += gp.fillRect(pixels, bytes_per_row, mx, 0, w, my); // UR
            if (m & 4 != 0) count += gp.fillRect(pixels, bytes_per_row, 0, my, mx, h); // LL
            if (m & 8 != 0) count += gp.fillRect(pixels, bytes_per_row, mx, my, w, h); // LR
            return count;
        },
        else => return 0, // isBlockElement 밖 — 호출 안 됨
    }
}

test "isBlockElement: U+2580~259F 연속(shade 포함)" {
    try std.testing.expect(isBlockElement(0x2588)); // █ full
    try std.testing.expect(isBlockElement(0x2580)); // ▀
    try std.testing.expect(isBlockElement(0x2590)); // ▐
    try std.testing.expect(isBlockElement(0x2591)); // ░ shade 포함
    try std.testing.expect(isBlockElement(0x2592)); // ▒
    try std.testing.expect(isBlockElement(0x2593)); // ▓
    try std.testing.expect(isBlockElement(0x259B)); // ▛ (로고)
    try std.testing.expect(isBlockElement(0x259F)); // ▟
    try std.testing.expect(!isBlockElement(0x257F)); // box-drawing(아래 범위 밖)
    try std.testing.expect(!isBlockElement(0x25A0)); // 범위 밖(■)
    try std.testing.expect(!isBlockElement('A')); // 일반 글자
}

test "fillCoverage: shade ░▒▓는 셀 전체를 균일 alpha(0x40/0x80/0xC0)로" {
    const w: u32 = 8;
    const h: u32 = 16;
    const bpr: usize = w * 4;
    var pixels: [16 * 8 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;

    // ░ light: 전 픽셀 alpha=0x40, count=w*h.
    try std.testing.expectEqual(w * h, fillCoverage(0x2591, w, h, bpr, &pixels));
    try std.testing.expectEqual(@as(u8, 0x40), a(&pixels, bpr, 0, 0));
    try std.testing.expectEqual(@as(u8, 0x40), a(&pixels, bpr, w - 1, h - 1));
    try std.testing.expectEqual(@as(u8, 0x40), a(&pixels, bpr, w / 2, h / 2));
    // ▒ medium: 0x80.
    _ = fillCoverage(0x2592, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0x80), a(&pixels, bpr, 3, 9));
    // ▓ dark: 0xC0.
    _ = fillCoverage(0x2593, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xC0), a(&pixels, bpr, 3, 9));
}

test "fillCoverage: full/half/quadrant가 정확한 픽셀 사각형을 채운다" {
    const w: u32 = 8;
    const h: u32 = 16;
    const bpr: usize = w * 4;
    var pixels: [16 * 8 * 4]u8 = undefined;

    // 헬퍼: (x,y)의 alpha(=coverage). RGBA8.
    const a = struct {
        fn at(p: []const u8, bytes_per_row: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bytes_per_row + @as(usize, x) * 4 + 3];
        }
    }.at;

    // █ full: 전부 채움(w*h).
    try std.testing.expectEqual(w * h, fillCoverage(0x2588, w, h, bpr, &pixels));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, 0));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, h - 1));

    // ▀ upper half: 위 절반만(w * h/2). 위는 채우고 아래는 빈다.
    try std.testing.expectEqual(w * (h / 2), fillCoverage(0x2580, w, h, bpr, &pixels));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 3, 0)); // 위
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 3, h / 2 - 1));
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 3, h / 2)); // 아래 빈다

    // ▐ right half: 오른쪽 절반만. 왼쪽은 빈다.
    _ = fillCoverage(0x2590, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, w / 2 - 1, 5)); // 왼쪽 빈다
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w / 2, 5)); // 오른쪽 채움

    // ▘ quadrant upper-left(2598): 좌상단 1/4만.
    _ = fillCoverage(0x2598, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, 0)); // UL
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, w - 1, 0)); // UR 빈다
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, h - 1)); // LL 빈다

    // ▟ quadrant UR+LL+LR(259F): 좌상단만 빈다.
    _ = fillCoverage(0x259F, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, 0)); // UL 빈다
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, 0)); // UR
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, h - 1)); // LL
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, h - 1)); // LR
}
