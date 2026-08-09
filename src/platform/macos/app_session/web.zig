//! web panel · 인앱 브라우저 — WKWebView surface 수명, 주소창 편집과 캐럿, 내비게이션 상태,
//! web term 생성/입양, 링크 열기, web find.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F11).
//! F 시리즈(F1~F10)는 이름 기준으로 그룹이 잡히는 도메인을 전부 소진했고, 여기서부터는 **그룹이 없던
//! 나머지 도메인**을 같은 방식으로 정리한다.
//!
//! 53개 중 **21개를 Swift 호스트가 직접 부른다** — WKWebView는 호스트가 소유하고 Zig는 그 surface의
//! 수명과 입력 라우팅을 관리하는 쪽이라 그렇다. 그 21개는 `app_session.zig`에 얇은 facade로 남는다.
//!
//! 대신 **pub화가 2개뿐**이다(F 시리즈 최저). web 상태가 자기 필드 안에서 닫혀 있고 그룹 밖 헬퍼를
//! 거의 부르지 않기 때문이다 — F9 settings(+60)와 정반대다.
//!
//! 주소창(`addr*`)을 여기 둔 이유: 주소창은 web surface의 URL을 편집하는 UI이고 `web_panel_prev`·
//! `addr_nav_*` 상태를 공유한다. IME preedit(`addrEditPreedit`)도 주소창 입력이라 여기 속한다 —
//! 터미널 IME(`preedit.zig`)와는 다른 경로다.
//!
//! `takeWebNavAction`은 여기 없다 — **익명 struct를 반환**하므로 허브에 facade를 두면 `AppSession`이
//! 만든 타입과 이 파일이 만든 타입이 서로 다른 타입이 되어 컴파일이 깨진다. 이름 있는 타입으로 바꾸면
//! 옮길 수 있지만 그건 이 PR의 범위(순수 이동) 밖이라 허브에 남긴다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const input_ops = @import("input.zig");
const dock_layout = app_session_mod.dock_layout;
const nav_button_w = app_session_mod.nav_button_w;
const addr_nav_url_cap = app_session_mod.addr_nav_url_cap;
const config_mod = app_session_mod.config_mod;
const dock_ops = @import("dock.zig");
const layout_math = app_session_mod.layout_math;
const nav_button_count = app_session_mod.nav_button_count;
const CloseScope = app_session_mod.CloseScope;
const NavButton = app_session_mod.NavButton;
const PaneBar = AppSession.PaneBar;
const Term = app_session_mod.Term;
const WebAppActionSource = AppSession.WebAppActionSource;
const WebFindRequest = AppSession.WebFindRequest;
const WebNavState = app_session_mod.WebNavState;
const WebNavigateRequest = AppSession.WebNavigateRequest;
const WebSurfaceTransition = app_session_mod.WebSurfaceTransition;
const addr_word_separators = AppSession.addr_word_separators;
const file_panel_bridge = app_session_mod.file_panel_bridge;
const file_panel_ops = @import("file_panel.zig");
const pane_ops = @import("pane.zig");
const tab_ops = @import("tab.zig");
const terminal = app_session_mod.terminal;
const web_panel_layout = app_session_mod.web_panel_layout;
const workspace_ops = @import("workspace.zig");

/// 주소창 편집 밴드(탭 바 바로 아래)가 포인트를 포함하는가 — mouse-down 클릭-어웨이(cancelAddrEdit)가 "자기 밴드
/// 재클릭(caret 재배치·nav 버튼)"만 살리게 판정한다(그 외 클릭이면 false → 편집 취소). 편집 아님/밴드 없음이면 false.
pub fn addrEditBandContainsPoint(self: *AppSession, x_px: f64, y_px: f64) bool {
    const pb = pane_ops.addrEditPaneBar(self) orelse return false;
    const bar_h = pb.full.h; // 밴드 높이 = 탭 바 높이(렌더 "1c"·클릭 ①b와 동일 소스)
    const band: maru.session.SplitRect = .{ .x = pb.full.x, .y = pb.full.y + bar_h, .w = pb.full.w, .h = bar_h };
    return layout_math.pointInRect(x_px, y_px, band);
}

/// 주소창 편집 caret의 셀 rect(backing px, 좌상단 원점) — IME 후보창 위치(imeCursorRect .addr_edit)에 쓴다. 렌더 "1c"
/// 와 같은 셈법: 밴드 y(full.y+bar_h) + text pad_y, caret_col은 fieldLayout(렌더 emitEditBand 단일 소스, mid-string
/// caret·가로 스크롤·ellipsis 반영). 극단적으로 좁은 밴드(cols≤nav_end로 text_area==0=스크롤 없음)면 fieldLayout이
/// caret_col을 하한만 클램프해 cols를 넘을 수 있으므로 **cols-1로 상한 클램프**(후보창이 밴드 밖에 뜨는 것 방지). 편집
/// surface가 활성 탭인 leaf를 못 찾거나 cell 미상이면 null(imeCursorRect가 본문 origin으로 폴백).
pub fn addrEditCaretRect(self: *AppSession) ?chrome.draw.Rect {
    const cw = self.cell_width_px;
    const ch = self.cell_height_px;
    if (cw == 0 or ch == 0) return null;
    const pb = pane_ops.addrEditPaneBar(self) orelse return null;
    const cols: u32 = pb.full.w / cw;
    if (cols == 0) return null;
    const nav_end: u32 = @as(u32, nav_button_count) * nav_button_w; // 버튼 존 [0, nav_end)(navButtonAt·렌더 단일 소스)
    // caret 열 = fieldLayout(렌더 emitEditBand와 **같은 단일 소스**) — mid-string caret·가로 스크롤·ellipsis 반영.
    const lay = chrome.components.text_field.fieldLayout(self.addr_field.view(), .{ .cols = @intCast(cols), .nav_end = @intCast(nav_end) });
    const caret_col: u32 = @min(lay.caret_col, cols -| 1); // 밴드 밖(cols 초과)이면 우경계로 상한 클램프
    const bar_h = pb.full.h;
    const text_origin_y = pb.full.y + bar_h + self.chromeBarTextOffsetY(bar_h); // 렌더 band_text_origin_y와 동일(밴드 높이 = bar_h)
    return .{
        .x = @intCast(pb.full.x + caret_col * cw),
        .y = @intCast(text_origin_y),
        .w = @intCast(cw),
        .h = @intCast(ch),
    };
}

/// 이 세션 트리(모든 탭·pane)에 그 web surface_id를 가진 web Term이 존재하는지. 창 간 이동 재부모화(4e-4·web-panel §10)
/// 판정용 — Swift가 원본 창 web surface destroy 전이 시 "이 surface가 **다른 창** 세션에 아직 live인가"로 이동↔닫기를
/// 구분한다(live=이동→WKWebView 재부모화·`browser.closed` 억제, 부재=진짜 닫힘→파괴). 순수 트리 조회(할당 없음).
pub fn hasWebSurface(self: *AppSession, surface_id: u64) bool {
    if (self.findTermWhere(surface_id, struct {
        fn pred(id: u64, term: *Term) bool {
            return term.kind == .web and term.surfaceId() == id;
        }
    }.pred) != null) return true;
    if (!self.dock_initialized) return false;
    var entry_it = file_panel_ops.fileEntries(self);
    while (entry_it.next()) |entry| if (entry.surface_id == surface_id) return true;
    return false;
}

/// Phase 7f-0: 팝업(`WKUIDelegate.createWebViewWith`) adopt용 — Swift가 WebKit이 넘긴 config로 **이미 만든**
/// WKWebView를 붙일 browser web Term을 활성 pane에 새 탭으로 만들고 그 surface_id를 돌려준다(Swift-first 동기 생성).
/// `newWebTermInActivePane` 미러이되 (1) 팝업은 임의 외부 콘텐츠라 **항상 browser(비신뢰)** 이고 (2) surface_id를
/// 반환해 Swift가 pre-created webview를 `webPanels[surface_id]`에 키잉하게 한다(소유·시점 역전: 평소 Zig-first lazy
/// 생성과 반대). create 전이는 평소대로 emit되며, Swift drain이 `webPanels[surface_id]` 존재 시 중복 WKWebView 생성을
/// 스킵한다(7f-1) — 이 함수는 term/트리만 만든다. 실패는 호출처(ABI)가 0(sentinel)으로 접는다.
pub fn createAdoptedWebTermInActivePane(self: *AppSession) !u64 {
    const pane = pane_ops.activePane(self);
    const term = try createWebTerm(self, .browser); // 팝업 = untrusted browser 고정(§7 격리)
    errdefer self.destroyTerm(term); // append 실패 시 방금 만든 term 롤백(newWebTermInActivePane과 동형)
    try pane.terms.append(self.allocator, term);
    self.focusTerm(pane.terms.items.len - 1); // 새 탭으로 포커스(사용자가 연 새 창 = 활성)
    self.metal_dirty = true;
    return term.surfaceId();
}

/// 4e-1: 한 **web Term**(WKWebView 패널의 first-class surface)을 heap-pin(`create`)으로 만든다 — registry가
/// LiveSurface **union web arm** 슬롯을 소유하고, 그 arm의 sentinel `Surface`(빈 core — 4e-1은 렌더/PTY 없음)를
/// 제자리 init한다. terminal `createTerm`과 대칭이되 **PTY spawn·attachSurface·pump가 없다**(web-panel.md §6). surface_id는
/// 앱 전역 `SurfaceIdAllocator` 발급(비재사용) — sentinel surface의 `id`에 실려 `Term.surface.id`가 web에서도 유효하다
/// (surface_ptrs·activeSurface 계약 불변). `kind`·`web_panel_kind`는 모델 Term에 저장(라벨·후속 trust 단일 출처).
/// Pane에 거는 건 호출자(maybeDebugOpenWebPanel·후속 command)가 한다. teardown은 `destroyTerm`이 kind로 분기.
pub fn createWebTerm(self: *AppSession, panel_kind: web_panel_layout.PanelKind) !*Term {
    const term = try self.allocator.create(Term);
    errdefer self.allocator.destroy(term);
    term.* = .{ .kind = .web, .web_panel_kind = panel_kind };

    const id = self.surface_ids.next(); // 앱 전역 발급(비재사용) — terminal과 같은 네임스페이스, 유일
    const slot = try self.live_registry.create(id, 0);
    // union web arm 확정 후 sentinel surface를 제자리 init. init 실패 시 슬롯은 아직 uninit이라(surface undefined)
    // removeUninitialized로 deinit 없이 슬롯만 해제한다(remove=web arm deinit은 surface inited 가정이라 못 씀).
    slot.* = .{ .web = .{ .internal_allocator = self.allocator } };
    term.surface = &slot.web.surface;
    errdefer self.live_registry.removeUninitialized(id) catch {};
    // sentinel: 최소 1×1 grid(빈 core, clampGridSize가 최소 보장). 렌더/PTY 없이 id·title만 실어 Term.surface를 유효화.
    term.surface.* = try maru.session.Surface.init(self.allocator, id, .{ .cols = 1, .rows = 1 });
    // web Term은 PTY/pump/attach 없음 — rt는 기본값(live_pty=undefined, live_initialized=false). destroyTerm이 kind로 가드.
    return term;
}

// 닫힐 scope에 browser web term이 있나 — 브라우저 탭 닫기는 실행 중 셸 명령이 없어도(web term=live_initialized=false라
// termHasRunningJob=false) "닫을까요?" 확인을 띄운다(제보). running job과 병렬 게이트. markdown web term은 제외(browser만).
pub fn termIsWebBrowser(term: *Term) bool {
    return isBrowserTerm(term); // 판정은 isBrowserTerm 단일 출처(중복 정의 제거)
}

pub fn sessionHasWebBrowser(self: *AppSession) bool {
    for (self.tabs.items) |t| if (tab_ops.tabHasWebBrowser(t)) return true;
    return false;
}

pub fn scopeHasWebBrowser(self: *AppSession, scope: CloseScope) bool {
    return switch (scope) {
        .none => false,
        .term => termIsWebBrowser(pane_ops.activePane(self).activeTerm()),
        .pane => pane_ops.paneHasWebBrowser(pane_ops.activePane(self)),
        .tab => |idx| tab_ops.tabHasWebBrowser(self.tabs.items[idx]),
        .session => sessionHasWebBrowser(self),
    };
}

/// 4e-1 시각/모델 확인 디버그 훅 — MARU_WEB_PANEL=1 env가 설정됐고 surface가 준비됐으면 활성 pane에 web **Term**
/// 하나를 만들어 append한다(한 번만). 4c는 이 훅이 활성 pane 본문에 오버레이 WKWebView(app_session.web_panel)를
/// 붙였으나, 4e-1은 §6대로 web surface를 **트리의 Term**으로 만든다(4e-2/3 fixture용 — 4e-5서 command 승격). env
/// 미설정이면 무동작(표준 macos-app-smoke는 env 미설정이라 이 훅 무동작 = 터미널 빌드 byte-identical). MARU_WEB_PANEL_MARKDOWN=1이면
/// markdown, 아니면 browser로 kind를 정한다(라벨·후속 trust 파생).
///
/// **[4e-2] 활성 탭으로 전환**: append 후 `focusTerm`으로 web Term을 활성화한다 — 4e-2가 활성 render 경로를
/// activeTermIsTerminal/activeTerminalSurface로 gate했으므로 활성 web은 sentinel core를 만지지 않고 본문 blank·
/// 크래시 0이다(§6). **[4e-3] WKWebView 부착**: computeWebSurfaceTransitions가 이 web Term을 walk해 create 전이를
/// 내면 Swift가 자기 pane 본문 rect에 인라인 흰 HTML WKWebView를 붙인다(about:blank는 다크 모드서 다크로 렌더돼 명시 흰 배경 사용; 그전엔 theme 배경으로 비어 보였다).
pub fn maybeDebugOpenWebPanel(self: *AppSession) void {
    if (self.debug_web_term_opened) return;
    if (!self.surface_initialized) return;
    if (std.c.getenv("MARU_WEB_PANEL") == null) return;
    const kind: web_panel_layout.PanelKind = if (std.c.getenv("MARU_WEB_PANEL_MARKDOWN") != null) .markdown else .browser;
    // web Term 생성의 create→append→focus 시퀀스(+append 실패 errdefer 롤백)는 newWebTermInActivePane 단일
    // 출처에 위임한다. 실패면 debug 플래그를 안 세워 다음 tick 재시도한다(pane은 errdefer로 불변).
    pane_ops.newWebTermInActivePane(self, kind) catch return;
    self.debug_web_term_opened = true;
}

/// backing px·좌상단 rect를 pt·좌하단(WKWebView frame·컨테이너 좌표)으로 변환한다(4a 순수 함수 소비). 컨테이너
/// content view의 backing 높이(backing_height_px)를 y-flip 기준으로 쓴다(§3 — OS 타이틀바 포함 전체 창이 아니라
/// pane rect가 사는 그 좌표 공간의 높이).
pub fn webFramePt(self: *const AppSession, rect_px: maru.session.SplitRect) web_panel_layout.RectPt {
    return web_panel_layout.pxTopLeftToPtBottomLeft(rect_px, self.backing_height_px, self.scale_milli);
}

pub fn webSurfacesPresent(self: *AppSession) bool {
    return workspace_ops.windowHasWebTerm(self) or file_panel_ops.dockHasLiveSurface(self);
}

/// Phase 4e-3: 활성 워크스페이스 탭의 pane 트리를 walk해 이번 tick의 web Term 집합(cur)을 만든다(§6). 각 web Term은
/// **자기 pane leaf rect**에서 탭 바(top inset)를 뺀 본문 rect(4a `contentRect`, §5 탭 바 노출)에 고정되고, visible은
/// **자기 pane의 활성 Term인가**다(4c의 활성 pane 추종을 완전 제거 — 각 웹뷰가 제 pane에 붙박인다). **비활성 워크스페이스 탭의 web Term도
/// 집합에 남는다** — zero rect + `visible=false`로(FP16c, 아래 두 번째 루프). 집합에서 빠지면 surfaceDiff가
/// destroyed를 내고 Swift가 WKWebView를 파괴해 미저장 CM6 버퍼가 사라지기 때문이다(docs/file-panel.md §4).
/// OOM/미초기화면 error(호출자가 prev 불변 유지).
pub fn collectWebSurfaces(self: *AppSession, out: *std.ArrayList(web_panel_layout.SurfaceLayout)) !void {
    if (self.surface_initialized and self.tabs.items.len > 0) {
        self.web_leaf_rects_scratch.clearRetainingCapacity(); // 영속 scratch 재사용(hot path 재할당 회피, layout이 append만 함)
        try tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &self.web_leaf_rects_scratch);
        const bar_h = pane_ops.paneBarHeightPx(self);
        const dt = pane_ops.dividerThicknessPx(self);
        // seam inset: WKWebView는 native NSView라 자기 frame 안 클릭을 **삼킨다**(터미널처럼 mouse handler가
        // dividerAtPoint를 먼저 가로챌 수 없다) → 형제 pane과 맞닿는 seam 가장자리서 divider를 **물리적으로 노출**해야
        // 마우스가 seam에 닿아 드래그 리사이즈된다(web-panel.md §5). 이전 `dt/2`는 기본 dt=1px에서 **0**이라 아무 효과
        // 없었다(세로·가로 divider가 안 잡히던 회귀 — [4e review 0] 재수정). `divider.hitTest` 허용폭
        // (chrome/components/divider.zig: cell/2+2)이 넉넉해 divider 선 밖 아주 작은 밴드만 있으면 보이는 선을 겨냥해
        // 잡히므로, gap을 **최소화**한다 — divider 선(dt) + 1pt 클릭 여유(scale 인지)만 들인다(사용자 요청: 공백 최대 축소).
        // dt==0(divider 숨김)이면 seam=0(무-inset, 웹뷰가 seam까지 채움).
        const seam: u32 = if (dt == 0) 0 else dt + @max(@as(u32, 1), self.scale_milli / 1000);
        const tr = self.termRect();
        const dg = dock_ops.dockGeometry(self);
        for (self.web_leaf_rects_scratch.items) |lr| {
            for (lr.leaf.terms.items, 0..) |term, i| {
                if (term.kind != .web) continue; // terminal Term은 WKWebView 없음(Metal 렌더).
                // 각 leaf 가장자리가 바깥 경계(termRect)가 아니면 형제 pane과 맞닿는 **seam** → seam만큼 본문 rect를 들여
                // WKWebView가 분할선을 덮지 않게 한다(작은 시각 gap). top seam은 탭 바(bar_h ≫ seam)가 이미 덮으므로 불요.
                // seam_edges 비트마스크(L=1·R=2·B=4)를 함께 실어 Swift가 그 가장자리 근처 클릭/hover를 통과시키게 한다
                // (넓은 grab 폭 — 시각 gap과 분리). left/right는 x축, bottom은 top-left px 기준 아래(y 큰 쪽).
                // **`seam > 0`으로 게이트**: divider 숨김(split.divider-thickness=0 → seam=0)이면 잡을 divider가 없어
                // inset도 seam_edges도 0으로 둔다 — 안 그러면 Swift hitTest가 잡을 것 없는 가장자리서 클릭을 헛통과한다
                // (10차 review 기각 항목이나 정합상 게이트). seam==0이라 inset.left=seam이 0이어도 비트는 안 세운다.
                // 7e-1b: browser(비신뢰) 웹 패널은 탭 바 바로 아래에 읽기전용 주소창 밴드(현재 URL)를 두므로 top inset을
                // bar_h + addr_h로 늘려 WKWebView 본문을 그만큼 더 내린다 → 밴드 영역이 웹뷰에서 비워지고, 탭 바 collect
                // 루프가 그 밴드에 배경 quad + URL 셀을 그린다(밴드 y = [bar_h, bar_h+addr_h]가 웹뷰 top과 정확히 abut).
                // addr_h는 탭 바 높이(paneBarHeightPx) 재사용 — 단일 소스, 별도 상수 없음. markdown web Term은 주소창이
                // 없어 top=bar_h 유지(byte-identical). bar_h==0(chrome_minimal)이면 addr_h도 0이라 밴드 없음(탭 바와 동조).
                // FP16d: 파일 Term도 탭 바 아래 헤더 밴드(breadcrumb + 모드 선택기)를 갖는다 — browser의
                // 주소창 밴드와 **같은 경로**로 top inset을 한 줄 더 내린다(§3.1).
                const addr_h: u32 = if (isBrowserTerm(term) or term.file_entry != null) bar_h else 0;
                var inset: web_panel_layout.ChromeInset = .{ .top = bar_h + addr_h };
                var seam_edges: u8 = 0;
                if (seam > 0 and lr.rect.x > tr.x) {
                    inset.left = seam; // 왼쪽에 형제 pane(세로 divider)
                    seam_edges |= 1;
                }
                const at_right_dock = dock_ops.dockVisible(self) and self.dock.side == .right and
                    lr.rect.x + lr.rect.w == tr.x + tr.w and dg.divider.w > 0;
                if (seam > 0 and (lr.rect.x + lr.rect.w < tr.x + tr.w or at_right_dock)) {
                    inset.right = seam; // 오른쪽 세로 divider
                    seam_edges |= 2;
                }
                const at_bottom_dock = dock_ops.dockVisible(self) and self.dock.side == .bottom and
                    lr.rect.y + lr.rect.h == tr.y + tr.h and dg.divider.h > 0;
                if (seam > 0 and (lr.rect.y + lr.rect.h < tr.y + tr.h or at_bottom_dock)) {
                    inset.bottom = seam; // 아래 가로 divider
                    seam_edges |= 4;
                }
                const content_rect = layout_math.insetRect(web_panel_layout.contentRect(lr.rect, inset), self.window_padding_px);
                var grab_bands: web_panel_layout.DividerGrabBandsPt = .{};
                if ((seam_edges & 1) != 0) {
                    grab_bands.left = pane_ops.dividerBandPt(self, content_rect, pane_ops.paneDividerTarget(self, lr.rect, .left), .left);
                }
                if ((seam_edges & 2) != 0) {
                    const target = if (at_right_dock)
                        pane_ops.dividerTargetRect(dock_layout.outerDividerHitRect(dg, .right, pane_ops.dockDividerGrabBandPx(self)))
                    else
                        pane_ops.paneDividerTarget(self, lr.rect, .right);
                    grab_bands.right = pane_ops.dividerBandPt(self, content_rect, target, .right);
                }
                if ((seam_edges & 4) != 0) {
                    const target = if (at_bottom_dock)
                        pane_ops.dividerTargetRect(dock_layout.outerDividerHitRect(dg, .bottom, pane_ops.dockDividerGrabBandPx(self)))
                    else
                        pane_ops.paneDividerTarget(self, lr.rect, .bottom);
                    grab_bands.bottom = pane_ops.dividerBandPt(self, content_rect, target, .bottom);
                }
                try out.append(self.allocator, .{
                    .surface_id = term.surfaceId(),
                    .panel_kind = term.web_panel_kind,
                    .seam_edges = seam_edges,
                    .divider_grab_bands_pt = grab_bands,
                    .content_rect = content_rect,
                    // AppKit은 mouse-down을 받은 Metal view에 drag/up을 계속 전달한다. 따라서 도크 resize 중에도
                    // WKWebView를 숨길 필요 없이 surfaceDiff의 reframe으로 라이브 추종할 수 있다.
                    .visible = i == lr.leaf.active_term,
                });
            }
        }
    }

    // FP16c: 비활성 워크스페이스(탭)의 web Term도 집합에 남긴다 — zero rect + hidden. 집합에서 빠지면
    // surfaceDiff가 destroyed를 내고 Swift가 WKWebView를 파괴해 **미저장 CM6 버퍼가 사라진다**. 도크 분기가
    // 이미 쓰던 "존재는 유지, 가시성만 끔" 패턴을 워크스페이스 경로로 옮긴 것이다(§4). 적용 범위는 파일뿐
    // 아니라 web Term 전체라, 브라우저가 전환 뒤 흰 페이지가 되던 결함도 함께 사라진다.
    if (self.surface_initialized) {
        for (self.tabs.items, 0..) |tab, ti| {
            if (ti == self.app_window.active_tab) continue;
            for (tab.panes.items) |pane| {
                for (pane.terms.items) |term| {
                    if (term.kind != .web) continue;
                    try out.append(self.allocator, .{
                        .surface_id = term.surfaceId(),
                        .panel_kind = term.web_panel_kind,
                        .seam_edges = 0,
                        .divider_grab_bands_pt = .{},
                        .content_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
                        .visible = false,
                    });
                }
            }
        }
    }

    // FP16: 도크는 **탐색기 전용**이라 WKWebView를 하나도 소유하지 않는다(트리는 전부 GPU 셀 chrome).
    // 파일 surface는 위 pane walk가 낸다 — 옛 도크 분기와 그에 딸린 도크-aware destroy/presence 예외는 삭제했다.

    // Phase 7e-1a: 이번 tick 활성 탭 web surface 집합(out)에 없는 nav 상태 키를 제거한다 — surface 닫힘/이동/비활성
    // 탭 이동 시 소유 url 메모리가 세션 끝까지 새지 않게(id는 앱 전역 비재사용이라 stale 오인은 없으나 소유 자원은
    // 즉시 회수). 흔한 경우 stale 0이라 바깥 while은 1회(스캔서 못 찾으면 break). fetchRemove로 iterator 무효화 없이
    // 한 건씩 지운다(스캔→break→제거→재스캔). web surface·nav 상태 수는 소수라 O(n·m) 비용 무해.
    while (self.web_nav_states.count() > 0) {
        var stale: ?u64 = null;
        var it = self.web_nav_states.keyIterator();
        scan: while (it.next()) |key_ptr| {
            const sid = key_ptr.*;
            for (out.items) |s| {
                if (s.surface_id == sid) continue :scan; // 이번 tick 존재 → 유지
            }
            stale = sid; // out에 없음 → 제거 대상
            break :scan;
        }
        const sid = stale orelse break;
        if (self.web_nav_states.fetchRemove(sid)) |kv| self.allocator.free(kv.value.url);
    }
}

/// Phase 7e-1a: browser 웹 패널의 WKWebView nav 상태를 per-surface로 upsert한다(Swift KVO → set_web_nav_state ABI).
/// 기존 엔트리가 있으면 옛 url을 free하고 새 url을 dup해 교체한다. url dup 또는 맵 성장이 OOM이면 조용히 무시한다
/// (nav 상태는 best-effort 표시용 — 실패해도 옛 상태 유지, 크래시 없음). 저장·정책은 Zig 단일 출처.
pub fn setWebNavState(self: *AppSession, surface_id: u64, can_go_back: bool, can_go_forward: bool, url: []const u8) void {
    const dup = self.allocator.dupe(u8, url) catch return; // OOM: 상태 미갱신(조용히 무시)
    const gop = self.web_nav_states.getOrPut(self.allocator, surface_id) catch {
        self.allocator.free(dup); // 맵 성장 OOM: dup 회수 후 미갱신
        return;
    };
    if (gop.found_existing) {
        // 값이 실제로 바뀐 tick에만 재렌더 요청 — 주소창 밴드(url)·nav 버튼 활성색(can_go_*)이 이 상태를 소비하므로,
        // 링크 이동으로 URL/히스토리가 바뀌면 metal_dirty를 세워야 주소창이 갱신된다("이동해도 주소 안 바뀜" 수정).
        // KVO push는 navStateDirty로 throttle돼 핫루프는 아니지만, 무변화 push(같은 값 재관측)는 재렌더 안 한다.
        const changed = gop.value_ptr.can_go_back != can_go_back or
            gop.value_ptr.can_go_forward != can_go_forward or
            !std.mem.eql(u8, gop.value_ptr.url, url);
        self.allocator.free(gop.value_ptr.url); // 옛 url 해제 후 교체
        if (changed) self.metal_dirty = true;
    } else {
        self.metal_dirty = true; // 새 상태 = 첫 주소 표시 → 재렌더
    }
    gop.value_ptr.* = .{ .can_go_back = can_go_back, .can_go_forward = can_go_forward, .url = dup };
}

/// Phase 7e-1a: surface_id의 저장된 nav 상태(없으면 null). 반환 url 슬라이스는 맵 소유로 다음 mutation까지 유효
/// (ABI getter가 즉시 out 버퍼로 복사). 7e-1b 주소창 소비.
pub fn webNavState(self: *AppSession, surface_id: u64) ?WebNavState {
    return self.web_nav_states.get(surface_id);
}

/// Phase 7e-4 후속: 활성 pane의 활성 term이 browser web이면 그 surface_id, 아니면 0. browser nav 단축키
/// (⌘←/→/R)를 **키보드 포커스(WKWebView firstResponder) 유무와 무관하게** "지금 활성 탭이 browser면" 동작하게
/// 게이트하는 데 쓴다(탭만 열어 보기만 해도 되게 — 브라우저 탭 활성화 시 webView에 자동 포커스를 안 주므로
/// isWebPanelFocused만으론 놓친다). split의 비활성 pane 브라우저는 활성 pane이 아니라 0을 반환해 걸러진다.
/// 0은 유효 surface_id가 아니므로(1부터 발급) sentinel로 안전.
pub fn activeWebSurfaceId(self: *AppSession) u64 {
    const term = pane_ops.activePane(self).activeTerm();
    return if (isBrowserTerm(term)) term.surfaceId() else 0;
}

pub fn isBrowserTerm(term: *const Term) bool {
    // **파일 entry 제외가 여기 있다**(FP16 §8). `.html`/`.pdf` 파일 Term은 격리 config를 쓰려고
    // `web_panel_kind == .browser`를 갖게 되는데, 그렇다고 browser 기능(주소창 밴드·nav 단축키·URL 편집·
    // 터미널 링크 착지)이 걸리면 로컬 HTML 파일 뷰가 브라우저처럼 동작한다. PR #1638이 판정 8곳을 이 함수
    // 하나로 모아 둔 목적이 정확히 이 한 줄을 한 곳에만 넣기 위해서였다.
    return term.kind == .web and term.file_entry == null and term.web_panel_kind == .browser;
}

/// 지금 **화면에 보이는** browser 패널의 surface_id(없으면 0). 각 pane의 **활성 Term만** 본다 — 숨은 Term 탭의
/// 브라우저에 링크를 띄우면 화면이 그대로라 "아무 일도 안 일어난 것"처럼 보인다. 활성 pane의 browser를 먼저
/// 고른다(브라우저를 보다가 옆 터미널 링크를 누르는 흐름이 가장 흔하다). 여럿이면 이 순서의 첫 번째.
pub fn visibleBrowserSurfaceId(self: *AppSession) u64 {
    const active = activeWebSurfaceId(self);
    if (active != 0) return active;
    for (tab_ops.activeTab(self).panes.items) |pane| {
        const term = pane.activeTerm();
        if (isBrowserTerm(term)) return term.surfaceId();
    }
    return 0;
}

/// 터미널 화면에서 (수식키)+클릭한 **웹 링크(http/https)** 를 `input.link-open-target` 정책대로 연다.
/// 인앱(browser 패널)으로 열기로 정했으면 pending action을 세우고 `true`, 시스템 브라우저로 보내야 하면
/// `false`를 돌려준다(호출처인 Swift `handleUrlClick`이 `NSWorkspace.open`으로 그 자리에서 연다).
///
/// 규칙(docs/link-detection.md §링크를 어디에 여는가):
///  1. `system`이면 false(이전 동작 그대로).
///  2. http/https 리터럴이 아니면 false — 파일 경로·`mailto:`·`ssh://`는 브라우저 패널에 실을 대상이 아니다.
///     검증기는 파일 패널 외부 링크와 **같은** `isExplicitHttpLink`를 공유한다(허용 스킴 판정 단일 출처).
///  3. 보이는 browser 패널이 있으면 그 패널에 띄운다(auto·in-app 공통).
///  4. 없을 때: `auto`(기본)는 false(시스템) — 링크 하나로 탭이 늘어나는 놀람을 피한다. `in-app`은 **새 browser
///     Term을 열어** 그곳에 띄운다(파일 패널 `in-app`과 같은 `appendWebTermInActivePane`).
///
/// **왜 즉시 반환이 아니라 pending인가**: 새로 만든 browser Term의 WKWebView는 **다음 tick의 surface 전이
/// batch**에서 생성된다. 클릭 시점에 surface_id를 돌려줘도 Swift `webPanels`에는 아직 없어 load가 유실된다.
/// 그래서 파일 패널 외부 링크와 **같은 pending 경로**(`takeExternalLinkAction`)를 쓴다 — Swift가 매 tick 전이
/// batch를 적용한 **뒤** drain하므로 "생성 → navigate" 순서가 구조적으로 보장된다. 기존 패널 재사용도 같은
/// 경로로 보내 분기를 하나로 유지한다(한 tick 지연은 최대 ~16ms).
pub fn openTerminalWebLink(self: *AppSession, url: []const u8) bool {
    const target = self.loaded_config.config.input.link_open_target;
    if (target == .system) return false;
    if (!file_panel_bridge.isExplicitHttpLink(url)) return false;
    // **호출 계약**: `urlAt`이 비어 있지 않은 URL을 돌려준 뒤에만 불린다(Swift handleUrlClick). 그 경로가 이미
    // surface_initialized와 활성 탭 존재를 통과했으므로 여기서 다시 방어하지 않는다(프로젝트 규칙 "헛방어 금지").
    const visible = visibleBrowserSurfaceId(self);
    const surface_id = if (visible != 0) visible else switch (target) {
        .auto => return false, // 보이는 패널이 없으면 시스템 — auto는 탭을 새로 만들지 않는다
        // in-app: 없으면 새로 연다. 실패(OOM 등)는 링크를 삼키는 대신 시스템 브라우저로 폴백한다.
        .in_app => pane_ops.appendWebTermInActivePane(self, .browser) catch return false,
        .system => unreachable, // 위에서 이미 걸렀다
    };
    // 직전 요청이 아직 drain되지 않았으면(같은 tick 안 연타) 이번 클릭은 시스템으로 보낸다 — URL을 덮어써
    // 앞 요청을 잃거나 목적지 없는 빈 탭을 남기지 않는다(파일 패널 LinkBusy와 같은 규율이되, 터미널 클릭은
    // 조용히 무시하는 것보다 시스템에서라도 열어 주는 편이 낫다).
    self.queueExternalLinkAction(url, surface_id) catch return false;
    return true;
}

/// Phase 4g-0: 활성 pane의 활성 term이 **web term(browser·markdown 무관)** 이면 그 surface_id, 아니면 0. focus-sync
/// 불변식(§4.1)의 Direction 1이 "활성 pane이 web이면 그 webview를 firstResponder로" 하려고 쓴다 —
/// `activeWebSurfaceId`(browser 전용)와 달리 **markdown web term도 포함**한다(둘 다 WKWebView라 포커스 대상).
/// Swift가 surface_id→webPanels로 webview를 조회한다. terminal 활성이면 0(→터미널 뷰 포커스). 0=유효 id 아님(1부터).
pub fn activeWebSurfaceIdAnyKind(self: *AppSession) u64 {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind == .web) return term.surfaceId();
    return 0;
}

/// Phase 7e-3/7e-4: browser 주소창 nav 버튼(back/forward/reload)을 눌러(밴드 클릭 ①b 또는 키보드 단축키 ABI) 이
/// surface의 nav action을 세운다 — **활성 버튼일 때만**(back=can_go_back·forward=can_go_forward·reload=항상). 활성이면
/// 1회성 pending(surface_id + code 0=back·1=forward·2=reload)을 세우고 metal_dirty. Swift가 매 tick takeWebNavAction으로
/// drain해 BrowserControl.goBack/goForward/reload를 실행한다. 클릭(①b)과 키보드(ABI browser_nav)가 이 단일 정책을
/// 공유해 "보이는 활성 == 실행되는 액션"이 두 경로에서 동일하다(활성 판정 중복 제거).
pub fn setBrowserNavAction(self: *AppSession, surface_id: u64, btn: NavButton) void {
    const nav_state = webNavState(self, surface_id);
    const active = switch (btn) {
        .back => if (nav_state) |st| st.can_go_back else false,
        .forward => if (nav_state) |st| st.can_go_forward else false,
        .reload => true, // reload = 항상 활성
    };
    if (!active) return; // 비활성 버튼은 no-op(클릭은 소비하되 pending 안 세움 — 호출처가 소비)
    self.web_nav_action_pending = surface_id;
    self.web_nav_action_code = switch (btn) {
        .back => 0,
        .forward => 1,
        .reload => 2,
    };
    self.metal_dirty = true;
}

/// 편집 진입(밴드 클릭). 현재 URL을 초기 버퍼로 시드(UTF-8 경계 절단) + focus-pull pending 세움(키 포커스를 WKWebView
/// 에서 뺏어 타이핑이 주소창으로 오게 — 7e-2b Swift가 실행). 이미 편집 중이면 대상을 교체한다(한 번에 하나).
pub fn enterAddrEdit(self: *AppSession, surface_id: u64, current_url: []const u8) void {
    self.addr_field.setText(self.allocator, current_url) catch self.addr_field.clear(); // 현재 URL 시드(caret=끝)·OOM이면 빈 편집
    self.addr_edit = surface_id;
    self.addr_focus_pull_pending = surface_id;
}

/// 편집 대상 surface_id(없으면 null) — 렌더/라우팅이 편집 활성 판정에 쓴다(파일 내부 전용, ABI export는
/// terminal_owns_input으로 대체돼 더는 pub 아님).
pub fn addrEditSurfaceId(self: *const AppSession) ?u64 {
    return self.addr_edit;
}

/// 현재 편집 확정 텍스트(TextField text, 없으면 빈). 렌더가 URL 대신 이걸(+preedit) 그린다.
pub fn addrEditText(self: *const AppSession) []const u8 {
    return self.addr_field.text.items;
}

/// IME 조합 중(preedit) 텍스트 — 렌더가 caret 위치에 겹쳐 조합 중 글자를 보인다(fieldLayout run).
pub fn addrEditPreedit(self: *const AppSession) []const u8 {
    return self.addr_field.preedit.items;
}

pub fn addrEditAppend(self: *AppSession, cp: u21) void {
    if (self.addr_edit == null) return;
    self.addr_field.insertCp(self.allocator, cp) catch {}; // caret에 삽입(선택 있으면 대체) — 동적 버퍼, OOM이면 무시
}

pub fn addrEditBackspace(self: *AppSession) void {
    if (self.addr_edit == null) return;
    self.addr_field.deleteBackward(); // caret 앞 그래핌 하나(선택 있으면 선택 삭제)
}

/// 슬라이스 3: 밴드 클릭 x_px → text 바이트 오프셋(fieldLayout 역함수 caretAtColumn — 렌더 emitEditBand와 같은 단일
/// 소스라 그려진 caret == 클릭 caret). 클릭 열은 셀 경계로 반올림(좌반=글자 앞·우반=글자 뒤). 밴드 밖 x는 caretAtColumn이
/// 창 경계로 clamp(드래그가 밴드를 벗어나면 시작/끝 방향으로 확장). cw==0이면 현재 caret 유지.
pub fn addrBandOffsetAt(self: *const AppSession, pb: PaneBar, x_px: f64) usize {
    const cw = self.cell_width_px;
    if (cw == 0) return self.addr_field.caret;
    const cols: u32 = pb.full.w / cw;
    const nav_end: u32 = @as(u32, nav_button_count) * nav_button_w;
    const rel = (x_px - @as(f64, @floatFromInt(pb.full.x))) / @as(f64, @floatFromInt(cw));
    const click_col: i32 = if (rel < 0) 0 else @intFromFloat(@round(rel));
    return chrome.components.text_field.caretAtColumn(self.addr_field.view(), .{ .cols = @intCast(cols), .nav_end = @intCast(nav_end) }, click_col);
}

/// 슬라이스 3: 편집 중 주소창 밴드 마우스 — 드래그 선택(kind 2/3 캡처)·더블클릭 단어(4)·트리플클릭 전체(5). down(1)의
/// caret 배치·드래그 시작은 클릭 핸들러 ①b가 한다(여기선 false 반환). 소비했으면 true(호출자 return). 드래그는 밴드를
/// 벗어나도 addr_dragging으로 캡처를 유지한다(스크롤바 드래그와 동형·포커스 불변식 §5.1). 편집 아니면 밴드 없음 → false.
pub fn addrBandMouse(self: *AppSession, kind: i32, x_px: f64, y_px: f64) bool {
    const pb = pane_ops.addrEditPaneBar(self) orelse return false;
    const cw = self.cell_width_px;
    if (cw == 0) return false;
    const bar_h = pb.full.h;
    const band: maru.session.SplitRect = .{ .x = pb.full.x, .y = pb.full.y + bar_h, .w = pb.full.w, .h = bar_h };
    const nav_end_x: f64 = @floatFromInt(pb.full.x + @as(u32, nav_button_count) * nav_button_w * cw); // URL 존 시작 px(버튼 존 뒤)
    const in_url_zone = layout_math.pointInRect(x_px, y_px, band) and x_px >= nav_end_x;
    switch (kind) {
        2 => { // drag → 선택 확장(anchor=down 지점, focus=현재). 밴드 밖이면 clamp된 경계로.
            if (!self.pointerGestureIs(.address_selection)) return false;
            self.addr_field.selectTo(addrBandOffsetAt(self, pb, x_px));
            self.metal_dirty = true;
            return true;
        },
        3 => { // up → 드래그 종료.
            if (!self.pointerGestureIs(.address_selection)) return false;
            self.finishPointerGesture();
            return true;
        },
        4 => { // 더블클릭 → 단어 선택(URL 존만).
            if (!in_url_zone) return false;
            self.addr_field.selectWordAt(addrBandOffsetAt(self, pb, x_px), addr_word_separators);
            self.metal_dirty = true;
            return true;
        },
        5 => { // 트리플클릭 → 전체 선택(URL 존만 — 더블클릭과 동일 게이트라 nav 버튼 존 트리플클릭이 전체선택 안 하게).
            if (!in_url_zone) return false;
            self.addr_field.selectAll();
            self.metal_dirty = true;
            return true;
        },
        else => return false, // down(1)은 ①b가 처리(caret 배치·드래그 시작)
    }
}

/// Enter — 편집 텍스트(query)를 resolveNavUrl로 검증. 유효(허용 스킴/프리픽스 가능)하면 navigate pending(surface_id +
/// resolved url)을 세우고 편집을 종료(addr_field.clear)+focus-restore를 세운다. **무효(null)면 로드하지 않고 편집을
/// 그대로 유지**한다(clear·focus-restore 안 함) — 조용히 지워 무시하지 않고 사용자가 고쳐 재-Enter하거나 Esc로 취소하게
/// 한다(제보 "잘못된 주소가 그냥 무시됨"). 상세는 아래 else 분기 주석 참조.
pub fn commitAddrEdit(self: *AppSession) void {
    if (self.addr_edit) |sid| {
        // query(편집)에서 읽어 addr_navigate_url_buf(별도 세션 필드)로 쓴다 — aliasing 없음. resolved는 그 버퍼 슬라이스라
        // 아래 clear/null 후에도 유효(url 바이트는 세션 필드에 남음).
        if (maru.session.app_scheme.resolveNavUrl(self.addr_field.text.items, &self.addr_navigate_url_buf)) |resolved| {
            self.addr_navigate_url_len = resolved.len;
            self.addr_navigate_pending = sid;
            self.addr_edit = null;
            self.addr_field.clear();
            if (self.pointerGestureIs(.address_selection)) self.finishPointerGesture();
            self.addr_focus_restore_pending = sid;
        }
        // else: 잘못된 주소(허용 스킴 아님 — file://·javascript:// 등, 또는 빈 입력). **편집을 유지**한다 — 입력을 지우고
        // 조용히 종료하지 않아(제보 "그냥 무시 당함") 사용자가 고쳐 다시 Enter하거나 Esc로 취소하게 한다. (bare 도메인은
        // resolveNavUrl이 https:// 프리픽스로 대부분 통과하므로 여기 걸리는 건 명시적 미허용 스킴·빈 입력뿐.)
    }
}

/// 편집만 종료(로드 안 함). navigate는 안 세운다. `restore_focus`면 focus-restore pending(→webView) —
/// **Esc는 true**(편집 취소 후 브라우저로 복귀), **클릭-어웨이는 false**: 클릭한 target(터미널·다른 pane)이 포커스를
/// 정하므로 webView로 되돌리면 터미널을 클릭했는데 포커스가 브라우저로 튄다(제보). false면 focus-pull로 이미 터미널
/// 뷰에 있는 firstResponder를 그대로 둬 클릭 처리(focusPaneByPtr 등)가 목표 pane을 포커스한다.
pub fn cancelAddrEdit(self: *AppSession, restore_focus: bool) void {
    if (self.addr_edit) |sid| {
        if (restore_focus) self.addr_focus_restore_pending = sid;
        self.addr_edit = null;
        self.addr_field.clear();
        if (self.pointerGestureIs(.address_selection)) self.finishPointerGesture();
    }
}

/// teardown 훅 — surface_id가 편집 대상이면 편집·관련 pending을 정리한다(stale surface_id 방지). web Term이 닫히거나
/// (destroyTerm) 이동할 때 부른다. navigate/restore pending은 이미 종료된 편집의 잔재일 수 있어 대상 일치 시 함께 비운다.
pub fn dropAddrEditIfSurface(self: *AppSession, surface_id: u64) void {
    if (self.addr_edit) |sid| if (sid == surface_id) {
        self.addr_edit = null;
        self.addr_field.clear();
        if (self.pointerGestureIs(.address_selection)) self.finishPointerGesture();
    };
    if (self.addr_focus_pull_pending) |sid| {
        if (sid == surface_id) self.addr_focus_pull_pending = null;
    }
    if (self.addr_navigate_pending) |sid| {
        if (sid == surface_id) self.addr_navigate_pending = null;
    }
    if (self.addr_focus_restore_pending) |sid| {
        if (sid == surface_id) self.addr_focus_restore_pending = null;
    }
    // Phase 7e-3: nav 버튼 클릭 pending도 대상 일치 시 비운다(이미 세워진 채 surface가 닫히면 stale surface_id 방지).
    if (self.web_nav_action_pending) |sid| {
        if (sid == surface_id) self.web_nav_action_pending = null;
    }
}

/// 편집 활성 중 키 처리(handleKeyEvent 래퍼가 호출 — 활성이면 모든 키 소비). handleRenameKey 동형: Enter=확정·
/// Esc=취소·Backspace=삭제·평문 글자=추가, 모디파이어 조합·기타 키(↑↓ 등)는 무시(편집기 유지). 시각(metal_dirty·
/// blink)은 래퍼가 세운다(순수 코어 분리). IME 조합은 inputFocus=.addr_edit 라우팅으로 addr_field.setPreedit가 처리한다.
pub fn handleAddrEditKey(self: *AppSession, ev: chrome.input.InputEvent) void {
    switch (ev) {
        .key => |k| switch (k.key) {
            .escape => cancelAddrEdit(self, true), // Esc = 편집 취소 후 브라우저(webView)로 포커스 복귀
            .enter => commitAddrEdit(self),
            // 슬라이스 4: caret 이동/선택([key-input-and-shortcuts.md] macOS 줄 편집 정합). shift=선택 확장·option=단어·
            // command=줄 시작/끝(⌘←/→ — Key enum에 home/end 없어 command+화살표로). Key enum에 delete(⌦)·home·end가
            // 없어 그 키는 아직 미지원(백스페이스·⌘←/→가 커버).
            .left => {
                if (k.mods.command) self.addr_field.moveHome(k.mods.shift) // ⌘← = 줄 시작(⇧면 선택)
                else if (k.mods.option) self.addr_field.moveWordLeft(addr_word_separators, k.mods.shift) // ⌥← = 단어
                else self.addr_field.moveLeft(k.mods.shift); // ← / ⇧←
            },
            .right => {
                if (k.mods.command) self.addr_field.moveEnd(k.mods.shift) // ⌘→ = 줄 끝
                else if (k.mods.option) self.addr_field.moveWordRight(addr_word_separators, k.mods.shift) else self.addr_field.moveRight(k.mods.shift);
            },
            .backspace => {
                if (k.mods.command) self.addr_field.deleteToLineStart() // ⌘⌫ = 줄 시작까지 삭제(macOS deleteToBeginningOfLine)
                else if (k.mods.option) self.addr_field.deleteWordBackward(addr_word_separators) // ⌥⌫ = 단어 삭제
                else addrEditBackspace(self);
            },
            .char => {
                if (k.mods.command and (k.codepoint == 'a' or k.codepoint == 'A')) return self.addr_field.selectAll(); // ⌘A 전체 선택
                if (k.mods.command and (k.codepoint == 'x' or k.codepoint == 'X')) return addrEditCut(self); // ⌘X 잘라내기(⌘C/⌘V는 Swift가 인터셉트)
                if (k.mods.control and (k.codepoint == 'a' or k.codepoint == 'A')) return self.addr_field.moveHome(k.mods.shift); // ⌃A 줄 시작(emacs)
                if (k.mods.control and (k.codepoint == 'e' or k.codepoint == 'E')) return self.addr_field.moveEnd(k.mods.shift); // ⌃E 줄 끝
                if (k.mods.command or k.mods.control or k.mods.option) return; // 그 외 단축키 조합은 편집기에 안 쌓음
                addrEditAppend(self, k.codepoint);
            },
            .up, .down, .tab, .other => {}, // 무시(편집기 유지)
        },
        .pointer => {}, // 주소창 편집기는 포인터를 안 받는다(밴드 클릭 진입은 mouse-down 핸들러가 처리).
    }
}

/// 편집 진입 시 세운 focus-pull 신호를 drain(1회성). 7e-2b Swift가 매 tick take해 키 포커스를 WKWebView에서 뗀다.
pub fn takeWebAddrFocusPull(self: *AppSession) ?u64 {
    const v = self.addr_focus_pull_pending;
    self.addr_focus_pull_pending = null;
    return v;
}

pub fn takeWebAddrNavigate(self: *AppSession) ?WebNavigateRequest {
    if (self.addr_navigate_pending) |sid| {
        self.addr_navigate_pending = null;
        return .{ .surface_id = sid, .url = self.addr_navigate_url_buf[0..self.addr_navigate_url_len] };
    }
    return takeRestoredBrowserNavigate(self);
}

/// 복원된 브라우저 하나의 `pending_url`을 소비해 navigate 신호로 바꾼다(WP-P). URL을 세션 버퍼로 옮겨 담아
/// 반환 슬라이스 수명을 주소창 경로와 **같게** 맞춘다(호출자가 즉시 복사한다는 계약 공유).
pub fn takeRestoredBrowserNavigate(self: *AppSession) ?WebNavigateRequest {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                const url = term.pending_url orelse continue;
                if (url.len == 0 or url.len > addr_nav_url_cap) { // 방어: 저장 경로가 이미 걸렀지만 소비는 여기 단일 지점
                    self.allocator.free(url);
                    term.pending_url = null;
                    continue;
                }
                // WKWebView가 아직 없으면(created 전) 다음 tick에 다시 본다 — 지금 보내면 Swift가 버린다.
                // `web_panel_prev`는 **직전 tick에 Swift로 나간 집합**이므로 여기 있으면 created가 이미 나갔다.
                const present = blk: {
                    for (self.web_panel_prev.items) |p| if (p.surface_id == term.surfaceId()) break :blk true;
                    break :blk false;
                };
                if (!present) continue;
                @memcpy(self.addr_navigate_url_buf[0..url.len], url);
                self.addr_navigate_url_len = url.len;
                self.allocator.free(url);
                term.pending_url = null;
                return .{ .surface_id = term.surfaceId(), .url = self.addr_navigate_url_buf[0..self.addr_navigate_url_len] };
            }
        }
    }
    return null;
}

/// commit/cancel이 세운 focus-restore 신호를 drain(1회성). 7e-2b Swift가 키 포커스를 대상 WKWebView로 되돌린다.
pub fn takeWebAddrFocusRestore(self: *AppSession) ?u64 {
    const v = self.addr_focus_restore_pending;
    self.addr_focus_restore_pending = null;
    return v;
}

/// 4a `surfaceDiff` 결과를 self.web_surface_transitions batch로 marshaling한다(§6 전이 열거). created는 visible을
/// 실어 Swift가 hidden 생성 여부를 알게 하고, show/reframe은 함의상 보임(visible=true), destroy/hide는 surface_id만.
pub fn marshalWebTransitions(self: *AppSession, diff: *web_panel_layout.SurfaceDiff) !void {
    for (diff.destroyed.items) |sid| // 먼저 파괴(id 비재사용이라 create와 충돌 없지만 명료성).
        try self.web_surface_transitions.append(self.allocator, .{ .op = .destroy, .surface_id = sid });
    for (diff.created.items) |s|
        try self.web_surface_transitions.append(self.allocator, .{ .op = .create, .surface_id = s.surface_id, .panel_kind = s.panel_kind, .visible = s.visible, .seam_edges = s.seam_edges, .divider_grab_bands_pt = s.divider_grab_bands_pt, .frame_pt = webFramePt(self, s.content_rect) });
    for (diff.hidden.items) |sid|
        try self.web_surface_transitions.append(self.allocator, .{ .op = .hide, .surface_id = sid });
    for (diff.shown.items) |s|
        try self.web_surface_transitions.append(self.allocator, .{ .op = .show, .surface_id = s.surface_id, .panel_kind = s.panel_kind, .visible = true, .seam_edges = s.seam_edges, .divider_grab_bands_pt = s.divider_grab_bands_pt, .frame_pt = webFramePt(self, s.content_rect) });
    for (diff.reframed.items) |s|
        try self.web_surface_transitions.append(self.allocator, .{ .op = .reframe, .surface_id = s.surface_id, .panel_kind = s.panel_kind, .visible = true, .seam_edges = s.seam_edges, .divider_grab_bands_pt = s.divider_grab_bands_pt, .frame_pt = webFramePt(self, s.content_rect) });
}

/// Phase 4e-3: 이번 tick의 web surface 전이 batch를 계산해 self.web_surface_transitions에 채운다(§6·§10 4e-3).
/// **4a 세 순수함수를 전부 소비**한다: ① `contentRect`(per-pane 본문 rect) ② `surfaceDiff`(prev 집합↔cur 집합
/// 전이) ③ `pxTopLeftToPtBottomLeft`(webFramePt, 전이가 실을 본문 rect → WKWebView frame). prev를 cur로 전진시켜
/// (Swift가 batch를 적용한다는 전제) 다음 tick이 무변경이면 batch가 빈다(§10 "diff 있을 때만 sync"). 원자성: cur
/// 수집·marshal 중 OOM이면 transitions를 비우고 prev도 **안 전진**해 다음 tick이 같은 상태로 재시도한다(부분 적용 없음).
pub fn computeWebSurfaceTransitions(self: *AppSession) void {
    self.web_surface_transitions.clearRetainingCapacity(); // FP16에서 LRU를 제거했으므로 상한에 의한 해제는 없다(§1 불변식).

    // 영속 scratch 재사용(매 tick fresh 할당 회피). collect 실패(OOM/미초기화)면 batch 빔·prev 불변(재시도) —
    // scratch에 남은 부분 데이터는 다음 tick clearRetainingCapacity가 리셋하므로 무해.
    self.web_cur_scratch.clearRetainingCapacity();
    collectWebSurfaces(self, &self.web_cur_scratch) catch return;

    var diff = web_panel_layout.surfaceDiff(self.allocator, self.web_panel_prev.items, self.web_cur_scratch.items) catch return;
    defer diff.deinit(self.allocator);

    marshalWebTransitions(self, &diff) catch {
        self.web_surface_transitions.clearRetainingCapacity(); // 부분 marshal 롤백, prev 불변(원자성).
        return;
    };

    // prev ↔ cur: 스토리지 swap(할당 0, marshal이 필요 값을 이미 복사). swap 후 web_panel_prev는 이번 tick cur를
    // 들어 다음 tick diff 기준이 되고, web_cur_scratch는 옛 prev 버퍼를 들어 다음 tick clearRetainingCapacity로 재사용된다.
    // 둘 다 세션 deinit이 정확히 한 번씩 해제한다(distinct 스토리지라 double-free/leak 없음).
    std.mem.swap(std.ArrayList(web_panel_layout.SurfaceLayout), &self.web_panel_prev, &self.web_cur_scratch);
}

/// Phase 4e-3: 이번 tick의 web surface 전이 batch를 계산해 개수를 돌려준다(command_catalog식 count+at). Swift가
/// tick당 **정확히 한 번** 호출해(계산·prev 전진이 여기서 일어난다) count를 받고, `webSurfaceTransitionAt`로 각
/// 전이를 읽어 dict의 WKWebView에 적용한다. 계산이 count에 있는 이유: prev 전진이 tick당 1회여야 하기 때문이다.
pub fn webSurfaceTransitionsCount(self: *AppSession) usize {
    computeWebSurfaceTransitions(self);
    return self.web_surface_transitions.items.len;
}

/// index번째 전이(webSurfaceTransitionsCount 이후 같은 tick 유효). 범위 밖이면 op=none(무동작).
pub fn webSurfaceTransitionAt(self: *const AppSession, index: usize) WebSurfaceTransition {
    if (index >= self.web_surface_transitions.items.len) return .{ .op = .none };
    return self.web_surface_transitions.items[index];
}

/// 지난 tick 레이아웃에서 그 web surface의 본문 rect(backing px). 아직 한 번도 배치되지 않았으면 null이다.
pub fn webSurfaceRect(self: *AppSession, surface_id: u64) ?web_panel_layout.Rect {
    for (self.web_panel_prev.items) |layout| {
        if (layout.surface_id == surface_id) return layout.content_rect;
    }
    return null;
}

/// 웹 패널 포커스 중 Swift performKeyEquivalent가 같은 resolver의 typed provenance를 **side-effect 없이** 묻는다.
/// 사용자 app rebind, explicit unbind/terminal macro consume, editable WebKit default, built-in app action 순서를
/// 보존하며 PTY write·상태 변경은 0이다. app_action은 Swift가 범용 handleKeyDown에 재진입시키지 않고 아래
/// dispatchWebAppAction으로 직접 실행해 terminal copy/paste·scroll·macro 전처리를 우회한다.
pub fn webContextIsEditable(self: *AppSession, surface_id: u64) bool {
    return if (self.dock_initialized)
        if (file_panel_ops.fileEntryForSurfaceId(self, surface_id)) |entry|
            entry.kind.usesEditorBridge() and entry.mode.isEditable()
        else
            false
    else
        false;
}

pub fn webKeyRoute(self: *AppSession, surface_id: u64, event: terminal.KeyEvent) config_mod.keybinding.WebKeyRoute {
    return self.loaded_config.keyBindingResolver().resolveWeb(event, webContextIsEditable(self, surface_id));
}

/// WebKeyRoute 조회 뒤 실제 dispatch까지 살아 있는 **active WebView capability**를 다시 증명한다. dock entry
/// 존재만으로는 background tab/retired WKWebView를 허용하지 않고, workspace 쪽도 active Term이 browser인 경우만
/// 받는다. 모든 app action이 이 한 gate를 지나므로 사용자 rebind된 destructive action도 provenance를 우회하지 못한다.
pub fn webAppActionSource(self: *AppSession, surface_id: u64) ?WebAppActionSource {
    if (surface_id == 0) return null;
    if (self.dock_initialized) {
        if (file_panel_ops.fileEntryForSurfaceId(self, surface_id)) |entry| {
            if (entry.surface_id != surface_id) return null;
            // 옛 "그 entry가 group의 active여야 한다"는 capability 재증명의 FP16판. 배경 탭·비활성
            // 파일 Term의 늦은 WKWebView 키 이벤트가 보이지 않는 surface 기준으로 app action을
            // 실행하지 못하게 막는다(code-review max).
            if (!file_panel_ops.fileSurfaceIsVisible(self, surface_id)) return null;
            return .file_panel;
        }
    }
    if (!self.surface_initialized) return null;
    const term = pane_ops.activePane(self).activeTerm();
    if (!termIsWebBrowser(term) or term.surfaceId() != surface_id) return null;
    if (self.activeSurface().id != surface_id or !self.ownsSurface(surface_id)) return null;
    return .workspace_browser;
}

/// WebKeyRoute.app_action 실행 전용 경로. Swift terminal key 전처리를 다시 타지 않고 같은 resolver가 돌려준
/// Action을 직접 dispatch한다. route 조회 뒤 config가 바뀌었으면 현재 resolver가 app action일 때만 실행한다.
pub fn dispatchWebAppAction(self: *AppSession, surface_id: u64, event: terminal.KeyEvent) bool {
    const source = webAppActionSource(self, surface_id) orelse return false;
    const action = self.loaded_config.keyBindingResolver().resolveWebAppAction(event, webContextIsEditable(self, surface_id)) orelse return false;
    if (action == .close_focused) {
        // 실제 NSEvent를 받은 WebView surface가 이 dispatch의 최신 provenance다. route 조회와 같은 main-actor
        // 이벤트 안에서도 stale/hidden surface를 방어하고, 별도 FocusOwner를 재읽어 terminal을 닫지 않는다.
        if (source == .file_panel) {
            // 실제 NSEvent source를 먼저 공용 native-focus funnel로 logical owner에 반영한다. 이후 dirty
            // sync/save가 늦게 끝나기 전에 사용자가 다른 곳을 focus하면 그 최신 owner가 close successor보다 이긴다.
            if (!self.focusFilePanelSurface(surface_id)) return false;
            file_panel_ops.requestFilePanelClose(self, surface_id);
        } else {
            // 실제 NSEvent source가 workspace browser이므로 stale dock owner/publish barrier를 먼저 버린다.
            // WebView에서 Metal successor로 responder를 넘겨야 하므로 logical owner 정합뿐 아니라 native
            // one-shot도 함께 요청한다. confirm을 취소해 browser가 남아도 다음 키의 SSOT는 workspace다.
            workspace_ops.focusWorkspaceInput(self);
            self.workspace_focus_pending = true;
            self.requestClose(.term_or_pane);
        }
    } else if (action == .close_term) {
        // 명시적 사용자 바인딩 호환 action이지만 terminal 전용이다. 파일 WebView에서는 resolver가 반환해도
        // consume-only no-op이고, active browser capability에서만 workspace cascade를 허용한다.
        if (source != .workspace_browser) return false;
        workspace_ops.focusWorkspaceInput(self);
        self.workspace_focus_pending = true;
        self.requestClose(.term_or_pane);
    } else {
        self.dispatchAppAction(action);
    }
    self.total_app_key_events += 1;
    input_ops.settleKeyEventSummary(self);
    return true;
}

/// 슬라이스 4: ⌘X 잘라내기 — 선택 바이트를 **먼저 클립보드-쓰기 큐에 캡처**한 뒤 선택을 지운다(cut 표준: 바이트를 넘기지
/// "지금 선택을 복사해"가 아니라 → 비동기 순서 문제 없음). Swift가 pendingClipboard drain에서 그 바이트를 NSPasteboard에
/// 쓴다(OSC52 write와 같은 경로 — 새 ABI 불요). 편집 아님/선택 없음/OOM이면 무동작(선택 보존).
pub fn addrEditCut(self: *AppSession) void {
    if (self.addr_edit == null) return;
    const sel = self.addr_field.selection orelse return;
    const slice = self.addr_field.text.items[sel.lo()..sel.hi()];
    if (slice.len == 0) return;
    const captured = self.allocator.dupe(u8, slice) catch return; // OOM이면 cut 안 함(선택 보존)
    if (self.chrome_clipboard_write.len > 0) self.allocator.free(self.chrome_clipboard_write);
    self.chrome_clipboard_write = captured; // Swift가 다음 tick pendingClipboard drain에서 NSPasteboard에 씀
    _ = self.addr_field.deleteSelection();
}

/// 슬라이스 4: 클립보드 텍스트를 주소창 편집 필드에 삽입(⌘V) — 위생 처리 후 caret에 insertText(선택 있으면 대체).
/// 편집 아님이면 무동작. 큰 붙여넣기도 URL이라 상한 없이 그대로(필드는 동적 버퍼). 위생 처리(리뷰 #3·#7):
///  - **모든 C0 제어문자(<0x20)·DEL(0x7F) 제거** — 단일행 URL 오염 방지(옛 코드는 \r\n\0\t만 걸러 ESC·FF·VT 등이 샜다).
///  - **유효 UTF-8만 삽입**(손상 바이트 skip) — addr_field.text를 항상 유효 UTF-8로 유지해 displayCols(바이트-폴백)와
///    emitEditBand(codepoint 폭)가 어긋나 caret/선택/hit-test가 밀리는 것을 막는다.
pub fn addrEditPaste(self: *AppSession, bytes: []const u8) void {
    if (self.addr_edit == null) return;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    buf.ensureTotalCapacity(self.allocator, bytes.len) catch return;
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1; // 손상 lead 바이트 skip
            continue;
        };
        if (i + n > bytes.len) break; // 잘린 멀티바이트(끝) — 버린다
        const cp = std.unicode.utf8Decode(bytes[i .. i + n]) catch {
            i += 1; // 손상 시퀀스 skip
            continue;
        };
        if (cp >= 0x20 and cp != 0x7F) buf.appendSlice(self.allocator, bytes[i .. i + n]) catch return; // C0·DEL 제외
        i += n;
    }
    if (buf.items.len > 0) self.addr_field.insertText(self.allocator, buf.items) catch {};
}

/// 세팅 window.background-image 행 활성으로 파일 선택창 요청이 대기 중인지 — 1회성 drain(Swift가 매 tick 호출,
/// 1이면 NSOpenPanel을 연다). take_bell과 같은 패턴. (배경 이미지 파일 선택 — 사용자 요청)
/// 웹 탭 페이지 내 찾기 질의를 낸다(§8 슬라이스 ②). 활성 web 탭이 없으면 무동작.
/// 매 호출이 새 `seq`를 달아 **늦게 오는 이전 회신을 무효로** 만든다.
pub fn submitWebFind(self: *AppSession, backwards: bool) void {
    const sid = activeWebSurfaceIdAnyKind(self);
    if (sid == 0) return;
    if (self.chrome_host.find.input.query.items.len == 0) {
        // 빈 질의는 보내지 않는다 — WebKit이 뭘 찾을지 정의되지 않고, 하이라이트만 흔든다.
        self.web_find_pending = null;
        self.web_find_last_surface = 0;
        self.chrome_host.find.page_found = null; // 검색한 것이 없으니 찾음/없음도 없다
        return;
    }
    const q = self.chrome_host.find.input.query.items;
    if (q.len > self.web_find_query_buf.len) return; // 상한 초과는 제출하지 않는다(잘라 보내지 않는다)
    @memcpy(self.web_find_query_buf[0..q.len], q);
    self.web_find_query_len = q.len;
    self.web_find_seq +%= 1;
    self.web_find_last_surface = sid;
    self.web_find_pending = .{ .seq = self.web_find_seq, .surface_id = sid, .backwards = backwards };
    self.metal_dirty = true;
}

/// 소비하지 않고 길이만 본다 — ABI가 out 용량을 **소비 전에** 검사하려고 쓴다(못 담을 질의를 삼키면
/// 검색이 조용히 죽는다).
pub fn peekWebFindQueryLen(self: *const AppSession) ?usize {
    if (self.web_find_pending == null) return null;
    return self.web_find_query_len;
}

pub fn takeWebFindQuery(self: *AppSession) ?WebFindRequest {
    const p = self.web_find_pending orelse return null;
    self.web_find_pending = null;
    return .{
        .seq = p.seq,
        .surface_id = p.surface_id,
        .backwards = p.backwards,
        .query = self.web_find_query_buf[0..self.web_find_query_len],
    };
}

/// Swift가 `WKWebView.find` 결과를 돌려준다.
///
/// **늦은 회신은 버린다**: seq가 현재 것과 다르면 그 사이 새 질의가 나갔다는 뜻이고, 오버레이가 닫혔거나
/// 활성 탭이 웹이 아니면 반영할 화면 자체가 없다(docs/web-panel.md §8 "비동기 수명").
/// Swift가 **전달하지 못했다**고 신고한다(그 surface의 WKWebView가 아직 없음). 걷어 간 질의를 그냥 버리면
/// `web_find_last_surface`가 "보냈다"로 남아 tick이 영영 재시도하지 않는다 — 검색이 조용히 죽는 경로다.
/// 마커만 지우면 다음 tick이 같은 조건에서 다시 제출한다(패널은 한두 프레임 안에 생긴다 —
/// `takeWebAddrNavigate`가 "아직 WKWebView가 없는 Term은 다음 tick에 다시 본다"로 푸는 것과 같은 문제·같은 답).
pub fn reportWebFindUndeliverable(self: *AppSession, seq: u64) void {
    if (seq == 0 or seq != self.web_find_seq) return; // 늦은 신고는 무시(그 사이 새 질의가 나갔다)
    self.web_find_last_surface = 0;
}

pub fn provideWebFindResult(self: *AppSession, seq: u64, found: bool) void {
    if (seq == 0 or seq != self.web_find_seq) return;
    if (!self.chrome_host.find.open) return;
    // **seq만으로는 부족하다**: A에서 제출한 뒤 결과가 오기 전에 B로 옮기면 seq는 아직 유효하지만 그 답은
    // A의 것이다. 그대로 붙이면 B 화면이 A의 찾음/없음을 말한다(실측). 제출 대상과 지금 보이는 탭이 같을
    // 때만 반영한다 — 다르면 어차피 tick이 B로 재제출한다.
    const active = activeWebSurfaceIdAnyKind(self);
    if (active == 0 or active != self.web_find_last_surface) return;
    // 결과가 사는 곳은 **오버레이 상태 하나**다(`find.page_found`) — 세션에 사본을 또 두면 어느 쪽이
    // 진짜인지 흐려진다. 초안은 `web_find_result`도 들었는데 아무도 읽지 않는 죽은 상태였다.
    self.chrome_host.find.page_found = found;
    self.metal_dirty = true;
}
