//! 파일 패널 전역 도크의 순수 기하. 창 backing px에서 터미널·도크·divider·tab/header/content rect를 한 번에
//! 파생해 렌더·hit-test·WKWebView 전이가 같은 좌표를 소비하게 한다. AppKit/renderer/PTY 의존은 없다.

const std = @import("std");
const dock_panel = @import("dock_panel.zig");
const layout_math = @import("layout_math.zig");
const Rect = @import("split_tree.zig").Rect;

pub const default_right_pt: u32 = 420;
pub const default_bottom_pt: u32 = 300;
pub const min_right_pt: u32 = 240;
pub const min_bottom_pt: u32 = 160;
pub const default_tree_cols: u32 = 18;
pub const min_tree_cols: u32 = 12;
/// Artifact에서 Markdown 본문은 tree보다 우선하는 주 surface다. 12칸짜리 세로 띠까지 줄이던 기존 하한은
/// 문서/편집기를 사실상 못 쓰게 하므로 28칸을 보장하고, 공간이 모자라면 tree를 먼저 숨긴다.
pub const min_editor_cols: u32 = 28;
/// Artifact의 editor tab처럼 파일 수가 적을 때 바 전체를 균등분할하지 않고 읽을 수 있는 고정폭 세그먼트를 쓴다.
/// 탭이 많아 공간이 모자랄 때만 균등 축소한다(가로 스크롤은 후속).
pub const default_tab_cols: u16 = 18;
/// dock Zig divider target을 넓히는 최대 logical-point 폭. native에는 이 값을 그대로 내리지 않고,
/// `AppSession.collectWebSurfaces`가 최종 padded frame과 이 target의 edge별 교집합만 ABI로 전달한다.
pub const divider_grab_band_pt: u32 = 10;

/// 위 최대 logical 폭을 Zig backing-pixel target으로 올림 변환한다. native pass-through는 이 target과
/// final WebView frame의 교집합만 소비해 1x/분수/2x에서도 resize target 밖 dead band를 만들지 않는다.
pub fn dividerGrabBandPx(scale_milli: u32) u32 {
    const scale = if (scale_milli == 0) 1000 else scale_milli;
    return @intCast((@as(u64, divider_grab_band_pt) * scale + 999) / 1000);
}

pub const Geometry = struct {
    /// 사이드바와 titlebar strip만 제외한 전체 작업영역. terminal·divider·dock의 합이며 전역 모달 중심의 권위다.
    workspace: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    terminal: Rect,
    dock: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    divider: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// 그룹 split tree가 차지하는 도크 좌측 영역. 우측 project tree와 독립이며 각 leaf가 자기 tab/header/content
    /// chrome을 파생한다. 단일 그룹에서도 같은 함수를 써 렌더와 hit-test 좌표를 일치시킨다.
    editor: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    tab_bar: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    header: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    tree: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// editor와 project tree 사이의 1px 시각 경계. hit target은 `treeDividerHitRect`가 별도로 넓힌다.
    tree_divider: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Artifact의 독립 탐색기 chrome. tree 전체 배경 안에서 제목 한 행과 실제 스크롤 rows를 분리해,
    /// 첫 project root가 제목처럼 보이거나 최근 파일에 밀리지 않게 한다.
    tree_header: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    tree_content: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    content: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    dock_size_px: u32 = 0,
};

pub const TabMetrics = struct {
    cols: u16,
    tab_cols: u16,
    tab_width: u16,
};

pub const TabCellLayout = struct {
    start: u16,
    end: u16,
    title_start: u16,
    title_end: u16,
    close_col: u16,
};

pub const TabScroll = struct {
    tab_width: u16, // 탭 하나의 고정 폭(default_tab_cols)
    has_scroll: bool, // 전체 탭 폭 > tab_cols(넘침)
    eff_scroll: u32, // [0,max_scroll]로 clamp된 실제 스크롤(stale 요청값 자동 정정)
    max_scroll: u32, // 최대 스크롤(넘칠 때만 >0)
};

/// 도크 탭 바 가로 스크롤 메트릭의 단일 출처. 탭은 고정폭(default_tab_cols)이라 total>tab_cols면 넘쳐 스크롤한다.
/// scroll_cols(요청값)를 [0,max]로 clamp하므로 창 크기·탭 수가 바뀌어 생긴 stale 값이 자동 정정된다(터미널
/// barMetrics와 동형). 셀·탭 0이면 null(호출자가 탭 처리 건너뜀).
pub fn dockTabScroll(tab_cols: u16, entry_count: usize, scroll_cols: u32) ?TabScroll {
    if (tab_cols == 0 or entry_count == 0) return null;
    const count: u32 = @intCast(@min(entry_count, std.math.maxInt(u16)));
    const tab_width: u16 = default_tab_cols;
    const total: u32 = count * @as(u32, tab_width);
    const has_scroll = total > tab_cols;
    const max_scroll: u32 = if (has_scroll) total - tab_cols else 0;
    return .{
        .tab_width = tab_width,
        .has_scroll = has_scroll,
        .eff_scroll = @min(scroll_cols, max_scroll),
        .max_scroll = max_scroll,
    };
}

/// cell-space 탭 레이아웃의 단일 출처. CoreText title/X와 px-space tabRect/tabCloseRect가 같은 결과를 쓴다. 탭은
/// 고정폭이고 scroll_cols만큼 좌측으로 밀린다(넘칠 때만). 좌·우로 완전히 스크롤아웃된 탭은 null(호출자는 렌더에서
/// continue, 히트테스트에서 miss). 부분 클립(좌단·우단 걸침)은 보이는 구간만 반환한다.
pub fn tabCellLayout(tab_cols: u16, entry_count: usize, index: usize, scroll_cols: u32) ?TabCellLayout {
    if (index >= entry_count) return null;
    const ts = dockTabScroll(tab_cols, entry_count, scroll_cols) orelse return null;
    const abs_start: u32 = @as(u32, @intCast(index)) * @as(u32, ts.tab_width);
    // 화면 컬럼 = 절대 컬럼 - eff_scroll(saturating). 좌측 스크롤아웃은 0, 우측은 tab_cols clamp(tabbar.segCols와 동일).
    const start_u32 = @min(abs_start -| ts.eff_scroll, @as(u32, tab_cols));
    const end_u32 = @min((abs_start + ts.tab_width) -| ts.eff_scroll, @as(u32, tab_cols));
    if (end_u32 <= start_u32) return null;
    const start: u16 = @intCast(start_u32);
    const end: u16 = @intCast(end_u32);
    return .{
        .start = start,
        .end = end,
        .title_start = @min(start +| 1, end),
        .title_end = end -| 1,
        .close_col = end - 1,
    };
}

/// 헤더 우측의 읽기/소스 편집 토글+dirty 표시 영역. 경로는 이 rect 왼쪽까지만 그린다. 폭이 너무 좁으면
/// 최소 6칸으로 줄여도 토글 hit target은 유지한다.
pub const header_control_cols: u32 = 18;

pub const HeaderCellLayout = struct {
    control_start: u16,
    mode_end: u16,
    dirty_col: ?u16,
    conflict_col: ?u16,
};

pub const HeaderModeDescriptor = struct {
    mode: dock_panel.Mode,
    label: []const u8,
};

/// ABI ordinal과 독립인 헤더 시각 순서와 label의 단일 출처. **라이브 프리뷰는 백로그(2026-07-22 사용자 결정)**라
/// markdown·svg 모두 `읽기|소스`만 노출한다. 라이브 재도입 시 여기 `.live_preview`("라이브")를 다시 넣고 markdown을
/// 별도 리스트로 분기한다. kind가 늘어나면 여기 모드 리스트만 더한다 — layout/render/hit-test는 `modesForKind`를 순회한다.
pub const header_modes = [_]HeaderModeDescriptor{
    .{ .mode = .read, .label = "읽기" },
    .{ .mode = .source_edit, .label = "소스" },
};

/// 이 kind가 헤더에 노출하는 mode 선택지(순서=시각 순서). 빈 슬라이스면 mode 선택기가 없다(html·text·image·pdf).
pub fn modesForKind(kind: dock_panel.EntryKind) []const HeaderModeDescriptor {
    return switch (kind) {
        .markdown, .svg => &header_modes,
        .html, .text, .image, .pdf => &.{},
    };
}

fn modeSlotForKind(kind: dock_panel.EntryKind, mode: dock_panel.Mode) ?usize {
    for (modesForKind(kind), 0..) |descriptor, slot| if (descriptor.mode == mode) return slot;
    return null;
}

pub const HeaderModeCellRange = struct { start: u16, end: u16 };

/// mode selector 폭을 kind의 mode 개수로 균등 분할한 한 슬롯의 cell 범위. markdown=1/3씩, svg=1/2씩. 마지막 슬롯은
/// 반올림 잔여를 흡수해 정확히 `mode_end`에서 끝난다.
pub fn headerModeCellRange(layout: HeaderCellLayout, kind: dock_panel.EntryKind, mode: dock_panel.Mode) ?HeaderModeCellRange {
    const modes = modesForKind(kind);
    if (modes.len == 0) return null;
    const idx = modeSlotForKind(kind, mode) orelse return null;
    const width: u16 = layout.mode_end - layout.control_start;
    const count: u16 = @intCast(modes.len);
    const start = layout.control_start + @as(u16, @intCast((@as(u32, width) * idx) / count));
    const end = if (idx + 1 == modes.len)
        layout.mode_end
    else
        layout.control_start + @as(u16, @intCast((@as(u32, width) * (idx + 1)) / count));
    return .{ .start = start, .end = end };
}

/// Header render/background/hit-test가 공유하는 cell 권위. 각 status는 glyph 1칸+간격 1칸을 우측에서
/// 예약하며 mode rect는 status 시작 전까지만 끝난다. mode 슬롯 분할은 `headerModeCellRange`가 kind별로 한다.
pub fn headerCellLayout(cols: u16, dirty: bool, external_change: bool) ?HeaderCellLayout {
    if (cols < 6) return null;
    const control_cols: u16 = @intCast(@min(header_control_cols, cols));
    const control_start = cols - control_cols;
    const available = cols - control_start;
    var status_count: u16 = 0;
    const show_conflict = external_change and available >= 8;
    if (show_conflict) status_count += 1;
    const show_dirty = dirty and available >= 6 + (status_count + 1) * 2;
    if (show_dirty) status_count += 1;
    const mode_end = cols - status_count * 2;
    var cursor = mode_end;
    var dirty_col: ?u16 = null;
    var conflict_col: ?u16 = null;
    if (show_conflict) {
        conflict_col = cursor;
        cursor += 2;
    }
    if (show_dirty) dirty_col = cursor;
    return .{
        .control_start = control_start,
        .mode_end = mode_end,
        .dirty_col = dirty_col,
        .conflict_col = conflict_col,
    };
}

pub fn headerControlRect(g: Geometry, cell_width_px: u32) ?Rect {
    if (cell_width_px == 0 or g.header.w < cell_width_px * 6) return null;
    const cols = @min(header_control_cols, g.header.w / cell_width_px);
    const width = cols * cell_width_px;
    return .{ .x = g.header.x + g.header.w - width, .y = g.header.y, .w = width, .h = g.header.h };
}

/// 헤더 mode 선택지 한 칸의 rect(markdown `읽기|라이브|소스`·svg `읽기|소스`). 전체 control을 토글 버튼 하나로
/// 취급하지 않고 보이는 구간과 클릭되는 구간이 같은 rect를 공유한다. 모드 선택기가 없는 kind(html·text)는 null.
pub fn headerModeRect(g: Geometry, cell_width_px: u32, kind: dock_panel.EntryKind, mode: dock_panel.Mode, dirty: bool, external_change: bool) ?Rect {
    if (modesForKind(kind).len == 0) return null;
    const control = headerControlRect(g, cell_width_px) orelse return null;
    const cols: u16 = @intCast(g.header.w / cell_width_px);
    const layout = headerCellLayout(cols, dirty, external_change) orelse return null;
    const range = headerModeCellRange(layout, kind, mode) orelse return null;
    const start_col = range.start;
    const end_col = range.end;
    if (end_col <= start_col) return null;
    return .{ .x = g.header.x + @as(u32, start_col) * cell_width_px, .y = control.y, .w = @as(u32, end_col - start_col) * cell_width_px, .h = control.h };
}

pub fn headerModeAt(g: Geometry, cell_width_px: u32, kind: dock_panel.EntryKind, dirty: bool, external_change: bool, x_px: f64, y_px: f64) ?dock_panel.Mode {
    for (modesForKind(kind)) |descriptor| {
        if (headerModeRect(g, cell_width_px, kind, descriptor.mode, dirty, external_change)) |r| if (layout_math.pointInRect(x_px, y_px, r)) return descriptor.mode;
    }
    return null;
}

/// 헤더 draw-list의 external-change `!` 한 칸과 같은 rect. mode 토글의 넓은 control rect보다 먼저
/// hit-test해, 충돌 표식을 누르면 편집 모드가 바뀌는 대신 명시적 disk reload 확인으로 라우팅한다.
pub fn headerConflictRect(g: Geometry, cell_width_px: u32, dirty: bool) ?Rect {
    if (cell_width_px == 0) return null;
    const cols: u16 = @intCast(g.header.w / cell_width_px);
    const layout = headerCellLayout(cols, dirty, true) orelse return null;
    const col = layout.conflict_col orelse return null;
    return .{
        .x = g.header.x + @as(u32, col) * cell_width_px,
        .y = g.header.y,
        .w = cell_width_px,
        .h = g.header.h,
    };
}

pub fn headerDirtyRect(g: Geometry, cell_width_px: u32, external_change: bool) ?Rect {
    if (cell_width_px == 0) return null;
    const cols: u16 = @intCast(g.header.w / cell_width_px);
    const layout = headerCellLayout(cols, true, external_change) orelse return null;
    const col = layout.dirty_col orelse return null;
    return .{ .x = g.header.x + @as(u32, col) * cell_width_px, .y = g.header.y, .w = cell_width_px, .h = g.header.h };
}

pub fn tabMetrics(g: Geometry, cell_width_px: u32, entry_count: usize) ?TabMetrics {
    if (cell_width_px == 0 or entry_count == 0 or g.tab_bar.w == 0) return null;
    const cols: u16 = @intCast(@min(g.tab_bar.w / cell_width_px, @as(u32, std.math.maxInt(u16))));
    if (cols < 1) return null;
    const tab_cols = cols; // 접기 버튼은 titlebar 띠 우측 dock 토글로 일원화 — 탭바는 예약 없이 전폭.
    const tab_width: u16 = default_tab_cols; // 고정폭 — 넘치면 축소 대신 가로 스크롤(dockTabScroll).
    return .{ .cols = cols, .tab_cols = tab_cols, .tab_width = tab_width };
}

pub fn tabRect(g: Geometry, cell_width_px: u32, entry_count: usize, index: usize, scroll_cols: u32) ?Rect {
    const m = tabMetrics(g, cell_width_px, entry_count) orelse return null;
    const cell = tabCellLayout(m.tab_cols, entry_count, index, scroll_cols) orelse return null;
    return .{ .x = g.tab_bar.x + @as(u32, cell.start) * cell_width_px, .y = g.tab_bar.y, .w = @as(u32, cell.end - cell.start) * cell_width_px, .h = g.tab_bar.h };
}

/// 탭 제목·hover·hit-test가 공유하는 닫기 영역. 한 칸 탭은 전체를 닫기 버튼으로 쓰고, 그보다 넓으면 우측
/// 한 칸을 예약한다. tabRect 밖을 절대 벗어나지 않는다.
pub fn tabCloseRect(g: Geometry, cell_width_px: u32, entry_count: usize, index: usize, scroll_cols: u32) ?Rect {
    const m = tabMetrics(g, cell_width_px, entry_count) orelse return null;
    const cell = tabCellLayout(m.tab_cols, entry_count, index, scroll_cols) orelse return null;
    return .{ .x = g.tab_bar.x + @as(u32, cell.close_col) * cell_width_px, .y = g.tab_bar.y, .w = cell_width_px, .h = g.tab_bar.h };
}

pub fn tabCloseIndexAt(g: Geometry, cell_width_px: u32, entry_count: usize, x_px: f64, y_px: f64, scroll_cols: u32) ?usize {
    const index = tabIndexAt(g, cell_width_px, entry_count, x_px, y_px, scroll_cols) orelse return null;
    const r = tabCloseRect(g, cell_width_px, entry_count, index, scroll_cols) orelse return null;
    return if (layout_math.pointInRect(x_px, y_px, r)) index else null;
}

pub fn tabIndexAt(g: Geometry, cell_width_px: u32, entry_count: usize, x_px: f64, y_px: f64, scroll_cols: u32) ?usize {
    if (!layout_math.pointInRect(x_px, y_px, g.tab_bar)) return null;
    const m = tabMetrics(g, cell_width_px, entry_count) orelse return null;
    const ts = dockTabScroll(m.tab_cols, entry_count, scroll_cols) orelse return null;
    const col: u32 = @intFromFloat((x_px - @as(f64, @floatFromInt(g.tab_bar.x))) / @as(f64, @floatFromInt(cell_width_px)));
    if (col >= m.tab_cols) return null;
    // 화면 컬럼 + eff_scroll = 절대 컬럼. 고정폭이므로 index = 절대 컬럼 / tab_width(tabCellLayout 역연산).
    const index: usize = @intCast((col + ts.eff_scroll) / ts.tab_width);
    return if (index < entry_count) index else null;
}

pub const Input = struct {
    backing_width_px: u32,
    backing_height_px: u32,
    sidebar_width_px: u32,
    titlebar_height_px: u32,
    cell_width_px: u32,
    cell_height_px: u32,
    scale_milli: u32,
    divider_px: u32,
    side: dock_panel.Side,
    size_pt: u32,
    tree_size_pt: u32 = 0,
    visible: bool,
};

pub fn compute(in: Input) Geometry {
    const available = Rect{
        .x = in.sidebar_width_px,
        .y = in.titlebar_height_px,
        .w = in.backing_width_px -| in.sidebar_width_px,
        .h = in.backing_height_px -| in.titlebar_height_px,
    };
    if (!in.visible or available.w == 0 or available.h == 0) return .{ .workspace = available, .terminal = available };

    const scale = if (in.scale_milli == 0) 1000 else in.scale_milli;
    const requested_pt = if (in.size_pt != 0) in.size_pt else switch (in.side) {
        .right => default_right_pt,
        .bottom => default_bottom_pt,
    };
    const requested_px = layout_math.ptToPx(requested_pt, scale);
    const divider = @min(in.divider_px, switch (in.side) {
        .right => available.w,
        .bottom => available.h,
    });
    const chrome_h = @min(in.cell_height_px, available.h);

    return switch (in.side) {
        .right => right: {
            const min_dock = layout_math.ptToPx(min_right_pt, scale);
            const min_terminal = @max(2 * in.cell_width_px, layout_math.ptToPx(320, scale));
            const max_dock = available.w -| divider -| min_terminal;
            const dock_w = @min(@max(requested_px, @min(min_dock, max_dock)), max_dock);
            if (dock_w == 0) break :right .{ .workspace = available, .terminal = available };
            const term_w = available.w -| divider -| dock_w;
            const dock_x = available.x + term_w + divider;
            const dock = Rect{ .x = dock_x, .y = available.y, .w = dock_w, .h = available.h };
            break :right fromDock(
                available,
                .{ .x = available.x, .y = available.y, .w = term_w, .h = available.h },
                dock,
                .{ .x = available.x + term_w, .y = available.y, .w = divider, .h = available.h },
                chrome_h,
                dock_w,
                in.cell_width_px,
                scale,
                in.tree_size_pt,
            );
        },
        .bottom => bottom: {
            const min_dock = layout_math.ptToPx(min_bottom_pt, scale);
            const min_terminal = @max(2 * in.cell_height_px, layout_math.ptToPx(180, scale));
            const max_dock = available.h -| divider -| min_terminal;
            const dock_h = @min(@max(requested_px, @min(min_dock, max_dock)), max_dock);
            if (dock_h == 0) break :bottom .{ .workspace = available, .terminal = available };
            const term_h = available.h -| divider -| dock_h;
            const dock_y = available.y + term_h + divider;
            const dock = Rect{ .x = available.x, .y = dock_y, .w = available.w, .h = dock_h };
            break :bottom fromDock(
                available,
                .{ .x = available.x, .y = available.y, .w = available.w, .h = term_h },
                dock,
                .{ .x = available.x, .y = available.y + term_h, .w = available.w, .h = divider },
                chrome_h,
                dock_h,
                in.cell_width_px,
                scale,
                in.tree_size_pt,
            );
        },
    };
}

fn fromDock(workspace: Rect, terminal: Rect, dock: Rect, divider: Rect, chrome_h: u32, dock_size_px: u32, cell_width_px: u32, scale_milli: u32, tree_size_pt: u32) Geometry {
    const tab_h = @min(chrome_h, dock.h);
    const header_h = @min(chrome_h, dock.h -| tab_h);
    const body_y = dock.y + tab_h + header_h;
    const body_h = dock.h -| tab_h -| header_h;
    const max_tree_w = dock.w -| min_editor_cols * cell_width_px;
    const min_tree_w = min_tree_cols * cell_width_px;
    const requested_tree_w = if (tree_size_pt == 0)
        default_tree_cols * cell_width_px
    else
        layout_math.ptToPx(tree_size_pt, scale_milli);
    const tree_w = if (max_tree_w < min_tree_w) 0 else std.math.clamp(requested_tree_w, min_tree_w, max_tree_w);
    const content_w = dock.w -| tree_w;
    // 탐색기(트리) 열은 에디터의 tab_bar+header 아래(body_y)가 아니라 **도크 최상단(dock.y)부터 전체 높이**로 둔다 —
    // VSCode식으로 "탐색기" 헤더가 에디터 탭 바("파일명")·터미널과 같은 높이(띠 바로 아래)에 붙는다. 트리는 별도 열
    // (x=dock.x+content_w)이라 에디터 chrome과 세로로 겹치지 않는다(사용자 피드백: 트리가 갭 없이 위로 올라와야).
    const tree_header_h = @min(chrome_h, dock.h);
    return .{
        .workspace = workspace,
        .terminal = terminal,
        .dock = dock,
        .divider = divider,
        .editor = .{ .x = dock.x, .y = dock.y, .w = content_w, .h = dock.h },
        // 단일 그룹의 기존 geometry도 FP8 editor 영역과 같게 둔다. 그래서 기존 single-group hit-test/테스트는
        // byte-level 호출 형태를 유지하면서 project tree 위 빈 chrome을 잘못 클릭하지 않는다.
        .tab_bar = .{ .x = dock.x, .y = dock.y, .w = content_w, .h = tab_h },
        .header = .{ .x = dock.x, .y = dock.y + tab_h, .w = content_w, .h = header_h },
        .tree = .{ .x = dock.x + content_w, .y = dock.y, .w = tree_w, .h = dock.h },
        .tree_divider = .{ .x = dock.x + content_w, .y = dock.y, .w = @min(@as(u32, 1), tree_w), .h = dock.h },
        .tree_header = .{ .x = dock.x + content_w, .y = dock.y, .w = tree_w, .h = tree_header_h },
        .tree_content = .{ .x = dock.x + content_w, .y = dock.y + tree_header_h, .w = tree_w, .h = dock.h -| tree_header_h },
        .content = .{ .x = dock.x, .y = body_y, .w = content_w, .h = body_h },
        .dock_size_px = dock_size_px,
    };
}

/// 탐색기 열의 실제 1px 경계를 양쪽으로 넓힌 마우스 target. tree가 좁은 창에서 숨겨졌으면 빈 rect다.
pub fn treeDividerHitRect(g: Geometry, hit_slop: u32) Rect {
    if (g.tree_divider.w == 0 or g.tree_divider.h == 0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    // 확장은 editor(WKWebView) 쪽만 넓힌다 — 그쪽은 WKWebView가 클릭을 삼켜 seam 통과 없이는 divider를 못 잡으므로.
    // 탐색기(우측)는 네이티브 rows라 hit_slop만큼 넓히면 좌측에 붙은 파일명 첫 셀이 리사이즈에 가려 안 열린다
    // → 우측은 divider 선(1px)까지만 잡고, 그 뒤 셀은 fileTreeRowAt으로 넘긴다.
    const start = @max(g.dock.x, g.tree_divider.x -| hit_slop);
    const end = @min(g.dock.x + g.dock.w, g.tree_divider.x +| g.tree_divider.w);
    return .{ .x = start, .y = g.tree_divider.y, .w = end -| start, .h = g.tree_divider.h };
}

/// terminal↔dock 외곽 divider의 실제 mouse target. render 선보다 넓은 영역과 bottom 쪽 비대칭 정책을
/// `dockDividerAtPoint`와 WebView native pass-through projection이 함께 소비한다.
pub fn outerDividerHitRect(g: Geometry, side: dock_panel.Side, hit_slop: u32) Rect {
    if (g.divider.w == 0 or g.divider.h == 0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    return switch (side) {
        .right => blk: {
            const start = @max(g.workspace.x, g.divider.x -| hit_slop);
            const end = @min(g.workspace.x +| g.workspace.w, g.divider.x +| g.divider.w +| hit_slop);
            break :blk .{ .x = start, .y = g.divider.y, .w = end -| start, .h = g.divider.h };
        },
        // dock 쪽은 tab/header라 WebView와 맞닿지 않고, 클릭을 훔치지 않도록 terminal 쪽만 확장한다.
        .bottom => blk: {
            const start = @max(g.workspace.y, g.divider.y -| hit_slop);
            const end = @min(g.workspace.y +| g.workspace.h, g.divider.y +| g.divider.h);
            break :blk .{ .x = g.divider.x, .y = start, .w = g.divider.w, .h = end -| start };
        },
    };
}

/// 탐색기 폭은 도크 side와 무관하게 항상 도크 오른쪽 경계에서 잰다. 포인터→pt 변환은 `sizePtForPointer` 단일
/// 출처를 재사용해 outer-dock resize와 rounding·센티널·clamp 규약이 갈리지 않게 한다(측정 시점 두 곳 중복 제거).
/// min/max clamp는 `compute`가 editor/tree 가독성 하한과 함께 단일 적용하므로, 호출자는 후보를 저장한 뒤 계산된
/// 실효 폭을 다시 권위값으로 삼는다.
pub fn treeSizePtForPointer(g: Geometry, x_px: f64, scale_milli: u32) ?u32 {
    return sizePtForPointer(g, .right, x_px, 0, scale_milli);
}

/// clamp된 실효 backing-px 폭을 다시 영속 pt로 되돌린다. **내부·max 경계는 올림** — 내림하면 1.5x처럼 px/pt가
/// 나누어떨어지지 않는 배율에서 `compute -> 저장 -> compute`마다 최대 1px씩 줄고, 올림값이 max를 1px 넘어도 다음
/// compute의 같은 max clamp가 원래 실효 폭을 복원하므로 고정점이다. 단 **min 경계(width==min_px)** 만은 올림이
/// min을 1px 넘겨 compute의 min clamp-up이 못 되돌리므로(하한에 영영 도달 못 함) **내림**해 정확히 min으로 복원한다.
/// min_px=0이면 하한 경계가 없어(outer dock resize) 항상 올림이다.
pub fn sizePtForEffectiveWidth(width_px: u32, min_px: u32, scale_milli: u32) u32 {
    const scale = if (scale_milli == 0) 1000 else scale_milli;
    const num = @as(u64, width_px) * 1000;
    const rounded = if (min_px != 0 and width_px <= min_px) num / scale else (num + (scale - 1)) / scale;
    return @intCast(@min(rounded, std.math.maxInt(u32)));
}

/// 한 DockTree leaf rect의 그룹별 chrome. global project tree 폭은 이미 `Geometry.editor`에서 빠졌으므로
/// leaf 전체 폭을 tab/header/content가 공유한다. 이 함수 결과를 기존 tab/header hit-test에 그대로 넘긴다.
pub fn groupGeometry(parent: Geometry, leaf: Rect) Geometry {
    const tab_h = @min(parent.tab_bar.h, leaf.h);
    const header_h = @min(parent.header.h, leaf.h -| tab_h);
    return .{
        .workspace = parent.workspace,
        .terminal = parent.terminal,
        .dock = leaf,
        .editor = leaf,
        .tab_bar = .{ .x = leaf.x, .y = leaf.y, .w = leaf.w, .h = tab_h },
        .header = .{ .x = leaf.x, .y = leaf.y + tab_h, .w = leaf.w, .h = header_h },
        .content = .{ .x = leaf.x, .y = leaf.y + tab_h + header_h, .w = leaf.w, .h = leaf.h -| tab_h -| header_h },
        .dock_size_px = parent.dock_size_px,
    };
}

/// 1px 경계선을 포인터로 잡기 쉽게 양쪽 hit_slop만큼 확장한다. 실제 divider draw는 pos 한 줄이고 hit rect만
/// 넓다. bounds 밖으로는 saturating clamp해 인접 도크/terminal 입력을 훔치지 않는다.
pub fn groupDividerHitRect(seg: dock_panel.DockTree.DividerSeg, hit_slop: u32) Rect {
    return groupDividerHitRectAt(seg.direction, seg.bounds, seg.pos, hit_slop);
}

/// leaf edge projection이 pointer-bearing `DividerSeg`를 만들지 않고도 실제 group divider target과 같은 기하를
/// 소비하게 하는 값 전용 코어. `groupDividerHitRect`와 WebView pass-through가 공유한다.
pub fn groupDividerHitRectAt(direction: @import("split_tree.zig").SplitDirection, bounds: Rect, pos: u32, hit_slop: u32) Rect {
    return switch (direction) {
        .horizontal => blk: {
            const start = @max(bounds.x, pos -| hit_slop);
            const end = @min(bounds.x + bounds.w, pos +| hit_slop +| 1);
            break :blk .{ .x = start, .y = bounds.y, .w = end -| start, .h = bounds.h };
        },
        .vertical => blk: {
            const start = @max(bounds.y, pos -| hit_slop);
            const end = @min(bounds.y + bounds.h, pos +| hit_slop +| 1);
            break :blk .{ .x = bounds.x, .y = start, .w = bounds.w, .h = end -| start };
        },
    };
}

pub fn groupDividerRatio(seg: dock_panel.DockTree.DividerSeg, x_px: f64, y_px: f64) ?f32 {
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    const raw: f64 = switch (seg.direction) {
        .horizontal => if (seg.bounds.w == 0) return null else (x_px - @as(f64, @floatFromInt(seg.bounds.x))) / @as(f64, @floatFromInt(seg.bounds.w)),
        .vertical => if (seg.bounds.h == 0) return null else (y_px - @as(f64, @floatFromInt(seg.bounds.y))) / @as(f64, @floatFromInt(seg.bounds.h)),
    };
    return @floatCast(@import("split_tree.zig").clampRatio(@floatCast(raw)));
}

pub fn sizePtForPointer(g: Geometry, side: dock_panel.Side, x_px: f64, y_px: f64, scale_milli: u32) ?u32 {
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    const raw: f64 = switch (side) {
        .right => @as(f64, @floatFromInt(g.dock.x + g.dock.w)) - x_px,
        .bottom => @as(f64, @floatFromInt(g.dock.y + g.dock.h)) - y_px,
    };
    const px: u32 = if (raw <= 0) 0 else @intFromFloat(@min(raw, @as(f64, @floatFromInt(std.math.maxInt(u32)))));
    const scale = if (scale_milli == 0) 1000 else scale_milli;
    // pt 0은 compute의 "미설정=기본값" 센티널이다. 라이브 드래그가 이 값을 만들면(포인터가 도크 반대 경계를 지나
    // raw<=0) divider를 끝까지 줄였는데 최소가 아니라 기본 크기로 튄다 → 최소 1을 보장하고, 실제 하한 clamp는
    // compute가 editor/tree 가독성 하한과 함께 적용한다.
    return @max(@as(u32, 1), @as(u32, @intCast((@as(u64, px) * 1000) / scale)));
}

test "right and bottom dock geometry share terminal and chrome boundaries" {
    const base = Input{ .backing_width_px = 1600, .backing_height_px = 1000, .sidebar_width_px = 240, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 2000, .divider_px = 4, .side = .right, .size_pt = 300, .visible = true };
    const right = compute(base);
    try std.testing.expectEqual(Rect{ .x = 240, .y = 40, .w = 1360, .h = 960 }, right.workspace);
    try std.testing.expectEqual(@as(u32, 600), right.dock.w);
    try std.testing.expectEqual(right.divider.x + right.divider.w, right.dock.x);
    try std.testing.expectEqual(right.tab_bar.y + right.tab_bar.h, right.header.y);
    try std.testing.expectEqual(right.header.y + right.header.h, right.content.y);
    try std.testing.expectEqual(@as(u32, 2 * 20), right.tab_bar.h + right.header.h);
    try std.testing.expectEqual(right.tree.y + right.tree_header.h, right.tree_content.y);
    try std.testing.expectEqual(right.tree.h, right.tree_header.h + right.tree_content.h);

    const bottom = compute(.{ .backing_width_px = base.backing_width_px, .backing_height_px = base.backing_height_px, .sidebar_width_px = base.sidebar_width_px, .titlebar_height_px = base.titlebar_height_px, .cell_width_px = base.cell_width_px, .cell_height_px = base.cell_height_px, .scale_milli = base.scale_milli, .divider_px = base.divider_px, .side = .bottom, .size_pt = 200, .visible = true });
    try std.testing.expectEqual(right.workspace, bottom.workspace);
    try std.testing.expectEqual(@as(u32, 400), bottom.dock.h);
    try std.testing.expectEqual(bottom.divider.y + bottom.divider.h, bottom.dock.y);
    try std.testing.expectEqual(base.sidebar_width_px, bottom.dock.x);
}

test "dock geometry collapses and clamps to leave a terminal floor" {
    const hidden = compute(.{ .backing_width_px = 800, .backing_height_px = 600, .sidebar_width_px = 200, .titlebar_height_px = 30, .cell_width_px = 8, .cell_height_px = 16, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 700, .visible = false });
    try std.testing.expectEqual(@as(u32, 600), hidden.terminal.w);
    try std.testing.expectEqual(@as(u32, 0), hidden.dock.w);

    const clamped = compute(.{ .backing_width_px = 800, .backing_height_px = 600, .sidebar_width_px = 200, .titlebar_height_px = 30, .cell_width_px = 8, .cell_height_px = 16, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 700, .visible = true });
    try std.testing.expect(clamped.terminal.w >= 320);
    try std.testing.expectEqual(clamped.terminal.w + clamped.divider.w + clamped.dock.w, hidden.terminal.w);

    const damaged = compute(.{ .backing_width_px = 800, .backing_height_px = 600, .sidebar_width_px = 200, .titlebar_height_px = 30, .cell_width_px = 8, .cell_height_px = 16, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = std.math.maxInt(u32), .visible = true });
    try std.testing.expect(damaged.terminal.w >= 320); // 손상 workspace의 u32 max도 overflow 없이 실효 크기로 clamp.
    try std.testing.expectEqual(damaged.terminal.w + damaged.divider.w + damaged.dock.w, hidden.terminal.w);
}

test "resize pointer maps backing pixels to persisted points and rejects non-finite" {
    const g = compute(.{ .backing_width_px = 1200, .backing_height_px = 800, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 2000, .divider_px = 2, .side = .right, .size_pt = 300, .visible = true });
    const expected_pt: u32 = @intCast((@as(u64, g.dock_size_px + 100) * 1000) / 2000);
    try std.testing.expectEqual(@as(?u32, expected_pt), sizePtForPointer(g, .right, @floatFromInt(g.dock.x - 100), 0, 2000));
    try std.testing.expectEqual(@as(?u32, null), sizePtForPointer(g, .right, std.math.nan(f64), 0, 2000));
}

test "dock tab metrics use the full tab bar and share render hit rects" {
    const g = compute(.{ .backing_width_px = 1400, .backing_height_px = 900, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 420, .visible = true });
    const second = tabRect(g, 10, 3, 1, 0).?;
    try std.testing.expectEqual(@as(?usize, 1), tabIndexAt(g, 10, 3, @floatFromInt(second.x + 1), @floatFromInt(second.y + 1), 0));
    // 접기 버튼은 탭바에서 제거(titlebar 띠 dock 토글로 일원화) — 우측 끝도 탭 영역이다. 탭은 고정폭(스크롤 0)이라
    // 단일 탭은 default_tab_cols 폭을 그대로 갖는다.
    const one = tabRect(g, 10, 1, 0, 0).?;
    try std.testing.expectEqual(@as(u32, default_tab_cols * 10), one.w);
    try std.testing.expectEqual(@as(?usize, null), tabIndexAt(g, 10, 1, @floatFromInt(one.x + one.w + 1), @floatFromInt(one.y + 1), 0));
}

test "dock close rect sits at the visible right edge and clips on overflow" {
    // 넉넉한 탭 바(40칸): 탭은 고정폭(18칸)이라 안 잘리고, close는 탭의 우측 끝 칸(col 17)에 온다.
    const wide = Geometry{
        .terminal = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .tab_bar = .{ .x = 100, .y = 20, .w = 400, .h = 18 },
    };
    const normal = tabCloseRect(wide, 10, 2, 0, 0).?;
    try std.testing.expectEqual(Rect{ .x = 270, .y = 20, .w = 10, .h = 18 }, normal); // 100 + 17*10
    try std.testing.expectEqual(@as(?usize, 0), tabCloseIndexAt(wide, 10, 2, 275, 25, 0));
    try std.testing.expectEqual(@as(?usize, null), tabCloseIndexAt(wide, 10, 2, 105, 25, 0)); // 제목 영역 — close 아님

    // 좁은 탭 바(2칸): 고정폭 탭이 넘쳐 스크롤한다. scroll 0이면 탭 0이 [0,2)로 잘리고 close는 보이는 우측 끝(col 1).
    // 탭 1은 완전히 스크롤아웃(col 18~)이라 안 보인다.
    const narrow = Geometry{
        .terminal = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .tab_bar = .{ .x = 4, .y = 8, .w = 20, .h = 18 },
    };
    const clipped = tabCloseRect(narrow, 10, 2, 0, 0).?;
    try std.testing.expectEqual(Rect{ .x = 14, .y = 8, .w = 10, .h = 18 }, clipped); // 4 + 1*10
    try std.testing.expectEqual(@as(?usize, 0), tabCloseIndexAt(narrow, 10, 2, 15, 9, 0));
    try std.testing.expectEqual(@as(?Rect, null), tabCloseRect(narrow, 10, 2, 1, 0)); // 탭 1은 스크롤아웃
}

test "dock tab bar scrolls fixed-width tabs when they overflow" {
    // 탭 바 30칸, 탭 3개 × 18칸 = 54칸 → 넘침. dockTabScroll이 has_scroll + max_scroll=24를 보고한다.
    const g = Geometry{
        .terminal = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .tab_bar = .{ .x = 0, .y = 0, .w = 300, .h = 18 },
    };
    const ts = dockTabScroll(30, 3, 0).?;
    try std.testing.expect(ts.has_scroll);
    try std.testing.expectEqual(@as(u32, 24), ts.max_scroll); // 54 - 30
    try std.testing.expectEqual(@as(u16, default_tab_cols), ts.tab_width);

    // scroll 0: 탭 0은 [0,18) 온전, 탭 2는 [36,54)라 우측이 [36,30)로 완전 스크롤아웃.
    try std.testing.expect(tabCellLayout(30, 3, 0, 0) != null);
    try std.testing.expectEqual(@as(?TabCellLayout, null), tabCellLayout(30, 3, 2, 0));

    // scroll 24(max): 탭 2가 우측 끝에 오고, 탭 0이 [−24..−6)→완전 스크롤아웃, tabIndexAt도 좌측 miss.
    const tail = tabCellLayout(30, 3, 2, 24).?;
    try std.testing.expectEqual(@as(u16, 30), tail.end); // 우단이 탭 바 끝에 붙는다
    try std.testing.expectEqual(@as(?usize, 2), tabIndexAt(g, 10, 3, 295, 9, 24)); // 우측 끝 클릭 → 탭 2
    try std.testing.expectEqual(@as(?TabCellLayout, null), tabCellLayout(30, 3, 0, 24));

    // 요청 스크롤이 max를 넘으면 clamp(stale 자동 정정).
    try std.testing.expectEqual(@as(u32, 24), dockTabScroll(30, 3, 1000).?.eff_scroll);
}

test "dock header control rect is right-aligned and bounded on narrow docks" {
    const g = compute(.{ .backing_width_px = 1400, .backing_height_px = 900, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 420, .visible = true });
    const control = headerControlRect(g, 10).?;
    try std.testing.expectEqual(g.header.x + g.header.w, control.x + control.w);
    try std.testing.expectEqual(@as(u32, header_control_cols * 10), control.w);
    const conflict = headerConflictRect(g, 10, false).?;
    try std.testing.expectEqual(g.header.x + g.header.w - 20, conflict.x);
    try std.testing.expectEqual(@as(u32, 10), conflict.w);
    try std.testing.expect(conflict.x >= control.x);
    // markdown 헤더는 읽기|소스 2모드다(라이브 백로그).
    const read = headerModeRect(g, 10, .markdown, .read, false, false).?;
    const edit = headerModeRect(g, 10, .markdown, .source_edit, false, false).?;
    try std.testing.expectEqual(@as(?Rect, null), headerModeRect(g, 10, .markdown, .live_preview, false, false)); // 라이브 없음
    try std.testing.expectEqual(control.x, read.x);
    try std.testing.expectEqual(read.x + read.w, edit.x);
    try std.testing.expectEqual(control.x + control.w, edit.x + edit.w);
    try std.testing.expectEqual(@as(?dock_panel.Mode, .read), headerModeAt(g, 10, .markdown, false, false, @floatFromInt(read.x + 1), @floatFromInt(read.y + 1)));
    try std.testing.expectEqual(@as(?dock_panel.Mode, .source_edit), headerModeAt(g, 10, .markdown, false, false, @floatFromInt(edit.x + 1), @floatFromInt(edit.y + 1)));
    try std.testing.expectEqual(@as(?dock_panel.Mode, null), headerModeAt(g, 10, .html, false, false, @floatFromInt(edit.x + 1), @floatFromInt(edit.y + 1)));

    inline for (.{ false, true }) |dirty| inline for (.{ false, true }) |external| {
        const read_mode = headerModeRect(g, 10, .markdown, .read, dirty, external).?;
        const source = headerModeRect(g, 10, .markdown, .source_edit, dirty, external).?;
        const cells = headerCellLayout(@intCast(g.header.w / 10), dirty, external).?;
        try std.testing.expectEqual(g.header.x + @as(u32, cells.control_start) * 10, read_mode.x); // 첫 슬롯=control_start
        try std.testing.expectEqual(read_mode.x + read_mode.w, source.x); // 인접
        try std.testing.expectEqual(g.header.x + @as(u32, cells.mode_end) * 10, source.x + source.w); // 마지막=mode_end
        if (dirty) {
            const status = headerDirtyRect(g, 10, external).?;
            try std.testing.expect(headerModeAt(g, 10, .markdown, dirty, external, @floatFromInt(status.x + 1), @floatFromInt(status.y + 1)) == null);
        }
        if (external) {
            const status = headerConflictRect(g, 10, dirty).?;
            try std.testing.expect(headerModeAt(g, 10, .markdown, dirty, external, @floatFromInt(status.x + 1), @floatFromInt(status.y + 1)) == null);
        }
    };
}

test "dock header mode slots split per kind (markdown thirds, svg halves) before status" {
    const bare = headerCellLayout(6, true, true).?;
    try std.testing.expectEqual(@as(u16, 6), bare.mode_end);
    try std.testing.expectEqual(@as(?u16, null), bare.conflict_col);
    try std.testing.expectEqual(@as(?u16, null), bare.dirty_col);

    const conflict_only = headerCellLayout(8, true, true).?;
    try std.testing.expectEqual(@as(?u16, 6), conflict_only.conflict_col);
    try std.testing.expectEqual(@as(?u16, null), conflict_only.dirty_col);
    const both = headerCellLayout(10, true, true).?;
    try std.testing.expectEqual(@as(?u16, 6), both.conflict_col);
    try std.testing.expectEqual(@as(?u16, 8), both.dirty_col);

    // markdown: 3개 슬롯이 control_start..mode_end를 연속으로 덮는다.
    var md_prev: ?u16 = null;
    for (modesForKind(.markdown)) |d| {
        const range = headerModeCellRange(both, .markdown, d.mode).?;
        if (md_prev) |p| try std.testing.expectEqual(p, range.start);
        md_prev = range.end;
        try std.testing.expect(d.label.len > 0);
    }
    try std.testing.expectEqual(@as(?u16, both.mode_end), md_prev);
    // svg: 2개 슬롯(읽기·소스), 라이브 없음.
    try std.testing.expectEqual(@as(usize, 2), modesForKind(.svg).len);
    try std.testing.expect(headerModeCellRange(both, .svg, .live_preview) == null);
    const svg_read = headerModeCellRange(both, .svg, .read).?;
    const svg_source = headerModeCellRange(both, .svg, .source_edit).?;
    try std.testing.expectEqual(both.control_start, svg_read.start);
    try std.testing.expectEqual(svg_read.end, svg_source.start);
    try std.testing.expectEqual(both.mode_end, svg_source.end);
    // html·text는 mode 선택기가 없다.
    try std.testing.expectEqual(@as(usize, 0), modesForKind(.html).len);
    try std.testing.expectEqual(@as(usize, 0), modesForKind(.text).len);
}

test "dock group geometry gives every split leaf its own tab header and content" {
    const parent = compute(.{ .backing_width_px = 1400, .backing_height_px = 900, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 420, .visible = true });
    try std.testing.expectEqual(parent.content.w, parent.editor.w);
    try std.testing.expectEqual(parent.dock.h, parent.editor.h);
    const left = groupGeometry(parent, .{ .x = parent.editor.x, .y = parent.editor.y, .w = parent.editor.w / 2, .h = parent.editor.h });
    try std.testing.expectEqual(left.dock.w, left.tab_bar.w);
    try std.testing.expectEqual(left.tab_bar.y + left.tab_bar.h, left.header.y);
    try std.testing.expectEqual(left.header.y + left.header.h, left.content.y);
    try std.testing.expectEqual(left.dock.h, left.tab_bar.h + left.header.h + left.content.h);
}

test "narrow right dock preserves a readable editor and hides an unusable tree sliver" {
    const narrow = compute(.{ .backing_width_px = 1000, .backing_height_px = 800, .sidebar_width_px = 160, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 330, .visible = true });
    try std.testing.expect(narrow.editor.w >= min_editor_cols * 10);
    try std.testing.expectEqual(@as(u32, 0), narrow.tree.w);

    const artifact_width = compute(.{ .backing_width_px = 1600, .backing_height_px = 900, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 500, .visible = true });
    try std.testing.expectEqual(default_tree_cols * 10, artifact_width.tree.w);
    try std.testing.expect(artifact_width.editor.w > artifact_width.tree.w);

    const resized = compute(.{ .backing_width_px = 1600, .backing_height_px = 900, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 500, .tree_size_pt = 150, .visible = true });
    try std.testing.expectEqual(@as(u32, 150), resized.tree.w);
    try std.testing.expectEqual(resized.tree.x, resized.tree_divider.x);
    // hit target은 editor(좌) 쪽으로만 hit_slop 넓히고 tree(우) 쪽은 divider 선(1px)까지만 — 파일명 첫 셀 보존.
    try std.testing.expectEqual(Rect{ .x = resized.tree.x - 5, .y = resized.tree.y, .w = 6, .h = resized.tree.h }, treeDividerHitRect(resized, 5));
    try std.testing.expectEqual(@as(u32, 150), treeSizePtForPointer(resized, @floatFromInt(resized.tree.x), 1000).?);

    const too_wide = compute(.{ .backing_width_px = 1600, .backing_height_px = 900, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 500, .tree_size_pt = 9999, .visible = true });
    try std.testing.expectEqual(min_editor_cols * 10, too_wide.editor.w);
    const too_narrow = compute(.{ .backing_width_px = 1600, .backing_height_px = 900, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 500, .tree_size_pt = 1, .visible = true });
    try std.testing.expectEqual(min_tree_cols * 10, too_narrow.tree.w);

    // 1.5x에서 max clamp된 470px은 313.33pt다. 313pt로 내리면 다음 frame에 469px로 줄지만, 314pt 올림은
    // 다시 같은 max 470px로 clamp되어 저장/복원 고정점을 만든다.
    const scaled_max = compute(.{ .backing_width_px = 1600, .backing_height_px = 900, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 1500, .divider_px = 2, .side = .right, .size_pt = 500, .tree_size_pt = 9999, .visible = true });
    const stable_pt = sizePtForEffectiveWidth(scaled_max.tree.w, 0, 1500);
    const scaled_restored = compute(.{ .backing_width_px = 1600, .backing_height_px = 900, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 1500, .divider_px = 2, .side = .right, .size_pt = 500, .tree_size_pt = stable_pt, .visible = true });
    try std.testing.expectEqual(@as(u32, 470), scaled_max.tree.w);
    try std.testing.expectEqual(@as(u32, 314), stable_pt);
    try std.testing.expectEqual(scaled_max.tree.w, scaled_restored.tree.w);
}

test "tree resize reaches its floor and never snaps back to the default sentinel" {
    // 1.25x·셀폭 7: min tree = 12*7 = 84px, 84*1000/1250 = 67.2로 px/pt가 안 나누어떨어진다.
    const base = Input{ .backing_width_px = 1600, .backing_height_px = 900, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 7, .cell_height_px = 14, .scale_milli = 1250, .divider_px = 2, .side = .right, .size_pt = 600, .visible = true };
    const g = compute(base);
    const min_tree_px = min_tree_cols * base.cell_width_px;

    // #1: 포인터가 도크 오른쪽 경계 밖(raw<=0)이어도 pt는 센티널 0이 아니라 ≥1.
    const past_edge = treeSizePtForPointer(g, @floatFromInt(g.dock.x + g.dock.w + 30), base.scale_milli).?;
    try std.testing.expect(past_edge >= 1);
    var at_min = base;
    at_min.tree_size_pt = past_edge;
    // 기본 18칸으로 튀지 않고 정확히 12칸 하한.
    try std.testing.expectEqual(min_tree_px, compute(at_min).tree.w);

    // #4: min 실효 폭 → 영속 pt(내림) → 다시 compute가 정확히 min을 복원(1px 더 넓게 멈추지 않음, 고정점).
    const stable = sizePtForEffectiveWidth(min_tree_px, min_tree_px, base.scale_milli);
    var restored = base;
    restored.tree_size_pt = stable;
    try std.testing.expectEqual(min_tree_px, compute(restored).tree.w);
    // 올림(min 무시)이었다면 85px로 벌어져 하한을 못 밟는다 — 내림 분기가 실제로 갈리는지 대비 확인.
    try std.testing.expect(sizePtForEffectiveWidth(min_tree_px, 0, base.scale_milli) > stable);
}

test "dock group divider hit target and pointer ratio share split bounds" {
    var split: dock_panel.DockTree.Split = undefined;
    const horizontal = dock_panel.DockTree.DividerSeg{
        .split = &split,
        .direction = .horizontal,
        .bounds = .{ .x = 100, .y = 40, .w = 600, .h = 400 },
        .pos = 340,
    };
    try std.testing.expectEqual(Rect{ .x = 335, .y = 40, .w = 11, .h = 400 }, groupDividerHitRect(horizontal, 5));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), groupDividerRatio(horizontal, 400, 100).?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), groupDividerRatio(horizontal, -1000, 100).?, 0.0001);
    try std.testing.expectEqual(@as(?f32, null), groupDividerRatio(horizontal, std.math.nan(f64), 0));
}

test "dock divider grab band rounds logical points up at fractional backing scales" {
    try std.testing.expectEqual(@as(u32, 10), dividerGrabBandPx(0));
    try std.testing.expectEqual(@as(u32, 10), dividerGrabBandPx(1000));
    try std.testing.expectEqual(@as(u32, 13), dividerGrabBandPx(1250));
    try std.testing.expectEqual(@as(u32, 15), dividerGrabBandPx(1500));
    try std.testing.expectEqual(@as(u32, 20), dividerGrabBandPx(2000));
}
