//! 디버그·스모크 픽스처 하네스 — `MARU_*` 환경변수로 UI 상태를 강제해 캡처/검증 시나리오를 만든다.
//!
//! **제품 로직이 아니다.** 첫 프레임에 세팅을 열거나(`maybeDebugOpenSettings`) 파일 패널을 여는
//! (`maybeDebugOpenFilePanel`) 것으로 시작했지만, 지금은 사이드바 접힘·가짜 브랜치·그룹 상태·드래그
//! 고스트·알림 배지 같은 상태를 **40개가 넘는 환경변수 게이트**로 강제하는 시나리오 하네스다.
//!
//! `app_session.zig`에서 뺀 이유는 크기(598줄)보다 **성격**이다 — 제품 경로를 읽는 사람이 이 분량의
//! 디버그 스캐폴딩을 지나야 했다. ABI가 직접 부르므로 진입점은 허브에 얇은 facade로 남는다.
//!
//! 이름이 `maybeDebug*`인 것은 각 게이트가 **환경변수가 없으면 즉시 반환**하기 때문이다. 제품 실행에서는
//! 첫 프레임에 플래그 검사 몇 번으로 끝난다.

const std = @import("std");
const editor_ops = @import("editor.zig");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const settings_ops = @import("settings.zig");
const DropPlan = AppSession.DropPlan;
const dock_ops = @import("dock.zig"); // 캡처 게이트가 도크 content 원점을 창 좌표로 옮길 때 쓴다
const scm_dock_ops = @import("scm_dock.zig");
const sidebar_ops = @import("sidebar.zig");
const tab_ops = @import("tab.zig");
const term_ops = @import("term.zig");
const notification_ops = @import("notification.zig");
const pane_ops = @import("pane.zig");
const find_ops = @import("find.zig");
const git_ops = @import("git.zig");
const image_gallery_ops = @import("image_gallery.zig"); // MARU_FORCE_IMAGE_GALLERY 가 갤러리를 첫 frame 에 세울 때 쓴다

/// 시각 확인 디버그 훅 — MARU_OPEN_SETTINGS env가 설정됐고 surface가 준비됐으면 세팅 화면을 한 번 자동으로 연다.
/// 스크린샷 하니스(MARU_SCREENSHOT)가 입력 없이 모달 상태를 캡처하도록(self-verify). env 미설정이면 무동작 —
/// 일반 실행/계약엔 영향 없다(MARU_DEBUG와 같은 env-gate). 매 frame 호출되지만 한 번만 연다(debug_settings_opened).
pub fn maybeDebugOpenSettings(self: *AppSession) void {
    if (self.debug_settings_opened) return;
    if (!self.surface_initialized) return;
    self.debug_settings_opened = true;
    // MARU_RUN_INSTALL_CLI=1 — "Install CLI" 명령을 첫 frame에 실행해 결과 notice를 캡처(self-verify debug-gate).
    if (std.c.getenv("MARU_RUN_INSTALL_CLI") != null) self.installCli();
    // MARU_FORCE_SPLIT=1 — 첫 frame에 활성 pane을 좌우로 한 번 분할해 비활성 split pane 디밍(window.unfocused-dim,
    // F2-7)을 헤드리스 스크린샷으로 캡처(self-verify debug-gate). 분할 후 활성은 새 pane이라 반대쪽이 비활성=디밍 대상.
    // 빈 셸은 첫 content frame까지 프롬프트가 안 와 디밍할 글자가 없으므로, 양쪽 pane core에 같은 SGR 샘플 줄을
    // 직접 써 넣어(리더와 경합하니 락 아래) 활성(풀 밝기) vs 비활성(디밍)을 한 화면에서 대비시킨다.
    // MARU_FORCE_NOTIFICATIONS=<n> — 안 읽은 알림 n개를 첫 frame에 넣어 상태바 우측 항목(종 + 개수)과
    // **좌우 충돌 규칙**(우측을 먼저 지키고 좌측을 뒤에서부터 버린다)을 헤드리스 스크린샷으로 검증한다
    // (self-verify debug-gate — MARU_FORCE_SPLIT과 같은 성격). 알림은 셸 관측과 무관해 첫 frame에 세울 수
    // 있다 — 브랜치·경로는 OSC 7이 아직 안 와 캡처로 못 보는 것과 대비된다.
    // MARU_FORCE_AGENT=1 — 활성 Term의 에이전트 상태를 running으로 세워 상태바 우측 에이전트 항목과
    // **우측 항목 순서**(에이전트가 더 오른쪽, 알림이 그 왼쪽)를 헤드리스로 검증한다. 실제 상태는 셸 화면을
    // 관측해 정해지므로(pollAgentKinds) 첫 frame엔 절대 서지 않는다 — 그래서 훅이 필요하다.
    // MARU_FORCE_STATUS_HOVER=<항목> — 그 항목에 포인터가 얹힌 것처럼 호버를 세워 헤드리스로 찍는다
    // (self-verify debug-gate). 실제 호버는 마우스 이동이 필요해 스크린샷으로는 못 만든다.
    if (std.c.getenv("MARU_FORCE_STATUS_HOVER")) |raw| {
        const name = std.mem.span(raw);
        self.status_bar_hovered = if (std.mem.eql(u8, name, "notifications"))
            .notifications
        else if (std.mem.eql(u8, name, "agents"))
            .running_agents
        else if (std.mem.eql(u8, name, "blocked"))
            .blocked_agents
        else if (std.mem.eql(u8, name, "cwd"))
            .cwd
        else
            null;
    }
    // MARU_FORCE_BLOCKED=1 — 활성 Term을 blocked로 세워 상태바 blocked 항목을 헤드리스로 찍는다.
    // MARU_FORCE_IMAGE_GALLERY=<트랜스크립트 절대경로> — 도크를 갤러리 뷰로 열고 활성 Term 의 소스를
    // 그 파일로 세운다. **실제 픽셀을 헤드리스로 찍기 위한 유일한 길**이다 — 갤러리 소스는 provider 훅이
    // 채우는데, 첫 frame 에는 훅이 아직 한 번도 안 돌았다(MARU_FORCE_AGENT 가 필요한 것과 같은 이유).
    if (std.c.getenv("MARU_FORCE_IMAGE_GALLERY")) |raw| {
        const path = std.mem.span(raw);
        const t = pane_ops.activePane(self).activeTerm();
        if (t.agent_image_source.set(path)) {
            dock_ops.openDockTo(self, .image_gallery);
            image_gallery_ops.refresh(self, true);
            // MARU_FORCE_IMAGE_GALLERY_OPEN=<n> — 그 칸을 크게 연다. 실제 열기는 클릭이라 헤드리스로는
            // 만들 수 없고(마우스가 없다), 스캔이 워커라 지금은 인덱스가 비어 있다 — 그래서 예약만 한다.
            if (std.c.getenv("MARU_FORCE_IMAGE_GALLERY_OPEN")) |raw_n| {
                self.debug_image_gallery_open = std.fmt.parseInt(usize, std.mem.span(raw_n), 10) catch null;
            }
            if (std.c.getenv("MARU_FORCE_IMAGE_GALLERY_HOVER")) |raw_n| {
                self.debug_image_gallery_hover = std.fmt.parseInt(usize, std.mem.span(raw_n), 10) catch null;
            }
        }
    }
    if (std.c.getenv("MARU_FORCE_BLOCKED") != null) {
        const t = pane_ops.activePane(self).activeTerm();
        t.agent_state = .blocked;
        t.agent_kind = .claude;
    }
    if (std.c.getenv("MARU_FORCE_AGENT") != null) {
        const t = pane_ops.activePane(self).activeTerm();
        t.agent_state = .running;
        t.agent_kind = .claude;
    }
    reapplyForcedAgentStates(self);
    if (std.c.getenv("MARU_FORCE_NOTIFICATIONS")) |raw| {
        const want = std.fmt.parseInt(usize, std.mem.span(raw), 10) catch 1;
        var i: usize = 0;
        while (i < @min(want, 99)) : (i += 1) {
            _ = notification_ops.pushNotificationHistory(self, "MARU", "self-verify", 0);
        }
    }
    // MARU_FORCE_SIDEBAR_CARDS=<n> — 워크스페이스 카드를 n개까지 늘려 사이드바 콘텐츠가 뷰포트(헤더 아래 ~
    // 상태바 위)를 넘치게 만든다. 아래 호버 픽스처와 짝이다: 경계를 넘는 카드가 있어야 "뷰포트 밖으로 샜나"가
    // 화면에 나타난다. 상한은 캡처 편의상 32(각 카드가 실제 PTY를 띄우므로 무한정 늘리지 않는다).
    if (std.c.getenv("MARU_FORCE_SIDEBAR_CARDS")) |raw| {
        const want = @min(std.fmt.parseInt(usize, std.mem.span(raw), 10) catch 1, 32);
        while (self.tabs.items.len < want) _ = tab_ops.newTab(self) catch break;
        sidebar_ops.rebuildSidebar(self) catch {};
    }
    // MARU_FORCE_SIDEBAR_SCROLL=<px|max> — 사이드바를 그만큼 굴려 둔 것처럼 만든다. 스크롤은 휠 이벤트라
    // 캡처 하니스로 도달할 수 없는데, **스크롤 중에만 걸리는 클립 분기**(셀 상단 scissor)가 있어 그 상태의
    // 헤더 밑줄·아이콘 호버가 살아남는지 볼 수단이 필요했다. `max`는 끝까지 굴린다.
    if (std.c.getenv("MARU_FORCE_SIDEBAR_SCROLL")) |raw| {
        const spec = std.mem.span(raw);
        const max = sidebar_ops.sidebarMaxScroll(self);
        self.sidebar_scroll_offset_px = if (std.mem.eql(u8, spec, "max"))
            max
        else
            @min(std.fmt.parseInt(u32, spec, 10) catch 0, max);
        sidebar_ops.rebuildSidebar(self) catch {};
    }
    // MARU_FORCE_SIDEBAR_HOVER=<슬롯 인덱스|edge|last> — 그 카드 슬롯에 포인터가 얹힌 것처럼 호버 밴드를 세운다.
    // 여기서 한 번 세우고 **매 tick 다시 세운다**(reapplyForcedSidebarHover) — 이유는 그 함수 주석에 있다.
    reapplyForcedSidebarHover(self);
    // MARU_FORCE_STICKY=1 — 첫 frame에 sticky 명령 배너를 세운다(SV6b 시각 검증). 실제로는 OSC 133 마크가 붙은
    // 명령 출력이 스크롤백을 채우고 사용자가 위로 굴려야 나타나므로(`core.stickyCommand`: view_offset>0 +
    // 위쪽에 `.input` 행) 캡처로는 절대 만들 수 없다 — 그래서 훅이 필요하다.
    //
    // 이 배너의 **하단 구분선은 layer 3 GPU quad**이고 좌표가 `placeAndDistribute` 산물이라 오버레이보다 늦게
    // 발행된다. SV6b 전에는 그 순서 때문에 열린 오버레이 위에 선이 그어졌다 — `MARU_OPEN_NOTIFICATIONS`와 함께
    // 쓰면 그 장면이 한 화면에 잡힌다.
    if (std.c.getenv("MARU_FORCE_STICKY") != null) {
        const surface = term_ops.activeSurface(self);
        surface.lockCore(self.io);
        // OSC 133로 명령줄(.input) 한 줄을 마킹하고, 그 뒤에 출력 줄을 뷰포트보다 많이 흘려 스크롤백을 채운다.
        surface.core.write("\x1b]133;A\x1b\\\x1b]133;B\x1b\\$ zig build test\r\n\x1b]133;C\x1b\\") catch {};
        var i: usize = 0;
        while (i < 60) : (i += 1) surface.core.write("output line\r\n") catch {};
        // 위로 굴려 명령줄을 화면 밖으로 보낸다 — 그래야 배너가 그것을 대신 보여준다.
        surface.core.scrollViewport(30); // 양수 = 위(과거)로
        surface.unlockCore(self.io);
    }
    // MARU_FORCE_WRAP_SEARCH=1 — 자동 줄바꿈을 **2셀 글자가 마지막 한 칸에 못 들어가** 일어나게 만든 뒤,
    // 그 경계를 걸친 검색어로 Find를 연다. 그 자리에 남는 칸은 터미널이 만든 wrap 채움이라 글자가 아닌데,
    // 그것을 공백으로 세면 검색어가 끊겨 **0건**이 된다(수정 전 동작). 리사이즈·타이핑·검색창 입력이 필요해
    // 캡처만으로는 만들 수 없는 상태라 여기서 강제한다(self-verify debug-gate — MARU_FORCE_SPLIT과 같은 성격).
    if (std.c.getenv("MARU_FORCE_WRAP_SEARCH") != null) {
        const surface = pane_ops.activePane(self).activeTerm().surface;
        surface.lockCore(self.io);
        const cols = surface.core.size.cols;
        // 마지막 한 칸만 남기고 채운다 → 다음 2셀 글자가 통째로 다음 줄로 밀린다.
        var col: u16 = 0;
        while (col + 1 < cols) : (col += 1) surface.core.write("a") catch {};
        surface.core.write("가나다 wrap 경계를 걸친 검색") catch {};
        surface.unlockCore(self.io);

        // 검색어 "a가" — 마지막 'a'와 다음 줄 '가' 사이를 걸친다. 그 사이의 wrap 채움을 공백으로 세면 안 잡힌다.
        self.chrome_host.find.show();
        self.chrome_host.find.input.appendChar(self.allocator, 'a') catch {};
        self.chrome_host.find.input.appendChar(self.allocator, '\u{AC00}') catch {};
        find_ops.recomputeFind(self);
    }
    if (std.c.getenv("MARU_FORCE_SPLIT") != null) {
        pane_ops.splitActivePane(self, .horizontal) catch {};
        for (tab_ops.activeTab(self).panes.items) |pane| {
            const surface = pane.activeTerm().surface;
            surface.lockCore(self.io);
            surface.core.write("\x1b[97mMARU\x1b[0m \x1b[91mred\x1b[0m \x1b[92mgreen\x1b[0m \x1b[44m bg \x1b[0m") catch {};
            surface.unlockCore(self.io);
        }
    }
    // MARU_FORCE_GROUP=1 — 첫 frame에 워크스페이스 3개를 만들고 두 번째 탭에 그룹 시작 마커를 얹어, 사이드바에
    // **최상위 카드(t0) + 그룹 헤더(삼각 ▾ + 이름) + 그룹 안 카드(t1·t2, 들여쓰기)**를 헤드리스 스크린샷으로
    // self-verify한다(SG3c 헤더 렌더·가변 높이 세로 위치·들여쓰기). MARU_FORCE_GROUP_COLLAPSED=1이면 그 그룹을 접어
    // "▸ 이름 (N)" 접힘 헤더(카드 숨김·짧아진 사이드바)를 캡처. 일반 실행엔 영향 없다(env-gate).
    if (std.c.getenv("MARU_FORCE_GROUP") != null) {
        _ = tab_ops.newTab(self) catch {};
        _ = tab_ops.newTab(self) catch {}; // [t0, t1, t2]
        if (self.tabs.items.len >= 2) {
            tab_ops.createGroupAbsorbForTab(self, self.tabs.items[1]); // t0=최상위, t1·t2=그룹
            if (std.c.getenv("MARU_FORCE_GROUP_COLLAPSED") != null) self.tabs.items[1].group_collapsed = true;
            // SG5-2: MARU_FORCE_GROUP_COLOR=1이면 그 그룹에 파랑(0x4A7BC4)을 얹어 헤더 밴드 tint·소속 카드 좌측
            // accent 막대에 그룹 색이 뜨는지 헤드리스 스크린샷으로 self-verify(브라우저 탭 그룹식 색 구분).
            if (std.c.getenv("MARU_FORCE_GROUP_COLOR") != null) self.tabs.items[1].group_color = 0x4A7BC4;
            sidebar_ops.rebuildSidebar(self) catch {};
        }
    }
    // MARU_FORCE_GROUP_PIN=1 — 그룹 고정 C2(§12.8·§12.10 GP4)를 헤드리스 스크린샷으로 self-verify한다. 최상위 카드 t0을
    // **개별 고정**하고 두 형제 그룹 A=[t1,t2]·B=[t3,t4]를 만든 뒤 **A만 그룹째 고정**(toggleGroupPin)해 한 화면에서:
    //   (a) 고정 그룹 A가 **상단 프리픽스**(t0 뒤)로 이동(tab_ops.stablePartitionPinned), (b) A 멤버 카드에 **📌 노이즈 없음**
    //   (pin_derived 억제·마커 카드 억제), (c) A 헤더에 **고정 인디케이터 📌**(sidebarRowShowsPin)을 낸다. 대조로 **개별
    //   고정 t0 카드는 📌 유지**(그룹 멤버 억제와 구별), **비고정 그룹 B**는 헤더 인디케이터 없음·멤버 📌 없음이다.
    //   GP1~3 실제 경로(createGroup·createSiblingGroup·개별 pin·toggleGroupPin)로 canonical 상태를 만들어 정규화·프리픽스
    //   정렬도 함께 검증된다(GP4(a) 헤드리스 테스트와 동형 배치). MARU_FORCE_GROUP_COLLAPSED=1이면 A를 접어 헤더만(멤버
    //   숨김), MARU_FORCE_GROUP_COLOR=1이면 A·B에 색을 얹는다. env-gate라 일반 실행엔 영향 없다.
    if (std.c.getenv("MARU_FORCE_GROUP_PIN") != null) {
        var made: usize = 0;
        while (made < 4) : (made += 1) _ = tab_ops.newTab(self) catch {}; // [t0..t4]
        if (self.tabs.items.len >= 5) {
            // 두 형제 최상위 그룹: A=[t1,t2](마커 t1, depth1), B=[t3,t4](마커 t3, depth1). t0는 고정 최상위 카드(개별 pin 대조).
            tab_ops.createGroupAbsorbForTab(self, self.tabs.items[1]); // A
            tab_ops.createSiblingGroupAbsorbForTab(self, self.tabs.items[3]); // B(형제, depth1)
            if (std.c.getenv("MARU_FORCE_GROUP_COLLAPSED") != null) self.tabs.items[1].group_collapsed = true; // A 접힘 → 헤더만
            if (std.c.getenv("MARU_FORCE_GROUP_COLOR") != null) {
                self.tabs.items[1].group_color = 0x4A7BC4; // A 파랑
                self.tabs.items[3].group_color = 0xC44A7B; // B 자홍(대조)
            }
            self.tabs.items[0].pinned = true; // t0 = 고정 최상위 카드(개별 pin — 그룹 고정과 직교, 📌 유지 대조)
            // A 마커 포인터는 heap-pin이라 toggleGroupPin의 stablePartition 재배치 후에도 안정 — 토글 전에 잡는다.
            const a_marker = self.tabs.items[1];
            tab_ops.toggleGroupPin(self, a_marker); // A를 그룹째 고정 → 프리픽스로 안착·멤버 pin 동기(§12.10 GP3)
            sidebar_ops.rebuildSidebar(self) catch {};
        }
    }
    // MARU_FORCE_GROUP_NESTED=1 — 첫 frame에 2단계 중첩(A>B)을 만들어 헤드리스 스크린샷으로 다단계 들여쓰기·중첩
    // 헤더·접기를 self-verify한다(SG5-3). 구조: [t0(최상위), t1=그룹 A(depth1), t2(A 카드), t3=그룹 B(depth2, A 안 중첩),
    // t4(B 카드)]. B는 A 안 카드(t3)에서 create_group을 부르므로 위치 파생으로 depth 2 자식 그룹이 된다.
    // MARU_FORCE_GROUP_COLLAPSED=1이면 부모 A를 접어 자식 B까지 통째 숨김을 캡처. env-gate라 일반 실행엔 영향 없다.
    if (std.c.getenv("MARU_FORCE_GROUP_NESTED") != null) {
        var made: usize = 0;
        while (made < 4) : (made += 1) _ = tab_ops.newTab(self) catch {}; // [t0..t4]
        if (self.tabs.items.len >= 5) {
            tab_ops.createGroupAbsorbForTab(self, self.tabs.items[1]); // 그룹 A(depth 1) — t1·t2 소속
            tab_ops.createGroupAbsorbForTab(self, self.tabs.items[3]); // t3은 A 안(depth1 카드)이라 새 그룹 B는 depth 2(중첩)
            if (std.c.getenv("MARU_FORCE_GROUP_COLLAPSED") != null) self.tabs.items[1].group_collapsed = true; // 부모 접기 → 자식 통째 숨김
            if (std.c.getenv("MARU_FORCE_GROUP_COLOR") != null) {
                self.tabs.items[1].group_color = 0x4A7BC4; // A 파랑
                self.tabs.items[3].group_color = 0xC44A7B; // B 자홍(중첩 색 구분)
            }
            sidebar_ops.rebuildSidebar(self) catch {};
        }
    }
    // MARU_FORCE_GROUP_DRAGNEST=1 — 두 형제 그룹 A·B를 만든 뒤 **A를 B의 헤더에 드롭한 결과**(중첩 넣기, SG5-4)를
    // 재투영으로 고정해 헤드리스 스크린샷으로 시각 확인한다(드래그 라이브 대신 드롭 결과 상태). 결과: B가 최상위,
    // A가 B의 자식(depth2)으로 들어가 A 카드가 한 단계 더 들여쓰인다. env-gate라 일반 실행엔 영향 없다.
    if (std.c.getenv("MARU_FORCE_GROUP_DRAGNEST") != null) {
        var made: usize = 0;
        while (made < 4) : (made += 1) _ = tab_ops.newTab(self) catch {}; // [t0..t4]
        if (self.tabs.items.len >= 5) {
            // 두 형제 최상위 그룹: A=[t1,t2](depth1), B=[t3,t4](depth1). t0는 최상위 카드.
            tab_ops.createGroupAbsorbForTab(self, self.tabs.items[1]); // A
            tab_ops.createSiblingGroupAbsorbForTab(self, self.tabs.items[3]); // B(형제, depth1)
            // A(마커 index1)를 B 헤더에 드롭 = 중첩. B 헤더 row를 찾아 groupNestPlan→tab_ops.moveGroupNesting(드롭 결과 재현).
            tab_ops.recomputeVisibleTabs(self);
            var b_row: usize = 0;
            for (self.sidebar_rows.items, 0..) |row, s| switch (row) {
                .group_header => |gh| if (gh.tab == 3) {
                    b_row = s;
                },
                .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => {},
                .card => {},
            };
            if (tab_ops.groupNestPlan(self, b_row, 1)) |plan| {
                _ = tab_ops.moveGroupNesting(self, 1, plan.insert_before, plan.target_depth);
            }
            sidebar_ops.rebuildSidebar(self) catch {};
        }
    }
    // MARU_FORCE_GROUP_DRAGGHOST=1 — 첫 frame에 **카드를 접힌 그룹으로 드래그 중인 프리뷰 상태**(SG8d 고스트)를 강제해
    // 헤드리스 스크린샷으로 시각 확인한다: 최상위 카드 t0(그대로) + 접힌 그룹 A(헤더가 펼침으로 flip) + **반투명 고스트
    // 카드 t1(삽입선과 함께)**이 그룹 A 안에 떠 "접힌 그룹에 넣어도 고스트가 안 사라짐"을 보인다(§9 SG8 핵심 UX). 라이브
    // 드래그가 아니라 refreshDragPreview로 프리뷰 상태만 세우고 놔둬(up 없음) 첫 frame을 캡처한다. env-gate라 일반 실행 영향 없음.
    if (std.c.getenv("MARU_FORCE_GROUP_DRAGGHOST") != null) {
        var made: usize = 0;
        while (made < 3) : (made += 1) _ = tab_ops.newTab(self) catch {}; // [t0..t3]
        if (self.tabs.items.len >= 4) {
            // t0·t1 최상위, A=[t2,t3](마커 t2, depth1) 접힘. drag t1 → 접힌 A 안(§9 SG8 접힌 그룹 드롭).
            tab_ops.createGroupAbsorbForTab(self, self.tabs.items[2]); // 그룹 A(마커 index2) — t2·t3 소속
            self.tabs.items[2].group_collapsed = true; // 접힘(헤더만, t3 숨김)
            tab_ops.recomputeVisibleTabs(self); // rows: [card t0(0), card t1(1), header A collapsed(2)]
            // hit-test: t1(origin=1)을 접힌 A 헤더(row2)에 드롭 → 그룹 끝 자리(sidebarGroupDropTargetTab). 그 plan을 프리뷰.
            const raw_row: usize = 2; // 접힌 A 헤더 표시 row
            if (tab_ops.sidebarGroupDropTargetTab(self, raw_row, 1)) |target_tab| {
                var arena_state = std.heap.ArenaAllocator.init(self.allocator);
                defer arena_state.deinit();
                self.pointer_gesture_owner = .{ .sidebar_tab = .{ .index = 1 } };
                tab_ops.refreshDragPreview(self, 1, .{ .card = .{ .target_tab = target_tab } }, 0, arena_state.allocator()) catch {};
            }
            sidebar_ops.rebuildSidebar(self) catch {}; // 렌더가 preview_rows로 고스트+삽입선을 그린다
        }
    }
    // MARU_FORCE_GROUP_DRAGGHOST_GROUP=1 — **그룹 A를 다른 그룹 B의 헤더에 드래그 중인 프리뷰 상태**(SG8e subtree 고스트)를
    // 강제한다: A subtree(헤더 t1 + 카드 t2)가 반투명 고스트로 **B 자식 depth**(한 단계 더 들여쓰기)에 떠 "폴더 안에 넣기"를
    // 보인다(카드 1행 고스트와 달리 그룹은 헤더+카드 연속 N행). MARU_FORCE_GROUP_COLLAPSED=1이면 B를 접어도 프리뷰 투영이
    // 타겟 헤더를 collapsed=false로 flip해 고스트가 보인다(§9 SG8 접힌 그룹 드롭 UX). 라이브 커밋 대신 refreshDragPreview로
    // 프리뷰만 세우고 놔둬(up 없음) 첫 frame을 캡처한다(self.tabs 불변). MARU_FORCE_GROUP_COLOR=1이면 A·B에 색을 얹어
    // 고스트+헤더 밴드 색을 함께 확인. **MARU_FORCE_GROUP_DRAGGHOST_SIBLING=1**이면 같은 setup에서 plan을 **형제**(group_sibling,
    // Cmd 없는 드래그)로 바꿔 "삽입선만"(중첩 없음·하이라이트 없음) 시각을 캡처한다 — Cmd 중첩 vs 일반 형제 스크린샷 비교용.
    // env-gate라 일반 실행엔 영향 없다.
    if (std.c.getenv("MARU_FORCE_GROUP_DRAGGHOST_GROUP") != null) {
        var made: usize = 0;
        while (made < 4) : (made += 1) _ = tab_ops.newTab(self) catch {}; // [t0..t4]
        if (self.tabs.items.len >= 5) {
            // 두 형제 최상위 그룹: A=[t1,t2](마커 index1, depth1), B=[t3,t4](마커 index3, depth1). t0는 최상위 카드.
            tab_ops.createGroupAbsorbForTab(self, self.tabs.items[1]); // A
            tab_ops.createSiblingGroupAbsorbForTab(self, self.tabs.items[3]); // B(형제, depth1)
            if (std.c.getenv("MARU_FORCE_GROUP_COLLAPSED") != null) self.tabs.items[3].group_collapsed = true; // B 접힘 → 고스트도 보임(flip)
            if (std.c.getenv("MARU_FORCE_GROUP_COLOR") != null) {
                self.tabs.items[1].group_color = 0x4A7BC4; // A 파랑
                self.tabs.items[3].group_color = 0xC44A7B; // B 자홍(중첩 색 구분)
            }
            tab_ops.recomputeVisibleTabs(self); // rows에서 B 헤더 표시 row를 찾는다
            var b_row: usize = 0;
            for (self.sidebar_rows.items, 0..) |row, s| switch (row) {
                .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => {},
                .group_header => |gh| if (gh.tab == 3) {
                    b_row = s;
                },
                .card => {},
            };
            // A(마커 index1)를 B 헤더(b_row)에 드롭. 기본 = 중첩(Cmd 눌린 프리뷰 = group_nest, 타깃 하이라이트+들여쓴 고스트).
            // MARU_FORCE_GROUP_DRAGGHOST_SIBLING=1이면 = 형제(Cmd 없는 프리뷰 = group_sibling, 삽입선만) — 두 시각을 스크린샷 비교.
            const plan: DropPlan = if (std.c.getenv("MARU_FORCE_GROUP_DRAGGHOST_SIBLING") != null) blk_plan: {
                const boundary = sidebar_ops.sidebarGroupDropBoundary(self, b_row, 1) orelse break :blk_plan .none;
                break :blk_plan .{ .group_sibling = .{ .insert_before = self.clampGroupMoveToRegion(1, boundary) } };
            } else if (tab_ops.groupNestPlan(self, b_row, 1)) |np|
                .{ .group_nest = .{ .insert_before = np.insert_before, .target_depth = np.target_depth } }
            else
                .none;
            var arena_state = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_state.deinit();
            self.pointer_gesture_owner = .{ .sidebar_group = .{ .phase = .dragging, .marker = 1, .slot = b_row, .down_y = 0 } };
            tab_ops.refreshDragPreview(self, 1, plan, 0, arena_state.allocator()) catch {};
            sidebar_ops.rebuildSidebar(self) catch {}; // 렌더가 preview_rows로 A subtree 고스트+삽입선을 그린다
        }
    }
    // MARU_FORCE_GROUP_LOCALPIN=1 — 그룹-로컬 pin(GL §13.6 렌더·§13.7 위생)을 헤드리스 스크린샷으로 self-verify한다.
    // [t0(최상위 카드), A=[t1(마커), t2, t3, t4]]를 만들고 **멤버 t3을 로컬 pin**(toggleLocalPin)해 한 화면에서:
    //   (a) t3이 그룹 A 내부 **상단**(마커 t1 직후)으로 float(tab_ops.stablePartitionSubtree), (b) t3 카드에 **📌**(sidebarRowShowsPin
    //   local_pinned 선두 분기), (c) 비pin 멤버 t2·t4는 그 **아래**·📌 없음, (d) 최상위 t0은 그룹 밖(로컬 pin과 무관).
    // MARU_FORCE_GROUP_LOCALPIN_GROUPPIN=1이면 A를 **그룹째 고정**도 해 **공존**(헤더 그룹📌 + 멤버 로컬📌, 단일 글리프
    // U+1F4CC 수용 §13.6) — 위치(헤더 vs 멤버 카드)로 구별된다. MARU_FORCE_GROUP_COLLAPSED=1이면 A 접힘(헤더만),
    // MARU_FORCE_GROUP_COLOR=1이면 A에 파랑. env-gate라 일반 실행엔 영향 없다.
    if (std.c.getenv("MARU_FORCE_GROUP_LOCALPIN") != null) {
        var made: usize = 0;
        while (made < 4) : (made += 1) _ = tab_ops.newTab(self) catch {}; // [t0..t4]
        if (self.tabs.items.len >= 5) {
            tab_ops.createGroupAbsorbForTab(self, self.tabs.items[1]); // A = [t1(마커), t2, t3, t4] — t0는 최상위 카드
            const t3 = self.tabs.items[3]; // 그룹 A의 (중간) 멤버 — heap-pin이라 float 재배치 후에도 안정
            tab_ops.toggleLocalPin(self, t3); // t3 로컬 pin → 마커 t1 직후(그룹 내 상단)로 float, 📌
            if (std.c.getenv("MARU_FORCE_GROUP_LOCALPIN_GROUPPIN") != null) {
                // 공존: A를 그룹째 고정(전역 프리픽스로 안착 — keystone §13.1로 subtree 내 로컬 float 순서 보존).
                const a_marker = self.tabs.items[1]; // 마커 heap-pin — toggleGroupPin의 stablePartition 후에도 안정
                tab_ops.toggleGroupPin(self, a_marker);
            }
            if (std.c.getenv("MARU_FORCE_GROUP_COLLAPSED") != null) self.tabs.items[1].group_collapsed = true; // A 접힘 → 헤더만
            if (std.c.getenv("MARU_FORCE_GROUP_COLOR") != null) self.tabs.items[1].group_color = 0x4A7BC4; // A 파랑
            sidebar_ops.rebuildSidebar(self) catch {};
        }
    }
    // MARU_FORCE_GROUP_LOCALPIN_NESTED=1 — 그룹-로컬 pin **중첩 배치**(GL §13.6.1·§13.8 GL4)를 헤드리스 스크린샷으로
    // self-verify한다. 2단계 중첩 [t0(최상위), A=[t1(마커 d1), t2(A 직접), B=[t3(마커 d2), t4, t5]]]에서 **A 직접 멤버
    // t2**와 **자식 subgroup B 안 leaf 멤버 t5**를 각각 로컬 pin해 한 화면에서:
    //   (a) t2가 A subtree 상단(A 마커 카드 위)으로 float·📌, (b) t5가 **B subtree 상단**(B 마커 카드 위)으로 float·📌
    //   (자식 그룹서도 마커 위 배치가 성립 — §13.6.1 재귀 동형), (c) 자식 float이 부모 밖으로 안 새고 I3 중첩 depth(A d1·
    //   B d2 들여쓰기)가 보존된다. floatLocalPinsAllGroups가 부모(A)→자식(B) 순차 스캔으로 둘 다 float(§13.4). GL2 실경로
    //   (createGroup 중첩·toggleLocalPin)로 canonical 상태를 만든다. MARU_FORCE_GROUP_COLOR=1이면 A 파랑·B 자홍(중첩 색 +
    //   로컬 pin 공존). env-gate라 일반 실행엔 영향 없다.
    if (std.c.getenv("MARU_FORCE_GROUP_LOCALPIN_NESTED") != null) {
        var made: usize = 0;
        while (made < 5) : (made += 1) _ = tab_ops.newTab(self) catch {}; // [t0..t5]
        if (self.tabs.items.len >= 6) {
            tab_ops.createGroupAbsorbForTab(self, self.tabs.items[1]); // A = [t1(마커 d1), t2, t3, t4, t5] — t0 최상위
            tab_ops.createGroupAbsorbForTab(self, self.tabs.items[3]); // t3은 A 안(d1 카드) → 자식 B(d2) = [t3, t4, t5], A 직접 = t2
            const t2 = self.tabs.items[2]; // A 직접 멤버(heap-pin — float 재배치 후에도 안정)
            const t5 = self.tabs.items[5]; // 자식 B leaf 멤버
            tab_ops.toggleLocalPin(self, t2); // A 직접 로컬 pin → A 마커 직후로 float, 📌
            tab_ops.toggleLocalPin(self, t5); // B leaf 로컬 pin → B 마커 직후로 float(자식 subtree 안), 📌
            if (std.c.getenv("MARU_FORCE_GROUP_COLOR") != null) {
                self.tabs.items[1].group_color = 0x4A7BC4; // A 파랑
                self.tabs.items[3].group_color = 0xC44A7B; // B 자홍(중첩 색 구분)
            }
            sidebar_ops.rebuildSidebar(self) catch {};
        }
    }
    // MARU_FORCE_INTERLEAVE=1 — §2.1 재설계(§14.5 SR3) "선택 탭만 그룹"을 헤드리스 스크린샷으로 self-verify한다. 워크스페이스
    // 4개 [t0,t1,t2,t3]에서 **t1만** 그룹으로 묶으면(프로덕션 createGroup — 다음 탭 t2에 top_level write) 사이드바에
    //   (a) 최상위 카드 t0, (b) 그룹 헤더 A + 그룹 안 카드 t1(들여쓰기, 배지 1), (c) **그룹 밖 최상위 카드 t2·t3**
    // (흡수 안 됨 — t2가 top_level 복귀 run 개시, t3은 sticky top-level)가 뜬다. 옛 흡수 동작이면 t2·t3이 그룹으로
    // 빨려들어갔을 것 — 인터리빙(그룹 뒤 최상위 카드 복귀)이 보이는지 대비 캡처. env-gate라 일반 실행엔 영향 없다.
    if (std.c.getenv("MARU_FORCE_INTERLEAVE") != null) {
        var made: usize = 0;
        while (made < 3) : (made += 1) _ = tab_ops.newTab(self) catch {}; // [t0..t3]
        if (self.tabs.items.len >= 4) {
            tab_ops.createGroupForTab(self, self.tabs.items[1]); // 선택 탭만 그룹(§14.5) — t1만 그룹, t2에 top_level write
            if (std.c.getenv("MARU_FORCE_GROUP_COLOR") != null) self.tabs.items[1].group_color = 0x4A7BC4; // A 파랑
            sidebar_ops.rebuildSidebar(self) catch {};
        }
    }
    // MARU_FORCE_SR4_DRAG=1 — §2.1 재설계(§14.6 SR4) **model-2 드래그 top_level 전이**를 헤드리스 스크린샷으로 self-verify한다.
    // 배치 [A(마커 t0), a1(t1,멤버), TOP1(t2,top_level 인터리브 top카드), X(t3, TOP1 뒤 sticky top)]에서 **X를 TOP1 옆(그룹 뒤
    // gap)으로 드래그 중인 프리뷰**(SG8d 고스트)를 강제한다: 반투명 고스트 카드 X가 **그룹 A 밖 최상위 depth 0**(들여쓰기 없음)
    // 으로 떠 "카드를 그룹 뒤로 끌면 최상위 복귀"(요구2)가 보인다. MARU_FORCE_SR4_DRAG_INTO=1이면 같은 setup에서 X를 **a1(멤버)
    // 옆**으로 드래그해 고스트가 **그룹 안 depth 1**(들여쓰기)로 떠 "그룹 안으로 끌면 멤버 흡수"를 대비 캡처한다. MARU_FORCE_GROUP_PIN=1
    // 이면 A·a1·TOP1·X를 고정해 **고정 탭↔고정 그룹 인터리빙**(고정 리전 안 top_level 전이·pin 유지)을 본다. 라이브 커밋 대신
    // refreshDragPreview로 프리뷰만 세우고 놔둬(up 없음) 첫 frame을 캡처한다(self.tabs 불변). env-gate라 일반 실행엔 영향 없다.
    if (std.c.getenv("MARU_FORCE_SR4_DRAG") != null) {
        var made: usize = 0;
        while (made < 3) : (made += 1) _ = tab_ops.newTab(self) catch {}; // [t0..t3]
        if (self.tabs.items.len >= 4) {
            self.tabs.items[0].group_start = self.allocator.dupe(u8, "A") catch null; // 그룹 A 마커
            self.tabs.items[0].group_depth = 1;
            self.tabs.items[2].top_level = true; // TOP1 = 그룹 뒤 인터리브 top카드
            if (std.c.getenv("MARU_FORCE_GROUP_PIN") != null) inline for (0..4) |i| {
                self.tabs.items[i].pinned = true; // 고정 리전 인터리빙
            };
            if (std.c.getenv("MARU_FORCE_GROUP_COLOR") != null) self.tabs.items[0].group_color = 0x4A7BC4;
            tab_ops.recomputeVisibleTabs(self);
            // 드래그: X(origin=3)를 타겟 row로. 기본=TOP1(그룹 뒤 gap→최상위 고스트), INTO=a1(그룹 안→멤버 고스트).
            const target_tab: usize = if (std.c.getenv("MARU_FORCE_SR4_DRAG_INTO") != null) 1 else 2;
            var into_row: usize = 0;
            for (self.sidebar_rows.items, 0..) |row, s| switch (row) {
                .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => {},
                .card => |c| if (c.tab == target_tab) {
                    into_row = s;
                },
                .group_header => {},
            };
            if (tab_ops.sidebarGroupDropTargetTab(self, into_row, 3)) |tt| {
                var arena_state = std.heap.ArenaAllocator.init(self.allocator);
                defer arena_state.deinit();
                self.pointer_gesture_owner = .{ .sidebar_tab = .{ .index = 3 } };
                tab_ops.refreshDragPreview(self, 3, .{ .card = .{ .target_tab = tt, .top_level = sidebar_ops.sidebarCardDropTopLevel(self, into_row) } }, 0, arena_state.allocator()) catch {};
            }
            sidebar_ops.rebuildSidebar(self) catch {}; // 렌더가 preview_rows로 고스트+삽입선(X의 최상위/멤버 depth)을 그린다
        }
    }
    // MARU_FORCE_GAP_DROP=1 — §2.1 재설계(§14.6 SR5 요구2) **"그룹 뒤 빈 gap" 첫 인터리브**를 헤드리스 스크린샷으로 self-verify한다.
    // 배치 [A(마커 t0), a1(t1,멤버), B(마커 t2), b1(t3,B 멤버)] — 인접 두 그룹 **사이에 top카드 없는 빈 gap**. b1을 A의
    // 마지막 멤버 a1 **아래 경계**로 드래그 중인 프리뷰(SG8d 고스트)를 강제한다: 고스트 b1이 **A·B 사이 최상위 depth 0**(들여쓰기
    // 없음)로 떠 "빈 gap에 첫 top카드 인터리브"(요구2 완성)가 보인다. 옛 SR4로는 그 자리에 기존 top카드가 있어야 드롭 타깃이
    // 잡혔다. plan은 sidebarCardDropAfterGroup의 결과(target=tab_ops.groupSubtreeEnd(A)=2, top_level=true)를 직접 굽는다(아래 경계
    // 판정 자체는 헤드리스 SR5(a)가 커버). MARU_FORCE_GROUP_COLLAPSED=1이면 A를 접어 접힌 헤더 뒤 gap을 캡처. env-gate라 일반 실행엔 영향 없다.
    if (std.c.getenv("MARU_FORCE_GAP_DROP") != null) {
        var made: usize = 0;
        while (made < 3) : (made += 1) _ = tab_ops.newTab(self) catch {}; // [t0..t3]
        if (self.tabs.items.len >= 4) {
            self.tabs.items[0].group_start = self.allocator.dupe(u8, "A") catch null;
            self.tabs.items[0].group_depth = 1;
            self.tabs.items[2].group_start = self.allocator.dupe(u8, "B") catch null;
            self.tabs.items[2].group_depth = 1;
            if (std.c.getenv("MARU_FORCE_GROUP_COLLAPSED") != null) self.tabs.items[0].group_collapsed = true; // A 접힘 → 접힌 헤더 뒤 gap
            if (std.c.getenv("MARU_FORCE_GROUP_COLOR") != null) {
                self.tabs.items[0].group_color = 0x4A7BC4; // A 파랑
                self.tabs.items[2].group_color = 0xB05CD6; // B 자홍
            }
            tab_ops.recomputeVisibleTabs(self);
            // b1(origin=3)을 A subtree 끝(그룹 밖 gap)에 top_level=true로 착지시키는 gap plan(from=3 >= j=2 → target=min(2,3)=2).
            const j = tab_ops.groupSubtreeEnd(self, 0, null, null);
            const target: usize = if (3 < j) j - 1 else @min(j, self.tabs.items.len - 1);
            var arena_state = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_state.deinit();
            self.pointer_gesture_owner = .{ .sidebar_tab = .{ .index = 3 } };
            tab_ops.refreshDragPreview(self, 3, .{ .card = .{ .target_tab = target, .top_level = true } }, 0, arena_state.allocator()) catch {};
            sidebar_ops.rebuildSidebar(self) catch {}; // 렌더가 preview_rows로 그룹 밖 top카드 고스트(depth 0)를 그린다
        }
    }
    // MARU_FORCE_SR5_3AXIS=1 — §14.7 SR5 **pin × local_pinned × top_level 3축 공존**을 헤드리스 스크린샷으로 self-verify한다.
    // 고정 리전 [A(마커,pin,d1), lp(pin,멤버,로컬📌), m1(pin,멤버), TOP(pin,top_level 고정 top카드), sticky(pin,sticky top)].
    // 헤더 그룹📌(A 고정 그룹으로도 만들면)·멤버 로컬📌(lp)·개별 top카드📌(TOP)가 위치로 구별돼 함께 뜬다. MARU_FORCE_GROUP_COLLAPSED=1이면
    // A 접힘(헤더만), MARU_FORCE_GROUP_COLOR=1이면 A 파랑, MARU_FORCE_GROUP_PIN=1이면 A도 그룹째 고정(헤더 인디케이터 추가). env-gate.
    if (std.c.getenv("MARU_FORCE_SR5_3AXIS") != null) {
        var made: usize = 0;
        while (made < 4) : (made += 1) _ = tab_ops.newTab(self) catch {}; // [t0..t4]
        if (self.tabs.items.len >= 5) {
            inline for (0..5) |i| self.tabs.items[i].pinned = true; // 고정 리전(I1 프리픽스)
            self.tabs.items[0].group_start = self.allocator.dupe(u8, "A") catch null;
            self.tabs.items[0].group_depth = 1;
            self.tabs.items[1].local_pinned = true; // 그룹-로컬 pin 멤버
            self.tabs.items[3].top_level = true; // 고정 top카드(그룹 뒤 인터리브)
            if (std.c.getenv("MARU_FORCE_GROUP_COLLAPSED") != null) self.tabs.items[0].group_collapsed = true;
            if (std.c.getenv("MARU_FORCE_GROUP_COLOR") != null) self.tabs.items[0].group_color = 0x4A7BC4;
            self.normalizePinnedFromGroups();
            self.floatLocalPinsAllGroups();
            self.clearStaleLocalPins();
            sidebar_ops.rebuildSidebar(self) catch {};
        }
    }
    // MARU_FORCE_SR5_NESTED_TOP=1 — §14.7 SR5 **중첩 안 top_level**(subgroup 뒤 top카드 = depth 0, 부모 복귀 없음)을 헤드리스
    // 스크린샷으로 self-verify한다. [A(마커,d1), a1(A 멤버,d1), B(마커,d2 중첩), b1(B 멤버,d2), TOP(top_level)]. TOP은 부모 A
    // depth 1로 복귀하지 못하고 **depth 0**(들여쓰기 없음)로 뜬다(sticky-reset은 항상 0으로만 되돌린다 — §14.7 제약 시각화).
    // MARU_FORCE_GROUP_COLOR=1이면 A 파랑·B 자홍(중첩 색). env-gate라 일반 실행엔 영향 없다.
    if (std.c.getenv("MARU_FORCE_SR5_NESTED_TOP") != null) {
        var made: usize = 0;
        while (made < 4) : (made += 1) _ = tab_ops.newTab(self) catch {}; // [t0..t4]
        if (self.tabs.items.len >= 5) {
            self.tabs.items[0].group_start = self.allocator.dupe(u8, "A") catch null;
            self.tabs.items[0].group_depth = 1;
            self.tabs.items[2].group_start = self.allocator.dupe(u8, "B") catch null;
            self.tabs.items[2].group_depth = 2; // 중첩 자식
            self.tabs.items[4].top_level = true; // subgroup B 뒤 top카드(부모 A 밖 depth 0)
            if (std.c.getenv("MARU_FORCE_GROUP_COLOR") != null) {
                self.tabs.items[0].group_color = 0x4A7BC4;
                self.tabs.items[2].group_color = 0xB05CD6;
            }
            sidebar_ops.rebuildSidebar(self) catch {};
        }
    }
    // MARU_FORCE_GROUP_TAB_SWAP=1 — §14.6 SR4 인터리빙 **그룹↔top_level 탭 순서 교환**(그룹 통째 드래그가 고정 top카드와
    // 자유 순서 교환)을 헤드리스 스크린샷으로 self-verify한다. 고정 리전 [X(t0, pin, top_level 탭), A=[a0(t1,pin,마커),
    // a1(t2,pin,멤버)]]에서 **그룹 A를 X 앞으로 드래그해 실제 커밋**하면 사이드바가 [그룹 A(헤더+a0·a1), 그 뒤 최상위 X]로
    // 순서 교환된다(X는 흡수 안 되고 top_level 최상위 유지·고정 유지). MARU_FORCE_GROUP_TAB_SWAP_BEFORE=1이면 드래그 전
    // 초기 순서 [탭 X, 그룹 A]를 그대로 렌더해 before/after를 대비 캡처한다. 커밋은 실제 groupDragPreviewFrame plan(sidebar
    // GroupDropBoundary + clampGroupMoveToRegion) + commitSidebarDragPreview 경로라 프로덕션 드래그와 동일하다. env-gate.
    if (std.c.getenv("MARU_FORCE_GROUP_TAB_SWAP") != null) {
        var made: usize = 0;
        while (made < 2) : (made += 1) _ = tab_ops.newTab(self) catch {}; // init 1개 + 2개 = [t0, t1, t2]
        if (self.tabs.items.len >= 3) {
            inline for (0..3) |i| self.tabs.items[i].pinned = true; // 고정 리전(고정 그룹↔고정 탭)
            self.tabs.items[0].top_level = true; // X = top_level 탭
            self.tabs.items[1].group_start = self.allocator.dupe(u8, "A") catch null; // 그룹 A 마커
            self.tabs.items[1].group_depth = 1;
            if (std.c.getenv("MARU_FORCE_GROUP_COLOR") != null) self.tabs.items[1].group_color = 0x4A7BC4; // A 파랑
            tab_ops.recomputeVisibleTabs(self);
            if (std.c.getenv("MARU_FORCE_GROUP_TAB_SWAP_BEFORE") == null) {
                // 그룹 A(마커 index1)를 X row 앞으로 드래그 확정 → [그룹 A, 탭 X].
                var x_row: usize = 0;
                for (self.sidebar_rows.items, 0..) |row, s| switch (row) {
                    .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => {},
                    .card => |c| if (c.tab == 0) {
                        x_row = s;
                    },
                    .group_header => {},
                };
                if (sidebar_ops.sidebarGroupDropBoundary(self, x_row, 1)) |boundary| {
                    const plan: DropPlan = .{ .group_sibling = .{ .insert_before = self.clampGroupMoveToRegion(1, boundary) } };
                    self.sidebar_drag_preview = .{ .origin = 1, .origin_len = tab_ops.groupSubtreeEnd(self, 1, null, null) - 1, .plan = plan, .cursor_y = 0, .ghost_lo = 0, .ghost_hi = 0 };
                    sidebar_ops.commitSidebarDragPreview(self);
                }
            }
            sidebar_ops.rebuildSidebar(self) catch {};
        }
    }
    // MARU_FORCE_RIGHT_CLICK=1 — 첫 frame에 터미널 본문 우클릭을 시뮬레이트해 input.right-click=menu의 복사/붙여넣기
    // 컨텍스트 메뉴 렌더를 헤드리스 스크린샷으로 캡처(self-verify debug-gate). 트래킹 .none(빈 셸)이라 config 분기를 탄다.
    // 좌표는 사이드바 우측 터미널 본문(x=400, y=150 backing px). menu가 아니면(paste/reporting) 메뉴 안 뜸 — 그것도 검증.
    if (std.c.getenv("MARU_FORCE_RIGHT_CLICK") != null) self.mouse(1, 400, 150, 2, 0);
    // MARU_FORCE_OSC52_READ=1 — 첫 frame에 활성 코어에 OSC 52 읽기 쿼리(`?`)를 흘려, osc52.read=allow면 다음 tick에
    // Swift가 시스템 클립보드를 읽어 base64 OSC 52 응답을 PTY로 보내는 전 경로를 self-verify(MARU_DEBUG=input 로그로
    // core->pty 응답 확인). deny면 응답 없음(그것도 검증). 클립보드 읽기는 락 아래(리더 경합 방지).
    if (std.c.getenv("MARU_FORCE_OSC52_READ") != null) {
        const s = term_ops.activeSurface(self);
        s.lockCore(self.io);
        s.core.write("\x1b]52;c;?\x1b\\") catch {};
        s.unlockCore(self.io);
    }
    // MARU_FAKE_BRANCH=<절대경로> — 첫 frame에 활성 코어로 OSC 7(cwd=<경로>)을 흘려, 그 경로가 git repo면 사이드바
    // 카드의 **브랜치 줄(octocat 0xF0009 + 브랜치명)·폴더 줄(cwd)**이 떠 헤드리스 스크린샷으로 self-verify한다. 헤드리스
    // 첫 frame엔 셸이 아직 OSC 7을 안 보내 termGitBranch(currentCwd)가 null → 두 보조줄이 안 떠 라이브 캡처가 불가했다.
    // OSC 7은 core.write에서 동기 파싱돼(core.zig "OSC 7 reports cwd" test와 동형) 같은 frame의 buildSidebarTitleFrame이
    // currentCwd를 읽는다. <경로>는 절대경로(예: 이 저장소 루트)이며 percent-encoding 없이 그대로 넣는다(공백 등 특수문자
    // 없는 dev 경로 가정). show-branch/show-folder 토글이 켜져 있어야 각 줄이 보인다(기본 on). 일반 실행엔 영향 없다(env-gate).
    if (std.c.getenv("MARU_FAKE_BRANCH")) |dir| {
        const d = std.mem.span(dir);
        if (d.len > 0 and d[0] == '/') {
            if (std.fmt.allocPrint(self.allocator, "\x1b]7;file://localhost{s}\x07", .{d})) |seq| {
                defer self.allocator.free(seq);
                const s = term_ops.activeSurface(self);
                s.lockCore(self.io);
                s.core.write(seq) catch {};
                s.unlockCore(self.io);
            } else |_| {}
        }
    }
    // MARU_FORCE_BELL=1 — 첫 frame에 BEL(0x07)을 활성 코어에 흘려 시각 벨(bell.visual) flash를 캡처(self-verify
    // debug-gate). maybeDebugOpenSettings는 tick의 dispatchBell 전에 돌아 같은 frame에 flash quad가 들어간다.
    if (std.c.getenv("MARU_FORCE_BELL") != null) {
        const s = term_ops.activeSurface(self);
        s.lockCore(self.io);
        s.core.write("\x07") catch {};
        s.unlockCore(self.io);
    }
    // MARU_KEY_HINTS_FORCE=1 — 첫 frame부터 단축키 힌트(KH-4)를 강제로 켜 각 chrome 요소 우상단 단축키 배지를
    // 헤드리스 스크린샷으로 캡처(self-verify). 모디파이어 홀드(Swift flagsChanged) 없이 렌더 자체를 검증한다 —
    // 홀드 타이밍은 실기 수동 확인. 일반 실행엔 영향 없다(env-gate). 홀드 머신도 shown=true로 맞춰(visible의 소유자)
    // 강제-표시 후 모디파이어 해제(off)가 hide로 정상 처리되게 한다 — 직접 set만 하면 머신 shown=false라 desync.
    if (std.c.getenv("MARU_KEY_HINTS_FORCE") != null) {
        self.chrome_host.key_hints.visible = true;
        self.key_hint_hold.shown = true;
    }
    // MARU_FORCE_STYLED=1 — 첫 frame에 bold/italic/bold-italic/regular SGR 텍스트를 활성 코어에 써 넣어 폰트 face
    // 선택(font.family-bold/italic, F2-3)을 헤드리스 스크린샷으로 캡처(self-verify). italic 슬랜트·bold 굵기가 보인다.
    if (std.c.getenv("MARU_FORCE_STYLED") != null) {
        const s = term_ops.activeSurface(self);
        s.lockCore(self.io);
        s.core.write("\x1b[1mBOLD\x1b[0m \x1b[3mITALIC\x1b[0m \x1b[1;3mBOTH\x1b[0m regular") catch {};
        s.unlockCore(self.io);
    }
    // MARU_FORCE_SYS_APPEARANCE=light|dark — 시스템 외관을 강제로 알려 theme.follow-system의 preset 교체를 캡처
    // (self-verify). NSAppearance를 헤드리스로 못 바꾸므로 setSystemAppearance를 직접 호출한다. config follow-system on 필요.
    if (std.c.getenv("MARU_FORCE_SYS_APPEARANCE")) |sv| {
        self.setSystemAppearance(std.mem.eql(u8, std.mem.span(sv), "dark"));
    }
    // MARU_COLLAPSE_SIDEBAR=N — 첫 frame에 테스트 알림 N개(미설정/0→3)를 시드하고 사이드바를 접는다(접힘 좌상단 ◧+종+
    // 배지를 헤드리스 스크린샷으로 self-verify하는 debug-gate). MARU_OPEN_NOTIFICATIONS와 함께 쓰면 접힘 상태에서 패널까지.
    if (std.c.getenv("MARU_COLLAPSE_SIDEBAR")) |cv| {
        var seed: usize = std.fmt.parseInt(usize, std.mem.span(cv), 10) catch 3;
        if (seed == 0) seed = 3;
        var i: usize = 0;
        while (i < seed) : (i += 1) _ = notification_ops.pushNotificationHistory(self, "Maru", "빌드 알림 예시", 0);
        if (!self.sidebar_collapsed) sidebar_ops.toggleSidebarCollapsed(self);
    }
    // MARU_OPEN_NOTIFICATIONS=N — 첫 frame에 테스트 알림 N개(미설정/0→2)를 시드하고 알림 패널을 연다(헤더 밴드·
    // 말풍선 caret·카드·스크롤을 헤드리스 스크린샷으로 self-verify하는 debug-gate). env 미설정이면 무동작.
    if (std.c.getenv("MARU_OPEN_NOTIFICATIONS")) |nv| {
        var seed: usize = std.fmt.parseInt(usize, std.mem.span(nv), 10) catch 2;
        if (seed == 0) seed = 2;
        var i: usize = 0;
        while (i < seed) : (i += 1) _ = notification_ops.pushNotificationHistory(self, "Maru", "빌드 알림 예시", 0);
        notification_ops.openNotificationPanel(self);
        // MARU_NOTIF_HOVER=K — 위에서 시드한 카드 K에 마우스 호버 강조(tab_hover_bg)를 건 채로 연다. 호버는 마우스
        // 이동(hoverCursor→hitTest)으로만 갱신돼 헤드리스 스크린샷 하니스로는 재현이 안 되므로, 호버 카드 색을 self-verify
        // 하는 debug-gate다. MARU_OPEN_NOTIFICATIONS의 **하위 옵션**이다(단독으로는 무효 — 시드된 카드와 열린 패널이
        // 필요해 이 블록 안에서만 읽는다). K가 시드 개수 밖이거나 비숫자면 무시한다 — 잘못된 K로 '강조 없음'이 정상처럼
        // 보여 self-verify가 오판하지 않게(범위 밖은 view가 어차피 강조를 안 그린다). 미설정이면 무동작.
        if (std.c.getenv("MARU_NOTIF_HOVER")) |hv| {
            const k = std.fmt.parseInt(usize, std.mem.span(hv), 10) catch seed; // 비숫자 → seed(=범위 밖)로 무시
            if (k < seed) self.chrome_host.notifications.hovered = k;
        }
    }
    // MARU_OPEN_NOTIFICATIONS_EMPTY=1 — 알림 0개로 패널을 연다(빈 상태 일러스트: 아이콘+제목+부제를 헤드리스
    // 스크린샷으로 self-verify하는 debug-gate). MARU_OPEN_NOTIFICATIONS와 배타(둘 다면 위에서 이미 시드됨).
    if (std.c.getenv("MARU_OPEN_NOTIFICATIONS_EMPTY") != null and !self.chrome_host.notifications.open) {
        notification_ops.openNotificationPanel(self);
    }
    // MARU_PASTE=<텍스트> — 그 텍스트를 붙여넣는다(pasteText, escape 없음). paste protection 확인 모달을
    // 헤드리스 스크린샷으로 self-verify하는 debug-gate — 개행이 있으면 확인 모달이 뜬다. `\n`은 실제 개행으로
    // 해석해 여러 줄을 만든다(env로 리터럴 개행 넣기 번거로워서). 미설정이면 무동작.
    if (std.c.getenv("MARU_PASTE")) |pv| {
        const raw = std.mem.span(pv);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len and raw[i + 1] == 'n') {
                buf.append(self.allocator, '\n') catch break;
                i += 1;
            } else buf.append(self.allocator, raw[i]) catch break;
        }
        self.pasteText(buf.items, false);
    }
    // MARU_OPEN_QUIT_CONFIRM=1 — 첫 frame에 "maru를 종료할까요?" 종료 확인 모달을 연다(applicationShouldTerminate가
    // 라이브로 여는 것과 같은 requestAppQuit 경로). 종료 확인 모달이 오버레이 레이어에 렌더되는지 헤드리스 스크린샷으로
    // self-verify하는 debug-gate. env 미설정이면 무동작. pending_quit/quit_decision은 세워지나 screenshot 모드는 첫 frame
    // 캡처 후 exit라 결정이 소비되지 않는다(무해).
    if (std.c.getenv("MARU_OPEN_QUIT_CONFIRM") != null) {
        self.requestAppQuit();
        return;
    }
    if (std.c.getenv("MARU_OPEN_SETTINGS") == null) return;
    settings_ops.toggleSettings(self);
    // MARU_OPEN_SETTINGS_SECTION=N — 특정 섹션을 열어 캡처(스크린샷 self-verify용 debug-gate). 미설정=섹션 0.
    if (std.c.getenv("MARU_OPEN_SETTINGS_SECTION")) |sv| {
        self.chrome_host.settings.section = std.fmt.parseInt(usize, std.mem.span(sv), 10) catch 0;
        settings_ops.refreshSettingsFieldCount(self);
    }
    // MARU_OPEN_SETTINGS_EDIT=1 — 섹션 마지막 행(text면)을 인라인 편집 모드로(text 위젯 caret 캡처용 debug-gate).
    if (std.c.getenv("MARU_OPEN_SETTINGS_EDIT") != null and self.chrome_host.settings.count > 0) {
        self.chrome_host.settings.selected = self.chrome_host.settings.count - 1;
        settings_ops.toggleSelectedSetting(self);
    }
    // MARU_OPEN_SETTINGS_SEARCH=<쿼리> — 검색 모드로 그 쿼리를 채워 필터된 폼을 캡처(검색 self-verify debug-gate).
    if (std.c.getenv("MARU_OPEN_SETTINGS_SEARCH")) |sv| {
        self.chrome_host.settings.startSearch();
        for (std.mem.span(sv)) |c| self.chrome_host.settings.appendSearchCp(c);
        settings_ops.refreshSettingsFieldCount(self);
    }
    // MARU_OPEN_SETTINGS_PICK=1 — 현재 섹션 첫 color 행을 선택하고 HSV picker를 연다(picker self-verify debug-gate).
    // theme 섹션(MARU_OPEN_SETTINGS_SECTION=1)과 함께 쓰면 색 그리드를 캡처. color 행이 없으면 무동작.
    if (std.c.getenv("MARU_OPEN_SETTINGS_PICK") != null) {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        if (settings_ops.currentSectionFields(self, scratch.allocator())) |cf| {
            if (cf.colors.len > 0) {
                self.chrome_host.settings.selected = cf.bools.len + cf.nums.len + cf.enums.len + cf.texts.len;
                settings_ops.toggleSelectedSetting(self);
            }
        } else |_| {}
    }
}

/// FP3 시각 픽스처. `MARU_FILE_PANEL=/absolute/path.md|html`이면 창-로컬 도크에 한 번만
/// 열어 WKWebView surface diff·크롬·resize를 실제 app-host 경로로 검증한다. FP4 전이라 본문은 placeholder다.
/// 강제된 에이전트 상태를 **여러 Term에** 다시 세운다(캡처 전용).
///
/// 두 가지를 해결한다. ⑴ `pollAgentKinds`가 매 tick 관측으로 상태를 되돌리므로 첫 frame에 한 번 세운
/// 값은 렌더까지 살아남지 못한다 — 그래서 tick의 폴링 **뒤에서도** 한 번 더 부른다. ⑵ 값이 `<n>`이면
/// 앞에서부터 n개 Term을 세워 **목록이 필요한 상태**(2개 이상)를 만든다. 없는 값이면 1로 본다.
///
/// 실제 상태는 셸 화면 관측이 정한다 — 그것을 캡처로 만들 방법이 없어서 훅이 필요하다(MARU_FORCE_AGENT와
/// 같은 성격). env 미설정이면 무동작이라 일반 실행에 영향이 없다.
/// 강제된 **소스 컨트롤 도크 행 호버**를 다시 세운다(캡처 전용, `MARU_FORCE_SCM_HOVER=<모델 인덱스|last>`).
///
/// 행 동작(`+`/`−`)은 **호버할 때만 그려진다**(그것이 계약이다 — 누를 수 없는 컨트롤을 상시 띄우지 않는다).
/// 그래서 캡처 하니스에 포인터가 없으면 그 버튼이 화면에 나오는지 헤드리스로 확인할 방법이 아예 없다 —
/// 사이드바 호버 밴드를 같은 이유로 강제하는 것과 같은 자리다.
///
/// **매 tick 다시 세운다.** 포인터가 도크 밖에 있으면 다음 pointer 이벤트가 곧바로 호버를 지운다.
///
/// env 미설정이면 무동작.
pub fn reapplyForcedScmHover(self: *AppSession) void {
    const raw = std.c.getenv("MARU_FORCE_SCM_HOVER") orelse return;
    if (self.dock.view != .source_control) return;
    const entries = self.scm_dock_entries.items;
    if (entries.len == 0) return;

    const spec = std.mem.span(raw);
    // 발행된 tree에서 **행 노드만** 고른다. 인덱스는 published 창 기준이라, 스크롤 없이 캡처하는
    // 하니스에서는 모델 인덱스와 같다.
    var last_row: ?chrome.ui.tree.UiId = null;
    var want_id: ?chrome.ui.tree.UiId = null;
    const want_index: ?usize = if (std.mem.eql(u8, spec, "last")) null else std.fmt.parseInt(usize, spec, 10) catch 0;
    var index: usize = 0;
    while (index < entries.len) : (index += 1) {
        const id = chrome.components.scm_dock.build.NodeIds.item(index);
        var found = false;
        for (entries) |entry| {
            if (entry.id == id) {
                found = true;
                break;
            }
        }
        if (!found) break;
        last_row = id;
        if (want_index) |w| {
            if (index == w) want_id = id;
        }
    }
    const target = want_id orelse last_row orelse return;
    if (self.scm_dock_interaction.hovered) |cur| {
        if (cur == target) return;
    }
    self.scm_dock_interaction.hovered = target;
    self.metal_dirty = true;
}

/// 강제된 **사이드바 카드 호버**를 다시 세운다(캡처 전용, `MARU_FORCE_SIDEBAR_HOVER=<슬롯|last>`).
///
/// 호버 밴드는 rich 토큰에서 **layer 0 GPU quad**라 사이드바 셀과 다른 경로로 잘린다. 그 클립이 상태바
/// 위에서 실제로 끊기는지는 캡처 하니스에 포인터가 없어 확인할 방법이 없었고, 뷰포트를 넘은 밴드가 상태바를
/// 덮은 결함(docs/status-bar.md §5.3)이 그래서 헤드리스로 안 잡혔다.
///
/// **매 tick 다시 세운다.** 첫 frame에 한 번 세운 값은 렌더까지 살아남지 못한다 — 포인터가 사이드바 밖에
/// 있으면 `hoverCursor`가 곧바로 `setHoveredSlot(null)`로 지운다(마우스가 창 위를 지나기만 해도 그렇다).
/// 실측으로 그 때문에 첫 픽스처가 조용히 무동작이었다. `reapplyForcedAgentStates`가 폴링에 맞서 같은 일을
/// 하는 것과 같은 규율이다. 이미 그 슬롯이면 재빌드하지 않는다(매 tick 재빌드 방지).
///
/// 값은 셋 중 하나다:
/// - `edge` — **뷰포트 바닥을 가로지르는 슬롯**. 이 결함을 겨냥하는 값이다(밴드가 상태바와 겹칠 수 있는
///   유일한 카드). 창 크기·폰트가 달라도 경계 카드를 스스로 찾으므로 인덱스를 손으로 맞출 필요가 없다.
/// - `last` — 마지막 표시 슬롯. 콘텐츠가 뷰포트를 넘치면 **화면 밖**이라 아무것도 안 보인다(실측으로 그
///   차이에 한 번 속았다). 목록 끝 렌더를 볼 때만 쓴다.
/// - 정수 — 그 표시 슬롯(범위 밖은 마지막으로 clamp).
///
/// env 미설정이면 무동작.
pub fn reapplyForcedSidebarHover(self: *AppSession) void {
    const raw = std.c.getenv("MARU_FORCE_SIDEBAR_HOVER") orelse return;
    const rows = self.sidebar_rows.items.len;
    if (rows == 0) return;
    const spec = std.mem.span(raw);
    const want: usize = if (std.mem.eql(u8, spec, "edge"))
        (sidebarViewportEdgeSlot(self) orelse return) // 넘치지 않는 창이면 겨냥할 경계가 없다 — 무동작
    else if (std.mem.eql(u8, spec, "last"))
        rows - 1
    else
        @min(std.fmt.parseInt(usize, spec, 10) catch 0, rows - 1);
    if (self.hovered_slot) |cur| {
        if (cur == want) return;
    }
    self.hovered_slot = want;
    sidebar_ops.rebuildSidebar(self) catch {}; // 호버 밴드는 재빌드가 발행한다(setHoveredSlot과 같은 경로)
    self.metal_dirty = true;
}

/// 뷰포트 바닥(상태바 위)을 **가로지르는** 표시 슬롯. 위아래가 온전히 안/밖인 카드는 경계를 증언하지
/// 못하므로, 클립을 검증하려면 걸친 카드를 골라야 한다. 콘텐츠가 안 넘치면 null(그럴 땐 겨냥할 경계가 없다).
/// 누적 산술은 렌더와 같은 도메인(`sidebarRenderRows`·`rowHeight`)을 쓴다 — 다른 도메인으로 세면 한 칸 밀린다.
fn sidebarViewportEdgeSlot(self: *AppSession) ?usize {
    const viewport = sidebar_ops.sidebarViewport(self);
    if (viewport.isEmpty()) return null;
    const metrics = sidebar_ops.sidebarMetrics(self);
    const bottom: i64 = @intCast(viewport.bottom);
    var row_top: i64 = @as(i64, @intCast(viewport.top)) - @as(i64, @intCast(self.sidebar_scroll_offset_px));
    for (sidebar_ops.sidebarRenderRows(self), 0..) |row, i| {
        const row_bottom = row_top + @as(i64, @intCast(chrome.components.sidebar.rowHeight(row, metrics)));
        if (row_top < bottom and row_bottom > bottom) return i;
        row_top = row_bottom;
    }
    return null;
}

pub fn reapplyForcedAgentStates(self: *AppSession) void {
    const running_raw = std.c.getenv("MARU_FORCE_AGENT");
    const blocked_raw = std.c.getenv("MARU_FORCE_BLOCKED");
    // MARU_FORCE_AGENTS_COLLAPSED=1 — 카드 하위 세션 목록을 접어 토글 행의 **대표 상태 요약**(`· 진행중`)을
    // 캡처한다. 그 요약은 접힘에서만 붙으므로(docs/sidebar-agent-list.md §2) 이 훅 없이는 스크린샷으로 만들 수
    // 없다 — 접기는 사용자 클릭이고 캡처 하니스에는 포인터가 없다. 위 상태 훅과 같은 성격이라 같은 자리에 둔다.
    //
    // **상태 훅과 독립적으로도 동작한다.** 실제로 쓸 때는 `MARU_FORCE_AGENT`와 함께 주지만, 함께일 때만 도는
    // 구조로 두면 이것만 준 사람에게 조용한 무동작이 된다(디버그 훅에서 가장 오해하기 쉬운 실패다).
    const collapse = std.c.getenv("MARU_FORCE_AGENTS_COLLAPSED") != null;
    if (running_raw == null and blocked_raw == null and !collapse) return;

    var n: usize = 0;
    if (blocked_raw orelse running_raw) |raw| {
        const want: maru.session.agent_observer.State = if (blocked_raw != null) .blocked else .running;
        const want_n = std.fmt.parseInt(usize, std.mem.span(raw), 10) catch 1;
        var stamp: u64 = 0;
        outer: for (self.tabs.items) |tab| {
            for (tab.panes.items) |pane| {
                for (pane.terms.items) |term| {
                    if (n >= want_n) break :outer;
                    term.agent_state = want;
                    term.agent_kind = .claude;
                    // 활동 시각은 **앞 Term이 가장 최근**이 되게 심는다 — 그래야 두 정렬이 화면에서 갈린다.
                    // 탭 순서면 [방금, 1분 전], 오래 기다린 순이면 [1분 전, 방금]이다. 같은 방향으로 심으면
                    // 두 목록이 똑같이 나와 정렬이 도는지 캡처로 못 가른다(첫 픽스처가 그래서 쓸모없었다).
                    term.agent_last_output_ms = self.awakeMs() -| (n * 60_000);
                    stamp += 1;
                    n += 1;
                }
            }
        }
    }
    if (collapse) for (self.tabs.items) |tab| {
        tab.agents_collapsed = true;
    };
    // **사이드바를 다시 투영한다.** `sidebar_rows`는 이벤트(Term 열기/닫기·접기·드래그)에서만 재빌드되고 tick에는
    // 돌지 않는다 — 그 설계 자체는 옳다(매 프레임 재투영은 낭비고, running 상태는 draw list가 라이브로 재조회한다).
    // 문제는 이 하니스가 **제품 이벤트를 거치지 않고** 상태를 심는다는 점이다: `MARU_FORCE_SPLIT`이 만든 pane과
    // 여기서 세운 agent_kind가 rows에는 없어, 목록 유무를 정하는 `appendAgentRows`가 "세션 1개·에이전트 0"인
    // 첫 투영 그대로 굳는다. 실제로 캡처에서 세션 목록이 통째로 안 나왔고, 그것을 코드 회귀로 오해하기 쉬웠다.
    //
    // 사용자 클릭과 **같은 경로**(rebuildSidebar)를 태워 rows를 현실과 맞춘다(메모리·docs의 self-verify 게이트 규율).
    // env 미설정이면 위에서 이미 반환했으므로 제품 실행에는 영향이 없다. 접힘도 같은 이유로 재투영이 필요하다 —
    // `agents_collapsed`는 rows에 굳어 들어가므로 세우기만 하고 다시 그리지 않으면 화면은 펼친 채로 남는다.
    if (n > 0 or collapse) sidebar_ops.rebuildSidebar(self) catch {};
}

/// `MARU_NATIVE_EDITOR=<path>` — 네이티브 편집기로 파일을 **열어 보고 그 결과를 알린다**(N1).
///
/// **아직 화면에 그리지 않는다.** 문서 쪽 절반(파일 읽기·인코딩·줄바꿈·논리행)이 실제 파일에서
/// 서는지 먼저 확인하는 훅이고, 그리는 절반은 chrome 텍스트 배선이 붙는 슬라이스에서 잇는다.
/// 그때 이 훅은 "열어서 그린다"로 바뀐다.
pub fn maybeDebugOpenNativeEditor(self: *AppSession) void {
    // **`dock_initialized`를 본다 — 바로 아래 파일 패널 훅과 같은 조건이다.** 처음에는
    // `surface_initialized`를 봤는데 그것은 `finishInitialSurface`가 **첫 live tab이 준비된 뒤**에
    // 켜므로(PTY 셸이 뜬 다음), 셸 시작이 늦은 환경에서는 훅이 매 프레임 그냥 반환한다. 같은
    // 함수에서 불리는 두 훅이 다른 시점을 기다릴 이유가 없고, 파일 패널 쪽 조건은 여러 보이는
    // 스모크가 실제로 캡처를 뽑아 동작이 증명돼 있다.
    //
    // **그래도 notice가 화면에 뜨는 것은 터미널 서피스가 있을 때뿐이다.** 모달은 `workspaceRect`
    // 위에 올라가는데(`modal_box.layout`), 서피스가 없으면 그 사각형이 0×0이라 layout이 null을 주고
    // op이 하나도 안 나온다. 이 훅은 "읽었다"를 알리는 쪽이므로 그 조건까지 기다리지 않는다 —
    // 서피스가 생기고 다음 redraw가 오면 열려 있던 notice가 그대로 그려진다.
    if (self.debug_native_editor_opened or !self.dock_initialized) return;
    const raw = std.c.getenv("MARU_NATIVE_EDITOR") orelse return;
    self.debug_native_editor_opened = true;

    const path = std.mem.span(raw);
    if (path.len == 0) return;

    // **연 파일을 활성 pane에 편집기 Term으로 붙인다** — N1의 "화면에 파일이 뜬다"가 여기서 닫힌다.
    _ = editor_ops.openPathInActivePane(self, path) catch |e| {
        // **왜 못 열었는지 구분해서 알린다.** §3.5가 "여는 것을 막는 이유는 UTF-8 아님 하나"라고
        // 정했으므로, 나머지 이유가 같은 메시지로 뭉개지면 그 계약을 확인할 수 없다.
        self.showNoticeKey(switch (e) {
            error.NotUtf8 => .dbg_editor_not_utf8,
            error.TooLarge => .dbg_editor_too_large,
            error.Unreadable => .dbg_editor_unreadable,
            error.OutOfMemory => .dbg_editor_oom,
        });
        return;
    };
    self.metal_dirty = true;
}

/// 강제된 **편집기 caret**(캡처 전용, `MARU_FORCE_EDITOR_CARET=<줄>:<열>`, 1-based).
///
/// 상태바의 커서 위치 항목은 **선택이 있을 때만** 뜨는데(§2.2), 선택은 클릭으로만 생긴다 —
/// 포인터가 없는 캡처 하니스에서는 그 항목이 있는 화면을 얻을 방법이 아예 없다. 커밋 메시지·
/// 사이드바 호버를 같은 이유로 강제하는 것과 같은 자리다.
///
/// **줄·열은 사용자가 보는 축 그대로 받는다**(1-based, 열은 그래핌 클러스터). 여기서 offset으로
/// 바꾸므로 픽스처가 내부 축을 알 필요가 없다.
pub fn applyForcedEditorCaret(self: *AppSession) void {
    const raw = std.c.getenv("MARU_FORCE_EDITOR_CARET") orelse return;
    const spec = std.mem.span(raw);
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return;
    const want_line = std.fmt.parseInt(usize, spec[0..colon], 10) catch return;
    const want_col = std.fmt.parseInt(usize, spec[colon + 1 ..], 10) catch return;
    if (want_line == 0 or want_col == 0) return;

    const pane = pane_ops.activePane(self);
    const term = pane.activeTerm();
    if (term.kind != .editor) return;
    const doc = term.rt.editor_doc orelse return;
    const line = doc.file.lines.line(want_line - 1) orelse return;

    // 열을 클러스터로 세어 offset을 찾는다 — 상태바가 되짚는 것과 **같은 축**이라야 캡처가
    // 보여주는 값이 요청한 값과 같다.
    var off = line.start;
    var col: usize = 1;
    const text = doc.file.content[line.start..line.contentEnd()];
    var i: usize = 0;
    while (col < want_col and i < text.len) {
        i = maru.grapheme.clusterEnd(text, i);
        off = line.start + i;
        col += 1;
    }
    term.rt.editor_selection = maru.session.editor.selection.Selection.at(off);
    self.metal_dirty = true;
}

pub fn maybeDebugOpenFilePanel(self: *AppSession) void {
    if (self.debug_file_panel_opened or !self.dock_initialized) return;
    const raw = std.c.getenv("MARU_FILE_PANEL") orelse return;
    const path = std.mem.span(raw);
    if (path.len == 0) return;
    if (self.openFilePanelPath(path) != .opened) return;
    if (std.c.getenv("MARU_FILE_PANEL_DOCK")) |side| {
        if (std.mem.eql(u8, std.mem.span(side), "bottom")) self.dock.side = .bottom;
    }
    self.debug_file_panel_opened = true;
    self.metal_dirty = true;
}

/// 강제된 **커밋 메시지 편집 상태**(캡처 전용, `MARU_FORCE_SCM_COMMIT=<메시지>`).
///
/// 편집은 클릭으로만 시작되고 글자는 키보드로만 들어오므로, 포인터·키보드가 없는 캡처 하니스에서는
/// 상자가 편집 중인 모습(caret·여러 줄·자란 높이)을 얻을 방법이 아예 없다 — 행 호버를 같은 이유로
/// 강제하는 것과 같은 자리다.
///
/// **상태를 심지 않는다.** 사용자와 같은 경로(`focusCommit`·`insertCommitText`)를 태우므로 랩·caret·
/// 상자 높이·목록 뷰포트는 전부 제품 tick이 정한다.
///
/// **한 번만 넣는다.** 매 tick 넣으면 같은 글자가 무한히 쌓인다 — 포커스 플래그가 그 가드다.
/// 캡처 전용: 소스 컨트롤 도크의 **탭·턴 목록·펼친 커밋**을 강제한다(env 미설정이면 무동작).
///
/// `app_session.zig` 의 tick 안에 인라인으로 있던 것을 옮겼다 — 이 모듈이 존재하는 이유가 정확히
/// «제품 경로를 읽는 사람이 디버그 스캐폴딩을 지나지 않게» 이고, 그 블록은 턴 하니스가 커지면서
/// 40줄을 넘었다(적대적 검증에서 잡혔다).
pub fn applyForcedScmTab(self: *AppSession) void {
    // MARU_FORCE_SCM_TAB=history|agent — 그 탭을 고른 것처럼 만든다(P4). 탭 전환은 클릭으로만
    // 일어나므로 포인터 없는 캡처 하니스에서는 히스토리 화면을 얻을 방법이 없다(행 호버와 같은 자리).
    if (std.c.getenv("MARU_FORCE_SCM_TAB")) |raw| {
        const spec = std.mem.span(raw);
        const tab: chrome.components.scm_dock.types.Tab = if (std.mem.eql(u8, spec, "history"))
            .history
        else if (std.mem.eql(u8, spec, "agent"))
            .agent
        else
            .changes;
        scm_dock_ops.selectScmTab(self, tab);
        // MARU_FORCE_SCM_COMMIT_EXPAND=<n> — 그 자리의 커밋을 펼친 것처럼 만든다(P4b). 펼치기는
        // 클릭으로만 일어나므로 포인터 없는 캡처 하니스에서는 그 화면을 얻을 방법이 없다.
        // MARU_FORCE_SCM_TURNS=<n> — 관측한 턴이 없는 하니스에서 타임라인을 찍기 위해 스냅샷을
        // n개 심는다(P5). 링은 **이번 실행에서 관측한 것**이라 헤드리스에는 비어 있다.
        //
        // **AT0 이후로는 신원도 함께 심는다.** 링의 키가 provider 세션 id 이고 화면은 «활성 세션의
        // 링» 을 그리므로, 신원 없이 링만 채우면 그 목록을 찾을 수 없다. 캡처 하니스에는 진짜
        // 에이전트가 없으므로 활성 Term 에 데모 신원을 붙이고 같은 키로 링을 만든다.
        if (tab == .agent) {
            if (std.c.getenv("MARU_FORCE_SCM_TURNS")) |raw_count| {
                const demo_session = "maru-demo-session";
                if (self.turn_rings.find(demo_session) == null) {
                    if (self.surface_initialized) {
                        const active_id = term_ops.activeSurface(self).id;
                        outer: for (self.tabs.items) |tab_item| {
                            for (tab_item.panes.items) |pane| {
                                for (pane.terms.items) |term| {
                                    if (term.surface.id != active_id) continue;
                                    term.agent_transcript.setIdentity(demo_session);
                                    break :outer;
                                }
                            }
                        }
                    }
                    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const repo = self.git_repo orelse (git_ops.gitRepoRoot(self, &repo_buf) orelse "");
                    // `orelse return` 을 쓰지 않는다 — 여기서 나가면 그 프레임의 나머지 tick 작업이 통째로 스킵된다.
                    if (self.turn_rings.ringFor(demo_session, repo)) |ring| {
                        const count = std.fmt.parseInt(usize, std.mem.span(raw_count), 10) catch 3;
                        const now_s: i64 = @intCast(@divFloor(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
                        // MARU_FORCE_SCM_TURN_TREES=<oid>,<oid>,… — **진짜 tree** 를 밖에서 받는다(오래된 것부터).
                        // 가짜 OID 를 심으면 `git diff` 가 실패해 `N개 파일` 요약이 영영 안 뜬다 — 그 줄을
                        // 캡처로 확인할 방법이 없어진다. 앱이 스스로 `rev-parse` 를 부르지 않는 이유는 그것이
                        // 비동기 배관이라 캡처 시점에 결과가 없기 때문이다(스크립트가 구해서 넘긴다).
                        //
                        // ⚠️ **스크립트가 커밋 tree(`HEAD~n^{tree}`)를 빌리는 것은 헤드리스 편의다.**
                        // 캡처 하니스에는 에이전트가 없어 진짜 턴 스냅샷을 만들 수 없으므로 이미 있는 tree 를
                        // 쓴다. **제품은 커밋과 무관하다** — `captureTurnSnapshot` 은 임시 index 로
                        // `read-tree HEAD → add -A → write-tree` 를 돌려 **작업트리**를 굳히므로 커밋하지 않은
                        // 변경이 그대로 잡힌다(계약 §2.4 가 커밋 0회·스테이징 0회로 실증했고, 그 경로는
                        // 「턴 스냅샷이 링에 실리고…」 통합 테스트가 실제로 돌린다). tree 는 «그 시점 파일들의
                        // 내용 스냅샷» 이라 어느 쪽으로 만들었든 diff 계산은 같다 — 그래서 이 빌림이 성립한다.
                        //
                        // 캡처 방식 전환(계약 §4.4) 뒤에는 tree 개념이 사라지므로 **이 게이트와 요약 배관이
                        // 함께 걷힌다** — 그때 파일 수는 우리가 든 그림자 사본에서 바로 나온다.
                        var trees_it: ?std.mem.SplitIterator(u8, .scalar) = if (std.c.getenv("MARU_FORCE_SCM_TURN_TREES")) |raw_trees|
                            std.mem.splitScalar(u8, std.mem.span(raw_trees), ',')
                        else
                            null;
                        var i: usize = 0;
                        while (i < count) : (i += 1) {
                            var oid_buf: [16]u8 = undefined;
                            const fallback = std.fmt.bufPrint(&oid_buf, "{d:0>10}ab", .{i}) catch continue;
                            const oid = if (trees_it) |*it| (it.next() orelse fallback) else fallback;
                            // 종류만 번갈아 심는다 — 한 링은 한 세션이므로 `surface_id` 는 하나다.
                            ring.push(.{
                                .tree = oid,
                                .surface_id = 1,
                                .captured_s = now_s - @as(i64, @intCast((count - i) * 900)),
                                .agent_kind = if (i % 2 == 0) 1 else 2,
                                // 턴 키는 심지 않는다 — 하니스에는 provider 훅이 없어 **모르는 것**이고,
                                // 가짜 키를 심으면 AT3 귀속이 그 항목에 없는 기록을 붙이려 든다.
                            });
                        }
                        // MARU_FORCE_SCM_TURNS_MISSED=<n> — 「기록하지 못한 턴」 줄을 세운다. 실제로는
                        // 다른 세션의 캡처와 겹쳐야 나는 값이라 헤드리스로는 재현할 방법이 없다.
                        if (std.c.getenv("MARU_FORCE_SCM_TURNS_MISSED")) |raw_missed| {
                            ring.missed = std.fmt.parseInt(u32, std.mem.span(raw_missed), 10) catch 0;
                        }
                        // MARU_FORCE_SCM_TURNS_EVICTED=1 — 「최근 세션에 밀려 이전 턴 기록이 사라졌습니다」
                        // 줄을 세운다. `_MISSED` 와 같은 성격이고 이유도 같다: 실제로 이 값이 서려면 **서로
                        // 다른 세션 신원 아홉**이 맵을 넘겨야 하는데, 신원은 provider 훅이 발급하므로 에이전트
                        // 없는 헤드리스에서는 만들 방법이 없다.
                        //
                        // `MARU_FORCE_SCM_TURNS` 값에 따라 **두 화면**이 나온다(문구는 같은 자리에 선다):
                        //   n>0 → 목록이 찬 채로 고지가 함께 선다(그 줄이 목록을 대신하지 않는다는 계약)
                        //   n=0 → 빈 목록의 «이유» 자리에 고지가 대신 선다
                        //
                        // ⚠️ **링이 아예 없는 경로(`RingMap.wasEvicted`)는 여기로 못 온다** — 그쪽은 밀린 뒤
                        // 아직 안 돌아온 세션이고, 이 게이트는 링을 세워야 하는 자리에 있다. 그 분기는 단위
                        // test 가 본다(`app_session.test.에이전트 탭: 밀려난 세션은 …`).
                        if (std.c.getenv("MARU_FORCE_SCM_TURNS_EVICTED") != null) {
                            ring.history_evicted = true;
                        }
                    }
                }
            }
        }
        if (tab == .history) {
            if (std.c.getenv("MARU_FORCE_SCM_COMMIT_EXPAND")) |raw_index| {
                if (self.scm_expanded_commit == null) {
                    const index = std.fmt.parseInt(u32, std.mem.span(raw_index), 10) catch 0;
                    scm_dock_ops.applyScmDockIntent(self, .{ .select_commit = index });
                }
            }
        }
    }
}

pub fn applyForcedCommitMessage(self: *AppSession) void {
    const raw = std.c.getenv("MARU_FORCE_SCM_COMMIT") orelse return;
    if (self.dock.view != .source_control) return;
    if (self.scm_commit_focus_repo != null) {
        forceCommitRun(self);
        return;
    }
    // 캡처는 **활성 저장소**의 상자를 연다 — 그 저장소가 지금 화면이 말하고 있는 곳이다.
    const repo = self.git_repo orelse return;
    scm_dock_ops.focusCommitRepo(self, repo);
    scm_dock_ops.insertCommitText(self, std.mem.span(raw));
    // 선택 밴드도 캡처로만 확인할 수 있다(`MARU_FORCE_SCM_COMMIT_SELECT=1` — 전체 선택).
    // 밴드가 글자와 **같은 자를 쓰는지**는 픽셀로만 드러난다: caret·밴드는 셀 열 산술이고 글자는
    // 측정된 advance로 그려지므로, 둘이 어긋나면 밴드가 글자에서 밀린다.
    if (std.c.getenv("MARU_FORCE_SCM_COMMIT_SELECT") != null) self.scm_commit_field.selectAll();
    forceCommitRun(self);
}

/// 원격 갱신을 **실제로 건다**(`MARU_FORCE_SCM_FETCH=1`, P6). 사용자 클릭과 **같은 진입점**
/// (`applyScmDockIntent(.fetch_remote)`)을 태우므로 원격 유무 판정·슬롯·실패 문구는 전부 제품이 한다.
///
/// **성사될 때까지 다시 건다.** 첫 tick에는 목록 읽기가 없어(`git_result == null`) 원격 유무를 모르고
/// 조용히 돌아간다 — 커밋 픽스처가 같은 이유로 재시도한다.
/// `∨` 보조 메뉴를 연 상태를 캡처한다(`MARU_FORCE_SCM_MENU=1`, P6b). 메뉴는 클릭으로만 열리므로
/// 포인터 없는 캡처 하니스에서는 그 화면에 도달할 방법이 없다(호버·커밋 상자와 같은 자리).
///
/// **상태를 심지 않는다** — 사용자 클릭과 같은 진입점(`.open_remote_menu`)을 태우므로 앵커·항목·원격
/// 유무 판정은 전부 제품이 한다. 이미 열려 있으면 다시 열지 않는다(매 tick 열면 선택이 첫 줄로 되돌아간다).
/// 커밋 상자를 **휠로 굴린 상태**를 캡처한다(`MARU_FORCE_SCM_COMMIT_WHEEL=<틱 수>`, 음수면 위로).
/// 휠은 포인터 장치 입력이라 캡처 하니스가 낼 수 없다 — 호버·커밋 편집을 같은 이유로 강제하는 자리다.
///
/// **상태를 심지 않는다**: 사용자 손짓과 같은 진입점(`scrollWheel`)을 상자 안 좌표로 태우므로 대상
/// 판정·부호·클램프는 전부 제품이 한다. 한 번만 굴린다(매 tick 굴리면 끝까지 가 버려 중간 상태가 없다).
pub fn applyForcedCommitWheel(self: *AppSession) void {
    if (self.debug_commit_wheel_done) return;
    const raw = std.c.getenv("MARU_FORCE_SCM_COMMIT_WHEEL") orelse return;
    if (self.dock.view != .source_control) return;
    if (self.scm_commit_focus_repo == null) return; // 편집 중인 상자만 굴린다(제품 규칙과 같다)
    const ticks = std.fmt.parseInt(i32, std.mem.span(raw), 10) catch return;
    const rect = scm_dock_ops.commitBoxRect(self) orelse return; // 아직 발행 전이다 — 다음 tick에 다시 본다
    const content = dock_ops.dockGeometry(self).tree_content;
    // **clip 안의 점을 고른다.** 상자 위쪽이 잘린 상태에서 `rect.y + 8`을 찍으면 그 점은 상자 밖으로
    // 판정돼(제품 규칙), 게이트가 조용히 아무 일도 안 하고 래치만 세운다.
    const top = if (scm_dock_ops.commitBoxClip(self)) |clip| @max(rect.y, clip.y) else rect.y;
    const x = @as(f64, @floatFromInt(content.x)) + rect.x + 12;
    const y = @as(f64, @floatFromInt(content.y)) + top + 8;
    const step: f64 = if (ticks < 0) -1 else 1;
    var left: i32 = if (ticks < 0) -ticks else ticks;
    while (left > 0) : (left -= 1) self.scrollWheel(step, 0, false, x, y);
    self.debug_commit_wheel_done = true;
}

/// 상태바 브랜치 목록을 연 상태를 캡처한다(`MARU_FORCE_BRANCH_MENU=1`).
///
/// **열릴 때까지 재시도한다**: 저장소 판정이 cwd 관측(OSC 7)에 달려 있어 첫 tick에는 아직 없다.
/// 가짜 목록을 심지 않는다 — 실제 `for-each-ref` 결과로 열린다(`requestBranchMenu`가 연타를 막는다).
/// 브랜치 항목이 **선 뒤에만** 요청한다 — 그 전에는 저장소 판정이 실패해 오류 알림이 화면에 남는다.
pub fn applyForcedBranchMenu(self: *AppSession) void {
    if (self.branch_menu_open) return;
    if (std.c.getenv("MARU_FORCE_BRANCH_MENU") == null) return;
    for (self.statusBarTree().entries) |e| {
        if (e.id != @intFromEnum(chrome.components.status_bar.ItemId.git_branch)) continue;
        settings_ops.requestBranchMenu(self, .switch_branch);
        break;
    }
}

/// 도크를 소스 컨트롤 뷰로 열어 둔 것처럼 만든다(`MARU_FORCE_SCM=1`).
///
/// 뷰 전환의 유일한 진입점이 스위처 아이콘 **클릭**이라 스크린샷 하니스로는 도달할 수 없다(입력
/// 자동화는 겹친 남의 창을 누를 위험이 있어 검증 수단으로 쓰지 않는다). 상태를 심지 않고 사용자
/// 클릭과 **같은 경로**(`openDockTo`)를 태우므로, 저장소 판정·목록 읽기·안내 문구는 전부 제품
/// tick이 그대로 정한다.
///
/// tick 에서 뒤따르는 `scm_dock_ops.pump*` **앞**에 부른다 — `pumpScmLog`·`pumpTurnSummaries` 가
/// `dock.view != .source_control` 에서 곧바로 나가므로, 뒤로 밀면 목록 읽기가 한 tick 늦는다. **이것이
/// 이 자리가 못 박는 유일한 순서다.**
///
/// 바로 앞의 `applyForcedScmTab` 과의 상대 순서는 **옮기기 전 자리를 그대로 둔 것**일 뿐, 확인된 제약이
/// 없다 — `selectScmTab` 은 `dock.view` 를 읽지 않고, `openDockTo` 는 `scm_tab` 을 읽지 않는다
/// (`shouldRefreshArchiveOnPresent` 가 `.agent_sessions` 에서만 참이다). 둘이 스치는 자리는 하나다:
/// `selectScmTab` → `forgetScrollExtent` 가 재는 뷰포트 높이가 `dockGeometry` 를 거쳐 `dock.view` 와
/// `presented` 를 본다. 그 값은 같은 프레임의 투영(`rememberScrollExtent`)이 덮으므로 화면에 남지 않는다.
pub fn applyForcedScmView(self: *AppSession) void {
    if (std.c.getenv("MARU_FORCE_SCM") == null) return;
    if (self.dock.view == .source_control) return;
    dock_ops.openDockTo(self, .source_control);
}

/// 상태바 리소스 팝오버를 연 상태를 캡처한다(`MARU_FORCE_RESOURCE_MENU=1`).
///
/// `applyForcedBranchMenu`와 같은 목적·같은 규율이다. **열릴 때까지 재시도한다**: 값은 두 번째
/// 표본부터 생기고 항목도 그때 서므로 첫 tick에는 앵커가 없다. 가짜 행을 심지 않는다 — 실제
/// 표본으로 열린다. tick 에서 `pollResourceUsage` **뒤**에 둔 것은 그 tick 의 표본을 곧바로 보기
/// 위해서다 — 앞에 두면 한 tick 늦을 뿐, 열릴 때까지 재시도하므로 결과는 같다.
pub fn applyForcedResourceMenu(self: *AppSession) void {
    if (self.resource_menu_open) return;
    if (std.c.getenv("MARU_FORCE_RESOURCE_MENU") == null) return;
    for (self.statusBarTree().entries) |e| {
        if (e.id != @intFromEnum(chrome.components.status_bar.ItemId.resource)) continue;
        self.openResourceMenu();
        break;
    }
}

/// 에이전트 개수 팝오버를 연 상태를 캡처한다(`MARU_FORCE_AGENT_MENU=running|blocked`).
///
/// 같은 규율: 가짜 행을 심지 않고 **항목이 실제로 선 뒤에만** 진짜 경로(`openAgentMenu`)로 연다.
pub fn applyForcedAgentMenu(self: *AppSession) void {
    if (self.agent_menu_open) return;
    const raw = std.c.getenv("MARU_FORCE_AGENT_MENU") orelse return;
    const want_blocked = std.mem.eql(u8, std.mem.span(raw), "blocked");
    const want_id: chrome.components.status_bar.ItemId = if (want_blocked) .blocked_agents else .running_agents;
    for (self.statusBarTree().entries) |e| {
        if (e.id != @intFromEnum(want_id)) continue;
        self.openAgentMenu(want_blocked);
        break;
    }
}

pub fn applyForcedRemoteMenu(self: *AppSession) void {
    if (std.c.getenv("MARU_FORCE_SCM_MENU") == null) return;
    if (self.dock.view != .source_control) return;
    if (self.scm_remote_menu_open) return;
    if (self.git_result == null) return; // 아직 읽기 전이다
    if (self.scm_write_error != null) return; // 이유가 이미 적혔다
    scm_dock_ops.applyScmDockIntent(self, .open_remote_menu);
}

/// 기준 브랜치 목록을 연 상태를 캡처한다(`MARU_FORCE_SCM_BASE_MENU=1`, §3.5). 두 단계를 거친다 —
/// `∨`를 열고, 그 안의 "기준 브랜치 고르기"를 누른다. 목록 읽기는 비동기라 메뉴는 **그다음 tick**에 뜬다.
///
/// **상태를 심지 않는다**: 자리는 제품이 만든 표에서 찾고(`.pick_base`가 몇 번째인지 여기서 세지 않는다),
/// 항목·앵커·기본값 줄 유무 판정도 전부 제품이 한다. 원격이 없는 저장소에서 그 자리가 0번으로 바뀌는데,
/// 여기서 자리를 굳혀 두면 캡처가 **제품과 다른 경로**를 타게 된다.
pub fn applyForcedBaseMenu(self: *AppSession) void {
    if (std.c.getenv("MARU_FORCE_SCM_BASE_MENU") == null) return;
    if (self.dock.view != .source_control) return;
    if (self.scm_base_menu_open) return; // 이미 그 화면이다
    if (self.branch_menu_pending) return; // 목록을 기다리는 중 — 도착하면 제품이 연다
    if (self.git_result == null) return; // 아직 읽기 전이다
    if (!self.scm_remote_menu_open) {
        scm_dock_ops.applyScmDockIntent(self, .open_remote_menu);
        return;
    }
    for (self.scm_remote_menu_items[0..self.scm_remote_menu_len], 0..) |item, i| {
        if (item != .pick_base) continue;
        // 사용자 클릭과 같은 순서다 — 메뉴를 닫고 고른 자리를 적용한다.
        settings_ops.closeContextMenu(self);
        scm_dock_ops.applyRemoteMenuSelection(self, i);
        return;
    }
}

pub fn applyForcedFetch(self: *AppSession) void {
    if (std.c.getenv("MARU_FORCE_SCM_FETCH") == null) return;
    // **커밋 픽스처에 얹지 않는다.** 그쪽은 `MARU_FORCE_SCM_COMMIT`이 없으면 첫 줄에서 돌아가므로,
    // 그 안에 두면 이 게이트만 준 캡처에서 **조용히 아무 일도 일어나지 않는다**(실측으로 그랬다).
    if (self.dock.view != .source_control) return;
    if (self.scm_fetch_inflight != 0) return; // 이미 돈다
    if (self.git_result == null) return; // 아직 읽기 전이다
    if (self.scm_write_error != null) return; // 결과·이유가 이미 적혔다 — 재시도가 그걸 덮지 않게
    scm_dock_ops.applyScmDockIntent(self, .fetch_remote);
}

/// 커밋 **실행**까지 헤드리스로 확인한다(`MARU_FORCE_SCM_COMMIT_RUN=1`). 사용자 클릭과 **같은
/// 진입점**(`submitCommit`)을 태우므로 판정·메시지 파일·hook은 전부 제품이 한다.
///
/// **성사될 때까지 다시 건다.** 첫 tick에는 목록 읽기가 아직 없어(`git_result == null`) 스테이지 판정이
/// 되지 않아 조용히 돌아간다 — 한 번만 걸면 그 tick을 놓치고 영영 안 눌린다(브랜치 메뉴 픽스처가 같은
/// 이유로 재시도한다). 한 번 떴거나 사유가 적혔으면 멈춘다.
fn forceCommitRun(self: *AppSession) void {
    if (std.c.getenv("MARU_FORCE_SCM_COMMIT_RUN") == null) return;
    if (self.scm_commit_inflight or self.scm_write_inflight != 0) return;
    if (self.scm_write_error != null) return; // 이유가 이미 적혔다 — 재시도가 그걸 덮지 않게
    if (self.git_result == null) return; // 아직 읽기 전이다
    if (self.scm_commit_field.text.items.len == 0) return; // 성공 뒤에는 상자가 비어 있다
    scm_dock_ops.submitCommit(self);
}

/// 탭 바를 **넘치게** 만든다(캡처 전용, `MARU_FORCE_TAB_COUNT=<n>`).
///
/// 좌우 스크롤 버튼(`‹`/`›`)은 탭이 바를 넘칠 때만 나타난다. rich 고정 폭이 `tab_width_cols`(코드
/// 상수)라 1920px 창에서는 **탭 12개 이상**이 필요한데, 탭 추가는 `Cmd+T`(앱 단축키)라 PTY 입력으로
/// 만들 수 없고 workspace 복원은 스크린샷 모드에서 적용되지 않는다. 그래서 그 버튼들의 렌더가 헤드리스로
/// 확인되지 못했다 — 실측으로 배경이 glyph 와 같은 한 칸만 칠해지던 결함(#2478)이 그 사각에 있었다.
///
/// 사용자 `Cmd+T`와 **같은 진입점**(`newTermInActivePane`)을 태운다. 실제 셸이 그 수만큼 뜨므로 캡처
/// 시나리오에서만 쓴다. 한 번만 동작한다(`debug_tab_count_applied`).
pub fn applyForcedTabCount(self: *AppSession) void {
    if (self.debug_tab_count_applied) return;
    const raw = std.c.getenv("MARU_FORCE_TAB_COUNT") orelse return;
    if (!self.surface_initialized) return; // 아직 pane 이 없다 — 다음 tick 에 다시 온다
    self.debug_tab_count_applied = true;
    const want = std.fmt.parseInt(usize, std.mem.span(raw), 10) catch return;
    const cap = @min(want, 64); // 캡처 하네스가 셸을 무한히 띄우지 않게
    var have = pane_ops.activePane(self).terms.items.len;
    while (have < cap) : (have += 1) {
        pane_ops.newTermInActivePane(self) catch break;
    }
}

/// 탭 바 버튼의 **호버 배경**을 세운다(캡처 전용, `MARU_FORCE_TAB_HOVER=close|plus`).
///
/// ✕ glyph 와 `‹`/`›` 는 호버 없이도 그려지지만(각각 `close_tab=true`, 버튼 자리 상시 점유) **배경 quad
/// 는 호버일 때만** 얹힌다. 그 배경이 버튼 폭을 덮는지가 #2478 의 쟁점이었는데, 캡처 하네스에 포인터가
/// 없어 확인할 방법이 없었다 — `reapplyForcedSidebarHover` 가 사이드바 카드에서 푼 것과 같은 문제다.
///
/// **매 tick 다시 세운다.** 포인터가 탭 바 밖에 있으면 `hoverCursor` 가 곧바로 지운다(마우스가 창 위를
/// 지나기만 해도 그렇다). 같은 값이면 재적용하지 않는다.
///
/// - `close` — 활성 탭의 ✕ 배경. 탭이 여럿일 때 그 탭에만 얹힌다.
/// - `plus` — "+"(새 Term) 버튼 배경.
///
/// env 미설정이면 무동작.
pub fn reapplyForcedTabHover(self: *AppSession) void {
    const raw = std.c.getenv("MARU_FORCE_TAB_HOVER") orelse return;
    if (!self.surface_initialized) return;
    const spec = std.mem.span(raw);
    const pane = pane_ops.activePane(self);
    if (std.mem.eql(u8, spec, "close")) {
        const idx = pane_ops.paneActiveTermIndex(self, pane);
        if (self.hovered_tab_close) |cur| {
            if (cur.pane == pane and cur.tab == idx) return;
        }
        tab_ops.setHoveredTabClose(self, .{ .pane = pane, .tab = idx });
        self.metal_dirty = true;
    } else if (std.mem.eql(u8, spec, "plus")) {
        if (self.hovered_plus) |cur| {
            if (cur == pane) return;
        }
        tab_ops.setHoveredPlus(self, pane);
        self.metal_dirty = true;
    }
}

/// 심볼 피커를 연다(캡처 전용 debug-gate — native-editor-ui.md §7.5).
///
/// **파일 패널 훅과 따로 둔다.** 그쪽은 「이 실행에서 새로 열었을 때」만 끝까지 가는데(복원된 작업
/// 공간에 그 파일이 이미 있으면 중간에 돌아온다), 피커는 **이미 열려 있는 문서**에도 떠야 한다.
/// 처음에 그 함수 안에 두었다가 캡처가 빈 화면으로 나와서 알았다.
///
/// **사용자와 같은 경로를 태운다**(`toggleSymbolPicker`) — 상태를 심지 않으므로 저하 판정
/// (편집기 아님·심볼 없음·파싱 미완)도 제품이 정한 대로 돈다.
/// MARU_OPEN_FIND=<검색어> — 편집기 찾기를 그 검색어로 연다.
/// MARU_FIND_RULES=case,word,sel — 규칙 토글을 켠 상태로 만든다(§5.1 표시 검증).
/// MARU_FIND_SELECTION=<시작>-<끝> — 찾기를 **열기 전에** 그 범위를 골라 둔다(§5.1 — 범위는
/// 여는 순간 뜨므로 그 전이어야 한다).
///
/// **파일이 열리고 편집기 타깃이 설 때까지 기다린다** — 규칙 표시는 `target == .editor` 일 때만
/// 뜨므로, 그 전에 켜면 캡처에 안 남는다(심볼 피커 훅이 같은 이유로 재시도한다).
pub fn maybeDebugOpenFind(self: *AppSession) void {
    const q = std.c.getenv("MARU_OPEN_FIND") orelse return;
    if (self.debug_find_opened) return;
    self.debug_find_tries +%= 1;
    if (self.debug_find_tries > 240) {
        std.debug.print("MARU_OPEN_FIND: gave up; target={s} open={}\n", .{
            @tagName(self.chrome_host.find.target), self.chrome_host.find.open,
        });
        self.debug_find_opened = true;
        return;
    }
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return; // 아직 파일이 안 열렸다 — 다음 tick 에 다시 본다

    // **찾기를 열기 전에** 선택을 세운다 — 범위는 여는 순간 뜬다(§5.1).
    if (std.c.getenv("MARU_FIND_SELECTION")) |sv| {
        const spec = std.mem.span(sv);
        if (std.mem.indexOfScalar(u8, spec, '-')) |dash| {
            const lo = std.fmt.parseInt(usize, spec[0..dash], 10) catch 0;
            const hi = std.fmt.parseInt(usize, spec[dash + 1 ..], 10) catch 0;
            if (lo < hi) term.rt.editor_selection = maru.session.editor.selection.Selection.fromPoints(lo, hi);
        }
    }
    if (!self.chrome_host.find.open) find_ops.toggleFind(self);
    if (!self.chrome_host.find.open) return;
    if (self.chrome_host.find.target != .editor) return; // tick 이 타깃을 세울 때까지 기다린다

    self.chrome_host.find.input.query.clearRetainingCapacity();
    self.chrome_host.find.input.query.appendSlice(self.allocator, std.mem.span(q)) catch {};
    if (std.c.getenv("MARU_FIND_RULES")) |rv| {
        const rules = std.mem.span(rv);
        self.chrome_host.find.match_case = std.mem.indexOf(u8, rules, "case") != null;
        self.chrome_host.find.whole_word = std.mem.indexOf(u8, rules, "word") != null;
        if (std.mem.indexOf(u8, rules, "sel") != null) find_ops.toggleFindInSelection(self);
    }
    find_ops.recomputeFind(self);
    self.debug_find_opened = true;
    self.metal_dirty = true;
}

/// MARU_OPEN_COMMAND_PALETTE=1 — 커맨드 팔레트를 연 화면을 캡처한다.
/// MARU_OPEN_COMMAND_PALETTE_QUERY=<쿼리> 로 필터해서 한 무리만 남길 수 있다.
///
/// **팔레트는 편집기 액션 여섯이 닿는 유일한 길이다**(나머지는 chord 가 없다 —
/// docs/configuration-input.md "편집기 전용 action"). 그 행에 chord 가 제대로 뜨는지는
/// `default_app_bindings` 역스캔 결과라, 표를 고치면 화면이 따라 바뀐다.
pub fn maybeDebugOpenPalette(self: *AppSession) void {
    if (std.c.getenv("MARU_OPEN_COMMAND_PALETTE") == null) return;
    // 심볼 피커 훅과 같은 이유로 **한 번만 열지 않는다** — 나중에 뜨는 알림이 배타적으로 닫는다.
    if (self.chrome_host.palette.open) return;
    if (self.debug_palette_opened) return;
    self.debug_palette_tries +%= 1;
    if (self.debug_palette_tries > 240) self.debug_palette_opened = true; // 4초쯤이면 포기

    self.dispatchAppAction(.toggle_command_palette);
    if (std.c.getenv("MARU_OPEN_COMMAND_PALETTE_QUERY")) |qv| {
        self.chrome_host.palette.input.query.appendSlice(self.allocator, std.mem.span(qv)) catch {};
        self.recomputePalette();
    }
    self.metal_dirty = true;
}

pub fn maybeDebugOpenSymbolPicker(self: *AppSession) void {
    if (!self.dock_initialized) return;
    if (std.c.getenv("MARU_OPEN_SYMBOL_PICKER") == null) return;
    // **한 번만 열지 않는다.** 작업 공간 복원 알림처럼 **나중에 뜨는 오버레이**가 단일-오버레이
    // 불변식으로 피커를 닫는다(`dismissMessageOverlays`) — 한 번만 열면 캡처에 안 남는다. 실제로
    // 그렇게 빈 화면이 나왔다. 열릴 때까지 매 tick 다시 연다(캡처 전용이라 상한만 둔다).
    if (self.chrome_host.symbol_picker.open) return;
    if (self.debug_symbol_picker_opened) return;
    self.debug_symbol_picker_tries +%= 1;
    if (self.debug_symbol_picker_tries > 240) {
        // **조용히 포기하면 안 된다.** 못 연 채로 찍힌 그림이 PR 의 증거가 되고, 그때
        // 「파싱이 아직이다」·「다른 오버레이가 닫았다」·「심볼이 0개다」가 구별되지 않는다
        // (옆 축의 Lab 골든이 같은 이유로 색 없는 그림을 골든으로 굳혔다, 2026-08-31).
        const term = pane_ops.activePane(self).activeTerm();
        const st = &term.rt.editor_syntax;
        std.debug.print(
            "MARU_OPEN_SYMBOL_PICKER: 240 tick 안에 못 열었다 — pending={} symbols={d} crumb={d} open={}\n",
            .{ st.pending, st.symbols.items.len, st.crumb_syms.items.len, self.chrome_host.symbol_picker.open },
        );
        self.debug_symbol_picker_opened = true;
    }

    // MARU_OPEN_SYMBOL_PICKER_SIBLING=<마디 번호> — 그 체인 마디를 **누른 것처럼** 형제 목록을 연다
    // (§7.5 「체인 항목을 누르면 형제가 뜬다」). 밴드 클릭은 포인터로만 일어나므로 캡처 하니스에서는
    // 그 화면을 얻을 방법이 없다 — 전체 피커를 강제하는 것과 같은 자리다.
    //
    // **체인이 설 때까지 기다린다.** `crumb_syms` 는 밴드를 그려야 채워지는 파생값이라 첫 tick 에는
    // 비어 있다 — 그때 전체 피커를 열어 버리면 위 `open` 가드에 걸려 **영영 형제로 안 바뀐다**
    // (실제로 캡처가 전체 목록으로 나왔다).
    if (std.c.getenv("MARU_OPEN_SYMBOL_PICKER_SIBLING")) |nv| {
        const n = std.fmt.parseInt(usize, std.mem.span(nv), 10) catch 0;
        const term = pane_ops.activePane(self).activeTerm();
        const crumb = term.rt.editor_syntax.crumb_syms.items;
        if (n >= crumb.len) return; // 아직 체인이 없다 — 다음 tick 에 다시 본다
        editor_ops.openSiblingPicker(self, crumb[n]);
        self.metal_dirty = true;
        return;
    }

    editor_ops.toggleSymbolPicker(self);
    // MARU_OPEN_SYMBOL_PICKER_QUERY=<쿼리> — 필터된 목록을 캡처한다.
    if (std.c.getenv("MARU_OPEN_SYMBOL_PICKER_QUERY")) |qv| {
        self.chrome_host.symbol_picker.input.query.appendSlice(self.allocator, std.mem.span(qv)) catch {};
        editor_ops.recomputeSymbolPicker(self);
    }
    self.metal_dirty = true;
}
