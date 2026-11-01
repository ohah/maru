//! Native packet consumption judges; fixtures never activate a user window.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const mf = maru.renderer.metal_frame;

fn nativeFill(color: u32) mf.NativeMetalCell {
    return .{ .row = 0, .col = 0, .width = 1, .codepoint = ' ', .slot_id = 0, .atlas_x_px = 0, .atlas_y_px = 0, .atlas_width_px = 0, .atlas_height_px = 0, .u0 = -1, .v0 = -1, .u1 = -1, .v1 = -1, .background = color };
}

fn ink(color: u32) mf.GpuGlyph {
    return .{ .x = -2, .y = 2, .w = 8, .h = 6, .atlas_x_px = 0, .atlas_y_px = 0, .atlas_width_px = 8, .atlas_height_px = 6, .u0 = 0.9, .v0 = 0.9, .u1 = 1, .v1 = 1, .foreground = color, .layer = 0 };
}

const Fixture = struct {
    base: [1]mf.NativeMetalCell = .{nativeFill(0xff0000ff)},
    ink: [1]mf.GpuGlyph = .{ink(0xff0000)},
    overlays: [1]mf.NativeMetalCell = .{nativeFill(0xff00ff00)},
    cursor_ink: [1]mf.GpuGlyph = .{ink(0)},

    fn frame(self: *Fixture) mf.PositionedTerminalFrame {
        return .{ .base = &self.base, .ink = &self.ink, .overlays = &self.overlays, .cursor_ink = &self.cursor_ink };
    }
};

test "Windows positioned terminal appends layers in paint order with transparent clipped ink" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture: Fixture = .{};
    var cells: std.ArrayList(maru.d3d11_cells.Cell) = .empty;
    defer cells.deinit(std.testing.allocator);
    try maru.win32_terminal.appendPositionedFrame(std.testing.allocator, &cells, fixture.frame(), 10, 20, 32, 32, .{ 0, 0, 10, 20 });
    try std.testing.expectEqual(@as(usize, 4), cells.items.len);
    try std.testing.expectEqual([4]f32{ 0, 0, 1, 1 }, cells.items[0].bg);
    try std.testing.expect(cells.items[0].uv[0] < 0);
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, cells.items[1].fg);
    try std.testing.expectEqual(@as(f32, 0), cells.items[1].bg[3]);
    try std.testing.expectEqual([4]f32{ 0, 2, 6, 6 }, cells.items[1].rect);
    try std.testing.expectEqual(@as(f32, 2.0 / 32.0), cells.items[1].uv[0]);
    try std.testing.expectEqual([4]f32{ 0, 1, 0, 1 }, cells.items[2].bg);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, cells.items[3].fg);
    try std.testing.expectEqual(@as(f32, 0), cells.items[3].bg[3]);
}

const AllocationWitness = struct { partial_failures: usize = 0 };

fn allocationProbe(a: std.mem.Allocator, witness: *AllocationWitness) !void {
    // Force growth through alloc, otherwise successful in-place remaps bypass
    // checkAllAllocationFailures' allocation counter and never test rollback.
    var no_resize = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    const controlled = no_resize.allocator();
    var fixture: Fixture = .{};
    var many: [24]mf.GpuGlyph = @splat(ink(0xff0000));
    var frame = fixture.frame();
    frame.ink = &many;
    var cells: std.ArrayList(maru.d3d11_cells.Cell) = .empty;
    defer cells.deinit(controlled);
    try cells.ensureTotalCapacityPrecise(controlled, 1);
    const prefix = maru.d3d11_cells.solidCell(99, 99, 1, 1, .{ 1, 1, 1, 1 }, @splat(0));
    cells.appendAssumeCapacity(prefix);
    maru.win32_terminal.appendPositionedFrame(controlled, &cells, frame, 10, 20, 32, 32, .{ 0, 0, 10, 20 }) catch |err| {
        if (no_resize.allocations > 1) witness.partial_failures += 1;
        try std.testing.expectEqual(@as(usize, 1), cells.items.len);
        try std.testing.expectEqualDeep(prefix, cells.items[0]);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 28), cells.items.len);
    try std.testing.expectEqualDeep(prefix, cells.items[0]);
}

test "Windows positioned terminal allocation failures roll back every partially appended layer" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var witness: AllocationWitness = .{};
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{&witness});
    try std.testing.expect(witness.partial_failures > 0);
}

test "Windows positioned terminal rejects invalid metrics before changing caller cells" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture: Fixture = .{};
    var cells: std.ArrayList(maru.d3d11_cells.Cell) = .empty;
    defer cells.deinit(std.testing.allocator);
    for (0..4) |index| {
        var metrics = [_]u32{ 10, 20, 32, 32 };
        metrics[index] = 0;
        try std.testing.expectError(error.InvalidFrameMetrics, maru.win32_terminal.appendPositionedFrame(std.testing.allocator, &cells, fixture.frame(), metrics[0], metrics[1], metrics[2], metrics[3], .{ 0, 0, 10, 20 }));
        try std.testing.expectEqual(@as(usize, 0), cells.items.len);
    }
}

test "Windows positioned terminal drops outside ink and empty viewport without touching earlier content" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture: Fixture = .{};
    fixture.ink[0].x = -1000;
    fixture.cursor_ink[0].x = 1000;
    var cells: std.ArrayList(maru.d3d11_cells.Cell) = .empty;
    defer cells.deinit(std.testing.allocator);
    try maru.win32_terminal.appendPositionedFrame(std.testing.allocator, &cells, fixture.frame(), 10, 20, 32, 32, .{ 0, 0, 10, 20 });
    try std.testing.expectEqual(@as(usize, 2), cells.items.len);
    const before = cells.items.len;
    try maru.win32_terminal.appendPositionedFrame(std.testing.allocator, &cells, fixture.frame(), 10, 20, 32, 32, .{ 0, 0, 0, 20 });
    try std.testing.expectEqual(before, cells.items.len);
}

test "Windows positioned terminal resamples final atlas coordinates and keeps solid fills out of the atlas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture: Fixture = .{};
    var cells: std.ArrayList(maru.d3d11_cells.Cell) = .empty;
    defer cells.deinit(std.testing.allocator);
    try maru.win32_terminal.appendPositionedFrame(std.testing.allocator, &cells, fixture.frame(), 10, 20, 64, 64, .{ 0, 0, 10, 20 });
    try std.testing.expectEqual(@as(f32, 2.0 / 64.0), cells.items[1].uv[0]);
    try std.testing.expectEqual(@as(f32, 8.0 / 64.0), cells.items[1].uv[2]);
    try std.testing.expectEqual([4]f32{ -1, -1, -1, -1 }, cells.items[0].uv);
    try std.testing.expectEqual([4]f32{ -1, -1, -1, -1 }, cells.items[2].uv);
}

fn releaseCom(pointer: *anyopaque) void {
    const Header = extern struct { vtable: [*]const *const anyopaque };
    const header: *Header = @ptrCast(@alignCast(pointer));
    const release: *const fn (*anyopaque) callconv(maru.win32_abi.winapi) u32 = @ptrCast(@alignCast(header.vtable[2]));
    _ = release(pointer);
}

fn pixel(mapped: anytype, x: usize, y: usize) [4]u8 {
    const bytes: [*]const u8 = @ptrCast(mapped.data.?);
    return bytes[y * mapped.row_pitch + x * 4 ..][0..4].*;
}

test "Windows positioned terminal actual GPU preserves earlier ink outside a later glyph mask" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const window = try maru.win32_window.Window.create(a, std.unicode.utf8ToUtf16LeStringLiteral("maru positioned packet GPU fixture"), 64, 64);
    defer window.destroy();
    const present = try maru.d3d11_present.Present.create(a, window.hwnd, 64, 64);
    defer present.destroy();
    var pixels: [16 * 8 * 4]u8 = @splat(0);
    for (0..6) |y| for (0..16) |x| {
        const offset = (y * 16 + x) * 4;
        @memset(pixels[offset..][0..3], 255);
        pixels[offset + 3] = if (x < 4 or x >= 12) 255 else 0;
    };
    const pipeline = try maru.d3d11_cells.CellPipeline.create(a, present.device, present.context, 16, 8, &pixels);
    defer pipeline.destroy();
    var fixture: Fixture = .{};
    var glyphs = [_]mf.GpuGlyph{ fixture.ink[0], fixture.ink[0] };
    for (&glyphs) |*glyph| glyph.x = 0;
    glyphs[1].atlas_x_px = 8;
    glyphs[1].foreground = 0x00ff00;
    var frame = fixture.frame();
    frame.ink = &glyphs;
    frame.overlays = &.{};
    frame.cursor_ink = &.{};
    var cells: std.ArrayList(maru.d3d11_cells.Cell) = .empty;
    defer cells.deinit(a);
    try maru.win32_terminal.appendPositionedFrame(a, &cells, frame, 10, 20, 16, 8, .{ 0, 0, 64, 64 });
    try present.beginFrame(.{ 1, 1, 1, 1 });
    try pipeline.draw(cells.items, 64, 64);

    // Exercise every pixel-shader branch over an unchanged blue base, then
    // an ordinary draw. GPU readback detects missing PS constants, inherited
    // opacity and accidental RGB scaling without relying on desktop focus.
    const blue = maru.d3d11_cells.solidCell(30, 0, 34, 30, .{ 0, 0, 1, 1 }, @splat(0));
    try pipeline.draw(&.{blue}, 64, 64);
    const red = maru.d3d11_cells.solidCell(32, 0, 6, 6, .{ 1, 0, 0, 1 }, @splat(0));
    try pipeline.drawOpacity(&.{red}, 64, 64, 500);
    var glyph = red;
    glyph.rect[0] = 42;
    glyph.uv = .{ 0, 0, 4.0 / 16.0, 6.0 / 8.0 };
    glyph.fg = .{ 1, 0, 0, 1 };
    glyph.bg = @splat(0);
    try pipeline.drawOpacity(&.{glyph}, 64, 64, 500);
    glyph.rect[0] = 52;
    glyph.bg = .{ 0, 0, 1, 1 };
    try pipeline.drawOpacity(&.{glyph}, 64, 64, 500);
    var zero = red;
    zero.rect[1] = 10;
    try pipeline.drawOpacity(&.{zero}, 64, 64, 0);
    var clamped = red;
    clamped.rect = .{ 42, 10, 6, 6 };
    try pipeline.drawOpacity(&.{clamped}, 64, 64, 2000);
    const green = maru.d3d11_cells.solidCell(32, 20, 6, 6, .{ 0, 1, 0, 1 }, @splat(0));
    try pipeline.draw(&.{green}, 64, 64);

    // Read the owned backbuffer through a staging texture, independent of
    // desktop occlusion, screenshots and foreground input. The IID is the same
    // ID3D11Texture2D contract owned by platform/windows/d3d11.zig.
    var back: ?*anyopaque = null;
    defer if (back) |owned| releaseCom(owned);
    try std.testing.expect(present.swapchain.vtable.GetBuffer(present.swapchain, 0, &.{ .data1 = 0x6f15aaf2, .data2 = 0xd208, .data3 = 0x4e89, .data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } }, &back) >= 0);
    try std.testing.expect(back != null);
    var staging: ?@TypeOf(pipeline.atlas) = null;
    defer if (staging) |owned| releaseCom(@ptrCast(owned));
    try std.testing.expect(present.device.vtable.CreateTexture2D(present.device, &.{ .width = 64, .height = 64, .mip_levels = 1, .array_size = 1, .format = 87, .sample_desc = .{ .count = 1, .quality = 0 }, .usage = 3, .bind_flags = 0, .cpu_access_flags = 0x20000, .misc_flags = 0 }, null, &staging) >= 0);
    try std.testing.expect(staging != null);
    const Context = @typeInfo(@TypeOf(present.context)).pointer.child;
    const copy: *const fn (@TypeOf(present.context), *anyopaque, *anyopaque) callconv(maru.win32_abi.winapi) void = @ptrCast(@alignCast(present.context.vtable.CopyResource));
    copy(present.context, @ptrCast(staging.?), back.?);
    const MapFn = @typeInfo(@FieldType(Context.VTable, "Map")).pointer.child;
    const Mapped = @typeInfo(@typeInfo(MapFn).@"fn".param_types[5].?).pointer.child;
    var mapped: Mapped = undefined;
    try std.testing.expect(present.context.vtable.Map(present.context, @ptrCast(staging.?), 0, 1, 0, &mapped) >= 0);
    defer present.context.vtable.Unmap(present.context, @ptrCast(staging.?), 0);
    try std.testing.expect(mapped.data != null and mapped.row_pitch >= 64 * 4);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(mapped, 1, 3));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, pixel(mapped, 6, 3));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(mapped, 9, 10));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(mapped, 20, 20));
    for ([_]usize{ 33, 43, 53 }) |x| {
        const half = pixel(mapped, x, 2);
        try std.testing.expect(half[0] >= 127 and half[0] <= 128);
        try std.testing.expectEqual(@as(u8, 0), half[1]);
        try std.testing.expect(half[2] >= 127 and half[2] <= 128);
        try std.testing.expectEqual(@as(u8, 255), half[3]);
    }
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(mapped, 33, 12));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(mapped, 43, 12));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, pixel(mapped, 33, 22));
    var bitmap: [54 + 64 * 64 * 4]u8 = @splat(0);
    @memcpy(bitmap[0..2], "BM");
    std.mem.writeInt(u32, bitmap[2..6], bitmap.len, .little);
    std.mem.writeInt(u32, bitmap[10..14], 54, .little);
    std.mem.writeInt(u32, bitmap[14..18], 40, .little);
    std.mem.writeInt(i32, bitmap[18..22], 64, .little);
    std.mem.writeInt(i32, bitmap[22..26], -64, .little);
    std.mem.writeInt(u16, bitmap[26..28], 1, .little);
    std.mem.writeInt(u16, bitmap[28..30], 32, .little);
    const bytes: [*]const u8 = @ptrCast(mapped.data.?);
    for (0..64) |row| @memcpy(bitmap[54 + row * 256 ..][0..256], bytes[row * mapped.row_pitch ..][0..256]);
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/positioned-terminal-gpu-{s}.bmp", .{@tagName(builtin.mode)});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &bitmap });
    std.debug.print(" positioned_gpu_bgra=red,green,blue,white capture={s} ", .{path});
}

test "Windows positioned terminal cursor suffix excludes decorations and accounts for clipping" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture: Fixture = .{};
    var overlays = [_]mf.NativeMetalCell{ nativeFill(0xff00ffff), nativeFill(0xff00ff00) };
    var frame = fixture.frame();
    frame.overlays = &overlays;
    frame.cursor_cells = 1;
    var cells: std.ArrayList(maru.d3d11_cells.Cell) = .empty;
    defer cells.deinit(std.testing.allocator);
    const suffix = try maru.win32_terminal.appendPositionedFrameSplit(std.testing.allocator, &cells, frame, 10, 20, 32, 32, .{ 0, 0, 10, 20 });
    try std.testing.expectEqual(@as(usize, 5), cells.items.len);
    try std.testing.expectEqual(@as(usize, 2), suffix);
    try std.testing.expectEqual([4]f32{ 0, 1, 1, 1 }, cells.items[cells.items.len - suffix - 1].bg);
    cells.clearRetainingCapacity();
    overlays[1].col = 10;
    const clipped = try maru.win32_terminal.appendPositionedFrameSplit(std.testing.allocator, &cells, frame, 10, 20, 32, 32, .{ 0, 0, 10, 20 });
    try std.testing.expectEqual(@as(usize, 1), clipped);
    const before = cells.items.len;
    frame.cursor_cells = 3;
    try std.testing.expectError(error.InvalidCursorSuffix, maru.win32_terminal.appendPositionedFrameSplit(std.testing.allocator, &cells, frame, 10, 20, 32, 32, .{ 0, 0, 10, 20 }));
    try std.testing.expectEqual(before, cells.items.len);
}
