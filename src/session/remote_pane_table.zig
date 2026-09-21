//! 원격 tmux pane 별 훅 슬롯 테이블([계획 RA7](../../docs/plans/remote-agent-state.md) 조각 2).
//!
//! **무엇을 답하나**: 「이 Term(surface) 의 wire 이벤트가 tmux pane `%N` 을 달고 왔을 때 그 pane 의 훅 상태는 어디 있나」.
//! 한 tmux 세션의 pane 여럿이 한 Term 으로 접히는 이유는 상태 자리가 Term 당 하나(`Term.hook`)였기 때문이라(재실측 ⑤),
//! pane 마다 슬롯을 따로 든다. **`AppSession` 에 모아 두고 Term 은 참조만 한다**(RA7.3.2 ⓒ) — pane 은 Term 의 속성이
//! 아니라 원격 세션 전체의 자원이고, 원격 pane 이 없는 로컬 Term 이 값을 치르면 안 된다. `turn_snapshot.RingMap` 과 같은
//! 모양이다: 고정 배열, 키로 찾고, 상한을 넘으면 **가장 오래 안 쓴 것부터** 버리며, 밀린 사실을 세어 화면이 말하게 한다.
//!
//! 키는 `(surface_id, pane)` 다. `surface_id` 가 이미 nonce(=Term=원격 tmux 서버의 attach 클라이언트)를 가르므로 다른
//! 서버의 같은 `%0` 과 부딪치지 않는다. 같은 Term 이 서버를 껐다 켜면 옛 `%0` 슬롯을 새 이벤트가 이어받는다 — 결정 4
//! (닫힌 pane 을 접지 않는다) 대로 무해하고, 상태는 최신 이벤트가 정한다.
const std = @import("std");
const session_model = @import("session_model.zig");
const remote_agent_stream = @import("remote_agent_stream.zig");

pub const HookSlot = session_model.HookSlot;

/// 동시에 드는 pane 수 상한. 실기 배치는 세션당 0~2(2026-09-21 재실측 — tmux 세션 11개 전부 pane 1)라 작게 잡고,
/// 밀리면 `evicted` 로 드러낸다(«몇 개까지» 를 미리 안다고 큰 값을 잡지 않는다 — `RingMap.max_sessions` 규율).
pub const max_panes: usize = 16;
pub const max_pane_len: usize = remote_agent_stream.max_pane_bytes;

pub const Entry = struct {
    surface_id: u64 = 0,
    pane: [max_pane_len]u8 = undefined,
    pane_len: u8 = 0,
    slot: HookSlot = .{},
    /// 마지막으로 쓰인 순서(단조 증가). 0이면 빈 자리다 — 시계가 아니라 카운터인 이유는 `RingMap` 과 같다.
    used: u64 = 0,
    /// 마지막 이벤트를 받은 시각(awake ms). 「가장 최근 pane」 을 고르는 잣대 — 대화 줄·집계의 동률 해소.
    last_event_ms: u64 = 0,

    pub fn paneName(self: *const Entry) []const u8 {
        return self.pane[0..self.pane_len];
    }
};

/// 밀린 pane 의 자취 — 어느 surface 의 어느 pane 이 밀렸나. 화면이 **그 Term 에서** «N 개가 밀렸다» 를 말할 근거다
/// (`evicted` 카운터는 앱 전체라 Term 별로는 못 말한다 — 조각 5 재실측 ①).
pub const Evicted = struct {
    surface_id: u64 = 0,
    pane: [max_pane_len]u8 = undefined,
    pane_len: u8 = 0,

    pub fn paneName(self: *const Evicted) []const u8 {
        return self.pane[0..self.pane_len];
    }
};
/// 자취 상한. 넘치면 오래된 자취부터 잊어 **과소 보고**한다 — `RingMap.max_evicted` 와 같은 한계.
pub const max_evicted: usize = max_panes;

pub const Table = struct {
    entries: [max_panes]Entry = @splat(.{}),
    tick: u64 = 0,
    /// 상한을 넘겨 **밀어낸 횟수**(앱 전체). 화면이 «pane 행이 밀려났다» 를 말할 근거 — 조용히 사라지지 않는다.
    evicted: u32 = 0,
    /// 밀린 (surface, pane) 자취(링). 그 pane 이 되돌아오거나 surface 가 버려지면 지운다.
    evicted_trace: [max_evicted]Evicted = @splat(.{}),
    evicted_next: usize = 0,

    /// 그 (surface, pane) 의 슬롯 — **없으면 만든다**. 빈 pane 이름은 거절한다(그 이벤트는 Term 인라인 슬롯 몫이다).
    pub fn slotFor(self: *Table, surface_id: u64, pane: []const u8, now_ms: u64) ?*Entry {
        if (pane.len == 0 or pane.len > max_pane_len) return null;
        self.tick +|= 1;
        if (self.findMut(surface_id, pane)) |e| {
            e.used = self.tick;
            e.last_event_ms = now_ms;
            return e;
        }
        const slot = self.victim();
        if (slot.used != 0) {
            self.evicted +|= 1;
            self.rememberEvicted(slot.surface_id, slot.paneName());
        }
        slot.* = .{ .surface_id = surface_id, .pane_len = @intCast(pane.len), .used = self.tick, .last_event_ms = now_ms };
        @memcpy(slot.pane[0..pane.len], pane);
        // 밀렸던 pane 이 되돌아왔다 — 자취를 지운다(행은 다시 서지만 상태·응답은 잃었다).
        self.forgetEvicted(surface_id, pane);
        return slot;
    }

    fn rememberEvicted(self: *Table, surface_id: u64, pane: []const u8) void {
        const t = &self.evicted_trace[self.evicted_next];
        t.* = .{ .surface_id = surface_id, .pane_len = @intCast(pane.len) };
        @memcpy(t.pane[0..pane.len], pane);
        self.evicted_next = (self.evicted_next + 1) % max_evicted;
    }

    fn forgetEvicted(self: *Table, surface_id: u64, pane: []const u8) void {
        for (&self.evicted_trace) |*t| {
            if (t.surface_id == surface_id and std.mem.eql(u8, t.paneName(), pane)) t.* = .{};
        }
    }

    /// 그 surface 에서 **밀려 지금 없는** pane 수 — 사이드바 고지 «+N 밀림» 의 값. 자취 상한을 넘긴 것은 세지 못한다(과소 보고).
    pub fn evictedFor(self: *const Table, surface_id: u64) usize {
        var n: usize = 0;
        for (&self.evicted_trace) |*t| {
            if (t.surface_id == surface_id and t.pane_len != 0) n += 1;
        }
        return n;
    }

    pub fn find(self: *const Table, surface_id: u64, pane: []const u8) ?*const Entry {
        for (&self.entries) |*e| {
            if (e.used == 0 or e.surface_id != surface_id) continue;
            if (std.mem.eql(u8, e.paneName(), pane)) return e;
        }
        return null;
    }

    pub fn findMut(self: *Table, surface_id: u64, pane: []const u8) ?*Entry {
        for (&self.entries) |*e| {
            if (e.used == 0 or e.surface_id != surface_id) continue;
            if (std.mem.eql(u8, e.paneName(), pane)) return e;
        }
        return null;
    }

    /// 그 surface 의 pane 슬롯들(빈 자리 제외). 순서는 자리 순 — 정렬은 호출자가 한다.
    pub const Iterator = struct {
        table: *Table,
        surface_id: u64,
        i: usize = 0,
        pub fn next(self: *Iterator) ?*Entry {
            while (self.i < max_panes) : (self.i += 1) {
                const e = &self.table.entries[self.i];
                if (e.used != 0 and e.surface_id == self.surface_id) {
                    self.i += 1;
                    return e;
                }
            }
            return null;
        }
    };

    pub fn forSurface(self: *Table, surface_id: u64) Iterator {
        return .{ .table = self, .surface_id = surface_id };
    }

    /// 그 surface 에서 **가장 최근에 이벤트를 받은** pane(없으면 null) — 대화 줄·집계의 동률 해소.
    pub fn latestFor(self: *Table, surface_id: u64) ?*Entry {
        var best: ?*Entry = null;
        var it = self.forSurface(surface_id);
        while (it.next()) |e| {
            if (best == null or e.last_event_ms > best.?.last_event_ms or
                (e.last_event_ms == best.?.last_event_ms and e.used > best.?.used)) best = e;
        }
        return best;
    }

    pub fn countFor(self: *Table, surface_id: u64) usize {
        var n: usize = 0;
        var it = self.forSurface(surface_id);
        while (it.next()) |_| n += 1;
        return n;
    }

    /// 그 surface 의 슬롯을 전부 비운다 — Term 이 죽거나 원격이 아니게 될 때. 밀림으로 세지 않는다(버린 것이 아니라 끝난 것).
    pub fn dropSurface(self: *Table, surface_id: u64) void {
        for (&self.entries) |*e| {
            if (e.used != 0 and e.surface_id == surface_id) e.* = .{};
        }
        for (&self.evicted_trace) |*t| {
            if (t.surface_id == surface_id) t.* = .{};
        }
    }

    fn victim(self: *Table) *Entry {
        var best: *Entry = &self.entries[0];
        for (&self.entries) |*e| {
            if (e.used == 0) return e;
            if (e.used < best.used) best = e;
        }
        return best;
    }
};

const testing = std.testing;

test "pane 테이블: 같은 (surface, pane) 은 같은 슬롯이고, 다른 surface 의 같은 pane 은 다른 슬롯이다" {
    var t: Table = .{};
    const a = t.slotFor(1, "%0", 10).?;
    a.slot.state = .running;
    try testing.expectEqual(@as(usize, 1), t.countFor(1));
    // 다시 찾으면 같은 자리 — 상태가 남아 있다.
    try testing.expectEqual(session_model.HookSlot, @TypeOf(t.slotFor(1, "%0", 20).?.slot));
    try testing.expect(t.slotFor(1, "%0", 20).?.slot.state == .running);
    try testing.expectEqual(@as(usize, 1), t.countFor(1));
    // 다른 surface 의 `%0` 은 다른 서버의 pane 이다.
    const b = t.slotFor(2, "%0", 30).?;
    try testing.expect(b.slot.state == .unknown);
    try testing.expectEqual(@as(usize, 1), t.countFor(2));
    // 빈 pane 이름은 거절 — 그 이벤트는 Term 인라인 슬롯 몫이다.
    try testing.expect(t.slotFor(1, "", 40) == null);
}

test "pane 테이블: 상한을 넘기면 가장 오래 안 쓴 것부터 밀고 그 사실을 센다" {
    var t: Table = .{};
    var i: usize = 0;
    var buf: [8]u8 = undefined;
    while (i < max_panes) : (i += 1) {
        const name = std.fmt.bufPrint(&buf, "%{d}", .{i}) catch unreachable;
        _ = t.slotFor(1, name, i).?;
    }
    try testing.expectEqual(@as(u32, 0), t.evicted);
    // `%0` 을 다시 써서 «최근» 으로 올린 뒤 하나 더 넣으면 `%1` 이 밀린다.
    _ = t.slotFor(1, "%0", 100).?;
    _ = t.slotFor(1, "%new", 101).?;
    try testing.expectEqual(@as(u32, 1), t.evicted);
    try testing.expect(t.find(1, "%1") == null);
    try testing.expect(t.find(1, "%0") != null);
    try testing.expect(t.find(1, "%new") != null);
}

test "pane 테이블: 밀린 자취는 surface 별로 세고, 그 pane 이 돌아오거나 surface 를 버리면 지운다 (RA7 조각 5)" {
    var t: Table = .{};
    var i: usize = 0;
    var buf: [8]u8 = undefined;
    // surface 1 이 15 칸, surface 2 가 1 칸 — 꽉 찼다.
    while (i < max_panes - 1) : (i += 1) {
        const name = std.fmt.bufPrint(&buf, "%{d}", .{i}) catch unreachable;
        _ = t.slotFor(1, name, i).?;
    }
    _ = t.slotFor(2, "%0", 50).?;
    try testing.expectEqual(@as(usize, 0), t.evictedFor(1));
    try testing.expectEqual(@as(usize, 0), t.evictedFor(2));
    // surface 2 의 신참이 surface 1 의 `%0`(가장 오래됨) 을 민다 — 자취는 **밀린 쪽**(surface 1) 에 남는다.
    _ = t.slotFor(2, "%9", 100).?;
    try testing.expectEqual(@as(usize, 1), t.evictedFor(1));
    try testing.expectEqual(@as(usize, 0), t.evictedFor(2));
    // 하나 더 밀리면 2.
    _ = t.slotFor(2, "%10", 101).?;
    try testing.expectEqual(@as(usize, 2), t.evictedFor(1));
    // 밀렸던 `%0` 이 돌아오면(그 자리에 또 누군가 밀린다) — `%0` 자취는 지워지고 새로 밀린 `%2` 가 남아 여전히 2.
    _ = t.slotFor(1, "%0", 102).?;
    try testing.expectEqual(@as(usize, 2), t.evictedFor(1));
    try testing.expect(t.find(1, "%0") != null);
    try testing.expect(t.find(1, "%2") == null);
    // surface 를 버리면 자취도 사라진다.
    t.dropSurface(1);
    try testing.expectEqual(@as(usize, 0), t.evictedFor(1));
    // 자취 상한: max_evicted 를 넘기면 오래된 자취부터 잊는다(과소 보고) — 값이 상한을 넘지 않는다.
    var t2: Table = .{};
    i = 0;
    while (i < max_panes * 3) : (i += 1) {
        const name = std.fmt.bufPrint(&buf, "%{d}", .{i}) catch unreachable;
        _ = t2.slotFor(7, name, i).?;
    }
    try testing.expect(t2.evictedFor(7) <= max_evicted);
    try testing.expectEqual(@as(usize, max_evicted), t2.evictedFor(7));
}

test "pane 테이블: 가장 최근 pane 은 마지막 이벤트 시각으로 고르고, surface 를 비우면 밀림으로 세지 않는다" {
    var t: Table = .{};
    _ = t.slotFor(7, "%3", 10).?;
    _ = t.slotFor(7, "%5", 50).?;
    _ = t.slotFor(7, "%3", 20).?; // %3 이 다시 왔지만 %5 가 더 최근이다
    try testing.expectEqualStrings("%5", t.latestFor(7).?.paneName());
    _ = t.slotFor(7, "%3", 60).?;
    try testing.expectEqualStrings("%3", t.latestFor(7).?.paneName());
    try testing.expect(t.latestFor(8) == null);
    t.dropSurface(7);
    try testing.expectEqual(@as(usize, 0), t.countFor(7));
    try testing.expectEqual(@as(u32, 0), t.evicted);
}
