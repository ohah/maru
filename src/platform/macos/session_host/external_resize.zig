//! External attach client의 local resize state machine.
//!
//! OS signal/ioctl은 `external_tty.RawTty`가 맡고, 이 모듈은 role·coalesce 결과·wire sequence와
//! host-applied generation만 결정한다. 공개 CLI와 MRSH 호출은 P5c3 adapter가 연결한다.

const std = @import("std");
const external_tty = @import("external_tty.zig");

pub const Role = enum { observer, controller };
pub const Error = error{SequenceExhausted};

pub const Request = struct {
    size: external_tty.Size,
    client_sequence: u64,
};

pub const Applied = struct {
    size: external_tty.Size,
    resize_generation: u64,
};

pub const ExternalResizeState = struct {
    role: Role,
    initial_size: external_tty.Size,
    last_sent_size: ?external_tty.Size = null,
    applied: ?Applied = null,
    next_sequence: u64 = 1,
    sequence_exhausted: bool = false,

    pub fn init(initial_size: external_tty.Size, role: Role) ExternalResizeState {
        return .{ .role = role, .initial_size = initial_size };
    }

    pub fn attached(self: *ExternalResizeState) Error!?Request {
        return if (self.role == .controller) try self.emit(self.initial_size, true) else null;
    }

    pub fn localResize(self: *ExternalResizeState, current: external_tty.Size) Error!?Request {
        if (self.role != .controller or current.cols == 0 or current.rows == 0) return null;
        return self.emit(current, false);
    }

    pub fn becomeController(
        self: *ExternalResizeState,
        current: external_tty.Size,
    ) Error!Request {
        self.role = .controller;
        return (try self.emit(current, true)).?;
    }

    pub fn becomeObserver(self: *ExternalResizeState) void {
        self.role = .observer;
    }

    pub fn applyHostResize(
        self: *ExternalResizeState,
        size: external_tty.Size,
        generation: u64,
    ) bool {
        if (generation == 0 or size.cols == 0 or size.rows == 0) return false;
        if (self.applied) |old| if (generation <= old.resize_generation) return false;
        self.applied = .{ .size = size, .resize_generation = generation };
        return true;
    }

    fn emit(
        self: *ExternalResizeState,
        size: external_tty.Size,
        force: bool,
    ) Error!?Request {
        if (size.cols == 0 or size.rows == 0) return null;
        if (!force and self.last_sent_size != null and
            std.meta.eql(self.last_sent_size.?, size)) return null;
        if (self.sequence_exhausted) return error.SequenceExhausted;
        const sequence = self.next_sequence;
        if (sequence == std.math.maxInt(u64)) {
            self.sequence_exhausted = true;
        } else {
            self.next_sequence += 1;
        }
        self.last_sent_size = size;
        return .{ .size = size, .client_sequence = sequence };
    }
};

test "observer suppresses local resize and controller emits forced first plus changed latest" {
    const initial: external_tty.Size = .{ .cols = 80, .rows = 24 };
    var state = ExternalResizeState.init(initial, .observer);
    try std.testing.expectEqual(@as(?Request, null), try state.attached());
    try std.testing.expectEqual(@as(?Request, null), try state.localResize(.{
        .cols = 100,
        .rows = 30,
    }));

    const first = try state.becomeController(initial);
    try std.testing.expectEqual(@as(u64, 1), first.client_sequence);
    try std.testing.expectEqual(initial, first.size);
    try std.testing.expectEqual(@as(?Request, null), try state.localResize(initial));
    const changed = (try state.localResize(.{ .cols = 120, .rows = 40 })).?;
    try std.testing.expectEqual(@as(u64, 2), changed.client_sequence);
    try std.testing.expectEqual(external_tty.Size{ .cols = 120, .rows = 40 }, changed.size);
}

test "zero sizes are suppressed, revoke drops authority, and takeover forces current size" {
    var state = ExternalResizeState.init(.{ .cols = 80, .rows = 24 }, .controller);
    _ = (try state.attached()).?;
    try std.testing.expectEqual(@as(?Request, null), try state.localResize(.{
        .cols = 0,
        .rows = 40,
    }));
    state.becomeObserver();
    try std.testing.expectEqual(@as(?Request, null), try state.localResize(.{
        .cols = 100,
        .rows = 30,
    }));
    const takeover = try state.becomeController(.{ .cols = 80, .rows = 24 });
    try std.testing.expectEqual(@as(u64, 2), takeover.client_sequence);
}

test "sequence emits max once without wrap" {
    var state = ExternalResizeState.init(.{ .cols = 80, .rows = 24 }, .controller);
    state.next_sequence = std.math.maxInt(u64);
    const final = (try state.localResize(.{ .cols = 81, .rows = 24 })).?;
    try std.testing.expectEqual(std.math.maxInt(u64), final.client_sequence);
    try std.testing.expectError(
        error.SequenceExhausted,
        state.localResize(.{ .cols = 82, .rows = 24 }),
    );
}

test "host resize applies increasing generation and accepts gaps" {
    var state = ExternalResizeState.init(.{ .cols = 80, .rows = 24 }, .observer);
    try std.testing.expect(state.applyHostResize(.{ .cols = 100, .rows = 30 }, 4));
    try std.testing.expect(!state.applyHostResize(.{ .cols = 90, .rows = 20 }, 4));
    try std.testing.expect(!state.applyHostResize(.{ .cols = 90, .rows = 20 }, 3));
    try std.testing.expect(!state.applyHostResize(.{ .cols = 0, .rows = 20 }, 5));
    try std.testing.expect(state.applyHostResize(.{ .cols = 120, .rows = 40 }, 9));
    try std.testing.expectEqual(@as(u64, 9), state.applied.?.resize_generation);
}
