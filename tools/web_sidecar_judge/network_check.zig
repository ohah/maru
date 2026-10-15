//! W9d① 판정 — 실제 CEF 154 의 자원 요청 처리기로 지켜보는 탭의 요청이 maru 에 오는가(docs/plans/web-osr-backend.md 「W9d① 결정」).
//! 판정자가 **maru 역할**로 `net_watch` 를 보내고 `net_*` 알림을 모은다. 이 판정의 서버는 따로 띄운다(연결마다 스레드 — 서비스 워커·iframe·
//! 쏟아짐이 한 스레드 서버를 묶지 않게). `127.0.0.1:<포트>` 와 `localhost:<포트>` 는 다른 사이트다.
//!
//!   net-attribution   주 프레임 문서(main_frame·document·이동), 다른 사이트 iframe 문서(subframe·iframe — initiator 는 부모), 그 iframe 안의
//!                     요청(subframe·initiator 는 iframe 출처 — 다른 사이트 iframe 의 요청), 전용 worker 의 fetch(initiator 는 페이지 출처)
//!   net-headers-full  설정 켬: 페이지가 단 `Authorization`, 쿠키(`Cookie` — 앞 응답이 심었다), 응답의 `set-cookie` 값이 그대로 온다
//!   net-redirect      301 → 302(다른 사이트) 리다이렉트는 한 요청 번호에 홉 둘, 마지막 응답 200 과 끝 하나
//!   net-unwatched     지켜보지 않는 탭의 요청은 하나도 오지 않는다
//!   net-headers-off   설정 끔(`full` 거짓, grant 호스트 127.0.0.1): 쿠키·인증 값은 비고(`stripped`), 허용 목록(`Accept`)은 남고, 다른 사이트
//!                     요청은 헤더가 없다, 주소의 사용자 정보는 지운다
//!   net-userinfo-full 설정 켬: 주소의 사용자 정보(`user:pass@`)가 보인다
//!   net-service-worker 서비스 워커가 다스리는 페이지의 fetch 는 브라우저가 없는 요청으로 와(공유 context 처리기) 그 출처를 연 지켜보는 탭에
//!                     `service_worker` 로 붙는다
//!   net-flood         3000 요청을 쏟으면 문이 대부분을 넘기고(`net_dropped`) 적은 수는 버스트 근처다
//!   net-watch-off     지켜보기를 끄면 그 뒤 요청은 오지 않는다

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const net_fields = protocol.net_fields;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const watched: u64 = 61;
const unwatched: u64 = 62;
const wait_ms = 15_000;

// ── 이 판정의 서버 ────────────────────────────────────────────────────────────────────────────────────────

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

var server_port: u16 = 0;
pub var flood_served = std.atomic.Value(u32).init(0);

fn startServer() !u16 {
    const fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
    if (listen(fd, 128) != 0) return error.ListenFailed;
    var len: u32 = @sizeOf(SockaddrIn);
    if (getsockname(fd, &addr, &len) != 0) return error.SocketFailed;
    server_port = std.mem.bigToNative(u16, addr.port);
    const t = try std.Thread.spawn(.{}, acceptLoop, .{fd});
    t.detach();
    return server_port;
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

fn reply(conn: c_int, status: []const u8, ctype: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [1024]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\n{s}Connection: close\r\n\r\n", .{ status, ctype, body.len, extra }) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, body.ptr, body.len);
}

fn serveOne(conn: c_int) void {
    defer _ = std.c.close(conn);
    var req: [8192]u8 = undefined;
    const n = std.c.read(conn, &req, req.len);
    if (n <= 0) return;
    const line_end = std.mem.indexOfScalar(u8, req[0..@intCast(n)], '\r') orelse return;
    var parts = std.mem.splitScalar(u8, req[0..line_end], ' ');
    _ = parts.next();
    const target = parts.next() orelse return;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const p = server_port;
    var bb: [4096]u8 = undefined;
    var xb: [512]u8 = undefined;
    const html = "text/html; charset=utf-8";
    if (std.mem.eql(u8, path, "/n/blank")) return reply(conn, "200 OK", html, "", "<!doctype html><title>blank</title>blank");
    if (std.mem.eql(u8, path, "/n/main")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>net-main</title><iframe src=\"http://localhost:{d}/n/frame\"></iframe><img src=\"/n/redir1\">" ++
            "<script>fetch('/n/api',{{headers:{{'Authorization':'Bearer page-token','X-Judge':'1'}}}});" ++
            "fetch('http://localhost:{d}/n/other').catch(function(){{}});new Worker('/n/worker.js');</script>", .{ p, p }) catch return;
        return reply(conn, "200 OK", html, "Set-Cookie: sid=judge-secret; Path=/\r\n", body);
    }
    if (std.mem.eql(u8, path, "/n/frame")) return reply(conn, "200 OK", html, "", "<!doctype html><title>frame</title><script>fetch('/n/in-frame')</script>");
    if (std.mem.eql(u8, path, "/n/worker.js")) return reply(conn, "200 OK", "application/javascript", "", "fetch('/n/from-worker')");
    if (std.mem.eql(u8, path, "/n/redir1")) return reply(conn, "301 Moved Permanently", "text/plain", "Location: /n/redir2\r\n", "");
    if (std.mem.eql(u8, path, "/n/redir2")) {
        const loc = std.fmt.bufPrint(&xb, "Location: http://localhost:{d}/n/final\r\n", .{p}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/n/final")) return reply(conn, "200 OK", "image/svg+xml", "", "<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'/>");
    if (std.mem.eql(u8, path, "/n/api")) return reply(conn, "200 OK", "application/json", "Set-Cookie: api=1; Path=/\r\n", "{\"ok\":1}");
    if (std.mem.eql(u8, path, "/n/other")) return reply(conn, "200 OK", "text/plain", "Access-Control-Allow-Origin: *\r\nSet-Cookie: other=secret; Path=/\r\n", "other");
    if (std.mem.eql(u8, path, "/n/sw-page")) return reply(conn, "200 OK", html, "", "<!doctype html><title>sw</title><script>" ++
        "navigator.serviceWorker.register('/n/sw.js',{scope:'/n/'}).then(function(){return navigator.serviceWorker.ready}).then(function(){" ++
        "if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}" ++
        "fetch('/n/sw-fetch?'+Date.now()).then(function(){document.title='sw-done'})})</script>");
    if (std.mem.eql(u8, path, "/n/sw.js")) return reply(conn, "200 OK", "application/javascript", "", "self.addEventListener('install',function(e){self.skipWaiting()});" ++
        "self.addEventListener('activate',function(e){e.waitUntil(self.clients.claim())});self.addEventListener('fetch',function(e){e.respondWith(fetch(e.request))});");
    if (std.mem.eql(u8, path, "/n/flood")) return reply(conn, "200 OK", html, "", "<!doctype html><title>flood</title><script>for(var i=0;i<3000;i++)fetch('/n/f?'+i).catch(function(){})</script>");
    if (std.mem.eql(u8, path, "/n/f")) {
        _ = flood_served.fetchAdd(1, .monotonic);
        return reply(conn, "204 No Content", "text/plain", "", "");
    }
    return reply(conn, "200 OK", "text/plain", "", "x");
}

// ── 모은 알림 ────────────────────────────────────────────────────────────────────────────────────────────

const Rec = struct {
    tag: msg.Tag,
    browser: u64,
    request: u64,
    flags: msg.NetFlags = .{},
    hop: msg.NetHopFlags = .{},
    resource_type: u8 = 0,
    status: u16 = 0,
    url: []u8 = &.{},
    initiator: []u8 = &.{},
    site: []u8 = &.{},
    headers: []u8 = &.{},
    header_count: u8 = 0,
    outcome: msg.NetOutcome = .success,
    count: u32 = 0,

    fn header(self: *const Rec, name: []const u8) ?[]const u8 {
        var it = net_fields.HeaderIterator.init(.{ .count = self.header_count, .bytes = self.headers });
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    recs: std.ArrayList(Rec) = .empty,
    loads: [2]u32 = .{ 0, 0 },
    created: [2]bool = .{ false, false },

    fn slot(id: u64) ?usize {
        return if (id == watched) 0 else if (id == unwatched) 1 else null;
    }

    fn dupe(self: *Run, s: []const u8) []u8 {
        return self.gpa.dupe(u8, s) catch &.{};
    }

    fn take(self: *Run, m: msg.Message) void {
        const r: ?Rec = switch (m) {
            .net_begin => |v| .{ .tag = .net_begin, .browser = v.browser, .request = v.request, .flags = v.flags, .resource_type = v.resource_type, .url = self.dupe(v.url), .initiator = self.dupe(v.initiator), .site = self.dupe(v.site), .headers = self.dupe(v.headers.bytes), .header_count = v.headers.count },
            .net_redirect => |v| .{ .tag = .net_redirect, .browser = v.browser, .request = v.request, .hop = v.flags, .status = v.status, .url = self.dupe(v.url), .headers = self.dupe(v.headers.bytes), .header_count = v.headers.count },
            .net_response => |v| .{ .tag = .net_response, .browser = v.browser, .request = v.request, .hop = v.flags, .status = v.status, .headers = self.dupe(v.headers.bytes), .header_count = v.headers.count },
            .net_end => |v| .{ .tag = .net_end, .browser = v.browser, .request = v.request, .outcome = v.outcome },
            .net_dropped => |v| .{ .tag = .net_dropped, .browser = v.browser, .request = 0, .count = v.count },
            .browser_created => |id| blk: {
                if (slot(id)) |i| self.created[i] = true;
                break :blk null;
            },
            .load_finished => |v| blk: {
                if (slot(v.browser)) |i| self.loads[i] += 1;
                break :blk null;
            },
            else => null,
        };
        if (r) |rec| self.recs.append(self.gpa, rec) catch {};
    }

    fn pump(self: *Run, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            const m = (self.host.next(20) catch null) orelse continue;
            self.take(m);
        }
    }

    fn untilCreated(self: *Run, i: usize) bool {
        const deadline = os.nowMs() + wait_ms;
        while (os.nowMs() < deadline and !self.created[i]) {
            const m = (self.host.next(50) catch null) orelse continue;
            self.take(m);
        }
        return self.created[i];
    }

    fn untilLoads(self: *Run, i: usize, n: u32) bool {
        const deadline = os.nowMs() + wait_ms;
        while (os.nowMs() < deadline and self.loads[i] < n) {
            const m = (self.host.next(50) catch null) orelse continue;
            self.take(m);
        }
        return self.loads[i] >= n;
    }

    fn mark(self: *const Run) usize {
        return self.recs.items.len;
    }

    /// `from` 뒤의 begin 중 주소에 `needle` 이 든 첫 것.
    fn begin(self: *const Run, from: usize, browser: u64, needle: []const u8) ?*const Rec {
        for (self.recs.items[from..]) |*r| if (r.tag == .net_begin and r.browser == browser and std.mem.indexOf(u8, r.url, needle) != null) return r;
        return null;
    }

    fn countFor(self: *const Run, from: usize, tag: msg.Tag, browser: u64, request: u64) usize {
        var n: usize = 0;
        for (self.recs.items[from..]) |r| if (r.tag == tag and r.browser == browser and (request == 0 or r.request == request)) {
            n += 1;
        };
        return n;
    }

    fn first(self: *const Run, from: usize, tag: msg.Tag, browser: u64, request: u64) ?*const Rec {
        for (self.recs.items[from..]) |*r| if (r.tag == tag and r.browser == browser and r.request == request) return r;
        return null;
    }

    fn navigate(self: *Run, browser: u64, to: []const u8) !void {
        try self.host.send(.{ .navigate = .{ .browser = browser, .url = to } });
    }

    fn watch(self: *Run, on: bool, full: bool) !void {
        var w: msg.NetWatch = .{ .browser = watched, .on = on, .full = full and on };
        if (on) {
            w.host_count = 1;
            w.hosts[0] = "127.0.0.1";
        }
        try self.host.send(.{ .net_watch = w });
    }
};

fn url(buf: []u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ server_port, path }) catch unreachable;
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    _ = try startServer();
    var detail: [900]u8 = undefined;
    var u: [512]u8 = undefined;
    const gpa = std.heap.c_allocator;
    var host = try Host.spawn(host_path, profile_arg);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    var r: Run = .{ .host = &host, .gpa = gpa };
    const size: msg.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
    try host.send(.{ .create_browser = .{ .browser = watched, .size = size, .hidden = false, .url = url(&u, "/n/blank") } });
    try host.send(.{ .create_browser = .{ .browser = unwatched, .size = size, .hidden = false, .url = url(&u, "/n/blank") } });
    if (!r.untilCreated(0) or !r.untilCreated(1)) return error.BrowserNotCreated;
    if (!r.untilLoads(0, 1) or !r.untilLoads(1, 1)) return error.PageNotLoaded;
    try r.watch(true, true);
    r.pump(200);

    // ── 켬: 한 페이지에서 갈래·헤더·리다이렉트 ──
    var at = r.mark();
    try r.navigate(watched, url(&u, "/n/main?full"));
    _ = r.untilLoads(0, 2);
    r.pump(2500);
    {
        const doc = r.begin(at, watched, "/n/main?full");
        const iframe = r.begin(at, watched, "/n/frame");
        const inner = r.begin(at, watched, "/n/in-frame");
        const worker = r.begin(at, watched, "/n/from-worker");
        const doc_ok = if (doc) |d| d.flags.main_frame and d.flags.navigation and d.resource_type == 0 else false;
        // iframe 문서를 부르는 요청은 부모가 일으키지만 CEF 154 는 initiator 를 「null」 로 준다(실측) — 프레임과 종류로 본다.
        const iframe_ok = if (iframe) |d| d.flags.subframe and d.resource_type == 1 and protocol.net_policy.crossSiteIframe(d.flags, d.resource_type, d.url, d.initiator, d.site) else false;
        // 다른 사이트 iframe 안의 요청: initiator 는 iframe 출처, 쿠키의 첫 사이트는 비었다(다른 사이트 문맥 — 실측).
        const inner_ok = if (inner) |d| d.flags.subframe and std.mem.indexOf(u8, d.initiator, "localhost") != null and protocol.net_policy.crossSiteIframe(d.flags, d.resource_type, d.url, d.initiator, d.site) else false;
        const worker_ok = if (worker) |d| !d.flags.service_worker and std.mem.indexOf(u8, d.initiator, "127.0.0.1") != null else false;
        report(doc_ok and iframe_ok and inner_ok and worker_ok, "net-attribution", std.fmt.bufPrint(&detail, "문서 {}(site {s}) · iframe 문서 {}(initiator {s} · site {s} · rt {d}) · iframe 안 {}(initiator {s} · site 「{s}」) · worker {}({s} · rt {d} · main {})", .{
            doc_ok,                                        if (doc) |d| d.site else "-",
            iframe_ok,                                     if (iframe) |d| d.initiator else "-",
            if (iframe) |d| d.site else "-",               if (iframe) |d| d.resource_type else 99,
            inner_ok,                                      if (inner) |d| d.initiator else "-",
            if (inner) |d| d.site else "-",                worker_ok,
            if (worker) |d| d.initiator else "-",          if (worker) |d| d.resource_type else 99,
            if (worker) |d| d.flags.main_frame else false,
        }) catch "");
        const api = r.begin(at, watched, "/n/api");
        const auth = if (api) |a| a.header("Authorization") orelse "" else "";
        const cookie = if (api) |a| a.header("Cookie") orelse "" else "";
        var set_cookie: []const u8 = "";
        if (doc) |d| if (r.first(at, .net_response, watched, d.request)) |resp| {
            set_cookie = resp.header("Set-Cookie") orelse "";
        };
        report(std.mem.eql(u8, auth, "Bearer page-token") and std.mem.indexOf(u8, cookie, "sid=judge-secret") != null and std.mem.indexOf(u8, set_cookie, "judge-secret") != null and !(if (api) |a| a.flags.stripped else true), "net-headers-full", std.fmt.bufPrint(&detail, "Authorization 「{s}」 · Cookie 「{s}」 · set-cookie 「{s}」", .{ auth, cookie, set_cookie }) catch "");
        const redir = r.begin(at, watched, "/n/redir1");
        var hops: usize = 0;
        var second_to_other = false;
        var final_ok = false;
        var ends: usize = 0;
        if (redir) |b| {
            hops = r.countFor(at, .net_redirect, watched, b.request);
            var i: usize = 0;
            for (r.recs.items[at..]) |rec| if (rec.tag == .net_redirect and rec.request == b.request) {
                i += 1;
                if (i == 2) second_to_other = rec.status == 302 and std.mem.indexOf(u8, rec.url, "localhost") != null;
            };
            if (r.first(at, .net_response, watched, b.request)) |resp| final_ok = resp.status == 200;
            ends = r.countFor(at, .net_end, watched, b.request);
        }
        report(redir != null and hops == 2 and second_to_other and final_ok and ends == 1, "net-redirect", std.fmt.bufPrint(&detail, "시작 {} · 홉 {d} · 둘째 302 → 다른 사이트 {} · 마지막 200 {} · 끝 {d}", .{ redir != null, hops, second_to_other, final_ok, ends }) catch "");
    }
    // 지켜보지 않는 탭.
    {
        const before = r.mark();
        try r.navigate(unwatched, url(&u, "/n/main?b"));
        _ = r.untilLoads(1, 2);
        r.pump(1500);
        var any: usize = 0;
        for (r.recs.items[before..]) |rec| if (rec.browser == unwatched) {
            any += 1;
        };
        report(any == 0, "net-unwatched", std.fmt.bufPrint(&detail, "지켜보지 않는 탭의 알림 {d}", .{any}) catch "");
    }
    // ── 켬: 주소의 사용자 정보 ──
    {
        at = r.mark();
        const cred = try std.fmt.bufPrint(&u, "http://judge:pw@127.0.0.1:{d}/n/blank?cred-full", .{server_port});
        try r.navigate(watched, cred);
        r.pump(1500);
        const b = r.begin(at, watched, "cred-full");
        report(if (b) |x| std.mem.indexOf(u8, x.url, "judge:pw@") != null else false, "net-userinfo-full", std.fmt.bufPrint(&detail, "주소 「{s}」", .{if (b) |x| x.url else "-"}) catch "");
    }
    // ── 끔: 덜어 낸 값 ──
    {
        try r.watch(true, false);
        r.pump(100);
        at = r.mark();
        try r.navigate(watched, url(&u, "/n/main?off"));
        r.pump(3000);
        const api = r.begin(at, watched, "/n/api");
        const other = r.begin(at, watched, "localhost");
        const cookie = if (api) |a| a.header("Cookie") else null;
        const auth = if (api) |a| a.header("Authorization") else null;
        const accept_h = if (api) |a| a.header("Accept") else null;
        const api_ok = if (api) |a| a.flags.stripped else false;
        const other_ok = if (other) |o| o.header_count == 0 and o.flags.stripped else false;
        const cred = try std.fmt.bufPrint(&u, "http://judge:pw@127.0.0.1:{d}/n/blank?cred-off", .{server_port});
        const at2 = r.mark();
        try r.navigate(watched, cred);
        r.pump(1500);
        const cb = r.begin(at2, watched, "cred-off");
        const cred_ok = if (cb) |x| std.mem.indexOf(u8, x.url, "judge") == null and x.flags.stripped else false;
        const ok = api_ok and cookie != null and cookie.?.len == 0 and auth != null and auth.?.len == 0 and accept_h != null and accept_h.?.len > 0 and other_ok and cred_ok;
        report(ok, "net-headers-off", std.fmt.bufPrint(&detail, "stripped {} · Cookie 「{?s}」 · Authorization 「{?s}」 · Accept 「{?s}」 · 다른 사이트 헤더 없음 {} · 사용자 정보 지움 {}({s})", .{ api_ok, cookie, auth, accept_h, other_ok, cred_ok, if (cb) |x| x.url else "-" }) catch "");
        try r.watch(true, true);
        r.pump(100);
    }
    // ── 서비스 워커 ──
    {
        at = r.mark();
        try r.navigate(watched, url(&u, "/n/sw-page"));
        r.pump(6000);
        const sw = r.begin(at, watched, "/n/sw-fetch");
        const ok = if (sw) |s| s.flags.service_worker and !s.flags.main_frame and !s.flags.subframe and std.mem.indexOf(u8, s.initiator, "127.0.0.1") != null else false;
        var sw_begins: usize = 0;
        for (r.recs.items[at..]) |rec| if (rec.tag == .net_begin and rec.flags.service_worker) {
            sw_begins += 1;
        };
        report(ok, "net-service-worker", std.fmt.bufPrint(&detail, "sw-fetch {} · 표시 {} · initiator 「{s}」 · 서비스 워커 요청 {d}", .{ sw != null, ok, if (sw) |s| s.initiator else "-", sw_begins }) catch "");
    }
    // ── 쏟아짐 ──
    {
        at = r.mark();
        try r.navigate(watched, url(&u, "/n/flood"));
        r.pump(6000);
        var begins: usize = 0;
        var dropped: u64 = 0;
        for (r.recs.items[at..]) |rec| {
            if (rec.browser != watched) continue;
            if (rec.tag == .net_begin and std.mem.indexOf(u8, rec.url, "/n/f?") != null) begins += 1;
            if (rec.tag == .net_dropped) dropped += rec.count;
        }
        const served = flood_served.load(.monotonic);
        report(dropped > 1000 and begins <= 800 and begins >= 100, "net-flood", std.fmt.bufPrint(&detail, "서버가 받은 {d} · 적은 요청 {d} · 넘긴 수 {d}", .{ served, begins, dropped }) catch "");
    }
    // ── 끄기 ──
    {
        try r.watch(false, false);
        r.pump(300);
        at = r.mark();
        try r.navigate(watched, url(&u, "/n/main?after-off"));
        r.pump(2000);
        var any: usize = 0;
        for (r.recs.items[at..]) |rec| if (rec.browser == watched and rec.tag != .net_dropped) {
            any += 1;
        };
        report(any == 0, "net-watch-off", std.fmt.bufPrint(&detail, "끈 뒤의 알림 {d}", .{any}) catch "");
    }
}
