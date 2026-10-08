//! 배경은 공통 painter에 맡긴다. 라벨과 입력 문자열은 발행한 사각형 안에서만 그린다.
const draw = @import("../../draw.zig");
const tk = @import("../../tokens.zig");
const interaction = @import("../../ui/interaction.zig");
const paint = @import("../../ui/paint.zig");
const types = @import("types.zig");
const build = @import("build.zig");
pub const Buffers = struct { ops: []draw.Op, runs: []draw.Run };
pub fn view(p: types.Props, f: build.Frame, state: interaction.InteractionState, tokens: *const tk.Tokens, b: Buffers) !draw.ChromeDraw {
    const painted = try paint.paint(f.tree, state, tokens, .pane_overlay, .{ .ops = b.ops });
    var count = painted.ops.len;
    var runs: usize = 0;
    for (0..3) |index| {
        if (index > 0 and !p.expanded) continue;
        try text(p, f, build.fieldId(index), if (p.fields[index].len == 0) p.field_labels[index] else p.fields[index], .surface_fg, &count, &runs, b);
    }
    const labels = [_][]const u8{ "Aa", "Ab", ".*", "…", "▶", "■" };
    for (labels, 0..) |label, index| try text(p, f, build.optionId(index), label, .surface_fg, &count, &runs, b);
    try text(p, f, 7, p.scopes, .muted_fg, &count, &runs, b);
    try text(p, f, 8, p.status, .muted_fg, &count, &runs, b);
    for (p.rows) |row| try text(p, f, build.rowId(row.index), row.label, .surface_fg, &count, &runs, b);
    return .{ .layer = .pane_overlay, .ops = b.ops[0..count] };
}
fn text(p: types.Props, f: build.Frame, id: u64, value: []const u8, role: tk.ColorRole, count: *usize, runs: *usize, b: Buffers) !void {
    _ = p;
    const entry = f.tree.entries[f.tree.find(id) orelse return];
    if (count.* >= b.ops.len or runs.* >= b.runs.len) return error.InsufficientBuffer;
    b.runs[runs.*] = .{ .text = value };
    const inset: i32 = @intCast(f.metrics.inset);
    const rect = entry.rect;
    const clip: draw.Rect = .{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .w = @intFromFloat(@max(0, rect.width)), .h = @intFromFloat(@max(0, rect.height)) };
    const effective = if (entry.effective_clip) |r| draw.Rect{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .w = @intFromFloat(@max(0, r.width)), .h = @intFromFloat(@max(0, r.height)) } else clip;
    b.ops[count.*] = .{ .text = .{ .origin = .{ .x = clip.x + inset, .y = clip.y + inset }, .runs = b.runs[runs.* .. runs.* + 1], .role = role, .text_role = .control, .max_width_px = clip.w -| @as(u32, @intCast(inset * 2)), .clip = effective, .scroll_clipped = true } };
    count.* += 1;
    runs.* += 1;
}
