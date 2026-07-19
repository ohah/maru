//! FP9 파일 도크 탭 drag의 OS-중립 gesture/target 기하. Terminal pane drag와 타입을 공유하지 않아
//! terminal↔dock 교차 drop을 구조적으로 만들 수 없다. AppSession은 mouse-down 때 고정 크기 snapshot을 채우고
//! pointer move/up 동안 이 모듈만 읽는다.

const std = @import("std");
const dock_panel = @import("dock_panel.zig");
const Rect = @import("split_tree.zig").Rect;

pub const drag_threshold_px: f64 = 4;

pub const Leaf = struct {
    group_id: u64,
    group: *dock_panel.DockGroup = undefined,
    rect: Rect,
    tab_bar: Rect,
    content: Rect,
    entry_count: usize,
    tab_width_px: u32,
};

pub const Target = struct {
    group_id: u64,
    drop: dock_panel.DockDropTarget,
    preview_rect: Rect,

    pub fn eql(a: Target, b: Target) bool {
        return a.group_id == b.group_id and std.meta.eql(a.drop, b.drop) and std.meta.eql(a.preview_rect, b.preview_rect);
    }
};

pub const ScanCounters = struct {
    leaf_visits: usize = 0,
};

pub const Session = struct {
    entry_id: dock_panel.EntryId,
    source_group_id: u64,
    down_x: f64,
    down_y: f64,
    pointer_x: f64,
    pointer_y: f64,
    snapshot_id: u64,
    layout_generation: u64,
    geometry_fingerprint: u64,
    target: ?Target = null,

    pub fn movedPastThreshold(self: Session, x: f64, y: f64) bool {
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
        const dx = x - self.down_x;
        const dy = y - self.down_y;
        return dx * dx + dy * dy >= drag_threshold_px * drag_threshold_px;
    }
};

/// 보이는 탭들의 source-remove 전 boundary(0...N). 탭 가운데를 기준으로 앞/뒤에 삽입하며 탭이 없는
/// 그룹이나 탭 뒤 빈 바는 마지막 boundary를 반환한다.
pub fn tabBoundary(leaf: Leaf, x: f64) usize {
    if (leaf.entry_count == 0 or leaf.tab_width_px == 0) return 0;
    if (x <= @as(f64, @floatFromInt(leaf.tab_bar.x))) return 0;
    const local = x - @as(f64, @floatFromInt(leaf.tab_bar.x));
    const width: f64 = @floatFromInt(leaf.tab_width_px);
    const raw: usize = @intFromFloat(@min(local / width, @as(f64, @floatFromInt(leaf.entry_count))));
    if (raw >= leaf.entry_count) return leaf.entry_count;
    const within = local - @as(f64, @floatFromInt(raw)) * width;
    return @min(raw + @intFromBool(within >= width / 2), leaf.entry_count);
}

fn splitTarget(rect: Rect, x: f64, y: f64) ?struct { edge: dock_panel.DockDropEdge, preview: Rect } {
    if (!pointInRect(x, y, rect) or rect.w == 0 or rect.h == 0) return null;
    const cx = @as(f64, @floatFromInt(rect.x)) + @as(f64, @floatFromInt(rect.w)) / 2;
    const cy = @as(f64, @floatFromInt(rect.y)) + @as(f64, @floatFromInt(rect.h)) / 2;
    const nx = (x - cx) / @as(f64, @floatFromInt(rect.w));
    const ny = (y - cy) / @as(f64, @floatFromInt(rect.h));
    if (nx == 0 and ny == 0) return null; // 정확한 중심 한 점은 방향 의도가 없어 invalid다.
    const horizontal = @abs(nx) >= @abs(ny); // diagonal tie는 horizontal 우선으로 결정적이다.
    if (horizontal) {
        const left = nx < 0;
        const half = rect.w / 2;
        return .{
            .edge = if (left) .left else .right,
            .preview = if (left)
                .{ .x = rect.x, .y = rect.y, .w = half, .h = rect.h }
            else
                .{ .x = rect.x + half, .y = rect.y, .w = rect.w - half, .h = rect.h },
        };
    }
    const top = ny < 0;
    const half = rect.h / 2;
    return .{
        .edge = if (top) .top else .bottom,
        .preview = if (top)
            .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = half }
        else
            .{ .x = rect.x, .y = rect.y + half, .w = rect.w, .h = rect.h - half },
    };
}

/// Snapshot 밖(terminal, project tree, outer divider)은 null이라 양 방향 cross-domain drop이 무동작이다.
pub fn targetAt(leaves: []const Leaf, x: f64, y: f64) ?Target {
    return targetAtCounted(leaves, x, y, null);
}

pub fn targetAtCounted(leaves: []const Leaf, x: f64, y: f64, counters: ?*ScanCounters) ?Target {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;
    for (leaves) |leaf| {
        if (counters) |stats| stats.leaf_visits += 1;
        if (pointInRect(x, y, leaf.tab_bar)) {
            const boundary = tabBoundary(leaf, x);
            const marker_x = leaf.tab_bar.x + @as(u32, @intCast(@min(boundary, leaf.entry_count))) * leaf.tab_width_px;
            return .{
                .group_id = leaf.group_id,
                .drop = .{ .tab_bar = boundary },
                .preview_rect = .{ .x = marker_x -| 1, .y = leaf.tab_bar.y, .w = 2, .h = leaf.tab_bar.h },
            };
        }
        if (splitTarget(leaf.content, x, y)) |split| return .{
            .group_id = leaf.group_id,
            .drop = .{ .split = split.edge },
            .preview_rect = split.preview,
        };
    }
    return null;
}

test "dock drag: target lookup visits each of 64 leaves at most once" {
    var leaves: [dock_panel.max_groups]Leaf = undefined;
    for (&leaves, 0..) |*leaf, index| leaf.* = .{
        .group_id = index + 1,
        .rect = .{ .x = @intCast(index * 100), .y = 0, .w = 100, .h = 200 },
        .tab_bar = .{ .x = @intCast(index * 100), .y = 0, .w = 100, .h = 20 },
        .content = .{ .x = @intCast(index * 100), .y = 40, .w = 100, .h = 160 },
        .entry_count = 4,
        .tab_width_px = 25,
    };

    for ([_]f64{ 1, 3201, 6399, 7000 }) |x| {
        var counters: ScanCounters = .{};
        _ = targetAtCounted(&leaves, x, 100, &counters);
        try std.testing.expect(counters.leaf_visits <= dock_panel.max_groups);
    }
}

/// Layout snapshot stale 판정용 값. group id와 모든 rect/count/metric을 섞으며 pointer hot path에서 allocation이 없다.
pub fn fingerprint(leaves: []const Leaf) u64 {
    var value: u64 = 0x4650_3900;
    for (leaves) |leaf| {
        inline for (.{
            leaf.group_id,
            @as(u64, leaf.rect.x),
            @as(u64, leaf.rect.y),
            @as(u64, leaf.rect.w),
            @as(u64, leaf.rect.h),
            @as(u64, leaf.tab_bar.x),
            @as(u64, leaf.tab_bar.y),
            @as(u64, leaf.tab_bar.w),
            @as(u64, leaf.tab_bar.h),
            @as(u64, leaf.content.x),
            @as(u64, leaf.content.y),
            @as(u64, leaf.content.w),
            @as(u64, leaf.content.h),
            @as(u64, @intCast(leaf.entry_count)),
            @as(u64, leaf.tab_width_px),
        }) |part| value = std.hash.Wyhash.hash(value, std.mem.asBytes(&part));
    }
    return value;
}

fn pointInRect(x: f64, y: f64, rect: Rect) bool {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
    return x >= @as(f64, @floatFromInt(rect.x)) and y >= @as(f64, @floatFromInt(rect.y)) and
        x < @as(f64, @floatFromInt(rect.x +| rect.w)) and y < @as(f64, @floatFromInt(rect.y +| rect.h));
}

test "dock drag: threshold and tab boundaries are deterministic" {
    const leaf = Leaf{ .group_id = 7, .rect = .{ .x = 100, .y = 20, .w = 400, .h = 300 }, .tab_bar = .{ .x = 100, .y = 20, .w = 400, .h = 20 }, .content = .{ .x = 100, .y = 60, .w = 400, .h = 260 }, .entry_count = 3, .tab_width_px = 100 };
    try std.testing.expectEqual(@as(usize, 0), tabBoundary(leaf, 100));
    try std.testing.expectEqual(@as(usize, 1), tabBoundary(leaf, 150));
    try std.testing.expectEqual(@as(usize, 3), tabBoundary(leaf, 499));
    const s = Session{ .entry_id = 1, .source_group_id = 7, .down_x = 10, .down_y = 10, .pointer_x = 10, .pointer_y = 10, .snapshot_id = 1, .layout_generation = 1, .geometry_fingerprint = 0 };
    try std.testing.expect(!s.movedPastThreshold(13, 12));
    try std.testing.expect(s.movedPastThreshold(14, 10));
}

test "dock drag: X zones, corners, center tie, and cross-domain null" {
    const leaf = Leaf{ .group_id = 9, .rect = .{ .x = 100, .y = 100, .w = 200, .h = 200 }, .tab_bar = .{ .x = 100, .y = 100, .w = 200, .h = 20 }, .content = .{ .x = 100, .y = 140, .w = 200, .h = 160 }, .entry_count = 1, .tab_width_px = 100 };
    try std.testing.expectEqual(dock_panel.DockDropEdge.left, targetAt(&.{leaf}, 101, 220).?.drop.split);
    try std.testing.expectEqual(dock_panel.DockDropEdge.right, targetAt(&.{leaf}, 299, 220).?.drop.split);
    try std.testing.expectEqual(dock_panel.DockDropEdge.top, targetAt(&.{leaf}, 200, 141).?.drop.split);
    try std.testing.expectEqual(dock_panel.DockDropEdge.bottom, targetAt(&.{leaf}, 200, 299).?.drop.split);
    try std.testing.expect(targetAt(&.{leaf}, 200, 220) == null);
    try std.testing.expect(targetAt(&.{leaf}, 200, 130) == null); // header는 split target이 아니다.
    try std.testing.expectEqual(dock_panel.DockDropEdge.left, targetAt(&.{leaf}, 121, 157).?.drop.split);
    try std.testing.expectEqual(dock_panel.DockDropEdge.right, targetAt(&.{leaf}, 279, 283).?.drop.split);
    try std.testing.expect(targetAt(&.{leaf}, 50, 200) == null); // terminal/outer divider domain
}

test "dock drag: preview and commit target consume the same value" {
    const leaves = [_]Leaf{
        .{ .group_id = 1, .rect = .{ .x = 0, .y = 0, .w = 200, .h = 300 }, .tab_bar = .{ .x = 0, .y = 0, .w = 200, .h = 20 }, .content = .{ .x = 0, .y = 40, .w = 200, .h = 260 }, .entry_count = 2, .tab_width_px = 80 },
        .{ .group_id = 2, .rect = .{ .x = 200, .y = 0, .w = 200, .h = 300 }, .tab_bar = .{ .x = 200, .y = 0, .w = 200, .h = 20 }, .content = .{ .x = 200, .y = 40, .w = 200, .h = 260 }, .entry_count = 1, .tab_width_px = 80 },
    };
    const preview = targetAt(&leaves, 250, 10).?;
    const commit = targetAt(&leaves, 250, 10).?;
    try std.testing.expect(Target.eql(preview, commit));
    try std.testing.expectEqual(@as(u64, 2), commit.group_id);
    try std.testing.expectEqual(@as(usize, 1), commit.drop.tab_bar);
    try std.testing.expectEqual(fingerprint(&leaves), fingerprint(&leaves));
}
