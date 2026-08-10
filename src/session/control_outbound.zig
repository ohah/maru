//! control_outbound — per-connection outbound 프레임 큐(L2 순수, 헤드리스). Track C 5f-0b.
//! 단일 출처: docs/control-plane-browser-session.md §9.5.1(통합 outbound 큐: 응답+이벤트)·§9.5.6(purge API·응답 포화 정책)·
//! §8.5(revoke 시 outbound 잔여 프레임 즉시 폐기 규범).
//!
//! **역할**: 연결당 outbound 프레임(응답 | 이벤트 notification)의 **bounded FIFO**. mechanism만 소유 —
//! coalesce(상태 이벤트 최신만 유지)·purge(revoke/surface-close 시 잔여 폐기)·bounded(`error.Full`). **정책**
//! (Full 시 응답=연결 종료 vs 이벤트=drop/subscriber-lagged)은 push 호출처(L4·§9.5.6)가 결정한다.
//!
//! **왜 통합 큐(§9.5.1)**: 응답과 이벤트가 한 큐를 공유해야 연결 스레드가 **하나의 write 경로**로 둘 다 내보낸다 —
//! 옛 accept 스레드가 `waitResolved` 블로킹으로 이벤트 write를 못 끼우던 문제(3차 감사 A2) 해소. 스레드/소켓/connection
//! registry는 L4(5f-0b-2)가 소유하고, 이 코어는 그 위에 얹히는 순수 자료구조다.
//!
//! **포화 정책 근거(§9.5.6②)**: 호출처는 큐 `max`를 **per-conn in-flight 상한 이상**으로 잡아 **응답은 절대 drop
//! 불필요**하게 한다(응답은 coalesce/drop 불가·메인 무블록). 방어적으로 Full이 나면 응답 push는 연결 종료로, 이벤트
//! push는 drop/`subscriber-lagged`로 접는다 — 큐는 `error.Full`만 알리고 판단은 호출처.
//!
//! **L2 순수**: std만 import(OS 타입·소켓·스레드 0). `bytes`는 gpa 소유 — push가 소유 인수, pop/purge/deinit이 free.

const std = @import("std");

/// outbound 프레임 하나(응답 or 이벤트 notification, 개행 제외 — writer가 write 시 `\n` 추가).
pub const Frame = struct {
    /// gpa 소유 프레임 바이트. push가 소유 인수, pop 반환분은 호출자가 write 후 free, purge/deinit이 free.
    bytes: []u8,
    /// coalesce 키(§9.5.2). null=coalesce 안 함(응답·이산 이벤트 dialog/crashed). 같은 키가 큐에 있으면 push가
    /// 그 프레임을 **replace**(옛 bytes free, 위치 유지=기아 방지) — 상태 이벤트(navigated·loadState) "최신만".
    coalesce_key: ?u64 = null,
    purge_key: PurgeKey = .none,
    /// 일반 payload가 final/error용 비상 여유를 먹지 못하게 admission class를 분리한다.
    /// terminal은 executeScript final/error처럼 진행 중 transfer를 끝내는 작은 프레임에만 쓴다.
    class: FrameClass = .general,
};

pub const FrameClass = enum { general, terminal };

pub const QueueAccounting = struct {
    total_bytes: usize = 0,
    terminal_bytes: usize = 0,
    total_frames: usize = 0,
    terminal_frames: usize = 0,

    pub fn generalBytes(self: QueueAccounting) usize {
        return self.total_bytes - self.terminal_bytes;
    }

    pub fn generalFrames(self: QueueAccounting) usize {
        return self.total_frames - self.terminal_frames;
    }
};

pub const PurgeKey = union(enum) {
    none,
    surface_event: u64,
    browser_request: u64,
    browser_result: i64,

    pub fn eql(a: PurgeKey, b: PurgeKey) bool {
        return std.meta.eql(a, b);
    }
};

pub const PushError = error{ Full, InvalidFrame, OutOfMemory };

/// 연결당 bounded outbound FIFO. `ControlRequestQueue`/`BrowserOpQueue` 선례(ArrayList + orderedRemove(0)).
pub const OutboundQueue = struct {
    items: std.ArrayList(Frame) = .empty,
    /// 최대 프레임 수(bounded). 호출처가 per-conn in-flight 상한 이상으로 준다(§9.5.6②).
    max: usize,
    max_wire_bytes: usize,
    queued_wire_bytes: usize = 0,

    pub fn init(max: usize) OutboundQueue {
        return .{ .max = max, .max_wire_bytes = std.math.maxInt(usize) };
    }

    pub fn initWithByteLimit(max: usize, max_wire_bytes: usize) OutboundQueue {
        return .{ .max = max, .max_wire_bytes = max_wire_bytes };
    }

    pub fn deinit(self: *OutboundQueue, gpa: std.mem.Allocator) void {
        for (self.items.items) |f| gpa.free(f.bytes);
        self.items.deinit(gpa);
    }

    /// 프레임 push. `coalesce_key`가 있고 같은 키가 큐에 있으면 그 프레임 bytes를 **replace**(옛 free, 위치 유지)하고
    /// 성공(큐 크기 불변). 아니면 append — `max` 도달 시 `error.Full`(호출처가 정책: 응답=연결종료·이벤트=drop).
    /// 성공 시 `frame.bytes` 소유권을 큐가 인수한다. **Full/OOM 시 frame.bytes 소유권은 호출자에 남는다**(호출자 free).
    pub fn push(self: *OutboundQueue, gpa: std.mem.Allocator, frame: Frame) PushError!void {
        if (frame.class == .terminal and frame.coalesce_key != null) return error.InvalidFrame;
        if (frame.coalesce_key) |k| {
            for (self.items.items) |*f| {
                if (f.coalesce_key != null and f.coalesce_key.? == k) {
                    const old_wire = wireBytes(f.bytes);
                    const new_wire = wireBytes(frame.bytes);
                    if (new_wire > self.max_wire_bytes -| (self.queued_wire_bytes - old_wire)) return error.Full;
                    gpa.free(f.bytes);
                    f.bytes = frame.bytes;
                    f.purge_key = frame.purge_key;
                    f.class = frame.class;
                    self.queued_wire_bytes = self.queued_wire_bytes - old_wire + new_wire;
                    return;
                }
            }
        }
        if (self.items.items.len >= self.max) return error.Full;
        const new_wire = wireBytes(frame.bytes);
        if (new_wire > self.max_wire_bytes -| self.queued_wire_bytes) return error.Full;
        try self.items.append(gpa, frame);
        self.queued_wire_bytes += new_wire;
    }

    /// FIFO pop(없으면 null). 반환 프레임의 `bytes` 소유권은 호출자로 이전(socket write 후 free).
    pub fn pop(self: *OutboundQueue) ?Frame {
        if (self.items.items.len == 0) return null;
        const frame = self.items.orderedRemove(0);
        self.queued_wire_bytes -= wireBytes(frame.bytes);
        return frame;
    }

    /// `tag` 매칭 프레임을 전부 폐기(§8.5 revoke/surface-close — 이미 직렬화돼 쌓인 잔여를 즉시 버림). bytes free.
    /// 폐기 개수 반환. **`tag==0`(응답)은 절대 안 지움**(요청→응답 계약 보호). 남은 프레임의 FIFO 순서 보존(orderedRemove).
    pub fn purge(self: *OutboundQueue, gpa: std.mem.Allocator, key: PurgeKey) usize {
        if (key == .none) return 0;
        var removed: usize = 0;
        var i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            if (self.items.items[i].purge_key.eql(key)) {
                self.queued_wire_bytes -= wireBytes(self.items.items[i].bytes);
                gpa.free(self.items.items[i].bytes);
                _ = self.items.orderedRemove(i);
                removed += 1;
            }
        }
        return removed;
    }

    /// 보안 취소/연결 abort용 전량 폐기. writer가 이미 소유한 프레임은 이 큐 밖이므로 호출자가 별도로
    /// socket shutdown 뒤 writeComplete하게 둔다.
    pub fn purgeAll(self: *OutboundQueue, gpa: std.mem.Allocator) usize {
        const removed = self.items.items.len;
        for (self.items.items) |frame| gpa.free(frame.bytes);
        self.items.clearRetainingCapacity();
        self.queued_wire_bytes = 0;
        return removed;
    }

    pub fn len(self: *const OutboundQueue) usize {
        return self.items.items.len;
    }

    /// push 전 정책 판단용(§9.5.6 — 호출처가 응답이면 Full 임박 시 연결 종료 선제 판단).
    pub fn isFull(self: *const OutboundQueue) bool {
        return self.items.items.len >= self.max;
    }

    pub fn queuedWireBytes(self: *const OutboundQueue) usize {
        return self.queued_wire_bytes;
    }

    pub fn prospectiveQueuedWireBytes(self: *const OutboundQueue, frame: Frame) usize {
        const new_wire = wireBytes(frame.bytes);
        if (frame.coalesce_key) |k| {
            for (self.items.items) |f| {
                if (f.coalesce_key != null and f.coalesce_key.? == k) {
                    return self.queued_wire_bytes - wireBytes(f.bytes) + new_wire;
                }
            }
        }
        return self.queued_wire_bytes + new_wire;
    }

    pub fn accounting(self: *const OutboundQueue) QueueAccounting {
        var result: QueueAccounting = .{};
        for (self.items.items) |frame| {
            const wire = wireBytes(frame.bytes);
            result.total_bytes += wire;
            result.total_frames += 1;
            if (frame.class == .terminal) {
                result.terminal_bytes += wire;
                result.terminal_frames += 1;
            }
        }
        std.debug.assert(result.total_bytes == self.queued_wire_bytes);
        return result;
    }

    pub fn prospectiveAccounting(self: *const OutboundQueue, frame: Frame) QueueAccounting {
        var result = self.accounting();
        const new_wire = wireBytes(frame.bytes);
        if (frame.coalesce_key) |key| {
            for (self.items.items) |old| {
                if (old.coalesce_key != null and old.coalesce_key.? == key) {
                    const old_wire = wireBytes(old.bytes);
                    result.total_bytes = result.total_bytes - old_wire + new_wire;
                    if (old.class == .terminal) {
                        result.terminal_bytes -= old_wire;
                        result.terminal_frames -= 1;
                    }
                    if (frame.class == .terminal) {
                        result.terminal_bytes += new_wire;
                        result.terminal_frames += 1;
                    }
                    return result;
                }
            }
        }
        result.total_bytes += new_wire;
        result.total_frames += 1;
        if (frame.class == .terminal) {
            result.terminal_bytes += new_wire;
            result.terminal_frames += 1;
        }
        return result;
    }
};

pub fn wireBytes(bytes: []const u8) usize {
    return bytes.len + 1;
}

// ── 테스트(헤드리스, 순수) ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

/// 테스트 헬퍼: gpa-dupe한 프레임(push가 소유 인수하므로 매 프레임 새 할당).
fn mkFrame(gpa: std.mem.Allocator, s: []const u8, key: ?u64, purge_key: PurgeKey) !Frame {
    return .{ .bytes = try gpa.dupe(u8, s), .coalesce_key = key, .purge_key = purge_key };
}

test "OutboundQueue: FIFO push/pop 순서" {
    var q = OutboundQueue.init(4);
    defer q.deinit(testing.allocator);
    try q.push(testing.allocator, try mkFrame(testing.allocator, "a", null, .none));
    try q.push(testing.allocator, try mkFrame(testing.allocator, "b", null, .none));
    try testing.expectEqual(@as(usize, 2), q.len());
    const f1 = q.pop().?;
    defer testing.allocator.free(f1.bytes);
    try testing.expectEqualStrings("a", f1.bytes);
    const f2 = q.pop().?;
    defer testing.allocator.free(f2.bytes);
    try testing.expectEqualStrings("b", f2.bytes);
    try testing.expect(q.pop() == null);
}

test "OutboundQueue: bounded → error.Full (호출자 소유권 유지)" {
    var q = OutboundQueue.init(2);
    defer q.deinit(testing.allocator);
    try q.push(testing.allocator, try mkFrame(testing.allocator, "1", null, .none));
    try q.push(testing.allocator, try mkFrame(testing.allocator, "2", null, .none));
    // 세 번째는 Full — frame.bytes 소유권이 호출자에 남으므로 여기서 free(누수 방지).
    const overflow = try mkFrame(testing.allocator, "3", null, .none);
    try testing.expectError(error.Full, q.push(testing.allocator, overflow));
    testing.allocator.free(overflow.bytes);
    try testing.expectEqual(@as(usize, 2), q.len());
}

test "OutboundQueue: coalesce_key 같으면 replace(최신·위치 유지·크기 불변)" {
    var q = OutboundQueue.init(4);
    defer q.deinit(testing.allocator);
    try q.push(testing.allocator, try mkFrame(testing.allocator, "url=a", 100, .{ .surface_event = 7 })); // 위치0, key 100
    try q.push(testing.allocator, try mkFrame(testing.allocator, "dialog", null, .{ .surface_event = 7 })); // 위치1, coalesce 안 함
    try q.push(testing.allocator, try mkFrame(testing.allocator, "url=b", 100, .{ .surface_event = 7 })); // key 100 존재 → 위치0 replace
    try testing.expectEqual(@as(usize, 2), q.len()); // 크기 불변(3개 push했지만 coalesce)
    // 위치0=최신 url=b(위치 유지), 위치1=dialog.
    const f0 = q.pop().?;
    defer testing.allocator.free(f0.bytes);
    try testing.expectEqualStrings("url=b", f0.bytes);
    const f1 = q.pop().?;
    defer testing.allocator.free(f1.bytes);
    try testing.expectEqualStrings("dialog", f1.bytes);
}

test "OutboundQueue: coalesce_key null은 coalesce 안 함(별개 프레임)" {
    var q = OutboundQueue.init(4);
    defer q.deinit(testing.allocator);
    try q.push(testing.allocator, try mkFrame(testing.allocator, "x", null, .none));
    try q.push(testing.allocator, try mkFrame(testing.allocator, "y", null, .none));
    try testing.expectEqual(@as(usize, 2), q.len()); // 각각 남음
}

test "OutboundQueue: purge(tag)는 매칭 폐기·순서 보존·tag 0 보호" {
    var q = OutboundQueue.init(8);
    defer q.deinit(testing.allocator);
    try q.push(testing.allocator, try mkFrame(testing.allocator, "resp", null, .none));
    try q.push(testing.allocator, try mkFrame(testing.allocator, "ev-s100-a", null, .{ .surface_event = 100 }));
    try q.push(testing.allocator, try mkFrame(testing.allocator, "ev-s200", null, .{ .surface_event = 200 }));
    try q.push(testing.allocator, try mkFrame(testing.allocator, "ev-s100-b", null, .{ .surface_event = 100 }));
    // surface 100 revoke/close → tag 100 두 개 폐기, 나머지 순서 보존.
    try testing.expectEqual(@as(usize, 2), q.purge(testing.allocator, .{ .surface_event = 100 }));
    try testing.expectEqual(@as(usize, 2), q.len());
    const f0 = q.pop().?;
    defer testing.allocator.free(f0.bytes);
    try testing.expectEqualStrings("resp", f0.bytes); // 응답 보존(tag 0)
    const f1 = q.pop().?;
    defer testing.allocator.free(f1.bytes);
    try testing.expectEqualStrings("ev-s200", f1.bytes); // 순서 보존
    // tag 0 purge는 무동작(응답 보호).
    try testing.expectEqual(@as(usize, 0), q.purge(testing.allocator, .none));
}

test "OutboundQueue: isFull·deinit 잔여 free(누수 없음)" {
    var q = OutboundQueue.init(2);
    defer q.deinit(testing.allocator); // 잔여 2개를 deinit이 free(testing.allocator가 누수 검출)
    try testing.expect(!q.isFull());
    try q.push(testing.allocator, try mkFrame(testing.allocator, "a", null, .{ .surface_event = 5 }));
    try q.push(testing.allocator, try mkFrame(testing.allocator, "b", 9, .{ .surface_event = 5 }));
    try testing.expect(q.isFull());
}

test "OutboundQueue: wire byte 상한은 newline 포함, pop·purge·replace에서 정확히 회수" {
    var q = OutboundQueue.initWithByteLimit(8, 8);
    defer q.deinit(testing.allocator);
    try q.push(testing.allocator, try mkFrame(testing.allocator, "abc", 1, .{ .browser_result = 7 })); // 4 bytes
    try testing.expectEqual(@as(usize, 4), q.queuedWireBytes());
    try q.push(testing.allocator, try mkFrame(testing.allocator, "x", 1, .{ .browser_result = 7 })); // replace=2
    try testing.expectEqual(@as(usize, 2), q.queuedWireBytes());
    try q.push(testing.allocator, try mkFrame(testing.allocator, "12345", null, .none)); // +6 = exact 8
    const overflow = try mkFrame(testing.allocator, "z", null, .none);
    try testing.expectError(error.Full, q.push(testing.allocator, overflow));
    testing.allocator.free(overflow.bytes);
    const first = q.pop().?;
    testing.allocator.free(first.bytes);
    try testing.expectEqual(@as(usize, 6), q.queuedWireBytes());
}

test "OutboundQueue: typed purge key는 같은 숫자의 surface/result를 격리" {
    var q = OutboundQueue.init(4);
    defer q.deinit(testing.allocator);
    try q.push(testing.allocator, try mkFrame(testing.allocator, "event", null, .{ .surface_event = 7 }));
    try q.push(testing.allocator, try mkFrame(testing.allocator, "result", null, .{ .browser_result = 7 }));
    try testing.expectEqual(@as(usize, 1), q.purge(testing.allocator, .{ .surface_event = 7 }));
    const remaining = q.pop().?;
    defer testing.allocator.free(remaining.bytes);
    try testing.expectEqualStrings("result", remaining.bytes);
}

test "OutboundQueue: terminal frame은 lossless라 coalesce를 거부한다" {
    var q = OutboundQueue.init(4);
    defer q.deinit(testing.allocator);
    const frame = try mkFrame(testing.allocator, "final", 1, .{ .browser_result = 7 });
    var terminal = frame;
    terminal.class = .terminal;
    try testing.expectError(error.InvalidFrame, q.push(testing.allocator, terminal));
    testing.allocator.free(terminal.bytes);
}
