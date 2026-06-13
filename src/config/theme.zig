pub const FontConfig = struct {
    family: []const u8 = "JetBrains Mono",
    size: f32 = 14,
};

pub const ThemeConfig = struct {
    background: []const u8 = "#101010",
    foreground: []const u8 = "#e8e8e8",
    cursor: []const u8 = "#ffffff",
    selection: []const u8 = "#334455",
    // 세로 탭 사이드바 색(선택, #RRGGBB). null이면 background에서 파생한다(resolveTheme의 lighten):
    // sidebar_background는 배경 +24(코히어런트하게 살짝 밝게), sidebar_active는 +48(활성 탭 하이라이트).
    // 명시하면 그 색으로 override해 테마가 사이드바를 background와 독립적으로 정할 수 있다(파생은 기본값).
    sidebar_background: ?[]const u8 = null,
    sidebar_active: ?[]const u8 = null,
    // 사이드바·pane 탭 바 제목 글자색(선택, #RRGGBB). null이면 foreground(터미널 글자색)를 그대로 쓴다.
    // 활성 탭은 이 색(full), 비활성 탭은 이 색을 background 쪽으로 흐리게 한 muted(렌더가 파생).
    sidebar_foreground: ?[]const u8 = null,
};

pub const CursorShape = enum {
    block,
    bar,
    underline,
};

pub const CursorConfig = struct {
    shape: CursorShape = .block,
    blink: bool = true,
};

/// 메인 화면(셸)에서 PageUp/PageDown를 어떻게 다룰지. alt 화면(vim/less)에선 어느 쪽이든 항상
/// 앱으로 `\e[5~`/`\e[6~`를 보낸다(앱이 자체 페이징).
pub const PageKeys = enum {
    /// xterm/Ghostty식: 그대로 PTY로 `\e[5~`/`\e[6~`를 보낸다. 레퍼런스와 일치하지만, 셸 프롬프트에서
    /// 깨진다 — emacs keymap은 BEL+'~'를 입력줄에 박고, vi keymap은 끝 '~'를 vi-swap-case로 해석해
    /// 대소문자를 토글한다(실측 확인). xterm 순정을 원하면 `input.page-keys = passthrough`로 opt-in.
    passthrough,
    /// Terminal.app/iTerm2식(기본): 메인 화면에선 Maru 스크롤백을 한 페이지씩 스크롤한다 — 셸에
    /// `\e[5~`를 안 보내 셸 keymap(vi/emacs)·프레임워크와 무관하게 입력줄이 안 깨진다(Mac 관례).
    scroll,
};

pub const InputConfig = struct {
    // 기본 scroll: Mac 관례(Terminal.app/iTerm2) + 셸 keymap 오해석(case 토글·'~' 삽입) 원천 차단.
    page_keys: PageKeys = .scroll,
};

/// quick terminal(전역 토글 오버레이 패널)을 어느 화면에 띄울지. main=주 디스플레이, mouse=마우스 포인터가
/// 있는 화면(멀티 모니터에서 지금 보는 화면). 실제 NSScreen 선택은 플랫폼(Swift)이 한다.
pub const QuickTerminalScreen = enum {
    main,
    mouse,
};

/// quick terminal 패널이 화면 어느 가장자리에서 슬라이드해 나올지. top/bottom은 전폭 + height_fraction 높이,
/// left/right는 전고 + height_fraction 폭(가장자리에 수직인 '두께'에 비율이 적용된다). 슬라이드/배치는 Swift.
pub const QuickTerminalPosition = enum {
    top,
    bottom,
    left,
    right,
};

/// quick terminal 표시 옵션. 값 검증/기본값은 loader가 채우고, 플랫폼(Swift)이 ABI로 받아 패널 크기·위치·
/// 화면·자동 숨김 동작에 쓴다.
pub const QuickTerminalConfig = struct {
    // 가장자리에 수직인 '두께' 비율(화면 visibleFrame 대비, 0.1~1.0). top/bottom이면 높이, left/right면 폭. 기본 0.45.
    height_fraction: f32 = 0.45,
    // 포커스를 잃으면(다른 창/앱 클릭) 자동으로 숨길지. 기본 true(quick terminal 표준 동작). false면 토글로만 숨김.
    auto_hide: bool = true,
    // 어느 화면에 띄울지.
    screen: QuickTerminalScreen = .main,
    // 화면 어느 가장자리에서 나올지.
    position: QuickTerminalPosition = .top,
};

pub const Config = struct {
    font: FontConfig = .{},
    theme: ThemeConfig = .{},
    cursor: CursorConfig = .{},
    input: InputConfig = .{},
    quick_terminal: QuickTerminalConfig = .{},
    /// 셸에 줄 TERM 값. 셸 설정/통합이 $TERM에 따라 키바인딩(예: Ctrl+A 줄-시작)을 다르게 잡는
    /// 경우, 사용자가 자기 환경이 기대하는 값(예: xterm-ghostty)으로 바꿀 수 있다. 빈 값은 무시.
    term: []const u8 = "xterm-256color",
};
