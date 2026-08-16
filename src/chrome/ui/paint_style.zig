//! semantic UI props를 token과 interaction state로 해석하는 모듈이다.
//!
//! 이 모듈에는 draw buffer도 pixel snapping도 없다. 그렇게 갈라 두어야 나중에 올 Metal·software·
//! inspector consumer가 Card variant 우선순위를 각자 다시 구현하지 않는다.

const interaction = @import("interaction.zig");
const tokens = @import("../tokens.zig");
const ui_style = @import("style.zig");
const ui_tree = @import("tree.zig");

/// ML3a가 아직 shadow를 Metal로 내리지 않지만 이름 붙은 shadow 메트릭은 여기서 해석한다. 이 값을
/// resolved style에 두어야 나중에 올 backend가 두 번째 매핑을 만들어 내지 않는다.
pub const ResolvedShadow = struct {
    blur_px: u16,
    offset_y_px: u16,
    alpha: u8,
};

pub const ResolvedCardStyle = struct {
    background: tokens.ColorRole,
    foreground: tokens.ColorRole,
    border: ?tokens.ColorRole,
    corner_radii_px: [4]u16,
    border_widths_px: [4]u16,
    /// semantic PaintStyle이 달리 말하지 않는 한 variant는 불투명(opaque)하게 만든다. 필드 기본값으로
    /// 두면 그 불변식이 어떤 닫힌 variant를 골랐는지와 무관해진다.
    opacity: u8 = 0xFF,
    shadow: ?ResolvedShadow,
};

pub const ResolvedTextStyle = struct {
    foreground: tokens.ColorRole,
    opacity: u8,
};

pub const ResolvedButtonStyle = ResolvedCardStyle;

/// Button은 자기만의 기본 팔레트와 interaction state를 갖는다. card와는 해석된 quad 모양만 공유하므로
/// 렌더링은 싸게 유지되면서도 disclosure/card variant가 command 대상으로 새지 않는다.
pub fn resolveButton(
    id: ui_tree.UiId,
    visual: ui_style.ButtonVisual,
    action: ?ui_tree.UiAction,
    state: interaction.InteractionState,
    tk: *const tokens.Tokens,
) ResolvedButtonStyle {
    var result = baseButtonStyle(visual.variant, tk);
    applyPaintOverride(&result, visual.paint, tk);
    const enabled = action != null and action.?.enabled;
    if (enabled and state.capture != null and state.capture.?.id == id) {
        result.background = .tab_active_bg;
        result.foreground = .surface_fg;
        result.border = .focus_accent;
    } else if (enabled and state.focused != null and state.focused.? == id) {
        result.border = .focus_accent;
    } else if (enabled and state.hovered != null and state.hovered.? == id) {
        result.background = .row_hover_bg;
        // Primary begins with a light foreground-colored fill. Hover deliberately moves it to
        // the dark shared hover token, so retaining its normal dark label would erase contrast.
        // Resolve both from the same semantic Button variant instead of asking the view to
        // special-case pointer state.
        if (visual.variant == .primary) result.foreground = .surface_fg;
    }
    if (action != null and !action.?.enabled) {
        result.background = .surface_bg;
        result.foreground = .muted_fg;
        result.border = .divider;
        result.opacity = @min(result.opacity, 0x80);
        result.shadow = null;
    }
    return result;
}

/// renderer를 건드리지 않고 card 하나를 해석한다. 명시적 paint props는 base variant만 대체하고,
/// pressed/focus/hover는 그 위에 그대로 보인다. disabled를 의도적으로 마지막에 두어, 접근성이 나쁜
/// 사용자 지정 색이 비활성 action을 활성처럼 보이게 만들지 못한다.
pub fn resolveCard(
    id: ui_tree.UiId,
    visual: ui_style.CardVisual,
    action: ?ui_tree.UiAction,
    state: interaction.InteractionState,
    tk: *const tokens.Tokens,
) ResolvedCardStyle {
    var result = baseCardStyle(visual.variant, tk);
    applyPaintOverride(&result, visual.paint, tk);

    const enabled = action != null and action.?.enabled;
    if (enabled and state.capture != null and state.capture.?.id == id) {
        result.background = .tab_active_bg;
        result.border = .focus_accent;
    } else if (enabled and state.focused != null and state.focused.? == id) {
        result.border = .focus_accent;
    } else if (enabled and state.hovered != null and state.hovered.? == id) {
        result.background = .row_hover_bg;
    }

    if (action != null and !action.?.enabled) {
        result.background = .surface_bg;
        result.foreground = .muted_fg;
        result.border = .divider;
        result.opacity = @min(result.opacity, 0x80);
        result.shadow = null;
    }
    return result;
}

/// text shaping은 ML3b의 일이지만, 그 전경색과 불투명도는 이미 같은 typed 스타일 어휘를 쓴다. 지금
/// 이 순수 resolver를 두면 나중에 host에 텍스트 전용 색 규칙이 따로 생기는 일을 막는다.
pub fn resolveText(visual: ui_style.TextVisual) ResolvedTextStyle {
    var foreground: tokens.ColorRole = switch (visual.tone) {
        .primary => .surface_fg,
        .muted => .muted_fg,
        .accent => .accent_bar,
        .danger => .danger_fg,
    };
    if (visual.paint.foreground) |override| foreground = override;
    return .{ .foreground = foreground, .opacity = visual.paint.opacity };
}

fn baseCardStyle(variant: ui_style.CardVariant, tk: *const tokens.Tokens) ResolvedCardStyle {
    const default_shadow: ?ResolvedShadow = switch (variant) {
        .raised => shadowFromTokens(tk),
        else => null,
    };
    return switch (variant) {
        .surface => .{
            .background = .surface_bg,
            .foreground = .surface_fg,
            .border = .divider,
            .corner_radii_px = uniform(tk.space.corner_radius_px),
            .border_widths_px = uniform(tk.space.border_width_px),
            .shadow = default_shadow,
        },
        .raised => .{
            .background = .tab_hover_bg,
            .foreground = .surface_fg,
            .border = .divider,
            .corner_radii_px = uniform(tk.space.corner_radius_px),
            .border_widths_px = uniform(tk.space.border_width_px),
            .shadow = default_shadow,
        },
        .selected => .{
            .background = .tab_active_bg,
            .foreground = .surface_fg,
            .border = .focus_accent,
            .corner_radii_px = uniform(tk.space.corner_radius_px),
            .border_widths_px = uniform(tk.space.border_width_px),
            .shadow = default_shadow,
        },
        .danger => .{
            .background = .danger_bg,
            .foreground = buttonForeground(.danger),
            .border = .danger_bg,
            .corner_radii_px = uniform(tk.space.corner_radius_px),
            .border_widths_px = uniform(tk.space.border_width_px),
            .shadow = default_shadow,
        },
    };
}

/// Label 전경은 variant가 정한다. paint와 component가 각자 매핑을 들면 값이 갈려 "보이는 색과
/// 계산된 색"이 달라지므로, 그 매핑은 여기 하나만 둔다. token 인스턴스와 무관하게 role만 고른다.
pub fn buttonForeground(variant: ui_style.ButtonVariant) tokens.ColorRole {
    return switch (variant) {
        .primary => .surface_bg,
        .secondary, .ghost => .surface_fg,
        .danger => .danger_fg,
    };
}

fn baseButtonStyle(variant: ui_style.ButtonVariant, tk: *const tokens.Tokens) ResolvedButtonStyle {
    return switch (variant) {
        .primary => .{
            .background = .surface_fg,
            .foreground = buttonForeground(.primary),
            .border = .surface_fg,
            .corner_radii_px = uniform(tk.space.corner_radius_px),
            .border_widths_px = uniform(tk.space.border_width_px),
            .shadow = null,
        },
        .secondary => .{
            .background = .tab_hover_bg,
            .foreground = buttonForeground(.secondary),
            .border = .divider,
            .corner_radii_px = uniform(tk.space.corner_radius_px),
            .border_widths_px = uniform(tk.space.border_width_px),
            .shadow = null,
        },
        // Ghost는 panel과 같은 배경을 base로 삼아 테두리 없이 label만 남긴다. hover/focus는 상태
        // 해석이 그 위에 얹으므로, 여기서 투명도를 낮추거나 별도 "없음" 색을 만들지 않는다.
        .ghost => .{
            .background = .surface_bg,
            .foreground = buttonForeground(.ghost),
            .border = null,
            .corner_radii_px = uniform(tk.space.corner_radius_px),
            // **테두리 색이 없으면 폭도 0이다.** lowering은 `border_role`이 null이면 색을 RGBA 0으로
            // packing하는데 폭은 그대로 넘긴다 — 셰이더가 그 띠를 투명하게 칠해 **뒤가 비친다**.
            // 배경과 같은 색이면 안 보이지만, 그 위에 호버 밴드처럼 다른 색이 깔리는 순간 행보다 어두운
            // 2px 링으로 드러난다(소스 컨트롤 도크 호버 캡처로 실측). ghost는 "테두리 없는 버튼"이므로
            // 폭을 남겨 둘 이유가 없다.
            .border_widths_px = uniform(0),
            .shadow = null,
        },
        // 파괴적 action. ThemeColors에 semantic error 입력이 없어 token layer가 보수적 fallback을
        // 소유하며(`tokens.zig`), 컴포넌트가 literal RGB를 들고 오지 않는다.
        .danger => .{
            .background = .danger_bg,
            .foreground = .danger_fg,
            .border = .danger_bg,
            .corner_radii_px = uniform(tk.space.corner_radius_px),
            .border_widths_px = uniform(tk.space.border_width_px),
            .shadow = null,
        },
    };
}

fn applyPaintOverride(result: *ResolvedCardStyle, paint_style: ui_style.PaintStyle, tk: *const tokens.Tokens) void {
    if (paint_style.background) |value| result.background = value;
    if (paint_style.foreground) |value| result.foreground = value;
    if (paint_style.border) |value| result.border = value;
    if (paint_style.corner_radii_px) |value| result.corner_radii_px = value;
    if (paint_style.border_widths_px) |value| result.border_widths_px = value;
    result.opacity = paint_style.opacity;
    if (paint_style.shadow) |kind| {
        result.shadow = switch (kind) {
            .none => null,
            .raised => shadowFromTokens(tk),
        };
    }
}

fn shadowFromTokens(tk: *const tokens.Tokens) ?ResolvedShadow {
    if (tk.space.shadow_alpha == 0 or tk.space.shadow_blur_px == 0) return null;
    return .{
        .blur_px = tk.space.shadow_blur_px,
        .offset_y_px = tk.space.shadow_offset_y_px,
        .alpha = tk.space.shadow_alpha,
    };
}

fn uniform(value: u16) [4]u16 {
    return .{ value, value, value, value };
}

test "ghost 버튼은 테두리 폭이 0이다(색 없는 테두리가 배경을 뚫는다)" {
    // lowering은 `border_role`이 null이면 색을 RGBA 0으로 packing하면서 **폭은 그대로 넘긴다**. 그러면
    // 셰이더가 그 띠를 투명하게 칠해 뒤가 비치고, 버튼이 행과 같은 배경일 때는 안 보이다가 **호버 밴드가
    // 깔리는 순간** 행보다 어두운 링으로 드러난다(소스 컨트롤 도크에서 실측). 폭을 0으로 두는 것이
    // "테두리 없음"의 유일한 정직한 표현이다.
    const tk = tokens.Tokens.tui(.{
        .diff_added = .{ .r = 1, .g = 1, .b = 1 },
        .diff_removed = .{ .r = 2, .g = 2, .b = 2 },
        .foreground = .{ .r = 3, .g = 3, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 4, .b = 4 },
        .sidebar_foreground = .{ .r = 5, .g = 5, .b = 5 },
        .sidebar_active = .{ .r = 6, .g = 6, .b = 6 },
        .search_match = .{ .r = 7, .g = 7, .b = 7 },
        .search_match_current = .{ .r = 8, .g = 8, .b = 8 },
        .selection = .{ .r = 9, .g = 9, .b = 9 },
        .cursor = .{ .r = 10, .g = 10, .b = 10 },
        .terminal_background = .{ .r = 11, .g = 11, .b = 11 },
        .accent = .{ .r = 12, .g = 12, .b = 12 },
    });
    const ghost = resolveButton(1, .{ .variant = .ghost, .paint = .{} }, .{ .id = 2 }, .{}, &tk);
    try @import("std").testing.expectEqual(@as(?tokens.ColorRole, null), ghost.border);
    try @import("std").testing.expectEqualSlices(u16, &.{ 0, 0, 0, 0 }, &ghost.border_widths_px);
}
