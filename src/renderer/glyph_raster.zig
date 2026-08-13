const std = @import("std");
const draw_list = @import("draw_list.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const glyph_frame = @import("glyph_frame.zig");
const glyph_layout = @import("glyph_layout.zig");
const glyph_quads = @import("glyph_quads.zig");
const terminal = @import("../terminal.zig");

const bytes_per_pixel: usize = 4;

pub const GlyphRasterError = error{
    InvalidGlyphIndex,
    InvalidGlyphBitmapSize,
    RasterizerFailed,
    RasterByteCountOverflow,
    RasterByteCountMismatch,
    RasterCountOverflow,
    UploadSlotMismatch,
    RasterNonClearPixelCountInvalid,
    InvalidAtlasTextureSize,
};

pub const GlyphRasterFrameConfig = struct {
    texture_size: glyph_quads.AtlasTextureSize,
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

pub const GlyphRasterSkipReason = enum {
    atlas_slot_outside_texture,
    rasterizer_failed,
};

pub const GlyphRasterUpload = struct {
    upload_index: usize,
    glyph_index: usize,
    slot: glyph_atlas.AtlasSlot,
    evicted: ?glyph_atlas.AtlasSlot = null,
    bytes_offset: usize,
    byte_count: usize,
    bytes_per_row: usize,
    non_clear_pixels: usize,
};

pub const GlyphRasterSkip = struct {
    upload_index: usize,
    glyph_index: usize,
    slot: glyph_atlas.AtlasSlot,
    evicted: ?glyph_atlas.AtlasSlot = null,
    reason: GlyphRasterSkipReason,
};

pub const GlyphRasterFrameStats = struct {
    upload_count: usize = 0,
    rasterized_count: usize = 0,
    skipped_count: usize = 0,
    out_of_bounds_skip_count: usize = 0,
    rasterizer_error_skip_count: usize = 0,
    byte_count: usize = 0,
    non_clear_pixels: usize = 0,
    zero_ink_uploads: usize = 0,

    pub fn ready(self: GlyphRasterFrameStats) bool {
        // 모든 upload가 회계 처리됐는지(rasterize 또는 skip)는 buildGlyphRasterFrame이 구조적으로
        // 보장하므로 여기서 다시 보지 않는다. out-of-bounds skip은 quad 단계가 이미
        // glyph_uv_ready=false로 신호하므로, 여기서는 "예상 못한 rasterizer 실패가 없는가"만 본다.
        // rasterizer가 실패한 glyph는 UV는 있는데 atlas bitmap이 없어 backend가 빈 영역을
        // 샘플링하므로, 그런 frame은 ready로 보지 않는다.
        return self.upload_count == self.rasterized_count + self.out_of_bounds_skip_count;
    }
};

pub const GlyphRasterFrame = struct {
    uploads: []GlyphRasterUpload,
    skips: []GlyphRasterSkip,
    pixels: []u8,
    stats: GlyphRasterFrameStats,

    pub fn deinit(self: *GlyphRasterFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.uploads);
        allocator.free(self.skips);
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

        // buffer는 buildGlyphRasterFrame이 이미 0으로 지워 넘긴다(계약). 그래서 여기서 다시
        // clear하지 않는다. space는 ink가 없으므로 그대로 두고 zero-ink로 보고한다.
        if (request.run.codepoint == ' ' or request.run.codepoint == 0) return .{ .non_clear_pixels = 0 }; // 안 쓴 칸도 잉크 없음

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
    config: GlyphRasterFrameConfig,
    rasterizer: anytype,
) !GlyphRasterFrame {
    // GlyphFrame.uploads는 "어떤 slot을 업로드해야 하는가"까지만 말한다. GlyphRasterFrame은
    // 그 다음 단계로, 실제 backend가 atlas texture에 복사할 contiguous RGBA byte buffer를
    // 만든다. 이 경계를 renderer domain에 두면 Metal bridge가 upload byte 수와 slot 크기를
    // 다시 추론하지 않아도 된다.
    if (config.texture_size.width_px == 0 or config.texture_size.height_px == 0) {
        return error.InvalidAtlasTextureSize;
    }

    var uploads: std.ArrayList(GlyphRasterUpload) = .empty;
    errdefer uploads.deinit(allocator);
    try uploads.ensureTotalCapacity(allocator, frame.uploads.len);

    var skips: std.ArrayList(GlyphRasterSkip) = .empty;
    errdefer skips.deinit(allocator);
    try skips.ensureTotalCapacity(allocator, frame.uploads.len);

    var pixels: std.ArrayList(u8) = .empty;
    errdefer pixels.deinit(allocator);

    var stats: GlyphRasterFrameStats = .{
        .upload_count = frame.uploads.len,
    };

    for (frame.uploads, 0..) |upload, upload_index| {
        if (upload.glyph_index >= frame.glyphs.len) return error.InvalidGlyphIndex;
        const prepared = frame.glyphs[upload.glyph_index];
        if (!std.meta.eql(prepared.slot, upload.slot)) {
            return error.UploadSlotMismatch;
        }

        const shape = try bitmapShapeForSlot(upload.slot);
        if (upload.upload_bytes != shape.byte_count) return error.RasterByteCountMismatch;

        if (!glyph_quads.slotFitsTexture(upload.slot, config.texture_size)) {
            try recordSkip(&skips, &stats, upload_index, upload, .atlas_slot_outside_texture);
            continue;
        }

        const offset = pixels.items.len;
        const pixel_slice = try pixels.addManyAsSlice(allocator, shape.byte_count);
        const end = std.math.add(usize, offset, shape.byte_count) catch
            return error.RasterByteCountOverflow;
        // 이 slice를 미리 0으로 지워 rasterizer에 넘기는 것이 계약이다. rasterizer는 ink가
        // 있는 pixel만 칠하면 되고, ink가 없는 영역(공백 glyph 포함)은 여기서 보장한 0으로
        // 남으므로 rasterizer가 buffer를 다시 clear할 필요가 없다.
        @memset(pixel_slice, 0);

        const result = rasterizer.rasterize(.{
            .run = prepared.run,
            .slot = upload.slot,
            .pixels = pixel_slice,
            .bytes_per_row = shape.bytes_per_row,
        }) catch {
            // 실제 CoreText rasterizer가 붙으면 한 glyph만 실패할 수 있다. 그때 frame 전체를
            // 버리면 다른 glyph까지 사라지므로, 이미 예약한 byte range를 되돌리고 skip으로
            // 관측한다. allocator/slot 불일치 같은 구조적 오류는 rasterizer 호출 전 검증한다.
            pixels.items.len = offset;
            try recordSkip(&skips, &stats, upload_index, upload, .rasterizer_failed);
            continue;
        };
        if (result.non_clear_pixels > shape.pixel_count) {
            return error.RasterNonClearPixelCountInvalid;
        }

        uploads.appendAssumeCapacity(.{
            .upload_index = upload_index,
            .glyph_index = upload.glyph_index,
            .slot = upload.slot,
            .evicted = upload.evicted,
            .bytes_offset = offset,
            .byte_count = shape.byte_count,
            .bytes_per_row = shape.bytes_per_row,
            .non_clear_pixels = result.non_clear_pixels,
        });
        stats.rasterized_count = std.math.add(usize, stats.rasterized_count, 1) catch
            return error.RasterCountOverflow;
        stats.non_clear_pixels = std.math.add(usize, stats.non_clear_pixels, result.non_clear_pixels) catch
            return error.RasterCountOverflow;
        if (result.non_clear_pixels == 0) {
            stats.zero_ink_uploads = std.math.add(usize, stats.zero_ink_uploads, 1) catch
                return error.RasterCountOverflow;
        }
        if (end != pixels.items.len) return error.RasterByteCountMismatch;
    }

    stats.byte_count = pixels.items.len;

    const upload_slice = try uploads.toOwnedSlice(allocator);
    errdefer allocator.free(upload_slice);
    const skip_slice = try skips.toOwnedSlice(allocator);
    errdefer allocator.free(skip_slice);
    const pixel_slice = try pixels.toOwnedSlice(allocator);
    errdefer allocator.free(pixel_slice);

    return .{
        .uploads = upload_slice,
        .skips = skip_slice,
        .pixels = pixel_slice,
        .stats = stats,
    };
}

fn recordSkip(
    skips: *std.ArrayList(GlyphRasterSkip),
    stats: *GlyphRasterFrameStats,
    upload_index: usize,
    upload: glyph_frame.GlyphUpload,
    reason: GlyphRasterSkipReason,
) GlyphRasterError!void {
    skips.appendAssumeCapacity(.{
        .upload_index = upload_index,
        .glyph_index = upload.glyph_index,
        .slot = upload.slot,
        .evicted = upload.evicted,
        .reason = reason,
    });
    stats.skipped_count = std.math.add(usize, stats.skipped_count, 1) catch
        return error.RasterCountOverflow;
    switch (reason) {
        .atlas_slot_outside_texture => {
            stats.out_of_bounds_skip_count = std.math.add(usize, stats.out_of_bounds_skip_count, 1) catch
                return error.RasterCountOverflow;
        },
        .rasterizer_failed => {
            stats.rasterizer_error_skip_count = std.math.add(usize, stats.rasterizer_error_skip_count, 1) catch
                return error.RasterCountOverflow;
        },
    }
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

    var raster = try buildGlyphRasterFrame(std.testing.allocator, frame, .{
        .texture_size = .{ .width_px = 1024, .height_px = 1024 },
    }, FakeGlyphRasterizer{});
    defer raster.deinit(std.testing.allocator);

    try std.testing.expect(raster.stats.ready());
    try std.testing.expectEqual(@as(usize, 1), raster.uploads.len);
    try std.testing.expectEqual(@as(usize, 1), raster.stats.upload_count);
    try std.testing.expectEqual(@as(usize, 1), raster.stats.rasterized_count);
    try std.testing.expectEqual(@as(usize, 0), raster.stats.skipped_count);
    try std.testing.expectEqual(frame.uploads[0].upload_bytes, raster.stats.byte_count);
    try std.testing.expectEqual(frame.uploads[0].upload_bytes, raster.pixels.len);
    try std.testing.expect(raster.stats.non_clear_pixels > 0);
    try std.testing.expectEqual(@as(usize, 0), raster.uploads[0].bytes_offset);
    try std.testing.expectEqual(@as(usize, 0), raster.uploads[0].upload_index);
    try std.testing.expectEqual(frame.uploads[0].slot.id, raster.uploads[0].slot.id);
}

test "glyph raster frame records zero-ink uploads without failing the frame" {
    var frame = try buildTestGlyphFrame(std.testing.allocator, "A", 2);
    defer frame.deinit(std.testing.allocator);

    // 두 번째 cell은 공백이다. 현재 fake path에서는 공백도 atlas miss/upload 후보가 될 수
    // 있으므로, zero-ink upload를 실패로 보지 말고 진단값으로만 남긴다.
    var raster = try buildGlyphRasterFrame(std.testing.allocator, frame, .{
        .texture_size = .{ .width_px = 1024, .height_px = 1024 },
    }, FakeGlyphRasterizer{});
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
        .{ .texture_size = .{ .width_px = 1024, .height_px = 1024 } },
        FakeGlyphRasterizer{},
    ));
}

test "glyph raster frame skips uploads outside the atlas texture without allocating bytes" {
    var frame = try buildTestGlyphFrame(std.testing.allocator, "ABC", 3);
    defer frame.deinit(std.testing.allocator);

    // 'A','B','C'는 row-packer에서 x=0,14,28에 놓인다. texture width 20이면 'B','C'는
    // GlyphQuadFrame과 마찬가지로 경계 밖이다. RasterFrame도 같은 slot을 skip해야
    // 준비 실패 frame에 큰 upload buffer를 만들지 않는다.
    var raster = try buildGlyphRasterFrame(std.testing.allocator, frame, .{
        .texture_size = .{ .width_px = 20, .height_px = 1024 },
    }, FakeGlyphRasterizer{});
    defer raster.deinit(std.testing.allocator);

    try std.testing.expect(raster.stats.ready());
    try std.testing.expectEqual(@as(usize, 3), raster.stats.upload_count);
    try std.testing.expectEqual(@as(usize, 1), raster.stats.rasterized_count);
    try std.testing.expectEqual(@as(usize, 2), raster.stats.skipped_count);
    try std.testing.expectEqual(@as(usize, 2), raster.stats.out_of_bounds_skip_count);
    try std.testing.expectEqual(@as(usize, 1), raster.uploads.len);
    try std.testing.expectEqual(@as(usize, 2), raster.skips.len);
    try std.testing.expectEqual(frame.uploads[0].upload_bytes, raster.pixels.len);
    try std.testing.expectEqual(GlyphRasterSkipReason.atlas_slot_outside_texture, raster.skips[0].reason);
}

const FailingGlyphRasterizer = struct {
    fail_codepoint: u21,

    pub fn rasterize(self: FailingGlyphRasterizer, request: GlyphRasterRequest) GlyphRasterError!GlyphRasterResult {
        if (request.run.codepoint == self.fail_codepoint) return error.RasterByteCountMismatch;
        return (FakeGlyphRasterizer{}).rasterize(request);
    }
};

test "glyph raster frame skips one rasterizer failure without aborting the frame" {
    var frame = try buildTestGlyphFrame(std.testing.allocator, "AB", 2);
    defer frame.deinit(std.testing.allocator);

    // 실제 shaper/rasterizer에서는 특정 glyph만 rasterize에 실패할 수 있다. 그런 실패를
    // frame 전체 에러로 올리면 나머지 glyph까지 사라지므로, 실패 glyph만 skip으로 남긴다.
    var raster = try buildGlyphRasterFrame(std.testing.allocator, frame, .{
        .texture_size = .{ .width_px = 1024, .height_px = 1024 },
    }, FailingGlyphRasterizer{ .fail_codepoint = 'B' });
    defer raster.deinit(std.testing.allocator);

    // rasterizer가 'B' 하나를 실패시켰으므로 frame은 그려질 완전한 준비 상태가 아니다.
    // ready()는 "회계 완료"가 아니라 "rasterizer 실패 없음"을 뜻한다(out-of-bounds skip은
    // quad의 glyph_uv_ready가 신호하므로 ready를 떨어뜨리지 않는다).
    try std.testing.expect(!raster.stats.ready());
    try std.testing.expectEqual(@as(usize, 2), raster.stats.upload_count);
    try std.testing.expectEqual(@as(usize, 1), raster.stats.rasterized_count);
    try std.testing.expectEqual(@as(usize, 1), raster.stats.skipped_count);
    try std.testing.expectEqual(@as(usize, 1), raster.stats.rasterizer_error_skip_count);
    try std.testing.expectEqual(@as(usize, 1), raster.uploads.len);
    try std.testing.expectEqual(@as(usize, 1), raster.skips.len);
    try std.testing.expectEqual(GlyphRasterSkipReason.rasterizer_failed, raster.skips[0].reason);
    try std.testing.expectEqual(@as(usize, 1), raster.skips[0].upload_index);
}
