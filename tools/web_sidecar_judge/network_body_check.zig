//! W9d② 판정 — 실제 CEF 154 에서 기록하는 탭의 응답 본문이 maru 에 오는가(docs/plans/web-osr-backend.md 「W9d② 결정」). 판정자가 **maru 역할**로
//! `net_watch`·`net_record` 를 보내고 `net_begin`(`body_expected`)·`net_body_data`·`net_body_end`·`net_record_state` 를 모은다. 서버는 따로 띄운다
//! (연결마다 스레드). `127.0.0.1:<포트>` 와 `localhost:<포트>` 는 다른 사이트다(다른 사이트 iframe 은 다른 렌더러 프로세스 — OOPIF).
//!
//!   body-record-on              켜면 sidecar 가 `net_record_state on`(그 세션)으로 답한다
//!   body-captured-chunked       Content-Length 없는 chunked JSON 이 그대로(조각을 이어)
//!   body-captured-gzip          gzip 으로 보낸 JSON 이 풀린 글로
//!   body-captured-h2(net)       공개 사이트(https — HTTP/2)의 문서 본문(인터넷이 없으면 관측으로)
//!   body-document               주 프레임 문서(text/html) 본문
//!   body-over-cap-json·-script  풀어 낸 크기가 1 MiB 를 넘는 JSON 과 스크립트는 받지 않는다(`over_cap` — 스크립트는 CDP 상한이 듣지 않았다 — J4)
//!   body-not-text               PNG 는 받지 않는다(`not_text`)
//!   body-no-body                204 는 `no_body`
//!   body-partial                Content-Length 보다 짧게 끊긴 응답은 `partial`
//!   body-redecoded              charset 없는 text/plain 의 UTF-8 이 Chromium 의 windows-1252 읽기에서 되돌아온다(J11)
//!   body-join-same-url          같은 주소 동시 요청 여덟의 본문이 제 CEF 요청에(요청 헤더 `x-n` 과 본문의 n 이 같다 — J2)
//!   body-cross-process-iframe   다른 사이트 iframe(다른 렌더러)의 요청은 `unmatched`(UB4 — 페이지의 DevTools 가 보지 못한다)
//!   body-service-worker         서비스 워커가 다스리는 페이지의 fetch 본문(서비스 워커 갈래의 CEF 요청과 짝)
//!   body-ub1-credentialed       다른 사이트(localhost)의 쿠키가 실린 `<script>` 본문은 `credentialed` — maru 의 규칙(`net_policy.bodyAccess`)은 그
//!                               사이트의 쿠키 권한이 없으면 숨긴다, 기록한 사이트 제 응답은 실리지 않았다
//!   body-switch-off-prefilter   설정 끔(`full` 거짓·127.0.0.1 만 덮는다): 덮이지 않는 호스트의 본문은 받지 않는다(`not_covered`), 덮이는 것은 받는다
//!   body-writer-nonblocking     maru 가 3 초 읽지 않는 동안 본문이 쏟아져도 sidecar 의 UI 스레드는 다른 탭의 이동을 그때 처리한다(J7 — 예전에는
//!                               48 KiB 뒤에 멈춘 만큼 섰다), 자리가 없는 본문은 `busy`
//!   body-devtools-guard         maru 를 거친 `Network.enable`·`Fetch.enable` 호출은 보내지 않는다(`invalid_request`)
//!   body-renderer-crash         렌더러가 죽으면 받던 본문은 `detached`, 다시 불러온 뒤에는 다시 켜지 않아도 본문이 온다(J5)
//!   body-record-off             끄면 기다리던 본문은 `recording_stopped`, 그 뒤 요청에는 `body_expected` 가 없다
//!   body-restart-same-id        같은 CEF 번호로 다시 시작한 이동(`Critical-CH` — W9d① 적대 리뷰 후 `R9d6-restart-same-id` 와 같은 서버 꼴): 시도마다
//!                               본문 끝이 꼭 하나이고 앞 시도의 끝은 다음 시작보다 먼저 온다(maru 는 본문을 그 번호의 새 기록에 붙인다), 새 시도의 본문은
//!                               200 답의 것이다(앞 시도의 403 본문이 새 시도에 붙지 않는다)
//!   body-one-end-each           `body_expected` 로 시작한 요청(시도)마다 본문 끝은 꼭 하나

const array_repeat = @import("array_repeat");

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const net_fields = protocol.net_fields;
const net_policy = protocol.net_policy;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const rec_tab: u64 = 71;
const other_tab: u64 = 72;
const wait_ms = 15_000;

// ── 서버 ──────────────────────────────────────────────────────────────────────────────────────────────────

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

var port: u16 = 0;
var pings = std.atomic.Value(u32).init(0);
/// 같은 번호 다시 시작(`/b/cch`)을 받은 수.
var cch_served = std.atomic.Value(u32).init(0);
/// 큰 본문(1.2 MiB JSON·1.5 MiB 스크립트·쏟아짐의 60 KiB 조각) — 처음에 한 번 만든다.
var big_json: []u8 = &.{};
var big_js: []u8 = &.{};
var flood_json: []u8 = &.{};

const gz_json = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xab, 0x56, 0x4a, 0xaf, 0x52, 0xb2, 0x52, 0x4a, 0xce, 0xcf, 0x2d, 0x28, 0x4a, 0x2d, 0x2e, 0x4e, 0x4d, 0xd1, 0x4d, 0xca, 0x4f, 0xa9, 0xd4, 0xcd, 0xcf, 0x56, 0xaa, 0x05, 0x00, 0x75, 0xc3, 0xad, 0xc7, 0x1b, 0x00, 0x00, 0x00 };
const gz_plain = "{\"gz\":\"compressed-body-ok\"}";
const png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0d\x49\x44\x41\x54\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
const chunked_parts = [_][]const u8{ "{\"chunked\":[", "\"one\",", "\"two\",", "\"three\"]}" };
const latin_utf8 = "한글 ok";
/// 페이지의 fetch 는 본문을 읽는다 — Chromium 은 페이지가 본문을 읽기 전에는 그 요청을 끝내지 않는다(실측: 읽지 않은 fetch 는 CDP `loadingFinished` 도
/// CEF 의 끝도 없이 다음 이동까지 열려 있었다 — 그러면 본문도 없다). 실제 페이지는 받은 본문을 읽는다.
const read_js = "function F(u,o){return fetch(u,o).then(function(r){return r.text()}).catch(function(){})}";
/// 같은 글을 형식 글(`bufPrint`) 안에 넣을 때 — 중괄호를 겹친다.
const read_js_fmt = "function F(u,o){{return fetch(u,o).then(function(r){{return r.text()}}).catch(function(){{}})}}";

fn startServer(gpa: std.mem.Allocator) !void {
    big_json = try gpa.alloc(u8, 1200 * 1024);
    @memset(big_json, 'j');
    @memcpy(big_json[0..8], "{\"big\":\"");
    @memcpy(big_json[big_json.len - 2 ..], "\"}");
    big_js = try gpa.alloc(u8, 1500 * 1024);
    @memset(big_js, ' ');
    const js_head = "var bigScript=1;/*";
    @memcpy(big_js[0..js_head.len], js_head);
    @memcpy(big_js[big_js.len - 2 ..], "*/");
    flood_json = try gpa.alloc(u8, 60 * 1024);
    @memset(flood_json, 'f');
    const fl_head = "{\"fl\":\"";
    @memcpy(flood_json[0..fl_head.len], fl_head);
    @memcpy(flood_json[flood_json.len - 2 ..], "\"}");
    const fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
    if (listen(fd, 128) != 0) return error.ListenFailed;
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
        const timeout: Timeval = .{ .sec = 5, .usec = 0 };
        _ = setsockopt(conn, 0xffff, 0x1006, &timeout, @sizeOf(Timeval));
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

fn reply(conn: c_int, status: []const u8, ctype: []const u8, extra: []const u8, body: []const u8) void {
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
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const p = port;
    var bb: [8192]u8 = undefined;
    const html = "text/html; charset=utf-8";
    if (std.mem.eql(u8, path, "/b/blank")) return reply(conn, "200 OK", html, "", "<!doctype html><title>blank</title>blank");
    // 같은 번호 다시 시작 — 힌트(`Sec-CH-UA-Arch`)가 없으면 403 에 `Critical-CH` 를 실어 Chromium 이 같은 이동을 힌트와 함께 다시 하게 한다
    // (`network_check.zig` 의 `/n/cch` 와 같은 꼴 — Cloudflare 확인 페이지).
    if (std.mem.eql(u8, path, "/b/cch")) {
        _ = cch_served.fetchAdd(1, .monotonic);
        if (std.ascii.findIgnoreCase(head, "sec-ch-ua-arch:") != null) return reply(conn, "200 OK", html, "", "<!doctype html><title>cch-ok</title>cch-ok-body");
        return reply(conn, "403 Forbidden", html, "Accept-CH: Sec-CH-UA-Arch\r\nCritical-CH: Sec-CH-UA-Arch\r\nSet-Cookie: cch=1; Path=/b/cch\r\n", "<!doctype html><title>cch-challenge</title>cch-challenge-body");
    }
    if (std.mem.eql(u8, path, "/b/ping")) {
        _ = pings.fetchAdd(1, .monotonic);
        return reply(conn, "200 OK", html, "", "<!doctype html><title>ping</title>ping");
    }
    if (std.mem.eql(u8, path, "/b/page")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>body-page</title><iframe src=\"http://localhost:{d}/b/frame\"></iframe>" ++
            "<img src=\"/b/pic.png\"><script src=\"/b/big.js\"></script><script>" ++ read_js_fmt ++
            "F('/b/chunked.json');F('/b/gzip.json');F('/b/big.json');F('/b/empty');F('/b/cut');F('/b/latin.txt');" ++
            "for(var i=0;i<8;i++)F('/b/echo',{{headers:{{'x-n':String(i)}}}});</script>body page", .{p}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/b/frame")) return reply(conn, "200 OK", html, "", "<!doctype html><title>frame</title><script>" ++ read_js ++ "F('/b/frame.json')</script>frame");
    if (std.mem.eql(u8, path, "/b/frame.json")) return reply(conn, "200 OK", "application/json", "", "{\"frame\":1}");
    if (std.mem.eql(u8, path, "/b/pic.png")) return reply(conn, "200 OK", "image/png", "", png);
    if (std.mem.eql(u8, path, "/b/big.js")) return reply(conn, "200 OK", "application/javascript", "", big_js);
    if (std.mem.eql(u8, path, "/b/big.json")) return reply(conn, "200 OK", "application/json", "", big_json);
    if (std.mem.eql(u8, path, "/b/empty")) {
        writeAll(conn, "HTTP/1.1 204 No Content\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
        return;
    }
    if (std.mem.eql(u8, path, "/b/cut")) {
        // 5000 바이트라 하고 100 바이트만 보낸 뒤 닫는다(ERR_CONTENT_LENGTH_MISMATCH).
        writeAll(conn, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5000\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
        writeAll(conn, array_repeat.repeat("c", 100));
        os.sleepMs(300);
        return;
    }
    if (std.mem.eql(u8, path, "/b/latin.txt")) return reply(conn, "200 OK", "text/plain", "", latin_utf8);
    if (std.mem.eql(u8, path, "/b/gzip.json")) return reply(conn, "200 OK", "application/json", "Content-Encoding: gzip\r\n", &gz_json);
    if (std.mem.eql(u8, path, "/b/echo")) {
        const nv = headerValue(head, "x-n");
        os.sleepMs(@as(u32, (std.fmt.parseInt(u32, nv, 10) catch 0) % 3) * 40); // 끝나는 차례를 섞는다
        const body = std.fmt.bufPrint(&bb, "{{\"n\":\"{s}\"}}", .{nv}) catch return;
        return reply(conn, "200 OK", "application/json", "", body);
    }
    if (std.mem.eql(u8, path, "/b/chunked.json")) {
        writeAll(conn, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
        for (chunked_parts) |part| {
            var cb: [64]u8 = undefined;
            writeAll(conn, std.fmt.bufPrint(&cb, "{x}\r\n", .{part.len}) catch return);
            writeAll(conn, part);
            writeAll(conn, "\r\n");
            os.sleepMs(30);
        }
        writeAll(conn, "0\r\n\r\n");
        return;
    }
    // 서비스 워커 — 범위 /b/sw/.
    if (std.mem.eql(u8, path, "/b/sw/page")) return reply(conn, "200 OK", html, "", "<!doctype html><title>sw</title><script>" ++
        "navigator.serviceWorker.register('/b/sw/sw.js',{scope:'/b/sw/'}).then(function(){return navigator.serviceWorker.ready}).then(function(){" ++
        "if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}" ++
        "fetch('/b/sw/data.json?'+Date.now()).then(function(r){return r.text()}).then(function(){document.title='sw-done'})})</script>");
    if (std.mem.eql(u8, path, "/b/sw/sw.js")) return reply(conn, "200 OK", "application/javascript", "", "self.addEventListener('install',function(e){self.skipWaiting()});" ++
        "self.addEventListener('activate',function(e){e.waitUntil(self.clients.claim())});self.addEventListener('fetch',function(e){e.respondWith(fetch(e.request))});");
    if (std.mem.eql(u8, path, "/b/sw/data.json")) return reply(conn, "200 OK", "application/json", "", "{\"sw\":\"body\"}");
    // UB1: localhost 가 쿠키를 심는다(SameSite=None; Secure — localhost 는 보안 문맥), 127.0.0.1 페이지가 localhost 의 스크립트를 쿠키와 함께 부른다.
    if (std.mem.eql(u8, path, "/b/setck")) return reply(conn, "200 OK", html, "Set-Cookie: ub1=SECRET; Path=/; SameSite=None; Secure\r\n", "<!doctype html><title>setck</title>set");
    if (std.mem.eql(u8, path, "/b/credpage")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>cred</title><script src=\"http://localhost:{d}/b/cred.js\"></script><script src=\"/b/own.js\"></script>cred", .{p}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/b/cred.js")) {
        const ck = headerValue(head, "cookie");
        const body = std.fmt.bufPrint(&bb, "var cred={{cookie:'{s}'}};", .{ck[0..@min(ck.len, 64)]}) catch return;
        return reply(conn, "200 OK", "application/javascript", "", body);
    }
    if (std.mem.eql(u8, path, "/b/own.js")) return reply(conn, "200 OK", "application/javascript", "", "var own=1;");
    // 설정 끔 — 덮이지 않는 호스트(localhost)의 CORS JSON 과 제 JSON.
    if (std.mem.eql(u8, path, "/b/offpage")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>off</title><script>" ++ read_js_fmt ++ "F('http://localhost:{d}/b/cors.json');F('/b/own.json')</script>off", .{p}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/b/cors.json")) return reply(conn, "200 OK", "application/json", "Access-Control-Allow-Origin: *\r\n", "{\"cors\":1}");
    if (std.mem.eql(u8, path, "/b/own.json")) return reply(conn, "200 OK", "application/json", "", "{\"own\":1}");
    // 쏟아짐 — 60 KiB JSON 쉰 개.
    if (std.mem.eql(u8, path, "/b/flood")) return reply(conn, "200 OK", html, "", "<!doctype html><title>flood</title><script>" ++ read_js ++ "for(var i=0;i<50;i++)F('/b/fl.json?'+i)</script>flood");
    if (std.mem.eql(u8, path, "/b/fl.json")) return reply(conn, "200 OK", "application/json", "", flood_json);
    // 느린 응답(렌더러 죽음·끄기 동안 기다리는 본문).
    if (std.mem.eql(u8, path, "/b/slowpage")) return reply(conn, "200 OK", html, "", "<!doctype html><title>slow</title><script>" ++ read_js ++ "F('/b/slow.json')</script>slow");
    if (std.mem.eql(u8, path, "/b/slow.json")) {
        os.sleepMs(4000);
        return reply(conn, "200 OK", "application/json", "", "{\"slow\":1}");
    }
    if (std.mem.eql(u8, path, "/b/after")) return reply(conn, "200 OK", html, "", "<!doctype html><title>after</title><script>" ++ read_js ++ "F('/b/after.json')</script>after");
    if (std.mem.eql(u8, path, "/b/after.json")) return reply(conn, "200 OK", "application/json", "", "{\"after\":1}");
    return reply(conn, "200 OK", "text/plain", "", "x");
}

// ── 모은 알림 ────────────────────────────────────────────────────────────────────────────────────────────

const Begin = struct { request: u64, url: []u8, expected: bool, sw: bool, xn: []u8 };
/// 기록하는 탭의 본문 알림 차례(같은 번호 다시 시작은 번호 하나에 시도가 둘이라 차례로 가른다).
const LogEv = struct { kind: enum { begin, data, end }, request: u64, expected: bool = false, state: msg.NetBodyState = .unavailable, bytes: []u8 = &.{} };
const Body = struct { request: u64, data: std.ArrayList(u8) = .empty, ends: usize = 0, state: msg.NetBodyState = .unavailable, flags: msg.NetBodyFlags = .{}, decoded: u64 = 0, session: u32 = 0 };

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    begins: std.ArrayList(Begin) = .empty,
    bodies: std.ArrayList(Body) = .empty,
    log: std.ArrayList(LogEv) = .empty,
    loads: [2]u32 = .{ 0, 0 },
    created: [2]bool = .{ false, false },
    record_state: ?msg.NetRecordStatus = null,
    record_session: u32 = 0,
    renderer_gone: bool = false,
    devtools_status: ?msg.DevtoolsStatus = null,

    fn slot(id: u64) ?usize {
        return if (id == rec_tab) 0 else if (id == other_tab) 1 else null;
    }

    fn body(self: *Run, request: u64) *Body {
        for (self.bodies.items) |*b| if (b.request == request) return b;
        self.bodies.append(self.gpa, .{ .request = request }) catch unreachable;
        return &self.bodies.items[self.bodies.items.len - 1];
    }

    fn take(self: *Run, m: msg.Message) void {
        switch (m) {
            .net_begin => |v| if (v.browser == rec_tab) {
                var xn: []const u8 = "";
                var it = net_fields.HeaderIterator.init(v.headers);
                while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "x-n")) {
                    xn = h.value;
                };
                self.begins.append(self.gpa, .{ .request = v.request, .url = self.gpa.dupe(u8, v.url) catch &.{}, .expected = v.flags2.body_expected, .sw = v.flags.service_worker, .xn = self.gpa.dupe(u8, xn) catch &.{} }) catch {};
                self.log.append(self.gpa, .{ .kind = .begin, .request = v.request, .expected = v.flags2.body_expected }) catch {};
            },
            .net_body_data => |v| if (v.browser == rec_tab) {
                const b = self.body(v.request);
                if (v.offset == b.data.items.len) b.data.appendSlice(self.gpa, v.bytes) catch {};
                self.log.append(self.gpa, .{ .kind = .data, .request = v.request, .bytes = self.gpa.dupe(u8, v.bytes) catch &.{} }) catch {};
            },
            .net_body_end => |v| if (v.browser == rec_tab) {
                const b = self.body(v.request);
                b.ends += 1;
                b.state = v.state;
                b.flags = v.flags;
                b.decoded = v.decoded;
                b.session = v.session;
                self.log.append(self.gpa, .{ .kind = .end, .request = v.request, .state = v.state }) catch {};
            },
            .net_record_state => |v| if (v.browser == rec_tab) {
                self.record_state = v.status;
                self.record_session = v.session;
            },
            .renderer_gone => |v| if (v.browser == rec_tab) {
                self.renderer_gone = true;
            },
            .devtools_result => |v| if (v.browser == rec_tab) {
                self.devtools_status = v.status;
            },
            .browser_created => |id| if (slot(id)) |i| {
                self.created[i] = true;
            },
            .load_finished => |v| if (slot(v.browser)) |i| {
                self.loads[i] += 1;
            },
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

    fn until(self: *Run, ms: u32, cond: *const fn (*Run) bool) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline and !cond(self)) {
            const m = (self.host.next(50) catch null) orelse continue;
            self.take(m);
        }
        return cond(self);
    }

    fn beginFor(self: *const Run, from: usize, needle: []const u8) ?*const Begin {
        for (self.begins.items[from..]) |*b| if (std.mem.indexOf(u8, b.url, needle) != null) return b;
        return null;
    }

    fn bodyOf(self: *Run, from: usize, needle: []const u8) ?*Body {
        const b = self.beginFor(from, needle) orelse return null;
        for (self.bodies.items) |*x| if (x.request == b.request) return x;
        return null;
    }

    fn mark(self: *const Run) usize {
        return self.begins.items.len;
    }

    fn navigate(self: *Run, browser: u64, path: []const u8) !void {
        var u: [512]u8 = undefined;
        try self.host.send(.{ .navigate = .{ .browser = browser, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}{s}", .{ port, path }) } });
    }
};

fn stateName(b: ?*Body) []const u8 {
    const x = b orelse return "(no end)";
    if (x.ends == 0) return "(no end)";
    return @tagName(x.state);
}

fn hasState(b: ?*Body, want: msg.NetBodyState) bool {
    const x = b orelse return false;
    return x.ends == 1 and x.state == want;
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    try startServer(gpa);
    var detail: [1200]u8 = undefined;
    // 판정자 전용 진단(`MARU_WEB_TEST_BODY_LOG`)을 이 판정자의 환경에서 sidecar 로 넘긴다(host 는 빈 환경으로 뜬다).
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
    try host.send(.{ .create_browser = .{ .browser = rec_tab, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/b/blank", .{port}) } });
    try host.send(.{ .create_browser = .{ .browser = other_tab, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/b/blank", .{port}) } });
    const Created = struct {
        fn both(x: *Run) bool {
            return x.created[0] and x.created[1] and x.loads[0] >= 1 and x.loads[1] >= 1;
        }
        fn recordOn(x: *Run) bool {
            return x.record_state != null;
        }
    };
    if (!r.until(wait_ms, &Created.both)) return error.BrowserNotCreated;
    // 지켜보기(설정 켬·어느 호스트든 — 에이전트 탭 꼴) 뒤 기록을 켠다.
    try host.send(.{ .net_watch = .{ .browser = rec_tab, .on = true, .full = true, .any_host = true } });
    try host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = 1 } });
    const on_ok = r.until(5000, &Created.recordOn) and r.record_state.? == .on and r.record_session == 1;
    report(on_ok, "body-record-on", std.fmt.bufPrint(&detail, "net_record_state {s} · 세션 {d}", .{ if (r.record_state) |s| @tagName(s) else "-", r.record_session }) catch "");

    // ── 한 페이지: 갈래 ──
    var at = r.mark();
    try r.navigate(rec_tab, "/b/page");
    r.pump(6000);
    {
        const ch = r.bodyOf(at, "/b/chunked.json");
        const want_chunked = chunked_parts[0] ++ chunked_parts[1] ++ chunked_parts[2] ++ chunked_parts[3];
        report(hasState(ch, .captured) and std.mem.eql(u8, ch.?.data.items, want_chunked), "body-captured-chunked", std.fmt.bufPrint(&detail, "{s} · 「{s}」", .{ stateName(ch), if (ch) |b| b.data.items[0..@min(b.data.items.len, 80)] else "" }) catch "");
        const gz = r.bodyOf(at, "/b/gzip.json");
        report(hasState(gz, .captured) and std.mem.eql(u8, gz.?.data.items, gz_plain), "body-captured-gzip", std.fmt.bufPrint(&detail, "{s} · 「{s}」", .{ stateName(gz), if (gz) |b| b.data.items[0..@min(b.data.items.len, 80)] else "" }) catch "");
        const doc = r.bodyOf(at, "/b/page");
        report(hasState(doc, .captured) and std.mem.indexOf(u8, doc.?.data.items, "body page") != null, "body-document", std.fmt.bufPrint(&detail, "{s} · {d} 바이트", .{ stateName(doc), if (doc) |b| b.data.items.len else 0 }) catch "");
        const bj = r.bodyOf(at, "/b/big.json");
        report(hasState(bj, .over_cap) and bj.?.decoded > msg.max_net_body_bytes and bj.?.data.items.len == 0, "body-over-cap-json", std.fmt.bufPrint(&detail, "{s} · 풀어 낸 {d} 바이트", .{ stateName(bj), if (bj) |b| b.decoded else 0 }) catch "");
        const bs = r.bodyOf(at, "/b/big.js");
        report(hasState(bs, .over_cap) and bs.?.decoded > msg.max_net_body_bytes and bs.?.data.items.len == 0, "body-over-cap-script", std.fmt.bufPrint(&detail, "{s} · 풀어 낸 {d} 바이트", .{ stateName(bs), if (bs) |b| b.decoded else 0 }) catch "");
        const pic = r.bodyOf(at, "/b/pic.png");
        report(hasState(pic, .not_text), "body-not-text", stateName(pic));
        const empty = r.bodyOf(at, "/b/empty");
        report(hasState(empty, .no_body), "body-no-body", stateName(empty));
        const cut = r.bodyOf(at, "/b/cut");
        report(hasState(cut, .partial), "body-partial", std.fmt.bufPrint(&detail, "{s} · 받은 {d}", .{ stateName(cut), if (cut) |b| b.decoded else 0 }) catch "");
        const lat = r.bodyOf(at, "/b/latin.txt");
        report(hasState(lat, .captured) and lat.?.flags.redecoded and std.mem.eql(u8, lat.?.data.items, latin_utf8), "body-redecoded", std.fmt.bufPrint(&detail, "{s} · redecoded {} · 「{s}」", .{ stateName(lat), if (lat) |b| b.flags.redecoded else false, if (lat) |b| b.data.items[0..@min(b.data.items.len, 40)] else "" }) catch "");
        // 같은 주소 여덟 — CEF 요청의 x-n 과 그 본문의 n.
        var right: usize = 0;
        var wrong: usize = 0;
        var other_state: usize = 0;
        for (r.begins.items[at..]) |b| if (std.mem.indexOf(u8, b.url, "/b/echo") != null) {
            for (r.bodies.items) |*x| if (x.request == b.request) {
                if (x.ends != 1 or x.state != .captured) {
                    other_state += 1;
                    continue;
                }
                var want: [32]u8 = undefined;
                const w = std.fmt.bufPrint(&want, "{{\"n\":\"{s}\"}}", .{b.xn}) catch "";
                if (std.mem.eql(u8, x.data.items, w)) right += 1 else wrong += 1;
            };
        };
        report(wrong == 0 and right >= 6, "body-join-same-url", std.fmt.bufPrint(&detail, "맞음 {d} · 틀림 {d} · 다른 상태(모호·busy 등) {d}", .{ right, wrong, other_state }) catch "");
        const fr = r.bodyOf(at, "/b/frame.json");
        report(hasState(fr, .unmatched), "body-cross-process-iframe", stateName(fr));
    }

    // ── 같은 번호 다시 시작(W9d① 적대 리뷰 후 × W9d②) — 시도마다 끝 하나, 앞 시도의 끝은 다음 시작보다 먼저, 새 시도의 본문은 200 답의 것 ──
    {
        at = r.mark();
        const log_at = r.log.items.len;
        const served0 = cch_served.load(.monotonic);
        try r.navigate(rec_tab, "/b/cch?restart");
        r.pump(5000);
        const id: u64 = if (r.beginFor(at, "/b/cch")) |b| b.request else 0;
        var attempts: usize = 0;
        var expected: usize = 0;
        var ends = [_]usize{ 0, 0, 0 };
        var states = [_]?msg.NetBodyState{ null, null, null };
        var data = [_]std.ArrayList(u8){ .empty, .empty, .empty };
        var shape: [256]u8 = undefined;
        var shape_len: usize = 0;
        for (r.log.items[log_at..]) |e| if (id != 0 and e.request == id) {
            const tag: []const u8 = switch (e.kind) {
                .begin => if (e.expected) "B+ " else "B- ",
                .data => "D ",
                .end => @tagName(e.state),
            };
            const piece = std.fmt.bufPrint(shape[shape_len..], "{s}{s}", .{ tag, if (e.kind == .end) " " else "" }) catch "";
            shape_len += piece.len;
            switch (e.kind) {
                .begin => {
                    attempts += 1;
                    expected += @intFromBool(e.expected);
                },
                .data => if (attempts > 0 and attempts <= 3) data[attempts - 1].appendSlice(gpa, e.bytes) catch {},
                .end => if (attempts > 0 and attempts <= 3) {
                    ends[attempts - 1] += 1;
                    states[attempts - 1] = e.state;
                },
            }
        };
        const served = cch_served.load(.monotonic) - served0;
        const second_ok = states[1] != null and states[1].? == .captured and std.mem.indexOf(u8, data[1].items, "cch-ok-body") != null;
        const first_clean = std.mem.indexOf(u8, data[0].items, "cch-ok-body") == null;
        report(served == 2 and attempts == 2 and expected == 2 and ends[0] == 1 and ends[1] == 1 and second_ok and first_clean, "body-restart-same-id", std.fmt.bufPrint(&detail, "서버가 받은 {d} · 시도 {d}(body_expected {d}) · 시도별 끝 {d}/{d} · 앞 시도 {s}「{s}」 · 새 시도 {s}「{s}」 · 차례 「{s}」", .{ served, attempts, expected, ends[0], ends[1], if (states[0]) |st| @tagName(st) else "-", data[0].items[0..@min(data[0].items.len, 60)], if (states[1]) |st| @tagName(st) else "-", data[1].items[0..@min(data[1].items.len, 60)], shape[0..shape_len] }) catch "");
        for (&data) |*d| d.deinit(gpa);
    }

    // ── 공개 사이트(https — HTTP/2): 인터넷이 없으면 관측으로 ──
    {
        at = r.mark();
        try host.send(.{ .navigate = .{ .browser = rec_tab, .url = "https://example.com/" } });
        r.pump(6000);
        const ex = r.bodyOf(at, "example.com");
        const ok = hasState(ex, .captured) and std.mem.indexOf(u8, ex.?.data.items, "Example Domain") != null;
        report(true, if (ok) "body-captured-h2(net)" else "body-captured-h2(net-obs)", std.fmt.bufPrint(&detail, "{s} · {d} 바이트", .{ stateName(ex), if (ex) |b| b.data.items.len else 0 }) catch "");
    }

    // ── 서비스 워커 ──
    {
        at = r.mark();
        try r.navigate(rec_tab, "/b/sw/page");
        r.pump(6000);
        var data: ?*Body = null;
        var sw_flag = false;
        for (r.begins.items[at..]) |b| if (std.mem.indexOf(u8, b.url, "/b/sw/data.json") != null) {
            for (r.bodies.items) |*x| if (x.request == b.request and x.ends == 1 and x.state == .captured) {
                data = x;
                sw_flag = b.sw;
            };
        };
        report(data != null and std.mem.eql(u8, data.?.data.items, "{\"sw\":\"body\"}"), "body-service-worker", std.fmt.bufPrint(&detail, "본문 {s} · 서비스 워커 갈래 {}", .{ if (data) |d| d.data.items else "(없음)", sw_flag }) catch "");
    }

    // ── UB1: 다른 사이트에서 쿠키가 실린 스크립트 ──
    {
        var bu: [256]u8 = undefined;
        try host.send(.{ .navigate = .{ .browser = rec_tab, .url = try std.fmt.bufPrint(&bu, "http://localhost:{d}/b/setck", .{port}) } });
        r.pump(1500);
        at = r.mark();
        try r.navigate(rec_tab, "/b/credpage");
        r.pump(3000);
        const cred = r.bodyOf(at, "/b/cred.js");
        const own = r.bodyOf(at, "/b/own.js");
        const carried = if (cred) |b| std.mem.indexOf(u8, b.data.items, "ub1=SECRET") != null else false;
        const base: net_policy.BodyFacts = .{ .has_body_grant = true, .response_visible = true, .page_covered = true, .after_grant = true, .body_host = "127.0.0.1", .final_host = "localhost", .credentialed = if (cred) |b| b.flags.credentialed else false };
        var with_cookie = base;
        with_cookie.cookie_host = "localhost";
        const hidden = net_policy.bodyAccess(base) == .needs_cookie_permission;
        const shown = net_policy.bodyAccess(with_cookie) == .visible;
        const own_plain = if (own) |b| b.ends == 1 and b.state == .captured and !b.flags.credentialed else false;
        report(hasState(cred, .captured) and carried and cred.?.flags.credentialed and hidden and shown and own_plain, "body-ub1-credentialed", std.fmt.bufPrint(&detail, "localhost 스크립트 {s} · 쿠키 실림(본문) {} · credentialed {} · 쿠키 권한 없이 숨김 {} · 있으면 보임 {} · 제 스크립트 실리지 않음 {}", .{ stateName(cred), carried, if (cred) |b| b.flags.credentialed else false, hidden, shown, own_plain }) catch "");
    }

    // ── 설정 끔: 덮이지 않는 호스트의 본문은 받지 않는다 ──
    {
        var w: msg.NetWatch = .{ .browser = rec_tab, .on = true, .full = false, .host_count = 1 };
        w.hosts[0] = "127.0.0.1";
        try host.send(.{ .net_watch = w });
        r.pump(200);
        at = r.mark();
        try r.navigate(rec_tab, "/b/offpage");
        r.pump(3000);
        const cors = r.bodyOf(at, "/b/cors.json");
        const own = r.bodyOf(at, "/b/own.json");
        report(hasState(cors, .not_covered) and hasState(own, .captured), "body-switch-off-prefilter", std.fmt.bufPrint(&detail, "localhost {s} · 127.0.0.1 {s}", .{ stateName(cors), stateName(own) }) catch "");
        try host.send(.{ .net_watch = .{ .browser = rec_tab, .on = true, .full = true, .any_host = true } });
        r.pump(200);
    }

    // ── J7: maru 가 읽지 않는 동안 ──
    {
        at = r.mark();
        const before = pings.load(.monotonic);
        try r.navigate(rec_tab, "/b/flood");
        // 읽지 않는다 — 그동안 다른 탭의 이동을 보낸다(UI 스레드가 처리해야 서버에 닿는다).
        os.sleepMs(1200);
        try r.navigate(other_tab, "/b/ping?j7");
        var reached = false;
        const deadline = os.nowMs() + 2500;
        while (os.nowMs() < deadline) {
            if (pings.load(.monotonic) > before) {
                reached = true;
                break;
            }
            os.sleepMs(50);
        }
        r.pump(8000);
        var captured: usize = 0;
        var busy: usize = 0;
        var ended: usize = 0;
        for (r.begins.items[at..]) |b| if (std.mem.indexOf(u8, b.url, "/b/fl.json") != null) {
            for (r.bodies.items) |*x| if (x.request == b.request and x.ends == 1) {
                ended += 1;
                if (x.state == .captured) captured += 1;
                if (x.state == .busy) busy += 1;
            };
        };
        report(reached and ended >= 40, "body-writer-nonblocking", std.fmt.bufPrint(&detail, "읽지 않는 동안 다른 탭의 이동이 서버에 닿았다 {} · 쉰 개 중 끝 {d}(잡음 {d} · busy {d})", .{ reached, ended, captured, busy }) catch "");
    }

    // ── DevTools 지킴 ──
    {
        r.devtools_status = null;
        try host.send(.{ .devtools_call = .{ .browser = rec_tab, .call = 901, .method = "Network.enable", .params_size = 0 } });
        const Dv = struct {
            fn got(x: *Run) bool {
                return x.devtools_status != null;
            }
        };
        const a = r.until(3000, &Dv.got) and r.devtools_status.? == .invalid_request;
        r.devtools_status = null;
        try host.send(.{ .devtools_call = .{ .browser = rec_tab, .call = 902, .method = "Fetch.enable", .params_size = 0 } });
        const b = r.until(3000, &Dv.got) and r.devtools_status.? == .invalid_request;
        report(a and b, "body-devtools-guard", std.fmt.bufPrint(&detail, "Network.enable 거절 {} · Fetch.enable 거절 {}", .{ a, b }) catch "");
    }

    // ── 렌더러 죽음 ──
    {
        at = r.mark();
        try r.navigate(rec_tab, "/b/slowpage");
        r.pump(1200);
        r.renderer_gone = false;
        try host.send(.{ .devtools_call = .{ .browser = rec_tab, .call = 903, .method = "Page.crash", .params_size = 0 } });
        const Gone = struct {
            fn got(x: *Run) bool {
                return x.renderer_gone;
            }
        };
        const gone = r.until(5000, &Gone.got);
        r.pump(1500);
        const slow = r.bodyOf(at, "/b/slow.json");
        const at2 = r.mark();
        try r.navigate(rec_tab, "/b/after");
        r.pump(3000);
        const after = r.bodyOf(at2, "/b/after.json");
        report(gone and hasState(slow, .detached) and hasState(after, .captured), "body-renderer-crash", std.fmt.bufPrint(&detail, "renderer_gone {} · 받던 본문 {s} · 다시 불러온 뒤 {s}(다시 켜지 않았다)", .{ gone, stateName(slow), stateName(after) }) catch "");
    }

    // ── 끄기 ──
    {
        at = r.mark();
        try r.navigate(rec_tab, "/b/slowpage");
        r.pump(1000);
        r.record_state = null;
        try host.send(.{ .net_record = .{ .browser = rec_tab, .on = false } });
        r.pump(1500);
        const slow = r.bodyOf(at, "/b/slow.json");
        const off_state = r.record_state;
        const at2 = r.mark();
        try r.navigate(rec_tab, "/b/after?off");
        r.pump(2500);
        var later_expected: usize = 0;
        var later: usize = 0;
        for (r.begins.items[at2..]) |b| {
            later += 1;
            if (b.expected) later_expected += 1;
        }
        report(hasState(slow, .recording_stopped) and off_state != null and off_state.? == .off and later > 0 and later_expected == 0, "body-record-off", std.fmt.bufPrint(&detail, "기다리던 본문 {s} · 상태 {s} · 끈 뒤 요청 {d} 중 body_expected {d}", .{ stateName(slow), if (off_state) |s| @tagName(s) else "-", later, later_expected }) catch "");
    }

    // ── 끝은 꼭 하나 ──
    {
        r.pump(4000);
        var expected: usize = 0;
        var missing: usize = 0;
        var doubled: usize = 0;
        var stray: usize = 0;
        // 같은 번호로 다시 시작한 요청은 시도가 여럿이다 — 번호마다 `body_expected` 시작 수와 끝 수를 견준다(한 번호는 한 번만 센다).
        for (r.begins.items, 0..) |b, i| if (b.expected) {
            expected += 1;
            const first = for (r.begins.items[0..i]) |o| {
                if (o.request == b.request and o.expected) break false;
            } else true;
            if (!first) continue;
            var want: usize = 0;
            for (r.begins.items[i..]) |o| want += @intFromBool(o.request == b.request and o.expected);
            var got: usize = 0;
            for (r.bodies.items) |*x| if (x.request == b.request) {
                got = x.ends;
            };
            if (got < want) missing += want - got;
            if (got > want) doubled += got - want;
        };
        for (r.bodies.items) |*x| {
            const known = for (r.begins.items) |b| {
                if (b.request == x.request and b.expected) break true;
            } else false;
            if (!known) stray += 1;
        }
        report(expected > 0 and missing == 0 and doubled == 0 and stray == 0, "body-one-end-each", std.fmt.bufPrint(&detail, "body_expected {d} · 끝 없음 {d} · 둘 이상 {d} · 시작 없는 끝 {d}", .{ expected, missing, doubled, stray }) catch "");
    }
}
