//! backend-neutral 색 primitive.
//!
//! 색 값은 terminal cell, renderer theme, config resolve 등 여러 레이어가 공유한다.
//! 특정 도메인(예: terminal) 안에 두면 config나 renderer가 색 하나 때문에 그 도메인을
//! import해야 해서 레이어 경계가 흐려진다. 그래서 공용 top-level 모듈로 분리한다.

const std = @import("std");

/// 채널당 8-bit RGB. alpha나 palette index 같은 도메인 의미는 담지 않는다. 그런
/// 의미가 필요한 곳(예: terminal `Color` union의 default/indexed)은 이 타입을 감싸서 둔다.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// `#rrggbb`(또는 `rrggbb`, 양끝 공백 허용) 6자리 hex를 Rgb로 파싱한다. 형식 오류(길이·비-hex)면 null. 색 picker의
/// hex 인라인 편집·다른 hex 입력이 공유하는 단일 출처(소문자/대문자 허용). 3자리 단축형·알파는 미지원(터미널 색은 #RRGGBB).
pub fn parseHex(text: []const u8) ?Rgb {
    var s = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (s.len > 0 and s[0] == '#') s = s[1..];
    if (s.len != 6) return null;
    const r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

/// HSV 색(세팅 GUI 색 picker용). h=색상(0~359도), s=채도(0~100%), v=명도(0~100%). 정수라 셀-그리드 picker의
/// 이산 선택과 맞물린다. RGB와 round-trip은 양자화 때문에 근사다(picker는 셀 해상도라 충분).
pub const Hsv = struct { h: u16, s: u8, v: u8 };

/// HSV→RGB(표준 변환). h 0~359, s·v 0~100. 색 picker가 그리드 셀·선택값을 화면색으로 푼다.
pub fn hsvToRgb(hsv: Hsv) Rgb {
    const h: f32 = @floatFromInt(@mod(hsv.h, 360));
    const s: f32 = @as(f32, @floatFromInt(@min(hsv.s, 100))) / 100.0;
    const v: f32 = @as(f32, @floatFromInt(@min(hsv.v, 100))) / 100.0;
    const c = v * s; // chroma
    const hp = h / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    const m = v - c;
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    if (hp < 1.0) {
        r = c;
        g = x;
    } else if (hp < 2.0) {
        r = x;
        g = c;
    } else if (hp < 3.0) {
        g = c;
        b = x;
    } else if (hp < 4.0) {
        g = x;
        b = c;
    } else if (hp < 5.0) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    return .{
        .r = @intFromFloat(@round((r + m) * 255.0)),
        .g = @intFromFloat(@round((g + m) * 255.0)),
        .b = @intFromFloat(@round((b + m) * 255.0)),
    };
}

/// RGB→HSV(표준 변환). picker가 현재 색에서 초기 h/s/v를 잡을 때. s·v는 0~100, h는 0~359로 반올림.
pub fn rgbToHsv(rgb: Rgb) Hsv {
    const r: f32 = @as(f32, @floatFromInt(rgb.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(rgb.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(rgb.b)) / 255.0;
    const max = @max(r, @max(g, b));
    const min = @min(r, @min(g, b));
    const d = max - min;
    var h: f32 = 0;
    if (d > 0.00001) {
        if (max == r) {
            h = 60.0 * @mod((g - b) / d, 6.0);
        } else if (max == g) {
            h = 60.0 * ((b - r) / d + 2.0);
        } else {
            h = 60.0 * ((r - g) / d + 4.0);
        }
    }
    if (h < 0) h += 360.0;
    const s: f32 = if (max > 0.00001) d / max else 0;
    return .{
        .h = @intFromFloat(@round(@mod(h, 360.0))),
        .s = @intFromFloat(@round(s * 100.0)),
        .v = @intFromFloat(@round(max * 100.0)),
    };
}

// 표준 xterm 16색 팔레트(0..15). 터미널 `Color.indexed`를 화면 RGB로 풀 때 쓴다.
const ansi16 = [16]Rgb{
    .{ .r = 0, .g = 0, .b = 0 }, // 0 black
    .{ .r = 128, .g = 0, .b = 0 }, // 1 red
    .{ .r = 0, .g = 128, .b = 0 }, // 2 green
    .{ .r = 128, .g = 128, .b = 0 }, // 3 yellow
    .{ .r = 0, .g = 0, .b = 128 }, // 4 blue
    .{ .r = 128, .g = 0, .b = 128 }, // 5 magenta
    .{ .r = 0, .g = 128, .b = 128 }, // 6 cyan
    .{ .r = 192, .g = 192, .b = 192 }, // 7 white
    .{ .r = 128, .g = 128, .b = 128 }, // 8 bright black
    .{ .r = 255, .g = 0, .b = 0 }, // 9 bright red
    .{ .r = 0, .g = 255, .b = 0 }, // 10 bright green
    .{ .r = 255, .g = 255, .b = 0 }, // 11 bright yellow
    .{ .r = 0, .g = 0, .b = 255 }, // 12 bright blue
    .{ .r = 255, .g = 0, .b = 255 }, // 13 bright magenta
    .{ .r = 0, .g = 255, .b = 255 }, // 14 bright cyan
    .{ .r = 255, .g = 255, .b = 255 }, // 15 bright white
};

const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

/// xterm 256색 index를 RGB로 푼다: 0..15 ANSI, 16..231 6×6×6 cube, 232..255 grayscale ramp.
pub fn xterm256(index: u8) Rgb {
    if (index < 16) return ansi16[index];
    if (index < 232) {
        const n = index - 16;
        return .{
            .r = cube_levels[n / 36],
            .g = cube_levels[(n / 6) % 6],
            .b = cube_levels[n % 6],
        };
    }
    const level: u8 = 8 + (index - 232) * 10;
    return .{ .r = level, .g = level, .b = level };
}

// ── WCAG 대비(contrast) 유틸 — `theme.min-contrast`의 단일 출처 ─────────────────────────────────────────
// config resolve(ANSI 16 팔레트 선보정 — appearance.resolveTheme)와 렌더 hot path(metal_frame의 256색·
// truecolor per-cell 하한)가 같은 수식을 공유한다. 베이스: WCAG 2.x relative luminance·contrast ratio
// 정의(공개 명세 — 단일 표준이 없는 "가독성 보정" 발명이 아니라 표준 명암비 수식 그대로, docs/configuration.md).

/// sRGB 채널(0~255)의 WCAG 선형 luminance LUT. 렌더 hot path가 셀마다 luminance를 계산하므로 pow를
/// 매번 부르지 않게 comptime으로 256개를 미리 푼다(채널당 조회 1회). 수식: WCAG 2.x — 임계 0.03928,
/// 그 위는 감마 2.4 (((s+0.055)/1.055)^2.4).
const channel_luminance_lut: [256]f32 = blk: {
    @setEvalBranchQuota(200_000);
    var t: [256]f32 = undefined;
    for (&t, 0..) |*v, i| {
        const s = @as(f32, @floatFromInt(i)) / 255.0;
        v.* = if (s <= 0.03928) s / 12.92 else std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
    }
    break :blk t;
};

/// 색의 WCAG relative luminance(0~1) — 채널 선형화(LUT) 후 0.2126/0.7152/0.0722 가중합(눈의 채널 민감도).
pub fn relativeLuminance(rgb: Rgb) f32 {
    return 0.2126 * channel_luminance_lut[rgb.r] + 0.7152 * channel_luminance_lut[rgb.g] + 0.0722 * channel_luminance_lut[rgb.b];
}

/// 두 luminance의 WCAG contrast ratio: (L_hi + 0.05) / (L_lo + 0.05), 범위 1.0(같은 밝기)~21.0(검정 대 흰색).
pub fn contrastRatio(lum_a: f32, lum_b: f32) f32 {
    const hi = @max(lum_a, lum_b);
    const lo = @min(lum_a, lum_b);
    return (hi + 0.05) / (lo + 0.05);
}

/// 색을 검은색 쪽으로 k(0~1)배 스케일한다(각 채널 × k, 반올림). k=1이면 원본, k=0이면 검정. R:G:B 비를 유지하므로
/// hue(색상)를 보존하고 명도(luminance)만 낮춘다 — "색은 그대로, 더 진하게"에 해당.
fn scaleTowardBlack(c: Rgb, k: f32) Rgb {
    return .{
        .r = @intFromFloat(@round(@as(f32, @floatFromInt(c.r)) * k)),
        .g = @intFromFloat(@round(@as(f32, @floatFromInt(c.g)) * k)),
        .b = @intFromFloat(@round(@as(f32, @floatFromInt(c.b)) * k)),
    };
}

/// 색이 배경 대비 `target` 명암비에 못 미치면 **색상을 보존한 채 검은색 방향으로 최소한만** 어둡게 보정한다.
/// `bg_lum`은 배경의 WCAG relative luminance(호출자가 재사용을 위해 계산해 넘긴다 — resolve는 16색에 1회,
/// 렌더는 셀 배경마다). 밝은 배경에선 어둡게 할수록(k↓) 대비가 단조 증가하므로, 목표 명암비에 막 닿는 최대
/// k(=최소 변화)를 이진 탐색으로 찾는다.
/// **활성 경계**: 검정(luminance 0)으로도 목표 대비에 못 미치면 원본을 그대로 둔다(어둡게 해봐야 목표를 못
/// 넘는다). 이는 배경이 어두울수록 성립한다 — 경계는 `contrastRatio(0, bg_lum) >= target`, 즉
/// `bg_lum >= 0.05*(target−1)`이다(target=3.0이면 bg_lum≈0.10). **모든 번들 다크 프리셋**은 배경 bg_lum이
/// 이보다 훨씬 낮아(#101010≈0.005 등) 무동작이다. 중간 밝기(회색) 배경은 목표 도달이 가능하면 보정한다.
/// `target<=1.0`(끔)·이미 충분하면 원본 그대로. 단일 출처: 팔레트 선보정(appearance.resolveTheme)과 렌더
/// per-cell 하한(metal_frame)이 모두 이 함수만 쓴다.
pub fn contrastFloor(c: Rgb, bg_lum: f32, target: f32) Rgb {
    if (target <= 1.0) return c; // 끔(0 포함) — 업스트림 원색 그대로
    if (contrastRatio(relativeLuminance(c), bg_lum) >= target) return c; // 이미 충분 → 무변경
    if (contrastRatio(0.0, bg_lum) < target) return c; // 검정(luminance 0)으로도 미달=배경이 충분히 어두움 → 무동작
    // 이진 탐색: k∈[0,1]에서 c×k. lo=목표 충족(더 어두움), hi=미충족(더 밝음). 24회면 u8 해상도로 수렴한다.
    var lo: f32 = 0.0; // k=0(검정)은 위 가드로 항상 충족
    var hi: f32 = 1.0; // k=1(원본)은 위 fast-path로 미충족
    var iter: usize = 0;
    while (iter < 24) : (iter += 1) {
        const mid = (lo + hi) / 2.0;
        if (contrastRatio(relativeLuminance(scaleTowardBlack(c, mid)), bg_lum) >= target) {
            lo = mid; // 충족 → 더 밝게(원본에 가깝게) 시도
        } else {
            hi = mid; // 미충족 → 더 어둡게
        }
    }
    return scaleTowardBlack(c, lo); // lo는 항상 충족 지점(테스트한 값 그대로 반환)
}

test "contrast: LUT luminance 경계·단조, contrastFloor 라이트/다크 동작" {
    // 이 테스트가 증명하는 것: LUT 기반 luminance가 WCAG 정의(검정 0, 흰색 1, 단조 증가)를 지키고,
    // contrastFloor가 밝은 배경에선 목표 명암비를 강제하며 어두운 배경에선 무동작이라는 계약 —
    // 렌더 per-cell 하한과 팔레트 선보정이 공유하는 단일 출처의 기본 성질이다.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), relativeLuminance(.{ .r = 0, .g = 0, .b = 0 }), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), relativeLuminance(.{ .r = 255, .g = 255, .b = 255 }), 1e-4);
    var prev: f32 = -1.0;
    var g: usize = 0;
    while (g < 256) : (g += 8) {
        const lum = relativeLuminance(.{ .r = @intCast(g), .g = @intCast(g), .b = @intCast(g) });
        try std.testing.expect(lum > prev);
        prev = lum;
    }
    // 밝은 배경(흰색): 거의 안 보이는 밝은 회색이 목표 3.0 이상으로 보정되고 hue(무채색)는 유지된다.
    const white_lum = relativeLuminance(.{ .r = 255, .g = 255, .b = 255 });
    const floored = contrastFloor(.{ .r = 235, .g = 235, .b = 235 }, white_lum, 3.0);
    try std.testing.expect(contrastRatio(relativeLuminance(floored), white_lum) >= 2.95);
    try std.testing.expect(floored.r == floored.g and floored.g == floored.b); // 무채색 보존
    // 어두운 배경(#101010): 검정으로도 목표 미달 → 무동작(다크 프리셋 회귀 0 가드).
    const dark_lum = relativeLuminance(.{ .r = 0x10, .g = 0x10, .b = 0x10 });
    const kept = contrastFloor(.{ .r = 30, .g = 30, .b = 30 }, dark_lum, 3.0);
    try std.testing.expectEqual(@as(u8, 30), kept.r);
}

/// xterm OSC "color specification"을 RGB로 푼다(OSC 4 팔레트·후속 OSC 10/11 set이 공유). 지원 형식:
///   - `rgb:<r>/<g>/<b>` — 각 채널 1..4 hex 자리를 8-bit로 스케일(rgb:ff/00/80, rgb:ffff/0000/8080 등).
///   - `#rgb` / `#rrggbb` / `#rrrgggbbb` / `#rrrrggggbbbb` — 채널당 1..4 hex 자리.
/// 형식 위반(자리수 0 또는 5+, 비-hex, 채널 수 != 3)이면 null. 베이스: xterm ctlseqs color specification.
pub fn parseSpec(spec: []const u8) ?Rgb {
    if (std.mem.startsWith(u8, spec, "rgb:")) return parseRgbForm(spec[4..]);
    if (spec.len >= 1 and spec[0] == '#') return parseHashForm(spec[1..]);
    return null;
}

fn parseRgbForm(s: []const u8) ?Rgb {
    var it = std.mem.splitScalar(u8, s, '/');
    const r = scaleChannel(it.next() orelse return null) orelse return null;
    const g = scaleChannel(it.next() orelse return null) orelse return null;
    const b = scaleChannel(it.next() orelse return null) orelse return null;
    if (it.next() != null) return null; // 채널 4개+면 형식 위반
    return .{ .r = r, .g = g, .b = b };
}

fn parseHashForm(s: []const u8) ?Rgb {
    if (s.len == 0 or s.len % 3 != 0) return null;
    const w = s.len / 3; // 채널당 자리수
    if (w > 4) return null;
    return .{
        .r = scaleChannel(s[0..w]) orelse return null,
        .g = scaleChannel(s[w .. 2 * w]) orelse return null,
        .b = scaleChannel(s[2 * w .. 3 * w]) orelse return null,
    };
}

/// 1..4 hex 자리 채널을 8-bit로 스케일한다. k자리 값 v(최대 16^k-1)를 `v*255/(16^k-1)`로 0..255에 매핑
/// (xterm: 2-hex는 그대로, 4-hex는 상위 바이트 근사). ff/ffff→255, 80/8080→128, f/fff의 채널→255.
fn scaleChannel(h: []const u8) ?u8 {
    if (h.len == 0 or h.len > 4) return null;
    const v = std.fmt.parseInt(u16, h, 16) catch return null; // 4 hex = 최대 0xffff
    const max: u32 = (@as(u32, 1) << @intCast(4 * h.len)) - 1; // 16^k - 1
    return @intCast(@as(u32, v) * 255 / max);
}

test "rgb holds three independent 8-bit channels" {
    const c: Rgb = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    try std.testing.expectEqual(@as(u8, 0x10), c.r);
    try std.testing.expectEqual(@as(u8, 0x20), c.g);
    try std.testing.expectEqual(@as(u8, 0x30), c.b);
}

test "hsvToRgb / rgbToHsv: 기준색 변환 + round-trip 근사 (색 picker)" {
    // 기준: 순수 빨강/초록/파랑/흰/검.
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, hsvToRgb(.{ .h = 0, .s = 100, .v = 100 }));
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 255, .b = 0 }, hsvToRgb(.{ .h = 120, .s = 100, .v = 100 }));
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 255 }, hsvToRgb(.{ .h = 240, .s = 100, .v = 100 }));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, hsvToRgb(.{ .h = 0, .s = 0, .v = 100 }));
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, hsvToRgb(.{ .h = 0, .s = 0, .v = 0 }));
    // rgbToHsv 기준.
    const red = rgbToHsv(.{ .r = 255, .g = 0, .b = 0 });
    try std.testing.expectEqual(@as(u16, 0), red.h);
    try std.testing.expectEqual(@as(u8, 100), red.s);
    try std.testing.expectEqual(@as(u8, 100), red.v);
    // round-trip 근사: hsv→rgb→hsv가 양자화 오차 내에서 같다(채널당 ±3, h ±2도).
    const cases = [_]Hsv{ .{ .h = 30, .s = 80, .v = 90 }, .{ .h = 200, .s = 50, .v = 70 }, .{ .h = 300, .s = 100, .v = 40 } };
    for (cases) |c| {
        const back = rgbToHsv(hsvToRgb(c));
        try std.testing.expect(@abs(@as(i32, back.s) - @as(i32, c.s)) <= 3);
        try std.testing.expect(@abs(@as(i32, back.v) - @as(i32, c.v)) <= 3);
        const dh = @abs(@as(i32, back.h) - @as(i32, c.h));
        try std.testing.expect(dh <= 2 or dh >= 358); // h wrap
    }
}

test "xterm256 resolves ansi, color cube, and grayscale ranges" {
    // ANSI 16
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, xterm256(0));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, xterm256(9));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, xterm256(15));
    // 6x6x6 cube: 16 = (0,0,0), 231 = (255,255,255)
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, xterm256(16));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, xterm256(231));
    // cube 196 = 16 + 180 -> n=180 -> r=180/36=5(255), g=(180/6)%6=0, b=0
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, xterm256(196));
    // grayscale ramp: 232 = 8, 255 = 238
    try std.testing.expectEqual(Rgb{ .r = 8, .g = 8, .b = 8 }, xterm256(232));
    try std.testing.expectEqual(Rgb{ .r = 238, .g = 238, .b = 238 }, xterm256(255));
}

test "parseSpec resolves xterm rgb: and # color specifications" {
    // rgb: 2-hex 채널(가장 흔함) — 그대로.
    try std.testing.expectEqual(Rgb{ .r = 0xff, .g = 0x00, .b = 0x80 }, parseSpec("rgb:ff/00/80").?);
    // rgb: 4-hex 채널 — 상위 바이트 근사(ffff→255, 8080→128, 0000→0).
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 128, .b = 0 }, parseSpec("rgb:ffff/8080/0000").?);
    // rgb: 1-hex 채널 — f→255, 0→0, 8→0x88(136).
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 136 }, parseSpec("rgb:f/0/8").?);
    // # 6-hex / 3-hex.
    try std.testing.expectEqual(Rgb{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, parseSpec("#aabbcc").?);
    try std.testing.expectEqual(Rgb{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, parseSpec("#abc").?);
    // 형식 위반 → null: 채널 수 부족·과다, 비-hex, 빈 채널, 미지원 prefix.
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("rgb:ff/00"));
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("rgb:ff/00/80/11"));
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("rgb:gg/00/80"));
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("rgb://"));
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("#abcd")); // 4 hex = 채널당 균등 분할 불가(4%3!=0)
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("blue")); // 이름 색은 미지원
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("?")); // 질의는 파서가 아니라 호출자가 처리
}

test "parseHex: #rrggbb / rrggbb 파싱, 형식 오류는 null (색 picker hex 인라인)" {
    try std.testing.expectEqual(Rgb{ .r = 0xff, .g = 0x00, .b = 0x80 }, parseHex("#ff0080").?);
    try std.testing.expectEqual(Rgb{ .r = 0xab, .g = 0xcd, .b = 0xef }, parseHex("abcdef").?); // # 없이도
    try std.testing.expectEqual(Rgb{ .r = 0x12, .g = 0x34, .b = 0x56 }, parseHex("  #123456  ").?); // 공백 trim
    try std.testing.expectEqual(Rgb{ .r = 0xAA, .g = 0xBB, .b = 0xCC }, parseHex("#AABBCC").?); // 대문자
    try std.testing.expectEqual(@as(?Rgb, null), parseHex("#fff")); // 3자리 미지원
    try std.testing.expectEqual(@as(?Rgb, null), parseHex("#gg0000")); // 비-hex
    try std.testing.expectEqual(@as(?Rgb, null), parseHex("")); // 빈 값
    try std.testing.expectEqual(@as(?Rgb, null), parseHex("#1234567")); // 너무 김
}
