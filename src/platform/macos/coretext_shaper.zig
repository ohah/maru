const std = @import("std");
const maru = @import("maru");
const app_config = maru.config;
const coretext_font = @import("coretext_font.zig");
const coretext_probe = @import("coretext_probe.zig");
const renderer = maru.renderer;
const terminal = maru.terminal;

/// NativeDrawCell.style_flags 비트 — bold cell이면 셰이퍼가 bold 폰트 face를 골라 bold variant의
/// glyph_id/PostScript name을 만든다(rasterizer가 그 이름으로 다시 그려 실제 굵은 글리프가 나온다).
pub const draw_cell_bold_bit: u16 = 1 << 0;
/// italic(SGR 3) cell — 셰이퍼가 italic face(font.family-italic 또는 주 family italic variant)로 그린다(F2-3).
/// bold와 같이 켜지면 bold-italic face. native MaruDrawCellItalicBit와 동일 비트.
pub const draw_cell_italic_bit: u16 = 1 << 1;

pub const NativeDrawCell = extern struct {
    row: u16,
    col: u16,
    width: u16,
    // 스타일 플래그(비트필드). bit0(draw_cell_bold_bit)=bold. native MaruCoreTextDrawCell.style_flags와 동일.
    style_flags: u16 = 0,
    codepoint: u32,
    // grapheme cluster 본체(base 뒤 extra 코드포인트 — 악센트·VS16·NFD 한글 V/T·키캡·ZWJ)를 shape
    // 호출의 grapheme_pool에서 가리킨다 — [grapheme_offset, grapheme_offset+grapheme_count). count>0이면
    // base 뒤에 풀의 코드포인트를 모두 붙여 cluster 전체를 셰이핑한다(무손실). 0이면 extra 없음.
    grapheme_offset: u32 = 0,
    grapheme_count: u16 = 0,
    reserved: u16 = 0, // 20바이트 정렬 패딩(ObjC MaruCoreTextDrawCell와 동형 레이아웃)
};

pub const NativeDrawGlyphRecord = extern struct {
    cell_index: u32,
    row: u16,
    col: u16,
    cell_width: u16,
    reserved: u16 = 0,
    codepoint: u32,
    glyph_id: u32,
    drawable: u32,
    fallback: u32,
    color_glyph_kind: u32,
    font_name: [coretext_probe.font_name_capacity]u8,
};

pub const NativeDrawListShapeResult = extern struct {
    status: c_int,
    primary_font_found: u32,
    requested_font_matched: u32,
    shaped_cell_count: u32,
    glyph_record_count: u32,
    glyph_record_overflow: u32,
    missing_glyph_count: u32,
    fallback_run_count: u32,
};

pub const ShapeDrawListFn = *const fn (
    requested_font_family: [*]const u8,
    requested_font_family_len: usize,
    requested_font_size: f64,
    // 폴백 폰트 CSV(쉼표 구분, 빈 len 0=폴백 없음). ObjC가 split·trim해 주 폰트에 kCTFontCascadeListAttribute로 박는다(F1-2).
    fallback_families: [*]const u8,
    fallback_families_len: usize,
    // bold/italic 글자용 별도 폰트 패밀리(빈 len 0=주 family variant). ObjC가 bold/italic face를 이 패밀리로 만든다(F2-3).
    bold_family: [*]const u8,
    bold_family_len: usize,
    italic_family: [*]const u8,
    italic_family_len: usize,
    // 합자(liga/clig/calt) 적용 여부 — 0이면 ObjC가 셋을 모두 꺼 글자 그대로 셰이핑한다(config font.ligatures).
    ligatures_enabled: u32,
    cells: [*]const NativeDrawCell,
    cell_count: usize,
    // grapheme cluster 본체 풀(base 제외한 extra 코드포인트). NativeDrawCell.grapheme_offset/count가 가리킨다.
    grapheme_pool: [*]const u32,
    grapheme_pool_len: usize,
    result: *NativeDrawListShapeResult,
    glyph_records: [*]NativeDrawGlyphRecord,
    glyph_record_capacity: usize,
) callconv(.c) void;

pub const CoreTextDrawListShaper = struct {
    pub const name = "coretext_draw_list";

    appearance: app_config.ResolvedAppearance,
    shape_draw_list: ShapeDrawListFn,
    // backing(Retina) scale. glyph cache key/atlas slot 크기가 font_size_px × device_scale라,
    // 2면 slot이 2배가 되어 Retina에서 또렷하게 그릴 수 있다.
    device_scale: u16 = 1,
    // 실제 폰트 메트릭에서 온 cell 픽셀 크기(device px). cell_width_px = grid advance(자간 반영, 합성 글리프 slot·배경),
    // glyph_cell_width_px = 폰트 글리프 자연폭(자간 무관, 폰트 글리프 slot). 0이면 메트릭이 없어 atlas가 정사각/폴백한다.
    // app session이 CoreText에서 뽑아 넘긴다(refreshCellMetrics·applyFontSpacing 단일 출처).
    cell_width_px: u16 = 0,
    glyph_cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,

    fn layoutConfig(self: CoreTextDrawListShaper) renderer.TextLayoutConfig {
        var config = renderer.textConfigFromFontSize(self.appearance.font.size, self.device_scale);
        config.cell_width_px = self.cell_width_px;
        config.glyph_cell_width_px = self.glyph_cell_width_px;
        config.cell_height_px = self.cell_height_px;
        return config;
    }

    pub fn shape(
        self: CoreTextDrawListShaper,
        allocator: std.mem.Allocator,
        list: renderer.DrawList,
        font_registry: *renderer.FontIdentityRegistry,
    ) !renderer.ShapedGlyphRunList {
        // 제품 경로에서는 DrawList가 size/cursor/dirty/overlay의 단일 출처다. CoreText가
        // glyph id/font face를 고른 뒤에도 이 surface metadata를 그대로 넘겨야 resize,
        // cursor, underline overlay 디버깅 신호가 유지된다.
        const surface = renderer.ShapedGlyphSurface{
            .size = list.size,
            .cursor = list.cursor,
            .dirty = list.dirty,
            .overlays = list.overlays,
        };

        if (list.cells.len == 0) {
            return renderer.buildGlyphRunListFromShapedRecordsWithSurface(
                allocator,
                &.{},
                self.layoutConfig(),
                surface,
            );
        }

        var native_cells: std.ArrayList(NativeDrawCell) = .empty;
        defer native_cells.deinit(allocator);
        try native_cells.ensureTotalCapacity(allocator, list.cells.len);
        for (list.cells) |cell| {
            native_cells.appendAssumeCapacity(nativeDrawCellFromDrawCell(cell));
        }

        const record_capacity = try std.math.mul(usize, list.cells.len, 2);
        var native_records = try allocator.alloc(NativeDrawGlyphRecord, record_capacity);
        defer allocator.free(native_records);
        @memset(native_records, emptyNativeDrawGlyphRecord());

        var native: NativeDrawListShapeResult = .{
            .status = -1,
            .primary_font_found = 0,
            .requested_font_matched = 0,
            .shaped_cell_count = 0,
            .glyph_record_count = 0,
            .glyph_record_overflow = 0,
            .missing_glyph_count = 0,
            .fallback_run_count = 0,
        };
        self.shape_draw_list(
            self.appearance.font.family.ptr,
            self.appearance.font.family.len,
            @floatCast(self.appearance.font.size),
            self.appearance.font.fallback.ptr,
            self.appearance.font.fallback.len,
            self.appearance.font.family_bold.ptr,
            self.appearance.font.family_bold.len,
            self.appearance.font.family_italic.ptr,
            self.appearance.font.family_italic.len,
            if (self.appearance.font.ligatures) 1 else 0,
            native_cells.items.ptr,
            native_cells.items.len,
            list.grapheme_pool.ptr,
            list.grapheme_pool.len,
            &native,
            native_records.ptr,
            native_records.len,
        );
        if (native.status != 0 or native.glyph_record_overflow != 0) {
            return error.CoreTextDrawListShapeFailed;
        }

        const record_count = @min(@as(usize, @intCast(native.glyph_record_count)), native_records.len);
        var coretext_records: std.ArrayList(coretext_font.CoreTextGlyphRecord) = .empty;
        defer coretext_records.deinit(allocator);
        try coretext_records.ensureTotalCapacity(allocator, record_count);
        for (native_records[0..record_count]) |*record| {
            coretext_records.appendAssumeCapacity(try coreTextGlyphRecordFromDrawRecord(record, list.cells));
        }

        return buildGlyphRunListFromCoreTextGlyphs(
            allocator,
            coretext_records.items,
            self.layoutConfig(),
            surface,
            font_registry,
        );
    }
};

fn nativeDrawCellFromDrawCell(cell: renderer.DrawCell) NativeDrawCell {
    return .{
        .row = cell.row,
        .col = cell.col,
        .width = cell.width,
        .style_flags = (if (cell.style.bold) draw_cell_bold_bit else 0) | (if (cell.style.italic) draw_cell_italic_bit else 0),
        .codepoint = cell.codepoint,
        .grapheme_offset = cell.grapheme_offset,
        .grapheme_count = cell.grapheme_count,
    };
}

fn emptyNativeDrawGlyphRecord() NativeDrawGlyphRecord {
    return .{
        .cell_index = 0,
        .row = 0,
        .col = 0,
        .cell_width = 0,
        .codepoint = 0,
        .glyph_id = 0,
        .drawable = 0,
        .fallback = 0,
        .color_glyph_kind = 0,
        .font_name = [_]u8{0} ** coretext_probe.font_name_capacity,
    };
}

fn coreTextGlyphRecordFromDrawRecord(
    record: *const NativeDrawGlyphRecord,
    cells: []const renderer.DrawCell,
) !coretext_font.CoreTextGlyphRecord {
    if (record.cell_index >= cells.len) return error.CoreTextDrawListRecordOutsideInput;
    if (record.cell_width > 2) return error.CoreTextDrawListInvalidCellWidth;
    if (record.codepoint > std.math.maxInt(u21)) return error.CoreTextDrawListInvalidCodepoint;

    const source_cell = cells[@intCast(record.cell_index)];
    return .{
        .row = record.row,
        .col = record.col,
        .cell_width = @intCast(record.cell_width),
        .codepoint = @intCast(record.codepoint),
        .glyph_id = record.glyph_id,
        .font_name = coretext_probe.cStringField(&record.font_name),
        .fallback = record.fallback != 0,
        .style = source_cell.style,
        .color_glyph_kind = if (record.color_glyph_kind != 0) .color else .monochrome,
        // 폰트가 글리프를 주면(glyph_id!=0) drawable. **단 합성 대상(box·block·Powerline·Braille·Legacy
        // Computing 모자이크/wedge/삼각형/대각선 등)은 rasterizer가 코드포인트로 직접 합성하므로 폰트 글리프가
        // 없어도(glyph_id==0) drawable이어야 한다** — 안 그러면 폰트에 그 글리프가 없거나 CoreText가 notdef를 줄
        // 때 셀이 스킵돼 합성에 도달조차 못 한다(보더가 안 보이던 원인). 합성 여부는 renderer의 단일 출처
        // `isSynthesizedCodepoint`로 판정한다(C 게이트 maru_is_synthesized_glyph가 같은 집합을 미러).
        .drawable = record.drawable != 0 and
            (record.glyph_id != 0 or renderer.isSynthesizedCodepoint(record.codepoint)),
    };
}

pub fn buildGlyphRunListFromCoreTextGlyphs(
    allocator: std.mem.Allocator,
    records: []const coretext_font.CoreTextGlyphRecord,
    config: renderer.TextLayoutConfig,
    surface: renderer.ShapedGlyphSurface,
    font_registry: *renderer.FontIdentityRegistry,
) !renderer.ShapedGlyphRunList {
    // 제품 CoreText shaper는 per-cell fake backend처럼 `shape(cell)` 하나로 끝나지 않는다.
    // CoreText가 이미 line/run 단위로 고른 glyph id와 font face를 renderer 중립 record로
    // 바꾼 뒤, 기존 `ShapedGlyphRecord -> GlyphRunList` 경로를 재사용해야 atlas/frame 준비
    // 로직이 smoke와 제품 backend에서 갈라지지 않는다.
    var shaped_records: std.ArrayList(renderer.ShapedGlyphRecord) = .empty;
    defer shaped_records.deinit(allocator);
    try shaped_records.ensureTotalCapacity(allocator, records.len);

    for (records) |record| {
        shaped_records.appendAssumeCapacity(try coretext_font.shapedRecordFromCoreTextGlyph(
            record,
            font_registry,
        ));
    }

    return renderer.buildGlyphRunListFromShapedRecordsWithSurface(
        allocator,
        shaped_records.items,
        config,
        surface,
    );
}

pub fn deriveProbeSurfaceFromCoreTextGlyphs(
    records: []const coretext_font.CoreTextGlyphRecord,
) renderer.ShapedGlyphSurface {
    // 제품 경로는 실제 DrawList의 surface metadata를 넘겨야 한다. 이 helper는 CoreText
    // smoke처럼 아직 TerminalCore DrawList가 없는 probe가 최소 surface를 만들 때만 쓴다.
    // 공백 record도 probe DrawList에는 남기므로, drawable glyph뿐 아니라 모든 cell 폭을
    // surface bounds에 포함한다.
    var max_row: u16 = 0;
    var max_col: u16 = 0;
    var any_cell = false;

    for (records) |record| {
        if (record.cell_width == 0) continue;

        any_cell = true;
        const end_col = std.math.add(u16, record.col, @as(u16, record.cell_width)) catch
            std.math.maxInt(u16);
        max_row = @max(max_row, record.row);
        max_col = @max(max_col, end_col);
    }

    const rows: u16 = if (any_cell) std.math.add(u16, max_row, 1) catch
        std.math.maxInt(u16) else 1;

    return .{
        .size = .{
            .cols = @max(max_col, 1),
            .rows = rows,
        },
        .dirty = if (any_cell) .{ .start_row = 0, .end_row = rows - 1 } else null,
    };
}

pub fn buildProbeDrawListFromCoreTextGlyphs(
    allocator: std.mem.Allocator,
    records: []const coretext_font.CoreTextGlyphRecord,
    surface: renderer.ShapedGlyphSurface,
) !renderer.DrawList {
    // smoke도 제품 RendererState의 ownership 계약을 타야 한다. 그래서 shaped record와
    // 같은 surface metadata를 가진 최소 DrawList를 만든다. 이 DrawList는 제품 UI 입력이
    // 아니라 "CoreText glyph record가 RenderFrame까지 이동 가능한가"를 검증하기 위한
    // probe artifact다.
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    try cells.ensureTotalCapacity(allocator, records.len);

    for (records) |record| {
        if (record.cell_width == 0) continue;
        try ensureRecordFitsSurface(record, surface.size);
        cells.appendAssumeCapacity(.{
            .row = record.row,
            .col = record.col,
            .codepoint = record.codepoint,
            .width = record.cell_width,
            .style = record.style,
        });
    }

    const overlays = try allocator.dupe(renderer.DrawOverlay, surface.overlays);
    errdefer allocator.free(overlays);

    return .{
        .size = surface.size,
        .cursor = surface.cursor,
        .dirty = surface.dirty,
        .cells = try cells.toOwnedSlice(allocator),
        .overlays = overlays,
    };
}

fn ensureRecordFitsSurface(
    record: coretext_font.CoreTextGlyphRecord,
    size: terminal.Size,
) !void {
    if (size.cols == 0 or size.rows == 0) return error.CoreTextRecordOutsideSurface;
    if (record.row >= size.rows or record.col >= size.cols) return error.CoreTextRecordOutsideSurface;
    const end_col = std.math.add(u16, record.col, @as(u16, record.cell_width)) catch
        return error.CoreTextRecordOutsideSurface;
    if (end_col > size.cols) return error.CoreTextRecordOutsideSurface;
}

test "shaper: box-drawing·block은 glyph_id==0(폰트 미보유)이어도 drawable(합성 대상)" {
    var cells = [_]renderer.DrawCell{.{ .row = 0, .col = 0, .codepoint = 0x2500, .width = 1 }};

    // ─(U+2500): 폰트가 글리프를 못 줘도(glyph_id=0) drawable이어야 rasterizer 합성에 도달한다(보더 안 보이던 버그).
    var box = emptyNativeDrawGlyphRecord();
    box.cell_index = 0;
    box.cell_width = 1;
    box.codepoint = 0x2500;
    box.glyph_id = 0; // notdef
    box.drawable = 1;
    try std.testing.expect((try coreTextGlyphRecordFromDrawRecord(&box, &cells)).drawable);

    // █(U+2588) block도 동일.
    cells[0].codepoint = 0x2588;
    var blk = emptyNativeDrawGlyphRecord();
    blk.cell_index = 0;
    blk.cell_width = 1;
    blk.codepoint = 0x2588;
    blk.glyph_id = 0;
    blk.drawable = 1;
    try std.testing.expect((try coreTextGlyphRecordFromDrawRecord(&blk, &cells)).drawable);

    // 대조: 일반 글자 'A'가 notdef(glyph_id=0)면 안 그린다(합성 대상 아님 — 기존 동작 보존).
    cells[0].codepoint = 'A';
    var a = emptyNativeDrawGlyphRecord();
    a.cell_index = 0;
    a.cell_width = 1;
    a.codepoint = 'A';
    a.glyph_id = 0;
    a.drawable = 1;
    try std.testing.expect(!(try coreTextGlyphRecordFromDrawRecord(&a, &cells)).drawable);
}

test "CoreText shaper preserves explicit product surface metadata" {
    // 제품 shaper는 DrawList가 가진 size/cursor/dirty/overlay를 record 위치에서 다시
    // 추론하면 안 된다. 빈 trailing 영역과 cursor/underline overlay가 사라지면 resize와
    // redraw 디버깅이 매우 어려워지기 때문에, surface metadata를 그대로 통과시킨다.
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const overlays = [_]renderer.DrawOverlay{
        .{ .cursor = .{ .row = 5, .col = 6 } },
        .{ .line = .{ .row = 4, .col = 2, .width = 1, .kind = .underline } },
    };
    const records = [_]coretext_font.CoreTextGlyphRecord{
        .{
            .row = 4,
            .col = 2,
            .codepoint = 'A',
            .glyph_id = 10,
            .font_name = "Menlo-Regular",
            .drawable = true,
        },
    };

    var shaped = try buildGlyphRunListFromCoreTextGlyphs(
        std.testing.allocator,
        &records,
        .{},
        .{
            .size = .{ .cols = 80, .rows = 24 },
            .cursor = .{ .row = 5, .col = 6, .visible = true },
            .dirty = .{ .start_row = 4, .end_row = 5 },
            .overlays = &overlays,
        },
        &registry,
    );
    defer shaped.deinit(std.testing.allocator);

    try std.testing.expectEqual(terminal.Size{ .cols = 80, .rows = 24 }, shaped.runs.size);
    try std.testing.expectEqual(terminal.Cursor{ .row = 5, .col = 6, .visible = true }, shaped.runs.cursor);
    try std.testing.expectEqual(terminal.DirtyRegion{ .start_row = 4, .end_row = 5 }, shaped.runs.dirty.?);
    try std.testing.expectEqual(@as(usize, 2), shaped.runs.overlays.len);
    try std.testing.expectEqual(@as(usize, 1), shaped.runs.glyphs.len);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
}

test "CoreText shaper keeps non drawable records in probe bounds but out of glyph runs" {
    // CoreText는 space도 glyph run record로 줄 수 있다. space를 atlas glyph로 만들면
    // rasterizer 진단이 부풀지만, probe DrawList bounds에서는 빠뜨리면 col이 surface 밖으로
    // 새는 거짓 artifact가 생긴다. 그래서 surface/draw-list와 glyph-run 필터를 분리한다.
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const records = [_]coretext_font.CoreTextGlyphRecord{
        .{
            .col = 0,
            .codepoint = 'A',
            .glyph_id = 10,
            .font_name = "Menlo-Regular",
            .drawable = true,
        },
        .{
            .col = 4,
            .codepoint = ' ',
            .glyph_id = 5,
            .font_name = "SpaceOnlyFallback-Regular",
            .drawable = false,
        },
    };

    const surface = deriveProbeSurfaceFromCoreTextGlyphs(&records);
    var shaped = try buildGlyphRunListFromCoreTextGlyphs(
        std.testing.allocator,
        &records,
        .{},
        surface,
        &registry,
    );
    defer shaped.deinit(std.testing.allocator);
    var draw_list = try buildProbeDrawListFromCoreTextGlyphs(std.testing.allocator, &records, surface);
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 5), surface.size.cols);
    try std.testing.expectEqual(@as(usize, 1), shaped.runs.glyphs.len);
    try std.testing.expectEqual(@as(usize, 1), shaped.skipped_count);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectEqual(@as(usize, 2), draw_list.cells.len);
    try std.testing.expectEqual(@as(u21, ' '), draw_list.cells[1].codepoint);
}

test "CoreText shaper rejects drawable glyphs outside explicit surface" {
    // 제품 surface가 이미 정해져 있는데 glyph가 그 밖으로 나가면 renderer가 조용히 더 큰
    // surface를 만들면 안 된다. 그 상태는 shaper 위치 계산 버그라서 즉시 실패해야 한다.
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const records = [_]coretext_font.CoreTextGlyphRecord{
        .{
            .col = 9,
            .cell_width = 2,
            .codepoint = '한',
            .glyph_id = 10,
            .font_name = "AppleSDGothicNeo-Regular",
            .drawable = true,
        },
    };

    try std.testing.expectError(
        error.ShapedRecordOutsideSurface,
        buildGlyphRunListFromCoreTextGlyphs(
            std.testing.allocator,
            &records,
            .{},
            .{ .size = .{ .cols = 10, .rows = 1 } },
            &registry,
        ),
    );
}

fn writeTestFontName(record: *NativeDrawGlyphRecord, name: []const u8) void {
    const len = @min(name.len, record.font_name.len - 1);
    @memcpy(record.font_name[0..len], name[0..len]);
    record.font_name[len] = 0;
}

fn fakeShapeDrawList(
    _: [*]const u8,
    _: usize,
    _: f64,
    _: [*]const u8, // fallback CSV ptr
    _: usize, // fallback CSV len
    _: [*]const u8, // bold family ptr (F2-3)
    _: usize, // bold family len
    _: [*]const u8, // italic family ptr (F2-3)
    _: usize, // italic family len
    _: u32, // ligatures_enabled(config font.ligatures) — fake shaper는 feature를 안 쓴다
    cells_ptr: [*]const NativeDrawCell,
    cell_count: usize,
    _: [*]const u32, // grapheme_pool ptr (fake shaper는 풀 미사용 — codepoint 기반 색판정)
    _: usize, // grapheme_pool_len
    result: *NativeDrawListShapeResult,
    records_ptr: [*]NativeDrawGlyphRecord,
    record_capacity: usize,
) callconv(.c) void {
    const cells = cells_ptr[0..cell_count];
    var record_count: usize = 0;
    result.* = .{
        .status = 0,
        .primary_font_found = 1,
        .requested_font_matched = 1,
        .shaped_cell_count = 0,
        .glyph_record_count = 0,
        .glyph_record_overflow = 0,
        .missing_glyph_count = 0,
        .fallback_run_count = 0,
    };

    for (cells, 0..) |cell, index| {
        if (cell.codepoint == 0 or cell.codepoint == ' ') continue;
        if (record_count >= record_capacity) {
            result.glyph_record_overflow = 1;
            result.status = 7;
            return;
        }

        const fallback = cell.codepoint > 0x7f;
        var record = emptyNativeDrawGlyphRecord();
        record.cell_index = @intCast(index);
        record.row = cell.row;
        record.col = cell.col;
        record.cell_width = cell.width;
        record.codepoint = cell.codepoint;
        record.glyph_id = cell.codepoint + 100;
        record.drawable = 1;
        record.fallback = if (fallback) 1 else 0;
        record.color_glyph_kind = if (cell.codepoint >= 0x1f300) 1 else 0;
        writeTestFontName(
            &record,
            if (fallback) "AppleSDGothicNeo-Regular" else "Menlo-Regular",
        );
        records_ptr[record_count] = record;
        record_count += 1;
        result.shaped_cell_count += 1;
        if (fallback) result.fallback_run_count += 1;
    }

    result.glyph_record_count = @intCast(record_count);
}

fn failingShapeDrawList(
    _: [*]const u8,
    _: usize,
    _: f64,
    _: [*]const u8, // fallback CSV ptr
    _: usize, // fallback CSV len
    _: [*]const u8, // bold family ptr (F2-3)
    _: usize, // bold family len
    _: [*]const u8, // italic family ptr (F2-3)
    _: usize, // italic family len
    _: u32, // ligatures_enabled(config font.ligatures) — fake shaper는 feature를 안 쓴다
    _: [*]const NativeDrawCell,
    _: usize,
    _: [*]const u32, // grapheme_pool ptr
    _: usize, // grapheme_pool_len
    result: *NativeDrawListShapeResult,
    _: [*]NativeDrawGlyphRecord,
    _: usize,
) callconv(.c) void {
    result.* = .{
        .status = 7,
        .primary_font_found = 1,
        .requested_font_matched = 1,
        .shaped_cell_count = 0,
        .glyph_record_count = 0,
        .glyph_record_overflow = 1,
        .missing_glyph_count = 0,
        .fallback_run_count = 0,
    };
}

fn outOfRangeRecordShapeDrawList(
    _: [*]const u8,
    _: usize,
    _: f64,
    _: [*]const u8, // fallback CSV ptr
    _: usize, // fallback CSV len
    _: [*]const u8, // bold family ptr (F2-3)
    _: usize, // bold family len
    _: [*]const u8, // italic family ptr (F2-3)
    _: usize, // italic family len
    _: u32, // ligatures_enabled(config font.ligatures) — fake shaper는 feature를 안 쓴다
    cells_ptr: [*]const NativeDrawCell,
    cell_count: usize,
    _: [*]const u32, // grapheme_pool ptr
    _: usize, // grapheme_pool_len
    result: *NativeDrawListShapeResult,
    records_ptr: [*]NativeDrawGlyphRecord,
    _: usize,
) callconv(.c) void {
    const cells = cells_ptr[0..cell_count];
    var record = emptyNativeDrawGlyphRecord();
    record.cell_index = @intCast(cell_count);
    record.row = cells[0].row;
    record.col = cells[0].col;
    record.cell_width = cells[0].width;
    record.codepoint = cells[0].codepoint;
    record.glyph_id = 42;
    record.drawable = 1;
    writeTestFontName(&record, "Menlo-Regular");
    records_ptr[0] = record;
    result.* = .{
        .status = 0,
        .primary_font_found = 1,
        .requested_font_matched = 1,
        .shaped_cell_count = 1,
        .glyph_record_count = 1,
        .glyph_record_overflow = 0,
        .missing_glyph_count = 0,
        .fallback_run_count = 0,
    };
}

test "CoreText draw list native ABI sizes stay aligned" {
    // 이 테스트는 Objective-C bridge와 Zig가 같은 메모리 레이아웃을 본다는 계약이다.
    // 필드 하나가 추가되거나 순서가 바뀌면 glyph id나 font name을 엉뚱한 위치에서 읽게
    // 되므로, 실제 CoreText smoke가 깨지기 전에 unit test에서 먼저 실패해야 한다.
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(NativeDrawCell));
    try std.testing.expectEqual(@as(usize, 160), @sizeOf(NativeDrawGlyphRecord));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(NativeDrawListShapeResult));
}

test "nativeDrawCellFromDrawCell carries style.bold into the bold style flag" {
    // bold cell만 셰이퍼가 bold 폰트 face를 고르므로, DrawCell.style.bold → style_flags bit0
    // 매핑이 끊기면 활성 탭/ SGR bold가 조용히 regular로 그려진다. 그 회귀를 여기서 잡는다.
    const bold = nativeDrawCellFromDrawCell(.{ .row = 0, .col = 0, .codepoint = 'A', .style = .{ .bold = true } });
    try std.testing.expectEqual(draw_cell_bold_bit, bold.style_flags & draw_cell_bold_bit);

    const regular = nativeDrawCellFromDrawCell(.{ .row = 0, .col = 0, .codepoint = 'A', .style = .{} });
    try std.testing.expectEqual(@as(u16, 0), regular.style_flags & draw_cell_bold_bit);
}

test "CoreText draw list shaper preserves DrawList metadata and styles" {
    // 이 테스트는 제품 입력인 DrawList를 native shaper로 넘기는 첫 계약이다. 기존 probe
    // surface를 쓰지 않고 DrawList의 size/cursor/dirty/overlay를 그대로 살려야 실제
    // terminal frame에서 trailing blank row와 cursor/underline 진단이 사라지지 않는다.
    var cells = [_]renderer.DrawCell{
        .{
            .row = 1,
            .col = 0,
            .codepoint = 'A',
            .width = 1,
            .style = .{ .bold = true, .underline = true },
        },
        .{ .row = 1, .col = 1, .codepoint = ' ', .width = 1 },
        .{ .row = 1, .col = 2, .codepoint = '한', .width = 2 },
    };
    var overlays = [_]renderer.DrawOverlay{
        .{ .cursor = .{ .row = 1, .col = 4, .visible = true } },
        .{ .line = .{ .row = 1, .col = 0, .width = 1, .kind = .underline } },
    };
    const list: renderer.DrawList = .{
        .size = .{ .cols = 12, .rows = 4 },
        .cursor = .{ .row = 1, .col = 4, .visible = true },
        .dirty = .{ .start_row = 1, .end_row = 1 },
        .cells = cells[0..],
        .overlays = overlays[0..],
    };
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const shaper = CoreTextDrawListShaper{
        .appearance = try app_config.resolveAppearance(.{}),
        .shape_draw_list = fakeShapeDrawList,
    };

    var shaped = try shaper.shape(std.testing.allocator, list, &registry);
    defer shaped.deinit(std.testing.allocator);

    try std.testing.expectEqual(list.size, shaped.runs.size);
    try std.testing.expectEqual(list.cursor, shaped.runs.cursor);
    try std.testing.expectEqual(list.dirty.?, shaped.runs.dirty.?);
    try std.testing.expectEqual(@as(usize, 2), shaped.runs.overlays.len);
    try std.testing.expectEqual(@as(usize, 2), shaped.runs.glyphs.len);
    try std.testing.expectEqual(@as(usize, 2), registry.count());
    try std.testing.expectEqual(@as(u21, 'A'), shaped.runs.glyphs[0].codepoint);
    try std.testing.expect(shaped.runs.glyphs[0].style.bold);
    try std.testing.expect(shaped.runs.glyphs[0].style.underline);
    try std.testing.expect(shaped.runs.glyphs[0].cache_key.style.bold);
    try std.testing.expect(shaped.runs.glyphs[1].fallback);
    try std.testing.expectEqual(@as(u2, 2), shaped.runs.glyphs[1].cell_width);
}

test "CoreText draw list shaper closes native failures before frame building" {
    // native bridge가 overflow나 font failure를 보고했는데 frame을 계속 만들면 summary가
    // renderer 문제처럼 보인다. DrawList shaper 경계에서 실패를 닫아야 root cause가
    // CoreText shape 단계로 남는다.
    var cells = [_]renderer.DrawCell{.{ .row = 0, .col = 0, .codepoint = 'A', .width = 1 }};
    const list: renderer.DrawList = .{
        .size = .{ .cols = 1, .rows = 1 },
        .cursor = .{},
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = cells[0..],
        .overlays = &.{},
    };
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const shaper = CoreTextDrawListShaper{
        .appearance = try app_config.resolveAppearance(.{}),
        .shape_draw_list = failingShapeDrawList,
    };

    try std.testing.expectError(
        error.CoreTextDrawListShapeFailed,
        shaper.shape(std.testing.allocator, list, &registry),
    );
}

test "CoreText draw list shaper rejects records that cannot map back to source cells" {
    // native record는 source cell index를 싣는다. 이 index가 DrawList 밖이면 style과
    // ownership을 잘못 붙이는 ABI 버그라, fallback으로 대충 그리지 않고 실패해야 한다.
    var cells = [_]renderer.DrawCell{.{ .row = 0, .col = 0, .codepoint = 'A', .width = 1 }};
    const list: renderer.DrawList = .{
        .size = .{ .cols = 1, .rows = 1 },
        .cursor = .{},
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = cells[0..],
        .overlays = &.{},
    };
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const shaper = CoreTextDrawListShaper{
        .appearance = try app_config.resolveAppearance(.{}),
        .shape_draw_list = outOfRangeRecordShapeDrawList,
    };

    try std.testing.expectError(
        error.CoreTextDrawListRecordOutsideInput,
        shaper.shape(std.testing.allocator, list, &registry),
    );
}
