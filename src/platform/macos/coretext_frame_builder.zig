const std = @import("std");
const maru = @import("maru");
const app = maru.app;
const config = maru.config;
const renderer = maru.renderer;
const terminal = maru.terminal;
const tabbar = maru.chrome.components.tabbar; // C4b-4: 탭 셀 경계 단일 소스(제목·✕가 hit-test·밴드와 같은 분할)
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

/// 말줄임 표시 glyph(U+2026 HORIZONTAL ELLIPSIS, 1칸). 제목이 칸을 넘으면 마지막 칸을 이걸로 바꾼다.
pub const title_ellipsis_glyph: u21 = 0x2026;

/// title의 디스플레이 폭(칸 합) — wide glyph는 2, 나머지 1. 깨진 UTF-8 바이트는 U+FFFD(1칸). 말줄임 필요 판정용.
/// pub: pane 라벨 세그먼트 폭(paneLabelCols)도 이 단일 출처로 폭을 잰다(렌더 ellipsize와 같은 셈법이라 라벨
/// 칸 예약과 실제 글리프가 어긋나지 않는다).
pub fn titleDisplayWidth(title: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < title.len) {
        var cp: u21 = 0xFFFD;
        var advance: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(title[i])) |seq_len| {
            const len: usize = seq_len;
            if (i + len <= title.len) {
                if (std.unicode.utf8Decode(title[i .. i + len])) |d| {
                    cp = d;
                    advance = len;
                } else |_| {}
            }
        } else |_| {}
        i += advance;
        total += @max(1, terminal.width.cellWidth(cp));
    }
    return total;
}

/// title을 [start_col, end_col) 칸에 row행 DrawCell로 깐다(좌→우). 다 안 들어가면 **하드 컷 대신 마지막 칸을
/// "…"(U+2026)로** 바꿔 잘렸음을 표시한다(말줄임). end_col<=start_col이면 무동작. 깨진 UTF-8 U+FFFD, wide 2칸.
/// 사이드바 제목·pane 탭 바 제목이 공유하는 단일 출처라 잘림 표시가 일관된다. 순수(out append만).
/// 제목을 [start_col, end_col) 칸에 깐다 — 안 들어가면 마지막 칸을 "…"(U+2026)로 말줄임한다. 사이드바·pane
/// 탭 바·floating 탭이 공유하는 잘림 규칙의 단일 출처. **다음 빈 col**(제목/말줄임 뒤)을 돌려줘, 호출자가 그 뒤를
/// 배경으로 채우는(솔리드 박스) 식으로 이어 그릴 수 있다. 글자만 추가하고 빈 칸은 채우지 않는다(중복 셀 없음).
fn appendEllipsizedTitle(
    allocator: std.mem.Allocator,
    cells: *std.ArrayList(renderer.DrawCell),
    title: []const u8,
    row: u16,
    start_col: u16,
    end_col: u16,
    style: terminal.Style,
) !u16 {
    if (end_col <= start_col) return start_col;
    const fits = titleDisplayWidth(title) <= @as(usize, end_col - start_col);
    const text_end: u16 = if (fits) end_col else end_col - 1; // 말줄임이면 마지막 1칸을 "…"에 남긴다
    var col: u16 = start_col;
    var i: usize = 0;
    while (i < title.len) {
        var cp: u21 = 0xFFFD;
        var advance: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(title[i])) |seq_len| {
            const len: usize = seq_len;
            if (i + len <= title.len) {
                if (std.unicode.utf8Decode(title[i .. i + len])) |d| {
                    cp = d;
                    advance = len;
                } else |_| {}
            }
        } else |_| {}
        const w: u16 = @max(1, terminal.width.cellWidth(cp));
        if (col + w > text_end) break; // 텍스트 한도를 넘으면(말줄임 자리 직전) 멈춘다
        try cells.append(allocator, .{ .row = row, .col = col, .codepoint = cp, .width = @intCast(@min(w, 2)), .style = style });
        col += w;
        i += advance;
    }
    if (!fits and col < end_col) {
        try cells.append(allocator, .{ .row = row, .col = col, .codepoint = title_ellipsis_glyph, .width = 1, .style = style });
        col += 1;
    }
    return col;
}

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
    active_row: ?usize,
    active_fg: terminal.Color,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);

    const style: terminal.Style = .{ .foreground = fg };
    const title_rows: u16 = @intCast(@min(titles.len, @as(usize, std.math.maxInt(u16))));
    const rows: u16 = title_rows;
    for (titles, 0..) |title, row_index| {
        if (row_index > std.math.maxInt(u16)) break;
        const row: u16 = @intCast(row_index);
        // 활성 행(워크스페이스)은 글자를 강조색(active_fg) + bold로, 나머지는 fg(흐림) regular로 — 활성 탭 글자 강조.
        // bold는 셰이퍼가 bold 폰트 face를 골라 실제 굵은 글리프를 그린다(색만으론 약한 강조를 무게로 보강).
        const row_style: terminal.Style = if (active_row != null and active_row.? == row_index) .{ .foreground = active_fg, .bold = true } else style;
        // 제목은 OSC 0/2(신뢰 불가 PTY 출력)이라 깨진 UTF-8을 U+FFFD로 다룬다. cols를 넘으면 하드 컷이 아니라
        // 마지막 칸을 "…"로 말줄임한다(appendEllipsizedTitle 단일 출처 — pane 탭 바 제목과 같은 규칙).
        _ = try appendEllipsizedTitle(allocator, &cells, title, row, 0, cols, row_style);
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

/// per-pane 가로 탭 바의 제목 glyph DrawList를 합성한다 — 사이드바(세로, 행=탭)와 달리 **모든 탭을
/// 행 0에 가로로** 등폭 세그먼트로 깐다. 탭 i는 col [i*tab_w, (i+1)*tab_w)를 차지하고, 그 안에 1칸 좌측
/// 패딩 뒤 제목을 (tab_w-1)칸까지 그린다(넘치면 자름). tab_w = cols/n(최소 1). 깨진 UTF-8은 U+FFFD,
/// 와이드 글자는 2칸 전진. 전경색은 `fg`(테마 글자색 — 활성 탭 강조는 호출자가 chrome 밴드로). 커서/overlay
/// 없는 UI 텍스트라 순수 함수로 OS 무관 단위 테스트한다. cols/n 0이면 빈(셀 없는) DrawList.
pub fn paneTabWidth(cols: u16, tab_count: usize) u16 {
    if (cols == 0 or tab_count == 0) return 0;
    const n: u16 = @intCast(@min(tab_count, @as(usize, cols))); // 탭이 cols보다 많으면 1칸씩(넘침은 잘림)
    return @max(1, cols / n);
}

/// 탭 바 레이아웃 단일 소스(§6) — barMetrics(hit-test)·buildPaneTabBarDrawList(렌더)가 공유해 보이는 탭/‹›/+ 와
/// 클릭이 일치한다. base=paneTabAreaCols("+" zone 뺀 탭 영역). 전체 탭 폭(term*tab_w)이 base를 넘으면 우측에
/// ‹›(왼/오 스크롤) 2칸을 예약해 tab_cols를 그만큼 줄인다(has_scroll). tab_w: rich 고정 or tui 균등. tab_w=0=분할 불가.
pub fn tabLayout(bar_cols: u16, term_count: usize, tab_width_fixed: u16, scroll_cols: u32) struct { tab_cols: u16, tab_w: u16, has_scroll: bool, eff_scroll: u32 } {
    const base = paneTabAreaCols(bar_cols);
    const tab_w = if (tab_width_fixed > 0) tab_width_fixed else paneTabWidth(base, term_count);
    if (tab_w == 0) return .{ .tab_cols = base, .tab_w = 0, .has_scroll = false, .eff_scroll = 0 };
    const total = @as(u32, @intCast(term_count)) * @as(u32, tab_w);
    // #4(리뷰): rich 고정폭(tab_width_fixed>0)만 스크롤한다 — tui 균등은 tab_w=1 collapse로 넘쳐도 ‹›를 안 띄움("tui 무변화" 유지).
    // ‹›(2칸) 둘 여유(base>2)도 필요.
    const has_scroll = tab_width_fixed > 0 and total > base and base > 3; // #5a: ‹(tab_cols)·gap(tab_cols+1)·›(tab_cols+2) 3칸(버튼 사이 공백) 여유
    const tab_cols: u16 = if (has_scroll) base - 3 else base;
    // #1(리뷰): scroll를 [0, total-tab_cols]로 clamp + has_scroll 아니면 0 → 탭 닫기/리사이즈로 넘침이 사라지면 stale scroll가
    // 자동으로 0이 돼 빈 탭 바에 갇히지 않는다. 렌더·hit-test·클릭이 이 eff_scroll을 공유(§6).
    const eff_scroll: u32 = if (has_scroll) @min(scroll_cols, total - tab_cols) else 0;
    return .{ .tab_cols = tab_cols, .tab_w = tab_w, .has_scroll = has_scroll, .eff_scroll = eff_scroll };
}

/// pane 라벨 세그먼트(탭 바 좌측)의 glyph DrawList — 한 줄(row 0)에 사용자 지정 이름을 [1, cols-1) 칸에 깐다
/// (col 0 좌측 패딩, 마지막 칸은 탭과의 시각 간격). 넘치면 탭 제목과 같은 말줄임(appendEllipsizedTitle 단일
/// 출처). 색은 `fg`(호출자가 accent로 줘 탭 제목과 구분). cols<3이면(패딩+글자+간격 불가) 빈 DrawList — 호출자는
/// label_cols를 그 미만으로 예약하지 않는다. 커서/overlay 없는 UI 텍스트라 OS 무관 단위 테스트.
pub fn buildPaneLabelDrawList(
    allocator: std.mem.Allocator,
    label: []const u8,
    cols: u16,
    fg: terminal.Color,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    if (cols >= 3) {
        // [1, cols-1): col 0 = 좌측 패딩, 마지막 칸 = 탭과의 간격. 그 사이에 이름(말줄임).
        _ = try appendEllipsizedTitle(allocator, &cells, label, 0, 1, cols - 1, .{ .foreground = fg });
    }
    return .{
        .size = .{ .cols = cols, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = try cells.toOwnedSlice(allocator),
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

pub fn buildPaneTabBarDrawList(
    allocator: std.mem.Allocator,
    titles: []const []const u8,
    cols: u16,
    fg: terminal.Color,
    close_tab: ?usize,
    active_tab: ?usize,
    active_fg: terminal.Color,
    tab_width_fixed: u16, // 0=균등분할(tui — 바를 탭 수로 나눔), >0=탭 고정 폭(rich). barMetrics와 같은 값이라 보이는 탭=클릭 탭 정합(§6)
    scroll_cols: u32, // Step 2: 가로 스크롤 offset(컬럼) — segCols에 전달해 보이는 탭 창을 왼쪽으로 민다. 0=기본. barMetrics와 같은 값(정합).
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);

    const style: terminal.Style = .{ .foreground = fg };
    // 탭은 "+" 버튼 zone을 뺀 영역(tab_cols)에만 깐다. 우측 [tab_cols, cols)는 "+"(새 Term) 버튼.
    // 탭 레이아웃 단일 소스(§6) — barMetrics(hit-test)와 같은 tabLayout이라 보이는 탭/‹›/+ == 클릭. 넘치면 우측 ‹›(2칸) 예약·탭 영역 축소.
    const layout = tabLayout(cols, titles.len, tab_width_fixed, scroll_cols);
    const tab_cols = layout.tab_cols;
    const tab_w = layout.tab_w;
    if (tab_w > 0) {
        for (titles, 0..) |title, tab_index| {
            // C4b-4: 셀 경계를 chrome tabbar.segCols 단일 소스로 — hit-test(segOf)·활성 밴드와 같은 분할이라 제목·✕가 정합.
            const sc = tabbar.segCols(tab_index, tab_w, tab_cols, layout.eff_scroll); // #1: clamp된 eff_scroll(stale 방지)
            const start: u32 = sc.start;
            if (sc.end <= start) {
                if (start >= tab_cols) break; // 우측 넘침 — 이후 탭도 다 넘침(중단)
                continue; // 왼쪽 스크롤아웃(scroll로 화면 밖) — 안 그리고 다음 탭으로
            }
            const seg_end: u32 = sc.end; // 이 탭의 col 한도
            // 호버된 탭이면 우측 안쪽(seg_end-2)에 닫기 ✕를 둔다 — 제목은 ✕ 앞(seg_end-2)까지만 그린다.
            const is_close = close_tab != null and close_tab.? == tab_index and tab_w >= 2 and seg_end >= 2;
            const title_end: u32 = if (is_close) seg_end - 2 else seg_end;
            // 활성 Term 탭은 글자를 강조색(active_fg) + bold로, 나머지는 fg(흐림) regular로 — 활성 탭 글자 강조.
            // bold는 셰이퍼가 bold 폰트 face를 골라 실제 굵은 글리프를 그린다(사이드바 활성 행과 같은 규칙).
            const tab_style: terminal.Style = if (active_tab != null and active_tab.? == tab_index) .{ .foreground = active_fg, .bold = true } else style;
            // 좌측 1칸 패딩 뒤에 제목. title_end(✕ 앞)를 넘으면 하드 컷이 아니라 "…"로 말줄임(사이드바와 같은 규칙).
            _ = try appendEllipsizedTitle(allocator, &cells, title, 0, @intCast(start + 1), @intCast(title_end), tab_style);
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

    // 우측 컨트롤: 넘치면(has_scroll) ‹›(왼/오 스크롤) 2칸을 tab_cols·tab_cols+1에, 그 오른쪽에 "+". 안 넘치면 "+"만.
    if (layout.has_scroll) {
        // #3: ‹/›를 스크롤 여지가 있는 방향만 강조색(active_fg)·없는 방향은 muted(style=fg)로 그려, ‹가 진하면 "왼쪽에 잘린 탭 더 있음"을
        // 알리는 단서로 쓴다(부분 탭 좌측 잘림 cue). eff_scroll은 [0, total-tab_cols]로 clamp돼 있어 경계 판정이 정확하다.
        const total: u32 = @intCast(titles.len * tab_w);
        const max_scroll: u32 = total - tab_cols; // has_scroll이면 total > tab_cols 보장(total > base ≥ tab_cols+3)
        const left_style: terminal.Style = if (layout.eff_scroll > 0) .{ .foreground = active_fg } else style; // 왼쪽 더 있으면 강조, scroll=0이면 흐림
        const right_style: terminal.Style = if (layout.eff_scroll < max_scroll) .{ .foreground = active_fg } else style; // 오른쪽 더 있으면 강조, 끝이면 흐림
        try cells.append(allocator, .{ .row = 0, .col = @intCast(tab_cols), .codepoint = '<', .width = 1, .style = left_style });
        try cells.append(allocator, .{ .row = 0, .col = @intCast(tab_cols + 2), .codepoint = '>', .width = 1, .style = right_style }); // gap tab_cols+1 건너뜀
    }
    // "+"(새 Term) 버튼 — ‹› 오른쪽(has_scroll) 또는 tab_cols(아니면). plus_start+1 col에 '+'.
    const plus_start: u16 = tab_cols + (if (layout.has_scroll) @as(u16, 2) else 0);
    if (plus_start < cols and plus_start + 1 < cols) {
        try cells.append(allocator, .{ .row = 0, .col = plus_start + 1, .codepoint = '+', .width = 1, .style = style });
    }

    return .{
        .size = .{ .cols = @max(cols, 1), .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = try cells.toOwnedSlice(allocator),
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// 드래그 중 커서를 따라다니는 'floating 탭' 미리보기의 DrawList(한 행). col마다 셀 하나(중복 없음)를 깔되 전부
/// `bg`를 줘 솔리드 박스로 보이게 하고, 1칸 좌패딩 뒤에 제목을 그린다. 박스 폭(cols)을 넘으면 하드 컷이 아니라
/// 마지막 칸을 "…"로 말줄임한다(appendEllipsizedTitle 단일 출처 — 사이드바·pane 탭 바와 같은 규칙). 깨진 UTF-8은
/// U+FFFD, wide glyph는 2칸. 박스 위에 제목이 얹힌 작은 탭처럼 보인다. 커서/overlay 없는 UI 텍스트라 순수 함수.
pub fn buildFloatingTabDrawList(
    allocator: std.mem.Allocator,
    title: []const u8,
    cols: u16,
    fg: terminal.Color,
    bg: terminal.Color,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    const style: terminal.Style = .{ .foreground = fg, .background = bg };

    var col: u16 = 0;
    if (col < cols) { // col 0 = 좌패딩(공백, bg)
        try cells.append(allocator, .{ .row = 0, .col = 0, .codepoint = ' ', .width = 1, .style = style });
        col = 1;
    }
    // 제목을 col 1..cols에 깔고(넘치면 "…"), 다음 빈 col을 받아 그 뒤를 bg로 채운다.
    col = try appendEllipsizedTitle(allocator, &cells, title, 0, col, cols, style);
    while (col < cols) : (col += 1) { // 남은 col = bg 공백(솔리드 박스 마감)
        try cells.append(allocator, .{ .row = 0, .col = col, .codepoint = ' ', .width = 1, .style = style });
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
    var draw_list = try buildSidebarDrawList(allocator, &titles, 10, .default, null, null, null, .default);
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
    var draw_list = try buildPaneTabBarDrawList(allocator, &titles, 20, .default, null, null, .default, 0, 0);
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
    var dl2 = try buildPaneTabBarDrawList(allocator, &longt, 11, .default, null, null, .default, 0, 0);
    defer dl2.deinit(allocator);
    var tab0: usize = 0;
    for (dl2.cells) |c| {
        if (c.col < 4) tab0 += 1; // 탭 0 세그먼트 [0,4)
    }
    try std.testing.expectEqual(@as(usize, 3), tab0); // "abcdef" 중 3칸(col 1,2,3)만

    // close_tab이 주어지면 그 탭 우측 안쪽(seg_end-2)에 ✕ glyph를 그리고 제목은 그 앞까지만. cols=20 → "+" zone
    // 3 빼고 탭 영역 17, 2탭 → tab_w=8, 탭 1 seg_end=min(16,17)=16 → ✕ col 14. 탭 1 호버.
    const ht = [_][]const u8{ "sh", "vim" };
    var dl3 = try buildPaneTabBarDrawList(allocator, &ht, 20, .default, 1, null, .default, 0, 0);
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

test "buildPaneLabelDrawList: 이름을 [1,cols-1)에 깔고 좌패딩·우간격을 남긴다(넘치면 말줄임)" {
    const allocator = std.testing.allocator;
    // cols=8 → [1,7)에 "build"(5칸) 들어감. col 0=패딩, col 7=탭과의 간격(빈 칸).
    var dl = try buildPaneLabelDrawList(allocator, "build", 8, .default);
    defer dl.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 8), dl.size.cols);
    try std.testing.expectEqual(@as(u16, 1), dl.size.rows);
    // 첫 글자 'b'는 col 1(좌패딩 뒤), 마지막 글자 'd'는 col 5 — col 0·6·7엔 글자 없음.
    var min_col: u16 = 999;
    var max_col: u16 = 0;
    for (dl.cells) |c| {
        if (c.col < min_col) min_col = c.col;
        if (c.col > max_col) max_col = c.col;
    }
    try std.testing.expectEqual(@as(u16, 1), min_col); // 좌패딩(col 0 비움)
    try std.testing.expect(max_col <= 5); // col 6·7은 간격(빈 칸)

    // 좁으면(cols<3) 빈 DrawList(패딩+글자+간격 불가).
    var tiny = try buildPaneLabelDrawList(allocator, "build", 2, .default);
    defer tiny.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), tiny.cells.len);

    // 긴 이름은 말줄임(U+2026)으로 끝난다.
    var ell = try buildPaneLabelDrawList(allocator, "very-long-pane-name", 6, .default);
    defer ell.deinit(allocator);
    var has_ellipsis = false;
    for (ell.cells) |c| {
        if (c.codepoint == title_ellipsis_glyph) has_ellipsis = true;
    }
    try std.testing.expect(has_ellipsis);
}

test "buildPaneTabBarDrawList reserves a right '+' zone (no '+' when too narrow)" {
    const allocator = std.testing.allocator;
    // cols=20 → 탭 영역 17, "+"는 col 18. 좁은 바(cols=4 ≤ +zone+1)는 "+" 없음.
    const titles = [_][]const u8{"sh"};
    var wide = try buildPaneTabBarDrawList(allocator, &titles, 20, .default, null, null, .default, 0, 0);
    defer wide.deinit(allocator);
    var wide_plus = false;
    for (wide.cells) |c| {
        if (c.codepoint == '+') wide_plus = true;
    }
    try std.testing.expect(wide_plus);

    var narrow = try buildPaneTabBarDrawList(allocator, &titles, 4, .default, null, null, .default, 0, 0);
    defer narrow.deinit(allocator);
    for (narrow.cells) |c| try std.testing.expect(c.codepoint != '+'); // 좁아서 "+" 없음
}

test "buildPaneTabBarDrawList: fixed tab width (rich) — left-aligned, leaves empty area" {
    const allocator = std.testing.allocator;
    // cols=40, "+"zone 3 → tab_cols=37. fixed_w=16: 탭0 [0,16), 탭1 [16,32), 나머지 [32,37) 빈(균등이면 ~18씩 stretch).
    const titles = [_][]const u8{ "sh", "vim" };
    var dl = try buildPaneTabBarDrawList(allocator, &titles, 40, .default, null, null, .default, 16, 0);
    defer dl.deinit(allocator);
    // 탭1 'v'는 seg start(16) + 1칸 좌패딩 = col 17(고정폭이라 균등분할과 다른 위치 — stretch 안 함).
    var v_col: ?u16 = null;
    for (dl.cells) |c| {
        if (c.codepoint == 'v') v_col = c.col;
    }
    try std.testing.expectEqual(@as(?u16, 17), v_col);
}

test "paneTabWidth divides cols among tabs (min 1, clamps when tabs exceed cols)" {
    try std.testing.expectEqual(@as(u16, 10), paneTabWidth(20, 2));
    try std.testing.expectEqual(@as(u16, 6), paneTabWidth(20, 3)); // 20/3 = 6
    try std.testing.expectEqual(@as(u16, 1), paneTabWidth(3, 5)); // 탭>cols → 1칸씩(넘침 잘림)
    try std.testing.expectEqual(@as(u16, 0), paneTabWidth(0, 2));
    try std.testing.expectEqual(@as(u16, 0), paneTabWidth(20, 0));
}

test "tabLayout: rich 넘침 ‹›·tab_cols 축소·scroll clamp; tui·안넘침 무스크롤" {
    // cols=40, "+"zone 3 → base=paneTabAreaCols(40)=37. 고정폭 16, 3탭 → total=48 > 37 → has_scroll, tab_cols=35.
    const ovf = tabLayout(40, 3, 16, 0);
    try std.testing.expect(ovf.has_scroll);
    try std.testing.expectEqual(@as(u16, 34), ovf.tab_cols); // 37 - 3(‹·gap·›)
    try std.testing.expectEqual(@as(u16, 16), ovf.tab_w);
    try std.testing.expectEqual(@as(u32, 0), ovf.eff_scroll); // scroll 0
    // #1: 큰 scroll(stale 등)은 max(=total 48-tab_cols 34=14)로 clamp.
    try std.testing.expectEqual(@as(u32, 14), tabLayout(40, 3, 16, 100).eff_scroll);
    // 2탭 → total=32 <= 37 → no scroll, tab_cols=37(그대로), eff 0(stale 무시).
    const fit = tabLayout(40, 2, 16, 50);
    try std.testing.expect(!fit.has_scroll);
    try std.testing.expectEqual(@as(u16, 37), fit.tab_cols);
    try std.testing.expectEqual(@as(u32, 0), fit.eff_scroll);
    // #4: tui(fixed 0)는 탭 많아 tab_w=1 collapse여도 has_scroll=false(균등, 스크롤 안 함 — tui 무변화).
    try std.testing.expect(!tabLayout(40, 12, 0, 0).has_scroll);
}

test "buildSidebarDrawList truncates to cols and advances wide glyphs by two columns" {
    const allocator = std.testing.allocator;
    // cols=5: "abcdefg"는 5칸까지만(자름). 와이드 글자는 2칸 전진.
    const titles = [_][]const u8{ "abcdefg", "한A" };
    var draw_list = try buildSidebarDrawList(allocator, &titles, 5, .default, null, null, null, .default);
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
    try std.testing.expectEqual(@as(usize, 5), row0); // 7글자 중 5칸까지만(말줄임 …)
    // "한"(와이드, width 2)이 col 0, 다음 'A'가 col 2(2칸 전진).
    try std.testing.expectEqual(@as(u16, 0), row1_cols[0]);
    try std.testing.expectEqual(@as(u16, 2), row1_cols[1]);
}

// 긴 제목은 하드 컷이 아니라 마지막 칸에 "…"(U+2026)를 둬 말줄임된다(사이드바·pane 탭 바 공유 규칙). 짧으면 없음.
test "long titles are ellipsized with U+2026 at the last cell; short titles are not" {
    const allocator = std.testing.allocator;
    // 사이드바: "abcdefg"(7) cols=5 → 'a','b','c','d','…'. 마지막 셀 = U+2026.
    {
        const titles = [_][]const u8{"abcdefg"};
        var dl = try buildSidebarDrawList(allocator, &titles, 5, .default, null, null, null, .default);
        defer dl.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 5), dl.cells.len);
        try std.testing.expectEqual(title_ellipsis_glyph, dl.cells[4].codepoint); // 마지막 = …
        try std.testing.expectEqual(@as(u16, 4), dl.cells[4].col);
        for (dl.cells[0..4]) |c| try std.testing.expect(c.codepoint != title_ellipsis_glyph); // 앞은 글자
    }
    // 딱 맞으면 말줄임 없음.
    {
        const titles = [_][]const u8{"abcde"}; // 5칸 = cols
        var dl = try buildSidebarDrawList(allocator, &titles, 5, .default, null, null, null, .default);
        defer dl.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 5), dl.cells.len);
        for (dl.cells) |c| try std.testing.expect(c.codepoint != title_ellipsis_glyph);
    }
    // pane 탭 바: 긴 제목도 세그먼트 한도에서 … . cols=11 → 탭 영역 8, 2탭 → tab_w=4, 탭 0 제목 칸 [1,4) = 3칸.
    {
        const titles = [_][]const u8{ "abcdef", "x" };
        var dl = try buildPaneTabBarDrawList(allocator, &titles, 11, .default, null, null, .default, 0, 0);
        defer dl.deinit(allocator);
        var saw_ellipsis = false;
        for (dl.cells) |c| {
            if (c.codepoint == title_ellipsis_glyph) {
                saw_ellipsis = true;
                try std.testing.expectEqual(@as(u16, 3), c.col); // 탭 0 [1,4)의 마지막 칸
            }
        }
        try std.testing.expect(saw_ellipsis);
    }
}

// 활성 탭(행/세그먼트) 제목은 active_fg + bold, 나머지는 fg + regular로 그려지는지 — 활성 탭 글자 강조.
// 색(active_fg)과 무게(bold)를 함께 확인한다. bold는 셰이퍼가 bold 폰트 face를 고르는 신호다.
test "active tab/row title is drawn with active_fg and bold; others with fg and regular" {
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
    const bright: terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } };
    // 사이드바: active_row=1 → 행 1 글자만 bright + bold, 행 0은 dim + regular.
    {
        const titles = [_][]const u8{ "ab", "cd" };
        var dl = try buildSidebarDrawList(allocator, &titles, 10, dim, null, null, 1, bright);
        defer dl.deinit(allocator);
        for (dl.cells) |c| {
            const active = c.row == 1;
            try std.testing.expectEqual(if (active) bright else dim, c.style.foreground);
            try std.testing.expectEqual(active, c.style.bold);
        }
    }
    // pane 탭 바: active_tab=1 → 탭 1(우측 세그먼트) 글자만 bright + bold. cols=20 → tab_w=8, 탭 0 [1,8), 탭 1 [9,16).
    {
        const titles = [_][]const u8{ "sh", "vim" };
        var dl = try buildPaneTabBarDrawList(allocator, &titles, 20, dim, null, 1, bright, 0, 0);
        defer dl.deinit(allocator);
        var saw_bright = false;
        var saw_dim = false;
        for (dl.cells) |c| {
            if (c.codepoint == '+') continue; // "+" 버튼은 fg
            if (c.col >= 9) { // 탭 1 세그먼트(활성)
                try std.testing.expectEqual(bright, c.style.foreground);
                try std.testing.expect(c.style.bold);
                saw_bright = true;
            } else if (c.col >= 1) { // 탭 0 세그먼트(비활성)
                try std.testing.expectEqual(dim, c.style.foreground);
                try std.testing.expect(!c.style.bold);
                saw_dim = true;
            }
        }
        try std.testing.expect(saw_bright and saw_dim);
    }
}

// #3: 넘침 스크롤 시 ‹/›를 스크롤 여지 있는 방향만 active_fg(강조)·없는 방향(경계)은 fg(muted)로 그린다 —
// ‹가 진하면 "왼쪽에 잘린 탭 더 있음"을 알리는 단서(부분 탭 좌측 잘림 cue). cols=40·고정폭16·3탭 → total=48, tab_cols=34, max_scroll=14.
test "scroll ‹/› highlight only the scrollable direction (boundary uses muted fg)" {
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } }; // fg(muted)
    const bright: terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }; // active_fg(강조)
    const titles = [_][]const u8{ "a", "b", "c" };
    // scroll=0(맨 왼쪽): ‹ 흐림(왼쪽 끝), › 강조(오른쪽 더 있음).
    {
        var dl = try buildPaneTabBarDrawList(allocator, &titles, 40, dim, null, null, bright, 16, 0);
        defer dl.deinit(allocator);
        var saw_l = false;
        var saw_r = false;
        for (dl.cells) |c| {
            if (c.codepoint == '<') {
                try std.testing.expectEqual(dim, c.style.foreground);
                saw_l = true;
            }
            if (c.codepoint == '>') {
                try std.testing.expectEqual(bright, c.style.foreground);
                saw_r = true;
            }
        }
        try std.testing.expect(saw_l and saw_r);
    }
    // scroll=14(맨 오른쪽=max_scroll): ‹ 강조(왼쪽 더 있음), › 흐림(오른쪽 끝).
    {
        var dl = try buildPaneTabBarDrawList(allocator, &titles, 40, dim, null, null, bright, 16, 14);
        defer dl.deinit(allocator);
        var saw_l = false;
        var saw_r = false;
        for (dl.cells) |c| {
            if (c.codepoint == '<') {
                try std.testing.expectEqual(bright, c.style.foreground);
                saw_l = true;
            }
            if (c.codepoint == '>') {
                try std.testing.expectEqual(dim, c.style.foreground);
                saw_r = true;
            }
        }
        try std.testing.expect(saw_l and saw_r);
    }
    // scroll=7(중간): 양방향 더 있음 → ‹·› 둘 다 강조.
    {
        var dl = try buildPaneTabBarDrawList(allocator, &titles, 40, dim, null, null, bright, 16, 7);
        defer dl.deinit(allocator);
        for (dl.cells) |c| {
            if (c.codepoint == '<' or c.codepoint == '>') try std.testing.expectEqual(bright, c.style.foreground);
        }
    }
}

test "buildSidebarDrawList adds a close glyph at the hovered row's right edge only" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{ "a", "b" };
    // 호버 행 1 → ✕가 row 1, col cols-2=8에 하나 추가된다.
    var hovered = try buildSidebarDrawList(allocator, &titles, 10, .default, 1, null, null, .default);
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
    var none = try buildSidebarDrawList(allocator, &titles, 10, .default, null, null, null, .default);
    defer none.deinit(allocator);
    for (none.cells) |c| try std.testing.expect(c.codepoint != sidebar_close_glyph);

    // 범위 밖 close_row(탭 수 이상)는 무시 — ✕ 없음.
    var oob = try buildSidebarDrawList(allocator, &titles, 10, .default, 5, null, null, .default);
    defer oob.deinit(allocator);
    for (oob.cells) |c| try std.testing.expect(c.codepoint != sidebar_close_glyph);
}

test "buildSidebarDrawList draws a '+' button row below the tabs when plus_row is set" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{ "sh", "vim" }; // 탭 2개 → "+"는 행 2
    var dl = try buildSidebarDrawList(allocator, &titles, 10, .default, null, titles.len, null, .default);
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
    var no_plus = try buildSidebarDrawList(allocator, &titles, 10, .default, null, null, null, .default);
    defer no_plus.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 2), no_plus.size.rows);
    for (no_plus.cells) |c| try std.testing.expect(c.codepoint != '+');
}

// buildFloatingTabDrawList가 한 행 박스(모든 col에 bg 셀) + 제목(1칸 패딩 뒤)을 만드는지 — floating 탭 미리보기.
test "buildFloatingTabDrawList fills a one-row box with the title" {
    const allocator = std.testing.allocator;
    const fg: terminal.Color = .{ .rgb = .{ .r = 0xEE, .g = 0xEE, .b = 0xEE } };
    const bg: terminal.Color = .{ .rgb = .{ .r = 0x33, .g = 0x44, .b = 0x55 } };
    var dl = try buildFloatingTabDrawList(allocator, "sh", 8, fg, bg);
    defer dl.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 8), dl.size.cols);
    try std.testing.expectEqual(@as(u16, 1), dl.size.rows);
    // 모든 셀이 row 0·박스 bg, col 0..7을 채운다(중복 없음 — col당 1셀). 제목 's','h'는 col 1,2.
    try std.testing.expectEqual(@as(usize, 8), dl.cells.len);
    for (dl.cells) |c| {
        try std.testing.expectEqual(@as(u16, 0), c.row);
        try std.testing.expectEqual(bg, c.style.background); // 솔리드 박스
    }
    try std.testing.expectEqual(@as(u21, 's'), dl.cells[1].codepoint); // 1칸 패딩 뒤
    try std.testing.expectEqual(@as(u21, 'h'), dl.cells[2].codepoint);
    try std.testing.expectEqual(@as(u21, ' '), dl.cells[0].codepoint); // 좌패딩
    // 폭보다 긴 제목은 하드 컷이 아니라 마지막 칸을 "…"로 말줄임한다(사이드바·pane 탭 바와 같은 규칙).
    var narrow = try buildFloatingTabDrawList(allocator, "abcdefghij", 5, fg, bg);
    defer narrow.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), narrow.cells.len); // col 0..4 (좌패딩 + a,b,c + …)
    // 마지막 셀(우측 끝 col 4)이 "…"(U+2026)다 — 잘렸음을 표시. 박스 bg는 유지된다.
    const last = narrow.cells[narrow.cells.len - 1];
    try std.testing.expectEqual(title_ellipsis_glyph, last.codepoint);
    try std.testing.expectEqual(@as(u16, 4), last.col);
    try std.testing.expectEqual(bg, last.style.background);
    // 딱 맞는 제목은 "…" 없이 박스를 채운다(좌패딩 + 'o','k' + 남은 bg 5칸 = 8).
    var exact = try buildFloatingTabDrawList(allocator, "ok", 8, fg, bg);
    defer exact.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 8), exact.cells.len);
    for (exact.cells) |c| try std.testing.expect(c.codepoint != title_ellipsis_glyph);
}

test "buildFromDrawList shapes a synthesized sidebar draw list into glyph cells (shared atlas seam)" {
    // 사이드바 제목 패스가 터미널과 같은 seam(shape→raster→RenderFrame)을 탄다. fake bridge로
    // 합성 DrawList가 glyph까지 닿는지 고정한다 — 실제 CoreText 없이 연결 계약만 검증.
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{"ab"};
    const draw_list = try buildSidebarDrawList(allocator, &titles, 10, .default, null, null, null, .default);

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
