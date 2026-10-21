//! W9d② final re-verification rounds 11–20 (verifier v20f B — kept as a regression judge). `--review-body-v20fb`.
//! Real CEF 154, sidecar spawned like maru does. `V20F_ONLY=enc,v1,tog,pause,orphan` to pick items. `V20F_HOSTLOG=<path>` makes the
//! sidecar write its body debug log (`MARU_WEB_TEST_BODY_LOG`) there — the orphan item counts `body: tick` lines in it.
//!   v20f-15-*   encodings that attack V4: UTF-16 BOM with charset=utf-8, UTF-16BE BOM, other MIME, gzip, cached / 304 bodies, XHR,
//!               BOM UTF-8 JSON (false flag?), multi-byte controls (gzip, deflate, br, chunked, cache) that must stay unflagged and exact
//!   v20f-14-*   V1 at the wire: agent tab with the switch off (any_host, full=false) — own first-site responses kept, other sites and hops to
//!               them stripped and not captured; agent navigation to the other site; narrowing (user drove) hides the other site again
//!   v20f-12-*   switch toggled every 70 ms between full and any_host+full=false (the V1 path) with a new session per off
//!   v20f-17/18-* paused stays paused: renderer crash, re-enable/pause cycles, tab close while paused (D2 sequence), re-created browser
//!   v20f-19-*   V3: 300 requests cut by a navigation — ends once as `unavailable`, the 50 ms tick stops afterwards

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const tab_enc: u64 = 301;
const tab_v1: u64 = 302;
const tab_tog: u64 = 303;
const tab_pause: u64 = 304;
const tab_orph: u64 = 305;
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

// ── bodies ──
const utf16le_json = "\xff\xfe{\"k\":\"\xc0\x80\"}"; // same bytes as v20b's D1 repro
const utf16le_ascii = "\xff\xfe" ++ "A\x00B\x00"; // "AB" in UTF-16LE with a BOM
const utf16be_json = "\xfe\xff\x00{\x00\"\x00k\x00\"\x00:\x001\x00}"; // {"k":1} in UTF-16BE with a BOM
const bom8_json = "\xef\xbb\xbf{\"k\":\"caf\xc3\xa9\"}";
const u8_json = "{\"k\":\"\xea\xb0\x80\xeb\x82\x98 caf\xc3\xa9 \xe2\x9c\x93 \xf0\x9f\x98\x80\"}"; // 가나 café ✓ 😀
const gz16 = [_]u8{ 31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 251, 255, 175, 90, 41, 91, 201, 74, 233, 64, 131, 82, 45, 0, 250, 93, 234, 225, 12, 0, 0, 0 };
const gz8_plain = "{\"g\":\"\xea\xb0\x80\xeb\x82\x98\xeb\x8b\xa4 \xc3\xa9 \xe2\x9c\x93\"}";
const gz8 = [_]u8{ 31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 171, 86, 74, 87, 178, 82, 122, 181, 161, 225, 117, 211, 140, 215, 221, 75, 20, 14, 175, 84, 120, 52, 103, 178, 82, 45, 0, 108, 28, 161, 13, 24, 0, 0, 0 };
const df_plain = "{\"deflate\":\"\xea\xb0\x80\xeb\x82\x98\xeb\x8b\xa4\"}";
const df_bytes = [_]u8{ 120, 156, 171, 86, 74, 73, 77, 203, 73, 44, 73, 85, 178, 82, 122, 181, 161, 225, 117, 211, 140, 215, 221, 75, 148, 106, 1, 116, 168, 10, 201 };
const br_plain = "{\"br\":\"brotli-body-\xea\xb0\x80\"}";
const br_bytes = [_]u8{ 143, 11, 128, 123, 34, 98, 114, 34, 58, 34, 98, 114, 111, 116, 108, 105, 45, 98, 111, 100, 121, 45, 234, 176, 128, 34, 125, 3 };

const Mode = enum { plain, cache, etag, chunked };
const Expect = enum {
    /// the text must be the bytes, or what the page read (UTF-8 decode), or carry a mark (chromium_decoded / binary)
    flag_or_exact,
    /// control: captured, byte-exact, no mark (compressed / chunked / cached multi-byte UTF-8 without charset)
    exact_noflag,
};
const EncCase = struct { name: []const u8, ctype: []const u8, body: []const u8, raw: []const u8, extra: []const u8 = "", mode: Mode = .plain, expect: Expect, twice: bool = false };
const enc_cases = [_]EncCase{
    .{ .name = "u16cs", .ctype = "application/json; charset=utf-8", .body = utf16le_json, .raw = utf16le_json, .expect = .flag_or_exact },
    .{ .name = "u16plaincs", .ctype = "text/plain; charset=utf-8", .body = utf16le_ascii, .raw = utf16le_ascii, .expect = .flag_or_exact },
    .{ .name = "u16be", .ctype = "application/json", .body = utf16be_json, .raw = utf16be_json, .expect = .flag_or_exact },
    .{ .name = "u16ascii", .ctype = "application/json", .body = utf16le_ascii, .raw = utf16le_ascii, .expect = .flag_or_exact },
    .{ .name = "u16js", .ctype = "application/javascript", .body = utf16le_json, .raw = utf16le_json, .expect = .flag_or_exact },
    .{ .name = "u16xml", .ctype = "application/xml", .body = utf16le_json, .raw = utf16le_json, .expect = .flag_or_exact },
    .{ .name = "u16gz", .ctype = "application/json", .body = &gz16, .raw = utf16le_json, .extra = "Content-Encoding: gzip\r\n", .expect = .flag_or_exact },
    .{ .name = "u16chunked", .ctype = "application/json", .body = utf16le_json, .raw = utf16le_json, .mode = .chunked, .expect = .flag_or_exact },
    .{ .name = "u16cache", .ctype = "application/json", .body = utf16le_json, .raw = utf16le_json, .mode = .cache, .expect = .flag_or_exact, .twice = true },
    .{ .name = "u16etag", .ctype = "application/json", .body = utf16le_json, .raw = utf16le_json, .mode = .etag, .expect = .flag_or_exact, .twice = true },
    .{ .name = "bom8json", .ctype = "application/json", .body = bom8_json, .raw = bom8_json, .expect = .flag_or_exact },
    .{ .name = "u8json", .ctype = "application/json", .body = u8_json, .raw = u8_json, .expect = .exact_noflag },
    .{ .name = "u8gz", .ctype = "application/json", .body = &gz8, .raw = gz8_plain, .extra = "Content-Encoding: gzip\r\n", .expect = .exact_noflag },
    .{ .name = "u8deflate", .ctype = "application/json", .body = &df_bytes, .raw = df_plain, .extra = "Content-Encoding: deflate\r\n", .expect = .exact_noflag },
    .{ .name = "u8br", .ctype = "application/json", .body = &br_bytes, .raw = br_plain, .extra = "Content-Encoding: br\r\n", .expect = .exact_noflag },
    .{ .name = "u8chunked", .ctype = "application/json", .body = u8_json, .raw = u8_json, .mode = .chunked, .expect = .exact_noflag },
    .{ .name = "u8cache", .ctype = "application/json", .body = u8_json, .raw = u8_json, .mode = .cache, .expect = .exact_noflag, .twice = true },
    .{ .name = "u8etag", .ctype = "application/json", .body = u8_json, .raw = u8_json, .mode = .etag, .expect = .exact_noflag, .twice = true },
};

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

fn replyH(conn: c_int, status: []const u8, ctype: []const u8, cache: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [1024]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: {s}\r\nAccess-Control-Allow-Origin: *\r\n{s}Connection: close\r\n\r\n", .{ status, ctype, body.len, cache, extra }) catch return;
    writeAll(conn, head);
    writeAll(conn, body);
}

fn reply(conn: c_int, ctype: []const u8, body: []const u8) void {
    replyH(conn, "200 OK", ctype, "no-store", "", body);
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

fn websocket(conn: c_int, head: []const u8) void {
    const key = headerValue(head, "sec-websocket-key");
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    var acc: [64]u8 = undefined;
    const accept_key = std.base64.standard.Encoder.encode(&acc, &digest);
    var hb: [256]u8 = undefined;
    writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept_key}) catch return);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = std.c.read(conn, &buf, buf.len);
        if (n <= 0) return;
    }
}

const read_js = "function F(u,o){return fetch(u,o).then(function(r){return r.text()}).catch(function(){})}";

fn serveOne(conn: c_int) void {
    defer _ = std.c.close(conn);
    var req: [8192]u8 = undefined;
    var have: usize = 0;
    while (have < req.len) {
        const n = std.c.read(conn, req[have..].ptr, req.len - have);
        if (n <= 0) break;
        have += @intCast(n);
        if (std.mem.indexOf(u8, req[0..have], "\r\n\r\n") != null) break;
    }
    if (have == 0) return;
    const head = req[0..have];
    const line_end = std.mem.indexOfScalar(u8, head, '\r') orelse head.len;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    _ = parts.next() orelse return;
    const target = parts.next() orelse return;
    const qi = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. qi orelse target.len];
    const query = if (qi) |i| target[i + 1 ..] else "";
    const html = "text/html; charset=utf-8";
    if (std.mem.eql(u8, path, "/f/ws")) return websocket(conn, head);
    if (std.mem.eql(u8, path, "/f/blank")) return reply(conn, html, "<!doctype html><title>blank</title>blank");
    if (std.mem.eql(u8, path, "/f/d")) {
        const n = counter.fetchAdd(1, .monotonic);
        var bb: [96]u8 = undefined;
        return replyH(conn, "200 OK", "application/json", "no-store", "Set-Cookie: v20f=secret; Path=/\r\n", std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{n}) catch return);
    }
    if (std.mem.eql(u8, path, "/f/r")) {
        // /f/r?to=<absolute url> — 302 to it.
        if (!std.mem.startsWith(u8, query, "to=")) return reply(conn, "text/plain", "?");
        var hb: [1024]u8 = undefined;
        return writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nSet-Cookie: v20fr=hop; Path=/\r\nConnection: close\r\n\r\n", .{query[3..]}) catch return);
    }
    if (std.mem.eql(u8, path, "/f/slow")) {
        os.sleepMs(20_000);
        return reply(conn, "application/json", "{\"slow\":1}");
    }
    if (std.mem.eql(u8, path, "/f/slow2")) {
        os.sleepMs(1_500);
        return reply(conn, "application/json", "{\"slow2\":1}");
    }
    // ── 15: encodings ──
    if (std.mem.eql(u8, path, "/f/enc")) {
        const qname = query[0 .. std.mem.indexOfScalar(u8, query, '&') orelse query.len];
        for (enc_cases) |c| if (std.mem.eql(u8, qname, c.name)) {
            switch (c.mode) {
                .plain => return replyH(conn, "200 OK", c.ctype, "no-store", c.extra, c.body),
                .cache => return replyH(conn, "200 OK", c.ctype, "max-age=600", c.extra, c.body),
                .etag => {
                    if (headerValue(head, "if-none-match").len > 0) return writeAll(conn, "HTTP/1.1 304 Not Modified\r\nETag: \"v20f\"\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n");
                    return replyH(conn, "200 OK", c.ctype, "no-cache", "ETag: \"v20f\"\r\n", c.body);
                },
                .chunked => {
                    var hb: [512]u8 = undefined;
                    writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", .{c.ctype}) catch return);
                    // two chunks, split inside a multi-byte character / inside the BOM
                    const cut = @min(@as(usize, 1), c.body.len);
                    for ([_][]const u8{ c.body[0..cut], c.body[cut..] }) |piece| {
                        var cb: [32]u8 = undefined;
                        writeAll(conn, std.fmt.bufPrint(&cb, "{x}\r\n", .{piece.len}) catch return);
                        writeAll(conn, piece);
                        writeAll(conn, "\r\n");
                        os.sleepMs(30);
                    }
                    return writeAll(conn, "0\r\n\r\n");
                },
            }
        };
        return reply(conn, "text/plain", "?");
    }
    if (std.mem.eql(u8, path, "/f/encp")) {
        var pb: [4096]u8 = undefined;
        var n: usize = 0;
        const Ap = struct {
            fn put(buf: []u8, at: *usize, t: []const u8) void {
                if (at.* + t.len > buf.len) return;
                @memcpy(buf[at.*..][0..t.len], t);
                at.* += t.len;
            }
        };
        Ap.put(&pb, &n, "<!doctype html><title>e</title><script>" ++ read_js ++ "var L=[");
        for (enc_cases) |c| {
            Ap.put(&pb, &n, "'");
            Ap.put(&pb, &n, c.name);
            Ap.put(&pb, &n, "',");
        }
        for (enc_cases) |c| if (c.twice) {
            Ap.put(&pb, &n, "'");
            Ap.put(&pb, &n, c.name);
            Ap.put(&pb, &n, "',");
        };
        Ap.put(&pb, &n, "'XHR'];var i=0;function step(){if(i>=L.length){setTimeout(function(){document.title='edone'},2500);return}var x=L[i++];" ++
            "if(x==='XHR'){var q=new XMLHttpRequest();q.open('GET','/f/enc?u16cs&xhr');q.onloadend=function(){setTimeout(step,80)};q.send();return}" ++
            "F('/f/enc?'+x).then(function(){setTimeout(step,80)})}setTimeout(step,200)</script>e");
        return reply(conn, html, pb[0..n]);
    }
    // ── 14: V1 at the wire ──
    if (std.mem.eql(u8, path, "/f/v1p")) return reply(conn, html, "<!doctype html><title>v1</title><script>" ++ read_js ++
        "var P=location.port;var L=['/f/d?v1own','http://localhost:'+P+'/f/d?v1cross','/f/r?to=http://localhost:'+P+'/f/d?v1o2c','http://localhost:'+P+'/f/r?to=http://127.0.0.1:'+P+'/f/d?v1c2o','/f/d?v1own2'];" ++
        "var i=0;function step(){if(i>=L.length){setTimeout(function(){document.title='v1done'},1500);return}F(L[i++]).then(function(){setTimeout(step,80)})}setTimeout(step,200)</script>v1");
    if (std.mem.eql(u8, path, "/f/v1q")) return reply(conn, html, "<!doctype html><title>v1q</title><script>" ++ read_js ++
        "var P=location.port;var L=['/f/d?v1qown','http://127.0.0.1:'+P+'/f/d?v1qcross','/f/d?v1qown2'];" ++
        "var i=0;function step(){if(i>=L.length){setTimeout(function(){document.title='v1qdone'},1500);return}F(L[i++]).then(function(){setTimeout(step,80)})}setTimeout(step,200)</script>v1q");
    if (std.mem.eql(u8, path, "/f/narrowp")) return reply(conn, html, "<!doctype html><title>nw</title><script>" ++ read_js ++
        "var P=location.port;var i=0;function step(){if(i>=60){setTimeout(function(){document.title='nwdone'},2000);return}F('/f/d?nwo'+i);F('http://127.0.0.1:'+P+'/f/d?nwc'+i);i++;setTimeout(step,50)}" ++
        "setTimeout(function(){document.title='nwstart';F('/f/slow2?nwslow');step()},300)</script>nw");
    // ── 12: toggle page (127.0.0.1) ──
    if (std.mem.eql(u8, path, "/f/togp")) return reply(conn, html, "<!doctype html><title>t</title><script>" ++ read_js ++
        "var P=location.port;var i=0;function step(){if(i>=180){setTimeout(function(){document.title='tdone'},2500);return}F('/f/d?to'+i);F('http://localhost:'+P+'/f/d?tx'+i);F('/f/r?to=http://localhost:'+P+'/f/d?tr'+i);i++;setTimeout(step,22)}setTimeout(step,200)</script>t");
    // ── 17/18: fetch page, flood page ──
    if (std.mem.eql(u8, path, "/f/fp")) return reply(conn, html, "<!doctype html><title>fp</title><script>" ++ read_js ++
        "var k=0;function f(){if(k>=10){setTimeout(function(){document.title='fpdone'},700);return}F('/f/d?fp'+k);k++;setTimeout(f,60)}setTimeout(f,150)</script>fp");
    if (std.mem.eql(u8, path, "/f/flood")) return reply(conn, html, "<!doctype html><title>f</title><script>" ++ read_js ++
        "var q=new URLSearchParams(location.search);var R=+q.get('r'),S=+q.get('s');var ws=new WebSocket('ws://'+location.host+'/f/ws');" ++
        "ws.onopen=function(){var t0=performance.now(),sent=0;function tick(){var el=performance.now()-t0;if(el>=S){after();return}var want=Math.floor(el*R/1000);while(sent<want){ws.send('x');sent++}setTimeout(tick,5)}tick()};" ++
        "function after(){var k=0;function f(){if(k>=10){setTimeout(function(){document.title='fdone'},500);return}F('/f/d?fa'+k);k++;setTimeout(f,100)}f()}</script>f");
    // ── 19: 300 slow requests, then the page goes ──
    if (std.mem.eql(u8, path, "/f/orph")) return reply(conn, html, "<!doctype html><title>o</title><script>" ++
        "setTimeout(function(){for(var i=0;i<300;i++){fetch('/f/slow?o'+i).catch(function(){})}document.title='ofired'},150)</script>o");
    return reply(conn, "text/plain", "x");
}

// ── run state ──

const Begin = struct { browser: u64, request: u64, url: []u8, expected: bool, at_ms: i64 };
const Body = struct {
    browser: u64,
    request: u64,
    data: std.ArrayList(u8) = .empty,
    ends: usize = 0,
    state: msg.NetBodyState = .unavailable,
    flags: msg.NetBodyFlags = .{},
    decoded: u64 = 0,
    size: u32 = 0,
    session: u32 = 0,
    end_ms: i64 = 0,
    misordered: usize = 0,
    responded: bool = false,
    resp_stripped: bool = false,
    /// header count of the response — with the switch off a not-covered response carries none, a covered one keeps the allowlist
    resp_headers: u8 = 0,
    resp_ms: i64 = 0,
    redirects: usize = 0,
    redirect_stripped: usize = 0,
    /// header count of the first redirect hop
    hop_headers: u8 = 0,
};
const StateRec = struct { browser: u64, session: u32, status: msg.NetRecordStatus, at_ms: i64 };

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    begins: std.ArrayList(Begin) = .empty,
    bodies: std.ArrayList(Body) = .empty,
    created: std.AutoHashMapUnmanaged(u64, void) = .empty,
    loads: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    gone: std.AutoHashMapUnmanaged(u64, void) = .empty,
    titles: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    states: std.ArrayList(StateRec) = .empty,

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
            .net_begin => |v| self.begins.append(self.gpa, .{ .browser = v.browser, .request = v.request, .url = self.gpa.dupe(u8, v.url) catch &.{}, .expected = v.flags2.body_expected, .at_ms = os.nowMs() }) catch {},
            .net_redirect => |v| {
                const b = self.body(v.browser, v.request);
                if (b.redirects == 0) b.hop_headers = v.headers.count;
                b.redirects += 1;
                if (v.flags.stripped) b.redirect_stripped += 1;
            },
            .net_response => |v| {
                const b = self.body(v.browser, v.request);
                b.responded = true;
                b.resp_stripped = v.flags.stripped;
                b.resp_headers = v.headers.count;
                b.resp_ms = os.nowMs();
            },
            .net_body_data => |v| {
                const b = self.body(v.browser, v.request);
                b.session = v.session;
                if (v.offset == b.data.items.len) b.data.appendSlice(self.gpa, v.bytes) catch {} else b.misordered += 1;
            },
            .net_body_end => |v| {
                const b = self.body(v.browser, v.request);
                b.ends += 1;
                b.state = v.state;
                b.flags = v.flags;
                b.decoded = v.decoded;
                b.size = v.size;
                b.session = v.session;
                b.end_ms = os.nowMs();
            },
            .net_record_state => |v| self.states.append(self.gpa, .{ .browser = v.browser, .session = v.session, .status = v.status, .at_ms = os.nowMs() }) catch {},
            .browser_created => |id| self.created.put(self.gpa, id, {}) catch {},
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

    fn titleIs(self: *Run, browser: u64, prefix: []const u8) bool {
        const t = self.titles.get(browser) orelse return false;
        return std.mem.startsWith(u8, t, prefix);
    }

    fn pumpTitle(self: *Run, browser: u64, prefix: []const u8, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (self.titleIs(browser, prefix)) return true;
            const m = (self.host.next(20) catch null) orelse continue;
            self.take(m);
        }
        return self.titleIs(browser, prefix);
    }

    fn waitFor(self: *Run, ms: u32, ctx: anytype, cond: fn (*Run, @TypeOf(ctx)) bool) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline and !cond(self, ctx)) {
            const m = (self.host.next(20) catch null) orelse continue;
            self.take(m);
        }
        return cond(self, ctx);
    }

    fn navigateTo(self: *Run, browser: u64, host_name: []const u8, path: []const u8) !void {
        var u: [512]u8 = undefined;
        if (self.titles.getPtr(browser)) |t| t.* = &.{};
        try self.host.send(.{ .navigate = .{ .browser = browser, .url = try std.fmt.bufPrint(&u, "http://{s}:{d}{s}", .{ host_name, port, path }) } });
    }

    fn navigate(self: *Run, browser: u64, path: []const u8) !void {
        return self.navigateTo(browser, "127.0.0.1", path);
    }

    fn stateFor(self: *Run, browser: u64, session: u32) ?msg.NetRecordStatus {
        var i = self.states.items.len;
        while (i > 0) {
            i -= 1;
            const s = self.states.items[i];
            if (s.browser == browser and s.session == session) return s.status;
        }
        return null;
    }

    fn sawState(self: *Run, browser: u64, session: u32, status: msg.NetRecordStatus, from: usize) bool {
        for (self.states.items[from..]) |s| if (s.browser == browser and s.session == session and s.status == status) return true;
        return false;
    }
};

fn createdAndLoaded(r: *Run, id: u64) bool {
    return r.created.contains(id) and (r.loads.get(id) orelse 0) >= 1;
}

const SessCtx = struct { browser: u64, session: u32 };
fn hasSessionState(r: *Run, c: SessCtx) bool {
    return r.stateFor(c.browser, c.session) != null;
}

fn enabled(name: []const u8) bool {
    const only = std.c.getenv("V20F_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(only), name) != null;
}

fn watchAny(r: *Run, id: u64, full: bool) !void {
    try r.host.send(.{ .net_watch = .{ .browser = id, .on = true, .full = full, .any_host = true } });
}

fn watchBound(r: *Run, id: u64, full: bool, h: []const u8) !void {
    var hosts: [msg.max_net_watch_hosts][]const u8 = @splat("");
    hosts[0] = h;
    try r.host.send(.{ .net_watch = .{ .browser = id, .on = true, .full = full, .any_host = false, .host_count = 1, .hosts = hosts } });
}

fn openTab(r: *Run, id: u64) !void {
    var u: [256]u8 = undefined;
    const size: msg.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
    try r.host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/f/blank", .{port}) } });
    if (!r.waitFor(wait_ms, id, createdAndLoaded)) return error.BrowserNotCreated;
    try watchAny(r, id, true);
}

fn record(r: *Run, id: u64, session: u32) !bool {
    try r.host.send(.{ .net_record = .{ .browser = id, .on = true, .session = session } });
    return r.waitFor(5000, SessCtx{ .browser = id, .session = session }, hasSessionState) and r.stateFor(id, session).? == .on;
}

fn stateName(b: ?*Body) []const u8 {
    const x = b orelse return "no-record";
    if (x.ends == 0) return "no-end";
    if (x.ends > 1) return "several-ends";
    return @tagName(x.state);
}

fn printable(buf: []u8, bytes: []const u8) []const u8 {
    var n: usize = 0;
    for (bytes[0..@min(bytes.len, 40)]) |c| {
        if (n + 4 > buf.len) break;
        if (c >= 0x20 and c < 0x7f) {
            buf[n] = c;
            n += 1;
        } else {
            const piece = std.fmt.bufPrint(buf[n..], "\\x{x:0>2}", .{c}) catch break;
            n += piece.len;
        }
    }
    return buf[0..n];
}

/// What `fetch().text()` reads: UTF-8 decode, a leading UTF-8 BOM dropped, every byte of a broken sequence → U+FFFD (enough for these bodies).
fn pageRead(out: []u8, bytes: []const u8) []const u8 {
    var i: usize = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) 3 else 0;
    var n: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (len != 0 and i + len <= bytes.len and (if (std.unicode.utf8Decode(bytes[i .. i + len])) |_| true else |_| false)) {
            if (n + len > out.len) return out[0..n];
            @memcpy(out[n..][0..len], bytes[i .. i + len]);
            n += len;
            i += len;
        } else {
            if (n + 3 > out.len) return out[0..n];
            @memcpy(out[n..][0..3], "\xef\xbf\xbd");
            n += 3;
            i += 1;
        }
    }
    return out[0..n];
}

/// All begins of this tab after `at` whose URL ends with `needle`, in order.
fn recordsOf(r: *Run, browser: u64, at: usize, needle: []const u8, out: []*Body) []*Body {
    var n: usize = 0;
    for (r.begins.items[at..]) |b| if (b.browser == browser and std.mem.endsWith(u8, b.url, needle)) {
        if (n == out.len) break;
        out[n] = r.body(browser, b.request);
        n += 1;
    };
    return out[0..n];
}

fn countTicks(path: [*:0]const u8) usize {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    var buf: [65536]u8 = undefined;
    var keep: usize = 0;
    var n: usize = 0;
    const pat = "body: tick\n";
    while (true) {
        const got = std.c.read(fd, buf[keep..].ptr, buf.len - keep);
        if (got <= 0) break;
        const end = keep + @as(usize, @intCast(got));
        n += std.mem.count(u8, buf[0..end], pat);
        // keep a tail shorter than the pattern so a match across reads is counted once
        const tail = @min(end, pat.len - 1);
        for (0..tail) |j| buf[j] = buf[end - tail + j];
        keep = tail;
    }
    return n;
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    try startServer();
    var detail: [4000]u8 = undefined;
    const hostlog: ?[*:0]const u8 = std.c.getenv("V20F_HOSTLOG");
    const env_log = [_][*:0]const u8{"MARU_WEB_TEST_BODY_LOG=1"};
    var host = try Host.spawnWith(host_path, profile_arg, if (hostlog) |p| std.mem.span(p) else null, if (hostlog != null) &env_log else &.{});
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    var r: Run = .{ .host = &host, .gpa = gpa };
    var session: u32 = 1000;

    // ── 15: encodings against V4 ──
    if (enabled("enc")) {
        try openTab(&r, tab_enc);
        session += 1;
        const on = try record(&r, tab_enc, session);
        const at = r.begins.items.len;
        try r.navigate(tab_enc, "/f/encp");
        const done = r.pumpTitle(tab_enc, "edone", 30_000);
        r.pump(1500);
        var pb: [200]u8 = undefined;
        var rb: [256]u8 = undefined;
        var line: [1500]u8 = undefined;
        for (enc_cases) |c| {
            var nb: [64]u8 = undefined;
            const needle = std.fmt.bufPrint(&nb, "/f/enc?{s}", .{c.name}) catch continue;
            var recs: [4]*Body = undefined;
            const list = recordsOf(&r, tab_enc, at, needle, &recs);
            var ok = on and done and list.len == @as(usize, if (c.twice) 2 else 1);
            var ln: usize = 0;
            const read = pageRead(&rb, c.raw);
            for (list, 0..) |x, k| {
                const d = x.data.items;
                const one = x.ends == 1;
                const cap = one and x.state == .captured;
                const marked = x.flags.chromium_decoded or x.flags.binary;
                const exact = std.mem.eql(u8, d, c.raw);
                const as_page = std.mem.eql(u8, d, read);
                var this_ok = one;
                switch (c.expect) {
                    // never unmarked text that is neither the bytes nor what the page read
                    .flag_or_exact => if (cap and !marked and !exact and !as_page) {
                        this_ok = false;
                    },
                    // first fetch must be captured exactly without a mark; a later (cached) one may be not captured, but never wrong or marked
                    .exact_noflag => this_ok = this_ok and ((cap and exact and !marked and !x.flags.redecoded) or (k > 0 and !cap)),
                }
                if (!this_ok) ok = false;
                const piece = std.fmt.bufPrint(line[ln..], " [#{d} {s} chromium_decoded={} binary={} redecoded={} size={d} decoded={d} exact={} as_page_read={} 「{s}」]", .{ k + 1, stateName(x), x.flags.chromium_decoded, x.flags.binary, x.flags.redecoded, d.len, x.decoded, exact, as_page, printable(&pb, d) }) catch "";
                ln += piece.len;
            }
            var nn: [64]u8 = undefined;
            report(ok, std.fmt.bufPrint(&nn, "v20f-15-{s}", .{c.name}) catch "v20f-15", std.fmt.bufPrint(&detail, "{s} ({s}) records {d}:{s}", .{ c.ctype, @tagName(c.expect), list.len, line[0..ln] }) catch "");
        }
        // XHR of the charset=utf-8 UTF-16 body
        {
            var recs: [2]*Body = undefined;
            const list = recordsOf(&r, tab_enc, at, "/f/enc?u16cs&xhr", &recs);
            var ok = list.len == 1;
            var ln: []const u8 = "no-record";
            if (list.len == 1) {
                const x = list[0];
                const d = x.data.items;
                const marked = x.flags.chromium_decoded or x.flags.binary;
                const exact = std.mem.eql(u8, d, utf16le_json);
                const as_page = std.mem.eql(u8, d, pageRead(&rb, utf16le_json));
                ok = x.ends == 1 and !(x.state == .captured and !marked and !exact and !as_page);
                ln = std.fmt.bufPrint(&line, "{s} chromium_decoded={} binary={} size={d} decoded={d} exact={} as_page_read={} 「{s}」", .{ stateName(x), x.flags.chromium_decoded, x.flags.binary, d.len, x.decoded, exact, as_page, printable(&pb, d) }) catch "";
            }
            report(ok, "v20f-15-u16cs-xhr", ln);
        }
        try r.host.send(.{ .net_record = .{ .browser = tab_enc, .on = false } });
        r.pump(200);
    }

    // ── 14: V1 at the wire ──
    if (enabled("v1")) {
        try openTab(&r, tab_v1);
        // agent tab, switch off, not driven: any_host, full=false
        try watchAny(&r, tab_v1, false);
        session += 1;
        const on = try record(&r, tab_v1, session);
        const Tally = struct {
            fn one(rr: *Run, at: usize, needle: []const u8) ?*Body {
                var recs: [2]*Body = undefined;
                const l = recordsOf(rr, tab_v1, at, needle, &recs);
                return if (l.len >= 1) l[0] else null;
            }
            fn line(buf: []u8, name: []const u8, b: ?*Body) []const u8 {
                const x = b orelse return std.fmt.bufPrint(buf, "{s}: no-record", .{name}) catch "";
                return std.fmt.bufPrint(buf, "{s}: {s} resp_stripped={} resp_headers={d} hops={d} hop_stripped={d} hop_headers={d} bytes={d}", .{ name, stateName(b), x.resp_stripped, x.resp_headers, x.redirects, x.redirect_stripped, x.hop_headers, x.data.items.len }) catch "";
            }
            fn cap(b: ?*Body) bool {
                const x = b orelse return false;
                return x.ends == 1 and x.state == .captured;
            }
            fn notCap(b: ?*Body) bool {
                const x = b orelse return false;
                return x.ends == 1 and x.state != .captured and x.data.items.len == 0;
            }
        };
        var l: [5][300]u8 = undefined;
        // A: page at 127.0.0.1
        {
            const at = r.begins.items.len;
            try r.navigate(tab_v1, "/f/v1p");
            const done = r.pumpTitle(tab_v1, "v1done", 15_000);
            r.pump(800);
            const own = Tally.one(&r, at, "/f/d?v1own");
            const own2 = Tally.one(&r, at, "/f/d?v1own2");
            const cross = Tally.one(&r, at, "/f/d?v1cross");
            const o2c = Tally.one(&r, at, "/f/d?v1o2c");
            const c2o = Tally.one(&r, at, "/f/d?v1c2o");
            const ok_own = Tally.cap(own) and Tally.cap(own2) and own.?.resp_headers > 0 and own2.?.resp_headers > 0;
            const ok_cross = Tally.notCap(cross) and cross.?.resp_stripped and cross.?.resp_headers == 0;
            const ok_o2c = Tally.notCap(o2c) and o2c.?.resp_headers == 0 and o2c.?.redirects == 1 and o2c.?.hop_headers > 0;
            report(on and done and ok_own and ok_cross and ok_o2c, "v20f-14-switch-off-agent-tab-own-site", std.fmt.bufPrint(&detail, "{s} · {s} · {s} · {s} · {s} (c2o = observation)", .{ Tally.line(&l[0], "own", own), Tally.line(&l[1], "own2", own2), Tally.line(&l[2], "cross(localhost)", cross), Tally.line(&l[3], "own→cross redirect", o2c), Tally.line(&l[4], "cross→own redirect", c2o) }) catch "");
        }
        // A': control — switch on, same page: everything captured and nothing stripped
        {
            try watchAny(&r, tab_v1, true);
            r.pump(100);
            const at = r.begins.items.len;
            try r.navigate(tab_v1, "/f/v1p");
            const done = r.pumpTitle(tab_v1, "v1done", 15_000);
            r.pump(800);
            const names = [_][]const u8{ "/f/d?v1own", "/f/d?v1cross", "/f/d?v1o2c", "/f/d?v1c2o", "/f/d?v1own2" };
            var all = done;
            for (names, 0..) |nm, k| {
                const b = Tally.one(&r, at, nm);
                if (!Tally.cap(b) or b.?.resp_stripped) all = false;
                _ = k;
            }
            var lines: [5][]const u8 = undefined;
            for (names, 0..) |nm, k| lines[k] = Tally.line(&l[k], nm, Tally.one(&r, at, nm));
            report(all, "v20f-14-control-switch-on-all-captured", std.fmt.bufPrint(&detail, "{s} · {s} · {s} · {s} · {s}", .{ lines[0], lines[1], lines[2], lines[3], lines[4] }) catch "");
            try watchAny(&r, tab_v1, false);
            r.pump(100);
        }
        // B: the agent navigates its tab to the other site (localhost) with the switch off — that site is now the first site
        {
            const at = r.begins.items.len;
            try r.navigateTo(tab_v1, "localhost", "/f/v1q");
            const done = r.pumpTitle(tab_v1, "v1qdone", 15_000);
            r.pump(800);
            const own = Tally.one(&r, at, "/f/d?v1qown");
            const own2 = Tally.one(&r, at, "/f/d?v1qown2");
            const cross = Tally.one(&r, at, "/f/d?v1qcross");
            const ok = done and Tally.cap(own) and Tally.cap(own2) and own.?.resp_headers > 0 and Tally.notCap(cross) and cross.?.resp_headers == 0;
            report(ok, "v20f-14-switch-off-agent-navigated-other-site", std.fmt.bufPrint(&detail, "{s} · {s} · {s}", .{ Tally.line(&l[0], "localhost own", own), Tally.line(&l[1], "localhost own2", own2), Tally.line(&l[2], "127.0.0.1 cross", cross) }) catch "");
        }
        // C: narrowing while the page at localhost keeps fetching (maru narrows when the user drives the tab with the switch off)
        {
            const at = r.begins.items.len;
            try r.navigateTo(tab_v1, "localhost", "/f/narrowp");
            const started = r.pumpTitle(tab_v1, "nwstart", 10_000);
            r.pump(700);
            const t_narrow = os.nowMs();
            try watchBound(&r, tab_v1, false, "127.0.0.1");
            const done = r.pumpTitle(tab_v1, "nwdone", 20_000);
            r.pump(1500);
            var lh_before: usize = 0;
            var lh_before_cap: usize = 0;
            var lh_after: usize = 0;
            var lh_after_cap: usize = 0;
            var lh_after_unstripped: usize = 0;
            var ip_after: usize = 0;
            var ip_after_cap: usize = 0;
            var ends_bad: usize = 0;
            for (r.begins.items[at..]) |b| if (b.browser == tab_v1 and b.expected and std.mem.indexOf(u8, b.url, "/f/d?nw") != null) {
                const x = r.body(tab_v1, b.request);
                if (x.ends != 1) ends_bad += 1;
                const lh = std.mem.indexOf(u8, b.url, "localhost") != null;
                const cap = x.ends == 1 and x.state == .captured;
                if (b.at_ms + 5 < t_narrow and x.end_ms != 0 and x.end_ms + 5 < t_narrow) {
                    if (lh) {
                        lh_before += 1;
                        if (cap) lh_before_cap += 1;
                    }
                } else if (b.at_ms >= t_narrow + 60) {
                    if (lh) {
                        lh_after += 1;
                        if (cap) lh_after_cap += 1;
                        if (x.responded and (!x.resp_stripped or x.resp_headers > 0)) lh_after_unstripped += 1;
                    } else {
                        ip_after += 1;
                        if (cap) ip_after_cap += 1;
                    }
                }
            };
            const slow = Tally.one(&r, at, "/f/slow2?nwslow");
            report(started and done and lh_before > 0 and lh_before_cap == lh_before and lh_after > 0 and lh_after_cap == 0 and lh_after_unstripped == 0 and ends_bad == 0, "v20f-14-narrowing-hides-other-site", std.fmt.bufPrint(&detail, "before narrowing localhost captured {d}/{d} · after narrowing localhost {d}: captured {d} (need 0), response with headers or unstripped {d} (need 0) · bound host 127.0.0.1 after narrowing captured {d}/{d} (control) · ends != 1: {d} · slow localhost fetch spanning the narrowing: {s}", .{ lh_before_cap, lh_before, lh_after, lh_after_cap, lh_after_unstripped, ip_after_cap, ip_after, ends_bad, Tally.line(&l[0], "slow", slow) }) catch "");
            report(ip_after > 0 and ip_after_cap * 100 >= ip_after * 80, "v20f-14-narrowing-control-bound-host-captured", std.fmt.bufPrint(&detail, "127.0.0.1 after narrowing captured {d}/{d}", .{ ip_after_cap, ip_after }) catch "");
        }
        try r.host.send(.{ .net_record = .{ .browser = tab_v1, .on = false } });
        r.pump(200);
    }

    // ── 12: switch toggled every 70 ms between full and any_host+full=false (V1 path), new session per off ──
    if (enabled("tog")) {
        try openTab(&r, tab_tog);
        session += 1;
        _ = try record(&r, tab_tog, session);
        const first_session = session;
        const at = r.begins.items.len;
        try r.navigate(tab_tog, "/f/togp");
        var full_now = true;
        var off_windows: [128][2]i64 = undefined;
        var n_off: usize = 0;
        var toggles: usize = 0;
        const t_end = os.nowMs() + 4300;
        while (os.nowMs() < t_end) {
            r.pump(70);
            if (full_now) {
                try watchAny(&r, tab_tog, false);
                session += 1;
                try host.send(.{ .net_record = .{ .browser = tab_tog, .on = true, .session = session } });
                full_now = false;
                if (n_off < off_windows.len) {
                    off_windows[n_off] = .{ os.nowMs(), std.math.maxInt(i64) };
                    n_off += 1;
                }
            } else {
                try watchAny(&r, tab_tog, true);
                full_now = true;
                if (n_off > 0) off_windows[n_off - 1][1] = os.nowMs();
            }
            toggles += 1;
        }
        if (!full_now) {
            try watchAny(&r, tab_tog, true);
            if (n_off > 0) off_windows[n_off - 1][1] = os.nowMs();
        }
        const done = r.pumpTitle(tab_tog, "tdone", 20_000);
        r.pump(2000);
        var expected: usize = 0;
        var bad_ends: usize = 0;
        var bad_sess: usize = 0;
        const K = enum { own, cross, o2c };
        var inside: [3]usize = @splat(0);
        var inside_cap: [3]usize = @splat(0);
        var inside_unstripped: [3]usize = @splat(0);
        var total: [3]usize = @splat(0);
        var total_cap: [3]usize = @splat(0);
        for (r.begins.items[at..]) |b| if (b.browser == tab_tog and b.expected) {
            const k: K = if (std.mem.indexOf(u8, b.url, "/f/r?to=") != null) .o2c else if (std.mem.indexOf(u8, b.url, "/f/d?tx") != null) .cross else if (std.mem.indexOf(u8, b.url, "/f/d?to") != null) .own else continue;
            const x = r.body(tab_tog, b.request);
            expected += 1;
            if (x.ends != 1) bad_ends += 1;
            if (x.ends == 1 and (x.session < first_session or x.session > session)) bad_sess += 1;
            const cap = x.ends == 1 and x.state == .captured;
            const ki = @backingInt(k);
            total[ki] += 1;
            if (cap) total_cap[ki] += 1;
            for (off_windows[0..n_off]) |w| if (b.at_ms >= w[0] + 30 and x.end_ms != 0 and x.end_ms < w[1]) {
                inside[ki] += 1;
                if (cap) inside_cap[ki] += 1;
                if (x.responded and x.resp_headers > 0 and x.resp_ms < w[1]) inside_unstripped[ki] += 1;
                break;
            };
        };
        report(done and bad_ends == 0 and bad_sess == 0, "v20f-12-toggle-one-end-each", std.fmt.bufPrint(&detail, "toggles {d} (off windows {d}, sessions {d}..{d}) · body_expected {d} · ends != 1: {d} · ends outside issued sessions {d}", .{ toggles, n_off, first_session, session, expected, bad_ends, bad_sess }) catch "");
        const c = @backingInt(K.cross);
        const o = @backingInt(K.o2c);
        const w = @backingInt(K.own);
        report(done and inside[c] > 0 and inside_cap[c] == 0 and inside[o] > 0 and inside_cap[o] == 0 and inside_unstripped[c] == 0 and inside_unstripped[o] == 0, "v20f-12-toggle-other-site-not-captured-while-off", std.fmt.bufPrint(&detail, "begun+ended inside an off window: cross {d} captured {d} with response headers {d} · own→cross redirect {d} captured {d} with response headers {d} (all need 0) · overall captured cross {d}/{d} o2c {d}/{d}", .{ inside[c], inside_cap[c], inside_unstripped[c], inside[o], inside_cap[o], inside_unstripped[o], total_cap[c], total[c], total_cap[o], total[o] }) catch "");
        report(done and inside[w] > 0 and inside_cap[w] > 0 and inside_unstripped[w] == inside[w], "v20f-12-toggle-own-site-kept-while-off-v1", std.fmt.bufPrint(&detail, "own site begun+ended inside an off window {d}: captured {d} (V1 — before the fix 0), response headers kept (allowlist) {d} · overall own captured {d}/{d}", .{ inside[w], inside_cap[w], inside_unstripped[w], total_cap[w], total[w] }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = tab_tog, .on = false } });
        r.pump(200);
    }

    // ── 17/18: paused stays paused ──
    if (enabled("pause")) {
        try openTab(&r, tab_pause);
        const Fp = struct {
            fn tally(rr: *Run, at: usize, needle: []const u8) struct { total: usize, expected: usize, captured: usize } {
                var t: usize = 0;
                var e: usize = 0;
                var c: usize = 0;
                for (rr.begins.items[at..]) |b| if (b.browser == tab_pause and std.mem.indexOf(u8, b.url, needle) != null) {
                    t += 1;
                    if (b.expected) e += 1;
                    const x = rr.body(tab_pause, b.request);
                    if (x.ends == 1 and x.state == .captured) c += 1;
                };
                return .{ .total = t, .expected = e, .captured = c };
            }
            fn floodPaused(rr: *Run, s: u32) !i64 {
                const t0 = os.nowMs();
                try rr.navigate(tab_pause, "/f/flood?r=8000&s=3000");
                _ = rr.pumpTitle(tab_pause, "fdone", 20_000);
                rr.pump(800);
                for (rr.states.items) |st| if (st.browser == tab_pause and st.session == s and st.status == .paused) return st.at_ms - t0;
                return -1;
            }
        };
        var cyc_line: [1500]u8 = undefined;
        var cl: usize = 0;
        var all_ok = true;
        // a. pause, then the renderer dies and the page reloads
        session += 1;
        const s1 = session;
        const on1 = try record(&r, tab_pause, s1);
        const st_at = r.states.items.len;
        const p1 = try Fp.floodPaused(&r, s1);
        _ = r.gone.remove(tab_pause);
        try r.host.send(.{ .devtools_call = .{ .browser = tab_pause, .call = 9901, .method = "Page.crash", .params_size = 0 } });
        const G = struct {
            fn got(x: *Run, id: u64) bool {
                return x.gone.contains(id);
            }
        };
        const gone = r.waitFor(5000, tab_pause, G.got);
        r.pump(800);
        const at_a = r.begins.items.len;
        try r.navigate(tab_pause, "/f/fp");
        _ = r.pumpTitle(tab_pause, "fpdone", 10_000);
        r.pump(800);
        const ta = Fp.tally(&r, at_a, "/f/d?fp");
        var s1_after: [64]u8 = undefined;
        var s1n: usize = 0;
        for (r.states.items[st_at..]) |st| if (st.browser == tab_pause and st.session == s1) {
            const piece = std.fmt.bufPrint(s1_after[s1n..], "{s} ", .{@tagName(st.status)}) catch break;
            s1n += piece.len;
        };
        const ok_a = on1 and p1 >= 0 and ta.total > 0 and ta.expected == 0 and !r.sawState(tab_pause, s1, .on, st_at);
        report(ok_a, "v20f-18-paused-survives-renderer-crash", std.fmt.bufPrint(&detail, "paused after {d} ms · renderer_gone {} · after reload fetches {d} body_expected {d} (need 0) · states of the paused session: {s}", .{ p1, gone, ta.total, ta.expected, s1_after[0..s1n] }) catch "");
        // b. three cycles: re-enable (new session) captures, the flood pauses it again, later fetches are not expected
        for (0..3) |k| {
            session += 1;
            const s = session;
            const on = try record(&r, tab_pause, s);
            const at_b = r.begins.items.len;
            try r.navigate(tab_pause, "/f/fp");
            _ = r.pumpTitle(tab_pause, "fpdone", 10_000);
            r.pump(600);
            const tb = Fp.tally(&r, at_b, "/f/d?fp");
            const at_c = r.begins.items.len;
            const p = try Fp.floodPaused(&r, s);
            const tc = Fp.tally(&r, at_c, "/f/d?fa");
            const auto_on = blk: {
                var seen_pause = false;
                for (r.states.items) |st| if (st.browser == tab_pause and st.session == s) {
                    if (st.status == .paused) seen_pause = true else if (seen_pause and st.status == .on) break :blk true;
                };
                break :blk false;
            };
            const ok = on and tb.total == 10 and tb.captured == 10 and p >= 0 and p <= 3500 and tc.expected == 0 and !auto_on;
            if (!ok) all_ok = false;
            const piece = std.fmt.bufPrint(cyc_line[cl..], " [cycle {d}: on {} captured {d}/{d} · paused after {d} ms · later fetches {d} expected {d} · auto on {}]", .{ k + 1, on, tb.captured, tb.total, p, tc.total, tc.expected, auto_on }) catch "";
            cl += piece.len;
        }
        report(all_ok, "v20f-17-reenable-pause-cycles", cyc_line[0..cl]);
        // c. tab closed while paused — does the sidecar send `failed` for the paused session (the D2 sequence), and a re-created browser
        //    with the same id does not record until a new session is asked for
        {
            const s_paused = session;
            const at_states = r.states.items.len;
            try r.host.send(.{ .destroy_browser = tab_pause });
            r.pump(1500);
            var seen: [96]u8 = undefined;
            var sn: usize = 0;
            for (r.states.items[at_states..]) |st| if (st.browser == tab_pause) {
                const piece = std.fmt.bufPrint(seen[sn..], "s{d}:{s} ", .{ st.session, @tagName(st.status) }) catch break;
                sn += piece.len;
            };
            _ = r.created.remove(tab_pause);
            _ = r.loads.remove(tab_pause);
            try openTab(&r, tab_pause);
            const at_d = r.begins.items.len;
            try r.navigate(tab_pause, "/f/fp");
            _ = r.pumpTitle(tab_pause, "fpdone", 10_000);
            r.pump(800);
            const td = Fp.tally(&r, at_d, "/f/d?fp");
            var any_on = false;
            for (r.states.items[at_states..]) |st| if (st.browser == tab_pause and st.status == .on) {
                any_on = true;
            };
            session += 1;
            const on_again = try record(&r, tab_pause, session);
            const at_e = r.begins.items.len;
            try r.navigate(tab_pause, "/f/fp");
            _ = r.pumpTitle(tab_pause, "fpdone", 10_000);
            r.pump(800);
            const te = Fp.tally(&r, at_e, "/f/d?fp");
            report(td.total > 0 and td.expected == 0 and !any_on and on_again and te.captured == te.total and te.total > 0, "v20f-18-paused-tab-closed-and-recreated", std.fmt.bufPrint(&detail, "states after closing the tab paused in s{d}: {s}· re-created browser: fetches {d} body_expected {d} (need 0) · on without a new session {} · new session on {} captured {d}/{d}", .{ s_paused, seen[0..sn], td.total, td.expected, any_on, on_again, te.captured, te.total }) catch "");
        }
        try r.host.send(.{ .net_record = .{ .browser = tab_pause, .on = false } });
        r.pump(200);
    }

    // ── 19: requests cut by a navigation (V3) — unavailable once each, the tick stops ──
    if (enabled("orphan")) {
        try openTab(&r, tab_orph);
        session += 1;
        const on = try record(&r, tab_orph, session);
        r.pump(1500);
        const path: ?[*:0]const u8 = hostlog;
        const ticks0 = if (path) |p| countTicks(p) else 0;
        r.pump(2000);
        const ticks_idle_before = (if (path) |p| countTicks(p) else 0) -| ticks0;
        const at = r.begins.items.len;
        try r.navigate(tab_orph, "/f/orph");
        const fired = r.pumpTitle(tab_orph, "ofired", 10_000);
        r.pump(1000);
        const t_nav = os.nowMs();
        // another host: the six sockets of 127.0.0.1:port are held by the slow requests — a navigation there would wait for them
        try r.navigateTo(tab_orph, "localhost", "/f/blank?after");
        // ends for the cut requests
        var last_end: i64 = 0;
        r.pump(4000);
        const ticks_a = if (path) |p| countTicks(p) else 0;
        r.pump(3000);
        const ticks_b = if (path) |p| countTicks(p) else 0;
        r.pump(500);
        var total: usize = 0;
        var expected: usize = 0;
        var bad_ends: usize = 0;
        var states: [16]usize = @splat(0);
        for (r.begins.items[at..]) |b| if (b.browser == tab_orph and std.mem.indexOf(u8, b.url, "/f/slow?o") != null) {
            total += 1;
            if (!b.expected) continue;
            expected += 1;
            const x = r.body(tab_orph, b.request);
            if (x.ends != 1) {
                bad_ends += 1;
                continue;
            }
            states[@backingInt(x.state)] += 1;
            last_end = @max(last_end, x.end_ms);
        };
        var sl: [400]u8 = undefined;
        var sn: usize = 0;
        for (states, 0..) |c, i| if (c > 0 and i < 14) {
            const piece = std.fmt.bufPrint(sl[sn..], " {s}={d}", .{ @tagName(@as(msg.NetBodyState, @fromBackingInt(@intCast(i)))), c }) catch break;
            sn += piece.len;
        };
        const unav = states[@backingInt(msg.NetBodyState.unavailable)];
        report(on and fired and expected >= 100 and bad_ends == 0 and unav == expected, "v20f-19-cut-requests-end-once-unavailable", std.fmt.bufPrint(&detail, "begun {d} · body_expected {d} · ends != 1: {d} · states{s} · last end {d} ms after the navigation", .{ total, expected, bad_ends, sl[0..sn], last_end - t_nav }) catch "");
        const tick_quiet = ticks_b -| ticks_a;
        report(path != null and tick_quiet <= 2, "v20f-19-tick-stops-after-cut-requests", std.fmt.bufPrint(&detail, "ticks while idle before {d} (2 s) · ticks 4–7 s after the navigation {d} (need <= 2 — before V3 a 50 ms tick ran ~60 times) · ticks 0–4 s {d}", .{ ticks_idle_before, tick_quiet, ticks_a -| ticks0 -| ticks_idle_before }) catch "");
        // control: recording still works
        const at2 = r.begins.items.len;
        try r.navigateTo(tab_orph, "localhost", "/f/fp");
        _ = r.pumpTitle(tab_orph, "fpdone", 10_000);
        r.pump(800);
        var c2: usize = 0;
        var t2: usize = 0;
        for (r.begins.items[at2..]) |b| if (b.browser == tab_orph and std.mem.indexOf(u8, b.url, "/f/d?fp") != null) {
            t2 += 1;
            const x = r.body(tab_orph, b.request);
            if (x.ends == 1 and x.state == .captured) c2 += 1;
        };
        report(t2 == 10 and c2 == 10, "v20f-19-control-after-cut-requests", std.fmt.bufPrint(&detail, "captured {d}/{d}", .{ c2, t2 }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = tab_orph, .on = false } });
        r.pump(200);
    }
}
