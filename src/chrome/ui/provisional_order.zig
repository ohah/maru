//! Provisional live reorder — CIM4.
//!
//! 탭 drag는 인접 탭의 자리를 **즉시 바꿔 보인다**. 그 preview를 model을 직접 회전해 만들면 취소할
//! 자리가 없다 — 중간에 Escape를 눌러도 되돌릴 시작 순서를 아무도 들고 있지 않다.
//!
//! 이 모듈은 그 preview를 model 밖으로 꺼낸다. 시작 순서를 transaction으로 보관하고, drag 중
//! 보이는 순서는 여기서 파생한 배열이며, model commit은 up 한 번뿐이다(이관 계약 §4.4).
//!
//! **소비자**: terminal tab drag(`app_session.dragTabTo`/`commitTabDragOrder` — `pane.terms`) 하나뿐이다.
//!
//! 사이드바 워크스페이스 카드는 이 모듈을 쓰지 **않지만 영구 live reorder도 아니다**. SG8d/SG8e에서 이미
//! 자체 고스트 프리뷰로 옮겼다 — `sidebar_ops.cardDropPlan`/`groupDragPreviewFrame`이 매 move마다
//! `tab_ops.simulateDrop`으로 arena에 가상 배치를 만들어 `sidebar_preview_rows`에만 투영하므로 드래그 내내
//! `self.tabs`는 불변이고, `moveTab`은 up의 `commitSidebarDragPreview`에서 **1회만** 돈다. 즉 §4.3의
//! "preview는 source layout을 mutation하지 않는다"를 두 소비자가 서로 다른 구현으로 이미 지키고 있다.
//!
//! **두 preview는 합치지 않는다.** 이 모듈은 flat `[]u64` 순열이라 "누가 몇 번째냐"만 표현한다. 사이드바는
//! 그룹 subtree를 블록으로 옮기면서 중첩 depth와 `top_level` 전이를 함께 투영해야 해서
//! (`VirtualLayout{ order, group_depth, top_level }`) 순열 하나로는 표현되지 않는다. CIM5가 사이드바에서
//! 옮길 몫은 preview 기계가 아니라 **capture 소유**(`PointerGestureOwner.sidebar_tab`/`sidebar_group` →
//! `InteractionState`)와 **손수 hit-test**(`components/sidebar.slotAt`/`dragTargetSlot`) 쪽이다.
//!
//! **clamp는 주입받는다.** pin 그룹 경계 같은 제약은 domain 상수라 host가 소유한다
//! (`app_session.clampMoveToGroup`). 그것을 모르면 preview가 commit할 수 없는 자리를 보여주고,
//! 손을 떼는 순간 탭이 튄다. `chrome/ui/button.zig`의 icon 등록 predicate와 같은 주입 선례다.
//! 다만 pin은 **워크스페이스 카드 축 전용**이라 terminal tab 소비자는 clamp를 주입하지 않는다
//! (`pane.terms`에는 고정 리전이 없고, 목적지 범위는 `tabbar.Metrics.tabIndex`가 이미 가둔다).

const std = @import("std");

pub const OrderError = error{
    /// 시작 순서와 preview 버퍼의 길이가 다르다. 부분 적용된 중간 순서를 남기지 않는다.
    MismatchedOrderBuffer,
    /// drag 대상이 그 순서 안에 없다.
    UnknownDragSource,
};

/// 목적지를 domain 제약 안으로 당기는 판정. host가 주입한다.
pub const ClampFn = *const fn (context: ?*const anyopaque, from: usize, to: usize) usize;

/// 한 drag 수명 동안만 사는 transaction. `start`는 호출자 소유 버퍼이고 이 모듈은 읽기만 한다.
/// `preview`도 호출자 소유이며 매 move마다 여기서 다시 채운다.
pub const Transaction = struct {
    /// drag 시작 시점의 순서. 복원은 이것을 그대로 되돌리는 것이라 중간 순서가 남지 않는다.
    start: []const u64,
    /// 지금 보이는 순서. paint와 hit-test가 **함께** 이것을 쓴다 — 둘이 갈리면 보이는 자리와
    /// 놓이는 자리가 달라진다.
    preview: []u64,
    /// 끌고 있는 항목의 identity.
    source: u64,
    clamp: ?ClampFn = null,
    clamp_context: ?*const anyopaque = null,

    pub fn init(start: []const u64, preview: []u64, source: u64) OrderError!Transaction {
        if (start.len != preview.len) return error.MismatchedOrderBuffer;
        if (indexOf(start, source) == null) return error.UnknownDragSource;
        @memcpy(preview, start);
        return .{ .start = start, .preview = preview, .source = source };
    }

    /// drag 중 목적지가 바뀌었을 때. **`start`는 건드리지 않는다** — 그것이 복원의 유일한 근거다.
    pub fn moveTo(self: *Transaction, raw_to: usize) void {
        const from = indexOf(self.preview, self.source) orelse return;
        if (raw_to >= self.preview.len) return;
        const to = if (self.clamp) |clamp| clamp(self.clamp_context, from, raw_to) else raw_to;
        if (to >= self.preview.len or to == from) return;
        rotate(self.preview, from, to);
    }

    /// 시작 순서로 되돌린다. Escape·cancel·deactivate·modal 진입·tab 제거·epoch mismatch가 모두
    /// 이 한 경로로 끝나며, transaction 하나를 되돌리는 것이라 부분 적용이 남지 않는다.
    pub fn restore(self: *Transaction) void {
        @memcpy(self.preview, self.start);
    }

    /// 지금 preview가 시작과 다른가. commit이 실제로 할 일이 있는지의 판정이며, 같은 순서면
    /// up에서도 model을 건드리지 않는다(effect 0).
    pub fn changed(self: Transaction) bool {
        return !std.mem.eql(u64, self.start, self.preview);
    }

    /// commit 대상 index. host는 이 값으로 자기 model을 한 번 회전한다.
    pub fn destination(self: Transaction) ?usize {
        return indexOf(self.preview, self.source);
    }
};

fn indexOf(order: []const u64, value: u64) ?usize {
    for (order, 0..) |item, index| {
        if (item == value) return index;
    }
    return null;
}

/// `from`을 빼서 `to`에 끼운다 — 사이 항목들이 한 칸씩 밀린다. 제품 `input_math.rotateMove`와 같은
/// 의미이며, 그것과 갈리면 preview와 commit 결과가 달라진다.
fn rotate(order: []u64, from: usize, to: usize) void {
    const moved = order[from];
    if (from < to) {
        std.mem.copyForwards(u64, order[from..to], order[from + 1 .. to + 1]);
    } else {
        std.mem.copyBackwards(u64, order[to + 1 .. from + 1], order[to..from]);
    }
    order[to] = moved;
}

test "preview moves while the start order stays the transaction's only truth" {
    const start = [_]u64{ 10, 20, 30, 40 };
    var preview: [4]u64 = undefined;
    var tx = try Transaction.init(&start, &preview, 10);

    tx.moveTo(2);
    try std.testing.expectEqualSlices(u64, &.{ 20, 30, 10, 40 }, &preview);
    // start는 그대로다 — 이것이 복원의 유일한 근거다.
    try std.testing.expectEqualSlices(u64, &.{ 10, 20, 30, 40 }, &start);
    try std.testing.expect(tx.changed());
    try std.testing.expectEqual(@as(?usize, 2), tx.destination());

    // 여러 번 움직여도 누적이 아니라 매번 현재 preview 기준이다.
    tx.moveTo(0);
    try std.testing.expectEqualSlices(u64, &.{ 10, 20, 30, 40 }, &preview);
    // 시작과 같아졌으면 commit이 할 일이 없다(effect 0).
    try std.testing.expect(!tx.changed());
}

test "restore returns exactly to the start, leaving no intermediate order" {
    const start = [_]u64{ 1, 2, 3, 4, 5 };
    var preview: [5]u64 = undefined;
    var tx = try Transaction.init(&start, &preview, 4);

    tx.moveTo(0);
    tx.moveTo(4);
    tx.moveTo(1);
    try std.testing.expect(tx.changed());

    // Escape·cancel·deactivate·modal·tab 제거·epoch mismatch가 전부 이 한 경로다.
    tx.restore();
    try std.testing.expectEqualSlices(u64, &start, &preview);
    try std.testing.expect(!tx.changed());
}

const PinContext = struct { pinned_count: usize };

fn clampToPinnedGroup(context: ?*const anyopaque, from: usize, to: usize) usize {
    const ctx: *const PinContext = @ptrCast(@alignCast(context.?));
    // pin된 탭은 앞 그룹 안에서만, 나머지는 뒤 그룹 안에서만 움직인다.
    if (from < ctx.pinned_count) return @min(to, ctx.pinned_count -| 1);
    return @max(to, ctx.pinned_count);
}

test "an injected clamp keeps the preview inside what a commit could produce" {
    const start = [_]u64{ 1, 2, 3, 4, 5 };
    var preview: [5]u64 = undefined;
    const context = PinContext{ .pinned_count = 2 };

    // pin 그룹(앞 2개) 안의 탭은 그 밖으로 나가지 않는다.
    var pinned = try Transaction.init(&start, &preview, 1);
    pinned.clamp = clampToPinnedGroup;
    pinned.clamp_context = &context;
    pinned.moveTo(4);
    try std.testing.expectEqualSlices(u64, &.{ 2, 1, 3, 4, 5 }, &preview);

    // 반대로 일반 탭은 pin 그룹 안으로 들어가지 않는다. clamp가 없으면 preview가 commit할 수 없는
    // 자리를 보여주고, 손을 떼는 순간 탭이 튄다.
    var plain = try Transaction.init(&start, &preview, 5);
    plain.clamp = clampToPinnedGroup;
    plain.clamp_context = &context;
    plain.moveTo(0);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 5, 3, 4 }, &preview);
}

test "the transaction fails closed instead of previewing a partial order" {
    const start = [_]u64{ 1, 2, 3 };
    var short: [2]u64 = undefined;
    try std.testing.expectError(error.MismatchedOrderBuffer, Transaction.init(&start, &short, 1));

    var preview: [3]u64 = undefined;
    try std.testing.expectError(error.UnknownDragSource, Transaction.init(&start, &preview, 99));

    // 범위 밖 목적지는 무동작이다 — 잘라서 끼우면 사용자가 겨냥하지 않은 자리에 놓인다.
    var tx = try Transaction.init(&start, &preview, 2);
    tx.moveTo(99);
    try std.testing.expectEqualSlices(u64, &start, &preview);
}
