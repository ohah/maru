//! Native font resources prepared together before a renderer generation uses them.
//! Builders borrow heap allocations, never the address of this movable owner.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

pub const TextResources = struct {
    allocator: std.mem.Allocator,
    raster: *maru.dwrite_font.Rasterizer,
    scratch: []u8,

    /// Preparation does not touch the currently displayed font or atlas. A live
    /// replacement must also stage renderer/cache/layout state before publishing
    /// this owner; replacing just a borrowed builder would leave stale glyphs.
    pub fn init(a: std.mem.Allocator, family: []const u8, fallback: []const u8, size_px: f32) !TextResources {
        const raster = try maru.dwrite_font.Rasterizer.create(a, family, fallback, size_px);
        errdefer raster.destroy();
        var chrome_extent: u32 = 1;
        inline for (@import("type_info_fields").enumFields(maru.chrome.ui.typography.ChromeTextRole)) |field| {
            const role: maru.chrome.ui.typography.ChromeTextRole = @fromBackingInt(@intCast(field.value));
            chrome_extent = @max(chrome_extent, maru.chrome.ui.typography.lineHeightPx(role, 1000));
        }
        const scratch = try a.alloc(u8, maru.win32_text.NeutralRasterizer.scratchSizeFor(@max(raster.metrics.width_px * 2, chrome_extent * 2), @max(raster.metrics.height_px, chrome_extent)));
        return .{ .allocator = a, .raster = raster, .scratch = scratch };
    }

    pub fn deinit(self: *TextResources) void {
        self.allocator.free(self.scratch);
        self.raster.destroy();
        self.* = undefined;
    }

    pub fn builder(self: *const TextResources) maru.win32_terminal.FrameBuilder {
        return .{
            .shaper = .{ .raster = self.raster },
            .rasterizer = .{ .raster = self.raster, .scratch = self.scratch },
        };
    }

    pub fn chromeMetrics(self: *const TextResources) maru.dwrite_font.CellMetrics {
        const d = self.raster.design;
        return maru.dwrite_font.cellMetricsFrom(d.upem, d.ascent, d.descent, d.line_gap, d.advance_width, maru.chrome.ui.typography.token(.list_row).point_size).?;
    }
};

fn expectInk(resources: *TextResources, cp: u32, columns: u32) !void {
    const b = resources.builder();
    try std.testing.expect(b.shaper.raster == b.rasterizer.raster);
    try std.testing.expectEqual(resources.scratch.len, b.rasterizer.scratch.len);
    try expectBuilderInk(b, resources.raster.metrics, cp, columns);
}

fn expectBuilderInk(b: maru.win32_terminal.FrameBuilder, metrics: maru.dwrite_font.CellMetrics, cp: u32, columns: u32) !void {
    const width = metrics.width_px * columns;
    const height = metrics.height_px;
    const pixels = try std.testing.allocator.alloc(u8, width * height * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0);
    const ink = try b.rasterizer.raster.rasterize(cp, width, height, width * 4, pixels, b.rasterizer.scratch);
    try std.testing.expect(ink > 0);
}

test "Windows text resources prepared builder renders native glyphs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var resources = try TextResources.init(std.testing.allocator, "", "", 18);
    defer resources.deinit();
    try expectInk(&resources, 'M', 1);
}

test "Windows text resources staging preserves the previous font" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var previous = try TextResources.init(std.testing.allocator, "", "", 14);
    defer previous.deinit();
    const before = previous.raster.metrics;
    {
        var staged = try TextResources.init(std.testing.allocator, "", "", 28);
        defer staged.deinit();
        try std.testing.expect(staged.raster.metrics.height_px > before.height_px);
        try expectInk(&staged, 'M', 1);
        try expectInk(&previous, 'M', 1);
        // UI runs remain 14px even when the terminal grows. A baseline taken
        // from the 28px terminal face would crop this smaller native glyph.
        const ui = staged.chromeMetrics();
        const pixels = try std.testing.allocator.alloc(u8, ui.width_px * ui.height_px * 4);
        defer std.testing.allocator.free(pixels);
        @memset(pixels, 0);
        const choice = staged.raster.glyphFor('M') orelse return error.MissingNativeGlyph;
        const ink = try staged.raster.rasterizeGlyphAtSize(choice, 14, ui.width_px, ui.height_px, ui.width_px * 4, pixels, staged.scratch);
        try std.testing.expect(ink > 0);
        const baseline = maru.dwrite_font.glyphBaselineForSize(staged.raster.design, 14, ui.height_px);
        try std.testing.expectEqual(@as(f32, @floatFromInt(ui.baseline_px)), baseline);
        try std.testing.expectEqual(baseline + 5, maru.dwrite_font.glyphBaselineForSize(staged.raster.design, 14, ui.height_px + 10));
    }
    try std.testing.expectEqual(before, previous.raster.metrics);
    try expectInk(&previous, 'M', 1);
}

test "Windows text resources allocation failures preserve active resources" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var previous = try TextResources.init(std.testing.allocator, "", "", 14);
    defer previous.deinit();
    const Probe = struct {
        fn run(a: std.mem.Allocator, active: *TextResources) !void {
            var staged = TextResources.init(a, "", "", 22) catch |err| {
                try expectInk(active, 'M', 1);
                return err;
            };
            defer staged.deinit();
            try expectInk(active, 'M', 1);
            try expectInk(&staged, 'M', 1);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{&previous});
}

test "Windows text resources scratch accommodates wide native glyphs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var resources = try TextResources.init(std.testing.allocator, "", "", 24);
    defer resources.deinit();
    try expectInk(&resources, '한', 2);
}

test "Windows text resources retiring old owner preserves prepared builder" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var previous = try TextResources.init(std.testing.allocator, "", "", 14);
    var next = TextResources.init(std.testing.allocator, "", "", 22) catch |err| {
        previous.deinit();
        return err;
    };
    defer next.deinit();
    const prepared_builder = next.builder();
    const metrics = next.raster.metrics;
    previous.deinit();
    try expectBuilderInk(prepared_builder, metrics, 'M', 1);
    try expectBuilderInk(prepared_builder, metrics, '한', 2);
}
