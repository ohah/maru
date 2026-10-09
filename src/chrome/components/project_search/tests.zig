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
    return .{ .viewport = .{ .width = width, .height = height }, .scale = scale, .generation = 7, .fields = .{ "한글", "", "" }, .field_labels = .{ "검색", "포함", "제외" }, .focused = 0, .options = .{ false, false, false }, .option_labels = .{ "대소문자", "단어", "정규식", "필터", "검색", "취소" }, .status = "검색 중", .scopes = "프로젝트", .expanded = false, .running = true, .can_search = true, .rows = &.{ .{ .label = "a.zig", .index = 99, .file = true }, .{ .label = "foo", .index = 100 } }, .shift = 11 };
}
test "project search dock replacement field and readonly diff share action geometry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = props(160, 300, 1000);
    p.replacing = true;
    p.previewing = true;
    p.can_apply = true;
    p.focused = 3;
    p.replacement = "한글";
    p.rows = &.{.{ .label = "- foo", .index = 0, .enabled = false, .kind = .removed }};
    const f = try make(a, p);
    var table = ids.Table.init(@constCast(f.actions));
    table.count = f.actions.len;
    try std.testing.expectEqual(@as(u32, 2), f.metrics.toolbar_rows);
    const narrow_option = f.tree.entries[f.tree.find(build.optionId(0)).?].rect;
    const narrow_run = f.tree.entries[f.tree.find(build.optionId(4)).?].rect;
    try std.testing.expect(narrow_run.y > narrow_option.y);
    const field = f.tree.entries[f.tree.find(build.fieldId(3)).?].rect;
    const field_hit = interaction.hitAction(f.tree, field.x + 10, field.y + field.height / 2).?;
    try std.testing.expectEqualDeep(ids.Intent{ .field = 3 }, table.resolve(field_hit.action_id, 7).?);
    const back = f.tree.entries[f.tree.find(build.optionId(7)).?].rect;
    const back_hit = interaction.hitAction(f.tree, back.x + back.width / 2, back.y + back.height / 2).?;
    try std.testing.expectEqualDeep(ids.Intent{ .option = 7 }, table.resolve(back_hit.action_id, 7).?);
    const row = f.tree.entries[f.tree.find(build.rowId(0)).?].rect;
    try std.testing.expect(interaction.hitAction(f.tree, row.x + 10, @max(row.y, @as(f32, @floatFromInt(f.metrics.header))) + 5) == null);
    const apply_rect = f.tree.entries[f.tree.find(build.optionId(9)).?].rect;
    const apply_hit = interaction.hitAction(f.tree, apply_rect.x + apply_rect.width / 2, apply_rect.y + apply_rect.height / 2).?;
    try std.testing.expectEqualDeep(ids.Intent{ .option = 9 }, table.resolve(apply_hit.action_id, 7).?);
    try std.testing.expect(table.resolve(apply_hit.action_id, 8) == null);
    p.viewport.width = 800;
    p.can_apply = false;
    const wide = try make(a, p);
    const disabled = wide.tree.entries[wide.tree.find(build.optionId(9)).?].rect;
    try std.testing.expect(interaction.hitAction(wide.tree, disabled.x + disabled.width / 2, disabled.y + disabled.height / 2) == null);
    const wide_option = wide.tree.entries[wide.tree.find(build.optionId(0)).?].rect;
    const wide_run = wide.tree.entries[wide.tree.find(build.optionId(4)).?].rect;
    try std.testing.expectEqual(@as(u32, 1), wide.metrics.toolbar_rows);
    try std.testing.expect(wide_run.y > wide_option.y);
    try std.testing.expectEqual(@as(f32, @floatFromInt(wide.metrics.row)), wide_run.width);
    try std.testing.expect(wide_run.x < wide_option.x);
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
    const hit = interaction.hitAction(f.tree, 20, @as(f32, @floatFromInt(f.metrics.header)) + 18).?;
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
    _ = try interaction.dispatch(&state, f.tree, .{ .phase = .down, .x_px = 20, .y_px = @as(f64, @floatFromInt(f.metrics.header)) + 18, .generation = 7, .timestamp_ns = 0 });
    const result = try interaction.dispatch(&state, f.tree, .{ .phase = .up, .x_px = 20, .y_px = @as(f64, @floatFromInt(f.metrics.header)) + 18, .generation = 8, .timestamp_ns = 0 });
    try std.testing.expect(result.action == null);
}

test "project search dock hidden fields and unavailable search commands have no action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = props(240, 200, 1000);
    p.fields[0] = "";
    p.can_search = false;
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
    for ([_]usize{ 4, 5 }) |index| {
        const rect = f.tree.entries[f.tree.find(build.optionId(index)).?].rect;
        try std.testing.expect(interaction.hitAction(f.tree, rect.x + rect.width / 2, rect.y + rect.height / 2) == null);
    }
}

test "project search dock text clips belong to individual fields buttons and rows" {
    for ([_]f32{ 48, 239, 240, 241, 801 }) |width| for ([_]f32{ 50, 250, 500 }) |height| for ([_]u32{ 1000, 1250, 2000 }) |scale| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var p = props(width, height, scale);
        p.expanded = true;
        p.fields = .{ "query", "include", "exclude" };
        const f = try make(a, p);
        const tk = tokens.Tokens.rich(std.mem.zeroes(tokens.ThemeColors));
        const rendered = try view.view(p, f, .{}, &tk, .{ .ops = try a.alloc(draw.Op, 200), .runs = try a.alloc(draw.Run, 30) });
        const names = [_][]const u8{ "query", "include", "exclude", "Aa", "Ab", ".*", "…", "▶", "■", "↔", "←", "→", "✓", p.scopes, p.status, "a.zig", "foo" };
        const names_ids = [_]u64{ 10, 11, 12, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 7, 8, build.rowId(99), build.rowId(100) };
        for (rendered.ops) |op| if (op == .text) {
            var found = false;
            for (names, names_ids) |name, id| if (std.mem.eql(u8, name, op.text.runs[0].text)) {
                found = true;
                const r = f.tree.entries[f.tree.find(id).?].rect;
                const c = op.text.clip.?;
                if (c.w == 0 or c.h == 0) continue;
                try std.testing.expect(@as(f32, @floatFromInt(c.x)) >= r.x);
                try std.testing.expect(@as(f32, @floatFromInt(c.y)) >= r.y);
                try std.testing.expect(@as(f32, @floatFromInt(@as(i64, c.x) + c.w)) <= r.x + r.width);
                try std.testing.expect(@as(f32, @floatFromInt(@as(i64, c.y) + c.h)) <= r.y + r.height);
            };
            try std.testing.expect(found);
        };
    };
}

test "project search dock disabled command semantics agree with pointer actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = props(240, 200, 1000);
    p.fields[0] = "";
    p.can_search = false;
    p.running = false;
    const f = try make(arena.allocator(), p);
    for ([_]usize{ 4, 5 }) |index| {
        const entry = f.tree.entries[f.tree.find(build.optionId(index)).?];
        try std.testing.expect(!entry.action.?.enabled);
        try std.testing.expect(!entry.semantics.?.enabled);
    }
}

test "project search dock frame and paint reject insufficient buffers without publishing a frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = props(160, 300, 1000);
    p.expanded = true;
    const n = build.size(p.rows.len);
    const complete: build.Buffers = .{ .nodes = try a.alloc(tree.UiNode, n), .entries = try a.alloc(tree.RectEntry, n), .items = try a.alloc(layout.Item, n), .flex = try a.alloc(layout.FlexScratch, n), .rects = try a.alloc(layout.UiRect, n), .actions = try a.alloc(ids.Entry, n) };
    for (0..6) |dimension| {
        var b = complete;
        switch (dimension) {
            0 => b.nodes = b.nodes[0..0],
            1 => b.entries = b.entries[0..0],
            2 => b.items = b.items[0..0],
            3 => b.flex = b.flex[0..0],
            4 => b.rects = b.rects[0..0],
            5 => b.actions = b.actions[0..0],
            else => unreachable,
        }
        if (build.build(p, b)) |_| return error.TestUnexpectedResult else |_| {}
    }
    const f = try build.build(p, complete);
    const budget = view.bufferSizes(p.rows.len, f.tree.entries.len);
    const tk = tokens.Tokens.rich(std.mem.zeroes(tokens.ThemeColors));
    const buffers: view.Buffers = .{ .ops = try a.alloc(draw.Op, budget.ops), .runs = try a.alloc(draw.Run, budget.runs) };
    _ = try view.view(p, f, .{}, &tk, buffers);
    try std.testing.expectError(error.InsufficientBuffer, view.view(p, f, .{}, &tk, .{ .ops = buffers.ops, .runs = &.{} }));
    try std.testing.expectError(error.InsufficientBuffer, view.view(p, f, .{}, &tk, .{ .ops = &.{}, .runs = buffers.runs }));
}
test "project search dock repeated row identity cannot publish ambiguous click targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = props(240, 200, 1000);
    p.rows = &.{ .{ .label = "first", .index = 1 }, .{ .label = "second", .index = 1 } };
    try std.testing.expectError(error.DuplicateIdentity, make(arena.allocator(), p));
}
test "project search dock malformed scroll and overflowing geometry fail before integer conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = props(240, 200, 1000);
    p.shift = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidGeometry, make(arena.allocator(), p));
    p.shift = 0;
    p.scale = std.math.maxInt(u32);
    const rows = try arena.allocator().alloc(types.Row, 100);
    for (rows, 0..) |*row, index| row.* = .{ .label = "row", .index = index };
    p.rows = rows;
    try std.testing.expectError(error.InvalidGeometry, make(arena.allocator(), p));
    try std.testing.expectEqual(std.math.maxInt(usize), build.size(std.math.maxInt(usize)));
}
