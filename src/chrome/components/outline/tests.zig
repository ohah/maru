//! 클릭되는 행·펼침 버튼과 그려지는 계층이 같은 tree를 쓰는지 검증한다.
const std = @import("std");
const build = @import("build.zig");
const view = @import("view.zig");
const types = @import("types.zig");
const ids = @import("ids.zig");
const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
const interaction = @import("../../ui/interaction.zig");
const tokens = @import("../../tokens.zig");
const draw = @import("../../draw.zig");

fn make(allocator: std.mem.Allocator, props: types.Props) !build.Frame {
    const size = build.bufferSizes(props.rows.len);
    return build.build(props, .{
        .nodes = try allocator.alloc(tree.UiNode, size.nodes),
        .entries = try allocator.alloc(tree.RectEntry, size.entries),
        .layout_items = try allocator.alloc(layout.Item, size.entries),
        .flex_scratch = try allocator.alloc(layout.FlexScratch, size.entries),
        .child_rects = try allocator.alloc(layout.UiRect, size.entries),
        .actions = try allocator.alloc(ids.Entry, size.actions),
    });
}

test "outline component separates disclosure from navigation and rejects stale generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const frame = try make(arena.allocator(), .{ .viewport_px = .{ .width = 220, .height = 80 }, .generation = 7, .rows = &.{
        .{ .label = "Class", .model_index = 3, .expandable = true },
        .{ .label = "method", .model_index = 4, .depth = 1 },
    } });
    var table = ids.Table.init(@constCast(frame.actions));
    table.count = frame.actions.len;
    const disclosure = interaction.hitAction(frame.tree, 12, 10).?;
    const label = interaction.hitAction(frame.tree, 80, 10).?;
    try std.testing.expectEqualDeep(ids.Intent{ .toggle = 3 }, table.resolve(disclosure.action_id, 7).?);
    try std.testing.expectEqualDeep(ids.Intent{ .navigate = 3 }, table.resolve(label.action_id, 7).?);
    var state: interaction.InteractionState = .{};
    _ = try interaction.dispatch(&state, frame.tree, .{ .phase = .down, .x_px = 80, .y_px = 10, .generation = 7, .timestamp_ns = 0 });
    const released = try interaction.dispatch(&state, frame.tree, .{ .phase = .up, .x_px = 80, .y_px = 10, .generation = 8, .timestamp_ns = 0 });
    try std.testing.expect(released.action == null);
}

test "outline component clips partial rows and keeps names visible at narrow scales" {
    for ([_]u32{ 1000, 2000 }) |scale| for ([_]f32{ 48, 120, 360 }) |width| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const props: types.Props = .{ .viewport_px = .{ .width = width, .height = 67 }, .scale_milli = scale, .origin_shift_px = 11, .generation = 1, .rows = &.{
            .{ .label = "클래스", .model_index = 7, .depth = 60, .expandable = true },
            .{ .label = "long_method_name", .model_index = 8, .depth = 61, .active = true },
        } };
        const frame = try make(a, props);
        const size = view.bufferSizes(props.rows.len, frame.tree.entries.len);
        const tk = tokens.Tokens.rich(std.mem.zeroes(tokens.ThemeColors));
        const rendered = try view.view(props, frame, .{}, &tk, .{ .ops = try a.alloc(draw.Op, size.ops), .runs = try a.alloc(draw.Run, size.runs) });
        var labels: usize = 0;
        for (rendered.ops) |op| if (op == .text) {
            try std.testing.expect(op.text.scroll_clipped);
            const clip = op.text.clip.?;
            try std.testing.expect(clip.y >= 0 and clip.h <= 67);
            try std.testing.expect(op.text.origin.x >= 0);
            try std.testing.expect(@as(f32, @floatFromInt(op.text.origin.x + @as(i32, @intCast(op.text.max_width_px.?)))) <= width);
            if (op.text.text_role == .list_row) labels += 1;
        };
        if (labels != 2) for (frame.tree.entries) |entry| std.debug.print("outline width={d} scale={d} id={d} rect={any}\n", .{ width, scale, entry.id, entry.rect });
        try std.testing.expectEqual(@as(usize, 2), labels);
        try std.testing.expect(interaction.hitAction(frame.tree, 20, -1) == null);
        try std.testing.expect(interaction.hitAction(frame.tree, 20, 68) == null);
    };
}

test "outline component empty message has no action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const frame = try make(arena.allocator(), .{ .viewport_px = .{ .width = 220, .height = 80 }, .generation = 1, .rows = &.{.{ .label = "No symbols", .enabled = false }} });
    try std.testing.expectEqual(@as(usize, 0), frame.actions.len);
    try std.testing.expect(interaction.hitAction(frame.tree, 40, 10) == null);
}
