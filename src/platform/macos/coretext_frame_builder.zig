const std = @import("std");
const maru = @import("maru");
const app = maru.app;
const config = maru.config;
const renderer = maru.renderer;
const terminal = maru.terminal;
const coretext_probe = @import("coretext_probe.zig");
const coretext_raster = @import("coretext_raster.zig");
const coretext_shaper = @import("coretext_shaper.zig");

pub const CoreTextFrameBuilder = struct {
    appearance: config.ResolvedAppearance,
    shape_draw_list: coretext_shaper.ShapeDrawListFn,
    rasterize_glyph: coretext_raster.RasterizeGlyphFn,
    // backing(Retina) scale을 천분율로 보관한다(예: 2000 = 2.0×). rasterizer는 이 분수 scale로
    // 폰트 크기를 device 픽셀에 정확히 맞추고, shaper config의 정수 device_scale은 여기서
    // 반올림해 파생한다(atlas 정사각 fallback/cache key 보조용).
    scale_milli: u32 = 1000,
    // 실제 폰트 메트릭에서 온 cell 픽셀 크기(advance 폭 × line-height, device px). shaper config로
    // 흘러 atlas slot이 정사각이 아니라 실제 모노스페이스 격자 크기가 된다.
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,

    pub fn build(
        self: CoreTextFrameBuilder,
        allocator: std.mem.Allocator,
        app_window: *app.AppWindow,
        renderer_state: *renderer.RendererState,
        drain_summary: app.RuntimePumpDrainSummary,
    ) !app.AppHostFrame {
        // FrameLoop는 "drain 뒤 active surface를 frame으로 만든다"는 순서만 소유한다.
        // macOS CoreText는 platform font/raster 경계라 app layer에 새면 안 되므로, 이
        // builder가 active TerminalCore snapshot을 DrawList -> CoreText GlyphRunList ->
        // RenderFrame으로 바꾸는 제품 후보 조립 책임을 맡는다.
        const active = app_window.active() orelse return error.NoActiveSurface;
        // renderSnapshot: 위로 스크롤한 상태면 뷰포트 윈도(스크롤백+활성)를 합성해 그린다. 바닥이면
        // snapshot()과 동일(합성 없음).
        const draw_list = try renderer.buildDrawList(allocator, active.core.renderSnapshot());
        // buildFromDrawList가 draw_list 소유권을 가져간다(실패 시 정리, 성공 시 RenderFrame으로 이동).
        const render_frame = try self.buildFromDrawList(allocator, draw_list, renderer_state);

        return .{
            .surface_id = active.id,
            .size = active.core.size,
            .process_state = active.process_state,
            .drain_summary = drain_summary,
            .render_frame = render_frame,
        };
    }

    /// 이미 만들어진 DrawList(소유권 이전)를 같은 CoreText shaper/rasterizer/renderer_state로
    /// shape → raster → RenderFrame까지 만든다. `build`(터미널 snapshot)와 사이드바 탭-제목 패스가
    /// 이 seam을 공유한다 — 둘이 같은 atlas(renderer_state)를 쓰므로 사이드바 제목 glyph도 터미널과
    /// 같은 slot을 재사용하고, 새 glyph만 추가 업로드된다. 성공하면 반환된 RenderFrame이 draw_list를
    /// 소유(deinit)하고, 실패하면 여기서 draw_list를 정리한다(호출자는 넘긴 뒤 건드리지 않는다).
    pub fn buildFromDrawList(
        self: CoreTextFrameBuilder,
        allocator: std.mem.Allocator,
        draw_list: renderer.DrawList,
        renderer_state: *renderer.RendererState,
    ) !renderer.RenderFrame {
        var owned_list = draw_list;
        var draw_list_owned = true;
        errdefer if (draw_list_owned) owned_list.deinit(allocator);

        var font_registry = renderer.FontIdentityRegistry.init(allocator);
        defer font_registry.deinit();

        const shaper = coretext_shaper.CoreTextDrawListShaper{
            .appearance = self.appearance,
            .shape_draw_list = self.shape_draw_list,
            // shaper config의 device_scale은 정수(정사각 fallback/cache key 거친 식별자)로만 쓰이고,
            // 실제 화면 경로는 아래 cell_width_px/cell_height_px(분수 메트릭)로 정밀 식별한다.
            .device_scale = renderer.deviceScaleFromMilli(self.scale_milli),
            .cell_width_px = self.cell_width_px,
            .cell_height_px = self.cell_height_px,
        };
        var shaped = try shaper.shape(allocator, owned_list, &font_registry);
        defer shaped.deinit(allocator);

        const rasterizer = coretext_raster.CoreTextGlyphRasterizer{
            .appearance = self.appearance,
            .font_registry = &font_registry,
            .rasterize_glyph = self.rasterize_glyph,
            .scale_milli = self.scale_milli,
        };
        const render_frame = try renderer_state.buildFrameFromGlyphRunListWithRasterizer(
            allocator,
            owned_list,
            shaped.runs,
            rasterizer,
        );
        draw_list_owned = false;
        return render_frame;
    }
};

/// 닫기(✕) 아이콘 코드포인트(U+2715 MULTIPLICATION X). 호버 슬롯 우측에 그린다.
pub const sidebar_close_glyph: u21 = 0x2715;

/// 텍스트 줄들을 사이드바 탭-제목 렌더용 DrawList로 합성한다(한 줄=한 탭, row=탭 인덱스). 각 줄을
/// UTF-8 코드포인트로 디코드해 cell 폭(terminal.width.cellWidth)만큼 열을 전진시키며 DrawCell을 깐다.
/// `cols`를 넘는 글자는 자른다(사이드바 폭 한도). 전경색은 `fg`(테마 사이드바 글자색). 커서/overlay는
/// 없다(UI 텍스트). 깨진 UTF-8 바이트는 U+FFFD로 대체해 한 칸 전진한다. `close_row`가 주어지면 그 행
/// (호버 슬롯) 우측 안쪽에 닫기 ✕ glyph 1개를 더한다(null이면 없음). 순수 함수라 OS 무관 단위 테스트한다.
pub fn buildSidebarDrawList(
    allocator: std.mem.Allocator,
    titles: []const []const u8,
    cols: u16,
    fg: terminal.Color,
    close_row: ?usize,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);

    const style: terminal.Style = .{ .foreground = fg };
    const rows: u16 = @intCast(@min(titles.len, @as(usize, std.math.maxInt(u16))));
    for (titles, 0..) |title, row_index| {
        if (row_index > std.math.maxInt(u16)) break;
        const row: u16 = @intCast(row_index);
        var col: u16 = 0;
        // 제목은 OSC 0/2(신뢰 불가 PTY 출력)에서 올 수 있어 잘못된 UTF-8을 패닉 없이 다뤄야 한다.
        // 바이트 단위로 디코드하고, 불완전/깨진 시퀀스는 U+FFFD로 대체하며 1바이트만 전진한다.
        var i: usize = 0;
        while (i < title.len) {
            var cp: u21 = 0xFFFD;
            var advance: usize = 1;
            if (std.unicode.utf8ByteSequenceLength(title[i])) |seq_len| {
                const len: usize = seq_len;
                if (i + len <= title.len) {
                    if (std.unicode.utf8Decode(title[i .. i + len])) |decoded| {
                        cp = decoded;
                        advance = len;
                    } else |_| {}
                }
            } else |_| {}
            i += advance;

            const w: u16 = @max(1, terminal.width.cellWidth(cp)); // 0폭(결합문자 등)도 최소 1칸 전진
            if (col + w > cols) break; // 사이드바 폭 한도 — 넘치는 제목은 자른다
            try cells.append(allocator, .{
                .row = row,
                .col = col,
                .codepoint = cp,
                .width = @intCast(@min(w, 2)),
                .style = style,
            });
            col += w;
        }
    }

    // 닫기 ✕ 아이콘: 호버 슬롯(close_row) 우측 안쪽 col에 glyph 1개. cols가 2칸 이상일 때만(우측 여백
    // 확보). 제목이 길어 같은 col에 겹치면 painter 순서로 ✕가 위에 그려진다(긴 제목 자름은 후속).
    if (close_row) |cr| {
        if (cr < @as(usize, rows) and cols >= 2) {
            try cells.append(allocator, .{
                .row = @intCast(cr),
                .col = cols - 2, // 우측에서 한 칸 안쪽(여백)
                .codepoint = sidebar_close_glyph,
                .width = 1,
                .style = style,
            });
        }
    }

    return .{
        .size = .{ .cols = cols, .rows = @max(rows, 1) },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = if (rows == 0) 0 else rows - 1 },
        .cells = try cells.toOwnedSlice(allocator),
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

fn emptyNativeDrawGlyphRecord() coretext_shaper.NativeDrawGlyphRecord {
    return .{
        .cell_index = 0,
        .row = 0,
        .col = 0,
        .cell_width = 0,
        .codepoint = 0,
        .combining = 0,
        .glyph_id = 0,
        .drawable = 0,
        .fallback = 0,
        .color_glyph_kind = 0,
        .font_name = [_]u8{0} ** coretext_probe.font_name_capacity,
    };
}

fn writeTestFontName(record: *coretext_shaper.NativeDrawGlyphRecord, name: []const u8) void {
    const len = @min(name.len, record.font_name.len - 1);
    @memcpy(record.font_name[0..len], name[0..len]);
    record.font_name[len] = 0;
}

fn testShapeDrawList(
    _: [*]const u8,
    _: usize,
    _: f64,
    cells_ptr: [*]const coretext_shaper.NativeDrawCell,
    cell_count: usize,
    result: *coretext_shaper.NativeDrawListShapeResult,
    records_ptr: [*]coretext_shaper.NativeDrawGlyphRecord,
    record_capacity: usize,
) callconv(.c) void {
    // 이 fake bridge는 CoreText 자체가 아니라 builder의 연결 계약만 검증한다. 공백과
    // continuation을 glyph로 만들지 않고, CJK는 fallback face로 보내 실제 CoreText
    // shaper/rasterizer가 지켜야 할 FontIdentityRegistry 경로를 unit test에서 고정한다.
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
            result.status = 7;
            result.glyph_record_overflow = 1;
            return;
        }

        const fallback = cell.codepoint > 0x7f;
        var record = emptyNativeDrawGlyphRecord();
        record.cell_index = @intCast(index);
        record.row = cell.row;
        record.col = cell.col;
        record.cell_width = cell.width;
        record.codepoint = cell.codepoint;
        record.combining = cell.combining;
        record.glyph_id = cell.codepoint + 10;
        record.drawable = 1;
        record.fallback = if (fallback) 1 else 0;
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
    _: [*]const coretext_shaper.NativeDrawCell,
    _: usize,
    result: *coretext_shaper.NativeDrawListShapeResult,
    _: [*]coretext_shaper.NativeDrawGlyphRecord,
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

fn testRasterizeGlyph(
    _: [*]const u8,
    _: usize,
    _: f64,
    _: [*]const u8,
    _: usize,
    _: u32,
    _: u32,
    _: usize,
    _: usize,
    _: usize,
    pixels: [*]u8,
    pixel_capacity: usize,
    result: *coretext_raster.NativeGlyphRasterResult,
) callconv(.c) void {
    // 실제 CoreText bitmap 품질은 native smoke가 본다. 여기서는 raster upload가 빈 bytes로
    // 사라지지 않고 RenderFrame 준비 gate까지 닿는지 보려는 목적이라 모든 픽셀을 잉크로
    // 채운다.
    if (pixel_capacity > 0) @memset(pixels[0..pixel_capacity], 0xff);
    result.* = .{
        .status = 0,
        .non_clear_pixels = @intCast(pixel_capacity / 4),
    };
}

test "CoreText frame builder builds AppHostFrame from active surface" {
    // 이 테스트는 실제 Objective-C/CoreText를 호출하지 않는다. 대신 같은 함수 포인터
    // 경계를 fake bridge로 주입해, active surface snapshot이 제품 후보
    // CoreTextDrawListShaper/CoreTextGlyphRasterizer/RendererState를 지나 AppHostFrame으로
    // 소유권을 넘기는지 고정한다.
    const allocator = std.testing.allocator;
    var surfaces = [_]app.Surface{try app.Surface.init(allocator, 7, .{ .cols = 8, .rows = 2 })};
    defer surfaces[0].deinit();
    surfaces[0].process_state = .running;
    try surfaces[0].core.write("A한");

    var tab_ptrs = [_]*app.Surface{&surfaces[0]};
    var app_window: app.AppWindow = .{ .tabs = &tab_ptrs };
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();

    const builder = CoreTextFrameBuilder{
        .appearance = try config.resolveAppearance(.{}),
        .shape_draw_list = testShapeDrawList,
        .rasterize_glyph = testRasterizeGlyph,
    };
    var frame = try builder.build(allocator, &app_window, &renderer_state, .{ .output_events = 1 });
    defer frame.deinit(allocator);

    const stats = renderer.renderFrameStats(frame.render_frame, renderer_state.atlas.entryCount());
    try std.testing.expectEqual(@as(u64, 7), frame.surface_id);
    try std.testing.expectEqual(terminal.Size{ .cols = 8, .rows = 2 }, frame.size);
    try std.testing.expectEqual(app.ProcessState.running, frame.process_state);
    try std.testing.expectEqual(@as(usize, 1), frame.drain_summary.output_events);
    try std.testing.expect(stats.prepared());
    try std.testing.expectEqual(@as(usize, 2), stats.glyph_count);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_count);
    try std.testing.expectEqual(@as(usize, 2), stats.glyph_raster_upload_count);
    try std.testing.expect(stats.glyph_raster_ready);
}

test "CoreText frame builder reports no active surface before shaping" {
    // active surface가 없으면 CoreText bridge를 호출하기 전에 실패해야 한다. 그래야 window/tab
    // lifecycle 버그가 font/raster 실패처럼 보이지 않는다.
    const allocator = std.testing.allocator;
    var tab_ptrs = [_]*app.Surface{};
    var app_window: app.AppWindow = .{ .tabs = &tab_ptrs };
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    const builder = CoreTextFrameBuilder{
        .appearance = try config.resolveAppearance(.{}),
        .shape_draw_list = testShapeDrawList,
        .rasterize_glyph = testRasterizeGlyph,
    };

    try std.testing.expectError(
        error.NoActiveSurface,
        builder.build(allocator, &app_window, &renderer_state, .{}),
    );
}

test "CoreText frame builder surfaces native shape failures" {
    // native shaper가 overflow/font failure를 보고하면 frame 준비를 계속하면 안 된다. 이
    // 실패가 renderer prepared=false로 숨어 버리면 root cause가 CoreText shape 단계인지
    // atlas/raster 단계인지 구분할 수 없기 때문이다.
    const allocator = std.testing.allocator;
    var surfaces = [_]app.Surface{try app.Surface.init(allocator, 8, .{ .cols = 4, .rows = 1 })};
    defer surfaces[0].deinit();
    try surfaces[0].core.write("A");

    var tab_ptrs = [_]*app.Surface{&surfaces[0]};
    var app_window: app.AppWindow = .{ .tabs = &tab_ptrs };
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    const builder = CoreTextFrameBuilder{
        .appearance = try config.resolveAppearance(.{}),
        .shape_draw_list = failingShapeDrawList,
        .rasterize_glyph = testRasterizeGlyph,
    };

    try std.testing.expectError(
        error.CoreTextDrawListShapeFailed,
        builder.build(allocator, &app_window, &renderer_state, .{}),
    );
}

test "buildSidebarDrawList lays tab titles into per-row draw cells, truncating to cols" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{ "zsh", "vim" };
    var draw_list = try buildSidebarDrawList(allocator, &titles, 10, .default, null);
    defer draw_list.deinit(allocator);

    // 한 줄=한 탭(row=탭 인덱스), size는 cols=한도·rows=탭 수.
    try std.testing.expectEqual(@as(u16, 10), draw_list.size.cols);
    try std.testing.expectEqual(@as(u16, 2), draw_list.size.rows);
    try std.testing.expectEqual(@as(usize, 6), draw_list.cells.len); // "zsh"(3) + "vim"(3)
    try std.testing.expectEqual(@as(u16, 0), draw_list.cells[0].row);
    try std.testing.expectEqual(@as(u16, 0), draw_list.cells[0].col);
    try std.testing.expectEqual(@as(u21, 'z'), draw_list.cells[0].codepoint);
    try std.testing.expectEqual(@as(u16, 1), draw_list.cells[3].row); // 둘째 탭은 row 1
    try std.testing.expectEqual(@as(u21, 'v'), draw_list.cells[3].codepoint);
    // UI 텍스트라 커서/overlay 없음.
    try std.testing.expect(!draw_list.cursor.visible);
    try std.testing.expectEqual(@as(usize, 0), draw_list.overlays.len);
}

test "buildSidebarDrawList truncates to cols and advances wide glyphs by two columns" {
    const allocator = std.testing.allocator;
    // cols=5: "abcdefg"는 5칸까지만(자름). 와이드 글자는 2칸 전진.
    const titles = [_][]const u8{ "abcdefg", "한A" };
    var draw_list = try buildSidebarDrawList(allocator, &titles, 5, .default, null);
    defer draw_list.deinit(allocator);

    var row0: usize = 0;
    var row1_cols: [2]u16 = .{ 0, 0 };
    var row1_i: usize = 0;
    for (draw_list.cells) |c| {
        if (c.row == 0) row0 += 1;
        if (c.row == 1 and row1_i < 2) {
            row1_cols[row1_i] = c.col;
            row1_i += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 5), row0); // 7글자 중 5칸까지만
    // "한"(와이드, width 2)이 col 0, 다음 'A'가 col 2(2칸 전진).
    try std.testing.expectEqual(@as(u16, 0), row1_cols[0]);
    try std.testing.expectEqual(@as(u16, 2), row1_cols[1]);
}

test "buildSidebarDrawList adds a close glyph at the hovered row's right edge only" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{ "a", "b" };
    // 호버 행 1 → ✕가 row 1, col cols-2=8에 하나 추가된다.
    var hovered = try buildSidebarDrawList(allocator, &titles, 10, .default, 1);
    defer hovered.deinit(allocator);
    var close_count: usize = 0;
    for (hovered.cells) |c| {
        if (c.codepoint == sidebar_close_glyph) {
            close_count += 1;
            try std.testing.expectEqual(@as(u16, 1), c.row);
            try std.testing.expectEqual(@as(u16, 8), c.col); // cols(10) - 2
        }
    }
    try std.testing.expectEqual(@as(usize, 1), close_count);

    // close_row=null이면 ✕ 없음.
    var none = try buildSidebarDrawList(allocator, &titles, 10, .default, null);
    defer none.deinit(allocator);
    for (none.cells) |c| try std.testing.expect(c.codepoint != sidebar_close_glyph);

    // 범위 밖 close_row(탭 수 이상)는 무시 — ✕ 없음.
    var oob = try buildSidebarDrawList(allocator, &titles, 10, .default, 5);
    defer oob.deinit(allocator);
    for (oob.cells) |c| try std.testing.expect(c.codepoint != sidebar_close_glyph);
}

test "buildFromDrawList shapes a synthesized sidebar draw list into glyph cells (shared atlas seam)" {
    // 사이드바 제목 패스가 터미널과 같은 seam(shape→raster→RenderFrame)을 탄다. fake bridge로
    // 합성 DrawList가 glyph까지 닿는지 고정한다 — 실제 CoreText 없이 연결 계약만 검증.
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{"ab"};
    const draw_list = try buildSidebarDrawList(allocator, &titles, 10, .default, null);

    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    const builder = CoreTextFrameBuilder{
        .appearance = try config.resolveAppearance(.{}),
        .shape_draw_list = testShapeDrawList,
        .rasterize_glyph = testRasterizeGlyph,
    };

    var render_frame = try builder.buildFromDrawList(allocator, draw_list, &renderer_state);
    defer render_frame.deinit(allocator);

    // 'a','b' 두 glyph(공백 아님)가 shape돼 atlas/quad까지 준비됐다.
    const stats = renderer.renderFrameStats(render_frame, renderer_state.atlas.entryCount());
    try std.testing.expect(stats.prepared());
    try std.testing.expectEqual(@as(usize, 2), stats.glyph_count);
}
