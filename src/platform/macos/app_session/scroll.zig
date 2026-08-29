//! 스크롤 — 휠·페이지·줄 단위 스크롤 라우팅, 스크롤바 위젯(썸 기하·드래그 캡처·페이드), 오버레이 스크롤.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F8).
//!
//! 여기 있는 것은 **표면에 종속되지 않는 스크롤 기구**다. 표면별 스크롤 상태는 이미 각자의 그룹으로 갔다 —
//! 사이드바 스크롤은 `sidebar.zig`(F7), 도크 리스트는 `dock.zig`(F5), 파일 트리는 `file_panel.zig`(F2),
//! pane 스크롤바 배치는 `pane.zig`(F4)다. 그래서 예상(1,327줄)보다 작다.
//!
//! 이름 함정을 셋 걸렀다.
//!   - `reapplyScrollback`: `scrollback.lines` config를 터미널에 재적용한다. 터미널 스크롤백이지 스크롤 UI가
//!     아니다 — 소유는 config/settings(F9)다.
//!   - `scrollToCurrentMatch`: 본문이 `find_ops.scrollToCurrentMatch(self)` 한 줄인 **E1 facade**다.
//!     이름만 scroll이고 소유는 `find.zig`다.
//!   - `msPerTick`: 프레임 타이밍 유틸리티(`frameRateHz` 기반)로 바로 옆이 `bellFlashTotalTicks`다.
//!     스크롤바 페이드가 유일한 호출자일 뿐이라 남겼다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const dock_list_scrollbar_min_thumb_px = app_session_mod.dock_list_scrollbar_min_thumb_px;
const input_math = app_session_mod.input_math;
const term_ops = @import("term.zig");
const git_ops = @import("git.zig");
const chrome_draw_lowering = app_session_mod.chrome_draw_lowering;
const agent_dock = app_session_mod.agent_dock;
const overlay_scrollbar_inset_px = app_session_mod.overlay_scrollbar_inset_px;
const layout_math = app_session_mod.layout_math;
const overlay_scrollbar_width_px = app_session_mod.overlay_scrollbar_width_px;
const Term = app_session_mod.Term;
const default_scrollbar_fade_ticks = app_session_mod.default_scrollbar_fade_ticks;
const dock_list_scroll_drag_payload = app_session_mod.dock_list_scroll_drag_payload;
const dock_ops = @import("dock.zig");
const image_gallery_ops = @import("image_gallery.zig");
const scm_dock_ops = @import("scm_dock.zig");
const overlay_scroll_max_entries = app_session_mod.overlay_scroll_max_entries;
const tab_ops = @import("tab.zig");
const FileTreeScrollExtent = AppSession.FileTreeScrollExtent;
const OverlayScrollExtent = AppSession.OverlayScrollExtent;
const ScrollRef = app_session_mod.ScrollRef;
const default_scrollbar_visible_ticks = app_session_mod.default_scrollbar_visible_ticks;
const file_panel_ops = @import("file_panel.zig");
const pane_ops = @import("pane.zig");
const editor_ops = @import("editor.zig");
const scrollbar_alpha_full = app_session_mod.scrollbar_alpha_full;
const scrollbar_fade_ms = app_session_mod.scrollbar_fade_ms;
const scrollbar_visible_ms = app_session_mod.scrollbar_visible_ms;
const sidebar_ops = @import("sidebar.zig");
const terminal = app_session_mod.terminal;

/// 키보드 ↑↓로 알림 선택이 바뀐 뒤 — 선택 카드가 패널 viewport 밖이면 보이게 스크롤한다(컴포넌트 ensureSelectedVisible
/// 단일 출처). 개수·metrics만 넘긴다(Item 빌드 불필요). scroll_offset 상태를 두는 알림 패널 특유 처리(palette는 파생).
pub fn scrollNotificationsToSelected(self: *AppSession) void {
    self.chrome_host.notifications.ensureSelectedVisible(self.notification_history.items.len, self.buildCellMetrics());
    self.metal_dirty = true;
}

/// scrollbar를 capture가 볼 수 있는 tree로 다시 발행한다. thumb이 스크롤에 따라 움직이므로 매
/// move마다 재발행하고 세대를 올린다 — capture를 넘길지는 §5 carry verdict가 판정한다.
pub fn scrollbarCaptureActive(self: *const AppSession) bool {
    return self.scrollbar_interaction.capture != null;
}

pub fn endScrollbarCapture(self: *AppSession) void {
    self.scrollbar_interaction.capture = null;
    self.dock_list_scroll_drag.end();
    self.dock_list_scroll_drag_owner = null;
    self.scrollbar_drag_target = .none;
}

/// capture가 살아 있는 동안의 move/up. 소비했으면 true.
pub fn routeScrollbarCapture(self: *AppSession, kind: i32, y_px: f64) bool {
    if (self.scrollbar_drag_target == .overlay) return routeOverlayScrollbarCapture(self, kind, y_px);
    if (self.scrollbar_drag_target == .sidebar) return sidebar_ops.routeSidebarScrollbarCapture(self, kind, y_px);
    const owner = self.dock_list_scroll_drag_owner orelse return false;
    if (self.file_tree_perf_counters) |counters| counters.pointer_events += 1;

    const key = chrome.ui.interaction.GestureCompatibility{
        .kind = dock_list_scroll_drag_payload,
        .enabled = true,
        .owner_epoch = owner.root_generation,
        .domain_identity = owner.projection_generation,
    };
    const current_key = chrome.ui.interaction.GestureCompatibility{
        .kind = dock_list_scroll_drag_payload,
        .enabled = true,
        .owner_epoch = self.file_tree.rootGeneration(),
        .domain_identity = self.file_tree_projection_generation,
    };

    // thumb이 스크롤에 따라 움직이므로 매 move마다 다시 발행한다 — capture를 넘길지는 §5 carry
    // verdict가 판정한다. 예전에는 전용 `publish`가 rect 두 개를 손으로 만들었고, 지금은 같은
    // `scrollArea` 선언이 낸 tree를 그대로 쓴다.
    dock_ops.buildDockListScrollTree(self);
    const snapshot = file_panel_ops.fileTreeScrollTree(self);
    if (snapshot.entries.len == 0) {
        endScrollbarCapture(self);
        return true;
    }
    _ = chrome.ui.interaction.reconcileCarryingCapture(
        &self.scrollbar_interaction,
        snapshot,
        key,
        current_key,
    ) catch {
        endScrollbarCapture(self);
        return true;
    };
    if (self.scrollbar_interaction.capture == null) {
        endScrollbarCapture(self);
        return true;
    }

    // key가 같아도 track/thumb **기하**가 달라졌으면 down 시점 기하로 계산한 스크롤이 손가락과
    // 어긋난다. carry key는 host가 주입한 값의 동등성만 보므로 이 축은 여기서 domain이 지킨다
    // (계약 §5의 "up effect는 live domain validation을 다시 통과한다"와 같은 자리다).
    const live = dock_ops.dockListScrollbarGeometry(self) orelse {
        endScrollbarCapture(self);
        return true;
    };
    if (!file_panel_ops.fileTreeScrollbarSameSnapshot(self.dock_list_scroll_drag.geometry, live)) {
        endScrollbarCapture(self);
        return true;
    }

    const dispatched = chrome.ui.interaction.dispatch(&self.scrollbar_interaction, snapshot, .{
        .phase = if (kind == 2) .move else .up,
        .x_px = @as(f64, self.dock_list_scroll_drag.geometry.track_x) + @as(f64, self.dock_list_scroll_drag.geometry.track_w) / 2,
        .y_px = y_px,
        .timestamp_ns = 0,
        .button = .left,
        .generation = snapshot.generation,
    }) catch {
        endScrollbarCapture(self);
        return true;
    };
    if (dispatched.drag) |event| switch (event) {
        .began, .moved => |update| {
            self.dock_list_scroll_drag.absorb(update.x_px, update.y_px);
            self.scrollbar_move_events +|= 1;
        },
        .dropped => |update| {
            self.dock_list_scroll_drag.absorb(update.x_px, update.y_px);
            applyPendingScrollbarScroll(self);
            endScrollbarCapture(self);
        },
        .cancelled => endScrollbarCapture(self),
    };
    if (kind == 3) endScrollbarCapture(self);
    return true;
}

/// tick이 부르는 소비 지점. move가 몇 번 왔든 최종 좌표 하나만 적용하고, 같은 offset으로 clamp되면
/// 재투영하지 않는다. 흡수·소비·중복 억제는 `scroll_area.Drag`가 소유한다(도크와 같은 타입).
pub fn applyPendingScrollbarScroll(self: *AppSession) void {
    const offset_px = self.dock_list_scroll_drag.takeOffset() orelse return;
    self.scrollbar_scroll_applications +|= 1;
    // 어느 스크롤바를 잡았느냐가 offset이 갈 곳을 정한다. 태그를 안 보면 사이드바를 끄는데
    // **보이지 않는 도크 목록**이 스크롤된다(SV3b가 뷰 라우팅에서 세운 것과 같은 위험이다).
    switch (self.scrollbar_drag_target) {
        .overlay => setOverlayScrollOffsetPx(self, offset_px),
        .sidebar => sidebar_ops.setSidebarScrollOffsetPx(self, offset_px),
        // **편집기는 px를 자기 단위로 옮긴다**(scroll-area.md 소비자 표) — 세로는 `(논리 줄, 조각)`이라
        // 시각 행으로 나눈 뒤 접두합을 되짚고, 가로는 열이라 셀 폭으로 나눈다.
        .editor_vertical => editor_ops.setEditorScrollFromBarPx(self, offset_px),
        // **여기 못 온다.** 이 함수는 세로 전용 `dock_list_scroll_drag`의 offset을 먼저 가져오는데(위
        // `orelse return`), 가로 드래그 중에는 그 Drag가 비활성이라 거기서 빠진다. 가로는 자기 Drag를
        // 쓰는 `applyPendingEditorHScroll`이 소비한다. `switch`가 모든 태그를 요구해 자리만 둔다.
        .editor_horizontal => {},
        .dock_list, .none => dock_ops.setDockListScrollOffsetPx(self, offset_px),
    }
}

/// 편집기 **가로** 막대의 tick 소비. 세로와 나눈 이유는 드래그 상태 타입이 다르기 때문이다
/// (`HorizontalDrag` — `grab_dx` + `HorizontalGeometry`). 흡수·중복 억제 규율은 세로와 같다.
pub fn applyPendingEditorHScroll(self: *AppSession) void {
    if (self.scrollbar_drag_target != .editor_horizontal) return;
    const offset_px = self.editor_hscroll_drag.takeOffset() orelse return;
    self.scrollbar_scroll_applications +|= 1;
    editor_ops.setEditorHScrollFromBarPx(self, offset_px);
}

/// 소스 컨트롤 목록의 스크롤 좌표계(SV3a). **브랜치 헤더 한 줄을 뺀** 나머지가 뷰포트다 — 헤더는
/// 스크롤에서 고정이므로 스크롤 좌표에 들어가지 않는다. 탐색기와 같은 이유로 세 값을 한 자리에서
/// 만든다(상한이 호출부마다 갈리면 목록이 빈 곳으로 스크롤된다).
/// 목록 스크롤 상한. **값의 단일 출처는 그 탭의 투영**이다(`scm_dock.scrollExtent`) — 여기서도 도크
/// 안에서도 다시 세지 않는다. 예전에는 셀 높이를 여기서 다시 곱했고(P1b에서 component 기하로 옮겼다),
/// 그다음 판에서도 도크가 **변경 사항 모델을 다시 세어** 히스토리·에이전트 탭이 자기 목록과 무관한
/// 상한으로 굴러가지 않았다. 세는 자리가 목록을 만드는 자리와 같아야 그 갈림이 원리적으로 없어진다.
pub fn scmScrollExtent(self: *AppSession) FileTreeScrollExtent {
    const extent = scm_dock_ops.scrollExtent(self);
    return .{
        .content_h_px = extent.content_h_px,
        .viewport_h_px = extent.viewport_h_px,
        .max_offset_px = extent.max_offset_px,
    };
}

pub fn scmEffectiveScrollPx(self: *AppSession) u32 {
    return @min(self.scm_scroll.offset_y_px, scmScrollExtent(self).max_offset_px);
}

pub fn clampScmScroll(self: *AppSession) void {
    self.scm_scroll.clamp(scmScrollExtent(self).max_offset_px);
}

/// 뷰포트를 delta_up줄만큼 스크롤한다(+위=과거, -아래=현재). 스크롤 로직은 TerminalCore가
/// 소유하고, 여기선 다음 tick이 새 뷰를 그리도록 metal_dirty만 세운다(Swift는 휠/키 이벤트를
/// 이 함수로 넘기는 얇은 글루다).
pub fn scroll(self: *AppSession, delta_up: i32) void {
    // [4e-2, §6·1-B] 활성 Term이 web이면 스크롤 대상(스크롤백)이 없다(sentinel) — no-op(웹 스크롤은 WKWebView 소유).
    if (!self.surface_initialized or !term_ops.activeTermIsTerminal(self)) return;
    const surface = term_ops.activeSurface(self);
    // scrollViewport는 코어 mutate라 reader로 위임(full (a), docs/plans/io-render-threading.md §9 P3-4).
    self.enqueueCoreCommandForSurface(surface.id, .{ .scroll = @as(isize, delta_up) }) catch {};
    self.metal_dirty = true;
}

/// 마우스/트랙패드 휠 스크롤. Swift는 raw NSEvent 값(델타 포인트 + 정밀 델타 여부)만 넘기고,
/// 줄 수 환산은 여기서 실제 cell 메트릭으로 한다(네이티브 최소화). 정밀(트랙패드) 델타는 포인트
/// 단위라 한 줄 높이(포인트)로 나눠 줄 수로 바꾸고, 줄 단위(마우스 휠) 델타는 그대로 줄 수다.
/// 한 줄 미만의 정밀 델타는 wheel_accum에 누적해 천천히 스크롤해도 줄이 소실되지 않는다.
/// NaN/∞·거대값은 무시/clamp한다(@intFromFloat trap 방지).
pub fn scrollWheel(self: *AppSession, delta_y: f64, delta_x: f64, precise: bool, x_px: f64, y_px: f64) void {
    if (!self.surface_initialized) return;
    // 닫기 확인 모달은 결정 게이트라 마우스 클릭(mouse())뿐 아니라 휠도 막는다 — 안 막으면 모달 뒤 터미널/스크롤백이
    // 사용자 결정 중에 움직이거나(스크롤) 트래킹 앱에 휠이 리포트된다(모달 의도 위배).
    if (self.chrome_host.confirm.open) return;
    // 상태바 위 휠은 **삼킨다**. 아래 라우팅은 "어느 pane에도 안 맞으면 활성 surface로 fallback"이라,
    // 안 막으면 상태바를 굴리는 동작이 터미널 스크롤백을 움직인다. 사이드바 판정보다 먼저 둔다 —
    // 상태바는 창 전폭이라 사이드바 아래 구간도 지나가고, 뒤에 두면 그 구간이 사이드바 스크롤로 샌다.
    //
    // **오버레이가 열려 있으면 이 가드를 타지 않는다.** 아래 notice 처리는 "아무 입력으로나 닫힘"
    // 규율이라 휠도 토스트를 닫아야 하는데(그 주석이 옛 회귀를 적어 뒀다), 여기서 삼키면 토스트가
    // 뜬 채로 스크롤도 막히고 닫히지도 않는다. 알림 패널 휠 처리도 아래에 있다. `mouse()`와 같은 게이트다.
    if (!self.anyOverlayOpen() and self.pointInStatusBar(x_px, y_px)) return;
    // notice 토스트(비-인터랙티브 정보, 자동 닫힘 타이머 없음)는 **휠로도 닫는다** — 키(notice.handle)·클릭(mouse())과
    // 같은 "아무 입력으로나 닫힘" 규율을 휠까지 확장한다(옛날엔 아래 anyOverlayOpen이 휠을 삼키기만 해 토스트가 떠 있는
    // 동안 스크롤이 막힌 채 닫히지도 않았다). 휠은 소비한다(닫되 스크롤은 안 함 — 토스트 확인 제스처). notifications와
    // 공존할 수 있어(showNotice가 패널을 안 닫음) 그 분기보다 먼저 둔다(mouse()의 notice-우선 순서와 일치).
    if (self.chrome_host.notice.open) {
        self.chrome_host.notice.dismiss();
        self.metal_dirty = true;
        return;
    }
    // 알림 패널이 열려 있으면 휠은 패널 카드 스크롤로 가로챈다(클릭이 패널로 가로채지는 mouse()의 게이트와 짝 —
    // 터미널/스크롤백으로 안 흘린다). 휠 위(lines>0)=목록 위(최신, offset↓)·아래=오래된(offset↑). 카드 단위라 줄
    // 수를 그대로 카드 delta로 쓴다(부호 반전: 위로 굴리면 offset 감소). 개수·metrics만 넘긴다(Item 빌드 불필요).
    if (self.chrome_host.notifications.open) {
        if (std.math.isFinite(delta_y) and delta_y * self.wheel_accum < 0) self.wheel_accum = 0;
        const scaled = delta_y * @as(f64, self.appearance.scroll_multiplier);
        const lines = wheelDeltaToLines(&self.wheel_accum, scaled, precise, self.cell_height_px, self.scale_milli);
        if (lines != 0) {
            self.chrome_host.notifications.scrollBy(self.notification_history.items.len, self.buildCellMetrics(), @as(i64, -lines));
            self.metal_dirty = true;
        }
        return;
    }
    // 그 외 오버레이(notice·context_menu·find·palette·settings)가 열려 있으면 휠을 **소비**한다 — 터미널/스크롤백으로
    // 안 흘린다(클릭이 mouse()에서 막히는 것과 짝, 오버레이는 배타적이라 한 번에 하나).
    //
    // **SV5d: 팔레트·세팅은 여기서 자기 목록을 굴린다**(위 주석이 "자체 스크롤은 아직 없다(후속)"이라
    // 적어 둔 그 후속이다). 소비 게이트가 이 자리에 있으므로 스크롤도 **여기서** 해야 한다 — 뒤에
    // 두면 이 return에 먼저 걸려 도달하지 못한다(실제로 그렇게 나갔다).
    if (self.anyOverlayOpen()) {
        const lines_overlay = wheelDeltaToLines(&self.wheel_accum, delta_y * @as(f64, self.appearance.scroll_multiplier), precise, self.cell_height_px, self.scale_milli);
        _ = scrollOverlayByLines(self, lines_overlay);
        return;
    }
    // 갤러리 크게 보기 위의 휠은 **확대·축소**다. 목록이 아니라 한 장을 보고 있으므로 굴릴 것이
    // 없고, 아무 일도 안 하면 「휠이 안 먹는다」로 읽힌다. 격자일 때는 아직 스크롤이 없어 흘려보낸다.
    if (dock_ops.dockVisible(self) and self.dock.view == .image_gallery and
        layout_math.pointInRect(x_px, y_px, dock_ops.dockGeometry(self).tree_content))
    {
        const scaled = delta_y * @as(f64, self.appearance.scroll_multiplier);
        if (self.image_gallery.open != null) {
            image_gallery_ops.wheelZoom(self, scaled, precise, x_px, y_px);
            return;
        }
        // 격자에서는 **굴린다**. 굴릴 것이 없으면 소비하지 않고 흘려보낸다(도크 위에서 휠이
        // 통째로 막히면 뒤 터미널 스크롤백이 죽는다).
        if (image_gallery_ops.wheelScroll(self, scaled, precise)) return;
    }
    const session_dock_wheel_target = dock_ops.dockVisible(self) and self.dock.view == .agent_sessions and
        layout_math.pointInRect(x_px, y_px, dock_ops.dockGeometry(self).tree_content);
    // Do not carry a sub-pixel trackpad remainder from the dock into a later re-entry. The
    // next dock gesture must start from its own physical direction and owner.
    // 도크를 떠났으면 분수 잔여를 남기지 않는다 — 다시 들어왔을 때 첫 틱이 엉뚱하게 튄다.
    if (!session_dock_wheel_target) self.agent_session_archive_scroll.dropWheelResidue();
    if (session_dock_wheel_target) {
        // 도크는 양쪽 clamp 경계에서도 자기 휠 이벤트를 소비한다. 안 그러면 목록 끝에 닿은
        // 트랙패드 제스처가 뒤 터미널/PTY로 샌다.
        const dock_scale_milli = agent_dock.agentSessionDockScaleMilli(self);
        const m = chrome.components.session_dock.types.DockMetrics.resolve(dock_scale_milli);
        // precise(트랙패드)는 논리 픽셀, 아니면 카드 한 장이 한 틱이다.
        const unit: f64 = if (precise)
            @as(f64, @floatFromInt(dock_scale_milli)) / 1000.0
        else
            @as(f64, @floatFromInt(m.card_h));
        // 잔여 축적·방향 전환·정수부 소비·overflow 가드는 `State`가 소유한다.
        const projection = agent_dock.agentSessionDockScrollProjection(self);
        if (self.agent_session_archive_scroll.scrollByWheel(
            delta_y * @as(f64, self.appearance.scroll_multiplier),
            unit,
            projection.max_offset_px,
        )) self.metal_dirty = true;
        return;
    }
    // 소스 컨트롤도 **자기 상태**(scm_scroll)로 굴린다 — 뷰별로 나눠 두지 않으면 안 보이는 목록이
    // 움직인다. 탐색기와 같은 픽셀 경로이므로 줄 환산 앞에 둔다(SV3a).
    const scm_wheel_target = dock_ops.dockVisible(self) and self.dock.view == .source_control and
        layout_math.pointInRect(x_px, y_px, dock_ops.dockGeometry(self).tree_content);
    if (!scm_wheel_target) self.scm_scroll.dropWheelResidue();
    // **커밋 상자 위의 휠은 그 상자를 굴린다**(사용자 결정 2026-08-18). 그전까지는 상자 위에서도 뒤의
    // 목록이 움직였다 — 상자에는 "글이 더 있다"는 막대가 떠 있는데 굴리면 **다른 것**이 움직이니
    // 그 막대가 고장으로 읽힌다. 상자 안 스크롤에 포인터로 닿는 길이 이것 하나뿐이기도 하다
    // (막대는 그리기 전용이고, caret 경로는 키보드다 — docs/editor-surface-dock.md §3.5).
    //
    // **목록 분기보다 앞이다.** 상자는 목록 안에 있는 줄이라(②b) 두 rect가 겹치고, 뒤에 두면 목록이
    // 먼저 소비해 상자에는 영영 닿지 않는다.
    //
    // **판정은 클릭과 같은 함수를 쓴다**(`pointInCommitBox`). 여기서 rect를 다시 재면 경계 한 픽셀에서
    // 두 입구가 갈려, "가장자리에서만 휠이 목록으로 샌다"는 재현하기 어려운 증상이 된다.
    const commit_wheel_target = scm_wheel_target and scm_dock_ops.pointInCommitBox(self, x_px, y_px);
    if (!commit_wheel_target) scm_dock_ops.dropCommitWheelResidue(self);
    if (commit_wheel_target) {
        // 트랙패드(precise)는 점 단위라 행 높이로 나눠 행으로 바꾸고, 휠 눈금은 한 틱이 한 행이다.
        const row_h: f64 = @floatFromInt(@max(scm_dock_ops.commitRowHeightPx(self), 1));
        const unit_rows: f64 = if (precise)
            @as(f64, @floatFromInt(self.scale_milli)) / 1000.0 / row_h
        else
            1.0;
        switch (scm_dock_ops.scrollCommitByWheel(
            self,
            delta_y * @as(f64, self.appearance.scroll_multiplier),
            unit_rows,
        )) {
            // 끝에 닿아도 소비한다 — 상자 안에서 굴린 손이 뒤의 목록을 움직이면 안 된다(도크·탐색기와
            // 같은 규율). 잔여만 쌓인 틱도 상자의 것이다.
            .scrolled => {
                self.metal_dirty = true;
                return;
            },
            .absorbed => return,
            // **글이 다 보이면 넘긴다.** 그때는 막대도 안 그려지고, 여기서 삼키면 상자 위가 죽은
            // 구역이 되어 목록이 안 굴러간다(짧은 메시지가 기본 상태다).
            .ignored => {},
        }
    }
    if (scm_wheel_target) {
        const unit: f64 = if (precise)
            @as(f64, @floatFromInt(self.scale_milli)) / 1000.0
        else
            @as(f64, @floatFromInt(self.cell_height_px));
        const extent = scmScrollExtent(self);
        if (self.scm_scroll.scrollByWheel(
            delta_y * @as(f64, self.appearance.scroll_multiplier),
            unit,
            extent.max_offset_px,
        )) self.metal_dirty = true;
        // 목록 끝에 닿아도 소비한다 — 도크·탐색기와 같은 규율(뒤 터미널로 새지 않는다).
        return;
    }
    // 탐색기도 자기 상태(file_tree_scroll)로 굴린다 — 다른 뷰에서 굴리면 안 보이는 목록이 움직인다.
    // **줄 환산(`wheelDeltaToLines`)보다 앞에 둔다**: 픽셀 상태라 공유 `wheel_accum`을 소비할 이유가
    // 없고, 소비하면 탐색기 위 제스처가 터미널 스크롤백의 잔여를 갉아먹는다.
    const file_tree_wheel_target = dock_ops.dockVisible(self) and self.dock.view == .explorer and
        layout_math.pointInRect(x_px, y_px, dock_ops.dockGeometry(self).tree_content);
    if (!file_tree_wheel_target) self.file_tree_scroll.dropWheelResidue();
    if (file_tree_wheel_target) {
        // precise(트랙패드)는 논리 픽셀이라 부분 행이 그대로 드러나고, 아니면 한 행이 한 틱이다.
        const unit: f64 = if (precise)
            @as(f64, @floatFromInt(self.scale_milli)) / 1000.0
        else
            @as(f64, @floatFromInt(self.cell_height_px));
        const extent = file_panel_ops.fileTreeScrollExtent(self);
        if (self.file_tree_scroll.scrollByWheel(
            delta_y * @as(f64, self.appearance.scroll_multiplier),
            unit,
            extent.max_offset_px,
        )) {
            dock_ops.buildDockListScrollTree(self);
            self.dock_list_scrollbar_idle_ticks = 0;
            self.metal_dirty = true;
            // **호버를 다시 계산하지 않는다**(FT2). 노드 id 는 창 안의 자리라, 스크롤해도 커서 밑의
            // 자리는 그대로다 — 그 자리가 어느 파일인지는 다음 발행의 action 표가 답한다. 여기서
            // 인덱스를 다시 구하면 발행 전 rect 로 계산한 두 번째 답이 생긴다.
        }
        // 목록 끝에 닿아도 소비한다 — 도크와 같은 규율(뒤 터미널로 새지 않는다).
        return;
    }
    // 방향이 뒤집히면 1줄 미만 잔여를 버린다 — 이전 방향의 residue가 첫 반대 틱을 상쇄해
    // 방향 전환이 굼뜨게 느껴지는 것 방지(iTerm2/xterm.js 동작).
    if (std.math.isFinite(delta_y) and delta_y * self.wheel_accum < 0) self.wheel_accum = 0;
    // 세로 스크롤 배수(scroll.multiplier): delta에 곱해 줄 환산 전 속도를 조절한다(가로 탭 바엔 적용 안 함 — 아래
    // tab_wheel_accum 경로는 원본 delta_x). 방향 판정(위 wheel_accum 부호)은 배수>0이라 부호 불변이라 영향 없다.
    const scaled_delta_y = delta_y * @as(f64, self.appearance.scroll_multiplier);
    const lines = wheelDeltaToLines(&self.wheel_accum, scaled_delta_y, precise, self.cell_height_px, self.scale_milli);
    // 사이드바 위 휠 = 사이드바 세로 스크롤이 **통째로 소비**한다(커서 아래 소유 원칙을 사이드바로 확장 — 터미널/
    // 스크롤백으로 안 흘린다). 카드가 헤더 아래 뷰포트를 안 넘으면 clamp가 no-op이라 무동작이지만, 그래도 소비해
    // 사이드바 위 휠이 뒤 터미널을 굴리는 위화감을 막는다. 한 줄(cell 높이)을 픽셀 단위로 환산해 스무스 스크롤한다 —
    // 위(lines>0=과거)면 콘텐츠를 아래로(offset↓), 아래면 위로(offset↑). 가로(탭 바)는 사이드바와 무관해 건너뛴다.
    if (self.sidebar_width_px > 0 and sidebar_ops.inSidebar(self, x_px)) {
        const max = sidebar_ops.sidebarMaxScroll(self);
        if (lines != 0 and max > 0) { // 안 넘치면 소비만(아래 return) — 헛 rebuild 안 함
            const step: i64 = @as(i64, lines) * @as(i64, @intCast(self.cell_height_px));
            const next: i64 = @as(i64, self.sidebar_scroll_offset_px) - step; // lines>0(위) → offset 감소
            const clamped: u32 = @intCast(std.math.clamp(next, 0, @as(i64, max)));
            if (clamped != self.sidebar_scroll_offset_px) { // 실제로 움직였을 때만 재배치
                self.sidebar_scroll_offset_px = clamped;
                sidebar_ops.rebuildSidebar(self) catch {}; // 밴드·tint quad를 새 오프셋으로 재배치(셀은 .m이 frame 오프셋으로 자동, 스크롤바는 per-frame)
                self.metal_dirty = true;
            }
        }
        return;
    }
    // 휠은 '커서 아래' surface가 통째로 처리한다 — split에서 비활성 panel 위 스크롤이 그 panel을 스크롤하고
    // (포커스는 안 바꾼다), mouse tracking 판정·리포트 좌표도 그 surface 기준이라 정합한다. 베이스: Ghostty/
    // Warp — 휠은 포인터 아래 surface가 소유한다(포커스 무관). 그래야 포커스 pane이 트래킹 앱(vim/tmux 등)
    // 이어도 옆 셸 pane 위 휠이 그 셸 스크롤백을 움직인다. 사이드바/밖(hit null)이면 활성 surface로 fallback.
    // surface와 rect는 한 leaf에서 온 한 쌍이라 함께 unwrap한다 — 둘을 따로 풀면 다른 분기에서 와 pane↔좌표가
    // 어긋날 수 있다(이 rework가 막으려는 것). rect는 트래킹 리포트 좌표용(pxToCellIn).
    const hit = pane_ops.paneTargetAt(self, x_px, y_px);
    // **편집기 pane은 문서를 스크롤한다.** 셸이 아니므로 아래의 스크롤백·mouse reporting 경로를
    // 타면 안 되고(둘 다 core가 있어야 한다), 안 소유하면 편집기 위 휠이 뒤 터미널을 굴린다.
    //
    // **세로만 소유한다 — 여기서 반환하면 안 된다.** 아래 가로(트랙패드 2-finger) 블록은 탭 바를
    // 굴리는 **직교 축**이고, 그것은 편집기 pane 위에서도 살아 있어야 한다(리뷰 지적 — 처음엔
    // 곧바로 반환해서 편집기 위 가로 스와이프가 아무 일도 안 했다).
    // **폴백에서도 편집기가 소유한다.** 어느 leaf에도 안 맞으면 라우팅은 활성 surface로 가는데,
    // 편집기 Term의 surface는 sentinel core라 아래 스크롤백 경로가 **아무 일도 하지 않는다** — 활성
    // pane이 편집기인 채로 pane 밖에서 굴리면 휠이 조용히 사라진다(적대적 검증에서 잡았다).
    const editor_owned = if (hit) |h|
        editor_ops.scrollLines(self, h.term, h.leaf_rect, lines)
    else if (pane_ops.activeLeafRect(self)) |leaf|
        editor_ops.scrollLines(self, pane_ops.activePane(self).activeTerm(), leaf, lines)
    else
        false;
    const target, const rect = if (hit) |h| .{ h.surface, h.rect } else .{ term_ops.activeSurface(self), self.active_pane_rect };
    // mouse_tracking 읽기 + reportMouse(코어 response 생성)는 락 아래(리더 core.write와 response 경합 방지,
    // docs/io-render-threading.md PR3). writeInput은 락 밖(PR1 패턴).
    // mouse_tracking 읽기는 메인 락-아래(읽기 위임 안 함, §9.1). reportMouse(코어 mutate+응답)는 full (a)
    // (docs/plans/io-render-threading.md §9 P3-4)로 reader에 위임 — 휠 lines만큼 반복 enqueue, reader가 각 적용 후
    // pendingResponse를 PTY로 흘린다.
    // host-backed(원격)면 placeholder core엔 mouse_tracking이 없으므로(진짜 코어는 host) 관측에서 온 실제
    // 모드로 게이트하고, 아래 enqueueCoreCommand(report_mouse)가 host로 라우팅돼 host가 인코딩·PTY 주입한다(§입력 패리티).
    // 편집기가 세로를 가져갔으면 아래 터미널 축은 통째로 건너뛴다(코어가 없어 트래킹 조회 자체가
    // 의미 없다). 가로 축은 그 아래에서 계속 처리된다.
    const tracking = if (editor_owned)
        false
    else if (target.remote != null)
        self.remoteMouseTracking(target.id) != .none
    else blk: {
        target.lockCore(self.io);
        defer target.unlockCore(self.io);
        break :blk target.core.mouse_tracking != .none;
    };
    // 세로(터미널) 축: 트래킹이면 앱이 휠을 소비(SGR 64/65 리포트), 아니면 커서 아래 surface 스크롤백을 굴린다.
    if (tracking) {
        // 리포트는 target(커서 아래)으로, 좌표도 그 본문 rect 기준이라 pane↔좌표가 정합한다. 사이드바/밖(hit
        // null)이면 활성 pane으로 폴백(target/rect 한 쌍). lines>0=위(과거)=64, <0=아래=65, 앱이 휠을 소비한다.
        if (lines != 0) {
            // 트래킹 앱이 휠을 소비하면 그 앱이 화면을 굴린다 — 남은 선택은 옛 좌표를 가리키는 유령이라
            // 먼저 해제한다(Ghostty: 리포팅 중 스크롤이면 setSelection(null)). lines 반복 리포트와 달리
            // 해제는 이벤트당 한 번이면 충분하다(lines만큼 반복할 이유가 없다).
            term_ops.clearSurfaceSelection(self, target.id);
            if (self.pxToCellIn(target, rect, x_px, y_px)) |cell| {
                const wb: u8 = if (lines > 0) 64 else 65;
                var n: i32 = if (lines > 0) lines else -lines;
                while (n > 0) : (n -= 1) self.enqueueCoreCommandForSurface(target.id, .{ .report_mouse = .{ .button = wb, .col = cell.col, .row = cell.row, .x_px = cell.term_x_px, .y_px = cell.term_y_px, .pressed = true, .motion = false, .mods = 0 } }) catch {};
            }
        }
    } else if (!editor_owned) {
        scrollSurfaceLines(self, target, lines);
    }
    // 가로(트랙패드 2-finger) 델타 → 커서 아래 pane 탭 바 가로 스크롤(#2b). 세로(터미널)와 **직교 축**이라 한
    // 이벤트(대각선)에서 둘 다 처리될 수 있고, 탭 바는 Maru chrome(터미널 앱이 못 받는 축)이라 mouse tracking과
    // 무관하게 항상 처리한다 — 트래킹 앱 pane 위에서도 탭 바는 굴러간다(세로만 앱이 소비). 안 넘치면 무동작.
    if (std.math.isFinite(delta_x) and delta_x != 0) {
        if (delta_x * self.tab_wheel_accum < 0) self.tab_wheel_accum = 0; // 방향 전환 시 잔여 버림(세로와 같은 규율)
        const cols = wheelDeltaToLines(&self.tab_wheel_accum, delta_x, precise, self.cell_width_px, self.scale_milli); // 셀 환산 범용 — 가로는 cell_width
        if (cols != 0) {
            // **편집기 본문이 넘칠 때만 이 축을 가져간다.** 랩을 끄면 긴 줄의 오른쪽을 볼 방법이
            // 지금은 없다. 다만 탭 바 축은 편집기 pane 위에서도 살아 있어야 하므로(위 세로 소유
            // 주석의 리뷰 지적), **넘칠 때만** 소유하고 아니면 지금까지의 탭 바 경로가 그대로 돈다.
            const editor_took_x = if (hit) |h|
                editor_ops.scrollCols(self, h.term, h.leaf_rect, cols, x_px)
            else if (pane_ops.activeLeafRect(self)) |leaf|
                editor_ops.scrollCols(self, pane_ops.activePane(self).activeTerm(), leaf, cols, null)
            else
                false;
            if (!editor_took_x) tab_ops.scrollTabBarAt(self, x_px, y_px, cols); // 커서 아래 터미널 pane 탭 바(있으면) // 커서 아래 도크 그룹 탭 바(있으면) — pane과 영역이 안 겹쳐 둘 중 하나만 매치
        }
    }
}

/// 줄 수만큼 스크롤한다. alt screen + alternate scroll(DECSET 1007)이면 화살표 키로 변환해
/// 프로그램(less/vim)에 보낸다(iTerm2/Terminal.app 동작, DECCKM이면 SS3 형식). 휠과
/// Shift+PageUp/Down이 같은 경로를 타 일관되게 동작한다.
/// 활성 surface를 줄 수만큼 스크롤(키보드 PageUp/Down 경로). 휠은 paneTargetAt으로 고른 surface에 직접 쓴다.
pub fn scrollLines(self: *AppSession, lines: i32) void {
    scrollSurfaceLines(self, term_ops.activeSurface(self), lines);
}

/// 주어진 surface를 줄 수만큼 스크롤한다 — 휠은 커서 아래 panel(비활성 가능), 키보드는 활성. alt screen +
/// alternate scroll(DECSET 1007)이면 그 surface PTY로 화살표 키를 보내고(less/vim 등 프로그램 스크롤),
/// 아니면 그 surface의 뷰포트를 스크롤한다(scrollback). 줄 0이면 무동작.
pub fn scrollSurfaceLines(self: *AppSession, surface: *maru.session.Surface, lines: i32) void {
    if (lines == 0) return;
    const core = &surface.core;
    var is_alt = false;
    var key_buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    var alt_len: usize = 0;
    if (surface.remote != null) {
        const loc = term_ops.findTermWhere(self, surface.id, struct {
            fn pred(id: u64, term: *Term) bool {
                return term.kind == .terminal and term.surface.id == id;
            }
        }.pred) orelse return;
        const term = loc.pane.terms.items[loc.term_index];
        // 관측이 아직 안 왔으면(재접속 직후 metadata 도착 전 ~0.5s window 등) **alt-screen 판정만 스킵**하고 평범한
        // 스크롤백(host view_offset — 관측이 필요 없음)은 그대로 진행한다. 예전엔 여기서 hard return이라 관측 미가용
        // 창에서 **양쪽 경로 다 죽어** 스크롤이 완전히 안 됐다(host-alive robustness — 재접속 직후 스크롤 즉시 동작).
        const observation = &term.rt.observation;
        if (observation.availability != .unavailable and observation.alt_active and observation.alternate_scroll) {
            is_alt = true;
            const bytes = if (lines > 0)
                (if (observation.app_cursor_keys) "\x1bOA" else "\x1b[A")
            else
                (if (observation.app_cursor_keys) "\x1bOB" else "\x1b[B");
            @memcpy(key_buffer[0..bytes.len], bytes);
            alt_len = bytes.len;
        }
    } else {
        // local alt+alternate_scroll 판정 + key encoding은 실제 core lock 아래.
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        if (core.alt_active and core.alternate_scroll) {
            is_alt = true;
            const key: terminal.input.Key = if (lines > 0) .arrow_up else .arrow_down;
            const bytes = core.encodeKey(.{ .key = key }, &key_buffer) catch return;
            alt_len = bytes.len;
        }
    }
    if (is_alt) {
        // 휠을 화살표 키로 바꿔 프로그램에 보내는 순간 그 화면은 프로그램이 다시 그린다 — 남은 선택은
        // 좌표가 어긋난 유령이 되므로 해제한다(Ghostty도 이 변환 경로에서 항상 setSelection(null)).
        term_ops.clearSurfaceSelection(self, surface.id);
        // alt screen + alternate scroll(DECSET 1007): 프로그램에 화살표 키를 보낸다(PTY write — core mutate 아님).
        // 시퀀스를 한 버퍼에 반복해 묶어 보낸다 — 줄마다 writeInput을 하면 빠른 플릭에서 PTY 버퍼가 차 나머지가 드랍.
        const bytes = key_buffer[0..alt_len];
        var batch: [512]u8 = undefined;
        const per_batch = batch.len / bytes.len;
        var remaining: u32 = @abs(lines);
        while (remaining > 0) {
            const count = @min(remaining, @as(u32, @intCast(per_batch)));
            var len: usize = 0;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                @memcpy(batch[len..][0..bytes.len], bytes);
                len += bytes.len;
            }
            self.runtime.writeInput(surface.id, .{ .bytes = batch[0..len] }) catch break; // 쓰기 실패 = 남은 스크롤 드랍, 중단
            remaining -= count;
        }
        return;
    }
    // non-alt: scrollViewport를 reader에 위임.
    self.enqueueCoreCommandForSurface(surface.id, .{ .scroll = @as(isize, lines) }) catch {};
    self.metal_dirty = true;
}

pub fn scrollbarVisibleTicks(self: *const AppSession) u32 {
    return self.ticksForMs(scrollbar_visible_ms);
}

pub fn scrollbarFadeTicks(self: *const AppSession) u32 {
    return self.ticksForMs(scrollbar_fade_ms);
}

pub fn scrollbarFadeCompleteTicks(self: *const AppSession) u32 {
    return scrollbarVisibleTicks(self) + scrollbarFadeTicks(self);
}

/// 드래그 자동 스크롤 한 스텝(frame-loop tick마다). 드래그가 grid 밖에 머무는 동안 한 줄씩
/// 스크롤하며 선택을 가장자리 행으로 확장한다 — 화면보다 긴 내용을 드래그로 선택하는 표준 UX.
pub fn applyDragAutoscroll(self: *AppSession) void {
    if (self.drag_autoscroll == 0) {
        self.drag_autoscroll_accum_ms = 0; // 드래그가 grid 안으로 돌아옴 — 다음 진입이 새로 누적 시작
        return;
    }
    // **frame rate 무관 속도**: 옛날엔 tick마다 한 줄이라 기본이 30→60Hz로 오르며 자동 스크롤이 2배(120Hz면
    // 4배) 빨라졌다. tick 수가 아니라 경과 ms로 게이트해 항상 ≈30줄/s를 유지한다 — msPerTick 누적이 step_ms를
    // 넘을 때만 한 줄. frame-rate_min=30이라 msPerTick≤step_ms → tick당 최대 한 줄(저rate에서도 과속 없음).
    self.drag_autoscroll_accum_ms += self.msPerTick();
    if (self.drag_autoscroll_accum_ms < drag_autoscroll_step_ms) return;
    self.drag_autoscroll_accum_ms -= drag_autoscroll_step_ms;
    const surface = term_ops.activeSurface(self);
    const core = &surface.core;
    // selection_anchor/view_offset/selection_head 읽기 + scrollViewport/selectionExtend(코어 변경)는 리더
    // core.write와 경합 — 메서드 전체를 락 아래(docs/io-render-threading.md PR3). 짧은 메서드라 락 비용 무시 가능;
    // 함수가 metal_dirty 직후 끝나므로 함수-스코프 defer로 풀어 early return도 안전히 unlock.
    // 게이트("확장할 선택이 있는가") + grid rows는 코어 read(메인 락-아래 — 읽기는 위임 안 함, §9.1).
    // mouse_drag_selecting로 걸면 더블/트리플클릭(4/5)으로 시작한 선택을 드래그로 화면 밖까지 늘릴 때 자동
    // 스크롤이 영원히 안 걸린다.
    const rows: u16 = blk: {
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        if (core.selection_anchor == null) return; // 확장할 선택 없음
        break :blk core.size.rows;
    };
    const row: u16 = if (self.drag_autoscroll > 0) 0 else rows - 1;
    // scroll+extend는 full (a)(docs/plans/io-render-threading.md §9 P3-4)로 reader에 위임 — **kind-2 드래그 extend와
    // 같은 명령 큐를 타 순서 보존**(둘이 다른 스레드면 선택이 어긋날 수 있다). 원래의 "변화 시만 재투영" 최적화는
    // reader 렌더 트리거로 대체한다(스크롤백 끝에서 포인터를 grid 밖에 둘 때 cheap render tick 몇 개 — §9 trade-off).
    self.enqueueCoreCommandForSurface(surface.id, .{ .scroll_and_extend = .{ .delta = @as(isize, self.drag_autoscroll), .row = row, .col = self.last_drag_col } }) catch {};
}

pub fn scrollPage(self: *AppSession, delta_pages: i32) void {
    // [4e-2, §6·1-B] 활성 Term이 web이면 스크롤 대상 없음(sentinel) — no-op(scroll과 동형).
    if (!self.surface_initialized or !term_ops.activeTermIsTerminal(self)) return;
    const rows = term_ops.activeSurface(self).core.size.rows;
    const page: i32 = @max(@as(i32, 1), @as(i32, rows) - 1);
    scrollLines(self, delta_pages *| page);
}

/// #5b: 호버 중인 ‹/› 스크롤 버튼을 갱신한다. 바뀌면 재드로우(버튼이 밝아져 클릭 가능 표시). 같으면 무동작.
pub fn setHoveredScroll(self: *AppSession, s: ?ScrollRef) void {
    const same = (self.hovered_scroll == null and s == null) or
        (self.hovered_scroll != null and s != null and self.hovered_scroll.?.pane == s.?.pane and self.hovered_scroll.?.right == s.?.right);
    if (same) return;
    self.hovered_scroll = s;
    self.metal_dirty = true;
}

/// #5a: 우측 가로 스크롤 ‹/› 버튼의 사각형 배경(GpuQuad layer 2) — col 셀(‹=tab_cols, ›=tab_cols+2) 영역을 약한
/// 배경으로 채워 "클릭 가능한 버튼"으로 보이게 한다. glyph는 coretext가 같은 col에 그린다(배경 위). hover 색은 #5b, 커서는 #5c.
pub fn appendScrollButtonQuad(self: *AppSession, m: chrome.components.tabbar.Metrics, col: u32, bg: u32) void {
    const x: f32 = @floatFromInt(m.bar_x + col * m.cell_width_px);
    self.appendSolidQuad(x, @floatFromInt(m.bar_y), @floatFromInt(m.cell_width_px), @floatFromInt(m.bar_h), bg, 2);
}

/// 스크롤바 thumb 기하(보이는 영역 내 y offset·높이, backing px) — 순수 함수라 단위 테스트 가능. sb_count==0
/// (스크롤백 없음)·메트릭 0이면 null(안 그림). thumb 높이=보이는 비율(view/(sb+view)), 최소 높이로 clamp.
/// y: view_offset 0(바닥)이면 view_h-thumb_h(아래), sb_count(꼭대기)면 0(위) — 위로 스크롤할수록 thumb가 올라간다.
pub fn scrollbarThumbGeom(sb_count: usize, view_offset: usize, cell_height_px: u32, view_h_px: u32) ?struct { y: f32, h: f32 } {
    if (sb_count == 0 or cell_height_px == 0 or view_h_px == 0) return null;
    const ch: f32 = @floatFromInt(cell_height_px);
    const sb_px: f32 = @as(f32, @floatFromInt(sb_count)) * ch; // 스크롤백 총 높이(px)
    const view_px: f32 = @floatFromInt(view_h_px); // 보이는 높이
    const min_thumb: f32 = @max(view_px * 0.04, 18.0);
    var thumb_h: f32 = view_px * view_px / (sb_px + view_px);
    if (thumb_h < min_thumb) thumb_h = min_thumb;
    if (thumb_h > view_px) thumb_h = view_px;
    const t: f32 = if (sb_px > 0) @as(f32, @floatFromInt(view_offset)) * ch / sb_px else 0; // 0..1
    return .{ .y = (view_px - thumb_h) * (1.0 - t), .h = thumb_h };
}

/// 드래그 위치 t(0=트랙 바닥, 1=꼭대기)를 view_offset으로 매핑 — scrollbarThumbGeom의 `t = view_offset/sb_count`
/// 역(逆). [0,1]로 clamp 후 round해 [0,sb_count] 정수 offset. 순수 함수라 단위 테스트 가능.
pub fn scrollbarTargetOffset(t: f64, sb_count: usize) usize {
    var tt = t;
    if (tt < 0) tt = 0;
    if (tt > 1) tt = 1;
    return @intFromFloat(@round(tt * @as(f64, @floatFromInt(sb_count))));
}

/// 스크롤바 thumb 폭(px) — cell_width 비율, 최소 px 보장. emphasized(hover/드래그)면 +emphasize_px로 굵게.
/// appendScrollbar(그리기)·scrollbarGrabAt(hit-test)가 공유해 폭이 어긋나지 않게 한다(순수 함수 — 테스트 가능).
pub fn scrollbarBarWidthPx(cell_width_px: u32, emphasized: bool) f32 {
    const base = @max(@as(f32, @floatFromInt(cell_width_px)) * scrollbar_bar_mul, scrollbar_bar_min_px);
    return if (emphasized) base + scrollbar_bar_emphasize_px else base;
}

/// idle 틱에 따른 스크롤바 alpha(0xAARRGGBB의 A). visible_ticks까지 full, 이어 fade_ticks 동안 full→idle로
/// 선형 감쇠, 이후 idle(faint) 유지(숨기지 않음). 순수 함수 — 테스트 가능. hover/드래그 override는 호출처에서.
pub fn computeScrollbarAlpha(idle_ticks: u32) u8 {
    return computeScrollbarAlphaFor(idle_ticks, default_scrollbar_visible_ticks, default_scrollbar_fade_ticks);
}

pub fn computeScrollbarAlphaFor(idle_ticks: u32, visible_ticks: u32, fade_ticks: u32) u8 {
    if (idle_ticks <= visible_ticks) return scrollbar_alpha_full;
    if (idle_ticks >= visible_ticks + fade_ticks) return scrollbar_alpha_idle;
    const into: u32 = idle_ticks - visible_ticks; // 1..fade_ticks-1
    const drop: u32 = @as(u32, scrollbar_alpha_full - scrollbar_alpha_idle) * into / fade_ticks;
    return @intCast(@as(u32, scrollbar_alpha_full) - drop);
}

pub fn scrollbarAlpha(self: *const AppSession, idle_ticks: u32) u8 {
    return computeScrollbarAlphaFor(idle_ticks, scrollbarVisibleTicks(self), scrollbarFadeTicks(self));
}

/// 마우스가 스크롤바 영역에 있는지 갱신(hoverCursor가 매 이동 호출). 바뀌면 redraw 표시 — hover 강조가
/// 곧바로 나타나거나 사라지게. fade 리셋(idle_ticks=0)은 updateScrollbarFade가 hover를 보고 한다.
pub fn setScrollbarHovered(self: *AppSession, on: bool) void {
    if (self.scrollbar_hovered == on) return;
    self.scrollbar_hovered = on;
    self.metal_dirty = true;
}

/// 매 tick 스크롤바 fade를 갱신한다(updateCursorBlink와 같은 frame-loop tick). 한 곳에서 활성 surface의 view_offset
/// 변화를 감지해(스크롤·드래그·page-key·surface 전환) idle_ticks를 0(full)으로 리셋하고, hover/드래그면 full로
/// 핀, 그 외엔 매 tick 늘려 fade 창에서 alpha가 바뀔 때만 metal_dirty를 세운다(idle 정착 후엔 정적 — 비용 0).
pub fn updateScrollbarFade(self: *AppSession) void {
    if (!self.surface_initialized) return;
    const visible_ticks = scrollbarVisibleTicks(self);
    const fade_done_ticks = scrollbarFadeCompleteTicks(self);
    // 활성 탭의 모든 pane을 순회해 각자 fade를 갱신한다(per-pane — pane 목록만 보면 되고 rect/layout 불요라
    // 매 tick 싸다). 활성 pane은 hover/드래그면 full로 핀. 한 pane이라도 alpha가 바뀌면 metal_dirty.
    const active_pane = pane_ops.activePane(self);
    for (tab_ops.activeTab(self).panes.items) |pane| {
        const psurface = pane.activeTerm().surface;
        // scrollbackLen(리더 core.write가 증가)·viewOffset 스칼라를 락 아래 한 번에 읽는다
        // (docs/io-render-threading.md PR3). 비-const 메서드라 락 가능.
        psurface.lockCore(self.io);
        const scroll_state = scrollStateOf(psurface);
        psurface.unlockCore(self.io);
        const sb_len = scroll_state.scrollback_len;
        const vo = scroll_state.view_offset;
        if (sb_len == 0) {
            // 스크롤바 없음 — 다음 등장이 full로 시작하게 타이머 리셋(0→nonzero 전환).
            pane.scrollbar_idle_ticks = 0;
            pane.scrollbar_last_view_offset = 0;
            continue;
        }
        if (vo != pane.scrollbar_last_view_offset) { // 이 pane 스크롤 활동 → full로 복귀
            pane.scrollbar_last_view_offset = vo;
            if (pane.scrollbar_idle_ticks != 0) self.metal_dirty = true;
            pane.scrollbar_idle_ticks = 0;
            continue;
        }
        if (pane == active_pane and (self.scrollbar_hovered or self.pointerGestureIs(.scrollbar))) { // 활성 pane 상호작용 — full 핀
            if (pane.scrollbar_idle_ticks != 0) {
                pane.scrollbar_idle_ticks = 0;
                self.metal_dirty = true;
            }
            continue;
        }
        if (pane.scrollbar_idle_ticks >= fade_done_ticks) continue; // faint 정착 — 정적
        pane.scrollbar_idle_ticks += 1;
        if (pane.scrollbar_idle_ticks > visible_ticks) self.metal_dirty = true; // fade 창 — alpha 변함
    }
    // 사이드바 스크롤바 fade(단일 트랙 — pane과 동형). 스크롤 활동은 offset 변화로 감지(휠/clamp가 바꾼다).
    // 스크롤 불필요(max 0)면 다음 등장이 full로 시작하게 타이머·last를 리셋한다.
    if (sidebar_ops.sidebarMaxScroll(self) == 0) {
        self.sidebar_scrollbar_idle_ticks = fade_done_ticks; // faint 정착(안 보임)
        self.sidebar_scrollbar_last_offset = self.sidebar_scroll_offset_px;
    } else if (self.sidebar_scroll_offset_px != self.sidebar_scrollbar_last_offset) { // 스크롤 활동 → full 복귀
        self.sidebar_scrollbar_last_offset = self.sidebar_scroll_offset_px;
        if (self.sidebar_scrollbar_idle_ticks != 0) self.metal_dirty = true;
        self.sidebar_scrollbar_idle_ticks = 0;
    } else if (self.sidebar_scrollbar_idle_ticks < fade_done_ticks) {
        self.sidebar_scrollbar_idle_ticks += 1;
        if (self.sidebar_scrollbar_idle_ticks > visible_ticks) self.metal_dirty = true; // fade 창 — alpha 변함
    }
    if (dock_ops.dockListScrollbarGeometry(self) == null) {
        self.dock_list_scrollbar_idle_ticks = fade_done_ticks;
        self.dock_list_scrollbar_last_offset_px = file_panel_ops.fileTreeEffectiveScrollPx(self);
    } else if (file_panel_ops.fileTreeEffectiveScrollPx(self) != self.dock_list_scrollbar_last_offset_px) {
        self.dock_list_scrollbar_last_offset_px = file_panel_ops.fileTreeEffectiveScrollPx(self);
        if (self.dock_list_scrollbar_idle_ticks != 0) self.metal_dirty = true;
        self.dock_list_scrollbar_idle_ticks = 0;
    } else if (self.dock_list_scrollbar_hovered or scrollbarCaptureActive(self)) {
        if (self.dock_list_scrollbar_idle_ticks != 0) self.metal_dirty = true;
        self.dock_list_scrollbar_idle_ticks = 0;
    } else if (self.dock_list_scrollbar_idle_ticks < fade_done_ticks) {
        self.dock_list_scrollbar_idle_ticks += 1;
        if (self.dock_list_scrollbar_idle_ticks > visible_ticks) self.metal_dirty = true;
    }
}

/// down 좌표가 활성 pane 스크롤바(thumb 또는 트랙)에 있으면 잡은 grab offset(y_px - thumb_top, px)을 돌려준다.
/// thumb 위면 그 offset(드래그가 thumb 내 상대 위치를 유지), thumb 밖 트랙이면 thumb_h/2(클릭 지점에 thumb
/// 중앙을 맞춰 점프). 스크롤백 없음·메트릭 0·영역 밖이면 null. x 영역은 thumb 폭 + 좌측 4px 여유(잡기 쉽게),
/// y는 트랙(pane) 전체. appendScrollbar와 같은 bar_w(cell_width*0.32, 최소 5)·우측 2px 안쪽 배치를 쓴다.
/// 스크롤바 thumb 계산에 쓰는 스크롤 상태. **화면 소유자를 묻지 않는다** — `renderSnapshot()`이 로컬은 core에서,
/// host-backed는 host가 wire로 보낸 값에서 같은 필드를 채우기 때문이다(중립 DTO). 예전엔 호출처들이
/// `core.scrollbackLen()`을 직접 읽어 원격에선 항상 0이었고(placeholder), 그래서 스크롤백이 쌓여도 스크롤바가
/// 뜨지 않았다. **호출자가 lockCore를 보유해야 한다**(snapshot이 소스 메모리를 alias — 스칼라만 읽고 복사).
pub fn scrollStateOf(surface: *maru.session.Surface) struct { scrollback_len: usize, view_offset: usize } {
    const snap = surface.renderSnapshot();
    return .{ .scrollback_len = snap.scrollback_len, .view_offset = snap.view_offset };
}

pub fn scrollbarGrabAt(self: *const AppSession, x_px: f64, y_px: f64) ?f32 {
    const rect = self.active_pane_rect;
    if (rect.w == 0 or self.cell_width_px == 0) return null;
    // 호출자(hoverCursor·mouse)가 락 밖에서 부르는 hit-test라 **여기서 잡는다** — `scrollStateOf`의 계약이
    // "호출자가 lockCore 보유"다. 옛 주석은 "스칼라 두 개뿐이라 괜찮다"고 적었지만 그 판단은 계약이 할 몫이고,
    // 원격 backing이면 이 락이 곧 RemoteScreen mutex라 delta-apply와의 직렬화가 실제로 필요하다.
    const grab_surface = term_ops.activeSurface(
        @constCast(self),
    );
    const scroll_state = blk: {
        grab_surface.lockCore(self.io);
        defer grab_surface.unlockCore(self.io);
        break :blk scrollStateOf(grab_surface);
    };
    const geom = scrollbarThumbGeom(scroll_state.scrollback_len, scroll_state.view_offset, self.cell_height_px, rect.h) orelse return null;
    // thumb가 트랙을 꽉 채워 스크롤 여지가 없으면(track<=0, degenerate 작은 pane) 잡지 않는다 — 안 그러면
    // 클릭을 캡처하고도 dragScrollbarTo가 무동작이라 선택도 스크롤도 안 되는 dead zone이 된다.
    if (geom.h >= @as(f32, @floatFromInt(rect.h))) return null;
    // hit-test는 base 폭(비-emphasized) + 4px 여유 — hover로 굵어진 폭이 아니라 안정된 base로 잡는다.
    const bar_w: f64 = scrollbarBarWidthPx(self.cell_width_px, false);
    const right: f64 = @floatFromInt(rect.x + rect.w);
    const zone_left: f64 = right - bar_w - 2.0 - 4.0; // thumb 좌단(우측 2px 안쪽) - 4px grab 여유
    if (x_px < zone_left or x_px > right) return null;
    const top: f64 = @floatFromInt(rect.y);
    const bottom: f64 = top + @as(f64, @floatFromInt(rect.h));
    if (y_px < top or y_px > bottom) return null;
    const thumb_top: f64 = top + @as(f64, geom.y);
    const grab: f64 = y_px - thumb_top;
    if (grab >= 0 and grab <= @as(f64, geom.h)) return @floatCast(grab); // thumb 위 — 상대 위치 유지
    return geom.h * 0.5; // 트랙 — thumb 중앙을 클릭에 맞춤(점프)
}

/// 드래그/트랙-점프 중 마우스 y로 view_offset을 절대 설정한다. new_thumb_top(view 내) = (y_px - rect.y) - grab을
/// [0, track]로 clamp(track = view_h - thumb_h), t = 1 - thumb_top/track(0=바닥, 1=꼭대기), target =
/// scrollbarTargetOffset(t, sb_count). 현재 viewOffset과의 차이만큼 scrollViewport(절대 위치 → 상대 delta).
pub fn dragScrollbarTo(self: *AppSession, y_px: f64) void {
    const grab: f64 = switch (self.pointer_gesture_owner) {
        .scrollbar => |drag| drag.grab,
        else => return,
    };
    const rect = self.active_pane_rect;
    if (rect.h == 0 or self.cell_height_px == 0) return;
    // 코어 읽기(scrollbackLen·viewOffset)는 락 아래(§9.1). scrollViewport mutate는 **락 밖에서** reader에 위임
    // (full (a)) — 락을 잡은 채 enqueueCoreCommand하면 non-interactive 폴백이 같은 core_mutex를 재취득해 재진입
    // (panic/deadlock). 그래서 읽기만 락에 가두고, enqueue는 락 해제 후 한다(다른 위임 사이트와 같은 규율).
    const surface = term_ops.activeSurface(self);
    const snap = blk: {
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        break :blk scrollStateOf(surface);
    };
    const total_sb = snap.scrollback_len;
    if (total_sb == 0) return;
    // thumb_h는 view_offset과 무관(sb_count·ch·view_h만) — 현재 offset으로 구해도 .h는 안정적.
    const geom = scrollbarThumbGeom(total_sb, snap.view_offset, self.cell_height_px, rect.h) orelse return;
    const view_px: f64 = @floatFromInt(rect.h);
    const track: f64 = view_px - @as(f64, geom.h); // thumb_top 가동 범위
    if (track <= 0) return; // thumb가 트랙을 꽉 채움 — 스크롤 여지 없음
    var thumb_top: f64 = (y_px - @as(f64, @floatFromInt(rect.y))) - grab;
    if (thumb_top < 0) thumb_top = 0;
    if (thumb_top > track) thumb_top = track;
    const t: f64 = 1.0 - thumb_top / track; // 0=바닥(offset 0), 1=꼭대기(offset sb_count)
    const target = scrollbarTargetOffset(t, total_sb);
    // 절대 목표를 reader에 위임(scroll_to_offset) — reader가 적용 시점의 fresh view_offset에서 delta 계산
    // (메인이 delta를 미리 빼면 연속 드래그가 옛 base로 double-count돼 어긋남).
    if (target != snap.view_offset) {
        self.enqueueCoreCommandForSurface(surface.id, .{ .scroll_to_offset = target }) catch {};
        self.metal_dirty = true;
    }
}

/// 팔레트 스크롤바를 **공용 발행 경로**로 낸다(SV5b). 컴포넌트가 자기 막대를 그리는 대신 host가
/// `tree.scrollArea`를 선언하고 `ui_paint`+`chrome_draw_lowering`이 quad로 내린다 — 도크·탐색기·
/// 소스 컨트롤·사이드바와 같은 막대가 된다.
///
/// **offset은 저장된 값이 아니다.** 팔레트는 창을 selected에서 매번 재파생하므로 그 파생값을 픽셀로
/// 환산해 쓴다(`win_start × ch`). 그래서 이 슬라이스는 스크롤 상태를 만들지 않는다.
/// 세팅 폼 목록 우측 막대(SV5c). 팔레트와 **같은 발행 저장소**를 쓴다 — 오버레이는 한 번에 하나만
/// 열리므로 둘이 동시에 살아 있을 일이 없다.
///
/// 팔레트와 다른 점은 뷰포트를 **컴포넌트가 준다**(`settings.scrollView`)는 것이다. 세팅은 폼 폭이
/// nav·control·↺ 여백에 얽혀 있어 host가 다시 계산하면 두 벌이 갈린다.
pub fn appendSettingsScrollbar(self: *AppSession, view: chrome.components.settings.ScrollView) void {
    const ch = self.cell_height_px;
    if (ch == 0 or view.visible == 0 or view.total <= view.visible) return;
    appendOverlayScrollbar(self, view.viewport, .{
        .offset_px = @as(u32, @intCast(view.win_start)) * ch,
        .content_h_px = @as(u32, @intCast(view.total)) * ch,
    });
}

pub fn appendOverlayScrollbar(self: *AppSession, viewport: chrome.draw.Rect, extent: OverlayScrollExtent) void {
    if (viewport.w == 0 or viewport.h == 0) return;

    var entries: [overlay_scroll_max_entries]chrome.ui.tree.RectEntry = undefined;
    var items: [overlay_scroll_max_entries]chrome.ui.layout.Item = undefined;
    var flex: [overlay_scroll_max_entries]chrome.ui.layout.FlexScratch = undefined;
    var child_rects: [overlay_scroll_max_entries]chrome.ui.layout.UiRect = undefined;

    const metrics: chrome.ui.scroll_area.ScrollbarMetrics = .{
        .width_px = overlay_scrollbar_width_px,
        .inset_x_px = overlay_scrollbar_inset_px,
        .min_thumb_px = overlay_scrollbar_min_thumb_px,
    };
    const node = chrome.ui.tree.scrollArea(.{
        .id = overlay_scroll_ids.area,
        .scroll = .{
            .offset_px = extent.offset_px,
            .content_h_px = extent.content_h_px,
            .gutter_px = @floatFromInt(metrics.width_px + metrics.inset_x_px),
            .metrics = metrics,
            // thumb을 누른 것 자체가 스크롤 의사라 threshold는 0이다. track도 같은 payload를 선언해
            // 눌러 점프한 뒤 손을 떼지 않고 이어 끌 수 있다(도크·사이드바와 같은 규율).
            .drag = .{ .payload = dock_list_scroll_drag_payload, .axis = .vertical, .threshold_px = 0 },
            .track = .{ .id = overlay_scroll_ids.track, .action = .{ .id = overlay_scroll_ids.track }, .paint = .{ .background = .surface_bg } },
            .thumb = .{ .id = overlay_scroll_ids.thumb, .action = .{ .id = overlay_scroll_ids.thumb }, .paint = .{ .background = .muted_fg, .corner_radii_px = .{ overlay_scrollbar_width_px / 2, overlay_scrollbar_width_px / 2, overlay_scrollbar_width_px / 2, overlay_scrollbar_width_px / 2 } } },
        },
    }, &.{});

    const built = chrome.ui.tree.build(node, .{
        .root_size = .{ .width = @floatFromInt(viewport.w), .height = @floatFromInt(viewport.h) },
        .max_entries = overlay_scroll_max_entries,
        .max_depth = 2,
    }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &flex,
        .child_rects = &child_rects,
    }) catch return;

    self.overlay_scroll_generation +|= 1;
    for (built.entries, 0..) |entry, i| {
        var moved = entry;
        moved.rect.x += @floatFromInt(viewport.x);
        moved.rect.y += @floatFromInt(viewport.y);
        if (moved.effective_clip) |*clip| {
            clip.x += @floatFromInt(viewport.x);
            clip.y += @floatFromInt(viewport.y);
        }
        self.overlay_scroll_entries[i] = moved;
    }
    self.overlay_scroll_entry_count = built.entries.len;

    const snapshot: chrome.ui.tree.UiRectTree = .{
        .entries = self.overlay_scroll_entries[0..self.overlay_scroll_entry_count],
        .generation = self.overlay_scroll_generation,
    };
    var ops: [overlay_scroll_max_entries]chrome.draw.Op = undefined;
    const tokens = self.buildChromeTokens();
    const draws = chrome.ui.paint.paint(snapshot, .{}, &tokens, .sidebar, .{ .ops = &ops }) catch return;
    // over(3) — 모달 배경 quad(layer 1)와 같은 버킷이라 **발행 순서**가 z를 정한다. 이 함수를
    // 오버레이 lowering **뒤에** 부르는 것이 그 규약이다(SV5b에서 앞에 뒀다가 배경에 덮였다).
    // SV6b: 오버레이 배경과 **같은 대기 버퍼**로 낸다. 배경 뒤에 놓여야 막대가 보이는 관계는 버퍼 안에서
    // 그대로 유지되고, 버퍼 전체가 프레임 끝에 flush돼 뒤늦은 터미널 장식(sticky 구분선)보다 위에 남는다.
    chrome_draw_lowering.appendBackgroundQuads(self.allocator, &.{draws}, &tokens, 0, 0, &self.overlay_quads, 3);
}

/// 오버레이 위 휠(SV5d). 팔레트·세팅은 원래 휠이 **없었다** — 목록이 열려 있는데 뒤 터미널이 굴러
/// 가는 것이 위화감이라, 축이 있으면 델타가 0이어도 소비한다(사이드바 휠과 같은 규율).
pub fn scrollOverlayByLines(self: *AppSession, lines: i64) bool {
    if (self.chrome_host.palette.open) {
        const ch = @max(self.cell_height_px, 1);
        const total = self.palette_filtered.items.len;
        const visible = @min(total, chrome.components.palette.max_visible);
        if (total <= visible or visible == 0) return true; // 안 넘침 — 소비만
        const max_offset: u32 = @intCast((total - visible) * ch);
        if (self.palette_scroll.scrollByPx(-lines * @as(i64, ch), max_offset)) self.metal_dirty = true;
        return true;
    }
    if (self.chrome_host.settings.open) {
        // 상한은 **직전 프레임이 캐시한 창**에서 얻는다 — 여기서 labels·fields를 다시 빌드하면 휠
        // 한 틱마다 arena 작업이 붙는다. 한 프레임 늦은 상한은 다음 layout이 clamp하므로 안전하다.
        const sv = self.settings_scroll_view orelse return true; // 안 넘침 — 소비만
        const ch = @max(self.cell_height_px, 1);
        const max_offset: u32 = @intCast((sv.total -| sv.visible) * ch);
        if (self.chrome_host.settings.scroll.scrollByPx(-lines * @as(i64, ch), max_offset)) self.metal_dirty = true;
        return true;
    }
    return false;
}

pub fn overlayScrollbarGeometry(self: *const AppSession) ?chrome.ui.scroll_area.ScrollbarGeometry {
    var track: ?chrome.ui.layout.UiRect = null;
    var thumb: ?chrome.ui.layout.UiRect = null;
    for (self.overlay_scroll_entries[0..self.overlay_scroll_entry_count]) |entry| {
        if (entry.id == overlay_scroll_ids.track) track = entry.rect;
        if (entry.id == overlay_scroll_ids.thumb) thumb = entry.rect;
    }
    const t = track orelse return null;
    const h = thumb orelse return null;
    // 잡는 자리(hit)는 tree에 안 실린다 — entry에는 그린 rect만 담긴다. 거터 폭으로 역산해 채운다.
    const bar: chrome.ui.scroll_area.ScrollbarGeometry = .{
        .track_x = t.x,
        .track_y = t.y,
        .track_w = t.width,
        .track_h = t.height,
        .hit_x = t.x,
        .hit_w = t.width,
        .thumb_y = h.y,
        .thumb_h = h.height,
        .max_offset_px = overlayMaxOffsetPx(self),
    };
    return bar.withHitSpan(@floatFromInt(overlay_scrollbar_width_px + overlay_scrollbar_inset_px));
}

/// 지금 열린 오버레이의 스크롤 상한(px). 발행된 막대와 **같은 시점의 값**이라야 드래그가 손가락과 안 어긋난다.
pub fn overlayMaxOffsetPx(self: *const AppSession) u32 {
    const ch = @max(self.cell_height_px, 1);
    if (self.chrome_host.palette.open) {
        const total = self.palette_filtered.items.len;
        const visible = @min(total, chrome.components.palette.max_visible);
        return @intCast((total -| visible) * ch);
    }
    if (self.settings_scroll_view) |sv| return @intCast((sv.total -| sv.visible) * ch);
    return 0;
}

/// 드래그가 낸 offset을 **지금 열린 오버레이**에 적용한다. 소유자가 갈리면 보이지 않는 목록이 스크롤된다.
pub fn setOverlayScrollOffsetPx(self: *AppSession, offset_px: u32) void {
    const clamped = @min(offset_px, overlayMaxOffsetPx(self));
    if (self.chrome_host.palette.open) {
        if (clamped == self.palette_scroll.offset_y_px) return;
        self.palette_scroll.offset_y_px = clamped;
    } else if (self.chrome_host.settings.open) {
        if (clamped == self.chrome_host.settings.scroll.offset_y_px) return;
        self.chrome_host.settings.scroll.offset_y_px = clamped;
    } else return;
    self.metal_dirty = true;
}

/// 오버레이 스크롤바를 잡는다(SV5d). 도크·사이드바와 **같은 타입**(`scroll_area.Drag`)을 쓰고 태그만 다르다.
pub fn beginOverlayScrollbarGesture(self: *AppSession, x_px: f64, y_px: f64) bool {
    const geometry = overlayScrollbarGeometry(self) orelse return false;
    if (!geometry.trackContains(x_px, y_px)) return false;
    if (self.dock_list_scroll_drag.begin(geometry, x_px, y_px)) |jumped| setOverlayScrollOffsetPx(self, jumped);
    const snapshot: chrome.ui.tree.UiRectTree = .{
        .entries = self.overlay_scroll_entries[0..self.overlay_scroll_entry_count],
        .generation = self.overlay_scroll_generation,
    };
    if (snapshot.entries.len == 0) return false;
    _ = chrome.ui.interaction.dispatch(&self.scrollbar_interaction, snapshot, .{
        .phase = .down,
        .x_px = x_px,
        .y_px = y_px,
        .timestamp_ns = 0,
        .generation = snapshot.generation,
    }) catch return false;
    if (self.scrollbar_interaction.capture == null) {
        self.dock_list_scroll_drag.end();
        return false;
    }
    self.pointer_gesture_owner = .none;
    self.scrollbar_drag_target = .overlay;
    self.metal_dirty = true;
    return true;
}

/// capture가 살아 있는 동안의 move/up(오버레이). 사이드바 경로와 같은 형태 — carry key는 고정값이고
/// "같은 막대를 계속 잡고 있는가"는 기하 비교가 판정한다(오버레이는 한 번에 하나만 열린다).
pub fn routeOverlayScrollbarCapture(self: *AppSession, kind: i32, y_px: f64) bool {
    const snapshot: chrome.ui.tree.UiRectTree = .{
        .entries = self.overlay_scroll_entries[0..self.overlay_scroll_entry_count],
        .generation = self.overlay_scroll_generation,
    };
    if (snapshot.entries.len == 0) {
        endScrollbarCapture(self);
        return true;
    }
    const live = overlayScrollbarGeometry(self) orelse {
        endScrollbarCapture(self);
        return true;
    };
    if (!file_panel_ops.fileTreeScrollbarSameSnapshot(self.dock_list_scroll_drag.geometry, live)) {
        endScrollbarCapture(self);
        return true;
    }
    const key = chrome.ui.interaction.GestureCompatibility{
        .kind = dock_list_scroll_drag_payload,
        .enabled = true,
        .owner_epoch = 0,
        .domain_identity = 0,
    };
    _ = chrome.ui.interaction.reconcileCarryingCapture(&self.scrollbar_interaction, snapshot, key, key) catch {
        endScrollbarCapture(self);
        return true;
    };
    if (self.scrollbar_interaction.capture == null) {
        endScrollbarCapture(self);
        return true;
    }
    const dispatched = chrome.ui.interaction.dispatch(&self.scrollbar_interaction, snapshot, .{
        .phase = if (kind == 2) .move else .up,
        .x_px = @as(f64, self.dock_list_scroll_drag.geometry.track_x) + @as(f64, self.dock_list_scroll_drag.geometry.track_w) / 2,
        .y_px = y_px,
        .timestamp_ns = 0,
        .button = .left,
        .generation = snapshot.generation,
    }) catch {
        endScrollbarCapture(self);
        return true;
    };
    if (dispatched.drag) |event| switch (event) {
        .began, .moved => |update| {
            self.dock_list_scroll_drag.absorb(update.x_px, update.y_px);
            self.scrollbar_move_events +|= 1;
        },
        .dropped => |update| {
            self.dock_list_scroll_drag.absorb(update.x_px, update.y_px);
            applyPendingScrollbarScroll(self);
            endScrollbarCapture(self);
        },
        .cancelled => endScrollbarCapture(self),
    };
    if (kind == 3) endScrollbarCapture(self);
    return true;
}

pub fn appendPaletteScrollbar(self: *AppSession) void {
    if (!self.chrome_host.palette.open) return;
    const lay = chrome.components.overlay_input.panelLayout(self.buildChromeProps()) orelse return;
    const total = self.palette_filtered.items.len;
    const visible = @min(total, chrome.components.palette.max_visible);
    if (total <= visible or visible == 0) return; // 안 넘침 — 막대 없음
    const max_offset: u32 = @intCast((total - visible) * lay.ch);
    // 목록 영역은 프롬프트 줄(row0) **아래**다 — 그 줄은 스크롤에서 고정이므로 트랙도 그 아래에서 시작한다.
    appendOverlayScrollbar(self, .{
        .x = lay.x,
        .y = lay.y + @as(i32, @intCast(lay.ch)),
        .w = lay.panel_cols * lay.cw,
        .h = @as(u32, @intCast(visible)) * lay.ch,
    }, .{
        .offset_px = @min(self.palette_scroll.offset_y_px, max_offset),
        .content_h_px = @as(u32, @intCast(total)) * lay.ch,
    });
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

pub const wheelDeltaToLines = input_math.wheelDeltaToLines;

// 드래그 자동 스크롤이 한 줄 더 스크롤하기까지의 간격(ms) — frame rate와 무관하게 일정 속도(≈30줄/s)를 유지하려고
// tick 수가 아니라 경과 ms로 게이트한다. 옛 30Hz 1틱/줄(≈33ms/줄)과 같은 체감 속도를 기준으로 잡았다. msPerTick
// 누적이 이 값을 넘을 때마다 한 줄 스크롤한다(render.frame-rate_min=30이라 msPerTick≤이 값 → tick당 최대 한 줄).
pub const drag_autoscroll_step_ms: u32 = 33;

// 스크롤바 thumb 폭(굵기). cell_width의 비율, 최소 px 보장. hover/드래그면 +emphasize_px로 살짝 굵게(affordance).
pub const scrollbar_bar_mul: f32 = 0.5; // cell_width 대비 폭 비율(굵게 — 잡기/보기 쉽게)

pub const scrollbar_bar_min_px: f32 = 7.0; // 작은 폰트에서도 최소 두께

pub const scrollbar_bar_emphasize_px: f32 = 2.0; // hover/드래그 시 추가 폭

pub const scrollbar_alpha_idle: u8 = 0x4D; // idle(faint) — ~30%

/// 오버레이(팔레트·세팅·알림) 스크롤바가 쓰는 id·저장소(SV5b). 오버레이는 **한 번에 하나만 열리므로**
/// 발행 저장소를 셋이 공유한다 — SV3b가 탐색기↔소스 컨트롤에서 쓴 것과 같은 근거다(도크·사이드바와는
/// 조건이 다르다. 그 둘은 동시에 화면에 있어 저장소를 나눠야 했다).
pub const overlay_scroll_ids = struct {
    pub const area: chrome.ui.tree.UiId = 0x4F56_0001;
    pub const track: chrome.ui.tree.UiId = 0x4F56_0002;
    pub const thumb: chrome.ui.tree.UiId = 0x4F56_0003;
};

pub const overlay_scrollbar_min_thumb_px: u32 = dock_list_scrollbar_min_thumb_px;
