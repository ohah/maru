//! W9d② 적대 리뷰 4 회차 판정(`body-r4-*` — 리뷰가 남긴 재현 판정 `rv4-*` 를 옮겼다; `--network`·`--network-body` 끝에서 따로 띄운 sidecar·프로필로,
//! 이것만은 `--review-body-r4`). 서버는 응답마다 셈(`X-Body: N`)을 머리에 싣고 본문은 `{"n":"N"}` — 잡은 본문이 그 기록 제 응답 머리의 N 과
//! 다르면 「틀린 본문」(그 기록이 받은 응답의 본문이 아니다). 통과는 틀린 본문 0(아래 더한 조건은 항목마다).
//!   body-r4-sw-swr        서비스 워커의 stale-while-revalidate(캐시로 답하고 같은 주소를 네트워크로 받아 캐시를 고친다) — 같은 주소 차례로 20 번 ×2
//!                         (고치기 전 틀림 38/40 — 페이지의 응답 출처 `cache-storage` 를 보고 워커 기록에 붙이지 않는다)
//!   body-r4-sw-synth      서비스 워커가 네트워크로 받은 뒤 `new Response` 로 바꿔 답한다(고치기 전 틀림 15/15)
//!   body-r4-sw-mixed      같은 주소를 서비스 워커가 그대로 넘김(pass-through)·놓음(fallback) 섞어 한꺼번에 — 그대로 넘긴 워커 기록은 모두 제 본문
//!   body-r4-frames        같은 주소를 주 프레임·같은 출처 iframe·다른 사이트 iframe 이 한꺼번에
//!   body-r4-cache         디스크 캐시·304 다시 확인·prefetch·preload 가 같은 주소의 네트워크 요청과 섞임(prefetch 는 `no_body` 가 아니다 — N1)
//!   body-r4-spa           SPA 꼴(서로 다른 JSON 동시·같은 주소 동시·폴링·이미지·같은 주소 POST 둘·캐시되는 설정·관계없는 fetch 를 하는 워커) — 잡은 비율,
//!                         페이지 JSON 은 97 % 이상(본문 수 버스트 — 고치기 전 134/152)
//!   body-r4-nav-pending   큰 본문 20 개가 기다리는 동안 다른 문서로 이동 — 기대한 시작마다 끝이 꼭 하나

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const net_fields = protocol.net_fields;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const rec_tab: u64 = 95;
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

var port: u16 = 0;
var counter = std.atomic.Value(u64).init(1);

fn startServer() !void {
    const fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
    if (listen(fd, 256) != 0) return error.ListenFailed;
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

const read_js = "function F(u,o){return fetch(u,o).then(function(r){return r.text()}).catch(function(){})}";
const read_js_fmt = "function F(u,o){{return fetch(u,o).then(function(r){{return r.text()}}).catch(function(){{}})}}";
const reg_js = "function reg(next){navigator.serviceWorker.register('/rv4/sw/sw.js',{scope:'/rv4/sw/'}).then(function(){return navigator.serviceWorker.ready}).then(function(){" ++
    "if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}setTimeout(next,200)})}";

const sw_js = "self.addEventListener('install',function(e){self.skipWaiting()});" ++
    "self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
    "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);var p=u.pathname;" ++
    // stale-while-revalidate: 네트워크를 먼저 시작하고 캐시가 있으면 캐시로 답한다(dd 는 10 ms 뒤에).
    "if(p=='/rv4/sw/d'||p=='/rv4/sw/dd'){var net=fetch(e.request).then(function(r){var c=r.clone();return caches.open('v').then(function(ca){return ca.put(e.request,c)}).then(function(){return r})});" ++
    "e.respondWith(caches.open('v').then(function(ca){return ca.match(e.request)}).then(function(m){if(!m)return net;if(p=='/rv4/sw/d')return m;return new Promise(function(res){setTimeout(function(){res(m)},10)})}));return}" ++
    // 대조: 캐시로 답한 **뒤에** 네트워크로 캐시를 고친다(waitUntil — 기록은 페이지의 응답 뒤에 시작한다).
    "if(p=='/rv4/sw/late'){e.respondWith(caches.open('v').then(function(ca){return ca.match(e.request)}).then(function(m){" ++
    "var upd=function(){return fetch(e.request).then(function(r){var c=r.clone();return caches.open('v').then(function(ca){return ca.put(e.request,c)}).then(function(){return r})})};" ++
    "if(!m)return upd();e.waitUntil(new Promise(function(res){setTimeout(res,30)}).then(upd));return m}));return}" ++
    "if(p=='/rv4/sw/syn'){e.respondWith(fetch(e.request).then(function(r){return r.text()}).then(function(t){return new Response('{\"n\":\"syn'+t.length+'\"}',{headers:{'content-type':'application/json'}})}));return}" ++
    "if(p=='/rv4/sw/pt'){if(e.request.headers.get('x-mode')=='fb')return;e.respondWith(fetch(e.request));return}" ++
    "});";

fn data(conn: c_int, head: []const u8, cache: []const u8, etag: bool) void {
    if (etag and headerValue(head, "if-none-match").len > 0) {
        return replyC(conn, "304 Not Modified", "application/json", cache, "ETag: \"e1\"\r\nAccess-Control-Allow-Origin: *\r\n", "");
    }
    const n = counter.fetchAdd(1, .monotonic);
    var bb: [64]u8 = undefined;
    var xb: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{n}) catch return;
    const extra = std.fmt.bufPrint(&xb, "X-Body: {d}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Expose-Headers: X-Body\r\n{s}", .{ n, if (etag) "ETag: \"e1\"\r\n" else "" }) catch return;
    replyC(conn, "200 OK", "application/json", cache, extra, body);
}

fn serveOne(conn: c_int) void {
    defer _ = std.c.close(conn);
    var req: [8192]u8 = undefined;
    const n = std.c.read(conn, &req, req.len);
    if (n <= 0) return;
    const head = req[0..@intCast(n)];
    const line_end = std.mem.indexOfScalar(u8, head, '\r') orelse return;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    _ = parts.next();
    const target = parts.next() orelse return;
    const qi = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. qi orelse target.len];
    const html = "text/html; charset=utf-8";
    var pb: [8192]u8 = undefined;
    if (std.mem.eql(u8, path, "/rv4/blank")) return reply(conn, html, "<!doctype html><title>blank</title>blank");
    if (std.mem.eql(u8, path, "/rv4/d") or std.mem.eql(u8, path, "/rv4/sw/d") or std.mem.eql(u8, path, "/rv4/sw/dd") or std.mem.eql(u8, path, "/rv4/sw/syn") or std.mem.eql(u8, path, "/rv4/sw/late") or std.mem.eql(u8, path, "/rv4/sw/pt"))
        return data(conn, head, "no-store", false);
    if (std.mem.eql(u8, path, "/rv4/dc")) return data(conn, head, "max-age=60", false);
    if (std.mem.eql(u8, path, "/rv4/de")) return data(conn, head, "no-cache", true);
    if (std.mem.eql(u8, path, "/rv4/st")) {
        const q = target[(qi orelse target.len)..];
        const nn = counter.fetchAdd(1, .monotonic);
        var bb: [64]u8 = undefined;
        var xb: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{nn}) catch return;
        const extra = std.fmt.bufPrint(&xb, "X-Body: {d}\r\n", .{nn}) catch return;
        if (std.mem.startsWith(u8, q, "?404")) return replyC(conn, "404 Not Found", "application/json", "no-store", extra, body);
        if (std.mem.startsWith(u8, q, "?500")) return replyC(conn, "500 Internal Server Error", "application/json", "no-store", extra, body);
        if (std.mem.startsWith(u8, q, "?204")) return replyC(conn, "204 No Content", "application/json", "no-store", extra, "");
        if (std.mem.startsWith(u8, q, "?206")) {
            var x2: [256]u8 = undefined;
            const e2 = std.fmt.bufPrint(&x2, "X-Body: {d}\r\nContent-Range: bytes 0-{d}/{d}\r\n", .{ nn, body.len - 1, body.len }) catch return;
            return replyC(conn, "206 Partial Content", "application/json", "no-store", e2, body);
        }
        if (std.mem.startsWith(u8, q, "?301")) {
            var x3: [256]u8 = undefined;
            const e3 = std.fmt.bufPrint(&x3, "Location: /rv4/d?after301{s}\r\n", .{q[4..]}) catch return;
            return replyC(conn, "301 Moved Permanently", "text/plain", "max-age=600", e3, "");
        }
        return replyC(conn, "200 OK", "application/json", "no-store", extra, body);
    }
    // 렌더러가 7 초 바쁘다(본문 호출의 답이 시한 5 초를 넘는다) — 그 사이 끝난 다른 요청들.
    if (std.mem.eql(u8, path, "/rv4/spin")) return reply(conn, html, "<!doctype html><title>sp</title><script>" ++ read_js ++
        "function spin(ms){var t=performance.now();while(performance.now()-t<ms){}}" ++
        "setTimeout(function(){F('/rv4/d?sp_a');F('/rv4/d?sp_b');F('/rv4/d?sp_c').then(function(){spin(7000);F('/rv4/d?sp_after').then(function(){document.title='spdone'})})},300)</script>sp");
    if (std.mem.eql(u8, path, "/rv4/status")) return reply(conn, html, "<!doctype html><title>st</title><script>" ++ read_js ++
        "var k=0;function step(){if(k>=10){document.title='stdone';return}var j=k;k++;" ++
        "F('/rv4/st?404_'+j);F('/rv4/st?500_'+j);F('/rv4/st?204_'+j);F('/rv4/st?206_'+j,{headers:{Range:'bytes=0-'}});F('/rv4/st?head_'+j,{method:'HEAD'});" ++
        "F('/rv4/st?301_'+(j%2)).then(function(){return F('/rv4/st?301_'+(j%2))});" ++
        "setTimeout(step,400)}setTimeout(step,300)</script>st");
    if (std.mem.eql(u8, path, "/rv4/img")) return reply(conn, "image/png", "\x89PNG\r\n\x1a\nxxxxxxxx");
    if (std.mem.eql(u8, path, "/rv4/sw/sw.js")) return reply(conn, "application/javascript", sw_js);
    // 서비스 워커 페이지들(범위 /rv4/sw/).
    if (std.mem.eql(u8, path, "/rv4/sw/swr")) return reply(conn, html, "<!doctype html><title>swr</title><script>" ++ read_js ++ reg_js ++
        "var k=0;function step(){if(k>=40){document.title='swrdone';return}var u=k<20?'/rv4/sw/d':'/rv4/sw/dd';k++;F(u).then(function(){setTimeout(step,150)})}reg(step)</script>swr");
    if (std.mem.eql(u8, path, "/rv4/sw/latep")) return reply(conn, html, "<!doctype html><title>late</title><script>" ++ read_js ++ reg_js ++
        "var k=0;function step(){if(k>=20){document.title='latedone';return}k++;F('/rv4/sw/late').then(function(){setTimeout(step,150)})}reg(step)</script>late");
    if (std.mem.eql(u8, path, "/rv4/js")) return data(conn, head, "max-age=60", false);
    if (std.mem.eql(u8, path, "/rv4/memc")) return reply(conn, html, "<!doctype html><title>m</title><script>" ++ read_js ++
        "function sc(u,cb){var s=document.createElement('script');s.src=u;s.onload=s.onerror=cb||null;document.head.appendChild(s)}" ++
        "var k=0;function step(){if(k>=15){document.title='mdone';return}var u='/rv4/js?m'+k;k++;" ++
        "sc(u,function(){sc(u);F(u,{cache:'no-store'});F(u)});setTimeout(step,300)}setTimeout(step,300)</script>m");
    if (std.mem.eql(u8, path, "/rv4/sw/synp")) return reply(conn, html, "<!doctype html><title>syn</title><script>" ++ read_js ++ reg_js ++
        "var k=0;function step(){if(k>=15){document.title='syndone';return}k++;F('/rv4/sw/syn').then(function(){setTimeout(step,120)})}reg(step)</script>syn");
    if (std.mem.eql(u8, path, "/rv4/sw/mixp")) return reply(conn, html, "<!doctype html><title>mix</title><script>" ++ read_js ++ reg_js ++
        "var k=0;function step(){if(k>=20){document.title='mixdone';return}var u='/rv4/sw/pt?r'+k;k++;" ++
        "F(u,{headers:{'x-mode':'fb'}});F(u);F(u,{headers:{'x-mode':'fb'}});F(u);setTimeout(step,200)}reg(step)</script>mix");
    // 주 프레임·같은 출처 iframe·다른 사이트(localhost) iframe 이 같은 주소를 한꺼번에.
    if (std.mem.eql(u8, path, "/rv4/frames")) {
        const page = std.fmt.bufPrint(&pb, "<!doctype html><title>fr</title><iframe id=a src='/rv4/fr'></iframe><iframe id=b src='http://localhost:{d}/rv4/fr'></iframe><script>" ++ read_js_fmt ++
            "var ready=0;onmessage=function(e){{if(e.data=='ready'){{ready++;if(ready==2)setTimeout(step,300)}}}};" ++
            "var k=0;function step(){{if(k>=30){{document.title='fdone';return}}var u='http://127.0.0.1:{d}/rv4/d?f'+k;" ++
            "a.contentWindow.postMessage(u,'*');b.contentWindow.postMessage(u,'*');F(u);k++;setTimeout(step,150)}}</script>fr", .{ port, port }) catch return;
        return reply(conn, html, page);
    }
    if (std.mem.eql(u8, path, "/rv4/fr")) return reply(conn, html, "<!doctype html><script>" ++ read_js ++ "onmessage=function(e){F(e.data)};parent.postMessage('ready','*')</script>fr");
    // 캐시가 섞인 같은 주소.
    if (std.mem.eql(u8, path, "/rv4/cache")) return reply(conn, html, "<!doctype html><title>c</title><script>" ++ read_js ++
        "function link(rel,href,asv){var l=document.createElement('link');l.rel=rel;l.href=href;if(asv){l.as=asv;l.crossOrigin='anonymous'}document.head.appendChild(l)}" ++
        "var k=0;function step(){if(k>=15){document.title='cdone';return}var j=k;k++;" ++
        "F('/rv4/dc?a'+j).then(function(){F('/rv4/dc?a'+j);F('/rv4/dc?a'+j,{cache:'no-store'})});" ++
        "F('/rv4/de?b'+j).then(function(){F('/rv4/de?b'+j);F('/rv4/de?b'+j,{cache:'reload'})});" ++
        "link('prefetch','/rv4/dc?c'+j);F('/rv4/dc?c'+j);" ++
        "link('preload','/rv4/dc?d'+j,'fetch');F('/rv4/dc?d'+j);" ++
        "setTimeout(step,250)}setTimeout(step,300)</script>c");
    // SPA 꼴.
    if (std.mem.eql(u8, path, "/rv4/spa")) return reply(conn, html, "<!doctype html><title>s</title><script>" ++ read_js ++
        "var w=new Worker('/rv4/spa_w.js');var poll=setInterval(function(){F('/rv4/d?poll')},250);" ++
        "var r=0;function step(){if(r>=12){clearInterval(poll);w.terminate();document.title='sdone';return}" ++
        "for(var i=0;i<6;i++)F('/rv4/d?u'+r+'_'+i);" ++
        "F('/rv4/d?me');F('/rv4/d?me');F('/rv4/d?me');" ++
        "F('/rv4/d?gql',{method:'POST',body:'{\"q\":'+r+'}'});F('/rv4/d?gql',{method:'POST',body:'{\"q\":0}'});" ++
        "for(var i=0;i<4;i++){var im=new Image();im.src='/rv4/img?'+r+'_'+i}" ++
        "F('/rv4/dc?cfg');r++;setTimeout(step,400)}setTimeout(step,300)</script>s");
    if (std.mem.eql(u8, path, "/rv4/spa_w.js")) return reply(conn, "application/javascript", "setInterval(function(){fetch('/rv4/d?wk'+Math.random()).then(function(r){return r.text()})},100);");
    // 큰 본문 20 개.
    if (std.mem.eql(u8, path, "/rv4/big")) return reply(conn, html, "<!doctype html><title>g</title><script>" ++ read_js ++
        "for(var j=0;j<20;j++)F('/rv4/bigj?'+j);</script>g");
    if (std.mem.eql(u8, path, "/rv4/bigj")) {
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
        return;
    }
    return reply(conn, "text/plain", "x");
}

const Begin = struct { browser: u64, request: u64, url: []u8, expected: bool, flags: msg.NetFlags, method: []u8 };
const Body = struct { browser: u64, request: u64, data: std.ArrayList(u8) = .empty, ends: usize = 0, state: msg.NetBodyState = .unavailable, xbody: []u8 = &.{}, status: u16 = 0, decoded: u64 = 0 };

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    begins: std.ArrayList(Begin) = .empty,
    bodies: std.ArrayList(Body) = .empty,
    created: std.AutoHashMapUnmanaged(u64, void) = .empty,
    closed: std.AutoHashMapUnmanaged(u64, void) = .empty,
    loads: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    states: std.AutoHashMapUnmanaged(u64, msg.NetRecordStatus) = .empty,
    titles: std.AutoHashMapUnmanaged(u64, []u8) = .empty,

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
            .net_begin => |v| self.begins.append(self.gpa, .{ .browser = v.browser, .request = v.request, .url = self.gpa.dupe(u8, v.url) catch &.{}, .expected = v.flags2.body_expected, .flags = v.flags, .method = self.gpa.dupe(u8, v.method) catch &.{} }) catch {},
            .net_response => |v| {
                const b = self.body(v.browser, v.request);
                b.status = v.status;
                var it = net_fields.HeaderIterator.init(v.headers);
                while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "x-body")) {
                    b.xbody = self.gpa.dupe(u8, h.value) catch &.{};
                };
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
            },
            .net_record_state => |v| self.states.put(self.gpa, v.browser, v.status) catch {},
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
fn isClosed(r: *Run, id: u64) bool {
    return r.closed.contains(id);
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
    sub: usize = 0,
    sub_own: usize = 0,
    main_own: usize = 0,
    states: [16]usize = @splat(0),
    notes: [700]u8 = undefined,
    notes_len: usize = 0,

    fn note(t: *Tally, comptime fmt: []const u8, args: anytype) void {
        const piece = std.fmt.bufPrint(t.notes[t.notes_len..], fmt, args) catch return;
        t.notes_len += piece.len;
    }
};

fn tally(r: *Run, browser: u64, at: usize, needle: []const u8, method: ?[]const u8) Tally {
    var t: Tally = .{};
    for (r.begins.items[at..]) |b| if (b.browser == browser and std.mem.indexOf(u8, b.url, needle) != null) {
        if (method) |m| if (!std.mem.eql(u8, b.method, m)) continue;
        t.total += 1;
        if (b.expected) t.expected += 1;
        if (b.flags.service_worker) t.sw += 1;
        if (b.flags.subframe) t.sub += 1;
        const x = r.body(browser, b.request);
        if (x.ends == 1) t.states[@backingInt(x.state)] += 1;
        if (b.expected and x.ends != 1) t.no_end += 1;
        if (x.ends == 1 and x.state == .captured) {
            if (b.flags.service_worker) t.sw_captured += 1;
            var want: [64]u8 = undefined;
            const wnt = std.fmt.bufPrint(&want, "{{\"n\":\"{s}\"}}", .{x.xbody}) catch "";
            if (x.xbody.len == 0) {
                t.unknown += 1;
                t.note(" [req {d} {s} status {d} no X-Body got {s}]", .{ b.request, b.url[@min(b.url.len, 22)..], x.status, x.data.items[0..@min(x.data.items.len, 20)] });
            } else if (std.mem.eql(u8, x.data.items, wnt)) {
                t.own += 1;
                if (b.flags.subframe) t.sub_own += 1 else t.main_own += 1;
            } else {
                t.wrong += 1;
                t.note(" [req {d}{s} X-Body {s} got {s}]", .{ b.request, if (b.flags.service_worker) " sw" else if (b.flags.subframe) " sub" else "", x.xbody, x.data.items[0..@min(x.data.items.len, 20)] });
            }
        } else if (x.ends == 1 and x.state == .ambiguous) {
            t.ambiguous += 1;
        } else {
            t.other += 1;
            if (t.other <= 6) t.note(" [other req {d} {s} {s} decoded {d} status {d}]", .{ b.request, b.url[@min(b.url.len, 22)..], if (x.ends == 1) @tagName(x.state) else "(no end)", x.decoded, x.status });
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
    return std.fmt.bufPrint(buf, "CEF requests {d} (body_expected {d}, sw {d}, subframe {d}) · own body {d} (main {d} sub {d}) · WRONG {d} · captured w/o X-Body {d} · ambiguous {d} · other {d} · no/several ends {d} · sw captured {d} · states{s} ·{s}", .{ t.total, t.expected, t.sw, t.sub, t.own, t.main_own, t.sub_own, t.wrong, t.unknown, t.ambiguous, t.other, t.no_end, t.sw_captured, stateLine(t, sl), t.notes[0..t.notes_len] }) catch "";
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    try startServer();
    var detail: [3000]u8 = undefined;
    var sl: [400]u8 = undefined;
    const log_env: []const [*:0]const u8 = if (std.c.getenv("MARU_WEB_TEST_BODY_LOG") != null) &.{"MARU_WEB_TEST_BODY_LOG=1"} else &.{};
    var host = try Host.spawnWith(host_path, profile_arg, null, log_env);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    var r: Run = .{ .host = &host, .gpa = gpa };
    const size: msg.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
    var u: [256]u8 = undefined;
    try host.send(.{ .create_browser = .{ .browser = rec_tab, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/rv4/blank", .{port}) } });
    if (!r.waitFor(wait_ms, rec_tab, createdAndLoaded)) return error.BrowserNotCreated;
    try host.send(.{ .net_watch = .{ .browser = rec_tab, .on = true, .full = true, .any_host = true } });
    try host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = 1 } });
    _ = r.waitFor(5000, rec_tab, hasState);

    // ── 서비스 워커 ──
    {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv4/sw/swr");
        const done = r.pumpTitle(rec_tab, "swrdone", 30_000);
        r.pump(4000);
        const ta = tally(&r, rec_tab, at, "/rv4/sw/d", null);
        report(done and ta.wrong == 0, "body-r4-sw-swr", lineOf(&ta, &detail, &sl));
    }
    {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv4/sw/latep");
        const done = r.pumpTitle(rec_tab, "latedone", 20_000);
        r.pump(4000);
        const t = tally(&r, rec_tab, at, "/rv4/sw/late", null);
        report(done and t.wrong == 0, "body-r4-sw-cache-then-update-control", lineOf(&t, &detail, &sl));
    }
    {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv4/memc");
        const done = r.pumpTitle(rec_tab, "mdone", 20_000);
        r.pump(4000);
        const t = tally(&r, rec_tab, at, "/rv4/js?m", null);
        report(done and t.wrong == 0, "body-r4-cache-memory", lineOf(&t, &detail, &sl));
    }
    {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv4/sw/synp");
        const done = r.pumpTitle(rec_tab, "syndone", 20_000);
        r.pump(4000);
        const t = tally(&r, rec_tab, at, "/rv4/sw/syn", null);
        report(done and t.wrong == 0, "body-r4-sw-synth", lineOf(&t, &detail, &sl));
    }
    {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv4/sw/mixp");
        const done = r.pumpTitle(rec_tab, "mixdone", 20_000);
        r.pump(4000);
        const t = tally(&r, rec_tab, at, "/rv4/sw/pt?", null);
        // 그대로 넘긴 워커 기록(출처 network)은 여전히 제 본문을 받는다 — 서비스 워커 갈래를 닫지 않았다.
        report(done and t.wrong == 0 and t.sw > 0 and t.sw_captured == t.sw, "body-r4-sw-mixed", lineOf(&t, &detail, &sl));
    }
    // ── 프레임 ──
    {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv4/frames");
        const done = r.pumpTitle(rec_tab, "fdone", 20_000);
        r.pump(4000);
        const t = tally(&r, rec_tab, at, "/rv4/d?f", null);
        report(done and t.wrong == 0, "body-r4-frames", lineOf(&t, &detail, &sl));
    }
    // ── 캐시 ──
    {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv4/cache");
        const done = r.pumpTitle(rec_tab, "cdone", 20_000);
        r.pump(4000);
        inline for (.{ .{ "/rv4/dc?a", "body-r4-cache-disk" }, .{ "/rv4/de?b", "body-r4-cache-304" }, .{ "/rv4/dc?c", "body-r4-cache-prefetch" }, .{ "/rv4/dc?d", "body-r4-cache-preload" } }) |c| {
            const t = tally(&r, rec_tab, at, c[0], null);
            // N1: 서버가 바이트를 보낸 응답은 「0 바이트」(`no_body`)가 아니다 — prefetch 는 CDP 가 빈 본문을 줬다(고치기 전 `no_body` 14/15). CEF 끝이
            // 본문 호출의 답보다 늦으면 아직 모른다(알고 둔 틈) — 실측에서는 CEF 끝이 늘 먼저였다(14/14 두 번).
            report(done and t.wrong == 0 and t.states[@backingInt(msg.NetBodyState.no_body)] == 0, c[1], lineOf(&t, &detail, &sl));
        }
    }
    // ── 상태 ──
    {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv4/status");
        const done = r.pumpTitle(rec_tab, "stdone", 20_000);
        r.pump(4000);
        inline for (.{ .{ "/rv4/st?404", "body-r4-status-404", null }, .{ "/rv4/st?500", "body-r4-status-500", null }, .{ "/rv4/st?204", "body-r4-status-204", null }, .{ "/rv4/st?206", "body-r4-status-206", null }, .{ "/rv4/st?head", "body-r4-status-head", "HEAD" }, .{ "/rv4/st?301", "body-r4-status-301-cached", null } }) |c| {
            const t = tally(&r, rec_tab, at, c[0], c[2]);
            report(done and t.wrong == 0, c[1], lineOf(&t, &detail, &sl));
        }
    }
    // ── 바쁜 렌더러 ──
    {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv4/spin");
        const done = r.pumpTitle(rec_tab, "spdone", 20_000);
        r.pump(7000);
        const t = tally(&r, rec_tab, at, "/rv4/d?sp", null);
        report(done and t.wrong == 0 and t.no_end == 0, "body-r4-busy-renderer", lineOf(&t, &detail, &sl));
    }
    // ── SPA ──
    {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv4/spa");
        const done = r.pumpTitle(rec_tab, "sdone", 20_000);
        r.pump(4000);
        inline for (.{ .{ "/rv4/d?u", "body-r4-spa-distinct", null }, .{ "/rv4/d?me", "body-r4-spa-same-url-x3", null }, .{ "/rv4/d?poll", "body-r4-spa-poll", null }, .{ "/rv4/d?gql", "body-r4-spa-post-x2", "POST" }, .{ "/rv4/dc?cfg", "body-r4-spa-cacheable", null }, .{ "/rv4/d?wk", "body-r4-spa-worker", null }, .{ "/rv4/d?", "body-r4-spa-all-json", null } }) |c| {
            const t = tally(&r, rec_tab, at, c[0], c[2]);
            var lb: [3000]u8 = undefined;
            report(done and t.wrong == 0, c[1], std.fmt.bufPrint(&detail, "capture rate {d}/{d} · {s}", .{ t.own, t.total, lineOf(&t, &lb, &sl) }) catch "");
        }
        // 페이지 JSON(`/rv4/d?` 에서 워커의 것을 뺀 것 — 서로 다른·같은 주소·폴링·POST): 97 % 이상을 잡는다(W9d② 적대 리뷰 4 회차 — 버스트 20 일 때
        // 134/152 = 88 %, 잃은 것은 모두 `busy`). 워커의 것은 설계상 `unmatched`(UB4).
        const all = tally(&r, rec_tab, at, "/rv4/d?", null);
        const wk = tally(&r, rec_tab, at, "/rv4/d?wk", null);
        const page_total = all.total - wk.total;
        const page_own = all.own - wk.own;
        report(done and all.wrong == 0 and page_total > 0 and page_own * 100 >= page_total * 97, "body-r4-spa-page-json", std.fmt.bufPrint(&detail, "capture rate {d}/{d} (need 97 %) · busy {d}", .{ page_own, page_total, all.states[@backingInt(msg.NetBodyState.busy)] - wk.states[@backingInt(msg.NetBodyState.busy)] }) catch "");
    }
    // ── 이동으로 기다리던 본문 ──
    {
        const id: u64 = 96;
        try host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/rv4/blank", .{port}) } });
        if (!r.waitFor(wait_ms, id, createdAndLoaded)) return error.BrowserNotCreated;
        try host.send(.{ .net_watch = .{ .browser = id, .on = true, .full = true, .any_host = true } });
        try host.send(.{ .net_record = .{ .browser = id, .on = true, .session = 9 } });
        _ = r.waitFor(5000, id, hasState);
        const at = r.begins.items.len;
        try r.navigate(id, "/rv4/big");
        r.pump(700);
        try r.navigate(id, "/rv4/blank?after");
        r.pump(8000);
        var expected: usize = 0;
        var one: usize = 0;
        var zero: usize = 0;
        var many: usize = 0;
        for (r.begins.items[at..]) |b| if (b.browser == id and b.expected) {
            expected += 1;
            const x = r.body(id, b.request);
            if (x.ends == 1) one += 1 else if (x.ends == 0) zero += 1 else many += 1;
        };
        const t = tally(&r, id, at, "/rv4/bigj", null);
        report(expected > 0 and one == expected, "body-r4-nav-pending", std.fmt.bufPrint(&detail, "expected begins {d} · one end {d} · no end {d} · several {d} · bigj states{s}", .{ expected, one, zero, many, stateLine(&t, &sl) }) catch "");
    }
}
