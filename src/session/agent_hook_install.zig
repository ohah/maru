//! 사용자 설정 파일의 훅 상태를 보고 **무엇을 할지** 정하는 순수 판정(L2, I/O 없음).
//! 계약의 단일 출처는 [docs/agent-hooks.md](../../docs/agent-hooks.md) §5이고, 파일 읽기·쓰기·`flock`·
//! JSON 편집은 platform 이 한다. 여기서는 «상태 → 계획» 하나만 본다.
//!
//! **왜 판정을 떼어 놓는가**: 이 결정이 틀리면 사용자 홈의 파일이 상한다. 같은 계열의 선례가 그것을 실제로
//! 겪었다 — 상태 판정과 파일 I/O 가 엉킨 코드가 «읽기 실패» 를 «빈 설정» 으로 접어, 0 바이트 창에 걸리자
//! 사용자 `settings.json` 을 통째로 날렸다. 판정을 순수 층으로 빼면 그 분기들을 **파일 없이** 전수로 돌릴 수 있다.

const std = @import("std");
const command = @import("agent_hook_command.zig");

/// platform 이 설정 파일을 훑어 채우는 요약. **우리 항목만** 센다 — 사용자 항목은 세지 않는다(건드리지 않으므로).
pub const Known = struct {
    /// 우리 표식이 붙은 항목 수(모든 이벤트에 걸쳐).
    ours: usize = 0,
    /// 그중 커맨드 바이트가 **지금 만들 것과 같은** 항목 수. 경로·상한·표식이 바뀌면 이 수가 줄어든다.
    ours_current: usize = 0,
    /// **세트에 있는** 이벤트 중 우리 항목이 덮은 수(중복 제외). 세트보다 적으면 일부만 설치된 것이다.
    events_covered: usize = 0,
    /// **세트에 없는** 이벤트에 붙어 있는 우리 항목 수. 세트에서 이벤트를 뺐을 때(예: `PostToolUse`) 그
    /// 자리에 남은 우리 항목이 여기 잡힌다 — 개수만 비교하면 «6개를 덮었다» 로 보여 **잘못된 이벤트에 남은
    /// 항목이 영영 안 지워진다**. 0 이 아니면 걷어 내고 다시 넣는다.
    events_outside: usize = 0,
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
    ///
    /// **한 번의 쓰기로 끝낸다.** 걷어 내기와 넣기를 두 번에 나눠 쓰면 그 사이에 죽었을 때 사용자에게
    /// «훅이 사라진» 파일이 남는다. platform 은 트리를 메모리에서 다 고친 뒤 atomic 하게 한 번 쓴다.
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
                // 세트에서 뺀 이벤트에 우리 항목이 남아 있으면 개수만으로는 «다 덮었다» 로 보인다.
                if (k.events_outside != 0) return .refresh;
                return .leave;
            },
        },
    }
}

/// 계약 §2 세트로 판정한다. **호출자가 세트 크기를 넘기지 않는다** — 그 값이 어긋나면 «다 덮었다» 를
/// 잘못 판정하는데, 세트는 이 저장소 안의 상수라 넘겨받을 이유가 없다. `planFor` 의 인자는 테스트가 다른
/// 크기를 넣어 경계를 보기 위한 것이다.
pub fn planForSet(state: State, intent: Intent) Plan {
    return planFor(state, intent, command.events.len);
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

test "세트에서 뺀 이벤트에 남은 우리 항목을 걷어 낸다" {
    // 개수만 비교하면 «세트 6개를 다 덮었다» 로 보여 그 항목이 영영 안 지워진다. 실제로 세트에서
    // `PostToolUse` 를 뺀 적이 있으므로(계약 §3.1) 가상의 상황이 아니다.
    const leftover: State = .{
        .known = .{
            .ours = 7,
            .ours_current = 7,
            .events_covered = 6, // 세트의 6개는 다 덮었지만
            .events_outside = 1, // 세트 밖 이벤트에 하나가 더 남아 있다
        },
    };
    try testing.expectEqual(Plan.refresh, planFor(leftover, .ensure, 6));

    // 그 하나가 없으면 그대로 둔다 — 이 대조가 «세트 밖 항목 때문» 임을 증명한다.
    const clean: State = .{ .known = .{ .ours = 6, .ours_current = 6, .events_covered = 6 } };
    try testing.expectEqual(Plan.leave, planFor(clean, .ensure, 6));
}

test "세트 크기는 호출자가 넘기지 않는다" {
    // 호출자가 그 수를 넘기면 어긋난 값이 «다 덮었다» 를 잘못 판정한다. 세트는 저장소 안의 상수다.
    const full: State = .{ .known = .{
        .ours = command.events.len,
        .ours_current = command.events.len,
        .events_covered = command.events.len,
    } };
    try testing.expectEqual(Plan.leave, planForSet(full, .ensure));
    try testing.expectEqual(Plan.remove, planForSet(full, .uninstall));
}

test "Known 의 필드가 늘면 판정 누락을 잡는다" {
    // 필드를 더하고 판정에 안 넣으면 **조용히 무시**된다. 개수로 못 박아 그 드리프트를 컴파일이 아니라
    // 테스트에서 잡는다 — 새 필드를 넣는 사람이 여기서 «이 필드는 판정에 어떻게 쓰이나» 를 묻게 된다.
    const fields = @typeInfo(Known).@"struct".fields;
    try testing.expectEqual(@as(usize, 5), fields.len);

    // 각 필드가 실제로 계획을 움직이는지(또는 의도적으로 안 움직이는지) 하나씩 흔들어 본다.
    const base: Known = .{
        .ours = command.events.len,
        .ours_current = command.events.len,
        .events_covered = command.events.len,
    };
    try testing.expectEqual(Plan.leave, planForSet(.{ .known = base }, .ensure));

    var no_ours = base;
    no_ours.ours = 0;
    try testing.expectEqual(Plan.install, planForSet(.{ .known = no_ours }, .ensure));

    var stale = base;
    stale.ours_current -= 1;
    try testing.expectEqual(Plan.refresh, planForSet(.{ .known = stale }, .ensure));

    var partial = base;
    partial.events_covered -= 1;
    try testing.expectEqual(Plan.refresh, planForSet(.{ .known = partial }, .ensure));

    var outside = base;
    outside.events_outside = 1;
    try testing.expectEqual(Plan.refresh, planForSet(.{ .known = outside }, .ensure));

    // `legacy_present` 는 **의도적으로** 계획을 바꾸지 않는다(P1 — 자동 정리 금지).
    var legacy = base;
    legacy.legacy_present = true;
    try testing.expectEqual(Plan.leave, planForSet(.{ .known = legacy }, .ensure));
}
