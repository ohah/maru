//! W9d③ 20 회 적대 검증 1–10 회차(검증자 A)의 실제 CEF 154 판정 — `maru-web-judge --review-block-v20a`(`--network-block` 에는 들지 않는다 —
//! W9d② 의 `--review-body-v20a` 와 같은 자리). 서버·도우미는 `network_block_check.zig` 에서 옮겨 와 끝점을 더했다.
//! 회차마다(`A-R<n>-*`): R2 GURL 이 고쳐 쓰는 주소 꼴, R3 요청 도중 더한 규칙·다른 사이트로 가는 주 프레임 홉, R4 사이트 묶기(about:blank·떠난
//! 문서의 비콘·다른 사이트 iframe·blob 맨 위), R5 특별한 요청 갈래(서비스 워커 등록 스크립트는 막지 못한다 — 문서화), R6 서비스 워커 길의 T(O)
//! (불러오는 중·늦게 뜨는 iframe 이 있어도 규칙을 쥔 탭은 막는다 — MED-2), R7 귀속, R8 엄격 모드(리다이렉트로 경계를 넘은 문서는 시작 때의 값
//! 그대로 닿고 수로 알린다 — MED-1), R9 Network 도메인 차례·DevTools 지킴, R10 D2(아무 일도 하지 않은 뒤로 뒤의 에이전트 이동 — LOW-3, 친 글의
//! Chromium 꼴 — LOW-4). 탐침(`A-P-*`)은 같은 회차의 다른 길.
//! 엄격 모드(`blkstrict`): block-strict-per-tab·other-tab-untouched·same-origin-iframe·cache-to-network·reload·crosssite·site-latch·oopif-not·crash·
//!   recording-share·valve·disable-flag.
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
    // ── A-verification endpoints (rounds 1–10) ──
    if (std.mem.eql(u8, path, "/x/hang")) {
        _ = usleep(8_000_000);
        return reply(conn, "200 OK", html, "", "<!doctype html><title>hang</title>hang");
    }
    if (std.mem.eql(u8, path, "/r/slow")) {
        _ = usleep(1_500_000);
        return reply(conn, "302 Found", "text/plain", "Location: /m/late\r\nAccess-Control-Allow-Origin: *\r\n", "");
    }
    if (std.mem.eql(u8, path, "/m2/direct")) {
        _ = usleep(1_500_000);
        return reply(conn, "200 OK", "text/plain", "Access-Control-Allow-Origin: *\r\n", "direct");
    }
    if (std.mem.startsWith(u8, path, "/blk/slow")) {
        _ = usleep(2_000_000);
        return reply(conn, "200 OK", html, "", "<!doctype html><title>slow</title>slow");
    }
    if (std.mem.startsWith(u8, path, "/m/") or std.mem.startsWith(u8, path, "/m2/")) return reply(conn, "200 OK", "text/plain", "Access-Control-Allow-Origin: *\r\n", "m");
    if (std.mem.startsWith(u8, path, "/ok/")) return reply(conn, "200 OK", html, "Access-Control-Allow-Origin: *\r\n", "<!doctype html><title>ok</title>ok");
    if (std.mem.eql(u8, path, "/r/to127")) {
        const loc = std.fmt.bufPrint(&xb, "Location: http://127.0.0.1:{d}/s/page?rd\r\n", .{p}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/r/toLocal")) {
        const loc = std.fmt.bufPrint(&xb, "Location: http://localhost:{d}/s/page?L2\r\n", .{p}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/r/tolocalblk")) {
        const loc = std.fmt.bufPrint(&xb, "Location: http://localhost:{d}/blk/xsite\r\n", .{p}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/x/bcn")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>bcn</title><script>addEventListener('pagehide',()=>navigator.sendBeacon('http://127.0.0.1:{d}/blk/rev'))</script>", .{p}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/x/ifr")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>ifr</title><script>window.msgs=[];addEventListener('message',e=>window.msgs.push(e.data))</script><iframe src='http://localhost:{d}/p/ifrfetch'></iframe>", .{p}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/p/ifrfetch")) return reply(conn, "200 OK", html, "", "<!doctype html><title>ifrfetch</title><script>fetch('/blk/ifr1').then(r=>'ok '+r.status,e=>'reject '+e.name).then(t=>parent.postMessage('ifr:'+t,'*'))</script>");
    if (std.mem.eql(u8, path, "/p/worker.js")) return reply(conn, "200 OK", "application/javascript", "", "fetch(new URL(location).searchParams.get('u')).then(()=>postMessage('ok'),()=>postMessage('reject'))");
    if (std.mem.eql(u8, path, "/p/shw.js")) return reply(conn, "200 OK", "application/javascript", "", "fetch(new URL(location).searchParams.get('u')).catch(()=>0)");
    if (std.mem.eql(u8, path, "/p/csp")) {
        const q = if (std.mem.indexOf(u8, target, "r=")) |i| target[i + 2 ..] else "/ok/none";
        const hdr = std.fmt.bufPrint(&xb, "Content-Security-Policy: img-src 'none'; report-uri {s}\r\n", .{q}) catch return;
        return reply(conn, "200 OK", html, hdr, "<!doctype html><title>csp</title><img src='/p/cspimg.svg'>");
    }
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
    if (std.mem.eql(u8, path, "/s/inner")) return reply(conn, "200 OK", html, "", "<!doctype html><title>inner</title>inner");
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
    redir_missed: [max_tabs]u64 = @splat(0),
    redir_bypassed: [max_tabs]u64 = @splat(0),
    reqs: std.ArrayList(End) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    errors: std.ArrayList(ErrPage) = .empty,
    downloads: u32 = 0,
    record_state: [max_tabs]msg.NetRecordStatus = @splat(.off),
    gen: u32 = 0,

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
                self.redir_missed[v.browser] += v.strict_redirect_missed;
                self.redir_bypassed[v.browser] += v.strict_redirect_bypassed;
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

// ════════════════════════════════════════════════════════════════════════════════════════════════════════
// A-verification scenarios (rounds 1–10). Every report line starts with `A-R<n>`.
// ════════════════════════════════════════════════════════════════════════════════════════════════════════

extern "c" fn usleep(us: c_uint) c_int;

pub fn run(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    tabAttacks(report, host_path, root) catch |err| report(false, "A-tab", @errorName(err));
    swAttacks(report, host_path, root) catch |err| report(false, "A-sw", @errorName(err));
    strictAttacks(report, host_path, root) catch |err| report(false, "A-strict", @errorName(err));
    probeTab(report, host_path, root) catch |err| report(false, "A-probe-tab", @errorName(err));
    probeSw(report, host_path, root) catch |err| report(false, "A-probe-sw", @errorName(err));
    probeStrict(report, host_path, root) catch |err| report(false, "A-probe-strict", @errorName(err));
}

fn subst(buf: []u8, tmpl: []const u8, u: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var i: usize = 0;
    while (i < tmpl.len) {
        if (i + 1 < tmpl.len and tmpl[i] == '%' and tmpl[i + 1] == 'U') {
            w.writeAll(u) catch return "";
            i += 2;
            continue;
        }
        w.writeByte(tmpl[i]) catch return "";
        i += 1;
    }
    return w.buffered();
}

fn ruleHits(r: *Run, b: u64, rule: u32) u64 {
    return r.hitOf(b, rule).hits;
}

fn tabAttacks(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a_tab", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [4096]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [900]u8 = undefined;
    var p1: [128]u8 = undefined;
    var p2: [128]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    const rules = [_]msg.NetBlockRule{
        .{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/blk/*") },
        .{ .id = 2, .site = "127.0.0.1", .pattern = pat(&p2, "localhost", "/blk/*") },
    };
    report(try r.block(1, &rules, ""), "A-setup-tab", "rules 1,2 applied");

    // ── R2: URL forms the page can choose — GURL canonicalizes before the handler sees them ──
    {
        const Form = struct { label: []const u8, url: []const u8, token: []const u8 };
        var ub: [12][160]u8 = undefined;
        const forms = [_]Form{
            .{ .label = "control /blk/gq0", .url = std.fmt.bufPrint(&ub[0], "/blk/gq0x", .{}) catch unreachable, .token = "gq0x" },
            .{ .label = "hex IPv4 0x7f.0.0.1", .url = std.fmt.bufPrint(&ub[1], "http://0x7f.0.0.1:{d}/blk/gq1x", .{port}) catch unreachable, .token = "gq1x" },
            .{ .label = "decimal IPv4 2130706433", .url = std.fmt.bufPrint(&ub[2], "http://2130706433:{d}/blk/gq2x", .{port}) catch unreachable, .token = "gq2x" },
            .{ .label = "short IPv4 127.1", .url = std.fmt.bufPrint(&ub[3], "http://127.1:{d}/blk/gq3x", .{port}) catch unreachable, .token = "gq3x" },
            .{ .label = "octal IPv4 0177.0.0.1", .url = std.fmt.bufPrint(&ub[4], "http://0177.0.0.1:{d}/blk/gq4x", .{port}) catch unreachable, .token = "gq4x" },
            .{ .label = "dot-dot segment", .url = std.fmt.bufPrint(&ub[5], "/zz/../blk/gq5x", .{}) catch unreachable, .token = "gq5x" },
            .{ .label = "encoded dot-dot %2e%2e", .url = std.fmt.bufPrint(&ub[6], "/zz/%2e%2e/blk/gq6x", .{}) catch unreachable, .token = "gq6x" },
            .{ .label = "backslash", .url = std.fmt.bufPrint(&ub[7], "/blk\\\\gq7x", .{}) catch unreachable, .token = "gq7x" },
            .{ .label = "uppercase host LOCALHOST", .url = std.fmt.bufPrint(&ub[8], "http://LOCALHOST:{d}/blk/gq8x", .{port}) catch unreachable, .token = "gq8x" },
            .{ .label = "dot segment /./", .url = std.fmt.bufPrint(&ub[9], "/blk/./gq9x", .{}) catch unreachable, .token = "gq9x" },
            .{ .label = "trailing-dot host localhost.", .url = std.fmt.bufPrint(&ub[10], "http://localhost.:{d}/blk/gqAx", .{port}) catch unreachable, .token = "gqAx" },
            .{ .label = "encoded letter %62lk (documented escape class)", .url = std.fmt.bufPrint(&ub[11], "/%62lk/gqBx", .{}) catch unreachable, .token = "gqBx" },
        };
        var blocked_n: usize = 0;
        var reached_n: usize = 0;
        for (forms) |f| {
            const got = r.ev(1, imgExpr(&x, f.url), &o);
            r.pump(150);
            const s = seen(f.token);
            if (s == 0) blocked_n += 1 else reached_n += 1;
            var lb: [600]u8 = undefined;
            const line = lastSeen(f.token, &lb);
            report(true, "A-R2-form", std.fmt.bufPrint(&d, "{s}: img {s} · server {d} · server line '{s}'", .{ f.label, got, s, std.mem.trim(u8, line, "\n") }) catch "");
        }
        report(true, "A-R2-forms-summary", std.fmt.bufPrint(&d, "forms {d}: server never saw {d}, server saw {d}", .{ forms.len, blocked_n, reached_n }) catch "");
    }

    // ── R3: rule added mid-request — next hop is matched; control: no further hop ──
    {
        _ = r.ev(1, "(window.slowres='pending',fetch('/r/slow').then(r=>window.slowres='ok '+r.status,e=>window.slowres='reject '+e.name),'started')", &o);
        r.pump(400);
        var p3: [128]u8 = undefined;
        const with_m = rules ++ [_]msg.NetBlockRule{.{ .id = 3, .site = "127.0.0.1", .pattern = pat(&p3, "127.0.0.1", "/m/*") }};
        const ok3 = try r.block(1, &with_m, "");
        r.pump(2200);
        const res = r.ev(1, "window.slowres", &o);
        const e = r.endOf(1, "/m/late");
        report(starts(res, "reject") and seen("/m/late") == 0 and seen("/r/slow") == 1, "A-R3-midrequest-next-hop", std.fmt.bufPrint(&d, "rule added at ~400 ms (applied {}) while /r/slow waits 1.5 s → fetch {s} · server /r/slow {d} /m/late {d} · end flagged {}", .{ ok3, res, seen("/r/slow"), seen("/m/late"), if (e) |v| v.flags.blocked else false }) catch "");
        // control — no further hop: started before the rule, completes.
        var o2: [600]u8 = undefined;
        _ = r.ev(1, "(window.slowres2='pending',fetch('/m2/direct').then(r=>window.slowres2='ok '+r.status,e=>window.slowres2='reject '+e.name),'started')", &o2);
        r.pump(400);
        var p4: [128]u8 = undefined;
        const with_m2 = with_m ++ [_]msg.NetBlockRule{.{ .id = 4, .site = "127.0.0.1", .pattern = pat(&p4, "127.0.0.1", "/m2/*") }};
        _ = try r.block(1, &with_m2, "");
        r.pump(2000);
        const res2 = r.ev(1, "window.slowres2", &o2);
        report(starts(res2, "ok 200"), "A-R3-midrequest-control", std.fmt.bufPrint(&d, "request started before the rule with no further hop → {s} (documented: matched from the next hop)", .{res2}) catch "");
        // after the rule: same URL is blocked
        var o3: [600]u8 = undefined;
        const after = r.ev(1, fetchExpr(&x, "/m2/direct"), &o3);
        report(starts(after, "reject"), "A-R3-after-rule", std.fmt.bufPrint(&d, "same URL after the rule → {s}", .{after}) catch "");
        _ = try r.block(1, &rules, "");
    }
    // ── R3: main-frame redirect to another site — hop host binding ──
    {
        const before = seen("/blk/xsite");
        try r.nav(1, uLoop(&u, "/r/tolocalblk"), false);
        r.pump(600);
        var o2: [600]u8 = undefined;
        const title = r.ev(1, "document.title+' @'+location.host", &o2);
        report(true, "A-R3-mainframe-xsite-hop(obs)", std.fmt.bufPrint(&d, "agent nav 127.0.0.1/r/tolocalblk → 302 localhost/blk/xsite (rule 2 pattern localhost/blk/*, site 127.0.0.1): server {d} · page {s} (documented: a main-frame hop binds to the hop host)", .{ seen("/blk/xsite") - before, title }) catch "");
        // subresource control: same URL from a 127.0.0.1 page is blocked
        try r.nav(1, uLoop(&u, "/p/sub?r3c"), false);
        var o3: [600]u8 = undefined;
        var xu: [160]u8 = undefined;
        const img = r.ev(1, imgExpr(&x, uLocal(&xu, "/blk/xsite2")), &o3);
        report(std.mem.eql(u8, img, "error") and seen("/blk/xsite2") == 0, "A-R3-subresource-xsite-control", std.fmt.bufPrint(&d, "same rule as a subresource from 127.0.0.1 page: img {s} · server {d}", .{ img, seen("/blk/xsite2") }) catch "");
    }

    // ── R4: site binding — about:blank top (unknown page), reverse departing beacon, cross-site iframe, blob top ──
    {
        const skipped_before = r.skipped[1];
        try r.nav(1, "about:blank", false);
        r.pump(300);
        var bu: [160]u8 = undefined;
        const got = r.ev(1, fetchExpr(&x, uLoop(&bu, "/blk/ab1")), &o);
        r.pump(500);
        report(true, "A-R4-about-blank-unknown-page", std.fmt.bufPrint(&d, "about:blank top fetch 127.0.0.1/blk/ab1 → {s} · server {d} · skipped_unknown_page +{d} (documented fail-open)", .{ got, seen("/blk/ab1"), r.skipped[1] - skipped_before }) catch "");
    }
    {
        // reverse departing-document beacon: localhost doc (rule site 127.0.0.1 dormant there) beacons to 127.0.0.1/blk/rev while navigating into 127.0.0.1.
        try r.nav(1, uLocal(&u, "/x/bcn"), false);
        r.pump(300);
        try r.nav(1, uLoop(&u, "/p/sub?r4b"), false);
        r.pump(1000);
        report(seen("/blk/rev") == 1, "A-R4-reverse-departing-beacon", std.fmt.bufPrint(&d, "localhost document's pagehide beacon to 127.0.0.1/blk/rev after commit of 127.0.0.1 → server {d} (expected 1: the departing document is not on the rule's site)", .{seen("/blk/rev")}) catch "");
    }
    {
        try r.nav(1, uLoop(&u, "/x/ifr"), false);
        r.pump(1500);
        const msgs = r.ev(1, "JSON.stringify(window.msgs)", &o);
        report(std.mem.indexOf(u8, msgs, "ifr:reject") != null and seen("/blk/ifr1") == 0, "A-R4-cross-site-iframe", std.fmt.bufPrint(&d, "127.0.0.1 page → localhost iframe fetch localhost/blk/ifr1 (rule 2) → {s} · server {d}", .{ msgs, seen("/blk/ifr1") }) catch "");
    }
    {
        try r.nav(1, uLoop(&u, "/p/sub?r4blob"), false);
        const skipped_before = r.skipped[1];
        _ = r.ev(1, "(location.href=URL.createObjectURL(new Blob(['<!doctype html><title>blobdoc</title>blob'],{type:'text/html'})),'nav')", &o);
        r.pump(1200);
        var o2: [600]u8 = undefined;
        const where = r.ev(1, "document.title+' '+location.protocol", &o2);
        var o3: [600]u8 = undefined;
        const got = r.ev(1, fetchExpr(&x, "/blk/blob1"), &o3);
        r.pump(500);
        report(seen("/blk/blob1") == 0, "A-R4-blob-top", std.fmt.bufPrint(&d, "top-level blob: document ({s}) fetch /blk/blob1 → {s} · server {d} · skipped_unknown_page +{d}", .{ where, got, seen("/blk/blob1"), r.skipped[1] - skipped_before }) catch "");
    }

    // ── R5: special request kinds — each blocked path paired with a control path ──
    {
        try r.nav(1, uLoop(&u, "/p/sub?r5"), false);
        const Kind = struct { name: []const u8, js: []const u8 };
        const kinds = [_]Kind{
            .{ .name = "ping", .js = "(()=>{const f=document.createElement('iframe');f.name='pf'+Math.random();document.body.appendChild(f);const a=document.createElement('a');a.href='/p/sub?pn'+Math.random();a.target=f.name;a.ping='%U';document.body.appendChild(a);a.click();return 'ok'})()" },
            .{ .name = "keepalive", .js = "(fetch('%U',{keepalive:true}).then(()=>1,()=>0),'ok')" },
            .{ .name = "eventsource", .js = "(()=>{const e=new EventSource('%U');setTimeout(()=>e.close(),1000);return 'ok'})()" },
            .{ .name = "worker-script", .js = "(()=>{try{new Worker('%U')}catch(e){};return 'ok'})()" },
            .{ .name = "worker-fetch", .js = "(()=>{new Worker('/p/worker.js?u='+encodeURIComponent('%U')+'&n='+Math.random());return 'ok'})()" },
            .{ .name = "sharedworker-fetch", .js = "(()=>{new SharedWorker('/p/shw.js?u='+encodeURIComponent('%U')+'&n='+Math.random());return 'ok'})()" },
            .{ .name = "preload", .js = "(()=>{const l=document.createElement('link');l.rel='preload';l.as='fetch';l.crossOrigin='anonymous';l.href='%U';document.head.appendChild(l);return 'ok'})()" },
            .{ .name = "modulepreload", .js = "(()=>{const l=document.createElement('link');l.rel='modulepreload';l.href='%U';document.head.appendChild(l);return 'ok'})()" },
            .{ .name = "dynamic-import", .js = "(import('%U').then(()=>1,()=>0),'ok')" },
            .{ .name = "fontface", .js = "(()=>{const f=new FontFace('x'+Math.random().toString(36).slice(2),'url(%U)');f.load().then(()=>1,()=>0);return 'ok'})()" },
            .{ .name = "video", .js = "(()=>{const v=document.createElement('video');v.preload='auto';v.src='%U';document.body.appendChild(v);return 'ok'})()" },
            .{ .name = "object", .js = "(()=>{const o=document.createElement('object');o.data='%U';document.body.appendChild(o);return 'ok'})()" },
            .{ .name = "srcset", .js = "(()=>{const i=new Image();i.srcset='%U 1x';document.body.appendChild(i);return 'ok'})()" },
            .{ .name = "sw-register-script", .js = "(navigator.serviceWorker.register('%U',{scope:'%U'.replace(/[^/]*$/,'')}).then(()=>1,()=>0),'ok')" },
        };
        var blocked_ok: usize = 0;
        var control_fired: usize = 0;
        for (kinds) |k| {
            var bp: [96]u8 = undefined;
            var cp: [96]u8 = undefined;
            const blk_path = std.fmt.bufPrint(&bp, "/blk/k-{s}", .{k.name}) catch unreachable;
            const ok_path = std.fmt.bufPrint(&cp, "/ok/k-{s}", .{k.name}) catch unreachable;
            var o2: [200]u8 = undefined;
            _ = r.ev(1, subst(&x, k.js, ok_path), &o2);
            r.pump(1200);
            _ = r.ev(1, subst(&x, k.js, blk_path), &o2);
            r.pump(1200);
            const c_seen = seen(ok_path);
            const b_seen = seen(blk_path);
            if (c_seen > 0) control_fired += 1;
            if (c_seen > 0 and b_seen == 0) blocked_ok += 1;
            // 서비스 워커 등록(주) 스크립트는 어느 CEF 처리기에도 오지 않는다(20 회 검증 LOW-2 — 실측: 탭·공유 context 처리기 모두 보지 못했다) — 막지도
            // 세지도 못한다고 문서에 적었다. 그 갈래는 서버에 닿는 것이 문서의 답이다.
            const documented_unblockable = std.mem.eql(u8, k.name, "sw-register-script");
            report(if (documented_unblockable) b_seen >= 1 else (c_seen == 0 or b_seen == 0), "A-R5-kind", std.fmt.bufPrint(&d, "{s}: control server {d} · blocked path server {d}", .{ k.name, c_seen, b_seen }) catch "");
        }
        // CSP report (navigations) — control and blocked.
        try r.nav(1, uLoop(&u, "/p/csp?r=/ok/k-csp"), false);
        r.pump(1200);
        try r.nav(1, uLoop(&u, "/p/csp?r=/blk/k-csp"), false);
        r.pump(1200);
        // 보고는 POST 줄만 센다(페이지 주소 `/p/csp?r=/blk/k-csp` 자체가 그 글을 담는다 — A 1 판의 판정자 잘못).
        report(seen("POST /ok/k-csp") == 0 or seen("POST /blk/k-csp") == 0, "A-R5-kind", std.fmt.bufPrint(&d, "csp_report: control server {d} · blocked path server {d}", .{ seen("POST /ok/k-csp"), seen("POST /blk/k-csp") }) catch "");
        if (seen("POST /ok/k-csp") > 0) control_fired += 1;
        if (seen("POST /ok/k-csp") > 0 and seen("POST /blk/k-csp") == 0) blocked_ok += 1;
        report(true, "A-R5-kinds-summary", std.fmt.bufPrint(&d, "kinds {d}: control fired {d}, blocked with control fired {d}", .{ kinds.len + 1, control_fired, blocked_ok }) catch "");
        // WebSocket — honestly not blockable: server sees it, hits unchanged, no blocked end.
        try r.nav(1, uLoop(&u, "/p/sub?r5ws"), false);
        const hits_before = ruleHits(&r, 1, 1);
        var wu: [256]u8 = undefined;
        const ws = std.fmt.bufPrint(&wu, "new Promise(res=>{{const w=new WebSocket('ws://127.0.0.1:{d}/blk/ws2');w.onerror=()=>res('error');w.onopen=()=>res('open');setTimeout(()=>res('timeout'),3000)}})", .{port}) catch unreachable;
        const wres = r.ev(1, ws, &o);
        r.pump(500);
        const e = r.endOf(1, "/blk/ws2");
        report(seen("/blk/ws2") >= 1 and ruleHits(&r, 1, 1) == hits_before and (e == null or !e.?.flags.blocked), "A-R5-websocket-honest", std.fmt.bufPrint(&d, "ws {s} · server {d} · rule 1 hits {d}→{d} · end blocked {}", .{ wres, seen("/blk/ws2"), hits_before, ruleHits(&r, 1, 1), if (e) |v| v.flags.blocked else false }) catch "");
    }

    // ── R7(tab): stale main-frame attribution after a superseded blocked navigation ──
    {
        try r.nav(1, uLoop(&u, "/p/sub?r7"), false);
        const errs0 = r.errors.items.len;
        var su: [160]u8 = undefined;
        const slow = uLoop(&su, "/blk/slowA");
        try r.host.send(.{ .navigate = .{ .browser = 1, .url = slow } });
        try r.host.send(.{ .navigate = .{ .browser = 1, .url = uLoop(&u, "/p/sub?sup") } });
        r.pump(1500);
        const errs_after_supersede = r.errors.items.len - errs0;
        var rule_after_supersede: u32 = 0;
        for (r.errors.items[errs0..]) |ep| if (ep.browser == 1 and ep.rule != 0) {
            rule_after_supersede = ep.rule;
        };
        // user types the same URL (D2 exempt — the server sleeps 2 s), then the user stops it.
        const errs1 = r.errors.items.len;
        try r.host.send(.{ .navigate = .{ .browser = 1, .url = slow, .user = true } });
        r.pump(500);
        try r.host.send(.{ .nav_action = .{ .browser = 1, .action = .stop, .user = true } });
        r.pump(2500);
        var stop_err: ?ErrPage = null;
        for (r.errors.items[errs1..]) |ep| if (ep.browser == 1) {
            stop_err = ep;
        };
        report(stop_err == null or stop_err.?.rule == 0, "A-R7-stale-attribution", std.fmt.bufPrint(&d, "agent nav /blk/slowA superseded at once: error_pages {d} (rule {d}) · then user-typed /blk/slowA (server {d}) stopped → error_page {?d} rule {?d}", .{ errs_after_supersede, rule_after_supersede, seen("/blk/slowA"), if (stop_err) |v| v.code else null, if (stop_err) |v| v.rule else null }) catch "");
    }

    // ── R10: D2 — lingering nav_action token, same-document back, typed URL forms, one-shot ──
    {
        try r.create(2, uLoop(&u, "/p/sub?t2"));
        try r.watch(2);
        report(try r.block(2, &rules, ""), "A-setup-tab2", "rules on tab 2");
        // a) no-op user back (no history), then agent navigate at once.
        try r.host.send(.{ .nav_action = .{ .browser = 2, .action = .back, .user = true } });
        try r.host.send(.{ .navigate = .{ .browser = 2, .url = uLoop(&u, "/blk/nb1") } });
        _ = r.until(Run.loadsAt, 2, r.loads[2] + 1, wait_ms);
        r.pump(600);
        const a_seen = seen("/blk/nb1");
        // b) control: wait 1.3 s
        try r.host.send(.{ .nav_action = .{ .browser = 2, .action = .back, .user = true } });
        r.pump(1300);
        try r.nav(2, uLoop(&u, "/blk/nb2"), false);
        r.pump(400);
        const b_seen = seen("/blk/nb2");
        report(a_seen == 0, "A-R10-noop-back-token-steal", std.fmt.bufPrint(&d, "no-op user back then agent navigate /blk/nb1 at once → server {d} (0 expected: agent navigations are not exempt) · control after 1.3 s /blk/nb2 server {d}", .{ a_seen, b_seen }) catch "");
        // c) same-document back (pushState), then agent navigate at once.
        try r.nav(2, uLoop(&u, "/p/sub?t2b"), false);
        _ = r.ev(2, "(history.pushState({},'','/p/sub?t2b-ps'),'ps')", &o);
        r.pump(200);
        try r.host.send(.{ .nav_action = .{ .browser = 2, .action = .back, .user = true } });
        r.pump(100);
        var o2: [200]u8 = undefined;
        const loc = r.ev(2, "location.search", &o2);
        try r.host.send(.{ .navigate = .{ .browser = 2, .url = uLoop(&u, "/blk/nb3") } });
        _ = r.until(Run.loadsAt, 2, r.loads[2] + 1, wait_ms);
        r.pump(600);
        report(seen("/blk/nb3") == 0, "A-R10-samedoc-back-token-steal", std.fmt.bufPrint(&d, "user back over a pushState entry (now {s}) then agent navigate /blk/nb3 within ~100 ms → server {d}", .{ loc, seen("/blk/nb3") }) catch "");
        // d) typed URL forms that GURL rewrites.
        r.pump(1200);
        const Typed = struct { label: []const u8, path: []const u8, token: []const u8 };
        const typed = [_]Typed{
            .{ .label = "exact (control)", .path = "/blk/ty1", .token = "/blk/ty1" },
            .{ .label = "space", .path = "/blk/t y2", .token = "/blk/t%20y2" },
            .{ .label = "dot segment", .path = "/blk/zz/../ty3", .token = "/blk/ty3" },
            .{ .label = "double quote", .path = "/blk/\"ty4\"", .token = "ty4" },
        };
        var exempt_n: usize = 0;
        for (typed) |t| {
            try r.nav(2, uLoop(&u, t.path), true);
            r.pump(300);
            const s = seen(t.token);
            if (s > 0) exempt_n += 1;
            report(s > 0, "A-R10-typed-form", std.fmt.bufPrint(&d, "user-typed {s} ({s}) → server {d}", .{ t.label, t.path, s }) catch "");
        }
        // LOW-4: 친 글은 Chromium 꼴로 맞춰 보므로 넷 모두 D2 예외로 지나간다(전에는 빈칸·점 조각·따옴표 셋이 막혔다).
        report(exempt_n == typed.len, "A-R10-typed-summary", std.fmt.bufPrint(&d, "typed forms {d}: exempt (reached server) {d}", .{ typed.len, exempt_n }) catch "");
        // e) one-shot: agent navigates to the exact URL the user typed.
        const before = seen("/blk/ty1");
        try r.nav(2, uLoop(&u, "/blk/ty1"), false);
        r.pump(300);
        report(seen("/blk/ty1") == before, "A-R10-one-shot", std.fmt.bufPrint(&d, "agent re-navigates the user's typed /blk/ty1 → server +{d}", .{seen("/blk/ty1") - before}) catch "");
    }
}

fn swAttacks(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a_sw", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [900]u8 = undefined;
    var p1: [128]u8 = undefined;
    var q1: [128]u8 = undefined;
    try r.create(1, uLoop(&u, "/s/page?A"));
    const a_ctl = swReady(&r, 1);
    try r.create(2, uLoop(&u, "/s/page?B"));
    const b_ctl = swReady(&r, 2);
    try r.watch(1);
    try r.watch(2);
    const rule_a = [_]msg.NetBlockRule{.{ .id = 11, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/s/swblk*") }};
    const rule_b = [_]msg.NetBlockRule{.{ .id = 21, .site = "127.0.0.1", .pattern = pat(&q1, "127.0.0.1", "/s/swblk*") }};
    _ = try r.block(1, &rule_a, "");
    _ = try r.block(2, &rule_b, "");
    {
        const got = r.ev(1, fetchExpr(&x, "/s/swblk-base"), &o);
        report(starts(got, "reject"), "A-R6-baseline-all-ruled", std.fmt.bufPrint(&d, "A {s} B {s} fetch {s} · server {d}", .{ a_ctl, b_ctl, got, seen("/s/swblk-base") }) catch "");
    }
    // ── R6: an unruled tab C shows the origin only through a blob: document (frame URL is not the origin) ──
    {
        try r.create(3, uLoop(&u, "/s/page?C"));
        const c_ctl = swReady(&r, 3);
        // control: C on the origin vetoes.
        var o0: [600]u8 = undefined;
        const ctrl = r.ev(1, fetchExpr(&x, "/s/swblk-ctrl"), &o0);
        _ = r.ev(3, "(location.href=URL.createObjectURL(new Blob(['<!doctype html><title>blobdoc</title><script>window.ctl=String(!!(navigator.serviceWorker&&navigator.serviceWorker.controller))</script>blob'],{type:'text/html'})),'nav')", &o);
        r.pump(1500);
        var o1: [600]u8 = undefined;
        const where = r.ev(3, "document.title+' '+location.protocol+' controlled='+window.ctl", &o1);
        var o2: [600]u8 = undefined;
        var cu1: [160]u8 = undefined; // blob 문서의 상대 주소는 풀리지 않는다 — 절대 주소로(A 1 판의 판정자 잘못)
        const c_fetch = r.ev(3, fetchExpr(&x, uLoop(&cu1, "/s/swblk-c1")), &o2);
        r.pump(300);
        var lb: [600]u8 = undefined;
        const c_line = lastSeen("/s/swblk-c1", &lb);
        var o3: [600]u8 = undefined;
        const a_fetch = r.ev(1, fetchExpr(&x, "/s/swblk-a1"), &o3);
        r.pump(300);
        report(!starts(c_fetch, "reject"), "A-R6-blob-veto", std.fmt.bufPrint(&d, "C {s} · control (C on origin) A fetch {s} · C now {s} · C (unruled) fetch {s} server {d} line '{s}' · A fetch {s} server {d}", .{ c_ctl, ctrl, where, c_fetch, seen("/s/swblk-c1"), std.mem.trim(u8, c_line, "\n"), a_fetch, seen("/s/swblk-a1") }) catch "");
        try r.host.send(.{ .destroy_browser = 3 });
        r.pump(800);
    }
    // ── R6: unruled tab D shows the origin in an about:blank popup it opened (popup frame URL about:blank) ──
    {
        try r.create(4, uLoop(&u, "/s/page?D"));
        _ = swReady(&r, 4);
        _ = r.ev(4, "(window.pw=window.open('','_blank'),String(!!window.pw))", &o);
        r.pump(800);
        try r.nav(4, uLocal(&u, "/x/blank"), false);
        r.pump(500);
        var o1: [600]u8 = undefined;
        const a_fetch = r.ev(1, fetchExpr(&x, "/s/swblk-d1"), &o1);
        report(true, "A-R6-blank-popup(obs)", std.fmt.bufPrint(&d, "D opened about:blank popup then left the origin; A fetch {s} · server {d} · created {}", .{ a_fetch, seen("/s/swblk-d1"), r.created[9] }) catch "");
        try r.host.send(.{ .destroy_browser = 4 });
        r.pump(800);
    }
    // ── R7: two tabs navigate to the same SW-path URL at once — each error page carries its own rule ──
    {
        const errs = r.errors.items.len;
        _ = r.ev(1, "(setTimeout(()=>location.href='/s/swblknav7',0),'sent')", &o);
        _ = r.ev(2, "(setTimeout(()=>location.href='/s/swblknav7',0),'sent')", &o);
        r.pump(2500);
        var ra: u32 = 0;
        var rb: u32 = 0;
        var ca: i32 = 0;
        var cb: i32 = 0;
        for (r.errors.items[errs..]) |ep| {
            if (ep.browser == 1) {
                ra = ep.rule;
                ca = ep.code;
            }
            if (ep.browser == 2) {
                rb = ep.rule;
                cb = ep.code;
            }
        }
        report(ra == 11 and rb == 21 and seen("/s/swblknav7") == 0, "A-R7-same-url-two-tabs", std.fmt.bufPrint(&d, "A error {d} rule {d} · B error {d} rule {d} · server {d}", .{ ca, ra, cb, rb, seen("/s/swblknav7") }) catch "");
        try r.nav(1, uLoop(&u, "/s/page?A2"), true);
        try r.nav(2, uLoop(&u, "/s/page?B2"), true);
        r.pump(500);
    }
    // ── R7: A navigates to U while B fetches U as a subresource — attribution only on A ──
    {
        const errs = r.errors.items.len;
        _ = r.ev(2, "(setTimeout(()=>fetch('/s/swblknav8').catch(()=>0),0),'f')", &o);
        _ = r.ev(1, "(location.href='/s/swblknav8','sent')", &o);
        r.pump(2500);
        var ra: u32 = 0;
        var b_err: usize = 0;
        for (r.errors.items[errs..]) |ep| {
            if (ep.browser == 1) ra = ep.rule;
            if (ep.browser == 2) b_err += 1;
        }
        report(ra == 11 and b_err == 0, "A-R7-nav-vs-subresource", std.fmt.bufPrint(&d, "A error rule {d} · B error pages {d}", .{ ra, b_err }) catch "");
    }
}

fn controlled(r: *Run, b: u64) []const u8 {
    var o: [64]u8 = undefined;
    const c = r.ev(b, "String(!!navigator.serviceWorker.controller)", &o);
    return if (std.mem.eql(u8, c, "true")) "controlled" else if (std.mem.eql(u8, c, "false")) "bypassed" else "unknown";
}

fn reloadState(r: *Run, b: u64, tag: []const u8, x: []u8) struct { ctl: []const u8, via_sw: bool } {
    r.action(b, .reload, false) catch {};
    r.pump(600);
    const ctl = controlled(r, b);
    var o: [600]u8 = undefined;
    var pb: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/s/{s}", .{tag}) catch unreachable;
    _ = r.ev(b, fetchExpr(x, path), &o);
    return .{ .ctl = ctl, .via_sw = viaServiceWorker(path) };
}

fn strictAttacks(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a_strict", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [900]u8 = undefined;
    var p1: [128]u8 = undefined;
    // register SWs on both origins
    try r.create(1, uLocal(&u, "/s/page?Lreg"));
    _ = swReady(&r, 1);
    try r.nav(1, uLoop(&u, "/s/page?SA"), false);
    const a_ctl = swReady(&r, 1);
    try r.watch(1);
    const rules = [_]msg.NetBlockRule{.{ .id = 31, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/s/st*") }};
    report(std.mem.eql(u8, a_ctl, "controlled"), "A-setup-strict", "A controlled before strict");

    // ── R8a: strict turned on while the tab shows another site — applies when it arrives ──
    {
        try r.nav(1, uLocal(&u, "/x/blank"), false);
        const on = try r.block(1, &rules, "127.0.0.1");
        const st = r.strict[1];
        try r.nav(1, uLoop(&u, "/s/page?arrive"), false);
        r.pump(500);
        const ctl = controlled(&r, 1);
        const got = r.ev(1, fetchExpr(&x, "/s/st-arrive"), &o);
        report(on and std.mem.eql(u8, ctl, "bypassed") and starts(got, "reject") and seen("/s/st-arrive") == 0, "A-R8-on-from-other-site", std.fmt.bufPrint(&d, "strict on while on localhost → state {s} · arrive 127.0.0.1: {s} · fetch rule-matched {s} server {d}", .{ @tagName(st), ctl, got, seen("/s/st-arrive") }) catch "");
    }
    // ── R8b: redirect hops toggle the latch per hop ──
    {
        const missed0 = r.redir_missed[1];
        const bypassed0 = r.redir_bypassed[1];
        try r.nav(1, uLocal(&u, "/r/to127"), false);
        r.pump(500);
        const ctl1 = controlled(&r, 1);
        var o1: [128]u8 = undefined;
        const at1 = r.ev(1, "location.host+location.search", &o1);
        try r.nav(1, uLoop(&u, "/r/toLocal"), false);
        r.pump(800);
        const ctl2 = controlled(&r, 1);
        var o2: [128]u8 = undefined;
        const at2 = r.ev(1, "location.host+location.search", &o2);
        r.pump(300);
        // MED-1: Chromium 은 우회 값을 이동이 시작할 때만 읽는다 — 경계를 넘은 리다이렉트의 문서는 시작 값 그대로 닿고, 말없이 두지 않고 센다
        // (sidecar 의 `strict_redirect_missed`·`strict_redirect_bypassed`). 바르게 닿으면(앞으로 고치면) 세지 않아도 된다.
        const in_ok = std.mem.eql(u8, ctl1, "bypassed") or r.redir_missed[1] == missed0 + 1;
        const out_ok = std.mem.eql(u8, ctl2, "controlled") or r.redir_bypassed[1] == bypassed0 + 1;
        report(in_ok and out_ok, "A-R8-redirect-latch", std.fmt.bufPrint(&d, "localhost→302→127.0.0.1 lands {s} {s} (counted missed +{d}) · 127.0.0.1→302→localhost lands {s} {s} (counted bypassed +{d})", .{ at1, ctl1, r.redir_missed[1] - missed0, at2, ctl2, r.redir_bypassed[1] - bypassed0 }) catch "");
        try r.nav(1, uLoop(&u, "/s/page?back"), false);
        r.pump(300);
    }
    // ── R8c: 20 rapid toggles without waiting; final off then final on ──
    {
        var i: u32 = 0;
        while (i < 20) : (i += 1) {
            r.gen += 1;
            var v: msg.NetBlock = .{ .browser = 1, .generation = r.gen, .strict_site = if (i % 2 == 0) "127.0.0.1" else "", .count = 1 };
            v.rules[0] = rules[0];
            try r.host.send(.{ .net_block = v });
        }
        // last sent i=19 → off
        _ = r.until(Run.stateAt, 1, r.gen, wait_ms);
        r.pump(800);
        const st_off = r.strict[1];
        const s1 = reloadState(&r, 1, "tg-off", &x);
        const on = try r.block(1, &rules, "127.0.0.1");
        const s2 = reloadState(&r, 1, "tg-on", &x);
        report(st_off == .off and std.mem.eql(u8, s1.ctl, "controlled") and s1.via_sw and on and std.mem.eql(u8, s2.ctl, "bypassed") and !s2.via_sw, "A-R8-rapid-toggles", std.fmt.bufPrint(&d, "20 toggles ending off: state {s} · reload {s} via SW {} · then on: {s} via SW {}", .{ @tagName(st_off), s1.ctl, s1.via_sw, s2.ctl, s2.via_sw }) catch "");
    }
    // ── R8d: watch off clears strict (bypass:false first); watch on again does not resurrect it ──
    {
        try r.host.send(.{ .net_watch = .{ .browser = 1, .on = false } });
        r.pump(300);
        const s1 = reloadState(&r, 1, "wo-off", &x);
        try r.watch(1);
        try r.host.send(.{ .net_record = .{ .browser = 1, .on = true, .session = 9 } });
        r.pump(600);
        const s2 = reloadState(&r, 1, "wo-rec", &x);
        try r.host.send(.{ .net_record = .{ .browser = 1, .on = false } });
        r.pump(300);
        report(std.mem.eql(u8, s1.ctl, "controlled") and s1.via_sw and std.mem.eql(u8, s2.ctl, "controlled") and s2.via_sw, "A-R8-watch-off", std.fmt.bufPrint(&d, "net_watch off → {s} via SW {} · watch on + Network.enable by recording → {s} via SW {}", .{ s1.ctl, s1.via_sw, s2.ctl, s2.via_sw }) catch "");
    }
    // ── R9: domain ownership orders ──
    {
        const Step = enum { s_on, s_off, r_on, r_off };
        const Order = struct { name: []const u8, steps: []const Step, want_bypass: bool };
        const orders = [_]Order{
            .{ .name = "s_on r_on s_off", .steps = &.{ .s_on, .r_on, .s_off }, .want_bypass = false },
            .{ .name = "r_on s_on r_off", .steps = &.{ .r_on, .s_on, .r_off }, .want_bypass = true },
            .{ .name = "s_on r_on r_off s_off r_on", .steps = &.{ .s_on, .r_on, .r_off, .s_off, .r_on }, .want_bypass = false },
            .{ .name = "r_on s_on s_off", .steps = &.{ .r_on, .s_on, .s_off }, .want_bypass = false },
            .{ .name = "s_on s_off r_on r_off s_on", .steps = &.{ .s_on, .s_off, .r_on, .r_off, .s_on }, .want_bypass = true },
        };
        var session: u32 = 20;
        for (orders, 0..) |ord, oi| {
            // back to a clean state
            _ = try r.block(1, &rules, "");
            try r.host.send(.{ .net_record = .{ .browser = 1, .on = false } });
            r.pump(300);
            // burst: send all steps without waiting
            for (ord.steps) |st| switch (st) {
                .s_on, .s_off => {
                    r.gen += 1;
                    var v: msg.NetBlock = .{ .browser = 1, .generation = r.gen, .strict_site = if (st == .s_on) "127.0.0.1" else "", .count = 1 };
                    v.rules[0] = rules[0];
                    try r.host.send(.{ .net_block = v });
                },
                .r_on => {
                    session += 1;
                    try r.host.send(.{ .net_record = .{ .browser = 1, .on = true, .session = session } });
                },
                .r_off => try r.host.send(.{ .net_record = .{ .browser = 1, .on = false } }),
            };
            _ = r.until(Run.stateAt, 1, r.gen, wait_ms);
            r.pump(800);
            var tb: [32]u8 = undefined;
            const s = reloadState(&r, 1, std.fmt.bufPrint(&tb, "ord{d}", .{oi}) catch unreachable, &x);
            const bypassed = std.mem.eql(u8, s.ctl, "bypassed") and !s.via_sw;
            report(bypassed == ord.want_bypass, "A-R9-order", std.fmt.bufPrint(&d, "{s} (burst) → strict state {s} · record {s} · after reload {s} via SW {} (want bypass {})", .{ ord.name, @tagName(r.strict[1]), @tagName(r.record_state[1]), s.ctl, s.via_sw, ord.want_bypass }) catch "");
        }
        try r.host.send(.{ .net_record = .{ .browser = 1, .on = false } });
        _ = try r.block(1, &rules, "");
    }
    // ── R9: agent DevTools cannot touch the shared domain (guard) while strict is on ──
    {
        _ = try r.block(1, &rules, "127.0.0.1");
        const a = r.call(1, "Network.disable", "{}", 5000) catch null;
        const b = r.call(1, "Network.enable", "{}", 5000) catch null;
        const c = r.call(1, "Network.setBypassServiceWorker", "{\"bypass\":false}", 5000) catch null;
        const s = reloadState(&r, 1, "guard", &x);
        report(a == .invalid_request and b == .invalid_request and c == .invalid_request and std.mem.eql(u8, s.ctl, "bypassed"), "A-R9-devtools-guard-strict", std.fmt.bufPrint(&d, "Network.disable {?} · Network.enable {?} · setBypassServiceWorker {?} · after reload {s}", .{ a, b, c, s.ctl }) catch "");
    }
}
fn swReady(r: *Run, b: u64) []const u8 {
    var o: [128]u8 = undefined;
    _ = r.ev(b, "window.swready", &o);
    _ = r.until(Run.loadsAt, b, r.loads[b] + 1, 3000);
    r.pump(400);
    var o2: [64]u8 = undefined;
    const c = r.ev(b, "String(!!navigator.serviceWorker.controller)", &o2);
    return if (std.mem.eql(u8, c, "true")) "controlled" else "not-controlled";
}

fn viaServiceWorker(path: []const u8) bool {
    var lb: [600]u8 = undefined;
    return std.mem.indexOf(u8, lastSeen(path, &lb), "sw=") != null;
}

// ── 탐침(A 의 둘째 판 — 같은 `--review-block-v20a` 에 든다) ──────────────────────────────────────────────────

fn endsFor(r: *Run, needle: []const u8, d: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(d);
    for (r.reqs.items) |e| if (std.mem.indexOf(u8, e.url[0..e.url_len], needle) != null) {
        w.print("[b{d} ended {} blocked {} rule {d} err {d}] ", .{ e.browser, e.ended, e.flags.blocked, e.rule, e.error_code }) catch break;
    };
    return w.buffered();
}

fn probeTab(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a_ptab", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [900]u8 = undefined;
    var e1: [600]u8 = undefined;
    var p1: [128]u8 = undefined;
    var p2: [128]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub"));
    try r.watch(1);
    const rules = [_]msg.NetBlockRule{
        .{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/blk/*") },
        .{ .id = 2, .site = "127.0.0.1", .pattern = pat(&p2, "localhost", "/blk/*") },
    };
    _ = try r.block(1, &rules, "");
    // R2: trailing-dot host — blocked or DNS failure?
    {
        var xu: [160]u8 = undefined;
        const got = r.ev(1, imgExpr(&x, std.fmt.bufPrint(&xu, "http://localhost.:{d}/blk/gqAx", .{port}) catch unreachable), &o);
        r.pump(400);
        report(true, "A-P-R2-trailing-dot", std.fmt.bufPrint(&d, "img {s} · server {d} · ends {s}", .{ got, seen("gqAx"), endsFor(&r, "gqAx", &e1) }) catch "");
    }
    // R4: blob top with absolute URLs
    {
        const skipped_before = r.skipped[1];
        _ = r.ev(1, "(location.href=URL.createObjectURL(new Blob(['<!doctype html><title>blobdoc</title>blob'],{type:'text/html'})),'nav')", &o);
        r.pump(1200);
        var bu: [160]u8 = undefined;
        var cu: [160]u8 = undefined;
        var o2: [600]u8 = undefined;
        const got = r.ev(1, fetchExpr(&x, uLoop(&bu, "/blk/blob2")), &o2);
        var o3: [600]u8 = undefined;
        const ctl = r.ev(1, fetchExpr(&x, uLoop(&cu, "/ok/blob2")), &o3);
        r.pump(500);
        report(seen("/blk/blob2") == 0, "A-P-R4-blob-top-abs", std.fmt.bufPrint(&d, "blob top fetch 127.0.0.1/blk/blob2 {s} server {d} · control /ok/blob2 {s} server {d} · skipped +{d} · ends {s}", .{ got, seen("/blk/blob2"), ctl, seen("/ok/blob2"), r.skipped[1] - skipped_before, endsFor(&r, "blob2", &e1) }) catch "");
    }
    // R5: CSP report — which path?
    {
        try r.nav(1, uLoop(&u, "/p/csp?r=/blk/k-csp2"), false);
        r.pump(1500);
        report(seen("POST /blk/k-csp2") == 0, "A-P-R5-csp", std.fmt.bufPrint(&d, "csp report-uri /blk/k-csp2 server {d} · net_begin/end {s} · skipped {d} unrecorded {d}", .{ seen("POST /blk/k-csp2"), endsFor(&r, "k-csp2", &e1), r.skipped[1], r.unrecorded[1] }) catch "");
    }
    // R5: SW register in a clean page (no extra frames)
    {
        try r.nav(1, uLoop(&u, "/p/sub?swreg"), false);
        const hits_before = r.hitOf(1, 1).hits;
        const res = r.ev(1, "navigator.serviceWorker.register('/blk/swk2.js',{scope:'/blk/'}).then(()=>'registered',e=>'reject '+e.name+' '+e.message.slice(0,60))", &o);
        r.pump(800);
        const frames = r.ev(1, "String(window.frames.length)", &e1);
        report(seen("/blk/swk2.js") >= 1 and r.hitOf(1, 1).hits == hits_before, "A-P-R5-sw-register-clean", std.fmt.bufPrint(&d, "register {s} · server {d} · frames {s} · rule1 hits {d}->{d} · unrecorded {d}", .{ res, seen("/blk/swk2.js"), frames, hits_before, r.hitOf(1, 1).hits, r.unrecorded[1] }) catch "");
    }
    // R5/R6: the same page with a never-committing iframe (empty frame URL → "unknown")
    {
        _ = r.ev(1, "(()=>{const f=document.createElement('iframe');f.src='/x/hang';document.body.appendChild(f);return 'ok'})()", &o);
        r.pump(500);
        const res = r.ev(1, "navigator.serviceWorker.register('/blk/swk3.js',{scope:'/blk/'}).then(()=>'registered',e=>'reject '+e.name)", &o);
        r.pump(800);
        report(seen("/blk/swk3.js") >= 1, "A-P-R5-sw-register-hanging-frame", std.fmt.bufPrint(&d, "with a loading iframe: register {s} · server {d} · rule1 sw_hits {d} sw_not_applied {d} shared {}", .{ res, seen("/blk/swk3.js"), r.hitOf(1, 1).sw_hits, r.hitOf(1, 1).sw_not_applied, r.shared[1] }) catch "");
    }
}

fn probeSw(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a_psw", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [900]u8 = undefined;
    var p1: [128]u8 = undefined;
    var q1: [128]u8 = undefined;
    try r.create(1, uLoop(&u, "/s/page?A"));
    _ = swReady(&r, 1);
    try r.create(2, uLoop(&u, "/s/page?B"));
    _ = swReady(&r, 2);
    try r.watch(1);
    try r.watch(2);
    _ = try r.block(1, &.{.{ .id = 11, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/s/swblk*") }}, "");
    _ = try r.block(2, &.{.{ .id = 21, .site = "127.0.0.1", .pattern = pat(&q1, "127.0.0.1", "/s/swblk*") }}, "");
    const base = r.ev(1, fetchExpr(&x, "/s/swblk-p0"), &o);
    const h0 = r.hitOf(1, 11);
    // A (ruled) adds a never-committing iframe — its own frame becomes "unknown".
    var o1: [600]u8 = undefined;
    _ = r.ev(1, "(()=>{const f=document.createElement('iframe');f.src='/x/hang';document.body.appendChild(f);return 'ok'})()", &o1);
    r.pump(400);
    var o2: [600]u8 = undefined;
    const got = r.ev(1, fetchExpr(&x, "/s/swblk-p1"), &o2);
    r.pump(500);
    const h1 = r.hitOf(1, 11);
    // lazy iframe far below the fold (never loads while offscreen)
    try r.nav(1, uLoop(&u, "/s/page?A3"), true);
    r.pump(9000); // let the hanging request finish
    var o3: [600]u8 = undefined;
    _ = r.ev(1, "(()=>{const f=document.createElement('iframe');f.loading='lazy';f.src='/s/inner?lazy';f.style.marginTop='20000px';document.body.appendChild(f);return 'ok'})()", &o3);
    r.pump(400);
    var o4: [600]u8 = undefined;
    const got2 = r.ev(1, fetchExpr(&x, "/s/swblk-p2"), &o4);
    r.pump(500);
    const h2 = r.hitOf(1, 11);
    report(starts(got, "reject") and starts(got2, "reject"), "A-P-R6-self-unknown-frame", std.fmt.bufPrint(&d, "baseline {s} (sw_hits {d}) · with hanging iframe {s} server {d} (sw_hits {d} sw_not_applied {d} shared {}) · with lazy offscreen iframe {s} server {d} (sw_hits {d} sw_not_applied {d})", .{ base, h0.sw_hits, got, seen("/s/swblk-p1"), h1.sw_hits, h1.sw_not_applied, r.shared[1], got2, seen("/s/swblk-p2"), h2.sw_hits, h2.sw_not_applied }) catch "");
    // blob doc in an unruled tab C: uncontrolled → its fetch goes via its own tab path (absolute URL).
    try r.create(3, uLoop(&u, "/s/page?C"));
    _ = swReady(&r, 3);
    _ = r.ev(3, "(location.href=URL.createObjectURL(new Blob(['<!doctype html><title>blobdoc</title>blob'],{type:'text/html'})),'nav')", &o);
    r.pump(1500);
    var cu: [160]u8 = undefined;
    var o5: [600]u8 = undefined;
    const c_fetch = r.ev(3, fetchExpr(&x, uLoop(&cu, "/s/swblk-c2")), &o5);
    var lb: [600]u8 = undefined;
    const line = lastSeen("/s/swblk-c2", &lb);
    report(starts(c_fetch, "ok"), "A-P-R6-blob-unruled-abs", std.fmt.bufPrint(&d, "unruled C on blob: fetch 127.0.0.1/s/swblk-c2 {s} · server line '{s}'", .{ c_fetch, std.mem.trim(u8, line, "\n") }) catch "");
}

fn probeStrict(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a_pstrict", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [900]u8 = undefined;
    var p1: [128]u8 = undefined;
    try r.create(1, uLocal(&u, "/s/page?Lreg"));
    _ = swReady(&r, 1);
    try r.nav(1, uLoop(&u, "/s/page?SA"), false);
    _ = swReady(&r, 1);
    try r.watch(1);
    const rules = [_]msg.NetBlockRule{.{ .id = 31, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/s/st*") }};
    _ = try r.block(1, &rules, "127.0.0.1");
    const Case = struct { name: []const u8, from_local: bool, path: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .name = "direct localhost→127.0.0.1 (control)", .from_local = true, .path = "/s/page?direct", .want = "bypassed" },
        .{ .name = "direct 127.0.0.1→localhost (control)", .from_local = false, .path = "/s/page?direct2", .want = "controlled" },
        .{ .name = "redirect localhost/r/to127 → 127.0.0.1", .from_local = true, .path = "/r/to127", .want = "bypassed" },
        .{ .name = "redirect 127.0.0.1/r/toLocal → localhost", .from_local = false, .path = "/r/toLocal", .want = "controlled" },
    };
    var bad: usize = 0;
    for (cases) |c| {
        // start on the other site
        if (c.from_local) try r.nav(1, uLocal(&u, "/x/blank"), false) else try r.nav(1, uLoop(&u, "/x/blank"), false);
        r.pump(300);
        const missed_before = r.redir_missed[1];
        const bypassed_before = r.redir_bypassed[1];
        const dest = if (std.mem.eql(u8, c.path, "/s/page?direct")) uLoop(&u, c.path) else if (std.mem.eql(u8, c.path, "/s/page?direct2")) uLocal(&u, c.path) else if (c.from_local) uLocal(&u, c.path) else uLoop(&u, c.path);
        try r.nav(1, dest, false);
        r.pump(800);
        const ctl = controlled(&r, 1);
        var o1: [128]u8 = undefined;
        const at = r.ev(1, "location.host+location.search", &o1);
        // MED-1: 리다이렉트로 경계를 넘은 문서는 시작 값 그대로 닿고 센다 — 바르게 닿거나, 어긋났으면 그 갈래의 수가 하나 올라야 한다.
        r.pump(300);
        const counted = if (std.mem.eql(u8, c.want, "bypassed")) r.redir_missed[1] == missed_before + 1 else r.redir_bypassed[1] == bypassed_before + 1;
        const ok = std.mem.eql(u8, ctl, c.want) or counted;
        if (!ok) bad += 1;
        report(ok, "A-P-R8-latch", std.fmt.bufPrint(&d, "{s}: lands {s} {s} (want {s}, mismatch counted {})", .{ c.name, at, ctl, c.want, counted }) catch "");
    }
    report(bad == 0, "A-P-R8-latch-summary", std.fmt.bufPrint(&d, "cases {d} wrong {d}", .{ cases.len, bad }) catch "");
}
