//! 지켜보는 탭의 네트워크 요청(W9d① — CEF 자원 요청 처리기, docs/plans/web-osr-backend.md 「W9d① 결정」).
//!
//! 스레드: CEF 는 `get_resource_request_handler` 와 그 처리기의 콜백을 브라우저 프로세스의 **IO 스레드**에서 부른다(W9d-0 실측 — UI 스레드가
//! 아니다). 여기서는 IO 스레드에서 쓰기(maru 로 가는 관)·로그를 하지 않는다 — 동기 쓰기 하나가 요청 처리량을 27 % 깎고 다른 탭의 불러오기를
//! 60 % 늦췄다(M6). 대신:
//!   ① `get_resource_request_handler`: 지켜보는 탭이 없으면 곧 null(가장 흔한 길). 있으면 **글로 바꾸기 전에** 문(`net_gate` — 탭·전체 양동이,
//!      동시 요청 512·탭마다 128)을 지나야 처리기를 돌려준다. 넘치면 수만 센다.
//!   ② 처리기 콜백: 주소(2 KiB)·메서드·헤더(64 개·8 KiB)의 앞부분만 바꿔 기록 하나(`Event`)를 만들고 뮤텍스 아래 넘김 상자(개수·바이트 상한)에
//!      넣는다. UI 스레드의 task 하나가 모아서 보낸다(`flush` — 이미 올렸으면 다시 올리지 않는다).
//! 요청은 CEF 요청 번호로 묶는다(리다이렉트·인증 재시도에도 같다 — M7·M5). 다운로드(번호 0)는 W10 의 몫이라 적지 않는다.
//! 출처는 브라우저 번호 + initiator 로 가른다(프레임 주소는 IO 스레드에서 비거나 낡았다 — M4).
//!
//! 서비스 워커: 서비스 워커가 다스리는 페이지의 요청은 탭의 처리기를 지나지 않고(브라우저가 없다), 전역 request context 와 저장소를 나눈
//! context 의 처리기에만 온다(M4·Q2). `host_main` 이 처음에 그 context 하나를 만들고(`createSharedContext`) 끝까지 쥔다 — 브라우저는 전역
//! context 에 그대로 둔다(권한·환경설정·다운로드가 그대로임을 Q2 가 쟀다). 그 처리기는 브라우저가 없는 요청만 보고, initiator 출처를 연 지켜보는
//! 탭이 없으면 곧 null 이다. 붙일 탭이 있으면 그 탭들 모두에 「service worker of <출처>」 로 붙는다.
//!
//! 설정 `browser.agent-network-full` 이 꺼진 탭(`net_watch.full` 거짓)은 UI 스레드가 보내기 전에 덜어 낸다(`net_policy` — 주소의 사용자 정보,
//! 덮이지 않는 호스트의 헤더, 허용 목록 밖 헤더 값). 덜어 낼지는 **적을 때** 탭마다 찍고(`net_gate.State.stamp`) 보낼 때의 지켜보기와 겹쳐
//! 더 덜어 내는 쪽으로 정한다(W9d① 적대 리뷰 3 회차 P1c — 꺼진 동안 적은 것은 켠 뒤 보내도 덜어 낸다). 보이지 않는 것
//! (`docs/plans/web-osr-backend.md`): CORS preflight·WebSocket·`data:`·`blob:`·서비스 워커 스크립트·서비스 워커가 만든 응답.
//! 호스트(W9d① 적대 리뷰 3 회차 T1): 덮이는지 가를 호스트(요청·홉·첫 사이트)와 서비스 워커를 붙일 출처는 **자르기 전의 온 주소**(CEF 의 UTF-16)
//! 에서 읽고(`net_policy.hostOfUrl16`), 요청·홉의 호스트는 제 칸(`host`)으로 싣는다. 2 KiB 로 자르는 주소는 사용자 정보를 빼고 자른다 — 긴
//! 사용자 정보 안에서 끊긴 앞부분(`https://yyy…a.test`)이 덮이는 사이트로 읽혀 은행의 쿠키가 보였다. 앞부분이 잘린 initiator 는 싣지 않는다.
//! W9d②: 어느 탭이든 본문을 기록하면(`net_body.any_recording`) IO 스레드가 시작마다 온 주소의 해시와 mach 시각을 찍고(맞추기 열쇠 — 2 KiB 앞부분이
//! 아니다), 문이 넘긴 요청과 넘김 상자가 넘쳐 버린 시작(W9d② 적대 리뷰 4 회차)의 해시를 남긴다(그 창의 같은 주소 짝은 모호하다). 보내는 task 가 기록하는 탭의 시작을 본문 후보로 적고(`body_expected`),
//! 응답에서 덮이는지(설정 끔 — 헤더를 덜어 낼지와 같은 결정), 끝에서 짝 없는 후보의 시한을 건다(`net_body.zig`).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const gate = @import("net_gate.zig");
const net_body = @import("net_body.zig"); // W9d②: 기록하는 탭의 본문(맞추기 열쇠·끝)
const body_table = @import("net_body_table.zig");
const blocking = @import("blocking.zig"); // W9d③: 요청 막기 — 처리기 고르기에서 맞춘다
const mocking = @import("mocking.zig"); // W9d④: 가짜 응답 — 막기 다음에 맞춘다(막기가 이긴다)

const msg = protocol.message;
const net_fields = protocol.net_fields;
const net_policy = protocol.net_policy;
const BrowserId = msg.BrowserId;

var lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
/// 뮤텍스 아래에서만 만진다.
var state: gate.State = .{};
var queue: std.ArrayList(*Event) = .empty;

var rrh: c.cef_resource_request_handler_t = undefined;
/// W9d③: 막는 요청의 기록 처리기 — `rrh` 에 막는 자원 처리기 고르기를 더했다(막힌 요청도 W9d① 기록에 `blocked` 로 남는다).
var rrh_block: c.cef_resource_request_handler_t = undefined;
var ctx_handler: c.cef_request_context_handler_t = undefined;
var shared_ctx: [*c]c.cef_request_context_t = null;
var flush_task: c.cef_task_t = undefined;
var flush_posted = std.atomic.Value(bool).init(false);
var ready = false;

/// 모은 기록을 보내기까지(UI 스레드 task 하나 — 쏟아질 때 여러 기록을 한 번에).
const flush_delay_ms: i64 = 10;

fn api() *const library.Api {
    return browsers.state.api;
}

fn doLock() void {
    _ = std.c.pthread_mutex_lock(&lock);
}

fn doUnlock() void {
    _ = std.c.pthread_mutex_unlock(&lock);
}

fn nowUs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
}

/// 유닉스 ms(요청의 시각 — 에이전트가 읽는다).
fn wallMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(@max(0, ts.sec))) * 1000 + @as(u64, @intCast(@divTrunc(@max(0, ts.nsec), 1_000_000)));
}

/// 처리기 구조체를 채운다(UI 스레드 — `client.get` 이 처음 부를 때).
pub fn init() void {
    if (ready) return;
    ready = true;
    rrh = object.zeroed(c.cef_resource_request_handler_t);
    object.staticRefCounted(&rrh.base);
    rrh.on_before_resource_load = &onBeforeResourceLoad;
    rrh.on_resource_redirect = &onResourceRedirect;
    rrh.on_resource_response = &onResourceResponse;
    rrh.on_resource_load_complete = &onResourceLoadComplete;
    blocking.init();
    rrh_block = rrh;
    rrh_block.get_resource_handler = &blocking.getBlockHandler;
    mocking.init();
    ctx_handler = object.zeroed(c.cef_request_context_handler_t);
    object.staticRefCounted(&ctx_handler.base);
    ctx_handler.get_resource_request_handler = &contextResourceRequestHandler;
    flush_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&flush_task.base);
    flush_task.execute = &flush;
}

/// W9d④: 요청마다의 가짜 처리기에 W9d① 기록 콜백을 단다(문을 지난 요청 — 가짜도 시작·응답·끝으로 적힌다, 실측 M13).
pub fn setRecording(r: *c.cef_resource_request_handler_t) void {
    r.on_before_resource_load = &onBeforeResourceLoad;
    r.on_resource_redirect = &onResourceRedirect;
    r.on_resource_response = &onResourceResponse;
    r.on_resource_load_complete = &onResourceLoadComplete;
}

/// W9d④: 보내는 task 를 깨운다(가짜의 붙잡기 시한 — UI 스레드).
pub fn postFlushPublic() void {
    postFlush();
}

/// W9d④: 모아 둔 기록을 지금 보낸다(UI 스레드 — 주 프레임 불러오기의 끝·멈춤 앞). 주 프레임 문서의 끝(IO 의 `on_resource_load_complete`)은
/// 불러오기의 끝보다 인과적으로 먼저지만 보내는 task 는 10 ms 뒤라, 작은 가짜 문서면 `load_finished` 가 먼저 maru 에 닿아 navigate 의 결과가
/// 「가짜였다」 를 몰랐다. 보낼 것이 없으면 아무것도 하지 않는다.
pub fn flushNow() void {
    doLock();
    const pending = queue.items.len > 0;
    doUnlock();
    if (pending) flush(&flush_task);
}

/// 서비스 워커 요청을 보는 context 하나를 만든다(UI 스레드 — `cef_initialize`·환경설정 뒤, 첫 브라우저 전). 전역 context 와 저장소를 나눈다.
/// 만들지 못하면 서비스 워커 요청만 보이지 않는다(나머지는 그대로).
pub fn createSharedContext() void {
    init();
    const global = api().request_context_get_global_context();
    if (global == null) return;
    // 넘긴 인자의 참조는 CEF 로 옮겨 간다(`object.release_callback_args`) — 전역 context 는 그대로 넘긴다(받은 참조를 넘긴다).
    shared_ctx = api().request_context_create_shared(global, &ctx_handler);
}

/// CEF 를 내리기 전에 놓는다.
pub fn releaseSharedContext() void {
    // request context 의 참조 세기는 환경설정 관리자(`base`) 아래의 `base` 에 있다.
    if (shared_ctx != null) _ = shared_ctx.*.base.base.release.?(&shared_ctx.*.base.base);
    shared_ctx = null;
}

// ── UI 스레드: maru 의 명령·주소 바뀜·닫힘 ─────────────────────────────────────────────────────────────

/// `net_watch`(maru) — 그 탭을 지켜보기 시작하거나 그만둔다.
pub fn watch(v: msg.NetWatch) void {
    init();
    const entry = browsers.state.registry.byId(v.browser) orelse return;
    var hosts: [msg.max_net_watch_hosts][]const u8 = undefined;
    for (v.hosts[0..v.host_count], 0..) |h, i| hosts[i] = h;
    var origin_buf: [gate.max_origin_bytes]u8 = undefined;
    const origin = if (v.on) currentOrigin(entry.handle, &origin_buf) else "";
    doLock();
    _ = state.setWatch(v.browser, entry.cef_id, v.on, v.full, v.any_host, hosts[0..v.host_count]);
    if (v.on) state.setTopOrigin(v.browser, origin);
    doUnlock();
    // 재검증 8 차: 기록 중에 지켜보기만 꺼졌다 — 문이 그 탭에 기록을 붙이지 않으니 서비스 워커 본문은 그 때부터 잇지 않는다.
    if (!v.on) net_body.watchOff(v.browser);
    // W9d③: 막기는 지켜보기 위에 선다 — 끄면 그 탭의 규칙을 버리고 엄격 모드를 끈다(계획 §2). 설정 `agent-network-full` 은 막기의 수에도
    // 듣는다(3 차 검증 N-B3-d — 꺼진 동안의 서비스 워커 수는 세지 않는다).
    blocking.setFull(v.browser, entry.cef_id, v.on and v.full);
    // W9d④: 가짜도 지켜보기 위에 선다 — 가짜의 규칙을 먼저 버리고(붙잡은 처리기는 `-12`), 막기가 두 엄격 사이트를 지우고 엄격을 끈다.
    if (!v.on) {
        mocking.watchOff(v.browser);
        blocking.watchOff(v.browser);
    }
}

/// W9d③: 그 탭을 지켜보는가(UI 스레드 — `blocking.apply` 가 규칙을 받을지 정한다).
pub fn watching(browser: BrowserId) bool {
    doLock();
    defer doUnlock();
    return state.watchOf(browser) != null;
}

/// 브라우저가 닫혔다.
pub fn browserClosed(id: BrowserId) void {
    doLock();
    state.forget(id);
    doUnlock();
}

/// 주 프레임 주소가 바뀌었다(UI 스레드 `on_address_change`) — 서비스 워커 요청을 붙일 출처. CEF 의 온 주소(UTF-16)에서 읽는다 — 32 KiB 를
/// 넘어 maru 에 알리지 않는 주소도(W9d① 적대 리뷰 4 회차 C3), 긴 사용자 정보 너머의 출처도(3 회차 T1). 모르면 빈 출처(붙이지 않는다).
pub fn mainFrameAddress(id: BrowserId, url: [*c]const c.cef_string_t) void {
    var ob: [gate.max_origin_bytes]u8 = undefined;
    const origin = net_policy.originOfUrl16(units(url), &ob);
    doLock();
    state.setTopOrigin(id, origin);
    doUnlock();
    net_body.topOrigin(id, origin); // 재검증 5 차 S3b(C0): 서비스 워커가 답한 응답은 맨 위 출처의 문서 것만 잇는다
}

/// 주 프레임에 새 문서가 시작됐다(UI 스레드 `on_load_start`·오류 페이지 — `page_started`·`error_page` 를 보내기 전에). 그 뒤에 보내는 앞 문서
/// iframe 의 요청에는 `previous_document` 가 선다(W9d① 적대 리뷰 5 회차 B1 — `net_gate.DocFrames`).
pub fn documentStarted(id: BrowserId) void {
    // W9d② 20 회 검증 N1·D3: 본문 표에도 — 앞 문서와 함께 끊긴 요청(CDP 끝이 오지 않는다)을 곧 `unavailable` 로 끝낸다.
    net_body.documentStarted(id);
    const entry = browsers.state.registry.byId(id) orelse return;
    entry.net_docs.mainDocument();
}

/// 하위 프레임에 문서가 시작됐다(UI 스레드 `on_load_start`) — 그 프레임이 지금 문서의 것임을 적는다.
pub fn subframeDocument(id: BrowserId, frame: [*c]c.cef_frame_t) void {
    const entry = browsers.state.registry.byId(id) orelse return;
    entry.net_docs.subframeDocument(frameKey(frame));
}

/// 프레임 번호(CEF 154 — 글)의 해시. 모르면 0(`DocFrames` 가 적지도 표시하지도 않는다). 어느 스레드에서나 부를 수 있다.
fn frameKey(frame: [*c]c.cef_frame_t) u64 {
    if (frame == null) return 0;
    const id = frame.*.get_identifier.?(frame);
    if (id == null) return 0;
    defer api().string_userfree_utf16_free(id);
    const u = units(id);
    if (u.len == 0) return 0;
    return @max(1, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(u)));
}

fn currentOrigin(handle: *anyopaque, buf: []u8) []const u8 {
    const browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(handle));
    const frame = browser.*.get_main_frame.?(browser);
    if (frame == null) return "";
    defer object.release(frame);
    const url = frame.*.get_url.?(frame);
    if (url == null) return "";
    defer api().string_userfree_utf16_free(url);
    return net_policy.originOfUrl16(units(url), buf); // 온 주소에서(3 회차 T1 — 사용자 정보 너머의 출처)
}

/// CEF 문자열의 UTF-16 단위들(비었으면 빈 조각).
fn units(value: [*c]const c.cef_string_t) []const u16 {
    if (value == null or value.*.str == null) return &.{};
    return @ptrCast(value.*.str[0..value.*.length]);
}

/// 주소를 싣는 꼴(W9d① 적대 리뷰 3 회차 T1) — 앞부분(2 KiB)과 온 주소에서 읽은 호스트. 잘릴 주소는 사용자 정보를 빼고 자른다(잘린 글에 사용자
/// 정보가 남으면 maru 가 보일 때 어디까지가 사용자 정보인지 모른다 — codec 이 거절한다). 잘리지 않는 주소는 그대로(설정이 켜져 있으면 maru 가
/// 읽는 쪽마다 지운다 — D1).
const UrlText = struct { text: []const u8, truncated: bool, host: []const u8 };

fn readUrl(value: [*c]const c.cef_string_t, buf: *[msg.max_net_url_bytes]u8, host_buf: *[msg.max_net_host_bytes]u8) UrlText {
    const all = units(value);
    const host = net_policy.hostOfUrl16(all, host_buf);
    const whole = library.readPrefix(api(), value, msg.max_net_url_bytes, buf);
    protocol.text.replaceControl(whole.text);
    if (!whole.truncated) return .{ .text = whole.text, .truncated = false, .host = host };
    const a = net_policy.authority16(all) orelse return .{ .text = whole.text, .truncated = true, .host = host };
    if (a.host_start == a.start) return .{ .text = whole.text, .truncated = true, .host = host }; // 사용자 정보가 없다
    // 스킴이 자르는 길이를 넘는다(5 회차 N1 — 스킴 길이는 보지 않는다): 앞부분에 사용자 정보만 남을 수 있어 싣지 않는다(그 요청·홉은 적지 않는다).
    if (a.start >= buf.len) return .{ .text = buf[0..0], .truncated = true, .host = host };
    // `scheme://`(스킴은 ASCII 글자 — `authority16` 이 봤다) + 호스트부터의 앞부분.
    for (all[0..a.start], buf[0..a.start]) |ch, *o| o.* = @intCast(ch);
    const rest: c.cef_string_t = .{ .str = value.*.str + a.host_start, .length = value.*.length - a.host_start, .dtor = null };
    const tail = library.readPrefix(api(), &rest, msg.max_net_url_bytes - a.start, buf[a.start..]);
    protocol.text.replaceControl(tail.text);
    return .{ .text = buf[0 .. a.start + tail.text.len], .truncated = tail.truncated, .host = host };
}

/// CEF 가 넘긴 주소 글(사용자가 풀어야 하는 것)의 호스트 — 온 주소에서 읽고 푼다.
fn userfreeHost(s: c.cef_string_userfree_t, host_buf: *[msg.max_net_host_bytes]u8) []const u8 {
    if (s == null) return "";
    defer api().string_userfree_utf16_free(s);
    return net_policy.hostOfUrl16(units(s), host_buf);
}

// ── IO 스레드: 처리기를 고른다 ─────────────────────────────────────────────────────────────────────────

/// 탭의 처리기 고르기(`cef_request_handler_t.get_resource_request_handler`).
pub fn resourceRequestHandler(_: [*c]c.cef_request_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, is_navigation: c_int, is_download: c_int, initiator: [*c]const c.cef_string_t, _: [*c]c_int) callconv(.c) [*c]c.cef_resource_request_handler_t {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    defer object.releaseArg(request);
    if (browser == null or request == null or is_download != 0) return null;
    // W9d④: 사용자 이동의 예외(D2·Q2) — 주 프레임 이동의 요청이면 규칙과 무관하게 공용 표가 소비한다(§13 P2-1). 막기·가짜가 같은 답을 본다.
    const exempt = blocking.navExempt(browser, frame, request, is_navigation);
    // W9d③: 막기 — 요청 번호·지켜보기·문보다 **먼저**(speculation prefetch·prerender 는 번호 0 으로 온다 — 실측 J-B11; 번호를 먼저 보면 막을
    // 주소가 서버에 간다). 규칙이 없으면 원자 하나만 본다.
    const block = blocking.tabSelect(browser, frame, request, is_navigation);
    if (block.rule != 0) return blockedTab(browser, request, is_navigation, initiator, block);
    // W9d④: 가짜 — 막기가 맞지 않은 요청만(막기가 이긴다). 같은 꼴(번호 전에 맞춘다·규칙이 없으면 원자 하나).
    switch (mocking.tabSelect(browser, frame, request, is_navigation, initiator, exempt)) {
        .none => {},
        .slot => |slot| return mockedTab(browser, request, is_navigation, initiator, slot),
        .busy => return busyTab(browser, request),
    }
    doLock();
    if (state.watching == 0) {
        doUnlock();
        return null;
    }
    const w = state.watchByCef(browser.*.get_identifier.?(browser)) orelse {
        doUnlock();
        return null;
    };
    const id = request.*.get_identifier.?(request);
    if (id == 0) {
        doUnlock();
        return null;
    }
    if (state.find(id)) |t| { // 리다이렉트의 다음 홉 — 문을 다시 지나지 않는다
        mockHop(t, 0, 0); // W9d④: 앞 홉이 가짜였으면 그 가짜가 리다이렉트를 줬다(이 홉은 진짜)
        doUnlock();
        return &rrh;
    }
    const admitted = if (state.startTab(w, id, nowUs())) |t| blk: {
        t.navigation = is_navigation != 0;
        break :blk true;
    } else false;
    const watched_browser = w.browser;
    doUnlock();
    if (!admitted) {
        // W9d②: 기록하는 탭이면 넘긴 요청의 주소 해시를 남긴다 — 그 창 안의 같은 주소 짝은 모호하다(넘긴 쌍둥이 자리에 다른 요청이 든다 — J2).
        if (net_body.any_recording.load(.acquire)) markDrop(&.{watched_browser}, request);
        postFlush();
        return null;
    }
    // 문을 지난 뒤에만 initiator 를 바꾼다(앞부분만). 잘린 출처는 싣지 않는다(3 회차 T1 — 앞부분의 호스트는 다른 호스트일 수 있다: 빈
    // initiator 는 다른 사이트로 친다).
    var ib: [gate.max_origin_bytes]u8 = undefined;
    const init_read = library.readPrefix(api(), initiator, gate.max_origin_bytes, &ib);
    const init_text = if (init_read.truncated) ib[0..0] else init_read.text;
    doLock();
    if (state.find(id)) |t| {
        @memcpy(t.initiator[0..init_text.len], init_text);
        t.initiator_len = init_text.len;
    }
    doUnlock();
    return &rrh;
}

/// W9d③: 탭 길에서 막는 요청 — 이미 적는 요청(리다이렉트의 다음 홉)이면 그 기록에 막음을 세우고, 아니면 문을 지나 적는다(막힌 요청도 목록에
/// 보이게). 문을 지나지 못했거나(양동이·동시 요청) 번호가 0 이거나 지켜보는 탭이 아니면 기록 없이 막고 그 수를 센다(fail closed — 문이 막기를
/// 끄지 않는다).
fn blockedTab(browser: [*c]c.cef_browser_t, request: [*c]c.cef_request_t, is_navigation: c_int, initiator: [*c]const c.cef_string_t, block: blocking.TabHit) [*c]c.cef_resource_request_handler_t {
    const rule = block.rule;
    const cef_id = browser.*.get_identifier.?(browser);
    const id = request.*.get_identifier.?(request);
    postFlush(); // 막은 수를 보낸다
    if (id == 0) {
        blocking.noteUnrecorded(cef_id, block.generation);
        return &blocking.block_only;
    }
    doLock();
    if (state.find(id)) |t| {
        t.block_kind = .blocked;
        t.block_rules = @splat(0);
        t.block_rules[0] = rule;
        doUnlock();
        return &rrh_block;
    }
    const w = state.watchByCef(cef_id) orelse {
        doUnlock();
        blocking.noteUnrecorded(cef_id, block.generation);
        return &blocking.block_only;
    };
    const watched_browser = w.browser;
    const t = state.startTab(w, id, nowUs()) orelse {
        doUnlock();
        if (net_body.any_recording.load(.acquire)) markDrop(&.{watched_browser}, request);
        blocking.noteUnrecorded(cef_id, block.generation);
        return &blocking.block_only;
    };
    t.navigation = is_navigation != 0;
    t.block_kind = .blocked;
    t.block_rules[0] = rule;
    doUnlock();
    var ib: [gate.max_origin_bytes]u8 = undefined;
    const init_read = library.readPrefix(api(), initiator, gate.max_origin_bytes, &ib);
    const init_text = if (init_read.truncated) ib[0..0] else init_read.text;
    doLock();
    if (state.find(id)) |tt| {
        @memcpy(tt.initiator[0..init_text.len], init_text);
        tt.initiator_len = init_text.len;
    }
    doUnlock();
    return &rrh_block;
}

/// W9d④: 홉 하나의 가짜 표시(잠금 아래) — 앞 홉이 가짜였으면(다음 홉이 왔으니 리다이렉트였다) 그 규칙을 `mock_redirect_rule` 로, 이 홉의 규칙
/// (0 = 진짜 홉)을 `mock_rule` 로.
fn mockHop(t: *gate.Track, rule: u32, body_id: u32) void {
    if (t.mock_rule != 0) t.mock_redirect_rule = t.mock_rule;
    t.mock_rule = rule;
    t.mock_body_id = body_id;
}

/// W9d④: 탭 길에서 가짜를 주는 요청 — 막기의 `blockedTab` 과 같은 꼴: 이미 적는 요청(리다이렉트의 다음 홉)이면 그 기록에 가짜를 세우고, 아니면 문을
/// 지나 적는다(가짜도 목록에 보이게 — 실측 M13). 문을 지나지 못했거나 번호가 0 이거나 지켜보지 않는 탭이면 기록 없이 가짜를 주고 그 수를
/// 센다(fail closed — 문이 가짜를 끄지 않는다). 어느 쪽이든 그 처리기 고르기는 쿠키 필터를 단다(`mocking.Slot`).
fn mockedTab(browser: [*c]c.cef_browser_t, request: [*c]c.cef_request_t, is_navigation: c_int, initiator: [*c]const c.cef_string_t, slot: *mocking.Slot) [*c]c.cef_resource_request_handler_t {
    const cef_id = browser.*.get_identifier.?(browser);
    const id = request.*.get_identifier.?(request);
    postFlush(); // 맞음의 수를 보낸다
    if (id == 0) {
        mocking.noteUnrecorded(cef_id);
        return slot.handlerFor(false);
    }
    doLock();
    if (state.find(id)) |t| {
        mockHop(t, slot.ruleId(), slot.bodyId());
        doUnlock();
        return slot.handlerFor(true);
    }
    const w = state.watchByCef(cef_id) orelse {
        doUnlock();
        mocking.noteUnrecorded(cef_id);
        return slot.handlerFor(false);
    };
    const watched_browser = w.browser;
    const t = state.startTab(w, id, nowUs()) orelse {
        doUnlock();
        if (net_body.any_recording.load(.acquire)) markDrop(&.{watched_browser}, request);
        mocking.noteUnrecorded(cef_id);
        return slot.handlerFor(false);
    };
    t.navigation = is_navigation != 0;
    t.mock_rule = slot.ruleId();
    t.mock_body_id = slot.bodyId();
    t.mock_first = !slot.redirects(); // 시작의 `flags2.mocked` — 리다이렉트 가짜면 다음 홉(진짜일 수 있다)의 본문을 W9d② 가 받는다
    doUnlock();
    // W9d② 와의 맞물림(main 위로 옮김 — 판정 `mock-record-body-mixed`): 본문 후보로 적지 않는 가짜 요청도 CDP 에는 보인다(가짜 본문을 싣고). 같은
    // 주소의 진짜 요청(다른 종류 — 같은 열쇠)이 곁에 있으면 그 진짜 기록이 가짜의 CDP 기록과 짝지어 **가짜 본문을 진짜의 것으로** 받았다(실측 19/20).
    // 문이 넘긴 요청처럼 표지를 남겨 그 창의 같은 주소 짝을 모호하게 친다(잃는 쪽). 탭 길의 요청이라 서비스 워커 갈래를 어둠으로 치지는 않는다 —
    // 몫이 차서 넘긴 서비스 워커 요청의 표지와 같은 「어둠 없음」 꼴(`sw_cap`)을 빌린다(그 표지는 짝만 모호하게 하고 수는 세지 않는다).
    if (mockSkipsBody(slot) and net_body.any_recording.load(.acquire)) markDropKind(&.{watched_browser}, request, true);
    var ib: [gate.max_origin_bytes]u8 = undefined;
    const init_read = library.readPrefix(api(), initiator, gate.max_origin_bytes, &ib);
    const init_text = if (init_read.truncated) ib[0..0] else init_read.text;
    doLock();
    if (state.find(id)) |tt| {
        @memcpy(tt.initiator[0..init_text.len], init_text);
        tt.initiator_len = init_text.len;
    }
    doUnlock();
    return slot.handlerFor(true);
}

/// 가짜가 시작에서 본문 후보를 건너뛰는가(`Track.mock_first` 와 같은 값 — 리다이렉트가 아닌 가짜).
fn mockSkipsBody(slot: *const mocking.Slot) bool {
    return !slot.redirects();
}

/// W9d④: 맞았지만 가짜를 줄 수 없다(풀이 참) — `-12` 로 끝낸다(진짜로 보내지 않는다 — M17). 이미 적는 요청이면 기록 콜백이 있는 꼴로(끝이 적힌다).
fn busyTab(browser: [*c]c.cef_browser_t, request: [*c]c.cef_request_t) [*c]c.cef_resource_request_handler_t {
    _ = browser;
    const id = request.*.get_identifier.?(request);
    postFlush();
    doLock();
    defer doUnlock();
    if (state.find(id)) |t| {
        mockHop(t, 0, 0);
        return &mocking.rrh_busy_recorded;
    }
    return &mocking.rrh_busy;
}

/// 공유 context 의 처리기 고르기 — 브라우저가 없는 요청(서비스·공유 워커가 대신 보냈다)만.
fn contextResourceRequestHandler(_: [*c]c.cef_request_context_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, is_navigation: c_int, is_download: c_int, initiator: [*c]const c.cef_string_t, _: [*c]c_int) callconv(.c) [*c]c.cef_resource_request_handler_t {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    defer object.releaseArg(request);
    if (browser != null or request == null or is_download != 0) return null; // 브라우저가 있는 요청은 탭의 처리기가 본다
    // W9d③: 서비스 워커 길의 막기(§6.2) — W9d① 의 문보다 앞. initiator 출처를 앞부분만 읽는다 — 비었거나 잘렸으면 모르는 출처라 막지 않는다.
    var ib: [gate.max_origin_bytes]u8 = undefined;
    var init_text: []const u8 = "";
    var init_ok = false;
    var sw: blocking.SwResult = .{};
    if (blocking.anyRules()) {
        const r = library.readPrefix(api(), initiator, gate.max_origin_bytes, &ib);
        init_ok = true;
        if (!r.truncated) init_text = r.text;
        if (init_text.len != 0) sw = blocking.serviceWorkerSelect(request, init_text);
        if (sw.outcome == .block or sw.outcome == .not_applied) postFlush();
    }
    // W9d④: 서비스 워커는 가짜를 어떤 길로도 보지 않는다(사용자 결정 Q1) — 맞는 규칙을 쥔 탭에 수만 센다(엄격을 쓰라). 막힌 요청은 세지 않는다.
    if (sw.outcome != .block and mocking.anyRules()) {
        if (!init_ok) {
            const r = library.readPrefix(api(), initiator, gate.max_origin_bytes, &ib);
            init_ok = true;
            if (!r.truncated) init_text = r.text;
        }
        if (init_text.len != 0 and mocking.serviceWorker(request, init_text)) postFlush();
    }
    const blocked = sw.outcome == .block;
    doLock();
    const any = state.watching != 0;
    doUnlock();
    if (!any) return unrecordedServiceWorker(blocked, &sw); // 가장 흔한 길 — 지켜보는 탭이 없다
    const id = request.*.get_identifier.?(request);
    if (id == 0) return unrecordedServiceWorker(blocked, &sw);
    doLock();
    // 리다이렉트의 다음 홉은 문을 다시 지나지 않는다.
    if (state.find(id)) |t| {
        if (sw.outcome == .block or sw.outcome == .not_applied) markServiceWorker(t, &sw);
        doUnlock();
        return if (blocked) &rrh_block else &rrh;
    }
    doUnlock();
    // 출처는 앞부분만(상한 있는) 바꾼다 — 지켜보는 출처가 아니면 양동이를 쓰지 않고 곧 null(적대 리뷰 2 회차 N5: 출처를 맞추기 전에 이 길의
    // 양동이를 썼더니 지켜보지 않는 출처의 쏟아짐이 지켜보는 탭의 요청을 세지도 않고 막았다). 지켜보는 출처의 거절은 붙일 탭들의 넘긴 수다.
    if (!init_ok) {
        const init_read = library.readPrefix(api(), initiator, gate.max_origin_bytes, &ib);
        if (init_read.truncated) return null; // 잘린 출처로는 붙일 탭을 고르지 않는다(3 회차 T1 — 다른 출처와 앞부분이 같을 수 있다)
        init_text = init_read.text;
    }
    if (init_text.len == 0) return unrecordedServiceWorker(blocked, &sw);
    doLock();
    var targets: [gate.max_targets]BrowserId = undefined;
    const gate_answer = state.startServiceWorker(init_text, id, nowUs(), &targets);
    const n = gate_answer.targets;
    const admitted = if (gate_answer.track) |t| blk: {
        t.navigation = is_navigation != 0;
        @memcpy(t.initiator[0..init_text.len], init_text);
        t.initiator_len = init_text.len;
        if (sw.outcome == .block or sw.outcome == .not_applied) markServiceWorker(t, &sw);
        break :blk true;
    } else false;
    doUnlock();
    if (n != 0 and !admitted) {
        if (net_body.any_recording.load(.acquire)) markDropKind(targets[0..n], request, gate_answer.cap);
        postFlush();
    }
    if (admitted) return if (blocked) &rrh_block else &rrh;
    return unrecordedServiceWorker(blocked, &sw);
}

/// W9d③: 서비스 워커 길의 답을 기록에 세운다(잠금 아래) — 붙일 탭마다 그 탭이 쥔 규칙(없으면 0 — 그 탭의 기록에는 표시가 없다).
fn markServiceWorker(t: *gate.Track, sw: *const blocking.SwResult) void {
    t.block_kind = if (sw.outcome == .block) .blocked else .sw_not_applied;
    for (t.targets[0..t.target_count], 0..) |b, i| t.block_rules[i] = sw.ruleOf(b);
}

/// W9d③: 기록하지 않는 서비스 워커 요청 — 막으면 기록 없이 막고 막은 규칙을 쥔 탭마다 센다.
fn unrecordedServiceWorker(blocked: bool, sw: *const blocking.SwResult) [*c]c.cef_resource_request_handler_t {
    if (!blocked) return null;
    blocking.noteUnrecordedTargets(sw);
    return &blocking.block_only;
}

// ── W9d②: 문이 넘긴 요청의 표지(IO 스레드 → 보내는 task) ──────────────────────────────────────────────────

// 표지는 `state`(뮤텍스 아래)에 둔다 — `net_gate.State.markDrop`·`queueRefused`(상자가 넘쳐 버린 시작도 — W9d② 적대 리뷰 4 회차). 넘치면 그
// 탭은 넘침으로 알린다(표가 그 탭의 넘침을 모르면 짝이 맞게 보일 수 있다).

fn markDrop(targets: []const BrowserId, request: [*c]c.cef_request_t) void {
    markDropKind(targets, request, false);
}

/// `sw_cap` — 서비스 워커 몫이 차서 넘겼다(재검증 5 차 (B) — 본문 표는 탭 전체를 어둠으로 치지 않는다).
fn markDropKind(targets: []const BrowserId, request: [*c]c.cef_request_t, sw_cap: bool) void {
    const raw = request.*.get_url.?(request);
    defer if (raw != null) api().string_userfree_utf16_free(raw);
    const hash = body_table.hashUrl16(units(raw));
    doLock();
    defer doUnlock();
    // 잠금 아래에서 찍는다 — 표지의 차례가 시각의 차례라 물 높이(`cefWatermark`)가 남은 표지의 가장 이른 시각으로 정해진다(W9d② 적대 리뷰 3 회차).
    state.markDropKind(targets, hash, net_body.machUs(), sw_cap);
}

// ── IO 스레드: 처리기 콜백 → 기록 ─────────────────────────────────────────────────────────────────────

const Kind = enum { begin, redirect, response, end };

/// IO → UI 로 넘기는 기록 하나(c_allocator — 글은 `data` 안에 이어 붙였다).
const Event = struct {
    kind: Kind,
    request: u64,
    targets: [gate.max_targets]BrowserId = @splat(0),
    target_count: u8 = 0,
    flags: msg.NetFlags = .{},
    hop: msg.NetHopFlags = .{},
    resource_type: u8 = 0,
    status: u16 = 0,
    outcome: msg.NetOutcome = .success,
    error_code: i32 = 0,
    received: u64 = 0,
    time_ms: u64 = 0,
    header_count: u8 = 0,
    /// 요청을 보낸 하위 프레임의 번호 해시(begin — 5 회차 B1: 보낼 때 그 프레임이 앞 문서의 것인지 본다). 모르면 0.
    frame: u64 = 0,
    /// 적을 때 찍은 덜어 내기(대상마다 — 3 회차 P1c).
    stamp: gate.Stamp = .{},
    /// W9d②(begin — 어느 탭이든 기록할 때만): 조각을 뗀 온 주소의 해시(맞추기 열쇠)와 IO 시각(mach µs — CDP `timestamp` 와 같은 시계).
    /// IO 시각은 넘김 상자에 넣을 때 잠금 아래에서 찍는다(`enqueue` — W9d② 적대 리뷰 3 회차 P1: 상자의 차례가 곧 시각의 차례라야 물 높이가 선다).
    url_hash: u64 = 0,
    t_io_us: i64 = 0,
    /// 상자에 넣은 시각(잠금 아래 — 모든 기록). 상자에 남은 가장 이른 것이 물 높이를 정한다(`cefWatermark`).
    queued_us: i64 = 0,
    /// W9d③(end): 막기의 표시와 대상마다 규칙(`Track.block_kind`·`block_rules`).
    block_kind: gate.BlockKind = .none,
    block_rules: [gate.max_targets]u32 = @splat(0),
    /// W9d④(begin): 첫 홉을 리다이렉트가 아닌 가짜로 골랐다(`flags2.mocked`). (end): 마지막 홉의 가짜 규칙·리다이렉트를 준 가짜 규칙.
    mock_first: bool = false,
    mock_rule: u32 = 0,
    mock_redirect_rule: u32 = 0,
    mock_body_id: u32 = 0,
    /// 덮이는지 가를 호스트(begin — 요청 주소, redirect — 옮기기 전 주소, response — 지금 주소) — 온 주소에서 읽었다(3 회차 T1).
    host: []const u8 = "",
    /// 싣는 주소의 호스트(begin — 요청 주소, redirect — 옮겨 갈 주소 — wire 의 `host` 칸).
    url_host: []const u8 = "",
    url: []const u8 = "",
    method: []const u8 = "",
    initiator: []const u8 = "",
    site: []const u8 = "",
    mime: []const u8 = "",
    headers: []const u8 = "",
    data: []u8 = &.{},

    fn bytes(self: *const Event) usize {
        return @sizeOf(Event) + self.data.len;
    }
};

/// 기록의 글을 하나로 모은다(앞부분이 이미 잘린 것들).
const Parts = struct {
    host: []const u8 = "",
    url_host: []const u8 = "",
    url: []const u8 = "",
    method: []const u8 = "",
    initiator: []const u8 = "",
    site: []const u8 = "",
    mime: []const u8 = "",
    headers: []const u8 = "",
};

fn makeEvent(template: Event, parts: Parts) ?*Event {
    const total = parts.host.len + parts.url_host.len + parts.url.len + parts.method.len + parts.initiator.len + parts.site.len + parts.mime.len + parts.headers.len;
    const a = std.heap.c_allocator;
    const e = a.create(Event) catch return null;
    const data = a.alloc(u8, total) catch {
        a.destroy(e);
        return null;
    };
    e.* = template;
    e.data = data;
    var at: usize = 0;
    e.host = place(data, &at, parts.host);
    e.url_host = place(data, &at, parts.url_host);
    e.url = place(data, &at, parts.url);
    e.method = place(data, &at, parts.method);
    e.initiator = place(data, &at, parts.initiator);
    e.site = place(data, &at, parts.site);
    e.mime = place(data, &at, parts.mime);
    e.headers = place(data, &at, parts.headers);
    return e;
}

/// `src` 를 `data[at..]` 에 옮기고 그 자리를 돌려준다.
fn place(data: []u8, at: *usize, src: []const u8) []const u8 {
    @memcpy(data[at.*..][0..src.len], src);
    const out = data[at.*..][0..src.len];
    at.* += src.len;
    return out;
}

fn freeEvent(e: *Event) void {
    std.heap.c_allocator.free(e.data);
    std.heap.c_allocator.destroy(e);
}

/// 넘김 상자에 넣는다 — 넘치면 버리고 그 탭들의 넘긴 수를 센다. 넣기 전에 대상마다 덜어 내기를 찍는다(3 회차 P1c — 적을 때의 설정·호스트).
fn enqueue(e: *Event) void {
    doLock();
    // W9d② 적대 리뷰 3 회차 P1: 시각을 잠금 아래에서 찍는다 — 그러면 상자의 차례가 시각의 차례이고, 보내는 task 가 상자를 비운 때까지 찍힌
    // 시작은 모두 표에 닿았다(물 높이). 요청은 이 콜백이 돌아온 뒤에 나가므로 제 기록의 IO 시각은 여전히 그 요청의 응답보다 앞이다.
    e.queued_us = net_body.machUs();
    if (e.kind == .begin and e.url_hash != 0) e.t_io_us = e.queued_us;
    e.stamp = state.stamp(e.targets[0..e.target_count], e.host, e.site);
    const ok = state.reserveQueue(e.bytes()) and blk: {
        queue.append(std.heap.c_allocator, e) catch {
            state.releaseQueue(e.bytes());
            break :blk false;
        };
        break :blk true;
    };
    // 넘친 시작은 넘긴 수를 세고, 본문을 기록하면 표지도 남긴다(W9d② 적대 리뷰 4 회차 — 그 요청의 CDP 쪽이 같은 주소의 다른 기록을 갖지 않게).
    // 넘친 리다이렉트·응답·끝은 본문을 기록하면 그 요청의 표지를 남긴다(5 회차 C1 — 버린 끝을 기다리는 후보도 끝이 꼭 오게).
    if (!ok) state.queueRefused(e.kind == .begin, e.targets[0..e.target_count], e.url_hash, e.request, e.queued_us, net_body.any_recording.load(.acquire));
    doUnlock();
    if (!ok) freeEvent(e);
    postFlush();
}

/// W9d② 적대 리뷰 3 회차 P1: 물 높이 — 이 IO 시각까지 찍힌 CEF 기록(시작·문 넘김 표지)은 모두 보내는 task 가 표에 넘겼다(UI 스레드에서 부른다 —
/// 보내는 task 도 UI 스레드라 상자에서 꺼낸 것은 이미 다 넘겼다). 상자가 비었으면 지금, 아니면 남은 가장 이른 것의 앞.
pub fn cefWatermark() i64 {
    doLock();
    defer doUnlock();
    var w = net_body.machUs() - 1;
    if (queue.items.len > 0) w = @min(w, queue.items[0].queued_us - 1);
    if (state.drop_mark_len > 0) w = @min(w, state.drop_marks[0].t_us - 1);
    return w;
}

pub fn postFlush() void {
    if (flush_posted.swap(true, .acq_rel)) return;
    if (api().post_delayed_task(c.TID_UI, &flush_task, flush_delay_ms) == 0) flush_posted.store(false, .release);
}

/// 요청 번호로 그 요청을 찾아 붙일 탭들과 시작의 첫 사이트(`site_buf` 에 — W9d② 20 회 검증 D1)를 복사한다(시작했는지도). 없으면 null.
fn lookup(request: [*c]c.cef_request_t, out: *Event, site_buf: *[msg.max_net_host_bytes]u8, site_len: *usize) ?bool {
    if (request == null) return null;
    const id = request.*.get_identifier.?(request);
    doLock();
    defer doUnlock();
    const t = state.find(id) orelse return null;
    out.request = id;
    out.targets = t.targets;
    out.target_count = t.target_count;
    const site = t.siteSlice();
    @memcpy(site_buf[0..site.len], site);
    site_len.* = site.len;
    return t.begun;
}

fn userfreeText(s: c.cef_string_userfree_t, max: usize, out: []u8) struct { text: []const u8, truncated: bool } {
    if (s == null) return .{ .text = "", .truncated = false };
    defer api().string_userfree_utf16_free(s);
    const p = library.readPrefix(api(), s, max, out);
    protocol.text.replaceControl(p.text);
    return .{ .text = p.text, .truncated = p.truncated };
}

/// 헤더 다발을 덩어리로(이름 64 개·8 KiB — 넘는 것은 싣지 않고 `truncated`). `hsts` 에 HSTS 내부 이동 표시를 적는다.
fn readHeaders(map: c.cef_string_multimap_t, b: *net_fields.HeaderBuilder, hsts: ?*bool) void {
    const a = api();
    const n = a.string_multimap_size(map);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (b.count >= msg.max_net_header_count or b.payload >= msg.max_net_headers_bytes) {
            b.truncated = true;
            break;
        }
        var k = std.mem.zeroes(c.cef_string_t);
        var v = std.mem.zeroes(c.cef_string_t);
        _ = a.string_multimap_key(map, i, &k);
        _ = a.string_multimap_value(map, i, &v);
        defer a.string_utf16_clear(&k);
        defer a.string_utf16_clear(&v);
        var kb: [msg.max_net_header_name_bytes]u8 = undefined;
        var vb: [msg.max_net_headers_bytes]u8 = undefined;
        const name = library.readPrefix(a, &k, msg.max_net_header_name_bytes, &kb);
        const room = msg.max_net_headers_bytes -| b.payload;
        const value = library.readPrefix(a, &v, @min(room, vb.len), &vb);
        if (name.truncated) {
            b.truncated = true;
            continue;
        }
        if (hsts) |h| if (std.ascii.eqlIgnoreCase(name.text, "non-authoritative-reason") and std.ascii.eqlIgnoreCase(value.text, "hsts")) {
            h.* = true;
        };
        _ = b.add(name.text, value.text);
        if (value.truncated) b.truncated = true;
    }
}

fn onBeforeResourceLoad(_: [*c]c.cef_resource_request_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, callback: [*c]c.cef_callback_t) callconv(.c) c.cef_return_value_t {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    defer object.releaseArg(request);
    defer object.releaseArg(callback);
    var e: Event = .{ .kind = .begin, .request = 0 };
    const id = if (request != null) request.*.get_identifier.?(request) else return c.RV_CONTINUE;
    var initiator_buf: [gate.max_origin_bytes]u8 = undefined;
    var initiator_len: usize = 0;
    {
        doLock();
        defer doUnlock();
        const t = state.find(id) orelse return c.RV_CONTINUE;
        if (t.begun) return c.RV_CONTINUE; // 인증 재시도·다음 홉 — 시작은 한 번만 보낸다
        t.begun = true;
        e.request = id;
        e.targets = t.targets;
        e.target_count = t.target_count;
        e.flags.service_worker = t.service_worker;
        e.flags.navigation = t.navigation;
        e.mock_first = t.mock_first; // W9d④
        initiator_len = t.initiator_len;
        @memcpy(initiator_buf[0..initiator_len], t.initiator[0..initiator_len]);
    }
    if (frame != null and !e.flags.service_worker) {
        if (frame.*.is_main.?(frame) != 0) e.flags.main_frame = true else e.flags.subframe = true;
    }
    if (e.flags.subframe) e.frame = frameKey(frame); // 5 회차 B1 — 보낼 때 앞 문서의 iframe 인지 본다
    e.resource_type = @intCast(@min(@as(c_uint, @intCast(request.*.get_resource_type.?(request))), msg.max_net_resource_type));
    if (e.resource_type == 18) e.resource_type = 6;
    e.time_ms = wallMs();
    var ub: [msg.max_net_url_bytes]u8 = undefined;
    var uh: [msg.max_net_host_bytes]u8 = undefined;
    const raw_url = request.*.get_url.?(request);
    defer if (raw_url != null) api().string_userfree_utf16_free(raw_url);
    // W9d②: 기록하는 탭이 있으면 맞추기 열쇠 — 온 주소(2 KiB 앞부분이 아니다 — 긴 주소의 앞이 같을 수 있다)의 해시와 IO 시각.
    if (net_body.any_recording.load(.acquire)) e.url_hash = body_table.hashUrl16(units(raw_url)); // IO 시각은 `enqueue` 가 찍는다
    const url = readUrl(raw_url, &ub, &uh);
    if (url.text.len == 0) {
        // 재검증 7 차(E1 의 같은 뿌리): 싣지 못하는 주소 — 기록이 표에 들지 않는다. 기록하면 넘긴 것처럼 표지를 남긴다(제 기록이 없는 W·CDP 요청이
        // 같은 주소의 남의 기록을 가져가지 않게).
        if (e.url_hash != 0) markDropKind(e.targets[0..e.target_count], request, false);
        return c.RV_CONTINUE;
    }
    e.flags.url_truncated = url.truncated;
    var mb: [msg.max_net_method_bytes]u8 = undefined;
    var method = userfreeText(request.*.get_method.?(request), msg.max_net_method_bytes, &mb).text;
    net_fields.checkMethod(method) catch {
        method = "GET";
    };
    var sb: [msg.max_net_host_bytes]u8 = undefined;
    const site = userfreeHost(request.*.get_first_party_for_cookies.?(request), &sb); // 온 주소에서(3 회차 T1)
    {
        // 리다이렉트·응답이 같은 첫 사이트로 덮기를 가르게 요청 표에 둔다(W9d② 20 회 검증 D1 — 그사이 끝났으면 자리가 없다: 그 뒤 기록도 없다).
        doLock();
        defer doUnlock();
        if (state.find(id)) |t| t.setSite(site);
    }
    var hb: net_fields.HeaderBuilder = .{};
    const map = api().string_multimap_alloc();
    if (map != null) {
        defer api().string_multimap_free(map);
        request.*.get_header_map.?(request, map);
        readHeaders(map, &hb, null);
    }
    e.flags.headers_truncated = hb.truncated;
    e.header_count = hb.count;
    const initiator = initiator_buf[0..initiator_len];
    protocol.text.replaceControl(initiator_buf[0..initiator_len]);
    const ev = makeEvent(e, .{ .host = url.host, .url_host = url.host, .url = url.text, .method = method, .initiator = initiator, .site = site, .headers = hb.block().bytes }) orelse {
        if (e.url_hash != 0) markDropKind(e.targets[0..e.target_count], request, false); // 재검증 7 차: 위와 같다(할당 실패)
        return c.RV_CONTINUE;
    };
    enqueue(ev);
    return c.RV_CONTINUE;
}

fn onResourceRedirect(_: [*c]c.cef_resource_request_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, response: [*c]c.cef_response_t, new_url: [*c]c.cef_string_t) callconv(.c) void {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    defer object.releaseArg(request);
    defer object.releaseArg(response);
    var e: Event = .{ .kind = .redirect, .request = 0 };
    var sb: [msg.max_net_host_bytes]u8 = undefined;
    var site_len: usize = 0;
    if (!(lookup(request, &e, &sb, &site_len) orelse return)) return;
    if (response == null) return;
    e.status = @intCast(std.math.clamp(response.*.get_status.?(response), 100, 599));
    e.time_ms = wallMs();
    var nb: [msg.max_net_url_bytes]u8 = undefined;
    var nh: [msg.max_net_host_bytes]u8 = undefined;
    const next = readUrl(new_url, &nb, &nh);
    if (next.text.len == 0) return;
    e.hop.url_truncated = next.truncated;
    var fh: [msg.max_net_host_bytes]u8 = undefined;
    const from_host = userfreeHost(request.*.get_url.?(request), &fh); // 그 홉을 보낸 곳(온 주소에서)
    var hb: net_fields.HeaderBuilder = .{};
    var hsts = false;
    const map = api().string_multimap_alloc();
    if (map != null) {
        defer api().string_multimap_free(map);
        response.*.get_header_map.?(response, map);
        readHeaders(map, &hb, &hsts);
    }
    e.hop.hsts = hsts;
    e.hop.headers_truncated = hb.truncated;
    e.header_count = hb.count;
    // 덮기는 시작의 첫 사이트로(D1) — 그 홉을 보낸 호스트(`from_host`)가 그와 같은 사이트일 때만 어느 호스트든으로 덮인다.
    const ev = makeEvent(e, .{ .host = from_host, .url_host = next.host, .url = next.text, .site = sb[0..site_len], .headers = hb.block().bytes }) orelse return;
    enqueue(ev);
}

fn onResourceResponse(_: [*c]c.cef_resource_request_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, response: [*c]c.cef_response_t) callconv(.c) c_int {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    defer object.releaseArg(request);
    defer object.releaseArg(response);
    var e: Event = .{ .kind = .response, .request = 0 };
    var sb: [msg.max_net_host_bytes]u8 = undefined;
    var site_len: usize = 0;
    if (!(lookup(request, &e, &sb, &site_len) orelse return 0)) return 0;
    if (response == null) return 0;
    e.status = @intCast(std.math.clamp(response.*.get_status.?(response), 0, 999));
    e.time_ms = wallMs();
    var mb: [msg.max_net_mime_bytes]u8 = undefined;
    const mime = userfreeText(response.*.get_mime_type.?(response), msg.max_net_mime_bytes, &mb).text;
    var rh: [msg.max_net_host_bytes]u8 = undefined;
    const resp_host = userfreeHost(request.*.get_url.?(request), &rh); // 응답을 보낸 곳(온 주소에서)
    var hb: net_fields.HeaderBuilder = .{};
    var hsts = false;
    const map = api().string_multimap_alloc();
    if (map != null) {
        defer api().string_multimap_free(map);
        response.*.get_header_map.?(response, map);
        readHeaders(map, &hb, &hsts);
    }
    e.hop.hsts = hsts;
    e.hop.headers_truncated = hb.truncated;
    e.header_count = hb.count;
    // 덮기는 시작의 첫 사이트로(D1) — 다른 사이트로 옮긴 뒤의 응답(`resp_host`)은 어느 호스트든으로 덮이지 않는다.
    const ev = makeEvent(e, .{ .host = resp_host, .mime = mime, .site = sb[0..site_len], .headers = hb.block().bytes }) orelse return 0;
    enqueue(ev);
    return 0;
}

fn onResourceLoadComplete(_: [*c]c.cef_resource_request_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, response: [*c]c.cef_response_t, status: c.cef_urlrequest_status_t, received: i64) callconv(.c) void {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    defer object.releaseArg(request);
    defer object.releaseArg(response);
    if (request == null) return;
    var e: Event = .{ .kind = .end, .request = 0 };
    const id = request.*.get_identifier.?(request);
    var begun = false;
    {
        doLock();
        defer doUnlock();
        const t = state.find(id) orelse return;
        begun = t.begun;
        e.request = id;
        e.targets = t.targets;
        e.target_count = t.target_count;
        e.block_kind = t.block_kind;
        e.block_rules = t.block_rules;
        e.mock_rule = t.mock_rule; // W9d④
        e.mock_redirect_rule = t.mock_redirect_rule;
        e.mock_body_id = t.mock_body_id;
        state.untrack(t);
    }
    if (!begun) return;
    e.outcome = switch (status) {
        c.UR_SUCCESS => .success,
        c.UR_CANCELED => .canceled,
        else => .failed,
    };
    const err: i32 = if (response != null) @intCast(response.*.get_error.?(response)) else 0;
    e.error_code = if (e.outcome == .success or err > 0) 0 else err;
    e.received = @intCast(@max(received, 0));
    e.time_ms = wallMs();
    const ev = makeEvent(e, .{}) orelse return;
    enqueue(ev);
}

// ── UI 스레드: 모아서 보낸다 ────────────────────────────────────────────────────────────────────────────

/// 보낼 때의 지켜보기(잠금 밖에서 쓰는 사본 — 덮기 규칙은 `net_gate.Watch.covers`).
fn watchView(browser: BrowserId) ?gate.Watch {
    doLock();
    defer doUnlock();
    const w = state.watchOf(browser) orelse return null;
    return w.*;
}

fn flush(_: [*c]c.cef_task_t) callconv(.c) void {
    flush_posted.store(false, .release);
    var taken: std.ArrayList(*Event) = .empty;
    var drops: [gate.capacity]struct { browser: BrowserId, count: u32, sw_cap: u32 } = undefined;
    var drop_count: usize = 0;
    var marks: [gate.max_drop_marks]gate.DropMark = undefined;
    var overflowed: [gate.max_targets]BrowserId = @splat(0);
    var lost: [gate.max_lost_marks]gate.LostMark = undefined;
    var lost_overflowed: [gate.max_targets]BrowserId = @splat(0);
    doLock();
    const mark_len = state.takeDropMarks(&marks, &overflowed);
    const lost_len = state.takeLostMarks(&lost, &lost_overflowed);
    std.mem.swap(std.ArrayList(*Event), &queue, &taken);
    // 꺼낸 때 — 이 앞에 찍힌 것은 모두 꺼냈다(아래에서 표에 넘긴 뒤 물 높이로 알린다).
    const swapped_us = net_body.machUs();
    for (&state.watches) |*w| if (w.on and (w.dropped != 0 or w.dropped_sw_cap != 0)) {
        drops[drop_count] = .{ .browser = w.browser, .count = w.dropped, .sw_cap = w.dropped_sw_cap };
        drop_count += 1;
        w.dropped = 0;
        w.dropped_sw_cap = 0;
    };
    doUnlock();
    defer taken.deinit(std.heap.c_allocator);
    for (drops[0..drop_count]) |d| browsers.state.writer.send(.{ .net_dropped = .{ .browser = d.browser, .count = d.count, .sw_inflight_cap = d.sw_cap } }) catch {};
    for (marks[0..mark_len]) |m| net_body.noteDropKind(m.browser, m.url_hash, m.t_us, m.sw_cap);
    for (overflowed) |b| if (b != 0) net_body.noteDropOverflow(b, net_body.machUs());
    for (taken.items) |e| {
        for (e.targets[0..e.target_count], 0..) |b, i| send(e, b, i);
        doLock();
        state.releaseQueue(e.bytes());
        doUnlock();
        freeEvent(e);
    }
    // W9d② 적대 리뷰 5 회차 C1: 버린 리다이렉트·응답·끝 — 그 요청의 시작(후보)은 위에서 넘겼다(상자의 차례). 후보는 끝을 영영 기다리지 않는다.
    for (lost[0..lost_len]) |m| net_body.cefLostWhy(m.browser, m.request, m.evicted);
    for (lost_overflowed) |b| if (b != 0) net_body.cefLostAll(b);
    // W9d② 적대 리뷰 3 회차 P1: 꺼낸 때까지의 CEF 기록이 모두 표에 닿았다 — 제 기록을 기다리던 CDP 끝을 곧 정한다.
    net_body.cefFlushed(swapped_us - 1);
    blocking.flushHits(); // W9d③: 막기의 수(차이)
    mocking.flushHits(); // W9d④: 가짜의 수(차이)

}

/// W9d②: 보이는 규칙에 드는 칸(프레임 갈래·앞 문서·첫 사이트·initiator)의 해시 — 같은 주소의 두 후보가 이것이 다르면 짝을 잘못 지었을 때
/// 다른 규칙으로 보인다(`ambiguous`).
fn projectionAttr(flags: msg.NetFlags, site: []const u8, initiator: []const u8) u64 {
    var h = std.hash.Wyhash.init(0xa77);
    const bits = [_]u8{ @intFromBool(flags.main_frame), @intFromBool(flags.subframe), @intFromBool(flags.service_worker), @intFromBool(flags.previous_document) };
    h.update(&bits);
    h.update(site);
    h.update(&.{0});
    h.update(initiator);
    return h.final();
}

/// W9d②: CEF 의 요청 헤더에 쿠키·인증 헤더가 있다(페이지가 단 Authorization — CDP ExtraInfo 가 없을 때와 함께 쓴다, J12).
fn credentialHeaders(block: msg.NetHeaderBlock) bool {
    var it = net_fields.HeaderIterator.init(block);
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "cookie") or std.ascii.eqlIgnoreCase(h.name, "authorization") or std.ascii.eqlIgnoreCase(h.name, "proxy-authorization")) return true;
    }
    return false;
}

/// 기록 하나를 그 탭(대상 `index`)에 보낸다 — 적을 때 찍은 것과 지금의 지켜보기 중 더 덜어 내는 쪽으로(3 회차 P1c).
fn send(e: *const Event, browser: BrowserId, index: usize) void {
    const view = watchView(browser) orelse {
        // 그사이 지켜보기가 꺼졌다. 재검증 7 차: 그 탭이 아직 본문을 기록하면 이 시작은 표에 들지 않는다 — 표지를 남긴다.
        if (e.kind == .begin and e.url_hash != 0 and net_body.recording(browser)) net_body.noteDropKind(browser, e.url_hash, e.t_io_us, false);
        return;
    };
    const bit: u32 = @as(u32, 1) << @intCast(index);
    const d = view.decide(e.stamp.full & bit != 0, e.stamp.covered & bit != 0, e.host, e.site);
    var ub: [msg.max_net_url_bytes]u8 = undefined;
    var stripped: net_fields.HeaderBuilder = .{};
    const raw: msg.NetHeaderBlock = .{ .count = e.header_count, .bytes = e.headers };
    var headers = raw;
    var url = e.url;
    if (!d.full) {
        url = net_policy.stripUserinfo(e.url, &ub);
        if (url.len == 0) url = e.url[0..0];
        net_policy.stripHeaders(raw, d.covered, &stripped);
        headers = stripped.block();
    }
    const message: msg.Message = switch (e.kind) {
        .begin => blk: {
            var flags = e.flags;
            // 5 회차 B1: 새 문서가 시작된 뒤 보내는 앞 문서 iframe 의 요청 — maru 는 그 맨 위 문서를 모른다로 친다(덮지 않는 쪽).
            if (flags.subframe) if (browsers.state.registry.byId(browser)) |entry| {
                flags.previous_document = entry.net_docs.previous(e.frame);
            };
            if (!d.full) {
                flags.stripped = true;
                flags.headers_truncated = flags.headers_truncated or stripped.truncated;
            }
            if (url.len == 0) {
                // 재검증 7 차(E1 의 같은 뿌리): 보내지 못하는 시작 — 기록하는 탭이면 그 기록은 표에 들지 않는다. 넘긴 것처럼 표지를 남긴다.
                if (e.url_hash != 0 and net_body.recording(browser)) net_body.noteDropKind(browser, e.url_hash, e.t_io_us, false);
                return;
            }
            // W9d②: 기록하는 탭이면 본문 후보로 적는다 — 적었으면 이 요청의 본문 끝이 꼭 하나 온다(`body_expected`).
            // W9d④: 가짜로 고른 요청은 CDP 로 본문을 받으러 가지 않는다(`mocked` — maru 가 제 원본을 보인다).
            var flags2: msg.NetFlags2 = .{ .mocked = e.mock_first };
            if (!e.mock_first and e.url_hash != 0 and net_body.recording(browser)) {
                flags2.body_expected = net_body.cefBegin(browser, .{
                    .request = e.request,
                    .key = .{ .url = e.url_hash, .method = body_table.hashMethod(e.method), .sw = flags.service_worker },
                    .t_io_us = e.t_io_us,
                    .attr = projectionAttr(flags, e.site, e.initiator),
                    .covered = d.full or d.covered,
                    // 설정이 꺼졌으면 응답을 보낼 호스트(리다이렉트 뒤)가 정해질 때까지 받으러 가지 않는다(W9d② 적대 리뷰 1 회차 MED-1).
                    .cover_pending = !d.full,
                    .cef_credentialed = credentialHeaders(raw),
                });
            }
            break :blk .{ .net_begin = .{ .browser = browser, .request = e.request, .flags = flags, .flags2 = flags2, .resource_type = e.resource_type, .time_ms = e.time_ms, .method = e.method, .url = url, .initiator = e.initiator, .site = e.site, .host = e.url_host, .headers = headers } };
        },
        .redirect => blk: {
            var hop = e.hop;
            if (!d.full) hop.stripped = true;
            // W9d②(적대 리뷰 1 회차 MED-1): 설정이 꺼졌으면 응답 호스트가 바뀐다 — 다음 응답이 덮이는지 정할 때까지 본문을 받으러 가지 않는다.
            net_body.cefRedirect(browser, e.request, !d.full);
            if (url.len == 0) return;
            break :blk .{ .net_redirect = .{ .browser = browser, .request = e.request, .status = e.status, .flags = hop, .time_ms = e.time_ms, .url = url, .host = e.url_host, .headers = headers } };
        },
        .response => blk: {
            var hop = e.hop;
            hop.url_truncated = false;
            if (!d.full) hop.stripped = true;
            // W9d②: 설정이 꺼졌을 때 응답 호스트가 덮이지 않으면 본문도 받지 않는다(헤더를 덜어 내는 것과 같은 결정).
            net_body.cefCovered(browser, e.request, d.full or d.covered, e.status);
            break :blk .{ .net_response = .{ .browser = browser, .request = e.request, .status = e.status, .flags = hop, .time_ms = e.time_ms, .mime = e.mime, .headers = headers } };
        },
        .end => blk: {
            net_body.cefEnd(browser, e.request, e.outcome == .success, e.received); // W9d②: 짝이 없으면 시한 뒤 `unmatched`(실패·취소는 P5 의 갈림, 받은 바이트는 4 회차 N1)
            // W9d③: 막기의 표시 — 그 대상(탭)의 규칙이 있을 때만(막힌 요청은 실패로 끝났을 때만 — 표시가 권위다).
            var flags: msg.NetEndFlags = .{};
            const rule = e.block_rules[index];
            if (rule != 0) switch (e.block_kind) {
                .blocked => flags.blocked = e.outcome == .failed,
                .sw_not_applied => flags.sw_not_applied = true,
                .none => {},
            };
            var rule_id: u32 = if (flags.blocked or flags.sw_not_applied) rule else 0;
            var mock_body_id: u32 = 0;
            // W9d④: 가짜의 표시 — 막기가 이긴다(막힌 홉이 있었으면 가짜 표시는 싣지 않는다). 가짜는 탭 길(대상 하나)에만.
            if (e.block_kind == .none and index == 0) {
                flags.mocked = e.mock_rule != 0;
                flags.mock_redirected = e.mock_redirect_rule != 0;
                if (flags.mocked) rule_id = e.mock_rule else if (flags.mock_redirected) rule_id = e.mock_redirect_rule;
                if (flags.mocked) mock_body_id = e.mock_body_id;
            }
            break :blk .{ .net_end = .{ .browser = browser, .request = e.request, .outcome = e.outcome, .error_code = e.error_code, .received = e.received, .time_ms = e.time_ms, .flags = flags, .rule_id = rule_id, .mock_body_id = mock_body_id } };
        },
    };
    browsers.state.writer.send(message) catch {};
}
