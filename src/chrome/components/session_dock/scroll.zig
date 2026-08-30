//! 아카이브 목록의 **항목 높이 규칙**과 그 위에 세운 스크롤 투영이다.
//!
//! `chrome.ui.scroll_area` 는 높이가 균일하다고 가정하지 않고 comptime 함수로 물어본다
//! (docs/scroll-area.md §3). 그 물음에 답하는 규칙 — 그룹 헤더·카드·펼친 카드 — 이 이 도크의 예외
//! 전부이고, **`build.zig` 가 노드를 놓을 때 쓰는 높이와 같은 값**이어야 한다. 갈리면 스크롤이 재는
//! 길이와 실제로 그려지는 길이가 달라져, 끝까지 굴려도 마지막 카드에 못 닿거나 빈 바닥이 보인다.
//!
//! **왜 여기인가.** 이 규칙은 `types.Item` 과 `types.DockMetrics` 만 있으면 답이 나온다 — 즉 중립이
//! 소유할 수 있다. 호스트마다 다시 적으면 한쪽만 고쳐지고, 그 증상은 "한 플랫폼에서만 목록 끝이
//! 안 나온다" 라 눈으로 잘 안 걸린다.

const std = @import("std");
const types = @import("types.zig");
const scroll_area = @import("../../ui/scroll_area.zig");

/// 목록 하나의 높이 규칙. `scroll_area.project` 에 그대로 넘길 수 있다.
pub const Items = struct {
    /// **빌린 슬라이스**다. 스냅샷이 바뀌면 무효라, 호출자는 같은 표현식 안에서 쓰고 저장하지 않는다.
    items: []const types.Item,
    metrics: types.DockMetrics,

    pub fn heightPx(self: Items, index: usize) u32 {
        return switch (self.items[index]) {
            .group => self.metrics.group_h,
            // 펼친 카드는 상세와 액션 줄을 **자기 높이 안에** 예약한다 — `build.zig` 가 그 합으로
            // 노드를 놓는다. 여기서 안 더하면 뒤 카드들이 그만큼 위로 당겨진 것으로 계산된다.
            //
            // **조건은 `card.expanded` 하나다** — `build.zig` 가 그렇게 갈래를 탄다(`if (card.expanded)
            // |expanded|`). `Props.expanded_identity` 를 함께 보면 안 된다: 그 필드는 host 가 detail
            // 캡처를 붙이는 **신원**이고 높이를 정하는 값이 아니라, 둘이 어긋나는 순간 **투영이 재는
            // 길이와 실제로 그려지는 길이가 갈린다**(적대적 검증 1회차에서 그렇게 적혀 있었다).
            .card => |c| if (c.expanded != null)
                self.metrics.card_h + self.metrics.expanded_detail_h + self.metrics.expanded_actions_h
            else
                self.metrics.card_h,
        };
    }

    pub fn extent(self: Items, viewport_h_px: u32) scroll_area.Extent {
        return .{ .count = self.items.len, .gap_px = self.metrics.item_gap, .viewport_h_px = viewport_h_px };
    }

    /// 이 목록의 content 높이와 최대 offset. **가상화를 안 하는 호스트**(보이는 것을 고르지 않고 전부
    /// 넘기는 쪽)도 이 둘은 알아야 한다 — 스크롤바가 얼마나 긴 목록의 어디를 보고 있는지는 그 값으로만
    /// 나온다(`Props.scroll_content_height_px`·`scroll_offset_px` 의 doc).
    pub fn project(self: Items, viewport_h_px: u32, requested_offset_px: u32) scroll_area.Projection {
        return scroll_area.project(self, Items.heightPx, self.extent(viewport_h_px), requested_offset_px);
    }
};

test "Items.heightPx: 그룹·카드·펼친 카드가 build 와 같은 높이를 낸다" {
    const m = types.DockMetrics.resolve(1000);
    const items = [_]types.Item{
        .{ .group = .{ .identity = 1, .label = "g", .count = 2 } },
        .{ .card = .{ .identity = 10, .provider = .claude, .title = "t", .summary = "s", .metadata = .{} } },
        .{ .card = .{ .identity = 11, .provider = .claude, .title = "t", .summary = "s", .metadata = .{}, .expanded = .{ .state = .ready } } },
    };
    const plain = Items{ .items = &items, .metrics = m };
    try std.testing.expectEqual(m.group_h, plain.heightPx(0));
    try std.testing.expectEqual(m.card_h, plain.heightPx(1));
    // **상세를 든 카드는 그만큼 높다** — `build.zig` 가 `card.expanded` 하나로 갈래를 타므로 여기도
    // 같은 것만 본다. `Props.expanded_identity` 를 함께 보면 둘이 어긋날 때 길이가 갈린다.
    try std.testing.expectEqual(m.card_h + m.expanded_detail_h + m.expanded_actions_h, plain.heightPx(2));
}

test "Items.project: 끝까지 굴리면 마지막 항목의 바닥이 뷰포트 바닥에 온다" {
    const m = types.DockMetrics.resolve(1000);
    var buf: [8]types.Item = undefined;
    for (&buf, 0..) |*it, i| it.* = .{ .card = .{
        .identity = @intCast(i),
        .provider = .claude,
        .title = "t",
        .summary = "s",
        .metadata = .{},
    } };
    const list = Items{ .items = &buf, .metrics = m };
    const total = 8 * m.card_h + 7 * m.item_gap;
    const viewport = total / 2;
    const p = list.project(viewport, std.math.maxInt(u32));
    try std.testing.expectEqual(total, p.content_height_px);
    // **최대 offset 은 남는 만큼이다.** 이보다 크면 빈 바닥이 보이고, 작으면 마지막 카드에 못 닿는다.
    try std.testing.expectEqual(total - viewport, p.max_offset_px);
    try std.testing.expectEqual(p.max_offset_px, p.offset_y_px);
}
