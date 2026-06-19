pub const FontConfig = struct {
    family: []const u8 = "JetBrains Mono",
    size: f32 = 14,
    /// ⌘+/⌘-(increase/decrease_font_size)가 한 번에 바꾸는 폰트 크기 증분(pt). 기본 1.0. loader가 `font.size-step`
    /// 키로 파싱하고, 런타임 폰트 조절이 이 값을 쓴다(⌘0 reset은 size로 복귀 — step과 무관). 범위는 아래 const.
    size_step: f32 = 1.0,
};

/// font.size-step 허용 범위(단일 출처 — loader 파싱 검증과 appearance resolveFont 검증이 공유해 drift 방지).
/// 0/음수면 ⌘+/⌘-가 무동작/역방향이 되고, 너무 크면 한 번에 범위를 튄다.
pub const font_size_step_min: f32 = 0.1;
pub const font_size_step_max: f32 = 32.0;

pub const ThemeConfig = struct {
    background: []const u8 = "#101010",
    foreground: []const u8 = "#e8e8e8",
    cursor: []const u8 = "#ffffff",
    selection: []const u8 = "#334455",
    // 스크롤백 Find(⌘F) 매치 하이라이트 배경(#RRGGBB). search_match = 뷰 안 모든 매치, search_match_current
    // = 현재(네비게이션) 매치. selection(파랑 계열)과 구분되게 앰버 계열 기본값을 쓴다 — 현재 매치가 더 밝다.
    search_match: []const u8 = "#554a1a",
    search_match_current: []const u8 = "#997722",
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
/// left/right는 전고 + height_fraction 폭(가장자리에 수직인 '두께'에 비율이 적용된다). center는 가장자리가 없어
/// 화면 중앙에 가로=width_fraction(미설정이면 height_fraction)·세로=height_fraction 비율로 띄우고, 슬라이드
/// 대신 페이드 인 한다. 슬라이드/배치는 Swift.
pub const QuickTerminalPosition = enum {
    top,
    bottom,
    left,
    right,
    center,
};

/// quick terminal 패널의 chrome 수준. full=메인 창처럼 사이드바·탭 바를 다 보임, minimal=사이드바·탭 바 없이
/// 터미널 그리드만(드롭다운 스크래치 터미널의 보편 모습). 실제 chrome 억제는 그 세션 렌더(Zig)가 한다.
pub const QuickTerminalChrome = enum {
    full,
    minimal,
};

/// chrome(탭바·사이드바·divider·focus 테두리) 디자인 테마. tui=cell-grid 룩(현행), rich=분리 색 팔레트(C4a — tui가
/// sidebar_active로 공유하던 role을 파생색으로 분리; 둥근 모서리·그라데이션은 C4b 후속). 컴포넌트는 토큰셋만 바꿔
/// 소비(코드 불변 — 같은 ColorRole 읽음). platform buildChromeTokens가 tui()/rich()로 분기한다.
pub const ChromeTheme = enum {
    tui,
    rich,
};

/// quick terminal 표시 옵션. 값 검증/기본값은 loader가 채우고, 플랫폼(Swift)이 ABI로 받아 패널 크기·위치·
/// 화면·자동 숨김 동작에 쓴다.
pub const QuickTerminalConfig = struct {
    // 가장자리에 수직인 '두께' 비율(화면 visibleFrame 대비, 0.1~1.0). top/bottom이면 높이, left/right면 폭. 기본 0.45.
    // center는 세로 비율로도 쓴다(가로는 width_fraction).
    height_fraction: f32 = 0.45,
    // center 위치의 가로 비율(화면 대비, 0.1~1.0). center가 아니면 무시(top/bottom=전폭, left/right=height로 두께).
    // 기본 0(미설정) — center 가로를 height_fraction과 같게(정사각 비율, 기존 center 동작 보존). 설정하면 가로/세로 독립.
    width_fraction: f32 = 0,
    // 포커스를 잃으면(다른 창/앱 클릭) 자동으로 숨길지. 기본 true(quick terminal 표준 동작). false면 토글로만 숨김.
    auto_hide: bool = true,
    // 어느 화면에 띄울지.
    screen: QuickTerminalScreen = .main,
    // 화면 어느 가장자리에서 나올지.
    position: QuickTerminalPosition = .top,
    // chrome 수준(full=사이드바·탭 바 보임, minimal=터미널만). 기본 full.
    chrome: QuickTerminalChrome = .full,
    // minimal 모드에서 탭(워크스페이스·pane Term)을 만들 수 있게 할지. 기본 false — minimal은 단일 스크래치
    // 터미널이라 ⌘T(새 Term)·⌘⇧T(새 워크스페이스)를 무동작으로 막는다(사이드바·탭 바가 없어 안 보이는 탭
    // 생성을 차단; split은 divider로 보이므로 유지). true면 탭을 허용한다(파워유저용 — ⌘1..9/⌘]로만 전환).
    // full 모드는 이 값과 무관하게 탭이 항상 동작한다(chrome이 탭을 보여줌). 적용은 그 세션 dispatch(Zig)가 한다.
    minimal_tabs: bool = false,
};

pub const Config = struct {
    font: FontConfig = .{},
    theme: ThemeConfig = .{},
    cursor: CursorConfig = .{},
    input: InputConfig = .{},
    quick_terminal: QuickTerminalConfig = .{},
    /// chrome(탭바·사이드바·divider·테두리) 디자인 테마(tui|rich). 기본 tui(현행 cell-grid 룩). loader가 `chrome.theme` 키로 파싱.
    chrome_theme: ChromeTheme = .tui,
    /// SGR 5(blink) 글자를 실제로 깜빡일지(true)·정적으로 둘지(false). **기본 false** — 깜빡이는 콘텐츠는 접근성
    /// (WCAG 발작 위험) 우려라 다수 터미널이 기본으로 끈다. loader가 `text.blink` 키로 파싱.
    blink_text: bool = false,
    /// 터미널 셀과 컨테이너(사이드바·탭 바 안쪽) 가장자리 사이의 빈 여백(논리 pt, DPI로 스케일). x=좌우 각각,
    /// y=상하 각각. loader가 `window.padding-x`/`window.padding-y` 키로 파싱. 0이면 inset 없음(셀이 가장자리에 붙음).
    /// 베이스/결정: 콘텐츠 inset 자체는 흔한 관행이나 기본값은 터미널마다 달라 단일 표준이 없다(0~수 pt). maru는
    /// **8/4**를 택했다 — 가로를 세로보다 크게 둬(좌우 숨통) 모노스페이스 텍스트가 가장자리에 붙어 보이지 않게 하되,
    /// 세로는 작게 둬 가시 행 손실을 줄였다. 사용자가 config로 자유 조절. (docs/configuration.md·tabs-splits-layout.md)
    window_padding_x: u32 = 8,
    window_padding_y: u32 = 4,
    /// 셸에 줄 TERM 값. 셸 설정/통합이 $TERM에 따라 키바인딩(예: Ctrl+A 줄-시작)을 다르게 잡는
    /// 경우, 사용자가 자기 환경이 기대하는 값(예: xterm-ghostty)으로 바꿀 수 있다. 빈 값은 무시.
    term: []const u8 = "xterm-256color",
    /// 데스크톱 알림 설정. loader가 `notifications.*` 키로 파싱.
    notifications: NotificationConfig = .{},
    /// 스크롤백(가시 화면 위로 보관하는 과거 줄) 설정. loader가 `scrollback.*` 키로 파싱.
    scrollback: ScrollbackConfig = .{},
    /// 벨(BEL) 설정. loader가 `bell.*` 키로 파싱.
    bell: BellConfig = .{},
};

/// 데스크톱 알림 설정.
pub const NotificationConfig = struct {
    /// 터미널에서 도는 에이전트(claude/codex) 세션이 **비활성 탭/창**에서 완료(running→idle)될 때 macOS 알림을
    /// 띄울지. 기본 true — 다른 일을 보는 동안 끝났음을 알린다(활성 탭은 화면으로 이미 보이므로 안 띄움).
    /// loader가 `notifications.agent-complete` 키로 파싱.
    agent_complete: bool = true,
};

/// 스크롤백 설정.
pub const ScrollbackConfig = struct {
    /// 가시 화면 위로 보관할 과거 줄 수(ring). 0이면 스크롤백 비활성(과거 줄 안 보관). 기본 1000.
    /// loader가 `scrollback.lines` 키로 파싱(0~100000, 상한은 메모리 폭주 가드).
    lines: u32 = 1000,
};

/// 벨(BEL, 0x07) 설정.
pub const BellConfig = struct {
    /// BEL 수신 시 시스템 소리(NSSound.beep)를 낼지. 기본 true. false면 음소거(코어 플래그는 정상 소비).
    /// loader가 `bell.audible` 키로 파싱.
    audible: bool = true,
};
