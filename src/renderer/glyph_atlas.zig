const std = @import("std");
const glyph_layout = @import("glyph_layout.zig");

pub const AtlasSlotId = u32;

pub const GlyphAtlasConfig = struct {
    max_slots: usize = 1024,
    // **현재** 텍스처 크기. 한 프레임의 고유 글리프가 이 크기에 안 들어가면 grow()가 max까지 2배씩
    // 키워 이 값을 갱신한다(Ghostty식 growable atlas). 그래서 atlas.config.atlas_*_px는 늘 "지금
    // 텍스처가 이만큼이다"를 뜻하고, 렌더러(app_session→metal_frame→set_atlas)가 이 값으로 GPU
    // 텍스처를 재할당한다. 초기값이 곧 시작 크기다.
    atlas_width_px: u32 = 1024,
    atlas_height_px: u32 = 1024,
    // grow 상한(GPU 2D 텍스처 한계 안전선 — 모든 Metal feature set이 ≥8192를 보장). 여기 도달하면
    // 더 못 키우고, 그 프레임의 고유 글리프가 max 용량(≈수만 와이드 글리프)마저 넘는 극단에서만
    // 부분 깨짐이 가능하다(현실에선 도달 불가 — distinct 글리프가 그렇게 많을 수 없다).
    max_atlas_width_px: u32 = 8192,
    max_atlas_height_px: u32 = 8192,
};

pub const AtlasInvalidationReason = enum {
    font_family_changed,
    font_size_changed,
    device_scale_changed,
    color_glyph_theme_changed,
    eviction_policy_changed,
    // row packer 좌표가 텍스처를 소진했다(eviction은 슬롯 수만 줄이고 좌표는 재활용하지 않으므로,
    // 고유 글리프가 많으면 y가 텍스처 높이를 넘는다). 전체 invalidate 후 (0,0)부터 재배치하고,
    // clean repack으로도 한 프레임이 안 들어가면 prepareGlyphFrame이 grow()로 텍스처를 키운 뒤
    // 다시 재배치한다 — 좌표 부족으로 두 글리프가 같은 자리에 겹치는 일(─가 ? 비트맵을 샘플)을 막는다.
    atlas_full,
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
    // 이번 배치가 좌표 소진으로 atlas 전체 invalidate를 일으켰다. frame builder는 이걸 보면 같은
    // frame에서 이미 나눠준 슬롯들이 무효이므로 frame을 처음부터 다시 빌드해야 한다(한 frame에
    // 두 좌표 세대가 섞이면 앞 글리프들이 덮어쓰인 텍셀을 샘플한다).
    invalidated: bool = false,
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
    // 직전 makeSlot이 좌표 소진으로 atlas_full invalidate를 일으켰는지(ensureGlyph가 lookup에 실음).
    place_invalidated: bool = false,
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
            self.place_invalidated = false;
            const uncached = self.makeSlot(glyph);
            self.stats.upload_bytes += uncached.upload_bytes;
            return .{
                .slot = uncached,
                .uploaded = true,
                .upload_bytes = uncached.upload_bytes,
                .invalidated = self.place_invalidated,
            };
        }

        if (self.entries.items.len >= self.config.max_slots) {
            const removed = self.entries.orderedRemove(0);
            evicted = removed.slot;
            self.stats.evictions += 1;
        }

        self.place_invalidated = false;
        const slot = self.makeSlot(glyph);
        try self.entries.append(self.allocator, .{ .slot = slot });
        self.stats.upload_bytes += slot.upload_bytes;

        return .{
            .slot = slot,
            .uploaded = true,
            .upload_bytes = slot.upload_bytes,
            // invalidate가 일어났으면 evicted는 의미를 잃는다(전부 제거됨) — invalidated가 우선 신호.
            .evicted = if (self.place_invalidated) null else evicted,
            .invalidated = self.place_invalidated,
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
        var dimensions = estimateGlyphBitmapSize(glyph);
        // 단일 글리프가 텍스처보다 크면 슬롯을 텍스처 크기로 clamp한다 — 글리프가 잘리지만 UV가
        // 범위 밖으로 새 화면 전체가 깨지는 것(#213이 고친 버그와 같은 증상)은 막는다.
        if (dimensions.width_px > self.config.atlas_width_px or dimensions.height_px > self.config.atlas_height_px) {
            dimensions.width_px = @min(dimensions.width_px, self.config.atlas_width_px);
            dimensions.height_px = @min(dimensions.height_px, self.config.atlas_height_px);
            dimensions.upload_bytes = @as(usize, dimensions.width_px) * @as(usize, dimensions.height_px) * 4;
        }
        const placement = self.placeGlyph(dimensions) orelse blk: {
            // 좌표 소진: atlas 전체를 invalidate(generation++ — 이후 frame의 글리프는 전부 miss로
            // 재배치+재업로드돼 텍스처가 일관되게 다시 채워진다)하고 (0,0)부터 다시 시작한다.
            // frame builder가 재시작할 수 있도록 신호를 남긴다(ensureGlyph가 lookup에 실음).
            _ = self.invalidate(.atlas_full);
            self.place_invalidated = true;
            break :blk self.placeGlyph(dimensions) orelse AtlasPlacement{ .x_px = 0, .y_px = 0 };
        };
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

    /// row packer로 글리프 자리를 잡는다. 텍스처 세로 공간이 소진되면 null — 호출자(makeSlot)가
    /// 전체 invalidate 후 재배치한다. 이 검사가 없으면 좌표가 증가만 해(eviction도 좌표는 재활용
    /// 안 함) y가 텍스처 높이를 넘은 슬롯이 생기고, UV가 범위 밖이 돼 글자가 깨지다가 안 보인다.
    fn placeGlyph(self: *GlyphAtlas, dimensions: EstimatedGlyphBitmapSize) ?AtlasPlacement {
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

        // 이 글리프의 아래 끝이 텍스처를 넘으면 공간 소진(단일 글리프가 atlas보다 큰 극단은
        // width와 같은 정책으로 유효 높이를 키워 통과시킨다 — 별도 이슈).
        const atlas_height = @max(self.config.atlas_height_px, dimensions.height_px);
        if (self.next_y_px > atlas_height - dimensions.height_px) return null;

        const placement: AtlasPlacement = .{
            .x_px = self.next_x_px,
            .y_px = self.next_y_px,
        };
        self.next_x_px += dimensions.width_px;
        self.row_height_px = @max(self.row_height_px, dimensions.height_px);
        return placement;
    }

    /// 텍스처를 키운다(Ghostty식 grow on full). clean repack(invalidate 후 (0,0)부터 재배치)으로도
    /// 한 프레임의 고유 글리프가 안 들어갈 때 호출자(prepareGlyphFrame)가 부른다 — 높이를 먼저 2배,
    /// 더 못 키우면 너비를 2배, max에 도달하면 false. 이게 충돌의 근본 차단책이다: 좌표가 모자라
    /// 두 글리프가 같은 자리를 받는 대신 **자리를 늘려** 모든 distinct 글리프가 고유 좌표를 받게 한다.
    /// 크기만 바꾼다 — 좌표(next_x/y)·캐시 비우기는 호출 흐름의 invalidate가 맡는다(grow→invalidate→
    /// 재시작 순서라 다음 패스가 커진 텍스처에 (0,0)부터 한 세대로 repack된다).
    pub fn grow(self: *GlyphAtlas) bool {
        if (self.config.atlas_height_px < self.config.max_atlas_height_px) {
            self.config.atlas_height_px = @min(self.config.atlas_height_px *| 2, self.config.max_atlas_height_px);
            return true;
        }
        if (self.config.atlas_width_px < self.config.max_atlas_width_px) {
            self.config.atlas_width_px = @min(self.config.atlas_width_px *| 2, self.config.max_atlas_width_px);
            return true;
        }
        return false;
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

test "glyph atlas: span(cell_width)이 키에 포함돼 1칸/2칸 slot이 안 충돌한다(한글 ㄱ 잘림 회귀)" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    // 같은 glyph·같은 메트릭이지만 span만 다른 두 요청 — 예: 어떤 경로가 한글 '가'를 span=1로(wide 폭 미설정), 다른
    // 경로(오버레이)가 span=2로 같은 atlas에 그릴 때. slot 폭 = cell_width_px × span이라 span이 키에 없으면 충돌한다.
    const narrow: glyph_layout.GlyphRun = .{
        .row = 0,
        .col = 0,
        .cell_width = 1,
        .codepoint = 0xAC00, // '가'
        .font_id = 1,
        .glyph_id = 0xAC00,
        .cache_key = .{ .font_id = 1, .glyph_id = 0xAC00, .font_size_px = 14, .device_scale = 2, .cell_width_px = 8, .cell_height_px = 16, .cell_width = 1 },
    };
    var wide = narrow;
    wide.cell_width = 2;
    wide.cache_key.cell_width = 2;

    // span=1을 먼저 캐시(1칸 slot), 그 다음 span=2 요청.
    const s1 = try atlas.ensureGlyph(narrow);
    const s2 = try atlas.ensureGlyph(wide);

    // 키에 span이 있으니 둘은 **다른 slot**이고, span=2 slot은 2칸 폭(= span=1의 2배)이다. 키에 span이 없었다면 s2가
    // s1의 1칸 slot을 재사용(cache hit)해 wide 글리프 오른쪽이 잘렸다(한글이 왼쪽 절반 ㄱ으로 — 회귀의 루트커즈).
    try std.testing.expect(s1.slot.id != s2.slot.id);
    try std.testing.expect(s2.uploaded); // hit가 아니라 새 slot(miss)
    try std.testing.expectEqual(@as(u32, 8), s1.slot.width_px); // 1칸
    try std.testing.expectEqual(@as(u32, 16), s2.slot.width_px); // 2칸(8×2) — 안 잘림
    try std.testing.expectEqual(@as(u32, 16), s1.slot.height_px);
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

test "glyph atlas recycles via full invalidation when the texture rows run out" {
    // 옛 동작은 y가 maxInt까지 포화하며 텍스처 밖 슬롯을 만들었다 — UV가 범위 밖이 돼 글자가
    // 깨지다가 안 보이는 라이브 버그의 원인. 이제 소진되면 전체 invalidate 후 (0,0)부터 재배치한다.
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .atlas_width_px = 14 });
    defer atlas.deinit();

    atlas.next_x_px = 1;
    atlas.next_y_px = std.math.maxInt(u32) - 5;
    atlas.row_height_px = 10;
    const generation_before = atlas.generation;

    const placed = try atlas.ensureGlyph(glyphForTest('A', .{
        .font_id = 1,
        .glyph_id = 'A',
        .font_size_px = 14,
        .device_scale = 1,
    }, .{}));

    try std.testing.expectEqual(@as(u32, 0), placed.slot.x_px);
    try std.testing.expectEqual(@as(u32, 0), placed.slot.y_px); // 텍스처 안으로 재배치
    try std.testing.expect(atlas.generation > generation_before); // 전체 재업로드 신호
    try std.testing.expectEqual(@as(usize, 1), atlas.stats.invalidations);
}

test "glyph atlas slots never exceed the texture height across many unique glyphs" {
    // 라이브 재현(claude CLI 스크롤): 고유 글리프가 텍스처 용량을 넘게 들어와도 모든 슬롯의
    // 아래 끝이 항상 텍스처 안이어야 한다(밖이면 UV 범위 밖 → 깨짐/빈 화면).
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .atlas_width_px = 64, .atlas_height_px = 64 });
    defer atlas.deinit();

    var cp: u21 = 0x4e00; // 고유 CJK 글리프를 대량 투입
    while (cp < 0x4e00 + 200) : (cp += 1) {
        const placed = try atlas.ensureGlyph(glyphForTest(cp, .{
            .font_id = 1,
            .glyph_id = @intCast(cp),
            .font_size_px = 14,
            .device_scale = 1,
        }, .{}));
        try std.testing.expect(placed.slot.y_px + placed.slot.height_px <= 64);
        try std.testing.expect(placed.slot.x_px + placed.slot.width_px <= 64);
    }
    try std.testing.expect(atlas.stats.invalidations > 0); // 소진 -> 재활용이 실제로 일어났다
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

test "a glyph larger than the atlas is clamped into the texture instead of overflowing it" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .atlas_width_px = 16, .atlas_height_px = 16 });
    defer atlas.deinit();
    // 32px 추정 글리프(font 32 × scale 1) — clamp 없이는 slot이 텍스처(16px)를 넘는다.
    const placed = try atlas.ensureGlyph(glyphForTest('W', .{
        .font_id = 1,
        .glyph_id = 'W',
        .font_size_px = 32,
        .device_scale = 1,
    }, .{}));
    try std.testing.expect(placed.slot.x_px + placed.slot.width_px <= 16);
    try std.testing.expect(placed.slot.y_px + placed.slot.height_px <= 16);
}
