//! 탐색기 트리 행의 제품 배선 — 투영 → props → build → view → paint.
//!
//! 순서는 Session Dock·SCM Dock과 **같다**. 다른 순서를 내면 한쪽만 고쳐지는 순간 조용히 갈린다.
//!
//! **이 파일이 소유하지 않는 것**: 행 모델(`session/file_tree.zig`), 창 산술
//! (`session/file_tree_layout.zig`), 스크롤바(`app_session/dock.zig`의 `buildDockListScrollTree`),
//! 아이콘 분류(`chrome/file_tree_icon.zig`). 여기는 그 넷을 컴포넌트 props로 옮기는 어댑터다.

const std = @import("std");
const maru = @import("maru");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const CollectedPane = AppSession.CollectedPane;
const coretext_frame_builder = app_session_mod.coretext_frame_builder;
const chrome_draw_lowering = app_session_mod.chrome_draw_lowering;
const metal_frame = app_session_mod.metal_frame;
const file_tree = maru.session.file_tree;
const i18n = maru.i18n;
const agent_dock = @import("agent_dock.zig");
const dock_ops = @import("dock.zig");
const file_panel_ops = @import("file_panel.zig");
const settings_ops = @import("settings.zig"); // 이름 변경 편집 글자(라벨 치환)

const component = chrome.components.file_tree;

/// 트리가 그릴 **backing 스케일**. 같은 컬럼의 다른 뷰(SCM·AI 세션)와 **같은 값**을 쓴다 — 뷰를 갈아
/// 끼울 때 행 높이가 튀면 안 된다(`scm_dock.scmDockScaleMilli`와 같은 판단).
pub fn fileTreeScaleMilli(self: *const AppSession) u32 {
    return agent_dock.agentSessionDockScaleMilli(self);
}

/// **행 높이의 단일 출처.** 예전에는 `cell_height_px`(터미널 폰트 종속)였고, 그래서 트리 밀도가
/// 사용자 `font.size`를 따라 움직였다(docs/plans/file-tree-component.md §0). 창 산술·히트테스트·렌더가
/// 전부 이 함수를 지나야 세 값이 갈리지 않는다.
///
/// **값은 셀과 무관하지만 게이트는 남는다.** 렌더 메트릭이 아직 없는 스냅샷(첫 프레임 전·폰트 로드
/// 실패)에서는 0을 준다 — 그러면 `drawWindow`가 창을 0으로 내고 히트테스트도 없는 행을 만들지 않는다.
/// 이 0은 "행이 셀 높이만 하다"는 뜻이 아니라 **"아직 그릴 수 없다"**는 뜻이고, 그 게이트가 여기 한
/// 곳에만 있어야 세 소비자가 같은 판정을 쓴다.
pub fn fileTreeRowHeightPx(self: *const AppSession) u32 {
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return 0;
    return component.types.Metrics.resolve(fileTreeScaleMilli(self)).row_h;
}

/// 도메인 행 하나를 컴포넌트 DTO로 옮긴다. **판정을 여기서 새로 만들지 않는다** — 무엇이 활성이고
/// 무엇이 무시된 행인지는 도메인이 이미 답했다.
fn projectRow(row: file_tree.Row, selected: bool, hovered: bool, ignored_known: bool) component.types.Row {
    var out: component.types.Row = .{
        .kind = .file,
        .label = "",
        .icon_kind = file_tree.rowIconKind(row),
        .selected = selected,
        .hovered = hovered,
        .ignored = ignored_known and file_tree.rowIgnored(row),
    };
    switch (row) {
        .recent_header => |v| {
            out.kind = .recent_header;
            out.label = i18n.t(.fp_recent_files);
            out.expandable = true;
            out.expanded = !v.collapsed;
        },
        .recent_file => |v| {
            out.kind = .recent_file;
            out.label = v.label;
            out.depth = v.depth;
            out.active = v.active;
            out.dirty = v.dirty;
            out.external_change = v.external_change;
        },
        .root => |v| {
            out.kind = .root;
            out.label = v.label;
            out.expandable = true;
            out.expanded = v.expanded;
            out.loading = v.loading;
        },
        .directory => |v| {
            out.kind = .directory;
            out.label = v.label;
            out.depth = v.depth;
            out.expandable = true;
            out.expanded = v.expanded;
            out.loading = v.loading;
        },
        .file => |v| {
            out.kind = .file;
            out.label = v.label;
            out.depth = v.depth;
            out.active = v.active;
            out.dirty = v.dirty;
            out.external_change = v.external_change;
        },
        .empty => {
            out.kind = .empty;
            out.label = i18n.t(.fp_open_to_show_tree);
        },
    }
    return out;
}

/// 한 프레임의 트리 그리기.
pub fn collectFileTreeDock(
    self: *AppSession,
    collected: *std.ArrayList(CollectedPane),
    builder: coretext_frame_builder.CoreTextFrameBuilder,
    colors: metal_frame.CellColors,
) void {
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return;
    const content = dock_ops.dockGeometry(self).tree_content;
    if (content.w == 0 or content.h == 0) return;
    const text_w = dock_ops.dockListTextWidthPx(self);
    if (text_w == 0) return;

    const window = file_panel_ops.fileTreeDrawWindow(self);
    if (window.count == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const start = @min(window.start, self.file_tree_rows.items.len);
    const end = @min(start + window.count, self.file_tree_rows.items.len);
    const rows_src = self.file_tree_rows.items[start..end];

    const rows = arena.alloc(component.types.Row, rows_src.len) catch return;
    // 무시 여부는 저장소를 물어봤을 때만 뜻이 있다 — 안 물어본 상태에서 흐리게 그리면 "모르는 것"이
    // "무시됨"으로 보인다(docs/file-explorer.md의 `ignored_fg` 규율과 같은 판정을 그대로 쓴다).
    const ignored_known = self.git_result != null;
    // 선택은 **신원 기반**이다(`selectedFileTreeRow`) — 비동기 재빌드로 행이 밀려도 같은 항목을 가리킨다.
    // 인덱스를 직접 비교하면 재빌드 직후 한 프레임 동안 엉뚱한 행이 선택돼 보인다.
    const selected_index = file_panel_ops.selectedFileTreeRow(self);
    // 이름 변경 중이면 그 행의 라벨을 편집 중인 글자로 바꾼다. 편집 자체(caret·키)는 FT2가 옮기지만,
    // **보이던 글자가 안 보이는 것**은 이관 중이라도 회귀다.
    const edit_text: ?[]const u8 = if (self.rename) |renaming|
        if (renaming == .file_tree) settings_ops.renameEditText(self, arena) catch null else null
    else
        null;
    const edit_identity: ?file_tree.RowIdentity = if (self.rename) |renaming|
        if (renaming == .file_tree and edit_text != null)
            .{ .kind = renaming.file_tree.row_kind, .path = renaming.file_tree.path() }
        else
            null
    else
        null;
    for (rows, rows_src, 0..) |*out, row, offset| {
        const index = start + offset;
        out.* = projectRow(
            row,
            selected_index != null and selected_index.? == index,
            self.file_tree_hovered_row == index,
            ignored_known,
        );
        if (edit_identity) |want| if (file_tree.rowIdentity(row)) |identity| {
            if (identity.eql(want)) out.label = edit_text.?;
        };
    }

    const props = component.types.Props{
        .viewport_px = .{ .width = @floatFromInt(text_w), .height = @floatFromInt(content.h) },
        .scale_milli = fileTreeScaleMilli(self),
        .rows = rows,
        .selection_focused = file_panel_ops.fileTreeFocused(self),
        .origin_shift_px = window.origin_shift_px,
    };

    const sizes = component.build.bufferSizes(rows.len);
    const frame = component.build.build(props, .{
        .nodes = arena.alloc(chrome.ui.tree.UiNode, sizes.nodes) catch return,
        .entries = arena.alloc(chrome.ui.tree.RectEntry, sizes.entries) catch return,
        .layout_items = arena.alloc(chrome.ui.layout.Item, sizes.entries) catch return,
        .flex_scratch = arena.alloc(chrome.ui.layout.FlexScratch, sizes.entries) catch return,
        .child_rects = arena.alloc(chrome.ui.layout.UiRect, sizes.entries) catch return,
    }) catch return;

    // 예산 산술은 **방출하는 쪽(component)**이 소유한다 — 여기서 세면 view가 op을 하나 더할 때마다
    // 조용히 낡고, 그 증상은 트리 전체가 빈 화면이다.
    const budget = component.view.bufferSizes(rows.len);
    const tokens = self.buildChromeTokens();
    const draws = component.view.view(props, frame, .{}, &tokens, .{
        .ops = arena.alloc(chrome.draw.Op, budget.ops) catch return,
        .runs = arena.alloc(chrome.draw.Run, budget.runs) catch return,
        .text_bytes = arena.alloc(u8, budget.text_bytes) catch return,
    }) catch return;

    chrome_draw_lowering.appendBackgroundQuads(self.allocator, &.{draws}, &tokens, content.x, content.y, &self.gpu_quads, 2);

    // **셀 경로를 쓰지 않는다.** SCM·Session Dock 은 여기서 `buildIconTextDrawList` 를 부르지만, 그것은
    // `wide_icons == true` 인 op 만 통과시킨다(`buildTextDrawListFiltered`). 이 컴포넌트의 텍스트·아이콘은
    // 전부 `wide_icons = false` 라 그 호출은 **빈 draw list** 를 낸다 — 매 프레임 할당만 하고 아무것도 안
    // 그렸다(적대적 검증에서 잡았다). 아이콘은 measured 경로가 그린다: `shapesTextOp` 이 `!wide_icons` 를
    // 태우고 `shapesRun` 이 `icon_in_rect` 를 명시적으로 살려 "worker 가 논리 rect 에서 SVG 를 직접 해석"
    // 한다. 그 사실을 컴포넌트 테스트가 못 박는다(`view` — 모든 op 이 measured 대상이다).
    const cols: u16 = @intCast(@min(text_w / self.cell_width_px, std.math.maxInt(u16)));
    const cell_rows: u16 = @intCast(@min(content.h / self.cell_height_px, std.math.maxInt(u16)));

    const scale = props.scale_milli;
    const scroll_origin_y_px: i32 = -@as(i32, @intCast(@min(window.origin_shift_px, std.math.maxInt(i32))));
    const base_fingerprint = chrome_draw_lowering.richTextFingerprint(
        draws.ops,
        &tokens,
        self.cell_width_px,
        self.cell_height_px,
        cols,
        cell_rows,
        scroll_origin_y_px,
    );
    const fingerprint = base_fingerprint ^ (@as(u64, scale) *% 0x9e3779b185ebca87);
    if (!app_session_mod.MeasuredTextCache.hit(self.file_tree_rich_text_cache, fingerprint))
        shapeFileTreeText(self, draws.ops, &tokens, fingerprint, scale, scroll_origin_y_px);
    if (self.file_tree_rich_text_cache) |*cache| {
        if (cache.fingerprint == fingerprint) {
            self.collectMeasuredTextFromCache(
                collected,
                app_session_mod.chrome_system_text.emptyDrawList(self.allocator, cache.records.len) catch return,
                cache,
                builder,
                .{ .pane = .{
                    .origin_x = content.x,
                    .origin_y = content.y,
                    .colors = colors,
                    .scroll_delta_y_px = @floatFromInt(scroll_origin_y_px - cache.scroll_origin_y_px),
                } },
            );
        }
    }
}

/// 이 프레임의 글자를 셰이핑해 캐시에 넣는다. **다음 tick으로 미루지 않는다** — 미루면 그 프레임의
/// 트리가 글자 없는 빈 목록이 된다(SCM·Session Dock과 같은 판단).
fn shapeFileTreeText(
    self: *AppSession,
    ops: []const chrome.draw.Op,
    tokens: *const chrome.Tokens,
    fingerprint: u64,
    scale_milli: u32,
    scroll_origin_y_px: i32,
) void {
    const chrome_system_text = app_session_mod.chrome_system_text;
    // face는 터미널과 같은 resolved appearance에서 온다 — 같은 화면의 다른 도크 뷰가 사용자 폰트인데
    // 여기만 시스템 UI face면 앱이 폰트 설정을 절반만 따르는 셈이다.
    var request = chrome_system_text.prepareRequest(self.allocator, fingerprint, ops, tokens, self.cell_width_px, .{
        .family = self.appearance.font.family,
        .fallback = self.appearance.font.fallback,
    }) catch return;
    defer request.deinit(self.allocator);
    var unresolved = chrome_system_text.shapeRequest(self.allocator, &request, scale_milli) catch return;
    defer unresolved.deinit(self.allocator);
    const artifact = chrome_system_text.resolveArtifact(self.allocator, &self.renderer_state.font_registry, unresolved) catch return;
    app_session_mod.MeasuredTextCache.store(&self.file_tree_rich_text_cache, self.allocator, fingerprint, artifact, scroll_origin_y_px);
}
