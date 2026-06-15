//! Chrome 디자인 토큰(데이터). 컴포넌트는 `tokens.get(role)`만 읽고 `if (rich)` 분기를 절대 안 한다 —
//! 테마 전환 = 토큰셋 교체(컴포넌트 코드 불변). tui와 rich는 같은 struct의 두 값. 현재 코드에 흩어진
//! 색 파생(lighten +24/+48 등)·픽셀 상수(사이드바 폭·슬롯 높이)를 여기로 모은다.
//! 단일 출처: docs/chrome-strategy.md §5.1, docs/layering-and-portability.md §6.

const std = @import("std");
const Rgb = @import("../color.zig").Rgb;

/// rich 토큰 색 파생(neutral — config의 appearance.lighten을 chrome이 import 못 하므로 여기 둔다). 채널별 ±delta를
/// [0,255]로 clamp. rich가 tui의 sidebar_active-공유 role을 분리할 때만 쓴다(tui는 안 씀 — 원본 테마 색 그대로).
fn clampChannel(c: u8, delta: i16) u8 {
    return @intCast(std.math.clamp(@as(i16, c) + delta, 0, 255));
}
fn lightenRgb(rgb: Rgb, delta: u8) Rgb {
    return .{ .r = clampChannel(rgb.r, delta), .g = clampChannel(rgb.g, delta), .b = clampChannel(rgb.b, delta) };
}
fn darkenRgb(rgb: Rgb, delta: u8) Rgb {
    const d: i16 = -@as(i16, delta);
    return .{ .r = clampChannel(rgb.r, d), .g = clampChannel(rgb.g, d), .b = clampChannel(rgb.b, d) };
}

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

/// 비-색 레이아웃 토큰(픽셀/비율, 정적 디자인 값 — rich는 바꾼다). chrome-strategy.md §5.1이 정의한 계획 기반
/// 토큰이라, 아직 소비처가 없어도(C2/C3 컴포넌트에서 읽음) 계획 링크와 함께 둔다(메모리 no-defensive 예외).
/// 단 **런타임 가변값(사이드바 폭 — 사용자 드래그)은 토큰이 아니라 props**(metrics.sidebar_width_px, 동적)로 흐른다
/// — 정적 토큰에 하드코딩하면 stale 출처가 되므로 토큰에 두지 않는다.
pub const Spacing = struct {
    modal_margin_cells: u32 = 2, // 모달 박스 좌우 안쪽 여백(셀) — Notice가 소비
    sidebar_slot_height_ratio_milli: u32 = 2500, // 사이드바 슬롯 높이 = 2.5×cell. C2/C3 사이드바 컴포넌트가 소비(계획)
};

/// 테두리/선 토큰. tui는 ~2px 띠(reserved-kind). rich에서 radius 등을 추가한다.
pub const Border = struct {
    line_thickness_px: u32 = 2,
};

/// `Tokens.tui`가 받는 resolved 테마 색(config.ResolvedTheme의 chrome-중립 투영). chrome은 config를 import하지
/// 않으므로(경계) 호출자(platform)가 ResolvedTheme에서 이 plain Rgb들만 뽑아 넘긴다. 역할→색 매핑 자체는
/// tui()가 단일 출처로 소유한다. background는 현재 어떤 역할도 안 써서 제외(필요해지면 추가).
pub const ThemeColors = struct {
    foreground: Rgb,
    sidebar_background: Rgb,
    sidebar_foreground: Rgb,
    sidebar_active: Rgb,
    search_match: Rgb,
    search_match_current: Rgb,
    selection: Rgb,
    cursor: Rgb,
};

/// 한 테마 = 토큰 묶음. `Tokens.tui(theme)`가 resolved 테마 색에서 12개 ColorRole을 채운다(C0 구현).
/// `Tokens.rich(...)`는 C4. 컴포넌트는 이 값만 소비한다.
pub const Tokens = struct {
    palette: std.EnumArray(ColorRole, Rgb),
    space: Spacing = .{},
    border: Border = .{},

    /// tui 토큰셋: resolved 테마(chrome-중립 ThemeColors)에서 12개 ColorRole을 채운다 — **역할→색 매핑의 단일
    /// 출처**. divider/focus_accent/tab_*/drop_zone은 현재 sidebar_active를 공유한다(렌더 sidebarActiveBg와 같은
    /// 출처), rich(C4)는 토큰셋만 바꿔 분리한다. muted_fg는 C0에선 sidebar_foreground. initFill 기본값은 12역할을
    /// 전부 명시 set하므로 실제로 안 쓰이지만(foreground로 채워 둠) EnumArray 초기화에 필요하다.
    pub fn tui(theme: ThemeColors) Tokens {
        var palette = std.EnumArray(ColorRole, Rgb).initFill(theme.foreground);
        palette.set(.surface_bg, theme.sidebar_background);
        palette.set(.surface_fg, theme.sidebar_foreground);
        palette.set(.muted_fg, theme.sidebar_foreground);
        palette.set(.tab_active_bg, theme.sidebar_active);
        palette.set(.tab_hover_bg, theme.sidebar_active);
        palette.set(.divider, theme.sidebar_active);
        palette.set(.focus_accent, theme.sidebar_active);
        palette.set(.drop_zone, theme.sidebar_active);
        palette.set(.search_match, theme.search_match);
        palette.set(.search_match_current, theme.search_match_current);
        palette.set(.selection, theme.selection);
        palette.set(.cursor, theme.cursor);
        return .{ .palette = palette };
    }

    /// rich 토큰셋(C4a): tui 색에서 출발해 tui가 sidebar_active로 **공유**하던 role(divider/focus_accent/drop_zone/
    /// tab_hover_bg)을 분리된 파생색으로 채운다 — divider 약간 어둡게, focus_accent 밝게, drop_zone 밝게, tab_hover 어둡게,
    /// muted_fg 더 흐리게. 컴포넌트는 같은 role을 읽으므로 코드 불변(테마=토큰셋 교체). 둥근 모서리·그라데이션(C4b)은
    /// 후속이라 Border/Spacing은 tui와 동일. 색 파생은 lightenRgb/darkenRgb(neutral, config import 없이).
    pub fn rich(theme: ThemeColors) Tokens {
        var tk = tui(theme);
        tk.palette.set(.divider, darkenRgb(theme.sidebar_active, 24));
        tk.palette.set(.focus_accent, lightenRgb(theme.sidebar_active, 40));
        tk.palette.set(.drop_zone, lightenRgb(theme.sidebar_active, 16));
        tk.palette.set(.tab_hover_bg, darkenRgb(theme.sidebar_active, 12));
        tk.palette.set(.muted_fg, darkenRgb(theme.sidebar_foreground, 48));
        return tk;
    }

    pub fn get(self: *const Tokens, role: ColorRole) Rgb {
        return self.palette.get(role);
    }
};

test "Tokens.tui maps resolved theme colors to the 12 semantic roles" {
    const c = struct {
        fn rgb(r: u8, g: u8, b: u8) Rgb {
            return .{ .r = r, .g = g, .b = b };
        }
    };
    const tk = Tokens.tui(.{
        .foreground = c.rgb(1, 1, 1),
        .sidebar_background = c.rgb(2, 2, 2),
        .sidebar_foreground = c.rgb(3, 3, 3),
        .sidebar_active = c.rgb(4, 4, 4),
        .search_match = c.rgb(5, 5, 5),
        .search_match_current = c.rgb(6, 6, 6),
        .selection = c.rgb(7, 7, 7),
        .cursor = c.rgb(8, 8, 8),
    });
    try std.testing.expectEqual(c.rgb(2, 2, 2), tk.get(.surface_bg));
    try std.testing.expectEqual(c.rgb(3, 3, 3), tk.get(.surface_fg));
    try std.testing.expectEqual(c.rgb(4, 4, 4), tk.get(.focus_accent)); // sidebar_active 공유
    try std.testing.expectEqual(c.rgb(4, 4, 4), tk.get(.divider));
    try std.testing.expectEqual(c.rgb(8, 8, 8), tk.get(.cursor));
}

test "Tokens.rich separates the sidebar_active-shared roles into derived colors (tui 불변)" {
    const c = struct {
        fn rgb(r: u8, g: u8, b: u8) Rgb {
            return .{ .r = r, .g = g, .b = b };
        }
    };
    const theme = ThemeColors{
        .foreground = c.rgb(200, 200, 200),
        .sidebar_background = c.rgb(20, 20, 20),
        .sidebar_foreground = c.rgb(180, 180, 180),
        .sidebar_active = c.rgb(100, 100, 100),
        .search_match = c.rgb(5, 5, 5),
        .search_match_current = c.rgb(6, 6, 6),
        .selection = c.rgb(7, 7, 7),
        .cursor = c.rgb(8, 8, 8),
    };
    const t = Tokens.tui(theme);
    const r = Tokens.rich(theme);
    // tui: divider/focus_accent/drop_zone/tab_hover_bg = sidebar_active(공유). rich: 분리 파생.
    try std.testing.expectEqual(c.rgb(100, 100, 100), t.get(.divider));
    try std.testing.expectEqual(c.rgb(76, 76, 76), r.get(.divider)); // darken 24
    try std.testing.expectEqual(c.rgb(140, 140, 140), r.get(.focus_accent)); // lighten 40
    try std.testing.expectEqual(c.rgb(116, 116, 116), r.get(.drop_zone)); // lighten 16
    try std.testing.expectEqual(c.rgb(88, 88, 88), r.get(.tab_hover_bg)); // darken 12
    try std.testing.expectEqual(c.rgb(132, 132, 132), r.get(.muted_fg)); // sidebar_fg(180) darken 48
    // 분리됨: divider != focus_accent != tab_active_bg(=sidebar_active 그대로).
    try std.testing.expectEqual(c.rgb(100, 100, 100), r.get(.tab_active_bg)); // 활성은 원색 유지
    try std.testing.expect(!std.meta.eql(r.get(.divider), r.get(.focus_accent)));
    // rich가 안 건드리는 role은 tui와 동일.
    try std.testing.expectEqual(t.get(.surface_bg), r.get(.surface_bg));
    try std.testing.expectEqual(t.get(.cursor), r.get(.cursor));
    try std.testing.expectEqual(t.get(.search_match), r.get(.search_match));
}
