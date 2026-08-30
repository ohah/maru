//! 에이전트 세션 도크의 **Windows 조립**(W8.5b⒜).
//!
//! 뷰 바의 셋째 칸(`.agent_sessions`)은 지금까지 **빈 도크**를 열었다 — 칸은 눌리는데 아무것도 안
//! 그려졌다. 이 파일이 그 자리를 채운다.
//!
//! ## SCM 표면과 같은 모양이다
//!
//! `win32_scm_surface.zig` 가 세운 그 길을 그대로 간다 — 항목 → tree → ChromeDraw → measured 셰이핑
//! → 셀. 다른 것은 컴포넌트(`session_dock`)와 항목의 출처뿐이다. 그래서 여기 **새로 짠 판정이 없다**:
//! 픽셀 → intent 는 `chrome.ui.interaction.dispatch` 와 `component.ids.Table` 이 소유한다.
//!
//! ## ⒜ 는 표면까지다 — 목록은 아직 비어 있다
//!
//! 에이전트 세션은 provider 이력(JSONL)을 훑어야 나온다. 그 데이터 경로는 별개 슬라이스이고, 이
//! 슬라이스가 세우는 것은 **조립이 Windows 에서 도는가**다(SCM 이 §2m.9 에서 같은 순서로 갔다).
//!
//! 그래서 **빈 목록을 정직하게 그린다** — 컴포넌트가 그 상태를 위해 안내 문구를 갖고 있다. 목록이
//! 비었다는 것과 조립이 실패했다는 것은 다른 사실이고, 판정이 그 둘을 가른다.
//!
//! ## 메모리 — 다시 그릴 때마다 arena 를 버린다
//!
//! SCM 과 같은 이유다(조립 하나에 배열 열댓 개).

const std = @import("std");

/// **이 파일은 root 모듈에 산다**(`main.zig` 가 가드해서 import 한다). 형제 Windows 모듈은 상대
/// 경로가 아니라 **배럴로** 가져온다 — 상대로 가져오면 같은 파일이 `maru` 모듈과 root 양쪽에 들어가
/// 컴파일이 거부된다(§2m.39 실측).
const maru = @import("maru");
const draw_host = maru.win32_draw_host;
const win32_terminal = maru.win32_terminal;
const d3d11_cells = maru.d3d11_cells;
/// **이름과 달리 두 OS 를 다 탄다**(§2m.18 이음매). `main.zig` 도 같은 상대 경로로 가져오므로 한
/// 모듈 안의 한 파일이다. 아직 `platform/macos/` 에 있는 사정은
/// [layering-and-portability.md](../../../docs/layering-and-portability.md) §3.4 — 이 파일은 네이티브
/// 참조가 37 개인 **섞임** 부류라 애초에 이동 후보도 아니다(떼어내는 것은 이동이 아니라 분해다 —
/// 그 37 은 §3.4 가 쓴 계수 방식, 즉 주석까지 센 값이다).
const system_text = @import("../macos/chrome/system_text.zig");

const component = maru.chrome.components.session_dock;
const interaction = maru.chrome.ui.interaction;

pub const Ctx = draw_host.SurfaceCtx;

/// 다시 그리기 사이에 살아남는 것 — **상태는 여기, 조립은 `build`**.
pub const State = struct {
    interaction: interaction.InteractionState = .{},
    /// 펼친 카드의 안정 identity. **인덱스가 아니라 identity 다** — 목록이 갱신되면 인덱스는 밀리고,
    /// 그러면 엉뚱한 카드가 펼쳐진 채로 남는다(컴포넌트 Props 의 그 필드 doc 이 정한 규칙).
    expanded_identity: ?u64 = null,
    /// tree 가 바뀌면 hover 를 버린다 — 옛 노드 id 를 들고 있으면 없는 것을 가리킨다.
    generation: u64 = 0,

    pub fn invalidateTree(self: *State) void {
        self.generation +%= 1;
        self.interaction.hovered = null;
    }
};

pub const Options = struct {
    font_family: []const u8,
    font_fallback: []const u8,
    font_size_pt: f32,
    tokens: *const maru.chrome.Tokens,
    /// 목록. ⒜ 에서는 비어 있고, 데이터 경로가 붙으면 호출자가 채운다.
    items: []const component.types.Item = &.{},
    /// 정렬 **방향**. 목록 자체는 호출자가 이미 그 방향으로 넘긴다 — 이 값은 헤더의 라벨이
    /// 무엇을 말할지를 정한다(`Newest first` / `Oldest first`). 둘이 갈리면 라벨이 거짓말을 한다.
    sort_order: component.types.SortOrder = .newest_first,
    /// 검색 줄에 무엇이 떠 있고 포커스인가. **그리기는 중립이 이미 한다**(`view.zig` 가 질의·조합·
    /// 캐럿을 그린다) — 호스트가 할 일은 값을 주는 것뿐이다. 거르는 것은 호스트다(목록을 이미
    /// 걸러 넘긴다).
    search: []const u8 = "",
    /// **조합 중인 글자**(IME). 확정 전이라 목록을 거르지 않는다 — 중립이 그 사실을 타입으로
    /// 못 박아 뒀다(`Props.search_preedit`: *"platform 이 `search` 로 확정하기 전까지 표시 전용"*).
    /// 안 주면 사용자가 **자기가 무엇을 치는지 못 본다**.
    search_preedit: []const u8 = "",
    search_focused: bool = false,
    /// **훑는 중인가.** `loading` 은 보여 줄 record 가 아직 하나도 없는 첫 훑기고, `refreshing` 은
    /// 목록이 있는 채로 다시 훑는 중이다 — 중립이 그 둘을 다른 문구·다른 아이콘 색으로 그린다
    /// (`session_dock/view.zig`: 개수 대신 "분석 중", 해골 줄, 죽은 새로고침 아이콘).
    /// 둘을 안 주면 큰 이력에서 **빈 목록이 "세션이 없다" 로 보인다**.
    loading: bool = false,
    refreshing: bool = false,
    /// 훑기가 사용자 이력의 **일부만** 봤다(read budget 소진·크기 초과·읽기 실패). 헤더가 "일부"
    /// 문구로 바꾼다 — 목록이 전부가 아님을 사용자가 알아야 한다.
    partial: bool = false,
    /// 스크롤 — **셋이 한 벌이다**(`session_dock/types.zig` 의 그 필드 doc).
    ///
    /// Windows 는 **가상화를 안 한다** — 보이는 것을 고르지 않고 목록을 전부 넘기고, 첫 항목의 origin 을
    /// `-offset` 으로 주어 중립이 그 자리에 놓게 한다. 넘친 셀은 호스트가 콘텐츠 사각형으로 자른다
    /// (§2m.91). 그러면 published rect 가 **이미 스크롤된 자리**라 히트테스트가 따로 offset 을 빼지
    /// 않아도 되고, 그리는 자리와 눌리는 자리의 주인이 하나로 남는다.
    ///
    /// 길이와 offset 은 그래도 줘야 한다 — 스크롤바가 *"얼마나 긴 목록의 어디"* 를 그 둘로만 안다.
    scroll_offset_px: u32 = 0,
    scroll_content_height_px: u32 = 0,
    content_first_item_origin_y_px: i32 = 0,
};

pub const Built = struct {
    arena: std.heap.ArenaAllocator,
    items: []const component.types.Item,
    props: component.types.Props,
    frame: component.build.Frame,
    cells: []const d3d11_cells.Cell,
    /// 그려진 글자 — **`draw_list.cells` 가 아니라 `artifact.records` 에서 온다**(measured 경로의
    /// 그 목록은 표면 크기만 나르는 합성 목록이라 비어 있다 — §2m.27 이 `0/5` 를 낸 자리).
    text: []const u8,
    ops: usize,
    ops_text: usize,
    ops_fill: usize,
    ops_dropped: usize,
    atlas_region_uploads: usize,
    stats: maru.renderer.RenderFrameStats,

    pub fn deinit(self: *Built) void {
        self.arena.deinit();
    }
};

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

    const bs = component.build.bufferSizes(opts.items);
    const props = component.types.Props{
        .viewport_px = .{ .width = @floatFromInt(view_w), .height = @floatFromInt(view_h) },
        .cell_width_px = ctx.cell_w,
        .cell_height_px = ctx.cell_h,
        .snapshot_generation = state.generation,
        .displayed_count = @intCast(opts.items.len),
        .items = opts.items,
        .sort_order = opts.sort_order,
        .search = opts.search,
        .search_preedit = opts.search_preedit,
        .search_focused = opts.search_focused,
        .loading = opts.loading,
        .refreshing = opts.refreshing,
        .partial = opts.partial,
        // **캐럿은 포커스일 때만** — 중립이 `search_focused and search_cursor_visible` 로 판정한다.
        // 깜빡임은 아직 없다(타이머가 없다) — 항상 켜 둔다.
        .search_cursor_visible = opts.search_focused,
        .expanded_identity = state.expanded_identity,
        .scroll_offset_px = opts.scroll_offset_px,
        .scroll_content_height_px = opts.scroll_content_height_px,
        .content_first_item_origin_y_px = opts.content_first_item_origin_y_px,
    };
    const frame = component.build.build(props, .{
        .nodes = try a.alloc(maru.chrome.ui.tree.UiNode, bs.nodes),
        .entries = try a.alloc(maru.chrome.ui.tree.RectEntry, bs.entries),
        .layout_items = try a.alloc(maru.chrome.ui.layout.Item, bs.layout_items),
        .flex_scratch = try a.alloc(maru.chrome.ui.layout.FlexScratch, bs.flex_scratch),
        .child_rects = try a.alloc(maru.chrome.ui.layout.UiRect, bs.child_rects),
        .actions = try a.alloc(component.ids.Entry, bs.actions),
    }) catch return error.TreeBuildFailed;

    // ── 그리기 예산 — **macOS 와 같은 식이다**(`app_session/agent_dock.zig`) ─────────────────
    //
    // 이 컴포넌트에는 `drawBufferSizes` 가 없어서 호출자가 잡는다. 그 파일이 왜 이 값들인지까지
    // 적어 뒀고 여기서 되풀이하지 않는다 — 요점만: **quad 몫은 published entry 수에서 유도한다**
    // (상수로 세면 tree 가 자라는 변경마다 조용히 모자라고, 그 결과가 "그 컴포넌트만 안 그려짐" 이
    // 아니라 **도크 전체 정지**다 — `view` 가 실패하면 프레임을 못 낸다).
    //
    // 카드 하나가 쓰는 run 은 11 이라 여유 1 을 더해 12 다(제목·요약·provider·셰브런 넷 + 메타 줄의
    // 세그먼트 넷과 구분자 셋).
    const item_n = opts.items.len;
    const ops_budget = frame.tree.entries.len + 22 + item_n * 6 + 4;
    const runs_budget = 10 + item_n * 12 + 4;
    const text_budget = 1024 + item_n * 1024;
    const draws = component.view.view(props, frame, state.interaction, opts.tokens, .{
        .ops = try a.alloc(maru.chrome.draw.Op, ops_budget),
        .runs = try a.alloc(maru.chrome.draw.Run, runs_budget),
        .text_bytes = try a.alloc(u8, text_budget),
    }) catch return error.ViewFailed;

    // ── ChromeDraw → 화면 (measured 경로 — §2m.27 과 같은 순서) ──────────────────────────────
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
    // face 를 못 찾고, 글자가 하나도 안 그려진다(§2m.27 실측).
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

    var cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    const counted = try draw_host.appendChromeOps(a, draws.ops, opts.tokens, view_w, view_h, &cells);
    var gpu_glyphs: std.ArrayList(maru.renderer.metal_frame.GpuGlyph) = .empty;
    // **스크롤 목록의 글자만 뷰포트로 자른다.** 그 판정은 중립이 이미 실어 보낸다
    // (`draw.Op.Text.scroll_clipped`, 떠 있는 헤더는 `above_scroll` + 자기 rect) — `appendGpuGlyphs`
    // 가 그 규칙을 갖고 있는데 Windows 는 `null` 을 주어 **아무것도 안 자르고 있었다**. 목록이
    // 굴러가기 시작하자 카드 글자가 고정 헤더 위로 겹쳐 보였다(§2m.92).
    const list_clip: ?maru.renderer.metal_frame.ClipPx = if (component.build.scrollTextViewport(frame.tree)) |vp| .{
        .x = @intFromFloat(@max(vp.x, 0)),
        .y = @intFromFloat(@max(vp.y, 0)),
        .w = @intFromFloat(@max(vp.width, 0)),
        .h = @intFromFloat(@max(vp.height, 0)),
    } else null;
    try artifact.appendGpuGlyphs(a, render_frame, ctx.renderer_state.atlas.config, 0, 0, list_clip, 0, &gpu_glyphs);
    for (gpu_glyphs.items) |g| {
        try cells.append(a, win32_terminal.cellFromGpuGlyph(g, ctx.atlas_w.*, ctx.atlas_h.*));
    }

    var text: std.ArrayList(u8) = .empty;
    for (artifact.records) |r| {
        var b: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(r.codepoint), &b) catch continue;
        try text.appendSlice(a, b[0..n]);
    }

    return .{
        .arena = arena_state,
        .items = opts.items,
        .props = props,
        .frame = frame,
        .cells = cells.items,
        .text = text.items,
        .ops = draws.ops.len,
        .ops_text = counted.text,
        .ops_fill = counted.fill,
        .ops_dropped = counted.dropped,
        .atlas_region_uploads = uploads,
        .stats = maru.renderer.renderFrameStats(render_frame, ctx.renderer_state.atlas.entryCount()),
    };
}

/// 포인터 하나를 tree 로 라우팅한다 — SCM 표면과 **같은 두 함수**를 부른다.
pub const Routed = struct {
    intent: ?component.ids.Intent = null,
    /// **그림이 달라졌다.** intent 가 없어도 참일 수 있다 — 호버가 들고 나는 것도 그림이 바뀌는
    /// 일이다. 이것을 안 보면 마우스를 올려도 아무 표시가 안 난다(§2m.35 가 겪은 결함).
    dirty: bool = false,
};

pub fn pointer(
    built: *const Built,
    state: *State,
    phase: interaction.UiPointerPhase,
    x_px: f64,
    y_px: f64,
) Routed {
    // **SCM 표면과 같은 호출 모양이다**(`win32_scm_surface.pointer`) — 여기서 다른 순서로 부르면
    // 두 도크가 다른 규칙으로 반응한다.
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
    const action = dispatched.action orelse return .{ .dirty = dirty };
    // **`@constCast` 는 안전하다** — `resolve` 는 `self` 를 값으로 받고 읽기만 한다(SCM 표면의 그
    // 주석과 같은 이유). 표를 손으로 훑지 않는 이유는 `enabled` 와 **세대 판정**이 거기 있기
    // 때문이다: 직접 훑으면 꺼진 컨트롤도 눌리고, 옛 프레임의 action 도 살아난다.
    var table = component.ids.Table.init(@constCast(built.frame.actions));
    table.count = built.frame.actions.len;
    return .{ .intent = table.resolve(action, built.props.snapshot_generation), .dirty = dirty };
}

/// 누르고 떼는 한 벌 — 판정이 쓰기 좋게 묶어 둔다(`.up` 만 보내면 클릭이 안 난다: §2m.35).
pub fn click(built: *const Built, state: *State, x_px: f64, y_px: f64) ?component.ids.Intent {
    _ = pointer(built, state, .down, x_px, y_px);
    return pointer(built, state, .up, x_px, y_px).intent;
}

const testing = std.testing;

test "빈 목록도 조립이 성립한다 — 그것이 이 슬라이스의 성질이다" {
    // 세션이 하나도 없는 것은 **정상 상태**다(provider 이력이 없는 기계). 그때 버퍼 크기가 0 이
    // 되어 조립이 실패하면, 화면이 비는 것과 조립이 깨진 것을 구별할 수 없다.
    const bs = component.build.bufferSizes(&.{});
    try testing.expect(bs.nodes >= 8); // 헤더·범위 줄·검색·본문 + 정렬 토글
    try testing.expect(bs.entries > 0);
}
