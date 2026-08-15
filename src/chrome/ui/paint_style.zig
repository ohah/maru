//! Token and interaction-state resolution for semantic UI props.
//!
//! This module has no draw buffer and no pixel snapping. That separation keeps a future Metal,
//! software, or inspector consumer from reimplementing Card variant precedence.

const interaction = @import("interaction.zig");
const tokens = @import("../tokens.zig");
const ui_style = @import("style.zig");
const ui_tree = @import("tree.zig");

/// Named shadow metrics are resolved here even though ML3a does not lower a shadow to Metal yet.
/// Keeping this in the resolved style prevents a future backend from inventing a second mapping.
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
    /// Variant construction is opaque unless a semantic PaintStyle says otherwise. A field
    /// default makes that invariant independent of which closed variant is selected.
    opacity: u8 = 0xFF,
    shadow: ?ResolvedShadow,
};

pub const ResolvedTextStyle = struct {
    foreground: tokens.ColorRole,
    opacity: u8,
};

pub const ResolvedButtonStyle = ResolvedCardStyle;

/// Buttons have their own base palette and interaction states.  Sharing only the resolved quad
/// shape with cards keeps rendering cheap without letting a disclosure/card variant leak into a
/// command target.
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

/// Resolves one card without touching a renderer. Explicit paint props replace only the base
/// variant; pressed/focus/hover remain visible above them, and disabled is intentionally last so
/// an inaccessible custom color cannot make an inert action look enabled.
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

/// Text shaping is ML3b work, but its foreground and opacity already use the same typed style
/// vocabulary. Keeping this pure resolver now avoids a later text-only color rule in a host.
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
