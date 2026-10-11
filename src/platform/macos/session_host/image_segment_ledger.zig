//! 이미지 채널 세그먼트 원장 — 연결마다 하나, host 전체 바이트는 공유 예산 하나.
//!
//! 단일 출처는 [Session host 이미지 채널](../../../../docs/session-host-image-channel.md) §4.3 이다. 세그먼트는 배치를
//! **만들 때** 청구되고(준비), 배치가 큐에 승인되어 이미지 채널로 나가면 발급 상태가 된다. 반환은 **정확히 한 번**이고
//! 길은 넷뿐이다: 준비 취소(`cancel`), 앱의 release(`release`), 연결 종료와 채널 상실(`releaseAll`). stream detach 는
//! 반환하지 않는다 — 그 메모리는 앱과 커널이 아직 쥐고 있다.
//!
//! 이 원장은 fd 를 쥐지 않는다. 준비 상태의 fd 는 배치 준비물이, 발급 뒤에는 앱이 소유한다. 원장은 「누가 얼마를
//! 붙잡고 있나」만 센다 — 그래서 OS 를 모르는 std-only leaf 이고, 반환 규칙은 PR CI(check-boundaries)에서 잰다.
//!
//! 송신 큐 예산·`GlobalBudget` 과 따로 둔다. 큐 예산에 넣으면 큰 세그먼트 하나가 다시 `screen_soft_bytes` 를 넘어 원래
//! 문제가 돌아오고, `GlobalBudget` 에 넣으면 텍스트만 있는 pane 까지 압력에 걸린다.

const std = @import("std");

/// 연결당 미반환 세그먼트 개수(`image_segment_max_per_connection`).
pub const image_segment_max_per_connection: usize = 32;
/// 연결당 미반환 바이트(`image_segment_bytes_per_connection`). 이보다 큰 한 장은 원장이 비었을 때만 받는다(§4.4).
pub const image_segment_bytes_per_connection: u64 = 64 * 1024 * 1024;
/// host 전체 미반환 바이트(`image_segment_bytes_per_host`). 이보다 큰 한 장은 「전송 불가」다(§4.4).
pub const image_segment_bytes_per_host: u64 = 256 * 1024 * 1024;

/// 앱이 이미지 채널을 읽지 않을 때 그 소켓에 쌓이는 fd 붙은 메시지 수(2026-10-11 이 맥 실측 — 크기와 무관하게 64).
/// host 의 이미지 채널 송신이 「정상적으로는 막힐 수 없다」는 주장이 이 수에 기댄다.
pub const fd_messages_buffered_unread: usize = 64;

comptime {
    // 개수 상한이 실측 버퍼의 절반을 넘으면 앱이 멈췄을 때 이미지 채널 송신이 막힐 수 있다. 그러면 단일 스레드 owner 가
    // 그 자리에서 서거나(블로킹) 송신 실패를 채널 상실로 처리해야 한다 — 계약은 그런 일이 정상 경로에 없다고 약속한다.
    if (image_segment_max_per_connection > fd_messages_buffered_unread / 2)
        @compileError("image_segment_max_per_connection must stay within half of the measured unread fd-message buffer");
    if (image_segment_max_per_connection == 0) @compileError("a connection must be able to hold at least one segment");
    if (image_segment_bytes_per_connection > image_segment_bytes_per_host)
        @compileError("a connection budget larger than the host budget makes the host cap unreachable");
}

/// host 전체에서 미반환 세그먼트가 붙잡은 바이트. owner 스레드 하나가 모든 연결 원장과 함께 쓴다.
pub const HostBudget = struct {
    bytes: u64 = 0,
};

pub const State = enum { prepared, issued };

pub const Entry = struct {
    segment_id: u64,
    stream_id: u64,
    image_id: u32,
    generation: u64,
    bytes: u64,
    state: State,
};

pub const ReserveError = error{
    /// 픽셀이 0 B 인 이미지는 세그먼트를 만들지 않는다 — 원장에 올 일이 없다.
    EmptySegment,
    /// 연결 개수 상한.
    ConnectionCountFull,
    /// 연결 바이트 상한(원장이 비었으면 그보다 큰 한 장도 받는다).
    ConnectionBytesFull,
    /// host 전체 바이트 상한 — 다른 연결이 반환하면 풀린다.
    HostBytesFull,
    /// host 전체 상한보다 큰 한 장 — 무엇이 반환돼도 못 보낸다(「전송 불가」).
    TooLargeForHost,
};

pub const ReleaseOutcome = enum {
    /// 발급 상태였고 지금 반환됐다.
    returned,
    /// 모르는 id·이미 반환된 id·아직 발급되지 않은 id. 무시하고 진단 카운터만 올린다.
    ignored,
};

pub const Ledger = struct {
    host: *HostBudget,
    entries: [image_segment_max_per_connection]Entry = undefined,
    len: usize = 0,
    bytes: u64 = 0,
    /// 0 은 「세그먼트 없음」(`image_ref`·`image_seg_hwm` 의 뜻)이라 1 부터 낸다. 연결 수명 동안 재사용하지 않는다.
    next_segment_id: u64 = 1,
    /// 이 연결에서 발급한 가장 큰 id — 배치의 `image_seg_hwm` 값이다(0 = 아직 없음).
    last_issued: u64 = 0,
    /// 무시한 release 수(진단). 앱이 정상이면 0 이다.
    ignored_releases: u64 = 0,

    pub fn init(host: *HostBudget) Ledger {
        return .{ .host = host };
    }

    pub fn count(self: *const Ledger) usize {
        return self.len;
    }

    pub fn items(self: *const Ledger) []const Entry {
        return self.entries[0..self.len];
    }

    /// 세그먼트를 만들기 **전에** 청구한다. 성공하면 준비 상태의 새 id 를 돌려준다.
    pub fn reserve(self: *Ledger, stream_id: u64, image_id: u32, generation: u64, bytes: u64) ReserveError!u64 {
        if (bytes == 0) return error.EmptySegment;
        if (bytes > image_segment_bytes_per_host) return error.TooLargeForHost;
        if (self.len == self.entries.len) return error.ConnectionCountFull;
        // 큰 한 장의 우선권(§4.4): 연결 상한보다 큰 이미지는 원장이 비었을 때만 받는다. 비었을 때 받지 않으면 그 이미지는
        // 영영 못 나간다.
        if (self.len != 0 and self.bytes + bytes > image_segment_bytes_per_connection) return error.ConnectionBytesFull;
        if (self.host.bytes + bytes > image_segment_bytes_per_host) return error.HostBytesFull;
        const id = self.next_segment_id;
        self.next_segment_id += 1;
        self.entries[self.len] = .{ .segment_id = id, .stream_id = stream_id, .image_id = image_id, .generation = generation, .bytes = bytes, .state = .prepared };
        self.len += 1;
        self.bytes += bytes;
        self.host.bytes += bytes;
        return id;
    }

    /// 배치가 큐에 승인되어 세그먼트 메시지를 이미지 채널로 보냈다. 준비 상태가 아니면 false(아무것도 안 바꾼다).
    pub fn issue(self: *Ledger, segment_id: u64) bool {
        const index = self.find(segment_id) orelse return false;
        const entry = &self.entries[index];
        if (entry.state != .prepared) return false;
        entry.state = .issued;
        self.last_issued = @max(self.last_issued, segment_id);
        return true;
    }

    /// 배치 롤백·attach 거절·resync 롤백: 앱이 본 적 없는 세그먼트를 되돌린다. 준비 상태일 때만 반환한다 — 발급된 것은
    /// 앱이 쥐고 있으므로 여기서 반환하면 같은 메모리를 두 번 돌려받게 된다.
    pub fn cancel(self: *Ledger, segment_id: u64) bool {
        const index = self.find(segment_id) orelse return false;
        if (self.entries[index].state != .prepared) return false;
        self.removeAt(index);
        return true;
    }

    /// 앱이 이미지 채널로 보낸 release. 발급 상태일 때만 반환한다.
    pub fn release(self: *Ledger, segment_id: u64) ReleaseOutcome {
        const index = self.find(segment_id) orelse {
            self.ignored_releases +|= 1;
            return .ignored;
        };
        if (self.entries[index].state != .issued) {
            self.ignored_releases +|= 1;
            return .ignored;
        }
        self.removeAt(index);
        return .returned;
    }

    /// 연결 종료·이미지 채널 상실: 상태와 무관하게 전부 반환한다. 이후 그 id 들의 `cancel`·`release` 는 아무것도 안 한다.
    pub fn releaseAll(self: *Ledger) void {
        self.host.bytes -= self.bytes;
        self.bytes = 0;
        self.len = 0;
    }

    /// 같은 (stream, image) 에 반환되지 않은 세그먼트가 있는가 — 있으면 새 프레임을 미룬다(§5 latest-wins).
    pub fn hasOutstanding(self: *const Ledger, stream_id: u64, image_id: u32) bool {
        for (self.items()) |entry| {
            if (entry.stream_id == stream_id and entry.image_id == image_id) return true;
        }
        return false;
    }

    fn find(self: *const Ledger, segment_id: u64) ?usize {
        for (self.items(), 0..) |entry, index| {
            if (entry.segment_id == segment_id) return index;
        }
        return null;
    }

    fn removeAt(self: *Ledger, index: usize) void {
        const bytes = self.entries[index].bytes;
        self.bytes -= bytes;
        self.host.bytes -= bytes;
        self.len -= 1;
        self.entries[index] = self.entries[self.len];
    }
};

// ── 판정자 ────────────────────────────────────────────────────────────────────
//
// 원장이 틀리면 두 방향으로 아프다. 반환이 빠지면 host 가 앱이 이미 놓은 메모리를 계속 붙잡고 있다고 믿어 이미지가 영영
// 미뤄지고, 반환이 두 번이면 예산이 실제보다 커져 상한이 뚫린다. 그래서 반환 길 넷 각각이 「정확히 한 번」인지 잰다.

const testing = std.testing;

const mib: u64 = 1024 * 1024;

test "이미지 원장: 발급한 세그먼트는 release 한 번으로 연결과 host 예산에서 함께 빠진다" {
    var host: HostBudget = .{};
    var ledger = Ledger.init(&host);
    const id = try ledger.reserve(7, 3, 11, 8 * mib);
    try testing.expectEqual(@as(u64, 8 * mib), host.bytes);
    try testing.expect(ledger.issue(id));
    try testing.expectEqual(@as(u64, id), ledger.last_issued);
    try testing.expectEqual(ReleaseOutcome.returned, ledger.release(id));
    try testing.expectEqual(@as(usize, 0), ledger.count());
    try testing.expectEqual(@as(u64, 0), ledger.bytes);
    try testing.expectEqual(@as(u64, 0), host.bytes);
    try testing.expectEqual(@as(u64, 0), ledger.ignored_releases);

    // 두 번째 release 는 아무것도 안 돌려준다 — 예산이 음수 쪽으로 새지 않는다.
    try testing.expectEqual(ReleaseOutcome.ignored, ledger.release(id));
    try testing.expectEqual(@as(u64, 0), host.bytes);
    try testing.expectEqual(@as(u64, 1), ledger.ignored_releases);
}

test "이미지 원장: 모르는 id 와 아직 발급 안 된 id 의 release 는 무시하고 세기만 한다" {
    var host: HostBudget = .{};
    var ledger = Ledger.init(&host);
    const id = try ledger.reserve(1, 1, 1, 4 * mib);
    try testing.expectEqual(ReleaseOutcome.ignored, ledger.release(999));
    // 준비 상태는 앱이 본 적 없는 id 다 — 앱이 그것을 release 하면 위조이거나 혼선이다. 반환하면 준비물이 나중에
    // cancel 할 때 두 번째 반환이 된다.
    try testing.expectEqual(ReleaseOutcome.ignored, ledger.release(id));
    try testing.expectEqual(@as(u64, 2), ledger.ignored_releases);
    try testing.expectEqual(@as(u64, 4 * mib), host.bytes);
    try testing.expect(ledger.cancel(id));
    try testing.expectEqual(@as(u64, 0), host.bytes);
}

test "이미지 원장: 준비 취소는 준비 상태에서 한 번만 반환하고 발급된 것은 건드리지 않는다" {
    var host: HostBudget = .{};
    var ledger = Ledger.init(&host);
    const kept = try ledger.reserve(1, 1, 1, 2 * mib);
    const rolled_back = try ledger.reserve(1, 2, 1, 3 * mib);
    try testing.expect(ledger.issue(kept));
    try testing.expect(ledger.cancel(rolled_back));
    try testing.expect(!ledger.cancel(rolled_back));
    // 발급된 세그먼트는 앱이 쥐고 있다 — 롤백 경로가 실수로 그 id 를 넘겨도 반환되지 않는다.
    try testing.expect(!ledger.cancel(kept));
    try testing.expectEqual(@as(u64, 2 * mib), host.bytes);
    try testing.expectEqual(@as(usize, 1), ledger.count());
    // 반환된 id 는 다시 발급할 수 없다.
    try testing.expect(!ledger.issue(rolled_back));
    try testing.expect(!ledger.issue(kept));
}

test "이미지 원장: 연결 종료·채널 상실은 준비와 발급을 모두 한 번에 반환하고 뒤늦은 cancel·release 는 헛돈다" {
    var host: HostBudget = .{};
    var other = Ledger.init(&host);
    _ = try other.reserve(9, 1, 1, 5 * mib);
    var ledger = Ledger.init(&host);
    const prepared = try ledger.reserve(1, 1, 1, 6 * mib);
    const issued = try ledger.reserve(1, 2, 1, 7 * mib);
    try testing.expect(ledger.issue(issued));
    try testing.expectEqual(@as(u64, 18 * mib), host.bytes);

    ledger.releaseAll();
    try testing.expectEqual(@as(usize, 0), ledger.count());
    try testing.expectEqual(@as(u64, 0), ledger.bytes);
    // 다른 연결의 몫은 그대로다.
    try testing.expectEqual(@as(u64, 5 * mib), host.bytes);

    // 롤백 중이던 배치 준비물과 늦게 온 release 가 다시 반환하지 않는다.
    try testing.expect(!ledger.cancel(prepared));
    try testing.expectEqual(ReleaseOutcome.ignored, ledger.release(issued));
    try testing.expectEqual(@as(u64, 5 * mib), host.bytes);
}

test "이미지 원장: 개수·연결 바이트·host 바이트 상한과 큰 한 장의 우선권" {
    var host: HostBudget = .{};
    var ledger = Ledger.init(&host);

    // 개수 상한.
    var i: usize = 0;
    while (i < image_segment_max_per_connection) : (i += 1) _ = try ledger.reserve(1, @intCast(i), 1, 1);
    try testing.expectError(error.ConnectionCountFull, ledger.reserve(1, 999, 1, 1));
    ledger.releaseAll();

    // 연결 바이트 상한: 차 있으면 넘는 것을 거절한다.
    _ = try ledger.reserve(1, 1, 1, 40 * mib);
    try testing.expectError(error.ConnectionBytesFull, ledger.reserve(1, 2, 1, 30 * mib));
    _ = try ledger.reserve(1, 2, 1, 24 * mib); // 정확히 상한까지는 된다
    ledger.releaseAll();

    // 큰 한 장(6K 화면 전체 pane 81 MB): 원장이 비었을 때만, 그리고 그 뒤로는 다른 것이 못 들어온다.
    const big = try ledger.reserve(1, 1, 1, 81 * mib);
    try testing.expectError(error.ConnectionBytesFull, ledger.reserve(1, 2, 1, 1));
    try testing.expect(ledger.cancel(big));

    // host 전체 상한보다 큰 한 장은 무엇이 비어도 못 보낸다.
    try testing.expectError(error.TooLargeForHost, ledger.reserve(1, 1, 1, image_segment_bytes_per_host + 1));

    // host 상한: 다른 연결들이 채운 몫과 합쳐 잰다.
    var a = Ledger.init(&host);
    var b = Ledger.init(&host);
    var c = Ledger.init(&host);
    var d = Ledger.init(&host);
    _ = try a.reserve(1, 1, 1, 64 * mib);
    _ = try b.reserve(1, 1, 1, 64 * mib);
    _ = try c.reserve(1, 1, 1, 64 * mib);
    _ = try d.reserve(1, 1, 1, 60 * mib);
    try testing.expectError(error.HostBytesFull, ledger.reserve(1, 1, 1, 5 * mib));
    _ = try ledger.reserve(1, 1, 1, 4 * mib); // 정확히 host 상한까지
    try testing.expectEqual(image_segment_bytes_per_host, host.bytes);
    a.releaseAll();
    _ = try ledger.reserve(1, 2, 1, 5 * mib); // 다른 연결이 반환하면 풀린다

    try testing.expectError(error.EmptySegment, ledger.reserve(1, 3, 1, 0));
}

test "이미지 원장: id 는 1 부터 단조이고 재사용하지 않으며 hwm 은 발급한 것 중 가장 큰 id 다" {
    var host: HostBudget = .{};
    var ledger = Ledger.init(&host);
    const first = try ledger.reserve(1, 1, 1, 1);
    const second = try ledger.reserve(2, 1, 1, 1);
    try testing.expectEqual(@as(u64, 1), first);
    try testing.expectEqual(@as(u64, 2), second);
    try testing.expectEqual(@as(u64, 0), ledger.last_issued); // 준비만으로는 hwm 이 움직이지 않는다
    try testing.expect(ledger.issue(second));
    try testing.expect(ledger.issue(first)); // 늦게 승인된 작은 id 가 hwm 을 되돌리지 않는다
    try testing.expectEqual(@as(u64, 2), ledger.last_issued);
    ledger.releaseAll();
    try testing.expectEqual(@as(u64, 3), try ledger.reserve(1, 1, 1, 1));
}

test "이미지 원장: 같은 stream 의 같은 이미지에 미반환 세그먼트가 있는지 반환 길마다 정확히 답한다" {
    var host: HostBudget = .{};
    var ledger = Ledger.init(&host);
    const id = try ledger.reserve(4, 9, 1, 1);
    try testing.expect(ledger.hasOutstanding(4, 9));
    try testing.expect(!ledger.hasOutstanding(4, 8)); // 다른 이미지
    try testing.expect(!ledger.hasOutstanding(5, 9)); // 다른 stream 의 같은 image id
    try testing.expect(ledger.issue(id));
    try testing.expect(ledger.hasOutstanding(4, 9)); // 발급돼도 앱이 쥐고 있는 동안은 미반환이다
    try testing.expectEqual(ReleaseOutcome.returned, ledger.release(id));
    try testing.expect(!ledger.hasOutstanding(4, 9));
}
