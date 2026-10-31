//! Shared press/release capture for popup rows. Target identity and command
//! execution remain with the owner; this layer only interprets pointer input.
const menu = @import("../context_menu.zig");
const input = @import("../../input.zig");
const Props = @import("../../props.zig").ChromeProps;
pub const Result = struct { consumed: bool = false, accept: bool = false };
pub fn dismiss(state: *menu.State, pressed: *?usize, swallow_left_up: *bool) void {
    swallow_left_up.* = swallow_left_up.* or pressed.* != null;
    state.hide();
    pressed.* = null;
}
pub fn pointer(state: *menu.State, pressed: *?usize, swallow_left_up: *bool, event: input.PointerEvent, props: Props, items: []const []const u8) Result {
    if (!state.open) {
        if (!swallow_left_up.*) return .{};
        if (event.phase == .up and event.button == .left) swallow_left_up.* = false;
        return .{ .consumed = true };
    }
    const hit = menu.itemAt(state, items, props, event.x_px, event.y_px);
    switch (event.phase) {
        .move => if (hit) |row| {
            state.selected = row;
        },
        .down => {
            if (event.button != .left) {
                dismiss(state, pressed, swallow_left_up);
            } else if (hit) |row| {
                state.selected = row;
                pressed.* = row;
            } else if (!menu.contains(state, items, props, event.x_px, event.y_px)) {
                dismiss(state, pressed, swallow_left_up);
                swallow_left_up.* = true;
            } else {
                pressed.* = null;
            }
        },
        .up => if (event.button == .left) {
            const down = pressed.*;
            pressed.* = null;
            if (down != null and hit == down) return .{ .consumed = true, .accept = true };
        },
    }
    return .{ .consumed = true };
}
