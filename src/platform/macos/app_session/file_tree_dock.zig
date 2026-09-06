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
fn projectRow(row: file_tree.Row, model_index: usize, selected: bool, ignored_known: bool) component.types.Row {
    var out: component.types.Row = .{
        .kind = .file,
        .label = "",
        .icon_kind = file_tree.rowIconKind(row),
        .selected = selected,
        .model_index = model_index,
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

/// 히트 tree만 **그리지 않고** 만들어 발행한다.
///
/// **왜 별도 진입점인가**: 포인터 경로가 published rect 를 보게 되면서(FT2) "아직 한 번도 안 그린
/// 세션"에는 누를 것이 없어졌다. 제품에서는 첫 프레임이 곧바로 채우지만, 렌더를 돌리지 않는 헤드리스
/// 테스트는 그 상태에 영원히 머문다. 그 테스트가 자기 rect 를 지어내면 제품과 다른 기하를 판정하게
/// 되므로, **같은 build 를 그대로** 부를 수 있는 문을 낸다(SCM 도크의 `testProps` 와 같은 자리).
pub fn publishFileTreeHitTree(self: *AppSession) void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prepared = prepare(self, arena) orelse return;
    publishFileTreeFrame(self, prepared.frame, prepared.content);
}

const Prepared = struct {
    props: component.types.Props,
    frame: component.build.Frame,
    /// 도크 기하는 `session.split_tree.Rect` 다(그리기·발행이 같은 값을 쓰게 그대로 옮긴다).
    content: @TypeOf(dock_ops.dockGeometry(@as(*AppSession, undefined)).tree_content),
    text_w: u32,
};

/// 투영 → props → build. **그리기와 히트 tree 발행이 같은 입력을 쓰게 하는 자리**다 — 둘이 각자
/// props 를 만들면 그 순간 화면과 판정이 갈린다.
fn prepare(self: *AppSession, arena: std.mem.Allocator) ?Prepared {
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return null;
    const content = dock_ops.dockGeometry(self).tree_content;
    if (content.w == 0 or content.h == 0) return null;
    const text_w = dock_ops.dockListTextWidthPx(self);
    if (text_w == 0) return null;

    const window = file_panel_ops.fileTreeDrawWindow(self);
    if (window.count == 0) return null;

    const start = @min(window.start, self.file_tree_rows.items.len);
    const end = @min(start + window.count, self.file_tree_rows.items.len);
    const rows_src = self.file_tree_rows.items[start..end];

    const rows = arena.alloc(component.types.Row, rows_src.len) catch return null;
    // 무시 여부는 저장소를 물어봤을 때만 뜻이 있다 — 안 물어본 상태에서 흐리게 그리면 "모르는 것"이
    // "무시됨"으로 보인다(docs/file-explorer.md의 `ignored_fg` 규율과 같은 판정을 그대로 쓴다).
    const ignored_known = self.git_result != null;
    // 선택은 **신원 기반**이다(`selectedFileTreeRow`) — 비동기 재빌드로 행이 밀려도 같은 항목을 가리킨다.
    const selected_index = file_panel_ops.selectedFileTreeRow(self);
    // 이름 변경 중이면 그 행의 라벨을 편집 중인 글자로 바꾼다.
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
            index,
            selected_index != null and selected_index.? == index,
            ignored_known,
        );
        if (edit_identity) |want| if (file_tree.rowIdentity(row)) |identity| {
            if (identity.eql(want)) out.label = edit_text.?;
        };
        // 원격 탐색기(RF3a)의 빈 행은 「열어 보라」가 아니라 상태 안내다 — 읽기 실패면 §2.5 의
        // 「원격이라 못 읽는다」, 아직 결과 전이면 첫 목록 대기 안내다.
        if (row == .empty and self.file_tree_rows_remote) {
            out.label = if (self.remote_explorer.err != null)
                i18n.t(.fp_remote_tree_unreadable)
            else
                i18n.t(.fp_remote_tree_loading);
        }
    }

    const props = component.types.Props{
        .viewport_px = .{ .width = @floatFromInt(text_w), .height = @floatFromInt(content.h) },
        .scale_milli = fileTreeScaleMilli(self),
        .snapshot_generation = self.file_tree_projection_generation,
        .rows = rows,
        .selection_focused = file_panel_ops.fileTreeFocused(self),
        .origin_shift_px = window.origin_shift_px,
        // 접근성 서술자의 `set_size` — **창이 아니라 도메인 목록의 크기**다. `rows.len` 을 주면
        // 스크린 리더가 400줄 트리를 늘 "N / 창크기" 로 읽는다(`chrome/ui/semantics.zig`).
        .total_rows = @intCast(@min(self.file_tree_rows.items.len, std.math.maxInt(u32))),
    };

    const sizes = component.build.bufferSizes(rows.len);
    const frame = component.build.build(props, .{
        .nodes = arena.alloc(chrome.ui.tree.UiNode, sizes.nodes) catch return null,
        .entries = arena.alloc(chrome.ui.tree.RectEntry, sizes.entries) catch return null,
        .layout_items = arena.alloc(chrome.ui.layout.Item, sizes.entries) catch return null,
        .flex_scratch = arena.alloc(chrome.ui.layout.FlexScratch, sizes.entries) catch return null,
        .child_rects = arena.alloc(chrome.ui.layout.UiRect, sizes.entries) catch return null,
        .actions = arena.alloc(component.ids.Entry, sizes.actions) catch return null,
    }) catch return null;
    return .{ .props = props, .frame = frame, .content = content, .text_w = text_w };
}

/// 한 프레임의 트리 그리기.
pub fn collectFileTreeDock(
    self: *AppSession,
    collected: *std.ArrayList(CollectedPane),
    builder: coretext_frame_builder.CoreTextFrameBuilder,
    colors: metal_frame.CellColors,
) void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prepared = prepare(self, arena) orelse return;
    const props = prepared.props;
    const frame = prepared.frame;
    const content = prepared.content;
    const text_w = prepared.text_w;

    // **발행이 먼저다.** 호버 색은 `InteractionState` 가 정하고 그 판정은 이 tree 를 본다 — 그리기 전에
    // 넣어야 같은 프레임의 호버가 화면에 반영된다.
    publishFileTreeFrame(self, frame, content);

    // 예산 산술은 **방출하는 쪽(component)**이 소유한다 — 여기서 세면 view가 op을 하나 더할 때마다
    // 조용히 낡고, 그 증상은 트리 전체가 빈 화면이다.
    const budget = component.view.bufferSizes(props.rows);
    const tokens = self.buildChromeTokens();
    const draws = component.view.view(props, frame, self.file_tree_interaction, &tokens, .{
        .ops = arena.alloc(chrome.draw.Op, budget.ops) catch return,
        .runs = arena.alloc(chrome.draw.Run, budget.runs) catch return,
        .text_bytes = arena.alloc(u8, budget.text_bytes) catch return,
    }) catch return;

    chrome_draw_lowering.appendBackgroundQuads(self.allocator, &.{draws}, &tokens, @intCast(content.x), @intCast(content.y), &self.gpu_quads, 2);

    // **셀 경로를 쓰지 않는다.** SCM·Session Dock 은 여기서 `buildIconTextDrawList` 를 부르지만, 그것은
    // `wide_icons == true` 인 op 만 통과시킨다(`buildTextDrawListFiltered`). 이 컴포넌트의 텍스트·아이콘은
    // 전부 `wide_icons = false` 라 그 호출은 **빈 draw list** 를 낸다 — 매 프레임 할당만 하고 아무것도 안
    // 그렸다(적대적 검증에서 잡았다). 아이콘은 measured 경로가 그린다: `shapesTextOp` 이 `!wide_icons` 를
    // 태우고 `shapesRun` 이 `icon_in_rect` 를 명시적으로 살려 "worker 가 논리 rect 에서 SVG 를 직접 해석"
    // 한다. 그 사실을 컴포넌트 테스트가 못 박는다(`view` — 모든 op 이 measured 대상이다).
    const cols: u16 = @intCast(@min(text_w / self.cell_width_px, std.math.maxInt(u16)));
    const cell_rows: u16 = @intCast(@min(content.h / self.cell_height_px, std.math.maxInt(u16)));

    const scale = props.scale_milli;
    const scroll_origin_y_px: i32 = -@as(i32, @intCast(@min(props.origin_shift_px, std.math.maxInt(i32))));
    // 행 글자를 자를 뷰포트. **quad 는 tree 의 clip 이 자르지만 measured 글자는 이 값이 없으면 아무 데도
    // 안 잘린다** — 반쯤 스크롤된 첫 행의 라벨이 트리 위 고정 chrome 위로 나온다(2026-08-25, SCM 도크에서
    // 같은 결함을 캡처로 잡고 이쪽도 함께 배선했다). 사각형의 출처는 컴포넌트 하나다(`build`).
    const scroll_clip: ?metal_frame.ClipPx = blk: {
        const rect = component.build.scrollTextViewport(frame.tree) orelse break :blk null;
        break :blk .{
            .x = content.x +| @as(u32, @intFromFloat(@max(rect.x, 0))),
            .y = content.y +| @as(u32, @intFromFloat(@max(rect.y, 0))),
            .w = @intFromFloat(@max(rect.width, 0)),
            .h = @intFromFloat(@max(rect.height, 0)),
        };
    };
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
                scroll_clip,
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

/// 히트 tree 발행. entries 는 **backing 좌표로 옮겨** 담는다 — 그리기는 pane origin 을 따로 더하지만
/// 히트테스트는 창 좌표로 오므로, 같은 값을 두 좌표계로 두면 그 변환이 두 곳에 생긴다.
///
/// **같은 tree 가 다시 나오는 것은 교체가 아니다.** 그걸 교체로 치면 방금 누른 행이 AppKit 의 mouse-up
/// 전에 취소된다(Session Dock·SCM 도크와 같은 판단).
fn publishFileTreeFrame(self: *AppSession, frame: component.build.Frame, content: anytype) void {
    // **두 좌표계를 견주지 않는다.** 저장본은 아래에서 pane origin 을 더해 backing 좌표로 굳고,
    // `frame.tree.entries` 는 아직 도크 로컬 좌표다. 오프셋을 빼고 비교하면 `content` 가 원점이 아닌 한
    // (오른쪽 도크는 x 가 1400 대다) **모든 발행이 교체로 판정된다** — 그러면 방금 누른 행의 capture 가
    // 다음 paint 에서 취소되고, mouse-up 이 intent 를 못 내 **좌클릭이 영영 안 열린다**(2026-08-26 실측:
    // `entries 25->25 actions 23->23 rows 23->23 gen 2464->2464` 인데 `replaced=true`).
    const replaced = !frameEql(
        self.file_tree_entries.items,
        self.file_tree_actions.items,
        frame.tree.entries,
        frame.actions,
        @floatFromInt(content.x),
        @floatFromInt(content.y),
    );
    // 두 저장소를 **먼저** 확보한다. 할당이 실패해도 마지막으로 온전히 그린 hit tree 가 남아야 한다.
    self.file_tree_entries.ensureTotalCapacity(self.allocator, frame.tree.entries.len) catch return;
    self.file_tree_actions.ensureTotalCapacity(self.allocator, frame.actions.len) catch return;
    self.file_tree_entries.clearRetainingCapacity();
    self.file_tree_actions.clearRetainingCapacity();
    for (frame.tree.entries) |entry| {
        var moved = entry;
        moved.rect.x += @floatFromInt(content.x);
        moved.rect.y += @floatFromInt(content.y);
        if (moved.effective_clip) |*clip| {
            clip.x += @floatFromInt(content.x);
            clip.y += @floatFromInt(content.y);
        }
        self.file_tree_entries.appendAssumeCapacity(moved);
    }
    self.file_tree_actions.appendSlice(self.allocator, frame.actions) catch return;
    if (replaced) self.file_tree_interaction.capture = null;
    // 이 발행이 **무엇을 보고 만들어졌는지** 남긴다. 포인터 입구가 이 값으로 신선도를 판정한다.
    self.file_tree_published_scroll_px = file_panel_ops.fileTreeEffectiveScrollPx(self);
    self.file_tree_published_rows = self.file_tree_rows.items.len;
    self.file_tree_published_generation = self.file_tree_projection_generation;
    self.file_tree_published_content = .{ .x = content.x, .y = content.y, .w = content.w, .h = content.h };
    // 접근성 스냅숏도 **이 자리에서** 굳힌다 — 발행된 entry 와 같은 순간이어야 host 가 보는 줄과
    // 화면의 줄이 같다. 라벨은 복사한다(그 이유는 `app_session/accessibility.zig` 머리말).
    self.file_tree_accessibility.rebuild(
        self.allocator,
        self.file_tree_entries.items,
        self.file_tree_published_generation,
    );
}

/// 행의 신원을 한 값으로 접는다 — **비교 전용**이다.
///
/// `RowIdentity` 를 그대로 들 수 없는 사정(빌려온 `path`)은 `file_tree_press_identity` 의 선언이
/// 소유한다. 여기서 필요한 것은 "같은 행인가" 하나뿐이라 kind 와 경로를 함께 접는다. 신원이 없는
/// 행(빈 자리 안내)은 null 이고, 그런 행은 애초에 action 을 안 든다.
fn rowIdentityHash(row: file_tree.Row) ?u64 {
    const identity = file_tree.rowIdentity(row) orelse return null;
    var hasher = std.hash.Wyhash.init(@intFromEnum(identity.kind));
    hasher.update(identity.path);
    return hasher.final();
}

/// 누르고 있던 행과 호버를 **놓는다**. 창이 비활성될 때처럼 "이 트리에 더는 손이 없다"가 확실한 자리용.
///
/// capture 만 지우면 밴드가 켜진 채 남는다 — 호버도 같이 놓고, 그림이 바뀌므로 dirty 를 세운다.
pub fn releaseFileTreePointer(self: *AppSession) void {
    const had_hover = self.file_tree_interaction.hovered != null;
    self.file_tree_interaction.capture = null;
    self.file_tree_interaction.hovered = null;
    if (had_hover) self.metal_dirty = true;
}

/// `old_entries` 는 **backing 좌표**(발행이 pane origin 을 더해 굳힌 것)이고 `new_entries` 는 아직
/// 도크 **로컬** 좌표다. 그래서 `dx`·`dy` 를 받아 새 쪽을 옮겨 놓고 견준다 — 발행이 쓰는 것과 같은
/// 덧셈이라 부동소수도 비트까지 같은 값이 나온다. 이 인자가 없던 동안 두 좌표계를 그대로 비교해
/// 모든 발행이 교체였다.
fn frameEql(
    old_entries: []const chrome.ui.tree.RectEntry,
    old_actions: []const component.ids.Entry,
    new_entries: []const chrome.ui.tree.RectEntry,
    new_actions: []const component.ids.Entry,
    dx: f32,
    dy: f32,
) bool {
    if (old_entries.len != new_entries.len or old_actions.len != new_actions.len) return false;
    for (old_entries, new_entries) |old, new| {
        if (old.id != new.id) return false;
        if (old.rect.x != new.rect.x + dx or old.rect.y != new.rect.y + dy) return false;
        if (old.rect.width != new.rect.width or old.rect.height != new.rect.height) return false;
    }
    for (old_actions, new_actions) |old, new| {
        if (!std.meta.eql(old.intent, new.intent)) return false;
    }
    return true;
}

/// 발행이 지금 상태를 반영하는지 보고, 아니면 **다시 낸다**.
///
/// 발행은 그리기 경로가 하므로 프레임 사이에 낡을 수 있다. 스크롤이 대표적이다 — 휠 이벤트와 클릭이
/// 같은 run loop 패스에 들어오면 그 사이에 paint 가 없고, 그러면 **커서 밑에 보이는 행과 발행이 말하는
/// 행이 다르다.** 세대 검사는 이것을 못 잡는다: 스크롤은 투영 세대를 올리지 않는다(올릴 이유도 없다 —
/// 목록이 바뀐 게 아니다). 실측으로 휠 10행 뒤 발행이 2행을 가리켰다.
///
/// **무조건 다시 내지 않는다.** 포인터 이동은 초당 수십 번 오고 발행은 arena 를 연다 — 두 정수 비교로
/// 바뀐 때만 낸다.
fn ensureFreshHitTree(self: *AppSession) void {
    if (self.file_tree_published_scroll_px == file_panel_ops.fileTreeEffectiveScrollPx(self) and
        self.file_tree_published_rows == self.file_tree_rows.items.len and
        // 행 **수**가 같아도 목록이 바뀔 수 있다(watcher 가 이름을 갈고, 폴더 하나를 접고 다른 하나를
        // 편다). 그 판정은 투영 세대가 이미 소유하고 있으니 여기서 그것도 본다.
        self.file_tree_published_generation == self.file_tree_projection_generation and
        // **기하도 본다.** 창·사이드바·도크 폭이 바뀌면 목록은 그대로인데 rect 가 통째로 움직인다 —
        // 위 셋 중 어느 것도 그 변화를 못 본다. 다음 paint 전에 온 포인터가 옛 자리로 행을 고르지
        // 않도록, 발행이 본 사각형과 지금 사각형을 견준다.
        geometryEql(self.file_tree_published_content, dock_ops.dockGeometry(self).tree_content)) return;
    publishFileTreeHitTree(self);
}

fn geometryEql(published: @TypeOf(@as(AppSession, undefined).file_tree_published_content), now: anytype) bool {
    return published.x == now.x and published.y == now.y and published.w == now.w and published.h == now.h;
}

/// 포인터 한 건을 발행된 tree 에 흘린다. 반환값은 **손을 뗐을 때의 intent** 다.
pub fn fileTreeDockPointer(
    self: *AppSession,
    phase: chrome.ui.interaction.UiPointerPhase,
    x_px: f64,
    y_px: f64,
) ?component.ids.Intent {
    if (self.dock.view != .explorer or !dock_ops.dockVisible(self)) return null;
    ensureFreshHitTree(self);
    if (self.file_tree_entries.items.len == 0) return null;
    // 스크롤바 트랙 위는 목록이 아니다 — 막대를 잡으려는 손이 행을 열면 안 된다(옛 `fileTreeRowAt` 의
    // 같은 가드를 여기로 옮겼다). **그냥 돌아가지 않고 호버를 놓는다** — 그러지 않으면 포인터가 막대
    // 위에 있는데 마지막 행의 밴드가 켜진 채 남는다(적대적 검증).
    if (dock_ops.dockListScrollbarGeometry(self)) |geometry| if (geometry.trackContains(x_px, y_px)) {
        file_panel_ops.clearFileTreeHover(self);
        return null;
    };
    // **세대를 양쪽에 싣는다.** `ensureFreshHitTree` 가 맞춰 주는 것이 정상 경로지만 발행은 실패할 수
    // 있다(`prepare` 가 null, 또는 저장소 확보 실패 — 그때는 옛 entries 가 남는다). 그 프레임의 좌표
    // 판정은 사라진 행을 짚을 수 있으므로, 낡은 스냅샷에서는 **capture·호버도 세우지 않고** 돌아간다
    // (`chrome.ui.interaction` 의 게이트는 tree 와 event 양쪽 세대가 0 이 아닐 때만 문다).
    const tree_view = chrome.ui.tree.UiRectTree{
        .entries = self.file_tree_entries.items,
        .generation = self.file_tree_published_generation,
    };
    const dispatched = chrome.ui.interaction.dispatch(
        &self.file_tree_interaction,
        tree_view,
        .{
            .phase = phase,
            .x_px = x_px,
            .y_px = y_px,
            .timestamp_ns = 0,
            .generation = self.file_tree_projection_generation,
        },
    ) catch return null;
    for (dispatched.dirty.ids) |id| {
        if (id != null) {
            self.metal_dirty = true;
            break;
        }
    }
    // **누른 행의 신원을 down 에서 굳힌다.** up 이 이것과 대조한다(그 이유는 필드 선언이 소유한다).
    //
    // **이 자리가 그 값의 단일 출처다** — 모든 down 이 먼저 비우고 capture 가 섰을 때만 채우므로, 옛
    // 값이 다음 클릭으로 샐 길이 없다. capture 를 놓는 다른 자리들(교체 발행·창 비활성)에서 함께
    // 비우는 코드를 두지 않는 이유가 이것이다 — 그 방어는 여기와 중복이라 어떤 판정자도 물지 못했고,
    // 죽은 방어는 "무엇을 지키는가"를 흐린다.
    if (phase == .down) {
        self.file_tree_press_identity = null;
        if (self.file_tree_interaction.capture) |capture| {
            var pressed_table = component.ids.Table.init(self.file_tree_actions.items);
            pressed_table.count = self.file_tree_actions.items.len;
            if (pressed_table.resolve(capture.action_id, self.file_tree_projection_generation)) |pressed| switch (pressed) {
                .activate_row => |index| if (index < self.file_tree_rows.items.len) {
                    self.file_tree_press_identity = rowIdentityHash(self.file_tree_rows.items[index]);
                },
            };
        }
    }
    const action = dispatched.action orelse return null;
    var table = component.ids.Table.init(self.file_tree_actions.items);
    table.count = self.file_tree_actions.items.len;
    const intent = table.resolve(action, self.file_tree_projection_generation) orelse return null;
    // **없는 행은 intent 로도 안 나간다.** 보통은 목록이 바뀌면 투영 세대가 올라가 위 `resolve` 가
    // 거르지만, 세대를 안 올리고 행만 줄어드는 경로가 생기면 그 방어가 통째로 비껴간다 — 질의 경로
    // (`fileTreeRowAtPublished`)가 정확히 그래서 죽었다. 같은 값의 두 소비자가 **같은 판정**을 쓰게 한다.
    return switch (intent) {
        .activate_row => |index| blk: {
            if (index >= self.file_tree_rows.items.len) break :blk null;
            // **누른 그 파일인가.** 자리가 유지된 채 내용만 갈리는 경우는 위 세대·범위 검사가 전부
            // 통과하므로(같은 `model_index`·같은 rect), 여기서만 걸린다. 손을 뗀 순간 한 번 쓰고 놓는다.
            if (phase == .up) {
                const pressed = self.file_tree_press_identity;
                self.file_tree_press_identity = null;
                if (pressed) |want| {
                    const now = rowIdentityHash(self.file_tree_rows.items[index]) orelse break :blk null;
                    if (now != want) break :blk null;
                }
            }
            break :blk intent;
        },
    };
}

/// 좌표가 가리키는 행의 **모델 인덱스**(우클릭처럼 dispatch 를 태우지 않는 자리용). 발행된 rect 를
/// 되읽으므로 클릭 경로와 같은 답이다.
///
/// **지금 없는 행은 주지 않는다.** 발행된 tree 는 행 목록보다 오래 살 수 있다 — watcher 갱신·스캔
/// 완료·폴더 접기는 렌더와 다른 시점에 목록을 바꾸고, 그 사이 도착한 포인터는 옛 표를 본다. 그 인덱스를
/// 그대로 돌려주면 소비자가 `file_tree_rows.items[i]` 에서 **범위를 넘어 죽는다**(실측:
/// `index 20, len 3`). 방어를 소비자마다 두면 하나를 빠뜨리고, 실제로 우클릭 경로가 그랬다 — 그래서
/// **질의 자체가** 판정한다.
pub fn fileTreeRowAtPublished(self: *AppSession, x_px: f64, y_px: f64) ?usize {
    if (self.dock.view != .explorer or !dock_ops.dockVisible(self)) return null;
    ensureFreshHitTree(self);
    if (dock_ops.dockListScrollbarGeometry(self)) |geometry| if (geometry.trackContains(x_px, y_px)) return null;
    // `hitAction` 에는 세대 게이트가 없다(좌표 질의라 상태를 안 만진다). 그래서 **여기서 판정한다** —
    // 클릭 경로가 낡은 발행을 거부하는데 우클릭이 같은 발행으로 행을 집으면, 두 소비자가 또 갈린다.
    if (self.file_tree_published_generation != self.file_tree_projection_generation) return null;
    const tree_view = chrome.ui.tree.UiRectTree{ .entries = self.file_tree_entries.items };
    const hit = chrome.ui.interaction.hitAction(tree_view, x_px, y_px) orelse return null;
    for (self.file_tree_actions.items) |candidate| {
        if (candidate.action_id != hit.action_id) continue;
        return switch (candidate.intent) {
            .activate_row => |index| if (index < self.file_tree_rows.items.len) index else null,
        };
    }
    return null;
}

/// 발행된 tree 가 선언한 커서. host 가 "누를 수 있나"를 다시 추론하지 않는다.
pub fn fileTreeHoverCursor(self: *const AppSession) chrome.ui.tree.CursorHint {
    const hovered = self.file_tree_interaction.hovered orelse return .auto;
    for (self.file_tree_entries.items) |entry| {
        if (entry.id == hovered) return entry.cursor;
    }
    return .auto;
}

/// intent 를 실제 동작으로 옮긴다. **모델 인덱스는 다시 조회한다** — intent 가 든 것은 인덱스뿐이고,
/// 그 사이 비동기 재스캔이 목록을 바꿨을 수 있다(늦은 클릭이 엉뚱한 파일을 열지 않게). 세대 검증은
/// 그 사이 **투영이 다시 발행된 경우**만 잡으므로 이 재조회를 대신하지 못한다.
pub fn applyFileTreeIntent(self: *AppSession, intent: component.ids.Intent) void {
    switch (intent) {
        .activate_row => |index| {
            if (index >= self.file_tree_rows.items.len) return;
            file_panel_ops.focusFileTree(self);
            _ = file_panel_ops.setFileTreeSelection(self, index);
            file_panel_ops.activateFileTreeRow(self, index);
        },
    }
}
