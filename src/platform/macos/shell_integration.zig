//! 셸 통합 — 터미널이 셸에 스크립트를 주입해 키바인딩 등을 셋업한다. Ghostty·iTerm2·kitty가 하는
//! 정식 기능으로, 사용자 셸 설정의 조건 분기(예: keymap이 vi/emacs로 갈리는 것)와 무관하게 macOS
//! 편집키(Cmd+←/→, Option+←/→ 등)가 동작하게 한다.
//!
//! clean-room: Ghostty/kitty의 통합 스크립트는 GPLv3라 차용하지 않는다. 아래 zsh 스크립트는 zsh
//! 매뉴얼의 ZDOTDIR/스타트업 파일 동작에서 직접 작성했다. ZDOTDIR로 통합 디렉터리를 가리키는
//! 메커니즘 자체는 zsh 공개 동작이다(Ghostty의 MIT setup 로직과 같은 아이디어).

const std = @import("std");

/// 셸 종류(통합 방식이 셸마다 다르다). 지금은 zsh만 구현하고, 그 외는 통합 없이 그대로 띄운다.
pub const Shell = enum { zsh, other };

/// 셸 경로(예: /bin/zsh)의 basename으로 종류를 판정한다.
pub fn detect(shell_path: []const u8) Shell {
    const base = std.fs.path.basename(shell_path);
    if (std.mem.eql(u8, base, "zsh")) return .zsh;
    return .other;
}

// Maru zsh 통합 .zshenv. zsh가 ZDOTDIR=<이 디렉터리>일 때 가장 먼저 source한다. 사용자 ZDOTDIR을
// 복원해 사용자의 .zprofile/.zshrc/.zlogin이 정상 로드되게 하고, 사용자 인터랙티브 설정(.zshrc)이
// 끝난 '뒤'(첫 프롬프트의 precmd 1회 훅)에 macOS 편집키를 바인딩한다 — keymap이 vi로 기본 선택돼도
// ($EDITOR=nvim 등) Cmd+←/→ 등이 동작하도록. bindkey -e(전체 emacs 강제)가 아니라 Maru가 보내는
// 키만 표준 위젯에 바인딩해 덜 침습적으로 둔다(vi 사용자의 나머지 바인딩 보존).
const zsh_zshenv =
    \\# Maru shell integration (zsh). ZDOTDIR을 통해 자동 source되며, 수동 source용이 아니다.
    \\# alias 확장을 피하려 builtin을 명시한다.
    \\if [[ -n "${MARU_ZDOTDIR_PREV+x}" ]]; then
    \\  'builtin' 'export' ZDOTDIR="$MARU_ZDOTDIR_PREV"
    \\  'builtin' 'unset' 'MARU_ZDOTDIR_PREV'
    \\else
    \\  'builtin' 'unset' 'ZDOTDIR'
    \\fi
    \\# 사용자의 .zshenv를 먼저 읽는다(unset ZDOTDIR는 $HOME로 취급 — zsh 규칙).
    \\() {
    \\  'builtin' 'local' _maru_d="${ZDOTDIR:-$HOME}"
    \\  [[ -r "$_maru_d/.zshenv" ]] && 'builtin' 'source' '--' "$_maru_d/.zshenv"
    \\}
    \\if [[ -o 'interactive' ]]; then
    \\  'builtin' 'autoload' '-Uz' 'add-zsh-hook'
    \\  _maru_shell_integration() {
    \\    add-zsh-hook -d precmd _maru_shell_integration
    \\    # macOS 편집키가 보내는 C0/meta 시퀀스를 표준 라인 위젯에 바인딩(현재 main keymap에).
    \\    'builtin' 'bindkey' '^A' beginning-of-line       # Cmd+Left
    \\    'builtin' 'bindkey' '^E' end-of-line             # Cmd+Right
    \\    'builtin' 'bindkey' '^U' backward-kill-line      # Cmd+Backspace
    \\    'builtin' 'bindkey' '^[b' backward-word          # Option+Left
    \\    'builtin' 'bindkey' '^[f' forward-word           # Option+Right
    \\    'builtin' 'bindkey' '^[^?' backward-kill-word    # Option+Backspace
    \\    'builtin' 'unfunction' '_maru_shell_integration'
    \\  }
    \\  add-zsh-hook precmd _maru_shell_integration
    \\fi
;

/// zsh 통합을 준비한다 — .zshenv를 캐시 디렉터리에 쓰고 그 디렉터리 경로를 돌려준다(호출자 소유).
/// 이 경로를 ZDOTDIR로 셸에 주면(SpawnRequest.zdotdir → EnvStorage) zsh가 위 스크립트를 로드한다.
/// 어떤 단계든 실패하면 null을 돌려준다(통합 없이 셸은 정상 동작 — graceful).
pub fn setupZsh(io: std.Io, allocator: std.mem.Allocator) ?[]const u8 {
    const dir = cacheDirZsh(allocator) catch return null;
    errdefer allocator.free(dir);

    std.Io.Dir.cwd().createDirPath(io, dir) catch return null;

    const zshenv_path = std.fmt.allocPrint(allocator, "{s}/.zshenv", .{dir}) catch return null;
    defer allocator.free(zshenv_path);
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = zshenv_path,
        .data = zsh_zshenv,
        .flags = .{ .truncate = true },
    }) catch return null;

    return dir;
}

/// `<XDG_CACHE_HOME 또는 $HOME/.cache>/maru/shell-integration/zsh`.
fn cacheDirZsh(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_CACHE_HOME")) |x| {
        const base = std.mem.span(x);
        if (base.len > 0) return std.fmt.allocPrint(allocator, "{s}/maru/shell-integration/zsh", .{base});
    }
    const home_raw = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.span(home_raw);
    if (home.len == 0) return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.cache/maru/shell-integration/zsh", .{home});
}

test "detect zsh by basename" {
    try std.testing.expectEqual(Shell.zsh, detect("/bin/zsh"));
    try std.testing.expectEqual(Shell.zsh, detect("/opt/homebrew/bin/zsh"));
    try std.testing.expectEqual(Shell.other, detect("/bin/bash"));
    try std.testing.expectEqual(Shell.other, detect("/bin/sh"));
}

test "zsh integration script binds the macOS editing keys and restores ZDOTDIR" {
    // 스크립트가 핵심 요소를 담는지(회귀 — 깨지면 통합이 조용히 무력화될 수 있다).
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "MARU_ZDOTDIR_PREV") != null); // 복원
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "add-zsh-hook precmd") != null); // .zshrc 후 실행
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "'^A' beginning-of-line") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "'^E' end-of-line") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "'^[b' backward-word") != null);
}
