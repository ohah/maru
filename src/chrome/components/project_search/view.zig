//! 배경은 공통 painter에 맡긴다. 라벨과 입력 문자열은 발행한 사각형 안에서만 그린다.
const draw = @import("../../draw.zig");
const tk = @import("../../tokens.zig");
const interaction = @import("../../ui/interaction.zig");
const paint = @import("../../ui/paint.zig");
const types = @import("types.zig");
const build = @import("build.zig");
const layout = @import("../../ui/layout.zig");
const icons = @import("../../../icons.zig");
const spacing = @import("../../ui/spacing.zig");
pub const Buffers = struct { ops: []draw.Op, runs: []draw.Run };
pub fn bufferSizes(row_count: usize, entry_count: usize) struct { ops: usize, runs: usize } {
    const runs = row_count +| 16;
    return .{ .ops = entry_count +| runs +| 6, .runs = runs };
}
pub fn view(p: types.Props, f: build.Frame, state: interaction.InteractionState, tokens: *const tk.Tokens, b: Buffers) !draw.ChromeDraw {
    const painted = try paint.paint(f.tree, state, tokens, .pane_overlay, .{ .ops = b.ops });
    var count = painted.ops.len;
    var runs: usize = 0;
    const selections = p.selections ++ [1]?types.Selection{p.replacement_selection};
    for (selections, 0..) |selected, index| if (selected) |range| {
        const entry = f.tree.entries[f.tree.find(build.fieldId(index)) orelse continue];
        const clipped = if (entry.effective_clip) |outer| layout.intersectRect(outer, entry.rect) else entry.rect;
        if (count >= b.ops.len) return error.InsufficientBuffer;
        const left = @min(range.left, range.right);
        const right = @max(range.left, range.right);
        b.ops[count] = .{ .quad = .{ .rect = .{ .x = @intFromFloat(entry.rect.x + @as(f32, @floatFromInt(f.metrics.inset)) + left), .y = @intFromFloat(entry.rect.y + @as(f32, @floatFromInt(f.metrics.inset))), .w = @intFromFloat(@max(0, right - left)), .h = f.metrics.row -| f.metrics.inset * 2 }, .fill_role = .selection, .clip = .{ .x = @intFromFloat(clipped.x), .y = @intFromFloat(clipped.y), .w = @intFromFloat(@max(0, clipped.width)), .h = @intFromFloat(@max(0, clipped.height)) } } };
        count += 1;
    };

    for (0..3) |index| {
        if (index > 0 and !p.expanded) continue;
        try text(p, f, build.fieldId(index), if (p.fields[index].len == 0) p.field_labels[index] else p.fields[index], if (p.fields[index].len == 0) .muted_fg else .surface_fg, &count, &runs, b);
    }
    if (p.replacing) try text(p, f, build.fieldId(3), if (p.replacement.len == 0) p.replacement_label else p.replacement, .surface_fg, &count, &runs, b);
    const labels = [_][]const u8{ "Aa", "Ab", ".*", "…", "▶", "■", "↔", "←", "→", "✓" };
    for (labels, 0..) |label, index| try text(p, f, build.optionId(index), label, .surface_fg, &count, &runs, b);
    try text(p, f, 7, p.scopes, .muted_fg, &count, &runs, b);
    try text(p, f, 8, p.status, .muted_fg, &count, &runs, b);
    for (p.rows) |row| try text(p, f, build.rowId(row.index), row.label, .surface_fg, &count, &runs, b);
    const carets = p.carets ++ [1]?f32{p.replacement_caret};
    for (carets, 0..) |caret, index| if (caret) |x| {
        const entry = f.tree.entries[f.tree.find(build.fieldId(index)) orelse continue];
        const clipped = if (entry.effective_clip) |outer| layout.intersectRect(outer, entry.rect) else entry.rect;
        if (count >= b.ops.len) return error.InsufficientBuffer;
        b.ops[count] = .{ .quad = .{ .rect = .{ .x = @intFromFloat(entry.rect.x + @as(f32, @floatFromInt(f.metrics.inset)) + x), .y = @intFromFloat(entry.rect.y + @as(f32, @floatFromInt(f.metrics.inset))), .w = @max(1, p.scale / 1000), .h = f.metrics.row -| f.metrics.inset * 2 }, .fill_role = .surface_fg, .clip = .{ .x = @intFromFloat(clipped.x), .y = @intFromFloat(clipped.y), .w = @intFromFloat(@max(0, clipped.width)), .h = @intFromFloat(@max(0, clipped.height)) } } };
        count += 1;
    };
    return .{ .layer = .pane_overlay, .ops = b.ops[0..count] };
}
fn text(p: types.Props, f: build.Frame, id: u64, value: []const u8, role: tk.ColorRole, count: *usize, runs: *usize, b: Buffers) !void {
    const entry = f.tree.entries[f.tree.find(id) orelse return];
    if (count.* >= b.ops.len or runs.* >= b.runs.len) return error.InsufficientBuffer;
    b.runs[runs.*] = .{ .text = value };
    const inset: i32 = @intCast(f.metrics.inset);
    const horizontal_inset = if (id >= 20 and id < 30) @divTrunc(inset, 2) else inset;
    const rect = entry.rect;
    const clip: draw.Rect = .{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .w = @intFromFloat(@max(0, rect.width)), .h = @intFromFloat(@max(0, rect.height)) };
    // 조상 clip뿐 아니라 이 텍스트를 소유하는 면에도 묶는다. 긴 미리보기가 옆 행을 덮지 않는다.
    const clipped = if (entry.effective_clip) |r| layout.intersectRect(r, rect) else rect;
    // 소수 경계에서도 글자가 자기 면을 넘지 않게 가까운 변은 올리고 먼 변은 내린다.
    const left = @ceil(clipped.x);
    const top = @ceil(clipped.y);
    const effective: draw.Rect = .{ .x = @intFromFloat(left), .y = @intFromFloat(top), .w = @intFromFloat(@max(0, @floor(clipped.x + clipped.width) - left)), .h = @intFromFloat(@max(0, @floor(clipped.y + clipped.height) - top)) };
    // 탐색·펼침은 다른 Chrome 표면과 같은 SVG 슬롯을 쓴다. 텍스트 기호의 폰트별 모양에 기대지 않는다.
    const icon: ?icons.Icon = switch (id) {
        20 => .search_case,
        21 => .search_word,
        22 => .search_regex,
        23 => .search_filter,
        24 => .search,
        25 => .search_stop,
        26 => if (p.replacing) .chevron_down else .chevron_right,
        27 => .arrow_left,
        28 => .arrow_right,
        29 => .check,
        else => null,
    };
    b.ops[count.*] = .{ .text = .{ .origin = .{ .x = clip.x + horizontal_inset, .y = clip.y + inset }, .runs = b.runs[runs.* .. runs.* + 1], .placement = if (icon) |source| .{ .icon_in_rect = .{ .content_rect = clip, .icon_codepoint = icons.codepoint(source), .icon_extent_px = @intCast(spacing.pointsPx(14, p.scale)) } } else if (id >= 20 and id < 30) .{ .center_in_rect = clip } else .origin, .anchor = if (id >= 10 and id <= 13) .tail else .head, .role = if (entry.semantics != null and !entry.semantics.?.enabled) .muted_fg else role, .text_role = .control, .max_width_px = clip.w -| @as(u32, @intCast(horizontal_inset * 2)), .clip = effective, .scroll_clipped = true, .above_scroll = true } };
    count.* += 1;
    runs.* += 1;
}
