const std = @import("std");
const draw_list = @import("draw_list.zig");
const glyph_frame = @import("glyph_frame.zig");
const glyph_quads = @import("glyph_quads.zig");

pub const Backend = enum {
    // 미래 backend는 구현을 시작하기 전까지 public enum에 넣지 않는다.
    // 실제로 제공하지 않는 backend를 config나 테스트가 실수로 계약처럼
    // 의존하지 않게 하기 위해서다.
    metal,
};

pub const RenderFrame = struct {
    backend: Backend,
    draw_list: draw_list.DrawList,
    glyph_frame: glyph_frame.GlyphFrame,
    glyph_quad_frame: glyph_quads.GlyphQuadFrame,

    // RenderFrame은 backend가 그릴 DrawList, atlas slot 준비 결과, shader UV 입력을
    // 함께 소유한다. Metal backend가 각자 GlyphFrame -> GlyphQuadFrame 변환을 다시
    // 호출하면 texture bounds/UV 정책이 smoke마다 갈라지므로 제품 frame 경계에서
    // GlyphQuadFrame까지 준비해 둔다.
    pub fn deinit(self: *RenderFrame, allocator: std.mem.Allocator) void {
        self.glyph_quad_frame.deinit(allocator);
        self.glyph_frame.deinit(allocator);
        self.draw_list.deinit(allocator);
        self.* = undefined;
    }

    // glyph frame이 backend가 소비할 수 있을 만큼 draw list와 내부 count/slice가 서로
    // 맞는지 본다. "draw cell 개수 == glyph 개수"를 뜻하지 않는다. 실제 shaper가 공백이나
    // zero-ink glyph를 atlas upload 대상에서 제외할 수 있기 때문이다. 이 frame 준비 계약을
    // RenderFrame이 직접 소유해, app host와 여러 smoke probe가 같은 일관성 검사를 각자
    // 재구현하다 서로 어긋나지 않게 한다.
    pub fn glyphFrameConsistent(self: RenderFrame) bool {
        const frame = self.glyph_frame;
        const quads = self.glyph_quad_frame;
        return frame.size.cols == self.draw_list.size.cols and
            frame.size.rows == self.draw_list.size.rows and
            frame.stats.glyph_count == frame.glyphs.len and
            frame.stats.upload_count == frame.uploads.len and
            frame.stats.upload_count + frame.stats.reused_count == frame.glyphs.len and
            quads.size.cols == frame.size.cols and
            quads.size.rows == frame.size.rows and
            quads.stats.glyph_count == frame.stats.glyph_count and
            quads.stats.uv_count == quads.glyphs.len and
            quads.overlays.len == frame.overlays.len and
            (quads.stats.glyph_count == 0 or quads.stats.ready());
    }
};

pub fn initialBackendForMacOS() Backend {
    return .metal;
}

test "macOS renderer starts with Metal" {
    try @import("std").testing.expectEqual(Backend.metal, initialBackendForMacOS());
}

test "render frame owns and frees draw and glyph frame data" {
    // RenderFrame이 DrawList와 GlyphFrame의 heap slice를 모두 소유한다는 계약을
    // 고정한다. deinit이 하나라도 빼먹으면 testing.allocator가 누수로 잡아낸다.
    const cells = try std.testing.allocator.alloc(draw_list.DrawCell, 2);
    const overlays = try std.testing.allocator.alloc(draw_list.DrawOverlay, 1);
    const prepared = try std.testing.allocator.alloc(glyph_frame.PreparedGlyph, 0);
    const frame_overlays = try std.testing.allocator.alloc(draw_list.DrawOverlay, 0);
    const uploads = try std.testing.allocator.alloc(glyph_frame.GlyphUpload, 0);
    const quads = try std.testing.allocator.alloc(glyph_quads.GlyphQuad, 0);
    const quad_overlays = try std.testing.allocator.alloc(draw_list.DrawOverlay, 0);
    var frame: RenderFrame = .{
        .backend = initialBackendForMacOS(),
        .draw_list = .{
            .size = .{ .cols = 2, .rows = 1 },
            .cursor = .{},
            .dirty = .{ .start_row = 0, .end_row = 0 },
            .cells = cells,
            .overlays = overlays,
        },
        .glyph_frame = .{
            .size = .{ .cols = 2, .rows = 1 },
            .cursor = .{},
            .dirty = .{ .start_row = 0, .end_row = 0 },
            .glyphs = prepared,
            .overlays = frame_overlays,
            .uploads = uploads,
            .stats = .{},
        },
        .glyph_quad_frame = .{
            .size = .{ .cols = 2, .rows = 1 },
            .cursor = .{},
            .dirty = .{ .start_row = 0, .end_row = 0 },
            .glyphs = quads,
            .overlays = quad_overlays,
            .stats = .{},
        },
    };
    frame.deinit(std.testing.allocator);
}

const TestRenderFrameShape = struct {
    draw_cols: u16 = 2,
    draw_rows: u16 = 1,
    glyph_cols: u16 = 2,
    glyph_rows: u16 = 1,
    glyph_len: usize = 0,
    upload_len: usize = 0,
    glyph_count: usize = 0,
    upload_count: usize = 0,
    reused_count: usize = 0,
    quad_len: usize = 0,
    quad_glyph_count: usize = 0,
    quad_uv_count: usize = 0,
    quad_overlay_len: usize = 0,
};

fn makeTestRenderFrame(
    allocator: std.mem.Allocator,
    shape: TestRenderFrameShape,
) !RenderFrame {
    // glyphFrameConsistent는 slice의 실제 원소 값을 읽지 않고 frame metadata와 len만
    // 검증한다. 그래서 테스트 fixture도 uninitialized slice로 충분하다. 이 helper는
    // "frame 준비 계약"의 성공/실패 모양을 작게 만들기 위한 전용 fixture다.
    const cells = try allocator.alloc(draw_list.DrawCell, 0);
    errdefer allocator.free(cells);
    const draw_overlays = try allocator.alloc(draw_list.DrawOverlay, 0);
    errdefer allocator.free(draw_overlays);
    const prepared = try allocator.alloc(glyph_frame.PreparedGlyph, shape.glyph_len);
    errdefer allocator.free(prepared);
    const frame_overlays = try allocator.alloc(draw_list.DrawOverlay, 0);
    errdefer allocator.free(frame_overlays);
    const uploads = try allocator.alloc(glyph_frame.GlyphUpload, shape.upload_len);
    errdefer allocator.free(uploads);
    const quads = try allocator.alloc(glyph_quads.GlyphQuad, shape.quad_len);
    errdefer allocator.free(quads);
    const quad_overlays = try allocator.alloc(draw_list.DrawOverlay, shape.quad_overlay_len);
    errdefer allocator.free(quad_overlays);

    return .{
        .backend = initialBackendForMacOS(),
        .draw_list = .{
            .size = .{ .cols = shape.draw_cols, .rows = shape.draw_rows },
            .cursor = .{},
            .dirty = null,
            .cells = cells,
            .overlays = draw_overlays,
        },
        .glyph_frame = .{
            .size = .{ .cols = shape.glyph_cols, .rows = shape.glyph_rows },
            .cursor = .{},
            .dirty = null,
            .glyphs = prepared,
            .overlays = frame_overlays,
            .uploads = uploads,
            .stats = .{
                .glyph_count = shape.glyph_count,
                .upload_count = shape.upload_count,
                .reused_count = shape.reused_count,
            },
        },
        .glyph_quad_frame = .{
            .size = .{ .cols = shape.glyph_cols, .rows = shape.glyph_rows },
            .cursor = .{},
            .dirty = null,
            .glyphs = quads,
            .overlays = quad_overlays,
            .stats = .{
                .glyph_count = shape.quad_glyph_count,
                .uv_count = shape.quad_uv_count,
            },
        },
    };
}

test "render frame consistency accepts matching glyph frame metadata" {
    var empty = try makeTestRenderFrame(std.testing.allocator, .{});
    defer empty.deinit(std.testing.allocator);
    try std.testing.expect(empty.glyphFrameConsistent());

    var non_empty = try makeTestRenderFrame(std.testing.allocator, .{
        .glyph_len = 2,
        .upload_len = 1,
        .glyph_count = 2,
        .upload_count = 1,
        .reused_count = 1,
        .quad_len = 2,
        .quad_glyph_count = 2,
        .quad_uv_count = 2,
    });
    defer non_empty.deinit(std.testing.allocator);
    try std.testing.expect(non_empty.glyphFrameConsistent());
}

test "render frame consistency rejects size and count mismatches" {
    // app host와 visible smoke가 이 helper를 공유하므로(모두 writeRenderFrameStats로
    // renderer_frame_prepared를 낸다), false로 닫혀야 하는 모양을 renderer 레이어에서 직접
    // 고정한다. 그렇지 않으면 summary가 준비되지 않은 frame을 renderer_frame_prepared=true로
    // 보고할 수 있다.
    var size_mismatch = try makeTestRenderFrame(std.testing.allocator, .{
        .glyph_cols = 3,
    });
    defer size_mismatch.deinit(std.testing.allocator);
    try std.testing.expect(!size_mismatch.glyphFrameConsistent());

    var glyph_count_mismatch = try makeTestRenderFrame(std.testing.allocator, .{
        .glyph_len = 1,
        .upload_len = 1,
        .glyph_count = 2,
        .upload_count = 1,
        .reused_count = 0,
        .quad_len = 2,
        .quad_glyph_count = 2,
        .quad_uv_count = 2,
    });
    defer glyph_count_mismatch.deinit(std.testing.allocator);
    try std.testing.expect(!glyph_count_mismatch.glyphFrameConsistent());

    var upload_count_mismatch = try makeTestRenderFrame(std.testing.allocator, .{
        .glyph_len = 1,
        .upload_len = 0,
        .glyph_count = 1,
        .upload_count = 1,
        .reused_count = 0,
        .quad_len = 1,
        .quad_glyph_count = 1,
        .quad_uv_count = 1,
    });
    defer upload_count_mismatch.deinit(std.testing.allocator);
    try std.testing.expect(!upload_count_mismatch.glyphFrameConsistent());

    var accounting_mismatch = try makeTestRenderFrame(std.testing.allocator, .{
        .glyph_len = 2,
        .upload_len = 1,
        .glyph_count = 2,
        .upload_count = 1,
        .reused_count = 0,
        .quad_len = 2,
        .quad_glyph_count = 2,
        .quad_uv_count = 2,
    });
    defer accounting_mismatch.deinit(std.testing.allocator);
    try std.testing.expect(!accounting_mismatch.glyphFrameConsistent());
}

test "render frame consistency rejects incomplete glyph quad uv data" {
    // GlyphQuadFrame이 제품 RenderFrame 안으로 들어오면 UV 준비 실패도 frame 준비 실패다.
    // atlas bounds 밖 slot을 개별 skip하더라도 그 누락이 consistent=true로 숨으면 Metal
    // backend가 일부 glyph가 빠진 frame을 정상 입력처럼 그릴 수 있다.
    var missing_uv = try makeTestRenderFrame(std.testing.allocator, .{
        .glyph_len = 2,
        .upload_len = 1,
        .glyph_count = 2,
        .upload_count = 1,
        .reused_count = 1,
        .quad_len = 1,
        .quad_glyph_count = 2,
        .quad_uv_count = 1,
    });
    defer missing_uv.deinit(std.testing.allocator);

    try std.testing.expect(!missing_uv.glyphFrameConsistent());
}
