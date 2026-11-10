//! W9d② 재검증 12 차 판정(`--review-body-swwait`, 고른 항목만 `SWWAIT_ONLY=first,restart,…` — docs/plans/web-osr-backend.md 「재검증 12 차」).
//! 새로 뜨는 워커를 멈춰 붙이는 길(`Target.setAutoAttach{waitForDebuggerOnStart:true}` — 놓기는 그 세션의 `Network.enable` 답 뒤)이 워커를 걸리게
//! 하지 않는지, 시작을 얼마나 늦추는지, 다시 뜬 워커의 W 시작 사건을 잃지 않는지를 실제 CEF 로 잰다. 판정자가 maru 역할로 탭 셋(기록하는 A·C,
//! 기록하지 않는 B)을 연다. 페이지의 함수를 DevTools `Runtime.evaluate`(에이전트 길과 같은 `devtools_call`)로 불러 시각(ms — 페이지의
//! `performance.now`)을 받는다. 각 꼴은 `SWWAIT_ROUNDS`(기본 20) 판.
//!   swwait-first      새 범위의 서비스 워커를 깐다(register → activated → 범위 안 iframe 의 fetch) — 기록하는 A·기록하지 않는 B·기록을 끈 A
//!   swwait-restart-pre   기록 앞에 깐 워커를 멈추고(`ServiceWorker.stopAllWorkers` — 기록하지 않는 B 에서) 범위 안 fetch 로 다시 띄운다
//!   swwait-restart-rec   기록 중에 깐 워커를 같은 꼴로 — 다시 뜬 워커가 시작 사건을 잃지 않는지(host 로그 — `swwait_d.py`)
//!   swwait-update     같은 등록의 스크립트를 바꿔 `update()` → 새 버전 activated
//!   swwait-tabs       기록하는 탭 둘(A·C)이 같은 출처를 볼 때 새 워커·다시 뜸
//!   swwait-xo         다른 출처(localhost) iframe 의 서비스 워커(깔기·다시 뜸)와 그 iframe 의 전용 워커
//!   swwait-dw         전용 워커·그 안의 전용 워커
//!   swwait-shw        공유 워커
//!   swwait-agent      에이전트 DevTools 호출이 겹친다(`Runtime.runIfWaitingForDebugger`·`Target.setAutoAttach` 막힘·`ServiceWorker.stopAllWorkers`)
//!   swwait-offrace    워커를 깔자마자 기록을 끈다(놓기 앞에 떼기·관찰자 놓기가 겹친다)
//!   swwait-navrace    느린 스크립트의 SW 를 깔자마자 다른 출처로 옮긴다(Chromium 이 그 세션을 놓기 답 앞에 뗀다 — 건지기)
//!   swwait-closerace  같은 꼴에서 기록하는 탭을 닫는다(건지기 — 다른 탭에서)
//!   swwait-keepalive  재검증 12 차(⑩′): 다녀간 출처를 떠나 40 초 뒤 돌아온다 — 붙여 둔 세션이 SW 를 살려 둔다(끈 대조는 멈췄다 다시 뜸)
//!   swwait-keepmem    출처 스물을 다녀간다 — helper RSS·몫(탭 16)으로 뗀 출처·붙여 둔 출처로 돌아올 때의 boot
//! 판마다 시한(8 초) 안에 끝나지 않으면 「걸림」 이다. 판정: 걸림 0. 시각(중앙·p99)은 detail 에만(`MARU_WEB_SW_WAIT=0` 대조와 견주는 것은
//! 판정자 밖 — 계획 「재검증 12 차」 PHASE0).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const tab_a: u64 = 151;
const tab_b: u64 = 152;
const tab_c: u64 = 153;
/// 닫힘이 겹치는 판의 탭(판마다 새로 연다).
const tab_d0: u64 = 160;
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
extern "c" fn mach_absolute_time() u64;
const Timebase = extern struct { numer: u32, denom: u32 };
extern "c" fn mach_timebase_info(info: *Timebase) c_int;

fn machUs() i64 {
    var tb: Timebase = undefined;
    _ = mach_timebase_info(&tb);
    return @intCast(@as(u128, mach_absolute_time()) * tb.numer / tb.denom / 1000);
}

var port: u16 = 0;
var counter = std.atomic.Value(u64).init(1);
var update_n = std.atomic.Value(u64).init(1);
var boots = std.atomic.Value(u64).init(0);

const FILE = opaque {};
extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fgets(buf: [*]u8, n: c_int, f: *FILE) ?[*]u8;
extern "c" fn pclose(f: *FILE) c_int;

/// 재검증 12 차(`keepmem`): 출처를 여럿 만들려고 더 여는 서버(포트마다 다른 출처).
var extra_ports: [128]u16 = @splat(0);

fn startServer() !void {
    port = try listenOn();
}

/// host 의 자식(`maru-web-helper` — 렌더러·GPU·네트워크 프로세스)의 RSS 합(KiB)과 수.
fn helperRss(host_pid: c_int) struct { kb: u64, n: u64 } {
    var cb: [160]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&cb, "ps -A -o pid=,ppid=,rss= | awk '$2=={d}{{s+=$3;n+=1}} END{{print s+0, n+0}}'", .{host_pid}, 0) catch return .{ .kb = 0, .n = 0 };
    const f = popen(cmd, "r") orelse return .{ .kb = 0, .n = 0 };
    defer _ = pclose(f);
    var line: [96]u8 = undefined;
    _ = fgets(&line, line.len, f) orelse return .{ .kb = 0, .n = 0 };
    var it = std.mem.tokenizeAny(u8, std.mem.sliceTo(&line, 0), " \n\t");
    const a = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    const b = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    return .{ .kb = a, .n = b };
}

fn listenOn() !u16 {
    const fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
    if (listen(fd, 1024) != 0) return error.ListenFailed;
    var len: u32 = @sizeOf(SockaddrIn);
    if (getsockname(fd, &addr, &len) != 0) return error.SocketFailed;
    const t = try std.Thread.spawn(.{}, acceptLoop, .{fd});
    t.detach();
    return std.mem.bigToNative(u16, addr.port);
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

fn reply(conn: c_int, ctype: []const u8, body: []const u8) void {
    var hb: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ ctype, body.len }) catch return;
    writeAll(conn, head);
    writeAll(conn, body);
}

const html = "text/html; charset=utf-8";
const js = "text/javascript";

/// 서비스 워커: 시작할 때마다(스크립트 평가 중) `/sww/boot` 를 부르고(그 W 의 시작 사건이 보이는가 — 다시 뜬 워커의 눈먼 때), 범위 안 요청은
/// 그대로 넘긴다.
const sw_js = "fetch('/sww/boot?t='+Date.now(),{cache:'no-store'}).catch(function(){});" ++
    "self.addEventListener('install',function(){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
    "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(u.pathname.indexOf('/boot')>=0)return;e.respondWith(fetch(e.request))});";
/// 다른 출처 iframe 의 워커(같은 꼴 — 다른 출처의 boot).
const dw_js = "fetch('/sww/x?k=dw',{cache:'no-store'}).then(function(r){return r.text()}).then(function(){postMessage('up')}).catch(function(){postMessage('up')});";
const dw_outer_js = "var w=new Worker('/sww/dw2.js');w.onmessage=function(e){postMessage('up2')};postMessage('up');";
const dw2_js = "postMessage('in');";
const shw_js = "onconnect=function(e){e.ports[0].postMessage('up')};";

/// 페이지 함수(판정자가 `Runtime.evaluate` 로 부른다 — 값은 JSON 글).
const lib_js = "function S(ms){return new Promise(function(r){setTimeout(r,ms)})}" ++
    "function T(p,ms){return Promise.race([p,S(ms).then(function(){throw new Error('timeout')})])}" ++
    "function act(w){return new Promise(function(res){if(w.state=='activated')return res(w);w.addEventListener('statechange',function(){if(w.state=='activated')res(w)})})}" ++
    "function frame(src){var f=document.createElement('iframe');return new Promise(function(res){f.onload=function(){res(f)};f.src=src;document.body.appendChild(f)})}" ++
    "function R(o){return JSON.stringify(o)}" ++
    // 새 범위 워커: register → activated → 범위 안 iframe(다스린다) → 그 iframe 의 fetch.
    "async function first(i,slow){var t0=performance.now();try{var reg=await T(navigator.serviceWorker.register('/sww/sw.js?v=f'+i+(slow?'&slow=1':''),{scope:'/sww/f'+i+'/'}),8000);" ++
    "await T(act(reg.installing||reg.waiting||reg.active),8000);var t1=performance.now();var f=await T(frame('/sww/f'+i+'/frame'),8000);var t2=performance.now();" ++
    "var x=await T(f.contentWindow.fetch('/sww/f'+i+'/x?k=f'+i,{cache:'no-store'}).then(function(r){return r.text()}),8000);var t3=performance.now();" ++
    "var ctl=!!f.contentWindow.navigator.serviceWorker.controller;f.remove();await reg.unregister();return R({ok:x.indexOf('\"n\"')>=0,ctl:ctl,act:t1-t0,frame:t2-t1,fetch:t3-t2,total:t3-t0})}" ++
    "catch(e){return R({ok:false,err:String(e),total:performance.now()-t0})}}" ++
    // 다른 탭이 깔다 닫힌 등록 — 그 버전이 activated 에 닿고 범위 안 iframe 의 fetch 가 되는가(멈춘 채 남지 않았나).
    "async function late(i){var t0=performance.now();try{var reg=null;for(var k=0;k<80&&!reg;k++){reg=await navigator.serviceWorker.getRegistration('/sww/f'+i+'/');if(!reg)await S(50)}" ++
    "if(!reg)return R({ok:true,none:true,total:performance.now()-t0});var w=reg.installing||reg.waiting||reg.active;var again=!w;" ++
    // 닫힘이 깔기를 끊었으면(버전 없음) 같은 범위를 다시 깐다 — 그 등록이 영영 멈춘 채가 아닌지.
    "if(again){reg=await T(navigator.serviceWorker.register('/sww/sw.js?v=f'+i,{scope:'/sww/f'+i+'/'}),8000);w=reg.installing||reg.waiting||reg.active}await T(act(w),8000);var f=await T(frame('/sww/f'+i+'/frame'),8000);" ++
    "var x=await T(f.contentWindow.fetch('/sww/f'+i+'/x?k=l'+i,{cache:'no-store'}).then(function(r){return r.text()}),8000);f.remove();await reg.unregister();" ++
    "return R({ok:x.indexOf('\"n\"')>=0,again:again,total:performance.now()-t0})}catch(e){return R({ok:false,err:String(e),total:performance.now()-t0})}}" ++
    // 범위 안 fetch(다스리는 워커가 멈췄으면 다시 띄운다).
    "async function hit(k){var t0=performance.now();try{var x=await T(fetch('/sww/'+k,{cache:'no-store'}).then(function(r){return r.text()}),8000);" ++
    "return R({ok:x.indexOf('\"n\"')>=0,ctl:!!navigator.serviceWorker.controller,total:performance.now()-t0})}catch(e){return R({ok:false,err:String(e),total:performance.now()-t0})}}" ++
    // 같은 등록의 새 버전.
    "async function upd(){var t0=performance.now();try{var reg=await navigator.serviceWorker.getRegistration();var p=new Promise(function(res){reg.addEventListener('updatefound',function(){res(reg.installing)})});" ++
    "await T(reg.update(),8000);var w=await T(p,8000);await T(act(w),8000);var t1=performance.now();var x=await T(fetch('/sww/u/x?k=u',{cache:'no-store'}).then(function(r){return r.text()}),8000);" ++
    "return R({ok:x.indexOf('\"n\"')>=0,act:t1-t0,total:performance.now()-t0})}catch(e){return R({ok:false,err:String(e),total:performance.now()-t0})}}" ++
    // 다른 출처 iframe(그 iframe 이 제 워커를 깔고 범위 안 fetch·전용 워커를 한 뒤 알린다).
    "async function xo(i){var t0=performance.now();try{var got=new Promise(function(res){window.addEventListener('message',function h(e){if(e.data&&e.data.xo){window.removeEventListener('message',h);res(e.data)}})});" ++
    "var f=await T(frame('http://localhost:'+PORT+'/sww/xo/i?i='+i),8000);var d=await T(got,8000);f.remove();return R({ok:d.ok,ctl:d.ctl,sw:d.sw,dw:d.dw,total:performance.now()-t0})}catch(e){return R({ok:false,err:String(e),total:performance.now()-t0})}}" ++
    "function wmsg(w,want){return new Promise(function(res){var seen={};w.onmessage=function(e){seen[e.data]=1;if(want.every(function(k){return seen[k]}))res()}})}" ++
    "async function dw(){var t0=performance.now();try{var w=new Worker('/sww/dw.js');await T(wmsg(w,['up']),8000);var t1=performance.now();w.terminate();" ++
    "var o=new Worker('/sww/dwo.js');await T(wmsg(o,['up','up2']),8000);o.terminate();return R({ok:true,dw:t1-t0,total:performance.now()-t0})}catch(e){return R({ok:false,err:String(e),total:performance.now()-t0})}}" ++
    "async function shw(i){var t0=performance.now();try{var s=new SharedWorker('/sww/shw.js?i='+i);var p=new Promise(function(res){s.port.onmessage=function(){res()}});s.port.start();await T(p,8000);s.port.close();" ++
    "return R({ok:true,total:performance.now()-t0})}catch(e){return R({ok:false,err:String(e),total:performance.now()-t0})}}";

fn page(conn: c_int, title: []const u8, body_js: []const u8) void {
    var b: [16 * 1024]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "<!doctype html><title>{s}</title><script>var PORT={d};{s}{s}</script>{s}", .{ title, port, lib_js, body_js, title }) catch return;
    reply(conn, html, s);
}

/// 범위 `scope` 의 워커를 깔고 다스릴 때까지 다시 불러온다 — 다스리면 제목을 `ready`.
fn regPage(conn: c_int, scope: []const u8) void {
    var b: [600]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "navigator.serviceWorker.register('{s}sw.js',{{scope:'{s}'}}).then(function(){{return navigator.serviceWorker.ready}}).then(function(){{" ++
        "if(!navigator.serviceWorker.controller){{setTimeout(function(){{location.reload()}},300);return}}document.title='ready'}});", .{ scope, scope }) catch return;
    page(conn, "p", s);
}

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
    if (std.mem.eql(u8, path, "/blank")) return page(conn, "blank", "");
    if (std.mem.endsWith(u8, path, "/boot")) {
        _ = boots.fetchAdd(1, .monotonic);
        return reply(conn, "text/plain", "boot");
    }
    // 어느 범위든 `sw.js`(업데이트 범위는 요청마다 다른 바이트 — `update()` 가 새 버전을 깐다).
    if (std.mem.endsWith(u8, path, "/sw.js")) {
        if (std.mem.indexOf(u8, target, "slow=1") != null) os.sleepMs(300);
        if (std.mem.startsWith(u8, path, "/sww/u/")) {
            var b: [1024]u8 = undefined;
            return reply(conn, js, std.fmt.bufPrint(&b, "/*{d}*/{s}", .{ update_n.fetchAdd(1, .monotonic), sw_js }) catch sw_js);
        }
        return reply(conn, js, sw_js);
    }
    if (std.mem.eql(u8, path, "/sww/dw.js")) return reply(conn, js, dw_js);
    if (std.mem.eql(u8, path, "/sww/dwo.js")) return reply(conn, js, dw_outer_js);
    if (std.mem.eql(u8, path, "/sww/dw2.js")) return reply(conn, js, dw2_js);
    if (std.mem.eql(u8, path, "/sww/shw.js")) return reply(conn, js, shw_js);
    // 기록 앞에 까는 범위(`/sww/a/`)·기록 중에 까는 범위(`/sww/b/`)·업데이트 범위(`/sww/u/`).
    if (std.mem.eql(u8, path, "/sww/a/p")) return regPage(conn, "/sww/a/");
    if (std.mem.eql(u8, path, "/sww/b/p")) return regPage(conn, "/sww/b/");
    if (std.mem.eql(u8, path, "/sww/u/p")) return regPage(conn, "/sww/u/");
    if (std.mem.eql(u8, path, "/sww/n/p")) return page(conn, "ready", "");
    // 다른 출처 iframe: 제 워커를 깔고(다스릴 때까지 다시 불러온다 — 그 iframe 안에서) 범위 안 fetch·전용 워커 뒤 부모에 알린다.
    if (std.mem.eql(u8, path, "/sww/xo/i")) return page(conn, "xo", "(async function(){var o={xo:1,ok:false,ctl:false,sw:0,dw:0};try{var t0=performance.now();await T(navigator.serviceWorker.register('/sww/xo/sw.js',{scope:'/sww/xo/'}),7000);" ++
        "await T(navigator.serviceWorker.ready,7000);if(!navigator.serviceWorker.controller){location.reload();return}o.ctl=true;" ++
        "var x=await T(fetch('/sww/xo/x?k=xo',{cache:'no-store'}).then(function(r){return r.text()}),7000);o.sw=performance.now()-t0;var t1=performance.now();" ++
        "var w=new Worker('/sww/dw.js');await T(wmsg(w,['up']),7000);w.terminate();o.dw=performance.now()-t1;o.ok=x.indexOf('\"n\"')>=0}catch(e){o.err=String(e)}parent.postMessage(o,'*')})()");
    if (std.mem.endsWith(u8, path, "/frame")) return page(conn, "frame", "");
    if (std.mem.endsWith(u8, path, "/x")) {
        const n = counter.fetchAdd(1, .monotonic);
        var bb: [64]u8 = undefined;
        return reply(conn, "application/json", std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{n}) catch "");
    }
    return reply(conn, "text/plain", "?");
}

const Dt = struct { call: u32, done: bool = false, status: msg.DevtoolsStatus = .ok, data: std.ArrayList(u8) = .empty };

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    created: std.AutoHashMapUnmanaged(u64, void) = .empty,
    loads: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    states: std.AutoHashMapUnmanaged(u64, msg.NetRecordStatus) = .empty,
    titles: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    dts: std.ArrayList(Dt) = .empty,
    next_call: u32 = 7000,

    fn dt(self: *Run, cid: u32) *Dt {
        for (self.dts.items) |*d| if (d.call == cid) return d;
        self.dts.append(self.gpa, .{ .call = cid }) catch unreachable;
        return &self.dts.items[self.dts.items.len - 1];
    }

    fn take(self: *Run, m: msg.Message) void {
        switch (m) {
            .net_record_state => |v| self.states.put(self.gpa, v.browser, v.status) catch {},
            .devtools_result_data => |v| self.dt(v.call).data.appendSlice(self.gpa, v.bytes) catch {},
            .devtools_result => |v| {
                const d = self.dt(v.call);
                d.done = true;
                d.status = v.status;
            },
            .browser_created => |id| self.created.put(self.gpa, id, {}) catch {},
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

    /// DevTools 호출(에이전트 길과 같은 `devtools_call`) — 상태와 결과(다음 호출 전까지).
    fn call(self: *Run, browser: u64, method: []const u8, params: []const u8, ms: u32) struct { status: msg.DevtoolsStatus, data: []const u8, answered: bool } {
        self.next_call += 1;
        const id = self.next_call;
        self.host.send(.{ .devtools_call = .{ .browser = browser, .call = id, .method = method, .params_size = @intCast(params.len) } }) catch return .{ .status = .send_failed, .data = "", .answered = false };
        if (params.len > 0) self.host.send(.{ .devtools_call_data = .{ .browser = browser, .call = id, .bytes = params } }) catch {};
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            const d = self.dt(id);
            if (d.done) return .{ .status = d.status, .data = d.data.items, .answered = true };
            const m = (self.host.next(20) catch null) orelse continue;
            self.take(m);
        }
        return .{ .status = .expired, .data = "", .answered = false };
    }

    /// 페이지 식 하나를 기다려 그 값(JSON 글)을 푼다 — 답이 없거나 값이 아니면 null.
    fn eval(self: *Run, browser: u64, expr: []const u8) ?Shot {
        var pb: [1024]u8 = undefined;
        const params = std.fmt.bufPrint(&pb, "{{\"expression\":\"{s}\",\"awaitPromise\":true,\"returnByValue\":true}}", .{expr}) catch return null;
        const r = self.call(browser, "Runtime.evaluate", params, 12_000);
        if (!r.answered or r.status != .ok) return null;
        return Shot.parse(self.gpa, r.data);
    }
};

/// 페이지 함수의 답 — `ok`·시각(ms).
const Shot = struct {
    ok: bool = false,
    ctl: bool = true,
    total: f64 = 0,
    act: f64 = 0,
    timeout: bool = false,
    again: bool = false,
    err: [80]u8 = @splat(0),
    err_len: usize = 0,

    fn parse(gpa: std.mem.Allocator, data: []const u8) ?Shot {
        var outer = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return null;
        defer outer.deinit();
        const res = outer.value.object.get("result") orelse return null;
        if (res != .object) return null;
        const val = res.object.get("value") orelse return null;
        if (val != .string) return null;
        var inner = std.json.parseFromSlice(std.json.Value, gpa, val.string, .{}) catch return null;
        defer inner.deinit();
        if (inner.value != .object) return null;
        const o = inner.value.object;
        var s: Shot = .{};
        if (o.get("ok")) |x| s.ok = x == .bool and x.bool;
        if (o.get("ctl")) |x| s.ctl = x == .bool and x.bool;
        s.total = num(o.get("total"));
        if (o.get("again")) |x| s.again = x == .bool and x.bool;
        s.act = num(o.get("act"));
        if (o.get("err")) |x| if (x == .string) {
            s.timeout = std.mem.indexOf(u8, x.string, "timeout") != null;
            s.err_len = @min(x.string.len, s.err.len);
            @memcpy(s.err[0..s.err_len], x.string[0..s.err_len]);
        };
        return s;
    }

    fn num(v: ?std.json.Value) f64 {
        const x = v orelse return 0;
        return switch (x) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => 0,
        };
    }
};

/// 한 꼴의 셈 — 걸림(시한·답 없음)·실패·시각.
const Tally = struct {
    n: usize = 0,
    hung: usize = 0,
    failed: usize = 0,
    uncontrolled: usize = 0,
    times: [256]f64 = undefined,
    acts: [256]f64 = undefined,
    nt: usize = 0,
    again: usize = 0,
    first_err: [80]u8 = @splat(0),
    first_err_len: usize = 0,

    fn add(self: *Tally, s: ?Shot) void {
        self.n += 1;
        const x = s orelse {
            self.hung += 1;
            return;
        };
        if (x.timeout) self.hung += 1 else if (!x.ok) self.failed += 1;
        if (x.again) self.again += 1;
        if (!x.ok and self.first_err_len == 0 and x.err_len > 0) {
            self.first_err = x.err;
            self.first_err_len = x.err_len;
        }
        if (!x.ctl) self.uncontrolled += 1;
        if (x.ok and self.nt < self.times.len) {
            self.times[self.nt] = x.total;
            self.acts[self.nt] = x.act;
            self.nt += 1;
        }
    }

    fn line(self: *Tally, buf: []u8) []const u8 {
        std.mem.sort(f64, self.times[0..self.nt], {}, std.sort.asc(f64));
        std.mem.sort(f64, self.acts[0..self.nt], {}, std.sort.asc(f64));
        const med = if (self.nt > 0) self.times[self.nt / 2] else 0;
        const p99 = if (self.nt > 0) self.times[@min(self.nt - 1, (self.nt * 99) / 100)] else 0;
        const amed = if (self.nt > 0) self.acts[self.nt / 2] else 0;
        const ap99 = if (self.nt > 0) self.acts[@min(self.nt - 1, (self.nt * 99) / 100)] else 0;
        return std.fmt.bufPrint(buf, "rounds {d} · hung {d} · failed {d} · uncontrolled {d} · total ms median {d:.1} p99 {d:.1} max {d:.1} · act ms median {d:.1} p99 {d:.1}{s}{s}", .{ self.n, self.hung, self.failed, self.uncontrolled, med, p99, if (self.nt > 0) self.times[self.nt - 1] else 0, amed, ap99, if (self.first_err_len > 0) " · first error: " else "", self.first_err[0..self.first_err_len] }) catch "";
    }

    fn againLine(self: *const Tally, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, " · install cut by the close (registered again) {d}", .{self.again}) catch "";
    }

    fn clean(self: *const Tally) bool {
        return self.n > 0 and self.hung == 0 and self.failed == 0;
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
    const only = std.c.getenv("SWWAIT_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(only), name) != null;
}

fn rounds() usize {
    const v = std.c.getenv("SWWAIT_ROUNDS") orelse return 20;
    return std.fmt.parseInt(usize, std.mem.span(v), 10) catch 20;
}

fn openTab(r: *Run, id: u64) !void {
    var u: [256]u8 = undefined;
    const size: msg.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
    try r.host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/blank", .{port}) } });
    if (!r.waitFor(wait_ms, id, createdAndLoaded)) return error.BrowserNotCreated;
    try r.host.send(.{ .net_watch = .{ .browser = id, .on = true, .full = true, .any_host = true } });
}

fn recordOn(r: *Run, id: u64, session: u32) bool {
    _ = r.states.remove(id);
    r.host.send(.{ .net_record = .{ .browser = id, .on = true, .session = session } }) catch return false;
    const ok = r.waitFor(5000, Want{ .id = id, .status = .on }, stateIs);
    r.pump(300); // 붙이기(`setAutoAttach`)와 떠 있는 워커의 enable 답
    return ok;
}

fn recordOff(r: *Run, id: u64) void {
    r.host.send(.{ .net_record = .{ .browser = id, .on = false, .session = 0 } }) catch {};
    r.pump(300);
}

/// 판정자의 표지(host 로그와 같은 단조 시계 — `swwait_d.py` 가 꼴마다 자른다).
fn mark(name: []const u8, edge: []const u8) void {
    std.debug.print("MARK {s} {s} {d}\n", .{ name, edge, machUs() });
}

fn stopAll(r: *Run) void {
    _ = r.call(tab_b, "ServiceWorker.stopAllWorkers", "", 5000);
    r.pump(500);
}

fn goUrlReady(r: *Run, id: u64, url: []const u8) !bool {
    try r.navigate(id, "/blank");
    _ = r.pumpTitle(id, "blank", 10_000);
    _ = r.titles.remove(id);
    try r.host.send(.{ .navigate = .{ .browser = id, .url = url } });
    return r.pumpTitle(id, "ready", 20_000);
}

fn goReady(r: *Run, id: u64, path: []const u8) !bool {
    // 같은 문서로 다시 옮기면 제목 알림이 오지 않는다 — 빈 문서를 거친다.
    try r.navigate(id, "/blank");
    _ = r.pumpTitle(id, "blank", 10_000);
    try r.navigate(id, path);
    return r.pumpTitle(id, "ready", 20_000);
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    try startServer();
    var detail: [1500]u8 = undefined;
    var lb: [600]u8 = undefined;
    var env_buf: [12][*:0]const u8 = undefined;
    var env_n: usize = 0;
    env_buf[env_n] = "MARU_WEB_SW_CDP=1";
    env_n += 1;
    env_buf[env_n] = "MARU_WEB_TEST_BODY_LOG=1";
    env_n += 1;
    // 대조·탐침 손잡이를 host 에 그대로 넘긴다(`MARU_WEB_SW_WAIT`·`MARU_WEB_SW_WAIT_FILTER`·`MARU_WEB_TEST_SW_*`).
    const pass_through = [_][:0]const u8{ "MARU_WEB_SW_WAIT", "MARU_WEB_SW_WAIT_FILTER", "MARU_WEB_SW_WAIT_STOPDETACH", "MARU_WEB_TEST_SW_NORELEASE", "MARU_WEB_TEST_SW_NOREPLY", "MARU_WEB_TEST_SW_PEND_MS", "MARU_WEB_SW_KEEP" };
    var pt_bufs: [pass_through.len][128:0]u8 = undefined;
    for (pass_through, 0..) |name, k| {
        const v = std.c.getenv(name) orelse continue;
        const s = std.fmt.bufPrintSentinel(&pt_bufs[k], "{s}={s}", .{ name, std.mem.span(v) }, 0) catch continue;
        if (env_n < env_buf.len) {
            env_buf[env_n] = s.ptr;
            env_n += 1;
        }
    }
    var sp_buf: [1100]u8 = undefined;
    const stderr_path: ?[:0]const u8 = if (std.c.getenv("SWWAIT_HOST_STDERR")) |p| std.mem.span(p) else blk: {
        const eq = std.mem.indexOfScalar(u8, profile_arg, '=') orelse break :blk null;
        break :blk std.fmt.bufPrintSentinel(&sp_buf, "{s}_host.log", .{profile_arg[eq + 1 ..]}, 0) catch null;
    };
    var host = try Host.spawnWith(host_path, profile_arg, stderr_path, env_buf[0..env_n]);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    var r: Run = .{ .host = &host, .gpa = gpa };
    try openTab(&r, tab_a);
    try openTab(&r, tab_b);
    try openTab(&r, tab_c);
    _ = r.call(tab_b, "ServiceWorker.enable", "", 5000);
    const n = rounds();
    var session: u32 = 30;

    // 새 범위 워커 — 기록하는 A·기록하지 않는 B·기록을 끈 A.
    if (enabled("first")) {
        inline for (.{ .{ "rec", tab_a, true, 1 }, .{ "norec", tab_b, false, 2 }, .{ "off", tab_a, false, 3 } }) |c| {
            var t: Tally = .{};
            const ready = try goReady(&r, c[1], "/sww/n/p");
            session += 1;
            const on = if (c[2]) recordOn(&r, c[1], session) else true;
            mark("first-" ++ c[0], "begin");
            for (0..n) |i| {
                var eb: [64]u8 = undefined;
                t.add(r.eval(c[1], std.fmt.bufPrint(&eb, "first({d}{d})", .{ c[3], i + 1000 }) catch "first(0)"));
            }
            mark("first-" ++ c[0], "end");
            if (c[2]) recordOff(&r, c[1]);
            report(ready and on and t.clean(), "swwait-first-" ++ c[0], std.fmt.bufPrint(&detail, "{s}", .{t.line(&lb)}) catch "");
            // 「기록을 끈 A」 는 앞 판(rec)에서 켰다 끈 뒤다.
        }
    }

    // 다시 뜸 — 기록 앞에 깐 워커(`/sww/a/`)·기록 중에 깐 워커(`/sww/b/`).
    if (enabled("restart")) {
        inline for (.{ .{ "pre", "/sww/a/p", false }, .{ "rec", "/sww/b/p", true } }) |c| {
            var t: Tally = .{};
            session += 1;
            var ready = false;
            var on = false;
            if (c[2]) {
                on = recordOn(&r, tab_a, session);
                ready = try goReady(&r, tab_a, c[1]);
            } else {
                ready = try goReady(&r, tab_a, c[1]);
                on = recordOn(&r, tab_a, session);
            }
            r.pump(500);
            const b0 = boots.load(.monotonic);
            mark("restart-" ++ c[0], "begin");
            for (0..n) |i| {
                stopAll(&r);
                var eb: [64]u8 = undefined;
                t.add(r.eval(tab_a, std.fmt.bufPrint(&eb, "hit('{s}x?k=r{d}')", .{ c[1][5..7], i }) catch "hit('x')"));
            }
            mark("restart-" ++ c[0], "end");
            const b1 = boots.load(.monotonic);
            recordOff(&r, tab_a);
            report(ready and on and t.clean() and t.uncontrolled == 0, "swwait-restart-" ++ c[0], std.fmt.bufPrint(&detail, "{s} · boots {d}", .{ t.line(&lb), b1 - b0 }) catch "");
        }
    }

    // 업데이트 — 같은 등록의 새 버전(새 타깃이 멈춰 붙는다).
    if (enabled("update")) {
        var t: Tally = .{};
        session += 1;
        const ready = try goReady(&r, tab_a, "/sww/u/p");
        const on = recordOn(&r, tab_a, session);
        mark("update", "begin");
        for (0..n) |_| t.add(r.eval(tab_a, "upd()"));
        mark("update", "end");
        recordOff(&r, tab_a);
        report(ready and on and t.clean(), "swwait-update", t.line(&lb));
    }

    // 기록하는 탭 둘 — 같은 출처의 새 워커·다시 뜸(두 탭의 세션이 함께 멈춰 붙는다).
    if (enabled("tabs")) {
        var tf: Tally = .{};
        var tr: Tally = .{};
        const ra = try goReady(&r, tab_a, "/sww/b/p");
        const rc = try goReady(&r, tab_c, "/sww/b/p");
        session += 1;
        const oa = recordOn(&r, tab_a, session);
        session += 1;
        const oc = recordOn(&r, tab_c, session);
        mark("tabs", "begin");
        for (0..n) |i| {
            var eb: [64]u8 = undefined;
            tf.add(r.eval(tab_a, std.fmt.bufPrint(&eb, "first(9{d})", .{i}) catch "first(0)"));
            stopAll(&r);
            tr.add(r.eval(if (i % 2 == 0) tab_a else tab_c, std.fmt.bufPrint(&eb, "hit('b/x?k=t{d}')", .{i}) catch "hit('x')"));
        }
        mark("tabs", "end");
        recordOff(&r, tab_a);
        recordOff(&r, tab_c);
        var lb2: [600]u8 = undefined;
        report(ra and rc and oa and oc and tf.clean() and tr.clean(), "swwait-tabs", std.fmt.bufPrint(&detail, "first: {s} | restart: {s}", .{ tf.line(&lb), tr.line(&lb2) }) catch "");
    }

    // 다른 출처 iframe 의 서비스 워커와 그 전용 워커 — 기록하는 A(남의 출처 세션)·기록하지 않는 B.
    if (enabled("xo")) {
        inline for (.{ .{ "rec", tab_a, true }, .{ "norec", tab_b, false } }) |c| {
            var t: Tally = .{};
            const ready = try goReady(&r, c[1], "/sww/n/p");
            session += 1;
            const on = if (c[2]) recordOn(&r, c[1], session) else true;
            mark("xo-" ++ c[0], "begin");
            for (0..n) |i| {
                if (i % 2 == 1) stopAll(&r);
                var eb: [64]u8 = undefined;
                t.add(r.eval(c[1], std.fmt.bufPrint(&eb, "xo({d})", .{i}) catch "xo(0)"));
            }
            mark("xo-" ++ c[0], "end");
            if (c[2]) recordOff(&r, c[1]);
            report(ready and on and t.clean() and t.uncontrolled == 0, "swwait-xo-" ++ c[0], t.line(&lb));
        }
    }

    // 전용 워커·공유 워커 — 기록하는 A(서비스 워커가 다스리는 페이지)·기록하지 않는 B.
    inline for (.{ .{ "dw", "dw()" }, .{ "shw", "shw" } }) |k| if (enabled(k[0])) {
        inline for (.{ .{ "rec", tab_a, true }, .{ "norec", tab_b, false } }) |c| {
            var t: Tally = .{};
            const ready = try goReady(&r, c[1], "/sww/b/p");
            session += 1;
            const on = if (c[2]) recordOn(&r, c[1], session) else true;
            mark(k[0] ++ "-" ++ c[0], "begin");
            for (0..n) |i| {
                var eb: [64]u8 = undefined;
                const e = if (comptime std.mem.eql(u8, k[0], "shw")) std.fmt.bufPrint(&eb, "shw({d}{d})", .{ c[1], i }) catch "shw(0)" else k[1];
                t.add(r.eval(c[1], e));
            }
            mark(k[0] ++ "-" ++ c[0], "end");
            if (c[2]) recordOff(&r, c[1]);
            report(ready and on and t.clean(), "swwait-" ++ k[0] ++ "-" ++ c[0], t.line(&lb));
        }
    };

    // 에이전트 DevTools 호출이 겹친다 — 페이지 세션의 놓기(해가 없다)·`Target.*` 막힘·워커 멈춤(다시 뜬다).
    if (enabled("agent")) {
        var t: Tally = .{};
        const ready = try goReady(&r, tab_a, "/sww/b/p");
        session += 1;
        const on = recordOn(&r, tab_a, session);
        var forbidden_ok: usize = 0;
        mark("agent", "begin");
        for (0..n) |i| {
            _ = r.call(tab_a, "Runtime.runIfWaitingForDebugger", "", 5000);
            const saa = r.call(tab_a, "Target.setAutoAttach", "{\"autoAttach\":false,\"waitForDebuggerOnStart\":false}", 5000);
            if (saa.answered and saa.status != .ok) forbidden_ok += 1;
            _ = r.call(tab_a, "ServiceWorker.enable", "", 5000);
            _ = r.call(tab_a, "ServiceWorker.stopAllWorkers", "", 5000);
            r.pump(300);
            var eb: [64]u8 = undefined;
            t.add(r.eval(tab_a, std.fmt.bufPrint(&eb, "first(8{d})", .{i}) catch "first(0)"));
            t.add(r.eval(tab_a, std.fmt.bufPrint(&eb, "hit('b/x?k=g{d}')", .{i}) catch "hit('x')"));
        }
        mark("agent", "end");
        _ = r.call(tab_a, "ServiceWorker.disable", "", 5000);
        recordOff(&r, tab_a);
        report(ready and on and t.clean() and forbidden_ok == n, "swwait-agent", std.fmt.bufPrint(&detail, "{s} · Target.setAutoAttach refused {d}/{d}", .{ t.line(&lb), forbidden_ok, n }) catch "");
    }

    // 깔자마자 기록을 끈다 — 멈춰 붙은 세션의 놓기 앞에 떼기·관찰자 놓기가 겹친다(그 뒤 그 워커가 뛰는가).
    if (enabled("offrace")) {
        var t: Tally = .{};
        const ready = try goReady(&r, tab_a, "/sww/n/p");
        mark("offrace", "begin");
        for (0..n) |i| {
            session += 1;
            _ = recordOn(&r, tab_a, session);
            var eb: [96]u8 = undefined;
            // 등록을 걸고(기다리지 않는다) 곧 기록을 끈 뒤 그 등록이 끝나는지 본다.
            _ = r.call(tab_a, "Runtime.evaluate", std.fmt.bufPrint(&eb, "{{\"expression\":\"window.P{d}=first(7{d})\"}}", .{ i, i }) catch "", 5000);
            r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } }) catch {};
            t.add(r.eval(tab_a, std.fmt.bufPrint(&eb, "window.P{d}", .{i}) catch "0"));
        }
        mark("offrace", "end");
        report(ready and t.clean(), "swwait-offrace", t.line(&lb));
    }

    // 깔자마자 기록하는 탭이 다른 출처로 옮긴다 — auto-attach 가 그 출처의 워커 세션을 스스로 뗀다(놓기 답 앞일 수 있다).
    if (enabled("navrace")) {
        var t: Tally = .{};
        const ready = try goReady(&r, tab_a, "/sww/n/p");
        session += 1;
        const on = recordOn(&r, tab_a, session);
        mark("navrace", "begin");
        for (0..n) |i| {
            _ = try goReady(&r, tab_a, "/sww/n/p");
            var eb: [96]u8 = undefined;
            _ = r.call(tab_a, "Runtime.evaluate", std.fmt.bufPrint(&eb, "{{\"expression\":\"window.P=first(5{d},1)\"}}", .{i}) catch "", 5000);
            var u: [128]u8 = undefined;
            r.host.send(.{ .navigate = .{ .browser = tab_a, .url = std.fmt.bufPrint(&u, "http://localhost:{d}/blank", .{port}) catch "" } }) catch {};
            r.pump(300);
            t.add(r.eval(tab_b, std.fmt.bufPrint(&eb, "late(5{d})", .{i}) catch "0"));
        }
        mark("navrace", "end");
        recordOff(&r, tab_a);
        var ab: [96]u8 = undefined;
        report(ready and on and t.clean(), "swwait-navrace", std.fmt.bufPrint(&detail, "{s}{s}", .{ t.line(&lb), t.againLine(&ab) }) catch "");
    }

    // 깔자마자 기록하는 탭이 닫힌다 — 멈춰 붙은 세션이 놓기 앞에 사라진다. 다른 탭(B — 기록하지 않는다)에서 그 등록이 끝나는지 본다.
    if (enabled("closerace")) {
        var t: Tally = .{};
        mark("closerace", "begin");
        for (0..n) |i| {
            const d = tab_d0 + i;
            try openTab(&r, d);
            _ = try goReady(&r, d, "/sww/n/p");
            session += 1;
            _ = recordOn(&r, d, session);
            var eb: [96]u8 = undefined;
            _ = r.call(d, "Runtime.evaluate", std.fmt.bufPrint(&eb, "{{\"expression\":\"window.P=first(6{d},1)\"}}", .{i}) catch "", 5000);
            r.host.send(.{ .destroy_browser = d }) catch {};
            r.pump(300);
            t.add(r.eval(tab_b, std.fmt.bufPrint(&eb, "late(6{d})", .{i}) catch "0"));
        }
        mark("closerace", "end");
        var ab: [96]u8 = undefined;
        report(t.clean(), "swwait-closerace", std.fmt.bufPrint(&detail, "{s}{s}", .{ t.line(&lb), t.againLine(&ab) }) catch "");
    }

    // 재검증 12 차(⑩′ — 붙여 두기): 기록하는 A 가 SW 범위에서 다른 출처로 떠나 40 초(놀이 시한 30 초 넘게) 머문 뒤 돌아온다 — 다녀간 출처의 세션을 붙여
    // 두면 그 SW 는 멈추지 않는다(돌아와도 boot 그대로), 끈 대조(`MARU_WEB_SW_KEEP=0`)는 멈췄다 다시 뜬다(boot +1).
    if (enabled("keepalive")) {
        const keep_on = if (std.c.getenv("MARU_WEB_SW_KEEP")) |v| !std.mem.eql(u8, std.mem.span(v), "0") else true;
        var u: [160]u8 = undefined;
        const ready0 = try goReady(&r, tab_a, "/sww/b/p");
        session += 1;
        const on = recordOn(&r, tab_a, session);
        r.pump(500);
        mark("keepalive", "begin");
        try r.host.send(.{ .navigate = .{ .browser = tab_a, .url = std.fmt.bufPrint(&u, "http://localhost:{d}/blank", .{port}) catch "" } });
        r.pump(40_000);
        const b0 = boots.load(.monotonic);
        _ = r.titles.remove(tab_a);
        try r.navigate(tab_a, "/sww/b/p");
        const ready1 = r.pumpTitle(tab_a, "ready", 20_000);
        r.pump(1500);
        const b1 = boots.load(.monotonic);
        const hit = r.eval(tab_a, "hit('b/x?k=keep')");
        mark("keepalive", "end");
        recordOff(&r, tab_a);
        const kept = b1 == b0;
        report(ready0 and on and ready1 and hit != null and kept == keep_on, "swwait-keepalive", std.fmt.bufPrint(&detail, "after 40 s away the worker {s} (boots {d} → {d}, keep {}) · fetch on return {s}", .{ if (kept) "kept running" else "stopped and restarted", b0, b1, keep_on, if (hit) |h| (if (h.ok) "ok" else "failed") else "hung" }) catch "");
    }

    // 재검증 12 차(⑩′ — 붙여 두기의 값): 기록하는 A 가 출처 스물(포트마다)을 차례로 다녀간다(출처마다 SW). 다녀간 출처의 세션은 탭 몫 16 까지 붙여
    // 두고 넘으면 가장 오래 떠나 있던 것부터 뗀다 — 그 출처로 돌아오면 처음 만남(어둠). helper 프로세스의 RSS 합을 출처 넷마다·40 초 놀린 뒤에 잰다.
    // 검증 v20r-B(15 회차 탐침 `SWWAIT_ONLY=keepmax`): 탭 T(`SWWAIT_KM_T`, 기본 1)가 저마다 다른 출처 N(`SWWAIT_KM_N`, 기본 100)을 다녀간다(탭 몫 16·
    // 전체 64 를 넘는다 — 탭이 여럿이면 남의 탭 세션을 빼는 `evictAway(0)` 길). 기록 중 RSS, 모두 끈 뒤 40 초 놀린 RSS, 그 뒤 기록하지 않는 B 로 처음·가운데·
    // 마지막 출처에 가 boot 가 느는가(놀이로 멈췄으면 +1 — 남은 세션이 쥐고 있으면 +0).
    if (std.c.getenv("SWWAIT_ONLY") != null and enabled("keepmax")) {
        const nt: usize = if (std.c.getenv("SWWAIT_KM_T")) |v| (std.fmt.parseInt(usize, std.mem.span(v), 10) catch 1) else 1;
        const no: usize = if (std.c.getenv("SWWAIT_KM_N")) |v| (std.fmt.parseInt(usize, std.mem.span(v), 10) catch 100) else 100;
        const m = @min(nt * no, extra_ports.len);
        for (0..m) |k| extra_ports[k] = try listenOn();
        var u: [160]u8 = undefined;
        var tabs: [8]u64 = undefined;
        for (0..@min(nt, tabs.len)) |i| {
            tabs[i] = 180 + i;
            try openTab(&r, tabs[i]);
            session += 1;
            if (std.c.getenv("SWWAIT_KM_NOREC") == null) _ = recordOn(&r, tabs[i], session); // 대조: 기록 없이 같은 길
        }
        const r0 = helperRss(host.pid);
        var ok: usize = 0;
        var rb: [900]u8 = undefined;
        var rn: usize = 0;
        mark("keepmax", "begin");
        for (0..m) |k| {
            const id = tabs[k % nt];
            if (try goUrlReady(&r, id, std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/sww/b/p", .{extra_ports[k]}) catch "")) ok += 1;
            if ((k + 1) % 20 == 0) {
                const x = helperRss(host.pid);
                const piece = std.fmt.bufPrint(rb[rn..], " {d}:{d}MiB/{d}", .{ k + 1, x.kb / 1024, x.n }) catch break;
                rn += piece.len;
            }
        }
        for (tabs[0..nt]) |id| try r.navigate(id, "/blank");
        r.pump(40_000);
        const r_idle = helperRss(host.pid);
        for (tabs[0..nt]) |id| recordOff(&r, id);
        r.pump(40_000);
        const r_off = helperRss(host.pid);
        var boots_line: [200]u8 = undefined;
        var bn: usize = 0;
        var kept: usize = 0;
        for ([_]usize{ 0, m / 2, m - 1 }) |k| {
            const b0 = boots.load(.monotonic);
            _ = try goUrlReady(&r, tab_b, std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/sww/b/p", .{extra_ports[k]}) catch "");
            r.pump(1000);
            const d = boots.load(.monotonic) - b0;
            if (d == 0) kept += 1;
            const piece = std.fmt.bufPrint(boots_line[bn..], " #{d}:+{d}", .{ k, d }) catch break;
            bn += piece.len;
        }
        try r.navigate(tab_b, "/blank");
        mark("keepmax", "end");
        report(ok == m and kept == 0, "swwait-keepmax", std.fmt.bufPrint(&detail, "tabs {d} × origins {d} · ready {d}/{d} · helper RSS start {d} MiB/{d} ·{s} · 40 s idle (still recording) {d} MiB/{d} · all off + 40 s {d} MiB/{d} · boots on revisit after off{s} (kept running {d})", .{ nt, no, ok, m, r0.kb / 1024, r0.n, rb[0..rn], r_idle.kb / 1024, r_idle.n, r_off.kb / 1024, r_off.n, boots_line[0..bn], kept }) catch "");
        for (tabs[0..nt]) |id| try r.host.send(.{ .destroy_browser = id });
        r.pump(500);
    }
    if (enabled("keepmem")) {
        const m: usize = 20;
        for (0..m) |k| extra_ports[k] = try listenOn();
        var u: [160]u8 = undefined;
        _ = try goReady(&r, tab_a, "/blank");
        session += 1;
        const on = recordOn(&r, tab_a, session);
        const r0 = helperRss(host.pid);
        var rb: [600]u8 = undefined;
        var rn: usize = 0;
        var ok: usize = 0;
        mark("keepmem", "begin");
        for (0..m) |k| {
            if (try goUrlReady(&r, tab_a, std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/sww/b/p", .{extra_ports[k]}) catch "")) ok += 1;
            if ((k + 1) % 4 == 0) {
                r.pump(2000);
                const x = helperRss(host.pid);
                const piece = std.fmt.bufPrint(rb[rn..], " {d}:{d}MiB/{d}", .{ k + 1, x.kb / 1024, x.n }) catch break;
                rn += piece.len;
            }
        }
        try r.navigate(tab_a, "/blank");
        r.pump(40_000);
        const r_idle = helperRss(host.pid);
        // 처음 출처(몫으로 뗐다)와 마지막 출처(붙여 두었다)로 돌아온다 — boot 가 는 수.
        const b0 = boots.load(.monotonic);
        _ = try goUrlReady(&r, tab_a, std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/sww/b/p", .{extra_ports[0]}) catch "");
        r.pump(1000);
        const b_first = boots.load(.monotonic) - b0;
        const b1 = boots.load(.monotonic);
        _ = try goUrlReady(&r, tab_a, std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/sww/b/p", .{extra_ports[m - 1]}) catch "");
        r.pump(1000);
        const b_last = boots.load(.monotonic) - b1;
        mark("keepmem", "end");
        recordOff(&r, tab_a);
        r.pump(1000);
        const r_off = helperRss(host.pid);
        report(on and ok == m, "swwait-keepmem", std.fmt.bufPrint(&detail, "origins {d}/{d} · helper RSS start {d} MiB/{d} procs ·{s} · after 40 s away {d} MiB/{d} · after off {d} MiB/{d} · on return: first origin boots +{d}, last origin boots +{d}", .{ ok, m, r0.kb / 1024, r0.n, rb[0..rn], r_idle.kb / 1024, r_idle.n, r_off.kb / 1024, r_off.n, b_first, b_last }) catch "");
    }
}
