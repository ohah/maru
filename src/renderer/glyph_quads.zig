const std = @import("std");
const draw_list = @import("draw_list.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const glyph_frame = @import("glyph_frame.zig");
const glyph_layout = @import("glyph_layout.zig");
const terminal = @import("../terminal.zig");

pub const AtlasTextureSize = struct {
    width_px: u32,
    height_px: u32,
};

pub const GlyphUvRect = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

pub const GlyphQuad = struct {
    run: glyph_layout.GlyphRun,
    slot: glyph_atlas.AtlasSlot,
    uv: GlyphUvRect,
};

pub const GlyphQuadFrameStats = struct {
    glyph_count: usize = 0,
    uv_count: usize = 0,

    // glyph이 하나라도 있고 그 전부가 UV로 변환됐는가. 경계를 벗어난 slot은
    // buildGlyphQuadFrame이 개별 skip하므로, 그런 frame은 uv_count < glyph_count가 되어
    // 여기서 false로 드러난다.
    pub fn ready(self: GlyphQuadFrameStats) bool {
        return self.glyph_count > 0 and self.glyph_count == self.uv_count;
    }
};

pub const GlyphQuadFrame = struct {
    size: terminal.Size,
    cursor: terminal.Cursor,
    dirty: ?terminal.DirtyRegion,
    glyphs: []GlyphQuad,
    overlays: []draw_list.DrawOverlay,
    stats: GlyphQuadFrameStats,

    pub fn deinit(self: *GlyphQuadFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        allocator.free(self.overlays);
        self.* = undefined;
    }
};

pub const GlyphQuadError = error{
    InvalidAtlasTextureSize,
    InvalidAtlasSlotSize,
    AtlasSlotOutsideTexture,
};

pub fn uvRectForSlot(
    slot: glyph_atlas.AtlasSlot,
    texture_size: AtlasTextureSize,
) GlyphQuadError!GlyphUvRect {
    // AtlasSlot은 pixel 좌표를 가진다. Metal/WebGPU shader는 0.0~1.0 UV를 쓰므로,
    // 이 변환을 renderer domain에서 한 번만 정의한다. backend가 각자 나눗셈과 bounds
    // check를 다시 만들면 slot overflow/scale bug가 platform마다 다르게 난다.
    if (texture_size.width_px == 0 or texture_size.height_px == 0) {
        return error.InvalidAtlasTextureSize;
    }
    if (slot.width_px == 0 or slot.height_px == 0) {
        return error.InvalidAtlasSlotSize;
    }
    if (!slotFitsTexture(slot, texture_size)) {
        return error.AtlasSlotOutsideTexture;
    }

    const width_f: f32 = @floatFromInt(texture_size.width_px);
    const height_f: f32 = @floatFromInt(texture_size.height_px);
    const x0: f32 = @floatFromInt(slot.x_px);
    const y0: f32 = @floatFromInt(slot.y_px);
    const x1: f32 = @floatFromInt(slot.x_px + slot.width_px);
    const y1: f32 = @floatFromInt(slot.y_px + slot.height_px);

    return .{
        .u0 = x0 / width_f,
        .v0 = y0 / height_f,
        .u1 = x1 / width_f,
        .v1 = y1 / height_f,
    };
}

pub fn buildGlyphQuadFrame(
    allocator: std.mem.Allocator,
    frame: glyph_frame.GlyphFrame,
    texture_size: AtlasTextureSize,
) !GlyphQuadFrame {
    // GlyphFrame은 "어떤 atlas slot을 쓸지"까지만 결정한다. GlyphQuadFrame은 그 다음
    // backend 입력 단계로, slot pixel rect를 shader UV로 바꾼다. 이 경계를 따로 두면
    // Metal backend가 font/layout/cache 정책을 다시 해석하지 않아도 된다.
    var glyphs: std.ArrayList(GlyphQuad) = .empty;
    errdefer glyphs.deinit(allocator);
    try glyphs.ensureTotalCapacity(allocator, frame.glyphs.len);

    var stats: GlyphQuadFrameStats = .{
        .glyph_count = frame.glyphs.len,
    };

    for (frame.glyphs) |glyph| {
        // 경계를 벗어난 slot 하나가 frame 전체를 날리지 않도록, UV 변환에 실패한 glyph만
        // 건너뛴다. (atlas가 자기 texture 밖에 slot을 놓을 수 있는 문제 자체는 별도 overflow
        // 정책 PR에서 다룬다.) skip이 생기면 uv_count < glyph_count가 되어 ready()가 false가
        // 되므로 누락이 통계로 드러난다.
        const uv = uvRectForSlot(glyph.slot, texture_size) catch |err| switch (err) {
            error.AtlasSlotOutsideTexture => continue,
            else => return err,
        };
        stats.uv_count += 1;
        glyphs.appendAssumeCapacity(.{
            .run = glyph.run,
            .slot = glyph.slot,
            .uv = uv,
        });
    }

    const overlay_copy = try allocator.dupe(draw_list.DrawOverlay, frame.overlays);
    errdefer allocator.free(overlay_copy);
    const glyph_slice = try glyphs.toOwnedSlice(allocator);

    return .{
        .size = frame.size,
        .cursor = frame.cursor,
        .dirty = frame.dirty,
        .glyphs = glyph_slice,
        .overlays = overlay_copy,
        .stats = stats,
    };
}

/// slot의 pixel rect가 texture 경계 안에 완전히 들어가는지 본다. quad 단계(UV 변환)와 raster
/// 단계(upload byte)가 같은 판정을 써야 두 단계가 같은 out-of-bounds slot을 skip한다. 그래서
/// 이 bounds 계산은 여기 한 곳에만 둔다.
pub fn slotFitsTexture(slot: glyph_atlas.AtlasSlot, texture_size: AtlasTextureSize) bool {
    return rangeFits(slot.x_px, slot.width_px, texture_size.width_px) and
        rangeFits(slot.y_px, slot.height_px, texture_size.height_px);
}

fn rangeFits(start: u32, len: u32, limit: u32) bool {
    if (len == 0 or start >= limit) return false;
    return len <= limit - start;
}

fn testSlot(x: u32, y: u32, width: u32, height: u32) glyph_atlas.AtlasSlot {
    return .{
        .id = 1,
        .key = .{
            .font_id = 1,
            .glyph_id = 'A',
            .font_size_px = 14,
            .device_scale = 1,
        },
        .x_px = x,
        .y_px = y,
        .width_px = width,
        .height_px = height,
        .upload_bytes = @as(usize, width) * @as(usize, height) * 4,
        .generation = 0,
    };
}

test "glyph uv rect normalizes atlas slot pixels" {
    // 이 테스트는 atlas slot 좌표가 shader UV로 바뀌는 수학을 고정한다. 제품 Metal
    // shader가 같은 계산을 다른 곳에서 반복하지 않게 renderer domain의 단일 계약으로 둔다.
    const uv = try uvRectForSlot(testSlot(16, 8, 16, 8), .{
        .width_px = 64,
        .height_px = 32,
    });

    try std.testing.expectEqual(@as(f32, 0.25), uv.u0);
    try std.testing.expectEqual(@as(f32, 0.25), uv.v0);
    try std.testing.expectEqual(@as(f32, 0.5), uv.u1);
    try std.testing.expectEqual(@as(f32, 0.5), uv.v1);
}

test "glyph uv rect rejects invalid texture and out-of-bounds slots" {
    // UV 계산이 실패해야 하는 모양을 명시한다. 여기서 걸러야 native backend가 texture 밖을
    // 샘플링하거나 0 크기 texture에서 NaN/inf UV를 만드는 문제를 피할 수 있다.
    try std.testing.expectError(
        error.InvalidAtlasTextureSize,
        uvRectForSlot(testSlot(0, 0, 8, 8), .{ .width_px = 0, .height_px = 32 }),
    );
    try std.testing.expectError(
        error.InvalidAtlasSlotSize,
        uvRectForSlot(testSlot(0, 0, 0, 8), .{ .width_px = 32, .height_px = 32 }),
    );
    try std.testing.expectError(
        error.AtlasSlotOutsideTexture,
        uvRectForSlot(testSlot(24, 0, 16, 8), .{ .width_px = 32, .height_px = 32 }),
    );
    try std.testing.expectError(
        error.AtlasSlotOutsideTexture,
        uvRectForSlot(testSlot(0, 24, 8, 16), .{ .width_px = 32, .height_px = 32 }),
    );
}

test "glyph quad frame converts glyph frame slots into shader uv input" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // 이 테스트는 제품 renderer 준비 경계의 다음 단계다. GlyphFrame의 slot 좌표가
    // GlyphQuadFrame의 UV로 변환되고, cursor/underline overlay도 보존되어야 Metal
    // backend가 텍스트와 draw-time 효과를 같은 frame에서 그릴 수 있다.
    core.clearDirty();
    try core.write("AA");
    core.screen.cells[0].style.underline = true;

    var list = try @import("draw_list.zig").buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyph_runs = try @import("glyph_layout.zig").buildGlyphRunList(
        std.testing.allocator,
        list,
        .{ .font_size_px = 16, .device_scale = 1 },
        @import("glyph_layout.zig").FakeFontBackend{},
    );
    defer glyph_runs.deinit(std.testing.allocator);

    var atlas = glyph_atlas.GlyphAtlas.init(std.testing.allocator, .{ .atlas_width_px = 64 });
    defer atlas.deinit();

    var frame = try glyph_frame.prepareGlyphFrame(std.testing.allocator, glyph_runs, &atlas);
    defer frame.deinit(std.testing.allocator);

    var quads = try buildGlyphQuadFrame(std.testing.allocator, frame, .{
        .width_px = 64,
        .height_px = 64,
    });
    defer quads.deinit(std.testing.allocator);

    try std.testing.expect(quads.stats.ready());
    try std.testing.expectEqual(frame.glyphs.len, quads.glyphs.len);
    try std.testing.expectEqual(frame.overlays.len, quads.overlays.len);
    try std.testing.expectEqual(frame.glyphs[0].slot.id, quads.glyphs[0].slot.id);
    try std.testing.expectEqual(frame.glyphs[0].run.codepoint, quads.glyphs[0].run.codepoint);
    try std.testing.expectEqual(@as(f32, 0.0), quads.glyphs[0].uv.u0);
    try std.testing.expectEqual(@as(f32, 0.0), quads.glyphs[0].uv.v0);
    try std.testing.expectEqual(@as(f32, 0.25), quads.glyphs[0].uv.u1);
    try std.testing.expectEqual(@as(f32, 0.25), quads.glyphs[0].uv.v1);

    // 같은 'A'는 같은 atlas slot을 재사용하므로 UV도 같아야 한다.
    try std.testing.expectEqual(quads.glyphs[0].slot.id, quads.glyphs[1].slot.id);
    try std.testing.expectEqual(quads.glyphs[0].uv.u0, quads.glyphs[1].uv.u0);
    try std.testing.expectEqual(quads.glyphs[0].uv.u1, quads.glyphs[1].uv.u1);
}

test "glyph quad frame skips slots outside the texture instead of failing the whole frame" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // 'A','B','C'는 row-packer에서 x=0,14,28에 놓인다. 일부러 atlas보다 좁은 texture를 넘겨
    // 'B','C' slot이 width 경계를 벗어나게 만든다. 경계 밖 slot 하나가 frame 전체를 실패시키면
    // 큰 폰트/긴 세션에서 화면이 통째로 비므로, 그런 glyph만 개별 skip하고 in-bounds 'A'는
    // 그대로 변환되어야 한다. 누락이 생겼으니 ready()는 false여야 한다.
    core.clearDirty();
    try core.write("ABC");

    var list = try @import("draw_list.zig").buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyph_runs = try @import("glyph_layout.zig").buildGlyphRunList(
        std.testing.allocator,
        list,
        .{ .font_size_px = 14, .device_scale = 1 },
        @import("glyph_layout.zig").FakeFontBackend{},
    );
    defer glyph_runs.deinit(std.testing.allocator);

    var atlas = glyph_atlas.GlyphAtlas.init(std.testing.allocator, .{ .atlas_width_px = 64 });
    defer atlas.deinit();

    var frame = try glyph_frame.prepareGlyphFrame(std.testing.allocator, glyph_runs, &atlas);
    defer frame.deinit(std.testing.allocator);

    var quads = try buildGlyphQuadFrame(std.testing.allocator, frame, .{
        .width_px = 20,
        .height_px = 64,
    });
    defer quads.deinit(std.testing.allocator);

    // glyph_count는 준비된 전체 glyph 수, uv_count는 실제 변환된 수. 둘이 어긋나면 ready()=false.
    try std.testing.expectEqual(@as(usize, 3), quads.stats.glyph_count);
    try std.testing.expectEqual(@as(usize, 1), quads.stats.uv_count);
    try std.testing.expectEqual(@as(usize, 1), quads.glyphs.len);
    try std.testing.expect(!quads.stats.ready());
    try std.testing.expectEqual(@as(u21, 'A'), quads.glyphs[0].run.codepoint);
    // 경계 밖 slot을 건너뛰어도 overlay 같은 frame-level 데이터는 그대로 보존된다.
    try std.testing.expectEqual(frame.overlays.len, quads.overlays.len);
}

test "glyph quad frame rejects invalid texture size instead of hiding configuration bugs" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 1, .rows = 1 });
    defer core.deinit();

    // out-of-bounds slot은 일부 glyph 누락으로 관측할 수 있지만, 0 크기 texture는 renderer
    // 설정 자체가 깨진 것이다. 이를 skip으로 삼키면 app/smoke가 glyph_uv_ready=false만
    // 남기고 근본 원인인 잘못된 texture 설정을 놓치므로 에러로 닫는다.
    core.clearDirty();
    try core.write("A");

    var list = try @import("draw_list.zig").buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyph_runs = try @import("glyph_layout.zig").buildGlyphRunList(
        std.testing.allocator,
        list,
        .{ .font_size_px = 14, .device_scale = 1 },
        @import("glyph_layout.zig").FakeFontBackend{},
    );
    defer glyph_runs.deinit(std.testing.allocator);

    var atlas = glyph_atlas.GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    var frame = try glyph_frame.prepareGlyphFrame(std.testing.allocator, glyph_runs, &atlas);
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidAtlasTextureSize, buildGlyphQuadFrame(
        std.testing.allocator,
        frame,
        .{ .width_px = 0, .height_px = 64 },
    ));
}
