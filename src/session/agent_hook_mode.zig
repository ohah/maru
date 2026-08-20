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
};

/// 지금 이 Term 이 어느 모드인가. **파일 유무로 판정한다** — 이벤트 개수로 잡으면 가만히 있는 세션이
/// 강등되고, 시간으로 잡으면 이미 돌던 세션이 강등된다(계약 §1.2의 두 함정).
pub fn modeFor(probe: Probe) Mode {
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
/// 두 가지를 특별히 다룬다:
/// - `stop_hook_active` 가 참인 `Stop` 은 **턴 종료로 세지 않는다**(서브에이전트·백그라운드로 재발화한다).
/// - `background_tasks` 가 비어 있지 않으면 **완료로 단정하지 않는다** — 턴은 끝났어도 셸 작업이 돌고 있다.
pub fn next(current: State, ev: event.Event) State {
    return switch (ev.kind) {
        // 세션이 시작됐다. 아직 턴이 없으므로 «대기» 다.
        .session_start => .idle,
        .user_prompt_submit => .running,
        .pre_tool_use => .running,
        .permission_request => .blocked,
        .stop => blk: {
            if (ev.stop_hook_active) break :blk current; // 재발화 — 턴이 끝난 것이 아니다
            // 셸 작업이 남아 있으면 여전히 «돌고 있다».
            break :blk if (ev.has_background_tasks) .running else .idle;
        },
        // 알림은 상태를 옮기지 않는다(알림 소비는 §6이 따로 소유한다).
        .notification => current,
        // 상한을 넘겨 접힌 이벤트와 모르는 이벤트는 **상태를 흔들지 않는다** — 내용을 모르는 채로 옮기면
        // 배지가 틀린 값에 고정된다.
        .oversized, .unknown => current,
    };
}

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
        .has_background_tasks = false,
    };
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

test "백그라운드 작업이 남아 있으면 완료로 단정하지 않는다" {
    // 턴은 끝났어도 셸 작업이 돌고 있다(실측: `{id, type: shell, status: running, description}`).
    var ev = evOf(.stop);
    ev.has_background_tasks = true;
    try testing.expectEqual(State.running, next(.running, ev));
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
    inline for (@typeInfo(event.Kind).@"enum".fields) |field| {
        const kind: event.Kind = @enumFromInt(field.value);
        const moved = next(.unknown, evOf(kind));
        const holds = switch (kind) {
            .notification, .oversized, .unknown => true,
            else => false,
        };
        if (holds) {
            try testing.expectEqual(State.unknown, moved);
        } else {
            try testing.expect(moved != .unknown);
        }
    }
}
