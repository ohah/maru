//! Text-only live configuration. Admission snapshots retain failed commands,
//! while irreversible scrollback shrink requires an explicit user decision.
const std = @import("std");
const config = @import("../config.zig");
const runtime = @import("runtime.zig");
const discard = @import("typed_input_queue.zig").discardOnError;
const command = @import("../session/core_command.zig");

/// Automatic refresh and preview may grow history, but may never erase it.
/// This is the existing macOS reload policy, shared with native Windows.
pub fn liveScrollbackTarget(current: u32, requested: u32, explicit: bool) u32 {
    return if (explicit) requested else @max(current, requested);
}
pub const Values = struct {
    scrollback: u32,
    ambiguous_wide: bool,
    emoji_wide: bool,
    pub fn fromConfig(cfg: config.Config) Values {
        return .{ .scrollback = cfg.scrollback.lines, .ambiguous_wide = cfg.ambiguous_width == .wide, .emoji_wide = cfg.emoji_width == .wide };
    }
};
pub const State = struct {
    admitted: Values,
    wanted: Values,
    shrink_authority: ?u32 = null,
    pub fn init(values: Values) State {
        return .{ .admitted = values, .wanted = values };
    }
    pub fn request(self: *State, values: Values, explicit_shrink: bool) void {
        if (self.shrink_authority != values.scrollback) self.shrink_authority = null;
        if (explicit_shrink) self.shrink_authority = values.scrollback;
        self.wanted = values;
        self.wanted.scrollback = liveScrollbackTarget(self.admitted.scrollback, values.scrollback, self.shrink_authority == values.scrollback);
        if (self.wanted.scrollback == self.admitted.scrollback) self.shrink_authority = null;
    }
    pub fn pending(self: *const State) bool {
        return !std.meta.eql(self.admitted, self.wanted);
    }
    pub fn pump(self: *State, target: *runtime.SurfaceRuntime, id: runtime.SurfaceId, io: std.Io) runtime.RuntimeError!void {
        self.submit(target, id, io) catch |err| {
            if (discard(err)) {
                self.wanted = self.admitted;
                self.shrink_authority = null;
            }
            return err;
        };
    }
    fn submit(self: *State, target: *runtime.SurfaceRuntime, id: runtime.SurfaceId, io: std.Io) runtime.RuntimeError!void {
        if (self.admitted.scrollback != self.wanted.scrollback) {
            try target.enqueueCoreCommand(id, .{ .set_max_scrollback = self.wanted.scrollback }, io);
            self.admitted.scrollback = self.wanted.scrollback;
            self.shrink_authority = null;
        }
        if (self.admitted.ambiguous_wide != self.wanted.ambiguous_wide) {
            try target.enqueueCoreCommand(id, .{ .set_ambiguous_wide = self.wanted.ambiguous_wide }, io);
            self.admitted.ambiguous_wide = self.wanted.ambiguous_wide;
        }
        if (self.admitted.emoji_wide != self.wanted.emoji_wide) {
            try target.enqueueCoreCommand(id, .{ .set_emoji_wide = self.wanted.emoji_wide }, io);
            self.admitted.emoji_wide = self.wanted.emoji_wide;
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
fn defaults() Values {
    return Values.fromConfig(.{});
}

test "live text config shares non-destructive scrollback policy and typed mapping" {
    try std.testing.expectEqual(@as(u32, 5000), liveScrollbackTarget(5000, 5, false));
    try std.testing.expectEqual(@as(u32, 8000), liveScrollbackTarget(5000, 8000, false));
    try std.testing.expectEqual(@as(u32, 0), liveScrollbackTarget(5000, 0, true));
    var cfg: config.Config = .{};
    cfg.scrollback.lines = 73;
    cfg.ambiguous_width = .wide;
    cfg.emoji_width = .narrow;
    const values = Values.fromConfig(cfg);
    try std.testing.expectEqual(@as(u32, 73), values.scrollback);
    try std.testing.expect(values.ambiguous_wide and !values.emoji_wide);
}
test "live text config changes future cell width without preview history loss" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.feed("0\r\n1\r\n2\r\n3\r\n");
    const history = f.surface.core.screen.sb.count;
    try std.testing.expect(history > 0);
    var state = State.init(defaults());
    state.request(.{ .scrollback = 0, .ambiguous_wide = true, .emoji_wide = false }, false);
    try state.pump(&f.target, 45, std.testing.io);
    try std.testing.expectEqual(history, f.surface.core.screen.sb.count);
    try std.testing.expect(f.surface.core.ambiguous_wide and !f.surface.core.emoji_wide);
    try f.feed("\x1b[H\xe2\x91\xa2");
    try std.testing.expectEqual(@as(u16, 2), f.surface.core.screen.cursor.col);
    try std.testing.expectEqual(@as(usize, 2), f.count);
    try std.testing.expect(f.commands[0] == .set_ambiguous_wide and f.commands[1] == .set_emoji_wide);
}
test "live text config explicit shrink survives failure but is consumed once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.feed("0\r\n1\r\n2\r\n3\r\n");
    var state = State.init(defaults());
    var values = defaults();
    values.scrollback = 0;
    state.request(values, true);
    f.reject_after = 0;
    try std.testing.expectError(error.WriteFailed, state.pump(&f.target, 45, std.testing.io));
    try std.testing.expect(state.pending() and state.shrink_authority == 0);
    state.request(values, false);
    f.reject_after = null;
    try state.pump(&f.target, 45, std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), f.surface.core.screen.sb.count);
    try std.testing.expect(state.shrink_authority == null);
    state.request(defaults(), false);
    try state.pump(&f.target, 45, std.testing.io);
    state.request(values, false);
    try std.testing.expect(!state.pending());
    try std.testing.expectEqual(@as(u32, 1000), state.admitted.scrollback);
}
test "live text config retains accepted prefix and replaces stale retry target" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var state = State.init(defaults());
    state.request(.{ .scrollback = 2000, .ambiguous_wide = true, .emoji_wide = false }, false);
    f.reject_after = 1;
    try std.testing.expectError(error.WriteFailed, state.pump(&f.target, 45, std.testing.io));
    try std.testing.expectEqual(@as(u32, 2000), state.admitted.scrollback);
    try std.testing.expect(!state.admitted.ambiguous_wide and state.admitted.emoji_wide);
    state.request(.{ .scrollback = 2000, .ambiguous_wide = false, .emoji_wide = false }, false);
    f.reject_after = null;
    try state.pump(&f.target, 45, std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), f.count);
    try std.testing.expect(f.commands[0] == .set_max_scrollback and f.commands[1] == .set_emoji_wide);
    try std.testing.expect(!state.pending());
}
test "live text config drops a dead target without replaying its pending decision" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var state = State.init(defaults());
    var values = defaults();
    values.scrollback = 0;
    state.request(values, true);
    try std.testing.expectError(error.UnknownSurface, state.pump(&f.target, 99, std.testing.io));
    try std.testing.expect(!state.pending() and state.shrink_authority == null);
    try std.testing.expectEqual(@as(usize, 0), f.count);
}
