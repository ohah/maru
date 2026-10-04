//! 면은 공통 semantic painter가, 라벨·펼침 아이콘은 완성된 tree의 사각형이 소유한다.
const draw = @import("../../draw.zig");
const tokens = @import("../../tokens.zig");
const interaction = @import("../../ui/interaction.zig");
const paint = @import("../../ui/paint.zig");
const layout = @import("../../ui/layout.zig");
const icons = @import("../../../icons.zig");
const types = @import("types.zig");
const build_mod = @import("build.zig");

pub const Buffers = struct { ops: []draw.Op, runs: []draw.Run };
pub const ViewError = paint.PaintError || error{InsufficientBuffer};
pub fn bufferSizes(row_count: usize, entry_count: usize) struct { ops: usize, runs: usize } {
    return .{ .ops = entry_count + row_count * 2, .runs = row_count * 2 };
}

fn rectOf(r: layout.UiRect) draw.Rect {
    return .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .w = @intFromFloat(@max(r.width, 0)), .h = @intFromFloat(@max(r.height, 0)) };
}

pub fn view(props: types.Props, frame: build_mod.Frame, state: interaction.InteractionState, tk: *const tokens.Tokens, buffers: Buffers) ViewError!draw.ChromeDraw {
    const painted = try paint.paint(frame.tree, state, tk, .pane_overlay, .{ .ops = buffers.ops });
    var count = painted.ops.len;
    var runs: usize = 0;
    for (props.rows) |row| {
        const entry = frame.tree.entries[frame.tree.find(build_mod.rowId(row.model_index)) orelse continue];
        const disclosure = frame.tree.entries[frame.tree.find(build_mod.disclosureId(row.model_index)) orelse continue];
        const clip: ?draw.Rect = if (entry.effective_clip) |r| rectOf(r) else null;
        if (row.expandable) {
            if (count == buffers.ops.len or runs == buffers.runs.len) return error.InsufficientBuffer;
            const value = if (row.expanded) icons.utf8Fit(.chevron_down, .tight) else icons.utf8Fit(.chevron_right, .tight);
            const cp = if (row.expanded) icons.codepointFit(.chevron_down, .tight) else icons.codepointFit(.chevron_right, .tight);
            buffers.runs[runs] = .{ .text = value };
            const rect = rectOf(disclosure.rect);
            buffers.ops[count] = .{ .text = .{ .origin = .{ .x = rect.x, .y = rect.y }, .runs = buffers.runs[runs .. runs + 1], .role = .list_secondary_fg, .text_role = .control, .max_width_px = rect.w, .clip = clip, .scroll_clipped = true, .placement = .{ .icon_in_rect = .{ .content_rect = rect, .icon_codepoint = cp, .icon_extent_px = @intCast(@min(frame.metrics.disclosure, 65535)) } } } };
            count += 1;
            runs += 1;
        }
        const x = disclosure.rect.x + disclosure.rect.width;
        const width = @max(0, entry.rect.x + entry.rect.width - x - @as(f32, @floatFromInt(frame.metrics.inset)));
        if (width < 1) continue;
        if (count == buffers.ops.len or runs == buffers.runs.len) return error.InsufficientBuffer;
        buffers.runs[runs] = .{ .text = row.label, .bold = row.active };
        buffers.ops[count] = .{ .text = .{
            .origin = .{ .x = @intFromFloat(x), .y = @intFromFloat(entry.rect.y + @as(f32, @floatFromInt(frame.metrics.row_h -| frame.metrics.label_h)) / 2) },
            .runs = buffers.runs[runs .. runs + 1],
            .role = if (row.enabled) .surface_fg else .muted_fg,
            .text_role = .list_row,
            .max_width_px = @intFromFloat(width),
            .clip = clip,
            .scroll_clipped = true,
        } };
        count += 1;
        runs += 1;
    }
    return .{ .layer = .pane_overlay, .ops = buffers.ops[0..count] };
}
