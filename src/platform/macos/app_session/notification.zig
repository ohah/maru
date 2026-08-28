//! 알림 · 벨 — OSC 9/777 알림 수신과 방출, 알림 이력과 읽음 상태, 알림 패널과 배지,
//! 터미널 벨(가청·시각 플래시), 원격 알림 폴링.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F13).
//!
//! 이름 함정이 없던 첫 그룹이다 — `notification`·`bell`·`badge`는 이 저장소에서 다른 뜻으로 쓰이지
//! 않는다. F4의 `pane`↔`filePanel`, F6의 `tab`↔`stable`, F12의 `ime`↔`Time`과 대비된다.
//!
//! `formatRelativeTime`이 여기 있다 — F12에서 `ime` 부분 문자열 함정으로 잘못 딸려왔던 그 함수인데,
//! 실제 호출자는 알림 목록의 상대 시각 표시뿐이라 소유는 여기다. **함정을 걸러 낸 뒤 제 자리를 찾은
//! 사례**다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const term_ops = @import("term.zig");
const agent_ops = @import("agent.zig");
const notificationLocation = app_session_mod.notificationLocation;
const is_macos = app_session_mod.is_macos;
const notification_location_buf_len = app_session_mod.notification_location_buf_len;
const tab_ops = @import("tab.zig");
const traffic_light_clearance_pt = app_session_mod.traffic_light_clearance_pt;
const triangleQuad = AppSession.triangleQuad;
const PendingNotification = AppSession.PendingNotification;
const Tab = app_session_mod.Tab;
const Term = app_session_mod.Term;
const layout_math = app_session_mod.layout_math;
const packRgbAlpha = app_session_mod.packRgbAlpha;
const sidebar_ops = @import("sidebar.zig");
const usizeOptEql = AppSession.usizeOptEql;

/// 인앱 알림 센터(notifications 컴포넌트)에 주입할 카드 배열을 arena로 빌드한다(palette buildPaletteRows 패턴 —
/// 매 프레임/클릭마다 재빌드). 히스토리를 **역순**(최신 먼저)으로 — title/body는 히스토리 owned slice 그대로(수명이
/// 더 김), relative_time만 arena 포맷, is_alive는 surface가 아직 살아있는지(findTermWhere 조회 — activate는 부수효과라
/// 안 씀). collect/itemAt/accept가 같은 역순 매핑(selected 0 = 최신 = 히스토리 끝)을 공유한다.
pub fn buildNotificationItems(self: *AppSession, arena: std.mem.Allocator) ![]chrome.components.notifications.Item {
    const len = self.notification_history.items.len;
    const items = try arena.alloc(chrome.components.notifications.Item, len);
    const now: i128 = std.Io.Clock.awake.now(self.io).nanoseconds;
    for (items, 0..) |*it, i| {
        const h = self.notification_history.items[len - 1 - i]; // 역순: 최신이 먼저
        const alive = term_ops.findTermWhere(self, h.surface_id, struct {
            fn pred(want: u64, term: *Term) bool {
                return term.surface.id == want;
            }
        }.pred) != null;
        it.* = .{
            .title = h.title,
            .body = h.body,
            .relative_time = formatRelativeTime(self, arena, now - h.timestamp_ns) catch "",
            .is_read = h.is_read,
            .is_alive = alive,
        };
    }
    return items;
}

/// 경과 시간(나노초)을 사람이 읽는 상대시간으로 — "방금"(<1분)/"N분 전"(<1시간)/"N시간 전"(<1일)/"N일 전". 음수
/// (시계 역행)는 0으로 본다. arena 포맷(notifications 카드 수명 = frame arena).
pub fn formatRelativeTime(self: *AppSession, arena: std.mem.Allocator, delta_ns: i128) ![]const u8 {
    _ = self;
    const ns: i128 = if (delta_ns < 0) 0 else delta_ns;
    const sec = @divFloor(ns, std.time.ns_per_s);
    // 문구는 `agent_dock.formatAgentSessionArchiveRelativeAge` 와 **같은 키를 쓴다** — 같은 개념을
    // 두 파일이 각자 적고 있었고(중복 리터럴), 그러면 한쪽만 고쳐지는 드리프트가 생긴다.
    // 여기는 arena 소유 슬라이스를 돌려주므로 스택 버퍼에 만든 뒤 복사한다(`i18n.format` 은 할당하지 않는다).
    var buf: [48]u8 = undefined;
    if (sec < 60) return maru.i18n.t(.ad_time_now);
    const min = @divFloor(sec, 60);
    if (min < 60) return arena.dupe(u8, maru.i18n.format(&buf, maru.i18n.t(.ad_time_minutes), &.{.{ .d = @intCast(min) }}));
    const hour = @divFloor(min, 60);
    if (hour < 24) return arena.dupe(u8, maru.i18n.format(&buf, maru.i18n.t(.ad_time_hours), &.{.{ .d = @intCast(hour) }}));
    const day = @divFloor(hour, 24);
    return arena.dupe(u8, maru.i18n.format(&buf, maru.i18n.t(.ad_time_days), &.{.{ .d = @intCast(day) }}));
}

/// 알림 카드 선택(Enter/클릭)을 처리한다 — selected(역순: 0=최신)를 히스토리 인덱스로 되돌려 그 surface를 봤다는
/// 의미로 같은 surface의 안읽음을 모두 읽음 처리(markNotificationsReadBySurface — 데스크톱 배너 클릭과 동일 정책)하고,
/// 그 surface로 점프(activateSurfaceById, 닫혔으면 false=점프 안 함)한 뒤 패널을 닫는다. 빈 목록/범위 밖이면 닫기만.
pub fn acceptNotification(self: *AppSession) void {
    const sel = self.chrome_host.notifications.selected;
    const len = self.notification_history.items.len;
    self.chrome_host.notifications.hide();
    self.metal_dirty = true;
    if (len == 0 or sel >= len) return;
    const history_index = len - 1 - sel; // 역순 매핑(목록 0 = 최신 = 히스토리 끝)
    const surface_id = self.notification_history.items[history_index].surface_id;
    markNotificationsReadBySurface(self, surface_id); // 그 surface를 봤으니 전체 읽음 — 데스크톱 배너 클릭과 동일 정책(통일)
    _ = self.activateSurfaceById(surface_id); // 닫힌 surface면 false(점프 안 함, 패널은 이미 닫음)
}

pub fn bellFlashTotalTicks(self: *const AppSession) u32 {
    return self.ticksForMs(bell_flash_total_ms);
}

pub fn pendingNotification(self: *AppSession) ?PendingNotification {
    if (!self.surface_initialized) return null;
    // OSC 9/777: 발신 surface의 코어가 자기 시퀀스를 파싱한다(reader 스레드가 core_mutex 아래 적용). 예전엔
    // activeSurface().core만 drain해 **비활성 pane/Term이 보낸 OSC 알림이 영영 안 나왔다** — 모든 Term의 코어를
    // 훑어 첫 pending을 그 surface.id로 실어 보낸다(클릭이 발신 Term으로 점프, activateSurfaceById). 한 호출에
    // 하나씩 drain하므로 여러 surface가 동시에 pending이면 다음 tick들에 이어 나온다.
    // 전면 배너 결정용: 사용자가 지금 그 안에 있는 Term(포커스 창의 활성 탭·pane·Term). 발신 Term이 이것이면 OSC
    // 배너를 전면에서 억제(목록만), 그 외 background pane/가로탭/비활성 탭이면 전면에서도 배너를 띄운다.
    const focused_term: ?*Term = if (self.window_focused) tab_ops.activeTab(self).activePane().activeTerm() else null;
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (!term.rt.live_initialized or term.rt.terminated) continue; // 종료(미reap) Term은 건너뜀(dispatchBell과 동형)
                // **훅 모드 Term 은 훅에서 알림이 온다**(계약 §6). 같은 tail(`emitNotification`)을 타므로
                // 위치 접두·인앱 히스토리·전면 배너 억제가 관측 모드와 똑같이 적용된다.
                //
                // **host-backed 검사보다 앞에 둔다.** 이 알림은 훅 로그를 우리가 읽어 Term 에 쌓아 둔
                // **client 측 상태**라 코어가 placeholder 인지와 무관하다. 아래 `continue` 뒤에 두었더니
                // keep-alive 를 켠 순간 그 Term 의 훅 알림이 **통째로 사라졌다** — 원격 pull 경로는 host
                // 코어의 OSC 만 꺼내므로 이 슬롯을 볼 자리가 없다.
                //
                // 여기서 `continue` 하지 않는다 — 아래 drain 이 그 Term 의 OSC `pending` 을 **비우는** 일을
                // 겸한다(비우지 않으면 다음 tick 마다 같은 것을 다시 보고 루프가 그 Term 에서 멈춘다).
                if (agent_ops.agentHookMode(self, term) == .hook) {
                    if (agent_ops.takeAgentHookNotice(self, term)) |notice| {
                        const title = switch (notice.kind) {
                            .done => maru.i18n.t(.agent_hook_notice_done),
                            .failed => maru.i18n.t(.agent_hook_notice_failed),
                            .attention => maru.i18n.t(.agent_hook_notice_attention),
                            .none => unreachable,
                        };
                        if (emitNotification(self, tab, term, focused_term, title, notice.body)) |n| return n;
                    }
                }
                // host-backed Term은 코어가 placeholder라 OSC 알림이 host에 있다 — 값싼 코어 drain에서 건너뛰고
                // 아래 RPC pull로(훅 알림은 위에서 이미 처리했다).
                if (is_macos and term.surface.remote != null) continue;
                if (drainOscNotificationFrom(self, tab, term, focused_term)) |n| return n;
            }
        }
    }
    // host-backed Term의 알림은 RPC로 pull한다(§6.32 GUI surfacing) — tick당 원격 Term 하나 round-robin.
    if (is_macos) return pollRemoteNotification(self, focused_term);
    return null;
}

/// 한 Term의 코어에 쌓인 OSC 9/777 데스크톱 알림을 drain한다(있으면 그 알림, 없으면 null). reader 스레드가
/// core_mutex 아래 notification_pending/title/body를 세우므로 **lockCore 아래에서 읽고 owned 버퍼로 복사**한다
/// (pendingNotification 반환 슬라이스는 코어 메모리를 가리켜, 락 없이 들고 dupe하면 reader가 clearNotification으로
/// 비우는 사이 torn read가 난다 — focusedTermCwd와 같은 함정). 반환 슬라이스는 self.notification_*_out 소유라
/// 락 밖에서도 유효하다. config notifications.osc=false면 pending만 비우고(다음 tick 재발화 방지) null — 호출 루프가
/// 다음 surface로 넘어가 모든 pending을 정리한다(종류별 on/off를 발화 지점에서 단일하게 막는 정책).
/// dupe 실패도 pending을 비우고 null(best-effort). 인앱 히스토리에도 dupe 보관한다.
/// `focused_term`=지금 보고 있는 그 Term(없으면 null=창 비포커스) — 발신 Term이 이것이면 foreground_banner=false
/// (전면에서 자기 화면 노이즈 억제, 목록만), 그 외면 true(전면이어도 배너).
/// `tab`=발신 Term이 속한 워크스페이스(호출부 pendingNotification의 tabs 루프에서 넘김) — 제목 위치 접두용.
pub fn drainOscNotificationFrom(self: *AppSession, tab: *Tab, term: *Term, focused_term: ?*Term) ?PendingNotification {
    term.surface.lockCore(self.io);
    defer term.surface.unlockCore(self.io);
    const pending = term.surface.core.pendingNotification() orelse return null;
    if (!self.loaded_config.config.notifications.osc) {
        term.surface.core.clearNotification();
        return null;
    }
    // **훅 모드 Term 에서는 OSC 알림을 쓰지 않는다**(계약 §1.1). 그 Term 의 알림은 훅 payload 에서 오고,
    // 여기서 함께 방출하면 같은 턴에 두 번 울린다. 게이트와 같은 모양으로 **pending 은 비운다** — 안 비우면
    // 다음 tick 마다 같은 것을 다시 보고 루프가 그 Term 에서 멈춘다.
    //
    // ⚠️ 이 자리는 «훅 모드면 버린다» 이고, 계약 §1.2가 말한 «강등 전까지 보류» 는 아직 아니다. 보류는
    // 훅 모드로 **시작했는데 훅이 안 오는** 구간을 위한 것인데, 지금 판정은 로그 파일이 생긴 뒤에만 훅
    // 모드가 되므로 그 구간 자체가 없다(파일이 없으면 관측 모드이고 알림은 그대로 나간다).
    if (agent_ops.agentHookMode(self, term) == .hook) {
        term.surface.core.clearNotification();
        return null;
    }
    // pending.title/body는 코어 메모리라 락 아래에서만 유효 — emitNotification이 dupe해 owned로 복사하므로 여기서
    // (락 든 채) 부른 뒤 clear한다. emitNotification은 코어를 안 만져(dupe + 히스토리 ring) 데드락이 없다.
    const n = emitNotification(self, tab, term, focused_term, pending.title, pending.body);
    term.surface.core.clearNotification();
    return n;
}

/// OSC 9/777 알림 한 건을 인앱 히스토리에 넣고 Swift가 띄울 `PendingNotification`으로 만든다 — **in-process 코어 drain과
/// host-backed 원격 pull의 공통 tail**(§6.32 GUI surfacing). `title`/`body`는 borrowed(dupe해 notification_*_out 소유로 복사)
/// 라 caller가 소스를 clear/deinit해도 안전하다. 제목에 위치(탭 › 팬)를 접두하고, 발신 Term이 지금 보고 있는 Term이면
/// foreground_banner=false(전면 노이즈 억제, 목록만)로 둔다. 포맷/dupe 실패(OOM)면 null(best-effort). `notifications.osc`
/// 게이트와 소스 소비는 caller가 한다. 위치 라벨은 메인 스레드 상태(auto_title/custom_name/surface.title)만 읽는다.
pub fn emitNotification(self: *AppSession, tab: *Tab, term: *Term, focused_term: ?*Term, title: []const u8, body: []const u8) ?PendingNotification {
    var loc_buf: [notification_location_buf_len]u8 = undefined;
    return emitNotificationAt(self, term, focused_term, notificationLocation(&loc_buf, tab, term), title, body, null, null);
}

fn emitNotificationAt(
    self: *AppSession,
    term: *Term,
    focused_term: ?*Term,
    display_label: []const u8,
    title: []const u8,
    body: []const u8,
    route: ?app_session_mod.StableNotificationRoute,
    occurred_at_ns: ?u64,
) ?PendingNotification {
    if (self.notification_title_out.len > 0) {
        self.allocator.free(self.notification_title_out);
        self.notification_title_out = &.{};
    }
    if (self.notification_body_out.len > 0) {
        self.allocator.free(self.notification_body_out);
        self.notification_body_out = &.{};
    }
    self.notification_title_out = (if (title.len > 0)
        std.fmt.allocPrint(self.allocator, "{s} · {s}", .{ display_label, title })
    else
        self.allocator.dupe(u8, display_label)) catch return null;
    self.notification_body_out = notificationBodyOwned(self, term, body) catch {
        self.allocator.free(self.notification_title_out);
        self.notification_title_out = &.{};
        return null;
    };
    const osc_surface_id = term.surface.id;
    const fg_banner = !(focused_term != null and term == focused_term.?);
    // 인앱 알림 센터는 body를 **한 줄 텍스트 run**으로 그린다 — 개행이 살아 있으면 글자가 뭉개진다. OS 배너는
    // 여러 줄을 제대로 보여주므로 그쪽엔 원문을 그대로 보내고, 히스토리에만 눕힌 사본을 넣는다(code-review max).
    const history_body = flattenForHistory(self, self.notification_body_out) catch null;
    defer if (history_body) |h| self.allocator.free(h);
    _ = pushNotificationHistoryAt(
        self,
        self.notification_title_out,
        history_body orelse self.notification_body_out,
        osc_surface_id,
        if (occurred_at_ns) |ns| @as(i128, ns) else @as(i128, std.Io.Clock.awake.now(self.io).nanoseconds),
        route,
    );
    return .{
        .title = self.notification_title_out,
        .body = self.notification_body_out,
        .surface_id = osc_surface_id,
        .foreground_banner = fg_banner,
        .route = route,
    };
}

/// 알림 **히스토리용** 한 줄 사본(owned) — 개행을 중점(·)으로 바꾼다. 원문을 안 고치는 이유는 OS 배너가
/// 여러 줄을 제대로 보여주기 때문이다(두 표면의 요구가 다르다).
pub fn flattenForHistory(self: *AppSession, body: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, body, '\n') == null) return self.allocator.dupe(u8, body);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    var it = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        if (!first) try out.appendSlice(self.allocator, " \u{00b7} ");
        try out.appendSlice(self.allocator, t);
        first = false;
    }
    return out.toOwnedSlice(self.allocator);
}

/// 알림 본문(owned) = provider 문구 + 그 Term의 **마지막 대화**(docs/sidebar-agent-list.md §7).
///
/// provider가 주는 문구는 `Claude is waiting for your input`처럼 **어느 세션인지 말해주지 않는다**. 에이전트를
/// 여럿 돌리면 배너만 보고는 무엇에 대한 알림인지 알 수 없어 결국 창을 뒤져야 한다. 제목의 위치 라벨(탭 › 팬)이
/// 자리를 알려준다면, 마지막 프롬프트는 **무엇을 시킨 건지**를 알려준다.
///
/// 프롬프트를 먼저 싣는다 — OS 배너는 몇 줄만 보여주고 잘라내므로, 식별에 더 쓸모 있는 쪽이 앞에 와야 한다.
/// 대화를 못 읽었으면(계약 1) provider 문구만 그대로 나가 기존 동작과 같다.
pub fn notificationBodyOwned(self: *AppSession, term: *Term, body: []const u8) ![]u8 {
    const tr = maru.session.agent_transcript;
    const prompt = tr.clampUtf8(term.agent_transcript.prompt(), notification_conversation_max_bytes);
    const reply = tr.clampUtf8(term.agent_transcript.reply(), notification_conversation_max_bytes);
    if (prompt.len == 0 and reply.len == 0) return self.allocator.dupe(u8, body);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    if (body.len > 0) try out.appendSlice(self.allocator, body);
    if (prompt.len > 0) {
        if (out.items.len > 0) try out.append(self.allocator, '\n');
        // 프롬프트 마커(❯)로 "사용자가 친 것"임을 응답과 구분한다 — 두 줄이 붙어 나오면 누가 한 말인지 흐려진다.
        try out.appendSlice(self.allocator, "\u{276F} ");
        try out.appendSlice(self.allocator, prompt);
    }
    if (reply.len > 0) {
        if (out.items.len > 0) try out.append(self.allocator, '\n');
        try out.appendSlice(self.allocator, reply);
    }
    return out.toOwnedSlice(self.allocator);
}

/// host-backed Term의 OSC 9/777 알림을 host에서 pull해 GUI 알림 경로에 잇는다(§6.32 — #1523 host→client 전달의 GUI
/// surfacing). host core가 알림을 파싱하므로 client placeholder 코어엔 없어 RPC(`runtime.notification`)로 뺀다.
///
/// **폴링을 프레임 속도에서 뗀다.** 예전에는 tick 마다 원격 Term 하나를 round-robin 으로 물어봤다. 인프로세스에서
/// 같은 질문은 코어 락 아래 필드 읽기라 사실상 공짜였는데, 코어가 host 로 나가면서 한 줄의 의미가 **프로세스 간
/// 왕복**으로 바뀌었다. 그 사실이 호출부에는 드러나지 않아, 유휴 상태에서도 초당 60 번 host 를 깨우고 있었다
/// (2026-08-28 실측: 앱 73% + host 33% CPU. host 는 답하느라 영영 잠들지 못한다).
///
/// 그래서 두 갈래로 고른다.
///   1. **힌트** — 마지막 확인 이후 출력을 받은 Term 을 먼저 본다. 알림은 출력의 결과로만 생기므로 조용한 Term 을
///      물어볼 이유가 없고, 출력이 난 Term 은 그 tick 에 바로 본다(지연이 오히려 줄어든다).
///   2. **바닥 주기** — 힌트가 없어도 `notification_floor_poll_ms` 마다 한 칸씩 round-robin 한다. OSC 9/777 은
///      화면을 안 바꿀 수 있어 출력 신호가 안 서는 경우가 있는데, 이 순회가 그것을 반드시 줍는다.
///
/// `notifications.osc` 가 꺼져 있어도 **바닥 주기로는 비운다**. 게이트를 RPC 앞에 두면 RPC 가 0 이 되지만,
/// `notification_config_update` 는 host 슬롯을 비우지 않아 껐을 때 들어온 알림이 고이고 **다시 켜는 순간 옛 알림이
/// 튄다**. 비우기 위한 순회는 남기고 결과만 버린다. best-effort.
const notification_floor_poll_ms: u32 = 100;

pub fn pollRemoteNotification(self: *AppSession, focused_term: ?*Term) ?PendingNotification {
    if (is_macos) {
        if (app_session_mod.app_remote_backend == null) return null;
        const osc_enabled = self.loaded_config.config.notifications.osc;
        // 바닥 주기 카운트다운. 이 tick 이 바닥이면 round-robin 한 칸을 돌린다.
        const floor_tick = blk: {
            if (self.remote_notif_floor_ticks == 0) {
                self.remote_notif_floor_ticks = self.ticksForMs(notification_floor_poll_ms);
                break :blk true;
            }
            self.remote_notif_floor_ticks -= 1;
            break :blk false;
        };
        // 원격 Term을 순서대로 세어 cursor 위치의 하나를 고르고(중첩 tabs/panes/terms를 flat index로), 그와 별개로
        // 출력 힌트가 선 Term 중 처음 하나를 집는다. 힌트는 **집는 순간 내린다** — 이번에 확인했다는 뜻이다.
        var count: usize = 0;
        var target_tab: ?*Tab = null;
        var target_term: ?*Term = null;
        var hinted_tab: ?*Tab = null;
        var hinted_term: ?*Term = null;
        for (self.tabs.items) |tab| {
            for (tab.panes.items) |pane| {
                for (pane.terms.items) |term| {
                    if (!term.rt.live_initialized or term.rt.terminated or term.surface.remote == null) continue;
                    if (count == self.remote_notif_cursor) {
                        target_tab = tab;
                        target_term = term;
                    }
                    if (hinted_term == null and term.output_since_notify_check) {
                        hinted_tab = tab;
                        hinted_term = term;
                    }
                    count += 1;
                }
            }
        }
        if (count == 0) {
            self.remote_notif_cursor = 0;
            return null;
        }
        // 힌트가 있으면 그것을, 없으면 바닥 tick 에만 cursor 한 칸을. 둘 다 아니면 이 tick 은 RPC 를 보내지 않는다.
        // 알림이 꺼져 있으면 힌트는 무시한다 — 비우기 위한 바닥 순회만 남긴다.
        var tab: *Tab = undefined;
        var term: *Term = undefined;
        if (osc_enabled and hinted_term != null) {
            hinted_term.?.output_since_notify_check = false;
            tab = hinted_tab.?;
            term = hinted_term.?;
        } else if (floor_tick) {
            self.remote_notif_cursor = (self.remote_notif_cursor + 1) % count;
            // cursor가 count 넘음(원격 Term 감소) — 다음 바닥 tick에 보정된다.
            term = target_term orelse return null;
            term.output_since_notify_check = false;
            tab = target_tab.?;
        } else return null;
        const notif = app_session_mod.app_remote_backend.?.takeNotificationFor(term.rt.handle) orelse return null;
        defer notif.deinit(app_session_mod.app_remote_backend.?.allocator); // takeNotificationFor가 backend allocator로 dupe.
        // 게이트. 여기까지 왔다는 것은 «바닥 순회로 슬롯을 비우러 온» 경우뿐이다(위에서 osc 가 꺼져 있으면 힌트를
        // 건너뛴다). 슬롯은 이미 비웠으니 결과만 버린다 — 이것이 다시 켰을 때 옛 알림이 튀지 않는 이유다.
        if (!osc_enabled) return null;
        // **훅 모드 Term 에서는 OSC 알림을 쓰지 않는다**(계약 §1.1) — in-process `drainOscNotificationFrom` 과
        // 같은 규율이다. 여기서 함께 방출하면 같은 턴에 두 번 울린다. host 슬롯은 위에서 이미 비웠다(drop).
        if (agent_ops.agentHookMode(self, term) == .hook) return null;
        if (notif.route) |route| {
            return emitNotificationAt(
                self,
                term,
                focused_term,
                notif.display_label orelse return null,
                notif.title,
                notif.body,
                .{ .host_id = route.host_id, .runtime_id = route.runtime_id, .event_id = route.event_id },
                route.occurred_at_ns,
            );
        }
        return emitNotification(self, tab, term, focused_term, notif.title, notif.body);
    }
    return null;
}

/// 인앱 알림 센터 히스토리에 한 건 보관한다(title/body dupe — pendingNotification이 드레인하는 owned 버퍼와
/// 소유권이 겹치지 않게 복사한다). 상한(config notifications.history-limit) 초과면 가장 오래된 걸 버리고, 그게 안
/// 읽음이면 unread를 보정한다. dupe/append 실패는 best-effort로 버린다(알림 보관은 부가 기능).
/// 알림을 인앱 센터에 추가하고 성공하면 true. 할당 실패(title/body dup·append)면 false를 돌려준다 —
/// drainUpdateCheck가 이 결과로 "성공했을 때만" 1회 가드를 닫아 일시적 실패 시 재시도하게 한다.
pub fn pushNotificationHistory(self: *AppSession, title: []const u8, body: []const u8, surface_id: u64) bool {
    return pushNotificationHistoryAt(
        self,
        title,
        body,
        surface_id,
        @as(i128, std.Io.Clock.awake.now(self.io).nanoseconds),
        null,
    );
}

fn pushNotificationHistoryAt(
    self: *AppSession,
    title: []const u8,
    body: []const u8,
    surface_id: u64,
    timestamp_ns: i128,
    route: ?app_session_mod.StableNotificationRoute,
) bool {
    const title_dup = self.allocator.dupe(u8, title) catch return false;
    const body_dup = self.allocator.dupe(u8, body) catch {
        self.allocator.free(title_dup);
        return false;
    };
    if (self.notification_history.items.len >= @as(usize, self.loaded_config.config.notifications.history_limit)) {
        const dropped = self.notification_history.orderedRemove(0);
        if (!dropped.is_read) self.notification_unread -|= 1;
        self.allocator.free(dropped.title);
        self.allocator.free(dropped.body);
    }
    self.notification_history.append(self.allocator, .{
        .title = title_dup,
        .body = body_dup,
        .surface_id = surface_id,
        .timestamp_ns = timestamp_ns,
        .route = route,
        .is_read = false,
    }) catch {
        self.allocator.free(title_dup);
        self.allocator.free(body_dup);
        return false;
    };
    self.notification_unread += 1;
    self.metal_dirty = true; // 배지 갱신 재렌더
    return true;
}

/// 히스토리 항목 index를 읽음 처리한다(안 읽음이었으면 unread 1 감소). 범위 밖/이미 읽음이면 무동작.
pub fn markNotificationRead(self: *AppSession, index: usize) void {
    if (index >= self.notification_history.items.len) return;
    if (self.notification_history.items[index].is_read) return;
    self.notification_history.items[index].is_read = true;
    self.notification_unread -|= 1;
}

/// 알림 센터 목록의 list_index(역순: 0=최신)에 해당하는 히스토리 항목을 삭제한다(owned title/body free). 안 읽음
/// 이었으면 unread 보정. 목록이 줄었으니 패널 selected를 clamp한다(다음 collect의 setItemCount와 같은 단일 출처).
pub fn deleteNotification(self: *AppSession, list_index: usize) void {
    const len = self.notification_history.items.len;
    if (len == 0 or list_index >= len) return;
    const history_index = len - 1 - list_index; // 역순 매핑(목록 0 = 최신 = 히스토리 끝)
    const removed = self.notification_history.orderedRemove(history_index);
    if (!removed.is_read) self.notification_unread -|= 1;
    self.allocator.free(removed.title);
    self.allocator.free(removed.body);
    self.chrome_host.notifications.setItemCount(self.notification_history.items.len);
    self.metal_dirty = true;
}

/// 모든 알림을 읽음 처리한다(배지 0). 히스토리 항목은 유지 — 목록엔 남고 안읽음 점(●)만 사라진다.
pub fn markAllNotificationsRead(self: *AppSession) void {
    for (self.notification_history.items) |*it| it.is_read = true;
    self.notification_unread = 0;
    self.metal_dirty = true;
}

/// 그 surface를 봤으니(데스크톱 배너 클릭 또는 인앱 카드 클릭) 그 surface_id의 안 읽은 히스토리 항목을 모두 읽음
/// 처리한다(배너↔인앱 센터 읽음 동기화). 같은 surface가 여러 번 알림했으면 다 읽음 — 그 터미널을 봤다는 의미라 일관.
/// 한 항목 읽음 회계는 markNotificationRead 단일 출처를 재사용한다(이미 읽음이면 내부에서 무동작). dirty는 형제
/// 알림 mutator(push·delete·markAll·clear)와 같이 무조건 세운다 — 배너/카드 클릭은 cold path라 조건부 절약 불필요.
pub fn markNotificationsReadBySurface(self: *AppSession, surface_id: u64) void {
    for (self.notification_history.items, 0..) |*it, i| {
        if (it.surface_id == surface_id) markNotificationRead(self, i);
    }
    self.metal_dirty = true;
}

/// 모든 알림을 히스토리에서 삭제한다(owned 전부 free). 패널은 빈 목록("알림 없음")으로 유지된다.
pub fn clearNotifications(self: *AppSession) void {
    for (self.notification_history.items) |it| {
        self.allocator.free(it.title);
        self.allocator.free(it.body);
    }
    self.notification_history.clearRetainingCapacity();
    self.notification_unread = 0;
    self.chrome_host.notifications.setItemCount(0);
    self.metal_dirty = true;
}

/// G12 BEL: 활성 surface에 pending 벨이 있으면 true(코어 플래그를 비운다). Swift가 시스템 벨(NSSound.beep)을
/// 울린다 — 코어는 OS 소리를 직접 내지 않는다(OSC 52/9·777과 같은 경계). 한 tick 1회로 합쳐져 벨 폭주 방지.
/// 활성 surface의 BEL 1회를 drain해 config에 따라 분배한다(audible 소리·visual flash·dock 배지). 매 tick frame
/// build 직전에 호출 — 코어 플래그를 **단일 drain**하므로 takeBell/take_bell_badge는 여기서 세운 신호만 본다.
/// 코어 플래그는 audible/visual 무관하게 항상 비운다(음소거·미설정에도 누적 방지). (F2-4)
pub fn dispatchBell(self: *AppSession) void {
    if (!self.surface_initialized) return;
    // **모든 live term core**의 BEL을 drain(OR) — 배경 탭/pane/term의 BEL도 잡는다(active surface만 보던 한계, 리뷰 D).
    // Dock 배지는 애초에 "언포커스(=배경) 벨"을 알리는 용도라 active만 보면 그 핵심 케이스를 놓친다. bell_pending은
    // 단일 writer(리더 스레드)가 세우는 bool이라 active-surface 때와 같은 무잠금 읽기다(bool torn read 없음 — benign
    // racy flag, docs/io-render-threading.md). **모든** core에 takeBell을 호출해 비워야 다음 tick 재트리거를 막는다(단락 금지).
    var rang = false;
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (!term.rt.live_initialized or term.rt.terminated) continue;
                if (comptime is_macos) {
                    if (term.surface.remote != null) {
                        if (app_session_mod.app_remote_backend) |*backend| {
                            if (backend.takeBellFor(term.rt.handle)) rang = true;
                        }
                        continue;
                    }
                }
                if (term.surface.core.takeBell()) rang = true; // 매 live core drain(클리어) — OR로 누적
            }
        }
    }
    if (rang) { // BEL 1회 이상 — config에 따라 분배
        if (self.audible_bell) self.bell_audible_pending = true; // Swift take_bell이 NSSound.beep
        if (self.bell_visual) self.bell_flash_ticks = bellFlashTotalTicks(self); // 시각 flash 시작
        if (self.bell_dock_badge and !self.window_focused) self.bell_badge_pending = true; // 언포커스 시 Dock 배지
    }
    // 시각 flash가 진행 중이면 매 tick 재빌드해 페이드를 그린다(appendBellFlashQuad가 alpha를 줄이고 1 감소).
    if (self.bell_flash_ticks > 0) self.metal_dirty = true;
}

pub fn takeBell(self: *AppSession) bool {
    const p = self.bell_audible_pending; // dispatchBell이 BEL+audible 시 세움
    self.bell_audible_pending = false;
    return p;
}

/// Dock 배지 1회성 신호 drain — pending이면 true(비움). Swift가 tick마다 호출해 NSApp.dockTile.badgeLabel을 세운다. (F2-4)
pub fn takeBellBadge(self: *AppSession) bool {
    const p = self.bell_badge_pending;
    self.bell_badge_pending = false;
    return p;
}

/// 세팅 GUI에서 데스크톱 알림 토글을 켠 경우 macOS 알림 권한 요청을 Swift에 맡기는 1회성 신호 drain.
/// Swift가 tick마다 호출해 true면 UNUserNotificationCenter.requestAuthorization을 시도한다.
pub fn takeNotificationAuthorizationRequest(self: *AppSession) bool {
    const pending = self.notification_authorization_pending;
    self.notification_authorization_pending = false;
    return pending;
}

/// 호버 중인 알림 카드를 갱신한다(알림 패널 열림 시 hoverCursor가 hitTest 결과로 호출). 바뀌면 재드로우만 — 카드
/// 데이터는 매 프레임 platform이 주입하므로 사이드바처럼 rebuild는 필요 없다. 같은 카드면 무동작(한 카드 안 이동 dedup).
pub fn setHoveredNotification(self: *AppSession, idx: ?usize) void {
    if (usizeOptEql(self.chrome_host.notifications.hovered, idx)) return;
    self.chrome_host.notifications.hovered = idx;
    self.metal_dirty = true;
}

/// 알림 패널 hit-test 단일 출처(클릭 라우팅 mouse()와 호버 라우팅 hoverCursor가 공유). 임시 arena로 동적 Item을
/// 빌드(buildNotificationItems — 역순)해 컴포넌트 hitTest에 넘기고 결과 Hit만 돌려준다(Item은 함수 안에서만 살고
/// Hit은 인덱스/태그라 escape하지 않는다). 빌드 실패(OOM)면 null. 클릭/호버가 같은 좌표→Hit 매핑을 쓰게 해 둘이 어긋나지 않는다.
pub fn notificationHitAt(self: *AppSession, x_px: f64, y_px: f64) ?chrome.components.notifications.Hit {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const items = buildNotificationItems(self, arena_state.allocator()) catch return null;
    return chrome.components.notifications.hitTest(&self.chrome_host.notifications, items, self.buildChromeProps(), x_px, y_px);
}

/// 시각 벨(bell.visual): flash 중(bell_flash_ticks>0)이면 화면 전체(backing px)를 전경색 반투명 GpuQuad로 덮고
/// 남은 tick 비율로 alpha를 정해 페이드한다. over 패스(layer 1)라 셀·chrome 위에 뜬다. 매 frame 1 감소 —
/// 0이면 멈춘다. metal_dirty(다음 frame 재빌드)는 dispatchBell이 세운다. dispatchBell 단일 drain 후 build에서 호출(F2-4).
pub fn appendBellFlashQuad(self: *AppSession) void {
    if (self.bell_flash_ticks == 0) return;
    // alpha = peak × (남은 tick / 총 tick). 첫 tick=full peak → 마지막 tick=거의 투명.
    const fade_milli: u32 = bell_flash_peak_milli * self.bell_flash_ticks / bellFlashTotalTicks(self);
    const alpha: u8 = @intCast(@min(@as(u32, 255), fade_milli * 255 / 1000));
    const color: u32 = packRgbAlpha(self.appearance.theme.foreground, alpha); // straight-alpha(셰이더가 rgb*=a)
    self.gpu_quads.append(self.allocator, .{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(self.backing_width_px),
        .h = @floatFromInt(self.backing_height_px),
        .corner_radii = .{ 0, 0, 0, 0 },
        .border_widths = .{ 0, 0, 0, 0 },
        .fill_color0 = color,
        .fill_color1 = color,
        .border_color = 0,
        .gradient_kind = 0,
        .layer = 1, // over 패스 — 화면 전체 덮음(scrollbar layer 3·modal layer 1과 같은 over, append 순서로 위)
    }) catch {};
    self.bell_flash_ticks -= 1; // 페이드: 다음 frame은 더 흐리게(0이면 다음 dispatchBell이 metal_dirty 안 세움)
}

/// 펼침 헤더 알림 배지(흰 숫자 cell·빨강 원 quad)가 올라갈 col — 종(2칸, bell_col·bell_col+1) **우측 한 칸**.
/// 종 글리프는 .m이 1.7cw×1.7ch(코너 아이콘과 동일 크기·2칸 footprint 중앙)로 그려 우상단 모서리가
/// ≈(bell_col+1.85)·cw인데, 배지 원 반지름이 0.41ch≈0.85cw(ch≈2cw)라 bell_col+2(중심 (bell_col+2.5)·cw)의
/// 배지 좌단(≈(bell_col+1.65)·cw)이 종 우측 모서리에 ~0.2cw만 겹쳐 iOS식 코너 배지가 된다(실측: 종 우측끝 95px,
/// 배지 93..107px). 종을 코너 크기로 줄여도 이 값이 그대로 맞다(좁아진 종 = 모서리가 안쪽으로 0.85cw 와도 반지름이 흡수).
/// appendBellAndBadge(셀)와 appendNotificationBadge(quad)의 단일 출처라 둘이 어긋나지 않는다.
/// **정의는 공유 모듈**(`cell_text.notificationBadgeCol`) — 그리기와 히트테스트가 같은 열을 봐야 한다.
pub fn notificationBadgeCol(bell_col: u16) u16 {
    return maru.cell_text.notificationBadgeCol(bell_col);
}

pub fn appendNotificationBadge(self: *AppSession) void {
    if (self.notification_unread == 0 or self.sidebar_collapsed) return;
    const cw = self.cell_width_px;
    const ch = self.cell_height_px;
    if (cw == 0 or ch == 0 or self.tabs.items.len == 0) return;
    if (self.sidebar_width_px == 0 or self.sidebar_header_height_px == 0) return;
    const cols = self.sidebar_width_px / cw;
    if (cols < 13) return; // 헤더가 안 그려지는 폭(buildSidebarHeaderDrawList cols<13과 정합) — 배지도 생략
    const cw_f: f32 = @floatFromInt(cw);
    const ch_f: f32 = @floatFromInt(ch);
    const badge_col = notificationBadgeCol(@intCast(cols - 12)); // 종(cols-12, 2칸) 우측 한 칸 = cols-10 (코너 크기 종의 우상단 모서리에 원 좌단이 ~0.2cw 겹침)
    // 배지 셀 중심(가로)·헤더 row 0 세로 중심(backing px). 흰 숫자가 원 가운데 오게 셀 중심에 맞춘다.
    // 세로 기준은 `sidebarHeaderIconRowTopPx` — 헤더 아이콘 줄은 y=0이 아니라 신호등 띠 안 세로 중앙에 놓인다.
    // 그 위에서 digit 글리프 시각 중심에 맞춰 notification_badge_center_in_cell을 더한다.
    // 원이 너무 크면 옆 ◧ 아이콘에 닿으므로 0.82ch.
    const center_x: f32 = (@as(f32, @floatFromInt(badge_col)) + 0.5) * cw_f;
    const row_top_f: f32 = @floatFromInt(sidebar_ops.sidebarHeaderIconRowTopPx(self));
    const center_y: f32 = row_top_f + ch_f * notification_badge_center_in_cell;
    const d: f32 = ch_f * 0.82; // 원 지름(또렷하면서 ◧ 아이콘과 안 닿게)
    const red = packRgbAlpha(.{ .r = 0xE5, .g = 0x48, .b = 0x4D }, 0xFF); // 알림 배지 빨강(흰 숫자 대비). straight-alpha(셰이더 rgb*=a)
    self.gpu_quads.append(self.allocator, .{
        .x = center_x - d / 2.0,
        .y = center_y - d / 2.0,
        .w = d,
        .h = d,
        .corner_radii = .{ d / 2.0, d / 2.0, d / 2.0, d / 2.0 }, // 원형
        .border_widths = .{ 0, 0, 0, 0 },
        .fill_color0 = red,
        .fill_color1 = red,
        .border_color = 0,
        .gradient_kind = 0,
        .layer = 4, // 사이드바 bg strip 뒤·헤더 글리프 앞(흰 숫자가 위에 보이게)
    }) catch {};
}

/// 사이드바 접힘 시 좌상단 알림 종(🔔) 글리프 col — 신호등 클리어런스 오른쪽 **첫(가장 왼쪽)** 아이콘. 펼침 헤더처럼
/// 종이 ◧ '왼쪽'에 와 접힘↔펼침을 토글해도 종/◧ 순서가 안 바뀐다(사용자 피드백 "◧ 누르면 알림이랑 위치가 바뀜").
/// render(buildCollapsedToggleDrawList)·hit-test(collapsedNotificationRect)·패널 anchor(openNotificationPanel)가 같은 값을
/// 쓴다(단일 출처). cell_width 0이면 0.
pub fn collapsedBellCol(self: *const AppSession) u16 {
    if (self.cell_width_px == 0) return 0;
    const clearance_px = layout_math.ptToPx(traffic_light_clearance_pt, self.scale_milli); // 신호등 클리어런스(backing px, pt→px 단일 출처)
    // 신호등 오른쪽 + 여백 + 배지폭. 종 왼쪽으로 "9+" 배지가 collapsed_badge_max_cells칸 뻗으므로, 종 base에 그 폭을
    // 더 보태 배지 좌단(=종−배지폭)이 클리어런스 + 여백 칸 안에 들어오게 한다 — 안 그러면 10+ 배지가 신호등에 닿는다.
    return @intCast(@min(clearance_px / self.cell_width_px + collapsed_toggle_gap_cells + collapsed_badge_max_cells, @as(u32, std.math.maxInt(u16))));
}

/// 접힘 시 알림 종(🔔)의 backing-px rect(클릭 hit-test) — collapsedBellCol()과 같은 col(단일 출처). 마우스 핸들러가 이
/// rect 클릭이면 openNotificationPanel한다(◧ 토글과 별개 영역). 종 글리프 중심((bell_col+0.5)·cw, 렌더러 가로 −0.5칸
/// nudge 반영)에 3칸 폭(배지+종)을 중앙 정렬. (3cw)/2 == cw + cw/2라 collapsedIconRect 중앙 정렬이 그대로 종 중심에 온다.
pub fn collapsedNotificationRect(self: *const AppSession) ?chrome.draw.Rect {
    return self.collapsedIconRect(collapsedBellCol(self), 3 * self.cell_width_px);
}

/// 알림 센터 패널을 종(🔔) 아이콘 아래에 연다 — 종 클릭과 디버그 훅(MARU_OPEN_NOTIFICATIONS)의 단일 출처.
/// 패널 좌단을 알림 그룹 좌단(배지 col cols-12)에 맞추고, 상단(body)은 줄2(=2ch)부터 둔다: 벨 글리프가 py_nudge
/// (0.30ch)로 줄0에서 [0.30ch, 1.30ch]에 그려지므로 줄1(빈 버퍼 행)을 벨↔팝업 간격으로 비워 벨을 안 가린다(말풍선
/// caret이 들어갈 자리). 항목은 collect 시점에 히스토리에서 빌드(buildNotificationItems) — show엔 개수만 준다(키 nav clamp).
pub fn openNotificationPanel(self: *AppSession) void {
    if (self.cell_width_px == 0) return;
    // rich 모달 배경 quad는 lowering(rasterizeOverlayCells)이 content rect를 사방 modal_padding_px만큼 outset하므로
    // **보이는** 패널 상단 = content_top − mp. mp를 더해 보이는 상단을 원하는 줄에 맞춘다(안 더하면 패널이 벨/띠에 붙음).
    const mp: u32 = self.buildChromeTokens().space.modal_padding_px;
    var anchor_x: i32 = undefined;
    var anchor_y: i32 = undefined;
    if (self.sidebar_collapsed) {
        // 접힘: 종은 타이틀바 띠 안 collapsedBellCol(). 패널 좌단을 종 묶음(배지) 좌단에, 보이는 상단을 띠 하단에 둔다.
        // (접힘은 사이드바 폭 0이라 말풍선 caret은 appendNotificationCaret의 cols<13 가드로 자동 생략 — 띠 아래 드롭다운.)
        // 배지/종 묶음 좌단: 안 읽음 개수별 배지 폭(10+ 2칸, 1~9 1칸, 0 없음)만큼 종 왼쪽이 묶음 좌단(collapsed_badge_max_cells 단일 출처).
        const badge_cells: u16 = if (self.notification_unread > 9) collapsed_badge_max_cells else if (self.notification_unread > 0) 1 else 0;
        anchor_x = @intCast(@as(u32, collapsedBellCol(self) -| badge_cells) * self.cell_width_px);
        anchor_y = @intCast(self.titlebar_strip_px + mp); // content_top − mp = titlebar_strip_px(띠 하단)
    } else {
        // 펼침: 패널 좌단을 알림 그룹 좌단(배지 col cols-12)에, 보이는 상단을 줄2에 둔다 — 벨(줄0, py_nudge로 ~1.30ch)을
        // 한 줄 띄우고 그 사이(줄1)가 말풍선 caret 자리. mp를 빼먹으면 보이는 패널이 벨에 붙어(2ch−mp) caret 틈이 없다.
        const hcols = self.sidebar_width_px / self.cell_width_px;
        anchor_x = @intCast((hcols -| 12) * self.cell_width_px);
        anchor_y = @intCast(self.cell_height_px * 2 + mp);
    }
    self.chrome_host.notifications.show(anchor_x, anchor_y, self.notification_history.items.len);
    // 모달을 여는 즉시 배경 호버 강조(탭 ✕·슬롯 밴드·스크롤바·URL)를 끈다 — hoverCursor는 다음 마우스 이동에야
    // 정리하므로, 그 사이 패널 뒤로 stale 호버가 비치는 것을 막는다(close-confirm 모달 showConfirmButtons와 같은 규율).
    self.clearAllHover();
    self.notif_panel_rect = null; // 재오픈 — 직전 오픈의 stale rect로 hover 게이트가 오판하지 않게(첫 프레임이 다시 채운다)
    self.metal_dirty = true;
}

/// 알림 패널 말풍선 caret을 GPU 삼각형(gpu_quads gradient_kind=3) **1개**(채움 surface_bg, 패널 배경과 같은 색)로
/// 그린다. 예전엔 focus_accent 외곽선 삼각형 위에 채움 삼각형을 얹었는데 채움 빗변의 fwidth edge-AA가 내부까지 부분
/// 커버리지를 줘 외곽선과 블렌딩, 내부가 패널색 아닌 중간톤으로 떴다(사용자 피드백). 벨 글리프 중심(렌더러 가로 nudge 반영: col cols-12·width 2 슬롯이 0.5칸
/// 왼쪽으로 밀려 중심 (cols-11.5)*cw)에 apex를 두고, 밑변을 패널 상단에 overlap만큼 겹쳐 상단 테두리를 caret
/// 폭만큼 덮어 'bubble을 연다'. 패널이 세로 clamp로 anchor보다 위로 밀렸거나 벨이 패널 가로 밖이면 생략(벨과
/// 어긋난 caret 방지). buildChromeOverlayFrame이 패널 배경 quad를 self.gpu_quads에 append한 '뒤'에 부른다(테두리 위로).
pub fn appendNotificationCaret(self: *AppSession, items: []const chrome.components.notifications.Item, props: chrome.ChromeProps, tk: *const chrome.Tokens) void {
    const cw = self.cell_width_px;
    const ch = self.cell_height_px;
    if (cw == 0 or ch == 0) return;
    const cols = self.sidebar_width_px / cw;
    if (cols < 13) return; // 벨이 안 그려지는 폭 — caret도 생략(buildSidebarHeaderDrawList cols<13과 정합)
    const panel = chrome.components.notifications.panelRect(&self.chrome_host.notifications, items, props) orelse return;
    if (panel.y < self.chrome_host.notifications.anchor_y) return; // 세로 clamp로 위로 밀림 — 벨과 어긋나니 생략
    const cw_f: f32 = @floatFromInt(cw);
    const ch_f: f32 = @floatFromInt(ch);
    const bell_cx: f32 = (@as(f32, @floatFromInt(cols)) - 11.5) * cw_f; // 벨 중심(cols-12, 2칸, 가로 -0.5 nudge 반영 → cols-11.5)
    // panelRect는 content rect(셀 격자)다. rich 모달 배경 quad는 lowering이 사방 modal_padding_px만큼 outset하므로
    // **보이는** 패널 경계는 content rect를 mp만큼 키운 것 — caret은 그 보이는 경계 기준으로 맞춰야 패널과 닿는다.
    const mp: f32 = @floatFromInt(tk.space.modal_padding_px);
    const px: f32 = @as(f32, @floatFromInt(panel.x)) - mp; // 보이는 패널 좌단
    const pw: f32 = @as(f32, @floatFromInt(panel.w)) + 2 * mp; // 보이는 패널 폭
    if (bell_cx < px or bell_cx > px + pw) return; // 벨이 (보이는) 패널 가로 밖 — 생략
    const panel_top: f32 = @as(f32, @floatFromInt(panel.y)) - mp; // 보이는 패널 상단(content top − outset)
    const caret_w: f32 = cw_f * 1.6; // ~1.6칸 폭(말풍선 꼭지)
    const caret_h: f32 = ch_f * 0.5; // ~반 줄 높이
    const overlap: f32 = 2.0; // 밑변을 패널 안으로 — 상단 테두리 seam 덮기
    const fill = packRgbAlpha(tk.get(.surface_bg), 0xFF); // 채움=패널 배경색(텍스트 박스와 동일)
    const border_col = packRgbAlpha(tk.get(.focus_accent), 0xFF); // 빗변 테두리=패널과 같은 색(패널 border_role=.focus_accent)
    const border_w: f32 = @floatFromInt(tk.space.border_width_px); // 빗변 테두리 두께=패널과 동일(같은 tokens 공유)
    // 말풍선 caret = 패널 배경(surface_bg) 채움 + 두 빗변에 패널과 같은 테두리(border_col). 밑변은 테두리 없이 패널
    // 본문으로 열려, 채움이 패널 상단 테두리를 caret 폭만큼 덮어(overlap) bubble을 연다 → 빗변 테두리가 패널 상단
    // 테두리와 이어져 하나의 말풍선 외곽선이 된다. 채움 삼각형 하나로만 그려 예전 이중 삼각형의 edge-AA 중간톤 뜸을 피한다.
    // SV6b: 패널 배경과 같은 대기 버퍼로 — caret은 패널의 일부라 flush 시점도 같아야 한다(배경 '뒤'에 와야
    // 상단 테두리를 덮는 painter 관계도 그대로 유지된다).
    self.overlay_quads.append(self.allocator, triangleQuad(bell_cx - caret_w / 2, panel_top - caret_h, caret_w, caret_h + overlap, fill, border_w, border_col)) catch {};
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

// 시각 벨(bell.visual) flash 지속 시간(ms). frame rate별 tick 수로 환산해 실제 페이드 시간을 유지한다(F2-4).
pub const bell_flash_total_ms: u32 = 250;

// 시각 벨 flash 최대 alpha(천분율) — 전경색 반투명 오버레이의 시작 불투명도. 너무 세지 않게(가독성·자극 균형) 0.35(F2-4).
pub const bell_flash_peak_milli: u32 = 350;

// 접힘 헤더 가장 왼쪽 아이콘 묶음(종+배지)을 신호등 클리어런스에서 더 오른쪽으로 미는 여백 칸 수 — 호버 배경이 셀
// 중심 기준 좌측으로 ≈0.8칸 번지므로, 1칸이면 신호등에 닿을 만큼 붙어 보였다(사용자 피드백). 2칸으로 한 칸 이상 간격.
pub const collapsed_toggle_gap_cells: u32 = 2;

// "9+" 안 읽음 배지가 종 글리프 왼쪽으로 뻗는 최대 칸 수(10+면 2칸). collapsedBellCol이 이만큼을 신호등 클리어런스
// 오른쪽에 예약해 배지가 신호등을 침범하지 않게 하고, openNotificationPanel 접힘 anchor가 배지 묶음 좌단을 잡는 단일 출처.
pub const collapsed_badge_max_cells: u16 = 2;

/// 알림 배지 원의 중심이 헤더 아이콘 줄 **셀 안에서** 얼마나 아래인가(셀 높이 비율). digit 글리프의 시각
/// 중심은 셀 중앙(0.5)보다 약간 위라 0.46이다. 줄 자체의 원점은 `sidebarHeaderIconRowTopPx`가 따로 준다 —
/// 이 상수는 그 원점 **위에서의 nudge**일 뿐이라 둘을 섞으면 안 된다(섞어서 배지가 어긋났던 결함).
pub const notification_badge_center_in_cell: f32 = 0.46;

/// 알림 본문에 싣는 대화 한 줄의 상한(bytes). 표시 상한(`max_text_bytes`)보다 짧다 — OS 배너는 몇 줄만 보여주고
/// 자르므로, 긴 원문을 통째로 넣어봐야 뒤가 안 보이면서 알림만 커진다.
pub const notification_conversation_max_bytes: usize = 160;
