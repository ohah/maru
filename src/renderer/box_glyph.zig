//! Box-drawing(U+2500~U+257F) 글리프 합성 — 폰트 글리프 대신 셀에 얇은 선을 직접 그려 **셀 경계에서 이음매
//! 없이 연결**한다(폰트 글리프는 셀에 안 맞아 선이 끊기거나 안 보인다 — TUI 보더 `─│╭╮`). block_glyph와 같은
//! 원리: 슬롯이 cell 크기 + 셀 셰이더 nearest 샘플 + alpha coverage라, 슬롯 alpha에 정수 픽셀 선을 채우면
//! 1:1 픽셀-퍼펙트로 셀에 그려진다.
//!
//! **arm 모델**: 각 box 문자는 셀 중앙에서 상/하/좌/우로 뻗는 팔의 조합이다. 가로 팔은 세로 중앙의 t-두께 띠,
//! 세로 팔은 가로 중앙의 t-두께 띠로 그리고, 각 팔을 **셀 경계까지** 뻗어(left→x=0, right→x=w, up→y=0, down→y=h)
//! 이웃 셀의 선과 정확히 맞닿게 한다. 중앙에서 팔들이 교차해 모서리(┌)·삼거리(├)·사거리(┼)가 된다.
//!
//! 범위: **light single**(─│ 직선, ┌┐└┘ 모서리, ├┤┬┴┼ 교차, 둥근 ╭╮╰╯ — 실제 quarter-arc) + **heavy**
//! (━┃ 직선·┏┓┗┛ 모서리·┣┫┳┻ 교차·╋ — 두께 2배) + **dashed**(┄┅┆┇┈┉┊┋ 2·3·4점선 + ╌╍╎╏ — 직선 전용,
//! light·heavy 굵기) + **double**(═║ 직선·╔╗╚╝ 모서리·╠╣╦╩ 교차·╬ — 두 평행선, 모서리는 outer/inner 코너).
//! 혼합 굵기(┍┎┑…)는 후속(폰트 폴백). 베이스 = Unicode Box Drawing 기하(굵기·점선·이중 분류는 Unicode 문자명
//! 그대로). Ghostty font/sprite/draw/box.zig 동작만 비교(코드 미복사 — clean-room). 중립 모듈.

const std = @import("std");

/// 셀 중앙에서 뻗는 팔. 가로(left/right)·세로(up/down) 조합으로 직선·모서리·교차를 표현한다.
const Arms = struct { up: bool = false, down: bool = false, left: bool = false, right: bool = false };

/// box 문자 한 글자의 합성 명세: 팔 조합 + 굵기(heavy) + 점선 개수(dash) + 둥근 모서리(rounded) + 이중선(double).
const Spec = struct {
    arms: Arms = .{},
    heavy: bool = false, // ━┃ 등 굵은 선(light 두께의 2배)
    dash: u8 = 0, // 0=실선, 2/3/4=점선 개수(직선 전용 — Unicode double/triple/quadruple dash)
    rounded: bool = false, // ╭╮╰╯ quarter-arc(light 전용)
    double: bool = false, // ═║╔╗╚╝╠╣╦╩╬ 두 평행선(arms는 분기 방향, 실제 그리기는 fillDouble가 cp별 처리)
};

/// cp가 합성 대상 box-drawing 문자인지(이 모듈이 덮는 집합: light·heavy·dashed). 그 외(double·혼합 굵기)는
/// false → 기존 폰트 글리프 경로로 폴백한다.
pub fn isBoxDrawing(cp: u32) bool {
    return specFor(cp) != null;
}

/// cp → 합성 명세. 덮지 않는 문자면 null. 굵기·점선 분류는 Unicode 문자명(LIGHT/HEAVY/DASH) 그대로.
fn specFor(cp: u32) ?Spec {
    return switch (cp) {
        // ── light single(실선) ──
        0x2500 => .{ .arms = .{ .left = true, .right = true } }, // ─
        0x2502 => .{ .arms = .{ .up = true, .down = true } }, // │
        0x250C => .{ .arms = .{ .down = true, .right = true } }, // ┌
        0x2510 => .{ .arms = .{ .down = true, .left = true } }, // ┐
        0x2514 => .{ .arms = .{ .up = true, .right = true } }, // └
        0x2518 => .{ .arms = .{ .up = true, .left = true } }, // ┘
        0x251C => .{ .arms = .{ .up = true, .down = true, .right = true } }, // ├
        0x2524 => .{ .arms = .{ .up = true, .down = true, .left = true } }, // ┤
        0x252C => .{ .arms = .{ .down = true, .left = true, .right = true } }, // ┬
        0x2534 => .{ .arms = .{ .up = true, .left = true, .right = true } }, // ┴
        0x253C => .{ .arms = .{ .up = true, .down = true, .left = true, .right = true } }, // ┼
        // 둥근 모서리(light)
        0x256D => .{ .arms = .{ .down = true, .right = true }, .rounded = true }, // ╭
        0x256E => .{ .arms = .{ .down = true, .left = true }, .rounded = true }, // ╮
        0x256F => .{ .arms = .{ .up = true, .left = true }, .rounded = true }, // ╯
        0x2570 => .{ .arms = .{ .up = true, .right = true }, .rounded = true }, // ╰
        // ── heavy(굵은 선) ──
        0x2501 => .{ .arms = .{ .left = true, .right = true }, .heavy = true }, // ━
        0x2503 => .{ .arms = .{ .up = true, .down = true }, .heavy = true }, // ┃
        0x250F => .{ .arms = .{ .down = true, .right = true }, .heavy = true }, // ┏
        0x2513 => .{ .arms = .{ .down = true, .left = true }, .heavy = true }, // ┓
        0x2517 => .{ .arms = .{ .up = true, .right = true }, .heavy = true }, // ┗
        0x251B => .{ .arms = .{ .up = true, .left = true }, .heavy = true }, // ┛
        0x2523 => .{ .arms = .{ .up = true, .down = true, .right = true }, .heavy = true }, // ┣
        0x252B => .{ .arms = .{ .up = true, .down = true, .left = true }, .heavy = true }, // ┫
        0x2533 => .{ .arms = .{ .down = true, .left = true, .right = true }, .heavy = true }, // ┳
        0x253B => .{ .arms = .{ .up = true, .left = true, .right = true }, .heavy = true }, // ┻
        0x254B => .{ .arms = .{ .up = true, .down = true, .left = true, .right = true }, .heavy = true }, // ╋
        // ── dashed(점선, 직선 전용) — light·heavy 굵기 ──
        0x2504 => .{ .arms = .{ .left = true, .right = true }, .dash = 3 }, // ┄ triple H
        0x2505 => .{ .arms = .{ .left = true, .right = true }, .dash = 3, .heavy = true }, // ┅
        0x2506 => .{ .arms = .{ .up = true, .down = true }, .dash = 3 }, // ┆ triple V
        0x2507 => .{ .arms = .{ .up = true, .down = true }, .dash = 3, .heavy = true }, // ┇
        0x2508 => .{ .arms = .{ .left = true, .right = true }, .dash = 4 }, // ┈ quad H
        0x2509 => .{ .arms = .{ .left = true, .right = true }, .dash = 4, .heavy = true }, // ┉
        0x250A => .{ .arms = .{ .up = true, .down = true }, .dash = 4 }, // ┊ quad V
        0x250B => .{ .arms = .{ .up = true, .down = true }, .dash = 4, .heavy = true }, // ┋
        0x254C => .{ .arms = .{ .left = true, .right = true }, .dash = 2 }, // ╌ double H
        0x254D => .{ .arms = .{ .left = true, .right = true }, .dash = 2, .heavy = true }, // ╍
        0x254E => .{ .arms = .{ .up = true, .down = true }, .dash = 2 }, // ╎ double V
        0x254F => .{ .arms = .{ .up = true, .down = true }, .dash = 2, .heavy = true }, // ╏
        // ── double(이중선) ── (arms=분기 방향, 실제 band는 fillDouble가 cp별)
        0x2550 => .{ .arms = .{ .left = true, .right = true }, .double = true }, // ═
        0x2551 => .{ .arms = .{ .up = true, .down = true }, .double = true }, // ║
        0x2554 => .{ .arms = .{ .down = true, .right = true }, .double = true }, // ╔
        0x2557 => .{ .arms = .{ .down = true, .left = true }, .double = true }, // ╗
        0x255A => .{ .arms = .{ .up = true, .right = true }, .double = true }, // ╚
        0x255D => .{ .arms = .{ .up = true, .left = true }, .double = true }, // ╝
        0x2560 => .{ .arms = .{ .up = true, .down = true, .right = true }, .double = true }, // ╠
        0x2563 => .{ .arms = .{ .up = true, .down = true, .left = true }, .double = true }, // ╣
        0x2566 => .{ .arms = .{ .down = true, .left = true, .right = true }, .double = true }, // ╦
        0x2569 => .{ .arms = .{ .up = true, .left = true, .right = true }, .double = true }, // ╩
        0x256C => .{ .arms = .{ .up = true, .down = true, .left = true, .right = true }, .double = true }, // ╬
        else => null,
    };
}

/// cp box 문자를 width×height RGBA8 슬롯에 coverage로 채운다 — 선은 흰색 불투명(0xFFFFFFFF, 셰이더가 alpha를
/// coverage로 읽어 전경색으로), 나머지 0. 채운 픽셀 수 반환. isBoxDrawing(cp) 가정. 선 두께 t는 cell 높이 비례
/// (light, 최소 1px), 중앙 정렬·정수 픽셀 스냅. 버퍼 계약(bpr≥w*4·len≥h*bpr) 위반 시 빈 글리프로 안전 degrade.
pub fn fillCoverage(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) u32 {
    const w = width_px;
    const h = height_px;
    if (w == 0 or h == 0) return 0;
    if (bytes_per_row < @as(usize, w) * 4 or pixels.len < @as(usize, h) * bytes_per_row) return 0;
    const spec = specFor(cp) orelse return 0;
    @memset(pixels[0 .. @as(usize, h) * bytes_per_row], 0);

    // 선 두께(device px) — light는 cell 높이 비례(최소 1), heavy는 그 2배(굵게). cell보다 두껍지 않게(언더플로 방지).
    var lt: u32 = (h + 8) / 16;
    if (lt < 1) lt = 1;
    // 이중선(═║ 등): 두 평행 light 선 + 모서리는 outer/inner 코너. cp별 band를 fillDouble가 직접 그린다.
    if (spec.double) return fillDouble(cp, w, h, bytes_per_row, pixels, lt);
    var t: u32 = if (spec.heavy) lt * 2 else lt;
    t = @min(t, @min(w, h));
    // 중앙 정렬 띠: 가로 팔은 [yb0,yb1) 높이, 세로 팔은 [xb0,xb1) 폭.
    const yb0 = (h - t) / 2;
    const yb1 = yb0 + t;
    const xb0 = (w - t) / 2;
    const xb1 = xb0 + t;

    // 둥근 모서리(╭╮╰╯)는 직각 대신 quarter-arc로 — 두 팔 방향(h_dir·v_dir)으로 아크 코너를 그린다.
    if (spec.rounded) {
        return switch (cp) {
            0x256D => fillRoundedCorner(pixels, bytes_per_row, w, h, t, yb0, yb1, xb0, xb1, 1, 1), // ╭ right+down
            0x256E => fillRoundedCorner(pixels, bytes_per_row, w, h, t, yb0, yb1, xb0, xb1, -1, 1), // ╮ left+down
            0x256F => fillRoundedCorner(pixels, bytes_per_row, w, h, t, yb0, yb1, xb0, xb1, -1, -1), // ╯ left+up
            0x2570 => fillRoundedCorner(pixels, bytes_per_row, w, h, t, yb0, yb1, xb0, xb1, 1, -1), // ╰ right+up
            else => 0,
        };
    }

    const arms = spec.arms;
    // 점선(직선 전용): 셀 폭/높이를 dash개의 주기로 나눠 각 주기의 앞 2/3만 칠한다(뒤 1/3은 gap). 셀마다 같은
    // 주기라 이웃 셀과 패턴이 이어진다. dashed는 모서리/교차가 없어(Unicode 점선은 직선뿐) 팔 방향만 본다.
    if (spec.dash > 0) {
        var count: u32 = 0;
        if (arms.left or arms.right) count += fillDashedH(pixels, bytes_per_row, w, yb0, yb1, spec.dash);
        if (arms.up or arms.down) count += fillDashedV(pixels, bytes_per_row, h, xb0, xb1, spec.dash);
        return count;
    }

    var count: u32 = 0;
    // 각 팔을 셀 경계까지 뻗는다(중앙 교차 [xb0,xb1)×[yb0,yb1)를 공유해 모서리/교차가 자연히 이어진다).
    if (arms.left) count += fillRect(pixels, bytes_per_row, 0, yb0, xb1, yb1); // 좌단~중앙
    if (arms.right) count += fillRect(pixels, bytes_per_row, xb0, yb0, w, yb1); // 중앙~우단
    if (arms.up) count += fillRect(pixels, bytes_per_row, xb0, 0, xb1, yb1); // 상단~중앙
    if (arms.down) count += fillRect(pixels, bytes_per_row, xb0, yb0, xb1, h); // 중앙~하단
    return count;
}

/// 가로 점선: 폭 w를 n개 주기(period=w/n)로 나눠 각 주기의 앞 dash_len(=period의 2/3)만 [yb0,yb1) 높이로 칠한다.
/// period가 0이면(셀이 점선보다 좁음) 실선으로 안전 degrade. 셀마다 동일 패턴이라 점선이 셀 경계 너머로 이어진다.
fn fillDashedH(pixels: []u8, bytes_per_row: usize, w: u32, yb0: u32, yb1: u32, n: u8) u32 {
    const period = w / n;
    if (period == 0) return fillRect(pixels, bytes_per_row, 0, yb0, w, yb1);
    const dash_len = @max(@as(u32, 1), period * 2 / 3);
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const x0 = i * period;
        count += fillRect(pixels, bytes_per_row, x0, yb0, @min(w, x0 + dash_len), yb1);
    }
    return count;
}

/// 세로 점선(fillDashedH의 세로판): 높이 h를 n주기로 나눠 각 주기 앞 2/3만 [xb0,xb1) 폭으로 칠한다.
fn fillDashedV(pixels: []u8, bytes_per_row: usize, h: u32, xb0: u32, xb1: u32, n: u8) u32 {
    const period = h / n;
    if (period == 0) return fillRect(pixels, bytes_per_row, xb0, 0, xb1, h);
    const dash_len = @max(@as(u32, 1), period * 2 / 3);
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const y0 = i * period;
        count += fillRect(pixels, bytes_per_row, xb0, y0, xb1, @min(h, y0 + dash_len));
    }
    return count;
}

/// 둥근 모서리(╭╮╰╯)를 quarter-arc + 접점 너머 직선 팔로 채운다. 슬롯은 이미 0으로 비워진 상태. h_dir/v_dir은
/// 가로/세로 팔 방향(+1=right/down, -1=left/up). 아크 중심 C=(cx+h_dir·r, cy+v_dir·r), r=min(cx,cy)(셀에 맞는
/// 최대 반지름). 아크 띠 = C에서 거리 [r-t/2, r+t/2]이고 셀 중앙을 향한 사분면((x-C)·dir ≤ 0). 접점 너머는
/// 기존 직선 팔(y/x 띠)로 셀 경계까지 뻗어 이웃 셀과 연결. pixel center(+0.5)로 거리 계산 → 대칭·연결 정확.
fn fillRoundedCorner(
    pixels: []u8,
    bytes_per_row: usize,
    w: u32,
    h: u32,
    t: u32,
    yb0: u32,
    yb1: u32,
    xb0: u32,
    xb1: u32,
    h_dir: i32,
    v_dir: i32,
) u32 {
    const cx = @as(f32, @floatFromInt(w)) * 0.5;
    const cy = @as(f32, @floatFromInt(h)) * 0.5;
    const r = @min(cx, cy); // 코너 반지름 = 셀 짧은 반 치수(아크가 셀에 들어가는 최대)
    const hd = @as(f32, @floatFromInt(h_dir));
    const vd = @as(f32, @floatFromInt(v_dir));
    const c_x = cx + hd * r; // 아크 중심
    const c_y = cy + vd * r;
    const tf = @as(f32, @floatFromInt(t));
    const r_lo = r - tf * 0.5;
    const r_hi = r + tf * 0.5;

    var count: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const dy = fy - c_y;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            const dx = fx - c_x;
            const dist = @sqrt(dx * dx + dy * dy);
            // 아크: 거리 band 안 + 셀 중앙을 향한 사분면(접점 사이 호).
            const in_arc = dist >= r_lo and dist <= r_hi and dx * hd <= 0.0 and dy * vd <= 0.0;
            // 가로 직선 팔: y 띠 + 아크 접점 바깥((x-C)·h_dir ≥ 0) → 셀 가로 경계까지.
            const in_h = (y >= yb0 and y < yb1) and dx * hd >= 0.0;
            // 세로 직선 팔: x 띠 + 접점 바깥 → 셀 세로 경계까지.
            const in_v = (x >= xb0 and x < xb1) and dy * vd >= 0.0;
            if (in_arc or in_h or in_v) {
                const off = @as(usize, y) * bytes_per_row + @as(usize, x) * 4;
                pixels[off] = 0xFF;
                pixels[off + 1] = 0xFF;
                pixels[off + 2] = 0xFF;
                pixels[off + 3] = 0xFF;
                count += 1;
            }
        }
    }
    return count;
}

/// 이중선(═║╔╗╚╝╠╣╦╩╬)을 두 평행 light 선(가로 yU·yL, 세로 xL·xR 밴드)으로 합성한다. 모서리는 **outer/inner**
/// 코너: 셀 중앙에서 먼 쪽 선이 outer, 가까운 쪽이 inner고, outer끼리·inner끼리 만나게 각 밴드의 along-축 범위를
/// cp별로 정한다(예 ╔: 위 가로=outer는 좌단 outer-세로까지, 아래 가로=inner는 inner-세로부터). T(╠╣╦╩)는
/// 통과 방향 두 선이 full이고 분기 방향 두 선이 spine에서 뻗는다. ╬는 네 선 full(중앙 사각은 자연히 빈다 — 이중
/// 십자). gap(두 선 사이)=선 두께 t, 3t가 셀에 들어가게 t 제한. 베이스=Unicode 이중선 box 기하, Ghostty 동작만 비교.
fn fillDouble(cp: u32, w: u32, h: u32, bytes_per_row: usize, pixels: []u8, t_in: u32) u32 {
    const cx = w / 2;
    const cy = h / 2;
    // 두 선 + gap = 3t가 셀에 들어가게 두께 제한(최소 1). 너무 작은 셀이면 선이 겹쳐도 fillRect가 안전 처리.
    const cap = @max(@as(u32, 1), @min(if (h >= 3) h / 3 else 1, if (w >= 3) w / 3 else 1));
    const t = @max(@as(u32, 1), @min(t_in, cap));
    const half = t / 2;
    // 가로 두 선 밴드 [yU0,yU1)·[yL0,yL1), 세로 두 선 밴드 [xL0,xL1)·[xR0,xR1). 중앙 기준 ±(t+half) 시작 → gap=t.
    const yU0 = cy -| (t + half);
    const yU1 = @min(h, yU0 + t);
    const yL0 = @min(h, yU0 + 2 * t);
    const yL1 = @min(h, yL0 + t);
    const xL0 = cx -| (t + half);
    const xL1 = @min(w, xL0 + t);
    const xR0 = @min(w, xL0 + 2 * t);
    const xR1 = @min(w, xR0 + t);
    const bpr = bytes_per_row;
    var c: u32 = 0;
    switch (cp) {
        0x2550 => { // ═ 두 가로선 full
            c += fillRect(pixels, bpr, 0, yU0, w, yU1);
            c += fillRect(pixels, bpr, 0, yL0, w, yL1);
        },
        0x2551 => { // ║ 두 세로선 full
            c += fillRect(pixels, bpr, xL0, 0, xL1, h);
            c += fillRect(pixels, bpr, xR0, 0, xR1, h);
        },
        0x2554 => { // ╔ down+right (outer 코너 좌상)
            c += fillRect(pixels, bpr, xL0, yU0, w, yU1); // 위 가로(outer): 좌단 outer-세로~우단
            c += fillRect(pixels, bpr, xR0, yL0, w, yL1); // 아래 가로(inner): inner-세로~우단
            c += fillRect(pixels, bpr, xL0, yU0, xL1, h); // 좌 세로(outer): 상단 코너~하단
            c += fillRect(pixels, bpr, xR0, yL0, xR1, h); // 우 세로(inner)
        },
        0x2557 => { // ╗ down+left (outer 코너 우상)
            c += fillRect(pixels, bpr, 0, yU0, xR1, yU1); // 위 가로(outer): 좌단~우단 outer-세로
            c += fillRect(pixels, bpr, 0, yL0, xL1, yL1); // 아래 가로(inner): 좌단~inner-세로
            c += fillRect(pixels, bpr, xL0, yL0, xL1, h); // 좌 세로(inner)
            c += fillRect(pixels, bpr, xR0, yU0, xR1, h); // 우 세로(outer)
        },
        0x255A => { // ╚ up+right (outer 코너 좌하)
            c += fillRect(pixels, bpr, xR0, yU0, w, yU1); // 위 가로(inner)
            c += fillRect(pixels, bpr, xL0, yL0, w, yL1); // 아래 가로(outer)
            c += fillRect(pixels, bpr, xL0, 0, xL1, yL1); // 좌 세로(outer): 상단~하단 코너
            c += fillRect(pixels, bpr, xR0, 0, xR1, yU1); // 우 세로(inner)
        },
        0x255D => { // ╝ up+left (outer 코너 우하)
            c += fillRect(pixels, bpr, 0, yU0, xL1, yU1); // 위 가로(inner)
            c += fillRect(pixels, bpr, 0, yL0, xR1, yL1); // 아래 가로(outer)
            c += fillRect(pixels, bpr, xL0, 0, xL1, yU1); // 좌 세로(inner)
            c += fillRect(pixels, bpr, xR0, 0, xR1, yL1); // 우 세로(outer)
        },
        0x2560 => { // ╠ up+down+right: 세로 두 선 full + 오른쪽 가로 분기
            c += fillRect(pixels, bpr, xL0, 0, xL1, h);
            c += fillRect(pixels, bpr, xR0, 0, xR1, h);
            c += fillRect(pixels, bpr, xL0, yU0, w, yU1);
            c += fillRect(pixels, bpr, xL0, yL0, w, yL1);
        },
        0x2563 => { // ╣ up+down+left
            c += fillRect(pixels, bpr, xL0, 0, xL1, h);
            c += fillRect(pixels, bpr, xR0, 0, xR1, h);
            c += fillRect(pixels, bpr, 0, yU0, xR1, yU1);
            c += fillRect(pixels, bpr, 0, yL0, xR1, yL1);
        },
        0x2566 => { // ╦ down+left+right: 가로 두 선 full + 아래 세로 분기
            c += fillRect(pixels, bpr, 0, yU0, w, yU1);
            c += fillRect(pixels, bpr, 0, yL0, w, yL1);
            c += fillRect(pixels, bpr, xL0, yU0, xL1, h);
            c += fillRect(pixels, bpr, xR0, yU0, xR1, h);
        },
        0x2569 => { // ╩ up+left+right
            c += fillRect(pixels, bpr, 0, yU0, w, yU1);
            c += fillRect(pixels, bpr, 0, yL0, w, yL1);
            c += fillRect(pixels, bpr, xL0, 0, xL1, yL1);
            c += fillRect(pixels, bpr, xR0, 0, xR1, yL1);
        },
        0x256C => { // ╬ all: 네 선 full(중앙 사각은 자연히 빈다)
            c += fillRect(pixels, bpr, 0, yU0, w, yU1);
            c += fillRect(pixels, bpr, 0, yL0, w, yL1);
            c += fillRect(pixels, bpr, xL0, 0, xL1, h);
            c += fillRect(pixels, bpr, xR0, 0, xR1, h);
        },
        else => {},
    }
    return c;
}

/// [x0,x1)×[y0,y1) 픽셀을 흰색 불투명(0xFFFFFFFF)으로. 채운 픽셀 수 반환. RGBA8 + bytes_per_row. 겹쳐도(교차)
/// 멱등이라 안전. 경계는 fillCoverage가 검증(off+4 ≤ h*bpr ≤ len)했으므로 per-pixel 가드 없이 쓴다.
fn fillRect(pixels: []u8, bytes_per_row: usize, x0: u32, y0: u32, x1: u32, y1: u32) u32 {
    if (x1 <= x0 or y1 <= y0) return 0;
    var count: u32 = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        const row_off = @as(usize, y) * bytes_per_row;
        var x = x0;
        while (x < x1) : (x += 1) {
            const off = row_off + @as(usize, x) * 4;
            const was_set = pixels[off + 3] != 0;
            pixels[off] = 0xFF;
            pixels[off + 1] = 0xFF;
            pixels[off + 2] = 0xFF;
            pixels[off + 3] = 0xFF;
            if (!was_set) count += 1; // 교차에서 겹친 픽셀은 한 번만 센다
        }
    }
    return count;
}

test "isBoxDrawing: light·heavy·dashed·double 집합(혼합 굵기는 폴백)" {
    // light
    try std.testing.expect(isBoxDrawing(0x2500)); // ─
    try std.testing.expect(isBoxDrawing(0x253C)); // ┼
    try std.testing.expect(isBoxDrawing(0x256D)); // ╭ (보더 둥근 모서리)
    // heavy
    try std.testing.expect(isBoxDrawing(0x2501)); // ━
    try std.testing.expect(isBoxDrawing(0x250F)); // ┏
    try std.testing.expect(isBoxDrawing(0x254B)); // ╋
    // dashed
    try std.testing.expect(isBoxDrawing(0x2504)); // ┄ triple H
    try std.testing.expect(isBoxDrawing(0x254C)); // ╌ double H
    // double
    try std.testing.expect(isBoxDrawing(0x2550)); // ═
    try std.testing.expect(isBoxDrawing(0x2551)); // ║
    try std.testing.expect(isBoxDrawing(0x2554)); // ╔
    try std.testing.expect(isBoxDrawing(0x256C)); // ╬
    // 폴백(이 모듈 밖)
    try std.testing.expect(!isBoxDrawing(0x250D)); // ┍ 혼합(light/heavy) (후속)
    try std.testing.expect(!isBoxDrawing(0x2552)); // ╒ 혼합(single/double) (후속)
    try std.testing.expect(!isBoxDrawing(0x2588)); // █ block(block_glyph)
    try std.testing.expect(!isBoxDrawing('A'));
}

test "fillCoverage: double ═는 두 가로선(중앙은 gap), ╔는 모서리에서 두 선이 outer/inner로 이어진다" {
    const w: u32 = 16;
    const h: u32 = 32; // light t=2 → 두 선 + gap 6px가 중앙에
    const bpr: usize = w * 4;
    var pixels: [32 * 16 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;
    const cy = h / 2;
    const cx = w / 2;

    // ═ : 세로로 스캔하면 중앙(cy) 근처에 칠/빈/칠(두 선 사이 gap)이 있어야 한다.
    _ = fillCoverage(0x2550, w, h, bpr, &pixels);
    var runs: u32 = 0; // 세로 방향 칠 구간 수(두 선 → 2)
    var prev: u8 = 0;
    for (0..h) |y| {
        const v = a(&pixels, bpr, cx, @intCast(y));
        if (v == 0xFF and prev == 0x00) runs += 1;
        prev = v;
    }
    try std.testing.expectEqual(@as(u32, 2), runs); // 두 가로선
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, cy -| 2)); // 위 선이 좌단 닿음
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy + 2)); // 아래 선이 우단 닿음

    // ╔ : 우단 두 가로선·하단 두 세로선에 닿고(이웃 ═║ 연결), 좌단·상단엔 안 닿는다(모서리).
    _ = fillCoverage(0x2554, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy -| 2)); // 위 가로(outer) 우단
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy + 2)); // 아래 가로(inner) 우단
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx -| 2, h - 1)); // 좌 세로(outer) 하단
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx + 2, h - 1)); // 우 세로(inner) 하단
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, cy -| 2)); // 좌단 안 닿음(모서리)
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, cx -| 2, 0)); // 상단 안 닿음
}

test "fillCoverage: heavy 선이 light보다 굵다(┃ vs │ 중앙 열 두께)" {
    const w: u32 = 16;
    const h: u32 = 32; // light t=(40)/16=2, heavy t=4
    const bpr: usize = w * 4;
    var pixels: [32 * 16 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;
    const cy = h / 2;

    // │ light: 중앙 열 한 행에서 t=2칸 폭.
    _ = fillCoverage(0x2502, w, h, bpr, &pixels);
    var light_w: u32 = 0;
    for (0..w) |x| {
        if (a(&pixels, bpr, @intCast(x), cy) == 0xFF) light_w += 1;
    }
    // ┃ heavy: 같은 행에서 더 넓다(t=4).
    _ = fillCoverage(0x2503, w, h, bpr, &pixels);
    var heavy_w: u32 = 0;
    for (0..w) |x| {
        if (a(&pixels, bpr, @intCast(x), cy) == 0xFF) heavy_w += 1;
    }
    try std.testing.expect(heavy_w > light_w); // heavy가 더 굵다
    try std.testing.expectEqual(@as(u32, 2), light_w);
    try std.testing.expectEqual(@as(u32, 4), heavy_w);
    // heavy도 상·하단에 닿아 이웃과 연결.
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w / 2, 0));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w / 2, h - 1));
}

test "fillCoverage: dashed ┄는 가로로 칠함·빈칸이 번갈아(3 dash)" {
    const w: u32 = 24; // period=8, dash_len=5 → dash 3개, 각 사이 gap
    const h: u32 = 32;
    const bpr: usize = w * 4;
    var pixels: [32 * 24 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;
    const cy = h / 2;

    _ = fillCoverage(0x2504, w, h, bpr, &pixels); // ┄ triple dash H
    // 중앙 행에 칠한 칸과 빈 칸이 둘 다 있어야 한다(실선이 아니라 점선).
    var filled: u32 = 0;
    var empty: u32 = 0;
    for (0..w) |x| {
        if (a(&pixels, bpr, @intCast(x), cy) == 0xFF) filled += 1 else empty += 1;
    }
    try std.testing.expect(filled > 0); // 칠한 칸 있음
    try std.testing.expect(empty > 0); // 빈 칸(gap)도 있음 — 점선
    // gap 위치(period 끝 직전, x=7)는 비고, dash 시작(x=0)은 칠해진다.
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, cy)); // 첫 dash 시작
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 7, cy)); // 첫 period 끝 gap
    // 점선이라 세로 중앙선 위/아래(선 밖)는 빈다.
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, 0));
}

test "fillCoverage: 직선·모서리·교차가 셀 경계까지 닿고 중앙에서 교차한다" {
    const w: u32 = 10;
    const h: u32 = 32; // t=(32+8)/16=2(짝수) → 중앙 띠 [15,17)가 cy=16=h/2을 포함(t=1 홀수면 band가 중앙서 ±0.5 어긋나 테스트만 까다로움; 렌더는 모든 셀 동일 공식이라 이음매 OK)
    const bpr: usize = w * 4;
    var pixels: [32 * 10 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bytes_per_row: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bytes_per_row + @as(usize, x) * 4 + 3];
        }
    }.at;
    const cy = h / 2;
    const cx = w / 2;

    // ─ horizontal: 세로 중앙에 가로선이 좌단~우단까지. 중앙 행은 채우고, 위/아래(선 밖)는 빈다.
    _ = fillCoverage(0x2500, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, cy)); // 좌단 닿음
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy)); // 우단 닿음
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, cx, 0)); // 선 밖(위) 빈다
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, cx, h - 1)); // 아래 빈다

    // │ vertical: 가로 중앙에 세로선이 상단~하단. 중앙 열은 채우고 좌/우는 빈다.
    _ = fillCoverage(0x2502, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, 0)); // 상단 닿음
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, h - 1)); // 하단 닿음
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, cy)); // 좌 빈다

    // ┌ down+right: 우단·하단엔 닿고 좌단·상단엔 안 닿는다(모서리). 중앙 교차는 채움.
    _ = fillCoverage(0x250C, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy)); // 오른쪽 팔
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, h - 1)); // 아래 팔
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, cy)); // 왼쪽 안 닿음
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, cx, 0)); // 위 안 닿음

    // ┼ all: 사거리 — 네 변에 다 닿는다.
    _ = fillCoverage(0x253C, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, cy));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, 0));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, h - 1));
}

test "fillCoverage: 둥근 모서리 ╭는 호로 두 팔을 잇고 직각 코너는 비운다(이웃과 연결 유지)" {
    const w: u32 = 10;
    const h: u32 = 32; // t=2
    const bpr: usize = w * 4;
    var pixels: [32 * 10 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bytes_per_row: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bytes_per_row + @as(usize, x) * 4 + 3];
        }
    }.at;
    const cy = h / 2; // 16
    const cx = w / 2; // 5

    _ = fillCoverage(0x256D, w, h, bpr, &pixels); // ╭ (right+down 둥근)
    // 이웃 연결: 우단 가로선(y=cy 띠)·하단 세로선(x=cx 띠)에 닿아야 ─/│ 이웃과 이어진다.
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy)); // 우단 → ─ 연결
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, h - 1)); // 하단 → │ 연결
    // ╭는 좌·상으로 안 뻗는다 — 좌단 가로/상단 세로는 빈다.
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, cy)); // 좌단 빈다
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, cx, 0)); // 상단 빈다
    // 둥근 효과: 직각 코너점(좌상 바깥 0,0)과 반대 코너(우하 w-1,h-1)는 비어야 한다.
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, 0)); // 좌상 바깥
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, w - 1, h - 1)); // 우하(╭ 영역 아님)
}
