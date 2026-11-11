//! 네트워크 메시지(W9d① — wire 21)의 닫힌 필드 규칙과 몸통 쓰기·읽기. encode 와 decode 가 **같은 검사 함수**(`checkBegin` 등)를
//! 지나야 한쪽만 느슨해지지 않는다(fields.zig 와 같은 규율). 헤더 덩어리는 frame 을 빌리는 바이트로 오가며(`NetHeaderBlock`) 만드는 쪽은
//! `HeaderBuilder`, 읽는 쪽은 `HeaderIterator` 를 쓴다 — sidecar 와 maru 가 같은 파일을 쓴다.
//!
//! 시험이 증명하는 것: 상한(주소 2 KiB·헤더 64 개·8 KiB·메서드 토큰), 짝이 맞지 않는 표시(주 프레임이면서 하위 프레임, 서비스 워커인데
//! 프레임), 0 번 요청, 모르는 자원 종류·결과, 덩어리 안 길이가 어긋난 헤더가 양쪽 모두에서 거절된다는 것. 브라우저 탭에서 중요한 이유 —
//! 이 글들은 페이지·서버가 고른 것이라(주소·헤더 값) 받는 쪽이 길이·모양을 믿으면 안 된다.

const array_repeat = @import("array_repeat");

const std = @import("std");
const wire = @import("wire.zig");
const message = @import("message.zig");
const fields = @import("fields.zig");
const net_block = @import("net_block.zig"); // W9d③: 막기 규칙의 패턴 — maru 와 sidecar 가 같은 함수로 본다
const net_mock_rules = @import("net_mock_rules.zig"); // W9d④: 가짜 응답의 규칙 — maru 와 sidecar 가 같은 함수로 본다

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
pub const max_host_bytes = message.max_net_host_bytes;

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
    if (host.len == 0 or host.len > max_host_bytes) return error.InvalidNetwork;
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

/// 값에 주소(들)를 싣는 헤더인가(대소문자 무시 — W9d① 적대 리뷰 4 회차 C1, 단일 출처: `net_policy.urlHeader` 가 이것을 쓴다). 사용자가 이름을 댄
/// 것은 `Location`·`Refresh`·`Content-Location`·`Link` 이고, 요청의 `Referer` 도 넣었다(작성자 — 같은 갈래).
pub fn urlValueHeader(name: []const u8) bool {
    for ([_][]const u8{ "location", "content-location", "refresh", "link", "referer" }) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return false;
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
            // 남은 자리에 「…」 을 붙일 만큼만 — 글자 경계에서. 주소를 싣는 헤더는 앞부분을 싣지 않는다(W9d① 적대 리뷰 4 회차 — 사용자 정보 안에서
            // 끊긴 앞부분 `http://user:pa…` 에는 `@` 가 없어 가리기(`net_policy.maskHeaderUserinfo`)가 사용자 정보로 알아보지 못했다. 실제 CEF:
            // 켬·끔 모두 348 바이트 조각이 나갔다 — 판정 `R9d4-cut-location-*`. 잘릴 주소를 사용자 정보째 싣지 않는 3 회차 T1 과 같은 까닭).
            const keep = room - name.len -| 3;
            shown = if (urlValueHeader(name)) "" else @import("text.zig").clampUtf8(value, keep);
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
    if (v.flags.main_frame and v.flags.subframe) return error.InvalidNetwork;
    // 앞 문서 표시는 하위 프레임의 것만(5 회차 B1 — sidecar 는 iframe 의 프레임 번호로만 가른다).
    if (v.flags.previous_document and !v.flags.subframe) return error.InvalidNetwork;
    // 서비스 워커가 대신 보낸 요청에는 CEF 의 프레임이 없다.
    if (v.flags.service_worker and (v.flags.main_frame or v.flags.subframe)) return error.InvalidNetwork;
    if (v.resource_type > message.max_net_resource_type or v.resource_type == 18) return error.InvalidNetwork;
    if (v.flags2._reserved != 0) return error.InvalidNetwork; // W9d②: 둘째 표시의 쓰지 않는 비트
    if (v.flags2.mocked and v.flags2.body_expected) return error.InvalidNetwork; // W9d④: 가짜로 고른 요청의 본문은 CDP 로 받지 않는다
    try checkMethod(v.method);
    if (v.url.len == 0) return error.InvalidNetwork;
    try checkLine(v.url, max_url_bytes);
    try checkLine(v.initiator, max_origin_bytes);
    try checkLine(v.site, max_origin_bytes);
    try checkHostField(v.host);
    try checkUrlCut(v.url, v.flags.url_truncated);
    try checkHeaders(v.headers);
}

/// 요청·홉 주소의 호스트 칸(W9d① 적대 리뷰 3 회차 T1) — 빈 글(http(s) 가 아니거나 모른다 — 덮이지 않는다)이거나 `checkHost` 를 지나는 소문자 호스트.
fn checkHostField(host: []const u8) Error!void {
    if (host.len != 0) try checkHost(host);
}

/// 잘린 주소에는 사용자 정보가 없다(W9d① 적대 리뷰 3 회차 T1 — sidecar 가 자르기 전에 뺀다). 잘린 글의 권한 부분에 `@` 가 있으면 그 글만으로는
/// 사용자 정보가 어디서 끝나는지 모른다 — 보일 때 지우지 못한다.
fn checkUrlCut(url: []const u8, truncated: bool) Error!void {
    if (!truncated) return;
    const a = authoritySpan(url) orelse return;
    if (std.mem.indexOfScalar(u8, url[a.start..a.end], '@') != null) return error.InvalidNetwork;
}

/// 주소의 권한 부분 `[start, end)`(`scheme://` 뒤 첫 `/`·`?`·`#` 까지) — 스킴(글자·숫자·`+`·`-`·`.`)이 첫 `:` 앞이고 그 뒤가 `//` 일 때만.
/// 아니면 null(`data:`·`blob:`·`about:` — 그 안의 `://` 는 권한이 아니다). 스킴 길이는 보지 않는다(GURL 은 어느 길이든 받는다 — W9d① 적대
/// 리뷰 5 회차 N1: 32 바이트에서 멈추면 긴 스킴의 사용자 정보가 남았다). sidecar 가 온 주소(UTF-16)에서 쓰는 규칙(`net_policy.authority16`)과
/// 같다 — 사용자 정보를 지우는 쪽과 빼는 쪽이 같은 곳을 본다.
pub fn authoritySpan(url: []const u8) ?struct { start: usize, end: usize } {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
    if (colon == 0) return null;
    for (url[0..colon]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return null;
    if (!std.mem.startsWith(u8, url[colon + 1 ..], "//")) return null;
    const start = colon + 3;
    const end = start + (std.mem.indexOfAny(u8, url[start..], "/?#") orelse url.len - start);
    return .{ .start = start, .end = end };
}

pub fn writeBegin(cursor: *Cursor, v: message.NetBegin) Error!void {
    try checkBegin(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU64(v.request);
    try cursor.writeByte(@bitCast(v.flags));
    try cursor.writeByte(@bitCast(v.flags2));
    try cursor.writeByte(v.resource_type);
    try cursor.writeU64(v.time_ms);
    try writeLine(cursor, v.method);
    try writeLine(cursor, v.url);
    try writeLine(cursor, v.initiator);
    try writeLine(cursor, v.site);
    try writeLine(cursor, v.host);
    try writeHeaders(cursor, v.headers);
}

pub fn readBegin(cursor: *ReadCursor) Error!message.NetBegin {
    const v: message.NetBegin = .{
        .browser = try fields.readBrowser(cursor),
        .request = try cursor.readU64(),
        .flags = @bitCast(try cursor.readByte()),
        .flags2 = @bitCast(try cursor.readByte()),
        .resource_type = try cursor.readByte(),
        .time_ms = try cursor.readU64(),
        .method = try readLine(cursor, max_method_bytes),
        .url = try readLine(cursor, max_url_bytes),
        .initiator = try readLine(cursor, max_origin_bytes),
        .site = try readLine(cursor, max_origin_bytes),
        .host = try readLine(cursor, max_host_bytes),
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
    try checkHostField(v.host);
    try checkUrlCut(v.url, v.flags.url_truncated);
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
    try writeLine(cursor, v.host);
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
        .host = try readLine(cursor, max_host_bytes),
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
    // W9d③: 막힘·적용 안 됨은 하나만, 둘 중 하나일 때만 규칙 번호, 막힌 요청은 실패로 끝났다.
    // W9d④: 가짜(`mocked`·`mock_redirected`)도 규칙 번호를 싣는다 — 막기 표시와 함께 오지 않는다(막기가 이긴다), 적용 안 됨과도.
    if (v.flags._reserved != 0) return error.InvalidNetwork;
    const mock = v.flags.mocked or v.flags.mock_redirected;
    if (@as(u2, @intFromBool(v.flags.blocked)) + @intFromBool(v.flags.sw_not_applied) + @intFromBool(mock) > 1) return error.InvalidNetwork;
    if ((v.flags.blocked or v.flags.sw_not_applied or mock) != (v.rule_id != 0)) return error.InvalidNetwork;
    if (v.flags.blocked and v.outcome != .failed) return error.InvalidNetwork;
    // 본문 번호는 가짜가 마지막 응답을 준 끝에만(가짜 리다이렉트만이면 본문은 진짜의 것이다).
    if (!v.flags.mocked and v.mock_body_id != 0) return error.InvalidNetwork;
}

pub fn writeEnd(cursor: *Cursor, v: message.NetEnd) Error!void {
    try checkEnd(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU64(v.request);
    try cursor.writeByte(@backingInt(v.outcome));
    try cursor.writeU32(@bitCast(v.error_code));
    try cursor.writeU64(v.received);
    try cursor.writeU64(v.time_ms);
    try cursor.writeByte(@bitCast(v.flags));
    try cursor.writeU32(v.rule_id);
    if (v.flags.mocked) try cursor.writeU32(v.mock_body_id);
}

pub fn readEnd(cursor: *ReadCursor) Error!message.NetEnd {
    var v: message.NetEnd = .{
        .browser = try fields.readBrowser(cursor),
        .request = try cursor.readU64(),
        .outcome = std.enums.fromInt(message.NetOutcome, try cursor.readByte()) orelse return error.InvalidNetwork,
        .error_code = @bitCast(try cursor.readU32()),
        .received = try cursor.readU64(),
        .time_ms = try cursor.readU64(),
        .flags = @bitCast(try cursor.readByte()),
        .rule_id = try cursor.readU32(),
    };
    if (v.flags.mocked) v.mock_body_id = try cursor.readU32();
    try checkEnd(v);
    return v;
}

pub fn writeDropped(cursor: *Cursor, v: message.NetDropped) Error!void {
    if (v.count == 0 and v.sw_inflight_cap == 0) return error.InvalidNetwork;
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.count);
    try cursor.writeU32(v.sw_inflight_cap);
}

pub fn readDropped(cursor: *ReadCursor) Error!message.NetDropped {
    const v: message.NetDropped = .{ .browser = try fields.readBrowser(cursor), .count = try cursor.readU32(), .sw_inflight_cap = try cursor.readU32() };
    if (v.count == 0 and v.sw_inflight_cap == 0) return error.InvalidNetwork;
    return v;
}

// ── net_watch ─────────────────────────────────────────────────────────────────────────────────────────────

pub fn checkWatch(v: message.NetWatch) Error!void {
    if (v.host_count > max_watch_hosts) return error.InvalidNetwork;
    if (!v.on and (v.full or v.any_host or v.host_count != 0)) return error.InvalidNetwork;
    for (v.hosts[0..v.host_count]) |h| try checkHost(h);
}

pub fn writeWatch(cursor: *Cursor, v: message.NetWatch) Error!void {
    try checkWatch(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeByte(@intFromBool(v.on));
    try cursor.writeByte(@intFromBool(v.full));
    try cursor.writeByte(@intFromBool(v.any_host));
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
        .any_host = try fields.readBool(cursor),
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

// ── 응답 본문(W9d②) ───────────────────────────────────────────────────────────────────────────────────────

/// `net_record` — 켜면 세션 번호가 0 이 아니고, 끄면 0.
pub fn checkRecord(v: message.NetRecord) Error!void {
    if (v.on != (v.session != 0)) return error.InvalidNetwork;
}

pub fn writeRecord(cursor: *Cursor, v: message.NetRecord) Error!void {
    try checkRecord(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeByte(@intFromBool(v.on));
    try cursor.writeU32(v.session);
}

pub fn readRecord(cursor: *ReadCursor) Error!message.NetRecord {
    const v: message.NetRecord = .{ .browser = try fields.readBrowser(cursor), .on = try fields.readBool(cursor), .session = try cursor.readU32() };
    try checkRecord(v);
    return v;
}

/// `net_body_data` — 세션·요청 번호 0 아님, 비지 않은 조각이 상한 안, 조각의 끝이 본문 상한 안.
pub fn checkBodyData(v: message.NetBodyData) Error!void {
    if (v.session == 0) return error.InvalidNetwork;
    try checkRequest(v.request);
    if (v.bytes.len == 0 or v.bytes.len > message.net_body_chunk_bytes) return error.InvalidNetwork;
    if (@as(u64, v.offset) + v.bytes.len > message.max_net_body_bytes) return error.InvalidNetwork;
}

pub fn writeBodyData(cursor: *Cursor, v: message.NetBodyData) Error!void {
    try checkBodyData(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.session);
    try cursor.writeU64(v.request);
    try cursor.writeU32(v.offset);
    try cursor.writeU16(@intCast(v.bytes.len));
    try cursor.writeBytes(v.bytes);
}

pub fn readBodyData(cursor: *ReadCursor) Error!message.NetBodyData {
    const browser = try fields.readBrowser(cursor);
    const session = try cursor.readU32();
    const request = try cursor.readU64();
    const offset = try cursor.readU32();
    const len = try cursor.readU16();
    if (len > message.net_body_chunk_bytes) return error.InvalidNetwork;
    const v: message.NetBodyData = .{ .browser = browser, .session = session, .request = request, .offset = offset, .bytes = try cursor.readBytes(len) };
    try checkBodyData(v);
    return v;
}

/// `net_body_end` — 세션·요청 번호 0 아님, 쓰지 않는 비트 없음, 크기는 잡았을 때만(본문 상한 안), 글 표시(되돌림·Chromium 이 푼 그대로)는 잡은 글에만
/// 하나까지, 바이너리 표시는 잡았을 때만.
pub fn checkBodyEnd(v: message.NetBodyEnd) Error!void {
    if (v.session == 0) return error.InvalidNetwork;
    try checkRequest(v.request);
    if (v.flags._reserved != 0) return error.InvalidNetwork;
    if (v.size > message.max_net_body_bytes) return error.InvalidNetwork;
    if (v.state != .captured and (v.size != 0 or v.flags.binary or v.flags.redecoded or v.flags.chromium_decoded)) return error.InvalidNetwork;
    if (v.flags.redecoded and v.flags.chromium_decoded) return error.InvalidNetwork;
    if (v.flags.binary and (v.flags.redecoded or v.flags.chromium_decoded)) return error.InvalidNetwork;
    if (v.decoded > std.math.maxInt(i64)) return error.InvalidNetwork;
}

pub fn writeBodyEnd(cursor: *Cursor, v: message.NetBodyEnd) Error!void {
    try checkBodyEnd(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.session);
    try cursor.writeU64(v.request);
    try cursor.writeByte(@backingInt(v.state));
    try cursor.writeByte(@bitCast(v.flags));
    try cursor.writeU32(v.size);
    try cursor.writeU64(v.decoded);
}

pub fn readBodyEnd(cursor: *ReadCursor) Error!message.NetBodyEnd {
    const v: message.NetBodyEnd = .{
        .browser = try fields.readBrowser(cursor),
        .session = try cursor.readU32(),
        .request = try cursor.readU64(),
        .state = std.enums.fromInt(message.NetBodyState, try cursor.readByte()) orelse return error.InvalidNetwork,
        .flags = @bitCast(try cursor.readByte()),
        .size = try cursor.readU32(),
        .decoded = try cursor.readU64(),
    };
    try checkBodyEnd(v);
    return v;
}

/// `net_record_state` — 켜짐·멈춤·켜지 못함은 세션이 0 이 아니다(꺼짐은 어느 것이든).
pub fn checkRecordState(v: message.NetRecordState) Error!void {
    if (v.status != .off and v.session == 0) return error.InvalidNetwork;
}

pub fn writeRecordState(cursor: *Cursor, v: message.NetRecordState) Error!void {
    try checkRecordState(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.session);
    try cursor.writeByte(@backingInt(v.status));
}

pub fn readRecordState(cursor: *ReadCursor) Error!message.NetRecordState {
    const v: message.NetRecordState = .{
        .browser = try fields.readBrowser(cursor),
        .session = try cursor.readU32(),
        .status = std.enums.fromInt(message.NetRecordStatus, try cursor.readByte()) orelse return error.InvalidNetwork,
    };
    try checkRecordState(v);
    return v;
}

// ── 요청 막기(W9d③) ────────────────────────────────────────────────────────────────────────────────────────

/// `net_block` — 규칙 수 상한, 번호 0·중복 없음, 종류 마스크는 아는 종류만(서비스 워커·18 빼고), 사이트는 호스트, 패턴은 풀리고 정규형 그대로
/// (`net_block.parse` — maru 와 sidecar 가 같은 함수), 엄격 사이트는 빈 글이거나 호스트.
pub fn checkBlock(v: message.NetBlock) Error!void {
    if (v.count > message.max_net_block_rules) return error.InvalidNetwork;
    if (v.strict_site.len != 0) try checkHost(v.strict_site);
    for (v.rules[0..v.count], 0..) |r, i| {
        if (r.id == 0) return error.InvalidNetwork;
        for (v.rules[0..i]) |q| if (q.id == r.id) return error.InvalidNetwork;
        if (r.types & ~net_block.types_mask_valid != 0) return error.InvalidNetwork;
        try checkHost(r.site);
        if (r.pattern.len == 0 or r.pattern.len > message.max_net_block_pattern_bytes) return error.InvalidNetwork;
        switch (net_block.parse(r.pattern)) {
            .ok => |p| if (!std.mem.eql(u8, p.norm(), r.pattern)) return error.InvalidNetwork,
            .err => return error.InvalidNetwork,
        }
    }
}

pub fn writeBlock(cursor: *Cursor, v: message.NetBlock) Error!void {
    try checkBlock(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.generation);
    try cursor.writeByte(@intCast(v.strict_site.len));
    try cursor.writeBytes(v.strict_site);
    try cursor.writeByte(v.count);
    for (v.rules[0..v.count]) |r| {
        try cursor.writeU32(r.id);
        try cursor.writeU32(r.types);
        try cursor.writeByte(@intCast(r.site.len));
        try cursor.writeBytes(r.site);
        try writeLine(cursor, r.pattern);
    }
}

pub fn readBlock(cursor: *ReadCursor) Error!message.NetBlock {
    var v: message.NetBlock = .{ .browser = try fields.readBrowser(cursor), .generation = try cursor.readU32() };
    const strict_len = try cursor.readByte();
    v.strict_site = try cursor.readBytes(strict_len);
    v.count = try cursor.readByte();
    if (v.count > message.max_net_block_rules) return error.InvalidNetwork;
    for (v.rules[0..v.count]) |*r| {
        r.id = try cursor.readU32();
        r.types = try cursor.readU32();
        const site_len = try cursor.readByte();
        r.site = try cursor.readBytes(site_len);
        r.pattern = try readLine(cursor, message.max_net_block_pattern_bytes);
    }
    try checkBlock(v);
    return v;
}

pub fn checkBlockState(v: message.NetBlockState) Error!void {
    if (!v.ok and v.strict != .off) return error.InvalidNetwork; // 적용하지 못한 세대에는 엄격 모드도 없다
}

pub fn writeBlockState(cursor: *Cursor, v: message.NetBlockState) Error!void {
    try checkBlockState(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.generation);
    try cursor.writeByte(@intFromBool(v.ok));
    try cursor.writeByte(@backingInt(v.strict));
}

pub fn readBlockState(cursor: *ReadCursor) Error!message.NetBlockState {
    const v: message.NetBlockState = .{
        .browser = try fields.readBrowser(cursor),
        .generation = try cursor.readU32(),
        .ok = try fields.readBool(cursor),
        .strict = std.enums.fromInt(message.NetStrictState, try cursor.readByte()) orelse return error.InvalidNetwork,
    };
    try checkBlockState(v);
    return v;
}

/// `net_block_hits` — 항목 수 상한, 번호 0·중복 없음, 빈 차이(모두 0 이고 표시도 없음)는 보내지 않는다.
pub fn checkBlockHits(v: message.NetBlockHits) Error!void {
    if (v.count > message.max_net_block_rules) return error.InvalidNetwork;
    for (v.entries[0..v.count], 0..) |e, i| {
        if (e.rule_id == 0) return error.InvalidNetwork;
        for (v.entries[0..i]) |q| if (q.rule_id == e.rule_id) return error.InvalidNetwork;
        if (e.hits == 0 and e.sw_hits == 0 and e.sw_not_applied == 0) return error.InvalidNetwork;
    }
    if (v.count == 0 and v.unrecorded == 0 and v.skipped_unknown_page == 0 and v.strict_redirect_missed == 0 and v.strict_redirect_bypassed == 0 and !v.sw_shared_with_unruled_tab) return error.InvalidNetwork;
}

pub fn writeBlockHits(cursor: *Cursor, v: message.NetBlockHits) Error!void {
    try checkBlockHits(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.generation);
    try cursor.writeU32(v.unrecorded);
    try cursor.writeU32(v.skipped_unknown_page);
    try cursor.writeU32(v.strict_redirect_missed);
    try cursor.writeU32(v.strict_redirect_bypassed);
    try cursor.writeByte(@intFromBool(v.sw_shared_with_unruled_tab));
    try cursor.writeByte(v.count);
    for (v.entries[0..v.count]) |e| {
        try cursor.writeU32(e.rule_id);
        try cursor.writeU32(e.hits);
        try cursor.writeU32(e.sw_hits);
        try cursor.writeU32(e.sw_not_applied);
    }
}

pub fn readBlockHits(cursor: *ReadCursor) Error!message.NetBlockHits {
    var v: message.NetBlockHits = .{
        .browser = try fields.readBrowser(cursor),
        .generation = try cursor.readU32(),
        .unrecorded = try cursor.readU32(),
        .skipped_unknown_page = try cursor.readU32(),
        .strict_redirect_missed = try cursor.readU32(),
        .strict_redirect_bypassed = try cursor.readU32(),
        .sw_shared_with_unruled_tab = try fields.readBool(cursor),
        .count = try cursor.readByte(),
    };
    if (v.count > message.max_net_block_rules) return error.InvalidNetwork;
    for (v.entries[0..v.count]) |*e| e.* = .{ .rule_id = try cursor.readU32(), .hits = try cursor.readU32(), .sw_hits = try cursor.readU32(), .sw_not_applied = try cursor.readU32() };
    try checkBlockHits(v);
    return v;
}

/// `error_page` — 오류 번호는 음수(ERR_ABORTED 는 sidecar 가 보내지 않지만 받는 쪽은 가르지 않는다).
pub fn checkErrorPage(v: message.ErrorPage) Error!void {
    if (v.error_code >= 0) return error.InvalidNetwork;
}

pub fn writeErrorPage(cursor: *Cursor, v: message.ErrorPage) Error!void {
    try checkErrorPage(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(@bitCast(v.error_code));
    try cursor.writeU32(v.blocked_rule);
}

pub fn readErrorPage(cursor: *ReadCursor) Error!message.ErrorPage {
    const v: message.ErrorPage = .{ .browser = try fields.readBrowser(cursor), .error_code = @bitCast(try cursor.readU32()), .blocked_rule = try cursor.readU32() };
    try checkErrorPage(v);
    return v;
}

// ── 가짜 응답(W9d④) ───────────────────────────────────────────────────────────────────────────────────────

/// 가짜 규칙의 머리 덩어리 상한(머리 32 개·8 KiB 에 머리마다 길이 칸 셋).
pub const max_mock_header_block_bytes: usize = message.max_net_mock_headers_bytes + message.max_net_mock_headers * 3;

/// 가짜 규칙 머리 덩어리 — 모양(`checkHeaders`)과 가짜 규칙(허용 목록·값 글자·32 개·8 KiB, `Location` 은 따로 칸 — 여기에는 없다).
pub fn checkMockHeaders(block: message.NetHeaderBlock) Error!void {
    if (block.count > message.max_net_mock_headers or block.bytes.len > max_mock_header_block_bytes) return error.InvalidNetwork;
    try checkHeaders(block);
    var list: [message.max_net_mock_headers]net_mock_rules.Header = undefined;
    var n: usize = 0;
    var it = HeaderIterator.init(block);
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "location")) return error.InvalidNetwork;
        list[n] = .{ .name = h.name, .value = h.value };
        n += 1;
    }
    if (net_mock_rules.checkHeaders(list[0..n], 200) != null) return error.InvalidNetwork;
}

/// `net_mock_rule` — 번호 0 아님·차례·종류(서비스 워커·preload 없음)·메서드·표시·사이트·실행 출처(표시와 짝)·정규형 패턴·상태·본문 번호와 길이
/// (짝, 상한, 본문 금지 상태)·content_type 문법과 그려지는 종류(문서로 맞을 수 있는 규칙)·Location(3xx 만, 리다이렉트는 꼭)·머리.
pub fn checkMockRule(v: message.NetMockRule) Error!void {
    if (v.id == 0 or v.index >= message.max_net_mock_rules) return error.InvalidNetwork;
    if (v.types & ~net_mock_rules.types_mask_valid != 0) return error.InvalidNetwork;
    if (v.methods & ~net_mock_rules.methods_mask_valid != 0) return error.InvalidNetwork;
    if (v.flags._reserved != 0) return error.InvalidNetwork;
    try checkHost(v.site);
    if (v.flags.exec_site_bound != (v.exec_site.len != 0)) return error.InvalidNetwork;
    if (v.exec_site.len != 0) try checkHost(v.exec_site);
    if (v.pattern.len == 0 or v.pattern.len > message.max_net_block_pattern_bytes) return error.InvalidNetwork;
    switch (net_block.parse(v.pattern)) {
        .ok => |p| if (!std.mem.eql(u8, p.norm(), v.pattern)) return error.InvalidNetwork,
        .err => return error.InvalidNetwork,
    }
    if (net_mock_rules.checkStatus(v.status) != null) return error.InvalidNetwork;
    if ((v.body_id == 0) != (v.body_len == 0)) return error.InvalidNetwork;
    if (v.body_len > message.max_net_mock_body_bytes) return error.InvalidNetwork;
    if (net_mock_rules.bodyForbidden(v.status) and v.body_len != 0) return error.InvalidNetwork;
    const essence = net_mock_rules.parseContentType(v.content_type) orelse return error.InvalidNetwork;
    if (net_mock_rules.documentCapable(v.types) and !net_mock_rules.renderable(v.content_type[0..essence])) return error.InvalidNetwork;
    if (v.location.len != 0) {
        if (v.status < 300 or v.status >= 400) return error.InvalidNetwork;
        if (net_mock_rules.checkLocation(v.location) != null) return error.InvalidNetwork;
    } else if (net_mock_rules.locationRequired(v.status)) return error.InvalidNetwork;
    try checkMockHeaders(v.headers);
}

pub fn writeMockRule(cursor: *Cursor, v: message.NetMockRule) Error!void {
    try checkMockRule(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.generation);
    try cursor.writeByte(v.index);
    try cursor.writeU32(v.id);
    try cursor.writeU32(v.types);
    try cursor.writeByte(v.methods);
    try cursor.writeByte(@bitCast(v.flags));
    try cursor.writeByte(@intCast(v.site.len));
    try cursor.writeBytes(v.site);
    try cursor.writeByte(@intCast(v.exec_site.len));
    try cursor.writeBytes(v.exec_site);
    try writeLine(cursor, v.pattern);
    try cursor.writeU16(v.status);
    try cursor.writeU32(v.body_id);
    try cursor.writeU32(v.body_len);
    try writeLine(cursor, v.content_type);
    try writeLine(cursor, v.location);
    try writeHeaders(cursor, v.headers);
}

pub fn readMockRule(cursor: *ReadCursor) Error!message.NetMockRule {
    var v: message.NetMockRule = .{ .browser = try fields.readBrowser(cursor), .generation = try cursor.readU32() };
    v.index = try cursor.readByte();
    v.id = try cursor.readU32();
    v.types = try cursor.readU32();
    v.methods = try cursor.readByte();
    v.flags = @bitCast(try cursor.readByte());
    v.site = try cursor.readBytes(try cursor.readByte());
    v.exec_site = try cursor.readBytes(try cursor.readByte());
    v.pattern = try readLine(cursor, message.max_net_block_pattern_bytes);
    v.status = try cursor.readU16();
    v.body_id = try cursor.readU32();
    v.body_len = try cursor.readU32();
    v.content_type = try readLine(cursor, message.max_net_mock_content_type_bytes);
    v.location = try readLine(cursor, message.max_net_mock_location_bytes);
    v.headers = try readHeaders(cursor);
    try checkMockRule(v);
    return v;
}

/// `net_mock_body` — 번호 0 아님, 비지 않은 조각(16 KiB 안), `offset + len ≤ total ≤ 512 KiB`.
pub fn checkMockBody(v: message.NetMockBody) Error!void {
    if (v.body_id == 0 or v.total == 0 or v.total > message.max_net_mock_body_bytes) return error.InvalidNetwork;
    if (v.bytes.len == 0 or v.bytes.len > message.net_mock_chunk_bytes) return error.InvalidNetwork;
    if (@as(u64, v.offset) + v.bytes.len > v.total) return error.InvalidNetwork;
}

pub fn writeMockBody(cursor: *Cursor, v: message.NetMockBody) Error!void {
    try checkMockBody(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.body_id);
    try cursor.writeU32(v.offset);
    try cursor.writeU32(v.total);
    try writeLine(cursor, v.bytes);
}

pub fn readMockBody(cursor: *ReadCursor) Error!message.NetMockBody {
    const v: message.NetMockBody = .{
        .browser = try fields.readBrowser(cursor),
        .body_id = try cursor.readU32(),
        .offset = try cursor.readU32(),
        .total = try cursor.readU32(),
        .bytes = try readLine(cursor, message.net_mock_chunk_bytes),
    };
    try checkMockBody(v);
    return v;
}

pub fn checkMockCommit(v: message.NetMockCommit) Error!void {
    if (v.count > message.max_net_mock_rules) return error.InvalidNetwork;
    if (v.strict_site.len != 0) try checkHost(v.strict_site);
}

pub fn writeMockCommit(cursor: *Cursor, v: message.NetMockCommit) Error!void {
    try checkMockCommit(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.generation);
    try cursor.writeByte(v.count);
    try cursor.writeByte(@intCast(v.strict_site.len));
    try cursor.writeBytes(v.strict_site);
}

pub fn readMockCommit(cursor: *ReadCursor) Error!message.NetMockCommit {
    var v: message.NetMockCommit = .{ .browser = try fields.readBrowser(cursor), .generation = try cursor.readU32(), .count = try cursor.readByte() };
    v.strict_site = try cursor.readBytes(try cursor.readByte());
    try checkMockCommit(v);
    return v;
}

pub fn checkMockState(v: message.NetMockState) Error!void {
    if (!v.ok and v.strict != .off) return error.InvalidNetwork; // 적용하지 못한 세대에는 엄격 모드도 없다
}

pub fn writeMockState(cursor: *Cursor, v: message.NetMockState) Error!void {
    try checkMockState(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.generation);
    try cursor.writeByte(@intFromBool(v.ok));
    try cursor.writeByte(@backingInt(v.strict));
}

pub fn readMockState(cursor: *ReadCursor) Error!message.NetMockState {
    const v: message.NetMockState = .{
        .browser = try fields.readBrowser(cursor),
        .generation = try cursor.readU32(),
        .ok = try fields.readBool(cursor),
        .strict = std.enums.fromInt(message.NetStrictState, try cursor.readByte()) orelse return error.InvalidNetwork,
    };
    try checkMockState(v);
    return v;
}

pub fn checkMockAck(v: message.NetMockAck) Error!void {
    if (v.body_id == 0 or v.received == 0 or v.received > message.max_net_mock_body_bytes) return error.InvalidNetwork;
}

pub fn writeMockAck(cursor: *Cursor, v: message.NetMockAck) Error!void {
    try checkMockAck(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.body_id);
    try cursor.writeU32(v.received);
}

pub fn readMockAck(cursor: *ReadCursor) Error!message.NetMockAck {
    const v: message.NetMockAck = .{ .browser = try fields.readBrowser(cursor), .body_id = try cursor.readU32(), .received = try cursor.readU32() };
    try checkMockAck(v);
    return v;
}

/// `net_mock_hits` — 항목 수 상한, 번호 0·중복 없음, 빈 항목·빈 차이는 보내지 않는다.
pub fn checkMockHits(v: message.NetMockHits) Error!void {
    if (v.count > message.max_net_mock_rules) return error.InvalidNetwork;
    for (v.entries[0..v.count], 0..) |e, i| {
        if (e.rule_id == 0) return error.InvalidNetwork;
        for (v.entries[0..i]) |q| if (q.rule_id == e.rule_id) return error.InvalidNetwork;
        if (e.hits == 0 and e.sw_not_mocked == 0 and e.frame_not_mocked == 0) return error.InvalidNetwork;
    }
    if (v.count == 0 and v.unrecorded == 0 and v.busy == 0 and v.skipped_unknown_page == 0 and !v.page_controlled) return error.InvalidNetwork;
}

pub fn writeMockHits(cursor: *Cursor, v: message.NetMockHits) Error!void {
    try checkMockHits(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.unrecorded);
    try cursor.writeU32(v.busy);
    try cursor.writeU32(v.skipped_unknown_page);
    try cursor.writeByte(@intFromBool(v.page_controlled));
    try cursor.writeByte(v.count);
    for (v.entries[0..v.count]) |e| {
        try cursor.writeU32(e.rule_id);
        try cursor.writeU32(e.hits);
        try cursor.writeU32(e.sw_not_mocked);
        try cursor.writeU32(e.frame_not_mocked);
    }
}

pub fn readMockHits(cursor: *ReadCursor) Error!message.NetMockHits {
    var v: message.NetMockHits = .{
        .browser = try fields.readBrowser(cursor),
        .unrecorded = try cursor.readU32(),
        .busy = try cursor.readU32(),
        .skipped_unknown_page = try cursor.readU32(),
        .page_controlled = try fields.readBool(cursor),
        .count = try cursor.readByte(),
    };
    if (v.count > message.max_net_mock_rules) return error.InvalidNetwork;
    for (v.entries[0..v.count]) |*e| e.* = .{ .rule_id = try cursor.readU32(), .hits = try cursor.readU32(), .sw_not_mocked = try cursor.readU32(), .frame_not_mocked = try cursor.readU32() };
    try checkMockHits(v);
    return v;
}

// 가장 큰 가짜 규칙 frame(사이트·실행 사이트·패턴·content_type·Location·머리 덩어리 상한)이 frame 상한 안에 든다(계획 §9 — 약 11 KiB).
// 가짜 본문 창(256 KiB)과 DevTools 인자의 최악(호출 8 개 × 64 KiB — 조각 머리까지 넉넉히 640 KiB)과 작은 frame 여유가 sidecar 의 명령 상자
// (1 MiB) 안에 든다(실측 M28 — 넘치면 관이 닫힌다).
comptime {
    const rule = wire.prefix_len + wire.common_len + 8 + 4 + 1 + 4 + 4 + 1 + 1 + 2 * (1 + max_host_bytes) + (2 + message.max_net_block_pattern_bytes) + 2 + 4 + 4 +
        (2 + message.max_net_mock_content_type_bytes) + (2 + message.max_net_mock_location_bytes) + 3 + max_mock_header_block_bytes;
    std.debug.assert(rule <= wire.max_frame_bytes);
    const body = wire.prefix_len + wire.common_len + 8 + 4 + 4 + 4 + 2 + message.net_mock_chunk_bytes;
    std.debug.assert(body <= wire.max_frame_bytes);
    std.debug.assert(message.net_mock_chunk_bytes <= std.math.maxInt(u16));
    std.debug.assert(max_mock_header_block_bytes <= std.math.maxInt(u16));
    std.debug.assert(message.max_net_mock_rules == net_mock_rules.max_rules);
    std.debug.assert(message.max_net_mock_body_bytes == net_mock_rules.max_body_bytes);
    std.debug.assert(message.net_mock_chunk_bytes == net_mock_rules.body_chunk_bytes);
    std.debug.assert(message.max_net_mock_headers == net_mock_rules.max_headers);
    std.debug.assert(message.max_net_mock_headers_bytes == net_mock_rules.max_headers_bytes);
    std.debug.assert(message.max_net_mock_location_bytes == net_mock_rules.max_location_bytes);
    std.debug.assert(message.max_net_mock_content_type_bytes == net_mock_rules.max_content_type_bytes);
    // 창의 조각마다 frame 머리가 붙는다 — 창(본문 바이트) + 조각 수 × 머리.
    const window_frames = net_mock_rules.window_bytes + (net_mock_rules.window_bytes / message.net_mock_chunk_bytes + 1) * (body - message.net_mock_chunk_bytes);
    const devtools_worst = 640 * 1024;
    std.debug.assert(message.max_devtools_calls * message.max_devtools_params_bytes <= devtools_worst);
    std.debug.assert(devtools_worst + window_frames + 64 * 1024 <= message.sidecar_inbox_bytes);
}

// 가장 큰 막기 frame(규칙 32 개 — 사이트·패턴 상한)이 frame 상한 안에 든다(계획 §8 — 약 25.2 KiB).
comptime {
    const rule = 4 + 4 + (1 + max_host_bytes) + (2 + message.max_net_block_pattern_bytes);
    const block = wire.prefix_len + wire.common_len + 8 + 4 + (1 + max_host_bytes) + 1 + message.max_net_block_rules * rule;
    std.debug.assert(block <= wire.max_frame_bytes);
    std.debug.assert(message.max_net_block_rules == net_block.max_rules);
    std.debug.assert(message.max_net_block_pattern_bytes == net_block.max_pattern_bytes);
}

// 가장 큰 본문 조각 frame 도 frame 상한 안에 든다.
comptime {
    const data = wire.prefix_len + wire.common_len + 8 + 4 + 8 + 4 + 2 + message.net_body_chunk_bytes;
    std.debug.assert(data <= wire.max_frame_bytes);
    std.debug.assert(message.net_body_chunk_bytes <= std.math.maxInt(u16));
}

// 가장 큰 네트워크 frame(net_begin: 머리 + 고정 칸 + 글 넷의 상한 + 헤더 덩어리 상한)이 frame 상한 안에 든다.
comptime {
    const begin = wire.prefix_len + wire.common_len + 8 + 8 + 1 + 1 + 1 + 8 + (2 + max_method_bytes) + (2 + max_url_bytes) + 2 * (2 + max_origin_bytes) + (2 + max_host_bytes) + 3 + max_header_block_bytes;
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
    try testing.expect(big.add("x-big", array_repeat.repeat("가", 4000)));
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
    try testing.expectError(error.InvalidNetwork, checkMethod(array_repeat.repeat("x", 33)));
    try checkHost("a.example.com");
    try checkHost("[::1]");
    try testing.expectError(error.InvalidNetwork, checkHost("A.example"));
    try testing.expectError(error.InvalidNetwork, checkHost("a/b"));
    try testing.expectError(error.InvalidNetwork, checkHost(""));
}
