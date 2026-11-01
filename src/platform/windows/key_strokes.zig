//! Native press identities outlive a frame, not the identity of a character.
//! Windows owns layout/IME translation. This ledger only pairs its physical
//! key slots and carries the first translated value to the matching release.
const std = @import("std");

pub fn Strokes(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Event = struct { value: T, stroke: u64 };
        pub const Down = struct { stroke: u64, repeated: bool };
        const Slot = struct { stroke: u64, first: ?T = null };
        slots: [256]?Slot = @splat(null),
        next: u64 = 1,

        /// Bit 30 of WM_KEYDOWN identifies repetition of the same physical press.
        /// https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-keydown
        pub fn begin(self: *Self, vk: u32, repeated: bool) ?Down {
            if (vk >= self.slots.len) return null;
            if (repeated) if (self.slots[vk]) |slot|
                return .{ .stroke = slot.stroke, .repeated = true };
            if (self.next == 0) return null;
            const stroke = self.next;
            self.next = if (stroke == std.math.maxInt(u64)) 0 else stroke + 1;
            self.slots[vk] = .{ .stroke = stroke };
            return .{ .stroke = stroke, .repeated = repeated };
        }

        /// Text remains the value supplied by WM_CHAR, including surrogate and
        /// layout translation. Several characters can belong to the same press.
        pub fn bind(self: *Self, vk: u32, value: T) ?Event {
            if (vk >= self.slots.len) return null;
            if (self.slots[vk]) |*slot| {
                if (slot.first == null) slot.first = value;
                return .{ .value = value, .stroke = slot.stroke };
            }
            return null;
        }

        pub fn release(self: *Self, vk: u32) ?Event {
            if (vk >= self.slots.len) return null;
            const slot = self.slots[vk] orelse return null;
            self.slots[vk] = null;
            return .{ .value = slot.first orelse return null, .stroke = slot.stroke };
        }

        pub fn current(self: *const Self, vk: u32) ?u64 {
            if (vk >= self.slots.len) return null;
            return if (self.slots[vk]) |slot| slot.stroke else null;
        }

        /// A focus boundary cancels down slots without reusing old identities.
        pub fn cancel(self: *Self) void {
            self.slots = @splat(null);
        }
    };
}

/// UI dismissal owns the remainder of exactly the consumed physical press.
/// It does not block unrelated committed text or a fresh press of the same key.
pub const Fence = struct {
    stroke: ?u64 = null,
    pub fn arm(self: *Fence, stroke: u64) void {
        self.stroke = if (stroke == 0) null else stroke;
    }
    pub fn clear(self: *Fence) void {
        self.stroke = null;
    }
    pub fn consume(self: *Fence, stroke: u64, released: bool) bool {
        if (stroke == 0 or self.stroke == null or self.stroke.? != stroke) return false;
        if (released) self.clear();
        return true;
    }
};

const KeyForTest = struct { scalar: u21, shift: bool = false };
const LedgerForTest = Strokes(KeyForTest);

test "Windows key stroke fence owns repeats and releases but not a fresh Escape" {
    var ledger: LedgerForTest = .{};
    const down = ledger.begin(0x1b, false).?;
    const press = ledger.bind(0x1b, .{ .scalar = 27 }).?;
    var fence: Fence = .{};
    fence.arm(press.stroke);
    const repeated = ledger.begin(0x1b, true).?;
    try std.testing.expect(repeated.repeated and down.stroke == repeated.stroke);
    try std.testing.expect(fence.consume(ledger.bind(0x1b, .{ .scalar = 27 }).?.stroke, false));
    const release = ledger.release(0x1b).?;
    try std.testing.expect(fence.consume(release.stroke, true));
    try std.testing.expect(fence.stroke == null);
    const fresh = ledger.begin(0x1b, false).?;
    try std.testing.expect(fresh.stroke != down.stroke and !fresh.repeated);
    try std.testing.expect(!fence.consume(fresh.stroke, false));
}

test "Windows key stroke preserves translated characters and first release snapshot" {
    var ledger: LedgerForTest = .{};
    const down = ledger.begin('A', false).?;
    const first = ledger.bind('A', .{ .scalar = '한', .shift = true }).?;
    const second = ledger.bind('A', .{ .scalar = 0x301 }).?;
    try std.testing.expectEqual(down.stroke, first.stroke);
    try std.testing.expectEqual(first.stroke, second.stroke);
    try std.testing.expectEqual(@as(u21, 0x301), second.value.scalar);
    const released = ledger.release('A').?;
    try std.testing.expectEqual(first.value, released.value);
    try std.testing.expectEqual(first.stroke, released.stroke);
    try std.testing.expect(ledger.release('A') == null);
}

test "Windows key stroke unrelated releases cannot end a captured gesture" {
    var ledger: LedgerForTest = .{};
    const captured = ledger.begin(0x1b, false).?;
    _ = ledger.bind(0x1b, .{ .scalar = 27 });
    const other = ledger.begin(0x0d, false).?;
    _ = ledger.bind(0x0d, .{ .scalar = 13 });
    var fence: Fence = .{};
    fence.arm(captured.stroke);
    try std.testing.expect(!fence.consume(ledger.release(0x0d).?.stroke, true));
    try std.testing.expectEqual(captured.stroke, fence.stroke.?);
    try std.testing.expect(other.stroke != captured.stroke);
    try std.testing.expect(fence.consume(ledger.release(0x1b).?.stroke, true));
}

test "Windows key stroke focus cancellation cannot alias a delayed release" {
    var ledger: LedgerForTest = .{};
    _ = ledger.begin(0x1b, false);
    _ = ledger.bind(0x1b, .{ .scalar = 27 });
    const delayed_release = ledger.release(0x1b).?;
    ledger.cancel();
    const fresh = ledger.begin(0x1b, false).?;
    var fence: Fence = .{};
    fence.arm(fresh.stroke);
    try std.testing.expect(!fence.consume(delayed_release.stroke, true));
    try std.testing.expectEqual(fresh.stroke, fence.stroke.?);
    _ = ledger.bind(0x1b, .{ .scalar = 27 });
    try std.testing.expect(fence.consume(ledger.release(0x1b).?.stroke, true));
}

test "Windows key stroke atomic text and invalid virtual keys never acquire a capture" {
    var ledger: LedgerForTest = .{};
    var fence: Fence = .{};
    fence.arm(0);
    try std.testing.expect(fence.stroke == null and !fence.consume(0, false));
    try std.testing.expect(ledger.begin(256, false) == null);
    try std.testing.expect(ledger.bind(256, .{ .scalar = 'x' }) == null);
    try std.testing.expect(ledger.release(256) == null);
    try std.testing.expectEqual(@as(u64, 1), ledger.next);
    try std.testing.expect(ledger.bind('X', .{ .scalar = 'x' }) == null);
    try std.testing.expect(ledger.release('X') == null);
}

test "Windows key stroke exhaustion cannot reuse an old press identity" {
    var ledger: LedgerForTest = .{ .next = std.math.maxInt(u64) };
    const last = ledger.begin(0x1b, false).?;
    try std.testing.expectEqual(std.math.maxInt(u64), last.stroke);
    _ = ledger.bind(0x1b, .{ .scalar = 27 });
    const repeated = ledger.begin(0x1b, true);
    try std.testing.expect(repeated != null);
    try std.testing.expectEqual(last.stroke, repeated.?.stroke);
    try std.testing.expect(ledger.begin(0x0d, false) == null);
    ledger.cancel();
    try std.testing.expect(ledger.begin(0x1b, false) == null);
}

test "Windows key stroke a repeat first seen after focus receives a distinct identity" {
    var ledger: LedgerForTest = .{};
    const before = ledger.begin('A', false).?;
    ledger.cancel();
    const after = ledger.begin('A', true).?;
    try std.testing.expect(after.repeated and after.stroke != before.stroke);
    try std.testing.expect(ledger.release('A') == null);
    try std.testing.expect(ledger.bind('A', .{ .scalar = 'a' }) == null);
}

test "Windows key stroke a missing old release cannot capture a new physical press" {
    var ledger: LedgerForTest = .{};
    const old = ledger.begin('A', false).?;
    _ = ledger.bind('A', .{ .scalar = 'a' });
    var fence: Fence = .{};
    fence.arm(old.stroke);
    const fresh = ledger.begin('A', false).?;
    try std.testing.expect(fresh.stroke != old.stroke);
    try std.testing.expect(!fence.consume(ledger.bind('A', .{ .scalar = 'A' }).?.stroke, false));
    try std.testing.expect(!fence.consume(ledger.release('A').?.stroke, true));
    fence.clear();
    try std.testing.expect(fence.stroke == null);
}
