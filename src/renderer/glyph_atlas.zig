const std = @import("std");
const glyph_layout = @import("glyph_layout.zig");

pub const AtlasSlotId = u32;

pub const GlyphAtlasConfig = struct {
    max_slots: usize = 1024,
    atlas_width_px: u32 = 1024,
    atlas_height_px: u32 = 1024,
};

pub const AtlasInvalidationReason = enum {
    font_family_changed,
    font_size_changed,
    device_scale_changed,
    color_glyph_theme_changed,
    eviction_policy_changed,
    manual,
};

pub const AtlasSlot = struct {
    id: AtlasSlotId,
    key: glyph_layout.GlyphCacheKey,
    x_px: u32,
    y_px: u32,
    width_px: u32,
    height_px: u32,
    upload_bytes: usize,
    generation: u32,
};

pub const AtlasLookup = struct {
    slot: AtlasSlot,
    uploaded: bool,
    upload_bytes: usize = 0,
    evicted: ?AtlasSlot = null,
};

pub const AtlasInvalidation = struct {
    reason: AtlasInvalidationReason,
    removed_slots: usize,
    generation: u32,
};

pub const AtlasStats = struct {
    hits: usize = 0,
    misses: usize = 0,
    evictions: usize = 0,
    invalidations: usize = 0,
    upload_bytes: usize = 0,
};

const AtlasEntry = struct {
    slot: AtlasSlot,
};

pub const GlyphAtlas = struct {
    allocator: std.mem.Allocator,
    config: GlyphAtlasConfig,
    entries: std.ArrayList(AtlasEntry) = .empty,
    stats: AtlasStats = .{},
    next_slot_id: AtlasSlotId = 1,
    generation: u32 = 0,
    next_x_px: u32 = 0,
    next_y_px: u32 = 0,
    row_height_px: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, config: GlyphAtlasConfig) GlyphAtlas {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ensureGlyph(self: *GlyphAtlas, glyph: glyph_layout.GlyphRun) !AtlasLookup {
        // Atlas의 첫 계약은 "같은 GlyphCacheKey면 같은 slot을 재사용한다"이다.
        // 실제 Metal texture가 없어도 이 계약을 먼저 고정해야 이후 rasterize/upload
        // 단계에서 중복 bitmap과 무효화 버그를 작게 잡을 수 있다.
        if (self.findSlot(glyph.cache_key)) |slot| {
            self.stats.hits += 1;
            return .{ .slot = slot, .uploaded = false };
        }

        self.stats.misses += 1;

        var evicted: ?AtlasSlot = null;
        if (self.config.max_slots == 0) {
            // 0-slot atlas는 캐시를 끄는 테스트/진단 모드다. upload 후보는 만들지만
            // 저장하지 않으므로 다음 요청도 miss가 된다.
            const uncached = self.makeSlot(glyph);
            self.stats.upload_bytes += uncached.upload_bytes;
            return .{
                .slot = uncached,
                .uploaded = true,
                .upload_bytes = uncached.upload_bytes,
            };
        }

        if (self.entries.items.len >= self.config.max_slots) {
            const removed = self.entries.orderedRemove(0);
            evicted = removed.slot;
            self.stats.evictions += 1;
        }

        const slot = self.makeSlot(glyph);
        try self.entries.append(self.allocator, .{ .slot = slot });
        self.stats.upload_bytes += slot.upload_bytes;

        return .{
            .slot = slot,
            .uploaded = true,
            .upload_bytes = slot.upload_bytes,
            .evicted = evicted,
        };
    }

    pub fn invalidate(self: *GlyphAtlas, reason: AtlasInvalidationReason) AtlasInvalidation {
        // 폰트 크기나 scale 변경은 기존 atlas 좌표를 안전하게 재사용할 수 없다는 뜻이다.
        // 그래서 삭제 개수와 이유를 domain event처럼 돌려줘 future debug artifact가
        // "왜 전체 redraw/upload가 생겼는지"를 설명할 수 있게 한다.
        const removed = self.entries.items.len;
        self.entries.clearRetainingCapacity();
        self.stats.invalidations += 1;
        self.generation += 1;
        self.next_x_px = 0;
        self.next_y_px = 0;
        self.row_height_px = 0;
        return .{
            .reason = reason,
            .removed_slots = removed,
            .generation = self.generation,
        };
    }

    pub fn entryCount(self: *const GlyphAtlas) usize {
        return self.entries.items.len;
    }

    fn findSlot(self: *const GlyphAtlas, key: glyph_layout.GlyphCacheKey) ?AtlasSlot {
        for (self.entries.items) |entry| {
            // GlyphCacheKey는 raster에 영향을 주는 필드만 담는 plain value 타입이라(슬라이스·
            // 포인터·union 없음) std.meta.eql이 정확한 구조적 동등성이다. 키에 필드가 추가돼도
            // 손으로 비교를 갱신할 필요가 없어 "다른 bitmap을 같은 slot에 재사용"하는 누락을 막는다.
            if (std.meta.eql(entry.slot.key, key)) return entry.slot;
        }
        return null;
    }

    fn makeSlot(self: *GlyphAtlas, glyph: glyph_layout.GlyphRun) AtlasSlot {
        const dimensions = estimateGlyphBitmapSize(glyph);
        const placement = self.placeGlyph(dimensions);
        const slot: AtlasSlot = .{
            .id = self.next_slot_id,
            .key = glyph.cache_key,
            .x_px = placement.x_px,
            .y_px = placement.y_px,
            .width_px = dimensions.width_px,
            .height_px = dimensions.height_px,
            .upload_bytes = dimensions.upload_bytes,
            .generation = self.generation,
        };
        self.next_slot_id += 1;
        return slot;
    }

    fn placeGlyph(self: *GlyphAtlas, dimensions: EstimatedGlyphBitmapSize) AtlasPlacement {
        // 실제 texture packer를 붙이기 전까지는 단순 row packer로 좌표를 고정한다.
        // 이 좌표가 있어야 Metal backend가 AtlasSlot만 보고 UV를 만들 수 있고,
        // backend마다 "slot id -> 임시 좌표"를 다시 발명하지 않는다.
        const atlas_width = @max(self.config.atlas_width_px, dimensions.width_px);
        if (self.next_x_px != 0 and self.next_x_px > atlas_width - dimensions.width_px) {
            self.next_x_px = 0;
            if (self.next_y_px > std.math.maxInt(u32) - self.row_height_px) {
                self.next_y_px = std.math.maxInt(u32);
            } else {
                self.next_y_px += self.row_height_px;
            }
            self.row_height_px = 0;
        }

        const placement: AtlasPlacement = .{
            .x_px = self.next_x_px,
            .y_px = self.next_y_px,
        };
        self.next_x_px += dimensions.width_px;
        self.row_height_px = @max(self.row_height_px, dimensions.height_px);
        return placement;
    }
};

const EstimatedGlyphBitmapSize = struct {
    width_px: u32,
    height_px: u32,
    upload_bytes: usize,
};

const AtlasPlacement = struct {
    x_px: u32,
    y_px: u32,
};

fn estimateGlyphBitmapSize(glyph: glyph_layout.GlyphRun) EstimatedGlyphBitmapSize {
    // cell 메트릭(advance 폭 × line-height)이 있으면 그 크기로 slot을 잡아 실제 모노스페이스
    // 셀에 맞게 그린다. wide glyph(cell_width=2)는 advance의 2배 폭이다. 메트릭이 없는 경로
    // (테스트/fake backend)는 font_size × scale 정사각으로 대체한다(기존 동작 보존).
    const cell_w = @as(u32, glyph.cache_key.cell_width_px);
    const cell_h = @as(u32, glyph.cache_key.cell_height_px);
    var width_px: u32 = undefined;
    var height_px: u32 = undefined;
    if (cell_w > 0 and cell_h > 0) {
        const span = @max(@as(u32, glyph.cell_width), 1);
        width_px = cell_w * span;
        height_px = cell_h;
    } else {
        const font_size = @max(@as(u32, glyph.cache_key.font_size_px), 1);
        const scale = @max(@as(u32, glyph.cache_key.device_scale), 1);
        const side = font_size * scale;
        width_px = side;
        height_px = side;
    }
    const upload_bytes: usize = @as(usize, width_px) * @as(usize, height_px) * 4;
    return .{
        .width_px = width_px,
        .height_px = height_px,
        .upload_bytes = upload_bytes,
    };
}

fn glyphForTest(
    codepoint: u21,
    key: glyph_layout.GlyphCacheKey,
    style: @import("../terminal.zig").Style,
) glyph_layout.GlyphRun {
    return .{
        .row = 0,
        .col = 0,
        .cell_width = 1,
        .codepoint = codepoint,
        .font_id = key.font_id,
        .glyph_id = key.glyph_id,
        .style = style,
        .cache_key = key,
    };
}

test "glyph atlas reuses a slot for repeated cache keys" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    const key: glyph_layout.GlyphCacheKey = .{
        .font_id = 1,
        .glyph_id = 'A',
        .font_size_px = 14,
        .device_scale = 2,
    };
    const glyph = glyphForTest('A', key, .{});

    // 첫 요청은 rasterize/upload 후보가 되고, 같은 key의 두 번째 요청은 hit가 된다.
    // 실제 texture 없이도 이 계약이 있어야 atlas 중복 할당을 조기에 막을 수 있다.
    const first = try atlas.ensureGlyph(glyph);
    const second = try atlas.ensureGlyph(glyph);

    try std.testing.expect(first.uploaded);
    try std.testing.expect(!second.uploaded);
    try std.testing.expectEqual(first.slot.id, second.slot.id);
    try std.testing.expectEqual(first.slot.x_px, second.slot.x_px);
    try std.testing.expectEqual(first.slot.y_px, second.slot.y_px);
    try std.testing.expect(first.upload_bytes > 0);
    try std.testing.expectEqual(@as(usize, 1), atlas.stats.misses);
    try std.testing.expectEqual(@as(usize, 1), atlas.stats.hits);
    try std.testing.expectEqual(first.upload_bytes, atlas.stats.upload_bytes);
}

test "glyph atlas assigns deterministic row-packed slot coordinates" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .atlas_width_px = 28 });
    defer atlas.deinit();

    // atlas slot 좌표는 future Metal shader의 UV 입력이 된다. 여기서 좌표를 고정하지
    // 않으면 backend가 slot id만 보고 임시 좌표를 만들게 되고, Metal/WebGPU가 서로 다른
    // layout 규칙을 발명할 수 있다. 14px glyph 두 개는 같은 row에, 세 번째는 다음 row에 간다.
    const first = try atlas.ensureGlyph(glyphForTest('A', .{
        .font_id = 1,
        .glyph_id = 'A',
        .font_size_px = 14,
        .device_scale = 1,
    }, .{}));
    const second = try atlas.ensureGlyph(glyphForTest('B', .{
        .font_id = 1,
        .glyph_id = 'B',
        .font_size_px = 14,
        .device_scale = 1,
    }, .{}));
    const third = try atlas.ensureGlyph(glyphForTest('C', .{
        .font_id = 1,
        .glyph_id = 'C',
        .font_size_px = 14,
        .device_scale = 1,
    }, .{}));

    try std.testing.expectEqual(@as(u32, 0), first.slot.x_px);
    try std.testing.expectEqual(@as(u32, 0), first.slot.y_px);
    try std.testing.expectEqual(@as(u32, 14), first.slot.width_px);
    try std.testing.expectEqual(@as(u32, 14), first.slot.height_px);
    try std.testing.expectEqual(@as(u32, 14), second.slot.x_px);
    try std.testing.expectEqual(@as(u32, 0), second.slot.y_px);
    try std.testing.expectEqual(@as(u32, 0), third.slot.x_px);
    try std.testing.expectEqual(@as(u32, 14), third.slot.y_px);
}

test "glyph atlas invalidation resets placement for the next generation" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .atlas_width_px = 28 });
    defer atlas.deinit();

    _ = try atlas.ensureGlyph(glyphForTest('A', .{ .font_id = 1, .glyph_id = 'A', .font_size_px = 14, .device_scale = 1 }, .{}));
    _ = try atlas.ensureGlyph(glyphForTest('B', .{ .font_id = 1, .glyph_id = 'B', .font_size_px = 14, .device_scale = 1 }, .{}));

    _ = atlas.invalidate(.font_size_changed);
    const after = try atlas.ensureGlyph(glyphForTest('C', .{ .font_id = 1, .glyph_id = 'C', .font_size_px = 14, .device_scale = 1 }, .{}));

    // invalidation 후 첫 slot이 예전 row offset을 이어받으면 새 texture generation의
    // UV가 비어 있는 위치를 가리키게 된다. 그래서 placement cursor도 generation과 함께
    // 처음으로 되돌아가야 한다.
    try std.testing.expectEqual(@as(u32, 0), after.slot.x_px);
    try std.testing.expectEqual(@as(u32, 0), after.slot.y_px);
    try std.testing.expectEqual(@as(u32, 1), after.slot.generation);
}

test "glyph atlas placement saturates instead of overflowing the y cursor" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .atlas_width_px = 14 });
    defer atlas.deinit();

    // 이 상태는 정상 제품 사용에서는 나오기 어렵지만, placement cursor가 손상되거나 아주
    // 긴 세션에서 누적됐을 때 ReleaseFast overflow로 터지지 않아야 한다. wrap이 필요한
    // 상태를 직접 만들고 다음 slot을 요청해 y 좌표가 maxInt로 포화되는지 확인한다.
    atlas.next_x_px = 1;
    atlas.next_y_px = std.math.maxInt(u32) - 5;
    atlas.row_height_px = 10;

    const placed = try atlas.ensureGlyph(glyphForTest('A', .{
        .font_id = 1,
        .glyph_id = 'A',
        .font_size_px = 14,
        .device_scale = 1,
    }, .{}));

    try std.testing.expectEqual(@as(u32, 0), placed.slot.x_px);
    try std.testing.expectEqual(std.math.maxInt(u32), placed.slot.y_px);
}

test "glyph atlas key ignores underline but separates raster-affecting style" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    const regular_key: glyph_layout.GlyphCacheKey = .{
        .font_id = 1,
        .glyph_id = 'A',
        .font_size_px = 14,
        .device_scale = 1,
    };
    var underlined_style = @import("../terminal.zig").Style{};
    underlined_style.underline = true;

    const regular = glyphForTest('A', regular_key, .{});
    const underlined = glyphForTest('A', regular_key, underlined_style);
    const bold = glyphForTest('A', .{
        .font_id = 1,
        .glyph_id = 'A',
        .font_size_px = 14,
        .device_scale = 1,
        .style = .{ .bold = true },
    }, .{ .bold = true });

    const first = try atlas.ensureGlyph(regular);
    const underline_hit = try atlas.ensureGlyph(underlined);
    const bold_miss = try atlas.ensureGlyph(bold);

    try std.testing.expectEqual(first.slot.id, underline_hit.slot.id);
    try std.testing.expect(!underline_hit.uploaded);
    try std.testing.expect(bold_miss.uploaded);
    try std.testing.expect(first.slot.id != bold_miss.slot.id);
}

test "glyph atlas separates font size scale font id and color glyph kind" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    const base_key: glyph_layout.GlyphCacheKey = .{
        .font_id = 1,
        .glyph_id = 'A',
        .font_size_px = 14,
        .device_scale = 1,
    };

    _ = try atlas.ensureGlyph(glyphForTest('A', base_key, .{}));
    _ = try atlas.ensureGlyph(glyphForTest('A', .{
        .font_id = 2,
        .glyph_id = 'A',
        .font_size_px = 14,
        .device_scale = 1,
    }, .{}));
    _ = try atlas.ensureGlyph(glyphForTest('A', .{
        .font_id = 1,
        .glyph_id = 'A',
        .font_size_px = 16,
        .device_scale = 1,
    }, .{}));
    _ = try atlas.ensureGlyph(glyphForTest('A', .{
        .font_id = 1,
        .glyph_id = 'A',
        .font_size_px = 14,
        .device_scale = 2,
    }, .{}));
    _ = try atlas.ensureGlyph(glyphForTest('A', .{
        .font_id = 1,
        .glyph_id = 'A',
        .font_size_px = 14,
        .device_scale = 1,
        .color_glyph_kind = .color,
    }, .{}));

    // 이 다섯 key는 같은 글자처럼 보여도 서로 다른 bitmap/cache 의미를 갖는다.
    try std.testing.expectEqual(@as(usize, 5), atlas.entryCount());
    try std.testing.expectEqual(@as(usize, 5), atlas.stats.misses);
}

test "glyph atlas evicts the oldest slot when capacity is full" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .max_slots = 2 });
    defer atlas.deinit();

    const a = try atlas.ensureGlyph(glyphForTest('A', .{ .font_id = 1, .glyph_id = 'A', .font_size_px = 14, .device_scale = 1 }, .{}));
    _ = try atlas.ensureGlyph(glyphForTest('B', .{ .font_id = 1, .glyph_id = 'B', .font_size_px = 14, .device_scale = 1 }, .{}));
    const c = try atlas.ensureGlyph(glyphForTest('C', .{ .font_id = 1, .glyph_id = 'C', .font_size_px = 14, .device_scale = 1 }, .{}));

    try std.testing.expect(c.uploaded);
    try std.testing.expect(c.evicted != null);
    try std.testing.expectEqual(a.slot.id, c.evicted.?.id);
    try std.testing.expectEqual(@as(usize, 2), atlas.entryCount());
    try std.testing.expectEqual(@as(usize, 1), atlas.stats.evictions);
}

test "glyph atlas invalidation clears slots and records the reason" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    _ = try atlas.ensureGlyph(glyphForTest('A', .{ .font_id = 1, .glyph_id = 'A', .font_size_px = 14, .device_scale = 1 }, .{}));
    _ = try atlas.ensureGlyph(glyphForTest('B', .{ .font_id = 1, .glyph_id = 'B', .font_size_px = 14, .device_scale = 1 }, .{}));

    const invalidation = atlas.invalidate(.font_size_changed);
    const after = try atlas.ensureGlyph(glyphForTest('A', .{ .font_id = 1, .glyph_id = 'A', .font_size_px = 14, .device_scale = 1 }, .{}));

    try std.testing.expectEqual(AtlasInvalidationReason.font_size_changed, invalidation.reason);
    try std.testing.expectEqual(@as(usize, 2), invalidation.removed_slots);
    try std.testing.expectEqual(@as(u32, 1), invalidation.generation);
    try std.testing.expectEqual(@as(usize, 1), atlas.entryCount());
    try std.testing.expect(after.uploaded);
    try std.testing.expectEqual(@as(u32, 1), after.slot.generation);
    try std.testing.expectEqual(@as(usize, 1), atlas.stats.invalidations);
}
