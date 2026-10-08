//! 실제 발행 tree로 고정 머리·클리핑·낡은 입력을 검사한다.
const std = @import("std");
const build = @import("build.zig");
const view = @import("view.zig");
const types = @import("types.zig");
const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
const ids = @import("ids.zig");
const interaction = @import("../../ui/interaction.zig");
const draw = @import("../../draw.zig");
const tokens = @import("../../tokens.zig");
fn make(a: std.mem.Allocator, p: types.Props) !build.Frame {
    const n = build.size(p.rows.len);
    return build.build(p, .{ .nodes = try a.alloc(tree.UiNode, n), .entries = try a.alloc(tree.RectEntry, n), .items = try a.alloc(layout.Item, n), .flex = try a.alloc(layout.FlexScratch, n), .rects = try a.alloc(layout.UiRect, n), .actions = try a.alloc(ids.Entry, n) });
}
fn props(width: f32, height: f32, scale: u32) types.Props {
    return .{ .viewport = .{ .width = width, .height = height }, .scale = scale, .generation = 7, .fields = .{ "한글", "", "" }, .field_labels = .{ "검색", "포함", "제외" }, .focused = 0, .options = .{ false, false, false }, .option_labels = .{ "대소문자", "단어", "정규식", "필터", "검색", "취소" }, .status = "검색 중", .scopes = "프로젝트", .expanded = false, .running = true, .rows = &.{ .{ .label = "a.zig", .index = 99, .file = true }, .{ .label = "foo", .index = 100 } }, .shift = 11 };
}
test "project search dock fixed header and row identity share published geometry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = props(240, 200, 1000);
    const f = try make(arena.allocator(), p);
    var table = ids.Table.init(@constCast(f.actions));
    table.count = f.actions.len;
    const field = interaction.hitAction(f.tree, 20, 10).?;
    try std.testing.expectEqualDeep(ids.Intent{ .field = 0 }, table.resolve(field.action_id, 7).?);
    const hit = interaction.hitAction(f.tree, 20, 130).?;
    try std.testing.expectEqualDeep(ids.Intent{ .row = 100 }, table.resolve(hit.action_id, 7).?);
    try std.testing.expect(interaction.hitAction(f.tree, 20, 201) == null);
}
test "project search dock clips header and rows in short narrow scaled viewports" {
    for ([_]u32{ 1000, 2000 }) |scale| for ([_]f32{ 48, 240 }) |width| for ([_]f32{ 50, 300 }) |height| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const p = props(width, height, scale);
        const f = try make(a, p);
        const tk = tokens.Tokens.rich(std.mem.zeroes(tokens.ThemeColors));
        const rendered = try view.view(p, f, .{}, &tk, .{ .ops = try a.alloc(draw.Op, 200), .runs = try a.alloc(draw.Run, 30) });
        for (rendered.ops) |op| if (op == .text) {
            const clip = op.text.clip.?;
            try std.testing.expect(clip.y >= 0);
            try std.testing.expect(clip.y + @as(i32, @intCast(clip.h)) <= @as(i32, @intFromFloat(height)));
        };
        try std.testing.expect(interaction.hitAction(f.tree, 20, height + 1) == null);
    };
}
test "project search dock stale generation cannot release an old pressed row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try make(arena.allocator(), props(240, 200, 1000));
    var state: interaction.InteractionState = .{};
    _ = try interaction.dispatch(&state, f.tree, .{ .phase = .down, .x_px = 20, .y_px = 130, .generation = 7, .timestamp_ns = 0 });
    const result = try interaction.dispatch(&state, f.tree, .{ .phase = .up, .x_px = 20, .y_px = 130, .generation = 8, .timestamp_ns = 0 });
    try std.testing.expect(result.action == null);
}

test "project search dock hidden fields and unavailable search commands have no action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = props(240, 200, 1000);
    p.fields[0] = "";
    p.running = false;
    const f = try make(arena.allocator(), p);
    var table = ids.Table.init(@constCast(f.actions));
    table.count = f.actions.len;
    for (f.actions) |entry| {
        switch (entry.intent) {
            .field => |index| try std.testing.expectEqual(@as(usize, 0), index),
            .run, .cancel => try std.testing.expect(table.resolve(entry.action_id, 7) == null),
            else => {},
        }
    }
    try std.testing.expect(interaction.hitAction(f.tree, 180, 40) == null);
    try std.testing.expect(interaction.hitAction(f.tree, 220, 40) == null);
}
