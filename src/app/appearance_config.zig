const std = @import("std");
const appearance = @import("../config/appearance.zig");
const terminal = @import("../terminal.zig");
const runtime = @import("runtime.zig");
const command = @import("../session/core_command.zig");
const discard = @import("typed_input_queue.zig").discardOnError;

/// The config and terminal enums have different ordinal orders. Explicit
/// mapping also makes a future variant fail at compile time instead of silently
/// choosing the wrong shape. This is the existing macOS policy.
pub fn cursorShape(value: @import("../config/theme.zig").CursorShape) terminal.CursorShape {
    return switch (value) {
        .block => .block,
        .bar => .bar,
        .underline => .underline,
    };
}
pub const Values = struct {
    palette: [16]?terminal.Rgb,
    colors: command.DefaultColors,
    cursor: terminal.CursorShape,
    pub fn fromAppearance(value: appearance.ResolvedAppearance) Values {
        return .{ .palette = value.theme.palette, .colors = .{ .foreground = value.theme.foreground, .background = value.theme.background }, .cursor = cursorShape(value.cursor.shape) };
    }
};
/// Tracks commands accepted by the reader, not reader completion. Retrying
/// only the unfinished suffix avoids resetting application palette overrides
/// or reissuing an already accepted cursor decision after queue backpressure.
pub const State = struct {
    admitted: Values,
    wanted: Values,
    pub fn init(values: Values) State {
        return .{ .admitted = values, .wanted = values };
    }
    pub fn request(self: *State, values: Values) void {
        self.wanted = values;
    }
    pub fn pending(self: *const State) bool {
        return !std.meta.eql(self.admitted, self.wanted);
    }
    pub fn pump(self: *State, target: *runtime.SurfaceRuntime, id: runtime.SurfaceId, io: std.Io) runtime.RuntimeError!void {
        self.submit(target, id, io) catch |err| {
            if (discard(err)) self.wanted = self.admitted;
            return err;
        };
    }
    fn submit(self: *State, target: *runtime.SurfaceRuntime, id: runtime.SurfaceId, io: std.Io) runtime.RuntimeError!void {
        if (!std.meta.eql(self.admitted.palette, self.wanted.palette)) {
            try target.enqueueCoreCommand(id, .{ .set_config_palette = self.wanted.palette }, io);
            self.admitted.palette = self.wanted.palette;
        }
        if (!std.meta.eql(self.admitted.colors, self.wanted.colors)) {
            try target.enqueueCoreCommand(id, .{ .set_default_colors = self.wanted.colors }, io);
            self.admitted.colors = self.wanted.colors;
        }
        if (self.admitted.cursor != self.wanted.cursor) {
            try target.enqueueCoreCommand(id, .{ .set_default_cursor_shape = self.wanted.cursor }, io);
            self.admitted.cursor = self.wanted.cursor;
        }
    }
};

const Fixture = struct {
    target: runtime.SurfaceRuntime,
    surface: @import("../session/surface.zig").Surface,
    commands: [8]command.CoreCommand,
    count: usize,
    reject_after: ?usize,
    fn init(self: *Fixture) !void {
        self.target = .init(std.testing.allocator);
        self.surface = try .init(std.testing.allocator, 45, .{ .cols = 8, .rows = 2 });
        self.count = 0;
        self.reject_after = null;
        _ = try self.target.attach(&self.surface, 9, .{ .ctx = self, .write_input = write, .resize_fn = resize, .enqueue_command = send });
    }
    fn deinit(self: *Fixture) void {
        self.target.deinit();
        self.surface.deinit();
    }
    fn send(ctx: *anyopaque, cmd: command.CoreCommand) !void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        if (self.reject_after == self.count) return error.InjectedFailure;
        self.commands[self.count] = cmd;
        self.count += 1;
        self.surface.lockCore(std.testing.io);
        defer self.surface.unlockCore(std.testing.io);
        _ = command.apply(&self.surface.core, cmd);
    }
    fn feed(self: *Fixture, bytes: []const u8) !void {
        try self.target.applyPtyEvent(.{ .output = .{ .pty_id = 9, .bytes = bytes } }, std.testing.io);
    }
    fn write(_: *anyopaque, _: []const u8) !void {
        return error.UnexpectedInput;
    }
    fn resize(_: *anyopaque, _: @import("../terminal.zig").Size) !void {}
};

fn defaults() !Values {
    return Values.fromAppearance(try appearance.resolve(.{}));
}

test "live appearance maps cursor names instead of enum ordinals" {
    try std.testing.expectEqual(terminal.CursorShape.bar, cursorShape(.bar));
    try std.testing.expectEqual(terminal.CursorShape.underline, cursorShape(.underline));
    try std.testing.expectEqual(terminal.CursorShape.block, cursorShape(.block));
}
test "live appearance updates palette and query default colors on actual core" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var state = State.init(try defaults());
    var next = try defaults();
    next.palette[2] = .{ .r = 7, .g = 8, .b = 9 };
    next.colors.foreground = .{ .r = 11, .g = 12, .b = 13 };
    state.request(next);
    try state.pump(&f.target, 45, std.testing.io);
    try std.testing.expectEqualDeep(next.palette, f.surface.core.config_palette);
    try std.testing.expectEqualDeep(next.colors.foreground, f.surface.core.default_fg_rgb);
    try std.testing.expectEqual(@as(usize, 2), f.count);
    try std.testing.expect(!state.pending());
}
test "live appearance preserves DECSCUSR override and changes its reset default" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.feed("\x1b[6 q");
    var state = State.init(try defaults());
    var next = try defaults();
    next.cursor = .underline;
    state.request(next);
    try state.pump(&f.target, 45, std.testing.io);
    try std.testing.expectEqual(terminal.CursorShape.bar, f.surface.core.cursor_shape);
    try std.testing.expectEqual(terminal.CursorShape.underline, f.surface.core.default_cursor_shape);
    try f.feed("\x1b[0 q");
    try std.testing.expectEqual(terminal.CursorShape.underline, f.surface.core.cursor_shape);
}
test "live appearance retries only unaccepted suffix and latest decision" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var state = State.init(try defaults());
    var next = try defaults();
    next.palette[2] = .{ .r = 7, .g = 8, .b = 9 };
    next.cursor = .bar;
    state.request(next);
    f.reject_after = 1;
    try std.testing.expectError(error.WriteFailed, state.pump(&f.target, 45, std.testing.io));
    try std.testing.expect(state.pending());
    try std.testing.expectEqual(terminal.CursorShape.block, state.admitted.cursor);
    next.cursor = .underline;
    state.request(next);
    f.reject_after = null;
    try state.pump(&f.target, 45, std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), f.count);
    try std.testing.expectEqual(terminal.CursorShape.underline, f.surface.core.default_cursor_shape);
}
test "live appearance discards a detached target decision" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var state = State.init(try defaults());
    var next = try defaults();
    next.cursor = .bar;
    state.request(next);
    try std.testing.expectError(error.UnknownSurface, state.pump(&f.target, 999, std.testing.io));
    try std.testing.expect(!state.pending());
    try std.testing.expectEqual(@as(usize, 0), f.count);
}
