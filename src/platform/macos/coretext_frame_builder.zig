const std = @import("std");
const maru = @import("maru");
const app = maru.app;
const config = maru.config;
const renderer = maru.renderer;
const terminal = maru.terminal;
const coretext_probe = @import("coretext_probe.zig");
const coretext_raster = @import("coretext_raster.zig");
const coretext_shaper = @import("coretext_shaper.zig");

pub const CoreTextFrameBuilder = struct {
    appearance: config.ResolvedAppearance,
    shape_draw_list: coretext_shaper.ShapeDrawListFn,
    rasterize_glyph: coretext_raster.RasterizeGlyphFn,

    pub fn build(
        self: CoreTextFrameBuilder,
        allocator: std.mem.Allocator,
        app_window: *app.AppWindow,
        renderer_state: *renderer.RendererState,
        drain_summary: app.RuntimePumpDrainSummary,
    ) !app.AppHostFrame {
        // FrameLoop는 "drain 뒤 active surface를 frame으로 만든다"는 순서만 소유한다.
        // macOS CoreText는 platform font/raster 경계라 app layer에 새면 안 되므로, 이
        // builder가 active TerminalCore snapshot을 DrawList -> CoreText GlyphRunList ->
        // RenderFrame으로 바꾸는 제품 후보 조립 책임을 맡는다.
        const active = app_window.active() orelse return error.NoActiveSurface;
        var draw_list = try renderer.buildDrawList(allocator, active.core.snapshot());
        var draw_list_owned = true;
        errdefer if (draw_list_owned) draw_list.deinit(allocator);

        var font_registry = renderer.FontIdentityRegistry.init(allocator);
        defer font_registry.deinit();

        const shaper = coretext_shaper.CoreTextDrawListShaper{
            .appearance = self.appearance,
            .shape_draw_list = self.shape_draw_list,
        };
        var shaped = try shaper.shape(allocator, draw_list, &font_registry);
        defer shaped.deinit(allocator);

        const rasterizer = coretext_raster.CoreTextGlyphRasterizer{
            .appearance = self.appearance,
            .font_registry = &font_registry,
            .rasterize_glyph = self.rasterize_glyph,
        };
        const render_frame = try renderer_state.buildFrameFromGlyphRunListWithRasterizer(
            allocator,
            draw_list,
            shaped.runs,
            rasterizer,
        );
        draw_list_owned = false;

        return .{
            .surface_id = active.id,
            .size = active.core.size,
            .process_state = active.process_state,
            .drain_summary = drain_summary,
            .render_frame = render_frame,
        };
    }
};

fn emptyNativeDrawGlyphRecord() coretext_shaper.NativeDrawGlyphRecord {
    return .{
        .cell_index = 0,
        .row = 0,
        .col = 0,
        .cell_width = 0,
        .codepoint = 0,
        .combining = 0,
        .glyph_id = 0,
        .drawable = 0,
        .fallback = 0,
        .color_glyph_kind = 0,
        .font_name = [_]u8{0} ** coretext_probe.font_name_capacity,
    };
}

fn writeTestFontName(record: *coretext_shaper.NativeDrawGlyphRecord, name: []const u8) void {
    const len = @min(name.len, record.font_name.len - 1);
    @memcpy(record.font_name[0..len], name[0..len]);
    record.font_name[len] = 0;
}

fn testShapeDrawList(
    _: [*]const u8,
    _: usize,
    _: f64,
    cells_ptr: [*]const coretext_shaper.NativeDrawCell,
    cell_count: usize,
    result: *coretext_shaper.NativeDrawListShapeResult,
    records_ptr: [*]coretext_shaper.NativeDrawGlyphRecord,
    record_capacity: usize,
) callconv(.c) void {
    // 이 fake bridge는 CoreText 자체가 아니라 builder의 연결 계약만 검증한다. 공백과
    // continuation을 glyph로 만들지 않고, CJK는 fallback face로 보내 실제 CoreText
    // shaper/rasterizer가 지켜야 할 FontIdentityRegistry 경로를 unit test에서 고정한다.
    const cells = cells_ptr[0..cell_count];
    var record_count: usize = 0;
    result.* = .{
        .status = 0,
        .primary_font_found = 1,
        .requested_font_matched = 1,
        .shaped_cell_count = 0,
        .glyph_record_count = 0,
        .glyph_record_overflow = 0,
        .missing_glyph_count = 0,
        .fallback_run_count = 0,
    };

    for (cells, 0..) |cell, index| {
        if (cell.codepoint == 0 or cell.codepoint == ' ') continue;
        if (record_count >= record_capacity) {
            result.status = 7;
            result.glyph_record_overflow = 1;
            return;
        }

        const fallback = cell.codepoint > 0x7f;
        var record = emptyNativeDrawGlyphRecord();
        record.cell_index = @intCast(index);
        record.row = cell.row;
        record.col = cell.col;
        record.cell_width = cell.width;
        record.codepoint = cell.codepoint;
        record.combining = cell.combining;
        record.glyph_id = cell.codepoint + 10;
        record.drawable = 1;
        record.fallback = if (fallback) 1 else 0;
        writeTestFontName(
            &record,
            if (fallback) "AppleSDGothicNeo-Regular" else "Menlo-Regular",
        );
        records_ptr[record_count] = record;
        record_count += 1;
        result.shaped_cell_count += 1;
        if (fallback) result.fallback_run_count += 1;
    }

    result.glyph_record_count = @intCast(record_count);
}

fn failingShapeDrawList(
    _: [*]const u8,
    _: usize,
    _: f64,
    _: [*]const coretext_shaper.NativeDrawCell,
    _: usize,
    result: *coretext_shaper.NativeDrawListShapeResult,
    _: [*]coretext_shaper.NativeDrawGlyphRecord,
    _: usize,
) callconv(.c) void {
    result.* = .{
        .status = 7,
        .primary_font_found = 1,
        .requested_font_matched = 1,
        .shaped_cell_count = 0,
        .glyph_record_count = 0,
        .glyph_record_overflow = 1,
        .missing_glyph_count = 0,
        .fallback_run_count = 0,
    };
}

fn testRasterizeGlyph(
    _: [*]const u8,
    _: usize,
    _: f64,
    _: [*]const u8,
    _: usize,
    _: u32,
    _: u32,
    _: usize,
    _: usize,
    _: usize,
    pixels: [*]u8,
    pixel_capacity: usize,
    result: *coretext_raster.NativeGlyphRasterResult,
) callconv(.c) void {
    // 실제 CoreText bitmap 품질은 native smoke가 본다. 여기서는 raster upload가 빈 bytes로
    // 사라지지 않고 RenderFrame 준비 gate까지 닿는지 보려는 목적이라 모든 픽셀을 잉크로
    // 채운다.
    if (pixel_capacity > 0) @memset(pixels[0..pixel_capacity], 0xff);
    result.* = .{
        .status = 0,
        .non_clear_pixels = @intCast(pixel_capacity / 4),
    };
}

test "CoreText frame builder builds AppHostFrame from active surface" {
    // 이 테스트는 실제 Objective-C/CoreText를 호출하지 않는다. 대신 같은 함수 포인터
    // 경계를 fake bridge로 주입해, active surface snapshot이 제품 후보
    // CoreTextDrawListShaper/CoreTextGlyphRasterizer/RendererState를 지나 AppHostFrame으로
    // 소유권을 넘기는지 고정한다.
    const allocator = std.testing.allocator;
    var surfaces = [_]app.Surface{try app.Surface.init(allocator, 7, .{ .cols = 8, .rows = 2 })};
    defer surfaces[0].deinit();
    surfaces[0].process_state = .running;
    try surfaces[0].core.write("A한");

    var app_window: app.AppWindow = .{ .tabs = surfaces[0..] };
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();

    const builder = CoreTextFrameBuilder{
        .appearance = try config.resolveAppearance(.{}),
        .shape_draw_list = testShapeDrawList,
        .rasterize_glyph = testRasterizeGlyph,
    };
    var frame = try builder.build(allocator, &app_window, &renderer_state, .{ .output_events = 1 });
    defer frame.deinit(allocator);

    const stats = renderer.renderFrameStats(frame.render_frame, renderer_state.atlas.entryCount());
    try std.testing.expectEqual(@as(u64, 7), frame.surface_id);
    try std.testing.expectEqual(terminal.Size{ .cols = 8, .rows = 2 }, frame.size);
    try std.testing.expectEqual(app.ProcessState.running, frame.process_state);
    try std.testing.expectEqual(@as(usize, 1), frame.drain_summary.output_events);
    try std.testing.expect(stats.prepared());
    try std.testing.expectEqual(@as(usize, 2), stats.glyph_count);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_count);
    try std.testing.expectEqual(@as(usize, 2), stats.glyph_raster_upload_count);
    try std.testing.expect(stats.glyph_raster_ready);
}

test "CoreText frame builder reports no active surface before shaping" {
    // active surface가 없으면 CoreText bridge를 호출하기 전에 실패해야 한다. 그래야 window/tab
    // lifecycle 버그가 font/raster 실패처럼 보이지 않는다.
    const allocator = std.testing.allocator;
    var surfaces = [_]app.Surface{};
    var app_window: app.AppWindow = .{ .tabs = surfaces[0..] };
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    const builder = CoreTextFrameBuilder{
        .appearance = try config.resolveAppearance(.{}),
        .shape_draw_list = testShapeDrawList,
        .rasterize_glyph = testRasterizeGlyph,
    };

    try std.testing.expectError(
        error.NoActiveSurface,
        builder.build(allocator, &app_window, &renderer_state, .{}),
    );
}

test "CoreText frame builder surfaces native shape failures" {
    // native shaper가 overflow/font failure를 보고하면 frame 준비를 계속하면 안 된다. 이
    // 실패가 renderer prepared=false로 숨어 버리면 root cause가 CoreText shape 단계인지
    // atlas/raster 단계인지 구분할 수 없기 때문이다.
    const allocator = std.testing.allocator;
    var surfaces = [_]app.Surface{try app.Surface.init(allocator, 8, .{ .cols = 4, .rows = 1 })};
    defer surfaces[0].deinit();
    try surfaces[0].core.write("A");

    var app_window: app.AppWindow = .{ .tabs = surfaces[0..] };
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    const builder = CoreTextFrameBuilder{
        .appearance = try config.resolveAppearance(.{}),
        .shape_draw_list = failingShapeDrawList,
        .rasterize_glyph = testRasterizeGlyph,
    };

    try std.testing.expectError(
        error.CoreTextDrawListShapeFailed,
        builder.build(allocator, &app_window, &renderer_state, .{}),
    );
}
