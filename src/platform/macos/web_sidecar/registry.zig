//! sidecar 가 든 브라우저 목록(W1c) — maru 의 `BrowserId` 와 CEF browser 를 잇는다. CEF 를 모른다(핸들은 불투명
//! 포인터) — 그래서 CEF SDK 없이 기본 test 에서 시험이 돈다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const BrowserId = protocol.message.BrowserId;
const ViewSize = protocol.message.ViewSize;

/// 한 sidecar 가 드는 브라우저 상한. 브라우저당 약 66MB(§13.1 실측)라 이 수면 이미 2GB 가 넘는다.
pub const capacity = 32;

pub const Entry = struct {
    id: BrowserId,
    /// CEF 의 browser identifier — CEF 콜백은 이것으로만 브라우저를 알려 준다.
    cef_id: c_int,
    /// CEF browser. 목록이 참조 하나를 쥐고, 닫힐 때(`on_before_close`) 푼다.
    handle: *anyopaque,
    size: ViewSize,
    closing: bool = false,
    /// 받은 그리기 콜백 수(W2 전의 관측점).
    paints: u64 = 0,
};

pub const Error = error{ Duplicate, Full };

pub const Registry = struct {
    slots: [capacity]?Entry = @splat(null),

    pub fn add(self: *Registry, entry: Entry) Error!void {
        if (self.byId(entry.id) != null) return error.Duplicate;
        for (&self.slots) |*slot| {
            if (slot.* == null) {
                slot.* = entry;
                return;
            }
        }
        return error.Full;
    }

    pub fn byId(self: *Registry, id: BrowserId) ?*Entry {
        for (&self.slots) |*slot| {
            if (slot.*) |*entry| if (entry.id == id) return entry;
        }
        return null;
    }

    pub fn byCefId(self: *Registry, cef_id: c_int) ?*Entry {
        for (&self.slots) |*slot| {
            if (slot.*) |*entry| if (entry.cef_id == cef_id) return entry;
        }
        return null;
    }

    /// 목록에서 빼고 돌려준다 — 호출자가 쥔 참조를 푼다.
    pub fn remove(self: *Registry, cef_id: c_int) ?Entry {
        for (&self.slots) |*slot| {
            if (slot.*) |entry| if (entry.cef_id == cef_id) {
                slot.* = null;
                return entry;
            };
        }
        return null;
    }

    pub fn count(self: *const Registry) usize {
        var n: usize = 0;
        for (self.slots) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }

    pub fn full(self: *const Registry) bool {
        return self.count() == capacity;
    }
};

const test_size: ViewSize = .{ .width = 10, .height = 10, .scale = 1 };
var test_handles: [capacity + 1]u8 = undefined;

fn testEntry(id: BrowserId, cef_id: c_int) Entry {
    return .{ .id = id, .cef_id = cef_id, .handle = &test_handles[@intCast(cef_id)], .size = test_size };
}

test "add finds by maru id and by CEF id, remove hands the entry back once" {
    var registry: Registry = .{};
    try registry.add(testEntry(100, 1));
    try registry.add(testEntry(200, 2));
    try std.testing.expectEqual(@as(c_int, 2), registry.byId(200).?.cef_id);
    try std.testing.expectEqual(@as(BrowserId, 100), registry.byCefId(1).?.id);
    try std.testing.expectEqual(@as(BrowserId, 100), registry.remove(1).?.id);
    try std.testing.expect(registry.remove(1) == null);
    try std.testing.expect(registry.byId(100) == null);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
}

test "duplicate maru id is refused, and capacity is a hard limit" {
    var registry: Registry = .{};
    try registry.add(testEntry(7, 1));
    try std.testing.expectError(error.Duplicate, registry.add(testEntry(7, 2)));
    var id: BrowserId = 8;
    while (registry.count() < capacity) : (id += 1) try registry.add(testEntry(id, @intCast(id - 6)));
    try std.testing.expect(registry.full());
    try std.testing.expectError(error.Full, registry.add(testEntry(999, capacity)));
    // 빈 자리가 생기면 다시 받는다.
    _ = registry.remove(1);
    try registry.add(testEntry(999, capacity));
}
