//! W9d④ 판정 — 실제 CEF 154 에서 가짜 응답(docs/plans/web-osr-backend.md 「W9d④ 결정·실측」). 판정자가 **maru 역할**로 `net_watch`·
//! `net_mock_rule`·`net_mock_commit`·`net_mock_body`(256 KiB 창 — `net_mock_ack` 로 연다)·`navigate{user}`·`nav_action{user}`·사람 입력
//! (`mouse`·`key`)을 보내고 `net_begin`(둘째 표시 `mocked`)·`net_end`(가짜 표시)·`net_mock_state`·`net_mock_hits`·`net_mock_ack` 를 모은다. 서버는
//! 따로 띄워 **받은 요청을 모두 적는다** — 「가짜였다」 는 페이지가 본 것(가짜의 본문·상태·머리)과 서버가 그 주소를 받지 않았다는 것 둘로 잰다.
//! 가짜가 아니면 서버는 `REAL:` 로 시작하는 본문을 준다. `127.0.0.1:<포트>` 와 `localhost:<포트>` 는 다른 사이트다.
//!
//! 탭 길(`mk1`): mock-fetch·xhr·head-empty·post·status-404-ct·empty-204·content-length·big-512k·script·css·img·worker·sse·prefetch·
//!   speculation-id0·favicon·main-frame(주소·history·`mocked` 끝)·iframe-same-site·oopif-site-bound(실행 출처 — 묶인 사이트가 덮지 않으면 진짜,
//!   어느 호스트든이면 가짜)·redirect-location·redirect-hop-rematch·redirect-loop·cors(ACAO 없음 실패·`*`·preflight 없음)·nocors-redirect-opaque·
//!   cookie-filter(판정자 훅으로 가짜에 Set-Cookie 를 실어도 저장 안 됨 — 기록하는·기록하지 않는 요청 둘 다)·header-allowlist(codec 이 거절)·
//!   no-store-bfcache·download-refused·block-wins·user-nav-exempt(가짜만 있는 탭 — §13 P2-1)·human-click(Q2 — 사용자 탭 규칙은 사람의 링크·폼
//!   이동의 주 문서에 듣지 않고 에이전트의 DevTools 누름에는 듣는다, 에이전트 탭 규칙은 둘 다)·unrecorded(문이 떨어뜨려도 가짜)·
//!   no-request-echo·devtools-guard·hits.
//! 서비스 워커(`mksw`): mock-sw-path-not-mocked(`sw_not_mocked`·`page_controlled`)·sw-cache-clean(설치의 `cache.add` 는 진짜)·
//!   sw-preload-not-mocked(navigation preload 19)·strict(엄격 탭은 가짜, 같은 출처 다른 탭은 진짜).
//! 풀·본문(`mkpool`): mock-pool-busy(600 개 — 진짜 0, 붙잡기 ≤ 128 + busy)·body-hold(본문이 늦게 오면 붙잡았다가 잇는다·10 초 시한 -12)·
//!   window(32 MiB 를 창으로 — sidecar 생존).
//! 재시작(`mkrestart`): mock-restart(다시 뜬 sidecar 의 재생 이동 앞에 규칙이 선다 — 서버 0).
//! 비용(`mkcost`): mock-cost(맞지 않는 가짜 규칙 32 개로 3000 fetch — 규칙 없음보다 많아야 +10 %, 잡음 몫 60 ms).
//! main 위로 옮김(`mkport` — 2026-11-11, W9d③ 결정 A·W9d② 와의 맞물림): mock-shw-fetch-not-mocked(공유 워커의 fetch 는 서비스 워커 길 — 가짜가
//!   아니고 `sw_not_mocked`)·mock-shw-strict-not-mocked(가짜 엄격도 공유 워커를 덮지 않는다 — 같은 탭의 페이지 fetch 는 가짜)·
//!   mock-shw-kind-refused(종류 shared_worker 는 거절 — 사용자 결정 A 2026-11-11)·mock-shw-script-real(종류 없는 규칙이 공유 워커 주 스크립트
//!   주소에 맞아도 워커는 진짜·`sw_not_mocked`, 같은 탭 같은 주소의 페이지 fetch 는 가짜)·mock-shw-script-cross-tab(규칙 없는 같은 출처 탭이
//!   같은 공유 워커에 붙어도 진짜)·mock-shw-script-after-close(만든 탭을 닫은 뒤 새 연결도 진짜)·mock-block-strict-union(막기 엄격만 켜도 가짜가 서비스 워커 아래 탭 길로 듣는다, 상태는 각자의 엄격만)·
//!   mock-record-body-mixed(W9d② 기록 중 같은 주소를 가짜(fetch)·진짜(img)로 함께 — 진짜 기록에 가짜 본문이 붙지 않는다).
//! 적대 검증 SEVERE 넷 고침(`mkfix4f`·`mkfix4d`·`mkfix4c` — 2026-11-11, `MOCK_ONLY=fix4`): mock-xframe-*·mock-sameframe-mocked(허락 밖 iframe 의 요청은 모두 진짜),
//!   mock-d2-*·block-d2-*(사용자 이동 × 에이전트 DevTools 호출 — 다툼), mock-churn-no-traffic(요청 없는 바꾸기) — 파일 끝의 설명.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const nf = protocol.net_fields;
const mr = protocol.net_mock_rules;
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
var srv_log: std.ArrayList(u8) = .empty;
var flood_served = std.atomic.Value(u32).init(0);

fn startServer() !void {
    if (port != 0) return;
    const fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
    if (listen(fd, 1024) != 0) return error.ListenFailed;
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

/// 서버가 그 글을 담은 요청을 받은 수.
fn seen(needle: []const u8) usize {
    _ = std.c.pthread_mutex_lock(&srv_lock);
    defer _ = std.c.pthread_mutex_unlock(&srv_lock);
    return std.mem.count(u8, srv_log.items, needle);
}

fn reply(conn: c_int, status: []const u8, ctype: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [2048]u8 = undefined;
    const cache = if (std.mem.indexOf(u8, extra, "Cache-Control") != null) "" else "Cache-Control: no-store\r\n";
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}{s}Connection: close\r\n\r\n", .{ status, ctype, body.len, cache, extra }) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, body.ptr, body.len);
}

const html = "text/html; charset=utf-8";

/// 서비스 워커 — navigation preload 를 켜고, 설치 때 `cache.add('/s/cached')`, 이동은 preloadResponse 를 Cache Storage `np` 에 넣고(실측 M26 —
/// 가짜면 남는다), `/s/` 아래는 `fetch(e.request)` 로 받아 온다(서비스 워커 길 — 공유 context 처리기).
const sw_js =
    \\self.addEventListener('install',e=>{self.skipWaiting();e.waitUntil(caches.open('c1').then(c=>c.add('/s/cached')))});
    \\self.addEventListener('activate',e=>e.waitUntil((async()=>{if(self.registration.navigationPreload)await self.registration.navigationPreload.enable();await self.clients.claim()})()));
    \\self.addEventListener('fetch',e=>{const u=new URL(e.request.url);
    \\ if(e.request.mode==='navigate'){e.respondWith((async()=>{const p=await e.preloadResponse;if(p){const c=await caches.open('np');await c.put(e.request.url,p.clone());return p}return fetch(e.request)})());return}
    \\ if(u.pathname==='/s/cached'){e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request)));return}
    \\ if(u.pathname==='/s/sw.js')return;
    \\ if(u.pathname.startsWith('/s/'))e.respondWith(fetch(e.request))});
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
    var cookie: []const u8 = "";
    if (std.ascii.findIgnoreCase(r, "\r\ncookie: ")) |i| {
        const rest = r[i + 10 ..];
        cookie = rest[0 .. std.mem.indexOfScalar(u8, rest, '\r') orelse rest.len];
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
        var lb: [700]u8 = undefined;
        const line = std.fmt.bufPrint(&lb, "{s} {s} host={s}\n", .{ method, target, host_hdr }) catch "";
        srv_log.appendSlice(std.heap.c_allocator, line) catch {};
    }
    var bb: [4096]u8 = undefined;
    const p = port;
    if (std.mem.eql(u8, path, "/c/echo")) {
        const body = std.fmt.bufPrint(&bb, "REAL:cookie={s}", .{cookie}) catch return;
        return reply(conn, "200 OK", "text/plain", "Access-Control-Allow-Origin: *\r\n", body);
    }
    if (std.mem.eql(u8, path, "/p/sub")) return reply(conn, "200 OK", html, "", "<!doctype html><title>sub</title><body>sub</body>");
    if (std.mem.startsWith(u8, path, "/x4/")) if (fix4Route(conn, path, target, &bb)) return;
    if (std.mem.eql(u8, path, "/p/links")) {
        // 사람·에이전트의 누름(Q2): 링크(위 왼쪽 큰 덩어리), 폼(입력칸·Enter), 늦은 이동(누름 뒤 1.5 초 setTimeout).
        const body =
            \\<!doctype html><title>links</title><body style=margin:0>
            \\<a id=l href=/m/linkdoc style="display:block;width:300px;height:80px;background:#ccc">link</a>
            \\<form id=f action=/m/formdoc><input id=i name=q style="display:block;width:300px;height:40px"></form>
            \\<div id=d style="width:300px;height:80px;background:#aaa" onclick="setTimeout(()=>location.href='/m/delaydoc',1500)">late</div>
            \\</body>
        ;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/p/frames")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>frames</title><script>window.msgs=[];addEventListener('message',e=>window.msgs.push(e.data))</script><iframe src='/m/samedoc'></iframe><iframe src='http://localhost:{d}/m/xsdoc'></iframe>", .{p}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/p/pf")) return reply(conn, "200 OK", html, "", "<!doctype html><title>pf</title><link rel=prefetch href='/m/pf'><script type=speculationrules>{\"prerender\":[{\"source\":\"list\",\"urls\":[\"/m/pr\"]}]}</script>");
    if (std.mem.eql(u8, path, "/p/favicon")) return reply(conn, "200 OK", html, "", "<!doctype html><title>fav</title><link rel=icon href='/m/fav.ico'>");
    if (std.mem.eql(u8, path, "/r/a")) return reply(conn, "302 Found", "text/plain", "Location: /m/afterreal\r\n", "");
    // main 위로 옮김: 공유 워커 — 받은 주소를 fetch 해 돌려준다(`/w/shw.js`), 주 스크립트 가짜의 진짜 쪽(`/w/shwm.js`).
    if (std.mem.eql(u8, path, "/w/shw.js")) return reply(conn, "200 OK", "text/javascript", "", "onconnect=e=>{const p=e.ports[0];p.onmessage=async m=>{try{const r=await fetch(m.data);p.postMessage('ok '+(await r.text()))}catch(x){p.postMessage('reject '+x.name)}}}");
    if (std.mem.eql(u8, path, "/w/shwm.js")) return reply(conn, "200 OK", "text/javascript", "", "onconnect=e=>e.ports[0].postMessage('REAL-SHW-SCRIPT')");
    // 서비스 워커 쪽.
    if (std.mem.eql(u8, path, "/s/sw.js")) return reply(conn, "200 OK", "application/javascript", "", sw_js);
    if (std.mem.eql(u8, path, "/s/cached")) return reply(conn, "200 OK", "text/plain", "", "REAL:cached");
    if (std.mem.startsWith(u8, path, "/s/page")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>swpage</title>{s}<div>{s}</div>", .{ sw_reg, target }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.startsWith(u8, path, "/s/navdoc")) return reply(conn, "200 OK", html, "", "<!doctype html><title>REAL-NAVDOC</title>REAL:navdoc");
    if (std.mem.startsWith(u8, path, "/s/")) {
        const body = std.fmt.bufPrint(&bb, "REAL:{s}", .{target}) catch return;
        return reply(conn, "200 OK", "text/plain", "", body);
    }
    // 검증 고침(mkfix4): 느린 진짜 문서 — 사용자 이동이 아직 가는 동안(옛 문서가 살아 있는 동안) 에이전트의 eval 이 같은 주소로 몬다.
    if (std.mem.startsWith(u8, path, "/m/x4d2slow")) os.sleepMs(800);
    // 그 밖은 진짜 — 문서처럼 보이는 글(`REAL:` 로 시작).
    const body = std.fmt.bufPrint(&bb, "REAL:{s}", .{target}) catch return;
    const is_doc = std.mem.endsWith(u8, path, "doc") or std.mem.startsWith(u8, path, "/m/after");
    if (is_doc) {
        const doc = std.fmt.bufPrint(&bb, "<!doctype html><title>REAL</title>REAL:{s}", .{target}) catch return;
        return reply(conn, "200 OK", html, "Access-Control-Allow-Origin: *\r\n", doc);
    }
    return reply(conn, "200 OK", "text/plain", "Access-Control-Allow-Origin: *\r\n", body);
}

// ── 판정자(maru 역할) ──────────────────────────────────────────────────────────────────────────────────────

const max_tabs = 16;

const End = struct { browser: u64 = 0, request: u64 = 0, url: [256]u8 = undefined, url_len: usize = 0, ended: bool = false, flags: msg.NetEndFlags = .{}, rule: u32 = 0, error_code: i32 = 0, begin_mocked: bool = false, status: u16 = 0, received: u64 = 0 };
const Hit = struct { browser: u64, rule: u32, hits: u64 = 0, sw_not_mocked: u64 = 0, frame_not_mocked: u64 = 0 };

/// 가짜 규칙 하나(판정자가 maru 처럼 만든다).
const Spec = struct {
    id: u32,
    pattern: []const u8,
    site: []const u8 = "127.0.0.1",
    types: u32 = 0,
    methods: u8 = 0,
    exec_site: []const u8 = "",
    human: bool = false,
    status: u16 = 200,
    content_type: []const u8 = mr.default_text_type,
    location: []const u8 = "",
    headers: []const [2][]const u8 = &.{},
    body: []const u8 = "",
    /// 본문 번호(0 이면 규칙 번호로) — 같은 본문을 다시 보내지 않게 고정할 때.
    body_id: u32 = 0,
};

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    next_call: u32 = 100,
    result: std.ArrayList(u8) = .empty,
    created: [max_tabs]bool = @splat(false),
    loads: [max_tabs]u32 = @splat(0),
    urls: [max_tabs]u32 = @splat(0),
    last_url: [max_tabs][256]u8 = undefined,
    last_url_len: [max_tabs]usize = @splat(0),
    state_gen: [max_tabs]u32 = @splat(0),
    state_ok: [max_tabs]bool = @splat(false),
    strict: [max_tabs]msg.NetStrictState = @splat(.off),
    unrecorded: [max_tabs]u64 = @splat(0),
    busy: [max_tabs]u64 = @splat(0),
    skipped: [max_tabs]u64 = @splat(0),
    page_controlled: [max_tabs]bool = @splat(false),
    reqs: std.ArrayList(End) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    acked: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    sent_body: usize = 0,
    acked_total: usize = 0,
    downloads: u32 = 0,
    failures: u32 = 0,
    gen: u32 = 0,
    /// 본문 번호 — maru 처럼 보낼 때마다 새 번호(같은 번호를 다시 보내지 않는다).
    next_body: u32 = 10_000,
    /// 판정 동안 sidecar 가 보낸 frame 수(가짜 길이 새 frame 을 만들지 않는가 — mock-no-request-echo).
    frames: [64]u32 = @splat(0),
    /// main 위로 옮김: W9d② 본문(요청 번호 → 받은 바이트·끝 상태)과 막기의 엄격 상태.
    bodies: std.AutoHashMapUnmanaged(u64, Body) = .empty,
    block_strict: [max_tabs]msg.NetStrictState = @splat(.off),
    block_gen: [max_tabs]u32 = @splat(0),

    const Body = struct { data: std.ArrayList(u8) = .empty, state: ?msg.NetBodyState = null };

    fn take(self: *Run, m: msg.Message) void {
        self.frames[@backingInt(std.meta.activeTag(m)) % 64] += 1;
        switch (m) {
            .browser_created => |id| if (id < max_tabs) {
                self.created[id] = true;
            },
            .load_finished => |v| if (v.browser < max_tabs) {
                self.loads[v.browser] += 1;
            },
            .url_changed => |v| if (v.browser < max_tabs) {
                self.urls[v.browser] += 1;
                const n = @min(v.url.len, 256);
                @memcpy(self.last_url[v.browser][0..n], v.url[0..n]);
                self.last_url_len[v.browser] = n;
            },
            .failure => self.failures += 1,
            .net_mock_state => |v| if (v.browser < max_tabs) {
                self.state_gen[v.browser] = v.generation;
                self.state_ok[v.browser] = v.ok;
                self.strict[v.browser] = v.strict;
            },
            .net_mock_ack => |v| {
                const prev = self.acked.get(v.body_id) orelse 0;
                if (v.received > prev) {
                    self.acked_total += v.received - prev;
                    self.acked.put(self.gpa, v.body_id, v.received) catch {};
                }
            },
            .net_mock_hits => |v| if (v.browser < max_tabs) {
                self.unrecorded[v.browser] += v.unrecorded;
                self.busy[v.browser] += v.busy;
                self.skipped[v.browser] += v.skipped_unknown_page;
                if (v.page_controlled) self.page_controlled[v.browser] = true;
                for (v.entries[0..v.count]) |e| {
                    const h = for (self.hits.items) |*h| {
                        if (h.browser == v.browser and h.rule == e.rule_id) break h;
                    } else blk: {
                        self.hits.append(self.gpa, .{ .browser = v.browser, .rule = e.rule_id }) catch return;
                        break :blk &self.hits.items[self.hits.items.len - 1];
                    };
                    h.hits += e.hits;
                    h.sw_not_mocked += e.sw_not_mocked;
                    h.frame_not_mocked += e.frame_not_mocked;
                }
            },
            .net_begin => |v| {
                var e: End = .{ .browser = v.browser, .request = v.request, .begin_mocked = v.flags2.mocked };
                const n = @min(v.url.len, e.url.len);
                @memcpy(e.url[0..n], v.url[0..n]);
                e.url_len = n;
                self.reqs.append(self.gpa, e) catch {};
            },
            .net_response => |v| if (self.findReq(v.browser, v.request)) |e| {
                e.status = v.status;
            },
            .net_end => |v| if (self.findReq(v.browser, v.request)) |e| {
                e.ended = true;
                e.flags = v.flags;
                e.rule = v.rule_id;
                e.error_code = v.error_code;
                e.received = v.received;
            },
            .download_begin => self.downloads += 1,
            .net_body_data => |v| {
                const g = self.bodies.getOrPut(self.gpa, v.request) catch return;
                if (!g.found_existing) g.value_ptr.* = .{};
                if (v.offset == g.value_ptr.data.items.len) g.value_ptr.data.appendSlice(self.gpa, v.bytes) catch {};
            },
            .net_body_end => |v| {
                const g = self.bodies.getOrPut(self.gpa, v.request) catch return;
                if (!g.found_existing) g.value_ptr.* = .{};
                g.value_ptr.state = v.state;
            },
            .net_block_state => |v| if (v.browser < max_tabs) {
                self.block_gen[v.browser] = v.generation;
                self.block_strict[v.browser] = v.strict;
            },
            else => {},
        }
    }

    fn blockStrictAt(self: *Run, b: u64, want: u32) bool {
        return self.block_gen[b] == want and self.block_strict[b] != .off;
    }

    fn findReq(self: *Run, b: u64, request: u64) ?*End {
        var i = self.reqs.items.len;
        while (i > 0) {
            i -= 1;
            const e = &self.reqs.items[i];
            if (e.browser == b and e.request == request and !e.ended) return e;
        }
        return null;
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

    /// 규칙을 하나씩 보내고 맺는다 — 답(그 세대)을 기다린다(엄격이면 엄격 상태가 정해질 때까지). `bodies` 면 본문도 창 안에서 보낸다.
    fn mock(self: *Run, b: u64, specs: []const Spec, strict_site: []const u8, bodies: bool) !bool {
        self.gen += 1;
        var ids: [64]u32 = undefined;
        for (specs, 0..) |s, i| {
            var hb: nf.HeaderBuilder = .{};
            for (s.headers) |h| _ = hb.add(h[0], h[1]);
            const body_id: u32 = if (s.body.len == 0) 0 else if (s.body_id != 0) s.body_id else blk: {
                self.next_body += 1;
                break :blk self.next_body;
            };
            ids[i] = body_id;
            try self.host.send(.{ .net_mock_rule = .{ .browser = b, .generation = self.gen, .index = @intCast(i), .id = s.id, .types = s.types, .methods = s.methods, .flags = .{ .exec_site_bound = s.exec_site.len != 0, .human_nav_real = s.human }, .site = s.site, .exec_site = s.exec_site, .pattern = s.pattern, .status = s.status, .body_id = body_id, .body_len = @intCast(s.body.len), .content_type = s.content_type, .location = s.location, .headers = hb.block() } });
        }
        try self.host.send(.{ .net_mock_commit = .{ .browser = b, .generation = self.gen, .count = @intCast(specs.len), .strict_site = strict_site } });
        const got = if (strict_site.len != 0) self.until(strictSettled, b, self.gen, wait_ms) else self.until(stateAt, b, self.gen, wait_ms);
        if (bodies) for (specs, 0..) |s, i| if (s.body.len != 0) try self.sendBody(b, ids[i], s.body);
        return got and self.state_ok[b];
    }

    /// 본문을 16 KiB 조각으로 — 확인받지 않은 바이트가 256 KiB 를 넘지 않게(maru 의 창과 같다).
    fn sendBody(self: *Run, b: u64, body_id: u32, data: []const u8) !void {
        var off: usize = 0;
        while (off < data.len) {
            const k = @min(msg.net_mock_chunk_bytes, data.len - off);
            const deadline = os.nowMs() + wait_ms;
            while (self.sent_body + k - self.acked_total > mr.window_bytes and os.nowMs() < deadline) {
                const m = (self.host.next(50) catch null) orelse continue;
                self.take(m);
            }
            if (self.sent_body + k - self.acked_total > mr.window_bytes) return error.WindowStuck;
            try self.host.send(.{ .net_mock_body = .{ .browser = b, .body_id = body_id, .offset = @intCast(off), .total = @intCast(data.len), .bytes = data[off..][0..k] } });
            self.sent_body += k;
            off += k;
        }
    }

    fn hitOf(self: *Run, b: u64, rule: u32) Hit {
        self.pump(80);
        for (self.hits.items) |h| if (h.browser == b and h.rule == rule) return h;
        return .{ .browser = b, .rule = rule };
    }

    fn endOf(self: *Run, b: u64, needle: []const u8) ?End {
        var i = self.reqs.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.reqs.items[i];
            if (e.browser == b and std.mem.indexOf(u8, e.url[0..e.url_len], needle) != null) return e;
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

    fn ev(self: *Run, browser: u64, expr: []const u8, out: []u8) []const u8 {
        var pb: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&pb);
        w.writeAll("{\"returnByValue\":true,\"awaitPromise\":true,\"expression\":") catch return "<arg>";
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
            .bool => |bv| if (bv) "true" else "false",
            .integer => |k| std.fmt.bufPrint(out, "{d}", .{k}) catch "<n>",
            .float => |f| std.fmt.bufPrint(out, "{d}", .{f}) catch "<n>",
            else => "<other>",
        };
    }

    /// 사람의 누름(maru 의 `mouse` — 사이드카의 사람 입력 길).
    fn humanClick(self: *Run, b: u64, x: i32, y: i32) !void {
        try self.host.send(.{ .set_focus = .{ .browser = b, .value = true } });
        try self.host.send(.{ .mouse = .{ .browser = b, .kind = .down, .point = .{ .x = x, .y = y }, .click_count = 1 } });
        try self.host.send(.{ .mouse = .{ .browser = b, .kind = .up, .point = .{ .x = x, .y = y }, .click_count = 1 } });
    }

    /// 에이전트의 누름(DevTools `Input.dispatchMouseEvent` — maru 를 지나지 않는다).
    fn agentClick(self: *Run, b: u64, x: i32, y: i32) void {
        var pb: [256]u8 = undefined;
        _ = self.call(b, "Input.dispatchMouseEvent", std.fmt.bufPrint(&pb, "{{\"type\":\"mousePressed\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}", .{ x, y }) catch unreachable, 5000) catch {};
        _ = self.call(b, "Input.dispatchMouseEvent", std.fmt.bufPrint(&pb, "{{\"type\":\"mouseReleased\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}", .{ x, y }) catch unreachable, 5000) catch {};
    }
};

fn uLoop(buf: []u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, path }) catch unreachable;
}

fn uLocal(buf: []u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://localhost:{d}{s}", .{ port, path }) catch unreachable;
}

fn pat(buf: []u8, host: []const u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://{s}:{d}{s}", .{ host, port, path }) catch unreachable;
}

const js_fetch_head = "(async()=>{try{const r=await fetch(";
const js_fetch_tail = ");return 'ok '+r.status+' '+(r.headers.get('content-type')||'')+' '+(await r.text()).slice(0,120)}catch(e){return 'reject '+e.name}})()";

fn fetchExpr(buf: []u8, u: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}'{s}'{s}", .{ js_fetch_head, u, js_fetch_tail }) catch unreachable;
}

fn starts(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

fn contains(s: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, s, needle) != null;
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

/// 판정자 훅: 가짜에 `Set-Cookie` 를 실어 쿠키 필터(두 겹의 둘째)를 잰다 — 머리 허용 목록은 codec 이 이미 거절하므로 wire 로는 실을 수 없다.
const env_log: [*:0]const u8 = "MARU_WEB_TEST_MOCK_LOG=1";
const env_inject: [*:0]const u8 = "MARU_WEB_TEST_MOCK_INJECT_SET_COOKIE=1";

pub fn run(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    // 판정자 손잡이(sidecar 는 읽지 않는다): `MOCK_ONLY=port` 면 main 위로 옮긴 판의 항목만, `fix4` 면 검증 SEVERE 넷 고침의 항목만.
    if (std.c.getenv("MOCK_ONLY")) |only| {
        if (std.mem.eql(u8, std.mem.span(only), "port")) {
            portChecks(report, host_path, root) catch |err| report(false, "mock-port", @errorName(err));
            return;
        }
        if (std.mem.eql(u8, std.mem.span(only), "fix4")) {
            fix4Checks(report, host_path, root) catch |err| report(false, "mock-fix4", @errorName(err));
            return;
        }
    }
    tabPath(report, host_path, root) catch |err| report(false, "mock-tab-path", @errorName(err));
    humanClicks(report, host_path, root) catch |err| report(false, "mock-human-click", @errorName(err));
    serviceWorker(report, host_path, root) catch |err| report(false, "mock-sw", @errorName(err));
    poolAndBodies(report, host_path, root) catch |err| report(false, "mock-pool", @errorName(err));
    restart(report, host_path, root) catch |err| report(false, "mock-restart", @errorName(err));
    cost(report, host_path, root) catch |err| report(false, "mock-cost", @errorName(err));
    portChecks(report, host_path, root) catch |err| report(false, "mock-port", @errorName(err));
    fix4Checks(report, host_path, root) catch |err| report(false, "mock-fix4", @errorName(err));
}

// ── 탭 길 ─────────────────────────────────────────────────────────────────────────────────────────────────

fn tabPath(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "mk1", &.{ env_log, env_inject });
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [700]u8 = undefined;
    var pbuf: [24][160]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    const big = try std.heap.c_allocator.alloc(u8, mr.max_body_bytes);
    defer std.heap.c_allocator.free(big);
    for (big, 0..) |*b, i| b.* = if (i % 64 == 63) '\n' else 'a' + @as(u8, @intCast(i % 26));
    const xhr_bit = mr.typeBits("xhr").?;
    const specs = [_]Spec{
        .{ .id = 1, .pattern = pat(&pbuf[0], "127.0.0.1", "/m/api*"), .types = xhr_bit, .content_type = "application/json", .body = "{\"mock\":\"api\"}" },
        .{ .id = 2, .pattern = pat(&pbuf[1], "127.0.0.1", "/m/s404"), .types = xhr_bit, .status = 404, .content_type = "application/json", .headers = &.{.{ "X-Mock", "1" }}, .body = "{\"err\":1}" },
        .{ .id = 3, .pattern = pat(&pbuf[2], "127.0.0.1", "/m/empty204"), .status = 204 },
        .{ .id = 4, .pattern = pat(&pbuf[3], "127.0.0.1", "/m/big"), .types = xhr_bit, .body = big },
        .{ .id = 5, .pattern = pat(&pbuf[4], "127.0.0.1", "/m/s.js"), .types = mr.typeBits("script").?, .content_type = "text/javascript", .body = "window.mjs=(window.mjs||0)+1;" },
        .{ .id = 6, .pattern = pat(&pbuf[5], "127.0.0.1", "/m/c.css"), .types = mr.typeBits("stylesheet").?, .content_type = "text/css", .body = "body{--m:mocked}" },
        .{ .id = 7, .pattern = pat(&pbuf[6], "127.0.0.1", "/m/i.svg"), .content_type = "image/svg+xml", .body = "<svg xmlns='http://www.w3.org/2000/svg' width='7' height='9'/>" },
        .{ .id = 8, .pattern = pat(&pbuf[7], "127.0.0.1", "/m/w.js"), .types = mr.typeBits("worker").?, .content_type = "text/javascript", .body = "postMessage('mocked-worker')" },
        .{ .id = 9, .pattern = pat(&pbuf[8], "127.0.0.1", "/m/sse"), .types = xhr_bit | mr.typeBits("other").?, .content_type = "text/event-stream", .body = "data: m1\n\ndata: m2\n\n" },
        .{ .id = 10, .pattern = pat(&pbuf[9], "127.0.0.1", "/m/pf"), .types = mr.typeBits("prefetch").?, .body = "MOCK-PF" },
        .{ .id = 11, .pattern = pat(&pbuf[10], "127.0.0.1", "/m/pr"), .content_type = "text/html; charset=utf-8", .body = "<!doctype html><title>MOCK-PR</title>pr" },
        .{ .id = 12, .pattern = pat(&pbuf[11], "127.0.0.1", "/m/fav.ico"), .types = mr.typeBits("favicon").?, .content_type = "image/svg+xml", .body = "<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'/>" },
        .{ .id = 13, .pattern = pat(&pbuf[12], "127.0.0.1", "/m/maindoc"), .content_type = "text/html; charset=utf-8", .headers = &.{.{ "Content-Security-Policy", "script-src 'none'" }}, .body = "<!doctype html><title>MOCKED-DOC</title><script>window.ran=1</script>mocked" },
        .{ .id = 14, .pattern = pat(&pbuf[13], "127.0.0.1", "/m/samedoc"), .content_type = "text/html; charset=utf-8", .body = "<!doctype html><title>MS</title><script>parent.postMessage('same:'+document.title,'*')</script>" },
        // 다른 사이트 iframe 문서(localhost) — 사이트 127.0.0.1 에 묶인 grant(실행 사이트 127.0.0.1)는 덮지 않는다(M25).
        .{ .id = 15, .pattern = pat(&pbuf[14], "localhost", "/m/xsdoc"), .exec_site = "127.0.0.1", .content_type = "text/html; charset=utf-8", .body = "<!doctype html><title>MX</title><script>parent.postMessage('xs:mocked','*')</script>" },
        .{ .id = 16, .pattern = pat(&pbuf[15], "127.0.0.1", "/m/redir"), .types = xhr_bit, .status = 302, .location = "/m/afterreal" },
        .{ .id = 17, .pattern = pat(&pbuf[16], "127.0.0.1", "/m/loop"), .types = xhr_bit, .status = 302, .location = "/m/loop" },
        .{ .id = 18, .pattern = pat(&pbuf[17], "localhost", "/m/cors-none"), .types = xhr_bit, .body = "cors" },
        .{ .id = 19, .pattern = pat(&pbuf[18], "localhost", "/m/cors-star"), .types = xhr_bit, .methods = mr.methodBit("PUT").? | mr.methodBit("GET").?, .headers = &.{.{ "Access-Control-Allow-Origin", "*" }}, .body = "cors-star" },
        .{ .id = 20, .pattern = pat(&pbuf[19], "127.0.0.1", "/m/xoredir"), .types = xhr_bit, .status = 302, .location = uLocal(&pbuf[20], "/c/echo?via-mock") },
        .{ .id = 21, .pattern = pat(&pbuf[21], "127.0.0.1", "/m/post"), .types = xhr_bit, .methods = mr.methodBit("POST").?, .body = "MOCK-POST" },
        .{ .id = 22, .pattern = pat(&pbuf[22], "127.0.0.1", "/m/nsdoc"), .content_type = "text/html; charset=utf-8", .body = "<!doctype html><title>MOCK-NS</title>ns" },
    };
    const applied = try r.mock(1, &specs, "", true);
    report(applied, "mock-rules-applied", std.fmt.bufPrint(&d, "net_mock 세대 {d} — ok, 본문 확인 {d}/{d} 바이트", .{ r.gen, r.acked_total, r.sent_body }) catch "");

    // 하위 자원 갈래.
    {
        const got = r.ev(1, fetchExpr(&x, "/m/api1"), &o);
        const e = r.endOf(1, "/m/api1");
        r.pump(300);
        const e2 = r.endOf(1, "/m/api1");
        _ = e;
        const flagged = if (e2) |v| v.ended and v.flags.mocked and v.rule == 1 and v.begin_mocked else false;
        report(starts(got, "ok 200 application/json {\"mock\":\"api\"}") and seen("/m/api1") == 0 and flagged, "mock-fetch", std.fmt.bufPrint(&d, "페이지 {s} · 서버 {d} · 끝 mocked·규칙 1·시작 mocked {}", .{ got, seen("/m/api1"), flagged }) catch "");
    }
    {
        const got = r.ev(1, "new Promise(res=>{const x=new XMLHttpRequest();x.open('GET','/m/api2');x.onload=()=>res('load '+x.status+' '+x.responseText);x.onerror=()=>res('error');x.send()})", &o);
        report(starts(got, "load 200 {\"mock\"") and seen("/m/api2") == 0, "mock-xhr", got);
    }
    {
        const got = r.ev(1, "(async()=>{const r=await fetch('/m/api3',{method:'HEAD'});return r.status+' cl='+r.headers.get('content-length')+' len='+(await r.text()).length})()", &o);
        report(contains(got, "len=0") and seen("/m/api3") == 0, "mock-head-empty", std.fmt.bufPrint(&d, "HEAD — {s}(가짜 본문을 싣지 않는다 — 실측 M3)", .{got}) catch "");
    }
    {
        const got = r.ev(1, "(async()=>{const a=await (await fetch('/m/post',{method:'POST',body:'x'})).text();const b=await (await fetch('/m/post')).text();return a+' | '+b})()", &o);
        r.pump(200);
        report(starts(got, "MOCK-POST | REAL:") and seen("POST /m/post") == 0 and seen("GET /m/post") == 1, "mock-post", std.fmt.bufPrint(&d, "POST 규칙: POST {s} · 서버 POST {d} GET {d}", .{ got, seen("POST /m/post"), seen("GET /m/post") }) catch "");
    }
    {
        const got = r.ev(1, "(async()=>{const r=await fetch('/m/s404');return r.status+' '+r.headers.get('content-type')+' x='+r.headers.get('x-mock')+' cc='+r.headers.get('cache-control')+' '+(await r.text())})()", &o);
        report(starts(got, "404 application/json x=1 cc=no-store {\"err\":1}"), "mock-status-404-ct", std.fmt.bufPrint(&d, "{s}(200 밖에서도 Content-Type 머리 — M20, 늘 no-store — M21)", .{got}) catch "");
    }
    {
        const got = r.ev(1, "(async()=>{const r=await fetch('/m/empty204');return r.status+' len='+(await r.text()).length})()", &o);
        report(std.mem.eql(u8, got, "204 len=0") and seen("/m/empty204") == 0, "mock-empty-204", got);
    }
    {
        const got = r.ev(1, "(async()=>{const r=await fetch('/m/big');const t=await r.text();return r.status+' cl='+r.headers.get('content-length')+' len='+t.length})()", &o);
        var want: [64]u8 = undefined;
        const w = std.fmt.bufPrint(&want, "200 cl={d} len={d}", .{ mr.max_body_bytes, mr.max_body_bytes }) catch "";
        report(std.mem.eql(u8, got, w), "mock-big-512k", got);
        report(contains(got, "cl=524288"), "mock-content-length", "Content-Length 머리 = 본문 길이");
    }
    {
        const got = r.ev(1, "new Promise(res=>{const s=document.createElement('script');s.src='/m/s.js';s.onload=()=>res('load '+window.mjs);s.onerror=()=>res('error');document.head.appendChild(s)})", &o);
        report(std.mem.eql(u8, got, "load 1") and seen("/m/s.js") == 0, "mock-script", got);
    }
    {
        const got = r.ev(1, "new Promise(res=>{const l=document.createElement('link');l.rel='stylesheet';l.href='/m/c.css';l.onload=()=>res('load '+getComputedStyle(document.body).getPropertyValue('--m'));l.onerror=()=>res('error');document.head.appendChild(l)})", &o);
        report(std.mem.eql(u8, got, "load mocked") and seen("/m/c.css") == 0, "mock-css", got);
    }
    {
        const got = r.ev(1, "new Promise(res=>{const i=new Image();i.onload=()=>res('load '+i.naturalWidth+'x'+i.naturalHeight);i.onerror=()=>res('error');i.src='/m/i.svg'})", &o);
        report(std.mem.eql(u8, got, "load 7x9") and seen("/m/i.svg") == 0, "mock-img", got);
    }
    {
        const got = r.ev(1, "new Promise(res=>{const w=new Worker('/m/w.js');w.onmessage=e=>res('msg '+e.data);w.onerror=()=>res('error');setTimeout(()=>res('timeout'),5000)})", &o);
        report(std.mem.eql(u8, got, "msg mocked-worker") and seen("/m/w.js") == 0, "mock-worker", got);
    }
    {
        const got = r.ev(1, "new Promise(res=>{const s=new EventSource('/m/sse');const got=[];s.onmessage=e=>{got.push(e.data);if(got.length==2){s.close();res('sse '+got.join(','))}};s.onerror=()=>{s.close();res('error '+got.join(','))};setTimeout(()=>res('timeout'),5000)})", &o);
        report(starts(got, "sse m1,m2") and seen("/m/sse") == 0, "mock-sse", got);
    }
    // 주 프레임 문서 — 에이전트 이동: 주소창이 가짜 주소로, CSP 머리가 듣는다, 끝은 mocked.
    {
        const urls_before = r.urls[1];
        try r.nav(1, uLoop(&u, "/m/maindoc"), false);
        r.pump(300);
        const view = r.ev(1, "document.title+' ran='+(window.ran||0)", &o);
        const e = r.endOf(1, "/m/maindoc");
        const flagged = if (e) |v| v.flags.mocked and v.rule == 13 else false;
        report(std.mem.eql(u8, view, "MOCKED-DOC ran=0") and r.urls[1] > urls_before and seen("/m/maindoc") == 0 and flagged, "mock-main-frame", std.fmt.bufPrint(&d, "{s} · url_changed {d} · 서버 {d} · 끝 mocked {}", .{ view, r.urls[1] - urls_before, seen("/m/maindoc"), flagged }) catch "");
    }
    // prefetch·speculation(번호 0)·favicon.
    {
        try r.nav(1, uLoop(&u, "/p/pf"), false);
        r.pump(2500);
        report(seen("/m/pf") == 0, "mock-prefetch", std.fmt.bufPrint(&d, "<link rel=prefetch> 서버 {d}", .{seen("/m/pf")}) catch "");
        report(seen("/m/pr") == 0, "mock-speculation-id0", std.fmt.bufPrint(&d, "speculation prerender 서버 {d}", .{seen("/m/pr")}) catch "");
        try r.nav(1, uLoop(&u, "/p/favicon"), false);
        r.pump(1500);
        report(seen("/m/fav.ico") == 0, "mock-favicon", std.fmt.bufPrint(&d, "favicon 서버 {d}", .{seen("/m/fav.ico")}) catch "");
    }
    // iframe — 같은 사이트는 가짜, 다른 사이트(localhost) 문서는 실행 사이트가 덮지 않아 진짜(M25).
    {
        try r.nav(1, uLoop(&u, "/p/frames"), false);
        r.pump(1500);
        const msgs = r.ev(1, "JSON.stringify(window.msgs)", &o);
        report(contains(msgs, "same:MS") and seen("/m/samedoc") == 0, "mock-iframe-same-site", msgs);
        report(!contains(msgs, "xs:mocked") and seen("/m/xsdoc") == 1, "mock-oopif-site-bound", std.fmt.bufPrint(&d, "{s} · 서버 /m/xsdoc {d}(실행 사이트 127.0.0.1 이 localhost 문서를 덮지 않는다)", .{ msgs, seen("/m/xsdoc") }) catch "");
    }
    // 리다이렉트 — 가짜 302 → 진짜 대상(다음 홉은 다시 고른다), 고리, 다른 출처 진짜로의 가짜 리다이렉트.
    {
        try r.nav(1, uLoop(&u, "/p/sub?r1"), false);
        const got = r.ev(1, "(async()=>{const r=await fetch('/m/redir');return r.status+' red='+r.redirected+' '+(await r.text())})()", &o);
        r.pump(300);
        const e = r.endOf(1, "/m/redir");
        const flagged = if (e) |v| v.flags.mock_redirected and !v.flags.mocked and v.rule == 16 and !v.begin_mocked else false;
        report(starts(got, "200 red=true ") and contains(got, "REAL:/m/afterreal") and seen("/m/redir") == 0 and seen("/m/afterreal") == 1, "mock-redirect-location", got);
        report(flagged, "mock-redirect-hop-rematch", std.fmt.bufPrint(&d, "끝 mock_redirected·규칙 16·마지막 응답은 진짜 {}", .{flagged}) catch "");
        const loop = r.ev(1, "(async()=>{try{await fetch('/m/loop');return 'ok'}catch(e){return 'reject '+e.name}})()", &o);
        report(starts(loop, "reject TypeError") and seen("/m/loop") == 0, "mock-redirect-loop", std.fmt.bufPrint(&d, "가짜 A→A: {s}(Chromium 의 리다이렉트 상한)", .{loop}) catch "");
        var o2: [600]u8 = undefined;
        const xo = r.ev(1, "(async()=>{const a=await fetch('/m/xoredir',{mode:'no-cors'}).then(r=>r.type+' '+r.status,e=>'reject');let b;try{b=await (await fetch('/m/xoredir')).text()}catch(e){b='reject '+e.name}return a+' | '+b})()", &o2);
        report(starts(xo, "opaque 0 | reject") or starts(xo, "opaqueredirect"), "mock-nocors-redirect-opaque", std.fmt.bufPrint(&d, "가짜 302 → 다른 출처 진짜(쿠키): {s}(M19 — 진짜 다른 출처를 읽는 길이 없다)", .{xo}) catch "");
    }
    // CORS — 다른 출처 가짜: ACAO 없음 실패, `*` 됨, preflight 없음.
    {
        var cu: [600]u8 = undefined;
        const none = r.ev(1, fetchExpr(&x, uLocal(&u, "/m/cors-none")), &o);
        var o2: [600]u8 = undefined;
        const star = r.ev(1, fetchExpr(&x, uLocal(&u, "/m/cors-star")), &o2);
        const put = std.fmt.bufPrint(&cu, "(async()=>{{try{{const r=await fetch('http://localhost:{d}/m/cors-star',{{method:'PUT',headers:{{'X-A':'1'}}}});return 'ok '+r.status}}catch(e){{return 'reject '+e.name}}}})()", .{port}) catch unreachable;
        var o3: [600]u8 = undefined;
        const p3 = r.ev(1, put, &o3);
        r.pump(300);
        const e = r.endOf(1, "/m/cors-none");
        const failed_flagged = if (e) |v| v.flags.mocked and v.error_code != 0 else false;
        report(starts(none, "reject TypeError") and starts(star, "ok 200") and starts(p3, "ok 200") and seen("OPTIONS") == 0 and seen("/m/cors") == 0 and failed_flagged, "mock-cors", std.fmt.bufPrint(&d, "ACAO 없음 {s} · * {s} · PUT(preflight 없이) {s} · 서버 OPTIONS {d} · CORS 로 떨어진 가짜도 mocked {}", .{ none, star, p3, seen("OPTIONS"), failed_flagged }) catch "");
    }
    // 쿠키 필터 — 판정자 훅이 모든 가짜에 Set-Cookie 를 싣는다: 저장되지 않아야(기록하는 요청). 기록하지 않는 요청은 아래 unrecorded 에서.
    {
        _ = r.ev(1, fetchExpr(&x, "/m/api-cookie"), &o);
        var o2: [600]u8 = undefined;
        const echo = r.ev(1, fetchExpr(&x, "/c/echo"), &o2);
        var o3: [200]u8 = undefined;
        const doc_cookie = r.ev(1, "document.cookie", &o3);
        report(!contains(echo, "mkinj") and !contains(doc_cookie, "mkinj"), "mock-cookie-filter", std.fmt.bufPrint(&d, "가짜의 Set-Cookie(훅) 뒤 진짜 요청의 쿠키 {s} · document.cookie '{s}'(실측 M22 — can_save_cookie 0)", .{ echo, doc_cookie }) catch "");
    }
    // 머리 허용 목록 — codec(maru·sidecar 공용)이 금지 머리를 실은 규칙을 거절한다.
    {
        var buf: [protocol.wire.max_frame_bytes]u8 = undefined;
        var all = true;
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(std.heap.c_allocator);
        for ([_][]const u8{ "Set-Cookie", "Accept-CH", "Strict-Transport-Security", "Clear-Site-Data", "Content-Disposition", "Critical-CH", "Alt-Svc" }) |h| {
            var hb: nf.HeaderBuilder = .{};
            _ = hb.add(h, "x");
            const ok = protocol.codec.encode(.{ .net_mock_rule = .{ .browser = 1, .generation = 99, .id = 1, .types = xhr_bit, .site = "127.0.0.1", .pattern = "https://a.test/", .content_type = "text/plain", .headers = hb.block() } }, &buf);
            if (!std.meta.isError(ok)) {
                all = false;
                names.appendSlice(std.heap.c_allocator, h) catch {};
            }
        }
        const dl = protocol.codec.encode(.{ .net_mock_rule = .{ .browser = 1, .generation = 99, .id = 1, .site = "127.0.0.1", .pattern = "https://a.test/", .content_type = "application/octet-stream", .body_id = 1, .body_len = 1 } }, &buf);
        report(all and std.meta.isError(dl), "mock-header-allowlist", std.fmt.bufPrint(&d, "금지 머리 거절 {}(통과: {s}) · 문서로 맞을 수 있는 octet-stream 거절 {}", .{ all, names.items, std.meta.isError(dl) }) catch "");
    }
    // bfcache — 가짜 문서는 no-store 라 규칙을 지운 뒤 뒤로 가면 진짜를 다시 청한다(M21).
    {
        try r.nav(1, uLoop(&u, "/m/nsdoc"), false);
        const t1 = r.ev(1, "document.title", &o);
        try r.nav(1, uLoop(&u, "/p/sub?r2"), false);
        const keep = [_]Spec{specs[0]};
        _ = try r.mock(1, &keep, "", true);
        try r.action(1, .back, false);
        r.pump(500);
        var o2: [200]u8 = undefined;
        const t2 = r.ev(1, "document.title", &o2);
        report(std.mem.eql(u8, t1, "MOCK-NS") and std.mem.eql(u8, t2, "REAL") and seen("/m/nsdoc") == 1, "mock-no-store-bfcache", std.fmt.bufPrint(&d, "가짜 {s} → 규칙 지움 → 뒤로 {s} · 서버 {d}", .{ t1, t2, seen("/m/nsdoc") }) catch "");
        _ = try r.mock(1, &specs, "", true); // 지운 규칙의 본문은 sidecar 가 놓았다 — maru 처럼 다시 보낸다
    }
    // 다운로드 — 문서로 맞지 않는 규칙(xhr 만)의 주소로 이동하면 진짜(다운로드가 되는 가짜는 만들 수 없다).
    {
        const dl_before = r.downloads;
        try r.nav(1, uLoop(&u, "/m/apidoc"), false);
        r.pump(500);
        var o2: [200]u8 = undefined;
        const t = r.ev(1, "document.title", &o2);
        report(std.mem.eql(u8, t, "REAL") and r.downloads == dl_before, "mock-download-refused", std.fmt.bufPrint(&d, "xhr 규칙 주소로의 이동 — {s}(가짜 아님) · 다운로드 {d}", .{ t, r.downloads - dl_before }) catch "");
    }
    // 막기가 이긴다 — 같은 주소에 막기 규칙(net_block)과 가짜 규칙.
    {
        try r.nav(1, uLoop(&u, "/p/sub?r3"), false);
        var bp: [160]u8 = undefined;
        var v: msg.NetBlock = .{ .browser = 1, .generation = 1, .count = 1 };
        v.rules[0] = .{ .id = 77, .site = "127.0.0.1", .pattern = pat(&bp, "127.0.0.1", "/m/api-bw") };
        try r.host.send(.{ .net_block = v });
        r.pump(300);
        const got = r.ev(1, fetchExpr(&x, "/m/api-bw"), &o);
        r.pump(300);
        const e = r.endOf(1, "/m/api-bw");
        const flagged = if (e) |ee| ee.flags.blocked and !ee.flags.mocked and ee.rule == 77 else false;
        report(starts(got, "reject TypeError") and flagged and seen("/m/api-bw") == 0, "mock-block-wins", std.fmt.bufPrint(&d, "{s} · 끝 blocked·규칙 77·mocked 아님 {}", .{ got, flagged }) catch "");
        try r.host.send(.{ .net_block = .{ .browser = 1, .generation = 2 } });
        r.pump(200);
    }
    // D2 — 가짜만 있는 탭(막기 규칙 없음)에서 사용자가 친 주소·사용자 새로고침의 주 문서는 진짜, 그 페이지의 하위 자원은 가짜, 에이전트 이동은 가짜.
    {
        try r.nav(1, uLoop(&u, "/m/maindoc"), true);
        var o2: [200]u8 = undefined;
        const typed = r.ev(1, "document.title", &o2);
        var o3: [300]u8 = undefined;
        const sub = r.ev(1, fetchExpr(&x, "/m/api-d2"), &o3);
        try r.action(1, .reload, true);
        var o4: [200]u8 = undefined;
        const reload = r.ev(1, "document.title", &o4);
        try r.action(1, .reload, false);
        var o5: [200]u8 = undefined;
        const agent = r.ev(1, "document.title", &o5);
        report(std.mem.eql(u8, typed, "REAL") and starts(sub, "ok 200 application/json {\"mock\"") and std.mem.eql(u8, reload, "REAL") and std.mem.eql(u8, agent, "MOCKED-DOC"), "mock-user-nav-exempt", std.fmt.bufPrint(&d, "주소창 {s} · 하위 자원 {s} · 사용자 새로고침 {s} · 에이전트 새로고침 {s}(막기 규칙 없는 탭 — §13 P2-1)", .{ typed, sub, reload, agent }) catch "");
    }
    // 문이 떨어뜨린 요청도 가짜(기록 없이) — 쿠키 필터도. 100 개씩 여덟 번(한꺼번에 800 개면 탭의 처리기 자리 128 을 넘어 나머지는 설계대로 -12 다 —
    // 그것은 `mock-pool-busy` 가 본다).
    {
        try r.nav(1, uLoop(&u, "/p/sub?r4"), false);
        const got = r.ev(1, "(async()=>{let n=0;for(let b=0;b<8;b++){const ps=[];for(let i=0;i<100;i++)ps.push(fetch('/m/api-fl'+(b*100+i)).then(r=>r.text()).then(t=>t.startsWith('{\"mock\"')?1:0,()=>0));n+=(await Promise.all(ps)).reduce((a,c)=>a+c,0)}return String(n)})()", &o);
        r.pump(1500);
        var o2: [300]u8 = undefined;
        const echo = r.ev(1, fetchExpr(&x, "/c/echo?after-flood"), &o2);
        report(std.mem.eql(u8, got, "800") and seen("/m/api-fl") == 0 and r.unrecorded[1] > 0 and !contains(echo, "mkinj"), "mock-unrecorded", std.fmt.bufPrint(&d, "가짜 {s}/800 · 서버 {d} · 기록 없이 가짜 {d} · 쿠키 {s}", .{ got, seen("/m/api-fl"), r.unrecorded[1], echo }) catch "");
    }
    // 가짜 길이 새 frame 을 만들지 않는다(요청 머리를 어디에도 보내지 않는다) — 가짜 fetch 하나 동안 sidecar 가 보낸 frame 종류.
    {
        r.pump(500);
        const before = r.frames;
        _ = r.ev(1, fetchExpr(&x, "/m/api-echo"), &o);
        r.pump(500);
        var extra = false;
        for (before, r.frames, 0..) |a, b, i| {
            if (b == a) continue;
            const value: u8 = @intCast(if (i < 32) i + 64 else i); // maru 로 오는 tag 는 32..127 — `take` 가 64 로 나눈 나머지에 셌다
            const tag: msg.Tag = std.enums.fromInt(msg.Tag, value) orelse {
                extra = true;
                continue;
            };
            switch (tag) {
                .net_begin, .net_response, .net_end, .net_mock_hits, .devtools_result, .devtools_result_data => {},
                else => extra = true,
            }
        }
        report(!extra, "mock-no-request-echo", "가짜 fetch 동안 기록·수·DevTools 답 밖의 frame 없음");
    }
    // DevTools 지킴 — 가짜를 scope·▣ 없이 만드는 길(Fetch.*·setRequestInterception).
    {
        const a = r.call(1, "Fetch.enable", "{}", 5000) catch null;
        const b = r.call(1, "Fetch.fulfillRequest", "{\"requestId\":\"1\",\"responseCode\":200}", 5000) catch null;
        const c = r.call(1, "Network.setRequestInterception", "{\"patterns\":[]}", 5000) catch null;
        report(a == .invalid_request and b == .invalid_request and c == .invalid_request, "mock-devtools-guard", std.fmt.bufPrint(&d, "Fetch.enable {?} · Fetch.fulfillRequest {?} · setRequestInterception {?}", .{ a, b, c }) catch "");
    }
    {
        const h = r.hitOf(1, 1);
        report(h.hits >= 800 and r.failures == 0, "mock-hits", std.fmt.bufPrint(&d, "규칙 1 hits {d} · sidecar failure {d}", .{ h.hits, r.failures }) catch "");
    }
}

// ── 사람·에이전트의 누름(Q2) ────────────────────────────────────────────────────────────────────────────────

/// 사용자 결정 Q2(2026-10-21 「사용자 탭은 진짜로」): 사용자 탭 규칙(`human_nav_real`)은 사람이 누른 링크·폼으로 시작한 이동의 주 문서에 듣지
/// 않는다. 에이전트의 DevTools 누름(사람 입력 없이)에는 듣는다. 에이전트 탭 규칙(UD2)은 둘 다 듣는다. 하위 자원은 사람 이동 뒤에도 가짜.
fn humanClicks(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "mkq2", &.{env_log});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [700]u8 = undefined;
    var pb: [8][160]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/links"));
    try r.watch(1);
    const doc = "text/html; charset=utf-8";
    const user_tab = [_]Spec{
        .{ .id = 1, .pattern = pat(&pb[0], "127.0.0.1", "/m/linkdoc*"), .human = true, .content_type = doc, .body = "<!doctype html><title>MOCK-LINK</title>m" },
        .{ .id = 2, .pattern = pat(&pb[1], "127.0.0.1", "/m/formdoc*"), .human = true, .content_type = doc, .body = "<!doctype html><title>MOCK-FORM</title>m" },
        .{ .id = 3, .pattern = pat(&pb[2], "127.0.0.1", "/m/delaydoc*"), .human = true, .content_type = doc, .body = "<!doctype html><title>MOCK-DELAY</title>m" },
        .{ .id = 4, .pattern = pat(&pb[3], "127.0.0.1", "/m/api*"), .human = true, .types = mr.typeBits("xhr").?, .content_type = "application/json", .body = "{\"mock\":1}" },
    };
    _ = try r.mock(1, &user_tab, "", true);
    const Case = struct { name: []const u8, title: []const u8 };
    var results: [6]Case = undefined;
    var n: usize = 0;
    // ① 사람의 링크 누름(maru 의 mouse) — 진짜.
    {
        const before = r.loads[1];
        try r.humanClick(1, 50, 40);
        _ = r.until(Run.loadsAt, 1, before + 1, wait_ms);
        r.pump(300);
        results[n] = .{ .name = "human-link", .title = try r.gpa.dupe(u8, r.ev(1, "document.title", &o)) };
        n += 1;
        var o2: [200]u8 = undefined;
        const sub = r.ev(1, fetchExpr(&x, "/m/api-after-human"), &o2);
        report(std.mem.eql(u8, results[0].title, "REAL") and starts(sub, "ok 200 application/json"), "mock-human-click", std.fmt.bufPrint(&d, "사용자 탭 규칙 — 사람의 링크 누름의 주 문서 {s} · 그 페이지의 하위 자원 {s}", .{ results[0].title, sub }) catch "");
    }
    // ② 사람의 폼 제출(입력칸 누름 + Enter 키) — 진짜.
    {
        try r.nav(1, uLoop(&u, "/p/links?2"), false);
        r.pump(5500); // 앞 사람 입력의 창을 넘긴다
        try r.humanClick(1, 50, 100);
        r.pump(200);
        const before = r.loads[1];
        try r.host.send(.{ .key = .{ .browser = 1, .kind = .raw_down, .windows_key_code = 13, .native_key_code = 0x24, .character = '\r', .unmodified_character = '\r' } });
        try r.host.send(.{ .key = .{ .browser = 1, .kind = .char, .windows_key_code = 13, .native_key_code = 0x24, .character = '\r', .unmodified_character = '\r' } });
        try r.host.send(.{ .key = .{ .browser = 1, .kind = .up, .windows_key_code = 13, .native_key_code = 0x24, .character = '\r', .unmodified_character = '\r' } });
        _ = r.until(Run.loadsAt, 1, before + 1, wait_ms);
        r.pump(300);
        const t = r.ev(1, "document.title", &o);
        report(std.mem.eql(u8, t, "REAL"), "mock-human-form", std.fmt.bufPrint(&d, "사람의 폼 제출(Enter) — {s}", .{t}) catch "");
    }
    // ③ 사람의 누름 뒤 1.5 초 setTimeout 이동(사용자 활성화 안) — 진짜.
    {
        try r.nav(1, uLoop(&u, "/p/links?3"), false);
        r.pump(5500);
        const before = r.loads[1];
        try r.humanClick(1, 50, 160);
        _ = r.until(Run.loadsAt, 1, before + 1, wait_ms);
        r.pump(300);
        const t = r.ev(1, "document.title", &o);
        report(std.mem.eql(u8, t, "REAL"), "mock-human-delayed", std.fmt.bufPrint(&d, "사람 누름 뒤 1.5 초 이동 — {s}", .{t}) catch "");
    }
    // ④ 에이전트의 DevTools 누름(사람 입력 없이 5 초 넘게) — 가짜.
    {
        try r.nav(1, uLoop(&u, "/p/links?4"), false);
        r.pump(5500);
        const before = r.loads[1];
        r.agentClick(1, 50, 40);
        _ = r.until(Run.loadsAt, 1, before + 1, wait_ms);
        r.pump(300);
        const t = r.ev(1, "document.title", &o);
        report(std.mem.eql(u8, t, "MOCK-LINK"), "mock-agent-click", std.fmt.bufPrint(&d, "에이전트의 DevTools 누름(사용자 탭 규칙) — {s}", .{t}) catch "");
    }
    // ⑤ 에이전트 탭 규칙(human_nav_real 거짓 — UD2) — 사람의 누름에도 가짜.
    {
        var pb2: [160]u8 = undefined;
        const agent_tab = [_]Spec{.{ .id = 5, .pattern = pat(&pb2, "127.0.0.1", "/m/linkdoc*"), .content_type = doc, .body = "<!doctype html><title>MOCK-AGENT-TAB</title>m" }};
        _ = try r.mock(1, &agent_tab, "", true);
        try r.nav(1, uLoop(&u, "/p/links?5"), false);
        r.pump(300);
        const before = r.loads[1];
        try r.humanClick(1, 50, 40);
        _ = r.until(Run.loadsAt, 1, before + 1, wait_ms);
        r.pump(300);
        const t = r.ev(1, "document.title", &o);
        report(std.mem.eql(u8, t, "MOCK-AGENT-TAB"), "mock-agent-tab-human-click", std.fmt.bufPrint(&d, "에이전트 탭 규칙 — 사람의 누름에도 {s}(UD2)", .{t}) catch "");
    }
}

// ── 서비스 워커 ─────────────────────────────────────────────────────────────────────────────────────────────

fn swReady(r: *Run, b: u64) []const u8 {
    var o: [128]u8 = undefined;
    _ = r.ev(b, "window.swready", &o);
    _ = r.until(Run.loadsAt, b, r.loads[b] + 1, 3000);
    r.pump(400);
    var o2: [64]u8 = undefined;
    const c = r.ev(b, "String(!!navigator.serviceWorker.controller)", &o2);
    return if (std.mem.eql(u8, c, "true")) "controlled" else "not-controlled";
}

fn serviceWorker(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "mksw", &.{env_log});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [700]u8 = undefined;
    var pb: [8][160]u8 = undefined;
    // 규칙을 서비스 워커 설치 **전에** 둔다 — 설치의 `cache.add('/s/cached')` 는 서비스 워커 길이라 가짜가 아니어야 한다(M12).
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    const specs = [_]Spec{
        .{ .id = 1, .pattern = pat(&pb[0], "127.0.0.1", "/s/api*"), .body = "MOCK-SW-API" },
        .{ .id = 2, .pattern = pat(&pb[1], "127.0.0.1", "/s/cached"), .body = "MOCK-CACHED" },
        .{ .id = 3, .pattern = pat(&pb[2], "127.0.0.1", "/s/navdoc*"), .content_type = "text/html; charset=utf-8", .body = "<!doctype html><title>MOCK-NAVDOC</title>m" },
    };
    _ = try r.mock(1, &specs, "", true);
    try r.nav(1, uLoop(&u, "/s/page?1"), false);
    const ctl = swReady(&r, 1);
    {
        const got = r.ev(1, fetchExpr(&x, "/s/api1"), &o);
        r.pump(400);
        const h = r.hitOf(1, 1);
        report(std.mem.eql(u8, ctl, "controlled") and contains(got, "REAL:/s/api1") and h.sw_not_mocked >= 1 and r.page_controlled[1], "mock-sw-path-not-mocked", std.fmt.bufPrint(&d, "{s} · 페이지 {s} · sw_not_mocked {d} · page_controlled {}", .{ ctl, got, h.sw_not_mocked, r.page_controlled[1] }) catch "");
    }
    {
        const got = r.ev(1, "caches.open('c1').then(c=>c.match('/s/cached')).then(r=>r?r.text():'none')", &o);
        report(std.mem.eql(u8, got, "REAL:cached"), "mock-sw-cache-clean", std.fmt.bufPrint(&d, "설치의 cache.add — Cache Storage 에 {s}(가짜가 남지 않는다 — M12)", .{got}) catch "");
    }
    {
        try r.nav(1, uLoop(&u, "/s/navdoc?1"), false);
        r.pump(500);
        const t = r.ev(1, "document.title", &o);
        var o2: [300]u8 = undefined;
        const np = r.ev(1, "caches.open('np').then(c=>c.keys()).then(async ks=>{const out=[];for(const k of ks){const r=await (await caches.open('np')).match(k);out.push((await r.text()).slice(0,40))}return out.join('|')})", &o2);
        report(std.mem.eql(u8, t, "REAL-NAVDOC") and !contains(np, "MOCK"), "mock-sw-preload-not-mocked", std.fmt.bufPrint(&d, "서비스 워커가 다스리는 이동 — {s} · preloadResponse 캐시 {s}(M26)", .{ t, np }) catch "");
    }
    // 엄격 — 탭 2 는 가짜 엄격(서비스 워커를 건너뛰어 탭 길로 와 가짜), 같은 출처의 탭 3 은 그대로(진짜).
    {
        try r.create(2, uLoop(&u, "/s/page?2"));
        try r.watch(2);
        _ = swReady(&r, 2);
        _ = try r.mock(2, &specs, "127.0.0.1", true);
        try r.nav(2, uLoop(&u, "/s/page?2b"), false);
        r.pump(500);
        const got2 = r.ev(2, fetchExpr(&x, "/s/api2"), &o);
        try r.create(3, uLoop(&u, "/s/page?3"));
        _ = swReady(&r, 3);
        var o3: [300]u8 = undefined;
        const got3 = r.ev(3, fetchExpr(&x, "/s/api3"), &o3);
        report(r.strict[2] == .on and contains(got2, "MOCK-SW-API") and contains(got3, "REAL:/s/api3"), "mock-strict", std.fmt.bufPrint(&d, "엄격 {s} · 엄격 탭 {s} · 같은 출처 다른 탭 {s}", .{ @tagName(r.strict[2]), got2, got3 }) catch "");
    }
}

// ── 풀·본문 ─────────────────────────────────────────────────────────────────────────────────────────────────

fn poolAndBodies(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "mkpool", &.{env_log});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [700]u8 = undefined;
    var pb: [4][160]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    // 본문을 보내지 않은 규칙 — 맞은 요청은 붙잡힌다(탭 128). 600 개면 나머지는 -12(진짜로 보내지 않는다 — M17).
    const held = [_]Spec{
        .{ .id = 1, .pattern = pat(&pb[0], "127.0.0.1", "/m/hold*"), .types = mr.typeBits("xhr").?, .body = "HELD-BODY", .body_id = 501 },
        .{ .id = 2, .pattern = pat(&pb[1], "127.0.0.1", "/m/never*"), .types = mr.typeBits("xhr").?, .body = "NEVER-BODY", .body_id = 502 },
    };
    _ = try r.mock(1, &held, "", false);
    {
        _ = r.ev(1, "(window.res=[],window.done=0,(()=>{for(let i=0;i<600;i++)fetch('/m/hold'+i).then(r=>r.text()).then(t=>{window.res.push(t)},e=>{window.res.push('E')}).finally(()=>window.done++)})(),'started')", &o);
        r.pump(2500);
        const busy_mid = r.busy[1];
        // 본문을 늦게 보낸다 — 붙잡은 것들이 이어진다.
        try r.sendBody(1, 501, "HELD-BODY");
        r.pump(2000);
        const tally = r.ev(1, "(async()=>{for(let i=0;i<50&&window.done<600;i++)await new Promise(r=>setTimeout(r,100));const ok=window.res.filter(t=>t==='HELD-BODY').length;const e=window.res.filter(t=>t==='E').length;return ok+' '+e+' '+window.done})()", &o);
        var it = std.mem.splitScalar(u8, tally, ' ');
        const ok_n = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
        const err_n = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
        report(seen("/m/hold") == 0 and ok_n > 0 and ok_n <= mr.max_handlers_tab and ok_n + err_n == 600 and busy_mid >= 600 - mr.max_handlers_tab, "mock-pool-busy", std.fmt.bufPrint(&d, "600 개 — 진짜 {d} · 붙잡았다 이어짐 {d} · -12 {d} · busy {d}", .{ seen("/m/hold"), ok_n, err_n, r.busy[1] }) catch "");
        report(ok_n > 0, "mock-body-hold", std.fmt.bufPrint(&d, "본문이 늦게 와도 붙잡은 요청이 가짜로 이어진다({d})", .{ok_n}) catch "");
    }
    {
        const t0 = os.nowMs();
        const got = r.ev(1, "(async()=>{try{await (await fetch('/m/never1')).text();return 'ok'}catch(e){return 'reject '+e.name}})()", &o);
        const ms = os.nowMs() - t0;
        report(starts(got, "reject TypeError") and ms >= 9000 and ms < 15000 and seen("/m/never") == 0, "mock-body-timeout", std.fmt.bufPrint(&d, "본문이 오지 않음 — {s} {d} ms(10 초 시한 -12) · 서버 {d}", .{ got, ms, seen("/m/never") }) catch "");
    }
    // 창 — 8 탭 × 8 규칙 × 512 KiB = 32 MiB 를 256 KiB 창으로. sidecar 가 산다(관이 닫히지 않는다 — M28).
    {
        const big = try std.heap.c_allocator.alloc(u8, mr.max_body_bytes);
        defer std.heap.c_allocator.free(big);
        @memset(big, 'w');
        var bufs: [64][160]u8 = undefined;
        var total: usize = 0;
        const t0 = os.nowMs();
        for (0..8) |ti| {
            const b: u64 = 4 + ti;
            try r.create(b, uLoop(&u, "/p/sub"));
            try r.watch(b);
            var specs: [8]Spec = undefined;
            for (&specs, 0..) |*s, i| s.* = .{ .id = @intCast(10 + i), .pattern = std.fmt.bufPrint(&bufs[ti * 8 + i], "http://127.0.0.1:{d}/m/w{d}-{d}", .{ port, ti, i }) catch unreachable, .types = mr.typeBits("xhr").?, .body = big, .body_id = @intCast(1000 + ti * 8 + i) };
            _ = try r.mock(b, &specs, "", true);
            total += 8 * big.len;
        }
        r.pump(1000);
        const ms = os.nowMs() - t0;
        const got = r.ev(11, "(async()=>(await (await fetch('/m/w7-7')).text()).length)()", &o);
        report(r.failures == 0 and r.acked_total >= total and std.mem.eql(u8, got, "524288"), "mock-window", std.fmt.bufPrint(&d, "{d} MiB 를 {d} ms 에 · 확인 {d} 바이트 · 마지막 본문 {s} · failure {d}", .{ total >> 20, ms, r.acked_total, got, r.failures }) catch "");
    }
}

// ── 재시작 ────────────────────────────────────────────────────────────────────────────────────────────────

fn restart(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var u: [512]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [512]u8 = undefined;
    var p1: [160]u8 = undefined;
    {
        var host = try spawn(host_path, root, "mkrestart", &.{});
        var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
        try r.create(1, uLoop(&u, "/p/sub"));
        _ = std.c.kill(host.pid, .KILL);
        _ = host.wait(10_000);
    }
    var host = try spawn(host_path, root, "mkrestart", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    // maru 의 차례: browser_created → net_watch → net_mock(규칙·맺음) → navigate(last_url) → 본문(창).
    try r.host.send(.{ .create_browser = .{ .browser = 1, .size = .{ .width = 640, .height = 400, .scale = 1 }, .hidden = false, .url = "about:blank" } });
    _ = r.until(Run.loadsAt, 1, 1, wait_ms);
    try r.watch(1);
    const specs = [_]Spec{.{ .id = 41, .pattern = pat(&p1, "127.0.0.1", "/m/after-restart*"), .content_type = "text/html; charset=utf-8", .body = "<!doctype html><title>MOCK-RESTART</title>m", .body_id = 41 }};
    r.gen = 0;
    _ = try r.mock(1, &specs, "", false);
    try r.host.send(.{ .navigate = .{ .browser = 1, .url = uLoop(&u, "/m/after-restart") } });
    try r.sendBody(1, 41, specs[0].body);
    _ = r.until(Run.loadsAt, 1, 2, wait_ms);
    r.pump(500);
    const t = r.ev(1, "document.title", &o);
    report(seen("/m/after-restart") == 0 and std.mem.eql(u8, t, "MOCK-RESTART"), "mock-restart", std.fmt.bufPrint(&d, "다시 뜬 sidecar 의 재생 이동 — 서버 {d} · {s}(규칙이 이동 앞, 본문은 뒤 — 붙잡았다 이음)", .{ seen("/m/after-restart"), t }) catch "");
}

// ── 비용 ──────────────────────────────────────────────────────────────────────────────────────────────────

fn floodMs(r: *Run) i64 {
    var o: [128]u8 = undefined;
    const got = r.ev(1, "(async()=>{const t=performance.now();for(let b=0;b<30;b++){const ps=[];for(let i=0;i<100;i++)ps.push(fetch('/f?'+b+'_'+i).then(()=>1,()=>0));await Promise.all(ps)}return String(Math.round(performance.now()-t))})()", &o);
    return std.fmt.parseInt(i64, got, 10) catch 999_999;
}

fn cost(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "mkcost", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [256]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    _ = floodMs(&r);
    var base: i64 = std.math.maxInt(i64);
    for (0..3) |_| base = @min(base, floodMs(&r));
    var bufs: [32][128]u8 = undefined;
    var specs: [32]Spec = undefined;
    for (&specs, 0..) |*s, i| s.* = .{ .id = @intCast(100 + i), .pattern = std.fmt.bufPrint(&bufs[i], "http://127.0.0.1:{d}/nomatch-{d:0>2}/*x*y", .{ port, i }) catch unreachable, .types = mr.typeBits("xhr").? };
    _ = try r.mock(1, &specs, "", false);
    var ruled: i64 = std.math.maxInt(i64);
    for (0..3) |_| ruled = @min(ruled, floodMs(&r));
    report(ruled <= base + @divTrunc(base, 10) + 60, "mock-cost", std.fmt.bufPrint(&d, "3000 fetch — 규칙 없음 {d} ms · 맞지 않는 가짜 규칙 32 개 {d} ms", .{ base, ruled }) catch "");
}

// ── main 위로 옮김(2026-11-11) — W9d③ 결정 A(공유 워커는 서비스 워커 길)·엄격의 합·W9d② 본문과의 맞물림 ─────────────────────────────

fn shwExpr(buf: []u8, script: []const u8, target: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "new Promise(res=>{{const w=new SharedWorker('{s}');w.port.onmessage=e=>res(String(e.data));w.onerror=()=>res('worker-error');w.port.postMessage('{s}');setTimeout(()=>res('timeout'),8000)}})", .{ script, target }) catch unreachable;
}

fn portChecks(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "mkport", &.{env_log});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [900]u8 = undefined;
    var pb: [8][160]u8 = undefined;
    // 공유 워커의 fetch — 서비스 워커 길(브라우저가 없는 요청)이라 가짜가 아니다. 종류 없는 규칙과 xhr 규칙 둘 다.
    try r.create(1, uLoop(&u, "/p/sub?shw1"));
    try r.watch(1);
    const specs1 = [_]Spec{
        .{ .id = 1, .pattern = pat(&pb[0], "127.0.0.1", "/m/shw-api*"), .body = "MOCK-SHW-API" },
        .{ .id = 2, .pattern = pat(&pb[1], "127.0.0.1", "/m/shw-x*"), .types = mr.typeBits("xhr").?, .body = "MOCK-SHW-X" },
    };
    const ok1 = try r.mock(1, &specs1, "", true);
    {
        const got = r.ev(1, shwExpr(&x, "/w/shw.js", "/m/shw-api1"), &o);
        r.pump(300);
        var o2: [300]u8 = undefined;
        const got_x = r.ev(1, shwExpr(&x, "/w/shw.js", "/m/shw-x1"), &o2);
        r.pump(300);
        var o3: [300]u8 = undefined;
        const page = r.ev(1, fetchExpr(&x, "/m/shw-api-page"), &o3);
        const h = r.hitOf(1, 1);
        report(ok1 and contains(got, "REAL:/m/shw-api1") and seen("/m/shw-api1") == 1 and contains(got_x, "REAL:/m/shw-x1") and seen("/m/shw-x1") == 1 and h.sw_not_mocked >= 1 and contains(page, "MOCK-SHW-API"), "mock-shw-fetch-not-mocked", std.fmt.bufPrint(&d, "공유 워커 fetch {s} · xhr 규칙 {s} · 서버 {d}/{d} · 규칙 1 sw_not_mocked {d} · 같은 탭 페이지 fetch {s}(대조)", .{ got, got_x, seen("/m/shw-api1"), seen("/m/shw-x1"), h.sw_not_mocked, page }) catch "");
    }
    // 가짜 엄격 — 같은 탭의 페이지 요청은 가짜(대조)지만 공유 워커의 요청은 엄격이어도 서비스 워커 길(막기와 같다 — 결정 A).
    {
        try r.create(2, uLoop(&u, "/p/sub?shw2"));
        try r.watch(2);
        const ok2 = try r.mock(2, &specs1, "127.0.0.1", true);
        try r.nav(2, uLoop(&u, "/p/sub?shw2b"), false);
        const got = r.ev(2, shwExpr(&x, "/w/shw.js?2", "/m/shw-api2"), &o);
        r.pump(300);
        var o2: [300]u8 = undefined;
        const page = r.ev(2, fetchExpr(&x, "/m/shw-api-page2"), &o2);
        report(ok2 and r.strict[2] == .on and contains(got, "REAL:/m/shw-api2") and seen("/m/shw-api2") == 1 and contains(page, "MOCK-SHW-API"), "mock-shw-strict-not-mocked", std.fmt.bufPrint(&d, "엄격 {s} · 공유 워커 fetch {s}(서버 {d}) · 페이지 fetch {s}", .{ @tagName(r.strict[2]), got, seen("/m/shw-api2"), page }) catch "");
    }
    // 공유 워커 주 스크립트(사용자 결정 A 2026-11-11 — 가짜 금지): 종류 `shared_worker` 규칙은 codec 이 거절하고(maru 의 `types_invalid` 와 같은 표),
    // 종류 없는 규칙이 그 주소에 맞아도 워커는 진짜 스크립트를 받는다(서버가 받는다·그 규칙의 `sw_not_mocked` +1). 같은 탭·같은 규칙·같은 주소의
    // 페이지 fetch 는 그때도 가짜(대조). 규칙 없는 같은 출처 탭이 같은 워커에 붙어도·만든 탭을 닫은 뒤의 새 연결도 진짜.
    {
        var buf: [protocol.wire.max_frame_bytes]u8 = undefined;
        const xhr_bit = mr.typeBits("xhr").?;
        const kind = protocol.codec.encode(.{ .net_mock_rule = .{ .browser = 1, .generation = 99, .id = 1, .types = mr.shared_worker_types, .site = "127.0.0.1", .pattern = "https://a.test/", .content_type = "text/plain" } }, &buf);
        const mixed = protocol.codec.encode(.{ .net_mock_rule = .{ .browser = 1, .generation = 99, .id = 1, .types = mr.shared_worker_types | xhr_bit, .site = "127.0.0.1", .pattern = "https://a.test/", .content_type = "text/plain" } }, &buf);
        const plain = protocol.codec.encode(.{ .net_mock_rule = .{ .browser = 1, .generation = 99, .id = 1, .types = xhr_bit, .site = "127.0.0.1", .pattern = "https://a.test/", .content_type = "text/plain" } }, &buf);
        const by_name = mr.typeBits("shared_worker") == null and mr.typeBits("worker") != null;
        report(by_name and std.meta.isError(kind) and std.meta.isError(mixed) and !std.meta.isError(plain), "mock-shw-kind-refused", std.fmt.bufPrint(&d, "이름 shared_worker 거절 {} · 종류 비트 10 거절 {} · 10+xhr 거절 {} · xhr 만 받음 {}", .{ by_name, std.meta.isError(kind), std.meta.isError(mixed), !std.meta.isError(plain) }) catch "");
    }
    {
        try r.create(3, uLoop(&u, "/p/sub?shw3"));
        try r.watch(3);
        const specs3 = [_]Spec{.{ .id = 1, .pattern = pat(&pb[2], "127.0.0.1", "/w/shwm.js"), .content_type = "text/javascript", .body = "onconnect=e=>e.ports[0].postMessage('MOCK-SHW-SCRIPT')" }};
        const ok3 = try r.mock(3, &specs3, "", true);
        const before = seen("/w/shwm.js");
        const got3 = r.ev(3, shwExpr(&x, "/w/shwm.js", "-"), &o);
        r.pump(200);
        const after_worker = seen("/w/shwm.js");
        var o3: [300]u8 = undefined;
        const page3 = r.ev(3, fetchExpr(&x, "/w/shwm.js"), &o3);
        r.pump(300);
        const h3 = r.hitOf(3, 1);
        report(ok3 and std.mem.eql(u8, got3, "REAL-SHW-SCRIPT") and after_worker == before + 1 and h3.sw_not_mocked >= 1 and contains(page3, "MOCK-SHW-SCRIPT") and seen("/w/shwm.js") == after_worker and h3.hits >= 1, "mock-shw-script-real", std.fmt.bufPrint(&d, "만든 탭의 워커 {s} · 서버 {d}→{d} · 규칙 1 sw_not_mocked {d} · 같은 탭 같은 주소의 페이지 fetch {s}(대조 — 서버 {d}, hits {d})", .{ got3, before, after_worker, h3.sw_not_mocked, page3, seen("/w/shwm.js"), h3.hits }) catch "");
        try r.create(4, uLoop(&u, "/p/sub?shw4"));
        var o4: [300]u8 = undefined;
        const got4 = r.ev(4, shwExpr(&x, "/w/shwm.js", "-"), &o4);
        r.pump(200);
        report(std.mem.eql(u8, got4, "REAL-SHW-SCRIPT"), "mock-shw-script-cross-tab", std.fmt.bufPrint(&d, "규칙 없는 같은 출처 탭이 같은 공유 워커에 붙음 — {s} · 서버 /w/shwm.js {d}", .{ got4, seen("/w/shwm.js") }) catch "");
        // 만든 탭을 닫은 뒤(워커는 탭 4 로 산다) 새 연결.
        try r.host.send(.{ .destroy_browser = 3 });
        r.pump(500);
        var o5: [300]u8 = undefined;
        const got5 = r.ev(4, shwExpr(&x, "/w/shwm.js", "-"), &o5);
        report(std.mem.eql(u8, got5, "REAL-SHW-SCRIPT"), "mock-shw-script-after-close", std.fmt.bufPrint(&d, "만든 탭을 닫은 뒤 탭 4 의 새 연결 — {s} · 서버 /w/shwm.js {d}", .{ got5, seen("/w/shwm.js") }) catch "");
    }
    // 엄격의 합 — 막기 엄격만 켜도 도메인은 하나라 서비스 워커를 건너뛰고 가짜가 탭 길에서 듣는다. 상태는 각자의 엄격 사이트가 있을 때만.
    {
        try r.create(5, uLoop(&u, "/s/page?u5"));
        try r.watch(5);
        _ = swReady(&r, 5);
        const specs5 = [_]Spec{.{ .id = 1, .pattern = pat(&pb[3], "127.0.0.1", "/s/api*"), .body = "MOCK-SW-API" }};
        _ = try r.mock(5, &specs5, "", true);
        var o0: [300]u8 = undefined;
        const before = r.ev(5, fetchExpr(&x, "/s/api-u0"), &o0);
        try r.host.send(.{ .net_block = .{ .browser = 5, .generation = 1, .strict_site = "127.0.0.1" } });
        const on = r.until(Run.blockStrictAt, 5, 1, wait_ms);
        try r.nav(5, uLoop(&u, "/s/page?u5b"), false);
        r.pump(300);
        const got = r.ev(5, fetchExpr(&x, "/s/api-u1"), &o);
        const mock_strict = r.strict[5];
        try r.host.send(.{ .net_block = .{ .browser = 5, .generation = 2 } });
        r.pump(300);
        try r.nav(5, uLoop(&u, "/s/page?u5c"), false);
        _ = swReady(&r, 5);
        var o2: [300]u8 = undefined;
        const after = r.ev(5, fetchExpr(&x, "/s/api-u2"), &o2);
        report(contains(before, "REAL:/s/api-u0") and on and r.block_strict[5] == .off and contains(got, "MOCK-SW-API") and mock_strict == .off and contains(after, "REAL:/s/api-u2"), "mock-block-strict-union", std.fmt.bufPrint(&d, "엄격 전 {s} · 막기 엄격 on {} → 페이지 {s}(가짜 상태의 엄격 {s}) · 막기 엄격 끈 뒤 {s}(막기 상태 {s})", .{ before, on, got, @tagName(mock_strict), after, @tagName(r.block_strict[5]) }) catch "");
    }
    // W9d② 본문 × 가짜 — 기록 중 같은 주소를 가짜(<script>, script 규칙)와 진짜(fetch)로 함께 받는다. 가짜 기록은 본문을 받으러 가지 않고(`flags2.mocked`),
    // 진짜 기록에는 가짜 본문이 붙지 않는다(틀린 본문 0 — 짝을 못 지으면 본문 없음은 괜찮다).
    {
        try r.create(6, uLoop(&u, "/p/sub?rb"));
        try r.watch(6);
        try r.host.send(.{ .net_record = .{ .browser = 6, .on = true, .session = 1 } });
        r.pump(300);
        const specs6 = [_]Spec{.{ .id = 1, .pattern = pat(&pb[4], "127.0.0.1", "/m/rb*"), .types = mr.typeBits("script").?, .content_type = "text/javascript", .body = "window.__rb=(window.__rb||0)+1//MOCK-RB" }};
        _ = try r.mock(6, &specs6, "", true);
        var o6: [2000]u8 = undefined;
        const got = r.ev(6, "(async()=>{const out=[];for(let i=0;i<20;i++){const u='/m/rb'+i;const sc=new Promise(res=>{const e=document.createElement('script');e.onload=e.onerror=()=>res(1);e.src=u;document.head.appendChild(e)});const f=fetch(u).then(r=>r.text());const [t]=await Promise.all([f,sc]);out.push(t)}return out.join(',')+' rb='+window.__rb})()", &o6);
        r.pump(1500);
        // 대조 — 가짜와 겹치지 않는 진짜(fetch 만, 다른 주소)는 제 본문을 받는다(이 판정이 본문을 정말 받는지).
        var oc: [200]u8 = undefined;
        _ = r.ev(6, "(async()=>{for(let i=0;i<5;i++){await (await fetch('/m/rbc'+i)).text();await new Promise(res=>setTimeout(res,150))}return 'ok'})()", &oc);
        r.pump(3000);
        var control: usize = 0;
        var cstates: [400]u8 = undefined;
        var cstates_len: usize = 0;
        var mocked_begins: usize = 0;
        var real_begins: usize = 0;
        var real_captured: usize = 0;
        var wrong: usize = 0;
        var mocked_with_body: usize = 0;
        var sample: [128]u8 = undefined;
        var sample_len: usize = 0;
        for (r.reqs.items) |e| {
            if (e.browser != 6) continue;
            const url = e.url[0..e.url_len];
            const at = std.mem.indexOf(u8, url, "/m/rb") orelse continue;
            const body = r.bodies.get(e.request);
            if (std.mem.startsWith(u8, url[at..], "/m/rbc")) {
                var want: [64]u8 = undefined;
                const w = std.fmt.bufPrint(&want, "REAL:{s}", .{url[at..]}) catch "";
                if (body) |b| if (std.mem.eql(u8, b.data.items, w)) {
                    control += 1;
                };
                if (cstates_len + 24 < cstates.len) {
                    const st: []const u8 = if (body) |b| (if (b.state) |bs| @tagName(bs) else "nostate") else "nobody";
                    const add = std.fmt.bufPrint(cstates[cstates_len..], "{s}/ended={}/expected ", .{ st, e.ended }) catch "";
                    cstates_len += add.len;
                }
                continue;
            }
            if (e.begin_mocked or e.flags.mocked) {
                mocked_begins += 1;
                if (body) |b| if (b.data.items.len > 0) {
                    mocked_with_body += 1;
                };
                continue;
            }
            real_begins += 1;
            if (body) |b| if (b.data.items.len > 0) {
                var want: [64]u8 = undefined;
                const w = std.fmt.bufPrint(&want, "REAL:{s}", .{url[at..]}) catch "";
                if (std.mem.eql(u8, b.data.items, w)) real_captured += 1 else {
                    if (wrong == 0) {
                        const sm: []const u8 = std.fmt.bufPrint(&sample, "{s} <- {s}", .{ url[at..], b.data.items[0..@min(b.data.items.len, 40)] }) catch "";
                        sample_len = sm.len;
                    }
                    wrong += 1;
                }
            };
        }
        const all_mock = std.mem.count(u8, got, "REAL:/m/rb") == 20 and std.mem.endsWith(u8, got, " rb=20");
        report(all_mock and mocked_begins >= 20 and real_begins >= 20 and wrong == 0 and mocked_with_body == 0 and control >= 4, "mock-record-body-mixed", std.fmt.bufPrint(&d, "페이지 script 가짜·fetch 진짜 {} · 가짜 기록 {d}(본문 붙음 {d}) · 진짜 기록 {d} — 제 본문 {d} · 틀린 본문 {d}({s}) · 대조(겹치지 않는 진짜 fetch) 제 본문 {d}/5 [{s}]", .{ all_mock, mocked_begins, mocked_with_body, real_begins, real_captured, wrong, sample[0..sample_len], control, cstates[0..cstates_len] }) catch "");
    }
}

// ── 검증 SEVERE 넷 고침(`mkfix4` — 2026-11-11, v1·v2 적대 검증) ─────────────────────────────────────────────────────
// mock-xframe-*(v1 SEVERE-1 — 사용자 결정 「허락 밖 iframe 요청은 모두 진짜」): 맨 위 127.0.0.1(사이트 grant 127.0.0.1 — 실행 사이트도) 아래 다른 사이트
//   iframe(localhost)이 부른 스크립트·grant 사이트 주소의 스크립트·이미지·fetch·전용 워커는 모두 진짜이고 서버가 받으며 규칙의 frame_not_mocked 로
//   센다, 그 iframe 은 localhost 쿠키를 읽지 못한다(검증자의 쿠키 읽기 재현); 같은 사이트 iframe 의 같은 다섯은 가짜(대조).
// mock-d2-*·block-d2-*(v1 SEVERE-2 — 사용자 결정 「고침」): 사용자가 친 주소·새로 고침(떠나기 처리기가 도는 옛 문서 포함) 바로 뒤의 에이전트
//   `Runtime.evaluate` 는 그 이동을 가짜·막힘으로 만들지 않는다, 친 주소와 같은 주소로 겹친 에이전트 이동도 진짜(fail-safe), 대조로 에이전트만의 이동·
//   새 문서가 선 뒤의 에이전트 이동은 그대로 가짜·막힘.
// mock-churn-no-traffic(v2 SEVERE-1 R11): 요청 없이 512 KiB 본문 규칙을 160 번 바꿔도 맺음이 모두 되고 페이지는 마지막 본문을 받으며 host 의
//   footprint 가 자라지 않는다(은퇴 묶음을 바꿀 때 곧 거둔다).

const RusageV2 = extern struct { uuid: [16]u8, f: [20]u64 };
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *RusageV2) c_int;

/// host(브라우저 프로세스)의 phys_footprint(KiB — `rusage_info_v2.ri_phys_footprint`).
fn footKiB(pid: c_int) u64 {
    var ru: RusageV2 = undefined;
    if (proc_pid_rusage(pid, 2, &ru) != 0) return 0;
    return ru.f[7] >> 10;
}

fn fix4Route(conn: c_int, path: []const u8, target: []const u8, bb: *[4096]u8) bool {
    const p = port;
    if (std.mem.eql(u8, path, "/x4/top")) {
        const body = std.fmt.bufPrint(bb, "<!doctype html><title>x4top</title><script>window.msgs=[];addEventListener('message',e=>window.msgs.push(String(e.data)))</script><iframe src='http://localhost:{d}/x4/frame?t=xs'></iframe><iframe src='/x4/frame?t=same'></iframe>", .{p}) catch return false;
        reply(conn, "200 OK", html, "", body);
        return true;
    }
    if (std.mem.eql(u8, path, "/x4/frame")) {
        const tag: []const u8 = if (std.mem.endsWith(u8, target, "t=xs")) "xs" else "same";
        const body = std.fmt.bufPrint(bb, "<!doctype html><title>x4frame</title><script src=/x4/s.js></script><script src='http://127.0.0.1:{d}/x4/own.js'></script><script>const T='{s}';const post=(k,v)=>parent.postMessage(T+':'+k+':'+v,'*');post('s',window.XS||'none');post('own',window.OWN||'none');const i=new Image();i.onload=()=>post('img',i.naturalWidth);i.onerror=()=>post('img','err');i.src='/x4/i.svg';fetch('/x4/f',{{credentials:'include'}}).then(r=>r.text()).then(t=>post('f',t),e=>post('f','reject '+e.name));try{{const w=new Worker('/x4/w.js');w.onmessage=e=>post('w',e.data);w.onerror=()=>post('w','error')}}catch(x){{post('w','throw '+x.name)}}</script>", .{ p, tag }) catch return false;
        reply(conn, "200 OK", html, "", body);
        return true;
    }
    if (std.mem.eql(u8, path, "/x4/s.js")) {
        reply(conn, "200 OK", "text/javascript", "", "window.XS='REAL-S'");
        return true;
    }
    if (std.mem.eql(u8, path, "/x4/own.js")) {
        reply(conn, "200 OK", "text/javascript", "", "window.OWN='REAL-OWN'");
        return true;
    }
    if (std.mem.eql(u8, path, "/x4/i.svg")) {
        reply(conn, "200 OK", "image/svg+xml", "", "<svg xmlns='http://www.w3.org/2000/svg' width='3' height='3'/>");
        return true;
    }
    if (std.mem.eql(u8, path, "/x4/f")) {
        reply(conn, "200 OK", "text/plain", "", "REAL-F");
        return true;
    }
    if (std.mem.eql(u8, path, "/x4/w.js")) {
        reply(conn, "200 OK", "text/javascript", "", "postMessage('REAL-W')");
        return true;
    }
    if (std.mem.eql(u8, path, "/x4/bu")) {
        reply(conn, "200 OK", html, "", "<!doctype html><title>bu</title><script>addEventListener('beforeunload',()=>{const t=Date.now();while(Date.now()-t<400){}})</script>bu");
        return true;
    }
    return false;
}

fn fix4Checks(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try fix4Frames(report, host_path, root);
    try fix4D2(report, host_path, root);
    try fix4Churn(report, host_path, root);
}

fn fix4Frames(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "mkfix4f", &.{env_log});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var o: [2000]u8 = undefined;
    var d: [2600]u8 = undefined;
    var pb: [10][160]u8 = undefined;
    // 검증자 재현의 쿠키 — localhost 에 SameSite=None 쿠키(그 iframe 이 가짜로 읽으면 안 된다).
    try r.create(2, uLocal(&u, "/p/sub?ck4"));
    var oc: [300]u8 = undefined;
    _ = r.ev(2, "document.cookie='lhnone=secret1; SameSite=None; Secure; Path=/';document.cookie", &oc);
    try r.create(1, uLoop(&u, "/p/sub?x4"));
    try r.watch(1);
    const js = "text/javascript";
    const svg = "<svg xmlns='http://www.w3.org/2000/svg' width='7' height='7'/>";
    const steal_s = "window.XS='MOCK-S ran-as '+location.origin+' cookie=['+document.cookie+']'";
    const steal_w = "fetch('/c/echo',{credentials:'include'}).then(r=>r.text()).then(t=>postMessage('MOCK-W '+t))";
    // 사용자 탭의 규칙 꼴(사이트·실행 사이트 = grant 호스트 127.0.0.1). 11–14 는 다른 사이트(localhost) 주소, 21–25 는 grant 사이트 주소.
    const specs = [_]Spec{
        .{ .id = 11, .pattern = pat(&pb[0], "localhost", "/x4/s.js"), .exec_site = "127.0.0.1", .human = true, .types = mr.typeBits("script").?, .content_type = js, .body = steal_s },
        .{ .id = 12, .pattern = pat(&pb[1], "localhost", "/x4/i.svg"), .exec_site = "127.0.0.1", .human = true, .types = mr.typeBits("image").?, .content_type = "image/svg+xml", .body = svg },
        .{ .id = 13, .pattern = pat(&pb[2], "localhost", "/x4/f"), .exec_site = "127.0.0.1", .human = true, .types = mr.typeBits("xhr").?, .body = "MOCK-F" },
        .{ .id = 14, .pattern = pat(&pb[3], "localhost", "/x4/w.js"), .exec_site = "127.0.0.1", .human = true, .types = mr.typeBits("worker").?, .content_type = js, .body = steal_w },
        .{ .id = 21, .pattern = pat(&pb[4], "127.0.0.1", "/x4/s.js"), .exec_site = "127.0.0.1", .human = true, .types = mr.typeBits("script").?, .content_type = js, .body = steal_s },
        .{ .id = 22, .pattern = pat(&pb[5], "127.0.0.1", "/x4/own.js"), .exec_site = "127.0.0.1", .human = true, .types = mr.typeBits("script").?, .content_type = js, .body = "window.OWN='MOCK-OWN cookie=['+document.cookie+']'" },
        .{ .id = 23, .pattern = pat(&pb[6], "127.0.0.1", "/x4/i.svg"), .exec_site = "127.0.0.1", .human = true, .types = mr.typeBits("image").?, .content_type = "image/svg+xml", .body = svg },
        .{ .id = 24, .pattern = pat(&pb[7], "127.0.0.1", "/x4/f"), .exec_site = "127.0.0.1", .human = true, .types = mr.typeBits("xhr").?, .body = "MOCK-F" },
        .{ .id = 25, .pattern = pat(&pb[8], "127.0.0.1", "/x4/w.js"), .exec_site = "127.0.0.1", .human = true, .types = mr.typeBits("worker").?, .content_type = js, .body = steal_w },
    };
    const ok = try r.mock(1, &specs, "", true);
    try r.nav(1, uLoop(&u, "/x4/top"), false);
    var msgs: []const u8 = "";
    const deadline = os.nowMs() + 8000;
    while (os.nowMs() < deadline) {
        r.pump(300);
        msgs = r.ev(1, "JSON.stringify(window.msgs)", &o);
        if (std.mem.count(u8, msgs, "\",\"") >= 9) break; // 열 개
    }
    r.pump(300);
    const xs_real = contains(msgs, "xs:s:REAL-S") and contains(msgs, "xs:own:REAL-OWN") and contains(msgs, "xs:img:3") and contains(msgs, "xs:f:REAL-F") and contains(msgs, "xs:w:REAL-W");
    const srv_xs = seen("/x4/s.js host=localhost") == 1 and seen("/x4/own.js host=127.0.0.1") == 1 and seen("/x4/i.svg host=localhost") == 1 and seen("/x4/f host=localhost") == 1 and seen("/x4/w.js host=localhost") == 1;
    var frame_nm: u64 = 0;
    var xs_hits: u64 = 0;
    for ([_]u32{ 11, 12, 13, 14 }) |id| {
        const h = r.hitOf(1, id);
        frame_nm += h.frame_not_mocked;
        xs_hits += h.hits;
    }
    const own = r.hitOf(1, 22);
    report(ok and contains(msgs, "xs:s:REAL-S") and seen("/x4/s.js host=localhost") == 1, "mock-xframe-script-real", std.fmt.bufPrint(&d, "다른 사이트 iframe 의 스크립트 — {s}", .{msgs}) catch "");
    report(contains(msgs, "xs:own:REAL-OWN") and seen("/x4/own.js host=127.0.0.1") == 1 and own.frame_not_mocked == 1, "mock-xframe-own-site-url-real", std.fmt.bufPrint(&d, "그 iframe 이 부른 grant 사이트 주소의 스크립트도 진짜 · 서버 {d} · 규칙 22 frame_not_mocked {d} hits {d}(같은 사이트 iframe 몫)", .{ seen("/x4/own.js host=127.0.0.1"), own.frame_not_mocked, own.hits }) catch "");
    report(contains(msgs, "xs:img:3") and contains(msgs, "xs:f:REAL-F") and contains(msgs, "xs:w:REAL-W"), "mock-xframe-image-fetch-worker-real", "이미지 3×3·fetch REAL-F·전용 워커 REAL-W");
    report(xs_real and srv_xs and xs_hits == 0 and frame_nm == 4, "mock-xframe-counted", std.fmt.bufPrint(&d, "다른 사이트 주소 규칙 넷 — 맞음 {d} · frame_not_mocked {d}(바람 4) · 서버가 다섯을 받음 {}", .{ xs_hits, frame_nm, srv_xs }) catch "");
    report(!contains(msgs, "secret1") and !contains(msgs, "MOCK-S ran-as http://localhost") and !contains(msgs, "xs:w:MOCK"), "mock-xframe-cookie-unread", std.fmt.bufPrint(&d, "그 iframe 은 가짜로 localhost 쿠키(lhnone=secret1)를 읽지 못한다 — {s}", .{msgs}) catch "");
    const same_mocked = contains(msgs, "same:s:MOCK-S ran-as http://127.0.0.1") and contains(msgs, "same:own:MOCK-OWN") and contains(msgs, "same:img:7") and contains(msgs, "same:f:MOCK-F") and contains(msgs, "same:w:MOCK-W");
    report(same_mocked and seen("/x4/s.js host=127.0.0.1") == 0 and seen("/x4/f host=127.0.0.1") == 0, "mock-sameframe-mocked", std.fmt.bufPrint(&d, "대조: 같은 사이트 iframe 의 다섯은 가짜 · 서버 s.js {d} f {d}", .{ seen("/x4/s.js host=127.0.0.1"), seen("/x4/f host=127.0.0.1") }) catch "");
}

/// 주 문서가 진짜(`REAL`)인가 가짜(`MOCK-D2`)인가 — 막힌 문서는 둘 다 아니다.
fn d2Doc(r: *Run, b: u64, out: []u8) []const u8 {
    return r.ev(b, "document.title+'|'+(document.body?document.body.innerText.slice(0,40):'')", out);
}

/// 사용자가 친 주소(`navigate{user}`) + 곧(또는 `delay_ms` 뒤) 에이전트의 `Runtime.evaluate`(읽기 목록 밖) — 그 이동이 선 뒤의 문서.
fn typedThenEval(r: *Run, b: u64, url: []const u8, delay_ms: u32, eval: []const u8, out: []u8) ![]const u8 {
    const before = r.loads[b];
    try r.host.send(.{ .navigate = .{ .browser = b, .url = url, .user = true } });
    if (delay_ms > 0) r.pump(delay_ms);
    var pb: [600]u8 = undefined;
    _ = r.call(b, "Runtime.evaluate", std.fmt.bufPrint(&pb, "{{\"expression\":\"{s}\"}}", .{eval}) catch "{}", 3000) catch null;
    _ = r.until(Run.loadsAt, b, before + 1, wait_ms);
    r.pump(300);
    return d2Doc(r, b, out);
}

fn fix4D2(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "mkfix4d", &.{env_log});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var ub: [512]u8 = undefined;
    var o: [400]u8 = undefined;
    var d: [1200]u8 = undefined;
    var pb: [160]u8 = undefined;
    var qb: [96]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub?d2"));
    try r.watch(1);
    const specs = [_]Spec{.{ .id = 1, .pattern = pat(&pb, "127.0.0.1", "/m/x4d2*"), .exec_site = "127.0.0.1", .human = true, .content_type = html, .body = "<!doctype html><title>MOCK-D2</title>m" }};
    const ok = try r.mock(1, &specs, "", true);
    // 친 주소 + 곧 에이전트 eval — 셋 다 진짜(전에는 0/5).
    var real: u32 = 0;
    for (0..3) |i| {
        try r.nav(1, uLoop(&u, "/p/sub?d2b"), false);
        if (contains(try typedThenEval(&r, 1, uLoop(&u, std.fmt.bufPrint(&qb, "/m/x4d2doc?b{d}", .{i}) catch ""), 0, "1", &o), "REAL|")) real += 1;
    }
    report(ok and real == 3, "mock-d2-typed+agent-eval", std.fmt.bufPrint(&d, "진짜 {d}/3", .{real}) catch "");
    // 떠나기 처리기(400 ms)가 도는 옛 문서 — 친 주소 + 100 ms 뒤 eval.
    real = 0;
    for (0..2) |i| {
        try r.nav(1, uLoop(&u, "/x4/bu"), false);
        if (contains(try typedThenEval(&r, 1, uLoop(&u, std.fmt.bufPrint(&qb, "/m/x4d2doc?c{d}", .{i}) catch ""), 100, "1", &o), "REAL|")) real += 1;
    }
    report(real == 2, "mock-d2-typed+beforeunload+agent-eval", std.fmt.bufPrint(&d, "진짜 {d}/2", .{real}) catch "");
    // 사용자 새로 고침 + 곧 eval.
    real = 0;
    try r.nav(1, uLoop(&u, "/m/x4d2doc?r"), true);
    for (0..3) |_| {
        const before = r.loads[1];
        try r.host.send(.{ .nav_action = .{ .browser = 1, .action = .reload, .user = true } });
        _ = r.call(1, "Runtime.evaluate", "{\"expression\":\"1\"}", 3000) catch null;
        _ = r.until(Run.loadsAt, 1, before + 1, wait_ms);
        r.pump(300);
        if (contains(d2Doc(&r, 1, &o), "REAL|")) real += 1;
    }
    report(real == 3, "mock-d2-reload+agent-eval", std.fmt.bufPrint(&d, "진짜 {d}/3", .{real}) catch "");
    // 친 주소와 같은 주소로 곧 에이전트가 몬다 — (1) wire navigate(브라우저가 시작한 이동이라 사용자 이동을 대신한다): 그 사이 문서도 진짜(fail-safe
    // 결정); (2) 옛 문서의 eval `location.href`(페이지 스크립트의 이동 — Chromium 은 사용자가 시작한 이동을 끊지 못하게 그 문서가 선 뒤로 미룬다, 실측):
    // 사용자의 문서는 진짜로 서고(서버가 받고 가짜 표시 없음), 그 뒤 에이전트의 이동은 에이전트의 것(규칙대로 — 관찰).
    {
        try r.nav(1, uLoop(&u, "/p/sub?d2f"), false);
        const before = r.loads[1];
        const target2 = uLoop(&ub, "/m/x4d2slowdoc?f");
        try r.host.send(.{ .navigate = .{ .browser = 1, .url = target2, .user = true } });
        try r.host.send(.{ .navigate = .{ .browser = 1, .url = target2, .user = false } });
        _ = r.until(Run.loadsAt, 1, before + 1, wait_ms);
        r.pump(400);
        var o5: [200]u8 = undefined;
        const v2 = d2Doc(&r, 1, &o5);
        report(contains(v2, "REAL|"), "mock-d2-same-url-agent-nav-real", std.fmt.bufPrint(&d, "친 주소 바로 뒤 같은 주소의 wire navigate(에이전트) — {s}", .{v2}) catch "");
        try r.nav(1, uLoop(&u, "/p/sub?d2e"), false);
        const target = uLoop(&ub, "/m/x4d2slowdoc?e"); // 느린 진짜(800 ms) — eval 이 옛 문서에서 돈다
        var eb: [300]u8 = undefined;
        const srv_e = seen("/m/x4d2slowdoc?e");
        _ = try typedThenEval(&r, 1, target, 0, std.fmt.bufPrint(&eb, "location.href='{s}';location.pathname", .{target}) catch "1", &o);
        r.pump(1500);
        const v1b = d2Doc(&r, 1, &o);
        // 사용자의 그 요청 — 끝났고 가짜가 아니다.
        var user_real: u32 = 0;
        var agent_mocked: u32 = 0;
        for (r.reqs.items) |e| if (e.browser == 1 and e.ended and contains(e.url[0..e.url_len], "/m/x4d2slowdoc?e")) {
            if (e.flags.mocked) agent_mocked += 1 else if (e.error_code == 0) user_real += 1;
        };
        report(seen("/m/x4d2slowdoc?e") - srv_e == 1 and user_real == 1, "mock-d2-typed+agent-eval-same-url-user-real", std.fmt.bufPrint(&d, "사용자 이동은 진짜로 섰다(서버 {d} · 진짜 끝 {d}) · 그 뒤 eval 의 같은 주소 이동(관찰): 가짜 끝 {d}, 지금 {s}", .{ seen("/m/x4d2slowdoc?e") - srv_e, user_real, agent_mocked, v1b }) catch "");
    }
    // 대조: 에이전트만의 이동·새 문서가 선 뒤의 에이전트 이동은 그대로 가짜.
    {
        try r.nav(1, uLoop(&u, "/m/x4d2doc?g"), false);
        const agent_only = contains(d2Doc(&r, 1, &o), "MOCK-D2");
        try r.nav(1, uLoop(&u, "/m/x4d2doc?h"), true);
        _ = r.call(1, "Runtime.evaluate", "{\"expression\":\"1\"}", 3000) catch null;
        r.pump(200);
        try r.nav(1, uLoop(&u, "/m/x4d2doc?h"), false); // 같은 주소지만 사용자 문서가 선 뒤 — 다툼의 창은 끝났다
        const after_settle = contains(d2Doc(&r, 1, &o), "MOCK-D2");
        var eo: [200]u8 = undefined;
        _ = r.ev(1, "location.href='/m/x4d2doc?i';'ok'", &eo);
        _ = r.until(Run.loadsAt, 1, r.loads[1] + 1, wait_ms);
        r.pump(300);
        const eval_nav = contains(d2Doc(&r, 1, &o), "MOCK-D2");
        report(agent_only and after_settle and eval_nav, "mock-d2-agent-nav-still-mocked", std.fmt.bufPrint(&d, "대조: 에이전트 이동 {} · 사용자 문서가 선 뒤 같은 주소 {} · 토큰 없을 때 eval 의 location {}", .{ agent_only, after_settle, eval_nav }) catch "");
    }
    // 막기(W9d③ 의 같은 경주 — 같은 표): 가짜 규칙을 지우고 막기 규칙.
    {
        try r.host.send(.{ .net_mock_commit = .{ .browser = 1, .generation = r.gen + 1, .count = 0 } });
        r.gen += 1;
        _ = r.until(Run.stateAt, 1, r.gen, wait_ms);
        var bp: [160]u8 = undefined;
        var v: msg.NetBlock = .{ .browser = 1, .generation = 1, .count = 1 };
        v.rules[0] = .{ .id = 91, .site = "127.0.0.1", .pattern = pat(&bp, "127.0.0.1", "/m/x4b*") };
        try r.host.send(.{ .net_block = v });
        r.pump(300);
        var breal: u32 = 0;
        for (0..3) |i| {
            try r.nav(1, uLoop(&u, "/p/sub?bb"), false);
            if (contains(try typedThenEval(&r, 1, uLoop(&u, std.fmt.bufPrint(&qb, "/m/x4bdoc?{d}", .{i}) catch ""), 0, "1", &o), "REAL|")) breal += 1;
        }
        try r.nav(1, uLoop(&u, "/x4/bu"), false);
        if (contains(try typedThenEval(&r, 1, uLoop(&u, "/m/x4bdoc?bu"), 100, "1", &o), "REAL|")) breal += 1;
        try r.nav(1, uLoop(&u, "/m/x4bdoc?r"), true);
        const typed_ok = contains(d2Doc(&r, 1, &o), "REAL|");
        var rreal: u32 = 0;
        for (0..2) |_| {
            const before = r.loads[1];
            try r.host.send(.{ .nav_action = .{ .browser = 1, .action = .reload, .user = true } });
            _ = r.call(1, "Runtime.evaluate", "{\"expression\":\"1\"}", 3000) catch null;
            _ = r.until(Run.loadsAt, 1, before + 1, wait_ms);
            r.pump(300);
            if (contains(d2Doc(&r, 1, &o), "REAL|")) rreal += 1;
        }
        report(breal == 4 and typed_ok and rreal == 2, "block-d2-typed-reload+agent-eval", std.fmt.bufPrint(&d, "막기 규칙 — 친 주소 + eval 진짜 {d}/4(떠나기 처리기 하나 포함) · 새로 고침 + eval 진짜 {d}/2", .{ breal, rreal }) catch "");
        const before_srv = seen("/m/x4bdoc?agent");
        try r.nav(1, uLoop(&u, "/m/x4bdoc?agent"), false);
        const agent_view = d2Doc(&r, 1, &o);
        report(!contains(agent_view, "REAL|") and seen("/m/x4bdoc?agent") == before_srv, "block-d2-agent-nav-still-blocked", std.fmt.bufPrint(&d, "대조: 에이전트 이동은 막힌다 — {s} · 서버 {d}", .{ agent_view, seen("/m/x4bdoc?agent") - before_srv }) catch "");
        try r.host.send(.{ .net_block = .{ .browser = 1, .generation = 2 } });
        r.pump(200);
    }
}

fn fix4Churn(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "mkfix4c", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var o: [300]u8 = undefined;
    var d: [900]u8 = undefined;
    var pb: [160]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub?churn"));
    try r.watch(1);
    const big = try std.heap.c_allocator.alloc(u8, mr.max_body_bytes);
    defer std.heap.c_allocator.free(big);
    // 처음 한 번(본문 하나가 산 상태)을 기준으로 잰다.
    @memset(big, '0');
    const specs0 = [_]Spec{.{ .id = 1, .pattern = pat(&pb, "127.0.0.1", "/m/churn*"), .types = mr.typeBits("xhr").?, .body = big }};
    _ = try r.mock(1, &specs0, "", true);
    r.pump(300);
    const foot0 = footKiB(host.pid);
    var fails: u32 = 0;
    var first_fail: i64 = -1;
    const rounds: usize = 160;
    for (0..rounds) |i| {
        @memset(big, 'a' + @as(u8, @intCast(i % 26)));
        const specs = [_]Spec{.{ .id = 1, .pattern = pat(&pb, "127.0.0.1", "/m/churn*"), .types = mr.typeBits("xhr").?, .body = big }};
        if (!try r.mock(1, &specs, "", true)) {
            fails += 1;
            if (first_fail < 0) first_fail = @intCast(i);
        }
    }
    r.pump(500);
    const foot1 = footKiB(host.pid);
    const got = r.ev(1, "(async()=>{try{const t=await (await fetch('/m/churn1')).text();return t.length+' '+t[0]+t[t.length-1]}catch(e){return 'reject '+e.name}})()", &o);
    const last: u8 = 'a' + @as(u8, @intCast((rounds - 1) % 26));
    var wb: [32]u8 = undefined;
    const want = std.fmt.bufPrint(&wb, "{d} {c}{c}", .{ mr.max_body_bytes, last, last }) catch "";
    const grew_kib: i64 = @as(i64, @intCast(foot1)) - @as(i64, @intCast(foot0));
    // 전에는 은퇴 묶음이 쥔 덩어리가 쌓여 +82 MiB(디버그 48→130 MB)·128 번째부터 맺음 실패였다. 산 덩어리는 하나(512 KiB) — 잡음 몫 24 MiB.
    report(fails == 0 and std.mem.eql(u8, got, want) and seen("/m/churn1") == 0 and grew_kib < 24 * 1024, "mock-churn-no-traffic", std.fmt.bufPrint(&d, "{d} 바꾸기(512 KiB·새 번호·그 사이 요청 없음) — 맺음 실패 {d}(처음 {d}번째) · 끝 fetch {s}(바람 {s}) · footprint {d} → {d} KiB(+{d})", .{ rounds, fails, first_fail, got, want, foot0, foot1, grew_kib }) catch "");
}
