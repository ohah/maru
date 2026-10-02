// Appended only to the isolated source snapshot by capture.py.
// Real AppSession shared-view opening and frame assembly; no product-source edits.
test "shared editor GPU capture peer folding and scroll anchors" {
    // The product screenshot hook is process-scoped and retains its first path.
    // capture.py launches this fixture once per phase/view, never twice per process.
    const capture_phase = std.mem.span(std.c.getenv("MARU_SHARED_IME_CAPTURE_PHASE") orelse return error.MissingCapturePhase);
    const capture_view = std.mem.span(std.c.getenv("MARU_SHARED_IME_CAPTURE_VIEW") orelse return error.MissingCaptureView);
    if (!std.mem.eql(u8, capture_view, "owner") and !std.mem.eql(u8, capture_view, "peer")) return error.InvalidCaptureView;
    const alloc = testing.allocator;
    var fx = try PaneFixture.init(alloc);
    defer fx.deinit(alloc);
    try testing.expect(selectAll(fx.session, fx.term));
    try testing.expect(insertText(fx.session, fx.term, "before\nblock\n    hidden one\n    hidden two\nafter\ntail 0\ntail 1\ntail 2\ntail 3\ntail 4\ntail 5\ntail 6\ntail 7\ntail 8\ntail 9\ntail 10\ntail 11\ntail 12\ntail 13\ntail 14\ntail 15\ntail 16\ntail 17\ntail 18\ntail 19\ntail 20\ntail 21\ntail 22\ntail 23\ntail 24\ntail 25\ntail 26\ntail 27\ntail 28\ntail 29\ntail 30\ntail 31\n"));
    dropUndoState(fx.session, fx.term);
    fx.term.rt.editorDocument().opened.?.file.revision = 0;
    fx.term.rt.editorDocument().notifications = .{};
    const peer = try openSharedViewInActivePane(fx.session, fx.term);
    try testing.expect(toggleFoldHead(fx.session, peer, 1));
    peer.rt.editor_selection = editor_selection.Selection.at(50);
    peer.rt.editor_first_line = 0;
    peer.rt.editor_first_col = 0;
    peer.rt.editor_wrap = false;
    fx.term.rt.editor_wrap = false;
    try sharedPreeditFixtureFocus(&fx);
    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    const cb = @import("../../coretext_smoke_bridge.zig");
    const capture = @import("../../chrome/lab_smoke_bridge.zig");
    const smoke = @import("../../metal_smoke.zig");
    const builder_mod = @import("../../coretext_frame_builder.zig");
    if (!std.mem.eql(u8, capture_phase, "before")) {
        try testing.expect(insertText(fx.session, fx.term, "new\n"));
    }
    if (std.mem.eql(u8, capture_phase, "undo") or std.mem.eql(u8, capture_phase, "redo")) {
        try testing.expect(undoEdit(fx.session, fx.term));
    }
    if (std.mem.eql(u8, capture_phase, "redo")) try testing.expect(redoEdit(fx.session, fx.term));
    const shifted = std.mem.eql(u8, capture_phase, "edited") or std.mem.eql(u8, capture_phase, "redo");
    try testing.expectEqualSlices(u32, &.{if (shifted) @as(u32, 2) else @as(u32, 1)}, foldedHeads(peer));
    try testing.expectEqual(@as(usize, if (shifted) 1 else 0), peer.rt.editor_first_line);
    const revision = fx.term.rt.editorDocument().opened.?.file.revision;
    const phase = capture_phase;
        for ([_]*Term{ fx.term, peer }, 0..) |term, idx| {
            const name = if (idx == 0) "owner" else "peer";
            if (!std.mem.eql(u8, name, capture_view)) continue;
            fx.session.gpu_quads.clearRetainingCapacity();
            const leaf = maru.session.SplitRect{ .x = 0, .y = 0, .w = 800, .h = 300 };
            var drawn = appendPaneFrame(fx.session, leaf, term) orelse return error.MissingFrame;
            var drawn_owned = true;
            defer if (drawn_owned) drawn.dl.deinit(alloc);
            if (idx == 1) {
                try testing.expectEqual(@as(usize, if (shifted) 1 else 0), peer.rt.editor_first_line);
                try testing.expectEqualSlices(u32, &.{if (shifted) @as(u32, 2) else @as(u32, 1)}, foldedHeads(peer));
            }
            var state = renderer.RendererState.init(alloc, .{});
            defer state.deinit();
            const builder = builder_mod.CoreTextFrameBuilder{
                .appearance = try maru.config.resolveAppearance(.{}),
                .shape_draw_list = cb.maru_macos_coretext_shape_draw_list,
                .rasterize_glyph = cb.maru_macos_coretext_smoke_rasterize_glyph,
                .cell_width_px = 8,
                .glyph_cell_width_px = 8,
                .cell_height_px = 16,
            };
            // buildFromDrawList consumes the DrawList on both success and failure.
            // Before transfer this fixture owns it; afterward frame.deinit owns cleanup.
            drawn_owned = false;
            var frame = try builder.buildFromDrawList(alloc, drawn.dl, &state);
            defer frame.deinit(alloc);
            var native = try smoke.buildSmokeFixtureFromRenderFrame(alloc, frame, state.atlas.config, state.atlas.entryCount(), true, "real-AppSession-shared-anchors", "CoreText", "CoreText");
            defer native.deinit(alloc);
            for (native.cells) |*cell| {
                cell.origin_x = @intCast(drawn.rect.x);
                cell.origin_y = @intCast(drawn.rect.y);
            }
            const ppm = try std.fmt.allocPrintSentinel(alloc, "__ARTIFACT_DIR__/{s}-{s}.ppm", .{ phase, name }, 0);
            defer alloc.free(ppm);
            const png = try std.fmt.allocPrintSentinel(alloc, "__ARTIFACT_DIR__/{s}-{s}.png", .{ phase, name }, 0);
            defer alloc.free(png);
            var result = capture.NativeResult{ .status = -1, .renderer_created = 0, .atlas_ready = 0, .draw_submitted = 0, .ppm_written = 0, .png_written = 0 };
            capture.maru_macos_chrome_lab_smoke_render(800, 300, ppm, png, 100, 18, 8, 16, native.cells.ptr, native.cells.len, native.atlas_width_px, native.atlas_height_px, native.raster_uploads.ptr, native.raster_uploads.len, native.raster_pixels.ptr, native.raster_pixels.len, fx.session.gpu_quads.items.ptr, fx.session.gpu_quads.items.len, null, 0, null, 0, 0, 0, 0, 0, 0, &result);
            std.debug.print("GPU {s}/{s} pid={d} status={d} draw={d} png={d} revision={d} owner_preedit={s} peer_preedit={d}\n", .{ phase, name, std.c.getpid(), result.status, result.draw_submitted, result.png_written, revision, fx.term.rt.editor_preedit, peer.rt.editor_preedit.len });
            // A PNG alone could be a stale or black conversion artifact. Require every
            // actual Metal creation/upload/draw/readback stage to acknowledge success.
            try testing.expectEqual(@as(c_int, 0), result.status);
            inline for (.{ "renderer_created", "atlas_ready", "draw_submitted", "ppm_written", "png_written" }) |field|
                try testing.expectEqual(@as(u32, 1), @field(result, field));
        }
        try testing.expectEqual(revision, fx.term.rt.editorDocument().opened.?.file.revision);
}
