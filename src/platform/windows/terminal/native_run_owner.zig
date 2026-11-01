//! Heap-stable native shaper generation; builders never borrow a movable owner.
const std = @import("std");
const maru = @import("maru");
const producer = @import("run_frame.zig");
pub const Owner = struct {
    allocator: std.mem.Allocator,
    shaper: *maru.dwrite_shape.Shaper,
    fallback: []u8,
    ligatures: bool,

    pub fn create(a: std.mem.Allocator, fallback: []const u8, ligatures: bool) !*Owner {
        const owner = try a.create(Owner);
        errdefer a.destroy(owner);
        const shaper = try maru.dwrite_shape.Shaper.create(a);
        errdefer shaper.destroy();
        const owned_fallback = try a.dupe(u8, fallback);
        owner.* = .{ .allocator = a, .shaper = shaper, .fallback = owned_fallback, .ligatures = ligatures };
        return owner;
    }
    pub fn destroy(self: *Owner) void {
        const a = self.allocator;
        self.shaper.destroy();
        a.free(self.fallback);
        a.destroy(self);
    }
    pub fn builder(self: *Owner) maru.win32_terminal.NativeDrawListBuilder {
        return .{ .context = self, .build_fn = build };
    }
    fn build(context: *anyopaque, a: std.mem.Allocator, list: maru.renderer.DrawList, state: *maru.renderer.RendererState, shaper: maru.win32_text.Shaper, rasterizer: maru.win32_text.NeutralRasterizer) !maru.renderer.RenderFrame {
        const self: *Owner = @ptrCast(@alignCast(context));
        return producer.build(a, list, state, shaper, rasterizer, self.shaper, self.fallback, self.ligatures);
    }
};
