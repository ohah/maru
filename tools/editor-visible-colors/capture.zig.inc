// 제품 프레임을 실제 CoreText·Metal 읽기 경로로 촬영한다. GUI·입력기 동작의 증거는 아니다.
test "visible color GPU capture" {
    const a = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    for (0..1000) |_| try text.appendSlice(a, "pub const value = 42;\n");
    var fx = try PaneFixture.init(a);
    defer fx.deinit(a);
    fx.session.loaded_config.config.lsp.enabled = false;
    fx.session.blink_visible = false;
    const term = try undoFixture(&fx, a, "visible-window.zig", text.items);
    fx.term = term;
    term.rt.editor_wrap = false;
    for (0..10000) |i| {
        var warm = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.NoFrame;
        warm.dl.deinit(a);
        if (!term.rt.editor_syntax.pending and i > 2) break;
    }
    try testing.expect(!term.rt.editor_syntax.pending);
    term.rt.editor_first_line = 31;
    fx.session.gpu_quads.clearRetainingCapacity();
    const leaf = maru.session.SplitRect{ .x = 0, .y = 0, .w = 800, .h = 4800 };
    var drawn = appendPaneFrame(fx.session, leaf, term) orelse return error.NoFrame;
    var owned = true;
    defer if (owned) drawn.dl.deinit(a);
    try testing.expectEqual(@as(usize, 31), term.rt.editor_first_line);
    try testing.expect(term.rt.editor_hit_rows_len > 256);
    const cb = @import("../../coretext_smoke_bridge.zig");
    const builder_mod = @import("../../coretext_frame_builder.zig");
    const capture = @import("../../chrome/lab_smoke_bridge.zig");
    const smoke = @import("../../metal_smoke.zig");
    var state = renderer.RendererState.init(a, .{});
    defer state.deinit();
    const builder = builder_mod.CoreTextFrameBuilder{
        .appearance = try maru.config.resolveAppearance(.{}),
        .shape_draw_list = cb.maru_macos_coretext_shape_draw_list,
        .rasterize_glyph = cb.maru_macos_coretext_smoke_rasterize_glyph,
        .cell_width_px = 8,
        .glyph_cell_width_px = 8,
        .cell_height_px = 16,
    };
    owned = false;
    var frame = try builder.buildFromDrawList(a, drawn.dl, &state);
    defer frame.deinit(a);
    var native = try smoke.buildSmokeFixtureFromRenderFrame(a, frame, state.atlas.config, state.atlas.entryCount(), true, "visible-color-window", "CoreText", "CoreText");
    defer native.deinit(a);
    for (native.cells) |*cell| {
        cell.origin_x = @intCast(drawn.rect.x);
        cell.origin_y = @intCast(drawn.rect.y);
    }
    var result = capture.NativeResult{ .status = -1, .renderer_created = 0, .atlas_ready = 0, .draw_submitted = 0, .ppm_written = 0, .png_written = 0 };
    capture.maru_macos_chrome_lab_smoke_render(800, 4800, "__ARTIFACT_DIR__/frame.ppm", "__ARTIFACT_DIR__/frame.png", 100, 300, 8, 16, native.cells.ptr, native.cells.len, native.atlas_width_px, native.atlas_height_px, native.raster_uploads.ptr, native.raster_uploads.len, native.raster_pixels.ptr, native.raster_pixels.len, fx.session.gpu_quads.items.ptr, fx.session.gpu_quads.items.len, null, 0, null, 0, 0, 0, 0, 0, 0, &result);
    try testing.expectEqual(@as(c_int, 0), result.status);
    inline for (.{ "renderer_created", "atlas_ready", "draw_submitted", "ppm_written", "png_written" }) |field| try testing.expectEqual(@as(u32, 1), @field(result, field));
    std.debug.print("COLOR_GPU first={d} rows={d} queried={d} body_y={d} cell_h={d} status=0 png=1\n", .{ term.rt.editor_first_line, term.rt.editor_hit_rows_len, term.rt.editor_syntax.bufs.line_bounds.items.len, term.rt.editor_hit_geom.body_y, term.rt.editor_hit_geom.cell_h_px });
}
