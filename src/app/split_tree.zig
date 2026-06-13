const std = @import("std");

// SplitTree(panel) 모델. 한 워크스페이스(사이드바 탭)는 leaf 1개(flat)가 아니라 가로/세로로 나눌 수 있는
// leaf 트리다(단일 출처: docs/tabs-splits-layout.md). 동작은 Ghostty의 SplitTree를 **개념만** 참고하고
// (MIT, 코드 표현 미참고) Zig로 독립 구현한다. 드라이버(네이티브 PTY / tmux pane)와 무관한 순수 모델이다.
//
//   Node = leaf(Leaf) | split{ direction, ratio, a, b }
//
// leaf는 panel 1개를 가리키는 **불투명 포인터**(`Leaf` 타입 파라미터). cmux식 모델에서 한 panel(Pane)이
// 여러 터미널을 가로 탭으로 들 수 있으므로, 트리는 그 Pane을 leaf로 들고 화면의 어느 surface를 그릴지는
// Pane이 정한다. 트리는 leaf를 소유하지 않고(Tab/session이 heap-pin 소유) split 노드만 heap 소유한다.
// `Leaf`로 일반화해(app 레이어가 platform의 Pane 타입에 의존하지 않게) 사용처(platform)가 `SplitTree(*Pane)`
// 으로 인스턴스화한다 — 레이아웃·트리 연산은 leaf 타입과 무관한 순수 로직이라 헤드리스 Zig 단위로 고정한다.

/// split 방향. horizontal = 좌우 분할(a=left, b=right), vertical = 상하 분할(a=top, b=bottom). leaf 타입과 무관.
pub const SplitDirection = enum { horizontal, vertical };

/// 픽셀 사각형(좌상단 origin, backing px). 레이아웃 입력(탭 영역)·출력(각 leaf의 영역). leaf 타입과 무관.
pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// split ratio 하한/상한 — 한 panel이 0폭/0높이(grid 빔·divider 히트 불가)가 되지 않게 막는다. 드래그
/// 리사이즈도 이 범위로 clamp해 layout과 같은 한도를 쓴다(단일 출처).
pub const ratio_min: f32 = 0.05;
pub const ratio_max: f32 = 0.95;

/// ratio를 [ratio_min, ratio_max]로 clamp한다. layout(ratioPx)·divider 드래그가 공유 — 보이는 분할과
/// 드래그가 같은 한도를 따른다. leaf 타입과 무관.
pub fn clampRatio(ratio: f32) f32 {
    return std.math.clamp(ratio, ratio_min, ratio_max);
}

/// clamp한 비율로 total을 나눈 a쪽 픽셀(반올림). 한 panel이 0이 되면 grid가 비고 divider 히트가 불가능하므로
/// 막는다. leaf 타입과 무관.
fn ratioPx(total: u32, ratio: f32) u32 {
    const v = @as(f32, @floatFromInt(total)) * clampRatio(ratio);
    return @intFromFloat(@round(v));
}

/// rect를 direction·ratio로 둘로 나눈 (a, b). horizontal=좌우(폭 분할), vertical=상하(높이 분할). split을
/// '생성'할 때 두 panel의 초기 크기를 정하는 용도로, layout()의 분할 규칙(ratioPx clamp)을 그대로 쓴다 —
/// 같은 트리를 layout()에 넣었을 때 나오는 a/b rect와 일치한다(틈 없음: a.w + b.w == rect.w). leaf 타입과 무관.
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

/// leaf 타입 `Leaf`(불투명 panel 포인터)에 대한 SplitTree 모듈. 트리는 `Leaf`를 pointer-identity로만 다루고
/// (split/replace/remove/count) 절대 deref하지 않으므로, app 레이어가 platform의 `*Pane`을 몰라도 된다 —
/// platform이 `SplitTree(*Pane)`으로 인스턴스화한다.
pub fn SplitTree(comptime Leaf: type) type {
    return struct {
        /// SplitTree 노드 — 단일 panel(leaf) 또는 두 자식 split. 재귀(split의 자식도 Node).
        pub const Node = union(enum) {
            leaf: Leaf,
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

        /// leaf와 그것을 그릴 사각형. 멀티-panel 렌더가 각 panel을 이 rect에 그린다(N개 panel을 sub-사각형에
        /// 동시 합성). leaf 타입은 인스턴스에 따른다(platform은 `*Pane`).
        pub const LeafRect = struct { leaf: Leaf, rect: Rect };

        /// node를 rect 안에서 재귀적으로 sub-rect로 나눠 각 leaf의 (leaf, rect)를 out에 채운다(트리 순서대로:
        /// a 먼저, b 다음). split은 방향에 따라 폭(horizontal) 또는 높이(vertical)를 ratio로 자른다 — 두 자식
        /// 영역의 합은 부모와 같다(틈 없음; divider 간격은 렌더 단계의 후속). 순수 — 유일한 할당은 out append.
        pub fn layout(allocator: std.mem.Allocator, node: Node, rect: Rect, out: *std.ArrayList(LeafRect)) !void {
            switch (node) {
                .leaf => |l| try out.append(allocator, .{ .leaf = l, .rect = rect }),
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

        /// split 경계(divider)와 그것을 조절하는 split 노드. 멀티-panel 렌더가 panel 사이에 divider를 그리고,
        /// 드래그 리사이즈가 mouse→ratio를 매핑할 때 쓴다. `bounds`는 이 split이 나누는 부모 영역(드래그 시
        /// `ratio = (mouse - bounds.origin) / bounds.size`), `pos`는 분할 경계 픽셀(horizontal=x, vertical=y).
        pub const DividerSeg = struct {
            split: *Split,
            direction: SplitDirection,
            bounds: Rect,
            pos: u32,
        };

        /// node를 rect 안에서 펴며 각 split 노드의 divider 경계를 out에 채운다(layout과 같은 분할 규칙·순서로
        /// 재귀). leaf만 있으면(단일 panel) 비어 있다. 렌더(divider 선)·hit-test(드래그)가 leaf rect와 같은
        /// 좌표계를 공유한다. 순수 — 유일한 할당은 out append.
        pub fn layoutDividers(allocator: std.mem.Allocator, node: Node, rect: Rect, out: *std.ArrayList(DividerSeg)) !void {
            switch (node) {
                .leaf => {},
                .split => |sp| switch (sp.direction) {
                    .horizontal => {
                        const a_w = ratioPx(rect.w, sp.ratio);
                        try out.append(allocator, .{ .split = sp, .direction = .horizontal, .bounds = rect, .pos = rect.x + a_w });
                        try layoutDividers(allocator, sp.a, .{ .x = rect.x, .y = rect.y, .w = a_w, .h = rect.h }, out);
                        try layoutDividers(allocator, sp.b, .{ .x = rect.x + a_w, .y = rect.y, .w = rect.w - a_w, .h = rect.h }, out);
                    },
                    .vertical => {
                        const a_h = ratioPx(rect.h, sp.ratio);
                        try out.append(allocator, .{ .split = sp, .direction = .vertical, .bounds = rect, .pos = rect.y + a_h });
                        try layoutDividers(allocator, sp.a, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = a_h }, out);
                        try layoutDividers(allocator, sp.b, .{ .x = rect.x, .y = rect.y + a_h, .w = rect.w, .h = rect.h - a_h }, out);
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

        /// split 노드를 재귀적으로 해제한다(leaf는 트리 소유가 아니므로 건드리지 않는다 — Tab/session이 정리).
        /// 단일 leaf 트리는 무동작. 트리를 헐 때(탭 close·pane collapse) 호출한다.
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

        /// 트리에서 target leaf를 replacement 노드로 in-place 교체한다(찾으면 true, 없으면 false). split 생성 시
        /// '활성 leaf'를 split{a: 기존 leaf, b: 새 leaf} 노드로 바꾸는 데 쓴다. 노드를 직접 변형하므로 루트는
        /// &tab.tree로 넘긴다(루트가 leaf면 tab.tree 자체가 split으로 바뀐다). 트리 순서로 앞선 leaf를 먼저
        /// 매치한다 — 같은 leaf가 두 번 들어가는 일은 없다(panel은 leaf와 1:1).
        pub fn replaceLeaf(node: *Node, target: Leaf, replacement: Node) bool {
            switch (node.*) {
                .leaf => |l| {
                    if (l == target) {
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

        fn isLeafOf(node: Node, target: Leaf) bool {
            return switch (node) {
                .leaf => |l| l == target,
                .split => false,
            };
        }

        /// node가 target leaf를 직접 자식으로 가진 split이면 그 leaf를 떼고 split을 '형제'로 교체한다(찾으면
        /// true). 즉 split{a: target_leaf, b: sibling} → sibling(반대도 대칭). pane close 시 트리를 collapse하는
        /// replaceLeaf의 역연산이다 — collapse된 split 노드만 heap 해제하고, 형제 subtree(leaf든 split이든)는
        /// 부모 슬롯으로 그대로 옮긴다(형제의 *Split은 안 건드림). leaf는 트리 소유가 아니라 건드리지 않는다
        /// (호출자가 panel teardown으로 정리). 루트가 단일 leaf면(형제 없음) false — 그건 탭 close가 처리한다.
        pub fn removeLeaf(allocator: std.mem.Allocator, node: *Node, target: Leaf) bool {
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
    };
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────────────────────
// 트리는 leaf를 pointer-identity로만 다루므로, 테스트는 임의의 heap-pin 포인터를 leaf로 쓴다(실제 Surface/
// Pane 불요 — 정수를 heap에 띄워 *u32를 leaf로). 레이아웃·collapse·replace 규칙은 leaf 타입과 무관함을 보인다.
const TestTree = SplitTree(*u32);

fn testLeaf(allocator: std.mem.Allocator, v: u32) !*u32 {
    const p = try allocator.create(u32);
    p.* = v;
    return p;
}

test "layout: single leaf fills the whole rect" {
    const allocator = std.testing.allocator;
    const a = try testLeaf(allocator, 1);
    defer allocator.destroy(a);

    var out: std.ArrayList(TestTree.LeafRect) = .empty;
    defer out.deinit(allocator);
    try TestTree.layout(allocator, .{ .leaf = a }, .{ .x = 10, .y = 20, .w = 200, .h = 100 }, &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(a, out.items[0].leaf);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 200, .h = 100 }, out.items[0].rect);
}

test "layout: horizontal split divides width by ratio, vertical divides height; sums match parent" {
    const allocator = std.testing.allocator;
    const a = try testLeaf(allocator, 1);
    defer allocator.destroy(a);
    const b = try testLeaf(allocator, 2);
    defer allocator.destroy(b);

    // horizontal 0.5: 폭 200 → a 100 + b 100(좌우), 높이는 둘 다 100.
    var hsplit = TestTree.Split{ .direction = .horizontal, .ratio = 0.5, .a = .{ .leaf = a }, .b = .{ .leaf = b } };
    {
        var out: std.ArrayList(TestTree.LeafRect) = .empty;
        defer out.deinit(allocator);
        try TestTree.layout(allocator, .{ .split = &hsplit }, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, &out);
        try std.testing.expectEqual(@as(usize, 2), out.items.len);
        try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, out.items[0].rect); // a(좌)
        try std.testing.expectEqual(Rect{ .x = 100, .y = 0, .w = 100, .h = 100 }, out.items[1].rect); // b(우)
        try std.testing.expectEqual(@as(u32, 200), out.items[0].rect.w + out.items[1].rect.w); // 합 = 부모(틈 없음)
    }

    // vertical 0.25: 높이 100 → a 25(상) + b 75(하), 폭은 둘 다 200.
    var vsplit = TestTree.Split{ .direction = .vertical, .ratio = 0.25, .a = .{ .leaf = a }, .b = .{ .leaf = b } };
    {
        var out: std.ArrayList(TestTree.LeafRect) = .empty;
        defer out.deinit(allocator);
        try TestTree.layout(allocator, .{ .split = &vsplit }, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, &out);
        try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 200, .h = 25 }, out.items[0].rect); // a(상)
        try std.testing.expectEqual(Rect{ .x = 0, .y = 25, .w = 200, .h = 75 }, out.items[1].rect); // b(하)
    }
}

test "layout: nested split recurses into sub-rects in tree order" {
    const allocator = std.testing.allocator;
    const a = try testLeaf(allocator, 1);
    defer allocator.destroy(a);
    const b = try testLeaf(allocator, 2);
    defer allocator.destroy(b);
    const c = try testLeaf(allocator, 3);
    defer allocator.destroy(c);

    // 루트 horizontal 0.5: 좌(a) | 우(vertical 0.5: 상 b / 하 c).
    var inner = TestTree.Split{ .direction = .vertical, .ratio = 0.5, .a = .{ .leaf = b }, .b = .{ .leaf = c } };
    var root = TestTree.Split{ .direction = .horizontal, .ratio = 0.5, .a = .{ .leaf = a }, .b = .{ .split = &inner } };

    var out: std.ArrayList(TestTree.LeafRect) = .empty;
    defer out.deinit(allocator);
    try TestTree.layout(allocator, .{ .split = &root }, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, &out);

    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(a, out.items[0].leaf);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, out.items[0].rect); // a 좌측 전체 높이
    try std.testing.expectEqual(b, out.items[1].leaf);
    try std.testing.expectEqual(Rect{ .x = 100, .y = 0, .w = 100, .h = 50 }, out.items[1].rect); // b 우상
    try std.testing.expectEqual(c, out.items[2].leaf);
    try std.testing.expectEqual(Rect{ .x = 100, .y = 50, .w = 100, .h = 50 }, out.items[2].rect); // c 우하
    try std.testing.expectEqual(@as(usize, 3), TestTree.leafCount(.{ .split = &root }));
}

test "layoutDividers: emits a divider seg per split with boundary pos and parent bounds" {
    const allocator = std.testing.allocator;
    const a = try testLeaf(allocator, 1);
    defer allocator.destroy(a);
    const b = try testLeaf(allocator, 2);
    defer allocator.destroy(b);
    const c = try testLeaf(allocator, 3);
    defer allocator.destroy(c);

    // 단일 leaf는 divider 없음.
    {
        var out: std.ArrayList(TestTree.DividerSeg) = .empty;
        defer out.deinit(allocator);
        try TestTree.layoutDividers(allocator, .{ .leaf = a }, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, &out);
        try std.testing.expectEqual(@as(usize, 0), out.items.len);
    }
    // horizontal 0.5 (w=200) → 경계 x=100, bounds=부모 rect, direction=horizontal.
    {
        var hsplit = TestTree.Split{ .direction = .horizontal, .ratio = 0.5, .a = .{ .leaf = a }, .b = .{ .leaf = b } };
        var out: std.ArrayList(TestTree.DividerSeg) = .empty;
        defer out.deinit(allocator);
        try TestTree.layoutDividers(allocator, .{ .split = &hsplit }, .{ .x = 10, .y = 20, .w = 200, .h = 100 }, &out);
        try std.testing.expectEqual(@as(usize, 1), out.items.len);
        try std.testing.expectEqual(&hsplit, out.items[0].split);
        try std.testing.expectEqual(SplitDirection.horizontal, out.items[0].direction);
        try std.testing.expectEqual(@as(u32, 10 + 100), out.items[0].pos); // x + ratioPx(200,0.5)
        try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 200, .h = 100 }, out.items[0].bounds);
    }
    // nested: 루트 horizontal 0.5 | 우 vertical 0.25 → divider 2개(루트 경계 x, 내부 경계 y), 트리 순서.
    {
        var inner = TestTree.Split{ .direction = .vertical, .ratio = 0.25, .a = .{ .leaf = b }, .b = .{ .leaf = c } };
        var root = TestTree.Split{ .direction = .horizontal, .ratio = 0.5, .a = .{ .leaf = a }, .b = .{ .split = &inner } };
        var out: std.ArrayList(TestTree.DividerSeg) = .empty;
        defer out.deinit(allocator);
        try TestTree.layoutDividers(allocator, .{ .split = &root }, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, &out);
        try std.testing.expectEqual(@as(usize, 2), out.items.len);
        // 루트 divider: 세로선 x=100, bounds=전체.
        try std.testing.expectEqual(&root, out.items[0].split);
        try std.testing.expectEqual(@as(u32, 100), out.items[0].pos);
        // 내부 divider: 가로선, bounds=우측 sub-rect(x=100,w=100,h=100), pos=y + ratioPx(100,0.25)=0+25.
        try std.testing.expectEqual(&inner, out.items[1].split);
        try std.testing.expectEqual(SplitDirection.vertical, out.items[1].direction);
        try std.testing.expectEqual(@as(u32, 25), out.items[1].pos);
        try std.testing.expectEqual(Rect{ .x = 100, .y = 0, .w = 100, .h = 100 }, out.items[1].bounds);
    }
}

test "clampRatio bounds the split ratio to [ratio_min, ratio_max]" {
    try std.testing.expectEqual(ratio_min, clampRatio(0.0));
    try std.testing.expectEqual(ratio_max, clampRatio(1.0));
    try std.testing.expectEqual(@as(f32, 0.5), clampRatio(0.5));
    try std.testing.expectEqual(ratio_min, clampRatio(-3.0));
}

test "layout: extreme ratio is clamped so neither panel is zero-sized" {
    const allocator = std.testing.allocator;
    const a = try testLeaf(allocator, 1);
    defer allocator.destroy(a);
    const b = try testLeaf(allocator, 2);
    defer allocator.destroy(b);
    // ratio 0(또는 1)이라도 clamp(0.05~0.95)라 a/b 둘 다 0이 아니다.
    var sp = TestTree.Split{ .direction = .horizontal, .ratio = 0.0, .a = .{ .leaf = a }, .b = .{ .leaf = b } };
    var out: std.ArrayList(TestTree.LeafRect) = .empty;
    defer out.deinit(allocator);
    try TestTree.layout(allocator, .{ .split = &sp }, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, &out);
    try std.testing.expect(out.items[0].rect.w > 0);
    try std.testing.expect(out.items[1].rect.w > 0);
    try std.testing.expectEqual(@as(u32, 200), out.items[0].rect.w + out.items[1].rect.w);
}

test "deinit frees split nodes but not leaves" {
    const allocator = std.testing.allocator;
    const a = try testLeaf(allocator, 1);
    defer allocator.destroy(a);
    const b = try testLeaf(allocator, 2);
    defer allocator.destroy(b);
    // heap split 노드 — deinit이 destroy해야 leak이 없다(testing.allocator가 검출).
    const sp = try allocator.create(TestTree.Split);
    sp.* = .{ .direction = .horizontal, .a = .{ .leaf = a }, .b = .{ .leaf = b } };
    TestTree.deinit(allocator, .{ .split = sp });
    // leaf는 위 defer가 정리(트리 deinit이 leaf를 건드리지 않음을 a/b 사용으로 보장).
    try std.testing.expectEqual(@as(u32, 1), a.*);
}

test "splitRect matches layout's a/b division (no gap, both non-zero)" {
    const allocator = std.testing.allocator;
    const a = try testLeaf(allocator, 1);
    defer allocator.destroy(a);
    const b = try testLeaf(allocator, 2);
    defer allocator.destroy(b);
    const rect = Rect{ .x = 10, .y = 20, .w = 200, .h = 100 };
    // splitRect(생성용)과 layout(렌더용)이 같은 트리에서 동일한 a/b를 내야 한다(생성 크기 == 렌더 크기).
    inline for (.{ SplitDirection.horizontal, SplitDirection.vertical }) |dir| {
        const split = splitRect(rect, dir, 0.5);
        var sp = TestTree.Split{ .direction = dir, .ratio = 0.5, .a = .{ .leaf = a }, .b = .{ .leaf = b } };
        var out: std.ArrayList(TestTree.LeafRect) = .empty;
        defer out.deinit(allocator);
        try TestTree.layout(allocator, .{ .split = &sp }, rect, &out);
        try std.testing.expectEqual(out.items[0].rect, split.a);
        try std.testing.expectEqual(out.items[1].rect, split.b);
    }
}

test "replaceLeaf swaps root leaf into a split and finds a nested leaf" {
    const allocator = std.testing.allocator;
    const a = try testLeaf(allocator, 1);
    defer allocator.destroy(a);
    const b = try testLeaf(allocator, 2);
    defer allocator.destroy(b);
    const c = try testLeaf(allocator, 3);
    defer allocator.destroy(c);

    // 1) 루트가 leaf(a)면 tree 자체가 split{a, b}로 바뀐다.
    var tree: TestTree.Node = .{ .leaf = a };
    const sp = try allocator.create(TestTree.Split);
    defer allocator.destroy(sp);
    sp.* = .{ .direction = .horizontal, .a = .{ .leaf = a }, .b = .{ .leaf = b } };
    try std.testing.expect(TestTree.replaceLeaf(&tree, a, .{ .split = sp }));
    try std.testing.expectEqual(@as(usize, 2), TestTree.leafCount(tree));

    // 2) 중첩된 leaf(b)도 찾아 교체한다(b → split{b, c}). 못 찾는 leaf는 false.
    const sp2 = try allocator.create(TestTree.Split);
    defer allocator.destroy(sp2);
    sp2.* = .{ .direction = .vertical, .a = .{ .leaf = b }, .b = .{ .leaf = c } };
    try std.testing.expect(TestTree.replaceLeaf(&tree, b, .{ .split = sp2 }));
    try std.testing.expectEqual(@as(usize, 3), TestTree.leafCount(tree));

    // 트리에 없는 leaf(d)는 false — 아무 노드도 건드리지 않는다.
    const d = try testLeaf(allocator, 4);
    defer allocator.destroy(d);
    try std.testing.expect(!TestTree.replaceLeaf(&tree, d, .{ .leaf = d }));
    try std.testing.expectEqual(@as(usize, 3), TestTree.leafCount(tree));
}

test "removeLeaf collapses a split into its sibling and frees the split node" {
    const allocator = std.testing.allocator;
    const a = try testLeaf(allocator, 1);
    defer allocator.destroy(a);
    const b = try testLeaf(allocator, 2);
    defer allocator.destroy(b);
    const c = try testLeaf(allocator, 3);
    defer allocator.destroy(c);
    const d = try testLeaf(allocator, 4);
    defer allocator.destroy(d);

    // tree = split{ a, split{ b, c } } — heap split 2개. removeLeaf가 collapse하며 해제하므로 split엔 defer 안 건다
    // (testing.allocator가 leak/이중 free를 잡는다 — 끝엔 split이 모두 형제로 collapse돼 남는 heap 노드가 없다).
    const inner = try allocator.create(TestTree.Split);
    inner.* = .{ .direction = .vertical, .a = .{ .leaf = b }, .b = .{ .leaf = c } };
    const root = try allocator.create(TestTree.Split);
    root.* = .{ .direction = .horizontal, .a = .{ .leaf = a }, .b = .{ .split = inner } };
    var tree: TestTree.Node = .{ .split = root };

    // 트리에 없는 leaf는 false(무변).
    try std.testing.expect(!TestTree.removeLeaf(allocator, &tree, d));
    try std.testing.expectEqual(@as(usize, 3), TestTree.leafCount(tree));

    // 중첩 split 안의 b를 닫으면 inner split이 형제 c로 collapse → tree = split{ a, c }.
    try std.testing.expect(TestTree.removeLeaf(allocator, &tree, b));
    try std.testing.expectEqual(@as(usize, 2), TestTree.leafCount(tree));

    // a를 닫으면 root split이 형제 c로 collapse → tree = leaf c(단일).
    try std.testing.expect(TestTree.removeLeaf(allocator, &tree, a));
    try std.testing.expectEqual(@as(usize, 1), TestTree.leafCount(tree));
    switch (tree) {
        .leaf => |l| try std.testing.expectEqual(c, l),
        .split => return error.TestExpectedLeaf,
    }

    // 마지막 단일 leaf는 형제가 없어 못 지운다 → false(탭 close가 처리).
    try std.testing.expect(!TestTree.removeLeaf(allocator, &tree, c));
    try std.testing.expectEqual(@as(usize, 1), TestTree.leafCount(tree));
}
