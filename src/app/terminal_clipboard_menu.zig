//! Terminal clipboard popup ownership shared by native hosts. The chrome
//! component owns geometry/paint; this controller owns the stable surface target
//! and the press/release lifecycle. Clipboard access remains in the OS adapter.
const std = @import("std");
const maru = @import("maru");
const menu = maru.chrome.components.context_menu;
const input = maru.chrome.input;
const Props = maru.chrome.props.ChromeProps;

pub const Action = enum { copy, paste };
pub const Request = struct { surface_id: u64, action: Action };
pub const PointerResult = struct { consumed: bool = false, request: ?Request = null };

pub fn labels() [2][]const u8 {
    return .{ maru.i18n.t(.ctx_copy), maru.i18n.t(.ctx_paste) };
}

pub const Popup = struct {
    state: menu.State = .{},
    surface_id: ?u64 = null,
    pressed: ?usize = null,
    swallow_left_up: bool = false,

    pub fn show(self: *Popup, surface_id: u64, x: i32, y: i32) void {
        self.state.show(x, y, 2);
        self.surface_id = surface_id;
        self.pressed = null;
        self.swallow_left_up = false;
    }

    pub fn dismiss(self: *Popup) void {
        self.swallow_left_up = self.swallow_left_up or self.pressed != null;
        self.state.hide();
        self.surface_id = null;
        self.pressed = null;
    }

    pub fn cancelCapture(self: *Popup) void {
        self.dismiss();
        self.swallow_left_up = false;
    }

    pub fn reconcile(self: *Popup, current: ?u64, blocked: bool) void {
        if (blocked or self.surface_id != current) self.dismiss();
    }

    fn accept(self: *Popup, current: ?u64) ?Request {
        const target = self.surface_id;
        const selected = self.state.selected;
        const valid = self.state.open and target != null and target == current and selected < 2;
        self.dismiss();
        if (!valid) return null;
        return .{ .surface_id = target.?, .action = if (selected == 0) .copy else .paste };
    }

    pub fn key(self: *Popup, event: input.InputEvent.KeyEvent, released: bool, current: ?u64) ?Request {
        if (!self.state.open or released) return null;
        switch (menu.handle(event, &self.state)) {
            .accept => return self.accept(current),
            .close => self.dismiss(),
            .selection_changed => {},
        }
        return null;
    }

    pub fn pointer(self: *Popup, event: input.PointerEvent, props: Props, current: ?u64) PointerResult {
        if (!self.state.open) {
            if (!self.swallow_left_up) return .{};
            if (event.phase == .up and event.button == .left) self.swallow_left_up = false;
            return .{ .consumed = true };
        }
        const items = labels();
        const hit = menu.itemAt(&self.state, &items, props, event.x_px, event.y_px);
        switch (event.phase) {
            .move => if (hit) |row| {
                self.state.selected = row;
            },
            .down => {
                if (event.button != .left) {
                    self.dismiss();
                } else if (hit) |row| {
                    self.state.selected = row;
                    self.pressed = row;
                } else if (!menu.contains(&self.state, &items, props, event.x_px, event.y_px)) {
                    self.dismiss();
                    self.swallow_left_up = true;
                } else {
                    self.pressed = null;
                }
            },
            .up => if (event.button == .left) {
                const pressed = self.pressed;
                self.pressed = null;
                if (pressed != null and hit == pressed) return .{ .consumed = true, .request = self.accept(current) };
            },
        }
        return .{ .consumed = true };
    }
};

fn fixtureProps() Props {
    return .{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 640, .backing_height_px = 480 } };
}

test "Terminal clipboard popup visible padding consumes without dismissing or executing" {
    var popup: Popup = .{};
    popup.show(41, 100, 100);
    var props = fixtureProps();
    props.shape.modal_padding_px = 8;
    props.shape.corner_radius_px = 4;
    props.shape.border_width_px = 1;
    const items = labels();
    const rect = menu.menuRect(&popup.state, &items, props).?;
    const x: f64 = @floatFromInt(rect.x - 4);
    const y: f64 = @floatFromInt(rect.y + 3);
    try std.testing.expect(menu.contains(&popup.state, &items, props, x, y));
    const down = popup.pointer(.{ .phase = .down, .x_px = x, .y_px = y }, props, 41);
    try std.testing.expect(down.consumed and down.request == null and popup.state.open);
    const up = popup.pointer(.{ .phase = .up, .x_px = x, .y_px = y }, props, 41);
    try std.testing.expect(up.consumed and up.request == null and popup.state.open);
}

test "Terminal clipboard popup keyboard selection keeps stable target and ignores releases" {
    var popup: Popup = .{};
    popup.show(41, 100, 100);
    try std.testing.expect(popup.key(.{ .key = .enter }, true, 41) == null);
    try std.testing.expect(popup.state.open);
    _ = popup.key(.{ .key = .down }, false, 41);
    const request = popup.key(.{ .key = .enter }, false, 41).?;
    try std.testing.expectEqual(@as(u64, 41), request.surface_id);
    try std.testing.expectEqual(Action.paste, request.action);
    try std.testing.expect(!popup.state.open);
    try std.testing.expect(popup.key(.{ .key = .enter }, false, 41) == null);
}

test "Terminal clipboard popup foreign or missing surface cannot receive clipboard actions" {
    for ([_]?u64{ 42, null }) |current| {
        var popup: Popup = .{};
        popup.show(41, 100, 100);
        try std.testing.expect(popup.key(.{ .key = .enter }, false, current) == null);
        try std.testing.expect(!popup.state.open);
    }
}

test "Terminal clipboard popup higher overlays and surface changes revoke target" {
    var popup: Popup = .{};
    popup.show(41, 100, 100);
    popup.reconcile(41, true);
    try std.testing.expect(!popup.state.open and popup.surface_id == null);
    popup.show(41, 100, 100);
    popup.reconcile(42, false);
    try std.testing.expect(!popup.state.open);
}

test "Terminal clipboard popup requires matching pointer press and release" {
    var popup: Popup = .{};
    popup.show(41, 100, 100);
    const props = fixtureProps();
    try std.testing.expect(popup.pointer(.{ .phase = .up, .x_px = 105, .y_px = 105 }, props, 41).request == null);
    _ = popup.pointer(.{ .phase = .down, .x_px = 105, .y_px = 105 }, props, 41);
    const result = popup.pointer(.{ .phase = .up, .x_px = 105, .y_px = 105 }, props, 41);
    try std.testing.expect(result.consumed);
    try std.testing.expect(result.request != null);
    try std.testing.expectEqual(Action.copy, result.request.?.action);
    try std.testing.expect(popup.pointer(.{ .phase = .up, .x_px = 105, .y_px = 105 }, props, 41).request == null);
}

test "Terminal clipboard popup release on another row cannot choose it" {
    var popup: Popup = .{};
    popup.show(41, 100, 100);
    const props = fixtureProps();
    _ = popup.pointer(.{ .phase = .down, .x_px = 105, .y_px = 105 }, props, 41);
    try std.testing.expect(popup.pointer(.{ .phase = .up, .x_px = 105, .y_px = 121 }, props, 41).request == null);
    try std.testing.expect(popup.state.open);
}

test "Terminal clipboard popup outside dismissal owns release and capture loss clears it" {
    var popup: Popup = .{};
    popup.show(41, 100, 100);
    const props = fixtureProps();
    try std.testing.expect(popup.pointer(.{ .phase = .down, .x_px = 500, .y_px = 400 }, props, 41).consumed);
    try std.testing.expect(!popup.state.open and popup.swallow_left_up);
    try std.testing.expect(popup.pointer(.{ .phase = .up, .x_px = 500, .y_px = 400 }, props, 41).consumed);
    try std.testing.expect(!popup.swallow_left_up);
    popup.show(41, 100, 100);
    _ = popup.pointer(.{ .phase = .down, .x_px = 105, .y_px = 105 }, props, 41);
    popup.cancelCapture();
    try std.testing.expect(!popup.state.open and popup.pressed == null and !popup.swallow_left_up);
}

test "Terminal clipboard popup keyboard dismissal cannot leak a held pointer release" {
    var popup: Popup = .{};
    popup.show(41, 100, 100);
    const props = fixtureProps();
    _ = popup.pointer(.{ .phase = .down, .x_px = 105, .y_px = 105 }, props, 41);
    _ = popup.key(.{ .key = .escape }, false, 41);
    try std.testing.expect(!popup.state.open and popup.swallow_left_up);
}

test "Terminal clipboard popup shares clamped paint and hit geometry" {
    var popup: Popup = .{};
    popup.show(41, 639, 479);
    const props = fixtureProps();
    const items = labels();
    const rect = menu.menuRect(&popup.state, &items, props).?;
    try std.testing.expect(rect.x >= 0 and rect.y >= 0 and rect.x + @as(i32, @intCast(rect.w)) <= 640 and rect.y + @as(i32, @intCast(rect.h)) <= 480);
    const x: f64 = @floatFromInt(rect.x + 3);
    const y: f64 = @floatFromInt(rect.y + 3);
    _ = popup.pointer(.{ .phase = .down, .x_px = x, .y_px = y }, props, 41);
    try std.testing.expectEqual(Action.copy, popup.pointer(.{ .phase = .up, .x_px = x, .y_px = y }, props, 41).request.?.action);
}
