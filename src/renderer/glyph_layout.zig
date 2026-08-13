const std = @import("std");
const draw_list = @import("draw_list.zig");
const terminal = @import("../terminal.zig");

pub const FontId = u32;
pub const GlyphId = u32;

pub const ColorGlyphKind = enum {
    monochrome,
    color,
};

pub const RasterStyleFlags = struct {
    // 이름 그대로 "rasterize(glyph bitmap)에 영향을 주는 style"만 담는다. bold/italic은 face가
    // 달라지거나 synthetic이라 같은 codepoint라도 다른 비트맵이 된다. underline은 glyph가
    // 아니라 draw-time 오버레이 선이라(같은 'A' 비트맵을 색·밑줄과 무관하게 재사용) 키에
    // 넣지 않는다. underline 정보는 `GlyphRun.style`에 그대로 남아 렌더러가 오버레이로 그린다.
    bold: bool = false,
    italic: bool = false,
};

pub const TextLayoutConfig = struct {
    font_size_px: u16 = 14,
    device_scale: u16 = 1,
    // **cell_width_px = grid advance**(셀 배치 간격, 자간 반영) — 합성 글리프(box/block/Powerline) slot·셀 배경·hit-test에
    // 쓴다. **glyph_cell_width_px = 폰트 글리프 비트맵 폭(자연폭, 자간 무관)** — 폰트 글리프 atlas slot에 쓴다. 0이면
    // 메트릭이 없는 경로(테스트/fake backend)라 cell_width_px로 폴백(기존 동작 보존). slot 폭 선택은 slotCellWidthPx.
    cell_width_px: u16 = 0,
    glyph_cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,

    /// glyph의 atlas slot 폭 기준이 되는 cell 폭(glyph_id별). **합성 글리프(box/block/Powerline)·notdef는 glyph_id==0**
    /// (셰이퍼가 0으로 정규화 — shaped_records 주석)이고 셀에 꽉 차 이음매 없이 타일링돼야 하므로 grid advance(cell_width_px)
    /// 그대로. **실제 폰트 글리프(id!=0)는 자간과 무관한 자연폭(glyph_cell_width_px)**으로 그려, 음수 자간이 폰트 글리프 slot을
    /// 좁혀 "셀보다 넓다" 오판→축소+ink세로중앙(세로 흔들림)·찌그러짐을 내던 버그를 끊는다(code-review). glyph_cell_width_px
    /// 미설정(0)이면 cell_width_px로 폴백(메트릭 없는 fake/테스트 경로 — 기존 동작).
    pub fn slotCellWidthPx(self: TextLayoutConfig, glyph_id: GlyphId) u16 {
        if (glyph_id == 0) return self.cell_width_px;
        return if (self.glyph_cell_width_px != 0) self.glyph_cell_width_px else self.cell_width_px;
    }
};

test "TextLayoutConfig.slotCellWidthPx: 합성/notdef=grid advance, 폰트 글리프=자연폭(슬롯 분리)" {
    // advance 10(자간으로 좁힘) vs 자연폭 16.
    const c = TextLayoutConfig{ .cell_width_px = 10, .glyph_cell_width_px = 16 };
    try std.testing.expectEqual(@as(u16, 10), c.slotCellWidthPx(0)); // 합성/notdef → grid advance(셀폭 — 타일링)
    try std.testing.expectEqual(@as(u16, 16), c.slotCellWidthPx(42)); // 폰트 글리프 → 자연폭(자간 무관)
    // glyph_cell_width_px 미설정(0, fake/테스트) → cell_width_px 폴백(기존 동작).
    const c2 = TextLayoutConfig{ .cell_width_px = 10 };
    try std.testing.expectEqual(@as(u16, 10), c2.slotCellWidthPx(42));
    try std.testing.expectEqual(@as(u16, 10), c2.slotCellWidthPx(0));
}

pub const GlyphCacheKey = struct {
    font_id: FontId,
    glyph_id: GlyphId,
    font_size_px: u16,
    device_scale: u16,
    // Rich Chrome can request a role-specific UI font size while sharing the terminal atlas.
    // Zero preserves the terminal appearance size; non-zero is a logical-point milli override
    // consumed only by the platform rasterizer and therefore belongs to atlas identity.
    raster_font_size_milli: u16 = 0,
    // atlas slot 폭의 단일 출처. **TextLayoutConfig.slotCellWidthPx의 결과**가 들어온다 — 폰트 글리프는 자연폭(자간
    // 무관), 합성/notdef(glyph_id==0)은 grid advance(셀폭). 0이면 정사각 대체. slot 폭이 바뀌면 같은 glyph라도 새 slot이라
    // cache identity의 일부다. (높이는 advance×line-height의 cell_height_px.)
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,
    // 셀 span(EAW 폭: wide=2, 그 외 1). atlas slot 폭 = cell_width_px × cell_width(estimateGlyphBitmapSize)라 **slot
    // 크기에 영향**을 주므로 cache identity의 일부다. 빠지면 같은 glyph를 span=1로 먼저 캐시한 1칸 slot을 span=2 요청이
    // 재사용해 wide 글리프 오른쪽이 잘린다(공유 atlas에서 한 경로가 wide 폭을 안 줬을 때 — 한글 ㄱ 잘림 회귀).
    cell_width: u2 = 1,
    // 목표 raster 크기(device px). 0이면 위 셀 메트릭에서 slot 크기를 산출한다(기존 동작). >0이면
    // estimateGlyphBitmapSize가 셀 배수 대신 이 크기로 slot을 잡아, atlas에 글리프를 **최종 크기로
    // 직접 굽는다** — GPU slot-stretch(셀 크기로 굽고 확대)로 생기는 blur를 없애는 경로(헤더 아이콘 등).
    // slot 크기를 바꾸므로 cache identity의 일부다: 같은 glyph라도 다른 목표 크기는 다른 bitmap이라
    // 다른 slot이어야 한다(findSlot의 std.meta.eql이 새 필드를 자동으로 포함).
    raster_width_px: u16 = 0,
    raster_height_px: u16 = 0,
    style: RasterStyleFlags = .{},
    color_glyph_kind: ColorGlyphKind = .monochrome,
};

pub const GlyphRun = struct {
    row: u16,
    col: u16,
    cell_width: u2,
    codepoint: u21,
    font_id: FontId,
    glyph_id: GlyphId,
    fallback: bool = false,
    replacement: bool = false,
    style: terminal.Style = .{},
    cache_key: GlyphCacheKey,
};

pub const GlyphRunList = struct {
    size: terminal.Size,
    cursor: terminal.Cursor,
    dirty: ?terminal.DirtyRegion,
    glyphs: []GlyphRun,
    overlays: []draw_list.DrawOverlay,
    fallback_count: usize = 0,
    replacement_count: usize = 0,

    pub fn deinit(self: *GlyphRunList, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        allocator.free(self.overlays);
        self.* = undefined;
    }
};

pub const ShapeResult = struct {
    font_id: FontId,
    glyph_id: GlyphId,
    fallback: bool = false,
    replacement: bool = false,
    color_glyph_kind: ColorGlyphKind = .monochrome,
};

pub const FakeFontBackend = struct {
    primary_font_id: FontId = 1,
    fallback_font_id: FontId = 2,
    replacement_glyph_id: GlyphId = 0xfffd,

    pub fn shape(self: FakeFontBackend, cell: draw_list.DrawCell) ShapeResult {
        // 이 fake backend는 실제 폰트 품질을 흉내 내려는 코드가 아니다. 기본 CI에서
        // CoreText 없이도 "primary/fallback/replacement가 어느 데이터로 흘러가는가"를
        // 고정하기 위한 테스트용 shaper다.
        // 안 쓴 칸(codepoint 0)은 그릴 잉크가 없다 — 공백과 같이 본다. 안 그러면 화면의 빈 칸이
        // 전부 "지원 못 하는 글자"로 분류돼 replacement glyph로 샌다(§안 쓴 칸, types.Cell).
        const codepoint: u21 = if (cell.codepoint == 0) ' ' else cell.codepoint;
        if (isPrimaryCodepoint(codepoint)) {
            return .{
                .font_id = self.primary_font_id,
                .glyph_id = glyphIdFor(codepoint),
                .color_glyph_kind = colorGlyphKind(codepoint),
            };
        }

        if (isFallbackCodepoint(codepoint)) {
            return .{
                .font_id = self.fallback_font_id,
                .glyph_id = glyphIdFor(codepoint),
                .fallback = true,
                .color_glyph_kind = colorGlyphKind(codepoint),
            };
        }

        return .{
            .font_id = self.fallback_font_id,
            .glyph_id = self.replacement_glyph_id,
            .fallback = true,
            .replacement = true,
        };
    }
};

pub fn buildGlyphRunList(
    allocator: std.mem.Allocator,
    list: draw_list.DrawList,
    config: TextLayoutConfig,
    shaper: anytype,
) !GlyphRunList {
    // GlyphRunList는 DrawList보다 한 단계 더 font/layout에 가까운 계약이다. 여기서도
    // CoreText 타입이나 atlas texture를 노출하지 않아야 나중에 Metal/WebGPU backend가
    // 같은 glyph run을 소비할 수 있다.
    //
    // shaper는 `shape(draw_list.DrawCell) ShapeResult`를 제공하는 값이면 된다(anytype).
    // 이 함수는 deterministic fake/backend 테스트와 간단한 probe를 위한 per-cell 경로다.
    // 실제 CoreText 제품 shaper는 줄/런 단위 결과를 `ShapedGlyphRecord -> GlyphRunList`로
    // 만든 뒤 `RendererState.buildFrameFromGlyphRunList`로 들어간다.
    var glyphs: std.ArrayList(GlyphRun) = .empty;
    errdefer glyphs.deinit(allocator);
    try glyphs.ensureTotalCapacity(allocator, list.cells.len);

    var fallback_count: usize = 0;
    var replacement_count: usize = 0;

    for (list.cells) |cell| {
        const shaped = shaper.shape(cell);
        if (shaped.fallback) fallback_count += 1;
        if (shaped.replacement) replacement_count += 1;

        const flags = rasterStyleFlags(cell.style);
        glyphs.appendAssumeCapacity(.{
            .row = cell.row,
            .col = cell.col,
            .cell_width = cell.width,
            .codepoint = cell.codepoint,
            .font_id = shaped.font_id,
            .glyph_id = shaped.glyph_id,
            .fallback = shaped.fallback,
            .replacement = shaped.replacement,
            .style = cell.style,
            .cache_key = .{
                .font_id = shaped.font_id,
                .glyph_id = shaped.glyph_id,
                .font_size_px = config.font_size_px,
                .device_scale = config.device_scale,
                // slot 폭 기준 cell 폭: 합성/notdef(glyph_id==0)은 grid advance(셀폭·타일링), 폰트 글리프는 자연폭(자간 무관).
                .cell_width_px = config.slotCellWidthPx(shaped.glyph_id),
                .cell_height_px = config.cell_height_px,
                .cell_width = cell.width, // span — slot 폭 = cell_width_px × span이라 키에 포함(span 충돌 방지)
                .style = flags,
                .color_glyph_kind = shaped.color_glyph_kind,
            },
        });
    }

    const overlays = try allocator.dupe(draw_list.DrawOverlay, list.overlays);
    errdefer allocator.free(overlays);

    return .{
        .size = list.size,
        .cursor = list.cursor,
        .dirty = list.dirty,
        .glyphs = try glyphs.toOwnedSlice(allocator),
        .overlays = overlays,
        .fallback_count = fallback_count,
        .replacement_count = replacement_count,
    };
}

pub fn rasterStyleFlags(style: terminal.Style) RasterStyleFlags {
    return .{
        .bold = style.bold,
        .italic = style.italic,
    };
}

fn glyphIdFor(codepoint: u21) GlyphId {
    return @intCast(codepoint);
}

fn isPrimaryCodepoint(codepoint: u21) bool {
    return codepoint >= 0x20 and codepoint <= 0x7e;
}

fn isFallbackCodepoint(codepoint: u21) bool {
    return codepoint >= 0x80 and !isPrivateUse(codepoint);
}

fn isPrivateUse(codepoint: u21) bool {
    return codepoint >= 0xe000 and codepoint <= 0xf8ff;
}

fn colorGlyphKind(codepoint: u21) ColorGlyphKind {
    if (codepoint >= 0x1f300 and codepoint <= 0x1faff) return .color;
    return .monochrome;
}

test "fake glyph layout maps primary and fallback fonts" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // 이 테스트는 실제 CoreText 없이도 cell -> font/glyph 계약을 먼저 고정한다. ASCII는 primary
    // font, 한글은 fallback font로 간다. (grapheme cluster 본체는 GlyphRun이 아니라 DrawList.grapheme_pool로
    // 흐르며 실제 셰이퍼가 소비한다 — fake 경로는 base codepoint만 본다.)
    core.clearDirty();
    try core.write("A한e\u{0301}");

    var list = try draw_list.buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyphs = try buildGlyphRunList(std.testing.allocator, list, .{}, FakeFontBackend{});
    defer glyphs.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), glyphs.glyphs.len);
    try std.testing.expectEqual(@as(FontId, 1), glyphs.glyphs[0].font_id);
    try std.testing.expect(!glyphs.glyphs[0].fallback);
    try std.testing.expectEqual(@as(u21, '한'), glyphs.glyphs[1].codepoint);
    try std.testing.expectEqual(@as(FontId, 2), glyphs.glyphs[1].font_id);
    try std.testing.expect(glyphs.glyphs[1].fallback);
    try std.testing.expectEqual(@as(u2, 2), glyphs.glyphs[1].cell_width);
    try std.testing.expectEqual(@as(u21, 'e'), glyphs.glyphs[2].codepoint);
    try std.testing.expect(glyphs.overlays.len > 0);
}

test "fake glyph layout records replacement glyphs" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // replacement 경로를 명시적으로 고정한다. 지원하지 않는 글자가 들어왔을 때
    // backend가 조용히 원본 glyph id를 쓰면 나중에 atlas miss 원인을 추적하기 어렵다.
    core.clearDirty();
    try core.write("\u{e000}");

    var list = try draw_list.buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyphs = try buildGlyphRunList(std.testing.allocator, list, .{}, FakeFontBackend{});
    defer glyphs.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), glyphs.replacement_count);
    try std.testing.expect(glyphs.glyphs[0].replacement);
    try std.testing.expectEqual(@as(GlyphId, 0xfffd), glyphs.glyphs[0].glyph_id);
    try std.testing.expectEqual(@as(GlyphId, 0xfffd), glyphs.glyphs[0].cache_key.glyph_id);

    // replacement glyph는 fallback font로 그리므로 fallback에도 포함된다. 즉
    // replacement_count는 fallback_count의 부분집합이다. 이 관계를 고정해 두지 않으면
    // 나중에 두 카운터의 의미가 조용히 어긋나도 테스트가 잡지 못한다.
    try std.testing.expect(glyphs.glyphs[0].fallback);
    try std.testing.expectEqual(@as(usize, 1), glyphs.fallback_count);
}

test "glyph cache key separates style size scale and color glyph kind" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // atlas cache key가 style/size/scale/color glyph 종류를 구분하지 못하면 서로 다른
    // glyph bitmap을 같은 atlas slot으로 재사용하는 버그가 난다.
    core.clearDirty();
    try core.write("A🚀");
    core.screen.cells[0].style = .{ .bold = true, .underline = true };

    var list = try draw_list.buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyphs = try buildGlyphRunList(
        std.testing.allocator,
        list,
        .{ .font_size_px = 16, .device_scale = 2 },
        FakeFontBackend{},
    );
    defer glyphs.deinit(std.testing.allocator);

    try std.testing.expect(glyphs.glyphs[0].cache_key.style.bold);
    // underline은 glyph bitmap을 바꾸지 않는 draw-time 오버레이라 cache key에서 제외한다.
    // (밑줄 유무로 같은 'A'를 atlas에 두 번 굽지 않게 한다.) 대신 렌더러가 오버레이로
    // 그릴 수 있도록 GlyphRun.style에는 그대로 보존한다.
    try std.testing.expect(glyphs.glyphs[0].style.underline);
    try std.testing.expectEqual(@as(u16, 16), glyphs.glyphs[0].cache_key.font_size_px);
    try std.testing.expectEqual(@as(u16, 2), glyphs.glyphs[0].cache_key.device_scale);
    try std.testing.expectEqual(ColorGlyphKind.color, glyphs.glyphs[1].cache_key.color_glyph_kind);
}
