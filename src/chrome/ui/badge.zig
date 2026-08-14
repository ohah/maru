//! Badge geometry — 작은 라벨 상자의 치수·자리를 한 곳에서 푼다.
//!
//! Session Dock의 그룹 count pill은 이 결정들을 자기 view 안에서 직접 내리고 있었다: 최소 폭,
//! 최대 높이, 반지름, 부모 행 안에서의 세로 중앙, 라벨의 가로/세로 중앙, 그리고 "안 들어가면
//! 안 그린다"는 세 개의 조기 반환. 그 산수 하나가 어긋나 pill이 행 밖으로 내려가 아래 카드에
//! 걸치는 것을 사용자가 보고했다 — `rect.y + (height - h) / 2`를 `rect.y + (height - h / 2)`로
//! 쓴 괄호 하나였다. 컴포넌트 view 한복판의 인라인 산수는 그 종류의 실수를 테스트로 고정하기
//! 어렵다.
//!
//! 그래서 이 모듈은 **ops를 내지 않고 사각형만 돌려준다.** 소비자마다 op를 내는 방식이 다르기
//! 때문이다 — Dock은 자기 published clip을 실어 보내는 writer를 거치고(`appendQuadClippedBy`),
//! 단축키 힌트는 arena ArrayList에 직접 append한다. emission까지 여기로 끌어오면 두 방식 모두와
//! 싸우게 되고, 정작 틀렸던 것은 emission이 아니라 geometry였다.
//!
//! **무엇이 이 모듈의 소비자가 아닌가**(같아 보이지만 다른 것들 — 나중에 잘못 합치지 않도록):
//!   - 알림 배지: 빨강 **원 quad + 터미널 셀 숫자**(펼침) / 빨강 **텍스트만**(접힘)이고 종 glyph의
//!     실측 기하에 묶여 있다. `platform`(app_session) 소유이며 chrome op가 아니다.
//!   - `toggle`의 pill: 라벨 없는 스위치 **트랙**이다. 상태는 색과 knob 위치로 읽는다.
//!   - provider badge·scope 탭: 배경 도형이 없는 텍스트다(선택 배경은 tree paint가 그린다).

const std = @import("std");
const draw = @import("../draw.zig");
const layout_mod = @import("layout.zig");
const spacing = @import("spacing.zig");
const typography = @import("typography.zig");

/// 부모 rect 안에 놓인 배지 하나의 결과. `label_*`는 배지 상자 **안에서** 라벨이 차지할 자리이고,
/// 상자와 라벨은 같은 좌표계(backing px)다.
pub const Layout = struct {
    box: draw.Rect,
    /// 네 모서리 공통 반지름. pill은 높이의 절반(양끝이 반원), keycap은 0.
    radius_px: u16,
    label_x: f32,
    label_y: f32,
    label_w: f32,
    /// 라벨이 상자 안에 들어가는가. **상자가 안 들어가는 것과 다른 상황이다** — 상자는 그릴 수
    /// 있는데 라벨 줄높이만 넘칠 때는 상자를 그리고 라벨만 생략한다. 이 둘을 하나로 합쳐 `null`로
    /// 만들면, 라벨이 안 들어간다는 이유로 상자와 그 행의 다른 요소까지 사라진다.
    label_fits: bool,
};

/// 부모 행의 **오른쪽 끝**에 붙는 count pill. 세로는 행 중앙, 가로는 `inset_x`만큼 안쪽.
///
/// 안 들어가면 `null`이다 — 호출자가 "그리지 않는다"를 한 번만 판단하게 하려는 것이다. 폭이
/// 모자란데 그리면 이름 라벨을 덮고, 높이가 라벨 줄높이보다 작은데 그리면 숫자가 상자 밖으로 나간다.
///
/// pill 폭을 정하는 규칙. **소비자마다 다르다** — 하나로 합치면 한쪽이 반드시 어색해진다.
pub const Width = enum {
    /// 한 자리 수여도 가로로 긴 pill. Session Dock 그룹 개수의 디자인이다 — 목록이 짧고 개수가
    /// 그 행의 주인공이라 넓은 자리가 어울린다.
    wide,
    /// 라벨에 딱 맞는 폭(좌우 패딩만). 소스 컨트롤처럼 행이 촘촘하고 배지가 **보조 정보**일 때 쓴다 —
    /// 넓은 pill은 한 자리 수에서 속이 빈 상자로 보인다(사용자 지적 2026-08-14).
    snug,
};

/// `label_cols`는 호출자가 센 표시 칸 수다(측정은 backend가 하고 chrome은 셀 추정만 하는 계약).
pub fn countPill(
    parent: layout_mod.UiRect,
    /// 부모 오른쪽 끝에서 pill 오른쪽 끝까지의 여백.
    inset_x: u32,
    label_cols: u16,
    cell_width_px: u32,
    scale_milli: u32,
    /// pill 오른쪽에 이미 자리를 잡은 것들(disclosure 아이콘 슬롯 등). 이만큼은 pill이 침범하지 않는다.
    reserved_x: u32,
    width_rule: Width,
) ?Layout {
    if (cell_width_px == 0) return null;
    const pad = spacing.px(.xs, scale_milli);
    const cols = @max(label_cols, 1);

    const height = @min(spacing.pointsPx(max_pill_height_pt, scale_milli), @as(u32, @intFromFloat(@floor(parent.height))));
    if (height == 0) return null;

    // 셀 추정은 더 긴 라벨이 들어갈 자리만 확보한다.
    const label_box = @as(u32, cols) * cell_width_px + pad * 2;
    const width = switch (width_rule) {
        .wide => @max(spacing.pointsPx(min_pill_width_pt, scale_milli), label_box),
        // 세로보다 좁아지지는 않게 둔다 — 한 자리 수에서 세로로 긴 알약이 되면 그것대로 어색하다.
        .snug => @max(label_box, height),
    };
    if (parent.width < @as(f32, @floatFromInt(inset_x * 2 + width + reserved_x))) return null;

    const line_h: f32 = @floatFromInt(typography.lineHeightPx(.control, scale_milli));

    const x: f32 = parent.x + parent.width - @as(f32, @floatFromInt(inset_x + width));
    // 세로 중앙은 `(부모 높이 - 상자 높이) / 2`다. 이 괄호가 밀리면 상자가 부모 바닥 밖으로 내려간다.
    const y: f32 = parent.y + (parent.height - @as(f32, @floatFromInt(height))) / 2;

    const label_w: f32 = @min(
        @as(f32, @floatFromInt(@as(u32, cols) * cell_width_px)),
        @as(f32, @floatFromInt(width -| pad * 2)),
    );
    return .{
        .box = .{
            .x = @intFromFloat(@floor(x)),
            .y = @intFromFloat(@floor(y)),
            .w = width,
            .h = height,
        },
        .radius_px = @intCast(@min(height / 2, @as(u32, std.math.maxInt(u16)))),
        .label_x = x + (@as(f32, @floatFromInt(width)) - label_w) / 2,
        // 행이 아니라 **상자** 안에서 중앙이다. 행 baseline을 쓰면 숫자가 어두운 pill 위로 떠오른다.
        .label_y = y + (@as(f32, @floatFromInt(height)) - line_h) / 2,
        .label_w = label_w,
        .label_fits = @as(f32, @floatFromInt(height)) >= line_h,
    };
}

/// 요소 rect의 **우상단**에 붙는 셀 정렬 keycap(단축키 힌트). 둥글지 않고 셀 한 줄 높이다 —
/// 배지 외 영역으로 터미널이 비쳐야 해서 셀 격자에 맞아야 한다.
///
/// 요소보다 넓은 chord는 좌단으로 clamp한다(요소 밖으로 안 나가게).
pub fn keycap(
    element: draw.Rect,
    label_cols: u32,
    cell_width_px: u32,
    cell_height_px: u32,
) ?Layout {
    if (label_cols == 0 or cell_width_px == 0 or cell_height_px == 0) return null;
    const width = label_cols * cell_width_px;
    const right = element.x + @as(i32, @intCast(element.w));
    const x = @max(right - @as(i32, @intCast(width)), element.x);
    return .{
        .box = .{ .x = x, .y = element.y, .w = width, .h = cell_height_px },
        .radius_px = 0,
        .label_x = @floatFromInt(x),
        .label_y = @floatFromInt(element.y),
        .label_w = @floatFromInt(width),
        // keycap 상자는 셀 한 줄이고 라벨도 셀 한 줄이라 항상 들어간다.
        .label_fits = true,
    };
}

/// 한 자리 수여도 유지하는 최소 pill 폭(pt).
const min_pill_width_pt: u16 = 44;
/// 행이 아무리 높아도 pill은 이보다 커지지 않는다(pt).
const max_pill_height_pt: u16 = 32;

// ── 테스트 ──────────────────────────────────────────────────────────────────────

test "countPill: 상자와 라벨이 각각 자기 부모의 세로 중앙에 온다" {
    // 행 높이 40, pill 높이는 32pt 상한에 걸린다 → (40-32)/2 = 4만큼 내려온다.
    const parent = layout_mod.UiRect{ .x = 0, .y = 100, .width = 300, .height = 40 };
    const layout = countPill(parent, 12, 1, 8, 1000, 28, .wide) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 32), layout.box.h);
    try std.testing.expectEqual(@as(i32, 104), layout.box.y);
    // 라벨은 행이 아니라 **상자** 기준 중앙이다.
    const line_h: f32 = @floatFromInt(typography.lineHeightPx(.control, 1000));
    try std.testing.expectApproxEqAbs(@as(f32, 104) + (32 - line_h) / 2, layout.label_y, 0.001);
}

test "countPill: 세로 중앙 산수가 상자를 부모 밖으로 내보내지 않는다" {
    // 사용자 보고 회귀(`y + (h - box/2)`)의 고정: 상자 아래끝이 항상 부모 안이다.
    for ([_]f32{ 24, 33, 40, 64, 100 }) |height| {
        const parent = layout_mod.UiRect{ .x = 0, .y = 50, .width = 300, .height = height };
        const layout = countPill(parent, 12, 1, 8, 1000, 28, .wide) orelse continue;
        const bottom = @as(f32, @floatFromInt(layout.box.y + @as(i32, @intCast(layout.box.h))));
        try std.testing.expect(bottom <= parent.y + parent.height + 1);
        try std.testing.expect(@as(f32, @floatFromInt(layout.box.y)) >= parent.y - 1);
    }
}

test "countPill: 한 자리 수도 최소 폭을 유지하고 라벨은 가로 중앙" {
    const parent = layout_mod.UiRect{ .x = 0, .y = 0, .width = 300, .height = 40 };
    const layout = countPill(parent, 12, 1, 8, 1000, 28, .wide) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 44), layout.box.w); // 1칸(8px)+패딩보다 최소 폭이 크다
    const box_x: f32 = @floatFromInt(layout.box.x);
    const left_gap = layout.label_x - box_x;
    const right_gap = (box_x + 44) - (layout.label_x + layout.label_w);
    try std.testing.expectApproxEqAbs(left_gap, right_gap, 0.001);
}

test "countPill: 라벨이 길면 셀 추정만큼 넓어진다" {
    const parent = layout_mod.UiRect{ .x = 0, .y = 0, .width = 300, .height = 40 };
    const wide = countPill(parent, 12, 6, 16, 1000, 28, .wide) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 6 * 16 + 8 * 2), wide.box.w);
}

test "countPill: 안 들어가면 null이다 — 호출자가 판단을 반복하지 않는다" {
    const narrow = layout_mod.UiRect{ .x = 0, .y = 0, .width = 60, .height = 40 };
    try std.testing.expectEqual(@as(?Layout, null), countPill(narrow, 12, 1, 8, 1000, 28, .wide));

    // cell_width 0(측정 전 프레임)은 폭을 못 정한다.
    const parent = layout_mod.UiRect{ .x = 0, .y = 0, .width = 300, .height = 40 };
    try std.testing.expectEqual(@as(?Layout, null), countPill(parent, 12, 1, 0, 1000, 28, .wide));
}

test "countPill: 라벨이 안 들어가도 상자는 남는다 — 둘은 다른 상황이다" {
    // 행이 control 줄높이(17px @1x)보다 낮다. 예전 dock view는 이때 pill·chevron·이름은 그리고
    // 숫자만 생략했다. 이걸 `null`로 합치면 그 행이 통째로 사라진다(빈 그룹 헤더).
    const short = layout_mod.UiRect{ .x = 0, .y = 0, .width = 300, .height = 12 };
    const layout = countPill(short, 12, 1, 8, 1000, 28, .wide) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 12), layout.box.h);
    try std.testing.expect(!layout.label_fits);

    // 넉넉한 행에서는 들어간다.
    const tall = layout_mod.UiRect{ .x = 0, .y = 0, .width = 300, .height = 40 };
    const ok = countPill(tall, 12, 1, 8, 1000, 28, .wide) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ok.label_fits);
}

test "countPill: pill이 오른쪽 여백과 예약 슬롯을 침범하지 않는다" {
    const parent = layout_mod.UiRect{ .x = 20, .y = 0, .width = 300, .height = 40 };
    const layout = countPill(parent, 12, 1, 8, 1000, 28, .wide) orelse return error.TestUnexpectedResult;
    const right = @as(f32, @floatFromInt(layout.box.x + @as(i32, @intCast(layout.box.w))));
    try std.testing.expectApproxEqAbs(parent.x + parent.width - 12, right, 1.0);
    try std.testing.expect(@as(f32, @floatFromInt(layout.box.x)) > parent.x + 28);
}

test "countPill: 반지름은 높이의 절반이라 양끝이 반원이다" {
    const parent = layout_mod.UiRect{ .x = 0, .y = 0, .width = 300, .height = 40 };
    const layout = countPill(parent, 12, 1, 8, 1000, 28, .wide) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 16), layout.radius_px);
}

test "keycap: 요소 우상단에 셀 크기로 붙는다" {
    const element = draw.Rect{ .x = 0, .y = 48, .w = 200, .h = 70 };
    const layout = keycap(element, 2, 8, 16) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 184), layout.box.x); // 200 - 16
    try std.testing.expectEqual(@as(i32, 48), layout.box.y);
    try std.testing.expectEqual(@as(u32, 16), layout.box.w);
    try std.testing.expectEqual(@as(u32, 16), layout.box.h);
    try std.testing.expectEqual(@as(u16, 0), layout.radius_px); // 셀 정렬이라 각지다
}

test "keycap: 요소보다 넓은 chord는 좌단으로 clamp한다" {
    const element = draw.Rect{ .x = 100, .y = 0, .w = 8, .h = 16 };
    const layout = keycap(element, 3, 8, 16) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 100), layout.box.x);
}

test "keycap: 셀이 0이거나 라벨이 비면 null" {
    const element = draw.Rect{ .x = 0, .y = 0, .w = 100, .h = 20 };
    try std.testing.expectEqual(@as(?Layout, null), keycap(element, 0, 8, 16));
    try std.testing.expectEqual(@as(?Layout, null), keycap(element, 2, 0, 16));
    try std.testing.expectEqual(@as(?Layout, null), keycap(element, 2, 8, 0));
}

test "countPill: snug은 라벨에 맞고 wide는 최소 폭을 지킨다" {
    // 두 규칙이 갈리는 이유가 이 테스트다 — 합치면 한쪽이 반드시 어색해진다. 한 자리 수에서
    // wide는 44pt 최소 폭을, snug은 "세로보다 좁지 않게"만 지킨다.
    const parent = layout_mod.UiRect{ .x = 0, .y = 0, .width = 300, .height = 24 };
    const wide_pill = countPill(parent, 12, 1, 8, 1000, 28, .wide) orelse return error.TestUnexpectedResult;
    const snug_pill = countPill(parent, 12, 1, 8, 1000, 28, .snug) orelse return error.TestUnexpectedResult;

    try std.testing.expect(snug_pill.box.w < wide_pill.box.w);
    try std.testing.expectEqual(snug_pill.box.h, snug_pill.box.w); // 세로보다 좁아지지 않는다
    try std.testing.expectEqual(@as(u32, 44), wide_pill.box.w);
    // 둘 다 오른쪽 끝 기준이라 오른쪽 변은 같은 자리다.
    try std.testing.expectEqual(
        wide_pill.box.x + @as(i32, @intCast(wide_pill.box.w)),
        snug_pill.box.x + @as(i32, @intCast(snug_pill.box.w)),
    );
}

test "countPill: snug은 자릿수가 늘면 넓어진다" {
    const parent = layout_mod.UiRect{ .x = 0, .y = 0, .width = 300, .height = 24 };
    const one = countPill(parent, 12, 1, 8, 1000, 28, .snug) orelse return error.TestUnexpectedResult;
    const three = countPill(parent, 12, 3, 8, 1000, 28, .snug) orelse return error.TestUnexpectedResult;
    try std.testing.expect(three.box.w > one.box.w);
}
