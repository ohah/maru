//! W9d② 적대적 검증 20 회 중 1–10 회차(A) 판정(`v20a-*` — `--review-body-v20a`, 고른 항목만 `V20_ONLY=r1,r2…`). 판정자가 maru 역할로
//! `net_watch`·`net_record` 를 보내고 `net_begin`·`net_redirect`·`net_response`·`net_body_*` 를 모은다. 서버는 응답마다 셈(`X-Body: N`)과
//! 보낸 쪽(`X-Who` — 요청의 `x-who` 머리)을 싣고 본문은 `{"n":"N"}` — 잡은 본문이 그 기록 제 응답 머리의 N 과 다르면 「틀린 본문」.
//!   v20a-r1-*   설정 끔(127.0.0.1 만 / 어느 호스트든): 덮이는 → 덮이지 않는 리다이렉트·바로·스크립트·주 프레임 문서, 켬 → 끔·끔 → 켬 사이의 요청
//!   v20a-r2-*   페이지와 전용·공유 워커가 같은 주소를 0–20 ms 떨어져(서버 곧 / 60 ms)
//!   v20a-r3-*   같은 주소 동시(POST·GET, 거꾸로 끝남, 셋), A → B → A, 제 주소 리다이렉트
//!   v20a-r4-*   물 높이: 잡음 묶음·워커가 먼저·큰 주소로 IO 스레드를 늦춤 — 틀림 0, 기대한 시작마다 끝이 꼭 하나
//!   v20a-r5-*   abort 뒤 다시: StrictMode 두 번, 셋, 머리 뒤 abort
//!   v20a-r6-*   서비스 워커: 네트워크 실패의 대체 응답, 바꾼 요청을 그대로 넘김, POST 넘김, 다시 싼 응답
//!   v20a-r8-*   본문 상한 경계(1 MiB −1·꼭·+1, 조각 인코딩, UTF-8 경계)
//!   v20a-r9-*   탭 닫힘·이동·렌더러 죽음·쏟아짐 밸브·sidecar SIGKILL 뒤 다시 띄움 — 기대한 시작마다 끝이 꼭 하나(이동으로 끊긴 것은
//!               `unavailable` — `unmatched` 가 아니다, 20 회 검증 N1)

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const net_fields = protocol.net_fields;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const rec_tab: u64 = 121;
const tab_b: u64 = 122;
const wait_ms = 15_000;

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
const FILE = opaque {};
extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fgets(buf: [*]u8, n: c_int, f: *FILE) ?[*]u8;
extern "c" fn pclose(f: *FILE) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;

var port: u16 = 0;
var counter = std.atomic.Value(u64).init(1);
/// A → B → A·제 주소 리다이렉트: 키(0..255)마다 첫 홉을 보냈는가.
var hop_seen: [4][256]std.atomic.Value(bool) = @splat(@splat(std.atomic.Value(bool).init(false)));
var size_body: []u8 = &.{};

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

fn replyC(conn: c_int, status: []const u8, ctype: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [1024]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n{s}Connection: close\r\n\r\n", .{ status, ctype, body.len, extra }) catch return;
    writeAll(conn, head);
    writeAll(conn, body);
}

fn reply(conn: c_int, ctype: []const u8, body: []const u8) void {
    replyC(conn, "200 OK", ctype, "", body);
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

fn whoOf(head: []const u8) []const u8 {
    const w = headerValue(head, "x-who");
    return if (w.len > 0 and w.len < 32) w else "-";
}

/// 주소의 `name=` 뒤 숫자(없으면 0).
fn qnum(target: []const u8, name: []const u8) u64 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, target, at, name)) |i| {
        if (i > 0 and (target[i - 1] == '?' or target[i - 1] == '&')) {
            var v: u64 = 0;
            var j = i + name.len;
            while (j < target.len and target[j] >= '0' and target[j] <= '9') : (j += 1) v = v * 10 + (target[j] - '0');
            return v;
        }
        at = i + 1;
    }
    return 0;
}

/// `{"n":"N"}` 와 X-Body·X-Who. `head_first_ms` 면 머리를 먼저 보내고 그만큼 뒤에 본문.
fn data(conn: c_int, head: []const u8, delay_ms: u64, head_first_ms: u64) void {
    if (delay_ms > 0) os.sleepMs(@intCast(delay_ms));
    const n = counter.fetchAdd(1, .monotonic);
    var bb: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{n}) catch return;
    var hb: [1024]u8 = undefined;
    writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: x-who\r\nAccess-Control-Expose-Headers: X-Body\r\nX-Body: {d}\r\nX-Who: {s}\r\nConnection: close\r\n\r\n", .{ body.len, n, whoOf(head) }) catch return);
    if (head_first_ms > 0) os.sleepMs(@intCast(head_first_ms));
    writeAll(conn, body);
}

const read_js = "function F(u,o){return fetch(u,o).then(function(r){return r.text()}).catch(function(){})}" ++
    "function W(u,w){return F(u,{headers:{'x-who':w}})}";
const worker_js = "onmessage=function(e){fetch(e.data,{headers:{'x-who':'w'}}).then(function(r){return r.text()}).catch(function(){})}";
const shared_js = "onconnect=function(c){var p=c.ports[0];p.onmessage=function(e){fetch(e.data,{headers:{'x-who':'w'}}).then(function(r){return r.text()}).catch(function(){})}}";
const reg_js = "function reg(next){navigator.serviceWorker.register('/v20/sw/sw.js',{scope:'/v20/sw/'}).then(function(){return navigator.serviceWorker.ready}).then(function(){" ++
    "if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}setTimeout(next,300)})}";
const sw_js = "self.addEventListener('install',function(e){self.skipWaiting()});" ++
    "self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
    "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);var p=u.pathname;" ++
    // 네트워크가 끊으면 만든 응답(대체) — 그 본문은 네트워크 응답이 아니다.
    "if(p=='/v20/sw/fail'){e.respondWith(fetch(e.request).catch(function(){return new Response('{\"n\":\"FALLBACK\"}',{headers:{'content-type':'application/json'}})}));return}" ++
    // 바꾼 요청(머리를 더함)을 그대로 넘김 — 네트워크 응답 그대로(출처 network).
    "if(p=='/v20/sw/mod'){var h=new Headers(e.request.headers);h.set('x-who','m');e.respondWith(fetch(new Request(e.request,{headers:h})));return}" ++
    // POST 를 그대로 넘김.
    "if(p=='/v20/sw/post'){e.respondWith(fetch(e.request));return}" ++
    // 네트워크 응답의 몸을 새 Response 로 다시 싼다(같은 바이트 — 출처는 만든 것).
    "if(p=='/v20/sw/wrap'){e.respondWith(fetch(e.request).then(function(r){return new Response(r.body,{status:r.status,headers:r.headers})}));return}" ++
    // 다른 주소의 fetch 로 답하고 페이지도 그 주소를 곧 받는다(머리 x-who 는 남긴다).
    "if(p=='/v20/sw/x'){e.respondWith(fetch('/v20/sw/y'+u.search,{headers:{'x-who':'sx'}}));return}" ++
    "});";

fn serveOne(conn: c_int) void {
    defer _ = std.c.close(conn);
    var req: [8192]u8 = undefined;
    var have: usize = 0;
    var tail: [4]u8 = @splat(0);
    var scratch: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < 4 * 1024 * 1024) {
        const n_read = std.c.read(conn, &scratch, scratch.len);
        if (n_read <= 0) break;
        const got = scratch[0..@intCast(n_read)];
        const k = @min(got.len, req.len - have);
        @memcpy(req[have..][0..k], got[0..k]);
        have += k;
        total += got.len;
        var done = false;
        for (got) |ch| {
            tail = .{ tail[1], tail[2], tail[3], ch };
            if (std.mem.eql(u8, &tail, "\r\n\r\n")) done = true;
        }
        if (done) break;
    }
    if (have == 0) return;
    const head = req[0..have];
    const line_end = std.mem.indexOfScalar(u8, head, '\r') orelse head.len;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    const qi = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. qi orelse target.len];
    const query = if (qi) |i| target[i..] else "";
    const html = "text/html; charset=utf-8";
    if (std.mem.eql(u8, method, "OPTIONS")) return replyC(conn, "204 No Content", "text/plain", "Access-Control-Allow-Headers: x-who, content-type\r\nAccess-Control-Allow-Methods: GET, POST\r\n", "");
    if (std.mem.eql(u8, path, "/v20/blank")) return reply(conn, html, "<!doctype html><title>blank</title>blank");
    if (std.mem.eql(u8, path, "/v20/d")) return data(conn, head, qnum(target, "d="), qnum(target, "h="));
    if (std.mem.eql(u8, path, "/v20/w.js")) return reply(conn, "application/javascript", worker_js);
    if (std.mem.eql(u8, path, "/v20/shw.js")) return reply(conn, "application/javascript", shared_js);
    // ── r1: 설정 끔 ──
    var lb: [512]u8 = undefined;
    if (std.mem.eql(u8, path, "/v20/r1/c2u")) {
        // 덮이는 → 덮이지 않는(localhost) — rd= 만큼 늦게 리다이렉트, 본문은 d= 만큼 머리 뒤.
        os.sleepMs(@intCast(qnum(target, "rd=")));
        return replyC(conn, "302 Found", "text/plain", std.fmt.bufPrint(&lb, "Location: http://localhost:{d}/v20/r1/sec{s}\r\n", .{ port, query }) catch return, "");
    }
    if (std.mem.eql(u8, path, "/v20/r1/sec")) {
        const b = "{\"secret\":\"SECRET-UNCOV\"}";
        var hb: [512]u8 = undefined;
        writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", .{b.len}) catch return);
        os.sleepMs(@intCast(qnum(target, "d=")));
        writeAll(conn, b);
        return;
    }
    if (std.mem.eql(u8, path, "/v20/r1/sec.js")) return reply(conn, "application/javascript", "var SECRET_UNCOV_JS=1;");
    if (std.mem.eql(u8, path, "/v20/r1/secdoc")) return reply(conn, html, "<!doctype html><title>secdoc</title>SECRET-UNCOV-DOC");
    if (std.mem.eql(u8, path, "/v20/r1/navredir")) return replyC(conn, "302 Found", "text/plain", std.fmt.bufPrint(&lb, "Location: http://localhost:{d}/v20/r1/secdoc\r\n", .{port}) catch return, "");
    if (std.mem.eql(u8, path, "/v20/r1/c2u2c")) return replyC(conn, "302 Found", "text/plain", std.fmt.bufPrint(&lb, "Location: http://localhost:{d}/v20/r1/u2c{s}\r\n", .{ port, query }) catch return, "");
    if (std.mem.eql(u8, path, "/v20/r1/u2c")) return replyC(conn, "302 Found", "text/plain", std.fmt.bufPrint(&lb, "Location: http://127.0.0.1:{d}/v20/d{s}\r\n", .{ port, query }) catch return, "");
    if (std.mem.eql(u8, path, "/v20/r1/a")) return reply(conn, html, "<!doctype html><title>r1a</title><script>" ++ read_js ++
        "var L='http://localhost:'+location.port;setTimeout(function(){" ++
        "for(var i=0;i<15;i++)F('/v20/r1/c2u?f'+i);" ++
        "for(var i=0;i<15;i++)F('/v20/r1/c2u?s'+i+'&d=300');" ++
        "for(var i=0;i<15;i++)F(L+'/v20/r1/sec?x'+i);" ++
        "for(var i=0;i<5;i++)F('/v20/r1/c2u2c?c'+i);" ++
        "for(var i=0;i<5;i++)F('/v20/d?o'+i);" ++
        "for(var i=0;i<5;i++){var s=document.createElement('script');s.src=L+'/v20/r1/sec.js?j'+i;document.head.appendChild(s)}" ++
        "setTimeout(function(){document.title='r1adone'},2500)},200)</script>r1a");
    // 켬 → 끔 사이: 본문이 늦은 것(d=700)·리다이렉트가 늦은 것(rd=500). 끔 → 켬 사이도 같은 꼴.
    if (std.mem.eql(u8, path, "/v20/r1/b")) return reply(conn, html, "<!doctype html><title>r1b</title><script>" ++ read_js ++
        "setTimeout(function(){for(var i=0;i<15;i++)F('/v20/r1/c2u?m'+i+'&d=700');for(var i=0;i<15;i++)F('/v20/r1/c2u?n'+i+'&rd=500');" ++
        "document.title='r1bfired';setTimeout(function(){document.title='r1bdone'},2500)},200)</script>r1b");
    if (std.mem.eql(u8, path, "/v20/r1/c")) return reply(conn, html, "<!doctype html><title>r1c</title><script>" ++ read_js ++
        "var L='http://localhost:'+location.port;setTimeout(function(){for(var i=0;i<10;i++)F(L+'/v20/d?on'+i);setTimeout(function(){document.title='r1cdone'},2000)},200)</script>r1c");
    // ── r2: 페이지와 워커가 같은 주소 ──
    if (std.mem.eql(u8, path, "/v20/r2/p")) return reply(conn, html, "<!doctype html><title>r2</title><script>" ++ read_js ++
        "var q=location.search;var sh=q.indexOf('sh')>=0;var d=q.indexOf('slow')>=0?60:0;var w;" ++
        "if(sh){var s=new SharedWorker('/v20/shw.js');w=s.port;s.port.start()}else{w=new Worker('/v20/w.js')}" ++
        "var k=0;function step(){if(k>=42){document.title='r2done';return}var j=k;k++;var u='/v20/d?r2'+q.slice(1)+'_'+j+'&d='+d;var off=j%21;" ++
        "if(j<21){w.postMessage(u);setTimeout(function(){W(u,'p')},off)}else{W(u,'p');setTimeout(function(){w.postMessage(u)},off)}" ++
        "setTimeout(step,140)}setTimeout(step,600)</script>r2");
    // ── r3: 같은 주소 동시 ──
    if (std.mem.eql(u8, path, "/v20/r3/aba")) {
        const k: usize = @intCast(qnum(target, "k=") % 256);
        const who = whoOf(head);
        if (std.mem.eql(u8, who, "r") and !hop_seen[0][k].swap(true, .acq_rel)) return replyC(conn, "302 Found", "text/plain", std.fmt.bufPrint(&lb, "Location: /v20/r3/abb{s}\r\n", .{query}) catch return, "");
        return data(conn, head, if (std.mem.eql(u8, who, "q")) 0 else 20, 0);
    }
    if (std.mem.eql(u8, path, "/v20/r3/abb")) return replyC(conn, "302 Found", "text/plain", std.fmt.bufPrint(&lb, "Location: /v20/r3/aba{s}\r\n", .{query}) catch return, "");
    if (std.mem.eql(u8, path, "/v20/r3/self")) {
        const k: usize = @intCast(qnum(target, "k=") % 256);
        const who = whoOf(head);
        if (std.mem.eql(u8, who, "s") and !hop_seen[1][k].swap(true, .acq_rel)) return replyC(conn, "302 Found", "text/plain", std.fmt.bufPrint(&lb, "Location: /v20/r3/self{s}\r\n", .{query}) catch return, "");
        return data(conn, head, 0, 0);
    }
    if (std.mem.eql(u8, path, "/v20/r3/slowby")) {
        // x-who 가 a 면 300 ms, b 면 150 ms, 그 밖은 곧.
        const who = whoOf(head);
        return data(conn, head, if (std.mem.eql(u8, who, "a")) 300 else if (std.mem.eql(u8, who, "b")) 150 else 0, 0);
    }
    if (std.mem.eql(u8, path, "/v20/r3/p")) return reply(conn, html, "<!doctype html><title>r3</title><script>" ++ read_js ++
        "function P(u,w){return F(u,{method:'POST',headers:{'x-who':w,'content-type':'text/plain'},body:'1'})}" ++
        "var k=0;function step(){if(k>=24){document.title='r3done';return}var j=k;k++;var gap=(j%2)?30:0;" ++
        "var u1='/v20/r3/slowby?post'+j;P(u1,'a');setTimeout(function(){P(u1,'c')},gap);" ++
        "var u2='/v20/r3/slowby?get'+j;W(u2,'a');setTimeout(function(){W(u2,'c')},gap);" ++
        "var u3='/v20/r3/slowby?tri'+j;W(u3,'a');setTimeout(function(){W(u3,'b')},5);setTimeout(function(){W(u3,'c')},10);" ++
        "var u4='/v20/r3/aba?k='+j;W(u4,'r');setTimeout(function(){W(u4,'q')},5);" ++
        "var u5='/v20/r3/self?k='+j;W(u5,'s');setTimeout(function(){W(u5,'t')},5);" ++
        "setTimeout(step,450)}setTimeout(step,300)</script>r3");
    // ── r4: 물 높이 ──
    if (std.mem.eql(u8, path, "/v20/r4/p")) return reply(conn, html, "<!doctype html><title>r4</title><script>" ++ read_js ++
        "var q=location.search;var giant=q.indexOf('giant')>=0;var pad=giant?new Array(300001).join('x'):'';var w=new Worker('/v20/w.js');" ++
        "var k=0;function step(){if(k>=40){document.title='r4done';return}var j=k;k++;var u='/v20/d?r4'+q.slice(1)+'_'+j;" ++
        "for(var i=0;i<30;i++)F('/v20/d?n'+q.slice(1)+'_'+j+'_'+i);" ++
        "if(giant){for(var i=0;i<4;i++)F('/v20/d?g'+j+'_'+i+'&pad='+pad)}" ++
        "w.postMessage(u);setTimeout(function(){W(u,'p')},j%4);setTimeout(step,160)}setTimeout(step,600)</script>r4");
    // ── r5: abort 뒤 다시 ──
    if (std.mem.eql(u8, path, "/v20/r5/p")) return reply(conn, html, "<!doctype html><title>r5</title><script>" ++ read_js ++
        "function A(u,w,c){return F(u,{signal:c.signal,headers:{'x-who':w}})}" ++
        "var k=0;function step(){if(k>=60){document.title='r5done';return}var j=k;k++;var dl=[0,5,50][j%3];" ++
        // StrictMode: effect → cleanup(abort) → effect again, 같은 task.
        "var u1='/v20/d?sm'+j+'&d='+dl;function eff(w){var c=new AbortController();A(u1,w,c);return function(){c.abort()}}var cl=eff('s1');cl();eff('s2');" ++
        // 셋: 둘을 끊고 셋째를 남김(동기·마이크로태스크).
        "var u2='/v20/d?th'+j+'&d='+dl;var c1=new AbortController(),c2=new AbortController();A(u2,'t1',c1);A(u2,'t2',c2);c1.abort();Promise.resolve().then(function(){c2.abort();W(u2,'t3')});" ++
        // 머리 뒤 abort(본문 300 ms 늦음) 뒤 다시.
        "var u3='/v20/d?hd'+j+'&h=300';var c3=new AbortController();A(u3,'h1',c3);setTimeout(function(){c3.abort();W(u3,'h2')},60);" ++
        "setTimeout(step,200)}setTimeout(step,300)</script>r5");
    // ── r6: 서비스 워커(범위 /v20/sw/) ──
    if (std.mem.eql(u8, path, "/v20/sw/sw.js")) return reply(conn, "application/javascript", sw_js);
    if (std.mem.eql(u8, path, "/v20/sw/fail")) {
        // 짝수는 연결을 그냥 닫는다(네트워크 실패 → 워커가 대체 응답), 홀수는 머리 뒤 끊는다(본문 일부).
        if (qnum(target, "k=") % 2 == 0) return;
        writeAll(conn, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\nCache-Control: no-store\r\nX-Body: 0\r\nConnection: close\r\n\r\n{\"n\":");
        return;
    }
    if (std.mem.eql(u8, path, "/v20/sw/mod") or std.mem.eql(u8, path, "/v20/sw/post") or std.mem.eql(u8, path, "/v20/sw/wrap") or std.mem.eql(u8, path, "/v20/sw/y")) return data(conn, head, 0, 0);
    if (std.mem.eql(u8, path, "/v20/sw/p")) return reply(conn, html, "<!doctype html><title>sw</title><script>" ++ read_js ++ reg_js ++
        "var k=0;function step(){if(k>=20){document.title='swdone';return}var j=k;k++;" ++
        "F('/v20/sw/fail?k='+j);W('/v20/sw/mod?'+j,'p');F('/v20/sw/post?'+j,{method:'POST',headers:{'x-who':'p','content-type':'text/plain'},body:'1'});" ++
        "W('/v20/sw/wrap?'+j,'p');W('/v20/sw/x?'+j,'p');setTimeout(function(){W('/v20/sw/y?'+j,'py')},j%3);" ++
        "setTimeout(step,180)}reg(step)</script>sw");
    // ── r8: 크기 경계 ──
    if (std.mem.eql(u8, path, "/v20/r8/size")) {
        const n: usize = @intCast(@min(qnum(target, "n="), size_body.len));
        const utf8 = qnum(target, "u=") == 1;
        const chunked = qnum(target, "c=") == 1;
        const body = size_body[0..n];
        // UTF-8: 끝 세 바이트를 「가」(EA B0 80)로 — 글자 수와 바이트 수가 달라진다.
        const tmp: [3]u8 = .{ 0xEA, 0xB0, 0x80 };
        var hb: [512]u8 = undefined;
        if (chunked) {
            writeAll(conn, "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
            var off: usize = 0;
            while (off < n) {
                const k = @min(n - off, 7777);
                writeAll(conn, std.fmt.bufPrint(&hb, "{x}\r\n", .{k}) catch return);
                if (utf8 and off + k == n) {
                    writeAll(conn, body[off .. off + k - 3]);
                    writeAll(conn, &tmp);
                } else writeAll(conn, body[off .. off + k]);
                writeAll(conn, "\r\n");
                off += k;
            }
            writeAll(conn, "0\r\n\r\n");
            return;
        }
        writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{n}) catch return);
        if (utf8) {
            writeAll(conn, body[0 .. n - 4]);
            writeAll(conn, &tmp);
            writeAll(conn, "\"");
        } else writeAll(conn, body);
        return;
    }
    if (std.mem.eql(u8, path, "/v20/r8/p")) return reply(conn, html, "<!doctype html><title>r8</title><script>" ++ read_js ++
        "var M=1048576;var L=[[M-1,0,0],[M,0,0],[M+1,0,0],[M,1,0],[M+1,1,0],[M,0,1],[M+1,0,1],[16384,0,0],[16385,0,1],[1,0,0]];var i=0;" ++
        "function step(){if(i>=L.length){document.title='r8done';return}var x=L[i];i++;F('/v20/r8/size?n='+x[0]+'&c='+x[1]+'&u='+x[2]+'&i='+i).then(function(){setTimeout(step,150)})}setTimeout(step,300)</script>r8");
    // ── r9: 수명 ──
    if (std.mem.eql(u8, path, "/v20/r9/pend")) return reply(conn, html, "<!doctype html><title>pend</title><script>" ++ read_js ++
        "setTimeout(function(){for(var i=0;i<20;i++)F('/v20/d?pd'+location.search.slice(1)+'_'+i+'&h=2500');for(var i=0;i<10;i++)F('/v20/d?pq'+location.search.slice(1)+'_'+i);" ++
        "if(location.search.indexOf('n2')>=0)for(var i=0;i<5;i++)F('/v20/d?pw'+location.search.slice(1)+'_'+i+'&d=2500');document.title='pfired'},200)</script>pend");
    // 9f: 같은 주소를 다시 — 첫 문서의 요청은 머리 뒤 3 s 붙잡고(이동으로 끊긴다 — CDP 끝이 없다), 다시 불러온 문서의 같은 주소는 곧.
    if (std.mem.eql(u8, path, "/v20/r9/rl")) return reply(conn, html, "<!doctype html><title>rl</title><script>" ++ read_js ++
        "var g=location.search.slice(1);setTimeout(function(){for(var i=0;i<10;i++)W('/v20/r9/hold1?k='+(i+(g.indexOf('b')>=0?100:0)),g);document.title='rlfired'},100)</script>rl");
    if (std.mem.eql(u8, path, "/v20/r9/hold1")) {
        const k: usize = @intCast(qnum(target, "k=") % 256);
        if (!hop_seen[2][k].swap(true, .acq_rel)) return data(conn, head, 0, 3000);
        return data(conn, head, 0, 0);
    }
    if (std.mem.eql(u8, path, "/v20/r9/flood")) return reply(conn, html, "<!doctype html><title>fl</title><script>" ++
        "var t0=performance.now();var n=0;function burst(){for(var i=0;i<400;i++){fetch('data:application/json,'+(n++)).then(function(r){return r.text()}).catch(function(){})}" ++
        "if(performance.now()-t0<5000)setTimeout(burst,0);else document.title='fldone'}setTimeout(burst,200)</script>fl");
    return reply(conn, "text/plain", "x");
}

// ── 모으기 ────────────────────────────────────────────────────────────────────────────────────────────────

const Begin = struct { browser: u64, request: u64, url: []u8, host: []u8, final_host: []u8, site: []u8 = &.{}, expected: bool, flags: msg.NetFlags, at_ms: i64 };
const Body = struct {
    browser: u64,
    request: u64,
    data: std.ArrayList(u8) = .empty,
    ends: usize = 0,
    state: msg.NetBodyState = .unavailable,
    xbody: []u8 = &.{},
    xwho: []u8 = &.{},
    status: u16 = 0,
    decoded: u64 = 0,
    size: u32 = 0,
    end_ms: i64 = 0,
    end_session: u32 = 0,
    data_session_max: u32 = 0,
    data_frames: usize = 0,
    data_after_end: usize = 0,
    gap: bool = false,
    stripped: bool = false,
};

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    begins: std.ArrayList(Begin) = .empty,
    bodies: std.ArrayList(Body) = .empty,
    created: std.AutoHashMapUnmanaged(u64, void) = .empty,
    loads: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    states: std.AutoHashMapUnmanaged(u64, msg.NetRecordStatus) = .empty,
    state_log: std.ArrayList(struct { browser: u64, session: u32, status: msg.NetRecordStatus }) = .empty,
    titles: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    gone: std.AutoHashMapUnmanaged(u64, void) = .empty,
    closed: std.AutoHashMapUnmanaged(u64, void) = .empty,
    stray_ends: usize = 0,

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
                const h: []u8 = self.gpa.dupe(u8, v.host) catch unreachable;
                self.begins.append(self.gpa, .{ .browser = v.browser, .request = v.request, .url = self.gpa.dupe(u8, v.url) catch &.{}, .host = h, .final_host = h, .site = self.gpa.dupe(u8, v.site) catch unreachable, .expected = v.flags2.body_expected, .flags = v.flags, .at_ms = os.nowMs() }) catch {};
                // 같은 번호의 새 시도(다시 시작) — 새 본문 자리.
                if (v.flags2.body_expected) {
                    const old = self.body(v.browser, v.request);
                    if (old.ends > 0) self.bodies.append(self.gpa, .{ .browser = v.browser, .request = v.request }) catch {};
                }
            },
            .net_redirect => |v| {
                var i = self.begins.items.len;
                while (i > 0) {
                    i -= 1;
                    const b = &self.begins.items[i];
                    if (b.browser == v.browser and b.request == v.request) {
                        b.final_host = self.gpa.dupe(u8, v.host) catch &.{};
                        break;
                    }
                }
            },
            .net_response => |v| {
                const b = self.body(v.browser, v.request);
                b.status = v.status;
                b.stripped = v.flags.stripped;
                var it = net_fields.HeaderIterator.init(v.headers);
                while (it.next()) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "x-body")) b.xbody = self.gpa.dupe(u8, h.value) catch &.{};
                    if (std.ascii.eqlIgnoreCase(h.name, "x-who")) b.xwho = self.gpa.dupe(u8, h.value) catch &.{};
                }
            },
            .net_body_data => |v| {
                const b = self.body(v.browser, v.request);
                b.data_frames += 1;
                b.data_session_max = @max(b.data_session_max, v.session);
                if (b.ends > 0) b.data_after_end += 1;
                if (v.offset == b.data.items.len) b.data.appendSlice(self.gpa, v.bytes) catch {} else b.gap = true;
            },
            .net_body_end => |v| {
                const b = self.body(v.browser, v.request);
                b.ends += 1;
                b.state = v.state;
                b.decoded = v.decoded;
                b.size = v.size;
                b.end_ms = os.nowMs();
                b.end_session = v.session;
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
fn hasState(r: *Run, id: u64) bool {
    return r.states.contains(id);
}

const Tally = struct {
    total: usize = 0,
    expected: usize = 0,
    own: usize = 0,
    wrong: usize = 0,
    unknown: usize = 0,
    ambiguous: usize = 0,
    other: usize = 0,
    no_end: usize = 0,
    multi_end: usize = 0,
    after_end: usize = 0,
    states: [16]usize = @splat(0),
    notes: [900]u8 = undefined,
    notes_len: usize = 0,

    fn note(t: *Tally, comptime fmt: []const u8, args: anytype) void {
        const piece = std.fmt.bufPrint(t.notes[t.notes_len..], fmt, args) catch return;
        t.notes_len += piece.len;
    }
};

fn ownBody(x: *const Body) bool {
    var want: [64]u8 = undefined;
    const wnt = std.fmt.bufPrint(&want, "{{\"n\":\"{s}\"}}", .{x.xbody}) catch return false;
    return std.mem.eql(u8, x.data.items, wnt);
}

/// `who` 는 응답 머리 X-Who(서버가 요청의 x-who 를 되돌림).
fn tally(r: *Run, browser: u64, at: usize, needle: []const u8, who: ?[]const u8) Tally {
    var t: Tally = .{};
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(r.gpa);
    for (r.begins.items[at..]) |b| if (b.browser == browser and std.mem.indexOf(u8, b.url, needle) != null) {
        if (seen.contains(b.request)) continue;
        seen.put(r.gpa, b.request, {}) catch {};
        const x = r.body(browser, b.request);
        if (who) |w| if (!std.mem.eql(u8, x.xwho, w)) continue;
        t.total += 1;
        if (b.expected) t.expected += 1;
        if (x.ends == 1) t.states[@backingInt(x.state)] += 1;
        if (b.expected and x.ends == 0) t.no_end += 1;
        if (x.ends > 1) t.multi_end += 1;
        t.after_end += x.data_after_end;
        if (x.ends >= 1 and x.state == .captured) {
            if (x.xbody.len == 0) {
                t.unknown += 1;
                t.note(" [req {d} status {d} no X-Body got {s}]", .{ b.request, x.status, x.data.items[0..@min(x.data.items.len, 24)] });
            } else if (ownBody(x)) {
                t.own += 1;
            } else {
                t.wrong += 1;
                t.note(" [WRONG req {d}{s} who {s} X-Body {s} got {s}]", .{ b.request, if (b.flags.service_worker) " sw" else "", x.xwho, x.xbody, x.data.items[0..@min(x.data.items.len, 24)] });
            }
        } else if (x.ends >= 1 and x.state == .ambiguous) {
            t.ambiguous += 1;
        } else {
            t.other += 1;
        }
    };
    return t;
}

fn stateLine(t: *const Tally, buf: []u8) []const u8 {
    var n: usize = 0;
    for (t.states, 0..) |c, i| if (c > 0) {
        if (i >= @import("type_info_fields").enumFields(msg.NetBodyState).len) continue;
        const piece = std.fmt.bufPrint(buf[n..], " {s}={d}", .{ @tagName(@as(msg.NetBodyState, @fromBackingInt(@intCast(i)))), c }) catch break;
        n += piece.len;
    };
    return buf[0..n];
}

fn lineOf(t: *const Tally, buf: []u8, sl: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "CEF requests {d} (body_expected {d}) · own {d} · WRONG {d} · captured w/o X-Body {d} · ambiguous {d} · other {d} · no end {d} · several ends {d} · data after end {d} · states{s} ·{s}", .{ t.total, t.expected, t.own, t.wrong, t.unknown, t.ambiguous, t.other, t.no_end, t.multi_end, t.after_end, stateLine(t, sl), t.notes[0..t.notes_len] }) catch "";
}

/// 기대한 시작(body_expected)마다 끝이 꼭 하나인가 — `at` 부터 그 탭의 것.
const EndCheck = struct { expected: usize = 0, missing: usize = 0, doubled: usize = 0, after_end: usize = 0, states: [16]usize = @splat(0) };
fn endCheck(r: *Run, browser: u64, at: usize) EndCheck {
    var c: EndCheck = .{};
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(r.gpa);
    for (r.begins.items[at..]) |b| if (b.browser == browser and b.expected) {
        if (seen.contains(b.request)) continue;
        seen.put(r.gpa, b.request, {}) catch {};
        c.expected += 1;
        const x = r.body(browser, b.request);
        if (x.ends == 0) c.missing += 1;
        if (x.ends > 1) c.doubled += 1;
        c.after_end += x.data_after_end;
        if (x.ends >= 1) c.states[@backingInt(x.state)] += 1;
    };
    return c;
}

fn endLine(c: *const EndCheck, buf: []u8, sl: []u8) []const u8 {
    var t: Tally = .{};
    t.states = c.states;
    return std.fmt.bufPrint(buf, "body_expected begins {d} · no end {d} · several ends {d} · data after end {d} · states{s}", .{ c.expected, c.missing, c.doubled, c.after_end, stateLine(&t, sl) }) catch "";
}

fn enabled(name: []const u8) bool {
    const only = std.c.getenv("V20_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(only), name) != null;
}

fn openTab(r: *Run, id: u64, session: u32) !void {
    var u: [256]u8 = undefined;
    const size: msg.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
    try r.host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/v20/blank", .{port}) } });
    if (!r.waitFor(wait_ms, id, createdAndLoaded)) return error.BrowserNotCreated;
    try r.host.send(.{ .net_watch = .{ .browser = id, .on = true, .full = true, .any_host = true } });
    try r.host.send(.{ .net_record = .{ .browser = id, .on = true, .session = session } });
    _ = r.waitFor(5000, id, hasState);
}

fn watchOff(r: *Run, id: u64, any_host: bool) !void {
    var w: msg.NetWatch = .{ .browser = id, .on = true, .full = false, .any_host = any_host, .host_count = if (any_host) 0 else 1 };
    if (!any_host) w.hosts[0] = "127.0.0.1";
    try r.host.send(.{ .net_watch = w });
}

fn hasSecret(x: *const Body) bool {
    return std.mem.indexOf(u8, x.data.items, "SECRET") != null;
}

/// r1: 끝 호스트가 localhost 인 요청 — 잡은 수·비밀 바이트가 나간 수.
const Leak = struct { total: usize = 0, captured: usize = 0, secret: usize = 0, not_covered: usize = 0, other: usize = 0, no_end: usize = 0, data_frames: usize = 0, max_session: u32 = 0, states: [16]usize = @splat(0) };
fn leakOf(r: *Run, browser: u64, at: usize, needle: []const u8, min_session: u32) Leak {
    var l: Leak = .{};
    for (r.begins.items[at..]) |b| if (b.browser == browser and std.mem.indexOf(u8, b.url, needle) != null) {
        if (!std.mem.eql(u8, b.final_host, "localhost")) continue;
        const x = r.body(browser, b.request);
        l.total += 1;
        if (b.expected and x.ends == 0) l.no_end += 1;
        if (x.ends >= 1) l.states[@backingInt(x.state)] += 1;
        if (x.ends >= 1 and x.state == .captured and x.end_session >= min_session) l.captured += 1;
        if (x.ends >= 1 and x.state == .not_covered) l.not_covered += 1 else l.other += 1;
        if (x.data_session_max >= min_session and x.data_frames > 0) {
            l.data_frames += x.data_frames;
            if (hasSecret(x)) l.secret += 1;
        }
        l.max_session = @max(l.max_session, x.data_session_max);
    };
    return l;
}

fn leakLine(l: *const Leak, buf: []u8, sl: []u8) []const u8 {
    var t: Tally = .{};
    t.states = l.states;
    return std.fmt.bufPrint(buf, "requests ending at localhost {d} · captured (accepted session) {d} · secret bytes sent (accepted session) {d} · data frames {d} · not_covered {d} · other {d} · no end {d} · states{s}", .{ l.total, l.captured, l.secret, l.data_frames, l.not_covered, l.other, l.no_end, stateLine(&t, sl) }) catch "";
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    size_body = try gpa.alloc(u8, 1024 * 1024 + 16);
    @memset(size_body, 'a');
    size_body[0] = '"';
    try startServer();
    var detail: [4000]u8 = undefined;
    var sl: [400]u8 = undefined;
    var lb: [4000]u8 = undefined;
    const log_env: []const [*:0]const u8 = if (std.c.getenv("MARU_WEB_TEST_BODY_LOG") != null) &.{"MARU_WEB_TEST_BODY_LOG=1"} else &.{};
    var host = try Host.spawnWith(host_path, profile_arg, null, log_env);
    var host_alive = true;
    defer if (host_alive) {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    };
    try browsers_check.handshake(&host);
    var r: Run = .{ .host = &host, .gpa = gpa };
    try openTab(&r, rec_tab, 1);
    var session: u32 = 10;

    // ══ r1: 설정 끔 ══
    if (enabled("r1")) {
        // 1a/1b: 끔 — 묶인 호스트(127.0.0.1) / 어느 호스트든(에이전트 탭, 첫 사이트 127.0.0.1).
        inline for (.{ .{ false, "v20a-r1-off-hosts" }, .{ true, "v20a-r1-off-anyhost" } }) |c| {
            try watchOff(&r, rec_tab, c[0]);
            session += 1;
            try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = session } });
            r.pump(300);
            const at = r.begins.items.len;
            try r.navigate(rec_tab, "/v20/r1/a");
            const done = r.pumpTitle(rec_tab, "r1adone", 20_000);
            r.pump(1500);
            const l = leakOf(&r, rec_tab, at, "/v20/r1/", 0);
            const ctl_c2u2c = tally(&r, rec_tab, at, "?c", null);
            const ctl_own = tally(&r, rec_tab, at, "/v20/d?o", null);
            var l2: [600]u8 = undefined;
            var sl2: [400]u8 = undefined;
            // 끔이면 X-Body 값은 덜어 낸다(이름만) — 대조는 잡은 수와 본문 모양으로.
            const own_cap = ctl_own.states[@backingInt(msg.NetBodyState.captured)];
            var sites: [200]u8 = undefined;
            var sn: usize = 0;
            for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, "/v20/d?o") != null and sn < 150) {
                const piece = std.fmt.bufPrint(sites[sn..], " site='{s}' host='{s}'", .{ b.site, b.host }) catch "";
                sn += piece.len;
            };
            std.debug.print("diag {s} control sites:{s}\n", .{ c[1], sites[0..sn] });
            report(done and l.total >= 45 and l.captured == 0 and l.secret == 0 and l.data_frames == 0 and l.no_end == 0 and own_cap == 5 and ctl_own.wrong == 0 and ctl_c2u2c.wrong == 0, c[1], std.fmt.bufPrint(&detail, "{s} · control covered captured {d}/5 · control covered→uncovered→covered captured {d}/{d} wrong {d} states{s}", .{ leakLine(&l, &l2, &sl), own_cap, ctl_c2u2c.states[@backingInt(msg.NetBodyState.captured)], ctl_c2u2c.total, ctl_c2u2c.wrong, stateLine(&ctl_c2u2c, &sl2) }) catch "");
            // 주 프레임 문서: 덮이는 주소 → localhost 문서.
            const at2 = r.begins.items.len;
            try r.navigate(rec_tab, "/v20/r1/navredir");
            r.pump(2500);
            const ld = leakOf(&r, rec_tab, at2, "/v20/r1/navredir", 0);
            report(ld.total >= 1 and ld.captured == 0 and ld.secret == 0, c[1] ++ "-document", leakLine(&ld, &detail, &sl));
            try r.navigate(rec_tab, "/v20/blank?r1");
            r.pump(500);
        }
        // 1c: 켬 → 끔 사이(maru setNetworkFull(false): net_watch 끔 뒤 net_record 새 세션 — 앞 세션 frame 은 maru 가 바닥으로 버린다).
        {
            try r.host.send(.{ .net_watch = .{ .browser = rec_tab, .on = true, .full = true, .any_host = true } });
            session += 1;
            const s_on = session;
            try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = s_on } });
            r.pump(300);
            const at = r.begins.items.len;
            try r.navigate(rec_tab, "/v20/r1/b");
            const fired = r.pumpTitle(rec_tab, "r1bfired", 10_000);
            r.pump(100);
            try watchOff(&r, rec_tab, true);
            session += 1;
            const s_off = session;
            try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = s_off } });
            const done = r.pumpTitle(rec_tab, "r1bdone", 10_000);
            r.pump(1500);
            const l = leakOf(&r, rec_tab, at, "/v20/r1/c2u?", s_off);
            const l_old = leakOf(&r, rec_tab, at, "/v20/r1/c2u?", 0);
            var l2: [600]u8 = undefined;
            report(fired and done and l.total >= 25 and l.captured == 0 and l.secret == 0 and l.data_frames == 0, "v20a-r1-on-to-off-midflight", std.fmt.bufPrint(&detail, "after switch (session ≥ {d}): {s} · bytes in the old session (maru drops by its floor) frames {d}", .{ s_off, leakLine(&l, &l2, &sl), l_old.data_frames }) catch "");
        }
        // 1d: 끔 → 켬 사이 — 끔인 동안 머리가 온 응답(d=700)은 켠 뒤에도 덜어 낸 쪽(not_covered), 리다이렉트가 켠 뒤인 것(rd=500)은 관측.
        {
            const at = r.begins.items.len;
            try r.navigate(rec_tab, "/v20/r1/b?2");
            const fired = r.pumpTitle(rec_tab, "r1bfired", 10_000);
            r.pump(150);
            try r.host.send(.{ .net_watch = .{ .browser = rec_tab, .on = true, .full = true, .any_host = true } });
            const done = r.pumpTitle(rec_tab, "r1bdone", 10_000);
            r.pump(1500);
            const lm = leakOf(&r, rec_tab, at, "/v20/r1/c2u?m", 0);
            const ln = leakOf(&r, rec_tab, at, "/v20/r1/c2u?n", 0);
            var l2: [600]u8 = undefined;
            var l3: [600]u8 = undefined;
            var sl3: [400]u8 = undefined;
            var stripped_captured: usize = 0;
            for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, "/v20/r1/c2u?") != null) {
                const x = r.body(rec_tab, b.request);
                if (x.ends >= 1 and x.state == .captured and x.stripped) stripped_captured += 1;
            };
            // 판정: 응답 머리가 끔인 동안 온(net_response stripped) 요청은 켠 뒤에도 본문이 나가지 않는다. 연결 6 개 상한으로 나머지는 켠 뒤에 머리가 온다
            // (그 응답은 켬에서 왔다 — 잡는 것이 설계).
            var stripped_total: usize = 0;
            var stripped_secret: usize = 0;
            for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, "/v20/r1/c2u?") != null and std.mem.eql(u8, b.final_host, "localhost")) {
                const x = r.body(rec_tab, b.request);
                if (x.stripped) {
                    stripped_total += 1;
                    if (x.data_frames > 0 or hasSecret(x)) stripped_secret += 1;
                }
            };
            report(fired and done and stripped_total >= 1 and stripped_captured == 0 and stripped_secret == 0, "v20a-r1-off-to-on-midflight", std.fmt.bufPrint(&detail, "responses whose headers came while off (stripped) {d} · of them captured {d} · body bytes sent {d} · headers-while-off group overall: {s} · redirect after switch on (observed): {s}", .{ stripped_total, stripped_captured, stripped_secret, leakLine(&lm, &l2, &sl), leakLine(&ln, &l3, &sl3) }) catch "");
        }
        // 1e: 다시 켬 — 대조: localhost 본문을 잡는다.
        {
            const at = r.begins.items.len;
            try r.navigate(rec_tab, "/v20/r1/c");
            const done = r.pumpTitle(rec_tab, "r1cdone", 10_000);
            r.pump(1000);
            const t = tally(&r, rec_tab, at, "/v20/d?on", null);
            report(done and t.own == 10 and t.wrong == 0, "v20a-r1-back-on-control", lineOf(&t, &detail, &sl));
        }
    }

    // ══ r2: 페이지·워커 같은 주소 ══
    if (enabled("r2")) {
        inline for (.{ .{ "/v20/r2/p?ded", "v20a-r2-dedicated-instant" }, .{ "/v20/r2/p?dedslow", "v20a-r2-dedicated-60ms" }, .{ "/v20/r2/p?sh", "v20a-r2-shared-instant" }, .{ "/v20/r2/p?shslow", "v20a-r2-shared-60ms" } }) |c| {
            const at = r.begins.items.len;
            try r.navigate(rec_tab, c[0]);
            const done = r.pumpTitle(rec_tab, "r2done", 30_000);
            r.pump(5000);
            const all = tally(&r, rec_tab, at, "/v20/d?r2", null);
            const p = tally(&r, rec_tab, at, "/v20/d?r2", "p");
            const w = tally(&r, rec_tab, at, "/v20/d?r2", "w");
            report(done and all.wrong == 0 and all.unknown == 0 and w.own == 0 and all.no_end == 0 and all.multi_end == 0, c[1], std.fmt.bufPrint(&detail, "page own/amb/other {d}/{d}/{d} of {d} · worker CEF records {d} captured {d} · all: {s}", .{ p.own, p.ambiguous, p.other, p.total, w.total, w.own + w.wrong, lineOf(&all, &lb, &sl) }) catch "");
        }
    }

    // ══ r3: 같은 주소 동시 ══
    if (enabled("r3")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/v20/r3/p");
        const done = r.pumpTitle(rec_tab, "r3done", 40_000);
        r.pump(5000);
        inline for (.{ .{ "slowby?post", "v20a-r3-post-pair-reverse" }, .{ "slowby?get", "v20a-r3-get-pair-reverse" }, .{ "slowby?tri", "v20a-r3-triple-reverse" }, .{ "/v20/r3/aba", "v20a-r3-a-b-a-redirect" }, .{ "/v20/r3/self", "v20a-r3-self-redirect" } }) |c| {
            const t = tally(&r, rec_tab, at, c[0], null);
            report(done and t.wrong == 0 and t.unknown == 0 and t.no_end == 0 and t.multi_end == 0, c[1], lineOf(&t, &detail, &sl));
        }
        // 대조: 짝이 갈리지 않는 a·c(앞 것 300 ms) 의 제 본문 수.
        const a = tally(&r, rec_tab, at, "slowby?", "a");
        const cc = tally(&r, rec_tab, at, "slowby?", "c");
        const q = tally(&r, rec_tab, at, "/v20/r3/aba", "q");
        const tt = tally(&r, rec_tab, at, "/v20/r3/self", "t");
        report(true, "v20a-r3-own-rates(observed)", std.fmt.bufPrint(&detail, "slow first (a) own {d}/{d} amb {d} · fast second (c) own {d}/{d} amb {d} · plain same URL beside A→B→A own {d}/{d} amb {d} · plain beside self-redirect own {d}/{d} amb {d}", .{ a.own, a.total, a.ambiguous, cc.own, cc.total, cc.ambiguous, q.own, q.total, q.ambiguous, tt.own, tt.total, tt.ambiguous }) catch "");
    }

    // ══ r4: 물 높이 ══
    if (enabled("r4")) {
        inline for (.{ .{ "/v20/r4/p?noise", "v20a-r4-noise-batches" }, .{ "/v20/r4/p?giant", "v20a-r4-giant-url-io-delay" } }) |c| {
            const at = r.begins.items.len;
            const t0 = os.nowMs();
            try r.navigate(rec_tab, c[0]);
            const done = r.pumpTitle(rec_tab, "r4done", 60_000);
            r.pump(3000);
            const t = tally(&r, rec_tab, at, "/v20/d?r4", null);
            const p = tally(&r, rec_tab, at, "/v20/d?r4", "p");
            const ec = endCheck(&r, rec_tab, at);
            // 끝까지 걸린 시간(시작 → 본문 끝)의 최댓값.
            var max_lat: i64 = 0;
            for (r.begins.items[at..]) |b| if (b.browser == rec_tab and b.expected) {
                const x = r.body(rec_tab, b.request);
                if (x.ends >= 1) max_lat = @max(max_lat, x.end_ms - b.at_ms);
            };
            var l2: [600]u8 = undefined;
            var sl2: [400]u8 = undefined;
            report(done and t.wrong == 0 and t.unknown == 0 and ec.missing == 0 and ec.doubled == 0 and ec.after_end == 0, c[1], std.fmt.bufPrint(&detail, "same-URL page/worker: {s} · page own {d}/{d} · tab-wide: {s} · max begin→body end {d} ms · run {d} ms", .{ lineOf(&t, &lb, &sl), p.own, p.total, endLine(&ec, &l2, &sl2), max_lat, os.nowMs() - t0 }) catch "");
        }
    }

    // ══ r5: abort 뒤 다시 ══
    if (enabled("r5")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/v20/r5/p");
        const done = r.pumpTitle(rec_tab, "r5done", 40_000);
        r.pump(3000);
        inline for (.{ .{ "/v20/d?sm", "s2", "v20a-r5-strictmode-double" }, .{ "/v20/d?th", "t3", "v20a-r5-three-requests" }, .{ "/v20/d?hd", "h2", "v20a-r5-abort-after-headers" } }) |c| {
            const all = tally(&r, rec_tab, at, c[0], null);
            const keep = tally(&r, rec_tab, at, c[0], c[1]);
            report(done and all.wrong == 0 and all.unknown == 0 and keep.states[@backingInt(msg.NetBodyState.request_failed)] == 0 and all.no_end == 0 and all.multi_end == 0, c[2], std.fmt.bufPrint(&detail, "kept request ({s}) own {d}/{d} · request_failed {d} · ambiguous {d} · all: {s}", .{ c[1], keep.own, keep.total, keep.states[@backingInt(msg.NetBodyState.request_failed)], keep.ambiguous, lineOf(&all, &lb, &sl) }) catch "");
        }
    }

    // ══ r6: 서비스 워커 ══
    if (enabled("r6")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/v20/sw/p");
        const done = r.pumpTitle(rec_tab, "swdone", 40_000);
        r.pump(3000);
        var fb_leak: usize = 0;
        for (r.bodies.items) |*x| if (x.browser == rec_tab and std.mem.indexOf(u8, x.data.items, "FALLBACK") != null) {
            fb_leak += 1;
        };
        inline for (.{ .{ "/v20/sw/fail", "v20a-r6-sw-network-fail-fallback" }, .{ "/v20/sw/mod", "v20a-r6-sw-modified-request-passthrough" }, .{ "/v20/sw/post", "v20a-r6-sw-post-passthrough" }, .{ "/v20/sw/wrap", "v20a-r6-sw-rewrapped-response" }, .{ "/v20/sw/x", "v20a-r6-sw-respond-with-other-url" }, .{ "/v20/sw/y", "v20a-r6-sw-other-url-direct" } }) |c| {
            const t = tally(&r, rec_tab, at, c[0], null);
            report(done and t.wrong == 0 and t.no_end == 0 and t.multi_end == 0 and fb_leak == 0, c[1], std.fmt.bufPrint(&detail, "{s} · FALLBACK bodies sent {d}", .{ lineOf(&t, &lb, &sl), fb_leak }) catch "");
        }
    }

    // ══ r8: 크기 경계 ══
    if (enabled("r8")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/v20/r8/p");
        const done = r.pumpTitle(rec_tab, "r8done", 60_000);
        r.pump(2000);
        const M: u64 = 1024 * 1024;
        const Case = struct { n: u64, c: u8, u: u8, want: msg.NetBodyState };
        const cases = [_]Case{
            .{ .n = M - 1, .c = 0, .u = 0, .want = .captured }, .{ .n = M, .c = 0, .u = 0, .want = .captured },     .{ .n = M + 1, .c = 0, .u = 0, .want = .over_cap },
            .{ .n = M, .c = 1, .u = 0, .want = .captured },     .{ .n = M + 1, .c = 1, .u = 0, .want = .over_cap }, .{ .n = M, .c = 0, .u = 1, .want = .captured },
            .{ .n = M + 1, .c = 0, .u = 1, .want = .over_cap }, .{ .n = 16384, .c = 0, .u = 0, .want = .captured }, .{ .n = 16385, .c = 0, .u = 1, .want = .captured },
            .{ .n = 1, .c = 0, .u = 0, .want = .captured },
        };
        var ok_all = done;
        var dn: usize = 0;
        for (cases, 1..) |cs, i| {
            var nb: [80]u8 = undefined;
            const needle = std.fmt.bufPrint(&nb, "/v20/r8/size?n={d}&c={d}&u={d}&i={d}", .{ cs.n, cs.c, cs.u, i }) catch continue;
            var got: ?*Body = null;
            for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.endsWith(u8, b.url, needle)) {
                got = r.body(rec_tab, b.request);
            };
            const x = got orelse {
                ok_all = false;
                const piece = std.fmt.bufPrint(detail[dn..], " [n={d} c={d} u={d}: no record]", .{ cs.n, cs.c, cs.u }) catch "";
                dn += piece.len;
                continue;
            };
            const good = x.ends == 1 and x.state == cs.want and !x.gap and (cs.want != .captured or (x.data.items.len == cs.n and x.size == cs.n)) and (cs.want != .over_cap or (x.data.items.len == 0 and x.decoded == cs.n));
            if (!good) ok_all = false;
            const piece = std.fmt.bufPrint(detail[dn..], " [n={d} chunked={d} utf8={d}: {s} ends {d} bytes {d} size {d} decoded {d}{s}]", .{ cs.n, cs.c, cs.u, @tagName(x.state), x.ends, x.data.items.len, x.size, x.decoded, if (good) "" else " UNEXPECTED" }) catch "";
            dn += piece.len;
        }
        report(ok_all, "v20a-r8-size-boundaries", detail[0..dn]);
    }

    // ══ r9: 수명 ══
    if (enabled("r9")) {
        // 9a 탭 닫힘: 머리만 온 본문 20 + 끝난 것 10 이 기다리는 동안 destroy_browser.
        {
            const cid: u64 = 131;
            try openTab(&r, cid, 900);
            const at = r.begins.items.len;
            try r.navigate(cid, "/v20/r9/pend?c");
            _ = r.pumpTitle(cid, "pfired", 10_000);
            r.pump(400);
            try r.host.send(.{ .destroy_browser = cid });
            r.pump(4000);
            const ec = endCheck(&r, cid, at);
            report(ec.expected >= 25 and ec.missing == 0 and ec.doubled == 0 and ec.after_end == 0, "v20a-r9-tab-close-pending", endLine(&ec, &detail, &sl));
        }
        // 9b 이동: 기다리는 동안 다른 문서로 — 머리만 온 본문(pd)·끝난 것(pq)·머리도 안 온 것(pw). 끝이 언제 오는가(4·10·20·35 s).
        {
            const at = r.begins.items.len;
            try r.navigate(rec_tab, "/v20/r9/pend?n2");
            _ = r.pumpTitle(rec_tab, "pfired", 10_000);
            r.pump(400);
            const t_nav = os.nowMs();
            try r.navigate(rec_tab, "/v20/blank?r9n");
            var marks: [4]usize = undefined;
            var dn: usize = 0;
            for ([_]u32{ 4000, 6000, 10_000, 15_000 }, 0..) |ms, mi| {
                r.pump(ms);
                const ec_i = endCheck(&r, rec_tab, at);
                marks[mi] = ec_i.missing;
            }
            const ec = endCheck(&r, rec_tab, at);
            // W9d② 20 회 검증 N1: 앞 문서와 함께 떠난 요청(머리만 온 pd·머리도 안 온 pw)은 `unmatched`(「다른 프로세스·worker」)가 아니라
            // `unavailable` 이다 — 그중 `unmatched` 는 0 이어야 한다(문서가 떠난 뒤 CEF 가 성공으로 끝낸 pd 는 짝 없는 시한 뒤에).
            var cut_unmatched: usize = 0;
            inline for (.{ "/v20/d?pdn2", "/v20/d?pqn2", "/v20/d?pwn2" }) |nd| {
                const t = tally(&r, rec_tab, at, nd, null);
                if (!std.mem.eql(u8, nd, "/v20/d?pqn2")) cut_unmatched += t.states[@backingInt(msg.NetBodyState.unmatched)];
                var maxe: i64 = 0;
                for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, nd) != null) {
                    const x = r.body(rec_tab, b.request);
                    if (x.ends >= 1) maxe = @max(maxe, x.end_ms - t_nav);
                };
                const piece = std.fmt.bufPrint(detail[dn..], " [{s}: {d} begins no end {d} states{s} last end {d} ms after nav]", .{ nd, t.total, t.no_end, stateLine(&t, &sl), maxe }) catch "";
                dn += piece.len;
            }
            var l2: [600]u8 = undefined;
            var sl2: [400]u8 = undefined;
            const piece = std.fmt.bufPrint(detail[dn..], " · missing ends at +4/+10/+20/+35 s: {d}/{d}/{d}/{d} · {s}", .{ marks[0], marks[1], marks[2], marks[3], endLine(&ec, &l2, &sl2) }) catch "";
            dn += piece.len;
            report(ec.expected >= 25 and marks[1] == 0 and cut_unmatched == 0 and ec.missing == 0 and ec.doubled == 0 and ec.after_end == 0, "v20a-r9-navigation-pending", detail[0..dn]);
        }
        // 9f 이동으로 끊긴 요청(CDP 끝이 오지 않는다)의 같은 주소를 곧 다시 — 다시 불러온 문서의 요청은 제 본문이고 틀린 본문은 없다.
        //    (r9 의 옛 문서 요청 기록은 CDP 쪽에 끝 없이 남는다 — 그 뒤 같은 주소의 짝에 끼는가.) 두 꼴: 같은 주소(k 0..9), 대조(다른 주소 k 100..109).
        {
            const at = r.begins.items.len;
            try r.navigate(rec_tab, "/v20/r9/rl?a");
            _ = r.pumpTitle(rec_tab, "rlfired", 10_000);
            r.pump(300);
            try r.navigate(rec_tab, "/v20/r9/rl?a2");
            _ = r.pumpTitle(rec_tab, "rlfired", 10_000);
            r.pump(6000);
            // 대조: 첫 문서의 요청이 끝난 뒤(3 s 붙잡음 + 여유) 같은 주소를 다시 — 끝 없는 CDP 기록이 없다.
            const at2 = r.begins.items.len;
            try r.navigate(rec_tab, "/v20/r9/rl?b");
            _ = r.pumpTitle(rec_tab, "rlfired", 10_000);
            r.pump(4500);
            try r.navigate(rec_tab, "/v20/r9/rl?b2");
            _ = r.pumpTitle(rec_tab, "rlfired", 10_000);
            r.pump(6000);
            const first = tally(&r, rec_tab, at, "/v20/r9/hold1", "a");
            const again = tally(&r, rec_tab, at, "/v20/r9/hold1", "a2");
            const ctl_again = tally(&r, rec_tab, at2, "/v20/r9/hold1", "b2");
            const ec = endCheck(&r, rec_tab, at);
            var l2: [600]u8 = undefined;
            var sl2: [400]u8 = undefined;
            var sl3: [400]u8 = undefined;
            var sl4: [400]u8 = undefined;
            report(again.wrong == 0 and first.wrong == 0 and ec.missing == 0 and ec.doubled == 0, "v20a-r9-reload-same-urls", std.fmt.bufPrint(&detail, "cut first document: total {d} states{s} · reloaded same URLs: own {d}/{d} wrong {d} states{s} · control (same URLs reloaded after the first load finished) own {d}/{d} states{s} · {s}", .{ first.total, stateLine(&first, &sl), again.own, again.total, again.wrong, stateLine(&again, &sl2), ctl_again.own, ctl_again.total, stateLine(&ctl_again, &sl3), endLine(&ec, &l2, &sl4) }) catch "");
        }
        // 9c 렌더러 죽음: 기다리는 동안 Page.crash — 끝은 꼭 하나, 다시 불러온 뒤(다시 켜지 않고) 잡는다.
        {
            const at = r.begins.items.len;
            try r.navigate(rec_tab, "/v20/r9/pend?k");
            _ = r.pumpTitle(rec_tab, "pfired", 10_000);
            r.pump(400);
            _ = r.gone.remove(rec_tab);
            try r.host.send(.{ .devtools_call = .{ .browser = rec_tab, .call = 7701, .method = "Page.crash", .params_size = 0 } });
            const Gone = struct {
                fn got(x: *Run, id: u64) bool {
                    return x.gone.contains(id);
                }
            };
            const gone = r.waitFor(5000, rec_tab, Gone.got);
            r.pump(3500);
            const ec = endCheck(&r, rec_tab, at);
            const at2 = r.begins.items.len;
            try r.navigate(rec_tab, "/v20/r1/c");
            _ = r.pumpTitle(rec_tab, "r1cdone", 10_000);
            r.pump(800);
            const t = tally(&r, rec_tab, at2, "/v20/d?on", null);
            var l2: [600]u8 = undefined;
            report(gone and ec.expected >= 25 and ec.missing == 0 and ec.doubled == 0 and ec.after_end == 0 and t.own == 10, "v20a-r9-renderer-crash-pending", std.fmt.bufPrint(&detail, "renderer_gone {} · {s} · after reload own {d}/10", .{ gone, endLine(&ec, &l2, &sl), t.own }) catch "");
        }
        // 9d 쏟아짐 밸브: data: fetch 를 쉬지 않고 — paused 가 오는가, 그 뒤 시작은 body_expected 가 없는가, 다시 켜면 잡는가.
        {
            const at = r.begins.items.len;
            const log_at = r.state_log.items.len;
            try r.navigate(rec_tab, "/v20/r9/flood");
            _ = r.pumpTitle(rec_tab, "fldone", 20_000);
            r.pump(1500);
            var paused = false;
            for (r.state_log.items[log_at..]) |s| if (s.browser == rec_tab and s.status == .paused) {
                paused = true;
            };
            const ec = endCheck(&r, rec_tab, at);
            // 멈춘 뒤 대조 페이지: 기대한 시작이 없어야 한다.
            const at2 = r.begins.items.len;
            try r.navigate(rec_tab, "/v20/r1/c");
            _ = r.pumpTitle(rec_tab, "r1cdone", 10_000);
            r.pump(500);
            const ec2 = endCheck(&r, rec_tab, at2);
            session += 1;
            try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = session } });
            r.pump(500);
            const at3 = r.begins.items.len;
            try r.navigate(rec_tab, "/v20/r1/c?again");
            _ = r.pumpTitle(rec_tab, "r1cdone", 10_000);
            r.pump(800);
            const t3 = tally(&r, rec_tab, at3, "/v20/d?on", null);
            var l2: [600]u8 = undefined;
            report(ec.missing == 0 and ec.doubled == 0 and (!paused or ec2.expected == 0) and t3.own == 10, "v20a-r9-flood-valve", std.fmt.bufPrint(&detail, "paused seen {} · during flood: {s} · after pause body_expected begins {d} · after re-enable own {d}/10", .{ paused, endLine(&ec, &l2, &sl), ec2.expected, t3.own }) catch "");
        }
        // 9e sidecar SIGKILL(이 판정자가 띄운 host) 뒤 다시 띄움 — 같은 프로필로 새 sidecar 가 뜨고 기록이 새 세션으로 돈다; 죽인 host 의 자식이 남지 않는다.
        {
            try r.navigate(rec_tab, "/v20/r9/pend?s");
            _ = r.pumpTitle(rec_tab, "pfired", 10_000);
            r.pump(300);
            var kids: [64]c_int = undefined;
            var nk: usize = 0;
            {
                var cb: [96]u8 = undefined;
                const cmd = std.fmt.bufPrintSentinel(&cb, "ps -A -o pid=,ppid= | awk '$2=={d}{{print $1}}'", .{host.pid}, 0) catch unreachable;
                if (popen(cmd, "r")) |f| {
                    var line: [64]u8 = undefined;
                    while (fgets(&line, line.len, f)) |_| {
                        const s = std.mem.trim(u8, std.mem.sliceTo(&line, 0), " \n\t");
                        if (nk < kids.len) {
                            kids[nk] = std.fmt.parseInt(c_int, s, 10) catch continue;
                            nk += 1;
                        }
                    }
                    _ = pclose(f);
                }
            }
            const killed_pid = host.pid;
            _ = kill(host.pid, 9);
            _ = host.wait(5000);
            host_alive = false;
            os.sleepMs(3000);
            var left: usize = 0;
            for (kids[0..nk]) |k| if (kill(k, 0) == 0) {
                left += 1;
            };
            var pb2: [1100]u8 = undefined;
            const prof2 = std.fmt.bufPrintSentinel(&pb2, "{s}", .{profile_arg}, 0) catch unreachable;
            var h2 = try Host.spawnWith(host_path, prof2, null, &.{});
            defer {
                h2.send(.shutdown) catch {};
                _ = h2.wait(wait_ms);
            }
            const hs_ok = if (browsers_check.handshake(&h2)) |_| true else |_| false;
            var r2: Run = .{ .host = &h2, .gpa = gpa };
            var own: usize = 0;
            if (hs_ok) {
                try openTab(&r2, rec_tab, 5000);
                const at = r2.begins.items.len;
                try r2.navigate(rec_tab, "/v20/r1/c?restart");
                _ = r2.pumpTitle(rec_tab, "r1cdone", 15_000);
                r2.pump(800);
                own = tally(&r2, rec_tab, at, "/v20/d?on", null).own;
            }
            report(hs_ok and left == 0 and own == 10, "v20a-r9-sidecar-sigkill-restart", std.fmt.bufPrint(&detail, "killed host pid {d} (children {d}, alive 3 s later {d}) · restarted on same profile: handshake {} · own after re-record {d}/10", .{ killed_pid, nk, left, hs_ok, own }) catch "");
        }
    }
}
