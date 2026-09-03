//! 훅과 화면·OSC 두 소스를 **한 판정**으로 합치는 순수 층([agent-hooks.md](../../docs/agent-hooks.md) §1.1).
//!
//! 소스를 우선순위로 줄 세우지 않는다 — 어느 쪽을 위에 놓아도 하나가 깨진다. 훅을 위에 놓으면 승인이
//! 풀려도 배지가 안 바뀌고(훅에 해제 이벤트가 없다), 화면을 위에 놓으면 자식이 도는데 「완료」가 나간다
//! (화면에 자식 수가 없다). 그래서 **질문마다 답할 자격이 있는 쪽**을 §1.1 권위표가 정하고, 이 파일은
//! 그 표를 그대로 옮긴 것이다.
//!
//! **표에 없는 뒤집기는 금지다.** 「신호가 더 세다」 같은 판단을 여기 넣지 않는다 — §1 이 «추측을 없앤
//! 채로 합친다» 고 한 것의 실질이 그 금지다. 화면이 훅을 이기는 자리는 C1·C2·C3 셋뿐이고, 그 셋은
//! «훅이 구조적으로 모르는 질문» 에 정확히 대응한다.
//!
//! 화면 소스 **안쪽**의 흔들림은 여기서 다루지 않는다 — `agent_observer.Stabilizer` 가 이미 근거 있는
//! 상태와 약한 폴백을 중재한다. 이 파일이 받는 `screen` 은 그것을 통과한 뒤의 값이다.

const std = @import("std");
const observer = @import("agent_observer.zig");

pub const State = observer.State;

/// 그 상태를 세운 **근거**. 전송 수단이 아니다 — SSH 너머에서 relay 된 훅 이벤트도 `hook` 이다(§1.4).
///
/// 뒤집힌 것도 기록한다. C1·C2 가 훅 상태를 덮으면 `screen` 이 되고, 그것이 곧 «훅이 아니라 화면이 이
/// 배지를 만들었다» 는 버그 보고의 근거다. 남기지 않으면 뒤집기를 열거로 제한한 의미가 절반 사라진다.
pub const Origin = enum {
    hook,
    screen,
    osc_title,
    osc_progress,
    /// 어느 규칙도 안 맞아 `output_active` 폴백이 세웠다(§1.1 E).
    pty,
    /// 프로세스 종료(§1.1 C3). 훅·화면 둘 다 필요 없는 가장 강한 증거다.
    process_exit,
};

/// 화면 판정의 규칙 id 를 `Origin` 으로 옮긴다(§1.4).
///
/// **규칙 id 를 보는 것이 region 을 보는 것보다 정확하다** — 같은 region 에서도 title 규칙과 화면 규칙이
/// 함께 나오고, 알고 싶은 것은 «무엇이 이 상태를 만들었나» 이기 때문이다.
///
/// 순수 층에 두는 이유는 **판정자를 세우기 위해서다.** 호출부(플랫폼 층)에 두면 매핑이 틀려도 아무도 안
/// 잡고, 그러면 §1.4 의 「출처를 기록한다」가 조용히 거짓말이 된다.
pub fn originOfRule(rule_id: []const u8) Origin {
    if (std.mem.eql(u8, rule_id, "pty_activity")) return .pty;
    if (std.mem.startsWith(u8, rule_id, "progress_")) return .osc_progress;
    if (std.mem.endsWith(u8, rule_id, "_title")) return .osc_title;
    return .screen;
}

/// 이 규칙이 **훅을 뒤집은** 것인가(§1.4 — 화면이 배지를 만들었다).
///
/// 화면이 이긴 자리는 C1·C2·C3 셋뿐이고, 그때만 사용자에게 표식을 보인다. **평소(B)는 조용해야 한다** —
/// 훅이 정한 대로인 것이 예상이고, 늘 표식이 뜨면 그 신호가 아무 뜻도 없어진다.
///
/// ⚠️ **`C2-pending` 은 뒤집힌 것이 아니다.** 세는 중일 뿐 상태는 훅의 것이라(`origin` 도 `hook` 이다)
/// 접두 비교(`r[0] == 'C'`)로 잡으면 「곧 뒤집힐지도 모른다」를 「뒤집혔다」로 보여 준다.
///
/// `A` 경로도 `origin` 이 `screen` 일 수 있지만 그것은 훅이 없는 것이지 뒤집은 것이 아니다 — 그래서
/// `origin` 이 아니라 **규칙 이름**으로 판단한다.
pub fn ruleIsFlip(rule: []const u8) bool {
    return std.mem.eql(u8, rule, "C1") or
        std.mem.eql(u8, rule, "C2") or
        std.mem.eql(u8, rule, "C3");
}

pub const Input = struct {
    /// 훅이 세운 상태. **`null` 이면 훅 소스가 없다**(§1.1 A) — 설치 안 됨·게이트 꺼짐·로그 파일 없음이
    /// 전부 여기로 접힌다. 판정은 §1.2 가 소유하고 이 파일은 결과만 받는다.
    hook: ?State = null,
    /// 살아 있는 자식 수(`liveSubagentIds` 가 센 것). D1 이 이 값 하나로 선다.
    hook_child_count: u32 = 0,
    /// `agent_observer` + `Stabilizer` 를 통과한 화면·OSC 상태.
    screen: State = .unknown,
    /// 화면에 승인 chrome 이 **지금** 보이는가. C1 이 이것의 부재로 선다.
    screen_visible_blocker: bool = false,
    /// 화면에 idle chrome 이 **지금** 보이는가. C2 가 이것의 연속 관측으로 선다.
    screen_visible_idle: bool = false,
    /// 화면 상태를 세운 근거. A 경로에서 그대로 `Verdict.origin` 이 된다.
    screen_origin: Origin = .screen,
    process_exited: bool = false,
    /// 훅이 연 **턴**의 일련번호. 호출자가 `turn_key`(claude `prompt_id`·codex `turn_id`)가 바뀔 때 올린다.
    ///
    /// **이것이 없으면 C2 가 한 번 성공한 뒤 다음 턴을 즉시 접는다**(적대적 검증 R8 에서 실제로 재현했다).
    /// C2 가 idle 을 낸 뒤 카운터는 3 에 남아 있고, 사용자가 새 프롬프트를 넣어 훅이 running 이 되어도
    /// 화면은 폴링 주기(500ms) 동안 이전 idle chrome 을 들고 있다 — 그 첫 판정에서 카운터가 4가 되어
    /// **확인 절차 없이 완료**가 된다. 새 턴은 처음부터 세야 한다.
    hook_turn_seq: u64 = 0,
    /// 화면을 **새로 읽은 횟수**. 호출자가 실제로 화면을 판정할 때마다 올린다.
    ///
    /// **C2 는 중재 호출이 아니라 화면 관측을 센다.** 한 tick 에 중재가 여러 번 불릴 수 있고(원격 채널
    /// 드레인과 폴링 소비자가 각자 부른다) 그때마다 세면 임계에 **몇 배 빨리** 닿는다 — 「연속 3회 관측」
    /// 이라는 말이 「연속 3회 호출」로 조용히 바뀐다. 이 값이 그대로면 C2 는 세지 않고 직전 판단을 잇는다.
    screen_seq: u64 = 0,
};

pub const Verdict = struct {
    state: State,
    origin: Origin,
    /// 권위표의 어느 행이 세웠는가(`"A"`·`"B"`·`"C1"`·`"C2"`·`"C2-pending"`·`"C3"`·`"D1"`·`"D2"`).
    ///
    /// 진단용이다. `origin` 이 «누가» 라면 이것은 «어느 규칙으로» 이고, 둘이 같이 있어야 «화면이 이겼다»
    /// 를 넘어 «화면이 C2 로 이겼다» 까지 말할 수 있다. 문자열은 전부 컴파일 타임 상수라 수명이 없다.
    rule: []const u8,
};

pub const Arbiter = struct {
    /// C2 가 본 연속 idle 관측 수. **연속이라야 한다** — 중간에 다른 화면이 한 번이라도 끼면 0으로 돌아간다.
    idle_confirmations: u8 = 0,
    /// 마지막으로 본 `Input.hook_turn_seq`. 턴이 바뀌면 위 셈을 버린다(그 필드의 주석 참고).
    last_turn_seq: u64 = 0,
    /// 마지막으로 **센** 화면 관측의 `screen_seq`. 같은 관측을 두 번 세지 않게 한다.
    last_counted_screen_seq: u64 = 0,

    /// 화면 idle 이 훅 running 을 덮으려면 필요한 연속 관측 수(§1.1 C2).
    ///
    /// **왜 확인이 필요한가**: 화면의 idle 은 «활동 증거의 **부재**» 다. 스크롤·재그리기·짧은 정적 구간이
    /// 전부 같은 모양이라, 한 번 보고 훅을 덮으면 도는 턴이 완료로 뒤집힌다. 반대로 승인 chrome 이 사라진
    /// 것(C1)은 «그 자리에 있던 것이 없어졌다» 는 **양성 관찰**이라 즉시 믿는다 — 이 비대칭이 §1 의 ⑴ 이다.
    ///
    /// 3인 근거는 herdr 의 같은 축(`AGENT_PENDING_IDLE_CONFIRMATIONS = 3`)이다. 그쪽은 시간 상한(700ms)도
    /// 같이 걸지만 우리는 걸지 않는다 — 상한이 만료로 «확인 없이» 통과시키는 길을 열어, C2 를 무겁게 둔
    /// 이유를 되돌린다. 우리 쪽 탈출구는 시간이 아니라 `StopFailure`(claude)와 프로세스 종료(C3)다.
    pub const idle_confirmations_required: u8 = 3;

    pub fn reset(self: *Arbiter) void {
        self.* = .{};
    }

    /// §1.1 권위표. **순서가 곧 계약이다** — 아래 주석의 행 이름이 문서의 행과 1:1 로 대응한다.
    pub fn arbitrate(self: *Arbiter, in: Input) Verdict {
        // 턴이 바뀌었으면 C2 의 연속 셈을 버린다. **모든 규칙보다 먼저다** — 아래 어느 분기가 이기든
        // 그 셈은 지난 턴의 것이고, 지난 턴의 관측으로 이번 턴을 접으면 안 된다.
        if (in.hook_turn_seq != self.last_turn_seq) {
            self.idle_confirmations = 0;
            self.last_turn_seq = in.hook_turn_seq;
        }

        // C3 — 프로세스가 죽었으면 훅도 화면도 필요 없다. 확인 절차 없이 즉시 idle.
        if (in.process_exited) {
            self.idle_confirmations = 0;
            return .{ .state = .idle, .origin = .process_exit, .rule = "C3" };
        }

        // A — 훅 소스가 없다. 화면이 상태를 세운다(예전 «관측 모드» 가 하던 그대로).
        const hook = in.hook orelse {
            self.idle_confirmations = 0;
            return .{ .state = in.screen, .origin = in.screen_origin, .rule = "A" };
        };

        // D1 — 자식이 살아 있으면 화면과 **무관하게** running 이다(계약 §2). 자식이 도는 동안 lead 의
        // `Stop` 은 턴 끝이 아니고, 그 사실은 화면에 근거가 없다.
        //
        // **C1 보다 위에 있다.** 자식이 도는 동안에도 승인 chrome 은 사라질 수 있는데(자식이 자기 승인을
        // 받고 진행), 그때 C1 이 먼저 서면 running 을 running 으로 바꾸는 무의미한 뒤집기가 `origin` 을
        // screen 으로 만든다 — 배지는 같은데 출처만 거짓이 된다.
        if (hook == .running and in.hook_child_count > 0) {
            self.idle_confirmations = 0;
            return .{ .state = .running, .origin = .hook, .rule = "D1" };
        }

        // C1 — 훅이 blocked 인데 화면에 승인 chrome 이 없다. 승인은 풀렸다.
        //
        // ⚠️ **화면을 한 번이라도 읽었어야 한다**(`screen_seq != 0`). C1 은 chrome 의 **부재**로 서는
        // 유일한 규칙이라, 「화면에 없다」와 「화면을 아직 안 봤다」가 같은 값(`false`)으로 온다. 구분하지
        // 않으면 화면을 못 읽은 Term(원격 채널만 있는 pane, 훅 이벤트만 처리한 tick)에서 **승인 대기가
        // 뜨자마자 풀린다.** C2 는 `visible_idle == true` 가 관측을 스스로 증명하므로 이 가드가 필요 없다.
        //
        // **결과가 running 이지 화면 상태가 아니다.** 승인이 풀린 순간 화면이 이미 idle chrome 을 보이더라도
        // 여기서는 running 까지만 간다. 화면 상태를 그대로 실으면 blocked → idle 이 **한 tick 에** 일어나
        // C2 의 연속 확인을 통째로 우회한다. 훅은 승인 요청 직전에 running 이었으므로(`PreToolUse`) 그
        // 자리로 돌리는 것이 사실에도 맞다.
        if (hook == .blocked and in.screen_seq != 0 and !in.screen_visible_blocker) {
            self.idle_confirmations = 0;
            return .{ .state = .running, .origin = .screen, .rule = "C1" };
        }

        // C2 — 훅은 running 인데 자식이 없고 화면이 idle 을 **연속으로** 보인다. codex 오류 턴이 여기서
        // 닫힌다(§9-10 — codex 에는 `StopFailure` 가 없어 `Stop` 이 오지 않는다).
        if (hook == .running and in.hook_child_count == 0 and in.screen_visible_idle) {
            // **같은 화면 관측을 두 번 세지 않는다**(`Input.screen_seq` 주석). 중재가 다시 불렸을 뿐이면
            // 셈은 그대로 두고 지금까지의 판단을 잇는다.
            if (in.screen_seq != self.last_counted_screen_seq) {
                self.last_counted_screen_seq = in.screen_seq;
                self.idle_confirmations +|= 1;
            }
            if (self.idle_confirmations >= idle_confirmations_required) {
                return .{ .state = .idle, .origin = .screen, .rule = "C2" };
            }
            // 아직 못 미쳤다. 훅 상태를 유지하되 «세는 중» 임을 rule 에 남긴다 — 남기지 않으면 C2 가
            // 도는 중인지 아예 안 걸린 것인지 로그에서 구분할 수 없다.
            return .{ .state = hook, .origin = .hook, .rule = "C2-pending" };
        }
        // 연속이 끊겼다. C2 는 «연속» 이라야 하므로 여기서 0 으로 돌린다.
        self.idle_confirmations = 0;

        // B0 — **훅이 아직 모르면 화면이 답한다.** 로그 파일은 생겼는데 우리가 그 이벤트를 아직 못 읽은
        // 구간이 있고(그리고 훅이 유실된 구간도), 그때 `hook` 은 `.unknown` 이다. 아래 D2·B 는 「훅이
        // 안다」를 전제하므로 그대로 두면 **화면이 승인 프롬프트를 보고 있는데 배지가 `unknown` 이다.**
        // §1 이 「훅이 유실됐을 때 화면이 그대로 본다」고 적은 자리이기도 하다.
        if (hook == .unknown and in.screen != .unknown) {
            return .{ .state = in.screen, .origin = in.screen_origin, .rule = "B0" };
        }

        // D2 — 훅이 도는 동안 화면만 blocked 다. **무시한다.**
        //
        // 스크롤백에 남은 옛 승인 문구를 지금 요구로 읽는 오탐이 이 자리에서 걸린다. 승인 요구는
        // `PermissionRequest` 가 아는 것이고, 훅이 살아 있는데 그것이 안 왔다면 요구가 없는 것이다.
        if (in.screen == .blocked and hook != .blocked) {
            return .{ .state = hook, .origin = .hook, .rule = "D2" };
        }

        // B — 기본 권위. 위 C 셋만이 이것을 뒤집는다.
        return .{ .state = hook, .origin = .hook, .rule = "B" };
    }
};

/// 화면 스캔을 건너뛰어도 되는지(§1.1 C2 · 적대적 검증 2026-09-01).
///
/// **왜 순수 층에 있나**: 이 판단이 틀리면 C2 가 조용히 굶는다 — 배지가 「진행 중」에 남는 증상만 보이고
/// 원인은 「화면을 안 읽었다」라 재현이 어렵다. 호출부(`pollAgentState`)의 if 문 안에 두면 판정자를 세울
/// 자리가 없어, 실제로 그 상태로 한 번 커밋됐다. herdr 도 같은 판단을 순수 층에 둔다
/// (`should_skip_idle_screen_scan` — 같은 문제를 같은 모양으로 풀었다).
pub const ScanSkip = struct {
    hook: ?State = null,
    hook_child_count: u32 = 0,
    screen: State = .unknown,
    idle_confirmations: u8 = 0,
    /// 화면 내용이 그대로인가(TerminalCore write seq 가 안 움직였다).
    generation_same: bool = false,
    output_active: bool = false,
    /// `Stabilizer` 가 근거 만료를 확인해야 한다고 말하는가.
    expiry_probe: bool = false,

    pub fn canSkip(self: ScanSkip) bool {
        // **C2 가 세는 중이면 못 건너뛴다.** 아래 「화면이 idle 이고 출력도 없다」가 곧 C2 가 세는 상황이라
        // (codex 오류 턴은 훅이 running 에 멈춘 채 화면만 idle 이고 출력이 끊긴 상태다), 그냥 두면 첫 관측
        // 뒤 화면이 얼어붙어 카운터가 1 에서 멈추고 C2 가 영영 임계에 못 간다.
        if (self.c2Counting()) return false;
        return self.generation_same and self.screen == .idle and !self.output_active and !self.expiry_probe;
    }

    /// C2 가 셀 **가능성**이 있는가.
    ///
    /// ⚠️ **권위표의 C2 와 같을 필요는 없고 «넓어야» 한다.** 이 함수가 좁으면 C2 가 셀 상황을 «다시 볼
    /// 것 없다» 로 지나쳐 카운터가 얼어붙는다(그 사고를 실제로 냈다). 넓으면 화면을 몇 번 더 읽을 뿐이다.
    /// 그래서 여기서는 `screen == .idle` 을 보고 C2 는 `screen_visible_idle` 을 본다 — 후자가 전자의
    /// 부분집합이라 이 쪽이 넉넉하다. 아래 `AR-SKIP 넓이` 판정자가 그 포함 관계를 잠근다.
    pub fn c2Counting(self: ScanSkip) bool {
        const hook = self.hook orelse return false;
        return hook == .running and self.screen == .idle and self.hook_child_count == 0 and
            self.idle_confirmations < Arbiter.idle_confirmations_required;
    }
};

const testing = std.testing;

test "AR-SKIP C2 가 세는 동안에는 화면 스캔을 못 건너뛴다 — 건너뛰면 C2 가 굶는다" {
    // codex 오류 턴: 훅은 running 에 멈췄고 화면은 idle chrome 이며 출력이 끊겼다. 예전 fast-path 는
    // 정확히 이 상태를 「다시 볼 것 없다」로 읽어 screen_seq 를 얼렸고, C2 카운터가 1 에서 멈췄다.
    const counting: ScanSkip = .{
        .hook = .running,
        .screen = .idle,
        .idle_confirmations = 1,
        .generation_same = true,
        .output_active = false,
    };
    try testing.expect(counting.c2Counting());
    try testing.expect(!counting.canSkip());
}

test "AR-SKIP C2 가 닫히면 다시 건너뛴다 — 그 구간에만 더 본다" {
    var done: ScanSkip = .{
        .hook = .running,
        .screen = .idle,
        .idle_confirmations = Arbiter.idle_confirmations_required,
        .generation_same = true,
    };
    try testing.expect(!done.c2Counting());
    try testing.expect(done.canSkip());
    // 자식이 있으면 애초에 D1 이라 C2 가 안 센다 — 그때도 건너뛴다.
    done.idle_confirmations = 0;
    done.hook_child_count = 2;
    try testing.expect(!done.c2Counting());
    try testing.expect(done.canSkip());
}

test "AR-SKIP 넓이 — 권위표가 C2 를 세는 입력에서는 반드시 스캔한다(포함 관계)" {
    // 이 둘이 갈리면 C2 가 조용히 굶는다. 조건을 두 곳에 적어 두었으므로(한쪽은 「다시 읽을까」, 한쪽은
    // 「셀까」) **포함 관계**를 판정자가 지킨다 — 같을 필요는 없고 스캔 쪽이 넓기만 하면 된다.
    const states = [_]State{ .unknown, .running, .blocked, .idle };
    for (states) |hook_state| {
        for (states) |screen_state| {
            for ([_]u32{ 0, 1, 3 }) |children| {
                for ([_]bool{ false, true }) |vis_idle| {
                    var probe: Arbiter = .{};
                    const v = probe.arbitrate(.{
                        .hook = hook_state,
                        .hook_child_count = children,
                        .screen = screen_state,
                        .screen_visible_idle = vis_idle,
                        .screen_seq = 1,
                    });
                    const counted = std.mem.startsWith(u8, v.rule, "C2");
                    if (!counted) continue;
                    // 권위표가 C2 를 셌다면(닫았든 pending 이든) 스캔을 건너뛰면 안 된다.
                    const skip: ScanSkip = .{
                        .hook = hook_state,
                        .hook_child_count = children,
                        .screen = screen_state,
                        .idle_confirmations = 0,
                        .generation_same = true,
                        .output_active = false,
                    };
                    testing.expect(!skip.canSkip()) catch |e| {
                        std.debug.print("\n  갈림: hook={s} screen={s} children={d} vis_idle={} rule={s}\n", .{ @tagName(hook_state), @tagName(screen_state), children, vis_idle, v.rule });
                        return e;
                    };
                }
            }
        }
    }
}

test "AR-SKIP 훅이 없으면 C2 축이 없다 — 예전 규칙 그대로다" {
    const no_hook: ScanSkip = .{ .hook = null, .screen = .idle, .generation_same = true };
    try testing.expect(!no_hook.c2Counting());
    try testing.expect(no_hook.canSkip());
}

test "AR-SKIP 화면이 바뀌었거나 출력이 흐르면 건너뛰지 않는다 — 기존 조건은 그대로다" {
    try testing.expect(!(ScanSkip{ .screen = .idle, .generation_same = false }).canSkip());
    try testing.expect(!(ScanSkip{ .screen = .idle, .generation_same = true, .output_active = true }).canSkip());
    try testing.expect(!(ScanSkip{ .screen = .idle, .generation_same = true, .expiry_probe = true }).canSkip());
    try testing.expect(!(ScanSkip{ .screen = .running, .generation_same = true }).canSkip());
}

test "AR-FLIP 뒤집은 규칙만 표식을 받는다 — C2-pending 과 A 는 아니다" {
    // 화면이 이긴 자리만 사용자에게 보인다. 평소(B)에도 표식이 뜨면 그 신호가 아무 뜻도 없어진다.
    try testing.expect(ruleIsFlip("C1"));
    try testing.expect(ruleIsFlip("C2"));
    try testing.expect(ruleIsFlip("C3"));

    // **C2-pending 은 세는 중일 뿐 상태는 훅의 것이다**(origin 도 hook) — 접두 비교로 잡으면 「곧
    // 뒤집힐지도 모른다」가 「뒤집혔다」로 보인다.
    try testing.expect(!ruleIsFlip("C2-pending"));
    // A 는 훅이 없는 것이지 뒤집은 것이 아니다. B·B0·D1·D2 도 훅을 따른 것이다.
    for ([_][]const u8{ "A", "B", "B0", "D1", "D2", "" }) |r| try testing.expect(!ruleIsFlip(r));
}

test "AR-FLIP 권위표가 내는 rule 과 실제로 맞물린다 — 이름을 손으로 적지 않는다" {
    // 위 판정자는 문자열을 손으로 적는다. 그 이름이 arbitrate 가 내는 것과 갈리면 표식이 조용히 사라지므로
    // **실제 판정 결과**로 한 번 더 확인한다.
    var a: Arbiter = .{};
    try testing.expect(ruleIsFlip(a.arbitrate(.{ .hook = .blocked, .screen_seq = 1 }).rule)); // C1
    a.reset();
    try testing.expect(ruleIsFlip(a.arbitrate(.{ .hook = .running, .process_exited = true }).rule)); // C3
    a.reset();
    try testing.expect(!ruleIsFlip(a.arbitrate(.{ .hook = .running }).rule)); // B
    try testing.expect(!ruleIsFlip(a.arbitrate(.{ .hook = null, .screen = .idle }).rule)); // A
}

test "AR-ORIGIN 실제 규칙 id 가 제 출처로 간다 — 진단이 거짓말하지 않게" {
    // `agent_observer` 가 실제로 내는 id 들이다. 매핑이 틀리면 배지 옆 출처가 조용히 거짓이 된다.
    try testing.expectEqual(Origin.pty, originOfRule("pty_activity"));
    try testing.expectEqual(Origin.osc_progress, originOfRule("progress_idle"));
    try testing.expectEqual(Origin.osc_progress, originOfRule("progress_running"));
    try testing.expectEqual(Origin.osc_title, originOfRule("idle_title"));
    try testing.expectEqual(Origin.osc_title, originOfRule("working_title"));
    // 화면 규칙들 — 접두·접미가 안 걸리므로 전부 screen 이다.
    try testing.expectEqual(Origin.screen, originOfRule("live_prompt"));
    try testing.expectEqual(Origin.screen, originOfRule("working_footer"));
    try testing.expectEqual(Origin.screen, originOfRule("confirmation_prompt"));
    try testing.expectEqual(Origin.screen, originOfRule("permission_prompt"));
    try testing.expectEqual(Origin.screen, originOfRule("interrupted_prompt"));
    try testing.expectEqual(Origin.screen, originOfRule(""));
}

test "AR-A 훅 소스가 없으면 화면이 상태를 세운다 — 출처도 화면 것이 그대로 간다" {
    var a: Arbiter = .{};
    const v = a.arbitrate(.{ .hook = null, .screen = .running, .screen_origin = .pty });
    try testing.expectEqual(State.running, v.state);
    try testing.expectEqual(Origin.pty, v.origin);
    try testing.expectEqualStrings("A", v.rule);
}

test "AR-B 훅이 있으면 훅이 상태를 세운다" {
    var a: Arbiter = .{};
    const v = a.arbitrate(.{ .hook = .running, .screen = .unknown });
    try testing.expectEqual(State.running, v.state);
    try testing.expectEqual(Origin.hook, v.origin);
    try testing.expectEqualStrings("B", v.rule);
}

test "AR-C1 승인 chrome 이 사라지면 blocked 가 즉시 풀린다 — 지연 없다" {
    var a: Arbiter = .{};
    const v = a.arbitrate(.{ .hook = .blocked, .screen_seq = 1, .screen_visible_blocker = false });
    try testing.expectEqual(State.running, v.state);
    try testing.expectEqual(Origin.screen, v.origin);
    try testing.expectEqualStrings("C1", v.rule);
}

test "AR-C1 화면을 한 번도 안 읽었으면 blocked 를 풀지 않는다 — 부재와 미관측은 다르다" {
    // C1 은 chrome 의 **부재**로 서는 유일한 규칙이라 「없다」와 「안 봤다」가 같은 false 로 온다.
    // 구분하지 않으면 원격 채널만 있는 pane 이나 훅 이벤트만 처리한 tick 에서 승인 대기가 뜨자마자
    // 풀린다(제품 게이트가 실제로 그렇게 깨졌다).
    var a: Arbiter = .{};
    const unseen = a.arbitrate(.{ .hook = .blocked, .screen_seq = 0 });
    try testing.expectEqual(State.blocked, unseen.state);
    try testing.expectEqual(Origin.hook, unseen.origin);
    try testing.expectEqualStrings("B", unseen.rule);

    // 화면을 한 번 읽고 거기 chrome 이 없으면 그때는 푼다.
    const seen = a.arbitrate(.{ .hook = .blocked, .screen_seq = 1 });
    try testing.expectEqual(State.running, seen.state);
    try testing.expectEqualStrings("C1", seen.rule);
}

test "AR-C1 승인 chrome 이 아직 보이면 blocked 가 유지된다" {
    var a: Arbiter = .{};
    const v = a.arbitrate(.{ .hook = .blocked, .screen_seq = 1, .screen_visible_blocker = true });
    try testing.expectEqual(State.blocked, v.state);
    try testing.expectEqual(Origin.hook, v.origin);
}

test "AR-C1 은 idle 을 내지 않는다 — 화면이 이미 idle 이어도 running 까지만 간다 (C2 우회 금지)" {
    var a: Arbiter = .{};
    // 승인이 풀린 그 tick 에 화면이 벌써 idle chrome 을 보이는 경우. C1 이 화면 상태를 그대로 실으면
    // blocked → idle 이 한 tick 에 일어나 C2 의 연속 3회가 통째로 무의미해진다.
    const v = a.arbitrate(.{
        .hook = .blocked,
        .screen = .idle,
        .screen_seq = 1,
        .screen_visible_blocker = false,
        .screen_visible_idle = true,
    });
    try testing.expectEqual(State.running, v.state);
    try testing.expectEqualStrings("C1", v.rule);
}

test "AR-C2 화면 idle 두 번으로는 훅 running 을 못 덮고 세 번째에 덮는다" {
    var a: Arbiter = .{};
    var seq: u64 = 0;
    seq += 1;
    var in: Input = .{ .hook = .running, .hook_child_count = 0, .screen_visible_idle = true, .screen_seq = seq };

    const first = a.arbitrate(in);
    try testing.expectEqual(State.running, first.state);
    try testing.expectEqualStrings("C2-pending", first.rule);

    seq += 1;
    in.screen_seq = seq;
    const second = a.arbitrate(in);
    try testing.expectEqual(State.running, second.state);
    try testing.expectEqualStrings("C2-pending", second.rule);

    seq += 1;
    in.screen_seq = seq;
    const third = a.arbitrate(in);
    try testing.expectEqual(State.idle, third.state);
    try testing.expectEqual(Origin.screen, third.origin);
    try testing.expectEqualStrings("C2", third.rule);
}

test "AR-C2 연속이 끊기면 다시 처음부터 센다" {
    var a: Arbiter = .{};
    _ = a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .screen_seq = 1 });
    _ = a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .screen_seq = 2 });
    // 한 tick 이라도 idle chrome 이 아니면 «연속» 이 아니다.
    _ = a.arbitrate(.{ .hook = .running, .screen_visible_idle = false, .screen_seq = 3 });
    const after = a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .screen_seq = 4 });
    try testing.expectEqual(State.running, after.state);
    try testing.expectEqualStrings("C2-pending", after.rule);
}

test "AR-C3 프로세스가 죽으면 확인 절차 없이 idle 이다" {
    var a: Arbiter = .{};
    const v = a.arbitrate(.{ .hook = .running, .hook_child_count = 3, .process_exited = true });
    try testing.expectEqual(State.idle, v.state);
    try testing.expectEqual(Origin.process_exit, v.origin);
    try testing.expectEqualStrings("C3", v.rule);
}

test "AR-D1 자식이 살아 있으면 화면 idle 이 몇 번 와도 running 이 유지된다" {
    var a: Arbiter = .{};
    const in: Input = .{ .hook = .running, .hook_child_count = 2, .screen_visible_idle = true, .screen = .idle };
    // C2 의 확인 수를 훌쩍 넘겨도 D1 이 먼저 선다. 자식이 도는 동안 lead 의 턴은 끝이 아니다(계약 §2).
    for (0..Arbiter.idle_confirmations_required + 5) |_| {
        const v = a.arbitrate(in);
        try testing.expectEqual(State.running, v.state);
        try testing.expectEqual(Origin.hook, v.origin);
        try testing.expectEqualStrings("D1", v.rule);
    }
}

test "AR-D1 자식이 끝난 뒤에야 C2 가 세기 시작한다" {
    var a: Arbiter = .{};
    for (0..5) |i| _ = a.arbitrate(.{ .hook = .running, .hook_child_count = 1, .screen_visible_idle = true, .screen_seq = i + 1 });
    // 자식이 사라진 순간부터 «처음부터» 세 번이다 — D1 이 도는 동안 센 것이 넘어오면 안 된다.
    try testing.expectEqualStrings("C2-pending", a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .screen_seq = 6 }).rule);
    try testing.expectEqualStrings("C2-pending", a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .screen_seq = 7 }).rule);
    try testing.expectEqualStrings("C2", a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .screen_seq = 8 }).rule);
}

test "AR-B0 훅이 아직 모르면 화면이 답한다 — 훅 자리가 unknown 인 구간" {
    // 로그 파일은 생겼는데 이벤트를 아직 못 읽은 구간(그리고 훅이 유실된 구간)이 있다. 그때 D2·B 를
    // 그대로 태우면 화면이 승인 프롬프트를 보고 있는데 배지가 unknown 이 된다.
    var a: Arbiter = .{};
    const v = a.arbitrate(.{ .hook = .unknown, .screen = .blocked, .screen_seq = 1, .screen_visible_blocker = true });
    try testing.expectEqual(State.blocked, v.state);
    try testing.expectEqual(Origin.screen, v.origin);
    try testing.expectEqualStrings("B0", v.rule);

    // 화면도 모르면 그대로 unknown 이다 — 없는 근거를 지어내지 않는다.
    const both = a.arbitrate(.{ .hook = .unknown, .screen = .unknown, .screen_seq = 2 });
    try testing.expectEqual(State.unknown, both.state);
    try testing.expectEqualStrings("B", both.rule);
}

test "AR-D2 훅이 도는 동안 화면만 blocked 면 배지가 안 바뀐다 — 스크롤백 오탐" {
    var a: Arbiter = .{};
    const v = a.arbitrate(.{ .hook = .running, .screen = .blocked, .screen_visible_blocker = true });
    try testing.expectEqual(State.running, v.state);
    try testing.expectEqual(Origin.hook, v.origin);
    try testing.expectEqualStrings("D2", v.rule);
}

test "AR 훅이 없을 때는 화면 blocked 가 그대로 간다 — D2 는 훅이 있을 때만이다" {
    var a: Arbiter = .{};
    const v = a.arbitrate(.{ .hook = null, .screen = .blocked, .screen_visible_blocker = true });
    try testing.expectEqual(State.blocked, v.state);
    try testing.expectEqualStrings("A", v.rule);
}

test "AR-C2 한 번 닫힌 뒤 새 턴은 처음부터 센다 — 지난 턴의 셈으로 이번 턴을 접지 않는다" {
    // 적대적 검증 R8 에서 실제로 재현된 버그다. 카운터가 3 에 남은 채 새 턴이 열리면 화면이 아직
    // 이전 idle chrome 을 들고 있는 첫 판정에서 곧바로 4가 되어 «확인 없이 완료» 가 됐다.
    var a: Arbiter = .{};
    _ = a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .hook_turn_seq = 1, .screen_seq = 1 });
    _ = a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .hook_turn_seq = 1, .screen_seq = 2 });
    try testing.expectEqualStrings("C2", a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .hook_turn_seq = 1, .screen_seq = 3 }).rule);

    // 사용자가 새 프롬프트를 넣었다(`UserPromptSubmit` → turn_key 변경). 화면은 폴링 주기 동안 아직
    // 이전 idle chrome 을 들고 있다.
    const first = a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .hook_turn_seq = 2, .screen_seq = 4 });
    try testing.expectEqual(State.running, first.state);
    try testing.expectEqualStrings("C2-pending", first.rule);
    try testing.expectEqualStrings("C2-pending", a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .hook_turn_seq = 2, .screen_seq = 5 }).rule);
    try testing.expectEqualStrings("C2", a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .hook_turn_seq = 2, .screen_seq = 6 }).rule);
}

test "AR-C2 같은 화면 관측을 두 번 세지 않는다 — 중재가 여러 번 불려도 임계는 관측 수로 온다" {
    // 한 tick 에 중재가 두 번 불릴 수 있다(원격 채널 드레인 + 폴링 소비자). 호출을 세면 「연속 3회
    // 관측」이 「연속 3회 호출」로 바뀌어 임계에 몇 배 빨리 닿는다.
    var a: Arbiter = .{};
    var seq: u64 = 0;
    var ticks: u32 = 0;
    while (ticks < 2) : (ticks += 1) {
        seq += 1; // 화면을 한 번 읽었다
        const in: Input = .{ .hook = .running, .screen_visible_idle = true, .screen_seq = seq };
        // 같은 tick 에서 세 번 중재해도 관측은 한 번이다.
        try testing.expectEqualStrings("C2-pending", a.arbitrate(in).rule);
        try testing.expectEqualStrings("C2-pending", a.arbitrate(in).rule);
        try testing.expectEqualStrings("C2-pending", a.arbitrate(in).rule);
    }
    // 세 번째 **관측**에서 비로소 닫힌다.
    seq += 1;
    try testing.expectEqualStrings("C2", a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .screen_seq = seq }).rule);
}

test "AR 훅 idle 은 화면 running 으로 되돌지 않는다 — 일부러 비운 자리다(§1)" {
    // 대칭을 맞추고 싶어지는 자리다. 넣으면 훅 `Stop` 직후 화면에 남은 running 잔상이 배지를 되돌려
    // **매 턴 끝마다 깜빡인다.** 훅의 Stop 은 정확한 신호이고 화면의 running 잔상은 흔하므로, 이 방향은
    // 화면을 믿을 근거가 C1·C2 보다 약하다. 이 판정자가 그 «개선» 을 막는다.
    var a: Arbiter = .{};
    const v = a.arbitrate(.{ .hook = .idle, .screen = .running });
    try testing.expectEqual(State.idle, v.state);
    try testing.expectEqual(Origin.hook, v.origin);
    try testing.expectEqualStrings("B", v.rule);
}

test "AR 뒤집힌 판정은 출처가 화면이다 — 뒤집힌 사실이 로그에 남아야 한다" {
    var a: Arbiter = .{};
    // C1 과 C2 는 훅을 덮은 경우다. 그때 origin 이 hook 으로 남으면 «훅이 이 배지를 만들었다» 는
    // 거짓이 되고, §1.4 가 뒤집기를 열거로 제한한 의미가 절반 사라진다.
    try testing.expectEqual(Origin.screen, a.arbitrate(.{ .hook = .blocked, .screen_seq = 1 }).origin);

    a.reset();
    _ = a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .screen_seq = 1 });
    _ = a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .screen_seq = 2 });
    try testing.expectEqual(Origin.screen, a.arbitrate(.{ .hook = .running, .screen_visible_idle = true, .screen_seq = 3 }).origin);
}

test "AR 상태 이름이 아니라 전이를 잠근다 — blocked 해제는 어떤 이름으로 와도 같은 자리에서 풀린다" {
    // claude 의 `PermissionRequest` 가 `blocked` 대신 `waiting` 으로 정규화되는 구현이 있다(§1 ⑵).
    // 우리 State 열거에는 그 이름이 없으므로, 판정자가 잠그는 것은 «blocked 로 들어온 것이 chrome 부재로
    // 풀린다» 는 **전이**다. 이름에 거는 판정자는 자기 테스트만 통과한다.
    var a: Arbiter = .{};
    var seen_release = false;
    for ([_]State{ .blocked, .running, .idle, .unknown }) |hook_state| {
        const v = a.arbitrate(.{ .hook = hook_state, .screen_seq = 1, .screen_visible_blocker = false });
        if (hook_state == .blocked) {
            try testing.expectEqualStrings("C1", v.rule);
            seen_release = true;
        } else {
            try testing.expect(!std.mem.eql(u8, v.rule, "C1"));
        }
    }
    try testing.expect(seen_release);
}
