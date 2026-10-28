//! Actual DirectWrite shaping-to-atlas smoke; production partitioning is separate.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const producer = @import("run_frame.zig");
const Resources = @import("text_resources.zig").TextResources;

const Case = enum { valid, mixed, synth, gap, empty };
fn render(a: std.mem.Allocator, ligatures: bool) !u64 {
    return renderCase(a, ligatures, .valid);
}
fn renderCase(a: std.mem.Allocator, ligatures: bool, case: Case) !u64 {
    const native_allocator = std.testing.allocator;
    var resources = try Resources.initConfigured(native_allocator, .{ .family = "Fira Code", .fallback = "Jetendard", .size = 22, .ligatures = ligatures });
    defer resources.deinit();
    var native = try maru.dwrite_shape.Shaper.create(native_allocator);
    defer native.destroy();
    var state = maru.renderer.RendererState.init(native_allocator, .{ .text = .{
        .font_size_px = 22,
        .device_scale = 1,
        .cell_width_px = @intCast(resources.raster.metrics.width_px),
        .glyph_cell_width_px = @intCast(resources.raster.metrics.width_px),
        .cell_height_px = @intCast(resources.raster.metrics.height_px),
    } });
    defer state.deinit();
    var reference: [32]maru.dwrite_shape.GlyphRecord = undefined;
    const expected = try native.shapeWithOptions(.{ .text = "=>", .family = resources.raster.family, .fallback_csv = "Jetendard", .size_px = 22 }, &reference, .{ .ligatures = ligatures, .face_style = .regular });
    try std.testing.expect(!expected.overflow and expected.count > 0);
    const cells = try a.dupe(maru.renderer.DrawCell, if (case == .empty) &.{} else &.{
        .{ .row = 0, .col = 0, .codepoint = '=' },
        .{ .row = 0, .col = 1, .codepoint = '>' },
    });
    switch (case) {
        .valid, .empty => {},
        .mixed => cells[1].style.bold = true,
        .synth => cells[1].codepoint = 0x2500,
        .gap => cells[1].col = 2,
    }
    const list: maru.renderer.DrawList = .{
        .size = .{ .cols = 2, .rows = 1 },
        .cursor = .{ .visible = false },
        .dirty = null,
        .cells = cells,
        .overlays = &.{},
    };
    const builder = resources.builder();
    var frame = if (case == .valid) try builder.buildDrawList(a, list, &state) else try producer.buildRun(a, list, &state, builder.shaper, builder.rasterizer, native, "Jetendard", ligatures);
    defer frame.deinit(a);
    if (case == .empty) {
        try std.testing.expectEqual(@as(usize, 0), frame.glyph_frame.glyphs.len);
        try std.testing.expectEqual(@as(usize, 0), frame.glyph_raster_frame.uploads.len);
        return 0;
    }
    try std.testing.expect(frame.glyph_raster_frame.uploads.len > 0);
    try std.testing.expectEqual(@as(usize, 0), frame.glyph_raster_frame.skips.len);
    var ink: usize = 0;
    for (frame.glyph_raster_frame.pixels) |v| ink += @intFromBool(v != 0);
    try std.testing.expect(ink > 0);
    var shifted = false;
    for (frame.glyph_frame.glyphs) |g| {
        var found = false;
        for (reference[0..expected.count]) |ref| found = found or g.run.cache_key.glyph_id == ref.glyph_id;
        try std.testing.expect(found);
        if (g.run.cache_key.raster_origin) |origin| shifted = shifted or origin.x() != 0;
        try std.testing.expect(g.run.placement != null);
        try std.testing.expect(g.run.cache_key.raster_origin != null);
    }
    if (ligatures) try std.testing.expect(shifted);
    return std.hash.Wyhash.hash(0, frame.glyph_raster_frame.pixels);
}

test "Windows run frame ligature toggle changes actual native atlas ink" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(try render(std.testing.allocator, true) != try render(std.testing.allocator, false));
}

fn allocationProbe(a: std.mem.Allocator) !void {
    _ = try render(a, true);
}

test "Windows run frame allocation failures release consumed draw list and native output" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var path: AllocationPath = .{ .backing = std.testing.allocator, .allow_remap = false };
    try std.testing.checkAllAllocationFailures(path.allocator(), allocationProbe, .{});
}

test "Windows run frame raster origin rejects nonfinite cache identity and canonicalizes zero" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Origin = maru.renderer.glyph_layout.GlyphRasterOrigin;
    const positive = try Origin.fromPixels(0, 0);
    const negative = try Origin.fromPixels(-@as(f32, 0), -@as(f32, 0));
    try std.testing.expectEqual(positive, negative);
    try std.testing.expectError(error.InvalidRasterOrigin, Origin.fromPixels(std.math.nan(f32), 0));
    try std.testing.expectError(error.InvalidRasterOrigin, Origin.fromPixels(0, std.math.inf(f32)));
    const fractional = try Origin.fromPixels(-1.25, 3.5);
    try std.testing.expectEqual(@as(f32, -1.25), fractional.x());
    try std.testing.expectEqual(@as(f32, 3.5), fractional.y());
}

test "Windows run frame rejects unpartitioned input and consumes failed draw lists" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectError(error.MixedShapingRun, renderCase(std.testing.allocator, true, .mixed));
    try std.testing.expectError(error.SynthesizedRunRequiresPartition, renderCase(std.testing.allocator, true, .synth));
    try std.testing.expectError(error.DiscontinuousCells, renderCase(std.testing.allocator, true, .gap));
}

fn wholeFrame(a: std.mem.Allocator) !void {
    var resources = try Resources.initConfigured(std.testing.allocator, .{ .family = "Fira Code", .fallback = "Jetendard", .size = 22 });
    defer resources.deinit();
    return wholeFrameWithResources(a, &resources);
}
const Witness = struct { glyphs: usize, uploads: usize, pixels: usize, hash: u64 };
fn wholeFrameWithResources(a: std.mem.Allocator, resources: *Resources) !void {
    return wholeFrameWitness(a, resources, null);
}
fn wholeFrameWitness(a: std.mem.Allocator, resources: *Resources, witness: ?*Witness) !void {
    const control = std.testing.allocator;
    var state = maru.renderer.RendererState.init(control, .{ .text = .{
        .font_size_px = 22,
        .device_scale = 1,
        .cell_width_px = @intCast(resources.raster.metrics.width_px),
        .glyph_cell_width_px = @intCast(resources.raster.metrics.width_px),
        .cell_height_px = @intCast(resources.raster.metrics.height_px),
    } });
    defer state.deinit();
    const cells = try a.dupe(maru.renderer.DrawCell, &.{
        .{ .row = 0, .col = 0, .codepoint = '=' },
        .{ .row = 0, .col = 1, .codepoint = '>' },
        .{ .row = 0, .col = 4, .codepoint = 'M', .style = .{ .bold = true } },
        .{ .row = 1, .col = 0, .codepoint = 'N', .style = .{ .italic = true } },
        .{ .row = 1, .col = 2, .codepoint = 0x2500 },
        .{ .row = 1, .col = 3, .codepoint = 0xac00, .width = 2 },
        .{ .row = 1, .col = 6, .codepoint = 0x10ffff },
    });
    const builder = resources.builder();
    var frame = try builder.buildDrawList(a, .{ .size = .{ .cols = 8, .rows = 2 }, .cursor = .{ .col = 1 }, .dirty = null, .cells = cells, .overlays = &.{} }, &state);
    defer frame.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), frame.glyph_raster_frame.skips.len);
    var synth = false;
    var bold = false;
    var italic = false;
    var wide = false;
    for (frame.glyph_frame.glyphs) |g| {
        const run = g.run;
        synth = synth or (run.codepoint == 0x2500 and run.font_id == 0 and run.glyph_id == 0);
        bold = bold or (run.row == 0 and run.col == 4 and run.style.bold);
        italic = italic or (run.row == 1 and run.col == 0 and run.style.italic);
        wide = wide or (run.row == 1 and run.col == 3 and run.cell_width == 2 and run.fallback);
    }
    try std.testing.expect(synth and bold and italic and wide);
    try std.testing.expect(frame.glyph_frame.stats.replacement_count > 0);
    var missing = false;
    for (frame.glyph_frame.glyphs) |g| {
        if (g.run.codepoint == 0x10ffff) {
            try std.testing.expectEqual(@as(u32, 0), g.run.glyph_id);
            try std.testing.expect(g.run.replacement);
            missing = true;
        }
    }
    try std.testing.expect(missing);
    try std.testing.expect(frame.glyph_raster_frame.stats.non_clear_pixels > 0);
    if (witness) |out| out.* = .{ .glyphs = frame.glyph_frame.glyphs.len, .uploads = frame.glyph_raster_frame.uploads.len, .pixels = frame.glyph_raster_frame.pixels.len, .hash = std.hash.Wyhash.hash(0, frame.glyph_raster_frame.pixels) };
}

test "Windows run frame whole screen preserves rows gaps faces cursor synth and wide fallback" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try wholeFrame(std.testing.allocator);
}

test "Windows run frame later run allocation failures do not publish partial frames" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var resources = try Resources.initConfigured(std.testing.allocator, .{ .family = "Fira Code", .fallback = "Jetendard", .size = 22 });
    defer resources.deinit();
    // Fault indices count allocations, not successful in-place remaps. Force
    // allocate/copy/free so every growth failure is actually injected.
    var path: AllocationPath = .{ .backing = std.testing.allocator, .allow_remap = false };
    try std.testing.checkAllAllocationFailures(path.allocator(), wholeFrameWithResources, .{&resources});
}

test "Windows run frame partition boundaries use shared row adjacency face and cursor policy" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Cell = maru.renderer.DrawCell;
    var cells = [_]Cell{
        .{ .row = 0, .col = 0, .codepoint = '=' },
        .{ .row = 0, .col = 1, .codepoint = '>' },
        .{ .row = 0, .col = 2, .codepoint = 'M' },
    };
    const hidden: maru.terminal.Cursor = .{ .visible = false };
    try std.testing.expectEqual(@as(usize, 3), producer.runEnd(&cells, hidden, 0));
    try std.testing.expectEqual(@as(usize, 1), producer.runEnd(&cells, .{ .col = 1 }, 0));
    cells[1].style.bold = true;
    try std.testing.expectEqual(@as(usize, 1), producer.runEnd(&cells, hidden, 0));
    cells[1].style = .{};
    cells[1].row = 1;
    try std.testing.expectEqual(@as(usize, 1), producer.runEnd(&cells, hidden, 0));
    cells[1].row = 0;
    cells[1].col = 3;
    try std.testing.expectEqual(@as(usize, 1), producer.runEnd(&cells, hidden, 0));
    cells[1].col = 1;
    cells[0].width = 0;
    try std.testing.expectEqual(@as(usize, 3), producer.runEnd(&cells, hidden, 0));
    cells[0].width = 2;
    try std.testing.expectEqual(@as(usize, 1), producer.runEnd(&cells, hidden, 0));
    cells[1].col = 2;
    cells[2].col = 3;
    try std.testing.expectEqual(@as(usize, 3), producer.runEnd(&cells, hidden, 0));
    cells[1].codepoint = 0x2500;
    try std.testing.expectEqual(@as(usize, 1), producer.runEnd(&cells, hidden, 0));
    try std.testing.expectEqual(@as(usize, 2), producer.runEnd(&cells, hidden, 1));
}

test "Windows run frame empty strict input preserves an empty owned frame" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u64, 0), try renderCase(std.testing.allocator, true, .empty));
}

fn ownerAllocationProbe(a: std.mem.Allocator) !void {
    const Owner = @import("native_run_owner.zig").Owner;
    const owner = try Owner.create(a, "Jetendard", false);
    defer owner.destroy();
    try std.testing.expectEqualStrings("Jetendard", owner.fallback);
    try std.testing.expect(!owner.ligatures);
}

test "Windows run frame native generation allocation prefixes release shaper and context" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ownerAllocationProbe, .{});
}

test "Windows run frame native generation owns fallback and remains stable when resources move" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fallback = "Jetendard".*;
    const Owner = @import("native_run_owner.zig").Owner;
    const owner = try Owner.create(std.testing.allocator, &fallback, true);
    defer owner.destroy();
    @memset(&fallback, 'x');
    try std.testing.expectEqualStrings("Jetendard", owner.fallback);
    var resources = try Resources.initConfigured(std.testing.allocator, .{ .family = "Fira Code", .fallback = "Jetendard", .size = 22, .ligatures = false });
    const before = resources.builder().native.?;
    var moved = resources;
    resources = undefined;
    defer moved.deinit();
    const after = moved.builder().native.?;
    try std.testing.expect(before.context == after.context);
    try std.testing.expect(!moved.native.?.ligatures);
}

// Trace the backing allocator separately from failure injection. A successful
// remap can replace a fresh allocation and change the numbered failure paths.
const AllocationPath = struct {
    backing: std.mem.Allocator,
    allow_remap: bool,
    remap_attempts: usize = 0,
    remap_successes: usize = 0,
    fn allocator(self: *AllocationPath) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn allocate(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *AllocationPath = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *AllocationPath = @ptrCast(@alignCast(ctx));
        self.remap_attempts += 1;
        if (!self.allow_remap) return false;
        const ok = self.backing.rawResize(memory, alignment, len, ra);
        self.remap_successes += @intFromBool(ok);
        return ok;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *AllocationPath = @ptrCast(@alignCast(ctx));
        self.remap_attempts += 1;
        if (!self.allow_remap) return null;
        const result = self.backing.rawRemap(memory, alignment, len, ra);
        self.remap_successes += @intFromBool(result != null);
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *AllocationPath = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
    }
};

test "Windows run frame allocation path compares native output with remap on and off" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var resources = try Resources.initConfigured(std.testing.allocator, .{ .family = "Fira Code", .fallback = "Jetendard", .size = 22 });
    defer resources.deinit();
    var first: ?Witness = null;
    for ([_]bool{ true, false }) |allow| {
        var minimum: usize = std.math.maxInt(usize);
        var maximum: usize = 0;
        var remaps: usize = 0;
        for (0..16) |_| {
            var path: AllocationPath = .{ .backing = std.testing.allocator, .allow_remap = allow };
            var failing = std.testing.FailingAllocator.init(path.allocator(), .{});
            var witness: Witness = undefined;
            try wholeFrameWitness(failing.allocator(), &resources, &witness);
            if (first) |before| try std.testing.expectEqual(before, witness) else first = witness;
            minimum = @min(minimum, failing.alloc_index);
            maximum = @max(maximum, failing.alloc_index);
            remaps += path.remap_successes;
        }
        std.debug.print("allocation path remap={} alloc_min={d} alloc_max={d} remap_successes={d} native_hash={x}\n", .{ allow, minimum, maximum, remaps, first.?.hash });
        if (!allow) {
            try std.testing.expectEqual(minimum, maximum);
            try std.testing.expectEqual(@as(usize, 0), remaps);
        }
    }
}
