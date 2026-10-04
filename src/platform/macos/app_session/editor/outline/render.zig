//! 아웃라인의 typed tree 발행과 제품 Metal 텍스트 경로. 입력도 이 build를 그대로 사용한다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const AppSession = host.AppSession;
const chrome = maru.chrome;
const component = chrome.components.outline;
const dock = @import("../../dock.zig");
const outline = @import("../outline.zig");
const i18n = maru.i18n;

const Prepared = struct {
    props: component.types.Props,
    frame: component.build.Frame,
    content: maru.session.SplitRect,
};

fn prepare(self: *AppSession, arena: std.mem.Allocator) !?Prepared {
    outline.refreshForFocus(self);
    if (!dock.dockVisible(self) or self.dock.view != .outline or self.cell_width_px == 0 or self.cell_height_px == 0) return null;
    const content = dock.dockGeometry(self).tree_content;
    const width = dock.dockListTextWidthPx(self);
    if (content.w == 0 or content.h == 0 or width == 0) return null;
    const state = &self.editor_outline;
    const height = @max(outline.rowHeight(self), 1);
    const offset = @min(state.scroll.offset_y_px, outline.scrollExtent(self).max_offset_px);
    const shift = offset % height;
    const first = @min(offset / height, state.model.visible.items.len);
    const end = @min(first + (@as(usize, content.h) + shift + height - 1) / height, state.model.visible.items.len);
    const rows = try arena.alloc(component.types.Row, @max(end - first, 1));
    if (state.model.visible.items.len == 0) {
        rows[0] = .{ .label = switch (state.status) {
            .not_editor => i18n.t(.outline_open_editor),
            .pending => i18n.t(.outline_loading),
            .failed => i18n.t(.outline_failed),
            .empty, .ready => i18n.t(.symbol_picker_empty),
        }, .enabled = false };
    } else for (rows, state.model.visible.items[first..end]) |*row, index| {
        const item = state.model.items.items[index];
        row.* = .{ .label = item.symbol.label, .model_index = index, .depth = item.depth, .expandable = item.expandable, .expanded = !item.collapsed, .active = state.active == index };
    }
    const props: component.types.Props = .{
        .viewport_px = .{ .width = @floatFromInt(width), .height = @floatFromInt(content.h) },
        .scale_milli = outline.scaleMilli(self),
        .rows = rows,
        .generation = state.generation,
        .origin_shift_px = shift,
    };
    const size = component.build.bufferSizes(rows.len);
    const frame = try component.build.build(props, .{
        .nodes = try arena.alloc(chrome.ui.tree.UiNode, size.nodes),
        .entries = try arena.alloc(chrome.ui.tree.RectEntry, size.entries),
        .layout_items = try arena.alloc(chrome.ui.layout.Item, size.entries),
        .flex_scratch = try arena.alloc(chrome.ui.layout.FlexScratch, size.entries),
        .child_rects = try arena.alloc(chrome.ui.layout.UiRect, size.entries),
        .actions = try arena.alloc(component.ids.Entry, size.actions),
    });
    return .{ .props = props, .frame = frame, .content = content };
}

fn store(self: *AppSession, prepared: Prepared) !void {
    const state = &self.editor_outline;
    const frame = prepared.frame;
    // 강조 색만 바뀌는 repaint는 누름을 취소하지 않는다. 동작·기하가 바뀌면 반드시 취소한다.
    var replaced = state.published_generation != state.generation or
        !std.meta.eql(state.published_content, prepared.content) or
        state.published_offset != state.scroll.offset_y_px or state.published_scale != prepared.props.scale_milli or
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
    if (replaced) state.interaction = .{};
    state.published_generation = state.generation;
    state.published_content = prepared.content;
    state.published_offset = state.scroll.offset_y_px;
    state.published_scale = prepared.props.scale_milli;
    state.accessibility.rebuild(self.allocator, state.entries.items, state.generation);
}

/// 그리기 없는 입력·판정자도 제품과 같은 기하를 발행한다. 실패하면 옛 입력을 거둔다.
pub fn publish(self: *AppSession) bool {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const prepared = (prepare(self, arena.allocator()) catch null) orelse {
        self.editor_outline.invalidate();
        return false;
    };
    store(self, prepared) catch {
        self.editor_outline.invalidate();
        return false;
    };
    return true;
}

pub fn collect(self: *AppSession, collected: *std.ArrayList(AppSession.CollectedPane), builder: host.coretext_frame_builder.CoreTextFrameBuilder, colors: host.metal_frame.CellColors) void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prepared = (prepare(self, arena) catch null) orelse {
        self.editor_outline.invalidate();
        return;
    };
    const props = prepared.props;
    const frame = prepared.frame;
    const content = prepared.content;
    store(self, prepared) catch {
        self.editor_outline.invalidate();
        return;
    };
    const budget = component.view.bufferSizes(props.rows.len, frame.tree.entries.len);
    const tokens = self.buildChromeTokens();
    const draws = component.view.view(props, frame, self.editor_outline.interaction, &tokens, .{
        .ops = arena.alloc(chrome.draw.Op, budget.ops) catch return,
        .runs = arena.alloc(chrome.draw.Run, budget.runs) catch return,
    }) catch return;
    host.chrome_draw_lowering.appendBackgroundQuads(self.allocator, &.{draws}, &tokens, @intCast(content.x), @intCast(content.y), &self.gpu_quads, 2);
    const origin: i32 = -@as(i32, @intCast(props.origin_shift_px));
    const fingerprint = host.chrome_draw_lowering.richTextFingerprint(draws.ops, &tokens, self.cell_width_px, self.cell_height_px, @intCast(@min(content.w / self.cell_width_px, 65535)), @intCast(@min(content.h / self.cell_height_px, 65535)), origin) ^ (@as(u64, props.scale_milli) *% 0x9e3779b185ebca87);
    if (!host.MeasuredTextCache.hit(self.editor_outline.cache, fingerprint)) shape(self, draws.ops, &tokens, fingerprint, props.scale_milli, origin);
    if (self.editor_outline.cache) |*cache| {
        if (cache.fingerprint != fingerprint) return;
        self.collectMeasuredTextFromCache(collected, host.chrome_system_text.emptyDrawList(self.allocator, cache.records.len) catch return, cache, builder, .{ .x = content.x, .y = content.y, .w = @intFromFloat(props.viewport_px.width), .h = content.h }, .{ .pane = .{ .origin_x = content.x, .origin_y = content.y, .colors = colors, .scroll_delta_y_px = @floatFromInt(origin - cache.scroll_origin_y_px) } });
    }
}

fn shape(self: *AppSession, ops: []const chrome.draw.Op, tokens: *const chrome.Tokens, fingerprint: u64, scale: u32, origin: i32) void {
    const text = host.chrome_system_text;
    var request = text.prepareRequest(self.allocator, fingerprint, ops, tokens, self.cell_width_px, .{ .family = self.appearance.font.family, .fallback = self.appearance.font.fallback }) catch return;
    defer request.deinit(self.allocator);
    var unresolved = text.shapeRequest(self.allocator, &request, scale) catch return;
    defer unresolved.deinit(self.allocator);
    const artifact = text.resolveArtifact(self.allocator, &self.renderer_state.font_registry, unresolved) catch return;
    host.MeasuredTextCache.store(&self.editor_outline.cache, self.allocator, fingerprint, artifact, origin);
}
