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
};

pub const GlyphCacheKey = struct {
    font_id: FontId,
    glyph_id: GlyphId,
    font_size_px: u16,
    device_scale: u16,
    style: RasterStyleFlags = .{},
    color_glyph_kind: ColorGlyphKind = .monochrome,
};

pub const GlyphRun = struct {
    row: u16,
    col: u16,
    cell_width: u2,
    codepoint: u21,
    combining: ?u21 = null,
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
        if (isPrimaryCodepoint(cell.codepoint)) {
            return .{
                .font_id = self.primary_font_id,
                .glyph_id = glyphIdFor(cell.codepoint),
                .color_glyph_kind = colorGlyphKind(cell.codepoint),
            };
        }

        if (isFallbackCodepoint(cell.codepoint)) {
            return .{
                .font_id = self.fallback_font_id,
                .glyph_id = glyphIdFor(cell.codepoint),
                .fallback = true,
                .color_glyph_kind = colorGlyphKind(cell.codepoint),
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
            .combining = cell.combining,
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

test "fake glyph layout maps primary fallback and combining data" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // 이 테스트는 실제 CoreText 없이도 cell -> font/glyph 계약을 먼저 고정한다.
    // ASCII는 primary font, 한글은 fallback font, combining mark는 base glyph에
    // 붙은 상태로 다음 단계에 전달되어야 한다.
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
    try std.testing.expectEqual(@as(?u21, 0x0301), glyphs.glyphs[2].combining);
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
    core.cells[0].style = .{ .bold = true, .underline = true };

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
