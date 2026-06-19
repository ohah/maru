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
//! 의도적으로 뺀 것(후속): 호스트 설치 캐시(Ghostty `+ssh-cache` 대응), terminfo 소스를 바이너리에
//! embed해 로컬 설치 의존을 없애기. 지금은 로컬 `infocmp -x xterm-maru`(= `mise run install-terminfo`
//! 후)를 쓴다. 단일 연결(ControlMaster)·원격 command 안전 처리(bootstrapEligible)는 이 슬라이스에서 했다.

const std = @import("std");

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

/// ssh 값 옵션 letter set — 이 옵션 바로 다음 토큰은 옵션의 값이지 목적지가 아니다(ssh(1) 기준).
/// bootstrapEligible이 목적지(첫 비옵션 토큰)를 찾을 때 값 토큰을 건너뛰는 데 쓴다.
const ssh_value_opts = "bcDEeFIiJLlmOopQRSWw";

/// 전체 래퍼 스크립트(`/bin/sh -c <script> sh <elig> <ssh args...>`로 실행). `$1`=bootstrap 적격
/// 플래그(Zig `bootstrapEligible` 결과 "1"/"0"), 나머지 `"$@"`=ssh 인자.
///
/// 적격("$1"=1: 원격 command 없는 순수 세션 + 로컬에 xterm-maru 있음)일 때만 **ControlMaster 단일
/// 연결** 안에서 terminfo를 심고 같은 연결로 세션을 exec한다 — 부트스트랩 ssh가 master가 되고
/// (`ControlMaster=auto`·`ControlPersist=10`) 세션 ssh가 그 소켓을 재사용해 **인증이 한 번**만 일어난다
/// (리뷰 #3: 비밀번호 인증 이중 프롬프트 제거). 설치 성공→`TERM=xterm-maru`, 실패→`xterm-256color` 폴백.
///
/// 부적격("$1"=0: 원격 command가 붙었거나 파싱 불확실)이면 bootstrap을 **건너뛰고** 그냥
/// `exec env TERM=xterm-256color ssh "$@"` 한다 — `ssh host cmd`에 설치 스크립트를 덧붙이면 사용자
/// command가 부트스트랩과 세션에서 **두 번 실행**되는 위험(리뷰 #2)을 피한다.
///
/// TERM은 `env`로 ssh 프로세스 환경에 실어 ssh가 원격으로 전달하게 한다 — `-o SetEnv`는 OpenSSH 7.8+
/// 전용이라 구버전 클라이언트 회귀를 만든다(리뷰 #4). `env TERM=...`는 POSIX라 그 의존이 없다.
pub const wrapper_script =
    "elig=\"$1\"; shift; " ++
    "if [ \"$elig\" = 1 ] && command -v infocmp >/dev/null 2>&1 && infocmp -x xterm-maru >/dev/null 2>&1; then " ++
    "ctl=$(mktemp -u \"${TMPDIR:-/tmp}/maru-ssh-XXXXXX\"); " ++
    "if infocmp -x xterm-maru | ssh -o ControlMaster=auto -o ControlPath=\"$ctl\" -o ControlPersist=10 \"$@\" '" ++ remote_install ++ "' >/dev/null 2>&1; then " ++
    "exec env TERM=xterm-maru ssh -o ControlPath=\"$ctl\" \"$@\"; " ++
    "else exec env TERM=xterm-256color ssh -o ControlPath=\"$ctl\" \"$@\"; fi; " ++
    "fi; " ++
    "exec env TERM=xterm-256color ssh \"$@\"";

/// 설치만 하고 세션은 띄우지 않는 안전 primitive(= 문서의 수동 한 줄을 자동화). `ssh localhost` smoke의
/// 대상이자 ssh 가로채기 싫은 사용자용. wrapper와 같은 `$1`=적격 플래그를 받아, 원격 command가 붙은
/// 오용(`--terminfo-only host cmd`)이면 설치하지 않고 에러낸다(command 이중 실행 방지).
pub const terminfo_only_script =
    "elig=\"$1\"; shift; " ++
    "[ \"$elig\" = 1 ] || { echo 'maru ssh --terminfo-only: 목적지만 지정하세요(원격 command 불가)' >&2; exit 2; }; " ++
    "infocmp -x xterm-maru | ssh \"$@\" '" ++ remote_install ++ "'";

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
            return i == ssh_args.len - 1; // destination — 뒤에 토큰이 더 있으면 원격 command
        }
    }
    return false; // destination을 못 찾음(옵션만) → 보수적으로 skip
}

/// `/bin/sh -c <script> sh <elig> <ssh args...>` 형태의 argv를 만든다. `sh`는 `$0`, `$1`=bootstrap 적격
/// 플래그("1"/"0"), 그 뒤 ssh_args가 `"$@"`로 들어간다. 반환 slice는 caller가 free한다(요소는 script
/// 상수·"1"/"0" 리터럴·ssh_args를 빌려 가리킨다 — 복사 아님).
pub fn buildArgv(allocator: std.mem.Allocator, parsed: Parsed) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, "/bin/sh");
    try list.append(allocator, "-c");
    try list.append(allocator, scriptFor(parsed.terminfo_only));
    try list.append(allocator, "sh"); // $0
    try list.append(allocator, if (bootstrapEligible(parsed.ssh_args)) "1" else "0"); // $1 = bootstrap 적격
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

test "wrapper 스크립트: ControlMaster 단일연결·terminfo 설치·안전 폴백·적격 분기 불변식" {
    const s = scriptFor(false);
    // 핵심 동작을 바이트로 고정한다("추측 말고 캡처").
    try std.testing.expect(std.mem.indexOf(u8, s, "ssh -o ControlMaster=auto -o ControlPath=\"$ctl\" -o ControlPersist=10 \"$@\"") != null); // 부트스트랩=master
    try std.testing.expect(std.mem.indexOf(u8, s, "tic -x -o \"$HOME/.terminfo\" -") != null); // 원격 설치
    try std.testing.expect(std.mem.indexOf(u8, s, "exec env TERM=xterm-maru ssh -o ControlPath=\"$ctl\"") != null); // 성공 시 maru + master 재사용
    try std.testing.expect(std.mem.indexOf(u8, s, "exec env TERM=xterm-256color ssh \"$@\"") != null); // 부적격/실패 폴백
    try std.testing.expect(std.mem.indexOf(u8, s, "[ \"$elig\" = 1 ]") != null); // 적격 게이트
    // 회귀 가드: SetEnv(OpenSSH 7.8+ 전용)·mkdir(tic -o가 대신) 미사용.
    try std.testing.expect(std.mem.indexOf(u8, s, "SetEnv") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "mkdir") == null);
}

test "terminfo-only 스크립트: 적격일 때만 설치, 세션 exec 없음" {
    const s = scriptFor(true);
    try std.testing.expect(std.mem.indexOf(u8, s, "tic -x -o \"$HOME/.terminfo\" -") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "[ \"$elig\" = 1 ]") != null); // 적격 게이트(원격 command 오용 차단)
    try std.testing.expect(std.mem.indexOf(u8, s, "exec ") == null); // 세션을 띄우지 않는다
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

test "buildArgv: /bin/sh -c <script> sh <elig> <ssh 인자>" {
    const a = std.testing.allocator;
    const p = try parse(&.{"user@host"});
    const argv = try buildArgv(a, p);
    defer a.free(argv);
    try std.testing.expectEqual(@as(usize, 6), argv.len);
    try std.testing.expectEqualStrings("/bin/sh", argv[0]);
    try std.testing.expectEqualStrings("-c", argv[1]);
    try std.testing.expectEqualStrings(scriptFor(false), argv[2]);
    try std.testing.expectEqualStrings("sh", argv[3]);
    try std.testing.expectEqualStrings("1", argv[4]); // host 단독 → 적격
    try std.testing.expectEqualStrings("user@host", argv[5]);
}

test "buildArgv: 원격 command가 있으면 적격 플래그 0" {
    const a = std.testing.allocator;
    const p = try parse(&.{ "host", "ls" });
    const argv = try buildArgv(a, p);
    defer a.free(argv);
    try std.testing.expectEqualStrings("0", argv[4]); // host + command → 부적격
}
