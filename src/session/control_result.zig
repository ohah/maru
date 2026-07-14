//! executeScript 대용량 결과의 순수 전송 회계(5f-5b 첫 슬라이스).
//! 실제 소켓/ABI는 L4가 소유하고, 이 모듈은 실행 예약과 queued+writer-owned 바이트의
//! 이중 청구를 막는 상태만 검증한다.

const std = @import("std");

pub const BudgetError = error{ ResourceBusy, Overflow, Underflow };

/// 실행 또는 transfer가 보유한 논리 결과 바이트 예약. 예약은 실행 전 선점하고
/// transfer로 소유권을 넘길 때 release하지 않는다.
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

    pub fn transfer(self: *ByteBudget, from: *Reservation, to: *Reservation) BudgetError!void {
        if (from.budget != self or to.budget != self) return error.Underflow;
        if (!from.active or from.released or to.active or to.released) return error.Underflow;
        to.amount = from.amount;
        to.active = true;
        to.released = false;
        from.active = false;
        from.released = true;
    }

    pub fn usedBytes(self: *const ByteBudget) usize {
        return self.used;
    }

    pub fn limitBytes(self: *const ByteBudget) usize {
        return self.limit;
    }
};

pub const Reservation = struct {
    budget: *ByteBudget,
    amount: usize,
    active: bool = true,
    released: bool = false,

    pub fn release(self: *Reservation) BudgetError!void {
        if (!self.active or self.released) return error.Underflow;
        try self.budget.release(self.amount);
        self.released = true;
    }

    pub fn shrinkTo(self: *Reservation, actual: usize) BudgetError!void {
        if (!self.active or self.released or actual > self.amount) return error.Underflow;
        const delta = self.amount - actual;
        try self.budget.release(delta);
        self.amount = actual;
    }
};

pub const OutboundAccounting = struct {
    limit: usize,
    queued: usize = 0,
    writer_owned: usize = 0,

    pub fn init(limit: usize) OutboundAccounting {
        return .{ .limit = limit };
    }

    pub fn enqueue(self: *OutboundAccounting, wire_bytes_with_newline: usize) BudgetError!void {
        try self.add(wire_bytes_with_newline);
        self.queued += wire_bytes_with_newline;
    }

    /// 큐에서 writer로 넘어가도 회계에서 제거하지 않는다.
    pub fn beginWrite(self: *OutboundAccounting, wire_bytes_with_newline: usize) BudgetError!void {
        if (wire_bytes_with_newline > self.queued) return error.Underflow;
        self.queued -= wire_bytes_with_newline;
        self.writer_owned += wire_bytes_with_newline;
    }

    pub fn writeComplete(self: *OutboundAccounting, wire_bytes_with_newline: usize) BudgetError!void {
        if (wire_bytes_with_newline > self.writer_owned) return error.Underflow;
        self.writer_owned -= wire_bytes_with_newline;
        self.usedRelease(wire_bytes_with_newline);
    }

    pub fn purgeQueued(self: *OutboundAccounting, wire_bytes: usize) BudgetError!void {
        if (wire_bytes > self.queued) return error.Underflow;
        self.queued -= wire_bytes;
        self.usedRelease(wire_bytes);
    }

    pub fn total(self: *const OutboundAccounting) usize {
        return self.queued + self.writer_owned;
    }

    pub fn highWatermark(self: *const OutboundAccounting) usize {
        return self.limit - self.limit / 4;
    }

    pub fn lowWatermark(self: *const OutboundAccounting) usize {
        return self.limit / 2;
    }

    pub fn shouldPause(self: *const OutboundAccounting) bool {
        return self.total() >= self.highWatermark();
    }

    pub fn shouldResume(self: *const OutboundAccounting) bool {
        return self.total() <= self.lowWatermark();
    }

    fn add(self: *OutboundAccounting, amount: usize) BudgetError!void {
        if (amount > self.limit -| self.total()) return error.ResourceBusy;
    }

    fn usedRelease(self: *OutboundAccounting, amount: usize) void {
        _ = self;
        _ = amount;
    }
};

test "ByteBudget: exact reserve, busy, release and transfer" {
    var budget = ByteBudget.init(10);
    try budget.reserve(10);
    try std.testing.expectError(error.ResourceBusy, budget.reserve(1));
    var execution = Reservation{ .budget = &budget, .amount = 10 };
    var transfer_reservation = Reservation{ .budget = &budget, .amount = 0, .active = false };
    try budget.transfer(&execution, &transfer_reservation);
    try std.testing.expect(execution.released);
    try std.testing.expect(!execution.active);
    try std.testing.expect(transfer_reservation.active);
    try transfer_reservation.release();
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}

test "ByteBudget transfer rejects inactive source and released destination" {
    var budget = ByteBudget.init(4);
    try budget.reserve(4);
    var inactive = Reservation{ .budget = &budget, .amount = 4, .active = false };
    var destination = Reservation{ .budget = &budget, .amount = 0, .active = false };
    try std.testing.expectError(error.Underflow, budget.transfer(&inactive, &destination));
    inactive.active = true;
    destination.released = true;
    try std.testing.expectError(error.Underflow, budget.transfer(&inactive, &destination));
    try inactive.release();
}

test "OutboundAccounting: queued와 writer-owned를 완료 전까지 합산" {
    var accounting = OutboundAccounting.init(10);
    try accounting.enqueue(7);
    try std.testing.expectError(error.ResourceBusy, accounting.enqueue(4));
    try accounting.beginWrite(7);
    try std.testing.expectEqual(@as(usize, 7), accounting.total());
    try accounting.writeComplete(7);
    try std.testing.expectEqual(@as(usize, 0), accounting.total());
}

test "Reservation: actual bytes 축소 후 transfer·release는 정확히 한 번" {
    var budget = ByteBudget.init(16);
    try budget.reserve(16);
    var execution = Reservation{ .budget = &budget, .amount = 16 };
    try execution.shrinkTo(3);
    try std.testing.expectEqual(@as(usize, 3), budget.used);
    var transfer_reservation = Reservation{ .budget = &budget, .amount = 0, .active = false };
    try budget.transfer(&execution, &transfer_reservation);
    try transfer_reservation.release();
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}
