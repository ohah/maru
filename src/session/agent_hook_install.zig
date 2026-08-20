//! 사용자 설정 파일의 훅 상태를 보고 **무엇을 할지** 정하는 순수 판정(L2, I/O 없음).
//! 계약의 단일 출처는 [docs/agent-hooks.md](../../docs/agent-hooks.md) §5이고, 파일 읽기·쓰기·`flock`·
//! JSON 편집은 platform 이 한다. 여기서는 «상태 → 계획» 하나만 본다.
//!
//! **왜 판정을 떼어 놓는가**: 이 결정이 틀리면 사용자 홈의 파일이 상한다. 같은 계열의 선례가 그것을 실제로
//! 겪었다 — 상태 판정과 파일 I/O 가 엉킨 코드가 «읽기 실패» 를 «빈 설정» 으로 접어, 0 바이트 창에 걸리자
//! 사용자 `settings.json` 을 통째로 날렸다. 판정을 순수 층으로 빼면 그 분기들을 **파일 없이** 전수로 돌릴 수 있다.

const std = @import("std");

/// platform 이 설정 파일을 훑어 채우는 요약. **우리 항목만** 센다 — 사용자 항목은 세지 않는다(건드리지 않으므로).
pub const Known = struct {
    /// 우리 표식이 붙은 항목 수(모든 이벤트에 걸쳐).
    ours: usize = 0,
    /// 그중 커맨드 바이트가 **지금 만들 것과 같은** 항목 수. 경로·상한·표식이 바뀌면 이 수가 줄어든다.
    ours_current: usize = 0,
    /// 우리 항목이 덮는 **이벤트 수**(중복 제외). 세트보다 적으면 일부만 설치된 것이다.
    events_covered: usize = 0,
    /// 과거 표식 항목이 있는가. **건드리지 않는다**([persistent-session-host.md](../../docs/persistent-session-host.md)
    /// P1 — legacy 잔재를 자동 정리하지 않는다). 안내에만 쓴다.
    legacy_present: bool = false,
};

pub const State = union(enum) {
    /// 파일을 읽지 못했다(없음이 아니라 **파싱 실패·권한·부분 쓰기 중**). 여기서 «빈 설정» 으로 접으면
    /// 사용자 파일을 우리 것으로 덮어쓴다.
    unreadable,
    /// 파일이 아직 없다. 새로 만들어도 잃을 것이 없다.
    absent,
    /// 읽었다.
    known: Known,
};

pub const Intent = enum {
    /// 켜져 있다 — 없으면 넣고, 낡았으면 고친다.
    ensure,
    /// 사용자가 **명시적으로** 제거를 요청했다. 게이트를 끈 것만으로는 여기 오지 않는다(§5 — 끔은
    /// «설치하지 않음» 이고 «제거» 가 아니다. 인스턴스 둘이 서로 다른 값을 가지면 설치·제거가 왕복한다).
    uninstall,
};

pub const Plan = enum {
    /// 아무것도 하지 않는다.
    leave,
    /// 우리 항목을 새로 넣는다.
    install,
    /// 우리 항목을 걷어 내고 다시 넣는다(낡았거나 일부만 있다).
    refresh,
    /// 우리 항목을 걷어 낸다.
    remove,
    /// 상태를 모른다 — **손대지 않는다**.
    abort,
};

/// `want_events` 는 계약 §2 세트의 이벤트 수다(`agent_hook_command.events.len`).
pub fn planFor(state: State, intent: Intent, want_events: usize) Plan {
    switch (state) {
        // **모르는 상태는 건드리지 않는다.** 지우는 쪽도 마찬가지다 — 무엇을 지우는지 모르는 채로 쓰면
        // 사용자 항목을 함께 날린다.
        .unreadable => return .abort,
        .absent => return switch (intent) {
            .ensure => .install,
            // 없는 파일에서 지울 것은 없다. 파일을 만들지도 않는다(남의 홈에 흔적을 남기지 않는다).
            .uninstall => .leave,
        },
        .known => |k| switch (intent) {
            .uninstall => return if (k.ours > 0) .remove else .leave,
            .ensure => {
                if (k.ours == 0) return .install;
                // 하나라도 낡았거나 덮지 못한 이벤트가 있으면 **전부 걷어 내고 다시 넣는다**. 부분 갱신은
                // 순서·중복을 다루는 분기를 늘리는데, 우리 항목은 언제나 같은 모양이라 얻는 것이 없다.
                if (k.ours_current != k.ours) return .refresh;
                if (k.events_covered != want_events) return .refresh;
                return .leave;
            },
        },
    }
}

/// 이 계획이 사용자 파일을 **바꾸는가**. platform 이 락·백업·atomic write 를 준비할지 정하는 데 쓴다.
pub fn mutates(plan: Plan) bool {
    return switch (plan) {
        .install, .refresh, .remove => true,
        .leave, .abort => false,
    };
}

const testing = std.testing;

test "읽지 못한 파일은 어느 방향으로도 손대지 않는다" {
    // 같은 계열의 선례가 겪은 사고: 읽기 실패를 «빈 설정» 으로 접어 사용자 파일을 통째로 날렸다.
    // 지우는 쪽도 막는다 — 무엇을 지우는지 모르는 채로 쓰면 사용자 항목이 함께 사라진다.
    try testing.expectEqual(Plan.abort, planFor(.unreadable, .ensure, 6));
    try testing.expectEqual(Plan.abort, planFor(.unreadable, .uninstall, 6));
    try testing.expect(!mutates(.abort));
}

test "없는 파일은 켤 때만 만든다" {
    try testing.expectEqual(Plan.install, planFor(.absent, .ensure, 6));
    // 끄는 사람의 홈에 파일을 만들지 않는다.
    try testing.expectEqual(Plan.leave, planFor(.absent, .uninstall, 6));
}

test "우리 항목이 없으면 넣는다" {
    const empty: State = .{ .known = .{} };
    try testing.expectEqual(Plan.install, planFor(empty, .ensure, 6));
    // 사용자 항목만 있는 파일도 마찬가지다 — 그 항목은 세지 않으므로 `ours` 가 0 이다.
    const user_only: State = .{ .known = .{ .ours = 0, .legacy_present = false } };
    try testing.expectEqual(Plan.install, planFor(user_only, .ensure, 6));
}

test "완전히 설치돼 있으면 그대로 둔다" {
    const full: State = .{ .known = .{ .ours = 6, .ours_current = 6, .events_covered = 6 } };
    try testing.expectEqual(Plan.leave, planFor(full, .ensure, 6));
    try testing.expect(!mutates(.leave));
}

test "낡은 커맨드가 하나라도 있으면 전부 다시 넣는다" {
    // 경로·상한·표식이 바뀌면 `ours_current` 가 준다. 부분 갱신은 순서·중복 분기를 늘리기만 한다.
    const stale: State = .{ .known = .{ .ours = 6, .ours_current = 5, .events_covered = 6 } };
    try testing.expectEqual(Plan.refresh, planFor(stale, .ensure, 6));
}

test "일부 이벤트만 덮고 있으면 다시 넣는다" {
    // 사용자가 항목 하나를 지웠거나, 우리가 세트를 늘린 뒤다. 둘 다 «덮지 못한 이벤트» 로 나타난다.
    const partial: State = .{ .known = .{ .ours = 4, .ours_current = 4, .events_covered = 4 } };
    try testing.expectEqual(Plan.refresh, planFor(partial, .ensure, 6));
}

test "명시적 제거만 지운다 — 게이트를 끈 것으로는 지우지 않는다" {
    // §5: 끔은 «설치하지 않음» 이다. 인스턴스 둘이 서로 다른 게이트 값을 가지면 설치·제거가 무한히 왕복한다.
    const installed: State = .{ .known = .{ .ours = 6, .ours_current = 6, .events_covered = 6 } };
    try testing.expectEqual(Plan.remove, planFor(installed, .uninstall, 6));
    const none: State = .{ .known = .{} };
    try testing.expectEqual(Plan.leave, planFor(none, .uninstall, 6));
}

test "과거 표식이 있어도 계획이 달라지지 않는다 — 그 항목은 건드리지 않는다" {
    // P1 이 «legacy 잔재를 자동 정리하지 않는다» 고 정했다. 그 존재가 우리 판정을 바꾸면 그 규칙이 샌다.
    const with_legacy: State = .{ .known = .{ .ours = 6, .ours_current = 6, .events_covered = 6, .legacy_present = true } };
    const without: State = .{ .known = .{ .ours = 6, .ours_current = 6, .events_covered = 6 } };
    try testing.expectEqual(planFor(without, .ensure, 6), planFor(with_legacy, .ensure, 6));
    try testing.expectEqual(planFor(without, .uninstall, 6), planFor(with_legacy, .uninstall, 6));
}

test "바꾸는 계획만 락·백업을 요구한다" {
    try testing.expect(mutates(.install));
    try testing.expect(mutates(.refresh));
    try testing.expect(mutates(.remove));
    try testing.expect(!mutates(.leave));
    try testing.expect(!mutates(.abort));
}
