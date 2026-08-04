//! Generic action/drag intent table — CIM1.
//!
//! Pointer hit testing과 drag 수명은 `UiActionId`와 opaque drag payload만 낸다. 그 두 값을 domain
//! intent로 되돌리는 자리가 이 표다. 지금까지는 소비자마다 같은 구조를 다시 만들었고
//! (`components/session_dock/ids.zig`, `components/archive_detail/ids.zig`), 그러면 두 번째 소비자가
//! generation 검증이나 stale 거부를 빠뜨려도 아무도 못 잡는다.
//!
//! **generation이 이 표의 핵심이다.** 같은 frame arena를 매 snapshot 재사용하므로 action ID는
//! 곧 재발급된다. 그래서 resolve는 ID뿐 아니라 **어느 세대의 ID인지**까지 맞을 때만 intent를 낸다 —
//! 이전 tree를 보고 누른 up이 새 tree의 다른 command를 실행하는 것을 여기서 한 번 더 막는다.
//!
//! 이 모듈은 domain을 모른다. `Intent`는 소비자가 주는 타입이고, 표는 그것을 옮기기만 한다.

const std = @import("std");
const tree = @import("tree.zig");

pub const TableError = error{InsufficientActionBuffer};

/// 소비자의 `Intent` 타입으로 특수화한 표. 한 frame 동안만 살고 다음 snapshot에서 다시 채운다.
pub fn IntentTable(comptime Intent: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            action_id: tree.UiActionId,
            snapshot_generation: u64,
            intent: Intent,
            /// published tree의 `UiAction.enabled`를 일부러 한 번 더 들고 있다. host의 keyboard
            /// dispatch가 같은 identity를 pointer와 다른 경로로 풀기 때문에, 두 번째 state gate를
            /// 새로 만들지 않고 여기서 함께 막는다. stale action이 "shortcut으로 지목됐다"는
            /// 이유만으로 실행돼서는 안 된다.
            enabled: bool = true,
            /// drag payload를 함께 발급한 경우 그 ID. click 전용 action은 null이다.
            drag_payload: ?u64 = null,
        };

        entries: []Entry,
        count: usize = 0,

        pub fn init(entries: []Entry) Self {
            return .{ .entries = entries };
        }

        /// click action 하나를 발급한다. 반환한 `UiAction`을 component가 node에 싣는다.
        pub fn append(self: *Self, snapshot_generation: u64, intent: Intent, enabled: bool) TableError!tree.UiAction {
            const action_id = try self.reserve(snapshot_generation, intent, enabled, null);
            return .{ .id = action_id, .enabled = enabled };
        }

        /// drag를 함께 선언하는 action을 발급한다. 두 축의 숫자가 겹치지 않게 payload는
        /// 별도 대역에서 발급한다(아래 `drag_payload_base` 참조).
        pub fn appendDraggable(
            self: *Self,
            snapshot_generation: u64,
            intent: Intent,
            enabled: bool,
            axis: tree.DragAxis,
            threshold_px: f32,
        ) TableError!struct { action: tree.UiAction, drag: tree.DragDeclaration } {
            const payload = drag_payload_base + @as(u64, @intCast(self.count + 1));
            const action_id = try self.reserve(snapshot_generation, intent, enabled, payload);
            return .{
                .action = .{ .id = action_id, .enabled = enabled },
                .drag = .{ .payload = payload, .axis = axis, .threshold_px = threshold_px },
            };
        }

        /// action ID를 intent로 되돌린다. **세대가 다르거나 disabled면 null이다.**
        pub fn resolve(self: Self, action_id: tree.UiActionId, snapshot_generation: u64) ?Intent {
            for (self.slice()) |entry| {
                if (entry.action_id != action_id) continue;
                if (entry.snapshot_generation != snapshot_generation) return null;
                if (!entry.enabled) return null;
                return entry.intent;
            }
            return null;
        }

        /// drag payload를 intent로 되돌린다. drop은 up 시점의 좌표를 host가 다시 hit-test해
        /// destination을 정하고, 이 함수는 **무엇을 끌고 있었는지**만 답한다.
        pub fn resolveDrag(self: Self, payload: u64, snapshot_generation: u64) ?Intent {
            for (self.slice()) |entry| {
                const declared = entry.drag_payload orelse continue;
                if (declared != payload) continue;
                if (entry.snapshot_generation != snapshot_generation) return null;
                if (!entry.enabled) return null;
                return entry.intent;
            }
            return null;
        }

        pub fn slice(self: Self) []const Entry {
            return self.entries[0..self.count];
        }

        fn reserve(self: *Self, snapshot_generation: u64, intent: Intent, enabled: bool, drag_payload: ?u64) TableError!tree.UiActionId {
            if (self.count == self.entries.len) return error.InsufficientActionBuffer;
            const action_id: tree.UiActionId = @intCast(self.count + 1);
            self.entries[self.count] = .{
                .action_id = action_id,
                .snapshot_generation = snapshot_generation,
                .intent = intent,
                .enabled = enabled,
                .drag_payload = drag_payload,
            };
            self.count += 1;
            return action_id;
        }

        /// drag payload를 발급하는 대역의 시작. `UiActionId`도 `u64`라 **타입이 두 축을 갈라주지
        /// 않는다** — 갈라주는 것은 `resolve`/`resolveDrag`가 서로 다른 필드만 본다는 사실이다.
        /// 이 오프셋은 그 위에 얹는 두 번째 방어다: 두 축의 숫자가 겹치지 않으므로 raw 값을 로그나
        /// trace에서 볼 때 어느 축인지 헷갈리지 않는다. 표는 고정 용량 버퍼로 채우고 그 크기는
        /// 2^32에 한참 못 미치므로 action ID가 이 대역까지 올라오지 않는다.
        const drag_payload_base: u64 = 1 << 32;
    };
}

const TestIntent = union(enum) { resume_session, reveal, move_tab: u32 };
const TestTable = IntentTable(TestIntent);

test "resolve requires both the action id and the generation that issued it" {
    var storage: [4]TestTable.Entry = undefined;
    var table = TestTable.init(&storage);

    const first = try table.append(7, .resume_session, true);
    try std.testing.expect(first.enabled);
    try std.testing.expectEqual(TestIntent.resume_session, table.resolve(first.id, 7).?);

    // 같은 ID라도 다른 세대면 풀리지 않는다 — frame arena가 ID를 곧 재발급하기 때문이다.
    try std.testing.expect(table.resolve(first.id, 8) == null);
    // 없는 ID도 마찬가지다.
    try std.testing.expect(table.resolve(first.id + 99, 7) == null);
}

test "a disabled action resolves to nothing on either axis" {
    var storage: [4]TestTable.Entry = undefined;
    var table = TestTable.init(&storage);

    // pointer 경로는 hit-test가 이미 거르지만, host의 keyboard dispatch는 같은 identity를
    // 다른 경로로 푼다. 그 두 번째 경로를 위해 표가 한 번 더 막는다.
    const disabled = try table.append(1, .reveal, false);
    try std.testing.expect(!disabled.enabled);
    try std.testing.expect(table.resolve(disabled.id, 1) == null);

    const dead_drag = try table.appendDraggable(1, .{ .move_tab = 9 }, false, .free, 3);
    try std.testing.expect(table.resolveDrag(dead_drag.drag.payload, 1) == null);
}

test "drag payloads never collide with action ids" {
    var storage: [4]TestTable.Entry = undefined;
    var table = TestTable.init(&storage);

    const draggable = try table.appendDraggable(3, .{ .move_tab = 2 }, true, .horizontal, 4);
    try std.testing.expectEqual(tree.DragAxis.horizontal, draggable.drag.axis);
    try std.testing.expectEqual(@as(f32, 4), draggable.drag.threshold_px);

    try std.testing.expectEqual(TestIntent{ .move_tab = 2 }, table.resolveDrag(draggable.drag.payload, 3).?);

    // drag도 세대를 지킨다.
    try std.testing.expect(table.resolveDrag(draggable.drag.payload, 4) == null);

    // 두 축은 서로의 값을 받아주지 않는다. `UiActionId`도 `u64`라 타입이 갈라주지 않으므로,
    // 실제로 갈라주는 것이 무엇인지를 양방향으로 고정한다.
    _ = try table.append(3, .reveal, true);
    try std.testing.expect(table.resolveDrag(draggable.action.id, 3) == null);
    try std.testing.expect(table.resolve(draggable.drag.payload, 3) == null);

    // 그리고 같은 표 안에서 두 축의 숫자 자체가 겹치지 않는다.
    for (table.slice()) |entry| {
        for (table.slice()) |other| {
            const payload = other.drag_payload orelse continue;
            try std.testing.expect(entry.action_id != payload);
        }
    }
}

test "the table fails closed instead of overwriting a full buffer" {
    var storage: [1]TestTable.Entry = undefined;
    var table = TestTable.init(&storage);
    _ = try table.append(1, .resume_session, true);
    try std.testing.expectError(error.InsufficientActionBuffer, table.append(1, .reveal, true));
    // 실패해도 이미 발급한 것은 그대로다 — partial publish 대신 candidate가 실패한다.
    try std.testing.expectEqual(@as(usize, 1), table.slice().len);
}
