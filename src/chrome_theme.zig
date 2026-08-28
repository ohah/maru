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
    // **구문 강조 색**(§5.3). `diff`와 **같은 함수 계열**에서 온다 — `syntax_theme`가 터미널
    // 팔레트에서 파생하므로 편집기 색이 옆 터미널과 같은 언어를 쓴다(2026-07-22 사용자 결정).
    //
    // 필드 이름이 양쪽에서 같아 `@field`로 옮긴다. **이름이 갈리면 컴파일이 죽는다** — 색을
    // 한쪽에만 늘리는 것이 이 저장소가 반복해서 당한 형태라 그 자리를 타입으로 막는다.
    // (`session.syntax_capture.Role`도 같은 이름을 쓰고, 그쪽은 자기 `comptime` 검사가 지킨다.)
    //
    // **반사(`@field`)로 옮기지 않는다.** 그렇게 쓰면 이 파일이 `imports.zig`의 반사 재고에 새로
    // 들어와 digest 원장을 건드리는데(실측: `unreviewed external reflection inventory:
    // src/chrome_theme.zig count=2`), 얻는 안전성은 **명시 대입과 같다** — 어느 쪽 구조체에서
    // 이름이 바뀌거나 필드가 늘면 여기서 컴파일이 죽는다. 값싼 쪽을 고른다.
    {
        const sc = session.syntax_theme.fromTheme(t);
        tk.setSyntax(.{
            .keyword = sc.keyword,
            .string = sc.string,
            .number = sc.number,
            .comment = sc.comment,
            .property = sc.property,
            .type_name = sc.type_name,
            .function = sc.function,
            .punctuation = sc.punctuation,
            .tag = sc.tag,
            .attribute = sc.attribute,
            .invalid = sc.invalid,
        });
    }
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

test "HL6 구문 색이 테마에서 토큰으로 흐른다 — 11개 전부, 값 그대로" {
    // **다리가 이름으로 놓인다**(`@field`). 한쪽 이름을 바꾸면 컴파일이 죽지만, 값이 **엉뚱한
    // 자리로** 들어가는 것은 컴파일러가 못 잡는다 — `keyword` 색이 `string` 역할에 들어가도
    // 타입은 같다. 그래서 11개를 하나씩 대조한다.
    const cfg = config.theme.Config{};
    const app = appearanceFrom(cfg);
    const tk = tokensFor(app);
    const sc = session.syntax_theme.fromTheme(app.theme);

    inline for (@typeInfo(chrome.tokens.SyntaxPalette).@"struct".fields) |f| {
        const role = @field(chrome.tokens.ColorRole, "syntax_" ++ f.name);
        try testing.expectEqual(@field(sc, f.name), tk.get(role));
    }
}

test "HL7 구문 색이 본문색과 다르다 — 흐르기만 하고 안 보이는 상태를 막는다" {
    // `HL6`은 "테마가 준 값이 그대로 들어갔다"만 본다. 테마가 **전부 본문색을 준다면** 그것도
    // 통과하는데, 그러면 화면은 무색이다. 실제로 색이 갈리는지는 따로 재야 한다.
    const tk = tokensFor(appearanceFrom(config.theme.Config{}));
    const body = tk.get(.surface_fg);

    var differ: usize = 0;
    inline for (@typeInfo(chrome.tokens.SyntaxPalette).@"struct".fields) |f| {
        if (!std.meta.eql(body, tk.get(@field(chrome.tokens.ColorRole, "syntax_" ++ f.name)))) differ += 1;
    }
    // 전부 다를 필요는 없다(`punctuation`은 본문색을 살짝 흐린 것이라 가까울 수 있다). 다만
    // **대부분이 갈려야** 강조가 강조 구실을 한다.
    try testing.expect(differ >= 8);

    // 키워드·문자열·주석은 서로도 갈려야 한다 — 셋이 같으면 색이 있으나 마나다.
    const kw = tk.get(.syntax_keyword);
    const str = tk.get(.syntax_string);
    const cmt = tk.get(.syntax_comment);
    try testing.expect(!std.meta.eql(kw, str));
    try testing.expect(!std.meta.eql(kw, cmt));
    try testing.expect(!std.meta.eql(str, cmt));
}

test "HL8 색을 안 얹으면 무색이다 — 픽스처 수십 곳이 거짓 색을 쓰지 않는다" {
    // `setSyntax`를 안 부르는 경로(테스트 픽스처·헤드리스 lowering)가 스무 곳이 넘는다. 그
    // 자리들이 **미초기화 팔레트**를 읽으면 쓰레기 색이 나오고, 자리표시 색을 읽으면 있지도
    // 않은 강조가 화면에 뜬다. 둘 다 아니고 **본문색**이어야 한다 — §5의 "무색"이 그것이다.
    const tk = chrome.tokens.Tokens.rich(std.mem.zeroes(chrome.tokens.ThemeColors));
    const body = tk.get(.surface_fg);
    inline for (@typeInfo(chrome.tokens.SyntaxPalette).@"struct".fields) |f| {
        try testing.expectEqual(body, tk.get(@field(chrome.tokens.ColorRole, "syntax_" ++ f.name)));
    }
}
