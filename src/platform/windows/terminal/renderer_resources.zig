//! A fresh CPU font/atlas namespace and GPU atlas prepared as one owner.
//! Publishing it still requires rebuilding every draw list referencing the old atlas.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const Pipeline = maru.d3d11_cells.CellPipeline;
const DevicePtr = @FieldType(Pipeline, "device");
const ContextPtr = @FieldType(Pipeline, "context");

pub const Metrics = struct { advance_width_px: u32, glyph_width_px: u32, height_px: u32 };

pub const RendererResources = struct {
    state: maru.renderer.RendererState,
    pipeline: *Pipeline,

    pub fn init(a: std.mem.Allocator, device: DevicePtr, context: ContextPtr, size_pt: f32, metrics: Metrics, atlas: maru.renderer.glyph_atlas.GlyphAtlasConfig) !RendererResources {
        // Windows supplies explicit native metrics, not the renderer's optional
        // zero/automatic values. Reject before casts or GPU allocation.
        for ([_]u32{ metrics.advance_width_px, metrics.glyph_width_px, metrics.height_px }) |value|
            if (value == 0 or value > std.math.maxInt(u16)) return error.InvalidCellMetrics;
        var state = maru.renderer.RendererState.init(a, .{
            .text = .{
                .font_size_px = maru.renderer.textConfigFromFontSize(size_pt, 1).font_size_px,
                .device_scale = 1,
                .cell_width_px = @intCast(metrics.advance_width_px),
                .glyph_cell_width_px = @intCast(metrics.glyph_width_px),
                .cell_height_px = @intCast(metrics.height_px),
            },
            .atlas = atlas,
        });
        errdefer state.deinit();
        const pipeline = try Pipeline.createEmptyAtlas(a, device, context, state.atlas.config.atlas_width_px, state.atlas.config.atlas_height_px);
        return .{ .state = state, .pipeline = pipeline };
    }

    pub fn deinit(self: *RendererResources) void {
        self.pipeline.destroy();
        self.state.deinit();
        self.* = undefined;
    }
};

const Fixture = struct {
    window: *maru.win32_window.Window,
    present: *maru.d3d11_present.Present,
    fn init() !Fixture {
        const a = std.testing.allocator;
        const window = try maru.win32_window.Window.create(a, std.unicode.utf8ToUtf16LeStringLiteral("maru renderer resource fixture"), 120, 120);
        errdefer window.destroy();
        // Window.create does not show or activate the private fixture.
        return .{ .window = window, .present = try maru.d3d11_present.Present.create(a, window.hwnd, 120, 120) };
    }
    fn deinit(self: *Fixture) void {
        self.present.destroy();
        self.window.destroy();
    }
    fn stage(self: *Fixture, a: std.mem.Allocator, size: f32, metrics: Metrics) !RendererResources {
        return RendererResources.init(a, self.present.device, self.present.context, size, metrics, .{ .atlas_width_px = 64, .atlas_height_px = 32 });
    }
    fn draw(self: *Fixture, resources: *RendererResources) !void {
        const pixel = [_]u8{ 255, 255, 255, 255 };
        try resources.pipeline.uploadAtlasRegion(0, 0, 1, 1, &pixel, 4);
        try self.present.beginFrame(.{ 0, 0, 0, 1 });
        const cells = [_]maru.d3d11_cells.Cell{maru.d3d11_cells.solidCell(1, 1, 8, 8, .{ 1, 1, 1, 1 }, @splat(0))};
        try resources.pipeline.draw(&cells, 120, 120);
    }
};
const test_metrics: Metrics = .{ .advance_width_px = 8, .glyph_width_px = 8, .height_px = 16 };

test "Windows renderer resources stage isolated identities and GPU atlas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var previous = try fixture.stage(std.testing.allocator, 14, test_metrics);
    defer previous.deinit();
    const old_id = try previous.state.font_registry.intern(.{ .postscript_name = "old-face" });
    var staged = try fixture.stage(std.testing.allocator, 22, test_metrics);
    defer staged.deinit();
    try std.testing.expectEqual(@as(u16, 22), staged.state.text_config.font_size_px);
    try std.testing.expectEqual(@as(usize, 0), staged.state.font_registry.count());
    try std.testing.expectEqual(@as(usize, 0), staged.state.atlas.entryCount());
    try std.testing.expect(previous.pipeline.atlas != staged.pipeline.atlas);
    _ = try staged.state.font_registry.intern(.{ .postscript_name = "new-face" });
    try std.testing.expectEqualStrings("old-face", previous.state.font_registry.get(old_id).?.postscript_name);
    try fixture.draw(&previous);
    try fixture.draw(&staged);
}

test "Windows renderer resources failed preparation preserves active generation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var active = try fixture.stage(std.testing.allocator, 14, test_metrics);
    defer active.deinit();
    _ = try active.state.font_registry.intern(.{ .postscript_name = "active-face" });
    const Probe = struct {
        fn run(a: std.mem.Allocator, f: *Fixture, current: *RendererResources) !void {
            const texture = current.pipeline.atlas;
            var staged = f.stage(a, 22, test_metrics) catch |err| {
                try f.draw(current);
                try std.testing.expect(current.pipeline.atlas == texture);
                try std.testing.expectEqual(@as(usize, 1), current.state.font_registry.count());
                return err;
            };
            defer staged.deinit();
            try f.draw(&staged);
            try f.draw(current);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{ &fixture, &active });
    // Exercise a real GPU API rejection too, not just failure of the pipeline's
    // final tracked allocation. The active namespace and GPU remain usable.
    try std.testing.expectError(error.CreateAtlasFailed, RendererResources.init(std.testing.allocator, fixture.present.device, fixture.present.context, 22, test_metrics, .{ .atlas_width_px = 0, .atlas_height_px = 32 }));
    try std.testing.expectEqual(@as(usize, 1), active.state.font_registry.count());
    try fixture.draw(&active);
}

test "Windows renderer resources retirement preserves staged device use" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var previous = try fixture.stage(std.testing.allocator, 14, test_metrics);
    var staged = fixture.stage(std.testing.allocator, 22, test_metrics) catch |err| {
        previous.deinit();
        return err;
    };
    defer staged.deinit();
    _ = try previous.state.font_registry.intern(.{ .postscript_name = "retiring-face" });
    previous.deinit();
    _ = try staged.state.font_registry.intern(.{ .postscript_name = "surviving-face" });
    try fixture.draw(&staged);
}

test "Windows renderer resources GPU dimensions match prepared atlas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var staged = try fixture.stage(std.testing.allocator, 18, test_metrics);
    defer staged.deinit();
    try std.testing.expectEqual(@as(u32, 64), staged.pipeline.atlas_w);
    try std.testing.expectEqual(@as(u32, 32), staged.pipeline.atlas_h);
    const pixel = [_]u8{ 255, 255, 255, 255 };
    try staged.pipeline.uploadAtlasRegion(63, 31, 1, 1, &pixel, 4);
    try std.testing.expectError(error.CreateAtlasFailed, staged.pipeline.uploadAtlasRegion(64, 31, 1, 1, &pixel, 4));
}

test "Windows renderer resources validate geometry and preserve natural glyph width" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const invalid = [_]Metrics{
        .{ .advance_width_px = 0, .glyph_width_px = 8, .height_px = 16 },
        .{ .advance_width_px = 8, .glyph_width_px = 0, .height_px = 16 },
        .{ .advance_width_px = 8, .glyph_width_px = 8, .height_px = 0 },
        .{ .advance_width_px = 65536, .glyph_width_px = 8, .height_px = 16 },
        .{ .advance_width_px = 8, .glyph_width_px = 65536, .height_px = 16 },
        .{ .advance_width_px = 8, .glyph_width_px = 8, .height_px = 65536 },
    };
    for (invalid) |metrics| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.InvalidCellMetrics, fixture.stage(failing.allocator(), 18, metrics));
    }
    var staged = try fixture.stage(std.testing.allocator, 18, .{ .advance_width_px = 6, .glyph_width_px = 9, .height_px = 20 });
    defer staged.deinit();
    try std.testing.expectEqual(@as(u16, 6), staged.state.text_config.cell_width_px);
    try std.testing.expectEqual(@as(u16, 9), staged.state.text_config.glyph_cell_width_px);
    try std.testing.expectEqual(@as(u16, 20), staged.state.text_config.cell_height_px);
}
