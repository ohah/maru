//! W9d② 적대 검증 11–20 회차(v20b) 판정 — 실제 CEF 154 에서 maru 처럼 sidecar 를 띄워(`--review-body-v20b`, 따로 띄운 sidecar·프로필)
//! 회차마다 하나의 주제를 본다. `V20B_ONLY=enc,size,…` 로 일부만.
//!   v20b-12-toggle-*     본문이 오가는 동안 설정 끔·켬(`net_watch full`)을 80 ms 마다 바꾸고 끌 때마다 새 세션(maru 의 wipe 처럼) — 기록마다 끝은
//!                        하나, 끈 동안 시작해 끝난 덮이지 않는 호스트(localhost)의 본문은 잡지 않는다(대조: 덮이는 127.0.0.1 은 잡는다)
//!   v20b-15-enc-*        글 풀기 — charset 없는 text/plain·text/css 의 UTF-8(되돌림), C1 자리 글자(Á Í Ï Ð Ý), BOM UTF-8, 진짜 Latin-1, charset 있는
//!                        Latin-1·EUC-KR, charset 없는 EUC-KR, 잘못된 UTF-8 JSON, 글로 꾸민 PNG, gzip·deflate·br, 빈 본문·204·HEAD
//!   v20b-16-size-*       본문 크기 경계 0·1·64 KiB−1·64 KiB·64 KiB+1·1 MiB(ASCII·여러 바이트 글자·charset 없는 글)·1 MiB+1(over_cap) — 조각
//!                        16 KiB 이하·이어지는 오프셋·바이트가 같다
//!   v20b-17-cycle-*      기록 켬·끔 200 번(가끔 끔 없이 켬 두 번) — 켬마다 상태 on, 끝은 하나, 마지막 켬의 본문은 잡는다
//!   v20b-18-flood-*      웹소켓 프레임으로 초당 Network 이벤트 8000 을 3 초 — paused, 그 뒤 새 요청은 body_expected 가 아니고 스스로 다시 켜지지
//!                        않는다, 새 세션으로 켜면 다시 잡는다; 대조: 초당 3000 을 4 초·5500 을 0.9 초는 멈추지 않는다
//!   v20b-19-guard-*      DevTools 지킴의 이름 변형(소문자·대문자·다른 Fetch 메서드) — 거절되거나 CDP 가 모른다고 답하고, 그 뒤에도 기록이 이어진다
//!   v20b-19-overhead     작은 fetch 200 개 묶음의 시간 — 기록을 켠 적 없는 탭 · 켠 탭 · 끈 탭(관측)

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const rec_tab: u64 = 201;
const tab_b: u64 = 202;
const tab_c: u64 = 203;
const tab_d: u64 = 204;
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
var ws_frames = std.atomic.Value(u64).init(0);

// 미리 압축한 본문(python zlib·gzip, brotli CLI).
const gz_plain = "gzip-\xed\x95\x9c\xea\xb8\x80-\xc3\xa9-\xe2\x9c\x93 text";
const gz_bytes = [_]u8{ 31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 75, 175, 202, 44, 208, 125, 59, 117, 206, 171, 29, 13, 186, 135, 87, 234, 62, 154, 51, 89, 161, 36, 181, 162, 4, 0, 3, 60, 136, 103, 23, 0, 0, 0 };
const df_plain = "{\"deflate\":\"\xea\xb0\x80\xeb\x82\x98\xeb\x8b\xa4\"}";
const df_bytes = [_]u8{ 120, 156, 171, 86, 74, 73, 77, 203, 73, 44, 73, 85, 178, 82, 122, 181, 161, 225, 117, 211, 140, 215, 221, 75, 148, 106, 1, 116, 168, 10, 201 };
const br_plain = "{\"br\":\"brotli-body-\xea\xb0\x80\"}";
const br_bytes = [_]u8{ 143, 11, 128, 123, 34, 98, 114, 34, 58, 34, 98, 114, 111, 116, 108, 105, 45, 98, 111, 100, 121, 45, 234, 176, 128, 34, 125, 3 };

const u8_text = "\xed\x95\x9c\xea\xb8\x80 caf\xc3\xa9 \xce\xa9 \xe2\x9c\x93 \xf0\x9f\x98\x80"; // 한글 café Ω ✓ 😀
const c1_text = "C1: \xc3\x81\xc3\x8d\xc3\x8f\xc3\x90\xc3\x9d end"; // ÁÍÏÐÝ — 둘째 바이트가 windows-1252 의 빈 자리(81 8D 8F 90 9D)
const latin1_raw = "caf\xe9 na\xefve \xa9"; // 진짜 Latin-1
const latin1_utf8 = "caf\xc3\xa9 na\xc3\xafve \xc2\xa9";
const euckr_raw = "\xc7\xd1\xb1\xdb"; // 「한글」 EUC-KR
const hangul = "\xed\x95\x9c\xea\xb8\x80";
const bad_json = "{\"k\":\"\x80\xfe\xc0\x80\"}"; // 잘못된 UTF-8(BOM 없음)
/// UTF-16LE BOM 으로 시작하는 JSON 바이트(첫 판정에서 Chromium 이 UTF-16 으로 풀어 표시 없는 「글」 로 왔다 — v20b 15 회차 결함 후보).
const utf16_bom_json = "\xff\xfe{\"k\":\"\xc0\x80\"}";
const png_text = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89";

var size_bodies: [9][]u8 = @splat(&.{});
const sizes = [_]usize{ 1, 64 * 1024 - 1, 64 * 1024, 64 * 1024 + 1, 1024 * 1024, 1024 * 1024 + 1 };
// size_bodies[6] = 1 MiB 여러 바이트 글자(JSON, charset=utf-8), [7] = 1 MiB charset 없는 text/plain 여러 바이트, [8] = 16 KiB 경계에 걸친 글자.

fn makeBodies(gpa: std.mem.Allocator) !void {
    for (sizes, 0..) |n, i| {
        const b = try gpa.alloc(u8, n);
        for (b, 0..) |*c, k| c.* = @intCast('0' + (k * 7 + i) % 10);
        size_bodies[i] = b;
    }
    for ([_]usize{ 6, 7 }) |i| {
        const b = try gpa.alloc(u8, 1024 * 1024);
        var k: usize = 0;
        while (k + 3 <= b.len) : (k += 3) @memcpy(b[k..][0..3], "\xea\xb0\x80"); // 가
        while (k < b.len) : (k += 1) b[k] = 'z';
        size_bodies[i] = b;
    }
    // 16 KiB 조각 경계마다 4 바이트 글자가 걸치도록 — 앞에 한 바이트.
    const b8 = try gpa.alloc(u8, 70 * 1024 + 1);
    b8[0] = 'p';
    var k: usize = 1;
    while (k + 4 <= b8.len) : (k += 4) @memcpy(b8[k..][0..4], "\xf0\x9f\x98\x80");
    while (k < b8.len) : (k += 1) b8[k] = 'q';
    size_bodies[8] = b8;
}

fn startServer() !void {
    const fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
    if (listen(fd, 512) != 0) return error.ListenFailed;
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

fn replyX(conn: c_int, status: []const u8, ctype: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [1024]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n{s}Connection: close\r\n\r\n", .{ status, ctype, body.len, extra }) catch return;
    writeAll(conn, head);
    writeAll(conn, body);
}

fn reply(conn: c_int, ctype: []const u8, body: []const u8) void {
    replyX(conn, "200 OK", ctype, "", body);
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

/// 웹소켓: 손잡기 뒤 받은 frame 을 세고 버린다(답하지 않는다 — 페이지의 보냄이 Network.webSocketFrameSent 이벤트다).
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
        // 대략 센다(작은 마스크 frame 하나 = 2 + 4 + 길이) — 관측용.
        _ = ws_frames.fetchAdd(@intCast(@divFloor(n, 16)), .monotonic);
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
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    const qi = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. qi orelse target.len];
    const query = if (qi) |i| target[i + 1 ..] else "";
    const html = "text/html; charset=utf-8";
    const is_head = std.mem.eql(u8, method, "HEAD");
    if (std.mem.eql(u8, path, "/v20/ws")) return websocket(conn, head);
    if (std.mem.eql(u8, path, "/v20/blank")) return reply(conn, html, "<!doctype html><title>blank</title>blank");
    if (std.mem.eql(u8, path, "/v20/d")) {
        const n = counter.fetchAdd(1, .monotonic);
        var bb: [64]u8 = undefined;
        return reply(conn, "application/json", std.fmt.bufPrint(&bb, "{{\"n\":\"{d}\"}}", .{n}) catch return);
    }
    // ── 15 회차: 글 풀기 ──
    if (std.mem.eql(u8, path, "/v20/enc")) {
        const Case = struct { name: []const u8, ctype: []const u8, extra: []const u8 = "", body: []const u8, status: []const u8 = "200 OK" };
        const cases = [_]Case{
            .{ .name = "u8plain", .ctype = "text/plain", .body = u8_text },
            .{ .name = "u8css", .ctype = "text/css", .body = "/* " ++ u8_text ++ " */" },
            .{ .name = "u8html", .ctype = "text/html", .body = "<p>" ++ u8_text ++ "</p>" },
            .{ .name = "c1", .ctype = "text/plain", .body = c1_text },
            .{ .name = "bom", .ctype = "text/plain", .body = "\xef\xbb\xbf" ++ hangul },
            .{ .name = "bomlatin", .ctype = "text/plain", .body = "\xef\xbb\xbf" ++ "caf\xc3\xa9" },
            .{ .name = "latin1", .ctype = "text/plain", .body = latin1_raw },
            .{ .name = "latin1cs", .ctype = "text/plain; charset=iso-8859-1", .body = latin1_raw },
            .{ .name = "euckr", .ctype = "text/plain", .body = euckr_raw },
            .{ .name = "euckrcs", .ctype = "text/plain; charset=euc-kr", .body = euckr_raw },
            .{ .name = "badjson", .ctype = "application/json", .body = bad_json },
            .{ .name = "utf16bomjson", .ctype = "application/json", .body = utf16_bom_json },
            .{ .name = "pngtext", .ctype = "text/plain", .body = png_text },
            .{ .name = "gzip", .ctype = "text/plain", .extra = "Content-Encoding: gzip\r\n", .body = &gz_bytes },
            .{ .name = "deflate", .ctype = "application/json", .extra = "Content-Encoding: deflate\r\n", .body = &df_bytes },
            .{ .name = "br", .ctype = "application/json", .extra = "Content-Encoding: br\r\n", .body = &br_bytes },
            .{ .name = "empty", .ctype = "application/json", .body = "" },
            .{ .name = "nocontent", .ctype = "application/json", .body = "", .status = "204 No Content" },
            .{ .name = "head", .ctype = "application/json", .body = "{\"head\":1}" },
        };
        for (cases) |c| if (std.mem.eql(u8, query, c.name)) {
            if (is_head) {
                var hb: [512]u8 = undefined;
                return writeAll(conn, std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ c.ctype, c.body.len }) catch return);
            }
            if (std.mem.eql(u8, c.status, "204 No Content")) return writeAll(conn, "HTTP/1.1 204 No Content\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
            return replyX(conn, c.status, c.ctype, c.extra, c.body);
        };
        return reply(conn, "text/plain", "?");
    }
    if (std.mem.eql(u8, path, "/v20/encp")) return reply(conn, html, "<!doctype html><title>e</title><script>" ++ read_js ++
        "var L=['u8plain','u8css','u8html','c1','bom','bomlatin','latin1','latin1cs','euckr','euckrcs','badjson','utf16bomjson','pngtext','gzip','deflate','br','empty','nocontent'];" ++
        "var i=0;function step(){if(i>=L.length){F('/v20/enc?head',{method:'HEAD'});setTimeout(function(){document.title='edone'},2500);return}F('/v20/enc?'+L[i]);i++;setTimeout(step,60)}setTimeout(step,200)</script>e");
    // ── 16 회차: 크기 ──
    if (std.mem.eql(u8, path, "/v20/size")) {
        const i = std.fmt.parseInt(usize, query, 10) catch return reply(conn, "text/plain", "?");
        if (i >= size_bodies.len) return reply(conn, "text/plain", "?");
        const ctype = switch (i) {
            6 => "application/json; charset=utf-8",
            7 => "text/plain",
            8 => "text/plain; charset=utf-8",
            else => "application/json",
        };
        return reply(conn, ctype, size_bodies[i]);
    }
    if (std.mem.eql(u8, path, "/v20/sizep")) return reply(conn, html, "<!doctype html><title>s</title><script>" ++ read_js ++
        "var i=0;function step(){if(i>=9){setTimeout(function(){document.title='sdone'},2500);return}F('/v20/size?'+i).then(function(){i++;setTimeout(step,150)})}setTimeout(step,200)</script>s");
    // ── 12 회차: 덮이는(127.0.0.1)·덮이지 않는(localhost) 본문이 번갈아 ──
    if (std.mem.eql(u8, path, "/v20/togp")) return reply(conn, html, "<!doctype html><title>t</title><script>" ++ read_js ++
        "var i=0;function step(){if(i>=200){setTimeout(function(){document.title='tdone'},2500);return}F('/v20/d?tc'+i);F('http://localhost:'+location.port+'/v20/d?tl'+i);i++;setTimeout(step,20)}setTimeout(step,200)</script>t");
    // ── 17 회차: 꾸준한 fetch ──
    if (std.mem.eql(u8, path, "/v20/cycp")) return reply(conn, html, "<!doctype html><title>c</title><script>" ++ read_js ++
        "var i=0;function step(){if(i>=600){document.title='cdone';return}F('/v20/d?cy'+i);i++;setTimeout(step,15)}setTimeout(step,100)</script>c");
    // ── 18 회차: 웹소켓 쏟아짐 — r 는 초당 frame, s 는 ms ──
    if (std.mem.eql(u8, path, "/v20/flood")) return reply(conn, html, "<!doctype html><title>f</title><script>" ++ read_js ++
        "var q=new URLSearchParams(location.search);var R=+q.get('r'),S=+q.get('s');var ws=new WebSocket('ws://'+location.host+'/v20/ws');" ++
        "ws.onopen=function(){var t0=performance.now(),sent=0;function tick(){var el=performance.now()-t0;if(el>=S){after();return}var want=Math.floor(el*R/1000);while(sent<want){ws.send('x');sent++}setTimeout(tick,5)}tick()};" ++
        "function after(){var k=0;function f(){if(k>=10){setTimeout(function(){document.title='fdone'},500);return}F('/v20/d?fa'+k);k++;setTimeout(f,100)}f()}</script>f");
    // ── 19 회차: 작은 fetch 200 개(동시 6) ──
    if (std.mem.eql(u8, path, "/v20/batch")) return reply(conn, html, "<!doctype html><title>b</title><script>" ++
        "var t0=performance.now(),n=0,started=0;function one(){if(started>=200)return;var k=started++;fetch('/v20/d?b'+k+'_'+Math.random()).then(function(r){return r.text()}).then(function(){n++;if(n==200){document.title='bt:'+Math.round(performance.now()-t0)}else one()})}" ++
        "setTimeout(function(){t0=performance.now();for(var j=0;j<6;j++)one()},300)</script>b");
    return reply(conn, "text/plain", "x");
}

const Begin = struct { browser: u64, request: u64, url: []u8, expected: bool, at_ms: i64, full_at_begin: bool };
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
    max_chunk: usize = 0,
    misordered: usize = 0,
    data_sessions_bad: usize = 0,
    end_ms: i64 = 0,
};

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    begins: std.ArrayList(Begin) = .empty,
    bodies: std.ArrayList(Body) = .empty,
    created: std.AutoHashMapUnmanaged(u64, void) = .empty,
    loads: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    titles: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    /// (탭, 세션) → 마지막 상태.
    states: std.ArrayList(struct { browser: u64, session: u32, status: msg.NetRecordStatus, at_ms: i64 }) = .empty,
    devtools: std.AutoHashMapUnmanaged(u32, msg.DevtoolsStatus) = .empty,
    devtools_data: std.AutoHashMapUnmanaged(u32, std.ArrayList(u8)) = .empty,
    /// 지금 설정(12 회차 — 판정자가 바꾼다).
    full_now: bool = true,

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
            .net_begin => |v| self.begins.append(self.gpa, .{ .browser = v.browser, .request = v.request, .url = self.gpa.dupe(u8, v.url) catch &.{}, .expected = v.flags2.body_expected, .at_ms = os.nowMs(), .full_at_begin = self.full_now }) catch {},
            .net_body_data => |v| {
                const b = self.body(v.browser, v.request);
                b.max_chunk = @max(b.max_chunk, v.bytes.len);
                if (b.session != 0 and b.session != v.session) b.data_sessions_bad += 1;
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
            .load_finished => |v| {
                const g = self.loads.getOrPut(self.gpa, v.browser) catch return;
                if (!g.found_existing) g.value_ptr.* = 0;
                g.value_ptr.* += 1;
            },
            .title_changed => |v| self.titles.put(self.gpa, v.browser, self.gpa.dupe(u8, v.text) catch &.{}) catch {},
            .devtools_result_data => |v| {
                const g = self.devtools_data.getOrPut(self.gpa, v.call) catch return;
                if (!g.found_existing) g.value_ptr.* = .empty;
                g.value_ptr.appendSlice(self.gpa, v.bytes) catch {};
            },
            .devtools_result => |v| self.devtools.put(self.gpa, v.call, v.status) catch {},
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

    fn titleIs(self: *Run, browser: u64, prefix: []const u8) ?[]const u8 {
        const t = self.titles.get(browser) orelse return null;
        return if (std.mem.startsWith(u8, t, prefix)) t else null;
    }

    fn pumpTitle(self: *Run, browser: u64, prefix: []const u8, ms: u32) ?[]const u8 {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (self.titleIs(browser, prefix)) |t| return t;
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

    fn navigate(self: *Run, browser: u64, path: []const u8) !void {
        var u: [512]u8 = undefined;
        if (self.titles.getPtr(browser)) |t| t.* = &.{};
        try self.host.send(.{ .navigate = .{ .browser = browser, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}{s}", .{ port, path }) } });
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

    /// `needle` 로 끝나는 주소의 마지막 기록(시작 `at` 뒤).
    fn bodyOf(self: *Run, browser: u64, at: usize, needle: []const u8) ?*Body {
        var i = self.begins.items.len;
        while (i > at) {
            i -= 1;
            const b = self.begins.items[i];
            if (b.browser == browser and std.mem.endsWith(u8, b.url, needle)) return self.body(browser, b.request);
        }
        return null;
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
    const only = std.c.getenv("V20B_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(only), name) != null;
}

fn openTab(r: *Run, id: u64) !void {
    var u: [256]u8 = undefined;
    const size: msg.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
    try r.host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = try std.fmt.bufPrint(&u, "http://127.0.0.1:{d}/v20/blank", .{port}) } });
    if (!r.waitFor(wait_ms, id, createdAndLoaded)) return error.BrowserNotCreated;
    try r.host.send(.{ .net_watch = .{ .browser = id, .on = true, .full = true, .any_host = true } });
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

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    const gpa = std.heap.c_allocator;
    try makeBodies(gpa);
    try startServer();
    var detail: [4000]u8 = undefined;
    var host = try Host.spawnWith(host_path, profile_arg, null, &.{});
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    var r: Run = .{ .host = &host, .gpa = gpa };
    try openTab(&r, rec_tab);
    try openTab(&r, tab_b);
    try openTab(&r, tab_c);
    try openTab(&r, tab_d);
    var session: u32 = 100;
    const rec_ok = try record(&r, rec_tab, session);
    report(rec_ok, "v20b-setup-record-on", if (rec_ok) "net_record_state on for session 100" else "no on state");

    // ── 15 회차: 글 풀기 ──
    if (enabled("enc")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/v20/encp");
        const done = r.pumpTitle(rec_tab, "edone", 20_000) != null;
        r.pump(1500);
        var pb: [200]u8 = undefined;
        const Exp = struct { name: []const u8, ok: bool, line: []const u8 };
        var out: [24]Exp = undefined;
        var n: usize = 0;
        const C = struct {
            fn line(buf: []u8, b: ?*Body, p: []u8) []const u8 {
                const x = b orelse return "no-record";
                return std.fmt.bufPrint(buf, "{s} binary={} redecoded={} chromium_decoded={} size={d} decoded={d} 「{s}」", .{ stateName(b), x.flags.binary, x.flags.redecoded, x.flags.chromium_decoded, x.data.items.len, x.decoded, printable(p, x.data.items) }) catch "";
            }
            fn cap(b: ?*Body) bool {
                const x = b orelse return false;
                return x.ends == 1 and x.state == .captured;
            }
        };
        var lines: [24][700]u8 = undefined;
        inline for (.{
            .{ "u8plain", "redecoded" }, .{ "u8css", "redecoded" },   .{ "u8html", "html" },
            .{ "c1", "redecoded" },      .{ "bom", "bom" },           .{ "bomlatin", "bomlatin" },
            .{ "latin1", "latin1" },     .{ "latin1cs", "latin1cs" }, .{ "euckr", "euckr" },
            .{ "euckrcs", "euckrcs" },   .{ "badjson", "binary" },    .{ "utf16bomjson", "utf16" },
            .{ "pngtext", "png" },       .{ "gzip", "gzip" },         .{ "deflate", "deflate" },
            .{ "br", "br" },             .{ "empty", "nobody" },      .{ "nocontent", "nobody" },
            .{ "head", "nobody" },
        }) |c| {
            const b = r.bodyOf(rec_tab, at, "/v20/enc?" ++ c[0]);
            const kind = c[1];
            var ok = false;
            if (b) |x| {
                const d = x.data.items;
                const one = x.ends == 1;
                if (std.mem.eql(u8, kind, "redecoded")) {
                    const want: []const u8 = if (std.mem.eql(u8, c[0], "u8plain")) u8_text else if (std.mem.eql(u8, c[0], "u8css")) "/* " ++ u8_text ++ " */" else c1_text;
                    ok = C.cap(b) and x.flags.redecoded and std.mem.eql(u8, d, want);
                } else if (std.mem.eql(u8, kind, "html")) {
                    // HTML 은 되돌리지 않는다 — Chromium 이 맞게 풀었으면 원래 글, 아니면 깨진 글이고 표시는 없다(관측 — 잡기만 본다).
                    ok = C.cap(b) and !x.flags.binary;
                } else if (std.mem.eql(u8, kind, "bom")) {
                    ok = C.cap(b) and !x.flags.redecoded and (std.mem.eql(u8, d, hangul) or std.mem.eql(u8, d, "\xef\xbb\xbf" ++ hangul));
                } else if (std.mem.eql(u8, kind, "bomlatin")) {
                    ok = C.cap(b) and !x.flags.redecoded and std.mem.indexOf(u8, d, "caf\xc3\xa9") != null and std.mem.indexOf(u8, d, "\xc3\x83") == null;
                } else if (std.mem.eql(u8, kind, "latin1")) {
                    ok = C.cap(b) and x.flags.chromium_decoded and std.mem.eql(u8, d, latin1_utf8);
                } else if (std.mem.eql(u8, kind, "latin1cs")) {
                    ok = C.cap(b) and !x.flags.chromium_decoded and !x.flags.redecoded and std.mem.eql(u8, d, latin1_utf8);
                } else if (std.mem.eql(u8, kind, "euckr")) {
                    // charset 없는 EUC-KR — windows-1252 로 푼 글(Chromium 이 푼 그대로 표시)이거나 바이트 그대로(바이너리). 틀린 「되돌림」 이 아니다.
                    ok = C.cap(b) and !x.flags.redecoded and ((x.flags.chromium_decoded and std.mem.eql(u8, d, "\xc3\x87\xc3\x91\xc2\xb1\xc3\x9b")) or (x.flags.binary and std.mem.eql(u8, d, euckr_raw)));
                } else if (std.mem.eql(u8, kind, "euckrcs")) {
                    ok = C.cap(b) and std.mem.eql(u8, d, hangul) and !x.flags.binary and !x.flags.chromium_decoded;
                } else if (std.mem.eql(u8, kind, "binary")) {
                    ok = C.cap(b) and x.flags.binary and std.mem.eql(u8, d, bad_json);
                } else if (std.mem.eql(u8, kind, "utf16")) {
                    // 받은 바이트(Σ dataReceived)와 다른 글로 바뀌었으면 그 사실이 표시돼야 한다(바이너리로 그대로이거나 chromium_decoded).
                    ok = C.cap(b) and ((x.flags.binary and std.mem.eql(u8, d, utf16_bom_json)) or x.flags.chromium_decoded);
                } else if (std.mem.eql(u8, kind, "png")) {
                    // 글로 꾸민 바이너리 — 바이트 그대로(binary)이거나 Chromium 이 푼 글(표시)이고, 표시 없는 「글」 이 아니다.
                    ok = C.cap(b) and ((x.flags.binary and std.mem.eql(u8, d, png_text)) or x.flags.chromium_decoded) and std.unicode.utf8ValidateSlice(d) == !x.flags.binary;
                } else if (std.mem.eql(u8, kind, "gzip")) {
                    ok = C.cap(b) and x.flags.redecoded and std.mem.eql(u8, d, gz_plain);
                } else if (std.mem.eql(u8, kind, "deflate")) {
                    ok = C.cap(b) and std.mem.eql(u8, d, df_plain);
                } else if (std.mem.eql(u8, kind, "br")) {
                    // http 의 br — Chromium 이 풀면 글 그대로, 풀지 못하면 요청이 실패한다(어느 쪽이든 끝은 하나, 틀린 바이트는 없다).
                    ok = one and ((x.state == .captured and std.mem.eql(u8, d, br_plain)) or x.state == .request_failed or x.state == .partial);
                } else if (std.mem.eql(u8, kind, "nobody")) {
                    ok = one and x.state == .no_body and d.len == 0;
                }
            }
            out[n] = .{ .name = c[0], .ok = ok and done, .line = C.line(&lines[n], b, &pb) };
            n += 1;
        }
        for (out[0..n]) |e| {
            var nb: [64]u8 = undefined;
            report(e.ok, std.fmt.bufPrint(&nb, "v20b-15-enc-{s}", .{e.name}) catch "v20b-15-enc", e.line);
        }
    }

    // ── 16 회차: 크기 ──
    if (enabled("size")) {
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/v20/sizep");
        const done = r.pumpTitle(rec_tab, "sdone", 40_000) != null;
        r.pump(1500);
        const names = [_][]const u8{ "1", "64KiB-1", "64KiB", "64KiB+1", "1MiB", "1MiB+1", "1MiB-utf8-json", "1MiB-utf8-text-nocharset", "70KiB-4byte-chars-straddling-16KiB" };
        for (names, 0..) |name, i| {
            var nb: [24]u8 = undefined;
            const b = r.bodyOf(rec_tab, at, std.fmt.bufPrint(&nb, "/v20/size?{d}", .{i}) catch "");
            const want = size_bodies[i];
            var ok = false;
            var line: [400]u8 = undefined;
            var ln: []const u8 = "no-record";
            if (b) |x| {
                if (i == 5) {
                    ok = x.ends == 1 and x.state == .over_cap and x.data.items.len == 0 and x.decoded == want.len;
                } else {
                    ok = x.ends == 1 and x.state == .captured and std.mem.eql(u8, x.data.items, want) and x.size == want.len and x.max_chunk <= msg.net_body_chunk_bytes and x.misordered == 0 and !x.flags.binary;
                    if (i == 7) ok = ok and x.flags.redecoded;
                }
                ln = std.fmt.bufPrint(&line, "{s} got {d}/{d} bytes · end size {d} · decoded {d} · max chunk {d} · misordered {d} · redecoded {} · binary {}", .{ stateName(b), x.data.items.len, want.len, x.size, x.decoded, x.max_chunk, x.misordered, x.flags.redecoded, x.flags.binary }) catch "";
            }
            var nn: [80]u8 = undefined;
            report(ok and done, std.fmt.bufPrint(&nn, "v20b-16-size-{s}", .{name}) catch "v20b-16-size", ln);
        }
    }

    // ── 12 회차: 설정을 빠르게 켜고 끈다 ──
    if (enabled("toggle")) {
        session += 1;
        _ = try record(&r, rec_tab, session);
        const at = r.begins.items.len;
        const first_session = session;
        try r.navigate(rec_tab, "/v20/togp");
        var toggles: usize = 0;
        // 꺼진 창: [시작, 끝) — 판정자 시각.
        var off_windows: [64][2]i64 = undefined;
        var n_off: usize = 0;
        const t_end = os.nowMs() + 4600;
        while (os.nowMs() < t_end) {
            r.pump(80);
            if (r.full_now) {
                var hosts: [msg.max_net_watch_hosts][]const u8 = @splat("");
                hosts[0] = "127.0.0.1";
                try host.send(.{ .net_watch = .{ .browser = rec_tab, .on = true, .full = false, .any_host = false, .host_count = 1, .hosts = hosts } });
                // maru 의 wipe 처럼 새 세션으로.
                session += 1;
                try host.send(.{ .net_record = .{ .browser = rec_tab, .on = true, .session = session } });
                r.full_now = false;
                if (n_off < off_windows.len) {
                    off_windows[n_off] = .{ os.nowMs(), std.math.maxInt(i64) };
                    n_off += 1;
                }
            } else {
                try host.send(.{ .net_watch = .{ .browser = rec_tab, .on = true, .full = true, .any_host = true } });
                r.full_now = true;
                if (n_off > 0) off_windows[n_off - 1][1] = os.nowMs();
            }
            toggles += 1;
        }
        if (!r.full_now) {
            try host.send(.{ .net_watch = .{ .browser = rec_tab, .on = true, .full = true, .any_host = true } });
            r.full_now = true;
            if (n_off > 0) off_windows[n_off - 1][1] = os.nowMs();
        }
        const done = r.pumpTitle(rec_tab, "tdone", 20_000) != null;
        r.pump(2000);
        var expected: usize = 0;
        var one_end: usize = 0;
        var no_end: usize = 0;
        var multi: usize = 0;
        var lh_total: usize = 0;
        var lh_inside_off: usize = 0;
        var lh_inside_off_captured: usize = 0;
        var lh_captured: usize = 0;
        var own_total: usize = 0;
        var own_captured: usize = 0;
        var states: [16]usize = @splat(0);
        var stale_session_ends: usize = 0;
        for (r.begins.items[at..]) |b| if (b.browser == rec_tab and std.mem.indexOf(u8, b.url, "/v20/d?t") != null) {
            const x = r.body(rec_tab, b.request);
            if (b.expected) expected += 1;
            if (b.expected and x.ends == 0) no_end += 1;
            if (x.ends == 1) one_end += 1;
            if (x.ends > 1) multi += 1;
            if (x.ends == 1) {
                states[@backingInt(x.state)] += 1;
                if (x.session < first_session or x.session > session) stale_session_ends += 1;
            }
            const lh = std.mem.indexOf(u8, b.url, "localhost") != null;
            if (lh) {
                lh_total += 1;
                if (x.ends == 1 and x.state == .captured) lh_captured += 1;
                // 시작과 끝이 같은 꺼진 창 안(여유 30 ms — 판정자가 보낸 뒤 sidecar 가 받기까지).
                for (off_windows[0..n_off]) |w| if (b.at_ms >= w[0] + 30 and x.end_ms != 0 and x.end_ms < w[1]) {
                    lh_inside_off += 1;
                    if (x.ends == 1 and x.state == .captured) lh_inside_off_captured += 1;
                    break;
                };
            } else {
                own_total += 1;
                if (x.ends == 1 and x.state == .captured) own_captured += 1;
            }
        };
        var sl: [400]u8 = undefined;
        var sn: usize = 0;
        for (states, 0..) |c, i| if (c > 0 and i < 14) {
            const piece = std.fmt.bufPrint(sl[sn..], " {s}={d}", .{ @tagName(@as(msg.NetBodyState, @fromBackingInt(@intCast(i)))), c }) catch break;
            sn += piece.len;
        };
        report(done and no_end == 0 and multi == 0 and stale_session_ends == 0, "v20b-12-toggle-one-end-each", std.fmt.bufPrint(&detail, "toggles {d} (off windows {d}, sessions {d}..{d}) · body_expected {d} · one end {d} · no end {d} · several {d} · ends with a session outside the issued ones {d} · states{s}", .{ toggles, n_off, first_session, session, expected, one_end, no_end, multi, stale_session_ends, sl[0..sn] }) catch "");
        report(done and lh_inside_off > 0 and lh_inside_off_captured == 0, "v20b-12-toggle-uncovered-not-captured-while-off", std.fmt.bufPrint(&detail, "localhost requests {d} · captured overall {d} · begun and ended inside an off window {d} · of them captured {d} (need 0)", .{ lh_total, lh_captured, lh_inside_off, lh_inside_off_captured }) catch "");
        report(done and own_captured * 100 >= own_total * 50, "v20b-12-toggle-covered-control", std.fmt.bufPrint(&detail, "127.0.0.1 captured {d}/{d} (control — need >= 50 %)", .{ own_captured, own_total }) catch "");
        // 마지막 세션이 on 으로 답했다.
        report(r.stateFor(rec_tab, session) == .on, "v20b-12-toggle-last-session-on", if (r.stateFor(rec_tab, session) == .on) "on" else "no on state for the last session");
    }

    // ── 17 회차: 켬·끔 200 번 ──
    if (enabled("cycle")) {
        const at = r.begins.items.len;
        try r.navigate(tab_b, "/v20/cycp");
        r.pump(200);
        var prng = std.Random.DefaultPrng.init(0x20b17);
        const rnd = prng.random();
        var issued_lo: u32 = 0;
        var on_states: usize = 0;
        var cycles: usize = 0;
        var doubles: usize = 0;
        const first = session + 1;
        issued_lo = first;
        for (0..200) |i| {
            session += 1;
            try host.send(.{ .net_record = .{ .browser = tab_b, .on = true, .session = session } });
            if (i % 9 == 4) {
                // 끄지 않고 다시 켠다(새 세션).
                r.pump(rnd.intRangeAtMost(u32, 0, 10));
                session += 1;
                try host.send(.{ .net_record = .{ .browser = tab_b, .on = true, .session = session } });
                doubles += 1;
            }
            r.pump(rnd.intRangeAtMost(u32, 0, 30));
            try host.send(.{ .net_record = .{ .browser = tab_b, .on = false } });
            r.pump(rnd.intRangeAtMost(u32, 0, 5));
            cycles += 1;
        }
        r.pump(500);
        for (r.states.items) |s| if (s.browser == tab_b and s.session >= first and s.status == .on) {
            on_states += 1;
        };
        // 마지막으로 켜 두고 본문을 잡는가(자리가 새지 않았다).
        session += 1;
        const last_on = try record(&r, tab_b, session);
        const at_last = r.begins.items.len;
        _ = r.pumpTitle(tab_b, "cdone", 15_000);
        r.pump(1500);
        var last_captured: usize = 0;
        var last_total: usize = 0;
        for (r.begins.items[at_last..]) |b| if (b.browser == tab_b and std.mem.indexOf(u8, b.url, "/v20/d?cy") != null and b.expected) {
            last_total += 1;
            const x = r.body(tab_b, b.request);
            if (x.ends == 1 and x.state == .captured) last_captured += 1;
        };
        var expected: usize = 0;
        var no_end: usize = 0;
        var multi: usize = 0;
        var states: [16]usize = @splat(0);
        var bad_sess: usize = 0;
        for (r.begins.items[at..]) |b| if (b.browser == tab_b and b.expected) {
            expected += 1;
            const x = r.body(tab_b, b.request);
            if (x.ends == 0) no_end += 1;
            if (x.ends > 1) multi += 1;
            if (x.ends == 1) {
                states[@backingInt(x.state)] += 1;
                if (x.session < issued_lo or x.session > session) bad_sess += 1;
            }
            if (x.data_sessions_bad > 0) bad_sess += 1;
        };
        var sl: [400]u8 = undefined;
        var sn: usize = 0;
        for (states, 0..) |c, i| if (c > 0 and i < 14) {
            const piece = std.fmt.bufPrint(sl[sn..], " {s}={d}", .{ @tagName(@as(msg.NetBodyState, @fromBackingInt(@intCast(i)))), c }) catch break;
            sn += piece.len;
        };
        report(no_end == 0 and multi == 0 and bad_sess == 0, "v20b-17-cycle-one-end-each", std.fmt.bufPrint(&detail, "cycles {d} (on twice without off {d}) · on states {d} · body_expected {d} · no end {d} · several {d} · wrong session {d} · states{s}", .{ cycles, doubles, on_states, expected, no_end, multi, bad_sess, sl[0..sn] }) catch "");
        report(last_on and last_total > 0 and last_captured * 100 >= last_total * 80, "v20b-17-cycle-last-on-captures", std.fmt.bufPrint(&detail, "after {d} cycles: on {} · captured {d}/{d} (need >= 80 %)", .{ cycles, last_on, last_captured, last_total }) catch "");
        try host.send(.{ .net_record = .{ .browser = tab_b, .on = false } });
        try r.navigate(tab_b, "/v20/blank?b");
        r.pump(500);
    }

    // ── 18 회차: 쏟아짐 밸브 ──
    if (enabled("flood")) {
        const Case = struct { name: []const u8, rate: u32, ms: u32, want_pause: bool };
        const cases = [_]Case{
            .{ .name = "control-3000-per-s-4s", .rate = 3000, .ms = 4000, .want_pause = false },
            .{ .name = "boundary-5500-per-s-0.9s", .rate = 5500, .ms = 900, .want_pause = false },
            .{ .name = "8000-per-s-3s", .rate = 8000, .ms = 3000, .want_pause = true },
        };
        for (cases) |c| {
            session += 1;
            const s = session;
            const on = try record(&r, tab_c, s);
            const at = r.begins.items.len;
            const t0 = os.nowMs();
            const frames0 = ws_frames.load(.monotonic);
            var pb: [80]u8 = undefined;
            try r.navigate(tab_c, std.fmt.bufPrint(&pb, "/v20/flood?r={d}&s={d}", .{ c.rate, c.ms }) catch "/v20/flood");
            const done = r.pumpTitle(tab_c, "fdone", 20_000) != null;
            r.pump(1500);
            var paused_ms: i64 = -1;
            for (r.states.items) |st| if (st.browser == tab_c and st.session == s and st.status == .paused) {
                paused_ms = st.at_ms - t0;
                break;
            };
            const paused = paused_ms >= 0;
            // 그 뒤 fetch(fa*) — 멈췄으면 본문을 기다리지 않는다, 아니면 잡는다.
            var after_expected: usize = 0;
            var after_total: usize = 0;
            var after_captured: usize = 0;
            for (r.begins.items[at..]) |b| if (b.browser == tab_c and std.mem.indexOf(u8, b.url, "/v20/d?fa") != null) {
                after_total += 1;
                if (b.expected) after_expected += 1;
                const x = r.body(tab_c, b.request);
                if (x.ends == 1 and x.state == .captured) after_captured += 1;
            };
            var auto_on = false;
            for (r.states.items) |st| if (st.browser == tab_c and st.session == s and st.status == .on and st.at_ms - t0 > paused_ms and paused) {
                auto_on = true;
            };
            const frames = ws_frames.load(.monotonic) - frames0;
            var nn: [80]u8 = undefined;
            if (c.want_pause) {
                report(on and done and paused and after_expected == 0 and !auto_on, std.fmt.bufPrint(&nn, "v20b-18-flood-{s}", .{c.name}) catch "", std.fmt.bufPrint(&detail, "paused {} after {d} ms · later fetches {d} with body_expected {d} (need 0) · auto re-on {} · ws bytes/16 ≈ {d}", .{ paused, paused_ms, after_total, after_expected, auto_on, frames }) catch "");
                // 다시 켜면 새 세션으로 잡는다.
                session += 1;
                const again = try record(&r, tab_c, session);
                const at2 = r.begins.items.len;
                try r.navigate(tab_c, "/v20/flood?r=10&s=200");
                _ = r.pumpTitle(tab_c, "fdone", 10_000);
                r.pump(1000);
                var c2: usize = 0;
                var t2: usize = 0;
                for (r.begins.items[at2..]) |b| if (b.browser == tab_c and std.mem.indexOf(u8, b.url, "/v20/d?fa") != null) {
                    t2 += 1;
                    const x = r.body(tab_c, b.request);
                    if (x.ends == 1 and x.state == .captured) c2 += 1;
                };
                report(again and t2 > 0 and c2 == t2, "v20b-18-flood-manual-reenable", std.fmt.bufPrint(&detail, "re-on {} · captured {d}/{d}", .{ again, c2, t2 }) catch "");
            } else {
                report(on and done and !paused and after_total > 0 and after_captured == after_total, std.fmt.bufPrint(&nn, "v20b-18-flood-{s}", .{c.name}) catch "", std.fmt.bufPrint(&detail, "paused {} (need false) · later fetches captured {d}/{d} · ws bytes/16 ≈ {d}", .{ paused, after_captured, after_total, frames }) catch "");
            }
        }
        try host.send(.{ .net_record = .{ .browser = tab_c, .on = false } });
    }

    // ── 19 회차: DevTools 지킴의 이름 변형 ──
    if (enabled("guard")) {
        session += 1;
        _ = try record(&r, rec_tab, session);
        const names = [_][]const u8{ "Network.enable", "Network.disable", "network.enable", "NETWORK.DISABLE", "Network.Enable", "network.disable", "Fetch.enable", "Fetch.disable", "Fetch.continueRequest", "fetch.enable", "Fetch.getResponseBody" };
        var call: u32 = 7000;
        var line: [1600]u8 = undefined;
        var ln: usize = 0;
        var all_blocked = true;
        for (names) |m| {
            call += 1;
            try host.send(.{ .devtools_call = .{ .browser = rec_tab, .call = call, .method = m, .params_size = 0 } });
            const Ctx = struct { call: u32 };
            const got = r.waitFor(3000, Ctx{ .call = call }, struct {
                fn f(x: *Run, c: Ctx) bool {
                    return x.devtools.contains(c.call);
                }
            }.f);
            const st = r.devtools.get(call);
            var res: []const u8 = "";
            if (r.devtools_data.get(call)) |d| res = d.items[0..@min(d.items.len, 90)];
            // 거절(invalid_request)이거나 CDP 가 모르는 메서드라고 답했다(cdp_error·'wasn't found').
            const blocked = got and st != null and (st.? == .invalid_request or (st.? == .cdp_error and std.mem.indexOf(u8, res, "wasn't found") != null));
            if (!blocked) all_blocked = false;
            const piece = std.fmt.bufPrint(line[ln..], " [{s}: {s}{s}{s}]", .{ m, if (st) |v| @tagName(v) else "no-answer", if (res.len > 0) " " else "", res }) catch "";
            ln += piece.len;
        }
        r.pump(300);
        // 그 뒤에도 기록이 이어진다 — 본문 하나를 잡는다, 상태는 on 그대로.
        const at = r.begins.items.len;
        try r.navigate(rec_tab, "/v20/encp");
        _ = r.pumpTitle(rec_tab, "edone", 20_000);
        r.pump(1000);
        const after = r.bodyOf(rec_tab, at, "/v20/enc?u8plain");
        var paused_or_off = false;
        for (r.states.items) |st| if (st.browser == rec_tab and st.session == session and st.status != .on) {
            paused_or_off = true;
        };
        report(all_blocked, "v20b-19-guard-variants", line[0..ln]);
        report(after != null and after.?.ends == 1 and after.?.state == .captured and !paused_or_off, "v20b-19-guard-recording-continues", std.fmt.bufPrint(&detail, "after the attempts: u8plain {s} · state changed {}", .{ stateName(after), paused_or_off }) catch "");
    }

    // ── 19 회차: 부담(관측) ──
    if (enabled("overhead")) {
        var times: [3][7]i64 = undefined;
        // 0: 기록을 켠 적 없는 탭(tab_d), 1: 켠 탭, 2: 끈 탭(같은 tab_d — 켰다 끈 뒤).
        for (0..3) |mode| {
            if (mode == 1) {
                session += 1;
                _ = try record(&r, tab_d, session);
            }
            if (mode == 2) {
                try host.send(.{ .net_record = .{ .browser = tab_d, .on = false } });
                r.pump(300);
            }
            for (0..7) |k| {
                var pb: [64]u8 = undefined;
                try r.navigate(tab_d, std.fmt.bufPrint(&pb, "/v20/batch?m{d}k{d}", .{ mode, k }) catch "/v20/batch");
                const t = r.pumpTitle(tab_d, "bt:", 30_000);
                times[mode][k] = if (t) |s| std.fmt.parseInt(i64, s[3..], 10) catch -1 else -1;
                r.pump(200);
            }
        }
        var med: [3]i64 = undefined;
        for (0..3) |m| {
            var c = times[m];
            std.mem.sort(i64, &c, {}, std.sort.asc(i64));
            med[m] = c[3];
        }
        report(med[0] > 0 and med[1] > 0 and med[2] > 0, "v20b-19-overhead", std.fmt.bufPrint(&detail, "200 small fetches (6 at a time), median of 7 ms — never recorded {d} · recording {d} · recording turned off {d} · runs never {any} · on {any} · off {any}", .{ med[0], med[1], med[2], times[0], times[1], times[2] }) catch "");
    }
}
