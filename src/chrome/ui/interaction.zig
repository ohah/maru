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
    /// 이 이벤트가 겨냥한 published snapshot 세대. host가 이벤트를 만들 때 그 시점의 tree 세대를
    /// 싣는다. 0은 "세대를 쓰지 않는다"이며 그때는 검사가 비활성이다 — click-only 소비자는 그대로
    /// 쓰고, drag를 다루는 소비자만 세대를 채운다.
    generation: u64 = 0,
};

/// Drag 축과 선언은 `ui/tree.zig`가 소유한다 — published entry와 여기가 같은 타입을 써야 둘이
/// 갈리지 않는다. payload는 host의 intent table에서만 domain intent로 풀리는 opaque ID다.
pub const DragAxis = ui_tree.DragAxis;
pub const DragDeclaration = ui_tree.DragDeclaration;

/// 진행 중인 drag의 수명. `started`가 false인 동안은 아직 click 후보다.
pub const DragState = struct {
    payload: u64,
    axis: DragAxis,
    threshold_px: f32,
    origin_x_px: f64,
    origin_y_px: f64,
    last_x_px: f64,
    last_y_px: f64,
    started: bool = false,

    /// 축을 존중한 이동 거리. `free`는 두 축의 큰 쪽을 쓴다(대각선이 두 축 모두에서 threshold를
    /// 넘어야 시작되는 것을 막는다).
    fn travel(self: DragState, x_px: f64, y_px: f64) f64 {
        const dx = @abs(x_px - self.origin_x_px);
        const dy = @abs(y_px - self.origin_y_px);
        return switch (self.axis) {
            .horizontal => dx,
            .vertical => dy,
            .free => @max(dx, dy),
        };
    }
};

pub const Capture = struct {
    id: UiId,
    action_id: UiActionId,
    /// 이 capture가 drag를 선언한 node에서 시작됐다면 그 수명. click-only capture는 null이다.
    drag: ?DragState = null,
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

/// drag 수명에서 이번 이벤트가 만든 변화. host는 이것으로 preview/commit을 정한다 — pure module은
/// 좌표와 payload만 전달하고 무엇을 옮길지는 모른다.
pub const DragEvent = union(enum) {
    /// threshold를 처음 넘었다. host가 preview를 시작한다.
    began: DragUpdate,
    /// 시작된 drag가 움직였다.
    moved: DragUpdate,
    /// up으로 끝났다. host가 현재 tree에 다시 hit-test해 destination을 정하고 한 번 commit한다.
    dropped: DragUpdate,
    /// cancel·stale·비호환 reconcile로 끝났다. effect 0이며 host는 시작 상태를 복원한다.
    cancelled: struct { payload: u64 },
};

pub const DragUpdate = struct {
    payload: u64,
    x_px: f64,
    y_px: f64,
};

pub const Dispatch = struct {
    action: ?UiActionId = null,
    dirty: DirtySet = .{},
    /// click action과 배타적이지 않다 — threshold를 넘지 않은 up은 `action`만, 넘은 up은 `drag`만 낸다.
    drag: ?DragEvent = null,
};

pub const InteractionError = error{DirtySetOverflow};

/// Dispatches one event against the currently published immutable tree. A caller must call
/// `reconcile` before replacing that tree; build failures do not call either function and therefore
/// retain the current interaction state unchanged.
pub fn dispatch(state: *InteractionState, snapshot: UiRectTree, event: UiPointerEvent) InteractionError!Dispatch {
    const before = state.*;
    var after = before;
    var action: ?UiActionId = null;
    var drag: ?DragEvent = null;

    // 이벤트가 겨냥한 세대가 지금 published 세대와 다르면 이 tree에 대한 판정이 아니다. 진행 중이던
    // capture는 effect 없이 취소하고 이벤트는 버린다 — 이전 tree를 보고 누른 up이 새 action을
    // 실행하지 못하게 하는 §5의 규율을 pointer 입구에서 한 번 더 세운다.
    if (event.generation != 0 and snapshot.generation != 0 and event.generation != snapshot.generation) {
        if (after.capture) |capture| {
            if (capture.drag) |d| drag = .{ .cancelled = .{ .payload = d.payload } };
        }
        after.capture = null;
        const stale = try finishTransition(before, after, null);
        state.* = after;
        return .{ .action = null, .dirty = stale.dirty, .drag = drag };
    }

    switch (event.phase) {
        .move => {
            if (after.capture) |*capture| {
                if (capture.drag) |*d| {
                    d.last_x_px = event.x_px;
                    d.last_y_px = event.y_px;
                    const update = DragUpdate{ .payload = d.payload, .x_px = event.x_px, .y_px = event.y_px };
                    if (d.started) {
                        drag = .{ .moved = update };
                    } else if (d.travel(event.x_px, event.y_px) >= @as(f64, d.threshold_px)) {
                        d.started = true;
                        drag = .{ .began = update };
                    }
                }
            } else {
                after.hovered = if (hitAction(snapshot, event.x_px, event.y_px)) |value| value.id else null;
            }
        },
        .down => {
            // The protocol has no pointer ID. A second down is a new primary sequence, so its
            // predecessor cannot remain pressed or later receive a stale up action.
            if (after.capture) |capture| {
                if (capture.drag) |d| drag = .{ .cancelled = .{ .payload = d.payload } };
            }
            after.capture = null;
            if (event.button == .left) {
                const target = hitAction(snapshot, event.x_px, event.y_px);
                after.hovered = if (target) |value| value.id else null;
                if (target) |value| {
                    after.focused = value.id;
                    after.capture = .{
                        .id = value.id,
                        .action_id = value.action_id,
                        .drag = if (value.drag) |decl| .{
                            .payload = decl.payload,
                            .axis = decl.axis,
                            .threshold_px = decl.threshold_px,
                            .origin_x_px = event.x_px,
                            .origin_y_px = event.y_px,
                            .last_x_px = event.x_px,
                            .last_y_px = event.y_px,
                        } else null,
                    };
                }
            }
        },
        .up => {
            if (event.button == .left) {
                const previous_capture = after.capture;
                after.capture = null;
                after.hovered = if (hitAction(snapshot, event.x_px, event.y_px)) |value| value.id else null;
                if (previous_capture) |capture| {
                    // 시작된 drag의 up은 drop이지 click이 아니다. threshold를 넘지 않았으면 여전히
                    // click이며, 그 판정은 현재 action table을 다시 통과해야 한다.
                    if (capture.drag) |d| {
                        if (d.started) {
                            drag = .{ .dropped = .{ .payload = d.payload, .x_px = event.x_px, .y_px = event.y_px } };
                        }
                    }
                    if (drag == null) {
                        if (enabledActionForId(snapshot, capture.id)) |current_action| {
                            if (current_action.id == capture.action_id) action = capture.action_id;
                        }
                    }
                }
            }
        },
        .cancel => {
            if (after.capture) |capture| {
                if (capture.drag) |d| drag = .{ .cancelled = .{ .payload = d.payload } };
            }
            after.capture = null;
            after.hovered = if (hitAction(snapshot, event.x_px, event.y_px)) |value| value.id else null;
        },
    }

    var result = try finishTransition(before, after, action);
    result.drag = drag;
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

/// `gesture compatibility key` — capture를 다음 snapshot으로 넘겨도 되는지 판정하는 입력.
///
/// 네 요소 중 **epoch와 domain identity는 neutral chrome이 모른다**. `InteractionState`는 `UiId`만
/// 알기 때문에, host가 그 둘을 opaque 값으로 주입하고 이 모듈은 **같은지만** 비교한다. 그 값이
/// 무엇을 뜻하는지 해석하는 쪽은 계속 host다(docs/chrome-interaction-migration.md §5).
pub const GestureCompatibility = struct {
    /// drag payload 등 gesture의 종류. 같은 node라도 종류가 바뀌면 다른 gesture다.
    kind: u64,
    /// action이 여전히 활성인가. disabled로 바뀐 target은 carry하지 않는다.
    enabled: bool,
    /// host가 주는 window/session epoch.
    owner_epoch: u64,
    /// host가 주는 source domain identity(예: 이 drag가 붙은 live 객체).
    domain_identity: u64,

    fn eql(self: GestureCompatibility, other: GestureCompatibility) bool {
        return self.kind == other.kind and self.enabled == other.enabled and
            self.owner_epoch == other.owner_epoch and self.domain_identity == other.domain_identity;
    }
};

/// Tree replacement에서 capture를 **명시적으로** 이어가는 경로.
///
/// 기본 `reconcile`은 언제나 cancel이고 그것이 click의 기본값이다. 그런데 drag와 continuous resize는
/// 매 move마다 tree를 다시 발행하므로, 그 기본값 위에서는 capture가 첫 move에 죽는다. 이 함수는
/// 그때만 쓰는 좁은 문이며, 아래 셋을 **모두** 만족할 때에만 carry한다.
///
///   1. 새 tree에 그 identity가 정확히 하나 있고, 그 node가 여전히 enabled action을 **닿을 수 있는
///      자리에** 가진다 — clip으로 완전히 잘려나간 node는 살아 있다고 보지 않는다.
///   2. host가 준 이전/현재 compatibility key가 같다.
///   3. capture가 drag를 들고 있다(click capture는 carry 대상이 아니다).
///
/// 하나라도 어긋나면 effect 없이 cancel하고 drag는 `cancelled`를 낸다 — "판정을 못 하겠으면
/// 유지하지 않는다"가 이 문의 기본 방향이다.
pub fn reconcileCarryingCapture(
    state: *InteractionState,
    new_tree: UiRectTree,
    previous: GestureCompatibility,
    current: GestureCompatibility,
) InteractionError!Dispatch {
    const before = state.*;
    const capture = before.capture orelse return reconcile(state, new_tree, new_tree);

    const carry = capture.drag != null and
        previous.eql(current) and
        isReachable(new_tree, capture.id) and
        countIdentity(new_tree, capture.id) == 1;

    if (carry) {
        // capture는 그대로 두고 hover/focus만 새 tree로 정리한다.
        var after = before;
        if (after.hovered) |id| {
            if (enabledActionForId(new_tree, id) == null) after.hovered = null;
        }
        if (after.focused) |id| {
            if (enabledActionForId(new_tree, id) == null) after.focused = null;
        }
        const kept = try finishTransition(before, after, null);
        state.* = after;
        return kept;
    }

    var result = try reconcile(state, new_tree, new_tree);
    if (capture.drag) |d| result.drag = .{ .cancelled = .{ .payload = d.payload } };
    return result;
}

/// 그 identity가 새 tree에서 여전히 **닿을 수 있는가**. enabled 여부만으로는 부족하다 — 스크롤
/// 밖으로 나가 clip이 rect를 완전히 잘라낸 node는 pointer가 도달할 수 없고, 그 위에서 drag를
/// 계속 이어가면 보이지 않는 대상을 끌게 된다.
fn isReachable(snapshot: UiRectTree, id: UiId) bool {
    const index = snapshot.find(id) orelse return false;
    const candidate = snapshot.entries[index];
    const action = candidate.action orelse return false;
    if (!action.enabled) return false;
    if (!hasArea(candidate.rect)) return false;
    const clip = candidate.effective_clip orelse return true;
    return hasArea(clip) and intersects(candidate.rect, clip);
}

fn hasArea(rect: layout.UiRect) bool {
    const width = @as(f64, rect.width);
    const height = @as(f64, rect.height);
    if (!std.math.isFinite(width) or !std.math.isFinite(height)) return false;
    return width > 0 and height > 0;
}

fn intersects(a: layout.UiRect, b: layout.UiRect) bool {
    const a_x = @as(f64, a.x);
    const a_y = @as(f64, a.y);
    const b_x = @as(f64, b.x);
    const b_y = @as(f64, b.y);
    if (!std.math.isFinite(a_x) or !std.math.isFinite(a_y) or !std.math.isFinite(b_x) or !std.math.isFinite(b_y)) return false;
    const a_right = a_x + @as(f64, a.width);
    const a_bottom = a_y + @as(f64, a.height);
    const b_right = b_x + @as(f64, b.width);
    const b_bottom = b_y + @as(f64, b.height);
    return a_x < b_right and b_x < a_right and a_y < b_bottom and b_y < a_bottom;
}

fn countIdentity(snapshot: UiRectTree, id: UiId) usize {
    var count: usize = 0;
    for (snapshot.entries) |candidate| {
        if (candidate.id == id) count += 1;
    }
    return count;
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
    /// 이 node가 drag를 선언했다면 그 능력. 선언은 published entry가 싣고 pure module은 그대로 옮긴다.
    drag: ?DragDeclaration = null,
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
        return .{ .id = rect_entry.id, .action_id = action.id, .drag = rect_entry.drag };
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

fn draggableEntry(
    id: UiId,
    rect: layout.UiRect,
    action: ui_tree.UiAction,
    decl: ui_tree.DragDeclaration,
) ui_tree.RectEntry {
    return .{
        .id = id,
        .parent_index = null,
        .kind = .card,
        .rect = rect,
        .effective_clip = null,
        .action = action,
        .drag = decl,
    };
}

fn generationTree(entries: []const ui_tree.RectEntry, generation: u64) UiRectTree {
    return .{ .entries = entries, .generation = generation };
}

test "an event aimed at another generation decides nothing and leaves no capture behind" {
    const entries = [_]ui_tree.RectEntry{
        draggableEntry(1, .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .{ .id = 10 }, .{ .payload = 77 }),
    };
    var state = InteractionState{};
    _ = try dispatch(&state, generationTree(&entries, 5), .{ .phase = .down, .x_px = 2, .y_px = 2, .timestamp_ns = 1, .generation = 5 });
    try std.testing.expect(state.capture != null);

    // 이전 tree를 보고 눌렀다 뗀 up. action을 내지 않고, 들고 있던 drag는 cancel로 닫는다.
    const stale = try dispatch(&state, generationTree(&entries, 6), .{ .phase = .up, .x_px = 2, .y_px = 2, .timestamp_ns = 2, .generation = 5 });
    try std.testing.expectEqual(@as(?UiActionId, null), stale.action);
    try std.testing.expectEqual(@as(u64, 77), stale.drag.?.cancelled.payload);
    try std.testing.expectEqual(@as(?Capture, null), state.capture);

    // 세대를 아무도 말하지 않으면(둘 중 하나가 0) 게이트는 열려 있다 — 아직 세대를 싣지 않는
    // 소비자를 이 게이트가 통째로 막아버리지 않게 하는 완화다.
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 2, .y_px = 2, .timestamp_ns = 3, .generation = 9 });
    try std.testing.expect(state.capture != null);
}

test "a drag begins only past its threshold, and only along its declared axis" {
    const entries = [_]ui_tree.RectEntry{
        draggableEntry(1, .{ .x = 0, .y = 0, .width = 40, .height = 40 }, .{ .id = 10 }, .{ .payload = 77, .axis = .horizontal, .threshold_px = 4 }),
    };
    var state = InteractionState{};
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 10, .y_px = 10, .timestamp_ns = 1 });

    // 선언한 축과 직교하는 이동은 아무리 커도 drag를 시작시키지 않는다.
    const vertical = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 10, .y_px = 34, .timestamp_ns = 2 });
    try std.testing.expect(vertical.drag == null);

    const under = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 13, .y_px = 34, .timestamp_ns = 3 });
    try std.testing.expect(under.drag == null);

    const began = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 14, .y_px = 34, .timestamp_ns = 4 });
    try std.testing.expectEqual(@as(u64, 77), began.drag.?.began.payload);

    // 시작한 뒤로는 threshold를 다시 묻지 않는다. origin 근처로 돌아와도 moved다.
    const back = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 10, .y_px = 10, .timestamp_ns = 5 });
    try std.testing.expectEqual(@as(u64, 77), back.drag.?.moved.payload);
}

test "a started drag ends in drop, and an unstarted one is still a click" {
    const entries = [_]ui_tree.RectEntry{
        draggableEntry(1, .{ .x = 0, .y = 0, .width = 40, .height = 40 }, .{ .id = 10 }, .{ .payload = 77 }),
    };
    var state = InteractionState{};

    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 10, .y_px = 10, .timestamp_ns = 1 });
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 30, .y_px = 10, .timestamp_ns = 2 });
    const dropped = try dispatch(&state, rectTree(&entries), .{ .phase = .up, .x_px = 30, .y_px = 12, .timestamp_ns = 3 });
    // drop은 click이 아니다. 둘 다 내면 소비자가 한 제스처를 두 번 실행한다.
    try std.testing.expectEqual(@as(?UiActionId, null), dropped.action);
    try std.testing.expectEqual(@as(u64, 77), dropped.drag.?.dropped.payload);
    try std.testing.expectEqual(@as(f64, 30), dropped.drag.?.dropped.x_px);

    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 10, .y_px = 10, .timestamp_ns = 4 });
    const clicked = try dispatch(&state, rectTree(&entries), .{ .phase = .up, .x_px = 11, .y_px = 10, .timestamp_ns = 5 });
    try std.testing.expectEqual(@as(?UiActionId, 10), clicked.action);
    try std.testing.expect(clicked.drag == null);

    // cancel과 두 번째 down은 진행 중이던 drag를 열린 채 두지 않는다.
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 10, .y_px = 10, .timestamp_ns = 6 });
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 30, .y_px = 10, .timestamp_ns = 7 });
    const cancelled = try dispatch(&state, rectTree(&entries), .{ .phase = .cancel, .x_px = 30, .y_px = 10, .timestamp_ns = 8 });
    try std.testing.expectEqual(@as(u64, 77), cancelled.drag.?.cancelled.payload);

    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 10, .y_px = 10, .timestamp_ns = 9 });
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 30, .y_px = 10, .timestamp_ns = 10 });
    const superseded = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 10, .y_px = 10, .timestamp_ns = 11 });
    try std.testing.expectEqual(@as(u64, 77), superseded.drag.?.cancelled.payload);
}

test "carrying a capture across trees needs the same key, one identity, and a live action" {
    const entries = [_]ui_tree.RectEntry{
        draggableEntry(1, .{ .x = 0, .y = 0, .width = 40, .height = 40 }, .{ .id = 10 }, .{ .payload = 77 }),
    };
    const key = GestureCompatibility{ .kind = 77, .enabled = true, .owner_epoch = 3, .domain_identity = 42 };

    var state = InteractionState{};
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 10, .y_px = 10, .timestamp_ns = 1 });
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 30, .y_px = 10, .timestamp_ns = 2 });

    // 매 move마다 tree를 다시 발행해도 drag가 살아남는다 — 기본 reconcile로는 여기서 죽는다.
    const carried = try reconcileCarryingCapture(&state, rectTree(&entries), key, key);
    try std.testing.expect(carried.drag == null);
    try std.testing.expectEqual(@as(?UiId, 1), state.capture.?.id);
    try std.testing.expect(state.capture.?.drag.?.started);

    // epoch가 바뀌면(창이 바뀌면) carry하지 않는다.
    var moved_epoch = key;
    moved_epoch.owner_epoch = 4;
    const across_windows = try reconcileCarryingCapture(&state, rectTree(&entries), key, moved_epoch);
    try std.testing.expectEqual(@as(u64, 77), across_windows.drag.?.cancelled.payload);
    try std.testing.expectEqual(@as(?Capture, null), state.capture);

    // 같은 identity가 새 tree에 둘이면 어느 쪽을 끌고 있었는지 판정할 수 없다 — 유지하지 않는다.
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 10, .y_px = 10, .timestamp_ns = 3 });
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 30, .y_px = 10, .timestamp_ns = 4 });
    const twins = [_]ui_tree.RectEntry{
        entries[0],
        draggableEntry(1, .{ .x = 60, .y = 0, .width = 40, .height = 40 }, .{ .id = 10 }, .{ .payload = 77 }),
    };
    const ambiguous = try reconcileCarryingCapture(&state, rectTree(&twins), key, key);
    try std.testing.expectEqual(@as(u64, 77), ambiguous.drag.?.cancelled.payload);

    // 사이에 disabled로 바뀐 target도 마찬가지다.
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 10, .y_px = 10, .timestamp_ns = 5 });
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 30, .y_px = 10, .timestamp_ns = 6 });
    const disabled = [_]ui_tree.RectEntry{
        draggableEntry(1, .{ .x = 0, .y = 0, .width = 40, .height = 40 }, .{ .id = 10, .enabled = false }, .{ .payload = 77 }),
    };
    const dead = try reconcileCarryingCapture(&state, rectTree(&disabled), key, key);
    try std.testing.expectEqual(@as(u64, 77), dead.drag.?.cancelled.payload);
}

test "a target scrolled out from under its clip is not carried" {
    const key = GestureCompatibility{ .kind = 77, .enabled = true, .owner_epoch = 3, .domain_identity = 42 };
    const entries = [_]ui_tree.RectEntry{
        draggableEntry(1, .{ .x = 0, .y = 0, .width = 40, .height = 40 }, .{ .id = 10 }, .{ .payload = 77 }),
    };

    var state = InteractionState{};
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 10, .y_px = 10, .timestamp_ns = 1 });
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 30, .y_px = 10, .timestamp_ns = 2 });

    // action은 그대로 enabled다. 달라진 것은 clip이 rect를 완전히 벗어났다는 것뿐이며,
    // 그것만으로 이 target은 더 이상 닿을 수 없다.
    var clipped = entries;
    clipped[0].effective_clip = .{ .x = 200, .y = 200, .width = 40, .height = 40 };
    const gone = try reconcileCarryingCapture(&state, rectTree(&clipped), key, key);
    try std.testing.expectEqual(@as(u64, 77), gone.drag.?.cancelled.payload);
    try std.testing.expectEqual(@as(?Capture, null), state.capture);

    // 빈 clip(면적 0)도 같다.
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 10, .y_px = 10, .timestamp_ns = 3 });
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 30, .y_px = 10, .timestamp_ns = 4 });
    var collapsed = entries;
    collapsed[0].effective_clip = .{ .x = 0, .y = 0, .width = 0, .height = 40 };
    const empty = try reconcileCarryingCapture(&state, rectTree(&collapsed), key, key);
    try std.testing.expectEqual(@as(u64, 77), empty.drag.?.cancelled.payload);

    // 부분적으로만 잘린 것은 여전히 닿을 수 있다 — 보이는 부분이 남아 있으면 유지한다.
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 10, .y_px = 10, .timestamp_ns = 5 });
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .move, .x_px = 30, .y_px = 10, .timestamp_ns = 6 });
    var partial = entries;
    partial[0].effective_clip = .{ .x = 20, .y = 0, .width = 40, .height = 40 };
    const kept = try reconcileCarryingCapture(&state, rectTree(&partial), key, key);
    try std.testing.expect(kept.drag == null);
    try std.testing.expectEqual(@as(?UiId, 1), state.capture.?.id);
}

test "a click capture is not carried, because only continuous gestures republish mid-stream" {
    const entries = [_]ui_tree.RectEntry{
        entry(1, .{ .x = 0, .y = 0, .width = 40, .height = 40 }, .{ .id = 10 }, null),
    };
    const key = GestureCompatibility{ .kind = 0, .enabled = true, .owner_epoch = 3, .domain_identity = 42 };

    var state = InteractionState{};
    _ = try dispatch(&state, rectTree(&entries), .{ .phase = .down, .x_px = 10, .y_px = 10, .timestamp_ns = 1 });

    // drag 선언이 없는 capture는 이 좁은 문의 대상이 아니다 — 기본값인 cancel이 그대로 적용된다.
    const result = try reconcileCarryingCapture(&state, rectTree(&entries), key, key);
    try std.testing.expect(result.drag == null);
    try std.testing.expectEqual(@as(?Capture, null), state.capture);
}
