//! Chrome 디자인 토큰(데이터). 컴포넌트는 `tokens.get(role)`만 읽고 `if (rich)` 분기를 절대 안 한다 —
//! 테마 전환 = 토큰셋 교체(컴포넌트 코드 불변). tui와 rich는 같은 struct의 두 값. 현재 코드에 흩어진
//! 색 파생(lighten +24/+48 등)·픽셀 상수(사이드바 폭·슬롯 높이)를 여기로 모은다.
//! 단일 출처: docs/chrome-strategy.md §5.1, docs/layering-and-portability.md §6.

const std = @import("std");
const Rgb = @import("../color.zig").Rgb;

/// 색 역할(semantic). 컴포넌트는 역할만 알고, 실제 Rgb는 토큰이 준다. divider/focus_accent/drop_zone은
/// 현재 sidebar_active를 공유하지만 rich에서 분리할 수 있게 별도 role로 둔다.
pub const ColorRole = enum {
    surface_bg,
    surface_fg,
    muted_fg,
    tab_active_bg,
    tab_hover_bg,
    divider,
    focus_accent,
    drop_zone,
    search_match,
    search_match_current,
    selection,
    cursor,
};

/// 비-색 레이아웃 토큰(픽셀/비율). 지금 app_dev_session에 흩어진 상수의 단일 출처. rich는 이 값을 바꾼다.
pub const Spacing = struct {
    sidebar_width_px: u32 = 180,
    sidebar_slot_height_ratio_milli: u32 = 2500, // 슬롯 높이 = 2.5 × cell height
    modal_margin_cells: u32 = 2, // 모달 박스 좌우 안쪽 여백(셀)
};

/// 테두리/선 토큰. tui는 ~2px 띠(reserved-kind). rich에서 radius 등을 추가한다.
pub const Border = struct {
    line_thickness_px: u32 = 2,
};

/// 한 테마 = 토큰 묶음. `Tokens.tui(resolvedTheme)`가 현재 9색 ResolvedTheme + 파생을 채운다(C0 구현).
/// `Tokens.rich(...)`는 C4. 컴포넌트는 이 값만 소비한다.
pub const Tokens = struct {
    palette: std.EnumArray(ColorRole, Rgb),
    space: Spacing = .{},
    border: Border = .{},

    pub fn get(self: *const Tokens, role: ColorRole) Rgb {
        return self.palette.get(role);
    }
};
