const std = @import("std");
const terminal = @import("../terminal.zig");
const glyph_layout = @import("glyph_layout.zig");
const state = @import("state.zig");
const types = @import("types.zig");

// glyph text smoke와 metal smoke는 똑같이 "제품 RenderFrame을 준비하고 그 통계를
// renderer_* 키로 artifact summary에 남기는" 일을 한다. 이 추출/직렬화를 각 smoke가 따로
// 구현하면 GlyphFrameStats가 바뀔 때마다 여러 곳을 손으로 맞춰야 하고 키 schema도 서로
// 어긋난다(한 smoke만 fallback_count를 빼먹는 식). 그래서 renderer가 단일 출처로 소유한다.
pub const RenderFrameStats = struct {
    consistent: bool,
    backend: types.Backend,
    surface_cols: u16,
    surface_rows: u16,
    draw_cells: usize,
    draw_overlays: usize,
    glyph_count: usize,
    glyph_quad_count: usize,
    glyph_uv_count: usize,
    glyph_uv_ready: bool,
    upload_count: usize,
    reused_count: usize,
    fallback_count: usize,
    replacement_count: usize,
    atlas_entries: usize,

    // visible smoke들의 공통 "frame이 backend가 그릴 만큼 준비됐다" gate. 내부 일관성
    // (glyphFrameConsistent)에 더해 실제로 glyph가 잡혔고 atlas가 채워졌는지(>0)까지 봐서,
    // 빈-but-consistent frame을 prepared로 보고하지 않게 한다.
    pub fn prepared(self: RenderFrameStats) bool {
        return self.consistent and self.glyph_count > 0 and self.glyph_uv_ready and self.atlas_entries > 0;
    }
};

// 준비된 RenderFrame과 그 frame을 만든 atlas의 entry 수에서 통계를 뽑는다. atlas는 frame
// 사이에 살아남는 RendererState 소유라 frame 자체에는 entry 수가 없어 따로 받는다.
pub fn renderFrameStats(frame: types.RenderFrame, atlas_entries: usize) RenderFrameStats {
    const glyph_frame = frame.glyph_frame;
    return .{
        .consistent = frame.glyphFrameConsistent(),
        .backend = frame.backend,
        .surface_cols = glyph_frame.size.cols,
        .surface_rows = glyph_frame.size.rows,
        .draw_cells = frame.draw_list.cells.len,
        .draw_overlays = frame.draw_list.overlays.len,
        .glyph_count = glyph_frame.stats.glyph_count,
        .glyph_quad_count = frame.glyph_quad_frame.stats.glyph_count,
        .glyph_uv_count = frame.glyph_quad_frame.stats.uv_count,
        .glyph_uv_ready = frame.glyph_quad_frame.stats.ready(),
        .upload_count = glyph_frame.stats.upload_count,
        .reused_count = glyph_frame.stats.reused_count,
        .fallback_count = glyph_frame.stats.fallback_count,
        .replacement_count = glyph_frame.stats.replacement_count,
        .atlas_entries = atlas_entries,
    };
}

// `<prefix>frame_prepared=...` 같은 한 묶음의 summary 줄을 쓴다. prefix로 같은 schema를
// 여러 smoke가 공유하게 한다(glyph text/metal smoke 모두 "renderer_"를 쓴다). 키 이름은
// 기존 smoke artifact 계약과 동일하게 유지한다.
pub fn writeRenderFrameStats(writer: anytype, prefix: []const u8, stats: RenderFrameStats) !void {
    try writer.print("{s}frame_prepared={}\n", .{ prefix, stats.prepared() });
    try writer.print("{s}backend={s}\n", .{ prefix, @tagName(stats.backend) });
    try writer.print("{s}surface_cols={d}\n", .{ prefix, stats.surface_cols });
    try writer.print("{s}surface_rows={d}\n", .{ prefix, stats.surface_rows });
    try writer.print("{s}draw_cells={d}\n", .{ prefix, stats.draw_cells });
    try writer.print("{s}draw_overlays={d}\n", .{ prefix, stats.draw_overlays });
    try writer.print("{s}glyph_count={d}\n", .{ prefix, stats.glyph_count });
    try writer.print("{s}glyph_quad_count={d}\n", .{ prefix, stats.glyph_quad_count });
    try writer.print("{s}glyph_uv_count={d}\n", .{ prefix, stats.glyph_uv_count });
    try writer.print("{s}glyph_uv_ready={}\n", .{ prefix, stats.glyph_uv_ready });
    try writer.print("{s}glyph_upload_count={d}\n", .{ prefix, stats.upload_count });
    try writer.print("{s}glyph_reused_count={d}\n", .{ prefix, stats.reused_count });
    try writer.print("{s}glyph_fallback_count={d}\n", .{ prefix, stats.fallback_count });
    try writer.print("{s}glyph_replacement_count={d}\n", .{ prefix, stats.replacement_count });
    try writer.print("{s}atlas_entries={d}\n", .{ prefix, stats.atlas_entries });
}

test "render frame stats extracts frame metadata and derives prepared" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    core.clearDirty();
    try core.write("AA");

    var renderer_state = state.RendererState.init(std.testing.allocator, .{});
    defer renderer_state.deinit();

    var frame = try renderer_state.buildFrame(std.testing.allocator, core.snapshot(), glyph_layout.FakeFontBackend{});
    defer frame.deinit(std.testing.allocator);

    const stats = renderFrameStats(frame, renderer_state.atlas.entryCount());

    try std.testing.expect(stats.consistent);
    try std.testing.expectEqual(types.Backend.metal, stats.backend);
    try std.testing.expectEqual(@as(u16, 4), stats.surface_cols);
    try std.testing.expectEqual(@as(u16, 1), stats.surface_rows);
    try std.testing.expectEqual(@as(usize, 4), stats.draw_cells);
    try std.testing.expectEqual(@as(usize, 4), stats.glyph_count);
    try std.testing.expectEqual(@as(usize, 4), stats.glyph_quad_count);
    try std.testing.expectEqual(@as(usize, 4), stats.glyph_uv_count);
    try std.testing.expect(stats.glyph_uv_ready);
    try std.testing.expectEqual(stats.glyph_count, stats.upload_count + stats.reused_count);
    try std.testing.expect(stats.atlas_entries > 0);
    // glyph가 잡혔고 atlas가 채워졌으므로 prepared는 참이다.
    try std.testing.expect(stats.prepared());
}

test "render frame stats prepared is false for an empty-but-consistent frame" {
    // 내부 일관성만으로 prepared를 보고하면 빈 frame도 통과한다. glyph/atlas가 0이면
    // 준비된 것이 아니라는 계약을 고정한다.
    const empty: RenderFrameStats = .{
        .consistent = true,
        .backend = .metal,
        .surface_cols = 2,
        .surface_rows = 1,
        .draw_cells = 0,
        .draw_overlays = 0,
        .glyph_count = 0,
        .glyph_quad_count = 0,
        .glyph_uv_count = 0,
        .glyph_uv_ready = false,
        .upload_count = 0,
        .reused_count = 0,
        .fallback_count = 0,
        .replacement_count = 0,
        .atlas_entries = 0,
    };
    try std.testing.expect(!empty.prepared());
}

test "write render frame stats emits prefixed canonical lines" {
    const stats: RenderFrameStats = .{
        .consistent = true,
        .backend = .metal,
        .surface_cols = 16,
        .surface_rows = 2,
        .draw_cells = 32,
        .draw_overlays = 1,
        .glyph_count = 32,
        .glyph_quad_count = 32,
        .glyph_uv_count = 32,
        .glyph_uv_ready = true,
        .upload_count = 5,
        .reused_count = 27,
        .fallback_count = 2,
        .replacement_count = 0,
        .atlas_entries = 5,
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer output.deinit();
    try writeRenderFrameStats(&output.writer, "renderer_", stats);
    const text = try output.toOwnedSlice();
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_frame_prepared=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_backend=metal\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_surface_cols=16\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_surface_rows=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_draw_cells=32\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_draw_overlays=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_glyph_count=32\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_glyph_quad_count=32\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_glyph_uv_count=32\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_glyph_uv_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_glyph_upload_count=5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_glyph_reused_count=27\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_glyph_fallback_count=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_glyph_replacement_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renderer_atlas_entries=5\n") != null);

    // 다른 prefix로도 같은 schema를 낼 수 있어야 host/다른 smoke가 재사용할 수 있다.
    var other: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer other.deinit();
    try writeRenderFrameStats(&other.writer, "glyph_", stats);
    const other_text = try other.toOwnedSlice();
    defer std.testing.allocator.free(other_text);
    try std.testing.expect(std.mem.indexOf(u8, other_text, "glyph_frame_prepared=true\n") != null);
}
