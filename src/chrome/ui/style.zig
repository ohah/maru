//! 새 Chrome component tree가 쓰는 **닫힌 의미(semantic) 시각 어휘**다.
//!
//! 이 파일에는 layout rect, interaction state, draw operation을 의도적으로 두지 않는다. 제품
//! 작성자는 여기서 Card나 Text가 무엇을 뜻하는지만 서술하고, 그 의미를 token snapshot으로
//! 해석하는 일은 `ui_paint_style`이, identity와 구조는 `ui_tree`가 맡는다.

const tokens = @import("../tokens.zig");

pub const CardVariant = enum { surface, raised, selected, danger };
/// command 대상은 정보 표면과 독립된 닫힌 어휘를 쓴다. Button을 selected Card로 다루었더니 archive
/// action이 disclosure의 hover/pressed 색을 물려받았고, Session Dock 레퍼런스에서 어느 대상이
/// primary인지 가려졌다.
/// 닫힌 command 표면 집합. `ghost`는 평소 panel과 같은 배경을 써 테두리 없이 label만 보이고,
/// `danger`는 파괴적 action 전용이라 token layer의 보수적 fallback(`danger_bg`/`danger_fg`)을 쓴다.
/// 상태(hover/focus/pressed/disabled) 해석은 variant와 독립이며 `paint_style`이 한 곳에서 얹는다.
pub const ButtonVariant = enum { primary, secondary, ghost, danger };
pub const TextTone = enum { primary, muted, accent, danger };
pub const ShadowKind = enum { none, raised };

/// 시각 override는 layout props와 같은 immutable component snapshot을 공유하지만 geometry를 푸는
/// 권한은 없다. `null`은 선택된 semantic variant가 자기 token을 준다는 뜻이고, 모든 RGB와 shadow
/// 메트릭은 `tokens.zig`가 소유한다.
pub const PaintStyle = struct {
    background: ?tokens.ColorRole = null,
    foreground: ?tokens.ColorRole = null,
    border: ?tokens.ColorRole = null,
    /// [좌상, 우상, 우하, 좌하] backing 픽셀.
    corner_radii_px: ?[4]u16 = null,
    /// [상, 우, 하, 좌] backing 픽셀.
    border_widths_px: ?[4]u16 = null,
    /// `null`은 variant 기본값을 유지하고, `.none`은 명시적으로 끈다.
    shadow: ?ShadowKind = null,
    opacity: u8 = 0xFF,
};

pub const CardVisual = struct { variant: CardVariant, paint: PaintStyle };
/// `leading_icon`은 published entry까지 실려야 paint/lowering이 final placement를 만들 수 있다.
/// 치수는 `ui/button.zig`가 `ButtonSize`와 token에서 한 번 계산해 넣는다.
pub const ButtonVisual = struct {
    variant: ButtonVariant,
    paint: PaintStyle,
    leading_icon: ?LeadingIcon = null,
};

pub const LeadingIcon = struct {
    codepoint: u21,
    extent_px: u16,
    gap_px: u16,
};
pub const TextVisual = struct { tone: TextTone, paint: PaintStyle };

/// interaction과 paint consumer가 공유하는 snapshot payload다. `none`은 내부 Container 구조 노드
/// 몫으로 예약했다 — 그 노드는 제품 시각 어휘를 의도적으로 갖지 않는다.
pub const VisualProps = union(enum) {
    none,
    card: CardVisual,
    button: ButtonVisual,
    text: TextVisual,
};
