//! 요청 막기(W9d③ — docs/plans/web-osr-backend.md 「W9d③ 결정·실측」). maru 의 `net_block` 을 받아 탭마다 규칙 묶음(`net_block_table`)과 엄격
//! 모드(`net_domain` — 그 탭의 CDP Network 도메인 주인)를 두고, IO 스레드의 처리기 고르기(`network.zig`)가 묻는 두 길을 답한다:
//!   - **탭 길**(`tabSelect`): 요청 번호·지켜보기·문보다 **먼저**(speculation prefetch·prerender 는 번호 0 으로 온다 — 실측 J-B11) 그 탭의 규칙에
//!     맞춘다. 맞으면 막는 처리기(`set_error(ERR_BLOCKED_BY_CLIENT)` — 실측 J-B1: RV_CANCEL 은 주 프레임 이동을 말없이 버리고 XHR 을 영영 붙잡았다,
//!     `open→0` 은 거짓 안내 「사이트에 연결할 수 없음」). 맞추기는 처리기 고르기 때(홉마다 — J-B2), 처리기는 맞을 때만(늘 돌려주면 +40 % — J-B7).
//!   - **서비스 워커 길**(`serviceWorkerSelect` — 공유 context 처리기, 브라우저가 없는 요청: 서비스 워커와 공유 워커의 요청 — CEF 는 둘을 가르지
//!     않는다, 옮긴 판 재검증 SEVERE-1 사용자 결정 A 2026-11-11): 그 출처를 보이는 살아 있는 탭 **모두**가 맞는 규칙을
//!     쥘 때만 막는다(사용자 결정 D3(a) — `sw_share`). 탭들은 IO 스레드에서 CEF 프레임 API 로 나열한다(실측 7–22 µs) — (출처, 위상 세대)로 캐시.
//! 엄격 모드(D3(b) — 탭마다 선택): 그 탭에 `Network.enable{0,0,1}` + `Network.setBypassServiceWorker` — 서비스 워커를 지나지 않아 요청이 탭 길로 와
//! 막을 수 있다(실측 D3(ii)). 규칙처럼 사이트에 묶는다 — 주 프레임 `on_before_browse` 에서 바라는 값이 바뀌면 보낸다(그 이동에 듣는다 — 실측
//! latch). W9d② 의 본문 기록과 Network 도메인을 나누므로 켜고 끄기는 `net_domain` 이 정한다(끔은 `bypass:false` 먼저 — sw2). W9d④ 의 가짜도
//! 엄격을 켤 수 있다 — 도메인은 하나라 바람은 「막기 엄격 사이트 또는 가짜 엄격 사이트가 그 호스트를 덮는다」 이고(`syncStrict`), 상태는 각자 제
//! 엄격 사이트가 있을 때만 알린다(`blockStrictState`·`mockStrictState`). 처리기 고르기의 예외 답(D2·Q2)은 `navExempt` 가 한 번 낸다.
//!
//! 스레드: 표·캐시는 이 파일의 뮤텍스 아래(IO 스레드와 UI 스레드). CEF 브라우저 목록은 따로 잠근다(나열은 참조를 잡아 잠금 밖에서). 엄격 모드·
//! 관찰자 등록은 UI 스레드만. IO 스레드에서는 쓰지도 로그하지도 않는다(W9d① M6) — 수는 원자로 올리고 `network.zig` 의 보내는 task 가 모아 보낸다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");
const table_mod = @import("net_block_table.zig");
const sw_share = @import("sw_share.zig");
const net_domain = @import("net_domain.zig");
const nav_exempt = @import("nav_exempt.zig"); // W9d④: 사람의 누름(Q2) — 가짜만
const mocking = @import("mocking.zig"); // W9d④: 가짜의 엄격 상태를 알린다(엄격의 CDP 는 하나)

const msg = protocol.message;
const nb = protocol.net_block;
const net_policy = protocol.net_policy;
const BrowserId = msg.BrowserId;
const gpa = std.heap.c_allocator;

/// Chromium `net::ERR_BLOCKED_BY_CLIENT`.
pub const err_blocked_by_client: c_int = -20;
/// 엄격 모드의 CDP 번호 대역 — 다른 사용처와 겹치지 않는다(권한·알림 수만 번대, 본문 [1<<28, 1<<29), DevTools [1<<29, 1<<30), 미디어 [1<<30, ..)).
/// 계획 v2 §6.4 는 [1<<29, ..) 라 적었지만 그 자리는 `devtools_table` 의 대역이다(실측 — 코드).
pub const strict_id_base: i32 = 1 << 27;
pub const strict_id_end: i32 = (1 << 27) + (1 << 20);

var lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var table: table_mod.Table = .{};
var sw_cache: sw_share.Cache = .{};
/// 규칙이 있는 탭이 하나라도 있다(`block_any`) — 처리기 고르기의 가장 흔한 길은 이것만 본다.
var any_rules = std.atomic.Value(bool).init(false);
/// 위상 세대 — 프레임 주소·진행 중 이동이 바뀔 수 있는 UI 사건마다 오른다(서비스 워커 길의 나열 캐시).
var topology = std.atomic.Value(u64).init(1);

var blist_lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
/// CEF 브라우저 모두(`on_after_created` ~ `on_before_close` — registry 가 아니다: 입양 전 팝업도 그 출처를 보일 수 있다, §12 P1-4). 참조 하나씩 쥔다.
var blist: [sw_share.max_browsers][*c]c.cef_browser_t = @splat(null);
/// 목록이 차서 담지 못한 브라우저들의 CEF 번호(20 회 검증 A N3: 33 번째 브라우저 — registry 32 + 입양 전 팝업 — 가 말없이 빠져 T(O) 에서
/// 사라졌다). 하나라도 있으면 서비스 워커 길은 「모르는 탭」 하나를 더한다(거부권 — `sw_not_applied` 로 세어진다). 닫히면 뺀다.
var blist_extra: [sw_share.max_browsers]c_int = @splat(0);
var blist_missing: usize = 0;

fn doLock() void {
    _ = std.c.pthread_mutex_lock(&lock);
}
fn doUnlock() void {
    _ = std.c.pthread_mutex_unlock(&lock);
}

fn api() *const library.Api {
    return browsers.state.api;
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn units(value: [*c]const c.cef_string_t) []const u16 {
    if (value == null or value.*.str == null) return &.{};
    return @ptrCast(value.*.str[0..value.*.length]);
}

fn bumpTopology() void {
    _ = topology.fetchAdd(1, .monotonic);
}

/// 규칙이 있는 탭이 있는가(IO 스레드 — 값싸게).
pub fn anyRules() bool {
    return any_rules.load(.acquire);
}

fn refreshAny() void {
    any_rules.store(table.with_rules > 0, .release);
}

// ── 막는 처리기(정적 — 상태 없음) ─────────────────────────────────────────────────────────────────────────

var block_handler: c.cef_resource_handler_t = undefined;
/// 기록하지 않는 탭·문을 지나지 못한 요청의 막는 처리기 고르기(자원 처리기만 — 기록 콜백 없음).
pub var block_only: c.cef_resource_request_handler_t = undefined;
var ready = false;

pub fn init() void {
    if (ready) return;
    ready = true;
    block_handler = object.zeroed(c.cef_resource_handler_t);
    object.staticRefCounted(&block_handler.base);
    block_handler.open = &hOpen;
    block_handler.get_response_headers = &hHeaders;
    block_handler.read = &hRead;
    block_handler.skip = &hSkip;
    block_handler.cancel = &hCancel;
    block_only = object.zeroed(c.cef_resource_request_handler_t);
    object.staticRefCounted(&block_only.base);
    block_only.get_resource_handler = &getBlockHandler;
    observer = object.zeroed(c.cef_dev_tools_message_observer_t);
    object.staticRefCounted(&observer.base);
    observer.on_dev_tools_method_result = &onResult;
    observer.on_dev_tools_agent_detached = &onDetached;
    resync_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&resync_task.base);
    resync_task.execute = &runResyncs;
}

/// 기록하는 처리기(`network.zig` 의 rrh)에 다는 자원 처리기 고르기 — 막는 처리기를 준다.
pub fn getBlockHandler(_: [*c]c.cef_resource_request_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t) callconv(.c) [*c]c.cef_resource_handler_t {
    object.releaseArg(browser);
    object.releaseArg(frame);
    object.releaseArg(request);
    return &block_handler;
}

fn hOpen(_: [*c]c.cef_resource_handler_t, request: [*c]c.cef_request_t, handle_request: [*c]c_int, callback: [*c]c.cef_callback_t) callconv(.c) c_int {
    object.releaseArg(request);
    object.releaseArg(callback);
    handle_request.* = 1; // 곧바로 답한다(응답 머리에서 오류를 세운다)
    return 1;
}

fn hHeaders(_: [*c]c.cef_resource_handler_t, response: [*c]c.cef_response_t, length: [*c]i64, _: [*c]c.cef_string_t) callconv(.c) void {
    defer object.releaseArg(response);
    if (response != null) response.*.set_error.?(response, err_blocked_by_client);
    length.* = 0;
}

fn hRead(_: [*c]c.cef_resource_handler_t, _: ?*anyopaque, _: c_int, bytes_read: [*c]c_int, callback: [*c]c.cef_resource_read_callback_t) callconv(.c) c_int {
    object.releaseArg(callback);
    bytes_read.* = 0;
    return 0;
}

fn hSkip(_: [*c]c.cef_resource_handler_t, _: i64, skipped: [*c]i64, callback: [*c]c.cef_resource_skip_callback_t) callconv(.c) c_int {
    object.releaseArg(callback);
    skipped.* = -2;
    return 0;
}

fn hCancel(_: [*c]c.cef_resource_handler_t) callconv(.c) void {}

// ── IO 스레드: 탭 길 ───────────────────────────────────────────────────────────────────────────────────────

/// 탭 길의 답 — 막을 규칙(0 = 막지 않는다)과 그 규칙 묶음의 세대(기록 없이 막은 수를 그 세대로 센다 — 3 차 검증 NEW-B3-1).
pub const TabHit = struct { rule: u32 = 0, generation: u32 = 0 };

pub fn tabSelect(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, is_navigation: c_int) TabHit {
    if (!anyRules()) return .{};
    const cef_id = browser.*.get_identifier.?(browser);
    const main_nav = is_navigation != 0 and frame != null and frame.*.is_main.?(frame) != 0;
    const raw = request.*.get_url.?(request);
    defer if (raw != null) api().string_userfree_utf16_free(raw);
    const url = units(raw);
    if (url.len == 0) return .{};
    var rt: u8 = @intCast(@min(@as(c_uint, @intCast(request.*.get_resource_type.?(request))), msg.max_net_resource_type));
    if (rt == 18) rt = 6; // `network.zig` 와 같은 바꾸기
    const id = request.*.get_identifier.?(request);
    // 하위 프레임 이동도 주소를 잰다 — 막으면 그 프레임의 다음 문서(오류 페이지)를 알아본다(3 차 검증 MED-A3-1).
    const sub_nav = is_navigation != 0 and !main_nav;
    const canon = if (main_nav or sub_nav) table_mod.canonHash(u16, url) else 0;
    doLock();
    var a = table.acquire(cef_id, id, main_nav, canon, nowMs()) orelse {
        doUnlock();
        return .{};
    };
    doUnlock();
    // 페이지 호스트(W9d① F2 — `net_policy.pageHost`): 쿠키의 첫 사이트와 탭의 맨 위 호스트(떠난 문서의 비콘은 옛 사이트로 — J-B9).
    var sb: [msg.max_net_host_bytes]u8 = undefined;
    const site = if (main_nav) "" else blk: {
        const fp = request.*.get_first_party_for_cookies.?(request);
        defer if (fp != null) api().string_userfree_utf16_free(fp);
        break :blk table_mod.urlHost(u16, units(fp), &sb);
    };
    const page = if (main_nav) "" else net_policy.pageHost(site, a.topHost());
    const verdict = table_mod.decideTab(&a, url, rt, main_nav, page);
    doLock();
    table.releaseNav(cef_id, &a, verdict, main_nav, sub_nav, canon);
    doUnlock();
    return switch (verdict) {
        .block => |r| .{ .rule = r, .generation = a.set.generation },
        else => .{},
    };
}

/// W9d④: 처리기 고르기의 예외 답 — 주 프레임 이동의 요청만 묻는다. D2(사용자 이동)는 막기 표의 토큰이 답하고(이 탭에 막기 규칙이 없어도
/// 소비한다 — §13 P2-1, `net_block_table.consumeExempt`), Q2(사람의 누름)는 공용 표(`nav_exempt`)가 답한다. 처리기 고르기에서 한 번 부르고 그 답을
/// 가짜가 쓴다(막기의 `tabSelect` 는 같은 번호로 다시 물어 같은 답을 얻는다).
pub fn navExempt(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, is_navigation: c_int) nav_exempt.Exempt {
    if (is_navigation == 0 or frame == null or frame.*.is_main.?(frame) == 0) return .{};
    const raw = request.*.get_url.?(request);
    defer if (raw != null) api().string_userfree_utf16_free(raw);
    const canon = table_mod.canonHash(u16, units(raw));
    const cef_id = browser.*.get_identifier.?(browser);
    const id = request.*.get_identifier.?(request);
    const now = nowMs();
    doLock();
    const user = table.consumeExempt(cef_id, id, true, canon, now);
    doUnlock();
    const ex = nav_exempt.shared.acquire();
    const human = ex.consume(cef_id, id, canon, now);
    nav_exempt.shared.release();
    return .{ .user = user, .human = human and !user };
}

/// 문을 지나지 못해(또는 번호 0 이라) 기록 없이 막았다 — 막은 묶음의 세대로 센다.
pub fn noteUnrecorded(cef_id: c_int, generation: u32) void {
    doLock();
    table.noteUnrecorded(cef_id, generation);
    doUnlock();
}

/// 서비스 워커 길에서 기록 없이 막았다 — 막은 규칙을 쥔 탭마다 그 규칙 묶음의 세대로 센다.
pub fn noteUnrecordedTargets(r: *const SwResult) void {
    doLock();
    for (r.targets[0..r.count]) |t| if (table.find(t.browser)) |tab| {
        tab.countsFor(t.generation).unrecorded +|= 1;
    };
    doUnlock();
}

// ── IO 스레드: 서비스 워커 길 ──────────────────────────────────────────────────────────────────────────────

pub const SwTarget = struct { browser: BrowserId, rule: u32, generation: u32 = 0 };

pub const SwResult = struct {
    outcome: sw_share.Outcome = .pass,
    /// 맞는 규칙을 쥔 탭(maru 번호)과 그 규칙 — 막았으면 막은 규칙, 아니면 「적용 안 됨」 의 규칙.
    targets: [sw_share.max_browsers]SwTarget = undefined,
    count: usize = 0,

    pub fn ruleOf(self: *const SwResult, browser: BrowserId) u32 {
        for (self.targets[0..self.count]) |t| if (t.browser == browser) return t.rule;
        return 0;
    }
};

/// 서비스 워커 길의 답(§6.2). `origin` 은 initiator 출처(앞부분만 읽었다 — 비었거나 잘렸으면 부른 쪽이 부르지 않는다).
/// 4 차 검증 B-LOW-4: 전에는 그 출처를 보이는 탭을 가리기 **전에** 모든 탭의 모든 규칙을 주소에 맞췄고(거르기), 몫을 쥔 탭의 규칙은 막기의 잠금
/// 아래에서 다시 맞췄다 — 별 많은 규칙과 긴 주소가 브라우저가 함께 쓰는 IO 스레드를(그리고 잠금을) 붙잡았다. 이제 T(O) 를 먼저 가리고, 몫을 쥔
/// 탭의 규칙만 잠금 밖에서 요청 하나의 예산(`nb.Budget` — 넘으면 막는 쪽)으로 맞춘다.
pub fn serviceWorkerSelect(request: [*c]c.cef_request_t, origin: []const u8) SwResult {
    var out: SwResult = .{};
    if (!anyRules() or origin.len == 0) return out;
    // ① 값싼 거르기 — 종류 없는 규칙을 쥔 탭이 있는가(주소는 맞추지 않는다). 없으면 나열하지 않는다.
    doLock();
    const any_untyped = for (&table.tabs) |*t| {
        if (t.used) if (t.set) |set| if (set.any_untyped) break true;
    } else false;
    doUnlock();
    if (!any_untyped) return out;
    const raw = request.*.get_url.?(request);
    defer if (raw != null) api().string_userfree_utf16_free(raw);
    const url = units(raw);
    const parts = nb.splitUrl(u16, url) orelse return out;

    // ② T(O) — 확정된 프레임 주소(나열, 캐시)와 진행 중 이동.
    const o_hash = table_mod.originHash(origin);
    const membership = membershipFor(origin);
    const canon = table_mod.canonHash(u16, url);
    const now = nowMs();
    // 요청의 쿠키 첫 사이트(호스트) — 진행 중 주 프레임 이동 자체인가를 가른다(`table_mod.swNavItself` — 5 차 검증 LOW: 분할 저장소의 iframe 서비스
    // 워커는 비었다). 읽지 못하면 빈 글(이동 자체로 치지 않는다).
    var fp_buf: [msg.max_net_host_bytes]u8 = undefined;
    const fp_host = blk: {
        const fp = request.*.get_first_party_for_cookies.?(request);
        defer if (fp != null) api().string_userfree_utf16_free(fp);
        break :blk table_mod.urlHost(u16, units(fp), &fp_buf);
    };
    const max_n = sw_share.max_browsers + 1;
    // 몫을 따질 탭 하나 — 잠금 아래에서 모은 사실(잠금 밖에서 규칙을 맞춘다: 묶음은 `readers` 로 잡고 호스트는 베낀다).
    const Cand = struct {
        browser: BrowserId = 0,
        shows: bool = false,
        /// 「보일지도」(오류 페이지 표시를 다 적지 못한 탭의 O 주소 하위 프레임 — 5 차 검증 MED).
        maybe: bool = false,
        unknown: bool = false,
        forgot_nav: bool = false,
        /// 이 요청이 그 탭의 진행 중 주 프레임 이동 자체일 수 있다(§6.3 귀속 — 5 차 검증 LOW: 첫 사이트가 이동이 아님을 보이면 거짓).
        nav_itself: bool = false,
        user_nav: bool = false,
        set: ?*table_mod.RuleSet = null,
        host_bufs: [2][msg.max_net_host_bytes]u8 = undefined,
        host_lens: [2]u8 = .{ 0, 0 },
        host_n: u8 = 0,
        rule: ?*table_mod.Rule = null,
    };
    var cands: [max_n]Cand = undefined;
    var n: usize = 0;
    doLock();
    for (membership.slice()) |mem| {
        var cd: Cand = .{ .shows = mem.shows, .maybe = mem.maybe, .unknown = mem.unknown };
        if (table.findCef(mem.cef_id)) |t| {
            cd.browser = t.browser;
            t.expire(now);
            for (t.pending[0..t.pending_len]) |*p| {
                if (p.origin == o_hash) cd.shows = true;
                if (p.main and p.user and p.url == canon) cd.user_nav = true;
            }
            // 진행 중 이동 표가 넘쳐 잊은 이동이 있다 — 그 이동은 규칙이 잠든 다른 사이트로 가는 중일 수 있어 규칙을 쥐었어도 빠지지 않는다(거부권).
            if (t.unknownPending(now)) {
                cd.unknown = true;
                cd.forgot_nav = true;
            }
            if (cd.shows or cd.maybe or cd.unknown) if (t.set) |set| if (set.any_untyped) {
                set.readers += 1;
                cd.set = set;
                cd.nav_itself = table_mod.swNavItself(t, canon, o_hash, fp_host) != .no;
                var hosts: [2][]const u8 = undefined;
                const hs = table_mod.swHosts(t, canon, o_hash, fp_host, &hosts);
                for (hs, 0..) |h, i| {
                    @memcpy(cd.host_bufs[i][0..h.len], h);
                    cd.host_lens[i] = @intCast(h.len);
                }
                cd.host_n = @intCast(hs.len);
            };
        }
        cands[n] = cd;
        n += 1;
    }
    doUnlock();
    // ③ 몫을 쥔 탭의 규칙만 — 잠금 밖에서, 요청 하나의 예산으로(모든 탭이 함께 쓴다).
    var budget: nb.Budget = .{};
    for (cands[0..n]) |*cd| if (cd.set) |set| {
        var hosts: [2][]const u8 = undefined;
        for (0..cd.host_n) |i| hosts[i] = cd.host_bufs[i][0..cd.host_lens[i]];
        cd.rule = table_mod.serviceWorkerRule(set, parts, hosts[0..cd.host_n], &budget);
    };
    var facts: [max_n]sw_share.TabFacts = undefined;
    var rules: [max_n]?*table_mod.Rule = @splat(null);
    var gens: [max_n]u32 = @splat(0);
    var navs: [max_n]bool = @splat(false);
    var m: usize = 0;
    doLock();
    defer doUnlock();
    for (cands[0..n]) |cd| {
        if (cd.set) |set| set.readers -= 1;
        // 탭의 몫(`sw_share.role` — 2 차 검증 MED-A2-1): O 를 보인다고 증명된 탭만 덮거나 거부하고, 증명되지 않은 모르는 탭은 맞는 규칙을 쥐었으면
        // 빠지고(덮지도 거부하지도 않는다) 아니면 거부권만. 「모름」 은 덮는 데 쓰지 않는다(20 회 검증 A MED-2 는 보이는 탭의 제 iframe 만).
        // 「보일지도」 인 탭은 맞는 규칙을 쥐었을 때만 덮는 몫이고, 아니면 빠진다(거부권 없음) — 어느 쪽이든 막는 쪽(5 차 검증 MED).
        const role = sw_share.role(cd.shows, cd.unknown, cd.rule != null and !cd.forgot_nav, cd.maybe);
        if (role == .skip) continue;
        const rule = if (role == .veto) null else cd.rule; // 거부권 몫은 덮지 않는다
        facts[m] = .{ .browser = cd.browser, .unknown = cd.unknown or cd.browser == 0, .user_nav = cd.user_nav, .rule_id = if (rule) |r| r.id else 0 };
        rules[m] = rule;
        gens[m] = if (cd.set) |set| set.generation else 0;
        navs[m] = cd.nav_itself;
        m += 1;
    }
    // 목록에 담지 못한 브라우저가 있다 — 그 출처를 보이는지 모르는 탭 하나로 친다(거부권 — 세어진다).
    if (membership.overflow) {
        facts[m] = .{ .browser = 0, .unknown = true };
        m += 1;
    }
    out.outcome = sw_share.decide(facts[0..m]);
    // 「적용 안 됨」 은 요청마다 한 번(리다이렉트 홉마다 불린다 — 3 차 검증 N-A3-2).
    const count_na = out.outcome != .not_applied or table.firstNotApplied(request.*.get_identifier.?(request));
    switch (out.outcome) {
        .block, .not_applied => for (facts[0..m], rules[0..m], gens[0..m], navs[0..m]) |f, r, g, nav_itself| if (r) |rule| {
            const t_full = if (table.find(f.browser)) |t| t.full else false;
            // 서비스 워커 길의 수·나눔 표시는 설정이 켜진 탭만 센다(3 차 검증 N-B3-d — 원천에서).
            if (t_full) {
                if (out.outcome == .block) table_mod.bump(&rule.sw_hits) else if (count_na) table_mod.bump(&rule.sw_not_applied);
            }
            if (out.count < out.targets.len) {
                out.targets[out.count] = .{ .browser = f.browser, .rule = rule.id, .generation = g };
                out.count += 1;
            }
            if (out.outcome == .not_applied and t_full) if (table.find(f.browser)) |t| {
                t.countsFor(g).sw_shared = true;
            };
            // §6.3: 막은 요청이 그 탭의 진행 중 주 프레임 이동이면 오류 페이지에 귀속한다(서비스 워커 길의 이동은 -2 로 끝난다). 이동이 아님이 보인
            // 요청은 빼고(5 차 검증 LOW: 옛 문서의 다른 사이트 iframe 이 같은 주소로 낸 요청의 막힘을 그 이동에 귀속해 두었다 — 첫 사이트가 빈 글).
            if (out.outcome == .block and nav_itself) if (table.find(f.browser)) |t| table.noteServiceWorkerMainBlock(t.cef_id, canon, rule.id);
        },
        else => {},
    }
    return out;
}

/// 그 출처를 보이는 브라우저들 — (출처, 위상 세대)로 캐시한다(IO 스레드). W9d④ 의 가짜도 서비스 워커 길의 수를 셀 때 쓴다.
pub fn membershipFor(origin: []const u8) sw_share.Membership {
    const o_hash = table_mod.originHash(origin);
    const gen = topology.load(.acquire);
    doLock();
    const cached = sw_cache.get(o_hash, gen);
    doUnlock();
    return cached orelse blk: {
        const m = enumerate(origin);
        doLock();
        sw_cache.put(o_hash, gen, m);
        doUnlock();
        break :blk m;
    };
}

/// 그 출처를 보이는 브라우저들(IO 스레드 — CEF 프레임 API). 프레임 주소가 비었거나 64 개를 넘으면 그 브라우저는 「모름」. 목록이 넘쳐 담지
/// 못한 브라우저가 있으면 `overflow`(그 브라우저들은 「모름」 하나 — 거부권).
fn enumerate(origin: []const u8) sw_share.Membership {
    var out: sw_share.Membership = .{};
    var copy: [sw_share.max_browsers][*c]c.cef_browser_t = @splat(null);
    {
        _ = std.c.pthread_mutex_lock(&blist_lock);
        defer _ = std.c.pthread_mutex_unlock(&blist_lock);
        for (blist, 0..) |b, i| if (b != null) {
            b.*.base.add_ref.?(&b.*.base);
            copy[i] = b;
        };
        if (blist_missing > 0) out.overflow = true;
    }
    const want = table_mod.originHash(origin);
    for (copy) |b| if (b != null) {
        defer object.release(b);
        var m: sw_share.Member = .{ .cef_id = b.*.get_identifier.?(b) };
        // 오류 페이지를 보이는 하위 프레임 — 주소는 실패한 주소지만 그 출처의 문서가 아니다(3 차 검증 MED-A3-1). 표시를 다 적지 못한 탭의 하위
        // 프레임은 「보일지도」(5 차 검증 MED — `table_mod.ErrSnapshot.view`).
        var errs: table_mod.ErrSnapshot = .{};
        doLock();
        if (table.findCef(m.cef_id)) |t| errs = t.errSnapshot();
        doUnlock();
        const list = api().string_list_alloc();
        if (list == null) {
            m.unknown = true;
            out.add(m);
            continue;
        }
        defer api().string_list_free(list);
        b.*.get_frame_identifiers.?(b, list);
        const count = api().string_list_size(list);
        if (count == 0 or count > sw_share.max_frames) m.unknown = true;
        var i: usize = 0;
        while (i < count and i < sw_share.max_frames) : (i += 1) {
            var s = std.mem.zeroes(c.cef_string_t);
            _ = api().string_list_value(list, i, &s);
            defer api().string_utf16_clear(&s);
            if (errs.isErr(keyOfUnits(units(&s)))) continue;
            const f = b.*.get_frame_by_identifier.?(b, &s);
            if (f == null) {
                m.unknown = true;
                continue;
            }
            defer object.release(f);
            const u = f.*.get_url.?(f);
            defer if (u != null) api().string_userfree_utf16_free(u);
            const fu = units(u);
            if (fu.len == 0) {
                m.unknown = true; // 첫 이동 중인 새 브라우저·새 iframe(실측 D3(i))
                continue;
            }
            switch (errs.view(f.*.is_main.?(f) != 0, table_mod.urlOriginHash(u16, fu) == want)) {
                .shows => m.shows = true,
                .maybe => m.maybe = true,
                .other => {},
            }
        }
        out.add(m);
    };
    return out;
}

// ── UI 스레드: maru 의 명령 ─────────────────────────────────────────────────────────────────────────────

/// 탭마다의 엄격 모드(UI 스레드만).
const Strict = struct {
    cef_id: c_int = 0,
    browser: BrowserId = 0,
    /// 렌더러 쪽 명령 길(`net_domain.Tab`) — 바람(`domain`)·엄격 켬의 답 셈(`batch`)·렌더러의 삶(`life` — 9 차: 죽음을 맞은 명령을 표시하고 그 첫
    /// 답에 다시 맞춘다)·답을 기다리는 명령(10 차: 모든 명령을 짝짓고, 자리는 이 탭의 종류마다 하나).
    tab: net_domain.Tab = .{},
    /// maru 가 보낸 마지막 세대(상태 답이 싣는다).
    generation: u32 = 0,
    /// 다시 맞추기가 걸렸다(`armResync` — 실패 답의 묶음이 끝난 뒤 보낸다).
    resync_armed: bool = false,
    reg: [*c]c.cef_registration_t = null,
    /// 지금 주 프레임 이동이 시작할 때 듣는 우회 값(첫 홉의 `on_before_browse` 가 보낸 값 — 실측 latch: 그 이동에 듣는다). 첫 홉마다 다시 잰다
    /// (엄격이 꺼져 있어도 — 2 차 검증 N-A2-6: 엄격 사이트가 빈 동안 시작한 이동은 앞 이동의 값을 들고 있었다).
    nav_bypass: bool = false,
    /// 그 이동이 시작할 때 엄격이 켜져 있었다 — 리다이렉트 어긋남은 그때만 센다(이동 중에 켠 엄격은 다음 이동부터 — 결과의 안내 그대로).
    nav_strict: bool = false,
    /// 이 이동의 리다이렉트 홉이 엄격 사이트의 경계를 넘었다 — 홉에서 보낸 값은 **다음** 이동부터 듣는다(20 회 검증 A MED-1 — 실측 2/2). 그 이동의
    /// 문서가 서면 한 번 센다(`addressChanged`). 2 차 검증 LOW-A2-2: 셈은 **그 이동의 문서**에 묶인다 — 마지막 홉 주소(`crossed_url`), 새 문서의
    /// 시작(`landing` — `on_load_start`, 같은 문서 이동에는 없다), 끊김(`on_load_error` — ERR_ABORTED 포함: 204·다운로드·멈춤)이 지운다.
    nav_crossed: bool = false,
    crossed_url: u64 = 0,
    landing: bool = false,
    /// 마지막 `net_block` 이 받아들여졌는가(엄격 CDP 의 늦은 답도 이 값으로 상태를 보낸다 — 2 차 검증 N-A2-7: `ok:true` 를 늘 실었다).
    ok: bool = true,
    /// W9d④: 막기 쪽 `net_block` 을 받은 적이 있다(엄격의 CDP 답을 막기 상태로도 알릴지 — 가짜 엄격만 있는 탭은 막기 상태를 보내지 않는다).
    block_seen: bool = false,
    /// W9e②: 네트워크 조건의 바람(`emulation.zig` 가 정한다 — 없으면 null). 답 셈은 `tab`(`net_domain.Tab` 의 `cond_*`).
    cond: ?CondWish = null,

    fn forgetCrossing(self: *Strict) void {
        self.nav_crossed = false;
        self.crossed_url = 0;
        self.landing = false;
    }
};

/// W9e②: 네트워크 조건 — 인자의 해시(0 아님)·오프라인·지연·처리량(kbps, 0 = 제한 없음). ByRule 의 인자는 이것으로 만든다.
pub const CondWish = struct {
    hash: u64,
    offline: bool = false,
    latency_ms: u32 = 0,
    download_kbps: u32 = 0,
    upload_kbps: u32 = 0,
};

pub const CondStatus = net_domain.CondStatus;

var stricts: [registry_mod.capacity]?Strict = @splat(null);
var observer: c.cef_dev_tools_message_observer_t = undefined;
var resync_task: c.cef_task_t = undefined;
var resync_posted = false;
var next_id: i32 = strict_id_base;
// 답을 기다리는 명령의 짝은 탭마다 쥔다(`Strict.tab` — `net_domain.Tab`, UI 스레드만). 10 차 LOW-1: 전에는 모든 탭이 256 자리를 나눠, 죽은 탭 하나가
// 엄격 켬·끔을 쏟으면 다른 탭의 엄격 켬이 거짓 `failed` 가 되고 다른 탭의 죽은 동안 끈 기록이 다시 맞추기를 몰랐다(2/2). 이제 탭마다 종류(도메인·우회)마다
// 한 자리 — 같은 종류의 새 명령이 앞 자리를 덮는다(마지막 명령이 그 값을 정한다).

fn strictOf(cef_id: c_int) ?*Strict {
    for (&stricts) |*s| if (s.*) |*v| if (v.cef_id == cef_id) return v;
    return null;
}

fn strictEnsure(cef_id: c_int, browser: BrowserId) ?*Strict {
    if (strictOf(cef_id)) |s| return s;
    for (&stricts) |*s| if (s.* == null) {
        s.* = .{ .cef_id = cef_id, .browser = browser };
        return &s.*.?;
    };
    return null;
}

fn writer() *@import("events.zig").Writer {
    return browsers.state.writer;
}

/// `net_block`(maru) — 규칙을 통째로 바꾸고 엄격 모드를 맞춘다. 지켜보는 탭이 아니면 받지 않는다(`ok` 거짓 — maru 는 지켜보기를 먼저 보낸다).
pub fn apply(v: msg.NetBlock) void {
    init();
    const entry = browsers.state.registry.byId(v.browser) orelse {
        writer().send(.{ .net_block_state = .{ .browser = v.browser, .generation = v.generation, .ok = false } }) catch {};
        return;
    };
    const watching = @import("network.zig").watching(v.browser);
    var compiled: Compiled = .{ .set = null, .ok = false };
    if (watching) compiled = compile(v);
    doLock();
    var site_moved = false;
    if (table.ensure(v.browser, entry.cef_id)) |t| {
        site_moved = !std.mem.eql(u8, t.strictSite(), if (watching) v.strict_site else "");
        table.swap(gpa, t, compiled.set, if (watching) v.strict_site else "", v.generation) catch {};
    } else if (compiled.set) |s| gpa.destroy(s);
    refreshAny();
    doUnlock();
    bumpTopology();
    const ok = watching and compiled.ok;
    const s = strictEnsure(entry.cef_id, v.browser) orelse {
        writer().send(.{ .net_block_state = .{ .browser = v.browser, .generation = v.generation, .ok = ok } }) catch {};
        return;
    };
    s.generation = v.generation;
    s.ok = ok;
    s.block_seen = true;
    // 엄격 사이트가 바뀌었다 — 걸린 경계 넘기는 옛 사이트로 잰 것이다(3 차 검증 N-B3-b — maru 도 옛 사이트의 수를 지운다).
    if (site_moved) s.forgetCrossing();
    // 답은 엄격 CDP 호출이 모두 답한 뒤(기다리는 것이 없으면 지금 — 꺼짐이면 곧).
    if (syncStrict(entry, s)) sendState(s, ok);
}

/// W9d④: 엄격의 원하는 값을 맞춘다 — 막기 엄격 사이트나 가짜 엄격 사이트가 있으면 켜고(지금 맨 위 호스트를 어느 쪽이든 덮으면 우회), 둘 다
/// 없으면 끈다(Network 도메인의 주인은 하나 — `net_domain`). 막기의 `apply`·가짜의 `setMockStrict` 가 부른다. 답할 상태가 정해졌으면(꺼짐, 또는
/// 켬의 답을 기다리지 않는다) 참.
fn syncStrict(entry: *const registry_mod.Entry, s: *Strict) bool {
    doLock();
    var want = false;
    var covers = false;
    if (table.findCef(entry.cef_id)) |t| {
        want = t.anyStrict();
        covers = t.strictCovers(t.topHost());
    }
    doUnlock();
    if (want) {
        // 앞의 엄격 CDP 가 실패했다(끝난 차례든 답을 기다리는 차례든) — 「보냈다」 는 표시를 믿지 않고 다시 보낸다(3 차 검증 N-B3-a·4 차 검증
        // B-LOW-3 — `net_domain.Batch.on`).
        runCmds(entry, s, s.tab.batch.on(&s.tab.domain, covers));
        return s.tab.batch.settle() != null;
    }
    runCmds(entry, s, s.tab.batch.off(&s.tab.domain));
    s.forgetCrossing(); // 엄격이 꺼졌다 — 걸린 어긋남은 셀 것이 아니다
    return true;
}

/// W9d④: 가짜의 엄격 사이트를 바꾼다(`net_mock_commit` — 지켜보는 탭만, 빈 글 = 끔). 엄격 CDP 가 답을 기다리면 null(답이 오면
/// `mocking.strictSettled`), 아니면 지금 상태.
pub fn setMockStrict(entry: *const registry_mod.Entry, site: []const u8) ?msg.NetStrictState {
    init();
    doLock();
    if (table.ensure(entry.id, entry.cef_id)) |t| t.setMockStrict(site);
    doUnlock();
    const s = strictEnsure(entry.cef_id, entry.id) orelse return .failed;
    const settled = syncStrict(entry, s);
    // 막기 쪽도 그 상태를 안다(막기 엄격이 있으면 같은 도메인이다).
    if (settled and s.block_seen) sendState(s, s.ok);
    if (!settled) return null;
    return mockStrictState(s);
}

/// 도메인의 엄격 상태(막기·가짜 공용).
fn domainState(s: *const Strict) msg.NetStrictState {
    return switch (s.tab.batch.state) {
        .off => .off,
        .on => .on,
        .failed => .failed,
    };
}

/// 가짜 쪽에 알릴 엄격 상태 — 가짜 엄격 사이트가 있을 때만 도메인의 상태, 없으면 꺼짐.
fn mockStrictState(s: *const Strict) msg.NetStrictState {
    doLock();
    defer doUnlock();
    const t = table.findCef(s.cef_id) orelse return .off;
    return if (t.mock_strict_len != 0) domainState(s) else .off;
}

/// 막기 쪽에 알릴 엄격 상태 — 막기 엄격 사이트가 있을 때만(가짜 엄격만 켜진 도메인을 막기의 엄격으로 알리지 않는다).
fn blockStrictState(s: *const Strict) msg.NetStrictState {
    doLock();
    defer doUnlock();
    const t = table.findCef(s.cef_id) orelse return .off;
    return if (t.strict_site_len != 0) domainState(s) else .off;
}

/// 엄격 CDP 의 답이 다 왔다(또는 떨어졌다·다시 맞췄다) — 막기·가짜 둘 다에 알린다(각자 제 엄격 사이트가 있을 때만 그 상태).
fn strictSettled(s: *const Strict) void {
    if (s.block_seen) sendState(s, s.ok);
    mocking.strictSettled(s.browser, mockStrictState(s));
}

const Compiled = struct { set: ?*table_mod.RuleSet, ok: bool };

fn compile(v: msg.NetBlock) Compiled {
    const c2 = table_mod.compile(gpa, v) catch return .{ .set = null, .ok = false };
    return .{ .set = c2.set, .ok = c2.ok };
}

fn sendState(s: *const Strict, ok: bool) void {
    writer().send(.{ .net_block_state = .{ .browser = s.browser, .generation = s.generation, .ok = ok, .strict = if (ok) blockStrictState(s) else .off } }) catch {};
}

/// 지켜보기가 꺼졌다(`net_watch` 끔) — 그 탭의 규칙을 버리고 엄격 모드를 끈다(계획 §2 — 막기는 네트워크 지켜보기 위에 선다).
pub fn watchOff(browser: BrowserId) void {
    const entry = browsers.state.registry.byId(browser) orelse return;
    doLock();
    table.dropRules(gpa, browser) catch {};
    if (table.find(browser)) |t| {
        t.strict_site_len = 0;
        t.mock_strict_len = 0; // W9d④: 가짜도 지켜보기 위에 선다(`mocking.watchOff` 가 규칙을 버린다)
    }
    refreshAny();
    doUnlock();
    if (strictOf(entry.cef_id)) |s| {
        runCmds(entry, s, s.tab.batch.off(&s.tab.domain));
        s.forgetCrossing();
    }
}

/// 설정 `browser.agent-network-full`(그 탭의 `net_watch`) — 서비스 워커 길의 수·다른 사이트 리다이렉트 수를 셀까(3 차 검증 N-B3-d).
pub fn setFull(browser: BrowserId, cef_id: c_int, full: bool) void {
    doLock();
    table.setFull(browser, cef_id, full);
    doUnlock();
}

/// `navigate{user}` — D2 의 주소 토큰.
pub fn userNavigate(browser: BrowserId, url: []const u8) void {
    const entry = browsers.state.registry.byId(browser) orelse return;
    doLock();
    table.userNavigate(browser, entry.cef_id, table_mod.canonHash(u8, url), nowMs());
    doUnlock();
}

/// `nav_action{user}` — D2 의 다음 이동 토큰(그 갈래의 이동만 가져간다 — 뒤로·앞으로는 기록 이동, 새로 고침은 새로 고침).
pub fn userNavAction(browser: BrowserId, kind: table_mod.NavKind) void {
    const entry = browsers.state.registry.byId(browser) orelse return;
    doLock();
    table.userNavAction(browser, entry.cef_id, kind, nowMs());
    doUnlock();
}

/// W9d④ Q2: maru 가 보낸 사람 입력(마우스 누름·뗌·키·IME 확정 — 에이전트의 DevTools 입력은 maru 의 이 길을 지나지 않는다). 그 뒤 창 안에서
/// 렌더러가 시작한 몸짓 이동은 사람의 것으로 묶인다(`nav_exempt`).
pub fn humanInput(browser: BrowserId) void {
    const entry = browsers.state.registry.byId(browser) orelse return;
    const t = nav_exempt.shared.acquire();
    defer nav_exempt.shared.release();
    t.humanInput(browser, entry.cef_id, nowMs());
}

// ── 사용자의 뒤로·앞으로가 주 프레임 문서를 옮기는가(3 차 검증 LOW-A3-4·4 차 검증 A-LOW) ─────────────────────────────────────

/// 기록 항목을 훑는 방문자(UI 스레드만 — CEF 가 `get_navigation_entries` 안에서 곧 부른다).
var entry_visitor: c.cef_navigation_entry_visitor_t = undefined;
var entry_visitor_ready = false;
const max_entries = 64;
var entry_urls: [max_entries]u64 = undefined;
var entry_seen: [max_entries]bool = undefined;
var entry_current: ?usize = null;

fn visitEntry(_: [*c]c.cef_navigation_entry_visitor_t, e: [*c]c.cef_navigation_entry_t, current: c_int, index: c_int, _: c_int) callconv(.c) c_int {
    defer object.releaseArg(e);
    if (e == null or index < 0 or index >= max_entries) return 1;
    const i: usize = @intCast(index);
    const u = e.*.get_url.?(e);
    defer if (u != null) api().string_userfree_utf16_free(u);
    entry_urls[i] = table_mod.canonHash(u16, units(u));
    entry_seen[i] = true;
    if (current != 0) entry_current = i;
    return 1;
}

/// 기록의 지금 항목과 그 방향(`step` -1 뒤로·+1 앞으로)의 바로 옆 항목 주소. CEF 의 「지금」 은 진행 중인 기록 이동이 있으면 그 **대상** 항목이다
/// (`NavigationController::GetCurrentEntryIndex` — 진행 중 항목) — 그래서 뒤로·앞으로를 시작한 **뒤** 읽으면 Chromium 이 고른 실제 대상(몸짓 없이
/// 생긴 항목을 건너뛴 — 기록 조작 개입)이다. 항목을 읽지 못하면 null.
pub fn historyAt(browser: [*c]c.cef_browser_t, step: i32) ?table_mod.HistoryAt {
    if (!entry_visitor_ready) {
        entry_visitor = object.zeroed(c.cef_navigation_entry_visitor_t);
        object.staticRefCounted(&entry_visitor.base);
        entry_visitor.visit = &visitEntry;
        entry_visitor_ready = true;
    }
    const host = browser.*.get_host.?(browser);
    if (host == null) return null;
    defer object.release(host);
    entry_seen = @splat(false);
    entry_current = null;
    host.*.get_navigation_entries.?(host, &entry_visitor, 0);
    const cur = entry_current orelse return null;
    var out: table_mod.HistoryAt = .{ .index = cur, .url = entry_urls[cur] };
    const next = @as(i64, @intCast(cur)) + step;
    if (next >= 0 and next < max_entries and entry_seen[@intCast(next)]) out.step_url = entry_urls[@intCast(next)];
    return out;
}

/// 사용자의 뒤로·앞으로를 시작한 뒤 — 그 기록 이동이 주 프레임 문서를 옮기지 않으면(`net_block_table.historyTokenStays` 거짓 — iframe 만·같은 주소의
/// 같은 문서) 몸짓 앞에 건 기록 토큰을 거둔다(3 차 검증 LOW-A3-4: 그 이동에는 `on_before_browse` 도 주 프레임 주소 확정도 없어 남은 토큰을 페이지의
/// `history.go(-1)` 이 가져갔다). 4 차 검증 A-LOW: 전에는 이동을 시작하기 **전에** 바로 옆 항목만 보아, 몸짓 없이 같은 주소로 pushState 한 항목을
/// 건너뛰어 그 앞 다른 문서로 가는 사용자의 뒤로가 토큰 없이 막혔다(실측 -20).
pub fn settleHistoryToken(browser: BrowserId, before: ?table_mod.HistoryAt, after: ?table_mod.HistoryAt) void {
    if (table_mod.historyTokenStays(before, after)) return;
    const entry = browsers.state.registry.byId(browser) orelse return;
    doLock();
    table.dropHistoryToken(entry.cef_id);
    doUnlock();
}

/// 다른 곳으로 가는 `nav_action{user:false}`(에이전트·복원·재생의 뒤로·앞으로)와 누구든 멈춤 — 남은 사용자 토큰을 거둔다(이 이동이 가져가지 않게
/// — 20 회 검증 A LOW-3).
pub fn agentNavigate(browser: BrowserId) void {
    const entry = browsers.state.registry.byId(browser) orelse return;
    doLock();
    table.agentNavigate(entry.cef_id);
    doUnlock();
}

/// `navigate{user:false}` — 산 주소 토큰과 같은 주소면 다툼(둘 다 진짜), 아니면 거둔다(`net_block_table.agentNavigateTo` — W9d④ v1 SEVERE-2).
pub fn agentNavigateTo(browser: BrowserId, url: []const u8) void {
    const entry = browsers.state.registry.byId(browser) orelse return;
    doLock();
    table.agentNavigateTo(entry.cef_id, table_mod.canonHash(u8, url), nowMs());
    doUnlock();
}

/// `nav_action{reload, user:false}` — 산 새로 고침 토큰이 있으면 다툼(같은 문서), 아니면 거둔다(`net_block_table.agentReload`).
pub fn agentReload(browser: BrowserId) void {
    const entry = browsers.state.registry.byId(browser) orelse return;
    doLock();
    table.agentReload(entry.cef_id, nowMs());
    doUnlock();
}

/// 이동을 시작할 수 있는 에이전트의 DevTools 호출(`devtools.zig` — `devtools_table.startsNavigationCall`) — 사용자 토큰을 거두지 않고 다툼으로 둔다
/// (`net_block_table.agentDevtoolsCall` — W9d④ v1 검증 SEVERE-2, 사용자 결정 2026-11-11 「고침」: 거두면 사용자가 친 주소·새로 고침이 겹친 에이전트의
/// `Runtime.evaluate` 하나로 가짜·막힘이 됐다; W9d③ 의 같은 경주 — 4 차 검증 A-LOW 「다시 하면 지나간다」 — 도 함께 닫는다).
pub fn agentDevtoolsCall(browser: BrowserId) void {
    const entry = browsers.state.registry.byId(browser) orelse return;
    doLock();
    table.agentDevtoolsCall(entry.cef_id, nowMs());
    doUnlock();
}

/// 떠나기 확인이 그 탭에 떴다(`dialogs.ask`) — 살아 있는 사용자 토큰의 시계를 멈춘다(2 차 검증 LOW-A2-4 — `net_block_table.holdTokens`).
pub fn beforeUnloadShown(browser: BrowserId, request: u32) void {
    const entry = browsers.state.registry.byId(browser) orelse return;
    doLock();
    table.holdTokens(entry.cef_id, request, nowMs());
    doUnlock();
}

/// 대화상자에 답이 왔다 — 멈춘 떠나기 확인이면 떠나기는 토큰을 그만큼 늘리고 머무르기는 거둔다.
pub fn dialogAnswered(browser: BrowserId, request: u32, accept: bool) void {
    const entry = browsers.state.registry.byId(browser) orelse return;
    doLock();
    table.releaseHold(entry.cef_id, request, accept, nowMs());
    doUnlock();
}

/// 그 탭의 대화상자가 답 없이 치워졌다(maru 의 새 이동이 취소로 답함·상태 비우기·렌더러 죽음) — 멈춘 토큰은 거둔다(그 이동은 시작되지 않았다).
pub fn dialogsDropped(browser: BrowserId) void {
    const entry = browsers.state.registry.byId(browser) orelse return;
    doLock();
    table.releaseHold(entry.cef_id, 0, false, nowMs());
    doUnlock();
}

// ── UI 스레드: 엄격 모드의 CDP ─────────────────────────────────────────────────────────────────────────

fn runCmds(entry: *const registry_mod.Entry, s: *Strict, cmds: net_domain.Cmds) void {
    for (cmds.slice()) |cmd| sendCmd(entry, s, cmd);
}

fn takeId() i32 {
    const id = next_id;
    next_id = if (next_id + 1 >= strict_id_end) strict_id_base else next_id + 1;
    return id;
}

fn sendCmd(entry: *const registry_mod.Entry, s: *Strict, cmd: net_domain.Cmd) void {
    const b: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.handle));
    const host = b.*.get_host.?(b);
    if (host == null) {
        // 보낼 길이 없다 — 보내기 실패로 적는다(엄격 켬의 셈은 실패, 우회는 모름, 죽은 동안이면 `life.stale` 이 새 문서에서 다시 맞추게 한다).
        s.tab.sent(cmd, 0, false);
        return;
    }
    defer object.release(host);
    // 결과를 받으려면 관찰자가 있어야 한다(결과는 그 브라우저의 모든 관찰자에게 간다 — 제 대역만 고른다).
    if (s.reg == null) s.reg = host.*.add_dev_tools_message_observer.?(host, &observer);
    const id = takeId();
    var jb: [512]u8 = undefined;
    const json = switch (cmd) {
        .enable_light => std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"Network.enable\",\"params\":{{\"maxTotalBufferSize\":0,\"maxResourceBufferSize\":0,\"maxPostDataSize\":1}}}}", .{id}),
        .enable_record => std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"Network.enable\",\"params\":{{\"maxResourceBufferSize\":2097152,\"maxTotalBufferSize\":8388608,\"maxPostDataSize\":1}}}}", .{id}),
        .disable => std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"Network.disable\",\"params\":{{}}}}", .{id}),
        .bypass_on => std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"Network.setBypassServiceWorker\",\"params\":{{\"bypass\":true}}}}", .{id}),
        .bypass_off => std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"Network.setBypassServiceWorker\",\"params\":{{\"bypass\":false}}}}", .{id}),
        // W9e②: 조건 — 규칙 하나(`urlPattern:""` — 모든 요청), 처리량은 바이트/초(kbps × 125, 0 = 제한 없음 -1). 오프라인은 요청 막기(ByRule)와
        // `navigator.onLine`(override) 둘(사용자 결정 3).
        .cond_set => condJson(&jb, id, s.cond orelse CondWish{ .hash = 1 }),
        .cond_clear => std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"Network.emulateNetworkConditionsByRule\",\"params\":{{\"matchedNetworkConditions\":[]}}}}", .{id}),
        .online_off => std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"Network.overrideNetworkState\",\"params\":{{\"offline\":true,\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}}}}", .{id}),
        .online_on => std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"Network.overrideNetworkState\",\"params\":{{\"offline\":false,\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}}}}", .{id}),
    } catch return;
    // W9e②(main 위로 옮김): 브라우저 쪽 명령(ByRule — `emulateNetworkConditionsByRule`)은 보내는 자리에서 곧 답한다 — 관찰자가 그 답을
    // `send_dev_tools_message` 안에서 받는다(실측: 보낸 뒤에 짝을 적으면 답이 짝을 못 찾아 조건 켬의 셈이 끝나지 않고 상태가 영영 `pending` —
    // 판정 `emu-net-latency`·`-offline` 의 「걸림 0x0」). 그래서 짝을 **먼저** 적고, 보내지 못하면 거둔다(`Tab.unsent`). 렌더러 쪽 명령의 답은
    // 렌더러를 거쳐 늦게 온다 — 9 차·10 차의 차례(보낸 뒤 적기 — 보내지 못한 명령은 앞 자리를 덮지 않는다) 그대로.
    if (!cmd.rendererSide()) s.tab.sent(cmd, id, true);
    const ok = host.*.send_dev_tools_message.?(host, json.ptr, json.len) != 0;
    // 10 차 MED-1: **모든** 명령의 답을 짝짓는다(엄격 밖의 `disable`·가벼운 enable 도) — 바쁜 렌더러가 처리하지 못한 채 죽으면 그 명령도 새 렌더러에
    // 닿지 않는다; 죽을 때 답을 기다리던 명령이 있어야 다시 맞춘다(`net_domain.Tab.sent` — 자리는 이 탭의 종류마다 하나, 엄격 켬의 셈·죽음 표시도 거기서).
    if (cmd.rendererSide()) s.tab.sent(cmd, id, ok) else if (!ok) s.tab.unsent(cmd, id);
    if (std.c.getenv("MARU_WEB_TEST_BLOCK_LOG") != null) std.debug.print("block: cdp b={d} {s}{s}{s}\n", .{ s.browser, @tagName(cmd), if (s.tab.life.dead) " dead" else "", if (ok) "" else " send-failed" });
}

fn onResult(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, id: c_int, success: c_int, _: ?*const anyopaque, _: usize) callconv(.c) void {
    defer object.releaseArg(browser);
    if (id < strict_id_base or id >= strict_id_end) return; // 다른 사용처의 결과
    if (browser == null) return;
    // 11 차 LOW-1: 번호만으로 모든 탭을 훑지 않는다 — 그 답이 온 탭의 짝에서만 찾는다(`net_domain.answerFrom`). 번호 대역은 1 Mi 이고 돌므로, 죽은 채
    // 되살리지 않은 탭의 「죽음」 자리를 남의 같은 번호 답이 풀 수 있었다.
    const r = net_domain.answerFrom(Strict, &stricts, browser.*.get_identifier.?(browser), id, success != 0) orelse return;
    const s = r.owner;
    const a = r.answer;
    // 9 차: 죽음을 맞은 명령의 첫 답 — 되살리는 이동이 시작됐다(실측: 그때 한꺼번에 실패로 온다 — 새 렌더러는 죽기 전 상태를 되받는다). 마지막으로
    // 바란 상태의 다시 보내기를 건다(`armResync` — 그 묶음이 끝난 뒤).
    if (a.resync) armResync(s);
    if (a.state != null) strictSettled(s);
    if (a.cond) @import("emulation.zig").conditionsSettled(s.browser); // W9e②: 조건 켬의 답 셈이 끝났다
    if (std.c.getenv("MARU_WEB_TEST_BLOCK_LOG") != null) std.debug.print("block: cdp b={d} answer ok={d}{s}\n", .{ s.browser, success, if (a.resync) " resync" else "" });
}

fn onDetached(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t) callconv(.c) void {
    defer object.releaseArg(browser);
    // DevTools 가 떨어졌다(렌더러 죽음 등) — 엄격 표시는 브라우저 쪽에 남는다(실측: 렌더러가 바뀌어도 유지). 기다리던 답만 지운다(우회 명령을 기다렸으면
    // 우회를 모른다). 죽음을 맞은 명령의 답이 사라지면 새 문서가 다시 맞춘다(`Renderer.stale` — 10 차).
    if (browser == null) return;
    const cef_id = browser.*.get_identifier.?(browser);
    const s = strictOf(cef_id) orelse return;
    const cond_lost = s.tab.condDetached(); // W9e②: 조건의 답을 기다리던 것도 오지 않는다 — 실패로 알린다(에이전트가 다시 걸 수 있다)
    if (s.tab.detached() != null) strictSettled(s);
    if (cond_lost) @import("emulation.zig").conditionsSettled(s.browser);
}

/// 다시 맞추기를 걸어 둔다 — 지금 보내지 않고 UI task 로 미룬다. 죽은 동안 보낸 명령의 실패 답은 되살리는 이동이 **시작할 때** 한꺼번에 오는데,
/// 그 답 안에서 보낸 명령도 같은 묶음으로 실패했다(실측 — 9 차 첫 고침은 답 안에서 다시 보내 모두 ok=0). 그 묶음이 끝난 뒤 보낸 명령은 새 렌더러가
/// 붙을 때까지 기다렸다가 닿는다(실측 — 이동 시작 홉에서 보낸 우회가 ok). 주 프레임 이동 시작(`beforeBrowse`)·새 문서(`loadStart`)도 걸린 것을
/// 푼다(task 보다 먼저 오면).
fn armResync(s: *Strict) void {
    s.resync_armed = true;
    // task 를 걸지 못하면 다음 이동 시작·새 문서가 푼다(`takeResync`).
    if (!resync_posted) resync_posted = api().post_task(c.TID_UI, &resync_task) != 0;
}

fn runResyncs(_: [*c]c.cef_task_t) callconv(.c) void {
    resync_posted = false;
    for (&stricts) |*slot| if (slot.*) |*s| takeResync(s);
}

/// 걸린 다시 맞추기를 지금 한다.
fn takeResync(s: *Strict) void {
    if (!s.resync_armed) return;
    s.resync_armed = false;
    const entry = browsers.state.registry.byCefId(s.cef_id) orelse return;
    resync(entry, s);
}

/// 렌더러 쪽 상태를 다시 맞춘다(9 차 — `net_domain.Batch.resync`): 마지막으로 바란 상태를 명시해 보낸다. 엄격이면 그 답이 상태를 정한다(새 차례 —
/// 죽은 동안 보낸 켬에 maru 는 아직 답을 받지 못했다; 기다릴 것이 없으면 곧 답한다).
fn resync(entry: *const registry_mod.Entry, s: *Strict) void {
    doLock();
    // W9d④: 막기·가짜 엄격 사이트 어느 쪽이든(엄격의 원하는 값 — `strictCovers`).
    const covers = if (table.findCef(s.cef_id)) |t| t.strictCovers(t.topHost()) else false;
    doUnlock();
    runCmds(entry, s, s.tab.resync(covers)); // W9e②: 조건 켬의 답 셈도 새 차례(`Tab.resync`)
    if (s.tab.domain.strict) if (s.tab.batch.settle() != null) strictSettled(s);
    if (s.tab.domain.cond and s.tab.cond_waiting == 0) @import("emulation.zig").conditionsSettled(s.browser); // 기다릴 조건 답이 없다 — 지금 상태
}

/// 렌더러가 죽었다(`client.onRenderProcessTerminated` — 9 차). 답을 기다리던 명령과 그 뒤 보내는 명령을 표시한다(`net_domain.Tab.gone`) — 표시한
/// 명령의 첫 답(되살리는 이동이 시작됐다)에 마지막으로 바란 상태의 다시 보내기를 건다. 10 차 MED-1: 살아 있을 때 보낸 명령도 모두 짝지으므로, 바쁜
/// 렌더러가 처리하지 못한 채 죽은 명령(엄격 없는 탭의 기록 끔 `disable` 등)도 여기서 표시된다. 엄격·기록을 쓴 적 없는 탭도 자리를 만든다(죽은 동안
/// 처음 켠 엄격도 표시해야 한다).
pub fn rendererGone(browser: BrowserId, cef_id: c_int) void {
    init();
    const s = strictEnsure(cef_id, browser) orelse return;
    s.tab.gone();
    if (std.c.getenv("MARU_WEB_TEST_BLOCK_LOG") != null) std.debug.print("block: renderer gone b={d} in-flight {d}\n", .{ browser, s.tab.inFlight() });
}

// ── W9e②: 네트워크 조건(`emulation.zig` 가 바람을 정한다 — 같은 Network 도메인이라 여기서 낸다) ─────────────────────────────

fn condJson(buf: []u8, id: i32, w: CondWish) ![]const u8 {
    if (w.offline) return std.fmt.bufPrint(buf, "{{\"id\":{d},\"method\":\"Network.emulateNetworkConditionsByRule\",\"params\":{{\"offline\":true,\"matchedNetworkConditions\":[{{\"urlPattern\":\"\",\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}}]}}}}", .{id});
    const down: i64 = if (w.download_kbps == 0) -1 else @as(i64, w.download_kbps) * 125;
    const up: i64 = if (w.upload_kbps == 0) -1 else @as(i64, w.upload_kbps) * 125;
    return std.fmt.bufPrint(buf, "{{\"id\":{d},\"method\":\"Network.emulateNetworkConditionsByRule\",\"params\":{{\"offline\":false,\"matchedNetworkConditions\":[{{\"urlPattern\":\"\",\"latency\":{d},\"downloadThroughput\":{d},\"uploadThroughput\":{d}}}]}}}}", .{ id, w.latency_ms, down, up });
}

/// 그 탭의 네트워크 조건을 바람대로(null = 푼다). 같은 바람이면 아무것도 내지 않는다(`net_domain` 이 해시로 가른다).
pub fn setConditions(entry: *const registry_mod.Entry, wish: ?CondWish) void {
    init();
    const s = strictEnsure(entry.cef_id, entry.id) orelse return;
    if (wish) |w| {
        const changed = s.cond == null or s.cond.?.hash != w.hash or s.cond.?.offline != w.offline;
        s.cond = w;
        if (changed) s.tab.cond_failed = false;
        runCmds(entry, s, s.tab.domain.conditionsOn(w.hash, w.offline));
    } else {
        if (s.cond == null and !s.tab.domain.cond) return;
        s.cond = null;
        s.tab.cond_failed = false;
        runCmds(entry, s, s.tab.domain.conditionsOff());
    }
}

/// 그 탭의 조건 상태(`emulation_state` 의 network 무리) — 렌더러가 죽은 동안·답을 기다리면 `pending`(`net_domain.Tab.condStatus`). 렌더러 죽음은
/// 위의 `rendererGone`(W9d③ 9 차의 길 — 엄격·기록·조건을 쓴 적 없는 탭도 자리를 만든다: 옛 W9e② 구현 적대 리뷰 2 회차 M-a 와 같은 규칙)이 적는다.
pub fn conditionsStatus(cef_id: c_int) CondStatus {
    const s = strictOf(cef_id) orelse return .off;
    return s.tab.condStatus();
}

// ── W9d② 기록과 나누기(`net_body.zig`) ──────────────────────────────────────────────────────────────────

/// 본문 기록이 켜졌다(net_body 가 기록의 상한으로 `Network.enable` 을 보냈다 — 그 답으로 켜짐을 안다). 그 뒤의 명령(엄격 밖의 모르는 우회를
/// 지우는 `bypass_off` — 5 차 검증 NIT: 기록의 enable 이 남았을 수 있는 우회 표시를 되살렸다)은 여기서 보낸다.
pub fn recordingOn(entry: *const registry_mod.Entry) void {
    const s = strictEnsure(entry.cef_id, entry.id) orelse return;
    const cmds = s.tab.domain.recordOn();
    for (cmds.slice()) |cmd| if (cmd != .enable_record) sendCmd(entry, s, cmd); // enable_record 는 net_body 가 보냈다
}

/// 본문 기록이 꺼졌다·밸브로 멈췄다 — 엄격이 도메인을 쥐고 있으면 끄지 않고 가벼운 enable 로 버퍼를 내린다(`net_domain`).
pub fn recordingOff(entry: *const registry_mod.Entry) void {
    const s = strictEnsure(entry.cef_id, entry.id) orelse return;
    runCmds(entry, s, s.tab.domain.recordOff());
}

/// 본문 기록의 켬이 실패했다(`net_body` 의 `Network.enable` 답 — 9 차: 렌더러가 죽은 동안 보낸 켬은 새 렌더러가 붙을 때 실패로 답하는데, 새 렌더러는
/// 죽기 전 상태 — 기록이 켠 도메인일 수 있다 — 를 되받는다). 기록 몫을 내리고 렌더러 쪽을 모르니 바라는 상태를 명시해 보낸다(끔이 덜 해롭다 —
/// 남은 도메인은 렌더러가 본문을 받아 두게 하고 에이전트가 DevTools 로 그것을 읽는다).
pub fn recordingFailed(entry: *const registry_mod.Entry) void {
    const s = strictEnsure(entry.cef_id, entry.id) orelse return;
    s.tab.domain.dropRecording();
    resync(entry, s);
}

/// 본문 기록의 DevTools 가 떨어졌다·브라우저가 닫힌다 — 명령 없이 기록 몫만 내린다.
pub fn recordingGone(cef_id: c_int) void {
    if (strictOf(cef_id)) |s| s.tab.domain.recordingGone(); // 엄격·조건이 없으면 도메인은 꺼진 것으로(`net_domain`)
}

// ── UI 스레드: CEF 사건 ────────────────────────────────────────────────────────────────────────────────

fn frameKey(frame: [*c]c.cef_frame_t) u64 {
    if (frame == null) return 0;
    const id = frame.*.get_identifier.?(frame);
    if (id == null) return 0;
    defer api().string_userfree_utf16_free(id);
    return keyOfUnits(units(id));
}

/// 프레임 번호 글의 열쇠(0 = 모름) — `frameKey` 와 나열(`get_frame_identifiers` 의 글)이 같은 값을 낸다.
fn keyOfUnits(u: []const u16) u64 {
    if (u.len == 0) return 0;
    return @max(1, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(u)));
}

/// `on_before_browse`(주·하위 프레임, 홉마다) — 진행 중 이동·D2 토큰 묶기·엄격의 사이트 묶기. 목록 밖 브라우저도 적는다(§12 P1-4).
/// W9d④: `user_gesture` — CEF 가 준 사용자 몸짓(렌더러가 시작한 링크·폼 이동). 주 프레임이고 D2 토큰이 가져가지 않은 이동이면 공용 표가 사람의
/// 누름(Q2)인지 정해 그 주소에 묶는다. 엄격은 막기·가짜 엄격 사이트 어느 쪽이든 덮는가로 정한다.
pub fn beforeBrowse(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, is_redirect: c_int, user_gesture: c_int) void {
    if (browser == null or frame == null or request == null) return;
    addBrowser(browser);
    const cef_id = browser.*.get_identifier.?(browser);
    const entry = browsers.state.registry.byCefId(cef_id);
    const main = frame.*.is_main.?(frame) != 0;
    const raw = request.*.get_url.?(request);
    defer if (raw != null) api().string_userfree_utf16_free(raw);
    const url = units(raw);
    var hb: [msg.max_net_host_bytes]u8 = undefined;
    const host = table_mod.urlHost(u16, url, &hb);
    const canon = table_mod.canonHash(u16, url);
    doLock();
    const nav = table_mod.NavKind.fromTransition(@bitCast(request.*.get_transition_type.?(request)));
    const user = table.beforeBrowse(if (entry) |e| e.id else 0, cef_id, main, is_redirect != 0, nav, if (main) 0 else frameKey(frame), canon, table_mod.urlOriginHash(u16, url), host, nowMs());
    const strict = if (table.findCef(cef_id)) |t| t.anyStrict() else false;
    const covers = if (table.findCef(cef_id)) |t| t.strictCovers(host) else false;
    doUnlock();
    bumpTopology();
    if (main) {
        const ex = nav_exempt.shared.acquire();
        const human = ex.beforeBrowse(if (entry) |e| e.id else 0, cef_id, is_redirect != 0, user_gesture != 0, user, canon, nowMs());
        nav_exempt.shared.release();
        if (std.c.getenv("MARU_WEB_TEST_MOCK_LOG") != null) std.debug.print("mock: obb b={d} redirect={d} gesture={d} user={} human={}\n", .{ cef_id, is_redirect, user_gesture, user, human });
    }
    // 엄격 모드의 사이트 묶기 — 이 홉의 호스트를 엄격 사이트가 덮는가. 첫 홉에서 보낸 값은 그 이동에 듣는다(실측 latch). 리다이렉트 홉에서 보낸
    // 값은 이 이동에는 듣지 않는다(Chromium 은 서비스 워커 우회를 이동이 시작할 때 정한다 — 20 회 검증 A MED-1, 실측 2/2): 다음 이동을 위해 보내고,
    // 이 이동이 경계를 넘었다고 적어 문서가 확정되면 센다(`addressChanged` — 결과의 `strict.redirects_not_covered`·`redirects_bypassed_other_site`).
    // 홉을 끊고 다시 이동하는 고침은 기록·Referer·SameSite 쿠키·POST 를 바꿔 사용자 결정에 남겼다(계획 문서 「W9d③ 20 회 적대 검증」).
    if (main) if (strictOf(cef_id)) |s| {
        takeResync(s); // 9 차: 걸린 다시 맞추기 — 실패 답의 묶음 뒤다(이 홉의 우회 값은 아래 `navigate` 가 다시 정한다)
        if (is_redirect == 0) {
            s.forgetCrossing();
            s.nav_strict = false;
            s.nav_bypass = s.tab.domain.strict and s.tab.domain.bypassing();
        }
        if (strict) if (entry) |e| {
            runCmds(e, s, s.tab.domain.navigate(covers));
            if (is_redirect == 0) {
                s.nav_bypass = s.tab.domain.strict and s.tab.domain.bypassing();
                s.nav_strict = s.tab.domain.strict;
            } else if (s.nav_strict and s.tab.domain.strict) {
                // 마지막 홉이 정한다(A→B→A 는 어긋남이 없다) — 그 홉 주소가 곧 문서의 주소다.
                s.nav_crossed = covers != s.nav_bypass;
                s.crossed_url = canon;
                s.landing = false;
            }
        };
    };
}

/// 주 프레임 주소가 바뀌었다(확정) — 맨 위 호스트.
pub fn addressChanged(browser: [*c]c.cef_browser_t, url: [*c]const c.cef_string_t) void {
    if (browser == null) return;
    const cef_id = browser.*.get_identifier.?(browser);
    const entry = browsers.state.registry.byCefId(cef_id);
    var hb: [msg.max_net_host_bytes]u8 = undefined;
    const host = table_mod.urlHost(u16, units(url), &hb);
    const canon = table_mod.canonHash(u16, units(url));
    doLock();
    table.committed(if (entry) |e| e.id else 0, cef_id, host, canon);
    // W9d④: 엄격의 바람은 막기·가짜 엄격 사이트 어느 쪽이든 — 그러나 어긋남의 수는 막기의 수(`net_block_hits`)라 막기 엄격이 켜졌을 때만 센다.
    const covers = if (table.findCef(cef_id)) |t| t.strictCovers(host) else false;
    const block_strict = if (table.findCef(cef_id)) |t| t.strict_site_len != 0 else false;
    doUnlock();
    bumpTopology();
    // MED-1: 리다이렉트로 엄격 사이트의 경계를 넘은 이동의 문서가 섰다 — 시작 때의 우회 값이 이 문서에 맞지 않으면 센다(말없이 두지 않는다).
    // 2 차 검증 LOW-A2-2: 새 문서의 시작(`landing`) 뒤의 주소 확정만 — 그 사이 옛 문서의 같은 문서 이동(pushState·해시)은 세지도 지우지도 않는다
    // (전에는 그것이 셈을 먹어 진짜 어긋남을 놓쳤다 2/2), 다른 문서가 섰으면(그 이동이 아니다 — bfcache 로 돌아감) 세지 않고 지운다.
    if (strictOf(cef_id)) |s| if (s.nav_crossed and s.landing) {
        const landed = canon == s.crossed_url;
        s.forgetCrossing();
        if (!landed or !block_strict) return;
        if (covers != s.nav_bypass) {
            doLock();
            if (table.findCef(cef_id)) |t| {
                // 다른 사이트 쪽은 설정이 켜졌을 때만 센다(N-B3-d).
                if (covers) t.counts.strict_redirect_missed +|= 1 else if (t.full) t.counts.strict_redirect_bypassed +|= 1;
            }
            doUnlock();
            @import("network.zig").postFlush();
            if (std.c.getenv("MARU_WEB_TEST_BLOCK_LOG") != null) std.debug.print("block: strict redirect {s} b={d}\n", .{ if (covers) "missed" else "bypassed", s.browser });
        }
    };
}

/// 문서가 시작됐다(`on_load_start`) — 그 프레임의 진행 중 이동이 끝났다.
pub fn loadStart(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t) void {
    if (browser == null or frame == null) return;
    const main = frame.*.is_main.?(frame) != 0;
    const cef_id = browser.*.get_identifier.?(browser);
    // 하위 프레임은 그 문서의 주소로도 찾는다(열쇠가 바뀐 사이트가 다른 iframe — MED-A3-1), 막은 이동의 오류 페이지인지도 그것으로 안다.
    var canon: u64 = 0;
    if (!main) {
        const u = frame.*.get_url.?(frame);
        defer if (u != null) api().string_userfree_utf16_free(u);
        canon = table_mod.canonHash(u16, units(u));
    }
    doLock();
    if (main) table.frameSettled(cef_id, true, 0) else table.subframeStarted(cef_id, frameKey(frame), canon);
    doUnlock();
    bumpTopology();
    // 새 문서가 섰다(같은 문서 이동에는 오지 않는다 — CEF 는 이 뒤에 주소 확정을 부른다): 경계를 넘은 이동이 걸려 있으면 그 주소 확정에서 센다.
    if (main) if (strictOf(cef_id)) |s| {
        if (s.nav_crossed) s.landing = true;
        // 9 차: 렌더러가 다시 섰다 — 걸린 다시 맞추기를 하고, 죽음을 맞은 명령이 없으면 맞출 것이 없다(표시를 그친다). 10 차: 죽음을 맞은 명령의 답을
        // 끝내 못 받았으면(떨어짐·보내기 실패) 지금 맞춘다(fail-safe — 늦어도 닫는다).
        takeResync(s);
        if (s.tab.committed()) if (browsers.state.registry.byCefId(cef_id)) |e| resync(e, s);
    };
}

/// 주 프레임 이동이 실패했다(`on_load_error`) — 실패 주소가 막은 이동이면 그 규칙(오류 페이지 귀속 — §6.3), 아니면 0.
pub fn loadError(browser: [*c]c.cef_browser_t, failed_url: [*c]const c.cef_string_t) u32 {
    if (browser == null) return 0;
    const cef_id = browser.*.get_identifier.?(browser);
    const canon = table_mod.canonHash(u16, units(failed_url));
    doLock();
    const rule = table.mainBlockRule(cef_id, canon);
    table.frameSettled(cef_id, true, 0);
    doUnlock();
    bumpTopology();
    crossingFailed(cef_id, canon); // 그 이동의 문서가 서지 않았다 — 셀 어긋남이 없다
    return rule;
}

/// 주 프레임 이동이 끊겼다(`on_load_error` 의 ERR_ABORTED — 204·다운로드·멈춤·새 이동에 밀림). 오류 페이지가 없고 옛 문서가 남는다(또는 새 이동이
/// 이어진다). 그 이동의 경계 넘기 셈을 지우고(2 차 검증 LOW-A2-2: 지우지 않아 뒤의 같은 문서 이동이 거짓으로 셌다 6/6), 그 이동의 진행 중 기록을
/// 놓는다 — 실패 주소가 그 기록의 주소일 때만(밀려 끊긴 옛 이동의 ERR_ABORTED 는 새 이동이 시작된 **뒤에** 온다 — 새 이동의 기록·셈을 지우지
/// 않게).
pub fn loadAborted(browser: [*c]c.cef_browser_t, failed_url: [*c]const c.cef_string_t) void {
    if (browser == null) return;
    const cef_id = browser.*.get_identifier.?(browser);
    const canon = table_mod.canonHash(u16, units(failed_url));
    doLock();
    table.mainAborted(cef_id, canon);
    doUnlock();
    bumpTopology();
    crossingFailed(cef_id, canon);
}

fn crossingFailed(cef_id: c_int, canon: u64) void {
    if (strictOf(cef_id)) |s| if (s.nav_crossed and s.crossed_url == canon) s.forgetCrossing();
}

/// 하위 프레임의 이동이 문서 없이 끝났다(`on_load_error` — 끊김 ERR_ABORTED 를 포함: 204·다운로드, 오류·막힘) — 그 프레임의 진행 중 기록을 놓는다
/// (3 차 검증 MED-A3-1: `on_load_start` 가 없는 이 끝들을 아무도 놓지 않아 그 탭이 30 초 동안 그 출처를 「보이는」 탭으로 남았다 — 아무 탭도
/// 보이지 않는 출처의 서비스 워커 요청이 다른 사이트에 묶인 규칙으로 막히고 무관한 탭에 「적용 안 됨」 이 세어졌다, 4/4).
/// 실패 주소로도 찾는다 — 사이트가 다른 iframe 의 오류 페이지는 새 렌더 프레임에 서 프레임 번호가 `on_before_browse` 때와 다르다(실측 CEF 154). 끊김이
/// 아닌 오류(빈 응답 등)는 그 프레임에 오류 페이지가 섰다 — 그 프레임은 그 출처를 보이지 않는다(나열이 실패 주소를 보인다).
pub fn subframeEnded(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, failed_url: [*c]const c.cef_string_t, error_code: c_int) void {
    if (browser == null or frame == null) return;
    const cef_id = browser.*.get_identifier.?(browser);
    const key = frameKey(frame);
    const canon = table_mod.canonHash(u16, units(failed_url));
    doLock();
    table.subframeEnded(cef_id, key, canon, error_code != c.ERR_ABORTED);
    doUnlock();
    bumpTopology();
}

/// 프레임이 떨어졌다 — 나열이 바뀌고, 하위 프레임이면 그 프레임의 진행 중 이동·오류 표시도 끝났다(MED-A3-1 — 이동 중에 지워진 iframe).
pub fn frameDetached(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t) void {
    if (browser != null and frame != null and frame.*.is_main.?(frame) == 0) {
        const cef_id = browser.*.get_identifier.?(browser);
        const key = frameKey(frame);
        doLock();
        table.subframeGone(cef_id, key);
        doUnlock();
    }
    bumpTopology();
}

/// CEF 브라우저가 만들어졌다(`on_after_created` — 입양 전 팝업 포함).
pub fn addBrowser(browser: [*c]c.cef_browser_t) void {
    if (browser == null) return;
    const id = browser.*.get_identifier.?(browser);
    _ = std.c.pthread_mutex_lock(&blist_lock);
    defer _ = std.c.pthread_mutex_unlock(&blist_lock);
    for (blist) |b| if (b != null and b.*.get_identifier.?(b) == id) return;
    for (blist_extra[0..blist_missing]) |x| if (x == id) return;
    for (&blist) |*s| if (s.* == null) {
        browser.*.base.add_ref.?(&browser.*.base);
        s.* = browser;
        bumpTopology();
        return;
    };
    // 목록이 찼다 — 번호만 적는다(나열은 「모름」 하나로 — 막지 않는 쪽).
    if (blist_missing < blist_extra.len) {
        blist_extra[blist_missing] = id;
        blist_missing += 1;
    } else blist_missing = blist_extra.len; // 더 넘쳐도 「있다」 는 그대로
    bumpTopology();
}

/// 브라우저가 닫힌다(`on_before_close`) — 목록·표·엄격에서 뺀다.
pub fn browserClosed(cef_id: c_int) void {
    {
        _ = std.c.pthread_mutex_lock(&blist_lock);
        defer _ = std.c.pthread_mutex_unlock(&blist_lock);
        for (&blist) |*s| if (s.* != null and s.*.*.get_identifier.?(s.*) == cef_id) {
            object.release(s.*);
            s.* = null;
        };
        var i: usize = 0;
        while (i < blist_missing) {
            if (blist_extra[i] == cef_id) {
                blist_extra[i] = blist_extra[blist_missing - 1];
                blist_missing -= 1;
            } else i += 1;
        }
    }
    doLock();
    table.forget(gpa, cef_id) catch {};
    refreshAny();
    doUnlock();
    {
        const ex = nav_exempt.shared.acquire();
        defer nav_exempt.shared.release();
        ex.forget(cef_id); // W9d④
    }
    bumpTopology();
    for (&stricts) |*s| if (s.*) |v| if (v.cef_id == cef_id) {
        if (v.reg != null) object.release(v.reg);
        s.* = null;
    };
}

// ── 보내는 task(`network.zig` 의 flush — UI 스레드) ────────────────────────────────────────────────────────

/// 모은 수의 차이를 보내고 다 쓴 은퇴 묶음을 푼다.
pub fn flushHits() void {
    const S = struct {
        var hits: [table_mod.capacity * 2 * table_mod.max_frames]msg.NetBlockHits = undefined;
    };
    const hits = &S.hits; // UI 스레드만 — 큰 배열을 쌓지 않게 정적 자리
    var n: usize = 0;
    doLock();
    var ids: [table_mod.capacity * 2]BrowserId = undefined;
    for (table.browsersWithHits(&ids)) |b| {
        if (b == 0) continue;
        n += table.takeHits(b, hits[n..][0..table_mod.max_frames]);
    }
    table.reap(gpa);
    doUnlock();
    for (hits[0..n]) |h| writer().send(.{ .net_block_hits = h }) catch {};
}
