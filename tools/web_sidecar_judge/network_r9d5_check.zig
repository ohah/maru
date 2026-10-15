//! W9d① 적대 리뷰 5 회차 판정(이름 `R9d5-*` — `--network` 끝에 따로 띄운 sidecar 로, docs/plans/web-osr-backend.md 「W9d① 적대 리뷰: 5 회차」).
//!
//!   R9d5-stale-*(obs)                    4 회차가 재지 않은 주 프레임 흐름(처음 about:blank·bfcache 뒤로·`javascript:` 주소 문서·같은 문서 안 이동·204·
//!                                        오류 페이지·스크립트 다시 불러오기·prerender 활성화·같은 주소 `location.replace`·같은 주소 form POST·meta
//!                                        refresh·`document.open`)에서 `page_started` 마다 뒤에 `url_changed` 가 오는가. 안 오면 maru 의 `Surface.url_stale`
//!                                        (page_started 에서 서고 url_changed 에서만 풀린다)이 다음 이동까지 남아 네트워크 판정이 그 탭을 「주소 모름」 으로
//!                                        친다(덮지 않는 쪽 — 첫 사이트가 빈 요청은 묶인 읽는 쪽에게 숨고, 끔에서 다른 탭 읽는 쪽의 서비스 워커 요청은 수만).
//!   R9d5-f2-old-iframe-beacon-after-nav  덮이지 않는 페이지(127.0.0.1 — 「은행」)의 다른 사이트 iframe(b.localhost)이 `pagehide` 에 보낸 비콘·keepalive
//!                                        fetch 는 새 페이지(a.localhost)의 `page_started`·`url_changed` 뒤에 온다. sidecar 가 그 iframe 이 앞 문서의 것임을
//!                                        표시하고(`previous_document`) maru 의 규칙(`web_osr_network.topHostOf` 를 여기서 따라 한다 — 앞 문서 표시면 빈 호스트)이
//!                                        a.localhost 에 묶인 읽는 쪽에게 숨기는가. 고치기 전에는 셋 중 둘(iframe 의 비콘·keepalive)이 보였다.
//!   R9d5-f2-current-iframe-not-flagged   대조: 은행 페이지의 iframe 문서·새 페이지의 iframe 문서와 그 안 요청에는 표시가 서지 않는다(지금 문서의 것).
//!   R9d5-c1-tab-*                        설정 끔(sidecar 가 보내기 전에 덜어 낸다), 덮이는 호스트의 리다이렉트 `Location` 이 사용자 정보를 ASCII 탭 뒤에
//!                                        숨긴다(GURL 은 탭을 지우고 읽는다) — `u:p@` 가 브라우저 프로세스를 나가는가. 고치기 전에는 둘 다 나갔다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const net_fields = protocol.net_fields;
const net_policy = protocol.net_policy;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

// ── 이 판정의 서버(연결마다 스레드) ─────────────────────────────────────────────────────────────────────────

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
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: u32) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
extern "c" fn getsockname(fd: c_int, addr: *anyopaque, len: *u32) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, name: c_int, value: *const anyopaque, len: u32) c_int;
const Timeval = extern struct { sec: i64, usec: i32 };

var port: u16 = 0;

var got_lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var got_buf: [4096]u8 = undefined;
var got_len: usize = 0;

fn startServer() !void {
    const fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var a: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (bind(fd, &a, @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
    if (listen(fd, 128) != 0) return error.ListenFailed;
    var len: u32 = @sizeOf(SockaddrIn);
    if (getsockname(fd, &a, &len) != 0) return error.SocketFailed;
    port = std.mem.bigToNative(u16, a.port);
    (try std.Thread.spawn(.{}, acceptLoop, .{fd})).detach();
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

fn reply(conn: c_int, status: []const u8, extra: []const u8, body: []const u8, store: bool) void {
    var hb: [1024]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\n{s}{s}Connection: close\r\n\r\n", .{ status, body.len, if (store) "" else "Cache-Control: no-store\r\n", extra }) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, body.ptr, body.len);
}

fn noteTarget(target: []const u8) void {
    _ = std.c.pthread_mutex_lock(&got_lock);
    defer _ = std.c.pthread_mutex_unlock(&got_lock);
    const n = @min(target.len, 120);
    if (got_len + n + 1 > got_buf.len) return;
    @memcpy(got_buf[got_len..][0..n], target[0..n]);
    got_buf[got_len + n] = '\n';
    got_len += n + 1;
}

fn received(needle: []const u8) bool {
    _ = std.c.pthread_mutex_lock(&got_lock);
    defer _ = std.c.pthread_mutex_unlock(&got_lock);
    return std.mem.indexOf(u8, got_buf[0..got_len], needle) != null;
}

fn serveOne(conn: c_int) void {
    defer _ = std.c.close(conn);
    var req: [16 * 1024]u8 = undefined;
    var n: usize = 0;
    while (n < req.len) {
        const r = std.c.read(conn, req[n..].ptr, req.len - n);
        if (r <= 0) break;
        n += @intCast(r);
        if (std.mem.indexOf(u8, req[0..n], "\r\n\r\n") != null) break;
    }
    const head = req[0..n];
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    _ = parts.next();
    const target = parts.next() orelse return;
    noteTarget(target);
    var xb: [512]u8 = undefined;
    var bb: [2048]u8 = undefined;
    const p = port;
    const is = struct {
        fn f(t: []const u8, prefix: []const u8) bool {
            return std.mem.startsWith(u8, t, prefix);
        }
    }.f;
    // bfcache 에 들 수 있는 페이지(`Cache-Control: no-store`·unload 처리기 없음) — pageshow 가 `persisted` 를 알린다.
    if (is(target, "/m-bf")) return reply(conn, "200 OK", "", "<!doctype html><title>bf</title><script>addEventListener('pageshow',e=>{fetch('/m-ps'+(e.persisted?'Y':'N')+'-'+location.pathname.slice(1))})</script>bf", true);
    if (is(target, "/m-js")) return reply(conn, "200 OK", "", "<!doctype html><title>js</title><script>setTimeout(()=>{location.href=\"javascript:'<p>replaced</p>'\"},300)</script>js", false);
    if (is(target, "/m-same")) return reply(conn, "200 OK", "", "<!doctype html><title>s</title><script>setTimeout(()=>{history.pushState({},'', '/m-same-pushed');location.hash='h1';history.back()},300)</script>s", false);
    if (is(target, "/m-n204")) return reply(conn, "204 No Content", "", "", false);
    if (is(target, "/m-rel")) return reply(conn, "200 OK", "", "<!doctype html><title>r</title><script>if(!sessionStorage.r){sessionStorage.r=1;setTimeout(()=>location.reload(),300)}</script>r", false);
    if (is(target, "/m-pr1")) return reply(conn, "200 OK", "", "<!doctype html><title>p</title><script type=\"speculationrules\">{\"prerender\":[{\"source\":\"list\",\"urls\":[\"/m-pr2\"]}]}</script><script>setTimeout(()=>{location.href='/m-pr2'},1500)</script>p", true);
    if (is(target, "/m-pr2")) return reply(conn, "200 OK", "", "<!doctype html><title>p2</title>p2", true);
    if (is(target, "/m-rep")) return reply(conn, "200 OK", "", "<!doctype html><title>rp</title><script>if(!sessionStorage.rp){sessionStorage.rp=1;setTimeout(()=>location.replace(location.href),300)}</script>rp", false);
    if (is(target, "/m-post")) return reply(conn, "200 OK", "", "<!doctype html><title>po</title><form method=post action=''><input name=a value=1></form><script>if(!sessionStorage.po){sessionStorage.po=1;setTimeout(()=>document.forms[0].submit(),300)}</script>po", false);
    if (is(target, "/m-meta")) return reply(conn, "200 OK", "", "<!doctype html><title>me</title><script>if(sessionStorage.me){document.title='me2'}else{sessionStorage.me=1;document.write('<meta http-equiv=refresh content=0>')}</script>me", false);
    if (is(target, "/m-dopen")) return reply(conn, "200 OK", "", "<!doctype html><title>do</title><script>onload=()=>setTimeout(()=>{document.open();document.write('<p>new</p>');document.close()},300)</script>do", false);
    // 탭 든 C1: GURL 은 ASCII 탭·줄바꿈을 지우고 읽는다.
    if (is(target, "/m-c1a")) return reply(conn, "302 Found", std.fmt.bufPrint(&xb, "Location: /\t/u:p@a.localhost:{d}/m-c1at\r\n", .{p}) catch return, "", false);
    if (is(target, "/m-c1b")) return reply(conn, "302 Found", std.fmt.bufPrint(&xb, "Location: ht\ttps:u:p@a.localhost:{d}/m-c1bt\r\n", .{p}) catch return, "", false);
    // F2 경쟁: 덮이지 않는 페이지(127.0.0.1)에 다른 사이트 iframe(b.localhost)이 있고, 그 iframe 이 pagehide 에 비콘을 보낸다.
    if (is(target, "/m-bank")) return reply(conn, "200 OK", "", std.fmt.bufPrint(&bb, "<!doctype html><title>bank</title><iframe src=\"http://b.localhost:{d}/m-trk\"></iframe><script>addEventListener('pagehide',()=>navigator.sendBeacon('/m-mbeacon'))</script>bank", .{p}) catch return, false);
    if (is(target, "/m-trk")) return reply(conn, "200 OK", "", "<!doctype html><title>trk</title><script>addEventListener('pagehide',()=>{navigator.sendBeacon('/m-tbeacon?uid=bank-user-42');fetch('/m-tkeep',{keepalive:true,method:'POST',body:'x'})})</script>trk", false);
    // 대조: 새 페이지(a.localhost)의 다른 사이트 iframe — 그 문서와 그 안 fetch 는 지금 문서의 것이다.
    if (is(target, "/m-landing")) return reply(conn, "200 OK", "", std.fmt.bufPrint(&bb, "<!doctype html><title>land</title><iframe src=\"http://b.localhost:{d}/m-inner\"></iframe>land", .{p}) catch return, false);
    if (is(target, "/m-inner-x")) return reply(conn, "200 OK", "", "x", false);
    if (is(target, "/m-inner")) return reply(conn, "200 OK", "", "<!doctype html><title>in</title><script>setTimeout(()=>fetch('/m-inner-x'),200)</script>in", false);
    return reply(conn, "200 OK", "", "<!doctype html><title>h</title>h", false);
}

// ── 모은 알림 ──────────────────────────────────────────────────────────────────────────────────────────────

const Ev = struct { browser: u64, tag: msg.Tag, url: []u8 = &.{}, request: u64 = 0, headers: []u8 = &.{}, hcount: u8 = 0, stripped: bool = false, site: []u8 = &.{}, host: []u8 = &.{}, initiator: []u8 = &.{}, flags: msg.NetFlags = .{}, rt: u8 = 0 };

const Col = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    seen: std.ArrayList(Ev) = .empty,
    created: [4]bool = @splat(false),

    fn dupe(self: *Col, s: []const u8) []u8 {
        return self.gpa.dupe(u8, s) catch &.{};
    }

    fn take(self: *Col, m: msg.Message) void {
        const e: ?Ev = switch (m) {
            .page_started => |id| .{ .browser = id, .tag = .page_started },
            .url_changed => |v| .{ .browser = v.browser, .tag = .url_changed, .url = self.dupe(v.url) },
            .error_page => |id| .{ .browser = id, .tag = .error_page },
            .net_begin => |v| .{ .browser = v.browser, .tag = .net_begin, .url = self.dupe(v.url), .request = v.request, .site = self.dupe(v.site), .host = self.dupe(v.host), .initiator = self.dupe(v.initiator), .flags = v.flags, .rt = v.resource_type },
            .net_redirect => |v| .{ .browser = v.browser, .tag = .net_redirect, .url = self.dupe(v.url), .request = v.request, .headers = self.dupe(v.headers.bytes), .hcount = v.headers.count, .stripped = v.flags.stripped },
            .browser_created => |id| blk: {
                if (id < 4) self.created[id] = true;
                break :blk null;
            },
            else => null,
        };
        if (e) |x| self.seen.append(self.gpa, x) catch {};
    }

    fn pump(self: *Col, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            const m = (self.host.next(20) catch null) orelse continue;
            self.take(m);
        }
    }

    fn mark(self: *const Col) usize {
        return self.seen.items.len;
    }

    /// `from` 부터 `browser` 의 알림 차례 — `S` page_started, `U` url_changed, `E` error_page — 와 마지막 page_started 뒤에 url_changed 가
    /// 없었는가(maru 의 `url_stale` 이 남는다).
    fn seq(self: *const Col, from: usize, browser: u64, out: []u8) struct { text: []const u8, stuck: bool, starts: usize } {
        var n: usize = 0;
        var pending = false;
        var starts: usize = 0;
        for (self.seen.items[from..]) |e| if (e.browser == browser) {
            const ch: u8 = switch (e.tag) {
                .page_started => blk: {
                    pending = true;
                    starts += 1;
                    break :blk 'S';
                },
                .url_changed => blk: {
                    pending = false;
                    break :blk 'U';
                },
                .error_page => 'E',
                else => continue,
            };
            if (n < out.len) {
                out[n] = ch;
                n += 1;
            }
        };
        return .{ .text = out[0..n], .stuck = pending, .starts = starts };
    }
};

fn headerOf(e: *const Ev, name: []const u8) ?[]const u8 {
    var it = net_fields.HeaderIterator.init(.{ .count = e.hcount, .bytes = e.headers });
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    try startServer();
    var host = try Host.spawn(host_path, profile_arg);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(20_000);
    }
    try browsers_check.handshake(&host);
    var col: Col = .{ .host = &host, .gpa = std.heap.c_allocator };
    var detail: [900]u8 = undefined;
    var ub: [512]u8 = undefined;
    var sb: [64]u8 = undefined;
    const size: msg.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
    const tab: u64 = 1;
    const at0 = col.mark();
    try host.send(.{ .create_browser = .{ .browser = tab, .size = size, .hidden = false, .url = "about:blank" } });
    {
        const deadline = os.nowMs() + 20_000;
        while (os.nowMs() < deadline and !col.created[tab]) col.pump(50);
    }
    col.pump(1500);
    {
        const s = col.seq(at0, tab, &sb);
        report(!s.stuck, "R9d5-stale-initial-about-blank(obs)", std.fmt.bufPrint(&detail, "about:blank 으로 만듦: 알림 「{s}」 · url_stale 남음 {}", .{ s.text, s.stuck }) catch "");
    }
    const Flow = struct { name: []const u8, path: []const u8, wait: u32, back: bool = false, second: ?[]const u8 = null };
    const flows = [_]Flow{
        .{ .name = "R9d5-stale-plain(obs)", .path = "/m-plain", .wait = 1200 },
        .{ .name = "R9d5-stale-bfcache-back(obs)", .path = "/m-bf1", .wait = 1200, .second = "/m-bf2", .back = true },
        .{ .name = "R9d5-stale-javascript-url(obs)", .path = "/m-js", .wait = 2000 },
        .{ .name = "R9d5-stale-same-document(obs)", .path = "/m-same", .wait = 2000 },
        .{ .name = "R9d5-stale-204(obs)", .path = "/m-plain2", .wait = 1000, .second = "/m-n204" },
        .{ .name = "R9d5-stale-error-page(obs)", .path = "/m-plain3", .wait = 1000, .second = "http://127.0.0.1:1/refused" },
        .{ .name = "R9d5-stale-script-reload(obs)", .path = "/m-rel", .wait = 2500 },
        .{ .name = "R9d5-stale-prerender(obs)", .path = "/m-pr1", .wait = 4000 },
        .{ .name = "R9d5-stale-replace-same-url(obs)", .path = "/m-rep", .wait = 2500 },
        .{ .name = "R9d5-stale-form-post-same-url(obs)", .path = "/m-post", .wait = 2500 },
        .{ .name = "R9d5-stale-meta-refresh(obs)", .path = "/m-meta", .wait = 2500 },
        .{ .name = "R9d5-stale-document-open(obs)", .path = "/m-dopen", .wait = 2500 },
    };
    for (flows) |f| {
        const at = col.mark();
        try host.send(.{ .navigate = .{ .browser = tab, .url = std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}{s}", .{ port, f.path }) catch unreachable } });
        col.pump(f.wait);
        if (f.second) |s2| {
            const to = if (std.mem.startsWith(u8, s2, "http")) s2 else std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}{s}", .{ port, s2 }) catch unreachable;
            try host.send(.{ .navigate = .{ .browser = tab, .url = to } });
            col.pump(1500);
        }
        if (f.back) {
            try host.send(.{ .nav_action = .{ .browser = tab, .action = .back } });
            col.pump(2000);
        }
        var last_url: []const u8 = "-";
        for (col.seen.items[at..]) |e| if (e.browser == tab and e.tag == .url_changed) {
            last_url = e.url;
        };
        const s = col.seq(at, tab, &sb);
        const extra: []const u8 = if (f.back)
            (if (received("/m-psY-bf1")) "bfcache 복원: 예" else if (received("/m-psN-bf1")) "bfcache 복원: 아니오(새로 불러옴)" else "pageshow 없음")
        else if (std.mem.eql(u8, f.path, "/m-pr1"))
            (if (received("/m-pr2")) "prerender 페이지를 받아 갔다" else "prerender 페이지를 받아 가지 않았다")
        else
            "";
        report(!s.stuck, f.name, std.fmt.bufPrint(&detail, "알림 「{s}」 · url_stale 남음 {} · 마지막 url_changed 「{s}」 {s}", .{ s.text, s.stuck, last_url[0..@min(last_url.len, 80)], extra }) catch "");
    }
    // ── F2 경쟁: 앞(덮이지 않는) 페이지의 다른 사이트 iframe 이 새(덮이는) 페이지의 url_changed 뒤에 비콘을 보낸다 ──
    {
        const w: msg.NetWatch = .{ .browser = tab, .on = true, .full = true, .any_host = true };
        try host.send(.{ .net_watch = w });
        col.pump(200);
        const at_bank = col.mark();
        try host.send(.{ .navigate = .{ .browser = tab, .url = std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/m-bank", .{port}) catch unreachable } });
        col.pump(2500);
        const at = col.mark();
        try host.send(.{ .navigate = .{ .browser = tab, .url = std.fmt.bufPrint(&ub, "http://a.localhost:{d}/m-landing", .{port}) catch unreachable } });
        col.pump(3000);
        // maru 의 차례를 따라 한다: app 의 맨 위 = 마지막 url_changed 의 호스트(page_started 뒤로는 모름 — url_stale), begin 마다
        // `web_osr_network.topHostOf`(앞 문서 표시면 빈 호스트 — 5 회차 B1).
        var app_url: []const u8 = "http://127.0.0.1/";
        var stale = false;
        var lines: [700]u8 = undefined;
        var ll: usize = 0;
        var exposed: usize = 0;
        var seen_beacon: usize = 0;
        var flagged: usize = 0;
        for (col.seen.items[at..]) |*e| if (e.browser == tab) switch (e.tag) {
            .page_started => stale = true,
            .url_changed => {
                app_url = e.url;
                stale = false;
            },
            .net_begin => if (contains(e.url, "beacon") or contains(e.url, "tkeep")) {
                seen_beacon += 1;
                flagged += @intFromBool(e.flags.previous_document);
                const app_top = if (stale) "" else net_policy.hostOfUrl(app_url) orelse "";
                const top = if (e.flags.main_frame and e.rt == 0) e.host else if (e.flags.previous_document) "" else if (e.site.len == 0) app_top else if (app_top.len != 0 and net_policy.sameSite(app_top, e.site)) app_top else e.site;
                const shown = net_policy.hostCovers("a.localhost", top);
                exposed += @intFromBool(shown);
                const part = std.fmt.bufPrint(lines[ll..], "[{s} 첫 사이트「{s}」 sub {} 앞 문서 {} init「{s}」 app_top「{s}」 -> top「{s}」 a.localhost 에게 {}] ", .{ e.url[@min(e.url.len, 22)..@min(e.url.len, 60)], e.site, e.flags.subframe, e.flags.previous_document, e.initiator, app_top, top, shown }) catch "";
                ll += part.len;
            },
            else => {},
        };
        report(seen_beacon > 0 and exposed == 0, "R9d5-f2-old-iframe-beacon-after-nav", std.fmt.bufPrint(&detail, "비콘 {d} · 앞 문서 표시 {d} · a.localhost 에 묶인 읽는 쪽에게 보임 {d} · {s}", .{ seen_beacon, flagged, exposed, lines[0..ll] }) catch "");
        // 대조: 지금 문서의 iframe 문서·그 안 요청에는 표시가 없다(은행 페이지의 /m-trk, 새 페이지의 /m-inner·/m-inner-x).
        var current: usize = 0;
        var wrong: usize = 0;
        for (col.seen.items[at_bank..]) |*e| if (e.browser == tab and e.tag == .net_begin and (contains(e.url, "/m-trk") or contains(e.url, "/m-inner"))) {
            current += 1;
            wrong += @intFromBool(e.flags.previous_document);
        };
        report(current >= 3 and wrong == 0, "R9d5-f2-current-iframe-not-flagged", std.fmt.bufPrint(&detail, "지금 문서의 iframe 요청 {d}(은행의 iframe 문서·새 페이지의 iframe 문서와 그 fetch) · 앞 문서로 잘못 표시 {d}", .{ current, wrong }) catch "");
    }
    // ── 탭 든 C1 — 설정 끔, 127.0.0.1 이 덮인다 ──
    {
        var w: msg.NetWatch = .{ .browser = tab, .on = true, .full = false };
        w.host_count = 1;
        w.hosts[0] = "127.0.0.1";
        try host.send(.{ .net_watch = w });
        col.pump(200);
        for ([_]struct { name: []const u8, path: []const u8, header: []const u8 }{
            .{ .name = "R9d5-c1-tab-scheme-relative-off", .path = "/m-c1a", .header = "Location" },
            .{ .name = "R9d5-c1-tab-in-scheme-off", .path = "/m-c1b", .header = "Location" },
        }) |c| {
            const at = col.mark();
            try host.send(.{ .navigate = .{ .browser = tab, .url = std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}{s}", .{ port, c.path }) catch unreachable } });
            col.pump(2000);
            var value: ?[]const u8 = null;
            var hop_url: []const u8 = "-";
            var stripped = false;
            for (col.seen.items[at..]) |*e| if (e.browser == tab and e.tag == .net_redirect) {
                value = headerOf(e, c.header);
                hop_url = e.url;
                stripped = e.stripped;
                break;
            };
            const leaked = if (value) |v| contains(v, "u:p@") else false;
            var shown: [200]u8 = undefined;
            var sl: usize = 0;
            if (value) |v| for (v) |ch| {
                if (sl + 2 > shown.len) break;
                if (ch == '\t') {
                    shown[sl] = '\\';
                    shown[sl + 1] = 't';
                    sl += 2;
                } else {
                    shown[sl] = ch;
                    sl += 1;
                }
            };
            report(value != null and !leaked, c.name, std.fmt.bufPrint(&detail, "홉 덜어 냄 {} · {s} 「{s}」 · 사용자 정보가 브라우저 프로세스를 나감 {} · 홉 주소 「{s}」", .{ stripped, c.header, shown[0..sl], leaked, hop_url[0..@min(hop_url.len, 90)] }) catch "");
        }
    }
}
