//! Session-host live upgrade의 process-local admission barrier(U2).
//!
//! Runtime input/resize/spawn 같은 새 작업과 socket frame dispatch는 모두 이 gate의 in-flight lease 안에서
//! 실행된다. Upgrade coordinator는 gate를 먼저 닫은 뒤 in-flight가 0인 것만 관찰하고 reader quiesce로
//! 넘어간다. Queue의 `closed` 비트를 admission 용도로 재사용하지 않는다. 실패 시 `reopen`하면 기존 runtime과
//! queue를 파괴하지 않고 serving으로 돌아간다.

const std = @import("std");

pub const AdmissionGate = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    open: bool = true,
    in_flight: usize = 0,
    epoch: u64 = 0,

    pub fn init(io: std.Io) AdmissionGate {
        return .{ .io = io };
    }

    pub const Lease = struct {
        gate: *AdmissionGate,
        released: bool = false,

        pub fn release(self: *Lease) void {
            if (self.released) return;
            self.released = true;
            self.gate.leave();
        }
    };

    /// 새 작업을 admission한다. gate가 닫힌 뒤 도착한 작업은 기다리지 않고 거부해 coordinator와
    /// connection handler 사이 deadlock을 만들지 않는다.
    pub fn tryEnter(self: *AdmissionGate) ?Lease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.open) return null;
        self.in_flight += 1;
        return .{ .gate = self };
    }

    fn leave(self: *AdmissionGate) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.in_flight > 0);
        self.in_flight -= 1;
    }

    /// 새 admission을 닫는다. false는 다른 attempt가 이미 gate를 소유한다는 뜻이다.
    pub fn close(self: *AdmissionGate) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.open) return false;
        self.open = false;
        return true;
    }

    /// gate가 닫혔고 기존 작업도 모두 반환했는지 한 스냅샷으로 검사한다.
    pub fn closedAndDrained(self: *AdmissionGate) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return !self.open and self.in_flight == 0;
    }

    /// quiesce/encode/exec 전 실패 rollback. Queue나 runtime state는 건드리지 않고 새 admission만 다시 연다.
    pub fn reopen(self: *AdmissionGate) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(!self.open);
        std.debug.assert(self.in_flight == 0);
        self.epoch +%= 1;
        self.open = true;
    }

    pub const Snapshot = struct {
        open: bool,
        in_flight: usize,
        epoch: u64,
    };

    pub fn snapshot(self: *AdmissionGate) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .open = self.open, .in_flight = self.in_flight, .epoch = self.epoch };
    }
};

test "upgrade admission gate rejects work after close and reopens only after drain" {
    var gate = AdmissionGate.init(std.testing.io);
    var first = gate.tryEnter() orelse return error.TestUnexpectedResult;
    var second = gate.tryEnter() orelse return error.TestUnexpectedResult;

    try std.testing.expect(gate.close());
    try std.testing.expect(!gate.close());
    try std.testing.expect(gate.tryEnter() == null);
    try std.testing.expect(!gate.closedAndDrained());

    first.release();
    try std.testing.expect(!gate.closedAndDrained());
    second.release();
    try std.testing.expect(gate.closedAndDrained());

    gate.reopen();
    const snap = gate.snapshot();
    try std.testing.expect(snap.open);
    try std.testing.expectEqual(@as(usize, 0), snap.in_flight);
    try std.testing.expectEqual(@as(u64, 1), snap.epoch);
    var after = gate.tryEnter() orelse return error.TestUnexpectedResult;
    after.release();
}
