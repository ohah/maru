const std = @import("std");
const draw_list = @import("draw_list.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const glyph_layout = @import("glyph_layout.zig");
const terminal = @import("../terminal.zig");

pub const PreparedGlyph = struct {
    run: glyph_layout.GlyphRun,
    slot: glyph_atlas.AtlasSlot,
};

pub const GlyphUpload = struct {
    glyph_index: usize,
    slot: glyph_atlas.AtlasSlot,
    upload_bytes: usize,
    evicted: ?glyph_atlas.AtlasSlot = null,
};

pub const GlyphFrameStats = struct {
    glyph_count: usize = 0,
    upload_count: usize = 0,
    upload_bytes: usize = 0,
    reused_count: usize = 0,
    evicted_count: usize = 0,
    fallback_count: usize = 0,
    replacement_count: usize = 0,
};

pub const GlyphFrame = struct {
    size: terminal.Size,
    cursor: terminal.Cursor,
    dirty: ?terminal.DirtyRegion,
    glyphs: []PreparedGlyph,
    overlays: []draw_list.DrawOverlay,
    uploads: []GlyphUpload,
    stats: GlyphFrameStats,

    pub fn deinit(self: *GlyphFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        allocator.free(self.overlays);
        allocator.free(self.uploads);
        self.* = undefined;
    }
};

pub fn prepareGlyphFrame(
    allocator: std.mem.Allocator,
    glyphs: glyph_layout.GlyphRunList,
    atlas: *glyph_atlas.GlyphAtlas,
) !GlyphFrame {
    // GlyphFrame은 제품 Metal/WebGPU backend가 소비할 첫 텍스트 frame 계약이다.
    // 여기서는 GPU texture를 직접 만들지 않고, 각 glyph가 어느 atlas slot을 써야 하는지와
    // 이번 frame에서 어떤 slot을 업로드해야 하는지만 결정한다. 이 경계가 있어야 다음
    // backend 구현이 font/layout/cache 정책을 다시 해석하지 않는다.
    var prepared: std.ArrayList(PreparedGlyph) = .empty;
    errdefer prepared.deinit(allocator);
    try prepared.ensureTotalCapacity(allocator, glyphs.glyphs.len);

    var uploads: std.ArrayList(GlyphUpload) = .empty;
    errdefer uploads.deinit(allocator);
    try uploads.ensureTotalCapacity(allocator, glyphs.glyphs.len);

    var stats: GlyphFrameStats = .{
        .glyph_count = glyphs.glyphs.len,
        .fallback_count = glyphs.fallback_count,
        .replacement_count = glyphs.replacement_count,
    };

    for (glyphs.glyphs, 0..) |glyph, index| {
        const lookup = try atlas.ensureGlyph(glyph);
        prepared.appendAssumeCapacity(.{
            .run = glyph,
            .slot = lookup.slot,
        });

        if (lookup.uploaded) {
            stats.upload_count += 1;
            stats.upload_bytes += lookup.upload_bytes;
            if (lookup.evicted != null) stats.evicted_count += 1;
            uploads.appendAssumeCapacity(.{
                .glyph_index = index,
                .slot = lookup.slot,
                .upload_bytes = lookup.upload_bytes,
                .evicted = lookup.evicted,
            });
        } else {
            stats.reused_count += 1;
        }
    }

    const overlay_copy = try allocator.dupe(draw_list.DrawOverlay, glyphs.overlays);
    errdefer allocator.free(overlay_copy);
    const prepared_slice = try prepared.toOwnedSlice(allocator);
    errdefer allocator.free(prepared_slice);
    const upload_slice = try uploads.toOwnedSlice(allocator);
    errdefer allocator.free(upload_slice);

    return .{
        .size = glyphs.size,
        .cursor = glyphs.cursor,
        .dirty = glyphs.dirty,
        .glyphs = prepared_slice,
        .overlays = overlay_copy,
        .uploads = upload_slice,
        .stats = stats,
    };
}

test "glyph frame prepares atlas slots and upload plan" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // 이 테스트는 실제 GPU 없이 "frame 준비" 계약을 고정한다. 같은 glyph가 반복되면
    // atlas slot은 재사용되어야 하고, backend는 첫 miss만 upload 후보로 받아야 한다.
    core.clearDirty();
    try core.write("AA");

    var list = try draw_list.buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyph_runs = try glyph_layout.buildGlyphRunList(
        std.testing.allocator,
        list,
        .{ .font_size_px = 14, .device_scale = 2 },
        glyph_layout.FakeFontBackend{},
    );
    defer glyph_runs.deinit(std.testing.allocator);

    var atlas = glyph_atlas.GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    var frame = try prepareGlyphFrame(std.testing.allocator, glyph_runs, &atlas);
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), frame.glyphs.len);
    try std.testing.expectEqual(frame.glyphs[0].slot.id, frame.glyphs[1].slot.id);
    try std.testing.expectEqual(@as(usize, 2), frame.stats.upload_count);
    try std.testing.expectEqual(@as(usize, 2), frame.stats.reused_count);
    try std.testing.expectEqual(@as(usize, 2), frame.uploads.len);
    try std.testing.expect(frame.stats.upload_bytes > 0);
    try std.testing.expectEqual(@as(usize, 2), atlas.stats.hits);
    try std.testing.expectEqual(@as(usize, 2), atlas.stats.misses);
}

test "glyph frame preserves overlays for draw-time effects" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 1 });
    defer core.deinit();

    // underline과 cursor는 glyph bitmap이 아니라 draw-time overlay다. GlyphFrame으로
    // 넘어오며 이 정보가 사라지면 Metal backend가 atlas slot은 알아도 실제 터미널
    // UI 효과를 그릴 수 없으므로, frame 계약에서 반드시 보존한다.
    core.clearDirty();
    try core.write("A");
    core.cells[0].style.underline = true;

    var list = try draw_list.buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyph_runs = try glyph_layout.buildGlyphRunList(
        std.testing.allocator,
        list,
        .{},
        glyph_layout.FakeFontBackend{},
    );
    defer glyph_runs.deinit(std.testing.allocator);

    var atlas = glyph_atlas.GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    var frame = try prepareGlyphFrame(std.testing.allocator, glyph_runs, &atlas);
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.overlays.len);
    try std.testing.expectEqual(@as(u16, 0), frame.overlays[0].underline.row);
    try std.testing.expectEqual(@as(u16, 0), frame.overlays[0].underline.col);
    try std.testing.expectEqual(@as(u16, 0), frame.overlays[1].cursor.row);
    try std.testing.expectEqual(@as(u16, 1), frame.overlays[1].cursor.col);
}

test "glyph frame reports atlas evictions without hiding reuse stats" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // eviction은 나중에 texture 좌표 무효화와 redraw 원인을 추적할 때 필요하다.
    // frame이 이 값을 삼켜 버리면 screenshot만 보고 왜 upload가 늘었는지 알 수 없다.
    core.clearDirty();
    try core.write("ABC");

    var list = try draw_list.buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyph_runs = try glyph_layout.buildGlyphRunList(
        std.testing.allocator,
        list,
        .{},
        glyph_layout.FakeFontBackend{},
    );
    defer glyph_runs.deinit(std.testing.allocator);

    var atlas = glyph_atlas.GlyphAtlas.init(std.testing.allocator, .{ .max_slots = 2 });
    defer atlas.deinit();

    var frame = try prepareGlyphFrame(std.testing.allocator, glyph_runs, &atlas);
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), frame.stats.upload_count);
    try std.testing.expectEqual(@as(usize, 1), frame.stats.evicted_count);
    try std.testing.expectEqual(@as(usize, 3), frame.uploads.len);
    try std.testing.expect(frame.uploads[2].evicted != null);
}
