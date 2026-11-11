//! 가짜 응답 본문을 sidecar 로 보내는 창(W9d④ — docs/plans/web-osr-backend.md 「W9d④ 결정·실측」 §7) — L2 순수.
//!
//! 왜 창인가(phase 0 실측 M28): sidecar 의 명령 상자는 1 MiB 다 — 32 KiB frame 64 개(2 MiB)를 38 ms 에 쓰면 `failure protocol_violation "command
//! inbox overflow"` 로 관이 닫혔다. 본문은 앱 전체에서 32 MiB 까지라(재시작 뒤 다시 보낸다) 한 번에 보내면 sidecar 가 죽는다. 그래서 maru 는
//! 앱 전체에서 **확인받지 않은 본문 바이트 ≤ 256 KiB** 를 지키며 16 KiB 조각으로 보낸다 — DevTools 인자의 최악(640 KiB)과 작은 frame 여유를 더해도
//! 1 MiB 안이다(codec comptime). sidecar 는 처리한 조각마다 `net_mock_ack{body_id, received}` 를 보낸다(버린 조각도 — 그래야 창이 새지 않는다).
//!
//! 규칙: 줄(`queue`)에는 보낼 본문(탭·번호·길이)을 넣고, 보낸 것마다 그 번호의 비행(`Flight` — 보낸 바이트·확인받은 바이트)을 센다. 확인은 그
//! 번호의 누적 바이트라 차례가 뒤섞여도·겹쳐 와도 큰 값만 쓴다. 모르는 번호의 확인은 버린다. 본문을 지우면(규칙을 지움·바꿈·탭 닫힘) 줄에서만
//! 빼고 비행은 확인이 올 때까지 남긴다(보낸 바이트는 sidecar 의 상자에 있을 수 있다). sidecar 가 다시 뜨면 비행을 모두 잊는다(새 관 — 옛 상자가
//! 없다). 본문 번호는 보낼 때마다 새것이라(`web_osr_mock.resendAll`) 옛 전송의 늦은 확인이 섞이지 않는다.
//!
//! 시험이 증명하는 것: 창(256 KiB 를 넘기지 않는다)·확인으로 열림, 확인의 뒤섞임·중복·모르는 번호(버림), 지운 본문은 줄에서 빠지되 비행은
//! 확인까지 남는다, 탭 닫힘, sidecar 재시작에서 창 초기화, 여러 본문의 차례.

const std = @import("std");
const ws = @import("web_sidecar/root.zig");

const mr = ws.net_mock_rules;
const msg = ws.message;

/// 보낼 본문 하나(줄).
pub const Item = struct {
    tab: u64,
    body_id: u32,
    total: u32,
    /// 다음에 보낼 자리.
    offset: u32 = 0,
};

/// 보낸 본문의 비행(창 셈).
pub const Flight = struct {
    body_id: u32,
    sent: u32 = 0,
    acked: u32 = 0,
};

/// 다음 조각 — 바이트는 부른 쪽이 본문에서 잘라 싣는다(`offset .. offset + len`).
pub const Chunk = struct { tab: u64, body_id: u32, offset: u32, len: u32, total: u32 };

pub const Pump = struct {
    queue: std.ArrayList(Item) = .empty,
    flights: std.ArrayList(Flight) = .empty,
    /// 확인받지 않은 바이트(비행마다 `sent - acked` 의 합).
    in_flight: usize = 0,

    pub fn deinit(self: *Pump, gpa: std.mem.Allocator) void {
        self.queue.deinit(gpa);
        self.flights.deinit(gpa);
        self.* = .{};
    }

    /// 본문 하나를 보낼 줄에 넣는다(같은 번호가 이미 있으면 그대로).
    pub fn enqueue(self: *Pump, gpa: std.mem.Allocator, tab: u64, body_id: u32, total: u32) std.mem.Allocator.Error!void {
        if (body_id == 0 or total == 0) return;
        for (self.queue.items) |q| if (q.body_id == body_id) return;
        try self.queue.append(gpa, .{ .tab = tab, .body_id = body_id, .total = total });
    }

    /// 그 본문을 줄에서 뺀다(비행은 확인까지 남는다).
    pub fn drop(self: *Pump, body_id: u32) void {
        var i: usize = 0;
        while (i < self.queue.items.len) {
            if (self.queue.items[i].body_id == body_id) _ = self.queue.orderedRemove(i) else i += 1;
        }
    }

    /// 그 탭의 본문을 모두 줄에서 뺀다(탭 닫힘·지켜보기 끔·새 브라우저 — 다시 넣는다).
    pub fn dropTab(self: *Pump, tab: u64) void {
        var i: usize = 0;
        while (i < self.queue.items.len) {
            if (self.queue.items[i].tab == tab) _ = self.queue.orderedRemove(i) else i += 1;
        }
    }

    /// sidecar 가 다시 떴다 — 새 관이라 옛 상자의 바이트는 없다. 비행·줄을 모두 잊는다(부른 쪽이 탭마다 다시 넣는다).
    pub fn reset(self: *Pump) void {
        self.queue.clearRetainingCapacity();
        self.flights.clearRetainingCapacity();
        self.in_flight = 0;
    }

    fn flightOf(self: *Pump, body_id: u32) ?*Flight {
        for (self.flights.items) |*f| if (f.body_id == body_id) return f;
        return null;
    }

    /// 다음 조각(창이 허락하면) — 보낸 것으로 센다. 줄의 앞에서부터 차례로.
    pub fn next(self: *Pump, gpa: std.mem.Allocator) std.mem.Allocator.Error!?Chunk {
        if (self.queue.items.len == 0) return null;
        const item = &self.queue.items[0];
        const len: u32 = @intCast(@min(mr.body_chunk_bytes, item.total - item.offset));
        if (self.in_flight + len > mr.window_bytes) return null;
        const f = self.flightOf(item.body_id) orelse blk: {
            try self.flights.append(gpa, .{ .body_id = item.body_id });
            break :blk &self.flights.items[self.flights.items.len - 1];
        };
        const out: Chunk = .{ .tab = item.tab, .body_id = item.body_id, .offset = item.offset, .len = len, .total = item.total };
        f.sent = item.offset + len;
        self.in_flight += len;
        item.offset += len;
        if (item.offset >= item.total) _ = self.queue.orderedRemove(0);
        return out;
    }

    /// sidecar 의 확인 — 그 번호의 누적 바이트(큰 값만 쓴다). 다 확인받은 비행은 지운다. 모르는 번호는 버린다.
    pub fn ack(self: *Pump, body_id: u32, received: u32) void {
        for (self.flights.items, 0..) |*f, i| if (f.body_id == body_id) {
            const r = @min(received, f.sent);
            if (r > f.acked) {
                self.in_flight -|= r - f.acked;
                f.acked = r;
            }
            const queued = for (self.queue.items) |q| {
                if (q.body_id == body_id) break true;
            } else false;
            if (f.acked == f.sent and !queued) _ = self.flights.swapRemove(i);
            return;
        };
    }

    /// 방금 `next` 가 준 조각을 보내지 못했다(그 사이 본문이 사라졌다) — 센 것을 되돌리고 그 본문을 줄에서 뺀다.
    pub fn unsend(self: *Pump, c: Chunk) void {
        self.drop(c.body_id);
        for (self.flights.items, 0..) |*f, i| if (f.body_id == c.body_id) {
            if (f.sent == c.offset + c.len) {
                f.sent = c.offset;
                self.in_flight -|= c.len;
            }
            if (f.acked >= f.sent) _ = self.flights.swapRemove(i);
            return;
        };
    }

    /// 보낼 것이 남았는가.
    pub fn pending(self: *const Pump) bool {
        return self.queue.items.len > 0;
    }
};

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "W9d④: 창 — 확인받지 않은 바이트는 256 KiB 를 넘지 않고, 확인이 오면 열린다, 다 확인받은 비행은 지운다" {
    var p: Pump = .{};
    defer p.deinit(testing.allocator);
    try p.enqueue(testing.allocator, 1, 7, 512 * 1024);
    var n: usize = 0;
    while (try p.next(testing.allocator)) |c| {
        try testing.expectEqual(@as(u32, 16 * 1024), c.len);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 16), n); // 256 KiB
    try testing.expectEqual(mr.window_bytes, p.in_flight);
    p.ack(7, 64 * 1024);
    var m: usize = 0;
    while (try p.next(testing.allocator)) |_| m += 1;
    try testing.expectEqual(@as(usize, 4), m);
    p.ack(7, 512 * 1024);
    while (try p.next(testing.allocator)) |_| {}
    p.ack(7, 512 * 1024);
    try testing.expectEqual(@as(usize, 0), p.in_flight);
    try testing.expectEqual(@as(usize, 0), p.flights.items.len);
    try testing.expect(!p.pending());
}

test "W9d④: 확인 — 뒤섞임(작은 값 나중)·중복은 큰 값만, 보낸 것보다 큰 값은 보낸 만큼, 모르는 번호는 버린다" {
    var p: Pump = .{};
    defer p.deinit(testing.allocator);
    try p.enqueue(testing.allocator, 1, 3, 48 * 1024);
    while (try p.next(testing.allocator)) |_| {}
    try testing.expectEqual(@as(usize, 48 * 1024), p.in_flight);
    p.ack(3, 32 * 1024);
    p.ack(3, 16 * 1024); // 늦게 온 작은 값
    p.ack(3, 32 * 1024); // 중복
    try testing.expectEqual(@as(usize, 16 * 1024), p.in_flight);
    p.ack(99, 1000); // 모르는 번호
    try testing.expectEqual(@as(usize, 16 * 1024), p.in_flight);
    p.ack(3, 999_999);
    try testing.expectEqual(@as(usize, 0), p.in_flight);
}

test "W9d④: 지운 본문은 줄에서 빠지되 보낸 바이트의 비행은 확인까지 남는다, 탭 닫힘, sidecar 재시작은 창을 처음으로, 여러 본문은 차례로" {
    var p: Pump = .{};
    defer p.deinit(testing.allocator);
    try p.enqueue(testing.allocator, 1, 5, 64 * 1024);
    try p.enqueue(testing.allocator, 2, 6, 32 * 1024);
    try p.enqueue(testing.allocator, 2, 6, 32 * 1024); // 같은 번호는 한 번
    try testing.expectEqual(@as(usize, 2), p.queue.items.len);
    const c1 = (try p.next(testing.allocator)).?;
    try testing.expectEqual(@as(u32, 5), c1.body_id);
    p.drop(5); // 규칙을 지웠다 — 남은 48 KiB 는 보내지 않는다
    try testing.expectEqual(@as(usize, 16 * 1024), p.in_flight);
    const c2 = (try p.next(testing.allocator)).?;
    try testing.expectEqual(@as(u32, 6), c2.body_id);
    p.ack(5, 16 * 1024); // sidecar 가 버린 덩어리의 조각도 확인한다
    try testing.expectEqual(@as(usize, 16 * 1024), p.in_flight);
    p.dropTab(2);
    try testing.expect(!p.pending());
    // 보내지 못한 조각은 되돌린다(그 사이 본문이 사라졌다).
    try p.enqueue(testing.allocator, 3, 8, 40 * 1024);
    const c3 = (try p.next(testing.allocator)).?;
    p.unsend(c3);
    try testing.expectEqual(@as(usize, 16 * 1024), p.in_flight); // 본문 5 의 남은 비행만
    try testing.expect(!p.pending());
    p.reset();
    try testing.expectEqual(@as(usize, 0), p.in_flight);
    try testing.expectEqual(@as(usize, 0), p.flights.items.len);
    try p.enqueue(testing.allocator, 1, 0, 10); // 빈 본문은 넣지 않는다
    try testing.expect(!p.pending());
}

test "W9d④ 변이: 누적 확인은 새로 확인된 바이트만 창에서 뺀다(조각 셋 비행 중 16 KiB·32 KiB 확인)" {
    var p: Pump = .{};
    defer p.deinit(testing.allocator);
    try p.enqueue(testing.allocator, 1, 5, 48 * 1024);
    for (0..3) |_| _ = (try p.next(testing.allocator)).?;
    try testing.expectEqual(@as(usize, 48 * 1024), p.in_flight);
    p.ack(5, 16 * 1024);
    try testing.expectEqual(@as(usize, 32 * 1024), p.in_flight);
    p.ack(5, 32 * 1024);
    try testing.expectEqual(@as(usize, 16 * 1024), p.in_flight);
}

test "W9d④ 변이: 줄에 남은 본문의 비행은 앞부분을 다 확인받아도 지우지 않는다(다음 조각의 확인이 그 비행에 이어진다)" {
    var p: Pump = .{};
    defer p.deinit(testing.allocator);
    try p.enqueue(testing.allocator, 1, 5, 48 * 1024);
    _ = (try p.next(testing.allocator)).?;
    p.ack(5, 16 * 1024);
    _ = (try p.next(testing.allocator)).?;
    _ = (try p.next(testing.allocator)).?;
    try testing.expectEqual(@as(usize, 32 * 1024), p.in_flight);
    p.ack(5, 32 * 1024);
    try testing.expectEqual(@as(usize, 16 * 1024), p.in_flight);
    p.ack(5, 48 * 1024);
    try testing.expectEqual(@as(usize, 0), p.in_flight);
    try testing.expectEqual(@as(usize, 0), p.flights.items.len);
}
