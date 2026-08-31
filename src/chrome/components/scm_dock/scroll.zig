//! 소스 컨트롤 목록의 **스크롤 투영**이다.
//!
//! **높이 규칙은 여기 없다** — `types.DockMetrics.itemHeight` 가 이미 소유한다(머리 줄·섹션·파일 행·
//! 커밋 줄·커밋 상자…). 이 파일이 하는 일은 그 함수를 `chrome.ui.scroll_area.project` 가 부를 수 있는
//! 모양으로 감싸는 것뿐이다(그 함수는 항목 높이를 comptime 함수로 물어본다 — docs/scroll-area.md §3).
//!
//! **왜 중립인가.** 감싸는 코드가 호스트마다 있으면 *"어느 항목 열을 어떤 metrics 로 재는가"* 가 두
//! 벌이 되고, 한쪽만 고쳐지는 순간 **그 플랫폼에서만 목록 끝이 안 나온다**. macOS 는 지금
//! `app_session/scm_dock.zig` 에 같은 모양을 갖고 있다 — 그쪽도 이것으로 옮길 수 있다.

const std = @import("std");
const types = @import("types.zig");
const scroll_area = @import("../../ui/scroll_area.zig");

pub const Items = struct {
    /// **빌린 슬라이스**다. 목록을 다시 지으면 무효라, 호출자는 같은 표현식 안에서 쓴다.
    items: []const types.Item,
    metrics: types.DockMetrics,

    pub fn heightPx(self: Items, index: usize) u32 {
        if (index >= self.items.len) return 0;
        return self.metrics.itemHeight(self.items[index]);
    }

    /// **틈이 없다.** 이 목록의 간격은 각 항목 높이가 이미 품고 있다(`itemHeight` 의 주석 — 커밋
    /// 버튼이 아래 여백까지 자기 높이로 갖는 것이 그 예다).
    pub fn extent(self: Items, viewport_h_px: u32) scroll_area.Extent {
        return .{ .count = self.items.len, .gap_px = 0, .viewport_h_px = viewport_h_px };
    }

    pub fn project(self: Items, viewport_h_px: u32, requested_offset_px: u32) scroll_area.Projection {
        return scroll_area.project(self, Items.heightPx, self.extent(viewport_h_px), requested_offset_px);
    }
};

test "Items.heightPx: 종류마다 다른 높이를 metrics 에서 그대로 가져온다" {
    const m = types.DockMetrics.resolve(1000);
    const items = [_]types.Item{
        .{ .section = .{ .section = .changes, .count = 2, .collapsed = false, .action = .none } },
        .{ .file = .{ .name = "a.zig", .dir = "", .status = .modified, .letter = 'M', .action = .none } },
    };
    const list = Items{ .items = &items, .metrics = m };
    try std.testing.expectEqual(m.section_h, list.heightPx(0));
    try std.testing.expectEqual(m.row_h, list.heightPx(1));
    // **범위 밖은 0 이다** — `project` 가 항목 수와 열을 따로 받으므로 어긋나도 트랩 대신 0 을 낸다.
    try std.testing.expectEqual(@as(u32, 0), list.heightPx(2));
}

test "Items.project: 넘치면 상한이 남는 만큼이고, 안 넘치면 0 이다" {
    const m = types.DockMetrics.resolve(1000);
    var buf: [12]types.Item = undefined;
    for (&buf, 0..) |*it, i| it.* = .{ .file = .{
        .model_index = @intCast(i),
        .name = "a.zig",
        .dir = "",
        .status = .modified,
        .letter = 'M',
        .action = .none,
    } };
    const list = Items{ .items = &buf, .metrics = m };
    const total = 12 * m.row_h;

    const tight = list.project(total / 2, std.math.maxInt(u32));
    try std.testing.expectEqual(total, tight.content_height_px);
    try std.testing.expectEqual(total - total / 2, tight.max_offset_px);
    try std.testing.expectEqual(tight.max_offset_px, tight.offset_y_px);

    // 뷰포트가 목록보다 크면 **굴릴 것이 없다** — 그때 스크롤바를 내면 없는 여백을 있다고 말하는 셈이다.
    const roomy = list.project(total + m.row_h, 999);
    try std.testing.expectEqual(@as(u32, 0), roomy.max_offset_px);
    try std.testing.expectEqual(@as(u32, 0), roomy.offset_y_px);
}
