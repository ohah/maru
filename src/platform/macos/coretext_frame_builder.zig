const std = @import("std");
const maru = @import("maru");
const app = maru.app;
const config = maru.config;
const icons = maru.icons; // 등록 chrome 아이콘 이름↔PUA codepoint(생성물) — codepoint 리터럴 대신 이름으로 고른다
const renderer = maru.renderer;
const terminal = maru.terminal;
const tabbar = maru.chrome.components.tabbar; // C4b-4: 탭 셀 경계 단일 소스(제목·✕가 hit-test·밴드와 같은 분할)
const sidebar_component = maru.chrome.components.sidebar; // 활동 시각 표기 폭(relative_age_cols) 단일 출처
const text_layout = maru.chrome.text_layout; // chrome 텍스트 셀 배치(분절·폭·말줄임) 단일 출처 — docs/layering-and-portability.md §7.9 CT-OWN
const text_field = maru.chrome.components.text_field; // 주소창 편집 밴드 단일 레이아웃 소스(fieldLayout — docs/text-field-editor.md §3)
const file_tree_icon = maru.chrome.file_tree_icon;
const dock_view_bar = maru.chrome.components.dock_view_bar;
const scm_view = maru.session.scm_view;
const git_status = maru.session.git_status;
const dock_layout = maru.session.dock_layout;
const dock_panel = maru.session.dock_panel;
const file_tree = maru.session.file_tree;
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
    // 실제 폰트 메트릭에서 온 cell 픽셀 크기(device px). cell_width_px = grid advance(자간 반영 — 합성 글리프 slot·배경),
    // glyph_cell_width_px = 폰트 글리프 자연폭(자간 무관 — 폰트 글리프 slot). shaper config로 흘러 atlas slot 폭이
    // glyph_id별로 갈린다(slotCellWidthPx). 0이면 폴백. 음수 자간 세로흔들림/squish 차단의 핵심 분리.
    cell_width_px: u16 = 0,
    glyph_cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,
    // 창이 포커스를 잃었을 때 활성 surface 커서를 어떻게 그릴지(config.cursor.unfocused). app_session이 매 frame
    // window_focused로 산출해 주입한다 — .normal이면 현행(반전 블록), .hollow/.hidden이면 renderer가 cursor
    // overlay를 그렇게 만든다(F1-4b-2). 활성 surface는 이 build 경로로 그려지므로 여기서 모드를 받아야 한다.
    cursor_unfocused: renderer.CursorUnfocused = .normal,

    pub fn build(
        self: CoreTextFrameBuilder,
        allocator: std.mem.Allocator,
        app_window: *maru.session.AppWindow,
        renderer_state: *renderer.RendererState,
        drain_summary: app.RuntimePumpDrainSummary,
        io: std.Io,
    ) !app.AppHostFrame {
        // FrameLoop는 "drain 뒤 active surface를 frame으로 만든다"는 순서만 소유한다.
        // macOS CoreText는 platform font/raster 경계라 app layer에 새면 안 되므로, 이
        // builder가 active TerminalCore snapshot을 DrawList -> CoreText GlyphRunList ->
        // RenderFrame으로 바꾸는 제품 후보 조립 책임을 맡는다.
        const active = app_window.active() orelse return error.NoActiveSurface;
        // renderSnapshot: 위로 스크롤한 상태면 뷰포트 윈도(스크롤백+활성)를 합성해 그린다. 바닥이면
        // snapshot()과 동일(합성 없음).
        //
        // I/O–렌더 스레딩 분리(docs/io-render-threading.md): 코어 읽기(renderSnapshot→buildDrawList,
        // 코어 메모리를 DrawList로 복사)는 **락 아래**, CoreText shaping(buildFromDrawList — DrawList
        // 복사본만 봄)은 **락 밖**. PR3에서 리더의 core.write가 CoreText shaping에 안 막히게 한다.
        active.lockCore(io);
        const list_or = renderer.buildDrawListWithUnfocused(allocator, active.renderSnapshot(), self.cursor_unfocused);
        active.unlockCore(io);
        const draw_list = try list_or;
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

    /// 활성 surface를 **shape까지만** 한다(build과 달리 place/raster·RenderFrame 없음 — atlas 무접촉). 멀티 페인
    /// 통합이 활성 panel을 다른 페인과 한 placeMultiPane(한 atlas 세대)에 합류시키려고 쓴다. 코어 lock은 build과
    /// 동형(읽기 락 아래 DrawList 복사, shape는 락 밖). place는 안 하지만 shape가 face를 intern하므로 공유
    /// `font_registry`(RendererState 소유)는 넘겨받는다 — atlas cache key의 FontId 안정성을 위해 다른 페인과 같은
    /// registry를 써야 한다(RendererState.font_registry 주석).
    pub fn shapeOnlyBuild(
        self: CoreTextFrameBuilder,
        allocator: std.mem.Allocator,
        app_window: *maru.session.AppWindow,
        font_registry: *renderer.FontIdentityRegistry,
        io: std.Io,
    ) !ShapedPane {
        const active = app_window.active() orelse return error.NoActiveSurface;
        active.lockCore(io);
        const list_or = renderer.buildDrawListWithUnfocused(allocator, active.renderSnapshot(), self.cursor_unfocused);
        // renderSnapshot이 뷰포트 합성에 실제로 쓴 view_offset을 **같은 락 아래**에서 같이 읽는다 — 호출자(app_session
        // 투영 게이트)가 "이 프레임이 그린 스크롤 위치"를 정확히 기록해, gate-read와 render-read 사이 리더 스크롤로
        // 어긋나는 read/render TOCTOU(스크롤 stale 재발) 없이 다음 tick의 재투영 여부를 판정한다.
        const rendered_view_offset = active.core.view_offset;
        active.unlockCore(io);
        const draw_list = try list_or;
        var pane = try self.shapeOnly(allocator, draw_list, font_registry);
        pane.view_offset = rendered_view_offset;
        return pane;
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
        // 단일 페인 경로는 멀티 페인 통합 빌드의 lists.len==1 특수화다: shapeOnly → placeMultiPane([1]) →
        // finishPane. 멀티 페인(app_session)은 여러 ShapedPane을 모아 한 번에 placeMultiPane해 cross-pane
        // 정합을 얻는다. 기존 호출자는 이 wrapper로 동작이 보존된다.
        var pane = try self.shapeOnly(allocator, draw_list, &renderer_state.font_registry);
        const frames = renderer_state.placeMultiPane(allocator, &.{pane.shaped.runs}) catch |e| {
            pane.deinit(allocator);
            return e;
        };
        defer allocator.free(frames);
        return self.finishPane(allocator, &pane, frames[0], renderer_state) catch |e| {
            // finishPane 실패 시 frame은 buildQuadRasterFromGlyphFrame이 정리하고, ShapedPane은 consume되지
            // 않았으므로 여기서 정리한다(성공 경로에선 finishPane이 consume하므로 pane.deinit을 부르지 않는다).
            pane.deinit(allocator);
            return e;
        };
    }

    /// DrawList(소유권 이전)를 **shape까지만** 한다 — atlas는 안 건드린다. 결과 ShapedPane이 owned_list·shaped를
    /// 소유한다. 멀티 페인은 이걸 모아 한 번에 `placeMultiPane`(통합 배치)한 뒤 `finishPane`으로 per-pane RenderFrame을
    /// 만든다. `font_registry`는 **호출자(RendererState)가 소유하는 공유 registry**를 빌려 intern한다 — atlas와 같은
    /// 수명이라 같은 PostScript name이 frame·pane을 넘어 같은 `FontId`를 받고, 그래야 frame 간 살아남는 atlas의
    /// cache key가 안정된다(RendererState.font_registry 주석 참고). 예전엔 shapeOnly가 registry를 per-pane으로
    /// 새로 만들어 순번이 frame마다 흔들렸고, 그게 조합 중 '놔'에 번개가 뜨던 atlas slot 오인 HIT의 루트커즈였다.
    pub fn shapeOnly(
        self: CoreTextFrameBuilder,
        allocator: std.mem.Allocator,
        draw_list: renderer.DrawList,
        font_registry: *renderer.FontIdentityRegistry,
    ) !ShapedPane {
        var owned_list = draw_list;
        var draw_list_owned = true;
        errdefer if (draw_list_owned) owned_list.deinit(allocator);

        const shaper = coretext_shaper.CoreTextDrawListShaper{
            .appearance = self.appearance,
            .shape_draw_list = self.shape_draw_list,
            // shaper config의 device_scale은 정수(정사각 fallback/cache key 거친 식별자)로만 쓰이고,
            // 실제 화면 경로는 아래 cell_width_px/cell_height_px(분수 메트릭)로 정밀 식별한다.
            .device_scale = renderer.deviceScaleFromMilli(self.scale_milli),
            .cell_width_px = self.cell_width_px,
            .glyph_cell_width_px = self.glyph_cell_width_px,
            .cell_height_px = self.cell_height_px,
        };
        const shaped = try shaper.shape(allocator, owned_list, font_registry);
        draw_list_owned = false;
        return .{ .owned_list = owned_list, .shaped = shaped };
    }

    /// A semantic Chrome text artifact may already own immutable, renderer-neutral shaped
    /// records. Rebuilding its frame must not synchronously enter CoreText again when the
    /// text/style/rect key is unchanged: this path recreates only the owned per-frame run list
    /// required by atlas placement and raster upload accounting.
    pub fn shapeFromRecords(
        self: CoreTextFrameBuilder,
        allocator: std.mem.Allocator,
        draw_list: renderer.DrawList,
        records: []const renderer.ShapedGlyphRecord,
    ) !ShapedPane {
        var owned_list = draw_list;
        var draw_list_owned = true;
        errdefer if (draw_list_owned) owned_list.deinit(allocator);

        const surface: renderer.ShapedGlyphSurface = .{
            .size = owned_list.size,
            .cursor = owned_list.cursor,
            .dirty = owned_list.dirty,
            .overlays = owned_list.overlays,
        };
        const shaped = try renderer.buildGlyphRunListFromShapedRecordsWithSurface(
            allocator,
            records,
            self.textLayoutConfig(),
            surface,
        );
        draw_list_owned = false;
        return .{ .owned_list = owned_list, .shaped = shaped };
    }

    fn textLayoutConfig(self: CoreTextFrameBuilder) renderer.TextLayoutConfig {
        var layout_config = renderer.textConfigFromFontSize(
            self.appearance.font.size,
            renderer.deviceScaleFromMilli(self.scale_milli),
        );
        layout_config.cell_width_px = self.cell_width_px;
        layout_config.glyph_cell_width_px = self.glyph_cell_width_px;
        layout_config.cell_height_px = self.cell_height_px;
        return layout_config;
    }

    /// 통합 place로 만든 GlyphFrame과 ShapedPane을 합쳐 per-pane RenderFrame을 만든다(rasterizer가
    /// `renderer_state.font_registry`를 참조해 비트맵 생성 — shape 때 intern한 그 공유 registry라 FontId가 일관).
    /// **ShapedPane을 consume한다**: 성공 시 owned_list가 RenderFrame으로 이동하고 shaped는 정리되므로, caller는
    /// 성공한 pane에 deinit을 부르면 안 된다. 실패 시 frame은 buildQuadRasterFromGlyphFrame이 정리하고, ShapedPane은
    /// consume되지 않아 caller가 pane.deinit으로 정리한다. font_registry는 공유(RendererState 소유)라 여기서 안 만진다.
    pub fn finishPane(
        self: CoreTextFrameBuilder,
        allocator: std.mem.Allocator,
        pane: *ShapedPane,
        frame: renderer.glyph_frame.GlyphFrame,
        renderer_state: *renderer.RendererState,
    ) !renderer.RenderFrame {
        const rasterizer = coretext_raster.CoreTextGlyphRasterizer{
            .appearance = self.appearance,
            .font_registry = &renderer_state.font_registry,
            .rasterize_glyph = self.rasterize_glyph,
            .scale_milli = self.scale_milli,
        };
        const render_frame = try renderer_state.buildQuadRasterFromGlyphFrame(allocator, pane.owned_list, frame, rasterizer);
        // 성공: owned_list가 render_frame으로 이동했다. shaped는 더 불필요 → 정리. font_registry는 공유라 유지.
        pane.shaped.deinit(allocator);
        return render_frame;
    }
};

/// shape만 끝낸 한 페인의 소유 상태(owned_list·shaped). 멀티 페인 통합 빌드의 중간 단위: 여러 ShapedPane을 모아
/// 한 번에 `placeMultiPane`한 뒤 `finishPane`으로 per-pane RenderFrame을 만든다. font_registry는 소유하지 않는다 —
/// shape 때 RendererState의 공유 registry에 intern했고 그건 atlas 수명이라 여기서 관리할 필요가 없다.
pub const ShapedPane = struct {
    owned_list: renderer.DrawList,
    shaped: renderer.ShapedGlyphRunList,
    // 이 페인을 그릴 때 renderSnapshot이 쓴 활성 surface view_offset(스크롤 위치). shapeOnlyBuild(활성 경로)만
    // 락 아래에서 채우고, 그 외 생성(비활성 pane·사이드바 — shapeOnly 직접)은 0(스크롤 추적 비대상). app_session
    // 투영 게이트가 last_rendered_view_offset에 이 값을 기록한다(render-time — read/render TOCTOU 방지).
    view_offset: usize = 0,

    /// shape 결과 전체를 정리한다(owned_list 포함). finishPane이 consume에 성공한 ShapedPane엔 호출하면
    /// 안 된다(double-free) — finishPane 실패 경로/place 실패 경로에서만 부른다. font_registry는 공유라 안 만진다.
    pub fn deinit(self: *ShapedPane, allocator: std.mem.Allocator) void {
        self.shaped.deinit(allocator);
        self.owned_list.deinit(allocator);
    }
};

/// 닫기(✕) 아이콘 코드포인트(U+2715 MULTIPLICATION X). 호버 슬롯 우측에 그린다.
pub const sidebar_close_glyph: u21 = 0x2715;

/// 고정(pin) 표시 glyph(U+1F4CC ROUND PUSHPIN). 고정된 워크스페이스 카드 이름줄 **우측 끝**에 그린다 — 선두가
/// 아니다. 선두 칼럼은 동작/활성 마커(·/*)를 위해 비워둔다(핀이 그 표시를 가리지 않게 — 사용자 요청). 📌는 컬러
/// 이모지라 외형(빨간 핀)이 cell fg와 무관하다(스타일 색은 영향 없음). 옛 설계는 이름 prefix("📌 ")로 선두에 박았다.
pub const sidebar_pin_glyph: u21 = 0x1F4CC;

/// `buildSidebarDrawList`의 아이콘 배열(`agents`·`inline_icons`) **공용 센티널** — 자리만 잡고 글리프는
/// 안 그린다. 아이콘 자산이 없는 일반 터미널 행이 쓴다: 0으로 두면 **그 행만** 라벨이 아이콘 폭만큼 왼쪽으로
/// 튀어 같은 목록 안에서 좌단이 어긋난다(gutter·인라인 양쪽에서 실측). 공백(U+0020)을 쓰는 이유는
/// "그릴 것이 없다"가 값 자체로 읽히기 때문이고, 실제 방출은 건너뛴다.
pub const icon_slot_reserve: u21 = ' ';

/// 세션 목록 행(= `inline_icons`를 쓰는 행)의 **행 전체 들여쓰기**(칸). 카드 하위 목록이라는 위계를 보이게 한다 —
/// 0이면 카드와 목록이 같은 좌단에서 시작해 "카드 아래 펼쳐진 목록"으로 안 읽혔다(사용자 피드백).
/// 아이콘이 이 열에 오고 이름 본문은 여기서 `icon_cols`만큼 더 간다. 보조줄은 호출자가 같은 자리에 맞춘다.
pub const session_row_indent_cols: u16 = 1;

/// gutter 아이콘이 있는 행의 **텍스트 시작 열**(아이콘 2칸 + 간격 1칸). 빌더가 이름줄을 이만큼 밀어 아이콘과
/// 겹치지 않게 한다.
///
/// **pub인 이유**: 이름줄 안의 열 좌표를 만드는 쪽이 이 폭을 알아야 한다. 사이드바 running 배지가 그렇다 —
/// 조립이 기록한 색 구간(`BadgeSpan`)과 색칠 루프가 보는 `c.col`이 같은 좌표계여야 하는데, 배지가 사는
/// `sessions` 토글 행은 삼각(▼)을 gutter에 실어 텍스트가 이만큼 밀린다. 그 폭을 여기서 파생하지 않고 3을
/// 따로 적으면 두 값이 조용히 어긋나 **색만 밀리는** 결함이 된다(실제로 그렇게 어긋났다 — 두 종류가 동시에
/// 도는 화면에서만 드러났다).
pub const sidebar_row_icon_cols: u16 = 3;

/// 카드 보조줄(branch/folder)에 maru가 의도적으로 박은 아이콘을 **렌더 폭 2칸**으로 치는 규칙 —
/// `text_layout`(L3)이 renderer를 import할 수 없어(경계 가드) predicate로 주입한다. advance(cellWidth)는 1이지만
/// 1칸(~8px)에 다운스케일하면 octocat·폴더 실루엣이 뭉개져 안 보였다(사용자 피드백) — 에이전트 gutter 아이콘
/// (별도 셀 width 2)과 같은 ~16px로 통일. `isRegisteredIcon`이 u32를 받아 얇게 감싼다.
fn wideIconGlyph(cp: u21) bool {
    return renderer.icon_glyph.isRegisteredIcon(cp);
}

/// 폭 판정 주입값. `widen_icons`=false(터미널·사용자 텍스트)면 확대 없음 — 등록 36개(0xF0001~0xF0025)가 Nerd Fonts v3
/// MDI(Plane-15 PUA)와 겹쳐, 제목/이름에 우연히 그 글리프가 와도 2칸으로 키우면 탭 텍스트와 rename caret 예약이
/// 틀어지기 때문이다. 그래서 maru가 아이콘을 직접 박는 카드 보조줄만 true.
fn wideIconPredicate(widen_icons: bool) ?text_layout.WideIconFn {
    return if (widen_icons) &wideIconGlyph else null;
}

/// title을 [start_col, end_col) 칸에 row행 DrawCell로 깐다. **배치(분절·폭·말줄임·앵커)는 chrome
/// `text_layout.plan`이 하고 여기는 그 결과를 CoreText용 셀·풀로 옮기기만 한다**(docs/layering-and-portability.md
/// §7.9 CT-OWN — 텍스트 의미는 OS-중립 계층 소유, platform은 방출 어댑터).
/// - `.head`(기본): 좌→우로 깔고 다 안 들어가면 **하드 컷 대신 마지막 칸을 "…"(U+2026)로** 바꿔 잘렸음을 표시(선두 고정).
/// - `.tail`: 넘치면 **선두**에 "…"를 두고 문자열 **끝**이 보이도록 앞 글자를 버린다(말미 고정 — rename 편집기의 caret 유지).
/// end_col<=start_col이면 무동작. 깨진 UTF-8 U+FFFD, wide 2칸. 사이드바 제목·pane 탭 바 제목·pane 라벨·rename 편집기가
/// 공유하는 잘림 규칙의 단일 출처라 잘림 표시가 일관된다. **다음 빈 col**(제목/말줄임 뒤)을 돌려줘, 호출자가 그 뒤를
/// 배경으로 채우는(솔리드 박스) 식으로 이어 그릴 수 있다. 글자만 추가하고 빈 칸은 채우지 않는다(중복 셀 없음). 순수(out append만).
fn appendEllipsizedTitle(
    allocator: std.mem.Allocator,
    cells: *std.ArrayList(renderer.DrawCell),
    pool: *std.ArrayList(u32), // grapheme cluster 본체(base 뒤 코드포인트) — 호출자가 DrawList.grapheme_pool로 넘긴다
    title: []const u8,
    row: u16,
    start_col: u16,
    end_col: u16,
    style: terminal.Style,
    widen_icons: bool, // 카드 보조줄(branch/folder)만 true — 등록 maru 아이콘을 2칸 렌더(wideIconPredicate)
    anchor: text_layout.Anchor,
) !u16 {
    var layout = text_layout.plan(title, start_col, end_col, anchor, wideIconPredicate(widen_icons));
    while (layout.next()) |item| switch (item) {
        .ellipsis => |col| try cells.append(allocator, .{ .row = row, .col = col, .codepoint = text_layout.ellipsis_glyph, .width = 1, .style = style }),
        .cluster => |c| try appendCluster(allocator, cells, pool, title, c, row, style),
    };
    return layout.endCol();
}

/// `text_layout`이 잡아 준 grapheme cluster **하나**를 셀 하나로 방출한다(docs/grapheme-clustering.md §3.1a CG1).
/// base 코드포인트는 셀에, 나머지(NFD 한글 V·T, 결합 악센트, VS16 같은 GB9 Extend)는 `pool`에 실어
/// `grapheme_offset/count`로 가리킨다 — 터미널 `buildDrawList`가 `snapshot.graphemes`로 하는 것과 같은 모양이고,
/// 셰이퍼가 base 뒤에 풀을 붙여 CoreText로 한 글리프를 만든다. 정규화는 하지 않는다(원본 코드포인트 그대로).
/// 분절·폭·한도 판정은 여기 없다 — cluster의 바이트 범위와 열·폭은 계획이 이미 정했다.
fn appendCluster(
    allocator: std.mem.Allocator,
    cells: *std.ArrayList(renderer.DrawCell),
    pool: *std.ArrayList(u32),
    title: []const u8,
    cluster: text_layout.Cluster,
    row: u16,
    style: terminal.Style,
) !void {
    const base = text_layout.decodeCodepoint(title, cluster.start);
    const end = cluster.end;
    const offset: u32 = @intCast(pool.items.len);
    var j = cluster.start + base.advance;
    // extra 개수는 **상한이 없다** — GB9가 결합 문자 런을 통째로 한 cluster로 삼키므로(Zalgo 텍스트·상한 없는
    // 주소창 URL) 65535를 넘을 수 있다. `grapheme_count`가 u16이라 그대로 @intCast하면 프레임 빌드 중 트랩으로
    // 앱이 죽는다 — 여기서 잘라 **열화 렌더**로 끝낸다(code-review max). 잘린 extra는 pool에도 안 남긴다(카운트와
    // 풀 내용이 어긋나면 셰이퍼가 남의 cluster를 이어 붙인다).
    const max_extra = @as(usize, std.math.maxInt(u16));
    while (j < end and j < title.len) {
        const extra = text_layout.decodeCodepoint(title, j);
        if (pool.items.len - offset >= max_extra) break;
        try pool.append(allocator, @as(u32, extra.cp));
        j += extra.advance;
    }
    try cells.append(allocator, .{
        .row = row,
        .col = cluster.col,
        .codepoint = base.cp,
        .grapheme_offset = offset,
        .grapheme_count = @intCast(pool.items.len - offset),
        .width = @intCast(@min(cluster.cols, 2)),
        .style = style,
    });
}

/// 주소창 **편집 밴드**를 `text_field.fieldLayout`(L3 단일 레이아웃 소스, docs/text-field-editor.md §3)로 셀 방출한다.
/// fieldLayout이 준 run(pre/preedit/post)·가로 스크롤·lead/tail "…"를 [nav_end, cols) 창에 클립해 깐다. caret은
/// **정적 반전 블록 셀**(docs/text-field-editor.md §6)로 그린다 — caret_block_col 칸의 글자를 커서색 반전(배경=caret_color=
/// theme.cursor, 글자=caret_text=theme.background)으로 다시 그려 **글자가 또렷이 보이면서**(불투명 블록은 글자를 가려 제보됨)
/// 터미널 커서와 같은 룩이 된다. 끝(칸에 글자 없음)이면 반전 공백=솔리드 블록. blink는 후속(§6 — 정적 셀이라 여기선 항상
/// 표시). caret 열이 hit-test(caretAtColumn)와 같은 fieldLayout 소스라 그려진 caret과 클릭 caret이 안 어긋난다(§2.3 벽②).
/// fieldLayout의 폭 규약(displayCols=Σ max(1,cellWidth))이 text_layout.clusterCols(아이콘 확대 없음)과 같아, 읽기전용
/// (appendEllipsizedTitle .head)과 편집 사이 열 점프가 없다(§3.2 전환 일치). codepoint당 셀(폭 max(1,cellWidth)).
fn emitEditBand(
    allocator: std.mem.Allocator,
    cells: *std.ArrayList(renderer.DrawCell),
    lay: text_field.FieldLayout, // 호출자가 프레임당 한 번 계산해 넘긴다(선택 quad와 공유, 리뷰 #9)
    nav_end: u16,
    cols: u16,
    style: terminal.Style,
    caret_color: terminal.Color, // 반전 블록 배경(=theme.cursor)
    caret_text: terminal.Color, // 반전 블록 위 글자색(=theme.background) — 글자가 "파여" 보임
) !void {
    const content_lo: i32 = @as(i32, nav_end) + @as(i32, if (lay.lead_ellipsis) 1 else 0);
    const content_hi: i32 = @as(i32, cols) - @as(i32, if (lay.tail_ellipsis) 1 else 0);
    const caret_bc: i32 = @intCast(lay.caret_block_col); // 반전 블록을 씌울 밴드 열
    const caret_style: terminal.Style = .{ .foreground = caret_text, .background = caret_color };
    var caret_drawn = false; // caret 칸에 글자가 있어 반전으로 그렸는가(끝이면 아래서 반전 공백)

    if (lay.lead_ellipsis) // 선두 "…"(앞이 스크롤로 잘렸음)
        try cells.append(allocator, .{ .row = 0, .col = nav_end, .codepoint = text_layout.ellipsis_glyph, .width = 1, .style = style });

    for (lay.runs) |run| {
        var col: i32 = run.start_col; // 밴드 열(스크롤되면 nav_end 왼쪽=음수 — 클립됨)
        var i: usize = 0;
        while (i < run.text.len) {
            const d = text_layout.decodeCodepoint(run.text, i);
            const w: i32 = text_layout.clusterCols(d.cp, null); // fieldLayout displayCols와 같은 규약 = Σ max(1,cellWidth)
            if (col >= content_lo and col + w <= content_hi) {
                const is_caret = (col == caret_bc); // 이 칸이 caret이면 반전색으로(글자 그대로 보이되 커서색 반전)
                if (is_caret) caret_drawn = true;
                try cells.append(allocator, .{ .row = 0, .col = @intCast(col), .codepoint = d.cp, .width = @intCast(@min(w, 2)), .style = if (is_caret) caret_style else style });
            }
            col += w;
            i += d.advance;
            if (col >= content_hi) break; // 우측 창 끝 넘음(나머지는 tail "…"가 대신)
        }
    }

    if (lay.tail_ellipsis) // 말미 "…"(뒤에 콘텐츠 더 있음)
        try cells.append(allocator, .{ .row = 0, .col = cols - 1, .codepoint = text_layout.ellipsis_glyph, .width = 1, .style = style });

    // caret이 끝(칸에 글자 없음)이면 반전 공백 = 솔리드 블록(터미널 끝 커서와 동일). 밴드 안일 때만.
    if (!caret_drawn and caret_bc >= nav_end and caret_bc < cols)
        try cells.append(allocator, .{ .row = 0, .col = @intCast(caret_bc), .codepoint = ' ', .width = 1, .style = caret_style });
}

/// pane 탭 바 우측 "+"(새 Term) 버튼이 차지하는 칸 수. 바 우측에 이만큼 예약하고 그 왼쪽을 탭 영역으로 쓴다.
pub const pane_tab_plus_cols: u16 = 3;

/// 바 cols에서 "+" 버튼 zone(pane_tab_plus_cols)을 뺀 탭 영역 cols. 바가 너무 좁으면(+ zone조차 못 둠) "+"
/// 없이 탭이 전체를 쓴다. 렌더(buildPaneTabBarDrawList)와 hit-test(tabIndexInBar 등)가 같은 값을 써서 보이는
/// 탭/+ 와 클릭이 일치한다. 순수 함수.
pub fn paneTabAreaCols(bar_cols: u16) u16 {
    return if (bar_cols > pane_tab_plus_cols + 1) bar_cols - pane_tab_plus_cols else bar_cols;
}

/// 사이드바 카드 row 인코딩 — 한 슬롯(**압축 카드 서수**) 안에서 (line_index, line_count)를 row에 싣는다. **디코드는
/// Zig**가 한다(SG3b-2-ii 옵션2): app_session.applySidebarGlyphPyTop이 slot=row/32, line_count=(row%32)/4,
/// line_index=(row%32)%4로 풀어 **rowTop 기반 py_top**(가변 높이 — 그룹 헤더 반영)을 셀 origin_y에 싣고, .m은 그 origin_y로
/// 세로 위치를 잡는다(옛 .m의 slot×slot_h 균일 기하 폐기 — code-review #1·#5·#6). 색칠 루프도 slot=row/32로 슬롯을 디코드한다.
/// line_count=1이면 단일행 중앙. 최대 4줄(이름·브랜치·경로·상태) 지원(base 32 — slot≤2047). 밴드 셀(slot_id=0)은 이 인코딩과
/// 무관하게 row=표시 row 인덱스 그대로(렌더러가 slot_id로 분기) — 여기를 인코딩 단일 출처로 고정한다. buildSidebarDrawList가
/// 4줄(이름·브랜치·경로·상태, `lines: [4]`)까지 쓰고, 슬롯 높이도 4줄을 담게 키웠다(sidebar_slot_height_ratio_milli=4600).
/// applySidebarGlyphPyTop이 base 32·×4를 decode에 쓰므로, 이 값을 바꾸면 아래 "인코딩 값 고정" 테스트가 깨져 동기 수정을 강제한다.
pub const sidebar_line_base: u16 = 32;
pub fn sidebarGlyphRow(slot: usize, line_index: u16, line_count: u16) u16 {
    return @as(u16, @intCast(slot)) *| sidebar_line_base +| line_count *| 4 +| line_index;
}

test "sidebarGlyphRow 인코딩 값 고정 (slot*32 + line_count*4 + line_index ↔ Zig applySidebarGlyphPyTop 디코더 결합)" {
    // app_session.applySidebarGlyphPyTop이 slot=row/32, line_count=(row%32)/4, line_index=(row%32)%4로 디코드해
    // rowTop 기반 py_top(origin_y)을 만든다(색칠 루프도 slot=row/32 사용). 아래 row 리터럴이 바뀌면 그 디코더도 동기
    // 수정해야 하므로 값으로 고정 — 인코딩만 바꾸고 디코더를 안 고치면 카드 glyph가 엉뚱한 슬롯/줄에 그려진다. 역산도 같이 검증한다.
    const cases = [_]struct { slot: u16, idx: u16, count: u16, row: u16 }{
        .{ .slot = 0, .idx = 0, .count = 1, .row = 4 }, // 1줄 중앙
        .{ .slot = 0, .idx = 0, .count = 3, .row = 12 }, // 3줄 위(이름)
        .{ .slot = 0, .idx = 2, .count = 3, .row = 14 }, // 3줄 아래(경로)
        .{ .slot = 0, .idx = 0, .count = 4, .row = 16 }, // 4줄 위(이름) — 상태줄 추가
        .{ .slot = 0, .idx = 3, .count = 4, .row = 19 }, // 4줄 맨 아래(상태)
        .{ .slot = 1, .idx = 0, .count = 1, .row = 36 }, // slot 1
        .{ .slot = 2, .idx = 2, .count = 3, .row = 78 },
        .{ .slot = 2, .idx = 3, .count = 4, .row = 83 }, // slot 2, 4줄 상태
    };
    for (cases) |c| {
        const row = sidebarGlyphRow(c.slot, c.idx, c.count);
        try std.testing.expectEqual(c.row, row);
        try std.testing.expectEqual(c.slot, row / 32); // .m 디코더 역산
        try std.testing.expectEqual(c.count, (row % 32) / 4);
        try std.testing.expectEqual(c.idx, (row % 32) % 4);
    }
}

/// 탭별 카드를 1~4줄로 합성한다: line0=이름(동작/활성 마커 ·/* 는 호출자가 이름 prefix로 붙임), 이어서 branches[i]·
/// paths[i]·statuses[i](각 있으면)를 한 줄씩. ""인 보조줄은 건너뛰어 줄 수가 줄고 남은 줄이 위로 당겨진다. `agents[i]`가
/// 0이 아니면 그 코드포인트(✶ claude/◆ codex)를 **슬롯 세로 중앙(count=1)·col 0·width 2(2칸)** 아이콘으로 따로 그리고,
/// 텍스트 줄은 그만큼(icon_cols=3) 우측으로 들여 아이콘이 줄 수와 무관하게 워크스페이스 가운데에 보이게 한다. `pinned[i]`면
/// 📌(sidebar_pin_glyph)를 이름줄 **우측 끝**에 그린다 — 선두가 아니라(선두는 마커 전용, 핀이 동작 표시를 안 가리게 —
/// 사용자 요청). 같은 행에 닫기 ✕(close_row)가 오면 그 왼쪽에 둔다. 세로 위치는 sidebarGlyphRow로 인코딩(렌더러가
/// 슬롯 안 블록 중앙 정렬). cols 넘으면 "…" 말줄임(핀이 있으면 이름은 핀 앞에서 자른다). 이름줄 전경색은 `fg`(활성 탭
/// active_fg+bold), 보조줄은 `fg`(흐림). 깨진 UTF-8은 U+FFFD. `close_row`면 그 슬롯 이름줄 우측 안쪽에 닫기 ✕ 1개. 순수
/// 함수라 OS 무관 단위 테스트.
pub fn buildSidebarDrawList(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    branches: []const []const u8,
    paths: []const []const u8,
    statuses: []const []const u8,
    agents: []const u21,
    /// inline_icons[i]=그 슬롯 **이름줄 선두**에 2칸으로 그릴 아이콘(0=없음). `agents`(왼쪽 독립 gutter)와
    /// **배타적으로** 쓴다 — gutter는 아이콘 하나 때문에 행의 **모든 줄**에서 3칸을 뺏고, 세로 중앙에 놓여
    /// 줄 수가 다른 행끼리 열을 이루지도 못한다(사용자 피드백). 세션 목록 행이 이 인라인 경로를 쓰고,
    /// 접기 토글 삼각(▶/▼)만 gutter에 남는다 — 그건 텍스트 줄에 두면 1칸이라 "눌러야 할 토글"로 안 읽혔다.
    ///
    /// **문자열에 섞지 않고 별도 셀로 내는 이유**: 이름줄은 `widen_icons=false`다(제목에 우연히 섞인 등록 PUA가
    /// 2칸으로 커지는 걸 막는 규칙). 아이콘을 이름 문자열 앞에 붙이면 그 규칙에 걸려 1칸으로 쪼그라든다 —
    /// 예전에 "깃 아이콘이 너무 작다"고 받은 그 현상이다. 핀(📌)과 같은 방식으로 셀을 따로 낸다.
    ///
    /// `icon_slot_reserve`는 **자리만 잡고 아무것도 안 그린다**. 아이콘 자산이 없는 일반 터미널 행이 쓴다 —
    /// 0으로 두면 그 행만 이름이 3칸 왼쪽에서 시작해 같은 목록 안에서 라벨 좌단이 들쭉날쭉해진다.
    inline_icons: []const u21,
    pinned: []const bool, // pinned[i]=true면 그 슬롯 이름줄 우측 끝에 📌(빈 슬라이스=핀 없음)
    cols: u16,
    fg: terminal.Color,
    close_rows: []const bool, // close_rows[i]=true면 그 row 우측에 닫기 ✕(호버 전용이 아니라 **행별 고정 표시**)
    ages: []const []const u8, // ages[i]=마지막 활동 상대 시각("5m"·"now", 빈 슬라이스=표시 안 함) — 이름줄 우측, ✕ 왼쪽
    plus_row: ?usize,
    active_row: ?usize,
    active_fg: terminal.Color,
    editing_row: ?usize, // rename 중인 슬롯(워크스페이스 카드·그룹 헤더). 그 슬롯 **이름줄(j==0)만** tail 앵커로 그려 caret(끝)을 유지한다.
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty; // cluster 본체(NFD 자모·결합 문자) — DrawList.grapheme_pool로 넘어간다
    errdefer pool.deinit(allocator);

    const style: terminal.Style = .{ .foreground = fg };
    const icon_cols: u16 = sidebar_row_icon_cols;
    var max_row: u16 = 0;
    for (names, 0..) |name, i| {
        if (i > @as(usize, std.math.maxInt(u16)) / sidebar_line_base) break; // slot*32+…가 u16 한도 안에 들게
        // 에이전트 아이콘: 슬롯 세로 중앙(count=1) col 0에 따로 — 3줄 블록과 무관하게 워크스페이스 가운데 고정.
        // 텍스트 줄은 아이콘이 있으면 icon_cols만큼 우측에서 시작(아이콘과 안 겹치게).
        const agent_cp: u21 = if (i < agents.len) agents[i] else 0;
        const inline_cp0: u21 = if (i < inline_icons.len) inline_icons[i] else 0;
        // 인라인 아이콘이 있는 행 = 카드 **하위 목록**이므로 행 전체를 `session_row_indent_cols`만큼 들여쓴다
        // (사용자 요청 — 카드와 목록의 위계가 안 보였다). gutter 행은 종전대로 아이콘 자리만큼만 민다.
        const text_col: u16 = if (agent_cp != 0) icon_cols else if (inline_cp0 != 0) session_row_indent_cols else 0;
        if (agent_cp != 0 and agent_cp != icon_slot_reserve) {
            const icon_row = sidebarGlyphRow(i, 0, 1);
            try cells.append(allocator, .{ .row = icon_row, .col = 0, .codepoint = agent_cp, .width = 2, .style = style });
            max_row = @max(max_row, icon_row);
        }
        // 이름줄 선두 아이콘(gutter의 대안 — 위 `inline_icons` 문서 참조). 아이콘은 `text_col`에 놓고 **이름줄만**
        // 그만큼 밀어, 보조줄(폴더·브랜치·응답)은 3칸을 그대로 쓴다. gutter처럼 모든 줄을 밀지 않는 것이 요점이다.
        const inline_cp: u21 = inline_cp0;
        const name_text_col: u16 = if (inline_cp != 0) text_col +| icon_cols else text_col;
        // 이 탭의 줄 모으기: 이름(항상) + 브랜치(있으면) + 경로(있으면) + 상태(에이전트면). 순서대로 line_index
        // 0,1,2,3을 부여. 빈 보조줄("")은 건너뛰어 1~4줄이 된다.
        // widen[j]: 그 줄이 maru가 아이콘을 박는 보조줄(branch/folder)이면 true → 등록 아이콘을 2칸 렌더. 이름줄·
        // 상태줄(사용자/에이전트 텍스트)은 false라, 거기에 우연히 등록 PUA cp(Nerd Fonts MDI 등)가 와도 폭이 안 커진다
        // (rename caret 예약 renameDisplayWidth는 1칸 셈 — 일치 유지). branches/paths만 widen, 나머지 false.
        var lines: [4][]const u8 = undefined;
        var line_widen: [4]bool = undefined;
        var n: u16 = 0;
        lines[n] = name;
        line_widen[n] = false;
        n += 1;
        if (i < branches.len and branches[i].len > 0) {
            lines[n] = branches[i];
            line_widen[n] = true; // 브랜치줄 octocat
            n += 1;
        }
        if (i < paths.len and paths[i].len > 0) {
            lines[n] = paths[i];
            line_widen[n] = true; // 폴더줄 folder 아이콘
            n += 1;
        }
        if (i < statuses.len and statuses[i].len > 0) {
            lines[n] = statuses[i];
            line_widen[n] = false;
            n += 1;
        }
        const active = active_row != null and active_row.? == i;
        // 고정 핀(📌): 이름줄(line 0) **우측 끝**에 둔다 — 선두 칼럼은 동작/활성 마커(·/*, 호출자가 이름 prefix로 붙임)
        // 전용이라 핀이 그걸 가리지 않게(사용자 요청). 핀은 width 2 + 컬러 이모지(빨간 핀, style.fg 무관)다. **cols-1은
        // 우측 패딩 1칸으로 예약**돼 있으므로(아래 end_col 주석: glyph_pad가 마지막 칸을 ~0.5칸 우측으로 밀어 경계 넘침),
        // 핀의 오른쪽 끝이 cols-2가 되도록 비호버는 pin_col=cols-3(→ cols-3,2 차지·cols-1 패딩 보존)에 둔다. 호버 슬롯이면
        // 닫기 ✕가 cols-2(width 1)에 오므로 핀은 그 왼쪽 pin_col=cols-5(→ cols-5,4·cols-3 gap·cols-2 ✕·cols-1 패딩)에.
        // 폭이 좁아 핀이 text_col을 침범하면 생략(degrade).
        const pinned_here = i < pinned.len and pinned[i];
        const close_here = i < close_rows.len and close_rows[i];
        // ✕ 열은 chrome이 단일 출처(`close_col_from_end`)이고 핀은 그 기준으로 자리를 잡는다 — 리터럴을 따로
        // 두면 ✕만 옮겨졌을 때 핀이 그 위에 겹친다.
        const close_from_end = sidebar_component.close_col_from_end;
        const pin_col: u16 = if (close_here) (cols -| (close_from_end + 3)) else (cols -| close_from_end);
        const draw_pin = pinned_here and cols >= 2 and pin_col > text_col;
        const name_row = sidebarGlyphRow(i, 0, n); // 이름줄(line 0) — j==0 줄과 핀이 공유(중복 계산 제거)
        // 활동 시각은 이름줄 우측(✕ 왼쪽)에 고정 폭으로 앉는다. 폭이 0이면 자리를 잡지 않아 제목이 끝까지 간다.
        const age_text: []const u8 = if (i < ages.len) ages[i] else "";
        const age_cols: u16 = @intCast(@min(age_text.len, @as(usize, sidebar_component.relative_age_cols)));
        var j: u16 = 0;
        while (j < n) : (j += 1) {
            const row = if (j == 0) name_row else sidebarGlyphRow(i, j, n);
            // 이름줄(j==0)만 활성 강조(active_fg+bold), 보조줄(브랜치·경로·상태)은 흐린 fg. bold는 셰이퍼가 bold face 선택.
            const row_style: terminal.Style = if (active and j == 0) .{ .foreground = active_fg, .bold = true } else style;
            // OSC 0/2(신뢰 불가)라 깨진 UTF-8은 U+FFFD, 폭 넘으면 "…" 말줄임(appendEllipsizedTitle 단일 출처).
            // **우측 패딩 1칸 예약(cols-1)**: 카드 글리프는 렌더러가 glyph_pad(=cw×0.5)만큼 오른쪽으로 미는데,
            // end_col=cols면 마지막 칸이 사이드바 경계를 반 칸 넘쳐 말줄임/텍스트가 경계에 붙어 답답했다(사용자
            // 피드백). cols-1로 두면 우측에 ~0.5칸 여백이 생겨 좌측 glyph_pad와 균형이 맞는다.
            // 핀이 있는 이름줄(j==0)은 핀 앞(pin_col)에서 잘라 긴 이름이 핀을 덮지 않게 한다(✕는 호버 전용이라 종전대로 overpaint).
            // ✕가 **고정 표시**로 바뀌었으므로 제목도 그 왼쪽에서 멈춰야 한다 — 예전엔 호버 순간에만 겹쳤지만 이제
            // 긴 이름·경로의 말줄임표 위에 ✕가 영구히 덧그려진다(code-review max). ✕는 cols-3이라 제목은 cols-4까지.
            const close_limit: u16 = if (close_here) (cols -| 4) else (cols -| 1);
            // 활동 시각이 있으면 이름줄 제목은 그 **왼쪽**에서 멈춘다(시각 폭 + 간격 1칸). 안 그러면 긴 제목의
            // 말줄임표 위에 시각이 덧그려져 둘 다 못 읽는다 — ✕에서 겪은 것과 같은 문제다.
            //
            // 예약은 실제 글자 수가 아니라 **고정 폭**(relative_age_cols)으로 잡는다. 실제 폭을 쓰면 `5m`인 행과
            // `12m`인 행의 제목이 서로 다른 col에서 잘려, 폭 상한을 둔 이유(잘리는 지점이 행마다 흔들리지 않게)가
            // 무효가 된다(code-review max).
            const age_limit: u16 = if (j == 0 and age_cols > 0) close_limit -| (sidebar_component.relative_age_cols + 1) else close_limit;
            const end_col: u16 = if (j == 0 and draw_pin) @min(pin_col, age_limit) else age_limit;
            // rename 중인 슬롯의 **이름줄(j==0)만** tail 앵커 — 긴 이름을 칠 때 선두를 "…"로 자르고 끝(caret)을 보여준다(탭·pane과 같은 규칙).
            // 보조줄(브랜치·경로·상태)은 rename 중 숨겨지므로 j>0은 늘 head다(편집 중엔 이름줄만 남는다).
            const line_anchor: text_layout.Anchor = if (j == 0 and editing_row != null and editing_row.? == i) .tail else .head;
            _ = try appendEllipsizedTitle(allocator, &cells, &pool, lines[j], row, if (j == 0) name_text_col else text_col, end_col, row_style, line_widen[j], line_anchor);
            max_row = @max(max_row, row);
        }
        // 이름줄 선두 아이콘 셀. 색은 `style`(브랜드 색칠 루프가 codepoint로 다시 집는다) — 활성 행의
        // active_fg+bold는 **글자에만** 적용한다(아이콘을 bold로 만들면 셰이퍼가 다른 face를 고른다).
        // 이름줄이 아이콘조차 못 담는 폭이면 생략한다(핀의 degrade와 같은 규율).
        if (inline_cp != 0 and inline_cp != icon_slot_reserve and name_text_col <= cols) {
            try cells.append(allocator, .{ .row = name_row, .col = text_col, .codepoint = inline_cp, .width = 2, .style = style });
            max_row = @max(max_row, name_row);
        }
        // 핀 글리프: 이름줄(name_row, n줄 블록 중앙) 우측. 컬러 이모지라 style.fg와 무관(빨간 핀 고정).
        if (draw_pin) {
            try cells.append(allocator, .{ .row = name_row, .col = pin_col, .codepoint = sidebar_pin_glyph, .width = 2, .style = style });
            max_row = @max(max_row, name_row);
        }
        // 활동 시각: 이름줄 우측 정렬. 보조줄이 아니라 이름줄에 두는 이유는 그 행이 "무엇을/언제"를 한 줄로 답해야
        // 하기 때문이다. 색은 보조줄과 같은 흐린 fg — 제목과 경쟁하면 안 된다.
        if (age_cols > 0) {
            // 핀이 있으면 그 **왼쪽**에 둔다. 예전엔 핀을 전혀 고려하지 않아 둘이 같은 칸에 덧그려질 수 있었다 —
            // 지금 호출부는 그런 행을 만들지 않지만(에이전트 행은 pins=false) 공개 draw-list API의 계약이므로
            // 여기서 지킨다(code-review max). 우측 정렬이라 고정 폭 슬롯의 오른쪽 끝에 붙인다.
            const age_right: u16 = if (draw_pin)
                pin_col -| 1
            else if (close_here) (cols -| 4) else (cols -| 1);
            const age_start: u16 = age_right -| age_cols;
            var ac: u16 = 0;
            var au = std.unicode.Utf8View.initUnchecked(age_text).iterator();
            while (au.nextCodepoint()) |cp| {
                if (ac >= age_cols) break;
                try cells.append(allocator, .{ .row = name_row, .col = age_start + ac, .codepoint = cp, .width = 1, .style = style });
                ac += 1;
            }
            max_row = @max(max_row, name_row);
        }
    }

    // 닫기 ✕ 아이콘: `close_rows[i]`인 **모든 행** 우측 안쪽 col에 glyph 1개(호버 전용이 아니라 고정 표시 —
    // 사용자 요청). cols가 2칸 이상일 때만(우측 여백
    // 확보). 제목이 길어 같은 col에 겹치면 painter 순서로 ✕가 위에 그려진다(긴 제목 자름은 후속).
    for (close_rows, 0..) |want_close, cr| {
        if (want_close and cr < names.len and cr <= @as(usize, std.math.maxInt(u16)) / sidebar_line_base and cols >= 2) {
            // ✕는 그 슬롯 이름줄(line 0)에. 슬롯 줄 수(이름+브랜치?+경로?+상태?)로 인코딩해 블록 중앙 정렬과 일치시킨다.
            var n: u16 = 1;
            if (cr < branches.len and branches[cr].len > 0) n += 1;
            if (cr < paths.len and paths[cr].len > 0) n += 1;
            if (cr < statuses.len and statuses[cr].len > 0) n += 1;
            const x_row = sidebarGlyphRow(cr, 0, n);
            try cells.append(allocator, .{
                .row = x_row,
                // 열 위치는 chrome `close_col_from_end` 단일 출처다. hit-test(`sidebar.closeButton`)가 같은
                // 값에서 x 구간을 내므로 "보이는 칸 = 눌리는 칸"이 구조적으로 보장된다.
                .col = cols -| sidebar_component.close_col_from_end,
                .codepoint = sidebar_close_glyph,
                .width = 1,
                .style = style,
            });
            max_row = @max(max_row, x_row);
        }
    }

    // 사이드바 하단 "+"(새 워크스페이스) 버튼 — 탭 목록 아래 슬롯(plus_row, 보통 탭 개수) 중앙(1줄)에 '+' glyph 1개를
    // 가로 중앙에 그린다. 렌더러가 사이드바 셀을 슬롯 높이로 배치하므로 마지막 탭 슬롯 아래에 놓인다.
    if (plus_row) |pr| {
        if (pr <= @as(usize, std.math.maxInt(u16)) / sidebar_line_base) {
            const prow = sidebarGlyphRow(pr, 0, 1); // "+" 슬롯 중앙(1줄)
            try cells.append(allocator, .{
                .row = prow,
                .col = cols / 2, // 가로 중앙
                .codepoint = '+',
                .width = 1,
                .style = style,
            });
            max_row = @max(max_row, prow);
        }
    }

    // pool을 **먼저** 떼어 낸다: 리터럴 안에서 마지막에 평가하면 cells 소유권이 이미 넘어간 뒤라
    // `errdefer cells.deinit`이 no-op이 되고, pool 할당 실패 시 cells 슬라이스가 샌다(code-review max).
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = cols, .rows = max_row + 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = max_row },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
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
    // **고정 폭은 하한이다(2026-08-18 사용자 요청).** 탭이 적으면 남는 폭을 나눠 **바를 꽉 채운다** —
    // 소스 컨트롤·히스토리·에이전트 도크의 탭이 그렇게 보이는데 터미널 탭 바만 오른쪽이 비어 톤이
    // 갈렸다. 탭이 많아 균등 폭이 고정 폭보다 좁아지면 고정 폭이 이기고(그때 넘치면 아래 ‹› 스크롤),
    // tui(fixed 0)는 예전처럼 항상 균등이다.
    const even = paneTabWidth(base, term_count);
    const tab_w = if (tab_width_fixed > 0) @max(tab_width_fixed, even) else even;
    if (tab_w == 0) return .{ .tab_cols = base, .tab_w = 0, .has_scroll = false, .eff_scroll = 0 };
    const total = @as(u32, @intCast(term_count)) * @as(u32, tab_w);
    // #4(리뷰): rich 고정폭(tab_width_fixed>0)만 스크롤한다 — tui 균등은 tab_w=1 collapse로 넘쳐도 ‹›를 안 띄움("tui 무변화" 유지).
    // ‹›(2칸) 둘 여유(base>2)도 필요.
    // ‹·› 는 각 `scroll_button_cols`(2칸) 이라 넷을 예약한다 — 옛 3칸(‹1·gap1·›1)은 클릭 폭이 한 칸이라
    // 실제로 누르기 어려웠다(사용자 보고 2026-08-18). 폭은 hit-test 와 **같은 상수**에서 나온다(§5.4).
    const scroll_zone_cols: u16 = @intCast(tabbar.Metrics.scroll_button_cols * 2);
    const has_scroll = tab_width_fixed > 0 and total > base and base > scroll_zone_cols; // 버튼 넷을 뗄 여유
    const tab_cols: u16 = if (has_scroll) base - scroll_zone_cols else base;
    // #1(리뷰): scroll를 [0, total-tab_cols]로 clamp + has_scroll 아니면 0 → 탭 닫기/리사이즈로 넘침이 사라지면 stale scroll가
    // 자동으로 0이 돼 빈 탭 바에 갇히지 않는다. 렌더·hit-test·클릭이 이 eff_scroll을 공유(§6).
    const eff_scroll: u32 = if (has_scroll) @min(scroll_cols, total - tab_cols) else 0;
    return .{ .tab_cols = tab_cols, .tab_w = tab_w, .has_scroll = has_scroll, .eff_scroll = eff_scroll };
}

/// pane 라벨 세그먼트(탭 바 좌측)의 glyph DrawList — 한 줄(row 0)에 사용자 지정 이름을 [1, cols-1) 칸에 깐다
/// (col 0 좌측 패딩, 마지막 칸은 탭과의 시각 간격). 넘치면 탭 제목과 같은 말줄임(appendEllipsizedTitle 단일
/// 출처). 색은 `fg`(호출자가 accent로 줘 탭 제목과 구분). cols<3이면(패딩+글자+간격 불가) 빈 DrawList — 호출자는
/// label_cols를 그 미만으로 예약하지 않는다. `anchor`=.tail이면(pane rename 중) 넘칠 때 선두를 "…"로 자르고 이름
/// **끝**(caret)을 보존한다 — 긴 이름을 칠 때 방금 친 글자가 안 사라지게. 평소(custom_name 표시)엔 .head(앞부분 표시).
/// 커서/overlay 없는 UI 텍스트라 OS 무관 단위 테스트.
pub fn buildPaneLabelDrawList(
    allocator: std.mem.Allocator,
    label: []const u8,
    cols: u16,
    fg: terminal.Color,
    anchor: text_layout.Anchor,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty; // cluster 본체(NFD 자모·결합 문자) — DrawList.grapheme_pool로 넘어간다
    errdefer pool.deinit(allocator);
    if (cols >= 3) {
        // [1, cols-1): col 0 = 좌측 패딩, 마지막 칸 = 탭과의 간격. 그 사이에 이름(말줄임 — rename 중이면 tail 앵커로 caret 유지).
        _ = try appendEllipsizedTitle(allocator, &cells, &pool, label, 0, 1, cols - 1, .{ .foreground = fg }, false, anchor); // pane 라벨(터미널 텍스트) — 아이콘 widen 안 함
    }
    // pool을 **먼저** 떼어 낸다: 리터럴 안에서 마지막에 평가하면 cells 소유권이 이미 넘어간 뒤라
    // `errdefer cells.deinit`이 no-op이 되고, pool 할당 실패 시 cells 슬라이스가 샌다(code-review max).
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = cols, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// Phase 7e-3: 주소창 nav 버튼 글리프(밴드 좌측 [0, nav_end) 존, 각 버튼당 `nav_button_w` 칸). back ←(U+2190)·
/// forward →(U+2192)·reload ⟳(U+27F3). 렌더와 hit-test(app_session.navButtonAt)가 **같은** `nav_button_w`/
/// `nav_button_count`를 공유해야 "보이는 버튼 == 클릭되는 버튼"이 성립한다 — 그래서 두 값은 app_session이 단일
/// 소스로 소유하고 여기로 주입한다(NavBarMetrics). 폰트에 화살표 글리프가 없으면 빈 칸 degrade(무해).
const nav_button_glyphs = [3]u21{ 0x2190, 0x2192, 0x27F3 }; // ← → ⟳ (back·forward·reload)

/// Phase 7e-1b/7e-3: browser(비신뢰) 웹 패널 주소창의 nav 버튼 + URL glyph DrawList — 한 줄(row 0)에 밴드 좌측
/// [0, nav_end)에 back/forward/reload 버튼(각 `nav_button_w` 칸, 존 가운데 칸에 글리프), 그 오른쪽 [nav_end, cols-1)에
/// 현재 URL/편집 텍스트를 깐다(마지막 칸은 우측 여백). `buildPaneLabelDrawList`와 같은 셀-정렬 1-row strip이되 URL 앵커는
/// **`.head`**(URL 앞부분 = scheme·host를 보존, 긴 경로는 말미를 "…"로 자름 — 주소창은 어디를 보는지가 먼저). URL 색은
/// `fg`(호출자가 muted로 줘 읽기전용 표시가 과하지 않게). 버튼은 활성(back=can_go_back·forward=can_go_forward·reload=항상)
/// 이면 `button_fg`, 비활성이면 더 흐린 `button_dim_fg`. 빈 url이면 URL 셀 없음(버튼만 보임). cols<3이면 빈 strip.
/// 편집 중(edit_view!=null)이면 URL 대신 fieldLayout(단일 레이아웃 소스, docs/text-field-editor.md §3)으로 편집 밴드를
/// 방출한다 — caret 위치가 hit-test와 같은 소스라 드리프트 0. 버튼은 편집 여부와 무관하게 늘 그린다(클릭은 nav action).
/// `nav_button_w`/`nav_button_count`는 app_session NavBarMetrics 단일 소스에서 주입 — hit-test와 정합.
/// 커서/overlay 없는 UI 텍스트라 OS 무관 단위 테스트(quad 금지, 셀 text만).
pub fn buildPaneAddressBarDrawList(
    allocator: std.mem.Allocator,
    url: []const u8,
    cols: u16,
    fg: terminal.Color,
    edit_layout: ?text_field.FieldLayout, // 슬라이스 2: 편집 중이면 fieldLayout(호출자가 한 번 계산·선택 quad와 공유)로 밴드 방출, null=읽기전용 URL. caret은 정적 반전 블록 셀(§6)
    caret_color: terminal.Color, // 편집 caret 반전 블록 배경(=theme.cursor) — edit_layout==null이면 미사용
    caret_text: terminal.Color, // caret 반전 블록 위 글자색(=theme.background)
    can_go_back: bool, // Phase 7e-3: back 버튼 활성(WKWebView.canGoBack) — webNavState에서 옴
    can_go_forward: bool, // forward 버튼 활성(WKWebView.canGoForward)
    button_fg: terminal.Color, // 활성 버튼 글리프 색
    button_dim_fg: terminal.Color, // 비활성(불가) 버튼 글리프 색(더 흐림)
    nav_button_w: u16, // 버튼당 셀 수(app_session NavBarMetrics 단일 소스, hit-test와 정합)
    nav_button_count: u16, // 버튼 개수(3 = back·forward·reload)
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty; // cluster 본체(NFD 자모·결합 문자) — DrawList.grapheme_pool로 넘어간다
    errdefer pool.deinit(allocator);
    if (cols >= 3) {
        // Phase 7e-3: 밴드 좌측 nav 버튼 존 [0, nav_end). 각 버튼 존 가운데 칸(i*nav_button_w + nav_button_w/2)에 글리프.
        // hit-test(navButtonAt)는 x_px를 nav_button_w로 나눠 같은 존을 판정하므로, 존 가운데 글리프는 늘 그 버튼 히트박스 안이다.
        const nav_end: u16 = nav_button_w *| nav_button_count;
        {
            var i: u16 = 0;
            while (i < nav_button_count and i < nav_button_glyphs.len) : (i += 1) {
                const center: u16 = i * nav_button_w + nav_button_w / 2;
                if (center >= cols) break; // 밴드가 좁으면(존이 밴드 밖) 그 버튼부터 생략 — 무해 degrade
                const active = switch (i) {
                    0 => can_go_back,
                    1 => can_go_forward,
                    else => true, // reload = 항상 활성
                };
                try cells.append(allocator, .{ .row = 0, .col = center, .codepoint = nav_button_glyphs[i], .width = 1, .style = .{ .foreground = if (active) button_fg else button_dim_fg } });
            }
        }
        // [nav_end, cols-1): 버튼 존 뒤부터 URL/편집 텍스트(마지막 칸 = 우측 여백). 밴드가 버튼 존 + 최소 1칸을 못 담으면
        // (nav_end >= cols-1) URL/편집 텍스트는 생략(버튼만). 편집 중이면 fieldLayout으로 mid-string caret·가로 스크롤
        // (넘치면 앞·뒤를 …로), 읽기전용은 head 앵커로 앞부분(scheme·host) 보존.
        if (nav_end < cols - 1) {
            if (edit_layout) |lay| {
                // 슬라이스 2: 편집 밴드는 fieldLayout(단일 레이아웃 소스)로 방출 — caret 위치가 hit-test(caretAtColumn)와
                // 같은 소스라 드리프트 0(§2.3 벽②, chrome-strategy §5.4 MUST). 읽기전용 URL은 아래 appendEllipsizedTitle(.head).
                try emitEditBand(allocator, &cells, lay, nav_end, cols, .{ .foreground = fg }, caret_color, caret_text);
            } else {
                _ = try appendEllipsizedTitle(allocator, &cells, &pool, url, 0, nav_end, cols - 1, .{ .foreground = fg }, false, .head); // 읽기전용 URL(head 앵커로 scheme·host 보존)
            }
        }
    }
    // pool을 **먼저** 떼어 낸다: 리터럴 안에서 마지막에 평가하면 cells 소유권이 이미 넘어간 뒤라
    // `errdefer cells.deinit`이 no-op이 되고, pool 할당 실패 시 cells 슬라이스가 샌다(code-review max).
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = cols, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false }, // caret은 emitEditBand가 반전 블록 셀로 그림(DrawList 커서 아님)
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// pane 탭 바 좌측 grip 핸들(pane 통째 드래그 손잡이)의 glyph DrawList — 한 줄(row 0)에 grip 글리프 ⠿
/// (U+283F, braille 6점 — 사용자 preview 손잡이 모양)를 **중앙 칸(cols/2)**에 깐다(좌·우 칸은 패딩 — 글리프가
/// 좌단·divider에 안 붙게). 폰트에 글리프가 없으면 빈 칸으로 degrade하지만, grip 영역은 paneBar가 예약하고 마우스
/// arm이 그 영역을 잡으므로 드래그는 그대로 동작한다. 색은 `fg`(호출자가 muted로 줘 손잡이가 과하지 않게).
pub fn buildPaneGripDrawList(
    allocator: std.mem.Allocator,
    cols: u16,
    fg: terminal.Color,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty; // cluster 본체(NFD 자모·결합 문자) — DrawList.grapheme_pool로 넘어간다
    errdefer pool.deinit(allocator);
    if (cols >= 1) {
        const c = cols / 2; // 글리프를 grip 영역 중앙 칸에 — 양쪽 패딩
        _ = try appendEllipsizedTitle(allocator, &cells, &pool, "\u{283F}", 0, c, c + 1, .{ .foreground = fg }, false, .head); // braille(아이콘 아님)
    }
    // pool을 **먼저** 떼어 낸다: 리터럴 안에서 마지막에 평가하면 cells 소유권이 이미 넘어간 뒤라
    // `errdefer cells.deinit`이 no-op이 되고, pool 할당 실패 시 cells 슬라이스가 샌다(code-review max).
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = cols, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// FP16 파일 Term 헤더 밴드(pane 탭 바 **아래** 한 줄). `부모 / 파일` breadcrumb + kind별 모드 선택기
/// (`읽기 | 소스`) + dirty ● + 외부변경 ! 를 셀로 그린다. 옛 도크 chrome 빌더의 1행을 그대로 물려받았고,
/// 0행(도크 탭)은 pane 탭 바가 대신하므로 사라졌다. 배치 권위는 `dock_layout.headerCellLayout` 하나다 —
/// 렌더·hit-test가 같은 cell 범위를 공유한다.
pub fn buildFilePanelHeaderDrawList(
    allocator: std.mem.Allocator,
    path: []const u8,
    kind: dock_panel.EntryKind,
    mode: dock_panel.Mode,
    dirty: bool,
    external_change: bool,
    cols: u16,
    fg: terminal.Color,
    active_fg: terminal.Color,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty; // cluster 본체(NFD 자모·결합 문자) — DrawList.grapheme_pool로 넘어간다
    errdefer pool.deinit(allocator);
    if (cols >= 1) {
        if (dock_layout.headerCellLayout(cols, dirty, external_change)) |header| {
            if (header.control_start > 1)
                _ = try appendEllipsizedTitle(allocator, &cells, &pool, path, 0, 1, header.control_start, .{ .foreground = fg }, false, .head);
            for (dock_layout.modesForKind(kind)) |descriptor| {
                const range = dock_layout.headerModeCellRange(header, kind, descriptor.mode) orelse continue;
                if (range.end > range.start + 1)
                    _ = try appendEllipsizedTitle(allocator, &cells, &pool, descriptor.label(), 0, range.start + 1, range.end, .{
                        .foreground = active_fg,
                        .bold = descriptor.mode == mode,
                    }, false, .head);
            }
            if (header.dirty_col) |col|
                try cells.append(allocator, .{ .row = 0, .col = col, .codepoint = 0x25CF, .width = 1, .style = .{ .foreground = active_fg } });
            if (header.conflict_col) |col|
                try cells.append(allocator, .{ .row = 0, .col = col, .codepoint = '!', .width = 1, .style = .{ .foreground = active_fg } });
        }
    }
    // pool을 **먼저** 떼어 낸다: 리터럴 안에서 마지막에 평가하면 cells 소유권이 이미 넘어간 뒤라
    // `errdefer cells.deinit`이 no-op이 되고, pool 할당 실패 시 cells 슬라이스가 샌다(code-review max).
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = @max(cols, 1), .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// FP7 project tree snapshot projection. rows는 이미 L2에서 natural-sort/open/dirty 상태를 결합한 immutable view다.
/// 이 함수는 보이는 row만 셀로 바꾸며 path나 filesystem을 읽지 않는다.
pub const file_tree_inset_cols: u16 = 1;

/// Artifact의 우측 독립 탐색기 제목 행. 실제 tree rows와 별도 draw list라 스크롤·클릭 인덱스에 섞이지 않는다.
/// 도크 뷰 스위처 한 행(docs/file-explorer.md §3.5). 슬롯마다 아이콘 1셀을 그리고 현재 뷰만 강조색을 쓴다.
/// 새 아이콘 자산을 만들지 않고 기존 `IconKind`(folder·git)를 재사용한다 — 합성 glyph 파이프라인·라이선스 기록을
/// 건드리지 않기 위해서다. 슬롯 자리는 chrome의 `dock_view_bar`가 계산한 것과 **같은 셀 수**를 쓴다.
pub fn buildDockViewBarDrawList(
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    active_index: usize,
    active_fg: terminal.Color,
    muted_fg: terminal.Color,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    const kinds = [_]file_tree_icon.IconKind{ .folder, .git, .code };
    const slot_cols: u16 = @intCast(dock_view_bar.slot_cols);
    for (kinds, 0..) |kind, index| {
        // 아이콘은 슬롯 안 좌측 여백 뒤에 **2칸으로** 놓는다. 합성 아이콘은 슬롯 크기에 맞춰 스케일되므로
        // (icon_glyph.fillCoverage: side = min(w, h)) 2칸이면 1칸일 때보다 또렷하고 크다 — 사이드바 에이전트
        // 아이콘이 같은 이유로 이미 `width = 2`다. 슬롯이 화면 밖이면 그리지 않는다.
        const col: u16 = @as(u16, @intCast(index)) *| slot_cols +| @as(u16, @intCast(dock_view_bar.icon_col_offset));
        if (col +| @as(u16, @intCast(dock_view_bar.icon_cols)) > cols) break;
        const cp = file_tree_icon.codepointFromRaw(@intFromEnum(kind)) orelse continue;
        try cells.append(allocator, .{
            // 밴드 가운데 행. 글리프는 행을 넘지 못하므로 세로 중앙은 홀수 행 밴드에서만 정확하다.
            .row = @max(rows, 1) / 2,
            .col = col,
            .codepoint = cp,
            .width = @intCast(dock_view_bar.icon_cols),
            .style = .{ .foreground = if (index == active_index) active_fg else muted_fg, .bold = index == active_index },
        });
    }
    return .{
        .size = .{ .cols = @max(cols, 1), .rows = @max(rows, 1) },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = @max(rows, 1) -| 1 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = try allocator.alloc(u32, 0),
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// 도크 AI 세션 목록 뷰의 행들. 한 행에 `<상태 마커> <라벨>` 한 줄이고, 라벨은 사이드바 에이전트 행과 **같은
/// 문자열**(마지막 사용자 프롬프트 우선)을 받는다 — 같은 것을 두 곳에서 다르게 부르지 않는다.
pub fn buildDockSessionListDrawList(
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    labels: []const []const u8,
    active_index: ?usize,
    fg: terminal.Color,
    active_fg: terminal.Color,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty;
    errdefer pool.deinit(allocator);
    const inset: u16 = file_tree_inset_cols;
    var r: u16 = 0;
    while (r < rows and r < labels.len) : (r += 1) {
        const is_active = active_index != null and active_index.? == r;
        const style: terminal.Style = .{ .foreground = if (is_active) active_fg else fg, .bold = is_active };
        if (cols > inset)
            _ = try appendEllipsizedTitle(allocator, &cells, &pool, labels[r], r, inset, cols, style, false, .head);
    }
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = @max(cols, 1), .rows = @max(rows, 1) },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = @max(rows, 1) -| 1 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

test "도크 뷰 바: 슬롯 3개가 모두 그려진다" {
    var dl = try buildDockViewBarDrawList(std.testing.allocator, 24, 1, 0, .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } });
    defer dl.deinit(std.testing.allocator);
    var count: usize = 0;
    for (dl.cells) |c| {
        count += 1;
        try std.testing.expectEqual(@as(u2, 2), c.width); // 2칸 아이콘
    }
    try std.testing.expectEqual(dock_view_bar.slot_count, count);
    // 미등록 PUA면 폰트 폴백으로 떨어져 **빈칸으로 보인다** — 세 아이콘 모두 합성 등록돼 있어야 한다.
    for (dl.cells) |c| try std.testing.expect(maru.renderer.icon_glyph.isRegisteredIcon(c.codepoint));
    // 한 줄짜리 바 — 세로 중앙은 렌더 origin이 패딩만큼 내려 맞춘다(app_session).
    for (dl.cells) |c| try std.testing.expectEqual(@as(u16, 0), c.row);
}

/// 도크 소스 컨트롤 뷰의 목록. 섹션 헤더는 `제목  N`, 파일 행은 `이름  흐린 경로  +N -N  X`다.
/// **폭이 좁아지면 경로가 먼저 줄어든다** — 파일명·증감·상태가 스캔의 축이라 끝까지 남긴다(§3.5).
/// 도크 뷰의 한 줄짜리 안내(빈 상태·읽는 중). 트리의 빈 안내와 같은 들여쓰기·흐린 색을 쓴다 — 같은 컬럼 안에서
/// 안내가 두 가지 모양이면 어느 것이 상태이고 어느 것이 내용인지 헷갈린다.
pub fn buildDockNoticeDrawList(
    allocator: std.mem.Allocator,
    cols: u16,
    text: []const u8,
    fg: terminal.Color,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty;
    errdefer pool.deinit(allocator);
    const inset: u16 = file_tree_inset_cols + 2;
    if (cols > inset)
        _ = try appendEllipsizedTitle(allocator, &cells, &pool, text, 0, inset, cols, .{ .foreground = fg }, false, .head);
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = @max(cols, 1), .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// 소스 컨트롤 목록. 첫 줄은 **브랜치 헤더**(브랜치 · upstream · ahead/behind)이고 그 아래가 섹션·파일 행이다.
/// 섹션 행은 접힘 표시(▸/▾)를 앞에 두고, 파일 행은 종류 아이콘을 둔다 — 탐색기와 같은 분류기를 쓴다.
pub fn buildDockScmDrawList(
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    /// `null`이면 헤더를 그리지 않고 **목록을 row 0부터** 그린다. 헤더는 스크롤에서 고정이고 목록만
    /// 픽셀 편향을 받으므로(SV3a), 둘을 같은 draw list에 담으면 그 편향이 헤더까지 끌고 간다.
    head: ?git_status.Head,
    model_rows: []const scm_view.Row,
    collapsed: []const bool,
    /// 선택된 행(모델 인덱스). 그 행을 강조해 **지금 보고 있는 비교가 어느 것인지** 남긴다.
    selected: ?usize,
    /// 첫 화면 행이 모델의 몇 번째인가(스크롤).
    scroll: usize,
    fg: terminal.Color,
    muted: terminal.Color,
    accent: terminal.Color,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty;
    errdefer pool.deinit(allocator);
    const inset: u16 = file_tree_inset_cols;
    var r: u16 = 0;

    // ── 브랜치 헤더. 아이콘 + 브랜치 이름 + (upstream 대비) ahead/behind. upstream이 없으면 그 자리를 비운다.
    if (head) |h| if (rows > 0 and cols > inset + 2) {
        try cells.append(allocator, .{ .row = 0, .col = inset, .codepoint = icons.codepoint(.git_branch), .width = 2, .style = .{ .foreground = muted } });
        var tail_buf: [32]u8 = undefined;
        var tail: []const u8 = "";
        if (h.has_ab) {
            tail = std.fmt.bufPrint(&tail_buf, "↑{d} ↓{d}", .{ h.ahead, h.behind }) catch "";
        }
        const tail_cols: u16 = @intCast(std.unicode.utf8CountCodepoints(tail) catch tail.len);
        const name_end = cols -| tail_cols -| 1;
        const branch = if (h.detached) "(detached)" else (h.branch orelse maru.i18n.t(.fp_no_branch));
        if (inset + 3 < name_end)
            _ = try appendEllipsizedTitle(allocator, &cells, &pool, branch, 0, inset + 3, name_end, .{ .foreground = fg, .bold = true }, false, .head);
        if (tail.len > 0 and tail_cols < cols) {
            var col = cols - tail_cols;
            var it = std.unicode.Utf8Iterator{ .bytes = tail, .i = 0 };
            while (it.nextCodepoint()) |cp| : (col += 1) {
                try cells.append(allocator, .{ .row = 0, .col = col, .codepoint = cp, .width = 1, .style = .{ .foreground = muted } });
            }
        }
        r = 1;
    };

    for (model_rows, 0..) |row, model_index| {
        if (r >= rows) break;
        const is_selected = selected != null and selected.? == scroll + model_index;
        switch (row) {
            .section => |sec| {
                var buf: [16]u8 = undefined;
                const count = std.fmt.bufPrint(&buf, "{d}", .{sec.count}) catch "";
                // 접힘 표시를 제목 앞에 둔다 — 눌러서 접을 수 있다는 것이 보여야 한다(눌러보기 전에 알 수 있게).
                const folded = @intFromEnum(sec.section) < collapsed.len and collapsed[@intFromEnum(sec.section)];
                // 들여쓰기 한 칸조차 못 들어가는 폭이 실제로 온다(도크를 끝까지 좁히면 cols=1) — 그때 이
                // 셀을 그대로 쓰면 격자 밖 열이 된다.
                if (inset < cols) try cells.append(allocator, .{
                    .row = r,
                    .col = inset,
                    .codepoint = if (folded) '>' else 'v',
                    .width = 1,
                    .style = .{ .foreground = muted },
                });
                // 일괄 동작(`+`/`−`)은 **호버에만** 뜨는 컨트롤이라 이 셀 그리드 표면에서는 그리지 않는다
                // (호버가 없다 — P1b 컴포넌트 이관에서 붙는다). 개수만 오른쪽 끝에 고정한다.
                const count_col = cols -| @as(u16, @intCast(count.len));
                const title_col = inset + 2;
                if (cols > title_col and count_col > title_col)
                    _ = try appendEllipsizedTitle(allocator, &cells, &pool, sec.section.title(), r, title_col, count_col, .{ .foreground = fg, .bold = true }, false, .head);
                // 개수는 오른쪽 끝에 고정한다 — 제목이 길어져도 개수가 밀려 사라지지 않는다.
                if (count_col > title_col) appendAscii(&cells, allocator, count, r, count_col, .{ .foreground = muted }) catch {};
            },
            .notice => |notice| {
                // 컨트롤이 아니라 상태 진술이라 강조색을 쓰지 않는다(빈 안내와 같은 흐린 색).
                if (cols > inset + 2)
                    _ = try appendEllipsizedTitle(allocator, &cells, &pool, notice.text(), r, inset + 2, cols, .{ .foreground = muted }, false, .head);
            },
            .more => |more| {
                // "모두 보기 (N개 더)" — 숨은 개수를 말한다. 조용히 자르면 사용자는 파일이 사라졌다고 읽는다.
                var buf: [48]u8 = undefined;
                const text = maru.i18n.format(&buf, maru.i18n.t(.scm_show_all_more), &.{.{ .d = @intCast(more.hidden) }});
                if (cols > inset + 2)
                    _ = try appendEllipsizedTitle(allocator, &cells, &pool, text, r, inset + 4, cols, .{ .foreground = accent }, false, .head);
            },
            .file => |file| {
                // 오른쪽부터 자리를 잡는다: 상태 문자 + 증감. 남는 폭이 이름·경로 몫이다.
                var delta_buf: [24]u8 = undefined;
                const delta: []const u8 = if (file.unknown_delta)
                    ""
                else if (file.binary)
                    "bin"
                else
                    std.fmt.bufPrint(&delta_buf, "+{d} -{d}", .{ file.added, file.removed }) catch "";
                // 오른쪽 끝은 **상태 문자**다(VS Code 배치). 행 동작(`+`/`−`)은 호버에만 뜨므로 이 표면엔 없다.
                const letter_col = cols -| 1;
                const delta_col = letter_col -| @as(u16, @intCast(delta.len)) -| 1;
                const name = std.fs.path.basename(file.path);
                const dir = file.path[0 .. file.path.len - name.len];
                // 종류 아이콘은 탐색기와 **같은 분류기**를 쓴다 — 같은 파일이 두 화면에서 다른 아이콘이면 안 된다.
                if (file_tree_icon.codepoint(file_tree_icon.classify(.file, name, false))) |cp| {
                    // 아이콘은 **2칸**이라 시작 열 + 2가 끝을 넘지 않아야 한다(1칸짜리 판정으로 재면 반 칸이 샌다).
                    if (inset + 1 + 2 <= cols)
                        try cells.append(allocator, .{ .row = r, .col = inset + 1, .codepoint = cp, .width = 2, .style = .{ .foreground = muted } });
                }
                var col = inset + 4;
                const name_style: terminal.Style = if (is_selected)
                    .{ .foreground = accent, .bold = true } // 선택 행은 이름을 강조 — 어느 비교를 보고 있는지 남는다
                else
                    .{ .foreground = fg };
                if (col < delta_col)
                    col = try appendEllipsizedTitle(allocator, &cells, &pool, name, r, col, @min(delta_col, cols), name_style, false, .head);
                if (dir.len > 0 and col + 1 < delta_col)
                    _ = try appendEllipsizedTitle(allocator, &cells, &pool, dir, r, col + 1, delta_col, .{ .foreground = muted }, false, .head);
                // **끝 열까지 들어가는지로 판정한다.** `delta_col`은 포화 뺄셈이라 폭이 아주 좁으면 0으로
                // 내려앉는데, 시작 열만 보면 그때 격자 **밖** 열에 셀을 쓴다(도크를 좁게 끌면 재현).
                if (delta.len > 0 and delta_col +| @as(u16, @intCast(delta.len)) <= cols)
                    appendAscii(&cells, allocator, delta, r, delta_col, .{ .foreground = muted }) catch {};
                if (letter_col < cols)
                    try cells.append(allocator, .{ .row = r, .col = letter_col, .codepoint = file.letter, .width = 1, .style = .{ .foreground = accent, .bold = true } });
            },
        }
        r += 1;
    }
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = @max(cols, 1), .rows = @max(rows, 1) },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = @max(rows, 1) -| 1 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

fn appendAscii(cells: *std.ArrayList(renderer.DrawCell), allocator: std.mem.Allocator, text: []const u8, row: u16, col: u16, style: terminal.Style) !void {
    for (text, 0..) |ch, i| {
        try cells.append(allocator, .{ .row = row, .col = col +| @as(u16, @intCast(i)), .codepoint = ch, .width = 1, .style = style });
    }
}

pub const FileTreeEdit = struct { identity: file_tree.RowIdentity, text: []const u8 };
pub const FileTreeSelectionPaint = struct {
    /// Absolute index in `rows`; the background renderer resolves the same transient selection index.
    index: usize,
    /// Theme-derived foreground with guaranteed contrast against the focused accent background.
    foreground: terminal.Color,
};

pub fn buildFileTreeDrawList(
    allocator: std.mem.Allocator,
    rows: []const file_tree.Row,
    edit: ?FileTreeEdit,
    scroll_rows: usize,
    visible_rows: u16,
    cols: u16,
    fg: terminal.Color,
    active_fg: terminal.Color,
    selection: ?FileTreeSelectionPaint,
    /// `IconKind` 순서대로 푼 아이콘 색(없으면 행 색을 그대로 쓴다). **분류→색 매핑은 chrome 이 소유**하고
    /// (`file_tree_icon.colorRole`) 호출자가 그것을 토큰으로 풀어 넘긴다 — 렌더가 자기 표를 들면 새
    /// `IconKind` 를 더할 때 한쪽만 갱신된다.
    icon_colors: ?[]const ?terminal.Color,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty; // cluster 본체(NFD 자모·결합 문자) — DrawList.grapheme_pool로 넘어간다
    errdefer pool.deinit(allocator);
    const count = @min(@as(usize, visible_rows), rows.len -| @min(scroll_rows, rows.len));
    for (rows[@min(scroll_rows, rows.len)..][0..count], 0..) |row, screen_row| {
        const r: u16 = @intCast(screen_row);
        const selected = if (selection) |v| v.index == scroll_rows + screen_row else false;
        var label: []const u8 = "";
        var depth: u16 = 0;
        var marker: u21 = ' ';
        var style: terminal.Style = .{ .foreground = fg };
        var dirty = false;
        var conflict = false;
        switch (row) {
            .recent_header => |v| {
                label = maru.i18n.t(.fp_recent_files);
                marker = if (v.collapsed) '>' else 'v';
                style = .{ .foreground = active_fg, .bold = true };
            },
            .recent_file => |v| {
                label = v.label;
                depth = v.depth;
                marker = if (v.active) '*' else ' ';
                style = .{ .foreground = if (v.active) active_fg else fg, .bold = v.active };
                dirty = v.dirty;
                conflict = v.external_change;
            },
            .root => |v| {
                label = v.label;
                marker = if (v.loading) '~' else if (v.expanded) 'v' else '>';
                style = .{ .foreground = active_fg, .bold = true };
            },
            .directory => |v| {
                label = v.label;
                depth = v.depth;
                marker = if (v.loading) '~' else if (v.expanded) 'v' else '>';
            },
            .file => |v| {
                label = v.label;
                depth = v.depth;
                marker = if (v.active) '*' else if (v.open) '+' else ' ';
                style = .{ .foreground = if (v.active) active_fg else fg, .bold = v.active };
                dirty = v.dirty;
                conflict = v.external_change;
            },
            .empty => {
                label = maru.i18n.t(.fp_open_to_show_tree);
            },
        }
        if (edit) |active_edit| if (file_tree.rowIdentity(row)) |identity| {
            if (identity.eql(active_edit.identity)) {
                label = active_edit.text;
                style = .{ .foreground = active_fg, .bold = true };
            }
        };
        // Focused selection paints the whole row with the theme accent in AppSession. Every glyph on
        // that row (marker, title, dirty/conflict state) must therefore use the paired contrast color;
        // retaining per-row muted/active colors makes light accents unreadable.
        if (selected) style.foreground = selection.?.foreground;
        const state_cols: u16 = if (conflict) 4 else if (dirty) 2 else 0;
        const end = cols -| state_cols;
        const indent: u16 = @min(file_tree_inset_cols +| depth *| 2, cols -| 1);
        if (indent < end) try cells.append(allocator, .{ .row = r, .col = indent, .codepoint = marker, .width = 1, .style = style });
        const icon_raw = file_tree.rowIconKind(row);
        const icon = file_tree_icon.codepointFromRaw(icon_raw);
        const icon_col = indent +| 2;
        // 선택된 행은 accent 로 통째로 칠해지므로 아이콘도 그 대비색을 따른다(위 주석과 같은 이유) —
        // 종류 색을 남기면 밝은 accent 위에서 읽히지 않는다.
        var icon_style = style;
        if (!selected) if (icon_colors) |colors| {
            if (icon_raw < colors.len) if (colors[icon_raw]) |c| {
                icon_style.foreground = c;
            };
        };
        if (icon) |cp| if (icon_col < end)
            try cells.append(allocator, .{ .row = r, .col = icon_col, .codepoint = cp, .width = 1, .style = icon_style });
        const label_col = if (icon != null) icon_col +| 2 else icon_col;
        if (label_col < end)
            _ = try appendEllipsizedTitle(allocator, &cells, &pool, label, r, label_col, end, style, false, .head);
        if (dirty and cols >= 2)
            try cells.append(allocator, .{ .row = r, .col = cols - 2, .codepoint = 0x25CF, .width = 1, .style = .{ .foreground = if (selected) selection.?.foreground else active_fg } });
        if (conflict and cols >= 4)
            try cells.append(allocator, .{ .row = r, .col = cols - 4, .codepoint = '!', .width = 1, .style = .{ .foreground = if (selected) selection.?.foreground else active_fg, .bold = true } });
    }
    // pool을 **먼저** 떼어 낸다: 리터럴 안에서 마지막에 평가하면 cells 소유권이 이미 넘어간 뒤라
    // `errdefer cells.deinit`이 no-op이 되고, pool 할당 실패 시 cells 슬라이스가 샌다(code-review max).
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = @max(cols, 1), .rows = @max(visible_rows, 1) },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = visible_rows -| 1 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// 상태표시줄 항목 하나(아이콘 + 텍스트) 한 줄짜리 DrawList. 항목마다 **자기 frame**을 만들고 호출자가
/// px origin에 놓는다(`chrome.components.status_bar`가 그 origin을 정한다) — 상태바는 터미널 grid 밖이라
/// grid 행/열로는 그릴 수 없고(`metal_frame`이 `row >= frame.size.rows`를 버린다), 우측 정렬도 셀 경계가
/// 아니라 창 가장자리에 붙어야 하기 때문이다. 아이콘은 2칸(사이드바 브랜치 줄과 같은 폭 규약), 그 뒤 1칸을
/// 띄고 텍스트가 온다. 텍스트가 `max_text_cols`를 넘으면 말줄임한다 — 배치는 글자를 자르지 않으므로
/// (`status_bar` doc) 자르는 일은 여기서 한다.
pub fn buildStatusBarItemDrawList(
    allocator: std.mem.Allocator,
    icon: ?u21,
    text: []const u8,
    max_text_cols: u16,
    fg: terminal.Color,
    icon_fg: terminal.Color,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty;
    errdefer pool.deinit(allocator);

    var col: u16 = 0;
    if (icon) |cp| {
        try cells.append(allocator, .{ .row = 0, .col = col, .codepoint = cp, .width = 2, .style = .{ .foreground = icon_fg } });
        col += 3; // 아이콘 2칸 + 1칸 여백
    }
    if (text.len > 0 and max_text_cols > 0) {
        _ = try appendEllipsizedTitle(allocator, &cells, &pool, text, 0, col, col +| max_text_cols, .{ .foreground = fg }, false, .head);
    }

    // 실제로 쓴 마지막 칸 + 1 = 이 frame의 폭. 말줄임 뒤 폭이 줄 수 있으므로 셀에서 되읽는다.
    var used: u16 = col;
    for (cells.items) |c| {
        const end = c.col +| @as(u16, c.width);
        if (end > used) used = end;
    }
    // **cluster 풀을 반드시 함께 싣는다.** `appendEllipsizedTitle`이 NFD 음절 같은 다중 codepoint 클러스터를
    // 이 풀에 담고 셀은 그 인덱스를 가리키므로, 풀을 버리면 셰이퍼가 base만 그려 한글 중성·종성이 사라진다
    // (tests/boundary/chrome_text_clusters.zig CG1이 이 누락을 잡는다 — 실제로 이 함수에서 한 번 잡혔다).
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = used, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

pub fn buildFileDockToggleDrawList(allocator: std.mem.Allocator, fg: terminal.Color) !renderer.DrawList {
    const cells = try allocator.alloc(renderer.DrawCell, 1);
    errdefer allocator.free(cells);
    cells[0] = .{ .row = 0, .col = 0, .codepoint = icons.codepoint(.sidebar_collapse), .width = 1, .style = .{ .foreground = fg } }; // maru PUA 아이콘(sidebar-collapse ◧) — 렌더러가 이 codepoint를 1.7× 확대(app_session §20073, dest=.dock_toggle 게이트). 작은 Unicode 0x25E7 대신 써 왼쪽 헤더 아이콘과 동일 크기. col 0 단일 셀 — 호출부가 origin_x 반칸 밀어 rect 중앙 정렬.
    return .{
        .size = .{ .cols = 1, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = cells,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

pub fn buildPaneTabBarDrawList(
    allocator: std.mem.Allocator,
    titles: []const []const u8,
    cols: u16,
    fg: terminal.Color,
    close_all: bool, // true면 **모든 탭**에 닫기 ✕(호버 전용이 아니라 고정 표시 — 사용자 요청)
    active_tab: ?usize,
    active_fg: terminal.Color,
    tab_width_fixed: u16, // 0=균등분할(tui — 바를 탭 수로 나눔), >0=탭 고정 폭(rich). barMetrics와 같은 값이라 보이는 탭=클릭 탭 정합(§6)
    scroll_cols: u32, // Step 2: 가로 스크롤 offset(컬럼) — segCols에 전달해 보이는 탭 창을 왼쪽으로 민다. 0=기본. barMetrics와 같은 값(정합).
    editing_tab: ?usize, // rename 중인 Term 탭 인덱스(없으면 null). 그 탭 제목만 tail 앵커로 그려 caret(문자열 끝)를 세그먼트 안에 유지한다.
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty; // cluster 본체(NFD 자모·결합 문자) — DrawList.grapheme_pool로 넘어간다
    errdefer pool.deinit(allocator);

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
            // 닫기 ✕는 우측 안쪽(seg_end-2)에 두고 **좌우로 한 칸씩 비운다**: 제목은 seg_end-3까지만(✕ 왼쪽 1칸),
            // ✕ 오른쪽 seg_end-1도 패딩으로 남는다. 예전엔 제목 끝이 ✕ 칸과 맞닿아 말줄임표("…")가 ✕에 붙거나
            // 겹쳐 보였다(사용자 피드백). ✕+좌우 패딩(3칸)에 제목 최소 1칸까지 확보되는 폭에서만 ✕를 그린다 —
            // 그보다 좁으면 제목이 통째로 사라지므로 ✕를 접는다.
            // 게이트는 **보이는 폭**(seg_end-start) 기준 5칸 — 좌패딩1 + 제목최소1 + ✕좌여백1 + ✕1 + ✕우여백1.
            // nominal tab_w로 판정하면 우단에서 잘린 탭이 ✕를 이웃 칸에 그리고 제목이 통째로 사라진다(code-review max).
            // tabbar.segOf의 has_close와 **같은 조건**이어야 "보이는 ✕ == 클릭되는 ✕"가 성립한다.
            const is_close = close_all and seg_end > start and (seg_end - start) >= 5;
            const title_end: u32 = if (is_close) seg_end - 3 else seg_end;
            // 활성 Term 탭은 글자를 강조색(active_fg) + bold로, 나머지는 fg(흐림) regular로 — 활성 탭 글자 강조.
            // bold는 셰이퍼가 bold 폰트 face를 골라 실제 굵은 글리프를 그린다(사이드바 활성 행과 같은 규칙).
            const tab_style: terminal.Style = if (active_tab != null and active_tab.? == tab_index) .{ .foreground = active_fg, .bold = true } else style;
            // 좌측 1칸 패딩 뒤에 제목. title_end(✕ 앞)를 넘으면 하드 컷이 아니라 "…"로 말줄임(사이드바와 같은 규칙).
            // rename 중인 탭이면 tail 앵커 — 넘칠 때 선두를 "…"로 자르고 이름 끝(caret)을 세그먼트 안에 유지한다(긴 이름 입력 가시성).
            const tab_anchor: text_layout.Anchor = if (editing_tab != null and editing_tab.? == tab_index) .tail else .head;
            _ = try appendEllipsizedTitle(allocator, &cells, &pool, title, 0, @intCast(start + 1), @intCast(title_end), tab_style, false, tab_anchor); // pane 탭 제목(터미널 OSC) — widen 안 함
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
        // glyph 는 각자 자기 2칸 버튼의 **바깥쪽** 칸에 둔다(hit-test 의 `scrollLeftGlyphCol`/`scrollRightGlyphCol`
        // 과 같은 규칙 — §5.4 단일 소스). 그래서 두 버튼 사이에 2칸 여백이 생기고 덜 붐빈다.
        const scroll_w: u16 = @intCast(tabbar.Metrics.scroll_button_cols);
        try cells.append(allocator, .{ .row = 0, .col = @intCast(tab_cols), .codepoint = '<', .width = 1, .style = left_style });
        try cells.append(allocator, .{ .row = 0, .col = @intCast(tab_cols + scroll_w * 2 - 1), .codepoint = '>', .width = 1, .style = right_style });
    }
    // "+"(새 Term) 버튼 — **상단탭 Warp 폴리시: 인라인**(마지막 탭 바로 뒤). 넘쳐서 ‹›가 있으면 옛대로 far-right
    // (tab_cols+2 뒤, ‹·gap·› 다음). plus_start+1 col에 '+'. hit-test(tabbar.Metrics.plusZoneStart)와 단일 정합 —
    // 인라인 plus_start = min(titles.len*tab_w, tab_cols) = plusZoneStart의 tabsEndCol과 같다(barMetrics가 tab_count로 채움).
    const tabs_end: u16 = @min(@as(u16, @intCast(titles.len)) * tab_w, tab_cols);
    const plus_zone_start: u16 = if (layout.has_scroll)
        tab_cols + @as(u16, @intCast(tabbar.Metrics.scroll_button_cols * 2))
    else
        tabs_end;
    // "+" 는 3칸 버튼의 **가운데** 칸에 그린다(hit-test 의 `plusGlyphCol` 과 같은 규칙) — 옛 코드는 2칸
    // 버튼의 둘째 칸이라 › 에 붙어 보였다(사용자 요청 2026-08-18 "+ 버튼도 가운데로").
    const plus_glyph_col: u16 = plus_zone_start + @as(u16, @intCast(tabbar.Metrics.plus_button_cols / 2));
    if (plus_glyph_col < cols) {
        try cells.append(allocator, .{ .row = 0, .col = plus_glyph_col, .codepoint = '+', .width = 1, .style = style });
    }

    // pool을 **먼저** 떼어 낸다: 리터럴 안에서 마지막에 평가하면 cells 소유권이 이미 넘어간 뒤라
    // `errdefer cells.deinit`이 no-op이 되고, pool 할당 실패 시 cells 슬라이스가 샌다(code-review max).
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = @max(cols, 1), .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
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
    var pool: std.ArrayList(u32) = .empty; // cluster 본체(NFD 자모·결합 문자) — DrawList.grapheme_pool로 넘어간다
    errdefer pool.deinit(allocator);
    const style: terminal.Style = .{ .foreground = fg, .background = bg };

    var col: u16 = 0;
    if (col < cols) { // col 0 = 좌패딩(공백, bg)
        try cells.append(allocator, .{ .row = 0, .col = 0, .codepoint = ' ', .width = 1, .style = style });
        col = 1;
    }
    // 제목을 col 1..cols에 깔고(넘치면 "…"), 다음 빈 col을 받아 그 뒤를 bg로 채운다.
    col = try appendEllipsizedTitle(allocator, &cells, &pool, title, 0, col, cols, style, false, .head); // 제목(터미널 텍스트) — widen 안 함
    while (col < cols) : (col += 1) { // 남은 col = bg 공백(솔리드 박스 마감)
        try cells.append(allocator, .{ .row = 0, .col = col, .codepoint = ' ', .width = 1, .style = style });
    }

    // pool을 **먼저** 떼어 낸다: 리터럴 안에서 마지막에 평가하면 cells 소유권이 이미 넘어간 뒤라
    // `errdefer cells.deinit`이 no-op이 되고, pool 할당 실패 시 cells 슬라이스가 샌다(code-review max).
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = @max(cols, 1), .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// sticky command 배너 한 줄 DrawList — `[✓/✗ 종료상태] 명령줄 텍스트`를 불투명 배너 bg 위에 깐다(스크롤된 콘텐츠를
/// 덮어 배너로 보이게 — buildFloatingTabDrawList의 솔리드 박스와 동형). exit==null이면(명령 실행 중) 글리프 없이 명령줄만.
/// ok_fg=성공(초록)·err_fg=실패(빨강)로 ✓(U+2713)/✗(U+2717)만 색을 달리하고 텍스트는 fg. cols가 좁으면 텍스트는 "…"로 줄인다.
pub fn buildStickyCommandDrawList(
    allocator: std.mem.Allocator,
    text: []const u8,
    cols: u16,
    exit: ?i16,
    fg: terminal.Color,
    bg: terminal.Color,
    ok_fg: terminal.Color,
    err_fg: terminal.Color,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty; // cluster 본체(NFD 자모·결합 문자) — DrawList.grapheme_pool로 넘어간다
    errdefer pool.deinit(allocator);
    const style: terminal.Style = .{ .foreground = fg, .background = bg };

    var col: u16 = 0;
    if (col < cols) { // col 0 = 좌패딩(공백, bg)
        try cells.append(allocator, .{ .row = 0, .col = 0, .codepoint = ' ', .width = 1, .style = style });
        col = 1;
    }
    if (exit) |code| { // 종료상태 글리프(있을 때만) — ✓(0)/✗(≠0), 색만 다르고 한 칸 + 뒤 간격 한 칸.
        if (col < cols) {
            const ok = code == 0;
            const gstyle: terminal.Style = .{ .foreground = if (ok) ok_fg else err_fg, .background = bg };
            try cells.append(allocator, .{ .row = 0, .col = col, .codepoint = if (ok) 0x2713 else 0x2717, .width = 1, .style = gstyle });
            col += 1;
        }
        if (col < cols) {
            try cells.append(allocator, .{ .row = 0, .col = col, .codepoint = ' ', .width = 1, .style = style });
            col += 1;
        }
    }
    // 명령줄 텍스트(넘치면 "…")를 col..cols에 깔고, 남은 col을 bg 공백으로 채워 솔리드 배너로 마감.
    col = try appendEllipsizedTitle(allocator, &cells, &pool, text, 0, col, cols, style, false, .head); // 명령줄 텍스트 — widen 안 함
    while (col < cols) : (col += 1) {
        try cells.append(allocator, .{ .row = 0, .col = col, .codepoint = ' ', .width = 1, .style = style });
    }

    // pool을 **먼저** 떼어 낸다: 리터럴 안에서 마지막에 평가하면 cells 소유권이 이미 넘어간 뒤라
    // `errdefer cells.deinit`이 no-op이 되고, pool 할당 실패 시 cells 슬라이스가 샌다(code-review max).
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = @max(cols, 1), .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
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
    _: [*]const u8, // fallback CSV ptr (테스트는 무시)
    _: usize, // fallback CSV len
    _: [*]const u8, // bold family ptr (F2-3)
    _: usize, // bold family len
    _: [*]const u8, // italic family ptr (F2-3)
    _: usize, // italic family len
    _: u32, // ligatures_enabled(config font.ligatures) — fake shaper는 feature를 안 쓴다
    cells_ptr: [*]const coretext_shaper.NativeDrawCell,
    cell_count: usize,
    _: [*]const u32, // grapheme_pool ptr (fake shaper는 풀 미사용 — codepoint 기반 색판정)
    _: usize, // grapheme_pool_len
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
    _: [*]const u8, // fallback CSV ptr
    _: usize, // fallback CSV len
    _: [*]const u8, // bold family ptr (F2-3)
    _: usize, // bold family len
    _: [*]const u8, // italic family ptr (F2-3)
    _: usize, // italic family len
    _: u32, // ligatures_enabled(config font.ligatures) — fake shaper는 feature를 안 쓴다
    _: [*]const coretext_shaper.NativeDrawCell,
    _: usize,
    _: [*]const u32, // grapheme_pool ptr
    _: usize, // grapheme_pool_len
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

test "CoreText frame builder replays cached shaped records without calling the native shaper" {
    const allocator = std.testing.allocator;
    const cells = try allocator.dupe(renderer.DrawCell, &.{.{
        .row = 0,
        .col = 0,
        .codepoint = 0x2500,
        .width = 1,
    }});
    const overlays = try allocator.alloc(renderer.DrawOverlay, 0);
    const list: renderer.DrawList = .{
        .size = .{ .cols = 1, .rows = 1 },
        .cursor = .{ .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = cells,
        .overlays = overlays,
    };
    const records = [_]renderer.ShapedGlyphRecord{.{
        .row = 0,
        .col = 0,
        .cell_width = 1,
        .codepoint = 0x2500,
        .font_id = 0,
        .glyph_id = 0,
        .drawable = true,
    }};
    const builder = CoreTextFrameBuilder{
        .appearance = try config.resolveAppearance(.{}),
        // This bridge always fails. A successful cached path proves shapeFromRecords never
        // re-enters CoreText just to rebuild an unchanged Chrome text frame.
        .shape_draw_list = failingShapeDrawList,
        .rasterize_glyph = testRasterizeGlyph,
    };
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    var pane = try builder.shapeFromRecords(allocator, list, &records);
    const placed = try renderer_state.placeMultiPane(allocator, &.{pane.shaped.runs});
    defer allocator.free(placed);
    var frame = try builder.finishPane(allocator, &pane, placed[0], &renderer_state);
    defer frame.deinit(allocator);
    try std.testing.expect(frame.glyphFrameConsistent());
    try std.testing.expectEqual(@as(usize, 1), frame.glyph_quad_frame.glyphs.len);
}

test "CoreText frame builder builds AppHostFrame from active surface" {
    // 이 테스트는 실제 Objective-C/CoreText를 호출하지 않는다. 대신 같은 함수 포인터
    // 경계를 fake bridge로 주입해, active surface snapshot이 제품 후보
    // CoreTextDrawListShaper/CoreTextGlyphRasterizer/RendererState를 지나 AppHostFrame으로
    // 소유권을 넘기는지 고정한다.
    const allocator = std.testing.allocator;
    var surfaces = [_]maru.session.Surface{try maru.session.Surface.init(allocator, 7, .{ .cols = 8, .rows = 2 })};
    defer surfaces[0].deinit();
    surfaces[0].process_state = .running;
    try surfaces[0].core.write("A한");

    var tab_ptrs = [_]*maru.session.Surface{&surfaces[0]};
    var app_window: maru.session.AppWindow = .{ .tabs = &tab_ptrs };
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();

    const builder = CoreTextFrameBuilder{
        .appearance = try config.resolveAppearance(.{}),
        .shape_draw_list = testShapeDrawList,
        .rasterize_glyph = testRasterizeGlyph,
    };
    var frame = try builder.build(allocator, &app_window, &renderer_state, .{ .output_events = 1 }, std.testing.io);
    defer frame.deinit(allocator);

    const stats = renderer.renderFrameStats(frame.render_frame, renderer_state.atlas.entryCount());
    try std.testing.expectEqual(@as(u64, 7), frame.surface_id);
    try std.testing.expectEqual(terminal.Size{ .cols = 8, .rows = 2 }, frame.size);
    try std.testing.expectEqual(maru.session.ProcessState.running, frame.process_state);
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
    var tab_ptrs = [_]*maru.session.Surface{};
    var app_window: maru.session.AppWindow = .{ .tabs = &tab_ptrs };
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    const builder = CoreTextFrameBuilder{
        .appearance = try config.resolveAppearance(.{}),
        .shape_draw_list = testShapeDrawList,
        .rasterize_glyph = testRasterizeGlyph,
    };

    try std.testing.expectError(
        error.NoActiveSurface,
        builder.build(allocator, &app_window, &renderer_state, .{}, std.testing.io),
    );
}

test "CoreText frame builder surfaces native shape failures" {
    // native shaper가 overflow/font failure를 보고하면 frame 준비를 계속하면 안 된다. 이
    // 실패가 renderer prepared=false로 숨어 버리면 root cause가 CoreText shape 단계인지
    // atlas/raster 단계인지 구분할 수 없기 때문이다.
    const allocator = std.testing.allocator;
    var surfaces = [_]maru.session.Surface{try maru.session.Surface.init(allocator, 8, .{ .cols = 4, .rows = 1 })};
    defer surfaces[0].deinit();
    try surfaces[0].core.write("A");

    var tab_ptrs = [_]*maru.session.Surface{&surfaces[0]};
    var app_window: maru.session.AppWindow = .{ .tabs = &tab_ptrs };
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    const builder = CoreTextFrameBuilder{
        .appearance = try config.resolveAppearance(.{}),
        .shape_draw_list = failingShapeDrawList,
        .rasterize_glyph = testRasterizeGlyph,
    };

    try std.testing.expectError(
        error.CoreTextDrawListShapeFailed,
        builder.build(allocator, &app_window, &renderer_state, .{}, std.testing.io),
    );
}

test "buildSidebarDrawList: 활동 시각은 ✕ 왼쪽에 우측 정렬되고 제목이 그 앞에서 멈춘다" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{"아주아주긴에이전트프롬프트문장"};
    const ages = [_][]const u8{"12m"};
    const cols: u16 = 20;
    var dl = try buildSidebarDrawList(allocator, &names, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, cols, .default, &.{true}, &ages, null, null, .default, null);
    defer dl.deinit(allocator);

    // ✕는 cols-3, 시각은 그 왼쪽에 폭만큼(= cols-4-3 .. cols-5).
    const age_start: u16 = (cols - 4) - 3;
    var seen: [3]bool = .{ false, false, false };
    var title_max_col: u16 = 0;
    for (dl.cells) |c| {
        if (c.codepoint == '1' and c.col == age_start) seen[0] = true;
        if (c.codepoint == '2' and c.col == age_start + 1) seen[1] = true;
        if (c.codepoint == 'm' and c.col == age_start + 2) seen[2] = true;
        // 제목(한글 또는 말줄임표)은 시각 왼쪽에서 멈춰야 한다 — 겹치면 둘 다 못 읽는다.
        // ✕(U+2715)는 제목이 아니므로 세지 않는다.
        if (c.codepoint >= 0xAC00 or c.codepoint == 0x2026) title_max_col = @max(title_max_col, c.col);
    }
    try std.testing.expect(seen[0] and seen[1] and seen[2]);
    try std.testing.expect(title_max_col < age_start);

    // 시각이 없으면 자리를 잡지 않아 제목이 ✕ 앞까지 간다.
    var dl2 = try buildSidebarDrawList(allocator, &names, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, cols, .default, &.{true}, &.{}, null, null, .default, null);
    defer dl2.deinit(allocator);
    var t2: u16 = 0;
    for (dl2.cells) |c| if (c.codepoint >= 0xAC00 or c.codepoint == 0x2026) {
        t2 = @max(t2, c.col);
    };
    try std.testing.expect(t2 > title_max_col);
}

test "buildSidebarDrawList lays tab titles into per-row draw cells, truncating to cols" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{ "zsh", "vim" };
    var draw_list = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 10, .default, &.{}, &.{}, null, null, .default, null);
    defer draw_list.deinit(allocator);

    // 보조줄 없음(branches/paths 빈) → 각 탭 1줄(line_count=1, 슬롯 중앙). size.rows = 마지막 행 + 1.
    try std.testing.expectEqual(@as(u16, 10), draw_list.size.cols);
    try std.testing.expectEqual(sidebarGlyphRow(1, 0, 1) + 1, draw_list.size.rows);
    try std.testing.expectEqual(@as(usize, 6), draw_list.cells.len); // "zsh"(3) + "vim"(3)
    try std.testing.expectEqual(sidebarGlyphRow(0, 0, 1), draw_list.cells[0].row);
    try std.testing.expectEqual(@as(u16, 0), draw_list.cells[0].col);
    try std.testing.expectEqual(@as(u21, 'z'), draw_list.cells[0].codepoint);
    try std.testing.expectEqual(sidebarGlyphRow(1, 0, 1), draw_list.cells[3].row); // 둘째 탭(slot 1)
    try std.testing.expectEqual(@as(u21, 'v'), draw_list.cells[3].codepoint);
    // UI 텍스트라 커서/overlay 없음.
    try std.testing.expect(!draw_list.cursor.visible);
    try std.testing.expectEqual(@as(usize, 0), draw_list.overlays.len);
}

// 멀티라인 카드: 이름(line0) + 브랜치(있으면 line1) + 경로(있으면 line2)를 같은 슬롯에 쌓는다(sidebarGlyphRow
// 인코딩). 보조줄이 ""면 건너뛰어 줄 수가 줄고, 렌더러(.m)가 slot=row/32·count=(row%32)/4·idx=(row%32)%4로 푼다.
test "buildSidebarDrawList multi-line card: name/branch/path stack; empty aux lines are skipped" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "maru", "docs" };
    const branches = [_][]const u8{ "\u{251C} main", "" }; // 탭 0만 브랜치줄
    const paths = [_][]const u8{ "~/dev/maru", "" }; // 탭 0만 경로줄
    var dl = try buildSidebarDrawList(allocator, &names, &branches, &paths, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 20, .default, &.{}, &.{}, null, null, .default, null);
    defer dl.deinit(allocator);

    // 탭 0 = 3줄(이름 idx0·브랜치 idx1·경로 idx2, count=3), 탭 1 = 1줄(이름만, count=1).
    var name0 = false;
    var branch1 = false;
    var path2 = false;
    var tab1 = false;
    for (dl.cells) |c| {
        if (c.codepoint == 'a' and c.row == sidebarGlyphRow(0, 0, 3)) name0 = true; // "maru"의 a
        if (c.codepoint == 0x251C and c.row == sidebarGlyphRow(0, 1, 3)) branch1 = true; // ├ 브랜치줄
        if (c.codepoint == '~' and c.row == sidebarGlyphRow(0, 2, 3)) path2 = true; // 경로줄
        if (c.codepoint == 'd' and c.row == sidebarGlyphRow(1, 0, 1)) tab1 = true; // 1줄 탭
    }
    try std.testing.expect(name0);
    try std.testing.expect(branch1);
    try std.testing.expect(path2);
    try std.testing.expect(tab1);
    // 탭 1엔 보조줄 셀이 없다(이름만).
    for (dl.cells) |c| {
        try std.testing.expect(c.row != sidebarGlyphRow(1, 1, 2));
        try std.testing.expect(c.row != sidebarGlyphRow(1, 2, 3));
    }
}

// 에이전트 아이콘은 카드 줄 수와 무관하게 슬롯 세로 중앙(count=1) col 0에 독립 배치되고, 텍스트는 아이콘
// 자리(icon_cols)만큼 들여써진다 — 사용자 요청("아이콘은 3줄 상관없이 워크스페이스 가운데, 독립 위치").
test "buildSidebarDrawList agent icon: centered at col 0 independent of lines; text indented" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{"maru"};
    const branches = [_][]const u8{"\u{251C} main"};
    const paths = [_][]const u8{"~/dev/maru"};
    const agents = [_]u21{icons.codepoint(.sparkle)}; // claude ✶
    var dl = try buildSidebarDrawList(allocator, &names, &branches, &paths, &[_][]const u8{}, &agents, &[_]u21{}, &[_]bool{}, 30, .default, &.{}, &.{}, null, null, .default, null);
    defer dl.deinit(allocator);

    // 아이콘 ✶: 슬롯 세로 중앙(count=1, idx0) col 0·width 2 — 3줄 블록(count=3)과 무관한 독립 위치.
    var icon_centered = false;
    for (dl.cells) |c| {
        if (c.codepoint == icons.codepoint(.sparkle)) {
            try std.testing.expectEqual(sidebarGlyphRow(0, 0, 1), c.row);
            try std.testing.expectEqual(@as(u16, 0), c.col);
            try std.testing.expect(c.width == 2); // 2칸 아이콘(또렷) — 회귀 방지
            icon_centered = true;
        }
    }
    try std.testing.expect(icon_centered);
    // 텍스트(이름 'm', 3줄 카드의 idx0)는 아이콘 자리(icon_cols=3)만큼 들여써져 col>=3.
    var name_indented = false;
    for (dl.cells) |c| {
        if (c.codepoint == 'm' and c.row == sidebarGlyphRow(0, 0, 3)) {
            try std.testing.expect(c.col >= 3);
            name_indented = true;
        }
    }
    try std.testing.expect(name_indented);
}

// 세션 목록 행의 종류 아이콘은 **이름줄 선두**에 인라인으로 놓인다(gutter가 아니라). 옛 gutter는 글리프 하나
// 때문에 행의 **모든 줄**에서 3칸을 뺏고, 슬롯 세로 중앙에 놓여 줄 수가 다른 행끼리 열도 못 이뤘다(사용자
// 피드백). 이 테스트가 고정하는 것: (1) 아이콘이 이름줄 행(count=n)에 width 2로 오고, (2) 이름줄 텍스트만
// icon_cols만큼 밀리며, (3) **보조줄은 안 밀린다**(gutter와의 결정적 차이), (4) `icon_slot_reserve`는
// 글리프를 안 내면서도 이름줄을 똑같이 밀어 아이콘 없는 행의 라벨 좌단을 맞춘다.
test "buildSidebarDrawList inline_icons: name line only shifts; aux lines keep full width" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "maru", "zsh" };
    const branches = [_][]const u8{ "~/dev/maru", "" };
    const inline_icons = [_]u21{ icons.codepoint(.sparkle), icon_slot_reserve };
    var dl = try buildSidebarDrawList(allocator, &names, &branches, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &inline_icons, &[_]bool{}, 30, .default, &.{}, &.{}, null, null, .default, null);
    defer dl.deinit(allocator);

    // 인라인 행은 카드 하위 목록이라 행 전체가 session_row_indent_cols만큼 들여써진다.
    const ind = session_row_indent_cols;
    // (1) 아이콘은 이름줄과 **같은 행**(2줄 카드의 idx0)에 들여쓰기 열·width 2. 옛 gutter처럼 count=1 중앙이 아니다.
    var icon_on_name_row = false;
    for (dl.cells) |c| {
        if (c.codepoint == icons.codepoint(.sparkle)) {
            try std.testing.expectEqual(sidebarGlyphRow(0, 0, 2), c.row);
            try std.testing.expectEqual(ind, c.col);
            try std.testing.expectEqual(@as(u16, 2), c.width);
            icon_on_name_row = true;
        }
    }
    try std.testing.expect(icon_on_name_row);

    // (2) 이름줄 'm'은 아이콘 자리(icon_cols=3)만큼 **더** 밀린다. (3) 보조줄 '~'는 들여쓰기까지만 —
    // 아이콘 폭은 안 먹는다. gutter였다면 둘 다 같은 만큼 밀려 보조줄이 3칸을 잃었다.
    var name_shifted = false;
    var aux_unshifted = false;
    for (dl.cells) |c| {
        if (c.codepoint == 'm' and c.row == sidebarGlyphRow(0, 0, 2)) {
            try std.testing.expectEqual(ind + 3, c.col);
            name_shifted = true;
        }
        if (c.codepoint == '~' and c.row == sidebarGlyphRow(0, 1, 2)) {
            try std.testing.expectEqual(ind, c.col);
            aux_unshifted = true;
        }
    }
    try std.testing.expect(name_shifted);
    try std.testing.expect(aux_unshifted);

    // (4) reserve 행: 글리프 셀은 안 나오지만 이름은 같은 열에서 시작한다(라벨 좌단 정렬).
    for (dl.cells) |c| try std.testing.expect(c.codepoint != icon_slot_reserve or c.row != sidebarGlyphRow(1, 0, 1));
    var reserved_shifted = false;
    for (dl.cells) |c| {
        if (c.codepoint == 'z' and c.row == sidebarGlyphRow(1, 0, 1)) {
            try std.testing.expectEqual(ind + 3, c.col);
            reserved_shifted = true;
        }
    }
    try std.testing.expect(reserved_shifted);
}

// 아이콘이 **없는** 행도 자리를 잡아야 같은 목록 안에서 라벨 좌단이 맞는다. gutter·인라인 두 배치 모두
// `icon_slot_reserve`가 그 역할을 한다 — 0으로 두면 그 행만 아이콘 폭만큼 왼쪽으로 튄다(사용자 제보:
// "왼쪽 정렬이 이상하다" — 에이전트 행과 일반 터미널 행의 좌단이 갈렸다).
test "buildSidebarDrawList icon_slot_reserve: icon-less rows keep the same label column in both layouts" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "maru", "zsh" };

    // gutter 배치: agents[0]=아이콘, agents[1]=센티널. 둘 다 icon_cols만큼 밀려 라벨 좌단이 같다.
    {
        const agents = [_]u21{ icons.codepoint(.sparkle), icon_slot_reserve };
        var dl = try buildSidebarDrawList(allocator, &names, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &agents, &[_]u21{}, &[_]bool{}, 30, .default, &.{}, &.{}, null, null, .default, null);
        defer dl.deinit(allocator);
        var m_col: ?u16 = null;
        var z_col: ?u16 = null;
        for (dl.cells) |c| {
            if (c.codepoint == 'm' and c.row == sidebarGlyphRow(0, 0, 1)) m_col = c.col;
            if (c.codepoint == 'z' and c.row == sidebarGlyphRow(1, 0, 1)) z_col = c.col;
            // 센티널은 글리프를 내지 않는다.
            try std.testing.expect(c.codepoint != icon_slot_reserve);
        }
        try std.testing.expectEqual(m_col, z_col);
    }

    // 인라인 배치: 같은 규율이 이름줄 선두 아이콘에도 적용된다.
    {
        const inline_icons = [_]u21{ icons.codepoint(.sparkle), icon_slot_reserve };
        var dl = try buildSidebarDrawList(allocator, &names, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &inline_icons, &[_]bool{}, 30, .default, &.{}, &.{}, null, null, .default, null);
        defer dl.deinit(allocator);
        var m_col: ?u16 = null;
        var z_col: ?u16 = null;
        for (dl.cells) |c| {
            if (c.codepoint == 'm' and c.row == sidebarGlyphRow(0, 0, 1)) m_col = c.col;
            if (c.codepoint == 'z' and c.row == sidebarGlyphRow(1, 0, 1)) z_col = c.col;
            try std.testing.expect(c.codepoint != icon_slot_reserve);
        }
        try std.testing.expectEqual(m_col, z_col);
    }
}

// 카드 줄 안에 인라인으로 박힌 maru 아이콘(브랜치줄 octocat 0xF0009·폴더줄 0xF000A)은 **width 2(~16px)**로
// 렌더돼 작은 셀에서도 실루엣이 또렷하다(wideIconPredicate). width-1(~8px)이면 octocat이 동그란 링처럼 뭉개졌다
// (사용자 피드백 "깃 아이콘이 너무 작다"). 아이콘이 2칸을 차지하므로 뒤따르는 텍스트가 그만큼 밀린다 — 회귀 방지.
test "buildSidebarDrawList inline icons (octocat·folder PUA) render width 2 and offset following text" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{"maru"};
    const branches = [_][]const u8{comptime icons.utf8(.mark_github) ++ " main"}; // octocat + 공백 + 브랜치
    const paths = [_][]const u8{comptime icons.utf8(.folder) ++ " ~/dev"}; // folder + 공백 + 경로
    var dl = try buildSidebarDrawList(allocator, &names, &branches, &paths, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 20, .default, &.{}, &.{}, null, null, .default, null);
    defer dl.deinit(allocator);

    // 아이콘 셀은 col 0·width 2. 아이콘 폭 2 + 공백 1 = 3이므로, 브랜치 'm'·경로 '~'는 col 3에서 시작.
    var octocat_w2 = false;
    var folder_w2 = false;
    var branch_text_at3 = false;
    var path_text_at3 = false;
    for (dl.cells) |c| {
        if (c.codepoint == icons.codepoint(.mark_github) and c.row == sidebarGlyphRow(0, 1, 3)) {
            try std.testing.expectEqual(@as(u16, 0), c.col);
            try std.testing.expectEqual(@as(u2, 2), c.width);
            octocat_w2 = true;
        }
        if (c.codepoint == icons.codepoint(.folder) and c.row == sidebarGlyphRow(0, 2, 3)) {
            try std.testing.expectEqual(@as(u16, 0), c.col);
            try std.testing.expectEqual(@as(u2, 2), c.width);
            folder_w2 = true;
        }
        if (c.codepoint == 'm' and c.row == sidebarGlyphRow(0, 1, 3)) {
            try std.testing.expectEqual(@as(u16, 3), c.col); // 아이콘(2)+공백(1) 뒤
            branch_text_at3 = true;
        }
        if (c.codepoint == '~' and c.row == sidebarGlyphRow(0, 2, 3)) {
            try std.testing.expectEqual(@as(u16, 3), c.col);
            path_text_at3 = true;
        }
    }
    try std.testing.expect(octocat_w2);
    try std.testing.expect(folder_w2);
    try std.testing.expect(branch_text_at3);
    try std.testing.expect(path_text_at3);
}

// 폭 predicate(wideIconPredicate)는 **등록된** maru 아이콘 PUA만 2칸으로 친다(렌더 폭과 일치해야 말줄임 예약 칸이 안 어긋난다).
// 미등록 범위 codepoint(Nerd Fonts v3가 Plane-15 PUA로 옮긴 MDI 등)는 신뢰 불가 OSC 0/2 제목에 와도 1칸 유지.
test "wideIconPredicate widens only registered maru icon PUA to width 2" {
    // widen=true(카드 보조줄): 등록 아이콘 2칸.
    try std.testing.expectEqual(@as(usize, 2), text_layout.displayCols(icons.utf8(.mark_github), wideIconPredicate(true))); // octocat(등록)
    try std.testing.expectEqual(@as(usize, 2), text_layout.displayCols(icons.utf8(.folder), wideIconPredicate(true))); // folder(등록)
    try std.testing.expectEqual(@as(usize, 1), text_layout.displayCols("\u{F0050}", wideIconPredicate(true))); // 미등록 범위 — 1칸(registered-only)
    try std.testing.expectEqual(@as(usize, 6), text_layout.displayCols(comptime icons.utf8(.mark_github) ++ " abc", wideIconPredicate(true))); // 2 + 공백 + abc(3)
    try std.testing.expectEqual(@as(usize, 3), text_layout.displayCols("abc", wideIconPredicate(true))); // 일반 텍스트 회귀
    // widen=false(탭·OSC·라벨 제목): 등록 아이콘도 1칸 — 터미널 제목이 Nerd Fonts MDI와 겹쳐도 안 어긋남.
    try std.testing.expectEqual(@as(usize, 1), text_layout.displayCols(icons.utf8(.mark_github), null)); // octocat이지만 1칸
    try std.testing.expectEqual(@as(usize, 5), text_layout.displayCols(comptime icons.utf8(.mark_github) ++ " abc", null)); // 1 + 공백 + abc(3)
}

// 두 생성물 동기 가드: C 셰이핑 게이트 icon_codepoints.h(maru_is_registered_icon_cp)와 Zig 등록 집합
// (icon_glyph.isRegisteredIcon/coverageFor)이 같은 codepoint들을 봐야 한다 — 둘 다 svg_to_coverage.py의 ICONS에서
// 생성되지만, 한쪽만 손편집/부분 재생성하면 드리프트해 그 아이콘이 실제 앱에서 blank가 된다(zig test는 .h를 안 봐서
// 안 잡힘). 여기서 .h를 파싱해 (1) 각 case cp가 Zig 등록이고 (2) 개수가 같음을 확인해 set 동일성을 못박는다.
test "icon_codepoints.h(C 게이트)와 Zig 등록 아이콘 집합이 일치한다" {
    const header = @embedFile("icon_codepoints.h"); // 같은 디렉터리(src/platform/macos)
    var c_count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, header, i, "case 0x")) |pos| {
        const hex_start = pos + "case 0x".len;
        var hex_end = hex_start;
        while (hex_end < header.len and std.ascii.isHex(header[hex_end])) : (hex_end += 1) {}
        const cp = try std.fmt.parseInt(u32, header[hex_start..hex_end], 16);
        try std.testing.expect(renderer.icon_glyph.isRegisteredIcon(cp)); // C ⊆ Zig 등록
        c_count += 1;
        i = hex_end;
    }
    try std.testing.expect(c_count > 0); // 파싱이 실제로 됐다
    try std.testing.expectEqual(renderer.icon_glyph.registeredIconCount(), c_count); // 개수 동일 → set 동일
}

// 위 가드는 **집합**만 본다. `.m`이 이제 `MARU_ICON_GEAR` 같은 이름 매크로로 아이콘을 고르므로(IC4), 이름↔cp
// **대응**이 어긋나면 1.7× 확대·bell 특례·에이전트 배율이 엉뚱한 글리프에 붙는다 — 값 집합은 그대로라 위
// 테스트는 통과한다(적대적 검증이 짚은 구멍). 여기서 매크로를 파싱해 Zig 이름 registry와 1:1로 맞춘다.
test "icon_codepoints.h의 MARU_ICON_* 매크로가 Zig 이름 registry와 같은 대응을 준다" {
    const header = @embedFile("icon_codepoints.h");
    var macro_count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, header, i, "#define MARU_ICON_")) |pos| {
        const name_start = pos + "#define MARU_ICON_".len;
        var name_end = name_start;
        while (name_end < header.len and header[name_end] != ' ' and header[name_end] != '\n') : (name_end += 1) {}
        // include guard(`#define MARU_ICON_CODEPOINTS_H`)도 같은 접두사라 걸린다 — 값이 16진수인 것만 본다.
        var value_start = name_end;
        while (value_start < header.len and header[value_start] == ' ') : (value_start += 1) {}
        if (!std.mem.startsWith(u8, header[value_start..], "0x")) {
            i = name_end;
            continue;
        }
        const hex_start = value_start + 2;
        var hex_end = hex_start;
        while (hex_end < header.len and std.ascii.isHex(header[hex_end])) : (hex_end += 1) {}
        const cp: u21 = @intCast(try std.fmt.parseInt(u32, header[hex_start..hex_end], 16));

        // 매크로 이름은 매니페스트 심볼의 대문자다: 기본 fit은 `<이름>`, 변형은 `<이름>_<FIT>`.
        const resolved = icons.fromCodepoint(cp) orelse return error.TestUnexpectedResult;
        var expected_buf: [64]u8 = undefined;
        const tag = @tagName(resolved.icon);
        const expected_lower = if (icons.codepoint(resolved.icon) == cp)
            tag
        else
            try std.fmt.bufPrint(&expected_buf, "{s}_{s}", .{ tag, @tagName(resolved.fit) });
        var upper_buf: [64]u8 = undefined;
        const expected = std.ascii.upperString(upper_buf[0..expected_lower.len], expected_lower);
        try std.testing.expectEqualStrings(expected, header[name_start..name_end]);

        macro_count += 1;
        i = hex_end;
    }
    try std.testing.expectEqual(renderer.icon_glyph.registeredIconCount(), macro_count); // 자산마다 하나씩
}

test "every semantic file tree icon lowers to a registered synthesized glyph" {
    inline for (std.meta.fields(file_tree_icon.IconKind)) |field| {
        const kind: file_tree_icon.IconKind = @enumFromInt(field.value);
        const cp = file_tree_icon.codepoint(kind);
        if (kind == .none) {
            try std.testing.expect(cp == null);
        } else {
            try std.testing.expect(cp != null);
            try std.testing.expect(renderer.icon_glyph.isRegisteredIcon(cp.?));
        }
    }
}

test "buildPaneTabBarDrawList lays Term titles horizontally into equal-width tab segments" {
    const allocator = std.testing.allocator;
    // cols=20 → 우측 "+" zone 3칸 떼고 탭 영역 17, 2탭 → tab_w=8. 탭 0은 col [0,8), 탭 1은 [8,16). 각 탭 1칸 좌패딩 뒤 제목.
    const titles = [_][]const u8{ "sh", "vim" };
    var draw_list = try buildPaneTabBarDrawList(allocator, &titles, 20, .default, false, null, .default, 0, 0, null);
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
    var dl2 = try buildPaneTabBarDrawList(allocator, &longt, 11, .default, false, null, .default, 0, 0, null);
    defer dl2.deinit(allocator);
    var tab0: usize = 0;
    for (dl2.cells) |c| {
        if (c.col < 4) tab0 += 1; // 탭 0 세그먼트 [0,4)
    }
    try std.testing.expectEqual(@as(usize, 3), tab0); // "abcdef" 중 3칸(col 1,2,3)만

    // close_all=true면 **모든 탭** 우측 안쪽(seg_end-2)에 ✕ glyph를 그리고 제목은 그 앞까지만. cols=20 → "+" zone
    // 3 빼고 탭 영역 17, 2탭 → tab_w=8 → 탭0 seg_end=8(✕ col 6)·탭1 seg_end=min(16,17)=16(✕ col 14).
    const ht = [_][]const u8{ "sh", "vim" };
    var dl3 = try buildPaneTabBarDrawList(allocator, &ht, 20, .default, true, null, .default, 0, 0, null);
    defer dl3.deinit(allocator);
    var found_close = false;
    var found_plus3 = false;
    var close_cols: [4]u16 = @splat(0);
    var close_n: usize = 0;
    for (dl3.cells) |c| {
        if (c.codepoint == sidebar_close_glyph) {
            found_close = true;
            if (close_n < close_cols.len) {
                close_cols[close_n] = c.col;
                close_n += 1;
            }
        }
        if (c.codepoint == '+') {
            found_plus3 = true;
            try std.testing.expectEqual(@as(u16, 17), c.col); // 인라인: tabs_end(2탭*tab_w8=16) + 1 — 마지막 탭(끝 16) 바로 뒤(상단탭 Warp 폴리시)
        }
    }
    try std.testing.expect(found_close);
    try std.testing.expect(found_plus3); // 우측 "+" 버튼이 항상 그려진다(cols 충분)
    // ✕는 **모든 탭**에 고정 표시된다(호버 전용 폐기 — 사용자 요청): 탭0 seg_end(8)-2=6, 탭1 seg_end(16)-2=14.
    try std.testing.expectEqual(@as(usize, 2), close_n);
    try std.testing.expectEqual(@as(u16, 6), close_cols[0]);
    try std.testing.expectEqual(@as(u16, 14), close_cols[1]);
    // close_all=false면 ✕ 없음(단, "+"는 있다).
    for (draw_list.cells) |c| try std.testing.expect(c.codepoint != sidebar_close_glyph);
}

test "buildPaneLabelDrawList: 이름을 [1,cols-1)에 깔고 좌패딩·우간격을 남긴다(넘치면 말줄임)" {
    const allocator = std.testing.allocator;
    // cols=8 → [1,7)에 "build"(5칸) 들어감. col 0=패딩, col 7=탭과의 간격(빈 칸).
    var dl = try buildPaneLabelDrawList(allocator, "build", 8, .default, .head);
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
    var tiny = try buildPaneLabelDrawList(allocator, "build", 2, .default, .head);
    defer tiny.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), tiny.cells.len);

    // 긴 이름은 말줄임(U+2026)으로 끝난다.
    var ell = try buildPaneLabelDrawList(allocator, "very-long-pane-name", 6, .default, .head);
    defer ell.deinit(allocator);
    var has_ellipsis = false;
    for (ell.cells) |c| {
        if (c.codepoint == text_layout.ellipsis_glyph) has_ellipsis = true;
    }
    try std.testing.expect(has_ellipsis);
}

test "buildPaneAddressBarDrawList: 밴드 좌측에 nav 버튼 3개 + URL을 [nav_end,cols-1)에 (7e-1b/7e-3)" {
    const allocator = std.testing.allocator;
    const btn_on: terminal.Color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }; // 활성 버튼 색(구분용)
    const btn_off: terminal.Color = .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } }; // 비활성 버튼 색
    // nav_button_w=3, count=3 → nav_end=9(버튼 존 [0,9), 글리프 col 1·4·7). cols=24 → URL 영역 [9,23) = 14칸.
    // can_go_back=true, can_go_forward=false → back·reload 활성(btn_on), forward 비활성(btn_off).
    var dl = try buildPaneAddressBarDrawList(allocator, "https://a/", 24, .default, null, .default, .default, true, false, btn_on, btn_off, 3, 3);
    defer dl.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 24), dl.size.cols);
    try std.testing.expectEqual(@as(u16, 1), dl.size.rows);
    try std.testing.expect(!dl.cursor.visible); // 읽기전용 UI — 커서 없음
    // 버튼 글리프 3개: back ← col 1(활성), forward → col 4(비활성), reload ⟳ col 7(활성).
    var back_cell: ?renderer.DrawCell = null;
    var fwd_cell: ?renderer.DrawCell = null;
    var reload_cell: ?renderer.DrawCell = null;
    var url_first: ?renderer.DrawCell = null;
    for (dl.cells) |c| {
        if (c.codepoint == 0x2190) back_cell = c;
        if (c.codepoint == 0x2192) fwd_cell = c;
        if (c.codepoint == 0x27F3) reload_cell = c;
        if (c.codepoint == 'h' and (url_first == null or c.col < url_first.?.col)) url_first = c;
    }
    try std.testing.expectEqual(@as(u16, 1), back_cell.?.col); // 존0 가운데
    try std.testing.expectEqual(@as(u16, 4), fwd_cell.?.col); // 존1 가운데
    try std.testing.expectEqual(@as(u16, 7), reload_cell.?.col); // 존2 가운데
    try std.testing.expectEqual(btn_on, back_cell.?.style.foreground); // canGoBack → 활성
    try std.testing.expectEqual(btn_off, fwd_cell.?.style.foreground); // !canGoForward → 비활성
    try std.testing.expectEqual(btn_on, reload_cell.?.style.foreground); // reload 항상 활성
    try std.testing.expectEqual(@as(u16, 9), url_first.?.col); // URL 시작 = nav_end(버튼과 안 겹침)

    // 빈 url이면 버튼 3개만(URL 셀 없음 — 첫 frame nav 미도착 시). 색 검증은 아래 전용 테스트가 담당.
    var empty = try buildPaneAddressBarDrawList(allocator, "", 24, .default, null, .default, .default, false, false, btn_on, btn_off, 3, 3);
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), empty.cells.len); // 버튼 3개(URL 셀 0)

    // cols<3이면 빈 strip(버튼·URL 불가).
    var tiny = try buildPaneAddressBarDrawList(allocator, "https://a/", 2, .default, null, .default, .default, true, true, btn_on, btn_off, 3, 3);
    defer tiny.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), tiny.cells.len);

    // 긴 URL은 .head 앵커라 앞부분 보존 + 말미 말줄임(U+2026)으로 끝난다(scheme·host 우선 표시).
    var long = try buildPaneAddressBarDrawList(allocator, "https://example.com/very/long/path/segment", 24, .default, null, .default, .default, false, false, btn_on, btn_off, 3, 3);
    defer long.deinit(allocator);
    var has_ellipsis = false;
    for (long.cells) |c| {
        if (c.codepoint == text_layout.ellipsis_glyph) has_ellipsis = true;
    }
    try std.testing.expect(has_ellipsis);
}

test "buildPaneAddressBarDrawList: reload는 항상 활성, back/forward는 canGo* 따름 (7e-3)" {
    const allocator = std.testing.allocator;
    const btn_on: terminal.Color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } };
    const btn_off: terminal.Color = .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } };
    // can_go_back=false, can_go_forward=false → back·forward 비활성, reload는 그래도 활성(btn_on).
    var dl = try buildPaneAddressBarDrawList(allocator, "", 24, .default, null, .default, .default, false, false, btn_on, btn_off, 3, 3);
    defer dl.deinit(allocator);
    for (dl.cells) |c| {
        if (c.codepoint == 0x2190) try std.testing.expectEqual(btn_off, c.style.foreground); // back 비활성
        if (c.codepoint == 0x2192) try std.testing.expectEqual(btn_off, c.style.foreground); // forward 비활성
        if (c.codepoint == 0x27F3) try std.testing.expectEqual(btn_on, c.style.foreground); // reload 항상 활성
    }
}

test "buildPaneAddressBarDrawList: 편집 caret은 정적 반전 블록 셀(글자 반전색·끝이면 솔리드 블록) (슬라이스 2/3)" {
    const allocator = std.testing.allocator;
    const caret: terminal.Color = .{ .rgb = .{ .r = 9, .g = 8, .b = 7 } }; // 반전 블록 배경
    const ctext: terminal.Color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }; // 반전 블록 위 글자색
    // nav_end=9 → 텍스트 영역 [9,23). "abc"(3칸)이 col 9~11, caret=끝(col 12)엔 글자 없어 **반전 공백(솔리드 블록)**.
    var dl = try buildPaneAddressBarDrawList(allocator, "", 24, .default, text_field.fieldLayout(.{ .text = "abc", .caret = 3 }, .{ .cols = 24, .nav_end = 9 }), caret, ctext, false, false, .default, .default, 3, 3);
    defer dl.deinit(allocator);
    var caret_cell: ?renderer.DrawCell = null;
    var text_cells: usize = 0;
    for (dl.cells) |c| {
        if (c.codepoint == 0x2190 or c.codepoint == 0x2192 or c.codepoint == 0x27F3) continue; // 버튼 글리프 제외
        if (c.style.background == .rgb and std.meta.eql(c.style.background, caret)) caret_cell = c else text_cells += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), text_cells); // "abc" 3글자
    try std.testing.expect(caret_cell != null); // caret 반전 블록 셀 존재
    try std.testing.expectEqual(@as(u16, 12), caret_cell.?.col); // caret=끝 → col 9(nav_end)+3 = 12
    try std.testing.expectEqual(@as(u21, ' '), caret_cell.?.codepoint); // 끝 = 반전 공백(솔리드 블록)
    try std.testing.expect(std.meta.eql(caret_cell.?.style.foreground, ctext)); // 위 글자색

    // caret이 글자 위(중간)면 그 글자를 반전색으로(공백 아님) — "abc"에서 caret=1이면 col 10의 'b'가 반전.
    var mid = try buildPaneAddressBarDrawList(allocator, "", 24, .default, text_field.fieldLayout(.{ .text = "abc", .caret = 1 }, .{ .cols = 24, .nav_end = 9 }), caret, ctext, false, false, .default, .default, 3, 3);
    defer mid.deinit(allocator);
    var mid_caret: ?renderer.DrawCell = null;
    for (mid.cells) |c| if (std.meta.eql(c.style.background, caret)) {
        mid_caret = c;
    };
    try std.testing.expect(mid_caret != null);
    try std.testing.expectEqual(@as(u16, 10), mid_caret.?.col); // nav_end(9)+1
    try std.testing.expectEqual(@as(u21, 'b'), mid_caret.?.codepoint); // 글자 그대로(반전색), 공백 아님 = 안 가림

    // 읽기전용(edit_view=null)이면 caret 셀 없음(회귀 방지 — editing만 caret).
    var ro = try buildPaneAddressBarDrawList(allocator, "abc", 24, .default, null, .default, .default, false, false, .default, .default, 3, 3);
    defer ro.deinit(allocator);
    for (ro.cells) |c| try std.testing.expect(!std.meta.eql(c.style.background, caret));

    // 리뷰 #2: caret 아래 **넓은(한글=2칸) 글자**가 가로 스크롤 우측 경계에 걸려도 통째로 잘리지 않는다(scrollWindow가 caret
    // 글자 폭 2칸을 예약). text="0..9가", caret=10(가 앞) → 좁은 밴드(cols=16, nav_end=9→text_area 7)로 스크롤. 가가 반전 caret
    // 셀로 방출되어야(옛 1칸 예약이면 2칸 가가 클립돼 caret 아래가 빈 셀이던 회귀).
    var wide = try buildPaneAddressBarDrawList(allocator, "", 16, .default, text_field.fieldLayout(.{ .text = "0123456789가", .caret = 10 }, .{ .cols = 16, .nav_end = 9 }), caret, ctext, false, false, .default, .default, 3, 3);
    defer wide.deinit(allocator);
    var wide_caret: ?renderer.DrawCell = null;
    for (wide.cells) |c| if (std.meta.eql(c.style.background, caret)) {
        wide_caret = c;
    };
    try std.testing.expect(wide_caret != null);
    try std.testing.expectEqual(@as(u21, '가'), wide_caret.?.codepoint); // 공백(잘림)이 아니라 '가' 그대로
    try std.testing.expectEqual(@as(u2, 2), wide_caret.?.width); // 2칸(넓은 글자)
}

test "buildPaneAddressBarDrawList: 긴 편집 URL은 fieldLayout 가로 스크롤 — 선두 …(lead) (슬라이스 2)" {
    const allocator = std.testing.allocator;
    // nav_end=9, cols=24 → 텍스트 영역 15칸. 긴 URL(caret=끝)은 텍스트 존을 넘쳐 fieldLayout이 가로 스크롤 →
    // 선두 "…"(lead ellipsis, col 9)로 앞을 자른다. caret=끝(반전 공백)이라 여기선 lead "…"만 확인.
    const long = "https://example.com/very/long/path/segment";
    var dl = try buildPaneAddressBarDrawList(allocator, "", 24, .default, text_field.fieldLayout(.{ .text = long, .caret = long.len }, .{ .cols = 24, .nav_end = 9 }), .default, .default, false, false, .default, .default, 3, 3);
    defer dl.deinit(allocator);
    var lead_ellipsis: ?renderer.DrawCell = null;
    for (dl.cells) |c| {
        if (c.codepoint == text_layout.ellipsis_glyph) lead_ellipsis = c;
        try std.testing.expect(!(c.style.background == .rgb and c.codepoint == ' ')); // 이 테스트는 caret 색 .default라 rgb 반전 셀 없음(lead "…"만 확인)
    }
    try std.testing.expect(lead_ellipsis != null); // 선두 "…"(앞이 스크롤로 잘림)
    try std.testing.expectEqual(@as(u16, 9), lead_ellipsis.?.col); // nav_end 자리에 lead "…"
}

test "buildPaneLabelDrawList tail 앵커: 넘치면 선두를 …로 자르고 이름 끝(rename caret)을 보존한다" {
    // pane/surface rename 중 편집 텍스트는 "이름|"처럼 caret('|')가 늘 끝에 온다. 세그먼트보다 길면 head 앵커는
    // caret과 방금 친 글자를 오른쪽으로 잘라 안 보이게 했다(사용자 제보). tail 앵커는 선두를 "…"로 자르고 끝을
    // 남겨 caret이 항상 보인다(입력창 scroll-to-caret). 이 회귀를 헤드리스로 잠근다.
    const allocator = std.testing.allocator;
    // cols=8 → 이름 영역 [1,7) = 6칸. "very-long-name|"(15칸)은 넘친다.
    var dl = try buildPaneLabelDrawList(allocator, "very-long-name|", 8, .default, .tail);
    defer dl.deinit(allocator);
    var last_cp: u21 = 0;
    var last_col: u16 = 0;
    var lead_ellipsis = false;
    for (dl.cells) |c| {
        if (c.col >= last_col) {
            last_col = c.col;
            last_cp = c.codepoint;
        }
        if (c.col == 1 and c.codepoint == text_layout.ellipsis_glyph) lead_ellipsis = true; // 선두 "…"는 좌패딩(col0) 뒤 col1
    }
    try std.testing.expectEqual(@as(u21, '|'), last_cp); // 문자열 끝(caret)이 보존됨 — head였다면 잘렸을 것
    try std.testing.expect(lead_ellipsis); // 앞이 잘렸다는 선두 "…"

    // head 앵커 대조: 같은 입력이면 caret이 잘려 마지막이 "…"(끝 보존 안 함).
    var head = try buildPaneLabelDrawList(allocator, "very-long-name|", 8, .default, .head);
    defer head.deinit(allocator);
    var head_last_cp: u21 = 0;
    var head_last_col: u16 = 0;
    for (head.cells) |c| {
        if (c.col >= head_last_col) {
            head_last_col = c.col;
            head_last_cp = c.codepoint;
        }
    }
    try std.testing.expect(head_last_cp != '|'); // head는 끝을 못 보여줌(대조군)
}

test "buildPaneLabelDrawList tail 앵커: 정확한 열 배치(선두 … + 우측 tail) + 경계 넘침 없음" {
    // tail 창(window) 수학을 열 단위로 못 박는다: 좌패딩(col0) 비움, 선두 "…"는 col1, tail은 col2부터 우측 끝까지,
    // end_col(cols-1) 이상·col0엔 아무 셀도 없다. cols=8 → 이름 영역 [1,7)=6칸, lead 1 + tail 5.
    const allocator = std.testing.allocator;
    var dl = try buildPaneLabelDrawList(allocator, "abcdefghij|", 8, .default, .tail);
    defer dl.deinit(allocator);
    // 열→코드포인트 맵으로 정확히 검증.
    var at: [8]?u21 = .{null} ** 8;
    for (dl.cells) |c| {
        try std.testing.expect(c.col >= 1 and c.col <= 6); // col0(좌패딩)·col7(=end_col 우간격) 비움 — 경계 넘침 없음
        at[c.col] = c.codepoint;
    }
    try std.testing.expectEqual(@as(?u21, null), at[0]); // 좌패딩
    try std.testing.expectEqual(@as(?u21, text_layout.ellipsis_glyph), at[1]); // 선두 "…"
    try std.testing.expectEqual(@as(?u21, 'g'), at[2]); // 앞 6글자("abcdef")를 버린 tail
    try std.testing.expectEqual(@as(?u21, 'h'), at[3]);
    try std.testing.expectEqual(@as(?u21, 'i'), at[4]);
    try std.testing.expectEqual(@as(?u21, 'j'), at[5]);
    try std.testing.expectEqual(@as(?u21, '|'), at[6]); // caret은 늘 우측 끝
    try std.testing.expectEqual(@as(?u21, null), at[7]); // end_col 자리(우간격) 비움

    // fits(안 넘침): tail이어도 선두 "…" 없이 좌측 정렬 그대로 — 짧은 이름에 헛 "…"를 붙이지 않는다.
    var fits = try buildPaneLabelDrawList(allocator, "ab|", 8, .default, .tail);
    defer fits.deinit(allocator);
    var fits_has_ellipsis = false;
    var fits_min_col: u16 = 999;
    for (fits.cells) |c| {
        if (c.codepoint == text_layout.ellipsis_glyph) fits_has_ellipsis = true;
        if (c.col < fits_min_col) fits_min_col = c.col;
    }
    try std.testing.expect(!fits_has_ellipsis); // 안 넘치면 말줄임 없음
    try std.testing.expectEqual(@as(u16, 1), fits_min_col); // 좌패딩 뒤 col1부터

    // narrow(가용 1칸): "…" 자리조차 없으면 생략하고 최소한 caret만 보인다.
    var narrow = try buildPaneLabelDrawList(allocator, "abc|", 3, .default, .tail); // [1,2)=1칸
    defer narrow.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), narrow.cells.len); // 딱 1칸
    try std.testing.expectEqual(@as(u21, '|'), narrow.cells[0].codepoint); // caret 우선 표시
    try std.testing.expectEqual(@as(u16, 1), narrow.cells[0].col);
}

test "buildPaneLabelDrawList tail 앵커: 한글(EAW 2칸)은 온전한 글자 단위로 tail을 남긴다(반쪽 없음)" {
    // 조합/확정 한글은 셀 폭 2칸이다. tail 창을 코드포인트 폭(EAW)으로 재지 않고 바이트/칸을 섞으면 한글이 반쪽으로
    // 잘리거나 caret 정렬이 어긋난다(과거 putUtf8 회귀와 같은 부류). tail이 폭 기준으로 온전한 한글만 남기는지 잠근다.
    const allocator = std.testing.allocator;
    // "가나다라마|" = 한글 5자(각 2칸=10) + caret 1칸 = 11칸. cols=8 → [1,7)=6칸(lead 1 + tail 5).
    var dl = try buildPaneLabelDrawList(allocator, "가나다라마|", 8, .default, .tail);
    defer dl.deinit(allocator);
    var at: [8]?u21 = .{null} ** 8;
    var hangul_w2 = false;
    for (dl.cells) |c| {
        try std.testing.expect(c.col >= 1 and c.col <= 6); // 경계 넘침 없음
        at[c.col] = c.codepoint;
        // 한글 음절(U+AC00~U+D7A3)은 반드시 width 2로 배치돼야 한다(반쪽 렌더 금지).
        if (c.codepoint >= 0xAC00 and c.codepoint <= 0xD7A3) {
            try std.testing.expectEqual(@as(u2, 2), c.width);
            hangul_w2 = true;
        }
    }
    try std.testing.expectEqual(@as(?u21, text_layout.ellipsis_glyph), at[1]); // 선두 "…"
    try std.testing.expect(hangul_w2); // 온전한 한글(width 2)이 tail에 남았다
    try std.testing.expectEqual(@as(?u21, '|'), at[6]); // caret은 우측 끝(col6)
    // tail 시작(col2)은 한글 '라'(온전한 글자) — 앞 3자("가나다")를 폭 단위로 버려 반쪽이 안 생겼다.
    try std.testing.expectEqual(@as(?u21, '라'), at[2]);
    try std.testing.expectEqual(@as(?u21, null), at[3]); // '라'가 2칸(col2~3) 점유 → col3엔 별도 셀 없음(연속칸)
    try std.testing.expectEqual(@as(?u21, '마'), at[4]);
}

test "buildPaneTabBarDrawList: editing_tab 지정 탭만 tail 앵커로 caret(끝)을 보존한다" {
    // Term 탭 rename 중 편집 탭(editing_tab)은 tail 앵커라 긴 이름이어도 끝의 caret('|')이 세그먼트에 남아야 한다.
    // 나머지 탭은 head. editing_tab=null이면(대조) 같은 긴 이름이 head로 잘려 '|'이 사라진다.
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{ "short", "renaming-a-really-long-title|" };

    // 편집 탭=1 → 탭1은 tail. 어딘가에 '|'(caret)이 남는다.
    var edited = try buildPaneTabBarDrawList(allocator, &titles, 24, .default, false, null, .default, 0, 0, 1);
    defer edited.deinit(allocator);
    var has_caret = false;
    for (edited.cells) |c| {
        if (c.codepoint == '|') has_caret = true;
    }
    try std.testing.expect(has_caret); // 편집 탭의 끝 caret 보존

    // editing_tab=null(대조) → 탭1도 head라 긴 제목이 잘려 '|'이 없다.
    var none = try buildPaneTabBarDrawList(allocator, &titles, 24, .default, false, null, .default, 0, 0, null);
    defer none.deinit(allocator);
    var none_caret = false;
    for (none.cells) |c| {
        if (c.codepoint == '|') none_caret = true;
    }
    try std.testing.expect(!none_caret); // head 앵커는 끝(caret)을 못 보여줌
}

test "buildPaneGripDrawList: grip 글리프 ⠿를 중앙 칸(cols/2)에 깔아 양쪽 패딩을 둔다" {
    const allocator = std.testing.allocator;
    // cols=3(실사용 pane_grip_cols) → 글리프 U+283F가 col 1(좌패딩 col 0, 우패딩 col 2). 글리프 칸 위치를 잠가
    // 회귀(글리프가 좌단 col 0으로 돌아가 양쪽 패딩이 깨지는 것)를 헤드리스로 잡는다 — 호버 테스트는 밴드 전체를
    // .grip으로 보므로 글리프 위치를 검증 못 한다.
    var dl = try buildPaneGripDrawList(allocator, 3, .default);
    defer dl.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 3), dl.size.cols);
    try std.testing.expectEqual(@as(u16, 1), dl.size.rows);
    var grip_col: ?u16 = null;
    for (dl.cells) |c| {
        if (c.codepoint == 0x283F) grip_col = c.col;
    }
    try std.testing.expectEqual(@as(?u16, 1), grip_col); // 중앙(cols/2=1)

    // cols=1(degenerate) → 글리프 col 0(중앙=0/2=0), 빈 칸 없음.
    var one = try buildPaneGripDrawList(allocator, 1, .default);
    defer one.deinit(allocator);
    var one_col: ?u16 = null;
    for (one.cells) |c| {
        if (c.codepoint == 0x283F) one_col = c.col;
    }
    try std.testing.expectEqual(@as(?u16, 0), one_col);
}

test "buildPaneTabBarDrawList reserves a right '+' zone (no '+' when too narrow)" {
    const allocator = std.testing.allocator;
    // cols=20 → 탭 영역 17, "+"는 col 18. 좁은 바(cols=4 ≤ +zone+1)는 "+" 없음.
    const titles = [_][]const u8{"sh"};
    var wide = try buildPaneTabBarDrawList(allocator, &titles, 20, .default, false, null, .default, 0, 0, null);
    defer wide.deinit(allocator);
    var wide_plus = false;
    for (wide.cells) |c| {
        if (c.codepoint == '+') wide_plus = true;
    }
    try std.testing.expect(wide_plus);

    var narrow = try buildPaneTabBarDrawList(allocator, &titles, 4, .default, false, null, .default, 0, 0, null);
    defer narrow.deinit(allocator);
    for (narrow.cells) |c| try std.testing.expect(c.codepoint != '+'); // 좁아서 "+" 없음
}

test "buildPaneTabBarDrawList: 탭 폭은 하한이다 — 적으면 바를 꽉 채우고, 많으면 하한에서 멈춘다" {
    const allocator = std.testing.allocator;
    // cols=40, "+"zone 3 → tab_cols=37. 하한 16인데 2탭이면 균등 18이 더 넓다 → 18씩 채운다(빈 영역 없음).
    // 옛 계약은 "고정 16 → [0,16)·[16,32)·나머지 빈 영역"이었다. 사용자 요청(2026-08-18)으로 고정 폭을
    // **하한**으로 바꿨고, 그 결과가 이 col 이다.
    const titles = [_][]const u8{ "sh", "vim" };
    var dl = try buildPaneTabBarDrawList(allocator, &titles, 40, .default, false, null, .default, 16, 0, null);
    defer dl.deinit(allocator);
    // 탭1 'v'는 seg start(18) + 1칸 좌패딩 = col 19.
    var v_col: ?u16 = null;
    for (dl.cells) |c| {
        if (c.codepoint == 'v') v_col = c.col;
    }
    try std.testing.expectEqual(@as(?u16, 19), v_col);

    // 탭이 많아 균등(37/4=9)이 하한 16보다 좁아지면 하한이 이긴다 — 탭1 은 16+1=17 에서 시작한다.
    const many = [_][]const u8{ "sh", "vim", "top", "cat" };
    var dl2 = try buildPaneTabBarDrawList(allocator, &many, 40, .default, false, null, .default, 16, 0, null);
    defer dl2.deinit(allocator);
    var v2: ?u16 = null;
    for (dl2.cells) |c| {
        if (c.codepoint == 'v') v2 = c.col;
    }
    try std.testing.expectEqual(@as(?u16, 17), v2);
}

test "paneTabWidth divides cols among tabs (min 1, clamps when tabs exceed cols)" {
    try std.testing.expectEqual(@as(u16, 10), paneTabWidth(20, 2));
    try std.testing.expectEqual(@as(u16, 6), paneTabWidth(20, 3)); // 20/3 = 6
    try std.testing.expectEqual(@as(u16, 1), paneTabWidth(3, 5)); // 탭>cols → 1칸씩(넘침 잘림)
    try std.testing.expectEqual(@as(u16, 0), paneTabWidth(0, 2));
    try std.testing.expectEqual(@as(u16, 0), paneTabWidth(20, 0));
}

test "tabLayout: rich 넘침 ‹›·tab_cols 축소·scroll clamp; tui·안넘침 무스크롤" {
    // cols=40, "+"zone 3 → base=paneTabAreaCols(40)=37. 고정폭 16, 3탭 → total=48 > 37 → has_scroll.
    // ‹·› 는 **각 2칸**이라 넷을 뗀다(옛 3칸: ‹·gap·›). tab_cols = 37 - 4 = 33.
    const ovf = tabLayout(40, 3, 16, 0);
    try std.testing.expect(ovf.has_scroll);
    try std.testing.expectEqual(@as(u16, 33), ovf.tab_cols); // 37 - 4(‹2칸·›2칸)
    try std.testing.expectEqual(@as(u16, 16), ovf.tab_w);
    try std.testing.expectEqual(@as(u32, 0), ovf.eff_scroll); // scroll 0
    // #1: 큰 scroll(stale 등)은 max(=total 48 - tab_cols 33 = 15)로 clamp.
    try std.testing.expectEqual(@as(u32, 15), tabLayout(40, 3, 16, 100).eff_scroll);
    // 2탭 → 균등 폭 18(=37/2)이 고정 16보다 넓어 **바를 꽉 채운다**(고정 폭은 하한). total=36 <= 37 →
    // no scroll, tab_cols=37(그대로), eff 0(stale 무시).
    const fit = tabLayout(40, 2, 16, 50);
    try std.testing.expect(!fit.has_scroll);
    try std.testing.expectEqual(@as(u16, 18), fit.tab_w);
    try std.testing.expectEqual(@as(u16, 37), fit.tab_cols);
    try std.testing.expectEqual(@as(u32, 0), fit.eff_scroll);
    // 탭 1개면 바 전체가 그 탭이다 — 도크 탭과 같은 모양(사용자가 요청한 그림).
    try std.testing.expectEqual(@as(u16, 37), tabLayout(40, 1, 16, 0).tab_w);
    // 탭이 많아 균등이 고정보다 좁아지면 **고정 폭이 이긴다**(그리고 넘쳐서 ‹› 스크롤이 뜬다).
    const many = tabLayout(40, 5, 16, 0);
    try std.testing.expectEqual(@as(u16, 16), many.tab_w);
    try std.testing.expect(many.has_scroll);
    // #4: tui(fixed 0)는 탭 많아 tab_w=1 collapse여도 has_scroll=false(균등, 스크롤 안 함 — tui 무변화).
    try std.testing.expect(!tabLayout(40, 12, 0, 0).has_scroll);
}

test "buildSidebarDrawList truncates to cols and advances wide glyphs by two columns" {
    const allocator = std.testing.allocator;
    // cols=5: 우측 패딩 1칸 예약 → 텍스트 폭은 cols-1=4. "abcdefg"는 4칸까지만(말줄임). 와이드 글자는 2칸 전진.
    const titles = [_][]const u8{ "abcdefg", "한A" };
    var draw_list = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 5, .default, &.{}, &.{}, null, null, .default, null);
    defer draw_list.deinit(allocator);

    var row0: usize = 0;
    var row1_cols: [2]u16 = .{ 0, 0 };
    var row1_i: usize = 0;
    for (draw_list.cells) |c| {
        if (c.row == sidebarGlyphRow(0, 0, 1)) row0 += 1;
        if (c.row == sidebarGlyphRow(1, 0, 1) and row1_i < 2) {
            row1_cols[row1_i] = c.col;
            row1_i += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), row0); // 7글자 중 4칸까지만(우측 패딩 1칸 예약, 말줄임 …)
    // "한"(와이드, width 2)이 col 0, 다음 'A'가 col 2(2칸 전진). "한A"=3칸이라 폭 4 안에 들어 말줄임 없음.
    try std.testing.expectEqual(@as(u16, 0), row1_cols[0]);
    try std.testing.expectEqual(@as(u16, 2), row1_cols[1]);
}

// 긴 제목은 하드 컷이 아니라 마지막 칸에 "…"(U+2026)를 둬 말줄임된다(사이드바·pane 탭 바 공유 규칙). 짧으면 없음.
test "long titles are ellipsized with U+2026 at the last cell; short titles are not" {
    const allocator = std.testing.allocator;
    // 사이드바: 우측 패딩 1칸 예약 → 텍스트 폭 cols-1=4. "abcdefg"(7) cols=5 → 'a','b','c','…'. 마지막 셀 = U+2026.
    {
        const titles = [_][]const u8{"abcdefg"};
        var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 5, .default, &.{}, &.{}, null, null, .default, null);
        defer dl.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 4), dl.cells.len);
        try std.testing.expectEqual(text_layout.ellipsis_glyph, dl.cells[3].codepoint); // 마지막 = …(col 3, col 4는 우측 패딩)
        try std.testing.expectEqual(@as(u16, 3), dl.cells[3].col);
        for (dl.cells[0..3]) |c| try std.testing.expect(c.codepoint != text_layout.ellipsis_glyph); // 앞은 글자
    }
    // 텍스트 폭(cols-1=4)에 딱 맞으면 말줄임 없음.
    {
        const titles = [_][]const u8{"abcd"}; // 4칸 = cols-1(우측 패딩 예약 후 가용 폭)
        var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 5, .default, &.{}, &.{}, null, null, .default, null);
        defer dl.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 4), dl.cells.len);
        for (dl.cells) |c| try std.testing.expect(c.codepoint != text_layout.ellipsis_glyph);
    }
    // pane 탭 바: 긴 제목도 세그먼트 한도에서 … . cols=11 → 탭 영역 8, 2탭 → tab_w=4, 탭 0 제목 칸 [1,4) = 3칸.
    {
        const titles = [_][]const u8{ "abcdef", "x" };
        var dl = try buildPaneTabBarDrawList(allocator, &titles, 11, .default, false, null, .default, 0, 0, null);
        defer dl.deinit(allocator);
        var saw_ellipsis = false;
        for (dl.cells) |c| {
            if (c.codepoint == text_layout.ellipsis_glyph) {
                saw_ellipsis = true;
                try std.testing.expectEqual(@as(u16, 3), c.col); // 탭 0 [1,4)의 마지막 칸
            }
        }
        try std.testing.expect(saw_ellipsis);
    }
}

test "file panel header draws source mode and dirty marker in the reserved control band" {
    // 이 테스트는 모드 라벨을 **코드포인트로** 찾는다(`'\u{c18c}'` = "소"). 그 글자는 한국어 라벨일
    // 때만 나오므로 언어를 고정한다 — 재는 것은 "예약 밴드에 모드 텍스트가 그려지는가"이지 문구가 아니다.
    const lang_before = maru.i18n.lang();
    defer maru.i18n.setLang(lang_before);
    maru.i18n.setLang(.ko);

    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
    const bright: terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } };
    var dl = try buildFilePanelHeaderDrawList(allocator, "/tmp/doc.md", .markdown, .source_edit, true, false, 48, dim, bright);
    defer dl.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 1), dl.size.rows);
    var saw_dirty = false;
    var saw_mode_text = false;
    var saw_path = false;
    for (dl.cells) |cell| {
        try std.testing.expectEqual(@as(u16, 0), cell.row); // 밴드는 한 줄이다
        if (cell.codepoint == 0x25CF and cell.col == 46) saw_dirty = true;
        if (cell.codepoint == '\u{c18c}') saw_mode_text = true; // "소스"의 첫 글자 — 아래 setLang(.ko) 가 이 글자를 보장한다
        if (cell.codepoint == 'd' or cell.codepoint == 'o') saw_path = true; // breadcrumb 텍스트
    }
    try std.testing.expect(saw_dirty);
    try std.testing.expect(saw_mode_text);
    try std.testing.expect(saw_path);
}

test "file tree draw list clips to visible rows and marks active dirty conflicts" {
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
    const bright: terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } };
    const rows = [_]file_tree.Row{
        .{ .recent_header = .{ .collapsed = false, .count = 1 } },
        .{ .file = .{
            .path = "/tmp/doc.md",
            .label = "doc.md",
            .depth = 1,
            .supported = true,
            .open = true,
            .active = true,
            .dirty = true,
            .external_change = true,
            .symlink = false,
        } },
        .empty,
    };
    var dl = try buildFileTreeDrawList(allocator, &rows, null, 1, 1, 18, dim, bright, null, null);
    defer dl.deinit(allocator);
    var saw_active = false;
    var saw_dirty = false;
    var saw_conflict = false;
    for (dl.cells) |cell| {
        try std.testing.expectEqual(@as(u16, 0), cell.row);
        if (cell.codepoint == '*') saw_active = cell.style.bold and std.meta.eql(cell.style.foreground, bright);
        if (cell.codepoint == 0x25CF and cell.col == 16) saw_dirty = true;
        if (cell.codepoint == '!' and cell.col == 14) saw_conflict = true;
    }
    try std.testing.expect(saw_active and saw_dirty and saw_conflict);

    var editing = try buildFileTreeDrawList(allocator, &rows, .{
        .identity = .{ .kind = .file, .path = "/tmp/doc.md" },
        .text = "renamed.md|",
    }, 1, 1, 18, dim, bright, null, null);
    defer editing.deinit(allocator);
    var saw_rename_r = false;
    var saw_old_o = false;
    for (editing.cells) |cell| {
        if (cell.codepoint == 'r') saw_rename_r = true;
        if (cell.codepoint == 'o') saw_old_o = true;
    }
    try std.testing.expect(saw_rename_r);
    try std.testing.expect(!saw_old_o);
}

test "파일 트리 rename 편집 텍스트도 cluster로 그린다(NFD는 음절·호환 자모는 낱자)" {
    // 사용자 제보: 파일명 변경 시 한글이 "ㅎㅏㄴㄱㅡㄹ"로 보인다. rename 표시가 cluster 경로를 타는지, 그리고
    // **어떤 입력 형태가 그 화면을 만드는지**를 여기서 갈라 둔다 — 진단의 단일 출처다.
    //   · NFD conjoining 자모(U+1100~, macOS IME/파일시스템) → 음절로 합쳐진다(CG1 경로)
    //   · **호환 자모**(U+3131~, 조합 없이 커밋된 낱자) → cluster 규칙 대상이 아니라 낱자 그대로다
    // 즉 제보 화면이 낱자라면 그건 렌더가 아니라 **입력이 조합되지 않은 것**이다.
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
    const rows = [_]file_tree.Row{.{ .file = .{
        .path = "/tmp/old.md",
        .label = "old.md",
        .depth = 1,
        .supported = true,
        .open = false,
        .active = false,
        .dirty = false,
        .external_change = false,
        .symlink = false,
    } }};

    // ① NFD conjoining "한글" + caret — rename 편집 텍스트가 그대로 cluster화된다.
    var nfd = try buildFileTreeDrawList(allocator, &rows, .{
        .identity = .{ .kind = .file, .path = "/tmp/old.md" },
        .text = "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}|",
    }, 0, 1, 40, dim, dim, null, null);
    defer nfd.deinit(allocator);
    var nfd_syllables: usize = 0;
    var nfd_stray: usize = 0;
    for (nfd.cells) |c| {
        if (c.codepoint == 0x1112 or c.codepoint == 0x1100) nfd_syllables += 1; // cluster base
        if (c.codepoint >= 0x1160 and c.codepoint <= 0x11FF) nfd_stray += 1; // 중성·종성이 셀을 차지하면 안 된다
    }
    try std.testing.expectEqual(@as(usize, 2), nfd_syllables);
    try std.testing.expectEqual(@as(usize, 0), nfd_stray);

    // ② 호환 자모 "ㅎㅏㄴㄱㅡㄹ" — UAX#29 cluster 규칙 밖이라 6칸 낱자로 그려진다(렌더는 정상 동작).
    var compat = try buildFileTreeDrawList(allocator, &rows, .{
        .identity = .{ .kind = .file, .path = "/tmp/old.md" },
        .text = "\u{314E}\u{314F}\u{3134}\u{3131}\u{3161}\u{3139}|",
    }, 0, 1, 40, dim, dim, null, null);
    defer compat.deinit(allocator);
    var compat_letters: usize = 0;
    for (compat.cells) |c| {
        if (c.codepoint >= 0x3131 and c.codepoint <= 0x3163) compat_letters += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), compat_letters); // 조합되지 않은 입력은 렌더가 합쳐 줄 수 없다
}

test "chrome 제목은 NFD를 grapheme cluster 셀로 낸다(한글 자모·라틴 악센트가 흩어지지 않는다)" {
    // 회귀(사용자 제보): macOS 파일시스템이 주는 NFD 이름을 codepoint마다 셀 하나로 깔아 파일 트리 한글이
    // "ㅅㅡㅋㅡ린ㅅㅑㅅ"처럼 자모로 흩어졌다. 이제 chrome도 터미널과 같은 cluster 모델을 쓴다(§3.1a CG1):
    // 셀 하나 = cluster 하나, base는 codepoint에·나머지는 DrawList.grapheme_pool에 실어 CoreText가 합성한다.
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
    const bright: terminal.Color = .{ .rgb = .{ .r = 0xEE, .g = 0xEE, .b = 0xEE } };

    // ── NFD 한글 "한글.md" — ㅎ+ㅏ+ㄴ / ㄱ+ㅡ+ㄹ (U+1100~U+11FF conjoining 자모)
    const nfd_hangul = "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}.md";
    const rows = [_]file_tree.Row{.{
        .file = .{
            .path = "/tmp/nfd.md", // 경로는 원본 바이트 그대로(cluster화는 셀을 만들 때만) — 여기선 라벨만 본다
            .label = nfd_hangul,
            .depth = 1,
            .supported = true,
            .open = false,
            .active = false,
            .dirty = false,
            .external_change = false,
            .symlink = false,
        },
    }};
    var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 40, dim, bright, null, null);
    defer dl.deinit(allocator);

    // 음절 base(초성)는 셀 하나로 나오고, 중성·종성은 **셀이 아니라 풀**에 실린다.
    var syllables: usize = 0;
    var stray_jamo_cells: usize = 0;
    for (dl.cells) |cell| {
        if (cell.codepoint == 0x1112 or cell.codepoint == 0x1100) { // ㅎ·ㄱ 초성 = cluster base
            syllables += 1;
            try std.testing.expectEqual(@as(u16, 2), cell.grapheme_count); // 중성+종성 2개가 풀에
            try std.testing.expectEqual(@as(u2, 2), cell.width); // 폭은 base가 정한다(자모는 0폭 흡수)
            const extra = dl.grapheme_pool[cell.grapheme_offset..][0..cell.grapheme_count];
            if (cell.codepoint == 0x1112) {
                try std.testing.expectEqual(@as(u32, 0x1161), extra[0]); // ㅏ
                try std.testing.expectEqual(@as(u32, 0x11AB), extra[1]); // ㄴ
            }
        } else if (cell.codepoint >= 0x1100 and cell.codepoint <= 0x11FF) {
            stray_jamo_cells += 1; // ★ 옛 동작: 중성·종성이 각자 셀을 차지했다
        }
    }
    try std.testing.expectEqual(@as(usize, 2), syllables); // 한·글
    try std.testing.expectEqual(@as(usize, 0), stray_jamo_cells);

    // ── NFD 라틴 악센트 "café.md" — e + U+0301(결합 악센트). NFC 조합으로는 못 고치던 같은 계열이다.
    const nfd_latin = "caf\u{0065}\u{0301}.md";
    const latin_rows = [_]file_tree.Row{.{ .file = .{
        .path = "/tmp/cafe.md",
        .label = nfd_latin,
        .depth = 1,
        .supported = true,
        .open = false,
        .active = false,
        .dirty = false,
        .external_change = false,
        .symlink = false,
    } }};
    var latin_dl = try buildFileTreeDrawList(allocator, &latin_rows, null, 0, 1, 40, dim, bright, null, null);
    defer latin_dl.deinit(allocator);
    var saw_e_with_accent = false;
    var stray_accent_cells: usize = 0;
    for (latin_dl.cells) |cell| {
        if (cell.codepoint == 'e' and cell.grapheme_count == 1) {
            saw_e_with_accent = latin_dl.grapheme_pool[cell.grapheme_offset] == 0x0301;
            try std.testing.expectEqual(@as(u2, 1), cell.width); // base가 1칸 — 악센트가 칸을 더 먹지 않는다
        }
        if (cell.codepoint == 0x0301) stray_accent_cells += 1; // ★ 옛 동작: 악센트가 자기 칸을 차지해 "cafe´"
    }
    try std.testing.expect(saw_e_with_accent);
    try std.testing.expectEqual(@as(usize, 0), stray_accent_cells);

    // ── 폭 셈법도 cluster 단위 — 말줄임 예약이 방출과 같은 단위여야 제목이 일찍 잘리지 않는다.
    try std.testing.expectEqual(@as(usize, 7), text_layout.displayCols(nfd_hangul, null)); // 한(2)+글(2)+".md"(3)
    try std.testing.expectEqual(@as(usize, 7), text_layout.displayCols(nfd_latin, null)); // "cafe"(4)+".md"(3)
    // 완성형과 같은 폭이어야 한다(같은 글자니까) — NFD/NFC가 레이아웃에서 동치.
    try std.testing.expectEqual(text_layout.displayCols("한글.md", null), text_layout.displayCols(nfd_hangul, null));
}

test "chrome DrawList 빌더는 할당 실패 지점 어디서든 새지 않는다(pool·cells 소유권 교차)" {
    // 회귀(code-review max): CG1이 `.grapheme_pool = try pool.toOwnedSlice(allocator)`를 반환 리터럴 **안**에
    // 넣으면서, cells 소유권이 이미 넘어간 뒤에 실패할 수 있는 fallible 필드가 생겼다. 그 시점의
    // `errdefer cells.deinit`은 비워진 리스트에 대고 도는 no-op이라 owned cells 슬라이스가 통째로 샜다
    // (메모리 압박 중이면 매 프레임 반복). 지금은 pool을 리터럴 **앞**에서 떼어 errdefer로 덮는다.
    //
    // 할당 실패를 지점마다 주입해 "어느 단계에서 실패해도 누수 0"을 고정한다 — 위 순서 규칙이 깨지면 여기서 잡힌다.
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
            // 라벨에 NFD 한글을 넣어 **pool이 실제로 할당되게** 한다(빈 pool이면 이 회귀 경로가 안 열린다).
            const rows = [_]file_tree.Row{.{ .file = .{
                .path = "/tmp/nfd.md",
                .label = "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}.md",
                .depth = 1,
                .supported = true,
                .open = false,
                .active = false,
                .dirty = false,
                .external_change = false,
                .symlink = false,
            } }};
            var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 40, dim, dim, null, null);
            dl.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "file tree focused selection applies its theme contrast color to every row glyph" {
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
    const bright: terminal.Color = .{ .rgb = .{ .r = 0xEE, .g = 0xEE, .b = 0xEE } };
    const on_accent: terminal.Color = .{ .rgb = .{ .r = 0x12, .g = 0x18, .b = 0x20 } };
    const rows = [_]file_tree.Row{.{ .file = .{
        .path = "/tmp/selected.md",
        .label = "selected.md",
        .depth = 1,
        .supported = true,
        .open = true,
        .active = false,
        .dirty = true,
        .external_change = true,
        .symlink = false,
    } }};
    var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 24, dim, bright, .{
        .index = 0,
        .foreground = on_accent,
    }, null);
    defer dl.deinit(allocator);
    var saw_marker = false;
    var saw_label = false;
    var saw_dirty = false;
    var saw_conflict = false;
    for (dl.cells) |cell| {
        try std.testing.expectEqual(on_accent, cell.style.foreground);
        if (cell.col == 3) saw_marker = true;
        if (cell.codepoint == 's') saw_label = true;
        if (cell.codepoint == 0x25CF) saw_dirty = true;
        if (cell.codepoint == '!') saw_conflict = true;
    }
    try std.testing.expect(saw_marker and saw_label and saw_dirty and saw_conflict);
}

// 아이콘 색은 **종류의 보조 신호**다(사용자 요청 2026-08-18 — 트리에서 파일 종류가 먼저 읽히게).
// 두 가지를 고정한다: ⑴ 색을 주면 아이콘만 라벨과 다른 색이 된다(라벨·marker 는 행 색 그대로),
// ⑵ **선택된 행에서는 그 색을 버리고 accent 대비색을 따른다** — 종류 색을 남기면 밝은 accent 위에서
// 읽히지 않는다(같은 이유로 marker·상태 글리프도 그렇게 한다).
test "file tree: 아이콘만 종류 색을 쓰고, 선택된 행에서는 대비색을 따른다" {
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
    const on_accent: terminal.Color = .{ .rgb = .{ .r = 0x10, .g = 0x20, .b = 0x30 } };
    const icon_color: terminal.Color = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } };
    var colors: [std.meta.fields(file_tree_icon.IconKind).len]?terminal.Color = @splat(null);
    colors[@intFromEnum(file_tree_icon.IconKind.document)] = icon_color;
    const rows = [_]file_tree.Row{.{ .file = .{
        .path = "/tmp/README.md",
        .label = "README.md",
        .depth = 0,
        .supported = true,
        .open = false,
        .active = false,
        .dirty = false,
        .external_change = false,
        .symlink = false,
        .icon_kind = @intFromEnum(file_tree_icon.IconKind.document),
    } }};

    {
        var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 24, dim, dim, null, &colors);
        defer dl.deinit(allocator);
        const icon_cp = file_tree_icon.codepoint(.document).?;
        var saw_icon = false;
        var saw_label = false;
        for (dl.cells) |cell| {
            if (cell.codepoint == icon_cp) {
                try std.testing.expectEqual(icon_color, cell.style.foreground); // 아이콘만 종류 색
                saw_icon = true;
            } else if (cell.codepoint == 'R') {
                try std.testing.expectEqual(dim, cell.style.foreground); // 라벨은 행 색 그대로
                saw_label = true;
            }
        }
        try std.testing.expect(saw_icon and saw_label);
    }
    {
        // 선택된 행: 아이콘도 accent 대비색이다.
        var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 24, dim, dim, .{
            .index = 0,
            .foreground = on_accent,
        }, &colors);
        defer dl.deinit(allocator);
        for (dl.cells) |cell| try std.testing.expectEqual(on_accent, cell.style.foreground);
    }
}

test "file tree icons occupy one cell between disclosure and label without state overlap" {
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };
    const selected_fg: terminal.Color = .{ .rgb = .{ .r = 0x10, .g = 0x20, .b = 0x30 } };
    const rows = [_]file_tree.Row{.{ .file = .{
        .path = "/tmp/README.md",
        .label = "README.md",
        .depth = 1,
        .supported = true,
        .open = true,
        .active = false,
        .dirty = true,
        .external_change = true,
        .symlink = false,
        .icon_kind = @intFromEnum(file_tree_icon.IconKind.document),
    } }};
    var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 16, dim, dim, .{
        .index = 0,
        .foreground = selected_fg,
    }, null);
    defer dl.deinit(allocator);
    var saw_icon = false;
    var saw_label = false;
    for (dl.cells) |cell| {
        try std.testing.expect(cell.col < 16);
        try std.testing.expectEqual(selected_fg, cell.style.foreground);
        if (cell.codepoint == icons.codepoint(.document)) {
            saw_icon = true;
            try std.testing.expectEqual(@as(u16, 5), cell.col);
        }
        if (cell.codepoint == 'R') {
            saw_label = true;
            try std.testing.expectEqual(@as(u16, 7), cell.col);
        }
    }
    try std.testing.expect(saw_icon and saw_label);

    var narrow = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, 7, dim, dim, null, null);
    defer narrow.deinit(allocator);
    for (narrow.cells, 0..) |cell, i| {
        try std.testing.expect(cell.col < 7);
        for (narrow.cells[i + 1 ..]) |other| try std.testing.expect(cell.row != other.row or cell.col != other.col);
    }
}

test "file tree disclosure icon label and state cells never overlap at narrow widths" {
    const allocator = std.testing.allocator;
    for (1..18) |cols_usize| for (0..5) |depth| for (0..4) |state| {
        const rows = [_]file_tree.Row{.{ .file = .{
            .path = "/tmp/a.zig",
            .label = "a.zig",
            .depth = @intCast(depth),
            .supported = true,
            .open = false,
            .active = false,
            .dirty = state & 1 != 0,
            .external_change = state & 2 != 0,
            .symlink = false,
            .icon_kind = @intFromEnum(file_tree_icon.IconKind.code),
        } }};
        const cols: u16 = @intCast(cols_usize);
        var dl = try buildFileTreeDrawList(allocator, &rows, null, 0, 1, cols, .default, .default, null, null);
        defer dl.deinit(allocator);
        for (dl.cells, 0..) |cell, i| {
            try std.testing.expect(cell.col < cols);
            for (dl.cells[i + 1 ..]) |other| try std.testing.expect(cell.row != other.row or cell.col != other.col);
        }
    };
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
        var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 10, dim, &.{}, &.{}, null, 1, bright, null);
        defer dl.deinit(allocator);
        for (dl.cells) |c| {
            const active = c.row == sidebarGlyphRow(1, 0, 1); // slot 1(활성) 1줄 행

            try std.testing.expectEqual(if (active) bright else dim, c.style.foreground);
            try std.testing.expectEqual(active, c.style.bold);
        }
    }
    // pane 탭 바: active_tab=1 → 탭 1(우측 세그먼트) 글자만 bright + bold. cols=20 → tab_w=8, 탭 0 [1,8), 탭 1 [9,16).
    {
        const titles = [_][]const u8{ "sh", "vim" };
        var dl = try buildPaneTabBarDrawList(allocator, &titles, 20, dim, false, 1, bright, 0, 0, null);
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
// ‹가 진하면 "왼쪽에 잘린 탭 더 있음"을 알리는 단서(부분 탭 좌측 잘림 cue). cols=40·고정폭16·3탭 → total=48,
// ‹·›가 각 2칸이라 tab_cols=33, max_scroll=15.
test "scroll ‹/› highlight only the scrollable direction (boundary uses muted fg)" {
    const allocator = std.testing.allocator;
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } }; // fg(muted)
    const bright: terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }; // active_fg(강조)
    const titles = [_][]const u8{ "a", "b", "c" };
    // scroll=0(맨 왼쪽): ‹ 흐림(왼쪽 끝), › 강조(오른쪽 더 있음).
    {
        var dl = try buildPaneTabBarDrawList(allocator, &titles, 40, dim, false, null, bright, 16, 0, null);
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
    // scroll=15(맨 오른쪽=max_scroll): ‹ 강조(왼쪽 더 있음), › 흐림(오른쪽 끝).
    {
        var dl = try buildPaneTabBarDrawList(allocator, &titles, 40, dim, false, null, bright, 16, 15, null);
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
        var dl = try buildPaneTabBarDrawList(allocator, &titles, 40, dim, false, null, bright, 16, 7, null);
        defer dl.deinit(allocator);
        for (dl.cells) |c| {
            if (c.codepoint == '<' or c.codepoint == '>') try std.testing.expectEqual(bright, c.style.foreground);
        }
    }
}

test "buildSidebarDrawList: close_rows로 지정한 행 우측에 닫기 ✕(우측 두 칸 여백)" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{ "a", "b" };
    // close_rows[1]=true → ✕가 slot 1 이름줄(경로 없으니 single), col cols-3=7에 하나 추가된다(우측 2칸 여백).
    var hovered = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 10, .default, &.{ false, true }, &.{}, null, null, .default, null);
    defer hovered.deinit(allocator);
    var close_count: usize = 0;
    for (hovered.cells) |c| {
        if (c.codepoint == sidebar_close_glyph) {
            close_count += 1;
            try std.testing.expectEqual(sidebarGlyphRow(1, 0, 1), c.row);
            try std.testing.expectEqual(@as(u16, 7), c.col); // cols(10) - 3(우측 두 칸 여백)
        }
    }
    try std.testing.expectEqual(@as(usize, 1), close_count);

    // close_row=null이면 ✕ 없음.
    var none = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 10, .default, &.{}, &.{}, null, null, .default, null);
    defer none.deinit(allocator);
    for (none.cells) |c| try std.testing.expect(c.codepoint != sidebar_close_glyph);

    // 범위 밖 close_row(탭 수 이상)는 무시 — ✕ 없음.
    var oob = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 10, .default, &.{ false, false, false, false, false, true }, &.{}, null, null, .default, null);
    defer oob.deinit(allocator);
    for (oob.cells) |c| try std.testing.expect(c.codepoint != sidebar_close_glyph);
}

// 고정 핀(📌)은 이름줄 **우측 끝**(선두가 아니라)에 그린다 — 선두 칼럼은 동작/활성 마커(·/*) 전용이라 핀이 그걸
// 가리지 않게(사용자 요청). 옛 설계는 이름 prefix("📌 ")로 선두에 박았다.
test "buildSidebarDrawList: pinned row draws the pin at the name line's right edge, not the lead" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{ "alpha", "beta" };
    const pins = [_]bool{ true, false }; // 탭0만 고정
    var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &pins, 12, .default, &.{}, &.{}, null, null, .default, null);
    defer dl.deinit(allocator);

    var pin_count: usize = 0;
    for (dl.cells) |c| {
        if (c.codepoint == sidebar_pin_glyph) {
            pin_count += 1;
            try std.testing.expectEqual(sidebarGlyphRow(0, 0, 1), c.row); // 탭0 이름줄(single)
            try std.testing.expectEqual(@as(u16, 9), c.col); // cols(12) - 3: 핀(2칸)=cols-3,2 + cols-1 우측 패딩 보존
            try std.testing.expectEqual(@as(u2, 2), c.width); // 이모지 2칸
            try std.testing.expect(c.col + c.width <= 11); // 핀 우측 끝 ≤ cols-2 → cols-1(=11) 우측 패딩 침범 금지(회귀 방지)
        }
    }
    try std.testing.expectEqual(@as(usize, 1), pin_count); // 비고정 탭1엔 핀 없음
    // 선두(col 0, 탭0 이름줄)는 핀이 아니라 텍스트('a')다 — 핀이 선두를 차지하지 않음.
    for (dl.cells) |c| {
        if (c.col == 0 and c.row == sidebarGlyphRow(0, 0, 1)) try std.testing.expect(c.codepoint != sidebar_pin_glyph);
    }
}

// 핀 + 호버(close_row) 동시: ✕는 cols-2, 핀은 그 왼쪽(cols-5)에 둬 안 겹친다.
test "buildSidebarDrawList: pinned + hovered row places the pin left of the close glyph" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{"alpha"};
    const pins = [_]bool{true};
    var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &pins, 12, .default, &.{true}, &.{}, null, null, .default, null); // close_row=0(호버)
    defer dl.deinit(allocator);
    var pin_col: ?u16 = null;
    var close_col: ?u16 = null;
    for (dl.cells) |c| {
        if (c.codepoint == sidebar_pin_glyph) pin_col = c.col;
        if (c.codepoint == sidebar_close_glyph) close_col = c.col;
    }
    try std.testing.expectEqual(@as(u16, 6), pin_col.?); // cols(12) - 6 (✕가 한 칸 더 안쪽으로 가며 핀도 이동)
    try std.testing.expectEqual(@as(u16, 9), close_col.?); // cols(12) - 3 (우측 두 칸 여백)
    try std.testing.expect(pin_col.? + 2 <= close_col.?); // 핀(2칸)이 ✕와 안 겹침
}

// 긴 이름은 핀 앞에서 말줄임(…)된다 — 긴 이름이 핀을 덮지 않게(name end_col=pin_col).
test "buildSidebarDrawList: pinned long name is ellipsized before the pin" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{"abcdefghijklmnopqrst"}; // 폭(12)을 넘는 긴 이름
    const pins = [_]bool{true};
    var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &pins, 12, .default, &.{}, &.{}, null, null, .default, null);
    defer dl.deinit(allocator);
    var has_ellipsis = false;
    for (dl.cells) |c| {
        if (c.codepoint == text_layout.ellipsis_glyph) has_ellipsis = true;
        // 핀(col 9, cols-3) 외 모든 글자/말줄임 셀은 핀 왼쪽(col<9)에 — 겹침 없음.
        if (c.codepoint != sidebar_pin_glyph) try std.testing.expect(c.col < 9);
    }
    try std.testing.expect(has_ellipsis); // 잘림 표시 존재
}

test "buildSidebarDrawList: editing_row 이름줄만 tail 앵커로 caret(끝)을 보존한다" {
    // 워크스페이스 카드·그룹 헤더 rename도 편집 텍스트가 "이름|"이라 caret이 끝에 온다. 사이드바 폭보다 길면
    // head는 끝(caret)을 잘라 안 보였다 — editing_row 지정 슬롯의 **이름줄(j==0)만** tail 앵커로 끝을 보존한다.
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "short-a", "renaming-a-very-long-workspace|" };

    // editing_row=1 → 슬롯1 이름줄은 tail. 어딘가에 '|'(caret)이 남는다.
    var edited = try buildSidebarDrawList(allocator, &names, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 12, .default, &.{}, &.{}, null, null, .default, 1);
    defer edited.deinit(allocator);
    var has_caret = false;
    for (edited.cells) |c| {
        if (c.codepoint == '|') has_caret = true;
    }
    try std.testing.expect(has_caret); // 편집 슬롯의 끝 caret 보존

    // editing_row=null(대조) → 슬롯1도 head라 긴 이름이 잘려 '|'이 없다.
    var none = try buildSidebarDrawList(allocator, &names, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 12, .default, &.{}, &.{}, null, null, .default, null);
    defer none.deinit(allocator);
    var none_caret = false;
    for (none.cells) |c| {
        if (c.codepoint == '|') none_caret = true;
    }
    try std.testing.expect(!none_caret); // head 앵커는 끝(caret)을 못 보여줌
}

test "buildSidebarDrawList draws a '+' button row below the tabs when plus_row is set" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{ "sh", "vim" }; // 탭 2개 → "+"는 slot 2
    var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 10, .default, &.{}, &.{}, titles.len, null, .default, null);
    defer dl.deinit(allocator);
    // size.rows = "+" 슬롯(slot 2, single) 행 + 1.
    try std.testing.expectEqual(sidebarGlyphRow(2, 0, 1) + 1, dl.size.rows);
    var plus_count: usize = 0;
    for (dl.cells) |c| {
        if (c.codepoint == '+') {
            plus_count += 1;
            try std.testing.expectEqual(sidebarGlyphRow(2, 0, 1), c.row); // 탭 목록 아래 슬롯
            try std.testing.expectEqual(@as(u16, 10 / 2), c.col); // 가로 중앙
        }
    }
    try std.testing.expectEqual(@as(usize, 1), plus_count);
    // plus_row=null이면 "+" 없음, rows = 마지막 탭(slot 1, single) 행 + 1.
    var no_plus = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 10, .default, &.{}, &.{}, null, null, .default, null);
    defer no_plus.deinit(allocator);
    try std.testing.expectEqual(sidebarGlyphRow(1, 0, 1) + 1, no_plus.size.rows);
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
    try std.testing.expectEqual(text_layout.ellipsis_glyph, last.codepoint);
    try std.testing.expectEqual(@as(u16, 4), last.col);
    try std.testing.expectEqual(bg, last.style.background);
    // 딱 맞는 제목은 "…" 없이 박스를 채운다(좌패딩 + 'o','k' + 남은 bg 5칸 = 8).
    var exact = try buildFloatingTabDrawList(allocator, "ok", 8, fg, bg);
    defer exact.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 8), exact.cells.len);
    for (exact.cells) |c| try std.testing.expect(c.codepoint != text_layout.ellipsis_glyph);
}

test "buildFromDrawList shapes a synthesized sidebar draw list into glyph cells (shared atlas seam)" {
    // 사이드바 제목 패스가 터미널과 같은 seam(shape→raster→RenderFrame)을 탄다. fake bridge로
    // 합성 DrawList가 glyph까지 닿는지 고정한다 — 실제 CoreText 없이 연결 계약만 검증.
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{"ab"};
    const draw_list = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 10, .default, &.{}, &.{}, null, null, .default, null);

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

test "buildFromDrawList interns faces into the shared RendererState registry (FontId stable across frames)" {
    // 루트커즈 회귀 가드 — 조합 중 '놔'에 번개가 뜨던 atlas slot 오인 HIT.
    //
    // atlas는 frame 사이에 살아남는다(RendererState 소유). 그런데 예전엔 shapeOnly가 FontIdentityRegistry를
    // **frame·pane마다 새로** 만들었다. FontId는 face가 처음 등장한 순서로 매기는 지역 순번이라, registry가
    // frame마다 새로 만들어지면 같은 순번(예: 2)이 frame마다 다른 face(어제 emoji, 오늘 한글)를 가리킨다.
    // atlas cache key는 그 FontId+glyph_id로 slot을 재사용하므로, 이전 frame이 심볼 face용으로 구운 slot을
    // 이번 frame의 한글 face가 오인 HIT해 엉뚱한(번개) 비트맵을 그렸다. 순번이 뒤집힐 때만 터져 간헐적이었다.
    //
    // 수정: registry를 RendererState가 소유(atlas와 같은 수명)해, 같은 PostScript name이 frame·pane을 넘어
    // 같은 FontId를 받게 한다. 이 테스트는 build가 그 **공유** registry에 intern하고(per-frame throwaway 아님)
    // face가 frame 간 안정됨을 고정한다 — shapeOnly를 per-frame registry로 되돌리면 renderer_state.font_registry가
    // 계속 비어 count 단언에서 실패한다.
    const allocator = std.testing.allocator;
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    const builder = CoreTextFrameBuilder{
        .appearance = try config.resolveAppearance(.{}),
        .shape_draw_list = testShapeDrawList,
        .rasterize_glyph = testRasterizeGlyph,
    };

    // Frame 1: ASCII 제목 → fake shaper가 "Menlo-Regular"를 공유 registry에 intern.
    {
        const titles = [_][]const u8{"a"};
        const dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 10, .default, &.{}, &.{}, null, null, .default, null);
        var f = try builder.buildFromDrawList(allocator, dl, &renderer_state);
        defer f.deinit(allocator);
    }
    // build가 per-frame throwaway가 아니라 **공유** registry에 intern했다(throwaway였다면 count=0).
    try std.testing.expectEqual(@as(usize, 1), renderer_state.font_registry.count());
    const menlo_id = try renderer_state.font_registry.intern(.{ .postscript_name = "Menlo-Regular" });

    // Frame 2: CJK 제목 → "AppleSDGothicNeo-Regular"를 **같은** registry에 intern. Menlo는 frame1에서
    // 등록된 채 그대로 남아(count가 1→2로 누적, 리셋 아님) registry가 frame을 넘어 살아있음을 증명한다.
    {
        const titles = [_][]const u8{"가"};
        const dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]u21{}, &[_]bool{}, 10, .default, &.{}, &.{}, null, null, .default, null);
        var f = try builder.buildFromDrawList(allocator, dl, &renderer_state);
        defer f.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), renderer_state.font_registry.count());
    // Menlo의 FontId가 frame 간 불변 = atlas cache key 안정(루트커즈 봉인). 뒤집힌 등장 순서로 다시 intern해도
    // idempotent라 새 순번을 안 받는다.
    try std.testing.expectEqual(menlo_id, try renderer_state.font_registry.intern(.{ .postscript_name = "Menlo-Regular" }));
}

test "buildDockScmDrawList: 브랜치 헤더가 첫 줄이고 접힌 섹션은 표시가 바뀐다" {
    // 헤더가 첫 줄이라는 사실은 **히트테스트와 공유하는 계약**이다(app_session.scmRowAt이 한 줄을 뺀다).
    // 여기서 깨지면 사용자가 누른 행과 열리는 행이 어긋난다.
    const allocator = std.testing.allocator;
    const rows = [_]scm_view.Row{
        .{ .section = .{ .section = .staged, .count = 2, .action = .unstage } },
        .{ .file = .{ .section = .staged, .path = "src/main.zig", .letter = 'M', .action = .unstage, .added = 3, .removed = 1 } },
    };
    const head: git_status.Head = .{ .branch = "feat/x", .ahead = 2, .behind = 1, .has_ab = true };
    var dl = try buildDockScmDrawList(allocator, 40, 3, head, &rows, &.{ false, false }, null, 0, .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } }, .{ .rgb = .{ .r = 136, .g = 136, .b = 136 } }, .{ .rgb = .{ .r = 221, .g = 161, .b = 94 } });
    defer dl.deinit(allocator);

    // 0행: git 아이콘 + 브랜치 이름 + ahead/behind.
    try std.testing.expect(hasCell(dl.cells, 0, icons.codepoint(.git_branch)));
    try std.testing.expect(hasCell(dl.cells, 0, 'f')); // feat/x
    try std.testing.expect(hasCell(dl.cells, 0, '2')); // ↑2
    // 1행: 섹션 헤더(펼침 표시 v) — 2행: 파일 행(상태 문자 M).
    try std.testing.expect(hasCell(dl.cells, 1, 'v'));
    try std.testing.expect(hasCell(dl.cells, 2, 'M'));
    // 상태 문자는 **오른쪽 끝 열**이다(VS Code 배치). 행 동작(`+`/`−`)은 호버 컨트롤이라 이 표면엔 없다.
    try std.testing.expectEqual(@as(u32, 'M'), cellAt(dl.cells, 2, 40 - 1).?.codepoint);

    var folded = try buildDockScmDrawList(allocator, 40, 3, head, rows[0..1], &.{ true, false }, null, 0, .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } }, .{ .rgb = .{ .r = 136, .g = 136, .b = 136 } }, .{ .rgb = .{ .r = 221, .g = 161, .b = 94 } });
    defer folded.deinit(allocator);
    try std.testing.expect(hasCell(folded.cells, 1, '>')); // 접힘 표시
    try std.testing.expect(!hasCell(folded.cells, 1, 'v'));
}

test "buildDockScmDrawList: 충돌 행에는 동작을 붙이지 않는다" {
    // 누르면 `git add`가 도는 컨트롤을 충돌 파일에 두면, 충돌 표시가 든 파일이 "해결됨"으로 커밋된다(§3.5.2).
    const allocator = std.testing.allocator;
    const rows = [_]scm_view.Row{
        .{ .file = .{ .section = .changes, .path = "f.txt", .letter = 'U', .action = .none, .conflicted = true, .unknown_delta = true } },
    };
    var dl = try buildDockScmDrawList(allocator, 40, 2, null, &rows, &.{ false, false }, null, 0, .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } }, .{ .rgb = .{ .r = 136, .g = 136, .b = 136 } }, .{ .rgb = .{ .r = 221, .g = 161, .b = 94 } });
    defer dl.deinit(allocator);
    try std.testing.expect(hasCell(dl.cells, 0, 'U')); // 상태 문자는 남는다
    try std.testing.expect(!hasCell(dl.cells, 0, '+')); // 동작은 붙지 않는다
}

test "buildDockScmDrawList: 폭이 아주 좁아도 격자 밖 열에 쓰지 않는다" {
    // 도크를 좁게 끌면 cols가 한 자리까지 내려간다. 시작 열만 보고 그리면 포화 뺄셈으로 0이 된 자리에서
    // 상태 문자·증감이 오른쪽으로 흘러 격자 밖 열을 만든다(적대적 검증 2026-08-14).
    const allocator = std.testing.allocator;
    const rows = [_]scm_view.Row{
        .{ .section = .{ .section = .staged, .count = 1, .action = .unstage } },
        .{ .file = .{ .section = .staged, .path = "a.txt", .letter = 'M', .action = .unstage, .added = 12, .removed = 34 } },
    };
    var width: u16 = 1;
    while (width <= 12) : (width += 1) {
        var dl = try buildDockScmDrawList(allocator, width, 3, null, &rows, &.{ false, false }, null, 0, .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } }, .{ .rgb = .{ .r = 136, .g = 136, .b = 136 } }, .{ .rgb = .{ .r = 221, .g = 161, .b = 94 } });
        defer dl.deinit(allocator);
        for (dl.cells) |c| {
            try std.testing.expect(c.col < width);
            try std.testing.expect(c.col + c.width <= width); // 2칸 아이콘도 끝을 넘지 않는다
        }
    }
}

fn cellAt(cells: []const renderer.DrawCell, row: u16, col: u16) ?renderer.DrawCell {
    for (cells) |c| {
        if (c.row == row and c.col == col) return c;
    }
    return null;
}

fn hasCell(cells: []const renderer.DrawCell, row: u16, codepoint: u32) bool {
    for (cells) |c| {
        if (c.row == row and c.codepoint == codepoint) return true;
    }
    return false;
}

// SB1-S3b: 상태표시줄 항목 빌더. 배치(`chrome.components.status_bar`)는 px 폭을 받으므로 이 frame의 `cols`가
// 곧 그 입력이다 — cols가 틀리면 항목이 겹치거나 자리가 남는다. 아이콘 폭 규약(2칸 + 1칸 여백)과 말줄임까지
// 여기서 못박는다(배치는 글자를 자르지 않는다는 계약의 반대쪽).
test "SB1-S3b: 항목 frame은 아이콘 2칸 + 여백 1칸 뒤에 텍스트를 놓고 cols를 실제 사용폭으로 낸다" {
    const allocator = std.testing.allocator;
    const fg: terminal.Color = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } };
    const muted: terminal.Color = .{ .rgb = .{ .r = 128, .g = 128, .b = 128 } };

    var dl = try buildStatusBarItemDrawList(allocator, icons.codepoint(.git_branch), "main", 40, fg, muted);
    defer dl.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 1), dl.size.rows);
    // 아이콘은 col 0에 2칸.
    try std.testing.expectEqual(@as(u16, 0), dl.cells[0].col);
    try std.testing.expectEqual(@as(u8, 2), dl.cells[0].width);
    try std.testing.expectEqual(icons.codepoint(.git_branch), dl.cells[0].codepoint);
    // 텍스트는 col 3부터(2칸 + 여백 1칸).
    try std.testing.expectEqual(@as(u16, 3), dl.cells[1].col);
    // cols = 아이콘 3칸 + "main" 4칸.
    try std.testing.expectEqual(@as(u16, 7), dl.size.cols);
}

test "SB1-S3b: 텍스트가 상한을 넘으면 말줄임하고 cols가 상한 안에 머문다" {
    const allocator = std.testing.allocator;
    const fg: terminal.Color = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } };

    var dl = try buildStatusBarItemDrawList(allocator, icons.codepoint(.git_branch), "feature/very-long-branch-name-that-overflows", 10, fg, fg);
    defer dl.deinit(allocator);

    // 아이콘 3칸 + 텍스트 최대 10칸 = 13칸을 넘지 않는다. 넘으면 배치가 자리를 잘못 잡아 항목이 겹친다.
    try std.testing.expect(dl.size.cols <= 13);
    try std.testing.expect(dl.size.cols > 3); // 텍스트가 아예 사라지지도 않는다
}

test "SB1-S3b: 아이콘 없이도 서고, 빈 텍스트는 폭 0이라 배치가 버린다" {
    const allocator = std.testing.allocator;
    const fg: terminal.Color = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } };

    var no_icon = try buildStatusBarItemDrawList(allocator, null, "abc", 40, fg, fg);
    defer no_icon.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 0), no_icon.cells[0].col); // 아이콘이 없으면 텍스트가 col 0부터
    try std.testing.expectEqual(@as(u16, 3), no_icon.size.cols);

    var empty = try buildStatusBarItemDrawList(allocator, null, "", 40, fg, fg);
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 0), empty.size.cols); // 폭 0 → status_bar.compute가 dropped로 센다
}

// cluster 풀 누락 회귀 가드. CG1(경계 테스트)이 "풀을 채우고 안 싣는" 정적 패턴을 잡지만, 여기서는 **실제
// 다중 codepoint 클러스터**가 풀에 들어가고 셀이 그것을 가리키는지까지 본다 — 풀을 안 실으면 셰이퍼가 base만
// 그려 한글 중성·종성이 사라진다(이 함수에서 실제로 한 번 났던 결함이다).
test "SB1-S3b: NFD 한글 브랜치명도 cluster 풀을 싣고 나간다" {
    const allocator = std.testing.allocator;
    const fg: terminal.Color = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } };
    // "한글" NFD(ᄒ+ᅡ+ᆫ, ᄀ+ᅳ+ᆯ) — 조합형이라 셀 하나가 codepoint 여럿을 가리킨다.
    const nfd = "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}";

    var dl = try buildStatusBarItemDrawList(allocator, icons.codepoint(.git_branch), nfd, 40, fg, fg);
    defer dl.deinit(allocator);

    try std.testing.expect(dl.grapheme_pool.len > 0); // 풀이 실렸다
    // 텍스트 셀 중 최소 하나가 풀을 가리킨다(= 다중 codepoint 클러스터가 살아 있다).
    var refs: usize = 0;
    for (dl.cells) |c| {
        if (c.grapheme_count > 0) refs += 1;
    }
    try std.testing.expect(refs > 0);
}
