//! executeScript 대용량 결과의 순수 전송 회계(5f-5b 첫 슬라이스).
//! 실제 소켓/ABI는 L4가 소유하고, 이 모듈은 논리 결과 바이트 예약(`ByteBudget`)과
//! progressive 전송 상태(`BrowserResultTransfer`)만 순수하게 검증한다.

const std = @import("std");

pub const BudgetError = error{ ResourceBusy, Underflow };

/// 실행 중 또는 transfer가 보유한 논리 결과 바이트 예약. L4(`app_host_abi`)가 실행 시 `reserve`,
/// transfer 시작 시 초과분만 `release`(beginTransfer)로 직접 조절한다.
pub const ByteBudget = struct {
    limit: usize,
    used: usize = 0,

    pub fn init(limit: usize) ByteBudget {
        return .{ .limit = limit };
    }

    pub fn reserve(self: *ByteBudget, amount: usize) BudgetError!void {
        if (amount > self.limit -| self.used) return error.ResourceBusy;
        self.used += amount;
    }

    pub fn release(self: *ByteBudget, amount: usize) BudgetError!void {
        if (amount > self.used) return error.Underflow;
        self.used -= amount;
    }

    pub fn usedBytes(self: *const ByteBudget) usize {
        return self.used;
    }

    pub fn limitBytes(self: *const ByteBudget) usize {
        return self.limit;
    }
};

pub const TransferError = error{ InvalidResultId, InvalidDeadline, InvalidCommit };

/// ABI나 socket을 모르는 순수 progressive-result 상태. `plan`은 관찰만 하고, 실제 outbound push가 성공한 뒤
/// `commit`해야 offset/seq와 무진행 deadline이 함께 전진한다. Full/OOM 재시도에서 chunk 중복·누락이 생기거나
/// 진전 없이 deadline만 늘어나는 것을 막는 경계다.
pub const BrowserResultTransfer = struct {
    result_id: i64,
    total_bytes: usize,
    offset: usize = 0,
    seq: usize = 0,
    deadline_ns: i128,
    paused: bool = false,
    planned: ?Slice = null,

    pub const Pressure = struct {
        should_pause: bool,
        should_resume: bool,
    };

    pub const Slice = struct { offset: usize, len: usize, seq: usize };
    pub const Plan = union(enum) { ready: Slice, paused, complete, expired };

    pub fn init(result_id: i64, total_bytes: usize, deadline_ns: i128) TransferError!BrowserResultTransfer {
        if (result_id < 0) return error.InvalidResultId;
        if (deadline_ns <= 0) return error.InvalidDeadline;
        return .{ .result_id = result_id, .total_bytes = total_bytes, .deadline_ns = deadline_ns };
    }

    pub fn plan(self: *BrowserResultTransfer, now_ns: i128, max_chunk_bytes: usize, pressure: Pressure) Plan {
        if (now_ns >= self.deadline_ns) return .expired;
        // 마지막 raw byte가 이미 enqueue됐으면 일반 chunk watermark보다 terminal carve-out을 우선한다.
        // 여기서 paused를 먼저 보면 unrelated queued bytes 때문에 final이 굶어 carve-out을 둔 목적이 사라진다.
        if (self.offset == self.total_bytes) return .complete;
        if (self.paused) {
            if (!pressure.should_resume) return .paused;
            self.paused = false;
        } else if (pressure.should_pause) {
            self.paused = true;
            return .paused;
        }
        if (max_chunk_bytes == 0) return .paused;
        if (self.planned) |slice| return .{ .ready = slice };
        const slice: Slice = .{
            .offset = self.offset,
            .len = @min(max_chunk_bytes, self.total_bytes - self.offset),
            .seq = self.seq,
        };
        self.planned = slice;
        return .{ .ready = slice };
    }

    pub fn commit(self: *BrowserResultTransfer, slice: Slice, next_deadline_ns: i128) TransferError!void {
        const planned = self.planned orelse return error.InvalidCommit;
        if (!std.meta.eql(planned, slice)) return error.InvalidCommit;
        if (slice.len > self.total_bytes - self.offset) return error.InvalidCommit;
        if (next_deadline_ns <= 0) return error.InvalidDeadline;
        self.offset += slice.len;
        self.seq += 1;
        self.deadline_ns = next_deadline_ns;
        self.planned = null;
    }
};

/// 여러 transfer를 tick마다 한 칸씩 순환시키는 작은 cursor. 실제 pump가 한 tick에 이 중 하나만 선택한다.
pub const RoundRobinCursor = struct {
    next: usize = 0,

    pub fn take(self: *RoundRobinCursor, len: usize) ?usize {
        if (len == 0) {
            self.next = 0;
            return null;
        }
        const selected = self.next % len;
        self.next = (selected + 1) % len;
        return selected;
    }
};

test "ByteBudget: 정확한 reserve, 상한 초과 busy, release로 used 복원" {
    var budget = ByteBudget.init(10);
    try budget.reserve(10);
    try std.testing.expectError(error.ResourceBusy, budget.reserve(1));
    try std.testing.expectEqual(@as(usize, 10), budget.usedBytes());
    try std.testing.expectError(error.Underflow, budget.release(11)); // 보유 초과 release
    try budget.release(7); // transfer 초과분 반환 시나리오(app_host_abi beginTransfer)
    try std.testing.expectEqual(@as(usize, 3), budget.usedBytes());
    try budget.reserve(7); // 여유 복원 확인
    try std.testing.expectEqual(@as(usize, 10), budget.usedBytes());
}

test "BrowserResultTransfer: push 성공 commit 전에는 offset과 seq가 바뀌지 않는다" {
    var transfer = try BrowserResultTransfer.init(7, 9, 100);
    const pressure: BrowserResultTransfer.Pressure = .{ .should_pause = false, .should_resume = true };
    const first = (transfer.plan(1, 4, pressure)).ready;
    try std.testing.expectEqual(@as(usize, 0), first.offset);
    try std.testing.expectEqual(@as(usize, 0), first.seq);
    const retry = (transfer.plan(2, 4, pressure)).ready;
    try std.testing.expectEqualDeep(first, retry);
    try std.testing.expectError(error.InvalidCommit, transfer.commit(.{ .offset = 0, .len = 3, .seq = 0 }, 101));
    try std.testing.expectError(error.InvalidDeadline, transfer.commit(first, 0));
    try transfer.commit(first, 101);
    const second = (transfer.plan(3, 4, pressure)).ready;
    try std.testing.expectEqual(@as(usize, 4), second.offset);
    try std.testing.expectEqual(@as(usize, 1), second.seq);
    try std.testing.expectError(error.InvalidCommit, transfer.commit(first, 102));
}

test "BrowserResultTransfer: 성공한 chunk만 무진행 deadline을 연장한다" {
    var transfer = try BrowserResultTransfer.init(8, 8, 10);
    const pressure: BrowserResultTransfer.Pressure = .{ .should_pause = false, .should_resume = true };
    const first = (transfer.plan(9, 4, pressure)).ready;

    // enqueue 실패를 가정해 commit하지 않으면 원래 deadline에서 만료된다.
    try std.testing.expect(transfer.plan(10, 4, pressure) == .expired);

    // 같은 slice를 성공적으로 재시도해 commit하면 새 무진행 구간이 열린다.
    try transfer.commit(first, 20);
    try std.testing.expect(transfer.plan(19, 4, pressure) == .ready);
    try std.testing.expect(transfer.plan(20, 4, pressure) == .expired);
}

test "BrowserResultTransfer: high에서 멈추고 low 이하에서만 재개하며 deadline은 우선한다" {
    var transfer = try BrowserResultTransfer.init(1, 8, 10);
    try std.testing.expect(transfer.plan(1, 4, .{ .should_pause = true, .should_resume = false }) == .paused);
    try std.testing.expect(transfer.plan(2, 4, .{ .should_pause = false, .should_resume = false }) == .paused);
    try std.testing.expect(transfer.plan(3, 4, .{ .should_pause = false, .should_resume = true }) == .ready);
    try std.testing.expect(transfer.plan(10, 4, .{ .should_pause = false, .should_resume = true }) == .expired);
}

test "BrowserResultTransfer: 마지막 slice와 round-robin 선택은 bounded다" {
    var transfer = try BrowserResultTransfer.init(2, 5, 100);
    const pressure: BrowserResultTransfer.Pressure = .{ .should_pause = false, .should_resume = true };
    const first = (transfer.plan(1, 4, pressure)).ready;
    try transfer.commit(first, 101);
    const last = (transfer.plan(2, 4, pressure)).ready;
    try std.testing.expectEqual(@as(usize, 1), last.len);
    try transfer.commit(last, 102);
    try std.testing.expect(transfer.plan(3, 4, .{ .should_pause = true, .should_resume = false }) == .complete);

    var cursor: RoundRobinCursor = .{};
    try std.testing.expectEqual(@as(?usize, 0), cursor.take(3));
    try std.testing.expectEqual(@as(?usize, 1), cursor.take(3));
    try std.testing.expectEqual(@as(?usize, 2), cursor.take(3));
    try std.testing.expectEqual(@as(?usize, 0), cursor.take(3));
    try std.testing.expectEqual(@as(?usize, null), cursor.take(0));
}
