//! sidecar 가 든 브라우저 목록(W1c) — maru 의 `BrowserId` 와 CEF browser 를 잇는다. CEF 를 모른다(핸들은 불투명
//! 포인터) — 그래서 CEF SDK 없이 기본 test 에서 시험이 돈다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const TitleGate = @import("title_gate.zig").TitleGate;

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
    /// 받은 그리기 콜백 수(관측점).
    paints: u64 = 0,
    title: TitleGate = .{},
    /// D9 — CPU 경로로 그렸다고 이미 알렸다(한 번만).
    gpu_unavailable_sent: bool = false,
    /// 이 브라우저의 픽셀 링 생산자(W2 — `ring_producer.Producer`). 목록은 CEF·mach 를 몰라 불투명하게 든다.
    frames: ?*anyopaque = null,
    /// 열린 팝업 위젯의 링 생산자(W6a). 팝업이 열려 처음 그릴 때 만들고 닫히면 버린다 — 다시 열면 새 링(이어지는 새 세대)으로
    /// 시작해 옛 목록이 비치지 않는다.
    popup_frames: ?*anyopaque = null,
    /// 다음 팝업 링의 세대 — 팝업 생산자를 버려도 이어 간다. 그래야 maru 가 닫히기 직전의 링과 다음 팝업의 링을 세대로 가른다
    /// (W6a① 적대 검증 — 생산자마다 1 부터면 둘이 같은 세대였다).
    popup_generation: u32 = 1,
    /// 팝업이 열려 있다(`on_popup_show(1)` ~ `(0)`·렌더러 사망). 방어로 셋에 쓴다 — 닫힌 뒤 늦게 온 팝업 그림이 생산자를 되살려
    /// 다음 팝업의 첫 세대로 옛 목록을 싣지 않게(4 차 — CEF 154 에서는 관측되지 않았다. CEF 는 열림 → 사각형 → 그림 순으로
    /// 부른다, 착수 전 실측), 닫힘 알림을 열린 팝업에만 한 번(6 차), 열림 없이 온 사각형은 알리지 않게(7 차). W6a① 적대 검증.
    popup_open: bool = false,
    /// 마지막으로 보낸 툴팁 글의 해시와 비었는지(W6b) — CEF 는 요소 안에서 움직일 때마다 같은 글을 다시 부른다(실측). 연달아
    /// 같은 글은 보내지 않는다. 빈 글도 하나의 값이다(처음은 빈 글).
    tooltip_hash: u64 = 0,
    tooltip_nonempty: bool = false,
    /// 쥔 우클릭 메뉴(W6c — `context_menu.Held`, CEF 메뉴 콜백을 든다). 목록은 CEF 를 몰라 불투명하게 든다.
    context_menu: ?*anyopaque = null,
    /// 밖에서 끌어 온 조각과 끌기 상태(W6d① — `drag.Pending`). 목록은 CEF 를 몰라 불투명하게 든다.
    drag: ?*anyopaque = null,
    /// 이 끌기에서 마지막으로 알린 받아들이는 동작(W6d① — 같은 것은 다시 안 보낸다, enter 에서 비운다).
    drag_operation: ?u32 = null,
    /// 마지막으로 알린 커서(W4 — 같은 것은 다시 안 보낸다).
    cursor: ?protocol.message.WebCursor = null,
    /// 마지막으로 알린 IME 조합 사각형(W4 — 같은 것은 다시 안 보낸다).
    ime_bounds: ?protocol.message.Rect = null,
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
