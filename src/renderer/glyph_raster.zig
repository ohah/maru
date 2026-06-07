const std = @import("std");
const draw_list = @import("draw_list.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const glyph_frame = @import("glyph_frame.zig");
const glyph_layout = @import("glyph_layout.zig");
const terminal = @import("../terminal.zig");

const bytes_per_pixel: usize = 4;

pub const GlyphRasterError = error{
    InvalidGlyphIndex,
    InvalidGlyphBitmapSize,
    RasterByteCountOverflow,
    RasterByteCountMismatch,
    RasterCountOverflow,
    UploadSlotMismatch,
    RasterNonClearPixelCountInvalid,
};

pub const GlyphRasterRequest = struct {
    run: glyph_layout.GlyphRun,
    slot: glyph_atlas.AtlasSlot,
    pixels: []u8,
    bytes_per_row: usize,
};

pub const GlyphRasterResult = struct {
    non_clear_pixels: usize,
};

pub const GlyphRasterUpload = struct {
    glyph_index: usize,
    slot: glyph_atlas.AtlasSlot,
    bytes_offset: usize,
    byte_count: usize,
    bytes_per_row: usize,
    non_clear_pixels: usize,
};

pub const GlyphRasterFrameStats = struct {
    upload_count: usize = 0,
    rasterized_count: usize = 0,
    byte_count: usize = 0,
    non_clear_pixels: usize = 0,
    zero_ink_uploads: usize = 0,

    pub fn ready(self: GlyphRasterFrameStats) bool {
        return self.upload_count == self.rasterized_count;
    }
};

pub const GlyphRasterFrame = struct {
    uploads: []GlyphRasterUpload,
    pixels: []u8,
    stats: GlyphRasterFrameStats,

    pub fn deinit(self: *GlyphRasterFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.uploads);
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

const GlyphBitmapShape = struct {
    width_px: usize,
    height_px: usize,
    bytes_per_row: usize,
    byte_count: usize,
    pixel_count: usize,
};

pub const FakeGlyphRasterizer = struct {
    pub fn rasterize(_: FakeGlyphRasterizer, request: GlyphRasterRequest) GlyphRasterError!GlyphRasterResult {
        // 이 fake rasterizer는 글꼴 품질을 흉내 내려는 코드가 아니다. CoreText 없이도
        // "upload slot에 실제 byte buffer가 채워지는가"를 기본 CI에서 검증하기 위한
        // 결정적 테스트 backend다. space는 zero-ink glyph로 두어 실제 renderer에서
        // 공백 glyph가 upload 후보가 될 수 있음을 관측하게 한다.
        const shape = try bitmapShapeForSlot(request.slot);
        if (request.pixels.len != shape.byte_count or request.bytes_per_row != shape.bytes_per_row) {
            return error.RasterByteCountMismatch;
        }

        @memset(request.pixels, 0);
        if (request.run.codepoint == ' ') return .{ .non_clear_pixels = 0 };

        const red: u8 = @truncate(request.run.glyph_id);
        const green: u8 = @truncate(request.run.glyph_id >> 8);
        const blue: u8 = if (request.run.fallback) 0x80 else 0xff;

        var non_clear: usize = 0;
        for (0..shape.height_px) |y| {
            for (0..shape.width_px) |x| {
                const offset = y * shape.bytes_per_row + x * bytes_per_pixel;
                request.pixels[offset + 0] = red;
                request.pixels[offset + 1] = green;
                request.pixels[offset + 2] = blue;
                request.pixels[offset + 3] = 0xff;
                non_clear += 1;
            }
        }

        return .{ .non_clear_pixels = non_clear };
    }
};

pub fn buildGlyphRasterFrame(
    allocator: std.mem.Allocator,
    frame: glyph_frame.GlyphFrame,
    rasterizer: anytype,
) !GlyphRasterFrame {
    // GlyphFrame.uploads는 "어떤 slot을 업로드해야 하는가"까지만 말한다. GlyphRasterFrame은
    // 그 다음 단계로, 실제 backend가 atlas texture에 복사할 contiguous RGBA byte buffer를
    // 만든다. 이 경계를 renderer domain에 두면 Metal bridge가 upload byte 수와 slot 크기를
    // 다시 추론하지 않아도 된다.
    var total_bytes: usize = 0;
    for (frame.uploads) |upload| {
        if (upload.glyph_index >= frame.glyphs.len) return error.InvalidGlyphIndex;
        if (!std.meta.eql(frame.glyphs[upload.glyph_index].slot, upload.slot)) {
            return error.UploadSlotMismatch;
        }
        const shape = try bitmapShapeForSlot(upload.slot);
        if (upload.upload_bytes != shape.byte_count) return error.RasterByteCountMismatch;
        total_bytes = std.math.add(usize, total_bytes, shape.byte_count) catch
            return error.RasterByteCountOverflow;
    }

    const uploads = try allocator.alloc(GlyphRasterUpload, frame.uploads.len);
    errdefer allocator.free(uploads);
    const pixels = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(pixels);

    var offset: usize = 0;
    var stats: GlyphRasterFrameStats = .{
        .upload_count = frame.uploads.len,
        .byte_count = total_bytes,
    };

    for (frame.uploads, 0..) |upload, index| {
        const prepared = frame.glyphs[upload.glyph_index];
        const shape = try bitmapShapeForSlot(upload.slot);
        const end = std.math.add(usize, offset, shape.byte_count) catch
            return error.RasterByteCountOverflow;
        const pixel_slice = pixels[offset..end];
        @memset(pixel_slice, 0);

        const result = try rasterizer.rasterize(.{
            .run = prepared.run,
            .slot = upload.slot,
            .pixels = pixel_slice,
            .bytes_per_row = shape.bytes_per_row,
        });
        if (result.non_clear_pixels > shape.pixel_count) {
            return error.RasterNonClearPixelCountInvalid;
        }

        uploads[index] = .{
            .glyph_index = upload.glyph_index,
            .slot = upload.slot,
            .bytes_offset = offset,
            .byte_count = shape.byte_count,
            .bytes_per_row = shape.bytes_per_row,
            .non_clear_pixels = result.non_clear_pixels,
        };
        stats.rasterized_count = std.math.add(usize, stats.rasterized_count, 1) catch
            return error.RasterCountOverflow;
        stats.non_clear_pixels = std.math.add(usize, stats.non_clear_pixels, result.non_clear_pixels) catch
            return error.RasterCountOverflow;
        if (result.non_clear_pixels == 0) {
            stats.zero_ink_uploads = std.math.add(usize, stats.zero_ink_uploads, 1) catch
                return error.RasterCountOverflow;
        }

        offset = end;
    }

    return .{
        .uploads = uploads,
        .pixels = pixels,
        .stats = stats,
    };
}

fn bitmapShapeForSlot(slot: glyph_atlas.AtlasSlot) GlyphRasterError!GlyphBitmapShape {
    if (slot.width_px == 0 or slot.height_px == 0) return error.InvalidGlyphBitmapSize;
    const width: usize = slot.width_px;
    const height: usize = slot.height_px;
    const bytes_per_row = std.math.mul(usize, width, bytes_per_pixel) catch
        return error.RasterByteCountOverflow;
    const byte_count = std.math.mul(usize, bytes_per_row, height) catch
        return error.RasterByteCountOverflow;
    const pixel_count = std.math.mul(usize, width, height) catch
        return error.RasterByteCountOverflow;
    return .{
        .width_px = width,
        .height_px = height,
        .bytes_per_row = bytes_per_row,
        .byte_count = byte_count,
        .pixel_count = pixel_count,
    };
}

fn buildTestGlyphFrame(
    allocator: std.mem.Allocator,
    text: []const u8,
    cols: u16,
) !glyph_frame.GlyphFrame {
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = cols, .rows = 1 });
    defer core.deinit();

    core.clearDirty();
    try core.write(text);

    var list = try draw_list.buildDrawList(allocator, core.snapshot());
    defer list.deinit(allocator);

    var glyphs = try glyph_layout.buildGlyphRunList(
        allocator,
        list,
        .{ .font_size_px = 14, .device_scale = 1 },
        glyph_layout.FakeFontBackend{},
    );
    defer glyphs.deinit(allocator);

    var atlas = glyph_atlas.GlyphAtlas.init(allocator, .{});
    defer atlas.deinit();

    return glyph_frame.prepareGlyphFrame(allocator, glyphs, &atlas);
}

test "glyph raster frame builds contiguous upload bytes for glyph frame misses" {
    var frame = try buildTestGlyphFrame(std.testing.allocator, "AA", 2);
    defer frame.deinit(std.testing.allocator);

    // 같은 'A'는 atlas slot을 재사용하므로 upload는 첫 glyph 하나만 생긴다. RasterFrame은
    // 이 upload 후보를 실제 byte buffer로 바꿔 Metal texture upload가 소비할 수 있게 한다.
    try std.testing.expectEqual(@as(usize, 1), frame.uploads.len);

    var raster = try buildGlyphRasterFrame(std.testing.allocator, frame, FakeGlyphRasterizer{});
    defer raster.deinit(std.testing.allocator);

    try std.testing.expect(raster.stats.ready());
    try std.testing.expectEqual(@as(usize, 1), raster.uploads.len);
    try std.testing.expectEqual(@as(usize, 1), raster.stats.upload_count);
    try std.testing.expectEqual(@as(usize, 1), raster.stats.rasterized_count);
    try std.testing.expectEqual(frame.uploads[0].upload_bytes, raster.stats.byte_count);
    try std.testing.expectEqual(frame.uploads[0].upload_bytes, raster.pixels.len);
    try std.testing.expect(raster.stats.non_clear_pixels > 0);
    try std.testing.expectEqual(@as(usize, 0), raster.uploads[0].bytes_offset);
    try std.testing.expectEqual(frame.uploads[0].slot.id, raster.uploads[0].slot.id);
}

test "glyph raster frame records zero-ink uploads without failing the frame" {
    var frame = try buildTestGlyphFrame(std.testing.allocator, "A", 2);
    defer frame.deinit(std.testing.allocator);

    // 두 번째 cell은 공백이다. 현재 fake path에서는 공백도 atlas miss/upload 후보가 될 수
    // 있으므로, zero-ink upload를 실패로 보지 말고 진단값으로만 남긴다.
    var raster = try buildGlyphRasterFrame(std.testing.allocator, frame, FakeGlyphRasterizer{});
    defer raster.deinit(std.testing.allocator);

    try std.testing.expect(raster.stats.ready());
    try std.testing.expectEqual(@as(usize, 2), raster.stats.upload_count);
    try std.testing.expectEqual(@as(usize, 1), raster.stats.zero_ink_uploads);
    try std.testing.expect(raster.stats.non_clear_pixels > 0);
}

test "glyph raster frame rejects upload byte mismatches" {
    var frame = try buildTestGlyphFrame(std.testing.allocator, "A", 1);
    defer frame.deinit(std.testing.allocator);

    // upload_bytes는 slot 크기에서 계산되는 texture copy 크기와 같아야 한다. 이 값이
    // 어긋나면 backend가 덜 복사하거나 더 읽게 되므로, raster 단계에서 바로 실패한다.
    frame.uploads[0].upload_bytes += 1;

    try std.testing.expectError(error.RasterByteCountMismatch, buildGlyphRasterFrame(
        std.testing.allocator,
        frame,
        FakeGlyphRasterizer{},
    ));
}
