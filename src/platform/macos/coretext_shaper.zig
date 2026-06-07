const std = @import("std");
const maru = @import("maru");
const coretext_font = @import("coretext_font.zig");
const renderer = maru.renderer;
const terminal = maru.terminal;

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
            .combining = record.combining,
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

test "CoreText shaper preserves explicit product surface metadata" {
    // 제품 shaper는 DrawList가 가진 size/cursor/dirty/overlay를 record 위치에서 다시
    // 추론하면 안 된다. 빈 trailing 영역과 cursor/underline overlay가 사라지면 resize와
    // redraw 디버깅이 매우 어려워지기 때문에, surface metadata를 그대로 통과시킨다.
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const overlays = [_]renderer.DrawOverlay{
        .{ .cursor = .{ .row = 5, .col = 6 } },
        .{ .underline = .{ .row = 4, .col = 2, .width = 1 } },
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
