//! 기기 흉내의 한 주인(W9e① — docs/plans/web-osr-backend.md 「W9e① 결정·실측」 §5–§7). maru 의 `emulation`(탭마다 **전체 상태**)을 받아 탭마다
//! 바라는 상태를 쥐고, 무엇을 보낼지는 `emu_plan.zig` 가 정하고, CDP 는 **스스로** 낸다(제 번호 대역 `emu_plan.id_base` — 권한·알림·엄격 모드와
//! 같다; maru 의 DevTools 표를 쓰지 않는다: 죽은 탭에서 답이 오지 않아 그 탭의 자리가 막히지 않게 — 계획 §13 P2-10). maru 를 거친 DevTools 호출의
//! `Emulation.*` 는 지킴(`devtools_table.forbiddenMethod`)이 막는다 — 흉내를 바꾸는 길은 여기 하나다.
//!
//! - **렌더러가 죽은 동안은 내지 않는다**: 죽은 탭에 `Emulation.setDeviceMetricsOverride` 를 보내면 maru-web-host 가 통째로(모든 Chromium 탭이)
//!   죽었다(실측 E11 — 세 번, `send_dev_tools_message` 아래 null 역참조). `renderer_gone` 부터 다음 주 프레임 `on_load_start` 까지 쌓고(마지막
//!   바라는 상태만) 새 렌더러에 차이만 낸다(이미 건 흉내는 Chromium 이 다시 건다 — E4).
//! - **사용자 탭은 그 사이트에서만**(사용자 결정 Q1): 주 프레임 `on_before_browse`(홉마다 — W9d③ 엄격 모드와 같은 자리)에서 그 홉의 호스트를
//!   grant 사이트가 덮으면 걸고 아니면 모두 지운다(값이 바뀔 때만). 리다이렉트 홉 요청 하나와 첫 요청의 client hints 는 한 요청 늦다(E12 — 문서화).
//!   사이트 밖 문서에서 사이트 안으로 가는 홉은 탭 전체에 아무것도 걸지 않고 모든 무리를 커밋(`on_load_start`)에서 건다 — 응답을 기다리는 동안
//!   옛(밖의) 문서가 화면 흉내를 봤고, 홉에서 건 UA 호출은 그 옛 문서가 만든 iframe·form 대상·Worker 의 요청에 흉내 머리를 실었다(옮긴 판 검증·집중
//!   검증 — `emu_plan.heldUntilCommit`). 그 홉의 주 프레임 문서 요청 하나에만 흉내 UA·client hints(·Accept-Language — CEF 154 는 진짜로 낸다)를
//!   직접 넣는다(`emu_inject.zig` — IO 스레드, 사용자 결정 2026-11-12 「그 한 요청만 머리를 직접 넣기」; 여기서는 기다림이 바뀔 때마다 넣을 값을
//!   적고 거둔다). bfcache 복원은 `on_before_browse` 를
//!   지나지 않아 복원된 밖의 문서가 pageshow 에서 흉내를 봤다 — maru 의 Chromium 은 bfcache 를 끈다(`app.zig` — 사용자 결정 2026-11-12).
//! - **거꾸로(안→밖) — maru 가 시작한 이동은 지움의 답 뒤에**(사용자 결정 2026-11-14 「maru 가 시작한 이동만 막기」 — `gateNav`): 사이트 안 문서에서 밖으로
//!   가는 HTTP 캐시의 뒤로(bfcache 가 아니다 — `pageshow` 의 `persisted` 거짓)는 홉에서 커밋까지가 짧아 홉에서 낸 지움이 새 렌더러에 옛 상태가 선 뒤
//!   닿았다 — 돌아간 밖의 문서가 첫 스크립트·pageshow 에서 흉내를 봤다. maru 의 주소·뒤로·앞으로·우클릭 메뉴의 뒤로·앞으로는 지움을 먼저 내고 그 답이
//!   다 오거나 100 ms 가 지나면 낸다. 페이지·에이전트 CDP 가 시작한 이동은 덮지 않는다(남는 틈 — 계획 문서).
//! - **화면은 pane 에 맞춰 줄인다**(사용자 결정 Q3 — `scale`): pane 크기가 바뀌면 다시 셈해 다시 낸다(E2).
//! - **위치는 W5b2 와 한 칸**(사용자 결정 Q2): `permissions.zig` 가 건다 — 그 탭의 위치만 묻는 프롬프트에는 묻지 않고 허용, 대신 허용한 출처는
//!   흉내가 끝나면 되돌린다.
//! - 답(`emulation_state`)은 낸 호출의 답이 다 오면, 아무것도 내지 않았으면 곧, 살아 있음·사이트 안팎·줄임·대신 허용한 출처가 바뀌면.
//! - **W9e② CPU**: 렌더러 프로세스 전체에 걸린다(같은 프로세스의 팝업·사용자 탭의 같은 사이트 iframe — 실측 c1·o1). 걸기 전에 `proc_share` 로 가족
//!   밖의 프레임이 함께 느려질 수 있는지 보고, 그러면 걸지 않고 그 무리를 `process_shared` 로 실패시킨다(이유를 늘 싣는다 — 사용자 결정 6). 걸린
//!   뒤에 그런 프레임이 생기면(어느 탭이든 프레임이 시작될 때 다시 본다) 곧 풀고 `released:process_shared`. 사이트를 모르는 가족 밖 하위 프레임
//!   (`data:`·불투명 출처 — `blob:`·`filesystem:` 은 안쪽 주소로 정한다)도 위험이다(적대 검증 7 회차 A7-1). 출처를 물려받는 하위 프레임(`about:blank`·
//!   srcdoc·`javascript:`·빈 주소)은 제 주소가 있는 조상의 자리로 보고, 그런 프레임이 있는 탭은 그 탭 하위 프레임이 그 주 문서에서 가졌던 사이트도
//!   있는 것으로 친다(`inheritedFrame`·`noteSubframeSite` — v20b V-A7: 다른 사이트 사용자 탭의 흔한 광고·분석 iframe 으로 거절하지 않는다; v20c N2:
//!   커밋한 문서만·주 문서마다·넘치면 다시 센다 — 리다이렉트 홉과 지난 문서의 기록이 그 탭을 닫을 때까지 거절하게 했다).
//! - **W9e② 네트워크**: 바람(`emu_plan.Tab.target`)을 `blocking.zig` 의 Network 도메인 주인에 넘긴다 — 본문 기록·엄격 모드와 같은 도메인이다.
//! - **W9e② 사람**: 사람이 그 탭을 몰면(입력·사람의 이동·대화상자·파일·권한의 답) CPU·네트워크를 풀고 `released:human_input`(PLAN v2 §8), 그
//!   탭과 연 탭 사슬이 같은 가족 탭에 걸린 CPU 도 푼다(같은 렌더러 프로세스 — v20c N4; 네트워크는 그 탭의 요청만이라 그 탭만).
//!
//! 스레드: 모두 UI 스레드(CEF 의 요청 처리기 `on_before_browse`·불러오기 처리기·DevTools 관찰자·명령 처리 모두).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");
const emu_plan = @import("emu_plan.zig");
const permissions = @import("permissions.zig");
const emu_inject = @import("emu_inject.zig");
const table_mod = @import("net_block_table.zig"); // 주소의 정규 해시(막기의 끊긴 이동 짝짓기와 같은 셈 — `canonHash`)
const blocking = @import("blocking.zig"); // W9e②: 네트워크 조건은 Network 도메인의 주인이 낸다
const proc_share = @import("proc_share.zig"); // W9e②: CPU 줄이기의 프로세스 나눔

const msg = protocol.message;
const BrowserId = msg.BrowserId;

const Entry = struct {
    cef_id: c_int,
    browser: BrowserId,
    tab: emu_plan.Tab = .{},
    reg: [*c]c.cef_registration_t = null,
    /// 마지막으로 보낸 상태(같으면 다시 보내지 않는다).
    last: ?msg.EmulationState = null,
    /// 대신 허용한 출처 목록이 바뀌었다(상태를 다시 보낸다).
    auto_dirty: bool = false,
    /// 마지막 주 프레임 이동 홉의 호스트(진행 중 이동 — `apply` 가 커밋된 옛 주소 대신 이것으로 사이트 안팎을 정한다: 다른 사이트로 가는 이동이
    /// 이미 지운 뒤 커밋 전에 온 `emulation` 이 옛 사이트로 다시 걸지 않게 — 적대 리뷰). 아는가·http(s) 호스트인가.
    hop_known: bool = false,
    hop_host: [msg.max_net_host_bytes]u8 = undefined,
    hop_len: usize = 0,
    /// 그 홉 주소의 정규 해시(`net_block_table.canonHash`) — 주 프레임 이동이 끊기면(`loadAborted` — 204·다운로드·멈춤) 끊긴 주소가 이 홉일 때만
    /// 옛 문서로 사이트 안팎을 되돌린다(새 이동에 밀려 늦게 온 옛 이동의 끊김은 새 홉을 지우지 않는다 — W9d③ `blocking.loadAborted` 와 같은 짝짓기).
    hop_canon: u64 = 0,
    /// W9e②: 네트워크 조건의 바람을 `blocking.zig` 에 넘겼다(푸는 것을 한 번 보낸다).
    cond_sent: bool = false,
    /// W9e② V-A7: 이 탭의 하위 프레임이 가졌던 사이트들(`noteSubframeSite` — 커밋한 문서만, 주 문서마다, 넘치면 지금 있는 프레임으로 다시 센다:
    /// v20c N2 — `proc_share.SubSites`). 모름이면 물려받는 하위 프레임이 있을 때 위험으로 친다.
    sub: proc_share.SubSites = .{},
    /// 거꾸로 경주 게이트(사용자 결정 2026-11-14) — 지움의 답을 기다리는 maru 의 이동 줄(`gateNav`).
    gate: emu_plan.Gate = .{},
    /// 줄에 있는 주소 이동의 주소 사본(`c_allocator`).
    gate_url: ?[]u8 = null,
    /// 게이트가 적은 가상 홉(대상의 호스트 — `hop_*`)이 아직 진짜 홉·커밋·끊김으로 바뀌지 않았다.
    gate_pseudo: bool = false,
    /// 게이트를 연(이동을 낸) 시각 — 안전망(`emu_plan.gate_safety_ms`). 0 = 없음.
    gate_opened_ms: i64 = 0,
    /// 가상 홉 동안 떠 있는 떠나기 확인(요청 번호 — 안전망을 멈추고, 머무르기·답 없이 치움이면 되돌린다). 0 = 없음.
    gate_dialog: u32 = 0,
    /// 로그·판정: 지움 수와 받은 답 수, 건 시각(µs).
    gate_clears: u32 = 0,
    gate_replies: u32 = 0,
    gate_t0_us: u64 = 0,

    fn hop(self: *const Entry) ?[]const u8 {
        return if (self.hop_len == 0) null else self.hop_host[0..self.hop_len];
    }
};

var entries: [registry_mod.capacity]?Entry = @splat(null);
var observer: c.cef_dev_tools_message_observer_t = undefined;
var observer_ready = false;
var next_id: i32 = emu_plan.id_base;
/// 답을 기다리는 흉내 호출(탭 32 × 종류 9 이면 288 — 넘치면 답을 기다리지 않고 「모름」 으로 둔다). `clear` 는 게이트가 낸 지움(`gate_arming`
/// 동안 — 상태(`Tab.status`)는 건드리지 않고 게이트의 남은 수만 센다: 평소 홉의 지움은 지금처럼 쫓지 않는다 — `emulation_state.pending` 의 뜻 그대로).
var pending_ids: [320]struct { id: i32 = 0, cef_id: c_int = 0, kind: emu_plan.Kind = .metrics, clear: bool = false } = @splat(.{});
/// 게이트가 지움을 내는 동안(`armGate` 의 `run` — UI 스레드).
var gate_arming = false;

fn logOn() bool {
    return std.c.getenv("MARU_WEB_TEST_EMU_LOG") != null;
}

fn initObserver() void {
    if (observer_ready) return;
    observer_ready = true;
    observer = object.zeroed(c.cef_dev_tools_message_observer_t);
    object.staticRefCounted(&observer.base);
    observer.on_dev_tools_method_result = &onResult;
    observer.on_dev_tools_agent_detached = &onDetached;
}

fn entryOf(cef_id: c_int) ?*Entry {
    for (&entries) |*e| if (e.*) |*v| if (v.cef_id == cef_id) return v;
    return null;
}

fn entryById(id: BrowserId) ?*Entry {
    for (&entries) |*e| if (e.*) |*v| if (v.browser == id) return v;
    return null;
}

fn ensure(reg: *const registry_mod.Entry) ?*Entry {
    if (entryOf(reg.cef_id)) |e| return e;
    for (&entries) |*e| if (e.* == null) {
        e.* = .{ .cef_id = reg.cef_id, .browser = reg.id };
        return &e.*.?;
    };
    return null;
}

fn browserOf(reg: *const registry_mod.Entry) [*c]c.cef_browser_t {
    return @ptrCast(@alignCast(reg.handle));
}

fn units(value: [*c]const c.cef_string_t) []const u16 {
    if (value == null or value.*.str == null) return &.{};
    return @ptrCast(value.*.str[0..value.*.length]);
}

/// 지금 맨 위 문서의 호스트(http(s) 가 아니면 null).
fn topHost(browser: [*c]c.cef_browser_t, out: *[msg.max_net_host_bytes]u8) ?[]const u8 {
    const frame = browser.*.get_main_frame.?(browser);
    if (frame == null) return null;
    defer object.release(frame);
    const raw = frame.*.get_url.?(frame);
    if (raw == null) return null;
    defer browsers.state.api.string_userfree_utf16_free(raw);
    const host = protocol.net_policy.hostOfUrl16(units(raw), out);
    return if (host.len == 0) null else host;
}

// ── maru 의 명령 ─────────────────────────────────────────────────────────────────────────────────────────

/// `emulation`(maru) — 그 탭의 바라는 상태를 바꾸고 차이를 낸다. 옛 sidecar 가 대신 허용한 위치 출처(`restore` — 재생 때만)는 먼저 되돌린다.
pub fn apply(v: msg.Emulation) void {
    initObserver();
    for (v.restore[0..v.restore_count]) |o| permissions.restoreOrigin(o);
    const reg = browsers.state.registry.byId(v.browser) orelse return;
    if (reg.closing) return; // 닫히는 탭에는 내지 않는다(세션이 함께 사라진다)
    const e = ensure(reg) orelse return;
    if (v.generation != e.tab.generation) e.tab.newGeneration();
    e.tab.setWant(v) catch return; // 풀 때 검사를 지났다 — 오지 않는다
    var hb: [msg.max_net_host_bytes]u8 = undefined;
    const shown = topHost(browserOf(reg), &hb);
    // 진행 중 이동이 있으면 그 홉으로(밖의 문서에서 안으로면 커밋까지 기다리고 그 홉의 문서 요청에만 머리), 아니면 지금 문서로.
    _ = if (e.hop_known) e.tab.hop(e.hop(), shown) else e.tab.navigate(shown);
    syncInject(e); // 기다리는 동안 온 지움·철회·다른 사이트는 그 뒤 홉부터 넣지 않는다
    e.tab.pane_w = reg.size.width;
    e.tab.pane_h = reg.size.height;
    if (logOn()) std.debug.print("emu: apply b={d} gen={d} flags=0x{x} on_site={} alive={}\n", .{ v.browser, v.generation, @as(u16, @bitCast(v.flags)), e.tab.on_site, e.tab.alive });
    run(e, reg);
    sendState(e, true);
}

/// 그 탭이 밖→안 홉을 기다리면 그 홉(주소)의 문서 요청에 넣을 머리를 IO 스레드의 표에 적고, 아니면 거둔다.
fn syncInject(e: *Entry) void {
    var inj: emu_plan.Inject = .{};
    if (e.hop_known and e.tab.injection(&inj)) {
        emu_inject.set(e.cef_id, e.hop_canon, &inj);
        if (logOn()) std.debug.print("emu: inject b={d} canon={x}\n", .{ e.browser, e.hop_canon });
    } else emu_inject.clear(e.cef_id);
}

fn run(e: *Entry, reg: *const registry_mod.Entry) void {
    var cmds: emu_plan.Cmds = .{};
    e.tab.plan(&cmds);
    for (cmds.slice()) |cmd| {
        // W9e②: CPU 를 걸기 전에 가족 밖의 프레임이 함께 느려지는지 본다(이유는 늘 공개 — 사용자 결정 6).
        if (cmd.kind == .cpu and cmd.set and cpuRisky(reg)) {
            e.tab.refuse(.cpu, .process_shared);
            sendCmd(e, reg, .{ .kind = .cpu, .set = false, .method = cmd.method, .params = "{\"rate\":1}" }); // 앞 값이 남지 않게(멱등)
            if (logOn()) std.debug.print("emu: cpu refused b={d} process_shared\n", .{e.browser});
            continue;
        }
        if (cmd.kind == .geo) {
            if (cmd.set) {
                if (!permissions.agentGeolocation(e.browser, browserOf(reg), cmd.geo.unavailable, cmd.geo.latitude, cmd.geo.longitude, cmd.geo.accuracy)) e.tab.sendFailed(.geo);
            } else permissions.agentEnd(e.browser, browserOf(reg));
            if (logOn()) std.debug.print("emu: geo b={d} set={} unavailable={}\n", .{ e.browser, cmd.set, cmd.geo.unavailable });
            continue;
        }
        sendCmd(e, reg, cmd);
    }
    syncConditions(e, reg);
}

/// W9e②: 네트워크 조건의 바람을 Network 도메인의 주인(`blocking.zig`)에 넘긴다(같은 바람이면 아무것도 내지 않는다).
fn syncConditions(e: *Entry, reg: *const registry_mod.Entry) void {
    const t = e.tab.networkTarget(); // 밖→안 홉의 커밋을 기다리는 동안은 걸지 않는다(W9e① 의 기다림)
    if (!t.flags.network) {
        if (e.cond_sent) blocking.setConditions(reg, null);
        e.cond_sent = false;
        return;
    }
    var hb: [32]u8 = undefined;
    std.mem.writeInt(u32, hb[0..4], t.latency_ms, .little);
    std.mem.writeInt(u32, hb[4..8], t.download_kbps, .little);
    std.mem.writeInt(u32, hb[8..12], t.upload_kbps, .little);
    hb[12] = @intFromBool(t.flags.offline);
    const raw = std.hash.Wyhash.hash(0x9e2, hb[0..13]);
    blocking.setConditions(reg, .{ .hash = if (raw == 0) 1 else raw, .offline = t.flags.offline, .latency_ms = t.latency_ms, .download_kbps = t.download_kbps, .upload_kbps = t.upload_kbps });
    e.cond_sent = true;
}

/// 로그용 — UTF-16 주소의 ASCII 앞부분.
fn ascii(u: []const u16, out: []u8) []const u8 {
    const n = @min(u.len, out.len);
    for (u[0..n], out[0..n]) |ch, *o| o.* = if (ch < 0x80) @intCast(ch) else '?';
    return out[0..n];
}

/// 한 프레임 주소의 사이트(`blob:`·`filesystem:` 은 안쪽 주소의 호스트 — A7-1, 겉 스킴만 보면 사이트 0). 모르면 0.
fn siteOfUrl16(u: []const u16) u64 {
    var hb: [msg.max_net_host_bytes]u8 = undefined;
    return proc_share.siteHash(protocol.net_policy.hostOfUrl16(proc_share.innerUrl16(u), &hb));
}

/// 출처를 물려받는 하위 프레임(V-A7)의 자리 — 위로 따라가 처음 만난 「제 주소가 있는」 조상(주 프레임이면 그 주 프레임과 같은 자리).
fn inheritedFrame(browser: c_int, frame: [*c]c.cef_frame_t, opener: c_int) proc_share.Frame {
    var cur = frame.*.get_parent.?(frame);
    var depth: usize = 0;
    while (cur != null and depth < 64) : (depth += 1) {
        const main = cur.*.is_main.?(cur) != 0;
        const raw = cur.*.get_url.?(cur);
        const u = units(raw);
        const inherits = proc_share.inheritsOrigin16(u);
        const site = siteOfUrl16(u);
        if (raw != null) browsers.state.api.string_userfree_utf16_free(raw);
        if (main or !inherits) {
            object.release(cur);
            return proc_share.inherited(browser, main, site, opener);
        }
        const next = cur.*.get_parent.?(cur);
        object.release(cur);
        cur = next;
    }
    if (cur != null) object.release(cur);
    return .{ .browser = browser, .main = false, .site = 0 }; // 조상을 모른다 — 위험으로
}

/// W9e②: 모든 탭의 프레임을 (탭, 주/하위, 사이트, 연 탭)으로 모아 이 탭에 CPU 를 걸면 가족 밖의 프레임이 함께 느려질 수 있는지(`proc_share`).
fn cpuRisky(reg: *const registry_mod.Entry) bool {
    var frames: [512]proc_share.Frame = undefined;
    var n: usize = 0;
    var t_site: u64 = 0;
    for (&browsers.state.registry.slots) |*slot| {
        const other = &(slot.* orelse continue);
        if (other.closing) continue;
        const b = browserOf(other);
        const host = b.*.get_host.?(b);
        const opener: c_int = if (host != null) host.*.get_opener_identifier.?(host) else 0;
        if (host != null) object.release(host);
        var inherits_sub = false;
        const list = browsers.state.api.string_list_alloc();
        defer browsers.state.api.string_list_free(list);
        b.*.get_frame_identifiers.?(b, list);
        const count = browsers.state.api.string_list_size(list);
        var i: usize = 0;
        while (i < count and n < frames.len) : (i += 1) {
            var id = std.mem.zeroes(c.cef_string_t);
            if (browsers.state.api.string_list_value(list, i, &id) == 0) continue;
            defer browsers.state.api.string_utf16_clear(&id);
            const frame = b.*.get_frame_by_identifier.?(b, &id);
            if (frame == null) continue;
            defer object.release(frame);
            const main = frame.*.is_main.?(frame) != 0;
            const raw = frame.*.get_url.?(frame);
            defer if (raw != null) browsers.state.api.string_userfree_utf16_free(raw);
            // 그래도 모르면 0 — `risky` 가 가족 밖이면 위험으로 친다(`data:` 등). 출처를 물려받는 하위 프레임은 물려준 조상의 자리(V-A7).
            const inherits = !main and proc_share.inheritsOrigin16(units(raw));
            inherits_sub = inherits_sub or inherits;
            frames[n] = if (inherits)
                inheritedFrame(other.cef_id, frame, opener)
            else
                .{ .browser = other.cef_id, .main = main, .site = siteOfUrl16(units(raw)), .opener = if (main) opener else 0 };
            if (main and other.cef_id == reg.cef_id) t_site = frames[n].site;
            if (logOn()) {
                var b1: [200]u8 = undefined;
                std.debug.print("emu: frame b={d} main={} url={s} -> main={} site={x}\n", .{ other.id, main, ascii(units(raw), &b1), frames[n].main, frames[n].site });
            }
            n += 1;
        }
        // V-A7: 물려받는 하위 프레임이 있는 탭은 그 탭의 하위 프레임이 그 주 문서에서 가졌던 사이트의 하위 프레임도 있는 것으로 친다(그 프레임이
        // 제 문서를 `about:blank` 로 바꿨으면 제 프로세스에 남는다 — 어느 프레임이 그랬는지는 모른다). 기록을 모르면 사이트 0(위험).
        if (inherits_sub) if (entryOf(other.cef_id)) |e| {
            for (e.sub.sites()) |s| if (n < frames.len) {
                frames[n] = proc_share.taint(other.cef_id, s);
                n += 1;
            };
            if (e.sub.lost() and n < frames.len) {
                frames[n] = proc_share.taint(other.cef_id, 0);
                n += 1;
            }
        };
    }
    // 가를 수 없을 만큼 프레임이 많으면 위험으로 본다(더 거절하는 쪽).
    if (n == frames.len) return true;
    return proc_share.risky(frames[0..n], reg.cef_id, t_site);
}

/// W9e② 결정 12: 그 탭(`cef_id`)의 렌더러 프로세스에 가족 밖의 프레임이 들 수 있는가 — CPU 조건과 같은 판정(`cpuRisky`). 모르면(탭이 없다) 참.
/// trace 가 그 프로세스의 이벤트를 가족 것으로 남겨도 되는지(`tracing.shared`)에 쓴다.
pub fn processShared(cef_id: c_int) bool {
    const reg = browsers.state.registry.byCefId(cef_id) orelse return true;
    return cpuRisky(reg);
}

/// V-A7: 이 탭의 하위 프레임이 커밋한 문서의 사이트를 적는다(`on_load_start` — v20c N2: 이동 홉은 적지 않는다, 리다이렉트는 문서를 만들지 않는다).
/// 물려받는 문서(`about:blank` 등)는 그것을 시작한 쪽 — 부모 또는 그 프레임 자신(제 앞 문서) — 의 프로세스에 든다. 프레임 자신이 제 문서를
/// `about:blank` 로 바꾸는 이동은 `on_before_browse` 를 지나지 않고(실측 — 홉이 오지 않았다) 프레임 번호도 바뀔 수 있어 「그 프레임의 앞 사이트」 를
/// 알 길이 없다 — 그래서 주 문서마다 「하위 프레임이 가졌던 사이트」 를 적고, 물려받는 하위 프레임이 있는 동안 그 사이트들의 하위 프레임이 있는 것으로
/// 친다(`cpuRisky` — A7-1 의 「제 문서를 바꾼 같은 사이트 iframe」 이 `about:blank` 로 새지 않게). 칸이 넘치면 지금 있는 하위 프레임의 사이트와
/// 열린 탭들의 맨 위 사이트로 다시 센다(`SubSites.subCommitted`).
fn noteSubframeSite(browser: [*c]c.cef_browser_t, url: [*c]const c.cef_string_t) void {
    const reg = browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) orelse return;
    const site = siteOfUrl16(units(url));
    if (site == 0) return; // 물려받는 문서·data: 등 — 다른 규칙이 가른다
    const e = ensure(reg) orelse return;
    var present: [64]u64 = undefined;
    var tops: [registry_mod.capacity]u64 = undefined;
    e.sub.subCommitted(site, presentSubSites(browser, &present), openTopSites(&tops));
    if (logOn()) {
        var b1: [200]u8 = undefined;
        std.debug.print("emu: subframe site b={d} {s} (recorded {d}, lost {})\n", .{ e.browser, ascii(units(url), &b1), e.sub.sites().len, e.sub.lost() });
    }
}

/// 그 탭에 지금 있는 하위 프레임의 사이트(제 주소가 있는 것만 — 물려받는 문서는 사이트가 없다).
fn presentSubSites(b: [*c]c.cef_browser_t, out: []u64) []const u64 {
    var n: usize = 0;
    const list = browsers.state.api.string_list_alloc();
    defer browsers.state.api.string_list_free(list);
    b.*.get_frame_identifiers.?(b, list);
    const count = browsers.state.api.string_list_size(list);
    var i: usize = 0;
    while (i < count and n < out.len) : (i += 1) {
        var id = std.mem.zeroes(c.cef_string_t);
        if (browsers.state.api.string_list_value(list, i, &id) == 0) continue;
        defer browsers.state.api.string_utf16_clear(&id);
        const frame = b.*.get_frame_by_identifier.?(b, &id);
        if (frame == null) continue;
        defer object.release(frame);
        if (frame.*.is_main.?(frame) != 0) continue;
        const raw = frame.*.get_url.?(frame);
        defer if (raw != null) browsers.state.api.string_userfree_utf16_free(raw);
        const site = siteOfUrl16(units(raw));
        if (site != 0) {
            out[n] = site;
            n += 1;
        }
    }
    return out[0..n];
}

/// 열린 탭들의 맨 위 문서 사이트(CPU 를 거는 탭의 사이트가 될 수 있는 것).
fn openTopSites(out: []u64) []const u64 {
    var n: usize = 0;
    for (&browsers.state.registry.slots) |*slot| {
        const other = &(slot.* orelse continue);
        if (other.closing or n >= out.len) continue;
        var hb: [msg.max_net_host_bytes]u8 = undefined;
        const site = proc_share.siteHash(topHost(browserOf(other), &hb) orelse continue);
        if (site != 0) {
            out[n] = site;
            n += 1;
        }
    }
    return out[0..n];
}

/// 주 문서 주소의 해시(조각 `#…` 은 뺀다 — 같은 문서다; 0 이 아니게).
fn docKey(u: []const u16) u64 {
    const end = std.mem.indexOfScalar(u16, u, '#') orelse u.len;
    const h = std.hash.Wyhash.hash(0x9e2d, std.mem.sliceAsBytes(u[0..end]));
    return if (h == 0) 1 else h;
}

fn takeId() i32 {
    const id = next_id;
    next_id = if (next_id + 1 >= emu_plan.id_end) emu_plan.id_base else next_id + 1;
    return id;
}

fn sendCmd(e: *Entry, reg: *const registry_mod.Entry, cmd: emu_plan.Cmd) void {
    const b = browserOf(reg);
    const host = b.*.get_host.?(b);
    if (host == null) return e.tab.sendFailed(cmd.kind);
    defer object.release(host);
    // 결과를 받으려면 관찰자가 있어야 한다(결과는 그 브라우저의 모든 관찰자에게 간다 — 제 대역만 고른다).
    if (e.reg == null) e.reg = host.*.add_dev_tools_message_observer.?(host, &observer);
    const id = takeId();
    var jb: [8 * 1024]u8 = undefined;
    const json = std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, cmd.method, cmd.params }) catch return e.tab.sendFailed(cmd.kind);
    // 같은 종류의 옛 호출은 더 기다리지 않는다 — 그 답이 이 호출의 답으로 잡히면 실패한 걸기를 걸린 것으로 보였다(적대 리뷰).
    for (&pending_ids) |*p| if (p.id != 0 and p.cef_id == e.cef_id and p.kind == cmd.kind) {
        p.* = .{};
    };
    var tracked = false;
    if (cmd.set or gate_arming) {
        for (&pending_ids) |*p| if (p.id == 0) {
            p.* = .{ .id = id, .cef_id = e.cef_id, .kind = cmd.kind, .clear = !cmd.set };
            tracked = true;
            break;
        };
    }
    if (logOn()) std.debug.print("emu: cdp b={d} {s} {s}\n", .{ e.browser, cmd.method, cmd.params });
    if (host.*.send_dev_tools_message.?(host, json.ptr, json.len) == 0) {
        if (tracked) for (&pending_ids) |*p| if (p.id == id) {
            p.* = .{};
        };
        if (cmd.set) e.tab.sendFailed(cmd.kind);
        return;
    }
    // 자리가 없어 기다리지 못한 걸기는 걸린 것으로 친다(답은 버린다 — 실패는 다음 바뀜에 드러난다).
    if (cmd.set and !tracked) e.tab.answered(cmd.kind, true, "");
}

fn onResult(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, id: c_int, success: c_int, result: ?*const anyopaque, size: usize) callconv(.c) void {
    defer object.releaseArg(browser);
    if (id < emu_plan.id_base or id >= emu_plan.id_end) return; // 다른 사용처의 결과
    for (&pending_ids) |*p| if (p.id == id) {
        const cef_id = p.cef_id;
        const kind = p.kind;
        const clear = p.clear;
        p.* = .{};
        const e = entryOf(cef_id) orelse return;
        if (clear) {
            // 게이트의 지움 — 실패 답도 답이다(렌더러가 처리했다). 마지막 답이면 열기를 task 로 미룬다: 관찰자 콜백 안에서 이동·명령을 내지 않는다
            // (`Check failed: !check_reentrancy` — W9d②·W9e② 의 같은 사고, 공격 A13).
            e.gate_replies += 1;
            if (logOn()) std.debug.print("emu: result b={d} {s} clear ok={}\n", .{ e.browser, @tagName(kind), success != 0 });
            if (e.gate.active and gateLeft(cef_id) == 0) postGate(0);
            return;
        }
        const bytes: []const u8 = if (result != null and size > 0) @as([*]const u8, @ptrCast(result.?))[0..@min(size, 4096)] else "";
        e.tab.answered(kind, success != 0, bytes);
        if (logOn()) std.debug.print("emu: result b={d} {s} ok={} {s}\n", .{ e.browser, @tagName(kind), success != 0, if (success != 0) "" else bytes });
        if (!e.tab.waiting()) sendState(e, false);
        return;
    };
}

fn dropPending(cef_id: c_int) void {
    for (&pending_ids) |*p| if (p.id != 0 and p.cef_id == cef_id) {
        p.* = .{};
    };
}

fn onDetached(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t) callconv(.c) void {
    defer object.releaseArg(browser);
    if (browser == null) return;
    const cef_id = browser.*.get_identifier.?(browser);
    dropPending(cef_id);
    const e = entryOf(cef_id) orelse return;
    // 답을 기다리던 것은 걸렸는지 모른다 — 다음 계획(되살아난 뒤)이 다시 낸다.
    e.tab.detached();
    sendState(e, false);
    if (e.gate.active) postGate(0); // 게이트의 지움은 더 답이 오지 않는다 — 연다(관찰자 콜백 밖에서)
}

// ── CEF 사건 ───────────────────────────────────────────────────────────────────────────────────────────

/// 주 프레임 `on_before_browse`(홉마다) — 사이트에 묶인 탭이 사이트 안팎을 오가면 걸거나 지운다(그 이동에 듣는다 — 실측 E12).
pub fn beforeBrowse(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t) void {
    if (browser == null or frame == null or request == null) return;
    // W9e② v20c N2: 하위 프레임의 홉은 적지 않는다(리다이렉트 홉은 문서를 만들지 않는다 — 커밋은 `loadStart` 가 적는다).
    if (frame.*.is_main.?(frame) == 0) return;
    const reg = browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) orelse return;
    // 흉내가 아직 없는 탭도 홉의 호스트를 적는다 — 커밋 전에 오는 첫 `emulation` 이 진행 중 이동의 사이트로 정하게.
    const e = ensure(reg) orelse return;
    const raw = request.*.get_url.?(request);
    defer if (raw != null) browsers.state.api.string_userfree_utf16_free(raw);
    var hb: [msg.max_net_host_bytes]u8 = undefined;
    const host = protocol.net_policy.hostOfUrl16(units(raw), &hb);
    @memcpy(e.hop_host[0..host.len], host);
    e.hop_len = host.len;
    e.hop_known = true;
    e.hop_canon = table_mod.canonHash(u16, units(raw));
    // 게이트: 이동이 시작됐다 — 가상 홉은 진짜 홉으로 끝나고(안전망도), 기다리는 줄이 있으면(그 사이 페이지가 이동을 시작했다 — 이 뒤 지움은 커밋까지 답이
    // 오지 않는다, 공격 A4) 더 기다리지 않고 연다(task — 요청 처리기 안에서 이동을 내지 않는다).
    endPseudo(e);
    if (e.gate.active) postGate(0);
    var sb: [msg.max_net_host_bytes]u8 = undefined;
    const changed = e.tab.hop(if (host.len == 0) null else host, topHost(browser, &sb));
    syncInject(e); // 안→안 리다이렉트도(새 홉의 주소로), 안→밖 홉은 거둔다 — 그 홉의 요청보다 먼저(IO 스레드는 이 뒤에 그 요청을 본다)
    if (!changed) return;
    if (logOn()) std.debug.print("emu: site b={d} host={s} on_site={} hold={}\n", .{ e.browser, host, e.tab.on_site, e.tab.hold });
    run(e, reg);
    sendState(e, false);
}

/// 주 프레임 `on_load_start` — 새 문서가 섰다(커밋): 사이트 안으로 가는 홉이 커밋까지 미룬 무리(`hold`)와 렌더러가 죽은 동안 쌓인 차이를 낸다.
/// `transition` 의 뒤로·앞으로 표시는 하위 프레임 기록을 되살릴지 가른다(W9e② V-A7·v20c N2 — bfcache; 지금은 bfcache 를 끈다 — `app.zig`
/// `product_switches` — 뒤로·앞으로도 다시 불러온 문서라 옛 기록으로 돌아가는 쪽은 더 거절하는 쪽일 뿐이다).
pub fn loadStart(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, transition: c.cef_transition_type_t) void {
    if (browser == null or frame == null) return;
    if (frame.*.is_main.?(frame) == 0) { // W9e② V-A7: 하위 프레임이 연 문서의 사이트
        const raw = frame.*.get_url.?(frame);
        defer if (raw != null) browsers.state.api.string_userfree_utf16_free(raw);
        return noteSubframeSite(browser, raw);
    }
    // W9e② v20c N2: 새 주 문서 — 하위 프레임 기록을 그 문서의 것으로(흉내가 없는 사용자 탭도 — CPU 판정이 모든 탭을 본다).
    if (browsers.state.registry.byCefId(browser.*.get_identifier.?(browser))) |reg_any| if (ensure(reg_any)) |e_any| {
        const raw = frame.*.get_url.?(frame);
        defer if (raw != null) browsers.state.api.string_userfree_utf16_free(raw);
        const back_forward = @as(u32, @bitCast(transition)) & @as(u32, @intCast(c.TT_FORWARD_BACK_FLAG)) != 0;
        e_any.sub.mainCommitted(docKey(units(raw)), back_forward);
    };
    const e = entryOf(browser.*.get_identifier.?(browser)) orelse return;
    const reg = browsers.state.registry.byCefId(e.cef_id) orelse return;
    if (reg.closing) return;
    const back = e.tab.rendererBack();
    // 안전망: 새 문서의 주소로 사이트 안팎을 다시 본다(`on_before_browse` 를 지나지 않는 문서 복원도). 홉 기록은 이 문서로 끝났다.
    const raw = frame.*.get_url.?(frame);
    defer if (raw != null) browsers.state.api.string_userfree_utf16_free(raw);
    var hb: [msg.max_net_host_bytes]u8 = undefined;
    const host = protocol.net_policy.hostOfUrl16(units(raw), &hb);
    e.hop_known = false;
    endPseudo(e);
    _ = e.tab.navigate(if (host.len == 0) null else host);
    emu_inject.clear(e.cef_id); // 그 이동은 끝났다
    if (logOn() and back) std.debug.print("emu: renderer back b={d}\n", .{e.browser});
    if (logOn()) std.debug.print("emu: commit b={d} host={s} on_site={}\n", .{ e.browser, host, e.tab.on_site });
    // 새 렌더러(쌓인 차이)·사이트 안팎·DevTools 가 떨어져 모르게 된 종류 — 살아 있는 문서가 막 시작했으니 차이를 낸다(바뀐 것이 없으면 빈 열).
    run(e, reg);
    sendState(e, false);
}

/// 주 프레임 이동이 문서 없이 끊겼다(`on_load_error` 의 ERR_ABORTED — 204·다운로드·멈춤; main 으로 옮길 때 더함 2026-11-12). `on_before_browse` 가
/// 그 홉의 사이트로 이미 걸거나 지웠는데 옛 문서가 남는다 — 끊긴 주소가 마지막 홉이면 지금 맨 위 문서의 호스트로 다시 정한다. 안 그러면 묶인 사이트
/// 밖의 문서에서 묶인 사이트로 가는 204 하나가 그 문서에 흉내를 걸었다(사용자가 허락하지 않은 사이트 — Q1), 거꾸로는 묶인 사이트의 문서에서 흉내가
/// 풀린 채 남았다. 오류 페이지(ERR_ABORTED 밖)는 `on_load_start` 가 새 문서로 본다.
pub fn loadAborted(browser: [*c]c.cef_browser_t, failed_url: [*c]const c.cef_string_t) void {
    if (browser == null) return;
    const e = entryOf(browser.*.get_identifier.?(browser)) orelse return;
    if (!e.hop_known or table_mod.canonHash(u16, units(failed_url)) != e.hop_canon) return;
    const reg = browsers.state.registry.byCefId(e.cef_id) orelse return;
    if (reg.closing) return;
    e.hop_known = false;
    endPseudo(e);
    emu_inject.clear(e.cef_id);
    var hb: [msg.max_net_host_bytes]u8 = undefined;
    if (!e.tab.navigate(topHost(browserOf(reg), &hb))) return;
    if (logOn()) std.debug.print("emu: aborted b={d} on_site={}\n", .{ e.browser, e.tab.on_site });
    run(e, reg);
    sendState(e, false);
}

/// 주 프레임 이동이 실패해 오류 페이지가 섰다(`on_load_error` 의 ERR_ABORTED 밖 — CEF 헤더: `on_load_start` 없이 옛 문서를 바꾼다). 끊긴 주소가
/// 마지막 홉이면 그 오류 페이지(실패한 주소)를 커밋된 문서로 보고 기다림을 끝낸다 — 안 그러면 밖→안 홉의 기다림·넣을 머리가 다음 이동까지 남았다
/// (옮긴 판 검증 L2 — Chromium 의 자동 다시 불러오기가 없는 오류면). 허락한 사이트 주소의 오류 페이지라 흉내가 걸려도 새는 쪽이 아니다.
pub fn loadFailed(browser: [*c]c.cef_browser_t, failed_url: [*c]const c.cef_string_t) void {
    if (browser == null) return;
    const e = entryOf(browser.*.get_identifier.?(browser)) orelse return;
    if (!e.hop_known or table_mod.canonHash(u16, units(failed_url)) != e.hop_canon) return;
    const reg = browsers.state.registry.byCefId(e.cef_id) orelse return;
    if (reg.closing) return;
    e.hop_known = false;
    endPseudo(e);
    emu_inject.clear(e.cef_id);
    var hb: [msg.max_net_host_bytes]u8 = undefined;
    const host = protocol.net_policy.hostOfUrl16(units(failed_url), &hb);
    if (!e.tab.navigate(if (host.len == 0) null else host)) return;
    if (logOn()) std.debug.print("emu: error page b={d} host={s} on_site={}\n", .{ e.browser, host, e.tab.on_site });
    run(e, reg);
    sendState(e, false);
}

/// 렌더러가 죽었다 — 이 탭의 흉내 명령을 쌓기 시작한다(E11).
pub fn rendererGone(cef_id: c_int) void {
    // 흉내가 아직 없는 탭도 적는다 — 그 뒤 처음 오는 `emulation` 이 죽은 렌더러에 metrics 를 보내지 않게(E11 — 적대 리뷰).
    const reg = browsers.state.registry.byCefId(cef_id) orelse return;
    const e = ensure(reg) orelse return;
    dropPending(cef_id);
    e.tab.rendererGone();
    if (logOn()) std.debug.print("emu: renderer gone b={d}\n", .{e.browser});
    sendState(e, false);
    if (e.gate.active) postGate(0); // 지움의 답은 오지 않는다 — 연다(새 렌더러는 Chromium 이 옛 흉내를 다시 건다 — 남는 틈, 공격 A9)
}

/// pane 크기가 바뀌었다(`resize`) — 흉내 화면이 있으면 fit 을 다시 셈해 다시 낸다(Chromium 은 셈하지 않는다 — E2).
pub fn resized(reg: *const registry_mod.Entry) void {
    if (reg.closing) return;
    const e = entryOf(reg.cef_id) orelse return;
    if (!e.tab.resize(reg.size.width, reg.size.height)) return;
    run(e, reg);
    sendState(e, false);
}

/// `permissions.zig` 가 대신 허용한 출처를 적거나 되돌렸다 — 상태를 다시 보낸다(maru 가 재시작 때 쓰려고 기억한다).
pub fn autoAllowedChanged(id: BrowserId) void {
    const e = entryById(id) orelse return;
    e.auto_dirty = true;
    sendState(e, false);
}

/// 브라우저가 닫힌다(`on_before_close`) — 표를 지운다(명령은 내지 않는다 — 세션이 함께 사라진다). 대신 허용한 출처는 `permissions.forgetBrowser`
/// 가 되돌린다.
pub fn browserClosed(cef_id: c_int) void {
    dropPending(cef_id);
    emu_inject.clear(cef_id);
    for (&entries) |*e| if (e.*) |v| if (v.cef_id == cef_id) {
        if (v.reg != null) object.release(v.reg);
        if (v.gate_url) |u| std.heap.c_allocator.free(u); // 줄은 버린다(이동 없음)
        e.* = null;
    };
}

// ── 상태 ─────────────────────────────────────────────────────────────────────────────────────────────────

fn sendState(e: *Entry, force: bool) void {
    // 흉내를 받은 적 없는 탭(홉·렌더러만 적은 자리)은 알리지 않는다.
    if (e.tab.wanted() == null and !e.auto_dirty and !force) return;
    var st = e.tab.state(e.browser);
    // W9e②: 네트워크 무리는 Network 도메인의 주인이 쥔 상태로.
    const net_bit: u16 = @as(u16, 1) << @backingInt(msg.EmuGroup.network);
    if (e.tab.networkTarget().flags.network) switch (blocking.conditionsStatus(e.cef_id)) {
        .on => st.active_mask |= net_bit,
        .pending, .off => st.pending = true,
        .failed => {
            st.failed_mask |= net_bit;
            if (st.reason == .none) st.reason = .cdp_error;
        },
    };
    var autos: [msg.max_emu_geo_origins][]const u8 = undefined;
    const list = permissions.autoAllowed(e.browser, &autos);
    st.auto_count = @intCast(list.len);
    for (list, 0..) |o, i| st.auto_allowed[i] = o;
    if (!force and !e.auto_dirty) if (e.last) |prev| if (sameState(prev, st)) return;
    e.auto_dirty = false;
    var keep = st;
    keep.auto_count = 0;
    keep.auto_allowed = @splat("");
    e.last = keep;
    browsers.state.writer.send(.{ .emulation_state = st }) catch {};
}

fn sameState(a: msg.EmulationState, b: msg.EmulationState) bool {
    return a.generation == b.generation and a.on_site == b.on_site and a.alive == b.alive and a.pending == b.pending and a.fit_scale == b.fit_scale and
        a.active_mask == b.active_mask and a.failed_mask == b.failed_mask and a.reason == b.reason and a.released_mask == b.released_mask;
}

// ── W9e②: 풀림 ─────────────────────────────────────────────────────────────────────────────────────────

/// 네트워크 조건의 답이 다 왔다(`blocking.zig`) — 상태를 다시 보낸다.
pub fn conditionsSettled(id: BrowserId) void {
    const e = entryById(id) orelse return;
    sendState(e, false);
}

/// 사람이 그 탭을 몸(입력·사람의 이동·대화상자·파일·권한의 답) — 그 탭의 CPU·네트워크를 풀고(`released:human_input`), 그 탭과 한 가족(연 탭
/// 사슬의 뿌리가 같다)인 탭들의 CPU 도 푼다(적대 검증 v20c N4: CPU 는 렌더러 프로세스 전체에 걸려 에이전트 탭에 건 조건이 그 탭이 연 팝업도 느리게
/// 한다 — 사람이 그 팝업을 몰기 시작해도 연 탭의 조건은 남아 4.3 배 느린 채였다). 네트워크 조건은 그 탭의 요청만이라(팝업은 받지 않는다 — A8-1)
/// 그 탭만 푼다.
pub fn humanInput(id: BrowserId) void {
    const touched = browsers.state.registry.byId(id) orelse return;
    if (entryById(id)) |e| releaseByHuman(e, touched, true);
    var frames: [registry_mod.capacity]proc_share.Frame = undefined;
    const fam = familyFrames(&frames);
    const root = proc_share.familyRoot(fam, touched.cef_id);
    for (&entries) |*slot| if (slot.*) |*e| {
        if (e.browser == id or !e.tab.target().flags.cpu) continue;
        if (proc_share.familyRoot(fam, e.cef_id) != root) continue;
        const reg = browsers.state.registry.byId(e.browser) orelse continue;
        releaseByHuman(e, reg, false);
    };
}

fn releaseByHuman(e: *Entry, reg: *const registry_mod.Entry, with_network: bool) void {
    const a = e.tab.release(.cpu, .human_input);
    const b = with_network and e.tab.release(.network, .human_input);
    if (!a and !b) return;
    if (logOn()) std.debug.print("emu: released by human b={d} cpu={} network={}\n", .{ e.browser, a, b });
    run(e, reg);
    sendState(e, false);
}

/// 열린 탭마다 주 프레임 하나(연 탭 번호만 — `familyRoot` 용).
fn familyFrames(out: []proc_share.Frame) []const proc_share.Frame {
    var n: usize = 0;
    for (&browsers.state.registry.slots) |*slot| {
        const other = &(slot.* orelse continue);
        if (n >= out.len) break;
        const b = browserOf(other);
        const host = b.*.get_host.?(b);
        const opener: c_int = if (host != null) host.*.get_opener_identifier.?(host) else 0;
        if (host != null) object.release(host);
        out[n] = .{ .browser = other.cef_id, .main = true, .site = 0, .opener = opener };
        n += 1;
    }
    return out[0..n];
}

/// 어느 탭이든 프레임이 시작됐다·탭이 생겼다 — CPU 를 건 탭마다 가족 밖의 프레임이 함께 느려지게 됐는지 다시 본다(그러면 곧 풀고
/// `released:process_shared`).
pub fn framesChanged() void {
    for (&entries) |*slot| if (slot.*) |*e| {
        const t = e.tab.target();
        if (!t.flags.cpu) continue;
        const reg = browsers.state.registry.byId(e.browser) orelse continue;
        if (reg.closing or !cpuRisky(reg)) continue;
        if (!e.tab.release(.cpu, .process_shared)) continue;
        if (logOn()) std.debug.print("emu: cpu released b={d} process_shared\n", .{e.browser});
        run(e, reg);
        sendState(e, false);
    };
}

// ── 거꾸로 경주 게이트(사용자 결정 2026-11-14 「maru 가 시작한 이동만 막기」) ─────────────────────────────────────────
//
// 사이트에 묶인 흉내가 걸린 사이트 안 문서에서 maru 가 시작한 이동(wire `navigate`·`nav_action` 뒤로·앞으로, 우클릭 메뉴의 뒤로·앞으로 — CEF 가 직접
// 낸다)이 사이트 밖 문서로 가면, 지움을 **먼저** 내고 그 답을 쫓아 다 오거나 시한(`emu_plan.gate_deadline_ms`)이 지나면 이동을 낸다(UI task —
// 관찰자 콜백 안에서는 내지 않는다). 캐시에서 오는 뒤로는 홉에서 커밋까지가 짧아, 홉에서 낸 지움이 이동 동안 붙잡혔다가 새 렌더러에 옛 상태가 선 뒤
// 닿았다 — 돌아간 밖의 문서가 첫 스크립트·pageshow 에서 흉내를 보고 그 요청이 흉내 머리를 실었다(실측 부하 22: 27/40·21/40, 게이트 0/40; 답은
// 0.4 ms). 지움은 대상 호스트로 적은 가상 홉(`gate_pseudo`)이 낸다 — 이동이 시작되면 진짜 홉이 이어받고, 시작되지 않으면(떠나기 확인의 머무르기·답
// 없이 치운 확인·멈춤·안전망 1 초) 지금 문서로 되돌려 다시 건다. 페이지·에이전트 CDP 가 시작한 이동은 덮지 않는다(남는 틈 — 계획 문서).

const max_hist = 64;
var hist_visitor: c.cef_navigation_entry_visitor_t = undefined;
var hist_ready = false;
var hist_hosts: [max_hist][msg.max_net_host_bytes]u8 = undefined;
var hist_lens: [max_hist]usize = undefined;
var hist_canon: [max_hist]u64 = undefined;
var hist_seen: [max_hist]bool = undefined;
var hist_current: ?usize = null;

fn visitHist(_: [*c]c.cef_navigation_entry_visitor_t, ent: [*c]c.cef_navigation_entry_t, current: c_int, index: c_int, _: c_int) callconv(.c) c_int {
    defer object.releaseArg(ent);
    if (ent == null or index < 0 or index >= max_hist) return 1;
    const i: usize = @intCast(index);
    const u = ent.*.get_url.?(ent);
    defer if (u != null) browsers.state.api.string_userfree_utf16_free(u);
    hist_lens[i] = protocol.net_policy.hostOfUrl16(units(u), &hist_hosts[i]).len;
    hist_canon[i] = table_mod.canonHash(u16, units(u));
    hist_seen[i] = true;
    if (current != 0) hist_current = i;
    return 1;
}

/// 게이트가 볼 이동의 대상 — 문서를 바꾸는 이동이면 `known`(호스트를 모르면 빈 글 — 밖), 정규 해시는 가상 홉의 끊김 짝짓기에.
const Target = struct {
    known: bool = false,
    host_buf: [msg.max_net_host_bytes]u8 = undefined,
    host_len: usize = 0,
    canon: u64 = 0,

    fn host(self: *const Target) ?[]const u8 {
        return if (self.host_len == 0) null else self.host_buf[0..self.host_len];
    }
};

/// 그 이동이 갈 문서. 뒤로·앞으로는 기록의 지금 항목(진행 중 기록 이동이 있으면 그 대상 — `blocking.historyAt` 과 같다) ± 1 의 주소 — 그 방향에 항목이
/// 없으면 모름(이동이 없다). 몸짓 없이 생긴 항목을 Chromium 이 건너뛰는 개입은 CEF 가 알리지 않는다(남는 틈 — 공격 A3). 새로고침은 게이트하지 않는다
/// (사이트 안 문서 — 밖으로 리다이렉트하면 그 홉이 지운다).
fn targetOf(reg: *const registry_mod.Entry, step: emu_plan.GateStep, url: []const u8) Target {
    var t: Target = .{};
    switch (step.action) {
        .reload => return t,
        .navigate => {
            if (!emu_plan.docChanging(url)) return t;
            // 호스트는 권한(authority) 안에만 있다 — 앞부분을 바이트 그대로 UTF-16 으로(ASCII 가 아니면 호스트를 못 읽어 밖: 더 지우는 쪽). `\` 는
            // Chromium(GURL)처럼 `/` 로 읽는다 — `http://밖\@안/` 을 사용자 정보 너머의 「안」 으로 읽어 게이트를 건너뛰었다(게이트 적대 검증 2026-11-14 — Chromium
            // 은 밖으로 갔다).
            var wide: [2048]u16 = undefined;
            const n = @min(url.len, wide.len);
            for (url[0..n], wide[0..n]) |ch, *w| w.* = if (ch == '\\') '/' else ch;
            t.host_len = protocol.net_policy.hostOfUrl16(wide[0..n], &t.host_buf).len;
            t.canon = table_mod.canonHash(u8, url);
            t.known = true;
        },
        .back, .forward, .menu_back, .menu_forward => {
            const step_dir: i64 = if (step.action == .back or step.action == .menu_back) -1 else 1;
            const cur = readHistory(reg) orelse return t;
            const next = @as(i64, @intCast(cur)) + step_dir;
            if (next < 0 or next >= max_hist or !hist_seen[@intCast(next)]) return t;
            const i: usize = @intCast(next);
            @memcpy(t.host_buf[0..hist_lens[i]], hist_hosts[i][0..hist_lens[i]]);
            t.host_len = hist_lens[i];
            t.canon = hist_canon[i];
            t.known = true;
        },
    }
    return t;
}

/// 그 탭의 기록 항목을 `hist_*` 에 읽는다 — 지금 항목의 번호(진행 중 기록 이동이 있으면 그 대상 — Chromium 의 `GetCurrentEntryIndex`), 모르면 null.
fn readHistory(reg: *const registry_mod.Entry) ?usize {
    if (!hist_ready) {
        hist_visitor = object.zeroed(c.cef_navigation_entry_visitor_t);
        object.staticRefCounted(&hist_visitor.base);
        hist_visitor.visit = &visitHist;
        hist_ready = true;
    }
    const b = browserOf(reg);
    const host = b.*.get_host.?(b);
    if (host == null) return null;
    defer object.release(host);
    hist_seen = @splat(false);
    hist_current = null;
    host.*.get_navigation_entries.?(host, &hist_visitor, 0);
    return hist_current;
}

/// 다른 주 프레임 이동이 진행 중인가(진짜 홉을 봤고 커밋·끊김·오류가 아직 — 가상 홉은 셈하지 않는다).
fn navInProgress(e: *const Entry) bool {
    return e.hop_known and !e.gate_pseudo;
}

/// 그 탭의 게이트 지움 가운데 답을 기다리는 수(칸을 훑어 센다 — 같은 종류의 새 명령이 칸을 지우면 그 종류는 새 명령이 대신한다).
fn gateLeft(cef_id: c_int) u32 {
    var n: u32 = 0;
    for (pending_ids) |p| {
        if (p.id != 0 and p.clear and p.cef_id == cef_id) n += 1;
    }
    return n;
}

fn dropClears(cef_id: c_int) void {
    for (&pending_ids) |*p| if (p.id != 0 and p.clear and p.cef_id == cef_id) {
        p.* = .{};
    };
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn nowUs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

var gate_task: c.cef_task_t = undefined;
var gate_task_ready = false;
/// 걸어 둔 늦은 task 의 가장 이른 때(더 이른 때가 필요하면 하나 더 건다 — task 는 몇 번 돌아도 같다).
var gate_timer_due: i64 = std.math.maxInt(i64);

/// 게이트 task 를 `delay_ms` 뒤에(0 = 곧 — 답·끊김·진행 중 이동이 왔다) 건다. 모든 탭의 마감·답·안전망을 한 번에 본다.
fn postGate(delay_ms: i64) void {
    if (!gate_task_ready) {
        gate_task = object.zeroed(c.cef_task_t);
        object.staticRefCounted(&gate_task.base);
        gate_task.execute = &gateSweep;
        gate_task_ready = true;
    }
    const due = nowMs() + delay_ms;
    if (delay_ms > 0 and due >= gate_timer_due) return;
    if (browsers.state.api.post_delayed_task(c.TID_UI, &gate_task, delay_ms) != 0 and delay_ms > 0) gate_timer_due = due;
}

fn gateSweep(_: [*c]c.cef_task_t) callconv(.c) void {
    gate_timer_due = std.math.maxInt(i64);
    const now = nowMs();
    var next: i64 = std.math.maxInt(i64);
    for (&entries) |*slot| if (slot.*) |*e| {
        if (e.gate.active) {
            const why: ?[]const u8 = if (gateLeft(e.cef_id) == 0)
                (if (e.gate_replies >= e.gate_clears) "replies" else "gone")
            else if (navInProgress(e))
                "in_progress"
            else if (e.gate.due(now))
                "timeout"
            else
                null;
            if (why) |w| openGate(e, w) else next = @min(next, e.gate.deadline_ms);
        }
        if (e.gate_pseudo and e.gate_opened_ms != 0 and e.gate_dialog == 0) {
            const at = e.gate_opened_ms + emu_plan.gate_safety_ms;
            if (now >= at) restorePseudo(e, "safety") else next = @min(next, at);
        }
    };
    if (next != std.math.maxInt(i64)) postGate(@max(1, next - now));
}

/// 줄에 하나를 더한다(주소면 사본을 쥔다). 쥐지 못하면 거짓 — 줄이 찼으면 지금 줄을 곧 열고(차례 그대로), 부른 쪽이 이것을 곧 낸다.
fn enqueue(e: *Entry, step: emu_plan.GateStep, url: []const u8) bool {
    if (step.action == .navigate) {
        const copy = std.heap.c_allocator.dupe(u8, url) catch {
            openGate(e, "full");
            return false;
        };
        if (e.gate_url) |old| std.heap.c_allocator.free(old);
        e.gate_url = copy;
    }
    switch (e.gate.push(step)) {
        .queued => {},
        .full => {
            openGate(e, "full");
            return false;
        },
    }
    if (logOn() and e.gate.len > 1) std.debug.print("emu: gate b={d} queue {s}\n", .{ e.browser, @tagName(step.action) });
    return true;
}

/// 대상의 호스트로 가상 홉을 적고 지움을 낸다(그 지움만 답을 쫓는다). 답을 기다리는 지움 수.
fn armGate(e: *Entry, reg: *const registry_mod.Entry, t: *const Target) u32 {
    @memcpy(e.hop_host[0..t.host_len], t.host_buf[0..t.host_len]);
    e.hop_len = t.host_len;
    e.hop_known = true;
    e.hop_canon = t.canon;
    e.gate_pseudo = true;
    e.gate_opened_ms = 0;
    e.gate_dialog = 0;
    var sb: [msg.max_net_host_bytes]u8 = undefined;
    _ = e.tab.hop(t.host(), topHost(browserOf(reg), &sb));
    syncInject(e);
    gate_arming = true;
    run(e, reg);
    gate_arming = false;
    sendState(e, false);
    e.gate_clears = gateLeft(e.cef_id);
    e.gate_replies = 0;
    e.gate_t0_us = nowUs();
    return e.gate_clears;
}

/// maru 가 시작한 이동 하나(`browsers.navigate`·`navAction` 의 뒤로·앞으로·새로고침, `context_menu.onCommand` 의 뒤로·앞으로) — 게이트가 붙잡았으면
/// 참(부른 쪽은 내지 않는다 — 게이트가 연 뒤 같은 길로 낸다). 기다리는 줄이 있으면 차례를 지켜 뒤에 붙인다. 흉내가 걸린 사이트 안 문서가 아니면
/// 기록 항목도 읽지 않고 곧 거짓(0 지연).
pub fn gateNav(reg: *const registry_mod.Entry, step: emu_plan.GateStep, url: []const u8) bool {
    const e = entryOf(reg.cef_id) orelse return false;
    if (e.gate.active) return enqueue(e, step, url);
    if (step.action == .reload or reg.closing) return false;
    const w = e.tab.wanted() orelse return false;
    if (!w.flags.site_bound or !e.tab.on_site or e.tab.hold or !e.tab.alive) return false;
    const t = targetOf(reg, step, url);
    if (!t.known) return false;
    const in_progress = navInProgress(e);
    if (!e.tab.gateWanted(t.host(), in_progress)) {
        if (in_progress and logOn() and e.tab.gateWanted(t.host(), false)) std.debug.print("emu: nogate b={d} in_progress {s}\n", .{ e.browser, @tagName(step.action) });
        return false;
    }
    e.gate.start(nowMs());
    if (!enqueue(e, step, url)) {
        e.gate = .{};
        return false;
    }
    const n = armGate(e, reg, &t);
    if (logOn()) std.debug.print("emu: gate b={d} hold {s} clears={d} host={s}\n", .{ e.browser, @tagName(step.action), n, t.host() orelse "-" });
    if (n == 0) openGate(e, "replies") else postGate(emu_plan.gate_deadline_ms);
    return true;
}

/// 줄을 연다 — 행동마다 그 직전에 게이트를 다시 본다(그 사이 다시 걸렸으면 — 페이지가 사이트 안으로 커밋 등 — 남은 줄로 다시 기다린다, 마감은 처음
/// 것). 닫히는 탭·종료 중이면 버린다(이동 없음).
fn openGate(e: *Entry, why: []const u8) void {
    var buf: [emu_plan.Gate.capacity]emu_plan.GateStep = undefined;
    const deadline = e.gate.deadline_ms;
    const steps = e.gate.take(&buf);
    dropClears(e.cef_id);
    const url = e.gate_url;
    e.gate_url = null;
    var owned = url; // 다시 기다리면 줄이 도로 쥔다
    defer if (owned) |u| std.heap.c_allocator.free(u);
    if (logOn()) std.debug.print("emu: gate b={d} open {s} replies={d}/{d} after={d}us\n", .{ e.browser, why, e.gate_replies, e.gate_clears, nowUs() -| e.gate_t0_us });
    const reg = browsers.state.registry.byCefId(e.cef_id) orelse return;
    if (reg.closing or browsers.state.shutting_down) return;
    // 기록 이동(뒤로·앞으로)만 냈는데 Chromium 이 아무 이동도 시작하지 않았는지 보려고 첫 기록 이동 앞의 지금 항목을 적는다.
    var hist_before: ?usize = null;
    var hist_read = false;
    var other = false;
    for (steps, 0..) |step, i| {
        if (!std.mem.eql(u8, why, "full") and nowMs() < deadline) {
            const t = targetOf(reg, step, url orelse "");
            if (t.known and e.tab.gateWanted(t.host(), navInProgress(e))) {
                e.gate.restart(deadline, steps[i..]);
                e.gate_url = url;
                owned = null;
                const n = armGate(e, reg, &t);
                if (logOn()) std.debug.print("emu: gate b={d} hold {s} clears={d} again\n", .{ e.browser, @tagName(step.action), n });
                if (n == 0) return openGate(e, "replies"); // 다시 낼 지움이 없다 — 마감 안에서 같은 상태라 다시 걸리지 않는다
                postGate(@max(1, deadline - nowMs()));
                return;
            }
        }
        switch (step.action) {
            .back, .forward, .menu_back, .menu_forward => if (!hist_read) {
                hist_read = true;
                hist_before = readHistory(reg);
            },
            .navigate, .reload => other = true,
        }
        startStep(reg, step, url orelse "");
    }
    if (e.gate_pseudo) {
        // 기록 이동만 냈는데 지금 항목이 그대로다 — Chromium 이 이동을 시작하지 않았다(옆 항목이 몸짓 없이 생긴 것뿐이라 건너뛴 뒤로·앞으로: CEF 의
        // `can_go_back` 은 그래도 참이다 — 게이트 적대 검증 2026-11-14, 안전망 1 초 동안 사이트 안 문서의 흉내가 지워져 있었다). 곧 되돌린다. 떠나기
        // 확인을 기다리는 이동은 그 대상이 지금 항목이라(진행 중 기록 이동) 여기 걸리지 않는다.
        if (!other) if (hist_before) |before| if (readHistory(reg) == before) return restorePseudo(e, "none");
        e.gate_opened_ms = nowMs();
        postGate(emu_plan.gate_safety_ms);
    }
}

fn startStep(reg: *const registry_mod.Entry, step: emu_plan.GateStep, url: []const u8) void {
    switch (step.action) {
        .navigate => browsers.startNavigate(reg, url, step.user),
        .back => browsers.startNavAction(reg, .back, step.user),
        .forward => browsers.startNavAction(reg, .forward, step.user),
        .reload => browsers.startNavAction(reg, .reload, step.user),
        // CEF 의 메뉴 명령(`MENU_ID_BACK`·`FORWARD`)이 하는 일과 같다 — 막기 토큰 없이(지금과 같다).
        .menu_back, .menu_forward => {
            const b = browserOf(reg);
            if (step.action == .menu_back) b.*.go_back.?(b) else b.*.go_forward.?(b);
        },
    }
}

/// 가상 홉이 진짜 홉·커밋·끊김·오류 페이지로 끝났다(안전망도 끝).
fn endPseudo(e: *Entry) void {
    e.gate_pseudo = false;
    e.gate_opened_ms = 0;
    e.gate_dialog = 0;
}

/// 이동이 일어나지 않았다 — 가상 홉을 거두고 지금 문서로 사이트 안팎을 다시 정해 다시 건다.
fn restorePseudo(e: *Entry, why: []const u8) void {
    if (!e.gate_pseudo) return;
    endPseudo(e);
    e.hop_known = false;
    const reg = browsers.state.registry.byCefId(e.cef_id) orelse return;
    if (reg.closing) return;
    var hb: [msg.max_net_host_bytes]u8 = undefined;
    const changed = e.tab.navigate(topHost(browserOf(reg), &hb));
    if (logOn()) std.debug.print("emu: gate b={d} restore {s} on_site={}\n", .{ e.browser, why, e.tab.on_site });
    if (!changed) return;
    run(e, reg);
    sendState(e, false);
}

/// 멈춤(`nav_action stop`) — 기다리는 줄을 버리고(이동 없음) 가상 홉을 되돌린다. 부른 쪽이 그 뒤 `stop_load` 를 낸다.
pub fn gateStop(reg: *const registry_mod.Entry) void {
    const e = entryOf(reg.cef_id) orelse return;
    if (e.gate.active) {
        var buf: [emu_plan.Gate.capacity]emu_plan.GateStep = undefined;
        const steps = e.gate.take(&buf);
        dropClears(e.cef_id);
        if (e.gate_url) |u| std.heap.c_allocator.free(u);
        e.gate_url = null;
        if (logOn()) std.debug.print("emu: gate b={d} cancel stop steps={d}\n", .{ e.browser, steps.len });
    }
    restorePseudo(e, "stop");
}

/// 가상 홉 동안 떠나기 확인이 떴다(`dialogs.ask`) — 답할 때까지 안전망을 멈춘다. 그동안 흉내는 이미 지운 채다(사용자 결정 2026-11-14 — 머무르기면 다시 건다).
pub fn beforeUnloadShown(id: BrowserId, request: u32) void {
    const e = entryById(id) orelse return;
    if (e.gate_pseudo) e.gate_dialog = request;
}

/// 대화상자에 답이 왔다 — 가상 홉의 떠나기 확인이면 머무르기는 되돌리고, 떠나기는 이동이 시작되기를 다시 기다린다(안전망을 새로).
pub fn dialogAnswered(id: BrowserId, request: u32, accept: bool) void {
    const e = entryById(id) orelse return;
    if (e.gate_dialog == 0 or e.gate_dialog != request) return;
    e.gate_dialog = 0;
    if (!accept) return restorePseudo(e, "stay");
    e.gate_opened_ms = nowMs();
    postGate(emu_plan.gate_safety_ms);
}

/// 그 탭의 대화상자가 답 없이 치워졌다(maru 의 새 이동이 취소로 답함·상태 비우기·렌더러 죽음) — 가상 홉의 떠나기 확인이었으면 그 이동은 시작되지 않았다.
pub fn dialogsDropped(id: BrowserId) void {
    const e = entryById(id) orelse return;
    if (e.gate_dialog == 0) return;
    e.gate_dialog = 0;
    restorePseudo(e, "dropped");
}
