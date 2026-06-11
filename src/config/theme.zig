pub const FontConfig = struct {
    family: []const u8 = "JetBrains Mono",
    size: f32 = 14,
};

pub const ThemeConfig = struct {
    background: []const u8 = "#101010",
    foreground: []const u8 = "#e8e8e8",
    cursor: []const u8 = "#ffffff",
    selection: []const u8 = "#334455",
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
    /// xterm/Ghostty 기본: 그대로 PTY로 `\e[5~`/`\e[6~`를 보낸다. 예측 가능하고 레퍼런스와 일치.
    /// 셸 기본 keymap이 unbound면 BEL+'~'가 입력줄에 박힐 수 있다(셸에서 bindkey로 해결).
    passthrough,
    /// Terminal.app/iTerm2식: 메인 화면에선 Maru 스크롤백을 한 페이지씩 스크롤한다.
    scroll,
};

pub const InputConfig = struct {
    page_keys: PageKeys = .passthrough,
};

pub const Config = struct {
    font: FontConfig = .{},
    theme: ThemeConfig = .{},
    cursor: CursorConfig = .{},
    input: InputConfig = .{},
    /// 셸에 줄 TERM 값. 셸 설정/통합이 $TERM에 따라 키바인딩(예: Ctrl+A 줄-시작)을 다르게 잡는
    /// 경우, 사용자가 자기 환경이 기대하는 값(예: xterm-ghostty)으로 바꿀 수 있다. 빈 값은 무시.
    term: []const u8 = "xterm-256color",
};
