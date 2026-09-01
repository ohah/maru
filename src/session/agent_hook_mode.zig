//! 훅 모드 판정과 상태 전이(L2 순수, I/O 없음).
//!
//! 계약의 단일 출처는 [docs/agent-hooks.md](../../docs/agent-hooks.md) §1.2(모드 판정)와 §4(상태 소비)다.
//! 파일 읽기·tick 배선은 platform 이 한다.
//!
//! **두 모드를 섞지 않는 것이 이 층의 존재 이유다.** 한 Term 의 상태가 두 소스에서 오면 어느 쪽이 맞는지
//! 아무도 모르는 상태가 되고, 그 증상은 «배지가 가끔 틀림» 이라 재현도 안 된다. 그래서 «어느 모드인가» 를
//! 값으로 들고 다니며, 소비자는 그 값으로만 갈린다.

const std = @import("std");
const event = @import("agent_hook_event.zig");
const transcript = @import("agent_transcript.zig");

/// 이 Term 의 상태·알림이 **어디서 오는가**.
pub const Mode = enum {
    /// 화면·OSC 를 읽는다(지금까지의 동작). 훅이 없거나, 있어도 아직 한 번도 돌지 않았다.
    observe,
    /// 훅 payload 만 쓴다. 이 Term 에서는 OSC 9/777 알림 drain 과 `agent_observer` 입력을 쓰지 않는다.
    hook,
};

/// platform 이 채우는 관측치. **이 층은 파일을 열지 않는다.**
pub const Probe = struct {
    /// config 게이트(`sidebar.agent-hooks`)가 켜져 있는가.
    gate_on: bool = false,
    /// 그 pane 의 이벤트 로그가 **있는가**. 훅이 한 번이라도 돌았다는 뜻이다(계약 §1.2).
    log_present: bool = false,
    /// 그 Term 에 에이전트가 붙어 있는가(`agent_kind != .none`). 에이전트가 없으면 모드를 논할 것도 없다.
    agent_present: bool = false,
    /// **원격 이벤트 채널이 열려 있는가**([계획](../../docs/plans/remote-agent-state.md) RA5).
    ///
    /// ssh 너머는 `agent_kind` 가 `none` 이라(로컬에서 원격 process tree 가 안 보인다) `agent_present` 로는
    /// 영영 훅 모드가 안 된다 — 계약 §11.1 이 적은 그 세 겹 중 첫째다. 그런데 **채널이 열렸다는 것 자체가
    /// «저 너머에 에이전트가 있고 훅이 돈다» 는 증거**다: 그 채널은 훅이 쓴 파일을 흘리는 길이고, 파일이
    /// 없으면 이벤트가 아예 안 온다. 그래서 원격에서는 이 값이 `agent_present` 를 대신한다.
    ///
    /// **로컬 판정을 안 건드린다.** 이 값이 `false` 면 예전과 바이트가 같다.
    remote_channel_open: bool = false,
};

/// 지금 이 Term 이 어느 모드인가. **파일 유무로 판정한다** — 이벤트 개수로 잡으면 가만히 있는 세션이
/// 강등되고, 시간으로 잡으면 이미 돌던 세션이 강등된다(계약 §1.2의 두 함정).
pub fn modeFor(probe: Probe) Mode {
    // **원격 축**: 채널이 열렸으면 그것이 곧 «훅이 돈다» 는 증거다(RA5). 로컬 로그 파일도
    // `agent_kind` 도 이 경우엔 원리적으로 얻을 수 없다(계약 §11.1).
    if (probe.remote_channel_open) return if (probe.gate_on) .hook else .observe;
    if (!probe.agent_present) return .observe;
    if (!probe.gate_on) return .observe;
    return if (probe.log_present) .hook else .observe;
}

/// 사이드바 배지가 쓰는 상태. **관측 모드와 같은 열거를 그대로 쓴다**(복사하지 않는다) — 두 소스가 같은
/// 자리에 같은 모양으로 그려야 하고(계약 §1), 열거를 따로 두면 «배지가 소스마다 다른 값» 이라는 드리프트가
/// 생긴다. 그 어긋남은 화면에서만 드러나 재현도 어렵다.
///
/// 의미 대응: `running` = 턴이 돌고 있다, `blocked` = 승인 대기(관측 모드의 `permission_prompt`·
/// `plan_approval` 규칙이 잡던 그 상태), `idle` = 턴이 끝났다.
pub const State = @import("agent_observer.zig").State;

/// 훅 이벤트로 상태를 옮긴다. **`Stop` 은 «완료» 가 아니라 «턴 끝» 이다**(계약 §2) — 사용자가 중단한 턴도
/// `Stop` 으로 온다.
///
/// `stop_hook_active` 가 참인 `Stop` 은 **턴 종료로 세지 않는다**(서브에이전트·백그라운드로 재발화한다).
///
/// **`background_tasks` 는 여기서 보지 않는다** — 자식 때문에 붙잡는 일은 `advance` 가 자기 로스터로
/// 단독으로 한다(계약 §2). 「이벤트 하나 → 상태」 만 보는 순수 전이로 남긴다.
pub fn next(current: State, ev: event.Event) State {
    // **자식 이벤트는 부모 상태를 옮기지 않는다**(계약 §2). 서브에이전트 활동은 `agent_id` 를 실은
    // 이벤트로 따로 오는데, 그것을 그대로 부모에 먹이면 자식이 도구를 부를 때마다 부모가 «진행 중» 이
    // 되고 자식이 끝날 때 부모가 «완료» 가 된다 — 부모의 턴과 무관하게 배지가 춤춘다.
    if (ev.agent_id.len != 0) return current;

    return switch (ev.kind) {
        // 세션이 시작됐다. 아직 턴이 없으므로 «대기» 다.
        .session_start => .idle,
        .user_prompt_submit => .running,
        .pre_tool_use => .running,
        .permission_request => .blocked,
        // **오류로 끝난 턴**(계약 §2). provider 가 `Stop` **대신** 보내므로, 이것을 안 받으면 그 pane 은
        // 영영 «진행 중» 에 멈춘다. 끝은 끝이라 같은 전이를 쓴다 — 문구만 알림에서 갈린다.
        .stop_failure => .idle,
        .stop => blk: {
            if (ev.stop_hook_active) break :blk current; // 재발화 — 턴이 끝난 것이 아니다
            // **`background_tasks` 는 여기서 보지 않는다**(2026-08-23 결정). 예전에는 그 목록에 `running`
            // 이 하나라도 있으면 «턴은 끝났으나 작업이 도는 중» 이라며 붙잡았는데, 그 셈이 `type` 을 안
            // 가려 **셸 백그라운드 작업까지** 붙잡았다. 그런데 셸 작업에는 `SubagentStop` 같은 **푸는
            // 이벤트가 없다** — 그래서 `run_in_background` 하나만 띄워 두면 그 pane 의 완료 알림이 그
            // 작업이 끝날 때까지 **한 건도** 안 나갔다(실측). 붙잡는 일은 `advance` 가 자기 로스터로
            // 단독으로 하고, 이 목록은 §2 대로 **거두는 데만** 쓴다.
            break :blk .idle;
        },
        // **아는 종류만 옮긴다**(계약 §6). claude 의 `notification_type` 은 열넷이고 그중 «사용자 입력을
        // 기다린다» 는 다섯만 배지를 옮긴다 — 나머지(유휴 알림·인증 성공·쿼터 재개 등)와 종류를 모르는
        // 알림은 상태를 흔들지 않는다. 그러지 않으면 **임의의 provider 알림이 「입력 대기」로 보인다.**
        //
        // 이 자리가 필요한 이유: 「입력 대기」의 다른 소스인 `PermissionRequest` 는 우리 실측에서 **한 번도
        // 발화하지 않았다**(헤드리스에서는 권한이 실제로 거부돼도 안 온다 — §9-6). 그것 하나에만 걸어 두면
        // 대화형에서도 안 올 경우 그 배지에 **소스가 하나도 없다**. 독립적인 둘을 둔다.
        .notification => switch (ev.notification_type) {
            .needs_input => .blocked,
            .none, .other => current,
        },
        // 서브에이전트 수명은 **여기서 다루지 않는다** — 세는 일이라 진행 상태가 필요하고, 그것은
        // `advance` 가 소유한다. `next` 는 «이벤트 하나 → 상태» 만 보는 순수 전이로 남긴다.
        .subagent_start, .subagent_stop => current,
        // 상한을 넘겨 접힌 이벤트와 모르는 이벤트는 **상태를 흔들지 않는다** — 내용을 모르는 채로 옮기면
        // 배지가 틀린 값에 고정된다.
        .oversized, .unknown => current,
    };
}

/// 한 턴의 진행 상태. **자식이 몇이나 도는지**와 **lead 가 이미 끝났는지**를 든다.
///
/// 왜 필요한가(계약 §2): 서브에이전트가 도는 동안 lead 의 `Stop` 은 턴 끝이 아니다. 그것을 완료로 다루면
/// **자식이 아직 도는데 «완료» 알림이 나간다.** 반대로 lead `Stop` 에서 무작정 «진행 중» 을 유지하면 이번엔
/// 배지가 안 풀린다 — 자식이 끝나는 것을 봐야 풀 수 있고, 그래서 **세야** 한다.
/// 자식 하나의 자리. **id 전문을 담지 않고 해시만 담는다** — 우리가 하는 일은 «같은가» 비교뿐이고,
/// 되읽거나 표시하지 않는다. 전문(claude 17 자·codex uuid 36 자)을 담으면 자리당 40 바이트라
/// 동시 자식 수 상한을 낮게 잡을 수밖에 없는데, **그 상한이 곧 조기 해제 버그의 재발 지점**이다:
/// 넘친 자식은 종료를 못 알아보므로, 담긴 것들이 끝나는 순간 아직 도는 자식을 두고 배지가 풀린다.
/// 8 바이트면 상한을 넉넉히 올릴 수 있다.
///
/// 충돌은 64 비트 해시에 자식 수십 개라 실질적으로 없다(있어도 «남의 종료가 우리 자식을 지우는»
/// 조기 해제 한 번이고, 다음 프롬프트가 정정한다).
pub const ChildKey = u64;

/// 한 턴에 동시에 담을 자식 수. **워크플로가 자식을 크게 펼치는 경우까지 본다** — 손으로 8 을 잡았다가
/// 「100 개 넘어가면 어쩌냐」는 지적을 받고 올렸다. 자리당 8 바이트라 Term 하나에 1 KiB 다.
///
/// 그래도 넘칠 수는 있다. 그때는 담지 못한 자식이 배지를 붙잡지 못한다 — 조기 해제 쪽으로 기울지만
/// 다음 프롬프트가 셈을 버려 정정한다. 반대쪽(안 풀림)은 사용자가 손쓸 수 없으므로 이 방향을 고른다.
pub const max_children: usize = 128;

/// id 를 자리 키로 만든다. 빈 id 는 키가 될 수 없다(호출자가 먼저 거른다).
fn childKey(id: []const u8) ChildKey {
    return std.hash.Wyhash.hash(0, id);
}

pub const Progress = struct {
    /// 지금 도는 자식들의 `agent_id`.
    ///
    /// **개수로 세면 안 된다**(2026-08-21 실사용이 뒤집었다). claude 는 우리가 시작을 본 적 없는
    /// 내부 에이전트의 `SubagentStop` 도 보낸다 — 한 턴에서 `SubagentStart` 는 하나였는데
    /// `SubagentStop` 이 **다섯 개의 서로 다른 `agent_id`** 로 왔고, 그중 우리 것의 짝은 **맨 마지막**
    /// 이었다. 개수를 세면 남의 첫 종료에서 이미 0 이 되어 **자식이 도는데 배지가 풀린다**.
    ///
    /// 그래서 **우리가 시작을 본 id 만** 담고, 그 id 의 종료에만 반응한다. 짝 없는 종료는 남의 것이라
    /// 무시한다.
    children: [max_children]ChildKey = @splat(0),
    child_count: u8 = 0,
    /// **lead 의 턴이 아직 열려 있는가.** 프롬프트·도구 호출처럼 lead 가 «돌고 있다» 를 뜻하는 이벤트가
    /// 열고, lead 의 `Stop`/`StopFailure` 가 닫는다.
    ///
    /// 왜 «lead 가 끝났다» 가 아니라 «열려 있다» 인가: 마지막 자식이 끝났을 때 배지를 풀지 말지는
    /// **lead 가 아직 일하는가** 로 갈린다. 「끝났다」 플래그로 물으면 «아직 시작도 안 했다» 와
    /// «이미 끝났다» 가 같은 값(거짓)이 되어, 대기 상태에 자식 한 쌍이 오면 배지가 «진행 중» 에
    /// 갇힌다(전수 탐색이 그 자리를 짚었다 — `SubagentStart` 는 `running` 으로 밀고, 이어진
    /// `SubagentStop` 은 풀어 줄 근거가 없어 그대로 둔다). 「열려 있다」 로 물으면 그 둘이 갈린다.
    turn_open: bool = false,
    /// 지금 보고 있는 턴의 식별자(claude `prompt_id` / codex `turn_id`). 빈 값 = 아직 못 봤다.
    ///
    /// 왜 드나: 턴 리셋의 유일한 신호가 `UserPromptSubmit` 이면 **그 줄이 유실될 때** 지난 턴의 자식
    /// 셈이 새 턴으로 넘어와 lead 의 `Stop` 이 붙잡힌다 — 안 풀리는 배지다. 줄 유실은 가정이 아니라
    /// 계약이 감당하기로 한 것이다(§4.3 동시 append·상한 초과). 키가 바뀌는 것 자체가 **두 번째,
    /// 독립적인** 턴 경계 신호라 그 구멍을 메운다.
    turn_buf: [64]u8 = undefined,
    turn_len: usize = 0,
    /// lead 의 턴이 **오류로** 끝났다. 알림 문구가 여기서 갈린다.
    ///
    /// 왜 상태에 드나: 자식이 남아 있으면 턴 끝 전이가 `StopFailure` 가 아니라 **마지막 `SubagentStop`**
    /// 에서 일어난다. 그 순간의 이벤트만 보면 오류였다는 사실이 사라져 «턴이 끝났습니다» 가 나간다.
    lead_failed: bool = false,

    pub fn reset(self: *Progress) void {
        // **턴 키는 남긴다.** 이것은 «지금 어느 턴인가» 라는 사실이지 그 턴의 진행 상태가 아니다.
        // 함께 지우면 같은 턴의 다음 이벤트가 «키가 바뀌었다» 로 읽혀 매번 리셋이 돈다.
        const key = self.turnKey();
        var buf: [64]u8 = undefined;
        @memcpy(buf[0..key.len], key);
        const n = key.len;
        self.* = .{};
        @memcpy(self.turn_buf[0..n], buf[0..n]);
        self.turn_len = n;
    }

    pub fn childCount(self: *const Progress) usize {
        return self.child_count;
    }

    /// 자식을 담는다. **같은 id 를 두 번 담지 않는다** — provider 가 같은 시작을 두 번 보내도(재동기화·
    /// 배치 재처리) 셈이 부풀지 않게.
    ///
    /// `id` 가 비어 있으면 담지 않는다. 담을 수 없는 자식을 «돈다» 고 붙잡으면 그 종료를 영영 못 알아봐
    /// 배지가 안 풀린다 — 이 층이 막으려는 바로 그 실패다. 실측에서는 수명 이벤트가 늘 `agent_id` 를
    /// 싣고 오므로 이 경로는 방어다.
    fn addChild(self: *Progress, id: []const u8) void {
        if (id.len == 0) return;
        const key = childKey(id);
        for (self.children[0..self.child_count]) |c| {
            if (c == key) return;
        }
        if (self.child_count >= max_children) return;
        self.children[self.child_count] = key;
        self.child_count += 1;
    }

    /// **우리가 시작을 본 자식**이면 빼고 `true`. 아니면 아무것도 안 하고 `false` — 남의 에이전트다.
    fn removeChild(self: *Progress, id: []const u8) bool {
        if (id.len == 0) return false;
        const key = childKey(id);
        var i: usize = 0;
        while (i < self.child_count) : (i += 1) {
            if (self.children[i] != key) continue;
            self.children[i] = self.children[self.child_count - 1];
            self.child_count -= 1;
            return true;
        }
        return false;
    }

    /// **목록에 없는 자식을 거둔다.** `live` 는 지금 도는 서브에이전트 id 들이다.
    ///
    /// 왜 필요한가: 우리가 붙잡는 근거는 «시작을 봤다» 인데, 그 종료를 못 볼 수 있다 — 줄이 유실되거나
    /// (§4.3 동시 append), 담을 자리가 없었거나, 상한을 넘겼거나. 그러면 그 자식은 **유령**이 되어 배지를
    /// 영영 붙잡는다. provider 가 실어 주는 목록이 그 유령을 정리해 준다.
    ///
    /// ⚠️ 호출자가 **목록이 완전할 때만** 부른다. 잘리거나 어긋난 목록으로 거두면 살아 있는 자식을
    /// 지운다 — 이 층이 막으려는 조기 해제 그 자체다.
    fn reapMissing(self: *Progress, live: []const []const u8) void {
        var i: usize = 0;
        while (i < self.child_count) {
            var found = false;
            for (live) |id| {
                if (childKey(id) == self.children[i]) {
                    found = true;
                    break;
                }
            }
            if (found) {
                i += 1;
                continue;
            }
            self.children[i] = self.children[self.child_count - 1];
            self.child_count -= 1;
            // 자리를 당겨 왔으므로 `i` 는 그대로 두고 다시 본다.
        }
    }

    pub fn turnKey(self: *const Progress) []const u8 {
        return self.turn_buf[0..self.turn_len];
    }

    /// 이 키가 **새 턴**인가. 빈 키는 판정하지 않는다(그 provider·이벤트가 안 주는 것이지 바뀐 것이 아니다).
    fn adoptTurn(self: *Progress, key: []const u8) bool {
        if (key.len == 0 or key.len > self.turn_buf.len) return false;
        if (std.mem.eql(u8, self.turnKey(), key)) return false;
        const had = self.turn_len != 0;
        @memcpy(self.turn_buf[0..key.len], key);
        self.turn_len = key.len;
        // 처음 본 키는 «바뀐 것» 이 아니다 — 훅을 이미 돌던 세션에 붙였을 뿐이다.
        return had;
    }

    /// 이번 턴이 오류로 끝났는지 **가져가며 지운다**. 지우지 않으면 다음 턴의 정상 종료까지 «오류» 라
    /// 부른다 — 안 풀리는 배지와 같은 부류의 실패다.
    pub fn takeFailed(self: *Progress) bool {
        defer self.lead_failed = false;
        return self.lead_failed;
    }
};

/// 이 이벤트가 **lead 의 턴 진행**을 뜻하는가. 턴 셈(자식·턴 키·턴 문)을 건드려도 되는지의 단일 기준이다.
///
/// 둘을 뺀다.
/// - **자식 이벤트**(`agent_id` 가 있다) — 자식의 활동은 부모의 턴이 아니다.
/// - **`Notification`** — 그것은 「lead 가 일한다」가 아니라 「누군가 입력을 기다린다」다. 그리고 실측상
///   claude 의 알림은 공통 payload 를 **에이전트 인자 없이** 만들어, 자식의 승인 요구도 `agent_id` 가 빈 채
///   lead 처럼 도착한다(2026-08-22 생성부 대조 — `PermissionRequest` 는 그 인자를 넘긴다). 그래서 그것으로
///   턴을 세면 **자식의 사정이 부모의 턴 셈을 흔든다.**
///
/// **한 이름으로 묶어 둔다.** 이 규칙을 조건마다 손으로 되풀이하면 다음에 자리를 하나 더할 때 잊는다 —
/// 실제로 잊었고, 턴 문과 턴 키 두 자리에서 각각 «안 풀리는 배지» 와 «지워지는 자식 셈» 이 나왔다.
/// 그래서 **턴 셈을 만지는 자리는 전부 이것을 지난다**(리셋·오류 표시·턴 문·턴 키·회수). 지금은 뒤의
/// 셋이 종류로도 걸러져 결과가 같지만, 같은 규칙을 두 모양으로 적어 두면 그 «같음» 이 언제 깨지는지
/// 아무도 안 본다.
fn marksTurnProgress(ev: event.Event) bool {
    return ev.agent_id.len == 0 and ev.kind != .notification;
}

/// 이벤트를 진행 상태에 반영하고 **그 뒤의 배지 상태**를 돌려준다. 기본 전이는 `next` 가 하고, 여기서는
/// 자식 때문에 달라지는 부분만 얹는다.
pub fn advance(progress: *Progress, current: State, ev: event.Event) State {
    switch (ev.kind) {
        .subagent_start => {
            progress.addChild(ev.agent_id);
            // 자식이 떴다 = 무언가 돌고 있다. lead 가 이미 `Stop` 을 보냈어도 턴은 안 끝났다.
            //
            // **다만 «막힘» 은 덮지 않는다.** 병렬 워커 턴에서는 하나가 승인 게이트에 걸린 채 다른 하나가
            // 뜬다(그 요구는 `agent_id` 없이 lead 로 온다 — §6). 「돈다」로 덮으면 **사용자가 할 일이 있다는
            // 신호만 골라 사라진다.** 둘 다 참일 때 무엇을 보일지는 관측 모드가 이미 정해 두었다 —
            // `visible_blocker` 가 최우선이다([agent-session.md](../../docs/agent-session.md) «해석»).
            // 배지 열거를 공유하듯 그 우선순위도 공유한다.
            return if (current == .blocked) current else .running;
        },
        .subagent_stop => {
            // **우리가 시작을 본 자식일 때만** 반응한다. claude 는 알린 적 없는 내부 에이전트의
            // 종료도 보내므로(실측), 그것을 우리 자식의 종료로 세면 자식이 도는 중에 배지가 풀린다.
            if (!progress.removeChild(ev.agent_id)) return current;
            // **마지막 자식이 끝났는데 lead 의 턴도 안 열려 있으면** 그때가 진짜 턴 끝이다. lead 가
            // 아직 일하는 중이면(턴이 열려 있으면) 자식이 다 끝나도 턴은 안 끝났다.
            if (progress.child_count == 0 and !progress.turn_open) return .idle;
            return current;
        },
        else => {},
    }

    // **턴 키가 바뀌었으면 그것만으로 새 턴이다**(실측: claude `prompt_id`·codex `turn_id` 가 한 턴의
    // 모든 lead 이벤트에 같은 값으로 실린다). `UserPromptSubmit` 이 유실돼도 이 신호가 남는다.
    // 자식 이벤트는 보지 않는다 — codex 의 자식은 **자기 turn_id** 를 싣고 오므로(실측) 그것을 부모의
    // 턴 변화로 읽으면 자식이 뜰 때마다 셈이 초기화된다.
    // **알림은 여기서도 빼놓는다**(§6). 그것은 턴 진행의 증거가 아닌데 공통 payload 를 타고 `prompt_id` 를
    // 싣고 온다 — 지난 턴의 워커 승인 요구가 늦게 도착하면 «턴 키가 바뀌었다» 로 읽혀 **이번 턴의 자식
    // 셈이 지워지고** lead 의 `Stop` 이 자식을 안 기다린다. 잃는 것은 없다: 턴을 실제로 옮기는 이벤트는
    // 모두 그 키를 싣는다.
    if (marksTurnProgress(ev) and progress.adoptTurn(ev.turn_key)) progress.reset();

    // 새 턴이 시작되면 지난 턴의 셈을 버린다 — 안 버리면 한 번 어긋난 수가 영영 남는다.
    // **새 세션도 마찬가지다.** 같은 pane 에서 에이전트를 다시 띄우면(또는 다른 provider 로 바꾸면)
    // 지난 세션의 자식은 이미 없다. 놓친 `SubagentStop` 하나가 세션을 건너뛰어 따라오지 않게 한다.
    if (marksTurnProgress(ev) and (ev.kind == .user_prompt_submit or ev.kind == .session_start))
        progress.reset();

    const base = next(current, ev);

    // lead 의 턴이 끝났는데 자식이 남아 있으면 **완료로 단정하지 않는다**. 그 사실을 기억해 두었다가
    // 마지막 자식이 끝날 때 푼다(위 `.subagent_stop`).
    if (marksTurnProgress(ev) and ev.kind == .stop_failure) progress.lead_failed = true;

    // **lead 가 돌고 있다는 신호가 턴을 연다.** 프롬프트만 보고 열면, 훅을 이미 돌던 세션에 붙인 경우
    // (첫 이벤트가 도구 호출인 경우)에 턴이 영영 안 열린 것으로 보여 자식이 끝나는 순간 **아직 일하는
    // lead 를 완료로 단정한다**. 그래서 `running`·`blocked` 로 가는 lead 이벤트를 모두 문으로 삼는다.
    //
    // **`Notification` 만 뺀다.** 그것은 「lead 가 일한다」가 아니라 「누군가 입력을 기다린다」는 신호이고,
    // 실측상 **에이전트 문맥을 안 싣는다** — claude 의 알림 생성부는 공통 payload 를 에이전트 인자 없이
    // 부르므로 `worker_permission_prompt` 도 `agent_id` 가 빈 채 **lead 이벤트로** 도착한다
    // (`PermissionRequest` 는 그 인자를 넘겨 자식 것이 자식으로 온다 — 2026-08-22 생성부 대조).
    // 그래서 이것으로 턴을 열면 **lead 가 이미 `Stop` 을 보낸 뒤 자식이 승인을 요구한 순간 턴이 되살아나고**,
    // 마지막 자식이 끝나도 «턴이 안 끝났다» 가 되어 배지가 영영 «입력 대기» 에 멈춘다.
    if (marksTurnProgress(ev) and (base == .running or base == .blocked)) progress.turn_open = true;

    // lead 의 턴이 끝났는데 자식이 남아 있으면 **완료로 단정하지 않는다**. 턴을 닫아 두었다가 마지막
    // 자식이 끝날 때 푼다(위 `.subagent_stop`).
    if (marksTurnProgress(ev) and (ev.kind == .stop or ev.kind == .stop_failure)) {
        progress.turn_open = false;
        // **여기서 유령을 거둔다**(계약 §2). lead 의 턴 끝은 목록이 가라앉은 자리이고, 붙잡을지 말지를
        // 정하기 **직전**이라 그 판단이 최신 사실 위에서 이뤄진다. 다른 이벤트에서는 거두지 않는다 —
        // 자식이 막 떴는데 목록이 아직 그것을 안 실은 순간에 거두면 살아 있는 자식을 지운다.
        var live: [max_children][]const u8 = undefined;
        const tally = event.liveSubagentIds(ev.background_tasks_raw, &live);
        // **완전할 때만 근거로 쓴다.** 잘리거나 어긋난 목록은 진실의 일부일 뿐이다.
        if (ev.background_tasks_raw.len != 0 and !tally.truncated and !tally.malformed)
            progress.reapMissing(live[0..tally.count]);
        // **붙잡는 근거는 로스터 하나다**(2026-08-23 결정). 목록은 위에서 «거두는» 데만 썼다 — 그것을
        // 붙잡는 근거로도 쓰면 `type` 을 안 가리는 셈이 셸 백그라운드 작업까지 붙잡고, 그 축에는 푸는
        // 이벤트가 없어 그 pane 의 완료 알림이 영영 안 나간다(실측). 목록에만 있고 우리가 시작을 못 본
        // 자식은 붙잡히지 않는다 — **조기 해제 쪽으로 기울되**(§2 의 기준: 안 풀리는 배지가 더 나쁘다)
        // 다음 프롬프트·턴 키 변화가 셈을 버려 정정한다.
        if (base == .idle and progress.child_count > 0) return .running;
    }
    return base;
}

// ── 알림 정책(계약 §6) ─────────────────────────────────────────────────────────────────────────
//
// **알림을 상태 «전이» 에 붙인다.** 그러면 계약이 요구하는 중복 방지가 규칙이 아니라 구조에서 나온다:
// 같은 턴에서 `Stop` 이 여러 번 와도 상태는 이미 `idle` 이라 전이가 없고, 재발화(`stop_hook_active`)나
// 백그라운드 작업이 남은 `Stop` 은 애초에 상태를 옮기지 않는다. 「턴 단위 1회」와 「재발화 가드」를 따로
// 세지 않아도 된다 — 세는 코드는 언제나 어딘가에서 어긋난다.

pub const Notice = enum {
    none,
    /// 턴이 끝났다(`Stop`). 내용은 마지막 응답.
    done,
    /// 턴이 **오류로** 끝났다(`StopFailure`). 같은 전이지만 문구가 다르다(계약 §2) — 오류로 끊긴 턴에
    /// «완료» 라고 알리면 그 알림 자체가 거짓말이다. provider 가 마지막 응답을 주지 않으므로 내용은 없다.
    failed,
    /// 입력을 기다린다(`PermissionRequest`). 내용은 무엇을 승인하는지.
    attention,
};

/// 이 전이가 어떤 알림을 만드는가. **`Notification`(idle_prompt)은 기본 억제**라 여기 없다 — 그 이벤트는
/// 상태도 안 옮기므로 전이가 생기지 않는다(계약 §6 표).
pub fn noticeOn(prev: State, now: State) Notice {
    if (prev == now) return .none;
    // **«모르다» 에서 나오는 것은 전이가 아니다.** `unknown → idle` 은 «턴이 끝났다» 가 아니라 «이제
    // 알게 됐다» 다. 이것을 완료로 치면 **세션을 여는 것만으로 «턴이 끝났습니다» 알림이 나간다** —
    // `SessionStart` 가 상태를 `idle` 로 놓기 때문이다(실사용 로그가 그 자리를 짚었다: 손으로 쓴
    // 테스트는 첫 이벤트가 늘 프롬프트라 안 걸렸다).
    //
    // 배지는 그대로 바뀐다 — 가려지는 것은 **알림뿐**이다. 사용자가 모르는 사이 끝난 턴을 놓치는 것이
    // 아니라, 애초에 우리가 못 보던 구간이라 알릴 «변화» 가 없는 것이다.
    if (prev == .unknown) return .none;
    return switch (now) {
        .idle => .done,
        .blocked => .attention,
        .running, .unknown => .none,
    };
}

/// 이 이벤트가 만든 전이는 **알리지 않는다**.
///
/// `SessionStart` 가 그렇다. 그것은 상태를 «대기» 로 놓지만(아직 턴이 없다) 그 전이는 «턴이 끝났다» 가
/// 아니라 «세션이 (재)시작됐다» 다. 배지가 «진행 중» 인 동안 `SessionStart` 가 오면 — resume 이나
/// 컨텍스트 압축이 그렇다(실측: 한 pane 에 `startup`·`resume`·`startup` 이 이어서 왔다) — 그 전이를
/// 완료로 읽어 **«턴이 끝났습니다» 가 나간다**. 세션 시작이 턴을 끝낸 것이 아니다.
///
/// `unknown` 에서 나오는 전이를 억제하는 것과 같은 부류다(`noticeOn`): 상태만 보면 «완료» 로 보이지만
/// 사실은 «이제 알게 됐다»·«다시 시작했다» 인 자리들이다.
pub fn suppressesNotice(ev: event.Event) bool {
    return ev.kind == .session_start;
}

/// 이 이벤트가 **세션 base 스냅샷(턴 0)** 을 열어야 하나(AT1 — 계약 §3 표의 `SessionStart` 행).
///
/// 타임라인은 「턴 K = 스냅샷[K+1] ↔ 스냅샷[K]」라 **스냅샷이 하나면 완료된 턴이 0개**다. base 가 없으면
/// 그 세션의 **첫 턴이 화면에 아예 안 뜬다** — 두 번째 턴이 끝나야 첫 턴이 보인다.
///
/// **`isTurnEnd` 와 상호배타다.** `previous == .running` 이면 `SessionStart` 는 `running → idle` 전이를
/// 만들어 **이미 턴 끝으로 찍힌다**(resume·컨텍스트 압축이 그렇다). 그 자리를 base 로도 세면 한 이벤트가
/// 두 사유를 만들어 셈이 갈린다. 그래서 여기서 `running` 을 뺀다 — 그 한 줄이 「지금도 찍히는 것」과
/// 「새로 찍는 것」을 정확히 가르고, 그 배타성을 test 가 값으로 못 박는다.
///
/// | previous | isTurnEnd | opensSessionBase |
/// | --- | --- | --- |
/// | `running` | 참 | 거짓 (턴 끝이다) |
/// | `idle`·`blocked`·`unknown` | 거짓 | 참 (cold start·`/clear` 직후·승인 대기 중 resume) |
///
/// **자식은 세션을 열지 않는다**(`agent_id`).
pub fn opensSessionBase(previous: State, ev: event.Event) bool {
    if (ev.agent_id.len != 0) return false;
    if (ev.kind != .session_start) return false;
    return previous != .running;
}

/// 이 이벤트가 **그 Term 의 세션 신원**을 싣고 오나(AT1 — 링의 키다, 계약 §6.1).
///
/// 훅 모드에는 신원을 갱신할 다른 자리가 **없다**. 관측 모드가 쓰는 자식 env 폴링
/// (`refreshAgentSessionIdentity`)은 `.observe` 분기 전용이고, 그 폴링을 걷어낸 것이 훅 모드가 주는
/// 이득의 절반이다(§1.1). provider 가 payload 로 직접 말해 주므로 추론할 이유가 없다.
///
/// ⚠️ **`marksTurnProgress` 를 재사용하지 않는다.** 그쪽이 `Notification` 을 빼는 이유는 「알림은 턴
/// 진행의 증거가 아니다」인데 **신원은 턴 진행이 아니다**. claude 알림은 공통 payload 라 lead 의
/// `session_id` 를 그대로 싣는다(2026-08-24 실측 — 알림 176개 전부 실었다). 같은 규칙의 두 모양이
/// 아니라 **다른 규칙 둘**이라, 이름을 따로 둔다.
///
/// **자식은 부모의 신원을 옮기지 않는다**(`agent_id` — 계약 §2 의 규율).
pub fn carriesSessionIdentity(ev: event.Event) bool {
    if (ev.agent_id.len != 0) return false;
    return ev.session_id.len != 0;
}

/// 주의 알림을 **바로 띄우지 않는 시간**(계약 §6 — 자동 승인으로 곧 해소되는 요청이 있다).
/// 배지는 즉시 바뀌고 배너만 늦는다 — 시각 상태와 OS 배너의 타이밍을 분리한다.
pub const attention_debounce_ms: u64 = 1200;

/// 예약해 둔 주의 알림을 지금 어떻게 할 것인가.
pub const Debounce = enum {
    /// 아직 이르다 — 다음 tick 에 다시 본다.
    wait,
    /// 띄운다.
    emit,
    /// **버린다** — 그 사이 상태가 `blocked` 를 떠났다(자동 승인으로 해소됐다는 뜻이다).
    drop,
};

pub fn attentionDebounce(state_now: State, since_ms: u64, now_ms: u64) Debounce {
    if (state_now != .blocked) return .drop;
    return if (now_ms -| since_ms >= attention_debounce_ms) .emit else .wait;
}

/// Term 이 들고 있는 «아직 안 띄운 알림». 고정 크기라 힙을 잡지 않는다(Term 은 수십 개가 산다).
/// 지금 무엇을 하고 있는지 — **진행 중 세부**(계약 §2). `PreToolUse` 의 `tool_input.description`(사람이
/// 읽는 설명), 없으면 도구 이름이다. **명령 원문은 담지 않는다**(계약 §7 — 길고 민감하다).
///
/// 왜 있어야 하나: 훅 모드는 화면·프로세스 관측을 끄므로(§1.1) 이 자리를 비워 두면 배지가 «진행중» 한
/// 마디만 말한다. 훅을 켠 사용자가 정보를 **잃는다** — 그러면 켤 이유가 없다(§8).
/// 훅이 알려 준 **작업 디렉터리**를 그 Term 에 들고 있는다.
///
/// `ToolLabel` 과 같은 모양이되 상한만 다르다 — 경로는 사이드바 한 줄보다 길 수 있고, 잘린 경로는
/// 「틀린 경로」라 표시에 쓰면 안 된다(그래서 넘치면 **안 담는다**).
pub const CwdLabel = struct {
    pub const max_text = 512;

    /// 이 값이 얼마나 오래 믿을 만한가. **원격에는 「에이전트가 사라졌다」 신호가 없다** —
    /// `agent_kind` 재판정은 원격에서 아예 돌지 않고(훅 줄이 소스다), 채널이 열려 있는 한 훅 모드도
    /// 유지된다. 그래서 에이전트를 끝내고 ssh 안에 남아 `cd` 하면 이 값이 **살아 있는 OSC 7 을 덮는다**.
    ///
    /// 시각을 함께 들고 오래되면 관측으로 되돌아간다. 턴이 도는 동안에는 매 이벤트가 이 값을 새로
    /// 하므로 만료되지 않고, 에이전트가 없으면 곧 만료돼 셸의 cwd 가 다시 보인다.
    pub const stale_after_ms: u64 = 10 * 60 * 1000; // 10 분

    len: usize = 0,
    seen_ms: u64 = 0,
    buf: [max_text]u8 = undefined,

    pub fn text(self: *const CwdLabel) []const u8 {
        return self.buf[0..self.len];
    }

    /// **아직 믿을 만한가.** `now_ms` 는 단조 시계(`awakeMs`)여야 한다 — 벽시계면 슬립·시간 보정에
    /// 값이 튀어 멀쩡한 값을 버리거나 낡은 값을 붙든다.
    pub fn fresh(self: *const CwdLabel, now_ms: u64) bool {
        if (self.len == 0) return false;
        if (now_ms < self.seen_ms) return true; // 시계가 뒤로 갔다 — 버리지 않는다
        return now_ms - self.seen_ms <= stale_after_ms;
    }

    pub fn isEmpty(self: *const CwdLabel) bool {
        return self.len == 0;
    }

    /// **절대 경로만, 상한 안에서만 담는다.** 상대 경로는 어느 기준인지 이쪽이 모르고, 잘린 절대
    /// 경로는 남의 디렉터리를 가리킨다 — 둘 다 「모른다」로 두는 편이 안전하다.
    pub fn set(self: *CwdLabel, path: []const u8, now_ms: u64) void {
        if (path.len == 0 or path.len > max_text or path[0] != '/') return;
        @memcpy(self.buf[0..path.len], path);
        self.len = path.len;
        self.seen_ms = now_ms;
    }

    pub fn clear(self: *CwdLabel) void {
        self.len = 0;
        self.seen_ms = 0;
    }
};

pub const ToolLabel = struct {
    /// 사이드바 한 줄에 곁들이는 값이라 길 필요가 없다. 넘치면 자른다(버리지 않는다).
    pub const max_text = 120;

    len: usize = 0,
    buf: [max_text]u8 = undefined,

    pub fn text(self: *const ToolLabel) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *ToolLabel, body: []const u8) void {
        // UTF-8 시퀀스 한가운데서 자르면 렌더가 U+FFFD 를 뿌린다 — 글자 경계로 물린다.
        const clamped = transcript.clampUtf8(body, max_text);
        @memcpy(self.buf[0..clamped.len], clamped);
        self.len = clamped.len;
    }

    pub fn clear(self: *ToolLabel) void {
        self.len = 0;
    }
};

/// 이 이벤트가 진행 중 세부를 어떻게 바꾸는가. 순수 규칙으로 떼어 둔 이유는 «언제 지우는가» 가
/// «언제 세우는가» 만큼 중요하기 때문이다 — 안 지우면 턴이 끝난 pane 이 마지막 도구를 계속 말한다.
pub const LabelChange = union(enum) {
    /// 이 이벤트는 세부와 무관하다.
    keep,
    /// 세부를 비운다(턴 경계).
    clear,
    /// 세부를 이 문구로 바꾼다.
    set: []const u8,
};

pub fn labelFor(ev: event.Event) LabelChange {
    // 자식의 도구 호출은 **부모의** 세부가 아니다(계약 §2 — 자식 활동은 `agent_id` 를 싣고 따로 온다).
    // 이것을 안 가르면 부모 줄이 자식이 하는 일로 계속 갈아 끼워져 «누가 무엇을» 이 뒤섞인다.
    if (ev.agent_id.len != 0) return .keep;
    switch (ev.kind) {
        .pre_tool_use => {
            const body = if (ev.tool_description.len > 0) ev.tool_description else ev.tool_name;
            // 둘 다 비면 지우지 않는다 — 이름 없는 이벤트 하나가 멀쩡한 세부를 날리지 않게.
            return if (body.len == 0) .keep else .{ .set = body };
        },
        // 턴 경계에서는 비운다. 도구 종료는 **다음 `PreToolUse` 또는 `Stop`** 으로 안다(계약 §2).
        .stop, .stop_failure, .user_prompt_submit, .session_start => return .clear,
        else => return .keep,
    }
}

pub const PendingNotice = struct {
    pub const max_text = 512;

    kind: Notice = .none,
    /// 예약된 시각(awake clock, ms). 주의 알림의 디바운스가 이 값으로 잰다.
    since_ms: u64 = 0,
    len: usize = 0,
    buf: [max_text]u8 = undefined,

    pub fn text(self: *const PendingNotice) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *PendingNotice, kind: Notice, body: []const u8, now_ms: u64) void {
        self.kind = kind;
        self.since_ms = now_ms;
        // **자른다, 버리지 않는다.** 마지막 응답은 길 수 있는데 그것 때문에 알림을 통째로 잃으면
        // 사용자는 «턴이 끝났다» 는 사실 자체를 놓친다.
        //
        // **글자 경계에서 자른다**(`ToolLabel.set` 과 같은 규율). 바이트로 자르면 한글 응답의 알림
        // 끝에 U+FFFD 가 붙는다 — 상한을 넘기는 것은 «길게 답한 턴» 이라 실제로 자주 걸린다.
        const clamped = transcript.clampUtf8(body, max_text);
        @memcpy(self.buf[0..clamped.len], clamped);
        self.len = clamped.len;
    }

    pub fn clear(self: *PendingNotice) void {
        self.kind = .none;
        self.len = 0;
        self.since_ms = 0;
    }
};

const testing = std.testing;

fn evOf(kind: event.Kind) event.Event {
    return .{
        .provider = "claude",
        .kind = kind,
        .session_id = "",
        .transcript_path = "",
        .turn_key = "",
        .tool_name = "",
        .tool_description = "",
        .file_path = "",
        .tool_command = "",
        .text = "",
        .source = "",
        .stop_hook_active = false,
    };
}

/// 자식 수명 이벤트를 **실측 모양대로** 만든다. `SubagentStart`/`SubagentStop` 은 자식의 `agent_id` 를
/// 싣고 온다(2026-08-21 실측). 이것을 빈 `agent_id` 로 시험하면 «자식 이벤트는 무시» 가드를 위로
/// 올리는 리팩터링이 **제품만 깨뜨리고 테스트는 통과한다** — 실제로 그 순서 때문에 동작하는 코드다.
fn childEv(kind: event.Kind) event.Event {
    return childEvId(kind, "a533c21143f8edccb"); // 실측에서 받은 모양
}

/// 자식을 **id 로 구분해** 만든다. 실사용에서 한 턴에 여러 자식 id 가 섞여 오므로(그중 남의 것도
/// 있다) 테스트도 그 모양을 써야 한다.
fn childEvId(kind: event.Kind, id: []const u8) event.Event {
    var ev = evOf(kind);
    ev.agent_id = id;
    return ev;
}

test "모드는 게이트·에이전트·로그 셋이 다 서야 훅이다" {
    try testing.expectEqual(Mode.hook, modeFor(.{ .gate_on = true, .log_present = true, .agent_present = true }));
    // 하나라도 빠지면 관측이다 — 셋을 각각 흔들어 본다(하나만 보고 판정하면 나머지가 조용히 무시된다).
    try testing.expectEqual(Mode.observe, modeFor(.{ .gate_on = false, .log_present = true, .agent_present = true }));
    try testing.expectEqual(Mode.observe, modeFor(.{ .gate_on = true, .log_present = false, .agent_present = true }));
    try testing.expectEqual(Mode.observe, modeFor(.{ .gate_on = true, .log_present = true, .agent_present = false }));
    try testing.expectEqual(Mode.observe, modeFor(.{}));
}

test "설치했는데 아직 안 돈 구간은 관측 모드다 — 조용히 훅 모드로 앉히지 않는다" {
    // 게이트가 켜졌다고 훅 모드로 두면, 훅이 깨진 사람은 **영영 빈 배지**를 본다(관측도 안 도니까).
    // 파일이 생기는 순간 승격된다.
    const before: Probe = .{ .gate_on = true, .agent_present = true, .log_present = false };
    try testing.expectEqual(Mode.observe, modeFor(before));
    var after = before;
    after.log_present = true;
    try testing.expectEqual(Mode.hook, modeFor(after));
}

test "배지 상태는 관측 모드와 같은 타입이다 — 복사하면 소스마다 값이 갈린다" {
    // 여기서 열거를 따로 선언하면 컴파일은 되지만 배지가 소스마다 다른 값을 갖게 된다. 그 어긋남은
    // 화면에서만 드러나고 재현도 어려우므로 타입 동일성으로 못박는다.
    try testing.expectEqual(@import("agent_observer.zig").State, State);
}

test "턴 경계가 상태를 옮긴다" {
    try testing.expectEqual(State.idle, next(.unknown, evOf(.session_start)));
    try testing.expectEqual(State.running, next(.idle, evOf(.user_prompt_submit)));
    try testing.expectEqual(State.running, next(.running, evOf(.pre_tool_use)));
    try testing.expectEqual(State.blocked, next(.running, evOf(.permission_request)));
    try testing.expectEqual(State.idle, next(.blocked, evOf(.stop)));
}

test "재발화 Stop 은 턴 종료가 아니다" {
    // `stop_hook_active` 는 서브에이전트·백그라운드가 다시 부른 것이다. 이것을 종료로 세면 턴이 둘로 갈린다.
    var ev = evOf(.stop);
    ev.stop_hook_active = true;
    try testing.expectEqual(State.running, next(.running, ev));
    try testing.expectEqual(State.blocked, next(.blocked, ev));
}

test "셸 백그라운드 작업이 도는 중이어도 턴은 끝난다" {
    // 실측 payload 그대로다(`Bash` 의 `run_in_background` 로 띄운 `sleep`). 예전에는 이 목록에 `running`
    // 이 있으면 배지를 붙잡았는데, 셸 작업에는 **푸는 이벤트가 없어** 그 pane 의 완료 알림이 그 작업이
    // 끝날 때까지 한 건도 안 나갔다. 이제 목록은 «거두는» 데만 쓰고 붙잡지 않는다(계약 §2).
    var ev = evOf(.stop);
    ev.background_tasks_raw =
        "[{\"id\":\"bmyb73pp8\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"Sleep 200 seconds\"}]";
    try testing.expectEqual(State.idle, next(.running, ev));

    // 여럿이어도 같다 — 개수가 아니라 **누가 도는가**(서브에이전트인가)가 기준이다.
    var many = evOf(.stop);
    many.background_tasks_raw =
        "[{\"id\":\"a\",\"type\":\"shell\",\"status\":\"running\"},{\"id\":\"b\",\"type\":\"shell\",\"status\":\"running\"}]";
    try testing.expectEqual(State.idle, next(.running, many));
}

test "모르는 이벤트와 접힌 이벤트는 상태를 흔들지 않는다" {
    // 내용을 모르는 채로 옮기면 배지가 틀린 값에 **고정**된다 — 다음 이벤트가 올 때까지 되돌릴 길이 없다.
    for ([_]event.Kind{ .unknown, .oversized, .notification }) |kind| {
        try testing.expectEqual(State.running, next(.running, evOf(kind)));
        try testing.expectEqual(State.blocked, next(.blocked, evOf(kind)));
        try testing.expectEqual(State.idle, next(.idle, evOf(kind)));
    }
}

test "파서가 아는 모든 이벤트에 전이가 있다 — 한쪽만 늘면 그 이벤트가 상태를 못 옮긴다" {
    // `Kind` 는 파서가 소유하고 전이는 여기가 소유한다. 새 이벤트를 파서에 넣고 여기를 잊으면 그 이벤트는
    // 조용히 «상태 유지» 가 되는데, 그것이 의도인지 누락인지 코드만 봐서는 알 수 없다.
    // 서브에이전트 둘은 `advance` 가 옮긴다 — 그쪽이 실제로 상태를 바꾸는지 여기서 함께 못박는다.
    {
        var progress: Progress = .{};
        try testing.expectEqual(State.running, advance(&progress, .idle, childEv(.subagent_start)));
        try testing.expectEqual(@as(usize, 1), progress.childCount());
    }
    {
        // **담을 수 없는 자식은 붙잡지 않는다.** `agent_id` 가 없으면 그 종료를 영영 못 알아보므로,
        // «돈다» 고 세어 두면 배지가 안 풀린다 — 이 층이 막으려는 바로 그 실패다. 배지는 그 순간
        // «진행 중» 으로 가되(무언가 돌긴 한다), 붙잡는 근거로는 쓰지 않는다.
        var progress: Progress = .{};
        try testing.expectEqual(State.running, advance(&progress, .idle, evOf(.subagent_start)));
        try testing.expectEqual(@as(usize, 0), progress.childCount());
    }
    inline for (@typeInfo(event.Kind).@"enum".fields) |field| {
        const kind: event.Kind = @enumFromInt(field.value);
        const moved = next(.unknown, evOf(kind));
        const holds = switch (kind) {
            .notification, .oversized, .unknown => true,
            // 서브에이전트 수명은 `next` 가 아니라 `advance` 가 옮긴다(세는 일이라 진행 상태가 필요하다).
            // 그래서 여기서는 «상태를 안 흔든다» 가 맞고, 그 사실을 아래에서 따로 못박는다.
            .subagent_start, .subagent_stop => true,
            else => false,
        };
        if (holds) {
            try testing.expectEqual(State.unknown, moved);
        } else {
            try testing.expect(moved != .unknown);
        }
    }
}

test "알림은 전이에 붙는다 — 같은 턴에서 두 번 울리지 않는다" {
    // `Stop` 이 여러 번 와도 상태는 이미 `idle` 이라 두 번째부터는 전이가 없다. 「턴 단위 1회」를 따로
    // 세지 않아도 성립하는 것이 이 설계의 요점이다.
    try testing.expectEqual(Notice.done, noticeOn(.running, .idle));
    try testing.expectEqual(Notice.none, noticeOn(.idle, .idle));
    try testing.expectEqual(Notice.attention, noticeOn(.running, .blocked));
    try testing.expectEqual(Notice.none, noticeOn(.blocked, .blocked));
    // 시작·진행은 알릴 것이 없다.
    try testing.expectEqual(Notice.none, noticeOn(.idle, .running));
    try testing.expectEqual(Notice.none, noticeOn(.unknown, .running));
}

test "재발화 Stop 은 전이를 안 만들고, 백그라운드가 도는 Stop 은 만든다" {
    // 상태 전이 함수와 알림 정책이 **같은 사실**을 쓰는지 확인한다 — 둘이 따로 판단하면 어긋난다.
    var reentrant = evOf(.stop);
    reentrant.stop_hook_active = true;
    const after_reentrant = next(.running, reentrant);
    try testing.expectEqual(Notice.none, noticeOn(.running, after_reentrant));

    // **셸 백그라운드가 도는 중이어도 알림은 나간다**(2026-08-23 결정). 사용자가 겪은 «알림이 안 온다» 가
    // 정확히 이 자리였다 — `Stop` 은 «모든 작업이 끝났다» 가 아니라 «턴 끝» 이다(계약 §2).
    var background = evOf(.stop);
    background.background_tasks_raw = "[{\"id\":\"s1\",\"type\":\"shell\",\"status\":\"running\"}]";
    const after_background = next(.running, background);
    try testing.expectEqual(Notice.done, noticeOn(.running, after_background));

    // 대조: 평범한 Stop 은 알린다.
    try testing.expectEqual(Notice.done, noticeOn(.running, next(.running, evOf(.stop))));
}

test "주의 알림은 디바운스하고, 그 사이 해소되면 버린다" {
    // 자동 승인으로 곧 사라지는 요청이 있다(계약 §6). 배지는 이미 바뀌었고 배너만 늦춘다.
    try testing.expectEqual(Debounce.wait, attentionDebounce(.blocked, 1000, 1000));
    try testing.expectEqual(Debounce.wait, attentionDebounce(.blocked, 1000, 1000 + attention_debounce_ms - 1));
    try testing.expectEqual(Debounce.emit, attentionDebounce(.blocked, 1000, 1000 + attention_debounce_ms));
    // 그 사이 상태가 blocked 를 떠났다 = 자동 승인으로 해소됐다.
    try testing.expectEqual(Debounce.drop, attentionDebounce(.running, 1000, 1000 + attention_debounce_ms));
    try testing.expectEqual(Debounce.drop, attentionDebounce(.idle, 1000, 1000));
}

test "예약한 알림은 잘리되 사라지지 않는다" {
    var notice: PendingNotice = .{};
    try testing.expectEqual(Notice.none, notice.kind);

    notice.set(.done, "끝났습니다", 42);
    try testing.expectEqual(Notice.done, notice.kind);
    try testing.expectEqual(@as(u64, 42), notice.since_ms);
    try testing.expectEqualStrings("끝났습니다", notice.text());

    // 긴 응답 때문에 «턴이 끝났다» 는 사실 자체를 잃으면 안 된다.
    const long = "x" ** (PendingNotice.max_text + 64);
    notice.set(.done, long, 1);
    try testing.expectEqual(@as(usize, PendingNotice.max_text), notice.text().len);

    notice.clear();
    try testing.expectEqual(Notice.none, notice.kind);
    try testing.expectEqual(@as(usize, 0), notice.text().len);
}

test "오류로 끝난 턴도 끝이다 — 안 받으면 배지가 영영 «진행 중»" {
    // provider 가 API·모델 오류에서는 `Stop` **대신** `StopFailure` 를 보낸다(계약 §2 실측).
    try testing.expectEqual(State.idle, next(.running, evOf(.stop_failure)));
    try testing.expectEqual(State.idle, next(.blocked, evOf(.stop_failure)));
    // 알림도 나간다 — 전이가 있으므로.
    try testing.expectEqual(Notice.done, noticeOn(.running, next(.running, evOf(.stop_failure))));
}

test "목록의 모양이 어떻든 next 는 그것을 보지 않는다" {
    // 붙잡는 일은 `advance` 가 자기 로스터로 단독으로 한다 — `next` 는 「이벤트 하나 → 상태」 만 보는
    // 순수 전이다. 목록이 비었든, 끝난 항목만 남았든, 서브에이전트가 도는 중이라 말하든 여기서는 같다.
    for ([_][]const u8{
        "",
        "[]",
        "[{\"id\":\"c1\",\"type\":\"subagent\",\"status\":\"completed\"}]",
        "[{\"id\":\"c1\",\"type\":\"subagent\",\"status\":\"running\"}]",
    }) |raw| {
        var ev = evOf(.stop);
        ev.background_tasks_raw = raw;
        try testing.expectEqual(State.idle, next(.running, ev));
    }
}

test "자식 이벤트는 부모 상태를 옮기지 않는다" {
    // 자식이 도구를 부를 때마다 부모가 «진행 중» 이 되고 자식이 끝날 때 부모가 «완료» 가 되면, 부모의
    // 턴과 무관하게 배지가 춤춘다(계약 §2 — 자식 활동은 `agent_id` 를 실은 이벤트로 온다).
    var child_tool = evOf(.pre_tool_use);
    child_tool.agent_id = "child-1";
    try testing.expectEqual(State.idle, next(.idle, child_tool)); // 부모는 그대로 대기

    var child_stop = evOf(.stop);
    child_stop.agent_id = "child-1";
    try testing.expectEqual(State.running, next(.running, child_stop)); // 자식이 끝나도 부모는 진행 중

    // 대조: 같은 이벤트라도 `agent_id` 가 없으면 부모 것이라 옮긴다.
    try testing.expectEqual(State.idle, next(.running, evOf(.stop)));
}

test "자식이 도는 동안 lead 의 Stop 은 턴 끝이 아니다 — 그리고 마지막 자식이 끝나면 풀린다" {
    var progress: Progress = .{};
    var state: State = .idle;

    state = advance(&progress, state, evOf(.user_prompt_submit)); // 턴 시작
    try testing.expectEqual(State.running, state);

    state = advance(&progress, state, childEvId(.subagent_start, "child-a")); // 자식 둘
    state = advance(&progress, state, childEvId(.subagent_start, "child-b"));
    try testing.expectEqual(@as(usize, 2), progress.childCount());

    // lead 가 먼저 끝났다 — **완료로 단정하지 않는다**(자식이 아직 돈다).
    state = advance(&progress, state, evOf(.stop));
    try testing.expectEqual(State.running, state);
    try testing.expect(!progress.turn_open);

    // 자식 하나가 끝나도 아직이다.
    state = advance(&progress, state, childEvId(.subagent_stop, "child-a"));
    try testing.expectEqual(State.running, state);

    // **마지막 자식이 끝나면** 그때가 진짜 턴 끝이다.
    state = advance(&progress, state, childEvId(.subagent_stop, "child-b"));
    try testing.expectEqual(State.idle, state);
    try testing.expectEqual(@as(usize, 0), progress.childCount());
}

test "자식이 없으면 lead 의 Stop 이 곧 턴 끝이다" {
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit));
    try testing.expect(progress.turn_open); // 프롬프트가 턴을 연다
    state = advance(&progress, state, evOf(.stop));
    try testing.expectEqual(State.idle, state);
    try testing.expect(!progress.turn_open); // 그리고 `Stop` 이 닫는다
    try testing.expectEqual(@as(usize, 0), progress.childCount()); // 붙잡을 자식이 없었다
}

test "새 턴은 지난 턴의 셈을 버린다 — 어긋난 수가 영영 남지 않게" {
    var progress: Progress = .{};
    _ = advance(&progress, .idle, childEvId(.subagent_start, "child-a"));
    _ = advance(&progress, .running, childEvId(.subagent_start, "child-b"));
    try testing.expectEqual(@as(usize, 2), progress.childCount()); // 자식 종료 이벤트를 놓쳤다고 하자

    const state = advance(&progress, .running, evOf(.user_prompt_submit));
    try testing.expectEqual(@as(usize, 0), progress.childCount()); // 새 턴에서 셈을 버린다
    try testing.expectEqual(State.running, state);
    // 그러니 다음 `Stop` 은 정상적으로 턴을 끝낸다.
    try testing.expectEqual(State.idle, advance(&progress, state, evOf(.stop)));
}

test "자식 수는 음수로 내려가지 않는다" {
    // 시작을 놓치고 종료만 오면(로그 유실·재접속) 0 에서 빼게 된다. 포화 뺄셈으로 막는다.
    //
    // **상태를 손으로 놓지 않고 이벤트로 만든다.** 예전에는 `(.running, 셈 0, 턴 안 열림)` 을 직접
    // 넣었는데 그 조합은 실제로 도달할 수 없다 — lead 가 `running` 으로 미는 이벤트는 반드시 턴을
    // 열기 때문이다. 도달 불가능한 상태에 대고 단언하면 규칙이 아니라 그 픽스처를 재게 된다.
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit)); // lead 가 일하는 중
    state = advance(&progress, state, childEv(.subagent_stop)); // 시작을 못 본 종료
    try testing.expectEqual(@as(usize, 0), progress.childCount()); // 0 밑으로 안 내려간다
    try testing.expectEqual(State.running, state); // lead 의 턴이 열려 있으므로 그대로
}

test "오류로 끝난 턴도 자식을 기다린다" {
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit));
    state = advance(&progress, state, childEv(.subagent_start));
    state = advance(&progress, state, evOf(.stop_failure));
    try testing.expectEqual(State.running, state); // 자식이 남았다
    state = advance(&progress, state, childEv(.subagent_stop));
    try testing.expectEqual(State.idle, state);
}

test "진행 중 세부는 도구 설명에서 오고 턴 경계에서 비워진다" {
    var label: ToolLabel = .{};

    var tool = evOf(.pre_tool_use);
    tool.tool_name = "Bash";
    tool.tool_description = "테스트를 돌린다";
    switch (labelFor(tool)) {
        .set => |body| label.set(body),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqualStrings("테스트를 돌린다", label.text());

    // 설명이 없으면 도구 이름이라도 보인다 — 빈 줄보다 낫다.
    var bare = evOf(.pre_tool_use);
    bare.tool_name = "Read";
    switch (labelFor(bare)) {
        .set => |body| try testing.expectEqualStrings("Read", body),
        else => return error.TestUnexpectedResult,
    }

    // 턴이 끝나면 비운다 — 안 비우면 끝난 pane 이 마지막 도구를 계속 말한다.
    for ([_]event.Kind{ .stop, .stop_failure, .user_prompt_submit, .session_start }) |kind| {
        try testing.expectEqual(LabelChange.clear, labelFor(evOf(kind)));
    }
    label.clear();
    try testing.expectEqualStrings("", label.text());
}

test "자식의 도구 호출은 부모의 세부를 갈아 끼우지 않는다" {
    var child = evOf(.pre_tool_use);
    child.tool_name = "Bash";
    child.tool_description = "자식이 하는 일";
    child.agent_id = "child-1";
    try testing.expectEqual(LabelChange.keep, labelFor(child));

    // 같은 이벤트라도 `agent_id` 가 없으면 부모 것이라 세운다.
    child.agent_id = "";
    try testing.expect(labelFor(child) == .set);
}

test "이름도 설명도 없는 도구 이벤트는 멀쩡한 세부를 날리지 않는다" {
    try testing.expectEqual(LabelChange.keep, labelFor(evOf(.pre_tool_use)));
}

test "세부는 글자 경계로 잘린다 — 잘린 바이트를 그리면 U+FFFD 가 뜬다" {
    var label: ToolLabel = .{};
    const long = "가" ** 100; // 300 바이트, 상한(120)보다 길다
    label.set(long);
    try testing.expect(label.text().len <= ToolLabel.max_text);
    try testing.expect(std.unicode.utf8ValidateSlice(label.text()));
    try testing.expect(label.text().len % 3 == 0); // 3 바이트 글자만 온전히 남았다
}

test "오류로 끝난 턴을 «완료» 라 부르지 않는다" {
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit));
    state = advance(&progress, state, evOf(.stop_failure));
    try testing.expectEqual(State.idle, state);
    try testing.expectEqual(Notice.done, noticeOn(.running, state)); // 전이는 같고
    try testing.expect(progress.takeFailed()); // 문구만 갈린다
    try testing.expect(!progress.takeFailed()); // 가져가면 지워진다
}

test "자식 뒤에 끝난 오류 턴도 오류로 남는다" {
    // 턴 끝 전이가 `StopFailure` 가 아니라 **마지막 `SubagentStop`** 에서 일어나는 경우다. 그 순간의
    // 이벤트만 보면 오류였다는 사실이 사라져 «턴이 끝났습니다» 가 나간다.
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit));
    state = advance(&progress, state, childEv(.subagent_start));
    state = advance(&progress, state, evOf(.stop_failure));
    try testing.expectEqual(State.running, state); // 자식이 남았다
    state = advance(&progress, state, childEv(.subagent_stop));
    try testing.expectEqual(State.idle, state);
    try testing.expect(progress.takeFailed());
}

test "정상으로 끝난 턴은 오류로 물들지 않는다" {
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit));
    state = advance(&progress, state, evOf(.stop_failure)); // 지난 턴은 오류였다
    try testing.expect(progress.lead_failed);

    // 새 턴이 시작되면 그 사실을 버린다 — 안 버리면 다음 턴의 정상 종료가 «오류» 로 나간다.
    state = advance(&progress, state, evOf(.user_prompt_submit));
    try testing.expect(!progress.lead_failed);
    state = advance(&progress, state, evOf(.stop));
    try testing.expectEqual(State.idle, state);
    try testing.expect(!progress.takeFailed());
}

test "실측 순서를 그대로 재생한다 — claude 서브에이전트 턴(2026-08-21)" {
    // 실제로 받은 순서다(`--settings` 로 훅만 주입하고 진짜 세션을 돌려 받았다):
    //   SessionStart → UserPromptSubmit → PreToolUse(Agent) → SubagentStart(agent_id)
    //   → PreToolUse(agent_id) → SubagentStop(agent_id) → Stop
    // **자식이 lead 보다 먼저 끝난다** — 그래서 이 순서에서는 «lead 를 붙잡는» 경로가 아예 안 탄다.
    // 그 경로는 순서가 뒤집히는 경우(비동기 자식)를 위한 방어이고, 여기서는 **평범한 순서가
    // 평범하게 끝나는지** 를 못박는다. 이 테스트가 없으면 방어 코드가 정상 경로를 망가뜨려도 모른다.
    var progress: Progress = .{};
    var state: State = .unknown;

    state = advance(&progress, state, evOf(.session_start));
    try testing.expectEqual(State.idle, state);
    state = advance(&progress, state, evOf(.user_prompt_submit));
    try testing.expectEqual(State.running, state);

    var spawn = evOf(.pre_tool_use); // lead 가 Agent 도구를 부른다
    spawn.tool_name = "Agent";
    spawn.tool_description = "Run echo command";
    state = advance(&progress, state, spawn);
    try testing.expectEqual(State.running, state);
    // 그 순간의 «진행 중 세부» 는 lead 가 시킨 일이다.
    try testing.expect(labelFor(spawn) == .set);

    state = advance(&progress, state, childEv(.subagent_start));
    try testing.expectEqual(@as(usize, 1), progress.childCount());

    var child_tool = evOf(.pre_tool_use); // 자식이 부르는 도구
    child_tool.agent_id = "a533c21143f8edccb";
    child_tool.tool_name = "Bash";
    child_tool.tool_description = "Echo from-child";
    state = advance(&progress, state, child_tool);
    try testing.expectEqual(State.running, state);
    // 자식이 하는 일이 부모 줄을 갈아 끼우지 않는다.
    try testing.expectEqual(LabelChange.keep, labelFor(child_tool));

    // 자식이 먼저 끝난다(실측 순서). lead 는 아직이므로 배지는 그대로다.
    var child_stop = childEv(.subagent_stop);
    child_stop.text = "from-child"; // `last_assistant_message` 가 자식 응답으로 온다
    state = advance(&progress, state, child_stop);
    try testing.expectEqual(State.running, state);
    try testing.expectEqual(@as(usize, 0), progress.childCount());
    try testing.expect(progress.turn_open);

    // 그리고 lead 가 끝난다 — 그때가 턴 끝이고, 알림이 나간다.
    const done = evOf(.stop);
    const before = state;
    state = advance(&progress, state, done);
    try testing.expectEqual(State.idle, state);
    try testing.expectEqual(Notice.done, noticeOn(before, state));
    try testing.expect(!progress.takeFailed()); // 오류가 아니었다
}

test "실측 순서를 그대로 재생한다 — codex 서브에이전트 턴(2026-08-21)" {
    // codex 도 같은 모양이다(실측):
    //   PreToolUse(collaborationspawn_agent) → PreToolUse(collaborationwait_agent)
    //   → SubagentStart(agent_id) → PreToolUse(agent_id) → SubagentStop(agent_id) → Stop
    // **도구 이름이 claude 와 다르다** — 그래서 이름으로 «서브에이전트를 띄우는 순간» 을 알아내려던
    // 옛 방식은 codex 에서 통하지 않았을 것이다. 수명 이벤트로 세는 지금 방식은 이름을 안 본다.
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit));

    var spawn = evOf(.pre_tool_use);
    spawn.tool_name = "collaborationspawn_agent"; // codex 는 사람이 읽는 description 을 안 준다(§2.1)
    state = advance(&progress, state, spawn);
    switch (labelFor(spawn)) {
        .set => |body| try testing.expectEqualStrings("collaborationspawn_agent", body),
        else => return error.TestUnexpectedResult, // 이름뿐이어도 빈 줄보다 낫다
    }

    var child = childEv(.subagent_start);
    child.agent_id = "01a022dd-680f-7151-8f1a-c1bf1f58a47c"; // 실측 모양(uuid)
    state = advance(&progress, state, child);
    try testing.expectEqual(@as(usize, 1), progress.childCount());

    var child_stop = childEv(.subagent_stop);
    child_stop.agent_id = child.agent_id;
    child_stop.text = "from-child";
    state = advance(&progress, state, child_stop);
    try testing.expectEqual(State.running, state); // 자식이 먼저 끝나도 lead 가 남았다

    state = advance(&progress, state, evOf(.stop));
    try testing.expectEqual(State.idle, state);
}

test "새 세션은 지난 세션의 셈을 물려받지 않는다" {
    var progress: Progress = .{};
    _ = advance(&progress, .idle, childEv(.subagent_start));
    _ = advance(&progress, .running, evOf(.stop_failure));
    try testing.expectEqual(@as(usize, 1), progress.childCount());
    try testing.expect(progress.lead_failed);

    // 같은 pane 에서 에이전트를 다시 띄웠다 — 지난 세션의 자식은 이미 없다.
    const state = advance(&progress, .running, evOf(.session_start));
    try testing.expectEqual(State.idle, state);
    try testing.expectEqual(@as(usize, 0), progress.childCount());
    try testing.expect(!progress.lead_failed);
}

// ── 전수 탐색 ─────────────────────────────────────────────────────────────────────────────────
//
// 손으로 고른 경우는 **내가 생각한 것**만 덮는다. 이 층의 실패는 «어떤 순서 뒤에 배지가 안 풀린다» 라
// 순서가 곧 버그이고, 그 순서를 내가 떠올리지 못하면 테스트도 없다. 그래서 짧은 순서를 **전부** 돌린다.

/// 전수 탐색에 쓰는 알파벳. lead 것과 자식 것을 **둘 다** 넣는다 — 실측에서 자식 수명 이벤트가
/// `agent_id` 를 싣고 오므로, 그 구분이 규칙의 핵심이다.
fn alphabetEvent(i: usize) event.Event {
    const kinds = [_]event.Kind{
        .session_start, .user_prompt_submit, .pre_tool_use,   .permission_request,
        .stop,          .stop_failure,       .subagent_start, .subagent_stop,
        .notification,  .oversized,          .notification,
    };
    const child = i >= kinds.len;
    const k = i % kinds.len;
    var ev = evOf(kinds[k]);
    // **마지막 자리는 «입력 대기» 알림이다.** 종류 없는 알림만 넣으면 그 가지를 한 번도 안 밟는다 —
    // 실제로 안 밟았고, 그 사이로 «자식이 남은 뒤 온 알림이 턴을 되살려 배지가 갇히는» 순서가 지나갔다.
    if (k == kinds.len - 1) ev.notification_type = .needs_input;
    if (child) ev.agent_id = "child-1";
    return ev;
}
const alphabet_len: usize = 22; // 위 11 종 × (lead | 자식)

test "전수: 어떤 순서 뒤에도 «새 턴 → 정상 종료» 는 반드시 대기로 끝난다" {
    // **안 풀리는 배지**의 일반형이다. 앞에 무엇이 왔든(이벤트 유실·자식 셈 어긋남·오류 잔재),
    // 새 프롬프트로 시작해 정상으로 끝난 턴은 «대기» 로 보여야 한다. 하나라도 아니면 그 pane 은
    // 사용자가 다시 프롬프트를 넣기 전까지 거짓말을 한다.
    const depth = 3;
    var seq: [depth]usize = .{0} ** depth;
    var total: usize = 0;
    while (true) {
        var progress: Progress = .{};
        var state: State = .unknown;
        for (seq) |i| state = advance(&progress, state, alphabetEvent(i));

        // 새 턴 → 정상 종료.
        state = advance(&progress, state, evOf(.user_prompt_submit));
        try testing.expectEqual(State.running, state);
        state = advance(&progress, state, evOf(.stop));
        if (state != .idle) {
            std.debug.print("안 풀린 순서: {any} → {s}\n", .{ seq, @tagName(state) });
            return error.StuckBadge;
        }
        total += 1;

        // 다음 순서(자리올림).
        var k: usize = 0;
        while (k < depth) : (k += 1) {
            seq[k] += 1;
            if (seq[k] < alphabet_len) break;
            seq[k] = 0;
        }
        if (k == depth) break;
    }
    try testing.expectEqual(alphabet_len * alphabet_len * alphabet_len, total);
}

test "전수: 알림은 턴 문을 건드리지 않는다 — 그것은 «일한다» 가 아니라 «기다린다» 다" {
    // 실측(2026-08-22): claude 의 알림 생성부는 공통 payload 를 **에이전트 인자 없이** 부른다. 그래서
    // 자식의 승인 요구(`worker_permission_prompt`)도 `agent_id` 가 빈 채 **lead 이벤트로** 온다
    // (`PermissionRequest` 는 그 인자를 넘겨 자식 것이 자식으로 온다). 이것으로 턴을 열면 lead 가 이미
    // `Stop` 을 보낸 뒤에도 턴이 되살아나 **마지막 자식이 끝나도 배지가 안 풀린다.**
    const depth = 3;
    var seq: [depth]usize = .{0} ** depth;
    while (true) {
        var progress: Progress = .{};
        var state: State = .unknown;
        for (seq) |i| state = advance(&progress, state, alphabetEvent(i));

        const open_before = progress.turn_open;
        var notice = evOf(.notification);
        notice.notification_type = .needs_input;
        _ = advance(&progress, state, notice);
        if (progress.turn_open != open_before) {
            std.debug.print("알림이 턴 문을 바꾼 순서: {any}\n", .{seq});
            return error.NoticeOpenedTurn;
        }

        var k: usize = 0;
        while (k < depth) : (k += 1) {
            seq[k] += 1;
            if (seq[k] < alphabet_len) break;
            seq[k] = 0;
        }
        if (k == depth) break;
    }
}

test "전수: 자식 셈은 알파벳 어디를 지나도 실제로 산 자식 수를 넘지 않는다" {
    // 셈이 새면 lead 의 `Stop` 이 영영 붙잡힌다. 상한은 «지금까지 본 `SubagentStart` 수» 다.
    const depth = 3;
    var seq: [depth]usize = .{0} ** depth;
    while (true) {
        var progress: Progress = .{};
        var state: State = .unknown;
        var started: u32 = 0;
        for (seq) |i| {
            const ev = alphabetEvent(i);
            // 알파벳의 자식 이벤트는 **같은 id** 를 쓰므로 담기는 것은 많아야 하나다. 같은 시작이
            // 여러 번 와도 셈이 부풀지 않는 것(중복 미담기)까지 여기서 함께 본다.
            if (ev.kind == .subagent_start and ev.agent_id.len != 0) started = 1;
            // 턴이 새로 열리면 셈이 버려지므로 기준도 함께 버린다.
            if ((ev.kind == .user_prompt_submit or ev.kind == .session_start) and ev.agent_id.len == 0)
                started = 0;
            state = advance(&progress, state, ev);
            try testing.expect(progress.childCount() <= started);
        }

        var k: usize = 0;
        while (k < depth) : (k += 1) {
            seq[k] += 1;
            if (seq[k] < alphabet_len) break;
            seq[k] = 0;
        }
        if (k == depth) break;
    }
}

test "전수: 알림은 «전이가 있을 때만» 나온다 — 같은 상태로 머무는 이벤트는 조용하다" {
    // 「턴 단위 1회」를 세는 코드 없이 얻는다는 계약 §6 의 주장을 순서 전체에서 확인한다.
    const depth = 3;
    var seq: [depth]usize = .{0} ** depth;
    while (true) {
        var progress: Progress = .{};
        var state: State = .unknown;
        for (seq) |i| {
            const prev = state;
            state = advance(&progress, state, alphabetEvent(i));
            if (prev == state) try testing.expectEqual(Notice.none, noticeOn(prev, state));
        }
        var k: usize = 0;
        while (k < depth) : (k += 1) {
            seq[k] += 1;
            if (seq[k] < alphabet_len) break;
            seq[k] = 0;
        }
        if (k == depth) break;
    }
}

test "전수: 자식이 떠도 «입력 대기» 는 안 지워진다 — 막힘이 이긴다" {
    // 병렬 워커 턴에서 하나가 승인 게이트에 걸린 채 다른 하나가 뜬다. 「자식이 떴다 = 돈다」로 덮으면
    // **사용자가 할 일이 있다는 신호만 골라 사라진다.** 관측 모드가 `visible_blocker` 를 최우선으로 두는
    // 것과 같은 규율이다 — 배지 열거를 공유하듯 그 우선순위도 공유한다.
    const depth = 3;
    var seq: [depth]usize = .{0} ** depth;
    while (true) {
        var progress: Progress = .{};
        var state: State = .unknown;
        for (seq) |i| state = advance(&progress, state, alphabetEvent(i));

        if (state == .blocked) {
            const after = advance(&progress, state, childEv(.subagent_start));
            if (after != .blocked) {
                std.debug.print("막힘이 지워진 순서: {any} → {s}\n", .{ seq, @tagName(after) });
                return error.BlockerErased;
            }
        }

        var k: usize = 0;
        while (k < depth) : (k += 1) {
            seq[k] += 1;
            if (seq[k] < alphabet_len) break;
            seq[k] = 0;
        }
        if (k == depth) break;
    }
}

test "전수: 자식 한 쌍만으로는 배지가 갇히지 않는다" {
    // 대기 상태에 `SubagentStart` 가 오면 «무언가 돈다» 로 밀리는데, 이어진 `SubagentStop` 이 그것을
    // 풀지 못하면 lead 의 `Stop` 은 이미 지나갔으므로 **풀어 줄 이벤트가 없다**. 「lead 가 끝났다」
    // 플래그로 물으면 «아직 시작 안 함» 과 «이미 끝남» 이 같은 값이 되어 그 자리가 생겼다.
    const depth = 3;
    var seq: [depth]usize = .{0} ** depth;
    while (true) {
        var progress: Progress = .{};
        var state: State = .unknown;
        for (seq) |i| state = advance(&progress, state, alphabetEvent(i));

        const before = state;
        const open_before = progress.turn_open;
        state = advance(&progress, state, childEv(.subagent_start));
        state = advance(&progress, state, childEv(.subagent_stop));
        // lead 의 턴이 안 열려 있었다면 자식 한 쌍은 **아무것도 바꾸지 않아야** 한다.
        if (!open_before and progress.childCount() == 0 and state == .running and before != .running) {
            std.debug.print("자식 한 쌍이 가둔 순서: {any} ({s} → {s})\n", .{ seq, @tagName(before), @tagName(state) });
            return error.StuckBadge;
        }

        var k: usize = 0;
        while (k < depth) : (k += 1) {
            seq[k] += 1;
            if (seq[k] < alphabet_len) break;
            seq[k] = 0;
        }
        if (k == depth) break;
    }
}

test "턴 키가 바뀌면 프롬프트를 못 봤어도 새 턴이다" {
    // `UserPromptSubmit` 은 유실될 수 있다(§4.3 동시 append·상한 초과). 그때 지난 턴의 자식 셈이
    // 넘어오면 lead 의 `Stop` 이 붙잡혀 **배지가 안 풀린다** — 고치려던 바로 그 부류다.
    var progress: Progress = .{};
    var first = evOf(.user_prompt_submit);
    first.turn_key = "turn-1";
    var state = advance(&progress, .idle, first);
    state = advance(&progress, state, childEv(.subagent_start));
    try testing.expectEqual(@as(usize, 1), progress.childCount());
    // 이 턴의 `Stop` 과 자식 종료를 **둘 다 놓쳤다** 고 하자.

    // 다음 턴의 프롬프트도 놓치고 도구 호출부터 봤다 — 키가 다르다.
    var next_tool = evOf(.pre_tool_use);
    next_tool.turn_key = "turn-2";
    state = advance(&progress, state, next_tool);
    try testing.expectEqual(@as(usize, 0), progress.childCount()); // 지난 턴의 셈을 버렸다
    try testing.expectEqualStrings("turn-2", progress.turnKey());

    // 그러니 이 턴의 `Stop` 은 정상적으로 끝난다.
    var done = evOf(.stop);
    done.turn_key = "turn-2";
    try testing.expectEqual(State.idle, advance(&progress, state, done));
}

test "같은 턴의 이벤트는 리셋을 만들지 않는다" {
    var progress: Progress = .{};
    var prompt = evOf(.user_prompt_submit);
    prompt.turn_key = "turn-1";
    var state = advance(&progress, .idle, prompt);
    state = advance(&progress, state, childEv(.subagent_start));

    var tool = evOf(.pre_tool_use);
    tool.turn_key = "turn-1"; // 같은 턴
    state = advance(&progress, state, tool);
    try testing.expectEqual(@as(usize, 1), progress.childCount()); // 셈이 살아 있다

    // 그리고 lead 가 끝나면 자식을 기다린다.
    var done = evOf(.stop);
    done.turn_key = "turn-1";
    state = advance(&progress, state, done);
    try testing.expectEqual(State.running, state);
    state = advance(&progress, state, childEv(.subagent_stop));
    try testing.expectEqual(State.idle, state);
}

test "자식의 턴 키는 부모의 턴을 바꾸지 않는다 — codex 의 자식은 자기 turn_id 를 쓴다" {
    var progress: Progress = .{};
    var prompt = evOf(.user_prompt_submit);
    prompt.turn_key = "turn-1";
    var state = advance(&progress, .idle, prompt);
    state = advance(&progress, state, childEv(.subagent_start));

    var child_tool = childEv(.pre_tool_use);
    child_tool.turn_key = "turn-child"; // 실측: codex 자식은 다른 turn_id 를 싣는다
    state = advance(&progress, state, child_tool);
    try testing.expectEqual(@as(usize, 1), progress.childCount()); // 부모의 셈이 살아 있다
    try testing.expectEqualStrings("turn-1", progress.turnKey());
}

test "처음 본 턴 키는 «바뀐 것» 이 아니다" {
    // 훅을 이미 돌던 세션에 붙이면 첫 이벤트가 턴 중간이다. 그것을 «턴이 바뀌었다» 로 읽어도 지울
    // 것이 없어 해는 없지만, 규칙을 분명히 해 둔다.
    var progress: Progress = .{};
    var tool = evOf(.pre_tool_use);
    tool.turn_key = "turn-9";
    _ = advance(&progress, .unknown, tool);
    try testing.expectEqualStrings("turn-9", progress.turnKey());
    try testing.expect(progress.turn_open); // 도구 호출이 턴을 열었다
}

test "세션을 여는 것만으로 «완료» 알림이 나가지 않는다" {
    // `SessionStart` 는 상태를 `idle` 로 놓는다. 그 직전이 `unknown` 이라 **전이는 생기지만**, 그것은
    // «턴이 끝났다» 가 아니라 «이제 알게 됐다» 다. 실사용 로그의 첫 줄이 `SessionStart` 라 이 결함이
    // 그 자리에서 드러났다 — 손으로 쓴 테스트는 첫 이벤트가 늘 프롬프트였다.
    var progress: Progress = .{};
    const state = advance(&progress, .unknown, evOf(.session_start));
    try testing.expectEqual(State.idle, state); // 배지는 «대기» 로 간다
    try testing.expectEqual(Notice.none, noticeOn(.unknown, state)); // 그러나 알리지는 않는다

    // 훅을 이미 돌던 세션에 붙어 첫 이벤트가 `Stop` 인 경우도 같다.
    try testing.expectEqual(Notice.none, noticeOn(.unknown, advance(&progress, .unknown, evOf(.stop))));

    // 대조: 진짜 턴이 끝나면 알린다.
    var p2: Progress = .{};
    const running = advance(&p2, .idle, evOf(.user_prompt_submit));
    try testing.expectEqual(Notice.done, noticeOn(running, advance(&p2, running, evOf(.stop))));
}

test "전수: «모르다» 에서 나오는 첫 전이는 조용하다" {
    const depth = 2;
    var seq: [depth]usize = .{0} ** depth;
    while (true) {
        var progress: Progress = .{};
        const state = advance(&progress, .unknown, alphabetEvent(seq[0]));
        try testing.expectEqual(Notice.none, noticeOn(.unknown, state));
        _ = seq[1];

        var k: usize = 0;
        while (k < depth) : (k += 1) {
            seq[k] += 1;
            if (seq[k] < alphabet_len) break;
            seq[k] = 0;
        }
        if (k == depth) break;
    }
}

test "실사용 순서: 남의 SubagentStop 이 섞여 와도 우리 자식이 끝날 때 풀린다(2026-08-21)" {
    // 실제 세션에서 받은 순서다. `SubagentStart` 는 **하나**(ac96…)인데 `SubagentStop` 이 **다섯 개의
    // 서로 다른 id** 로 왔고, 우리 것의 짝은 **맨 마지막**이었다. 개수를 세면 남의 첫 종료에서 이미
    // 0 이 되어 자식이 도는 중에 배지가 풀린다 — 그 결함을 이 순서가 잡았다.
    var progress: Progress = .{};
    var state: State = .unknown;

    state = advance(&progress, state, evOf(.user_prompt_submit));
    var spawn = evOf(.pre_tool_use);
    spawn.tool_name = "Agent";
    spawn.tool_description = "디렉터리 구조 조사";
    state = advance(&progress, state, spawn);
    state = advance(&progress, state, childEvId(.subagent_start, "ac963bb35f95b11fd"));
    try testing.expectEqual(@as(usize, 1), progress.childCount());

    // lead 가 먼저 답을 마쳤다 — 백그라운드로 띄웠다고 말하며, `background_tasks` 에 도는 것이 하나다.
    var lead_stop = evOf(.stop);
    lead_stop.text = "탐색 에이전트를 백그라운드로 띄웠습니다";
    state = advance(&progress, state, lead_stop);
    try testing.expectEqual(State.running, state);

    // **남의 에이전트 종료가 넷 섞여 온다.** 하나도 우리 자식이 아니다 — 배지는 그대로여야 한다.
    for ([_][]const u8{ "ab60fb9ff9", "a7b485fe68", "a9a53a68c2", "ac32d5a3e1" }) |other| {
        state = advance(&progress, state, childEvId(.subagent_stop, other));
        try testing.expectEqual(State.running, state);
        try testing.expectEqual(@as(usize, 1), progress.childCount());
    }

    // 그리고 **우리 자식**이 끝난다 — 그때가 진짜 턴 끝이다.
    state = advance(&progress, state, childEvId(.subagent_stop, "ac963bb35f95b11fd"));
    try testing.expectEqual(State.idle, state);
    try testing.expectEqual(@as(usize, 0), progress.childCount());
}

test "background_tasks 가 끝까지 도는 중이어도 자식이 끝나면 풀린다" {
    // 실측에서 마지막 자식 종료까지 `background_tasks` 는 계속 «도는 중 1» 이었다. 그것을 «아직 안
    // 끝났다» 의 근거로 쓰면 **배지가 영영 안 풀린다** — 0 이 되는 순간을 알려 줄 이벤트가 없다.
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit));
    state = advance(&progress, state, childEvId(.subagent_start, "c1"));
    var lead_stop = evOf(.stop);
    lead_stop.background_tasks_raw = "[{\"id\":\"c1\",\"type\":\"subagent\",\"status\":\"running\"}]";
    state = advance(&progress, state, lead_stop);
    try testing.expectEqual(State.running, state);

    const child_stop = childEvId(.subagent_stop, "c1");
    try testing.expectEqual(State.idle, advance(&progress, state, child_stop));
}

test "세션이 다시 시작돼도 «턴이 끝났습니다» 가 나가지 않는다" {
    // resume·컨텍스트 압축은 턴 중간에도 `SessionStart` 를 만든다(실측: 한 pane 에 startup·resume·
    // startup 이 이어서 왔고 resume 은 턴 키까지 실었다). 배지가 «진행 중» 일 때 그것이 오면 상태는
    // «대기» 로 가는데, 그 전이를 완료로 읽으면 **끝나지도 않은 턴에 완료 알림이 나간다**.
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit));
    try testing.expectEqual(State.running, state);

    const restart = evOf(.session_start);
    const before = state;
    state = advance(&progress, state, restart);
    try testing.expectEqual(State.idle, state); // 배지는 «대기» 로 간다
    try testing.expectEqual(Notice.done, noticeOn(before, state)); // 상태만 보면 «완료» 로 보이고
    try testing.expect(suppressesNotice(restart)); // 그래서 이벤트가 그것을 막는다

    // 대조: 진짜 턴 끝은 안 막는다.
    try testing.expect(!suppressesNotice(evOf(.stop)));
    try testing.expect(!suppressesNotice(evOf(.stop_failure)));
    try testing.expect(!suppressesNotice(evOf(.subagent_stop)));
}

test "자식을 상한까지 담고, 그 안에서는 마지막 하나가 끝날 때 풀린다" {
    // 워크플로가 자식을 크게 펼치는 경우다. 상한이 낮으면 넘친 자식이 배지를 못 붙잡아 **아직 도는데
    // 풀리는** 버그가 상한 너머에서 그대로 재현된다 — 그래서 자리를 해시로 바꿔 상한을 올렸다.
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit));

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < max_children) : (i += 1) {
        const id = try std.fmt.bufPrint(&buf, "child-{d}", .{i});
        state = advance(&progress, state, childEvId(.subagent_start, id));
    }
    try testing.expectEqual(max_children, progress.childCount());

    state = advance(&progress, state, evOf(.stop)); // lead 가 먼저 끝난다
    try testing.expectEqual(State.running, state);

    i = 0;
    while (i < max_children) : (i += 1) {
        const id = try std.fmt.bufPrint(&buf, "child-{d}", .{i});
        state = advance(&progress, state, childEvId(.subagent_stop, id));
        // **마지막 하나가 끝나기 전까지는 풀리지 않는다.**
        const expected: State = if (i + 1 == max_children) .idle else .running;
        try testing.expectEqual(expected, state);
    }
    try testing.expectEqual(@as(usize, 0), progress.childCount());
}

test "상한을 넘긴 자식은 붙잡지 못한다 — 그 방향을 골랐다는 사실을 못박는다" {
    // 넘치면 담지 못한 자식의 종료를 못 알아본다. 조기 해제 쪽으로 기울지만 다음 프롬프트가 정정한다.
    // 반대쪽(안 풀림)은 사용자가 손쓸 수 없다 — 그 비대칭이 이 선택의 근거다.
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit));
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < max_children + 3) : (i += 1) {
        const id = try std.fmt.bufPrint(&buf, "child-{d}", .{i});
        state = advance(&progress, state, childEvId(.subagent_start, id));
    }
    try testing.expectEqual(max_children, progress.childCount()); // 넘친 셋은 안 담긴다

    state = advance(&progress, state, evOf(.stop));
    i = 0;
    while (i < max_children) : (i += 1) {
        const id = try std.fmt.bufPrint(&buf, "child-{d}", .{i});
        state = advance(&progress, state, childEvId(.subagent_stop, id));
    }
    try testing.expectEqual(State.idle, state); // 넘친 셋이 아직 돌아도 여기서 풀린다

    // 그리고 새 프롬프트가 셈을 버려 다음 턴은 깨끗하다.
    state = advance(&progress, state, evOf(.user_prompt_submit));
    try testing.expectEqual(@as(usize, 0), progress.childCount());
}

test "회수: 종료를 놓친 유령을 lead 의 턴 끝에서 거둔다" {
    // 자식의 `SubagentStop` 이 유실되면(§4.3 인터리브·상한) 우리는 그 자식을 영영 붙잡는다. provider 가
    // 실어 주는 목록이 그것을 정리해 준다 — 도는 목록에 없으면 끝난 것이다.
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit));
    state = advance(&progress, state, childEvId(.subagent_start, "ghost"));
    state = advance(&progress, state, childEvId(.subagent_start, "alive"));
    try testing.expectEqual(@as(usize, 2), progress.childCount());

    // lead 가 끝난다. 목록에는 `alive` 만 도는 중이다 → `ghost` 는 거둬진다.
    var stop = evOf(.stop);
    stop.background_tasks_raw = "[{\"id\":\"alive\",\"type\":\"subagent\",\"status\":\"running\"}]";
    state = advance(&progress, state, stop);
    try testing.expectEqual(@as(usize, 1), progress.childCount()); // 유령이 사라졌다
    try testing.expectEqual(State.running, state); // 살아 있는 자식이 남아 붙잡는다

    // 그 자식이 끝나면 그때가 진짜 턴 끝이다.
    state = advance(&progress, state, childEvId(.subagent_stop, "alive"));
    try testing.expectEqual(State.idle, state);
}

test "회수: 목록이 모두 끝났다고 말하면 lead 의 Stop 이 곧 턴 끝이다" {
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit));
    state = advance(&progress, state, childEvId(.subagent_start, "c1"));

    var stop = evOf(.stop);
    // 목록은 있는데 도는 서브에이전트가 없다(끝났거나 셸뿐이다).
    stop.background_tasks_raw = "[{\"id\":\"c1\",\"type\":\"subagent\",\"status\":\"completed\"}]";
    state = advance(&progress, state, stop);
    try testing.expectEqual(@as(usize, 0), progress.childCount());
    try testing.expectEqual(State.idle, state);
}

test "회수: 잘리거나 어긋난 목록으로는 거두지 않는다 — 살아 있는 자식을 지우는 쪽이 더 나쁘다" {
    // **대조**: 완전하고 비어 있는 목록은 «다 끝났다» 라는 뜻이라 거둔다. 잘린 목록과 구분되는 지점이다.
    {
        var progress: Progress = .{};
        var state = advance(&progress, .idle, evOf(.user_prompt_submit));
        state = advance(&progress, state, childEvId(.subagent_start, "c1"));
        var stop = evOf(.stop);
        stop.background_tasks_raw = "[]";
        state = advance(&progress, state, stop);
        try testing.expectEqual(@as(usize, 0), progress.childCount());
        try testing.expectEqual(State.idle, state);
    }
    // 어긋난 목록(닫히지 않음) — 거두지 않는다.
    {
        var progress: Progress = .{};
        var state = advance(&progress, .idle, evOf(.user_prompt_submit));
        state = advance(&progress, state, childEvId(.subagent_start, "c1"));
        var stop = evOf(.stop);
        stop.background_tasks_raw = "[{\"id\":\"c1\",\"type\":\"subagent\"";
        state = advance(&progress, state, stop);
        try testing.expectEqual(@as(usize, 1), progress.childCount()); // 그대로 붙잡는다
        try testing.expectEqual(State.running, state);
    }
    // 목록 자체가 없으면(키 부재) 역시 거두지 않는다.
    {
        var progress: Progress = .{};
        var state = advance(&progress, .idle, evOf(.user_prompt_submit));
        state = advance(&progress, state, childEvId(.subagent_start, "c1"));
        state = advance(&progress, state, evOf(.stop)); // background_tasks_raw 없음
        try testing.expectEqual(@as(usize, 1), progress.childCount());
        try testing.expectEqual(State.running, state);
    }
}

test "회수는 lead 의 턴 끝에서만 한다 — 자식이 막 떴을 때 거두면 산 것을 지운다" {
    var progress: Progress = .{};
    var state = advance(&progress, .idle, evOf(.user_prompt_submit));
    state = advance(&progress, state, childEvId(.subagent_start, "fresh"));

    // 목록을 실은 **도구 호출**이 온다. 아직 그 자식이 목록에 안 실렸다고 하자.
    var tool = evOf(.pre_tool_use);
    tool.tool_name = "Bash";
    tool.background_tasks_raw = "[]";
    state = advance(&progress, state, tool);
    try testing.expectEqual(@as(usize, 1), progress.childCount()); // 거두지 않는다
}

test "Notification 의 «입력 대기» 종류는 배지를 옮긴다 — 다른 종류는 조용하다" {
    // 「입력 대기」의 다른 소스(`PermissionRequest`)는 실측에서 한 번도 발화하지 않았다. 그것 하나에만
    // 걸면 대화형에서도 안 올 때 그 배지에 소스가 없다 — 독립적인 둘을 둔다.
    var needs = evOf(.notification);
    needs.notification_type = .needs_input;
    try testing.expectEqual(State.blocked, next(.running, needs));
    try testing.expectEqual(Notice.attention, noticeOn(.running, next(.running, needs)));

    // 유휴 알림·인증 성공 같은 것은 배지를 흔들지 않는다.
    var other = evOf(.notification);
    other.notification_type = .other;
    try testing.expectEqual(State.running, next(.running, other));
    try testing.expectEqual(State.idle, next(.idle, other));

    // 종류가 없는 알림도 마찬가지다 — 모르면 안 옮긴다.
    try testing.expectEqual(State.running, next(.running, evOf(.notification)));
}

test "자식이 보낸 Notification 은 부모 배지를 옮기지 않는다" {
    var child = evOf(.notification);
    child.notification_type = .needs_input;
    child.agent_id = "child-1";
    try testing.expectEqual(State.running, next(.running, child));
}

test "자식이 남은 뒤 온 알림이 턴을 다시 열면 배지가 영영 안 풀린다" {
    // 실측: `worker_permission_prompt` 는 **`agent_id` 없이** 온다(claude 의 알림 생성부는 에이전트
    // 문맥을 안 넘긴다). 그래서 자식의 승인 요구가 **lead 이벤트로** 도착한다 — lead 가 이미 `Stop` 을
    // 보낸 뒤에도. 그때 턴이 다시 열리면 마지막 자식이 끝나도 «턴이 안 끝났다» 가 되어 안 풀린다.
    var progress = Progress{};
    var state = State.unknown;

    const prompt = evOf(.user_prompt_submit);
    state = advance(&progress, state, prompt);

    var start = evOf(.subagent_start);
    start.agent_id = "c1";
    state = advance(&progress, state, start);

    const stop = evOf(.stop);
    state = advance(&progress, state, stop);
    try testing.expectEqual(State.running, state); // 자식이 붙잡는다 — 옳다

    var notice = evOf(.notification);
    notice.notification_type = .needs_input;
    state = advance(&progress, state, notice);
    try testing.expectEqual(State.blocked, state); // 승인이 필요하다 — 옳다

    var child_done = evOf(.subagent_stop);
    child_done.agent_id = "c1";
    state = advance(&progress, state, child_done);
    // 마지막 자식이 끝났고 lead 는 이미 `Stop` 을 보냈다 — 턴은 끝났다.
    try testing.expectEqual(State.idle, state);
}

test "승인을 기다리는 중에 자식이 떠도 «입력 대기» 가 지워지지 않는다" {
    // 병렬 워커 턴에서 한 자식이 승인 게이트에 걸리고(그 알림은 `agent_id` 없이 lead 로 온다) 다른 자식이
    // 이어서 뜬다. 「자식이 떴다 = 돈다」로 덮으면 **사용자가 할 일이 있다는 신호가 사라진다** — 관측 모드가
    // `visible_blocker` 를 최우선으로 두는 것과 같은 이유로, 막힘이 이긴다.
    var progress = Progress{};
    var state = advance(&progress, .unknown, evOf(.user_prompt_submit));

    var first = evOf(.subagent_start);
    first.agent_id = "c1";
    state = advance(&progress, state, first);
    try testing.expectEqual(State.running, state);

    var notice = evOf(.notification);
    notice.notification_type = .needs_input;
    state = advance(&progress, state, notice);
    try testing.expectEqual(State.blocked, state);

    var second = evOf(.subagent_start);
    second.agent_id = "c2";
    state = advance(&progress, state, second);
    try testing.expectEqual(State.blocked, state); // 여전히 사용자를 기다린다
    try testing.expectEqual(@as(usize, 2), progress.childCount()); // 셈은 그대로 는다
}

test "지난 턴의 알림이 늦게 와도 이번 턴의 자식 셈을 지우지 않는다" {
    // 알림은 **턴 진행의 증거가 아니다**(§6). 그런데 공통 payload 를 타고 `prompt_id` 를 싣고 오므로,
    // 지난 턴의 워커 승인 요구가 늦게 도착하면 «턴 키가 바뀌었다» 로 읽혀 **이번 턴의 자식 셈이 지워진다**
    // — 그러면 lead 의 `Stop` 이 자식을 안 기다리고 배지가 일찍 풀린다.
    var progress = Progress{};

    var first = evOf(.user_prompt_submit);
    first.turn_key = "turn-1";
    var state = advance(&progress, .unknown, first);

    var second = evOf(.user_prompt_submit);
    second.turn_key = "turn-2";
    state = advance(&progress, state, second);

    var child = evOf(.subagent_start);
    child.agent_id = "c1";
    state = advance(&progress, state, child);
    try testing.expectEqual(@as(usize, 1), progress.childCount());

    // 지난 턴(turn-1)의 알림이 늦게 도착한다.
    var late = evOf(.notification);
    late.notification_type = .needs_input;
    late.turn_key = "turn-1";
    state = advance(&progress, state, late);
    try testing.expectEqual(@as(usize, 1), progress.childCount()); // 셈은 살아 있어야 한다
}

test "신원은 모든 lead 이벤트가 싣는다 — 알림도 포함이다(턴 진행 규칙과 다른 규칙이다)" {
    // 실측(2026-08-24, 훅 로그 5,221 이벤트): `session_id` 는 provider·종류 무관하게 100% 실렸다.
    // 그래서 채택을 특정 이벤트에 묶지 않는다 — maru 가 세션 중간에 붙어 첫 이벤트가 `PreToolUse` 여도
    // 신원이 선다.
    var ev: event.Event = .{ .kind = .notification, .session_id = "S1" };
    try std.testing.expect(carriesSessionIdentity(ev));
    // ⚠️ 여기가 `marksTurnProgress` 와 갈리는 자리다 — 그쪽은 알림을 뺀다(턴 진행의 증거가 아니라서).
    try std.testing.expect(!marksTurnProgress(ev));

    ev = .{ .kind = .pre_tool_use, .session_id = "S1" };
    try std.testing.expect(carriesSessionIdentity(ev));
    ev = .{ .kind = .session_start, .session_id = "S1" };
    try std.testing.expect(carriesSessionIdentity(ev));
}

test "자식 이벤트와 빈 값은 신원을 싣지 않는다" {
    // 자식은 부모의 신원을 옮기지 않는다(계약 §2). codex 자식이 자기 축을 싣고 온다는 실측이 근거다.
    try std.testing.expect(!carriesSessionIdentity(.{ .kind = .stop, .session_id = "OTHER", .agent_id = "a5" }));
    // 빈 값은 «모른다» 이지 «지워라» 가 아니다 — 아는 신원을 이 경로로 날리지 않는다.
    try std.testing.expect(!carriesSessionIdentity(.{ .kind = .stop, .session_id = "" }));
    try std.testing.expect(!carriesSessionIdentity(.{ .kind = .unknown }));
}

test "SessionStart 뒤에도 턴 키가 남는다 — 그래서 base 에 그대로 실으면 안 된다" {
    // `reset()` 이 키를 남기는 것은 **옳다**(같은 턴의 다음 이벤트가 «키가 바뀌었다» 로 읽히면 매번
    // 리셋이 돈다). 그 성질을 여기서 못 박아, 소비자가 그것을 모른 채 «지금 키» 로 쓰는 것을 막는다 —
    // 실제로 그 실수가 base 스냅샷에 직전 턴의 키를 실었다(2026-08-25).
    var p: Progress = .{};
    var prompt: event.Event = .{ .kind = .user_prompt_submit };
    prompt.turn_key = "p-1";
    _ = advance(&p, .unknown, prompt);
    try std.testing.expectEqualStrings("p-1", p.turnKey());

    _ = advance(&p, .running, .{ .kind = .session_start });
    // 진행 상태는 지워졌는데 **키는 남는다**.
    try std.testing.expectEqual(@as(usize, 0), p.childCount());
    try std.testing.expectEqualStrings("p-1", p.turnKey());
}

test "세션 base 는 «돌고 있지 않을 때» 의 SessionStart 다" {
    const start: event.Event = .{ .kind = .session_start };
    // cold start · `/clear` 직후 · 승인 대기 중 resume — 셋 다 base 다.
    try std.testing.expect(opensSessionBase(.unknown, start));
    try std.testing.expect(opensSessionBase(.idle, start));
    try std.testing.expect(opensSessionBase(.blocked, start));
    // **돌고 있으면 base 가 아니다** — 그 전이는 이미 «턴 끝» 으로 찍힌다(resume·컨텍스트 압축).
    try std.testing.expect(!opensSessionBase(.running, start));

    // 다른 이벤트는 세션을 열지 않는다.
    for ([_]event.Kind{ .stop, .user_prompt_submit, .pre_tool_use, .notification }) |k| {
        try std.testing.expect(!opensSessionBase(.unknown, .{ .kind = k }));
    }
    // 자식은 세션을 열지 않는다.
    try std.testing.expect(!opensSessionBase(.unknown, .{ .kind = .session_start, .agent_id = "a5" }));
}

test "원격 채널이 열리면 훅 모드다 — agent_kind 는 ssh 너머에서 영영 none 이다" {
    // 계약 §11.1: 원격 process tree 가 로컬에서 안 보여 `agent_present` 가 못 선다. 채널이 그 자리를
    // 대신한다 — 그 채널은 훅이 쓴 파일을 흘리는 길이라, 열렸다는 것이 곧 훅이 돈다는 증거다.
    try testing.expectEqual(Mode.hook, modeFor(.{ .remote_channel_open = true, .gate_on = true }));
    // 게이트가 꺼져 있으면 원격도 관측 모드다 — 사용자가 끈 것을 우회하지 않는다.
    try testing.expectEqual(Mode.observe, modeFor(.{ .remote_channel_open = true, .gate_on = false }));
}

test "원격 축이 로컬 판정을 안 건드린다 — 여덟 조합 전수로 옛 규칙과 대조한다" {
    // 손으로 고른 몇 개가 아니라 gate·log·agent 의 **모든** 조합을 옛 규칙과 나란히 놓는다.
    for ([_]bool{ false, true }) |gate| {
        for ([_]bool{ false, true }) |log| {
            for ([_]bool{ false, true }) |agent| {
                const got = modeFor(.{ .gate_on = gate, .log_present = log, .agent_present = agent });
                const want: Mode = if (!agent) .observe else if (!gate) .observe else if (log) .hook else .observe;
                try testing.expectEqual(want, got);
            }
        }
    }
    // 그리고 기본값이 원격을 안 켠다 — 새 필드가 기존 호출자를 안 바꾼다.
    const p: Probe = .{};
    try testing.expect(!p.remote_channel_open);
}

test "원격이 켜지면 다른 셋이 무엇이든 게이트만 본다" {
    for ([_]bool{ false, true }) |log| {
        for ([_]bool{ false, true }) |agent| {
            try testing.expectEqual(Mode.hook, modeFor(.{ .remote_channel_open = true, .gate_on = true, .log_present = log, .agent_present = agent }));
            try testing.expectEqual(Mode.observe, modeFor(.{ .remote_channel_open = true, .gate_on = false, .log_present = log, .agent_present = agent }));
        }
    }
    // 채널이 죽으면 원격 Term 은 로컬 로그가 없으므로 즉시 관측 모드로 내려간다.
    try testing.expectEqual(Mode.observe, modeFor(.{ .remote_channel_open = false, .gate_on = true }));
}

test "CwdLabel: 절대 경로만·상한 안에서만 담고, 못 담으면 앞 값을 지키지 않는다" {
    var l: CwdLabel = .{};
    try testing.expect(l.isEmpty());

    l.set("/a/b", 1000);
    try testing.expectEqualStrings("/a/b", l.text());

    // **상한을 정확히 채우는 것은 담는다**(경계 한 칸 차이가 잘린 경로를 만든다).
    var exact: [CwdLabel.max_text]u8 = undefined;
    exact[0] = '/';
    @memset(exact[1..], 'a');
    l.set(&exact, 1000);
    try testing.expectEqual(@as(usize, CwdLabel.max_text), l.text().len);

    // **넘치면 안 담는다.** 잘라 담으면 그 값은 «남의 디렉터리» 를 가리킨다 — 표시에도 판정에도 쓰면
    // 안 되므로 「모른다」로 두는 편이 맞다. 그리고 앞 값은 그대로 남는다(마지막으로 아는 좋은 값).
    var over: [CwdLabel.max_text + 1]u8 = undefined;
    over[0] = '/';
    @memset(over[1..], 'b');
    l.set(&over, 1000);
    try testing.expectEqual(@as(usize, CwdLabel.max_text), l.text().len);
    try testing.expectEqual(@as(u8, 'a'), l.text()[1]); // 앞 값이 그대로다

    // 상대 경로도 안 담는다 — 어느 기준인지 이쪽이 모른다.
    l.set("relative/x", 1000);
    try testing.expectEqual(@as(u8, 'a'), l.text()[1]);

    // 빈 값도 안 담는다.
    l.set("", 1000);
    try testing.expectEqual(@as(usize, CwdLabel.max_text), l.text().len);

    l.clear();
    try testing.expect(l.isEmpty());
}

test "CwdLabel: 오래되면 안 믿는다 — 원격에는 «에이전트가 사라졌다» 신호가 없다" {
    // 원격 pane 은 채널이 열려 있는 한 훅 모드가 유지되고 `agent_kind` 재판정도 안 돈다. 그래서
    // 에이전트를 끝내고 ssh 안에 남아 `cd` 하면, 만료가 없을 때 이 값이 **살아 있는 OSC 7 을 영영
    // 덮는다**. 턴이 도는 동안에는 매 이벤트가 값을 새로 하므로 만료되지 않는다.
    var l: CwdLabel = .{};
    try testing.expect(!l.fresh(0)); // 빈 값은 애초에 안 믿는다

    l.set("/srv/app", 1_000);
    try testing.expect(l.fresh(1_000));
    try testing.expect(l.fresh(1_000 + CwdLabel.stale_after_ms)); // 경계는 아직 산다
    try testing.expect(!l.fresh(1_000 + CwdLabel.stale_after_ms + 1)); // 한 칸 넘으면 죽는다

    // 새 이벤트가 오면 다시 산다(턴이 도는 동안 만료되지 않는 이유).
    l.set("/srv/app", 1_000 + CwdLabel.stale_after_ms + 1);
    try testing.expect(l.fresh(1_000 + CwdLabel.stale_after_ms + 1));

    // **시계가 뒤로 가면 버리지 않는다** — 단조 시계를 쓰지만 방어한다.
    try testing.expect(l.fresh(0));
}
