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
//! - **화면은 pane 에 맞춰 줄인다**(사용자 결정 Q3 — `scale`): pane 크기가 바뀌면 다시 셈해 다시 낸다(E2).
//! - **위치는 W5b2 와 한 칸**(사용자 결정 Q2): `permissions.zig` 가 건다 — 그 탭의 위치만 묻는 프롬프트에는 묻지 않고 허용, 대신 허용한 출처는
//!   흉내가 끝나면 되돌린다.
//! - 답(`emulation_state`)은 낸 호출의 답이 다 오면, 아무것도 내지 않았으면 곧, 살아 있음·사이트 안팎·줄임·대신 허용한 출처가 바뀌면.
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

    fn hop(self: *const Entry) ?[]const u8 {
        return if (self.hop_len == 0) null else self.hop_host[0..self.hop_len];
    }
};

var entries: [registry_mod.capacity]?Entry = @splat(null);
var observer: c.cef_dev_tools_message_observer_t = undefined;
var observer_ready = false;
var next_id: i32 = emu_plan.id_base;
/// 답을 기다리는 흉내 호출(탭 32 × 종류 7 이면 224 — 넘치면 답을 기다리지 않고 「모름」 으로 둔다).
var pending_ids: [256]struct { id: i32 = 0, cef_id: c_int = 0, kind: emu_plan.Kind = .metrics } = @splat(.{});

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
        if (cmd.kind == .geo) {
            if (cmd.set) {
                if (!permissions.agentGeolocation(e.browser, browserOf(reg), cmd.geo.unavailable, cmd.geo.latitude, cmd.geo.longitude, cmd.geo.accuracy)) e.tab.sendFailed(.geo);
            } else permissions.agentEnd(e.browser, browserOf(reg));
            if (logOn()) std.debug.print("emu: geo b={d} set={} unavailable={}\n", .{ e.browser, cmd.set, cmd.geo.unavailable });
            continue;
        }
        sendCmd(e, reg, cmd);
    }
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
    if (cmd.set) {
        for (&pending_ids) |*p| if (p.id == 0) {
            p.* = .{ .id = id, .cef_id = e.cef_id, .kind = cmd.kind };
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
        p.* = .{};
        const e = entryOf(cef_id) orelse return;
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
}

// ── CEF 사건 ───────────────────────────────────────────────────────────────────────────────────────────

/// 주 프레임 `on_before_browse`(홉마다) — 사이트에 묶인 탭이 사이트 안팎을 오가면 걸거나 지운다(그 이동에 듣는다 — 실측 E12).
pub fn beforeBrowse(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t) void {
    if (browser == null or frame == null or request == null) return;
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
    var sb: [msg.max_net_host_bytes]u8 = undefined;
    const changed = e.tab.hop(if (host.len == 0) null else host, topHost(browser, &sb));
    syncInject(e); // 안→안 리다이렉트도(새 홉의 주소로), 안→밖 홉은 거둔다 — 그 홉의 요청보다 먼저(IO 스레드는 이 뒤에 그 요청을 본다)
    if (!changed) return;
    if (logOn()) std.debug.print("emu: site b={d} host={s} on_site={} hold={}\n", .{ e.browser, host, e.tab.on_site, e.tab.hold });
    run(e, reg);
    sendState(e, false);
}

/// 주 프레임 `on_load_start` — 새 문서가 섰다(커밋): 사이트 안으로 가는 홉이 커밋까지 미룬 무리(`hold`)와 렌더러가 죽은 동안 쌓인 차이를 낸다.
pub fn loadStart(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t) void {
    if (browser == null or frame == null or frame.*.is_main.?(frame) == 0) return;
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
        e.* = null;
    };
}

// ── 상태 ─────────────────────────────────────────────────────────────────────────────────────────────────

fn sendState(e: *Entry, force: bool) void {
    // 흉내를 받은 적 없는 탭(홉·렌더러만 적은 자리)은 알리지 않는다.
    if (e.tab.wanted() == null and !e.auto_dirty and !force) return;
    var st = e.tab.state(e.browser);
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
        a.active_mask == b.active_mask and a.failed_mask == b.failed_mask and a.reason == b.reason;
}
