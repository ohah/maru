const std = @import("std");
const draw_list = @import("draw_list.zig");
const glyph_layout = @import("glyph_layout.zig");
const terminal = @import("../terminal.zig");

pub const ShapedGlyphRecord = struct {
    row: u16 = 0,
    col: u16,
    cell_width: u3 = 1,
    codepoint: u21,
    font_id: glyph_layout.FontId,
    glyph_id: glyph_layout.GlyphId,
    fallback: bool = false,
    replacement: bool = false,
    style: terminal.Style = .{},
    color_glyph_kind: glyph_layout.ColorGlyphKind = .monochrome,
    /// Non-terminal proportional UI text can request its role size and bitmap extents without
    /// leaking a platform font handle into renderer records. Zero preserves TextLayoutConfig.
    raster_font_size_milli: u16 = 0,
    raster_width_px: u16 = 0,
    raster_height_px: u16 = 0,
    drawable: bool = true,
};

pub const ShapedGlyphRunList = struct {
    runs: glyph_layout.GlyphRunList,
    color_glyph_count: usize = 0,
    skipped_count: usize = 0,

    pub fn deinit(self: *ShapedGlyphRunList, allocator: std.mem.Allocator) void {
        self.runs.deinit(allocator);
        self.* = undefined;
    }
};

pub const ShapedGlyphSurface = struct {
    size: terminal.Size,
    cursor: terminal.Cursor = .{},
    dirty: ?terminal.DirtyRegion = null,
    overlays: []const draw_list.DrawOverlay = &.{},
};

pub fn buildGlyphRunListFromShapedRecords(
    allocator: std.mem.Allocator,
    records: []const ShapedGlyphRecord,
    config: glyph_layout.TextLayoutConfig,
) !ShapedGlyphRunList {
    // CoreText, future HarfBuzz, 테스트 shaper는 모두 atlas/frame 준비 전에 이
    // renderer 중립 record 형태로 모여야 한다. 그래야 `GlyphRunList`에 native font
    // 타입이 새지 않고, Metal과 future WebGPU backend가 같은 renderer-domain 데이터를
    // 소비할 수 있다.
    const derived = derivedSurfaceFromRecords(records);
    return buildGlyphRunListFromShapedRecordsWithSurface(allocator, records, config, derived);
}

pub fn buildGlyphRunListFromShapedRecordsWithSurface(
    allocator: std.mem.Allocator,
    records: []const ShapedGlyphRecord,
    config: glyph_layout.TextLayoutConfig,
    surface: ShapedGlyphSurface,
) !ShapedGlyphRunList {
    // 제품 shaper 경로에서는 `DrawList`가 이미 surface size, cursor, dirty, overlay를
    // 소유한다. native shaper record만 보고 이 값을 다시 유도하면 trailing blank rows,
    // cursor overlay, underline overlay가 조용히 사라질 수 있으므로 명시적으로 전달받는다.
    var glyphs: std.ArrayList(glyph_layout.GlyphRun) = .empty;
    errdefer glyphs.deinit(allocator);
    try glyphs.ensureTotalCapacity(allocator, records.len);

    var fallback_count: usize = 0;
    var replacement_count: usize = 0;
    var color_glyph_count: usize = 0;
    var skipped_count: usize = 0;

    for (records) |record| {
        // drawable 하나로 판정한다. notdef(폰트 미보유) 일반 글자는 coreTextGlyphRecordFromDrawRecord
        // (#609)에서 이미 drawable=false라 여기서 걸러진다. 반면 box-drawing·block(U+2500~257F·2580~259F)은
        // 폰트 글리프가 없어도(glyph_id==0) rasterizer가 codepoint로 합성하므로 drawable=true다 — 예전의
        // `glyph_id == 0` 스킵이 이 합성 record를 GlyphRunList 진입 직전에 죽여 보더가 안 보였다(스킵 제거).
        if (!record.drawable or record.cell_width == 0) {
            skipped_count += 1;
            continue;
        }

        try validateRecordWithinSurface(record, surface.size);

        if (record.fallback) fallback_count += 1;
        if (record.replacement) replacement_count += 1;
        if (record.color_glyph_kind == .color) color_glyph_count += 1;

        const flags = glyph_layout.rasterStyleFlags(record.style);
        glyphs.appendAssumeCapacity(.{
            .row = record.row,
            .col = record.col,
            .cell_width = record.cell_width,
            .codepoint = record.codepoint,
            .font_id = record.font_id,
            .glyph_id = record.glyph_id,
            .fallback = record.fallback,
            .replacement = record.replacement,
            .style = record.style,
            .cache_key = .{
                .font_id = record.font_id,
                // 합성 glyph(box/block/Powerline)은 네이티브 셰이퍼(coretext_smoke.m)가 폰트 글리프 유무와 무관하게
                // glyph_id=0으로 정규화해 보낸다(폰트가 글리프를 줘도 rasterizer는 codepoint로 합성하니 무의미).
                // 그래서 여기 합성 글자는 항상 glyph_id=0·font_id=0(intern 제외, needsFontIdentity)이다. 그대로 두면
                // 모든 합성 글자가 같은 cache_key로 atlas 한 슬롯에 충돌해 ─│╭╮ 가 전부 같은 모양이 된다. codepoint로
                // 키잉해 코드포인트마다 고유 슬롯을 받게 한다(font_id=0 공간은 합성 전용이라 일반 glyph와 안 겹친다).
                .glyph_id = if (record.glyph_id == 0) @as(glyph_layout.GlyphId, record.codepoint) else record.glyph_id,
                .font_size_px = config.font_size_px,
                .device_scale = config.device_scale,
                // slot 폭 기준 cell 폭: 합성/notdef(record.glyph_id==0)은 grid advance(셀폭·타일링), 폰트 글리프는 자연폭
                // (자간 무관) — 음수 자간이 폰트 글리프 slot을 좁혀 세로 흔들림/찌그러짐을 내던 버그 차단(code-review). 합성
                // 판정은 위 glyph_id 재키잉과 같은 record.glyph_id==0(원본) 기준.
                .cell_width_px = config.slotCellWidthPx(record.glyph_id),
                .cell_height_px = config.cell_height_px,
                .cell_width = record.cell_width, // span — slot 폭 = cell_width_px × span이라 키에 포함(span 충돌 방지)
                .raster_font_size_milli = record.raster_font_size_milli,
                .raster_width_px = record.raster_width_px,
                .raster_height_px = record.raster_height_px,
                .style = flags,
                .color_glyph_kind = record.color_glyph_kind,
            },
        });
    }

    const glyph_slice = try glyphs.toOwnedSlice(allocator);
    errdefer allocator.free(glyph_slice);
    const overlays = try allocator.dupe(draw_list.DrawOverlay, surface.overlays);
    errdefer allocator.free(overlays);

    return .{
        .runs = .{
            .size = surface.size,
            .cursor = surface.cursor,
            .dirty = surface.dirty,
            .glyphs = glyph_slice,
            .overlays = overlays,
            .fallback_count = fallback_count,
            .replacement_count = replacement_count,
        },
        .color_glyph_count = color_glyph_count,
        .skipped_count = skipped_count,
    };
}

fn derivedSurfaceFromRecords(records: []const ShapedGlyphRecord) ShapedGlyphSurface {
    // CoreText smoke 같은 probe 경로는 DrawList가 없으므로 drawable record 위치에서 최소
    // surface metadata를 만든다. 제품 경로는 이 helper를 쓰지 않고 `DrawList` metadata를
    // 직접 넘겨 trailing blank 영역과 overlay를 보존해야 한다.
    var max_row: u16 = 0;
    var max_col: u16 = 0;
    var any_drawable = false;

    for (records) |record| {
        // drawable 단일 판정(위 build 루프와 동일) — 합성 glyph(glyph_id==0)도 drawable이면 surface 범위에 든다.
        if (!record.drawable or record.cell_width == 0) continue;

        any_drawable = true;
        const end_col = std.math.add(u16, record.col, @as(u16, record.cell_width)) catch
            std.math.maxInt(u16);
        max_row = @max(max_row, record.row);
        max_col = @max(max_col, end_col);
    }

    const rows: u16 = if (any_drawable) std.math.add(u16, max_row, 1) catch
        std.math.maxInt(u16) else 1;

    return .{
        .size = .{
            .cols = @max(max_col, 1),
            .rows = rows,
        },
        .dirty = if (any_drawable) .{ .start_row = 0, .end_row = rows - 1 } else null,
    };
}

fn validateRecordWithinSurface(record: ShapedGlyphRecord, size: terminal.Size) !void {
    if (size.cols == 0 or size.rows == 0) return error.ShapedRecordOutsideSurface;
    if (record.row >= size.rows or record.col >= size.cols) return error.ShapedRecordOutsideSurface;
    const end_col = std.math.add(u16, record.col, @as(u16, record.cell_width)) catch
        return error.ShapedRecordOutsideSurface;
    if (end_col > size.cols) return error.ShapedRecordOutsideSurface;
}

test "shaped records build backend neutral glyph runs" {
    // 이 테스트는 native shaper가 준 glyph id/font id가 CoreText 타입 없이도 renderer
    // 계약으로 들어갈 수 있는지 고정한다. 이 경계가 있어야 macOS smoke와 future
    // 제품 shaper가 `GlyphFrame` 준비 로직을 복제하지 않는다.
    const records = [_]ShapedGlyphRecord{
        .{ .col = 0, .cell_width = 1, .codepoint = 'A', .font_id = 1, .glyph_id = 10 },
        .{ .col = 1, .cell_width = 2, .codepoint = '한', .font_id = 2, .glyph_id = 20, .fallback = true },
        .{ .col = 3, .cell_width = 2, .codepoint = 0x1f34e, .font_id = 3, .glyph_id = 30, .fallback = true, .color_glyph_kind = .color },
    };

    var result = try buildGlyphRunListFromShapedRecords(std.testing.allocator, &records, .{ .font_size_px = 17, .device_scale = 2 });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.runs.glyphs.len);
    try std.testing.expectEqual(@as(u16, 5), result.runs.size.cols);
    try std.testing.expectEqual(@as(usize, 2), result.runs.fallback_count);
    try std.testing.expectEqual(@as(usize, 1), result.color_glyph_count);
    try std.testing.expectEqual(@as(u21, 'A'), result.runs.glyphs[0].codepoint);
    try std.testing.expectEqual(@as(u3, 2), result.runs.glyphs[1].cell_width);
    try std.testing.expectEqual(@as(glyph_layout.ColorGlyphKind, .color), result.runs.glyphs[2].cache_key.color_glyph_kind);
    try std.testing.expectEqual(@as(u16, 17), result.runs.glyphs[0].cache_key.font_size_px);
    try std.testing.expectEqual(@as(u16, 2), result.runs.glyphs[0].cache_key.device_scale);
}

test "shaped records preserve product surface metadata when provided" {
    // 실제 제품 shaper는 `DrawList`의 surface metadata를 그대로 보존해야 한다. record만
    // 보고 size/dirty를 재계산하면 빈 trailing row, cursor 위치, underline overlay가
    // 사라져 resize와 overlay redraw가 실제 앱에서 틀어진다.
    const overlays = [_]draw_list.DrawOverlay{
        .{ .cursor = .{ .row = 5, .col = 6 } },
        .{ .line = .{ .row = 4, .col = 2, .width = 1, .kind = .underline } },
    };
    const records = [_]ShapedGlyphRecord{
        .{ .row = 4, .col = 2, .codepoint = 'A', .font_id = 1, .glyph_id = 10 },
    };

    var result = try buildGlyphRunListFromShapedRecordsWithSurface(
        std.testing.allocator,
        &records,
        .{},
        .{
            .size = .{ .cols = 80, .rows = 24 },
            .cursor = .{ .row = 5, .col = 6, .visible = true },
            .dirty = .{ .start_row = 4, .end_row = 5 },
            .overlays = &overlays,
        },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(terminal.Size{ .cols = 80, .rows = 24 }, result.runs.size);
    try std.testing.expectEqual(terminal.Cursor{ .row = 5, .col = 6, .visible = true }, result.runs.cursor);
    try std.testing.expectEqual(terminal.DirtyRegion{ .start_row = 4, .end_row = 5 }, result.runs.dirty.?);
    try std.testing.expectEqual(@as(usize, 2), result.runs.overlays.len);
    try std.testing.expectEqual(@as(u16, 4), result.runs.glyphs[0].row);
}

test "shaped records reject drawable glyphs outside the provided surface" {
    // native shaper가 surface 밖 glyph를 돌려주면 renderer가 조용히 더 큰 surface를 만들면
    // 안 된다. 그런 상태는 size 계산 버그이므로 제품 경계에서 바로 실패시킨다.
    const records = [_]ShapedGlyphRecord{
        .{ .row = 0, .col = 9, .cell_width = 2, .codepoint = '한', .font_id = 1, .glyph_id = 10 },
    };

    try std.testing.expectError(
        error.ShapedRecordOutsideSurface,
        buildGlyphRunListFromShapedRecordsWithSurface(
            std.testing.allocator,
            &records,
            .{},
            .{ .size = .{ .cols = 10, .rows = 1 } },
        ),
    );
}

test "shaped records filter non drawable records before atlas preparation" {
    // space나 .notdef 같은 record를 atlas 후보로 보내면 upload 수가 부풀고, 실제 화면이
    // 비었는지 glyph가 없는지 진단이 흐려진다. 그래서 필터링도 renderer 계약으로 둔다.
    // 일반 notdef('?')은 합성 대상이 아니라 coreTextGlyphRecordFromDrawRecord(#609)에서 drawable=false로
    // 표시된다. 필터는 그 drawable을 본다(glyph_id==0 자체로 거르지 않음 — 합성 glyph가 glyph_id=0이라서).
    const records = [_]ShapedGlyphRecord{
        .{ .col = 0, .cell_width = 1, .codepoint = ' ', .font_id = 1, .glyph_id = 5, .drawable = false },
        .{ .col = 1, .cell_width = 1, .codepoint = '?', .font_id = 1, .glyph_id = 0, .drawable = false },
        .{ .col = 2, .cell_width = 1, .codepoint = 'A', .font_id = 1, .glyph_id = 10 },
    };

    var result = try buildGlyphRunListFromShapedRecords(std.testing.allocator, &records, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.runs.glyphs.len);
    try std.testing.expectEqual(@as(usize, 2), result.skipped_count);
    try std.testing.expectEqual(@as(u16, 3), result.runs.size.cols);
    try std.testing.expect(result.runs.dirty != null);
}

test "shaped records keep synthesized box/block glyphs (glyph_id==0) and key cache by codepoint" {
    // 보더가 안 보이던 버그: 폰트가 box-drawing/block 글리프를 안 가지면 glyph_id==0인데, 예전 필터가
    // glyph_id==0을 무조건 스킵해 합성 record가 GlyphRunList 진입 전에 죽었다. 합성 glyph는 drawable=true로
    // 들어오므로(#609) 통과해야 하고, font_id=0·glyph_id=0을 공유하니 cache_key를 codepoint로 키잉해 충돌을 막아야 한다.
    const records = [_]ShapedGlyphRecord{
        .{ .col = 0, .cell_width = 1, .codepoint = 0x2500, .font_id = 0, .glyph_id = 0, .drawable = true }, // ─
        .{ .col = 1, .cell_width = 1, .codepoint = 0x2502, .font_id = 0, .glyph_id = 0, .drawable = true }, // │
        .{ .col = 2, .cell_width = 1, .codepoint = 0x2588, .font_id = 0, .glyph_id = 0, .drawable = true }, // █ block
    };

    var result = try buildGlyphRunListFromShapedRecords(std.testing.allocator, &records, .{});
    defer result.deinit(std.testing.allocator);

    // 셋 다 살아남아야 한다(예전엔 0개 — 전부 스킵 → 보더 안 보임).
    try std.testing.expectEqual(@as(usize, 3), result.runs.glyphs.len);
    try std.testing.expectEqual(@as(usize, 0), result.skipped_count);

    // run.glyph_id는 0 그대로(rasterizer가 codepoint로 합성 분기), cache_key.glyph_id는 codepoint(고유 슬롯).
    try std.testing.expectEqual(@as(glyph_layout.GlyphId, 0), result.runs.glyphs[0].glyph_id);
    try std.testing.expectEqual(@as(glyph_layout.GlyphId, 0x2500), result.runs.glyphs[0].cache_key.glyph_id);
    try std.testing.expectEqual(@as(glyph_layout.GlyphId, 0x2502), result.runs.glyphs[1].cache_key.glyph_id);
    try std.testing.expectEqual(@as(glyph_layout.GlyphId, 0x2588), result.runs.glyphs[2].cache_key.glyph_id);

    // 서로 다른 cache_key여야 atlas에서 안 겹친다(─ ≠ │ ≠ █).
    try std.testing.expect(!std.meta.eql(result.runs.glyphs[0].cache_key, result.runs.glyphs[1].cache_key));
    try std.testing.expect(!std.meta.eql(result.runs.glyphs[1].cache_key, result.runs.glyphs[2].cache_key));
}

test "shaped records preserve raster style boundary" {
    // underline은 glyph bitmap이 아니라 overlay라 cache key에 들어가면 안 된다. 반대로
    // bold/italic은 bitmap을 바꾸므로 native shaper 경로에서도 key에 남아야 한다.
    const records = [_]ShapedGlyphRecord{
        .{
            .col = 0,
            .codepoint = 'A',
            .font_id = 1,
            .glyph_id = 10,
            .style = .{ .bold = true, .italic = true, .underline = true },
        },
    };

    var result = try buildGlyphRunListFromShapedRecords(std.testing.allocator, &records, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.runs.glyphs[0].style.underline);
    try std.testing.expect(result.runs.glyphs[0].cache_key.style.bold);
    try std.testing.expect(result.runs.glyphs[0].cache_key.style.italic);
}

test "shaped records derive rows and dirty span from record rows" {
    // 이 adapter는 CoreText probe(한 줄)뿐 아니라 future 제품 shaper(여러 줄 grid)도
    // 소비한다. drawable record의 최대 row에서 size.rows와 dirty span을 끌어내는 경로를
    // 고정해, 한 줄만 쓰는 현재 caller가 다중 행 회계를 깨지 않게 한다.
    const records = [_]ShapedGlyphRecord{
        .{ .row = 0, .col = 0, .codepoint = 'A', .font_id = 1, .glyph_id = 10 },
        .{ .row = 2, .col = 1, .codepoint = 'B', .font_id = 1, .glyph_id = 11 },
    };

    var result = try buildGlyphRunListFromShapedRecords(std.testing.allocator, &records, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 3), result.runs.size.rows);
    try std.testing.expect(result.runs.dirty != null);
    try std.testing.expectEqual(@as(u16, 0), result.runs.dirty.?.start_row);
    try std.testing.expectEqual(@as(u16, 2), result.runs.dirty.?.end_row);
}
