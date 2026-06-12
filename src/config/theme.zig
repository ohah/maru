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

pub const Config = struct {
    font: FontConfig = .{},
    theme: ThemeConfig = .{},
    cursor: CursorConfig = .{},
    input: InputConfig = .{},
    /// 셸에 줄 TERM 값. 셸 설정/통합이 $TERM에 따라 키바인딩(예: Ctrl+A 줄-시작)을 다르게 잡는
    /// 경우, 사용자가 자기 환경이 기대하는 값(예: xterm-ghostty)으로 바꿀 수 있다. 빈 값은 무시.
    term: []const u8 = "xterm-256color",
};
