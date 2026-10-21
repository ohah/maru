//! W9d③ 판정 — 실제 CEF 154 에서 요청 막기(docs/plans/web-osr-backend.md 「W9d③ 결정·실측」). 판정자가 **maru 역할**로 `net_watch`·`net_block`·
//! `navigate{user}`·`nav_action{user}` 를 보내고 `net_begin`·`net_end`(막기 표시)·`error_page`(막은 규칙)·`net_block_state`·`net_block_hits` 를
//! 모은다. 서버는 따로 띄워 **받은 요청을 모두 적는다** — 「막혔다」 는 페이지가 본 것(fetch TypeError·onerror·오류 페이지)과 서버가 그 주소를
//! 받지 않았다는 것 둘로 잰다. `127.0.0.1:<포트>` 와 `localhost:<포트>` 는 다른 사이트다.
//!
//! 탭 길(`blk1`): block-fetch·xhr·script·img·css·iframe-doc·beacon(페이지가 본 실패 + 서버가 받지 않음 + 끝의 `blocked`·규칙)·block-preflight(막힌 다른
//!   출처 PUT 의 OPTIONS 도 서버에 가지 않는다 — J-B14)·block-redirect-target(셋째 홉만 막힌다)·block-redirect-hop(주 프레임 302 의 다음 홉)·
//!   block-main-frame(에이전트 이동 — `error_page` -20·그 규칙, `url_changed` 없음)·block-error-page(Chromium 오류 페이지 글·history 하나 늚 — 관측)·
//!   block-cancel-not-used(막힌 XHR 이 곧 끝난다 — RV_CANCEL 이 아니다)·block-download(첨부 주소로의 이동은 막힘, `<a download>` 는 다운로드)·
//!   block-ws-untouched(WebSocket 은 처리기를 지나지 않는다)·block-prefetch·block-speculation-id0(번호 0 의 prefetch·prerender 요청)·
//!   block-page-context(다른 사이트에 묶인 규칙은 잠든다, 그 사이트 페이지의 다른 사이트 iframe 과 떠난 문서의 비콘에는 듣는다)·block-url-forms(조각·
//!   사용자 정보는 막힘, 경로 대소문자·`%2F` 는 문서화된 빠져나가기)·block-types(종류 단 규칙)·block-user-nav-exempt(주소창 이동·사용자 뒤로·
//!   새로고침·리다이렉트 홉은 통과, 그 페이지의 하위 자원은 막힘, 에이전트 새로고침은 막힘)·block-gate-flood(문이 떨어뜨린 요청도 막힘 —
//!   서버 0, 수)·block-devtools-guard·block-memcache-bfcache(관측)·block-hits(수의 차이).
//! 서비스 워커 길(`blksw`): block-sw-all-ruled·shared-not-applied·types-skip·empty-T·midnav·new-browser·popup·partition·cache-storage,
//!   block-navigate-op(서비스 워커 길로 막힌 이동은 -2 이지만 규칙이 붙는다)·block-user-nav-exempt-sw.
//! 공유 워커(`blkshw` — 옮긴 판 재검증 SEVERE-1, 사용자 결정 A): 공유 워커의 요청도 서비스 워커 길 — block-shw-one-tab(탭 하나·종류 없는 규칙은
//!   막고 `sw_hits`)·block-shw-types-skip(종류 규칙은 페이지만 막고 공유 워커에는 듣지 않는다)·block-shw-shared-not-applied(규칙 없는 같은 출처
//!   탭이 있으면 지나가고 `sw_not_applied`).
//! 엄격 모드(`blkstrict`): block-strict-per-tab·other-tab-untouched·same-origin-iframe·cache-to-network·reload·crosssite·site-latch·oopif-not·crash·
//!   recording-share·valve·disable-flag.
//! 엄격과 W9d② 의 전용 워커 세션(`blkstrictdw` — main 위로 옮김): block-strict-dedicated-worker-recording(기록 끔·켬에서 전용 워커 fetch 의 길이 같다).
//! 재시작(`blkrestart` — 같은 프로필로 host 를 다시 띄운다): block-restart·block-strict-restart(규칙·엄격이 첫 이동보다 먼저 선다).
//! 비용(`blkcost`): block-cost(맞지 않는 규칙 32 개로 3000 fetch — 규칙 없음보다 많아야 +10 %, 잡음 몫 60 ms).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const chunk = msg.devtools_chunk_bytes;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const wait_ms = 15_000;

// ── 서버(받은 요청을 모두 적는다) ─────────────────────────────────────────────────────────────────────────

const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const SockaddrIn = extern struct {
    len: u8 = @sizeOf(SockaddrIn),
    family: u8 = AF_INET,
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = @splat(0),
};
extern "c" fn socket(domain: c_int, kind: c_int, protocol_: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const SockaddrIn, len: u32) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
extern "c" fn getsockname(fd: c_int, addr: *SockaddrIn, len: *u32) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, name: c_int, value: *const anyopaque, len: u32) c_int;
const Timeval = extern struct { sec: i64, usec: i32 };

var port: u16 = 0;
var srv_lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
/// 받은 요청(`메서드 대상 host=…`) — 쏟아짐 끝점(`/f`)은 수만.
var srv_log: std.ArrayList(u8) = .empty;
var flood_served = std.atomic.Value(u32).init(0);

fn startServer() !void {
    if (port != 0) return;
    const fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
    if (listen(fd, 512) != 0) return error.ListenFailed;
    var len: u32 = @sizeOf(SockaddrIn);
    if (getsockname(fd, &addr, &len) != 0) return error.SocketFailed;
    port = std.mem.bigToNative(u16, addr.port);
    const t = try std.Thread.spawn(.{}, acceptLoop, .{fd});
    t.detach();
}

fn acceptLoop(fd: c_int) void {
    while (true) {
        const conn = accept(fd, null, null);
        if (conn < 0) continue;
        const timeout: Timeval = .{ .sec = 2, .usec = 0 };
        _ = setsockopt(conn, 0xffff, 0x1006, &timeout, @sizeOf(Timeval));
        const t = std.Thread.spawn(.{}, serveOne, .{conn}) catch {
            _ = std.c.close(conn);
            continue;
        };
        t.detach();
    }
}

/// 서버가 그 글을 담은 요청을 받은 수(대상·host 머리 포함).
fn seen(needle: []const u8) usize {
    _ = std.c.pthread_mutex_lock(&srv_lock);
    defer _ = std.c.pthread_mutex_unlock(&srv_lock);
    return std.mem.count(u8, srv_log.items, needle);
}

/// 그 글을 담은 마지막 요청 줄(`buf` 에 — 서비스 워커 표지 `sw=` 를 본다).
fn lastSeen(needle: []const u8, buf: []u8) []const u8 {
    _ = std.c.pthread_mutex_lock(&srv_lock);
    defer _ = std.c.pthread_mutex_unlock(&srv_lock);
    const at = std.mem.lastIndexOf(u8, srv_log.items, needle) orelse return "";
    const start = (std.mem.lastIndexOfScalar(u8, srv_log.items[0..at], '\n') orelse 0);
    const end = std.mem.indexOfScalarPos(u8, srv_log.items, at, '\n') orelse srv_log.items.len;
    const line = srv_log.items[start..end];
    const n = @min(line.len, buf.len);
    @memcpy(buf[0..n], line[0..n]);
    return buf[0..n];
}

fn reply(conn: c_int, status: []const u8, ctype: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [2048]u8 = undefined;
    const cache = if (std.mem.indexOf(u8, extra, "Cache-Control") != null) "" else "Cache-Control: no-store\r\n";
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}{s}Connection: close\r\n\r\n", .{ status, ctype, body.len, cache, extra }) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, body.ptr, body.len);
}

const html = "text/html; charset=utf-8";
/// 서비스 워커 — `/s/`·`/blk/` 아래를 네트워크로 받아 오며 `sw=<인스턴스>` 를 단다(서버 줄로 서비스 워커를 지났는지·어느 인스턴스인지 안다).
/// 이동(`mode=navigate`)은 주소를 바꾸지 않고 받아 온다 — 서비스 워커가 주소를 바꿔 받아 오는 이동은 막혀도 오류 페이지에 규칙이 붙지 않고 D2
/// 예외도 받지 못한다(계획 §6.3 — 문서화된 틈, 실측 phase 0 sw3 가 그 꼴이었다).
/// `message` 를 받으면 1.5 초 뒤 `/s/swlate` 를 부른다(탭이 모두 떠난 뒤의 요청 — block-sw-empty-T).
const sw_js =
    \\const iid=Math.random().toString(36).slice(2,8);
    \\self.addEventListener('install',e=>{self.skipWaiting();e.waitUntil(caches.open('c1').then(c=>c.add('/s/cached')))});
    \\self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
    \\self.addEventListener('message',e=>{e.waitUntil(new Promise(r=>setTimeout(()=>fetch('/s/swlate?sw='+iid).then(r,r),1500)))});
    \\self.addEventListener('fetch',e=>{const u=new URL(e.request.url);
    \\ if(e.request.mode==='navigate'){e.respondWith(fetch(e.request));return}
    \\ if(u.pathname==='/s/cached'){e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request)));return}
    \\ if(u.pathname==='/s/sw.js')return;
    \\ if(u.pathname.startsWith('/s/')||u.pathname.startsWith('/blk/')){const sep=u.search?'&':'?';
    \\  e.respondWith(fetch(u.href+sep+'sw='+iid))}});
;
const sw_reg =
    \\<script>window.swready=navigator.serviceWorker.register('/s/sw.js',{scope:'/s/'}).then(()=>navigator.serviceWorker.ready).then(()=>{
    \\ if(!navigator.serviceWorker.controller){if(!sessionStorage.rl){sessionStorage.rl=1;location.reload()}return 'nocontroller'}return 'controlled'},e=>'regerr:'+e.name+':'+e.message);
    \\</script>
;

fn serveOne(conn: c_int) void {
    defer _ = std.c.close(conn);
    while (serveReq(conn)) {}
}

fn serveReq(conn: c_int) bool {
    var req: [8192]u8 = undefined;
    const n = std.c.read(conn, &req, req.len);
    if (n <= 0) return false;
    serveParsed(conn, req[0..@intCast(n)]) catch return true;
    return false;
}

fn serveParsed(conn: c_int, r: []const u8) error{Keep}!void {
    const line_end = std.mem.indexOfScalar(u8, r, '\r') orelse return;
    var parts = std.mem.splitScalar(u8, r[0..line_end], ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    var host_hdr: []const u8 = "";
    if (std.ascii.findIgnoreCase(r, "\r\nhost: ")) |i| {
        const rest = r[i + 8 ..];
        host_hdr = rest[0 .. std.mem.indexOfScalar(u8, rest, '\r') orelse rest.len];
    }
    if (std.mem.eql(u8, path, "/f")) {
        _ = flood_served.fetchAdd(1, .monotonic);
        const resp = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n";
        _ = std.c.write(conn, resp.ptr, resp.len);
        return error.Keep;
    }
    {
        _ = std.c.pthread_mutex_lock(&srv_lock);
        defer _ = std.c.pthread_mutex_unlock(&srv_lock);
        var lb: [600]u8 = undefined;
        const line = std.fmt.bufPrint(&lb, "{s} {s} host={s}\n", .{ method, target, host_hdr }) catch "";
        srv_log.appendSlice(std.heap.c_allocator, line) catch {};
    }
    const p = port;
    var bb: [4096]u8 = undefined;
    var xb: [512]u8 = undefined;
    const svg = "<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'/>";
    if (std.mem.eql(u8, path, "/p/sub")) return reply(conn, "200 OK", html, "", "<!doctype html><title>sub</title><body>sub</body>");
    if (std.mem.eql(u8, path, "/p/userpage")) return reply(conn, "200 OK", html, "", "<!doctype html><title>userpage</title><img src='/blk/userimg'>");
    if (std.mem.eql(u8, path, "/blk/userpage")) return reply(conn, "200 OK", html, "", "<!doctype html><title>blk-userpage</title><img id=i src='/blk/userimg'>");
    if (std.mem.eql(u8, path, "/blk/s.js")) return reply(conn, "200 OK", "application/javascript", "", "window.sran=1");
    if (std.mem.eql(u8, path, "/blk/c.css")) return reply(conn, "200 OK", "text/css", "", "body{}");
    if (std.mem.startsWith(u8, path, "/blk/i") or std.mem.eql(u8, path, "/blk/target") or std.mem.startsWith(u8, path, "/typed/") or std.mem.startsWith(u8, path, "/forms") or std.mem.startsWith(u8, path, "/FORMS")) return reply(conn, "200 OK", "image/svg+xml", "Access-Control-Allow-Origin: *\r\n", svg);
    if (std.mem.eql(u8, path, "/blk/dl")) return reply(conn, "200 OK", "application/octet-stream", "Content-Disposition: attachment; filename=x.bin\r\n", "data");
    if (std.mem.eql(u8, path, "/blk/cors")) {
        if (std.mem.eql(u8, method, "OPTIONS")) return reply(conn, "204 No Content", "text/plain", "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: PUT\r\nAccess-Control-Allow-Headers: x-a\r\n", "");
        return reply(conn, "200 OK", "text/plain", "Access-Control-Allow-Origin: *\r\n", "cors");
    }
    if (std.mem.startsWith(u8, path, "/blk/") or std.mem.startsWith(u8, path, "/fl/") or std.mem.startsWith(u8, path, "/ctx/")) return reply(conn, "200 OK", html, "Access-Control-Allow-Origin: *\r\n", "<!doctype html><title>blk-reached</title>reached");
    if (std.mem.eql(u8, path, "/r/a")) return reply(conn, "301 Moved Permanently", "text/plain", "Location: /r/b\r\n", "");
    if (std.mem.eql(u8, path, "/r/b")) {
        const loc = std.fmt.bufPrint(&xb, "Location: http://localhost:{d}/blk/target\r\nAccess-Control-Allow-Origin: *\r\n", .{p}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/r/nav")) return reply(conn, "302 Found", "text/plain", "Location: /blk/navtarget\r\n", "");
    if (std.mem.eql(u8, path, "/r/user")) return reply(conn, "302 Found", "text/plain", "Location: /blk/usertarget\r\n", "");
    if (std.mem.eql(u8, path, "/c/i.png")) return reply(conn, "200 OK", "image/svg+xml", "Cache-Control: max-age=600\r\n", svg);
    if (std.mem.eql(u8, path, "/p/mc")) return reply(conn, "200 OK", html, "Cache-Control: max-age=600\r\n", "<!doctype html><title>mc</title><img id=i src='/c/i.png'><script>window.addEventListener('pageshow',e=>{window.ps=(window.ps||'')+(e.persisted?'P':'N')})</script>");
    if (std.mem.eql(u8, path, "/p/pf")) return reply(conn, "200 OK", html, "", "<!doctype html><title>pf</title><link rel=prefetch href='/blk/pf'><script type=speculationrules>{\"prerender\":[{\"source\":\"list\",\"urls\":[\"/p/pr\"]}],\"prefetch\":[{\"source\":\"list\",\"urls\":[\"/p/spf\"]}]}</script><a id=a href='/p/pr'>pr</a>");
    if (std.mem.eql(u8, path, "/p/pr") or std.mem.eql(u8, path, "/p/spf")) return reply(conn, "200 OK", html, "", "<!doctype html><title>speculated</title>");
    // 페이지 맥락(localhost 맨 위·127.0.0.1 iframe·떠날 때의 비콘).
    if (std.mem.eql(u8, path, "/x/ctxtop")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>ctxtop</title><script>window.msgs=[];addEventListener('message',e=>window.msgs.push(e.data));addEventListener('pagehide',()=>navigator.sendBeacon('http://127.0.0.1:{d}/ctx/beacon'))</script><iframe src='http://127.0.0.1:{d}/p/ctxframe'></iframe>", .{ p, p }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/p/ctxframe")) return reply(conn, "200 OK", html, "", "<!doctype html><title>ctxframe</title><script>fetch('/ctx/b').then(r=>'ok '+r.status,e=>'reject '+e.name).then(t=>parent.postMessage('ctx:'+t,'*'))</script>");
    // 서비스 워커 쪽(어느 호스트든 — 출처마다 제 서비스 워커).
    if (std.mem.eql(u8, path, "/s/sw.js")) return reply(conn, "200 OK", "application/javascript", "", sw_js);
    if (std.mem.eql(u8, path, "/s/cached")) return reply(conn, "200 OK", "text/plain", "", "server-cached");
    if (std.mem.startsWith(u8, path, "/s/page")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>swpage</title>{s}<iframe id=inner src='/s/inner'></iframe><div id=t>{s}</div>", .{ sw_reg, target }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    // 옮김(2026-11-11): 전용 워커 — 쿼리 `p` 의 주소를 fetch 해 결과를 돌려준다(`strictDedicatedWorker`).
    if (std.mem.eql(u8, path, "/s/dw.js")) return reply(conn, "200 OK", "application/javascript", "", "const p=new URL(location.href).searchParams.get('p');fetch(p+'?n='+Math.random()).then(r=>r.text()).then(t=>postMessage('ok '+t),e=>postMessage('reject '+e.name))");
    if (std.mem.eql(u8, path, "/s/inner")) return reply(conn, "200 OK", html, "", "<!doctype html><title>inner</title>inner");
    // 옮긴 판 재검증 SEVERE-1(2026-11-11): 공유 워커 — 쿼리 `u` 의 주소를 fetch 해 그 결과를 붙은 포트로 돌려준다(`sharedWorkerPath`).
    if (std.mem.eql(u8, path, "/shw/w.js")) return reply(conn, "200 OK", "application/javascript", "", "const u=new URL(location.href).searchParams.get('u');onconnect=e=>{const pt=e.ports[0];fetch(u).then(r=>pt.postMessage('ok '+r.status),x=>pt.postMessage('reject '+x.name))}");
    if (std.mem.eql(u8, path, "/s/framed")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>framed</title>{s}<script>window.swready.then(s=>{{if(s==='controlled')fetch('/s/fromframe?'+Date.now()).then(r=>r.text()).then(t=>parent.postMessage('framed:'+t,'*'),e=>parent.postMessage('framed-reject:'+e.name,'*'))}})</script>", .{sw_reg}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.startsWith(u8, path, "/s/")) return reply(conn, "200 OK", "text/plain", "", target);
    if (std.mem.eql(u8, path, "/x/top")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>xtop</title><script>window.msgs=[];addEventListener('message',e=>window.msgs.push(e.data))</script><iframe src='http://127.0.0.1:{d}/s/framed'></iframe>", .{p}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/x/blank")) return reply(conn, "200 OK", html, "", "<!doctype html><title>xblank</title>x");
    if (std.mem.eql(u8, path, "/v20b/json")) return reply(conn, "200 OK", "application/json", "Cache-Control: no-store\r\n", "{\"v20b\":[1,2,3],\"s\":\"body-ok\"}"); // v20b R19
    return reply(conn, "200 OK", "text/plain", "", "x");
}

// ── 판정자(maru 역할) ──────────────────────────────────────────────────────────────────────────────────────

const max_tabs = 16;

const End = struct { browser: u64 = 0, request: u64 = 0, url: [256]u8 = undefined, url_len: usize = 0, ended: bool = false, flags: msg.NetEndFlags = .{}, rule: u32 = 0, error_code: i32 = 0 };
const Hit = struct { browser: u64, rule: u32, hits: u64 = 0, sw_hits: u64 = 0, sw_not_applied: u64 = 0 };
const ErrPage = struct { browser: u64, code: i32, rule: u32 };

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    next_call: u32 = 100,
    result: std.ArrayList(u8) = .empty,
    created: [max_tabs]bool = @splat(false),
    loads: [max_tabs]u32 = @splat(0),
    urls: [max_tabs]u32 = @splat(0),
    state_gen: [max_tabs]u32 = @splat(0),
    state_ok: [max_tabs]bool = @splat(false),
    strict: [max_tabs]msg.NetStrictState = @splat(.off),
    unrecorded: [max_tabs]u64 = @splat(0),
    skipped: [max_tabs]u64 = @splat(0),
    shared: [max_tabs]bool = @splat(false),
    reqs: std.ArrayList(End) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    errors: std.ArrayList(ErrPage) = .empty,
    downloads: u32 = 0,
    record_state: [max_tabs]msg.NetRecordStatus = @splat(.off),
    gen: u32 = 0,
    // v20b R19: 본문 조각(요청 번호·바이트)과 끝 상태.
    v20b_bodies: std.ArrayList(u8) = .empty,
    v20b_body_chunks: std.ArrayList(struct { request: u64, start: usize, len: usize }) = .empty,
    v20b_body_ends: std.ArrayList(struct { request: u64, state: msg.NetBodyState }) = .empty,

    fn take(self: *Run, m: msg.Message) void {
        switch (m) {
            .browser_created => |id| if (id < max_tabs) {
                self.created[id] = true;
            },
            .load_finished => |v| if (v.browser < max_tabs) {
                self.loads[v.browser] += 1;
            },
            .url_changed => |v| if (v.browser < max_tabs) {
                self.urls[v.browser] += 1;
            },
            .error_page => |v| self.errors.append(self.gpa, .{ .browser = v.browser, .code = v.error_code, .rule = v.blocked_rule }) catch {},
            .net_block_state => |v| if (v.browser < max_tabs) {
                self.state_gen[v.browser] = v.generation;
                self.state_ok[v.browser] = v.ok;
                self.strict[v.browser] = v.strict;
            },
            .net_block_hits => |v| if (v.browser < max_tabs) {
                self.unrecorded[v.browser] += v.unrecorded;
                self.skipped[v.browser] += v.skipped_unknown_page;
                if (v.sw_shared_with_unruled_tab) self.shared[v.browser] = true;
                for (v.entries[0..v.count]) |e| {
                    const h = for (self.hits.items) |*h| {
                        if (h.browser == v.browser and h.rule == e.rule_id) break h;
                    } else blk: {
                        self.hits.append(self.gpa, .{ .browser = v.browser, .rule = e.rule_id }) catch return;
                        break :blk &self.hits.items[self.hits.items.len - 1];
                    };
                    h.hits += e.hits;
                    h.sw_hits += e.sw_hits;
                    h.sw_not_applied += e.sw_not_applied;
                }
            },
            .net_begin => |v| {
                var e: End = .{ .browser = v.browser, .request = v.request };
                const n = @min(v.url.len, e.url.len);
                @memcpy(e.url[0..n], v.url[0..n]);
                e.url_len = n;
                self.reqs.append(self.gpa, e) catch {};
            },
            .net_end => |v| {
                var i = self.reqs.items.len;
                while (i > 0) {
                    i -= 1;
                    const e = &self.reqs.items[i];
                    if (e.browser == v.browser and e.request == v.request and !e.ended) {
                        e.ended = true;
                        e.flags = v.flags;
                        e.rule = v.rule_id;
                        e.error_code = v.error_code;
                        break;
                    }
                }
            },
            .download_begin => self.downloads += 1,
            .popup_created => |v| if (v.browser < max_tabs) {
                self.created[v.browser] = true;
            },
            .net_record_state => |v| if (v.browser < max_tabs) {
                self.record_state[v.browser] = v.status;
            },
            .net_body_data => |v| {
                self.v20b_body_chunks.append(self.gpa, .{ .request = v.request, .start = self.v20b_bodies.items.len, .len = v.bytes.len }) catch {};
                self.v20b_bodies.appendSlice(self.gpa, v.bytes) catch {};
            },
            .net_body_end => |v| self.v20b_body_ends.append(self.gpa, .{ .request = v.request, .state = v.state }) catch {},
            else => {},
        }
    }

    fn pump(self: *Run, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            const m = (self.host.next(20) catch null) orelse continue;
            self.take(m);
        }
    }

    fn until(self: *Run, comptime cond: fn (*Run, u64, u32) bool, b: u64, want: u32, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline and !cond(self, b, want)) {
            const m = (self.host.next(50) catch null) orelse continue;
            self.take(m);
        }
        return cond(self, b, want);
    }

    fn loadsAt(self: *Run, b: u64, want: u32) bool {
        return self.loads[b] >= want;
    }
    fn stateAt(self: *Run, b: u64, want: u32) bool {
        return self.state_gen[b] == want;
    }
    fn strictSettled(self: *Run, b: u64, want: u32) bool {
        return self.state_gen[b] == want and self.strict[b] != .off;
    }

    fn create(self: *Run, b: u64, u: []const u8) !void {
        try self.host.send(.{ .create_browser = .{ .browser = b, .size = .{ .width = 640, .height = 400, .scale = 1 }, .hidden = false, .url = u } });
        const deadline = os.nowMs() + wait_ms;
        while (os.nowMs() < deadline and !self.created[b]) {
            const m = (self.host.next(50) catch null) orelse continue;
            self.take(m);
        }
        _ = self.until(loadsAt, b, 1, wait_ms);
    }

    fn nav(self: *Run, b: u64, u: []const u8, user: bool) !void {
        const before = self.loads[b];
        try self.host.send(.{ .navigate = .{ .browser = b, .url = u, .user = user } });
        _ = self.until(loadsAt, b, before + 1, wait_ms);
        self.pump(150);
    }

    fn action(self: *Run, b: u64, a: msg.NavActionKind, user: bool) !void {
        const before = self.loads[b];
        try self.host.send(.{ .nav_action = .{ .browser = b, .action = a, .user = user } });
        _ = self.until(loadsAt, b, before + 1, wait_ms);
        self.pump(150);
    }

    fn watch(self: *Run, b: u64) !void {
        try self.host.send(.{ .net_watch = .{ .browser = b, .on = true, .full = true, .any_host = true } });
        self.pump(50);
    }

    /// 규칙(`pattern`·`site`·종류)을 통째로 보낸다 — 답(그 세대)을 기다린다. 엄격이면 엄격 상태가 정해질 때까지.
    fn block(self: *Run, b: u64, rules: []const msg.NetBlockRule, strict_site: []const u8) !bool {
        self.gen += 1;
        var v: msg.NetBlock = .{ .browser = b, .generation = self.gen, .strict_site = strict_site, .count = @intCast(rules.len) };
        for (rules, 0..) |r, i| v.rules[i] = r;
        try self.host.send(.{ .net_block = v });
        const got = if (strict_site.len != 0) self.until(strictSettled, b, self.gen, wait_ms) else self.until(stateAt, b, self.gen, wait_ms);
        return got and self.state_ok[b];
    }

    fn hitOf(self: *Run, b: u64, rule: u32) Hit {
        self.pump(80);
        for (self.hits.items) |h| if (h.browser == b and h.rule == rule) return h;
        return .{ .browser = b, .rule = rule };
    }

    /// 그 탭에서 주소에 그 글을 담은 마지막 요청의 끝.
    fn endOf(self: *Run, b: u64, needle: []const u8) ?End {
        var i = self.reqs.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.reqs.items[i];
            if (e.browser == b and std.mem.indexOf(u8, e.url[0..e.url_len], needle) != null) return e;
        }
        return null;
    }

    fn lastError(self: *Run, b: u64) ?ErrPage {
        var i = self.errors.items.len;
        while (i > 0) {
            i -= 1;
            if (self.errors.items[i].browser == b) return self.errors.items[i];
        }
        return null;
    }

    fn call(self: *Run, browser: u64, method: []const u8, params: []const u8, ms: u32) !?msg.DevtoolsStatus {
        self.next_call += 1;
        const id = self.next_call;
        try self.host.send(.{ .devtools_call = .{ .browser = browser, .call = id, .method = method, .params_size = @intCast(params.len) } });
        var off: usize = 0;
        while (off < params.len) {
            const k = @min(chunk, params.len - off);
            try self.host.send(.{ .devtools_call_data = .{ .browser = browser, .call = id, .bytes = params[off..][0..k] } });
            off += k;
        }
        self.result.clearRetainingCapacity();
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            const m = (self.host.next(50) catch null) orelse continue;
            switch (m) {
                .devtools_result_data => |v| if (v.call == id) {
                    try self.result.appendSlice(self.gpa, v.bytes);
                    continue;
                },
                .devtools_result => |v| if (v.call == id) return v.status,
                else => {},
            }
            self.take(m);
        }
        return null;
    }

    /// 주 프레임에서 식을 돌려 글로(문자열·수·참거짓). 실패면 `<…>`.
    fn ev(self: *Run, browser: u64, expr: []const u8, out: []u8) []const u8 {
        return self.evAs(browser, expr, out, false);
    }

    /// `gesture` — 사용자 몸짓으로 돌린다(`window.open` 이 팝업을 만들게).
    fn evAs(self: *Run, browser: u64, expr: []const u8, out: []u8, gesture: bool) []const u8 {
        var pb: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&pb);
        w.writeAll(if (gesture) "{\"userGesture\":true,\"returnByValue\":true,\"awaitPromise\":true,\"expression\":" else "{\"returnByValue\":true,\"awaitPromise\":true,\"expression\":") catch return "<arg>";
        std.json.Stringify.value(expr, .{}, &w) catch return "<arg>";
        w.writeAll("}") catch return "<arg>";
        const st = self.call(browser, "Runtime.evaluate", w.buffered(), 20_000) catch null;
        if (st == null or st.? != .ok) return std.fmt.bufPrint(out, "<{s}>", .{if (st) |s| @tagName(s) else "timeout"}) catch "<>";
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, self.result.items, .{}) catch return "<unparsed>";
        defer parsed.deinit();
        const res = parsed.value.object.get("result") orelse return "<noresult>";
        const v = res.object.get("value") orelse return "<novalue>";
        return switch (v) {
            .string => |s| std.fmt.bufPrint(out, "{s}", .{s[0..@min(s.len, out.len)]}) catch "<long>",
            .bool => |b| if (b) "true" else "false",
            .integer => |k| std.fmt.bufPrint(out, "{d}", .{k}) catch "<n>",
            .float => |f| std.fmt.bufPrint(out, "{d}", .{f}) catch "<n>",
            else => "<other>",
        };
    }
};

fn uLoop(buf: []u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, path }) catch unreachable;
}

fn uLocal(buf: []u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://localhost:{d}{s}", .{ port, path }) catch unreachable;
}

/// 규칙 패턴(정규형 — 포트를 담는다).
fn pat(buf: []u8, host: []const u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://{s}:{d}{s}", .{ host, port, path }) catch unreachable;
}

const js_fetch_head = "(async()=>{const t=performance.now();try{const r=await fetch(";
const js_fetch_tail = ");return 'ok '+r.status+' '+(await r.text()).slice(0,120)}catch(e){return 'reject '+e.name}})()";

fn fetchExpr(buf: []u8, u: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}'{s}'{s}", .{ js_fetch_head, u, js_fetch_tail }) catch unreachable;
}

fn imgExpr(buf: []u8, u: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "new Promise(res=>{{const i=new Image();i.onload=()=>res('load');i.onerror=()=>res('error');i.src='{s}';setTimeout(()=>res('timeout'),5000)}})", .{u}) catch unreachable;
}

fn starts(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

fn spawn(host_path: [:0]const u8, root: []const u8, name: []const u8, env: []const [*:0]const u8) !Host {
    var prof_buf: [1024]u8 = undefined;
    const profile = try std.fmt.bufPrintSentinel(&prof_buf, "--profile-dir={s}/{s}", .{ root, name }, 0);
    var host = try Host.spawnWith(host_path, profile, null, env);
    try browsers_check.handshake(&host);
    return host;
}

fn stop(host: *Host) void {
    host.send(.shutdown) catch {};
    while (host.next(2000) catch null) |_| {}
    if (host.wait(20_000) == null) {
        _ = std.c.kill(host.pid, .KILL);
        _ = host.wait(10_000);
    }
}

pub fn run(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    tabPath(report, host_path, root) catch |err| report(false, "block-tab-path", @errorName(err));
    serviceWorkerPath(report, host_path, root) catch |err| report(false, "block-sw", @errorName(err));
    sharedWorkerPath(report, host_path, root) catch |err| report(false, "block-shw", @errorName(err));
    strictMode(report, host_path, root) catch |err| report(false, "block-strict", @errorName(err));
    strictDedicatedWorker(report, host_path, root) catch |err| report(false, "block-strict-dedicated-worker", @errorName(err));
    restart(report, host_path, root) catch |err| report(false, "block-restart", @errorName(err));
    cost(report, host_path, root) catch |err| report(false, "block-cost", @errorName(err));
}

// ── 탭 길 ─────────────────────────────────────────────────────────────────────────────────────────────────

fn tabPath(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "blk1", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [512]u8 = undefined;
    var p1: [128]u8 = undefined;
    var p2: [128]u8 = undefined;
    var p3: [128]u8 = undefined;
    var p4: [128]u8 = undefined;
    var p5: [128]u8 = undefined;
    var p6: [128]u8 = undefined;
    var p7: [128]u8 = undefined;
    var p8: [128]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    const rules = [_]msg.NetBlockRule{
        .{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/blk/*") },
        .{ .id = 2, .site = "127.0.0.1", .pattern = pat(&p2, "localhost", "/blk/*") },
        .{ .id = 3, .types = protocol.net_block.typeBits("image").?, .site = "127.0.0.1", .pattern = pat(&p3, "127.0.0.1", "/typed/*") },
        .{ .id = 4, .site = "127.0.0.1", .pattern = pat(&p4, "127.0.0.1", "/p/pr") },
        .{ .id = 5, .site = "127.0.0.1", .pattern = pat(&p5, "127.0.0.1", "/p/spf") },
        .{ .id = 6, .site = "localhost", .pattern = pat(&p6, "127.0.0.1", "/ctx/*") },
        .{ .id = 7, .site = "127.0.0.1", .pattern = pat(&p7, "127.0.0.1", "/forms/*") },
        .{ .id = 8, .site = "127.0.0.1", .pattern = pat(&p8, "127.0.0.1", "/fl/*") },
    };
    const applied = try r.block(1, &rules, "");
    report(applied, "block-rules-applied", "net_block 세대 1 — ok");

    // 하위 자원 갈래마다: 페이지가 본 실패 + 서버가 받지 않음 + 끝의 표시.
    const Sub = struct { name: []const u8, path: []const u8, expr: []const u8, want_prefix: []const u8 };
    const subs = [_]Sub{
        .{ .name = "block-fetch", .path = "/blk/f1", .expr = "", .want_prefix = "reject TypeError" },
        .{ .name = "block-xhr", .path = "/blk/x1", .expr = "new Promise(res=>{const x=new XMLHttpRequest();x.open('GET','/blk/x1');x.onload=()=>res('load '+x.status);x.onerror=()=>res('error '+x.status);x.send();setTimeout(()=>res('timeout'),5000)})", .want_prefix = "error 0" },
        .{ .name = "block-script", .path = "/blk/s.js", .expr = "new Promise(res=>{const s=document.createElement('script');s.src='/blk/s.js';s.onload=()=>res('load');s.onerror=()=>res('error');document.head.appendChild(s);setTimeout(()=>res('timeout'),5000)})", .want_prefix = "error" },
        .{ .name = "block-img", .path = "/blk/i1.png", .expr = "", .want_prefix = "error" },
        .{ .name = "block-css", .path = "/blk/c.css", .expr = "new Promise(res=>{const l=document.createElement('link');l.rel='stylesheet';l.href='/blk/c.css';l.onload=()=>res('load');l.onerror=()=>res('error');document.head.appendChild(l);setTimeout(()=>res('timeout'),5000)})", .want_prefix = "error" },
        .{ .name = "block-iframe-doc", .path = "/blk/frame", .expr = "new Promise(res=>{const f=document.createElement('iframe');f.src='/blk/frame';f.onload=()=>{let t;try{t=f.contentDocument?'doc':'nodoc'}catch(e){t='cross'}res('load '+t)};document.body.appendChild(f);setTimeout(()=>res('timeout'),5000)})", .want_prefix = "load " },
        .{ .name = "block-beacon", .path = "/blk/beacon", .expr = "String(navigator.sendBeacon('/blk/beacon','x'))", .want_prefix = "true" },
    };
    for (subs) |s| {
        const before = seen(s.path);
        const t0 = os.nowMs();
        const expr = if (std.mem.eql(u8, s.name, "block-fetch")) fetchExpr(&x, s.path) else if (std.mem.eql(u8, s.name, "block-img")) imgExpr(&x, s.path) else s.expr;
        const got = r.ev(1, expr, &o);
        const ms = os.nowMs() - t0;
        r.pump(400);
        const e = r.endOf(1, s.path);
        const flagged = if (e) |v| v.ended and v.flags.blocked and v.rule == 1 and v.error_code == -20 else false;
        const ok = starts(got, s.want_prefix) and seen(s.path) == before and flagged;
        report(ok, s.name, std.fmt.bufPrint(&d, "페이지 {s} ({d} ms) · 서버 {d} · 끝 blocked·규칙 1·-20 {}", .{ got, ms, seen(s.path) - before, flagged }) catch "");
        // RV_CANCEL 이 아님 — 막힌 XHR 이 곧 끝난다(RV_CANCEL 은 XHR 을 영영 붙잡았다 — 실측 m2.1).
        if (std.mem.eql(u8, s.name, "block-xhr")) report(starts(got, "error") and ms < 3000, "block-cancel-not-used", std.fmt.bufPrint(&d, "막힌 XHR 이 {d} ms 에 onerror", .{ms}) catch "");
    }
    // 종류 단 규칙 — 이미지만.
    {
        const img = r.ev(1, imgExpr(&x, "/typed/a.png"), &o);
        var o2: [600]u8 = undefined;
        const f = r.ev(1, fetchExpr(&x, "/typed/b.png"), &o2);
        report(std.mem.eql(u8, img, "error") and starts(f, "ok 200") and seen("/typed/a.png") == 0 and seen("/typed/b.png") == 1, "block-types", std.fmt.bufPrint(&d, "image 규칙: 이미지 {s} · fetch {s}", .{ img, f }) catch "");
    }
    // preflight — 막힌 다른 출처 PUT 은 OPTIONS 도 가지 않는다(J-B14).
    {
        var cu: [400]u8 = undefined;
        const cors = std.fmt.bufPrint(&cu, "(async()=>{{try{{const r=await fetch('http://localhost:{d}/blk/cors',{{method:'PUT',headers:{{'X-A':'1'}}}});return 'ok '+r.status}}catch(e){{return 'reject '+e.name}}}})()", .{port}) catch unreachable;
        const got = r.ev(1, cors, &o);
        r.pump(300);
        report(starts(got, "reject") and seen("/blk/cors") == 0, "block-preflight", std.fmt.bufPrint(&d, "{s} · 서버 OPTIONS·PUT {d}", .{ got, seen("/blk/cors") }) catch "");
    }
    // 리다이렉트 대상 — /r/a 301 → /r/b 302 → localhost/blk/target 의 셋째 홉만.
    {
        const got = r.ev(1, fetchExpr(&x, "/r/a"), &o);
        r.pump(400);
        report(starts(got, "reject") and seen("/r/a ") == 1 and seen("/r/b ") == 1 and seen("/blk/target") == 0, "block-redirect-target", std.fmt.bufPrint(&d, "{s} · 서버 /r/a {d} /r/b {d} 대상 {d}", .{ got, seen("/r/a "), seen("/r/b "), seen("/blk/target") }) catch "");
    }
    // 페이지 맥락 — 규칙 6(사이트 localhost)은 127.0.0.1 페이지에서 잠든다.
    {
        const got = r.ev(1, fetchExpr(&x, "/ctx/a"), &o);
        report(starts(got, "ok 200") and seen("/ctx/a") == 1, "block-page-context-dormant", std.fmt.bufPrint(&d, "127.0.0.1 페이지의 /ctx/a {s}", .{got}) catch "");
    }
    // URL 꼴 — 조각·사용자 정보는 막힌다, 경로 대소문자·%2F 는 빠져나간다(문서화).
    {
        var ua: [256]u8 = undefined;
        var ub: [256]u8 = undefined;
        const frag = r.ev(1, imgExpr(&x, "/forms/a#frag"), &o);
        var ob: [600]u8 = undefined;
        const userinfo = r.ev(1, imgExpr(&x, std.fmt.bufPrint(&ua, "http://u:p@127.0.0.1:{d}/forms/b", .{port}) catch unreachable), &ob);
        var oc: [600]u8 = undefined;
        const upper = r.ev(1, imgExpr(&x, "/FORMS/c"), &oc);
        var od: [600]u8 = undefined;
        const esc = r.ev(1, imgExpr(&x, std.fmt.bufPrint(&ub, "/forms%2Fd", .{}) catch unreachable), &od);
        const ok = std.mem.eql(u8, frag, "error") and std.mem.eql(u8, userinfo, "error") and seen("/forms/a") == 0 and seen("/forms/b") == 0 and std.mem.eql(u8, upper, "load") and std.mem.eql(u8, esc, "load");
        report(ok, "block-url-forms", std.fmt.bufPrint(&d, "조각 {s} · 사용자 정보 {s} · 대문자 경로 {s}(빠져나감) · %2F {s}(빠져나감)", .{ frag, userinfo, upper, esc }) catch "");
    }
    // 수 — 탭 길 막음이 규칙 1 에 쌓였다.
    {
        const h = r.hitOf(1, 1);
        report(h.hits >= 7, "block-hits", std.fmt.bufPrint(&d, "규칙 1 hits {d}(막은 하위 자원 7 이상)", .{h.hits}) catch "");
    }
    // DevTools 지킴.
    {
        const a = r.call(1, "Network.setBypassServiceWorker", "{\"bypass\":true}", 5000) catch null;
        const b = r.call(1, "Network.setBlockedURLs", "{\"urls\":[\"*\"]}", 5000) catch null;
        const c = r.call(1, "Network.setRequestInterception", "{\"patterns\":[]}", 5000) catch null;
        const e = r.call(1, "Network.emulateNetworkConditions", "{\"offline\":true,\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}", 5000) catch null;
        const all = a == .invalid_request and b == .invalid_request and c == .invalid_request and e == .invalid_request;
        report(all, "block-devtools-guard", std.fmt.bufPrint(&d, "setBypassServiceWorker {?} · setBlockedURLs {?} · setRequestInterception {?} · emulateNetworkConditions {?}", .{ a, b, c, e }) catch "");
    }
    // 문이 떨어뜨린 요청도 막는다 — 1500 fetch(탭 버스트 500).
    {
        const got = r.ev(1, "(async()=>{const ps=[];for(let i=0;i<1500;i++)ps.push(fetch('/fl/'+i).then(()=>1,()=>0));return String((await Promise.all(ps)).reduce((a,c)=>a+c,0))})()", &o);
        r.pump(1500);
        const h = r.hitOf(1, 8);
        report(std.mem.eql(u8, got, "0") and seen("/fl/") == 0 and h.hits >= 1500 and r.unrecorded[1] > 0, "block-gate-flood", std.fmt.bufPrint(&d, "성공 {s} · 서버 {d} · 규칙 hits {d} · 기록 없이 막음 {d}", .{ got, seen("/fl/"), h.hits, r.unrecorded[1] }) catch "");
    }
    // 주 프레임 — 에이전트 이동(사용자 아님).
    {
        const urls_before = r.urls[1];
        const hist_before = r.ev(1, "String(history.length)", &o);
        var hb: [32]u8 = undefined;
        @memcpy(hb[0..hist_before.len], hist_before);
        try r.nav(1, uLoop(&u, "/blk/main"), false);
        r.pump(800);
        const ep = r.lastError(1);
        const ok = ep != null and ep.?.code == -20 and ep.?.rule == 1 and r.urls[1] == urls_before and seen("/blk/main") == 0;
        report(ok, "block-main-frame", std.fmt.bufPrint(&d, "error_page {?d}·규칙 {?d} · url_changed {d} · 서버 {d}", .{ if (ep) |v| v.code else null, if (ep) |v| v.rule else null, r.urls[1] - urls_before, seen("/blk/main") }) catch "");
        report(ok, "block-navigate-op", "탭 길 막힘 — error_page 가 규칙을 싣는다(-20)");
        var o2: [600]u8 = undefined;
        const view = r.ev(1, "document.title+' | '+(document.body?document.body.innerText.replace(/\\s+/g,' ').slice(0,160):'')+' | hist='+history.length", &o2);
        report(std.mem.indexOf(u8, view, "ERR_BLOCKED_BY_CLIENT") != null, "block-error-page", std.fmt.bufPrint(&d, "{s} (앞 history {s})", .{ view, hb[0..hist_before.len] }) catch "");
    }
    // 주 프레임 리다이렉트의 다음 홉.
    {
        try r.nav(1, uLoop(&u, "/p/sub?r1"), false);
        try r.nav(1, uLoop(&u, "/r/nav"), false);
        r.pump(800);
        const ep = r.lastError(1);
        report(ep != null and ep.?.rule == 1 and seen("/r/nav") == 1 and seen("/blk/navtarget") == 0, "block-redirect-hop", std.fmt.bufPrint(&d, "error_page 규칙 {?d} · 서버 /r/nav {d} 대상 {d}", .{ if (ep) |v| v.rule else null, seen("/r/nav"), seen("/blk/navtarget") }) catch "");
    }
    // 다운로드 — 첨부 주소로의 이동은 막히고, `<a download>` 은 다운로드(못 막음 — 문서화).
    {
        try r.nav(1, uLoop(&u, "/p/sub?r2"), false);
        const dl_before = r.downloads;
        try r.nav(1, uLoop(&u, "/blk/dl"), false);
        r.pump(800);
        const nav_blocked = seen("/blk/dl ") == 0 and r.downloads == dl_before;
        try r.nav(1, uLoop(&u, "/p/sub?r3"), false);
        _ = r.ev(1, "(()=>{const a=document.createElement('a');a.href='/blk/dl?attr';a.download='y.bin';document.body.appendChild(a);a.click();return 'clicked'})()", &o);
        r.pump(2000);
        report(nav_blocked and r.downloads > dl_before, "block-download", std.fmt.bufPrint(&d, "이동 막힘 {} · <a download> 다운로드 {d}", .{ nav_blocked, r.downloads - dl_before }) catch "");
    }
    // WebSocket 은 처리기를 지나지 않는다(못 막음).
    {
        var wu: [256]u8 = undefined;
        const ws = std.fmt.bufPrint(&wu, "new Promise(res=>{{const w=new WebSocket('ws://127.0.0.1:{d}/blk/ws');w.onerror=()=>res('error');w.onopen=()=>res('open');setTimeout(()=>res('timeout'),3000)}})", .{port}) catch unreachable;
        _ = r.ev(1, ws, &o);
        r.pump(300);
        report(seen("/blk/ws") >= 1, "block-ws-untouched", std.fmt.bufPrint(&d, "서버가 업그레이드 요청을 받았다 {d}", .{seen("/blk/ws")}) catch "");
    }
    // prefetch·speculation(번호 0) — 규칙 1·4·5.
    {
        try r.nav(1, uLoop(&u, "/p/pf"), false);
        r.pump(3000);
        report(seen("/blk/pf") == 0, "block-prefetch", std.fmt.bufPrint(&d, "<link rel=prefetch> 서버 {d}", .{seen("/blk/pf")}) catch "");
        report(seen("/p/spf") == 0 and seen("/p/pr ") == 0, "block-speculation-id0", std.fmt.bufPrint(&d, "speculation prefetch 서버 {d} · prerender 서버 {d}", .{ seen("/p/spf"), seen("/p/pr ") }) catch "");
    }
    // 페이지 맥락 — localhost 페이지의 127.0.0.1 iframe(첫 사이트 = localhost)에는 듣고, 떠난 문서의 비콘에도(J-B9).
    {
        try r.nav(1, uLocal(&u, "/x/ctxtop"), false);
        r.pump(1500);
        const msgs = r.ev(1, "JSON.stringify(window.msgs)", &o);
        const iframe_blocked = std.mem.indexOf(u8, msgs, "ctx:reject") != null and seen("/ctx/b") == 0;
        try r.nav(1, uLoop(&u, "/p/sub?r4"), false);
        r.pump(800);
        report(iframe_blocked and seen("/ctx/beacon") == 0, "block-page-context", std.fmt.bufPrint(&d, "localhost 의 127.0.0.1 iframe {s} · 떠난 문서 비콘 서버 {d}", .{ msgs, seen("/ctx/beacon") }) catch "");
    }
    // D2 — 주소창 이동·사용자 뒤로·새로고침·리다이렉트 홉은 통과, 그 페이지의 하위 자원은 막힘, 에이전트 새로고침은 막힘.
    {
        const errors_before = r.errors.items.len;
        try r.nav(1, uLoop(&u, "/blk/userpage"), true);
        r.pump(800);
        const typed = seen("/blk/userpage") == 1 and seen("/blk/userimg") == 0;
        try r.nav(1, uLoop(&u, "/r/user"), true);
        r.pump(600);
        const hop = seen("/blk/usertarget") == 1;
        try r.nav(1, uLoop(&u, "/p/sub?r5"), false);
        try r.action(1, .back, true);
        r.pump(600);
        const back = seen("/blk/usertarget") == 2;
        try r.action(1, .reload, true);
        r.pump(600);
        const reload = seen("/blk/usertarget") == 3;
        const errs_user = r.errors.items.len - errors_before;
        try r.action(1, .reload, false);
        r.pump(800);
        const agent_reload_blocked = seen("/blk/usertarget") == 3 and r.errors.items.len > errors_before + errs_user;
        report(typed and hop and back and reload and errs_user == 0 and agent_reload_blocked, "block-user-nav-exempt", std.fmt.bufPrint(&d, "주소창 {} (하위 자원 막힘) · 리다이렉트 홉 {} · 뒤로 {} · 새로고침 {} · 사용자 오류 페이지 {d} · 에이전트 새로고침 막힘 {}", .{ typed, hop, back, reload, errs_user, agent_reload_blocked }) catch "");
    }
    // 메모리 캐시·bfcache(관측 — 처리기를 지나지 않는다).
    {
        try r.nav(1, uLoop(&u, "/p/mc"), false);
        r.pump(500);
        var pc: [128]u8 = undefined;
        _ = try r.block(1, &(rules ++ [_]msg.NetBlockRule{.{ .id = 9, .site = "127.0.0.1", .pattern = pat(&pc, "127.0.0.1", "/c/i.png") }}), "");
        const mem = r.ev(1, imgExpr(&x, "/c/i.png"), &o);
        var o2: [600]u8 = undefined;
        const http_cache = r.ev(1, "fetch('/c/i.png').then(r=>'ok '+r.status,e=>'reject '+e.name)", &o2);
        report(true, "block-memcache-bfcache(obs)", std.fmt.bufPrint(&d, "같은 문서의 이미지 다시 쓰기 {s}(메모리 캐시 — 못 막음) · fetch 의 HTTP 캐시 {s}", .{ mem, http_cache }) catch "");
        _ = try r.block(1, &rules, "");
    }
}

// ── 서비스 워커 길 ─────────────────────────────────────────────────────────────────────────────────────────

fn swReady(r: *Run, b: u64) []const u8 {
    var o: [128]u8 = undefined;
    _ = r.ev(b, "window.swready", &o);
    _ = r.until(Run.loadsAt, b, r.loads[b] + 1, 3000);
    r.pump(400);
    var o2: [64]u8 = undefined;
    const c = r.ev(b, "String(!!navigator.serviceWorker.controller)", &o2);
    return if (std.mem.eql(u8, c, "true")) "controlled" else "not-controlled";
}

fn serviceWorkerPath(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "blksw", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [700]u8 = undefined;
    var p1: [128]u8 = undefined;
    var p2: [128]u8 = undefined;
    var p3: [128]u8 = undefined;
    var lb: [600]u8 = undefined;
    // A=1·B=2 — 같은 서비스 워커(127.0.0.1).
    try r.create(1, uLoop(&u, "/s/page?A"));
    const a_ctl = swReady(&r, 1);
    try r.create(2, uLoop(&u, "/s/page?B"));
    const b_ctl = swReady(&r, 2);
    try r.watch(1);
    try r.watch(2);
    const rule_a = [_]msg.NetBlockRule{
        .{ .id = 11, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/s/swblk*") },
        .{ .id = 12, .types = protocol.net_block.typeBits("xhr").?, .site = "127.0.0.1", .pattern = pat(&p2, "127.0.0.1", "/s/typed*") },
        .{ .id = 13, .site = "127.0.0.1", .pattern = pat(&p3, "127.0.0.1", "/s/cached") },
    };
    var q1: [128]u8 = undefined;
    var q2: [128]u8 = undefined;
    const rule_b = [_]msg.NetBlockRule{
        .{ .id = 21, .site = "127.0.0.1", .pattern = pat(&q1, "127.0.0.1", "/s/swblk*") },
        .{ .id = 22, .types = protocol.net_block.typeBits("xhr").?, .site = "127.0.0.1", .pattern = pat(&q2, "127.0.0.1", "/s/typed*") },
    };
    _ = try r.block(1, &rule_a, "");
    _ = try r.block(2, &rule_b, "");
    // 모두 쥠 — 막는다.
    {
        const got = r.ev(1, fetchExpr(&x, "/s/swblk1"), &o);
        r.pump(400);
        const h = r.hitOf(1, 11);
        const hb = r.hitOf(2, 21);
        report(starts(got, "reject") and seen("/s/swblk1") == 0 and h.sw_hits >= 1 and hb.sw_hits >= 1, "block-sw-all-ruled", std.fmt.bufPrint(&d, "A {s}·B {s} · fetch {s} · 서버 {d} · sw_hits A {d} B {d}", .{ a_ctl, b_ctl, got, seen("/s/swblk1"), h.sw_hits, hb.sw_hits }) catch "");
    }
    // 종류 단 규칙은 서비스 워커 길에 듣지 않는다.
    {
        const got = r.ev(1, fetchExpr(&x, "/s/typed1"), &o);
        report(starts(got, "ok 200") and seen("/s/typed1") == 1, "block-sw-types-skip", std.fmt.bufPrint(&d, "xhr 규칙(두 탭) — 서비스 워커 길 fetch {s}", .{got}) catch "");
    }
    // Cache Storage 로 답한 것은 어디에도 오지 않는다(못 막음 — 문서화).
    {
        const got = r.ev(1, fetchExpr(&x, "/s/cached"), &o);
        report(starts(got, "ok 200 server-cached"), "block-sw-cache-storage(obs)", std.fmt.bufPrint(&d, "규칙 13 이 있어도 캐시 응답 {s}", .{got}) catch "");
    }
    // B 의 규칙을 지우면 — 적용 안 됨(막지 않고 센다).
    {
        _ = try r.block(2, &.{}, "");
        const got = r.ev(1, fetchExpr(&x, "/s/swblk2"), &o);
        r.pump(500);
        const h = r.hitOf(1, 11);
        const e = r.endOf(1, "/s/swblk2");
        const flagged = if (e) |v| v.flags.sw_not_applied and v.rule == 11 else false;
        report(starts(got, "ok 200") and seen("/s/swblk2") == 1 and h.sw_not_applied >= 1 and r.shared[1], "block-sw-shared-not-applied", std.fmt.bufPrint(&d, "fetch {s} · sw_not_applied {d} · 나눔 표시 {} · 끝 표시 {}", .{ got, h.sw_not_applied, r.shared[1], flagged }) catch "");
        _ = try r.block(2, &rule_b, "");
    }
    // 옮기는 중인 탭(D: localhost → 127.0.0.1/s/page2) — 진행 중 이동이 T 에 든다(규칙 없음 → 막지 않는다).
    {
        try r.create(4, uLocal(&u, "/x/blank"));
        var pm: [128]u8 = undefined;
        _ = try r.block(1, &(rule_a ++ [_]msg.NetBlockRule{.{ .id = 14, .site = "127.0.0.1", .pattern = pat(&pm, "127.0.0.1", "/s/page2*") }}), "");
        _ = try r.block(2, &(rule_b ++ [_]msg.NetBlockRule{.{ .id = 24, .site = "127.0.0.1", .pattern = pat(&pm, "127.0.0.1", "/s/page2*") }}), "");
        try r.nav(4, uLoop(&u, "/s/page2?D"), false);
        r.pump(800);
        const title = r.ev(4, "document.title", &o);
        report(std.mem.eql(u8, title, "swpage") and seen("/s/page2?D") >= 1, "block-sw-midnav", std.fmt.bufPrint(&d, "D 의 이동(서비스 워커가 받아 옴) {s} · 서버 {d}", .{ title, seen("/s/page2?D") }) catch "");
        // 새 브라우저의 첫 이동(주소가 빈 프레임 — 모름).
        try r.create(5, uLoop(&u, "/s/page2?E"));
        r.pump(800);
        var o2: [64]u8 = undefined;
        const te = r.ev(5, "document.title", &o2);
        report(std.mem.eql(u8, te, "swpage"), "block-sw-new-browser", std.fmt.bufPrint(&d, "새 브라우저 E 의 첫 이동 {s}", .{te}) catch "");
        try r.host.send(.{ .destroy_browser = 4 });
        try r.host.send(.{ .destroy_browser = 5 });
        r.pump(800);
        _ = try r.block(1, &rule_a, "");
        _ = try r.block(2, &rule_b, "");
    }
    // 분할 — localhost 맨 위의 127.0.0.1 iframe 은 다른 서비스 워커(인스턴스가 다르다), 그 탭은 규칙 없음 → 막지 않는다.
    {
        try r.create(3, uLocal(&u, "/x/top"));
        r.pump(3500);
        const msgs = r.ev(3, "JSON.stringify(window.msgs)", &o);
        const a_line = lastSeen("/s/swblk2", &lb);
        var lb2: [600]u8 = undefined;
        const c_line = lastSeen("/s/fromframe", &lb2);
        const iid_a = if (std.mem.indexOf(u8, a_line, "sw=")) |i| a_line[i..@min(a_line.len, i + 9)] else "";
        const iid_c = if (std.mem.indexOf(u8, c_line, "sw=")) |i| c_line[i..@min(c_line.len, i + 9)] else "";
        report(std.mem.indexOf(u8, msgs, "framed:") != null and iid_a.len > 0 and iid_c.len > 0 and !std.mem.eql(u8, iid_a, iid_c), "block-sw-partition", std.fmt.bufPrint(&d, "iframe {s} · 인스턴스 A {s} · iframe {s}", .{ msgs, iid_a, iid_c }) catch "");
        // C 가 127.0.0.1 을 보이는 동안은 A·B 가 모두 쥐어도 막지 않는다(거부권 — 보수적 「어느 프레임이든」).
        const got = r.ev(1, fetchExpr(&x, "/s/swblk3"), &o);
        report(starts(got, "ok 200"), "block-sw-partition-veto", std.fmt.bufPrint(&d, "C 의 iframe 이 127.0.0.1 을 보인다 — A fetch {s}", .{got}) catch "");
        try r.host.send(.{ .destroy_browser = 3 });
        r.pump(800);
    }
    // 입양 전 팝업 — 같은 출처를 보이는 팝업 브라우저(규칙 없음)는 거부권.
    {
        try r.host.send(.{ .popup_reserve = .{ .browser = 9 } });
        try r.host.send(.{ .new_tab_credit = 1 }); // maru 가 에이전트 탭에 주는 새 탭 장(그 몸짓으로 팝업을 만든다)
        r.pump(100);
        _ = r.evAs(1, "(window.open('/s/page?pop','_blank','popup,width=300,height=300'),'opened')", &o, true);
        r.pump(2500);
        const popup = r.created[9] or seen("/s/page?pop") > 0;
        const got = r.ev(1, fetchExpr(&x, "/s/swblk4"), &o);
        report(popup and starts(got, "ok 200"), "block-sw-popup", std.fmt.bufPrint(&d, "팝업(입양 전 — 서버 {d})이 같은 출처 — A fetch {s}", .{ seen("/s/page?pop"), got }) catch "");
        try r.host.send(.{ .destroy_browser = 9 });
        r.pump(800);
    }
    // 서비스 워커 길로 막힌 이동(-2)에도 규칙이 붙는다(§6.3).
    {
        const errs = r.errors.items.len;
        _ = r.ev(1, "(location.href='/s/swblknav','sent')", &o);
        _ = r.until(Run.loadsAt, 1, r.loads[1] + 1, wait_ms);
        r.pump(1200);
        const ep = r.lastError(1);
        report(r.errors.items.len > errs and ep != null and ep.?.rule == 11 and seen("/s/swblknav") == 0, "block-navigate-op-sw", std.fmt.bufPrint(&d, "error_page {?d}·규칙 {?d} · 서버 {d}", .{ if (ep) |v| v.code else null, if (ep) |v| v.rule else null, seen("/s/swblknav") }) catch "");
        try r.nav(1, uLoop(&u, "/s/page?A2"), true);
        r.pump(500);
    }
    // 사용자가 친 이동은 서비스 워커 길에서도 통과(D2 — §6.2-8).
    {
        try r.nav(1, uLoop(&u, "/s/swblkuser"), true);
        r.pump(800);
        report(seen("/s/swblkuser") >= 1, "block-user-nav-exempt-sw", std.fmt.bufPrint(&d, "주소창 이동(서비스 워커가 받아 옴) 서버 {d}", .{seen("/s/swblkuser")}) catch "");
        try r.nav(1, uLoop(&u, "/s/page?A3"), true);
        r.pump(500);
    }
    // 빈 T — 탭이 모두 떠난 뒤 서비스 워커만 남은 요청은 막지 않는다.
    {
        var rl: [128]u8 = undefined;
        _ = try r.block(1, &(rule_a ++ [_]msg.NetBlockRule{.{ .id = 15, .site = "127.0.0.1", .pattern = pat(&rl, "127.0.0.1", "/s/swlate*") }}), "");
        _ = r.ev(1, "(navigator.serviceWorker.controller.postMessage('late'),'posted')", &o);
        try r.nav(1, uLocal(&u, "/x/blank"), false);
        try r.nav(2, uLocal(&u, "/x/blank"), false);
        r.pump(2500);
        report(seen("/s/swlate") >= 1, "block-sw-empty-T", std.fmt.bufPrint(&d, "탭이 떠난 뒤의 서비스 워커 요청 서버 {d}", .{seen("/s/swlate")}) catch "");
    }
}

// ── 공유 워커(옮긴 판 재검증 SEVERE-1 — 사용자 결정 A, 2026-11-11) ──────────────────────────────────────────
// 공유 워커가 낸 요청은 서비스 워커의 요청처럼 브라우저가 없는 요청이라(CEF 가 둘을 가르지 않는다) 서비스 워커 길로 판정한다 — 그 출처를 보이는
// 모든 탭이 맞는 종류 없는 규칙을 쥘 때만 막고, 종류 있는 규칙은 듣지 않는다. 문서(`control-plane-browser.md` `browser.networkBlock`)대로의 동작을
// 못 박는다. 워커는 부를 때마다 주소가 달라 새로 뜬다.

fn sharedWorkerExpr(buf: []u8, u: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "new Promise(res=>{{const w=new SharedWorker('/shw/w.js?u='+encodeURIComponent('{s}'));w.port.onmessage=e=>res(String(e.data));w.port.start();w.onerror=()=>res('error');setTimeout(()=>res('timeout'),6000)}})", .{u}) catch unreachable;
}

fn sharedWorkerPath(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "blkshw", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var o2: [600]u8 = undefined;
    var d: [700]u8 = undefined;
    var p1: [128]u8 = undefined;
    var p2: [128]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub?shw1"));
    try r.watch(1);
    const rules = [_]msg.NetBlockRule{
        .{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/blk/shw*") },
        .{ .id = 2, .types = protocol.net_block.typeBits("xhr").?, .site = "127.0.0.1", .pattern = pat(&p2, "127.0.0.1", "/tx/*") },
    };
    const applied = try r.block(1, &rules, "");
    // (b) 탭 하나 — 종류 없는 규칙은 공유 워커의 fetch 도 막고 서비스 워커 수(`sw_hits`)로 센다.
    {
        const before = r.hitOf(1, 1).sw_hits;
        const got = r.ev(1, sharedWorkerExpr(&x, "/blk/shw-one"), &o);
        r.pump(600);
        const h = r.hitOf(1, 1);
        report(applied and starts(got, "reject") and seen("/blk/shw-one") == 0 and h.sw_hits > before, "block-shw-one-tab", std.fmt.bufPrint(&d, "규칙 세대 {} · 공유 워커 fetch {s} · 서버 {d} · 규칙 1 sw_hits +{d}", .{ applied, got, seen("/blk/shw-one"), h.sw_hits - before }) catch "");
    }
    // (c) 탭 하나 — 종류 있는 규칙(xhr)은 페이지의 fetch 는 막지만 공유 워커의 fetch 에는 듣지 않는다.
    {
        const page = r.ev(1, fetchExpr(&x, "/tx/page"), &o);
        const got = r.ev(1, sharedWorkerExpr(&x, "/tx/shw"), &o2);
        r.pump(400);
        report(starts(page, "reject") and seen("/tx/page") == 0 and starts(got, "ok 200") and seen("/tx/shw") == 1, "block-shw-types-skip", std.fmt.bufPrint(&d, "xhr 규칙 — 페이지 fetch {s}(서버 {d}) · 공유 워커 fetch {s}(서버 {d})", .{ page, seen("/tx/page"), got, seen("/tx/shw") }) catch "");
    }
    // (a) 규칙 없는 탭 2 가 같은 출처를 보이면 — 막지 않고 「적용 안 됨」 으로 센다(탭 1 이 만든 워커여도). 페이지의 fetch 는 여전히 막힌다(대조).
    {
        try r.create(2, uLoop(&u, "/p/sub?shw2"));
        try r.watch(2);
        const before = r.hitOf(1, 1).sw_not_applied;
        const page = r.ev(1, fetchExpr(&x, "/blk/shw-page"), &o);
        const got = r.ev(1, sharedWorkerExpr(&x, "/blk/shw-two"), &o2);
        r.pump(600);
        const h = r.hitOf(1, 1);
        report(starts(page, "reject") and seen("/blk/shw-page") == 0 and starts(got, "ok 200") and seen("/blk/shw-two") == 1 and h.sw_not_applied > before and r.shared[1], "block-shw-shared-not-applied", std.fmt.bufPrint(&d, "페이지 fetch {s}(서버 {d}) · 공유 워커 fetch {s}(서버 {d}) · 규칙 1 sw_not_applied +{d} · 나눔 표시 {}", .{ page, seen("/blk/shw-page"), got, seen("/blk/shw-two"), h.sw_not_applied - before, r.shared[1] }) catch "");
    }
}

// ── 엄격 모드 ─────────────────────────────────────────────────────────────────────────────────────────────

/// 서버 줄로 서비스 워커를 지났는가(`sw=`) — 지나지 않았으면 탭 길(엄격).
fn viaServiceWorker(path: []const u8) bool {
    var lb: [600]u8 = undefined;
    return std.mem.indexOf(u8, lastSeen(path, &lb), "sw=") != null;
}

fn strictMode(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "blkstrict", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [700]u8 = undefined;
    var p1: [128]u8 = undefined;
    try r.create(1, uLoop(&u, "/s/page?SA"));
    const a_ctl = swReady(&r, 1);
    try r.create(2, uLoop(&u, "/s/page?SB"));
    _ = swReady(&r, 2);
    try r.watch(1);
    try r.watch(2);
    const rules = [_]msg.NetBlockRule{.{ .id = 31, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/s/st*") }};
    const on = try r.block(1, &rules, "127.0.0.1");
    report(on and r.strict[1] == .on, "block-strict-on", std.fmt.bufPrint(&d, "엄격 상태 {s} · A {s}", .{ @tagName(r.strict[1]), a_ctl }) catch "");
    {
        const got = r.ev(1, fetchExpr(&x, "/s/st1"), &o);
        r.pump(400);
        const e = r.endOf(1, "/s/st1");
        report(starts(got, "reject") and seen("/s/st1") == 0 and e != null and e.?.flags.blocked, "block-strict-per-tab", std.fmt.bufPrint(&d, "엄격 탭 A 의 fetch(탭 길로) {s} · 서버 {d}", .{ got, seen("/s/st1") }) catch "");
    }
    {
        const got = r.ev(2, fetchExpr(&x, "/s/other1"), &o);
        report(starts(got, "ok 200") and viaServiceWorker("/s/other1"), "block-strict-other-tab-untouched", std.fmt.bufPrint(&d, "B(같은 서비스 워커) fetch {s} · 서비스 워커를 지남 {}", .{ got, viaServiceWorker("/s/other1") }) catch "");
    }
    {
        const got = r.ev(1, "frames[0].fetch('/s/inner2').then(r=>r.text(),e=>'reject '+e.name)", &o);
        report(!starts(got, "reject") and !viaServiceWorker("/s/inner2") and seen("/s/inner2") == 1, "block-strict-same-origin-iframe", std.fmt.bufPrint(&d, "같은 출처 iframe fetch {s} · 서비스 워커를 지남 {}", .{ got, viaServiceWorker("/s/inner2") }) catch "");
    }
    {
        const before = seen("/s/cached");
        const got = r.ev(1, fetchExpr(&x, "/s/cached"), &o);
        report(starts(got, "ok 200") and seen("/s/cached") > before, "block-strict-cache-to-network", std.fmt.bufPrint(&d, "Cache Storage 주소가 네트워크로 {s} · 서버 +{d}", .{ got, seen("/s/cached") - before }) catch "");
    }
    {
        try r.action(1, .reload, false);
        r.pump(500);
        const ctl = r.ev(1, "String(!!navigator.serviceWorker.controller)", &o);
        var o2: [600]u8 = undefined;
        const got = r.ev(1, fetchExpr(&x, "/s/r1"), &o2);
        report(std.mem.eql(u8, ctl, "false") and starts(got, "ok 200") and !viaServiceWorker("/s/r1"), "block-strict-reload", std.fmt.bufPrint(&d, "새로고침 뒤 다스림 {s} · fetch 서비스 워커를 지남 {}", .{ ctl, viaServiceWorker("/s/r1") }) catch "");
    }
    // 사이트 묶기 — 다른 사이트(localhost)에서는 그 사이트의 서비스 워커가 다스린다, 돌아오면 다시 우회.
    {
        try r.nav(1, uLocal(&u, "/s/page?L"), false);
        const l_ctl = swReady(&r, 1);
        var o2: [600]u8 = undefined;
        const lf = r.ev(1, fetchExpr(&x, "/s/l1"), &o2);
        const latch_off = std.mem.eql(u8, l_ctl, "controlled") and viaServiceWorker("/s/l1");
        report(latch_off and starts(lf, "ok"), "block-strict-site-latch", std.fmt.bufPrint(&d, "localhost 에서 {s} · fetch 서비스 워커를 지남 {}", .{ l_ctl, viaServiceWorker("/s/l1") }) catch "");
        try r.nav(1, uLoop(&u, "/s/page?back"), false);
        r.pump(500);
        const ctl = r.ev(1, "String(!!navigator.serviceWorker.controller)", &o);
        var o3: [600]u8 = undefined;
        const got = r.ev(1, fetchExpr(&x, "/s/c1"), &o3);
        report(std.mem.eql(u8, ctl, "false") and starts(got, "ok 200") and !viaServiceWorker("/s/c1"), "block-strict-crosssite", std.fmt.bufPrint(&d, "돌아온 뒤 다스림 {s} · fetch 서비스 워커를 지남 {}", .{ ctl, viaServiceWorker("/s/c1") }) catch "");
    }
    // 다른 사이트 OOPIF 는 덮지 않는다 — 엄격 사이트 localhost 로 localhost 맨 위에 127.0.0.1 iframe(분할 서비스 워커).
    {
        _ = try r.block(1, &rules, "localhost");
        try r.nav(1, uLocal(&u, "/x/top?SA"), false);
        r.pump(3500);
        const msgs = r.ev(1, "JSON.stringify(window.msgs)", &o);
        report(std.mem.indexOf(u8, msgs, "sw=") != null, "block-strict-oopif-not", std.fmt.bufPrint(&d, "엄격(localhost) 탭의 127.0.0.1 iframe fetch {s}", .{msgs}) catch "");
        _ = try r.block(1, &rules, "127.0.0.1");
        try r.nav(1, uLoop(&u, "/s/page?back2"), false);
        r.pump(500);
    }
    // 렌더러 죽음 뒤에도 유지.
    {
        _ = r.call(1, "Page.crash", "{}", 3000) catch null;
        r.pump(1500);
        try r.action(1, .reload, false);
        r.pump(800);
        const got = r.ev(1, fetchExpr(&x, "/s/k1"), &o);
        report(starts(got, "ok 200") and !viaServiceWorker("/s/k1"), "block-strict-crash", std.fmt.bufPrint(&d, "Page.crash·새로고침 뒤 fetch {s} · 서비스 워커를 지남 {}", .{ got, viaServiceWorker("/s/k1") }) catch "");
    }
    // 기록과 나눔 — 본문 기록을 켰다 끄면 엄격은 그대로(기록의 disable 이 엄격을 말없이 멈추지 않는다).
    {
        try r.host.send(.{ .net_record = .{ .browser = 1, .on = true, .session = 5 } });
        r.pump(800);
        try r.host.send(.{ .net_record = .{ .browser = 1, .on = false } });
        r.pump(500);
        try r.action(1, .reload, false);
        r.pump(500);
        const ctl = r.ev(1, "String(!!navigator.serviceWorker.controller)", &o);
        var o2: [600]u8 = undefined;
        const got = r.ev(1, fetchExpr(&x, "/s/rec1"), &o2);
        report(std.mem.eql(u8, ctl, "false") and starts(got, "ok 200") and !viaServiceWorker("/s/rec1"), "block-strict-recording-share", std.fmt.bufPrint(&d, "기록 켬·끔 뒤 다스림 {s} · fetch 서비스 워커를 지남 {}", .{ ctl, viaServiceWorker("/s/rec1") }) catch "");
    }
    // 쏟아짐 밸브 — 기록만 멈추고 엄격은 그대로.
    {
        try r.host.send(.{ .net_record = .{ .browser = 1, .on = true, .session = 6 } });
        r.pump(800);
        _ = r.ev(1, "(async()=>{for(let k=0;k<4;k++){const ps=[];for(let i=0;i<2500;i++)ps.push(fetch('/f?'+k+'_'+i).then(()=>1,()=>0));await Promise.all(ps)}return 'done'})()", &o);
        r.pump(1500);
        const paused = r.record_state[1] == .paused;
        try r.action(1, .reload, false);
        r.pump(500);
        var o2: [600]u8 = undefined;
        const got = r.ev(1, fetchExpr(&x, "/s/v1"), &o2);
        report(starts(got, "ok 200") and !viaServiceWorker("/s/v1"), if (paused) "block-strict-valve" else "block-strict-valve(obs)", std.fmt.bufPrint(&d, "기록 상태 {s} · 그 뒤 fetch 서비스 워커를 지남 {}", .{ @tagName(r.record_state[1]), viaServiceWorker("/s/v1") }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = 1, .on = false } });
        r.pump(300);
    }
    // 끔은 `bypass:false` 먼저 — 그 뒤 기록이 Network 를 다시 켜도 엄격이 되살아나지 않는다(sw2).
    {
        _ = try r.block(1, &rules, "");
        try r.host.send(.{ .net_record = .{ .browser = 1, .on = true, .session = 7 } });
        r.pump(800);
        try r.action(1, .reload, false);
        _ = swReady(&r, 1);
        const ctl = r.ev(1, "String(!!navigator.serviceWorker.controller)", &o);
        var o2: [600]u8 = undefined;
        const got = r.ev(1, fetchExpr(&x, "/s/off1"), &o2);
        report(std.mem.eql(u8, ctl, "true") and starts(got, "ok 200") and viaServiceWorker("/s/off1") and r.strict[1] == .off, "block-strict-disable-flag", std.fmt.bufPrint(&d, "엄격 끔 → 기록 켬 뒤 다스림 {s} · fetch 서비스 워커를 지남 {}", .{ ctl, viaServiceWorker("/s/off1") }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = 1, .on = false } });
        r.pump(300);
    }
}

// ── 엄격 모드와 W9d② 의 전용 워커 세션(main 위로 옮김, 2026-11-11) ──────────────────────────────────────────

/// W9d② 재검증 12 차부터 기록 중인 탭은 새로 뜨는 서비스 워커와 **전용 워커**를 멈춰 붙이고(`Target.setAutoAttach` 의 filter `swdw`) 그 세션에
/// `Network.enable` 을 보낸다. 엄격 모드의 `setBypassServiceWorker` 는 페이지 세션에만 보낸다 — 붙인 워커 세션이 그 워커의 fetch 가 서비스 워커를
/// 지나는지를 바꾸지 않는가(옮김 뒤 처음 재는 상호작용). 다스리는 문서에서 만든 전용 워커의 fetch 를 기록 끔·켬으로 한 번씩 재고, 둘이 같아야
/// 통과한다. 양의 대조로 엄격을 켜기 전 같은 워커의 fetch 가 서비스 워커를 지나는지 먼저 본다(실측 2026-11-11: 켜기 전 지남, 켠 뒤 기록 끔·켬 모두
/// 지나지 않음 — 엄격이 다스리는 문서의 전용 워커도 덮는다, 계획 「main 위로 옮김」).
fn strictDedicatedWorker(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    // 판정자 환경의 `MARU_WEB_TEST_BODY_LOG` 를 넘기면 전용 워커 세션이 붙었는지(`body: sw-attached … type=worker`)를 stderr 로 본다(판정 아님).
    const log_env: []const [*:0]const u8 = if (std.c.getenv("MARU_WEB_TEST_BODY_LOG") != null) &.{"MARU_WEB_TEST_BODY_LOG=1"} else &.{};
    var host = try spawn(host_path, root, "blkstrictdw", log_env);
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [900]u8 = undefined;
    var p1: [128]u8 = undefined;
    try r.create(1, uLoop(&u, "/s/page?DW"));
    const ctl = swReady(&r, 1);
    try r.watch(1);
    // 양의 대조: 엄격을 켜기 전에는 그 전용 워커의 fetch 가 서비스 워커를 지난다(지나지 않으면 아래 비교는 아무것도 재지 않는다).
    var ctl_got: [96]u8 = undefined;
    var ctl_len: usize = 0;
    {
        var o: [600]u8 = undefined;
        const g = r.ev(1, "new Promise(res=>{const w=new Worker('/s/dw.js?p=/s/dwc');w.onmessage=e=>res(e.data);setTimeout(()=>res('timeout'),5000)})", &o);
        ctl_len = @min(g.len, ctl_got.len);
        @memcpy(ctl_got[0..ctl_len], g[0..ctl_len]);
    }
    const via_ctl = viaServiceWorker("/s/dwc");
    const rules = [_]msg.NetBlockRule{.{ .id = 51, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/s/zz*") }};
    const on = try r.block(1, &rules, "127.0.0.1");
    var via: [2]bool = .{ false, false };
    var page_via: [2]bool = .{ true, true };
    var got: [2][96]u8 = undefined;
    var got_len: [2]usize = .{ 0, 0 };
    var rec_on = false;
    for (0..2) |k| {
        if (k == 1) {
            try r.host.send(.{ .net_record = .{ .browser = 1, .on = true, .session = 9 } });
            r.pump(1000);
            rec_on = r.record_state[1] == .on;
        }
        var jb: [400]u8 = undefined;
        const js = std.fmt.bufPrint(&jb, "new Promise(res=>{{const w=new Worker('/s/dw.js?p=/s/dwf{d}');w.onmessage=e=>res(e.data);setTimeout(()=>res('timeout'),5000)}})", .{k}) catch "";
        var o: [600]u8 = undefined;
        const g = r.ev(1, js, &o);
        got_len[k] = @min(g.len, got[k].len);
        @memcpy(got[k][0..got_len[k]], g[0..got_len[k]]);
        var pb: [16]u8 = undefined;
        via[k] = viaServiceWorker(std.fmt.bufPrint(&pb, "/s/dwf{d}", .{k}) catch "");
        var x: [256]u8 = undefined;
        var o2: [600]u8 = undefined;
        _ = r.ev(1, fetchExpr(&x, std.fmt.bufPrint(&pb, "/s/dpg{d}", .{k}) catch ""), &o2);
        page_via[k] = viaServiceWorker(std.fmt.bufPrint(&pb, "/s/dpg{d}", .{k}) catch "");
    }
    try r.host.send(.{ .net_record = .{ .browser = 1, .on = false } });
    r.pump(300);
    const ok0 = starts(got[0][0..got_len[0]], "ok");
    const ok1 = starts(got[1][0..got_len[1]], "ok");
    report(on and r.strict[1] == .on and std.mem.eql(u8, ctl, "controlled") and via_ctl and starts(ctl_got[0..ctl_len], "ok") and rec_on and ok0 and ok1 and via[0] == via[1] and !page_via[0] and !page_via[1], "block-strict-dedicated-worker-recording", std.fmt.bufPrint(&d, "다스림 {s} · 엄격 전 전용 워커 fetch 서비스 워커를 지남 {} ({s}) · 기록 켬 {} · 전용 워커 fetch 서비스 워커를 지남: 기록 끔 {} ({s}) · 켬 {} ({s}) · 페이지 fetch 지남 {}/{}", .{ ctl, via_ctl, ctl_got[0..ctl_len], rec_on, via[0], got[0][0..got_len[0]], via[1], got[1][0..got_len[1]], page_via[0], page_via[1] }) catch "");
}

// ── 재시작(같은 프로필로 host 를 다시 띄운다) ─────────────────────────────────────────────────────────────

fn restart(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [512]u8 = undefined;
    var p1: [128]u8 = undefined;
    // 먼저 서비스 워커를 등록해 둔다.
    {
        var host = try spawn(host_path, root, "blkrestart", &.{});
        var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
        try r.create(1, uLoop(&u, "/s/page?R0"));
        _ = swReady(&r, 1);
        _ = std.c.kill(host.pid, .KILL); // sidecar 가 죽는다(maru 는 다시 띄운다)
        _ = host.wait(10_000);
    }
    var host = try spawn(host_path, root, "blkrestart", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    // maru 의 차례: browser_created → net_watch → (net_record) → net_block → navigate(last_url).
    try r.host.send(.{ .create_browser = .{ .browser = 1, .size = .{ .width = 640, .height = 400, .scale = 1 }, .hidden = false, .url = "about:blank" } });
    _ = r.until(Run.loadsAt, 1, 1, wait_ms);
    try r.watch(1);
    const rules = [_]msg.NetBlockRule{.{ .id = 41, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/blk/*") }};
    var v: msg.NetBlock = .{ .browser = 1, .generation = 1, .strict_site = "127.0.0.1", .count = 1 };
    v.rules[0] = rules[0];
    try r.host.send(.{ .net_block = v });
    try r.host.send(.{ .navigate = .{ .browser = 1, .url = uLoop(&u, "/blk/after-restart") } });
    _ = r.until(Run.loadsAt, 1, 2, wait_ms);
    r.pump(800);
    const ep = r.lastError(1);
    report(seen("/blk/after-restart") == 0 and ep != null and ep.?.rule == 41, "block-restart", std.fmt.bufPrint(&d, "다시 뜬 sidecar 의 재생 이동 — 서버 {d} · error_page 규칙 {?d}", .{ seen("/blk/after-restart"), if (ep) |e| e.rule else null }) catch "");
    try r.nav(1, uLoop(&u, "/s/page?R1"), false);
    r.pump(800);
    const ctl = r.ev(1, "String(!!navigator.serviceWorker.controller)", &o);
    var o2: [600]u8 = undefined;
    const got = r.ev(1, fetchExpr(&x, "/s/rs1"), &o2);
    report(r.strict[1] == .on and std.mem.eql(u8, ctl, "false") and starts(got, "ok 200") and !viaServiceWorker("/s/rs1"), "block-strict-restart", std.fmt.bufPrint(&d, "엄격 {s} · 다스림 {s} · fetch 서비스 워커를 지남 {}", .{ @tagName(r.strict[1]), ctl, viaServiceWorker("/s/rs1") }) catch "");
}

// ── 비용 ──────────────────────────────────────────────────────────────────────────────────────────────────

fn floodMs(r: *Run) i64 {
    var o: [128]u8 = undefined;
    const got = r.ev(1, "(async()=>{const t=performance.now();for(let b=0;b<30;b++){const ps=[];for(let i=0;i<100;i++)ps.push(fetch('/f?'+b+'_'+i).then(()=>1,()=>0));await Promise.all(ps)}return String(Math.round(performance.now()-t))})()", &o);
    return std.fmt.parseInt(i64, got, 10) catch 999_999;
}

fn cost(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "blkcost", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [256]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    _ = floodMs(&r); // 데우기
    var base: i64 = std.math.maxInt(i64);
    for (0..3) |_| base = @min(base, floodMs(&r));
    var bufs: [32][128]u8 = undefined;
    var rules: [32]msg.NetBlockRule = undefined;
    for (&rules, 0..) |*rule, i| rule.* = .{ .id = @intCast(100 + i), .site = "127.0.0.1", .pattern = std.fmt.bufPrint(&bufs[i], "http://127.0.0.1:{d}/nomatch-{d:0>2}/*x*y", .{ port, i }) catch unreachable };
    _ = try r.block(1, &rules, "");
    var with: i64 = std.math.maxInt(i64);
    for (0..3) |_| with = @min(with, floodMs(&r));
    report(with <= @divTrunc(base * 110, 100) + 60, "block-cost", std.fmt.bufPrint(&d, "3000 fetch — 규칙 없음 {d} ms · 맞지 않는 규칙 32 {d} ms(가장 빠른 셋 중 하나)", .{ base, with }) catch "");
}

// ── W9d③ 20 회 적대 검증 11–20 회차(검증자 B) — `--review-block-v20b` ──────────────────────────────────────────

pub fn runV20b(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    v20bTab(report, host_path, root) catch |err| report(false, "v20b-tab", @errorName(err));
    v20bGuard(report, host_path, root) catch |err| report(false, "v20b-guard", @errorName(err));
    v20bRestart(report, host_path, root) catch |err| report(false, "v20b-restart", @errorName(err));
    v20bCost(report, host_path, root) catch |err| report(false, "v20b-cost", @errorName(err));
    v20b2Guard(report, host_path, root) catch |err| report(false, "v20b2-guard", @errorName(err));
}

// ── W9d③ 2 차 검증 NEW-1(검증자 B2 — 6077ecc4c): DevTools 지킴은 바깥 메서드 이름만 봤다 — `Target.attachToTarget{flatten:false}` +
// `Target.sendMessageToTarget` 이 실은 `Network.setBlockedURLs` 가 fetch 를 막았다(서버 0). 고친 뒤: `Target.*` 는 `getTargetInfo`(maru 가 쓰는 읽기)
// 말고 모두 `invalid_request`, 그 길로는 아무 효과가 없다(대조: 지킴이 막는 이름 그대로).
fn v20b2Guard(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "v20b2guard", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [4096]u8 = undefined;
    var o: [1200]u8 = undefined;
    var line: [8192]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line);
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    r.pump(500);
    var ok = true;
    {
        const st = r.call(1, "Network.setBlockedURLs", "{\"urls\":[\"*v20b2/c0*\"]}", 5000) catch null;
        const got = r.ev(1, fetchExpr(&x, "/v20b2/c0"), &o);
        if (st == null or st.? != .invalid_request or !starts(got, "ok")) ok = false;
        lw.print("control Network.setBlockedURLs → {s} · fetch {s} · server {d}\n", .{ if (st) |v| @tagName(v) else "timeout", got, seen("/v20b2/c0") }) catch {};
    }
    // 읽기 하나는 남는다(저장소 op 의 출처 확인).
    var tid_buf: [80]u8 = undefined;
    var tid: []const u8 = "";
    {
        const st = r.call(1, "Target.getTargetInfo", "{}", 5000) catch null;
        const res = r.result.items;
        if (std.mem.indexOf(u8, res, "\"targetId\":\"")) |i| {
            const start = i + 12;
            if (std.mem.indexOfScalarPos(u8, res, start, '"')) |end| if (end - start <= tid_buf.len) {
                @memcpy(tid_buf[0 .. end - start], res[start..end]);
                tid = tid_buf[0 .. end - start];
            };
        }
        if (st == null or st.? != .ok or tid.len == 0) ok = false;
        lw.print("Target.getTargetInfo → {s} · targetId {s}\n", .{ if (st) |v| @tagName(v) else "timeout", tid }) catch {};
    }
    // 둘째 세션·메시지 옮기기·페이지 JS 의 CDP·maru 가 모르는 브라우저 — 모두 거절.
    var pa: [256]u8 = undefined;
    var pb: [256]u8 = undefined;
    var pc: [512]u8 = undefined;
    const Call = struct { method: []const u8, params: []const u8 };
    const calls = [_]Call{
        .{ .method = "Target.attachToTarget", .params = std.fmt.bufPrint(&pa, "{{\"targetId\":\"{s}\",\"flatten\":false}}", .{tid}) catch "{}" },
        .{ .method = "Target.attachToBrowserTarget", .params = "{}" },
        .{ .method = "Target.setAutoAttach", .params = "{\"autoAttach\":true,\"waitForDebuggerOnStart\":false,\"flatten\":false}" },
        .{ .method = "Target.autoAttachRelated", .params = std.fmt.bufPrint(&pb, "{{\"targetId\":\"{s}\",\"waitForDebuggerOnStart\":false}}", .{tid}) catch "{}" },
        .{ .method = "Target.exposeDevToolsProtocol", .params = std.fmt.bufPrint(&pc, "{{\"targetId\":\"{s}\",\"bindingName\":\"cdpx\"}}", .{tid}) catch "{}" },
        .{ .method = "Target.sendMessageToTarget", .params = "{\"sessionId\":\"X\",\"message\":\"{\\\"id\\\":12,\\\"method\\\":\\\"Network.setBlockedURLs\\\",\\\"params\\\":{\\\"urls\\\":[\\\"*v20b2/t3*\\\"]}}\"}" },
        .{ .method = "Target.createTarget", .params = "{\"url\":\"about:blank\"}" },
    };
    for (calls) |c| {
        const st = r.call(1, c.method, c.params, 5000) catch null;
        if (st == null or st.? != .invalid_request) ok = false;
        lw.print("{s} → {s}\n", .{ c.method, if (st) |v| @tagName(v) else "timeout" }) catch {};
    }
    r.pump(400);
    const got = r.ev(1, fetchExpr(&x, "/v20b2/t3"), &o);
    r.pump(200);
    if (!starts(got, "ok") or seen("/v20b2/t3") != 1) ok = false;
    lw.print("fetch /v20b2/t3 → {s} · server {d}\n", .{ got, seen("/v20b2/t3") }) catch {};
    report(ok, "v20b2-r20-guard-target-domain", lw.buffered());
}

fn v20bTab(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "v20bblk", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [700]u8 = undefined;
    var p1: [128]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    // R12: 지켜보기를 끄면 sidecar 가 규칙을 버린다 — 다시 켜도(net_block 없이) 막지 않는다. 대조: 끄기 전에는 막혔다.
    {
        const rules = [_]msg.NetBlockRule{.{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/v20b/w/*") }};
        _ = try r.block(1, &rules, "");
        const before = r.ev(1, fetchExpr(&x, "/v20b/w/1"), &o);
        var bb: [64]u8 = undefined;
        @memcpy(bb[0..@min(before.len, 64)], before[0..@min(before.len, 64)]);
        try r.host.send(.{ .net_watch = .{ .browser = 1, .on = false } });
        r.pump(300);
        try r.watch(1);
        var o2: [600]u8 = undefined;
        const after = r.ev(1, fetchExpr(&x, "/v20b/w/2"), &o2);
        r.pump(300);
        const e = r.endOf(1, "/v20b/w/2");
        report(starts(bb[0..@min(before.len, 64)], "reject") and seen("/v20b/w/1") == 0 and starts(after, "ok 200") and seen("/v20b/w/2") == 1 and (e == null or !e.?.flags.blocked), "v20b-r12-watch-off-drops-rules", std.fmt.bufPrint(&d, "끄기 전 {s} · 서버 {d} → 끔·켬 뒤 {s} · 서버 {d} · 끝 표시 blocked {?}", .{ bb[0..@min(before.len, 64)], seen("/v20b/w/1"), after, seen("/v20b/w/2"), if (e) |v| v.flags.blocked else null }) catch "");
    }
    // R12: 지켜보지 않는 탭에 보낸 net_block — 답은 ok 거짓, 막지 않는다.
    {
        try r.create(2, uLoop(&u, "/p/sub?two"));
        const rules = [_]msg.NetBlockRule{.{ .id = 2, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/v20b/u/*") }};
        r.gen += 1;
        var v: msg.NetBlock = .{ .browser = 2, .generation = r.gen, .count = 1 };
        v.rules[0] = rules[0];
        try r.host.send(.{ .net_block = v });
        _ = r.until(Run.stateAt, 2, r.gen, 3000);
        const got = r.ev(2, fetchExpr(&x, "/v20b/u/1"), &o);
        report(r.state_gen[2] == r.gen and !r.state_ok[2] and starts(got, "ok 200") and seen("/v20b/u/1") == 1, "v20b-r12-unwatched-tab-not-blocked", std.fmt.bufPrint(&d, "답 세대 {d}/{d} ok {} · fetch {s} · 서버 {d}", .{ r.state_gen[2], r.gen, r.state_ok[2], got, seen("/v20b/u/1") }) catch "");
    }
    // R14: 규칙 32 개 — 마지막(32 번째)만 맞는다, 31 개는 맞지 않는다.
    {
        var pats: [32][128]u8 = undefined;
        var rules: [32]msg.NetBlockRule = undefined;
        for (&rules, 0..) |*rr, i| {
            var pb: [64]u8 = undefined;
            const path = if (i == 31) "/v20b/last/*" else (std.fmt.bufPrint(&pb, "/v20b/no{d}/*", .{i}) catch unreachable);
            rr.* = .{ .id = @intCast(100 + i), .site = "127.0.0.1", .pattern = pat(&pats[i], "127.0.0.1", path) };
        }
        const applied = try r.block(1, &rules, "");
        const got = r.ev(1, fetchExpr(&x, "/v20b/last/1"), &o);
        var o2: [600]u8 = undefined;
        const ok_one = r.ev(1, fetchExpr(&x, "/v20b/no5x"), &o2);
        r.pump(300);
        const e = r.endOf(1, "/v20b/last/1");
        report(applied and starts(got, "reject") and seen("/v20b/last/1") == 0 and e != null and e.?.rule == 131 and starts(ok_one, "ok 200"), "v20b-r14-32-rules-last-matches", std.fmt.bufPrint(&d, "적용 {} · 32 번째 {s} 규칙 {?d} · 맞지 않는 주소 {s}", .{ applied, got, if (e) |v| v.rule else null, ok_one }) catch "");
    }
    // R14: 세대가 거꾸로 온다(10 → 9) — 나중에 온 것이 서는가(관측: maru 는 늘 오르는 세대만 보낸다).
    {
        const ra = [_]msg.NetBlockRule{.{ .id = 7, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/v20b/genA/*") }};
        var pb2: [128]u8 = undefined;
        const rb = [_]msg.NetBlockRule{.{ .id = 8, .site = "127.0.0.1", .pattern = pat(&pb2, "127.0.0.1", "/v20b/genB/*") }};
        var v1: msg.NetBlock = .{ .browser = 1, .generation = 1000, .count = 1 };
        v1.rules[0] = ra[0];
        var v2: msg.NetBlock = .{ .browser = 1, .generation = 999, .count = 1 };
        v2.rules[0] = rb[0];
        try r.host.send(.{ .net_block = v1 });
        try r.host.send(.{ .net_block = v2 });
        r.pump(400);
        const a = r.ev(1, fetchExpr(&x, "/v20b/genA/1"), &o);
        var o2: [600]u8 = undefined;
        const b = r.ev(1, fetchExpr(&x, "/v20b/genB/1"), &o2);
        report(true, "v20b-r14-generation-order(obs)", std.fmt.bufPrint(&d, "1000 뒤 999 — genA(1000) {s} · genB(999) {s} · 마지막 답 세대 {d}", .{ a, b, r.state_gen[1] }) catch "");
        r.gen = 1000;
    }
    // R19: 규칙이 있는 탭에서 본문 기록 — 막히지 않은 JSON 본문은 그대로, 막힌 요청은 본문 없이 끝난다.
    {
        const rules = [_]msg.NetBlockRule{.{ .id = 9, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/v20b/b/*") }};
        _ = try r.block(1, &rules, "");
        try r.host.send(.{ .net_record = .{ .browser = 1, .on = true, .session = 11 } });
        r.pump(800);
        const blocked = r.ev(1, fetchExpr(&x, "/v20b/b/x"), &o);
        r.pump(300);
        const be = r.endOf(1, "/v20b/b/x");
        var o3: [600]u8 = undefined;
        const got = r.ev(1, "fetch('/v20b/json?n=1').then(r=>r.text()).then(t=>'ok '+t,e=>'reject '+e.name)", &o3);
        r.pump(800);
        const je2 = r.endOf(1, "/v20b/json?n=1");
        const got2 = got;
        var body: std.ArrayList(u8) = .empty;
        if (je2) |e| for (r.v20b_body_chunks.items) |c| if (c.request == e.request) body.appendSlice(r.gpa, r.v20b_bodies.items[c.start..][0..c.len]) catch {};
        const want = "{\"v20b\":[1,2,3],\"s\":\"body-ok\"}";
        const body_match = je2 != null and std.mem.eql(u8, body.items, want);
        var blocked_body_state: []const u8 = "(none)";
        if (be) |e| for (r.v20b_body_ends.items) |be2| if (be2.request == e.request) {
            blocked_body_state = @tagName(be2.state);
        };
        report(starts(blocked, "reject") and be != null and be.?.flags.blocked and starts(got, "ok {") and body_match, "v20b-r19-body-with-rules", std.fmt.bufPrint(&d, "막힘 {s}(본문 끝 {s}) · JSON {s} · 본문 {d}B 같음 {} (요청 {?d})", .{ blocked, blocked_body_state, got2, body.items.len, body_match, if (je2) |e| e.request else null }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = 1, .on = false } });
        r.pump(300);
    }
    // R14c: 호스트가 253 바이트를 넘는 페이지(*.localhost)가 Chromium 에서 열리는가(열리면 maru 의 규칙 사이트가 wire 를 지나지 못한다).
    // 길이 셋: 257(라벨 61×4)·253(경계)·253+끝 점(254 바이트 — maru 의 hostOfUrl 은 끝 점까지 돌려준다).
    for ([_]struct { labels: [4]usize, dot: bool }{ .{ .labels = .{ 61, 61, 61, 61 }, .dot = false }, .{ .labels = .{ 61, 61, 61, 57 }, .dot = false }, .{ .labels = .{ 61, 61, 61, 57 }, .dot = true } }) |c| {
        var lh: [400]u8 = undefined;
        var w: std.Io.Writer = .fixed(&lh);
        for (c.labels, 0..) |n, k| {
            for (0..n) |_| try w.writeByte(@as(u8, 'a') + @as(u8, @intCast(k)));
            try w.writeByte('.');
        }
        try w.writeAll("localhost");
        if (c.dot) try w.writeByte('.');
        const long_host = w.buffered();
        var lu: [600]u8 = undefined;
        var tag: [32]u8 = undefined;
        const tg = try std.fmt.bufPrint(&tag, "long{d}{s}", .{ long_host.len, if (c.dot) "dot" else "" });
        const url = try std.fmt.bufPrint(&lu, "http://{s}:{d}/p/sub?{s}", .{ long_host, port, tg });
        const urls_before = r.urls[1];
        const loads_before = r.loads[1];
        const errs_before = r.errors.items.len;
        try r.nav(1, url, false);
        r.pump(800);
        var o5: [600]u8 = undefined;
        const title = r.ev(1, "document.title.slice(0,12)+' host='+location.host.length", &o5);
        var nb: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&nb, "/p/sub?{s}", .{tg});
        report(true, "v20b-r14-long-host(obs)", std.fmt.bufPrint(&d, "호스트 {d} 바이트{s} — 불러옴 +{d} · url_changed +{d} · {s} · 서버 {d} · 새 오류 {d}{s}", .{ long_host.len, if (c.dot) "(끝 점)" else "", r.loads[1] - loads_before, r.urls[1] - urls_before, title, seen(needle), r.errors.items.len - errs_before, if (r.errors.items.len > errs_before) (if (r.errors.items[r.errors.items.len - 1].code == -105) " -105" else " other") else "" }) catch "");
    }
}

fn v20bGuard(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "v20bguard", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    // 기록을 켠다 — Network 도메인이 켜져 setBlockedURLs 같은 것이 들을 수 있게(가장 나쁜 경우).
    try r.host.send(.{ .net_record = .{ .browser = 1, .on = true, .session = 21 } });
    r.pump(800);
    const Case = struct { method: []const u8, params: []const u8, path: []const u8, reset_method: []const u8 = "", reset_params: []const u8 = "" };
    const cases = [_]Case{
        .{ .method = "Network.setBlockedURLs", .params = "{\"urls\":[\"*v20b/g0*\"]}", .path = "/v20b/g0" },
        .{ .method = "network.setBlockedURLs", .params = "{\"urls\":[\"*v20b/g1*\"]}", .path = "/v20b/g1" },
        .{ .method = "Network.SetBlockedURLs", .params = "{\"urls\":[\"*v20b/g2*\"]}", .path = "/v20b/g2" },
        .{ .method = "NETWORK.setBlockedURLs", .params = "{\"urls\":[\"*v20b/g3*\"]}", .path = "/v20b/g3" },
        .{ .method = "Network.setblockedurls", .params = "{\"urls\":[\"*v20b/g4*\"]}", .path = "/v20b/g4" },
        .{ .method = "Network.setBlockedURLs", .params = "{\"urlPatterns\":[{\"urlPattern\":\"*://*:*/v20b/g5*\",\"block\":true}]}", .path = "/v20b/g5" },
        .{ .method = "Network.emulateNetworkConditionsByRule", .params = "{\"offline\":true,\"matchedNetworkConditions\":[{\"urlPattern\":\"*://*:*/v20b/g6*\",\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}]}", .path = "/v20b/g6", .reset_method = "Network.emulateNetworkConditionsByRule", .reset_params = "{\"offline\":false,\"matchedNetworkConditions\":[]}" },
        .{ .method = "Network.overrideNetworkState", .params = "{\"offline\":true,\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}", .path = "/v20b/g7", .reset_method = "Network.overrideNetworkState", .reset_params = "{\"offline\":false,\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}" },
        .{ .method = "Network.emulateNetworkConditions", .params = "{\"offline\":true,\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}", .path = "/v20b/g8" },
        .{ .method = "network.emulateNetworkConditions", .params = "{\"offline\":true,\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}", .path = "/v20b/g9", .reset_method = "network.emulateNetworkConditions", .reset_params = "{\"offline\":false,\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}" },
        .{ .method = "Network.setBypassServiceWorker", .params = "{\"bypass\":true}", .path = "/v20b/g10" },
        .{ .method = "network.setBypassServiceWorker", .params = "{\"bypass\":true}", .path = "/v20b/g11", .reset_method = "network.setBypassServiceWorker", .reset_params = "{\"bypass\":false}" },
        .{ .method = "Network.setRequestInterception", .params = "{\"patterns\":[{\"urlPattern\":\"*v20b/g12*\"}]}", .path = "/v20b/g12" },
        .{ .method = "Fetch.enable", .params = "{\"patterns\":[{\"urlPattern\":\"*v20b/g13*\"}]}", .path = "/v20b/g13" },
        .{ .method = "fetch.enable", .params = "{\"patterns\":[{\"urlPattern\":\"*v20b/g14*\"}]}", .path = "/v20b/g14", .reset_method = "fetch.disable", .reset_params = "{}" },
        .{ .method = "Network.disable", .params = "{}", .path = "/v20b/g15" },
        .{ .method = "network.disable", .params = "{}", .path = "/v20b/g16" },
    };
    var any_bypass = false;
    var line: [4096]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line);
    for (cases) |c| {
        const st = r.call(1, c.method, c.params, 5000) catch null;
        var eb: [160]u8 = undefined;
        const err_text = if (st != null and st.? == .cdp_error) (std.fmt.bufPrint(&eb, "{s}", .{r.result.items[0..@min(r.result.items.len, 100)]}) catch "") else "";
        const got = r.ev(1, fetchExpr(&x, c.path), &o);
        r.pump(200);
        const effect = !starts(got, "ok 200") or seen(c.path) == 0;
        if (effect and !(std.mem.eql(u8, c.method, "Network.setBypassServiceWorker"))) any_bypass = true;
        lw.print("{s} → {s}{s}{s} · fetch {s} · 서버 {d}{s}\n", .{ c.method, if (st) |s| @tagName(s) else "timeout", if (err_text.len > 0) " " else "", err_text, got, seen(c.path), if (effect) " ← 효과" else "" }) catch {};
        if (c.reset_method.len > 0) _ = r.call(1, c.reset_method, c.reset_params, 3000) catch null;
    }
    report(!any_bypass, "v20b-r20-devtools-guard-variants", lw.buffered());
    try r.host.send(.{ .net_record = .{ .browser = 1, .on = false } });
    r.pump(200);
}

fn v20bRestart(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [700]u8 = undefined;
    var p1: [128]u8 = undefined;
    // 첫 sidecar — 규칙으로 막고 수를 받는다, 그리고 죽는다.
    var first_hits: u64 = 0;
    {
        var host = try spawn(host_path, root, "v20brestart", &.{});
        var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
        try r.create(1, uLoop(&u, "/p/sub?first"));
        try r.watch(1);
        const rules = [_]msg.NetBlockRule{.{ .id = 51, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/v20b/rs/*") }};
        _ = try r.block(1, &rules, "");
        for (0..3) |k| {
            var pb: [64]u8 = undefined;
            _ = r.ev(1, fetchExpr(&x, std.fmt.bufPrint(&pb, "/v20b/rs/a{d}", .{k}) catch unreachable), &o);
        }
        first_hits = r.hitOf(1, 51).hits;
        _ = std.c.kill(host.pid, .KILL);
        _ = host.wait(10_000);
    }
    var host = try spawn(host_path, root, "v20brestart", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    // maru 의 차례(기록이 켜져 있던 탭): browser_created → net_watch → net_record → net_block → navigate(재생 — user 거짓).
    try r.host.send(.{ .create_browser = .{ .browser = 1, .size = .{ .width = 640, .height = 400, .scale = 1 }, .hidden = false, .url = "about:blank" } });
    _ = r.until(Run.loadsAt, 1, 1, wait_ms);
    try r.watch(1);
    try r.host.send(.{ .net_record = .{ .browser = 1, .on = true, .session = 31 } });
    const rules = [_]msg.NetBlockRule{.{ .id = 51, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/v20b/rs/*") }};
    var v: msg.NetBlock = .{ .browser = 1, .generation = 5, .count = 1 };
    v.rules[0] = rules[0];
    try r.host.send(.{ .net_block = v });
    try r.host.send(.{ .navigate = .{ .browser = 1, .url = uLoop(&u, "/v20b/rs/replay") } });
    _ = r.until(Run.loadsAt, 1, 2, wait_ms);
    r.pump(800);
    const ep = r.lastError(1);
    // 대조: 같은 주소를 사용자가 친 이동(user)으로 보내면 지나간다(D2) — 그래서 재생은 user 거짓이어야 한다.
    try r.nav(1, uLoop(&u, "/v20b/rs/typed"), true);
    r.pump(500);
    // 재시작 뒤의 수는 0 부터의 차이(maru 가 누적한다).
    try r.nav(1, uLoop(&u, "/p/sub?second"), false);
    _ = r.ev(1, fetchExpr(&x, "/v20b/rs/b0"), &o);
    const after_hits = r.hitOf(1, 51).hits;
    report(seen("/v20b/rs/replay") == 0 and ep != null and ep.?.rule == 51 and seen("/v20b/rs/typed") == 1 and first_hits == 3 and after_hits >= 1 and after_hits <= 2, "v20b-r15-restart-with-record", std.fmt.bufPrint(&d, "첫 sidecar 수 {d} · 재생 이동 서버 {d}·규칙 {?d} · 사용자 이동(D2) 서버 {d} · 재시작 뒤 수(차이) {d}", .{ first_hits, seen("/v20b/rs/replay"), if (ep) |e| e.rule else null, seen("/v20b/rs/typed"), after_hits }) catch "");
}

/// 긴 주소(쿼리 ~2 KiB)로 3000 fetch — 규칙 없음 · 거의 맞다 빗나가는 8-별 규칙 32 개(마지막 조각만 없다) · 엄격 켬(규칙 없음).
fn v20bFloodLongMs(r: *Run) i64 {
    var o: [128]u8 = undefined;
    const got = r.ev(1, "(async()=>{const q='aaaa'+'x'.repeat(400)+'bbbb'+'x'.repeat(400)+'cccc'+'x'.repeat(400)+'dddd'+'x'.repeat(400)+'eeee'+'x'.repeat(400);const t=performance.now();for(let b=0;b<30;b++){const ps=[];for(let i=0;i<100;i++)ps.push(fetch('/f?'+q+b+'_'+i).then(()=>1,()=>0));await Promise.all(ps)}return String(Math.round(performance.now()-t))})()", &o);
    return std.fmt.parseInt(i64, got, 10) catch 999_999;
}

fn v20bCost(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "v20bcost", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [400]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    _ = v20bFloodLongMs(&r);
    var base: i64 = std.math.maxInt(i64);
    var base_all: [3]i64 = undefined;
    for (&base_all) |*m| {
        m.* = v20bFloodLongMs(&r);
        base = @min(base, m.*);
    }
    var bufs: [32][128]u8 = undefined;
    var rules: [32]msg.NetBlockRule = undefined;
    for (&rules, 0..) |*rule, i| rule.* = .{ .id = @intCast(200 + i), .site = "127.0.0.1", .pattern = std.fmt.bufPrint(&bufs[i], "*://*/f*aaaa*bbbb*cccc*dddd*eeee*zz{d:0>2}", .{i}) catch unreachable };
    const applied = try r.block(1, &rules, "");
    var worst: i64 = std.math.maxInt(i64);
    var worst_all: [3]i64 = undefined;
    for (&worst_all) |*m| {
        m.* = v20bFloodLongMs(&r);
        worst = @min(worst, m.*);
    }
    _ = try r.block(1, &.{}, "127.0.0.1");
    const strict_state = r.strict[1];
    var strict: i64 = std.math.maxInt(i64);
    var strict_all: [3]i64 = undefined;
    for (&strict_all) |*m| {
        m.* = v20bFloodLongMs(&r);
        strict = @min(strict, m.*);
    }
    _ = try r.block(1, &.{}, "");
    report(applied and worst <= @divTrunc(base * 125, 100) + 80, "v20b-r20-cost-worst-glob", std.fmt.bufPrint(&d, "3000 fetch(쿼리 2 KiB) — 규칙 없음 {d} ms {any} · 8-별 거의 맞는 규칙 32 {d} ms {any} · 엄격({s}) {d} ms {any}", .{ base, base_all, worst, worst_all, @tagName(strict_state), strict, strict_all }) catch "");
}

// ── W9d③ 3 차 검증 11–20 회차(검증자 B3 — 8485a891e) — `--review-block-v20c` ──────────────────────────────────────────

pub fn runV20c(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    v20cLateRetag(report, host_path, root) catch |err| report(false, "v20c-late-retag", @errorName(err));
    v20cGuardSweep(report, host_path, root) catch |err| report(false, "v20c-guard-sweep", @errorName(err));
}

// R12(NEW-B3-1): 2 차 고침(NEW-3·N-a)은 「탭을 비운 세대보다 앞선 늦은 수는 버린다」 를 세대로 가른다 — 그러려면 sidecar 가 수를 **센 때**의
// 세대로 보내야 한다(전에는 보낼 때의 세대를 실어 10 회 중 4 회 빈 세대를 단 수가 maru 에 받혔다). 규칙에 걸리는 요청을 쏟는 동안 maru 처럼 빈
// net_block(새 세대 E)을 보내고, 그 뒤 온 수 frame 중 세대 E 를 단 것 — 문 넘김·모르는 페이지·옛 규칙의 수 — 이 없어야 한다(옛 세대를 단 늦은
// frame 은 있어도 된다 — maru 의 바닥이 버린다).
fn v20cLateRetag(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "v20clate", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var o: [600]u8 = undefined;
    var p1: [160]u8 = undefined;
    var line: [4096]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line);
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    var cycles_with_retag: u32 = 0;
    var frames_old_late: u32 = 0;
    var frames_after: u32 = 0;
    var frames_retag: u32 = 0;
    var retag_tab: u64 = 0;
    var retag_rule_hits: u64 = 0;
    var before_unrec: u64 = 0;
    const cycles = 10;
    for (0..cycles) |cyc| {
        const rules = [_]msg.NetBlockRule{.{ .id = @intCast(300 + cyc), .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/v20c/fl/*") }};
        if (!try r.block(1, &rules, "")) return error.BlockNotApplied;
        _ = r.ev(1, "(function(){window.__v20c=setInterval(function(){for(var i=0;i<60;i++)fetch('/v20c/fl/'+i+'?'+Math.random()).catch(function(){})},1);return 'started'})()", &o);
        const unrec0 = r.unrecorded[1];
        r.pump(400);
        before_unrec += r.unrecorded[1] - unrec0;
        // maru 의 sync 가 탭을 비웠다 — 빈 net_block(새 세대). 이 세대 앞의 수는 maru 가 버리려는 늦은 수다.
        r.gen += 1;
        const empty = r.gen;
        try r.host.send(.{ .net_block = .{ .browser = 1, .generation = empty } });
        var got_retag = false;
        const deadline = os.nowMs() + 600;
        while (os.nowMs() < deadline) {
            const m = (r.host.next(20) catch null) orelse continue;
            if (m == .net_block_hits and m.net_block_hits.browser == 1) {
                const v = m.net_block_hits;
                frames_after += 1;
                if (v.generation != empty and v.unrecorded + v.skipped_unknown_page + v.count > 0) frames_old_late += 1;
                if (v.generation == empty) {
                    var rule_hits: u64 = 0;
                    for (v.entries[0..v.count]) |e| rule_hits += e.hits;
                    if (v.unrecorded + v.skipped_unknown_page > 0 or rule_hits > 0) {
                        frames_retag += 1;
                        retag_tab += v.unrecorded + v.skipped_unknown_page;
                        retag_rule_hits += rule_hits;
                        got_retag = true;
                    }
                }
            }
            r.take(m);
        }
        if (got_retag) cycles_with_retag += 1;
        _ = r.ev(1, "clearInterval(window.__v20c),'stopped'", &o);
        r.pump(300);
    }
    lw.print("cycles {d} · blocked-without-record during flood {d} · hits frames after the empty generation {d} (late ones carrying an older generation {d}) · frames carrying the empty generation with counts {d} (cycles {d}) · tab-level counts in them {d} · old-rule hits in them {d} (want 0 — counts carry the generation they were made under)", .{ cycles, before_unrec, frames_after, frames_old_late, frames_retag, cycles_with_retag, retag_tab, retag_rule_hits }) catch {};
    report(before_unrec > 0 and frames_retag == 0, "v20c-r12-late-retag", lw.buffered());
}

// R20: DevTools 지킴 훑기 — `Target.*` 는 `getTargetInfo` 말고 모두 거절(이름·대소문자 꼴 포함), 다른 도메인에서 세션을 열거나 메시지를 옮기거나
// 막기를 흉내·우회할 수 있는 메서드를 불러도 — 막힌 주소는 막힌 채, 막히지 않은 주소는 서버에 닿고, 새 브라우저가 생기지 않는다.
fn v20cGuardSweep(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "v20cguard", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [4096]u8 = undefined;
    var o: [1200]u8 = undefined;
    var p1: [160]u8 = undefined;
    var line: [16384]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line);
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    const rules = [_]msg.NetBlockRule{.{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/v20c/g/blk/*") }};
    if (!try r.block(1, &rules, "")) return error.BlockNotApplied;
    var tid_buf: [80]u8 = undefined;
    var tid: []const u8 = "";
    {
        _ = r.call(1, "Target.getTargetInfo", "{}", 5000) catch null;
        const res = r.result.items;
        if (std.mem.indexOf(u8, res, "\"targetId\":\"")) |i| {
            const start = i + 12;
            if (std.mem.indexOfScalarPos(u8, res, start, '"')) |end| if (end - start <= tid_buf.len) {
                @memcpy(tid_buf[0 .. end - start], res[start..end]);
                tid = tid_buf[0 .. end - start];
            };
        }
    }
    var origin_buf: [64]u8 = undefined;
    const origin = std.fmt.bufPrint(&origin_buf, "http://127.0.0.1:{d}", .{port}) catch unreachable;
    var pb: [16][512]u8 = undefined;
    const Call = struct { method: []const u8, params: []const u8, must_refuse: bool = false };
    const calls = [_]Call{
        // Target — getTargetInfo 말고 모두 거절.
        .{ .method = "Target.getTargets", .params = "{}", .must_refuse = true },
        .{ .method = "Target.getBrowserContexts", .params = "{}", .must_refuse = true },
        .{ .method = "Target.setDiscoverTargets", .params = "{\"discover\":true}", .must_refuse = true },
        .{ .method = "Target.attachToTarget", .params = std.fmt.bufPrint(&pb[0], "{{\"targetId\":\"{s}\",\"flatten\":true}}", .{tid}) catch "{}", .must_refuse = true },
        .{ .method = "Target.activateTarget", .params = std.fmt.bufPrint(&pb[1], "{{\"targetId\":\"{s}\"}}", .{tid}) catch "{}", .must_refuse = true },
        .{ .method = "Target.detachFromTarget", .params = "{\"sessionId\":\"X\"}", .must_refuse = true },
        .{ .method = "Target.setRemoteLocations", .params = "{\"locations\":[{\"host\":\"127.0.0.1\",\"port\":9}]}", .must_refuse = true },
        .{ .method = "Target.createBrowserContext", .params = "{}", .must_refuse = true },
        .{ .method = "Target.disposeBrowserContext", .params = "{\"browserContextId\":\"X\"}", .must_refuse = true },
        .{ .method = "Target.openDevTools", .params = std.fmt.bufPrint(&pb[2], "{{\"targetId\":\"{s}\"}}", .{tid}) catch "{}", .must_refuse = true },
        .{ .method = "Target.getDevToolsTarget", .params = std.fmt.bufPrint(&pb[3], "{{\"targetId\":\"{s}\"}}", .{tid}) catch "{}", .must_refuse = true },
        .{ .method = "Target.closeTarget", .params = "{\"targetId\":\"X\"}", .must_refuse = true },
        // 이름·대소문자 꼴(Chromium 은 대소문자를 가린다 — 지킴을 지나도 듣지 않아야 한다).
        .{ .method = "target.attachToTarget", .params = std.fmt.bufPrint(&pb[4], "{{\"targetId\":\"{s}\",\"flatten\":false}}", .{tid}) catch "{}" },
        .{ .method = "TARGET.setAutoAttach", .params = "{\"autoAttach\":true,\"waitForDebuggerOnStart\":false,\"flatten\":false}" },
        .{ .method = "Target.AttachToTarget", .params = std.fmt.bufPrint(&pb[5], "{{\"targetId\":\"{s}\",\"flatten\":false}}", .{tid}) catch "{}" },
        .{ .method = "Target", .params = "{}" },
        .{ .method = "Target.getTargetInfo", .params = "{\"targetId\":\"0000\"}" },
        .{ .method = "network.setBlockedURLs", .params = "{\"urls\":[\"*v20c/g/ok*\"]}" },
        .{ .method = "Network.SetBlockedURLs", .params = "{\"urls\":[\"*v20c/g/ok*\"]}" },
        .{ .method = "Network.setBlockedURLs", .params = "{\"urlPatterns\":[{\"urlPattern\":\"*://*:*/v20c/g/ok*\",\"block\":true}]}", .must_refuse = true },
        .{ .method = "fetch.enable", .params = "{\"patterns\":[{\"urlPattern\":\"*v20c/g/ok*\"}]}" },
        // 다른 도메인 — 세션·메시지 옮기기·브라우저 만들기·막기 흉내가 될 만한 것.
        .{ .method = "ServiceWorker.enable", .params = "{}" },
        .{ .method = "ServiceWorker.setForceUpdateOnPageLoad", .params = "{\"forceUpdateOnPageLoad\":true}" },
        .{ .method = "ServiceWorker.inspectWorker", .params = "{\"versionId\":\"0\"}" },
        .{ .method = "ServiceWorker.stopAllWorkers", .params = "{}" },
        .{ .method = "ServiceWorker.disable", .params = "{}" },
        .{ .method = "Browser.getVersion", .params = "{}" },
        .{ .method = "Browser.setDownloadBehavior", .params = "{\"behavior\":\"default\"}" },
        .{ .method = "Browser.getBrowserCommandLine", .params = "{}" },
        .{ .method = "Page.createIsolatedWorld", .params = "{\"frameId\":\"X\",\"worldName\":\"v20c\"}" },
        .{ .method = "Page.setBypassCSP", .params = "{\"enabled\":false}" },
        .{ .method = "Runtime.addBinding", .params = "{\"name\":\"v20cBinding\"}" },
        .{ .method = "Network.setCacheDisabled", .params = "{\"cacheDisabled\":true}" },
        .{ .method = "Network.setCacheDisabled", .params = "{\"cacheDisabled\":false}" },
        .{ .method = "Network.setAttachDebugStack", .params = "{\"enabled\":true}" },
        .{ .method = "Network.enableReportingApi", .params = "{\"enable\":true}" },
        .{ .method = "Network.setExtraHTTPHeaders", .params = "{\"headers\":{\"X-V20c\":\"1\"}}" },
        .{ .method = "Network.setExtraHTTPHeaders", .params = "{\"headers\":{}}" },
        .{ .method = "Network.replayXHR", .params = "{\"requestId\":\"1\"}" },
        .{ .method = "Network.overrideNetworkState", .params = "{\"offline\":true,\"latency\":0,\"downloadThroughput\":0,\"uploadThroughput\":0}" },
        .{ .method = "Network.overrideNetworkState", .params = "{\"offline\":false,\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}" },
        .{ .method = "Network.setRequestInterception", .params = "{\"patterns\":[{\"urlPattern\":\"*v20c/g/ok*\"}]}", .must_refuse = true },
        .{ .method = "Network.setBypassServiceWorker", .params = "{\"bypass\":true}", .must_refuse = true },
        .{ .method = "Network.enable", .params = "{}", .must_refuse = true },
        .{ .method = "Network.disable", .params = "{}", .must_refuse = true },
        .{ .method = "Fetch.enable", .params = "{}", .must_refuse = true },
        .{ .method = "Storage.getUsageAndQuota", .params = std.fmt.bufPrint(&pb[6], "{{\"origin\":\"{s}\"}}", .{origin}) catch "{}" },
        .{ .method = "Storage.trackCacheStorageForOrigin", .params = std.fmt.bufPrint(&pb[7], "{{\"origin\":\"{s}\"}}", .{origin}) catch "{}" },
        .{ .method = "Emulation.setUserAgentOverride", .params = "{\"userAgent\":\"v20c\"}" },
        .{ .method = "Emulation.setAutomationOverride", .params = "{\"enabled\":true}" },
        .{ .method = "Emulation.setCPUThrottlingRate", .params = "{\"rate\":1}" },
        .{ .method = "Security.setIgnoreCertificateErrors", .params = "{\"ignore\":true}" },
        .{ .method = "Extensions.loadUnpacked", .params = "{\"path\":\"/nonexistent\"}" },
        .{ .method = "Tethering.bind", .params = "{\"port\":0}" },
        .{ .method = "PWA.getOsAppState", .params = "{\"manifestId\":\"x\"}" },
        .{ .method = "SystemInfo.getInfo", .params = "{}" },
    };
    var ok = true;
    var refused: u32 = 0;
    var must: u32 = 0;
    const created_before = std.mem.count(bool, &r.created, &.{true});
    for (calls) |c| {
        var err_name: []const u8 = "timeout";
        const st = r.call(1, c.method, c.params, 5000) catch |e| blk: {
            err_name = @errorName(e);
            break :blk null;
        };
        const res = r.result.items;
        const refused_here = st != null and st.? == .invalid_request;
        if (c.must_refuse) {
            must += 1;
            if (refused_here) refused += 1 else ok = false;
        }
        lw.print("{s} → {s}{s}{s}\n", .{ c.method, if (st) |v| @tagName(v) else err_name, if (res.len > 0) " " else "", res[0..@min(res.len, 70)] }) catch {};
    }
    r.pump(500);
    var o2: [1200]u8 = undefined;
    const got_ok = r.ev(1, fetchExpr(&x, "/v20c/g/ok?s1"), &o);
    var x2: [4096]u8 = undefined;
    const got_blk = r.ev(1, fetchExpr(&x2, "/v20c/g/blk/x?s1"), &o2);
    r.pump(200);
    const created_after = std.mem.count(bool, &r.created, &.{true});
    if (!starts(got_ok, "ok 200") or seen("/v20c/g/ok?s1") != 1 or !starts(got_blk, "reject") or seen("/v20c/g/blk/x?s1") != 0 or created_after != created_before) ok = false;
    lw.print("must-refuse {d}/{d} · fetch ok {s} (server {d}) · fetch blocked {s} (server {d}) · browsers {d} → {d}\n", .{ refused, must, got_ok[0..@min(got_ok.len, 12)], seen("/v20c/g/ok?s1"), got_blk[0..@min(got_blk.len, 16)], seen("/v20c/g/blk/x?s1"), created_before, created_after }) catch {};
    report(ok, "v20c-r20-guard-sweep", lw.buffered());
    // N-B3-f: maru 가 보낼 수 없는(고정 목록 밖) `Browser.executeBrowserCommand` — 고치기 전에는 그 뒤 모든 DevTools 호출·평가가 답하지 않았다. 지킴이
    // 거절하고 그 탭의 평가가 그대로 답해야 한다.
    var lw2: std.Io.Writer = .fixed(&line);
    const st = r.call(1, "Browser.executeBrowserCommand", "{\"commandId\":\"openTabSearch\"}", 5000) catch |e| blk: {
        lw2.print("executeBrowserCommand send/recv error {s}\n", .{@errorName(e)}) catch {};
        break :blk null;
    };
    lw2.print("Browser.executeBrowserCommand → {s}\n", .{if (st) |v| @tagName(v) else "timeout"}) catch {};
    var o3: [600]u8 = undefined;
    const after = r.ev(1, "1+1", &o3);
    lw2.print("Runtime.evaluate after it → {s} · host pid {d} alive {}\n", .{ after, host.pid, std.c.kill(host.pid, @fromBackingInt(@intCast(0))) == 0 }) catch {};
    report(st != null and st.? == .invalid_request and std.mem.eql(u8, after, "2"), "v20c-r20-execute-browser-command", lw2.buffered());
}

// ── W9d③ 4 차 적대 검증 B4(`--review-block-v20d` — `runV20d`) ─────────────────────────────────────────────
// R20 비용(B-LOW-4): 별이 많은 규칙 32 개를 쥔 탭의 페이지가 긴 주소(60 KiB)의 요청을 쏟으면, 처리기 고르기(IO 스레드)의 맞추기가 요청마다 주소
// 끝까지 32 번 훑었다(고치기 전 ReleaseFast: 규칙 없는 다른 탭의 fetch 60 개 98 → 539 ms). 고친 뒤의 상한: 한 요청의 가운데 조각 훑기는 모든
// 규칙을 합쳐 `request_scan_budget`(64 Ki 단위) — 다른 탭의 지연은 기준의 두 배 + 100 ms 안이고, 예산을 다 쓴 요청은 막는 쪽(첫 규칙 700 이
// 주소 끝까지 훑어 예산을 거의 다 쓰고, 둘째 규칙 701 이 다 보지 못해 막는다 — 700 은 맞지 않는다).

pub fn runV20d(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    v20dIoCost(report, host_path, root) catch |err| report(false, "v20d-r20-io-cost", @errorName(err));
}

fn v20dRound(r: *Run, o: []u8, o2: []u8, out_flood: *i64, out_other: *i64) void {
    // 탭 1: 닫힌 포트(47999 — 곧 거절)로 60 KiB 주소 fetch 300 개(50 개씩 6 번). 끝나면 window.__v20d 에 걸린 ms.
    _ = r.ev(1, "window.__v20d=null;(async()=>{const L='ab'.repeat(30000)+'b';const t=performance.now();for(let k=0;k<6;k++){const ps=[];for(let i=0;i<50;i++)ps.push(fetch('http://127.0.0.1:47999/z'+k+'_'+i+'?'+L,{mode:'no-cors'}).then(()=>1,()=>0));await Promise.all(ps)}window.__v20d=String(Math.round(performance.now()-t))})();'started'", o);
    // 탭 2(규칙 없음): 그 동안 작은 fetch 60 개를 차례로.
    const other = r.ev(2, "(async()=>{const t=performance.now();for(let i=0;i<60;i++){await fetch('/f?v20d'+i+'_'+Math.random()).catch(()=>0)}return String(Math.round(performance.now()-t))})()", o2);
    out_other.* = std.fmt.parseInt(i64, other, 10) catch 999_999;
    const deadline = os.nowMs() + 60_000;
    while (os.nowMs() < deadline) {
        const got = r.ev(1, "String(window.__v20d)", o);
        if (!std.mem.eql(u8, got, "null")) {
            out_flood.* = std.fmt.parseInt(i64, got, 10) catch 999_999;
            return;
        }
        r.pump(100);
    }
    out_flood.* = 999_999;
}

fn v20dIoCost(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "v20dcost", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var o: [600]u8 = undefined;
    var o2: [600]u8 = undefined;
    var line: [2048]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line);
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.create(2, uLoop(&u, "/p/sub"));
    try r.watch(1);
    var fb: i64 = 0;
    var ob: i64 = 0;
    v20dRound(&r, &o, &o2, &fb, &ob); // 데우기
    var base_flood: i64 = std.math.maxInt(i64);
    var base_other: i64 = std.math.maxInt(i64);
    for (0..3) |_| {
        v20dRound(&r, &o, &o2, &fb, &ob);
        base_flood = @min(base_flood, fb);
        base_other = @min(base_other, ob);
    }
    var bufs: [32][128]u8 = undefined;
    var rules: [32]msg.NetBlockRule = undefined;
    for (&rules, 0..) |*rule, i| rule.* = .{ .id = @intCast(700 + i), .site = "127.0.0.1", .pattern = std.fmt.bufPrint(&bufs[i], "http://127.0.0.1:47999/*a*a*a*a*a*zz{d:0>2}*b", .{i}) catch unreachable };
    const applied = try r.block(1, &rules, "");
    var with_flood: i64 = std.math.maxInt(i64);
    var with_other: i64 = std.math.maxInt(i64);
    for (0..3) |_| {
        v20dRound(&r, &o, &o2, &fb, &ob);
        with_flood = @min(with_flood, fb);
        with_other = @min(with_other, ob);
    }
    const h700 = r.hitOf(1, 700);
    const h701 = r.hitOf(1, 701);
    lw.print("rules applied {} · tab 1 (300 fetch × 60 KiB URL) none {d} ms → 32 star rules {d} ms · tab 2 (no rules, 60 small sequential fetch at the same time) none {d} ms → {d} ms (best of 3) · rule 700 hits {d} · rule 701 hits {d} (budget ran out — blocking side)", .{ applied, base_flood, with_flood, base_other, with_other, h700.hits, h701.hits }) catch {};
    // 단언: 다른 탭의 지연이 기준의 두 배 + 100 ms 를 넘지 않는다(IO 스레드 맞추기가 다른 탭을 붙잡지 않는다), 예산을 다 쓴 요청은 막는 쪽이다.
    report(applied and with_other <= base_other * 2 + 100 and h700.hits == 0 and h701.hits >= 300, "v20d-r20-io-cost", lw.buffered());
}
