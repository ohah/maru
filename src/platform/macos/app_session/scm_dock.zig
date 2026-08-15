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
const git_backend_mod = app_session_mod.git_backend_mod;
const git_write_command = app_session_mod.git_write_command;
const redact = maru.redact;

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
/// 커밋 상자가 보여 줄 **시각 행** 수. P3b에서는 입력이 아직 없어 늘 한 줄이고, P3c가 실제 메시지의
/// 랩 결과(`text_area.visibleRows`)를 준다 — 그 계산의 자리를 지금 만들어 두어 목록 높이와 상자 높이가
/// **같은 값**을 쓰게 한다(두 곳이 각자 세면 스크롤 범위가 어긋난다).
fn commitRows(self: *const AppSession) u32 {
    _ = self;
    return 1;
}

fn listViewportHeightPx(self: *const AppSession, has_branch: bool) u32 {
    const content = dock_ops.dockGeometry(self).tree_content;
    const m = component.types.DockMetrics.resolve(scmDockScaleMilli(self));
    // **고정 chrome을 전부 뺀다.** 하나라도 빠뜨리면 목록이 자기 자리보다 크다고 믿고 스크롤 범위가
    // 어긋난다(탭 줄에서 실제로 그랬다). 커밋 상자는 내용을 따라 자라므로 그 높이도 여기서 센다.
    const commit_h = m.commit_row_h * @max(commitRows(self), 1) + m.commit_button_h;
    const fixed = m.tab_h + m.summary_h + commit_h + if (has_branch) m.branch_h else 0;
    return content.h -| fixed;
}

/// 모델 행 하나를 component 항목으로 옮긴다. **문자열은 복사하지 않는다** — `git_result`가 이 프레임
/// 동안 살아 있고, component는 immutable snapshot만 읽는다.
fn itemFor(row: scm_view.Row, model_index: usize, selected_row: ?usize, collapsed: [scm_view.section_count]bool) component.types.Item {
    return switch (row) {
        .section => |section| .{
            .section = .{
                .section = sectionOf(section.section),
                .count = @intCast(section.count),
                .collapsed = collapsed[@intFromEnum(section.section)],
                // 섹션 헤더의 일괄 동작. 모델이 "대상이 하나도 없으면(전부 충돌) `.none`"까지 판정해 둔다.
                .action = actionOf(section.action),
            },
        },
        .file => |file| .{
            .file = .{
                .model_index = @intCast(model_index),
                .name = std.fs.path.basename(file.path),
                .dir = file.path[0 .. file.path.len - std.fs.path.basename(file.path).len],
                .status = statusOf(file),
                .letter = file.letter,
                .added = file.added,
                .removed = file.removed,
                .has_delta = !file.unknown_delta and !file.binary,
                .binary = file.binary,
                // 행 동작(`+`/`−`). **충돌 행은 모델이 `.none`으로 준다** — `git add`는 충돌을 "해결됨"으로
                // 표시하므로, 그 행에 `+`를 두면 사용자가 의도하지 않은 해결이 일어난다.
                .action = actionOf(file.action),
                .selected = selected_row != null and selected_row.? == model_index,
            },
        },
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
    /// 커밋 버튼을 켤 수 있나 = index에 무언가 올라가 있나. **모델이 status로 판정한 것만 쓴다**
    /// (낙관적으로 추정하지 않는다 — 쓰기 문서 §7).
    has_staged: bool,
    /// 탭 이름 옆의 **전체** 파일 수. 섹션 헤더의 `count`를 더해서 낸다 — 그 값은 접혀 있어도 잘려
    /// 있어도 전체를 말하므로, 화면 행을 세는 것과 달리 10행 상한·접기에 흔들리지 않는다.
    file_count: u32,
};

/// 모델 → 항목 열 + 스크롤 투영. **렌더와 포인터가 같은 함수를 지난다** — 두 곳이 각자 만들면 스크롤한
/// 뒤 누른 행과 열리는 행이 어긋난다.
pub fn project(self: *AppSession, arena: std.mem.Allocator) ?Projection {
    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const model = git_ops.buildScmModel(self, &rows_buf, &scratch) orelse return null;

    // 쓰기가 실패했으면 그 사유를 **목록 맨 위 한 줄**로 낸다(§5 — 실패는 사실대로). 별도 배너를 만들지
    // 않는 이유는 이 자리가 이미 "목록이 사실과 다르다"를 말하는 자리(`notice`)이고, 사용자가 방금 누른
    // 동작의 결과를 그 목록 바로 위에서 읽는 것이 자연스럽기 때문이다.
    const notice_rows: usize = if (self.scm_write_error != null) 1 else 0;
    const items = arena.alloc(component.types.Item, model.rows.len + notice_rows) catch return null;
    if (self.scm_write_error) |err| items[0] = .{ .notice = err };
    for (model.rows, items[notice_rows..], 0..) |row, *item, index| {
        item.* = itemFor(row, index, self.scm_selected_row, self.scm_collapsed);
    }
    const item_rows = items[notice_rows..];
    applyScmPending(self, model.rows, item_rows);

    var file_count: u32 = 0;
    for (model.rows) |row| switch (row) {
        .section => |section| file_count += @intCast(section.count),
        else => {},
    };

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
        .file_count = file_count,
        .has_staged = model.has_staged,
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
        .cell_width_px = self.cell_width_px,
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
        .changed_file_count = projection.file_count,
        .commit_rows = commitRows(self),
        // **실제 index 상태로만** 켠다(§7 — 낙관하지 않는다).
        .commit_enabled = projection.has_staged,
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
    // 예산 산술은 **방출하는 쪽(component)**이 소유한다 — 여기서 세면 view가 op을 하나 더할 때마다
    // 조용히 낡고, 그 증상은 도크 전체가 빈 화면이다(실제로 두 번 그랬다).
    const budget = component.view.drawBufferSizes(props, frame.tree.entries.len);
    const ops = arena.alloc(chrome.draw.Op, budget.ops) catch return;
    const runs = arena.alloc(chrome.draw.Run, budget.runs) catch return;
    const text_bytes = arena.alloc(u8, budget.text_bytes) catch return;
    const tokens = self.buildChromeTokens();
    const draws = component.view.view(props, frame, self.scm_dock_interaction, &tokens, .{
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
        .row_action => |index| submitRowWrite(self, index),
        .section_action => |section| submitSectionWrite(self, section),
        .scroll_thumb, .scroll_track => {},
    }
}

/// 모델의 행 동작을 component 값으로 옮긴다. 값이 갈리면 이 exhaustive switch가 컴파일로 걸린다.
fn actionOf(action: scm_view.RowAction) component.types.RowAction {
    return switch (action) {
        .stage => .stage,
        .unstage => .unstage,
        .none => .none,
    };
}

/// 낙관적으로 옮긴 행을 투영 결과에 얹는다(§7).
///
/// **모델을 고치지 않는다.** `session/scm_view`는 git 출력의 순수 함수로 남아야 P4·P5가 그대로 쓴다 —
/// "아직 확인되지 않은 사용자 의도"는 세션 상태이지 도메인이 아니다. 그래서 옮기기는 **투영 층에서**
/// 일어나고, 컴포넌트는 받은 것을 그대로 그린다(낙관인지 확정인지 모른다).
///
/// **낙관의 경계**(§7): 옮기는 것은 **그 행 하나의 자리**뿐이다.
///   - 개수·요약 숫자는 건드리지 않는다 — 부분 스테이지·rename에서 틀린 숫자가 나오고, 그건 사용자가
///     커밋 직전에 보는 값이다.
///   - **증감을 지운다.** 그 숫자는 행이 선 그룹의 축(index ↔ 작업트리)에서 나오는데 옮긴 뒤의 축을
///     우리는 아직 모른다. 옛 축의 숫자를 새 자리에 두면 그건 거짓말이다.
///   - **동작을 끈다.** 쓰기가 도는 동안 두 번째 클릭은 어차피 흘려지고(§6), 누를 수 있어 보이면
///     "안 눌렸다"로 읽힌다.
///   - 상태 문자는 **그대로 둔다.** 새 축의 글자를 추측하면(`U` → `A`) 맞을 때가 많지만 그건 추측이고,
///     ~100 ms 뒤 읽기가 사실을 싣고 온다.
fn applyScmPending(self: *AppSession, rows: []const scm_view.Row, items: []component.types.Item) void {
    const pending = self.scm_pending orelse return;
    const target: scm_view.Section = switch (pending.from) {
        .staged => .changes,
        .changes => .staged,
    };

    // 떠나는 행과 도착 그룹 헤더를 찾는다. **도착 헤더가 없으면 옮기지 않는다** — 그 그룹이 화면에
    // 없다는 뜻이고(개수 0이면 헤더를 안 낸다), 갈 곳 없는 행을 숨기면 그 파일이 잠깐 사라져 보인다.
    var from_index: ?usize = null;
    var target_header: ?usize = null;
    for (rows, 0..) |row, index| {
        switch (row) {
            .file => |file| {
                if (from_index == null and file.section == pending.from and std.mem.eql(u8, file.path, pending.path)) {
                    from_index = index;
                }
            },
            .section => |section| {
                if (section.section == target) target_header = index;
            },
            else => {},
        }
    }
    const moving = from_index orelse return;
    const header = target_header orelse return;
    if (moving >= items.len or header >= items.len) return;

    var carried = items[moving].file;
    carried.action = .none;
    carried.has_delta = false;
    carried.binary = false;

    // 배열 안에서 한 칸씩 밀어 헤더 **바로 뒤**에 끼운다(그 그룹의 첫 행 자리).
    if (moving > header) {
        var i = moving;
        while (i > header + 1) : (i -= 1) items[i] = items[i - 1];
        items[header + 1] = .{ .file = carried };
    } else {
        var i = moving;
        while (i < header) : (i += 1) items[i] = items[i + 1];
        items[header] = .{ .file = carried };
    }
}

/// 행 하나의 `+`/`−`. **모델 인덱스는 다시 조회한다** — intent가 든 것은 인덱스뿐이고 그 사이 목록이
/// 갱신됐을 수 있다(늦은 클릭이 엉뚱한 파일을 스테이지하지 않게. `open_row`와 같은 규율이다).
fn submitRowWrite(self: *AppSession, index: u32) void {
    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const model = git_ops.buildScmModel(self, &rows_buf, &scratch) orelse return;
    if (index >= model.rows.len) return;
    const row = switch (model.rows[index]) {
        .file => |file| file,
        .section, .more, .notice => return,
    };
    // 모델이 이미 판정한 것을 다시 판정하지 않는다 — 충돌 행은 여기서 `.none`이라 아무 일도 일어나지 않는다.
    const kind: git_write_command.Kind = switch (row.action) {
        .stage => .stage,
        .unstage => if (model.head.unborn) .unstage_unborn else .unstage,
        .none => return,
    };
    const paths = [_][]const u8{row.path};
    if (!submitWrite(self, kind, &paths)) return;

    // **낙관적 반영**(§7): 화면은 즉시 바뀐다. 안 그러면 100 ms 남짓 아무 일도 안 일어나 두 번 누르게
    // 되고, 두 번째 클릭은 in-flight라 흘려져 "안 눌렸다"로 읽힌다. 낙관은 **이 행 하나**에만 건다.
    setScmPending(self, row.path, row.section);
}

/// 낙관적으로 옮길 행을 기억한다. 경로는 **복사한다** — 모델 버퍼는 프레임마다 다시 만들어진다.
fn setScmPending(self: *AppSession, path: []const u8, from: scm_view.Section) void {
    clearScmPending(self);
    const copy = self.allocator.dupe(u8, path) catch return;
    self.scm_pending = .{ .path = copy, .from = from };
    self.metal_dirty = true;
}

pub fn clearScmPending(self: *AppSession) void {
    if (self.scm_pending) |pending| {
        self.allocator.free(pending.path);
        self.scm_pending = null;
    }
}

/// 섹션 헤더의 일괄 `+`/`−`. **방향은 host가 지금 상태로 다시 정한다**(intent가 방향을 싣지 않는 이유 —
/// published tree와 host 상태가 어긋날 수 있다).
fn submitSectionWrite(self: *AppSession, section: component.types.Section) void {
    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const model = git_ops.buildScmModel(self, &rows_buf, &scratch) orelse return;
    const target = switch (section) {
        .staged => scm_view.Section.staged,
        .changes => scm_view.Section.changes,
    };
    const kind: git_write_command.Kind = switch (target) {
        .staged => if (model.head.unborn) .unstage_all_unborn else .unstage_all,
        .changes => .stage_all,
    };
    // `_all` 변종은 경로를 받지 않는다. **그래서 화면에 안 보이는 파일까지 든다** — 그것이 "모두"의 뜻이고,
    // 10행 상한에 걸려 접힌 파일도 사용자가 기대하는 대상이다.
    _ = submitWrite(self, kind, &.{});
}

/// 쓰기 하나를 건다. **in-flight 하나**(§6) — 도는 동안 눌린 것은 흘린다(큐를 쌓으면 오래된 클릭이
/// 뒤늦게 저장소를 바꾼다).
fn submitWrite(self: *AppSession, kind: git_write_command.Kind, paths: []const []const u8) bool {
    if (self.scm_write_inflight != 0) return false;
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = git_ops.gitRepoRoot(self, &repo_buf) orelse return false;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse return false;
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch return false;
    }
    self.scm_write_seq += 1;
    if (!self.git_backend.?.submitWrite(git_exe, repo, kind, paths, null, self.scm_write_seq)) return false;
    self.scm_write_inflight = self.scm_write_seq;
    clearScmWriteError(self);
    self.metal_dirty = true;
    return true;
}

pub fn clearScmWriteError(self: *AppSession) void {
    if (self.scm_write_error) |err| {
        self.allocator.free(err);
        self.scm_write_error = null;
    }
}

/// 끝난 쓰기를 거둔다. **성공이든 실패든 목록을 다시 읽는다** — 성공이면 사실이 바뀌었고, 실패면 우리가
/// 아는 상태와 저장소가 갈렸다는 뜻이다(§5·§7). 읽기는 여기서 **한 번만** 건다.
pub fn drainScmWrite(self: *AppSession) void {
    const backend = &(self.git_backend orelse return);
    var taken = backend.takeWriteResult() orelse return;
    defer taken.deinit(git_backend_mod.worker_allocator);
    if (taken.request_id != self.scm_write_inflight) return; // 낡은 결과는 버린다
    self.scm_write_inflight = 0;
    self.metal_dirty = true;
    // **성공이든 실패든 낙관을 걷는다.** 뒤이어 거는 읽기가 사실을 싣고 오므로, 낙관을 남겨 두면 그
    // 사실 위에 옛 추측이 덧그려진다(§7 — 실패하면 되돌린다).
    clearScmPending(self);

    if (!taken.ok()) {
        clearScmWriteError(self);
        self.scm_write_error = writeErrorText(self, taken);
    }
    // 쓰기가 끝난 **뒤** 한 번 읽는다(§6-1 — 쓰기마다 읽기를 걸면 `+`를 빠르게 누를 때 프로세스가 줄줄이 뜬다).
    git_ops.refreshGitStatus(self);
}

/// 화면에 낼 실패 사유. **redact하고 자른다**(§5) — 홈 경로·IP·`user@host`가 stderr에 섞이고, hook 출력은
/// 수천 줄이 될 수 있다. trace·로그에는 싣지 않는다(화면은 방금 누른 동작의 결과, 로그는 나중에 공유되는 산출물).
fn writeErrorText(self: *AppSession, result: git_backend_mod.WriteResult) ?[]u8 {
    if (!result.spawned) return self.allocator.dupe(u8, "git을 실행하지 못했습니다") catch null;
    const raw = std.mem.trimEnd(u8, result.stderr, "\n");
    if (raw.len == 0) return self.allocator.dupe(u8, "git 명령이 실패했습니다") catch null;
    // **마지막 줄만** 낸다. 목록 안 한 줄짜리 자리라 여러 줄을 담을 수 없고, hook 거부 사유는 보통 끝에 온다.
    const last_break = std.mem.lastIndexOfScalar(u8, raw, '\n');
    const last = if (last_break) |at| raw[at + 1 ..] else raw;
    const anonymized = redact.anonymizeAlloc(self.allocator, last, .{}) catch return null;
    defer self.allocator.free(anonymized);
    const max_cols: usize = 160;
    const clipped = if (anonymized.len > max_cols) anonymized[0..max_cols] else anonymized;
    return self.allocator.dupe(u8, clipped) catch null;
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

test "draw 예산은 최악 행 구성을 담는다(모자라면 도크가 통째로 빈다)" {
    // 이 테스트가 없으면 view에 op을 하나 더하는 변경이 조용히 예산을 넘기고, 증상은 "그 op이 안 보임"이
    // 아니라 **도크 전체가 빈 화면**이다(실제로 겪었다 — 증감을 두 색으로 가르면서 행당 5 → 6이 됐다).
    // 그래서 제품 경로와 **같은 `drawBudget`**으로 버퍼를 잡고, 가장 op을 많이 내는 행 구성으로 돌린다.
    const component_types = component.types;
    var items: [12]component_types.Item = undefined;
    // 그룹 헤더 둘 + 파일 열 — 파일 행이 op을 가장 많이 낸다(아이콘·이름·경로·증감 둘·상태 문자).
    items[0] = .{ .section = .{ .section = .staged, .count = 5, .collapsed = false, .action = .none } };
    items[6] = .{ .section = .{ .section = .changes, .count = 5, .collapsed = false, .action = .none } };
    // 나머지 항목 종류도 예산에 든다 — 서식 문자열이 component 것이라 platform은 길이를 모른다.
    items[10] = .{ .more = .{ .section = .changes, .hidden = std.math.maxInt(u32) } };
    items[11] = .{ .notice = "git 출력이 상한에 걸려 잘렸다 — 뒤쪽 파일은 오지 않았다" };
    for (&items, 0..) |*item, index| {
        if (index == 0 or index == 6 or index == 10 or index == 11) continue;
        item.* = .{
            .file = .{
                .name = "some-file-name.zig",
                // **경로에 상한이 없다** — `name`+`dir`이 곧 git 경로다. 행당 고정 바이트로 예산을 잡으면
                // 어떤 값을 골라도 그보다 긴 저장소가 있고, 넘치는 순간 도크가 통째로 빈다.
                .dir = "src/" ++ "very-long-directory-segment/" ** 45,
                .status = .modified,
                .letter = 'M',
                .added = 123,
                .removed = 456,
                .has_delta = true,
                .action = .none,
            },
        };
    }

    const props: component_types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 480 },
        .items = &items,
        // 숫자는 **u32 최댓값**으로 민다 — 자릿수를 10으로 잡아 둔 예산이 실제로 그만큼 버티는지가
        // 산술이 아니라 테스트로 확인돼야 한다(브랜치 줄은 계산상 여유가 1바이트뿐이었다).
        .branch = "feat/a-really-long-branch-name-that-someone-will-eventually-create",
        .has_ab = true,
        .ahead = std.math.maxInt(u32),
        .behind = std.math.maxInt(u32),
        .summary = .{ .added = std.math.maxInt(u32), .removed = std.math.maxInt(u32) },
        .changed_file_count = std.math.maxInt(u32),
    };

    const sizes = component.build.bufferSizes(&items);
    const allocator = testing.allocator;
    const nodes = try allocator.alloc(chrome.ui.tree.UiNode, sizes.nodes);
    defer allocator.free(nodes);
    const entries = try allocator.alloc(chrome.ui.tree.RectEntry, sizes.entries);
    defer allocator.free(entries);
    const layout_items = try allocator.alloc(chrome.ui.layout.Item, sizes.layout_items);
    defer allocator.free(layout_items);
    const flex_scratch = try allocator.alloc(chrome.ui.layout.FlexScratch, sizes.flex_scratch);
    defer allocator.free(flex_scratch);
    const child_rects = try allocator.alloc(chrome.ui.layout.UiRect, sizes.child_rects);
    defer allocator.free(child_rects);
    const actions = try allocator.alloc(component.ids.Entry, sizes.actions);
    defer allocator.free(actions);

    const frame = try component.build.build(props, .{
        .nodes = nodes,
        .entries = entries,
        .layout_items = layout_items,
        .flex_scratch = flex_scratch,
        .child_rects = child_rects,
        .actions = actions,
    });

    const budget = component.view.drawBufferSizes(props, frame.tree.entries.len);
    const ops = try allocator.alloc(chrome.draw.Op, budget.ops);
    defer allocator.free(ops);
    const runs = try allocator.alloc(chrome.draw.Run, budget.runs);
    defer allocator.free(runs);
    const text_bytes = try allocator.alloc(u8, budget.text_bytes);
    defer allocator.free(text_bytes);

    const tokens = chrome.tokens.Tokens.tui(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 },
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 200, .g = 200, .b = 200 },
        .sidebar_background = .{ .r = 30, .g = 30, .b = 30 },
        .sidebar_foreground = .{ .r = 200, .g = 200, .b = 200 },
        .sidebar_active = .{ .r = 60, .g = 60, .b = 60 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 13, .g = 14, .b = 15 },
        .accent = .{ .r = 16, .g = 17, .b = 18 },
    });
    // 호버가 걸린 행도 동작 글리프를 하나 더 낸다 — 그 최악까지 담아야 한다.
    const hovered: chrome.ui.interaction.InteractionState = .{ .hovered = component.build.NodeIds.item(1) };
    const draws = try component.view.view(props, frame, hovered, &tokens, .{
        .ops = ops,
        .runs = runs,
        .text_bytes = text_bytes,
    });
    try testing.expect(draws.ops.len > 0);
}

test "스크롤한 창에서도 intent는 모델 인덱스를 싣는다" {
    // **P1b가 창 자리를 실어 내보냈다.** 그러면 목록을 스크롤한 뒤 누른 행과 열리는(그리고 스테이지되는)
    // 행이 어긋난다 — host가 그 값으로 모델을 다시 조회하기 때문이다. 쓰기가 붙은 지금은 그 어긋남이
    // "엉뚱한 파일이 열린다"가 아니라 **"엉뚱한 파일이 스테이지된다"**가 된다.
    const rows = [_]scm_view.Row{
        .{ .section = .{ .section = .changes, .count = 3, .action = .stage } },
        .{ .file = .{ .section = .changes, .path = "a.zig", .letter = 'M', .action = .stage } },
        .{ .file = .{ .section = .changes, .path = "b.zig", .letter = 'M', .action = .stage } },
        .{ .file = .{ .section = .changes, .path = "c.zig", .letter = 'M', .action = .stage } },
    };
    var items: [rows.len]component.types.Item = undefined;
    for (rows, &items, 0..) |row, *item, index| {
        item.* = itemFor(row, index, null, @splat(false));
    }

    // 창이 2번째 행부터 시작한다고 하자(앞 둘은 스크롤아웃).
    const window = items[2..];
    try testing.expectEqual(@as(u32, 2), window[0].file.model_index);
    try testing.expectEqual(@as(u32, 3), window[1].file.model_index);
}

test "낙관적 반영: 그 행만 옮기고 개수·증감·동작은 낙관하지 않는다 (§7)" {
    // `+`를 누르면 화면이 **즉시** 바뀐다(안 그러면 두 번 누르고, 두 번째는 in-flight라 흘려져
    // "안 눌렸다"로 읽힌다). 다만 낙관은 **그 행 하나의 자리**뿐이다.
    const rows = [_]scm_view.Row{
        .{ .section = .{ .section = .staged, .count = 1, .action = .unstage } },
        .{ .file = .{ .section = .staged, .path = "kept.zig", .letter = 'M', .action = .unstage } },
        .{ .section = .{ .section = .changes, .count = 2, .action = .stage } },
        .{ .file = .{ .section = .changes, .path = "moving.zig", .letter = 'M', .action = .stage, .added = 3, .removed = 1 } },
        .{ .file = .{ .section = .changes, .path = "other.zig", .letter = 'M', .action = .stage } },
    };
    var items: [rows.len]component.types.Item = undefined;
    for (rows, &items, 0..) |row, *item, index| {
        item.* = itemFor(row, index, null, @splat(false));
    }
    // 낙관 없이는 원래 자리다.
    try testing.expectEqualStrings("moving.zig", items[3].file.name);

    var session: AppSession = undefined;
    session.allocator = testing.allocator;
    session.scm_pending = .{ .path = try testing.allocator.dupe(u8, "moving.zig"), .from = .changes };
    defer testing.allocator.free(session.scm_pending.?.path);

    applyScmPending(&session, &rows, &items);

    // ① 그 행이 **스테이지된 변경** 헤더 바로 뒤로 옮겨졌다.
    try testing.expectEqualStrings("moving.zig", items[1].file.name);
    // ② 나머지 행들은 순서를 지킨다.
    try testing.expectEqualStrings("kept.zig", items[2].file.name);
    try testing.expectEqualStrings("other.zig", items[4].file.name);
    // ③ **개수는 낙관하지 않는다** — 헤더 숫자는 그대로다(실제 결과가 온 뒤에 바뀐다).
    try testing.expectEqual(@as(u32, 1), items[0].section.count);
    try testing.expectEqual(@as(u32, 2), items[3].section.count);
    // ④ **증감을 지운다** — 그 숫자는 옛 축(작업트리)의 것이고 새 자리의 축을 우리는 아직 모른다.
    try testing.expect(!items[1].file.has_delta);
    // ⑤ **동작을 끈다** — 쓰기가 도는 동안 두 번째 클릭은 어차피 흘려진다.
    try testing.expectEqual(component.types.RowAction.none, items[1].file.action);
    // ⑥ 상태 문자는 그대로다(새 축의 글자를 추측하지 않는다).
    try testing.expectEqual(@as(u8, 'M'), items[1].file.letter);
}

test "낙관적 반영: 도착 그룹이 화면에 없으면 옮기지 않는다" {
    // 개수 0인 섹션은 헤더를 안 낸다. 갈 곳이 없는데 원래 자리에서 지우면 **그 파일이 잠깐 사라져
    // 보인다** — 사용자가 방금 누른 파일이 목록에서 없어지는 것이 가장 나쁜 실패 모드다.
    const rows = [_]scm_view.Row{
        .{ .section = .{ .section = .changes, .count = 1, .action = .stage } },
        .{ .file = .{ .section = .changes, .path = "only.zig", .letter = 'M', .action = .stage } },
    };
    var items: [rows.len]component.types.Item = undefined;
    for (rows, &items, 0..) |row, *item, index| {
        item.* = itemFor(row, index, null, @splat(false));
    }

    var session: AppSession = undefined;
    session.allocator = testing.allocator;
    session.scm_pending = .{ .path = try testing.allocator.dupe(u8, "only.zig"), .from = .changes };
    defer testing.allocator.free(session.scm_pending.?.path);

    applyScmPending(&session, &rows, &items);
    // 그대로다 — 파일이 사라지지 않는다.
    try testing.expectEqualStrings("only.zig", items[1].file.name);
    try testing.expectEqual(component.types.RowAction.stage, items[1].file.action);
}
