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
        const list_or = renderer.buildDrawListWithUnfocused(allocator, active.core.renderSnapshot(), self.cursor_unfocused);
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
    /// 동형(읽기 락 아래 DrawList 복사, shape는 락 밖). renderer_state는 불필요(place를 안 한다).
    pub fn shapeOnlyBuild(
        self: CoreTextFrameBuilder,
        allocator: std.mem.Allocator,
        app_window: *maru.session.AppWindow,
        io: std.Io,
    ) !ShapedPane {
        const active = app_window.active() orelse return error.NoActiveSurface;
        active.lockCore(io);
        const list_or = renderer.buildDrawListWithUnfocused(allocator, active.core.renderSnapshot(), self.cursor_unfocused);
        // renderSnapshot이 뷰포트 합성에 실제로 쓴 view_offset을 **같은 락 아래**에서 같이 읽는다 — 호출자(app_session
        // 투영 게이트)가 "이 프레임이 그린 스크롤 위치"를 정확히 기록해, gate-read와 render-read 사이 리더 스크롤로
        // 어긋나는 read/render TOCTOU(스크롤 stale 재발) 없이 다음 tick의 재투영 여부를 판정한다.
        const rendered_view_offset = active.core.view_offset;
        active.unlockCore(io);
        const draw_list = try list_or;
        var pane = try self.shapeOnly(allocator, draw_list);
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
        var pane = try self.shapeOnly(allocator, draw_list);
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

    /// DrawList(소유권 이전)를 **shape까지만** 한다 — atlas는 안 건드린다. 결과 ShapedPane이 owned_list·
    /// shaped·font_registry를 소유한다. 멀티 페인은 이걸 모아 한 번에 `placeMultiPane`(통합 배치)한 뒤
    /// `finishPane`으로 per-pane RenderFrame을 만든다. font_registry는 rasterize까지 살아야 하므로
    /// ShapedPane이 소유한다 — interned PostScript registry라 페인별 독립이다(멀티 페인이 동시에 서로 다른
    /// registry를 들 수 있어 RendererState 단일 필드로 승격 불가).
    pub fn shapeOnly(
        self: CoreTextFrameBuilder,
        allocator: std.mem.Allocator,
        draw_list: renderer.DrawList,
    ) !ShapedPane {
        var owned_list = draw_list;
        var draw_list_owned = true;
        errdefer if (draw_list_owned) owned_list.deinit(allocator);

        var font_registry = renderer.FontIdentityRegistry.init(allocator);
        errdefer font_registry.deinit();

        const shaper = coretext_shaper.CoreTextDrawListShaper{
            .appearance = self.appearance,
            .shape_draw_list = self.shape_draw_list,
            // shaper config의 device_scale은 정수(정사각 fallback/cache key 거친 식별자)로만 쓰이고,
            // 실제 화면 경로는 아래 cell_width_px/cell_height_px(분수 메트릭)로 정밀 식별한다.
            .device_scale = renderer.deviceScaleFromMilli(self.scale_milli),
            .cell_width_px = self.cell_width_px,
            .cell_height_px = self.cell_height_px,
        };
        const shaped = try shaper.shape(allocator, owned_list, &font_registry);
        draw_list_owned = false;
        return .{ .owned_list = owned_list, .shaped = shaped, .font_registry = font_registry };
    }

    /// 통합 place로 만든 GlyphFrame과 ShapedPane을 합쳐 per-pane RenderFrame을 만든다(rasterizer가
    /// pane.font_registry를 참조해 비트맵 생성). **ShapedPane을 consume한다**: 성공 시 owned_list가
    /// RenderFrame으로 이동하고 shaped/font_registry는 정리되므로, caller는 성공한 pane에 deinit을 부르면
    /// 안 된다. 실패 시 frame은 buildQuadRasterFromGlyphFrame이 정리하고, ShapedPane은 consume되지 않아
    /// caller가 pane.deinit으로 정리한다.
    pub fn finishPane(
        self: CoreTextFrameBuilder,
        allocator: std.mem.Allocator,
        pane: *ShapedPane,
        frame: renderer.glyph_frame.GlyphFrame,
        renderer_state: *renderer.RendererState,
    ) !renderer.RenderFrame {
        const rasterizer = coretext_raster.CoreTextGlyphRasterizer{
            .appearance = self.appearance,
            .font_registry = &pane.font_registry,
            .rasterize_glyph = self.rasterize_glyph,
            .scale_milli = self.scale_milli,
        };
        const render_frame = try renderer_state.buildQuadRasterFromGlyphFrame(allocator, pane.owned_list, frame, rasterizer);
        // 성공: owned_list가 render_frame으로 이동했다. shaped/font_registry는 더 불필요 → 정리.
        pane.shaped.deinit(allocator);
        pane.font_registry.deinit();
        return render_frame;
    }
};

/// shape만 끝낸 한 페인의 소유 상태(owned_list·shaped·font_registry). 멀티 페인 통합 빌드의 중간 단위:
/// 여러 ShapedPane을 모아 한 번에 `placeMultiPane`한 뒤 `finishPane`으로 per-pane RenderFrame을 만든다.
pub const ShapedPane = struct {
    owned_list: renderer.DrawList,
    shaped: renderer.ShapedGlyphRunList,
    font_registry: renderer.FontIdentityRegistry,
    // 이 페인을 그릴 때 renderSnapshot이 쓴 활성 surface view_offset(스크롤 위치). shapeOnlyBuild(활성 경로)만
    // 락 아래에서 채우고, 그 외 생성(비활성 pane·사이드바 — shapeOnly 직접)은 0(스크롤 추적 비대상). app_session
    // 투영 게이트가 last_rendered_view_offset에 이 값을 기록한다(render-time — read/render TOCTOU 방지).
    view_offset: usize = 0,

    /// shape 결과 전체를 정리한다(owned_list 포함). finishPane이 consume에 성공한 ShapedPane엔 호출하면
    /// 안 된다(double-free) — finishPane 실패 경로/place 실패 경로에서만 부른다.
    pub fn deinit(self: *ShapedPane, allocator: std.mem.Allocator) void {
        self.shaped.deinit(allocator);
        self.font_registry.deinit();
        self.owned_list.deinit(allocator);
    }
};

/// 닫기(✕) 아이콘 코드포인트(U+2715 MULTIPLICATION X). 호버 슬롯 우측에 그린다.
pub const sidebar_close_glyph: u21 = 0x2715;

/// 고정(pin) 표시 glyph(U+1F4CC ROUND PUSHPIN). 고정된 워크스페이스 카드 이름줄 **우측 끝**에 그린다 — 선두가
/// 아니다. 선두 칼럼은 동작/활성 마커(·/*)를 위해 비워둔다(핀이 그 표시를 가리지 않게 — 사용자 요청). 📌는 컬러
/// 이모지라 외형(빨간 핀)이 cell fg와 무관하다(스타일 색은 영향 없음). 옛 설계는 이름 prefix("📌 ")로 선두에 박았다.
pub const sidebar_pin_glyph: u21 = 0x1F4CC;

/// 말줄임 표시 glyph(U+2026 HORIZONTAL ELLIPSIS, 1칸). 제목이 칸을 넘으면 마지막 칸을 이걸로 바꾼다.
pub const title_ellipsis_glyph: u21 = 0x2026;

/// title의 디스플레이 폭(칸 합) — wide glyph는 2, 나머지 1. 깨진 UTF-8 바이트는 U+FFFD(1칸). 말줄임 필요 판정용.
/// pub: pane 라벨 세그먼트 폭(paneLabelCols)도 이 단일 출처로 폭을 잰다(렌더 ellipsize와 같은 셈법이라 라벨
/// 칸 예약과 실제 글리프가 어긋나지 않는다).
/// 카드 보조줄(branch/folder)에 maru가 의도적으로 박은 아이콘은 **렌더 폭 2칸**으로 친다 — 단 `widen_icons`=true일
/// 때만. advance(cellWidth)는 1이지만 1칸(~8px)에 다운스케일하면 octocat·폴더 실루엣이 뭉개져 안 보였다(사용자 피드백).
/// 에이전트 gutter 아이콘(별도 셀 width 2)과 같은 ~16px로 통일. **opt-in인 이유**: 이 폭 함수는 pane 탭 제목·pane
/// 라벨·OSC 0/2 터미널 제목·rename 편집기까지 공유하는데, 등록 10개(0xF0001~A)가 Nerd Fonts v3 MDI(Plane-15 PUA로
/// 이전)와 겹쳐 — 그 제목/이름에 우연히 그 글리프가 와도 폭을 2칸으로 키우면 탭 텍스트가 어긋나고 rename caret 예약
/// (renameDisplayWidth는 1칸 셈)과 틀어진다. 그래서 maru가 아이콘을 박는 카드 보조줄만 widen=true, 나머지(터미널/
/// 사용자 텍스트)는 false(1칸). 아이콘이 아니거나 widen=false면 cellWidth 그대로(EAW 2칸·일반 1칸).
fn titleCellWidth(cp: u21, widen_icons: bool) u16 {
    if (widen_icons and renderer.icon_glyph.isRegisteredIcon(cp)) return 2;
    return @max(1, terminal.width.cellWidth(cp));
}

/// title의 표시 칸 폭. `widen_icons`면 카드 보조줄에 박힌 등록 maru 아이콘을 2칸으로 친다(titleCellWidth 참고 —
/// 카드만 true, 탭·OSC·라벨 제목은 false). appendEllipsizedTitle의 말줄임 예약과 렌더가 같은 폭을 봐야 한다.
pub fn titleDisplayWidth(title: []const u8, widen_icons: bool) usize {
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
        total += titleCellWidth(cp, widen_icons);
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
    widen_icons: bool, // 카드 보조줄(branch/folder)만 true — 등록 maru 아이콘을 2칸 렌더(titleCellWidth)
) !u16 {
    if (end_col <= start_col) return start_col;
    const fits = titleDisplayWidth(title, widen_icons) <= @as(usize, end_col - start_col);
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
        const w: u16 = titleCellWidth(cp, widen_icons); // 카드 보조줄이면 등록 maru 아이콘 2칸 렌더
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

/// 사이드바 카드 row 인코딩 — 한 슬롯(탭) 안에서 (line_index, line_count)를 row에 싣는다. 렌더러(.m 사이드바
/// 루프)가 slot=row/32, line_count=(row%32)/4, line_index=(row%32)%4로 디코드해 line_count줄(각 1×cell)을 슬롯
/// 안 블록으로 세로 중앙 정렬하고 line_index번째 줄에 그린다. line_count=1이면 단일행 중앙. 최대 4줄(이름·브랜치·
/// 경로·상태) 지원(base 32 — slot≤2047). 밴드 셀(slot_id=0)은 이 인코딩과 무관하게 row=slot 그대로(렌더러가
/// slot_id로 분기) — 여기를 인코딩 단일 출처로 고정한다. buildSidebarDrawList가 4줄(이름·브랜치·경로·상태,
/// `lines: [4]`)까지 쓰고, 슬롯 높이도 4줄을 담게 키웠다(sidebar_slot_height_ratio_milli=4600).
/// .m 디코더가 base 32·×4를 하드코딩하므로(FFI 경계), 이 값을 바꾸면 아래 "인코딩 값 고정" 테스트가 깨져 .m 동기 수정을 강제한다.
pub const sidebar_line_base: u16 = 32;
pub fn sidebarGlyphRow(slot: usize, line_index: u16, line_count: u16) u16 {
    return @as(u16, @intCast(slot)) *| sidebar_line_base +| line_count *| 4 +| line_index;
}

test "sidebarGlyphRow 인코딩 값 고정 (slot*32 + line_count*4 + line_index ↔ .m 디코더 결합)" {
    // maru_metal_renderer.m이 slot=row/32, line_count=(row%32)/4, line_index=(row%32)%4로 디코드한다(FFI 경계라
    // 하드코딩). 아래 row 리터럴이 바뀌면 .m도 동기 수정해야 하므로 값으로 고정 — 인코딩만 바꾸고 .m을 안 고치면
    // 카드 glyph가 엉뚱한 슬롯/줄에 그려진다. 디코더 역산도 같이 검증한다.
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
    pinned: []const bool, // pinned[i]=true면 그 슬롯 이름줄 우측 끝에 📌(빈 슬라이스=핀 없음)
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
    const icon_cols: u16 = 3; // 에이전트 아이콘 자리(아이콘 2칸 + 간격 1칸) — 왼쪽 독립 gutter
    var max_row: u16 = 0;
    for (names, 0..) |name, i| {
        if (i > @as(usize, std.math.maxInt(u16)) / sidebar_line_base) break; // slot*32+…가 u16 한도 안에 들게
        // 에이전트 아이콘: 슬롯 세로 중앙(count=1) col 0에 따로 — 3줄 블록과 무관하게 워크스페이스 가운데 고정.
        // 텍스트 줄은 아이콘이 있으면 icon_cols만큼 우측에서 시작(아이콘과 안 겹치게).
        const agent_cp: u21 = if (i < agents.len) agents[i] else 0;
        const text_col: u16 = if (agent_cp != 0) icon_cols else 0;
        if (agent_cp != 0) {
            const icon_row = sidebarGlyphRow(i, 0, 1);
            try cells.append(allocator, .{ .row = icon_row, .col = 0, .codepoint = agent_cp, .width = 2, .style = style });
            max_row = @max(max_row, icon_row);
        }
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
        const close_here = close_row != null and close_row.? == i;
        const pin_col: u16 = if (close_here) (cols -| 5) else (cols -| 3);
        const draw_pin = pinned_here and cols >= 2 and pin_col > text_col;
        const name_row = sidebarGlyphRow(i, 0, n); // 이름줄(line 0) — j==0 줄과 핀이 공유(중복 계산 제거)
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
            const end_col: u16 = if (j == 0 and draw_pin) pin_col else (cols -| 1);
            _ = try appendEllipsizedTitle(allocator, &cells, lines[j], row, text_col, end_col, row_style, line_widen[j]);
            max_row = @max(max_row, row);
        }
        // 핀 글리프: 이름줄(name_row, n줄 블록 중앙) 우측. 컬러 이모지라 style.fg와 무관(빨간 핀 고정).
        if (draw_pin) {
            try cells.append(allocator, .{ .row = name_row, .col = pin_col, .codepoint = sidebar_pin_glyph, .width = 2, .style = style });
            max_row = @max(max_row, name_row);
        }
    }

    // 닫기 ✕ 아이콘: 호버 슬롯(close_row) 우측 안쪽 col에 glyph 1개. cols가 2칸 이상일 때만(우측 여백
    // 확보). 제목이 길어 같은 col에 겹치면 painter 순서로 ✕가 위에 그려진다(긴 제목 자름은 후속).
    if (close_row) |cr| {
        if (cr < names.len and cr <= @as(usize, std.math.maxInt(u16)) / sidebar_line_base and cols >= 2) {
            // ✕는 그 슬롯 이름줄(line 0)에. 슬롯 줄 수(이름+브랜치?+경로?+상태?)로 인코딩해 블록 중앙 정렬과 일치시킨다.
            var n: u16 = 1;
            if (cr < branches.len and branches[cr].len > 0) n += 1;
            if (cr < paths.len and paths[cr].len > 0) n += 1;
            if (cr < statuses.len and statuses[cr].len > 0) n += 1;
            const x_row = sidebarGlyphRow(cr, 0, n);
            try cells.append(allocator, .{
                .row = x_row,
                .col = cols - 2, // 우측에서 한 칸 안쪽(여백)
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

    return .{
        .size = .{ .cols = cols, .rows = max_row + 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = max_row },
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
        _ = try appendEllipsizedTitle(allocator, &cells, label, 0, 1, cols - 1, .{ .foreground = fg }, false); // pane 라벨(터미널 텍스트) — 아이콘 widen 안 함
    }
    return .{
        .size = .{ .cols = cols, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = 0 },
        .cells = try cells.toOwnedSlice(allocator),
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
    if (cols >= 1) {
        const c = cols / 2; // 글리프를 grip 영역 중앙 칸에 — 양쪽 패딩
        _ = try appendEllipsizedTitle(allocator, &cells, "\u{283F}", 0, c, c + 1, .{ .foreground = fg }, false); // braille(아이콘 아님)
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
            _ = try appendEllipsizedTitle(allocator, &cells, title, 0, @intCast(start + 1), @intCast(title_end), tab_style, false); // pane 탭 제목(터미널 OSC) — widen 안 함
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
    // "+"(새 Term) 버튼 — **상단탭 Warp 폴리시: 인라인**(마지막 탭 바로 뒤). 넘쳐서 ‹›가 있으면 옛대로 far-right
    // (tab_cols+2 뒤, ‹·gap·› 다음). plus_start+1 col에 '+'. hit-test(tabbar.Metrics.plusZoneStart)와 단일 정합 —
    // 인라인 plus_start = min(titles.len*tab_w, tab_cols) = plusZoneStart의 tabsEndCol과 같다(barMetrics가 tab_count로 채움).
    const tabs_end: u16 = @min(@as(u16, @intCast(titles.len)) * tab_w, tab_cols);
    const plus_start: u16 = if (layout.has_scroll) tab_cols + 2 else tabs_end;
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
    col = try appendEllipsizedTitle(allocator, &cells, title, 0, col, cols, style, false); // 제목(터미널 텍스트) — widen 안 함
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
    col = try appendEllipsizedTitle(allocator, &cells, text, 0, col, cols, style, false); // 명령줄 텍스트 — widen 안 함
    while (col < cols) : (col += 1) {
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

test "buildSidebarDrawList lays tab titles into per-row draw cells, truncating to cols" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{ "zsh", "vim" };
    var draw_list = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]bool{}, 10, .default, null, null, null, .default);
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
    var dl = try buildSidebarDrawList(allocator, &names, &branches, &paths, &[_][]const u8{}, &[_]u21{}, &[_]bool{}, 20, .default, null, null, null, .default);
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
    const agents = [_]u21{0xF0007}; // claude ✶
    var dl = try buildSidebarDrawList(allocator, &names, &branches, &paths, &[_][]const u8{}, &agents, &[_]bool{}, 30, .default, null, null, null, .default);
    defer dl.deinit(allocator);

    // 아이콘 ✶: 슬롯 세로 중앙(count=1, idx0) col 0·width 2 — 3줄 블록(count=3)과 무관한 독립 위치.
    var icon_centered = false;
    for (dl.cells) |c| {
        if (c.codepoint == 0xF0007) {
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

// 카드 줄 안에 인라인으로 박힌 maru 아이콘(브랜치줄 octocat 0xF0009·폴더줄 0xF000A)은 **width 2(~16px)**로
// 렌더돼 작은 셀에서도 실루엣이 또렷하다(titleCellWidth). width-1(~8px)이면 octocat이 동그란 링처럼 뭉개졌다
// (사용자 피드백 "깃 아이콘이 너무 작다"). 아이콘이 2칸을 차지하므로 뒤따르는 텍스트가 그만큼 밀린다 — 회귀 방지.
test "buildSidebarDrawList inline icons (octocat·folder PUA) render width 2 and offset following text" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{"maru"};
    const branches = [_][]const u8{"\u{F0009} main"}; // octocat + 공백 + 브랜치
    const paths = [_][]const u8{"\u{F000A} ~/dev"}; // folder + 공백 + 경로
    var dl = try buildSidebarDrawList(allocator, &names, &branches, &paths, &[_][]const u8{}, &[_]u21{}, &[_]bool{}, 20, .default, null, null, null, .default);
    defer dl.deinit(allocator);

    // 아이콘 셀은 col 0·width 2. 아이콘 폭 2 + 공백 1 = 3이므로, 브랜치 'm'·경로 '~'는 col 3에서 시작.
    var octocat_w2 = false;
    var folder_w2 = false;
    var branch_text_at3 = false;
    var path_text_at3 = false;
    for (dl.cells) |c| {
        if (c.codepoint == 0xF0009 and c.row == sidebarGlyphRow(0, 1, 3)) {
            try std.testing.expectEqual(@as(u16, 0), c.col);
            try std.testing.expectEqual(@as(u2, 2), c.width);
            octocat_w2 = true;
        }
        if (c.codepoint == 0xF000A and c.row == sidebarGlyphRow(0, 2, 3)) {
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

// titleDisplayWidth는 **등록된** maru 아이콘 PUA만 2칸으로 친다(렌더 폭과 일치해야 말줄임 예약 칸이 안 어긋난다).
// 미등록 범위 codepoint(Nerd Fonts v3가 Plane-15 PUA로 옮긴 MDI 등)는 신뢰 불가 OSC 0/2 제목에 와도 1칸 유지.
test "titleDisplayWidth counts only registered maru icon PUA as width 2" {
    // widen=true(카드 보조줄): 등록 아이콘 2칸.
    try std.testing.expectEqual(@as(usize, 2), titleDisplayWidth("\u{F0009}", true)); // octocat(등록)
    try std.testing.expectEqual(@as(usize, 2), titleDisplayWidth("\u{F000A}", true)); // folder(등록)
    try std.testing.expectEqual(@as(usize, 1), titleDisplayWidth("\u{F0050}", true)); // 미등록 범위 — 1칸(registered-only)
    try std.testing.expectEqual(@as(usize, 6), titleDisplayWidth("\u{F0009} abc", true)); // 2 + 공백 + abc(3)
    try std.testing.expectEqual(@as(usize, 3), titleDisplayWidth("abc", true)); // 일반 텍스트 회귀
    // widen=false(탭·OSC·라벨 제목): 등록 아이콘도 1칸 — 터미널 제목이 Nerd Fonts MDI와 겹쳐도 안 어긋남.
    try std.testing.expectEqual(@as(usize, 1), titleDisplayWidth("\u{F0009}", false)); // octocat이지만 1칸
    try std.testing.expectEqual(@as(usize, 5), titleDisplayWidth("\u{F0009} abc", false)); // 1 + 공백 + abc(3)
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
            try std.testing.expectEqual(@as(u16, 17), c.col); // 인라인: tabs_end(2탭*tab_w8=16) + 1 — 마지막 탭(끝 16) 바로 뒤(상단탭 Warp 폴리시)
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
    // cols=5: 우측 패딩 1칸 예약 → 텍스트 폭은 cols-1=4. "abcdefg"는 4칸까지만(말줄임). 와이드 글자는 2칸 전진.
    const titles = [_][]const u8{ "abcdefg", "한A" };
    var draw_list = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]bool{}, 5, .default, null, null, null, .default);
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
        var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]bool{}, 5, .default, null, null, null, .default);
        defer dl.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 4), dl.cells.len);
        try std.testing.expectEqual(title_ellipsis_glyph, dl.cells[3].codepoint); // 마지막 = …(col 3, col 4는 우측 패딩)
        try std.testing.expectEqual(@as(u16, 3), dl.cells[3].col);
        for (dl.cells[0..3]) |c| try std.testing.expect(c.codepoint != title_ellipsis_glyph); // 앞은 글자
    }
    // 텍스트 폭(cols-1=4)에 딱 맞으면 말줄임 없음.
    {
        const titles = [_][]const u8{"abcd"}; // 4칸 = cols-1(우측 패딩 예약 후 가용 폭)
        var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]bool{}, 5, .default, null, null, null, .default);
        defer dl.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 4), dl.cells.len);
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
        var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]bool{}, 10, dim, null, null, 1, bright);
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
    // 호버 슬롯 1 → ✕가 slot 1 이름줄(경로 없으니 single), col cols-2=8에 하나 추가된다.
    var hovered = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]bool{}, 10, .default, 1, null, null, .default);
    defer hovered.deinit(allocator);
    var close_count: usize = 0;
    for (hovered.cells) |c| {
        if (c.codepoint == sidebar_close_glyph) {
            close_count += 1;
            try std.testing.expectEqual(sidebarGlyphRow(1, 0, 1), c.row);
            try std.testing.expectEqual(@as(u16, 8), c.col); // cols(10) - 2
        }
    }
    try std.testing.expectEqual(@as(usize, 1), close_count);

    // close_row=null이면 ✕ 없음.
    var none = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]bool{}, 10, .default, null, null, null, .default);
    defer none.deinit(allocator);
    for (none.cells) |c| try std.testing.expect(c.codepoint != sidebar_close_glyph);

    // 범위 밖 close_row(탭 수 이상)는 무시 — ✕ 없음.
    var oob = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]bool{}, 10, .default, 5, null, null, .default);
    defer oob.deinit(allocator);
    for (oob.cells) |c| try std.testing.expect(c.codepoint != sidebar_close_glyph);
}

// 고정 핀(📌)은 이름줄 **우측 끝**(선두가 아니라)에 그린다 — 선두 칼럼은 동작/활성 마커(·/*) 전용이라 핀이 그걸
// 가리지 않게(사용자 요청). 옛 설계는 이름 prefix("📌 ")로 선두에 박았다.
test "buildSidebarDrawList: pinned row draws the pin at the name line's right edge, not the lead" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{ "alpha", "beta" };
    const pins = [_]bool{ true, false }; // 탭0만 고정
    var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &pins, 12, .default, null, null, null, .default);
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
    var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &pins, 12, .default, 0, null, null, .default); // close_row=0(호버)
    defer dl.deinit(allocator);
    var pin_col: ?u16 = null;
    var close_col: ?u16 = null;
    for (dl.cells) |c| {
        if (c.codepoint == sidebar_pin_glyph) pin_col = c.col;
        if (c.codepoint == sidebar_close_glyph) close_col = c.col;
    }
    try std.testing.expectEqual(@as(u16, 7), pin_col.?); // cols(12) - 5
    try std.testing.expectEqual(@as(u16, 10), close_col.?); // cols(12) - 2
    try std.testing.expect(pin_col.? + 2 <= close_col.?); // 핀(2칸)이 ✕와 안 겹침
}

// 긴 이름은 핀 앞에서 말줄임(…)된다 — 긴 이름이 핀을 덮지 않게(name end_col=pin_col).
test "buildSidebarDrawList: pinned long name is ellipsized before the pin" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{"abcdefghijklmnopqrst"}; // 폭(12)을 넘는 긴 이름
    const pins = [_]bool{true};
    var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &pins, 12, .default, null, null, null, .default);
    defer dl.deinit(allocator);
    var has_ellipsis = false;
    for (dl.cells) |c| {
        if (c.codepoint == title_ellipsis_glyph) has_ellipsis = true;
        // 핀(col 9, cols-3) 외 모든 글자/말줄임 셀은 핀 왼쪽(col<9)에 — 겹침 없음.
        if (c.codepoint != sidebar_pin_glyph) try std.testing.expect(c.col < 9);
    }
    try std.testing.expect(has_ellipsis); // 잘림 표시 존재
}

test "buildSidebarDrawList draws a '+' button row below the tabs when plus_row is set" {
    const allocator = std.testing.allocator;
    const titles = [_][]const u8{ "sh", "vim" }; // 탭 2개 → "+"는 slot 2
    var dl = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]bool{}, 10, .default, null, titles.len, null, .default);
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
    var no_plus = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]bool{}, 10, .default, null, null, null, .default);
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
    const draw_list = try buildSidebarDrawList(allocator, &titles, &[_][]const u8{}, &[_][]const u8{}, &[_][]const u8{}, &[_]u21{}, &[_]bool{}, 10, .default, null, null, null, .default);

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
