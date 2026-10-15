//! W9d① 적대 리뷰 4 회차 판정 — 호스트 해석의 일치(`R9d4-host-*`, docs/plans/web-osr-backend.md 「W9d① 적대 리뷰: 4 회차」).
//!
//! 무엇을 보나: 읽는 쪽에게 무엇이 「덮이는」 지는 sidecar 가 온 주소에서 읽어 싣는 호스트 칸(`net_policy.hostOfUrl16`)과 app 이 주소 알림에서
//! 읽는 호스트(`net_policy.hostOfUrl` — grant 호스트·맨 위 문서 호스트가 이것이다)로 정한다. 그 둘이 **CEF 가 실제로 붙은 곳**과 다르면 읽는 쪽이
//! 덮인다고 본 호스트와 요청이 간 호스트가 갈린다(높음). 그래서 문법이 이상하지만 무해한 주소들(대소문자 섞인 호스트·끝의 점·IPv4/IPv6 글자와
//! 포트·퍼센트로 쓴 호스트 글자·IDN·권한 안의 역슬래시·`@` 여럿·2 KiB 자르기 근처의 긴 주소·이상한 `Location`)로 옮기거나 불러 보고, 이 판정의
//! 서버가 **받은 요청의 `Host` 머리**(Chromium 이 붙은 호스트 — `*.localhost` 는 Chromium 이 DNS 없이 루프백으로 푼다)와 세 칸을 맞춘다.
//!
//! 판정: 같으면 통과, sidecar·app 의 칸이 비면 「덮이지 않음(fail closed)」 으로 통과, 비지 않았는데 다르면 실패(높음). 서버가 받지 못한 요청
//! (Chromium 이 거절했다)은 기대한 정규 호스트와 맞춘다.
//! C3 의 전제(관측): 새 문서는 `page_started` 뒤 `url_changed` 차례로 오고(다시 불러오기·뒤로도), 32 KiB 를 넘는 주소는 `page_started` 만 온다 —
//! app 은 그 사이 주소를 「옛 것」 으로 표시한다(`R9d4-nav-order(obs)`·`R9d4-long-url-no-url-changed(obs)`).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;

const msg = protocol.message;
const net_policy = protocol.net_policy;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

// ── 받은 요청을 적는 서버(IPv4 127.0.0.1 과 IPv6 ::1, 같은 포트를 바란다) ───────────────────────────────────────

const AF_INET: c_int = 2;
const AF_INET6: c_int = 30;
const SOCK_STREAM: c_int = 1;
const SockaddrIn = extern struct {
    len: u8 = @sizeOf(SockaddrIn),
    family: u8 = AF_INET,
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = @splat(0),
};
const SockaddrIn6 = extern struct {
    len: u8 = @sizeOf(SockaddrIn6),
    family: u8 = AF_INET6,
    port: u16 = 0,
    flowinfo: u32 = 0,
    addr: [16]u8 = @splat(0),
    scope_id: u32 = 0,
};
extern "c" fn socket(domain: c_int, kind: c_int, protocol_: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: u32) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
extern "c" fn getsockname(fd: c_int, addr: *anyopaque, len: *u32) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, name: c_int, value: *const anyopaque, len: u32) c_int;
const Timeval = extern struct { sec: i64, usec: i32 };

var port4: u16 = 0;
var port6: u16 = 0;

/// 받은 요청 하나 — 경로의 표지(`/m-<표지>`)·`Host` 머리·IPv6 로 받았나.
const Got = struct {
    marker: [24]u8 = undefined,
    marker_len: usize = 0,
    host: [320]u8 = undefined,
    host_len: usize = 0,
    v6: bool = false,
};
var got_lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var got: [128]Got = undefined;
var got_count: usize = 0;

fn startServers() !void {
    const fd4 = socket(AF_INET, SOCK_STREAM, 0);
    if (fd4 < 0) return error.SocketFailed;
    var a4: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (bind(fd4, &a4, @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
    if (listen(fd4, 128) != 0) return error.ListenFailed;
    var len4: u32 = @sizeOf(SockaddrIn);
    if (getsockname(fd4, &a4, &len4) != 0) return error.SocketFailed;
    port4 = std.mem.bigToNative(u16, a4.port);
    (try std.Thread.spawn(.{}, acceptLoop, .{ fd4, false })).detach();
    // IPv6 ::1 — 같은 포트를 먼저 바란다(IPv4 로 매핑된 IPv6 주소도 같은 포트로 닿게). 안 되면 아무 포트.
    const fd6 = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd6 < 0) return error.SocketFailed;
    var a6: SockaddrIn6 = .{ .port = std.mem.nativeToBig(u16, port4) };
    a6.addr[15] = 1;
    if (bind(fd6, &a6, @sizeOf(SockaddrIn6)) != 0) {
        a6.port = 0;
        if (bind(fd6, &a6, @sizeOf(SockaddrIn6)) != 0) return error.BindFailed;
    }
    if (listen(fd6, 128) != 0) return error.ListenFailed;
    var len6: u32 = @sizeOf(SockaddrIn6);
    if (getsockname(fd6, &a6, &len6) != 0) return error.SocketFailed;
    port6 = std.mem.bigToNative(u16, a6.port);
    (try std.Thread.spawn(.{}, acceptLoop, .{ fd6, true })).detach();
}

fn acceptLoop(fd: c_int, v6: bool) void {
    while (true) {
        const conn = accept(fd, null, null);
        if (conn < 0) continue;
        const timeout: Timeval = .{ .sec = 2, .usec = 0 };
        _ = setsockopt(conn, 0xffff, 0x1006, &timeout, @sizeOf(Timeval));
        const t = std.Thread.spawn(.{}, serveOne, .{ conn, v6 }) catch {
            _ = std.c.close(conn);
            continue;
        };
        t.detach();
    }
}

fn reply(conn: c_int, status: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [1024]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nCache-Control: no-store\r\n{s}Connection: close\r\n\r\n", .{ status, body.len, extra }) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, body.ptr, body.len);
}

/// 요청 줄의 대상에서 `/m-` 뒤 표지(글자·숫자). 없으면 빈 글.
fn markerOf(target: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, target, "/m-") orelse return "";
    const rest = target[at + 3 ..];
    var n: usize = 0;
    while (n < rest.len and std.ascii.isAlphanumeric(rest[n])) n += 1;
    return rest[0..n];
}

fn serveOne(conn: c_int, v6: bool) void {
    defer _ = std.c.close(conn);
    // 긴 주소(40 KB 요청 줄)의 `Host` 까지 읽는다 — 머리 끝까지 모은다.
    var req: [64 * 1024]u8 = undefined;
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
    const marker = markerOf(target);
    var host: []const u8 = "";
    var lines = std.mem.splitSequence(u8, head[line_end + 2 ..], "\r\n");
    while (lines.next()) |l| if (l.len > 5 and std.ascii.eqlIgnoreCase(l[0..5], "host:")) {
        host = std.mem.trim(u8, l[5..], " \t");
        break;
    };
    if (marker.len > 0) {
        _ = std.c.pthread_mutex_lock(&got_lock);
        if (got_count < got.len) {
            var g: Got = .{ .v6 = v6 };
            g.marker_len = @min(marker.len, g.marker.len);
            @memcpy(g.marker[0..g.marker_len], marker[0..g.marker_len]);
            g.host_len = @min(host.len, g.host.len);
            @memcpy(g.host[0..g.host_len], host[0..g.host_len]);
            got[got_count] = g;
            got_count += 1;
        }
        _ = std.c.pthread_mutex_unlock(&got_lock);
    }
    var xb: [512]u8 = undefined;
    var bb: [2048]u8 = undefined;
    const p = port4;
    const q = port6;
    // 이상한 `Location` — 다음 홉의 호스트 칸(sidecar 가 CEF 의 새 주소에서 읽는다)과 실제로 붙은 곳을 맞춘다.
    if (std.mem.eql(u8, marker, "r1")) return reply(conn, "302 Found", std.fmt.bufPrint(&xb, "Location: //u@v@A.LocalHost:{d}\\m-r1t\r\n", .{p}) catch return, "");
    if (std.mem.eql(u8, marker, "r2")) return reply(conn, "302 Found", std.fmt.bufPrint(&xb, "Location: http:a.localhost:{d}/m-r2t\r\n", .{p}) catch return, "");
    if (std.mem.eql(u8, marker, "r3")) return reply(conn, "302 Found", std.fmt.bufPrint(&xb, "Location: http:\\\\b.localhost:{d}\\m-r3t\r\n", .{p}) catch return, "");
    if (std.mem.eql(u8, marker, "r4")) return reply(conn, "302 Found", std.fmt.bufPrint(&xb, "Location: http://u:p@a.localhost:{d}/m-r4t\r\n", .{p}) catch return, "");
    // 하위 자원(이미지)으로 부르는 이상한 주소들 — 사용자 정보가 든 하위 자원은 Chromium 이 막는다(그래서 넣지 않는다).
    if (std.mem.eql(u8, marker, "fpage")) return reply(conn, "200 OK", "", std.fmt.bufPrint(&bb, "<!doctype html><title>f</title>" ++
        "<img src=\"http://A.LocalHost.:{d}/m-f1\"><img src=\"http://%61.localhost:{d}/m-f2\"><img src=\"http://[::1]:{d}/m-f3\">" ++
        "<img src=\"http:\\\\a.localhost:{d}\\m-f4\"><img src=\"http://0x7f.1:{d}/m-f5\"><img src=\"//B.LOCALHOST:{d}/m-f6\">", .{ p, p, q, p, p, p }) catch return);
    // 탭이 든 주소 — URL 파서가 지운다(maru 의 navigate 는 제어 글자를 싣지 못해 페이지가 옮긴다).
    if (std.mem.eql(u8, marker, "tabpage")) return reply(conn, "200 OK", "", std.fmt.bufPrint(&bb, "<!doctype html><title>t</title><script>location.href='http://a.loc\\talhost:{d}/m-25'</script>", .{p}) catch return);
    // 32 KiB 를 넘는 주소로 페이지가 스스로 옮긴다(C3 — sidecar 는 url_changed 를 보내지 않는다).
    if (std.mem.eql(u8, marker, "longpage")) return reply(conn, "200 OK", "", std.fmt.bufPrint(&bb, "<!doctype html><title>l</title><script>location.href='http://c.localhost:{d}/m-lp?'+'x'.repeat(40000)</script>", .{p}) catch return);
    return reply(conn, "200 OK", "", "<!doctype html><title>h</title>h");
}

/// 서버가 그 표지로 받은 요청의 `Host`(포트 없이, 소문자 — `out` 에). 받지 못했으면 null.
fn receivedHost(marker: []const u8, out: []u8, v6: *bool) ?[]const u8 {
    _ = std.c.pthread_mutex_lock(&got_lock);
    defer _ = std.c.pthread_mutex_unlock(&got_lock);
    for (got[0..got_count]) |*g| if (std.mem.eql(u8, g.marker[0..g.marker_len], marker)) {
        var h = g.host[0..g.host_len];
        if (h.len > 0 and h[0] == '[') {
            if (std.mem.indexOfScalar(u8, h, ']')) |e| h = h[0 .. e + 1];
        } else if (std.mem.lastIndexOfScalar(u8, h, ':')) |c| h = h[0..c];
        const len = @min(h.len, out.len);
        for (h[0..len], out[0..len]) |ch, *o| o.* = std.ascii.toLower(ch);
        v6.* = g.v6;
        return out[0..len];
    };
    return null;
}

// ── 모은 알림 ────────────────────────────────────────────────────────────────────────────────────────────

const Seen = struct {
    tag: msg.Tag,
    request: u64 = 0,
    url: []u8 = &.{},
    host: []u8 = &.{},
};

const Collect = struct {
    host: *Host,
    browser: u64,
    gpa: std.mem.Allocator,
    seen: std.ArrayList(Seen) = .empty,

    fn dupe(self: *Collect, s: []const u8) []u8 {
        return self.gpa.dupe(u8, s) catch &.{};
    }

    fn take(self: *Collect, m: msg.Message) void {
        const s: ?Seen = switch (m) {
            .net_begin => |v| if (v.browser == self.browser) .{ .tag = .net_begin, .request = v.request, .url = self.dupe(v.url), .host = self.dupe(v.host) } else null,
            .net_redirect => |v| if (v.browser == self.browser) .{ .tag = .net_redirect, .request = v.request, .url = self.dupe(v.url), .host = self.dupe(v.host) } else null,
            .url_changed => |v| if (v.browser == self.browser) .{ .tag = .url_changed, .url = self.dupe(v.url) } else null,
            .page_started => |id| if (id == self.browser) .{ .tag = .page_started } else null,
            else => null,
        };
        if (s) |x| self.seen.append(self.gpa, x) catch {};
    }

    fn pump(self: *Collect, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            const m = (self.host.next(20) catch null) orelse continue;
            self.take(m);
        }
    }

    fn mark(self: *const Collect) usize {
        return self.seen.items.len;
    }

    fn find(self: *const Collect, from: usize, tag: msg.Tag, needle: []const u8) ?*const Seen {
        for (self.seen.items[from..]) |*s| if (s.tag == tag and std.mem.indexOf(u8, s.url, needle) != null) return s;
        return null;
    }

    fn lastUrlChanged(self: *const Collect, from: usize) ?*const Seen {
        var out: ?*const Seen = null;
        for (self.seen.items[from..]) |*s| if (s.tag == .url_changed) {
            out = s;
        };
        return out;
    }
};

// ── 시나리오 ─────────────────────────────────────────────────────────────────────────────────────────────

const How = enum { navigate, page, redirect, subresource };

const Case = struct {
    name: []const u8,
    marker: []const u8,
    how: How,
    /// 옮길 주소의 틀 — `{P}` 는 IPv4 포트, `{Q}` 는 IPv6 포트(`navigate`). 아니면 부를 페이지의 표지.
    url: []const u8 = "",
    /// 서버가 받지 못했을 때 맞출 정규 호스트(Chromium 의 GURL 꼴).
    canonical: []const u8,
};

const cases = [_]Case{
    .{ .name = "mixed-case", .marker = "01", .how = .navigate, .url = "http://A.LocalHost:{P}/m-01", .canonical = "a.localhost" },
    .{ .name = "trailing-dot", .marker = "02", .how = .navigate, .url = "http://a.localhost.:{P}/m-02", .canonical = "a.localhost." },
    .{ .name = "ipv4-literal", .marker = "03", .how = .navigate, .url = "http://127.0.0.1:{P}/m-03", .canonical = "127.0.0.1" },
    .{ .name = "ipv4-hex-short", .marker = "04", .how = .navigate, .url = "http://0x7f.1:{P}/m-04", .canonical = "127.0.0.1" },
    .{ .name = "ipv4-integer", .marker = "05", .how = .navigate, .url = "http://2130706433:{P}/m-05", .canonical = "127.0.0.1" },
    .{ .name = "ipv6-literal", .marker = "06", .how = .navigate, .url = "http://[::1]:{Q}/m-06", .canonical = "[::1]" },
    .{ .name = "ipv6-long-form", .marker = "07", .how = .navigate, .url = "http://[0:0:0:0:0:0:0:1]:{Q}/m-07", .canonical = "[::1]" },
    .{ .name = "ipv6-v4-mapped", .marker = "08", .how = .navigate, .url = "http://[::ffff:127.0.0.1]:{P}/m-08", .canonical = "[::ffff:7f00:1]" },
    .{ .name = "percent-host", .marker = "09", .how = .navigate, .url = "http://%61.localhost:{P}/m-09", .canonical = "a.localhost" },
    .{ .name = "percent-dot", .marker = "10", .how = .navigate, .url = "http://a%2Elocalhost:{P}/m-10", .canonical = "a.localhost" },
    .{ .name = "idn-unicode", .marker = "11", .how = .navigate, .url = "http://한국.localhost:{P}/m-11", .canonical = "xn--3e0b707e.localhost" },
    .{ .name = "idn-punycode", .marker = "12", .how = .navigate, .url = "http://xn--3e0b707e.localhost:{P}/m-12", .canonical = "xn--3e0b707e.localhost" },
    .{ .name = "idn-fullwidth", .marker = "13", .how = .navigate, .url = "http://ａ.localhost:{P}/m-13", .canonical = "a.localhost" },
    .{ .name = "backslash-path", .marker = "14", .how = .navigate, .url = "http://a.localhost:{P}\\m-14", .canonical = "a.localhost" },
    .{ .name = "backslash-scheme", .marker = "15", .how = .navigate, .url = "http:\\\\a.localhost:{P}\\m-15", .canonical = "a.localhost" },
    .{ .name = "backslash-before-at", .marker = "16", .how = .navigate, .url = "http://b.localhost:{P}\\@a.localhost:{P}/m-16", .canonical = "b.localhost" },
    .{ .name = "multi-at", .marker = "17", .how = .navigate, .url = "http://u:p@b.localhost@a.localhost:{P}/m-17", .canonical = "a.localhost" },
    .{ .name = "userinfo-host-port", .marker = "18", .how = .navigate, .url = "http://a.localhost:{P}@b.localhost:{P}/m-18", .canonical = "b.localhost" },
    .{ .name = "userinfo-covered-ip", .marker = "19", .how = .navigate, .url = "http://127.0.0.1:{P}@a.localhost:{P}/m-19", .canonical = "a.localhost" },
    .{ .name = "upper-scheme", .marker = "23", .how = .navigate, .url = "HTTP://A.LOCALHOST:{P}/m-23", .canonical = "a.localhost" },
    .{ .name = "no-slash-special", .marker = "24", .how = .navigate, .url = "http:a.localhost:{P}/m-24", .canonical = "a.localhost" },
    .{ .name = "tab-in-host", .marker = "25", .how = .page, .url = "tabpage", .canonical = "a.localhost" },
    .{ .name = "location-scheme-relative", .marker = "r1t", .how = .redirect, .url = "r1", .canonical = "a.localhost" },
    .{ .name = "location-no-slash-same-scheme", .marker = "r2t", .how = .redirect, .url = "r2", .canonical = "127.0.0.1" },
    .{ .name = "location-backslashes", .marker = "r3t", .how = .redirect, .url = "r3", .canonical = "b.localhost" },
    .{ .name = "location-userinfo", .marker = "r4t", .how = .redirect, .url = "r4", .canonical = "a.localhost" },
    .{ .name = "img-trailing-dot", .marker = "f1", .how = .subresource, .canonical = "a.localhost." },
    .{ .name = "img-percent-host", .marker = "f2", .how = .subresource, .canonical = "a.localhost" },
    .{ .name = "img-ipv6", .marker = "f3", .how = .subresource, .canonical = "[::1]" },
    .{ .name = "img-backslash-scheme", .marker = "f4", .how = .subresource, .canonical = "a.localhost" },
    .{ .name = "img-ipv4-hex", .marker = "f5", .how = .subresource, .canonical = "127.0.0.1" },
    .{ .name = "img-scheme-relative", .marker = "f6", .how = .subresource, .canonical = "b.localhost" },
};

/// 틀의 `{P}`·`{Q}` 를 포트로.
fn fill(buf: []u8, template: []const u8) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < template.len) {
        if (i + 3 <= template.len and template[i] == '{' and template[i + 2] == '}' and (template[i + 1] == 'P' or template[i + 1] == 'Q')) {
            const s = std.fmt.bufPrint(buf[w..], "{d}", .{if (template[i + 1] == 'P') port4 else port6}) catch return buf[0..w];
            w += s.len;
            i += 3;
            continue;
        }
        buf[w] = template[i];
        w += 1;
        i += 1;
    }
    return buf[0..w];
}

const Verdict = struct { ok: bool, note: []const u8 };

/// 한 칸(sidecar·app)을 실제로 붙은 곳(`dest` — 없으면 정규 호스트)과 맞춘다.
fn judge(field: ?[]const u8, dest: []const u8) Verdict {
    const f = field orelse return .{ .ok = true, .note = "없음" };
    if (f.len == 0) return .{ .ok = true, .note = "빈 칸(덮이지 않음 — fail closed)" };
    if (std.mem.eql(u8, f, dest)) return .{ .ok = true, .note = "같다" };
    return .{ .ok = false, .note = "다르다(높음 — 덮인다고 본 호스트와 간 곳이 갈린다)" };
}

pub fn run(report: Report, host: *Host, browser: u64, base_url: []const u8) !void {
    try startServers();
    var col: Collect = .{ .host = host, .browser = browser, .gpa = std.heap.c_allocator };
    var detail: [900]u8 = undefined;
    var ub: [600]u8 = undefined;
    var dh: [320]u8 = undefined;
    // 하위 자원 페이지는 한 번에 — 127.0.0.1 의 페이지가 여러 이상한 주소의 이미지를 부른다.
    var sub_mark: usize = 0;
    var sub_loaded = false;
    for (cases) |c| {
        const at = col.mark();
        switch (c.how) {
            .navigate => try host.send(.{ .navigate = .{ .browser = browser, .url = fill(&ub, c.url) } }),
            .page, .redirect => {
                var pb: [64]u8 = undefined;
                try host.send(.{ .navigate = .{ .browser = browser, .url = fill(&ub, std.fmt.bufPrint(&pb, "http://127.0.0.1:{{P}}/m-{s}", .{c.url}) catch unreachable) } });
            },
            .subresource => if (!sub_loaded) {
                sub_loaded = true;
                sub_mark = at;
                try host.send(.{ .navigate = .{ .browser = browser, .url = fill(&ub, "http://127.0.0.1:{P}/m-fpage") } });
                col.pump(2500);
            },
        }
        if (c.how != .subresource) col.pump(1500);
        var needle_buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "/m-{s}", .{c.marker}) catch unreachable;
        const from = if (c.how == .subresource) sub_mark else at;
        // sidecar 의 칸: 처음 요청(begin) — 리다이렉트면 그 홉(옮겨 갈 주소의 칸).
        const rec = if (c.how == .redirect) col.find(from, .net_redirect, needle) else col.find(from, .net_begin, needle);
        const sidecar: ?[]const u8 = if (rec) |r| r.host else null;
        // app 의 칸: 그 이동 뒤 마지막 주소 알림에서 읽은 호스트(grant 호스트·맨 위 문서 호스트가 이것이다).
        var app: ?[]const u8 = null;
        if (c.how != .subresource) if (col.lastUrlChanged(at)) |uc| {
            app = net_policy.hostOfUrl(uc.url) orelse "";
        };
        var v6 = false;
        const received = receivedHost(c.marker, &dh, &v6);
        const dest = received orelse c.canonical;
        const sv = judge(sidecar, dest);
        const av = judge(app, dest);
        var nb: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "R9d4-host-{s}", .{c.name}) catch unreachable;
        const shown: []const u8 = if (rec) |r| r.url[0..@min(r.url.len, 90)] else "-";
        report(sv.ok and av.ok and (rec != null or received == null), name, std.fmt.bufPrint(&detail, "sidecar 칸 「{s}」({s}) · app 칸 「{s}」({s}) · 받은 서버 Host 「{s}」(IPv6 {}) · 정규 「{s}」 · 실린 주소 「{s}」", .{
            sidecar orelse "-", sv.note,     app orelse "-", av.note,
            received orelse "(받지 못함)",
            v6,                 c.canonical, shown,
        }) catch "");
    }
    // ── 2 KiB 자르기 근처의 긴 주소: 호스트 칸은 온 주소에서 — 길이와 무관하게 같다 ──
    {
        var lb: [2400]u8 = undefined;
        var all_ok = true;
        var parts: [400]u8 = undefined;
        var pl: usize = 0;
        for ([_]usize{ 2046, 2047, 2048, 2049, 2050 }, 0..) |total, i| {
            var pre_buf: [96]u8 = undefined;
            const pre = std.fmt.bufPrint(&pre_buf, "http://d.localhost:{d}/m-20{c}?", .{ port4, @as(u8, 'a') + @as(u8, @intCast(i)) }) catch unreachable;
            @memcpy(lb[0..pre.len], pre);
            @memset(lb[pre.len..total], 'x');
            const at = col.mark();
            try host.send(.{ .navigate = .{ .browser = browser, .url = lb[0..total] } });
            col.pump(1200);
            var mb: [8]u8 = undefined;
            const marker = std.fmt.bufPrint(&mb, "20{c}", .{@as(u8, 'a') + @as(u8, @intCast(i))}) catch unreachable;
            var nb: [16]u8 = undefined;
            const rec = col.find(at, .net_begin, std.fmt.bufPrint(&nb, "/m-{s}", .{marker}) catch unreachable);
            var v6 = false;
            const received = receivedHost(marker, &dh, &v6);
            const v = judge(if (rec) |r| r.host else null, received orelse "d.localhost");
            const ok = v.ok and rec != null;
            all_ok = all_ok and ok;
            const s = std.fmt.bufPrint(parts[pl..], "{d}B:「{s}」/「{s}」 ", .{ total, if (rec) |r| r.host else "-", received orelse "-" }) catch "";
            pl += s.len;
        }
        // 사용자 정보가 2 KiB 자리를 건너는 주소(3 회차의 꼴) — 실제로 붙은 곳과 맞춘다.
        const pad_len = msg.max_net_url_bytes - "http://".len - ".127.0.0.1".len;
        @memset(lb[0..pad_len], 'y');
        var ul: [2400]u8 = undefined;
        const long = std.fmt.bufPrint(&ul, "http://{s}.127.0.0.1zzzz@e.localhost:{d}/m-21", .{ lb[0..pad_len], port4 }) catch unreachable;
        const at = col.mark();
        try host.send(.{ .navigate = .{ .browser = browser, .url = long } });
        col.pump(1500);
        const rec = col.find(at, .net_begin, "e.localhost");
        var v6 = false;
        const received = receivedHost("21", &dh, &v6);
        const v = judge(if (rec) |r| r.host else null, received orelse "e.localhost");
        all_ok = all_ok and v.ok and rec != null;
        report(all_ok, "R9d4-host-long-urls", std.fmt.bufPrint(&detail, "길이별 sidecar 칸/받은 Host: {s}· 2 KiB 를 건너는 사용자 정보: 「{s}」/「{s}」({s})", .{ parts[0..pl], if (rec) |r| r.host else "-", received orelse "-", v.note }) catch "");
    }
    // ── 253 바이트 근처의 긴 호스트 — 넘으면 칸이 빈다(덮이지 않음) ──
    {
        const label = "h" ** 63;
        var hb: [400]u8 = undefined;
        for ([_]struct { name: []const u8, mid: usize }{ .{ .name = "R9d4-host-long-host-250", .mid = 48 }, .{ .name = "R9d4-host-long-host-257", .mid = 55 } }) |lc| {
            const mid = "k" ** 63;
            const h = std.fmt.bufPrint(&hb, "{s}.{s}.{s}.{s}.localhost", .{ label, label, label, mid[0..lc.mid] }) catch unreachable;
            var lu: [600]u8 = undefined;
            const marker = if (lc.mid == 48) "h250" else "h257";
            const u = std.fmt.bufPrint(&lu, "http://{s}:{d}/m-{s}", .{ h, port4, marker }) catch unreachable;
            const at = col.mark();
            try host.send(.{ .navigate = .{ .browser = browser, .url = u } });
            col.pump(1500);
            var nb: [16]u8 = undefined;
            const rec = col.find(at, .net_begin, std.fmt.bufPrint(&nb, "/m-{s}", .{marker}) catch unreachable);
            var v6 = false;
            const received = receivedHost(marker, &dh, &v6);
            var lower: [400]u8 = undefined;
            const canon = std.ascii.lowerString(&lower, h);
            const v = judge(if (rec) |r| r.host else null, received orelse canon);
            report(v.ok, lc.name, std.fmt.bufPrint(&detail, "호스트 {d} 바이트 · sidecar 칸 {d} 바이트({s}) · 서버가 받았다 {} · 요청이 보였다 {}", .{ h.len, if (rec) |r| r.host.len else 0, v.note, received != null, rec != null }) catch "");
        }
    }
    // ── C3 의 전제(관측): 새 문서마다 page_started 뒤 url_changed, 32 KiB 를 넘는 주소는 url_changed 가 없다 ──
    {
        const at = col.mark();
        try host.send(.{ .navigate = .{ .browser = browser, .url = base_url } });
        col.pump(1200);
        try host.send(.{ .navigate = .{ .browser = browser, .url = fill(&ub, "http://a.localhost:{P}/m-o2") } });
        col.pump(1200);
        try host.send(.{ .nav_action = .{ .browser = browser, .action = .back } });
        col.pump(1200);
        try host.send(.{ .nav_action = .{ .browser = browser, .action = .reload } });
        col.pump(1200);
        try host.send(.{ .navigate = .{ .browser = browser, .url = fill(&ub, "http://a.localhost:{P}/m-o2") } });
        col.pump(1200);
        // 차례: page_started 마다 다음 page_started 전에 url_changed 가 왔나, url_changed 가 page_started 없이 앞서 오지 않았나.
        var starts: usize = 0;
        var followed: usize = 0;
        var pending = false;
        for (col.seen.items[at..]) |s| switch (s.tag) {
            .page_started => {
                starts += 1;
                pending = true;
            },
            .url_changed => if (pending) {
                followed += 1;
                pending = false;
            },
            else => {},
        };
        report(starts >= 5 and followed == starts, "R9d4-nav-order(obs)", std.fmt.bufPrint(&detail, "새 문서 {d} · 그 뒤 다음 문서 전에 url_changed 가 온 것 {d}(이동·이동·뒤로·다시 불러오기·같은 주소)", .{ starts, followed }) catch "");
        const at2 = col.mark();
        try host.send(.{ .navigate = .{ .browser = browser, .url = fill(&ub, "http://127.0.0.1:{P}/m-longpage") } });
        col.pump(3000);
        var page_starts: usize = 0;
        var url_changes: usize = 0;
        var long_begin: ?*const Seen = null;
        var after_long = false;
        for (col.seen.items[at2..]) |*s| {
            if (s.tag == .net_begin and std.mem.indexOf(u8, s.url, "/m-lp") != null) {
                long_begin = s;
                after_long = true;
            }
            if (!after_long) continue;
            if (s.tag == .page_started) page_starts += 1;
            if (s.tag == .url_changed) url_changes += 1;
        }
        var v6 = false;
        const received = receivedHost("lp", &dh, &v6);
        report(long_begin != null and page_starts == 1 and url_changes == 0, "R9d4-long-url-no-url-changed(obs)", std.fmt.bufPrint(&detail, "40 KB 주소: 요청 {}(sidecar 칸 「{s}」 · 받은 Host 「{s}」) · 그 뒤 page_started {d} · url_changed {d}", .{ long_begin != null, if (long_begin) |b| b.host else "-", received orelse "-", page_starts, url_changes }) catch "");
    }
    try host.send(.{ .navigate = .{ .browser = browser, .url = base_url } });
    col.pump(800);
}
