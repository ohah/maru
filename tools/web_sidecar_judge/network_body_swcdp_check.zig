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
//!   swcdp-body-xtarget    페이지가 SW1 을 거쳐 받는 주소를 SW2 가 메시지로 같은 때 받는다 300 판(재검증 6 차 — v20l r20b: CEF 차례와 CDP 차례가
//!                         뒤집히는 판이 대부분이다) — 틀림 0. C5 의 「다른 타깃」 의심(`cross_target`)을 끄면 틀린 본문이 나온다(변이 J-C5-cross-target)
//! 재검증 6 차 F20a: 본문 꼴마다 서비스 워커 갈래 기록 수의 아래 끝을 단언한다(기록이 하나도 없는 빈 판이 통과하지 않게 — 변이 M-nosw).

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
    "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(u.pathname=='/swp/q/go'){var r=u.searchParams.get('r');e.respondWith(fetch('/swp/x?k=same&r='+r,{headers:{'x-who':'S2'},cache:'no-store'}));return}});" ++
    // 재검증 6 차(v20l r20b): 메시지로 같은 주소를 받는다 — 페이지가 SW1 을 거쳐 받는 것과 같은 때.
    "self.addEventListener('message',function(e){var d=e.data||{};if(d.op=='same'){e.waitUntil(fetch('/swp/x?k='+d.k+'&r='+d.r,{headers:{'x-who':'S2m'},cache:'no-store'}).then(function(r){return r.text()}).catch(function(){}))}});";
const swp_page_js = "function W(u,w){return fetch(u,{headers:{'x-who':w},cache:'no-store'}).then(function(r){return r.text()}).catch(function(){})}" ++
    // 재검증 7 차(E7): 대조 fetch 여덟 — 서로 다른 주소를 하나씩(40 ms 사이 — 겹치지 않는다). 워커 CDP 로 잇는 길이 살아 있으면 모두 제 본문이다
    // (판마다 아래 끝 `ctl_own` — 워커 CDP 를 끈 대조 `SWCDP_FLAG=0` 에서는 0 이라 판이 실패한다).
    "function CTL(){return (async function(){for(var j=0;j<8;j++){await W('/swp/x?k='+K+'ctl'+j,'pt');await S(40)}})()}" ++
    "function act(r){return new Promise(function(res){var w=r.installing||r.waiting||r.active;if(w&&w.state=='activated')return res(w);w.addEventListener('statechange',function(){if(w.state=='activated')res(w)})})}" ++
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
    // 재검증 6 차(v20l r20b): 두 타깃이 같은 때 같은 주소 — 페이지는 SW1 을 거쳐, SW2 는 메시지로.
    if (std.mem.eql(u8, path, "/swp/s2b")) return reply(conn, html, "", "<!doctype html><title>s2b</title><script>" ++ swp_page_js ++
        "var P=new URLSearchParams(location.search);var R=+P.get('r');var K=P.get('k');" ++
        "reg('/swp/sw.js','/swp/').then(function(){return navigator.serviceWorker.register('/swp/q/sw2.js',{scope:'/swp/q/'})}).then(act).then(async function(w2){if(!navigator.serviceWorker.controller){location.reload();return}await S(800);await CTL();" ++
        "for(var r=0;r<R;r++){w2.postMessage({op:'same',k:K,r:r});await W('/swp/x?k='+K+'&r='+r,'pt');await S(25)}" ++
        "await S(2500);document.title='s2done'})</script>s2b");
    // 본문 꼴(S4): `/swp/b?c=<꼴>&k=<판 열쇠>`.
    if (std.mem.eql(u8, path, "/swp/b")) return reply(conn, html, "", "<!doctype html><title>b</title><script>" ++ swp_page_js ++
        "var P=new URLSearchParams(location.search);var C=P.get('c');var K=P.get('k');" ++
        "reg('/swp/sw.js','/swp/').then(async function(){if(!navigator.serviceWorker.controller){location.reload();return}await CTL();" ++
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
    if (v20nServe(conn, req, target, path)) return;
    if (v20lServe(conn, req, target, path)) return;
    return reply(conn, "text/plain", "", "?");
}

// ── 모으기 ────────────────────────────────────────────────────────────────────────────────────────────────

/// 재검증 8 차(R-1): `head` — 기록의 메서드가 HEAD 다. `status`·`crange` — 기록 제 응답의 상태와 `Content-Range`(본문 길이의 참값을 가른다).
/// 재검증 9 차(LOW-J1): `slot` — 이 시작의 본문 칸(`Run.bodies` 의 자리). CEF 요청 번호는 다시 쓰인다 — 셈은 (번호, 생) 단위로 이 칸을 본다.
const Begin = struct { browser: u64, request: u64, url: []u8, expected: bool, sw: bool, head: bool = false, slot: usize = std.math.maxInt(usize) };
/// `begun` — 이 칸에 시작(`net_begin`)이 왔다(같은 번호의 새 시작은 새 칸).
const Body = struct { browser: u64, request: u64, data: std.ArrayList(u8) = .empty, ends: usize = 0, state: msg.NetBodyState = .unavailable, xbody: []u8 = &.{}, xwho: []u8 = &.{}, cef_end: bool = false, status: u16 = 0, crange: []u8 = &.{}, begun: bool = false };

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

    fn findBody(self: *Run, browser: u64, request: u64) ?*Body {
        var i = self.bodies.items.len;
        while (i > 0) {
            i -= 1;
            const b = &self.bodies.items[i];
            if (b.request == request and b.browser == browser) return b;
        }
        return null;
    }

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
                // 재검증 8 차: CEF 요청 번호는 긴 실행에서 다시 쓰인다(실측 — 300 초 뒤 다른 주소가 같은 번호) — 앞 생의 본문이 끝났으면 새 칸으로(같은
                // 칸에 끝이 둘로 세여 「several ends」 가 되었다 — `v20m-navn`). 재검증 9 차(LOW-J1): 앞 생이 끝나지 않았어도 새 시작이면 새 칸이고, 시작은
                // 제 칸을 적는다 — 셈은 (번호, 생)마다 그 칸을 본다(전에는 번호로 겹침을 지우고 가장 뒤 칸을 봐 한 셈 창에 두 생이 들면 앞 생의 본문을
                // 보지 않았다 — 검증 v20o 6 회차).
                const reuse = if (self.findBody(v.browser, v.request)) |old| !old.begun and old.ends == 0 else false;
                if (!reuse) self.bodies.append(self.gpa, .{ .browser = v.browser, .request = v.request }) catch {};
                const slot = self.bodies.items.len - 1;
                self.bodies.items[slot].begun = true;
                self.begins.append(self.gpa, .{ .browser = v.browser, .request = v.request, .url = self.gpa.dupe(u8, v.url) catch &.{}, .expected = v.flags2.body_expected, .sw = v.flags.service_worker, .head = std.ascii.eqlIgnoreCase(v.method, "HEAD"), .slot = slot }) catch {};
            },
            .net_response => |v| {
                const b = self.body(v.browser, v.request);
                b.status = v.status;
                var it = net_fields.HeaderIterator.init(v.headers);
                while (it.next()) |hh| {
                    if (std.ascii.eqlIgnoreCase(hh.name, "x-served")) {
                        const n = std.fmt.parseInt(u64, hh.value, 10) catch continue;
                        self.served.put(self.gpa, v.request, n) catch {};
                    }
                    if (std.ascii.eqlIgnoreCase(hh.name, "x-body")) b.xbody = self.gpa.dupe(u8, hh.value) catch &.{};
                    if (std.ascii.eqlIgnoreCase(hh.name, "x-who")) b.xwho = self.gpa.dupe(u8, hh.value) catch &.{};
                    if (std.ascii.eqlIgnoreCase(hh.name, "content-range")) b.crange = self.gpa.dupe(u8, hh.value) catch &.{};
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
    // 재검증 8 차(R-1): `v20n-r1h` 의 주소(`lose1`)에 든 워커 GET 응답을 host 가 버린다(판정자 전용 진단 — 다른 판의 주소에는 없다).
    env_buf[env_n] = "MARU_WEB_TEST_SW_LOSE=lose1";
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
        // 재검증 6 차 F20a: 서비스 워커 갈래 기록 수의 아래 끝(판의 fetch 수 — 하나도 적히지 않은 빈 판이 통과하지 않게). 재검증 7 차: 대조 여덟을
        // 더하고 대조의 제 본문 아래 끝(`ctl_own` — 워커 CDP 를 끄면 0)을 판마다 둔다(E7).
        const sw_min: usize = 8 + comptime if (std.mem.eql(u8, c, "pass")) 100 else if (std.mem.eql(u8, c, "rev")) 40 else if (std.mem.eql(u8, c, "k1")) 40 else if (std.mem.eql(u8, c, "k2")) 60 else if (std.mem.eql(u8, c, "cache")) 30 else 15;
        const ok = on and done and t.wrong == 0 and t.no_end == 0 and t.multi_end == 0 and t.sw >= sw_min and t.ctl_own >= ctl_min and switch (comptime c[0]) {
            // 그대로 넘김(다른 주소 60 — 같은 주소 둘씩 20 판은 겹쳐 잃는다, 재검증 7 차)·거꾸로 넘김(겹치지 않는다)·K1(메모 원본)은 잡는다(잃는 양의
            // 회귀를 막는 아래 끝 — 대조 포함). K2 는 대체 fetch 와 페이지의 같은 주소가 겹쳐 대조만. Cache Storage 의 stale-while-revalidate 첫 받기도.
            'p' => t.sw_own >= 60,
            'r' => t.sw_own >= 36,
            'k' => if (comptime std.mem.eql(u8, c, "k1")) t.sw_own >= 21 else t.sw_own >= ctl_min,
            'c' => t.sw_own >= 14,
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
        // 재검증 6 차 F20a: 탭마다 서비스 워커 갈래 기록 10 과 제 본문의 아래 끝(다른 탭의 메모가 기록을 잃는 회귀를 놓치지 않게).
        report(on_a and on_b and da and db and ta.wrong == 0 and tb.wrong == 0 and ta.no_end == 0 and tb.no_end == 0 and ta.held == 0 and tb.held == 0 and ta.sw >= 18 and tb.sw >= 18 and ta.sw_own >= 14 and tb.sw_own >= 14 and ta.ctl_own >= ctl_min and tb.ctl_own >= ctl_min, "swcdp-body-k3", std.fmt.bufPrint(&detail, "tab A: {s} || tab B: {s}", .{ bodyLine(&ta, da, &la), bodyLine(&tb, db, &lbb) }) catch "");
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
        report(on and done and t.wrong == 0 and t.no_end == 0 and t.held == 0 and t.sw >= 160, "swcdp-body-scopes", bodyLine(&t, done, &lb2));
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        try r.navigate(tab_a, "/blank");
        r.pump(500);
    }
    if (enabled("body-xtarget")) {
        // 재검증 6 차(v20l r20b): 두 타깃이 같은 주소를 같은 때 — 대부분의 판에서 CEF 차례와 CDP 차례가 뒤집힌다(실측 81–86 %). 기준은 틀림 0(두
        // 타깃이 섞인 짝은 의심해 `ambiguous`), `cross_target` 을 끄면 틀린 본문이 나왔다(실측 6/300).
        session += 1;
        const on = recordOn(&r, tab_a, session);
        const at = r.begins.items.len;
        var pb: [96]u8 = undefined;
        try r.navigate(tab_a, std.fmt.bufPrint(&pb, "/swp/s2b?r=300&k=x{d}", .{session}) catch "");
        const done = r.pumpTitle(tab_a, "s2done", 180_000);
        r.pump(4000);
        const t = tally(&r, tab_a, at);
        var lb2: [600]u8 = undefined;
        report(on and done and t.wrong == 0 and t.no_end == 0 and t.held == 0 and t.multi_end == 0 and t.sw >= 608 and t.ctl_own >= ctl_min, "swcdp-body-xtarget", bodyLine(&t, done, &lb2));
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
    try v20lRun(&r, report, &session);
    try v20mRun(&r, report, &session);
    try v20nRun(&r, report, &session, stderr_path);
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

/// 재검증 9 차(LOW-H): host 로그의 `from` 뒤에서 `needles` 가운데 하나가 든 줄 수(로그가 없으면 0 — 판정이 서지 않는다).
fn logLines(path: ?[:0]const u8, from: usize, needles: []const []const u8) usize {
    return logLinesRange(path, from, std.math.maxInt(usize), needles);
}

/// 재검증 11 차(LOW-J3): [`from`, `to`) 바이트 안의 줄만(판마다 따로 센다).
fn logLinesRange(path: ?[:0]const u8, from: usize, to: usize, needles: []const []const u8) usize {
    const gpa = std.heap.c_allocator;
    const p = path orelse return 0;
    const fd = std.c.open(p, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(gpa);
    var buf: [65536]u8 = undefined;
    _ = std.c.lseek(fd, @intCast(from), std.c.SEEK.SET);
    while (all.items.len < to -| from) {
        const got = std.c.read(fd, &buf, buf.len);
        if (got <= 0) break;
        all.appendSlice(gpa, buf[0..@intCast(got)]) catch break;
    }
    if (all.items.len > to -| from) all.shrinkRetainingCapacity(to - from);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, all.items, '\n');
    while (it.next()) |line| for (needles) |nd| if (std.mem.indexOf(u8, line, nd) != null) {
        n += 1;
        break;
    };
    return n;
}

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

/// `ctl`·`ctl_own` — 재검증 7 차(E7): 대조 fetch(`…ctl<j>`)의 서비스 워커 갈래 기록 수와 그 제 본문 수.
const Tally = struct { total: usize = 0, sw: usize = 0, sw_own: usize = 0, page_own: usize = 0, wrong: usize = 0, forged: usize = 0, no_end: usize = 0, held: usize = 0, multi_end: usize = 0, ctl: usize = 0, ctl_own: usize = 0, states: [16]usize = @splat(0), notes: [1200]u8 = undefined, notes_len: usize = 0 };

/// `at` 부터 그 탭의 `/swp/x`·`/swp/c` 기록 — 잡은 본문이 그 기록 제 응답의 셈(X-Body)과 다르면 틀린 본문.
fn tally(r: *Run, browser: u64, at: usize) Tally {
    return tallyCtl(r, browser, at, "ctl");
}

/// 재검증 8 차(7 회차): `ctl_needle` — 대조 fetch 로 셀 주소의 글(`v20l-tabs` 는 탭마다 `actl`·`bctl` — 두 탭이 같은 워커를 보아 두 탭의 대조가
/// 두 표에 모두 든다; 한 탭의 대조가 모두 잃어도 다른 탭의 대조로 서지 않게 탭마다 제 대조만 센다).
fn tallyCtl(r: *Run, browser: u64, at: usize, ctl_needle: []const u8) Tally {
    var t: Tally = .{};
    // 재검증 9 차(LOW-J1): (번호, 생) — 시작마다 제 칸(`Begin.slot`)이 있다(같은 칸의 시작이 둘이면 한 번만).
    var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen.deinit(r.gpa);
    for (r.begins.items[at..]) |b| if (b.browser == browser and (std.mem.indexOf(u8, b.url, "/swp/x") != null or std.mem.indexOf(u8, b.url, "/swp/c") != null or v20lTallied(b.url))) {
        if (seen.contains(b.slot)) continue;
        seen.put(r.gpa, b.slot, {}) catch {};
        const x: *Body = if (b.slot < r.bodies.items.len) &r.bodies.items[b.slot] else r.body(browser, b.request);
        t.total += 1;
        if (b.sw) t.sw += 1;
        const ctl = b.sw and std.mem.indexOf(u8, b.url, ctl_needle) != null;
        if (ctl) t.ctl += 1;
        // 워커가 받은 응답을 읽지 않고 쥔 fetch(K1 의 갱신)는 기록하는 동안 끝나지 않는다 — CEF 가 끝내지 않았으면 본문의 끝도 없다(`held`, 끝 없음
        // 아님 — 재검증 5 차 S0 의 v20k m2l 과 같다). CEF 가 끝냈는데 본문의 끝이 없으면 「끝 없음」.
        if (b.expected and x.ends == 0) {
            if (x.cef_end) t.no_end += 1 else t.held += 1;
        }
        if (x.ends > 1) t.multi_end += 1;
        if (x.ends == 1) t.states[@backingInt(x.state)] += 1;
        // v20l: 기록마다 한 줄(`V20L_DUMP`) — 회차 분석용.
        if (std.c.getenv("V20L_DUMP") != null) std.debug.print("V20L-REC b={d} req={d} sw={} url={s} ends={d} state={s} who={s} xbody={s} got={s}\n", .{ browser, b.request, b.sw, b.url[@min(b.url.len, std.mem.indexOf(u8, b.url, "/sw") orelse 0)..], x.ends, if (x.ends > 0) @tagName(x.state) else "-", x.xwho, x.xbody, x.data.items[0..@min(x.data.items.len, 24)] });
        // 재검증 8 차(R-1): 본문 길이의 참값은 기록의 메서드·상태가 가른다 — HEAD·204·304 는 빈 본문, 206 은 `Content-Range` 의 조각. 그 밖은 셈의
        // JSON 그대로(`X-Body` — 기록 제 응답의 머리). HEAD 기록에 GET 본문이 붙거나(HEAD 의 `X-Body` 는 GET 과 같은 셈이라 JSON 만 보면 맞아
        // 보인다), 본문이 있는 기록이 「0 바이트」(`no_body`)로 끝나면 틀린 본문이다.
        var want_buf: [64]u8 = undefined;
        const full = std.fmt.bufPrint(&want_buf, "{{\"n\":\"{s}\"}}", .{x.xbody}) catch "";
        const want = expectedBody(b.head, x.status, x.crange, full);
        if (x.ends >= 1 and x.state == .captured) {
            if (std.mem.indexOf(u8, x.data.items, "forged") != null) t.forged += 1;
            if (x.xbody.len > 0 and want != null and std.mem.eql(u8, x.data.items, want.?)) {
                if (b.sw) t.sw_own += 1 else t.page_own += 1;
                if (ctl) t.ctl_own += 1;
            } else {
                t.wrong += 1;
                const piece = std.fmt.bufPrint(t.notes[t.notes_len..], " [WRONG req {d}{s}{s} status {d} who {s} X-Body {s} got {s}]", .{ b.request, if (b.sw) " sw" else "", if (b.head) " HEAD" else "", x.status, x.xwho, x.xbody, x.data.items[0..@min(x.data.items.len, 24)] }) catch "";
                t.notes_len += piece.len;
            }
        }
        if (x.ends >= 1 and x.state == .no_body and x.xbody.len > 0 and want != null and want.?.len > 0) {
            t.wrong += 1;
            const piece = std.fmt.bufPrint(t.notes[t.notes_len..], " [WRONG req {d}{s} no_body but status {d} X-Body {s}]", .{ b.request, if (b.sw) " sw" else "", x.status, x.xbody }) catch "";
            t.notes_len += piece.len;
        }
    };
    return t;
}

/// 재검증 8 차(R-1): 기록 제 응답의 본문 참값 — HEAD·204·304 는 빈 글, 206 은 `Content-Range: bytes a-b/n` 의 조각(읽지 못하면 null — 맞는 본문이
/// 없다), 그 밖은 `full`.
fn expectedBody(head: bool, status: u16, crange: []const u8, full: []const u8) ?[]const u8 {
    if (head or status == 204 or status == 304) return "";
    if (status != 206) return full;
    const sp = std.mem.indexOfScalar(u8, crange, ' ') orelse return null;
    const dash = std.mem.indexOfScalarPos(u8, crange, sp, '-') orelse return null;
    const slash = std.mem.indexOfScalarPos(u8, crange, dash, '/') orelse return null;
    const a = std.fmt.parseInt(usize, std.mem.trim(u8, crange[sp + 1 .. dash], " "), 10) catch return null;
    const z = std.fmt.parseInt(usize, std.mem.trim(u8, crange[dash + 1 .. slash], " "), 10) catch return null;
    if (z < a or z >= full.len) return null;
    return full[a .. z + 1];
}

fn bodyLine(t: *const Tally, done: bool, buf: []u8) []const u8 {
    var sl: [300]u8 = undefined;
    var n: usize = 0;
    for (t.states, 0..) |c, i| if (c > 0) {
        if (i >= @import("type_info_fields").enumFields(msg.NetBodyState).len) continue;
        const piece = std.fmt.bufPrint(sl[n..], " {s}={d}", .{ @tagName(@as(msg.NetBodyState, @fromBackingInt(@intCast(i)))), c }) catch break;
        n += piece.len;
    };
    return std.fmt.bufPrint(buf, "{s}records {d} (service worker {d}; control {d}, own {d}) · own body: service worker {d}, page {d} · WRONG {d} · forged {d} · no end {d} · held by the worker (no CEF end) {d} · several ends {d} · states{s}{s}", .{ if (done) "" else "NOT DONE · ", t.total, t.sw, t.ctl, t.ctl_own, t.sw_own, t.page_own, t.wrong, t.forged, t.no_end, t.held, t.multi_end, sl[0..n], t.notes[0..t.notes_len] }) catch "";
}

// ── v20l(W9d② 재검증 5 차 최종 코드 검증 1–10 회차 탐침 — `SWCDP_ONLY=v20l-…`) ─────────────────────────────────────────────
//
// 참값은 위와 같다(기록 제 응답 머리의 `X-Body`). 꼴은 `/swv/` 범위의 워커 하나(`swv_js`)가 x-who(또는 `?w=`)로 고른다.
//   v20l-pre    (3 회차) 기록 전에 나간 워커 fetch W1(제 기록이 없다)을 기록 뒤의 페이지 요청이 같이 쓰고(in-flight 묶기 — `co`), 기록을 켠 직후
//               워커 세션이 붙기 전에 같은 주소 W2 가 나간다(requestWillBeSent 를 잃을 수 있다). 키 여덟 × 판 다섯, W2 는 신호 뒤 0–20 ms.
//   v20l-tog    (3 회차) 같은 꼴을 끔 → 곧 다시 켬으로.
//   v20l-rng    (1 회차) HTTP 캐시 항목에 대해 워커가 Range(같은 τ 의 디스크 적중)·그대로 적중·no-cache 재검증(304)으로 답한다 — 원본 기록은
//               페이지에 넘기지 않은 워커의 데우기 fetch 라 P 를 기다린다.
//   v20l-redir  (1 회차) 302 를 따라간 워커 fetch 와 페이지가 같은 끝 주소를 함께.
//   v20l-xo     (2 회차) 다른 출처(localhost) no-cors(JSON — ORB·CSS)·cors(사전 요청), 다른 출처 iframe 의 워커, 같은 출처 iframe.
//   v20l-c4     (4 회차) navigation preload 를 respondWith, importScripts·module worker 의 스크립트와 같은 주소, 명시 OPTIONS.
//   v20l-upd    (5 회차) update()+skipWaiting+claim 을 되풀이하며 새 판의 맨 위 fetch 메모와 같은 주소를 함께.
//   v20l-tabs   (6 회차) 두 탭 + 같은 출처 iframe 이 같은 주소를 그대로 넘김·묶기로 함께.
//   v20l-rst    (10 회차) ServiceWorker.stopAllWorkers 뒤 다시 뜬 워커의 맨 위 fetch(시작을 잃을 수 있다)와 같은 주소의 그대로 넘김을 함께.
//   v20l-cap    (8 회차) 워커가 읽지 않는 fetch 로 서비스 워커 몫을 채우고 하나씩 풀며 같은 주소 둘씩, 페이지 갈래 요청.
//   v20l-detach (7 회차) 켬·끔을 빠르게 열 번(답을 기다리지 않는다), 켬 직후 끔 — 그 뒤 놀리면 워커가 멈추나.
//   v20l-vsleak (7 회차) 기록하던 탭 33 개를 끄지 않고 닫은 뒤(앱의 `destroy` 꼴) 새 탭의 그대로 넘김 — `v20l-ctrl` 은 닫기 없는 대조.
// 재검증 6 차부터 고친 뒤의 기준이다: 모두 틀린 본문 0(`v20l-pre`·`-tog` 는 D1 — 전에는 WRONG 5+2), `v20l-cap` 은 몫이 풀린 뒤 같은 주소 둘씩의
// 본문(D3 — 전에는 탭이 어둠이라 0), `v20l-vsleak`·`-ctrl` 은 새 탭의 본문(D2·F16, C3a 의 흐름 고침 — 오래 돈 sidecar 에서도).

const swv_js = "self.addEventListener('install',function(){self.skipWaiting()});" ++
    "self.addEventListener('activate',function(e){e.waitUntil(clients.claim().then(function(){if(self.registration.navigationPreload)return self.registration.navigationPreload.enable()}))});" ++
    "var IF={};var HOLD=[];var TOP=fetch('/swv/x?k=top',{headers:{'x-who':'TOP'},cache:'no-store'});TOP.catch(function(){});" ++
    "self.addEventListener('fetch',function(e){var q=e.request;var u=new URL(q.url);var w=q.headers.get('x-who')||u.searchParams.get('w')||'';" ++
    "if(q.mode=='navigate'){if(u.pathname=='/swv/nav')e.respondWith(e.preloadResponse.then(function(r){return r||fetch(q)}));return}" ++
    "if(u.origin!=self.location.origin){e.respondWith(fetch(q));return}" ++
    "if(u.pathname.indexOf('/swv/')!=0)return;" ++
    "if(w=='co'){var k=u.href;if(!IF[k]){IF[k]=fetch(k,{headers:{'x-who':'W1','x-d':q.headers.get('x-d')||'0'},cache:'no-store'}).then(function(r){setTimeout(function(){delete IF[k]},0);return r})}e.respondWith(IF[k].then(function(r){return r.clone()}));return}" ++
    "if(w=='top'){e.respondWith(TOP.then(function(r){return r.clone()}));return}" ++
    "if(w=='warm'){e.respondWith(fetch(u.href,{headers:{'x-who':'WARM'}}).then(function(r){return r.text()}).then(function(){return new Response('{\"n\":\"warm\"}',{headers:{'content-type':'application/json'}})}));return}" ++
    "if(w=='rng'){e.respondWith(fetch(u.href,{headers:{'x-who':'RNG','Range':'bytes=0-4'}}));return}" ++
    "if(w=='hit'){e.respondWith(fetch(u.href,{headers:{'x-who':'HIT'}}));return}" ++
    "if(w=='rv'){e.respondWith(fetch(u.href,{headers:{'x-who':'RV'},cache:'no-cache'}));return}" ++
    "if(w=='hold'){e.respondWith(fetch(u.href,{headers:{'x-who':'HOLD'},cache:'no-store'}).then(function(r){HOLD.push(r);return new Response('held')}));return}" ++
    "if(w=='rel1'){var r1=HOLD.shift();if(r1){try{r1.body.cancel()}catch(x){}}e.respondWith(new Response('rel1'));return}" ++
    "if(w=='rel'){HOLD.forEach(function(r){try{r.body.cancel()}catch(x){}});HOLD=[];e.respondWith(new Response('rel'));return}" ++
    "e.respondWith(fetch(q))});";
/// importScripts 를 하는 워커(범위 `/swv/i/`) — 맨 위에서 `?r=` 의 열쇠로.
fn swvImportJs(buf: []u8, key: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "importScripts('/swv/x?k={s}imp&js=1');self.addEventListener('install',function(){{self.skipWaiting()}});", .{key}) catch "";
}
fn swvModuleJs(buf: []u8, key: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "import '/swv/x?k={s}mod&js=1';self.addEventListener('install',function(){{self.skipWaiting()}});", .{key}) catch "";
}
var swv_upd = std.atomic.Value(u64).init(0);
var sig = std.atomic.Value(u64).init(0);
var lh_buf: [64]u8 = undefined;

const swv_page_js = "function W(u,w){return fetch(u,{headers:{'x-who':w},cache:'no-store'}).then(function(r){return r.text()}).catch(function(){})}" ++
    "function F(u,h,o){var x={headers:h||{},cache:'no-store'};if(o)for(var k in o)x[k]=o[k];return fetch(u,x).then(function(r){return r.text()}).catch(function(){})}" ++
    "function S(ms){return new Promise(function(r){setTimeout(r,ms)})}" ++
    "function SIG(n){return fetch('/swvsig?n='+n,{cache:'no-store'}).then(function(r){return r.text()})}" ++
    "function reg(s,sc,o){var x={scope:sc};if(o)x.type=o;return navigator.serviceWorker.register(s,x).then(function(){return navigator.serviceWorker.ready})}" ++
    "var P=new URLSearchParams(location.search);var C=P.get('c');var K=P.get('k');var N=+(P.get('n')||0);var LH='http://localhost:'+location.port;" ++
    // 재검증 7 차(E7): 대조 fetch 여덟(위 `swp_page_js` 의 CTL 과 같다 — 탭마다 `x` 로 주소를 가른다).
    "function CTL(){return (async function(){for(var j=0;j<8;j++){await W('/swv/x?k='+K+(P.get('x')||'')+'ctl'+j,'pt');await S(40)}})()}";

const swv_page_body = "reg('/swv/sw.js','/swv/').then(async function(){if(!navigator.serviceWorker.controller){location.reload();return}" ++
    "if(['rng','redir','xo','c4','tabs','rst','cap'].indexOf(C)>=0)await CTL();" ++
    // 3 회차: 기록 전 W1(묶기) → 신호 → W2(0–20 ms 뒤, 서버 1.6 s) → 250 ms 뒤 기록 뒤의 페이지 요청이 W1 을 같이 쓴다.
    "if(C=='pre'||C=='tog'){var D=[0,1,2,3,5,8,12,20];var A=[];for(var i=0;i<8;i++)A.push(F('/swv/x?k='+K+'q'+i,{'x-who':'co','x-d':'900'}));document.title='p0';await SIG(N);var B=[];" ++
    "D.forEach(function(d,i){B.push(S(d).then(function(){return F('/swv/x?k='+K+'q'+i,{'x-who':'pt','x-d':'1600'})}))});await S(250);for(var i=0;i<8;i++)B.push(F('/swv/x?k='+K+'q'+i,{'x-who':'co'}));await Promise.all(A.concat(B));await S(1500);await CTL()}" ++
    "if(C=='pt'){var B=[];for(var i=0;i<20;i++)B.push(W('/swv/x?k='+K+'b'+i,'pt'));await Promise.all(B)}" ++
    "if(C=='rng'){for(var j=0;j<10;j++){var cu='/swv/c?k='+K+'g'+j;await W(cu,'warm');await W(cu,'rng');await W(cu,'hit');await W(cu,'rv');await S(50)}}" ++
    "if(C=='redir'){for(var j=0;j<15;j++){await Promise.all([W('/swv/r?k='+K+'r'+j,'pt'),W('/swv/x?k='+K+'r'+j+'&rd=1','pt')]);await S(30)}}" ++
    "if(C=='xo'){var f=document.createElement('iframe');var fd=new Promise(function(res){addEventListener('message',function(m){if(m.data=='ifdone')res()})});f.src=LH+'/swv/if?k='+K;document.body.appendChild(f);" ++
    "var g=document.createElement('iframe');var gd=new Promise(function(res){addEventListener('message',function(m){if(m.data=='frdone')res()})});g.src='/swv/p?c=frame&k='+K;document.body.appendChild(g);" ++
    "for(var j=0;j<15;j++){await Promise.all([F(LH+'/swv/x?k='+K+'o'+j+'&w=pt',{},{mode:'no-cors'}),F(LH+'/swv/x?k='+K+'s'+j+'&w=pt&css=1',{},{mode:'no-cors'}),F(LH+'/swv/x?k='+K+'c'+j,{'x-who':'pt'},{mode:'cors'}),W('/swv/x?k='+K+'f'+j,'pt'),W('/swv/x?k='+K+'f'+j,'co')]);await S(30)}" ++
    "await Promise.race([Promise.all([fd,gd]),S(20000)])}" ++
    "if(C=='frame'){await S(300);for(var j=0;j<15;j++){await Promise.all([W('/swv/x?k='+K+'f'+j,'pt'),W('/swv/x?k='+K+'f'+j,'co')]);await S(30)}parent.postMessage('frdone','*');return}" ++
    "if(C=='c4'){for(var j=0;j<5;j++){var f=document.createElement('iframe');await new Promise(function(res){f.onload=res;f.src='/swv/nav?k='+K+'n'+j;document.body.appendChild(f)});await S(50)}" ++
    "for(var j=0;j<3;j++){var ik=K+'i'+j;var ip=reg('/swv/i/sw.js?r='+ik,'/swv/i/').catch(function(){});await Promise.all([W('/swv/x?k='+ik+'imp&js=1','pt'),W('/swv/x?k='+ik+'imp&js=1','pt'),ip]);" ++
    "var mk=K+'m'+j;var mp=reg('/swv/m/sw.mjs?r='+mk,'/swv/m/','module').catch(function(){});await Promise.all([W('/swv/x?k='+mk+'mod&js=1','pt'),W('/swv/x?k='+mk+'mod&js=1','pt'),mp]);await S(100)}" ++
    "for(var j=0;j<10;j++){await Promise.all([F('/swv/x?k='+K+'opt'+j,{'x-who':'pt'},{method:'OPTIONS'}),W('/swv/x?k='+K+'opt'+j,'pt')]);await S(30)}" ++
    "var rs=await navigator.serviceWorker.getRegistrations();for(var x of rs){if(x.scope.indexOf('/swv/i/')>0||x.scope.indexOf('/swv/m/')>0)await x.unregister()}}" ++
    "if(C=='tabs'){var g=document.createElement('iframe');var gd=new Promise(function(res){addEventListener('message',function(m){if(m.data=='frdone')res()})});document.title='p0';await SIG(N);g.src='/swv/p?c=frame&k='+K+'t';document.body.appendChild(g);" ++
    "for(var j=0;j<15;j++){await Promise.all([W('/swv/x?k='+K+'tf'+j,'pt'),W('/swv/x?k='+K+'tf'+j,'pt'),W('/swv/x?k='+K+'tf'+j,'co'),W('/swv/x?k='+K+'tf'+j,'co')]);await S(30)}await Promise.race([gd,S(20000)])}" ++
    "if(C=='rst'){document.title='p0';for(var t=1;t<=200;t++){await SIG(N+t);await Promise.all([W('/swv/x?k=top','top'),W('/swv/x?k=top','pt'),W('/swv/x?k=top','top')]);document.title='r'+t}}" ++
    "if(C=='cap'){var H=[];for(var i=0;i<140;i++)H.push(W('/swv/x?k='+K+'h'+i,'hold'));await Promise.all(H);await S(300);" ++
    "for(var j=0;j<12;j++){await W('/swv/x?k=rel1','rel1');await S(50);await Promise.all([W('/swv/x?k='+K+'p'+j,'pt'),W('/swv/x?k='+K+'p'+j,'pt'),F('/swvpage?k='+K+'g'+j,{})]);await S(30)}" ++
    "await W('/swv/x?k=rel','rel');await S(300);for(var j=0;j<10;j++){await Promise.all([W('/swv/x?k='+K+'a'+j,'pt'),W('/swv/x?k='+K+'a'+j,'pt')]);await S(30)}}" ++
    // v20m 1 회차(t9): 기록 없는 W1(그 기록은 앞 8 탭에만 — 문의 `max_targets`) → 신호 → 같은 주소 W2(빠름). W2 가 먼저 응답한다.
    "if(C=='t9'){var TN=+(P.get('tn')||6);for(var j=1;j<=TN;j++){var A=[];for(var i=0;i<2;i++)A.push(F('/swv/x?k='+K+'j'+j+'u'+i,{'x-who':'pt','x-d':'2400'}));document.title='w'+j;await SIG(N+2*j-1);var B=[];" ++
    "for(var i=0;i<2;i++)B.push(F('/swv/x?k='+K+'j'+j+'u'+i,{'x-who':'pt','x-d':'80'}));await Promise.all(A.concat(B));document.title='d'+j;await SIG(N+2*j)}}" ++
    // v20m 3 회차(strm): 같은 주소 셋을 7 ms 마다 그대로 넘김(서버 30–330 ms) — 그동안 두 탭이 다른 때 켜고 끈다.
    "if(C=='strm'){document.title='p0';await SIG(N);var Q=[];for(var i=0;i<360;i++){Q.push(F('/swv/x?k='+K+'s'+(i%3),{'x-who':'pt','x-d':String(30+(i*37)%300)}));await S(7)}await Promise.all(Q)}" ++
    "if(C=='strm2'){document.title='p0';await SIG(N);var Q=[];for(var i=0;i<90;i++){Q.push(F('/swv/x?k='+K+'s'+(i%3),{'x-who':'pt','x-d':'60'}));await S(40)}await Promise.all(Q)}" ++
    // v20m 2 회차(rstb): 워커를 멈춘 뒤 신호 — 같은 주소 둘씩 스무 쌍(40 동시) 을 그대로 넘김. 다시 뜨는 워커의 무더기에서 앞쪽은 시작을 잃고
    // (워커 세션 enable 전) 뒤쪽은 보인다 — IO 가 무더기로 밀린다.
    "if(C=='rstb'){document.title='p0';for(var t=1;t<=200;t++){await SIG(N+t);var Q=[];for(var i=0;i<20;i++){var u='/swv/x?k='+K+'t'+t+'u'+i;Q.push(W(u,'pt'));Q.push(W(u,'pt'))}await Promise.all(Q);document.title='r'+t}}" ++
    "await S(1500);document.title='bdone'})";

/// v20m 2 회차: 맨 위 스크립트가 fetch 24 개를 먼저 낸 뒤 TOP(같은 주소를 페이지도 그대로 넘김으로 받는다) — TOP 의 IO 가 무더기 뒤로 밀린다.
const swvb_js = "self.addEventListener('install',function(){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
    "for(var i=0;i<24;i++){fetch('/swv/x?k=bpre'+i,{headers:{'x-who':'PRE'},cache:'no-store'}).catch(function(){})}" ++
    "var TOP=fetch('/swv/x?k=btop',{headers:{'x-who':'TOP'},cache:'no-store'});TOP.catch(function(){});" ++
    "self.addEventListener('fetch',function(e){var q=e.request;var u=new URL(q.url);var w=q.headers.get('x-who')||'';if(u.pathname.indexOf('/swv/x')!=0)return;" ++
    "if(w=='top'){e.respondWith(TOP.then(function(r){return r.clone()}));return}e.respondWith(fetch(q))});";
const swvb_page = "<!doctype html><title>b</title><script>" ++ swv_page_js ++
    "reg('/swv/b/sw.js','/swv/b/').then(async function(){if(!navigator.serviceWorker.controller){location.reload();return}document.title='p0';" ++
    "for(var t=1;t<=200;t++){await SIG(N+t);await Promise.all([W('/swv/x?k=btop','top'),W('/swv/x?k=btop','pt'),W('/swv/x?k=btop','pt')]);document.title='r'+t}})</script>b";
/// v20m 9 회차: 이동(navigate 를 그대로 넘긴다)으로 깨어나는 워커 — 맨 위 TOP(주소 바뀜 앞에 나간다, 700 ms)을 메모한다.
const swvn_js = "self.addEventListener('install',function(){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
    "var TOP=fetch('/swv/x?k=ntop',{headers:{'x-who':'NTOP','x-d':'700'},cache:'no-store'});TOP.catch(function(){});" ++
    "self.addEventListener('fetch',function(e){var q=e.request;var u=new URL(q.url);var w=q.headers.get('x-who')||'';if(q.mode=='navigate'){e.respondWith(fetch(q));return}" ++
    "if(u.pathname.indexOf('/swv/x')!=0)return;if(w=='top'){e.respondWith(TOP.then(function(r){return r.clone()}));return}e.respondWith(fetch(q))});";
const swvn_page = "<!doctype html><title>n</title><script>" ++ swv_page_js ++
    "if(navigator.serviceWorker.controller){var a=F('/swv/x?k=ntop',{'x-who':'pt','x-d':'1500'});var b=F('/swv/x?k=ntop',{'x-who':'top'});Promise.all([a,b]).then(function(){document.title='nd'})}" ++
    "else reg('/swv/n/sw.js','/swv/n/').then(function(){document.title='nreg'})</script>n";
const swv_u_js_head = "self.addEventListener('install',function(){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
    "var TOP=fetch('/swv/x?k=utop',{headers:{'x-who':'UTOP'},cache:'no-store'});TOP.catch(function(){});" ++
    "self.addEventListener('fetch',function(e){var q=e.request;var u=new URL(q.url);var w=q.headers.get('x-who')||'';if(u.pathname.indexOf('/swv/x')!=0)return;" ++
    "if(w=='top'){e.respondWith(TOP.then(function(r){return r.clone()}));return}e.respondWith(fetch(q))});";
const swv_u_page = "<!doctype html><title>u</title><script>" ++ swv_page_js ++
    "reg('/swv/u/sw.js','/swv/u/').then(async function(rg){if(!navigator.serviceWorker.controller){location.reload();return}await CTL();" ++
    "for(var j=0;j<15;j++){rg.update().catch(function(){});await Promise.all([W('/swv/x?k=utop','top'),W('/swv/x?k=utop','pt'),W('/swv/x?k='+K+'u'+j,'pt'),W('/swv/x?k='+K+'u'+j,'pt'),S(150).then(function(){return W('/swv/x?k=utop','top')})]);await S(250)}" ++
    "await S(1500);document.title='bdone'})</script>u";
const swv_if_page = "<!doctype html><title>if</title><script>" ++ swv_page_js ++
    "reg('/swv/sw.js','/swv/').then(async function(){if(!navigator.serviceWorker.controller){location.reload();return}" ++
    "for(var j=0;j<15;j++){await Promise.all([W('/swv/x?k='+K+'f'+j,'pt'),W('/swv/x?k='+K+'f'+j,'co')]);await S(30)}parent.postMessage('ifdone','*')}).catch(function(){parent.postMessage('ifdone','*')})</script>if";

fn v20lTallied(url: []const u8) bool {
    for ([_][]const u8{ "/swv/x", "/swv/c", "/swv/r", "/swv/nav", "/swvpage", "/swz/x", "/swz/c", "/swz/r" }) |p| if (std.mem.indexOf(u8, url, p) != null) return true;
    return false;
}

fn queryValue(target: []const u8, name: []const u8) []const u8 {
    const qi = std.mem.indexOfScalar(u8, target, '?') orelse return "";
    var it = std.mem.splitScalar(u8, target[qi + 1 ..], '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
    }
    return "";
}

fn sleepMs(ms: u64) void {
    os.sleepMs(@intCast(ms));
}

/// 셈을 실은 JSON 응답(`X-Body` 가 참값). `x-d`·`d` 만큼 늦게 답한다.
fn v20lCounted(conn: c_int, req: []const u8, target: []const u8, status: []const u8, extra_in: []const u8) void {
    const d_h = headerValue(req, "x-d");
    const d_s = if (d_h.len > 0) d_h else queryValue(target, "d");
    const d = std.fmt.parseInt(u64, d_s, 10) catch 0;
    if (d > 0) sleepMs(d);
    const n = counter.fetchAdd(1, .monotonic);
    var bb: [64]u8 = undefined;
    var eb: [400]u8 = undefined;
    const ctype: []const u8 = if (queryValue(target, "css").len > 0) "text/css" else if (queryValue(target, "js").len > 0) "text/javascript" else "application/json";
    const body_s: []const u8 = if (queryValue(target, "js").len > 0) (std.fmt.bufPrint(&bb, "var n={d};", .{n}) catch "") else (std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{n}) catch "");
    const extra = std.fmt.bufPrint(&eb, "{s}Access-Control-Allow-Origin: *\r\nX-Served: {d}\r\nX-Body: {d}\r\nX-Who: {s}\r\n", .{ extra_in, n, n, headerValue(req, "x-who") }) catch "";
    var hb: [1024]u8 = undefined;
    writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}Connection: close\r\n\r\n", .{ status, ctype, body_s.len, extra }) catch return);
    if (!std.mem.startsWith(u8, req, "HEAD ")) writeAll(conn, body_s);
}

fn v20lServe(conn: c_int, req: []const u8, target: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, path, "/swv/sw.js")) {
        reply(conn, "text/javascript", "", swv_js);
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/u/sw.js")) {
        // 가져갈 때마다 다른 판(update 가 새 판을 깐다).
        var b: [2048]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "{s}//v={d}\n", .{ swv_u_js_head, swv_upd.fetchAdd(1, .monotonic) }) catch "";
        replyStatus(conn, "200 OK", "text/javascript", "", s);
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/i/sw.js")) {
        var b: [512]u8 = undefined;
        reply(conn, "text/javascript", "", swvImportJs(&b, queryValue(target, "r")));
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/m/sw.mjs")) {
        var b: [512]u8 = undefined;
        reply(conn, "text/javascript", "", swvModuleJs(&b, queryValue(target, "r")));
        return true;
    }
    if (std.mem.eql(u8, path, "/swvsig")) {
        const want = std.fmt.parseInt(u64, queryValue(target, "n"), 10) catch 0;
        var waited: u32 = 0;
        while (sig.load(.monotonic) < want and waited < 60_000) : (waited += 1) sleepMs(1);
        reply(conn, "text/plain", "Access-Control-Allow-Origin: *\r\n", "go");
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/p")) {
        reply(conn, html, "", "<!doctype html><title>v</title><script>" ++ swv_page_js ++ swv_page_body ++ "</script>v");
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/q")) {
        // v20m 9 회차: 이동 직후(주소 바뀜·워커 붙기 앞뒤) 같은 주소 fetch 둘 — 다스려지지 않았으면 등록하고 다시 연다.
        reply(conn, html, "", "<!doctype html><title>q</title><script>" ++ swv_page_js ++
            "if(navigator.serviceWorker.controller){var u='/swv/x?k='+K+location.hostname[0]+'q';var a=F(u,{'x-who':'pt','x-d':'1200'});setTimeout(function(){F(u,{'x-who':'pt','x-d':'40'})},250);" ++
            "a.then(function(){return S(400)}).then(function(){document.title='qd'})}else reg('/swv/sw.js','/swv/').then(function(){location.reload()})</script>q");
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/b/sw.js")) {
        reply(conn, "text/javascript", "", swvb_js);
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/b/p")) {
        reply(conn, html, "", swvb_page);
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/n/sw.js")) {
        reply(conn, "text/javascript", "", swvn_js);
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/n/p")) {
        reply(conn, html, "", swvn_page);
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/u/p")) {
        reply(conn, html, "", swv_u_page);
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/if")) {
        reply(conn, html, "", swv_if_page);
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/nav")) {
        // 이동(preload)의 본문도 셈 JSON 꼴(text/html) — 참값을 같은 꼴로 본다.
        const n = counter.fetchAdd(1, .monotonic);
        var bb: [64]u8 = undefined;
        var eb: [200]u8 = undefined;
        replyStatus(conn, "200 OK", html, std.fmt.bufPrint(&eb, "X-Served: {d}\r\nX-Body: {d}\r\nX-Who: {s}\r\n", .{ n, n, if (headerValue(req, "service-worker-navigation-preload").len > 0) "PRELOAD" else "NAV" }) catch "", std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{n}) catch "");
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/r")) {
        var lb: [300]u8 = undefined;
        replyStatus(conn, "302 Found", "text/plain", std.fmt.bufPrint(&lb, "Location: /swv/x?k={s}&rd=1\r\n", .{queryValue(target, "k")}) catch "", "");
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/x") or std.mem.eql(u8, path, "/swvpage")) {
        if (std.mem.startsWith(u8, req, "OPTIONS ") and headerValue(req, "access-control-request-method").len > 0) {
            writeAll(conn, "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\nAccess-Control-Allow-Methods: *\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return true;
        }
        v20lCounted(conn, req, target, "200 OK", "Cache-Control: no-store\r\n");
        return true;
    }
    if (std.mem.eql(u8, path, "/swv/c")) {
        // HTTP 캐시에 남는 응답 — 검증자·Accept-Ranges(캐시가 Range 를 제 항목으로 답할 수 있게). 재검증은 304(X-Body 는 보내지 않는다 —
        // 합친 머리가 캐시의 X-Body 를 그대로 지닌다).
        if (headerValue(req, "if-none-match").len > 0) {
            writeAll(conn, "HTTP/1.1 304 Not Modified\r\nETag: \"v20l\"\r\nCache-Control: max-age=600\r\nX-Who-304: 1\r\nConnection: close\r\n\r\n");
            return true;
        }
        if (headerValue(req, "range").len > 0) {
            // 네트워크로 온 Range — 제 셈의 JSON 전체를 206 으로(제 기록의 참값이 그대로 맞는다).
            v20lCounted(conn, req, target, "206 Partial Content", "Cache-Control: no-store\r\nContent-Range: bytes 0-9/10\r\n");
            return true;
        }
        v20lCounted(conn, req, target, "200 OK", "Cache-Control: max-age=600\r\nETag: \"v20l\"\r\nLast-Modified: Mon, 26 Oct 2026 00:00:00 GMT\r\nAccept-Ranges: bytes\r\n");
        return true;
    }
    return false;
}

/// 재검증 7 차(E7): 대조 fetch 여덟 가운데 제 본문이어야 할 아래 끝(하나 둘은 시간에 기대 잃을 수 있다).
const ctl_min: usize = 6;

fn v20lCase(r: *Run, report: Report, session: *u32, comptime name: []const u8, path: []const u8, title: []const u8, ms: u32, sw_min: usize) !void {
    session.* += 1;
    const on = recordOn(r, tab_a, session.*);
    const at = r.begins.items.len;
    try r.navigate(tab_a, path);
    const done = r.pumpTitle(tab_a, title, ms);
    r.pump(4000);
    const t = tally(r, tab_a, at);
    var lb2: [2000]u8 = undefined;
    // 재검증 6 차 D3: 몫 넘김으로 의심해 끝낸 기록은 설명된 것 — 몫이 풀린 뒤의 같은 주소 둘씩(20)은 제 본문을 잡는다(전에는 탭이 어둠이라 0).
    // 재검증 7 차: 같은 주소 둘씩은 겹쳐 잃는다(겹침 규칙) — `v20l-cap` 의 아래 끝은 대조와 다른 주소. 판마다 서비스 워커 갈래 기록 수와 대조의
    // 제 본문(E7 — 워커 CDP 를 끄면 0)의 아래 끝.
    const own_min: usize = if (comptime std.mem.eql(u8, name, "v20l-cap")) ctl_min else 0;
    report(on and done and t.wrong == 0 and t.multi_end == 0 and t.sw_own >= own_min and t.sw >= sw_min and t.ctl_own >= ctl_min, name, bodyLine(&t, done, &lb2));
    try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
    r.pump(500);
    try r.navigate(tab_a, "/blank");
    r.pump(500);
}

fn v20lRun(r: *Run, report: Report, session: *u32) !void {
    var detail: [6000]u8 = undefined;
    var pb: [160]u8 = undefined;
    // 3 회차: 기록 전 W1 + 붙기 전 W2.
    inline for (.{ "v20l-pre", "v20l-tog" }) |name| if (enabled(name)) {
        const tog = comptime std.mem.eql(u8, name, "v20l-tog");
        var tot: Tally = .{};
        var lines: std.ArrayList(u8) = .empty;
        defer lines.deinit(r.gpa);
        var all_done = true;
        for (0..5) |trial| {
            session.* += 1;
            const n = sig.load(.monotonic) + 1;
            if (tog) _ = recordOn(r, tab_a, session.*);
            const at = r.begins.items.len;
            try r.navigate(tab_a, std.fmt.bufPrint(&pb, "/swv/p?c={s}&k={s}{d}x{d}&n={d}", .{ if (tog) "tog" else "pre", name[5..], session.*, trial, n }) catch "");
            const p0 = r.pumpTitle(tab_a, "p0", 30_000);
            r.pump(300);
            if (tog) {
                try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
                session.* += 1;
            }
            // 켬(답을 기다리지 않는다)과 함께 신호 — 페이지가 곧 W2 를 낸다.
            _ = r.states.remove(tab_a);
            try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = true, .session = session.* } });
            sig.store(n, .monotonic);
            const done = r.pumpTitle(tab_a, "bdone", 60_000);
            r.pump(4000);
            const t = tally(r, tab_a, at);
            all_done = all_done and p0 and done;
            tot.total += t.total;
            tot.sw += t.sw;
            tot.sw_own += t.sw_own;
            tot.wrong += t.wrong;
            tot.no_end += t.no_end;
            tot.held += t.held;
            tot.multi_end += t.multi_end;
            tot.ctl += t.ctl;
            tot.ctl_own += t.ctl_own;
            for (t.states, 0..) |c, i| tot.states[i] += c;
            var lb2: [2000]u8 = undefined;
            lines.print(r.gpa, " || trial {d}: {s}", .{ trial, bodyLine(&t, done, &lb2) }) catch {};
            try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
            r.pump(500);
            try r.navigate(tab_a, "/blank");
            r.pump(500);
        }
        var lt: [2000]u8 = undefined;
        // 재검증 7 차(E7): 판마다 대조의 제 본문(다섯 판 — 워커 CDP 를 끄면 0)과 서비스 워커 갈래 기록 수의 아래 끝.
        report(all_done and tot.wrong == 0 and tot.multi_end == 0 and tot.ctl_own >= 5 * ctl_min and tot.sw >= 5 * 8 + 5 * 8, name, std.fmt.bufPrint(&detail, "total: {s}{s}", .{ bodyLine(&tot, all_done, &lt), lines.items[0..@min(lines.items.len, 1400)] }) catch "");
    };
    // 재검증 7 차(E7): 서비스 워커 갈래 기록 수의 아래 끝 — 6 차 회귀 실측(rng 40·redir 30·xo 105·c4 38·upd 61)의 약 3/4 + 대조 여덟.
    if (enabled("v20l-rng")) try v20lCase(r, report, session, "v20l-rng", std.fmt.bufPrint(&pb, "/swv/p?c=rng&k=g{d}", .{session.*}) catch "", "bdone", 60_000, 30 + 8);
    if (enabled("v20l-redir")) try v20lCase(r, report, session, "v20l-redir", std.fmt.bufPrint(&pb, "/swv/p?c=redir&k=r{d}", .{session.*}) catch "", "bdone", 60_000, 22 + 8);
    if (enabled("v20l-xo")) try v20lCase(r, report, session, "v20l-xo", std.fmt.bufPrint(&pb, "/swv/p?c=xo&k=o{d}", .{session.*}) catch "", "bdone", 90_000, 75 + 8);
    if (enabled("v20l-c4")) try v20lCase(r, report, session, "v20l-c4", std.fmt.bufPrint(&pb, "/swv/p?c=c4&k=c{d}", .{session.*}) catch "", "bdone", 90_000, 28 + 8);
    if (enabled("v20l-upd")) try v20lCase(r, report, session, "v20l-upd", std.fmt.bufPrint(&pb, "/swv/u/p?k=u{d}", .{session.*}) catch "", "bdone", 90_000, 45 + 8);
    if (enabled("v20l-tabs")) {
        session.* += 1;
        const on_a = recordOn(r, tab_a, session.*);
        session.* += 1;
        const on_b = recordOn(r, tab_b, session.*);
        const at = r.begins.items.len;
        const n = sig.load(.monotonic) + 1;
        const k = session.*;
        try r.navigate(tab_a, std.fmt.bufPrint(&pb, "/swv/p?c=tabs&k=t{d}&n={d}&x=a", .{ k, n }) catch "");
        const pa = r.pumpTitle(tab_a, "p0", 30_000);
        try r.navigate(tab_b, std.fmt.bufPrint(&pb, "/swv/p?c=tabs&k=t{d}&n={d}&x=b", .{ k, n }) catch "");
        const pbb = r.pumpTitle(tab_b, "p0", 30_000);
        sig.store(n, .monotonic);
        var da = r.pumpTitle(tab_a, "bdone", 90_000);
        const db = r.pumpTitle(tab_b, "bdone", 90_000);
        if (!da) da = r.pumpTitle(tab_a, "bdone", 1000);
        r.pump(4000);
        // 재검증 8 차(7 회차): 탭마다 제 대조(A 는 `actl`, B 는 `bctl`)만 센다.
        const ta = tallyCtl(r, tab_a, at, "actl");
        const tb = tallyCtl(r, tab_b, at, "bctl");
        var la: [2000]u8 = undefined;
        var lbb: [2000]u8 = undefined;
        // 재검증 7 차(E7): 탭마다 대조의 제 본문 — 같은 워커를 두 탭이 함께 보므로 두 탭의 대조가 겹치지 않게 뒤 탭은 앞 탭의 대조 뒤에 연다(`p0`).
        report(on_a and on_b and pa and pbb and da and db and ta.wrong == 0 and tb.wrong == 0 and ta.multi_end == 0 and tb.multi_end == 0 and ta.ctl_own >= ctl_min and tb.ctl_own >= ctl_min and ta.sw >= 30 and tb.sw >= 30, "v20l-tabs", std.fmt.bufPrint(&detail, "tab A: {s} || tab B: {s}", .{ bodyLine(&ta, da, &la), bodyLine(&tb, db, &lbb) }) catch "");
        for ([_]u64{ tab_a, tab_b }) |b| try r.host.send(.{ .net_record = .{ .browser = b, .on = false, .session = 0 } });
        r.pump(500);
        try r.navigate(tab_a, "/blank");
        try r.navigate(tab_b, "/blank");
        r.pump(500);
    }
    if (enabled("v20l-rst")) {
        session.* += 1;
        const on = recordOn(r, tab_a, session.*);
        const at = r.begins.items.len;
        const n0 = sig.load(.monotonic);
        try r.navigate(tab_a, std.fmt.bufPrint(&pb, "/swv/p?c=rst&k=s{d}&n={d}", .{ session.*, n0 }) catch "");
        const p0 = r.pumpTitle(tab_a, "p0", 30_000);
        try r.host.send(.{ .devtools_call = .{ .browser = tab_a, .call = 7001, .method = "ServiceWorker.enable", .params_size = 0 } });
        r.pump(500);
        var ok_trials: usize = 0;
        const rst_n: usize = if (std.c.getenv("V20L_RST")) |v| (std.fmt.parseInt(usize, std.mem.span(v), 10) catch 12) else 12;
        for (1..rst_n + 1) |t| {
            try r.host.send(.{ .devtools_call = .{ .browser = tab_a, .call = @intCast(7100 + t), .method = "ServiceWorker.stopAllWorkers", .params_size = 0 } });
            r.pump(400);
            sig.store(n0 + t, .monotonic);
            var tb: [8]u8 = undefined;
            if (r.pumpTitle(tab_a, std.fmt.bufPrint(&tb, "r{d}", .{t}) catch "", 15_000)) ok_trials += 1;
            r.pump(2600); // 같은 주소(`/swv/x?k=top`)의 창(2 s)을 넘겨 판을 가른다
        }
        r.pump(4000);
        const t = tally(r, tab_a, at);
        var lb2: [2000]u8 = undefined;
        report(on and p0 and ok_trials == rst_n and t.wrong == 0 and t.multi_end == 0 and t.ctl_own >= ctl_min and t.sw >= 8 + rst_n * 2, "v20l-rst", std.fmt.bufPrint(&detail, "restarts {d}/{d} · {s}", .{ ok_trials, rst_n, bodyLine(&t, true, &lb2) }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        try r.navigate(tab_a, "/blank");
        r.pump(500);
    }
    if (enabled("v20l-cap")) try v20lCase(r, report, session, "v20l-cap", std.fmt.bufPrint(&pb, "/swv/p?c=cap&k=h{d}", .{session.*}) catch "", "bdone", 90_000, 8 + 128);
    if (enabled("v20l-vsleak")) {
        // 7 회차: 기록하던 탭을 끄지 않고 닫기를 33 번(registry 32 넘게) — 그 뒤 새 탭의 서비스 워커 본문이 잡히나(VS 자리).
        var closed_n: usize = 0;
        for (0..33) |i| {
            const id: u64 = 500 + i;
            try openTab(r, id);
            session.* += 1;
            _ = recordOn(r, id, session.*);
            try r.host.send(.{ .destroy_browser = id });
            const Closed = struct {
                fn got(x: *Run, bid: u64) bool {
                    return x.closed.contains(bid);
                }
            };
            if (r.waitFor(5000, id, Closed.got)) closed_n += 1;
        }
        const id_new: u64 = 600;
        try openTab(r, id_new);
        session.* += 1;
        const on = recordOn(r, id_new, session.*);
        const at = r.begins.items.len;
        _ = r.titles.remove(id_new);
        var u: [256]u8 = undefined;
        try r.host.send(.{ .navigate = .{ .browser = id_new, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/swv/p?c=pt&k=vl{d}", .{ port, session.* }) } });
        const done = r.pumpTitle(id_new, "bdone", 60_000);
        r.pump(4000);
        const t = tally(r, id_new, at);
        var lb2: [2000]u8 = undefined;
        // 재검증 7 차(v20m 20 회차 ①): 앞 검증 실측 20/20 — 하나만 잡아도 지나던 아래 끝을 18 로.
        report(on and done and closed_n == 33 and t.wrong == 0 and t.sw_own >= 18, "v20l-vsleak", std.fmt.bufPrint(&detail, "closed while recording {d}/33 · new tab: {s}", .{ closed_n, bodyLine(&t, done, &lb2) }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = id_new, .on = false, .session = 0 } });
        r.pump(300);
        try r.host.send(.{ .destroy_browser = id_new });
        r.pump(500);
    }
    if (enabled("v20l-ctrl")) {
        // 대조: 같은 새 탭 꼴을 닫기 없이.
        const id_new: u64 = 700;
        try openTab(r, id_new);
        session.* += 1;
        const on = recordOn(r, id_new, session.*);
        const at = r.begins.items.len;
        _ = r.titles.remove(id_new);
        var u: [256]u8 = undefined;
        try r.host.send(.{ .navigate = .{ .browser = id_new, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/swv/p?c=pt&k=vc{d}", .{ port, session.* }) } });
        const done = r.pumpTitle(id_new, "bdone", 60_000);
        r.pump(4000);
        const t = tally(r, id_new, at);
        var lb2: [2000]u8 = undefined;
        report(on and done and t.wrong == 0 and t.sw_own >= 18, "v20l-ctrl", bodyLine(&t, done, &lb2));
        try r.host.send(.{ .net_record = .{ .browser = id_new, .on = false, .session = 0 } });
        r.pump(300);
        try r.host.send(.{ .destroy_browser = id_new });
        r.pump(500);
    }
    if (enabled("v20l-detach")) {
        // 켬·끔 열 번(답을 기다리지 않는다) → 끔, 켬 직후 끔 — 그 뒤 놀리면 멈춰야 한다.
        session.* += 1;
        const armed = try armA(r, session.*);
        for (0..10) |i| {
            session.* += 1;
            try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = true, .session = session.* } });
            r.pump(@intCast(2 + i * 3));
            try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
            r.pump(@intCast(1 + i));
        }
        session.* += 1;
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = true, .session = session.* } });
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(1500);
        const x = try idleThenProbe(r);
        var lb: [400]u8 = undefined;
        report(armed and x.probed and x.stopped, "v20l-detach", std.fmt.bufPrint(&detail, "flap ×10 then on+off at once: {s}", .{idleLine(x, &lb)}) catch "");
    }
}

// ── v20m(W9d② 재검증 6 차 고침 e3c8cdba9 의 검증 1–10 회차 탐침 — `SWCDP_ONLY=v20m-…`) ─────────────────────────────────────────
//   v20m-t9     (1 회차) 같은 출처를 지켜보는 탭 8 개 뒤의 아홉째 탭 R 이 기록한다 — 문은 서비스 워커 갈래 기록을 앞 `max_targets`(8) 탭에만
//               붙여 R 의 표에는 W1 의 기록이 없다(W1 은 R 의 워커 세션에 보인다). 앞 탭 하나의 지켜보기를 끄면 R 이 대상에 들어 같은 주소 W2 의
//               기록이 R 에 온다. W2 가 먼저 응답한다(서버 80 ms) — 남는 W 를 볼 W2 가 빠진 뒤 W1(2.4 s)이 응답한다.
//   v20m-t9n    (1 회차) 같은 꼴 — 앞 탭이 다른 출처(localhost)로 이동해 R 이 대상에 든다.
//   v20m-tabs3  (3 회차) 두 탭이 같은 워커의 같은 주소 셋을 7 ms 마다 받는 동안, 서로 다른 때 켜고 A 는 끔·켬을 다섯 번.
//   v20m-nav    (9 회차) 기록하는 탭이 127.0.0.1 ↔ localhost(각자 워커)를 여덟 번 오가며, 다스려진 문서가 열리자마자 같은 주소 둘.

const t9_helpers = [_]u64{ 810, 811, 812, 813, 814, 815, 816, 817 };
const t9_r: u64 = 820;

fn watchSet(r: *Run, id: u64, on: bool) !void {
    try r.host.send(.{ .net_watch = if (on) .{ .browser = id, .on = true, .full = true, .any_host = true } else .{ .browser = id, .on = false } });
}

fn v20mT9(r: *Run, report: Report, session: *u32, comptime name: []const u8, nav: bool) !void {
    var detail: [6000]u8 = undefined;
    var pb: [200]u8 = undefined;
    // tab_a·tab_b 의 지켜보기를 잠시 끈다(앞 자리 — 셈이 흐려진다).
    try watchSet(r, tab_a, false);
    try watchSet(r, tab_b, false);
    for (t9_helpers) |id| try openTab(r, id);
    try openTab(r, t9_r);
    session.* += 1;
    const on = recordOn(r, t9_r, session.*);
    const at = r.begins.items.len;
    const n0 = sig.load(.monotonic);
    const tn: usize = if (std.c.getenv("V20M_T9N")) |v| (std.fmt.parseInt(usize, std.mem.span(v), 10) catch 6) else 6;
    _ = r.titles.remove(t9_r);
    try r.navigate(t9_r, std.fmt.bufPrint(&pb, "/swv/p?c=t9&k={s}{d}&n={d}&tn={d}", .{ name[5..], session.*, n0, tn }) catch "");
    var ok: usize = 0;
    for (1..tn + 1) |j| {
        var tb: [8]u8 = undefined;
        if (!r.pumpTitle(t9_r, std.fmt.bufPrint(&tb, "w{d}", .{j}) catch "", 30_000)) break;
        r.pump(150);
        if (nav) {
            var u: [256]u8 = undefined;
            try r.host.send(.{ .navigate = .{ .browser = t9_helpers[0], .url = try std.fmt.bufPrint(&u, "http://localhost:{d}/blank", .{port}) } });
            r.pump(500);
        } else {
            try watchSet(r, t9_helpers[0], false);
            r.pump(40);
        }
        sig.store(n0 + 2 * j - 1, .monotonic);
        const d = r.pumpTitle(t9_r, std.fmt.bufPrint(&tb, "d{d}", .{j}) catch "", 15_000);
        if (nav) {
            try r.navigate(t9_helpers[0], "/blank");
            r.pump(500);
        } else {
            try watchSet(r, t9_helpers[0], true);
            r.pump(40);
        }
        if (d) ok += 1;
        sig.store(n0 + 2 * j, .monotonic);
    }
    r.pump(4000);
    const t = tally(r, t9_r, at);
    var lb2: [2000]u8 = undefined;
    report(on and ok == tn and t.wrong == 0 and t.multi_end == 0 and t.sw >= tn * 2, name, std.fmt.bufPrint(&detail, "9th watcher records, trials {d}/{d}: {s}", .{ ok, tn, bodyLine(&t, ok == tn, &lb2) }) catch "");
    try r.host.send(.{ .net_record = .{ .browser = t9_r, .on = false, .session = 0 } });
    r.pump(300);
    for (t9_helpers) |id| try r.host.send(.{ .destroy_browser = id });
    try r.host.send(.{ .destroy_browser = t9_r });
    r.pump(800);
    try watchSet(r, tab_a, true);
    try watchSet(r, tab_b, true);
    r.pump(200);
}

fn v20mRun(r: *Run, report: Report, session: *u32) !void {
    var detail: [6000]u8 = undefined;
    var pb: [200]u8 = undefined;
    if (enabled("v20m-t9n")) try v20mT9(r, report, session, "v20m-t9n", true);
    if (enabled("v20m-t9,") or (std.c.getenv("SWCDP_ONLY") == null) or std.mem.endsWith(u8, std.mem.span(std.c.getenv("SWCDP_ONLY").?), "v20m-t9")) try v20mT9(r, report, session, "v20m-t9", false);
    if (enabled("v20m-tabs3")) {
        // 3 회차: 두 탭이 같은 워커를 — A 는 0 ms 에, B 는 23 ms 뒤에 켜고, A 는 150 ms 마다 끔·켬 다섯 번(끔 → 3 ms → 켬), 끝에 B 를 끔·켬.
        const n0 = sig.load(.monotonic) + 1;
        const at = r.begins.items.len;
        _ = r.titles.remove(tab_a);
        _ = r.titles.remove(tab_b);
        try r.navigate(tab_a, std.fmt.bufPrint(&pb, "/swv/p?c={s}&k=ta{d}&n={d}", .{ if (std.c.getenv("V20M_STRM2") != null) "strm2" else "strm", session.*, n0 }) catch "");
        try r.navigate(tab_b, std.fmt.bufPrint(&pb, "/swv/p?c={s}&k=tb{d}&n={d}", .{ if (std.c.getenv("V20M_STRM2") != null) "strm2" else "strm", session.*, n0 }) catch "");
        const pa = r.pumpTitle(tab_a, "p0", 30_000);
        const pbb = r.pumpTitle(tab_b, "p0", 30_000);
        sig.store(n0, .monotonic);
        r.pump(120);
        session.* += 1;
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = true, .session = session.* } });
        r.pump(23);
        session.* += 1;
        try r.host.send(.{ .net_record = .{ .browser = tab_b, .on = true, .session = session.* } });
        for (0..5) |_| {
            r.pump(150);
            try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
            r.pump(3);
            session.* += 1;
            try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = true, .session = session.* } });
        }
        r.pump(200);
        try r.host.send(.{ .net_record = .{ .browser = tab_b, .on = false, .session = 0 } });
        session.* += 1;
        try r.host.send(.{ .net_record = .{ .browser = tab_b, .on = true, .session = session.* } });
        const da = r.pumpTitle(tab_a, "bdone", 60_000);
        const db = r.pumpTitle(tab_b, "bdone", 60_000);
        r.pump(4000);
        const ta = tally(r, tab_a, at);
        const tb = tally(r, tab_b, at);
        var la: [2000]u8 = undefined;
        var lbb: [2000]u8 = undefined;
        report(pa and pbb and da and db and ta.wrong == 0 and tb.wrong == 0 and ta.multi_end == 0 and tb.multi_end == 0 and ta.sw >= 60 and tb.sw >= 60, "v20m-tabs3", std.fmt.bufPrint(&detail, "tab A: {s} || tab B: {s}", .{ bodyLine(&ta, da, &la), bodyLine(&tb, db, &lbb) }) catch "");
        for ([_]u64{ tab_a, tab_b }) |b| try r.host.send(.{ .net_record = .{ .browser = b, .on = false, .session = 0 } });
        r.pump(500);
        try r.navigate(tab_a, "/blank");
        try r.navigate(tab_b, "/blank");
        r.pump(500);
    }
    if (enabled("v20m-rstb")) {
        // 2 회차: 워커를 멈추고(ServiceWorker.stopAllWorkers) 같은 주소 둘씩 스무 쌍을 한꺼번에.
        session.* += 1;
        const on = recordOn(r, tab_a, session.*);
        const at = r.begins.items.len;
        const n0 = sig.load(.monotonic);
        try r.navigate(tab_a, std.fmt.bufPrint(&pb, "/swv/p?c=rstb&k=rb{d}&n={d}", .{ session.*, n0 }) catch "");
        const p0 = r.pumpTitle(tab_a, "p0", 30_000);
        try r.host.send(.{ .devtools_call = .{ .browser = tab_a, .call = 7001, .method = "ServiceWorker.enable", .params_size = 0 } });
        r.pump(500);
        var ok_trials: usize = 0;
        const n_t: usize = if (std.c.getenv("V20M_RSTB")) |v| (std.fmt.parseInt(usize, std.mem.span(v), 10) catch 40) else 40;
        for (1..n_t + 1) |t| {
            try r.host.send(.{ .devtools_call = .{ .browser = tab_a, .call = @intCast(7300 + t), .method = "ServiceWorker.stopAllWorkers", .params_size = 0 } });
            r.pump(400);
            sig.store(n0 + t, .monotonic);
            var tb: [8]u8 = undefined;
            if (r.pumpTitle(tab_a, std.fmt.bufPrint(&tb, "r{d}", .{t}) catch "", 15_000)) ok_trials += 1;
            r.pump(300);
        }
        r.pump(4000);
        const t = tally(r, tab_a, at);
        var lb2: [2000]u8 = undefined;
        report(on and p0 and ok_trials == n_t and t.wrong == 0 and t.multi_end == 0 and t.sw >= n_t * 30, "v20m-rstb", std.fmt.bufPrint(&detail, "restarts {d}/{d} · {s}", .{ ok_trials, n_t, bodyLine(&t, true, &lb2) }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        try r.navigate(tab_a, "/blank");
        r.pump(500);
    }
    if (enabled("v20m-rstc")) {
        // 2 회차: 맨 위 fetch 무더기 뒤의 TOP(시작을 잃는다)과 같은 주소의 그대로 넘김 둘(보인다).
        session.* += 1;
        const on = recordOn(r, tab_a, session.*);
        const at = r.begins.items.len;
        const n0 = sig.load(.monotonic);
        try r.navigate(tab_a, std.fmt.bufPrint(&pb, "/swv/b/p?k=rc{d}&n={d}", .{ session.*, n0 }) catch "");
        const p0 = r.pumpTitle(tab_a, "p0", 30_000);
        try r.host.send(.{ .devtools_call = .{ .browser = tab_a, .call = 7001, .method = "ServiceWorker.enable", .params_size = 0 } });
        r.pump(500);
        var ok_trials: usize = 0;
        const n_t: usize = if (std.c.getenv("V20M_RSTC")) |v| (std.fmt.parseInt(usize, std.mem.span(v), 10) catch 40) else 40;
        for (1..n_t + 1) |t| {
            if (std.c.getenv("V20M_FRESH") != null) {
                // 판마다 새 기록 세션(앞 판의 어둠을 지운다 — 판을 서로 떼어 잰다).
                try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
                session.* += 1;
                _ = recordOn(r, tab_a, session.*);
            }
            try r.host.send(.{ .devtools_call = .{ .browser = tab_a, .call = @intCast(7500 + t), .method = "ServiceWorker.stopAllWorkers", .params_size = 0 } });
            r.pump(400);
            sig.store(n0 + t, .monotonic);
            var tb: [8]u8 = undefined;
            if (r.pumpTitle(tab_a, std.fmt.bufPrint(&tb, "r{d}", .{t}) catch "", 15_000)) ok_trials += 1;
            r.pump(2300); // 같은 주소 창(2 s)을 넘겨 판을 가른다
        }
        r.pump(4000);
        const t = tally(r, tab_a, at);
        var lb2: [2000]u8 = undefined;
        report(on and p0 and ok_trials == n_t and t.wrong == 0 and t.multi_end == 0 and t.sw >= n_t * 20, "v20m-rstc", std.fmt.bufPrint(&detail, "restarts {d}/{d} · {s}", .{ ok_trials, n_t, bodyLine(&t, true, &lb2) }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        try r.navigate(tab_a, "/blank");
        r.pump(500);
    }
    if (enabled("v20m-navn")) {
        // 9 회차: 기록하는 A 가 127.0.0.1/blank → localhost/swv/n/p 로 이동 — 이동이 localhost 워커를 깨우고 그 맨 위 TOP 은 주소 바뀜 앞에 나간다.
        // 문서는 곧 같은 주소를 그대로 넘김(1.5 s)과 TOP 메모로 받는다. 판마다 워커를 멈춘다.
        var u: [256]u8 = undefined;
        _ = r.titles.remove(tab_a);
        try r.host.send(.{ .navigate = .{ .browser = tab_a, .url = try std.fmt.bufPrint(&u, "http://localhost:{d}/swv/n/p?k=reg", .{port}) } });
        _ = r.pumpTitle(tab_a, "nreg", 20_000);
        r.pump(500);
        session.* += 1;
        const on = recordOn(r, tab_a, session.*);
        const at = r.begins.items.len;
        try r.host.send(.{ .devtools_call = .{ .browser = tab_a, .call = 7001, .method = "ServiceWorker.enable", .params_size = 0 } });
        var ok: usize = 0;
        const n_t: usize = if (std.c.getenv("V20M_NAVN")) |v| (std.fmt.parseInt(usize, std.mem.span(v), 10) catch 40) else 40;
        for (0..n_t) |i| {
            try r.navigate(tab_a, "/blank");
            r.pump(300);
            try r.host.send(.{ .devtools_call = .{ .browser = tab_a, .call = @intCast(7700 + i), .method = "ServiceWorker.stopAllWorkers", .params_size = 0 } });
            r.pump(400);
            _ = r.titles.remove(tab_a);
            try r.host.send(.{ .navigate = .{ .browser = tab_a, .url = try std.fmt.bufPrint(&u, "http://localhost:{d}/swv/n/p?k=n{d}", .{ port, i }) } });
            if (r.pumpTitle(tab_a, "nd", 15_000)) ok += 1;
            r.pump(2100);
        }
        r.pump(4000);
        const t = tally(r, tab_a, at);
        var lb2: [2000]u8 = undefined;
        report(on and ok == n_t and t.wrong == 0 and t.multi_end == 0 and t.sw >= n_t, "v20m-navn", std.fmt.bufPrint(&detail, "navigations {d}/{d}: {s}", .{ ok, n_t, bodyLine(&t, ok == n_t, &lb2) }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        try r.navigate(tab_a, "/blank");
        r.pump(500);
    }
    if (enabled("v20m-nav")) {
        // 9 회차: 127.0.0.1 ↔ localhost 를 여덟 번(각 문서가 다스려지자마자 같은 주소 둘).
        session.* += 1;
        const on = recordOn(r, tab_a, session.*);
        const at = r.begins.items.len;
        var ok: usize = 0;
        for (0..16) |i| {
            var u: [256]u8 = undefined;
            const host_s: []const u8 = if (i % 2 == 0) "localhost" else "127.0.0.1";
            _ = r.titles.remove(tab_a);
            try r.host.send(.{ .navigate = .{ .browser = tab_a, .url = try std.fmt.bufPrint(&u, "http://{s}:{d}/swv/q?k=nv{d}i{d}", .{ host_s, port, session.*, i }) } });
            if (r.pumpTitle(tab_a, "qd", 20_000)) ok += 1;
        }
        r.pump(4000);
        const t = tally(r, tab_a, at);
        var lb2: [2000]u8 = undefined;
        report(on and ok >= 14 and t.wrong == 0 and t.multi_end == 0 and t.sw >= 20, "v20m-nav", std.fmt.bufPrint(&detail, "navigations done {d}/16: {s}", .{ ok, bodyLine(&t, ok == 16, &lb2) }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        try r.navigate(tab_a, "/blank");
        r.pump(500);
    }
}

// ── v20n(W9d② 재검증 7 차 `34df5f03c` 적대 검증 1–10 회차 탐침 — `SWCDP_ONLY=v20n-…` 로 **고를 때만** 돈다) ─────────────────────────────
//
// 참값은 위와 같다(기록 제 응답 머리의 `X-Body`). 워커는 `/swz/` 범위의 `swz_js` 하나가 x-who 로 고른다(그 밖은 그대로 넘김).
//   v20n-r1   (1 회차) 열쇠 가장자리 — 조각만 다른 같은 주소 둘·같은 주소 HEAD + GET·쿼리 차례만 다른 주소 둘·302 를 따라간 fetch 와 그 끝 주소·
//             POST → 303 → GET 과 그 끝 주소·페이지 GET 에 워커 HEAD 응답·페이지 HEAD 에 워커 GET 응답(같은 주소의 그대로 넘김과 함께)·혼자인 대조
//   v20n-r2   (2 회차) 기록 전에 나간 캐시되는 fetch(서버 1.5 s)와 기록 켬 뒤의 같은 주소 fetch(HTTP 캐시 쓰기를 함께 쓸 수 있다 — 같은 τ) 10 판
//   v20n-r2n  (2 회차 대조) 같은 꼴을 no-store 로
//   v20n-r3   (3 회차) 같은 주소 둘 겹침(하나는 `V20N_HOLD` ms — 기본 9 700) 동안 다른 주소 24 개와 같은 주소 셋째 — 설명 미루기
//   v20n-r8   (8 회차) 캐시 항목에 대해 워커의 no-cache(304)·적중·페이지 HEAD·OPTIONS·그 주소로의 302 를 한꺼번에

const swz_js = "self.addEventListener('install',function(){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});var IF={};" ++
    "self.addEventListener('fetch',function(e){var q=e.request;if(q.mode=='navigate')return;var u=new URL(q.url);var w=q.headers.get('x-who')||u.searchParams.get('w')||'';" ++
    "if(w=='head'){e.respondWith(fetch(u.href,{method:'HEAD',headers:{'x-who':'HEADW'},cache:'no-store'}));return}" ++
    "if(w=='gfh'){e.respondWith(fetch(u.href,{headers:{'x-who':'GFH'},cache:'no-store'}));return}" ++
    "if(w=='rv'){e.respondWith(fetch(u.href,{headers:{'x-who':'RV'},cache:'no-cache'}));return}" ++
    "if(w=='hit'){e.respondWith(fetch(u.href,{headers:{'x-who':'HIT'}}));return}" ++
    // 재검증 8 차(R-1 — `v20n-r1h`): 앞 fetch W1 을 같이 쓰고(묶기), 같이 쓰는 때 같은 주소의 HEAD(coh)·Range(cor)를 따로 받는다 — HTTP 캐시의 한
    // 쓰기를 나눠 같은 τ 가 된다(r2h 실측). W1 의 응답은 host 가 버린다(`MARU_WEB_TEST_SW_LOSE`) — 보이는 것은 τ 를 나눈 HEAD·Range W 뿐이다.
    "if(w=='coh'||w=='cor'){var k=u.href;var j1=IF[k];if(!j1){j1=IF[k]=fetch(k,{headers:{'x-who':'W1'},cache:'default'}).then(function(r){setTimeout(function(){delete IF[k]},0);return r})}" ++
    "else{fetch(k,w=='coh'?{method:'HEAD',headers:{'x-who':'SIDEH'},cache:'default'}:{headers:{'x-who':'SIDER','Range':'bytes=0-3'},cache:'default'}).then(function(r){return r.text()}).catch(function(){})}" ++
    "e.respondWith(j1.then(function(r){return r.clone()}));return}" ++
    "e.respondWith(fetch(q))});";

const swz_page_body = "reg('/swz/sw.js','/swz/').then(async function(){if(!navigator.serviceWorker.controller){location.reload();return}" ++
    "if(C=='r1'){await CTL();" ++
    "for(var j=0;j<20;j++){var u='/swz/x?k='+K+'f'+j;await Promise.all([F(u+'#a',{'x-who':'pt'}),F(u+'#b',{'x-who':'pt'})]);await S(30)}" ++
    "for(var j=0;j<20;j++){var u='/swz/x?k='+K+'h'+j;await Promise.all([F(u,{'x-who':'pt'},{method:'HEAD'}),F(u,{'x-who':'pt'})]);await S(30)}" ++
    "for(var j=0;j<20;j++){await Promise.all([W('/swz/x?k='+K+'q'+j+'&a=1&b=2','pt'),W('/swz/x?k='+K+'q'+j+'&b=2&a=1','pt')]);await S(30)}" ++
    "for(var j=0;j<15;j++){await Promise.all([W('/swz/r?k='+K+'r'+j,'pt'),W('/swz/x?k='+K+'r'+j+'&rd=1','pt')]);await S(30)}" ++
    "for(var j=0;j<15;j++){await Promise.all([F('/swz/r303?k='+K+'s'+j,{'x-who':'pt'},{method:'POST',body:'x'}),W('/swz/x?k='+K+'s'+j+'&rd=1','pt')]);await S(30)}" ++
    "for(var j=0;j<15;j++){var u='/swz/x?k='+K+'g'+j;await Promise.all([W(u,'head'),W(u,'pt')]);await S(30)}" ++
    "for(var j=0;j<15;j++){var u='/swz/x?k='+K+'e'+j;await Promise.all([F(u,{'x-who':'gfh'},{method:'HEAD'}),W(u,'pt')]);await S(30)}" ++
    "for(var j=0;j<15;j++){await F('/swz/x?k='+K+'e2'+j,{'x-who':'gfh'},{method:'HEAD'});await S(30)}" ++
    "for(var j=0;j<15;j++){await W('/swz/x?k='+K+'g2'+j,'head');await S(30)}" ++
    "for(var j=0;j<15;j++){await W('/swz/r?k='+K+'r2'+j,'pt');await S(30)}" ++
    "for(var j=0;j<15;j++){await W('/swz/x?k='+K+'solo'+j,'pt');await S(30)}}" ++
    "if(C=='r2'||C=='r2n'||C=='r2s'){var CM=C!='r2n'?'default':'no-store';var DD=P.get('d')||'1500';document.title='p0';for(var j=1;j<=10;j++){var u='/swz/'+(C!='r2n'?'c':'x')+'?k='+K+'c'+j+'&d='+DD;" ++
    "var a=F(u,{'x-who':'pt','x-d':DD},{cache:CM});document.title='a'+j;await SIG(N+2*j-1);var b=F(u,{'x-who':'pt'},{cache:CM});await Promise.all([a,b]);await S(300);" ++
    "var E=performance.getEntriesByName(location.origin+u).map(function(x){return Math.round(x.workerStart)+':'+Math.round(x.startTime)+':'+Math.round(x.responseStart)}).join(',');await fetch('/swz/log?j='+j+'&e='+E,{cache:'no-store'}).catch(function(){});" ++
    "document.title='b'+j;await SIG(N+2*j)}}" ++
    // 재검증 8 차(R-1): 판마다 기록 끔에서 W1(캐시되는 주소, 서버 1.5 s)을 내고 → 켬 → 같은 주소를 묶기로(그때 워커가 HEAD·Range 를 따로).
    "if(C=='r1h'){for(var j=1;j<=10;j++){var md=(j%2)?'coh':'cor';var u='/swz/c?k='+K+'lose1x'+j+'&d=1500';var a=F(u,{'x-who':md},{cache:'default'});document.title='a'+j;await SIG(N+2*j-1);" ++
    "var b=F(u,{'x-who':md},{cache:'default'});await Promise.all([a,b]);await S(300);document.title='b'+j;await SIG(N+2*j)}}" ++
    "if(C=='r2h'){for(var j=0;j<10;j++){var u='/swz/c?k='+K+'h'+j+'&d=1500';var a=F(u,{'x-who':'pt'},{cache:'default'});await S(300);" ++
    "var b=F(u,{'x-who':'pt'},{method:'HEAD',cache:'default'});var c=F(u+'&rg=1',{'x-who':'pt'},{cache:'default'});await S(200);var d=F(u,{'x-who':'pt','Range':'bytes=0-3'},{cache:'default'});await Promise.all([a,b,c,d]);await S(100)}}" ++
    "if(C=='r3'){await CTL();var HD=P.get('h')||'9700';var u='/swz/x?k='+K+'d';var A=F(u,{'x-who':'pt','x-d':HD});await S(3);var B=F(u,{'x-who':'pt','x-d':'50'});" ++
    "var L=[];for(var i=0;i<24;i++){L.push(W('/swz/x?k='+K+'o'+i,'pt'));await S(500);if(i==10){L.push(F(u,{'x-who':'pt','x-d':'30'}))}}" ++
    "await Promise.all([A,B].concat(L));await S(2500);await CTL()}" ++
    "if(C=='r8'){await CTL();for(var j=0;j<10;j++){var cu='/swz/c?k='+K+'g'+j;await F(cu,{'x-who':'pt'},{cache:'default'});await S(30);" ++
    "await Promise.all([W(cu,'rv'),F(cu,{'x-who':'hit'},{cache:'default'}),F(cu,{'x-who':'pt'},{method:'HEAD',cache:'default'}),F(cu,{'x-who':'pt'},{method:'OPTIONS'}),F('/swz/rc?k='+K+'g'+j,{'x-who':'pt'},{cache:'default'})]);await S(50)}" ++
    "await S(500);await CTL()}" ++
    // 재검증 9 차(검증 v20o 5 회차 탐침 → 기준): 기록 중 지켜보기 끔·켬을 빠르게 — 판정자가 `w0` 뒤에 A 의 net_watch 를 여섯 번 끔·켬, 그동안·그 뒤
    // 다른 주소 fetch 40 과 대조.
    "if(C=='wof'){await CTL();document.title='w0';await SIG(N+1);for(var j=0;j<40;j++){await W('/swz/x?k='+K+'o'+j,'pt');await S(25)}await CTL()}" ++
    "await S(1500);document.title='bdone'})";

fn v20nServe(conn: c_int, req: []const u8, target: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/swz/")) return false;
    if (std.mem.eql(u8, path, "/swz/log")) {
        std.debug.print("V20N-LOG {s}\n", .{target});
        reply(conn, "text/plain", "", "ok");
        return true;
    }
    if (std.mem.eql(u8, path, "/swz/sw.js")) {
        reply(conn, "text/javascript", "", swz_js);
        return true;
    }
    if (std.mem.eql(u8, path, "/swz/p")) {
        reply(conn, html, "", "<!doctype html><title>z</title><script>" ++ swv_page_js ++ swz_page_body ++ "</script>z");
        return true;
    }
    if (std.mem.eql(u8, path, "/swz/r") or std.mem.eql(u8, path, "/swz/r303") or std.mem.eql(u8, path, "/swz/rc")) {
        var lb: [300]u8 = undefined;
        const to = if (std.mem.eql(u8, path, "/swz/rc")) std.fmt.bufPrint(&lb, "Location: /swz/c?k={s}\r\n", .{queryValue(target, "k")}) catch "" else std.fmt.bufPrint(&lb, "Location: /swz/x?k={s}&rd=1\r\n", .{queryValue(target, "k")}) catch "";
        replyStatus(conn, if (std.mem.eql(u8, path, "/swz/r303")) "303 See Other" else "302 Found", "text/plain", to, "");
        return true;
    }
    if (std.mem.eql(u8, path, "/swz/x")) {
        if (std.mem.startsWith(u8, req, "OPTIONS ") and headerValue(req, "access-control-request-method").len > 0) {
            writeAll(conn, "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\nAccess-Control-Allow-Methods: *\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return true;
        }
        v20lCounted(conn, req, target, "200 OK", "Cache-Control: no-store\r\n");
        return true;
    }
    if (std.mem.eql(u8, path, "/swz/c")) {
        // HTTP 캐시에 남는 응답(Range 는 알리지 않는다 — 캐시가 제 항목의 앞부분으로 답하면 참값 꼴이 갈린다). 재검증은 304.
        if (headerValue(req, "if-modified-since").len > 0 or headerValue(req, "if-none-match").len > 0) {
            writeAll(conn, "HTTP/1.1 304 Not Modified\r\nCache-Control: max-age=600\r\nLast-Modified: Mon, 26 Oct 2026 00:00:00 GMT\r\nConnection: close\r\n\r\n");
            return true;
        }
        v20lCounted(conn, req, target, "200 OK", "Cache-Control: max-age=600\r\nLast-Modified: Mon, 26 Oct 2026 00:00:00 GMT\r\n");
        return true;
    }
    return false;
}

/// 「고를 때만」 — `SWCDP_ONLY` 가 그 이름을 담을 때만(기준 판정 `--review-body-swcdp` 에는 들지 않는다).
fn v20nPicked(name: []const u8) bool {
    const only = std.c.getenv("SWCDP_ONLY") orelse return false;
    return std.mem.indexOf(u8, std.mem.span(only), name) != null;
}

/// 판 하나 — 새 기록 세션으로 `/swz/p?c=…` 를 열고 `bdone` 까지.
fn v20nCase(r: *Run, report: Report, session: *u32, comptime name: []const u8, c: []const u8, extra: []const u8, ms: u32, sw_min: usize, own_min: usize) !void {
    var pb: [256]u8 = undefined;
    session.* += 1;
    const on = recordOn(r, tab_a, session.*);
    const at = r.begins.items.len;
    try r.navigate(tab_a, std.fmt.bufPrint(&pb, "/swz/p?c={s}&k=z{s}{d}{s}", .{ c, c, session.*, extra }) catch "");
    const done = r.pumpTitle(tab_a, "bdone", ms);
    r.pump(4000);
    const t = tally(r, tab_a, at);
    var lb2: [2400]u8 = undefined;
    report(on and done and t.wrong == 0 and t.multi_end == 0 and t.sw >= sw_min and t.sw_own >= own_min, name, bodyLine(&t, done, &lb2));
    try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
    r.pump(500);
    try r.navigate(tab_a, "/blank");
    r.pump(500);
}

fn v20nRun(r: *Run, report: Report, session: *u32, log_path: ?[:0]const u8) !void {
    var detail: [6000]u8 = undefined;
    var lb_r1h: [320]u8 = undefined;
    var pb: [256]u8 = undefined;
    if (v20nPicked("v20n-r1")) try v20nCase(r, report, session, "v20n-r1", "r1", "", 120_000, 150, 12);
    // 재검증 8 차(R-1): `v20n-r1h` 는 기준 판정이다(고르지 않아도 돈다).
    inline for (.{ "v20n-r1h", "v20n-r2n", "v20n-r2s", "v20n-r2" }) |nm| if (if (comptime std.mem.eql(u8, nm, "v20n-r1h")) enabled(nm) else (v20nPicked(nm ++ ",") or (std.mem.endsWith(u8, std.mem.span(std.c.getenv("SWCDP_ONLY") orelse ""), nm)))) {
        // 기록 끔에서 첫 fetch(기록 전) → 켬 → 같은 주소 둘째 fetch. 판마다 새 기록 세션.
        const c = nm[5..];
        const n0 = sig.load(.monotonic);
        _ = r.titles.remove(tab_a);
        const dd = std.c.getenv("V20N_D") orelse "1500";
        try r.navigate(tab_a, std.fmt.bufPrint(&pb, "/swz/p?c={s}&k=z{s}{d}&n={d}&d={s}", .{ c, c, session.*, n0, std.mem.span(dd) }) catch "");
        // 2 회차: 첫 판의 W_a 는 그 워커의 첫 붙기 앞에 나간다 — `r2s` 는 판마다 워커를 멈춰(기록 끔 동안) 매 판을 그 꼴로 만든다.
        const stop_each = comptime std.mem.eql(u8, nm, "v20n-r2s");
        if (stop_each) try r.host.send(.{ .devtools_call = .{ .browser = tab_a, .call = 8001, .method = "ServiceWorker.enable", .params_size = 0 } });
        const p0 = true;
        var tot: Tally = .{};
        var ok: usize = 0;
        const at_all = r.begins.items.len;
        const log0 = logSize(log_path);
        // 재검증 11 차(LOW-J3): 판마다 로그 자리를 끊어 판의 막은 까닭을 따로 센다(합이 아니라 — 한 판에 몰려도 서던 것을 조였다).
        var run_from: [11]usize = undefined;
        var run_ok: [11]bool = @splat(false);
        for (1..11) |j| {
            run_from[j - 1] = logSize(log_path);
            var tb: [8]u8 = undefined;
            if (!r.pumpTitle(tab_a, std.fmt.bufPrint(&tb, "a{d}", .{j}) catch "", 15_000)) break;
            r.pump(100);
            session.* += 1;
            _ = recordOn(r, tab_a, session.*);
            const at = r.begins.items.len;
            r.pump(400);
            sig.store(n0 + 2 * j - 1, .monotonic);
            if (r.pumpTitle(tab_a, std.fmt.bufPrint(&tb, "b{d}", .{j}) catch "", 15_000)) {
                ok += 1;
                run_ok[j - 1] = true;
            }
            r.pump(3000);
            const t = tally(r, tab_a, at);
            tot.total += t.total;
            tot.sw += t.sw;
            tot.sw_own += t.sw_own;
            tot.wrong += t.wrong;
            tot.multi_end += t.multi_end;
            tot.no_end += t.no_end;
            for (t.states, 0..) |v, i| tot.states[i] += v;
            if (t.notes_len > 0 and tot.notes_len + t.notes_len < tot.notes.len) {
                @memcpy(tot.notes[tot.notes_len .. tot.notes_len + t.notes_len], t.notes[0..t.notes_len]);
                tot.notes_len += t.notes_len;
            }
            try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
            r.pump(300);
            if (stop_each) {
                try r.host.send(.{ .devtools_call = .{ .browser = tab_a, .call = @intCast(8100 + j), .method = "ServiceWorker.stopAllWorkers", .params_size = 0 } });
                r.pump(600);
            }
            sig.store(n0 + 2 * j, .monotonic);
        }
        _ = at_all;
        var lb2: [2400]u8 = undefined;
        // 재검증 8 차(R-1): `v20n-r1h` 는 τ 를 나눈 HEAD·Range 기록이 판마다 생겨야 한다(빈 판이 통과하지 않게).
        // 재검증 9 차(LOW-H): 위험 꼴이 정말 생겼는지도 — host 가 판마다 W1 응답을 버렸고(`sw-lose` 줄 ≥ 판 수 — 진단이 조용히 꺼지면 선다), 보인 것은
        // τ 를 나눈 HEAD·Range W 라 페이지 GET 을 머리·부분 응답·독 τ 로 막았다(`sig`·`partial`·`mixed` 까닭 ≥ 1 — Chromium 이 τ 를 나누지 않게 바뀌면 선다).
        // 재검증 10 차(LOW-J): 막은 까닭도 판마다(≥ 성공한 판 수) — 한 판에서만 위험 꼴이 서도 통과하던 것을 조였다(검증 v20p 7 회차 — 실측은 10).
        const is_r1h = comptime std.mem.eql(u8, nm, "v20n-r1h");
        const lost = if (is_r1h) logLines(log_path, log0, &.{"body: sw-lose "}) else 0;
        const shared = if (is_r1h) logLines(log_path, log0, &.{ "reason=sig", "reason=partial", "reason=mixed" }) else 0;
        // 재검증 11 차(LOW-J3): 판마다 하한 — 성공한 판마다 sw-lose ≥ 1 · 막은 까닭 ≥ 1(가장 적은 판을 detail 에).
        run_from[10] = logSize(log_path);
        var min_lost: usize = std.math.maxInt(usize);
        var min_shared: usize = std.math.maxInt(usize);
        if (is_r1h) for (0..10) |x| if (run_ok[x]) {
            min_lost = @min(min_lost, logLinesRange(log_path, run_from[x], run_from[x + 1], &.{"body: sw-lose "}));
            min_shared = @min(min_shared, logLinesRange(log_path, run_from[x], run_from[x + 1], &.{ "reason=sig", "reason=partial", "reason=mixed" }));
        };
        if (min_lost == std.math.maxInt(usize)) min_lost = 0;
        if (min_shared == std.math.maxInt(usize)) min_shared = 0;
        report(p0 and ok == 10 and tot.wrong == 0 and tot.multi_end == 0 and (!is_r1h or (tot.sw >= 8 and min_lost >= 1 and min_shared >= 1)), nm, std.fmt.bufPrint(&detail, "trials {d}/10: {s}{s}", .{ ok, bodyLine(&tot, ok == 10, &lb2), if (is_r1h) (std.fmt.bufPrint(&lb_r1h, " · host dropped W1 responses {d} (sw-lose — fewest in one trial {d}) · page GETs held off by a shared-τ HEAD/Range W {d} (sig/partial/mixed — fewest in one trial {d})", .{ lost, min_lost, shared, min_shared }) catch "") else "" }) catch "");
        try r.navigate(tab_a, "/blank");
        r.pump(500);
    };
    if (v20nPicked("v20n-r3")) {
        const hold = std.c.getenv("V20N_HOLD") orelse "9700";
        var eb: [32]u8 = undefined;
        try v20nCase(r, report, session, "v20n-r3", "r3", std.fmt.bufPrint(&eb, "&h={s}", .{std.mem.span(hold)}) catch "", 120_000, 20, 0);
    }
    if (v20nPicked("v20n-r2h")) try v20nCase(r, report, session, "v20n-r2h", "r2h", "", 120_000, 10, 0);
    if (v20nPicked("v20n-r8")) try v20nCase(r, report, session, "v20n-r8", "r8", "", 120_000, 30, 0);
    if (enabled("v20o-woff")) {
        // 재검증 9 차(검증 v20o 5 회차 탐침 → 기준 — `Table.watchOff` 를 실제 CEF 로 보는 판정이 없었다): A·B 가 같은 워커 출처를 기록 — A 는
        // 지켜보기를 기록 중에 여섯 번 끔·켬(B 는 그대로). 끈 탭은 그때부터 다시 기록할 때까지 서비스 워커 본문이 어둠이다(설계). 틀린 본문 0, 끝은
        // 기록마다 하나, A 의 끄기 앞 대조 ≥ 6, B 의 대조 ≥ 6(A 의 끔이 B 를 해치지 않는다).
        const n0 = sig.load(.monotonic);
        session.* += 1;
        const on_a = recordOn(r, tab_a, session.*);
        session.* += 1;
        const on_b = recordOn(r, tab_b, session.*);
        const at = r.begins.items.len;
        _ = r.titles.remove(tab_a);
        _ = r.titles.remove(tab_b);
        try r.navigate(tab_b, std.fmt.bufPrint(&pb, "/swz/p?c=wof&k=zwofb{d}&x=b&n={d}", .{ session.*, n0 }) catch "");
        try r.navigate(tab_a, std.fmt.bufPrint(&pb, "/swz/p?c=wof&k=zwofa{d}&x=a&n={d}", .{ session.*, n0 }) catch "");
        const w0a = r.pumpTitle(tab_a, "w0", 30_000);
        const toggles: usize = if (std.c.getenv("V20O_TOGGLES")) |v| (std.fmt.parseInt(usize, std.mem.span(v), 10) catch 6) else 6;
        for (0..toggles) |_| {
            try watchSet(r, tab_a, false);
            r.pump(40);
            try watchSet(r, tab_a, true);
            r.pump(60);
        }
        sig.store(n0 + 1, .monotonic);
        const da = r.pumpTitle(tab_a, "bdone", 60_000);
        const db = r.pumpTitle(tab_b, "bdone", 60_000);
        r.pump(4000);
        const ta = tallyCtl(r, tab_a, at, "actl");
        const tb = tallyCtl(r, tab_b, at, "bctl");
        var la: [2400]u8 = undefined;
        var lbb: [2400]u8 = undefined;
        report(on_a and on_b and w0a and da and db and ta.wrong == 0 and tb.wrong == 0 and ta.multi_end == 0 and tb.multi_end == 0 and ta.ctl_own >= 6 and tb.ctl_own >= ctl_min, "v20o-woff", std.fmt.bufPrint(&detail, "toggles {d} · tab A: {s} || tab B: {s}", .{ toggles, bodyLine(&ta, da, &la), bodyLine(&tb, db, &lbb) }) catch "");
        for ([_]u64{ tab_a, tab_b }) |b| try r.host.send(.{ .net_record = .{ .browser = b, .on = false, .session = 0 } });
        r.pump(500);
        try r.navigate(tab_a, "/blank");
        try r.navigate(tab_b, "/blank");
        r.pump(500);
    }
}
