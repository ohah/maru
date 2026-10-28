//! W9d② 서비스 워커 CDP 판정(`--review-body-swcdp`, 고른 항목만 `SWCDP_ONLY=detach-off,…` — docs/plans/web-osr-backend.md 「서비스 워커 갈래
//! 새 설계」). 판정자가 maru 역할로 탭 둘(기록하는 A, 기록하지 않는 B)을 열고 sidecar 를 `MARU_WEB_SW_CDP=1`(워커 세션을 붙인다)로 띄운다.
//!
//! 떼기(공격 2 A1 — 기록이 멈추는 모든 길이 `detachWorkers` 를 탄다): 서비스 워커는 시작할 때마다 `/swd/boot` 를 부른다(서버가 센다). 길마다
//! A 를 기록하며 워커 페이지를 띄우고, 그 길로 기록을 멈춘 뒤 40 초 놀린다(Chromium 의 놀이 시한 30 초 — 실측: 붙은 세션을 떼면 +28 초에
//! stopped). 그 뒤 기록하지 않는 B 가 워커 범위의 문서로 옮긴다 — 워커가 멈췄으면 다시 뜨며 `boot` 가 는다.
//!   swcdp-detach-control   기록을 이어 간다 — 붙은 세션이 워커를 살려 둔다(boot 그대로). 플래그가 듣는지의 대조
//!   swcdp-detach-off       기록 끔(`net_record off`)
//!   swcdp-detach-twice     기록을 두 번 켠다(새 세션 — 떼고 다시 건다) — 살아 있어야 하고(boot 그대로), 그 뒤 끔이면 멈춘다
//!   swcdp-detach-valve     쏟아짐 밸브(`paused`)
//!   swcdp-detach-close     탭 닫힘(`destroy_browser`)
//!   swcdp-detach-crash     렌더러 죽음(`Page.crash`) — host 가 살아 있고(공격 2 A11), 새 문서에서 다시 건다(다시 살려 둔다)
//! 켬 실패·등록 실패의 길은 실제 CEF 에서 낼 수 없어 순수 시험(`net_body_table` 의 `.detach_workers`)이 덮는다.
//!
//! 짝(S3a — W ↔ CEF 기록): host 진단 로그(`MARU_WEB_TEST_BODY_LOG` — `sw-wresp … xs=<워커가 받은 응답의 X-Served>`·`sw-pair … req=<기록>
//! wrid=<워커 요청>`)와 판정자가 받은 그 기록의 응답 머리 `X-Served` 를 견준다(서버 셈이 참값 — 공격 3 M7).
//!   swcdp-pair            그대로 넘김 60 동시(다른 주소)·같은 주소 둘씩 20 판·거꾸로 넘김(앞 요청을 100 ms 늦춤) 20 판·메모 + 갱신·fetch 뒤
//!                         대체 + 페이지도 대체 주소 — 틀린 짝 0, 짝 수
//!   swcdp-pair-scopes     같은 출처 두 범위 SW(페이지 SW1·iframe SW2)가 같은 주소를 0–9 ms 차로 80 번 — 다른 타깃이 섞이면 짝을 맺지 않는다
//!                         (틀린 짝 0)
//!
//! 본문(S4 — 잇기 C0–C7′): 잡은 본문이 그 기록 제 응답 머리의 셈(`X-Body`)과 다르면 「틀린 본문」(공격 3 M7 — 페이지가 받은 것과 견주면 기록을
//! 잘못 골라도 맞아 보인다). 판마다 새 기록 세션.
//!   swcdp-body-pass       그대로 넘김 60 동시(다른 주소)·같은 주소 둘씩 20 판 — 제 본문
//!   swcdp-body-rev        워커가 같은 주소 둘을 거꾸로 넘긴다(앞 요청을 100 ms 늦춤) 20 판 — 제 본문(관 하나 안의 차례)
//!   swcdp-body-k1         메모 복제 + 같은 주소 갱신 fetch(재검증 5 차 K1) 20 판 — 메모의 원본 기록만 제 본문, 갱신 기록은 본문 없이(워커가
//!                         읽지 않은 갱신은 기록 중 끝나지 않는다 — `held`, 다른 꼴에서는 0)
//!   swcdp-body-k2         fetch 뒤 대체 + 페이지도 대체 주소(K2) 20 판 — 대체 fetch·페이지의 대체 주소 기록은 제 본문, 원래 주소의 404 는 없이
//!   swcdp-body-k3         다른 탭의 메모(K3) — 탭 B 의 요청에 탭 A 가 받은 응답으로 답한다 — 틀림 0
//!   swcdp-body-cache      Cache Storage(stale-while-revalidate·만든 응답을 put)·만든 응답(`new Response`) — 그 기록에 본문을 붙이지 않는다
//!   swcdp-body-hb         HTTP 캐시의 같은 항목 HEAD 적중(같은 τ·빈 본문)으로 답하고 바쁜 루프로 W 를 1.5 s 늦춘다(공격 1 H1) — 틀림 0
//!   swcdp-body-scopes     두 범위 SW 가 같은 주소를 함께(공격 3 H1) — 틀림 0

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const net_fields = protocol.net_fields;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const tab_a: u64 = 141;
const tab_b: u64 = 142;
const wait_ms = 15_000;
/// 놀리는 때 — Chromium 의 서비스 워커 놀이 시한(30 초)보다 넉넉히.
const idle_ms: u32 = 40_000;

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

var port: u16 = 0;
var counter = std.atomic.Value(u64).init(1);
var boots = std.atomic.Value(u64).init(0);

fn startServer() !void {
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
        const t = std.Thread.spawn(.{}, serveOne, .{conn}) catch {
            _ = std.c.close(conn);
            continue;
        };
        t.detach();
    }
}

fn writeAll(conn: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(conn, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn reply(conn: c_int, ctype: []const u8, extra: []const u8, body: []const u8) void {
    replyStatus(conn, "200 OK", ctype, extra, body);
}

fn replyStatus(conn: c_int, status: []const u8, ctype: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [1024]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\n{s}Connection: close\r\n\r\n", .{ status, ctype, body.len, extra }) catch return;
    writeAll(conn, head);
    writeAll(conn, body);
}

fn headerValue(req: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitSequence(u8, req, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return "";
}

const html = "text/html; charset=utf-8";

/// 워커: 시작할 때마다 `/swd/boot`, 범위 안 요청은 그대로 넘긴다.
const swd_js = "fetch('/swd/boot?t='+Date.now(),{cache:'no-store'}).catch(function(){});" ++
    "self.addEventListener('install',function(){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
    "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(u.pathname=='/swd/boot')return;e.respondWith(fetch(e.request))});";
const reg_js = "function reg(next){navigator.serviceWorker.register('/swd/sw.js',{scope:'/swd/'}).then(function(){return navigator.serviceWorker.ready}).then(function(){" ++
    "if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}next()})}";

/// 짝 판정의 워커: x-who 로 꼴을 고른다.
const swp_js = "self.addEventListener('install',function(){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
    "var M={};function N(u,w){return fetch(u,{headers:{'x-who':w},cache:'no-store'})}" ++
    "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(u.pathname!='/swp/x')return;var w=e.request.headers.get('x-who')||'';" ++
    "if(w=='rev'){e.respondWith(new Promise(function(r){setTimeout(function(){r(fetch(e.request))},100)}));return}" ++
    "if(w=='m1'){e.respondWith(fetch(e.request).then(function(r){M[u.href]=r.clone();return r}));return}" ++
    "if(w=='m2e'){var c=M[u.href];if(c){N(u.href,'X').catch(function(){});e.respondWith(c.clone());return}}" ++
    "if(w=='f1'){e.respondWith(fetch(e.request).then(function(r){return r.text().then(function(){return N(u.href+'&fb=1','F')})}));return}" ++
    // K3: 메모만으로 답한다(다른 탭이 남긴 것 — 없으면 받는다).
    "if(w=='m2'){var c2=M[u.href];if(c2){e.respondWith(c2.clone());return}}" ++
    // Cache Storage: stale-while-revalidate, 만든 응답을 put 한 뒤 match, 만든 응답.
    "if(w=='swr'){e.respondWith(caches.open('c').then(function(c){return c.match(u.href).then(function(hit){var p=N(u.href,'R').then(function(r){c.put(u.href,r.clone());return r});return hit||p})}));return}" ++
    "if(w=='csput'){e.respondWith(caches.open('c').then(function(c){return c.put(u.href,new Response('{\"n\":\"forged\"}',{headers:{'content-type':'application/json'}})).then(function(){return c.match(u.href)})}));return}" ++
    "if(w=='syn'){e.respondWith(N(u.href,'SN').then(function(r){return r.text().then(function(t){return new Response(t,{status:r.status,headers:r.headers})})}));return}" ++
    // 공격 1 H1: 같은 HTTP 캐시 항목의 HEAD 적중(빈 본문, 같은 τ)으로 답하고 바쁜 루프로 W 를 늦춘다.
    "if(w=='hb'){var cu=u.href.replace('/swp/x','/swp/c');e.respondWith(fetch(cu,{cache:'default',headers:{'x-who':'HB0'}}).then(function(r){return r.text()}).then(function(){return fetch(cu,{cache:'default',headers:{'x-who':'HB1'}})}).then(function(r){return r.text()}).then(function(){return fetch(cu,{method:'HEAD',cache:'default',headers:{'x-who':'HBH'}})}).then(function(r){var t0=Date.now();while(Date.now()-t0<1500){}return r}));return}" ++
    "e.respondWith(fetch(e.request))});";
/// 둘째 범위(`/swp/q/`)의 워커 — 같은 주소(`/swp/x`)를 제 이름으로 받는다.
const swq_js = "self.addEventListener('install',function(){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
    "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(u.pathname=='/swp/q/go'){var r=u.searchParams.get('r');e.respondWith(fetch('/swp/x?k=same&r='+r,{headers:{'x-who':'S2'},cache:'no-store'}));return}});";
const swp_page_js = "function W(u,w){return fetch(u,{headers:{'x-who':w},cache:'no-store'}).then(function(r){return r.text()}).catch(function(){})}" ++
    "function S(ms){return new Promise(function(r){setTimeout(r,ms)})}" ++
    "function reg(s,sc){return navigator.serviceWorker.register(s,{scope:sc}).then(function(){return navigator.serviceWorker.ready})}";

fn serveOne(conn: c_int) void {
    defer _ = std.c.close(conn);
    var buf: [8192]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = std.c.read(conn, buf[got..].ptr, buf.len - got);
        if (n <= 0) return;
        got += @intCast(n);
        if (std.mem.indexOf(u8, buf[0..got], "\r\n\r\n") != null) break;
    }
    const req = buf[0..got];
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return;
    var parts = std.mem.splitScalar(u8, req[0..line_end], ' ');
    _ = parts.next();
    const target = parts.next() orelse return;
    const qi = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..qi];
    if (std.mem.eql(u8, path, "/blank")) return reply(conn, html, "", "<!doctype html><title>blank</title>blank");
    if (std.mem.eql(u8, path, "/swd/sw.js")) return reply(conn, "text/javascript", "", swd_js);
    if (std.mem.eql(u8, path, "/swd/boot")) {
        _ = boots.fetchAdd(1, .monotonic);
        return reply(conn, "text/plain", "", "boot");
    }
    // A: 워커를 깔고(다스릴 때까지 다시 불러온다) 범위 안 데이터를 한 번 받는다.
    if (std.mem.eql(u8, path, "/swd/p")) return reply(conn, html, "", "<!doctype html><title>p</title><script>" ++ reg_js ++
        "reg(function(){fetch('/swd/x?k=p',{cache:'no-store'}).then(function(r){return r.text()}).then(function(){document.title='ready'})})</script>p");
    // B: 범위 안의 문서 — 워커가 멈췄으면 이 이동이 다시 띄운다.
    if (std.mem.eql(u8, path, "/swd/probe")) return reply(conn, html, "", "<!doctype html><title>probed</title>probe");
    // 쏟아짐 밸브(v20a r9 와 같다): data: fetch 를 5 초 동안 쉬지 않고 — 워커를 거치지 않는다.
    if (std.mem.eql(u8, path, "/swd/flood")) return reply(conn, html, "", "<!doctype html><title>fl</title><script>" ++
        "var t0=performance.now();var n=0;function burst(){for(var i=0;i<400;i++){fetch('data:application/json,'+(n++)).then(function(r){return r.text()}).catch(function(){})}" ++
        "if(performance.now()-t0<5000)setTimeout(burst,0);else document.title='fldone'}setTimeout(burst,200)</script>fl");
    if (std.mem.eql(u8, path, "/swp/sw.js")) return reply(conn, "text/javascript", "", swp_js);
    if (std.mem.eql(u8, path, "/swp/q/sw2.js")) return reply(conn, "text/javascript", "", swq_js);
    if (std.mem.eql(u8, path, "/swp/p")) return reply(conn, html, "", "<!doctype html><title>p</title><script>" ++ swp_page_js ++
        "reg('/swp/sw.js','/swp/').then(async function(){if(!navigator.serviceWorker.controller){location.reload();return}" ++
        "var B=[];for(var i=0;i<60;i++)B.push(W('/swp/x?k=b'+i,'pt'));await Promise.all(B);" ++
        "for(var j=0;j<20;j++){await Promise.all([W('/swp/x?k=d'+j,'pt'),W('/swp/x?k=d'+j,'pt')]);await S(30)}" ++
        "for(var j=0;j<20;j++){await Promise.all([W('/swp/x?k=r'+j,'rev'),S(20).then(function(){return W('/swp/x?k=r'+j,'pt')})]);await S(30)}" ++
        "for(var j=0;j<10;j++){await W('/swp/x?k=m'+j,'m1');await S(100);await W('/swp/x?k=m'+j,'m2e');await S(50)}" ++
        "for(var j=0;j<10;j++){await Promise.all([W('/swp/x?k=f'+j,'f1'),W('/swp/x?k=f'+j+'&fb=1','pt')]);await S(30)}" ++
        "await S(1500);document.title='pdone'})</script>p");
    // 두 범위: 페이지는 SW1(`/swp/`)이, iframe 은 SW2(`/swp/q/`)가 다스린다 — 같은 주소를 거의 함께.
    if (std.mem.eql(u8, path, "/swp/o")) return reply(conn, html, "", "<!doctype html><title>o</title><script>" ++ swp_page_js ++
        "reg('/swp/sw.js','/swp/').then(function(){return reg('/swp/q/sw2.js','/swp/q/')}).then(async function(){if(!navigator.serviceWorker.controller){location.reload();return}" ++
        "var f=document.createElement('iframe');await new Promise(function(res){f.onload=res;f.src='/swp/q/i';document.body.appendChild(f)});await S(500);" ++
        "for(var r=0;r<80;r++){var g=Math.floor(Math.random()*10);await Promise.all([W('/swp/x?k=same&r='+r,'pt'),S(g).then(function(rr){return function(){return f.contentWindow.fetch('/swp/q/go?r='+rr,{cache:'no-store'}).then(function(x){return x.text()}).catch(function(){})}}(r))]);await S(20)}" ++
        "await S(1500);document.title='odone'})</script>o");
    if (std.mem.eql(u8, path, "/swp/q/i")) return reply(conn, html, "", "<!doctype html><title>i</title>i");
    // 본문 꼴(S4): `/swp/b?c=<꼴>&k=<판 열쇠>`.
    if (std.mem.eql(u8, path, "/swp/b")) return reply(conn, html, "", "<!doctype html><title>b</title><script>" ++ swp_page_js ++
        "var P=new URLSearchParams(location.search);var C=P.get('c');var K=P.get('k');" ++
        "reg('/swp/sw.js','/swp/').then(async function(){if(!navigator.serviceWorker.controller){location.reload();return}" ++
        "if(C=='pass'){var B=[];for(var i=0;i<60;i++)B.push(W('/swp/x?k='+K+'b'+i,'pt'));await Promise.all(B);for(var j=0;j<20;j++){await Promise.all([W('/swp/x?k='+K+'d'+j,'pt'),W('/swp/x?k='+K+'d'+j,'pt')]);await S(30)}}" ++
        "if(C=='rev'){for(var j=0;j<20;j++){await Promise.all([W('/swp/x?k='+K+'r'+j,'rev'),S(20).then(function(){return W('/swp/x?k='+K+'r'+j,'pt')})]);await S(30)}}" ++
        "if(C=='k1'){for(var j=0;j<20;j++){await W('/swp/x?k='+K+'m'+j,'m1');await S(150);await W('/swp/x?k='+K+'m'+j,'m2e');await S(100)}}" ++
        "if(C=='k2'){for(var j=0;j<20;j++){await Promise.all([W('/swp/x?k='+K+'f'+j+'&nf=1','f1'),W('/swp/x?k='+K+'f'+j+'&nf=1&fb=1','pt')]);await S(50)}}" ++
        "if(C=='k3a'){for(var j=0;j<10;j++){await W('/swp/x?k='+K+'s'+j,'m1')}}" ++
        "if(C=='k3b'){for(var j=0;j<10;j++){await W('/swp/x?k='+K+'s'+j,'m2')}}" ++
        "if(C=='cache'){for(var j=0;j<10;j++){await W('/swp/x?k='+K+'w'+j,'swr');await S(100);await W('/swp/x?k='+K+'w'+j,'swr');await W('/swp/x?k='+K+'p'+j,'csput');await W('/swp/x?k='+K+'y'+j,'syn')}}" ++
        "if(C=='hb'){for(var j=0;j<5;j++){await W('/swp/x?k='+K+'h'+j,'hb');await S(100)}}" ++
        "await S(1500);document.title='bdone'})</script>b");
    if (std.mem.eql(u8, path, "/swp/x") or std.mem.eql(u8, path, "/swd/x")) {
        const n = counter.fetchAdd(1, .monotonic);
        var bb: [64]u8 = undefined;
        var eb: [160]u8 = undefined;
        const who = headerValue(req, "x-who");
        const status = if (std.mem.indexOf(u8, target, "nf=1") != null and std.mem.indexOf(u8, target, "fb=1") == null) "404 Not Found" else "200 OK";
        return replyStatus(conn, status, "application/json", std.fmt.bufPrint(&eb, "X-Served: {d}\r\nX-Body: {d}\r\nX-Who: {s}\r\n", .{ n, n, who }) catch "", std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{n}) catch "");
    }
    // HTTP 캐시에 남는 응답(HEAD 도 받는다 — 공격 1 H1).
    if (std.mem.eql(u8, path, "/swp/c")) {
        const n = counter.fetchAdd(1, .monotonic);
        var bb: [64]u8 = undefined;
        var eb: [200]u8 = undefined;
        const head = std.mem.startsWith(u8, req, "HEAD ");
        const body_s = std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{n}) catch "";
        const extra = std.fmt.bufPrint(&eb, "Cache-Control: max-age=600\r\nX-Served: {d}\r\nX-Body: {d}\r\nX-Who: {s}\r\n", .{ n, n, headerValue(req, "x-who") }) catch "";
        var hb: [512]u8 = undefined;
        writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n{s}Connection: close\r\n\r\n", .{ body_s.len, extra }) catch return);
        if (!head) writeAll(conn, body_s);
        return;
    }
    return reply(conn, "text/plain", "", "?");
}

// ── 모으기 ────────────────────────────────────────────────────────────────────────────────────────────────

const Begin = struct { browser: u64, request: u64, url: []u8, expected: bool, sw: bool };
const Body = struct { browser: u64, request: u64, data: std.ArrayList(u8) = .empty, ends: usize = 0, state: msg.NetBodyState = .unavailable, xbody: []u8 = &.{}, xwho: []u8 = &.{}, cef_end: bool = false };

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    created: std.AutoHashMapUnmanaged(u64, void) = .empty,
    loads: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    states: std.AutoHashMapUnmanaged(u64, msg.NetRecordStatus) = .empty,
    state_log: std.ArrayList(struct { browser: u64, session: u32, status: msg.NetRecordStatus }) = .empty,
    titles: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    gone: std.AutoHashMapUnmanaged(u64, void) = .empty,
    closed: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// 기록 번호 → 그 응답의 X-Served(서버 셈 — 짝의 참값).
    served: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// 기록 번호 → 서비스 워커 갈래인가.
    sw_begin: std.AutoHashMapUnmanaged(u64, void) = .empty,
    begins: std.ArrayList(Begin) = .empty,
    bodies: std.ArrayList(Body) = .empty,

    fn body(self: *Run, browser: u64, request: u64) *Body {
        var i = self.bodies.items.len;
        while (i > 0) {
            i -= 1;
            const b = &self.bodies.items[i];
            if (b.request == request and b.browser == browser) return b;
        }
        self.bodies.append(self.gpa, .{ .browser = browser, .request = request }) catch unreachable;
        return &self.bodies.items[self.bodies.items.len - 1];
    }

    fn take(self: *Run, m: msg.Message) void {
        switch (m) {
            .net_begin => |v| {
                if (v.flags.service_worker) self.sw_begin.put(self.gpa, v.request, {}) catch {};
                self.begins.append(self.gpa, .{ .browser = v.browser, .request = v.request, .url = self.gpa.dupe(u8, v.url) catch &.{}, .expected = v.flags2.body_expected, .sw = v.flags.service_worker }) catch {};
            },
            .net_response => |v| {
                const b = self.body(v.browser, v.request);
                var it = net_fields.HeaderIterator.init(v.headers);
                while (it.next()) |hh| {
                    if (std.ascii.eqlIgnoreCase(hh.name, "x-served")) {
                        const n = std.fmt.parseInt(u64, hh.value, 10) catch continue;
                        self.served.put(self.gpa, v.request, n) catch {};
                    }
                    if (std.ascii.eqlIgnoreCase(hh.name, "x-body")) b.xbody = self.gpa.dupe(u8, hh.value) catch &.{};
                    if (std.ascii.eqlIgnoreCase(hh.name, "x-who")) b.xwho = self.gpa.dupe(u8, hh.value) catch &.{};
                }
            },
            .net_end => |v| self.body(v.browser, v.request).cef_end = true,
            .net_body_data => |v| {
                const b = self.body(v.browser, v.request);
                if (v.offset == b.data.items.len) b.data.appendSlice(self.gpa, v.bytes) catch {};
            },
            .net_body_end => |v| {
                const b = self.body(v.browser, v.request);
                b.ends += 1;
                b.state = v.state;
            },
            .net_record_state => |v| {
                self.states.put(self.gpa, v.browser, v.status) catch {};
                self.state_log.append(self.gpa, .{ .browser = v.browser, .session = v.session, .status = v.status }) catch {};
            },
            .browser_created => |id| self.created.put(self.gpa, id, {}) catch {},
            .browser_closed => |id| self.closed.put(self.gpa, id, {}) catch {},
            .renderer_gone => |v| self.gone.put(self.gpa, v.browser, {}) catch {},
            .load_finished => |v| {
                const g = self.loads.getOrPut(self.gpa, v.browser) catch return;
                if (!g.found_existing) g.value_ptr.* = 0;
                g.value_ptr.* += 1;
            },
            .title_changed => |v| self.titles.put(self.gpa, v.browser, self.gpa.dupe(u8, v.text) catch &.{}) catch {},
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

    fn pumpTitle(self: *Run, browser: u64, title: []const u8, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (self.titles.get(browser)) |t| if (std.mem.eql(u8, t, title)) return true;
            const m = (self.host.next(20) catch null) orelse continue;
            self.take(m);
        }
        return false;
    }

    fn waitFor(self: *Run, ms: u32, ctx: anytype, cond: fn (*Run, @TypeOf(ctx)) bool) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline and !cond(self, ctx)) {
            const m = (self.host.next(50) catch null) orelse continue;
            self.take(m);
        }
        return cond(self, ctx);
    }

    fn navigate(self: *Run, browser: u64, path: []const u8) !void {
        _ = self.titles.remove(browser);
        var u: [512]u8 = undefined;
        try self.host.send(.{ .navigate = .{ .browser = browser, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}{s}", .{ port, path }) } });
    }
};

fn createdAndLoaded(r: *Run, id: u64) bool {
    return r.created.contains(id) and (r.loads.get(id) orelse 0) >= 1;
}

const Want = struct { id: u64, status: msg.NetRecordStatus };
fn stateIs(r: *Run, want: Want) bool {
    const s = r.states.get(want.id) orelse return false;
    return s == want.status;
}

fn enabled(name: []const u8) bool {
    const only = std.c.getenv("SWCDP_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(only), name) != null;
}

fn openTab(r: *Run, id: u64) !void {
    var u: [256]u8 = undefined;
    const size: msg.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
    _ = r.created.remove(id);
    _ = r.loads.remove(id);
    _ = r.closed.remove(id);
    try r.host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/blank", .{port}) } });
    if (!r.waitFor(wait_ms, id, createdAndLoaded)) return error.BrowserNotCreated;
    try r.host.send(.{ .net_watch = .{ .browser = id, .on = true, .full = true, .any_host = true } });
}

fn recordOn(r: *Run, id: u64, session: u32) bool {
    _ = r.states.remove(id);
    r.host.send(.{ .net_record = .{ .browser = id, .on = true, .session = session } }) catch return false;
    return r.waitFor(5000, Want{ .id = id, .status = .on }, stateIs);
}

/// A 를 기록하며 워커 페이지를 띄운다(워커가 다스릴 때까지) — 붙을 틈을 준다.
fn armA(r: *Run, session: u32) !bool {
    const on = recordOn(r, tab_a, session);
    try r.navigate(tab_a, "/swd/p");
    const ready = r.pumpTitle(tab_a, "ready", 20_000);
    r.pump(1500);
    return on and ready;
}

/// 놀린 뒤 B 가 범위 안으로 옮긴다 — 그동안 워커가 다시 떴으면(boot 가 늘었으면) 멈췄던 것이다.
const Idle = struct { stopped: bool, probed: bool, boots_before: u64, boots_after: u64 };
fn idleThenProbe(r: *Run) !Idle {
    const before = boots.load(.monotonic);
    r.pump(idle_ms);
    try r.navigate(tab_b, "/swd/probe");
    const probed = r.pumpTitle(tab_b, "probed", 15_000);
    r.pump(1500);
    const after = boots.load(.monotonic);
    try r.navigate(tab_b, "/blank");
    r.pump(500);
    return .{ .stopped = after > before, .probed = probed, .boots_before = before, .boots_after = after };
}

fn idleLine(x: Idle, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "worker {s} after {d} s idle (boots {d} → {d}, probe {})", .{ if (x.stopped) "stopped" else "kept running", idle_ms / 1000, x.boots_before, x.boots_after, x.probed }) catch "";
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    try startServer();
    var detail: [2000]u8 = undefined;
    var lb: [400]u8 = undefined;
    var env_buf: [4][*:0]const u8 = undefined;
    var env_n: usize = 0;
    // 워커 세션을 붙이는 판정이다 — 플래그를 늘 준다(`SWCDP_FLAG=0` 이면 끈 대조).
    const flag_off = if (std.c.getenv("SWCDP_FLAG")) |v| std.mem.eql(u8, std.mem.span(v), "0") else false;
    env_buf[env_n] = if (flag_off) "MARU_WEB_SW_CDP=0" else "MARU_WEB_SW_CDP=1";
    env_n += 1;
    env_buf[env_n] = "MARU_WEB_TEST_BODY_LOG=1";
    env_n += 1;
    var sp_buf: [1100]u8 = undefined;
    const stderr_path: ?[:0]const u8 = if (std.c.getenv("SWCDP_HOST_STDERR")) |p| std.mem.span(p) else blk: {
        const eq = std.mem.indexOfScalar(u8, profile_arg, '=') orelse break :blk null;
        break :blk std.fmt.bufPrintSentinel(&sp_buf, "{s}_host.log", .{profile_arg[eq + 1 ..]}, 0) catch null;
    };
    var host = try Host.spawnWith(host_path, profile_arg, stderr_path, env_buf[0..env_n]);
    var host_alive = true;
    defer if (host_alive) {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    };
    try browsers_check.handshake(&host);
    var r: Run = .{ .host = &host, .gpa = gpa };
    try openTab(&r, tab_a);
    try openTab(&r, tab_b);
    var session: u32 = 10;

    if (enabled("pair")) {
        inline for (.{ .{ "pair", "/swp/p", "pdone" }, .{ "pair-scopes", "/swp/o", "odone" } }) |c| if (enabled(c[0])) {
            session += 1;
            const on = recordOn(&r, tab_a, session);
            const log_at = logSize(stderr_path);
            try r.navigate(tab_a, c[1]);
            const done = r.pumpTitle(tab_a, c[2], 120_000);
            r.pump(3000);
            const p = pairCheck(&r, gpa, stderr_path, log_at);
            report(on and done and p.log_ok and p.wrong == 0 and p.pairs > 0, "swcdp-" ++ c[0], std.fmt.bufPrint(&detail, "{s}: pairs {d} · correct {d} · WRONG {d} · W without X-Served {d} · record without X-Served {d} · service-worker records {d}{s}", .{ if (done) "done" else "NOT DONE", p.pairs, p.correct, p.wrong, p.no_w, p.no_rec, r.sw_begin.count(), if (p.log_ok) "" else " · NO HOST LOG (set SWCDP_HOST_STDERR and MARU_WEB_TEST_BODY_LOG=1)" }) catch "");
            try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
            r.pump(500);
            try r.navigate(tab_a, "/blank");
            r.pump(500);
        };
    }
    inline for (.{ "pass", "rev", "k1", "k2", "cache", "hb" }) |c| if (enabled("body-" ++ c)) {
        session += 1;
        const on = recordOn(&r, tab_a, session);
        const at = r.begins.items.len;
        var pb: [96]u8 = undefined;
        try r.navigate(tab_a, std.fmt.bufPrint(&pb, "/swp/b?c={s}&k=s{d}", .{ c, session }) catch "");
        const done = r.pumpTitle(tab_a, "bdone", 180_000);
        r.pump(4000);
        const t = tally(&r, tab_a, at);
        var lb2: [600]u8 = undefined;
        const ok = on and done and t.wrong == 0 and t.no_end == 0 and t.multi_end == 0 and switch (comptime c[0]) {
            // 그대로 넘김·거꾸로 넘김·K1·K2 는 잡는다(잃는 양의 회귀를 막는 아래 끝).
            'p' => t.sw_own >= 90,
            'r' => t.sw_own >= 30,
            'k' => if (comptime std.mem.eql(u8, c, "k1")) t.sw_own >= 15 else t.sw_own >= 30,
            else => true,
        } and (if (comptime std.mem.eql(u8, c, "cache")) t.forged == 0 else true) and
            // K1 의 갱신 fetch(20)만 워커가 쥔다 — 그 밖의 꼴에서 쥔 것이 있으면 판정이 끝을 놓쳤다.
            (if (comptime std.mem.eql(u8, c, "k1")) t.held <= 20 else t.held == 0);
        report(ok, "swcdp-body-" ++ c, bodyLine(&t, done, &lb2));
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        try r.navigate(tab_a, "/blank");
        r.pump(500);
    };
    if (enabled("body-k3")) {
        // 두 탭이 같은 출처를 기록한다 — A 가 받고(메모), B 의 요청에 그 메모로 답한다.
        session += 1;
        const on_a = recordOn(&r, tab_a, session);
        session += 1;
        const on_b = recordOn(&r, tab_b, session);
        const at = r.begins.items.len;
        try r.navigate(tab_a, "/swp/b?c=k3a&k=k3");
        const da = r.pumpTitle(tab_a, "bdone", 60_000);
        try r.navigate(tab_b, "/swp/b?c=k3b&k=k3");
        const db = r.pumpTitle(tab_b, "bdone", 60_000);
        r.pump(4000);
        const ta = tally(&r, tab_a, at);
        const tb = tally(&r, tab_b, at);
        var la: [600]u8 = undefined;
        var lbb: [600]u8 = undefined;
        report(on_a and on_b and da and db and ta.wrong == 0 and tb.wrong == 0 and ta.no_end == 0 and tb.no_end == 0 and ta.held == 0 and tb.held == 0, "swcdp-body-k3", std.fmt.bufPrint(&detail, "tab A: {s} || tab B: {s}", .{ bodyLine(&ta, da, &la), bodyLine(&tb, db, &lbb) }) catch "");
        for ([_]u64{ tab_a, tab_b }) |b| try r.host.send(.{ .net_record = .{ .browser = b, .on = false, .session = 0 } });
        r.pump(500);
        try r.navigate(tab_a, "/blank");
        try r.navigate(tab_b, "/blank");
        r.pump(500);
    }
    if (enabled("body-scopes")) {
        session += 1;
        const on = recordOn(&r, tab_a, session);
        const at = r.begins.items.len;
        try r.navigate(tab_a, "/swp/o");
        const done = r.pumpTitle(tab_a, "odone", 120_000);
        r.pump(4000);
        const t = tally(&r, tab_a, at);
        var lb2: [600]u8 = undefined;
        report(on and done and t.wrong == 0 and t.no_end == 0 and t.held == 0, "swcdp-body-scopes", bodyLine(&t, done, &lb2));
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        try r.navigate(tab_a, "/blank");
        r.pump(500);
    }
    if (enabled("detach-control")) {
        session += 1;
        const armed = try armA(&r, session);
        const x = try idleThenProbe(&r);
        report(armed and x.probed and x.stopped == flag_off, "swcdp-detach-control", std.fmt.bufPrint(&detail, "recording on (flag {s}): {s}", .{ if (flag_off) "off" else "on", idleLine(x, &lb) }) catch "");
    }
    if (enabled("detach-off")) {
        session += 1;
        const armed = try armA(&r, session);
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        const x = try idleThenProbe(&r);
        report(armed and x.probed and x.stopped, "swcdp-detach-off", std.fmt.bufPrint(&detail, "net_record off: {s}", .{idleLine(x, &lb)}) catch "");
    }
    if (enabled("detach-twice")) {
        session += 1;
        const armed = try armA(&r, session);
        session += 1;
        const again = recordOn(&r, tab_a, session); // 켠 채 다시 켬 — 새 세션(떼고 다시 건다)
        r.pump(1500);
        // 워커를 한 번 깨워 다시 붙은 세션이 놀이 시한을 처음부터 세게 한다.
        try r.navigate(tab_a, "/swd/p?again");
        const ready = r.pumpTitle(tab_a, "ready", 20_000);
        r.pump(1500);
        const x = try idleThenProbe(&r);
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        const y = try idleThenProbe(&r);
        var lb2: [400]u8 = undefined;
        report(armed and again and ready and x.probed and x.stopped == flag_off and y.stopped, "swcdp-detach-twice", std.fmt.bufPrint(&detail, "on twice: {s} · then off: {s}", .{ idleLine(x, &lb), idleLine(y, &lb2) }) catch "");
    }
    if (enabled("detach-valve")) {
        session += 1;
        const armed = try armA(&r, session);
        const log_at = r.state_log.items.len;
        try r.navigate(tab_a, "/swd/flood");
        _ = r.pumpTitle(tab_a, "fldone", 20_000);
        r.pump(1000);
        var paused = false;
        for (r.state_log.items[log_at..]) |s| if (s.browser == tab_a and s.status == .paused) {
            paused = true;
        };
        const x = try idleThenProbe(&r);
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        report(armed and paused and x.probed and x.stopped, "swcdp-detach-valve", std.fmt.bufPrint(&detail, "paused {} · {s}", .{ paused, idleLine(x, &lb) }) catch "");
    }
    if (enabled("detach-crash")) {
        session += 1;
        const armed = try armA(&r, session);
        _ = r.gone.remove(tab_a);
        try r.host.send(.{ .devtools_call = .{ .browser = tab_a, .call = 901, .method = "Page.crash", .params_size = 0 } });
        const Gone = struct {
            fn got(x: *Run, id: u64) bool {
                return x.gone.contains(id);
            }
        };
        const gone = r.waitFor(5000, tab_a, Gone.got);
        const x = try idleThenProbe(&r);
        // host 가 살아 있다(공격 2 A11 — 죽은 렌더러에 Target 명령): B 가 옮겼으면 산 것이다. A 를 다시 띄우면(새 렌더러·새 문서) 다시 건다 —
        // 기록은 이어진다(J5).
        try r.navigate(tab_a, "/swd/p?after");
        const ready = r.pumpTitle(tab_a, "ready", 20_000);
        r.pump(1500);
        const y = try idleThenProbe(&r);
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        var lb2: [400]u8 = undefined;
        report(armed and gone and x.probed and x.stopped and ready and y.probed and y.stopped == flag_off, "swcdp-detach-crash", std.fmt.bufPrint(&detail, "renderer_gone {} · after crash: {s} · host alive (probe) · reloaded {} · re-armed: {s}", .{ gone, idleLine(x, &lb), ready, idleLine(y, &lb2) }) catch "");
    }
    if (enabled("detach-close")) {
        session += 1;
        const armed = try armA(&r, session);
        try r.host.send(.{ .destroy_browser = tab_a });
        const Closed = struct {
            fn got(x: *Run, id: u64) bool {
                return x.closed.contains(id);
            }
        };
        const closed = r.waitFor(5000, tab_a, Closed.got);
        const x = try idleThenProbe(&r);
        report(armed and closed and x.probed and x.stopped, "swcdp-detach-close", std.fmt.bufPrint(&detail, "closed {} · {s}", .{ closed, idleLine(x, &lb) }) catch "");
        try openTab(&r, tab_a);
    }
    host.send(.shutdown) catch {};
    host_alive = false;
    _ = host.wait(wait_ms);
}

fn logSize(path: ?[:0]const u8) usize {
    const p = path orelse return 0;
    const fd = std.c.open(p, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    return if (end < 0) 0 else @intCast(end);
}

const PairResult = struct { log_ok: bool = false, pairs: usize = 0, correct: usize = 0, wrong: usize = 0, no_w: usize = 0, no_rec: usize = 0 };

fn field(line: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const rest = line[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return rest[0..end];
}

/// host 로그의 `log_at` 뒤에서 짝 줄을 읽어 참값(기록의 X-Served == 그 W 가 받은 응답의 X-Served)과 견준다.
fn pairCheck(r: *Run, gpa: std.mem.Allocator, path: ?[:0]const u8, log_at: usize) PairResult {
    var res: PairResult = .{};
    const p = path orelse return res;
    const fd = std.c.open(p, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return res;
    defer _ = std.c.close(fd);
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(gpa);
    var buf: [65536]u8 = undefined;
    _ = std.c.lseek(fd, @intCast(log_at), std.c.SEEK.SET);
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        all.appendSlice(gpa, buf[0..@intCast(n)]) catch break;
    }
    res.log_ok = std.mem.indexOf(u8, all.items, "sw-") != null;
    // 워커 요청(표 이름 `w<타깃>:<rid>`) → X-Served.
    var wxs: std.StringHashMapUnmanaged(u64) = .empty;
    defer wxs.deinit(gpa);
    var it = std.mem.splitScalar(u8, all.items, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "sw-wresp ") == null) continue;
        const t = field(line, " t=") orelse continue;
        const rid = field(line, " rid=") orelse continue;
        const xs = field(line, " xs=") orelse continue;
        const n = std.fmt.parseInt(u64, xs, 10) catch continue;
        // 표 이름과 같은 꼴로(`w<타깃의 아래 32 비트>:<rid>` — 타깃은 epoch 를 더하지 않은 첫 판으로 본다).
        const tv = std.fmt.parseInt(u64, t, 16) catch continue;
        var kb: [96]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "w{x}:{s}", .{ @as(u32, @truncate(tv)), rid }) catch continue;
        wxs.put(gpa, gpa.dupe(u8, key) catch continue, n) catch {};
    }
    var it2 = std.mem.splitScalar(u8, all.items, '\n');
    while (it2.next()) |line| {
        if (std.mem.indexOf(u8, line, "sw-pair ") == null) continue;
        const req_s = field(line, " req=") orelse continue;
        const wrid = field(line, " wrid=") orelse continue;
        const req = std.fmt.parseInt(u64, req_s, 10) catch continue;
        res.pairs += 1;
        const w = wxs.get(wrid) orelse {
            res.no_w += 1;
            continue;
        };
        const rec = r.served.get(req) orelse {
            res.no_rec += 1;
            continue;
        };
        if (w == rec) res.correct += 1 else res.wrong += 1;
    }
    var kit = wxs.keyIterator();
    while (kit.next()) |k| gpa.free(k.*);
    return res;
}

const Tally = struct { total: usize = 0, sw: usize = 0, sw_own: usize = 0, page_own: usize = 0, wrong: usize = 0, forged: usize = 0, no_end: usize = 0, held: usize = 0, multi_end: usize = 0, states: [16]usize = @splat(0), notes: [600]u8 = undefined, notes_len: usize = 0 };

/// `at` 부터 그 탭의 `/swp/x`·`/swp/c` 기록 — 잡은 본문이 그 기록 제 응답의 셈(X-Body)과 다르면 틀린 본문.
fn tally(r: *Run, browser: u64, at: usize) Tally {
    var t: Tally = .{};
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(r.gpa);
    for (r.begins.items[at..]) |b| if (b.browser == browser and (std.mem.indexOf(u8, b.url, "/swp/x") != null or std.mem.indexOf(u8, b.url, "/swp/c") != null)) {
        if (seen.contains(b.request)) continue;
        seen.put(r.gpa, b.request, {}) catch {};
        const x = r.body(browser, b.request);
        t.total += 1;
        if (b.sw) t.sw += 1;
        // 워커가 받은 응답을 읽지 않고 쥔 fetch(K1 의 갱신)는 기록하는 동안 끝나지 않는다 — CEF 가 끝내지 않았으면 본문의 끝도 없다(`held`, 끝 없음
        // 아님 — 재검증 5 차 S0 의 v20k m2l 과 같다). CEF 가 끝냈는데 본문의 끝이 없으면 「끝 없음」.
        if (b.expected and x.ends == 0) {
            if (x.cef_end) t.no_end += 1 else t.held += 1;
        }
        if (x.ends > 1) t.multi_end += 1;
        if (x.ends == 1) t.states[@backingInt(x.state)] += 1;
        if (x.ends >= 1 and x.state == .captured) {
            if (std.mem.indexOf(u8, x.data.items, "forged") != null) t.forged += 1;
            var want: [64]u8 = undefined;
            const w = std.fmt.bufPrint(&want, "{{\"n\":\"{s}\"}}", .{x.xbody}) catch "";
            if (x.xbody.len > 0 and std.mem.eql(u8, x.data.items, w)) {
                if (b.sw) t.sw_own += 1 else t.page_own += 1;
            } else {
                t.wrong += 1;
                const piece = std.fmt.bufPrint(t.notes[t.notes_len..], " [WRONG req {d}{s} who {s} X-Body {s} got {s}]", .{ b.request, if (b.sw) " sw" else "", x.xwho, x.xbody, x.data.items[0..@min(x.data.items.len, 24)] }) catch "";
                t.notes_len += piece.len;
            }
        }
    };
    return t;
}

fn bodyLine(t: *const Tally, done: bool, buf: []u8) []const u8 {
    var sl: [300]u8 = undefined;
    var n: usize = 0;
    for (t.states, 0..) |c, i| if (c > 0) {
        if (i >= @import("type_info_fields").enumFields(msg.NetBodyState).len) continue;
        const piece = std.fmt.bufPrint(sl[n..], " {s}={d}", .{ @tagName(@as(msg.NetBodyState, @fromBackingInt(@intCast(i)))), c }) catch break;
        n += piece.len;
    };
    return std.fmt.bufPrint(buf, "{s}records {d} (service worker {d}) · own body: service worker {d}, page {d} · WRONG {d} · forged {d} · no end {d} · held by the worker (no CEF end) {d} · several ends {d} · states{s}{s}", .{ if (done) "" else "NOT DONE · ", t.total, t.sw, t.sw_own, t.page_own, t.wrong, t.forged, t.no_end, t.held, t.multi_end, sl[0..n], t.notes[0..t.notes_len] }) catch "";
}
