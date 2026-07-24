//! Same-PID exec에서 상속하는 runtime/state/owner descriptor layout의 OS-중립 단일 출처.

const std = @import("std");
const limits = @import("upgrade_limits.zig");

pub const slot_count: usize = limits.max_runtime_count + 3;

pub const Layout = struct {
    first_runtime_slot: i32,

    pub fn init(first_runtime_slot: i64) error{InvalidLayout}!Layout {
        const last = std.math.add(
            i64,
            first_runtime_slot,
            @as(i64, @intCast(slot_count - 1)),
        ) catch return error.InvalidLayout;
        if (first_runtime_slot < 3 or last > std.math.maxInt(u16))
            return error.InvalidLayout;
        return .{ .first_runtime_slot = @intCast(first_runtime_slot) };
    }

    pub fn valid(self: Layout) bool {
        _ = init(self.first_runtime_slot) catch return false;
        return true;
    }

    pub fn primarySlot(self: Layout) i32 {
        std.debug.assert(self.valid());
        return self.first_runtime_slot + @as(i32, @intCast(limits.max_runtime_count));
    }

    pub fn runtimeSlot(self: Layout, index: usize) ?i32 {
        if (!self.valid() or index >= limits.max_runtime_count) return null;
        return self.first_runtime_slot + @as(i32, @intCast(index));
    }

    pub fn backupSlot(self: Layout) i32 {
        return self.primarySlot() + 1;
    }

    pub fn ownerSlot(self: Layout) i32 {
        return self.backupSlot() + 1;
    }

    pub fn requested(self: Layout) ?[slot_count]i32 {
        if (!self.valid()) return null;
        var result: [slot_count]i32 = undefined;
        for (&result, 0..) |*slot, index|
            slot.* = self.first_runtime_slot + @as(i32, @intCast(index));
        return result;
    }
};

test "upgrade fd layout owns the exact inclusive u16 boundary" {
    const last = try Layout.init(65_277);
    try std.testing.expectEqual(@as(i32, 65_535), last.ownerSlot());
    try std.testing.expectError(error.InvalidLayout, Layout.init(65_278));
    try std.testing.expectError(error.InvalidLayout, Layout.init(2));
    try std.testing.expect(!(Layout{ .first_runtime_slot = -1 }).valid());
    try std.testing.expectEqual(@as(i32, 65_532), last.runtimeSlot(limits.max_runtime_count - 1).?);
    try std.testing.expect(last.runtimeSlot(limits.max_runtime_count) == null);
}
