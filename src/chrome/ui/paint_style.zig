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
            .foreground = .danger_fg,
            .border = .danger_bg,
            .corner_radii_px = uniform(tk.space.corner_radius_px),
            .border_widths_px = uniform(tk.space.border_width_px),
            .shadow = default_shadow,
        },
    };
}

fn baseButtonStyle(variant: ui_style.ButtonVariant, tk: *const tokens.Tokens) ResolvedButtonStyle {
    return switch (variant) {
        .primary => .{
            .background = .surface_fg,
            .foreground = .surface_bg,
            .border = .surface_fg,
            .corner_radii_px = uniform(tk.space.corner_radius_px),
            .border_widths_px = uniform(tk.space.border_width_px),
            .shadow = null,
        },
        .secondary => .{
            .background = .tab_hover_bg,
            .foreground = .surface_fg,
            .border = .divider,
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
