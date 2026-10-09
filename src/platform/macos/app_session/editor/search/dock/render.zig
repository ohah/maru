//! 아웃라인의 typed tree 발행과 제품 Metal 텍스트 경로. 입력도 이 build를 그대로 사용한다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../../app_session.zig");
const AppSession = host.AppSession;
const chrome = maru.chrome;
const component = chrome.components.project_search;
const dock = @import("../../../dock.zig");
const search_dock = @import("../dock.zig");
const i18n = maru.i18n;

const Prepared = struct {
    props: component.types.Props,
    frame: component.build.Frame,
    content: maru.session.SplitRect,
};

fn prepare(self: *AppSession, arena: std.mem.Allocator) !?Prepared {
    search_dock.refreshForFocus(self);
    if (!dock.dockVisible(self) or self.dock.view != .project_search or self.cell_width_px == 0 or self.cell_height_px == 0) return null;
    const content = dock.dockGeometry(self).tree_content;
    const width = dock.dockListTextWidthPx(self);
    if (content.w == 0 or content.h == 0 or width == 0) return null;
    const state = &self.editor_search;
    const m = search_dock.metrics(self);
    const window = state.result.model.window(m.row, search_dock.resultRect(self).h, state.scroll.offset_y_px);
    const rows = try arena.alloc(component.types.Row, window.items.len);
    for (rows, window.items, 0..) |*row, visible, index| switch (visible) {
        .file => |group_index| {
            const group = state.result.model.groups.items[group_index];
            const path = try arena.dupe(u8, group.path);
            for (path) |*byte| if (byte.* == '\n' or byte.* == '\r' or byte.* == '\t') {
                byte.* = ' ';
            };
            const source = if (group.source == .model) try std.fmt.allocPrint(arena, "{s} {d}", .{ i18n.t(.project_search_model), group_index + 1 }) else i18n.t(.project_search_disk);
            row.* = .{ .label = try std.fmt.allocPrint(arena, "{s} [{d}] {s} ({d}) [{s}]", .{ if (group.collapsed) ">" else "v", group.root_index + 1, path, group.matches, source }), .index = window.first + index, .file = true, .expanded = !group.collapsed };
        },
        .hit => |hit| {
            const match = state.result.model.rows.items[hit.row].match;
            const span = match.ranges[hit.range];
            const preview = try arena.dupe(u8, match.text);
            for (preview) |*byte| if (byte.* == '\n' or byte.* == '\r' or byte.* == '\t') {
                byte.* = ' ';
            };
            row.* = .{ .label = try std.fmt.allocPrint(arena, "  {d}: {s}", .{ span.start.line + 1, preview }), .index = window.first + index };
        },
    };
    var fields: [3][]const u8 = undefined;
    const cols = (width -| m.inset * 2) / @max(self.cell_width_px, 1);
    var carets: [3]?f32 = .{ null, null, null };
    var selections: @TypeOf(@as(component.types.Props, undefined).selections) = .{ null, null, null };
    for (&fields, &state.fields, 0..) |*text, *field, index| {
        const display = try search_dock.makeDisplay(arena, field, "", cols);
        text.* = display.text;
        if (state.focused == index and (self.blink_visible or display.selected != null)) {
            const start = if (display.selected) |selected| selected.start else display.caret;
            const end = if (display.selected) |selected| selected.end else display.caret;
            const measured = try search_dock.measure(self, display.text, .{ display.caret, start, end }, width -| m.inset * 2);
            if (self.blink_visible) carets[index] = measured[0];
            if (display.selected != null) selections[index] = .{ .left = measured[1], .right = measured[2] };
        }
    }
    var scopes: std.ArrayList(u8) = .empty;
    for (0..if (search_dock.localRoots(self)) self.file_tree.rootCount() else 0) |index| {
        if (index != 0) try scopes.appendSlice(arena, " | ");
        try scopes.appendSlice(arena, try std.fmt.allocPrint(arena, "[{d}] {s}", .{ index + 1, self.file_tree.rootAt(index).? }));
    }
    const status = if (search_dock.remote(self)) i18n.t(.project_search_remote) else if (!search_dock.localRoots(self)) i18n.t(.project_search_no_root) else if (state.nav != null) i18n.t(.project_search_running) else switch (state.result.phase) {
        .idle => i18n.t(.project_search_idle),
        .composing, .waiting => i18n.t(.project_search_waiting),
        .running => i18n.t(.project_search_running),
        .complete => i18n.t(.project_search_complete),
        .cancelled => i18n.t(.project_search_cancelled),
        .partial => i18n.t(.project_search_partial),
        .failed => i18n.t(.project_search_failed),
    };
    const count = state.result.model.matches;
    const props: component.types.Props = .{
        .viewport = .{ .width = @floatFromInt(width), .height = @floatFromInt(content.h) },
        .scale = search_dock.scaleMilli(self),
        .generation = state.result.generation,
        .fields = fields,
        .carets = carets,
        .selections = selections,
        .field_labels = .{ i18n.t(.project_search_query), i18n.t(.project_search_include), i18n.t(.project_search_exclude) },
        .focused = state.focused,
        .options = state.options,
        .option_labels = .{ i18n.t(.project_search_case), i18n.t(.project_search_word), i18n.t(.project_search_regex), i18n.t(.project_search_filters), i18n.t(.project_search_run), i18n.t(.project_search_cancel) },
        .status = if (state.result.phase == .complete and state.nav == null) try std.fmt.allocPrint(arena, "{d} {s} · {d} {s}", .{ count, i18n.t(.project_search_matches), state.result.excluded, i18n.t(.project_search_excluded) }) else try std.fmt.allocPrint(arena, "{s} · {d} {s} · {d} {s}", .{ status, count, i18n.t(.project_search_matches), state.result.excluded, i18n.t(.project_search_excluded) }),
        .scopes = scopes.items,
        .expanded = state.expanded,
        .running = state.result.phase == .running or state.result.phase == .waiting or state.nav != null,
        .can_search = search_dock.canSearch(self),
        .rows = rows,
        .shift = window.shift,
    };
    const size = component.build.size(rows.len);
    const frame = try component.build.build(props, .{
        .nodes = try arena.alloc(chrome.ui.tree.UiNode, size),
        .entries = try arena.alloc(chrome.ui.tree.RectEntry, size),
        .items = try arena.alloc(chrome.ui.layout.Item, size),
        .flex = try arena.alloc(chrome.ui.layout.FlexScratch, size),
        .rects = try arena.alloc(chrome.ui.layout.UiRect, size),
        .actions = try arena.alloc(component.ids.Entry, size),
    });
    return .{ .props = props, .frame = frame, .content = content };
}

fn store(self: *AppSession, prepared: Prepared) !void {
    const state = &self.editor_search;
    const frame = prepared.frame;
    // 강조 색만 바뀌는 repaint는 누름을 취소하지 않는다. 동작·기하가 바뀌면 반드시 취소한다.
    var replaced = state.published_generation != state.result.generation or
        !std.meta.eql(state.published_content, prepared.content) or
        state.published_offset != state.scroll.offset_y_px or state.published_scale != prepared.props.scale or
        state.entries.items.len != frame.tree.entries.len or state.actions.items.len != frame.actions.len;
    if (!replaced) {
        for (state.entries.items, frame.tree.entries) |old, new| {
            var moved = new.rect;
            moved.x += @floatFromInt(prepared.content.x);
            moved.y += @floatFromInt(prepared.content.y);
            if (old.id != new.id or !std.meta.eql(old.rect, moved)) {
                replaced = true;
                break;
            }
        }
    }
    try state.entries.ensureTotalCapacity(self.allocator, frame.tree.entries.len);
    try state.actions.ensureTotalCapacity(self.allocator, frame.actions.len);
    state.entries.clearRetainingCapacity();
    state.actions.clearRetainingCapacity();
    for (frame.tree.entries) |entry| {
        var moved = entry;
        moved.rect.x += @floatFromInt(prepared.content.x);
        moved.rect.y += @floatFromInt(prepared.content.y);
        if (moved.effective_clip) |*clip| {
            clip.x += @floatFromInt(prepared.content.x);
            clip.y += @floatFromInt(prepared.content.y);
        }
        state.entries.appendAssumeCapacity(moved);
    }
    state.actions.appendSliceAssumeCapacity(frame.actions);
    if (replaced) {
        state.interaction = .{};
        state.field_drag = null;
    }
    state.published_generation = state.result.generation;
    state.published_content = prepared.content;
    state.published_offset = state.scroll.offset_y_px;
    state.published_scale = prepared.props.scale;
    try state.accessibility.rebuildChecked(self.allocator, state.entries.items, state.result.generation);
}

/// 그리기 없는 입력·판정자도 제품과 같은 기하를 발행한다. 실패하면 옛 입력을 거둔다.
pub fn publish(self: *AppSession) bool {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const prepared = (prepare(self, arena.allocator()) catch null) orelse {
        self.editor_search.invalidate();
        return false;
    };
    store(self, prepared) catch {
        self.editor_search.invalidate();
        return false;
    };
    return true;
}

pub fn collect(self: *AppSession, collected: *std.ArrayList(AppSession.CollectedPane), builder: host.coretext_frame_builder.CoreTextFrameBuilder, colors: host.metal_frame.CellColors) void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prepared = (prepare(self, arena) catch null) orelse {
        self.editor_search.invalidate();
        return;
    };
    var painted = false;
    // 입력 표를 먼저 만들었더라도 paint 준비가 실패하면 보이지 않는 동작을 남기지 않는다.
    defer if (!painted) self.editor_search.invalidate();
    const props = prepared.props;
    const frame = prepared.frame;
    const content = prepared.content;
    store(self, prepared) catch {
        self.editor_search.invalidate();
        return;
    };
    const budget = component.view.bufferSizes(props.rows.len, frame.tree.entries.len);
    const tokens = self.buildChromeTokens();
    const draws = component.view.view(props, frame, self.editor_search.interaction, &tokens, .{
        .ops = arena.alloc(chrome.draw.Op, budget.ops) catch return,
        .runs = arena.alloc(chrome.draw.Run, budget.runs) catch return,
    }) catch return;
    host.chrome_draw_lowering.appendBackgroundQuads(self.allocator, &.{draws}, &tokens, @intCast(content.x), @intCast(content.y), &self.gpu_quads, 2);
    const origin: i32 = 0;
    const fingerprint = host.chrome_draw_lowering.richTextFingerprint(draws.ops, &tokens, self.cell_width_px, self.cell_height_px, @intCast(@min(content.w / self.cell_width_px, 65535)), @intCast(@min(content.h / self.cell_height_px, 65535)), origin) ^ (@as(u64, props.scale) *% 0x9e3779b185ebca87);
    if (!host.MeasuredTextCache.hit(self.editor_search.cache, fingerprint)) shape(self, draws.ops, &tokens, fingerprint, props.scale, origin);
    if (self.editor_search.cache) |*cache| {
        if (cache.fingerprint != fingerprint) return;
        const before = collected.items.len;
        self.collectMeasuredTextFromCache(collected, host.chrome_system_text.emptyDrawList(self.allocator, cache.records.len) catch return, cache, builder, .{ .x = content.x, .y = content.y, .w = @intFromFloat(props.viewport.width), .h = content.h }, .{ .pane = .{ .origin_x = content.x, .origin_y = content.y, .colors = colors, .scroll_delta_y_px = @floatFromInt(origin - cache.scroll_origin_y_px) } });
        painted = collected.items.len > before;
    }
}

fn shape(self: *AppSession, ops: []const chrome.draw.Op, tokens: *const chrome.Tokens, fingerprint: u64, scale: u32, origin: i32) void {
    const text = host.chrome_system_text;
    var request = text.prepareRequest(self.allocator, fingerprint, ops, tokens, self.cell_width_px, .{ .family = self.appearance.font.family, .fallback = self.appearance.font.fallback }) catch return;
    defer request.deinit(self.allocator);
    var unresolved = text.shapeRequest(self.allocator, &request, scale) catch return;
    defer unresolved.deinit(self.allocator);
    const artifact = text.resolveArtifact(self.allocator, &self.renderer_state.font_registry, unresolved) catch return;
    host.MeasuredTextCache.store(&self.editor_search.cache, self.allocator, fingerprint, artifact, origin);
}
