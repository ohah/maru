//! W9d② 최종 재검증 1–10 회차(검증자 v20f A — 6d8d39dbd 의 재검증, 고친 뒤 회귀 판정으로 남김). `--review-body-v20fa`, 고른 항목만 `V20F_ONLY=r1,r2…`.
//! 재검증 3 차: 검증자 v20h A 의 항목(`v20h-*` — 새 문서의 첫 요청이 알림보다 먼저 나간 꼴·같은 사이트 iframe 의 같은 주소·워커 기록 뒤의
//! 빠른 꼬리)을 더했고, 같은 주소 GET 의 동시성을 보려던 항목은 `cache:'no-store'` 로 보낸다(N-4 — Chromium 의 HTTP 캐시 잠금이 같은 주소 GET 을
//! 줄 세워, 앞 요청의 머리가 오기 전에는 뒤 요청이 나가지 않았다).
//! 판정자가 maru 역할로 `net_watch`·`net_record` 를 보내고 `net_*` 를 모은다. 서버는 응답마다 셈(`X-Body: N`)과 보낸 쪽(`X-Who`)을 싣는다.

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
/// v20g A: hits per key for the chain handler.
var g_hits: [256]std.atomic.Value(u8) = @splat(std.atomic.Value(u8).init(0));

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

/// `W` 는 HTTP 캐시를 거치지 않는다(`cache:'no-store'` — 재검증 3 차 N-4: 캐시 잠금이 같은 주소 GET 을 줄 세워 동시성을 보려던 항목이 그것을
/// 보지 못했다).
const read_js = "function F(u,o){return fetch(u,o).then(function(r){return r.text()}).catch(function(){})}" ++
    "function W(u,w){return F(u,{headers:{'x-who':w},cache:'no-store'})}";

/// 서비스 워커: /v20f/sw/dl?d=N — N ms 뒤 그 요청을 그대로 넘긴다(출처 network).
const sw_js = "self.addEventListener('install',function(e){self.skipWaiting()});" ++
    "self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
    "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(u.pathname!='/v20f/sw/dl')return;var d=+(u.searchParams.get('d')||0);" ++
    "e.respondWith(new Promise(function(res){setTimeout(function(){res(fetch(e.request))},d)}))});";
const reg_js = "function reg(next){navigator.serviceWorker.register('/v20f/sw/sw.js',{scope:'/v20f/sw/'}).then(function(){return navigator.serviceWorker.ready}).then(function(){" ++
    "if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}setTimeout(next,300)})}";

fn serveOne(conn: c_int) void {
    defer _ = std.c.close(conn);
    var req: [8192]u8 = undefined;
    var have: usize = 0;
    var tail: [4]u8 = @splat(0);
    var scratch: [65536]u8 = undefined;
    while (true) {
        const n_read = std.c.read(conn, &scratch, scratch.len);
        if (n_read <= 0) break;
        const got = scratch[0..@intCast(n_read)];
        const k = @min(got.len, req.len - have);
        @memcpy(req[have..][0..k], got[0..k]);
        have += k;
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
    var lb: [512]u8 = undefined;
    if (std.mem.eql(u8, method, "OPTIONS")) return replyC(conn, "204 No Content", "text/plain", "Access-Control-Allow-Headers: x-who, content-type\r\nAccess-Control-Allow-Methods: GET, POST, HEAD\r\n", "");
    if (std.mem.eql(u8, path, "/v20/blank")) return reply(conn, html, "<!doctype html><title>blank</title>blank");
    if (std.mem.eql(u8, path, "/v20/d")) return data(conn, head, qnum(target, "d="), qnum(target, "h="));
    // ── r1: 설정 끔·어느 호스트든 — 덮기의 표 ──
    if (std.mem.eql(u8, path, "/v20f/r1/c2u")) return replyC(conn, "302 Found", "text/plain", std.fmt.bufPrint(&lb, "Location: http://localhost:{d}/v20/d{s}\r\n", .{ port, query }) catch return, "");
    if (std.mem.eql(u8, path, "/v20f/r1/u2c")) return replyC(conn, "302 Found", "text/plain", std.fmt.bufPrint(&lb, "Location: http://127.0.0.1:{d}/v20/d{s}\r\n", .{ port, query }) catch return, "");
    if (std.mem.eql(u8, path, "/v20f/r1/doc")) return reply(conn, html, "<!doctype html><title>fdoc</title>DOCBODY");
    if (std.mem.eql(u8, path, "/v20f/r1/navredir")) return replyC(conn, "302 Found", "text/plain", std.fmt.bufPrint(&lb, "Location: http://localhost:{d}/v20f/r1/doc?r\r\n", .{port}) catch return, "");
    if (std.mem.eql(u8, path, "/v20f/r1/navback")) return replyC(conn, "302 Found", "text/plain", std.fmt.bufPrint(&lb, "Location: http://127.0.0.1:{d}/v20f/r1/doc?b\r\n", .{port}) catch return, "");
    if (std.mem.eql(u8, path, "/v20f/r1/if")) return reply(conn, html, "<!doctype html><title>if</title><script>" ++ read_js ++
        "var P='http://127.0.0.1:'+location.port;var x=location.search.indexOf('x')>=0;setTimeout(function(){" ++
        "if(x){for(var i=0;i<5;i++)F(P+'/v20/d?fy'+i);for(var i=0;i<5;i++)F('/v20/d?fz'+i)}else{for(var i=0;i<5;i++)F('/v20/d?fi'+i)}},300)</script>if");
    if (std.mem.eql(u8, path, "/v20f/r1/a")) return reply(conn, html, "<!doctype html><title>r1a</title><script>" ++ read_js ++
        "var L='http://localhost:'+location.port;setTimeout(function(){" ++
        "for(var i=0;i<10;i++)F('/v20/d?fo'+i);" ++
        "for(var i=0;i<10;i++)F(L+'/v20/d?fx'+i);" ++
        "for(var i=0;i<10;i++)F('/v20f/r1/c2u?fc'+i);" ++
        "for(var i=0;i<10;i++)F(L+'/v20f/r1/u2c?fu'+i);" ++
        "setTimeout(function(){document.title='r1adone'},3000)},300)</script>" ++
        "<iframe src='/v20f/r1/if'></iframe><script>document.write(\"<iframe src='http://localhost:\"+location.port+\"/v20f/r1/if?x'></iframe>\")</script>r1a");
    // ── r2: 페이지·다른 사이트 iframe(다른 프로세스)·같은 사이트 iframe 이 같은 주소 ──
    if (std.mem.eql(u8, path, "/v20f/r2/if")) return reply(conn, html, "<!doctype html><title>if2</title><script>" ++ read_js ++
        "var s=location.search.indexOf('s')>=0;onmessage=function(e){if(s)W(e.data,'s');else F(e.data)}</script>if2");
    if (std.mem.eql(u8, path, "/v20f/r2/p")) return reply(conn, html, "<!doctype html><title>r2</title><script>" ++ read_js ++
        "var P='http://127.0.0.1:'+location.port;var q=location.search.slice(1);</script>" ++
        "<script>document.write(\"<iframe id=x src='http://localhost:\"+location.port+\"/v20f/r2/if'></iframe><iframe id=s src='/v20f/r2/if?s'></iframe>\")</script><script>" ++
        "var k=0;function step(){if(k>=30){setTimeout(function(){document.title='r2done'},1500);return}var j=k;k++;" ++
        "var u=P+'/v20/d?r2x'+q+'_'+j;var v=P+'/v20/d?r2s'+q+'_'+j;var off=j%11;" ++
        "if(j%2){W(u,'p');setTimeout(function(){document.getElementById('x').contentWindow.postMessage(u,'*')},off)}else{document.getElementById('x').contentWindow.postMessage(u,'*');setTimeout(function(){W(u,'p')},off)}" ++
        "W(v,'p');setTimeout(function(){document.getElementById('s').contentWindow.postMessage(v,'*')},off);" ++
        "setTimeout(step,150)}onload=function(){setTimeout(step,500)}</script>r2");
    // ── r3: 두 탭이 같은 주소·조각만 다른 주소·HEAD 와 GET ──
    if (std.mem.eql(u8, path, "/v20f/r3/slow")) {
        const who = whoOf(head);
        const d: u64 = if (std.mem.eql(u8, who, "a")) 300 else if (std.mem.eql(u8, who, "b")) 150 else 0;
        if (std.mem.eql(u8, method, "HEAD")) {
            os.sleepMs(@intCast(d));
            const n = counter.fetchAdd(1, .monotonic);
            var hb: [512]u8 = undefined;
            writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Expose-Headers: X-Body\r\nX-Body: {d}\r\nX-Who: {s}\r\nConnection: close\r\n\r\n", .{ n, who }) catch return);
            return;
        }
        return data(conn, head, d, 0);
    }
    if (std.mem.eql(u8, path, "/v20f/r3/two")) return reply(conn, html, "<!doctype html><title>two</title><script>" ++ read_js ++
        "var t=location.search.indexOf('t=a')>=0?'a':'c';var g=location.search.slice(1);var k=0;function step(){if(k>=30){setTimeout(function(){document.title='twodone'},1500);return}var j=k;k++;" ++
        "W('/v20f/r3/slow?tw'+(g.indexOf('x')>=0?'x':'')+j,t);setTimeout(step,120)}setTimeout(step,400)</script>two");
    if (std.mem.eql(u8, path, "/v20f/r3/frag")) return reply(conn, html, "<!doctype html><title>frag</title><script>" ++ read_js ++
        "var k=0;function step(){if(k>=24){setTimeout(function(){document.title='fragdone'},1500);return}var j=k;k++;" ++
        "W('/v20f/r3/slow?fr'+j+'#a','a');setTimeout(function(){W('/v20f/r3/slow?fr'+j+'#b','c')},5);" ++
        "fetch('/v20f/r3/slow?hg'+j,{method:'HEAD',headers:{'x-who':'a'}}).catch(function(){});W('/v20f/r3/slow?hg'+j,'c');" ++
        "setTimeout(step,400)}setTimeout(step,300)</script>frag");
    // ── r4: 렌더러 주 스레드가 막힌 동안(CDP 사건이 늦다) ──
    if (std.mem.eql(u8, path, "/v20f/r4/busy")) return reply(conn, html, "<!doctype html><title>busy</title><script>" ++ read_js ++
        "var B=[1500,2500,3500];var k=0;function step(){if(k>=12){setTimeout(function(){document.title='busydone'},4500);return}var j=k;k++;var b=B[j%3];" ++
        "for(var i=0;i<5;i++)F('/v20/d?bz'+b+'_'+j+'_'+i);var t=performance.now();while(performance.now()-t<b){}setTimeout(step,400)}setTimeout(step,300)</script>busy");
    // ── r5: 새 문서 맨 앞의 abort·다시(문서 시작 알림과 경주), 다시 받은 요청이 기다리는 동안 이동 ──
    if (std.mem.eql(u8, path, "/v20f/r5/early")) return reply(conn, html, "<!doctype html><head><script>" ++ read_js ++
        "function A(u,w,c){return F(u,{signal:c.signal,headers:{'x-who':w}})}var g=location.search.slice(1);" ++
        "var dl=g.indexOf('busy')>=0?'&d=700':'';for(var i=0;i<3;i++){var u1='/v20/d?ea'+g+'_'+i+dl;var c=new AbortController();A(u1,'s1',c);c.abort();W(u1,'s2');" ++
        "var u2='/v20/d?eb'+g+'_'+i+dl;var c1=new AbortController(),c2=new AbortController();A(u2,'t1',c1);A(u2,'t2',c2);c1.abort();c2.abort();W(u2,'t3')}" ++
        "if(g.indexOf('busy')>=0){var t0=performance.now();while(performance.now()-t0<400){}}" ++
        "</script><title>early</title></head><body>early<script>setTimeout(function(){document.title='earlydone'},1200)</script></body>");
    if (std.mem.eql(u8, path, "/v20f/r5/navcut")) return reply(conn, html, "<!doctype html><title>navcut</title><script>" ++ read_js ++
        "function A(u,w,c){return F(u,{signal:c.signal,headers:{'x-who':w}})}var g=location.search.slice(1);setTimeout(function(){" ++
        "for(var i=0;i<4;i++){var u='/v20/d?nc'+g+'_'+i+'&d=2000';var c=new AbortController();A(u,'s1',c);c.abort();W(u,'s2')}" ++
        "document.title='ncfired'},200)</script>navcut");
    // ── r6: 서비스 워커가 늦게 넘긴다(0·1.5·2.5 s) ──
    if (std.mem.eql(u8, path, "/v20f/sw/sw.js")) return reply(conn, "application/javascript", sw_js);
    if (std.mem.eql(u8, path, "/v20f/sw/dl")) return data(conn, head, 0, 0);
    if (std.mem.eql(u8, path, "/v20f/sw/p")) return reply(conn, html, "<!doctype html><title>sw</title><script>" ++ read_js ++ reg_js ++
        "var D=[0,1500,2500];var k=0;function step(){if(k>=24){setTimeout(function(){document.title='swdone'},5000);return}var j=k;k++;" ++
        "W('/v20f/sw/dl?d='+D[j%3]+'&k='+j,'p');setTimeout(step,250)}reg(step)</script>sw");
    // ── r9: 머리 전에 끊긴 요청과 같은 주소를 다시 불러온 문서가 ──
    if (std.mem.eql(u8, path, "/v20f/r9/hp")) {
        const v = qnum(target, "v=") % 4;
        const k: usize = @intCast((qnum(target, "k=") + 100 * qnum(target, "x=")) % 256);
        if (!hop_seen[v][k].swap(true, .acq_rel)) {
            // 첫 번(옛 문서): v=1 은 머리 전 3 s, v=2 는 머리 곧 본문 3 s 뒤.
            if (v == 2) return data(conn, head, 0, 3000);
            return data(conn, head, 3000, 0);
        }
        return data(conn, head, qnum(target, "d="), 0);
    }
    if (std.mem.eql(u8, path, "/v20f/r9/rlp")) return reply(conn, html, "<!doctype html><title>rlp</title><script>" ++ read_js ++
        "var q=location.search.slice(1);var g=q.split('&')[0];var rest=q.slice(g.length);var L=rest.indexOf('x=1')>=0?'http://localhost:'+location.port:'';var n=L?4:10;setTimeout(function(){for(var i=0;i<n;i++)W(L+'/v20f/r9/hp?k='+i+rest,g);document.title='rlpfired'},100)</script>rlp");
    // ── v20g A (verifier probes) ──
    // reload delays / chain: /v20g/hp?k=K&n=N&d=D — the first N hits of key K hold the headers 6 s, later hits answer after D ms.
    if (std.mem.eql(u8, path, "/v20g/hp")) {
        const k: usize = @intCast(qnum(target, "k=") % 256);
        const hit = g_hits[k].fetchAdd(1, .acq_rel) + 1;
        if (hit <= qnum(target, "n=")) return data(conn, head, 6000, 0);
        return data(conn, head, qnum(target, "d="), 0);
    }
    if (std.mem.eql(u8, path, "/v20g/rlp")) return reply(conn, html, "<!doctype html><title>grlp</title><script>" ++ read_js ++
        "var q=location.search.slice(1);var g=q.split('&')[0];var rest=q.slice(g.length);var o=+(new URLSearchParams(location.search).get('o')||0);var c=+(new URLSearchParams(location.search).get('c')||4);" ++
        "var L=rest.indexOf('x=1')>=0?'http://localhost:'+location.port:'';setTimeout(function(){for(var i=0;i<c;i++)W(L+'/v20g/hp?k='+(o+i)+rest,g);document.title='grlpfired'},100)</script>grlp");
    // gap: the old document fires the URL and reloads in the same task; the reloaded document fires it twice (n1 fast, n2 slow).
    if (std.mem.eql(u8, path, "/v20g/g")) {
        const who = whoOf(head);
        const d: u64 = if (std.mem.eql(u8, who, "o")) 3000 else if (std.mem.eql(u8, who, "n1")) 100 else if (std.mem.eql(u8, who, "n2")) 1500 else 0;
        return data(conn, head, d, 0);
    }
    if (std.mem.eql(u8, path, "/v20g/gp")) return reply(conn, html, "<!doctype html><title>gp</title><script>" ++ read_js ++
        "var P=new URLSearchParams(location.search);var k=P.get('k');var m=P.get('m');var u='/v20g/g?k='+k;" ++
        "if(!sessionStorage.getItem('g'+k)){sessionStorage.setItem('g'+k,'1');" ++
        "if(m=='hide'){addEventListener('pagehide',function(){for(var i=0;i<3;i++)W(u,'o')});setTimeout(function(){location.reload()},50)}" ++
        "else if(m=='low'){setTimeout(function(){for(var i=0;i<3;i++)F(u,{headers:{'x-who':'o'},priority:'low'});location.reload()},50)}" ++
        "else{setTimeout(function(){for(var i=0;i<3;i++)W(u,'o');location.reload()},50)}}" ++
        "else{W(u,'n1');setTimeout(function(){W(u,'n2')},5);setTimeout(function(){document.title='gdone'},2500)}</script>gp");
    // worker + same-URL concurrency (WB-1 shape): /v20g/s delays by x-who.
    if (std.mem.eql(u8, path, "/v20g/s")) {
        const who = whoOf(head);
        const D = [_]struct { []const u8, u64 }{ .{ "a", 70 }, .{ "b", 5000 }, .{ "w", 0 }, .{ "c", 5000 }, .{ "d", 2000 }, .{ "e", 4500 } };
        var d: u64 = 0;
        for (D) |e| if (std.mem.eql(u8, who, e[0])) {
            d = e[1];
        };
        return data(conn, head, d, 0);
    }
    if (std.mem.eql(u8, path, "/v20g/w.js")) return reply(conn, "application/javascript", "onmessage=function(e){fetch(e.data.u,{headers:{'x-who':e.data.w},cache:'no-store'}).then(function(r){return r.text()}).catch(function(){})}");
    if (std.mem.eql(u8, path, "/v20g/wp")) return reply(conn, html, "<!doctype html><title>wp</title><script>" ++ read_js ++
        "var w=new Worker('/v20g/w.js');var R=+(new URLSearchParams(location.search).get('r')||8);var j=0;function round(){if(j>=R){setTimeout(function(){document.title='wpdone'},6000);return}var u='/v20g/s?k='+j+'&t='+Date.now();j++;" ++
        "W(u,'a');W(u,'b');setTimeout(function(){w.postMessage({u:u,w:'w'})},250);setTimeout(function(){W(u,'c')},500);setTimeout(function(){W(u,'d')},1590);setTimeout(function(){W(u,'e')},1640);setTimeout(round,7000)}setTimeout(round,300)</script>wp");
    // ── 재검증 3 차: 검증자 v20h A 의 꼴 ──
    // /v20h/e?k=K — x-who 로 늦춘다.
    if (std.mem.eql(u8, path, "/v20h/e")) {
        const who = whoOf(head);
        const D = [_]struct { []const u8, u64 }{ .{ "a", 900 }, .{ "b", 30 }, .{ "c", 30 }, .{ "A", 900 }, .{ "B", 1000 }, .{ "C", 50 }, .{ "D", 400 } };
        var d: u64 = 0;
        for (D) |e| if (std.mem.eql(u8, who, e[0])) {
            d = e[1];
        };
        return data(conn, head, d, 0);
    }
    // 꼬리(WB-4): 전용 워커가 u 를 받고, 페이지가 2 ms 쯤 뒤 a(느림)·8 ms 쯤 뒤 b(빠름)·b 바로 뒤 d(느림).
    if (std.mem.eql(u8, path, "/v20h/t")) {
        const who = whoOf(head);
        const d: u64 = if (std.mem.eql(u8, who, "a") or std.mem.eql(u8, who, "d")) 300 else 0;
        return data(conn, head, d, 0);
    }
    if (std.mem.eql(u8, path, "/v20h/tw.js")) return reply(conn, "application/javascript", "onmessage=function(e){fetch(e.data,{headers:{'x-who':'w'},cache:'no-store'}).then(function(r){return r.text()}).catch(function(){});postMessage(1)}");
    if (std.mem.eql(u8, path, "/v20h/tp")) return reply(conn, html, "<!doctype html><title>tp</title><script>" ++ read_js ++
        "function spin(ms){var s=performance.now();while(performance.now()-s<ms){}}" ++
        "var w=new Worker('/v20h/tw.js');var R=+(new URLSearchParams(location.search).get('r')||40);var G=+(new URLSearchParams(location.search).get('g')||2);var j=0;var k=location.search.slice(1);" ++
        "function N(u,w){return F(u,{headers:{'x-who':w},cache:'no-store'})}" ++
        "var E=+(new URLSearchParams(location.search).get('e')||0.3);" ++
        "w.onmessage=function(){spin(G);N(u,'a');spin(6);N(u,'b');spin(E);N(u,'d');setTimeout(round,700)};var u='';" ++
        "function round(){if(j>=R){setTimeout(function(){document.title='tpdone'},4000);return}u='/v20h/t?k='+k+'_'+j;j++;w.postMessage(u)}setTimeout(round,300)</script>tp");
    // 새 문서의 첫 인라인 스크립트가 곧 u 를 받고('a' — 느림), 40 ms 에 'b', 80 ms 에 'c'(빠름). `ns` 면 캐시를 거치지 않는다(N-4 — 셋이 동시다).
    if (std.mem.eql(u8, path, "/v20h/ep")) return reply(conn, html, "<!doctype html><html><head><script>" ++ read_js ++
        "var u='/v20h/e?k='+location.search.slice(1);if(location.search.indexOf('ns')<0)W=function(u,w){return F(u,{headers:{'x-who':w}})};W(u,'a');setTimeout(function(){W(u,'b')},40);setTimeout(function(){W(u,'c')},80);setTimeout(function(){document.title='epdone'},2000)</script><title>ep</title></head><body>ep</body></html>");
    // iframe: 주 프레임 A(느림)·B(느림), 같은 사이트 iframe 이 주 프레임에 D 를 받게 한 뒤 곧 C(빠름).
    if (std.mem.eql(u8, path, "/v20h/fp")) return reply(conn, html, "<!doctype html><title>fp</title><body>fp<script>" ++ read_js ++
        "var u='/v20h/e?k='+location.search.slice(1);if(location.search.indexOf('ns')<0)W=function(u,w){return F(u,{headers:{'x-who':w}})};W(u,'A');setTimeout(function(){W(u,'B')},10);addEventListener('message',function(e){if(e.data=='go')W(u,'D')});" ++
        "setTimeout(function(){var f=document.createElement('iframe');f.src='/v20h/fi?'+location.search.slice(1);document.body.appendChild(f)},30);setTimeout(function(){document.title='fpdone'},2500)</script></body>");
    if (std.mem.eql(u8, path, "/v20h/fi")) return reply(conn, html, "<!doctype html><title>fi</title><script>" ++ read_js ++
        "var u='/v20h/e?k='+location.search.slice(1);if(location.search.indexOf('ns')<0)W=function(u,w){return F(u,{headers:{'x-who':w}})};parent.postMessage('go','*');setTimeout(function(){W(u,'C')},2)</script>fi");
    // ── 재검증 3 차 뒤(스모크 w9d-body 의 꼴): 쿠키를 심는 localhost 문서에서 127.0.0.1 문서로 옮기고, 새 문서가 그림·다른 사이트의 쿠키 실린
    // 스크립트·JSON 셋(그중 2 MiB 하나)을 곧 받는다 — 끝난 요청이 `pending` 에 머물면 안 된다.
    if (std.mem.eql(u8, path, "/v20i/ck")) return replyC(conn, "200 OK", html, "Set-Cookie: vck=1; Path=/\r\n", "<!doctype html><title>ckdone</title>ck");
    if (std.mem.eql(u8, path, "/v20i/pic.png")) return reply(conn, "image/png", "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89");
    if (std.mem.eql(u8, path, "/v20i/cred.js")) return reply(conn, "application/javascript", "window.vcred=1;");
    if (std.mem.eql(u8, path, "/v20i/c.json")) return data(conn, head, 0, 0);
    if (std.mem.eql(u8, path, "/v20i/big.json")) return reply(conn, "application/json", size_body);
    if (std.mem.eql(u8, path, "/v20i/bp")) {
        var pb: [1024]u8 = undefined;
        return reply(conn, html, std.fmt.bufPrint(&pb, "<!doctype html><title>bp</title><img src=\"/v20i/pic.png{s}\"><script src=\"http://localhost:{d}/v20i/cred.js{s}\"></script><script>{s}" ++
            "F('/v20i/c.json{s}');F('/v20i/big.json{s}');setTimeout(function(){{document.title='bpdone'}},1500)</script>bp", .{ query, port, query, read_js, query, query }) catch return);
    }

    // ── 재검증 3 차 뒤(검증자 v20i A 의 탐침 — WB-5·PF-2·잃음): 서비스 워커·abort 무리·IO 부하·빨리 떠나기·앞 문서의 fetch ──
    // SW: /v20i/sw/x?k=K&d=D — p1: the SW first fetches the same URL itself (x-who X, CDP-invisible), then passes p1 through;
    // p2: passes through after D ms (CEF record late); s2: answers itself after D ms (no CEF record).
    if (std.mem.eql(u8, path, "/v20i/sw/sw.js")) return reply(conn, "application/javascript", "self.addEventListener('install',function(e){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
        "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(u.pathname!='/v20i/sw/x')return;var w=e.request.headers.get('x-who')||'';var d=+(u.searchParams.get('d')||0);" ++
        "if(w=='p1'){fetch(u.href,{headers:{'x-who':'X'},cache:'no-store'}).catch(function(){});e.respondWith(fetch(e.request));return}" ++
        "if(w=='p2'){e.respondWith(new Promise(function(res){setTimeout(function(){res(fetch(e.request))},d)}));return}" ++
        "if(w=='s2'){e.respondWith(new Promise(function(res){setTimeout(function(){res(new Response('{\"n\":\"syn\"}',{headers:{'content-type':'application/json'}}))},d)}));return}})");
    if (std.mem.eql(u8, path, "/v20i/sw/x")) return data(conn, head, 0, 0);
    if (std.mem.eql(u8, path, "/v20i/sw/p")) return reply(conn, html, "<!doctype html><title>swp</title><script>" ++ read_js ++
        "function reg(next){navigator.serviceWorker.register('/v20i/sw/sw.js',{scope:'/v20i/sw/'}).then(function(){return navigator.serviceWorker.ready}).then(function(){if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}setTimeout(next,300)})}" ++
        "var P=new URLSearchParams(location.search);var D=+(P.get('d')||0);var M=P.get('m')||'p2';var K=P.get('k')||'';var R=+(P.get('r')||20);var j=0;" ++
        "function step(){if(j>=R){setTimeout(function(){document.title='swpdone'},1500);return}var u='/v20i/sw/x?k='+K+'_'+j+'&d='+D;j++;W(u,'p1');setTimeout(function(){W(u,M)},1);setTimeout(step,D+600)}reg(step)</script>swp");
    // ── 재검증 4 차 뒤(검증자 v20j A R6-1): 서비스 워커가 같은 주소 두 요청을 거꾸로 넘긴다 — p1 은 D ms 뒤 fetch(e.request), p2 는 곧. 서버는
    // S ms 뒤에 답한다(두 워커 기록이 두 응답보다 앞에 시작한다).
    if (std.mem.eql(u8, path, "/v20j/sw/sw.js")) return reply(conn, "application/javascript", "self.addEventListener('install',function(e){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
        "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(u.pathname!='/v20j/sw/x')return;var w=e.request.headers.get('x-who')||'';var d=+(u.searchParams.get('d')||0);" ++
        "if(w=='p1'){e.respondWith(new Promise(function(res){setTimeout(function(){res(fetch(e.request))},d)}));return}" ++
        "if(w=='a1'){e.respondWith(fetch(u.href+'&alt=1',{headers:{'x-who':'A'},cache:'no-store'}));return}" ++
        "if(w=='a3'){fetch(u.href,{headers:{'x-who':'X'},cache:'no-store'}).catch(function(){});e.respondWith(fetch(u.href+'&alt=1',{headers:{'x-who':'A'},cache:'no-store'}));return}" ++
        // v20k(검증자): m1 은 그대로 넘기며 응답을 메모리에 남기고, m2 는 그 남긴 응답(출처 network)으로 답하며 같은 주소를 갱신 fetch(X)로 받는다 —
        // m2e 는 갱신을 먼저, m2l 은 답한 뒤 80 ms 에. f1 은 제 주소를 받은 뒤 다른 주소(&fb=1 — F)로 답한다(실패 대체 꼴).
        "if(w=='m1'){e.respondWith(fetch(e.request).then(function(r){self.M=self.M||{};self.M[u.href]=r.clone();return r}));return}" ++
        "if(w=='m2e'||w=='m2l'){var c=(self.M||{})[u.href];if(c){var g=function(){return fetch(u.href,{headers:{'x-who':'X'},cache:'no-store'}).catch(function(){})};if(w=='m2e')g();else setTimeout(g,80);e.respondWith(c.clone());return}}" ++
        "if(w=='f1'){e.respondWith(fetch(e.request).then(function(r){return r.text().then(function(){return fetch(u.href+'&fb=1',{headers:{'x-who':'F'},cache:'no-store'})})}));return}" ++
        "e.respondWith(fetch(e.request))})");
    if (std.mem.eql(u8, path, "/v20j/sw/x")) return data(conn, head, qnum(target, "s="), 0);
    // 검증자 v20j A(조정자 요청): `--network` 의 body-r4-sw-mixed 꼴 — 같은 주소를 서비스 워커가 놓음(fb)·그대로 넘김(pt) 섞어 한꺼번에(fb·pt·fb·pt).
    if (std.mem.eql(u8, path, "/v20j/mx/sw.js")) return reply(conn, "application/javascript", "self.addEventListener('install',function(e){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
        "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(u.pathname!='/v20j/mx/pt')return;if(e.request.headers.get('x-mode')=='fb')return;e.respondWith(fetch(e.request))})");
    if (std.mem.eql(u8, path, "/v20j/mx/pt")) return data(conn, head, 0, 0);
    if (std.mem.eql(u8, path, "/v20j/mx/p")) return reply(conn, html, "<!doctype html><title>mx</title><script>function F(u,o){return fetch(u,o).then(function(r){return r.text()}).catch(function(){})}" ++
        "function reg(next){navigator.serviceWorker.register('/v20j/mx/sw.js',{scope:'/v20j/mx/'}).then(function(){return navigator.serviceWorker.ready}).then(function(){if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}setTimeout(next,200)})}" ++
        "var P=new URLSearchParams(location.search);var K=P.get('k')||'';var k=0;function step(){if(k>=20){document.title='mxdone';return}var u='/v20j/mx/pt?'+K+'_'+k;k++;" ++
        "F(u,{headers:{'x-mode':'fb','x-who':'fb'}});F(u,{headers:{'x-who':'pt'}});F(u,{headers:{'x-mode':'fb','x-who':'fb'}});F(u,{headers:{'x-who':'pt'}});setTimeout(step,200)}reg(step)</script>mx");
    if (std.mem.eql(u8, path, "/v20j/sw/q")) return reply(conn, html, "<!doctype html><title>swq</title><script>" ++ read_js ++
        "function reg(next){navigator.serviceWorker.register('/v20j/sw/sw.js',{scope:'/v20j/sw/'}).then(function(){return navigator.serviceWorker.ready}).then(function(){if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}setTimeout(next,300)})}" ++
        "var P=new URLSearchParams(location.search);var S=+(P.get('s')||0);var K=P.get('k')||'';var R=+(P.get('r')||20);var MO=P.get('mo')||'m2e';var j=0;" ++
        "function step(){if(j>=R){setTimeout(function(){document.title='swqdone'},1500);return}var u='/v20j/sw/x?k='+K+'_'+j+'&s='+S;j++;" ++
        "if(MO=='fb'){W(u,'f1');W(u+'&fb=1','pf');setTimeout(step,2*S+800);return}" ++
        "W(u,'m1').then(function(){setTimeout(function(){W(u,MO)},300)});setTimeout(step,2*S+1200)}reg(step)</script>swq");
    if (std.mem.eql(u8, path, "/v20j/sw/p")) return reply(conn, html, "<!doctype html><title>swj</title><script>" ++ read_js ++
        "function reg(next){navigator.serviceWorker.register('/v20j/sw/sw.js',{scope:'/v20j/sw/'}).then(function(){return navigator.serviceWorker.ready}).then(function(){if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}setTimeout(next,300)})}" ++
        "var P=new URLSearchParams(location.search);var D=+(P.get('d')||0);var S=+(P.get('s')||0);var K=P.get('k')||'';var R=+(P.get('r')||20);var FW=P.get('f')||'p1';var j=0;" ++
        "function step(){if(j>=R){setTimeout(function(){document.title='swjdone'},1500);return}var u='/v20j/sw/x?k='+K+'_'+j+'&d='+D+'&s='+S;j++;W(u,FW);if(P.get('n2')!='0')setTimeout(function(){W(u,'p2')},1);setTimeout(step,D+S+600)}reg(step)</script>swj");

    // hostile: D (x-who d, 300 ms), F (aborted at once — before CEF), E (x-who e, 3 s) of one URL in one task.
    if (std.mem.eql(u8, path, "/v20i/h")) {
        const who = whoOf(head);
        return data(conn, head, if (std.mem.eql(u8, who, "e")) 3000 else if (std.mem.eql(u8, who, "d")) 300 else 0, 0);
    }
    if (std.mem.eql(u8, path, "/v20i/hp")) return reply(conn, html, "<!doctype html><title>hp</title><script>" ++ read_js ++
        "var P=new URLSearchParams(location.search);var ND=+(P.get('d')||60),NF=+(P.get('f')||3900),NE=+(P.get('e')||60),R=+(P.get('r')||3);var K=P.get('k')||'';var j=0;" ++
        "function round(){if(j>=R){setTimeout(function(){document.title='hpdone'},5000);return}var u='/v20i/h?k='+K+'_'+j;j++;" ++
        "for(var i=0;i<ND;i++)W(u,'d');for(var i=0;i<NF;i++){var c=new AbortController();F(u,{headers:{'x-who':'f'},cache:'no-store',signal:c.signal});c.abort()}for(var i=0;i<NE;i++)W(u,'e');setTimeout(round,7000)}setTimeout(round,500)</script>hp");
    // IO load: a worker fetches u (X), then the page fires p1, N distinct fetches, p2 (both same URL as X).
    if (std.mem.eql(u8, path, "/v20i/l")) return data(conn, head, 0, 0);
    if (std.mem.eql(u8, path, "/v20i/lw.js")) return reply(conn, "application/javascript", "onmessage=function(e){fetch(e.data,{headers:{'x-who':'X'},cache:'no-store'}).then(function(r){return r.text()}).catch(function(){});postMessage(1)}");
    if (std.mem.eql(u8, path, "/v20i/lp")) return reply(conn, html, "<!doctype html><title>lp</title><script>" ++ read_js ++
        "var P=new URLSearchParams(location.search);var N=+(P.get('n')||200);var K=P.get('k')||'';var R=+(P.get('r')||10);var j=0;var u='';var w=new Worker('/v20i/lw.js');" ++
        "w.onmessage=function(){W(u,'p1');for(var i=0;i<N;i++)W('/v20/d?lz'+K+'_'+j+'_'+i,'z');W(u,'p2');setTimeout(round,1500)};" ++
        "function round(){if(j>=R){setTimeout(function(){document.title='lpdone'},3000);return}u='/v20i/l?k='+K+'_'+j;j++;w.postMessage(u)}setTimeout(round,300)</script>lp");
    // navigate-quickly: a (fast) and b (slow 2 s) of one URL, then the page navigates X ms after a resolves.
    if (std.mem.eql(u8, path, "/v20i/q")) {
        const who = whoOf(head);
        return data(conn, head, if (std.mem.eql(u8, who, "b")) 2000 else 0, 0);
    }
    if (std.mem.eql(u8, path, "/v20i/qp")) return reply(conn, html, "<!doctype html><title>qp</title><script>" ++ read_js ++
        "var P=new URLSearchParams(location.search);var X=+(P.get('x')||0);var u='/v20i/q?k='+P.get('k');setTimeout(function(){W(u,'a').then(function(){setTimeout(function(){location.href='/v20/blank?qdone'},X)});setTimeout(function(){W(u,'b')},1)},200)</script>qp");
    // unload / pagehide fetches of the old document (sent after the doc notice?) + reloaded document's n1/n2 of the same URL.
    if (std.mem.eql(u8, path, "/v20i/g")) {
        const who = whoOf(head);
        const d: u64 = if (std.mem.eql(u8, who, "o")) 3000 else if (std.mem.eql(u8, who, "n1")) 100 else if (std.mem.eql(u8, who, "n2")) 1500 else 0;
        return data(conn, head, d, 0);
    }
    if (std.mem.eql(u8, path, "/v20i/gp")) return reply(conn, html, "<!doctype html><title>igp</title><script>" ++ read_js ++
        "var P=new URLSearchParams(location.search);var k=P.get('k');var m=P.get('m');var u='/v20i/g?k='+k;" ++
        "if(!sessionStorage.getItem('i'+k)){sessionStorage.setItem('i'+k,'1');" ++
        "if(m=='unload'){addEventListener('unload',function(){for(var i=0;i<3;i++)W(u,'o')});setTimeout(function(){location.reload()},50)}" ++
        "else if(m=='hidecut'){addEventListener('pagehide',function(){for(var i=0;i<3;i++){var c=new AbortController();F(u,{headers:{'x-who':'o'},cache:'no-store',signal:c.signal});}});setTimeout(function(){location.reload()},50)}" ++
        "else if(m=='bf'){W(u,'o');setTimeout(function(){location.href='/v20i/gb?k='+k},50)}" ++
        "else if(m=='docopen'){W(u,'o');setTimeout(function(){document.open();document.write('<title>igp<\\/title><script>'+document.getElementById('rj').textContent+'<\\/script>');document.close()},50)}" ++
        "}else{W(u,'n1');setTimeout(function(){W(u,'n2')},5);setTimeout(function(){document.title='igdone'},2500)}</script>" ++
        "<script id=rj type=text/plain>function F(u,o){return fetch(u,o).then(function(r){return r.text()}).catch(function(){})}function W(u,w){return F(u,{headers:{'x-who':w},cache:'no-store'})}var u='/v20i/g?k='+new URLSearchParams(location.search).get('k');W(u,'n1');setTimeout(function(){W(u,'n2')},5);setTimeout(function(){document.title='igdone'},2500)</script>igp");
    // bfcache: B fires o (slow) and goes back — the restored page fires n1/n2 in pageshow(persisted).
    if (std.mem.eql(u8, path, "/v20i/gb")) return reply(conn, html, "<!doctype html><title>igb</title><script>" ++ read_js ++
        "var u='/v20i/g?k='+new URLSearchParams(location.search).get('k');setTimeout(function(){W(u,'o');history.back()},100)</script>igb");
    if (std.mem.eql(u8, path, "/v20i/bfa")) return reply(conn, html, "<!doctype html><title>bfa</title><script>" ++ read_js ++
        "var k=new URLSearchParams(location.search).get('k');var u='/v20i/g?k='+k;addEventListener('pageshow',function(e){if(e.persisted){W(u,'n1');setTimeout(function(){W(u,'n2')},5);setTimeout(function(){document.title='igdone'},2500)}" ++
        "else if(sessionStorage.getItem('b'+k)){document.title='igdone'}else{sessionStorage.setItem('b'+k,'1');setTimeout(function(){location.href='/v20i/gb?k='+k},300)}});</script>bfa");
    return reply(conn, "text/plain", "x");
}

// ── 모으기 ────────────────────────────────────────────────────────────────────────────────────────────────

const Begin = struct { browser: u64, request: u64, url: []u8, host: []u8, final_host: []u8, site: []u8 = &.{}, initiator: []u8 = &.{}, method_head: bool = false, expected: bool, flags: msg.NetFlags, at_ms: i64 };
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
    ct_visible: bool = false,
    redirects: usize = 0,
    redirect_ct_hidden: usize = 0,
    /// 재검증 5 차 S0: CEF 의 끝(`net_end`)을 봤다 — 끝나지 않은 요청의 본문은 `pending` 이 참이다.
    cef_end: bool = false,
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
                self.begins.append(self.gpa, .{ .browser = v.browser, .request = v.request, .url = self.gpa.dupe(u8, v.url) catch &.{}, .host = h, .final_host = h, .site = self.gpa.dupe(u8, v.site) catch unreachable, .initiator = self.gpa.dupe(u8, v.initiator) catch unreachable, .method_head = std.mem.eql(u8, v.method, "HEAD"), .expected = v.flags2.body_expected, .flags = v.flags, .at_ms = os.nowMs() }) catch {};
                // 같은 번호의 새 시도(다시 시작) — 새 본문 자리.
                if (v.flags2.body_expected) {
                    const old = self.body(v.browser, v.request);
                    if (old.ends > 0) self.bodies.append(self.gpa, .{ .browser = v.browser, .request = v.request }) catch {};
                }
            },
            .net_redirect => |v| {
                {
                    const bx = self.body(v.browser, v.request);
                    bx.redirects += 1;
                    var loc_visible = false;
                    var hit = net_fields.HeaderIterator.init(v.headers);
                    while (hit.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "location") and h.value.len > 0) {
                        loc_visible = true;
                    };
                    if (!loc_visible) bx.redirect_ct_hidden += 1;
                }
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
                    if (std.ascii.eqlIgnoreCase(h.name, "content-type") and h.value.len > 0) b.ct_visible = true;
                }
            },
            .net_body_data => |v| {
                const b = self.body(v.browser, v.request);
                b.data_frames += 1;
                b.data_session_max = @max(b.data_session_max, v.session);
                if (b.ends > 0) b.data_after_end += 1;
                if (v.offset == b.data.items.len) b.data.appendSlice(self.gpa, v.bytes) catch {} else b.gap = true;
            },
            .net_end => |v| {
                self.body(v.browser, v.request).cef_end = true;
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
    /// 재검증 5 차 S0: 서비스 워커 갈래(`NetFlags.service_worker`) 기록에 붙은 본문 수.
    sw_captured: usize = 0,
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
        if (x.ends >= 1 and x.state == .captured and b.flags.service_worker) t.sw_captured += 1;
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
    return std.fmt.bufPrint(buf, "CEF requests {d} (body_expected {d}) · own {d} (sw {d}) · WRONG {d} · captured w/o X-Body {d} · ambiguous {d} · other {d} · no end {d} · several ends {d} · data after end {d} · states{s} ·{s}", .{ t.total, t.expected, t.own, t.sw_captured, t.wrong, t.unknown, t.ambiguous, t.other, t.no_end, t.multi_end, t.after_end, stateLine(t, sl), t.notes[0..t.notes_len] }) catch "";
}

/// 기대한 시작(body_expected)마다 끝이 꼭 하나인가 — `at` 부터 그 탭의 것.
const EndCheck = struct { expected: usize = 0, missing: usize = 0, doubled: usize = 0, after_end: usize = 0, states: [16]usize = @splat(0) };
fn endCheck(r: *Run, browser: u64, at: usize) EndCheck {
    return endCheckOf(r, browser, at, false);
}

/// 재검증 5 차 S0: `ended_only` 면 CEF 가 끝내지 않은 요청(워커가 받은 응답을 읽지 않고 쥔 갱신 fetch — 그 요청은 정말 끝나지 않았다, 본문은
/// `pending`)은 「끝 없음」 으로 세지 않는다.
fn endCheckOf(r: *Run, browser: u64, at: usize, ended_only: bool) EndCheck {
    var c: EndCheck = .{};
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(r.gpa);
    for (r.begins.items[at..]) |b| if (b.browser == browser and b.expected) {
        if (seen.contains(b.request)) continue;
        seen.put(r.gpa, b.request, {}) catch {};
        c.expected += 1;
        const x = r.body(browser, b.request);
        if (x.ends == 0 and (!ended_only or x.cef_end)) c.missing += 1;
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
    const only = std.c.getenv("V20F_ONLY") orelse return true;
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

fn watchSet(r: *Run, id: u64, full: bool, any_host: bool) !void {
    var w: msg.NetWatch = .{ .browser = id, .on = true, .full = full, .any_host = any_host, .host_count = if (any_host or full) 0 else 1 };
    if (!any_host and !full) w.hosts[0] = "127.0.0.1";
    if (full) w.any_host = true;
    try r.host.send(.{ .net_watch = w });
}

fn navigateUrl(r: *Run, browser: u64, url: []const u8) !void {
    _ = r.titles.remove(browser);
    try r.host.send(.{ .navigate = .{ .browser = browser, .url = url } });
}

/// 끝 호스트(리다이렉트 뒤)와 주소 조각으로 고른 기록들 — 잡은 수·데이터 frame·응답 머리의 content-type 값이 보였는가·홉의 덜어 냄.
const Cov = struct { total: usize = 0, captured: usize = 0, frames: usize = 0, ct_visible: usize = 0, redirect_stripped: usize = 0, redirects: usize = 0, no_end: usize = 0, multi_end: usize = 0, states: [16]usize = @splat(0), sites: [160]u8 = undefined, sites_len: usize = 0 };
fn covOf(r: *Run, browser: u64, at: usize, needle: []const u8, final_host: ?[]const u8) Cov {
    var c: Cov = .{};
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(r.gpa);
    for (r.begins.items[at..]) |b| if (b.browser == browser and std.mem.indexOf(u8, b.url, needle) != null) {
        if (seen.contains(b.request)) continue;
        seen.put(r.gpa, b.request, {}) catch {};
        if (final_host) |fh| if (!std.mem.eql(u8, b.final_host, fh)) continue;
        const x = r.body(browser, b.request);
        c.total += 1;
        if (b.expected and x.ends == 0) c.no_end += 1;
        if (x.ends > 1) c.multi_end += 1;
        if (x.ends >= 1) c.states[@backingInt(x.state)] += 1;
        if (x.ends >= 1 and x.state == .captured) c.captured += 1;
        c.frames += x.data_frames;
        if (x.ct_visible) c.ct_visible += 1;
        c.redirects += x.redirects;
        c.redirect_stripped += x.redirect_ct_hidden;
        if (c.sites_len < 120) {
            const piece = std.fmt.bufPrint(c.sites[c.sites_len..], " '{s}'", .{b.site[0..@min(b.site.len, 16)]}) catch "";
            c.sites_len += piece.len;
        }
    };
    return c;
}

fn covLine(c: *const Cov, buf: []u8, sl: []u8) []const u8 {
    var t: Tally = .{};
    t.states = c.states;
    return std.fmt.bufPrint(buf, "records {d} · captured {d} · data frames {d} · response content-type visible {d} · redirect hops {d} (Location hidden {d}) · no end {d} · several ends {d} · states{s} · begin sites{s}", .{ c.total, c.captured, c.frames, c.ct_visible, c.redirects, c.redirect_stripped, c.no_end, c.multi_end, stateLine(&t, sl), c.sites[0..c.sites_len] }) catch "";
}

fn countInFile(path: [*:0]const u8, needle: []const u8) usize {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    var buf: [65536]u8 = undefined;
    var carry: usize = 0;
    var n: usize = 0;
    while (true) {
        const got = std.c.read(fd, buf[carry..].ptr, buf.len - carry);
        if (got <= 0) break;
        const end = carry + @as(usize, @intCast(got));
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, buf[0..end], at, needle)) |i| {
            n += 1;
            at = i + needle.len;
        }
        // 경계에 걸친 것을 잇는다.
        const keep = @min(needle.len - 1, end);
        std.mem.copyForwards(u8, buf[0..keep], buf[end - keep .. end]);
        carry = keep;
    }
    return n;
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    try startServer();
    var detail: [4000]u8 = undefined;
    var sl: [400]u8 = undefined;
    var lb: [4000]u8 = undefined;
    var ub: [256]u8 = undefined;
    const body_log = std.c.getenv("V20F_BODY_LOG") != null;
    const log_env: []const [*:0]const u8 = if (body_log) &.{"MARU_WEB_TEST_BODY_LOG=1"} else &.{};
    const stderr_path: ?[:0]const u8 = if (std.c.getenv("V20F_HOST_STDERR")) |p| std.mem.span(p) else null;
    var host = try Host.spawnWith(host_path, profile_arg, stderr_path, log_env);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    var r: Run = .{ .host = &host, .gpa = gpa };
    try openTab(&r, rec_tab, 1);
    var session: u32 = 10;

    // ══ r1: 설정 끔 — 어느 호스트든(에이전트 탭) / 묶인 호스트(127.0.0.1) — 첫 사이트가 응답·홉을 덮는다(V1 고침) ══
    if (enabled("r1")) {
        inline for (.{ .{ true, "v20f-r1-anyhost" }, .{ false, "v20f-r1-hostlist" } }) |c| {
            try watchSet(&r, rec_tab, false, c[0]);
            session += 1;
            try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = session } });
            r.pump(300);
            const at = r.begins.items.len;
            try r.navigate(rec_tab, "/v20f/r1/a");
            const done = r.pumpTitle(rec_tab, "r1adone", 20_000);
            r.pump(2500);
            var l1: [900]u8 = undefined;
            var l2: [900]u8 = undefined;
            var l3: [900]u8 = undefined;
            var l4: [900]u8 = undefined;
            var l5: [900]u8 = undefined;
            var l6: [900]u8 = undefined;
            var s1: [400]u8 = undefined;
            var s2: [400]u8 = undefined;
            var s3: [400]u8 = undefined;
            var s4: [400]u8 = undefined;
            var s5: [400]u8 = undefined;
            var s6: [400]u8 = undefined;
            const own = covOf(&r, rec_tab, at, "/v20/d?fo", null);
            const cross = covOf(&r, rec_tab, at, "/v20/d?fx", null);
            const c2u = covOf(&r, rec_tab, at, "/v20f/r1/c2u?fc", null);
            const u2c = covOf(&r, rec_tab, at, "/v20f/r1/u2c?fu", null);
            const ifs = covOf(&r, rec_tab, at, "/v20/d?fi", null);
            const ifx = covOf(&r, rec_tab, at, "/v20/d?f", "localhost");
            const ify = covOf(&r, rec_tab, at, "/v20/d?fy", null);
            // 새는 쪽: localhost 가 응답한 본문은 어느 꼴에서도 잡히지 않는다(어느 호스트든의 첫 사이트 127.0.0.1 · 묶인 호스트 127.0.0.1). 다른 사이트
            // iframe(첫 사이트 없음) 의 것도. 대조: 제 사이트(첫 사이트 127.0.0.1)는 잡힌다 — 어느 호스트든도(고침 전에는 0).
            const leak_ok = cross.captured == 0 and cross.frames == 0 and c2u.captured == 0 and c2u.frames == 0 and ifx.captured == 0 and ifx.frames == 0 and ify.captured == 0 and ify.frames == 0 and cross.ct_visible == 0 and c2u.ct_visible == 0;
            const ctl_ok = own.captured == 10 and own.ct_visible == 10 and ifs.captured == 5 and u2c.captured == 10;
            report(done and leak_ok and ctl_ok and own.no_end + cross.no_end + c2u.no_end + u2c.no_end == 0, c[1], std.fmt.bufPrint(&detail, "own site [{s}] · direct to localhost [{s}] · 127.0.0.1→localhost [{s}] · localhost→127.0.0.1 [{s}] · same-site iframe [{s}] · cross-site iframe (localhost answered) [{s}] · cross-site iframe → 127.0.0.1 [records {d} captured {d} frames {d}]", .{ covLine(&own, &l1, &s1), covLine(&cross, &l2, &s2), covLine(&c2u, &l3, &s3), covLine(&u2c, &l4, &s4), covLine(&ifs, &l5, &s5), covLine(&ifx, &l6, &s6), ify.total, ify.captured, ify.frames }) catch "");
            // 주 프레임 문서: 곧 localhost 로(첫 사이트 = 그 주소) · 127.0.0.1 → localhost · localhost → 127.0.0.1.
            var dd: usize = 0;
            var doc_leak = false;
            inline for (.{ .{ "http://localhost:{d}/v20f/r1/doc?d", "/v20f/r1/doc?d", "direct localhost doc" }, .{ "http://127.0.0.1:{d}/v20f/r1/navredir", "/v20f/r1/navredir", "127.0.0.1→localhost doc" }, .{ "http://localhost:{d}/v20f/r1/navback", "/v20f/r1/navback", "localhost→127.0.0.1 doc" } }) |nv| {
                const at2 = r.begins.items.len;
                try navigateUrl(&r, rec_tab, try std.fmt.bufPrint(&ub, nv[0], .{port}));
                _ = r.pumpTitle(rec_tab, "fdoc", 8000);
                r.pump(1500);
                const d = covOf(&r, rec_tab, at2, nv[1], null);
                var dsl: [400]u8 = undefined;
                var dl: [900]u8 = undefined;
                if (std.mem.eql(u8, nv[2], "127.0.0.1→localhost doc") and (d.captured != 0 or d.frames != 0)) doc_leak = true;
                if (!c[0] and std.mem.eql(u8, nv[2], "direct localhost doc") and (d.captured != 0 or d.frames != 0)) doc_leak = true;
                const piece = std.fmt.bufPrint(detail[dd..], " [{s}: {s}]", .{ nv[2], covLine(&d, &dl, &dsl) }) catch "";
                dd += piece.len;
            }
            report(!doc_leak, c[1] ++ "-documents", detail[0..dd]);
            try r.navigate(rec_tab, "/v20/blank?r1f");
            r.pump(500);
        }
        try watchSet(&r, rec_tab, true, true);
    }

    // ══ r2: 페이지·다른 사이트 iframe·같은 사이트 iframe 이 같은 주소 0–10 ms ══
    if (enabled("r2")) {
        inline for (.{ .{ true, "/v20f/r2/p?on", "v20f-r2-full" }, .{ false, "/v20f/r2/p?off", "v20f-r2-off-anyhost" } }) |c| {
            try watchSet(&r, rec_tab, c[0], true);
            session += 1;
            try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = session } });
            r.pump(300);
            const at = r.begins.items.len;
            try r.navigate(rec_tab, c[1]);
            const done = r.pumpTitle(rec_tab, "r2done", 30_000);
            r.pump(4000);
            // 다른 사이트 iframe 의 기록 — initiator 가 localhost.
            var x_total: usize = 0;
            var x_captured: usize = 0;
            var x_frames: usize = 0;
            var x_states: [16]usize = @splat(0);
            var px_own: usize = 0;
            var px_amb: usize = 0;
            var px_wrong: usize = 0;
            var px_total: usize = 0;
            var px_other: [16]usize = @splat(0);
            var px_captured: usize = 0;
            for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, "/v20/d?r2x") != null) {
                const x = r.body(rec_tab, b.request);
                if (std.mem.indexOf(u8, b.initiator, "localhost") != null) {
                    x_total += 1;
                    if (x.ends >= 1 and x.state == .captured) x_captured += 1;
                    x_frames += x.data_frames;
                    if (x.ends >= 1) x_states[@backingInt(x.state)] += 1;
                } else {
                    px_total += 1;
                    if (x.ends >= 1 and x.state == .captured) {
                        px_captured += 1;
                        if (x.xbody.len > 0) {
                            if (ownBody(x)) px_own += 1 else px_wrong += 1;
                        }
                    } else if (x.ends >= 1 and x.state == .ambiguous) px_amb += 1 else if (x.ends >= 1) px_other[@backingInt(x.state)] += 1;
                }
            };
            const s_all = tally(&r, rec_tab, at, "/v20/d?r2s", null);
            const s_if = tally(&r, rec_tab, at, "/v20/d?r2s", "s");
            const s_pg = tally(&r, rec_tab, at, "/v20/d?r2s", "p");
            var t1: Tally = .{};
            t1.states = x_states;
            var t2: Tally = .{};
            t2.states = px_other;
            var sl2: [400]u8 = undefined;
            var sl3: [400]u8 = undefined;
            const ec = endCheck(&r, rec_tab, at);
            var el: [600]u8 = undefined;
            var esl: [400]u8 = undefined;
            // full: 틀린 본문 0(머리 X-Body 로 대조). off: X-Body 값은 덜어 낸다 — 다른 사이트 iframe 기록에 바이트 0 만 본다.
            const ok = done and x_captured == 0 and x_frames == 0 and px_wrong == 0 and s_all.wrong == 0 and ec.missing == 0 and ec.doubled == 0 and ec.after_end == 0;
            report(ok, c[2], std.fmt.bufPrint(&detail, "cross-site iframe records {d}: captured {d} data frames {d} states{s} · page records {d}: captured {d} (own {d}, WRONG {d}) ambiguous {d} other{s} · same-site iframe vs page: iframe own {d}/{d} amb {d} · page own {d}/{d} amb {d} · all wrong {d} · tab-wide: {s}", .{ x_total, x_captured, x_frames, stateLine(&t1, &sl), px_total, px_captured, px_own, px_wrong, px_amb, stateLine(&t2, &sl2), s_if.own, s_if.total, s_if.ambiguous, s_pg.own, s_pg.total, s_pg.ambiguous, s_all.wrong, endLine(&ec, &el, &esl) }) catch "");
            _ = &sl3;
            _ = &lb;
        }
        try watchSet(&r, rec_tab, true, true);
    }

    // ══ r3: 두 탭이 같은 주소 · 조각만 다른 같은 주소 · HEAD 와 GET ══
    if (enabled("r3")) {
        try openTab(&r, tab_b, 700);
        session += 1;
        const at = r.begins.items.len;
        // 두 탭을 거의 함께.
        try r.navigate(rec_tab, "/v20f/r3/two?t=a");
        try r.navigate(tab_b, "/v20f/r3/two?t=c");
        const d1 = r.pumpTitle(rec_tab, "twodone", 30_000);
        const d2 = r.pumpTitle(tab_b, "twodone", 10_000);
        r.pump(2000);
        const ta = tally(&r, rec_tab, at, "/v20f/r3/slow?tw", null);
        const tb = tally(&r, tab_b, at, "/v20f/r3/slow?tw", null);
        const tbw = tally(&r, tab_b, at, "/v20f/r3/slow?tw", "a"); // 탭 B 기록에 탭 A(x-who a)의 응답 — 머리는 제 것이니 X-Who 가 a 면 짝이 틀린 것
        const taw = tally(&r, rec_tab, at, "/v20f/r3/slow?tw", "c");
        var sl2: [400]u8 = undefined;
        report(d1 and d2 and ta.wrong == 0 and tb.wrong == 0 and tbw.total == 0 and taw.total == 0 and ta.no_end + tb.no_end == 0 and ta.multi_end + tb.multi_end == 0, "v20f-r3-two-tabs-same-url", std.fmt.bufPrint(&detail, "tab A (slow 300 ms): {s} · tab B (instant): {s} · cross-tab responses A→B {d} B→A {d}", .{ lineOf(&ta, &lb, &sl), lineOf(&tb, &ub, &sl2), tbw.total, taw.total }) catch "");
        try r.host.send(.{ .destroy_browser = tab_b });
        r.pump(1000);
        const at2 = r.begins.items.len;
        try r.navigate(rec_tab, "/v20f/r3/frag");
        const d3 = r.pumpTitle(rec_tab, "fragdone", 30_000);
        r.pump(2000);
        const fa = tally(&r, rec_tab, at2, "/v20f/r3/slow?fr", null);
        const hg = tally(&r, rec_tab, at2, "/v20f/r3/slow?hg", "c");
        // HEAD 기록(메서드 HEAD) — 본문 상태.
        var head_states: [16]usize = @splat(0);
        var head_bytes: usize = 0;
        for (r.begins.items[at2..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, "/v20f/r3/slow?hg") != null and b.method_head) {
            const x = r.body(rec_tab, b.request);
            if (x.ends >= 1) head_states[@backingInt(x.state)] += 1;
            head_bytes += x.data.items.len;
        };
        var th: Tally = .{};
        th.states = head_states;
        var sl3: [400]u8 = undefined;
        var l9: [900]u8 = undefined;
        report(d3 and fa.wrong == 0 and fa.no_end == 0 and fa.multi_end == 0 and hg.wrong == 0 and head_bytes == 0, "v20f-r3-fragment-and-head", std.fmt.bufPrint(&detail, "same URL with #a (slow) / #b (instant): {s} · GET beside a HEAD of the same URL: {s} · HEAD records states{s} bytes {d}", .{ lineOf(&fa, &lb, &sl), lineOf(&hg, &l9, &sl3), stateLine(&th, &sl), head_bytes }) catch "");
    }

    // ══ r4: 렌더러 주 스레드가 1.5·2.5·3.5 s 막힘 — CDP 사건이 늦다(물 높이·끊긴 자리 놓기·짝 없는 시한) ══
    if (enabled("r4")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/v20f/r4/busy");
        const done = r.pumpTitle(rec_tab, "busydone", 60_000);
        r.pump(2000);
        var dn: usize = 0;
        var ok = done;
        inline for (.{ "bz1500_", "bz2500_", "bz3500_" }) |nd| {
            const t = tally(&r, rec_tab, at, nd, null);
            if (t.wrong != 0 or t.no_end != 0 or t.multi_end != 0 or t.after_end != 0) ok = false;
            var max_lat: i64 = 0;
            for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, nd) != null) {
                const x = r.body(rec_tab, b.request);
                if (x.ends >= 1) max_lat = @max(max_lat, x.end_ms - b.at_ms);
            };
            const piece = std.fmt.bufPrint(detail[dn..], " [{s}: {s} max begin→end {d} ms]", .{ nd, lineOf(&t, &lb, &sl), max_lat }) catch "";
            dn += piece.len;
        }
        const ec = endCheck(&r, rec_tab, at);
        var el: [600]u8 = undefined;
        const piece = std.fmt.bufPrint(detail[dn..], " · tab-wide: {s}", .{endLine(&ec, &el, &sl)}) catch "";
        dn += piece.len;
        report(ok and ec.missing == 0 and ec.doubled == 0, "v20f-r4-busy-renderer", detail[0..dn]);
    }

    // ══ r5: 새 문서 맨 앞의 abort·다시 · 다시 받은 요청이 기다리는 동안 이동 ══
    if (enabled("r5")) {
        const at = r.begins.items.len;
        var k: usize = 0;
        while (k < 20) : (k += 1) {
            try r.navigate(rec_tab, try std.fmt.bufPrint(&ub, "/v20f/r5/early?k{d}", .{k}));
            _ = r.pumpTitle(rec_tab, "earlydone", 8000);
        }
        r.pump(4000);
        const at_busy = r.begins.items.len;
        k = 0;
        while (k < 20) : (k += 1) {
            try r.navigate(rec_tab, try std.fmt.bufPrint(&ub, "/v20f/r5/early?busy{d}", .{k}));
            _ = r.pumpTitle(rec_tab, "earlydone", 8000);
        }
        r.pump(4000);
        inline for (.{ .{ "/v20/d?eabusy", "s2", "v20f-r5-early-busy-strictmode" }, .{ "/v20/d?ebbusy", "t3", "v20f-r5-early-busy-three" } }) |c| {
            const all = tally(&r, rec_tab, at_busy, c[0], null);
            const keep = tally(&r, rec_tab, at_busy, c[0], c[1]);
            var sl2: [400]u8 = undefined;
            report(all.wrong == 0 and all.no_end == 0 and all.multi_end == 0 and keep.own == keep.total, c[2], std.fmt.bufPrint(&detail, "kept ({s}) {d}: own {d} amb {d} states{s} · all: {s}", .{ c[1], keep.total, keep.own, keep.ambiguous, stateLine(&keep, &sl2), lineOf(&all, &lb, &sl) }) catch "");
        }
        inline for (.{ .{ "/v20/d?eak", "s2", "v20f-r5-early-strictmode" }, .{ "/v20/d?ebk", "t3", "v20f-r5-early-three" } }) |c| {
            const all = tally(&r, rec_tab, at, c[0], null);
            const keep = tally(&r, rec_tab, at, c[0], c[1]);
            var sl2: [400]u8 = undefined;
            report(all.wrong == 0 and all.no_end == 0 and all.multi_end == 0 and keep.states[@backingInt(msg.NetBodyState.request_failed)] == 0 and keep.states[@backingInt(msg.NetBodyState.unavailable)] == 0, c[2], std.fmt.bufPrint(&detail, "kept ({s}) {d}: own {d} amb {d} states{s} · all: {s}", .{ c[1], keep.total, keep.own, keep.ambiguous, stateLine(&keep, &sl2), lineOf(&all, &lb, &sl) }) catch "");
        }
        const at2 = r.begins.items.len;
        k = 0;
        while (k < 8) : (k += 1) {
            try r.navigate(rec_tab, try std.fmt.bufPrint(&ub, "/v20f/r5/navcut?k{d}", .{k}));
            _ = r.pumpTitle(rec_tab, "ncfired", 8000);
            r.pump(150);
            try r.navigate(rec_tab, "/v20/blank?nc");
            r.pump(400);
        }
        r.pump(5000);
        const all = tally(&r, rec_tab, at2, "/v20/d?nc", null);
        const ec = endCheck(&r, rec_tab, at2);
        var el: [600]u8 = undefined;
        var sl2: [400]u8 = undefined;
        report(all.wrong == 0 and ec.missing == 0 and ec.doubled == 0 and ec.after_end == 0, "v20f-r5-refetch-cut-by-navigation", std.fmt.bufPrint(&detail, "{s} · tab-wide: {s}", .{ lineOf(&all, &lb, &sl), endLine(&ec, &el, &sl2) }) catch "");
    }

    // ══ r6: 서비스 워커가 0·1.5·2.5 s 뒤 그대로 넘긴다 ══
    if (enabled("r6")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/v20f/sw/p");
        const done = r.pumpTitle(rec_tab, "swdone", 60_000);
        r.pump(3000);
        var dn: usize = 0;
        var ok = done;
        inline for (.{ "/v20f/sw/dl?d=0&", "/v20f/sw/dl?d=1500&", "/v20f/sw/dl?d=2500&" }) |nd| {
            const t = tally(&r, rec_tab, at, nd, null);
            if (t.wrong != 0 or t.sw_captured != 0 or t.no_end != 0 or t.multi_end != 0) ok = false; // 5 차 S0: 서비스 워커 갈래는 본문 없이
            const piece = std.fmt.bufPrint(detail[dn..], " [{s}: {s}]", .{ nd, lineOf(&t, &lb, &sl) }) catch "";
            dn += piece.len;
        }
        report(ok, "v20f-r6-sw-delayed-passthrough", detail[0..dn]);
    }

    // ══ r9: 머리 전에 끊긴 옛 문서 요청과 같은 주소를 다시 불러온 문서 · 그 뒤 표가 한가해지는가 ══
    if (enabled("r9")) {
        var dn: usize = 0;
        var ok = true;
        inline for (.{ .{ "&v=1&d=400", "headers held, reload answers in 400 ms" }, .{ "&v=3&d=0", "headers held, reload answers at once" }, .{ "&v=2&d=400", "headers sent (body held), reload answers in 400 ms" }, .{ "&v=1&d=400&x=1", "other host (no connection queue), headers held, reload answers in 400 ms" }, .{ "&v=3&d=0&x=1", "other host, headers held, reload answers at once" }, .{ "&v=2&d=400&x=1", "other host, headers sent (body held), reload answers in 400 ms" } }) |c| {
            const at = r.begins.items.len;
            try r.navigate(rec_tab, "/v20f/r9/rlp?A" ++ c[0]);
            _ = r.pumpTitle(rec_tab, "rlpfired", 10_000);
            r.pump(300);
            try r.navigate(rec_tab, "/v20f/r9/rlp?B" ++ c[0]);
            _ = r.pumpTitle(rec_tab, "rlpfired", 10_000);
            r.pump(7000);
            const b = tally(&r, rec_tab, at, c[0], "B");
            const all = tally(&r, rec_tab, at, c[0], null);
            const ec = endCheck(&r, rec_tab, at);
            if (all.wrong != 0 or ec.missing != 0 or ec.doubled != 0) ok = false;
            if (b.own != b.total or b.total < 4) ok = false;
            var el: [600]u8 = undefined;
            var sl2: [400]u8 = undefined;
            const piece = std.fmt.bufPrint(detail[dn..], " [{s}: reloaded own {d}/{d} states{s} · all wrong {d} · {s}]", .{ c[1], b.own, b.total, stateLine(&b, &sl), all.wrong, endLine(&ec, &el, &sl2) }) catch "";
            dn += piece.len;
            try r.navigate(rec_tab, "/v20/blank?r9f");
            r.pump(4000);
        }
        report(ok, "v20f-r9-reload-while-pending", detail[0..dn]);
        if (body_log and stderr_path != null) {
            // 모든 끝이 나온 뒤 10 s — 50 ms 주기 task 가 멈췄는가(본문 로그의 「body: tick」 줄 수).
            r.pump(4000);
            const n0 = countInFile(stderr_path.?.ptr, "body: tick");
            r.pump(10_000);
            const n1 = countInFile(stderr_path.?.ptr, "body: tick");
            report(n1 - n0 <= 2, "v20f-r9-idle-after-cut", std.fmt.bufPrint(&detail, "body ticks in the 10 s after every end: {d} (before: {d} in the whole run)", .{ n1 - n0, n0 }) catch "");
        }
    }
    // ══ v20g A: reload delays 1.7 / 2.4 / 4.8 s (same host, other host) · reload chain A → B → C ══
    if (enabled("g9d")) {
        var dn: usize = 0;
        var ok = true;
        inline for (.{ .{ "&n=1&d=1700&o=10", "same host 1.7 s" }, .{ "&n=1&d=2400&o=20", "same host 2.4 s" }, .{ "&n=1&d=4800&o=30", "same host 4.8 s" }, .{ "&n=1&d=1700&o=40&x=1", "other host 1.7 s" }, .{ "&n=1&d=2400&o=50&x=1", "other host 2.4 s" }, .{ "&n=1&d=4800&o=60&x=1", "other host 4.8 s" } }) |c| {
            const at = r.begins.items.len;
            try r.navigate(rec_tab, "/v20g/rlp?A" ++ c[0]);
            _ = r.pumpTitle(rec_tab, "grlpfired", 10_000);
            r.pump(300);
            try r.navigate(rec_tab, "/v20g/rlp?B" ++ c[0]);
            _ = r.pumpTitle(rec_tab, "grlpfired", 10_000);
            r.pump(9000);
            const b = tally(&r, rec_tab, at, c[0], "B");
            const all = tally(&r, rec_tab, at, c[0], null);
            const ec = endCheck(&r, rec_tab, at);
            if (all.wrong != 0 or ec.missing != 0 or ec.doubled != 0) ok = false;
            if (b.own != b.total or b.total < 4) ok = false;
            var el: [600]u8 = undefined;
            var sl2: [400]u8 = undefined;
            const piece = std.fmt.bufPrint(detail[dn..], " [{s}: reloaded own {d}/{d} states{s} · all wrong {d} · {s}]", .{ c[1], b.own, b.total, stateLine(&b, &sl), all.wrong, endLine(&ec, &el, &sl2) }) catch "";
            dn += piece.len;
            try r.navigate(rec_tab, "/v20/blank?g9f");
            r.pump(4000);
        }
        report(ok, "v20g-r9-reload-delays", detail[0..dn]);
        dn = 0;
        ok = true;
        inline for (.{ .{ "&n=2&d=400&o=70", "same host" }, .{ "&n=2&d=400&o=80&x=1", "other host" } }) |c| {
            const at = r.begins.items.len;
            inline for (.{ "A", "B", "C" }) |g| {
                try r.navigate(rec_tab, "/v20g/rlp?" ++ g ++ c[0]);
                _ = r.pumpTitle(rec_tab, "grlpfired", 10_000);
                r.pump(300);
            }
            r.pump(7000);
            const cc = tally(&r, rec_tab, at, c[0], "C");
            const all = tally(&r, rec_tab, at, c[0], null);
            const ec = endCheck(&r, rec_tab, at);
            if (all.wrong != 0 or ec.missing != 0 or ec.doubled != 0) ok = false;
            if (cc.own != cc.total or cc.total < 4) ok = false;
            var el: [600]u8 = undefined;
            var sl2: [400]u8 = undefined;
            const piece = std.fmt.bufPrint(detail[dn..], " [{s}: C own {d}/{d} states{s} · all wrong {d} · {s}]", .{ c[1], cc.own, cc.total, stateLine(&cc, &sl), all.wrong, endLine(&ec, &el, &sl2) }) catch "";
            dn += piece.len;
            try r.navigate(rec_tab, "/v20/blank?g9c");
            r.pump(4000);
        }
        report(ok, "v20g-r9-reload-chain", detail[0..dn]);
    }
    // ══ v20g A: WB-3 live — old document fires the URL then reloads at once; the reloaded document fires it twice ══
    if (enabled("g9gap")) {
        inline for (.{ "plain", "low", "hide" }) |m| {
            var wrong: usize = 0;
            var own: usize = 0;
            var amb: usize = 0;
            var other: usize = 0;
            var o_begins: usize = 0;
            var n_total: usize = 0;
            var missing: usize = 0;
            var doubled: usize = 0;
            var gk: [64]u8 = undefined;
            for (0..10) |round| {
                const key = std.fmt.bufPrint(&gk, "{s}{d}x{d}", .{ m, round, session }) catch "";
                const at = r.begins.items.len;
                var pb: [128]u8 = undefined;
                try r.navigate(rec_tab, std.fmt.bufPrint(&pb, "/v20g/gp?m={s}&k={s}", .{ m, key }) catch "");
                _ = r.pumpTitle(rec_tab, "gdone", 15_000);
                r.pump(1500);
                var nb: [96]u8 = undefined;
                const needle = std.fmt.bufPrint(&nb, "/v20g/g?k={s}", .{key}) catch "";
                const all = tally(&r, rec_tab, at, needle, null);
                const n1 = tally(&r, rec_tab, at, needle, "n1");
                const n2 = tally(&r, rec_tab, at, needle, "n2");
                const ec = endCheck(&r, rec_tab, at);
                wrong += all.wrong;
                own += n1.own + n2.own;
                amb += n1.ambiguous + n2.ambiguous;
                other += n1.other + n2.other;
                n_total += n1.total + n2.total;
                o_begins += all.total -| (n1.total + n2.total);
                missing += ec.missing;
                doubled += ec.doubled;
            }
            report(wrong == 0 and missing == 0 and doubled == 0, "v20g-r9-gap-" ++ m, std.fmt.bufPrint(&detail, "10 reloads: old-doc CEF records {d} (3 fetched per round) · reloaded n1+n2 records {d}: own {d} ambiguous {d} other {d} · WRONG {d} · no end {d} · several ends {d}", .{ o_begins, n_total, own, amb, other, wrong, missing, doubled }) catch "");
            try r.navigate(rec_tab, "/v20/blank?gapf");
            r.pump(4000);
        }
    }
    // ══ v20g A: WB-1 live — page A/B same task, dedicated worker fetches the same URL 250 ms later, C/D/E later ══
    if (enabled("g2w")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/v20g/wp?r=8");
        _ = r.pumpTitle(rec_tab, "wpdone", 90_000);
        r.pump(2000);
        // a body still waiting for a fetch slot ends a little later — tally once every begin has its end (or after 10 s more)
        var waited: u32 = 0;
        while (waited < 10_000 and endCheck(&r, rec_tab, at).missing > 0) : (waited += 500) r.pump(500);
        const all = tally(&r, rec_tab, at, "/v20g/s?", null);
        var line: [6][160]u8 = @splat(@splat(0));
        const whos = [_][]const u8{ "a", "b", "w", "c", "d", "e" };
        for (whos, 0..) |w, wi| {
            const t = tally(&r, rec_tab, at, "/v20g/s?", w);
            var s3: [200]u8 = undefined;
            _ = std.fmt.bufPrint(line[wi][0..159], "{s}: {d} own {d} amb {d} wrong {d}{s}", .{ w, t.total, t.own, t.ambiguous, t.wrong, stateLine(&t, &s3) }) catch "";
        }
        const ec = endCheck(&r, rec_tab, at);
        var el: [600]u8 = undefined;
        var sl2: [400]u8 = undefined;
        report(all.wrong == 0 and ec.missing == 0 and ec.doubled == 0, "v20g-r2-worker-same-url-concurrency", std.fmt.bufPrint(&detail, "{s} | {s} | {s} | {s} | {s} | {s} · all WRONG {d} · {s}{s}", .{ std.mem.sliceTo(&line[0], 0), std.mem.sliceTo(&line[1], 0), std.mem.sliceTo(&line[2], 0), std.mem.sliceTo(&line[3], 0), std.mem.sliceTo(&line[4], 0), std.mem.sliceTo(&line[5], 0), all.wrong, endLine(&ec, &el, &sl2), all.notes[0..all.notes_len] }) catch "");
    }
    // ══ 재검증 3 차 뒤(스모크 w9d-body 의 꼴): 쿠키를 심는 localhost 문서 → 127.0.0.1 문서(다른 사이트 — 새 렌더러)가 곧 받는 그림·다른 사이트의
    // 쿠키 실린 스크립트·JSON 둘(하나는 2 MiB). 통과 조건: 모든 시작에 끝이 하나(8 초 안 — `pending` 에 머물지 않는다), 그림은 not_text, 스크립트와
    // 작은 JSON 은 captured, 큰 JSON 은 over_cap. ══
    if (enabled("v20i")) {
        const rounds: usize = 20;
        if (size_body.len == 0) {
            size_body = try gpa.alloc(u8, 2 * 1024 * 1024);
            @memset(size_body, 'a');
            @memcpy(size_body[0..6], "{\"a\":\"");
            @memcpy(size_body[size_body.len - 2 ..], "\"}");
        }
        var missing: usize = 0;
        var doubled: usize = 0;
        var good: [4]usize = @splat(0);
        var bad_txt: [1500]u8 = undefined;
        var bn: usize = 0;
        for (0..rounds) |round| {
            var nb: [160]u8 = undefined;
            const url = std.fmt.bufPrint(&nb, "http://localhost:{d}/v20i/ck?{d}x{d}", .{ port, round, session }) catch "";
            try navigateUrl(&r, rec_tab, url);
            _ = r.pumpTitle(rec_tab, "ckdone", 10_000);
            const at = r.begins.items.len;
            var pb: [96]u8 = undefined;
            try r.navigate(rec_tab, std.fmt.bufPrint(&pb, "/v20i/bp?i{d}x{d}", .{ round, session }) catch "");
            _ = r.pumpTitle(rec_tab, "bpdone", 15_000);
            var waited: u32 = 0;
            while (waited < 8_000 and endCheck(&r, rec_tab, at).missing > 0) : (waited += 250) r.pump(250);
            const ec = endCheck(&r, rec_tab, at);
            missing += ec.missing;
            doubled += ec.doubled;
            const want = [_]struct { []const u8, msg.NetBodyState }{ .{ "/v20i/pic.png", .not_text }, .{ "/v20i/cred.js", .captured }, .{ "/v20i/c.json", .captured }, .{ "/v20i/big.json", .over_cap } };
            for (want, 0..) |w, wi| {
                var found = false;
                for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, w[0]) != null) {
                    found = true;
                    const x = r.body(rec_tab, b.request);
                    if (x.ends == 1 and x.state == w[1]) good[wi] += 1 else {
                        const piece = std.fmt.bufPrint(bad_txt[bn..], " [round {d} {s} req {d} ends {d} state {s}]", .{ round, w[0], b.request, x.ends, if (x.ends > 0) @tagName(x.state) else "pending" }) catch "";
                        bn += piece.len;
                    }
                    break;
                };
                if (!found) {
                    const piece = std.fmt.bufPrint(bad_txt[bn..], " [round {d} {s} no begin]", .{ round, w[0] }) catch "";
                    bn += piece.len;
                }
            }
        }
        const ok = missing == 0 and doubled == 0 and good[0] == rounds and good[1] == rounds and good[2] == rounds and good[3] == rounds;
        report(ok, "v20i-xsite-nav-body-page", std.fmt.bufPrint(&detail, "{d} rounds (localhost cookie page → 127.0.0.1 page): png not_text {d} · cross-site credentialed script captured {d} · json captured {d} · 2 MiB json over_cap {d} · no end {d} · several ends {d}{s}", .{ rounds, good[0], good[1], good[2], good[3], missing, doubled, bad_txt[0..bn] }) catch "");
        try r.navigate(rec_tab, "/v20/blank?v20i");
        r.pump(2000);
    }
    // ══ 재검증 3 차(v20h A): WB-4 꼬리 — 워커 기록이 a 앞에, 빠른 b, b 바로 뒤 d(그 CEF 기록이 b 의 응답 뒤에 닿을 수 있다) ══
    if (enabled("h2tail")) {
        inline for (.{ .{ "g1", "1", "0.3" }, .{ "g2", "2", "0.3" }, .{ "g3", "3", "0.3" }, .{ "e10", "2", "1.0" }, .{ "e15", "2", "1.5" }, .{ "e20", "2", "2.0" }, .{ "e25", "2", "2.5" }, .{ "e35", "2", "3.5" } }) |gv| {
            const at = r.begins.items.len;
            var pb: [96]u8 = undefined;
            try r.navigate(rec_tab, std.fmt.bufPrint(&pb, "/v20h/tp?{s}x{d}&r=40&g={s}&e={s}", .{ gv[0], session, gv[1], gv[2] }) catch "");
            _ = r.pumpTitle(rec_tab, "tpdone", 90_000);
            r.pump(2000);
            var waited: u32 = 0;
            while (waited < 8_000 and endCheck(&r, rec_tab, at).missing > 0) : (waited += 500) r.pump(500);
            const all = tally(&r, rec_tab, at, "/v20h/t?", null);
            var line: [4][160]u8 = @splat(@splat(0));
            for ([_][]const u8{ "w", "a", "b", "d" }, 0..) |w, wi| {
                const t = tally(&r, rec_tab, at, "/v20h/t?", w);
                var s3: [200]u8 = undefined;
                _ = std.fmt.bufPrint(line[wi][0..159], "{s}: {d} own {d} amb {d} wrong {d}{s}", .{ w, t.total, t.own, t.ambiguous, t.wrong, stateLine(&t, &s3) }) catch "";
            }
            const ec = endCheck(&r, rec_tab, at);
            var el: [600]u8 = undefined;
            var sl2: [400]u8 = undefined;
            report(all.wrong == 0 and ec.missing == 0 and ec.doubled == 0, "v20h-h2tail-" ++ gv[0], std.fmt.bufPrint(&detail, "40 rounds, gap {s} ms, d {s} ms after b: {s} | {s} | {s} | {s} · all WRONG {d} · {s}{s}", .{ gv[1], gv[2], std.mem.sliceTo(&line[0], 0), std.mem.sliceTo(&line[1], 0), std.mem.sliceTo(&line[2], 0), std.mem.sliceTo(&line[3], 0), all.wrong, endLine(&ec, &el, &sl2), all.notes[0..@min(all.notes_len, 600)] }) catch "");
            try r.navigate(rec_tab, "/v20/blank?h2t");
            r.pump(3000);
        }
    }
    // ══ 재검증 3 차(v20h A): 새 문서의 첫 요청이 알림보다 먼저 나간다(LB-1 — loader 로 가른다) · 같은 사이트 iframe 이 주 프레임과 같은 주소를
    // 받는다(보이는 규칙만 다른 짝은 그 짝만 본문 없이). `ns` 는 캐시를 거치지 않아 셋이 동시다(N-4). 통과 조건: 틀린 본문 0·끝 하나, 그리고
    // h9early·h9nsearly 는 제 본문이 거의 모두(60 중 57 이상 — 1c8e95230 은 h9nsearly 30/60), h2nsiframe 은 네 요청 가운데 판마다 하나까지만 잃는다
    // (80 중 57 이상 — 1c8e95230 은 주 프레임 0/60). 재검증 3 차 뒤 WB-5: 보이는 규칙이 다른 C·D 의 둘 중 먼저 정하는 쪽이 `ambiguous` 다 — 응답 전의
    // A·B 를 기다리게 되자 C 가 아니라 D 가 잃는다(전에는 주 프레임 A·B·D 60/60·C 0, 이제 A·B·C 60/60·D 0). ══
    inline for (.{ .{ "h9early", "/v20h/ep?", "epdone", [_][]const u8{ "a", "b", "c" }, "abc", 0 }, .{ "h2iframe", "/v20h/fp?", "fpdone", [_][]const u8{ "A", "B", "C", "D" }, "", 0 }, .{ "h9nsearly", "/v20h/ep?ns", "epdone", [_][]const u8{ "a", "b", "c" }, "abc", 0 }, .{ "h2nsiframe", "/v20h/fp?ns", "fpdone", [_][]const u8{ "A", "B", "C", "D" }, "ABCD", 1 } }) |c| {
        if (enabled(c[0])) {
            const whos = c[3];
            const rounds: usize = 20;
            var own: [whos.len]usize = @splat(0);
            var amb: [whos.len]usize = @splat(0);
            var tot: [whos.len]usize = @splat(0);
            var other_states: [16]usize = @splat(0);
            var wrong: usize = 0;
            var missing: usize = 0;
            var doubled: usize = 0;
            var rounds_txt: [1200]u8 = undefined;
            var rn: usize = 0;
            for (0..rounds) |round| {
                var kb: [64]u8 = undefined;
                const key = std.fmt.bufPrint(&kb, "{s}{d}x{d}", .{ c[0], round, session }) catch "";
                const at = r.begins.items.len;
                var pb: [128]u8 = undefined;
                try r.navigate(rec_tab, std.fmt.bufPrint(&pb, "{s}{s}", .{ c[1], key }) catch "");
                _ = r.pumpTitle(rec_tab, c[2], 15_000);
                r.pump(1500);
                var waited: u32 = 0;
                while (waited < 6_000 and endCheck(&r, rec_tab, at).missing > 0) : (waited += 500) r.pump(500);
                var nb: [96]u8 = undefined;
                const needle = std.fmt.bufPrint(&nb, "/v20h/e?k={s}{s}", .{ if (std.mem.indexOf(u8, c[1], "?ns") != null) "ns" else "", key }) catch "";
                const all = tally(&r, rec_tab, at, needle, null);
                wrong += all.wrong;
                const ec = endCheck(&r, rec_tab, at);
                missing += ec.missing;
                doubled += ec.doubled;
                var mark: [8]u8 = @splat('.');
                for (whos, 0..) |w, wi| {
                    const t = tally(&r, rec_tab, at, needle, w);
                    own[wi] += t.own;
                    amb[wi] += t.ambiguous;
                    tot[wi] += t.total;
                    for (t.states, 0..) |n, si| other_states[si] += n;
                    mark[wi] = if (t.own > 0) 'o' else if (t.ambiguous > 0) 'a' else if (t.total == 0) '-' else 'x';
                }
                const piece = std.fmt.bufPrint(rounds_txt[rn..], " {s}", .{mark[0..whos.len]}) catch "";
                rn += piece.len;
            }
            var lnb: [400]u8 = undefined;
            var ln: usize = 0;
            var want_own: usize = 0;
            for (whos, 0..) |w, wi| {
                const piece = std.fmt.bufPrint(lnb[ln..], "{s}: own {d}/{d} amb {d} · ", .{ w, own[wi], tot[wi], amb[wi] }) catch "";
                ln += piece.len;
                if (std.mem.indexOf(u8, c[4], w) != null) want_own += own[wi];
            }
            const need: usize = if (c[4].len == 0) 0 else (c[4].len - c[5]) * rounds - 3;
            var t2: Tally = .{};
            t2.states = other_states;
            report(wrong == 0 and missing == 0 and doubled == 0 and want_own >= need, "v20h-" ++ c[0], std.fmt.bufPrint(&detail, "{d} rounds · {s}WRONG {d} · no end {d} · several ends {d} · own of {s} {d} (need {d}) · states{s} · per round (o own, a ambiguous, x other){s}", .{ rounds, lnb[0..ln], wrong, missing, doubled, if (c[4].len == 0) "-" else c[4], want_own, need, stateLine(&t2, &sl), rounds_txt[0..rn] }) catch "");
            try r.navigate(rec_tab, "/v20/blank?h");
            r.pump(4000);
        }
    }

    // ══ 재검증 3 차 뒤: 검증자 v20i A 의 판정(WB-5 — 서비스 워커가 늦게 넘긴·늦게 답한 같은 주소 요청, PF-2 — abort 무리, IO 부하, 빨리 떠나기,
    // 앞 문서의 unload·pagehide fetch). 실제 사이트(`V20I_SITES`)·bfcache·document.open 꼴은 `X_V20I=1` 일 때만(이 OSR 탭에서 기록이 생기지
    // 않았다 — 검증 「Not verified」). ══
    {
        // SW late record / slow SW-synthesised answer (assumption: CEF IO ≤ 60 ms after the CDP start).
        inline for (.{ .{ "swlag-d20", "p2", "20" }, .{ "swlag-d100", "p2", "100" }, .{ "swlag-d300", "p2", "300" }, .{ "swsyn-d20", "s2", "20" }, .{ "swsyn-d100", "s2", "100" }, .{ "swsyn-d300", "s2", "300" } }) |c| if (enabled("v20i-" ++ c[0])) {
            // 항목마다 새 세션으로 다시 켠다 — 앞 항목(IO 부하 1500)이 쏟아짐 밸브로 기록을 멈출 수 있다(`recording_stopped`).
            session += 1;
            try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = session } });
            r.pump(300);
            const at = r.begins.items.len;
            var pb: [128]u8 = undefined;
            try r.navigate(rec_tab, std.fmt.bufPrint(&pb, "/v20i/sw/p?k={s}x{d}&m={s}&d={s}&r=20", .{ c[0], session, c[1], c[2] }) catch "");
            const done = r.pumpTitle(rec_tab, "swpdone", 60_000);
            r.pump(2000);
            var waited: u32 = 0;
            while (waited < 8_000 and endCheck(&r, rec_tab, at).missing > 0) : (waited += 500) r.pump(500);
            const all = tally(&r, rec_tab, at, "/v20i/sw/x?", null);
            var line: [3][200]u8 = @splat(@splat(0));
            for ([_][]const u8{ "X", "p1", c[1] }, 0..) |w, wi| {
                const t = tally(&r, rec_tab, at, "/v20i/sw/x?", w);
                var s3: [200]u8 = undefined;
                _ = std.fmt.bufPrint(line[wi][0..199], "{s}: {d} own {d} amb {d} wrong {d}{s}", .{ w, t.total, t.own, t.ambiguous, t.wrong, stateLine(&t, &s3) }) catch "";
            }
            const ec = endCheck(&r, rec_tab, at);
            var el: [600]u8 = undefined;
            var sl2: [400]u8 = undefined;
            report(done and all.wrong == 0 and all.sw_captured == 0 and ec.missing == 0 and ec.doubled == 0, "v20i-" ++ c[0], std.fmt.bufPrint(&detail, "20 rounds{s}: {s} | {s} | {s} · all WRONG {d} · {s}{s}", .{ if (done) "" else " (NOT DONE)", std.mem.sliceTo(&line[0], 0), std.mem.sliceTo(&line[1], 0), std.mem.sliceTo(&line[2], 0), all.wrong, endLine(&ec, &el, &sl2), all.notes[0..@min(all.notes_len, 700)] }) catch "");
            try r.navigate(rec_tab, "/v20/blank?swi");
            r.pump(2000);
        };
        // 재검증 4 차 뒤(검증자 v20j A R6-1): 워커가 같은 주소 두 요청을 거꾸로 넘기고 서버가 느리다.
        // `swalt-*`: 워커가 첫 요청(a1)에는 다른 주소(&alt=1)를 fetch 해 답한다(출처 network — 제 주소의 기록이 없다), p2 는 그대로 넘긴다.
        inline for (.{ .{ "swrev-d20-s400", "20", "400", "p1" }, .{ "swrev-d100-s400", "100", "400", "p1" }, .{ "swrev-d300-s600", "300", "600", "p1" }, .{ "swrev-d50-s0", "50", "0", "p1" }, .{ "swalt-s400", "0", "400", "a1" }, .{ "swalt-s50", "0", "50", "a1" }, .{ "swalt1-s400", "0", "400&n2=0", "a3" }, .{ "swalt1-s50", "0", "50&n2=0", "a3" } }) |c| if (enabled("v20j-" ++ c[0])) {
            session += 1;
            try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = session } });
            r.pump(300);
            const at = r.begins.items.len;
            var pb: [128]u8 = undefined;
            try r.navigate(rec_tab, std.fmt.bufPrint(&pb, "/v20j/sw/p?k={s}x{d}&d={s}&s={s}&f={s}&r=20", .{ c[0], session, c[1], c[2], c[3] }) catch "");
            const done = r.pumpTitle(rec_tab, "swjdone", 90_000);
            r.pump(2000);
            var waited: u32 = 0;
            while (waited < 10_000 and endCheck(&r, rec_tab, at).missing > 0) : (waited += 500) r.pump(500);
            const all = tally(&r, rec_tab, at, "/v20j/sw/x?", null);
            var line: [2][200]u8 = @splat(@splat(0));
            for ([_][]const u8{ c[3], "p2" }, 0..) |w, wi| {
                const t = tally(&r, rec_tab, at, "/v20j/sw/x?", w);
                var s3: [200]u8 = undefined;
                _ = std.fmt.bufPrint(line[wi][0..199], "{s}: {d} own {d} amb {d} wrong {d}{s}", .{ w, t.total, t.own, t.ambiguous, t.wrong, stateLine(&t, &s3) }) catch "";
            }
            const ec = endCheck(&r, rec_tab, at);
            var el: [600]u8 = undefined;
            var sl2: [400]u8 = undefined;
            report(done and all.wrong == 0 and all.sw_captured == 0 and ec.missing == 0 and ec.doubled == 0, "v20j-" ++ c[0], std.fmt.bufPrint(&detail, "20 rounds{s}: {s} | {s} · all WRONG {d} · {s}{s}", .{ if (done) "" else " (NOT DONE)", std.mem.sliceTo(&line[0], 0), std.mem.sliceTo(&line[1], 0), all.wrong, endLine(&ec, &el, &sl2), all.notes[0..@min(all.notes_len, 900)] }) catch "");
            try r.navigate(rec_tab, "/v20/blank?swj");
            r.pump(2000);
        };
        // 검증자 v20k: 메모리에 남긴 응답으로 답하며 같은 주소를 갱신(m2e·m2l), 제 주소를 받은 뒤 다른 주소로 답하고 그 주소를 페이지도 받음(fb).
        inline for (.{ .{ "swmemo-e-s0", "0", "m2e" }, .{ "swmemo-e-s300", "300", "m2e" }, .{ "swmemo-l-s0", "0", "m2l" }, .{ "swfb-s0", "0", "fb" }, .{ "swfb-s300", "300", "fb" } }) |c| if (enabled("v20k-" ++ c[0])) {
            session += 1;
            try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = session } });
            r.pump(300);
            const at = r.begins.items.len;
            var pb: [128]u8 = undefined;
            try r.navigate(rec_tab, std.fmt.bufPrint(&pb, "/v20j/sw/q?k={s}x{d}&s={s}&mo={s}&r=20", .{ c[0], session, c[1], c[2] }) catch "");
            const done = r.pumpTitle(rec_tab, "swqdone", 120_000);
            r.pump(2000);
            var waited: u32 = 0;
            while (waited < 10_000 and endCheck(&r, rec_tab, at).missing > 0) : (waited += 500) r.pump(500);
            const all = tally(&r, rec_tab, at, "/v20j/sw/x?", null);
            var line: [5][200]u8 = @splat(@splat(0));
            for ([_][]const u8{ "m1", "X", "f1", "F", "pf" }, 0..) |w, wi| {
                const t = tally(&r, rec_tab, at, "/v20j/sw/x?", w);
                var s3: [200]u8 = undefined;
                _ = std.fmt.bufPrint(line[wi][0..199], "{s}: {d} own {d} amb {d} wrong {d}{s}", .{ w, t.total, t.own, t.ambiguous, t.wrong, stateLine(&t, &s3) }) catch "";
            }
            // 재검증 5 차 S0: m2l 의 갱신 fetch 는 워커가 응답을 읽지 않고 쥔다 — CEF 가 끝내지 않아 그 본문은 `pending` 이 참(끝 없음으로 세지 않는다).
            const ec = endCheckOf(&r, rec_tab, at, comptime std.mem.eql(u8, c[2], "m2l"));
            var el: [600]u8 = undefined;
            var sl2: [400]u8 = undefined;
            report(done and all.wrong == 0 and all.sw_captured == 0 and ec.missing == 0 and ec.doubled == 0, "v20k-" ++ c[0], std.fmt.bufPrint(&detail, "20 rounds{s}: {s} | {s} | {s} | {s} | {s} · all WRONG {d} · {s}{s}", .{ if (done) "" else " (NOT DONE)", std.mem.sliceTo(&line[0], 0), std.mem.sliceTo(&line[1], 0), std.mem.sliceTo(&line[2], 0), std.mem.sliceTo(&line[3], 0), std.mem.sliceTo(&line[4], 0), all.wrong, endLine(&ec, &el, &sl2), all.notes[0..@min(all.notes_len, 900)] }) catch "");
            try r.navigate(rec_tab, "/v20/blank?swq");
            r.pump(2000);
        };
        // 검증자 v20j A(조정자 요청): body-r4-sw-mixed 꼴을 여러 판(`V20J_MIX_LOADS` — 기본 40 판 × 20 묶음).
        if (enabled("v20j-swmix")) {
            const loads: usize = if (std.c.getenv("V20J_MIX_LOADS")) |v| std.fmt.parseInt(usize, std.mem.span(v), 10) catch 40 else 40;
            var wrong: usize = 0;
            var sw_total: usize = 0;
            var sw_own: usize = 0;
            var missing: usize = 0;
            var doubled: usize = 0;
            var bad_loads: usize = 0;
            var notes: [1500]u8 = undefined;
            var nn: usize = 0;
            var st: [16]usize = @splat(0);
            for (0..loads) |load| {
                session += 1;
                try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = session } });
                r.pump(300);
                const at = r.begins.items.len;
                var pb: [128]u8 = undefined;
                try r.navigate(rec_tab, std.fmt.bufPrint(&pb, "/v20j/mx/p?k=L{d}x{d}", .{ load, session }) catch "");
                const done = r.pumpTitle(rec_tab, "mxdone", 30_000);
                r.pump(3000);
                const all = tally(&r, rec_tab, at, "/v20j/mx/pt?", null);
                const pt = tally(&r, rec_tab, at, "/v20j/mx/pt?", "pt");
                const ec = endCheck(&r, rec_tab, at);
                wrong += all.wrong;
                sw_total += pt.total;
                sw_own += pt.own;
                missing += ec.missing;
                doubled += ec.doubled;
                for (all.states, 0..) |x, si| st[si] += x;
                if (!done or all.wrong > 0) {
                    bad_loads += 1;
                    const piece = std.fmt.bufPrint(notes[nn..], " [load {d} done {} begins from {d}: wrong {d}{s}]", .{ load, done, at, all.wrong, all.notes[0..@min(all.notes_len, 300)] }) catch "";
                    nn += piece.len;
                }
                std.debug.print("v20j-swmix load {d}: wrong {d} pt own {d}/{d}\n", .{ load, all.wrong, pt.own, pt.total });
                try r.navigate(rec_tab, "/v20/blank?mx");
                r.pump(500);
            }
            var t2: Tally = .{};
            t2.states = st;
            report(wrong == 0 and sw_own == 0 and missing == 0 and doubled == 0 and bad_loads == 0, "v20j-swmix", std.fmt.bufPrint(&detail, "{d} loads × 20: WRONG {d} · pass-through own {d}/{d} · no end {d} · several ends {d} · states{s}{s}", .{ loads, wrong, sw_own, sw_total, missing, doubled, stateLine(&t2, &sl), notes[0..nn] }) catch "");
        }
        // IO load between p1 and p2.
        inline for (.{ .{ "load-n100", "100" }, .{ "load-n400", "400" }, .{ "load-n1500", "1500" } }) |c| if (enabled("v20i-" ++ c[0])) {
            // 항목마다 새 세션으로 다시 켠다 — 앞 항목(IO 부하 1500)이 쏟아짐 밸브로 기록을 멈출 수 있다(`recording_stopped`).
            session += 1;
            try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = session } });
            r.pump(300);
            const at = r.begins.items.len;
            var pb: [128]u8 = undefined;
            try r.navigate(rec_tab, std.fmt.bufPrint(&pb, "/v20i/lp?k={s}x{d}&n={s}&r=10", .{ c[0], session, c[1] }) catch "");
            const done = r.pumpTitle(rec_tab, "lpdone", 90_000);
            r.pump(2000);
            var waited: u32 = 0;
            while (waited < 10_000 and endCheck(&r, rec_tab, at).missing > 0) : (waited += 500) r.pump(500);
            const all = tally(&r, rec_tab, at, "/v20i/l?", null);
            var line: [3][200]u8 = @splat(@splat(0));
            for ([_][]const u8{ "X", "p1", "p2" }, 0..) |w, wi| {
                const t = tally(&r, rec_tab, at, "/v20i/l?", w);
                var s3: [200]u8 = undefined;
                _ = std.fmt.bufPrint(line[wi][0..199], "{s}: {d} own {d} amb {d} wrong {d}{s}", .{ w, t.total, t.own, t.ambiguous, t.wrong, stateLine(&t, &s3) }) catch "";
            }
            const ec = endCheck(&r, rec_tab, at);
            var el: [600]u8 = undefined;
            var sl2: [400]u8 = undefined;
            report(done and all.wrong == 0 and ec.missing == 0 and ec.doubled == 0, "v20i-" ++ c[0], std.fmt.bufPrint(&detail, "10 rounds{s}: {s} | {s} | {s} · all WRONG {d} · {s}{s}", .{ if (done) "" else " (NOT DONE)", std.mem.sliceTo(&line[0], 0), std.mem.sliceTo(&line[1], 0), std.mem.sliceTo(&line[2], 0), all.wrong, endLine(&ec, &el, &sl2), all.notes[0..@min(all.notes_len, 700)] }) catch "");
            try r.navigate(rec_tab, "/v20/blank?li");
            r.pump(3000);
        };
        // navigate-quickly: a's body after the page leaves X ms after a resolved.
        inline for (.{ .{ "navq-x0", "0" }, .{ "navq-x20", "20" }, .{ "navq-x50", "50" }, .{ "navq-x100", "100" }, .{ "navq-x300", "300" } }) |c| if (enabled("v20i-" ++ c[0])) {
            // 항목마다 새 세션으로 다시 켠다 — 앞 항목(IO 부하 1500)이 쏟아짐 밸브로 기록을 멈출 수 있다(`recording_stopped`).
            session += 1;
            try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = session } });
            r.pump(300);
            var own_a: usize = 0;
            var wrong: usize = 0;
            var missing: usize = 0;
            var doubled: usize = 0;
            var st: [16]usize = @splat(0);
            for (0..20) |round| {
                const at = r.begins.items.len;
                var pb: [128]u8 = undefined;
                try r.navigate(rec_tab, std.fmt.bufPrint(&pb, "/v20i/qp?k={s}_{d}x{d}&x={s}", .{ c[0], round, session, c[1] }) catch "");
                _ = r.pumpTitle(rec_tab, "blank", 6_000);
                r.pump(2500);
                var waited: u32 = 0;
                while (waited < 4_000 and endCheck(&r, rec_tab, at).missing > 0) : (waited += 500) r.pump(500);
                const ta = tally(&r, rec_tab, at, "/v20i/q?", "a");
                const all = tally(&r, rec_tab, at, "/v20i/q?", null);
                own_a += ta.own;
                wrong += all.wrong;
                for (ta.states, 0..) |n, si| st[si] += n;
                const ec = endCheck(&r, rec_tab, at);
                missing += ec.missing;
                doubled += ec.doubled;
            }
            var t2: Tally = .{};
            t2.states = st;
            report(wrong == 0 and missing == 0 and doubled == 0, "v20i-" ++ c[0], std.fmt.bufPrint(&detail, "20 rounds, navigate {s} ms after a resolved: a own {d}/20 · a states{s} · all WRONG {d} · no end {d} · several ends {d}", .{ c[1], own_a, stateLine(&t2, &sl), wrong, missing, doubled }) catch "");
        };

        // real sites (V20I_SITES=url,url…): body_expected begins and their end states (loss rates; no wrong-body oracle).
        if (enabled("v20i-sites") and std.c.getenv("X_V20I") != null) if (std.c.getenv("V20I_SITES")) |sites_z| {
            var it = std.mem.splitScalar(u8, std.mem.span(sites_z), ',');
            while (it.next()) |site| {
                if (site.len == 0) continue;
                const at = r.begins.items.len;
                try navigateUrl(&r, rec_tab, site);
                r.pump(15_000);
                try r.navigate(rec_tab, "/v20/blank?site");
                r.pump(5_000);
                const ec = endCheck(&r, rec_tab, at);
                var el: [600]u8 = undefined;
                var sl2: [400]u8 = undefined;
                var cap: usize = 0;
                for (r.begins.items[at..]) |b| if (b.browser == rec_tab and b.expected) {
                    const x = r.body(rec_tab, b.request);
                    if (x.ends >= 1 and x.state == .captured) cap += 1;
                };
                report(ec.missing == 0 and ec.doubled == 0, "v20i-sites", std.fmt.bufPrint(&detail, "{s}: captured {d} · {s}", .{ site, cap, endLine(&ec, &el, &sl2) }) catch "");
            }
        };

        if (enabled("v20i-hostile")) {
            // 항목마다 새 세션으로 다시 켠다 — 앞 항목(IO 부하 1500)이 쏟아짐 밸브로 기록을 멈출 수 있다(`recording_stopped`).
            session += 1;
            try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = session } });
            r.pump(300);
            const at = r.begins.items.len;
            var pb: [160]u8 = undefined;
            const qs = if (std.c.getenv("V20I_HOSTILE_Q")) |q| std.mem.span(q) else "d=60&f=3900&e=60&r=3";
            try r.navigate(rec_tab, std.fmt.bufPrint(&pb, "/v20i/hp?k=h{d}&{s}", .{ session, qs }) catch "");
            const done = r.pumpTitle(rec_tab, "hpdone", 60_000);
            r.pump(4000);
            const all = tally(&r, rec_tab, at, "/v20i/h?", null);
            const ec = endCheck(&r, rec_tab, at);
            var el: [600]u8 = undefined;
            var sl2: [400]u8 = undefined;
            report(done and all.wrong == 0 and ec.missing == 0 and ec.doubled == 0, "v20i-hostile", std.fmt.bufPrint(&detail, "{s}{s}: CEF records {d} own {d} amb {d} WRONG {d} · {s}", .{ qs, if (done) "" else " (NOT DONE)", all.total, all.own, all.ambiguous, all.wrong, endLine(&ec, &el, &sl2) }) catch "");
            try r.navigate(rec_tab, "/v20/blank?hi");
            r.pump(2000);
        }
        // old-document fetches around the switch (unload / pagehide abort / bfcache / document.open) + n1/n2 of the same URL.
        inline for (.{ .{ "gunload", "unload", "/v20i/gp?", false }, .{ "ghidecut", "hidecut", "/v20i/gp?", false }, .{ "gbf", "bf", "/v20i/bfa?", true }, .{ "gdocopen", "docopen", "/v20i/gp?", true } }) |c| if (enabled("v20i-" ++ c[0]) and (!c[3] or std.c.getenv("X_V20I") != null)) {
            // 항목마다 새 세션으로 다시 켠다 — 앞 항목(IO 부하 1500)이 쏟아짐 밸브로 기록을 멈출 수 있다(`recording_stopped`).
            session += 1;
            try r.host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = session } });
            r.pump(300);
            var own: [3]usize = @splat(0);
            var tot: [3]usize = @splat(0);
            var wrong: usize = 0;
            var missing: usize = 0;
            var doubled: usize = 0;
            var rounds_txt: [400]u8 = undefined;
            var rn: usize = 0;
            var notes: [700]u8 = undefined;
            var nn: usize = 0;
            for (0..10) |round| {
                var kb: [64]u8 = undefined;
                const key = std.fmt.bufPrint(&kb, "{s}{d}x{d}", .{ c[0], round, session }) catch "";
                const at = r.begins.items.len;
                var pb: [128]u8 = undefined;
                try r.navigate(rec_tab, std.fmt.bufPrint(&pb, "{s}k={s}&m={s}", .{ c[2], key, c[1] }) catch "");
                _ = r.pumpTitle(rec_tab, "igdone", 12_000);
                r.pump(1500);
                var waited: u32 = 0;
                while (waited < 6_000 and endCheck(&r, rec_tab, at).missing > 0) : (waited += 500) r.pump(500);
                var nb: [96]u8 = undefined;
                const needle = std.fmt.bufPrint(&nb, "/v20i/g?k={s}", .{key}) catch "";
                const all = tally(&r, rec_tab, at, needle, null);
                wrong += all.wrong;
                if (all.wrong > 0 and nn < 600) {
                    const piece = std.fmt.bufPrint(notes[nn..], "{s}", .{all.notes[0..@min(all.notes_len, 600 - nn)]}) catch "";
                    nn += piece.len;
                }
                const ec = endCheck(&r, rec_tab, at);
                missing += ec.missing;
                doubled += ec.doubled;
                var mark: [3]u8 = @splat('.');
                for ([_][]const u8{ "o", "n1", "n2" }, 0..) |w, wi| {
                    const t = tally(&r, rec_tab, at, needle, w);
                    own[wi] += t.own;
                    tot[wi] += t.total;
                    mark[wi] = if (t.wrong > 0) 'W' else if (t.own > 0) 'o' else if (t.ambiguous > 0) 'a' else if (t.total == 0) '-' else 'x';
                }
                const piece = std.fmt.bufPrint(rounds_txt[rn..], " {s}", .{mark[0..]}) catch "";
                rn += piece.len;
            }
            report(wrong == 0 and missing == 0 and doubled == 0, "v20i-" ++ c[0], std.fmt.bufPrint(&detail, "10 rounds · o own {d}/{d} · n1 own {d}/{d} · n2 own {d}/{d} · WRONG {d} · no end {d} · several ends {d} · per round (o n1 n2){s}{s}", .{ own[0], tot[0], own[1], tot[1], own[2], tot[2], wrong, missing, doubled, rounds_txt[0..rn], notes[0..nn] }) catch "");
            try r.navigate(rec_tab, "/v20/blank?gi");
            r.pump(2000);
        };
    }
}
