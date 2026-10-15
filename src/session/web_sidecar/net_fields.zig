//! 네트워크 메시지(W9d① — wire 21)의 닫힌 필드 규칙과 몸통 쓰기·읽기. encode 와 decode 가 **같은 검사 함수**(`checkBegin` 등)를
//! 지나야 한쪽만 느슨해지지 않는다(fields.zig 와 같은 규율). 헤더 덩어리는 frame 을 빌리는 바이트로 오가며(`NetHeaderBlock`) 만드는 쪽은
//! `HeaderBuilder`, 읽는 쪽은 `HeaderIterator` 를 쓴다 — sidecar 와 maru 가 같은 파일을 쓴다.
//!
//! 시험이 증명하는 것: 상한(주소 2 KiB·헤더 64 개·8 KiB·메서드 토큰), 짝이 맞지 않는 표시(주 프레임이면서 하위 프레임, 서비스 워커인데
//! 프레임), 0 번 요청, 모르는 자원 종류·결과, 덩어리 안 길이가 어긋난 헤더가 양쪽 모두에서 거절된다는 것. 브라우저 탭에서 중요한 이유 —
//! 이 글들은 페이지·서버가 고른 것이라(주소·헤더 값) 받는 쪽이 길이·모양을 믿으면 안 된다.

const std = @import("std");
const wire = @import("wire.zig");
const message = @import("message.zig");
const fields = @import("fields.zig");

const Cursor = wire.Cursor;
const ReadCursor = wire.ReadCursor;
const Error = wire.Error;

pub const max_url_bytes = message.max_net_url_bytes;
pub const max_method_bytes = message.max_net_method_bytes;
pub const max_origin_bytes = message.max_net_origin_bytes;
pub const max_mime_bytes = message.max_net_mime_bytes;
pub const max_header_count = message.max_net_header_count;
pub const max_headers_bytes = message.max_net_headers_bytes;
pub const max_header_name_bytes = message.max_net_header_name_bytes;
pub const max_watch_hosts = message.max_net_watch_hosts;

/// 헤더 덩어리의 바이트 상한 — 이름·값 합(`max_headers_bytes`)에 헤더마다 길이 칸 셋.
pub const max_header_block_bytes: usize = max_headers_bytes + max_header_count * 3;

// ── 글 규칙 ─────────────────────────────────────────────────────────────────────────────────────────────────

/// UTF-8 이고 C0 제어 문자·DEL 이 없다(탭도 거절 — 주소·출처·MIME 은 한 줄 글이다).
fn checkLine(text: []const u8, max: usize) Error!void {
    if (text.len > max) return error.InvalidNetwork;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return error.ControlCharacter;
}

/// HTTP 메서드 — RFC 9110 토큰 글자(tchar), 1..32 바이트.
pub fn checkMethod(method: []const u8) Error!void {
    if (method.len == 0 or method.len > max_method_bytes) return error.InvalidNetwork;
    for (method) |c| if (!isTchar(c)) return error.InvalidNetwork;
}

fn isTchar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
}

/// 헤더 이름 — 비지 않은 토큰 글자(tchar), 255 바이트까지.
pub fn checkHeaderName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_header_name_bytes) return error.InvalidNetwork;
    for (name) |c| if (!isTchar(c)) return error.InvalidNetwork;
}

/// 헤더 값 — UTF-8, 탭만 허용하는 제어 문자 없음(값은 sidecar 가 다듬어 보낸다 — 줄바꿈으로 다음 헤더를 흉내 내지 못하게).
pub fn checkHeaderValue(value: []const u8) Error!void {
    if (value.len > max_headers_bytes) return error.InvalidNetwork;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.ControlCharacter;
}

/// 호스트(grant 호스트 — `net_watch`) — 비고 253 바이트를 넘지 않으며 소문자 글자·숫자·`-`·`.`·`:`·`[`·`]` 만(IPv6 포함).
pub fn checkHost(host: []const u8) Error!void {
    if (host.len == 0 or host.len > 253) return error.InvalidNetwork;
    for (host) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '.' or c == ':' or c == '[' or c == ']' or c == '_';
        if (!ok) return error.InvalidNetwork;
    }
}

// ── 헤더 덩어리 ───────────────────────────────────────────────────────────────────────────────────────────

/// 덩어리를 차례로 읽는다. 모양은 `checkHeaders` 가 먼저 봤다고 가정하지 않는다 — 어긋나면 null 로 끝난다.
pub const HeaderIterator = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub const Header = struct { name: []const u8, value: []const u8 };

    pub fn init(block: message.NetHeaderBlock) HeaderIterator {
        return .{ .bytes = block.bytes };
    }

    pub fn next(self: *HeaderIterator) ?Header {
        if (self.pos >= self.bytes.len) return null;
        const name_len = self.bytes[self.pos];
        const name_end = self.pos + 1 + name_len;
        if (name_end + 2 > self.bytes.len) return null;
        const value_len = std.mem.readInt(u16, self.bytes[name_end..][0..2], .big);
        const value_end = name_end + 2 + value_len;
        if (value_end > self.bytes.len) return null;
        const h: Header = .{ .name = self.bytes[self.pos + 1 .. name_end], .value = self.bytes[name_end + 2 .. value_end] };
        self.pos = value_end;
        return h;
    }
};

/// 덩어리의 모양: `count` 개의 헤더가 바이트를 꼭 채우고, 이름·값 규칙과 상한을 지킨다.
pub fn checkHeaders(block: message.NetHeaderBlock) Error!void {
    if (block.count > max_header_count or block.bytes.len > max_header_block_bytes) return error.InvalidNetwork;
    var it = HeaderIterator.init(block);
    var n: usize = 0;
    var payload: usize = 0;
    while (it.next()) |h| {
        n += 1;
        try checkHeaderName(h.name);
        try checkHeaderValue(h.value);
        payload += h.name.len + h.value.len;
    }
    if (n != block.count or it.pos != block.bytes.len) return error.InvalidNetwork;
    if (payload > max_headers_bytes) return error.InvalidNetwork;
}

/// 덩어리를 만든다(sidecar 가 CEF 헤더에서, 시험이 손으로). 이름이 토큰 글자가 아니면 그 헤더를 빼고, 값의 제어 문자는 공백으로
/// 바꾼다. 개수·바이트 상한을 넘는 헤더는 싣지 않고 `truncated` 를 세운다(값이 길면 그 헤더는 앞부분만 — 끝에 「…」).
pub const HeaderBuilder = struct {
    buf: [max_header_block_bytes]u8 = undefined,
    len: usize = 0,
    count: u8 = 0,
    payload: usize = 0,
    truncated: bool = false,

    pub fn block(self: *const HeaderBuilder) message.NetHeaderBlock {
        return .{ .count = self.count, .bytes = self.buf[0..self.len] };
    }

    /// 헤더 하나를 덧붙인다. 실었으면 true.
    pub fn add(self: *HeaderBuilder, name: []const u8, value: []const u8) bool {
        if (checkHeaderName(name)) |_| {} else |_| {
            self.truncated = true;
            return false;
        }
        if (self.count >= max_header_count) {
            self.truncated = true;
            return false;
        }
        const room = max_headers_bytes -| self.payload;
        if (name.len >= room) {
            self.truncated = true;
            return false;
        }
        var shown = value;
        var cut = false;
        if (name.len + value.len > room) {
            // 남은 자리에 「…」 을 붙일 만큼만 — 글자 경계에서.
            const keep = room - name.len -| 3;
            shown = @import("text.zig").clampUtf8(value, keep);
            cut = true;
        }
        if (!std.unicode.utf8ValidateSlice(shown)) shown = "";
        const extra: usize = if (cut) 3 else 0;
        const need = 1 + name.len + 2 + shown.len + extra;
        if (self.len + need > self.buf.len) {
            self.truncated = true;
            return false;
        }
        self.buf[self.len] = @intCast(name.len);
        @memcpy(self.buf[self.len + 1 ..][0..name.len], name);
        const vstart = self.len + 1 + name.len + 2;
        std.mem.writeInt(u16, self.buf[self.len + 1 + name.len ..][0..2], @intCast(shown.len + extra), .big);
        @memcpy(self.buf[vstart..][0..shown.len], shown);
        for (self.buf[vstart..][0..shown.len]) |*b| {
            if ((b.* < 0x20 and b.* != '\t') or b.* == 0x7f) b.* = ' ';
        }
        if (cut) @memcpy(self.buf[vstart + shown.len ..][0..3], "…");
        self.len += need;
        self.count += 1;
        self.payload += name.len + shown.len + extra;
        if (cut) self.truncated = true;
        return true;
    }
};

fn writeHeaders(cursor: *Cursor, block: message.NetHeaderBlock) Error!void {
    try cursor.writeByte(block.count);
    try cursor.writeU16(@intCast(block.bytes.len));
    try cursor.writeBytes(block.bytes);
}

fn readHeaders(cursor: *ReadCursor) Error!message.NetHeaderBlock {
    const count = try cursor.readByte();
    const len = try cursor.readU16();
    if (len > max_header_block_bytes) return error.InvalidNetwork;
    return .{ .count = count, .bytes = try cursor.readBytes(len) };
}

fn writeLine(cursor: *Cursor, text: []const u8) Error!void {
    try cursor.writeU16(@intCast(text.len));
    try cursor.writeBytes(text);
}

fn readLine(cursor: *ReadCursor, max: usize) Error![]const u8 {
    const len = try cursor.readU16();
    if (len > max) return error.InvalidNetwork;
    return cursor.readBytes(len);
}

fn checkRequest(request: u64) Error!void {
    if (request == 0) return error.InvalidNetwork;
}

// ── net_begin ─────────────────────────────────────────────────────────────────────────────────────────────

pub fn checkBegin(v: message.NetBegin) Error!void {
    try checkRequest(v.request);
    if (v.flags._reserved != 0) return error.InvalidNetwork;
    if (v.flags.main_frame and v.flags.subframe) return error.InvalidNetwork;
    // 서비스 워커가 대신 보낸 요청에는 CEF 의 프레임이 없다.
    if (v.flags.service_worker and (v.flags.main_frame or v.flags.subframe)) return error.InvalidNetwork;
    if (v.resource_type > message.max_net_resource_type or v.resource_type == 18) return error.InvalidNetwork;
    try checkMethod(v.method);
    if (v.url.len == 0) return error.InvalidNetwork;
    try checkLine(v.url, max_url_bytes);
    try checkLine(v.initiator, max_origin_bytes);
    try checkLine(v.site, max_origin_bytes);
    try checkHeaders(v.headers);
}

pub fn writeBegin(cursor: *Cursor, v: message.NetBegin) Error!void {
    try checkBegin(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU64(v.request);
    try cursor.writeByte(@bitCast(v.flags));
    try cursor.writeByte(v.resource_type);
    try cursor.writeU64(v.time_ms);
    try writeLine(cursor, v.method);
    try writeLine(cursor, v.url);
    try writeLine(cursor, v.initiator);
    try writeLine(cursor, v.site);
    try writeHeaders(cursor, v.headers);
}

pub fn readBegin(cursor: *ReadCursor) Error!message.NetBegin {
    const v: message.NetBegin = .{
        .browser = try fields.readBrowser(cursor),
        .request = try cursor.readU64(),
        .flags = @bitCast(try cursor.readByte()),
        .resource_type = try cursor.readByte(),
        .time_ms = try cursor.readU64(),
        .method = try readLine(cursor, max_method_bytes),
        .url = try readLine(cursor, max_url_bytes),
        .initiator = try readLine(cursor, max_origin_bytes),
        .site = try readLine(cursor, max_origin_bytes),
        .headers = try readHeaders(cursor),
    };
    try checkBegin(v);
    return v;
}

// ── net_redirect ──────────────────────────────────────────────────────────────────────────────────────────

fn checkHopFlags(f: message.NetHopFlags) Error!void {
    if (f._reserved != 0) return error.InvalidNetwork;
}

pub fn checkRedirect(v: message.NetRedirect) Error!void {
    try checkRequest(v.request);
    try checkHopFlags(v.flags);
    if (v.status < 100 or v.status > 599) return error.InvalidNetwork;
    if (v.url.len == 0) return error.InvalidNetwork;
    try checkLine(v.url, max_url_bytes);
    try checkHeaders(v.headers);
}

pub fn writeRedirect(cursor: *Cursor, v: message.NetRedirect) Error!void {
    try checkRedirect(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU64(v.request);
    try cursor.writeU16(v.status);
    try cursor.writeByte(@bitCast(v.flags));
    try cursor.writeU64(v.time_ms);
    try writeLine(cursor, v.url);
    try writeHeaders(cursor, v.headers);
}

pub fn readRedirect(cursor: *ReadCursor) Error!message.NetRedirect {
    const v: message.NetRedirect = .{
        .browser = try fields.readBrowser(cursor),
        .request = try cursor.readU64(),
        .status = try cursor.readU16(),
        .flags = @bitCast(try cursor.readByte()),
        .time_ms = try cursor.readU64(),
        .url = try readLine(cursor, max_url_bytes),
        .headers = try readHeaders(cursor),
    };
    try checkRedirect(v);
    return v;
}

// ── net_response ──────────────────────────────────────────────────────────────────────────────────────────

pub fn checkResponse(v: message.NetResponse) Error!void {
    try checkRequest(v.request);
    try checkHopFlags(v.flags);
    if (v.flags.url_truncated) return error.InvalidNetwork; // 응답은 주소를 싣지 않는다
    if (v.status > 999) return error.InvalidNetwork;
    try checkLine(v.mime, max_mime_bytes);
    try checkHeaders(v.headers);
}

pub fn writeResponse(cursor: *Cursor, v: message.NetResponse) Error!void {
    try checkResponse(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU64(v.request);
    try cursor.writeU16(v.status);
    try cursor.writeByte(@bitCast(v.flags));
    try cursor.writeU64(v.time_ms);
    try writeLine(cursor, v.mime);
    try writeHeaders(cursor, v.headers);
}

pub fn readResponse(cursor: *ReadCursor) Error!message.NetResponse {
    const v: message.NetResponse = .{
        .browser = try fields.readBrowser(cursor),
        .request = try cursor.readU64(),
        .status = try cursor.readU16(),
        .flags = @bitCast(try cursor.readByte()),
        .time_ms = try cursor.readU64(),
        .mime = try readLine(cursor, max_mime_bytes),
        .headers = try readHeaders(cursor),
    };
    try checkResponse(v);
    return v;
}

// ── net_end·net_dropped ──────────────────────────────────────────────────────────────────────────────────

pub fn checkEnd(v: message.NetEnd) Error!void {
    try checkRequest(v.request);
    if (v.error_code > 0) return error.InvalidNetwork;
    if (v.outcome == .success and v.error_code != 0) return error.InvalidNetwork;
    // CEF `received_content_length` 는 i64 — 음수는 sidecar 가 0 으로 보낸다.
    if (v.received > std.math.maxInt(i64)) return error.InvalidNetwork;
}

pub fn writeEnd(cursor: *Cursor, v: message.NetEnd) Error!void {
    try checkEnd(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU64(v.request);
    try cursor.writeByte(@intFromEnum(v.outcome));
    try cursor.writeU32(@bitCast(v.error_code));
    try cursor.writeU64(v.received);
    try cursor.writeU64(v.time_ms);
}

pub fn readEnd(cursor: *ReadCursor) Error!message.NetEnd {
    const v: message.NetEnd = .{
        .browser = try fields.readBrowser(cursor),
        .request = try cursor.readU64(),
        .outcome = std.enums.fromInt(message.NetOutcome, try cursor.readByte()) orelse return error.InvalidNetwork,
        .error_code = @bitCast(try cursor.readU32()),
        .received = try cursor.readU64(),
        .time_ms = try cursor.readU64(),
    };
    try checkEnd(v);
    return v;
}

pub fn writeDropped(cursor: *Cursor, v: message.NetDropped) Error!void {
    if (v.count == 0) return error.InvalidNetwork;
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.count);
}

pub fn readDropped(cursor: *ReadCursor) Error!message.NetDropped {
    const v: message.NetDropped = .{ .browser = try fields.readBrowser(cursor), .count = try cursor.readU32() };
    if (v.count == 0) return error.InvalidNetwork;
    return v;
}

// ── net_watch ─────────────────────────────────────────────────────────────────────────────────────────────

pub fn checkWatch(v: message.NetWatch) Error!void {
    if (v.host_count > max_watch_hosts) return error.InvalidNetwork;
    if (!v.on and (v.full or v.host_count != 0)) return error.InvalidNetwork;
    for (v.hosts[0..v.host_count]) |h| try checkHost(h);
}

pub fn writeWatch(cursor: *Cursor, v: message.NetWatch) Error!void {
    try checkWatch(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeByte(@intFromBool(v.on));
    try cursor.writeByte(@intFromBool(v.full));
    try cursor.writeByte(v.host_count);
    for (v.hosts[0..v.host_count]) |h| {
        try cursor.writeByte(@intCast(h.len));
        try cursor.writeBytes(h);
    }
}

pub fn readWatch(cursor: *ReadCursor) Error!message.NetWatch {
    var v: message.NetWatch = .{
        .browser = try fields.readBrowser(cursor),
        .on = try fields.readBool(cursor),
        .full = try fields.readBool(cursor),
        .host_count = try cursor.readByte(),
    };
    if (v.host_count > max_watch_hosts) return error.InvalidNetwork;
    for (v.hosts[0..v.host_count]) |*h| {
        const len = try cursor.readByte();
        h.* = try cursor.readBytes(len);
    }
    try checkWatch(v);
    return v;
}

// 가장 큰 네트워크 frame(net_begin: 머리 + 고정 칸 + 글 넷의 상한 + 헤더 덩어리 상한)이 frame 상한 안에 든다.
comptime {
    const begin = wire.prefix_len + wire.common_len + 8 + 8 + 1 + 1 + 8 + (2 + max_method_bytes) + (2 + max_url_bytes) + 2 * (2 + max_origin_bytes) + 3 + max_header_block_bytes;
    std.debug.assert(begin <= wire.max_frame_bytes);
    std.debug.assert(max_header_block_bytes <= std.math.maxInt(u16));
    std.debug.assert(max_header_count <= std.math.maxInt(u8));
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "W9d①: HeaderBuilder 는 토큰이 아닌 이름을 빼고, 값의 제어 문자를 공백으로, 상한을 넘으면 싣지 않거나 잘라 truncated 를 세운다 — 만든 덩어리는 checkHeaders 를 지난다" {
    var b: HeaderBuilder = .{};
    try testing.expect(b.add("Content-Type", "text/html; charset=utf-8"));
    try testing.expect(b.add("Set-Cookie", "sid=abc\r\nX-Evil: 1"));
    try testing.expect(!b.add("Bad Name", "x"));
    try testing.expect(!b.add("", "x"));
    try checkHeaders(b.block());
    var it = HeaderIterator.init(b.block());
    try testing.expectEqualStrings("Content-Type", it.next().?.name);
    const sc = it.next().?;
    try testing.expectEqualStrings("Set-Cookie", sc.name);
    try testing.expectEqualStrings("sid=abc  X-Evil: 1", sc.value); // 줄바꿈으로 다음 헤더를 흉내 내지 못한다
    try testing.expect(it.next() == null);
    try testing.expect(b.truncated);

    // 64 개 넘게.
    var many: HeaderBuilder = .{};
    for (0..max_header_count + 5) |i| {
        var nb: [16]u8 = undefined;
        _ = many.add(try std.fmt.bufPrint(&nb, "x-h{d}", .{i}), "v");
    }
    try testing.expectEqual(@as(u8, max_header_count), many.count);
    try testing.expect(many.truncated);
    try checkHeaders(many.block());

    // 값이 8 KiB 를 넘으면 앞부분만 — 「…」 로 끝나고 합은 상한 안.
    var big: HeaderBuilder = .{};
    try testing.expect(big.add("x-big", "가" ** 4000));
    try testing.expect(big.truncated);
    try checkHeaders(big.block());
    var bi = HeaderIterator.init(big.block());
    const h = bi.next().?;
    try testing.expect(std.mem.endsWith(u8, h.value, "…"));
    try testing.expect(h.name.len + h.value.len <= max_headers_bytes);
    try testing.expect(!big.add("x-more", "y")); // 남은 자리가 없다
}

test "W9d①: checkHeaders 는 개수·길이가 어긋난 덩어리, 토큰이 아닌 이름, 제어 문자 값을 거절한다" {
    var b: HeaderBuilder = .{};
    _ = b.add("a", "1");
    _ = b.add("b", "2");
    var blk = b.block();
    blk.count = 3;
    try testing.expectError(error.InvalidNetwork, checkHeaders(blk));
    blk.count = 2;
    blk.bytes = blk.bytes[0 .. blk.bytes.len - 1];
    try testing.expectError(error.InvalidNetwork, checkHeaders(blk));
    var raw = [_]u8{ 1, ' ', 0, 1, 'x' };
    try testing.expectError(error.InvalidNetwork, checkHeaders(.{ .count = 1, .bytes = &raw }));
    var raw2 = [_]u8{ 1, 'a', 0, 1, 0x1b };
    try testing.expectError(error.ControlCharacter, checkHeaders(.{ .count = 1, .bytes = &raw2 }));
    var raw3 = [_]u8{ 1, 'a', 0, 2, 'x', '\t' };
    try checkHeaders(.{ .count = 1, .bytes = &raw3 }); // 값 안의 탭은 받는다
}

test "W9d①: 메서드는 토큰 글자 1..32, 호스트는 소문자 호스트 글자" {
    try checkMethod("GET");
    try checkMethod("M-SEARCH");
    try testing.expectError(error.InvalidNetwork, checkMethod(""));
    try testing.expectError(error.InvalidNetwork, checkMethod("GE T"));
    try testing.expectError(error.InvalidNetwork, checkMethod("x" ** 33));
    try checkHost("a.example.com");
    try checkHost("[::1]");
    try testing.expectError(error.InvalidNetwork, checkHost("A.example"));
    try testing.expectError(error.InvalidNetwork, checkHost("a/b"));
    try testing.expectError(error.InvalidNetwork, checkHost(""));
}
