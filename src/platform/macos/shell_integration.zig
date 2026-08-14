//! 셸 통합 — 터미널이 셸에 스크립트를 주입해 키바인딩 등을 셋업한다. Ghostty·iTerm2·kitty가 하는
//! 정식 기능으로, 사용자 셸 설정의 조건 분기(예: keymap이 vi/emacs로 갈리는 것)와 무관하게 macOS
//! 편집키(Cmd+←/→, Option+←/→ 등)가 동작하게 한다.
//!
//! 함께, OSC 133(semantic prompt) 마커도 emit해 프롬프트/입력/출력 경계를 터미널(TerminalCore)에
//! 알린다 — 거터 ✓/✗·프롬프트 점프·reflow 정확화의 토대다(명세: freedesktop semantic-prompts.md,
//! FinalTerm 발). 또 OSC 7로 매 프롬프트 cwd를 보고한다(창 제목·새 탭 cwd가 읽는다).
//!
//! 또 `ssh`를 셸 함수로 감싸 원격이 모르는 TERM이 새지 않게 한다(zsh 전용 — bash/fish 통합은 미구현):
//! (1) 기본 다운그레이드 — TERM이 maru 고유 `xterm-maru`면 ssh 호출에 한해 `xterm-256color`(표준값)로 낮춰
//! 항목 없는 원격에서 mux/TUI 커서·레이아웃이 깨지는 걸 막는다(Ghostty `ssh-env`와 같은 결, 항상 켜짐).
//! (2) opt-in 전파 — config `shell-integration.ssh = true`로 maru가 MARU_SSH_INTEGRATION/MARU_BIN을 주면
//! `ssh`를 `maru ssh`로 라우팅해 maru terminfo(`xterm-maru`)를 원격에 자동 전파한다. 근거·트레이드오프는
//! terminal-compatibility-policy.md.
//!
//! clean-room: Ghostty/kitty의 통합 스크립트는 GPLv3라 차용하지 않는다. 아래 zsh 스크립트는 zsh
//! 매뉴얼의 ZDOTDIR/스타트업·precmd/preexec/add-zsh-hook·PS1 `%{%}` 동작과 freedesktop
//! semantic-prompts.md 명세에서 직접 작성했다. 메커니즘(ZDOTDIR로 가리키기, precmd가 A/D·preexec가
//! C·PS1 끝이 B를 emit)은 공개 동작/명세다(Ghostty의 MIT setup 로직과 같은 아이디어). OSC 7도
//! VTE가 정의한 공개 형식(file://host/path)에서 직접 작성했다 — VTE의 vte.sh(GPL)는 열람하지
//! 않고, percent-encoding은 OSC 7 형식 명세대로 zsh에서 바이트 단위로 구현했다. ssh 라우팅(셸 함수로
//! `ssh`를 가려 터미널의 ssh 래퍼로 위임)은 공개 동작 아이디어로, Ghostty `ssh-integration`(GPLv3)은
//! 동작만 비교하고 zsh 함수·env 게이트는 직접 작성했다.

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
    \\  # OSC 7: 매 프롬프트 cwd 보고(VTE가 정의한 사실상 표준 — file://host/path, ECMA-48 아님).
    \\  # path를 percent-encode한다(unreserved 외 바이트 → %XX). 'emulate -L zsh'로 옵션을 지역화하고
    \\  # 'nomultibyte'로 바이트 단위 인덱싱해 UTF-8 path(한글 등)도 바이트별 인코딩 → 터미널 디코더가
    \\  # 정확히 복원한다. 종결자는 ST(ESC \).
    \\  #
    \\  # **authority(host)는 비워 보낸다** — `file://` + 경로 = `file:///path`, VTE 규약상 localhost다
    \\  # (docs/ssh-integration.md §9.2의 "로컬 판정" 첫 항목). 이 스크립트는 maru가 직접 spawn한 **로컬
    \\  # pty**에서만 로드되므로(원격 rc는 사용자가 별도 스니펫을 넣는다 — §9.5) 여기서 보고하는 cwd는
    \\  # 정의상 로컬이고, 그 사실을 hostname 문자열로 추측하게 만들 이유가 없다.
    \\  #
    \\  # 예전에는 ${HOST}를 실었는데, 그 값은 **셸이 시작한 시점**의 gethostname()이고 앱이 대조하는
    \\  # 로컬 이름은 **앱이 시작한 시점**의 gethostname()이다. macOS는 DHCP 도메인·Wi-Fi 전환·슬립 복귀로
    \\  # hostname의 접미가 바뀌므로(`box.local` ↔ `box.lan` ↔ `localhost`) 두 스냅샷이 어긋날 수 있고,
    \\  # hostIsLocal은 양쪽이 다 FQDN인데 전체가 다르면 **다른 호스트로 단정한다**(box.corp.com vs
    \\  # box.home.net을 막는 규율 — core.zig). 그러면 로컬 세션이 통째로 원격 취급돼 폴더줄에 `host:`
    \\  # 접두가 붙고 cwd 상속·링크 감지·git 저장소 조회가 전부 꺼진다(사용자 보고 2026-08-13: 소스 컨트롤
    \\  # 뷰가 로컬 저장소에 서 있는데 "git 저장소가 아닙니다"). 로컬 보고자가 로컬임을 명시하면 그 추측
    \\  # 자체가 사라진다. ssh로 들어가면 원격 스니펫이 ${HOST}를 실어 원격 판정은 그대로 동작한다.
    \\  #
    \\  # ⚠️ **이 함수를 원격 rc에 그대로 복사하지 말 것.** 원격 셸이 authority를 비우면 maru는 그 세션을
    \\  # 로컬로 읽고, 원격 경로를 로컬 파일시스템에 대고 해석한다 — 새 탭이 없는 디렉터리로 spawn하고
    \\  # 파일 경로 링크가 **로컬의 같은 경로**를 조용히 연다(§9.4가 막으려는 바로 그 결함). 원격용은
    \\  # 인코딩 규약만 가져가고 `file://${HOST}` 형태로 host를 반드시 실어야 한다(§9.5). 이 경고가
    \\  # 여기 있는 이유: ${HOST}를 싣던 동안에는 복사해도 원격 이름이 실려 안전했는데, 그 안전이
    \\  # 이 변경으로 사라졌다(적대적 검증에서 발견).
    \\  _maru_osc7() {
    \\    'builtin' 'emulate' '-L' 'zsh'
    \\    'builtin' 'setopt' 'nomultibyte'
    \\    'builtin' 'local' _maru_p="$PWD" _maru_enc="" _maru_hex _maru_i _maru_c
    \\    for (( _maru_i = 1; _maru_i <= ${#_maru_p}; _maru_i++ )); do
    \\      _maru_c="$_maru_p[_maru_i]"
    \\      case "$_maru_c" in
    \\        ([A-Za-z0-9/._~-]) _maru_enc+="$_maru_c" ;;
    \\        (*) 'builtin' 'printf' '-v' _maru_hex '%02X' "'$_maru_c"; _maru_enc+="%$_maru_hex" ;;
    \\      esac
    \\    done
    \\    'builtin' 'print' '-rn' -- $'\e]7;file://'"${_maru_enc}"$'\e\\'
    \\  }
    \\  # ssh 너머 TUI(claude/codex/tmux/vim)가 SIGKILL로 비정상 종료해 정리 시퀀스를 못 보낸 잔류
    \\  # 입력 모드를 매 프롬프트에서 끈다: focus(1004)·mouse(1000/1002/1003)·kitty keyboard 스택.
    \\  # 그러면 raw 셸에서 포커스/마우스마다 CSI I·좌표가 흘러나와 입력이 오염되는 증상이 다음
    \\  # 프롬프트에서 자동 회복된다. precmd는 프롬프트가 그려질 때(=풀스크린 TUI가 없을 때)만 돌아
    \\  # 정상 앱을 깨지 않는다. bracketed paste(2004)·app cursor(1)는 zle이 매 줄 직접 켜고 끄므로
    \\  # 제외한다. kitty pop은 스택 한도(16)만큼 보내 잔류 스택을 전부 비운다(빈 스택 pop은 no-op).
    \\  _maru_reset_input_modes() {
    \\    'builtin' 'print' '-rn' -- $'\e[?1004l\e[?1000l\e[?1002l\e[?1003l\e[<16u'
    \\  }
    \\  add-zsh-hook precmd _maru_osc133_precmd
    \\  add-zsh-hook preexec _maru_osc133_preexec
    \\  add-zsh-hook precmd _maru_osc133_ps1
    \\  add-zsh-hook precmd _maru_osc7
    \\  add-zsh-hook precmd _maru_reset_input_modes
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
    \\  # ssh 안전 처리: 평범한 `ssh`는 자식 env의 TERM(기본 xterm-maru)을 원격에 그대로 전달하지만 TERMINFO
    \\  # (로컬 env)는 안 따라가, 항목 없는 원격에선 mux/TUI가 커서·레이아웃을 깬다(terminal-compatibility-policy.md).
    \\  # 두 갈래로 막는다(우선순위 순):
    \\  #  (1) opt-in 전파(config `shell-integration.ssh = true` → maru가 MARU_SSH_INTEGRATION/MARU_BIN 주입):
    \\  #      `ssh`를 `maru ssh`로 라우팅해 원격에 xterm-maru terminfo를 심는다(설치 실패 시 maru ssh가 256color 폴백).
    \\  #  (2) 기본 다운그레이드(opt-in 미설정 + TERM이 maru 고유 `xterm-maru`): 그 ssh 호출에 한해 TERM을
    \\  #      xterm-256color(모든 원격이 가진 표준값)로 낮춰 커서/레이아웃 깨짐을 막는다(Ghostty `ssh-env`와 같은 결).
    \\  # TERM이 이미 xterm-256color 등(로컬 tic 폴백/사용자 override)이면 함수를 안 만들어 평범한 `ssh`가 그대로
    \\  # 동작한다(graceful). 둘 다 `maru ssh`(비대화형 /bin/sh exec)·`command ssh`로 실제 ssh를 불러 재귀하지
    \\  # 않는다. 명시 우회: `command ssh` 또는 절대경로 `/usr/bin/ssh`(함수는 `\ssh`로 안 풀린다 — alias 전용).
    \\  if [[ -n "${MARU_SSH_INTEGRATION+x}" && -n "${MARU_BIN}" && -x "${MARU_BIN}" ]]; then
    \\    ssh() { "${MARU_BIN}" ssh "$@"; }
    \\  elif [[ "$TERM" == "xterm-maru" ]]; then
    \\    ssh() { TERM=xterm-256color command ssh "$@"; }
    \\  fi
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

// 테스트에서 XDG_CACHE_HOME을 임시 디렉터리로 돌리기 위한 libc 바인딩(std.c 미노출 — macOS 전용 테스트).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "셸 통합: 파일이 사라져도 setupZsh가 다시 만든다(멱등)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // 사용자 캐시를 건드리지 않도록 XDG_CACHE_HOME을 임시 디렉터리로 돌린다.
    var tmp_buf: [128]u8 = undefined;
    const tmp = try std.fmt.bufPrintZ(&tmp_buf, "/tmp/maru-shellint-test-{d}", .{std.c.getpid()});
    const saved = std.c.getenv("XDG_CACHE_HOME");
    if (setenv("XDG_CACHE_HOME", tmp.ptr, 1) != 0) return error.SkipZigTest;
    defer {
        if (saved) |old| {
            _ = setenv("XDG_CACHE_HOME", old, 1);
        } else {
            _ = unsetenv("XDG_CACHE_HOME");
        }
    }

    const dir = setupZsh(io, allocator) orelse return error.SkipZigTest;
    defer allocator.free(dir);
    var path_buf: [256]u8 = undefined;
    const zshenv = try std.fmt.bufPrintZ(&path_buf, "{s}/.zshenv", .{dir});
    var dirz_buf: [256]u8 = undefined;
    const dirz = try std.fmt.bufPrintZ(&dirz_buf, "{s}", .{dir});
    defer {
        _ = std.c.unlink(zshenv.ptr);
        _ = std.c.rmdir(dirz.ptr);
    }

    // 처음 호출이 파일을 만든다.
    _ = std.Io.Dir.cwd().statFile(io, zshenv, .{}) catch return error.SkipZigTest;

    // 사용자가 캐시를 비운 상황 — 파일만 사라진다.
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlink(zshenv.ptr));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, zshenv, .{}));

    // 다시 부르면 복원돼야 한다. 이게 안 되면 새 탭이 **존재하지 않는 ZDOTDIR**을 받아 사용자의 `.zshrc`를
    // 통째로 건너뛴다 — PATH·자동완성·OSC 133이 전부 사라지는데 화면에는 아무 단서가 없다.
    const again = setupZsh(io, allocator) orelse return error.SkipZigTest;
    defer allocator.free(again);
    const stat = std.Io.Dir.cwd().statFile(io, zshenv, .{}) catch return error.SkipZigTest;
    try std.testing.expect(stat.size > 0);
    try std.testing.expectEqualStrings(dir, again); // 경로는 그대로여야 보관 중인 ZDOTDIR이 유효하다
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

test "zsh integration script resets stale input modes each prompt (ssh-kill recovery)" {
    // ssh 너머 TUI가 SIGKILL로 죽어 정리 못 한 focus·mouse·kitty 모드를 매 프롬프트에서 끄는지(회귀
    // 방지 — 깨지면 ssh 끊김 후 포커스마다 ^[[I·비프 증상이 되살아난다). ESC 바이트는 raw string에
    // literal `\e`로 들어가므로, 기존 OSC 테스트처럼 ESC 뒤 안정 바이트로 매칭한다.
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "add-zsh-hook precmd _maru_reset_input_modes") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "[?1004l") != null); // focus reporting off
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "[?1000l") != null); // mouse normal off
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "[?1002l") != null); // mouse button-event off
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "[?1003l") != null); // mouse any-event off
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "[<16u") != null); // kitty keyboard 스택 전체 pop
    // 충돌 회피: zle이 매 줄 직접 관리하는 bracketed paste(2004)는 리셋하지 않는다.
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "[?2004l") == null);
}

test "zsh integration script emits OSC 7 cwd reporting" {
    // 매 프롬프트 cwd를 보고하는 precmd 훅 + file:// 형식 + percent-encoding을 담는지(회귀 방지).
    // 실제 zsh가 공백/UTF-8 path를 어떻게 인코딩하는지는 PTY 캡처로 별도 검증했다(PR 본문에
    // `/a b/가` → `file://h/.../a%20b/%EA%B0%80` 캡처 인용).
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "add-zsh-hook precmd _maru_osc7") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "]7;file://") != null); // OSC 7 file 스킴
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "nomultibyte") != null); // 바이트 단위 인코딩
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "%02X") != null); // 비-unreserved 바이트 → %XX
    // **authority는 비어야 한다**(`file://` 바로 뒤에 경로). 로컬 pty 전용 스크립트라 보고하는 cwd는 정의상
    // 로컬이고, host를 실으면 그 값(셸 시작 시점 hostname)과 앱이 대조하는 이름(앱 시작 시점 hostname)이
    // 어긋날 때 로컬 세션이 원격으로 오판된다(§9.2 hostIsLocal의 FQDN 단정 — 그 회귀가 실제로 났다).
    //
    // **검사는 emit 줄에 건다.** 스크립트 전체에서 `${HOST}` 부재를 요구하면 그 결정을 설명하는 **주석까지**
    // 걸려(주석도 이 문자열의 일부다) 수정 상태에서도 빨간불이 된다 — 적대적 검증에서 실제로 그 착오를 냈다.
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "]7;file://'\"${_maru_enc}\"") != null); // file:///path
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "]7;file://'\"${HOST}") == null); // 옛 형태로 되돌아가지 않았다
}

test "zsh integration script routes ssh through maru ssh only when opt-in env is injected" {
    // opt-in: maru가 MARU_SSH_INTEGRATION/MARU_BIN을 주입할 때만 ssh 함수를 정의하는지(회귀 — 깨지면
    // 평범한 ssh가 라우팅되지 않거나, 반대로 항상 가려져 graceful이 무너진다). env 게이트(셋 모두)와
    // 함수 본문이 maru ssh로 위임하는지 확인. 실제 zsh가 함수로 ssh를 가리고 maru ssh로 위임하는지는
    // PTY/수동으로 별도 검증한다(PR 본문 — 단위로는 셸을 실행하지 않으므로).
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "MARU_SSH_INTEGRATION+x") != null); // opt-in 게이트(설정됨)
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "-x \"${MARU_BIN}\"") != null); // 바이너리 실행 가능할 때만
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "ssh() { \"${MARU_BIN}\" ssh \"$@\"; }") != null); // maru ssh로 위임
}

test "zsh integration script downgrades TERM to xterm-256color over plain ssh (default, xterm-maru only)" {
    // 기본 동작(opt-in 미설정): TERM이 maru 고유 xterm-maru면 평범한 ssh 호출을 xterm-256color로 다운그레이드해,
    // TERMINFO가 안 따라가는 원격에서 mux/TUI 커서·레이아웃이 깨지는 걸 막는다(회귀 — 깨지면 ssh+mux 커서가
    // 다시 엉뚱한 위치에 그려진다). 실제 zsh가 함수로 ssh를 가려 TERM을 낮추는지는 PTY/수동으로 별도 검증.
    // opt-in maru ssh 라우팅(위 테스트)보다 우선순위가 낮은 elif라, 둘이 배타적으로 한 갈래만 함수를 정의한다.
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "elif [[ \"$TERM\" == \"xterm-maru\" ]]; then") != null); // maru 고유 TERM일 때만
    try std.testing.expect(std.mem.indexOf(u8, zsh_zshenv, "ssh() { TERM=xterm-256color command ssh \"$@\"; }") != null); // 그 호출만 256color로 낮춰 실제 ssh
    // graceful: TERM이 폴백/override로 이미 xterm-256color 등이면 함수 자체를 안 만들어 평범한 ssh가 그대로 동작.
    // (xterm-maru 리터럴이 조건에만 쓰이고 무조건 ssh를 가리지 않음을 위 elif 가드가 보장.)
}
