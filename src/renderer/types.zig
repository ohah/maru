const std = @import("std");
const draw_list = @import("draw_list.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const glyph_frame = @import("glyph_frame.zig");
const glyph_layout = @import("glyph_layout.zig");
const glyph_quads = @import("glyph_quads.zig");
const glyph_raster = @import("glyph_raster.zig");

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
    glyph_raster_frame: glyph_raster.GlyphRasterFrame,

    // RenderFrame은 backend가 그릴 DrawList, atlas slot 준비 결과, shader UV 입력,
    // texture upload bytes를 함께 소유한다. Metal backend가 각자 glyph raster/upload
    // 정책을 다시 추론하면 texture copy 크기와 UV 정책이 smoke마다 갈라지므로 제품
    // frame 경계에서 필요한 입력을 모은다.
    pub fn deinit(self: *RenderFrame, allocator: std.mem.Allocator) void {
        self.glyph_raster_frame.deinit(allocator);
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
        const raster = self.glyph_raster_frame;
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
            (quads.stats.glyph_count == 0 or quads.stats.ready()) and
            glyphRasterFrameConsistent(frame, raster);
    }
};

fn glyphRasterFrameConsistent(
    frame: glyph_frame.GlyphFrame,
    raster: glyph_raster.GlyphRasterFrame,
) bool {
    if (raster.stats.upload_count != frame.stats.upload_count) return false;
    if (raster.stats.rasterized_count != raster.uploads.len) return false;
    if (raster.stats.skipped_count != raster.skips.len) return false;
    if (!raster.stats.ready()) return false;
    if (raster.pixels.len != raster.stats.byte_count) return false;
    if (!rasterSkipReasonCountsConsistent(raster)) return false;

    var expected_offset: usize = 0;
    for (raster.uploads) |upload| {
        if (upload.upload_index >= frame.uploads.len) return false;
        const source = frame.uploads[upload.upload_index];
        if (!rasterUploadMatchesSource(upload, source)) return false;
        if (upload.bytes_offset != expected_offset) return false;
        if (upload.byte_count == 0 or upload.bytes_per_row == 0) return false;
        if (upload.byte_count != source.upload_bytes) return false;
        const end = std.math.add(usize, upload.bytes_offset, upload.byte_count) catch return false;
        if (end > raster.pixels.len) return false;
        expected_offset = end;
    }
    if (expected_offset != raster.pixels.len) return false;

    for (raster.skips) |skip| {
        if (skip.upload_index >= frame.uploads.len) return false;
        const source = frame.uploads[skip.upload_index];
        if (!rasterSkipMatchesSource(skip, source)) return false;
    }

    for (frame.uploads, 0..) |_, upload_index| {
        if (rasterAccountingCountForUpload(raster, upload_index) != 1) return false;
    }

    return true;
}

fn rasterSkipReasonCountsConsistent(raster: glyph_raster.GlyphRasterFrame) bool {
    var out_of_bounds: usize = 0;
    var rasterizer_errors: usize = 0;
    for (raster.skips) |skip| {
        switch (skip.reason) {
            .atlas_slot_outside_texture => out_of_bounds += 1,
            .rasterizer_failed => rasterizer_errors += 1,
        }
    }
    return out_of_bounds == raster.stats.out_of_bounds_skip_count and
        rasterizer_errors == raster.stats.rasterizer_error_skip_count;
}

fn rasterUploadMatchesSource(
    upload: glyph_raster.GlyphRasterUpload,
    source: glyph_frame.GlyphUpload,
) bool {
    return upload.glyph_index == source.glyph_index and
        std.meta.eql(upload.slot, source.slot) and
        std.meta.eql(upload.evicted, source.evicted);
}

fn rasterSkipMatchesSource(
    skip: glyph_raster.GlyphRasterSkip,
    source: glyph_frame.GlyphUpload,
) bool {
    return skip.glyph_index == source.glyph_index and
        std.meta.eql(skip.slot, source.slot) and
        std.meta.eql(skip.evicted, source.evicted);
}

fn rasterAccountingCountForUpload(raster: glyph_raster.GlyphRasterFrame, upload_index: usize) usize {
    var count: usize = 0;
    for (raster.uploads) |upload| {
        if (upload.upload_index == upload_index) count += 1;
    }
    for (raster.skips) |skip| {
        if (skip.upload_index == upload_index) count += 1;
    }
    return count;
}

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
    const raster_uploads = try std.testing.allocator.alloc(glyph_raster.GlyphRasterUpload, 0);
    const raster_skips = try std.testing.allocator.alloc(glyph_raster.GlyphRasterSkip, 0);
    const raster_pixels = try std.testing.allocator.alloc(u8, 0);
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
        .glyph_raster_frame = .{
            .uploads = raster_uploads,
            .skips = raster_skips,
            .pixels = raster_pixels,
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
    raster_upload_len: usize = 0,
    raster_skip_len: usize = 0,
    raster_upload_count: usize = 0,
    rasterized_count: usize = 0,
    raster_skipped_count: usize = 0,
    raster_out_of_bounds_skip_count: usize = 0,
    rasterizer_error_skip_count: usize = 0,
    raster_byte_len: usize = 0,
    raster_byte_count: usize = 0,
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
    const raster_uploads = try allocator.alloc(glyph_raster.GlyphRasterUpload, shape.raster_upload_len);
    errdefer allocator.free(raster_uploads);
    const raster_skips = try allocator.alloc(glyph_raster.GlyphRasterSkip, shape.raster_skip_len);
    errdefer allocator.free(raster_skips);
    const raster_pixels = try allocator.alloc(u8, shape.raster_byte_len);
    errdefer allocator.free(raster_pixels);

    fillPreparedGlyphs(prepared);
    fillGlyphUploads(uploads, prepared);
    fillRasterUploads(raster_uploads, uploads);
    fillRasterSkips(raster_skips, uploads, shape.raster_upload_len);

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
        .glyph_raster_frame = .{
            .uploads = raster_uploads,
            .skips = raster_skips,
            .pixels = raster_pixels,
            .stats = .{
                .upload_count = shape.raster_upload_count,
                .rasterized_count = shape.rasterized_count,
                .skipped_count = shape.raster_skipped_count,
                .out_of_bounds_skip_count = shape.raster_out_of_bounds_skip_count,
                .rasterizer_error_skip_count = shape.rasterizer_error_skip_count,
                .byte_count = shape.raster_byte_count,
            },
        },
    };
}

fn fillPreparedGlyphs(prepared: []glyph_frame.PreparedGlyph) void {
    for (prepared, 0..) |*glyph, index| {
        const bounded_index: u21 = @intCast(@min(index, 25));
        const codepoint: u21 = 'A' + bounded_index;
        const slot = testSlot(index);
        glyph.* = .{
            .run = .{
                .row = 0,
                .col = @intCast(@min(index, std.math.maxInt(u16))),
                .cell_width = 1,
                .codepoint = codepoint,
                .font_id = slot.key.font_id,
                .glyph_id = slot.key.glyph_id,
                .cache_key = slot.key,
            },
            .slot = slot,
        };
    }
}

fn fillGlyphUploads(
    uploads: []glyph_frame.GlyphUpload,
    prepared: []const glyph_frame.PreparedGlyph,
) void {
    for (uploads, 0..) |*upload, index| {
        const glyph_index = if (prepared.len == 0) 0 else @min(index, prepared.len - 1);
        const slot = if (prepared.len == 0) testSlot(index) else prepared[glyph_index].slot;
        upload.* = .{
            .glyph_index = glyph_index,
            .slot = slot,
            .upload_bytes = slot.upload_bytes,
        };
    }
}

fn fillRasterUploads(
    raster_uploads: []glyph_raster.GlyphRasterUpload,
    source_uploads: []const glyph_frame.GlyphUpload,
) void {
    for (raster_uploads, 0..) |*upload, index| {
        const source_index = if (source_uploads.len == 0) 0 else @min(index, source_uploads.len - 1);
        const source = if (source_uploads.len == 0) testGlyphUpload(index) else source_uploads[source_index];
        upload.* = .{
            .upload_index = source_index,
            .glyph_index = source.glyph_index,
            .slot = source.slot,
            .evicted = source.evicted,
            .bytes_offset = index * source.upload_bytes,
            .byte_count = source.upload_bytes,
            .bytes_per_row = source.slot.width_px * 4,
            .non_clear_pixels = 1,
        };
    }
}

fn fillRasterSkips(
    raster_skips: []glyph_raster.GlyphRasterSkip,
    source_uploads: []const glyph_frame.GlyphUpload,
    raster_upload_len: usize,
) void {
    for (raster_skips, 0..) |*skip, index| {
        const source_index = if (source_uploads.len == 0)
            0
        else
            @min(raster_upload_len + index, source_uploads.len - 1);
        const source = if (source_uploads.len == 0) testGlyphUpload(index) else source_uploads[source_index];
        skip.* = .{
            .upload_index = source_index,
            .glyph_index = source.glyph_index,
            .slot = source.slot,
            .evicted = source.evicted,
            .reason = .atlas_slot_outside_texture,
        };
    }
}

fn testGlyphUpload(index: usize) glyph_frame.GlyphUpload {
    const slot = testSlot(index);
    return .{
        .glyph_index = index,
        .slot = slot,
        .upload_bytes = slot.upload_bytes,
    };
}

fn testSlot(index: usize) glyph_atlas.AtlasSlot {
    const bounded_index: glyph_layout.GlyphId = @intCast(@min(index, 25));
    const glyph_id: glyph_layout.GlyphId = 'A' + bounded_index;
    return .{
        .id = @intCast(index + 1),
        .key = .{
            .font_id = 1,
            .glyph_id = glyph_id,
            .font_size_px = 1,
            .device_scale = 1,
        },
        .x_px = @intCast(index),
        .y_px = 0,
        .width_px = 1,
        .height_px = 1,
        .upload_bytes = 4,
        .generation = 0,
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
        .raster_upload_len = 1,
        .raster_upload_count = 1,
        .rasterized_count = 1,
        .raster_byte_len = 4,
        .raster_byte_count = 4,
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
        .raster_upload_len = 1,
        .raster_upload_count = 1,
        .rasterized_count = 1,
        .raster_byte_len = 4,
        .raster_byte_count = 4,
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
        .raster_upload_len = 0,
        .raster_upload_count = 1,
        .rasterized_count = 0,
        .raster_byte_len = 0,
        .raster_byte_count = 0,
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
        .raster_upload_len = 1,
        .raster_upload_count = 1,
        .rasterized_count = 1,
        .raster_byte_len = 4,
        .raster_byte_count = 4,
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
        .raster_upload_len = 1,
        .raster_upload_count = 1,
        .rasterized_count = 1,
        .raster_byte_len = 4,
        .raster_byte_count = 4,
    });
    defer missing_uv.deinit(std.testing.allocator);

    try std.testing.expect(!missing_uv.glyphFrameConsistent());
}

test "render frame consistency rejects incomplete glyph raster upload data" {
    // GlyphRasterFrame이 제품 RenderFrame 안으로 들어오면 upload 후보가 성공 upload 또는
    // 명시적 skip 중 하나로 전부 회계 처리되어야 한다. 그렇지 않으면 Metal backend가
    // texture에 복사할 bytes 없이 정상 frame처럼 진행할 수 있다.
    var missing_raster = try makeTestRenderFrame(std.testing.allocator, .{
        .glyph_len = 2,
        .upload_len = 1,
        .glyph_count = 2,
        .upload_count = 1,
        .reused_count = 1,
        .quad_len = 2,
        .quad_glyph_count = 2,
        .quad_uv_count = 2,
        .raster_upload_len = 1,
        .raster_upload_count = 1,
        .rasterized_count = 0,
        .raster_byte_len = 4,
        .raster_byte_count = 4,
    });
    defer missing_raster.deinit(std.testing.allocator);

    try std.testing.expect(!missing_raster.glyphFrameConsistent());
}

test "render frame consistency rejects missing glyph raster bytes" {
    // Raster metadata만 맞고 실제 pixel buffer가 비어 있으면 backend는 texture에 복사할
    // 원본 bytes 없이 정상 frame처럼 진행할 수 있다. frame consistency는 metadata와
    // byte storage를 함께 확인해야 한다.
    var missing_bytes = try makeTestRenderFrame(std.testing.allocator, .{
        .glyph_len = 2,
        .upload_len = 1,
        .glyph_count = 2,
        .upload_count = 1,
        .reused_count = 1,
        .quad_len = 2,
        .quad_glyph_count = 2,
        .quad_uv_count = 2,
        .raster_upload_len = 1,
        .raster_upload_count = 1,
        .rasterized_count = 1,
        .raster_byte_len = 0,
        .raster_byte_count = 4,
    });
    defer missing_bytes.deinit(std.testing.allocator);

    try std.testing.expect(!missing_bytes.glyphFrameConsistent());
}

test "render frame consistency accepts raster skips as accounted upload candidates" {
    // 경계 밖 atlas slot이나 단일 glyph rasterizer 실패는 RenderFrame 전체를 즉시 에러로
    // 만들지 않고 skip으로 남긴다. 다만 upload 후보 하나가 성공 upload 또는 skip 중 정확히
    // 하나로 회계 처리되어야 backend가 누락을 artifact에서 볼 수 있다.
    var frame = try makeTestRenderFrame(std.testing.allocator, .{
        .glyph_len = 2,
        .upload_len = 2,
        .glyph_count = 2,
        .upload_count = 2,
        .reused_count = 0,
        .quad_len = 2,
        .quad_glyph_count = 2,
        .quad_uv_count = 2,
        .raster_upload_len = 1,
        .raster_skip_len = 1,
        .raster_upload_count = 2,
        .rasterized_count = 1,
        .raster_skipped_count = 1,
        .raster_out_of_bounds_skip_count = 1,
        .raster_byte_len = 4,
        .raster_byte_count = 4,
    });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expect(frame.glyphFrameConsistent());
}

test "render frame consistency rejects raster upload identity mismatches" {
    // Raster upload은 byte buffer 위치만 맞으면 되는 값이 아니다. 어떤 GlyphUpload에서 온
    // 것인지 틀리면 backend가 다른 slot에 bitmap을 올릴 수 있으므로, upload_index와
    // glyph_index/slot identity를 함께 검증한다.
    var frame = try makeTestRenderFrame(std.testing.allocator, .{
        .glyph_len = 2,
        .upload_len = 1,
        .glyph_count = 2,
        .upload_count = 1,
        .reused_count = 1,
        .quad_len = 2,
        .quad_glyph_count = 2,
        .quad_uv_count = 2,
        .raster_upload_len = 1,
        .raster_upload_count = 1,
        .rasterized_count = 1,
        .raster_byte_len = 4,
        .raster_byte_count = 4,
    });
    defer frame.deinit(std.testing.allocator);

    frame.glyph_raster_frame.uploads[0].glyph_index = 1;
    try std.testing.expect(!frame.glyphFrameConsistent());
}

test "render frame consistency rejects raster byte range gaps and overflow" {
    // Metal/WebGPU backend는 `bytes_offset..bytes_offset+byte_count`를 slice로 삼아
    // texture에 복사하게 된다. offset이 buffer 밖을 가리키거나 중간에 빈 공간이 생기면
    // native layer에서 OOB copy나 잘못된 glyph upload로 터지므로 domain layer에서 막는다.
    var frame = try makeTestRenderFrame(std.testing.allocator, .{
        .glyph_len = 2,
        .upload_len = 1,
        .glyph_count = 2,
        .upload_count = 1,
        .reused_count = 1,
        .quad_len = 2,
        .quad_glyph_count = 2,
        .quad_uv_count = 2,
        .raster_upload_len = 1,
        .raster_upload_count = 1,
        .rasterized_count = 1,
        .raster_byte_len = 4,
        .raster_byte_count = 4,
    });
    defer frame.deinit(std.testing.allocator);

    frame.glyph_raster_frame.uploads[0].bytes_offset = 1;
    try std.testing.expect(!frame.glyphFrameConsistent());
}

test "render frame consistency rejects an in-bounds glyph that failed to rasterize" {
    // out-of-bounds skip은 quad 단계가 glyph_uv_ready=false로 이미 신호한다. 하지만 in-bounds
    // glyph가 rasterizer 실패로 skip되면 quad에는 UV가 남아 backend가 atlas bitmap이 없는 빈
    // 영역을 샘플링할 수 있다. 그래서 rasterizer 실패가 있는 frame은 prepared로 보지 않는다.
    var frame = try makeTestRenderFrame(std.testing.allocator, .{
        .glyph_len = 2,
        .upload_len = 2,
        .glyph_count = 2,
        .upload_count = 2,
        .reused_count = 0,
        .quad_len = 2,
        .quad_glyph_count = 2,
        .quad_uv_count = 2,
        .raster_upload_len = 1,
        .raster_skip_len = 1,
        .raster_upload_count = 2,
        .rasterized_count = 1,
        .raster_skipped_count = 1,
        .raster_out_of_bounds_skip_count = 1,
        .raster_byte_len = 4,
        .raster_byte_count = 4,
    });
    defer frame.deinit(std.testing.allocator);

    // out-of-bounds였던 skip을 rasterizer 실패로 바꾼다(이유 카운트와 skip.reason을 함께 맞춰
    // accounting/skip-reason 검증은 통과시키고 ready()만 떨어지게 한다).
    frame.glyph_raster_frame.stats.out_of_bounds_skip_count = 0;
    frame.glyph_raster_frame.stats.rasterizer_error_skip_count = 1;
    frame.glyph_raster_frame.skips[0].reason = .rasterizer_failed;

    try std.testing.expect(!frame.glyphFrameConsistent());
}
