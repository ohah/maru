//! W9d③ 2 차 20 회 적대 검증 1–10 회차(검증자 A2 — 6077ecc4c 를 다시 쳤다)의 실제 CEF 판정 — `maru-web-judge --review-block-v20a2`(`--network-block`
//! 에는 들지 않는다; docs/plans/web-osr-backend.md 「W9d③ 20 회 적대 검증」 의 2 차). 검증자의 `--a2-attack` 을 고친 뒤의 답으로 단언하게 옮겼다.
//! 회차마다:
//!   - R1·R2(`canon`): Chromium 의 URL 파서와 `url_canon.hash`(D2 의 친 주소 비교)·`net_block.parse`(맞을 수 없는 경로 거절)를 무작위로 대조, 앞부분
//!     꼴의 끝 점 조각(N-A2-1), 패턴이 거절하는 호스트 글자(`!$~+` — N-A2-2)는 Chromium 이 요청을 보내지 않아 규칙이 쓸모없음을 잰다.
//!   - R5(`imp`): 서비스 워커가 가져오는 스크립트(importScripts·모듈 import)는 서비스 워커 길에서 막히고 `sw_hits` 로 센다(N-A2-5 — 문서).
//!   - R6(`sw`): MED-A2-1 — 출처를 보이지 않는 「모르는」 규칙 탭은 T(O) 에서 빠진다(빈 T 는 막지 않음·무관한 탭에 「적용 안 됨」 없음), 보수 규칙의
//!     거부권(규칙 없는 모르는 탭)은 그대로 센다.
//!   - R8(`strict`): LOW-A2-2 — 엄격의 리다이렉트 어긋남은 닿은 문서마다 정확히 한 번(204·다운로드·멈춤 뒤의 같은 문서 이동은 0, 옛 문서의 pushState 가
//!     낀 진짜 어긋남은 1).
//!   - R10(`d2`): LOW-A2-3·LOW-A2-4·N-A2-3 — 에이전트의 CDP 기록 이동·새로 고침과 페이지의 이동은 사용자의 토큰을 가져가지 못하고, 늦게 답한 떠나기
//!     확인 뒤의 사용자 이동은 예외, maru 가 보낼 수 있는 친 주소 꼴 12 가지가 모두 예외.
//! 바꾼 것: 검증자의 고르기 변수 `A2_ONLY` 는 `V20A2_ONLY` 로, 시험 서버는 1 차 검증(A)의 끝점을 함께 쓴다.

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
    // ── A2 endpoints ──
    if (std.mem.eql(u8, path, "/r/go")) {
        // 302 to everything after the first `to=` (raw — nested chains carry their own `to=`).
        const at = std.mem.indexOf(u8, target, "to=") orelse return reply(conn, "400 Bad Request", "text/plain", "", "no to");
        const loc = std.fmt.bufPrint(&xb, "Location: {s}\r\nAccess-Control-Allow-Origin: *\r\n", .{target[at + 3 ..]}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/n204")) return reply(conn, "204 No Content", "text/plain", "", "");
    if (std.mem.eql(u8, path, "/r/slowgo")) {
        // 1.5 초 뒤 `to=` 뒤로 302(이동 중에 엄격을 켤 틈).
        _ = usleep(1_500_000);
        const at = std.mem.indexOf(u8, target, "to=") orelse return reply(conn, "400 Bad Request", "text/plain", "", "no to");
        const loc = std.fmt.bufPrint(&xb, "Location: {s}\r\n", .{target[at + 3 ..]}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.startsWith(u8, path, "/dl/")) return reply(conn, "200 OK", "application/octet-stream", "Content-Disposition: attachment; filename=a2.bin\r\n", "data");
    if (std.mem.eql(u8, path, "/x/slowpage")) {
        _ = usleep(1_500_000);
        return reply(conn, "200 OK", html, "", "<!doctype html><title>slowpage</title>slow");
    }
    if (std.mem.eql(u8, path, "/x/lazy")) return reply(conn, "200 OK", html, "", "<!doctype html><title>lazy</title><div style='height:30000px'></div><iframe loading=lazy src='/p/sub?lz'></iframe>");
    if (std.mem.eql(u8, path, "/p/ifrhist")) return reply(conn, "200 OK", html, "", "<!doctype html><title>ifrhist</title><iframe id=f src='/p/sub?f1'></iframe>");
    if (std.mem.startsWith(u8, path, "/blk/h")) return reply(conn, "200 OK", html, "Cache-Control: no-store\r\n", "<!doctype html><title>blk-h</title><script>addEventListener('unload',()=>{});window.bc=new BroadcastChannel('a2')</script>h");
    if (std.mem.startsWith(u8, path, "/blk/bu") or std.mem.eql(u8, path, "/p/bu")) return reply(conn, "200 OK", html, "", "<!doctype html><title>bu</title><script>addEventListener('beforeunload',e=>{e.preventDefault();e.returnValue='x'})</script>bu");
    if (std.mem.eql(u8, path, "/i/sw.js")) return reply(conn, "200 OK", "application/javascript", "", "importScripts('/blk/imp1.js');self.addEventListener('fetch',()=>{})");
    if (std.mem.eql(u8, path, "/i/swm.js")) return reply(conn, "200 OK", "application/javascript", "", "import '/blk/impm.js';self.addEventListener('fetch',()=>{})");
    if (std.mem.startsWith(u8, path, "/blk/impm")) return reply(conn, "200 OK", "application/javascript", "", "export{}");
    if (std.mem.startsWith(u8, path, "/blk/imp")) return reply(conn, "200 OK", "application/javascript", "", "self.imp=1");
    if (std.mem.eql(u8, path, "/s/slowpage")) {
        _ = usleep(1_500_000);
        return reply(conn, "200 OK", html, "", "<!doctype html><title>sslow</title>sslow");
    }
    if (std.mem.eql(u8, path, "/i/page")) return reply(conn, "200 OK", html, "", "<!doctype html><title>ipage</title>i");
    // ── 1 차 검증(A)의 끝점 — 같은 서버를 쓴다 ──
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

const max_tabs = 40;

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
    dialogs: std.ArrayList(msg.JsDialog) = .empty,

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
            .js_dialog => |v| self.dialogs.append(self.gpa, .{ .browser = v.browser, .request = v.request, .kind = v.kind, .origin = "", .message = "" }) catch {},
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
// 2 차 검증 1–10 회차의 시나리오 — 보고 줄은 `A2-R<n>` 으로 시작한다.
// ════════════════════════════════════════════════════════════════════════════════════════════════════════

extern "c" fn usleep(us: c_uint) c_int;

const url_canon = protocol.url_canon;
const nbp = protocol.net_block;

fn only(name: []const u8) bool {
    const v = std.c.getenv("V20A2_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(v), name) != null;
}

pub fn run(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    if (only("strict")) strictCounts(report, host_path, root) catch |err| report(false, "A2-strict", @errorName(err));
    if (only("d2")) d2Tokens(report, host_path, root) catch |err| report(false, "A2-d2", @errorName(err));
    if (only("sw")) swShared(report, host_path, root) catch |err| report(false, "A2-sw", @errorName(err));
    if (only("imp")) swImports(report, host_path, root) catch |err| report(false, "A2-imp", @errorName(err));
    if (only("canon")) liveCanon(report, host_path, root) catch |err| report(false, "A2-canon", @errorName(err));
}

fn ctlOf(r: *Run, b: u64) []const u8 {
    var o: [64]u8 = undefined;
    const c = r.ev(b, "String(!!(navigator.serviceWorker&&navigator.serviceWorker.controller))", &o);
    return if (std.mem.eql(u8, c, "true")) "controlled" else if (std.mem.eql(u8, c, "false")) "bypassed" else "unknown";
}

fn swReadyA2(r: *Run, b: u64) []const u8 {
    var o: [128]u8 = undefined;
    _ = r.ev(b, "window.swready", &o);
    _ = r.until(Run.loadsAt, b, r.loads[b] + 1, 3000);
    r.pump(400);
    return ctlOf(r, b);
}

/// `%L` → localhost origin, `%I` → 127.0.0.1 origin.
fn expand(buf: []u8, tmpl: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var i: usize = 0;
    while (i < tmpl.len) {
        if (i + 1 < tmpl.len and tmpl[i] == '%' and (tmpl[i + 1] == 'L' or tmpl[i + 1] == 'I')) {
            w.print("http://{s}:{d}", .{ if (tmpl[i + 1] == 'L') "localhost" else "127.0.0.1", port }) catch return "";
            i += 2;
            continue;
        }
        w.writeByte(tmpl[i]) catch return "";
        i += 1;
    }
    return w.buffered();
}

// ── R8: MED-1 counting — exactly once for a real crossing, never for a crossing that did not land ──────────────

fn strictCounts(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a2_strict", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [1024]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [1400]u8 = undefined;
    var p1: [128]u8 = undefined;
    try r.create(1, uLocal(&u, "/s/page?Lreg"));
    const l_reg = swReadyA2(&r, 1);
    _ = r.ev(1, "(sessionStorage.rl=1,'ok')", &o);
    try r.nav(1, uLoop(&u, "/s/page?Ireg"), false);
    const i_reg = swReadyA2(&r, 1);
    _ = r.ev(1, "(sessionStorage.rl=1,'ok')", &o);
    try r.watch(1);
    const rules = [_]msg.NetBlockRule{.{ .id = 31, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/s/st*") }};
    const on = try r.block(1, &rules, "127.0.0.1");
    report(on and std.mem.eql(u8, l_reg, "controlled") and std.mem.eql(u8, i_reg, "controlled"), "A2-R8-setup", std.fmt.bufPrint(&d, "SW localhost {s} · 127.0.0.1 {s} · strict on {} state {s}", .{ l_reg, i_reg, on, @tagName(r.strict[1]) }) catch "");

    const How = enum { agent, page, stop };
    const Case = struct {
        name: []const u8,
        start_local: bool,
        dest: []const u8,
        how: How = .agent,
        lands: bool = true,
        after: []const u8 = "",
        want_missed: u64 = 0,
        want_bypassed: u64 = 0,
        want_ctl: []const u8 = "",
    };
    const cases = [_]Case{
        .{ .name = "C1 in: localhost→302→127 (real crossing — count once, replace/pushState after do not add)", .start_local = true, .dest = "%L/r/go?to=%I/s/inner?c1", .after = "(history.replaceState({},'','?c1r'),history.pushState({},'','?c1p'),'ok')", .want_missed = 1, .want_ctl = "controlled" },
        .{ .name = "C2 out: 127→302→localhost (count once)", .start_local = false, .dest = "%I/r/go?to=%L/s/inner?c2", .after = "(history.pushState({},'','?c2p'),'ok')", .want_bypassed = 1, .want_ctl = "bypassed" },
        .{ .name = "C3 same-site 127→302→127", .start_local = false, .dest = "%I/r/go?to=%I/s/inner?c3", .want_ctl = "bypassed" },
        .{ .name = "C4 direct localhost→127", .start_local = true, .dest = "%I/s/inner?c4", .want_ctl = "bypassed" },
        .{ .name = "C5 direct 127→localhost", .start_local = false, .dest = "%L/s/inner?c5", .want_ctl = "controlled" },
        .{ .name = "C6 A→B→A 127→localhost→127", .start_local = false, .dest = "%I/r/go?to=%L/r/go?to=%I/s/inner?c6", .want_ctl = "bypassed" },
        .{ .name = "C7 B→A→B localhost→127→localhost", .start_local = true, .dest = "%L/r/go?to=%I/r/go?to=%L/s/inner?c7", .want_ctl = "controlled" },
        .{ .name = "C8 B→A→A localhost→127→127", .start_local = true, .dest = "%L/r/go?to=%I/r/go?to=%I/s/inner?c8", .want_missed = 1, .want_ctl = "controlled" },
        .{ .name = "C9 page-initiated in: location.href localhost→302→127", .start_local = true, .dest = "%L/r/go?to=%I/s/inner?c9", .how = .page, .want_missed = 1, .want_ctl = "controlled" },
        .{ .name = "F1 aborted (204) in-crossing while on 127, then pushState", .start_local = false, .dest = "%L/r/go?to=%I/n204", .lands = false, .after = "(history.pushState({},'','?f1p'),'ok')" },
        .{ .name = "F2 aborted (204) out-crossing while on localhost, then pushState", .start_local = true, .dest = "%I/r/go?to=%L/n204", .lands = false, .after = "(history.pushState({},'','?f2p'),'ok')" },
        .{ .name = "F3 download in-crossing while on 127, then pushState", .start_local = false, .dest = "%L/r/go?to=%I/dl/f3.bin", .lands = false, .after = "(history.pushState({},'','?f3p'),'ok')" },
        .{ .name = "F4 download out-crossing while on localhost, then pushState", .start_local = true, .dest = "%I/r/go?to=%L/dl/f4.bin", .lands = false, .after = "(history.pushState({},'','?f4p'),'ok')" },
        .{ .name = "F5 stopped in-crossing (hanging target) while on 127, then pushState", .start_local = false, .dest = "%L/r/go?to=%I/x/hang", .how = .stop, .lands = false, .after = "(history.pushState({},'','?f5p'),'ok')" },
        .{ .name = "F6 aborted (204) in-crossing while on 127, then location.hash", .start_local = false, .dest = "%L/r/go?to=%I/n204", .lands = false, .after = "(location.hash='f6','ok')" },
        .{ .name = "M1 out-crossing, old 127 document pushState while the localhost page is slow", .start_local = false, .dest = "%I/r/go?to=%L/s/slowpage?m1", .how = .page, .want_bypassed = 1, .want_ctl = "bypassed" },
        .{ .name = "M2 in-crossing, old localhost document pushState while the 127 page is slow", .start_local = true, .dest = "%L/r/go?to=%I/s/slowpage?m2", .how = .page, .want_missed = 1, .want_ctl = "controlled" },
    };
    var wrong: usize = 0;
    for (cases, 0..) |c, ci| {
        var sb: [64]u8 = undefined;
        const start_path = std.fmt.bufPrint(&sb, "/x/blank?st{d}", .{ci}) catch unreachable;
        if (c.start_local) try r.nav(1, uLocal(&u, start_path), false) else try r.nav(1, uLoop(&u, start_path), false);
        r.pump(300);
        const m0 = r.redir_missed[1];
        const b0 = r.redir_bypassed[1];
        var db: [512]u8 = undefined;
        const dest = expand(&db, c.dest);
        const loads0 = r.loads[1];
        switch (c.how) {
            .agent => {
                try r.host.send(.{ .navigate = .{ .browser = 1, .url = dest } });
            },
            .page => {
                const is_m = c.name[0] == 'M';
                const js = if (is_m)
                    std.fmt.bufPrint(&x, "(setTimeout(()=>history.pushState({{}},'','?inflight'),700),location.href='{s}','ok')", .{dest}) catch unreachable
                else
                    std.fmt.bufPrint(&x, "(location.href='{s}','ok')", .{dest}) catch unreachable;
                _ = r.ev(1, js, &o);
            },
            .stop => {
                try r.host.send(.{ .navigate = .{ .browser = 1, .url = dest } });
                r.pump(700);
                try r.host.send(.{ .nav_action = .{ .browser = 1, .action = .stop } });
            },
        }
        if (c.lands) {
            _ = r.until(Run.loadsAt, 1, loads0 + 1, wait_ms);
            r.pump(500);
        } else r.pump(1800);
        var ob: [600]u8 = undefined;
        if (c.after.len != 0) {
            _ = r.ev(1, c.after, &ob);
        }
        r.pump(700);
        const ctl = ctlOf(&r, 1);
        var lb: [200]u8 = undefined;
        const at = r.ev(1, "location.host+location.pathname+location.search+location.hash", &lb);
        const dm = r.redir_missed[1] - m0;
        const dbp = r.redir_bypassed[1] - b0;
        const ctl_ok = c.want_ctl.len == 0 or std.mem.eql(u8, ctl, c.want_ctl);
        const ok = dm == c.want_missed and dbp == c.want_bypassed and ctl_ok;
        if (!ok) wrong += 1;
        report(ok, "A2-R8-count", std.fmt.bufPrint(&d, "{s}: at {s} {s} (want {s}) · missed +{d} (want {d}) · bypassed +{d} (want {d}) · downloads {d}", .{ c.name, at, ctl, c.want_ctl, dm, c.want_missed, dbp, c.want_bypassed, r.downloads }) catch "");
        if (c.how == .stop) r.pump(8500); // let the hanging server thread finish
    }
    report(wrong == 0, "A2-R8-count-summary", std.fmt.bufPrint(&d, "cases {d} wrong {d}", .{ cases.len, wrong }) catch "");
    // N-A2-6: 엄격이 꺼진 채 시작한 이동이 도중에 켠 엄격의 사이트로 리다이렉트되어 닿으면 — 그 이동의 시작 값은 「끔」 이라 리다이렉트 어긋남이 아니다
    // (안내대로 「다음 이동부터」 — 세지 않는다). 첫 홉마다 시작 값을 다시 재고 그 이동이 엄격으로 시작했을 때만 센다.
    {
        _ = try r.block(1, &rules, "");
        try r.nav(1, uLocal(&u, "/x/blank?s1"), false);
        r.pump(300);
        const m0 = r.redir_missed[1];
        const b0 = r.redir_bypassed[1];
        var db: [512]u8 = undefined;
        const loads0 = r.loads[1];
        try r.host.send(.{ .navigate = .{ .browser = 1, .url = expand(&db, "%L/r/slowgo?to=%I/s/inner?s1") } });
        r.pump(500);
        const on_mid = try r.block(1, &rules, "127.0.0.1");
        _ = r.until(Run.loadsAt, 1, loads0 + 1, wait_ms);
        r.pump(700);
        const ctl = ctlOf(&r, 1);
        var lb: [200]u8 = undefined;
        const at = r.ev(1, "location.host+location.pathname+location.search", &lb);
        const dm = r.redir_missed[1] - m0;
        const dbp = r.redir_bypassed[1] - b0;
        report(on_mid and dm == 0 and dbp == 0, "A2-R8-strict-on-mid-navigation", std.fmt.bufPrint(&d, "strict off at the start, turned on at 500 ms (ok {}), localhost→slow 302→127: at {s} {s} · missed +{d} · bypassed +{d} (want 0/0: not a redirect gap — strict applies from the next navigation)", .{ on_mid, at, ctl, dm, dbp }) catch "");
    }
}

// ── R10: D2 tokens ─────────────────────────────────────────────────────────────────────────────────────────

fn waitDialog(r: *Run, b: u64, from: usize, ms: u32) ?msg.JsDialog {
    const deadline = os.nowMs() + ms;
    while (os.nowMs() < deadline) {
        for (r.dialogs.items[from..]) |dl| if (dl.browser == b) return dl;
        const m = (r.host.next(50) catch null) orelse continue;
        r.take(m);
    }
    for (r.dialogs.items[from..]) |dl| if (dl.browser == b) return dl;
    return null;
}

/// The agent's `browser.back` (web_cdp_ops): Page.getNavigationHistory then Page.navigateToHistoryEntry(currentIndex - 1).
fn cdpBack(r: *Run, b: u64) []const u8 {
    const st = r.call(b, "Page.getNavigationHistory", "{}", 5000) catch null;
    if (st == null or st.? != .ok) return "history-failed";
    const parsed = std.json.parseFromSlice(std.json.Value, r.gpa, r.result.items, .{}) catch return "history-unparsed";
    defer parsed.deinit();
    const ci = parsed.value.object.get("currentIndex") orelse return "no-index";
    const entries = parsed.value.object.get("entries") orelse return "no-entries";
    if (ci.integer < 1) return "at-start";
    const id = entries.array.items[@intCast(ci.integer - 1)].object.get("id").?.integer;
    var pb: [64]u8 = undefined;
    const params = std.fmt.bufPrint(&pb, "{{\"entryId\":{d}}}", .{id}) catch return "fmt";
    const st2 = r.call(b, "Page.navigateToHistoryEntry", params, 5000) catch null;
    return if (st2 != null and st2.? == .ok) "sent" else "nav-failed";
}

/// The agent's `browser.reload` (web_cdp_ops): Page.reload.
fn cdpReload(r: *Run, b: u64) []const u8 {
    const st = r.call(b, "Page.reload", "{}", 5000) catch null;
    return if (st != null and st.? == .ok) "sent" else "reload-failed";
}

fn d2Tokens(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a2_d2", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var o: [600]u8 = undefined;
    var o2: [600]u8 = undefined;
    var d: [1400]u8 = undefined;
    var p1: [128]u8 = undefined;
    const rules = [_]msg.NetBlockRule{.{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/blk/*") }};

    // T1: a user back that only moves an iframe leaves the history token; the agent's back within 1 s takes it.
    // control (tab 2): the same without the user back — the agent's back to the blocked page is blocked.
    {
        try r.create(2, uLoop(&u, "/blk/h2"));
        try r.nav(2, uLoop(&u, "/p/ifrhist?c"), false);
        try r.watch(2);
        _ = try r.block(2, &rules, "");
        const c0 = seen("/blk/h2");
        const sent = cdpBack(&r, 2);
        r.pump(1500);
        const cerr = r.lastError(2);
        report(seen("/blk/h2") == c0, "A2-R10-iframe-back-control", std.fmt.bufPrint(&d, "agent back (CDP {s}) to /blk/h2 (no user gesture) → server +{d} · error page {?d} rule {?d}", .{ sent, seen("/blk/h2") - c0, if (cerr) |v| v.code else null, if (cerr) |v| v.rule else null }) catch "");
    }
    {
        try r.create(1, uLoop(&u, "/blk/h1"));
        try r.nav(1, uLoop(&u, "/p/ifrhist?a"), false);
        // with a user gesture: Chrome's back button skips history entries added without one (history intervention — run 1 had none).
        _ = r.evAs(1, "(document.getElementById('f').src='/p/sub?f2','ok')", &o, true);
        r.pump(800);
        const hl = r.ev(1, "String(history.length)", &o);
        try r.watch(1);
        _ = try r.block(1, &rules, "");
        const c0 = seen("/blk/h1");
        try r.host.send(.{ .nav_action = .{ .browser = 1, .action = .back, .user = true } });
        r.pump(300);
        // 사이에 스크립트를 돌리지 않는다(에이전트의 Runtime 호출도 토큰을 거둔다 — 이 항목은 기록 이동 자체가 거두는지를 본다).
        const sent = cdpBack(&r, 1);
        r.pump(1500);
        const after_user = r.ev(1, "location.pathname+location.search+' iframe='+(document.getElementById('f')?document.getElementById('f').contentWindow.location.search:'none')", &o2);
        var ab: [200]u8 = undefined;
        const after_user_copy = ab[0..@min(ab.len, after_user.len)];
        @memcpy(after_user_copy, after_user[0..after_user_copy.len]);
        const e = r.lastError(1);
        var lb: [200]u8 = undefined;
        const at = r.ev(1, "location.pathname+' '+document.title", &lb);
        report(seen("/blk/h1") == c0, "A2-R10-iframe-back-token-steal", std.fmt.bufPrint(&d, "history.length {s} · user back moved only the iframe · agent back (CDP navigateToHistoryEntry {s}) 300 ms later → server +{d} · page {s} (after: {s}) · error page {?d} rule {?d} (want blocked: agent history navigations are not exempt)", .{ hl, sent, seen("/blk/h1") - c0, at, after_user_copy, if (e) |v| v.code else null, if (e) |v| v.rule else null }) catch "");
    }
    // T1b: 같은 것을 페이지가 — 사용자의 뒤로가 iframe 만 옮기고 400 ms 뒤 페이지의 `history.go(-1)` 이 주 프레임 기록 이동을 시작한다(스크립트는 사용자
    // 몸짓 **앞에** 걸어 둔다 — 그 사이 Runtime 호출이 없게). 그 기록 이동은 사용자의 것이 아니다(iframe 기록 이동이 토큰을 거둔다).
    {
        try r.create(8, uLoop(&u, "/blk/h8"));
        try r.nav(8, uLoop(&u, "/p/ifrhist?b"), false);
        _ = r.evAs(8, "(document.getElementById('f').src='/p/sub?f2','ok')", &o, true);
        r.pump(800);
        try r.watch(8);
        _ = try r.block(8, &rules, "");
        const c0 = seen("/blk/h8");
        _ = r.ev(8, "(setTimeout(()=>history.go(-1),400),'armed')", &o);
        try r.host.send(.{ .nav_action = .{ .browser = 8, .action = .back, .user = true } });
        r.pump(2000);
        const e = r.lastError(8);
        report(seen("/blk/h8") == c0, "A2-R10-iframe-back-page-history-steal", std.fmt.bufPrint(&d, "user back moved only the iframe, page history.go(-1) 400 ms later → server +{d} · error page {?d} rule {?d} (want blocked)", .{ seen("/blk/h8") - c0, if (e) |v| v.code else null, if (e) |v| v.rule else null }) catch "");
    }

    // T2: a typed fragment-only navigation leaves the 5 s URL token; the agent's reload of that URL takes it.
    {
        try r.create(3, uLoop(&u, "/p/sub?t3"));
        try r.watch(3);
        _ = try r.block(3, &rules, "");
        try r.nav(3, uLoop(&u, "/blk/cur3"), true);
        const typed = seen("/blk/cur3");
        try r.host.send(.{ .navigate = .{ .browser = 3, .url = uLoop(&u, "/blk/cur3#frag"), .user = true } });
        r.pump(300);
        const c0 = seen("/blk/cur3");
        const rs3 = cdpReload(&r, 3);
        _ = r.until(Run.loadsAt, 3, r.loads[3] + 1, 5000);
        r.pump(600);
        const steal = seen("/blk/cur3") - c0;
        var hb: [100]u8 = undefined;
        const hash_now = r.ev(3, "document.title", &hb);
        // control: same without the fragment step.
        try r.create(4, uLoop(&u, "/p/sub?t4"));
        try r.watch(4);
        _ = try r.block(4, &rules, "");
        try r.nav(4, uLoop(&u, "/blk/cur4"), true);
        const typed4 = seen("/blk/cur4");
        r.pump(300);
        const c4 = seen("/blk/cur4");
        _ = cdpReload(&r, 4);
        _ = r.until(Run.loadsAt, 4, r.loads[4] + 1, 5000);
        r.pump(600);
        const ctrl = seen("/blk/cur4") - c4;
        // variant: page-initiated navigation to the same URL (agent `exec`).
        try r.host.send(.{ .navigate = .{ .browser = 4, .url = uLoop(&u, "/p/sub?t4b"), .user = true } });
        r.pump(800);
        try r.nav(4, uLoop(&u, "/blk/cur5"), true);
        // 페이지의 같은 주소 이동은 친 `#x` **앞에** 걸어 둔다(그 사이 Runtime 호출이 없게 — 거두는 것은 같은 문서 확정이어야 한다).
        _ = r.ev(4, "(setTimeout(()=>location.href=location.href.split('#')[0],600),'armed')", &o);
        const c5 = seen("/blk/cur5");
        try r.host.send(.{ .navigate = .{ .browser = 4, .url = uLoop(&u, "/blk/cur5#x"), .user = true } });
        _ = r.until(Run.loadsAt, 4, r.loads[4] + 1, 5000);
        r.pump(600);
        const steal_page = seen("/blk/cur5") - c5;
        report(steal == 0 and steal_page == 0, "A2-R10-fragment-url-token-steal", std.fmt.bufPrint(&d, "user typed /blk/cur3 (server {d}) then /blk/cur3#frag (title after the agent reload {s}) → agent reload (CDP Page.reload {s}) 300 ms later: server +{d} · control without the fragment step: typed {d}, agent reload +{d} · page-initiated location.href to the same URL after a typed #x: server +{d} (want 0 everywhere: only the user's own navigation is exempt)", .{ typed, hash_now, rs3, steal, typed4, ctrl, steal_page }) catch "");
    }

    // T3: a beforeunload dialog that the user answers late — the user's own navigation should still be exempt.
    {
        try r.create(5, uLoop(&u, "/p/bu"));
        var gb: [32]u8 = undefined;
        _ = r.evAs(5, "1", &gb, true);
        try r.watch(5);
        _ = try r.block(5, &rules, "");
        const Variant = struct { label: []const u8, wait: u32, path: []const u8 };
        const vs = [_]Variant{
            .{ .label = "typed, answered after 200 ms", .wait = 200, .path = "/blk/bu1" },
            .{ .label = "typed, answered after 6 s", .wait = 6000, .path = "/blk/bu2" },
        };
        for (vs) |v| {
            // back to a beforeunload page with sticky activation
            if (!std.mem.eql(u8, v.path, "/blk/bu1")) {
                try r.nav(5, uLoop(&u, "/p/bu?again"), true);
                _ = r.evAs(5, "1", &gb, true);
            }
            const from = r.dialogs.items.len;
            const c0 = seen(v.path);
            try r.host.send(.{ .navigate = .{ .browser = 5, .url = uLoop(&u, v.path), .user = true } });
            const dl = waitDialog(&r, 5, from, 3000);
            if (dl) |q| {
                r.pump(v.wait);
                try r.host.send(.{ .dialog_reply = .{ .browser = 5, .request = q.request, .accept = true } });
            }
            _ = r.until(Run.loadsAt, 5, r.loads[5] + 1, 5000);
            r.pump(600);
            const e = r.lastError(5);
            report(seen(v.path) > c0, "A2-R10-beforeunload-typed", std.fmt.bufPrint(&d, "{s}: dialog {s} · server +{d} · last error page {?d} rule {?d} (want exempt: the user's typed navigation)", .{ v.label, if (dl) |q| @tagName(q.kind) else "none", seen(v.path) - c0, if (e) |q| q.code else null, if (e) |q| q.rule else null }) catch "");
        }
        // reload of a blocked-URL page with beforeunload (loaded before the rule).
        try r.create(6, uLoop(&u, "/blk/bu3"));
        try r.watch(6);
        _ = try r.block(6, &rules, "");
        const RV = struct { label: []const u8, wait: u32 };
        for ([_]RV{ .{ .label = "user reload, answered after 200 ms", .wait = 200 }, .{ .label = "user reload, answered after 1.5 s", .wait = 1500 } }) |v| {
            _ = r.evAs(6, "1", &gb, true);
            const from = r.dialogs.items.len;
            const c0 = seen("/blk/bu3");
            try r.host.send(.{ .nav_action = .{ .browser = 6, .action = .reload, .user = true } });
            const dl = waitDialog(&r, 6, from, 3000);
            if (dl) |q| {
                r.pump(v.wait);
                try r.host.send(.{ .dialog_reply = .{ .browser = 6, .request = q.request, .accept = true } });
            }
            _ = r.until(Run.loadsAt, 6, r.loads[6] + 1, 5000);
            r.pump(600);
            const e = r.lastError(6);
            report(seen("/blk/bu3") > c0, "A2-R10-beforeunload-reload", std.fmt.bufPrint(&d, "{s}: dialog {s} · server +{d} · last error page {?d} rule {?d} (want exempt)", .{ v.label, if (dl) |q| @tagName(q.kind) else "none", seen("/blk/bu3") - c0, if (e) |q| q.code else null, if (e) |q| q.rule else null }) catch "");
            // a blocked reload shows the error page — reload the real page again for the next variant (user typed — exempt)
            if (seen("/blk/bu3") == c0) try r.nav(6, uLoop(&u, "/blk/bu3"), true);
        }
    }

    // T4: typed forms that Chromium rewrites (beyond the nine of LOW-4).
    {
        try r.create(7, uLoop(&u, "/p/sub?t7"));
        try r.watch(7);
        _ = try r.block(7, &rules, "");
        const Form = struct { label: []const u8, url: []const u8, token: []const u8 };
        var fb: [14][200]u8 = undefined;
        const forms = [_]Form{
            .{ .label = "control exact", .url = std.fmt.bufPrint(&fb[0], "http://127.0.0.1:{d}/blk/tf0", .{port}) catch unreachable, .token = "/blk/tf0" },
            .{ .label = "uppercase scheme and host", .url = std.fmt.bufPrint(&fb[1], "HTTP://127.0.0.1:{d}/blk/tf1", .{port}) catch unreachable, .token = "/blk/tf1" },
            .{ .label = "invalid escape %zz", .url = std.fmt.bufPrint(&fb[2], "http://127.0.0.1:{d}/blk/tf2%zz", .{port}) catch unreachable, .token = "/blk/tf2" },
            .{ .label = "brackets [x]", .url = std.fmt.bufPrint(&fb[3], "http://127.0.0.1:{d}/blk/tf3[x]", .{port}) catch unreachable, .token = "/blk/tf3" },
            .{ .label = "escaped host 127.0.0.%31", .url = std.fmt.bufPrint(&fb[4], "http://127.0.0.%31:{d}/blk/tf4", .{port}) catch unreachable, .token = "/blk/tf4" },
            .{ .label = "apostrophe in query", .url = std.fmt.bufPrint(&fb[5], "http://127.0.0.1:{d}/blk/tf5?a'b", .{port}) catch unreachable, .token = "/blk/tf5" },
            .{ .label = "leading-zero port", .url = std.fmt.bufPrint(&fb[6], "http://127.0.0.1:0{d}/blk/tf6", .{port}) catch unreachable, .token = "/blk/tf6" },
            .{ .label = "escaped dot segment /%2e/", .url = std.fmt.bufPrint(&fb[7], "http://127.0.0.1:{d}/blk/tf7/%2e/x", .{port}) catch unreachable, .token = "/blk/tf7/x" },
            .{ .label = "pipe in query", .url = std.fmt.bufPrint(&fb[8], "http://127.0.0.1:{d}/blk/tf8?q=a|b", .{port}) catch unreachable, .token = "/blk/tf8" },
            .{ .label = "lowercase escape %7e", .url = std.fmt.bufPrint(&fb[9], "http://127.0.0.1:{d}/blk/tf9%7e", .{port}) catch unreachable, .token = "/blk/tf9" },
            .{ .label = "space + fragment", .url = std.fmt.bufPrint(&fb[10], "http://127.0.0.1:{d}/blk/t f10#x y", .{port}) catch unreachable, .token = "/blk/t%20f10" },
            .{ .label = "trailing-dot host", .url = std.fmt.bufPrint(&fb[11], "http://127.0.0.1.:{d}/blk/tf11", .{port}) catch unreachable, .token = "/blk/tf11" },
            .{ .label = "backslash dot-dot", .url = std.fmt.bufPrint(&fb[12], "http://127.0.0.1:{d}/blk/tf12\\..\\tf12b", .{port}) catch unreachable, .token = "/blk/tf12b" },
            .{ .label = "escaped host letters %31%32%37.0.0.1", .url = std.fmt.bufPrint(&fb[13], "http://%31%32%37.0.0.1:{d}/blk/tf13", .{port}) catch unreachable, .token = "/blk/tf13" },
        };
        var lost: usize = 0;
        for (forms) |f| {
            const c0 = seen(f.token);
            try r.host.send(.{ .navigate = .{ .browser = 7, .url = f.url, .user = true } });
            _ = r.until(Run.loadsAt, 7, r.loads[7] + 1, 5000);
            r.pump(400);
            var e1: [600]u8 = undefined;
            const s = seen(f.token) - c0;
            if (s == 0) lost += 1;
            var lb: [600]u8 = undefined;
            const line = lastSeen(f.token, &lb);
            report(s > 0, "A2-R10-typed-form", std.fmt.bufPrint(&d, "{s} ({s}) → server +{d} · line '{s}' · ends {s}", .{ f.label, f.url, s, std.mem.trim(u8, line, "\n"), endsForA2(&r, f.token, &e1) }) catch "");
            // reset to a neutral page (user — exempt anyway)
            try r.nav(7, uLoop(&u, "/p/sub?t7r"), true);
        }
        // maru 의 주소창은 `scheme://…` 만 보낸다(`app_scheme.resolveNavUrl`) — `http:/…`·`http:…` 꼴은 검증자의 1 판에서 뺐다.
        report(lost == 0, "A2-R10-typed-summary", std.fmt.bufPrint(&d, "forms {d}: lost the exemption (blocked) {d}", .{ forms.len, lost }) catch "");
    }
}

fn endsForA2(r: *Run, needle: []const u8, dd: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(dd);
    for (r.reqs.items) |e| if (std.mem.indexOf(u8, e.url[0..e.url_len], needle) != null) {
        w.print("[{s} ended {} blocked {} rule {d} err {d}] ", .{ e.url[0..@min(e.url_len, 90)], e.ended, e.flags.blocked, e.rule, e.error_code }) catch break;
    };
    return w.buffered();
}

// ── R6: MED-2 fix — a ruled tab that is only "unknown" (lazy iframe) and does not show the origin ────────────────

fn swShared(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a2_sw", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [1400]u8 = undefined;
    var p5: [128]u8 = undefined;
    const broad = [_]msg.NetBlockRule{.{ .id = 41, .site = "localhost", .pattern = "*://*/s/swlate*" }};
    // control phase: ruled tab A' on localhost without unknown frames.
    try r.create(1, uLoop(&u, "/s/page?B"));
    const b_ctl = swReadyA2(&r, 1);
    try r.create(3, uLocal(&u, "/x/blank?Aprime"));
    try r.watch(3);
    const ok3 = try r.block(3, &broad, "");
    {
        const got = r.ev(1, fetchExpr(&x, "/s/swlate-e2c"), &o);
        r.pump(500);
        const h = r.hitOf(3, 41);
        report(starts(got, "ok") and h.sw_not_applied == 0 and h.sw_hits == 0, "A2-R6-control-known-ruled-elsewhere", std.fmt.bufPrint(&d, "B {s} · A' (ruled {}, localhost, no unknown frame) · B fetch /s/swlate-e2c → {s} · A' sw_hits {d} sw_not_applied {d} shared {}", .{ b_ctl, ok3, got, h.sw_hits, h.sw_not_applied, r.shared[3] }) catch "");
    }
    {
        const s0 = seen("/s/swlate?sw=");
        _ = r.ev(1, "(navigator.serviceWorker.controller.postMessage(1),'sent')", &o);
        r.pump(100);
        try r.host.send(.{ .destroy_browser = 1 });
        r.pump(3000);
        const h = r.hitOf(3, 41);
        report(seen("/s/swlate?sw=") == s0 + 1, "A2-R6-control-empty-T", std.fmt.bufPrint(&d, "B closed, SW fetch /s/swlate 1.5 s later with A' known and not on the origin → server +{d} · A' sw_hits {d} (want +1, 0: empty T is not blocked)", .{ seen("/s/swlate?sw=") - s0, h.sw_hits }) catch "");
    }
    try r.host.send(.{ .destroy_browser = 3 });
    r.pump(600);
    // attack phase: ruled tab A on localhost with a lazy offscreen iframe (an empty-URL frame — "unknown").
    try r.create(4, uLoop(&u, "/s/page?B2"));
    const b2_ctl = swReadyA2(&r, 4);
    try r.create(2, uLocal(&u, "/x/lazy"));
    r.pump(500);
    var fo: [200]u8 = undefined;
    const frames = r.ev(2, "String(window.frames.length)+' '+String(window.frames[0]&&window.frames[0].location.href)", &fo);
    try r.watch(2);
    const ok2 = try r.block(2, &broad, "");
    {
        const got = r.ev(4, fetchExpr(&x, "/s/swlate-e2"), &o);
        r.pump(500);
        const h = r.hitOf(2, 41);
        report(h.sw_not_applied == 0 and !r.shared[2], "A2-R6-unknown-ruled-not-showing-counts", std.fmt.bufPrint(&d, "B2 {s} · A (ruled {}, localhost, lazy iframe: frames {s}) does not show 127.0.0.1 · B2 fetch /s/swlate-e2 → {s} · A sw_hits {d} sw_not_applied {d} shared {} (want 0/0/false: A has nothing to do with that origin)", .{ b2_ctl, ok2, frames, got, h.sw_hits, h.sw_not_applied, r.shared[2] }) catch "");
    }
    {
        const s0 = seen("/s/swlate?sw=");
        const h0 = r.hitOf(2, 41);
        _ = r.ev(4, "(navigator.serviceWorker.controller.postMessage(1),'sent')", &o);
        r.pump(100);
        try r.host.send(.{ .destroy_browser = 4 });
        r.pump(3000);
        const h = r.hitOf(2, 41);
        report(seen("/s/swlate?sw=") == s0 + 1, "A2-R6-empty-T-blocked-by-unknown-ruled-tab", std.fmt.bufPrint(&d, "B2 closed, SW fetch /s/swlate 1.5 s later; only A (localhost, lazy iframe, broad rule 41) is open → server +{d} · A sw_hits +{d} (want server +1: no tab shows the origin — empty T is not blocked)", .{ seen("/s/swlate?sw=") - s0, h.sw_hits - h0.sw_hits }) catch "");
    }
    try r.host.send(.{ .destroy_browser = 2 });
    r.pump(600);
    // E3: an unrelated unruled tab Z (other site) with a lazy iframe vetoes the sole ruled tab's SW-path blocking (documented conservative veto).
    {
        try r.create(5, uLoop(&u, "/s/page?A2"));
        const a2 = swReadyA2(&r, 5);
        try r.watch(5);
        _ = try r.block(5, &.{.{ .id = 51, .site = "127.0.0.1", .pattern = pat(&p5, "127.0.0.1", "/s/swblk*") }}, "");
        var o1: [600]u8 = undefined;
        const base = r.ev(5, fetchExpr(&x, "/s/swblk-e3a"), &o1);
        try r.create(6, uLocal(&u, "/x/lazy?Z"));
        r.pump(500);
        var o2: [600]u8 = undefined;
        const with_z = r.ev(5, fetchExpr(&x, "/s/swblk-e3b"), &o2);
        r.pump(400);
        const hz = r.hitOf(5, 51);
        try r.host.send(.{ .destroy_browser = 6 });
        r.pump(600);
        var o3: [600]u8 = undefined;
        const after = r.ev(5, fetchExpr(&x, "/s/swblk-e3c"), &o3);
        r.pump(400);
        // 문서의 보수 규칙(N-A2-4): 그 출처를 보인다고 증명되지 않은 모르는 **규칙 없는** 탭은 거부권 — 막지 않고 「적용 안 됨」 으로 센다, 닫히면 다시 막는다.
        report(starts(base, "reject") and starts(with_z, "ok") and hz.sw_not_applied >= 1 and starts(after, "reject"), "A2-R6-unrelated-unknown-veto", std.fmt.bufPrint(&d, "A2 {s} sole tab on 127.0.0.1 · baseline {s} · with unrelated localhost tab Z holding a lazy iframe: {s} server {d} (sw_not_applied {d} shared {}) · Z closed: {s}", .{ a2, base, with_z, seen("/s/swblk-e3b"), hz.sw_not_applied, r.shared[5], after }) catch "");
        // LOW-A2-2 의 끊김(ERR_ABORTED)은 그 이동의 진행 중 기록도 놓는다: 규칙 없는 탭 Q 가 127.0.0.1 의 204 로 이동했다가 끊겨(localhost 에 남음)도 30 초
        // 동안 그 출처를 「보이는」 탭으로 남아 A2 의 서비스 워커 길 막기를 거부하지 않는다(대조: Q 가 그 출처를 진짜 보이면 거부 — 위 항목).
        try r.create(7, uLocal(&u, "/x/blank?Q"));
        r.pump(300);
        try r.host.send(.{ .navigate = .{ .browser = 7, .url = uLoop(&u, "/n204?q") } });
        r.pump(1500);
        var o4: [600]u8 = undefined;
        const q_at = r.ev(7, "location.host+location.pathname", &o4);
        var o5: [600]u8 = undefined;
        const after_abort = r.ev(5, fetchExpr(&x, "/s/swblk-e3d"), &o5);
        r.pump(400);
        report(std.mem.startsWith(u8, q_at, "localhost") and starts(after_abort, "reject") and seen("/s/swblk-e3d") == 0, "A2-R8-aborted-nav-not-pending", std.fmt.bufPrint(&d, "unruled tab Q navigated to 127.0.0.1/n204 (204 — ERR_ABORTED) and stayed at {s} · A2's SW fetch /s/swblk-e3d 1.5 s later → {s} · server {d} (want blocked: the aborted navigation no longer counts as Q showing 127.0.0.1)", .{ q_at, after_abort, seen("/s/swblk-e3d") }) catch "");
    }
}

// ── R5: scripts a service worker imports ─────────────────────────────────────────────────────────────────

fn swImports(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a2_imp", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [1400]u8 = undefined;
    var p1: [128]u8 = undefined;
    try r.create(1, uLoop(&u, "/i/page"));
    try r.watch(1);
    _ = try r.block(1, &.{.{ .id = 61, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/blk/*") }}, "");
    var o0: [600]u8 = undefined;
    const sanity = r.ev(1, fetchExpr(&x, "/blk/sanity"), &o0);
    const h0 = r.hitOf(1, 61);
    const reg = r.ev(1, "navigator.serviceWorker.register('/i/sw.js',{scope:'/i/'}).then(r=>new Promise(res=>{const w=r.installing||r.waiting||r.active;if(!w)return res('noworker');if(w.state==='activated')return res('activated');w.onstatechange=()=>{if(w.state==='activated'||w.state==='redundant')res(w.state)};setTimeout(()=>res('timeout '+w.state),4000)}),e=>'reject '+e.name+' '+e.message.slice(0,80))", &o);
    r.pump(600);
    const h1 = r.hitOf(1, 61);
    var o2: [600]u8 = undefined;
    const regm = r.ev(1, "navigator.serviceWorker.register('/i/swm.js',{scope:'/i/m/',type:'module'}).then(r=>'registered',e=>'reject '+e.name+' '+e.message.slice(0,80))", &o2);
    r.pump(1500);
    const h2 = r.hitOf(1, 61);
    var e1: [600]u8 = undefined;
    var e2: [600]u8 = undefined;
    // 문서(N-A2-5): 등록 스크립트만 막을 수 없다 — 그것이 가져오는 스크립트는 서비스 워커 길에서 막히고 세어진다(그래서 등록이 실패한다).
    report(seen("/blk/imp1.js") == 0 and seen("/blk/impm.js") == 0 and h2.sw_hits >= 2, "A2-R5-sw-importScripts", std.fmt.bufPrint(&d, "sanity page fetch /blk/sanity {s} (hits {d}) · classic SW importScripts('/blk/imp1.js'): register {s} · server {d} · hits {d}→{d} sw_hits {d} unrecorded {d} · ends {s} · module SW import '/blk/impm.js': {s} · server {d} · hits →{d} sw_hits {d} · ends {s}", .{ sanity, h0.hits, reg, seen("/blk/imp1.js"), h0.hits, h1.hits, h1.sw_hits, r.unrecorded[1], endsForA2(&r, "imp1", &e1), regm, seen("/blk/impm.js"), h2.hits, h2.sw_hits, endsForA2(&r, "impm", &e2) }) catch "");
}

// ── R2/R1: Chromium's own URL parser vs url_canon.hash (D2) and net_block.parse (patterns) ─────────────────────

fn evAlloc(r: *Run, b: u64, expr: []const u8) ?std.json.Parsed(std.json.Value) {
    var aw: std.Io.Writer.Allocating = .init(r.gpa);
    defer aw.deinit();
    aw.writer.writeAll("{\"returnByValue\":true,\"awaitPromise\":true,\"expression\":") catch return null;
    std.json.Stringify.value(expr, .{}, &aw.writer) catch return null;
    aw.writer.writeAll("}") catch return null;
    const st = r.call(b, "Runtime.evaluate", aw.written(), 30_000) catch null;
    if (st == null or st.? != .ok) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, r.gpa, r.result.items, .{}) catch return null;
    defer parsed.deinit();
    const res = parsed.value.object.get("result") orelse return null;
    const v = res.object.get("value") orelse return null;
    if (v != .string) return null;
    return std.json.parseFromSlice(std.json.Value, r.gpa, v.string, .{}) catch null;
}

/// Chromium's canonical href for each input (`!` = invalid).
fn chromiumHrefs(r: *Run, b: u64, inputs: []const []const u8) ?std.json.Parsed(std.json.Value) {
    var aw: std.Io.Writer.Allocating = .init(r.gpa);
    defer aw.deinit();
    aw.writer.writeAll("JSON.stringify(") catch return null;
    std.json.Stringify.value(inputs, .{}, &aw.writer) catch return null;
    aw.writer.writeAll(".map(s=>{try{return new URL(s).href}catch(e){return '!'}}))") catch return null;
    return evAlloc(r, b, aw.written());
}

fn liveCanon(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a2_canon", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [8000]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub"));
    var prng = std.Random.DefaultPrng.init(0xa2a2);
    const rnd = prng.random();

    // (a) typed URLs (D2): url_canon.hash(typed) must equal url_canon.hash(Chromium href).
    {
        const schemes = [_][]const u8{ "http", "HTTP", "https", "HtTpS" };
        const slashes = [_][]const u8{"//"}; // maru's address bar only sends `scheme://…` (app_scheme.resolveNavUrl)
        const hosts = [_][]const u8{ "127.0.0.1", "localhost", "LOCALHOST", "127.1", "0x7f.0.0.1", "2130706433", "a.test", "A.Test.", "[::1]", "[0:0::1]", "[::FFFF:1.2.3.4]", "127.0.0.1.", "xn--bcher-kva.test", "a_b.test", "u:p@a.test", "0177.0.0.01", "127.000.000.001", "a.test:", "a-b.test" };
        const ports = [_][]const u8{ "", "", "", ":80", ":080", ":8080", ":443", ":00443", ":" };
        const pieces = [_][]const u8{ "a", "b", "/", "/", "/", ".", "..", "%2e", "%2E", ".%2e", "\\", "\"", "<", ">", "{", "}", "|", "^", "`", "'", "[", "]", " ", "%zz", "%41", "%7e", "%7E", "~", "!", "$", "&", "(", ")", "*", "+", ",", ";", "=", ":", "@", "%", "%2f", "\xc3\xa9", "\xed\x95\x9c", "%", "%%", "%2", "\x7f" };
        const qpieces = [_][]const u8{ "a", "=", "&", "?", "/", "'", "\"", "<", ">", " ", "`", "{", "}", "|", "^", "%zz", "%41", "\\", "..", "\xc3\xa9", "#", "%2e" };
        const n_total: usize = 20_000;
        const batch: usize = 150;
        var mismatches: usize = 0;
        var invalid: usize = 0;
        var compared: usize = 0;
        var examples: std.Io.Writer = .fixed(&d);
        var shown: usize = 0;
        var store: [150][400]u8 = undefined;
        var done: usize = 0;
        while (done < n_total) : (done += batch) {
            var inputs: [150][]const u8 = undefined;
            for (0..batch) |i| {
                var w: std.Io.Writer = .fixed(&store[i]);
                w.writeAll(schemes[rnd.uintLessThan(usize, schemes.len)]) catch {};
                w.writeAll(":") catch {};
                w.writeAll(slashes[rnd.uintLessThan(usize, slashes.len)]) catch {};
                const h = hosts[rnd.uintLessThan(usize, hosts.len)];
                w.writeAll(h) catch {};
                if (h[h.len - 1] != ':') w.writeAll(ports[rnd.uintLessThan(usize, ports.len)]) catch {};
                if (rnd.uintLessThan(u8, 6) != 0) {
                    w.writeAll(if (rnd.boolean()) "/" else "\\") catch {};
                    const np = rnd.uintLessThan(usize, 9);
                    for (0..np) |_| w.writeAll(pieces[rnd.uintLessThan(usize, pieces.len)]) catch {};
                }
                if (rnd.uintLessThan(u8, 3) == 0) {
                    w.writeAll("?") catch {};
                    const nq = rnd.uintLessThan(usize, 6);
                    for (0..nq) |_| w.writeAll(qpieces[rnd.uintLessThan(usize, qpieces.len)]) catch {};
                }
                if (rnd.uintLessThan(u8, 5) == 0) w.writeAll("#f x") catch {};
                inputs[i] = std.mem.trim(u8, w.buffered(), " \t"); // resolveNavUrl trims spaces and tabs
            }
            const parsed = chromiumHrefs(&r, 1, inputs[0..batch]) orelse {
                report(false, "A2-R2-canon-typed", "chromium eval failed");
                return;
            };
            defer parsed.deinit();
            if (parsed.value != .array or parsed.value.array.items.len != batch) {
                report(false, "A2-R2-canon-typed", "bad eval shape");
                return;
            }
            for (parsed.value.array.items, 0..) |v, i| {
                const href = v.string;
                if (std.mem.eql(u8, href, "!")) {
                    invalid += 1;
                    continue;
                }
                compared += 1;
                const a = url_canon.hash(u8, 1, inputs[i]);
                const g = url_canon.hash(u8, 1, href);
                if (a == null or g == null or a.? != g.?) {
                    mismatches += 1;
                    if (shown < 25) {
                        examples.print("[{s} ⇒ {s}] ", .{ inputs[i], href }) catch {};
                        shown += 1;
                    }
                }
            }
        }
        report(mismatches == 0, "A2-R2-canon-typed", std.fmt.bufPrint(&u, "random typed URLs {d}: Chromium-invalid {d}, compared {d}, url_canon.hash(typed) != url_canon.hash(Chromium href) in {d}", .{ n_total, invalid, compared, mismatches }) catch "");
        report(true, "A2-R2-canon-typed-examples", examples.buffered());
    }

    // (b) pattern paths, exact mode (`*://a.test<P>` — LOW-1: the path must equal P): dead ⇔ Chromium does not keep P as it is.
    {
        const chars = "ab/./%?!$&'()+,;=:@~[]\\\"<>{}|^`-_";
        const n_total: usize = 20_000;
        const batch: usize = 200;
        var false_reject: usize = 0;
        var dead_accept: usize = 0;
        var other_reject: usize = 0;
        var compared: usize = 0;
        var store: [200][40]u8 = undefined;
        var paths: [200][]const u8 = undefined;
        var inputs: [200][]const u8 = undefined;
        var ibuf: [200][64]u8 = undefined;
        var ex: [3000]u8 = undefined;
        var exw: std.Io.Writer = .fixed(&ex);
        var shown: usize = 0;
        var done: usize = 0;
        while (done < n_total) : (done += batch) {
            for (0..batch) |i| {
                var w: std.Io.Writer = .fixed(&store[i]);
                w.writeByte('/') catch {};
                const n = rnd.uintLessThan(usize, 10);
                for (0..n) |_| {
                    const roll = rnd.uintLessThan(u8, 12);
                    if (roll == 0) {
                        w.writeAll("%2E") catch {};
                    } else if (roll == 1) {
                        w.writeAll("%41") catch {};
                    } else if (roll == 2) {
                        w.writeAll("..") catch {};
                    } else w.writeByte(chars[rnd.uintLessThan(usize, chars.len)]) catch {};
                }
                paths[i] = w.buffered();
                inputs[i] = std.fmt.bufPrint(&ibuf[i], "http://a.test{s}", .{paths[i]}) catch unreachable;
            }
            const parsed = chromiumHrefs(&r, 1, inputs[0..batch]) orelse {
                report(false, "A2-R1-dead-path", "chromium eval failed");
                return;
            };
            defer parsed.deinit();
            for (parsed.value.array.items, 0..) |v, i| {
                const href = v.string;
                if (std.mem.eql(u8, href, "!")) continue;
                const canon_path = href["http://a.test".len..];
                var pb: [80]u8 = undefined;
                const pattern = std.fmt.bufPrint(&pb, "*://a.test{s}", .{paths[i]}) catch unreachable;
                const kept = std.mem.eql(u8, canon_path, paths[i]);
                switch (nbp.parse(pattern)) {
                    .ok => {
                        compared += 1;
                        if (!kept) {
                            dead_accept += 1;
                            if (shown < 10) {
                                exw.print("[accepted {s} ⇒ Chromium {s}] ", .{ paths[i], canon_path }) catch {};
                                shown += 1;
                            }
                        }
                    },
                    .err => |why| {
                        if (why != .path) {
                            other_reject += 1;
                            continue;
                        }
                        compared += 1;
                        if (kept) {
                            false_reject += 1;
                            if (shown < 10) {
                                exw.print("[rejected {s} but Chromium keeps it] ", .{paths[i]}) catch {};
                                shown += 1;
                            }
                        }
                    },
                }
            }
        }
        report(false_reject == 0 and dead_accept == 0, "A2-R1-dead-path-exact", std.fmt.bufPrint(&u, "random paths {d}: compared {d}, other rejection {d}, false `.path` rejection {d}, accepted never-matching {d}", .{ n_total, compared, other_reject, false_reject, dead_accept }) catch "");
        report(true, "A2-R1-dead-path-examples", exw.buffered());
    }

    // (c) prefix mode: a trailing dot segment is a useful prefix (`/.well-known`, `/..foo` are canonical paths).
    {
        const Pre = struct { pattern: []const u8, url: []const u8 };
        const pres = [_]Pre{
            .{ .pattern = "https://a.test/.", .url = "https://a.test/.well-known/x" },
            .{ .pattern = "https://a.test/..", .url = "https://a.test/..foo" },
            .{ .pattern = "https://a.test/x/%2E", .url = "https://a.test/x/%2Ehidden" },
        };
        var w: std.Io.Writer = .fixed(&d);
        var bad: usize = 0;
        var urls: [3][]const u8 = undefined;
        for (pres, 0..) |p, i| urls[i] = p.url;
        const parsed = chromiumHrefs(&r, 1, &urls);
        defer if (parsed) |pp| pp.deinit();
        for (pres, 0..) |p, i| {
            const href = if (parsed) |pp| pp.value.array.items[i].string else "?";
            const res = nbp.parse(p.pattern);
            const rejected = res == .err;
            if (rejected and std.mem.eql(u8, href, p.url)) bad += 1;
            w.print("[{s}: {s} · Chromium keeps {s} as {s}] ", .{ p.pattern, if (rejected) @tagName(res.err) else "accepted", p.url, href }) catch {};
        }
        report(bad == 0, "A2-R1-prefix-dot-segment", w.buffered());
    }

    // (d) host forms: pattern acceptance vs Chromium's host.
    {
        const hosts = [_][]const u8{ "a.1", "foo.0x", "a.0xbabe", "1.2.3.4.5", "1.2.3", "0x7f.1", "09.1.1.1", "a!b.test", "a$b.test", "a-.test", "-a.test", "xn--abc", "a_b.test", "a.test.", "0", "0x", "[::1]", "[::ffff:102:304]", "[::ffff:1.2.3.4]", "[1:0:0:0:0:0:0:1]", "[1::1]", "a.b.c.d.e", "1.0x", "a.09", "a.08b", "a.0x1g", "127.0.0.1", "255.255.255.255", "256.1.1.1", "a~b.test", "a+b.test" };
        var inputs: [hosts.len][]const u8 = undefined;
        var ib: [hosts.len][64]u8 = undefined;
        for (hosts, 0..) |h, i| inputs[i] = std.fmt.bufPrint(&ib[i], "http://{s}/x", .{h}) catch unreachable;
        const parsed = chromiumHrefs(&r, 1, &inputs) orelse return;
        defer parsed.deinit();
        var w: std.Io.Writer = .fixed(&d);
        var disagree: usize = 0;
        for (hosts, 0..) |h, i| {
            const href = parsed.value.array.items[i].string;
            var pb: [80]u8 = undefined;
            const pattern = std.fmt.bufPrint(&pb, "http://{s}/x", .{h}) catch unreachable;
            const res = nbp.parse(pattern);
            const chromium_same = !std.mem.eql(u8, href, "!") and blk: {
                // same host as written (lowercase, trailing dot kept by Chromium) ⇒ a pattern for it can match
                var lb: [80]u8 = undefined;
                const lower = std.ascii.lowerString(&lb, pattern);
                break :blk std.mem.eql(u8, href, lower);
            };
            const accepted = res == .ok;
            const mismatch = accepted != chromium_same and !(accepted and std.mem.endsWith(u8, h, "."));
            if (mismatch) disagree += 1;
            w.print("[{s}: pattern {s}{s} · Chromium {s}{s}] ", .{ h, if (accepted) "ok" else @tagName(res.err), if (accepted) "" else "", href, if (mismatch) " ≠" else "" }) catch {};
        }
        report(true, "A2-R1-host-forms(obs)", std.fmt.bufPrint(&u, "{d} host forms, {d} where acceptance ≠ Chromium keeps the host as written", .{ hosts.len, disagree }) catch "");
        report(true, "A2-R1-host-forms-detail", w.buffered());
    }
    // (e) N-A2-2: 패턴이 거절하는 호스트 글자(`!`·`$`·`~`·`+`)를 Chromium 의 URL 파서는 받지만 요청은 나가지 않는다(호스트 이름 검사 — 실측) — 그런
    // 호스트에 맞는 규칙은 막을 요청이 없다. `.localhost` 아래(이름 풀이 없이 127.0.0.1)로 이동·fetch·img 를 보내 서버가 받는지 잰다.
    {
        var w: std.Io.Writer = .fixed(&d);
        var reached: usize = 0;
        for ([_][]const u8{ "a!b", "a$b", "a~b", "a+b" }) |h| {
            var tb: [160]u8 = undefined;
            const target = std.fmt.bufPrint(&tb, "http://{s}.localhost:{d}/hostform/{s}", .{ h, port, h }) catch unreachable;
            var xb: [600]u8 = undefined;
            var ob: [300]u8 = undefined;
            const got = r.ev(1, fetchExpr(&xb, target), &ob);
            var ib: [600]u8 = undefined;
            var ob2: [100]u8 = undefined;
            const img = r.ev(1, imgExpr(&ib, target), &ob2);
            r.pump(300);
            var nb: [64]u8 = undefined;
            const n = seen(std.fmt.bufPrint(&nb, "/hostform/{s}", .{h}) catch unreachable);
            reached += n;
            w.print("[{s}.localhost: fetch {s} · img {s} · server {d}] ", .{ h, got[0..@min(got.len, 40)], img, n }) catch {};
        }
        report(reached == 0, "A2-R1-host-forms-unreachable", w.buffered());
    }
}
