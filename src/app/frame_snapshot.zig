//! Copy terminal inputs under the surface lock, then shape only owned data.
const std = @import("std");
const renderer = @import("../renderer.zig");
const surface_mod = @import("../session/surface.zig");

pub const Snapshot = struct {
    draw_list: renderer.DrawList,
    view_offset: usize,
};

/// The caller owns draw_list even after the live core changes. Scroll provenance
/// is captured in the same critical section as the cells it describes. Native
/// adapters must finish capture before calling a shaper or touching the atlas.
pub fn capture(allocator: std.mem.Allocator, active: *surface_mod.Surface, io: std.Io, unfocused: renderer.CursorUnfocused) !Snapshot {
    active.lockCore(io);
    defer active.unlockCore(io);
    return .{
        .draw_list = try renderer.buildDrawListWithUnfocused(allocator, active.renderSnapshot(), unfocused),
        .view_offset = active.core.view_offset,
    };
}

test "frame snapshot owns grapheme data after live core mutation" {
    var active = try surface_mod.Surface.init(std.testing.allocator, 1, .{ .cols = 8, .rows = 2 });
    defer active.deinit();
    try active.core.write("q\u{307}");
    var snapshot = try capture(std.testing.allocator, &active, std.testing.io, .normal);
    defer snapshot.draw_list.deinit(std.testing.allocator);
    try active.core.write("\x1b[2J\x1b[Hchanged");
    try std.testing.expectEqual(@as(u21, 'q'), snapshot.draw_list.cells[0].codepoint);
    try std.testing.expectEqual(@as(u16, 1), snapshot.draw_list.cells[0].grapheme_count);
    try std.testing.expectEqual(@as(u32, 0x307), snapshot.draw_list.grapheme_pool[snapshot.draw_list.cells[0].grapheme_offset]);
}

test "frame snapshot captures scrolled cells and matching offset together" {
    var active = try surface_mod.Surface.init(std.testing.allocator, 1, .{ .cols = 8, .rows = 2 });
    defer active.deinit();
    try active.core.write("one\r\ntwo\r\nthree");
    active.core.scrollViewport(1);
    var snapshot = try capture(std.testing.allocator, &active, std.testing.io, .normal);
    defer snapshot.draw_list.deinit(std.testing.allocator);
    active.core.scrollViewport(-1);
    try std.testing.expectEqual(@as(usize, 1), snapshot.view_offset);
    try std.testing.expectEqual(@as(u21, 'o'), snapshot.draw_list.cells[0].codepoint);
}

test "frame snapshot unfocused cursor is projected without changing live cursor" {
    var active = try surface_mod.Surface.init(std.testing.allocator, 1, .{ .cols = 8, .rows = 2 });
    defer active.deinit();
    var snapshot = try capture(std.testing.allocator, &active, std.testing.io, .hidden);
    defer snapshot.draw_list.deinit(std.testing.allocator);
    try std.testing.expect(snapshot.draw_list.overlays.len > 0);
    try std.testing.expect(!snapshot.draw_list.overlays[0].cursor.visible);
    try std.testing.expect(active.core.snapshot().cursor.visible);
}

fn expectUnlocked(active: *surface_mod.Surface) !void {
    // Test the actual mutex in both Debug and ReleaseFast, without a second
    // blocking acquisition that could hang a missing-unlock mutation forever.
    const unlocked = active.core_mutex.tryLock();
    if (unlocked) {
        active.core.owner_dbg.enter();
        active.unlockCore(std.testing.io);
    }
    try std.testing.expect(unlocked);
}

fn allocationProbe(a: std.mem.Allocator) !void {
    var active = try surface_mod.Surface.init(std.testing.allocator, 1, .{ .cols = 8, .rows = 2 });
    defer active.deinit();
    try active.core.write("q\u{307}");
    var snapshot = capture(a, &active, std.testing.io, .normal) catch |err| {
        try expectUnlocked(&active);
        return err;
    };
    defer snapshot.draw_list.deinit(a);
    try expectUnlocked(&active);
}

test "frame snapshot allocation failures release lock and all owned buffers" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "frame snapshot host metadata stays with copied cells when shaping resizes core" {
    const host = @import("host.zig");
    const window = @import("../session/window.zig");
    var active = try surface_mod.Surface.init(std.testing.allocator, 1, .{ .cols = 8, .rows = 2 });
    defer active.deinit();
    try active.core.write("before");
    var tabs = [_]*surface_mod.Surface{&active};
    var app_window: window.AppWindow = .{ .tabs = &tabs };
    var state = renderer.RendererState.init(std.testing.allocator, .{});
    defer state.deinit();
    var calls: usize = 0;
    const Shaper = struct {
        active: *surface_mod.Surface,
        calls: *usize,
        pub fn shape(self: @This(), cell: renderer.DrawCell) renderer.glyph_layout.ShapeResult {
            if (self.calls.* == 0) {
                std.debug.assert(!self.active.core.owner_dbg.isOwnedBySelf());
                self.active.lockCore(std.testing.io);
                self.active.core.resize(9, 3) catch unreachable;
                self.active.unlockCore(std.testing.io);
            }
            self.calls.* += 1;
            return (renderer.FakeFontBackend{}).shape(cell);
        }
    };
    var frame = try host.buildFrameAfterDrain(std.testing.allocator, &app_window, &state, Shaper{ .active = &active, .calls = &calls }, .{}, std.testing.io);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expect(calls > 0);
    try std.testing.expectEqual(@as(u16, 9), active.core.size.cols);
    try std.testing.expectEqual(@as(u16, 8), frame.size.cols);
    try std.testing.expectEqual(frame.render_frame.draw_list.size, frame.size);
}
