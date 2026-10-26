//! W9d② 적대 리뷰 3 회차 판정(`--network`·`--network-body` 끝에 따로 띄운 sidecar·프로필 — 이것만 다시 볼 때는 `--review-body-r3`).
//! 리뷰가 남긴 재현 판정(`rv3-*`)을 고친 뒤의 이름으로 옮겼다(`body-r1-*`·`body-r2-*` 와 같은 꼴):
//!   body-r3-worker-own-late        전용 워커가 같은 주소를 조금 먼저 받고 페이지의 요청은 곧 끝난다(서버 지연 0, 잡음 요청으로 묶음 경계를 흩뜨림) —
//!                                  틀린 본문 0·워커가 받은 본문 0(페이지의 본문은 제 것이거나 없음 — 둘을 가를 수 없으면 `ambiguous`), 끝은 꼭 하나
//!   body-r3-worker-own-late-quiet  같은 것, 잡음 없음
//!   body-r3-worker-after-response  워커가 페이지의 응답을 받은 뒤 같은 주소를 받는다 — 같은 판정, 페이지가 제 본문을 받은 수를 보인다(대가가 줄었나)
//!   body-r3-abort-refetch          fetch 를 곧 abort 하고 같은 주소를 다시(React StrictMode 의 effect 두 번 꼴) — 다시 받은 것은 모두 제 본문
//!   body-r3-poll-sequential        같은 주소를 차례로 20 번(앞 것이 끝난 뒤 다음)
//!   body-r3-burst-reverse          같은 주소 8 개를 한꺼번에 — 서버가 거꾸로 끝낸다, 네 바퀴
//!   body-r3-retry-after-failure    빈 응답으로 실패한 뒤 같은 주소를 다시
//!   body-r3-destroy-pending        큰 본문 20 개가 기다리는 동안 브라우저를 닫는다 — 기대한 시작마다 끝이 꼭 하나

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const net_fields = protocol.net_fields;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const rec_tab: u64 = 91;
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

const read_js = "function F(u,o){return fetch(u,o).then(function(r){return r.text()}).catch(function(){})}" ++
    "function spin(ms){var t=performance.now();while(performance.now()-t<ms){}}";

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
    var bb: [8192]u8 = undefined;
    const html = "text/html; charset=utf-8";
    const nv = headerValue(head, "x-n");
    if (std.mem.eql(u8, path, "/rv3/blank")) return reply(conn, "200 OK", html, "", "<!doctype html><title>blank</title>blank");
    if (std.mem.eql(u8, path, "/rv3/noise")) return reply(conn, "200 OK", "text/plain", "", "n");
    // 워커가 같은 주소를 조금 먼저, 페이지의 요청은 곧 끝난다. ?q=1 이면 잡음 요청을 함께.
    if (std.mem.eql(u8, path, "/rv3/wpage")) {
        const noisy = qi != null;
        return reply(conn, "200 OK", html, "", if (noisy) "<!doctype html><title>w</title><script>" ++ read_js ++
            "var w=new Worker('/rv3/w.js');var i=0;" ++
            "function step(){if(i>=80){document.title='wdone';return}var k=i;var u='/rv3/e?n'+k;fetch('/rv3/noise?'+k).catch(function(){});spin(6+k%4);w.postMessage('n'+k);spin(0.5+k%5*0.6);" ++
            "F(u,{headers:{'x-n':'p'+k}});i++;setTimeout(step,70+Math.random()*25)}w.onmessage=function(){};setTimeout(step,300)</script>w" else "<!doctype html><title>w</title><script>" ++ read_js ++
            "var w=new Worker('/rv3/w.js');var i=0;" ++
            "function step(){if(i>=80){document.title='wdone';return}var k=i;var u='/rv3/e?q'+k;w.postMessage('q'+k);spin(k%5*0.8);" ++
            "F(u,{headers:{'x-n':'p'+k}});i++;setTimeout(step,60+Math.random()*25)}w.onmessage=function(){};setTimeout(step,300)</script>w");
    }
    // 워커가 페이지의 응답 뒤에 같은 주소를 받는다(응답 머리를 받자마자 알린다 — 페이지의 본문은 아직 오는 중일 수 있다).
    if (std.mem.eql(u8, path, "/rv3/wafter")) return reply(conn, "200 OK", html, "", "<!doctype html><title>wa</title><script>" ++ read_js ++
        "var w=new Worker('/rv3/w.js');var i=0;" ++
        "function step(){if(i>=40){document.title='wadone';return}var k=i;var u='/rv3/e?a'+k;" ++
        "fetch(u,{headers:{'x-n':'p'+k}}).then(function(r){w.postMessage('a'+k);return r.text()}).catch(function(){});i++;setTimeout(step,80+Math.random()*25)}w.onmessage=function(){};setTimeout(step,300)</script>wa");
    if (std.mem.eql(u8, path, "/rv3/w.js")) return reply(conn, "200 OK", "application/javascript", "", "onmessage=function(e){var k=e.data;fetch('/rv3/e?'+k,{headers:{'x-n':'w'+k}}).then(function(r){return r.text()}).catch(function(){})};");
    if (std.mem.eql(u8, path, "/rv3/e")) {
        const body = std.fmt.bufPrint(&bb, "{{\"n\":\"{s}\"}}", .{nv}) catch return;
        return reply(conn, "200 OK", "application/json", "", body);
    }
    // abort 한 뒤 같은 주소 다시: 셋 꼴 — 곧(같은 task), 마이크로 task 뒤, setTimeout 0 뒤.
    if (std.mem.eql(u8, path, "/rv3/abort")) return reply(conn, "200 OK", html, "", "<!doctype html><title>a</title><script>" ++ read_js ++
        "var i=0;function step(){if(i>=30){document.title='adone';return}var k=i;var u='/rv3/slow?a'+k;var c=new AbortController();" ++
        "F(u,{signal:c.signal,headers:{'x-n':'x'+k}});var go=function(){F(u,{headers:{'x-n':'p'+k}})};" ++
        "if(k%3==0){c.abort();go()}else if(k%3==1){Promise.resolve().then(function(){c.abort();go()})}else{setTimeout(function(){c.abort();go()},0)}" ++
        "i++;setTimeout(step,150)}setTimeout(step,300)</script>a");
    if (std.mem.eql(u8, path, "/rv3/slow")) {
        os.sleepMs(5);
        const body = std.fmt.bufPrint(&bb, "{{\"n\":\"{s}\"}}", .{nv}) catch return;
        return reply(conn, "200 OK", "application/json", "", body);
    }
    // 차례로 20 번.
    if (std.mem.eql(u8, path, "/rv3/poll")) return reply(conn, "200 OK", html, "", "<!doctype html><title>p</title><script>" ++ read_js ++
        "var k=0;function step(){if(k>=20){document.title='pdone';return}var j=k;k++;F('/rv3/slow?poll',{headers:{'x-n':'p'+j}}).then(function(){setTimeout(step,10)})}setTimeout(step,300)</script>p");
    // 같은 주소 8 개를 한꺼번에, 서버가 거꾸로 끝낸다(x-n 의 둘째 글자가 지연 차례), 네 바퀴.
    if (std.mem.eql(u8, path, "/rv3/burst")) return reply(conn, "200 OK", html, "", "<!doctype html><title>b</title><script>" ++ read_js ++
        "var r=0;function step(){if(r>=4){document.title='bdone';return}for(var j=0;j<8;j++)F('/rv3/rev?b'+r,{headers:{'x-n':'b'+j+'r'+r}});r++;setTimeout(step,700)}setTimeout(step,300)</script>b");
    if (std.mem.eql(u8, path, "/rv3/rev")) {
        const d: u64 = if (nv.len > 1 and nv[1] >= '0' and nv[1] <= '9') nv[1] - '0' else 0;
        os.sleepMs(@intCast((8 - d) * 30));
        const body = std.fmt.bufPrint(&bb, "{{\"n\":\"{s}\"}}", .{nv}) catch return;
        return reply(conn, "200 OK", "application/json", "", body);
    }
    // 빈 응답으로 실패 → 같은 주소 다시.
    if (std.mem.eql(u8, path, "/rv3/retry")) return reply(conn, "200 OK", html, "", "<!doctype html><title>r</title><script>" ++ read_js ++
        "var k=0;function step(){if(k>=10){document.title='rdone';return}var j=k;k++;var u='/rv3/flaky?'+j;" ++
        "fetch(u,{headers:{'x-n':'f'+j}}).then(function(r){return r.text()}).catch(function(){return F(u,{headers:{'x-n':'r'+j}})}).then(function(){setTimeout(step,50)})}setTimeout(step,300)</script>r");
    if (std.mem.eql(u8, path, "/rv3/flaky")) {
        if (nv.len > 0 and nv[0] == 'f') return; // 빈 응답(닫기)
        const body = std.fmt.bufPrint(&bb, "{{\"n\":\"{s}\"}}", .{nv}) catch return;
        return reply(conn, "200 OK", "application/json", "", body);
    }
    // 큰 본문 20 개.
    if (std.mem.eql(u8, path, "/rv3/big")) return reply(conn, "200 OK", html, "", "<!doctype html><title>g</title><script>" ++ read_js ++
        "for(var j=0;j<20;j++)F('/rv3/bigj?'+j);</script>g");
    if (std.mem.eql(u8, path, "/rv3/bigj")) {
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
    return reply(conn, "200 OK", "text/plain", "", "x");
}

const Begin = struct { browser: u64, request: u64, url: []u8, expected: bool, xn: []u8 };
const Body = struct { browser: u64, request: u64, data: std.ArrayList(u8) = .empty, ends: usize = 0, state: msg.NetBodyState = .unavailable };

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

const Tally = struct {
    total: usize = 0,
    expected: usize = 0,
    right: usize = 0,
    wrong: usize = 0,
    ambiguous: usize = 0,
    other: usize = 0,
    by_prefix_captured: [128]usize = @splat(0),
    by_prefix_total: [128]usize = @splat(0),
    by_prefix_other: [128]usize = @splat(0),
    by_prefix_ambiguous: [128]usize = @splat(0),
    by_prefix_right: [128]usize = @splat(0),
    /// 끝이 없거나 둘 이상인 기대한 시작(끝은 꼭 하나).
    no_end: usize = 0,
    states: [16]usize = @splat(0),
    notes: [900]u8 = undefined,
    notes_len: usize = 0,
};

fn tally(r: *Run, browser: u64, at: usize, needle: []const u8) Tally {
    var t: Tally = .{};
    for (r.begins.items[at..]) |b| if (b.browser == browser and std.mem.indexOf(u8, b.url, needle) != null) {
        t.total += 1;
        if (b.expected) t.expected += 1;
        const p: u8 = if (b.xn.len > 0) b.xn[0] & 0x7f else '?';
        t.by_prefix_total[p] += 1;
        const x = r.body(browser, b.request);
        if (x.ends == 1) t.states[@backingInt(x.state)] += 1;
        if (x.ends == 1 and x.state == .captured) {
            t.by_prefix_captured[p] += 1;
            var want: [48]u8 = undefined;
            const wnt = std.fmt.bufPrint(&want, "{{\"n\":\"{s}\"}}", .{b.xn}) catch "";
            if (std.mem.eql(u8, x.data.items, wnt)) {
                t.right += 1;
                t.by_prefix_right[p] += 1;
            } else {
                t.wrong += 1;
                const piece = std.fmt.bufPrint(t.notes[t.notes_len..], " [req {d} x-n {s} got {s}]", .{ b.request, b.xn, x.data.items[0..@min(x.data.items.len, 20)] }) catch "";
                t.notes_len += piece.len;
            }
        } else if (x.ends == 1 and x.state == .ambiguous) {
            t.ambiguous += 1;
            t.by_prefix_ambiguous[p] += 1;
        } else {
            t.other += 1;
            t.by_prefix_other[p] += 1;
            if (b.expected and x.ends != 1) t.no_end += 1;
            const piece = std.fmt.bufPrint(t.notes[t.notes_len..], " [x-n {s} {s}]", .{ b.xn, if (x.ends == 1) @tagName(x.state) else if (x.ends == 0) "(no end)" else "(ends>1)" }) catch "";
            t.notes_len += piece.len;
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

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    try startServer();
    var detail: [2400]u8 = undefined;
    var sl: [400]u8 = undefined;
    var host = try Host.spawnWith(host_path, profile_arg, null, &.{});
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    var r: Run = .{ .host = &host, .gpa = gpa };
    const size: msg.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
    var u: [256]u8 = undefined;
    try host.send(.{ .create_browser = .{ .browser = rec_tab, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/rv3/blank", .{port}) } });
    if (!r.waitFor(wait_ms, rec_tab, createdAndLoaded)) return error.BrowserNotCreated;
    try host.send(.{ .net_watch = .{ .browser = rec_tab, .on = true, .full = true, .any_host = true } });
    try host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = 1 } });
    _ = r.waitFor(5000, rec_tab, hasState);

    const Case = struct { page: []const u8, needle: []const u8, name: []const u8, ms: u32, worker: bool = false };
    const cases = [_]Case{
        .{ .page = "/rv3/wpage?q=1", .needle = "/rv3/e?n", .name = "body-r3-worker-own-late", .ms = 9000, .worker = true },
        .{ .page = "/rv3/wpage", .needle = "/rv3/e?q", .name = "body-r3-worker-own-late-quiet", .ms = 9000, .worker = true },
        .{ .page = "/rv3/wafter", .needle = "/rv3/e?a", .name = "body-r3-worker-after-response", .ms = 9000, .worker = true },
        .{ .page = "/rv3/abort", .needle = "/rv3/slow?a", .name = "body-r3-abort-refetch", .ms = 6000 },
        .{ .page = "/rv3/poll", .needle = "/rv3/slow?poll", .name = "body-r3-poll-sequential", .ms = 3000 },
        .{ .page = "/rv3/burst", .needle = "/rv3/rev?b", .name = "body-r3-burst-reverse", .ms = 4000 },
        .{ .page = "/rv3/retry", .needle = "/rv3/flaky?", .name = "body-r3-retry-after-failure", .ms = 3000 },
    };
    for (cases) |cs| {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, cs.page);
        r.pump(cs.ms);
        const t = tally(&r, rec_tab, at, cs.needle);
        const wcap = t.by_prefix_captured['w'];
        // 워커가 섞인 꼴: 페이지의 본문은 제 것이거나 없다(`ambiguous`·`unmatched` — 고친 뒤의 약속: 다른 요청의 본문을 붙이느니 없음), 워커의
        // 기록은 본문을 받지 않는다, 끝은 꼭 하나.
        const ok = if (cs.worker)
            t.wrong == 0 and wcap == 0 and t.no_end == 0
        else
            // 페이지가 다 받은 요청(w·x·f 밖)은 모두 제 본문. abort 한 요청(x)은 abort 전에 다 받았으면 제 본문을 가질 수 있다(실측 — 렌더러가 늦어
            // setTimeout 0 의 abort 가 응답 뒤에 왔다) — 틀린 본문만 아니면 된다.
            t.wrong == 0 and wcap == 0 and t.right - t.by_prefix_right['w'] - t.by_prefix_right['x'] - t.by_prefix_right['f'] == t.total - t.by_prefix_total['w'] - t.by_prefix_total['x'] - t.by_prefix_total['f'];
        report(ok, cs.name, std.fmt.bufPrint(&detail, "CEF requests {d} (body_expected {d}; w {d} x {d} f {d}) · own body {d} · wrong {d} · ambiguous {d} · other {d} · no/several ends {d} · page p own/ambiguous/other {d}/{d}/{d} · worker/aborted/failed captured {d}/{d}/{d} · states{s} ·{s}", .{ t.total, t.expected, t.by_prefix_total['w'], t.by_prefix_total['x'], t.by_prefix_total['f'], t.right, t.wrong, t.ambiguous, t.other, t.no_end, t.by_prefix_captured['p'], t.by_prefix_ambiguous['p'], t.by_prefix_other['p'], wcap, t.by_prefix_captured['x'], t.by_prefix_captured['f'], stateLine(&t, &sl), t.notes[0..t.notes_len] }) catch "");
    }

    // 큰 본문이 기다리는 동안 닫기.
    {
        const id: u64 = 92;
        try host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/rv3/blank", .{port}) } });
        if (!r.waitFor(wait_ms, id, createdAndLoaded)) return error.BrowserNotCreated;
        try host.send(.{ .net_watch = .{ .browser = id, .on = true, .full = true, .any_host = true } });
        try host.send(.{ .net_record = .{ .browser = id, .on = true, .session = 7 } });
        _ = r.waitFor(5000, id, hasState);
        const at = r.begins.items.len;
        try r.navigate(id, "/rv3/big");
        r.pump(900);
        try host.send(.{ .destroy_browser = id });
        _ = r.waitFor(wait_ms, id, isClosed);
        r.pump(1500);
        var expected: usize = 0;
        var one: usize = 0;
        var zero: usize = 0;
        var many: usize = 0;
        for (r.begins.items[at..]) |b| if (b.browser == id and b.expected) {
            expected += 1;
            const x = r.body(id, b.request);
            if (x.ends == 1) one += 1 else if (x.ends == 0) zero += 1 else many += 1;
        };
        const t = tally(&r, id, at, "/rv3/bigj");
        report(expected > 0 and one == expected, "body-r3-destroy-pending", std.fmt.bufPrint(&detail, "expected begins {d} · one end {d} · no end {d} · several {d} · states{s}", .{ expected, one, zero, many, stateLine(&t, &sl) }) catch "");
    }
}
