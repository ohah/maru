//! provider 설정에 넣을 **인라인 훅 커맨드**를 만드는 순수 모듈(L2, I/O 없음).
//! 계약의 단일 출처는 [docs/agent-hooks.md](../../docs/agent-hooks.md) §4.1이고, 실제 설치(파일 읽기·쓰기·
//! `flock`·Codex trust 갱신)는 AH2가 맡는다.
//!
//! **왜 스크립트 파일이 아니라 인라인인가**: 파일을 두면 provider가 매 이벤트마다 그 절대경로를 실행하므로,
//! 그 파일을 덮어쓸 수 있는 누구든 사용자 권한으로 임의 코드를 돌린다. 우리가 하는 일은 한 줄 append라
//! 파일이 필요 없다. 대가는 Codex `trusted_hash`가 커맨드 바이트 해시라 **로직을 고치면 재승인**이 뜬다는
//! 것이므로, 커맨드는 한 번에 확정하고 자주 바꾸지 않는다.
//!
//! **왜 추가 프로세스를 하나도 안 쓰는가**: 실측(2026-08-20)에서 훅 1회 비용의 65%가 `sh` spawn 자체였다
//! (`/bin/sh -c "exit 0"` 8.04 ms, 훅 전체 12.27 ms). 스크립트가 `cat`·`mkdir`·`head`를 부르면 그만큼
//! 프로세스가 더 뜨고 도구 호출마다 그 값이 얹힌다. 그래서 stdin은 셸 내장 `read`로 받고, 길이 제한은
//! `${#var}`로 하고, 디렉터리는 **설치할 때 maru가 미리 만든다**(훅은 없으면 조용히 실패하고 나간다).

const std = @import("std");
const event = @import("agent_hook_event.zig");

/// 커맨드 끝에 붙는 표식. **우리 항목을 고르는 유일한 근거**다(파일이 없으므로 파일명 매칭이 불가능하다).
///
/// 사람이 읽는 안내를 함께 넣는다 — 사용자가 이 커맨드를 복사해 자기 항목으로 쓰면 우리가 그것을 우리 것으로
/// 오인해 지운다. 그 사고를 막는 것은 "이건 maru 것이고 임의로 사라진다"는 문장뿐이다.
///
/// **이 문장만은 UI 언어를 따르지 않고 영어로 고정한다**(i18n `t()`를 쓰지 않는다). Codex는
/// `config.toml`의 `trusted_hash`가 **커맨드 바이트의 sha256**이라, 문구가 언어에 따라 달라지면
/// **앱 언어를 바꾸는 것만으로 훅이 미신뢰가 되어 매 실행에 확인 프롬프트가 뜬다.** 설정 파일에 남는
/// 문자열이라 표시 계층이 아니라 **프로토콜 상수**로 다룬다(docs/i18n.md §7의 "영어 고정 표면"과 같은 결).
pub const marker = "MARU_HOOK_V3";
pub const marker_comment = "# " ++ marker ++ " managed by maru: added and removed automatically, do not copy";

/// payload 길이 상한. 넘으면 훅이 **표식 한 줄로 바꿔** 적는다(잘라서 반쪽 JSON을 만들지 않는다).
///
/// **줄 상한에서 접두를 뺀 값이다.** 훅이 적는 줄은 `<provider><구분자><payload>` 라서 payload 를 줄 상한과
/// 같게 두면 그만큼 줄이 길어져 **파서가 버린다** — 커맨드는 통과시키고 파서는 버리는, 상한 경계에서만
/// 나타나는 유실이다. 접두 최대치(provider 이름 + 구분자 1)를 미리 뺀다.
pub const max_payload_bytes: usize = event.max_line_bytes - event.max_provider_len - 1;

/// 훅 항목에 함께 적는 타임아웃(초). **기본값에 맡기지 않는다** — provider 가 그 기본을 바꾸면 우리 훅이
/// 조용히 길어지고, 그동안 에이전트 턴이 물린다(계약 §4.1).
///
/// **2초인 근거**: 훅 1회 실측이 12.27 ms 이고 하는 일은 로컬 파일 append 하나뿐이다. 그 100배를 넘겨도
/// 안 끝난다면 디스크·파일 잠금에 뭔가 잘못된 것이고, 그때는 **훅을 포기하는 쪽이 옳다** — 이벤트 하나를
/// 잃는 것과 사용자의 턴이 멈추는 것 중 전자가 낫다.
pub const timeout_seconds: u32 = 2;

/// 이벤트 로그가 사는 자리(`sessionCacheBase()` 아래 상대 경로). platform 이 **미리 만들고**(0700) 그
/// 절대 경로를 `build` 에 넘긴다 — 커맨드는 디렉터리를 만들지 않는다(훅이 하는 일이 적을수록 턴이 빨리 끝나고,
/// `mkdir` 이 실패하는 경우를 훅 안에서 처리할 방법도 없다).
pub const log_dir_rel = "agent-turn-events";

/// 훅에 신원을 넘기는 예약 환경변수 둘. **control-plane 의 `MARU_PANE_ID` 와 갈라 둔다.**
///
/// 예전에는 pane 칸으로 `MARU_PANE_ID` 를 그대로 썼다. 그 값은 control-plane `auth.self` selector 이고
/// **GUI process-local surface id** 라, host 가 띄운 자식에는 실을 수 없다(GUI 가 재실행되면 그 번호는
/// 남의 pane 을 가리킨다 — 그래서 `persistentSpawnRequest` 가 fail-closed 로 떼어 낸다). 한 변수가 두 일을
/// 하는 동안은 «훅 신원» 을 host 소유 값으로 바꾸는 것이 곧 «selector 를 거짓말하게 만드는 것» 이었다.
///
/// 그래서 훅은 자기 변수를 갖는다. `MARU_PANE_ID` 는 selector 로만 남고, 훅 경로는 이 둘만 본다 —
/// 소유자가 GUI 든 host 든 **같은 규칙으로** 채워지는 칸이다(계약 §4).
pub const instance_env = "MARU_HOOK_INSTANCE";
pub const pane_env = "MARU_HOOK_PANE";

/// 경로 한 칸에 허용되는 글자를 **한 곳에서** 정한다.
///
/// 이 값 하나가 셸 가드의 문자 클래스(`case … in *[!…]*`)와 maru 쪽 판정(`accepts`)을 **함께** 만든다.
/// 두 곳에 손으로 적으면 «커맨드는 거부하는데 maru 는 통과시키는»(또는 반대) 드리프트가 조용히 생기고,
/// 그 증상은 «훅은 도는데 이벤트가 0» — 진단하기 가장 나쁜 상태다(계약 §4.1).
pub const TokenClass = struct {
    /// 허용 구간(양끝 포함). 셸 bracket expression 의 `a-z` 와 같은 뜻이다.
    ranges: []const [2]u8,
    /// 구간으로 표현하기 어색한 낱글자.
    extra: []const u8 = "",

    /// 이 칸에 써도 되는 값인가. **빈 값은 거부한다** — 빈 칸은 경로를 `//` 로 접어 상위 디렉터리에 쓴다.
    pub fn accepts(self: TokenClass, token: []const u8) bool {
        if (token.len == 0) return false;
        next_char: for (token) |ch| {
            for (self.ranges) |range| {
                if (ch >= range[0] and ch <= range[1]) continue :next_char;
            }
            for (self.extra) |allowed| {
                if (ch == allowed) continue :next_char;
            }
            return false;
        }
        return true;
    }

    /// 셸 bracket expression 안에 그대로 들어가는 글자 목록.
    ///
    /// ⚠️ **구간을 `a-z` 로 적지 않고 낱글자로 펼친다.** 셸의 bracket «범위» 는 로케일 collation 순서를
    /// 따르므로 `[!0-9a-z_]` 이 **대문자를 통과시킨다** — 실측(2026-08-24):
    ///
    /// ```text
    /// C            : 범위표기=reject  낱글자열거=reject
    /// en_US.UTF-8  : 범위표기=accept  낱글자열거=reject
    /// ko_KR.UTF-8  : 범위표기=accept  낱글자열거=reject
    /// ```
    ///
    /// 즉 사용자 로케일에서 가드가 조용히 느슨해진다(옛 `[!0-9]` 는 글자가 없어 이 함정 밖이었다 — 클래스를
    /// 넓히면서 생긴 위험이고, 셸 게이트가 머지 전에 잡았다). 훅은 `LC_ALL` 을 정할 수 없다(provider 가 주는
    /// 환경에서 돈다). 그래서 **표기 자체를 로케일에 무관하게** 만든다.
    pub fn shellClass(comptime self: TokenClass) []const u8 {
        comptime {
            var rendered: []const u8 = "";
            for (self.ranges) |range| {
                var ch = range[0];
                while (ch <= range[1]) : (ch += 1) rendered = rendered ++ &[_]u8{ch};
            }
            return rendered ++ self.extra;
        }
    }
};

/// pane 칸의 허용 글자. 십진 `surface_id`(GUI 소유)와 32 hex `runtime_id`(host 소유)를 함께 받으므로
/// hex 글자까지 든다.
pub const pane_token_class: TokenClass = .{ .ranges = &.{ .{ '0', '9' }, .{ 'a', 'f' } } };

/// 인스턴스 칸의 허용 글자. host 소유 칸은 `host_` 접두를 달아 **사람이 캐시 디렉터리를 봐도** 누가
/// 소유자인지 읽히게 하므로 소문자와 `_` 까지 든다.
///
/// ⚠️ **지키는 성질은 «숫자만» 이 아니라 «경로를 벗어나지 못한다» 다.** 화이트리스트에 `/` 와 `.` 가 없는
/// 것이 그 성질을 보장한다(실측 2026-08-20: 검증이 없을 때 `../outside/pwned` 가 로그 디렉터리 밖에 파일을
/// 만들었다). 글자 범위를 넓히는 변경은 그 둘이 여전히 빠져 있는지만 확인하면 된다.
pub const instance_token_class: TokenClass = .{ .ranges = &.{ .{ '0', '9' }, .{ 'a', 'z' } }, .extra = "_" };

/// host 가 소유하는 인스턴스 칸의 접두.
pub const host_instance_prefix = "host_";

/// 인스턴스/pane 칸 문자열 버퍼 크기. u128 hex 32 자(+접두)가 최대다.
pub const instance_token_max = host_instance_prefix.len + 32;
pub const pane_token_max = 32;

/// GUI 프로세스가 소유하는 인스턴스 칸 — 그 프로세스의 pid.
///
/// **pid 인 이유는 «살아 있는가» 를 물을 수 있어서다**(계약 §4). 시작 시 정리가 남의 칸을 지워도 되는지
/// `getpgid` 로 판정한다.
pub fn formatGuiInstance(buf: *[instance_token_max]u8, pid: u32) []const u8 {
    // u32 십진은 10 자라 버퍼(37)를 넘길 수 없다.
    return std.fmt.bufPrint(buf, "{d}", .{pid}) catch unreachable;
}

/// host 가 소유하는 인스턴스 칸 — `host_<32 hex host_id>`.
///
/// **pid 가 아니라 `host_id` 인 이유**: host 는 업그레이드로 **프로세스가 바뀌어도 같은 host** 다
/// (`upgrade_bootstrap` 이 `invocation.host_id != state.host.host_id` 를 거부한다 — 후계자가 같은 id 를
/// 물려받는다). pid 로 이름을 지으면 업그레이드 뒤 그 칸이 «죽은 인스턴스» 로 보여, **살아 있는 runtime 의
/// 로그를 정리가 거둔다.** host_id 는 그 교체를 넘어 살아남는 유일한 소유자 키다.
pub fn formatHostInstance(buf: *[instance_token_max]u8, host_id: u128) []const u8 {
    return std.fmt.bufPrint(buf, host_instance_prefix ++ "{x:0>32}", .{host_id}) catch unreachable;
}

/// GUI 프로세스가 소유하는 pane 칸 — process-local `surface_id`(십진). 파일 이름은 예전과 같다.
pub fn formatSurfacePane(buf: *[pane_token_max]u8, surface_id: u64) []const u8 {
    // u64 십진은 20 자라 버퍼(32)를 넘길 수 없다.
    return std.fmt.bufPrint(buf, "{d}", .{surface_id}) catch unreachable;
}

/// host 가 소유하는 pane 칸 — `runtime_id`(32 hex).
///
/// **`surface_id` 가 아니라 `runtime_id` 인 이유**: 그 자식은 GUI 보다 오래 살고, GUI 가 재실행된 뒤에도
/// 자기 로그를 알아볼 수 있어야 한다. workspace 가 이미 `runtime-handle`(host_id:runtime_id)을 저장하므로
/// 재접속한 GUI 는 **새로 저장할 것 없이** 그 이름을 다시 계산한다.
pub fn formatRuntimePane(buf: *[pane_token_max]u8, runtime_id: u128) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>32}", .{runtime_id}) catch unreachable;
}

/// 원격 pane 신원(`LC_MARU_PANE`)의 최대 길이 — `<instance>_<pane>`.
pub const remote_pane_nonce_max = instance_token_max + 1 + pane_token_max;

/// 원격에 실어 보내는 pane 신원을 만든다([계획](../../docs/plans/remote-agent-state.md) RA2).
///
/// **여기가 유일한 조립 자리다.** 로컬 훅 경로의 두 칸을 만드는 곳과 같은 파일에 두는 이유는 §4 가 적어
/// 둔 그것이다 — 두 곳에서 조립하면 «훅이 쓰는 이름 ≠ maru 가 읽는 이름» 이 조용히 성립한다. 셸에서
/// 문자열을 이어 붙이지 않고 이 함수가 만든 값을 argv 로 넘긴다.
///
/// ⚠️ **인스턴스 칸을 반드시 넣는다.** `surface_id` 는 프로세스마다 1 부터라, 빼면 maru 를 둘 띄운 순간
/// 두 인스턴스의 첫 pane 이 원격에서 **같은 파일**을 쓴다 — §4 가 로컬에서 겪은 사고를 원격에서 그대로
/// 재현하는 셈이다.
///
/// 두 칸이 각자의 화이트리스트를 통과하지 못하면 **null 을 준다** — 호출자는 그때 이 값을 안 보낸다.
/// 값이 없는 채로 보내면 원격 훅이 경로를 조립할 수 없고, 그 실패는 원격 파일 이름에서만 드러난다.
pub fn formatRemotePaneNonce(
    buf: *[remote_pane_nonce_max]u8,
    instance: []const u8,
    pane: []const u8,
) ?[]const u8 {
    if (instance.len > instance_token_max or pane.len > pane_token_max) return null;
    // `accepts` 가 빈 값도 거부한다 — 빈 칸은 경로를 접어 상위 디렉터리에 쓴다(그 함수의 주석).
    if (!instance_token_class.accepts(instance)) return null;
    if (!pane_token_class.accepts(pane)) return null;
    return std.fmt.bufPrint(buf, "{s}_{s}", .{ instance, pane }) catch unreachable;
}

/// 우리가 거는 이벤트(계약 §2). **한 번에 확정한다** — Codex는 나중에 늘리면 사용자에게 재승인을 요구한다.
pub const Event = struct {
    name: []const u8,
    /// `null`이면 matcher 없이 등록한다.
    matcher: ?[]const u8 = null,
};

/// 훅을 설치하는 대상. **세트가 provider 마다 다르므로** 이 값이 곧 «어떤 이벤트를 거는가» 를 정한다.
pub const Provider = enum {
    claude,
    codex,

    /// 로그 줄 앞에 붙는 표식(파서가 읽는 그 값). `looksLikeProvider` 를 통과하는 이름이어야 한다.
    pub fn tag(self: Provider) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
        };
    }
};

/// claude 세트(계약 §2). **한 번에 확정한다.**
pub const claude_events = [_]Event{
    .{ .name = "SessionStart" },
    .{ .name = "UserPromptSubmit" },
    .{ .name = "Stop" },
    // 오류로 끝난 턴은 `Stop` 이 **오지 않는다** — 이것을 안 걸면 그 pane 이 영영 «진행 중» 이다(계약 §2).
    // codex 열거에는 없어 claude 세트에만 둔다.
    .{ .name = "StopFailure" },
    .{ .name = "Notification" },
    .{ .name = "PermissionRequest", .matcher = "*" },
    .{ .name = "PreToolUse", .matcher = "*" },
    // 자식 수를 **세는** 유일한 신뢰 신호다(계약 §2). 자식이 도는 동안 lead 의 `Stop` 은 턴 끝이
    // 아니고, 세지 않으면 «자식이 아직 도는데 완료 알림» 이 나간다. 양 provider 열거에 다 있다(실측).
    .{ .name = "SubagentStart" },
    .{ .name = "SubagentStop" },
};

/// codex 세트 — **`Notification` 과 `StopFailure` 가 없다**(2026-08-21 실측). codex 자신에게 물어
/// 확정했다: app-server `hooks/list` 는 **codex 가 실제로 로드한 것만** 돌려주므로, 모르는 이름을 함께
/// 적어 두고 목록에서 빠지는지를 보면 추측이 필요 없다. 그렇게 물었을 때 빠진 것이 정확히 이 둘이다.
/// 없는 이벤트를 걸면 잘해야 무시되고, 나쁘면 그 파일의 파싱을 통째로 깨뜨린다 — 남의 설정 파일이라
/// 시험 삼아 넣지 않는다.
///
/// codex 에는 `PostToolUse`·`SessionEnd`·`PreCompact`·`PostCompact` 도 있으나 걸지 않는다 — 앞의 것은
/// 비용 때문이고(계약 §3.1) 나머지 셋은 지금 쓰는 자리가 없다.
///
/// ⚠️ **`StopFailure` 가 없다는 것의 대가는 메울 수 없다**(계약 §9-10, 2026-08-22 종결). codex 는 오류로
/// 끝난 턴에 `Stop` **도** 보내지 않는다 — 공개 소스에서 오류 경로가 stop 훅을 부르기 전에 반환하고
/// (`core/src/session/turn.rs`), 그 사실은 훅이 아니라 extension API 로만 나간다. 그래서 오류 턴은 배지를
/// «진행 중» 에 남기고 다음 턴이 정상 종료할 때 풀린다. `SessionEnd` 를 여기 더해도 안 메워진다 — 그것은
/// 세션이 끝날 때만 오고, 대화형의 «세션은 살아 있고 턴만 실패한» 경우가 바로 그 문제이기 때문이다.
/// **다음 사람에게**: 이 자리를 다시 파기 전에 §9-10 을 읽어라. 답은 «codex 가 훅을 하나 내어 주기 전까지
/// 없다» 이고, 그 조사는 이미 소스까지 갔다.
///
/// 나머지 일곱은 claude 와 같은 이름이다(codex 도 `hooks.json` 에는 PascalCase 로 적는다 — 실측).
pub const codex_events = [_]Event{
    .{ .name = "SessionStart" },
    .{ .name = "UserPromptSubmit" },
    .{ .name = "Stop" },
    .{ .name = "PermissionRequest", .matcher = "*" },
    .{ .name = "PreToolUse", .matcher = "*" },
    // 자식 수를 **세는** 유일한 신뢰 신호다(계약 §2). 자식이 도는 동안 lead 의 `Stop` 은 턴 끝이
    // 아니고, 세지 않으면 «자식이 아직 도는데 완료 알림» 이 나간다. 양 provider 열거에 다 있다(실측).
    .{ .name = "SubagentStart" },
    .{ .name = "SubagentStop" },
};

/// 훅을 **어디에 거는가**. provider 와 함께 세트를 정하는 두 번째 축이다
/// ([계획](../../docs/plans/remote-agent-state.md) RA1).
pub const Scope = enum {
    /// maru 가 자기 pty 에 띄운 에이전트. 지금까지의 유일한 경우다.
    local,
    /// ssh 너머에서 도는 에이전트. 배지·대화 줄만 쓰고 턴 스냅샷은 안 만든다
    /// (사용자 결정 2026-08-29 — 계약 [§11](../../docs/agent-hooks.md)).
    remote,
};

/// 원격에서 **빼는** 이벤트. **이 목록 하나가 단일 출처다.**
///
/// 원격 세트를 배열로 따로 적지 않는 이유가 여기 있다 — 그러면 로컬 세트가 늘 때 원격이 **조용히
/// 뒤처지고**, 그 어긋남이 드러나는 자리는 사용자의 원격 설정 파일뿐이다(§2 가 provider 세트에서
/// 이미 겪은 실패 방식이다). 그래서 원격은 로컬에서 **파생**시키고, 무엇을 왜 빼는지만 여기 적는다.
///
/// **`PreToolUse` 를 빼는 근거는 셋이다.**
/// 1. 그것이 만드는 `→ running` 은 `UserPromptSubmit` 이 이미 만든다(`agent_hook_mode.next`).
///    그것만 주는 두 가지(진행 중 세부·AI 소행 경로)는 턴 스냅샷 축이고, 원격 범위 밖이다.
/// 2. **비용**: 도구 호출마다 도는 발화가 계약 §3 의 주범이다(턴당 ~90 ms).
/// 3. **보안**: payload 에 `tool_input.command`(셸 명령 원문)와 `oldString`/`newString`(소스코드)이
///    실린다(계약 §7). 원격 축에서는 그것이 **네트워크를 건너므로** 로컬보다 훨씬 무겁게 걸린다.
pub const remote_excluded = [_][]const u8{"PreToolUse"};

fn isRemoteExcluded(name: []const u8) bool {
    for (remote_excluded) |x| {
        if (std.mem.eql(u8, x, name)) return true;
    }
    return false;
}

/// 로컬 세트에서 `remote_excluded` 를 걷어낸 원격 세트를 comptime 에 만든다.
fn deriveRemote(comptime src: []const Event) []const Event {
    comptime {
        var out: [src.len]Event = undefined;
        var n: usize = 0;
        for (src) |e| {
            if (isRemoteExcluded(e.name)) continue;
            out[n] = e;
            n += 1;
        }
        const frozen = out[0..n].*;
        return &frozen;
    }
}

pub const claude_remote_events = deriveRemote(&claude_events);
pub const codex_remote_events = deriveRemote(&codex_events);

/// 그 provider 가 그 자리에서 거는 이벤트. **전역 세트를 두지 않는다** — 하나로 두면 codex 에 없는
/// 이벤트가 조용히 섞이고, 그 사실이 드러나는 자리는 사용자의 설정 파일뿐이다. **스코프 없는
/// 접근자도 두지 않는다** — 같은 이유로 «조용히 로컬 세트를 쓰는 원격 경로» 가 생긴다.
pub fn eventsFor(provider: Provider, scope: Scope) []const Event {
    return switch (scope) {
        .local => switch (provider) {
            .claude => &claude_events,
            .codex => &codex_events,
        },
        .remote => switch (provider) {
            .claude => claude_remote_events,
            .codex => codex_remote_events,
        },
    };
}

/// 셸 single-quote 이스케이프. 경로에 `'`가 있어도 커맨드가 깨지지 않게 `'\''`로 끊어 붙인다.
fn appendQuoted(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, '\'');
    for (value) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}

/// 한 provider의 훅 커맨드를 만든다. `log_dir_abs`는 maru가 **미리 만들어 둔** 이벤트 로그 디렉터리다.
///
/// 계약이 요구하는 것을 순서대로 지킨다:
/// 1. **stdin을 먼저 전부 삼킨다** — 첫 줄을 payload로 받고 나머지를 드레인한다. 안 그러면 provider 파이프가
///    막힌다. 실측상 payload는 개행 없는 한 줄 JSON이라 드레인 루프는 즉시 끝난다.
/// 2. pane 식별자가 없으면 **아무것도 하지 않고** 나간다(maru 밖에서 띄운 세션에는 남길 pane이 없다).
/// 3. 상한을 넘으면 표식으로 바꾼다 — 이벤트를 조용히 없애지 않는다.
/// 4. provider 이름을 **우리가 붙인다**(payload에는 그 정보가 없다).
/// 5. 무슨 일이 있어도 `exit 0`.
pub fn build(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    provider: []const u8,
    log_dir_abs: []const u8,
) error{ OutOfMemory, InvalidProvider }!void {
    // **provider 이름을 검증한다.** 이 값은 줄 앞에 그대로 적히므로 탭이나 개행이 들어오면 **모든 줄이
    // 깨진다**(구분자가 둘이 되거나 줄이 둘로 갈린다). 파서와 같은 규칙을 쓴다 — 두 곳이 기준이 다르면
    // «훅은 적었는데 파서는 못 읽는» 이름이 생긴다.
    if (!event.looksLikeProvider(provider)) return error.InvalidProvider;
    // `|| :` — provider가 `sh -e`로 실행해도 마지막 줄의 read 실패(개행 없이 끝남)가 훅을 죽이지 않게.
    // **파일 권한을 훅이 정한다.** 이 로그에는 payload 가 그대로 실리고 거기엔 소스 코드와 셸 명령 원문이
    // 들어간다(계약 §7). `>>` 가 만드는 파일의 권한은 **셸의 umask** 에 끌려가므로, 두지 않으면 흔한 기본값
    // (022)에서 0644 로 만들어져 같은 머신의 다른 사용자가 읽는다. 디렉터리는 platform 이 0700 으로 만들지만
    // 그것만으로는 부족하다 — 디렉터리 권한은 나중에 사용자가 바꿀 수 있고, 파일 자체가 안전해야 한다.
    // `umask` 는 셸 내장이라 프로세스가 늘지 않는다.
    try out.appendSlice(allocator, "umask 077; ");
    try out.appendSlice(allocator, "IFS= read -r mh_p || :; while IFS= read -r mh_x; do :; done; ");
    // **pane 칸을 화이트리스트로 검증한다.** 그 값이 그대로 파일명이 되므로 검증 없이 쓰면 경로를 벗어난다 —
    // 실측(2026-08-20)에서 `../outside/pwned` 가 로그 디렉터리 **밖에** 파일을 만들었다. 지키는 성질은
    // «숫자만» 이 아니라 «`/` 와 `.` 가 없다» 이고, 클래스가 그것을 보장한다. 문자 클래스는 `pane_token_class`
    // 에서 렌더한다 — 여기 손으로 적으면 maru 쪽 판정과 갈린다. `case` 는 셸 내장이라 프로세스가 늘지 않는다.
    try out.print(allocator, "case \"${s}\" in ''|*[!{s}]*) exit 0 ;; esac; ", .{
        pane_env,
        comptime pane_token_class.shellClass(),
    });
    // **인스턴스 식별자도 같은 규율로 검증한다.** 로그 디렉터리는 사용자 캐시 하나뿐이라 **maru 를 두 개
    // 띄우면 두 인스턴스가 같은 디렉터리를 쓴다.** 그런데 `surface_id` 는 프로세스마다 1 부터 발급되므로
    // (`SurfaceIdAllocator`) 두 인스턴스의 첫 pane 이 **같은 파일 이름**을 갖는다 — 서로의 이벤트를 읽고,
    // 시작 시 정리가 남의 살아 있는 로그를 지운다. 그래서 파일 이름 앞에 인스턴스 칸을 하나 둔다.
    // 값은 GUI 소유면 그 pid, host 소유면 `host_<hex host_id>` 다(`formatGuiInstance`/`formatHostInstance`).
    // 그 밖의 모양이면 우리 세션이 아니라고 보고 나간다 — 경로 탈출 방어는 pane 칸과 같은 이유·같은 방법이다.
    try out.print(allocator, "case \"${s}\" in ''|*[!{s}]*) exit 0 ;; esac; ", .{
        instance_env,
        comptime instance_token_class.shellClass(),
    });
    // **상한을 넘겨도 «무엇이었는지» 는 살린다**(2026-08-21 실사용에서 실제로 넘겼다 — codex payload 하나).
    //
    // 예전에는 이름까지 버리고 `__oversized__` 하나만 남겼다. 그런데 `Stop` 은 최종 답변 전문
    // (`last_assistant_message`)을 싣는다 — 긴 보고서를 낸 턴이면 상한을 넘고, 그러면 **턴 끝 신호를
    // 통째로 잃어 배지가 안 풀린다.** 이 층이 막으려는 바로 그 실패다.
    //
    // 그래서 payload 를 버리기 **전에** 이름만 뽑는다. 세트의 이름을 `case` 로 훑는 것이라 프로세스가
    // 늘지 않는다(셸 내장). 이름을 못 찾으면 예전처럼 표식만 남긴다 — 모르는 것을 지어내지 않는다.
    // 본문은 사라지므로 알림 문구는 비지만, **상태는 옳게 간다**. 그 둘 중 무엇을 지킬지는 계약이
    // 이미 정해 두었다: 안 풀리는 배지가 더 나쁘다.
    try out.print(allocator, "if [ ${{#mh_p}} -gt {d} ]; then case \"$mh_p\" in ", .{max_payload_bytes});
    // **claude 세트로 훑는다 — codex 세트는 그 부분집합이다**(위 테스트가 못박는다). 그래서 커맨드가
    // provider 마다 갈리지 않고, 한 벌로 두 곳을 덮는다.
    for (claude_events) |e| {
        try out.print(allocator, "*'\"hook_event_name\":\"{s}\"'*) mh_p='{{\"hook_event_name\":\"{s}\"}}' ;; ", .{ e.name, e.name });
    }
    try out.print(allocator, "*) mh_p='{{\"hook_event_name\":\"{s}\"}}' ;; esac; fi; ", .{event.oversized_marker});
    // **`{ … } 2>/dev/null` 로 감싼다.** `printf … 2>/dev/null` 은 printf 자신의 stderr 만 막고 **리다이렉션
    // 대상이 없을 때 셸이 내는 에러**(`No such file or directory`)는 못 막는다 — 실측에서 로그 디렉터리가
    // 없을 때 그 메시지가 provider 화면으로 샜다. 훅은 어떤 실패도 사용자에게 보이지 않아야 한다.
    // **구분자는 파서와 같은 상수여야 한다.** 셸 포맷 문자열에는 `\t` 를 글자로 적을 수밖에 없어(작은따옴표
    // 안의 실제 탭은 읽는 사람이 못 본다) 두 곳에 따로 적히는 모양이 된다. 그 드리프트는 «모든 이벤트가
    // 조용히 파싱 실패» 로 나타나므로, 상수가 탭이 아니게 되면 **컴파일이 깨지게** 묶어 둔다.
    comptime {
        if (event.field_separator != '\t') {
            // 개발자 메시지는 영어로 둔다(i18n 원장 §7.2 — 표시 문자열이 아니고 컴파일 로그에 뜬다).
            @compileError("hook command separator drifted from `agent_hook_event.field_separator`; " ++
                "update the `\\t` in the printf format string too");
        }
    }
    try out.print(allocator, "{{ printf '{s}\\t%s\\n' \"$mh_p\" >> ", .{provider});
    try appendQuoted(out, allocator, log_dir_abs);
    // 경로는 `<로그 디렉터리>/<인스턴스>/<pane>.ndjson` 이다 — 따옴표 밖에서 확장해야 값이 들어간다.
    // 인스턴스 칸이 있어야 maru 를 여러 개 띄워도 이름이 안 겹친다(위 가드 주석). 디렉터리는 maru 가
    // 미리 만든다 — 훅이 `mkdir` 을 부르면 그만큼 프로세스가 늘고(계약 §4.1), 없으면 조용히 나간다.
    try out.print(allocator, "\"/${s}/${s}.ndjson\"; }} 2>/dev/null; exit 0 ", .{ instance_env, pane_env });
    try out.appendSlice(allocator, marker_comment);
}

/// 이 커맨드가 우리 것인가. **표식만 본다** — 경로·상한이 바뀌어도 우리 것으로 남고, 사용자 항목은 표식이
/// 없으므로 걸리지 않는다.
pub fn isOurs(command: []const u8) bool {
    return std.mem.indexOf(u8, command, marker) != null;
}

/// 과거 표식. [persistent-session-host.md](../../docs/persistent-session-host.md) P1이 "legacy 잔재를 자동
/// 정리하지 않는다"고 정했으므로 **우리는 이 항목을 지우지 않는다.** 여기 두는 이유는 우리 표식과 구분해
/// «건드리지 않았음»을 테스트로 고정하기 위해서다.
pub const legacy_markers = [_][]const u8{"MARU_AGENT_MAP_HOOK_V2"};

pub fn isLegacy(command: []const u8) bool {
    for (legacy_markers) |m| {
        if (std.mem.indexOf(u8, command, m) != null) return true;
    }
    return false;
}

const testing = std.testing;

fn buildAlloc(provider: []const u8, dir: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try build(&out, testing.allocator, provider, dir);
    return out.toOwnedSlice(testing.allocator);
}

test "두 칸 모두 파일에 쓰기 전에 검증한다 — 그 값이 그대로 파일명이 되므로" {
    // 실측: 검증이 없을 때 `../outside/pwned` 가 로그 디렉터리 밖에 파일을 만들었다.
    const cmd = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(cmd);
    const write = std.mem.indexOf(u8, cmd, "printf").?;
    for ([_][]const u8{ pane_env, instance_env }) |name| {
        const guard = std.mem.indexOf(u8, cmd, name) orelse return error.GuardMissing;
        try testing.expect(guard < write);
    }
}

test "셸 가드의 문자 클래스는 maru 쪽 판정과 같은 값에서 나온다" {
    // 두 곳에 손으로 적으면 «커맨드는 거부하는데 maru 는 통과시키는» 드리프트가 조용히 생긴다. 렌더된
    // 클래스가 커맨드 안에 그대로 있는지 본다 — 그러면 한 상수를 고치는 것으로 양쪽이 함께 움직인다.
    const cmd = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "*[!" ++ comptime pane_token_class.shellClass() ++ "]*") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "*[!" ++ comptime instance_token_class.shellClass() ++ "]*") != null);
}

test "셸 클래스는 범위 표기를 쓰지 않는다 — 범위는 로케일을 탄다" {
    // 실측(2026-08-24): `[!0-9a-z_]` 는 en_US.UTF-8·ko_KR.UTF-8 에서 `HOST_AA` 를 **통과시킨다**(범위가
    // collation 순서를 따르므로). 낱글자로 펼치면 어느 로케일에서도 거부한다. 훅은 provider 가 주는
    // 환경에서 돌아 `LC_ALL` 을 정할 수 없으므로, 표기 자체가 로케일에 무관해야 한다.
    inline for (.{ pane_token_class, instance_token_class }) |class| {
        const rendered = comptime class.shellClass();
        try testing.expect(std.mem.indexOfScalar(u8, rendered, '-') == null);
    }
    // 펼친 결과가 실제로 그 구간을 전부 담는지 — 빠뜨리면 우리가 만든 이름이 우리 가드에 걸린다.
    const pane = comptime pane_token_class.shellClass();
    try testing.expectEqualStrings("0123456789abcdef", pane);
}

test "경로 탈출은 두 칸 모두에서 막힌다 — 화이트리스트에 `/` 와 `.` 가 없다" {
    for ([_]TokenClass{ pane_token_class, instance_token_class }) |class| {
        try testing.expect(!class.accepts("")); // 빈 칸은 경로를 `//` 로 접는다
        try testing.expect(!class.accepts(".."));
        try testing.expect(!class.accepts("../outside/pwned"));
        try testing.expect(!class.accepts("1/2"));
        try testing.expect(!class.accepts("1.2"));
        try testing.expect(!class.accepts("~"));
        try testing.expect(!class.accepts("$(id)"));
        try testing.expect(!class.accepts("a\nb"));
    }
}

test "maru 가 만드는 네 가지 칸 이름은 모두 자기 가드를 통과한다" {
    // 이 단언이 «host 가 심는 이름 = 커맨드가 받는 이름» 의 첫 매듭이다. 포매터가 클래스 밖 글자를 쓰면
    // 훅은 도는데 이벤트가 0 인 상태가 되고, 그것은 진단하기 가장 나쁜 실패다.
    var ibuf: [instance_token_max]u8 = undefined;
    var pbuf: [pane_token_max]u8 = undefined;

    try testing.expect(instance_token_class.accepts(formatGuiInstance(&ibuf, 1)));
    try testing.expect(instance_token_class.accepts(formatGuiInstance(&ibuf, std.math.maxInt(u32))));
    try testing.expect(instance_token_class.accepts(formatHostInstance(&ibuf, 0)));
    try testing.expect(instance_token_class.accepts(formatHostInstance(&ibuf, std.math.maxInt(u128))));
    try testing.expect(pane_token_class.accepts(formatSurfacePane(&pbuf, 1)));
    try testing.expect(pane_token_class.accepts(formatSurfacePane(&pbuf, std.math.maxInt(u64))));
    try testing.expect(pane_token_class.accepts(formatRuntimePane(&pbuf, 0)));
    try testing.expect(pane_token_class.accepts(formatRuntimePane(&pbuf, std.math.maxInt(u128))));
}

test "인스턴스 칸은 소유자가 이름에서 읽힌다 — GUI 는 pid, host 는 host_<hex>" {
    // 사람이 캐시 디렉터리를 봤을 때 누구 것인지 알아야 하고, 시작 시 정리도 그 모양으로 «어느 방법으로
    // 살아 있는지 묻는가» 를 가른다(pid → getpgid, host_<hex> → manifest).
    var ibuf: [instance_token_max]u8 = undefined;
    try testing.expectEqualStrings("4242", formatGuiInstance(&ibuf, 4242));
    try testing.expectEqualStrings(
        "host_000000000000000000000000000000ff",
        formatHostInstance(&ibuf, 0xff),
    );
    // GUI 칸은 접두를 달지 않는다 — 두 이름공간이 섞이면 정리가 잘못된 질문을 한다.
    try testing.expect(!std.mem.startsWith(u8, formatGuiInstance(&ibuf, 4242), host_instance_prefix));
}

test "pane 칸은 host 소유일 때 32 hex 로 고정 폭이다 — 앞자리 0 을 잃으면 다른 파일이 된다" {
    var pbuf: [pane_token_max]u8 = undefined;
    const pane = formatRuntimePane(&pbuf, 0x1);
    try testing.expectEqual(@as(usize, 32), pane.len);
    try testing.expectEqualStrings("00000000000000000000000000000001", pane);
}

test "훅 경로는 control-plane selector 를 더 이상 참조하지 않는다" {
    // `MARU_PANE_ID` 는 GUI process-local surface id 이고 host 가 띄운 자식에는 실을 수 없다. 훅이 그 값을
    // 계속 보면 host-backed 터미널은 영원히 훅 모드 밖에 남는다 — 그래서 커맨드에서 그 이름을 떼어 낸다.
    const cmd = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "MARU_PANE_ID") == null);
    try testing.expect(std.mem.indexOf(u8, cmd, pane_env) != null);
    try testing.expect(std.mem.indexOf(u8, cmd, instance_env) != null);
}

test "커맨드는 추가 프로세스를 하나도 띄우지 않는다" {
    // 비용의 65%가 sh spawn이라 스크립트가 프로세스를 더 부르면 그만큼 도구 호출마다 얹힌다.
    // `cat`·`mkdir`·`head`·`tr`·`jq`는 모두 프로세스다 — 셸 내장(`read`·`printf`·`${#var}`)으로만 짠다.
    const cmd = try buildAlloc("claude", "/home/u/.cache/maru/agent-turn-events");
    defer testing.allocator.free(cmd);
    for ([_][]const u8{ "cat ", "mkdir", "head ", "tr ", "jq ", "sed ", "curl" }) |bad| {
        try testing.expect(std.mem.indexOf(u8, cmd, bad) == null);
    }
    try testing.expect(std.mem.indexOf(u8, cmd, "read -r") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "printf") != null);
}

test "stdin을 먼저 받고 나머지를 드레인한 뒤에야 가드가 온다" {
    // 가드를 먼저 두면 pane 식별자가 없는 세션에서 stdin을 안 읽고 나가 provider 파이프가 막힌다.
    const cmd = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(cmd);
    const read_at = std.mem.indexOf(u8, cmd, "read -r mh_p").?;
    const drain_at = std.mem.indexOf(u8, cmd, "while IFS= read -r mh_x").?;
    const guard_at = std.mem.indexOf(u8, cmd, "case \"$" ++ pane_env ++ "\" in").?;
    try testing.expect(read_at < drain_at);
    try testing.expect(drain_at < guard_at);
}

test "원격 pane 신원은 두 칸을 합쳐 만든다 — 인스턴스를 빼면 maru 둘이 같은 파일을 쓴다" {
    var buf: [remote_pane_nonce_max]u8 = undefined;
    var ibuf: [instance_token_max]u8 = undefined;
    var pbuf: [pane_token_max]u8 = undefined;

    const gui = formatGuiInstance(&ibuf, 4331);
    const pane = formatSurfacePane(&pbuf, 7);
    const nonce = formatRemotePaneNonce(&buf, gui, pane).?;
    try testing.expectEqualStrings("4331_7", nonce);

    // 인스턴스가 다르면 값이 다르다 — 이것이 §4 의 사고를 원격에서 막는 성질이다.
    var ibuf2: [instance_token_max]u8 = undefined;
    var buf2: [remote_pane_nonce_max]u8 = undefined;
    const other = formatRemotePaneNonce(&buf2, formatGuiInstance(&ibuf2, 9002), pane).?;
    try testing.expect(!std.mem.eql(u8, nonce, other));

    // host 소유 칸도 조립된다(접두 `host_` 와 32 hex).
    var hbuf: [instance_token_max]u8 = undefined;
    var rbuf: [pane_token_max]u8 = undefined;
    var buf3: [remote_pane_nonce_max]u8 = undefined;
    const host_nonce = formatRemotePaneNonce(&buf3, formatHostInstance(&hbuf, 0xa11ce), formatRuntimePane(&rbuf, 1)).?;
    try testing.expect(std.mem.startsWith(u8, host_nonce, "host_"));
}

test "원격 pane 신원은 경로를 벗어나는 값을 거부한다 — 그 값이 원격에서 파일 이름이 된다" {
    var buf: [remote_pane_nonce_max]u8 = undefined;
    // 빈 칸·경로 문자·대문자·너무 긴 값은 전부 null 이다.
    try testing.expect(formatRemotePaneNonce(&buf, "", "7") == null);
    try testing.expect(formatRemotePaneNonce(&buf, "4331", "") == null);
    try testing.expect(formatRemotePaneNonce(&buf, "../etc", "7") == null);
    try testing.expect(formatRemotePaneNonce(&buf, "4331", "../7") == null);
    try testing.expect(formatRemotePaneNonce(&buf, "4331", "a.b") == null);
    try testing.expect(formatRemotePaneNonce(&buf, "HOST_1", "7") == null); // 대문자
    var long: [instance_token_max + 1]u8 = undefined;
    @memset(&long, 'a');
    try testing.expect(formatRemotePaneNonce(&buf, &long, "7") == null);
}

test "maru 가 만드는 네 조합이 모두 원격 신원 조립을 통과한다" {
    var buf: [remote_pane_nonce_max]u8 = undefined;
    var ibuf: [instance_token_max]u8 = undefined;
    var pbuf: [pane_token_max]u8 = undefined;
    const instances = [_][]const u8{ formatGuiInstance(&ibuf, 1), formatHostInstance(&ibuf, 0) };
    _ = instances;
    // 버퍼 재사용을 피해 조합마다 따로 만든다.
    for ([_]u32{ 1, 99999 }) |pid| {
        var ib: [instance_token_max]u8 = undefined;
        for ([_]u64{ 1, 12345 }) |sid| {
            var pb: [pane_token_max]u8 = undefined;
            try testing.expect(formatRemotePaneNonce(&buf, formatGuiInstance(&ib, pid), formatSurfacePane(&pb, sid)) != null);
        }
    }
    for ([_]u128{ 0, 0xa11ce }) |hid| {
        var ib: [instance_token_max]u8 = undefined;
        for ([_]u128{ 0, 1 }) |rid| {
            var pb: [pane_token_max]u8 = undefined;
            try testing.expect(formatRemotePaneNonce(&buf, formatHostInstance(&ib, hid), formatRuntimePane(&pb, rid)) != null);
        }
    }
    _ = &pbuf;
}

test "원격 세트는 로컬에서 파생된다 — 부분집합이고 차이는 remote_excluded 하나뿐이다" {
    for ([_]Provider{ .claude, .codex }) |provider| {
        const local = eventsFor(provider, .local);
        const remote = eventsFor(provider, .remote);
        try testing.expect(remote.len < local.len);
        for (remote) |r| {
            var found = false;
            for (local) |l| {
                if (!std.mem.eql(u8, l.name, r.name)) continue;
                try testing.expectEqual(l.matcher == null, r.matcher == null);
                if (l.matcher) |m| try testing.expectEqualStrings(m, r.matcher.?);
                found = true;
            }
            try testing.expect(found);
        }
        for (local) |l| {
            var in_remote = false;
            for (remote) |r| {
                if (std.mem.eql(u8, l.name, r.name)) in_remote = true;
            }
            try testing.expectEqual(!isRemoteExcluded(l.name), in_remote);
        }
    }
}

test "원격 세트에 PreToolUse 가 없다 — 명령 원문과 소스코드가 네트워크를 안 건넌다" {
    for ([_]Provider{ .claude, .codex }) |provider| {
        for (eventsFor(provider, .remote)) |e| {
            try testing.expect(!std.mem.eql(u8, e.name, "PreToolUse"));
        }
        var local_has = false;
        for (eventsFor(provider, .local)) |e| {
            if (std.mem.eql(u8, e.name, "PreToolUse")) local_has = true;
        }
        try testing.expect(local_has); // 원격 축이 로컬 동작을 바꾸지 않는다
    }
}

test "원격 세트도 배지와 대화 줄에 필요한 것을 모두 갖는다" {
    const needed = [_][]const u8{ "SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "SubagentStart", "SubagentStop" };
    for ([_]Provider{ .claude, .codex }) |provider| {
        for (needed) |want| {
            var found = false;
            for (eventsFor(provider, .remote)) |e| {
                if (std.mem.eql(u8, e.name, want)) found = true;
            }
            try testing.expect(found);
        }
    }
    for ([_][]const u8{ "Notification", "StopFailure" }) |want| {
        var found = false;
        for (eventsFor(.claude, .remote)) |e| {
            if (std.mem.eql(u8, e.name, want)) found = true;
        }
        try testing.expect(found);
        for (eventsFor(.codex, .remote)) |e| try testing.expect(!std.mem.eql(u8, e.name, want));
    }
}

test "remote_excluded 의 이름은 실제 세트에 있는 것이어야 한다 — 오타는 조용히 아무것도 안 뺀다" {
    for (remote_excluded) |x| {
        var found = false;
        for ([_]Provider{ .claude, .codex }) |provider| {
            for (eventsFor(provider, .local)) |e| {
                if (std.mem.eql(u8, e.name, x)) found = true;
            }
        }
        try testing.expect(found);
    }
}

test "파생 배열이 런타임에도 제 값을 갖는다 — comptime 저장소가 승격되는지" {
    var seen: usize = 0;
    for (claude_remote_events) |e| {
        try testing.expect(e.name.len > 0);
        try testing.expect(!std.mem.eql(u8, e.name, "PreToolUse"));
        seen += 1;
    }
    try testing.expectEqual(claude_events.len - remote_excluded.len, seen);
    seen = 0;
    for (codex_remote_events) |e| {
        try testing.expect(e.name.len > 0);
        seen += 1;
    }
    try testing.expectEqual(codex_events.len - remote_excluded.len, seen);
    // 두 파생본이 같은 저장소를 가리키면 codex 가 claude 세트를 쓴다.
    try testing.expect(claude_remote_events.len != codex_remote_events.len);
}

test "max_events 는 두 스코프를 모두 담는다 — 원격이 부분집합이라 로컬 상한이 곧 상한이다" {
    for ([_]Provider{ .claude, .codex }) |provider| {
        try testing.expect(eventsFor(provider, .remote).len <= eventsFor(provider, .local).len);
    }
}

test "provider 이름을 우리가 붙인다 — payload에는 그 정보가 없다" {
    const claude = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(claude);
    const codex = try buildAlloc("codex", "/tmp/ev");
    defer testing.allocator.free(codex);
    try testing.expect(std.mem.indexOf(u8, claude, "printf 'claude\\t%s\\n'") != null);
    try testing.expect(std.mem.indexOf(u8, codex, "printf 'codex\\t%s\\n'") != null);
}

test "상한을 넘긴 payload는 표식으로 바뀐다 — 파서가 아는 그 이름이다" {
    const cmd = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, event.oversized_marker) != null);
    // 파서가 그 줄을 실제로 oversized로 읽는지까지 본다(두 모듈이 같은 이름을 쓴다는 증명).
    const line = "claude\t{\"hook_event_name\":\"" ++ event.oversized_marker ++ "\"}";
    try testing.expectEqual(event.Kind.oversized, event.parseLine(line).?.kind);
}

test "어떤 경로로 나가든 exit 0이다" {
    const cmd = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(cmd);
    // 가드 탈출도, 정상 종료도 0이어야 훅이 에이전트 턴을 물지 않는다.
    try testing.expect(std.mem.indexOf(u8, cmd, ") exit 0 ;; esac") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "; exit 0 ") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "2>/dev/null") != null);
}

test "디렉터리 경로의 따옴표가 커맨드를 깨지 않는다" {
    const cmd = try buildAlloc("claude", "/home/o'brien/.cache/maru/ev");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "'/home/o'\\''brien/.cache/maru/ev'") != null);
}

test "표식으로 우리 항목만 고른다 — 사용자 항목과 legacy는 남는다" {
    const cmd = try buildAlloc("claude", "/tmp/ev");
    defer testing.allocator.free(cmd);
    try testing.expect(isOurs(cmd));
    try testing.expect(!isLegacy(cmd));

    try testing.expect(!isOurs("my-own-hook.sh"));
    try testing.expect(!isOurs("bunx ccusage statusline"));

    // legacy 항목은 우리 것이 아니고, P1이 자동 정리를 금지했으므로 건드리지 않는다.
    const legacy = "if [ -n \"$MARU_AGENT_MAPPING_ID\" ]; then cat > x; fi # MARU_AGENT_MAP_HOOK_V2";
    try testing.expect(!isOurs(legacy));
    try testing.expect(isLegacy(legacy));
}

test "표식에 사람이 읽는 안내가 있고, 그 문구는 언어에 따라 흔들리지 않는다" {
    // 표식만 있으면 사용자가 커맨드를 복사했을 때 우리가 그것을 지운다. 그 사고를 막는 것은 문장뿐이다.
    try testing.expect(std.mem.indexOf(u8, marker_comment, "maru") != null);
    try testing.expect(std.mem.indexOf(u8, marker_comment, "do not copy") != null);
    try testing.expect(std.mem.startsWith(u8, marker_comment, "# "));
    // **ASCII 고정**: 커맨드 바이트가 UI 언어를 타면 Codex trusted_hash 가 깨져 언어 변경만으로 재승인이 뜬다.
    for (marker_comment) |c| try testing.expect(c < 0x80);
}

test "이벤트 세트는 계약 §2 그대로다 — provider 마다" {
    // 6 → 9: `StopFailure`(오류로 끝난 턴) + `SubagentStart`/`SubagentStop`(자식 세기).
    try testing.expectEqual(@as(usize, 9), claude_events.len);
    // codex 에는 `Notification` 이 없다(계약 §2.1 실측).
    // 5 → 7: 서브에이전트 둘. `StopFailure` 는 codex 열거에 없어 더하지 않는다.
    try testing.expectEqual(@as(usize, 7), codex_events.len);
    for (codex_events) |e| try testing.expect(!std.mem.eql(u8, e.name, "Notification"));
    for (codex_events) |e| try testing.expect(!std.mem.eql(u8, e.name, "StopFailure"));
    // codex 세트는 claude 세트의 **부분집합**이어야 한다(이름도 matcher 도) — 두 세트가 따로 흘러가면
    // provider 마다 다른 상태가 된다.
    for (codex_events) |c| {
        var found = false;
        for (claude_events) |cl| {
            if (std.mem.eql(u8, c.name, cl.name)) {
                try testing.expectEqual(cl.matcher == null, c.matcher == null);
                if (cl.matcher) |m| try testing.expectEqualStrings(m, c.matcher.?);
                found = true;
            }
        }
        try testing.expect(found);
    }

    for ([_]Provider{ .claude, .codex }) |provider| {
        const set = eventsFor(provider, .local);
        var star: usize = 0;
        for (set) |e| {
            if (e.matcher) |m| {
                try testing.expectEqualStrings("*", m);
                star += 1;
            }
        }
        // matcher가 붙는 것은 도구 이벤트 둘뿐이다(PermissionRequest·PreToolUse).
        try testing.expectEqual(@as(usize, 2), star);
        // PostToolUse는 세트에 없다 — payload가 originalFile을 실어 큰 파일 편집에서 상한에 잘린다(계약 §3.1).
        for (set) |e| try testing.expect(!std.mem.eql(u8, e.name, "PostToolUse"));
        // **이름이 겹치면 안 된다.** 겹치면 설치가 그 이벤트에 항목을 둘 넣는데, 설치 판정은 이벤트를 «덮었나»로
        // 세므로 「우리 항목 수 = 세트 크기」가 영영 맞지 않는다 → 시작할 때마다 사용자 파일을 다시 쓴다
        // (`agent_hook_install.planFor`의 마지막 검사). 손으로 보면 안 보이는 종류의 실수라 여기서 막는다.
        for (set, 0..) |a_ev, i| {
            for (set[i + 1 ..]) |b_ev| {
                try testing.expect(!std.mem.eql(u8, a_ev.name, b_ev.name));
            }
        }
        // 표식은 파서가 인정하는 이름이어야 한다 — 아니면 훅이 적은 줄을 우리가 못 읽는다.
        try testing.expect(event.looksLikeProvider(provider.tag()));
    }
}

test "커맨드 구조가 셸 게이트가 검증한 그 모양이다" {
    // `tools/check-agent-hook-command.sh` 가 실제 `/bin/sh` 로 돌려 계약 6개를 보는 fixture
    // (`tests/golden/agent_hook_command.sh`)와 **같은 구조**여야 한다. 파일을 직접 비교하지 못하는 것은
    // `@embedFile` 이 패키지 경로 밖을 못 읽기 때문이고, 대신 ⑴ 여기서 구조 불변식을 고정하고 ⑵ 셸 게이트가
    // 표식 버전으로 fixture 의 신선도를 본다. 두 검사가 만나는 지점이 `marker` 다.
    const cmd = try buildAlloc("claude", "__LOG_DIR__");
    defer testing.allocator.free(cmd);
    // 리다이렉션 실패까지 삼키는 그룹으로 감쌌는지 — 감싸지 않으면 디렉터리가 없을 때 셸 에러가
    // provider 화면으로 샌다(실측으로 잡은 결함).
    try testing.expect(std.mem.indexOf(u8, cmd, "{ printf ") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "; } 2>/dev/null;") != null);
    // fixture 가 치환하는 자리표시자가 그대로 있는지.
    try testing.expect(std.mem.indexOf(u8, cmd, "'__LOG_DIR__'") != null);
    try testing.expect(std.mem.endsWith(u8, cmd, marker_comment));
    // 권한을 **가장 먼저** 좁힌다 — 뒤에 두면 그 사이에 만들어진 파일이 넓은 권한으로 남는다.
    try testing.expect(std.mem.startsWith(u8, cmd, "umask 077; "));

    // **payload 를 커맨드라인에 올리지 않는다**(계약 §4.1). argv 에 실으면 같은 머신의 다른 프로세스가
    // `ps` 로 읽고 보안 제품이 그 명령줄을 수집·저장한다 — 그 안에는 소스 코드와 셸 명령 원문이 있다(§7).
    // payload 는 stdin 으로 받아 변수에 담고(`read -r mh_p`) `printf` 의 **인자로 확장**된다. 그 확장은
    // 우리 프로세스 안에서 일어나므로 커맨드 문자열 자체에는 값이 없다 — 여기서 보는 것은 «커맨드에 값을
    // 박는 모양이 아니다» 이고, 그 모양이면 반드시 `$mh_p` 같은 참조로만 나타난다.
    try testing.expect(std.mem.indexOf(u8, cmd, "read -r mh_p") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "\"$mh_p\"") != null);
}

test "커맨드가 쓴 줄을 파서가 읽는다 — 형식이 두 곳에 따로 적히면 조용히 깨진다" {
    // 셸 게이트는 «파일에 이 모양으로 적혔다» 까지 보고, 파서 테스트는 «이 모양을 읽는다» 를 본다.
    // 그 사이가 비면 형식 드리프트가 «모든 이벤트가 파싱 실패» 로만 드러난다. 여기서 양쪽을 잇는다.
    const cmd = try buildAlloc("codex", "/tmp/ev");
    defer testing.allocator.free(cmd);
    // 커맨드가 만드는 줄 모양: <provider><구분자><payload>
    try testing.expect(std.mem.indexOf(u8, cmd, "printf 'codex\\t%s\\n'") != null);

    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(testing.allocator);
    try line.appendSlice(testing.allocator, "codex");
    try line.append(testing.allocator, event.field_separator);
    try line.appendSlice(testing.allocator, "{\"hook_event_name\":\"Stop\"}");
    const ev = event.parseLine(line.items).?;
    try testing.expectEqualStrings("codex", ev.provider);
    try testing.expectEqual(event.Kind.stop, ev.kind);
}

test "payload 상한이 줄 상한을 넘기지 않는다 — 경계에서만 나는 유실이다" {
    // 훅이 적는 줄은 `<provider><구분자><payload>` 다. payload 상한을 줄 상한과 같게 두면 접두만큼 길어져
    // 커맨드는 통과시키고 **파서가 버린다**. 그 유실은 딱 경계에서만 나타나 눈에 안 띈다.
    const longest_prefix = event.max_provider_len + 1; // 이름 + 구분자
    try testing.expect(max_payload_bytes + longest_prefix <= event.max_line_bytes);

    // 실제로 상한 크기의 payload 로 만든 줄이 파서의 상한 안에 드는지 본다.
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(testing.allocator);
    try line.appendSlice(testing.allocator, "mimo-code"); // 우리가 아는 이름 중 긴 편
    try line.append(testing.allocator, event.field_separator);
    try line.appendSlice(testing.allocator, "{\"hook_event_name\":\"Stop\",\"pad\":\"");
    while (line.items.len < max_payload_bytes) try line.append(testing.allocator, 'x');
    try line.appendSlice(testing.allocator, "\"}");
    try testing.expect(line.items.len <= event.max_line_bytes);
    try testing.expect(event.parseLine(line.items) != null);
}

test "세트의 모든 이벤트를 파서가 안다 — 한쪽만 늘면 그 이벤트가 조용히 unknown 이 된다" {
    // 세트(여기)와 `Kind`(파서)는 따로 적혀 있다. 이벤트를 하나 더 걸고 파서에 넣는 것을 잊으면 그 이벤트는
    // 로그에 쌓이면서 `unknown` 으로만 읽혀, 소비자가 «아무 일도 없었다» 와 구분하지 못한다.
    // 두 세트를 합쳐 본다 — provider 하나만 보면 다른 쪽에만 있는 이벤트가 빠진다.
    for (claude_events ++ codex_events) |e| {
        var line: std.ArrayListUnmanaged(u8) = .empty;
        defer line.deinit(testing.allocator);
        try line.appendSlice(testing.allocator, "claude");
        try line.append(testing.allocator, event.field_separator);
        try line.print(testing.allocator, "{{\"hook_event_name\":\"{s}\"}}", .{e.name});
        const ev = event.parseLine(line.items) orelse {
            // 진단 메시지는 영어로 둔다 — CI 로그를 사람과 스크립트가 함께 읽고, 원장(§7.2)을 늘리지 않는다.
            std.debug.print("\nhook event in the set failed to parse: {s}\n", .{e.name});
            return error.TestUnexpectedResult;
        };
        if (ev.kind == .unknown) {
            std.debug.print("\nset has an event the parser does not know: {s}\n", .{e.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "타임아웃이 실측 비용보다 넉넉하되 턴을 물지 않을 만큼 짧다" {
    // 기본값에 맡기면 provider 가 그 기본을 바꿀 때 우리 훅이 조용히 길어진다. 값이 없는 것 자체가 결함이라
    // 여기서 «있다» 와 «범위» 를 함께 고정한다.
    try testing.expect(timeout_seconds >= 1); // 실측 12.27 ms 의 80배 이상
    try testing.expect(timeout_seconds <= 5); // 이보다 길면 사용자가 멈춤을 체감한다
}

test "provider 이름이 줄을 깨뜨릴 수 있으면 거절한다" {
    // 이 값은 줄 앞에 그대로 적힌다 — 탭이면 구분자가 둘이 되고 개행이면 줄이 둘로 갈린다. 그런 이름으로
    // 커맨드를 만들면 **그 provider 의 모든 이벤트가 조용히 파싱 실패**한다.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.InvalidProvider, build(&out, testing.allocator, "cl\taude", "/tmp/ev"));
    try testing.expectError(error.InvalidProvider, build(&out, testing.allocator, "cl\naude", "/tmp/ev"));
    try testing.expectError(error.InvalidProvider, build(&out, testing.allocator, "", "/tmp/ev"));
    try testing.expectError(error.InvalidProvider, build(&out, testing.allocator, "Claude", "/tmp/ev"));

    // 우리가 쓰는 이름은 통과한다.
    out.clearRetainingCapacity();
    try build(&out, testing.allocator, "claude", "/tmp/ev");
    try testing.expect(out.items.len > 0);
}
