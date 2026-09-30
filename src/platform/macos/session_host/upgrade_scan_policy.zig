//! 업그레이드 스캔이 한 후보에 `host.upgrade.prepare` 를 보낸 **뒤** 다음 후보로 넘어가도 되는가 — 순수 판정.
//!
//! `host_connect.tryUpgradeExistingHost` 는 예전에 「prepare 를 한 번 보낸 뒤에는 결과와 무관하게 스캔을
//! 끝낸다」였다. 연쇄 교체가 여러 host 의 client 를 떨어뜨리는 것을 막으려는 규칙이지만, 결과를 보지 않으니
//! **확정적으로 실패하는 host 하나가 나머지 전부를 영구히 막았다.**
//!
//! 2026-09-30 실측: 9/27 빌드 host(7592)는 매니페스트 ctime 결함으로 교체가 매번 `resumed/handoff_failed` 로
//! 끝나는데 readdir 순서상 늘 첫 후보였다. 스캔이 거기서 끝나 9/28·9/29 빌드 host 둘(c227·f1fe)은 한 번도
//! 교체 시도를 받지 못했고, 설치마다 새 host 가 하나씩 늘어 넷이 됐다.
//!
//! 그래서 **결과를 보고** 가른다. host 가 exec 전에 되돌아가 옛 이미지로 다시 serving 중임이 확정된 경우
//! (`resumed`)와, prepare 가 부수효과 없이 거절된 경우(진행 중인 다른 attempt 때문이 아닌 `rejected`)만 다음
//! 후보로 간다. 교체 중이거나 상태가 불확실한 경우는 예전처럼 멈춘다.
//!
//! 또 **공정한 순서**로 시도한다(`orderByPublication`). 스캔은 교체 하나에 성공하면 멈추므로, 순서가 고정이면
//! 매 설치가 같은 host 를 바꾸고 뒤의 host 는 영영 옛 이미지로 남는다. 매니페스트가 **마지막으로 게시된** 때가
//! 오래된 host 부터 시도하면, 방금 교체된 host 는 새로 게시돼 맨 뒤로 가 설치마다 다른 host 가 교체된다.
//!
//! 이 파일은 std 와 `upgrade_wire`·`upgrade_limits` 만 쓴다 — PR 필수 check-boundaries 에서 돈다.

const std = @import("std");
const upgrade_wire = @import("upgrade_wire.zig");
const upgrade_limits = @import("upgrade_limits.zig");

/// 한 번의 GUI 시작에서 prepare 를 보낼 수 있는 후보 수 상한. 실측된 구 host 수(셋)를 한 번에 덮는다.
pub const max_prepare_attempts: usize = 3;

/// **다음** prepare 를 시작해도 되는 스캔 경과 시간 상한(첫 prepare 는 예전처럼 항상 보낸다). host 하나의
/// 교체 pause 예산과 같다. `resumed` 로 끝나는 보통의 실패는 약 1 초라 이 안에 들고, 한 시도가 pause 예산을
/// 다 쓰거나 재연결이 길어지면(최대 약 10 초) 경과가 이 값을 넘어 스캔이 멈춘다 — 그래서 예전보다 늘어나는
/// 시작 지연은 최악이어도 **느린 시도 하나분**으로 묶인다.
pub const continue_budget_ms: u64 = upgrade_limits.pause_budget_ms;

/// 한 후보에 대한 prepare 가 **어떻게 끝났는가**. `host_connect` 가 각 종료 갈래에서 정확히 하나를 만든다.
pub const Resolution = union(enum) {
    /// prepare 응답을 받지 못했다 — host 가 accepted 를 썼는지 모른다(느린 디스크에서 응답보다 exec 가 먼저일 수 있다).
    prepare_transport_error,
    /// host 가 prepare 를 `upgrade_busy` 로 거절했다(attachment 가 남아 있음). accepted 전이라 host 상태 불변.
    rejected_busy,
    /// host 가 `attempt_conflict` 로 거절했다 — **다른 attempt 가 그 host 에서 진행 중**이다. 교체 도중인 host 다.
    rejected_conflict,
    /// 그 밖의 typed 거절(`upgrade_unsupported`·`invalid_target`·`resource_exhausted` 등). accepted 전이라 상태 불변.
    rejected_other,
    /// prepare 가 이미 끝난 attempt 를 보고했다.
    completed: upgrade_wire.AttemptStatus,
    /// accepted → 같은 host_id 로 재연결했고 새 이미지임을 build_id 로 확인했다.
    upgraded,
    /// accepted → 재연결했지만 옛 이미지였고, host 가 이 attempt 의 status 를 보고했다.
    reconnected_old_image: upgrade_wire.AttemptStatus,
    /// accepted → 재연결 실패, 또는 재연결은 됐지만 status 를 묻지 못했거나 기록이 없었다.
    unresolved,
};

pub const Next = enum { stop, next_candidate };

/// 이 결과 뒤에 스캔을 계속해도 되는가.
pub fn afterPrepare(resolution: Resolution) Next {
    return switch (resolution) {
        // 교체 성공 — 그 host 를 쓴다.
        .upgraded => .stop,
        // 확정된 부수효과 없음: host 는 accepted 전에 거절했다. 이 host 에 대한 "지금은 안 된다"일 뿐 다른 host 와
        // 무관하고, 아무 client 도 떨어뜨리지 않았으므로 연쇄 피해가 없다.
        .rejected_busy, .rejected_other => .next_candidate,
        // 그 host 에서 **다른 attempt 가 진행 중**이다 — 교체 도중인 host 를 두고 다른 host 를 흔들지 않는다.
        .rejected_conflict => .stop,
        .completed, .reconnected_old_image => |status| afterStatus(status),
        // 불확실: accepted 여부를 모르거나(transport), 재연결·조회로 상태를 확정하지 못했다. 다른 host 를 흔들기 전에
        // 멈춘다 — 이 host 가 아직 교체 중일 수 있다.
        .prepare_transport_error, .unresolved => .stop,
    };
}

fn afterStatus(status: upgrade_wire.AttemptStatus) Next {
    return switch (status) {
        // exec 전에 되돌아가 옛 이미지로 serving 을 재개했다 — host 는 멀쩡하다. 이것이 막혀 있던 갈래다.
        .resumed => .next_candidate,
        // 성공(재연결로 채택) — 멈춘다.
        .committed => .stop,
        // 아직 진행 중 — 교체 도중인 host 를 두고 다른 host 를 흔들지 않는다.
        .pending => .stop,
        // exec **뒤** 되돌아갔다: host 가 이미지 두 번 교체와 복원을 거쳤다. 같은 시작에서 또 다른 host 의 exec 를
        // 겹치지 않는다(보수적).
        .rolled_back => .stop,
        // 권위가 망가졌다는 보고 — host 상태를 신뢰할 수 없다.
        .failed_nonretryable => .stop,
    };
}

/// 다음 후보에 prepare 를 **보내도** 되는가. `sent` 는 이미 보낸 prepare 수, `elapsed_ms` 는 스캔 시작부터의
/// 단조 경과(시계를 못 읽으면 `null` — 보수적으로 멈춘다). 첫 prepare 는 예전처럼 항상 허용한다.
pub fn mayPrepare(sent: usize, elapsed_ms: ?u64) bool {
    if (sent == 0) return true;
    if (sent >= max_prepare_attempts) return false;
    const elapsed = elapsed_ms orelse return false;
    return elapsed < continue_budget_ms;
}

/// 한 번의 스캔 상태. `host_connect` 는 후보마다 `mayPrepare` → (prepare 전송) `notePrepared` → 종료 갈래에서
/// `settle` 을 부르고, 스캔이 끝나면 `skipped` 를 UI 알림으로 돌려준다. 알림 타입은 호출자가 정한다.
pub fn Scan(comptime Notice: type) type {
    return struct {
        const Self = @This();

        sent: usize = 0,
        started_ms: ?u64,
        /// 다음 후보로 넘어간 실패 중 **첫 번째** 알림. 끝내 아무 host 도 못 바꾸면 이것이 UI 에 나간다
        /// (실패마다 로그는 호출자가 이미 남겼다). 뒤 후보가 성공하면 성공 알림이 이긴다 — 알림 슬롯은 하나다.
        skipped: ?Notice = null,

        pub fn mayPrepareNow(self: *const Self, now_ms: ?u64) bool {
            const elapsed: ?u64 = if (self.started_ms) |started|
                if (now_ms) |now| now -| started else null
            else
                null;
            return mayPrepare(self.sent, elapsed);
        }

        pub fn notePrepared(self: *Self) void {
            self.sent += 1;
        }

        /// 한 후보의 실패(`failure`)를 정산한다. `.next_candidate` 면 첫 실패만 기억하고 스캔을 잇는다.
        pub fn settle(self: *Self, resolution: Resolution, failure: Notice) Next {
            const next = afterPrepare(resolution);
            if (next == .next_candidate and self.skipped == null) self.skipped = failure;
            return next;
        }
    };
}

/// 공정 순서의 입력: host 와 그 매니페스트가 **마지막으로 게시된** 시각. 호출자는 매니페스트 파일의 birth time 을
/// 준다 — 게시(`publish`·`republish`)는 언제나 새 파일을 만들어 rename 하므로 birth time 이 바뀌고, tmp 정리를
/// 피하려는 주기적 touch(`utimensat`·`futimens`)는 mtime·ctime 만 바꾸고 birth time 은 두지 않는다. mtime 은
/// 이 목적에 쓸 수 없다 — 교체된 적 없는 host 는 한 시간마다 자기 매니페스트를 찍어 mtime 이 늘 새것이고,
/// 교체된 host 는 찍지 않아 mtime 이 교체 시각에 머문다. mtime 순이면 방금 교체한 host 가 다음 설치에서 오히려
/// **맨 앞**으로 와 같은 host 만 매번 교체된다. 시각을 못 읽으면 `null` — 맨 앞에 둬 차례를 잃지 않게 한다.
pub const Candidate = struct {
    host_id: u128,
    published_ns: ?i128,

    fn lessThan(_: void, a: Candidate, b: Candidate) bool {
        const a_ns = a.published_ns orelse std.math.minInt(i128);
        const b_ns = b.published_ns orelse std.math.minInt(i128);
        if (a_ns != b_ns) return a_ns < b_ns;
        return a.host_id < b.host_id; // 같은 시각이면 host_id 로 결정적으로
    }
};

/// 마지막 게시가 오래된 host 부터. 스캔은 교체 하나에 성공하면 멈추므로 이 순서가 곧 공정성이다 — 한 설치에
/// 옛 host 하나씩 돌아가며 교체되고, 늘 실패하는 host 는 `resumed` 로 지나친다.
pub fn orderByPublication(candidates: []Candidate) void {
    std.mem.sort(Candidate, candidates, {}, Candidate.lessThan);
}

const testing = std.testing;

test "업그레이드 스캔 판정 — resumed·거절(conflict 제외)만 다음 후보로, 교체 중·불확실은 멈춘다" {
    const Case = struct { resolution: Resolution, expected: Next };
    const cases = [_]Case{
        .{ .resolution = .upgraded, .expected = .stop },
        .{ .resolution = .rejected_busy, .expected = .next_candidate },
        .{ .resolution = .rejected_conflict, .expected = .stop },
        .{ .resolution = .rejected_other, .expected = .next_candidate },
        .{ .resolution = .prepare_transport_error, .expected = .stop },
        .{ .resolution = .unresolved, .expected = .stop },
        .{ .resolution = .{ .completed = .resumed }, .expected = .next_candidate },
        .{ .resolution = .{ .completed = .committed }, .expected = .stop },
        .{ .resolution = .{ .completed = .pending }, .expected = .stop },
        .{ .resolution = .{ .completed = .rolled_back }, .expected = .stop },
        .{ .resolution = .{ .completed = .failed_nonretryable }, .expected = .stop },
        .{ .resolution = .{ .reconnected_old_image = .resumed }, .expected = .next_candidate },
        .{ .resolution = .{ .reconnected_old_image = .committed }, .expected = .stop },
        .{ .resolution = .{ .reconnected_old_image = .pending }, .expected = .stop },
        .{ .resolution = .{ .reconnected_old_image = .rolled_back }, .expected = .stop },
        .{ .resolution = .{ .reconnected_old_image = .failed_nonretryable }, .expected = .stop },
    };
    for (cases) |case| try testing.expectEqual(case.expected, afterPrepare(case.resolution));

    // 표가 모든 변형을 덮는지 — 새 `AttemptStatus`·`Resolution` 변형이 판정 없이 새어 들어오지 않게 센다.
    const status_count = @typeInfo(upgrade_wire.AttemptStatus).@"enum".fields.len;
    const plain_variants = @typeInfo(Resolution).@"union".fields.len - 2; // completed·reconnected_old_image 제외
    try testing.expectEqual(plain_variants + 2 * status_count, cases.len);
}

test "업그레이드 스캔 판정 — 첫 prepare 는 항상, 이후는 횟수·경과 상한 안에서만" {
    try testing.expect(mayPrepare(0, null));
    try testing.expect(mayPrepare(0, 60_000));
    try testing.expect(mayPrepare(1, 900));
    try testing.expect(mayPrepare(2, continue_budget_ms - 1));
    try testing.expect(!mayPrepare(1, continue_budget_ms));
    try testing.expect(!mayPrepare(1, null));
    try testing.expect(!mayPrepare(max_prepare_attempts, 0));
}

/// 스캔 루프의 **모양**만 떼어 재는 모형. `host_connect` 의 실제 루프는 readdir·소켓을 쓰므로 PR 에서 못 돌린다 —
/// 같은 `Scan` 을 같은 순서(`mayPrepareNow` → `notePrepared` → `settle`)로 부르는지는 wiring 경계 판정자가 잠근다.
const SimResult = struct { prepared: usize, adopted: ?usize, shown: ?usize };

fn simulateScan(outcomes: []const Resolution, elapsed_per_attempt_ms: u64) SimResult {
    var scan: Scan(usize) = .{ .started_ms = 0 };
    var now: u64 = 0;
    for (outcomes, 0..) |outcome, index| {
        if (!scan.mayPrepareNow(now)) break;
        scan.notePrepared();
        now += elapsed_per_attempt_ms;
        if (outcome == .upgraded) return .{ .prepared = scan.sent, .adopted = index, .shown = null };
        if (scan.settle(outcome, index) == .stop) return .{ .prepared = scan.sent, .adopted = null, .shown = index };
    }
    return .{ .prepared = scan.sent, .adopted = null, .shown = scan.skipped };
}

test "업그레이드 스캔 — 첫 후보가 resumed 로 실패해도 둘째 후보가 교체된다 (2026-09-30 사고 순서)" {
    // 7592(resumed/handoff_failed) → c227(성공). 예전 규칙이면 첫 prepare 뒤 끝나 c227 은 시도조차 못 받았다.
    const incident = [_]Resolution{ .{ .reconnected_old_image = .resumed }, .upgraded, .upgraded };
    const result = simulateScan(&incident, 1_000);
    try testing.expectEqual(@as(?usize, 1), result.adopted);
    try testing.expectEqual(@as(usize, 2), result.prepared);

    // 교체 중·불확실 뒤에는 다음 host 를 흔들지 않고, 그 host 의 실패가 알림으로 나간다.
    const uncertain = [_]Resolution{ .unresolved, .upgraded };
    const stopped = simulateScan(&uncertain, 1_000);
    try testing.expectEqual(@as(?usize, null), stopped.adopted);
    try testing.expectEqual(@as(?usize, 0), stopped.shown);
    const post_exec = [_]Resolution{ .{ .reconnected_old_image = .rolled_back }, .upgraded };
    try testing.expectEqual(@as(?usize, null), simulateScan(&post_exec, 1_000).adopted);

    // 끝내 못 바꾸면 **첫** 실패가 알림으로 나간다(다음 후보로 넘어가며 버려지지 않는다).
    const busy_then_resumed = [_]Resolution{ .rejected_busy, .{ .completed = .resumed } };
    const none = simulateScan(&busy_then_resumed, 1_000);
    try testing.expectEqual(@as(?usize, null), none.adopted);
    try testing.expectEqual(@as(?usize, 0), none.shown);

    // 상한: 넷째 후보는 시도하지 않고, 느린 시도 하나 뒤에도 멈춘다.
    const all_resumed = [_]Resolution{ .{ .completed = .resumed }, .{ .completed = .resumed }, .{ .completed = .resumed }, .upgraded };
    const bounded = simulateScan(&all_resumed, 1_000);
    try testing.expectEqual(@as(usize, max_prepare_attempts), bounded.prepared);
    try testing.expectEqual(@as(?usize, null), bounded.adopted);
    try testing.expectEqual(@as(?usize, 0), bounded.shown);
    const slow = simulateScan(&all_resumed, continue_budget_ms);
    try testing.expectEqual(@as(usize, 1), slow.prepared);

    // 시계를 못 읽으면 첫 시도 뒤 멈춘다(보수적).
    var blind: Scan(usize) = .{ .started_ms = null };
    try testing.expect(blind.mayPrepareNow(null));
    blind.notePrepared();
    try testing.expect(!blind.mayPrepareNow(123));
}

/// 여러 번의 설치를 모형으로 돌린다: 설치마다 후보를 `orderByPublication` 순(또는 `ordered=false` 면 readdir 순)
/// 으로 시도하고, 교체된 host 는 새로 게시돼 birth time 이 그 설치 시각이 된다. `always_fails` 는 늘 `resumed`
/// 로 끝나고 매니페스트를 다시 쓰지 않는 host(2026-09-30 의 9/27 host 와 같은 모양).
fn simulateInstalls(
    readdir_order: []const u128,
    births: []i128,
    always_fails: u128,
    installs: usize,
    ordered: bool,
    upgraded_out: []u128,
) !void {
    var install: usize = 0;
    while (install < installs) : (install += 1) {
        var candidates: [8]Candidate = undefined;
        for (readdir_order, 0..) |host_id, i| candidates[i] = .{ .host_id = host_id, .published_ns = births[i] };
        const list = candidates[0..readdir_order.len];
        if (ordered) orderByPublication(list);
        var scan: Scan(u128) = .{ .started_ms = 0 };
        upgraded_out[install] = 0;
        for (list) |candidate| {
            if (!scan.mayPrepareNow(0)) break;
            scan.notePrepared();
            if (candidate.host_id == always_fails) {
                if (scan.settle(.{ .reconnected_old_image = .resumed }, candidate.host_id) == .stop) break;
                continue;
            }
            upgraded_out[install] = candidate.host_id;
            const at = std.mem.indexOfScalar(u128, readdir_order, candidate.host_id).?;
            births[at] = @as(i128, @intCast(100 + install)); // 교체 = 새 게시
            break;
        }
    }
}

test "업그레이드 스캔 — 공정 순서라 설치마다 다른 옛 host 가 교체되고, 늘 실패하는 host 는 지나친다" {
    // readdir 순서는 고정이고, 늘 실패하는 host(0xA)가 가장 오래됐다 — 2026-09-30 과 같은 모양.
    const readdir_order = [_]u128{ 0xD, 0xC, 0xB, 0xA };
    var births = [_]i128{ 4, 3, 2, 1 };
    var upgraded: [3]u128 = undefined;
    try simulateInstalls(&readdir_order, &births, 0xA, 3, true, &upgraded);
    try testing.expectEqual(@as(u128, 0xB), upgraded[0]);
    try testing.expectEqual(@as(u128, 0xC), upgraded[1]);
    try testing.expectEqual(@as(u128, 0xD), upgraded[2]);

    // 대조: readdir 순서 그대로면 매 설치가 같은 host(0xD)만 바꾼다 — 수렴하지 않는다.
    var births_fixed = [_]i128{ 4, 3, 2, 1 };
    var fixed: [3]u128 = undefined;
    try simulateInstalls(&readdir_order, &births_fixed, 0xA, 3, false, &fixed);
    try testing.expectEqual(@as(u128, 0xD), fixed[0]);
    try testing.expectEqual(@as(u128, 0xD), fixed[2]);

    // 시각을 못 읽은 host 는 맨 앞, 같은 시각은 host_id 순.
    var mixed = [_]Candidate{
        .{ .host_id = 3, .published_ns = 10 },
        .{ .host_id = 2, .published_ns = null },
        .{ .host_id = 1, .published_ns = 10 },
    };
    orderByPublication(&mixed);
    try testing.expectEqual(@as(u128, 2), mixed[0].host_id);
    try testing.expectEqual(@as(u128, 1), mixed[1].host_id);
    try testing.expectEqual(@as(u128, 3), mixed[2].host_id);
}
