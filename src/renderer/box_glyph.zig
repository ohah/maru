//! Box-drawing(U+2500~U+257F) 글리프 합성 — 폰트 글리프 대신 셀에 얇은 선을 직접 그려 **셀 경계에서 이음매
//! 없이 연결**한다(폰트 글리프는 셀에 안 맞아 선이 끊기거나 안 보인다 — TUI 보더 `─│╭╮`). block_glyph와 같은
//! 원리: 슬롯이 cell 크기 + 셀 셰이더 nearest 샘플 + alpha coverage라, 슬롯 alpha에 정수 픽셀 선을 채우면
//! 1:1 픽셀-퍼펙트로 셀에 그려진다.
//!
//! **arm 모델(per-arm 굵기)**: 각 box 문자는 셀 중앙에서 상/하/좌/우로 뻗는 팔의 조합이고 **팔마다 굵기**(light/
//! heavy/double)를 든다(Ghostty linesChar와 같은 모델). 가로 팔은 세로 중앙의 t-두께 띠, 세로 팔은 가로 중앙의
//! t-두께 띠로 그리고, 각 팔을 **셀 경계까지** 뻗어(left→x=0…down→y=h) 이웃 셀과 맞닿게 한다. 중앙 교차(가장 굵은
//! 세로 팔 폭 × 가장 굵은 가로 팔 높이)를 모두가 덮어 모서리(┌)·T(├)·사거리(┼)·**혼합 굵기**(┞=up heavy)가 자연히 된다.
//!
//! 범위: **U+2500~257F 전체**. 직선 ─━│┃ · 모서리 ┌┍┎┏ … · T ├┝┞ … · 사거리 ┼┽ …(light·heavy·**혼합**) +
//! dashed(┄…┋ 2·3·4점선, ╌╍╎╏) + 둥근 ╭╮╰╯(**실제 quarter-arc**) + double(═║·╔╗╚╝·╠╣╦╩·╬ — 모서리 outer/inner)
//! + single↔double 혼합(╒╓ ╞╟ ╤╥ ╪╫ … — 일반 band 모델 fillMixed, double과 선 위치 일치해 연결) + 대각선
//! (╱╲╳ — 거리 기반) + 반선·두께전이(╴╵╶╷╸╹╺╻╼╽╾╿). 베이스 = Unicode Box Drawing 기하(굵기·점선·이중 분류는
//! Unicode 문자명 그대로). Ghostty font/sprite/draw/box.zig 동작만 비교(코드 미복사 — clean-room). 중립 모듈.

const std = @import("std");
const gp = @import("glyph_pixels.zig"); // 슬롯 검증·clear·fillRect·setPixel·대각선 공유 프리미티브(단일 출처).

/// 팔 굵기. light·heavy 혼합(┍┞ 등)을 한 모델로 다루려고 팔마다 굵기를 든다. double은 두 평행선(fillDouble).
const Weight = enum { light, heavy, double };

/// 셀 중앙에서 뻗는 팔 — 방향별 굵기(없으면 null). 가로(left/right)·세로(up/down) 조합 + per-arm 굵기로 직선·
/// 모서리·교차·반선(╴╵)·혼합 굵기(┍┞)·이중선을 모두 표현한다(Ghostty linesChar와 같은 per-arm-weight 모델).
const Arms = struct { up: ?Weight = null, down: ?Weight = null, left: ?Weight = null, right: ?Weight = null };

/// 대각선 종류(코너↔코너 선). ╱(fwd)·╲(back)·╳(둘 다). arm 모델 밖이라 fillDiagonal가 거리 기반으로 그린다.
const Diagonal = enum { none, forward, backward, cross };

/// box 문자 한 글자의 합성 명세: 팔(방향별 굵기) + 점선 개수(dash) + 둥근 모서리(rounded) + 대각선(diagonal).
const Spec = struct {
    arms: Arms = .{},
    dash: u8 = 0, // 0=실선, 2/3/4=점선 개수(직선 전용 — Unicode double/triple/quadruple dash)
    rounded: bool = false, // ╭╮╰╯ quarter-arc(light 전용)
    diagonal: Diagonal = .none, // ╱╲╳ — arm 모델 밖, fillDiagonal
};

/// cp가 합성 대상 box-drawing 문자인지 — **U+2500~257F 전체**(직선·모서리·T·사거리·dashed·둥근·이중선·
/// single↔double 혼합·대각선·반선, light·heavy·혼합 굵기 전부). 그 밖이면 false(폰트 폴백).
pub fn isBoxDrawing(cp: u32) bool {
    return specFor(cp) != null;
}

const L: Weight = .light;
const H: Weight = .heavy;
const D: Weight = .double;

/// cp → 합성 명세. 덮지 않는 문자면 null. 굵기 분류는 Unicode 문자명(LIGHT/HEAVY/DOUBLE) 조합 그대로.
fn specFor(cp: u32) ?Spec {
    return switch (cp) {
        // ── 직선 ─━│┃ ──
        0x2500 => .{ .arms = .{ .left = L, .right = L } }, // ─
        0x2501 => .{ .arms = .{ .left = H, .right = H } }, // ━
        0x2502 => .{ .arms = .{ .up = L, .down = L } }, // │
        0x2503 => .{ .arms = .{ .up = H, .down = H } }, // ┃
        // ── dashed(점선, 직선 전용) ──
        0x2504 => .{ .arms = .{ .left = L, .right = L }, .dash = 3 }, // ┄
        0x2505 => .{ .arms = .{ .left = H, .right = H }, .dash = 3 }, // ┅
        0x2506 => .{ .arms = .{ .up = L, .down = L }, .dash = 3 }, // ┆
        0x2507 => .{ .arms = .{ .up = H, .down = H }, .dash = 3 }, // ┇
        0x2508 => .{ .arms = .{ .left = L, .right = L }, .dash = 4 }, // ┈
        0x2509 => .{ .arms = .{ .left = H, .right = H }, .dash = 4 }, // ┉
        0x250A => .{ .arms = .{ .up = L, .down = L }, .dash = 4 }, // ┊
        0x250B => .{ .arms = .{ .up = H, .down = H }, .dash = 4 }, // ┋
        // ── 모서리 down+right ┌┍┎┏ ──
        0x250C => .{ .arms = .{ .down = L, .right = L } }, // ┌
        0x250D => .{ .arms = .{ .down = L, .right = H } }, // ┍
        0x250E => .{ .arms = .{ .down = H, .right = L } }, // ┎
        0x250F => .{ .arms = .{ .down = H, .right = H } }, // ┏
        // 모서리 down+left ┐┑┒┓
        0x2510 => .{ .arms = .{ .down = L, .left = L } }, // ┐
        0x2511 => .{ .arms = .{ .down = L, .left = H } }, // ┑
        0x2512 => .{ .arms = .{ .down = H, .left = L } }, // ┒
        0x2513 => .{ .arms = .{ .down = H, .left = H } }, // ┓
        // 모서리 up+right └┕┖┗
        0x2514 => .{ .arms = .{ .up = L, .right = L } }, // └
        0x2515 => .{ .arms = .{ .up = L, .right = H } }, // ┕
        0x2516 => .{ .arms = .{ .up = H, .right = L } }, // ┖
        0x2517 => .{ .arms = .{ .up = H, .right = H } }, // ┗
        // 모서리 up+left ┘┙┚┛
        0x2518 => .{ .arms = .{ .up = L, .left = L } }, // ┘
        0x2519 => .{ .arms = .{ .up = L, .left = H } }, // ┙
        0x251A => .{ .arms = .{ .up = H, .left = L } }, // ┚
        0x251B => .{ .arms = .{ .up = H, .left = H } }, // ┛
        // ── T: vertical+right ├┝┞┟┠┡┢┣ ──
        0x251C => .{ .arms = .{ .up = L, .down = L, .right = L } }, // ├
        0x251D => .{ .arms = .{ .up = L, .down = L, .right = H } }, // ┝
        0x251E => .{ .arms = .{ .up = H, .down = L, .right = L } }, // ┞
        0x251F => .{ .arms = .{ .up = L, .down = H, .right = L } }, // ┟
        0x2520 => .{ .arms = .{ .up = H, .down = H, .right = L } }, // ┠
        0x2521 => .{ .arms = .{ .up = H, .down = L, .right = H } }, // ┡
        0x2522 => .{ .arms = .{ .up = L, .down = H, .right = H } }, // ┢
        0x2523 => .{ .arms = .{ .up = H, .down = H, .right = H } }, // ┣
        // T: vertical+left ┤┥┦┧┨┩┪┫
        0x2524 => .{ .arms = .{ .up = L, .down = L, .left = L } }, // ┤
        0x2525 => .{ .arms = .{ .up = L, .down = L, .left = H } }, // ┥
        0x2526 => .{ .arms = .{ .up = H, .down = L, .left = L } }, // ┦
        0x2527 => .{ .arms = .{ .up = L, .down = H, .left = L } }, // ┧
        0x2528 => .{ .arms = .{ .up = H, .down = H, .left = L } }, // ┨
        0x2529 => .{ .arms = .{ .up = H, .down = L, .left = H } }, // ┩
        0x252A => .{ .arms = .{ .up = L, .down = H, .left = H } }, // ┪
        0x252B => .{ .arms = .{ .up = H, .down = H, .left = H } }, // ┫
        // T: horizontal+down ┬┭┮┯┰┱┲┳
        0x252C => .{ .arms = .{ .down = L, .left = L, .right = L } }, // ┬
        0x252D => .{ .arms = .{ .down = L, .left = H, .right = L } }, // ┭
        0x252E => .{ .arms = .{ .down = L, .left = L, .right = H } }, // ┮
        0x252F => .{ .arms = .{ .down = L, .left = H, .right = H } }, // ┯
        0x2530 => .{ .arms = .{ .down = H, .left = L, .right = L } }, // ┰
        0x2531 => .{ .arms = .{ .down = H, .left = H, .right = L } }, // ┱
        0x2532 => .{ .arms = .{ .down = H, .left = L, .right = H } }, // ┲
        0x2533 => .{ .arms = .{ .down = H, .left = H, .right = H } }, // ┳
        // T: horizontal+up ┴┵┶┷┸┹┺┻
        0x2534 => .{ .arms = .{ .up = L, .left = L, .right = L } }, // ┴
        0x2535 => .{ .arms = .{ .up = L, .left = H, .right = L } }, // ┵
        0x2536 => .{ .arms = .{ .up = L, .left = L, .right = H } }, // ┶
        0x2537 => .{ .arms = .{ .up = L, .left = H, .right = H } }, // ┷
        0x2538 => .{ .arms = .{ .up = H, .left = L, .right = L } }, // ┸
        0x2539 => .{ .arms = .{ .up = H, .left = H, .right = L } }, // ┹
        0x253A => .{ .arms = .{ .up = H, .left = L, .right = H } }, // ┺
        0x253B => .{ .arms = .{ .up = H, .left = H, .right = H } }, // ┻
        // ── 사거리 ┼┽┾┿╀╁╂╃╄╅╆╇╈╉╊╋ ──
        0x253C => .{ .arms = .{ .up = L, .down = L, .left = L, .right = L } }, // ┼
        0x253D => .{ .arms = .{ .up = L, .down = L, .left = H, .right = L } }, // ┽
        0x253E => .{ .arms = .{ .up = L, .down = L, .left = L, .right = H } }, // ┾
        0x253F => .{ .arms = .{ .up = L, .down = L, .left = H, .right = H } }, // ┿
        0x2540 => .{ .arms = .{ .up = H, .down = L, .left = L, .right = L } }, // ╀
        0x2541 => .{ .arms = .{ .up = L, .down = H, .left = L, .right = L } }, // ╁
        0x2542 => .{ .arms = .{ .up = H, .down = H, .left = L, .right = L } }, // ╂
        0x2543 => .{ .arms = .{ .up = H, .down = L, .left = H, .right = L } }, // ╃
        0x2544 => .{ .arms = .{ .up = H, .down = L, .left = L, .right = H } }, // ╄
        0x2545 => .{ .arms = .{ .up = L, .down = H, .left = H, .right = L } }, // ╅
        0x2546 => .{ .arms = .{ .up = L, .down = H, .left = L, .right = H } }, // ╆
        0x2547 => .{ .arms = .{ .up = H, .down = L, .left = H, .right = H } }, // ╇
        0x2548 => .{ .arms = .{ .up = L, .down = H, .left = H, .right = H } }, // ╈
        0x2549 => .{ .arms = .{ .up = H, .down = H, .left = H, .right = L } }, // ╉
        0x254A => .{ .arms = .{ .up = H, .down = H, .left = L, .right = H } }, // ╊
        0x254B => .{ .arms = .{ .up = H, .down = H, .left = H, .right = H } }, // ╋
        // ── dashed 2점선 ╌╍╎╏ ──
        0x254C => .{ .arms = .{ .left = L, .right = L }, .dash = 2 }, // ╌
        0x254D => .{ .arms = .{ .left = H, .right = H }, .dash = 2 }, // ╍
        0x254E => .{ .arms = .{ .up = L, .down = L }, .dash = 2 }, // ╎
        0x254F => .{ .arms = .{ .up = H, .down = H }, .dash = 2 }, // ╏
        // ── double(이중선, pure) ── (arms=double 방향, 실제 band는 fillDouble가 cp별)
        0x2550 => .{ .arms = .{ .left = D, .right = D } }, // ═
        0x2551 => .{ .arms = .{ .up = D, .down = D } }, // ║
        0x2554 => .{ .arms = .{ .down = D, .right = D } }, // ╔
        0x2557 => .{ .arms = .{ .down = D, .left = D } }, // ╗
        0x255A => .{ .arms = .{ .up = D, .right = D } }, // ╚
        0x255D => .{ .arms = .{ .up = D, .left = D } }, // ╝
        0x2560 => .{ .arms = .{ .up = D, .down = D, .right = D } }, // ╠
        0x2563 => .{ .arms = .{ .up = D, .down = D, .left = D } }, // ╣
        0x2566 => .{ .arms = .{ .down = D, .left = D, .right = D } }, // ╦
        0x2569 => .{ .arms = .{ .up = D, .left = D, .right = D } }, // ╩
        0x256C => .{ .arms = .{ .up = D, .down = D, .left = D, .right = D } }, // ╬
        // ── single↔double 혼합(한 축 light, 다른 축 double) — fillMixed(일반 band 모델) ──
        0x2552 => .{ .arms = .{ .down = L, .right = D } }, // ╒
        0x2553 => .{ .arms = .{ .down = D, .right = L } }, // ╓
        0x2555 => .{ .arms = .{ .down = L, .left = D } }, // ╕
        0x2556 => .{ .arms = .{ .down = D, .left = L } }, // ╖
        0x2558 => .{ .arms = .{ .up = L, .right = D } }, // ╘
        0x2559 => .{ .arms = .{ .up = D, .right = L } }, // ╙
        0x255B => .{ .arms = .{ .up = L, .left = D } }, // ╛
        0x255C => .{ .arms = .{ .up = D, .left = L } }, // ╜
        0x255E => .{ .arms = .{ .up = L, .down = L, .right = D } }, // ╞
        0x255F => .{ .arms = .{ .up = D, .down = D, .right = L } }, // ╟
        0x2561 => .{ .arms = .{ .up = L, .down = L, .left = D } }, // ╡
        0x2562 => .{ .arms = .{ .up = D, .down = D, .left = L } }, // ╢
        0x2564 => .{ .arms = .{ .down = L, .left = D, .right = D } }, // ╤
        0x2565 => .{ .arms = .{ .down = D, .left = L, .right = L } }, // ╥
        0x2567 => .{ .arms = .{ .up = L, .left = D, .right = D } }, // ╧
        0x2568 => .{ .arms = .{ .up = D, .left = L, .right = L } }, // ╨
        0x256A => .{ .arms = .{ .up = L, .down = L, .left = D, .right = D } }, // ╪
        0x256B => .{ .arms = .{ .up = D, .down = D, .left = L, .right = L } }, // ╫
        // ── 둥근 모서리(light arc) ╭╮╯╰ ──
        0x256D => .{ .arms = .{ .down = L, .right = L }, .rounded = true }, // ╭
        0x256E => .{ .arms = .{ .down = L, .left = L }, .rounded = true }, // ╮
        0x256F => .{ .arms = .{ .up = L, .left = L }, .rounded = true }, // ╯
        0x2570 => .{ .arms = .{ .up = L, .right = L }, .rounded = true }, // ╰
        // ── 반선(half line) ╴╵╶╷╸╹╺╻ + 혼합 두께 전이 ╼╽╾╿ ──
        0x2574 => .{ .arms = .{ .left = L } }, // ╴
        0x2575 => .{ .arms = .{ .up = L } }, // ╵
        0x2576 => .{ .arms = .{ .right = L } }, // ╶
        0x2577 => .{ .arms = .{ .down = L } }, // ╷
        0x2578 => .{ .arms = .{ .left = H } }, // ╸
        0x2579 => .{ .arms = .{ .up = H } }, // ╹
        0x257A => .{ .arms = .{ .right = H } }, // ╺
        0x257B => .{ .arms = .{ .down = H } }, // ╻
        0x257C => .{ .arms = .{ .left = L, .right = H } }, // ╼ light left + heavy right
        0x257D => .{ .arms = .{ .up = L, .down = H } }, // ╽
        0x257E => .{ .arms = .{ .left = H, .right = L } }, // ╾
        0x257F => .{ .arms = .{ .up = H, .down = L } }, // ╿
        // ── 대각선 ╱╲╳ ──
        0x2571 => .{ .diagonal = .forward }, // ╱ (좌하→우상)
        0x2572 => .{ .diagonal = .backward }, // ╲ (좌상→우하)
        0x2573 => .{ .diagonal = .cross }, // ╳
        else => null,
    };
}

fn isDoubleArm(arm: ?Weight) bool {
    return if (arm) |wt| wt == .double else false;
}

fn armsHaveDouble(a: Arms) bool {
    return isDoubleArm(a.up) or isDoubleArm(a.down) or isDoubleArm(a.left) or isDoubleArm(a.right);
}

/// present 팔이 전부 double인지(pure double ═║╔ → fillDouble의 outer/inner notch). 하나라도 light면 false
/// → single↔double 혼합(╒╞ 등)은 fillMixed.
fn armsAllDouble(a: Arms) bool {
    const ok = struct {
        fn f(arm: ?Weight) bool {
            return if (arm) |wt| wt == .double else true; // 없는 팔은 무시(true)
        }
    }.f;
    return ok(a.up) and ok(a.down) and ok(a.left) and ok(a.right);
}

/// 팔 굵기 → device px 두께(light/heavy 전용). double 팔은 fillCoverage가 fillDouble/fillMixed로 먼저 분기하므로
/// weightT까지 오지 않는다(dashed·fillLines는 light/heavy만). 그 불변식을 어기면 잡으려고 .double은 unreachable.
fn weightT(wt: Weight, lt: u32, ht: u32) u32 {
    return switch (wt) {
        .light => lt,
        .heavy => ht,
        .double => unreachable, // double 팔은 여기 도달 불가(fillDouble/fillMixed가 처리)
    };
}

/// 이중선 두 평행선 + gap = 3t가 셀에 들어가게 두께를 제한한다(최소 1). fillDouble·fillMixed가 **같은 선 위치**를
/// 쓰도록 cap/t/half/d 계산을 단일 출처로 둔다(따로 계산하면 둘이 어긋나 ═↔╤ 이음매가 깨진다). d=gap=t.
const DoubleBand = struct { t: u32, half: u32, d: u32 };
fn doubleBandParams(w: u32, h: u32, t_in: u32) DoubleBand {
    const cap = @max(@as(u32, 1), @min(if (h >= 3) h / 3 else 1, if (w >= 3) w / 3 else 1));
    const t = @max(@as(u32, 1), @min(t_in, cap));
    return .{ .t = t, .half = t / 2, .d = t };
}

/// cp box 문자를 width×height RGBA8 슬롯에 coverage로 채운다 — 선은 흰색 불투명(0xFFFFFFFF, 셰이더가 alpha를
/// coverage로 읽어 전경색으로), 나머지 0. 채운 픽셀 수 반환. isBoxDrawing(cp) 가정. 선 두께 t는 cell 높이 비례
/// (light, 최소 1px), 중앙 정렬·정수 픽셀 스냅. 버퍼 계약(bpr≥w*4·len≥h*bpr) 위반 시 빈 글리프로 안전 degrade.
pub fn fillCoverage(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) u32 {
    const w = width_px;
    const h = height_px;
    if (!gp.slotFits(w, h, bytes_per_row, pixels)) return 0;
    const spec = specFor(cp) orelse return 0;
    gp.clear(pixels, h, bytes_per_row);

    // 선 두께(device px) — light는 cell 높이 비례(최소 1), heavy는 그 2배. cell보다 두껍지 않게(언더플로 방지).
    var lt: u32 = (h + 8) / 16;
    if (lt < 1) lt = 1;
    lt = @min(lt, @min(w, h));
    const ht: u32 = @min(lt * 2, @min(w, h));
    const arms = spec.arms;

    // 대각선(╱╲╳): 코너↔코너 선이라 arm 모델 밖 — 공유 대각선 프리미티브로 light 두께만큼 칠한다(Powerline
    // 모서리 thin 대각선과 같은 식). backward=╲, forward=╱, cross=둘 다.
    if (spec.diagonal != .none) {
        const do_back = spec.diagonal == .backward or spec.diagonal == .cross;
        const do_fwd = spec.diagonal == .forward or spec.diagonal == .cross;
        return gp.fillDiagonal(pixels, bytes_per_row, w, h, lt, do_back, do_fwd);
    }

    // 둥근 모서리(╭╮╰╯)는 직각 대신 quarter-arc로 — 두 팔 방향(h_dir·v_dir)으로 아크 코너를 그린다(light).
    if (spec.rounded) {
        const t = lt;
        const yb0 = (h - t) / 2;
        const yb1 = yb0 + t;
        const xb0 = (w - t) / 2;
        const xb1 = xb0 + t;
        return switch (cp) {
            0x256D => fillRoundedCorner(pixels, bytes_per_row, w, h, t, yb0, yb1, xb0, xb1, 1, 1), // ╭ right+down
            0x256E => fillRoundedCorner(pixels, bytes_per_row, w, h, t, yb0, yb1, xb0, xb1, -1, 1), // ╮ left+down
            0x256F => fillRoundedCorner(pixels, bytes_per_row, w, h, t, yb0, yb1, xb0, xb1, -1, -1), // ╯ left+up
            0x2570 => fillRoundedCorner(pixels, bytes_per_row, w, h, t, yb0, yb1, xb0, xb1, 1, -1), // ╰ right+up
            else => 0,
        };
    }

    // 점선(직선 전용): 셀 폭/높이를 dash개 주기로 나눠 각 주기 앞 2/3만 칠한다(뒤 1/3 gap). 팔 굵기(light/heavy)
    // 로 띠 두께를 정한다. dashed는 모서리/교차가 없어(Unicode 점선은 직선뿐) 가로(left)·세로(up) 한쪽만 산다.
    if (spec.dash > 0) {
        var count: u32 = 0;
        if (arms.left) |wt| {
            const t = @min(weightT(wt, lt, ht), h);
            const yb0 = (h - t) / 2;
            count += fillDashedH(pixels, bytes_per_row, w, yb0, yb0 + t, spec.dash);
        }
        if (arms.up) |wt| {
            const t = @min(weightT(wt, lt, ht), w);
            const xb0 = (w - t) / 2;
            count += fillDashedV(pixels, bytes_per_row, h, xb0, xb0 + t, spec.dash);
        }
        return count;
    }

    if (armsHaveDouble(arms)) {
        // pure double(전 팔 double)은 모서리 outer/inner notch를 위해 cp별 fillDouble. single↔double 혼합
        // (한 축 light, 다른 축 double)은 일반 band 모델 fillMixed — fillDouble과 같은 선 위치라 이음매 없이 연결.
        if (armsAllDouble(arms)) return fillDouble(cp, w, h, bytes_per_row, pixels, lt);
        return fillMixed(arms, w, h, bytes_per_row, pixels, lt);
    }

    // light/heavy(혼합 포함) 선·모서리·교차·반선: 각 팔을 자기 굵기로 그리고 중앙 교차에서 합친다.
    return fillLines(arms, w, h, bytes_per_row, pixels, lt, ht);
}

/// light/heavy(+혼합) 팔들을 합성한다. 각 팔은 자기 굵기 띠로 셀 경계까지 뻗고, 중앙 교차(가장 굵은 세로 팔
/// 폭 × 가장 굵은 가로 팔 높이)를 모두가 덮어 모서리(┌┍)·T(├┞)·사거리(┼╀)·반선(╴╵)이 자연히 이어진다.
/// 혼합 굵기(┞: up heavy + down/right light)는 팔마다 다른 두께가 같은 중앙에 모여 한 모델로 처리된다.
fn fillLines(arms: Arms, w: u32, h: u32, bytes_per_row: usize, pixels: []u8, lt: u32, ht: u32) u32 {
    const cx = w / 2;
    const cy = h / 2;
    const tu: u32 = if (arms.up) |wt| weightT(wt, lt, ht) else 0;
    const td: u32 = if (arms.down) |wt| weightT(wt, lt, ht) else 0;
    const tl: u32 = if (arms.left) |wt| weightT(wt, lt, ht) else 0;
    const tr: u32 = if (arms.right) |wt| weightT(wt, lt, ht) else 0;
    // 중앙 교차 박스: 세로 팔 최대 두께 = 가로폭, 가로 팔 최대 두께 = 세로높이. 각 팔이 이 박스 반대변까지 뻗어 겹친다.
    const max_v = @max(tu, td);
    const max_h = @max(tl, tr);
    const cbx0 = cx -| max_v / 2;
    const cbx1 = @min(w, cbx0 + max_v);
    const cby0 = cy -| max_h / 2;
    const cby1 = @min(h, cby0 + max_h);
    var count: u32 = 0;
    if (tl > 0) {
        const y0 = cy -| tl / 2;
        count += gp.fillRect(pixels, bytes_per_row, 0, y0, cbx1, @min(h, y0 + tl)); // 좌단~중앙 교차 우변
    }
    if (tr > 0) {
        const y0 = cy -| tr / 2;
        count += gp.fillRect(pixels, bytes_per_row, cbx0, y0, w, @min(h, y0 + tr)); // 중앙 교차 좌변~우단
    }
    if (tu > 0) {
        const x0 = cx -| tu / 2;
        count += gp.fillRect(pixels, bytes_per_row, x0, 0, @min(w, x0 + tu), cby1); // 상단~중앙 교차 하변
    }
    if (td > 0) {
        const x0 = cx -| td / 2;
        count += gp.fillRect(pixels, bytes_per_row, x0, cby0, @min(w, x0 + td), h); // 중앙 교차 상변~하단
    }
    return count;
}

/// 대각선(╱╲╳)을 코너↔코너 선으로 합성한다. 픽셀 중심(+0.5)에서 선까지 수직거리가 t/2 이하면 칠한다 — ╲는
/// (0,0)→(w,h), ╱는 (0,h)→(w,0). 셀 코너를 지나므로 대각으로 이웃한 셀의 같은 대각선과 코너에서 이어진다.
/// 거리 정규화로 w≠h(비정사각 셀)에서도 두께가 일정. cross(╳)는 둘 다.
/// 가로 점선: 폭 w를 n개 주기(period=w/n)로 나눠 각 주기의 앞 dash_len(=period의 2/3)만 [yb0,yb1) 높이로 칠한다.
/// period가 0이면(셀이 점선보다 좁음) 실선으로 안전 degrade. 셀마다 동일 패턴이라 점선이 셀 경계 너머로 이어진다.
fn fillDashedH(pixels: []u8, bytes_per_row: usize, w: u32, yb0: u32, yb1: u32, n: u8) u32 {
    const period = w / n;
    if (period == 0) return gp.fillRect(pixels, bytes_per_row, 0, yb0, w, yb1);
    const dash_len = @max(@as(u32, 1), period * 2 / 3);
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const x0 = i * period;
        count += gp.fillRect(pixels, bytes_per_row, x0, yb0, @min(w, x0 + dash_len), yb1);
    }
    return count;
}

/// 세로 점선(fillDashedH의 세로판): 높이 h를 n주기로 나눠 각 주기 앞 2/3만 [xb0,xb1) 폭으로 칠한다.
fn fillDashedV(pixels: []u8, bytes_per_row: usize, h: u32, xb0: u32, xb1: u32, n: u8) u32 {
    const period = h / n;
    if (period == 0) return gp.fillRect(pixels, bytes_per_row, xb0, 0, xb1, h);
    const dash_len = @max(@as(u32, 1), period * 2 / 3);
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const y0 = i * period;
        count += gp.fillRect(pixels, bytes_per_row, xb0, y0, xb1, @min(h, y0 + dash_len));
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
                gp.setPixel(pixels, @as(usize, y) * bytes_per_row + @as(usize, x) * 4);
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
    // 두 선 위치는 fillMixed와 같은 단일 출처(doubleBandParams)에서. 너무 작은 셀이면 선이 겹쳐도 fillRect가 안전 처리.
    const band = doubleBandParams(w, h, t_in);
    const t = band.t;
    const half = band.half;
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
            c += gp.fillRect(pixels, bpr, 0, yU0, w, yU1);
            c += gp.fillRect(pixels, bpr, 0, yL0, w, yL1);
        },
        0x2551 => { // ║ 두 세로선 full
            c += gp.fillRect(pixels, bpr, xL0, 0, xL1, h);
            c += gp.fillRect(pixels, bpr, xR0, 0, xR1, h);
        },
        0x2554 => { // ╔ down+right (outer 코너 좌상)
            c += gp.fillRect(pixels, bpr, xL0, yU0, w, yU1); // 위 가로(outer): 좌단 outer-세로~우단
            c += gp.fillRect(pixels, bpr, xR0, yL0, w, yL1); // 아래 가로(inner): inner-세로~우단
            c += gp.fillRect(pixels, bpr, xL0, yU0, xL1, h); // 좌 세로(outer): 상단 코너~하단
            c += gp.fillRect(pixels, bpr, xR0, yL0, xR1, h); // 우 세로(inner)
        },
        0x2557 => { // ╗ down+left (outer 코너 우상)
            c += gp.fillRect(pixels, bpr, 0, yU0, xR1, yU1); // 위 가로(outer): 좌단~우단 outer-세로
            c += gp.fillRect(pixels, bpr, 0, yL0, xL1, yL1); // 아래 가로(inner): 좌단~inner-세로
            c += gp.fillRect(pixels, bpr, xL0, yL0, xL1, h); // 좌 세로(inner)
            c += gp.fillRect(pixels, bpr, xR0, yU0, xR1, h); // 우 세로(outer)
        },
        0x255A => { // ╚ up+right (outer 코너 좌하)
            c += gp.fillRect(pixels, bpr, xR0, yU0, w, yU1); // 위 가로(inner)
            c += gp.fillRect(pixels, bpr, xL0, yL0, w, yL1); // 아래 가로(outer)
            c += gp.fillRect(pixels, bpr, xL0, 0, xL1, yL1); // 좌 세로(outer): 상단~하단 코너
            c += gp.fillRect(pixels, bpr, xR0, 0, xR1, yU1); // 우 세로(inner)
        },
        0x255D => { // ╝ up+left (outer 코너 우하)
            c += gp.fillRect(pixels, bpr, 0, yU0, xL1, yU1); // 위 가로(inner)
            c += gp.fillRect(pixels, bpr, 0, yL0, xR1, yL1); // 아래 가로(outer)
            c += gp.fillRect(pixels, bpr, xL0, 0, xL1, yU1); // 좌 세로(inner)
            c += gp.fillRect(pixels, bpr, xR0, 0, xR1, yL1); // 우 세로(outer)
        },
        0x2560 => { // ╠ up+down+right: 세로 두 선 full + 오른쪽 가로 분기
            c += gp.fillRect(pixels, bpr, xL0, 0, xL1, h);
            c += gp.fillRect(pixels, bpr, xR0, 0, xR1, h);
            c += gp.fillRect(pixels, bpr, xL0, yU0, w, yU1);
            c += gp.fillRect(pixels, bpr, xL0, yL0, w, yL1);
        },
        0x2563 => { // ╣ up+down+left
            c += gp.fillRect(pixels, bpr, xL0, 0, xL1, h);
            c += gp.fillRect(pixels, bpr, xR0, 0, xR1, h);
            c += gp.fillRect(pixels, bpr, 0, yU0, xR1, yU1);
            c += gp.fillRect(pixels, bpr, 0, yL0, xR1, yL1);
        },
        0x2566 => { // ╦ down+left+right: 가로 두 선 full + 아래 세로 분기
            c += gp.fillRect(pixels, bpr, 0, yU0, w, yU1);
            c += gp.fillRect(pixels, bpr, 0, yL0, w, yL1);
            c += gp.fillRect(pixels, bpr, xL0, yU0, xL1, h);
            c += gp.fillRect(pixels, bpr, xR0, yU0, xR1, h);
        },
        0x2569 => { // ╩ up+left+right
            c += gp.fillRect(pixels, bpr, 0, yU0, w, yU1);
            c += gp.fillRect(pixels, bpr, 0, yL0, w, yL1);
            c += gp.fillRect(pixels, bpr, xL0, 0, xL1, yL1);
            c += gp.fillRect(pixels, bpr, xR0, 0, xR1, yL1);
        },
        0x256C => { // ╬ all: 네 선 full(중앙 사각은 자연히 빈다)
            c += gp.fillRect(pixels, bpr, 0, yU0, w, yU1);
            c += gp.fillRect(pixels, bpr, 0, yL0, w, yL1);
            c += gp.fillRect(pixels, bpr, xL0, 0, xL1, h);
            c += gp.fillRect(pixels, bpr, xR0, 0, xR1, h);
        },
        else => {},
    }
    return c;
}

/// single↔double 혼합(╒╓ ╞╟ ╤╥ ╪╫ …)을 일반 band 모델로 합성한다. 한 축은 light(한 선, 중앙), 다른 축은
/// double(두 선, 중앙±d). 각 선의 along-축 범위 = present 방향이면 셀 경계, 아니면 수직선들이 차지하는 중앙
/// span까지(코너/T 연결). double 선 위치(중앙±t, gap=t)는 fillDouble과 동일해 이중 박스와 이음매 없이 잇는다.
fn fillMixed(arms: Arms, w: u32, h: u32, bytes_per_row: usize, pixels: []u8, t_in: u32) u32 {
    const cx = w / 2;
    const cy = h / 2;
    // 두 선 위치는 fillDouble과 같은 단일 출처(doubleBandParams) → 선 위치 일치해 이음매 없이 연결.
    const band = doubleBandParams(w, h, t_in);
    const t = band.t;
    const half = band.half;
    const d = band.d; // double 선 중앙 오프셋(gap=t)

    // 가로 선 y-중앙들(없으면 0개), 세로 선 x-중앙들. left/right는 같은 굵기, up/down도 같은 굵기(혼합 집합 규약).
    const hw: ?Weight = arms.left orelse arms.right;
    const vw: ?Weight = arms.up orelse arms.down;
    var hy: [2]u32 = undefined;
    var hyn: usize = 0;
    if (hw) |wt| {
        if (wt == .double) {
            hy[0] = cy -| d;
            hy[1] = cy + d;
            hyn = 2;
        } else {
            hy[0] = cy;
            hyn = 1;
        }
    }
    var vx: [2]u32 = undefined;
    var vxn: usize = 0;
    if (vw) |wt| {
        if (wt == .double) {
            vx[0] = cx -| d;
            vx[1] = cx + d;
            vxn = 2;
        } else {
            vx[0] = cx;
            vxn = 1;
        }
    }
    // band [c-half, c-half+t). 중앙 span = 모든 세로선이 차지하는 x범위 / 모든 가로선의 y범위(코너/T 연결점).
    const cxmin = if (vxn > 0) vx[0] -| half else cx;
    const cxmax = if (vxn > 0) @min(w, vx[vxn - 1] -| half + t) else cx;
    const cymin = if (hyn > 0) hy[0] -| half else cy;
    const cymax = if (hyn > 0) @min(h, hy[hyn - 1] -| half + t) else cy;

    // 한쪽만 있는 single 가지가 **꽉 찬 이중 벽**(양방향 존재)을 만나면 안쪽 선에 부착한다(바깥 선까지
    // 뻗어 gap을 가로지르지 않음). ╟╢(이중 세로벽+single 가로 stub)·╤╧(이중 가로벽+single 세로 stub)이 해당.
    // 코너(한 방향만, 예 ╓╒)는 양 선을 이어야 하므로 기존대로 바깥 span(cxmin/cymin)까지 뻗는다. 벽이 단일선이면
    // 안쪽==바깥이라 변화 없음(╞╡ 등). 베이스 = 정설 이중-T 모양(안쪽 부착), Ghostty linesChar와 동작 비교.
    const v_full = arms.up != null and arms.down != null; // 세로가 위·아래 모두 = 통과 벽
    const h_full = arms.left != null and arms.right != null; // 가로가 좌·우 모두 = 통과 벽

    var count: u32 = 0;
    var i: usize = 0;
    while (i < hyn) : (i += 1) {
        const y0 = hy[i] -| half;
        const y1 = @min(h, y0 + t);
        // left 있으면 좌단(0). 없으면 stub: 벽이 통과 이중벽이면 안쪽(우측) 세로선 vx[last]에 붙고, 코너면 바깥(cxmin).
        const x0 = if (arms.left != null) 0 else if (v_full and vxn > 0) vx[vxn - 1] -| half else cxmin;
        const x1 = if (arms.right != null) w else if (v_full and vxn > 0) @min(w, (vx[0] -| half) + t) else cxmax;
        count += gp.fillRect(pixels, bytes_per_row, x0, y0, x1, y1);
    }
    i = 0;
    while (i < vxn) : (i += 1) {
        const x0 = vx[i] -| half;
        const x1 = @min(w, x0 + t);
        // up 있으면 상단(0). 없으면 stub: 벽이 통과 이중벽이면 안쪽(아래) 가로선 hy[last]에 붙고, 코너면 바깥(cymin).
        const y0 = if (arms.up != null) 0 else if (h_full and hyn > 0) hy[hyn - 1] -| half else cymin;
        const y1 = if (arms.down != null) h else if (h_full and hyn > 0) @min(h, (hy[0] -| half) + t) else cymax;
        count += gp.fillRect(pixels, bytes_per_row, x0, y0, x1, y1);
    }
    return count;
}

test "isBoxDrawing: light·heavy·혼합·dashed·double·반선 (single↔double 혼합·대각선은 폴백)" {
    try std.testing.expect(isBoxDrawing(0x2500)); // ─ light
    try std.testing.expect(isBoxDrawing(0x254B)); // ╋ heavy cross
    try std.testing.expect(isBoxDrawing(0x250D)); // ┍ 혼합(down light + right heavy) — 이제 커버
    try std.testing.expect(isBoxDrawing(0x251E)); // ┞ 혼합 T(up heavy)
    try std.testing.expect(isBoxDrawing(0x2540)); // ╀ 혼합 사거리
    try std.testing.expect(isBoxDrawing(0x257E)); // ╾ 두께전이 반선(heavy left + light right)
    try std.testing.expect(isBoxDrawing(0x2574)); // ╴ 반선
    try std.testing.expect(isBoxDrawing(0x256D)); // ╭ 둥근
    try std.testing.expect(isBoxDrawing(0x2504)); // ┄ dashed
    try std.testing.expect(isBoxDrawing(0x2550)); // ═ double
    try std.testing.expect(isBoxDrawing(0x256C)); // ╬ double cross
    try std.testing.expect(isBoxDrawing(0x2571)); // ╱ 대각선
    try std.testing.expect(isBoxDrawing(0x2573)); // ╳ 대각 십자
    try std.testing.expect(isBoxDrawing(0x2552)); // ╒ single↔double 혼합 (이제 커버)
    try std.testing.expect(isBoxDrawing(0x256B)); // ╫ single↔double 혼합 cross
    // U+2500~257F 전체 커버 — 그 밖만 폴백
    try std.testing.expect(!isBoxDrawing(0x2588)); // █ block(block_glyph)
    try std.testing.expect(!isBoxDrawing(0x257F + 1)); // 0x2580 = block 시작
    try std.testing.expect(!isBoxDrawing('A'));
}

test "isBoxDrawing: U+2500~257F 전 코드포인트 커버(빈틈 없음)" {
    var cp: u32 = 0x2500;
    while (cp <= 0x257F) : (cp += 1) {
        try std.testing.expect(isBoxDrawing(cp));
    }
}

test "fillCoverage: single↔double 혼합 ╞(single 세로 full + double 가로 우)·╤(single 세로 down + double 가로)" {
    const w: u32 = 16;
    const h: u32 = 32; // light t=2, double 선 cy±2
    const bpr: usize = w * 4;
    var pixels: [32 * 16 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;
    const cx = w / 2;
    const cy = h / 2;

    // ╞ (up.L down.L right.D): single 세로선 full + 두 가로선 우측. 세로 중앙선 상·하단 닿음, 우단에 두 가로선.
    _ = fillCoverage(0x255E, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, 0)); // 세로 상단
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, h - 1)); // 세로 하단
    var h_runs: u32 = 0; // 우단 열의 세로 스캔 → 두 가로선 = run 2
    var prev: u8 = 0;
    for (0..h) |y| {
        const v = a(&pixels, bpr, w - 1, @intCast(y));
        if (v == 0xFF and prev == 0x00) h_runs += 1;
        prev = v;
    }
    try std.testing.expectEqual(@as(u32, 2), h_runs); // 우단에 두 가로선(double)
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, cy)); // 좌단 안 닿음(right만)

    // ╤ (down.L left.D right.D): 두 가로선 full + single 세로선 아래로. 상단 세로 안 닿고 하단 닿음.
    _ = fillCoverage(0x2564, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, cy -| 2)); // 위 가로선 좌단
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy + 2)); // 아래 가로선 우단
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, h - 1)); // 세로 하단(down)
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, cx, 0)); // 세로 상단 안 닿음(up 없음)
}

test "fillCoverage: 이중 세로벽+single 가로 stub ╟╢는 안쪽 선에 붙고 gap을 안 메운다" {
    // 회귀 고정(#4): ╟(up.D down.D right.L)·╢(up.D down.D left.L)은 꽉 찬 이중 세로벽에 single 가로 stub이
    // 붙는다. stub은 **안쪽** 세로선에 붙어야 하고, 두 세로선 사이 gap을 가로질러선 안 된다(예전엔 바깥 선부터
    // 뻗어 gap을 메웠다). w=16,h=32 → t=2,half=1,d=2, 세로선 x=6·10, gap=x{7,8}.
    const w: u32 = 16;
    const h: u32 = 32;
    const bpr: usize = w * 4;
    var pixels: [32 * 16 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;
    const cy = h / 2;

    // ╟ (right stub): 안쪽=우측 세로선(x=10)에서 우단으로. gap{7,8}은 row cy에서 비어야 한다.
    _ = fillCoverage(0x255F, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 6, 0)); // 좌 세로선 상단(up)
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 10, h - 1)); // 우 세로선 하단(down)
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy)); // 우 stub 우단 닿음
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 7, cy)); // gap 안 메움(예전엔 0xFF)
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 8, cy)); // gap 안 메움

    // ╢ (left stub): 안쪽=좌측 세로선(x=6)에서 좌단으로. gap{7,8}은 row cy에서 비어야 한다.
    _ = fillCoverage(0x2562, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, cy)); // 좌 stub 좌단 닿음
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 7, cy)); // gap 안 메움
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 8, cy)); // gap 안 메움
}

test "fillCoverage: 대각선 ╲는 좌상→우하, ╱는 좌하→우상 코너를 지난다" {
    const w: u32 = 16;
    const h: u32 = 16;
    const bpr: usize = w * 4;
    var pixels: [16 * 16 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;

    // ╲ U+2572: 좌상(0,0)·우하(w-1,h-1) 코너 닿고, 반대 코너(우상·좌하)는 빈다.
    _ = fillCoverage(0x2572, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, 0)); // 좌상
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, h - 1)); // 우하
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, w - 1, 0)); // 우상 빔
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, h - 1)); // 좌하 빔

    // ╱ U+2571: 좌하(0,h-1)·우상(w-1,0) 코너 닿고, 좌상·우하는 빈다.
    _ = fillCoverage(0x2571, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, h - 1)); // 좌하
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, 0)); // 우상
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, 0)); // 좌상 빔

    // ╳ U+2573: 네 코너 다 닿는다(둘 다).
    _ = fillCoverage(0x2573, w, h, bpr, &pixels);
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, 0));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, h - 1));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, 0));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, h - 1));
    // 중앙도 칠해진다(두 선이 교차).
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w / 2, h / 2));
}

test "fillCoverage: 혼합 굵기 ┞(up heavy + down/right light)는 위 stem만 굵고 아래·우는 가늘다" {
    const w: u32 = 16;
    const h: u32 = 32; // light t=2, heavy t=4
    const bpr: usize = w * 4;
    var pixels: [32 * 16 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;
    const cx = w / 2; // 8
    const cy = h / 2; // 16

    _ = fillCoverage(0x251E, w, h, bpr, &pixels); // ┞ up.heavy down.light right.light
    // 위 stem(y<cy): heavy 폭 4. 아래 stem(y>cy): light 폭 2. 같은 행에서 폭 비교.
    var up_w: u32 = 0;
    var down_w: u32 = 0;
    for (0..w) |x| {
        if (a(&pixels, bpr, @intCast(x), 4) == 0xFF) up_w += 1; // 위쪽 행
        if (a(&pixels, bpr, @intCast(x), h - 4) == 0xFF) down_w += 1; // 아래쪽 행
    }
    try std.testing.expectEqual(@as(u32, 4), up_w); // 위 stem heavy
    try std.testing.expectEqual(@as(u32, 2), down_w); // 아래 stem light
    // 세 팔이 셀 경계에 닿는다(up 상단, down 하단, right 우단). left는 안 닿음.
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, 0)); // up 상단
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, cx, h - 1)); // down 하단
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, cy)); // right 우단
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, cy)); // left 안 닿음
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
