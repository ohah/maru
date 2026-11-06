//! W9d② 재검증 5 차 적대 검증 11–20 회차의 탐침(`--review-body-v20l`, 고른 항목만 `V20L_ONLY=r11,r12,…`). 판정자가 maru 역할로
//! sidecar 를 `MARU_WEB_SW_CDP=1`·`MARU_WEB_TEST_BODY_LOG=1` 로 띄우고 회차마다 하나의 각도를 잰다. 설계가 약속한 것(틀린 본문 0·host 생존·
//! 워커가 멈춤)을 합격 조건으로 보고, 재검증 6 차가 고친 결함(F11·F13·F14a·F16)은 고친 뒤의 동작을 단언한다(그 밖의 잰 값은 줄에 적는다).
//! 재검증 6 차부터 붙은 워커의 주소는 host 진단 줄(`sw-attached … url=`)에서 읽는다 — 에이전트 길의 `Target.getTargets` 는 막혔다(F11).
//!
//! 출처 셋: O1 = http://127.0.0.1:P1, O2 = http://127.0.0.1:P2(O1 과 같은 사이트·다른 출처), X2 = http://localhost:P2(다른 사이트).
//!   v20l-r11-target   에이전트 길의 Target.*(인자 없는 getTargetInfo 만 — 재검증 6 차 F11)·sessionId 끼우기 — 다른 탭·워커가 보이지 않는다
//!   v20l-r12-scope    무엇이 붙는가: 같은 사이트 다른 출처 iframe 의 SW·다른 사이트 iframe 의 SW·공유·전용 worker·관계없는 다른 탭의 SW
//!   v20l-r13-alive    다른 출처(iframe) SW 는 기록 중에도 놀면 멈춘다(재검증 6 차 F13 — 「그 탭이 보이는 출처의 SW」 만 살려 둔다)
//!   v20l-r13b-iframe-origin  기록 중 다시 뜬 iframe 출처(같은 사이트·다른 사이트)의 SW 도 시한 뒤 떼어 멈춘다(F13)
//!   v20l-r14-cap      SW 몫(재검증 6 차 F14a — 탭마다 128)을 다른 탭의 SW 가 쥐어도 이 탭의 SW 갈래 기록·본문은 남는다(기록 끔·켬 둘 다)
//!   v20l-r14-many     한 출처에 SW 70 개 — 세션 상한 64(sidecar 전체), 붙임·뗌 되풀이, 다른 탭의 붙이기
//!   v20l-r14-loop     워커가 끝없이 fetch — 밸브·host 메모리
//!   v20l-r15-race     기록 켬·이동 직후 탭 닫기·렌더러 죽이기를 여러 간격으로 — host 생존·CHECK·남는 워커
//!   v20l-r16-toggle   계속 fetch 하는 페이지에서 끔·켬 60 번 — 틀린 본문 0·세션·끈 뒤 워커가 멈춤
//!   v20l-r16-leak     기록 중 닫힌 탭 33 개 뒤에도, 기록을 켰다 끈 뒤 닫힌 탭 33 개 뒤에도 새로 켠 탭의 SW 본문을 잡는다(재검증 6 차 F16 —
//!                     VS 자리, 서비스 워커 표의 탭 자리 — 셋째 판은 새 탭으로 잰다: 자리가 새면 새 탭이 붙이기를 걸지 못한다)
//!   v20l-r17-fail     실패한 워커 fetch 하나 뒤 그대로 넘김 20 번 — 응답 없는 실패는 잃지 않고, 응답 전에 끊긴 fetch 는 그 뒤 본문을 잃는다
//!                     (F17 — 문서의 잃는 표, 틀림은 0)
//!   v20l-r20-xtarget  두 SW 타깃이 같은 주소를 같은 때(메시지로) — CEF 차례와 CDP 차례가 뒤집히는 판의 비율(변이 J-C5-cross-target 을 가를 수 있는가)

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const net_fields = protocol.net_fields;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const tab_a: u64 = 151;
const tab_b: u64 = 152;
const tab_c: u64 = 153;
const wait_ms = 15_000;
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

var ports: [2]u16 = .{ 0, 0 };
var counter = std.atomic.Value(u64).init(1);
var boots: [16]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));
var hang_open = std.atomic.Value(i64).init(0);
/// 재검증 9 차(LOW-T3): 서버에 닿은 `/g/hang` 의 수(끝난 것 포함)와 「곧 풀기」 — 참이면 매달린 것·새로 닿는 것을 곧 끝낸다(v20m 과 같은 꼴).
var hang_seen = std.atomic.Value(u64).init(0);
var hang_release = std.atomic.Value(bool).init(false);

fn startServer(which: usize) !void {
    const fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
    if (listen(fd, 1024) != 0) return error.ListenFailed;
    var len: u32 = @sizeOf(SockaddrIn);
    if (getsockname(fd, &addr, &len) != 0) return error.SocketFailed;
    ports[which] = std.mem.bigToNative(u16, addr.port);
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

fn replyStatus(conn: c_int, status: []const u8, ctype: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [1024]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\n{s}Connection: close\r\n\r\n", .{ status, ctype, body.len, extra }) catch return;
    writeAll(conn, head);
    writeAll(conn, body);
}

fn reply(conn: c_int, ctype: []const u8, body: []const u8) void {
    replyStatus(conn, "200 OK", ctype, "", body);
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

fn queryValue(target: []const u8, key: []const u8) []const u8 {
    const qi = std.mem.indexOfScalar(u8, target, '?') orelse return "";
    var it = std.mem.splitScalar(u8, target[qi + 1 ..], '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], key)) return kv[eq + 1 ..];
    }
    return "";
}

const html = "text/html; charset=utf-8";

/// 워커: 시작할 때마다 `/g/boot?b=B`. `/g/x`·`/g/hang` 은 그대로 넘긴다. 메시지로 끝없는 fetch(`loop`)·같은 주소(`same`).
const sw_js = "var Q=new URL(location.href).searchParams;var B=Q.get('b')||'0';" ++
    "fetch('/g/boot?b='+B,{cache:'no-store'}).catch(function(){});" ++
    "self.addEventListener('install',function(){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
    "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(u.pathname=='/g/x'||u.pathname=='/g/hang'){e.respondWith(fetch(e.request))}});" ++
    "var LOOP=0;self.addEventListener('message',function(e){var d=e.data||{};" ++
    "if(d.op=='loop'){LOOP=1;e.waitUntil((async function(){var i=0;while(LOOP&&i<d.n){await fetch('/g/x?k=loop'+B+'_'+(i++),{cache:'no-store'}).then(function(r){return r.text()}).catch(function(){})}})())}" ++
    "if(d.op=='stop'){LOOP=0}" ++
    "if(d.op=='same'){e.waitUntil(fetch('/g/x?k=same&r='+d.r,{headers:{'x-who':'S'+B},cache:'no-store'}).then(function(r){return r.text()}).catch(function(){}))}" ++
    "if(d.op=='solo'){e.waitUntil(fetch('/g/x?k=solo&r='+d.r,{headers:{'x-who':'S'+B},cache:'no-store'}).then(function(r){return r.text()}).catch(function(){}))}});";

/// 페이지: SW(`/g/sw.js?b=B`, 범위 `/g/`)를 깔고 다스릴 때까지 다시 불러온 뒤, 고른 것(공유·전용 worker, iframe, fetch n 개)을 하고 `ready`.
const page_js = "var P=new URLSearchParams(location.search);" ++
    "navigator.serviceWorker.register('/g/sw.js?b='+(P.get('b')||'1'),{scope:'/g/'}).then(function(){return navigator.serviceWorker.ready}).then(async function(){" ++
    "if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}" ++
    "if(P.get('wk')){try{new SharedWorker('/g/wk.js?s=1')}catch(e){};try{window.__w=new Worker('/g/wk.js?d=1')}catch(e){}}" ++
    "var fs=(P.get('if')||'').split(',').filter(function(x){return x});for(var q=0;q<fs.length;q++){var f=document.createElement('iframe');f.src=decodeURIComponent(fs[q]);document.body.appendChild(f);await new Promise(function(r){f.onload=r;setTimeout(r,6000)})}" ++
    // 재검증 12 차: `pw` — 첫 fetch 앞에 기다린다(ms). 떠 있던 SW 에 붙는 눈먼 때 + 지연(50 ms)의 본문은 어둠이라(넓은 꼴) 본문을 세는 꼴은 그 뒤에 받는다.
    "var n=+(P.get('n')||0);var K=P.get('k')||'k';var ms=+(P.get('ms')||0);var pw=+(P.get('pw')||0);if(pw)await new Promise(function(r){setTimeout(r,pw)});" ++
    "for(var i=0;i<n;i++){await fetch('/g/x?k='+K+i,{cache:'no-store'}).then(function(r){return r.text()}).catch(function(){});if(ms)await new Promise(function(r){setTimeout(r,ms)})}" ++
    "document.title='ready'})";

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
    if (std.mem.eql(u8, path, "/blank")) return reply(conn, html, "<!doctype html><title>blank</title>blank");
    if (std.mem.eql(u8, path, "/g/sw.js")) return reply(conn, "text/javascript", sw_js);
    if (std.mem.eql(u8, path, "/g/wk.js")) return reply(conn, "text/javascript", "onconnect=function(e){e.ports[0].postMessage(1)};onmessage=function(){};");
    if (std.mem.eql(u8, path, "/g/boot")) {
        const b = std.fmt.parseInt(usize, queryValue(target, "b"), 10) catch 15;
        _ = boots[@min(b, 15)].fetchAdd(1, .monotonic);
        return reply(conn, "text/plain", "boot");
    }
    if (std.mem.eql(u8, path, "/g/p")) return reply(conn, html, "<!doctype html><title>p</title><script>" ++ page_js ++ "</script>p");
    // 범위 안 문서(멈췄던 워커를 다시 띄운다).
    if (std.mem.eql(u8, path, "/g/probe")) return reply(conn, html, "<!doctype html><title>probed</title>probe");
    // iframe 문서: 다스리는 SW 가 있으면 그것을 거쳐 n 번 받는다.
    if (std.mem.eql(u8, path, "/g/f")) return reply(conn, html, "<!doctype html><title>f</title><script>" ++
        "(async function(){for(var i=0;i<3;i++){await fetch('/g/x?k=ifr'+location.port+'_'+i,{cache:'no-store'}).then(function(r){return r.text()}).catch(function(){})}})()</script>f");
    // SW m 개(범위 `/g/n/<k>/`).
    if (std.mem.eql(u8, path, "/g/many")) return reply(conn, html, "<!doctype html><title>m</title><script>" ++
        "var m=+new URLSearchParams(location.search).get('m');var ps=[];for(var k=0;k<m;k++){ps.push(navigator.serviceWorker.register('/g/sw.js?b=7&k='+k,{scope:'/g/n/'+k+'/'}).then(function(r){return new Promise(function(res){var w=r.installing||r.waiting||r.active;if(!w)return res();if(w.state=='activated')return res();w.addEventListener('statechange',function(){if(w.state=='activated')res()});setTimeout(res,8000)})}).catch(function(){}))}" ++
        "Promise.all(ps).then(function(){return navigator.serviceWorker.getRegistrations()}).then(function(rs){document.title='many '+rs.length})</script>m");
    // 다스리는 SW 를 거쳐 끝나지 않는 fetch n 개를 연다.
    if (std.mem.eql(u8, path, "/g/hold")) return reply(conn, html, "<!doctype html><title>h</title><script>" ++
        "var n=+new URLSearchParams(location.search).get('n');for(var i=0;i<n;i++){fetch('/g/hang?i='+i,{cache:'no-store'}).then(function(r){return r.text()}).catch(function(){})}setTimeout(function(){document.title='holding'},500)</script>h");
    // 다스리는 SW 에 끝없는 fetch 를 시킨다 / 멈춘다.
    if (std.mem.eql(u8, path, "/g/loop")) return reply(conn, html, "<!doctype html><title>l</title><script>" ++
        "navigator.serviceWorker.ready.then(function(r){r.active.postMessage({op:'loop',n:+new URLSearchParams(location.search).get('n')});document.title='looping'})</script>l");
    if (std.mem.eql(u8, path, "/g/stop")) return reply(conn, html, "<!doctype html><title>s</title><script>" ++
        "navigator.serviceWorker.ready.then(function(r){r.active.postMessage({op:'stop'});document.title='stopped'})</script>s");
    // 두 범위 SW(b=1 `/g/`, b=4 `/g/q/`)에 같은 때 메시지 — 둘 다 같은 주소를 받는다.
    if (std.mem.eql(u8, path, "/g/same2")) return reply(conn, html, "<!doctype html><title>s2</title><script>" ++
        "var R=+new URLSearchParams(location.search).get('r');function S(ms){return new Promise(function(r){setTimeout(r,ms)})}" ++
        "function act(r){return new Promise(function(res){var w=r.installing||r.waiting||r.active;if(w&&w.state=='activated')return res(w);w.addEventListener('statechange',function(){if(w.state=='activated')res(w)})})}" ++
        "Promise.all([navigator.serviceWorker.register('/g/sw.js?b=1',{scope:'/g/'}).then(act),navigator.serviceWorker.register('/g/sw.js?b=4',{scope:'/g/q/'}).then(act)]).then(async function(ws){await S(800);" ++
        "for(var r=0;r<R;r++){ws[0].postMessage({op:'same',r:r});ws[1].postMessage({op:'same',r:r});ws[r%2].postMessage({op:'solo',r:r});await S(25)}await S(2500);document.title='sdone'})</script>s2");
    // 실패한 워커 fetch 하나(m=dead — 닫힌 포트로 거절, m=abort — 응답 전에 페이지가 끊음, m=none — 대조) 뒤 그대로 넘김 20 번.
    if (std.mem.eql(u8, path, "/g/fail")) return reply(conn, html, "<!doctype html><title>fl</title><script>" ++
        "var P=new URLSearchParams(location.search);var M=P.get('m');var K=P.get('k');function S(ms){return new Promise(function(r){setTimeout(r,ms)})}" ++
        "navigator.serviceWorker.ready.then(async function(){if(!navigator.serviceWorker.controller){location.reload();return}" ++
        "if(M=='dead'){await fetch('http://127.0.0.1:1/g/x?k='+K+'dead',{cache:'no-store'}).catch(function(){})}" ++
        "if(M=='abort'){var ac=new AbortController();var f=fetch('/g/hang?k='+K+'ab',{cache:'no-store',signal:ac.signal}).catch(function(){});await S(300);ac.abort();await f}" ++
        "await S(200);for(var i=0;i<20;i++){await fetch('/g/x?k='+K+'n'+i,{cache:'no-store'}).then(function(r){return r.text()}).catch(function(){})}" ++
        "await S(500);document.title='fdone'})</script>fl");
    // 본문 꼴: 페이지가 SW1 을 거쳐 받는 주소를 SW2 가 같은 때 메시지로 받는다(그 주소의 기록 둘 — 페이지 P 는 SW1 의 W 와 τ 로 이어진다).
    if (std.mem.eql(u8, path, "/g/same2b")) return reply(conn, html, "<!doctype html><title>s2b</title><script>" ++
        "var R=+new URLSearchParams(location.search).get('r');function S(ms){return new Promise(function(r){setTimeout(r,ms)})}" ++
        "function act(r){return new Promise(function(res){var w=r.installing||r.waiting||r.active;if(w&&w.state=='activated')return res(w);w.addEventListener('statechange',function(){if(w.state=='activated')res(w)})})}" ++
        "Promise.all([navigator.serviceWorker.register('/g/sw.js?b=1',{scope:'/g/'}).then(act),navigator.serviceWorker.register('/g/sw.js?b=4',{scope:'/g/q/'}).then(act)]).then(async function(ws){if(!navigator.serviceWorker.controller){location.reload();return}await S(800);" ++
        "for(var r=0;r<R;r++){ws[1].postMessage({op:'same',r:r});await fetch('/g/x?k=same&r='+r,{cache:'no-store'}).then(function(x){return x.text()}).catch(function(){});await S(25)}await S(2500);document.title='sdone'})</script>s2b");
    if (std.mem.eql(u8, path, "/g/hang")) {
        _ = hang_seen.fetchAdd(1, .monotonic);
        _ = hang_open.fetchAdd(1, .monotonic);
        const until = os.nowMs() + 45_000;
        while (os.nowMs() < until and !hang_release.load(.monotonic)) os.sleepMs(50);
        _ = hang_open.fetchSub(1, .monotonic);
        return reply(conn, "application/json", "{\"n\":\"hang\"}");
    }
    if (std.mem.eql(u8, path, "/g/x")) {
        const n = counter.fetchAdd(1, .monotonic);
        var bb: [64]u8 = undefined;
        var eb: [160]u8 = undefined;
        return replyStatus(conn, "200 OK", "application/json", std.fmt.bufPrint(&eb, "X-Served: {d}\r\nX-Body: {d}\r\nX-Who: {s}\r\n", .{ n, n, headerValue(req, "x-who") }) catch "", std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{n}) catch "");
    }
    return reply(conn, "text/plain", "?");
}

// ── 모으기 ────────────────────────────────────────────────────────────────────────────────────────────────

const Begin = struct { browser: u64, request: u64, url: []u8, expected: bool, sw: bool, session: u32 };
const Body = struct { browser: u64, request: u64, data: std.ArrayList(u8) = .empty, ends: usize = 0, state: msg.NetBodyState = .unavailable, session: u32 = 0, xbody: []u8 = &.{}, xserved: u64 = 0, cef_end: bool = false };
const Dt = struct { call: u32, data: std.ArrayList(u8) = .empty, done: bool = false, status: msg.DevtoolsStatus = .ok };

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
    /// 지금 켜 둔 기록 세션(탭마다 — 판정자 쪽 장부).
    on_session: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    dropped: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    dropped_sw: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    begins: std.ArrayList(Begin) = .empty,
    bodies: std.ArrayList(Body) = .empty,
    dts: std.ArrayList(Dt) = .empty,
    next_call: u32 = 5000,

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

    fn dt(self: *Run, cid: u32) *Dt {
        for (self.dts.items) |*d| if (d.call == cid) return d;
        self.dts.append(self.gpa, .{ .call = cid }) catch unreachable;
        return &self.dts.items[self.dts.items.len - 1];
    }

    fn take(self: *Run, m: msg.Message) void {
        switch (m) {
            .net_begin => |v| self.begins.append(self.gpa, .{ .browser = v.browser, .request = v.request, .url = self.gpa.dupe(u8, v.url) catch &.{}, .expected = v.flags2.body_expected, .sw = v.flags.service_worker, .session = self.on_session.get(v.browser) orelse 0 }) catch {},
            .net_response => |v| {
                const b = self.body(v.browser, v.request);
                var it = net_fields.HeaderIterator.init(v.headers);
                while (it.next()) |hh| {
                    if (std.ascii.eqlIgnoreCase(hh.name, "x-body")) b.xbody = self.gpa.dupe(u8, hh.value) catch &.{};
                    if (std.ascii.eqlIgnoreCase(hh.name, "x-served")) b.xserved = std.fmt.parseInt(u64, hh.value, 10) catch 0;
                }
            },
            .net_end => |v| self.body(v.browser, v.request).cef_end = true,
            .net_dropped => |v| {
                const g = self.dropped.getOrPut(self.gpa, v.browser) catch return;
                if (!g.found_existing) g.value_ptr.* = 0;
                g.value_ptr.* += v.count;
                const h = self.dropped_sw.getOrPut(self.gpa, v.browser) catch return;
                if (!h.found_existing) h.value_ptr.* = 0;
                h.value_ptr.* += v.sw_inflight_cap;
            },
            .net_body_data => |v| {
                const b = self.body(v.browser, v.request);
                if (v.offset == b.data.items.len) b.data.appendSlice(self.gpa, v.bytes) catch {};
            },
            .net_body_end => |v| {
                const b = self.body(v.browser, v.request);
                b.ends += 1;
                b.state = v.state;
                b.session = v.session;
            },
            .net_record_state => |v| {
                self.states.put(self.gpa, v.browser, v.status) catch {};
                self.state_log.append(self.gpa, .{ .browser = v.browser, .session = v.session, .status = v.status }) catch {};
            },
            .devtools_result_data => |v| self.dt(v.call).data.appendSlice(self.gpa, v.bytes) catch {},
            .devtools_result => |v| {
                const d = self.dt(v.call);
                d.done = true;
                d.status = v.status;
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
            if (self.titles.get(browser)) |t| if (std.mem.startsWith(u8, t, title)) return true;
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

    fn go(self: *Run, browser: u64, url: []const u8) !void {
        _ = self.titles.remove(browser);
        try self.host.send(.{ .navigate = .{ .browser = browser, .url = url } });
    }

    fn goO(self: *Run, browser: u64, which: usize, path: []const u8) !void {
        var u: [1024]u8 = undefined;
        try self.go(browser, try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}{s}", .{ ports[which], path }));
    }

    /// DevTools 호출(에이전트 길과 같은 `devtools_call`) — 상태와 결과.
    fn call(self: *Run, browser: u64, method: []const u8, params: []const u8) struct { status: msg.DevtoolsStatus, data: []const u8, answered: bool } {
        self.next_call += 1;
        const id = self.next_call;
        self.host.send(.{ .devtools_call = .{ .browser = browser, .call = id, .method = method, .params_size = @intCast(params.len) } }) catch return .{ .status = .send_failed, .data = "", .answered = false };
        if (params.len > 0) self.host.send(.{ .devtools_call_data = .{ .browser = browser, .call = id, .bytes = params } }) catch {};
        const deadline = os.nowMs() + 8000;
        while (os.nowMs() < deadline) {
            const d = self.dt(id);
            if (d.done) return .{ .status = d.status, .data = d.data.items, .answered = true };
            const m = (self.host.next(20) catch null) orelse continue;
            self.take(m);
        }
        return .{ .status = .expired, .data = "", .answered = false };
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
    const only = std.c.getenv("V20L_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(only), name) != null;
}

fn openTab(r: *Run, id: u64) !void {
    var u: [256]u8 = undefined;
    const size: msg.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
    _ = r.created.remove(id);
    _ = r.loads.remove(id);
    _ = r.closed.remove(id);
    try r.host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/blank", .{ports[0]}) } });
    if (!r.waitFor(wait_ms, id, createdAndLoaded)) return error.BrowserNotCreated;
    try r.host.send(.{ .net_watch = .{ .browser = id, .on = true, .full = true, .any_host = true } });
}

var next_session: u32 = 100;

fn recordOn(r: *Run, id: u64) bool {
    _ = r.states.remove(id);
    next_session += 1;
    r.on_session.put(r.gpa, id, next_session) catch {};
    r.host.send(.{ .net_record = .{ .browser = id, .on = true, .session = next_session } }) catch return false;
    return r.waitFor(5000, Want{ .id = id, .status = .on }, stateIs);
}

fn recordOff(r: *Run, id: u64) void {
    _ = r.on_session.remove(id);
    r.host.send(.{ .net_record = .{ .browser = id, .on = false, .session = 0 } }) catch {};
}

fn logSize(path: ?[:0]const u8) usize {
    const p = path orelse return 0;
    const fd = std.c.open(p, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    return if (end < 0) 0 else @intCast(end);
}

fn readLog(gpa: std.mem.Allocator, path: ?[:0]const u8, from: usize) []u8 {
    const p = path orelse return &.{};
    const fd = std.c.open(p, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return &.{};
    defer _ = std.c.close(fd);
    var all: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    _ = std.c.lseek(fd, @intCast(from), std.c.SEEK.SET);
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        all.appendSlice(gpa, buf[0..@intCast(n)]) catch break;
    }
    return all.items;
}

fn field(line: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const rest = line[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return rest[0..end];
}

fn countLines(log: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |line| if (std.mem.indexOf(u8, line, needle) != null) {
        n += 1;
    };
    return n;
}

/// 판 하나의 셈: 그 탭·`at` 뒤·주소에 `needle` 이 든 기록 — 본문이 그 기록 제 응답의 셈(X-Body)과 다르면 틀림.
const Tally = struct { total: usize = 0, sw: usize = 0, sw_own: usize = 0, page_own: usize = 0, wrong: usize = 0, no_end: usize = 0, held: usize = 0, states: [16]usize = @splat(0), bad_session: usize = 0 };

fn tally(r: *Run, browser: u64, at: usize, needle: []const u8) Tally {
    var t: Tally = .{};
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(r.gpa);
    for (r.begins.items[at..]) |b| if (b.browser == browser and std.mem.indexOf(u8, b.url, needle) != null) {
        if (seen.contains(b.request)) continue;
        seen.put(r.gpa, b.request, {}) catch {};
        const x = r.body(browser, b.request);
        t.total += 1;
        if (b.sw) t.sw += 1;
        if (b.expected and x.ends == 0) {
            if (x.cef_end) t.no_end += 1 else t.held += 1;
        }
        if (x.ends == 1) t.states[@backingInt(x.state)] += 1;
        if (x.ends >= 1 and x.state == .captured) {
            var want: [64]u8 = undefined;
            const w = std.fmt.bufPrint(&want, "{{\"n\":\"{s}\"}}", .{x.xbody}) catch "";
            if (x.xbody.len > 0 and std.mem.eql(u8, x.data.items, w)) {
                if (b.sw) t.sw_own += 1 else t.page_own += 1;
            } else t.wrong += 1;
        }
        if (x.ends >= 1 and b.session != 0 and x.session != b.session) t.bad_session += 1;
    };
    return t;
}

fn tallyLine(t: *const Tally, buf: []u8) []const u8 {
    var sl: [300]u8 = undefined;
    var n: usize = 0;
    for (t.states, 0..) |c, i| if (c > 0) {
        if (i >= @import("type_info_fields").enumFields(msg.NetBodyState).len) continue;
        const piece = std.fmt.bufPrint(sl[n..], " {s}={d}", .{ @tagName(@as(msg.NetBodyState, @fromBackingInt(@intCast(i)))), c }) catch break;
        n += piece.len;
    };
    return std.fmt.bufPrint(buf, "records {d} (sw {d}) · own body sw {d} page {d} · WRONG {d} · no end {d} · held {d} · body session != begin session {d} · states{s}", .{ t.total, t.sw, t.sw_own, t.page_own, t.wrong, t.no_end, t.held, t.bad_session, sl[0..n] }) catch "";
}

/// getTargets 결과에서 (targetId, type, url) — 대충 훑는다(JSON 을 풀어).
const TInfo = struct { id: []const u8, kind: []const u8, url: []const u8 };
fn parseTargets(gpa: std.mem.Allocator, data: []const u8, out: *std.ArrayList(TInfo)) void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return;
    const v = parsed.value;
    if (v != .object) return;
    const infos = v.object.get("targetInfos") orelse return;
    if (infos != .array) return;
    for (infos.array.items) |ti| if (ti == .object) {
        const id = ti.object.get("targetId") orelse continue;
        const kind = ti.object.get("type") orelse continue;
        const url = ti.object.get("url") orelse continue;
        if (id != .string or kind != .string or url != .string) continue;
        out.append(gpa, .{ .id = id.string, .kind = kind.string, .url = url.string }) catch {};
    };
}

fn hostAlive(r: *Run) bool {
    const c = r.call(tab_b, "Runtime.evaluate", "{\"expression\":\"1+1\",\"returnByValue\":true}");
    return c.answered and c.status == .ok;
}

const Idle = struct { stopped: bool, probed: bool, before: u64, after: u64 };
/// 놀린 뒤 `prober` 가 `which` 출처의 범위 안 문서로 옮긴다 — 그동안 b 번 워커가 다시 떴으면 멈췄던 것이다.
fn idleThenProbe(r: *Run, prober: u64, which: usize, host_name: []const u8, b: usize) !Idle {
    const before = boots[b].load(.monotonic);
    r.pump(idle_ms);
    var u: [256]u8 = undefined;
    try r.go(prober, try std.fmt.bufPrint(&u, "http://{s}:{d}/g/probe", .{ host_name, ports[which] }));
    const probed = r.pumpTitle(prober, "probed", 15_000);
    r.pump(2000);
    const after = boots[b].load(.monotonic);
    try r.goO(prober, 0, "/blank");
    r.pump(500);
    return .{ .stopped = after > before, .probed = probed, .before = before, .after = after };
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    try startServer(0);
    try startServer(1);
    var detail: [4000]u8 = undefined;
    var env_buf: [4][*:0]const u8 = undefined;
    var env_n: usize = 0;
    env_buf[env_n] = "MARU_WEB_SW_CDP=1";
    env_n += 1;
    env_buf[env_n] = "MARU_WEB_TEST_BODY_LOG=1";
    env_n += 1;
    // 재검증 12 차: 대조 손잡이(`MARU_WEB_SW_WAIT=0`·`MARU_WEB_SW_KEEP=0`)를 host 에 그대로 넘긴다.
    var pt_bufs: [2][64:0]u8 = undefined;
    for ([_][:0]const u8{ "MARU_WEB_SW_WAIT", "MARU_WEB_SW_KEEP" }, 0..) |name, k| {
        const v = std.c.getenv(name) orelse continue;
        const e = std.fmt.bufPrintSentinel(&pt_bufs[k], "{s}={s}", .{ name, std.mem.span(v) }, 0) catch continue;
        env_buf[env_n] = e.ptr;
        env_n += 1;
    }
    var sp_buf: [1100]u8 = undefined;
    const stderr_path: ?[:0]const u8 = blk: {
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
    try openTab(&r, tab_c);
    std.debug.print("v20l: ports O1={d} O2={d} host pid={d}\n", .{ ports[0], ports[1], host.pid });

    // C 가 O2(b=2)·X2(b=3) 의 SW 를 깐다 — 뒤 회차의 「다른 출처·다른 사이트」 워커.
    {
        try r.goO(tab_c, 1, "/g/p?b=2&n=1&k=c2");
        const ok2 = r.pumpTitle(tab_c, "ready", 20_000);
        var u: [256]u8 = undefined;
        try r.go(tab_c, try std.fmt.bufPrint(&u, "http://localhost:{d}/g/p?b=3&n=1&k=c3", .{ports[1]}));
        const ok3 = r.pumpTitle(tab_c, "ready", 20_000);
        try r.goO(tab_c, 0, "/blank");
        r.pump(500);
        std.debug.print("v20l: setup O2 sw {} X2 sw {}\n", .{ ok2, ok3 });
    }

    // ── 11 회차: 에이전트 길의 Target.* ────────────────────────────────────────────────────────────────
    if (enabled("r11")) {
        const on = recordOn(&r, tab_a);
        try r.goO(tab_a, 0, "/g/p?b=1&n=3&k=secretA");
        const ready = r.pumpTitle(tab_a, "ready", 20_000);
        r.pump(1500);
        const log_at = logSize(stderr_path);
        var targets: std.ArrayList(TInfo) = .empty;
        const gt = r.call(tab_b, "Target.getTargets", "");
        parseTargets(gpa, gt.data, &targets);
        var pages: usize = 0;
        var sws: usize = 0;
        var a_seen = false;
        var a_id: []const u8 = "";
        var sw_id: []const u8 = "";
        var other_origin_sw = false;
        for (targets.items) |t| {
            if (std.mem.eql(u8, t.kind, "page")) pages += 1;
            if (std.mem.eql(u8, t.kind, "service_worker")) {
                sws += 1;
                if (sw_id.len == 0) sw_id = t.id;
                if (std.mem.indexOf(u8, t.url, "localhost") != null) other_origin_sw = true;
            }
            if (std.mem.indexOf(u8, t.url, "secretA") != null) {
                a_seen = true;
                a_id = t.id;
            }
        }
        var pb: [256]u8 = undefined;
        const gti = r.call(tab_b, "Target.getTargetInfo", std.fmt.bufPrint(&pb, "{{\"targetId\":\"{s}\"}}", .{a_id}) catch "{}");
        const gti_leak = std.mem.indexOf(u8, gti.data, "secretA") != null;
        const act = r.call(tab_b, "Target.activateTarget", std.fmt.bufPrint(&pb, "{{\"targetId\":\"{s}\"}}", .{a_id}) catch "{}");
        const att = r.call(tab_b, "Target.attachToTarget", std.fmt.bufPrint(&pb, "{{\"targetId\":\"{s}\",\"flatten\":true}}", .{sw_id}) catch "{}");
        const saa = r.call(tab_a, "Target.setAutoAttach", "{\"autoAttach\":false,\"waitForDebuggerOnStart\":false}");
        const inj = r.call(tab_a, "Runtime.evaluate", "{\"expression\":\"1\"},\"sessionId\":\"AAAA\"");
        const inj2 = r.call(tab_a, "Runtime.evaluate", "{\"expression\":\"1\",\"sessionId\":\"AAAA\"}");
        const sd = r.call(tab_a, "ServiceWorker.stopAllWorkers", "");
        // 재검증 6 차 F11: maru 가 쓰는 꼴(인자 없는 getTargetInfo — 그 탭 자신)만 받는다.
        const own0 = r.call(tab_b, "Target.getTargetInfo", "{}");
        const own1 = r.call(tab_b, "Target.getTargetInfo", "");
        const gti_x = r.call(tab_b, "Target.getTargetInfo", "{\"targetId\":\"0123456789ABCDEF0123456789ABCDEF\"}");
        const own_secret = std.mem.indexOf(u8, own0.data, "secretA") != null;
        r.pump(1500);
        const log = readLog(gpa, stderr_path, log_at);
        const detached = countLines(log, "sw-detached");
        const f11 = gt.status == .invalid_request and gti.status == .invalid_request and gti_x.status == .invalid_request and act.status == .invalid_request and own0.status == .ok and own1.status == .ok and !own_secret and !a_seen and !gti_leak;
        report(on and ready and f11 and att.status == .invalid_request and saa.status == .invalid_request and inj.status == .invalid_request, "v20l-r11-target", std.fmt.bufPrint(&detail, "getTargets from tab B (not recording): {s} {d} bytes · pages {d} · service workers {d} · tab A's url (secretA) visible {} · other-site SW visible {} || getTargetInfo(A's id) from B: {s} leaks A url {} · getTargetInfo(any targetId): {s} · getTargetInfo {{}} / no params (maru's form — tab B itself): {s} / {s} (A's url in it {}) || activateTarget(A) from B: {s} || attachToTarget(SW): {s} || setAutoAttach: {s} || sessionId after params: {s} || sessionId inside params: {s} || ServiceWorker.stopAllWorkers (not blocked): {s} → sw-detached lines after {d}", .{ @tagName(gt.status), gt.data.len, pages, sws, a_seen, other_origin_sw, @tagName(gti.status), gti_leak, @tagName(gti_x.status), @tagName(own0.status), @tagName(own1.status), own_secret, @tagName(act.status), @tagName(att.status), @tagName(saa.status), @tagName(inj.status), @tagName(inj2.status), @tagName(sd.status), detached }) catch "");
        std.debug.print("v20l r11 getTargets head: {s}\n", .{gt.data[0..@min(gt.data.len, 1500)]});
        recordOff(&r, tab_a);
        r.pump(500);
        try r.goO(tab_a, 0, "/blank");
        r.pump(500);
    }

    // ── 12 회차: 무엇이 붙는가 ─────────────────────────────────────────────────────────────────────────
    if (enabled("r12") or enabled("r13")) {
        const on = recordOn(&r, tab_a);
        const log_at = logSize(stderr_path);
        const at = r.begins.items.len;
        // 같은 사이트·다른 출처 iframe(O2 — b=2 가 다스린다)과 다른 사이트 iframe(X2 — b=3), 공유·전용 worker.
        var pb: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&pb, "/g/p?b=1&n=2&k=r12&wk=1&if=http%3A%2F%2F127.0.0.1%3A{d}%2Fg%2Ff,http%3A%2F%2Flocalhost%3A{d}%2Fg%2Ff", .{ ports[1], ports[1] });
        try r.goO(tab_a, 0, path);
        const ready = r.pumpTitle(tab_a, "ready", 25_000);
        r.pump(3000);
        var targets: std.ArrayList(TInfo) = .empty;
        const gt = r.call(tab_b, "Target.getTargets", "");
        parseTargets(gpa, gt.data, &targets);
        const log = readLog(gpa, stderr_path, log_at);
        var lines: [1500]u8 = undefined;
        var ln: usize = 0;
        var att_o2 = false;
        var att_x2 = false;
        var att_other_type = false;
        var it = std.mem.splitScalar(u8, log, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "sw-attached ") == null) continue;
            if (std.mem.indexOf(u8, line, " b=151 ") == null) continue;
            const kind = field(line, " type=") orelse "";
            const keep = field(line, " keep=") orelse "";
            // 재검증 12 차: 전용 워커(`worker`)는 붙는다 — 멈춰 붙은 것을 놓고 곧 뗀다(keep=false; 렌더러가 filter 를 모른 채 멈춘다). 그 밖의 꼴·남긴 전용 워커는 틀림.
            if (!std.mem.eql(u8, kind, "service_worker") and !(std.mem.eql(u8, kind, "worker") and std.mem.eql(u8, keep, "false"))) att_other_type = true;
            const url = attUrl(line, targets.items);
            if (std.mem.indexOf(u8, url, "b=2") != null) att_o2 = true;
            if (std.mem.indexOf(u8, url, "b=3") != null) att_x2 = true;
            const piece = std.fmt.bufPrint(lines[ln..], " [{s} keep={s} {s}]", .{ kind, keep, url }) catch break;
            ln += piece.len;
        }
        const t = tally(&r, tab_a, at, "/g/x?k=");
        var tb: [600]u8 = undefined;
        report(on and ready and t.wrong == 0 and !att_other_type, "v20l-r12-scope", std.fmt.bufPrint(&detail, "tab A (top 127.0.0.1:{d}) with iframes 127.0.0.1:{d} (same site) and localhost:{d} (cross site), shared+dedicated worker — attached to A:{s} || same-site other-origin iframe SW (b=2) attached {} · cross-site iframe SW (b=3) attached {} · non-SW type attached {} || bodies: {s}", .{ ports[0], ports[1], ports[1], lines[0..ln], att_o2, att_x2, att_other_type, tallyLine(&t, &tb) }) catch "");
        if (enabled("r13")) {
            // 기록을 켠 채 40 초 놀린 뒤 C 가 O2 범위 안으로 — b=2 가 다시 떴으면 멈췄던 것이다(붙었으면 살아 있다).
            const x = try idleThenProbe(&r, tab_c, 1, "127.0.0.1", 2);
            // 재검증 6 차 F13: 맨 위 출처가 아닌 워커는 시한 뒤 뗀다 — 기록 중에도 놀면 멈춘다.
            report(x.probed and x.stopped, "v20l-r13-alive", std.fmt.bufPrint(&detail, "while A records (top 127.0.0.1:{d}), the same-site iframe origin's SW (127.0.0.1:{d}, b=2, attached {}) {s} after {d} s idle (boots {d} → {d}, probe {})", .{ ports[0], ports[1], att_o2, if (x.stopped) "stopped" else "KEPT RUNNING", idle_ms / 1000, x.before, x.after, x.probed }) catch "");
            recordOff(&r, tab_a);
            r.pump(500);
            try r.goO(tab_a, 0, "/blank");
            const y = try idleThenProbe(&r, tab_c, 1, "127.0.0.1", 2);
            report(y.stopped, "v20l-r13-off", std.fmt.bufPrint(&detail, "after recording off: b=2 {s} (boots {d} → {d})", .{ if (y.stopped) "stopped" else "KEPT RUNNING", y.before, y.after }) catch "");
        } else {
            recordOff(&r, tab_a);
            r.pump(500);
            try r.goO(tab_a, 0, "/blank");
            r.pump(500);
        }
    }

    // ── 13 회차 b: 기록 중 다른 출처(iframe) SW 가 (다시) 뜨면 붙어 살아 있는가 — 대조(iframe 없음)부터 ──────────────
    if (enabled("r13b")) {
        const on = recordOn(&r, tab_a);
        try r.goO(tab_a, 0, "/g/p?b=1&n=1&k=r13c");
        _ = r.pumpTitle(tab_a, "ready", 20_000);
        // 놀려 b=2·b=3 을 멈춘다(앞 회차가 깨웠을 수 있다).
        r.pump(idle_ms);
        var la = logSize(stderr_path);
        var u: [256]u8 = undefined;
        try r.go(tab_c, try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/g/probe", .{ports[1]}));
        _ = r.pumpTitle(tab_c, "probed", 15_000);
        try r.go(tab_c, try std.fmt.bufPrint(&u, "http://localhost:{d}/g/probe", .{ports[1]}));
        _ = r.pumpTitle(tab_c, "probed", 15_000);
        r.pump(2000);
        const ctrl = countKeep(readLog(gpa, stderr_path, la), "b=151", "keep=true");
        try r.goO(tab_c, 0, "/blank");
        // 이제 A 가 iframe 둘(O2·X2)을 품는다.
        var pb: [512]u8 = undefined;
        try r.goO(tab_a, 0, try std.fmt.bufPrint(&pb, "/g/p?b=1&n=1&k=r13i&if=http%3A%2F%2F127.0.0.1%3A{d}%2Fg%2Ff,http%3A%2F%2Flocalhost%3A{d}%2Fg%2Ff", .{ ports[1], ports[1] }));
        _ = r.pumpTitle(tab_a, "ready", 25_000);
        r.pump(idle_ms); // iframe 가 띄운 b=2·b=3 이 놀다 멈춘다(붙지 않았으면)
        la = logSize(stderr_path);
        const b2a = boots[2].load(.monotonic);
        const b3a = boots[3].load(.monotonic);
        try r.go(tab_c, try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/g/probe", .{ports[1]}));
        _ = r.pumpTitle(tab_c, "probed", 15_000);
        try r.go(tab_c, try std.fmt.bufPrint(&u, "http://localhost:{d}/g/probe", .{ports[1]}));
        _ = r.pumpTitle(tab_c, "probed", 15_000);
        r.pump(2000);
        try r.goO(tab_c, 0, "/blank");
        const b2b = boots[2].load(.monotonic);
        const b3b = boots[3].load(.monotonic);
        var targets: std.ArrayList(TInfo) = .empty;
        const gt = r.call(tab_b, "Target.getTargets", "");
        parseTargets(gpa, gt.data, &targets);
        const log = readLog(gpa, stderr_path, la);
        var lines: [1500]u8 = undefined;
        var ln: usize = 0;
        var it = std.mem.splitScalar(u8, log, '\n');
        var foreign_kept: usize = 0;
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "sw-attached ") == null or std.mem.indexOf(u8, line, " b=151 ") == null) continue;
            const url = attUrl(line, targets.items);
            const own = field(line, " own=") orelse "-";
            if (std.mem.eql(u8, field(line, " keep=") orelse "", "true") and !std.mem.eql(u8, own, "true")) foreign_kept += 1;
            const piece = std.fmt.bufPrint(lines[ln..], " [keep={s} own={s} {s}]", .{ field(line, " keep=") orelse "", own, url }) catch break;
            ln += piece.len;
        }
        // A 는 계속 기록 — 40 초 뒤 C 가 다시 범위 안으로: 다시 뜨지 않으면(boot 그대로) 살아 있었다.
        r.pump(idle_ms);
        try r.go(tab_c, try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/g/probe", .{ports[1]}));
        _ = r.pumpTitle(tab_c, "probed", 15_000);
        try r.go(tab_c, try std.fmt.bufPrint(&u, "http://localhost:{d}/g/probe", .{ports[1]}));
        _ = r.pumpTitle(tab_c, "probed", 15_000);
        r.pump(2000);
        try r.goO(tab_c, 0, "/blank");
        const b2c = boots[2].load(.monotonic);
        const b3c = boots[3].load(.monotonic);
        // 재검증 6 차 F13: 다시 뜬 iframe 출처의 SW 는 붙어도 남의 것(own=false)이라 시한 뒤 떼고(`sw-foreign-detach`), 놀면 멈춘다.
        const foreign_detached = countLines(readLog(gpa, stderr_path, la), "sw-foreign-detach b=151 ");
        const stopped2 = b2c > b2b;
        const stopped3 = b3c > b3b;
        report(on and ctrl == 0 and stopped2 and stopped3, "v20l-r13b-iframe-origin", std.fmt.bufPrint(&detail, "A records (on {}). control (no iframe): O2/X2 SW started by tab C → attached to A {d} || A with iframes 127.0.0.1:{d} and localhost:{d}: O2 SW restarted by C (boots {d}→{d}), X2 SW (boots {d}→{d}); attached to A:{s} · kept as foreign {d} · foreign detached (sw-foreign-detach, whole idle) {d} || after {d} s more idle while A records: O2 SW {s} (boots {d}→{d}), X2 SW {s} (boots {d}→{d})", .{ on, ctrl, ports[1], ports[1], b2a, b2b, b3a, b3b, lines[0..ln], foreign_kept, foreign_detached, idle_ms / 1000, if (stopped2) "stopped" else "KEPT RUNNING", b2b, b2c, if (stopped3) "stopped" else "KEPT RUNNING", b3b, b3c }) catch "");
        recordOff(&r, tab_a);
        r.pump(500);
        try r.goO(tab_a, 0, "/blank");
        r.pump(500);
    }

    // ── 14 회차: SW 몫(sidecar 전체 128)을 다른 탭이 쥔다 ───────────────────────────────────────────────
    if (enabled("r14-cap")) {
        // C(O2, 지켜봄·기록 안 함)가 b=2 를 거쳐 끝나지 않는 fetch 140 개를 연다.
        try r.goO(tab_c, 1, "/g/p?b=2&n=0");
        _ = r.pumpTitle(tab_c, "ready", 20_000);
        try r.goO(tab_c, 1, "/g/hold?n=140");
        const holding = r.pumpTitle(tab_c, "holding", 10_000);
        r.pump(3000);
        const hangs = hang_open.load(.monotonic);
        // ① A 는 지켜보기만(기록 끔): b=1 을 거쳐 30 번.
        const at_w = r.begins.items.len;
        const dsw0 = r.dropped_sw.get(tab_a) orelse 0;
        try r.goO(tab_a, 0, "/g/p?b=1&n=30&k=capW");
        const ready_w = r.pumpTitle(tab_a, "ready", 25_000);
        r.pump(2000);
        var sw_w: usize = 0;
        var page_w: usize = 0;
        for (r.begins.items[at_w..]) |b| if (b.browser == tab_a and std.mem.indexOf(u8, b.url, "k=capW") != null) {
            if (b.sw) sw_w += 1 else page_w += 1;
        };
        const dsw_w = (r.dropped_sw.get(tab_a) orelse 0) - dsw0;
        // ② A 가 기록한다.
        const on = recordOn(&r, tab_a);
        const at = r.begins.items.len;
        try r.goO(tab_a, 0, "/g/p?b=1&n=30&k=capR&pw=150");
        const ready = r.pumpTitle(tab_a, "ready", 25_000);
        r.pump(3000);
        const t = tally(&r, tab_a, at, "/g/x?k=capR");
        const dsw_r = (r.dropped_sw.get(tab_a) orelse 0) - dsw0 - dsw_w;
        var tb: [600]u8 = undefined;
        // 재검증 6 차 F14a: 몫은 탭마다 — C 가 제 몫을 다 쥐어도 A 의 서비스 워커 갈래 요청은 적히고(넘긴 수 0) 본문도 잡는다.
        // C 의 몫이 찼다는 증거는 C 가 넘긴 수다(서버에 닿는 것은 연결 6 개뿐 — 나머지는 Chromium 줄에 선다).
        const c_cap = r.dropped_sw.get(tab_c) orelse 0;
        report(t.wrong == 0 and holding and c_cap > 0 and ready_w and ready and on and sw_w >= 30 and dsw_w == 0 and dsw_r == 0 and t.sw >= 30 and t.sw_own >= 27, "v20l-r14-cap", std.fmt.bufPrint(&detail, "tab C (127.0.0.1:{d}, watched, not recording) holds {d} hanging fetches through its SW (holding {}, C's dropped_sw_inflight_cap {d}) || tab A (127.0.0.1:{d}) NOT recording, 30 fetches via its own SW: SW-branch records {d} · page records {d} · A's dropped_sw_inflight_cap +{d} (ready {}) || tab A recording (on {}): {s} · A's dropped_sw_inflight_cap +{d} (ready {})", .{ ports[1], hangs, holding, c_cap, ports[0], sw_w, page_w, dsw_w, ready_w, on, tallyLine(&t, &tb), dsw_r, ready }) catch "");
        recordOff(&r, tab_a);
        try r.goO(tab_c, 0, "/blank");
        try r.goO(tab_a, 0, "/blank");
        // 재검증 9 차(LOW-T3): 매달린 fetch 를 곧 푼다 — 서버에 닿는 것은 연결 6 개뿐이고 나머지 134 개는 Chromium 의 같은 호스트 연결 줄(6)에 서서
        // 45 초마다 6 개씩(약 17 분) O2 의 연결을 쥐었다; 전에는 첫 6 개가 끝나 `hang_open` 이 잠깐 0 이 되면 나가 뒤 회차(`r14-many`·`r14-stall`)의
        // O2 페이지가 서지 않았다(전체 차례에서만 FAIL — 검증 v20o 10 회차). 줄에 선 것까지 모두 서버에 닿아 끝날 때까지(닿은 수가 3 초 동안 오르지
        // 않을 때까지) 기다린다.
        hang_release.store(true, .monotonic);
        const deadline = os.nowMs() + 120_000;
        var last = hang_seen.load(.monotonic);
        var still_since = os.nowMs();
        while (os.nowMs() < deadline) {
            r.pump(300);
            const now_seen = hang_seen.load(.monotonic);
            if (now_seen != last) {
                last = now_seen;
                still_since = os.nowMs();
            } else if (hang_open.load(.monotonic) == 0 and os.nowMs() - still_since >= 3_000) break;
        }
        hang_release.store(false, .monotonic);
        r.pump(1000);
    }

    // ── 14 회차: 한 출처에 SW 70 개 ───────────────────────────────────────────────────────────────────
    if (enabled("r14-many")) {
        try r.goO(tab_c, 0, "/g/many?m=70");
        const many = r.pumpTitle(tab_c, "many", 90_000);
        const many_title = r.titles.get(tab_c) orelse "";
        try r.goO(tab_c, 0, "/blank");
        r.pump(500);
        const log_at = logSize(stderr_path);
        const on = recordOn(&r, tab_a);
        try r.goO(tab_a, 0, "/g/p?b=1&n=1&k=many");
        const ready = r.pumpTitle(tab_a, "ready", 20_000);
        r.pump(4000);
        const log1 = readLog(gpa, stderr_path, log_at);
        const keep1 = countLines(log1, "keep=true");
        const drop1 = countLines(log1, "keep=false");
        const log_at2 = logSize(stderr_path);
        r.pump(10_000);
        const log2 = readLog(gpa, stderr_path, log_at2);
        const churn = countLines(log2, "sw-attached ");
        // B(O2)가 기록한다 — 제 SW(b=2)의 세션 자리가 남았는가.
        const log_at3 = logSize(stderr_path);
        const on_b = recordOn(&r, tab_b);
        const at = r.begins.items.len;
        try r.goO(tab_b, 1, "/g/p?b=2&n=20&k=manyB&pw=150");
        const ready_b = r.pumpTitle(tab_b, "ready", 20_000);
        r.pump(4000);
        const log3 = readLog(gpa, stderr_path, log_at3);
        const t = tally(&r, tab_b, at, "/g/x?k=manyB");
        var tb: [600]u8 = undefined;
        const alive = hostAlive(&r);
        // 재검증 6 차 F14c: 세션은 탭마다 16 — A 가 출처의 SW 70 개를 가져도 B 는 제 SW 를 붙여 본문을 잡는다.
        report(alive and t.wrong == 0 and on_b and ready_b and countKeep(log3, "b=152", "keep=true") >= 1 and t.sw_own >= 15, "v20l-r14-many", std.fmt.bufPrint(&detail, "C registered: {s} ({}) · A records (on {} ready {}): attached keep=true {d} · keep=false {d} · attach lines in the next 10 s {d} || B (127.0.0.1:{d}) then records (on {} ready {}): B attach keep=true {d} keep=false {d} · {s} · host alive {}", .{ many_title, many, on, ready, keep1, drop1, churn, ports[1], on_b, ready_b, countKeep(log3, "b=152", "keep=true"), countKeep(log3, "b=152", "keep=false"), tallyLine(&t, &tb), alive }) catch "");
        recordOff(&r, tab_a);
        recordOff(&r, tab_b);
        r.pump(500);
        try r.goO(tab_a, 0, "/blank");
        try r.goO(tab_b, 0, "/blank");
        r.pump(500);
    }

    // ── 14 회차 b: 세션 상한이 찬 뒤 다른 탭의 페이지가 멈추는가(제목의 때를 잰다) ─────────────────────────────
    if (enabled("r14-stall")) {
        try r.goO(tab_c, 0, "/g/many?m=70");
        const many = r.pumpTitle(tab_c, "many", 90_000);
        try r.goO(tab_c, 0, "/blank");
        r.pump(500);
        const on_a = recordOn(&r, tab_a);
        try r.goO(tab_a, 0, "/g/p?b=1&n=1&k=st");
        _ = r.pumpTitle(tab_a, "ready", 20_000);
        r.pump(3000);
        var res: [5]i64 = @splat(-1);
        const steps = [_]struct { tab: u64, rec: bool, label: []const u8 }{
            .{ .tab = tab_c, .rec = false, .label = "C not recording → O2 page" },
            .{ .tab = tab_b, .rec = true, .label = "B records (armed at O1 blank) → O2 page" },
            .{ .tab = tab_b, .rec = true, .label = "B records again (armed at O1 blank) → O2 page" },
            .{ .tab = tab_c, .rec = true, .label = "C records (armed at O1 blank), A off → O2 page" },
            .{ .tab = tab_b, .rec = false, .label = "B not recording → O2 page" },
        };
        var line: [1500]u8 = undefined;
        var ln: usize = 0;
        for (steps, 0..) |st, i| {
            try r.goO(st.tab, 0, "/blank");
            r.pump(800);
            if (i == 3) {
                recordOff(&r, tab_a);
                r.pump(1500);
            }
            const la = logSize(stderr_path);
            if (st.rec) _ = recordOn(&r, st.tab) else recordOff(&r, st.tab);
            r.pump(1500);
            const t0 = os.nowMs();
            var pb: [128]u8 = undefined;
            try r.goO(st.tab, 1, try std.fmt.bufPrint(&pb, "/g/p?b=2&n=5&k=st{d}", .{i}));
            const ok = r.pumpTitle(st.tab, "ready", 30_000);
            res[i] = if (ok) os.nowMs() - t0 else -1;
            const lg = readLog(gpa, stderr_path, la);
            const title = r.titles.get(st.tab) orelse "";
            const piece = std.fmt.bufPrint(line[ln..], " [{s}: ready {d} ms (title '{s}') · attach keep=true {d} keep=false {d} · runIfWaiting {d}]", .{ st.label, res[i], title, countLines(lg, "keep=true"), countLines(lg, "keep=false"), countLines(lg, "runIfWaitingForDebugger") }) catch break;
            ln += piece.len;
            if (st.rec) recordOff(&r, st.tab);
            r.pump(500);
        }
        report(res[1] >= 0 and res[2] >= 0, "v20l-r14-stall", std.fmt.bufPrint(&detail, "70 SWs on 127.0.0.1:{d} ({}) · A records (on {}) holding the session slots ·{s}", .{ ports[0], many, on_a, line[0..ln] }) catch "");
        for ([_]u64{ tab_a, tab_b, tab_c }) |b| {
            recordOff(&r, b);
            try r.goO(b, 0, "/blank");
        }
        r.pump(1000);
    }

    // ── 14 회차: 워커가 끝없이 fetch ──────────────────────────────────────────────────────────────────
    if (enabled("r14-loop")) {
        const on = recordOn(&r, tab_a);
        try r.goO(tab_a, 0, "/g/p?b=1&n=0");
        _ = r.pumpTitle(tab_a, "ready", 20_000);
        const at = r.begins.items.len;
        const sl = r.state_log.items.len;
        const t0 = os.nowMs();
        try r.goO(tab_a, 0, "/g/loop?n=200000");
        var paused_ms: i64 = -1;
        var rss: [16]u64 = @splat(0);
        var k: usize = 0;
        while (os.nowMs() - t0 < 30_000) {
            r.pump(2000);
            if (k < rss.len) {
                rss[k] = psRss(host.pid);
                k += 1;
            }
            if (paused_ms < 0) for (r.state_log.items[sl..]) |s| if (s.browser == tab_a and s.status == .paused) {
                paused_ms = os.nowMs() - t0;
            };
        }
        var recs: usize = 0;
        for (r.begins.items[at..]) |b| if (b.browser == tab_a and std.mem.indexOf(u8, b.url, "k=loop") != null) {
            recs += 1;
        };
        try r.goO(tab_a, 0, "/g/stop");
        _ = r.pumpTitle(tab_a, "stopped", 10_000);
        const t = tally(&r, tab_a, at, "/g/x?k=loop");
        var tb: [600]u8 = undefined;
        var rb: [300]u8 = undefined;
        var rn: usize = 0;
        for (rss[0..k]) |v| {
            const piece = std.fmt.bufPrint(rb[rn..], " {d}", .{v / 1024}) catch break;
            rn += piece.len;
        }
        report(t.wrong == 0 and hostAlive(&r), "v20l-r14-loop", std.fmt.bufPrint(&detail, "SW fetches in a loop while A records (on {}): paused after {d} ms · loop records in 30 s {d} · host RSS MiB every 2 s:{s} · {s}", .{ on, paused_ms, recs, rb[0..rn], tallyLine(&t, &tb) }) catch "");
        recordOff(&r, tab_a);
        r.pump(500);
        try r.goO(tab_a, 0, "/blank");
        r.pump(500);
    }

    // ── 17 회차: 실패한 워커 fetch 하나가 그 탭을 어둡게 하는가 ─────────────────────────────────────────
    if (enabled("r17-fail")) {
        try r.goO(tab_a, 0, "/g/p?b=1&n=0");
        _ = r.pumpTitle(tab_a, "ready", 20_000);
        var line: [1500]u8 = undefined;
        var ln: usize = 0;
        var wrong: usize = 0;
        var lost_ctrl: usize = 0;
        for ([_][]const u8{ "none", "dead", "abort", "none" }, 0..) |m, i| {
            _ = recordOn(&r, tab_a);
            const la = logSize(stderr_path);
            const at = r.begins.items.len;
            var pb: [128]u8 = undefined;
            try r.goO(tab_a, 0, try std.fmt.bufPrint(&pb, "/g/fail?m={s}&k=f{d}{s}", .{ m, i, m }));
            const done = r.pumpTitle(tab_a, "fdone", 30_000);
            r.pump(4000);
            var nb: [64]u8 = undefined;
            const t = tally(&r, tab_a, at, std.fmt.bufPrint(&nb, "/g/x?k=f{d}{s}n", .{ i, m }) catch "");
            wrong += t.wrong;
            const lg = readLog(gpa, stderr_path, la);
            var tb: [600]u8 = undefined;
            const piece = std.fmt.bufPrint(line[ln..], " [{s} (done {}): {s} · notes dark {d} unexplained {d}]", .{ m, done, tallyLine(&t, &tb), countLines(lg, "reason=dark"), countLines(lg, "reason=unexplained") }) catch break;
            ln += piece.len;
            // 대조와 응답 없는 실패(닫힌 포트)는 잃지 않는다. 응답 전에 끊긴 fetch(abort)는 그 W 가 응답 때 짝을 정해 기록이 설명되지 않은 채 열려
            // 있어 그 뒤 본문을 잃는다(F17 — 문서의 잃는 표; 틀림은 0).
            if (!std.mem.eql(u8, m, "abort") and (!done or t.sw_own < 18)) lost_ctrl += 1;
            recordOff(&r, tab_a);
            r.pump(500);
        }
        report(wrong == 0 and lost_ctrl == 0, "v20l-r17-fail", std.fmt.bufPrint(&detail, "one failed worker fetch, then 20 pass-through fetches (fresh recording session each):{s}", .{line[0..ln]}) catch "");
        try r.goO(tab_a, 0, "/blank");
        r.pump(500);
        // 몫이 비도록 /g/hang 이 끝날 때까지(abort 꼴).
        const deadline = os.nowMs() + 60_000;
        while (hang_open.load(.monotonic) > 0 and os.nowMs() < deadline) r.pump(500);
    }

    // ── 16 회차 b: 기록 중 닫힌 탭 33 개 뒤 새로 켠 탭의 서비스 워커 본문(VS 자리) ───────────────────────────
    if (enabled("r16-leak")) {
        // 대조: 닫기 전.
        var line: [1800]u8 = undefined;
        var ln: usize = 0;
        var own_min: usize = std.math.maxInt(usize);
        for (0..3) |phase| {
            if (phase >= 1) {
                for (0..33) |i| {
                    // 1: 기록하는 채 닫는다(표의 `closed` — VS 자리). 2: 기록을 켜(워커 붙이기를 건다) 끈 뒤 닫는다(표에 없어 닫힘의 떼기 일이 오지
                    // 않는다 — 서비스 워커 표의 탭 자리, 재검증 6 차의 같은 꼴).
                    const id: u64 = (if (phase == 1) @as(u64, 400) else @as(u64, 500)) + i;
                    try openTab(&r, id);
                    _ = recordOn(&r, id);
                    if (phase == 2) {
                        r.pump(150);
                        recordOff(&r, id);
                        r.pump(100);
                    }
                    try r.host.send(.{ .destroy_browser = id });
                    const Closed = struct {
                        fn got(x: *Run, b: u64) bool {
                            return x.closed.contains(b);
                        }
                    };
                    _ = r.waitFor(5000, id, Closed.got);
                }
            }
            // 셋째 판은 새 탭에서 잰다 — 서비스 워커 표의 탭 자리는 새 탭만 새로 잡는다(A 는 앞 판에 잡은 자리가 있다).
            const meas: u64 = if (phase == 2) 600 else tab_a;
            if (phase == 2) try openTab(&r, meas);
            const la = logSize(stderr_path);
            _ = recordOn(&r, meas);
            const at = r.begins.items.len;
            var pb: [96]u8 = undefined;
            try r.goO(meas, 0, try std.fmt.bufPrint(&pb, "/g/p?b=1&n=20&k=lk{d}&pw=150", .{phase}));
            const done = r.pumpTitle(meas, "ready", 30_000);
            r.pump(4000);
            var nb: [64]u8 = undefined;
            const t = tally(&r, meas, at, std.fmt.bufPrint(&nb, "/g/x?k=lk{d}", .{phase}) catch "");
            const lg = readLog(gpa, stderr_path, la);
            var tb: [600]u8 = undefined;
            const what = switch (phase) {
                0 => "before closing tabs",
                1 => "after 33 tabs closed while recording",
                else => "after 33 more tabs recorded, turned off, then closed",
            };
            const piece = std.fmt.bufPrint(line[ln..], " [{s} (done {}): {s} · before_visible notes {d} · arms {d}]", .{ what, done, tallyLine(&t, &tb), countLines(lg, "reason=before_visible"), countLines(lg, "sw-arm ") }) catch break;
            ln += piece.len;
            own_min = @min(own_min, if (done) t.sw_own else 0);
            recordOff(&r, meas);
            r.pump(500);
            try r.goO(meas, 0, "/blank");
            r.pump(500);
        }
        // 재검증 6 차 F16: 닫힌 탭이 VS 자리를 비운다 — 닫기 뒤에도 닫기 전처럼 잡는다(전에는 20/20 → 0/20).
        report(own_min >= 18, "v20l-r16-leak", std.fmt.bufPrint(&detail, "tab A records with its SW pass-through:{s}", .{line[0..ln]}) catch "");
    }

    // ── 15 회차: 켬·이동 직후 닫기·죽이기 ─────────────────────────────────────────────────────────────
    if (enabled("r15")) {
        const log_at = logSize(stderr_path);
        const gaps = [_]u32{ 0, 2, 5, 10, 20, 40, 80, 150, 300, 600 };
        var died_at: ?usize = null;
        var iters: usize = 0;
        for (0..40) |i| {
            const id: u64 = 300 + i;
            openTab(&r, id) catch {
                died_at = i;
                break;
            };
            const g = gaps[i % gaps.len];
            switch (i % 4) {
                0 => {
                    next_session += 1;
                    try r.host.send(.{ .net_record = .{ .browser = id, .on = true, .session = next_session } });
                    try r.goO(id, 0, "/g/p?b=1&n=5&k=race");
                    os.sleepMs(g);
                    try r.host.send(.{ .destroy_browser = id });
                },
                1 => {
                    _ = recordOn(&r, id);
                    try r.goO(id, 0, "/g/p?b=1&n=5&k=race");
                    r.pump(200 + g);
                    try r.host.send(.{ .destroy_browser = id });
                },
                2 => {
                    _ = recordOn(&r, id);
                    try r.goO(id, 0, "/g/p?b=1&n=5&k=race");
                    r.pump(300 + g);
                    recordOff(&r, id);
                    next_session += 1;
                    try r.host.send(.{ .net_record = .{ .browser = id, .on = true, .session = next_session } });
                    os.sleepMs(g / 4);
                    try r.host.send(.{ .destroy_browser = id });
                },
                else => {
                    _ = recordOn(&r, id);
                    try r.goO(id, 0, "/g/p?b=1&n=5&k=race");
                    r.pump(300 + g);
                    try r.host.send(.{ .devtools_call = .{ .browser = id, .call = 900 + @as(u32, @intCast(i)), .method = "Page.crash", .params_size = 0 } });
                    os.sleepMs(g / 4);
                    try r.host.send(.{ .destroy_browser = id });
                },
            }
            r.pump(300);
            if (!hostAlive(&r)) {
                died_at = i;
                break;
            }
            iters += 1;
        }
        r.pump(3000);
        const log = readLog(gpa, stderr_path, log_at);
        const checks = countLines(log, "Check failed") + countLines(log, "FATAL") + countLines(log, "DCHECK");
        var closed: usize = 0;
        for (0..40) |i| if (r.closed.contains(300 + i)) {
            closed += 1;
        };
        // 다 닫힌 뒤: A·B·C 모두 기록하지 않는다 — b=1 이 멈추는가(남은 auto-attach 가 없다).
        const x = try idleThenProbe(&r, tab_b, 0, "127.0.0.1", 1);
        report(died_at == null and checks == 0 and x.stopped, "v20l-r15-race", std.fmt.bufPrint(&detail, "iterations {d}/40 · host died at {?d} · Check failed/FATAL lines {d} · browser_closed {d}/40 · then b=1 {s} after {d} s idle (boots {d} → {d}, probe {})", .{ iters, died_at, checks, closed, if (x.stopped) "stopped" else "KEPT RUNNING", idle_ms / 1000, x.before, x.after, x.probed }) catch "");
    }

    // ── 16 회차: 끔·켬 60 번 ─────────────────────────────────────────────────────────────────────────
    if (enabled("r16")) {
        const at = r.begins.items.len;
        const log_at = logSize(stderr_path);
        try r.goO(tab_a, 0, "/g/p?b=1&n=0");
        _ = r.pumpTitle(tab_a, "ready", 20_000);
        try r.goO(tab_a, 0, "/g/p?b=1&n=1200&ms=10&k=tg");
        var prng = std.Random.DefaultPrng.init(0x2011);
        const rnd = prng.random();
        _ = recordOn(&r, tab_a);
        for (0..60) |_| {
            recordOff(&r, tab_a);
            r.pump(rnd.uintLessThan(u32, 30));
            next_session += 1;
            r.on_session.put(gpa, tab_a, next_session) catch {};
            try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = true, .session = next_session } });
            r.pump(rnd.uintLessThan(u32, 120));
        }
        _ = recordOn(&r, tab_a);
        const done = r.pumpTitle(tab_a, "ready", 90_000);
        r.pump(4000);
        const t = tally(&r, tab_a, at, "/g/x?k=tg");
        const log = readLog(gpa, stderr_path, log_at);
        const checks = countLines(log, "Check failed");
        recordOff(&r, tab_a);
        r.pump(500);
        try r.goO(tab_a, 0, "/blank");
        const x = try idleThenProbe(&r, tab_b, 0, "127.0.0.1", 1);
        var tb: [600]u8 = undefined;
        report(t.wrong == 0 and checks == 0 and x.stopped, "v20l-r16-toggle", std.fmt.bufPrint(&detail, "60 off/on toggles while the page fetches through its SW every 10 ms (done {}): {s} · arms {d} · detaches(autoAttach false) {d} · Check failed {d} || after final off: b=1 {s} (boots {d} → {d})", .{ done, tallyLine(&t, &tb), countLines(log, "sw-arm "), countLines(log, "sw-detach "), checks, if (x.stopped) "stopped" else "KEPT RUNNING", x.before, x.after }) catch "");
    }

    // ── 20 회차: 두 SW 타깃이 같은 주소를 같은 때 ─────────────────────────────────────────────────────
    if (enabled("r20")) {
        const on = recordOn(&r, tab_a);
        const log_at = logSize(stderr_path);
        const at = r.begins.items.len;
        try r.goO(tab_a, 0, "/g/same2?r=400");
        const done = r.pumpTitle(tab_a, "sdone", 120_000);
        r.pump(3000);
        const log = readLog(gpa, stderr_path, log_at);
        const res = reversal(&r, gpa, log, at);
        // 재검증 10 차(LOW-J): 7 차 겹침 규칙 뒤로 같은 주소 W 둘(두 타깃)은 짝을 맺지 않아 sw-pair 줄이 판마다 0 이었다(짝의 옳음을 보는 힘이 없다 —
        // 검증 v20p 7 회차). 판마다 한 타깃만 받는 다른 주소(`k=solo`)를 더해 짝이 서고, 그 짝이 옳은지(X-Served)와 짝 수의 아래 끝을 함께 본다.
        report(on and done and res.wrong_pairs == 0 and res.correct_pairs >= 100, "v20l-r20-xtarget", std.fmt.bufPrint(&detail, "rounds with both records and both W {d} · CEF order != CDP order (reversed) {d} · CDP start gap < 1 ms {d} (reversed among them {d}) · sw-pair lines {d} (two-target k=same {d} · one-target k=solo {d} · correct {d} · WRONG {d}) · w_cross_target notes {d}", .{ res.both, res.reversed, res.close, res.close_rev, res.pairs, res.pairs_same, res.pairs_solo, res.correct_pairs, res.wrong_pairs, countLines(log, "reason=w_cross_target") }) catch "");
        recordOff(&r, tab_a);
        r.pump(500);
        try r.goO(tab_a, 0, "/blank");
        r.pump(500);
    }

    if (enabled("r20b")) {
        const on = recordOn(&r, tab_a);
        const at = r.begins.items.len;
        try r.goO(tab_a, 0, "/g/same2b?r=300");
        const done = r.pumpTitle(tab_a, "sdone", 120_000);
        r.pump(4000);
        const t = tally(&r, tab_a, at, "/g/x?k=same&r=");
        var tb: [600]u8 = undefined;
        report(on and done and t.wrong == 0, "v20l-r20b-xtarget-body", std.fmt.bufPrint(&detail, "page fetch (SW1 pass-through) + SW2 fetch of the same URL at the same time, 300 rounds: {s}", .{tallyLine(&t, &tb)}) catch "");
        recordOff(&r, tab_a);
        r.pump(500);
        try r.goO(tab_a, 0, "/blank");
        r.pump(500);
    }

    host.send(.shutdown) catch {};
    host_alive = false;
    const code = host.wait(wait_ms);
    std.debug.print("v20l: host exit {?d}\n", .{code});
}

/// 붙은 워커의 주소 — host 진단 줄의 `url=`(재검증 6 차), 없으면 getTargets 결과.
fn attUrl(line: []const u8, targets: []const TInfo) []const u8 {
    if (field(line, " url=")) |u| if (u.len > 0) return u;
    const tid = field(line, " target=") orelse return "?";
    for (targets) |t| if (std.mem.eql(u8, t.id, tid)) return t.url;
    return "?";
}

fn countKeep(log: []const u8, who: []const u8, keep: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |line| if (std.mem.indexOf(u8, line, "sw-attached ") != null and std.mem.indexOf(u8, line, who) != null and std.mem.indexOf(u8, line, keep) != null) {
        n += 1;
    };
    return n;
}

fn psRss(pid: c_int) u64 {
    var cmd: [128]u8 = undefined;
    const c = std.fmt.bufPrintSentinel(&cmd, "ps -o rss= -p {d}", .{pid}, 0) catch return 0;
    const f = popen(c.ptr, "r") orelse return 0;
    defer _ = pclose(f);
    var buf: [64]u8 = undefined;
    const n = fread(&buf, 1, buf.len, f);
    return std.fmt.parseInt(u64, std.mem.trim(u8, buf[0..n], " \n\t"), 10) catch 0;
}
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(f: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, f: *anyopaque) usize;

/// 재검증 11 차(LOW-J′): `pairs_same`·`pairs_solo` — sw-pair 줄을 그 기록 주소(`k=same` 두 타깃·`k=solo` 한 타깃)로 가른 수.
const Rev = struct { both: usize = 0, reversed: usize = 0, close: usize = 0, close_rev: usize = 0, pairs: usize = 0, correct_pairs: usize = 0, wrong_pairs: usize = 0, pairs_same: usize = 0, pairs_solo: usize = 0 };

/// 판 r 마다: 같은 주소의 기록 둘(CEF IO 시각 `cef-begin t=`)과 W 둘(CDP 시작 `sw-wsent ts=`)을 서버 셈(X-Served ↔ W 의 xs)으로 이어,
/// 두 차례가 다른 판을 센다. `sw-pair` 줄은 기록의 X-Served 와 W 의 xs 로 맞는지 본다.
fn reversal(r: *Run, gpa: std.mem.Allocator, log: []const u8, at: usize) Rev {
    var res: Rev = .{};
    // 기록 번호 → CEF t.
    var cef_t: std.AutoHashMapUnmanaged(u64, i64) = .empty;
    // W 이름(w<타깃32>:<rid>) → ts, xs.
    var w_ts: std.StringHashMapUnmanaged(i64) = .empty;
    var w_xs: std.StringHashMapUnmanaged(u64) = .empty;
    // xs → W 이름.
    var xs_w: std.AutoHashMapUnmanaged(u64, []const u8) = .empty;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "body: cef-begin ") != null) {
            const req = std.fmt.parseInt(u64, field(line, " req=") orelse continue, 10) catch continue;
            const t = std.fmt.parseInt(i64, field(line, " t=") orelse continue, 10) catch continue;
            cef_t.put(gpa, req, t) catch {};
        } else if (std.mem.indexOf(u8, line, "sw-wsent ") != null or std.mem.indexOf(u8, line, "sw-wresp ") != null) {
            const tv = std.fmt.parseInt(u64, field(line, " t=") orelse continue, 16) catch continue;
            const rid = field(line, " rid=") orelse continue;
            var kb: [96]u8 = undefined;
            const key = gpa.dupe(u8, std.fmt.bufPrint(&kb, "w{x}:{s}", .{ @as(u32, @truncate(tv)), rid }) catch continue) catch continue;
            if (std.mem.indexOf(u8, line, "sw-wsent ") != null) {
                const ts = std.fmt.parseInt(i64, field(line, " ts=") orelse continue, 10) catch continue;
                w_ts.put(gpa, key, ts) catch {};
            } else {
                const xs = std.fmt.parseInt(u64, field(line, " xs=") orelse continue, 10) catch continue;
                w_xs.put(gpa, key, xs) catch {};
                xs_w.put(gpa, xs, key) catch {};
            }
        }
    }
    // 판마다 기록 둘.
    var by_round: std.AutoHashMapUnmanaged(u64, [2]u64) = .empty;
    var cnt: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    for (r.begins.items[at..]) |b| if (b.browser == tab_a and b.sw and std.mem.indexOf(u8, b.url, "k=same&r=") != null) {
        const rs = b.url[std.mem.indexOf(u8, b.url, "&r=").? + 3 ..];
        const round = std.fmt.parseInt(u64, rs, 10) catch continue;
        const g = by_round.getOrPut(gpa, round) catch continue;
        const c = cnt.getOrPut(gpa, round) catch continue;
        if (!c.found_existing) c.value_ptr.* = 0;
        if (c.value_ptr.* < 2) g.value_ptr.*[c.value_ptr.*] = b.request;
        c.value_ptr.* += 1;
    };
    var rit = by_round.iterator();
    while (rit.next()) |e| {
        if ((cnt.get(e.key_ptr.*) orelse 0) != 2) continue;
        const q = e.value_ptr.*;
        const t0 = cef_t.get(q[0]) orelse continue;
        const t1 = cef_t.get(q[1]) orelse continue;
        const x0 = r.body(tab_a, q[0]).xserved;
        const x1 = r.body(tab_a, q[1]).xserved;
        const w0 = xs_w.get(x0) orelse continue;
        const w1 = xs_w.get(x1) orelse continue;
        const s0 = w_ts.get(w0) orelse continue;
        const s1 = w_ts.get(w1) orelse continue;
        res.both += 1;
        const rev = (t0 < t1) != (s0 < s1);
        if (rev) res.reversed += 1;
        if (@abs(s0 - s1) < 1000) {
            res.close += 1;
            if (rev) res.close_rev += 1;
        }
    }
    var kind_of: std.AutoHashMapUnmanaged(u64, u8) = .empty; // 기록 번호 → 1 same · 2 solo
    for (r.begins.items[at..]) |b| if (b.browser == tab_a and b.sw) {
        const k: u8 = if (std.mem.indexOf(u8, b.url, "k=same") != null) 1 else if (std.mem.indexOf(u8, b.url, "k=solo") != null) 2 else 0;
        if (k != 0) kind_of.put(gpa, b.request, k) catch {};
    };
    var it2 = std.mem.splitScalar(u8, log, '\n');
    while (it2.next()) |line| {
        if (std.mem.indexOf(u8, line, "sw-pair ") == null) continue;
        const req = std.fmt.parseInt(u64, field(line, " req=") orelse continue, 10) catch continue;
        const wrid = field(line, " wrid=") orelse continue;
        res.pairs += 1;
        switch (kind_of.get(req) orelse 0) {
            1 => res.pairs_same += 1,
            2 => res.pairs_solo += 1,
            else => {},
        }
        const xs = w_xs.get(wrid) orelse continue;
        const rec = r.body(tab_a, req).xserved;
        if (rec == 0) continue;
        if (xs == rec) res.correct_pairs += 1 else res.wrong_pairs += 1;
    }
    return res;
}
