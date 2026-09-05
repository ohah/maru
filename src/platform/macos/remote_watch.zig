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
/// ⚠️ **판 2 부터 `exit_watch_limit` 은 원격이 안 낸다**(RW7d — 한도에서 폴링으로 내려간다).
/// 그래도 목록에 남긴다: 원격에 **판 1 바이너리가 도는 동안**은 그쪽이 여전히 그 코드로 나가고,
/// 그때 재시도하면 5 초마다 ssh 자식이 뜬다(RW5 가 없앤 폭주). 판이 갈리면 다음 설치에서 바뀐다.
pub fn isPermanent(exit_code: c_int) bool {
    return exit_code == exit_watch_limit or exit_code == exit_unsupported;
}

/// 원격에 감시자가 **심겨 있는가**(RW2c). RW2a 가 계약을, RW2b 가 페이로드를 만들어 두고도 «아무도
/// 실행하지 않아» 감시자는 사람이 손으로 넣은 원격에서만 돌았다 — 그 자리를 잇는 상태다.
///
/// tick 은 **읽기만** 하고, 실제 확인·심기는 백그라운드 스레드가 한다(`uploadWorker` 와 같은 규율 —
/// ssh 왕복은 블로킹이라 UI 틱에서 하면 화면이 선다).
pub const Install = enum {
    /// 아직 안 물어봤다.
    unknown,
    /// 스레드가 확인·심기 중이다. **또 띄우지 않는다.**
    running,
    /// 있고 우리 판이다 — 띄워도 된다.
    ready,
    /// 못 심었다(원격이 거절·전송 실패·번들에 그 변종이 없다). 백오프 뒤 다시 본다.
    failed,
};

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
    /// **지금 감시하고 있는 저장소 루트.** 이것이 없으면 «같은 호스트에서 저장소만 바뀌는» 전환을
    /// 못 본다(적대적 검증 2026-09-04 6 회차) — `git_repo_dest` 가 그대로라 `rememberGitRepoDest` 는
    /// 조기 반환하고, 채널은 **옛 저장소**를 계속 본다. 그러면 새 저장소의 변경은 영영 안 오고 옛
    /// 저장소의 변경이 엉뚱한 새로고침을 건다. 힙을 안 쓴다 — 이 구조체는 `AppSession` 안에 산다.
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,
    /// 설치 상태(RW2c). 대상이 바뀌면 `stop` 이 `.unknown` 으로 되돌린다 — 새 호스트에는 그 답이 없다.
    install: Install = .unknown,

    /// 지금 감시 중인 루트(안 띄웠으면 빈 슬라이스).
    pub fn watchedRoot(self: *const Channel) []const u8 {
        return self.root_buf[0..self.root_len];
    }

    /// 띄운 루트를 적어 둔다. **부를 수 있는지는 `canTrack` 이 먼저 답한다** — 이 함수는 들어온 것을
    /// 그대로 적는다.
    pub fn rememberRoot(self: *Channel, root: []const u8) void {
        std.debug.assert(canTrack(root));
        @memcpy(self.root_buf[0..root.len], root);
        self.root_len = root.len;
    }

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

    /// **자식과 버퍼만** 놓는다 — 판단(`phase`)도 그 판단의 대상(`root_len`)도 안 건드린다.
    fn releaseChild(self: *Channel) void {
        if (self.started) _ = ssh_upload.stopRemoteWatch(self.stream);
        self.started = false;
        self.stream = .{ .pid = 0, .out_fd = -1, .in_fd = -1 };
        self.pending.clearRetainingCapacity();
    }

    /// 도크가 안 보이거나 SCM 뷰가 아니다 — 자식은 놓되 **판단과 그 대상을 지킨다.**
    ///
    /// `.gave_up`(못 한다)도 `.backoff`(아직 때가 아니다)도 **저 호스트의 저 저장소**에 대한 판단이라
    /// 화면을 껐다 켠다고 달라지지 않는다(적대적 검증 4 회차 — `.backoff` 를 빠뜨려 재개가
    /// `retry_at_ns` 를 건너뛰었다).
    ///
    /// ⚠️ **루트 기억도 지키다**(8 회차). 여기서 지우면 「어느 저장소에 대한 판단인가」가 사라져,
    /// 도크를 껐다 켠 뒤 저장소를 바꾸면 `.gave_up` 이 그대로 남아 **새 저장소를 영영 안 본다.**
    pub fn pause(self: *Channel) void {
        self.releaseChild();
        self.phase = switch (self.phase) {
            .gave_up, .backoff => self.phase,
            .idle, .watching => .idle,
        };
    }

    /// 대상이 바뀌었다(다른 호스트이거나 로컬로 돌아왔다) — 판단째로 놓는다. 「못 한다」는 **그
    /// 호스트**의 성질이었으므로 새 대상에는 적용되지 않는다.
    pub fn stop(self: *Channel) void {
        self.releaseChild();
        self.phase = .idle;
        self.root_len = 0;
        // ⚠️ **설치 답도 놓는다.** 「심겨 있다」는 **그 호스트**에 대한 답이라 새 대상에는 안 통한다.
        // `pause` 는 반대로 지킨다 — 화면을 감췄다고 저쪽에서 파일이 사라지지 않는다.
        self.install = .unknown;
    }
};

/// 감시 루트로 적어 둘 수 있는 최대 길이. `Channel.root_buf` 와 같은 값이다.
pub const max_root_bytes: usize = std.fs.max_path_bytes;

/// 이 루트를 **추적할 수 있는가**. 못 하면 **아예 안 띄운다**(적대적 검증 2026-09-04 7 회차).
///
/// ⚠️ 앞선 판에서는 「넘으면 기억을 0 으로 두고 다음 tick 이 다시 띄운다」고 적었는데 **거짓이었다** —
/// 전환 판정이 `root_len != 0` 을 요구해 그 경우 아예 안 걸렸고, 무엇을 보는지 모르는 감시자가 조용히
/// 남았다. 그렇다고 `started` 로 바꾸면 이번엔 매 tick 「달라졌다」가 되어 **재기동 폭주**다(RW5 가
/// 없앤 바로 그것). 띄우기 «전» 에 답하는 것만이 두 함정을 다 피한다.
pub fn canTrack(root: []const u8) bool {
    return root.len <= max_root_bytes;
}

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

    // ⚠️ **`.backoff` 도 판단이다**(적대적 검증 4 회차). 무너뜨리면 재개가 위 switch 의 `.backoff`
    // 갈래를 안 지나 `retry_at_ns` 를 건너뛴다 — 죽은 원격에 도크 토글마다 ssh 자식이 뜬다.
    c.phase = .backoff;
    c.retry_at_ns = 12_345;
    c.pause();
    try testing.expectEqual(Phase.backoff, c.phase);
    try testing.expectEqual(@as(i128, 12_345), c.retry_at_ns);
    c.stop();
    try testing.expectEqual(Phase.idle, c.phase);

    // 진행 중이거나 처음인 상태만 처음으로 돌아간다 — 다시 보일 때 곧장 띄우면 된다.
    for ([_]Phase{ .watching, .idle }) |from| {
        c.phase = from;
        c.pause();
        try testing.expectEqual(Phase.idle, c.phase);
    }
}

test "무엇을 보고 있는지 기억한다 — 같은 호스트에서 저장소만 바뀌는 전환" {
    // 적대적 검증 2026-09-04 6 회차. `git_repo_dest` 가 그대로면 `rememberGitRepoDest` 는 조기
    // 반환하므로, 저장소가 바뀐 것을 아는 유일한 길은 **채널이 무엇을 보고 있는지 아는 것**이다.
    var c: Channel = .{};
    try testing.expectEqualStrings("", c.watchedRoot());

    c.rememberRoot("/srv/app");
    try testing.expectEqualStrings("/srv/app", c.watchedRoot());

    // **놓아줌**은 기억도 지운다 — 새 대상에는 그 판단이 없다.
    c.stop();
    try testing.expectEqualStrings("", c.watchedRoot());

    // ⚠️ **잠시 멈춤은 기억을 지킨다**(8 회차). 여기서 지우면 「어느 저장소에 대한 판단인가」가
    // 사라져, 도크를 껐다 켠 뒤 저장소를 바꾸면 `.gave_up` 이 그대로 남아 새 저장소를 영영 안 본다.
    for ([_]Phase{ .gave_up, .backoff, .watching, .idle }) |from| {
        c.rememberRoot("/srv/app");
        c.phase = from;
        c.pause();
        try testing.expectEqualStrings("/srv/app", c.watchedRoot());
    }

    // ⚠️ **설치 답의 수명은 「대상」이다**(RW2c). 화면을 감췄다고 저쪽 파일이 사라지지 않으므로
    // `pause` 는 지키고, 새 호스트에는 그 답이 안 통하므로 `stop` 은 지운다.
    c.install = .ready;
    c.pause();
    try testing.expectEqual(Install.ready, c.install);
    c.stop();
    try testing.expectEqual(Install.unknown, c.install);

    // **추적할 수 있는지는 띄우기 전에 답한다** — 못 하면 안 띄우므로 `rememberRoot` 에 안 온다.
    try testing.expect(canTrack("/srv/app"));
    try testing.expect(canTrack("x" ** max_root_bytes));
    try testing.expect(!canTrack("x" ** (max_root_bytes + 1)));
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
    //
    // ⚠️ **판 번호를 여기 박지 않는다**(RW7d 에서 2 로 올리며 세 자리째 밟았다). 박아 두면 판을 올릴
    // 때마다 빨개지고, 그 손질이 곧 「무엇을 확인하는지」를 흐린다. 확인해야 하는 것은 **번호**가
    // 아니라 «판 문자열과 파일 이름이 같은 판을 가리키는가» 다.
    try testing.expect(std.mem.startsWith(u8, install_contract.remote_binary, "maru-remote-watch-"));
    const name_version = install_contract.remote_binary["maru-remote-watch-".len..];
    const line_version = std.mem.trimEnd(u8, install_contract.version_line["maru-remote-watch ".len..], "\n");
    try testing.expectEqualStrings(line_version, name_version);
    try testing.expect(std.mem.startsWith(u8, install_contract.remote_dir, "$HOME/"));
}
