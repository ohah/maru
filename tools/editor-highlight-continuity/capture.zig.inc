// 외부 사본에만 연결한다. 실제 Metal 경로의 대기 프레임이며 OS 키보드 검증은 아니다.
fn highlightCapture(fx: *PaneFixture, name: []const u8) !void {
    const a = testing.allocator;
    fx.session.gpu_quads.clearRetainingCapacity();
    const leaf = maru.session.SplitRect{ .x = 0, .y = 0, .w = 800, .h = 480 };
    const drawn = appendPaneFrame(fx.session, leaf, fx.term) orelse return error.NoFrame;
    const ppm = try std.fmt.allocPrintSentinel(a, "__ARTIFACT_DIR__/{s}.ppm", .{name}, 0);
    defer a.free(ppm);
    const png = try std.fmt.allocPrintSentinel(a, "__ARTIFACT_DIR__/{s}.png", .{name}, 0);
    defer a.free(png);
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
    var frame = try builder.buildFromDrawList(a, drawn.dl, &state);
    defer frame.deinit(a);
    var native = try smoke.buildSmokeFixtureFromRenderFrame(a, frame, state.atlas.config, state.atlas.entryCount(), true, "visible-color-window", "CoreText", "CoreText");
    defer native.deinit(a);
    for (native.cells) |*cell| {
        cell.origin_x = @intCast(drawn.rect.x);
        cell.origin_y = @intCast(drawn.rect.y);
    }
    var result = capture.NativeResult{ .status = -1, .renderer_created = 0, .atlas_ready = 0, .draw_submitted = 0, .ppm_written = 0, .png_written = 0 };
    capture.maru_macos_chrome_lab_smoke_render(800, 480, ppm.ptr, png.ptr, 100, 300, 8, 16, native.cells.ptr, native.cells.len, native.atlas_width_px, native.atlas_height_px, native.raster_uploads.ptr, native.raster_uploads.len, native.raster_pixels.ptr, native.raster_pixels.len, fx.session.gpu_quads.items.ptr, fx.session.gpu_quads.items.len, null, 0, null, 0, 0, 0, 0, 0, 0, &result);
    try testing.expectEqual(@as(c_int, 0), result.status);
    inline for (.{ "renderer_created", "atlas_ready", "draw_submitted", "ppm_written", "png_written" }) |field| try testing.expectEqual(@as(u32, 1), @field(result, field));
}

test "highlight continuity GPU capture" {
    const a = testing.allocator;
    var fx = try PaneFixture.initWithSyntax(a, true);
    defer fx.deinit(a);
    fx.session.loaded_config.config.lsp.enabled = false;
    fx.session.blink_visible = false;
    fx.term.rt.editor_wrap = false;
    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, fx.term, "pub fn example() void {\n    const value = 42;\n    // 한글 주석\n    _ = value;\n}\n"));
    const wake = @import("parse/dispatch.zig").wake;
    const deadline = std.Io.Clock.awake.now(testing.io).nanoseconds + 10_000_000_000;
    while (fx.term.rt.editor_syntax.pending) {
        try testing.expect(std.Io.Clock.awake.now(testing.io).nanoseconds < deadline);
        _ = wake.deliverForTest();
        std.Thread.yield() catch {};
    }
    // 첫 프레임의 헤더 배치와 caret 위치를 고정한 뒤 비교한다.
    fx.term.rt.editor_selection = editor_selection.Selection.at(8);
    for (0..2) |_| {
        var warm = appendPaneFrame(fx.session, .{ .x = 0, .y = 0, .w = 800, .h = 480 }, fx.term) orelse return error.NoFrame;
        warm.dl.deinit(a);
    }
    try highlightCapture(&fx, "ready");
    try testing.expect(insertText(fx.session, fx.term, "x"));
    try testing.expect(fx.term.rt.editor_syntax.pending);
    try testing.expect(fx.term.rt.editor_syntax.provider == null);
    try highlightCapture(&fx, "pending");
    try testing.expect(fx.term.rt.editor_syntax.pending);
    while (fx.term.rt.editor_syntax.pending) {
        try testing.expect(std.Io.Clock.awake.now(testing.io).nanoseconds < deadline);
        _ = wake.deliverForTest();
        std.Thread.yield() catch {};
    }
    try highlightCapture(&fx, "completed");
    std.debug.print("HIGHLIGHT_GPU ready pending completed captured\n", .{});
}
