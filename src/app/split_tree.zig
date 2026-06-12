const std = @import("std");
const surface_mod = @import("surface.zig");

pub const Surface = surface_mod.Surface;

// SplitTree(panel) 모델. 한 탭은 surface 1개(flat)가 아니라 가로/세로로 나눌 수 있는 surface 트리다
// (단일 출처: docs/tabs-splits-layout.md). 동작은 Ghostty의 SplitTree를 **개념만** 참고하고(MIT,
// 코드 표현 미참고) Zig로 독립 구현한다. 드라이버(네이티브 PTY / tmux pane)와 무관한 순수 모델이다.
//
//   Node = leaf(surface) | split{ direction, ratio, a, b }
//
// leaf는 panel surface 1개. split은 두 자식을 방향(horizontal=좌우, vertical=상하)과 ratio(a의 비율)로
// 나눈다. 탭 = 이 트리의 루트. leaf의 *Surface는 트리가 소유하지 않는다(Tab/session이 heap-pin으로 소유) —
// 트리는 split 노드만 heap 소유한다. 레이아웃·트리 연산은 헤드리스 Zig 단위로 고정한다.

/// split 방향. horizontal = 좌우 분할(a=left, b=right), vertical = 상하 분할(a=top, b=bottom).
pub const SplitDirection = enum { horizontal, vertical };

/// SplitTree 노드 — 단일 panel(leaf) 또는 두 자식 split. 재귀(split의 자식도 Node).
pub const Node = union(enum) {
    leaf: *Surface,
    split: *Split,
};

/// split 노드: 두 자식을 direction과 ratio로 나눈다. ratio는 a(left/top)가 차지하는 비율 [0,1]이며
/// layout이 [0.05, 0.95]로 clamp해 한쪽 panel이 0폭/0높이가 되지 않게 한다. heap 소유(트리 deinit까지).
pub const Split = struct {
    direction: SplitDirection,
    ratio: f32 = 0.5,
    a: Node,
    b: Node,
};

/// 픽셀 사각형(좌상단 origin, backing px). 레이아웃 입력(탭 영역)·출력(각 leaf의 영역).
pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// leaf surface와 그것을 그릴 사각형. 멀티-panel 렌더가 각 surface를 이 rect에 그린다(surface→rect
/// 메커니즘의 일반화 — N개 surface를 sub-사각형에 동시 합성).
pub const LeafRect = struct { surface: *Surface, rect: Rect };

/// ratio가 [0.05, 0.95]를 벗어나지 않게 clamp한 비율로 total을 나눈 a쪽 픽셀(반올림). 한 panel이 0이
/// 되면 grid가 비고 divider 히트가 불가능하므로 막는다.
fn ratioPx(total: u32, ratio: f32) u32 {
    const clamped = std.math.clamp(ratio, 0.05, 0.95);
    const v = @as(f32, @floatFromInt(total)) * clamped;
    return @intFromFloat(@round(v));
}

/// node를 rect 안에서 재귀적으로 sub-rect로 나눠 각 leaf의 (surface, rect)를 out에 채운다(트리 순서대로:
/// a 먼저, b 다음). split은 방향에 따라 폭(horizontal) 또는 높이(vertical)를 ratio로 자른다 — 두 자식 영역의
/// 합은 부모와 같다(틈 없음; divider 간격은 렌더 단계의 후속). 순수 — 유일한 할당은 out append.
pub fn layout(allocator: std.mem.Allocator, node: Node, rect: Rect, out: *std.ArrayList(LeafRect)) !void {
    switch (node) {
        .leaf => |s| try out.append(allocator, .{ .surface = s, .rect = rect }),
        .split => |sp| switch (sp.direction) {
            .horizontal => {
                const a_w = ratioPx(rect.w, sp.ratio);
                try layout(allocator, sp.a, .{ .x = rect.x, .y = rect.y, .w = a_w, .h = rect.h }, out);
                try layout(allocator, sp.b, .{ .x = rect.x + a_w, .y = rect.y, .w = rect.w - a_w, .h = rect.h }, out);
            },
            .vertical => {
                const a_h = ratioPx(rect.h, sp.ratio);
                try layout(allocator, sp.a, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = a_h }, out);
                try layout(allocator, sp.b, .{ .x = rect.x, .y = rect.y + a_h, .w = rect.w, .h = rect.h - a_h }, out);
            },
        },
    }
}

/// 트리의 leaf(panel) 수. split 키 활성/단일-panel 여부 판정 등에 쓴다.
pub fn leafCount(node: Node) usize {
    return switch (node) {
        .leaf => 1,
        .split => |sp| leafCount(sp.a) + leafCount(sp.b),
    };
}

/// split 노드를 재귀적으로 해제한다(leaf의 *Surface는 트리 소유가 아니므로 건드리지 않는다 — Tab/session이
/// 정리). 단일 leaf 트리는 무동작. 트리를 헐 때(탭 close·pane collapse) 호출한다.
pub fn deinit(allocator: std.mem.Allocator, node: Node) void {
    switch (node) {
        .leaf => {},
        .split => |sp| {
            deinit(allocator, sp.a);
            deinit(allocator, sp.b);
            allocator.destroy(sp);
        },
    }
}

/// rect를 direction·ratio로 둘로 나눈 (a, b). horizontal=좌우(폭 분할), vertical=상하(높이 분할). split을
/// '생성'할 때 두 panel의 초기 크기를 정하는 용도로, layout()의 분할 규칙(ratioPx clamp)을 그대로 쓴다 —
/// 같은 트리를 layout()에 넣었을 때 나오는 a/b rect와 일치한다(틈 없음: a.w + b.w == rect.w).
pub fn splitRect(rect: Rect, direction: SplitDirection, ratio: f32) struct { a: Rect, b: Rect } {
    switch (direction) {
        .horizontal => {
            const a_w = ratioPx(rect.w, ratio);
            return .{
                .a = .{ .x = rect.x, .y = rect.y, .w = a_w, .h = rect.h },
                .b = .{ .x = rect.x + a_w, .y = rect.y, .w = rect.w - a_w, .h = rect.h },
            };
        },
        .vertical => {
            const a_h = ratioPx(rect.h, ratio);
            return .{
                .a = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = a_h },
                .b = .{ .x = rect.x, .y = rect.y + a_h, .w = rect.w, .h = rect.h - a_h },
            };
        },
    }
}

/// 트리에서 target surface를 가리키는 leaf를 replacement 노드로 in-place 교체한다(찾으면 true, 없으면
/// false). split 생성 시 '활성 leaf'를 split{a: 기존 leaf, b: 새 leaf} 노드로 바꾸는 데 쓴다. 노드를
/// 직접 변형하므로 루트는 &tab.tree로 넘긴다(루트가 leaf면 tab.tree 자체가 split으로 바뀐다). 트리 순서로
/// 앞선 leaf를 먼저 매치한다 — 같은 surface가 두 번 들어가는 일은 없다(panel은 surface와 1:1).
pub fn replaceLeaf(node: *Node, target: *Surface, replacement: Node) bool {
    switch (node.*) {
        .leaf => |s| {
            if (s == target) {
                node.* = replacement;
                return true;
            }
            return false;
        },
        .split => |sp| {
            if (replaceLeaf(&sp.a, target, replacement)) return true;
            return replaceLeaf(&sp.b, target, replacement);
        },
    }
}

/// node가 target surface leaf를 직접 자식으로 가진 split이면 그 leaf를 떼고 split을 '형제'로 교체한다(찾으면
/// true). 즉 split{a: target_leaf, b: sibling} → sibling(반대도 대칭). pane close 시 트리를 collapse하는
/// replaceLeaf의 역연산이다 — collapse된 split 노드만 heap 해제하고, 형제 subtree(leaf든 split이든)는 부모
/// 슬롯으로 그대로 옮긴다(형제의 *Split은 안 건드림). leaf surface는 트리 소유가 아니라 건드리지 않는다
/// (호출자가 Pane teardown으로 정리). 루트가 단일 leaf면(형제 없음) false — 그건 탭 close가 처리한다.
fn isLeafOf(node: Node, target: *Surface) bool {
    return switch (node) {
        .leaf => |s| s == target,
        .split => false,
    };
}

pub fn removeLeaf(allocator: std.mem.Allocator, node: *Node, target: *Surface) bool {
    switch (node.*) {
        .leaf => return false, // 루트가 leaf면 형제가 없어 트리 레벨에서 못 지운다(탭 close가 처리)
        .split => |sp| {
            // 직접 자식이 target leaf면 이 split을 반대 자식(형제)으로 교체하고 split 노드만 해제.
            if (isLeafOf(sp.a, target)) {
                node.* = sp.b; // 형제를 부모 슬롯으로(Node 값 복사 — 형제가 split이면 그 *Split 보존)
                allocator.destroy(sp);
                return true;
            }
            if (isLeafOf(sp.b, target)) {
                node.* = sp.a;
                allocator.destroy(sp);
                return true;
            }
            // 직접 자식이 아니면 자식 split으로 재귀(중첩 split 안의 leaf).
            if (removeLeaf(allocator, &sp.a, target)) return true;
            return removeLeaf(allocator, &sp.b, target);
        },
    }
}

test "layout: single leaf fills the whole rect" {
    const allocator = std.testing.allocator;
    var s = try Surface.init(allocator, 1, .{ .cols = 4, .rows = 2 });
    defer s.deinit();

    var out: std.ArrayList(LeafRect) = .empty;
    defer out.deinit(allocator);
    try layout(allocator, .{ .leaf = &s }, .{ .x = 10, .y = 20, .w = 200, .h = 100 }, &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(&s, out.items[0].surface);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 200, .h = 100 }, out.items[0].rect);
}

test "layout: horizontal split divides width by ratio, vertical divides height; sums match parent" {
    const allocator = std.testing.allocator;
    var a = try Surface.init(allocator, 1, .{ .cols = 4, .rows = 2 });
    defer a.deinit();
    var b = try Surface.init(allocator, 2, .{ .cols = 4, .rows = 2 });
    defer b.deinit();

    // horizontal 0.5: 폭 200 → a 100 + b 100(좌우), 높이는 둘 다 100.
    var hsplit = Split{ .direction = .horizontal, .ratio = 0.5, .a = .{ .leaf = &a }, .b = .{ .leaf = &b } };
    {
        var out: std.ArrayList(LeafRect) = .empty;
        defer out.deinit(allocator);
        try layout(allocator, .{ .split = &hsplit }, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, &out);
        try std.testing.expectEqual(@as(usize, 2), out.items.len);
        try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, out.items[0].rect); // a(좌)
        try std.testing.expectEqual(Rect{ .x = 100, .y = 0, .w = 100, .h = 100 }, out.items[1].rect); // b(우)
        // 두 폭의 합 = 부모 폭(틈 없음).
        try std.testing.expectEqual(@as(u32, 200), out.items[0].rect.w + out.items[1].rect.w);
    }

    // vertical 0.25: 높이 100 → a 25(상) + b 75(하), 폭은 둘 다 200.
    var vsplit = Split{ .direction = .vertical, .ratio = 0.25, .a = .{ .leaf = &a }, .b = .{ .leaf = &b } };
    {
        var out: std.ArrayList(LeafRect) = .empty;
        defer out.deinit(allocator);
        try layout(allocator, .{ .split = &vsplit }, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, &out);
        try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 200, .h = 25 }, out.items[0].rect); // a(상)
        try std.testing.expectEqual(Rect{ .x = 0, .y = 25, .w = 200, .h = 75 }, out.items[1].rect); // b(하)
    }
}

test "layout: nested split recurses into sub-rects in tree order" {
    const allocator = std.testing.allocator;
    var a = try Surface.init(allocator, 1, .{ .cols = 4, .rows = 2 });
    defer a.deinit();
    var b = try Surface.init(allocator, 2, .{ .cols = 4, .rows = 2 });
    defer b.deinit();
    var c = try Surface.init(allocator, 3, .{ .cols = 4, .rows = 2 });
    defer c.deinit();

    // 루트 horizontal 0.5: 좌(a) | 우(vertical 0.5: 상 b / 하 c).
    var inner = Split{ .direction = .vertical, .ratio = 0.5, .a = .{ .leaf = &b }, .b = .{ .leaf = &c } };
    var root = Split{ .direction = .horizontal, .ratio = 0.5, .a = .{ .leaf = &a }, .b = .{ .split = &inner } };

    var out: std.ArrayList(LeafRect) = .empty;
    defer out.deinit(allocator);
    try layout(allocator, .{ .split = &root }, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, &out);

    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(&a, out.items[0].surface);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, out.items[0].rect); // a 좌측 전체 높이
    try std.testing.expectEqual(&b, out.items[1].surface);
    try std.testing.expectEqual(Rect{ .x = 100, .y = 0, .w = 100, .h = 50 }, out.items[1].rect); // b 우상
    try std.testing.expectEqual(&c, out.items[2].surface);
    try std.testing.expectEqual(Rect{ .x = 100, .y = 50, .w = 100, .h = 50 }, out.items[2].rect); // c 우하
    try std.testing.expectEqual(@as(usize, 3), leafCount(.{ .split = &root }));
}

test "layout: extreme ratio is clamped so neither panel is zero-sized" {
    const allocator = std.testing.allocator;
    var a = try Surface.init(allocator, 1, .{ .cols = 4, .rows = 2 });
    defer a.deinit();
    var b = try Surface.init(allocator, 2, .{ .cols = 4, .rows = 2 });
    defer b.deinit();
    // ratio 0(또는 1)이라도 clamp(0.05~0.95)라 a/b 둘 다 0이 아니다.
    var sp = Split{ .direction = .horizontal, .ratio = 0.0, .a = .{ .leaf = &a }, .b = .{ .leaf = &b } };
    var out: std.ArrayList(LeafRect) = .empty;
    defer out.deinit(allocator);
    try layout(allocator, .{ .split = &sp }, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, &out);
    try std.testing.expect(out.items[0].rect.w > 0);
    try std.testing.expect(out.items[1].rect.w > 0);
    try std.testing.expectEqual(@as(u32, 200), out.items[0].rect.w + out.items[1].rect.w);
}

test "deinit frees split nodes but not leaf surfaces" {
    const allocator = std.testing.allocator;
    var a = try Surface.init(allocator, 1, .{ .cols = 4, .rows = 2 });
    defer a.deinit();
    var b = try Surface.init(allocator, 2, .{ .cols = 4, .rows = 2 });
    defer b.deinit();
    // heap split 노드 — deinit이 destroy해야 leak이 없다(testing.allocator가 검출).
    const sp = try allocator.create(Split);
    sp.* = .{ .direction = .horizontal, .a = .{ .leaf = &a }, .b = .{ .leaf = &b } };
    deinit(allocator, .{ .split = sp });
    // leaf surface는 위 defer가 정리(트리 deinit이 surface를 건드리지 않음을 a/b 사용으로 보장).
    try std.testing.expectEqual(@as(u64, 1), a.id);
}

test "splitRect matches layout's a/b division (no gap, both non-zero)" {
    const allocator = std.testing.allocator;
    var a = try Surface.init(allocator, 1, .{ .cols = 4, .rows = 2 });
    defer a.deinit();
    var b = try Surface.init(allocator, 2, .{ .cols = 4, .rows = 2 });
    defer b.deinit();
    const rect = Rect{ .x = 10, .y = 20, .w = 200, .h = 100 };
    // splitRect(생성용)과 layout(렌더용)이 같은 트리에서 동일한 a/b를 내야 한다(생성 크기 == 렌더 크기).
    inline for (.{ SplitDirection.horizontal, SplitDirection.vertical }) |dir| {
        const split = splitRect(rect, dir, 0.5);
        var sp = Split{ .direction = dir, .ratio = 0.5, .a = .{ .leaf = &a }, .b = .{ .leaf = &b } };
        var out: std.ArrayList(LeafRect) = .empty;
        defer out.deinit(allocator);
        try layout(allocator, .{ .split = &sp }, rect, &out);
        try std.testing.expectEqual(out.items[0].rect, split.a);
        try std.testing.expectEqual(out.items[1].rect, split.b);
    }
}

test "replaceLeaf swaps root leaf into a split and finds a nested leaf" {
    const allocator = std.testing.allocator;
    var a = try Surface.init(allocator, 1, .{ .cols = 4, .rows = 2 });
    defer a.deinit();
    var b = try Surface.init(allocator, 2, .{ .cols = 4, .rows = 2 });
    defer b.deinit();
    var c = try Surface.init(allocator, 3, .{ .cols = 4, .rows = 2 });
    defer c.deinit();

    // 1) 루트가 leaf(a)면 tree 자체가 split{a, b}로 바뀐다.
    var tree: Node = .{ .leaf = &a };
    const sp = try allocator.create(Split);
    defer allocator.destroy(sp);
    sp.* = .{ .direction = .horizontal, .a = .{ .leaf = &a }, .b = .{ .leaf = &b } };
    try std.testing.expect(replaceLeaf(&tree, &a, .{ .split = sp }));
    try std.testing.expectEqual(@as(usize, 2), leafCount(tree));

    // 2) 중첩된 leaf(b)도 찾아 교체한다(b → split{b, c}). 못 찾는 surface는 false.
    const sp2 = try allocator.create(Split);
    defer allocator.destroy(sp2);
    sp2.* = .{ .direction = .vertical, .a = .{ .leaf = &b }, .b = .{ .leaf = &c } };
    try std.testing.expect(replaceLeaf(&tree, &b, .{ .split = sp2 }));
    try std.testing.expectEqual(@as(usize, 3), leafCount(tree));

    // 트리에 없는 surface(d)는 false — 아무 노드도 건드리지 않는다.
    var d = try Surface.init(allocator, 4, .{ .cols = 4, .rows = 2 });
    defer d.deinit();
    try std.testing.expect(!replaceLeaf(&tree, &d, .{ .leaf = &d }));
    try std.testing.expectEqual(@as(usize, 3), leafCount(tree));
}

test "removeLeaf collapses a split into its sibling and frees the split node" {
    const allocator = std.testing.allocator;
    var a = try Surface.init(allocator, 1, .{ .cols = 4, .rows = 2 });
    defer a.deinit();
    var b = try Surface.init(allocator, 2, .{ .cols = 4, .rows = 2 });
    defer b.deinit();
    var c = try Surface.init(allocator, 3, .{ .cols = 4, .rows = 2 });
    defer c.deinit();
    var d = try Surface.init(allocator, 4, .{ .cols = 4, .rows = 2 });
    defer d.deinit();

    // tree = split{ a, split{ b, c } } — heap split 2개. removeLeaf가 collapse하며 해제하므로 split엔 defer 안 건다
    // (testing.allocator가 leak/이중 free를 잡는다 — 끝엔 split이 모두 형제로 collapse돼 남는 heap 노드가 없다).
    const inner = try allocator.create(Split);
    inner.* = .{ .direction = .vertical, .a = .{ .leaf = &b }, .b = .{ .leaf = &c } };
    const root = try allocator.create(Split);
    root.* = .{ .direction = .horizontal, .a = .{ .leaf = &a }, .b = .{ .split = inner } };
    var tree: Node = .{ .split = root };

    // 트리에 없는 surface는 false(무변).
    try std.testing.expect(!removeLeaf(allocator, &tree, &d));
    try std.testing.expectEqual(@as(usize, 3), leafCount(tree));

    // 중첩 split 안의 b를 닫으면 inner split이 형제 c로 collapse → tree = split{ a, c }.
    try std.testing.expect(removeLeaf(allocator, &tree, &b));
    try std.testing.expectEqual(@as(usize, 2), leafCount(tree));

    // a를 닫으면 root split이 형제 c로 collapse → tree = leaf c(단일).
    try std.testing.expect(removeLeaf(allocator, &tree, &a));
    try std.testing.expectEqual(@as(usize, 1), leafCount(tree));
    switch (tree) {
        .leaf => |s| try std.testing.expectEqual(&c, s),
        .split => return error.TestExpectedLeaf,
    }

    // 마지막 단일 leaf는 형제가 없어 못 지운다 → false(탭 close가 처리).
    try std.testing.expect(!removeLeaf(allocator, &tree, &c));
    try std.testing.expectEqual(@as(usize, 1), leafCount(tree));
}
