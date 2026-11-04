//! W9d② 재검증 6 차(`e3c8cdba9`) 적대 검증 11–20 회차의 탐침(`--review-body-v20m`, 고른 항목만 `V20M_ONLY=r11-nav,…`). 재검증 7 차부터 고친 뒤의
//! 기준이다 — `r11-valve`(N11 — 남의 출처 세션의 사건은 밸브에 세지 않는다)·`r12-move`(N12 — 몫은 워커의 출처마다)·`r13-flood`(N13 — 남의 출처
//! 세션도 탭마다 묶고 넘으면 세워 둔다)·`r14-cap512`(N14 — 닫힌 탭의 출처 몫을 놓는다)는 고치기 전에 실패했다. 판정자가 maru 역할로
//! sidecar 를 `MARU_WEB_SW_CDP=1`·`MARU_WEB_TEST_BODY_LOG=1` 로 띄우고 회차마다 각도 하나를 잰다. 합격 조건은 설계가 약속한 것(틀린 본문 0 ·
//! 고친 결함의 보장 — F13 「그 탭이 보이는 출처의 워커만 산다」, F14a 「다른 출처의 워커가 이 탭의 몫을 막지 않는다」, F14c 「한 탭이 세션 64 를 다
//! 쥐지 않는다」, F11 「인자 없는 getTargetInfo 만」)이고, 그 밖의 잰 값은 줄에 적는다.
//!
//! 출처: O1 = http://127.0.0.1:P1, O2..O6 = http://127.0.0.1:Pn(같은 사이트·다른 출처 — 저장소를 나누지 않는다), X2 = http://localhost:P2.
//!   r11-nav        기록 중 3 초 안에 맨 위 출처를 여러 번 바꾼다(O1·O2·X2) — 틀린 본문 0, 앞 출처 워커는 결국 멈춘다
//!   r11-retarget   iframe(O2)이 새 워커를 띄워 남의 것(foreign)으로 붙은 뒤 d ms 에 탭이 그 출처로 옮긴다(d = 3 초 앞뒤) — 틀린 본문 0
//!   r12-move       탭 A(첫 자리)가 O2 의 워커로 몫 128 을 채운 뒤 O1 로 옮긴다 — 같은 O1 의 탭 B(기록)의 서비스 워커 갈래 기록이 남는가
//!   r13-flood      기록하는 탭의 iframe(O2)이 워커를 잇달아 띄운다(떼기를 기다리는 남의 세션) — 다른 탭 B 의 워커가 붙는가(탭 16·전체 64)
//!   r14-cap512     네 탭이 각자 몫 128 을 채워 전체 512 — 그 탭들을 닫은 뒤 다른 탭이 언제 되찾는가
//!   r15-forms      getTargetInfo 의 인자 꼴(빈 객체·공백·같은 열쇠 둘·유니코드 이스케이프·잘린 JSON·크기 속이기)
//!   r19-big        큰 본문(0.9 MB × 30 + 3 MB × 10)을 서비스 워커로 넘기는 동안 판정자가 10 초 읽지 않는다 — host 메모리·끝·틀림
//!   v20o-r12rec    (재검증 9 차 — 검증 v20o 3 회차 탐침) v20n-r12-hop 을 A 가 기록하며 — 비운 놓은 요청의 기록이 틀린 본문·끝 둘·끝 없음 없이 끝나는가

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

const n_ports = 6;
var ports: [n_ports]u16 = @splat(0);
var counter = std.atomic.Value(u64).init(1);
var boots: [16]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));
var hang_open = std.atomic.Value(i64).init(0);
var hang_seen = std.atomic.Value(i64).init(0);
/// 판정자가 세우면 열린 `/g/hang` 이 곧 답한다(줄 선 것도 오는 대로 곧 — 몫을 빨리 비운다).
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

/// 워커: 시작할 때마다 `/g/boot?b=B`. 주소가 `/x`·`/hang`·`/big` 로 끝나면 그대로 넘긴다. 메시지 `hold` — 워커 자신이 끝나지 않는 fetch n 개
/// (`/g/hang?s=…` — 본문을 읽지 않는 갱신 fetch 꼴, 페이지가 떠나도 끊기지 않는다).
const sw_js = "var Q=new URL(location.href).searchParams;var B=Q.get('b')||'0';var LOOP=0;" ++
    "fetch('/g/boot?b='+B,{cache:'no-store'}).catch(function(){});" ++
    "self.addEventListener('install',function(){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
    "self.addEventListener('fetch',function(e){var p=new URL(e.request.url).pathname;if(p.endsWith('/x')||p.endsWith('/hang')||p.endsWith('/big')){e.respondWith(fetch(e.request))}});" ++
    "self.addEventListener('message',function(e){var d=e.data||{};" ++
    "if(d.op=='loop'){LOOP=1;e.waitUntil((async function(){var i=0;while(LOOP&&i<d.n){await fetch('/g/x?k=loop'+B+'_'+(i++),{cache:'no-store'}).then(function(r){return r.text()}).catch(function(){})}})())}if(d.op=='stop'){LOOP=0}" ++
    "if(d.op=='hold'){var ps=[];for(var i=0;i<d.n;i++){ps.push(fetch('/g/hang?s='+d.s+'&h='+B+'_'+i,{cache:'no-store'}).then(function(r){return r.text()}).catch(function(){}))}e.waitUntil(Promise.all(ps))}});";

/// 페이지: SW(`/g/sw.js?b=B`, 범위 `/g/`)를 깔고 다스릴 때까지 다시 불러온 뒤, iframe 을 넣고 fetch n 개를 하고 `ready`.
const page_js = "var P=new URLSearchParams(location.search);" ++
    "navigator.serviceWorker.register('/g/sw.js?b='+(P.get('b')||'1'),{scope:'/g/'}).then(function(){return navigator.serviceWorker.ready}).then(async function(){" ++
    "if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}" ++
    "var fs=(P.get('if')||'').split(',').filter(function(x){return x});for(var q=0;q<fs.length;q++){var f=document.createElement('iframe');f.src=decodeURIComponent(fs[q]);document.body.appendChild(f);await new Promise(function(r){f.onload=r;setTimeout(r,6000)})}" ++
    "var n=+(P.get('n')||0);var K=P.get('k')||'k';" ++
    "for(var i=0;i<n;i++){await fetch('/g/x?k='+K+i,{cache:'no-store'}).then(function(r){return r.text()}).catch(function(){})}" ++
    "document.title='ready:'+K})";

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
    if (std.mem.eql(u8, path, "/g/boot")) {
        const b = std.fmt.parseInt(usize, queryValue(target, "b"), 10) catch 15;
        _ = boots[@min(b, 15)].fetchAdd(1, .monotonic);
        return reply(conn, "text/plain", "boot");
    }
    if (std.mem.eql(u8, path, "/g/p")) return reply(conn, html, "<!doctype html><title>p</title><script>" ++ page_js ++ "</script>p");
    if (std.mem.eql(u8, path, "/g/probe")) return reply(conn, html, "<!doctype html><title>probed</title>probe");
    // iframe(O2): 새 워커 하나(범위 `/g/s6/`, 판마다 새 판 `v` — 새 타깃이 뜬다).
    if (std.mem.eql(u8, path, "/g/reg6")) return reply(conn, html, "<!doctype html><title>r6</title><script>" ++
        "navigator.serviceWorker.register('/g/sw.js?b=6&v='+new URLSearchParams(location.search).get('v'),{scope:'/g/s6/'}).catch(function(){})</script>r6");
    // iframe(O2): 새 워커(b=6, 판 v)를 띄우고 활성이 되면 끝없는 fetch 를 시킨다(loop=1).
    if (std.mem.eql(u8, path, "/g/reg6l")) return reply(conn, html, "<!doctype html><title>r6l</title><script>" ++
        "var P=new URLSearchParams(location.search);navigator.serviceWorker.register('/g/sw.js?b=6&v='+P.get('v'),{scope:'/g/s6/'}).then(function(r){var w=r.installing||r.waiting||r.active;function go(){if(P.get('loop')=='1')w.postMessage({op:'loop',n:1000000})}if(w.state=='activated')go();else w.addEventListener('statechange',function(){if(w.state=='activated')go()})}).catch(function(){})</script>r6l");
    // `/g/s6/` 범위 안 — 다스리는 워커에 멈춤을 보낸다.
    if (std.mem.eql(u8, path, "/g/s6/stop")) return reply(conn, html, "<!doctype html><title>st</title><script>" ++
        "navigator.serviceWorker.ready.then(function(r){r.active.postMessage({op:'stop'});setTimeout(function(){document.title='stopped'},300)})</script>st");
    // `/g/s6/` 범위 안 페이지 — 다스리는 워커(b=6)를 거쳐 n 번.
    if (std.mem.eql(u8, path, "/g/s6/p")) return reply(conn, html, "<!doctype html><title>s6</title><script>" ++
        "var P=new URLSearchParams(location.search);(async function(){if(!navigator.serviceWorker.controller){await navigator.serviceWorker.ready;if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}}" ++
        "var n=+P.get('n'),K=P.get('k');for(var i=0;i<n;i++){await fetch('/g/s6/x?k='+K+i,{cache:'no-store'}).then(function(r){return r.text()}).catch(function(){})}document.title='ready:'+K})()</script>s6");
    // iframe: 워커를 잇달아 띄운다 — `every` ms 마다 `per` 개(범위마다 새 등록), 3.5 초 뒤 그 등록을 푼다, `dur` ms 동안.
    if (std.mem.eql(u8, path, "/g/regmany")) return reply(conn, html, "<!doctype html><title>rm</title><script>" ++
        "var P=new URLSearchParams(location.search);var per=+P.get('per'),ev=+P.get('every'),dur=+P.get('dur');var t0=Date.now();var c=0;" ++
        "function tick(){if(Date.now()-t0>dur)return;for(var i=0;i<per;i++){c++;navigator.serviceWorker.register('/g/sw.js?b=9&z='+c+'_'+t0,{scope:'/g/z/'+t0+'_'+c+'/'}).then(function(r){setTimeout(function(){r.unregister()},3500)}).catch(function(){})}setTimeout(tick,ev)}tick();</script>rm");
    // 다스리는 워커에 「끝나지 않는 fetch n 개」 를 시킨다(워커 자신의 fetch — 페이지가 떠나도 이어진다).
    if (std.mem.eql(u8, path, "/g/swhold")) return reply(conn, html, "<!doctype html><title>sh</title><script>" ++
        "var P=new URLSearchParams(location.search);navigator.serviceWorker.ready.then(function(r){r.active.postMessage({op:'hold',n:+P.get('n'),s:+P.get('s')});setTimeout(function(){document.title='sheld'},1500)})</script>sh");
    // 큰 본문 n 개를 한꺼번에(다스리는 워커가 그대로 넘긴다).
    if (std.mem.eql(u8, path, "/g/bigp")) return reply(conn, html, "<!doctype html><title>bp</title><script>" ++
        "var P=new URLSearchParams(location.search);(async function(){await navigator.serviceWorker.ready;if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}" ++
        "var n=+P.get('n'),sz=P.get('sz'),K=P.get('k');var ps=[];for(var i=0;i<n;i++)ps.push(fetch('/g/big?sz='+sz+'&k='+K+i,{cache:'no-store'}).then(function(r){return r.text()}).catch(function(){}));await Promise.all(ps);document.title='ready'})()</script>bp");
    if (std.mem.eql(u8, path, "/g/hang")) {
        const s = std.fmt.parseInt(u32, queryValue(target, "s"), 10) catch 45;
        _ = hang_seen.fetchAdd(1, .monotonic);
        _ = hang_open.fetchAdd(1, .monotonic);
        const until = os.nowMs() + @as(i64, @min(s, 600)) * 1000;
        while (os.nowMs() < until and !hang_release.load(.monotonic)) os.sleepMs(50);
        _ = hang_open.fetchSub(1, .monotonic);
        return reply(conn, "application/json", "{\"n\":\"hang\"}");
    }
    if (std.mem.eql(u8, path, "/g/big")) {
        const n = counter.fetchAdd(1, .monotonic);
        const sz = std.fmt.parseInt(usize, queryValue(target, "sz"), 10) catch 1000;
        const body = std.heap.c_allocator.alloc(u8, @max(sz, 32)) catch return;
        defer std.heap.c_allocator.free(body);
        @memset(body, 'a');
        const headp = std.fmt.bufPrint(body, "{{\"n\":\"{d}\",\"p\":\"", .{n}) catch return;
        _ = headp;
        body[body.len - 2] = '"';
        body[body.len - 1] = '}';
        var eb: [160]u8 = undefined;
        return replyStatus(conn, "200 OK", "application/json", std.fmt.bufPrint(&eb, "X-Served: {d}\r\nX-Body: {d}\r\n", .{ n, n }) catch "", body);
    }
    if (std.mem.endsWith(u8, path, "/x")) {
        const n = counter.fetchAdd(1, .monotonic);
        var bb: [64]u8 = undefined;
        var eb: [160]u8 = undefined;
        return replyStatus(conn, "200 OK", "application/json", std.fmt.bufPrint(&eb, "X-Served: {d}\r\nX-Body: {d}\r\n", .{ n, n }) catch "", std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{n}) catch "");
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
    titles: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    closed: std.AutoHashMapUnmanaged(u64, void) = .empty,
    on_session: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    dropped_sw: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    begins: std.ArrayList(Begin) = .empty,
    bodies: std.ArrayList(Body) = .empty,
    dts: std.ArrayList(Dt) = .empty,
    next_call: u32 = 5000,
    /// 본문 데이터를 버린다(큰 본문 — 판정자 메모리). 크기만 센다.
    keep_data: bool = true,
    big_bytes: u64 = 0,

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
                const h = self.dropped_sw.getOrPut(self.gpa, v.browser) catch return;
                if (!h.found_existing) h.value_ptr.* = 0;
                h.value_ptr.* += v.sw_inflight_cap;
            },
            .net_body_data => |v| {
                const b = self.body(v.browser, v.request);
                if (!self.keep_data) {
                    // 머리 64 바이트만(본문의 셈 `{"n":"…"`).
                    if (b.data.items.len < 64) b.data.appendSlice(self.gpa, v.bytes[0..@min(v.bytes.len, 64 - b.data.items.len)]) catch {};
                    self.big_bytes += v.bytes.len;
                } else if (v.offset == b.data.items.len) b.data.appendSlice(self.gpa, v.bytes) catch {};
            },
            .net_body_end => |v| {
                const b = self.body(v.browser, v.request);
                b.ends += 1;
                b.state = v.state;
                b.session = v.session;
            },
            .net_record_state => |v| self.states.put(self.gpa, v.browser, v.status) catch {},
            .devtools_result_data => |v| self.dt(v.call).data.appendSlice(self.gpa, v.bytes) catch {},
            .devtools_result => |v| {
                const d = self.dt(v.call);
                d.done = true;
                d.status = v.status;
            },
            .browser_created => |id| self.created.put(self.gpa, id, {}) catch {},
            .browser_closed => |id| self.closed.put(self.gpa, id, {}) catch {},
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

    fn callRaw(self: *Run, browser: u64, method: []const u8, declared: u32, chunks: []const []const u8) struct { status: msg.DevtoolsStatus, data: []const u8, answered: bool } {
        self.next_call += 1;
        const id = self.next_call;
        self.host.send(.{ .devtools_call = .{ .browser = browser, .call = id, .method = method, .params_size = declared } }) catch return .{ .status = .send_failed, .data = "", .answered = false };
        for (chunks) |ch| self.host.send(.{ .devtools_call_data = .{ .browser = browser, .call = id, .bytes = ch } }) catch {};
        const deadline = os.nowMs() + 8000;
        while (os.nowMs() < deadline) {
            const d = self.dt(id);
            if (d.done) return .{ .status = d.status, .data = d.data.items, .answered = true };
            const m = (self.host.next(20) catch null) orelse continue;
            self.take(m);
        }
        return .{ .status = .expired, .data = "", .answered = false };
    }

    fn call(self: *Run, browser: u64, method: []const u8, params: []const u8) struct { status: msg.DevtoolsStatus, data: []const u8, answered: bool } {
        const x = self.callRaw(browser, method, @intCast(params.len), if (params.len > 0) &.{params} else &.{});
        return .{ .status = x.status, .data = x.data, .answered = x.answered };
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
    const only = std.c.getenv("V20M_ONLY") orelse return true;
    var it = std.mem.splitScalar(u8, std.mem.span(only), ',');
    while (it.next()) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
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

fn closeTab(r: *Run, id: u64) void {
    r.host.send(.{ .destroy_browser = id }) catch return;
    const Closed = struct {
        fn got(x: *Run, b: u64) bool {
            return x.closed.contains(b);
        }
    };
    _ = r.waitFor(5000, id, Closed.got);
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

/// 줄에 `a` 와 `b` 가 함께 든 수.
fn count2(log: []const u8, a: []const u8, b: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |line| if (std.mem.indexOf(u8, line, a) != null and std.mem.indexOf(u8, line, b) != null) {
        n += 1;
    };
    return n;
}

fn count3(log: []const u8, a: []const u8, b: []const u8, c: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |line| if (std.mem.indexOf(u8, line, a) != null and std.mem.indexOf(u8, line, b) != null and std.mem.indexOf(u8, line, c) != null) {
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
            var want2: [64]u8 = undefined;
            const w = std.fmt.bufPrint(&want, "{{\"n\":\"{s}\"", .{x.xbody}) catch "";
            const exact_small = std.mem.eql(u8, x.data.items, std.fmt.bufPrint(&want2, "{{\"n\":\"{s}\"}}", .{x.xbody}) catch "");
            const big_ok = !r.keep_data and std.mem.startsWith(u8, x.data.items, w);
            if (x.xbody.len > 0 and (exact_small or big_ok)) {
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
    return std.fmt.bufPrint(buf, "records {d} (sw {d}) · own body sw {d} page {d} · WRONG {d} · no end {d} · held {d} · bad session {d} · states{s}", .{ t.total, t.sw, t.sw_own, t.page_own, t.wrong, t.no_end, t.held, t.bad_session, sl[0..n] }) catch "";
}

fn swRecords(r: *Run, browser: u64, at: usize, needle: []const u8) usize {
    var n: usize = 0;
    for (r.begins.items[at..]) |b| if (b.browser == browser and b.sw and std.mem.indexOf(u8, b.url, needle) != null) {
        n += 1;
    };
    return n;
}

fn hostAlive(r: *Run) bool {
    const c = r.call(tab_b, "Runtime.evaluate", "{\"expression\":\"1+1\",\"returnByValue\":true}");
    return c.answered and c.status == .ok;
}

const Idle = struct { stopped: bool, probed: bool, before: u64, after: u64 };
fn idleThenProbe(r: *Run, prober: u64, host_name: []const u8, port: u16, b: usize) !Idle {
    const before = boots[b].load(.monotonic);
    r.pump(idle_ms);
    var u: [256]u8 = undefined;
    try r.go(prober, try std.fmt.bufPrint(&u, "http://{s}:{d}/g/probe", .{ host_name, port }));
    const probed = r.pumpTitle(prober, "probed", 15_000);
    r.pump(2000);
    const after = boots[b].load(.monotonic);
    try r.goO(prober, 0, "/blank");
    r.pump(500);
    return .{ .stopped = after > before, .probed = probed, .before = before, .after = after };
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

/// 붙은 워커 진단 줄(`sw-attached b=… keep=true own=… url=…`)에서 b 의 것만 세어 「동시에 붙어 있던 최대 수」 를 어림한다 — 붙음 +1, 남의 출처
/// 떼기(`sw-foreign-detach b=…`)·떼어진 사건(`sw-detached b=…`)에 −1.
fn maxLive(log: []const u8, who: []const u8) usize {
    var live: isize = 0;
    var best: isize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, who) == null) continue;
        if (std.mem.indexOf(u8, line, "sw-attached ") != null and std.mem.indexOf(u8, line, "keep=true") != null) live += 1;
        if (std.mem.indexOf(u8, line, "sw-foreign-detach ") != null) live -= 1;
        best = @max(best, live);
    }
    return @intCast(@max(best, 0));
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    for (0..n_ports) |i| try startServer(i);
    var detail: [4000]u8 = undefined;
    var env_buf: [4][*:0]const u8 = undefined;
    var env_n: usize = 0;
    env_buf[env_n] = "MARU_WEB_SW_CDP=1";
    env_n += 1;
    env_buf[env_n] = "MARU_WEB_TEST_BODY_LOG=1";
    env_n += 1;
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
    std.debug.print("v20m: ports O1={d} O2={d} O3={d} O4={d} O5={d} O6={d} host pid={d}\n", .{ ports[0], ports[1], ports[2], ports[3], ports[4], ports[5], host.pid });

    // 출처마다 워커를 깐다: O2 b=2, X2 b=3, O3 b=8 — C 가 한 번씩 연다.
    {
        try r.goO(tab_c, 1, "/g/p?b=2&n=1&k=c2");
        const ok2 = r.pumpTitle(tab_c, "ready", 20_000);
        var u: [256]u8 = undefined;
        try r.go(tab_c, try std.fmt.bufPrint(&u, "http://localhost:{d}/g/p?b=3&n=1&k=c3", .{ports[1]}));
        const ok3 = r.pumpTitle(tab_c, "ready", 20_000);
        try r.goO(tab_c, 2, "/g/p?b=8&n=1&k=c8");
        const ok8 = r.pumpTitle(tab_c, "ready", 20_000);
        try r.goO(tab_c, 0, "/g/p?b=1&n=1&k=c1");
        const ok1 = r.pumpTitle(tab_c, "ready", 20_000);
        try r.goO(tab_c, 0, "/blank");
        r.pump(500);
        std.debug.print("v20m: setup O1 {} O2 {} X2 {} O3 {}\n", .{ ok1, ok2, ok3, ok8 });
    }

    // ── 11 회차 ①: 3 초 안에 맨 위 출처를 여러 번 바꾼다 ──────────────────────────────────────────────────
    if (enabled("r11-nav")) {
        const on = recordOn(&r, tab_a);
        const log_at = logSize(stderr_path);
        const at = r.begins.items.len;
        const seq = [_]struct { host: []const u8, port_i: usize, b: u8 }{
            .{ .host = "127.0.0.1", .port_i = 0, .b = 1 }, .{ .host = "127.0.0.1", .port_i = 1, .b = 2 }, .{ .host = "localhost", .port_i = 1, .b = 3 },
            .{ .host = "127.0.0.1", .port_i = 0, .b = 1 }, .{ .host = "127.0.0.1", .port_i = 1, .b = 2 }, .{ .host = "127.0.0.1", .port_i = 0, .b = 1 },
            .{ .host = "localhost", .port_i = 1, .b = 3 }, .{ .host = "127.0.0.1", .port_i = 1, .b = 2 }, .{ .host = "127.0.0.1", .port_i = 0, .b = 1 },
        };
        var ready_n: usize = 0;
        var gaps: [16]i64 = @splat(0);
        var last = os.nowMs();
        for (seq, 0..) |s, i| {
            var u: [256]u8 = undefined;
            try r.go(tab_a, try std.fmt.bufPrint(&u, "http://{s}:{d}/g/p?b={d}&n=8&k=nv{d}_", .{ s.host, ports[s.port_i], s.b, i }));
            var tw: [32]u8 = undefined;
            if (r.pumpTitle(tab_a, std.fmt.bufPrint(&tw, "ready:nv{d}_", .{i}) catch "ready", 15_000)) ready_n += 1;
            const now = os.nowMs();
            gaps[i] = now - last;
            last = now;
        }
        r.pump(5000);
        const t = tally(&r, tab_a, at, "/g/x?k=nv");
        const log = readLog(gpa, stderr_path, log_at);
        var tb: [600]u8 = undefined;
        var gb: [200]u8 = undefined;
        var gn: usize = 0;
        for (gaps[0..seq.len]) |g| {
            const piece = std.fmt.bufPrint(gb[gn..], " {d}", .{g}) catch break;
            gn += piece.len;
        }
        // 마지막은 O1 — O2(b=2)·X2(b=3) 워커는 3 초 뒤 떼어 놀면 멈춰야 한다(F13).
        r.pump(3000);
        const x2 = try idleThenProbe(&r, tab_c, "127.0.0.1", ports[1], 2);
        const x3 = try idleThenProbe(&r, tab_c, "localhost", ports[1], 3);
        const log2 = readLog(gpa, stderr_path, log_at);
        report(on and ready_n == seq.len and t.wrong == 0 and x2.stopped and x3.stopped, "v20m-r11-nav", std.fmt.bufPrint(&detail, "9 top-origin changes O1→O2→X2→O1→O2→O1→X2→O2→O1 (ms per page:{s}) — ready {d}/9 · {s} || attaches keep=true own=true {d} · own=false {d} · keep=false {d} · retarget lines {d} · foreign-detach {d} (by end of idle {d}) · max live sessions ≈{d} || after: O2 SW {s} (boots {d}→{d}), X2 SW {s} (boots {d}→{d})", .{ gb[0..gn], ready_n, tallyLine(&t, &tb), count3(log, "sw-attached b=151", "keep=true", "own=true"), count3(log, "sw-attached b=151", "keep=true", "own=false"), count2(log, "sw-attached b=151", "keep=false"), countLines(log, "sw-retarget b=151"), countLines(log, "sw-foreign-detach b=151"), countLines(log2, "sw-foreign-detach b=151"), maxLive(log, "b=151 "), if (x2.stopped) "stopped" else "KEPT RUNNING", x2.before, x2.after, if (x3.stopped) "stopped" else "KEPT RUNNING", x3.before, x3.after }) catch "");
        recordOff(&r, tab_a);
        r.pump(500);
        try r.goO(tab_a, 0, "/blank");
        r.pump(500);
    }

    // ── 11 회차 ②: 남의 것으로 붙은 세션이 d ms 뒤 맨 위 출처의 것이 된다(3 초 시한 앞뒤) ─────────────────────────
    if (enabled("r11-retarget")) {
        const delays = [_]u32{ 300, 1500, 2600, 2900, 3000, 3100, 3400, 4500 };
        var line: [2400]u8 = undefined;
        var ln: usize = 0;
        var wrong: usize = 0;
        var keep_ok: usize = 0;
        for (delays, 0..) |d, i| {
            const on = recordOn(&r, tab_a);
            const la = logSize(stderr_path);
            var pb: [512]u8 = undefined;
            const v = os.nowMs();
            // A(O1)가 O2 iframe 을 품는다 — iframe 이 O2 에 새 워커(b=6, 판 v)를 띄운다 → 기록 중 뜬 iframe 출처 워커라 A 에 남의 것으로 붙는다.
            try r.goO(tab_a, 0, try std.fmt.bufPrint(&pb, "/g/p?b=1&n=0&if=http%3A%2F%2F127.0.0.1%3A{d}%2Fg%2Freg6%3Fv%3D{d}", .{ ports[1], v }));
            _ = r.pumpTitle(tab_a, "ready", 20_000);
            // 붙음 줄(b=6&v=…)을 기다린다.
            var vb: [64]u8 = undefined;
            const vneedle = std.fmt.bufPrint(&vb, "b=6&v={d}", .{v}) catch "";
            var seen_at: i64 = -1;
            const dl = os.nowMs() + 8000;
            while (os.nowMs() < dl) {
                r.pump(20);
                if (count2(readLog(gpa, stderr_path, la), "sw-attached b=151", vneedle) > 0) {
                    seen_at = os.nowMs();
                    break;
                }
            }
            // 붙은 뒤 d ms 에 A 가 그 출처(O2)의 `/g/s6/` 페이지로 — 그 워커가 다스린다.
            if (seen_at >= 0) {
                const el: u32 = @intCast(@max(os.nowMs() - seen_at, 0));
                if (d > el) r.pump(d - el);
            }
            const at = r.begins.items.len;
            var nb: [64]u8 = undefined;
            const k = std.fmt.bufPrint(&nb, "rt{d}_", .{i}) catch "";
            try r.goO(tab_a, 1, try std.fmt.bufPrint(&pb, "/g/s6/p?n=20&k={s}", .{k}));
            var tw: [32]u8 = undefined;
            const ready = r.pumpTitle(tab_a, std.fmt.bufPrint(&tw, "ready:{s}", .{k}) catch "ready", 20_000);
            r.pump(4000);
            var kn: [64]u8 = undefined;
            const t = tally(&r, tab_a, at, std.fmt.bufPrint(&kn, "/g/s6/x?k={s}", .{k}) catch k);
            wrong += t.wrong;
            const lg = readLog(gpa, stderr_path, la);
            var tb: [600]u8 = undefined;
            if (t.sw_own >= 18) keep_ok += 1;
            const piece = std.fmt.bufPrint(line[ln..], " [d={d} (attach seen {}, on {}, ready {}): {s} · attach b=6 own=false {d} own=true {d} · retarget {d} · foreign-detach {d}]", .{ d, seen_at >= 0, on, ready, tallyLine(&t, &tb), count3(lg, "sw-attached b=151", "own=false", "b=6&"), count3(lg, "sw-attached b=151", "own=true", "b=6&"), countLines(lg, "sw-retarget b=151"), countLines(lg, "sw-foreign-detach b=151") }) catch break;
            ln += piece.len;
            recordOff(&r, tab_a);
            r.pump(500);
            try r.goO(tab_a, 0, "/blank");
            r.pump(500);
        }
        report(wrong == 0, "v20m-r11-retarget", std.fmt.bufPrint(&detail, "foreign-attached iframe-origin SW, then the tab moves to that origin after d ms (bodies ≥18/20 in {d}/{d}):{s}", .{ keep_ok, delays.len, line[0..ln] }) catch "");
    }

    // ── 11 회차 ③: 떼기를 기다리는 3 초 동안 남의 출처 워커의 사건이 이 탭의 쏟아짐 밸브에 든다 ───────────────────────────
    if (enabled("r11-valve")) {
        var line: [1600]u8 = undefined;
        var ln: usize = 0;
        var paused_loop = false;
        for ([_]u8{ 0, 1 }, 0..) |lp, i| {
            const on = recordOn(&r, tab_a);
            const la = logSize(stderr_path);
            const at = r.begins.items.len;
            var pb: [512]u8 = undefined;
            const v = os.nowMs();
            try r.goO(tab_a, 0, try std.fmt.bufPrint(&pb, "/g/p?b=1&n=0&k=vl{d}_&if=http%3A%2F%2F127.0.0.1%3A{d}%2Fg%2Freg6l%3Fv%3D{d}%26loop%3D{d}", .{ i, ports[1], v, lp }));
            var tw: [32]u8 = undefined;
            const ready = r.pumpTitle(tab_a, std.fmt.bufPrint(&tw, "ready:vl{d}_", .{i}) catch "ready", 20_000);
            // 6 초 — 남의 세션은 3 초 뒤 떼어진다. 그 안에 밸브가 닫히는가.
            const t0 = os.nowMs();
            var paused_at: i64 = -1;
            while (os.nowMs() - t0 < 6000) {
                r.pump(100);
                if (paused_at < 0) if (r.states.get(tab_a)) |st| if (st == .paused) {
                    paused_at = os.nowMs() - t0;
                };
            }
            const lg = readLog(gpa, stderr_path, la);
            // 그 뒤 A 의 페이지 요청 10 개 — 멈췄으면 본문이 없다.
            const at2 = r.begins.items.len;
            _ = at;
            const ev = r.call(tab_a, "Runtime.evaluate", "{\"expression\":\"(async function(){for(var i=0;i<10;i++){await fetch('/g/x?k=vlafter'+i,{cache:'no-store'}).then(function(r){return r.text()})}return 1})()\",\"awaitPromise\":true}");
            r.pump(2500);
            const tt = tally(&r, tab_a, at2, "/g/x?k=vlafter");
            if (lp == 1 and paused_at >= 0) paused_loop = true;
            var tb: [600]u8 = undefined;
            const piece = std.fmt.bufPrint(line[ln..], " [{s} (on {}, ready {}): A paused at {d} ms · A attach own=false {d} · foreign-detach {d} · worker events for A ≈{d} · after: eval {s} · {s}]", .{ if (lp == 1) "iframe SW loops" else "control (iframe SW idle)", on, ready, paused_at, count3(lg, "sw-attached b=151", "keep=true", "own=false"), countLines(lg, "sw-foreign-detach b=151"), countLines(lg, "sw-ev b=151"), @tagName(ev.status), tallyLine(&tt, &tb) }) catch break;
            ln += piece.len;
            // 워커를 멈춘다(뒤 회차에 남지 않게).
            try r.goO(tab_c, 1, "/g/s6/stop");
            _ = r.pumpTitle(tab_c, "stopped", 10_000);
            try r.goO(tab_c, 0, "/blank");
            recordOff(&r, tab_a);
            r.pump(500);
            try r.goO(tab_a, 0, "/blank");
            r.pump(1000);
        }
        // 바라는 것(F13 「그 워커로는 본문을 잇지 않으니 잃는 것이 없다」): 남의 출처 워커의 사건은 이 탭의 기록을 멈추지 않는다.
        report(!paused_loop, "v20m-r11-valve", std.fmt.bufPrint(&detail, "A records at O1 with an O2 iframe that starts a new SW (foreign-attached to A for 3 s):{s}", .{line[0..ln]}) catch "");
    }

    // ── 12 회차: 몫을 낸 탭이 다른 출처로 옮긴다 ─────────────────────────────────────────────────────────
    if (enabled("r12-move")) {
        // A(첫 자리 — 지켜보기만)가 O2 의 워커로 끝나지 않는 fetch 200 개(서버 3 초씩, 연결 6 — 약 100 초 동안 줄 선다).
        const hs0 = hang_seen.load(.monotonic);
        try r.goO(tab_a, 1, "/g/p?b=2&n=0");
        _ = r.pumpTitle(tab_a, "ready", 20_000);
        const dsw_a0 = r.dropped_sw.get(tab_a) orelse 0;
        try r.goO(tab_a, 1, "/g/swhold?n=150&s=600");
        const held = r.pumpTitle(tab_a, "sheld", 10_000);
        r.pump(2000);
        const dsw_a1 = (r.dropped_sw.get(tab_a) orelse 0) - dsw_a0;
        // A 가 O1 로 옮긴다(빈 문서) — O2 워커의 fetch 는 이어진다.
        try r.goO(tab_a, 0, "/blank");
        r.pump(1000);
        // B(O1, 기록)가 제 워커(b=1)를 거쳐 30 번.
        const on_b = recordOn(&r, tab_b);
        const dsw_b0 = r.dropped_sw.get(tab_b) orelse 0;
        var at = r.begins.items.len;
        try r.goO(tab_b, 0, "/g/p?b=1&n=30&k=mvB");
        const ready_b = r.pumpTitle(tab_b, "ready", 25_000);
        r.pump(2500);
        const sw_b = swRecords(&r, tab_b, at, "k=mvB");
        const tB = tally(&r, tab_b, at, "/g/x?k=mvB");
        const dsw_b = (r.dropped_sw.get(tab_b) orelse 0) - dsw_b0;
        const dsw_a2 = (r.dropped_sw.get(tab_a) orelse 0) - dsw_a0 - dsw_a1;
        recordOff(&r, tab_b);
        // 대조: A 를 닫으면 B 가 첫 자리다.
        const t_close = os.nowMs();
        closeTab(&r, tab_a);
        at = r.begins.items.len;
        const on_b2 = recordOn(&r, tab_b);
        const dsw_b1 = r.dropped_sw.get(tab_b) orelse 0;
        try r.goO(tab_b, 0, "/g/p?b=1&n=30&k=mvC");
        const ready_c = r.pumpTitle(tab_b, "ready", 25_000);
        r.pump(2500);
        const sw_c = swRecords(&r, tab_b, at, "k=mvC");
        const tC = tally(&r, tab_b, at, "/g/x?k=mvC");
        const dsw_c = (r.dropped_sw.get(tab_b) orelse 0) - dsw_b1;
        recordOff(&r, tab_b);
        var tb: [600]u8 = undefined;
        var tc: [600]u8 = undefined;
        // F14a 의 약속: 다른 출처(O2)의 워커가 쥔 fetch 는 O1 의 서비스 워커 갈래 요청을 막지 않는다.
        report(held and on_b and ready_b and sw_b >= 30 and dsw_b == 0 and tB.wrong == 0 and tC.wrong == 0, "v20m-r12-move", std.fmt.bufPrint(&detail, "tab A (first watch slot) at O2 made its SW hold 200 hanging fetches (held {}, A's dropped_sw_inflight_cap +{d}), then moved to O1 /blank || tab B (O1, recording on {} ready {}): SW-branch records {d}/30 · B's dropped_sw_inflight_cap +{d} (A's +{d}) · {s} || control — A closed ({d} ms after): B again (on {} ready {}): SW-branch records {d}/30 · dropped +{d} · {s} · server hangs seen {d} open {d}", .{ held, dsw_a1, on_b, ready_b, sw_b, dsw_b, dsw_a2, tallyLine(&tB, &tb), os.nowMs() - t_close, on_b2, ready_c, sw_c, dsw_c, tallyLine(&tC, &tc), hang_seen.load(.monotonic), hang_open.load(.monotonic) }) catch "");
        try openTab(&r, tab_a);
        try r.goO(tab_b, 0, "/blank");
        // 줄 선 fetch 를 모두 풀어 끝낸다.
        hang_release.store(true, .monotonic);
        const deadline = os.nowMs() + 90_000;
        while (hang_seen.load(.monotonic) < hs0 + 150 and os.nowMs() < deadline) r.pump(500);
        while (hang_open.load(.monotonic) > 0 and os.nowMs() < deadline) r.pump(200);
        r.pump(2000);
        hang_release.store(false, .monotonic);
    }

    // ── 13 회차: iframe 이 워커를 잇달아 띄운다 — 떼기를 기다리는 남의 세션이 전체 64 를 채우는가 ────────────────────
    if (enabled("r13-flood")) {
        // 대조: B 가 O3(b=8)에서 기록.
        const la0 = logSize(stderr_path);
        _ = recordOn(&r, tab_b);
        var at = r.begins.items.len;
        try r.goO(tab_b, 2, "/g/p?b=8&n=20&k=fl0_");
        const ready0 = r.pumpTitle(tab_b, "ready", 20_000);
        r.pump(3000);
        const t0 = tally(&r, tab_b, at, "/g/x?k=fl0_");
        const lg0 = readLog(gpa, stderr_path, la0);
        recordOff(&r, tab_b);
        try r.goO(tab_b, 0, "/blank");
        r.pump(1000);
        // A(O1)가 기록하며 O2 iframe 이 워커를 잇달아 띄운다(200 ms 마다 5 개, 30 초).
        const la = logSize(stderr_path);
        const on_a = recordOn(&r, tab_a);
        var pb: [512]u8 = undefined;
        try r.goO(tab_a, 0, try std.fmt.bufPrint(&pb, "/g/p?b=1&n=0&if=http%3A%2F%2F127.0.0.1%3A{d}%2Fg%2Fregmany%3Fper%3D5%26every%3D200%26dur%3D30000", .{ports[1]}));
        _ = r.pumpTitle(tab_a, "ready", 20_000);
        r.pump(8000);
        const lga = readLog(gpa, stderr_path, la);
        const a_keep = count2(lga, "sw-attached b=151", "keep=true");
        const a_drop = count2(lga, "sw-attached b=151", "keep=false");
        const a_live = maxLive(lga, "b=151 ");
        // 그동안 B 가 O3 에서 기록한다.
        const lb = logSize(stderr_path);
        const on_b = recordOn(&r, tab_b);
        at = r.begins.items.len;
        try r.goO(tab_b, 2, "/g/p?b=8&n=20&k=fl1_");
        const ready1 = r.pumpTitle(tab_b, "ready", 20_000);
        r.pump(3000);
        const t1 = tally(&r, tab_b, at, "/g/x?k=fl1_");
        const lg1 = readLog(gpa, stderr_path, lb);
        recordOff(&r, tab_b);
        try r.goO(tab_b, 0, "/blank");
        // 다 끝난 뒤(30 초 + 5 초) 되찾는가.
        r.pump(25_000);
        const lga2 = readLog(gpa, stderr_path, la);
        recordOff(&r, tab_a);
        try r.goO(tab_a, 0, "/blank");
        r.pump(5000);
        const lr = logSize(stderr_path);
        _ = recordOn(&r, tab_b);
        at = r.begins.items.len;
        try r.goO(tab_b, 2, "/g/p?b=8&n=20&k=fl2_");
        const ready2 = r.pumpTitle(tab_b, "ready", 20_000);
        r.pump(3000);
        const t2 = tally(&r, tab_b, at, "/g/x?k=fl2_");
        const lg2 = readLog(gpa, stderr_path, lr);
        recordOff(&r, tab_b);
        try r.goO(tab_b, 0, "/blank");
        r.pump(1000);
        var tb0: [600]u8 = undefined;
        var tb1: [600]u8 = undefined;
        var tb2: [600]u8 = undefined;
        // F14c 의 약속: 한 탭이 세션 전체(64)를 다 쥐지 않는다 — B 는 제 워커를 붙여 본문을 잡는다. 재검증 7 차(N13): 남의 출처 세션은 탭마다 4 개로
        // 묶고 넘으면 세워 둔다 — B 의 붙음은 하나도 떼이지 않고 본문은 대조와 같은 만큼(대조의 아래 끝은 겹침 규칙 — 워커가 막 붙은 때 시작한
        // fetch 는 잃는다), A 의 곧 떼기(되풀이)는 30 초에 2 000 번 아래(전에는 16 741 번).
        const a_detach = count2(lga2, "sw-send b=151", "Target.detachFromTarget");
        report(on_a and on_b and t1.wrong == 0 and t0.wrong == 0 and t2.wrong == 0 and count2(lg1, "sw-attached b=152", "keep=true") >= 1 and count2(lg1, "sw-attached b=152", "keep=false") == 0 and t1.sw_own >= 10 and t1.sw_own + 3 >= t0.sw_own and a_detach < 2000, "v20m-r13-flood", std.fmt.bufPrint(&detail, "A detach commands during the flood {d} || control B (O3 b=8, ready {}): attach keep=true {d} keep=false {d} · {s} || A records (on {}) at O1 while its O2 iframe registers 5 SWs every 200 ms (unregistered after 3.5 s): first 8 s — A attaches keep=true {d} (own=false {d}) · keep=false {d} · foreign-detach {d} · max live ≈{d} · boots b=9 {d} || B records at O3 meanwhile (on {} ready {}): B attach keep=true {d} keep=false {d} · {s} || whole flood: A keep=true {d} keep=false {d} foreign-detach {d} max live ≈{d} || after flood: B (ready {}) attach keep=true {d} keep=false {d} · {s}", .{ a_detach, ready0, count2(lg0, "sw-attached b=152", "keep=true"), count2(lg0, "sw-attached b=152", "keep=false"), tallyLine(&t0, &tb0), on_a, a_keep, count3(lga, "sw-attached b=151", "keep=true", "own=false"), a_drop, countLines(lga, "sw-foreign-detach b=151"), a_live, boots[9].load(.monotonic), on_b, ready1, count2(lg1, "sw-attached b=152", "keep=true"), count2(lg1, "sw-attached b=152", "keep=false"), tallyLine(&t1, &tb1), count2(lga2, "sw-attached b=151", "keep=true"), count2(lga2, "sw-attached b=151", "keep=false"), countLines(lga2, "sw-foreign-detach b=151"), maxLive(lga2, "b=151 "), ready2, count2(lg2, "sw-attached b=152", "keep=true"), count2(lg2, "sw-attached b=152", "keep=false"), tallyLine(&t2, &tb2) }) catch "");
    }

    // ── 14 회차: 전체 512 를 채우고, 채운 탭들을 닫은 뒤 언제 되찾는가 ─────────────────────────────────────────────
    if (enabled("r14-cap512")) {
        const hogs = [_]u64{ 161, 162, 163, 164 };
        const hs1 = hang_seen.load(.monotonic);
        var held: usize = 0;
        for (hogs, 0..) |h, i| {
            try openTab(&r, h);
            var pb: [128]u8 = undefined;
            try r.goO(h, 2 + i, try std.fmt.bufPrint(&pb, "/g/p?b={d}&n=0", .{10 + i}));
            _ = r.pumpTitle(h, "ready", 20_000);
            try r.goO(h, 2 + i, "/g/swhold?n=150&s=600");
            if (r.pumpTitle(h, "sheld", 10_000)) held += 1;
        }
        r.pump(1500);
        var hog_drop: u64 = 0;
        for (hogs) |h| hog_drop += r.dropped_sw.get(h) orelse 0;
        // B(O1)가 기록 — 전체 512 가 찼다(문서대로 잃는다).
        _ = recordOn(&r, tab_b);
        var res: [3]struct { sw: usize, drop: u64, own: usize, wrong: usize, ready: bool, at_ms: i64 } = undefined;
        const t_start = os.nowMs();
        for (0..3) |phase| {
            if (phase == 1) {
                for (hogs) |h| closeTab(&r, h);
            }
            if (phase == 2) {
                // 닫힌 탭들의 워커가 쥔 fetch 를 서버가 모두 끝낸다.
                hang_release.store(true, .monotonic);
                const deadline = os.nowMs() + 120_000;
                while (hang_seen.load(.monotonic) < hs1 + 600 and os.nowMs() < deadline) r.pump(500);
                while (hang_open.load(.monotonic) > 0 and os.nowMs() < deadline) r.pump(200);
                r.pump(2000);
                hang_release.store(false, .monotonic);
            }
            if (phase == 1) r.pump(5000);
            const d0 = r.dropped_sw.get(tab_b) orelse 0;
            const at = r.begins.items.len;
            var pb: [64]u8 = undefined;
            var kb: [32]u8 = undefined;
            const k = std.fmt.bufPrint(&kb, "c5{d}_", .{phase}) catch "";
            try r.goO(tab_b, 0, try std.fmt.bufPrint(&pb, "/g/p?b=1&n=20&k={s}", .{k}));
            const ready = r.pumpTitle(tab_b, "ready", 25_000);
            r.pump(2500);
            var kn: [48]u8 = undefined;
            const t = tally(&r, tab_b, at, std.fmt.bufPrint(&kn, "/g/x?k={s}", .{k}) catch k);
            res[phase] = .{ .sw = swRecords(&r, tab_b, at, k), .drop = (r.dropped_sw.get(tab_b) orelse 0) - d0, .own = t.sw_own, .wrong = t.wrong, .ready = ready, .at_ms = os.nowMs() - t_start };
        }
        recordOff(&r, tab_b);
        try r.goO(tab_b, 0, "/blank");
        r.pump(500);
        // 재검증 7 차(N14): 그 출처를 보이는 탭이 닫히면 그 워커가 쥔 fetch 는 몫에서 놓는다 — 닫은 직후부터 B 의 20 이 적힌다(전에는 그 fetch 가
        // 끝날 때까지 전체 512 가 찬 채였다).
        report(res[1].sw >= 20 and res[2].sw >= 20 and res[0].wrong + res[1].wrong + res[2].wrong == 0, "v20m-r14-cap512", std.fmt.bufPrint(&detail, "4 hog tabs (O3..O6) each make their SW hold 200 hanging fetches (held {d}/4, hogs' dropped_sw_inflight_cap {d}) || B (O1, recording) 20 SW fetches: full 512 — SW records {d}/20 dropped +{d} own body {d} (ready {}, t+{d} ms) || right after closing the 4 hog tabs — SW records {d}/20 dropped +{d} own body {d} (ready {}, t+{d} ms) || after all hanging fetches ended (server seen {d}) — SW records {d}/20 dropped +{d} own body {d} (ready {}, t+{d} ms)", .{ held, hog_drop, res[0].sw, res[0].drop, res[0].own, res[0].ready, res[0].at_ms, res[1].sw, res[1].drop, res[1].own, res[1].ready, res[1].at_ms, hang_seen.load(.monotonic), res[2].sw, res[2].drop, res[2].own, res[2].ready, res[2].at_ms }) catch "");
    }

    // ── 재검증 8 차 기준 · v20n-B R12-hop(재검증 7 차 검증 12 회차 — D-v20n-1): 한 탭이 출처 여덟을 차례로 옮기며 각 워커에 끝나지 않는 fetch 를 쥐게
    // 한다 — 떠난 출처의 요청이 몫에 남아 다른 탭(B, O1)의 서비스 워커 갈래 기록을 막는가. 7 차는 놓은 수 512 뒤로 놓지 않아 B 0/20(2/2 실패),
    // 8 차는 언제나 놓고 자리가 차면 가장 오래된 놓은 요청을 비운다.
    if (enabled("v20n-r12-hop")) {
        const hs0 = hang_seen.load(.monotonic);
        // 대조: B(O1)가 기록하며 20 번 — 몫이 비었을 때.
        _ = recordOn(&r, tab_b);
        var at = r.begins.items.len;
        const d00 = r.dropped_sw.get(tab_b) orelse 0;
        try r.goO(tab_b, 0, "/g/p?b=1&n=20&k=hpc_");
        const ready0 = r.pumpTitle(tab_b, "ready", 25_000);
        r.pump(2000);
        const sw0 = swRecords(&r, tab_b, at, "k=hpc_");
        const dr0 = (r.dropped_sw.get(tab_b) orelse 0) - d00;
        recordOff(&r, tab_b);
        try r.goO(tab_b, 0, "/blank");
        r.pump(500);
        // A 가 출처 여덟(O3..O6, localhost:P3..P6)을 옮겨 다닌다 — 출처마다 워커를 깔고 끝나지 않는 fetch 150(몫 128 + 넘김 22).
        var held: usize = 0;
        var hops: usize = 0;
        for (0..8) |i| {
            const port = ports[2 + (i % 4)];
            const host_name: []const u8 = if (i < 4) "127.0.0.1" else "localhost";
            var u: [256]u8 = undefined;
            try r.go(tab_a, try std.fmt.bufPrint(&u, "http://{s}:{d}/g/p?b={d}&n=0", .{ host_name, port, 10 + (i % 4) }));
            _ = r.pumpTitle(tab_a, "ready", 20_000);
            try r.go(tab_a, try std.fmt.bufPrint(&u, "http://{s}:{d}/g/swhold?n=150&s=600", .{ host_name, port }));
            if (r.pumpTitle(tab_a, "sheld", 10_000)) held += 1;
            hops += 1;
        }
        try r.goO(tab_a, 0, "/blank"); // 마지막 출처도 떠난다
        r.pump(1500);
        // B 가 다시 기록하며 20 번.
        _ = recordOn(&r, tab_b);
        at = r.begins.items.len;
        const d10 = r.dropped_sw.get(tab_b) orelse 0;
        try r.goO(tab_b, 0, "/g/p?b=1&n=20&k=hpa_");
        const ready1 = r.pumpTitle(tab_b, "ready", 25_000);
        r.pump(2000);
        const sw1 = swRecords(&r, tab_b, at, "k=hpa_");
        const dr1 = (r.dropped_sw.get(tab_b) orelse 0) - d10;
        const t1 = tally(&r, tab_b, at, "/g/x?k=hpa_");
        recordOff(&r, tab_b);
        try r.goO(tab_b, 0, "/blank");
        var tb: [600]u8 = undefined;
        // 바라는 것(N14): 어느 탭도 보이지 않는 출처의 워커가 쥔 fetch 는 B 의 서비스 워커 갈래 요청을 막지 않는다.
        report(ready0 and sw0 >= 20 and ready1 and sw1 >= 20 and dr1 == 0 and t1.wrong == 0, "v20n-r12-hop", std.fmt.bufPrint(&detail, "control B (O1): SW records {d}/20 dropped +{d} (ready {}) || tab A hopped {d} origins, each SW holding 150 hanging fetches (held {d}/8), then left || B (O1) again: SW records {d}/20 · dropped_sw_inflight_cap +{d} (ready {}) · {s} · server hangs seen {d}", .{ sw0, dr0, ready0, hops, held, sw1, dr1, ready1, tallyLine(&t1, &tb), hang_seen.load(.monotonic) - hs0 }) catch "");
        // 매달린 fetch 를 모두 끝낸다.
        hang_release.store(true, .monotonic);
        const deadline = os.nowMs() + 120_000;
        while (hang_open.load(.monotonic) > 0 and os.nowMs() < deadline) r.pump(300);
        r.pump(3000);
        hang_release.store(false, .monotonic);
    }
    if (enabled("v20o-r12rec")) {
        // 재검증 9 차(검증 v20o 3 회차 탐침 → 기준): v20n-r12-hop 를 A 가 **기록하며** 아홉 출처로 — A 가 떠난 출처의 매달린 fetch(시작을 보냈다)는 놓은 요청이 되고, 자리
        // 1 024 가 차면 가장 오래된 것부터 비워(`evictOrphan`) A 의 표에 잃은 것으로 알린다. 그 뒤 매달린 fetch 를 모두 풀어(비운 요청의 뒤 기록은
        // 보내지 않는다) A 의 기록마다: 틀린 본문 0, 끝은 하나(둘 이상 없음), CEF 가 끝냈는데 본문의 끝이 없는 기록 0. B 는 그 뒤 20/20.
        const hs0 = hang_seen.load(.monotonic);
        _ = recordOn(&r, tab_a);
        const at_a = r.begins.items.len;
        var held: usize = 0;
        var hops: usize = 0;
        const n_hops: usize = if (std.c.getenv("V20O_HOPS")) |v| (std.fmt.parseInt(usize, std.mem.span(v), 10) catch 9) else 9;
        for (0..n_hops) |i| {
            const port = ports[2 + (i % 4)];
            const host_name: []const u8 = if ((i / 4) % 2 == 0) "127.0.0.1" else "localhost";
            var u: [256]u8 = undefined;
            try r.go(tab_a, try std.fmt.bufPrint(&u, "http://{s}:{d}/g/p?b={d}&n=0", .{ host_name, port, 10 + (i % 4) }));
            _ = r.pumpTitle(tab_a, "ready", 20_000);
            try r.go(tab_a, try std.fmt.bufPrint(&u, "http://{s}:{d}/g/swhold?n=150&s=600", .{ host_name, port }));
            if (r.pumpTitle(tab_a, "sheld", 10_000)) held += 1;
            hops += 1;
        }
        try r.goO(tab_a, 0, "/blank");
        r.pump(1500);
        _ = recordOn(&r, tab_b);
        const at = r.begins.items.len;
        const d10 = r.dropped_sw.get(tab_b) orelse 0;
        try r.goO(tab_b, 0, "/g/p?b=1&n=20&k=hpr_");
        const ready1 = r.pumpTitle(tab_b, "ready", 25_000);
        r.pump(2000);
        const sw1 = swRecords(&r, tab_b, at, "k=hpr_");
        const dr1 = (r.dropped_sw.get(tab_b) orelse 0) - d10;
        const t1 = tally(&r, tab_b, at, "/g/x?k=hpr_");
        recordOff(&r, tab_b);
        try r.goO(tab_b, 0, "/blank");
        // 매달린 fetch 를 모두 끝낸다 — A 는 아직 기록한다.
        hang_release.store(true, .monotonic);
        const deadline = os.nowMs() + 120_000;
        while (hang_open.load(.monotonic) > 0 and os.nowMs() < deadline) r.pump(300);
        r.pump(12_000); // 시한(끝 없는 기록 10 초)까지
        hang_release.store(false, .monotonic);
        const ta = tally(&r, tab_a, at_a, "/g/hang");
        var multi: usize = 0;
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer seen.deinit(r.gpa);
        for (r.begins.items[at_a..]) |b| if (b.browser == tab_a and std.mem.indexOf(u8, b.url, "/g/hang") != null) {
            if (seen.contains(b.request)) continue;
            seen.put(r.gpa, b.request, {}) catch {};
            if (r.body(tab_a, b.request).ends > 1) multi += 1;
        };
        recordOff(&r, tab_a);
        var tb: [600]u8 = undefined;
        var ta_l: [600]u8 = undefined;
        report(ready1 and sw1 >= 20 and dr1 == 0 and t1.wrong == 0 and ta.wrong == 0 and multi == 0 and ta.no_end == 0, "v20o-r12rec", std.fmt.bufPrint(&detail, "tab A (recording) hopped {d} origins (held {d}) · A's /g/hang: {s} · several ends {d} || B after: SW records {d}/20 · dropped +{d} · {s} · hangs seen {d}", .{ hops, held, tallyLine(&ta, &ta_l), multi, sw1, dr1, tallyLine(&t1, &tb), hang_seen.load(.monotonic) - hs0 }) catch "");
    }

    // ── 15 회차: getTargetInfo 의 인자 꼴 ──────────────────────────────────────────────────────────────
    if (enabled("r15-forms")) {
        try r.goO(tab_a, 0, "/g/p?b=1&n=0&k=secretA");
        _ = r.pumpTitle(tab_a, "ready", 20_000);
        // declared 0 = 조각 길이의 합(크기 속이기 둘만 따로 — 그 둘은 마지막에 탭 C 로: 덜 보낸 호출은 시한까지 자리를 쥔다).
        const Case = struct { label: []const u8, declared: u32, chunks: []const []const u8, want_ok: bool };
        const cases = [_]Case{
            .{ .label = "none", .declared = 0, .chunks = &.{}, .want_ok = true },
            .{ .label = "{}", .declared = 2, .chunks = &.{"{}"}, .want_ok = true },
            .{ .label = "ws{ }ws", .declared = 9, .chunks = &.{" \t{ \n }\r "}, .want_ok = true },
            .{ .label = "{} in 2 chunks", .declared = 2, .chunks = &.{ "{", "}" }, .want_ok = true },
            .{ .label = "64B pad", .declared = 64, .chunks = &.{"{" ++ @import("array_repeat").repeat(" ", 62) ++ "}"}, .want_ok = true },
            .{ .label = "65B pad", .declared = 65, .chunks = &.{"{" ++ @import("array_repeat").repeat(" ", 63) ++ "}"}, .want_ok = false },
            .{ .label = "targetId", .declared = 18, .chunks = &.{"{\"targetId\":\"AB\"}"}, .want_ok = false },
            .{ .label = "dup key", .declared = 33, .chunks = &.{"{\"targetId\":\"A\",\"targetId\":\"B\"}"}, .want_ok = false },
            .{ .label = "\\u escape", .declared = 23, .chunks = &.{"{\"\\u0074argetId\":\"AB\"}"}, .want_ok = false },
            .{ .label = "truncated", .declared = 13, .chunks = &.{"{\"targetId\":"}, .want_ok = false },
            .{ .label = "{} then targetId chunk", .declared = 20, .chunks = &.{ "{}", "{\"targetId\":\"A\"}" }, .want_ok = false },
            .{ .label = "null", .declared = 4, .chunks = &.{"null"}, .want_ok = false },
            .{ .label = "[]", .declared = 2, .chunks = &.{"[]"}, .want_ok = false },
            .{ .label = "{}{}", .declared = 4, .chunks = &.{"{}{}"}, .want_ok = false },
            .{ .label = "{\"\":1}", .declared = 6, .chunks = &.{"{\"\":1}"}, .want_ok = false },
            .{ .label = "BOM{}", .declared = 5, .chunks = &.{"\xEF\xBB\xBF{}"}, .want_ok = false },
            .{ .label = "NBSP{}", .declared = 4, .chunks = &.{"\xC2\xA0{}"}, .want_ok = false },
            .{ .label = "{}//c", .declared = 5, .chunks = &.{"{}//c"}, .want_ok = false },
            .{ .label = "declared 2 sent 18", .declared = 2, .chunks = &.{"{\"targetId\":\"AB\"}"}, .want_ok = false },
            .{ .label = "declared 18 sent 2", .declared = 18, .chunks = &.{"{}"}, .want_ok = false },
        };
        var line: [3000]u8 = undefined;
        var ln: usize = 0;
        var bad: usize = 0;
        var leak: usize = 0;
        for (cases) |cs| {
            var sum: u32 = 0;
            for (cs.chunks) |ch| sum += @intCast(ch.len);
            const lie = std.mem.startsWith(u8, cs.label, "declared");
            const who: u64 = if (lie) tab_c else tab_b;
            const x = r.callRaw(who, "Target.getTargetInfo", if (lie) cs.declared else sum, cs.chunks);
            const ok = x.answered and x.status == .ok;
            if (ok != cs.want_ok) bad += 1;
            if (std.mem.indexOf(u8, x.data, "secretA") != null) leak += 1;
            const piece = std.fmt.bufPrint(line[ln..], " [{s}: {s}{s}]", .{ cs.label, @tagName(x.status), if (ok != cs.want_ok) " ← UNEXPECTED" else "" }) catch break;
            ln += piece.len;
        }
        // 다른 Target 메서드(대소문자·끝 공백은 wire 가 막는다).
        for ([_][]const u8{ "Target.getTargets", "Target.activateTarget", "Target.getTargetInfoX", "target.getTargets" }) |m| {
            const x = r.call(tab_b, m, "{}");
            const piece = std.fmt.bufPrint(line[ln..], " [{s}: {s}]", .{ m, @tagName(x.status) }) catch break;
            ln += piece.len;
            if (std.mem.indexOf(u8, x.data, "secretA") != null) leak += 1;
        }
        const alive = hostAlive(&r);
        report(bad == 0 and leak == 0 and alive, "v20m-r15-forms", std.fmt.bufPrint(&detail, "Target.getTargetInfo param forms from tab B (tab A shows ?k=secretA): unexpected {d} · A's url leaked {d} · host alive {} ||{s}", .{ bad, leak, alive, line[0..ln] }) catch "");
        try r.goO(tab_a, 0, "/blank");
        r.pump(500);
    }

    // ── 19 회차: 큰 본문을 넘기는 동안 판정자가 읽지 않는다 ─────────────────────────────────────────────────────
    if (enabled("r19-big") or enabled("r19-bigc")) {
        r.keep_data = false;
        const on = recordOn(&r, tab_a);
        const rss0 = psRss(host.pid);
        const at = r.begins.items.len;
        try r.goO(tab_a, 0, "/g/bigp?n=30&sz=900000&k=bgA");
        // 판정자가 10 초 동안 알림을 읽지 않는다(관이 찬다). 대조(`r19-bigc`)는 읽는다.
        if (enabled("r19-bigc")) r.pump(10_000) else os.sleepMs(10_000);
        const rss1 = psRss(host.pid);
        var rss: [12]u64 = @splat(0);
        const ready = r.pumpTitle(tab_a, "ready", 60_000);
        for (&rss) |*x| {
            r.pump(1000);
            x.* = psRss(host.pid);
        }
        const tA = tally(&r, tab_a, at, "/g/big?sz=900000&k=bgA");
        const at2 = r.begins.items.len;
        try r.goO(tab_a, 0, "/g/bigp?n=10&sz=3000000&k=bgB");
        const ready2 = r.pumpTitle(tab_a, "ready", 60_000);
        r.pump(5000);
        const tB = tally(&r, tab_a, at2, "/g/big?sz=3000000&k=bgB");
        const rss2 = psRss(host.pid);
        recordOff(&r, tab_a);
        try r.goO(tab_a, 0, "/blank");
        r.pump(3000);
        const rss3 = psRss(host.pid);
        const alive = hostAlive(&r);
        var tb: [600]u8 = undefined;
        var tc: [600]u8 = undefined;
        var rb: [300]u8 = undefined;
        var rn: usize = 0;
        for (rss) |v| {
            const piece = std.fmt.bufPrint(rb[rn..], " {d}", .{v / 1024}) catch break;
            rn += piece.len;
        }
        report(on and alive and tA.wrong == 0 and tB.wrong == 0 and tA.held == 0, if (enabled("r19-bigc")) "v20m-r19-bigc" else "v20m-r19-big", std.fmt.bufPrint(&detail, "30 × 0.9 MB through the SW (judge stalls 10 s unless bigc) (ready {}): {s} || 10 × 3 MB (ready {}): {s} || body bytes received {d} MiB || host RSS MiB: before {d} · after 10 s unread {d} · then every 1 s:{s} · after 3 MB {d} · after off {d} · alive {}", .{ ready, tallyLine(&tA, &tb), ready2, tallyLine(&tB, &tc), r.big_bytes >> 20, rss0 / 1024, rss1 / 1024, rb[0..rn], rss2 / 1024, rss3 / 1024, alive }) catch "");
        r.keep_data = true;
    }

    host.send(.shutdown) catch {};
    host_alive = false;
    const code = host.wait(wait_ms);
    std.debug.print("v20m: host exit {?d}\n", .{code});
}
