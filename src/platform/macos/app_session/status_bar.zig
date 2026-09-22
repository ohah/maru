//! 상태바 — 항목 수집·배치·그리기, 클릭 라우팅, 그리고 그 안의 **리소스 표시**(CPU·메모리 표본과 메뉴).
//!
//! `app_session.zig` 에서 목적별로 떼어낸 그룹이다(docs/plans/app-session-decomposition.md §4.1 F17).
//!
//! **상태바와 리소스를 함께 둔 이유는 호출 관계다.** 이름으로는 둘로 보이지만 서로 부른다(각 2 건) —
//! 리소스 표본이 상태바 «항목» 으로 나오고, 상태바 클릭이 리소스 «메뉴» 를 연다. F1 이 archive 와
//! agent dock 을 합친 것과 같은 판정이다(이름이 아니라 호출 관계로 경계를 정한다).
//!
//! **이 그룹은 밖의 비공개 «메서드» 를 하나도 안 부른다**(실측 0 건). 상태바는 세션 상태를 «읽어»
//! 그릴 뿐 세션을 바꾸지 않기 때문이다. 대신 파일 스코프 상수·헬퍼를 여럿 쓰므로 그쪽에서 pub 이 는다.
//!
//! **F 시리즈가 이 주제를 지금까지 못 본 이유는 이름이다.** `collectStatusBarItems` ·
//! `appendStatusBarBackground` · `buildStatusBarItem` 은 **동사로 시작해서** 이름 앞부분으로 묶는
//! 방식에 안 걸렸다 — 주제가 이름 «가운데» 있었다. 남은 그룹을 찾을 때는 동사를 걷어내고 본다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const terminal = maru.terminal;
const renderer = maru.renderer;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const agentIconCodepoint = app_session_mod.agentIconCodepoint;
const activeTermNarrowedCols = app_session_mod.activeTermNarrowedCols;
const monotonicMs = app_session_mod.monotonicMs;
const max_resource_samples_per_term = app_session_mod.max_resource_samples_per_term;
const notificationLocation = app_session_mod.notificationLocation;
const max_resource_host_samples = app_session_mod.max_resource_host_samples;
const max_status_bar_right_items = app_session_mod.max_status_bar_right_items;
const resourceHostLabel = app_session_mod.resourceHostLabel;
const resource_row_name_cols = app_session_mod.resource_row_name_cols;
const copyClamped = app_session_mod.copyClamped;
const max_resource_samples = app_session_mod.max_resource_samples;
const resource_host_key = app_session_mod.resource_host_key;
const resource_pinned_keys = app_session_mod.resource_pinned_keys;
const sidebarCwdPath = app_session_mod.sidebarCwdPath;
const truncateColsInto = app_session_mod.truncateColsInto;
const icons = app_session_mod.icons;
const resourceAppLabel = app_session_mod.resourceAppLabel;
const resource_footer_rows = app_session_mod.resource_footer_rows;
const resource_poll_interval_ms = app_session_mod.resource_poll_interval_ms;
const resource_row_max_bytes = app_session_mod.resource_row_max_bytes;
const is_macos = app_session_mod.is_macos;
const max_resource_rows = app_session_mod.max_resource_rows;
const max_status_bar_left_items = app_session_mod.max_status_bar_left_items;
const notification_location_buf_len = app_session_mod.notification_location_buf_len;
const packOpaqueRgb = app_session_mod.packOpaqueRgb;
const resource_app_key = app_session_mod.resource_app_key;
const resource_header_rows = app_session_mod.resource_header_rows;
const resource_open_poll_interval_ms = app_session_mod.resource_open_poll_interval_ms;
const status_bar_border_pt = app_session_mod.status_bar_border_pt;
const status_bar_edge_pad_pt = app_session_mod.status_bar_edge_pad_pt;
const status_bar_gap_pt = app_session_mod.status_bar_gap_pt;
const status_bar_item_pad_pt = app_session_mod.status_bar_item_pad_pt;
const status_bar_metrics = app_session_mod.status_bar_metrics;
const CollectedPane = AppSession.CollectedPane;
const StatusBarItemKind = AppSession.StatusBarItemKind;
const status_bar_layer = AppSession.status_bar_layer;
const metal_frame = app_session_mod.metal_frame;
const coretext_frame_builder = app_session_mod.coretext_frame_builder;
const layout_math = maru.session.layout_math;
const notification_ops = @import("notification.zig");
const sidebar_ops = @import("sidebar.zig");
const dock_ops = @import("dock.zig");
const pane_ops = @import("pane.zig");
const agent_ops = @import("agent.zig");
const git_ops = @import("git.zig");
const editor_ops = @import("editor.zig");
const settings_ops = @import("settings.zig");

/// 창 바닥 상태표시줄의 backing px 높이. `dock_layout`이 이 값으로 작업영역을 깎고(S1 seam), 렌더러가
/// 같은 값으로 사이드바 배경 strip·셀 scissor를 끊는다(S2a ABI). 접힘·도크 상태와 무관하게 항상 선다 —
/// 조건부로 만들면 바 높이가 프레임마다 달라져 터미널 grid가 출렁인다.
/// 상태바 좌/우 가장자리 안쪽 여백(px). 사이드바 카드 여백과 같은 급으로 두되 pt 독립이다.
fn statusBarEdgePadPx(self: *const AppSession) u32 {
    return layout_math.ptToPx(status_bar_edge_pad_pt, self.scale_milli);
}

/// 상태바 항목 사이 간격(px). 아이콘+텍스트 묶음끼리 붙어 보이지 않을 만큼만 띄운다.
fn statusBarGapPx(self: *const AppSession) u32 {
    return layout_math.ptToPx(status_bar_gap_pt, self.scale_milli);
}

pub fn statusBarHeightPx(self: *const AppSession) u32 {
    // quick terminal은 chrome을 의도적으로 걷어낸 모드다 — `paneBarHeightPx`가 0을 돌려 탭 바를
    // 통째로 끄는 것과 같은 규율. §2 "항상 선다"는 도크·사이드바 **토글**(프레임마다 바뀌어
    // grid가 출렁이는 것)을 막는 규칙이고, 세션 생성 시 고정되는 이 모드는 그 대상이 아니다.
    if (self.chrome_minimal) return 0;
    // 사용자가 끈 경우도 같은 자리에서 0으로 만든다 — 게이트가 여기 하나뿐이라 작업영역·도크·사이드바
    // 뷰포트·strip·scissor가 전부 자동으로 따라온다(§5.4의 소비처 목록을 손댈 필요가 없다).
    if (!self.loaded_config.config.status_bar.show) return 0;
    // **텍스트 행에 여백을 더한 높이와 고정 하한 중 큰 쪽.** 상단 타이틀바 띠(`computeTitlebarStripPx`)가
    // 쓰는 `@max(cell_height_px, 최소 pt)`와 같은 패턴이다.
    //
    // 고정 높이만 쓰면 두 가지가 깨진다: (1) 기본 폰트에서 22px 바에 18px 행이라 위아래 2px밖에 안 남아
    // 빡빡하고(사용자 지적), (2) 폰트를 키워 셀이 바보다 커지면 `(h -| cell_height) / 2`가 0으로 포화돼
    // **글자가 바 아래로 넘친다**(창 밖). 텍스트가 터미널 셀 높이를 쓰는 이상 바가 그걸 담아야 한다.
    //
    // 그래도 **하한은 폰트 독립**이라 작은 폰트에서 바가 실처럼 얇아지지 않는다 — 도크 view bar가 폰트
    // 파생만으로 오르내리던 회귀(실측 53px↔80px)를 피한 이유가 그 하한이다.
    return status_bar_metrics.heightPx(self.cell_height_px, self.scale_milli);
}

/// 세션 host 데몬 자신의 표본을 채우고 개수를 돌려준다. 출처는 **앱 전역** 원격 backend다 — 창마다가
/// 아니라 프로세스마다 하나라(§10) 어느 창에서 물어도 같은 host를 가리키고, 그래서 그 값이
/// "모든 창 공유" 행이 된다. keep-alive가 꺼져 있거나 host 연결에 실패했으면 0이고 행이 서지 않는다.
///
/// ⚠️ backend 포인터를 **밖으로 내보내지 않는다.** `RemoteSessionBackend`는 non-macOS에서 `void`라
/// 호출을 `if (is_macos)` **안**에서 끝내야 그 갈래가 comptime에 통째로 잘린다(기존 `backendFor`와 같은 꼴).
fn hostResourceSamples(self: *AppSession, out: []maru.session.resource_usage.Sample) usize {
    _ = self;
    if (is_macos) {
        if (app_session_mod.app_remote_backend) |*rb| return rb.hostProcessSamples(out);
    }
    return 0;
}

/// 이 창의 터미널 프로세스 표본을 모아 리소스 표시를 갱신한다(docs/status-bar.md §4.1).
///
/// **창 단위로 귀속되는 것만 센다** — 다만 앱 자신과 세션 host 데몬은 예외다(앱 전역이라 창이 둘이면
/// 같은 값이 두 번 표시되는 것을 알면서도, 가장 큰 소비자를 어느 화면에서도 못 보게 두지 않으려고
/// "모든 창 공유" 행 둘로 낸다). 웹 콘텐츠는 여전히 뺀다(비문서 심볼이 필요하다).
///
/// **host-backed 터미널도 이제 센다** — host가 관측에 실어 보낸 `child_pid`를 뿌리로 앱이 직접 트리를
/// 훑는다(§4.1 "host-backed 터미널도 센다"). 예전 주석은 "backend가 0을 돌려줘 자연히 빠진다"였다.
///
/// 상태바가 안 보이면(설정 off·quick terminal) **아예 재지 않는다** — 안 보이는 UI에 syscall을 쓰지 않는다.
pub fn pollResourceUsage(self: *AppSession) void {
    self.resource_poll_ticks += 1;
    const interval_ms = if (self.resource_menu_open) resource_open_poll_interval_ms else resource_poll_interval_ms;
    if (self.resource_poll_ticks < self.ticksForMs(interval_ms)) return;
    self.resource_poll_ticks = 0;
    if (!self.surface_initialized) return;
    if (statusBarHeightPx(self) == 0) { // 단일 게이트: chrome_minimal + status-bar.show
        // 팝오버는 그 항목에 앵커돼 있다 — 항목이 사라졌는데 목록만 남으면 누른 적 없는 자리에 뜬
        // 유령이 된다(브랜치 메뉴가 "앵커 없으면 열지 않는다"로 막은 문제의 **열린 뒤** 판).
        if (self.resource_menu_open) settings_ops.closeContextMenu(self);
        clearResourceReading(self);
        return;
    }

    // **행 수와 함께 큰다.** 예전엔 `* 4`(192 개)였는데, 그 상한에 닿으면 뒤 탭은 표본을 아예 못 받아
    // **총합에서도 빠졌다** — 「합이 안 맞는다」의 둘째 원인이고, 행만 늘리면 안 고쳐진다.
    var samples: [max_resource_samples]maru.session.resource_usage.Sample = undefined;
    var groups: [max_resource_rows + resource_footer_rows]maru.session.resource_usage.Group = undefined;
    var n: usize = 0;
    var group_n: usize = 0;
    // **앱 자신을 먼저 넣는다**(§4.1). 뒤에 넣으면 탭이 많을 때 공유 고정 버퍼에 자리가 없다 — 앞에 넣어도
    // 각 그룹이 자기 `start`를 기록하므로 탭 행 계산은 그대로다. 그리고 이 표본은 **자기 그룹을 하나 갖는다**:
    // 합계(=`samples` 전체)에 들어가면서 팝오버 꼬리 행의 값도 같은 산술에서 나온다.
    if (maru.pty.selfResourceSample()) |own| {
        samples[0] = .{ .pid = own.pid, .footprint_bytes = own.footprint_bytes, .cpu_ns = own.cpu_ns };
        n = 1;
        groups[0] = .{ .key = resource_app_key, .start = 0, .len = 1 };
        group_n = 1;
    }
    // **세션 호스트도 같은 자리에서 센다**(§4.1). 앱과 같은 이유다 — keep-alive를 켜면 터미널이 host
    // 프로세스 안에 살고, 그 데몬 자신의 오버헤드는 어느 화면에도 안 나오던 값이었다. 여기서도 **트리를
    // 훑지 않는다**: 자식들은 아래 Term 행이 각자 세므로 트리를 훑으면 같은 바이트를 두 번 센다.
    // 앱 표본 바로 뒤(앞쪽)에 넣는 이유도 앱과 같다 — 탭이 많을 때 뒤에는 자리가 없다.
    {
        const room = @min(max_resource_host_samples, samples.len - n);
        const host_n = hostResourceSamples(self, samples[n..][0..room]);
        if (host_n > 0 and group_n < groups.len) {
            groups[group_n] = .{ .key = resource_host_key, .start = n, .len = host_n };
            group_n += 1;
            n += host_n;
        }
    }
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (term.kind != .terminal) continue;
                if (!term.rt.live_initialized or term.rt.terminated) continue;
                if (n >= samples.len) break;
                const start = n;
                const room = @min(max_resource_samples_per_term, samples.len - n);
                n += self.backendFor(term).resourceSamples(term.rt.handle, samples[n..][0..room]);
                // 표본이 0이어도 **행은 남긴다** — 탭은 존재하므로(값만 `—`). 행 상한을 넘으면 더 담지
                // 않는다(공유 라벨 버퍼 크기 — comptime 가드가 상한을 못 박는다).
                if (group_n < groups.len) {
                    groups[group_n] = .{ .key = term.surfaceId(), .start = start, .len = n - start };
                    group_n += 1;
                }
            }
        }
    }

    // 앱·호스트 표본까지 실패했고 터미널도 없다(웹 탭만) — 0을 그리지 않고 항목을 내린다.
    if (n == 0) {
        clearResourceReading(self);
        return;
    }

    const reading = self.resource_meter.updateGrouped(
        self.allocator,
        samples[0..n],
        monotonicMs(),
        groups[0..group_n],
        &self.resource_rows,
    ) orelse {
        self.resource_rows_len = 0;
        // 첫 표본·긴 공백 — CPU%를 낼 수 없으면 **항목 자체를 내지 않는다**(메모리만 먼저 그리면 폭이
        // 변해 좌측 경로가 흔들린다).
        clearResourceReading(self);
        return;
    };

    self.resource_rows_len = @min(group_n, self.resource_rows.len);

    // **표시 문자열을 행보다 먼저 확정한다.** 팝오버 머리글이 이 버퍼에서 합계를 읽으므로
    // (§4.2 "합계는 상태바 항목과 **같은 값**을 쓴다 — 다른 숫자를 두 곳에 두면 어느 쪽이 맞는지
    // 물어야 한다"), 갱신 **전에** 행을 다시 그리면 머리글만 한 tick 뒤처진다. 예전 순서가 그랬고,
    // 총합이 느리게 움직이던 동안에는 두 숫자가 대개 같아 보여 드러나지 않았다 — 세션 호스트가
    // 합계에 들어오면서 초 단위로 크게 움직이자 실측 캡처에서 **머리글 516 MB vs 띠 532 MB**로 보였다.
    var buf: [maru.session.resource_usage.text_max_bytes]u8 = undefined;
    const text = maru.session.resource_usage.format(&buf, reading);
    const text_changed = !(text.len == self.resource_text_len and
        std.mem.eql(u8, text, self.resource_text_buf[0..self.resource_text_len]));
    if (text_changed) {
        @memcpy(self.resource_text_buf[0..text.len], text);
        self.resource_text_len = text.len;
    }
    self.resource_reading = reading;
    if (self.resource_menu_open) refreshResourceMenuRows(self); // 열려 있으면 값만 다시 그린다(순서·개수 고정)

    // **글자가 바뀔 때만** 재렌더한다. 원값은 매초 흔들려도 표시가 같으면 다시 그릴 이유가 없다
    // (매초 전체 재렌더는 배터리에 그대로 실린다).
    //
    // 단 **팝오버가 열려 있으면 함께 그린다** — 방금 행 값을 다시 조립했는데 총합 문자열이 같다는
    // 이유로 건너뛰면 그 라벨이 화면에 도달하지 못한다. 열렸을 때 주기를 500ms로 당긴 이유가
    // "값이 안 변하면 멈춘 것처럼 보인다"(§4.2)인데, 옛 순서는 바로 그 경우에 화면을 안 고쳤다.
    if (!text_changed and !self.resource_menu_open) return;
    self.metal_dirty = true;
}

/// 리소스 팝오버를 연다 — 상태바 항목에 앵커한 탭별 목록(docs/status-bar.md §6 "리소스 팝오버").
///
/// **열 때 행 집합과 순서를 정하고 닫힐 때까지 얼린다.** 무거운 순으로 정렬하는데 갱신마다 다시 정렬하면
/// 누르려던 줄이 손가락 밑에서 다른 탭이 되고, `context_menu.show()`를 다시 부르면 선택도 0으로 튕긴다.
/// 캡처 하니스(`debug_fixtures.applyForcedResourceMenu`)도 부르므로 `pub` 이다.
pub fn openResourceMenu(self: *AppSession) void {
    if (self.resource_rows_len == 0) {
        self.showNoticeKey(.app_no_measured_terminal);
        return;
    }
    // **앵커가 있어야 연다** — 브랜치 메뉴와 같은 규율(바가 사라진 뒤 열면 창 바닥에 붙는다).
    var anchor_x: f64 = 0;
    var anchor_y: f64 = 0;
    var anchored = false;
    for (statusBarTree(self).entries) |e| {
        if (e.id != @intFromEnum(chrome.components.status_bar.ItemId.resource)) continue;
        anchor_x = e.rect.x;
        anchor_y = e.rect.y;
        anchored = true;
    }
    if (!anchored) return;

    // 무거운 순 정렬 — 값이 없는 행(표본 0)은 뒤로. **공유 행 둘은 넣지 않는다**(정렬 밖 고정,
    // 아래에서 맨 뒤에 붙인다). 가르는 산술은 순수 모듈이 소유하고 테스트가 단언한다 —
    // 실제로 서는 꼬리 수가 0·1·2로 갈리는데 그것을 여기서 다시 세면 화면에서만 드러난다.
    var order: [max_resource_rows + resource_footer_rows]usize = undefined;
    var pinned: [resource_pinned_keys.len]usize = undefined;
    const part = maru.session.resource_usage.partitionPinned(
        self.resource_rows[0..self.resource_rows_len],
        &resource_pinned_keys,
        &order,
        &pinned,
    );
    const count = part.sortable;
    const Ctx = struct {
        rows: []const maru.session.resource_usage.GroupReading,
        fn heavier(ctx: @This(), a: usize, b: usize) bool {
            const av = if (ctx.rows[a].reading) |r| r.footprint_bytes else 0;
            const bv = if (ctx.rows[b].reading) |r| r.footprint_bytes else 0;
            return av > bv;
        }
    };
    std.sort.pdq(usize, order[0..count], Ctx{ .rows = self.resource_rows[0..self.resource_rows_len] }, Ctx.heavier);

    settings_ops.closeContextMenu(self);
    self.resource_menu_len = 0;
    for (order[0..count]) |row_index| {
        if (self.resource_menu_len >= max_resource_rows) break;
        self.resource_menu_keys[self.resource_menu_len] = self.resource_rows[row_index].key;
        self.resource_menu_len += 1;
    }
    // 공유 행은 **잘리는 상한 뒤**에 붙는다 — 탭이 넘쳐도 사라지지 않는다(§4.1 "항상 있으므로 항상 보여야").
    // 꼬리 수는 **실제로 붙은 개수**다(상수가 아니다) — host가 없거나 앱 표본이 실패하면 하나만 선다.
    for (pinned[0..part.pinned_len]) |row_index| {
        self.resource_menu_keys[self.resource_menu_len] = self.resource_rows[row_index].key;
        self.resource_menu_len += 1;
    }
    const footer: usize = part.pinned_len;
    self.resource_menu_open = true;
    refreshResourceMenuRows(self);
    self.chrome_host.context_menu.showWithFooters(
        @intFromFloat(anchor_x),
        @intFromFloat(anchor_y),
        resource_header_rows + self.resource_menu_len,
        resource_header_rows,
        footer,
    );
    self.metal_dirty = true;
}

/// 얼린 행 순서 그대로 **값만** 다시 조립한다(`show`를 다시 부르지 않는다 — 선택이 리셋된다).
pub fn refreshResourceMenuRows(self: *AppSession) void {
    const ru = maru.session.resource_usage;
    buildResourceHeaderRows(self);
    for (0..self.resource_menu_len) |i| {
        const key = self.resource_menu_keys[i];
        // 이 행의 최신 값을 키로 찾는다. 그 사이 탭이 죽었으면 못 찾는다 → `—`(갈 곳이 아님을 보인다).
        var reading: ?ru.Reading = null;
        for (self.resource_rows[0..self.resource_rows_len]) |row| {
            if (row.key == key) {
                reading = row.reading;
                break;
            }
        }
        self.context_menu_items_buf[resource_header_rows + i] = formatResourceRow(self, i, key, reading);
    }
    self.context_menu_items_len = resource_header_rows + self.resource_menu_len;
}

/// 앞머리 두 줄 — ⓪ `리소스  <창 합계>` ① `이름 … 메모리   CPU`. 합계는 상태바 항목과 **같은 값**을
/// 쓴다(다른 숫자를 두 곳에 두면 어느 쪽이 맞는지 물어야 한다).
fn buildResourceHeaderRows(self: *AppSession) void {
    const ru = maru.session.resource_usage;
    const cols = chrome.components.overlay_input.displayCols;

    // 머리글 버퍼는 **행 슬롯 뒤**에 온다. 행은 탭(max_resource_rows) + 앱(resource_footer_rows)까지
    // 쓰므로, 예전처럼 `[max_resource_rows]`를 제목으로 쓰면 **12번째 탭 행과 제목이 같은 버퍼**를
    // 나눠 쓴다(행이 꽉 찬 창에서만 드러나는 종류의 손상).
    const title = &self.resource_menu_text[max_resource_rows + resource_footer_rows];
    var used: usize = copyClamped(title[0..], maru.i18n.t(.col_resource));
    if (self.resource_text_len > 0) {
        var pad = resource_row_name_cols -| cols(maru.i18n.t(.col_resource));
        while (pad > 0 and used < title.len) : (pad -= 1) {
            title[used] = ' ';
            used += 1;
        }
        used += copyClamped(title[used..], "  ");
        used += copyClamped(title[used..], self.resource_text_buf[0..self.resource_text_len]);
    }
    self.context_menu_items_buf[0] = title[0..used];

    const head = &self.resource_menu_text[max_resource_rows + resource_footer_rows + 1];
    var n: usize = copyClamped(head[0..], maru.i18n.t(.col_name));
    var pad2 = resource_row_name_cols -| cols(maru.i18n.t(.col_name));
    while (pad2 > 0 and n < head.len) : (pad2 -= 1) {
        head[n] = ' ';
        n += 1;
    }
    n += copyClamped(head[n..], "  ");
    // 값 줄과 **같은 칸**에서 끝나는 열 이름(순수 모듈이 폭 규약을 함께 소유한다).
    var head_buf: [ru.header_max_bytes]u8 = undefined;
    n += copyClamped(head[n..], ru.formatHeader(&head_buf));
    self.context_menu_items_buf[1] = head[0..n];
}

/// 한 행 = `탭 › 팬` + 고정 폭 숫자. 라벨 조립은 **알림과 같은 함수**(`notificationLocation`)를 쓴다 —
/// 구분자 규약이 앱 전체에서 하나여야 하고, 두 라벨이 같을 때 하나만 쓰는 처리도 거기 있다.
/// 패딩은 **EAW 표시 칸** 기준이다(한글 한 자 = 2칸) — 글자 수로 채우면 한글 탭에서 열이 어긋난다.
fn formatResourceRow(self: *AppSession, slot: usize, key: u64, reading: ?maru.session.resource_usage.Reading) []const u8 {
    const ru = maru.session.resource_usage;
    var loc_buf: [notification_location_buf_len]u8 = undefined;
    const label = resourceRowLabel(self, &loc_buf, key);

    var value_buf: [ru.text_max_bytes]u8 = undefined;
    const value: []const u8 = if (reading) |r| ru.format(&value_buf, r) else "—";

    // 이름 예산 = 전체 폭에서 숫자 열과 간격을 뺀 만큼. 넘치면 EAW 절단(`…`).
    var name_buf: [resource_row_max_bytes]u8 = undefined;
    const shown = truncateColsInto(&name_buf, label, resource_row_name_cols);
    const name_cols = chrome.components.overlay_input.displayCols(shown);

    var out = &self.resource_menu_text[slot];
    var used: usize = 0;
    used += copyClamped(out[used..], shown);
    var pad = resource_row_name_cols -| name_cols;
    while (pad > 0 and used < out.len) : (pad -= 1) {
        out[used] = ' ';
        used += 1;
    }
    used += copyClamped(out[used..], "  ");
    used += copyClamped(out[used..], value);
    return out[0..used];
}

/// 이 행이 가리키는 Term의 `탭 › 팬` 라벨. 못 찾으면(그 사이 닫힘) 마지막으로 알던 이름이 없으므로 물음표.
fn resourceRowLabel(self: *AppSession, buf: []u8, key: u64) []const u8 {
    // 공유 행 둘은 Term이 아니다 — 탭 목록에서 못 찾는 게 정상이라 먼저 가른다(§4.1).
    if (key == resource_app_key) return resourceAppLabel();
    if (key == resource_host_key) return resourceHostLabel();
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (term.surfaceId() != key) continue;
                return notificationLocation(buf, tab, term);
            }
        }
    }
    return maru.i18n.t(.app_closed_tab);
}

fn clearResourceReading(self: *AppSession) void {
    if (self.resource_reading == null and self.resource_text_len == 0) return;
    self.resource_reading = null;
    self.resource_text_len = 0;
    self.metal_dirty = true;
}

/// 상태바가 그릴 리소스 문자열. 없으면 null(항목 없음).
pub fn resourceText(self: *const AppSession) ?[]const u8 {
    if (self.resource_text_len == 0) return null;
    return self.resource_text_buf[0..self.resource_text_len];
}

/// 펼침 헤더 종 우상단 알림 배지의 **빨강 원형 quad**(layer 4 — 사이드바 bg strip 뒤·헤더 글리프 앞)를 self.gpu_quads에
/// 1개 append한다. 그 원 위에 올라갈 흰 숫자는 appendBellAndBadge가 헤더 frame 셀(col=notificationBadgeCol)로 둔다 —
/// cell↔quad가 같은 col에서 만나 어긋나지 않는다. 안 읽은 알림이 없거나 헤더가 안 그려지는 폭/상태면 무동작.
/// **접힘은 제외**한다(접힘 헤더는 터미널 위에 그려져 layer 4 quad가 터미널 셀에 가려 안 보임 — 접힘은 텍스트 배지 유지).
/// per-frame: renderFrame이 dropQuadsByLayer(4) 직후 호출(헤더 frame의 흰 숫자와 같은 주기로 갱신).
/// 상태표시줄 항목을 수집한다(SB1-S3b: 좌측 git 브랜치). 폭은 **셀로 재고 px로 넘긴다** —
/// `chrome.components.status_bar`가 px로 배치하고(우측 정렬이 셀 경계가 아니라 창 가장자리에 붙어야
/// 한다), 항목마다 자기 frame을 px origin에 놓는다. 실패는 무시한다(항목 없이 빈 바 — 세션을 안 죽인다).
/// 발행된 tree를 비운다(항목이 하나도 없을 때). **조기 반환 경로가 이걸 안 하면 옛 tree가 남아,
/// 항목이 사라진 뒤에도 그 자리를 누르면 없어진 항목의 액션이 돈다** — 보이지 않는 것이 눌리는 셈이다.
/// 호버도 함께 지운다(가리키는 항목이 없다).
fn clearStatusBarTree(self: *AppSession) void {
    self.status_bar_entry_count = 0;
    self.status_bar_hovered = null;
}

pub fn collectStatusBarItems(self: *AppSession, collected: *std.ArrayList(CollectedPane), builder: coretext_frame_builder.CoreTextFrameBuilder, colors: metal_frame.CellColors) void {
    const h = statusBarHeightPx(self);
    if (h == 0 or self.cell_width_px == 0 or self.backing_width_px == 0) {
        clearStatusBarTree(self);
        return;
    }

    const term = pane_ops.activePane(self).activeTerm();
    const bar_cols: u16 = @intCast(@min(self.backing_width_px / self.cell_width_px, std.math.maxInt(u16)));
    const fg: terminal.Color = .{ .rgb = self.appearance.theme.foreground };
    const icon_fg: terminal.Color = .{ .rgb = self.mutedForeground() };

    // 좌측 항목을 **순서대로** 만든다. 폭이 모자라면 `status_bar.compute`가 **뒤쪽부터** 버리므로,
    // 배열 순서가 곧 우선순위다 — 브랜치가 경로보다 짧고 자주 바뀌므로 앞에 둔다.
    var frames: [max_status_bar_left_items]?renderer.DrawList = .{null} ** max_status_bar_left_items;
    var widths: [max_status_bar_left_items]u32 = .{0} ** max_status_bar_left_items;
    // 폭 배열과 **같은 순서**의 의미 id. 슬롯의 `index`로 되짚어 발행한다 — 인덱스를 id로 쓰면 항목이
    // 하나 빠질 때 남은 것의 id가 밀려 "누른 것과 실행된 것"이 갈린다.
    var left_ids: [max_status_bar_left_items]chrome.components.status_bar.ItemId = undefined;
    var n: usize = 0;
    defer for (frames[0..n]) |*maybe| {
        if (maybe.*) |*dl| dl.deinit(self.allocator);
    };

    // ① git 브랜치 — repo 안일 때만 존재한다.
    if (git_ops.termGitBranch(self, term)) |branch| {
        if (branch.len > 0) {
            if (buildStatusBarItem(self, icons.codepoint(.git_branch), branch, bar_cols, fg, icon_fg, .plain)) |dl| {
                frames[n] = dl;
                widths[n] = @as(u32, dl.size.cols) * self.cell_width_px;
                left_ids[n] = .git_branch;
                n += 1;
            }
        }
    }

    // ② 작업 경로 — **repo 밖에서도 그린다**. 사이드바 카드는 "repo 안일 때만 폴더줄"이지만(카드는 repo
    // 맥락을 보여주는 자리다), 상태바는 "지금 어디에 있나"가 목적이라 repo 밖 cwd가 오히려 유용하다.
    // 경로 파생은 `sidebarCwdPath`(HOME 경계를 정확히 지켜 `~`로 줄인다)를 재사용한다 — 다시 구현하지 않는다.
    if (sidebarCwdPath(self, term)) |path| {
        defer self.allocator.free(path);
        if (path.len > 0 and n < max_status_bar_left_items) {
            if (buildStatusBarItem(self, icons.codepoint(.folder), path, bar_cols, fg, icon_fg, .path)) |dl| {
                frames[n] = dl;
                widths[n] = @as(u32, dl.size.cols) * self.cell_width_px;
                left_ids[n] = .cwd;
                n += 1;
            }
        }
    } else |_| {}

    // 우측 — 안 읽은 알림 수. 0이면 항목 자체가 없다(사이드바 종 배지와 같은 전제).
    // 좌측과 **독립 배열**이다: `status_bar.compute`가 우측을 먼저 배치하고 좌측이 그 좌단을 넘지 않게
    // 자른다(S3a "부딪히면 우측을 먼저 지킨다"). 이 항목이 붙는 순간 그 규칙이 처음으로 실제로 작동한다.
    var right_frames: [max_status_bar_right_items]?renderer.DrawList = .{null} ** max_status_bar_right_items;
    var right_widths: [max_status_bar_right_items]u32 = .{0} ** max_status_bar_right_items;
    var right_ids: [max_status_bar_right_items]chrome.components.status_bar.ItemId = undefined;
    var rn: usize = 0;
    defer for (right_frames[0..rn]) |*maybe| {
        if (maybe.*) |*dl| dl.deinit(self.allocator);
    };
    // 영속 세션 강등도 데이터 보존 경고라 같은 자리를 다툰다 — 체크포인트 실패보다 **먼저** 넣어
    // 가장 오른쪽에 서고 가장 오래 살아남는다. 이 상태가 보이는 동안 새 Term 은 앱과 함께 죽는데,
    // notice 는 첫 폴백 때 한 번 뜨고 아무 키에나 닫혀 사라진다(status-bar.md §4.3).
    if (is_macos and app_session_mod.host_connect_failed) {
        const danger: terminal.Color = .{ .rgb = self.appearance.theme.palette[1] orelse self.appearance.theme.accent };
        if (buildStatusBarItem(
            self,
            // **`hourglass` 를 쓰지 않는다.** §4 가 막힌 에이전트를 «모양으로» 구분한다고 정했고 그
            // 모양이 모래시계다 — 같은 모양을 다른 뜻으로 재사용하면 그 규칙이 무너진다. `host` 는
            // 이 상태가 가리키는 대상 그 자체이고 아직 UI 어디에도 쓰이지 않았다.
            icons.codepoint(.host),
            maru.i18n.t(.status_session_not_persisted),
            bar_cols,
            danger,
            danger,
            .plain,
        )) |dl| {
            right_frames[rn] = dl;
            right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
            right_ids[rn] = .session_host_disconnected;
            rn += 1;
        }
    }
    // checkpoint 실패는 데이터 보존 경고라 우측 최우선이다. 성공 commit 전까지 필드가 유지되므로
    // 프레임이 바뀌어도 사라지지 않는 비모달 상태다.
    const checkpoint_failure_text: ?[]const u8 = switch (self.workspace_checkpoint_failure) {
        1 => maru.i18n.t(.ws_checkpoint_capture_failed),
        2 => maru.i18n.t(.ws_checkpoint_write_failed),
        else => null,
    };
    if (checkpoint_failure_text) |text| {
        const danger: terminal.Color = .{ .rgb = self.appearance.theme.palette[1] orelse self.appearance.theme.accent };
        if (buildStatusBarItem(self, null, text, bar_cols, danger, danger, .plain)) |dl| {
            right_frames[rn] = dl;
            right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
            right_ids[rn] = .workspace_checkpoint_failure;
            rn += 1;
        }
    }

    // **폰이 세션을 좁혀 두었으면 그 사실을 말한다**(S11-6). 위 두 경고보다 **나중에** 넣는다 —
    // 삽입 순서가 곧 생존 순위라(먼저 넣을수록 오른쪽에 서고 오래 남는다), 데이터 보존
    // 경고가 이 «사실 전달» 보다 먼저 밀려나면 안 된다(적대적 검증 4회차). 창은 그대로인데 내용이 갑자기
    // 좁게 리플로우되면 사용자는 그것을 **버그로 읽는다** — 계약이 「아무 신호 없이 줄이지
    // 않는다」인 이유다. 이것은 사건이 아니라 **폰이 붙어 있는 동안 지속되는 상태**라 상태줄이
    // 성격에 맞는다(한 번 뜨고 마는 알림이 아니다).
    if (activeTermNarrowedCols(self)) |narrowed| {
        var text_buf: [48]u8 = undefined;
        const text = maru.i18n.format(&text_buf, maru.i18n.t(.status_viewport_narrowed), &.{.{ .d = @intCast(narrowed) }});
        // 경고가 아니라 **사실 전달**이라 danger 색을 안 쓴다 — 폰이 붙은 것은 정상 동작이다.
        const narrowed_fg: terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground };
        if (buildStatusBarItem(
            self,
            // **새 자산이다** — `host` 를 빌려 쓰면 그 모양이 「host 강등」과 「폰이 좁혔다」
            // 둘을 뜻하게 되어 §4 의 「한 모양 한 뜻」이 무너진다.
            icons.codepoint(.phone),
            text,
            bar_cols,
            narrowed_fg,
            narrowed_fg,
            .plain,
        )) |dl| {
            right_frames[rn] = dl;
            right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
            right_ids[rn] = .viewport_narrowed;
            rn += 1;
        }
    }

    // 우측 배열은 **앞이 더 오른쪽**이다(compute가 오른쪽 끝에서 왼쪽으로 쌓는다). 시급한 순서로 놓는다:
    // blocked(사람을 기다림) → running(알아서 굴러감) → 알림(누적 카운터).
    //
    // blocked는 **모양으로** 구분한다(모래시계 + 강조색). 색만 다르면 "저 강조색이 무슨 뜻인지"를 배워야
    // 하고, running과 같은 아이콘을 쓰면 개수가 무엇의 개수인지 모호해진다.
    const agents = agent_ops.tallyAgents(self);
    if (agents.blocked > 0) {
        var blocked_buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&blocked_buf, "{d}", .{@min(agents.blocked, 99)}) catch "";
        // 테마 accent(브랜드 강조) — danger는 파괴적 동작용이라 과하다. 새 색 역할을 만들지 않는다.
        const accent: terminal.Color = .{ .rgb = self.appearance.theme.accent };
        if (text.len > 0) {
            if (buildStatusBarItem(self, icons.codepoint(.hourglass), text, bar_cols, accent, accent, .plain)) |dl| {
                right_frames[rn] = dl;
                right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
                right_ids[rn] = .blocked_agents;
                rn += 1;
            }
        }
    }
    if (agents.running > 0 and rn < max_status_bar_right_items) {
        const kind = agents.running_kind;
        var agent_buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&agent_buf, "{d}", .{@min(agents.running, 99)}) catch "";
        // **종류를 모르면 아이콘을 안 그린다.** 예전에는 `.none` 에 sparkle 을 썼는데 그것은 claude
        // 아이콘이라, 「모른다」를 「claude 다」로 단정하는 거짓말이 된다. 실제로 그 한 줄이 진단을
        // 망쳤다(2026-09-05): 원격 pane 의 `agent_kind` 가 안 세워진 상태였는데 화면은 claude 로
        // 보여, 사용자가 「codex 인데 claude 로 나온다」로 읽고 **엉뚱한 축을 한참 팠다**.
        //
        // **provider 중립 아이콘은 두지 않는다** — 그것을 만들려면 새 SVG 자산과 빌드 생성기가
        // 필요하고, 그 비용은 이 자리가 정당화하지 못한다. 아이콘이 없어도 blocked(모래시계)와는
        // **모양으로 갈리므로** 위 주석의 규율("running 과 같은 아이콘을 쓰면 개수가 무엇의 개수인지
        // 모호해진다")은 그대로 지켜진다.
        const icon: ?u21 = if (kind == .none) null else agentIconCodepoint(kind);
        if (text.len > 0 and rn < max_status_bar_right_items) {
            if (buildStatusBarItem(self, icon, text, bar_cols, fg, icon_fg, .plain)) |dl| {
                right_frames[rn] = dl;
                right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
                right_ids[rn] = .running_agents;
                rn += 1;
            }
        }
    }
    if (self.notification_unread > 0 and rn < max_status_bar_right_items) {
        var count_buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "{d}", .{self.notification_unread}) catch "";
        if (count.len > 0) {
            if (buildStatusBarItem(self, icons.codepoint(.bell), count, bar_cols, fg, icon_fg, .plain)) |dl| {
                right_frames[rn] = dl;
                right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
                right_ids[rn] = .notifications;
                rn += 1;
            }
        }
    }

    // **편집기 pane이 활성일 때만 나오는 넷**(native-editor-layering.md §2.2). 상태바는 창 전폭 띠라
    // 늘 떠 있으면 터미널을 쓰는 동안에도 기존 항목을 밀어낸다 — 그래서 조건부다.
    //
    // 배열 순서 = 버려지는 순서다(뒤가 먼저 사라진다). **커서 위치 → 저하 → 읽기 전용 → 줄바꿈** 순으로 넣어
    // "축소가 일어났다"는 사실이 가장 오래 남게 한다(§2.2: 조용히 줄어들면 사용자는 버그로 읽는다).
    // 리소스보다는 **앞**이다 — 리소스가 가장 먼저 사라져야 한다는 아래 계약을 그대로 둔다.
    if (rn < max_status_bar_right_items and self.surface_initialized and self.tabs.items.len > 0) {
        const active_term = pane_ops.activePane(self).activeTerm();
        if (active_term.kind == .editor) {
            // ⓪ 커서 위치(줄:열). §2.2 표의 첫 항목이라 **가장 오래 살아남아야 한다** — 우측
            //    묶음은 먼저 더한 것이 오른쪽에 서고 뒤로 갈수록 먼저 버려지므로 맨 앞에 둔다.
            //    선택이 없으면 항목 자체가 없다(읽기 전용이라 caret이 늘 있지는 않다).
            if (editor_ops.diffCursorPosition(active_term)) |pos| {
                if (rn < max_status_bar_right_items) {
                    var buf: [48]u8 = undefined;
                    // **형식은 `editor_ops` 가 소유한다** — 여기 묻어 두면 판정자가 글자를
                    // 못 읽는다(트리 항목은 id 와 사각만 든다).
                    const text = editor_ops.formatDiffCursor(&buf, pos);
                    if (text) |txt| if (buildStatusBarItem(self, null, txt, bar_cols, fg, icon_fg, .plain)) |dl| {
                        // 단일 편집기와 **같은 가드** — 잘린 숫자는 다른 값으로 읽힌다.
                        // 이 글도 ASCII(`L`·` `·숫자·`:`·`-`·`+`)뿐이라 byte 수 = 셀 수다.
                        if (dl.size.cols >= txt.len) {
                            right_frames[rn] = dl;
                            right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
                            right_ids[rn] = .editor_cursor;
                            rn += 1;
                        } else {
                            var truncated = dl;
                            truncated.deinit(self.allocator);
                        }
                    };
                }
            } else if (editor_ops.cursorPosition(active_term)) |pos| {
                if (rn < max_status_bar_right_items) {
                    var buf: [48]u8 = undefined;
                    // 상한을 넘으면 `+`를 붙인다 — 그 너머는 세지 않았다는 사실을 숨기지 않는다.
                    const text = if (pos.truncated)
                        std.fmt.bufPrint(&buf, "{d}:{d}+", .{ pos.line, pos.column }) catch null
                    else
                        std.fmt.bufPrint(&buf, "{d}:{d}", .{ pos.line, pos.column }) catch null;
                    if (text) |t| if (buildStatusBarItem(self, null, t, bar_cols, fg, icon_fg, .plain)) |dl| {
                        // **숫자는 잘리면 안 된다** — 리소스가 같은 이유로 같은 가드를 갖는다
                        //  (아래). 잘린 `199999:7` → `19999…`는 **다른 값으로 읽힌다**.
                        //
                        // 판정 기준은 다르다: 이 텍스트는 ASCII(숫자·`:`·`+`)뿐이라 **byte 수 = 셀
                        // 수**인데, 리소스는 `·`가 2바이트라 그 등식이 깨져 `text_cols` 상수를 든다.
                        if (dl.size.cols >= t.len) {
                            right_frames[rn] = dl;
                            right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
                            right_ids[rn] = .editor_cursor;
                            rn += 1;
                        } else {
                            // **버린 것은 푼다.** `defer`가 도는 대상은 배열에 실린 것뿐이라
                            // (`right_frames[0..rn]`), 여기서 안 풀면 좁은 창에서 편집기를 보는
                            // 동안 **프레임마다** cells·overlays·grapheme_pool이 샌다.
                            var truncated = dl;
                            truncated.deinit(self.allocator);
                        }
                    };
                }
            }
            // ① 저하: 행 수를 아직 다 못 셌다 → 스크롤바가 실제보다 짧다(§2.1).
            if (active_term.rt.editor_row_cache.countingIncomplete() and rn < max_status_bar_right_items) {
                if (buildStatusBarItem(self, icons.codepoint(.hourglass), maru.i18n.t(.editor_counting_rows), bar_cols, fg, icon_fg, .plain)) |dl| {
                    right_frames[rn] = dl;
                    right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
                    right_ids[rn] = .editor_degraded;
                    rn += 1;
                }
            }
            // ①-b 저하: **가로 보기가 상한에 걸렸다**(`editor.max-columns` — §3.8). 그 너머 글자는
            // 그려지지 않는데 화면만 보면 「더 안 밀린다」로만 보여 **버그로 읽힌다**. VSCode 가
            // 같은 자리에서 *"Rendering paused for long line for performance reasons. This can be
            // configured via `editor.stopRenderingLineAfter`"* 로 알리는 것과 같은 몫이다 — 그쪽은
            // 그 줄 hover 이고 우리는 상태바다(우리에겐 저하를 모으는 자리가 이미 있다).
            //
            // **판정은 「셈이 상한에서 멈췄나」 하나다.** 그 값이 곧 갈 수 있는 끝이므로(가로 위치의
            // 상한이 `max_cols - 보이는 열`이다) 상한에 닿았다는 것과 잘렸다는 것이 같은 사실이다.
            if (active_term.rt.editor_max_cols >= active_term.rt.editor_max_columns and
                active_term.rt.editor_max_cols > 0 and
                rn < max_status_bar_right_items)
            {
                if (buildStatusBarItem(self, icons.codepoint(.hourglass), maru.i18n.t(.editor_columns_capped), bar_cols, fg, icon_fg, .plain)) |dl| {
                    right_frames[rn] = dl;
                    right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
                    right_ids[rn] = .editor_degraded;
                    rn += 1;
                }
            }
            // ①-b2 저하: **미저장 백업이 멈췄다**(§3.10 — 문서가 저장 상한보다 크다). 조용히 멈추면
            // 사용자는 보호받고 있다고 오해하므로 저하 칸에 남긴다. 같은 칸의 위 둘과 같은 모양이고,
            // 「멈췄다」는 백업 tick 이 그 판정을 한 뒤에만 참이다(`editor_backup_paused`).
            if (active_term.rt.editor_backup_paused and rn < max_status_bar_right_items) {
                if (buildStatusBarItem(self, icons.codepoint(.hourglass), maru.i18n.t(.editor_backup_paused), bar_cols, fg, icon_fg, .plain)) |dl| {
                    right_frames[rn] = dl;
                    right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
                    right_ids[rn] = .editor_degraded;
                    rn += 1;
                }
            }
            // ①-c **언어 서버 상태**(tooling §8.2a): 서버 이름표가 있는 문서에만. 저하 계열이라 여기(앞쪽).
            if (rn < max_status_bar_right_items) {
                if (editor_ops.lsp_client.statusFor(self, active_term)) |view| {
                    var lsp_buf: [128]u8 = undefined;
                    if (editor_ops.lsp_client.statusText(view, &lsp_buf)) |text| {
                        const icon: ?u21 = switch (view.phase) {
                            .ready => null,
                            .missing, .denied, .failed => icons.codepoint(.bell),
                            .asking, .starting, .restarting => icons.codepoint(.hourglass),
                        };
                        if (buildStatusBarItem(self, icon, text, bar_cols, fg, icon_fg, .plain)) |dl| {
                            right_frames[rn] = dl;
                            right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
                            right_ids[rn] = .editor_lsp;
                            rn += 1;
                        }
                    }
                }
            }
            // ② 읽기 전용: **그 문서가 실제로 읽기 전용일 때만** 뜬다(§2.2 — 2026-09-03 정정).
            //
            // **오래 조건 없이 그렸다.** 그 문장("N1 편집기는 전부 읽기 전용이다")은 N1 시절의
            // 것이고, **N2 가 편집을 세우면서(2026-08-25) 거짓이 됐다** — 글자가 들어가는 편집기
            // 옆에서 사용자가 「읽기 전용」을 읽었다. 이 항목의 존재 이유가 *"사용자는 「왜 안
            // 써지지」를 묻는다"* 인데 정확히 반대로 오해를 만들고 있었다.
            //
            // **판정자가 아니라 캡처가 잡았다** — 상태바 판정자는 항목이 **있는지**만 재고 그것이
            // **참인지**는 안 쟀다(#3126·#3143 의 화면을 찍고서야 dirty 점과 나란히 뜬 것이 보였다).
            const doc_read_only = if (active_term.rt.editor_doc) |*d| d.file.read_only else false;
            if (doc_read_only and rn < max_status_bar_right_items) {
                if (buildStatusBarItem(self, null, maru.i18n.t(.editor_readonly), bar_cols, fg, icon_fg, .plain)) |dl| {
                    right_frames[rn] = dl;
                    right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
                    right_ids[rn] = .editor_readonly;
                    rn += 1;
                }
            }
            // ③ 줄바꿈: 파일이 쓰던 것을 그대로 말한다(저장이 되돌릴 값이기도 하다 — 문서 모델 §3.5).
            // ③ 언어: 이 문서에 **무엇이 색을 입히고 있는가**를 말한다(`status-bar.md` 「언어 항목」).
            // **줄바꿈보다 앞이다** — 이 배열 순서가 곧 **버려지는 순서**이고, 언어는 *"이 파일이
            // 무엇인가"* 라 줄바꿈보다 자주 쓰인다.
            //
            // **`Grammar` 를 쓴다 — `Language` 가 아니다.** 그 열거는 주석 문법으로 묶은 것이라
            // `c_like` 가 `"C-like"` 를 내고 `Makefile`·`Dockerfile` 을 `shell` 로 묶는다.
            //
            // **`none` 이면 말하지 않는다** — 그때 "Plain Text" 라고 적으면 강조가 없는 이유를
            // 설명하는 대신 가린다(줄바꿈 `none` 을 안 적는 것과 같은 규율).
            // **이 상한 검사는 오늘 도달하지 않는다**(2026-09-07 변이 검사 — 지워도 판정자가
            // 안 잡는 것이 정상이다). 상한이 `right_candidates.len` 이고 각 항목은 **한 번씩만**
            // 들어가므로 `rn` 이 그 값을 넘을 수 없다. 그럼에도 두는 이유는 **배열 경계 방어**이고,
            // 나머지 항목들이 전부 같은 모양을 쓴다 — 여기만 빼면 그 관례가 깨진다.
            if (rn < max_status_bar_right_items) {
                if (active_term.rt.editor_grammar.displayName()) |text| {
                    if (buildStatusBarItem(self, null, text, bar_cols, fg, icon_fg, .plain)) |dl| {
                        right_frames[rn] = dl;
                        right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
                        right_ids[rn] = .editor_language;
                        rn += 1;
                    }
                }
            }
            // **인코딩은 넣지 않는다**: 이 편집기는 UTF-8만 열므로(같은 절) 그 자리는 늘 같은 값이고,
            // 폭을 다투는 띠에서 변하지 않는 값은 자리만 먹는다. 다른 인코딩이 열리는 날 함께 넣는다.
            if (active_term.rt.editor_doc) |*doc| {
                if (rn < max_status_bar_right_items) {
                    // `none`(줄바꿈이 하나도 없는 파일)은 **말하지 않는다** — 그때 "LF"라고 적으면
                    // 파일에 없는 사실을 단정하는 것이고, 저장이 되돌릴 값도 없다.
                    const eol: ?[]const u8 = switch (doc.file.format.dominant_ending) {
                        .lf => "LF",
                        .crlf => "CRLF",
                        .none => null,
                    };
                    if (eol) |text| if (buildStatusBarItem(self, null, text, bar_cols, fg, icon_fg, .plain)) |dl| {
                        right_frames[rn] = dl;
                        right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
                        right_ids[rn] = .editor_eol;
                        rn += 1;
                    };
                }
            }
        }
    }

    // 리소스는 **배열 마지막**(= 가장 왼쪽)이다. 폭이 모자라면 뒤부터 버려지므로 가장 먼저 사라져야 한다 —
    // 막힌 에이전트가 리소스 숫자에 밀려 없어지면 안 된다(docs/status-bar.md §6 "자리").
    // 아이콘이 없다(등록부가 닫혀 있어 SVG 추가가 필요하다 — 숫자가 쓸모 있다고 확인된 뒤로 미룬다).
    if (resourceText(self)) |res_text| {
        if (rn < max_status_bar_right_items) {
            if (buildStatusBarItem(self, null, res_text, bar_cols, fg, icon_fg, .plain)) |dl| {
                // **숫자는 잘리면 안 된다.** 좁은 창에서 텍스트 예산(바 폭의 1/3)이 모자라면 빌더가
                // 말줄임하는데(`appendEllipsizedTitle`), 이름과 달리 잘린 숫자는 **다른 값으로 읽힌다**
                // ("512 MB ·…"). 온전히 못 담으면 항목을 통째로 내린다 — 부재가 오독보다 낫다.
                // 판정은 빌더가 되돌려준 실제 폭으로 한다(예산 산술을 여기서 다시 구현하지 않는다).
                if (dl.size.cols >= maru.session.resource_usage.text_cols) {
                    right_frames[rn] = dl;
                    right_widths[rn] = @as(u32, dl.size.cols) * self.cell_width_px;
                    right_ids[rn] = .resource;
                    rn += 1;
                } else {
                    var truncated = dl;
                    truncated.deinit(self.allocator);
                }
            }
        }
    }

    if (n == 0 and rn == 0) {
        clearStatusBarTree(self);
        return;
    }

    var left_buf: [max_status_bar_left_items]chrome.components.status_bar.Slot = undefined;
    var right_buf: [max_status_bar_right_items]chrome.components.status_bar.Slot = undefined;
    // 배치와 발행이 **같은 Metrics**를 봐야 한다 — 갈리면 그린 자리와 판정 자리가 어긋난다.
    const bar_metrics: chrome.components.status_bar.Metrics = .{
        .bar_x = 0,
        .bar_y = self.backing_height_px -| h,
        .bar_w = self.backing_width_px,
        .bar_h = h,
        .edge_pad_px = statusBarEdgePadPx(self),
        .gap_px = statusBarGapPx(self),
    };
    const layout = chrome.components.status_bar.compute(
        bar_metrics,
        widths[0..n],
        right_widths[0..rn],
        &left_buf,
        &right_buf,
    );

    // **상호작용 tree 발행** — 배치가 정한 슬롯을 그대로 낸다. 보이는 자리와 눌리는 자리가 같아지고,
    // 자리를 못 얻은 항목은 tree에 없다(안 보이면 눌리지도 않는다).
    publishStatusBarTree(self, bar_metrics, layout, left_ids[0..n], right_ids[0..rn]);

    // 세로 중앙: 홀수 나머지는 위로 — 바의 첫/마지막 행은 quad AA 가장자리라 한 행 어둡다(#1910 캡처).
    const origin_y = (self.backing_height_px -| h) + ((h -| self.cell_height_px) / 2);
    for (layout.left) |slot| {
        const dl = frames[slot.index] orelse continue;
        frames[slot.index] = null; // 소유권을 collectShaped로 넘긴다(위 defer가 두 번 해제하지 않게)
        self.collectShaped(collected, dl, builder, .{ .status_bar = .{ .origin_x = slot.x, .origin_y = origin_y, .colors = colors } });
    }
    for (layout.right) |slot| {
        const dl = right_frames[slot.index] orelse continue;
        right_frames[slot.index] = null;
        self.collectShaped(collected, dl, builder, .{ .status_bar = .{ .origin_x = slot.x, .origin_y = origin_y, .colors = colors } });
    }
}

pub fn buildStatusBarItem(self: *AppSession, icon: ?u21, text: []const u8, bar_cols: u16, fg: terminal.Color, icon_fg: terminal.Color, kind: StatusBarItemKind) ?renderer.DrawList {
    const max_text_cols: u16 = @max(1, bar_cols / 3);
    // 경로는 컴포넌트 단위로 먼저 줄인다. 예산을 아는 곳이 여기뿐이라 여기서 한다 — 호출부가 따로
    // 계산하면 줄인 폭과 그리는 폭이 갈린다. wide_icon predicate는 null이다(경로에 등록 아이콘이 올 수
    // 없고, pane 라벨 폭 계산도 같은 선례를 쓴다).
    var path_buf: [1024]u8 = undefined;
    const shown = switch (kind) {
        .plain => text,
        .path => chrome.text_layout.elidePathMiddle(text, max_text_cols, null, &path_buf),
    };
    return coretext_frame_builder.buildStatusBarItemDrawList(self.allocator, icon, shown, max_text_cols, fg, icon_fg) catch null;
}

/// 배치된 슬롯을 상호작용 tree로 발행한다. 좌/우를 한 tree에 담는다 — 판정은 "어느 항목인가" 하나라
/// 나눌 이유가 없다. 발행 실패(버퍼 부족)는 tree를 비워 **아무것도 안 눌리게** 한다: 잘못된 항목이
/// 눌리는 것보다 안 눌리는 편이 낫다.
fn publishStatusBarTree(
    self: *AppSession,
    bar_metrics: chrome.components.status_bar.Metrics,
    layout: chrome.components.status_bar.Layout,
    left_ids: []const chrome.components.status_bar.ItemId,
    right_ids: []const chrome.components.status_bar.ItemId,
) void {
    self.status_bar_entry_count = 0;
    self.status_bar_generation +|= 1;

    var written: usize = 0;
    inline for (.{ .{ layout.left, left_ids }, .{ layout.right, right_ids } }) |pair| {
        const slots = pair[0];
        const ids = pair[1];
        if (written >= self.status_bar_entry_scratch.len) break;
        const t = chrome.components.status_bar.publish(
            bar_metrics,
            slots,
            ids,
            layout_math.ptToPx(status_bar_item_pad_pt, self.scale_milli),
            self.status_bar_generation,
            self.status_bar_entry_scratch[written..],
        ) catch {
            self.status_bar_entry_count = 0;
            return;
        };
        written += t.entries.len;
    }
    self.status_bar_entry_count = written;

    // **새 tree에 없는 hover는 지운다.** `chrome/ui/interaction.zig`의 `reconcile`이 하는 일과 같다 —
    // 안 하면 항목이 사라졌다 다시 나타날 때(알림을 읽어 0이 됐다가 새 알림이 오는 경우) 포인터가
    // 그 자리에 없는데도 호버가 칠해진다. 포인터가 창 밖으로 나가 `hoverCursor`가 더는 안 불리는
    // 경우도 같은 부류다.
    if (self.status_bar_hovered) |id| {
        var still_there = false;
        for (statusBarTree(self).entries) |entry| {
            if (entry.id == @intFromEnum(id)) still_there = true;
        }
        if (!still_there) self.status_bar_hovered = null;
    }
}

/// 발행된 tree(슬라이스 view). 호출자가 hit-test·hover에 쓴다.
pub fn statusBarTree(self: *const AppSession) chrome.ui.tree.UiRectTree {
    return .{
        .entries = self.status_bar_entry_scratch[0..self.status_bar_entry_count],
        .generation = self.status_bar_generation,
    };
}

/// 포인터 아래 상태표시줄 항목. 없으면 null. **rect는 배치가 정한 그대로**라 보이는 자리와 눌리는
/// 자리가 같다(#1925가 바 전체에 대해 보장하는 것을 항목 단위로 좁힌 것).
pub fn statusBarItemAt(self: *const AppSession, x_px: f64, y_px: f64) ?chrome.components.status_bar.ItemId {
    for (statusBarTree(self).entries) |entry| {
        const r = entry.rect;
        if (x_px >= r.x and x_px < r.x + r.width and y_px >= r.y and y_px < r.y + r.height) {
            return @enumFromInt(entry.id);
        }
    }
    return null;
}

/// 호버 중인 항목의 배경. 배경 quad **바로 뒤**에 넣어 같은 bottom 버킷 안에서 위에 오게 한다
/// (버킷 안 순서 = painter 순서). 없으면 무동작이라 호버가 없을 때는 quad가 하나도 안 는다.
pub fn appendStatusBarHover(self: *AppSession) void {
    const id = self.status_bar_hovered orelse return;
    for (statusBarTree(self).entries) |entry| {
        if (entry.id != @intFromEnum(id)) continue;
        self.appendSolidQuad(
            entry.rect.x,
            entry.rect.y,
            entry.rect.width,
            entry.rect.height,
            // 사이드바 행 호버와 같은 톤 — 상태바만의 색을 새로 만들지 않는다.
            self.chromeQuadBg(sidebar_ops.sidebarRowHoverBg(self)),
            status_bar_layer,
        );
        return;
    }
}

/// 항목 클릭 — **이미 있는 표면을 여는 것만** 한다. 새 UI를 지어내지 않는다.
/// 브랜치는 열 대상이 아직 없어(브랜치 목록 UI 부재) 클릭해도 아무 일도 하지 않는다 — 호버도 안 준다.
pub fn activateStatusBarItem(self: *AppSession, id: chrome.components.status_bar.ItemId) void {
    switch (id) {
        .notifications => notification_ops.openNotificationPanel(self),
        // **그 에이전트로 간다**(§4). 옛 동작(기록 도크 열기)은 누른 것과 다른 것을 가리켰다.
        .running_agents => self.openAgentMenu(false),
        .blocked_agents => self.openAgentMenu(true),
        .cwd => dock_ops.openDockTo(self, .explorer),
        // **표시 전용이다.** 폰이 떠나면 host 가 크기를 되돌리며 저절로 사라지므로 여기서
        // 사용자가 할 일이 없다 — 누를 수 있게 보이면 아무 일도 안 하는 자리가 된다.
        .viewport_narrowed => {},
        .git_branch => settings_ops.requestBranchMenu(self, .switch_branch), // 로컬 브랜치 목록을 띄운다(고르면 터미널에 git switch 주입)
        // 리소스는 v1에서 **표시 전용**이다. 탭별 내역 패널은 이 숫자가 쓸모 있다고 확인된 뒤에 정한다
        // (docs/status-bar.md §6) — 열 대상이 없으니 아래 clickable도 false라 호버도 주지 않는다.
        .resource => openResourceMenu(self), // 탭별 내역 팝오버(§6) — 이 항목에 앵커한다
        // 편집기 넷은 **표시 전용**이다. 열 대상이 없다 — 읽기 전용을 눌러 편집을 켜는 길은 N2가
        // 만들고(그 전에 누르면 아무 일도 안 일어난다), 저하·줄바꿈은 상태 진술이지 컨트롤이 아니다.
        // 영속 세션 강등은 **표시 전용**이다. 다시 잇는 동작은 실제 socket reconnect(CR4)가 소유하므로
        // 여기서 만들지 않는다 — 지금 붙이면 선행 gate 우회다(implementation-plan.md CR 절).
        // **언어도 표시 전용이다** — 문법을 사용자가 고르는 개념이 아직 없다(`grammarForPath`
        // 위에 override 층이 필요하고 그건 별도 조각이다). 열 대상이 없으므로 호버도 안 준다.
        .editor_lsp => editor_ops.lsp_client.activateStatus(self), // 없음 → 설치 명령 입력 · 거부됨 → 다시 묻기 · 실패 → 재시작(§8.2a)
        .editor_degraded, .editor_readonly, .editor_eol, .editor_cursor, .editor_language, .workspace_checkpoint_failure, .session_host_disconnected => {},
    }
    self.metal_dirty = true;
}

/// 클릭 가능한 항목인가. 열 대상이 없는 항목은 호버도 주지 않는다 — 눌리는 것처럼 보이는데 아무
/// 일도 안 일어나는 편이 아무 표시도 없는 것보다 나쁘다.
pub fn statusBarItemClickable(id: chrome.components.status_bar.ItemId) bool {
    return switch (id) {
        // 브랜치도 이제 누를 수 있다 — 목록이 생겼다(§6에서 내려온 항목).
        .notifications, .running_agents, .blocked_agents, .cwd, .git_branch => true,
        .resource => true, // 누르면 탭별 내역 팝오버가 뜬다
        .viewport_narrowed => false, // 표시 전용 — 열 대상이 없다
        // 열 대상이 없으므로 호버도 주지 않는다 — 눌리는 것처럼 보이는데 아무 일도 안 하는 편이
        // 아무 표시도 없는 것보다 나쁘다(이 함수의 계약).
        .editor_lsp => true, // 설치·다시 묻기·재시작이 있다(§8.2a)
        .editor_degraded, .editor_readonly, .editor_eol, .editor_cursor, .editor_language, .workspace_checkpoint_failure, .session_host_disconnected => false,
    };
}

/// 포인터가 창 바닥 상태표시줄 위인가. **렌더 rect와 같은 산술**을 쓴다(`appendStatusBarBackground`와 한 쌍) —
/// 갈리면 보이는 자리와 눌리는 자리가 어긋난다. 상태바는 창 전폭이라 사이드바 아래 구간도 포함한다.
pub fn pointInStatusBar(self: *const AppSession, x_px: f64, y_px: f64) bool {
    const h = statusBarHeightPx(self);
    if (h == 0 or self.backing_width_px == 0) return false;
    const top: f64 = @floatFromInt(self.backing_height_px -| h);
    return y_px >= top and y_px < @as(f64, @floatFromInt(self.backing_height_px)) and
        x_px >= 0 and x_px < @as(f64, @floatFromInt(self.backing_width_px));
}

/// 창 바닥 상태표시줄 배경(창 전폭). **조건 없이 매 프레임 넣는다** — 도크·사이드바 상태와 무관하게 바가 늘
/// 서 있어야 `dock_layout`이 깎아 둔 자리와 화면이 일치한다(조건부로 만들면 깎인 자리에 아무것도 없는 프레임이
/// 생긴다). 항목(글자·아이콘)은 S3에서 이 배경 위에 올린다.
pub fn appendStatusBarBackground(self: *AppSession) void {
    const h = statusBarHeightPx(self);
    if (h == 0 or self.backing_width_px == 0 or self.backing_height_px == 0) return;
    const y = self.backing_height_px -| h;
    self.appendSolidQuad(
        0,
        @floatFromInt(y),
        @floatFromInt(self.backing_width_px),
        @floatFromInt(h),
        // 사이드바 톤을 따르되 **구분은 되게** — 사이드바 색을 터미널 배경 반대 방향으로 한 단계 옮긴다
        // (`tokens.statusBarBg`). 예전엔 사이드바와 **같은 색**이라 경계가 안 보였다(사용자 제보).
        // window.opacity는 그대로 반영한다(straight-alpha quad 경로).
        self.chromeQuadBg(packOpaqueRgb(chrome.tokens.statusBarBg(
            self.appearance.theme.sidebar_background,
            self.appearance.theme.background,
        ))),
        status_bar_layer,
    );
}

/// 상태바 **상단 경계선**. 띠 **안쪽 맨 위**에 겹쳐 그린다 — 바 밖에 그리면 터미널 마지막 행을 덮고,
/// 높이를 늘리면 작업영역이 줄어든다(§4.0). 바가 선보다 얇으면 바 높이로 clamp해 밖으로 새지 않는다.
///
/// **호출 순서가 계약이다**: 항목 호버 배경(`appendStatusBarHover`)은 슬롯이 바 전체 높이라 선과 같은
/// 자리를 칠한다. 같은 bottom 버킷 안에서는 배열 순서가 painter 순서라, 호버 **뒤에** 내지 않으면
/// 호버한 항목 위에서만 선이 끊긴다.
pub fn appendStatusBarTopBorder(self: *AppSession) void {
    const h = statusBarHeightPx(self);
    if (h == 0 or self.backing_width_px == 0 or self.backing_height_px == 0) return;
    const border_h = @min(layout_math.ptToPx(status_bar_border_pt, self.scale_milli), h);
    if (border_h == 0) return;
    self.appendSolidQuad(
        0,
        @floatFromInt(self.backing_height_px -| h),
        @floatFromInt(self.backing_width_px),
        @floatFromInt(border_h),
        self.chromeQuadBg(packOpaqueRgb(chrome.tokens.statusBarBorder(
            self.appearance.theme.sidebar_background,
            self.appearance.theme.background,
        ))),
        status_bar_layer,
    );
}
