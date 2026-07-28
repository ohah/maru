//! 파일 패널 전역 도크의 순수 기하. 창 backing px에서 터미널·도크·divider·tab/header/content rect를 한 번에
//! 파생해 렌더·hit-test·WKWebView 전이가 같은 좌표를 소비하게 한다. AppKit/renderer/PTY 의존은 없다.

const std = @import("std");
const dock_panel = @import("dock_panel.zig");
const layout_math = @import("layout_math.zig");
const Rect = @import("split_tree.zig").Rect;

/// FP16: 도크가 **탐색기 전용**이 되면서 폭 기준이 바뀐다. 420/240pt는 editor(문서 본문) + tree를 함께
/// 담던 시절의 값이라 트리만 있는 지금은 화면을 절반 가까이 먹는다. 좌측 사이드바(카드 목록)와 같은
/// 성격의 목록 열이므로 그쪽 기본값에 맞춘다 — `theme.SidebarConfig.width_pt` 기본 180pt와 같은 값이다
/// (레이어가 달라 상수를 공유하진 못하고 값만 맞춘다, 그 필드 주석과 같은 규율).
/// 하한도 "문서를 담아야 한다"는 근거가 사라져 사이드바 하한(120pt)과 같은 자리로 내린다.
pub const default_right_pt: u32 = 180;
pub const min_right_pt: u32 = 120;
/// bottom은 가로 띠라 성격이 다르다(폭이 아니라 높이). 트리 행이 몇 줄은 보여야 하므로 그대로 둔다.
pub const default_bottom_pt: u32 = 300;
pub const min_bottom_pt: u32 = 160;
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
    /// FP16: 도크에 남은 건 탐색기뿐이라 트리가 **도크 전체**다. 옛 `editor`/`tab_bar`/`header`/`content`
    /// (그룹 split tree의 좌측 칼럼과 그 chrome)와 그 둘을 가르던 `tree_divider`는 대상이 사라져 없앴다 —
    /// 파일 탭 바·헤더 밴드는 이제 워크스페이스 pane이 소유한다(§3.1).
    tree: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Artifact의 독립 탐색기 chrome. tree 전체 배경 안에서 제목 한 행과 실제 스크롤 rows를 분리해,
    /// 첫 project root가 제목처럼 보이거나 최근 파일에 밀리지 않게 한다.
    tree_header: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    tree_content: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    dock_size_px: u32 = 0,
};

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
        .html, .text, .image, .media, .pdf => &.{},
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

/// FP16: 헤더 밴드는 도크가 아니라 **파일 Term**이 소유한다. 그래서 이 함수군은 `Geometry` 대신 호출자가
/// 계산한 밴드 rect를 받는다 — pane leaf에서 나온 rect든 옛 도크 rect든 배치 규칙은 하나다.
pub fn headerControlRect(header: Rect, cell_width_px: u32) ?Rect {
    if (cell_width_px == 0 or header.w < cell_width_px * 6) return null;
    const cols = @min(header_control_cols, header.w / cell_width_px);
    const width = cols * cell_width_px;
    return .{ .x = header.x + header.w - width, .y = header.y, .w = width, .h = header.h };
}

/// 헤더 mode 선택지 한 칸의 rect(markdown `읽기|라이브|소스`·svg `읽기|소스`). 전체 control을 토글 버튼 하나로
/// 취급하지 않고 보이는 구간과 클릭되는 구간이 같은 rect를 공유한다. 모드 선택기가 없는 kind(html·text)는 null.
pub fn headerModeRect(header: Rect, cell_width_px: u32, kind: dock_panel.EntryKind, mode: dock_panel.Mode, dirty: bool, external_change: bool) ?Rect {
    if (modesForKind(kind).len == 0) return null;
    const control = headerControlRect(header, cell_width_px) orelse return null;
    const cols: u16 = @intCast(header.w / cell_width_px);
    const layout = headerCellLayout(cols, dirty, external_change) orelse return null;
    const range = headerModeCellRange(layout, kind, mode) orelse return null;
    const start_col = range.start;
    const end_col = range.end;
    if (end_col <= start_col) return null;
    return .{ .x = header.x + @as(u32, start_col) * cell_width_px, .y = control.y, .w = @as(u32, end_col - start_col) * cell_width_px, .h = control.h };
}

pub fn headerModeAt(header: Rect, cell_width_px: u32, kind: dock_panel.EntryKind, dirty: bool, external_change: bool, x_px: f64, y_px: f64) ?dock_panel.Mode {
    for (modesForKind(kind)) |descriptor| {
        if (headerModeRect(header, cell_width_px, kind, descriptor.mode, dirty, external_change)) |r| if (layout_math.pointInRect(x_px, y_px, r)) return descriptor.mode;
    }
    return null;
}

/// 헤더 draw-list의 external-change `!` 한 칸과 같은 rect. mode 토글의 넓은 control rect보다 먼저
/// hit-test해, 충돌 표식을 누르면 편집 모드가 바뀌는 대신 명시적 disk reload 확인으로 라우팅한다.
pub fn headerConflictRect(header: Rect, cell_width_px: u32, dirty: bool) ?Rect {
    if (cell_width_px == 0) return null;
    const cols: u16 = @intCast(header.w / cell_width_px);
    const layout = headerCellLayout(cols, dirty, true) orelse return null;
    const col = layout.conflict_col orelse return null;
    return .{
        .x = header.x + @as(u32, col) * cell_width_px,
        .y = header.y,
        .w = cell_width_px,
        .h = header.h,
    };
}

pub fn headerDirtyRect(header: Rect, cell_width_px: u32, external_change: bool) ?Rect {
    if (cell_width_px == 0) return null;
    const cols: u16 = @intCast(header.w / cell_width_px);
    const layout = headerCellLayout(cols, true, external_change) orelse return null;
    const col = layout.dirty_col orelse return null;
    return .{ .x = header.x + @as(u32, col) * cell_width_px, .y = header.y, .w = cell_width_px, .h = header.h };
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
            );
        },
    };
}

fn fromDock(workspace: Rect, terminal: Rect, dock: Rect, divider: Rect, chrome_h: u32, dock_size_px: u32, cell_width_px: u32, scale_milli: u32) Geometry {
    _ = cell_width_px;
    _ = scale_milli;
    // 탐색기 헤더("탐색기" 한 행)는 도크 최상단에 붙고, 그 아래가 스크롤되는 rows다.
    const tree_header_h = @min(chrome_h, dock.h);
    return .{
        .workspace = workspace,
        .terminal = terminal,
        .dock = dock,
        .divider = divider,
        .tree = dock,
        .tree_header = .{ .x = dock.x, .y = dock.y, .w = dock.w, .h = tree_header_h },
        .tree_content = .{ .x = dock.x, .y = dock.y + tree_header_h, .w = dock.w, .h = dock.h -| tree_header_h },
        .dock_size_px = dock_size_px,
    };
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
    // FP16: 도크 = 트리 전체. 옛 editor 칼럼과 그 chrome(tab_bar/header/content)은 없다.
    try std.testing.expectEqual(right.dock, right.tree);
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

test "파일 헤더 밴드 control rect는 우측 정렬되고 좁은 밴드에서도 경계 안이다" {
    // FP16: 헤더 밴드는 파일 Term 소유라 도크 기하와 무관하다 — 밴드 rect를 직접 준다(pane이 계산한 값).
    const header: Rect = .{ .x = 400, .y = 60, .w = 600, .h = 20 };
    const control = headerControlRect(header, 10).?;
    try std.testing.expectEqual(header.x + header.w, control.x + control.w);
    try std.testing.expectEqual(@as(u32, header_control_cols * 10), control.w);
    const conflict = headerConflictRect(header, 10, false).?;
    try std.testing.expectEqual(header.x + header.w - 20, conflict.x);
    try std.testing.expectEqual(@as(u32, 10), conflict.w);
    try std.testing.expect(conflict.x >= control.x);
    // markdown 헤더는 읽기|소스 2모드다(라이브 백로그).
    const read = headerModeRect(header, 10, .markdown, .read, false, false).?;
    const edit = headerModeRect(header, 10, .markdown, .source_edit, false, false).?;
    try std.testing.expectEqual(@as(?Rect, null), headerModeRect(header, 10, .markdown, .live_preview, false, false)); // 라이브 없음
    try std.testing.expectEqual(control.x, read.x);
    try std.testing.expectEqual(read.x + read.w, edit.x);
    try std.testing.expectEqual(control.x + control.w, edit.x + edit.w);
    try std.testing.expectEqual(@as(?dock_panel.Mode, .read), headerModeAt(header, 10, .markdown, false, false, @floatFromInt(read.x + 1), @floatFromInt(read.y + 1)));
    try std.testing.expectEqual(@as(?dock_panel.Mode, .source_edit), headerModeAt(header, 10, .markdown, false, false, @floatFromInt(edit.x + 1), @floatFromInt(edit.y + 1)));
    try std.testing.expectEqual(@as(?dock_panel.Mode, null), headerModeAt(header, 10, .html, false, false, @floatFromInt(edit.x + 1), @floatFromInt(edit.y + 1)));

    inline for (.{ false, true }) |dirty| inline for (.{ false, true }) |external| {
        const read_mode = headerModeRect(header, 10, .markdown, .read, dirty, external).?;
        const source = headerModeRect(header, 10, .markdown, .source_edit, dirty, external).?;
        const cells = headerCellLayout(@intCast(header.w / 10), dirty, external).?;
        try std.testing.expectEqual(header.x + @as(u32, cells.control_start) * 10, read_mode.x); // 첫 슬롯=control_start
        try std.testing.expectEqual(read_mode.x + read_mode.w, source.x); // 인접
        try std.testing.expectEqual(header.x + @as(u32, cells.mode_end) * 10, source.x + source.w); // 마지막=mode_end
        if (dirty) {
            const status = headerDirtyRect(header, 10, external).?;
            try std.testing.expect(headerModeAt(header, 10, .markdown, dirty, external, @floatFromInt(status.x + 1), @floatFromInt(status.y + 1)) == null);
        }
        if (external) {
            const status = headerConflictRect(header, 10, dirty).?;
            try std.testing.expect(headerModeAt(header, 10, .markdown, dirty, external, @floatFromInt(status.x + 1), @floatFromInt(status.y + 1)) == null);
        }
    };
}

test "헤더 mode 슬롯은 kind별로 나뉜다 (markdown thirds, svg halves) before status" {
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

test "dock divider grab band rounds logical points up at fractional backing scales" {
    try std.testing.expectEqual(@as(u32, 10), dividerGrabBandPx(0));
    try std.testing.expectEqual(@as(u32, 10), dividerGrabBandPx(1000));
    try std.testing.expectEqual(@as(u32, 13), dividerGrabBandPx(1250));
    try std.testing.expectEqual(@as(u32, 15), dividerGrabBandPx(1500));
    try std.testing.expectEqual(@as(u32, 20), dividerGrabBandPx(2000));
}
