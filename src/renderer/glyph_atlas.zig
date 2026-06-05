const std = @import("std");
const glyph_layout = @import("glyph_layout.zig");

pub const AtlasSlotId = u32;

pub const GlyphAtlasConfig = struct {
    max_slots: usize = 1024,
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
        const slot: AtlasSlot = .{
            .id = self.next_slot_id,
            .key = glyph.cache_key,
            .width_px = dimensions.width_px,
            .height_px = dimensions.height_px,
            .upload_bytes = dimensions.upload_bytes,
            .generation = self.generation,
        };
        self.next_slot_id += 1;
        return slot;
    }
};

const EstimatedGlyphBitmapSize = struct {
    width_px: u32,
    height_px: u32,
    upload_bytes: usize,
};

fn estimateGlyphBitmapSize(glyph: glyph_layout.GlyphRun) EstimatedGlyphBitmapSize {
    // 실제 rasterizer가 붙기 전까지 upload byte는 보수적인 관측 후보값이다.
    // slot/cache 동작을 테스트할 수 있게 하되, 픽셀 품질 계약으로 오해되지 않게
    // font size와 scale만 사용한다.
    const font_size = @max(@as(u32, glyph.cache_key.font_size_px), 1);
    const scale = @max(@as(u32, glyph.cache_key.device_scale), 1);
    const side = font_size * scale;
    const upload_bytes: usize = @as(usize, side) * @as(usize, side) * 4;
    return .{
        .width_px = side,
        .height_px = side,
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
    try std.testing.expect(first.upload_bytes > 0);
    try std.testing.expectEqual(@as(usize, 1), atlas.stats.misses);
    try std.testing.expectEqual(@as(usize, 1), atlas.stats.hits);
    try std.testing.expectEqual(first.upload_bytes, atlas.stats.upload_bytes);
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
