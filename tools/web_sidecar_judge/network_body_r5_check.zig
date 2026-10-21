//! W9d② 적대 리뷰 5 회차 판정(`body-r5-*` — 리뷰가 남긴 재현 판정 `rv5-*` 를 옮겼다; `--network`·`--network-body` 끝에서 따로 띄운 sidecar·프로필로,
//! 이것만은 `--review-body-r5`). 서버는 응답마다 셈(`X-Body: N`)과 보낸 쪽
//! (`X-Who` — 요청의 `x-who` 머리)을 싣고 본문은 `{"n":"N"}` — 잡은 본문이 그 기록 제 응답 머리의 N 과 다르면 「틀린 본문」.
//!   body-r5-abort-refetch-many   abort 한 뒤 같은 주소 다시(r3 꼴 셋) 150 번 — 다시 받은 요청(p)의 `request_failed` 0·틀린 본문 0(A1 — 고치기 전
//!                                450 번에 1–3)
//!   body-r5-sw-navpreload-*      서비스 워커의 navigation preload(preloadResponse 로 답함 / preload 가 켜진 채 fetch 로 답함) — iframe 이동
//!   body-r5-sw-other-url         워커가 /o?a 를 /o?b 의 fetch 로 답하고 페이지는 /o?b 도 받는다(같은 열쇠의 워커 기록 둘)
//!   body-r5-sw-redirect-*        워커가 그대로 넘긴 fetch 의 302(따라감 / redirect:'manual' 의 opaque redirect)
//!   body-r5-sw-http-cache        워커가 그대로 넘긴 fetch 가 HTTP 캐시에서 온다(두 번째)
//!   body-r5-sw-dedupe            워커가 같은 주소의 진행 중 fetch 하나를 여럿에 나눠 준다
//!   body-r5-sw-two-tabs-*        두 탭(둘 다 기록)이 한 서비스 워커 아래 같은 주소를 거의 같이 — A 는 첫 응답을 받자 같은 주소를 다시 받고(A2),
//!                                서버는 A2 가 오면 A1 의 본문을 끝낸다(2·3 회차의 「남는 틈」: 뒤 요청의 기록이 아직이고 CDP 가 보지 못한 같은 열쇠
//!                                기록 — 여기서는 다른 탭의 워커 기록 — 이 앞에 있다)
//!   body-r5-sw-update            새 판 워커의 install 이 페이지가 받는 주소를 미리 받고(cache.addAll) skipWaiting·claim — 다섯 번
//!   body-r5-hostile-*            적대 탭이 900 KiB JSON 120 개 + 작은 JSON 200 개를 한꺼번에, 같은 때 다른 기록 탭이 작은 JSON 60 개(50 ms 마다)
//!                                — 다른 탭은 60/60, sidecar(브라우저 프로세스) RSS 의 최고값은 처음보다 96 MiB 넘게 늘지 않는다
//!   body-r5-giant-url            적대 탭이 1.5 MB 주소의 fetch 40 개 — 그동안 다른 기록 탭의 폴링 끝 사이의 가장 긴 틈(UI 스레드 멈춤 — 관측)
//!   body-r5-quit-drain           shutdown 뒤 관을 읽지 않을 때(maru 의 stop) 본문이 흐르는 기록 탭의 sidecar 가 3 초 안에 끝난다
//!   body-r5-mixlate-*            첫 적재의 스크립트·스타일 뒤 1.5 초에 낸 JSON(관측 — 틀린 본문 0)
//!   body-r5-mix-*                무거운 로컬 페이지(스크립트·스타일·이미지·JSON·같은 주소 셋·iframe 셋) — `body-r5-mix-page-json` 은 페이지의 JSON
//!                                90 % 이상(A2 — 고치기 전 57–62/90)

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const net_fields = protocol.net_fields;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const rec_tab: u64 = 95;
const tab_b: u64 = 97;
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

var port: u16 = 0;
var counter = std.atomic.Value(u64).init(1);
var hold_seen: [256]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false));

fn startServer() !void {
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

fn replyC(conn: c_int, status: []const u8, ctype: []const u8, cache: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [1024]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: {s}\r\n{s}Connection: close\r\n\r\n", .{ status, ctype, body.len, cache, extra }) catch return;
    writeAll(conn, head);
    writeAll(conn, body);
}

fn reply(conn: c_int, ctype: []const u8, body: []const u8) void {
    replyC(conn, "200 OK", ctype, "no-store", "", body);
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

/// `{"n":"N"}` 와 X-Body·X-Who.
fn dataC(conn: c_int, head: []const u8, ctype: []const u8, cache: []const u8) void {
    const n = counter.fetchAdd(1, .monotonic);
    var bb: [64]u8 = undefined;
    var xb: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{n}) catch return;
    const extra = std.fmt.bufPrint(&xb, "X-Body: {d}\r\nX-Who: {s}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Expose-Headers: X-Body\r\n", .{ n, whoOf(head) }) catch return;
    replyC(conn, "200 OK", ctype, cache, extra, body);
}

fn data(conn: c_int, head: []const u8) void {
    dataC(conn, head, "application/json", "no-store");
}

fn big(conn: c_int) void {
    const n_big: usize = 900 * 1024;
    var hb: [512]u8 = undefined;
    writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{n_big}) catch return);
    writeAll(conn, "\"");
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'a');
    var sent: usize = 1;
    while (sent + chunk.len < n_big - 1) : (sent += chunk.len) writeAll(conn, &chunk);
    writeAll(conn, chunk[0 .. n_big - 1 - sent]);
    writeAll(conn, "\"");
}

fn roundOf(target: []const u8) ?usize {
    const at = std.mem.indexOf(u8, target, "?r") orelse return null;
    var i = at + 2;
    var v: usize = 0;
    var digits: usize = 0;
    while (i < target.len and target[i] >= '0' and target[i] <= '9') : (i += 1) {
        v = v * 10 + (target[i] - '0');
        digits += 1;
    }
    if (digits == 0 or v >= hold_seen.len) return null;
    return v;
}

/// A1 의 본문은 A2 가 서버에 닿을 때까지(300 ms 까지) 끝내지 않는다.
fn hold(conn: c_int, head: []const u8, target: []const u8) void {
    const who = whoOf(head);
    const r = roundOf(target) orelse return data(conn, head);
    if (std.mem.eql(u8, who, "A2")) {
        hold_seen[r].store(true, .release);
        return data(conn, head);
    }
    if (!std.mem.eql(u8, who, "A1")) return data(conn, head);
    const n = counter.fetchAdd(1, .monotonic);
    var bb: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{n}) catch return;
    var hb: [512]u8 = undefined;
    writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nX-Body: {d}\r\nX-Who: A1\r\nConnection: close\r\n\r\n", .{ body.len, n }) catch return);
    writeAll(conn, body[0..5]);
    var waited: u32 = 0;
    while (!hold_seen[r].load(.acquire) and waited < 300) : (waited += 1) os.sleepMs(1);
    writeAll(conn, body[5..]);
}

const read_js = "function F(u,o){return fetch(u,o).then(function(r){return r.text()}).catch(function(){})}";
const reg_js = "function reg(next){navigator.serviceWorker.register('/rv5/sw/sw.js',{scope:'/rv5/sw/'}).then(function(){return navigator.serviceWorker.ready}).then(function(){" ++
    "if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}setTimeout(next,300)})}";

const sw_js = "var V=new URL(self.location).searchParams.get('v')||'1';" ++
    "self.addEventListener('install',function(e){if(V!='1'){var l=[];for(var i=0;i<40;i++)l.push('/rv5/sw/u?r'+V+'k'+i);" ++
    "e.waitUntil(caches.open('pre'+V).then(function(c){return c.addAll(l)}).then(function(){return self.skipWaiting()}));return}self.skipWaiting()});" ++
    "self.addEventListener('activate',function(e){e.waitUntil(Promise.all([clients.claim(),self.registration.navigationPreload?self.registration.navigationPreload.enable():0]))});" ++
    "var infl={};" ++
    "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);var p=u.pathname;var q=u.search;" ++
    "if(p=='/rv5/sw/nav/doc'){if(q.indexOf('?p')==0){e.respondWith(Promise.resolve(e.preloadResponse).then(function(r){return r||fetch(e.request)}));return}e.respondWith(fetch(e.request));return}" ++
    "if(p=='/rv5/sw/o'){if(q.indexOf('?a')==0){e.respondWith(fetch('/rv5/sw/o?b'+q.slice(2)));return}e.respondWith(fetch(e.request));return}" ++
    "if(p=='/rv5/sw/r'||p=='/rv5/sw/hold'||p=='/rv5/sw/u'||p=='/rv5/sw/hc'){e.respondWith(fetch(e.request));return}" ++
    "if(p=='/rv5/sw/dd'){var k=u.href;var pr=infl[k]||(infl[k]=fetch(k).then(function(r){setTimeout(function(){delete infl[k]},100);return r}));e.respondWith(pr.then(function(r){return r.clone()}));return}" ++
    "});";

fn serveOne(conn: c_int) void {
    defer _ = std.c.close(conn);
    // 머리 끝까지 읽는다(1.5 MB 주소의 요청도 — 읽지 않은 채 닫으면 RST 가 응답을 지운다). 앞 8 KiB 만 쥔다.
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
    _ = parts.next();
    const target = parts.next() orelse return;
    const qi = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. qi orelse target.len];
    const html = "text/html; charset=utf-8";
    if (std.mem.eql(u8, path, "/rv5/blank")) return reply(conn, html, "<!doctype html><title>blank</title>blank");
    if (std.mem.eql(u8, path, "/rv5/d") or std.mem.eql(u8, path, "/rv5/g")) return data(conn, head);
    if (std.mem.eql(u8, path, "/rv5/slow")) {
        os.sleepMs(5);
        return data(conn, head);
    }
    if (std.mem.eql(u8, path, "/rv5/big")) return big(conn);
    if (std.mem.eql(u8, path, "/rv5/slowp")) {
        writeAll(conn, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 20\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{\"slow\":");
        os.sleepMs(30_000);
        writeAll(conn, "\"0123456789\"}");
        return;
    }
    if (std.mem.eql(u8, path, "/rv5/flow")) return reply(conn, html, "<!doctype html><title>fl</title><script>" ++ read_js ++
        "for(var k=0;k<8;k++)F('/rv5/slowp?k'+k);var n=0;function loop(){for(var i=0;i<4;i++)F('/rv5/big?f'+(n++));F('/rv5/d?f'+n);setTimeout(loop,200)}loop()</script>fl");
    if (std.mem.eql(u8, path, "/rv5/img")) return reply(conn, "image/png", "\x89PNG\r\n\x1a\nxxxxxxxx");
    // ── abort 한 뒤 같은 주소 다시(r3 꼴 셋) 150 번.
    if (std.mem.eql(u8, path, "/rv5/abort")) return reply(conn, html, "<!doctype html><title>a</title><script>" ++ read_js ++
        "var i=0;function step(){if(i>=150){document.title='adone';return}var k=i;var u='/rv5/slow?a'+k;var c=new AbortController();" ++
        "F(u,{signal:c.signal,headers:{'x-who':'x'}});var go=function(){F(u,{headers:{'x-who':'p'}})};" ++
        "if(k%3==0){c.abort();go()}else if(k%3==1){Promise.resolve().then(function(){c.abort();go()})}else{setTimeout(function(){c.abort();go()},0)}" ++
        "i++;setTimeout(step,120)}setTimeout(step,300)</script>a");
    // ── 적대 탭·희생 탭.
    if (std.mem.eql(u8, path, "/rv5/hostile")) return reply(conn, html, "<!doctype html><title>h</title><script>" ++ read_js ++
        "setTimeout(function(){for(var j=0;j<120;j++)F('/rv5/big?'+j);for(var j=0;j<200;j++)F('/rv5/d?h'+j);setTimeout(function(){document.title='hdone'},6000)},200)</script>h");
    if (std.mem.eql(u8, path, "/rv5/victim")) return reply(conn, html, "<!doctype html><title>v</title><script>" ++ read_js ++
        "var i=0;function step(){if(i>=60){document.title='vdone';return}F('/rv5/d?v'+i);i++;setTimeout(step,50)}setTimeout(step,200)</script>v");
    if (std.mem.eql(u8, path, "/rv5/giant")) return reply(conn, html, "<!doctype html><title>g</title><script>" ++ read_js ++
        "var pad=new Array(1500001).join('x');setTimeout(function(){for(var j=0;j<40;j++)F('/rv5/g?k'+j+'&pad='+pad);setTimeout(function(){document.title='gdone'},4000)},300)</script>g");
    if (std.mem.eql(u8, path, "/rv5/gpoll")) return reply(conn, html, "<!doctype html><title>gp</title><script>" ++ read_js ++
        "var i=0;function step(){if(i>=200){document.title='gpdone';return}F('/rv5/d?gp'+location.search.slice(1)+'_'+i);i++;setTimeout(step,20)}setTimeout(step,200)</script>gp");
    // ── 무거운 로컬 페이지.
    if (std.mem.eql(u8, path, "/rv5/mix")) return reply(conn, html, "<!doctype html><title>m</title><script>" ++ read_js ++
        "function el(t,a){var e=document.createElement(t);for(var k in a)e[k]=a[k];document.head.appendChild(e);return e}" ++
        "setTimeout(function(){for(var i=0;i<30;i++)el('script',{src:'/rv5/mx/s.js?'+i});for(var i=0;i<20;i++)el('link',{rel:'stylesheet',href:'/rv5/mx/c.css?'+i});" ++
        "for(var i=0;i<40;i++){var im=new Image();im.src='/rv5/img?m'+i}for(var i=0;i<30;i++)F('/rv5/d?mj'+i);" ++
        "for(var i=0;i<10;i++){F('/rv5/d?ms'+i);F('/rv5/d?ms'+i);F('/rv5/d?ms'+i)}" ++
        "for(var i=0;i<3;i++){var f=document.createElement('iframe');f.src='/rv5/mx/f?'+i;document.body.appendChild(f)}" ++
        "setTimeout(function(){document.title='mdone'},4000)},200)</script>m");
    if (std.mem.eql(u8, path, "/rv5/mixlate")) return reply(conn, html, "<!doctype html><title>ml</title><script>" ++ read_js ++
        "function el(t,a){var e=document.createElement(t);for(var k in a)e[k]=a[k];document.head.appendChild(e);return e}" ++
        "setTimeout(function(){for(var i=0;i<30;i++)el('script',{src:'/rv5/mx/s.js?l'+i});for(var i=0;i<20;i++)el('link',{rel:'stylesheet',href:'/rv5/mx/c.css?l'+i});" ++
        "for(var i=0;i<6;i++)F('/rv5/d?ml0_'+i);setTimeout(function(){for(var i=0;i<30;i++)F('/rv5/d?ml1_'+i);setTimeout(function(){document.title='mldone'},3000)},1500)},200)</script>ml");
    if (std.mem.eql(u8, path, "/rv5/mx/s.js")) return dataC(conn, head, "application/javascript", "max-age=60");
    if (std.mem.eql(u8, path, "/rv5/mx/c.css")) return dataC(conn, head, "text/css", "max-age=60");
    if (std.mem.eql(u8, path, "/rv5/mx/f")) return reply(conn, html, "<!doctype html><script>" ++ read_js ++
        "for(var j=0;j<10;j++)F('/rv5/d?mf'+location.search.slice(1)+'_'+j)</script>f");
    // ── 서비스 워커(범위 /rv5/sw/).
    if (std.mem.eql(u8, path, "/rv5/sw/sw.js")) return reply(conn, "application/javascript", sw_js);
    if (std.mem.eql(u8, path, "/rv5/sw/nav/doc")) return dataC(conn, head, "text/html", "no-store");
    if (std.mem.eql(u8, path, "/rv5/sw/o") or std.mem.eql(u8, path, "/rv5/sw/rd") or std.mem.eql(u8, path, "/rv5/sw/u") or std.mem.eql(u8, path, "/rv5/sw/dd")) return data(conn, head);
    if (std.mem.eql(u8, path, "/rv5/sw/hc")) return dataC(conn, head, "application/json", "max-age=60");
    if (std.mem.eql(u8, path, "/rv5/sw/r")) {
        var x3: [256]u8 = undefined;
        const e3 = std.fmt.bufPrint(&x3, "Location: /rv5/sw/rd{s}\r\n", .{target[(qi orelse target.len)..]}) catch return;
        return replyC(conn, "302 Found", "text/plain", "no-store", e3, "");
    }
    if (std.mem.eql(u8, path, "/rv5/sw/hold")) return hold(conn, head, target);
    if (std.mem.eql(u8, path, "/rv5/sw/navp")) return reply(conn, html, "<!doctype html><title>nv</title><script>" ++ reg_js ++
        "var k=0;function step(){if(k>=40){document.title='nvdone';return}var f=document.createElement('iframe');f.src='/rv5/sw/nav/doc?'+(k<20?'p':'f')+k;k++;" ++
        "f.onload=function(){setTimeout(function(){f.remove();step()},60)};document.body.appendChild(f)}reg(step)</script>nv");
    if (std.mem.eql(u8, path, "/rv5/sw/otherp")) return reply(conn, html, "<!doctype html><title>o</title><script>" ++ read_js ++ reg_js ++
        "var k=0;function step(){if(k>=20){document.title='odone';return}F('/rv5/sw/o?a'+k);F('/rv5/sw/o?b'+k);k++;setTimeout(step,150)}reg(step)</script>o");
    if (std.mem.eql(u8, path, "/rv5/sw/redirp")) return reply(conn, html, "<!doctype html><title>r</title><script>" ++ read_js ++ reg_js ++
        "var k=0;function step(){if(k>=15){document.title='rdone';return}F('/rv5/sw/r?f'+k);F('/rv5/sw/r?m'+k,{redirect:'manual'});k++;setTimeout(step,150)}reg(step)</script>r");
    if (std.mem.eql(u8, path, "/rv5/sw/hcp")) return reply(conn, html, "<!doctype html><title>hc</title><script>" ++ read_js ++ reg_js ++
        "var k=0;function step(){if(k>=15){document.title='hcdone';return}var u='/rv5/sw/hc?'+k;k++;F(u).then(function(){return F(u)}).then(function(){setTimeout(step,80)})}reg(step)</script>hc");
    if (std.mem.eql(u8, path, "/rv5/sw/ddp")) return reply(conn, html, "<!doctype html><title>dd</title><script>" ++ read_js ++ reg_js ++
        "var k=0;function step(){if(k>=15){document.title='dddone';return}var u='/rv5/sw/dd?'+k;k++;F(u);F(u);F(u);setTimeout(step,150)}reg(step)</script>dd");
    // 두 탭: A 가 라운드를 알리고(BroadcastChannel) 0–3 ms 뒤 A1, A1 의 응답 머리를 받자 A2. B 는 알림을 받자 곧 같은 주소.
    if (std.mem.eql(u8, path, "/rv5/sw/holdp")) {
        if (std.mem.indexOf(u8, target, "?B") != null) return reply(conn, html, "<!doctype html><title>hb</title><script>" ++ reg_js ++
            "var bc=new BroadcastChannel('rv5');reg(function(){document.title='bready';bc.onmessage=function(e){fetch(e.data,{headers:{'x-who':'B'}}).then(function(r){return r.text()}).catch(function(){})}})</script>hb");
        return reply(conn, html, "<!doctype html><title>ha</title><script>" ++ reg_js ++
            "var bc=new BroadcastChannel('rv5');var k=0;function step(){if(k>=60){document.title='holddone';return}var j=k;k++;var u='/rv5/sw/hold?r'+j;bc.postMessage(u);" ++
            "setTimeout(function(){fetch(u,{headers:{'x-who':'A1'}}).then(function(r){fetch(u,{headers:{'x-who':'A2'}}).then(function(r2){return r2.text()}).catch(function(){});return r.text()}).catch(function(){})},j%4);" ++
            "setTimeout(step,150)}reg(function(){document.title='aready';setTimeout(step,500)})</script>ha");
    }
    // 새 판 워커: 판 v 의 install 이 /u?r<v>k0..39 를 미리 받는다 — 페이지는 등록하자마자 0–30 ms 뒤 같은 주소 40 개.
    if (std.mem.eql(u8, path, "/rv5/sw/updp")) return reply(conn, html, "<!doctype html><title>up</title><script>" ++ read_js ++ reg_js ++
        "var v=2;function step(){if(v>=7){document.title='updone';return}var vv=v;v++;navigator.serviceWorker.register('/rv5/sw/sw.js?v='+vv,{scope:'/rv5/sw/'}).catch(function(){});" ++
        "setTimeout(function(){for(var i=0;i<40;i++)F('/rv5/sw/u?r'+vv+'k'+i)},(vv*7)%30);setTimeout(step,1200)}reg(step)</script>up");
    return reply(conn, "text/plain", "x");
}

const Begin = struct { browser: u64, request: u64, url: []u8, expected: bool, flags: msg.NetFlags, method: []u8, at_ms: i64 };
const Body = struct { browser: u64, request: u64, data: std.ArrayList(u8) = .empty, ends: usize = 0, state: msg.NetBodyState = .unavailable, xbody: []u8 = &.{}, xwho: []u8 = &.{}, status: u16 = 0, decoded: u64 = 0, end_ms: i64 = 0 };

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    begins: std.ArrayList(Begin) = .empty,
    bodies: std.ArrayList(Body) = .empty,
    created: std.AutoHashMapUnmanaged(u64, void) = .empty,
    loads: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    states: std.AutoHashMapUnmanaged(u64, msg.NetRecordStatus) = .empty,
    titles: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    dropped: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    rss_peak_kb: u64 = 0,
    sample_rss: bool = false,
    last_sample_ms: i64 = 0,

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
            .net_begin => |v| self.begins.append(self.gpa, .{ .browser = v.browser, .request = v.request, .url = self.gpa.dupe(u8, v.url) catch &.{}, .expected = v.flags2.body_expected, .flags = v.flags, .method = self.gpa.dupe(u8, v.method) catch &.{}, .at_ms = os.nowMs() }) catch {},
            .net_response => |v| {
                const b = self.body(v.browser, v.request);
                b.status = v.status;
                var it = net_fields.HeaderIterator.init(v.headers);
                while (it.next()) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "x-body")) b.xbody = self.gpa.dupe(u8, h.value) catch &.{};
                    if (std.ascii.eqlIgnoreCase(h.name, "x-who")) b.xwho = self.gpa.dupe(u8, h.value) catch &.{};
                }
            },
            .net_body_data => |v| {
                const b = self.body(v.browser, v.request);
                if (v.offset == b.data.items.len) b.data.appendSlice(self.gpa, v.bytes) catch {};
            },
            .net_body_end => |v| {
                const b = self.body(v.browser, v.request);
                b.ends += 1;
                b.state = v.state;
                b.decoded = v.decoded;
                b.end_ms = os.nowMs();
            },
            .net_dropped => |v| {
                const g = self.dropped.getOrPut(self.gpa, v.browser) catch return;
                if (!g.found_existing) g.value_ptr.* = 0;
                g.value_ptr.* += v.count;
            },
            .net_record_state => |v| self.states.put(self.gpa, v.browser, v.status) catch {},
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

    fn sample(self: *Run) void {
        if (!self.sample_rss) return;
        const now = os.nowMs();
        if (now - self.last_sample_ms < 100) return;
        self.last_sample_ms = now;
        var cb: [64]u8 = undefined;
        const cmd = std.fmt.bufPrintSentinel(&cb, "ps -o rss= -p {d}", .{self.host.pid}, 0) catch return;
        const f = popen(cmd, "r") orelse return;
        var lb: [64]u8 = undefined;
        if (fgets(&lb, lb.len, f)) |_| {
            const s = std.mem.trim(u8, std.mem.sliceTo(&lb, 0), " \n\t");
            const kb = std.fmt.parseInt(u64, s, 10) catch 0;
            self.rss_peak_kb = @max(self.rss_peak_kb, kb);
        }
        _ = pclose(f);
    }

    fn pump(self: *Run, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            self.sample();
            const m = (self.host.next(20) catch null) orelse continue;
            self.take(m);
        }
    }

    fn pumpTitle(self: *Run, browser: u64, title: []const u8, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            self.sample();
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
    sw: usize = 0,
    sw_captured: usize = 0,
    states: [16]usize = @splat(0),
    notes: [900]u8 = undefined,
    notes_len: usize = 0,

    fn note(t: *Tally, comptime fmt: []const u8, args: anytype) void {
        const piece = std.fmt.bufPrint(t.notes[t.notes_len..], fmt, args) catch return;
        t.notes_len += piece.len;
    }
};

fn tally(r: *Run, browser: u64, at: usize, needle: []const u8, who: ?[]const u8) Tally {
    var t: Tally = .{};
    for (r.begins.items[at..]) |b| if (b.browser == browser and std.mem.indexOf(u8, b.url, needle) != null) {
        const x = r.body(browser, b.request);
        if (who) |w| if (!std.mem.eql(u8, x.xwho, w)) continue;
        t.total += 1;
        if (b.expected) t.expected += 1;
        if (b.flags.service_worker) t.sw += 1;
        if (x.ends == 1) t.states[@backingInt(x.state)] += 1;
        if (b.expected and x.ends != 1) t.no_end += 1;
        if (x.ends == 1 and x.state == .captured) {
            if (b.flags.service_worker) t.sw_captured += 1;
            var want: [64]u8 = undefined;
            const wnt = std.fmt.bufPrint(&want, "{{\"n\":\"{s}\"}}", .{x.xbody}) catch "";
            if (x.xbody.len == 0) {
                t.unknown += 1;
                t.note(" [req {d} {s} status {d} no X-Body got {s}]", .{ b.request, b.url[@min(b.url.len, 22)..@min(b.url.len, 60)], x.status, x.data.items[0..@min(x.data.items.len, 20)] });
            } else if (std.mem.eql(u8, x.data.items, wnt)) {
                t.own += 1;
            } else {
                t.wrong += 1;
                t.note(" [WRONG req {d}{s} who {s} X-Body {s} got {s}]", .{ b.request, if (b.flags.service_worker) " sw" else "", x.xwho, x.xbody, x.data.items[0..@min(x.data.items.len, 20)] });
            }
        } else if (x.ends == 1 and x.state == .ambiguous) {
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
    return std.fmt.bufPrint(buf, "CEF requests {d} (body_expected {d}, sw {d}) · own body {d} · WRONG {d} · captured w/o X-Body {d} · ambiguous {d} · other {d} · no/several ends {d} · sw captured {d} · states{s} ·{s}", .{ t.total, t.expected, t.sw, t.own, t.wrong, t.unknown, t.ambiguous, t.other, t.no_end, t.sw_captured, stateLine(t, sl), t.notes[0..t.notes_len] }) catch "";
}

fn enabled(name: []const u8) bool {
    const only = std.c.getenv("R5_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(only), name) != null;
}

fn openTab(r: *Run, id: u64, session: u32) !void {
    var u: [256]u8 = undefined;
    const size: msg.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
    try r.host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/rv5/blank", .{port}) } });
    if (!r.waitFor(wait_ms, id, createdAndLoaded)) return error.BrowserNotCreated;
    try r.host.send(.{ .net_watch = .{ .browser = id, .on = true, .full = true, .any_host = true } });
    try r.host.send(.{ .net_record = .{ .browser = id, .on = true, .session = session } });
    _ = r.waitFor(5000, id, hasState);
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    try startServer();
    var detail: [4000]u8 = undefined;
    var sl: [400]u8 = undefined;
    const log_env: []const [*:0]const u8 = if (std.c.getenv("MARU_WEB_TEST_BODY_LOG") != null) &.{"MARU_WEB_TEST_BODY_LOG=1"} else &.{};
    var host = try Host.spawnWith(host_path, profile_arg, null, log_env);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    var r: Run = .{ .host = &host, .gpa = gpa };
    try openTab(&r, rec_tab, 1);
    try openTab(&r, tab_b, 2);

    // ── abort 한 뒤 다시 받기 150 번(A1 의 빈도) ──
    if (enabled("abort")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv5/abort");
        const done = r.pumpTitle(rec_tab, "adone", 60_000);
        r.pump(4000);
        // 주소마다: CEF 기록 수(1 = abort 가 CEF 에 닿지 않았다), 다시 받은 요청(p)의 상태.
        var p_total: usize = 0;
        var p_own: usize = 0;
        var p_failed: usize = 0;
        var p_other: usize = 0;
        var p_wrong: usize = 0;
        var single: usize = 0;
        var single_failed: usize = 0;
        var by_kind: [3]usize = @splat(0);
        var kb: [400]u8 = undefined;
        var kn: usize = 0;
        for (0..150) |k| {
            var nb: [40]u8 = undefined;
            const needle = std.fmt.bufPrint(&nb, "/rv5/slow?a{d}", .{k}) catch continue;
            var recs: usize = 0;
            var p_req: ?*Body = null;
            for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.endsWith(u8, b.url, needle)) {
                recs += 1;
                const x = r.body(rec_tab, b.request);
                if (std.mem.eql(u8, x.xwho, "p")) p_req = x;
            };
            if (recs == 1) single += 1;
            const x = p_req orelse continue;
            p_total += 1;
            if (x.ends == 1 and x.state == .captured) {
                var wb: [64]u8 = undefined;
                if (std.mem.eql(u8, x.data.items, std.fmt.bufPrint(&wb, "{{\"n\":\"{s}\"}}", .{x.xbody}) catch "")) p_own += 1 else p_wrong += 1;
            } else if (x.ends == 1 and x.state == .request_failed) {
                p_failed += 1;
                if (recs == 1) single_failed += 1;
                by_kind[k % 3] += 1;
                const piece = std.fmt.bufPrint(kb[kn..], " a{d}(k%3={d},recs {d})", .{ k, k % 3, recs }) catch "";
                kn += piece.len;
            } else p_other += 1;
        }
        report(done and p_failed == 0 and p_wrong == 0, "body-r5-abort-refetch-many", std.fmt.bufPrint(&detail, "refetch requests {d} · own {d} · request_failed {d} (sync/microtask/timeout0 = {d}/{d}/{d}; of them abort never reached CEF {d}) · wrong {d} · other {d} · URLs whose abort never reached CEF {d}/150 ·{s}", .{ p_total, p_own, p_failed, by_kind[0], by_kind[1], by_kind[2], single_failed, p_wrong, p_other, single, kb[0..kn] }) catch "");
    }

    // ── 서비스 워커 ──
    if (enabled("navpreload")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv5/sw/navp");
        const done = r.pumpTitle(rec_tab, "nvdone", 40_000);
        r.pump(4000);
        const a = tally(&r, rec_tab, at, "/rv5/sw/nav/doc?p", null);
        report(done and a.wrong == 0, "body-r5-sw-navpreload-preload", lineOf(&a, &detail, &sl));
        const b = tally(&r, rec_tab, at, "/rv5/sw/nav/doc?f", null);
        report(done and b.wrong == 0, "body-r5-sw-navpreload-fetch", lineOf(&b, &detail, &sl));
    }
    if (enabled("other")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv5/sw/otherp");
        const done = r.pumpTitle(rec_tab, "odone", 30_000);
        r.pump(4000);
        const t = tally(&r, rec_tab, at, "/rv5/sw/o?", null);
        report(done and t.wrong == 0, "body-r5-sw-other-url", lineOf(&t, &detail, &sl));
    }
    if (enabled("redirect")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv5/sw/redirp");
        const done = r.pumpTitle(rec_tab, "rdone", 30_000);
        r.pump(4000);
        const f = tally(&r, rec_tab, at, "/rv5/sw/r?f", null);
        report(done and f.wrong == 0, "body-r5-sw-redirect-follow", lineOf(&f, &detail, &sl));
        const m = tally(&r, rec_tab, at, "/rv5/sw/r?m", null);
        report(done and m.wrong == 0, "body-r5-sw-redirect-manual", lineOf(&m, &detail, &sl));
    }
    if (enabled("httpcache")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv5/sw/hcp");
        const done = r.pumpTitle(rec_tab, "hcdone", 30_000);
        r.pump(4000);
        const t = tally(&r, rec_tab, at, "/rv5/sw/hc?", null);
        report(done and t.wrong == 0, "body-r5-sw-http-cache", lineOf(&t, &detail, &sl));
    }
    if (enabled("dedupe")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv5/sw/ddp");
        const done = r.pumpTitle(rec_tab, "dddone", 30_000);
        r.pump(4000);
        const t = tally(&r, rec_tab, at, "/rv5/sw/dd?", null);
        report(done and t.wrong == 0, "body-r5-sw-dedupe", lineOf(&t, &detail, &sl));
    }
    if (enabled("twotabs")) {
        const at = r.begins.items.len;
        try r.navigate(tab_b, "/rv5/sw/holdp?B");
        _ = r.pumpTitle(tab_b, "bready", 20_000);
        try r.navigate(rec_tab, "/rv5/sw/holdp?A");
        const done = r.pumpTitle(rec_tab, "holddone", 40_000);
        r.pump(4000);
        inline for (.{ .{ rec_tab, "body-r5-sw-two-tabs-A" }, .{ tab_b, "body-r5-sw-two-tabs-B" } }) |c| {
            const t = tally(&r, c[0], at, "/rv5/sw/hold?", null);
            const a1 = tally(&r, c[0], at, "/rv5/sw/hold?", "A1");
            const a2 = tally(&r, c[0], at, "/rv5/sw/hold?", "A2");
            const bb = tally(&r, c[0], at, "/rv5/sw/hold?", "B");
            var lb: [4000]u8 = undefined;
            report(done and t.wrong == 0, c[1], std.fmt.bufPrint(&detail, "by who: A1 own/amb/other {d}/{d}/{d} · A2 own/amb/other {d}/{d}/{d} · B own/amb/other {d}/{d}/{d} · all: {s}", .{ a1.own, a1.ambiguous, a1.other, a2.own, a2.ambiguous, a2.other, bb.own, bb.ambiguous, bb.other, lineOf(&t, &lb, &sl) }) catch "");
        }
        try r.navigate(tab_b, "/rv5/blank?b");
        r.pump(500);
    }
    if (enabled("update")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv5/sw/updp");
        const done = r.pumpTitle(rec_tab, "updone", 40_000);
        r.pump(4000);
        const t = tally(&r, rec_tab, at, "/rv5/sw/u?", null);
        report(done and t.wrong == 0, "body-r5-sw-update", lineOf(&t, &detail, &sl));
    }
    // ── 적대 탭 ──
    if (enabled("hostile")) {
        const at = r.begins.items.len;
        r.sample_rss = true;
        r.rss_peak_kb = 0;
        r.sample();
        const base_rss = r.rss_peak_kb;
        r.rss_peak_kb = 0;
        try r.navigate(tab_b, "/rv5/hostile");
        try r.navigate(rec_tab, "/rv5/victim");
        const done = r.pumpTitle(rec_tab, "vdone", 30_000);
        _ = r.pumpTitle(tab_b, "hdone", 30_000);
        r.pump(6000);
        r.sample_rss = false;
        const v = tally(&r, rec_tab, at, "/rv5/d?v", null);
        const hb = tally(&r, tab_b, at, "/rv5/big?", null);
        const hs = tally(&r, tab_b, at, "/rv5/d?h", null);
        var lb: [4000]u8 = undefined;
        // 5 회차 고침(기다림 탭 128·전체 512): 다른 기록 탭은 그대로 60/60, sidecar(브라우저 프로세스)의 RSS 는 적대 탭의 본문 합(108 MiB)보다 덜 는다.
        report(done and v.wrong == 0 and v.total == 60 and v.own == v.total, "body-r5-hostile-victim", std.fmt.bufPrint(&detail, "victim capture {d}/{d} (need 60/60) · {s}", .{ v.own, v.total, lineOf(&v, &lb, &sl) }) catch "");
        var sl2: [400]u8 = undefined;
        report(hb.wrong == 0 and hs.wrong == 0 and hb.no_end == 0 and hs.no_end == 0 and base_rss > 0 and r.rss_peak_kb <= base_rss + 96 * 1024, "body-r5-hostile-attacker", std.fmt.bufPrint(&detail, "big: total {d} states{s} · small: own {d}/{d} states{s} · sidecar browser RSS before {d} KiB, peak {d} KiB (need growth <= 96 MiB)", .{ hb.total, stateLine(&hb, &sl), hs.own, hs.total, stateLine(&hs, &sl2), base_rss, r.rss_peak_kb }) catch "");
        try r.navigate(tab_b, "/rv5/blank?h");
        r.pump(1000);
    }
    if (enabled("giant")) {
        // 먼저 혼자 폴링(기준) — 그다음 적대 탭의 큰 주소와 함께.
        var gaps: [3]i64 = .{ 0, 0, 0 };
        var counts: [3]usize = .{ 0, 0, 0 };
        var drops_before: u64 = 0;
        for (0..3) |phase| {
            const at = r.begins.items.len;
            drops_before = r.dropped.get(tab_b) orelse 0;
            // 대조(phase 2): 적대 탭의 본문 기록을 끈 채 같은 큰 주소 — 멈춤이 본문 기록 때문인가.
            if (phase == 2) {
                try r.host.send(.{ .net_record = .{ .browser = tab_b, .on = false } });
                try r.navigate(tab_b, "/rv5/blank?g2");
                r.pump(1500);
            }
            if (phase >= 1) try r.navigate(tab_b, "/rv5/giant");
            try r.navigate(rec_tab, if (phase == 0) "/rv5/gpoll?a" else if (phase == 1) "/rv5/gpoll?b" else "/rv5/gpoll?c");
            _ = r.pumpTitle(rec_tab, "gpdone", 30_000);
            r.pump(3000);
            var last: i64 = 0;
            for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, "/rv5/d?gp") != null) {
                const x = r.body(rec_tab, b.request);
                if (x.ends != 1) continue;
                counts[phase] += 1;
                if (last != 0) gaps[phase] = @max(gaps[phase], x.end_ms - last);
                last = @max(last, x.end_ms);
            };
        }
        const g = tally(&r, tab_b, 0, "/rv5/g?k", null);
        report(true, "body-r5-giant-url", std.fmt.bufPrint(&detail, "victim poll ends alone {d} (max gap {d} ms) · with 40 × 1.5 MB-URL fetches in the other (recording) tab {d} (max gap {d} ms) · same with that tab NOT recording {d} (max gap {d} ms) · giant begins {d} states{s} · net_dropped other tab {d}", .{ counts[0], gaps[0], counts[1], gaps[1], counts[2], gaps[2], g.total, stateLine(&g, &sl), (r.dropped.get(tab_b) orelse 0) - drops_before }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = tab_b, .on = true, .session = 3 } });
        try r.navigate(tab_b, "/rv5/blank?g");
        r.pump(1000);
    }
    if (enabled("quit")) {
        // 앱 종료 꼴(maru `web_osr.stop`): shutdown 을 보낸 뒤 관을 읽지 않고 기다린다 — 3 초면 maru 가 SIGKILL. 본문이 흐르는 기록 탭 / 기록 끔 대조.
        var times: [2]i64 = .{ -1, -1 };
        var queued: [2]usize = .{ 0, 0 };
        for (0..2) |mode| {
            var pb2: [1100]u8 = undefined;
            const prof2 = std.fmt.bufPrintSentinel(&pb2, "{s}_q{d}", .{ profile_arg, mode }, 0) catch return;
            var h2 = try Host.spawnWith(host_path, prof2, null, &.{});
            try browsers_check.handshake(&h2);
            var r2: Run = .{ .host = &h2, .gpa = gpa };
            const qid: u64 = 99;
            var ub2: [256]u8 = undefined;
            try h2.send(.{ .create_browser = .{ .browser = qid, .size = .{ .width = 640, .height = 400, .scale = 2 }, .hidden = false, .url = try std.fmt.bufPrint(&ub2, "http://127.0.0.1:{d}/rv5/blank", .{port}) } });
            if (!r2.waitFor(wait_ms, qid, createdAndLoaded)) return error.BrowserNotCreated;
            try h2.send(.{ .net_watch = .{ .browser = qid, .on = true, .full = true, .any_host = true } });
            if (mode == 0) {
                try h2.send(.{ .net_record = .{ .browser = qid, .on = true, .session = 1 } });
                _ = r2.waitFor(5000, qid, hasState);
            }
            try r2.navigate(qid, "/rv5/flow");
            r2.pump(4000);
            for (r2.bodies.items) |b| if (b.ends == 0 and b.data.items.len > 0) {
                queued[mode] += 1;
            };
            const t0 = os.nowMs();
            try h2.send(.shutdown);
            // 읽지 않는다(maru 의 stop 처럼) — 끝나기를 6 초까지.
            if (h2.wait(6000)) |_| times[mode] = os.nowMs() - t0 else {
                _ = std.c.kill(h2.pid, .KILL);
                _ = h2.wait(5000);
            }
        }
        report(times[0] >= 0 and times[0] < 3000, "body-r5-quit-drain", std.fmt.bufPrint(&detail, "sidecar exit after shutdown without reading: recording + bodies flowing {d} ms · recording off {d} ms (-1 = still alive after 6 s; maru SIGKILLs at 3 s)", .{ times[0], times[1] }) catch "");
    }
    if (enabled("mixlate")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv5/mixlate");
        const done = r.pumpTitle(rec_tab, "mldone", 30_000);
        r.pump(4000);
        inline for (.{ .{ "/rv5/mx/s.js?l", "body-r5-mixlate-script" }, .{ "/rv5/mx/c.css?l", "body-r5-mixlate-css" }, .{ "/rv5/d?ml0", "body-r5-mixlate-json-during-burst" }, .{ "/rv5/d?ml1", "body-r5-mixlate-json-1500ms-after" } }) |c| {
            const t = tally(&r, rec_tab, at, c[0], null);
            var lb: [4000]u8 = undefined;
            report(done and t.wrong == 0, c[1], std.fmt.bufPrint(&detail, "capture {d}/{d} · {s}", .{ t.own, t.total, lineOf(&t, &lb, &sl) }) catch "");
        }
    }
    if (enabled("mix")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv5/mix");
        const done = r.pumpTitle(rec_tab, "mdone", 30_000);
        r.pump(5000);
        inline for (.{ .{ "/rv5/mx/s.js", "body-r5-mix-script" }, .{ "/rv5/mx/c.css", "body-r5-mix-css" }, .{ "/rv5/d?mj", "body-r5-mix-json" }, .{ "/rv5/d?ms", "body-r5-mix-same-url-x3" }, .{ "/rv5/d?mf", "body-r5-mix-iframe-json" }, .{ "/rv5/", "body-r5-mix-all" } }) |c| {
            const t = tally(&r, rec_tab, at, c[0], null);
            var lb: [4000]u8 = undefined;
            report(done and t.wrong == 0, c[1], std.fmt.bufPrint(&detail, "capture {d}/{d} · {s}", .{ t.own, t.total, lineOf(&t, &lb, &sl) }) catch "");
        }
        // 재현 A2: 페이지의 JSON(같은 주소 셋·iframe 포함)은 첫 적재의 스크립트·스타일과 함께여도 90 % 이상 잡아야 한다(기다림 32 가 넘쳐 `busy`).
        const pj = tally(&r, rec_tab, at, "/rv5/d?m", null);
        report(done and pj.wrong == 0 and pj.own * 100 >= pj.total * 90, "body-r5-mix-page-json", std.fmt.bufPrint(&detail, "page JSON capture {d}/{d} (need 90 %) · busy {d}", .{ pj.own, pj.total, pj.states[@backingInt(msg.NetBodyState.busy)] }) catch "");
    }
}
