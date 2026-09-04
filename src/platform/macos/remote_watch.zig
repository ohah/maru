//! **원격 감시 채널**(RW3 — [계획](../../../docs/plans/remote-watch.md)).
//!
//! 원격에 심어 둔 감시자(RW1·RW2)를 ControlMaster 위에 **하나** 띄우고, 그것이 내는 「바뀌었다」를
//! 받아 **지금 있는 읽기 파이프라인을 다시 걸게** 한다. 이 파일은 읽기를 하지 않는다 — 트리거만 만든다.
//!
//! ## 왜 하나인가
//!
//! 원격 SCM 의 대상은 **`git_repo_dest` 하나**다(원격 목록은 활성 pane 을 따라간다). 그래서 채널도
//! 하나이고, 그 값이 바뀌는 **유일한 길목**(`rememberGitRepoDest`)에서 갈아 끼운다 — 그 자리는
//! 이미 「호스트가 바뀌면 버린다」를 두 번 배운 곳이다(머리 줄 요약·쓰기 안내).
//!
//! ## 선례를 따른다
//!
//! `ssh_upload.spawnAgentEvents` 가 같은 모양의 긴 수명 원격 스트림이고, 소비는 **스레드가 아니라
//! `O_NONBLOCK` + 틱 드레인**이다(「읽기가 UI 를 안 멈춘다」). 여기서도 그대로 한다.
//!
//! ⚠️ **한 곳만 정반대다.** 그쪽은 stdin 을 `/dev/null` 로 막지만 감시자는 **파이프**를 받는다 —
//! 조용한 자식이라 EPIPE 로는 안 죽고, 부모가 쓰기 끝을 닫는 EOF 만이 정상 종료 신호다(계획 §5).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const ssh_upload = @import("ssh_upload.zig");

const install_contract = maru.session.remote_watch_install;

/// 채널이 죽었을 때 다시 띄우기까지. **즉시 재시도하지 않는다** — 소켓이 죽었거나 원격이 감시자를
/// 못 돌리는 상태면 재시도가 초당 수십 번의 ssh 자식이 된다.
pub const retry_ns: i128 = 5 * std.time.ns_per_s;

/// 한 번에 받아 둘 출력 상한. 감시자는 `change\n` 만 내므로 이보다 커질 일이 없지만, **원격이 우리가
/// 심은 것이 아닐 수도 있다**(같은 경로에 다른 파일이 있는 경우) — 그때 무한히 모으지 않는다.
pub const max_pending: usize = 4 * 1024;

/// 감시자가 「이 원격에서는 못 한다」고 말하는 종료 코드. `tools/remote-watch/main.zig` 의 상수와
/// 같아야 한다 — 경계 test 가 센다.
pub const exit_watch_limit: c_int = 2;
pub const exit_unsupported: c_int = 3;

/// 그 종료 코드가 **다시 시도해도 소용없는** 것인가(RW5).
///
/// 한도 초과·미지원은 저장소나 원격이 바뀌기 전에는 결과가 같다. 그런데도 다시 띄우면 사용자가 도크를
/// 열어 둔 내내 **5 초마다 ssh 자식**이 뜬다 — 실측으로 30 초에 7 번이었다. 그건 남의 서버에서 도는
/// 비용이라 「조용히 계속」이 가장 나쁜 선택이다.
pub fn isPermanent(exit_code: c_int) bool {
    return exit_code == exit_watch_limit or exit_code == exit_unsupported;
}

pub const Phase = enum {
    /// 아직 아무것도 안 했다. 원격 SCM 이 서면 여기서 시작한다.
    idle,
    /// 감시자를 띄웠고 「바뀌었다」를 기다린다.
    watching,
    /// 못 띄웠다. `retry_at_ns` 뒤에 다시 본다.
    backoff,
    /// **다시 안 띄운다**(RW5). 감시자가 「이 원격에서는 못 한다」고 말했다 — 대상이 바뀌기 전에는
    /// 결과가 같으므로 재시도가 순수한 낭비다. 화면은 RW3 이전 동작(포커스·새로고침)으로 돌아간다.
    gave_up,
};

/// 채널 하나. **`dest` 는 소유하지 않는다** — 세션의 `git_repo_dest` 가 그 값의 주인이고, 여기서
/// 복사해 들면 두 벌이 되어 어느 쪽이 최신인지 판정이 하나 더 생긴다.
pub const Channel = struct {
    phase: Phase = .idle,
    stream: ssh_upload.WatchStream = .{ .pid = 0, .out_fd = -1, .in_fd = -1 },
    /// **띄웠나**. `pid` 로 판정하지 않는다 — 가짜 스트림을 만드는 판정자가 `pid = 0` 을 쓰고(그래야
    /// `kill` 이 프로세스 그룹을 안 친다) 그러면 두 뜻이 겹친다(에이전트 채널이 세운 규율).
    started: bool = false,
    pending: std.ArrayListUnmanaged(u8) = .empty,
    retry_at_ns: i128 = 0,
    /// 감시자가 「바뀌었다」를 낸 횟수. 화면에 안 쓴다 — **판정자가 「정말 왔나」를 세는 값**이다.
    changes: u32 = 0,

    pub fn deinit(self: *Channel, allocator: std.mem.Allocator) void {
        self.stop();
        self.pending.deinit(allocator);
    }

    /// 채널을 끝낸다. **멱등이다** — 호스트 전환과 세션 종료가 같은 자리를 지난다.
    /// 채널을 끝내고 **감시자가 남긴 이유**를 돌려준다(정상 정리면 `-1`).
    pub fn stopReporting(self: *Channel) c_int {
        const code: c_int = if (self.started) ssh_upload.stopRemoteWatch(self.stream) else -1;
        self.started = false;
        self.stream = .{ .pid = 0, .out_fd = -1, .in_fd = -1 };
        self.pending.clearRetainingCapacity();
        return code;
    }

    /// 자식과 버퍼만 놓는다 — **판단은 안 지운다**(적대적 검증 2026-09-04 1 회차).
    ///
    /// ⚠️ `stop` 하나로 두 뜻을 쓰면 RW5 가 풀린다. 「도크가 안 보인다」는 **잠시 멈춤**이고
    /// 「대상이 바뀌었다」는 **놓아줌**인데, 둘 다 `.idle` 로 되돌리면 도크를 껐다 켤 때마다
    /// 「이 원격에서는 못 한다」가 잊혀 남의 서버에 ssh 자식이 다시 뜨고, RW6 의 배너도 다시 뜬다.
    fn release(self: *Channel, next: Phase) void {
        if (self.started) _ = ssh_upload.stopRemoteWatch(self.stream);
        self.started = false;
        self.stream = .{ .pid = 0, .out_fd = -1, .in_fd = -1 };
        self.phase = next;
        self.pending.clearRetainingCapacity();
    }

    /// 도크가 안 보이거나 SCM 뷰가 아니다 — 자식은 놓되 **`.gave_up` 은 지키다**. 그 판단은 화면이
    /// 아니라 **저 호스트**에 대한 것이라 도크를 껐다 켠다고 달라지지 않는다.
    pub fn pause(self: *Channel) void {
        self.release(if (self.phase == .gave_up) .gave_up else .idle);
    }

    /// 대상이 바뀌었다(다른 호스트이거나 로컬로 돌아왔다) — 판단째로 놓는다. 「못 한다」는 **그
    /// 호스트**의 성질이었으므로 새 대상에는 적용되지 않는다.
    pub fn stop(self: *Channel) void {
        self.release(.idle);
    }
};

/// 감시자가 내는 한 줄. `tools/remote-watch/main.zig` 가 쓰는 것과 같아야 한다 — 경계 test 가 센다.
pub const change_line = "change";

/// 모아 둔 바이트에서 **완결된 줄 수**를 세고 소비한다. 부분 줄은 남긴다 — ssh 는 경계를 안 지킨다.
///
/// 아는 줄만 센다: 감시자가 아닌 무언가가 그 경로에 있으면 출력이 우리 것이 아닐 수 있고, 그때
/// 「바뀌었다」로 읽으면 **끝없이 읽기를 거는** 상태가 된다.
pub fn takeChanges(pending: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) u32 {
    var seen: u32 = 0;
    while (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
        const line = std.mem.trim(u8, pending.items[0..nl], " \t\r");
        if (std.mem.eql(u8, line, change_line)) seen += 1;
        pending.replaceRange(allocator, 0, nl + 1, &.{}) catch {
            pending.clearRetainingCapacity();
            break;
        };
    }
    // 부분 줄이 상한을 넘으면 버린다 — 우리 것이 아닌 출력이 쌓이는 경우다.
    if (pending.items.len > max_pending) pending.clearRetainingCapacity();
    return seen;
}

const testing = std.testing;

test "완결된 `change` 줄만 세고 부분 줄은 남긴다" {
    const a = testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);

    try buf.appendSlice(a, "change\nchange\nchan");
    try testing.expectEqual(@as(u32, 2), takeChanges(&buf, a));
    // **부분 줄은 남는다** — ssh 는 줄 경계를 안 지킨다. 버리면 다음 조각과 못 이어 붙인다.
    try testing.expectEqualStrings("chan", buf.items);
    try buf.appendSlice(a, "ge\n");
    try testing.expectEqual(@as(u32, 1), takeChanges(&buf, a));
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "모르는 줄은 «바뀌었다»로 읽지 않는다" {
    const a = testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    // 우리 감시자가 아닌 무언가가 그 경로에 있으면 출력이 우리 것이 아니다. 그것을 트리거로 읽으면
    // **끝없이 읽기를 거는** 상태가 된다.
    try buf.appendSlice(a, "bash: no such file\nchange\nsegfault\n");
    try testing.expectEqual(@as(u32, 1), takeChanges(&buf, a));
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "상한을 넘는 부분 줄은 버린다 — 무한히 모으지 않는다" {
    const a = testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendNTimes(a, 'x', max_pending + 1);
    try testing.expectEqual(@as(u32, 0), takeChanges(&buf, a));
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "잠시 멈춤은 «못 한다» 는 판단을 지키고, 놓아줌은 지운다" {
    // 적대적 검증 2026-09-04 1 회차. `stop` 하나로 두 뜻을 쓰다가 RW5 가 풀렸다 — 도크를 감추면
    // `.gave_up` 이 `.idle` 로 돌아가, 다시 켤 때마다 못 하는 원격에 ssh 자식이 뜨고 배너도 되풀이됐다.
    var c: Channel = .{};

    // 「못 한다」는 **호스트**의 성질이라 화면을 감췄다 켠다고 달라지지 않는다.
    c.phase = .gave_up;
    c.pause();
    try testing.expectEqual(Phase.gave_up, c.phase);

    // 대상이 바뀌면 판단째로 놓는다 — 새 호스트에는 그 성질이 없다.
    c.phase = .gave_up;
    c.stop();
    try testing.expectEqual(Phase.idle, c.phase);

    // 나머지 상태는 잠시 멈춤에서도 처음으로 돌아간다 — 다시 보일 때 곧장 띄우면 된다.
    for ([_]Phase{ .backoff, .watching, .idle }) |from| {
        c.phase = from;
        c.pause();
        try testing.expectEqual(Phase.idle, c.phase);
    }
}

test "«다시 시도해도 소용없는» 종료만 포기로 읽는다" {
    // 한도·미지원은 대상이 바뀌기 전엔 결과가 같다 — 다시 띄우면 5 초마다 ssh 자식이 영원히 뜬다.
    try testing.expect(isPermanent(exit_watch_limit));
    try testing.expect(isPermanent(exit_unsupported));
    // 그 밖은 **일시적**으로 본다. 정상 정리(`-1`)·소켓 끊김·원격 재부팅은 다시 해 볼 값이 있다.
    try testing.expect(!isPermanent(-1));
    try testing.expect(!isPermanent(0));
    try testing.expect(!isPermanent(127)); // 명령 없음 — 설치가 다시 될 수 있다
    try testing.expect(!isPermanent(255)); // ssh 전송 실패
}

test "설치 계약과 같은 판·같은 자리를 가리킨다" {
    // 채널이 띄우는 것은 **설치가 심은 그 파일**이다. 두 상수가 갈리면 채널은 없는 파일을 띄우려 하고
    // 증상은 「감시가 그냥 안 된다」뿐이다.
    try testing.expectEqualStrings("maru-remote-watch-1", install_contract.remote_binary);
    try testing.expect(std.mem.startsWith(u8, install_contract.remote_dir, "$HOME/"));
}
