//! 새 rich/Metal UiNode tree의 고정 버퍼 draw emission이다.
//!
//! 모든 부동소수 rect는 layout이, pointer-local state는 ui_interaction이, semantic variant의 token
//! 해석은 `paint_style`이 소유한다. 이 파일은 그 결과 rect를 한 번만 snap해서 backend 중립
//! ChromeDraw를 낸다. Metal lowering, text shaping, clip scissor, GPU shadow emission은 ML3b
//! 경계에 남는다.

const std = @import("std");
const icons = @import("../../icons.zig"); // 등록 아이콘 이름↔codepoint(테스트가 실제 등록 cp를 쓰게)
const draw = @import("../draw.zig");
const interaction = @import("interaction.zig");
const layout = @import("layout.zig");
const paint_style = @import("paint_style.zig");
const ui_style = @import("style.zig");
const tokens = @import("../tokens.zig");
const ui_tree = @import("tree.zig");

pub const PaintError = error{
    InsufficientBuffer,
    InvalidSnapshot,
    InvalidRect,
};

/// caller가 소유하는 고정 frame 저장소다. paint는 할당하지 않고 이전 frame의 op을 남기지도 않는다 —
/// 실패한 후보는 지워지므로 host가 반쯤 다시 칠해진 tree를 publish할 수 없다.
pub const PaintBuffers = struct {
    ops: []draw.Op,
};

pub const ResolvedShadow = paint_style.ResolvedShadow;
pub const ResolvedCardStyle = paint_style.ResolvedCardStyle;
pub const ResolvedTextStyle = paint_style.ResolvedTextStyle;
pub const resolveCard = paint_style.resolveCard;
pub const resolveButton = paint_style.resolveButton;
pub const resolveText = paint_style.resolveText;

/// semantic Card/Button마다 Quad 하나를 preorder로 낸다. 실제 CoreText layout 산출물이 배선되기
/// 전까지 텍스트는 의도적으로 내지 않으며, caller는 그래도 `resolveText`로 typed 시각 스타일을 얻을
/// 수 있다. 결과는 단위 테스트에서 snapshot하기에는 안전하지만 제품 frame은 아니다.
/// **시간에 따라 변하는 alpha 를 노드 id 로 얹는다**(fade). 계약([ScrollArea](../../../docs/scroll-area.md) §7)이
/// 「fade alpha 는 published tree 에 넣지 않는다」고 못 박은 이유가 이 타입의 존재 이유다 — tree 에 실으면
/// 프레임마다 tree 가 달라져 발행 경로의 동등 비교(예: `agentSessionDockFrameEql`)가 매번 실패하고,
/// 그 자리에 붙어 있는 드래그 carry 판정까지 흔든다. alpha 는 **paint 시점에 얹는 값**이다.
pub const IdAlpha = struct { id: ui_tree.UiId, alpha: u8 };

/// 오버라이드가 있으면 그 값, 없으면 선언된 opacity.
fn alphaFor(overrides: []const IdAlpha, id: ui_tree.UiId, declared: u8) u8 {
    for (overrides) |o| if (o.id == id) return o.alpha;
    return declared;
}

/// 기존 호출부를 위한 얇은 래퍼(오버라이드 없음). 인자를 늘리는 대신 이름을 나누는 것은
/// `appendBackgroundQuadsWithTerminalOpacity` 와 같은 선례다.
pub fn paint(
    tree: ui_tree.UiRectTree,
    state: interaction.InteractionState,
    tk: *const tokens.Tokens,
    layer: draw.Layer,
    buffers: PaintBuffers,
) PaintError!draw.ChromeDraw {
    return paintWithAlphaOverrides(tree, state, tk, layer, buffers, &.{});
}

/// `overrides` 에 든 id 의 quad 는 그 alpha 로 **덮어쓴다**(곱하지 않는다 — fade 는 이미 최종 값이다).
/// 목록이 짧다는 전제로 선형 탐색한다(스크롤바 track·thumb 둘).
pub fn paintWithAlphaOverrides(
    tree: ui_tree.UiRectTree,
    state: interaction.InteractionState,
    tk: *const tokens.Tokens,
    layer: draw.Layer,
    buffers: PaintBuffers,
    overrides: []const IdAlpha,
) PaintError!draw.ChromeDraw {
    clearOps(buffers.ops);
    var count: usize = 0;
    errdefer clearOps(buffers.ops);

    for (tree.entries) |entry| {
        switch (entry.visual) {
            // 구조 노드는 그릴 것이 없다. `scroll_area`도 그중 하나다 — 자기 배경을 갖지 않고 clip과
            // 자식 배치만 하며, 눈에 보이는 것은 그 자식들과 track/thumb(각각 card visual)이다.
            .none => if (entry.kind != .container and entry.kind != .scroll_area) return error.InvalidSnapshot,
            .card => |visual| {
                if (entry.kind != .card) return error.InvalidSnapshot;
                if (fullyClipped(entry)) continue;
                const rect = try snapRect(entry.rect);
                if (rect.w == 0 or rect.h == 0) continue;
                if (count == buffers.ops.len) return error.InsufficientBuffer;
                const style = paint_style.resolveCard(entry.id, visual, entry.action, state, tk);
                buffers.ops[count] = .{ .quad = .{
                    .rect = rect,
                    .fill_role = style.background,
                    .corner_radii = style.corner_radii_px,
                    .border_widths = style.border_widths_px,
                    .border_role = style.border,
                    .alpha = alphaFor(overrides, entry.id, style.opacity),
                    .clip = clipRectOf(entry),
                } };
                count += 1;
            },
            .button => |visual| {
                if (entry.kind != .button) return error.InvalidSnapshot;
                if (fullyClipped(entry)) continue;
                const rect = try snapRect(entry.rect);
                if (rect.w == 0 or rect.h == 0) continue;
                if (count == buffers.ops.len) return error.InsufficientBuffer;
                const style = paint_style.resolveButton(entry.id, visual, entry.action, state, tk);
                buffers.ops[count] = .{ .quad = .{
                    .rect = rect,
                    .fill_role = style.background,
                    .corner_radii = style.corner_radii_px,
                    .border_widths = style.border_widths_px,
                    .border_role = style.border,
                    .alpha = alphaFor(overrides, entry.id, style.opacity),
                    .clip = clipRectOf(entry),
                } };
                count += 1;
            },
            .text => |visual| {
                if (entry.kind != .text) return error.InvalidSnapshot;
                _ = paint_style.resolveText(visual);
            },
        }
    }
    return .{ .layer = layer, .ops = buffers.ops[0..count] };
}

/// 이 entry가 자기 clip에 **통째로** 잘렸는가. `layout.intersectRect`는 교차가 비면 면적 0 rect를 주고
/// (`layout.zig`), 그것은 "한 픽셀도 보이지 않는다"는 뜻이다. 그런데 backend의 quad clip 규약은 폭 0을
/// **"클립 없음"**으로 읽으므로(`maru_metal_shader.h`의 `clip.z == 0`), 그대로 내보내면 정반대로 자르지
/// 않은 원본 rect가 통째로 그려진다 — 스크롤로 뷰포트를 완전히 벗어난 카드 배경이 고정 chrome 위에
/// 떠 있던 사용자 보고가 이것이다. 안 보이는 quad는 여기서 없앤다.
///
/// NaN clip도 여기서 걸러진다(비교가 전부 false라 `!(> 0)`이 참). 그리는 쪽에 넘겨 봐야 좌표가 없다.
fn fullyClipped(entry: ui_tree.RectEntry) bool {
    const clip = entry.effective_clip orelse return false;
    return !(clip.width > 0 and clip.height > 0);
}

/// published clip을 semantic quad에 **그대로** 싣는다. 여기서 rect를 미리 자르지 않는 것이 핵심이다 —
/// backend shader가 corner radius와 변별 border를 rect 기하에서 유도하므로, 잘린 rect를 주면 클립 경계에
/// 없어야 할 곡률과 stroke가 생긴다. 원본 모양을 그린 뒤 뷰포트 밖 fragment만 버리는 것이 정확하다.
fn clipRectOf(entry: ui_tree.RectEntry) ?draw.Rect {
    const clip = entry.effective_clip orelse return null;
    if (!std.math.isFinite(clip.x) or !std.math.isFinite(clip.y) or
        !std.math.isFinite(clip.width) or !std.math.isFinite(clip.height)) return null;
    return .{
        .x = @intFromFloat(@ceil(clip.x)),
        .y = @intFromFloat(@ceil(clip.y)),
        .w = @intFromFloat(@max(@floor(clip.width), 0)),
        .h = @intFromFloat(@max(@floor(clip.height), 0)),
    };
}

/// layout은 percent/fill에서 소수 rect를 낼 수 있다. paint는 마지막 중립 경계에서 한 번만 snap한다 —
/// origin은 내리고 먼 변은 올리므로 인접한 rect 사이에 틈이 드러나지 않는다.
fn snapRect(rect: layout.UiRect) PaintError!draw.Rect {
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
        !std.math.isFinite(rect.width) or !std.math.isFinite(rect.height) or
        rect.width < 0 or rect.height < 0) return error.InvalidRect;
    const right = rect.x + rect.width;
    const bottom = rect.y + rect.height;
    if (!std.math.isFinite(right) or !std.math.isFinite(bottom)) return error.InvalidRect;

    const left_px = @floor(rect.x);
    const top_px = @floor(rect.y);
    const right_px = @ceil(right);
    const bottom_px = @ceil(bottom);
    const min_i32: f32 = @floatFromInt(std.math.minInt(i32));
    const max_i32: f32 = @floatFromInt(std.math.maxInt(i32));
    const max_u32: f32 = @floatFromInt(std.math.maxInt(u32));
    if (left_px < min_i32 or top_px < min_i32 or right_px > max_i32 or bottom_px > max_i32 or
        right_px < left_px or bottom_px < top_px or right_px - left_px > max_u32 or bottom_px - top_px > max_u32) return error.InvalidRect;

    return .{
        .x = @intFromFloat(left_px),
        .y = @intFromFloat(top_px),
        .w = @intFromFloat(right_px - left_px),
        .h = @intFromFloat(bottom_px - top_px),
    };
}

fn clearOps(ops: []draw.Op) void {
    for (ops) |*op| op.* = emptyOp();
}

fn emptyOp() draw.Op {
    return .{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .role = .surface_bg } };
}

fn testTokens() tokens.Tokens {
    return tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
}

fn cardEntry(id: ui_tree.UiId, rect: layout.UiRect, visual: ui_tree.CardVisual, action: ?ui_tree.UiAction) ui_tree.RectEntry {
    return .{ .id = id, .parent_index = null, .kind = .card, .rect = rect, .effective_clip = null, .action = action, .visual = .{ .card = visual } };
}

test "resolveCard gives disabled precedence and preserves rich token shadow ownership" {
    const tk = testTokens();
    const visual: ui_tree.CardVisual = .{ .variant = .raised, .paint = .{ .background = .accent_bar, .border = .accent_bar } };
    const active = resolveCard(7, visual, .{ .id = 9 }, .{ .hovered = 7, .focused = 7, .capture = .{ .id = 7, .action_id = 9 } }, &tk);
    try std.testing.expectEqual(tokens.ColorRole.tab_active_bg, active.background);
    try std.testing.expectEqual(@as(?tokens.ColorRole, .focus_accent), active.border);
    try std.testing.expect(active.shadow != null);
    try std.testing.expectEqual(tk.space.shadow_blur_px, active.shadow.?.blur_px);

    const disabled = resolveCard(7, visual, .{ .id = 9, .enabled = false }, .{ .hovered = 7, .focused = 7, .capture = .{ .id = 7, .action_id = 9 } }, &tk);
    try std.testing.expectEqual(tokens.ColorRole.surface_bg, disabled.background);
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, disabled.foreground);
    try std.testing.expectEqual(@as(?tokens.ColorRole, .divider), disabled.border);
    try std.testing.expectEqual(@as(u8, 0x80), disabled.opacity);
    try std.testing.expectEqual(@as(?ResolvedShadow, null), disabled.shadow);
}

test "every semantic card variant starts fully opaque" {
    const tk = testTokens();
    inline for ([_]ui_tree.CardVariant{ .surface, .raised, .selected, .danger }) |variant| {
        const resolved = resolveCard(1, .{ .variant = variant, .paint = .{} }, null, .{}, &tk);
        try std.testing.expectEqual(@as(u8, 0xFF), resolved.opacity);
    }
}

test "Button primary and secondary keep command contrast independent of Card variants" {
    const tk = testTokens();
    const primary = resolveButton(5, .{ .variant = .primary, .paint = .{} }, .{ .id = 9 }, .{}, &tk);
    try std.testing.expectEqual(tokens.ColorRole.surface_fg, primary.background);
    try std.testing.expectEqual(tokens.ColorRole.surface_bg, primary.foreground);
    const secondary = resolveButton(6, .{ .variant = .secondary, .paint = .{} }, .{ .id = 10 }, .{}, &tk);
    try std.testing.expectEqual(tokens.ColorRole.tab_hover_bg, secondary.background);
    try std.testing.expectEqual(tokens.ColorRole.surface_fg, secondary.foreground);
    const hovered_primary = resolveButton(5, .{ .variant = .primary, .paint = .{} }, .{ .id = 9 }, .{ .hovered = 5 }, &tk);
    try std.testing.expectEqual(tokens.ColorRole.row_hover_bg, hovered_primary.background);
    try std.testing.expectEqual(tokens.ColorRole.surface_fg, hovered_primary.foreground);
    const disabled = resolveButton(7, .{ .variant = .primary, .paint = .{} }, .{ .id = 11, .enabled = false }, .{}, &tk);
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, disabled.foreground);
    try std.testing.expectEqual(@as(u8, 0x80), disabled.opacity);
}

test "every Button variant resolves a distinct command surface and one foreground source" {
    const tk = testTokens();
    // 닫힌 집합 전체를 돈다 — variant가 늘면 이 배열도 컴파일 단계에서 함께 늘어야 한다.
    const variants = [_]ui_style.ButtonVariant{ .primary, .secondary, .ghost, .danger };
    inline for (variants) |variant| {
        const resolved = resolveButton(1, .{ .variant = variant, .paint = .{} }, .{ .id = 2 }, .{}, &tk);
        // 전경은 단일 출처가 정한다. base가 자기 매핑을 따로 들면 여기서 갈린다.
        try std.testing.expectEqual(paint_style.buttonForeground(variant), resolved.foreground);
        try std.testing.expectEqual(@as(u8, 0xFF), resolved.opacity);
    }

    // ghost는 panel과 같은 배경을 base로 삼고 테두리를 두지 않는다 — 그래서 평소에는 label만 보인다.
    const ghost = resolveButton(1, .{ .variant = .ghost, .paint = .{} }, .{ .id = 2 }, .{}, &tk);
    try std.testing.expectEqual(tokens.ColorRole.surface_bg, ghost.background);
    try std.testing.expect(ghost.border == null);

    // danger는 파괴적 action 전용 token을 쓴다. 다른 variant가 그 색을 빌려 쓰지 않는다.
    const danger = resolveButton(1, .{ .variant = .danger, .paint = .{} }, .{ .id = 2 }, .{}, &tk);
    try std.testing.expectEqual(tokens.ColorRole.danger_bg, danger.background);
    try std.testing.expectEqual(tokens.ColorRole.danger_fg, danger.foreground);
    for ([_]ui_style.ButtonVariant{ .primary, .secondary, .ghost }) |other| {
        const style = resolveButton(1, .{ .variant = other, .paint = .{} }, .{ .id = 2 }, .{}, &tk);
        try std.testing.expect(style.background != .danger_bg);
    }

    // ghost hover는 **한 단계 약한** 면과 테두리다. 목록 행용 `row_hover_bg`는 활성보다 밝게 잡은 색이라
    // 평소 배경이 없는 경량 컨트롤에 깔리면 그 하나만 튄다(사용자 제보). 면은 `tab_hover_bg`로 낮추고
    // 형태는 테두리가 말한다. 다른 variant는 공유 token을 그대로 받는다.
    const hovered_ghost = resolveButton(1, .{ .variant = .ghost, .paint = .{} }, .{ .id = 2 }, .{ .hovered = 1 }, &tk);
    try std.testing.expectEqual(tokens.ColorRole.tab_hover_bg, hovered_ghost.background);
    try std.testing.expectEqual(tokens.ColorRole.divider, hovered_ghost.border.?);
    const hovered_secondary = resolveButton(1, .{ .variant = .secondary, .paint = .{} }, .{ .id = 2 }, .{ .hovered = 1 }, &tk);
    try std.testing.expectEqual(tokens.ColorRole.row_hover_bg, hovered_secondary.background);
    // pressed도 한 단계 낮추지만 **hover보다는 진하다** — 그 순서가 뒤집히면 누르는 중이 더 흐려진다.
    const pressed_ghost = resolveButton(1, .{ .variant = .ghost, .paint = .{} }, .{ .id = 2 }, .{ .capture = .{ .id = 1, .action_id = 2 } }, &tk);
    try std.testing.expectEqual(tokens.ColorRole.control_press_bg, pressed_ghost.background);
    try std.testing.expectEqual(tokens.ColorRole.focus_accent, pressed_ghost.border.?);
    const pressed_secondary = resolveButton(1, .{ .variant = .secondary, .paint = .{} }, .{ .id = 2 }, .{ .capture = .{ .id = 1, .action_id = 2 } }, &tk);
    try std.testing.expectEqual(tokens.ColorRole.tab_active_bg, pressed_secondary.background);
    // role 이 다른 것만으로는 아무것도 증명되지 않는다 — **실제 RGB**가 갈려야 화면이 달라진다.
    // 2026-08-17 에 role 만 바꾼 수정(`tab_active_bg` → `row_hover_bg`)이 두 role 이 같은 색이라 시각
    // 효과가 0 이었고, 적대적 검증에서 그것이 드러났다. 그 실패를 이 단언이 못 박는다: ghost 의
    // hover < pressed < 활성 세기 계단이 rich 토큰셋에서 **색으로** 갈린다.
    const rich = testTokens(); // rich 토큰셋 픽스처(sidebar_active = 80,80,80)
    const ghost_hover_rgb = rich.get(hovered_ghost.background);
    const ghost_press_rgb = rich.get(pressed_ghost.background);
    const active_rgb = rich.get(pressed_secondary.background);
    try std.testing.expect(!std.meta.eql(ghost_hover_rgb, ghost_press_rgb));
    try std.testing.expect(!std.meta.eql(ghost_press_rgb, active_rgb));
    // 그리고 방향까지: hover 가 가장 어둡고 활성이 가장 밝다(dark 테마 기준 fixture).
    try std.testing.expect(ghost_hover_rgb.r < ghost_press_rgb.r);
    try std.testing.expect(ghost_press_rgb.r < active_rgb.r);
    // 목록 행 hover 는 **활성보다 밝다**. 이 role 도 2026-08-17까지 `sidebar_active` 를 그대로 담아
    // 자기 주석("활성색과 완전히 같아 구분이 0")이 금지한 상태였다 — 값이 아니라 이름만 달랐다.
    // 그래서 방향까지 단언한다: 활성 밴드 위에 겹쳐도 구분되려면 반드시 더 밝아야 한다.
    const row_hover_rgb = rich.get(.row_hover_bg);
    try std.testing.expect(!std.meta.eql(row_hover_rgb, active_rgb));
    try std.testing.expect(row_hover_rgb.r > active_rgb.r);
    // disabled는 언제나 마지막이라 danger의 강한 색도 비활성으로 가라앉는다.
    const disabled_danger = resolveButton(1, .{ .variant = .danger, .paint = .{} }, .{ .id = 2, .enabled = false }, .{}, &tk);
    try std.testing.expect(disabled_danger.background != .danger_bg);
}

test "Button painter state order is pressed, focus, hover, and disabled always last" {
    const tk = testTokens();
    const id: u64 = 5;
    const enabled_action = ui_tree.UiAction{ .id = 9 };
    const visual = ui_style.ButtonVisual{ .variant = .primary, .paint = .{} };

    const base = resolveButton(id, visual, enabled_action, .{}, &tk);

    // pressed(capture)는 focus·hover가 함께 있어도 이긴다. 셋을 동시에 준 상태가 capture 단독과 같다.
    const all_three = resolveButton(id, visual, enabled_action, .{
        .capture = .{ .id = id, .action_id = 9 },
        .focused = id,
        .hovered = id,
    }, &tk);
    const pressed_only = resolveButton(id, visual, enabled_action, .{ .capture = .{ .id = id, .action_id = 9 } }, &tk);
    try std.testing.expectEqual(pressed_only.background, all_three.background);
    try std.testing.expectEqual(pressed_only.foreground, all_three.foreground);

    // focus는 hover보다 앞선다 — 둘 다 있으면 focus 결과가 나온다.
    const focus_and_hover = resolveButton(id, visual, enabled_action, .{ .focused = id, .hovered = id }, &tk);
    const focus_only = resolveButton(id, visual, enabled_action, .{ .focused = id }, &tk);
    try std.testing.expectEqual(focus_only.background, focus_and_hover.background);
    try std.testing.expectEqual(focus_only.border, focus_and_hover.border);

    // hover는 base를 바꾼다 — 아무 상태도 없을 때와 달라야 한다.
    const hover_only = resolveButton(id, visual, enabled_action, .{ .hovered = id }, &tk);
    try std.testing.expect(hover_only.background != base.background);

    // disabled는 언제나 마지막이다. 셋 중 무엇이 켜져 있어도 비활성 표현이 이긴다 — 접근 불가한
    // 상태가 활성처럼 보이면 사용자가 누를 수 있다고 오해한다.
    const disabled_action = ui_tree.UiAction{ .id = 9, .enabled = false };
    for ([_]interaction.InteractionState{
        .{},
        .{ .hovered = id },
        .{ .focused = id },
        .{ .capture = .{ .id = id, .action_id = 9 }, .focused = id, .hovered = id },
    }) |state| {
        const disabled = resolveButton(id, visual, disabled_action, state, &tk);
        try std.testing.expectEqual(tokens.ColorRole.muted_fg, disabled.foreground);
        try std.testing.expectEqual(tokens.ColorRole.surface_bg, disabled.background);
        try std.testing.expect(disabled.opacity < 0xFF);
        try std.testing.expect(disabled.shadow == null);
    }

    // 다른 node의 상태는 이 node를 바꾸지 않는다 — id가 다르면 남의 hover/focus를 빌려오지 않는다.
    const other = resolveButton(id, visual, enabled_action, .{
        .hovered = id + 1,
        .focused = id + 1,
        .capture = .{ .id = id + 1, .action_id = 99 },
    }, &tk);
    try std.testing.expectEqual(base.background, other.background);
    try std.testing.expectEqual(base.foreground, other.foreground);
}

test "paint emits preordered snapped card quads and ignores text until shaping exists" {
    const tk = testTokens();
    const entries = [_]ui_tree.RectEntry{
        cardEntry(1, .{ .x = 0.2, .y = 1.2, .width = 10.1, .height = 4.1 }, .{ .variant = .surface, .paint = .{} }, .{ .id = 10 }),
        .{ .id = 2, .parent_index = 0, .kind = .text, .rect = .{ .x = 1, .y = 2, .width = 2, .height = 1 }, .effective_clip = null, .action = null, .visual = .{ .text = .{ .tone = .muted, .paint = .{} } } },
        cardEntry(3, .{ .x = 10.3, .y = 1.2, .width = 2.1, .height = 4.1 }, .{ .variant = .selected, .paint = .{} }, .{ .id = 30 }),
    };
    var ops: [2]draw.Op = undefined;
    const out = try paint(.{ .entries = &entries }, .{ .hovered = 1 }, &tk, .sidebar, .{ .ops = &ops });
    try std.testing.expectEqual(draw.Layer.sidebar, out.layer);
    try std.testing.expectEqual(@as(usize, 2), out.ops.len);
    try std.testing.expect(out.ops[0] == .quad);
    try std.testing.expectEqual(draw.Rect{ .x = 0, .y = 1, .w = 11, .h = 5 }, out.ops[0].quad.rect);
    try std.testing.expectEqual(tokens.ColorRole.row_hover_bg, out.ops[0].quad.fill_role);
    try std.testing.expect(out.ops[1] == .quad);
    try std.testing.expectEqual(tokens.ColorRole.tab_active_bg, out.ops[1].quad.fill_role);
}

// clip은 이제 **자르지 않고 싣는다**. backend shader가 원본 rect로 모양(corner radius·변별 border)을 그린
// 뒤 뷰포트 밖 fragment만 버리므로, 여기서 rect를 미리 자르면 클립 경계에 없어야 할 곡률과 stroke가 생긴다.
test "paint carries the completed tree clip on the quad instead of cutting its rect" {
    const tk = testTokens();
    const entries = [_]ui_tree.RectEntry{.{
        .id = 1,
        .parent_index = null,
        .kind = .card,
        .rect = .{ .x = 0, .y = -8, .width = 20, .height = 20 },
        .effective_clip = .{ .x = 0, .y = 0, .width = 20, .height = 12 },
        .action = .{ .id = 1 },
        .visual = .{ .card = .{ .variant = .surface, .paint = .{} } },
    }};
    var ops: [1]draw.Op = undefined;
    const out = try paint(.{ .entries = &entries }, .{}, &tk, .sidebar, .{ .ops = &ops });
    try std.testing.expectEqual(@as(usize, 1), out.ops.len);
    // rect는 원본 그대로다.
    try std.testing.expectEqual(@as(i32, -8), out.ops[0].quad.rect.y);
    // 대신 published clip이 실려 backend가 그 사각형 밖을 버린다.
    const clip = out.ops[0].quad.clip orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 0), clip.y);
    try std.testing.expectEqual(@as(u32, 12), clip.h);
}

test "paint drops a fully clipped quad instead of publishing an empty clip" {
    // 회귀(사용자 보고): 펼친 카드를 스크롤로 목록 위까지 올리면 그 카드 배경이 고정 header/scope 위에
    // 통째로 그려졌다. `layout.intersectRect`가 빈 교차를 면적 0 rect로 접고, backend는 폭 0 clip을
    // "클립 없음"으로 읽기 때문이다(maru_metal_shader.h). 안 보이는 quad는 아예 내지 않는다.
    const tk = testTokens();
    const entries = [_]ui_tree.RectEntry{
        .{
            .id = 1,
            .parent_index = null,
            .kind = .card,
            .rect = .{ .x = 0, .y = -200, .width = 20, .height = 20 },
            // 뷰포트 위로 완전히 벗어난 자식의 교차: 원점은 컨테이너 경계 안이고 면적만 0이다.
            .effective_clip = .{ .x = 0, .y = 0, .width = 20, .height = 0 },
            .action = .{ .id = 1 },
            .visual = .{ .card = .{ .variant = .surface, .paint = .{} } },
        },
        .{
            .id = 2,
            .parent_index = null,
            .kind = .button,
            .rect = .{ .x = 0, .y = -200, .width = 20, .height = 20 },
            .effective_clip = .{ .x = 0, .y = 0, .width = 0, .height = 20 },
            .action = .{ .id = 2 },
            .visual = .{ .button = .{ .variant = .primary, .paint = .{} } },
        },
        // 같은 프레임의 보이는 형제는 그대로 남는다 — "전부 지운다"가 아니라 "안 보이는 것만"이다.
        .{
            .id = 3,
            .parent_index = null,
            .kind = .card,
            .rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 },
            .effective_clip = .{ .x = 0, .y = 0, .width = 20, .height = 20 },
            .action = .{ .id = 3 },
            .visual = .{ .card = .{ .variant = .surface, .paint = .{} } },
        },
    };
    var ops: [3]draw.Op = undefined;
    const out = try paint(.{ .entries = &entries }, .{}, &tk, .sidebar, .{ .ops = &ops });
    try std.testing.expectEqual(@as(usize, 1), out.ops.len);
    try std.testing.expectEqual(@as(i32, 0), out.ops[0].quad.rect.y);
}

test "paint fails closed for bad snapshots and fixed-capacity overflow" {
    const tk = testTokens();
    const entries = [_]ui_tree.RectEntry{
        cardEntry(1, .{ .x = 0, .y = 0, .width = 5, .height = 5 }, .{ .variant = .surface, .paint = .{} }, null),
        cardEntry(2, .{ .x = 5, .y = 0, .width = 5, .height = 5 }, .{ .variant = .surface, .paint = .{} }, null),
    };
    var one_op: [1]draw.Op = undefined;
    try std.testing.expectError(error.InsufficientBuffer, paint(.{ .entries = &entries }, .{}, &tk, .sidebar, .{ .ops = &one_op }));
    try std.testing.expectEqual(emptyOp(), one_op[0]);

    const malformed = [_]ui_tree.RectEntry{.{ .id = 3, .parent_index = null, .kind = .text, .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .effective_clip = null, .action = null, .visual = .{ .card = .{ .variant = .surface, .paint = .{} } } }};
    try std.testing.expectError(error.InvalidSnapshot, paint(.{ .entries = &malformed }, .{}, &tk, .sidebar, .{ .ops = &one_op }));

    const invalid_rect = [_]ui_tree.RectEntry{cardEntry(4, .{ .x = std.math.nan(f32), .y = 0, .width = 1, .height = 1 }, .{ .variant = .surface, .paint = .{} }, null)};
    try std.testing.expectError(error.InvalidRect, paint(.{ .entries = &invalid_rect }, .{}, &tk, .sidebar, .{ .ops = &one_op }));
}

test "leading icon slot survives projection into the published entry" {
    // 회귀: `visualFor`가 `leading_icon`을 버려, builder가 검증·계산한 슬롯이 published entry에
    // 도달하지 못했다 — 아이콘이 영원히 그려지지 않는 상태였다.
    const label = [_]ui_tree.UiNode{ui_tree.text(.{ .id = 2, .value = "이어하기" })};
    const node = ui_tree.buttonWithLabel(.{
        .id = 1,
        .action = .{ .id = 7 },
        .leading_icon = .{ .codepoint = icons.codepointFit(.reset, .tight), .extent_px = 18, .gap_px = 8 },
    }, &label);

    var entries: [4]ui_tree.RectEntry = undefined;
    var items: [4]layout.Item = undefined;
    var scratch: [4]layout.FlexScratch = undefined;
    var rects: [4]layout.UiRect = undefined;
    const built = try ui_tree.build(node, .{
        .root_size = .{ .width = 200, .height = 60 },
        .max_entries = 4,
        .max_depth = 2,
    }, .{ .entries = &entries, .items = &items, .flex_scratch = &scratch, .child_rects = &rects });

    const entry = built.entries[built.find(1).?];
    const icon = entry.visual.button.leading_icon orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(icons.codepointFit(.reset, .tight), icon.codepoint);
    try std.testing.expectEqual(@as(u16, 18), icon.extent_px);
    try std.testing.expectEqual(@as(u16, 8), icon.gap_px);
}
