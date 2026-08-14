const std = @import("std");

pub const Kind = enum(u8) { bell, clipboard_write, clipboard_read };

pub const Snapshot = struct {
    observer_generation: u64,
    bell_count: u64,
    clipboard_write_seq: u64,
    clipboard_read_seq: u64,
};

const Prepared = struct {
    cursor_addr: usize,
    kind: Kind,
    observer_generation: u64,
    previous_sequence: u64,
    sequence: u64,
};

pub const EventCursor = struct {
    observer_generation: ?u64 = null,
    bell_count: u64 = 0,
    clipboard_write_seq: u64 = 0,
    clipboard_read_seq: u64 = 0,

    pub fn takeBell(self: *EventCursor, snapshot: Snapshot) bool {
        if (self.rebase(snapshot)) return false;
        if (snapshot.bell_count <= self.bell_count) {
            self.bell_count = snapshot.bell_count;
            return false;
        }
        self.bell_count = snapshot.bell_count;
        return true;
    }

    pub fn prepare(self: *EventCursor, kind: Kind, snapshot: Snapshot) ?Prepared {
        if (kind == .bell or self.rebase(snapshot)) return null;
        const current = switch (kind) {
            .bell => unreachable,
            .clipboard_write => self.clipboard_write_seq,
            .clipboard_read => self.clipboard_read_seq,
        };
        const incoming = switch (kind) {
            .bell => unreachable,
            .clipboard_write => snapshot.clipboard_write_seq,
            .clipboard_read => snapshot.clipboard_read_seq,
        };
        if (incoming <= current) {
            switch (kind) {
                .bell => unreachable,
                .clipboard_write => self.clipboard_write_seq = incoming,
                .clipboard_read => self.clipboard_read_seq = incoming,
            }
            return null;
        }
        return .{
            .cursor_addr = @intFromPtr(self),
            .kind = kind,
            .observer_generation = snapshot.observer_generation,
            .previous_sequence = current,
            .sequence = incoming,
        };
    }

    pub fn commit(self: *EventCursor, prepared: Prepared) bool {
        if (@intFromPtr(self) != prepared.cursor_addr or
            self.observer_generation != prepared.observer_generation) return false;
        const cursor = switch (prepared.kind) {
            .bell => return false,
            .clipboard_write => &self.clipboard_write_seq,
            .clipboard_read => &self.clipboard_read_seq,
        };
        if (cursor.* != prepared.previous_sequence or prepared.sequence <= cursor.*) return false;
        cursor.* = prepared.sequence;
        return true;
    }

    fn rebase(self: *EventCursor, snapshot: Snapshot) bool {
        if (self.observer_generation == snapshot.observer_generation) return false;
        self.* = .{
            .observer_generation = snapshot.observer_generation,
            .bell_count = snapshot.bell_count,
            .clipboard_write_seq = snapshot.clipboard_write_seq,
            .clipboard_read_seq = snapshot.clipboard_read_seq,
        };
        return true;
    }
};

test "CR2d3 event cursor는 첫 관측과 generation 교체를 재생하지 않는다" {
    var cursor: EventCursor = .{};
    try std.testing.expect(!cursor.takeBell(.{ .observer_generation = 7, .bell_count = 9, .clipboard_write_seq = 10, .clipboard_read_seq = 11 }));
    try std.testing.expect(cursor.takeBell(.{ .observer_generation = 7, .bell_count = 10, .clipboard_write_seq = 10, .clipboard_read_seq = 11 }));
    try std.testing.expect(!cursor.takeBell(.{ .observer_generation = 8, .bell_count = 40, .clipboard_write_seq = 50, .clipboard_read_seq = 60 }));
    try std.testing.expect(cursor.prepare(.clipboard_write, .{ .observer_generation = 8, .bell_count = 40, .clipboard_write_seq = 50, .clipboard_read_seq = 60 }) == null);
}

test "CR2d3 event cursor는 OSC52 prepare 실패와 commit을 구분한다" {
    var cursor: EventCursor = .{};
    const base: Snapshot = .{ .observer_generation = 3, .bell_count = 0, .clipboard_write_seq = 4, .clipboard_read_seq = 5 };
    _ = cursor.takeBell(base);
    const write = cursor.prepare(.clipboard_write, .{ .observer_generation = 3, .bell_count = 0, .clipboard_write_seq = 6, .clipboard_read_seq = 5 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 4), cursor.clipboard_write_seq);
    try std.testing.expect(cursor.commit(write));
    try std.testing.expectEqual(@as(u64, 6), cursor.clipboard_write_seq);
    try std.testing.expect(!cursor.commit(write));
    var copied: EventCursor = cursor;
    try std.testing.expect(!copied.commit(write));
    const read = cursor.prepare(.clipboard_read, .{ .observer_generation = 3, .bell_count = 0, .clipboard_write_seq = 6, .clipboard_read_seq = 7 }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cursor.commit(read));
}
