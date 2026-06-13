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

/// pane 탭 바 우측 "+"(새 Term) 버튼이 차지하는 칸 수. 바 우측에 이만큼 예약하고 그 왼쪽을 탭 영역으로 쓴다.
pub const pane_tab_plus_cols: u16 = 3;

/// 바 cols에서 "+" 버튼 zone(pane_tab_plus_cols)을 뺀 탭 영역 cols. 바가 너무 좁으면(+ zone조차 못 둠) "+"
/// 없이 탭이 전체를 쓴다. 렌더(buildPaneTabBarDrawList)와 hit-test(tabIndexInBar 등)가 같은 값을 써서 보이는
/// 탭/+ 와 클릭이 일치한다. 순수 함수.
pub fn paneTabAreaCols(bar_cols: u16) u16 {
    return if (bar_cols > pane_tab_plus_cols + 1) bar_cols - pane_tab_plus_cols else bar_cols;
}

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
    plus_row: ?usize,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);

    const style: terminal.Style = .{ .foreground = fg };
    const title_rows: u16 = @intCast(@min(titles.len, @as(usize, std.math.maxInt(u16))));
    const rows: u16 = title_rows;
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

    // 사이드바 하단 "+"(새 워크스페이스) 버튼 — 탭 목록 아래 행(plus_row, 보통 탭 개수)에 '+' glyph 1개를
    // 가로 중앙에 그린다. 렌더러가 사이드바 셀을 행×슬롯 높이로 배치하므로 마지막 탭 슬롯 아래에 놓인다.
    var total_rows: u16 = rows;
    if (plus_row) |pr| {
        if (pr <= std.math.maxInt(u16)) {
            const prow: u16 = @intCast(pr);
            total_rows = @max(total_rows, prow + 1);
            try cells.append(allocator, .{
                .row = prow,
                .col = cols / 2, // 가로 중앙
                .codepoint = '+',
                .width = 1,
                .style = style,
            });
        }
    }

    return .{
        .size = .{ .cols = cols, .rows = @max(total_rows, 1) },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = if (total_rows == 0) 0 else total_rows - 1 },
        .cells = try cells.toOwnedSlice(allocator),
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// per-pane 가로 탭 바(cmux식)의 제목 glyph DrawList를 합성한다 — 사이드바(세로, 행=탭)와 달리 **모든 탭을
/// 행 0에 가로로** 등폭 세그먼트로 깐다. 탭 i는 col [i*tab_w, (i+1)*tab_w)를 차지하고, 그 안에 1칸 좌측
/// 패딩 뒤 제목을 (tab_w-1)칸까지 그린다(넘치면 자름). tab_w = cols/n(최소 1). 깨진 UTF-8은 U+FFFD,
/// 와이드 글자는 2칸 전진. 전경색은 `fg`(테마 글자색 — 활성 탭 강조는 호출자가 chrome 밴드로). 커서/overlay
/// 없는 UI 텍스트라 순수 함수로 OS 무관 단위 테스트한다. cols/n 0이면 빈(셀 없는) DrawList.
pub fn paneTabWidth(cols: u16, tab_count: usize) u16 {
    if (cols == 0 or tab_count == 0) return 0;
    const n: u16 = @intCast(@min(tab_count, @as(usize, cols))); // 탭이 cols보다 많으면 1칸씩(넘침은 잘림)
    return @max(1, cols / n);
}

pub fn buildPaneTabBarDrawList(
    allocator: std.mem.Allocator,
    titles: []const []const u8,
    cols: u16,
    fg: terminal.Color,
    close_tab: ?usize,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);

    const style: terminal.Style = .{ .foreground = fg };
    // 탭은 "+" 버튼 zone을 뺀 영역(tab_cols)에만 깐다. 우측 [tab_cols, cols)는 "+"(새 Term) 버튼.
    const tab_cols = paneTabAreaCols(cols);
    const tab_w = paneTabWidth(tab_cols, titles.len);
    if (tab_w > 0) {
        for (titles, 0..) |title, tab_index| {
            const start: u32 = @as(u32, @intCast(tab_index)) * tab_w;
            if (start >= tab_cols) break; // 탭이 탭 영역을 넘으면 나머지는 잘림
            const seg_end: u32 = @min(start + tab_w, @as(u32, tab_cols)); // 이 탭의 col 한도
            // 호버된 탭이면 우측 안쪽(seg_end-2)에 닫기 ✕를 둔다 — 제목은 ✕ 앞(seg_end-2)까지만 그린다.
            const is_close = close_tab != null and close_tab.? == tab_index and tab_w >= 2 and seg_end >= 2;
            const title_end: u32 = if (is_close) seg_end - 2 else seg_end;
            var col: u32 = start + 1; // 좌측 1칸 패딩
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

                const w: u16 = @max(1, terminal.width.cellWidth(cp)); // 0폭도 최소 1칸 전진
                if (col + w > title_end) break; // 제목 한도(✕ 앞)를 넘기면 자른다
                try cells.append(allocator, .{
                    .row = 0,
                    .col = @intCast(col),
                    .codepoint = cp,
                    .width = @intCast(@min(w, 2)),
                    .style = style,
                });
                col += w;
            }
            if (is_close) { // 호버 탭 우측 안쪽에 ✕ glyph 1개(xInTabCloseZone과 같은 col=seg_end-2).
                try cells.append(allocator, .{
                    .row = 0,
                    .col = @intCast(seg_end - 2),
                    .codepoint = sidebar_close_glyph,
                    .width = 1,
                    .style = style,
                });
            }
        }
    }

    // "+"(새 Term) 버튼 — 예약된 우측 zone이 있으면(tab_cols < cols) tab_cols+1 col에 '+' glyph 1개.
    if (tab_cols < cols and tab_cols + 1 < cols) {
        try cells.append(allocator, .{
            .row = 0,
            .col = tab_cols + 1,
            .codepoint = '+',
            .width = 1,
            .style = style,
        });
    }

    return .{
        .size = .{ .cols = @max(cols, 1), .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
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
    var draw_list = try buildSidebarDrawList(allocator, &titles, 10, .default, null, null);
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

test "buildPaneTabBarDrawList lays Term titles horizontally into equal-width tab segments" {
    const allocator = std.testing.allocator;
    // cols=20 → 우측 "+" zone 3칸 떼고 탭 영역 17, 2탭 → tab_w=8. 탭 0은 col [0,8), 탭 1은 [8,16). 각 탭 1칸 좌패딩 뒤 제목.
    const titles = [_][]const u8{ "sh", "vim" };
    var draw_list = try buildPaneTabBarDrawList(allocator, &titles, 20, .default, null);
    defer draw_list.deinit(allocator);

    // 모든 탭이 행 0(가로), size cols=한도·rows=1.
    try std.testing.expectEqual(@as(u16, 20), draw_list.size.cols);
    try std.testing.expectEqual(@as(u16, 1), draw_list.size.rows);
    try std.testing.expectEqual(@as(usize, 6), draw_list.cells.len); // "sh"(2) + "vim"(3) + "+"(1)
    for (draw_list.cells) |c| try std.testing.expectEqual(@as(u16, 0), c.row);
    // 탭 0: col 1('s'), 2('h'). 탭 1: col 9('v'), 10('i'), 11('m') — 세그먼트 start(8) + 1칸 패딩.
    try std.testing.expectEqual(@as(u16, 1), draw_list.cells[0].col);
    try std.testing.expectEqual(@as(u21, 's'), draw_list.cells[0].codepoint);
    try std.testing.expectEqual(@as(u16, 9), draw_list.cells[2].col);
    try std.testing.expectEqual(@as(u21, 'v'), draw_list.cells[2].codepoint);
    try std.testing.expect(!draw_list.cursor.visible);

    // 세그먼트보다 긴 제목은 그 탭 한도에서 잘린다. cols=11 → 탭 영역 8, 2탭 → tab_w=4, 제목 칸 = [start+1, start+4) = 3칸.
    const longt = [_][]const u8{ "abcdef", "x" };
    var dl2 = try buildPaneTabBarDrawList(allocator, &longt, 11, .default, null);
    defer dl2.deinit(allocator);
    var tab0: usize = 0;
    for (dl2.cells) |c| {
        if (c.col < 4) tab0 += 1; // 탭 0 세그먼트 [0,4)
    }
    try std.testing.expectEqual(@as(usize, 3), tab0); // "abcdef" 중 3칸(col 1,2,3)만

    // close_tab이 주어지면 그 탭 우측 안쪽(seg_end-2)에 ✕ glyph를 그리고 제목은 그 앞까지만. cols=20 → "+" zone
    // 3 빼고 탭 영역 17, 2탭 → tab_w=8, 탭 1 seg_end=min(16,17)=16 → ✕ col 14. 탭 1 호버.
    const ht = [_][]const u8{ "sh", "vim" };
    var dl3 = try buildPaneTabBarDrawList(allocator, &ht, 20, .default, 1);
    defer dl3.deinit(allocator);
    var found_close = false;
    var found_plus3 = false;
    for (dl3.cells) |c| {
        if (c.codepoint == sidebar_close_glyph) {
            found_close = true;
            try std.testing.expectEqual(@as(u16, 14), c.col); // seg_end(16) - 2
        }
        if (c.codepoint == '+') {
            found_plus3 = true;
            try std.testing.expectEqual(@as(u16, 18), c.col); // tab_cols(17) + 1
        }
    }
    try std.testing.expect(found_close);
    try std.testing.expect(found_plus3); // 우측 "+" 버튼이 항상 그려진다(cols 충분)
    // 호버 안 된 탭(close_tab=null)엔 ✕ 없음(단, "+"는 있다).
    for (draw_list.cells) |c| try std.testing.expect(c.codepoint != sidebar_close_glyph);
}

test "buildPaneTabBarDrawList reserves a right '+' zone (no '+' when too narrow)" {
    const allocator = std.testing.allocator;
    // cols=20 → 탭 영역 17, "+"는 col 18. 좁은 바(cols=4 ≤ +zone+1)는 "+" 없음.
    const titles = [_][]const u8{"sh"};
    var wide = try buildPaneTabBarDrawList(allocator, &titles, 20, .default, null);
    defer wide.deinit(allocator);
    var wide_plus = false;
    for (wide.cells) |c| {
        if (c.codepoint == '+') wide_plus = true;
    }
    try std.testing.expect(wide_plus);

    var narrow = try buildPaneTabBarDrawList(allocator, &titles, 4, .default, null);
    defer narrow.deinit(allocator);
    for (narrow.cells) |c| try std.testing.expect(c.codepoint != '+'); // 좁아서 "+" 없음
}

test "paneTabWidth divides cols among tabs (min 1, clamps when tabs exceed cols)" {
    try std.testing.expectEqual(@as(u16, 10), paneTabWidth(20, 2));
    try std.testing.expectEqual(@as(u16, 6), paneTabWidth(20, 3)); // 20/3 = 6
    try std.testing.expectEqual(@as(u16, 1), paneTabWidth(3, 5)); // 탭>cols → 1칸씩(넘침 잘림)
    try std.testing.expectEqual(@as(u16, 0), paneTabWidth(0, 2));
    try std.testing.expectEqual(@as(u16, 0), paneTabWidth(20, 0));
}

test "buildSidebarDrawList truncates to cols and advances wide glyphs by two columns" {
    const allocator = std.testing.allocator;
    // cols=5: "abcdefg"는 5칸까지만(자름). 와이드 글자는 2칸 전진.
    const titles = [_][]const u8{ "abcdefg", "한A" };
    var draw_list = try buildSidebarDrawList(allocator, &titles, 5, .default, null, null);
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
    var hovered = try buildSidebarDrawList(allocator, &titles, 10, .default, 1, null);
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
    var none = try buildSidebarDrawList(allocator, &titles, 10, .default, null, null);
    defer none.deinit(allocator);
    for (none.cells) |c| try std.testing.expect(c.codepoint != sidebar_close_glyph);

    // 범위 밖 close_row(탭 수 이상)는 무시 — ✕ 없음.
    var oob = try buildSidebarDrawList(allocator, &titles, 10, .default, 5, null);
    defer oob.deinit(allocator);
    for (oob.cells) |c| try std.testing.expect(c.codepoint != sidebar_close_glyph);
}

test "buildSidebarDrawList draws a '+' button row below the tabs when plus_row is set" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{ "sh", "vim" }; // 탭 2개 → "+"는 행 2
    var dl = try buildSidebarDrawList(allocator, &titles, 10, .default, null, titles.len);
    defer dl.deinit(allocator);
    // rows가 "+" 행(2)을 포함해 3이 된다(탭 0/1 + "+" 2).
    try std.testing.expectEqual(@as(u16, 3), dl.size.rows);
    var plus_count: usize = 0;
    for (dl.cells) |c| {
        if (c.codepoint == '+') {
            plus_count += 1;
            try std.testing.expectEqual(@as(u16, 2), c.row); // 탭 목록 아래 행
            try std.testing.expectEqual(@as(u16, 10 / 2), c.col); // 가로 중앙
        }
    }
    try std.testing.expectEqual(@as(usize, 1), plus_count);
    // plus_row=null이면 "+" 없음, rows=탭 수.
    var no_plus = try buildSidebarDrawList(allocator, &titles, 10, .default, null, null);
    defer no_plus.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 2), no_plus.size.rows);
    for (no_plus.cells) |c| try std.testing.expect(c.codepoint != '+');
}

test "buildFromDrawList shapes a synthesized sidebar draw list into glyph cells (shared atlas seam)" {
    // 사이드바 제목 패스가 터미널과 같은 seam(shape→raster→RenderFrame)을 탄다. fake bridge로
    // 합성 DrawList가 glyph까지 닿는지 고정한다 — 실제 CoreText 없이 연결 계약만 검증.
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{"ab"};
    const draw_list = try buildSidebarDrawList(allocator, &titles, 10, .default, null, null);

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
