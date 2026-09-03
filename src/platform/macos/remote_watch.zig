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

pub const Phase = enum {
    /// 아직 아무것도 안 했다. 원격 SCM 이 서면 여기서 시작한다.
    idle,
    /// 감시자를 띄웠고 「바뀌었다」를 기다린다.
    watching,
    /// 못 띄웠다. `retry_at_ns` 뒤에 다시 본다.
    backoff,
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
    pub fn stop(self: *Channel) void {
        if (self.started) ssh_upload.stopRemoteWatch(self.stream);
        self.started = false;
        self.stream = .{ .pid = 0, .out_fd = -1, .in_fd = -1 };
        self.phase = .idle;
        self.pending.clearRetainingCapacity();
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

test "설치 계약과 같은 판·같은 자리를 가리킨다" {
    // 채널이 띄우는 것은 **설치가 심은 그 파일**이다. 두 상수가 갈리면 채널은 없는 파일을 띄우려 하고
    // 증상은 「감시가 그냥 안 된다」뿐이다.
    try testing.expectEqualStrings("maru-remote-watch-1", install_contract.remote_binary);
    try testing.expect(std.mem.startsWith(u8, install_contract.remote_dir, "$HOME/"));
}
