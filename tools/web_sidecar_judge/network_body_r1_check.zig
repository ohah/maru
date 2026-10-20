//! W9d② 적대 리뷰 1 회차 판정(이름 `body-r1-*` — `--network`·`--network-body` 끝에 따로 띄운 sidecar·프로필로, docs/plans/web-osr-backend.md
//! 「W9d② 적대 리뷰: 1 회차」). 리뷰가 만든 재현 판정을 그대로 옮겼다(리뷰의 이름 `rv-*` 를 괄호에 둔다). 판정자가 maru 역할로 `net_watch`·
//! `net_record` 를 보내고 `net_begin`·`net_body_*`·`net_record_state` 를 모은다.
//!
//!   body-r1-switch-off-redirect(rv-switch-off-redirect)   설정 끔(127.0.0.1 만 덮는다): 덮이는 주소가 80 ms 뒤 덮이지 않는 호스트(localhost)로 302 —
//!                                                        그 본문은 sidecar 를 나가지 않는다(`not_covered`, 바이트 0). 고치기 전에는 CDP 의
//!                                                        `loadingFinished` 가 CEF 응답(10 ms 묶음)보다 먼저 와 시작 호스트로 정해 12/12 가 나갔다(MED-1).
//!   body-r1-switch-off-redirect-slowbody(control)         대조: 머리를 먼저, 본문은 250 ms 뒤 — CEF 응답이 먼저 와 고치기 전에도 `not_covered`.
//!   body-r1-redirect-uncredentialed                       쿠키 없는 다른 호스트 리다이렉트 fetch 는 `credentialed` 가 아니다 — 홉마다 ExtraInfo 를 세는
//!                                                        규칙(LOW-3)이 실린 것으로 잘못 치지 않는다(대조).
//!   body-r1-ub1-redirect-hop(rv-ub1-redirect-hop)         다른 사이트의 쿠키가 리다이렉트 홉에 실린 `<script>`·fetch(include) 본문은 `credentialed`.
//!   body-r1-preflight-body(rv-preflight-body)             CORS 사전 요청 + 본 요청 — 본문은 제 요청에.
//!   body-r1-disk-cache-over-cap(rv-disk-cache-over-cap)   디스크 캐시에서 다시 불러온 1.5 MiB 스크립트도 Σ dataReceived 로 받기 전에 `over_cap`.
//!   body-r1-worker-same-url(rv-worker-same-url)           전용 워커와 페이지가 거의 같은 때 같은 주소를 받는다(CEF 는 워커의 fetch 를 주 프레임의
//!                                                        것으로 적고 페이지의 CDP 에는 없다) — 어느 CEF 요청도 남의 본문을 받지 않는다(페이지의 것은
//!                                                        맞거나 `ambiguous`, 워커의 것은 `unmatched`·`ambiguous`). 고치기 전에는 40 번 중 39–40 번
//!                                                        워커의 요청이 페이지의 본문을 가져갔다(MED-2).
//!   body-r1-slot-leak(rv-slot-leak)                       서로 다른 브라우저 34 개가 기록 켬 → 끔 → 닫기 — 모두 `net_record_state on` 을 받는다.
//!                                                        고치기 전에는 끄기의 `Network.disable` 이 결과 자리를 새어 32 개 뒤로는 답이 없었다(LOW-1).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const net_fields = protocol.net_fields;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const rec_tab: u64 = 81;
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

fn startServer() !void {
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

const read_js = "function F(u,o){return fetch(u,o).then(function(r){return r.text()}).catch(function(){})}";
const read_js_fmt = "function F(u,o){{return fetch(u,o).then(function(r){{return r.text()}}).catch(function(){{}})}}";

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
    const query = if (qi) |i| target[i + 1 ..] else "";
    const p = port;
    var bb: [8192]u8 = undefined;
    const html = "text/html; charset=utf-8";
    if (std.mem.eql(u8, path, "/rv/blank")) return reply(conn, "200 OK", html, "", "<!doctype html><title>blank</title>blank");
    // RV1: 덮이는 페이지 — 덮이는 주소가 80 ms 뒤 덮이지 않는 호스트의 JSON 으로 302.
    if (std.mem.eql(u8, path, "/rv/offredir")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>offredir</title><script>" ++ read_js_fmt ++
            "for(var i=0;i<12;i++)F('/rv/redir?'+i);</script>offredir", .{}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/rv/redir")) {
        os.sleepMs(80);
        var lb: [256]u8 = undefined;
        const loc = std.fmt.bufPrint(&lb, "Location: http://localhost:{d}/rv/secret.json?{s}\r\n", .{ p, query }) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/rv/offredir2")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>offredir2</title><script>" ++ read_js_fmt ++
            "for(var i=0;i<12;i++)F('/rv/redir2?'+i);</script>offredir2", .{}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/rv/redir2")) {
        os.sleepMs(80);
        var lb: [256]u8 = undefined;
        const loc = std.fmt.bufPrint(&lb, "Location: http://localhost:{d}/rv/slowsecret.json?{s}\r\n", .{ p, query }) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/rv/slowsecret.json")) {
        // 머리 먼저, 본문은 250 ms 뒤 — CEF 응답(호스트 localhost → 덮이지 않는다)이 CDP loadingFinished 보다 훨씬 먼저 온다(대조).
        const b = "{\"uncovered\":\"SECRET-FROM-LOCALHOST\"}";
        var hb: [512]u8 = undefined;
        writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", .{b.len}) catch return);
        os.sleepMs(250);
        writeAll(conn, b);
        return;
    }
    // 대조(LOW-3): 쿠키 없이 다른 호스트로 리다이렉트하는 fetch — 홉마다 ExtraInfo 가 온다.
    if (std.mem.eql(u8, path, "/rv/nocred")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>nocred</title><script>" ++ read_js_fmt ++
            "for(var i=0;i<6;i++)F('/rv/r2l.json?nc'+i);</script>nocred", .{}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    // RV4: 리다이렉트 홉의 UB1 — localhost 가 쿠키를 심고, 127.0.0.1 페이지가 localhost 로 리다이렉트하는 제 주소를 불러온다.
    if (std.mem.eql(u8, path, "/rv/setck")) return reply(conn, "200 OK", html, "Set-Cookie: rv=SECRETCK; Path=/; SameSite=None; Secure\r\n", "<!doctype html><title>setck</title>set");
    if (std.mem.eql(u8, path, "/rv/credpage")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>cred</title>" ++
            "<script src=\"/rv/r2l.js?1\"></script><script src=\"/rv/r2l.js?2\"></script><script src=\"/rv/r2l.js?3\"></script><script src=\"/rv/r2l.js?4\"></script>" ++
            "<script src=\"http://localhost:{d}/rv/cred.js?direct\"></script><script>" ++ read_js_fmt ++
            "for(var i=0;i<6;i++)F('/rv/r2l.json?'+i,{{credentials:'include'}});</script>cred", .{p}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/rv/r2l.js") or std.mem.eql(u8, path, "/rv/r2l.json")) {
        var lb: [256]u8 = undefined;
        const tgt = if (std.mem.eql(u8, path, "/rv/r2l.js")) "cred.js" else "cred.json";
        const loc = std.fmt.bufPrint(&lb, "Location: http://localhost:{d}/rv/{s}?{s}\r\n", .{ p, tgt, query }) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/rv/cred.js") or std.mem.eql(u8, path, "/rv/cred.json")) {
        const ck = headerValue(head, "cookie");
        const origin = headerValue(head, "origin");
        var xb: [512]u8 = undefined;
        const extra = std.fmt.bufPrint(&xb, "Access-Control-Allow-Origin: {s}\r\nAccess-Control-Allow-Credentials: true\r\n", .{if (origin.len > 0) origin else "*"}) catch return;
        const body = std.fmt.bufPrint(&bb, "var c='{s}';", .{ck[0..@min(ck.len, 64)]}) catch return;
        return reply(conn, "200 OK", if (std.mem.endsWith(u8, path, ".js")) "application/javascript" else "application/json", extra, body);
    }
    // RV5: 사용자 헤더를 단 다른 출처 fetch → CORS 사전 요청(OPTIONS) + 본 요청.
    if (std.mem.eql(u8, path, "/rv/pfpage")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>pf</title><script>" ++ read_js_fmt ++
            "for(var i=0;i<6;i++)F('http://localhost:{d}/rv/pf.json?'+i,{{headers:{{'x-n':'pf'+i,'content-type':'application/json'}},method:'POST',body:'{{}}'}});</script>pf", .{p}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/rv/pf.json")) {
        const acao = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: x-n, content-type\r\nAccess-Control-Allow-Methods: POST\r\n";
        if (std.mem.startsWith(u8, head, "OPTIONS")) {
            writeAll(conn, "HTTP/1.1 204 No Content\r\n" ++ acao ++ "Connection: close\r\n\r\n");
            return;
        }
        const nv = headerValue(head, "x-n");
        const body = std.fmt.bufPrint(&bb, "{{\"n\":\"{s}\"}}", .{nv}) catch return;
        return reply(conn, "200 OK", "application/json", acao, body);
    }
    // RV6: 캐시되는 1.5 MiB 스크립트 — 둘째는 디스크 캐시에서(다른 사이트로 렌더러를 바꾼 뒤).
    if (std.mem.eql(u8, path, "/rv/cpage")) return reply(conn, "200 OK", html, "", "<!doctype html><title>cpage</title><script src=\"/rv/bigc.js\"></script>cpage");
    if (std.mem.eql(u8, path, "/rv/bigc.js")) {
        var hb: [512]u8 = undefined;
        const n_big: usize = 1536 * 1024;
        writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\nContent-Length: {d}\r\nCache-Control: public, max-age=3600\r\nConnection: close\r\n\r\n", .{n_big}) catch return);
        writeAll(conn, "var bigc=1;/*");
        var chunk: [4096]u8 = undefined;
        @memset(&chunk, ' ');
        var sent: usize = 13;
        while (sent + chunk.len < n_big - 2) : (sent += chunk.len) writeAll(conn, &chunk);
        writeAll(conn, chunk[0 .. n_big - 2 - sent]);
        writeAll(conn, "*/");
        return;
    }
    if (std.mem.eql(u8, path, "/rv/secret.json")) return reply(conn, "200 OK", "application/json", "Access-Control-Allow-Origin: *\r\n", "{\"uncovered\":\"SECRET-FROM-LOCALHOST\"}");
    // RV2: 페이지와 전용 워커가 같은 주소를 받는다.
    if (std.mem.eql(u8, path, "/rv/wpage")) return reply(conn, "200 OK", html, "", "<!doctype html><title>wpage</title><script>" ++ read_js ++
        "var w=new Worker('/rv/w.js');var i=0;function spin(ms){var t=performance.now();while(performance.now()-t<ms){}}" ++
        "function step(){if(i>=40){document.title='wdone';return}var k=i;var u='/rv/echo3?'+k;w.postMessage(k);spin(k%7*0.7);" ++
        "F(u,{headers:{'x-n':'p'+k}});i++;setTimeout(step,120)}w.onmessage=function(){};setTimeout(step,300)</script>wpage");
    if (std.mem.eql(u8, path, "/rv/w.js")) return reply(conn, "200 OK", "application/javascript", "", "onmessage=function(e){var k=e.data;fetch('/rv/echo3?'+k,{headers:{'x-n':'w'+k}}).then(function(r){return r.text()}).catch(function(){})};");
    if (std.mem.eql(u8, path, "/rv/echo3")) {
        const nv = headerValue(head, "x-n");
        os.sleepMs(15);
        const body = std.fmt.bufPrint(&bb, "{{\"n\":\"{s}\"}}", .{nv}) catch return;
        return reply(conn, "200 OK", "application/json", "", body);
    }
    return reply(conn, "200 OK", "text/plain", "", "x");
}

const Begin = struct { browser: u64, request: u64, url: []u8, expected: bool, xn: []u8 };
const Body = struct { browser: u64, request: u64, data: std.ArrayList(u8) = .empty, ends: usize = 0, state: msg.NetBodyState = .unavailable, cred: bool = false, decoded: u64 = 0 };

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    begins: std.ArrayList(Begin) = .empty,
    bodies: std.ArrayList(Body) = .empty,
    created: std.AutoHashMapUnmanaged(u64, void) = .empty,
    closed: std.AutoHashMapUnmanaged(u64, void) = .empty,
    loads: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    states: std.AutoHashMapUnmanaged(u64, msg.NetRecordStatus) = .empty,

    fn body(self: *Run, browser: u64, request: u64) *Body {
        for (self.bodies.items) |*b| if (b.request == request and b.browser == browser) return b;
        self.bodies.append(self.gpa, .{ .browser = browser, .request = request }) catch unreachable;
        return &self.bodies.items[self.bodies.items.len - 1];
    }

    fn take(self: *Run, m: msg.Message) void {
        switch (m) {
            .net_begin => |v| {
                var xn: []const u8 = "";
                var it = net_fields.HeaderIterator.init(v.headers);
                while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "x-n")) {
                    xn = h.value;
                };
                self.begins.append(self.gpa, .{ .browser = v.browser, .request = v.request, .url = self.gpa.dupe(u8, v.url) catch &.{}, .expected = v.flags2.body_expected, .xn = self.gpa.dupe(u8, xn) catch &.{} }) catch {};
            },
            .net_body_data => |v| {
                const b = self.body(v.browser, v.request);
                if (v.offset == b.data.items.len) b.data.appendSlice(self.gpa, v.bytes) catch {};
            },
            .net_body_end => |v| {
                const b = self.body(v.browser, v.request);
                b.ends += 1;
                b.state = v.state;
                b.cred = v.flags.credentialed;
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

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    try startServer();
    var detail: [2000]u8 = undefined;
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
    try host.send(.{ .create_browser = .{ .browser = rec_tab, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/rv/blank", .{port}) } });
    if (!r.waitFor(wait_ms, rec_tab, createdAndLoaded)) return error.BrowserNotCreated;

    // ── RV1: 설정 끔, 덮이는 주소 → 덮이지 않는 호스트 리다이렉트 ──
    {
        var w: msg.NetWatch = .{ .browser = rec_tab, .on = true, .full = false, .host_count = 1 };
        w.hosts[0] = "127.0.0.1";
        try host.send(.{ .net_watch = w });
        try host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = 1 } });
        _ = r.waitFor(5000, rec_tab, hasState);
        for ([_][]const u8{ "/rv/offredir", "/rv/offredir2" }, [_][]const u8{ "/rv/redir?", "/rv/redir2?" }, [_][]const u8{ "body-r1-switch-off-redirect", "body-r1-switch-off-redirect-slowbody(control)" }) |page, needle, name| {
            const at = r.begins.items.len;
            try r.navigate(rec_tab, page);
            r.pump(5000);
            var captured: usize = 0;
            var leaked: usize = 0;
            var not_covered: usize = 0;
            var other: usize = 0;
            var total: usize = 0;
            for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, needle) != null) {
                total += 1;
                const x = r.body(rec_tab, b.request);
                if (x.ends == 1 and x.state == .captured) captured += 1 else if (x.ends == 1 and x.state == .not_covered) not_covered += 1 else other += 1;
                if (std.mem.indexOf(u8, x.data.items, "SECRET-FROM-LOCALHOST") != null) leaked += 1;
            };
            report(total > 0 and captured == 0 and leaked == 0, name, std.fmt.bufPrint(&detail, "redirects {d} · not_covered {d} · captured {d} (uncovered body bytes sent to maru: {d}) · other {d}", .{ total, not_covered, captured, leaked, other }) catch "");
        }
        try host.send(.{ .net_watch = .{ .browser = rec_tab, .on = true, .full = true, .any_host = true } });
        r.pump(200);
    }

    // ── 대조(LOW-3): 쿠키 없는 다른 호스트 리다이렉트는 실린 것이 아니다 — localhost 의 쿠키를 심기 전에 ──
    {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv/nocred");
        r.pump(3000);
        var total: usize = 0;
        var captured: usize = 0;
        var flagged: usize = 0;
        for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, "/rv/r2l.json?nc") != null) {
            total += 1;
            const x = r.body(rec_tab, b.request);
            if (x.ends == 1 and x.state == .captured) captured += 1;
            if (x.cred) flagged += 1;
        };
        report(total > 0 and captured == total and flagged == 0, "body-r1-redirect-uncredentialed", std.fmt.bufPrint(&detail, "redirected fetches {d} · captured {d} · flagged credentialed {d}", .{ total, captured, flagged }) catch "");
    }

    // ── RV4: 쿠키가 리다이렉트 홉에 실릴 때의 credentialed ──
    {
        var bu: [256]u8 = undefined;
        try host.send(.{ .navigate = .{ .browser = rec_tab, .url = try std.fmt.bufPrint(&bu, "http://localhost:{d}/rv/setck", .{port}) } });
        r.pump(1500);
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv/credpage");
        r.pump(4000);
        var with_cookie: usize = 0;
        var flagged: usize = 0;
        var unflagged_with_cookie: usize = 0;
        var states_buf: [600]u8 = undefined;
        var sl: usize = 0;
        for (r.begins.items[at..]) |b| if (b.browser == rec_tab and (std.mem.indexOf(u8, b.url, "/rv/r2l") != null or std.mem.indexOf(u8, b.url, "/rv/cred.js?direct") != null)) {
            const x = r.body(rec_tab, b.request);
            const ck = std.mem.indexOf(u8, x.data.items, "SECRETCK") != null;
            if (ck) with_cookie += 1;
            if (x.cred) flagged += 1;
            if (ck and !x.cred) unflagged_with_cookie += 1;
            const piece = std.fmt.bufPrint(states_buf[sl..], " [{s} {s} cred={} ck={}]", .{ b.url[std.mem.lastIndexOfScalar(u8, b.url, '/').?..], @tagName(x.state), x.cred, ck }) catch "";
            sl += piece.len;
        };
        report(with_cookie > 0 and unflagged_with_cookie == 0, "body-r1-ub1-redirect-hop", std.fmt.bufPrint(&detail, "bodies carrying the cookie {d} · flagged credentialed {d} · cookie but NOT flagged {d} ·{s}", .{ with_cookie, flagged, unflagged_with_cookie, states_buf[0..sl] }) catch "");
    }

    // ── RV5: CORS 사전 요청 + 본 요청 ──
    {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv/pfpage");
        r.pump(4000);
        var buf: [900]u8 = undefined;
        var bl: usize = 0;
        var right: usize = 0;
        var posts: usize = 0;
        for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, "/rv/pf.json") != null) {
            const x = r.body(rec_tab, b.request);
            posts += 1;
            var want: [32]u8 = undefined;
            const wnt = std.fmt.bufPrint(&want, "{{\"n\":\"{s}\"}}", .{b.xn}) catch "";
            if (x.ends == 1 and x.state == .captured and std.mem.eql(u8, x.data.items, wnt)) right += 1;
            const piece = std.fmt.bufPrint(buf[bl..], " [{s} xn={s} {s} {s}]", .{ b.url[std.mem.lastIndexOfScalar(u8, b.url, '/').?..], b.xn, if (x.ends == 1) @tagName(x.state) else "(no end)", x.data.items[0..@min(x.data.items.len, 16)] }) catch "";
            bl += piece.len;
        };
        report(posts > 0 and right == posts, "body-r1-preflight-body", std.fmt.bufPrint(&detail, "CEF requests {d} · right bodies {d} ·{s}", .{ posts, right, buf[0..bl] }) catch "");
    }

    // ── RV6: 디스크 캐시의 넘치는 스크립트 — Σ dataReceived 가 그대로 있는가(없으면 1.5 MiB 본문을 받아 UI 스레드에서 푼다) ──
    {
        var res: [2]struct { state: []const u8 = "(none)", decoded: u64 = 0 } = .{ .{}, .{} };
        for (0..2) |round| {
            const at = r.begins.items.len;
            try r.navigate(rec_tab, "/rv/cpage");
            r.pump(2500);
            for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, "/rv/bigc.js") != null) {
                const x = r.body(rec_tab, b.request);
                res[round] = .{ .state = if (x.ends == 1) @tagName(x.state) else "(no end)", .decoded = x.decoded };
            };
            var bu: [256]u8 = undefined;
            try host.send(.{ .navigate = .{ .browser = rec_tab, .url = try std.fmt.bufPrint(&bu, "http://localhost:{d}/rv/blank", .{port}) } });
            r.pump(1200);
        }
        const ok = std.mem.eql(u8, res[1].state, "over_cap") and res[1].decoded > msg.max_net_body_bytes;
        report(ok, "body-r1-disk-cache-over-cap", std.fmt.bufPrint(&detail, "network load {s} (Σ dataReceived {d}) · disk-cache load {s} (Σ dataReceived {d})", .{ res[0].state, res[0].decoded, res[1].state, res[1].decoded }) catch "");
    }

    // ── RV2: 페이지와 전용 워커가 같은 주소 ──
    {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/rv/wpage");
        r.pump(9000);
        var right: usize = 0;
        var wrong: usize = 0;
        var page_ambiguous: usize = 0;
        var page_other: usize = 0;
        var worker_captured: usize = 0;
        var worker_begins: usize = 0;
        var page_begins: usize = 0;
        var wrong_detail: [600]u8 = undefined;
        var wd_len: usize = 0;
        for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, "/rv/echo3") != null) {
            const is_worker = b.xn.len > 0 and b.xn[0] == 'w';
            if (is_worker) worker_begins += 1 else page_begins += 1;
            const x = r.body(rec_tab, b.request);
            if (x.ends != 1 or x.state != .captured) {
                if (!is_worker) {
                    if (x.ends == 1 and x.state == .ambiguous) page_ambiguous += 1 else page_other += 1;
                }
                continue;
            }
            if (is_worker) worker_captured += 1;
            var want: [32]u8 = undefined;
            const wnt = std.fmt.bufPrint(&want, "{{\"n\":\"{s}\"}}", .{b.xn}) catch "";
            if (std.mem.eql(u8, x.data.items, wnt)) right += 1 else {
                wrong += 1;
                const piece = std.fmt.bufPrint(wrong_detail[wd_len..], " [req {d} x-n {s} got {s}]", .{ b.request, b.xn, x.data.items[0..@min(x.data.items.len, 20)] }) catch "";
                wd_len += piece.len;
            }
        };
        report(wrong == 0 and worker_captured == 0 and page_other == 0 and page_begins > 0, "body-r1-worker-same-url", std.fmt.bufPrint(&detail, "page begins {d} · worker begins {d} · bodies right {d} · wrong {d} · page ambiguous {d} · page other {d} · worker captured {d}{s}", .{ page_begins, worker_begins, right, wrong, page_ambiguous, page_other, worker_captured, wrong_detail[0..wd_len] }) catch "");
    }

    // ── RV3: 켬 결과 자리의 샘 ──
    {
        try host.send(.{ .net_record = .{ .browser = rec_tab, .on = false } });
        r.pump(300);
        var answered: usize = 0;
        var last_ok = false;
        var i: u64 = 0;
        while (i < 34) : (i += 1) {
            const id: u64 = 200 + i;
            try host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = true, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/rv/blank", .{port}) } });
            if (!r.waitFor(wait_ms, id, createdAndLoaded)) {
                report(false, "body-r1-slot-leak", "browser not created");
                return;
            }
            try host.send(.{ .net_watch = .{ .browser = id, .on = true, .full = true, .any_host = true } });
            _ = r.states.remove(id);
            try host.send(.{ .net_record = .{ .browser = id, .on = true, .session = @intCast(i + 10) } });
            const got = r.waitFor(4000, id, hasState) and r.states.get(id).? == .on;
            if (got) answered += 1;
            if (i == 33) last_ok = got;
            try host.send(.{ .net_record = .{ .browser = id, .on = false } });
            r.pump(150);
            try host.send(.{ .destroy_browser = id });
            _ = r.waitFor(wait_ms, id, isClosed);
        }
        report(last_ok and answered == 34, "body-r1-slot-leak", std.fmt.bufPrint(&detail, "net_record_state on answered for {d} of 34 browsers · 34th answered {}", .{ answered, last_ok }) catch "");
    }
}
