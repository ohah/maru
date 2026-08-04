//! Closed semantic visual vocabulary for the new Chrome component tree.
//!
//! This file deliberately contains no layout rect, interaction state, or draw operation. A
//! product author can describe what a Card or Text means here; `ui_paint_style` later resolves
//! those meanings through a token snapshot, while `ui_tree` owns identity and structure.

const tokens = @import("../tokens.zig");

pub const CardVariant = enum { surface, raised, selected, danger };
/// Command targets use a closed vocabulary independent of information surfaces.  Treating a
/// Button as a selected Card made archive actions inherit disclosure hover/pressed colours and
/// obscured which target was primary in the Session Dock reference.
/// 닫힌 command 표면 집합. `ghost`는 평소 panel과 같은 배경을 써 테두리 없이 label만 보이고,
/// `danger`는 파괴적 action 전용이라 token layer의 보수적 fallback(`danger_bg`/`danger_fg`)을 쓴다.
/// 상태(hover/focus/pressed/disabled) 해석은 variant와 독립이며 `paint_style`이 한 곳에서 얹는다.
pub const ButtonVariant = enum { primary, secondary, ghost, danger };
pub const TextTone = enum { primary, muted, accent, danger };
pub const ShadowKind = enum { none, raised };

/// Visual overrides share the immutable component snapshot with layout props, but have no
/// geometry-solving authority. `null` means the selected semantic variant supplies its token;
/// all RGB and shadow metrics remain owned by `tokens.zig`.
pub const PaintStyle = struct {
    background: ?tokens.ColorRole = null,
    foreground: ?tokens.ColorRole = null,
    border: ?tokens.ColorRole = null,
    /// [top-left, top-right, bottom-right, bottom-left] backing pixels.
    corner_radii_px: ?[4]u16 = null,
    /// [top, right, bottom, left] backing pixels.
    border_widths_px: ?[4]u16 = null,
    /// null preserves the variant default; `.none` explicitly disables it.
    shadow: ?ShadowKind = null,
    opacity: u8 = 0xFF,
};

pub const CardVisual = struct { variant: CardVariant, paint: PaintStyle };
pub const ButtonVisual = struct { variant: ButtonVariant, paint: PaintStyle };
pub const TextVisual = struct { tone: TextTone, paint: PaintStyle };

/// Snapshot payload shared by interaction and paint consumers. `none` is reserved for the
/// internal Container structural node, which deliberately has no product visual vocabulary.
pub const VisualProps = union(enum) {
    none,
    card: CardVisual,
    button: ButtonVisual,
    text: TextVisual,
};
