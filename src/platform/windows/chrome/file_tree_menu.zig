//! Explorer background popup. Shared catalog and pointer capture own rows and gestures.
const std = @import("std");
const maru = @import("maru");
const menu = maru.chrome.components.context_menu;
const catalog = maru.app.file_tree_context_menu;
const input = maru.chrome.input;
const Props = maru.chrome.props.ChromeProps;
pub const Purpose = enum { file, replace_root, add_root };
pub const Request = struct { generation: u64, purpose: Purpose };
pub const PointerResult = struct { consumed: bool = false, request: ?Request = null };
pub fn labels() [3][]const u8 {
    const items = catalog.items(.background, false);
    return .{ items[0].label(), items[1].label(), items[2].label() };
}
pub const Popup = struct {
    state: menu.State = .{},
    generation: ?u64 = null,
    pressed: ?usize = null,
    swallow_left_up: bool = false,
    pub fn show(self: *Popup, generation: u64, x: i32, y: i32) void {
        self.state.show(x, y, catalog.items(.background, false).len);
        self.generation = generation;
        self.pressed = null;
        self.swallow_left_up = false;
    }
    pub fn dismiss(self: *Popup) void {
        menu.capture.dismiss(&self.state, &self.pressed, &self.swallow_left_up);
        self.generation = null;
    }
    pub fn cancelCapture(self: *Popup) void {
        self.dismiss();
        self.swallow_left_up = false;
    }
    pub fn reconcile(self: *Popup, generation: u64, blocked: bool) void {
        if (blocked or self.generation != generation) self.dismiss();
    }
    fn accept(self: *Popup, generation: u64) ?Request {
        const valid = self.state.open and self.generation != null and self.generation == generation;
        const selected = self.state.selected;
        self.dismiss();
        if (!valid) return null;
        const action = catalog.actionAt(.background, false, selected) orelse return null;
        const purpose: Purpose = switch (action) {
            .open_file => .file,
            .open_folder => .replace_root,
            .add_root => .add_root,
            else => return null,
        };
        return .{ .generation = generation, .purpose = purpose };
    }
    pub fn key(self: *Popup, event: input.InputEvent.KeyEvent, released: bool, generation: u64) ?Request {
        if (!self.state.open or released) return null;
        switch (menu.handle(event, &self.state)) {
            .accept => return self.accept(generation),
            .close => self.dismiss(),
            .selection_changed => {},
        }
        return null;
    }
    pub fn pointer(self: *Popup, event: input.PointerEvent, props: Props, generation: u64) PointerResult {
        const items = labels();
        const result = menu.capture.pointer(&self.state, &self.pressed, &self.swallow_left_up, event, props, &items);
        if (!self.state.open) self.generation = null;
        return .{ .consumed = result.consumed, .request = if (result.accept) self.accept(generation) else null };
    }
};
fn propsForTest() Props {
    return .{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 640, .backing_height_px = 480 } };
}
test "Windows explorer background menu dispatches exactly its three visible catalog rows" {
    try std.testing.expectEqual(@as(usize, 3), catalog.items(.background, false).len);
    for ([_]Purpose{ .file, .replace_root, .add_root }, 0..) |purpose, index| {
        var popup: Popup = .{};
        popup.show(7, 100, 100);
        popup.state.selected = index;
        try std.testing.expect(popup.key(.{ .key = .enter }, true, 7) == null and popup.state.open);
        const request = popup.key(.{ .key = .enter }, false, 7);
        try std.testing.expect(request != null);
        try std.testing.expectEqual(purpose, request.?.purpose);
        try std.testing.expectEqual(@as(u64, 7), request.?.generation);
        try std.testing.expect(!popup.state.open and popup.key(.{ .key = .enter }, false, 7) == null);
    }
}
test "Windows explorer background menu refuses a changed root generation" {
    var popup: Popup = .{};
    popup.show(7, 100, 100);
    try std.testing.expect(popup.key(.{ .key = .enter }, false, 8) == null and !popup.state.open);
    popup.show(7, 100, 100);
    popup.reconcile(8, false);
    try std.testing.expect(!popup.state.open);
    popup.show(7, 100, 100);
    popup.reconcile(7, true);
    try std.testing.expect(!popup.state.open);
}
test "Windows explorer background menu pointer acceptance needs a matching press and generation" {
    var popup: Popup = .{};
    popup.show(7, 100, 100);
    const props = propsForTest();
    const items = labels();
    const rect = menu.menuRect(&popup.state, &items, props).?;
    const x: f64 = @floatFromInt(rect.x + 8);
    const y: f64 = @floatFromInt(rect.y + 8);
    try std.testing.expect(popup.pointer(.{ .phase = .up, .x_px = x, .y_px = y }, props, 7).request == null);
    _ = popup.pointer(.{ .phase = .down, .x_px = x, .y_px = y }, props, 7);
    try std.testing.expect(popup.pointer(.{ .phase = .up, .x_px = x, .y_px = y }, props, 8).request == null);
}
test "Windows explorer background menu outside dismissal owns the matching release" {
    var popup: Popup = .{};
    popup.show(7, 100, 100);
    const props = propsForTest();
    const down = popup.pointer(.{ .phase = .down, .x_px = 0, .y_px = 0 }, props, 7);
    try std.testing.expect(down.consumed and down.request == null and !popup.state.open);
    const up = popup.pointer(.{ .phase = .up, .x_px = 120, .y_px = 120 }, props, 7);
    try std.testing.expect(up.consumed and up.request == null and !popup.swallow_left_up);
}
test "Windows explorer background menu matching pointer gesture opens the visible command" {
    var popup: Popup = .{};
    popup.show(7, 100, 100);
    const props = propsForTest();
    const items = labels();
    const rect = menu.menuRect(&popup.state, &items, props).?;
    const x: f64 = @floatFromInt(rect.x + 8);
    const y: f64 = @floatFromInt(rect.y + 8);
    _ = popup.pointer(.{ .phase = .down, .x_px = x, .y_px = y }, props, 7);
    const result = popup.pointer(.{ .phase = .up, .x_px = x, .y_px = y }, props, 7);
    try std.testing.expect(result.request != null);
    try std.testing.expectEqual(Purpose.file, result.request.?.purpose);
}
test "Windows explorer background menu rejects invalid row selection" {
    var popup: Popup = .{};
    popup.show(7, 100, 100);
    popup.state.selected = 3;
    try std.testing.expect(popup.key(.{ .key = .enter }, false, 7) == null and !popup.state.open);
    popup.show(7, 100, 100);
    popup.pressed = 0;
    popup.cancelCapture();
    try std.testing.expect(!popup.state.open and !popup.swallow_left_up and popup.generation == null);
}
