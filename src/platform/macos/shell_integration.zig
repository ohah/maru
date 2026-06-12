//! 셸 통합 — 터미널이 셸에 스크립트를 주입해 키바인딩 등을 셋업한다. Ghostty·iTerm2·kitty가 하는
//! 정식 기능으로, 사용자 셸 설정의 조건 분기(예: keymap이 vi/emacs로 갈리는 것)와 무관하게 macOS
//! 편집키(Cmd+←/→, Option+←/→ 등)가 동작하게 한다.
//!
//! 함께, OSC 133(semantic prompt) 마커도 emit해 프롬프트/입력/출력 경계를 터미널(TerminalCore)에
//! 알린다 — 거터 ✓/✗·프롬프트 점프·reflow 정확화·cwd 추적의 토대다(명세: freedesktop
//! semantic-prompts.md, FinalTerm 발).
//!
//! clean-room: Ghostty/kitty의 통합 스크립트는 GPLv3라 차용하지 않는다. 아래 zsh 스크립트는 zsh
//! 매뉴얼의 ZDOTDIR/스타트업·precmd/preexec/add-zsh-hook·PS1 `%{%}` 동작과 freedesktop
//! semantic-prompts.md 명세에서 직접 작성했다. 메커니즘(ZDOTDIR로 가리키기, precmd가 A/D·preexec가
//! C·PS1 끝이 B를 emit)은 공개 동작/명세다(Ghostty의 MIT setup 로직과 같은 아이디어).

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
    \\  # OSC 133 semantic prompt 마킹(freedesktop semantic-prompts.md). 두 precmd 훅으로 나눈다 —
    \\  # 직전 $? 캡처·D·A는 '맨 앞' 훅이(.zshenv가 사용자 .zshrc보다 먼저 실행돼 precmd_functions 선두라
    \\  # 직전 $?를 정확히 잡음), 입력 시작 B(PS1 끝)는 '맨 뒤' 훅이 처리한다. preexec=출력 시작(C).
    \\  _maru_osc133_precmd() {
    \\    'builtin' 'local' _maru_st=$?
    \\    if [[ -n "${_maru_osc133_started+x}" ]]; then
    \\      'builtin' 'print' '-rn' -- $'\e]133;D;'"$_maru_st"$'\a'
    \\    fi
    \\    'builtin' 'typeset' '-g' '_maru_osc133_started=1'
    \\    'builtin' 'print' '-rn' -- $'\e]133;A\a'
    \\  }
    \\  _maru_osc133_preexec() {
    \\    'builtin' 'print' '-rn' -- $'\e]133;C\a'
    \\  }
    \\  # B는 PS1 끝에 둔다. p10k/starship/oh-my-zsh 등이 '자기 precmd에서 PS1을 통째로 재생성'해도
    \\  # B가 살아남도록, 매 프롬프트 자신을 precmd_functions '맨 뒤'로 재정렬한 뒤(프레임워크 재생성
    \\  # '후'에 실행되게) append한다. 안 그러면 B가 매 프롬프트 제거돼 입력 영역이 마킹되지 않는다.
    \\  _maru_osc133_ps1() {
    \\    [[ "${precmd_functions[-1]}" = _maru_osc133_ps1 ]] || precmd_functions=( "${(@)precmd_functions:#_maru_osc133_ps1}" _maru_osc133_ps1 )
    \\    [[ "$PS1" == *$'\e]133;B'* ]] || PS1="$PS1"$'%{\e]133;B\a%}'
    \\  }
    \\  add-zsh-hook precmd _maru_osc133_precmd
    \\  add-zsh-hook preexec _maru_osc133_preexec
    \\  add-zsh-hook precmd _maru_osc133_ps1
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

test "zsh integration script emits OSC 133 semantic prompt markers" {
    // 두 precmd 훅(D/A 맨 앞, B 맨 뒤) + preexec C를 담는지(회귀 — 깨지면 분류가 조용히 멈춘다).
    // 실제 zsh emit 순서/종료코드/프레임워크 PS1 생존은 PTY 캡처로 별도 검증했다(PR 본문).
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "add-zsh-hook precmd _maru_osc133_precmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "add-zsh-hook preexec _maru_osc133_preexec") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "add-zsh-hook precmd _maru_osc133_ps1") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "133;A") != null); // 프롬프트 시작
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "133;D;") != null); // 명령 끝 + 종료코드
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "133;C") != null); // 출력 시작
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "133;B") != null); // 입력 시작(PS1 끝)
    // 직전 $?를 가장 먼저 캡처해야 정확한 종료코드를 보낸다(precmd 첫 줄).
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "local' _maru_st=$?") != null);
    // B 훅이 프레임워크 PS1 재생성에도 살아남도록 precmd_functions 맨 뒤로 재정렬하는지(회귀 방지).
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "precmd_functions[-1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "${(@)precmd_functions:#_maru_osc133_ps1}") != null);
}
