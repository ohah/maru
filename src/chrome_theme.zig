//! **해석된 테마 → chrome 토큰.** 사용자가 고른 색이 사이드바·도크·탭·모달에 닿는 유일한 길이다.
//!
//! ## 왜 최상위인가
//!
//! 입력은 `config.appearance.ResolvedAppearance`(config 계층)이고 출력은 `chrome.Tokens`(L3)다.
//! **chrome 은 config 를 import 하지 않는다** — 그것이 이 저장소의 경계이고, macOS 쪽 원본 주석이
//! 그 이유를 적어 뒀다:
//!
//! > chrome 은 ResolvedTheme 를 import 하지 않으므로(경계) 여기서 resolved Rgb 만 뽑아 넘기고,
//! > **역할→색 매핑은 `chrome.tokens.Tokens` 가 단일 출처로 소유**한다.
//!
//! 그래서 이 투영은 어느 쪽에도 못 산다 — `scm_items.zig`(session↔chrome)·`text_shaper.zig` 와
//! 같은 자리, 같은 이유다.
//!
//! ## 왜 뺐나
//!
//! **이 함수가 macOS `app_session.zig` 안에 있어서 Windows 가 부를 수 없었다.** 그 결과 Windows
//! 표면들이 색을 **손으로 적었고**, 화면에서 터미널만 테마를 따르고 크롬은 안 따르는 상태가 됐다
//! (실측: 터미널 `#101010`(테마) vs 사이드바 `#141922`·도크 `#181D28`·디바이더 `#2A3344` — 전부
//! 리터럴). windows-platform.md §2m.33 이 그것을 "인지된 부채" 로 적어 뒀고, 이 파일이 그것을 갚는다.
//!
//! **역할→색 매핑은 여전히 chrome 이 소유한다.** 여기서 하는 일은 필드 추림뿐이다 — 어느 테마 색이
//! 어느 chrome 역할로 가는가를 두 곳에서 정하면 두 플랫폼 화면이 갈린다.

const std = @import("std");

const chrome = @import("chrome.zig");
const config = @import("config.zig");
const session = @import("session.zig");

/// 해석된 외양 → chrome 토큰.
///
/// `Tokens.rich` 를 쓴다 — 기반 팔레트 위에 divider·focus_accent 같은 역할을 분리 색으로 얹는
/// 토큰셋이다(C4a). 옛 `tui` 룩은 제거돼 갈래가 하나다.
pub fn tokensFor(appearance: config.appearance.ResolvedAppearance) chrome.Tokens {
    const t = appearance.theme;
    // **한 번만 부른다** — 파생 계산(휘도·대비 바닥)이 호출마다 돈다.
    const diff_colors = session.syntax_theme.diffFromTheme(t);
    var tk = chrome.tokens.Tokens.rich(.{
        .foreground = t.foreground,
        .sidebar_background = t.sidebar_background,
        // 편집기 뷰가 터미널과 같은 바탕을 쓰도록(§4.1b).
        .terminal_background = t.background,
        .sidebar_foreground = t.sidebar_foreground,
        .sidebar_active = t.sidebar_active,
        .search_match = t.search_match,
        .search_match_current = t.search_match_current,
        .selection = t.selection,
        .cursor = t.cursor,
        // 테마-구동 accent(탭·포커스 언더바·활성 카드 막대·세팅 강조) — 프리셋별 시그니처 색.
        .accent = t.accent,
        // 비교 밴드 색은 **웹과 같은 함수**에서 온다 — CM6 화면이 CSS 변수로 받던 그 값이라 두
        // 화면이 같은 초록·빨강을 쓴다(§7).
        .diff_added = diff_colors.added,
        .diff_removed = diff_colors.removed,
    });
    // 활성 탭 룩 축(chrome.tab-style) — config enum 을 chrome 중립 토큰으로 옮긴다(색이
    // ThemeColors 로 흐르는 것과 같은 모양).
    tk.space.tab_active_style = switch (appearance.chrome_tab_style) {
        .connected => .connected,
        .underline => .underline,
        .pill => .pill,
    };
    return tk;
}

const testing = std.testing;

fn appearanceFrom(cfg: config.theme.Config) config.appearance.ResolvedAppearance {
    return config.appearance.resolve(cfg) catch unreachable;
}

test "테마 색이 chrome 역할로 흐른다 — 배경·전경" {
    var cfg = config.theme.Config{};
    cfg.theme.background = "#402018";
    cfg.theme.foreground = "#ffd8a0";
    const tk = tokensFor(appearanceFrom(cfg));
    // 편집기·터미널 바탕은 테마 배경 그대로다.
    const bg = tk.get(.terminal_bg);
    try testing.expectEqual(@as(u8, 0x40), bg.r);
    try testing.expectEqual(@as(u8, 0x20), bg.g);
    try testing.expectEqual(@as(u8, 0x18), bg.b);
}

test "테마를 바꾸면 크롬 색도 바뀐다 — 리터럴이 아니다" {
    // 이 성질이 없어서 Windows 표면들이 리터럴을 들고도 초록이었다(§2m.33).
    var a = config.theme.Config{};
    a.theme.background = "#101010";
    var b = config.theme.Config{};
    b.theme.background = "#402018";
    const ta = tokensFor(appearanceFrom(a));
    const tb = tokensFor(appearanceFrom(b));
    try testing.expect(!std.meta.eql(ta.get(.terminal_bg), tb.get(.terminal_bg)));
}

test "탭 룩 축이 config 에서 온다" {
    var cfg = config.theme.Config{};
    cfg.chrome_tab_style = .pill;
    try testing.expectEqual(chrome.tokens.TabActiveStyle.pill, tokensFor(appearanceFrom(cfg)).space.tab_active_style);
    cfg.chrome_tab_style = .underline;
    try testing.expectEqual(chrome.tokens.TabActiveStyle.underline, tokensFor(appearanceFrom(cfg)).space.tab_active_style);
}
