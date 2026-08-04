//! Immutable rect-tree pointer interaction seam for the Metal Chrome path.
//!
//! This module owns no platform objects, callbacks, Metal state, or mutable rect cache. The host
//! publishes only completed `UiRectTree` snapshots and converts its platform pointer event once at
//! the boundary. Tests can therefore exercise click/capture correctness without a macOS window.

const std = @import("std");
const input = @import("../input.zig");
const layout = @import("layout.zig");
const ui_tree = @import("tree.zig");

pub const UiId = ui_tree.UiId;
pub const UiActionId = ui_tree.UiActionId;
pub const UiRectTree = ui_tree.UiRectTree;

pub const UiPointerPhase = enum { move, down, up, cancel };

pub const UiPointerEvent = struct {
    phase: UiPointerPhase,
    x_px: f64,
    y_px: f64,
    button: input.PointerButton = .left,
    timestamp_ns: u64,
};

pub const Capture = struct {
    id: UiId,
    action_id: UiActionId,
};

pub const InteractionState = struct {
    hovered: ?UiId = null,
    focused: ?UiId = null,
    capture: ?Capture = null,
};

/// Fixed and allocation-free because the ML2b state has three visual identities. A transition can
/// replace each old identity with one new identity, but valid single-pointer transitions produce at
/// most four distinct IDs. Keeping a fourth slot makes that invariant explicit rather than silently
/// losing a repaint request.
pub const DirtySet = struct {
    ids: [4]?UiId = .{ null, null, null, null },

    pub fn add(self: *DirtySet, id: ?UiId) InteractionError!void {
        const value = id orelse return;
        for (self.ids) |existing| {
            if (existing != null and existing.? == value) return;
        }
        for (&self.ids) |*slot| {
            if (slot.* == null) {
                slot.* = value;
                return;
            }
        }
        return error.DirtySetOverflow;
    }
};

pub const Dispatch = struct {
    action: ?UiActionId = null,
    dirty: DirtySet = .{},
};

pub const InteractionError = error{DirtySetOverflow};

/// Dispatches one event against the currently published immutable tree. A caller must call
/// `reconcile` before replacing that tree; build failures do not call either function and therefore
/// retain the current interaction state unchanged.
pub fn dispatch(state: *InteractionState, snapshot: UiRectTree, event: UiPointerEvent) InteractionError!Dispatch {
    const before = state.*;
    var after = before;
    var action: ?UiActionId = null;

    switch (event.phase) {
        .move => {
            if (after.capture == null) {
                after.hovered = if (hitAction(snapshot, event.x_px, event.y_px)) |value| value.id else null;
            }
        },
        .down => {
            // The protocol has no pointer ID. A second down is a new primary sequence, so its
            // predecessor cannot remain pressed or later receive a stale up action.
            after.capture = null;
            if (event.button == .left) {
                const target = hitAction(snapshot, event.x_px, event.y_px);
                after.hovered = if (target) |value| value.id else null;
                if (target) |value| {
                    after.focused = value.id;
                    after.capture = .{ .id = value.id, .action_id = value.action_id };
                }
            }
        },
        .up => {
            if (event.button == .left) {
                const previous_capture = after.capture;
                after.capture = null;
                after.hovered = if (hitAction(snapshot, event.x_px, event.y_px)) |value| value.id else null;
                if (previous_capture) |capture| {
                    if (enabledActionForId(snapshot, capture.id)) |current_action| {
                        if (current_action.id == capture.action_id) action = capture.action_id;
                    }
                }
            }
        },
        .cancel => {
            after.capture = null;
            after.hovered = if (hitAction(snapshot, event.x_px, event.y_px)) |value| value.id else null;
        },
    }

    const result = try finishTransition(before, after, action);
    state.* = after;
    return result;
}

/// Reconciles stable IDs before a completed candidate replaces the published tree. Capture is never
/// carried across snapshots: an up after this point must not execute an action from an older tree.
pub fn reconcile(state: *InteractionState, old_tree: UiRectTree, new_tree: UiRectTree) InteractionError!Dispatch {
    _ = old_tree;
    const before = state.*;
    var after = before;
    after.capture = null;
    if (after.hovered) |id| {
        if (enabledActionForId(new_tree, id) == null) after.hovered = null;
    }
    if (after.focused) |id| {
        if (enabledActionForId(new_tree, id) == null) after.focused = null;
    }

    const result = try finishTransition(before, after, null);
    state.* = after;
    return result;
}

/// Keyboard activation of the focused node — the parity path for a pointer click.
///
/// **아직 host 배선이 없다.** Session Dock은 여전히 `agentSessionDockShortcutIntent`(intent 종류를
/// 목록에서 찾아 실행)로 키보드 action을 처리하므로 focus와 무관하게 같은 동작을 낸다. 그 경로를
/// 이 함수로 옮기는 것은 **사용자에게 보이는 동작 변경**(선택된 버튼만 실행)이라 승인과 fixture
/// 갱신이 함께 필요하며, 그때까지 두 경로가 공존한다는 사실을 여기 적어 둔다.
///
/// 이 함수가 없으면 keyboard 사용자는 같은 command에 도달할 길이 없다. Session Dock은 지금
/// "이 종류의 intent를 목록에서 찾아 실행"하는 별도 경로를 쓰는데, 그것은 focus와 무관해서 어떤
/// 버튼이 선택돼 있든 같은 동작을 낸다 — parity가 아니다.
///
/// pointer up과 **정확히 같은 검증**을 통과한다: 지금 published tree에서 그 id가 여전히 enabled
/// action을 가질 때만 실행한다. 그래서 stale focus나 사이에 disabled로 바뀐 action이 키로 되살아나지
/// 않는다. capture가 살아 있으면(누군가 pointer로 누르고 있는 중) 아무것도 하지 않는다 — 한 stream에
/// 하나의 owner라는 §4.3 규칙을 keyboard가 우회하지 못하게 한다.
pub fn activateFocused(state: *InteractionState, snapshot: UiRectTree) InteractionError!Dispatch {
    const before = state.*;
    if (before.capture != null) return try finishTransition(before, before, null);
    const id = before.focused orelse return try finishTransition(before, before, null);
    const current = enabledActionForId(snapshot, id) orelse {
        // focus만 남고 action이 사라졌거나 disabled가 됐다. 그 자리를 비워 다음 키가 유령 대상을
        // 다시 겨냥하지 않게 한다.
        var after = before;
        after.focused = null;
        const result = try finishTransition(before, after, null);
        state.* = after;
        return result;
    };
    // 시각 상태는 바뀌지 않는다(focus 그대로). action만 낸다.
    return try finishTransition(before, before, current.id);
}

/// A surface lifetime boundary. Unlike a tree replacement, deactivation also discards focus and
/// hover so a numeric ID in a future surface cannot inherit visual state from the retired one.
pub fn deactivate(state: *InteractionState) InteractionError!Dispatch {
    const before = state.*;
    const after = InteractionState{};
    const result = try finishTransition(before, after, null);
    state.* = after;
    return result;
}

const HitAction = struct {
    id: UiId,
    action_id: UiActionId,
};

fn hitAction(snapshot: UiRectTree, x_px: f64, y_px: f64) ?HitAction {
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;

    var index = snapshot.entries.len;
    while (index > 0) {
        index -= 1;
        const rect_entry = snapshot.entries[index];
        const action = rect_entry.action orelse continue;
        if (!action.enabled) continue;
        if (!containsPoint(rect_entry.rect, x_px, y_px)) continue;
        if (rect_entry.effective_clip) |clip| {
            if (!containsPoint(clip, x_px, y_px)) continue;
        }
        return .{ .id = rect_entry.id, .action_id = action.id };
    }
    return null;
}

fn enabledActionForId(snapshot: UiRectTree, id: UiId) ?ui_tree.UiAction {
    const index = snapshot.find(id) orelse return null;
    const action = snapshot.entries[index].action orelse return null;
    return if (action.enabled) action else null;
}

fn containsPoint(rect: layout.UiRect, x_px: f64, y_px: f64) bool {
    const x = @as(f64, rect.x);
    const y = @as(f64, rect.y);
    const width = @as(f64, rect.width);
    const height = @as(f64, rect.height);
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(width) or !std.math.isFinite(height)) return false;
    if (width <= 0 or height <= 0) return false;
    const right = x + width;
    const bottom = y + height;
    return std.math.isFinite(right) and std.math.isFinite(bottom) and x <= x_px and x_px < right and y <= y_px and y_px < bottom;
}

fn finishTransition(before: InteractionState, after: InteractionState, action: ?UiActionId) InteractionError!Dispatch {
    var dirty = DirtySet{};
    try addChanged(&dirty, before.hovered, after.hovered);
    try addChanged(&dirty, before.focused, after.focused);
    try addChanged(&dirty, captureId(before.capture), captureId(after.capture));
    return .{ .action = action, .dirty = dirty };
}

fn addChanged(dirty: *DirtySet, before: ?UiId, after: ?UiId) InteractionError!void {
    if (before == after) return;
    try dirty.add(before);
    try dirty.add(after);
}

fn captureId(capture: ?Capture) ?UiId {
    return if (capture) |value| value.id else null;
}

fn rectTree(entries: []const ui_tree.RectEntry) UiRectTree {
    return .{ .entries = entries };
}

fn entry(id: UiId, rect: layout.UiRect, action: ?ui_tree.UiAction, clip: ?layout.UiRect) ui_tree.RectEntry {
    return .{ .id = id, .parent_index = null, .kind = .card, .rect = rect, .effective_clip = clip, .action = action };
}

fn expectDirty(actual: DirtySet, expected: []const UiId) !void {
    for (actual.ids, 0..) |value, index| {
        const actual_id = value orelse {
            try std.testing.expect(index >= expected.len);
            continue;
        };
        try std.testing.expect(index < expected.len);
        try std.testing.expectEqual(expected[index], actual_id);
    }
}

test "hit test uses reverse z-order, rect, and effective clip" {
    const entries = [_]ui_tree.RectEntry{
        entry(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .id = 10 }, null),
        entry(2, .{ .x = 5, .y = 5, .width = 20, .height = 20 }, .{ .id = 20 }, .{ .x = 5, .y = 5, .width = 5, .height = 5 }),
    };
    var state = InteractionState{};

    const overlap = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 7, .y_px = 7, .timestamp_ns = 1 });
    try std.testing.expectEqual(@as(?UiId, 2), state.hovered);
    try expectDirty(overlap.dirty, &.{2});

    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 12, .y_px = 12, .timestamp_ns = 2 });
    try std.testing.expectEqual(@as(?UiId, 1), state.hovered);

    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 40, .y_px = 12, .timestamp_ns = 3 });
    try std.testing.expectEqual(@as(?UiId, null), state.hovered);

    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = std.math.nan(f64), .y_px = 1, .timestamp_ns = 4 });
    try std.testing.expectEqual(@as(?UiId, null), state.hovered);
}

test "inert text does not block its actionable card ancestor" {
    const entries = [_]ui_tree.RectEntry{
        entry(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .id = 10 }, null),
        .{
            .id = 2,
            .parent_index = 0,
            .kind = .text,
            .rect = .{ .x = 2, .y = 2, .width = 12, .height = 12 },
            .effective_clip = null,
            .action = null,
        },
    };
    var state = InteractionState{};
    const down = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 4, .y_px = 4, .timestamp_ns = 1 });
    try std.testing.expectEqual(@as(?Capture, .{ .id = 1, .action_id = 10 }), state.capture);
    try std.testing.expectEqual(@as(?UiActionId, null), down.action);
}

test "hover transition marks old and new rect, and left down marks focus and capture" {
    const entries = [_]ui_tree.RectEntry{
        entry(1, .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .{ .id = 10 }, null),
        entry(2, .{ .x = 10, .y = 0, .width = 10, .height = 10 }, .{ .id = 20 }, null),
    };
    var state = InteractionState{};
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 2, .y_px = 2, .timestamp_ns = 1 });

    const move = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 12, .y_px = 2, .timestamp_ns = 2 });
    try expectDirty(move.dirty, &.{ 1, 2 });

    const unchanged_move = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 12, .y_px = 2, .timestamp_ns = 3 });
    try expectDirty(unchanged_move.dirty, &.{});

    const down = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 2, .y_px = 2, .timestamp_ns = 4 });
    try std.testing.expectEqual(@as(?UiId, 1), state.hovered);
    try std.testing.expectEqual(@as(?UiId, 1), state.focused);
    try std.testing.expectEqual(@as(?Capture, .{ .id = 1, .action_id = 10 }), state.capture);
    try expectDirty(down.dirty, &.{ 2, 1 });
}

test "capture delivers outside left up only while action identity remains enabled" {
    const entries = [_]ui_tree.RectEntry{
        entry(1, .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .{ .id = 10 }, null),
        entry(2, .{ .x = 20, .y = 0, .width = 10, .height = 10 }, .{ .id = 20 }, null),
    };
    var state = InteractionState{};
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 2, .y_px = 2, .timestamp_ns = 1 });
    const up = try dispatch(&state, rectTree(&entries), .{ .phase = .up, .x_px = 25, .y_px = 2, .timestamp_ns = 2 });
    try std.testing.expectEqual(@as(?UiActionId, 10), up.action);
    try std.testing.expectEqual(@as(?UiId, 2), state.hovered);
    try std.testing.expectEqual(@as(?Capture, null), state.capture);

    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 2, .y_px = 2, .timestamp_ns = 3 });
    const disabled_entries = [_]ui_tree.RectEntry{
        entry(1, .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .{ .id = 10, .enabled = false }, null),
        entries[1],
    };
    const stale = try dispatch(&state, rectTree(&disabled_entries), .{ .phase = .up, .x_px = 25, .y_px = 2, .timestamp_ns = 4 });
    try std.testing.expectEqual(@as(?UiActionId, null), stale.action);

    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 2, .y_px = 2, .timestamp_ns = 5 });
    const changed_action_entries = [_]ui_tree.RectEntry{
        entry(1, .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .{ .id = 99 }, null),
        entries[1],
    };
    const changed_action = try dispatch(&state, rectTree(&changed_action_entries), .{ .phase = .up, .x_px = 25, .y_px = 2, .timestamp_ns = 6 });
    try std.testing.expectEqual(@as(?UiActionId, null), changed_action.action);
}

test "snapshot reconcile and deactivation cancel capture and stale state" {
    const old_entries = [_]ui_tree.RectEntry{
        entry(1, .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .{ .id = 10 }, null),
    };
    const new_entries = [_]ui_tree.RectEntry{
        entry(1, .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .{ .id = 10 }, null),
    };
    var state = InteractionState{};
    _ = try dispatch(&state, rectTree(&old_entries), .{ .phase = .down, .x_px = 2, .y_px = 2, .timestamp_ns = 1 });

    const reconcile_result = try reconcile(&state, rectTree(&old_entries), rectTree(&new_entries));
    try std.testing.expectEqual(@as(?Capture, null), state.capture);
    try expectDirty(reconcile_result.dirty, &.{1});
    const stale_up = try dispatch(&state, rectTree(&new_entries), .{ .phase = .up, .x_px = 2, .y_px = 2, .timestamp_ns = 2 });
    try std.testing.expectEqual(@as(?UiActionId, null), stale_up.action);

    const deactivated = try deactivate(&state);
    try std.testing.expectEqual(InteractionState{}, state);
    try expectDirty(deactivated.dirty, &.{1});
}

test "second down cancels predecessor and right up cannot release left capture" {
    const entries = [_]ui_tree.RectEntry{
        entry(1, .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .{ .id = 10 }, null),
        entry(2, .{ .x = 10, .y = 0, .width = 10, .height = 10 }, .{ .id = 20 }, null),
    };
    var state = InteractionState{};
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 2, .y_px = 2, .timestamp_ns = 1 });
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .up, .x_px = 2, .y_px = 2, .button = .right, .timestamp_ns = 2 });
    try std.testing.expectEqual(@as(?Capture, .{ .id = 1, .action_id = 10 }), state.capture);

    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 12, .y_px = 2, .timestamp_ns = 3 });
    try std.testing.expectEqual(@as(?Capture, .{ .id = 2, .action_id = 20 }), state.capture);
    const up = try dispatch(&state, rectTree(&entries), .{ .phase = .up, .x_px = 12, .y_px = 2, .timestamp_ns = 4 });
    try std.testing.expectEqual(@as(?UiActionId, 20), up.action);
}

test "keyboard activation matches a pointer click and refuses what a click would refuse" {
    const entries = [_]ui_tree.RectEntry{
        entry(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .id = 10 }, null),
        entry(2, .{ .x = 30, .y = 0, .width = 20, .height = 20 }, .{ .id = 20, .enabled = false }, null),
    };
    const snapshot = rectTree(&entries);

    // focus가 없으면 키는 아무것도 하지 않는다 — 마지막에 눌린 것을 기억해 실행하지 않는다.
    var state = InteractionState{};
    const no_focus = try activateFocused(&state, snapshot);
    try std.testing.expect(no_focus.action == null);

    // pointer down이 focus를 남기고, 같은 rect에서 키가 같은 action을 낸다(parity).
    _ = try dispatch(&state, snapshot, .{ .phase = .down, .x_px = 5, .y_px = 5, .timestamp_ns = 1 });
    _ = try dispatch(&state, snapshot, .{ .phase = .up, .x_px = 5, .y_px = 5, .timestamp_ns = 2 });
    try std.testing.expectEqual(@as(?UiId, 1), state.focused);
    const activated = try activateFocused(&state, snapshot);
    try std.testing.expectEqual(@as(?UiActionId, 10), activated.action);
    // 시각 상태는 그대로다 — 키 실행이 focus를 옮기거나 hover를 만들지 않는다.
    try std.testing.expectEqual(@as(?UiId, 1), state.focused);

    // pointer로 누르고 있는 중이면 키가 끼어들지 못한다(§4.3 — 한 stream에 owner 하나).
    _ = try dispatch(&state, snapshot, .{ .phase = .down, .x_px = 5, .y_px = 5, .timestamp_ns = 3 });
    try std.testing.expect(state.capture != null);
    const during_capture = try activateFocused(&state, snapshot);
    try std.testing.expect(during_capture.action == null);
    _ = try dispatch(&state, snapshot, .{ .phase = .cancel, .x_px = 5, .y_px = 5, .timestamp_ns = 4 });

    // disabled는 click intent가 될 수 없다 — 키도 마찬가지다. focus 자체가 붙지 않는다.
    _ = try dispatch(&state, snapshot, .{ .phase = .down, .x_px = 35, .y_px = 5, .timestamp_ns = 5 });
    try std.testing.expectEqual(@as(?UiId, 1), state.focused);
}

test "keyboard activation revalidates against the current tree, not the focused past" {
    const enabled = [_]ui_tree.RectEntry{
        entry(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .id = 10 }, null),
    };
    var state = InteractionState{};
    _ = try dispatch(&state, rectTree(&enabled), .{ .phase = .down, .x_px = 5, .y_px = 5, .timestamp_ns = 1 });
    _ = try dispatch(&state, rectTree(&enabled), .{ .phase = .up, .x_px = 5, .y_px = 5, .timestamp_ns = 2 });
    try std.testing.expectEqual(@as(?UiId, 1), state.focused);

    // 같은 id가 disabled로 바뀐 tree에서는 키가 실행되지 않고 focus도 비운다 — 유령 대상을 다음
    // 키가 다시 겨냥하지 않게 한다. pointer up이 stale action을 거부하는 것과 같은 규율이다.
    const disabled = [_]ui_tree.RectEntry{
        entry(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .id = 10, .enabled = false }, null),
    };
    const refused = try activateFocused(&state, rectTree(&disabled));
    try std.testing.expect(refused.action == null);
    try std.testing.expect(state.focused == null);

    // node가 통째로 사라진 경우도 같다.
    var gone_state = InteractionState{};
    _ = try dispatch(&gone_state, rectTree(&enabled), .{ .phase = .down, .x_px = 5, .y_px = 5, .timestamp_ns = 3 });
    _ = try dispatch(&gone_state, rectTree(&enabled), .{ .phase = .up, .x_px = 5, .y_px = 5, .timestamp_ns = 4 });
    const empty = [_]ui_tree.RectEntry{};
    const vanished = try activateFocused(&gone_state, rectTree(&empty));
    try std.testing.expect(vanished.action == null);
    try std.testing.expect(gone_state.focused == null);
}
