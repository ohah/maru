// 격리 사본에서 실제 AppSession·CoreText·Metal 경로를 사용한다.
// 캡처 훅이 첫 경로를 유지하므로 각 단계와 뷰는 별도 프로세스에서 실행한다.
test "shared editor GPU capture search word boundary" {
    const capture_phase = std.mem.span(std.c.getenv("MARU_SHARED_IME_CAPTURE_PHASE") orelse return error.MissingCapturePhase);
    const capture_view = std.mem.span(std.c.getenv("MARU_SHARED_IME_CAPTURE_VIEW") orelse return error.MissingCaptureView);
    if (!std.mem.eql(u8, capture_view, "owner") and !std.mem.eql(u8, capture_view, "peer")) return error.InvalidCaptureView;
    const alloc = testing.allocator;
    var fx = try PaneFixture.init(alloc);
    defer fx.deinit(alloc);
    fx.term = try undoFixture(&fx, alloc, "search-word.txt", "prefix\nfoo$bar\nfoo😀bar\nfoo_bar\nfoo bar\nsuffix\n");
    const peer = try openSharedViewInActivePane(fx.session, fx.term);
    try sharedPreeditFixtureFocus(&fx);
    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    peer.rt.editor_selection = editor_selection.Selection.at(24);
    const cb = @import("../../coretext_smoke_bridge.zig");
    const capture = @import("../../chrome/lab_smoke_bridge.zig");
    const smoke = @import("../../metal_smoke.zig");
    const builder_mod = @import("../../coretext_frame_builder.zig");
    if (!std.mem.eql(u8, capture_phase, "before") and !std.mem.eql(u8, capture_phase, "search") and !std.mem.eql(u8, capture_phase, "edited") and !std.mem.eql(u8, capture_phase, "closed")) return error.InvalidCapturePhase;
    if (!std.mem.eql(u8, capture_phase, "before")) {
        find_ops.toggleFind(fx.session);
        fx.session.chrome_host.find.whole_word = true;
        try fx.session.chrome_host.find.input.query.appendSlice(alloc, "foo");
        try fx.session.chrome_host.find.replace.query.appendSlice(alloc, "done");
        find_ops.recomputeFind(fx.session);
        try testing.expect(fx.session.activateSurfaceById(peer.surfaceId()));
        find_ops.toggleFind(fx.session);
        try fx.session.chrome_host.find.input.query.appendSlice(alloc, "foo");
        find_ops.recomputeFind(fx.session);
    }
    if (std.mem.eql(u8, capture_phase, "edited") or std.mem.eql(u8, capture_phase, "closed")) {
        try testing.expect(fx.session.activateSurfaceById(fx.term.surfaceId()));
        find_ops.replaceOne(fx.session);
    }
    if (std.mem.eql(u8, capture_phase, "closed")) {
        try testing.expect(fx.session.activateSurfaceById(fx.term.surfaceId()));
        find_ops.toggleFind(fx.session);
    }
    const revision = fx.term.rt.editorDocument().opened.?.file.revision;
    try testing.expectEqual(@as(u64, if (std.mem.eql(u8, capture_phase, "edited") or std.mem.eql(u8, capture_phase, "closed")) 1 else 0), revision);
    try testing.expectEqualStrings(if (revision == 1) "prefix\ndone$bar\nfoo😀bar\nfoo_bar\nfoo bar\nsuffix\n" else "prefix\nfoo$bar\nfoo😀bar\nfoo_bar\nfoo bar\nsuffix\n", fx.term.rt.editorDocument().opened.?.file.content);
    const phase = capture_phase;
        for ([_]*Term{ fx.term, peer }, 0..) |term, idx| {
            const name = if (idx == 0) "owner" else "peer";
            if (!std.mem.eql(u8, name, capture_view)) continue;
            fx.session.gpu_quads.clearRetainingCapacity();
            const leaf = maru.session.SplitRect{ .x = 0, .y = 0, .w = 800, .h = 300 };
            var drawn = appendPaneFrame(fx.session, leaf, term) orelse return error.MissingFrame;
            var drawn_owned = true;
            defer if (drawn_owned) drawn.dl.deinit(alloc);
            const vf = find_ops.viewFind(fx.session, term);
            const count: usize = if (std.mem.eql(u8, phase, "before") or (std.mem.eql(u8, phase, "closed") and idx == 0)) 0 else (if (idx == 0) (if (revision == 0) @as(usize, 2) else 1) else (if (revision == 0) @as(usize, 4) else 3));
            try testing.expectEqual(count, if (vf) |v| v.matches.len else 0);
            if (vf) |v| {
                try testing.expectEqualStrings(if (idx == 0) "foo" else "foo", v.state.input.query.items);
                if (!std.mem.eql(u8, phase, "closed")) try testing.expect(v.state.open);
                std.debug.print("SEARCH open={any} nav={any} matches={d} line_cache={d} document_lines={d}\n", .{ v.state.open, v.nav, v.matches.len, term.rt.editor_lines.len, term.rt.editorDocument().opened.?.file.lines.lines.len });
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
            // 프레임 빌더가 DrawList를 인수한 뒤에는 프레임이 해제한다.
            drawn_owned = false;
            var frame = try builder.buildFromDrawList(alloc, drawn.dl, &state);
            defer frame.deinit(alloc);
            var native = try smoke.buildSmokeFixtureFromRenderFrame(alloc, frame, state.atlas.config, state.atlas.entryCount(), true, "real-AppSession-shared-find", "CoreText", "CoreText");
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
            // PNG 존재만으로 성공하지 않고 GPU 생성·업로드·제출·읽기를 모두 확인한다.
            try testing.expectEqual(@as(c_int, 0), result.status);
            inline for (.{ "renderer_created", "atlas_ready", "draw_submitted", "ppm_written", "png_written" }) |field|
                try testing.expectEqual(@as(u32, 1), @field(result, field));
        }
        try testing.expectEqual(revision, fx.term.rt.editorDocument().opened.?.file.revision);
}
