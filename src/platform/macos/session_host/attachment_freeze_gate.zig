//! 재접속이 attachment 를 **얼린 동안** payload 를 만지는 연산이 무엇을 하는가 — 순수 판정(std-only).
//!
//! ## 왜 있나
//!
//! 재접속은 여러 프레임에 걸친 상태 기계다(한 프레임에 전이 하나). `connected` 다음 전이가 host 의 모든 runtime
//! 을 `retirement_prepared` 로 얼리고, 커밋 뒤에는
//! 새 세대가 runtime 마다 게시될 때까지 현재 세대가 `cleaning`/`terminal` 로 남는다. 그 창 동안 runtime 은
//! `backend.runtimes` 에 그대로 있으므로 화면 tick·관측 probe·사용자 조작이 그 runtime 을 부를 수 있다.
//! payload 접근(`GenerationAttachment.payloadMut`/`payloadConst`)은 live 가 아니면 **abort** 한다.
//!
//! 2026-10-05 19:07 실측: `frame_malformed` poison → `reconnect job connected` → 같은 프레임의 창 drain 이
//! `drainRemote` → `pumpDelta` → `statePtr()` 로 들어가 `generation attachment is not live: site=payloadMut
//! lifecycle_raw=7` 로 앱이 죽었다. 유지보수 펌프는 이미 live 가 아닌 runtime 을 건너뛰었지만(그래서 프레임 요약이
//! 없었고), 창 drain 이 요약 없이 직접 펌프했다.
//!
//! ## 판정 출처
//!
//! 「live 인가」는 여기서 다시 판정하지 않는다 — `GenerationAttachment.isLive` 가 패닉 조건과 같은 단일 출처이고,
//! 호출부가 그 값을 넘긴다(RemoteRuntime 의 `attachmentLive` 파사드). 여기서 lifecycle 을 다시 읽으면 두 판정이
//! 갈라지는 날 한쪽만 고쳐진다. 이 파일이 정하는 것은 **live 가 아닐 때 연산마다 무엇을 하는가** 하나다.

const std = @import("std");

/// 얼린 창에서 payload 에 닿을 수 있는 연산 묶음.
pub const Op = enum {
    /// 프레임 drain(`pumpDelta`). 매 프레임 모든 Term 이 부른다.
    pump,
    /// 관측·선택·링크·검색·resync 같은 비변경 RPC. 첫 줄에서 `streamId()` 로 payload 를 읽는다.
    read_rpc,
    /// client 쪽만 회수하는 best-effort detach. 연결이 교체되는 중이라 보낼 곳이 없다.
    detach,
    /// runtime 파괴 RPC(`terminate` — 탭 닫기의 close 경로, runtime deinit). 얼린 attachment 로는 보낼 권위가 없다.
    terminate,
};

pub const Action = enum {
    /// live — 지금까지와 같이 진행한다.
    proceed,
    /// 이번 프레임은 할 일이 없다. drain 은 `.idle` 을 돌려주고 세션을 끝내지 **않는다**(새 세대가 게시되면 이어서
    /// 펌프한다). 오류로 돌려주면 `drainRemoteNow` 가 `markPumpEnded` 로 세션을 exited 로 만든다.
    idle,
    /// 지금은 받을 수 없다 — `error.AdminBusy`. `admitRuntimeOperation` 이 원래 내던 거절과 같은 이름이라 호출부가
    /// 이미 처리한다(관측 probe 는 다음 주기에 다시 묻는다).
    busy,
    /// 아무것도 보내지 않고 돌아간다. 옛 연결의 controller lease 는 재접속이 연결을 닫을 때 host 가 EOF 로
    /// 회수한다. terminate 를 건너뛴 runtime 은 host 에 남는다(인벤토리로 다시 보인다) — abort 보다 낫다.
    skip,
};

pub fn decide(live: bool, op: Op) Action {
    if (live) return .proceed;
    return switch (op) {
        .pump => .idle,
        .read_rpc => .busy,
        .detach, .terminate => .skip,
    };
}

test "재접속 얼림 관문: live 면 어떤 연산이든 진행한다" {
    inline for (std.meta.fields(Op)) |field| {
        try std.testing.expectEqual(Action.proceed, decide(true, @field(Op, field.name)));
    }
}

test "재접속 얼림 관문: live 가 아니면 drain 은 세션을 끝내지 않고 이번 프레임만 쉰다" {
    try std.testing.expectEqual(Action.idle, decide(false, .pump));
}

test "재접속 얼림 관문: live 가 아니면 비변경 RPC 는 바쁨으로 거절하고 detach·terminate 는 보내지 않는다" {
    try std.testing.expectEqual(Action.busy, decide(false, .read_rpc));
    try std.testing.expectEqual(Action.skip, decide(false, .detach));
    try std.testing.expectEqual(Action.skip, decide(false, .terminate));
}

test "재접속 얼림 관문: live 가 아닌데 진행하는 연산은 없다" {
    inline for (std.meta.fields(Op)) |field| {
        try std.testing.expect(decide(false, @field(Op, field.name)) != .proceed);
    }
}
