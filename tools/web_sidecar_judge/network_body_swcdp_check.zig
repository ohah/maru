//! W9d② 서비스 워커 CDP 판정(`--review-body-swcdp`, 고른 항목만 `SWCDP_ONLY=detach-off,…` — docs/plans/web-osr-backend.md 「서비스 워커 갈래
//! 새 설계」). 판정자가 maru 역할로 탭 둘(기록하는 A, 기록하지 않는 B)을 열고 sidecar 를 `MARU_WEB_SW_CDP=1`(워커 세션을 붙인다)로 띄운다.
//!
//! 떼기(공격 2 A1 — 기록이 멈추는 모든 길이 `detachWorkers` 를 탄다): 서비스 워커는 시작할 때마다 `/swd/boot` 를 부른다(서버가 센다). 길마다
//! A 를 기록하며 워커 페이지를 띄우고, 그 길로 기록을 멈춘 뒤 40 초 놀린다(Chromium 의 놀이 시한 30 초 — 실측: 붙은 세션을 떼면 +28 초에
//! stopped). 그 뒤 기록하지 않는 B 가 워커 범위의 문서로 옮긴다 — 워커가 멈췄으면 다시 뜨며 `boot` 가 는다.
//!   swcdp-detach-control   기록을 이어 간다 — 붙은 세션이 워커를 살려 둔다(boot 그대로). 플래그가 듣는지의 대조
//!   swcdp-detach-off       기록 끔(`net_record off`)
//!   swcdp-detach-twice     기록을 두 번 켠다(새 세션 — 떼고 다시 건다) — 살아 있어야 하고(boot 그대로), 그 뒤 끔이면 멈춘다
//!   swcdp-detach-valve     쏟아짐 밸브(`paused`)
//!   swcdp-detach-close     탭 닫힘(`destroy_browser`)
//!   swcdp-detach-crash     렌더러 죽음(`Page.crash`) — host 가 살아 있고(공격 2 A11), 새 문서에서 다시 건다(다시 살려 둔다)
//! 켬 실패·등록 실패의 길은 실제 CEF 에서 낼 수 없어 순수 시험(`net_body_table` 의 `.detach_workers`)이 덮는다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const net_fields = protocol.net_fields;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const tab_a: u64 = 141;
const tab_b: u64 = 142;
const wait_ms = 15_000;
/// 놀리는 때 — Chromium 의 서비스 워커 놀이 시한(30 초)보다 넉넉히.
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

var port: u16 = 0;
var counter = std.atomic.Value(u64).init(1);
var boots = std.atomic.Value(u64).init(0);

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

fn reply(conn: c_int, ctype: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [1024]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\n{s}Connection: close\r\n\r\n", .{ ctype, body.len, extra }) catch return;
    writeAll(conn, head);
    writeAll(conn, body);
}

const html = "text/html; charset=utf-8";

/// 워커: 시작할 때마다 `/swd/boot`, 범위 안 요청은 그대로 넘긴다.
const swd_js = "fetch('/swd/boot?t='+Date.now(),{cache:'no-store'}).catch(function(){});" ++
    "self.addEventListener('install',function(){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});" ++
    "self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(u.pathname=='/swd/boot')return;e.respondWith(fetch(e.request))});";
const reg_js = "function reg(next){navigator.serviceWorker.register('/swd/sw.js',{scope:'/swd/'}).then(function(){return navigator.serviceWorker.ready}).then(function(){" ++
    "if(!navigator.serviceWorker.controller){setTimeout(function(){location.reload()},300);return}next()})}";

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
    if (std.mem.eql(u8, path, "/blank")) return reply(conn, html, "", "<!doctype html><title>blank</title>blank");
    if (std.mem.eql(u8, path, "/swd/sw.js")) return reply(conn, "text/javascript", "", swd_js);
    if (std.mem.eql(u8, path, "/swd/boot")) {
        _ = boots.fetchAdd(1, .monotonic);
        return reply(conn, "text/plain", "", "boot");
    }
    // A: 워커를 깔고(다스릴 때까지 다시 불러온다) 범위 안 데이터를 한 번 받는다.
    if (std.mem.eql(u8, path, "/swd/p")) return reply(conn, html, "", "<!doctype html><title>p</title><script>" ++ reg_js ++
        "reg(function(){fetch('/swd/x?k=p',{cache:'no-store'}).then(function(r){return r.text()}).then(function(){document.title='ready'})})</script>p");
    // B: 범위 안의 문서 — 워커가 멈췄으면 이 이동이 다시 띄운다.
    if (std.mem.eql(u8, path, "/swd/probe")) return reply(conn, html, "", "<!doctype html><title>probed</title>probe");
    // 쏟아짐 밸브(v20a r9 와 같다): data: fetch 를 5 초 동안 쉬지 않고 — 워커를 거치지 않는다.
    if (std.mem.eql(u8, path, "/swd/flood")) return reply(conn, html, "", "<!doctype html><title>fl</title><script>" ++
        "var t0=performance.now();var n=0;function burst(){for(var i=0;i<400;i++){fetch('data:application/json,'+(n++)).then(function(r){return r.text()}).catch(function(){})}" ++
        "if(performance.now()-t0<5000)setTimeout(burst,0);else document.title='fldone'}setTimeout(burst,200)</script>fl");
    if (std.mem.eql(u8, path, "/swd/x")) {
        const n = counter.fetchAdd(1, .monotonic);
        var bb: [64]u8 = undefined;
        var eb: [64]u8 = undefined;
        return reply(conn, "application/json", std.fmt.bufPrint(&eb, "X-Served: {d}\r\n", .{n}) catch "", std.fmt.bufPrint(&bb, "{{\"n\":{d}}}", .{n}) catch "");
    }
    return reply(conn, "text/plain", "", "?");
}

// ── 모으기 ────────────────────────────────────────────────────────────────────────────────────────────────

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    created: std.AutoHashMapUnmanaged(u64, void) = .empty,
    loads: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    states: std.AutoHashMapUnmanaged(u64, msg.NetRecordStatus) = .empty,
    state_log: std.ArrayList(struct { browser: u64, session: u32, status: msg.NetRecordStatus }) = .empty,
    titles: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    gone: std.AutoHashMapUnmanaged(u64, void) = .empty,
    closed: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn take(self: *Run, m: msg.Message) void {
        switch (m) {
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

const Want = struct { id: u64, status: msg.NetRecordStatus };
fn stateIs(r: *Run, want: Want) bool {
    const s = r.states.get(want.id) orelse return false;
    return s == want.status;
}

fn enabled(name: []const u8) bool {
    const only = std.c.getenv("SWCDP_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(only), name) != null;
}

fn openTab(r: *Run, id: u64) !void {
    var u: [256]u8 = undefined;
    const size: msg.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
    _ = r.created.remove(id);
    _ = r.loads.remove(id);
    _ = r.closed.remove(id);
    try r.host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/blank", .{port}) } });
    if (!r.waitFor(wait_ms, id, createdAndLoaded)) return error.BrowserNotCreated;
    try r.host.send(.{ .net_watch = .{ .browser = id, .on = true, .full = true, .any_host = true } });
}

fn recordOn(r: *Run, id: u64, session: u32) bool {
    _ = r.states.remove(id);
    r.host.send(.{ .net_record = .{ .browser = id, .on = true, .session = session } }) catch return false;
    return r.waitFor(5000, Want{ .id = id, .status = .on }, stateIs);
}

/// A 를 기록하며 워커 페이지를 띄운다(워커가 다스릴 때까지) — 붙을 틈을 준다.
fn armA(r: *Run, session: u32) !bool {
    const on = recordOn(r, tab_a, session);
    try r.navigate(tab_a, "/swd/p");
    const ready = r.pumpTitle(tab_a, "ready", 20_000);
    r.pump(1500);
    return on and ready;
}

/// 놀린 뒤 B 가 범위 안으로 옮긴다 — 그동안 워커가 다시 떴으면(boot 가 늘었으면) 멈췄던 것이다.
const Idle = struct { stopped: bool, probed: bool, boots_before: u64, boots_after: u64 };
fn idleThenProbe(r: *Run) !Idle {
    const before = boots.load(.monotonic);
    r.pump(idle_ms);
    try r.navigate(tab_b, "/swd/probe");
    const probed = r.pumpTitle(tab_b, "probed", 15_000);
    r.pump(1500);
    const after = boots.load(.monotonic);
    try r.navigate(tab_b, "/blank");
    r.pump(500);
    return .{ .stopped = after > before, .probed = probed, .boots_before = before, .boots_after = after };
}

fn idleLine(x: Idle, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "worker {s} after {d} s idle (boots {d} → {d}, probe {})", .{ if (x.stopped) "stopped" else "kept running", idle_ms / 1000, x.boots_before, x.boots_after, x.probed }) catch "";
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    try startServer();
    var detail: [2000]u8 = undefined;
    var lb: [400]u8 = undefined;
    var env_buf: [4][*:0]const u8 = undefined;
    var env_n: usize = 0;
    // 워커 세션을 붙이는 판정이다 — 플래그를 늘 준다(`SWCDP_FLAG=0` 이면 끈 대조).
    const flag_off = if (std.c.getenv("SWCDP_FLAG")) |v| std.mem.eql(u8, std.mem.span(v), "0") else false;
    env_buf[env_n] = if (flag_off) "MARU_WEB_SW_CDP=0" else "MARU_WEB_SW_CDP=1";
    env_n += 1;
    if (std.c.getenv("MARU_WEB_TEST_BODY_LOG") != null) {
        env_buf[env_n] = "MARU_WEB_TEST_BODY_LOG=1";
        env_n += 1;
    }
    const stderr_path: ?[:0]const u8 = if (std.c.getenv("SWCDP_HOST_STDERR")) |p| std.mem.span(p) else null;
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
    var session: u32 = 10;

    if (enabled("detach-control")) {
        session += 1;
        const armed = try armA(&r, session);
        const x = try idleThenProbe(&r);
        report(armed and x.probed and x.stopped == flag_off, "swcdp-detach-control", std.fmt.bufPrint(&detail, "recording on (flag {s}): {s}", .{ if (flag_off) "off" else "on", idleLine(x, &lb) }) catch "");
    }
    if (enabled("detach-off")) {
        session += 1;
        const armed = try armA(&r, session);
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        const x = try idleThenProbe(&r);
        report(armed and x.probed and x.stopped, "swcdp-detach-off", std.fmt.bufPrint(&detail, "net_record off: {s}", .{idleLine(x, &lb)}) catch "");
    }
    if (enabled("detach-twice")) {
        session += 1;
        const armed = try armA(&r, session);
        session += 1;
        const again = recordOn(&r, tab_a, session); // 켠 채 다시 켬 — 새 세션(떼고 다시 건다)
        r.pump(1500);
        // 워커를 한 번 깨워 다시 붙은 세션이 놀이 시한을 처음부터 세게 한다.
        try r.navigate(tab_a, "/swd/p?again");
        const ready = r.pumpTitle(tab_a, "ready", 20_000);
        r.pump(1500);
        const x = try idleThenProbe(&r);
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        const y = try idleThenProbe(&r);
        var lb2: [400]u8 = undefined;
        report(armed and again and ready and x.probed and x.stopped == flag_off and y.stopped, "swcdp-detach-twice", std.fmt.bufPrint(&detail, "on twice: {s} · then off: {s}", .{ idleLine(x, &lb), idleLine(y, &lb2) }) catch "");
    }
    if (enabled("detach-valve")) {
        session += 1;
        const armed = try armA(&r, session);
        const log_at = r.state_log.items.len;
        try r.navigate(tab_a, "/swd/flood");
        _ = r.pumpTitle(tab_a, "fldone", 20_000);
        r.pump(1000);
        var paused = false;
        for (r.state_log.items[log_at..]) |s| if (s.browser == tab_a and s.status == .paused) {
            paused = true;
        };
        const x = try idleThenProbe(&r);
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        report(armed and paused and x.probed and x.stopped, "swcdp-detach-valve", std.fmt.bufPrint(&detail, "paused {} · {s}", .{ paused, idleLine(x, &lb) }) catch "");
    }
    if (enabled("detach-crash")) {
        session += 1;
        const armed = try armA(&r, session);
        _ = r.gone.remove(tab_a);
        try r.host.send(.{ .devtools_call = .{ .browser = tab_a, .call = 901, .method = "Page.crash", .params_size = 0 } });
        const Gone = struct {
            fn got(x: *Run, id: u64) bool {
                return x.gone.contains(id);
            }
        };
        const gone = r.waitFor(5000, tab_a, Gone.got);
        const x = try idleThenProbe(&r);
        // host 가 살아 있다(공격 2 A11 — 죽은 렌더러에 Target 명령): B 가 옮겼으면 산 것이다. A 를 다시 띄우면(새 렌더러·새 문서) 다시 건다 —
        // 기록은 이어진다(J5).
        try r.navigate(tab_a, "/swd/p?after");
        const ready = r.pumpTitle(tab_a, "ready", 20_000);
        r.pump(1500);
        const y = try idleThenProbe(&r);
        try r.host.send(.{ .net_record = .{ .browser = tab_a, .on = false, .session = 0 } });
        r.pump(500);
        var lb2: [400]u8 = undefined;
        report(armed and gone and x.probed and x.stopped and ready and y.probed and y.stopped == flag_off, "swcdp-detach-crash", std.fmt.bufPrint(&detail, "renderer_gone {} · after crash: {s} · host alive (probe) · reloaded {} · re-armed: {s}", .{ gone, idleLine(x, &lb), ready, idleLine(y, &lb2) }) catch "");
    }
    if (enabled("detach-close")) {
        session += 1;
        const armed = try armA(&r, session);
        try r.host.send(.{ .destroy_browser = tab_a });
        const Closed = struct {
            fn got(x: *Run, id: u64) bool {
                return x.closed.contains(id);
            }
        };
        const closed = r.waitFor(5000, tab_a, Closed.got);
        const x = try idleThenProbe(&r);
        report(armed and closed and x.probed and x.stopped, "swcdp-detach-close", std.fmt.bufPrint(&detail, "closed {} · {s}", .{ closed, idleLine(x, &lb) }) catch "");
        try openTab(&r, tab_a);
    }
    host.send(.shutdown) catch {};
    host_alive = false;
    _ = host.wait(wait_ms);
}
