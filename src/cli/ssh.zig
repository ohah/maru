//! `maru ssh` 서브커맨드의 순수 로직 — 인자 파싱, 셸 스크립트, exec argv 조립.
//!
//! 무엇을 하나: `maru ssh <ssh args...>`는 원격에 maru terminfo(`xterm-maru`)를 먼저 심은 뒤
//! 평범한 `ssh`로 넘어간다(exec). 그러면 원격 tmux/vim이 maru 캡(특히 동기화 출력 Sync)을 인식해
//! tmux+SSH 레이아웃 플리커가 사라진다. 사용자의 평소 `ssh`는 건드리지 않는다 — `maru ssh`라고
//! 명시할 때만 동작하는 opt-in 래퍼다.
//!
//! 왜 이 형태인가(clean-room): 원격 전파의 요구사항은 단순하다 — "원격에 terminfo가 없으면 깨지니,
//! 세션 전에 원격에 설치하고, 못 하면 안전 폴백한다". 그 요구에서 직접 유도한 구성이다(아래
//! `remote_install` 주석에 세 단계 유도 근거). Ghostty `ghostty +ssh`(MIT)도 같은 문제를 비슷하게
//! 푸는 것을 동작 비교로 확인했지만, 셸 구절·idiom(`if/then/fi`·`$HOME`·`tic -o`·`env TERM=`)은 maru가
//! 독립 작성했다 — 레퍼런스 코드 표현 미복사(docs/project-rules.md, docs/references.md clean-room).
//!
//! 이 모듈은 std만 의존하는 순수 로직이라 단위 테스트로 동작을 못박는다. 실제 프로세스 exec(I/O)는
//! main.zig가 맡고, 원격 연결 검증은 opt-in `ssh localhost` smoke가 맡는다.
//!
//! 의도적으로 뺀 것(후속): 캐시 관리 서브커맨드(Ghostty `+ssh-cache` list/clear 대응 — 지금은 캐시
//! 파일을 지워 비운다). 호스트 설치 캐시·terminfo 소스 embed(자기완결)·단일 연결(ControlMaster)·원격
//! command 안전 처리(bootstrapEligible)는 했다.

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// 원격에서 도는 terminfo 부트스트랩. `ssh`에 작은따옴표로 그대로 넘긴다(내부에 작은따옴표 없음).
/// 요구사항에서 직접 유도한 세 단계다: (1) `xterm-maru`가 이미 해석되면 더 할 일 없음(즉시 성공),
/// (2) 원격에 `tic`이 없으면 설치 불가이므로 실패시켜 호출 측이 안전 폴백하게 하고, (3) 아니면 로컬에서
/// 파이프된 terminfo 소스를 원격 사용자 디렉터리에 컴파일한다. `tic -o`는 대상 디렉터리를 알아서
/// 만들어 주므로 별도 `mkdir`가 필요 없다(실측 확인). `~` 대신 `$HOME`을 써 셸 의존을 줄인다. 베이스:
/// terminfo `tic`(공개 도구) 동작. Ghostty `ghostty +ssh`는 같은 목적의 동작 비교 참고일 뿐, 위 구절은
/// 요구사항에서 독립적으로 구성했다(코드 미복사 — docs/project-rules.md clean-room).
pub const remote_install =
    "if infocmp xterm-maru >/dev/null 2>&1; then exit 0; fi; " ++
    "command -v tic >/dev/null 2>&1 || exit 1; " ++
    "tic -x -o \"$HOME/.terminfo\" - 2>/dev/null";

/// xterm-maru terminfo 소스를 바이너리에 embed한다. 이게 핵심 — `maru ssh`가 **자기완결적**이 된다:
/// 예전엔 로컬 `infocmp -x xterm-maru`로 소스를 떠서(= `mise run install-terminfo`를 먼저 해야 함)
/// 원격에 파이프했지만, 이제 embed한 소스를 그대로 흘린다. 로컬 설치 없이도 원격 전파가 되고,
/// 로컬/원격 terminfo 버전이 항상 일치한다. 베이스: terminfo 소스 파일(공개 포맷). 단일 신원 출처는
/// `terminfo/maru.terminfo` 하나다(중복 없음).
pub const embedded_terminfo = @embedFile("maru_terminfo");

// 인라인 안전 가드: embed 소스를 `printf '%s' '<소스>'`로 single-quoted 셸 리터럴에 그대로 넣으므로,
// 소스에 작은따옴표가 생기면 셸 인용이 깨진다. 그때 빌드를 실패시켜(escape 추가하거나 따옴표 제거하라고)
// 런타임에 조용히 깨지는 걸 막는다.
comptime {
    @setEvalBranchQuota(embedded_terminfo.len + 100); // 소스 바이트 수만큼 comptime 루프 분기가 필요
    for (embedded_terminfo) |c| {
        // 이 문장은 **개발자에게 하는 말**이라 한국어로 둔다 — 계약 §7.1 이 영어로 고정한 것은
        // 사용자가 보는 CLI 출력이고, `@compileError` 는 빌드가 멈출 때 기여자가 읽는다.
        if (c == '\'') @compileError("terminfo/maru.terminfo에 작은따옴표(')가 생겼다 — maru ssh의 single-quoted 인라인이 깨진다. 따옴표를 빼거나 escape 로직을 추가하라.");
    }
}

/// embed한 terminfo 소스를 stdout으로 내보내는 셸 구절. `infocmp -x xterm-maru`(로컬 설치 의존)를 대체한다.
/// `printf '%s'`는 인자의 `%`·`\`를 해석하지 않아(format이 아니라 data) 소스의 `\E`·`%p1` 등이 그대로
/// 나간다. 소스를 single-quote로 감싸 셸 확장도 막는다(위 comptime 가드가 작은따옴표 부재를 보장).
const emit_terminfo = "printf '%s' '" ++ embedded_terminfo ++ "'";

/// ssh 값 옵션 letter set — 이 옵션 바로 다음 토큰은 옵션의 값이지 목적지가 아니다(ssh(1) 기준).
/// bootstrapEligible이 목적지(첫 비옵션 토큰)를 찾을 때 값 토큰을 건너뛰는 데 쓴다.
const ssh_value_opts = "bcDEeFIiJLlmOopQRSWw";

/// 설치 캐시 파일 경로 구절. 목적지(한 줄에 하나)를 기록해, 같은 목적지 재접속 시 설치를 건너뛴다.
/// `$XDG_CACHE_HOME` 우선, 없으면 `~/.cache`. 비우려면 이 파일을 지운다(아래 docs). 셸이 읽고 쓴다.
const cache_path = "${XDG_CACHE_HOME:-$HOME/.cache}/maru/ssh-terminfo-hosts";

/// notify 이후 foreground ssh가 정상 종료하거나 HUP/INT/TERM으로 끊겨도 `ssh-end`를 정확히 한 번 보내는 shell lifecycle.
/// signal trap과 EXIT trap이 경합하지 않도록 cleanup이 먼저 모든 trap을 해제한다. 정상 ssh exit code와 관례적 signal code를
/// 보존한다. 함수는 wrapper의 `notify`/`clear_notify` 정의 뒤에 붙는다.
///
/// **`end_notify`가 `cleanup_notify`에서 분리된 이유**: 재접속 루프(§`session_loop`)는 세션이 죽을 때마다
/// 통지를 걷어야 하는데, 그때는 **셸이 끝나면 안 된다**. 예전에는 걷는 일과 끝내는 일이 한 함수에 붙어
/// 있어서 루프에서 쓸 수 없었다 — 걷는 쪽만 떼어 두 호출자(루프·trap)가 같은 "정확히 한 번" 규율을 공유한다.
const notify_lifecycle =
    "remote_active=0; " ++
    "end_notify() { if [ \"$remote_active\" = 1 ]; then remote_active=0; clear_notify; fi; }; " ++
    "cleanup_notify() { rc=\"$1\"; trap - EXIT HUP INT TERM; end_notify; exit \"$rc\"; }; " ++
    "begin_notify() { remote_active=1; trap 'cleanup_notify $?' EXIT; trap 'cleanup_notify 129' HUP; trap 'cleanup_notify 130' INT; trap 'cleanup_notify 143' TERM; notify; }; ";

/// 세션 하나를 돌리고, **끊기면 다시 붙는** 루프. 전략 근거는 docs/ssh-integration.md §10.
///
/// 호출 규약: ssh 인자를 `"$@"`로 받고, 나머지는 스크립트 전역이 정한다 — `tv`(원격에 실을 TERM),
/// `nf`(1이면 OSC 통지), `cmode`(1=ControlMaster+Path, 2=Path만, 0=control socket 없음), `ka`(keepalive
/// `-o` 구절), `rcon`(1이면 재접속). **POSIX sh에 배열이 없어** ssh 인자만 위치 인자로 남기고 나머지를
/// 전역으로 뺐다 — 전역에 담으면 `-o ControlPath=$ctl`의 인용이 깨져(HOME에 공백이 있는 macOS 계정에서
/// 실제로 깨진다) 세 갈래를 `case`로 펼쳐 각 자리에서 `"$ctl"`을 인용한다.
///
/// **재시도 판정은 exit 255 하나다.** ssh(1)가 자기 오류(연결 실패·끊김)에 쓰는 코드이고, 원격 프로그램의
/// 종료 코드는 그대로 흘려보내야 한다 — 원격 셸의 `exit 3`을 끊김으로 읽으면 사용자가 끝낸 세션이 되살아난다.
///
/// **접속 자체가 안 되는 것과 끊긴 것을 시간으로 가른다.** 호스트 오타·방화벽이면 ssh가 곧바로 255로
/// 죽는데, 그것을 끊김으로 보면 **영원히 재시도한다**. 2초를 못 넘긴 세션이 3번 연속이면 포기한다
/// (`date +%s`가 없는 환경에서는 t0이 0이라 이 판정을 건너뛴다 — 그때는 사용자가 Ctrl-C로 끊는다).
///
/// **시각은 숫자인지 검사하고 쓴다.** `date`가 숫자가 아닌 것을 내면(`+%s`를 모르는 구현이 인자를 그대로
/// 되돌리는 경우) `$((t1 - t0))`이 **문법 오류로 셸을 그 자리에서 죽인다** — 적대적 검증에서 실제로 그렇게
/// 죽었고, 증상은 "끊긴 직후 재접속도 못 하고 이상한 오류만 남는다"였다. `date`는 사용자 PATH에서 오므로
/// 그 출력은 우리가 정하는 값이 아니다. 숫자가 아니면 0으로 접어 시간 판정만 건너뛴다(재시도는 계속된다).
///
/// 백오프는 1→2→4→8→16→30초로 늘고 30초에서 멈춘다. 세션이 2초 넘게 살았으면 1초로 되돌린다 —
/// 자리를 옮기며 여러 번 끊기는 이동 중에 대기가 계속 길어지지 않게 한다.
const session_loop =
    // 대기: bash(= macOS의 `/bin/sh`)이고 stdin이 tty면 `read -t`로 기다려 **Enter로 즉시 건너뛸 수 있게**
    // 한다. dash 등 `read -t`가 없는 셸에서는 `sleep`으로 같은 시간을 기다린다(기능 축소일 뿐 동작은 같다).
    // tty가 아니면(파이프) `read`가 즉시 EOF로 돌아와 대기가 사라지므로 그 경우도 `sleep`으로 보낸다.
    "wait_retry() { if [ -n \"$BASH_VERSION\" ] && [ -t 0 ]; then read -t \"$1\" -r _skip 2>/dev/null || :; else sleep \"$1\"; fi; }; " ++
    "run() { attempt=1; delay=1; short=0; while :; do " ++
    "[ \"$nf\" = 1 ] && begin_notify; " ++
    "t0=$(date +%s 2>/dev/null || printf 0); case \"$t0\" in ''|*[!0-9]*) t0=0 ;; esac; " ++
    "case \"$cmode\" in " ++
    "1) env TERM=\"$tv\" COLORTERM=truecolor ssh $ka -o SendEnv=COLORTERM -o ControlMaster=auto -o ControlPath=\"$ctl\" \"$@\" ;; " ++
    "2) env TERM=\"$tv\" COLORTERM=truecolor ssh $ka -o SendEnv=COLORTERM -o ControlPath=\"$ctl\" \"$@\" ;; " ++
    "*) env TERM=\"$tv\" COLORTERM=truecolor ssh $ka -o SendEnv=COLORTERM \"$@\" ;; " ++
    "esac; rc=$?; end_notify; " ++
    "[ \"$rcon\" = 1 ] || return \"$rc\"; " ++
    "[ \"$rc\" = 255 ] || return \"$rc\"; " ++
    "t1=$(date +%s 2>/dev/null || printf 0); case \"$t1\" in ''|*[!0-9]*) t1=0 ;; esac; " ++
    "if [ \"$t0\" != 0 ] && [ \"$t1\" != 0 ] && [ $((t1 - t0)) -lt 2 ]; then short=$((short + 1)); else short=0; delay=1; fi; " ++
    "if [ \"$short\" -ge 3 ]; then printf 'maru ssh: cannot reach %s -- giving up after %s attempts\\n' \"$dest\" \"$attempt\" >&2; return \"$rc\"; fi; " ++
    "printf 'maru ssh: connection to %s lost (ssh exit 255)\\n' \"$dest\" >&2; " ++
    "printf 'maru ssh: reconnecting in %ss (attempt %s) -- Enter: now, Ctrl-C: cancel\\n' \"$delay\" \"$attempt\" >&2; " ++
    "wait_retry \"$delay\"; " ++
    "delay=$((delay * 2)); [ \"$delay\" -gt 30 ] && delay=30; " ++
    "attempt=$((attempt + 1)); " ++
    "done; }; ";

/// 전체 래퍼 스크립트(`/bin/sh -c <script> sh <elig> <dest> <ctl> <ssh args...>`로 실행). `$1`=bootstrap
/// 적격 플래그("1"/"0"), `$2`=목적지(캐시 키), `$3`=control socket 경로(빈 문자열이면 미사용), 나머지
/// `"$@"`=ssh 인자. `$ctl`이 있으면 디렉터리를 만들고(`mkdir -p`) ssh `ControlPath`로 쓴다 — 드롭 파일
/// 업로드가 이 socket으로 가는 사이드채널(docs/ssh-integration.md §4)의 토대다.
///
/// 또한 control socket이 살아있는 maru 경로(캐시 hit·부트스트랩 성공) 직전에 `notify`가 OSC 5379
/// `ssh;<dest>`를 emit해(tmux 안이면 `$TMUX` 감지 후 DCS passthrough로 감쌈) Maru에 "이 세션은 maru ssh
/// 원격, 목적지=dest"임을 알린다 — Maru가 dest로 control socket 경로를 계산해 드롭 업로드 대상으로 쓴다
/// (docs/ssh-integration.md §4, 2단계). ssh가 끝나면 `clear_notify`가 `ssh-end`를 emit하고 원래 exit code를
/// 보존해 로컬 shell의 drop이 끝난 원격 destination을 재사용하지 않게 한다. ctl 없는 폴백 경로는 socket이 없어 통지하지 않는다.
///
/// **캐시 hit**(이 목적지에 이미 설치 기록 있음): bootstrap을 통째로 건너뛰되, `$ctl`이 있으면
/// `ControlMaster=auto`로 **control socket을 유지하며** `TERM=xterm-maru`로 exec한다(이전엔 캐시 hit
/// 경로에 socket이 없어 재접속 세션엔 사이드채널이 없었다). 매 접속 설치 round-trip은 그대로 없앤다
/// (Ghostty `+ssh-cache`식). 캐시는 셸이 grep으로 읽는다.
///
/// 캐시 miss + 적격("$1"=1: 원격 command 없는 순수 세션): **ControlMaster 단일 연결** 안에서 embed한
/// terminfo 소스를 원격에 심고 같은 연결로 세션을 exec한다 — 부트스트랩 ssh가 master가 되고 세션 ssh가
/// 그 소켓을 재사용해 **인증이 한 번**만 일어난다(리뷰 #3). 설치 **성공 시 목적지를 캐시에 기록**하고
/// `TERM=xterm-maru`, 실패 시 `xterm-256color` 폴백.
///
/// 부적격("$1"=0: 원격 command가 붙었거나 파싱 불확실)이면 bootstrap을 건너뛰고 `xterm-256color`로
/// 그냥 exec한다 — 사용자 command가 두 번 실행되는 위험(리뷰 #2)을 피한다.
///
/// TERM은 `env`로 실어 보낸다 — `-o SetEnv`는 OpenSSH 7.8+ 전용 회귀(리뷰 #4)라 안 쓴다.
///
/// **COLORTERM 은 `-o SendEnv=COLORTERM` 으로 보낸다.** ssh 가 원격에 전달하는 환경변수는 `TERM` 뿐이라
/// `env` 로 세운 값은 로컬 ssh 프로세스에만 남는다. 그래서 terminfo 를 읽지 않고 `TERM` 문자열 패턴과
/// `COLORTERM` 만 보는 앱(Node 계열 다수)이 `xterm-maru` 를 모르는 이름으로 취급해 **16색으로 떨어졌다**.
/// tmux 안에서는 tmux 가 자기 `screen-256color` 를 세워 256색으로 승격되므로 "tmux 밖에서만 색이 죽는"
/// 증상이었다(사용자 보고 2026-08-18).
///
/// **왜 SetEnv 가 아니라 SendEnv 인가**(적대적 검증 2026-08-18, `ssh -G` 실측):
///  - `SetEnv` 는 first-wins 다. 커맨드라인에 하나 주면 사용자 `~/.ssh/config` 의 `SetEnv` 가 **통째로
///    사라진다**(`SetEnv FOO=bar` + `-o SetEnv=COLORTERM=truecolor` → `setenv COLORTERM` 만 남았다).
///    `-o SetEnv` 를 두 번 줘도 첫 것만 산다.
///  - `SendEnv` 는 목록에 **누적**되고(`sendenv COLORTERM` + 사용자 `sendenv LANG` 공존) 사용자 `SetEnv` 도
///    건드리지 않는다. 게다가 OpenSSH 3.9 부터 있어 **버전 프리플라이트가 불필요**하다(SetEnv 는 7.8+ 라
///    구버전에서 연결이 깨져 `-V` 선검증이 필요했다).
///  - 보낼 값은 `env COLORTERM=truecolor` 로 명시한다 — SendEnv 는 *로컬 환경의 값*을 보내므로, 로컬에
///    그 값이 있다고 가정하지 않는다.
///
/// **서버 협조에 달린 보조 수단이다.** sshd 가 `AcceptEnv` 로 허용하지 않으면 조용히 버려진다(배포판
/// 기본값은 대개 `LANG LC_*`). 허용하는 호스트에서는 원격 셸 실행 방식을 건드리지 않고 색이 돌아오고,
/// 아닌 호스트에서는 지금과 같다.
pub const wrapper_script =
    "elig=\"$1\"; dest=\"$2\"; ctl=\"$3\"; alive=\"$4\"; amax=\"$5\"; rcon=\"$6\"; shift 6; cache=\"" ++ cache_path ++ "\"; " ++
    "[ -n \"$ctl\" ] && mkdir -p \"${ctl%/*}\" 2>/dev/null; " ++
    // keepalive는 **값이 0이면 아예 안 붙인다**. ssh는 커맨드라인 `-o`가 설정 파일보다 우선이라, 항상
    // 붙이면 사용자가 `~/.ssh/config`에 적어 둔 ServerAlive* 를 말없이 덮는다(`ssh -G` 실측 규칙과 같은 결).
    // `$ka`만 인용 없이 확장하는 것은 의도다 — 두 `-o` 쌍으로 **단어 분리**되어야 하고, 값은 config가
    // 정수 범위로 검증해 넣으므로 분리로 깨질 글자가 들어올 수 없다.
    "ka=\"\"; [ \"$alive\" != 0 ] && ka=\"-o ServerAliveInterval=$alive -o ServerAliveCountMax=$amax\"; " ++
    // 원격 command가 붙은 호출(`maru ssh host ls`)은 **재접속 대상이 아니다**. 그 명령을 자동으로 다시
    // 실행하면 부작용 있는 명령이 두 번 도는데, 사용자가 요청한 것은 한 번이다. 대화형 세션만 다시 붙는다.
    "[ \"$elig\" = 1 ] || rcon=0; " ++
    // notify: maru exec 직전 OSC 5379(ssh;<dest>)로 원격 세션을 Maru에 알린다. tmux 안($TMUX)이면 DCS
    // passthrough(ESC P tmux; <inner의 ESC를 doubled> ESC \\)로 감싸 tmux를 통과시킨다. raw inner는
    // ESC ] 5379 ; ssh ; <dest> BEL. dest는 printf '%s'라 format 해석 없이 그대로 들어간다.
    "notify() { if [ -n \"$TMUX\" ]; then printf '\\033Ptmux;\\033\\033]5379;ssh;%s\\007\\033\\\\' \"$dest\"; else printf '\\033]5379;ssh;%s\\007' \"$dest\"; fi; }; " ++
    "clear_notify() { if [ -n \"$TMUX\" ]; then printf '\\033Ptmux;\\033\\033]5379;ssh-end\\007\\033\\\\'; else printf '\\033]5379;ssh-end\\007'; fi; }; " ++
    notify_lifecycle ++
    session_loop ++
    "if [ -n \"$dest\" ] && grep -qxF \"$dest\" \"$cache\" 2>/dev/null; then " ++
    "tv=xterm-maru; if [ -n \"$ctl\" ]; then nf=1; cmode=1; else nf=0; cmode=0; fi; run \"$@\"; exit $?; fi; " ++
    "if [ \"$elig\" = 1 ] && [ -n \"$ctl\" ]; then " ++
    "if " ++ emit_terminfo ++ " | ssh -o ControlMaster=auto -o ControlPath=\"$ctl\" -o ControlPersist=10 \"$@\" '" ++ remote_install ++ "' >/dev/null 2>&1; then " ++
    "[ -n \"$dest\" ] && { mkdir -p \"${cache%/*}\" 2>/dev/null; printf '%s\\n' \"$dest\" >> \"$cache\" 2>/dev/null; }; " ++
    "tv=xterm-maru; nf=1; cmode=1; run \"$@\"; exit $?; " ++
    "else tv=xterm-256color; nf=0; cmode=2; run \"$@\"; exit $?; fi; " ++
    "fi; " ++
    "tv=xterm-256color; nf=0; cmode=0; run \"$@\"; exit $?";

/// 설치만 하고 세션은 띄우지 않는 안전 primitive(= 문서의 수동 한 줄을 자동화). `ssh localhost` smoke의
/// 대상이자, ssh 가로채기 싫은 사용자의 강제 설치 경로다 — wrapper와 달리 **캐시를 읽지 않고 항상
/// 설치**한다(스테일 캐시 복구용). `$1`=적격 플래그(원격 command 붙으면 에러), `$2`=목적지. 설치 성공 시
/// 목적지를 캐시에 기록한다(중복 없이).
pub const terminfo_only_script =
    // ctl($3)·keepalive($4·$5)·재접속($6)은 안 쓰지만(설치만 하고 세션을 안 띄움) buildArgv가 항상
    // 같은 자리에 넣으므로 자리를 맞춰 shift 6 한다.
    "elig=\"$1\"; dest=\"$2\"; shift 6; cache=\"" ++ cache_path ++ "\"; " ++
    "[ \"$elig\" = 1 ] || { echo 'maru ssh --terminfo-only: specify only the destination (no remote command)' >&2; exit 2; }; " ++
    emit_terminfo ++ " | ssh \"$@\" '" ++ remote_install ++ "'; rc=$?; " ++
    "[ \"$rc\" = 0 ] && [ -n \"$dest\" ] && { grep -qxF \"$dest\" \"$cache\" 2>/dev/null || { mkdir -p \"${cache%/*}\" 2>/dev/null; printf '%s\\n' \"$dest\" >> \"$cache\" 2>/dev/null; }; }; " ++
    "exit \"$rc\"";

/// 결정론적 control socket 경로. `maru ssh`(이 모듈)와 로컬 Maru 앱(후속 "원격 인식" 단계)이 **같은
/// 규약으로 같은 경로를 도출**해야 OSC 통지 없이도 Maru가 socket을 찾을 수 있다. 그래서 순수 함수로
/// 두고 양쪽이 공유한다. 경로 = `<home>/.cache/maru/ctl-<dest 해시 hex>`. 설계 근거는
/// docs/ssh-integration.md §4(접속 방식 maru ssh 전용·결정론적 해시 경로, 사용자 결정 2026-06-21).
///
/// 해시는 dest 문자열의 Wyhash다 — 암호 용도가 아니라 **목적지별 유일 경로**가 목적이고(같은 host
/// 재접속은 같은 master를 공유), control socket은 세션 동안만 사는 일시 파일이라 빌드 간 영구 안정성은
/// 필요 없다(maru ssh와 Maru 앱은 같은 빌드의 같은 함수를 쓰므로 한 세션 안에서는 항상 일치한다).
/// unix domain socket 경로는 `sun_path` 길이 제한(macOS 104바이트, NUL 포함)이 있어 103자를 넘으면
/// `error.ControlPathTooLong`을 돌려준다 — 호출 측은 그때 control socket 없이 폴백한다.
pub const ControlPathError = error{ControlPathTooLong} || std.mem.Allocator.Error;

pub fn controlSocketPath(allocator: std.mem.Allocator, home: []const u8, dest: []const u8) ControlPathError![]u8 {
    // home 끝의 '/'는 떼어 `//` 중복을 막는다("/"가 home이면 base가 빈 문자열이 되어 `/.cache/...`가 됨).
    const base = std.mem.trimEnd(u8, home, "/");
    const hash = std.hash.Wyhash.hash(0, dest);
    const path = try std.fmt.allocPrint(allocator, "{s}/.cache/maru/ctl-{x}", .{ base, hash });
    if (path.len > 103) {
        allocator.free(path);
        return error.ControlPathTooLong;
    }
    return path;
}

/// 드롭 업로드 파일 크기 상한(사용자 결정 2026-06-21: 16MB, OSC 52 클립보드와 동일). 넘으면 업로드하지
/// 않는다 — 느린 ssh 링크에서 거대 파일 전송으로 세션이 멎는 걸 막는다. 실제 크기 검사는 실행 측(3b).
pub const max_upload_bytes: usize = 16 * 1024 * 1024;

/// 드롭된 로컬 파일 경로에서 원격에 쓸 안전한 파일명을 만든다(호출자 소유). basename만 취하고(경로
/// 구분자 제거), 영숫자·`.`·`-`·`_`만 남기고 나머지는 `_`로 바꾼다 — 셸 구절(uploadShellCommand)의
/// 큰따옴표 안에 그대로 들어가도 안전하고(`$`·백틱·공백·`;` 등 차단) 원격에서 예측 가능한 이름이 된다.
/// 선두 '.'(숨김 파일·`..` 경로 탈출)도 '_'로 바꾼다. 정제 후 비면 "drop"을 쓴다(충돌 회피 접두는 3b).
pub fn sanitizeDropFilename(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const base = std.fs.path.basename(path);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (base) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_';
        try out.append(allocator, if (safe) c else '_');
    }
    if (out.items.len > 0 and out.items[0] == '.') out.items[0] = '_'; // 선두 '.' = 숨김/'..' 탈출 차단
    if (out.items.len == 0) {
        out.deinit(allocator);
        return allocator.dupe(u8, "drop");
    }
    return out.toOwnedSlice(allocator);
}

/// 원격에서 드롭 파일을 받는 셸 구절(호출자 소유). `ssh -S <ctl> <dest> '<이 구절>'`로 실행하고 파일
/// 바이트를 stdin으로 흘리면, 원격이 저장 디렉터리를 만들고 stdin을 그 파일로 받은 뒤 **원격 절대경로를
/// stdout으로 돌려준다** — 로컬은 그 절대경로를 받아 메인 PTY로 paste한다(원격 $HOME을 로컬이 모르므로
/// 원격이 알려준다). `remote_name`은 sanitizeDropFilename으로 정제돼 큰따옴표 안에서 안전하다.
///
/// 업로드 전에 7일 지난 파일을 정리한다(`find -mtime +7 -delete`) — 저장 디렉터리가 paste/drop마다 무한
/// 누적되는 걸 막는 보존 정책(사용자 결정 2026-06-21, 7일). maru가 만든 dropped/만 건드리고, 진행 중
/// 파일(7일 이내)은 남기며, find 실패는 무시한다(업로드 자체는 계속). dropped/는 디렉터리당 1회 mkdir.
pub fn uploadShellCommand(allocator: std.mem.Allocator, remote_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "d=\"$HOME/.cache/maru/dropped\"; mkdir -p \"$d\" && find \"$d\" -type f -mtime +7 -delete 2>/dev/null; cat > \"$d/{s}\" && printf '%s' \"$d/{s}\"",
        .{ remote_name, remote_name },
    );
}

pub const ParseError = error{MissingDestination};

pub const Parsed = struct {
    /// `--terminfo-only`가 주어지면 설치만 하고 세션을 안 띄운다.
    terminfo_only: bool,
    /// ssh에 verbatim으로 넘길 인자들(목적지 포함). 비면 안 된다.
    ssh_args: []const []const u8,
};

/// `maru ssh` 뒤의 인자들을 파싱한다. 첫 인자가 `--terminfo-only`면 소비하고 플래그를 켠다. 남은
/// 인자가 없으면(목적지 없음) error. ssh 옵션 자체는 파싱하지 않는다 — 전부 ssh에 그대로 넘긴다.
pub fn parse(args: []const []const u8) ParseError!Parsed {
    var rest = args;
    var terminfo_only = false;
    if (rest.len > 0 and std.mem.eql(u8, rest[0], "--terminfo-only")) {
        terminfo_only = true;
        rest = rest[1..];
    }
    if (rest.len == 0) return error.MissingDestination;
    return .{ .terminfo_only = terminfo_only, .ssh_args = rest };
}

/// 모드에 맞는 셸 스크립트를 고른다.
pub fn scriptFor(terminfo_only: bool) []const u8 {
    return if (terminfo_only) terminfo_only_script else wrapper_script;
}

/// ssh 인자에 **원격 command가 없는지**(= bootstrap을 붙여도 안전한지) 판정한다. `maru ssh host`처럼
/// 순수 세션이면 true. `maru ssh host ls`처럼 command가 있으면 false — 그 경우 bootstrap 스크립트를
/// `"$@"`에 덧붙이면 ssh가 사용자 command 뒤에 설치 스크립트를 이어 붙여 (1) 설치가 안 되고 (2) 사용자
/// command가 부트스트랩과 세션에서 두 번 실행되는 위험이 있다(리뷰 #2). 그래서 command가 있으면
/// bootstrap을 건너뛴다. 파싱이 불확실하면(목적지를 못 찾으면) 보수적으로 false → 건너뜀(안전). 판정:
/// 목적지 = 첫 비옵션 토큰, 값 받는 옵션(ssh_value_opts)의 값 토큰은 건너뛴다; 목적지가 마지막이면
/// command 없음. 베이스: ssh(1) 옵션 문법. 틀려도 실패 모드는 "bootstrap skip → 평범한 ssh"라 안전하다.
pub fn bootstrapEligible(ssh_args: []const []const u8) bool {
    const di = destinationIndex(ssh_args) orelse return false; // 목적지 못 찾으면 보수적 skip
    return di == ssh_args.len - 1; // 목적지가 마지막 토큰 = 뒤에 원격 command 없음
}

/// ssh 인자에서 목적지(첫 비옵션 토큰)의 인덱스를 찾는다. 값 받는 옵션(ssh_value_opts)의 값 토큰은
/// 건너뛴다. 옵션만 있고 목적지가 없으면 null. bootstrapEligible과 destination이 공유하는 파서다.
pub fn destinationIndex(ssh_args: []const []const u8) ?usize {
    var i: usize = 0;
    while (i < ssh_args.len) {
        const arg = ssh_args[i];
        if (arg.len >= 2 and arg[0] == '-') {
            if (arg.len == 2 and std.mem.indexOfScalar(u8, ssh_value_opts, arg[1]) != null) {
                i += 2; // 값 받는 옵션(예: `-p 2222`) → 다음 토큰은 값
            } else {
                i += 1; // 부울 플래그·붙은 값(`-p2222`)·결합 플래그(`-tt`)는 한 토큰으로
            }
        } else {
            return i; // 첫 비옵션 토큰 = 목적지
        }
    }
    return null; // 목적지 없음(옵션만)
}

/// ssh 목적지 문자열(예: `user@host`, `host`). 설치 캐시의 **키**로 쓴다 — 이 목적지에 terminfo를
/// 설치했으면 다음 접속에서 bootstrap을 건너뛴다. 못 찾으면 null(그땐 캐시 안 함).
pub fn destination(ssh_args: []const []const u8) ?[]const u8 {
    return if (destinationIndex(ssh_args)) |i| ssh_args[i] else null;
}

/// 세션 수명 정책 — config `ssh.*`(theme.SshConfig)에서 온다. 기본값은 **그 스키마의 기본값과 같아야
/// 한다**: config를 못 읽는 경로(로드 실패)도 같은 동작을 내야 "설정을 안 건드렸는데 왜 다르지"가 안 생긴다.
pub const SessionOpts = struct {
    /// `ServerAliveInterval` 초. **0이면 `-o`를 아예 안 붙인다**(사용자 `~/.ssh/config` 존중).
    server_alive_interval: u32 = 15,
    /// `ServerAliveCountMax`. interval이 0이면 안 쓰인다.
    server_alive_count_max: u32 = 3,
    /// 끊겼을 때(ssh exit 255) 자동으로 다시 붙을지.
    reconnect: bool = true,
};

/// `buildArgv`가 숫자 옵션을 십진 문자열로 찍는 자리. **호출자가 소유**한다 — 반환 argv가 이 버퍼를
/// 빌려 가리키므로 `execve`까지 살아 있어야 한다. allocator로 찍지 않는 이유는 반환 slice의 다른 요소가
/// 전부 빌린 것이라(스크립트 상수·리터럴·`ssh_args`), 소유가 하나만 섞이면 free 규약이 갈리기 때문이다.
pub const ArgvScratch = struct {
    alive: [12]u8 = undefined,
    amax: [12]u8 = undefined,
};

/// `/bin/sh -c <script> sh <elig> <dest> <ctl> <alive> <amax> <rcon> <ssh args...>` 형태의 argv를 만든다.
/// `sh`는 `$0`, `$1`=bootstrap 적격 플래그("1"/"0"), `$2`=목적지(캐시 키, 없으면 빈 문자열), `$3`=control
/// socket 경로(빈 문자열이면 미사용 → 스크립트가 control socket 없이 폴백), `$4`=`ServerAliveInterval`
/// ("0"이면 keepalive 미사용), `$5`=`ServerAliveCountMax`, `$6`=재접속 플래그("1"/"0"), 그 뒤 ssh_args가
/// `"$@"`로 들어간다. `ctl`·`scratch`는 caller가 소유·수명 관리하고 여기선 빌려 가리킨다(반환 slice의 다른
/// 요소도 script 상수·리터럴·ssh_args를 빌린다 — 복사 아님). 반환 slice는 caller가 free한다.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    parsed: Parsed,
    ctl: []const u8,
    opts: SessionOpts,
    scratch: *ArgvScratch,
) ![]const []const u8 {
    // u32의 십진 표현은 최대 10자리라 12바이트 버퍼를 넘길 수 없다 — 넘치면 그것은 버퍼 크기를 잘못
    // 잡은 프로그래밍 오류이지 런타임 조건이 아니다.
    const alive = std.fmt.bufPrint(&scratch.alive, "{d}", .{opts.server_alive_interval}) catch unreachable;
    const amax = std.fmt.bufPrint(&scratch.amax, "{d}", .{opts.server_alive_count_max}) catch unreachable;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, "/bin/sh");
    try list.append(allocator, "-c");
    try list.append(allocator, scriptFor(parsed.terminfo_only));
    try list.append(allocator, "sh"); // $0
    try list.append(allocator, if (bootstrapEligible(parsed.ssh_args)) "1" else "0"); // $1 = bootstrap 적격
    try list.append(allocator, destination(parsed.ssh_args) orelse ""); // $2 = 목적지(캐시 키)
    try list.append(allocator, ctl); // $3 = control socket 경로(빈 문자열이면 미사용)
    try list.append(allocator, alive); // $4 = ServerAliveInterval("0"=미사용)
    try list.append(allocator, amax); // $5 = ServerAliveCountMax
    try list.append(allocator, if (opts.reconnect) "1" else "0"); // $6 = 재접속 플래그
    for (parsed.ssh_args) |a| try list.append(allocator, a);
    return list.toOwnedSlice(allocator);
}

test "parse: 플래그 없으면 terminfo_only=false, 전부 ssh 인자" {
    const p = try parse(&.{"user@host"});
    try std.testing.expect(!p.terminfo_only);
    try std.testing.expectEqual(@as(usize, 1), p.ssh_args.len);
    try std.testing.expectEqualStrings("user@host", p.ssh_args[0]);
}

test "parse: --terminfo-only는 소비되고 나머지가 ssh 인자" {
    const p = try parse(&.{ "--terminfo-only", "-p", "2222", "host" });
    try std.testing.expect(p.terminfo_only);
    try std.testing.expectEqual(@as(usize, 3), p.ssh_args.len);
    try std.testing.expectEqualStrings("-p", p.ssh_args[0]);
    try std.testing.expectEqualStrings("host", p.ssh_args[2]);
}

test "parse: 인자 없음 → MissingDestination" {
    try std.testing.expectError(error.MissingDestination, parse(&.{}));
}

test "parse: --terminfo-only만 있고 목적지 없음 → MissingDestination" {
    try std.testing.expectError(error.MissingDestination, parse(&.{"--terminfo-only"}));
}

test "wrapper 스크립트: 결정론적 ctl·캐시 hit 유지·ControlMaster·embed·안전 폴백 불변식" {
    const s = scriptFor(false);
    // 핵심 동작을 바이트로 고정한다("추측 말고 캡처").
    // ctl은 $3로 받고(buildArgv/controlSocketPath가 결정론적 경로를 만든다) 디렉터리를 준비한다.
    try std.testing.expect(std.mem.indexOf(u8, s, "ctl=\"$3\"; alive=\"$4\"; amax=\"$5\"; rcon=\"$6\"; shift 6") != null); // ctl($3)·keepalive($4·$5)·재접속($6) 수신
    try std.testing.expect(std.mem.indexOf(u8, s, "[ -n \"$ctl\" ] && mkdir -p \"${ctl%/*}\"") != null); // socket 디렉터리 준비
    try std.testing.expect(std.mem.indexOf(u8, s, "mktemp") == null); // 랜덤 mktemp 제거(결정론적 경로로 대체)
    // 부트스트랩=master, 세션=슬레이브(같은 $ctl 재사용 → 인증 1회).
    try std.testing.expect(std.mem.indexOf(u8, s, "ssh -o ControlMaster=auto -o ControlPath=\"$ctl\" -o ControlPersist=10 \"$@\"") != null); // 부트스트랩=master
    try std.testing.expect(std.mem.indexOf(u8, s, "tic -x -o \"$HOME/.terminfo\" -") != null); // 원격 설치
    // 세션 실행은 전부 `run`(재접속 루프)을 통과한다 — 경로가 정하는 것은 TERM(tv)·통지(nf)·control
    // socket 모드(cmode) 셋뿐이다. exec는 남지 않는다: 프로세스를 교체하면 ssh가 죽었을 때 다시 붙을
    // 셸이 없어 재접속 자체가 불가능하다.
    try std.testing.expect(std.mem.indexOf(u8, s, "tv=xterm-maru; nf=1; cmode=1; run \"$@\"; exit $?") != null); // 설치 성공 → maru TERM·통지·master 유지
    try std.testing.expect(std.mem.indexOf(u8, s, "else tv=xterm-256color; nf=0; cmode=2; run \"$@\"; exit $?") != null); // 설치 실패 → 안전 폴백(통지 없음, ControlPath만)
    try std.testing.expect(std.mem.indexOf(u8, s, "tv=xterm-256color; nf=0; cmode=0; run \"$@\"; exit $?") != null); // 부적격/ctl 없음 폴백
    try std.testing.expect(std.mem.indexOf(u8, s, "exec env") == null); // 재접속 루프가 exec를 대체했다
    try std.testing.expect(std.mem.indexOf(u8, s, "[ \"$elig\" = 1 ] && [ -n \"$ctl\" ]") != null); // 적격 게이트(부트스트랩은 ctl이 있어야)
    // COLORTERM: ssh 는 TERM 만 전달하므로 따로 요청해야 한다. **`SendEnv` 를 쓴다** — 실측(2026-08-18)에서
    // `SetEnv` 는 first-wins 라 커맨드라인에 하나 주면 **사용자 `~/.ssh/config` 의 SetEnv 가 통째로
    // 사라졌다**(`ssh -G` 로 확인). `SendEnv` 는 목록에 **누적**되고 사용자 SetEnv 도 건드리지 않으며,
    // OpenSSH 3.9 부터 있어 버전 프리플라이트도 필요 없다.
    try std.testing.expect(std.mem.indexOf(u8, s, "-o SendEnv=COLORTERM") != null); // 원격에 전달 요청
    try std.testing.expect(std.mem.indexOf(u8, s, "COLORTERM=truecolor ssh") != null); // 보낼 값은 env 로 명시(로컬 환경에 의존하지 않는다)
    // 부트스트랩(원격 tic 실행)에는 붙이지 않는다 — 색과 무관하고, 그 연결은 명령 실행 전용이다.
    try std.testing.expect(std.mem.indexOf(u8, s, "COLORTERM=truecolor ssh -o SendEnv=COLORTERM -o ControlMaster=auto -o ControlPath=\"$ctl\" -o ControlPersist=10") == null);
    // 캐시: hit이면 bootstrap 건너뛰되 ctl 있으면 control socket을 유지하며 maru로 exec, 설치 성공 시 목적지 기록.
    try std.testing.expect(std.mem.indexOf(u8, s, "grep -qxF \"$dest\" \"$cache\"") != null); // 캐시 read
    try std.testing.expect(std.mem.indexOf(u8, s, "ssh-terminfo-hosts") != null); // 캐시 파일
    try std.testing.expect(std.mem.indexOf(u8, s, ">> \"$cache\"") != null); // 캐시 write
    try std.testing.expect(std.mem.indexOf(u8, s, "tv=xterm-maru; if [ -n \"$ctl\" ]; then nf=1; cmode=1; else nf=0; cmode=0; fi; run \"$@\"; exit $?") != null); // 캐시 hit: ctl 있으면 socket 유지+통지, 없으면 그냥 세션
    // embed 회귀 가드: 로컬 infocmp 의존 없이(printf로 embed 소스 emit) 자기완결적이다.
    try std.testing.expect(std.mem.indexOf(u8, s, "printf '%s' '") != null); // embed 소스 emit
    try std.testing.expect(std.mem.indexOf(u8, s, "Sync=") != null); // embed된 terminfo가 스크립트에 들어있다
    try std.testing.expect(std.mem.indexOf(u8, s, "infocmp -x") == null); // 로컬 infocmp 의존 없음
    try std.testing.expect(std.mem.indexOf(u8, s, "command -v infocmp") == null); // 로컬 게이트 없음
    // 2단계: maru exec 직전 OSC 5379로 원격 세션을 Maru에 통지(tmux면 DCS passthrough).
    try std.testing.expect(std.mem.indexOf(u8, s, "notify() {") != null); // 통지 함수 정의
    try std.testing.expect(std.mem.indexOf(u8, s, "]5379;ssh;%s") != null); // OSC 5379 payload(ssh;<dest>)
    try std.testing.expect(std.mem.indexOf(u8, s, "clear_notify() {") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "]5379;ssh-end") != null); // ssh 종료 뒤 local shell로 복귀
    try std.testing.expect(std.mem.indexOf(u8, s, "Ptmux;") != null); // tmux passthrough 래핑
    try std.testing.expect(std.mem.indexOf(u8, s, "[ \"$nf\" = 1 ] && begin_notify") != null); // 통지는 nf가 정한다(폴백 경로는 nf=0)
    // 회귀 가드: SetEnv(OpenSSH 7.8+ 전용) 미사용 — 리뷰 #4 원안 그대로다. COLORTERM 도 SetEnv 가 아니라
    // SendEnv 로 보내므로 이 가드를 좁힐 필요가 없었다(적대적 검증 2026-08-18: SetEnv 는 사용자 config 의
    // SetEnv 를 덮는다는 실측이 나와 SendEnv 로 갈았다).
    try std.testing.expect(std.mem.indexOf(u8, s, "SetEnv") == null);
}

/// 셸 스크립트를 `/bin/sh -c`로 띄우고 (자식 pid, 읽기 fd)를 돌려준다. 못 띄우면 null.
///
/// **두 테스트 헬퍼가 이것을 공유한다.** 각자 fork/pipe/exec를 들면 같은 syscall이 두 벌이 되고,
/// `cli/` 순수성 게이트가 세는 impure 토큰도 두 배가 된다(`tests/boundary/cli_purity.zig`의 재고가
/// 그 수를 고정한다 — 이 파일의 제품 경로는 순수하고 예외는 테스트 헬퍼뿐이라는 것이 그 항목의 뜻이다).
/// 게이트가 아니어도 fork 절차를 두 벌 두는 것은 그 자체로 나쁘다.
const SpawnedShell = struct { pid: std.c.pid_t, fd: c_int };

fn spawnShell(script_z: [:0]const u8, capture_stderr: bool) ?SpawnedShell {
    var pipe_fds: [2]c_int = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return null;
    const child = std.c.fork();
    if (child < 0) {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
        return null;
    }
    if (child == 0) {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.dup2(pipe_fds[1], 1);
        // 재접속 루프의 안내는 stderr로 나가므로(CLI 진단 관례) 그쪽 테스트만 stderr까지 모은다.
        if (capture_stderr) _ = std.c.dup2(pipe_fds[1], 2);
        _ = std.c.close(pipe_fds[1]);
        const sh: [:0]const u8 = "/bin/sh";
        const arg0: [:0]const u8 = "sh";
        const arg1: [:0]const u8 = "-c";
        var argv = [_:null]?[*:0]const u8{ arg0.ptr, arg1.ptr, script_z.ptr, null };
        _ = execv(sh.ptr, &argv);
        std.c._exit(127);
    }
    _ = std.c.close(pipe_fds[1]);
    return .{ .pid = child, .fd = pipe_fds[0] };
}

/// `out`이 차거나 EOF까지 마저 읽는다. `used`는 이미 읽은 길이(이어서 채운다).
fn drainShell(fd: c_int, out: []u8, used: *usize) void {
    while (used.* < out.len) {
        const n = std.c.read(fd, out[used.*..].ptr, out.len - used.*);
        if (n <= 0) break;
        used.* += @intCast(n);
    }
}

fn expectNotifyLifecycle(body: []const u8, signal: ?std.c.SIG, expected_exit: u32) !void {
    const allocator = std.testing.allocator;
    const script = try std.fmt.allocPrint(
        allocator,
        "notify() {{ printf 'notify\\n'; }}; clear_notify() {{ printf 'clear\\n'; }}; {s}{s}",
        .{ notify_lifecycle, body },
    );
    defer allocator.free(script);
    const script_z = try allocator.dupeZ(u8, script);
    defer allocator.free(script_z);
    const spawned = spawnShell(script_z, false) orelse return error.SkipZigTest;
    const child = spawned.pid;
    defer _ = std.c.close(spawned.fd);
    // 어떤 경로로 빠져나가도 자식을 거둔다. 아래 `expect` 들이 실패하면 그 자리에서 반환하는데, 그러면
    // 자식이 고아로 남아 부모 없이 계속 돈다(2026-08-28 실측: 며칠 된 고아가 load average 를 89 까지
    // 끌어올렸다). 정상 종료 경로가 이미 거뒀으면 `reaped` 로 표시해 두 번 기다리지 않는다.
    var reaped = false;
    defer if (!reaped) {
        _ = std.c.kill(child, std.posix.SIG.KILL);
        var orphan_status: c_int = 0;
        _ = std.c.waitpid(child, &orphan_status, 0);
    };

    var output: [64]u8 = undefined;
    // 첫 조각은 **신호를 보내기 전에** 읽어야 한다 — `notify`가 나온 뒤라야 trap이 걸린 상태다.
    const first = std.c.read(spawned.fd, &output, output.len);
    if (first <= 0) return error.TestUnexpectedResult; // 위 defer 가 거둔다
    var used: usize = @intCast(first);
    try std.testing.expect(std.mem.indexOf(u8, output[0..used], "notify\n") != null);
    if (signal) |sig| try std.testing.expectEqual(@as(c_int, 0), std.c.kill(child, sig));

    var status: c_int = 0;
    try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
    reaped = true;
    drainShell(spawned.fd, &output, &used);
    try std.testing.expectEqualStrings("notify\nclear\n", output[0..used]);
    const unsigned_status: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(unsigned_status));
    try std.testing.expectEqual(expected_exit, std.c.W.EXITSTATUS(unsigned_status));
}

test "notify lifecycle: normal exit and HUP INT TERM emit ssh-end exactly once with preserved status" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    // 대기 body 는 **CPU 를 태우지 않고, 고아가 되어도 스스로 사라져야 한다.**
    //
    // 예전에는 `while :; do :; done` 이었다. signal 을 기다리는 동안 코어 하나를 100% 로 돌리고, 테스트가
    // 도중에 죽으면(타임아웃 kill 등) 자식이 고아로 남아 **며칠씩** 그 상태로 돈다. 2026-08-28 실측:
    // 3~4 일 된 고아 3 개가 살아 있어 load average 가 89/145/133 까지 올랐고 맥 전체가 느려졌다.
    // 정리 후 32 로 떨어졌다.
    //
    // `sleep` 은 그 사이에도 signal 을 받아 trap 이 그대로 돌므로 검증 대상은 바뀌지 않는다. 유한 루프라
    // 고아가 되어도 수명이 60 초로 끝난다 — 테스트는 그 전에 signal 을 보내므로 여유가 넉넉하다.
    const wait_body = "begin_notify; i=0; while [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done";
    try expectNotifyLifecycle("begin_notify; exit 17", null, 17);
    try expectNotifyLifecycle(wait_body, std.posix.SIG.HUP, 129);
    try expectNotifyLifecycle(wait_body, std.posix.SIG.INT, 130);
    try expectNotifyLifecycle(wait_body, std.posix.SIG.TERM, 143);
}

test "embed: 바이너리에 terminfo 소스가 들어있고 emit 구절이 그걸 흘린다" {
    // 자기완결성: 로컬 설치 없이도 원격 전파가 되려면 소스가 바이너리 안에 있어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, embedded_terminfo, "xterm-maru|maru") != null); // 항목 헤더
    try std.testing.expect(std.mem.indexOf(u8, embedded_terminfo, "Sync=") != null); // 핵심 캡
    try std.testing.expect(std.mem.startsWith(u8, emit_terminfo, "printf '%s' '"));
    try std.testing.expectEqual(@as(u8, '\''), emit_terminfo[emit_terminfo.len - 1]); // 닫는 따옴표
}

test "terminfo-only 스크립트: 캐시 무시 강제 설치, 성공 시 기록, 세션 exec 없음" {
    const s = scriptFor(true);
    try std.testing.expect(std.mem.indexOf(u8, s, "tic -x -o \"$HOME/.terminfo\" -") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "[ \"$elig\" = 1 ]") != null); // 적격 게이트(원격 command 오용 차단)
    try std.testing.expect(std.mem.indexOf(u8, s, ">> \"$cache\"") != null); // 성공 시 캐시 기록
    try std.testing.expect(std.mem.indexOf(u8, s, "grep -qxF \"$dest\" \"$cache\"") != null); // 중복 없이(기록 전 확인)
    try std.testing.expect(std.mem.indexOf(u8, s, "exec ") == null); // 세션을 띄우지 않는다
    try std.testing.expect(std.mem.indexOf(u8, s, "shift 6") != null); // ctl($3)·keepalive($4·$5)·재접속($6) 자리 소비(buildArgv argv 일관)
}

test "bootstrapEligible: 순수 세션은 적격, 원격 command가 있으면 부적격" {
    try std.testing.expect(bootstrapEligible(&.{"host"}));
    try std.testing.expect(bootstrapEligible(&.{"user@host"}));
    try std.testing.expect(bootstrapEligible(&.{ "-p", "2222", "host" })); // 값 옵션 + dest
    try std.testing.expect(bootstrapEligible(&.{ "-i", "key", "-4", "host" })); // 값 옵션 + 부울 + dest
    // 원격 command가 붙으면 부적격(이중 실행 방지).
    try std.testing.expect(!bootstrapEligible(&.{ "host", "ls" }));
    try std.testing.expect(!bootstrapEligible(&.{ "-p", "2222", "host", "uptime" }));
    // 목적지 없음(옵션만/빈) → 보수적으로 부적격.
    try std.testing.expect(!bootstrapEligible(&.{}));
    try std.testing.expect(!bootstrapEligible(&.{ "-p", "2222" }));
}

test "destination: 첫 비옵션 토큰을 캐시 키로 뽑는다" {
    try std.testing.expectEqualStrings("host", destination(&.{"host"}).?);
    try std.testing.expectEqualStrings("user@host", destination(&.{"user@host"}).?);
    try std.testing.expectEqualStrings("host", destination(&.{ "-p", "2222", "host" }).?); // 값 옵션 건너뜀
    try std.testing.expectEqualStrings("host", destination(&.{ "host", "ls" }).?); // command 앞 목적지
    try std.testing.expect(destination(&.{}) == null);
    try std.testing.expect(destination(&.{ "-p", "2222" }) == null); // 옵션만 → 없음
}

test "buildArgv: /bin/sh -c <script> sh <elig> <dest> <ctl> <alive> <amax> <rcon> <ssh 인자>" {
    const a = std.testing.allocator;
    const p = try parse(&.{"user@host"});
    var scratch: ArgvScratch = .{};
    const argv = try buildArgv(a, p, "/tmp/ctl-x", .{}, &scratch);
    defer a.free(argv);
    try std.testing.expectEqual(@as(usize, 11), argv.len);
    try std.testing.expectEqualStrings("/bin/sh", argv[0]);
    try std.testing.expectEqualStrings("-c", argv[1]);
    try std.testing.expectEqualStrings(scriptFor(false), argv[2]);
    try std.testing.expectEqualStrings("sh", argv[3]);
    try std.testing.expectEqualStrings("1", argv[4]); // host 단독 → 적격
    try std.testing.expectEqualStrings("user@host", argv[5]); // $2 = 목적지(캐시 키)
    try std.testing.expectEqualStrings("/tmp/ctl-x", argv[6]); // $3 = control socket 경로
    try std.testing.expectEqualStrings("user@host", argv[10]); // $4~$6 뒤부터 ssh 인자
}

test "buildArgv: 원격 command가 있으면 적격 플래그 0" {
    const a = std.testing.allocator;
    const p = try parse(&.{ "host", "ls" });
    var scratch: ArgvScratch = .{};
    const argv = try buildArgv(a, p, "", .{}, &scratch);
    defer a.free(argv);
    try std.testing.expectEqualStrings("0", argv[4]); // host + command → 부적격
}

test "controlSocketPath: 결정론적이고 dest별로 다르다" {
    const a = std.testing.allocator;
    const p1 = try controlSocketPath(a, "/Users/me", "user@host");
    defer a.free(p1);
    const p2 = try controlSocketPath(a, "/Users/me", "user@host");
    defer a.free(p2);
    try std.testing.expectEqualStrings(p1, p2); // 같은 (home,dest) → 같은 경로(결정론 — Maru가 OSC 통지 없이 계산)
    try std.testing.expect(std.mem.startsWith(u8, p1, "/Users/me/.cache/maru/ctl-"));
    const p3 = try controlSocketPath(a, "/Users/me", "other@host");
    defer a.free(p3);
    try std.testing.expect(!std.mem.eql(u8, p1, p3)); // 다른 dest → 다른 경로(목적지별 유일)
}

test "controlSocketPath: home 끝 슬래시를 정규화한다" {
    const a = std.testing.allocator;
    const p = try controlSocketPath(a, "/Users/me/", "host");
    defer a.free(p);
    try std.testing.expect(std.mem.indexOf(u8, p, "//") == null); // `//` 중복 없음
    try std.testing.expect(std.mem.startsWith(u8, p, "/Users/me/.cache/maru/ctl-"));
}

test "controlSocketPath: sun_path 한도를 넘으면 ControlPathTooLong" {
    const a = std.testing.allocator;
    const long_home = "/" ++ ("x" ** 120); // 경로가 sun_path(104B)를 넘는다
    try std.testing.expectError(error.ControlPathTooLong, controlSocketPath(a, long_home, "host"));
}

test "sanitizeDropFilename: basename + 안전 문자만(셸 메타·경로탈출 차단)" {
    const a = std.testing.allocator;
    const p1 = try sanitizeDropFilename(a, "/Users/me/Screen Shot.png");
    defer a.free(p1);
    try std.testing.expectEqualStrings("Screen_Shot.png", p1); // basename + 공백→_
    const p2 = try sanitizeDropFilename(a, "/tmp/a$b`c;d.txt");
    defer a.free(p2);
    try std.testing.expectEqualStrings("a_b_c_d.txt", p2); // 셸 메타문자→_
    const p3 = try sanitizeDropFilename(a, "/x/..");
    defer a.free(p3);
    try std.testing.expectEqualStrings("_.", p3); // 선두 '.'→_ ('..' 경로 탈출 차단)
    const p4 = try sanitizeDropFilename(a, "");
    defer a.free(p4);
    try std.testing.expectEqualStrings("drop", p4); // basename 비면 기본명
}

test "uploadShellCommand: mkdir + cat + 원격 절대경로 echo" {
    const a = std.testing.allocator;
    const cmd = try uploadShellCommand(a, "img.png");
    defer a.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "mkdir -p \"$d\"") != null); // 저장 디렉터리 생성
    try std.testing.expect(std.mem.indexOf(u8, cmd, "cat > \"$d/img.png\"") != null); // stdin→파일
    try std.testing.expect(std.mem.indexOf(u8, cmd, "printf '%s' \"$d/img.png\"") != null); // 원격 절대경로 반환
    try std.testing.expect(std.mem.indexOf(u8, cmd, ".cache/maru/dropped") != null); // 저장 위치
    try std.testing.expect(std.mem.indexOf(u8, cmd, "find \"$d\" -type f -mtime +7 -delete") != null); // 7일 보존 정리
}

test "wrapper 스크립트: keepalive는 0이면 안 붙고, 세션 세 갈래 모두 싣는다" {
    const s = scriptFor(false);
    // 조립 자리: 0이면 `$ka`가 빈 문자열이라 `-o`가 **아예 안 나간다**(사용자 `~/.ssh/config` 존중).
    try std.testing.expect(std.mem.indexOf(u8, s, "ka=\"\"; [ \"$alive\" != 0 ] && ka=\"-o ServerAliveInterval=$alive -o ServerAliveCountMax=$amax\"") != null);
    // 세 갈래 전부에 실린다 — 한 갈래만 빠지면 그 경로에서만 감지가 늦어 원인을 짚기 어렵다.
    try std.testing.expect(std.mem.indexOf(u8, s, "1) env TERM=\"$tv\" COLORTERM=truecolor ssh $ka -o SendEnv=COLORTERM -o ControlMaster=auto -o ControlPath=\"$ctl\" \"$@\" ;;") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "2) env TERM=\"$tv\" COLORTERM=truecolor ssh $ka -o SendEnv=COLORTERM -o ControlPath=\"$ctl\" \"$@\" ;;") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "*) env TERM=\"$tv\" COLORTERM=truecolor ssh $ka -o SendEnv=COLORTERM \"$@\" ;;") != null);
    // 부트스트랩(원격 tic 실행)에는 안 붙인다 — 짧은 명령이라 keepalive가 할 일이 없다.
    try std.testing.expect(std.mem.indexOf(u8, s, "ControlPersist=10 \"$@\" $ka") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "$ka -o ControlMaster=auto -o ControlPath=\"$ctl\" -o ControlPersist=10") == null);
}

test "wrapper 스크립트: 재접속은 255에만·원격 command엔 안 걸고·안 붙는 호스트는 포기한다" {
    const s = scriptFor(false);
    try std.testing.expect(std.mem.indexOf(u8, s, "[ \"$rcon\" = 1 ] || return \"$rc\"") != null); // 정책 off면 그대로 반환
    try std.testing.expect(std.mem.indexOf(u8, s, "[ \"$rc\" = 255 ] || return \"$rc\"") != null); // 원격 종료 코드는 흘려보낸다
    try std.testing.expect(std.mem.indexOf(u8, s, "[ \"$elig\" = 1 ] || rcon=0") != null); // `maru ssh host cmd`는 재실행하지 않는다
    try std.testing.expect(std.mem.indexOf(u8, s, "if [ \"$short\" -ge 3 ]") != null); // 접속 자체가 안 되면 포기
    try std.testing.expect(std.mem.indexOf(u8, s, "delay=$((delay * 2)); [ \"$delay\" -gt 30 ] && delay=30") != null); // 백오프와 상한
    try std.testing.expect(std.mem.indexOf(u8, s, "wait_retry() { if [ -n \"$BASH_VERSION\" ] && [ -t 0 ]; then read -t") != null); // Enter로 건너뛰기(bash·tty)
}

test "buildArgv: keepalive·재접속이 $4~$6 자리에 십진으로 들어간다" {
    const a = std.testing.allocator;
    const p = try parse(&.{"user@host"});
    var scratch: ArgvScratch = .{};
    const argv = try buildArgv(a, p, "/tmp/ctl", .{}, &scratch);
    defer a.free(argv);
    try std.testing.expectEqualStrings("1", argv[4]); // $1 bootstrap 적격
    try std.testing.expectEqualStrings("user@host", argv[5]); // $2 목적지
    try std.testing.expectEqualStrings("/tmp/ctl", argv[6]); // $3 control socket
    try std.testing.expectEqualStrings("15", argv[7]); // $4 ServerAliveInterval 기본
    try std.testing.expectEqualStrings("3", argv[8]); // $5 ServerAliveCountMax 기본
    try std.testing.expectEqualStrings("1", argv[9]); // $6 재접속 기본 on
    try std.testing.expectEqualStrings("user@host", argv[10]); // 그 뒤부터 ssh 인자

    var scratch_off: ArgvScratch = .{};
    const argv_off = try buildArgv(a, p, "", .{ .server_alive_interval = 0, .reconnect = false }, &scratch_off);
    defer a.free(argv_off);
    try std.testing.expectEqualStrings("0", argv_off[7]); // 0 = keepalive 미사용
    try std.testing.expectEqualStrings("0", argv_off[9]); // 0 = 재접속 안 함
}

test "buildArgv: SessionOpts 기본값은 config 스키마 기본값과 같다" {
    // 갈리면 "설정을 안 건드렸는데 CLI와 앱이 다르게 군다"가 된다. 한쪽만 고치는 것을 막는 자리다.
    const cfg: @import("../config/theme.zig").SshConfig = .{};
    const opts: SessionOpts = .{};
    try std.testing.expectEqual(cfg.server_alive_interval, opts.server_alive_interval);
    try std.testing.expectEqual(cfg.server_alive_count_max, opts.server_alive_count_max);
    try std.testing.expectEqual(cfg.reconnect, opts.reconnect);
}

/// `session_loop`를 **실제 `/bin/sh`로** 돌리고 출력을 모아 돌려준다(`out`에 쓴다). 문자열 검사는 "스크립트에
/// 그 구절이 있다"까지만 말하는데, 재접속은 **몇 번 도는가·언제 멈추는가**가 전부라 그 층에서는 판정이 안 된다.
///
/// `ssh`뿐 아니라 `env`도 셸 함수로 갈아 끼운다 — 스크립트가 `env TERM=… ssh …`로 부르므로 `env`가 그 자리에서
/// 실제 바이너리를 찾고, `ssh` 함수만 정의하면 **안 탄다**(그러면 테스트가 진짜 ssh를 부른다).
fn runSessionLoop(allocator: std.mem.Allocator, setup: []const u8, out: []u8) ![]u8 {
    const script = try std.fmt.allocPrint(
        allocator,
        "n=0; " ++
            "env() {{ while [ $# -gt 0 ]; do case \"$1\" in *=*) shift ;; *) break ;; esac; done; \"$@\"; }}; " ++
            "date() {{ printf 100; }}; " ++ // 시간 고정 = 모든 세션이 "짧은 세션"(접속 실패 판정을 태운다)
            "notify() {{ printf 'notify\\n'; }}; clear_notify() {{ printf 'clear\\n'; }}; " ++
            "{s}{s}" ++
            "wait_retry() {{ :; }}; " ++ // 대기 없이(정책은 바이트 테스트가 본다)
            "tv=x; nf=1; cmode=0; ka=''; ctl=''; dest=box; " ++
            "{s} run host; printf 'rc=%s\\n' \"$?\"",
        .{ notify_lifecycle, session_loop, setup },
    );
    defer allocator.free(script);
    const script_z = try allocator.dupeZ(u8, script);
    defer allocator.free(script_z);

    // stderr까지 모은다 — 재접속 안내는 CLI 진단 관례대로 stderr로 나가고, 그 문구가 판정 대상이다.
    const spawned = spawnShell(script_z, true) orelse return error.SkipZigTest;
    defer _ = std.c.close(spawned.fd);
    var used: usize = 0;
    drainShell(spawned.fd, out, &used);
    var status: c_int = 0;
    _ = std.c.waitpid(spawned.pid, &status, 0);
    return out[0..used];
}

test "재접속 루프(실행): 끊기면 다시 붙고, 통지는 세션마다 정확히 한 쌍이다" {
    // POSIX 전용 하네스다(fork/pipe). **이 가드는 런타임 skip 이 아니라 comptime 가지치기다** —
    // `builtin.os.tag` 가 comptime 상수라 다른 타깃에서는 본문이 통째로 사라지고, 그래야
    // `std.c.pipe` 의 fd 타입이 타깃마다 다른 것(Windows 는 `*anyopaque`)이 크로스 컴파일을 깨지 않는다.
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    // 첫 세션은 255(끊김), 두 번째는 0(정상 종료) — 두 번째에서 루프가 멈춰야 한다.
    const text = try runSessionLoop(a, "rcon=1; ssh() { n=$((n+1)); printf 'try%s\\n' \"$n\"; [ \"$n\" -ge 2 ] && return 0; return 255; };", &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "try2") != null); // 다시 붙었다
    try std.testing.expect(std.mem.indexOf(u8, text, "try3") == null); // 성공했으면 멈춘다
    try std.testing.expect(std.mem.indexOf(u8, text, "rc=0") != null); // 마지막 세션의 코드를 그대로 낸다
    try std.testing.expect(std.mem.indexOf(u8, text, "connection to box lost") != null); // 사용자에게 이유를 말한다
    // 통지는 세션마다 열고 닫힌다 — 안 닫으면 Maru가 끊긴 목적지를 계속 원격으로 표시한다.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "notify\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "clear\n"));
}

test "재접속 루프(실행): 255가 아니면 재시도하지 않는다" {
    // POSIX 전용 하네스다(fork/pipe). **이 가드는 런타임 skip 이 아니라 comptime 가지치기다** —
    // `builtin.os.tag` 가 comptime 상수라 다른 타깃에서는 본문이 통째로 사라지고, 그래야
    // `std.c.pipe` 의 fd 타입이 타깃마다 다른 것(Windows 는 `*anyopaque`)이 크로스 컴파일을 깨지 않는다.
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    // 원격 셸이 `exit 3`으로 끝난 것 — 사용자가 끝낸 세션을 되살리면 안 된다.
    const text = try runSessionLoop(a, "rcon=1; ssh() { n=$((n+1)); printf 'try%s\\n' \"$n\"; return 3; };", &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "try2") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "rc=3") != null); // 원격 코드를 그대로 흘린다
}

test "재접속 루프(실행): 정책이 꺼져 있으면 255여도 그대로 끝낸다" {
    // POSIX 전용 하네스다(fork/pipe). **이 가드는 런타임 skip 이 아니라 comptime 가지치기다** —
    // `builtin.os.tag` 가 comptime 상수라 다른 타깃에서는 본문이 통째로 사라지고, 그래야
    // `std.c.pipe` 의 fd 타입이 타깃마다 다른 것(Windows 는 `*anyopaque`)이 크로스 컴파일을 깨지 않는다.
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    const text = try runSessionLoop(a, "rcon=0; ssh() { n=$((n+1)); printf 'try%s\\n' \"$n\"; return 255; };", &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "try2") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "rc=255") != null);
}

test "재접속 루프(실행): 안 붙는 호스트는 3번 만에 포기한다" {
    // POSIX 전용 하네스다(fork/pipe). **이 가드는 런타임 skip 이 아니라 comptime 가지치기다** —
    // `builtin.os.tag` 가 comptime 상수라 다른 타깃에서는 본문이 통째로 사라지고, 그래야
    // `std.c.pipe` 의 fd 타입이 타깃마다 다른 것(Windows 는 `*anyopaque`)이 크로스 컴파일을 깨지 않는다.
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    // `date`가 고정이라 모든 세션이 2초 미만 = 접속 자체가 안 되는 모양. 이 판정이 없으면 호스트 오타에
    // **영원히 재시도한다**(사용자가 Ctrl-C를 칠 때까지 화면이 재접속 메시지로 덮인다).
    const text = try runSessionLoop(a, "rcon=1; ssh() { n=$((n+1)); printf 'try%s\\n' \"$n\"; return 255; };", &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "try3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "try4") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "giving up") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "rc=255") != null);
}
