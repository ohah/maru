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
const sidebar_ops = @import("sidebar.zig");
const tab_ops = @import("tab.zig");
const term_ops = @import("term.zig");
const notification_ops = @import("notification.zig");
const pane_ops = @import("pane.zig");
const find_ops = @import("find.zig");

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
                .agent_toggle, .agent => {},
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
                .agent_toggle, .agent => {},
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
                .agent_toggle, .agent => {},
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
                    .agent_toggle, .agent => {},
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

    var opened = editor_ops.openPath(self.io, self.allocator, path) catch |e| {
        // **왜 못 열었는지 구분해서 알린다.** §3.5가 "여는 것을 막는 이유는 UTF-8 아님 하나"라고
        // 정했으므로, 나머지 이유가 같은 메시지로 뭉개지면 그 계약을 확인할 수 없다.
        self.showNotice(switch (e) {
            error.NotUtf8 => "네이티브 편집기: UTF-8이 아니라 열지 않았습니다.",
            error.TooLarge => "네이티브 편집기: 파일이 읽기 상한을 넘었습니다.",
            error.Unreadable => "네이티브 편집기: 파일을 읽지 못했습니다.",
            error.OutOfMemory => "네이티브 편집기: 메모리가 모자랍니다.",
        });
        return;
    };
    defer opened.deinit(self.allocator);

    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "네이티브 편집기: {d}줄 · {s} · {s}{s}", .{
        opened.file.lineCount(),
        @tagName(opened.file.doc.format.dominant_ending),
        if (opened.file.doc.read_only) "읽기 전용" else "쓰기 가능",
        if (opened.file.doc.format.has_bom) " · BOM" else "",
    }) catch return;
    self.showNotice(msg);
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
