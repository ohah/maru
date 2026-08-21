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
    /// 입력을 기다린다(`PermissionRequest`). 내용은 무엇을 승인하는지.
    attention,
};

/// 이 전이가 어떤 알림을 만드는가. **`Notification`(idle_prompt)은 기본 억제**라 여기 없다 — 그 이벤트는
/// 상태도 안 옮기므로 전이가 생기지 않는다(계약 §6 표).
pub fn noticeOn(prev: State, now: State) Notice {
    if (prev == now) return .none;
    return switch (now) {
        .idle => .done,
        .blocked => .attention,
        .running, .unknown => .none,
    };
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
        const n = @min(body.len, max_text);
        @memcpy(self.buf[0..n], body[0..n]);
        self.len = n;
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

test "재발화 Stop 과 백그라운드 작업은 애초에 전이를 만들지 않는다" {
    // 상태 전이 함수와 알림 정책이 **같은 사실**을 쓰는지 확인한다 — 둘이 따로 판단하면 어긋난다.
    var reentrant = evOf(.stop);
    reentrant.stop_hook_active = true;
    const after_reentrant = next(.running, reentrant);
    try testing.expectEqual(Notice.none, noticeOn(.running, after_reentrant));

    var background = evOf(.stop);
    background.has_background_tasks = true;
    const after_background = next(.running, background);
    try testing.expectEqual(Notice.none, noticeOn(.running, after_background));

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
