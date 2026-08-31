//! 소스 컨트롤 표면의 **Windows 상태와 다시 그리기**(W8.4⒞).
//!
//! §2m.27·§2m.28 까지의 스모크는 프레임을 **한 번** 만들어 120 번 표현했다. 눌러서 무언가 바뀌려면
//! 그 조립을 **상태가 바뀔 때마다** 다시 할 수 있어야 하고, 이 파일이 그 조립을 소유한다.
//!
//! ## 새로 짠 판정이 없다
//!
//! 픽셀 → intent 는 전부 중립이 소유한다 — `chrome.ui.interaction.dispatch` 가 published tree 를
//! 훑고, `component.ids.Table` 이 그 `UiActionId` 에 도메인 의미를 붙인다. Windows 가 하는 일은
//! 창이 준 픽셀을 넘기고 돌아온 intent 를 상태에 적용하는 것뿐이다. macOS 의
//! `app_session/scm_dock.zig` `scmDockPointer` 와 **같은 함수들**을 부른다.
//!
//! ## 상태 적용을 왜 여기 두는가 (공유 안 한 것)
//!
//! `applyIntent` 의 규칙 셋은 macOS `applyScmDockIntent` 를 그대로 읽어 왔다. 중립 leaf 로 빼지
//! **않은** 이유는 macOS 쪽이 저장소별로 서기 때문이다 — 거기 선택은 `(repo, index)` 쌍이고
//! (`scm_selected_repo`), 여기는 저장소가 하나다. 지금 한 타입으로 묶으면 Windows 가 안 쓰는
//! 저장소 축을 지거나, macOS 가 못 쓰는 모양이 된다. **규칙이 늘면 그때 뺀다** — `scm_items.zig`
//! 가 그렇게 나왔다(중복이 실제로 둘이 된 뒤에 뺐다).
//!
//! 다만 **왜 선택을 내리는가**는 여기 적어 둔다: 접으면 행 번호가 밀려서, 안 내리면 엉뚱한 행이
//! 강조된 채로 남는다(macOS 적대적 검증 4 회차가 찾은 것).
//!
//! ## 메모리 — 다시 그릴 때마다 arena 를 버린다
//!
//! 한 번 조립에 열대여섯 개의 배열이 든다(tree 버퍼 여섯, draw 버퍼 셋, 셰이핑 산출물 넷…).
//! 개별로 `defer` 를 걸면 다시 그리는 자리마다 그 목록을 되풀이하게 되고, 하나 빠뜨리면 누수는
//! 프레임마다 쌓인다. arena 하나를 통째로 버린다.

const std = @import("std");

/// **이 파일은 root 모듈에 산다**(`main.zig` 가 가드해서 import 한다). 그래서 형제 Windows 모듈은
/// 상대 경로가 아니라 **배럴로** 가져온다 — 상대로 가져오면 같은 파일이 `maru` 모듈과 root 양쪽에
/// 들어가 컴파일이 거부된다(실측: `file exists in modules 'maru' and 'root'`).
const maru = @import("maru");
const draw_host = maru.win32_draw_host;
const win32_terminal = maru.win32_terminal;
const d3d11_cells = maru.d3d11_cells;
/// **이름과 달리 두 OS 를 다 탄다** — Windows 는 §2m.18 이음매로 간다. `main.zig` 도 같은 상대
/// 경로로 가져오므로 한 모듈 안의 한 파일이다. 아직 `platform/macos/` 에 있는 사정은
/// layering-and-portability.md §3.4.
const system_text = @import("../macos/chrome/system_text.zig");

const scm_view = maru.session.scm_view;
const git_write_command = maru.session.git_write_command;
const component = maru.chrome.components.scm_dock;
const interaction = maru.chrome.ui.interaction;

/// 표면을 그리는 데 필요한 호스트 조각들 — **정의는 `win32_draw_host` 가 소유한다**(그쪽이
/// `maru` 모듈이라 두 소비자가 다 볼 수 있다).
pub const Ctx = draw_host.SurfaceCtx;

/// 눌러서 바뀌는 것 전부. **모델이 아니다** — 모델은 git 출력에서 매번 다시 세운다.
pub const State = struct {
    collapsed: [scm_view.section_count]bool = @splat(false),
    expanded: [scm_view.section_count]bool = @splat(false),
    /// 강조할 행(모델 인덱스). **화면 자리가 아니다** — 스크롤하면 어긋난다(`scm_items` 의 그 테스트).
    selected: ?usize = null,
    interaction: interaction.InteractionState = .{},
    /// published tree 의 세대. `Table.resolve` 가 이 값으로 **옛 프레임의 action 을 버린다**.
    ///
    /// **여기서는 아직 그 판정이 발동하지 않는다** — 프레임과 그 action 표가 같은 `Built` 안에
    /// 함께 있어서, 클릭이 참조하는 표는 언제나 지금 화면의 표다. 그래도 세대를 올려 두는 것은
    /// 표가 프레임 밖으로 나가는 순간(스크롤 가상화·비동기 갱신) 그 판정이 **저절로 켜지게**
    /// 하기 위해서다. macOS 는 호스트가 표를 따로 들고 있어 이미 켜져 있다.
    generation: u64 = 1,

    /// **목록이 통째로 바뀌었다**(git 쓰기·비동기 갱신). 포인터 상태를 버리고 세대를 올린다.
    ///
    /// 안 버리면 `hovered` 가 사라졌거나 **다른 뜻이 된 node id** 를 가리킨다 — id 는
    /// `NodeIds.item(i)` 라 인덱스가 밀리면 같은 번호가 다른 행이다. macOS 는 같은 자리에서
    /// `if (replaced) capture = null` 을 한다(§2m.29 가 남긴 위험 항목).
    pub fn invalidateTree(self: *State) void {
        self.interaction = .{};
        self.selected = null;
        self.generation += 1;
    }

    /// intent 를 상태에 적용한다. **바뀌었으면 `true`** — 호출자가 그때만 다시 그린다.
    ///
    /// 여기서 처리하지 않는 intent(쓰기·비교 열기·탭)는 `false` 를 낸다. 조용히 무시하는 것이
    /// 아니라 **이 슬라이스의 범위 밖**이라는 뜻이고, 호출자가 그 사실을 세어 보고한다.
    pub fn apply(self: *State, intent: component.ids.Intent) bool {
        switch (intent) {
            .toggle_section => |section| {
                const index = @intFromEnum(sectionOf(section));
                self.collapsed[index] = !self.collapsed[index];
                // **행 번호가 밀리므로 강조를 내린다** — 안 내리면 엉뚱한 행이 강조된 채 남는다.
                self.selected = null;
                self.generation += 1;
                return true;
            },
            .expand_section => |section| {
                self.expanded[@intFromEnum(sectionOf(section))] = true;
                self.selected = null;
                self.generation += 1;
                return true;
            },
            .open_row => |ref| {
                // 비교를 여는 것은 이 슬라이스가 아니다(에디터 표면과 git 읽기가 함께 필요하다).
                // **고르기까지**가 여기다 — 강조가 실제로 옮겨 가는 것이 눈에 보이는 결과다.
                if (self.selected != null and self.selected.? == ref.model_index) return false;
                self.selected = ref.model_index;
                self.generation += 1;
                return true;
            },
            else => return false,
        }
    }
};

/// 눌린 것이 **git 을 쓰는 일**일 때, 무엇을 어떻게 쓸지.
///
/// `State.apply` 가 안 하는 이유: 이것은 상태 변경이 아니라 **바깥 세계에 대한 요청**이다. 한
/// 함수에 섞으면 "적용했다" 가 두 가지 뜻을 갖고, 실패를 어디서 다루는지가 흐려진다.
pub const Write = struct {
    kind: git_write_command.Kind,
    /// 행 명령이면 그 경로 하나. `_all` 변종은 경로를 안 받으므로 `null` 이다.
    ///
    /// **`built` 의 arena 를 가리킨다** — 다시 짓기 **전에** 쓰거나 복사해야 한다.
    path: ?[]const u8,
};

/// intent 하나를 git 명령으로 옮긴다. **모델을 다시 조회한다** — intent 가 든 것은 인덱스뿐이고
/// 그 사이 목록이 갱신됐을 수 있다(macOS `submitRowWrite` 와 같은 규율).
///
/// 규칙 자체(`unborn` 특례 포함)는 중립이 소유한다 — `git_write_command.kindForRow`·`kindForSection`.
pub fn writeFor(built: *const Built, intent: component.ids.Intent) ?Write {
    switch (intent) {
        .row_action => |ref| {
            if (ref.model_index >= built.model.rows.len) return null;
            const row = switch (built.model.rows[ref.model_index]) {
                .file => |f| f,
                else => return null,
            };
            const kind = git_write_command.kindForRow(row.action, built.model.head.unborn) orelse return null;
            return .{ .kind = kind, .path = row.path };
        },
        .section_action => |ref| return .{
            .kind = git_write_command.kindForSection(sectionOf(ref.section), built.model.head.unborn),
            .path = null,
        },
        else => return null,
    }
}

/// component 의 섹션 값을 모델 축으로 되돌린다. `scm_items.sectionOf` 의 역이고, 두 값 집합이
/// 갈리면 이 switch 가 컴파일에서 걸린다.
fn sectionOf(section: component.types.Section) scm_view.Section {
    return switch (section) {
        .staged => .staged,
        .changes => .changes,
    };
}

/// 한 번 조립한 결과. **arena 를 들고 있다** — `deinit` 하나가 전부를 놓는다.
pub const Built = struct {
    arena: std.heap.ArenaAllocator,
    model: scm_view.Model,
    items: []component.types.Item,
    props: component.types.Props,
    frame: component.build.Frame,
    /// 화면에 올릴 셀(단색 사각 + 자유 위치 글리프).
    cells: []d3d11_cells.Cell,
    /// 그려진 글자 전부(판정용). 조립 순서 그대로다.
    text: []const u8,
    ops: usize,
    ops_text: usize,
    ops_fill: usize,
    ops_dropped: usize,
    /// 이번 투영이 낸 스크롤 상한. **휠이 이 값을 쓴다** — 휠은 짓는 자리 밖에서 오므로 그때 투영을
    /// 다시 할 수 없다.
    scroll_max_offset_px: u32 = 0,
    /// 발행된 **목록 뷰포트 높이**. 다음 프레임의 투영이 이것을 쓴다(위 `Options.list_viewport_h`).
    list_viewport_h_px: u32 = 0,
    atlas_region_uploads: usize,
    stats: maru.renderer.RenderFrameStats,

    pub fn deinit(self: *Built) void {
        self.arena.deinit();
    }
};

pub const Options = struct {
    /// `git status --porcelain=v2 -b` 원문. 호출자가 소유한다.
    status_text: []const u8,
    font_family: []const u8,
    font_fallback: []const u8,
    font_size_pt: f32,
    tokens: *const maru.chrome.Tokens,
    /// 목록 스크롤 — **셋이 한 벌이다**(에이전트 도크와 같은 모양, §2m.92).
    ///
    /// Windows 는 **가상화를 안 한다**: 목록을 전부 넘기고 첫 항목의 origin 을 `-offset` 으로 준다.
    /// 그러면 발행 rect 가 **이미 스크롤된 자리**라 히트테스트가 offset 을 따로 빼지 않아도 된다.
    scroll_offset_px: u32 = 0,
    /// 지난 프레임이 발행한 **목록 뷰포트 높이**. 투영은 짓기 전에 필요한데 그 높이는 짓고 나야 나온다
    /// (탭 줄·요약 줄·브랜치 줄이 목록 위아래를 차지한다). 0 이면 첫 프레임이라 표면 높이를 쓴다.
    ///
    /// **여기서 고정 chrome 을 빼서 계산하지 않는다** — macOS 가 그렇게 하는데 그 함수 주석이
    /// *"하나라도 빠뜨리면 목록이 자기 자리보다 크다고 믿고 스크롤 범위가 어긋난다"* 고 적어 뒀다.
    /// 발행된 값을 되읽으면 그 목록이 하나다.
    list_viewport_h: u32 = 0,
};

/// 상태 → 화면. **매번 처음부터 짓는다** — 부분 갱신을 하려면 무엇이 바뀌었는지를 두 번째로 알아야
/// 하고, 그 둘이 갈리는 것이 조용한 오답의 씨앗이다(§2m.27 의 `cellFromGpuGlyph` 와 같은 규율).
pub fn build(
    parent: std.mem.Allocator,
    ctx: Ctx,
    state: *const State,
    opts: Options,
) !Built {
    var arena_state = std.heap.ArenaAllocator.init(parent);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();

    const view_w = ctx.viewport_w;
    const view_h = ctx.viewport_h;

    // ── git 출력 → 모델 ──────────────────────────────────────────────────────────────────────
    const rows_buf = try a.alloc(scm_view.Row, 256);
    const model_scratch = try a.alloc(u8, 64 * 1024);
    const model = scm_view.build(
        opts.status_text,
        "",
        "",
        "",
        state.collapsed,
        state.expanded,
        false,
        rows_buf,
        model_scratch,
    );

    // ── 모델 → 항목 ─────────────────────────────────────────────────────────────────────────
    const items = try a.alloc(component.types.Item, model.rows.len);
    for (model.rows, 0..) |row, i| {
        items[i] = maru.scm_items.itemFor(row, 0, i, state.selected, state.collapsed);
    }

    // ── 스크롤 투영 ─────────────────────────────────────────────────────────────────────────
    //
    // **높이 규칙은 중립이 소유한다**(`DockMetrics.itemHeight`) — 이 자리는 그 답을 모아 길이와 상한을
    // 낼 뿐이다. 길이를 안 주면 스크롤바가 "얼마나 긴 목록의 어디" 를 모른다.
    const dm = component.types.DockMetrics.resolve(1000);
    const list = maru.chrome.components.scm_dock.scroll.Items{ .items = items, .metrics = dm };
    const list_view_h: u32 = if (opts.list_viewport_h != 0) opts.list_viewport_h else view_h;
    const proj = list.project(list_view_h, opts.scroll_offset_px);

    // ── 항목 → tree ──────────────────────────────────────────────────────────────────────────
    const bs = component.build.bufferSizes(items);
    const props = component.types.Props{
        .viewport_px = .{ .x = 0, .y = 0, .width = @floatFromInt(view_w), .height = @floatFromInt(view_h) },
        .cell_width_px = ctx.cell_w,
        .items = items,
        .branch = model.head.branch orelse "",
        .ahead = model.head.ahead,
        .behind = model.head.behind,
        .has_ab = model.head.has_ab,
        .changed_file_count = scm_view.changedFileCount(opts.status_text),
        .snapshot_generation = state.generation,
        .scroll_offset_px = proj.offset_y_px,
        .content_h_px = proj.content_height_px,
        .content_first_item_origin_y_px = -@as(i32, @intCast(proj.offset_y_px)),
        // **넘칠 때만 거터를 준다** — 그 자리 주석이 사용자 지적으로 그렇게 정해 뒀다.
        .list_overflows = proj.max_offset_px > 0,
    };
    const frame = component.build.build(props, .{
        .nodes = try a.alloc(maru.chrome.ui.tree.UiNode, bs.nodes),
        .entries = try a.alloc(maru.chrome.ui.tree.RectEntry, bs.entries),
        .layout_items = try a.alloc(maru.chrome.ui.layout.Item, bs.layout_items),
        .flex_scratch = try a.alloc(maru.chrome.ui.layout.FlexScratch, bs.flex_scratch),
        .child_rects = try a.alloc(maru.chrome.ui.layout.UiRect, bs.child_rects),
        .actions = try a.alloc(component.ids.Entry, bs.actions),
    }) catch return error.TreeBuildFailed;

    // ── tree → ChromeDraw ────────────────────────────────────────────────────────────────────
    const budget = component.view.drawBufferSizes(props, frame.tree.entries.len);
    const draws = component.view.view(props, frame, state.interaction, opts.tokens, .{
        .ops = try a.alloc(maru.chrome.draw.Op, budget.ops),
        .runs = try a.alloc(maru.chrome.draw.Run, budget.runs),
        .text_bytes = try a.alloc(u8, budget.text_bytes),
    }) catch return error.ViewFailed;

    // ── ChromeDraw → 화면 (measured 경로 — §2m.27) ───────────────────────────────────────────
    var request = try system_text.prepareRequest(a, 1, draws.ops, opts.tokens, ctx.cell_w, .{
        .family = opts.font_family,
        .fallback = opts.font_fallback,
    });
    const unresolved = try system_text.shapeRequest(a, &request, 1000);
    const artifact = try system_text.resolveArtifact(a, &ctx.renderer_state.font_registry, unresolved);

    const shape_surface = try system_text.emptyDrawList(a, artifact.records.len);
    var layout_cfg = maru.renderer.textConfigFromFontSize(opts.font_size_pt, 1);
    layout_cfg.cell_width_px = @intCast(ctx.cell_w);
    layout_cfg.glyph_cell_width_px = @intCast(ctx.cell_w);
    layout_cfg.cell_height_px = @intCast(ctx.cell_h);
    const shaped = try maru.renderer.buildGlyphRunListFromShapedRecordsWithSurface(
        a,
        artifact.records,
        layout_cfg,
        .{
            .size = shape_surface.size,
            .cursor = shape_surface.cursor,
            .dirty = shape_surface.dirty,
            .overlays = shape_surface.overlays,
        },
    );

    // **래스터라이저에 이름 표를 준다** — measured 텍스트의 `font_id` 는 레지스트리 id 라 이것 없이는
    // face 를 못 찾고, 그러면 글자가 하나도 안 그려진다(§2m.27 실측).
    var measured_rasterizer = ctx.rasterizer;
    measured_rasterizer.registry = &ctx.renderer_state.font_registry;
    const render_frame = try ctx.renderer_state.buildFrameFromGlyphRunListWithRasterizer(
        a,
        shape_surface,
        shaped.runs,
        measured_rasterizer,
    );
    // **짓는 자리에서 곧바로 올린다** — 업로드 목록은 프레임과 함께 사라진다(§2m.32).
    try draw_host.syncAtlasTexture(ctx.pipeline, ctx.renderer_state, ctx.atlas_w, ctx.atlas_h);
    const uploads = draw_host.uploadFrameRegions(ctx.pipeline, render_frame);

    // ── 셀 ───────────────────────────────────────────────────────────────────────────────────
    var cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    const counted = try draw_host.appendChromeOps(a, draws.ops, opts.tokens, view_w, view_h, &cells);
    var gpu_glyphs: std.ArrayList(maru.renderer.metal_frame.GpuGlyph) = .empty;
    try artifact.appendGpuGlyphs(a, render_frame, ctx.renderer_state.atlas.config, 0, 0, null, 0, &gpu_glyphs);
    for (gpu_glyphs.items) |g| {
        try cells.append(a, win32_terminal.cellFromGpuGlyph(g, ctx.atlas_w.*, ctx.atlas_h.*));
    }

    // ── 판정용 글자 ──────────────────────────────────────────────────────────────────────────
    //
    // **`draw_list.cells` 를 읽으면 안 된다** — measured 경로의 그 목록은 표면 크기만 나르는 합성
    // 목록이라 비어 있다. 글자는 `artifact.records` 에 있다(§2m.27 에서 `0/5` 를 낸 자리).
    var text: std.ArrayList(u8) = .empty;
    for (artifact.records) |r| {
        var b: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(r.codepoint), &b) catch continue;
        try text.appendSlice(a, b[0..n]);
    }

    return .{
        .arena = arena_state,
        .model = model,
        .items = items,
        .props = props,
        .frame = frame,
        .cells = cells.items,
        .text = text.items,
        .ops = draws.ops.len,
        .ops_text = counted.text,
        .ops_fill = counted.fill,
        .ops_dropped = counted.dropped,
        .scroll_max_offset_px = proj.max_offset_px,
        // **되읽어서 알린다** — 여기서 고정 chrome 을 빼면 그 산수의 주인이 둘이 된다.
        .list_viewport_h_px = if (component.build.scrollTextViewport(frame.tree)) |vp|
            @intFromFloat(@max(vp.height, 0))
        else
            0,
        .atlas_region_uploads = uploads,
        .stats = maru.renderer.renderFrameStats(render_frame, ctx.renderer_state.atlas.entryCount()),
    };
}

/// 포인터 하나를 tree 로 라우팅한다. macOS `scmDockPointer` 와 **같은 두 함수**를 부른다 —
/// `interaction.dispatch` 로 hover·click 을 풀고, `ids.Table.resolve` 로 도메인 의미를 붙인다.
///
/// 스크롤바 드래그는 여기 없다 — 이 표면은 아직 스크롤하지 않는다(편집기는 §2m.23 에서 했다).
pub const Routed = struct {
    intent: ?component.ids.Intent = null,
    /// **그림이 달라졌다.** intent 가 없어도 참일 수 있다 — 호버가 들어오고 나가는 것도 그림이
    /// 바뀌는 일이다. 이것을 안 보면 **마우스를 올려도 아무 표시가 안 난다**: 상태는 바뀌는데
    /// 화면을 다시 안 그린다(적대적 검증에서 나온 실제 결함이다. macOS 는 같은 자리에서
    /// `dispatched.dirty` 를 보고 `metal_dirty` 를 세운다).
    dirty: bool = false,
    /// **끄는 제스처.** intent 와 배타적이 아니다 — 그 타입 doc: *"threshold 를 넘지 않은 up 은
    /// `action` 만, 넘은 up 은 `drag` 만 낸다"*. 스크롤바 thumb 이 이 길로 온다.
    ///
    /// **이 값을 버리면 막대가 안 잡힌다** — 에이전트 표면이 정확히 그 상태였다(§2m.95).
    drag: ?interaction.DragEvent = null,
};

pub fn pointer(
    built: *const Built,
    state: *State,
    phase: interaction.UiPointerPhase,
    x_px: f64,
    y_px: f64,
) Routed {
    const tree_view = maru.chrome.ui.tree.UiRectTree{ .entries = built.frame.tree.entries };
    const dispatched = interaction.dispatch(
        &state.interaction,
        tree_view,
        .{ .phase = phase, .x_px = x_px, .y_px = y_px, .timestamp_ns = 0 },
    ) catch return .{};
    var dirty = false;
    for (dispatched.dirty.ids) |id| {
        if (id != null) {
            dirty = true;
            break;
        }
    }
    const action = dispatched.action orelse return .{ .dirty = dirty, .drag = dispatched.drag };
    // **`@constCast` 는 안전하다** — `resolve` 는 `self` 를 값으로 받고 읽기만 한다(그 함수 본문).
    // 표를 직접 훑지 않는 이유는 `enabled` 와 세대 판정이 **거기 있기** 때문이다: 손으로 훑으면
    // 꺼진 컨트롤도 눌린다(예전 스모크가 실제로 그 둘을 건너뛰고 있었다).
    var table = component.ids.Table.init(@constCast(built.frame.actions));
    table.count = built.frame.actions.len;
    return .{
        .intent = table.resolve(action, built.props.snapshot_generation),
        .dirty = dirty,
        .drag = dispatched.drag,
    };
}

/// 한 자리를 **누르고 뗀다**. 판정 코드가 쓰는 편의 함수다.
///
/// `.up` 만 보내면 아무 action 도 안 나온다 — 중립 `dispatch` 는 `.down` 이 잡아 둔 자리와 뗀 자리가
/// 같아야 클릭으로 친다(창 밖으로 끌고 나갔다 놓는 것을 클릭으로 세지 않으려는 규율이다). 처음에
/// `.up` 만 보내 `row_hits=0/3` 이 나왔는데, 그것은 히트테스트가 아니라 **판정이 틀린 것**이었다.
pub fn click(built: *const Built, state: *State, x_px: f64, y_px: f64) ?component.ids.Intent {
    _ = pointer(built, state, .down, x_px, y_px);
    return pointer(built, state, .up, x_px, y_px).intent;
}

const testing = std.testing;

test "접으면 강조가 내려간다 — 행 번호가 밀리기 때문" {
    var state = State{ .selected = 3 };
    try testing.expect(state.apply(.{ .toggle_section = .changes }));
    try testing.expect(state.collapsed[@intFromEnum(scm_view.Section.changes)]);
    try testing.expectEqual(@as(?usize, null), state.selected);
}

test "다시 누르면 펴진다" {
    var state = State{};
    _ = state.apply(.{ .toggle_section = .staged });
    try testing.expect(state.collapsed[@intFromEnum(scm_view.Section.staged)]);
    _ = state.apply(.{ .toggle_section = .staged });
    try testing.expect(!state.collapsed[@intFromEnum(scm_view.Section.staged)]);
}

test "섹션마다 자리가 따로다 — 하나를 접어도 다른 하나는 그대로다" {
    var state = State{};
    _ = state.apply(.{ .toggle_section = .changes });
    try testing.expect(state.collapsed[@intFromEnum(scm_view.Section.changes)]);
    try testing.expect(!state.collapsed[@intFromEnum(scm_view.Section.staged)]);
}

test "모두 보기는 그 섹션만 편다" {
    var state = State{ .selected = 1 };
    try testing.expect(state.apply(.{ .expand_section = .changes }));
    try testing.expect(state.expanded[@intFromEnum(scm_view.Section.changes)]);
    try testing.expect(!state.expanded[@intFromEnum(scm_view.Section.staged)]);
    try testing.expectEqual(@as(?usize, null), state.selected);
}

test "같은 행을 다시 누르면 안 바뀐다 — 헛 그리기를 막는다" {
    var state = State{};
    try testing.expect(state.apply(.{ .open_row = .{ .repo_index = 0, .model_index = 2 } }));
    try testing.expectEqual(@as(?usize, 2), state.selected);
    try testing.expect(!state.apply(.{ .open_row = .{ .repo_index = 0, .model_index = 2 } }));
    try testing.expect(state.apply(.{ .open_row = .{ .repo_index = 0, .model_index = 5 } }));
    try testing.expectEqual(@as(?usize, 5), state.selected);
}

test "상태가 바뀔 때만 세대가 는다 — 늦은 클릭 판정이 그 값에 걸려 있다" {
    var state = State{};
    const g0 = state.generation;
    _ = state.apply(.{ .open_row = .{ .repo_index = 0, .model_index = 1 } });
    try testing.expectEqual(g0 + 1, state.generation);
    // 같은 행 → 안 바뀜 → 세대도 그대로
    _ = state.apply(.{ .open_row = .{ .repo_index = 0, .model_index = 1 } });
    try testing.expectEqual(g0 + 1, state.generation);
}

test "이 슬라이스 밖의 intent 는 false 를 낸다 — 조용히 삼키지 않는다" {
    var state = State{};
    try testing.expect(!state.apply(.{ .row_action = .{ .repo_index = 0, .model_index = 0 } }));
    try testing.expect(!state.apply(.{ .commit = 0 }));
    try testing.expect(!state.apply(.{ .select_tab = .history }));
    // 상태는 하나도 안 움직였다.
    try testing.expectEqual(@as(u64, 1), state.generation);
    try testing.expectEqual(@as(?usize, null), state.selected);
}

test "목록이 바뀌면 포인터 상태를 버린다 — id 가 밀리기 때문" {
    var state = State{ .selected = 4 };
    state.interaction = .{ .hovered = 0x5343_1008, .focused = 0x5343_1008 };
    const g0 = state.generation;
    state.invalidateTree();
    try testing.expectEqual(@as(?u64, null), state.interaction.hovered);
    try testing.expectEqual(@as(?u64, null), state.interaction.focused);
    try testing.expectEqual(@as(?usize, null), state.selected);
    try testing.expectEqual(g0 + 1, state.generation);
}

test "접힘 상태는 목록이 바뀌어도 남는다 — 사용자가 접어 둔 것이다" {
    var state = State{};
    _ = state.apply(.{ .toggle_section = .staged });
    state.invalidateTree();
    try testing.expect(state.collapsed[@intFromEnum(scm_view.Section.staged)]);
}
