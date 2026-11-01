//! Settings scrollbar adapter. Paint and hit geometry come from the same
//! published ScrollArea tree; the shared drag keeps its original grab point.
const std = @import("std");
const maru = @import("maru");
const ui = maru.chrome.ui;
const area = ui.scroll_area;
pub const metrics: area.ScrollbarMetrics = .{ .width_px = 8, .inset_x_px = 8, .min_thumb_px = 24 };
const track_id = 0x73657402;
const thumb_id = 0x73657403;
const payload = 0x73657404;

pub const Bar = struct {
    entries: [3]ui.tree.RectEntry = undefined,
    count: usize = 0,
    generation: u64 = 0,
    interaction: ui.interaction.InteractionState = .{},
    drag: area.Drag = .{},
    geometry: ?area.ScrollbarGeometry = null,

    pub fn cancel(self: *Bar) void {
        self.drag.end();
        self.interaction = .{};
    }
    pub fn hide(self: *Bar) void {
        self.cancel();
        self.count = 0;
        self.geometry = null;
    }
    fn snapshot(self: *const Bar) ui.tree.UiRectTree {
        return .{ .entries = self.entries[0..self.count], .generation = self.generation };
    }
    fn compatible(a: area.ScrollbarGeometry, b: area.ScrollbarGeometry) bool {
        // Thumb position follows scrolling; the range and track must stay fixed.
        return a.track_x == b.track_x and a.track_y == b.track_y and a.track_w == b.track_w and a.track_h == b.track_h and a.thumb_h == b.thumb_h and a.max_offset_px == b.max_offset_px;
    }
    pub fn publish(self: *Bar, view: maru.chrome.components.settings.ScrollView, ch: u32, tk: *const maru.chrome.Tokens, a: std.mem.Allocator, out: *std.ArrayList(maru.chrome.draw.Op)) !void {
        // Failed paint must not publish invisible interactive targets.
        errdefer self.hide();
        if (ch == 0 or view.visible == 0 or view.total <= view.visible) {
            self.hide();
            return;
        }
        var items: [3]ui.layout.Item = undefined;
        var flex: [3]ui.layout.FlexScratch = undefined;
        var rects: [3]ui.layout.UiRect = undefined;
        const node = ui.tree.scrollArea(.{ .id = 0x73657401, .scroll = .{
            .offset_px = @as(u32, @intCast(view.win_start)) * ch,
            .content_h_px = @as(u32, @intCast(view.total)) * ch,
            .gutter_px = @floatFromInt(metrics.gutterPx()),
            .metrics = metrics,
            .drag = .{ .payload = payload, .axis = .vertical, .threshold_px = 0 },
            .track = .{ .id = track_id, .action = .{ .id = track_id }, .paint = .{ .background = .surface_bg } },
            .thumb = .{ .id = thumb_id, .action = .{ .id = thumb_id }, .paint = .{ .background = .muted_fg, .corner_radii_px = .{ 4, 4, 4, 4 } } },
        } }, &.{});
        const built = ui.tree.build(node, .{ .root_size = .{ .width = @floatFromInt(view.viewport.w), .height = @floatFromInt(view.viewport.h) }, .max_entries = 3, .max_depth = 2 }, .{ .entries = &self.entries, .items = &items, .flex_scratch = &flex, .child_rects = &rects }) catch |err| {
            self.hide();
            return err;
        };
        self.count = built.entries.len;
        self.generation +|= 1;
        var track: ?ui.layout.UiRect = null;
        var thumb: ?ui.layout.UiRect = null;
        for (self.entries[0..self.count]) |*entry| {
            entry.rect.x += @floatFromInt(view.viewport.x);
            entry.rect.y += @floatFromInt(view.viewport.y);
            if (entry.effective_clip) |*clip| {
                clip.x += @floatFromInt(view.viewport.x);
                clip.y += @floatFromInt(view.viewport.y);
            }
            // Publish the full gutter as the track surface, not a separate
            // invisible host hit box. Paint and typed capture see this same rect.
            if (entry.id == track_id) {
                const gutter: f32 = @floatFromInt(metrics.gutterPx());
                entry.rect.x -= (gutter - entry.rect.width) / 2;
                entry.rect.width = gutter;
            }
            if (entry.id == track_id) track = entry.rect;
            if (entry.id == thumb_id) thumb = entry.rect;
        }
        const t = track orelse {
            self.hide();
            return;
        };
        const h = thumb orelse {
            self.hide();
            return;
        };
        const live: area.ScrollbarGeometry = (area.ScrollbarGeometry{
            .track_x = h.x,
            .track_y = t.y,
            .track_w = h.width,
            .track_h = t.height,
            .hit_x = t.x,
            .hit_w = t.width,
            .thumb_y = h.y,
            .thumb_h = h.height,
            .max_offset_px = @as(u32, @intCast(view.total - view.visible)) * ch,
        });
        if (self.drag.active) {
            if (!compatible(self.drag.geometry, live)) self.cancel() else {
                const key: ui.interaction.GestureCompatibility = .{ .kind = payload, .enabled = true, .owner_epoch = 0, .domain_identity = 0 };
                _ = ui.interaction.reconcileCarryingCapture(&self.interaction, self.snapshot(), key, key) catch {
                    self.cancel();
                    return;
                };
                if (self.interaction.capture == null) self.cancel();
            }
        }
        self.geometry = live;
        var ops: [3]maru.chrome.draw.Op = undefined;
        const draws = try ui.paint.paint(self.snapshot(), self.interaction, tk, .sidebar, .{ .ops = &ops });
        try out.appendSlice(a, draws.ops);
    }
    fn apply(self: *Bar, scroll: *area.State) void {
        if (self.drag.takeOffset()) |offset| _ = scroll.setOffsetPx(offset, self.drag.geometry.max_offset_px);
    }
    pub fn tick(self: *Bar, scroll: *area.State) void {
        self.apply(scroll);
    }
    pub fn pointer(self: *Bar, event: maru.chrome.input.PointerEvent, scroll: *area.State) bool {
        const bar = self.geometry orelse return false;
        if (event.button != .left) return self.drag.active;
        var jumped: ?u32 = null;
        if (!self.drag.active) {
            if (event.phase != .down or !bar.trackContains(event.x_px, event.y_px)) return false;
            jumped = self.drag.begin(bar, event.x_px, event.y_px);
        }
        // A down/up pair can contain no move message. Interaction then reports
        // a click rather than a drag, but release still owns the final offset.
        if (event.phase == .up) self.drag.absorb(event.x_px, event.y_px);
        const result = ui.interaction.dispatch(&self.interaction, self.snapshot(), .{
            .phase = switch (event.phase) {
                .down => .down,
                .move => .move,
                .up => .up,
            },
            .x_px = event.x_px,
            .y_px = event.y_px,
            .button = event.button,
            .timestamp_ns = 0,
            .generation = self.generation,
        }) catch {
            self.cancel();
            return true;
        };
        if (event.phase == .down and self.interaction.capture == null) {
            self.cancel();
            return true;
        }
        if (jumped) |offset| _ = scroll.setOffsetPx(offset, bar.max_offset_px);
        if (result.drag) |drag_event| switch (drag_event) {
            .began, .moved => |update| self.drag.absorb(update.x_px, update.y_px),
            .dropped => |update| {
                self.drag.absorb(update.x_px, update.y_px);
                self.apply(scroll);
                self.cancel();
            },
            .cancelled => self.cancel(),
        };
        if (event.phase == .up) {
            self.apply(scroll);
            self.cancel();
        }
        return true;
    }
};
