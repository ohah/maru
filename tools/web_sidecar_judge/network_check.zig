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
//! W9d① 적대 리뷰 1 회차(리뷰가 더한 판정 — 이름 `R9d1-*`):
//!   R9d1-sw-cross-tab-on   설정 켬: 지켜보지 않는 탭(사용자의 grant 없는 탭)이 같은 출처에서 보낸 서비스 워커 fetch 도 지켜보는 탭에
//!                          `service_worker` 로 붙는다 — 사용자 결정(2026-10-15 「다 보여 줌」)
//!   R9d1-sw-cross-tab-off  설정 끔: 같은 fetch 가 붙어도 `Authorization` 값은 브라우저 프로세스를 나가지 않는다(이름만) — 수만 세는 것은
//!                          maru 의 몫(grant 없는 탭이 같은 출처를 보인다 — L2·web_osr 시험)
//!   R9d1-inflight-*        끝나지 않는 요청을 쏟는 탭이 있어도 다른 지켜보는 탭이 적히고(탭마다 128), 떠나거나 닫으면 자리가 돌아온다
//! W9d① 적대 리뷰 2 회차(리뷰가 더한 판정 — 이름 `R9d2-*`, 고친 뒤에는 maru 의 규칙이 그 이동을 숨기는지 실제 CEF 의 알림으로 본다):
//!   R9d2-redirect-back            덮이지 않는 사이트(localhost — 「은행」)의 페이지가 POST 한 이동이 302 로 덮이는 사이트(127.0.0.1)에 돌아온다:
//!                                 한 요청 번호에 처음 주소는 localhost, 홉은 127.0.0.1 — 은행의 Cookie·Set-Cookie 가 실린 채 maru 에 오지만(설정 켬)
//!                                 maru 의 규칙(`net_policy.navigationCovered` — 처음 주소와 홉의 대상이 모두 덮일 때만)은 127.0.0.1 grant 에게 숨긴다
//!   R9d2-redirect-back-agent-nav  에이전트가 그 탭을 은행의 열린 리다이렉트로 곧장 옮긴다(브라우저가 시작한 이동 — initiator 「null」): 같은 모양,
//!                                 HttpOnly 쿠키까지 실린다 — 규칙은 initiator 를 보지 않고 숨긴다
//! W9d① 적대 리뷰 3 회차(리뷰가 더한 판정 — 이름 `R9d3-*`, 고친 뒤에는 sidecar 가 온 주소에서 읽어 싣는 호스트 칸으로 maru 의 규칙을 본다):
//!   R9d3-userinfo-truncated-full·-off  사용자 정보가 2 KiB 를 넘는 주소(`http://y…y.127.0.0.1z…@localhost/…`)로 옮긴다 — 호스트 칸은 실제 호스트
//!                                 (localhost)이고, 실린 주소에는 사용자 정보가 없으며, 127.0.0.1 grant 에게 덮이지 않는다. 끔이면 sidecar 가 헤더를 싣지 않는다
//!   R9d3-empty-watch-off          설정 끔에 묶인 호스트도 어느 호스트든도 없는 지켜보기(빈 사이트로 좁힌 grant) — 어떤 요청의 헤더도 싣지 않는다
//!                                 (빈 목록은 아무것도 덮지 않는다 — 전에는 `invalid` 를 실어야 했다)
//!   R9d3-request-ids(obs)         이 sidecar 프로세스의 처음 요청 번호들(두 번 돌리면 이동 요청 번호가 같다 — maru 는 다시 뜬 브라우저의 진행 중
//!                                 기록을 끝낸다)
//! W9d① 적대 리뷰 4 회차(이름 `R9d4-*` — `network_host_check.zig`): 문법이 이상한 주소들로 옮기거나 불러 sidecar 의 호스트 칸·app 이 주소 알림에서
//!   읽는 호스트를 서버가 받은 `Host` 와 맞춘다(`R9d4-host-*`), C3 의 전제(새 문서는 `page_started` 뒤 `url_changed`, 32 KiB 넘는 주소는 알림 없음)를 본다.
//! W9d① 적대 리뷰 5 회차(이름 `R9d5-*` — `network_r9d5_check.zig`, `--network` 가 이 판정 뒤에 따로 띄운 sidecar 로 돈다): 떠난 문서의 iframe 비콘,
//!   탭 든 `Location` 의 사용자 정보, 새 문서마다 `url_changed` 가 오는가(관측).

const array_repeat = @import("array_repeat");

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");
const network_host_check = @import("network_host_check.zig");

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
    // R9d1(리뷰): 다른(지켜보지 않는) 탭에서 서비스 워커가 다스리는 페이지와 그 탭만의 fetch, 끝나지 않는 끝점과 그것을 많이 여는 페이지.
    if (std.mem.eql(u8, path, "/n/sw-other")) return reply(conn, "200 OK", html, "", "<!doctype html><title>other</title><script>" ++
        "fetch('/n/user-secret?'+Date.now(),{headers:{'Authorization':'Bearer user-only'}}).then(function(){document.title='other-done'})</script>");
    if (std.mem.eql(u8, path, "/n/hang")) {
        os.sleepMs(40_000);
        return reply(conn, "200 OK", "text/plain", "", "late");
    }
    if (std.mem.eql(u8, path, "/n/hang-page")) return reply(conn, "200 OK", html, "", "<!doctype html><title>hang</title><script>" ++
        "for(var i=0;i<480;i++)fetch('/n/hang?a'+i).catch(function(){});" ++
        "setTimeout(function(){for(var i=0;i<200;i++)fetch('/n/hang?b'+i).catch(function(){})},1500)</script>");
    if (std.mem.eql(u8, path, "/v/page")) return reply(conn, "200 OK", html, "", "<!doctype html><title>v</title><script>for(var i=0;i<40;i++)fetch('/v/f?'+i)</script>");
    if (std.mem.eql(u8, path, "/n/slow")) {
        os.sleepMs(2_000);
        return reply(conn, "200 OK", "text/plain", "", "slow");
    }
    // 사용자가 곧 떠나는 바쁜 보통 페이지 — 떠날 때 요청 100 개가 아직 진행 중이다
    if (std.mem.eql(u8, path, "/n/slow-page")) return reply(conn, "200 OK", html, "", "<!doctype html><title>slow</title><script>" ++
        "for(var i=0;i<100;i++)fetch('/n/slow?'+Math.random()).catch(function(){});setTimeout(function(){location.href='/n/blank?left'},300)</script>");
    if (std.mem.eql(u8, path, "/n/flood")) return reply(conn, "200 OK", html, "", "<!doctype html><title>flood</title><script>for(var i=0;i<3000;i++)fetch('/n/f?'+i).catch(function(){})</script>");
    // R9d2(적대 리뷰 2 회차): 「은행」(localhost)이 쿠키를 심고, 제 페이지가 로그인 양식을 POST 하면 새 세션 쿠키와 함께 302 로 덮이는
    // 사이트(127.0.0.1)에 돌려보낸다 — OAuth·결제의 돌아오기.
    if (std.mem.eql(u8, path, "/b/home")) return reply(conn, "200 OK", html, "Set-Cookie: bank=SECRET1; Path=/\r\n", "<!doctype html><title>bank</title>bank");
    if (std.mem.eql(u8, path, "/b/form")) return reply(conn, "200 OK", html, "", "<!doctype html><title>bank-form</title><form method=post action=/b/login><input name=user value=alice></form><script>document.forms[0].submit()</script>");
    if (std.mem.eql(u8, path, "/b/login")) {
        const loc = std.fmt.bufPrint(&xb, "Set-Cookie: bank_sid=NEWSECRET; Path=/; HttpOnly\r\nLocation: http://127.0.0.1:{d}/n/blank?callback=1\r\n", .{p}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    // R9d4 C1(적대 리뷰 4 회차): 덮이는 호스트의 리다이렉트가 주소를 싣는 헤더 넷에 사용자 정보(자리표시)를 싣는다.
    if (std.mem.eql(u8, path, "/n/loc-userinfo")) {
        const loc = std.fmt.bufPrint(&xb, "Location: http://u:p@127.0.0.1:{d}/n/blank?loc\r\nRefresh: 0; url=http://u:p@127.0.0.1:{d}/r\r\n" ++
            "Content-Location: http://u:p@127.0.0.1:{d}/c\r\nLink: <http://u:p@127.0.0.1:{d}/l>; rel=preload\r\n", .{ p, p, p, p }) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    // R9d4(작성자 공격): 덩어리 상한(8 KiB)을 거의 채우는 헤더 뒤의 Location — 그 값이 사용자 정보 안에서 잘리게. CEF 의 헤더 다발은 이름 차례라
    // 채우는 헤더는 `A-` 로 앞에 둔다(처음엔 `X-Fill` 이 Location 뒤로 가 잘리지 않았다 — 실측).
    if (std.mem.eql(u8, path, "/n/loc-cut")) {
        var big: [12 * 1024]u8 = undefined;
        const head = std.fmt.bufPrint(&big, "HTTP/1.1 302 Found\r\nContent-Length: 0\r\nA-Fill: {s}\r\nLocation: http://{s}:SECRETPW@127.0.0.1:{d}/n/blank?cut\r\nConnection: close\r\n\r\n", .{ array_repeat.repeat("f", 7800), array_repeat.repeat("u", 1000), p }) catch return;
        _ = std.c.write(conn, head.ptr, head.len);
        return;
    }
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
    /// 호스트 칸(begin — 요청 주소, redirect — 옮겨 갈 주소 — sidecar 가 온 주소에서 읽었다, W9d① 적대 리뷰 3 회차 T1).
    host: []u8 = &.{},
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
            .net_begin => |v| .{ .tag = .net_begin, .browser = v.browser, .request = v.request, .flags = v.flags, .resource_type = v.resource_type, .url = self.dupe(v.url), .host = self.dupe(v.host), .initiator = self.dupe(v.initiator), .site = self.dupe(v.site), .headers = self.dupe(v.headers.bytes), .header_count = v.headers.count },
            .net_redirect => |v| .{ .tag = .net_redirect, .browser = v.browser, .request = v.request, .hop = v.flags, .status = v.status, .url = self.dupe(v.url), .host = self.dupe(v.host), .headers = self.dupe(v.headers.bytes), .header_count = v.headers.count },
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

    /// 주 프레임 이동 하나(`l`)의 리다이렉트 모양 — `from` 뒤의 같은 요청 번호 알림으로 본다(R9d2).
    fn redirectBack(self: *const Run, from: usize, l: *const Rec) RedirectBack {
        var hops: [20][]const u8 = undefined;
        var n: usize = 0;
        var out: RedirectBack = .{ .begins = self.countFor(from, .net_begin, l.browser, l.request) };
        for (self.recs.items[from..]) |*rec| if (rec.tag == .net_redirect and rec.browser == l.browser and rec.request == l.request and n < hops.len) {
            hops[n] = rec.host;
            n += 1;
        };
        out.starts_uncovered = std.mem.eql(u8, l.host, "localhost");
        out.back_to_covered = n > 0 and std.mem.eql(u8, hops[n - 1], "127.0.0.1");
        // maru 가 읽을 때 쓰는 바로 그 규칙(`web_osr_network.navigationCovered` 가 부른다 — sidecar 가 실은 호스트 칸으로, 3 회차 T1).
        out.hidden = !protocol.net_policy.navigationCovered("127.0.0.1", l.host, hops[0..n]);
        return out;
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

    /// W9d① 적대 리뷰 3 회차: 묶인 호스트도 어느 호스트든도 없는 지켜보기(빈 사이트로 좁힌 grant 꼴).
    fn watchNothing(self: *Run) !void {
        try self.host.send(.{ .net_watch = .{ .browser = watched, .on = true, .full = false } });
    }
};

/// R9d2: 덮이지 않는 곳에서 시작해 덮이는 곳으로 돌아온 이동의 모양.
const RedirectBack = struct {
    begins: usize = 0,
    starts_uncovered: bool = false,
    back_to_covered: bool = false,
    hidden: bool = false,

    fn ok(self: RedirectBack) bool {
        return self.begins == 1 and self.starts_uncovered and self.back_to_covered and self.hidden;
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
        const iframe_ok = if (iframe) |d| d.flags.subframe and d.resource_type == 1 and protocol.net_policy.crossSiteIframe(d.flags, d.resource_type, d.host, d.initiator, d.site) else false;
        // 다른 사이트 iframe 안의 요청: initiator 는 iframe 출처, 쿠키의 첫 사이트는 비었다(다른 사이트 문맥 — 실측).
        const inner_ok = if (inner) |d| d.flags.subframe and std.mem.indexOf(u8, d.initiator, "localhost") != null and protocol.net_policy.crossSiteIframe(d.flags, d.resource_type, d.host, d.initiator, d.site) else false;
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
        // R9d3(관측): 이 sidecar 프로세스의 처음 요청 번호들 — 판정을 두 번 돌려 같으면 다시 뜬 sidecar 는 같은 번호를 다시 쓴다(maru 의 `live` 와 겹친다).
        {
            var ids_buf: [600]u8 = undefined;
            var ids_len: usize = 0;
            var shown: usize = 0;
            for (r.recs.items) |rec| if (rec.tag == .net_begin and shown < 12) {
                const part = std.fmt.bufPrint(ids_buf[ids_len..], "{d} ", .{rec.request}) catch break;
                ids_len += part.len;
                shown += 1;
            };
            report(true, "R9d3-request-ids(obs)", ids_buf[0..ids_len]);
        }
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
    // ── R9d2(적대 리뷰 2 회차 N1): 덮이지 않는 사이트에서 시작해 덮이는 사이트로 리다이렉트돼 돌아온 이동 ──
    {
        var bu: [512]u8 = undefined;
        try r.navigate(watched, try std.fmt.bufPrint(&bu, "http://localhost:{d}/b/home", .{server_port}));
        r.pump(1500);
        at = r.mark();
        try r.navigate(watched, try std.fmt.bufPrint(&bu, "http://localhost:{d}/b/form", .{server_port}));
        r.pump(3000);
        const login = r.begin(at, watched, "/b/login");
        const cookie: []const u8 = if (login) |l| l.header("Cookie") orelse "" else "";
        var hop_set_cookie: []const u8 = "";
        var final_status: u16 = 0;
        var main_doc = false;
        var shape = RedirectBack{};
        if (login) |l| {
            main_doc = l.flags.main_frame and l.flags.navigation and l.resource_type == 0;
            shape = r.redirectBack(at, l);
            if (r.first(at, .net_redirect, watched, l.request)) |h| hop_set_cookie = h.header("Set-Cookie") orelse "";
            if (r.first(at, .net_response, watched, l.request)) |resp| final_status = resp.status;
        }
        // 고친 뒤의 기대: 한 요청 번호(begin 하나)·처음 주소는 localhost·홉은 127.0.0.1 — 그래서 maru 의 규칙이 127.0.0.1 grant 에게 숨긴다.
        report(main_doc and shape.ok(), "R9d2-redirect-back", std.fmt.bufPrint(&detail, "은행 POST /b/login: 주 프레임 문서 {} · begin {d} · 처음 주소 localhost {} · 홉 → 127.0.0.1 {} · 127.0.0.1 grant 에게 숨김 {} · (실린 것: Cookie 「{s}」 · 홉 Set-Cookie 「{s}」 · 마지막 {d})", .{ main_doc, shape.begins, shape.starts_uncovered, shape.back_to_covered, shape.hidden, cookie, hop_set_cookie, final_status }) catch "");
        // 에이전트가 이 탭(제어 grant 는 사이트에 묶이지 않는다)을 은행의 열린 리다이렉트(SSO·logout?next=)로 곧장 옮긴다 — 브라우저가 시작한 GET.
        try r.navigate(watched, url(&u, "/n/blank?covered-again"));
        r.pump(1000);
        const at2 = r.mark();
        try r.navigate(watched, try std.fmt.bufPrint(&bu, "http://localhost:{d}/b/login?agent=1", .{server_port}));
        r.pump(2500);
        const nav = r.begin(at2, watched, "/b/login?agent=1");
        const c2: []const u8 = if (nav) |l| l.header("Cookie") orelse "" else "";
        var shape2 = RedirectBack{};
        if (nav) |l| shape2 = r.redirectBack(at2, l);
        const doc2 = if (nav) |l| l.flags.main_frame and l.resource_type == 0 else false;
        report(doc2 and shape2.ok(), "R9d2-redirect-back-agent-nav", std.fmt.bufPrint(&detail, "navigate → localhost/b/login?agent=1: 주 프레임 문서 {} · initiator 「{s}」 · begin {d} · 처음 주소 localhost {} · 홉 → 127.0.0.1 {} · 127.0.0.1 grant 에게 숨김 {} · (실린 Cookie 「{s}」)", .{ doc2, if (nav) |l| l.initiator else "-", shape2.begins, shape2.starts_uncovered, shape2.back_to_covered, shape2.hidden, c2 }) catch "");
    }
    // ── R9d3(적대 리뷰 3 회차): 사용자 정보가 긴 주소 — sidecar 가 2 KiB 앞부분만 싣는다. 앞부분이 「…y.127.0.0.1」 에서 끊기면 그 글의
    // 호스트는 덮이는 호스트(127.0.0.1 의 하위 도메인 꼴)로 읽히고, 실제 호스트(localhost — 「은행」)는 잘려 나간다. ──
    {
        var lu: [2300]u8 = undefined;
        const pad_len = msg.max_net_url_bytes - "http://".len - ".127.0.0.1".len;
        var pad: [msg.max_net_url_bytes]u8 = undefined;
        @memset(pad[0..pad_len], 'y');
        const long = try std.fmt.bufPrint(&lu, "http://{s}.127.0.0.1zzzzzzzz@localhost:{d}/b/home?r9d3", .{ pad[0..pad_len], server_port });
        for ([_]bool{ true, false }) |full| {
            try r.watch(true, full);
            r.pump(100);
            const at3 = r.mark();
            try r.navigate(watched, long);
            r.pump(2500);
            var doc: ?*const Rec = null;
            for (r.recs.items[at3..]) |*rec| if (rec.tag == .net_begin and rec.browser == watched and rec.flags.main_frame and rec.resource_type == 0) {
                doc = rec;
                break;
            };
            var hops: [20][]const u8 = undefined;
            var nh: usize = 0;
            var set_cookie: []const u8 = "";
            if (doc) |d| {
                for (r.recs.items[at3..]) |*rec| if (rec.tag == .net_redirect and rec.request == d.request and nh < hops.len) {
                    hops[nh] = rec.host;
                    nh += 1;
                };
                if (r.first(at3, .net_response, watched, d.request)) |resp| set_cookie = resp.header("Set-Cookie") orelse "";
            }
            const shown_url: []const u8 = if (doc) |d| d.url else "";
            const host_field: []const u8 = if (doc) |d| d.host else "-";
            const truncated = if (doc) |d| d.flags.url_truncated else false;
            const userinfo_shipped = protocol.net_policy.hasUserinfo(shown_url) or std.mem.indexOf(u8, shown_url, "yyyy") != null;
            // 고친 뒤의 규칙 — maru 는 sidecar 가 실은 호스트 칸으로만 가른다.
            const covered = doc != null and protocol.net_policy.navigationCovered("127.0.0.1", host_field, hops[0..nh]);
            const cookie: []const u8 = if (doc) |d| d.header("Cookie") orelse "" else "";
            const nhdr: u8 = if (doc) |d| d.header_count else 0;
            const off_ok = full or nhdr == 0; // 끔: 덮이지 않는 요청은 헤더를 싣지 않는다
            report(doc != null and !covered and std.mem.eql(u8, host_field, "localhost") and !userinfo_shipped and off_ok, if (full) "R9d3-userinfo-truncated-full" else "R9d3-userinfo-truncated-off", std.fmt.bufPrint(&detail, "주 프레임 문서 {} · 호스트 칸 「{s}」 · 실린 주소 「{s}」(url_truncated {}) · 사용자 정보가 실렸다 {} · 127.0.0.1 grant 에게 덮임(보인다) {} · 실린 Cookie 「{s}」 · 응답 Set-Cookie 「{s}」 · sidecar 가 실은 헤더 수 {d}", .{ doc != null, host_field, shown_url[0..@min(shown_url.len, 80)], truncated, userinfo_shipped, covered, cookie, set_cookie, nhdr }) catch "");
        }
        // 빈 지켜보기(묶인 호스트도 어느 호스트든도 없다) — 끔에서 어떤 요청의 헤더도 싣지 않는다.
        try r.watchNothing();
        r.pump(100);
        const at4 = r.mark();
        try r.navigate(watched, url(&u, "/n/main?nothing"));
        r.pump(2500);
        var begins: usize = 0;
        var with_headers: usize = 0;
        var unstripped: usize = 0;
        for (r.recs.items[at4..]) |rec| if (rec.browser == watched and (rec.tag == .net_begin or rec.tag == .net_redirect or rec.tag == .net_response)) {
            if (rec.tag == .net_begin) begins += 1;
            if (rec.header_count != 0) with_headers += 1;
            if (!(if (rec.tag == .net_begin) rec.flags.stripped else rec.hop.stripped)) unstripped += 1;
        };
        report(begins >= 3 and with_headers == 0 and unstripped == 0, "R9d3-empty-watch-off", std.fmt.bufPrint(&detail, "요청 {d} · 헤더를 실은 알림 {d} · 덜어 냈다는 표시가 없는 알림 {d}", .{ begins, with_headers, unstripped }) catch "");
        try r.watch(true, true);
        r.pump(100);
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
    // ── R9d4(적대 리뷰 4 회차): 호스트 해석의 일치 — 지켜보는 탭(설정 켬)을 이상한 주소들로 옮긴다(그 판정이 알림을 직접 모은다) ──
    try network_host_check.run(report, &host, watched, url(&u, "/n/blank?host-check"));
    // ── R9d4 C1(적대 리뷰 4 회차): 덮이는 호스트(127.0.0.1)가 보낸 리다이렉트의 Location·Refresh·Content-Location·Link 에 든 사용자 정보 ──
    // 켬: sidecar 는 그대로 싣는다(관측 — maru 가 읽는 쪽의 쿠키 권한으로 지운다, L2·web_osr 시험). 끔: 브라우저 프로세스를 나가지 않는다 —
    // Location 은 사용자 정보만 지운 값, 나머지 셋은 이름만(허용 목록 밖).
    for ([_]bool{ true, false }) |full| {
        try r.watch(true, full);
        r.pump(100);
        const at5 = r.mark();
        try r.navigate(watched, url(&u, if (full) "/n/loc-userinfo?full" else "/n/loc-userinfo?off"));
        r.pump(1500);
        var vals: [4][]const u8 = .{ "-", "-", "-", "-" };
        const names = [_][]const u8{ "Location", "Refresh", "Content-Location", "Link" };
        if (r.begin(at5, watched, "/n/loc-userinfo")) |b| if (r.first(at5, .net_redirect, watched, b.request)) |h| {
            for (names, &vals) |n, *v| v.* = h.header(n) orelse "-";
        };
        var with_userinfo: usize = 0;
        for (vals) |v| with_userinfo += @intFromBool(std.mem.indexOf(u8, v, "u:p@") != null);
        const ok = if (full)
            with_userinfo == 4
        else
            with_userinfo == 0 and std.mem.indexOf(u8, vals[0], "127.0.0.1") != null and vals[1].len == 0 and vals[2].len == 0 and vals[3].len == 0;
        report(ok, if (full) "R9d4-c1-url-headers-full(obs)" else "R9d4-c1-url-headers-off", std.fmt.bufPrint(&detail, "홉 헤더: Location 「{s}」 · Refresh 「{s}」 · Content-Location 「{s}」 · Link 「{s}」 · 사용자 정보가 실린 값 {d}", .{ vals[0], vals[1], vals[2], vals[3], with_userinfo }) catch "");
    }
    // R9d4(작성자 공격): 8 KiB 덩어리 상한에서 잘리는 Location — 사용자 정보 안에서 끊기면 `@` 가 없어 가리기가 사용자 정보로 알아보지
    // 못한다. 켬·끔 모두 sidecar 가 그 값을 싣지 않아야 한다(주소를 싣는 헤더는 자르지 않고 비운다 — 잘림 표시는 남는다).
    for ([_]bool{ true, false }) |full| {
        try r.watch(true, full);
        r.pump(100);
        const at6 = r.mark();
        try r.navigate(watched, url(&u, if (full) "/n/loc-cut?full" else "/n/loc-cut?off"));
        r.pump(1500);
        var loc: ?[]const u8 = null;
        var trunc = false;
        if (r.begin(at6, watched, "/n/loc-cut")) |b| if (r.first(at6, .net_redirect, watched, b.request)) |h| {
            loc = h.header("Location");
            trunc = h.hop.headers_truncated;
        };
        // 새는 꼴: 사용자 정보 조각이 `@` 없이 실렸다(켬이면 `@` 째 실린 값은 maru 가 읽는 쪽마다 지운다 — 그것은 새는 것이 아니다).
        const leaked = if (loc) |l| std.mem.indexOf(u8, l, "uuuuuuuu") != null and std.mem.indexOfScalar(u8, l, '@') == null else false;
        report(loc != null and !leaked and trunc, if (full) "R9d4-cut-location-full" else "R9d4-cut-location-off", std.fmt.bufPrint(&detail, "홉의 Location {s}(길이 {d}) 「{s}」 · 사용자 정보 조각이 실렸다 {} · 잘림 표시 {}", .{ if (loc != null) "있음" else "없음", if (loc) |l| l.len else 0, if (loc) |l| l[0..@min(l.len, 48)] else "-", leaked, trunc }) catch "");
    }
    try r.watch(true, true);
    r.pump(100);
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
    // ── R9d1(리뷰): 탭을 건너는 서비스 워커 요청 — 켬·끔 ──
    // 지켜보는 탭은 127.0.0.1 에 있고 /n/sw-page 의 서비스 워커가 /n/ 을 다스린다. 지켜보지 않는 탭(사용자의 grant 없는 탭)이 그 범위의
    // 페이지를 열어 그 탭만의 fetch(`Authorization`)를 보낸다 — 지켜보는 탭에 붙는가, 끄면 값이 나가는가.
    {
        try r.navigate(watched, url(&u, "/n/blank?sw-host"));
        r.pump(1000);
        for ([_]bool{ true, false }) |full| {
            try r.watch(true, full);
            r.pump(300);
            at = r.mark();
            var pb: [64]u8 = undefined;
            try r.navigate(unwatched, url(&u, try std.fmt.bufPrint(&pb, "/n/sw-other?full={}", .{full})));
            r.pump(4000);
            const leak = r.begin(at, watched, "/n/user-secret");
            const nav = r.begin(at, watched, "/n/sw-other");
            const auth: []const u8 = if (leak) |l| l.header("Authorization") orelse "" else "";
            const sw = if (leak) |l| l.flags.service_worker else false;
            // 켬: 사용자 결정대로 붙는다(서비스 워커 표시와 값까지). 끔: 붙어도 값은 비었다(이름만 — `stripped`).
            const ok = if (full)
                sw and std.mem.eql(u8, auth, "Bearer user-only")
            else if (leak) |l| sw and l.flags.stripped and auth.len == 0 else true;
            report(ok, if (full) "R9d1-sw-cross-tab-on" else "R9d1-sw-cross-tab-off", std.fmt.bufPrint(&detail, "지켜보지 않는 탭의 fetch 가 지켜보는 탭에 {} (서비스 워커 {} · Authorization 「{s}」) · 그 탭의 이동 {}", .{ leak != null, sw, auth, nav != null }) catch "");
        }
        try r.watch(true, true);
        r.pump(300);
    }
    // ── R9d1(리뷰): 끝나지 않는 요청을 쥔 지켜보는 탭 대 다른 지켜보는 탭 ──
    // 피해 탭의 페이지는 http://127.0.0.1:<포트>/v/page — 서비스 워커의 /n/ 범위 밖이고 끝나지 않는 요청(localhost:<포트>)과 다른 호스트라
    // Chromium 자신의 호스트별 연결 줄이 막지 않는다.
    {
        const second: u64 = unwatched;
        var w2: msg.NetWatch = .{ .browser = second, .on = true, .full = true, .host_count = 1 };
        w2.hosts[0] = "127.0.0.1";
        var lb: [512]u8 = undefined;
        try r.host.send(.{ .net_watch = w2 });
        r.pump(300);
        const Victim = struct {
            fn load(rr: *Run, tag: []const u8) !struct { begins: usize, dropped: u64 } {
                var b: [512]u8 = undefined;
                const from = rr.mark();
                try rr.navigate(unwatched, try std.fmt.bufPrint(&b, "http://127.0.0.1:{d}/v/page?{s}", .{ server_port, tag }));
                rr.pump(2500);
                var n: usize = 0;
                var d: u64 = 0;
                for (rr.recs.items[from..]) |rec| if (rec.browser == unwatched) {
                    if (rec.tag == .net_begin) n += 1;
                    if (rec.tag == .net_dropped) d += rec.count;
                };
                return .{ .begins = n, .dropped = d };
            }
        };
        const base = try Victim.load(&r, "baseline");
        try r.navigate(watched, try std.fmt.bufPrint(&lb, "http://localhost:{d}/n/hang-page", .{server_port}));
        r.pump(5000);
        const starved = try Victim.load(&r, "victim");
        report(starved.begins > 0, "R9d1-inflight-starve", std.fmt.bufPrint(&detail, "다른 지켜보는 탭: 기준 시작 {d} · 첫 탭이 끝나지 않는 요청을 쥔 동안 시작 {d} 넘김 {d}", .{ base.begins, starved.begins, starved.dropped }) catch "");
        // 그 탭이 떠난다 — 끝나지 않던 fetch 가 취소된다. 자리가 돌아오는가?
        try r.navigate(watched, url(&u, "/n/blank?leave"));
        r.pump(3000);
        const after = try Victim.load(&r, "after");
        report(after.begins > 0, "R9d1-inflight-recover", std.fmt.bufPrint(&detail, "끝나지 않는 요청의 탭이 떠나고 3 초 뒤: 시작 {d} 넘김 {d}", .{ after.begins, after.dropped }) catch "");
        r.pump(45_000);
        const late = try Victim.load(&r, "late");
        report(late.begins > 0, "R9d1-inflight-recover-late", std.fmt.bufPrint(&detail, "48 초 뒤(서버의 40 초 답 뒤): 시작 {d} 넘김 {d}", .{ late.begins, late.dropped }) catch "");
        try r.host.send(.{ .net_watch = .{ .browser = second, .on = false, .full = false } });
        r.pump(200);
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
    // ── R9d1(리뷰): 바쁜 페이지를 떠나 취소된 요청 — 그 자리가 풀리는가 ──
    {
        var w2: msg.NetWatch = .{ .browser = unwatched, .on = true, .full = true, .host_count = 1 };
        w2.hosts[0] = "127.0.0.1";
        try r.host.send(.{ .net_watch = w2 });
        try r.watch(true, true);
        r.pump(300);
        var lb: [512]u8 = undefined;
        var round: usize = 0;
        const Probe = struct {
            fn victim(rr: *Run, tag: []const u8, port: u16) !struct { n: usize, d: u64 } {
                var b: [512]u8 = undefined;
                const from = rr.mark();
                try rr.navigate(unwatched, try std.fmt.bufPrint(&b, "http://127.0.0.1:{d}/v/page?{s}", .{ port, tag }));
                rr.pump(3000);
                var n: usize = 0;
                var d: u64 = 0;
                for (rr.recs.items[from..]) |rec| if (rec.browser == unwatched) {
                    if (rec.tag == .net_begin) n += 1;
                    if (rec.tag == .net_dropped) d += rec.count;
                };
                return .{ .n = n, .d = d };
            }
        };
        const before = try Probe.victim(&r, "leak-before", server_port);
        while (round < 8) : (round += 1) {
            try r.navigate(watched, try std.fmt.bufPrint(&lb, "http://localhost:{d}/n/slow-page?r{d}", .{ server_port, round }));
            r.pump(1500);
        }
        r.pump(15_000); // /n/slow 의 답(2 초)은 다 끝났다 — 취소된 것은 끝내 오지 않는다
        const after = try Probe.victim(&r, "leak-after", server_port);
        report(after.d == 0, "R9d1-inflight-leak-on-leave", std.fmt.bufPrint(&detail, "피해 탭 전: 시작 {d} 넘김 {d} · 지켜보는 탭이 바쁜 페이지를 8 번 떠난 뒤(+15 초): 시작 {d} 넘김 {d}", .{ before.n, before.d, after.n, after.d }) catch "");
    }
    // ── R9d1(리뷰): 끝나지 않는 요청을 쥔 탭을 닫는다 — 자리가 돌아오는가 ──
    {
        var w2: msg.NetWatch = .{ .browser = unwatched, .on = true, .full = true, .host_count = 1 };
        w2.hosts[0] = "127.0.0.1";
        try r.host.send(.{ .net_watch = w2 });
        try r.host.send(.{ .destroy_browser = watched });
        r.pump(5000);
        const from = r.mark();
        try r.navigate(unwatched, url(&u, "/v/page?closed"));
        r.pump(3000);
        var n: usize = 0;
        var d: u64 = 0;
        for (r.recs.items[from..]) |rec| if (rec.browser == unwatched) {
            if (rec.tag == .net_begin) n += 1;
            if (rec.tag == .net_dropped) d += rec.count;
        };
        report(d == 0, "R9d1-inflight-after-close", std.fmt.bufPrint(&detail, "끝나지 않는 요청의 탭을 닫고 5 초 뒤: 시작 {d} 넘김 {d}(페이지는 요청 42 개)", .{ n, d }) catch "");
    }
}
