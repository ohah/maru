//! 소스 컨트롤 도크의 **호스트 배선**(component ↔ AppSession).
//!
//! `session/scm_view.zig`의 행 모델을 component props로 투영하고, 만들어진 tree를 그리고, 포인터를
//! 그 tree로 라우팅한다. Session Dock(`agent_dock.zig`)과 **같은 경로**를 쓴다 — 두 도크 뷰가 서로 다른
//! 배선을 가지면 같은 컬럼에서 뷰를 갈아 끼울 때 스크롤·호버·히트테스트 규칙이 갈린다.
//!
//! **여기서 행 높이를 다시 곱하지 않는다.** 기하의 단일 출처는 component의 `DockMetrics`이고, 이 파일은
//! 그 값을 스크롤 투영에 그대로 넘긴다(옛 셀 그리드 경로가 갈려서 "그린 자리와 눌리는 자리"가 어긋났다).

const std = @import("std");
const maru = @import("maru");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const CollectedPane = AppSession.CollectedPane;
const coretext_frame_builder = app_session_mod.coretext_frame_builder;
const chrome_draw_lowering = app_session_mod.chrome_draw_lowering;
const metal_frame = app_session_mod.metal_frame;
const dock_ops = @import("dock.zig");
const git_ops = @import("git.zig");
const agent_dock = @import("agent_dock.zig");
const scm_view = app_session_mod.scm_view;
const scm_row_capacity = app_session_mod.scm_row_capacity;

const component = chrome.components.scm_dock;

/// 도크 UI zoom. **Session Dock과 같은 값**을 쓴다 — 같은 컬럼의 두 뷰가 다른 축으로 커지면 뷰를
/// 갈아 끼울 때 행 높이가 튄다(docs/editor-surface-dock.md §3.5).
pub fn scmDockScaleMilli(self: *const AppSession) u32 {
    return agent_dock.agentSessionDockUiZoomMilli(self);
}

/// 스크롤 투영의 항목 열. 높이는 component가 정하고(`DockMetrics.itemHeight`) 이 구조체는 그 함수를
/// 인덱스로 부를 수 있게만 감싼다.
pub const ScrollItems = struct {
    items: []const component.types.Item,
    metrics: component.types.DockMetrics,

    pub fn heightPx(self: ScrollItems, index: usize) u32 {
        if (index >= self.items.len) return 0;
        return self.metrics.itemHeight(self.items[index]);
    }

    pub fn extent(self: ScrollItems, viewport_h_px: u32) chrome.ui.scroll_area.Extent {
        return .{ .count = self.items.len, .gap_px = 0, .viewport_h_px = viewport_h_px };
    }
};

/// 목록 뷰포트 높이 = 도크 content에서 고정 chrome(요약 줄·브랜치 줄)을 뺀 것.
fn listViewportHeightPx(self: *const AppSession, has_branch: bool) u32 {
    const content = dock_ops.dockGeometry(self).tree_content;
    const m = component.types.DockMetrics.resolve(scmDockScaleMilli(self));
    const fixed = m.summary_h + if (has_branch) m.branch_h else 0;
    return content.h -| fixed;
}

/// 모델 행 하나를 component 항목으로 옮긴다. **문자열은 복사하지 않는다** — `git_result`가 이 프레임
/// 동안 살아 있고, component는 immutable snapshot만 읽는다.
fn itemFor(row: scm_view.Row, model_index: usize, selected_row: ?usize, collapsed: [scm_view.section_count]bool) component.types.Item {
    return switch (row) {
        .section => |section| .{ .section = .{
            .section = sectionOf(section.section),
            .count = @intCast(section.count),
            .collapsed = collapsed[@intFromEnum(section.section)],
            // **행 동작은 아직 켜지 않는다.** `+`/`−`는 git **쓰기**라 P2의 안전 계약
            // (docs/editor-surface-dock-write.md)이 먼저 있어야 한다. component는 이미 그릴 수 있지만,
            // 눌러도 아무 일 없는 컨트롤을 화면에 두지 않는 것이 이 문서의 규칙이다.
            .action = .none,
        } },
        .file => |file| .{ .file = .{
            .name = std.fs.path.basename(file.path),
            .dir = file.path[0 .. file.path.len - std.fs.path.basename(file.path).len],
            .status = statusOf(file),
            .letter = file.letter,
            .added = file.added,
            .removed = file.removed,
            .has_delta = !file.unknown_delta and !file.binary,
            .binary = file.binary,
            .action = .none, // 위와 같은 이유(P2)
            .selected = selected_row != null and selected_row.? == model_index,
        } },
        .more => |more| .{ .more = .{ .section = sectionOf(more.section), .hidden = @intCast(more.hidden) } },
        .notice => |notice| .{ .notice = notice.text() },
    };
}

fn sectionOf(section: scm_view.Section) component.types.Section {
    // 값 집합이 갈리면 이 switch가 컴파일에서 걸린다(component는 session 모듈을 import하지 않는다).
    return switch (section) {
        .staged => .staged,
        .changes => .changes,
    };
}

fn statusOf(file: scm_view.FileRow) component.types.StatusKind {
    if (file.conflicted) return .conflicted;
    if (file.untracked) return .added; // 새로 생긴 것과 같은 계열(§3.5.2)
    return switch (file.letter) {
        'A', 'C' => .added,
        'D' => .deleted,
        else => .modified,
    };
}

/// 모델 행 하나의 높이. **정책은 component의 `itemHeight`가 소유한다** — 여기서 숫자를 다시 고르면
/// 스크롤 상한과 그린 자리가 갈린다. 그래서 높이 계산에 필요한 최소 항목을 만들어 그 함수에 묻는다.
fn rowHeightPx(m: component.types.DockMetrics, row: scm_view.Row) u32 {
    const probe: component.types.Item = switch (row) {
        .section => .{ .section = .{ .section = .changes, .count = 0, .collapsed = false, .action = .none } },
        .file => .{ .file = .{ .name = "", .dir = "", .status = .modified, .letter = 'M', .action = .none } },
        .more => .{ .more = .{ .section = .changes, .hidden = 0 } },
        .notice => .{ .notice = "" },
    };
    return m.itemHeight(probe);
}

pub const Extent = struct { content_h_px: u32, viewport_h_px: u32, max_offset_px: u32 };

/// 목록 스크롤 상한. 휠·클램프가 이 값을 쓰고, 렌더는 같은 기하를 `project`로 다시 받는다.
pub fn scrollExtent(self: *AppSession) Extent {
    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const m = component.types.DockMetrics.resolve(scmDockScaleMilli(self));
    const model = git_ops.buildScmModel(self, &rows_buf, &scratch) orelse
        return .{ .content_h_px = 0, .viewport_h_px = listViewportHeightPx(self, false), .max_offset_px = 0 };
    var content: u32 = 0;
    for (model.rows) |row| content +|= rowHeightPx(m, row);
    const has_branch = model.head.detached or model.head.branch != null;
    const viewport = listViewportHeightPx(self, has_branch);
    return .{ .content_h_px = content, .viewport_h_px = viewport, .max_offset_px = content -| viewport };
}

pub const Projection = struct {
    items: []const component.types.Item,
    scroll: chrome.ui.scroll_area.Projection,
    branch: []const u8,
    ahead: u32,
    behind: u32,
    has_ab: bool,
    summary: component.types.Summary,
};

/// 모델 → 항목 열 + 스크롤 투영. **렌더와 포인터가 같은 함수를 지난다** — 두 곳이 각자 만들면 스크롤한
/// 뒤 누른 행과 열리는 행이 어긋난다.
pub fn project(self: *AppSession, arena: std.mem.Allocator) ?Projection {
    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const model = git_ops.buildScmModel(self, &rows_buf, &scratch) orelse return null;

    const items = arena.alloc(component.types.Item, model.rows.len) catch return null;
    for (model.rows, items, 0..) |row, *item, index| {
        item.* = itemFor(row, index, self.scm_selected_row, self.scm_collapsed);
    }

    const branch: []const u8 = if (model.head.detached)
        "(detached)"
    else
        model.head.branch orelse "";
    const m = component.types.DockMetrics.resolve(scmDockScaleMilli(self));
    const list_items = ScrollItems{ .items = items, .metrics = m };
    const scroll = chrome.ui.scroll_area.project(
        list_items,
        ScrollItems.heightPx,
        list_items.extent(listViewportHeightPx(self, branch.len > 0)),
        self.scm_scroll.offset_y_px,
    );
    return .{
        .items = items,
        .scroll = scroll,
        .branch = branch,
        .ahead = model.head.ahead,
        .behind = model.head.behind,
        .has_ab = model.head.has_ab,
        .summary = .{ .added = model.total_added, .removed = model.total_removed },
    };
}

fn propsFor(self: *AppSession, projection: Projection, window: []const component.types.Item) component.types.Props {
    const content = dock_ops.dockGeometry(self).tree_content;
    return .{
        .viewport_px = .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(content.w),
            .height = @floatFromInt(content.h),
        },
        .scale_milli = scmDockScaleMilli(self),
        .snapshot_generation = self.scm_dock_snapshot_generation,
        .items = window,
        .scroll_offset_px = projection.scroll.offset_y_px,
        .content_h_px = projection.scroll.content_height_px,
        .content_first_item_origin_y_px = projection.scroll.first_origin_y_px,
        .branch = projection.branch,
        .ahead = projection.ahead,
        .behind = projection.behind,
        .has_ab = projection.has_ab,
        .summary = projection.summary,
    };
}

/// 테스트가 렌더 없이 tree를 만들 때 쓰는 표면. 제품 경로(`collectScmDock`)와 **같은 props**를 내므로
/// 테스트가 자기만의 기하를 지어내지 않는다.
pub fn testProps(self: *AppSession, projection: Projection) component.types.Props {
    const start = @min(projection.scroll.first_index, projection.items.len);
    const end = @min(projection.scroll.end_exclusive, projection.items.len);
    return propsFor(self, projection, projection.items[start..end]);
}

/// 한 프레임의 도크 그리기. Session Dock과 같은 순서다: 투영 → tree → view → 배경 quad → 글자.
pub fn collectScmDock(
    self: *AppSession,
    collected: *std.ArrayList(CollectedPane),
    builder: coretext_frame_builder.CoreTextFrameBuilder,
    colors: metal_frame.CellColors,
) void {
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return;
    const content = dock_ops.dockGeometry(self).tree_content;
    if (content.w == 0 or content.h == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const projection = project(self, arena) orelse return;
    // **가상화**: 화면에 보이는 창만 component에 넘긴다. 그 창의 첫 항목이 어디서 시작하는지는
    // 투영이 답하고, tree가 자식 전체를 그만큼 평행이동한다.
    const start = @min(projection.scroll.first_index, projection.items.len);
    const end = @min(projection.scroll.end_exclusive, projection.items.len);
    const window = projection.items[start..end];
    const props = propsFor(self, projection, window);

    const sizes = component.build.bufferSizes(window);
    const frame = component.build.build(props, .{
        .nodes = arena.alloc(chrome.ui.tree.UiNode, sizes.nodes) catch return,
        .entries = arena.alloc(chrome.ui.tree.RectEntry, sizes.entries) catch return,
        .layout_items = arena.alloc(chrome.ui.layout.Item, sizes.layout_items) catch return,
        .flex_scratch = arena.alloc(chrome.ui.layout.FlexScratch, sizes.flex_scratch) catch return,
        .child_rects = arena.alloc(chrome.ui.layout.UiRect, sizes.child_rects) catch return,
        .actions = arena.alloc(component.ids.Entry, sizes.actions) catch return,
    }) catch return;

    // paint quad는 published entry 하나당 최대 하나다. 상수로 세면 tree가 자라는 변경마다 조용히
    // 모자라는데, 그 결과가 "그 컴포넌트만 안 그려짐"이 아니라 **도크 전체 정지**다(view가 실패하면
    // 아래 publish까지 못 가서 hit tree가 이전 프레임에 멈춘다 — Session Dock에서 실제로 겪었다).
    const quad_budget = frame.tree.entries.len;
    // 행마다 최대 5개(아이콘·이름·경로·증감·상태 문자) + 요약 2 + 브랜치 3 + 호버 동작 1.
    const text_budget = window.len * 5 + 6;
    const ops = arena.alloc(chrome.draw.Op, quad_budget + text_budget) catch return;
    const runs = arena.alloc(chrome.draw.Run, text_budget) catch return;
    const text_bytes = arena.alloc(u8, 256 + window.len * 512) catch return;
    const tokens = self.buildChromeTokens();
    const draws = component.view.view(props, frame, self.scm_dock_interaction, &tokens, self.cell_width_px, .{
        .ops = ops,
        .runs = runs,
        .text_bytes = text_bytes,
    }) catch return;

    publishScmDockFrame(self, frame);

    chrome_draw_lowering.appendBackgroundQuads(self.allocator, &.{draws}, &tokens, content.x, content.y, &self.gpu_quads, 2);
    const cols: u16 = @intCast(@min(content.w / self.cell_width_px, std.math.maxInt(u16)));
    const rows: u16 = @intCast(@min(content.h / self.cell_height_px, std.math.maxInt(u16)));
    // 등록 아이콘은 셀 경로로, **일반 글자는 measured CoreText 경로**로 간다. 아이콘만 그리면 도크가
    // 배경과 화살표만 있는 빈 카드가 된다(첫 배선에서 실제로 그랬다).
    const icon_dl = chrome_draw_lowering.buildIconTextDrawList(
        self.allocator,
        draws.ops,
        &tokens,
        self.cell_width_px,
        self.cell_height_px,
        cols,
        rows,
    ) catch return;

    const scale = scmDockScaleMilli(self);
    const scroll_origin_y_px = props.content_first_item_origin_y_px;
    const base_fingerprint = chrome_draw_lowering.richTextFingerprint(
        draws.ops,
        &tokens,
        self.cell_width_px,
        self.cell_height_px,
        cols,
        rows,
        scroll_origin_y_px,
    );
    // zoom은 같은 셀 메트릭에서도 CoreText point size를 바꾸므로 fingerprint에 함께 접는다.
    const fingerprint = base_fingerprint ^ (@as(u64, scale) *% 0x9e3779b185ebca87);
    if (!app_session_mod.MeasuredTextCache.hit(self.scm_dock_rich_text_cache, fingerprint))
        shapeScmDockText(self, draws.ops, &tokens, fingerprint, scale, scroll_origin_y_px);
    if (self.scm_dock_rich_text_cache) |*cache| {
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
    self.collectShaped(collected, icon_dl, builder, .{ .pane = .{
        .origin_x = content.x,
        .origin_y = content.y,
        .colors = colors,
    } });
}

/// 이 프레임의 글자를 셰이핑해 캐시에 넣는다. **다음 tick으로 미루지 않는다** — 미루면 그 프레임의
/// 도크가 글자 없는 빈 카드가 된다(Session Dock과 같은 판단).
fn shapeScmDockText(
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
    app_session_mod.MeasuredTextCache.store(&self.scm_dock_rich_text_cache, self.allocator, fingerprint, artifact, scroll_origin_y_px);
}

/// 히트 tree 발행. 같은 스냅샷에서 같은 tree가 다시 나오는 것은 **교체가 아니다** — 그걸 교체로 치면
/// 방금 누른 행이 AppKit의 mouse-up 전에 취소된다(Session Dock과 같은 판단).
pub fn publishScmDockFrame(self: *AppSession, frame: component.build.Frame) void {
    if (frameEql(self.scm_dock_entries.items, self.scm_dock_actions.items, frame.tree.entries, frame.actions)) return;
    // 두 저장소를 **먼저** 확보한다. 할당이 실패해도 마지막으로 온전히 그린 hit tree가 남아야 한다.
    self.scm_dock_entries.ensureTotalCapacity(self.allocator, frame.tree.entries.len) catch return;
    self.scm_dock_actions.ensureTotalCapacity(self.allocator, frame.actions.len) catch return;
    self.scm_dock_entries.clearRetainingCapacity();
    self.scm_dock_actions.clearRetainingCapacity();
    self.scm_dock_entries.appendSlice(self.allocator, frame.tree.entries) catch return;
    self.scm_dock_actions.appendSlice(self.allocator, frame.actions) catch return;
    // 기하·action 매핑이 바뀌었으므로 진행 중인 capture는 더 이상 유효하지 않다.
    self.scm_dock_interaction.capture = null;
    // **세대는 여기서 올리지 않는다.** action 표는 그리기 직전의 세대로 태깅되므로, 발행 직후 올리면
    // 그 프레임의 클릭이 전부 stale로 거부된다(테스트가 "행을 눌렀는데 0개 열림"으로 잡았다).
    // 세대는 **목록이 바뀔 때**(새 git 결과·목록 폐기) 올린다 — `git.zig`가 그 지점을 소유한다.
}

fn frameEql(
    old_entries: []const chrome.ui.tree.RectEntry,
    old_actions: []const component.ids.Entry,
    new_entries: []const chrome.ui.tree.RectEntry,
    new_actions: []const component.ids.Entry,
) bool {
    if (old_entries.len != new_entries.len or old_actions.len != new_actions.len) return false;
    for (old_entries, new_entries) |old, new| {
        if (old.id != new.id) return false;
        if (old.rect.x != new.rect.x or old.rect.y != new.rect.y) return false;
        if (old.rect.width != new.rect.width or old.rect.height != new.rect.height) return false;
    }
    for (old_actions, new_actions) |old, new| {
        if (!std.meta.eql(old.intent, new.intent)) return false;
    }
    return true;
}

/// 포인터를 도크 tree로 라우팅한다. 반환된 intent는 호출자가 그 프레임에 적용한다.
pub fn scmDockPointer(
    self: *AppSession,
    phase: chrome.ui.interaction.UiPointerPhase,
    x_px: f64,
    y_px: f64,
) ?component.ids.Intent {
    if (self.dock.view != .source_control or !dock_ops.dockVisible(self)) return null;
    if (self.scm_dock_entries.items.len == 0) return null;
    const content = dock_ops.dockGeometry(self).tree_content;
    const local_x = x_px - @as(f64, @floatFromInt(content.x));
    const local_y = y_px - @as(f64, @floatFromInt(content.y));
    const tree_view = chrome.ui.tree.UiRectTree{ .entries = self.scm_dock_entries.items };
    const dispatched = chrome.ui.interaction.dispatch(
        &self.scm_dock_interaction,
        tree_view,
        .{ .phase = phase, .x_px = local_x, .y_px = local_y, .timestamp_ns = 0 },
    ) catch return null;
    // `dirty`에 무언가 들어오면 다시 그려야 한다(호버가 들어오고 나가는 것도 그림이 바뀌는 일이다).
    for (dispatched.dirty.ids) |id| {
        if (id != null) {
            self.metal_dirty = true;
            break;
        }
    }
    const action = dispatched.action orelse return null;
    var table = component.ids.Table.init(self.scm_dock_actions.items);
    table.count = self.scm_dock_actions.items.len;
    return table.resolve(action, self.scm_dock_snapshot_generation);
}

/// intent를 실제 동작으로 옮긴다. **모델 인덱스는 다시 조회한다** — intent가 든 것은 인덱스뿐이고,
/// 그 사이 목록이 갱신됐을 수 있다(늦은 클릭이 엉뚱한 파일을 열지 않게).
pub fn applyScmDockIntent(self: *AppSession, intent: component.ids.Intent) void {
    switch (intent) {
        .toggle_section => |section| {
            const index = sectionIndex(section);
            self.scm_collapsed[index] = !self.scm_collapsed[index];
            self.scm_selected_row = null; // 행 번호가 밀리므로 강조를 내린다(§ 적대적 검증 4회차)
            self.metal_dirty = true;
        },
        .expand_section => |section| {
            self.scm_expanded[sectionIndex(section)] = true;
            self.scm_selected_row = null;
            self.metal_dirty = true;
        },
        .open_row => |index| {
            var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
            var scratch: [std.fs.max_path_bytes]u8 = undefined;
            const model = git_ops.buildScmModel(self, &rows_buf, &scratch) orelse return;
            if (index >= model.rows.len) return;
            switch (model.rows[index]) {
                .file => |file| {
                    self.scm_selected_row = index;
                    self.metal_dirty = true;
                    git_ops.openDiffForScmRow(self, file);
                },
                .section, .more, .notice => {},
            }
        },
        // 행 동작(`+`/`−`)은 git 쓰기라 P2에서 붙는다. 지금은 host가 `.none`만 투영하므로 이 intent가
        // 발행되지 않지만, component가 이미 만들 수 있으므로 여기서 조용히 무시한다.
        .row_action, .section_action => {},
        .scroll_thumb, .scroll_track => {},
    }
}

fn sectionIndex(section: component.types.Section) usize {
    return switch (section) {
        .staged => @intFromEnum(scm_view.Section.staged),
        .changes => @intFromEnum(scm_view.Section.changes),
    };
}

const testing = std.testing;

test "상태 종류: 충돌·추적되지 않음·추가·삭제가 서로 다른 축으로 간다" {
    // 색은 종류가 정하고(component), 종류는 여기서 정한다 — 두 곳이 같은 판정을 하면 갈린다.
    try testing.expectEqual(component.types.StatusKind.conflicted, statusOf(.{ .section = .changes, .path = "a", .letter = 'U', .action = .none, .conflicted = true }));
    try testing.expectEqual(component.types.StatusKind.added, statusOf(.{ .section = .changes, .path = "a", .letter = 'U', .action = .stage, .untracked = true }));
    try testing.expectEqual(component.types.StatusKind.added, statusOf(.{ .section = .staged, .path = "a", .letter = 'A', .action = .unstage }));
    try testing.expectEqual(component.types.StatusKind.deleted, statusOf(.{ .section = .staged, .path = "a", .letter = 'D', .action = .unstage }));
    try testing.expectEqual(component.types.StatusKind.modified, statusOf(.{ .section = .staged, .path = "a", .letter = 'M', .action = .unstage }));
}

test "섹션 값은 두 모듈 사이에서 1:1이다" {
    // component는 session 모듈을 import하지 않으므로 이 변환이 유일한 다리다. 값이 갈리면 여기서 걸린다.
    try testing.expectEqual(component.types.Section.staged, sectionOf(.staged));
    try testing.expectEqual(component.types.Section.changes, sectionOf(.changes));
    try testing.expectEqual(@intFromEnum(scm_view.Section.staged), sectionIndex(.staged));
    try testing.expectEqual(@intFromEnum(scm_view.Section.changes), sectionIndex(.changes));
}
