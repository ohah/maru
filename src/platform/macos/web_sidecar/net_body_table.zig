//! 응답 본문 기록의 표(W9d② — docs/plans/web-osr-backend.md 「W9d② 결정」). CEF 를 모른다 — 시각·번호·CDP 이벤트의 값은 호출자
//! (`net_body.zig`)가 준다. 잠금도 없다 — UI 스레드 하나만 쓴다(CEF 의 DevTools 관찰자 콜백과 `network.zig` 의 보내는 task 가 둘 다 UI 스레드).
//!
//! 왜 맞추기가 필요한가: 본문은 CDP(`Network.getResponseBody`)로만 받는데, maru 의 네트워크 기록은 CEF 자원 요청 처리기의 요청 번호로 적는다.
//! 둘 사이에 번호의 관계가 없다(W9d②-0 J1 실측 — CDP 는 `<렌더러 pid>.<번호>`, CEF 는 프로세스 전체의 번호). 그래서 같은 요청을
//! (조각을 뗀 온 주소, 메서드, 서비스 워커 갈래)의 열쇠와 시각·차례로 맞춘다(J1·J2 — 실제 사이트 14 곳 두 번에서 짝지은 요청의 상태가 100 %
//! 같았다):
//!   - 후보: 같은 열쇠의 아직 짝이 없는 CEF 시작 중 IO 시각이 CDP 시작 `[ts − 5 ms, ts + 2 s]` 안.
//!   - 차례: 같은 열쇠의 다른 CDP 요청 중 먼저 시작해 아직 열린 것의 수 k — 후보 중 k 번째로 오래된 것(같은 주소의 동시 요청 2250/2250 이 시작
//!     차례 그대로였다).
//!   - CDP 의 `loadingFinished` 가 CEF 의 시작보다 먼저 올 수 있다(10 ms 묶음 — 빠른 로컬 요청은 450/450) — 그때는 잠시(`cef_grace_us`) 기다린다.
//!   - 모호함: 창 안의 다른 후보가 보이는 규칙(프레임·첫 사이트·initiator)이 다르거나, 그 탭이 같은 주소의 요청을 문에서 넘긴 창 안이면
//!     짝을 지어도 본문을 붙이지 않는다(`ambiguous` — 넘긴 요청의 쌍둥이 자리에 다른 요청이 들어온다, J2: 넘김 창 안에서 4–6 개가 틀렸다).
//! 본문 상태(`NetBodyState`)는 CEF 시작마다 **꼭 하나**다(`body_expected` 로 알린 요청 — 짝이 없으면 `unmatched`, 기록을 끄면
//! `recording_stopped`, 렌더러가 죽으면 `detached`, 같은 번호로 다시 시작하면 앞 시도는 `restarted` — 그 끝은 새 시작보다 먼저).
//! 상한: 풀어 낸 크기(`dataReceived` 의 합 — J4: 이것이 실제 크기와 꼭 같았다)가 1 MiB 를 넘으면 받지 않는다(CDP 의 자원 상한은 스크립트·스타일에 듣지 않았다 — 11 MB 가 왔다), 동시 2/탭·8 전체, 초당 20 개·4 MiB/탭·8 MiB 전체.
//! 다음 문서로 옮기면 본문이 사라지므로(J4) 기다리는 것은 잠시뿐이고(`waiting_expiry_us`) 넘으면 `busy` 다.
//!
//! 시험이 증명하는 것: 맞추기(두 도착 차례·창·같은 주소의 차례·문 넘김과 보이는 규칙이 다른 후보의 모호함·서비스 워커 갈래·조각 떼기),
//! 상한과 판정(넘침·글 아님·빈 본문·끊김·실패), 동시·초당 상한과 기다림의 만료, 세대(끈 뒤 늦게 온 결과는 버린다), 시작마다 끝은 꼭 하나,
//! MIME 가르기, 결과 풀기(JSON 글·base64·잘못된 UTF-8·windows-1252 되돌리기).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const msg = protocol.message;
const BrowserId = msg.BrowserId;
const State = msg.NetBodyState;
const Flags = msg.NetBodyFlags;

pub const max_tabs = @import("registry.zig").capacity;
/// CDP 시작보다 CEF 시작이 이만큼 앞이어도 후보다(J1: CDP 가 늘 0.09–6.3 ms 먼저였다 — 거꾸로 온 것도 받는다).
pub const window_before_us: i64 = 5_000;
/// CDP 시작 뒤 이만큼까지의 CEF 시작이 후보다(J1·실제 사이트: 짝의 최대 간격 1.66 s).
pub const window_after_us: i64 = 2_000_000;
/// CDP 끝 뒤 CEF 시작을 기다리는 시간(CEF 기록은 10 ms 묶음으로 오고 p50 7 ms 늦다 — 넉넉히).
pub const cef_grace_us: i64 = 250_000;
/// 짝이 없는 CEF 요청이 끝난 뒤 `unmatched` 로 정하기까지(그 뒤의 CDP 끝이 아직 짝을 찾을 수 있게).
pub const unclaimed_expiry_us: i64 = 3_000_000;
/// 자리가 날 때까지 기다리는 본문의 시한 — 다음 문서로 옮기면 본문이 사라진다(J4).
pub const waiting_expiry_us: i64 = 3_000_000;
pub const max_inflight_per_tab: usize = 2;
pub const max_inflight: usize = 8;
pub const max_waiting_per_tab: usize = 32;
/// 탭마다 쥐는 CEF 후보·CDP 요청 수 상한(넘으면 가장 오래된 것부터 놓는다 — 후보는 `busy` 로 끝낸다).
pub const max_candidates: usize = 4096;
pub const max_cdp: usize = 4096;
/// 초당 본문 수·바이트(탭), 바이트(전체).
pub const tab_bodies_per_s: f64 = 20;
pub const tab_bytes_per_s: f64 = 4 * 1024 * 1024;
pub const global_bytes_per_s: f64 = 8 * 1024 * 1024;
/// 쏟아짐 밸브 — 이벤트가 초당 이만큼을 연달아 이 초만큼 넘으면 기록을 멈춘다(J7: 쏟아질 때 Chromium 의 직렬화가 CPU 를 먹는다).
pub const flood_events_per_s: u32 = 5000;
pub const flood_seconds: u8 = 2;
/// 탭마다 기억하는 문 넘김 표지 수(넘치면 그 창 전체를 모호함으로).
pub const max_drop_marks: usize = 128;
/// `getResponseBody` 번호 대역 — 다른 DevTools 사용처와 겹치지 않는다(J13: 권한 0 부터·알림 20000 부터·`devtools_table` [1<<29, 1<<30)·미디어 메뉴
/// [1<<30, 2^31)).
pub const id_base: i32 = 1 << 28;
pub const id_end: i32 = 1 << 29;
pub const max_rid_bytes: usize = 64;

// ── 열쇠 ──────────────────────────────────────────────────────────────────────────────────────────────────

/// 맞추기 열쇠 — 조각(`#…`)을 뗀 온 주소의 해시, 메서드의 해시, 서비스 워커 갈래.
pub const Key = struct {
    url: u64,
    method: u64,
    sw: bool,

    pub fn eql(a: Key, b: Key) bool {
        return a.url == b.url and a.method == b.method and a.sw == b.sw;
    }
};

/// UTF-8 주소의 해시 — `#` 앞까지(CEF 주소는 조각을 싣고 CDP 는 떼었다 — J1).
pub fn hashUrl8(url: []const u8) u64 {
    const end = std.mem.indexOfScalar(u8, url, '#') orelse url.len;
    return std.hash.Wyhash.hash(0x9d2, url[0..end]);
}

/// CEF 의 UTF-16 주소를 UTF-8 로 풀며 같은 해시를 낸다(할당 없음 — IO 스레드에서 부른다). 짝 없는 대리 쌍은 U+FFFD.
pub fn hashUrl16(units: []const u16) u64 {
    var h = std.hash.Wyhash.init(0x9d2);
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < units.len) : (i += 1) {
        var cp: u21 = units[i];
        if (cp == '#') break;
        if (cp >= 0xD800 and cp <= 0xDBFF and i + 1 < units.len and units[i + 1] >= 0xDC00 and units[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (units[i + 1] - 0xDC00);
            i += 1;
        } else if (cp >= 0xD800 and cp <= 0xDFFF) cp = 0xFFFD;
        if (n + 4 > buf.len) {
            h.update(buf[0..n]);
            n = 0;
        }
        n += std.unicode.utf8Encode(cp, buf[n..][0..4]) catch unreachable;
    }
    h.update(buf[0..n]);
    return h.final();
}

pub fn hashMethod(method: []const u8) u64 {
    return std.hash.Wyhash.hash(0x3e7, method);
}

// ── MIME 가르기 ───────────────────────────────────────────────────────────────────────────────────────────

pub const MimeClass = enum {
    /// 글로 받는다.
    text,
    /// 글이 아닌 종류 — 받지 않는다(`not_text`).
    binary,
    /// 모른다(빈 MIME) — 받아 보고 UTF-8 이면 글.
    unknown,
};

/// 응답 MIME(매개변수 없이, 소문자로 비교)의 갈래. 글: `text/*`(이벤트 흐름 제외), JSON·XML 꼴(`+json`·`+xml` 포함), JavaScript, 양식,
/// GraphQL. 빈 MIME 는 모른다.
pub fn mimeClass(mime_full: []const u8) MimeClass {
    const semi = std.mem.indexOfScalar(u8, mime_full, ';') orelse mime_full.len;
    const mime = std.mem.trim(u8, mime_full[0..semi], " \t");
    if (mime.len == 0) return .unknown;
    var lb: [128]u8 = undefined;
    if (mime.len > lb.len) return .binary;
    const m = std.ascii.lowerString(&lb, mime);
    if (std.mem.eql(u8, m, "text/event-stream")) return .binary; // 끝나지 않는 흐름 — 본문이 남지 않는다
    if (std.mem.startsWith(u8, m, "text/")) return .text;
    if (std.mem.endsWith(u8, m, "+json") or std.mem.endsWith(u8, m, "+xml") or std.mem.endsWith(u8, m, "/json") or std.mem.endsWith(u8, m, "/xml")) return .text;
    for ([_][]const u8{ "application/javascript", "application/ecmascript", "application/x-javascript", "application/x-www-form-urlencoded", "application/graphql", "application/x-ndjson", "application/jsonl", "application/csv" }) |t| {
        if (std.mem.eql(u8, m, t)) return .text;
    }
    return .binary;
}

/// windows-1252 로 되돌려 볼 MIME 인가(J11 — charset 없는 `text/plain` 이 깨져 왔다; HTML·JavaScript·JSON 은 맞게 풀렸다).
fn redecodeCandidate(mime_full: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, mime_full, ';') orelse mime_full.len;
    const mime = std.mem.trim(u8, mime_full[0..semi], " \t");
    if (!std.ascii.startsWithIgnoreCase(mime, "text/")) return false;
    for ([_][]const u8{ "text/html", "text/javascript", "text/ecmascript" }) |t| if (std.ascii.eqlIgnoreCase(mime, t)) return false;
    return true;
}

/// Content-Type 헤더 값에 charset 매개변수가 있는가.
pub fn hasCharset(content_type: []const u8) bool {
    return std.ascii.findIgnoreCase(content_type, "charset=") != null;
}

// ── 결과 풀기 ─────────────────────────────────────────────────────────────────────────────────────────────

/// windows-1252 의 0x80..0x9F 자리(정의되지 않은 다섯은 그 C1 코드점 그대로 — Chromium 의 디코더와 같다).
const cp1252_high = [32]u21{
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
};

fn cp1252Byte(cp: u21) ?u8 {
    if (cp < 0x80 or (cp >= 0xA0 and cp <= 0xFF)) return @intCast(cp);
    for (cp1252_high, 0..) |v, i| if (v == cp) return @intCast(0x80 + i);
    return null;
}

/// 글을 windows-1252 바이트로 되돌린다(`out` 에) — 한 글자라도 그 표에 없으면 null.
pub fn toCp1252(text: []const u8, out: []u8) ?[]u8 {
    var it = (std.unicode.Utf8View.init(text) catch return null).iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (n == out.len) return null;
        out[n] = cp1252Byte(cp) orelse return null;
        n += 1;
    }
    return out[0..n];
}

pub const Decoded = struct {
    state: State,
    flags: Flags = .{},
    /// `captured` 일 때만 — 부른 쪽 소유.
    bytes: []u8 = &.{},
};

/// `getResponseBody` 의 결과(`{"body":"…","base64Encoded":bool}`)를 보낼 바이트로 푼다. `mime` 은 응답 MIME, `charset` 은 Content-Type 에
/// charset 이 있었는가. 실패한 호출(`ok` 거짓 — 「다음 문서로 옮겨 사라졌다」 등)과 모양이 틀린 결과는 `unavailable`.
pub fn decodeResult(gpa: std.mem.Allocator, ok: bool, json: []const u8, mime: []const u8, charset: bool) std.mem.Allocator.Error!Decoded {
    if (!ok) return .{ .state = .unavailable };
    const parsed = std.json.parseFromSlice(struct { body: []const u8 = "", base64Encoded: bool = false }, gpa, json, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .state = .unavailable },
    };
    defer parsed.deinit();
    const v = parsed.value;
    var bytes: []u8 = undefined;
    if (v.base64Encoded) {
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(v.body) catch return .{ .state = .unavailable };
        if (n > msg.max_net_body_bytes) return .{ .state = .over_cap };
        bytes = try gpa.alloc(u8, n);
        dec.decode(bytes, v.body) catch {
            gpa.free(bytes);
            return .{ .state = .unavailable };
        };
    } else {
        if (v.body.len > 4 * msg.max_net_body_bytes) return .{ .state = .over_cap };
        bytes = try gpa.dupe(u8, v.body);
    }
    if (bytes.len == 0) {
        gpa.free(bytes);
        return .{ .state = .no_body };
    }
    var flags: Flags = .{};
    if (v.base64Encoded) {
        // 글 MIME 인데 base64 로 왔다(잘못된 UTF-8 JSON·charset 없는 EUC-KR — J11): UTF-8 이면 글, 아니면 바이트 그대로.
        if (!std.unicode.utf8ValidateSlice(bytes)) flags.binary = true;
    } else if (!charset and redecodeCandidate(mime) and !isAscii(bytes)) {
        // charset 없는 text/* 를 Chromium 이 windows-1252 로 풀었다(J11) — 되돌려 UTF-8 이면 그것이 페이지가 받은 글이다.
        const back = try gpa.alloc(u8, bytes.len);
        defer gpa.free(back);
        if (toCp1252(bytes, back)) |raw| {
            if (std.unicode.utf8ValidateSlice(raw) and !isAscii(raw)) {
                const fixed = try gpa.dupe(u8, raw);
                gpa.free(bytes);
                bytes = fixed;
                flags.redecoded = true;
            } else flags.chromium_decoded = true;
        } else flags.chromium_decoded = true;
    }
    if (bytes.len > msg.max_net_body_bytes) {
        gpa.free(bytes);
        return .{ .state = .over_cap };
    }
    return .{ .state = .captured, .flags = flags, .bytes = bytes };
}

fn isAscii(b: []const u8) bool {
    for (b) |c| if (c >= 0x80) return false;
    return true;
}

// ── CDP 이벤트에서 고른 값 ────────────────────────────────────────────────────────────────────────────────

pub const Rid = struct {
    buf: [max_rid_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn init(s: []const u8) ?Rid {
        if (s.len == 0 or s.len > max_rid_bytes) return null;
        var r: Rid = .{ .len = @intCast(s.len) };
        @memcpy(r.buf[0..s.len], s);
        return r;
    }

    pub fn slice(self: *const Rid) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn eql(self: *const Rid, s: []const u8) bool {
        return std.mem.eql(u8, self.slice(), s);
    }
};

/// 표가 받는 CDP 사건(호출자가 JSON 에서 고른 값 — `parseEvent`).
pub const Event = union(enum) {
    /// `Network.requestWillBeSent` — 리다이렉트 홉이면 `redirect`(열쇠는 첫 주소의 것).
    will_be_sent: struct { rid: []const u8, url_hash: u64, method_hash: u64, ts_us: i64, redirect: bool = false, prefetch: bool = false },
    /// `Network.requestWillBeSentExtraInfo` — 실제로 실린 쿠키(막히지 않은 것)·인증 헤더가 있었나.
    extra_info: struct { rid: []const u8, credentialed: bool },
    /// `Network.responseReceived`.
    response: struct { rid: []const u8, mime: []const u8, from_sw: bool, charset: bool, prefetch: bool = false },
    /// `Network.dataReceived` — 풀어 낸 바이트.
    data: struct { rid: []const u8, bytes: u64 },
    /// `Network.requestServedFromCache` — 메모리 캐시: CEF 는 이 요청을 보지 못한다(J1).
    from_cache: struct { rid: []const u8 },
    finished: struct { rid: []const u8 },
    failed: struct { rid: []const u8 },
};

fn getPath(v: std.json.Value, path: []const u8) ?std.json.Value {
    var cur = v;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return cur;
}

fn str(v: std.json.Value, path: []const u8) []const u8 {
    const x = getPath(v, path) orelse return "";
    return if (x == .string) x.string else "";
}

fn boolean(v: std.json.Value, path: []const u8) bool {
    const x = getPath(v, path) orelse return false;
    return x == .bool and x.bool;
}

fn number(v: std.json.Value, path: []const u8) ?f64 {
    const x = getPath(v, path) orelse return null;
    return switch (x) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// 헤더 객체에서 이름(대소문자 무시)의 값.
fn header(headers: ?std.json.Value, name: []const u8) ?[]const u8 {
    const h = headers orelse return null;
    if (h != .object) return null;
    var it = h.object.iterator();
    while (it.next()) |kv| if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, name)) {
        return if (kv.value_ptr.* == .string) kv.value_ptr.string else "";
    };
    return null;
}

/// 표가 쓰는 CDP 메서드인가(메서드 이름으로 먼저 거른다 — J7: 그 밖은 풀지 않는다).
pub fn wanted(method: []const u8) bool {
    for ([_][]const u8{ "Network.requestWillBeSent", "Network.requestWillBeSentExtraInfo", "Network.responseReceived", "Network.loadingFinished", "Network.loadingFailed", "Network.requestServedFromCache" }) |m| {
        if (std.mem.eql(u8, method, m)) return true;
    }
    return false;
}

/// `Network.dataReceived` 를 풀지 않고 훑는다(J7 — 이벤트의 29 %): `"requestId":"…"` 와 `"dataLength":N`.
pub fn scanData(params: []const u8) ?Event {
    const rid = scanString(params, "\"requestId\":\"") orelse return null;
    const at = std.mem.indexOf(u8, params, "\"dataLength\":") orelse return null;
    var i = at + "\"dataLength\":".len;
    while (i < params.len and params[i] == ' ') i += 1;
    var n: u64 = 0;
    var digits: usize = 0;
    while (i < params.len and params[i] >= '0' and params[i] <= '9') : (i += 1) {
        n = n *| 10 +| (params[i] - '0');
        digits += 1;
    }
    if (digits == 0) return null;
    return .{ .data = .{ .rid = rid, .bytes = n } };
}

fn scanString(p: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, p, needle) orelse return null;
    const rest = p[at + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

/// 푼 params 에서 사건 하나(모르는 메서드·모양이면 null). 글 칸은 `v` 를 빌린다.
pub fn parseEvent(method: []const u8, v: std.json.Value) ?Event {
    const rid = str(v, "requestId");
    if (rid.len == 0) return null;
    if (std.mem.eql(u8, method, "Network.requestWillBeSent")) {
        const ts = number(v, "timestamp") orelse return null;
        const url = str(v, "request.url");
        const method_name = str(v, "request.method");
        const kind = str(v, "type");
        return .{ .will_be_sent = .{
            .rid = rid,
            .url_hash = hashUrl8(url),
            .method_hash = hashMethod(method_name),
            .ts_us = @intFromFloat(ts * 1e6),
            .redirect = getPath(v, "redirectResponse") != null,
            .prefetch = std.mem.eql(u8, kind, "Prefetch"),
        } };
    }
    if (std.mem.eql(u8, method, "Network.requestWillBeSentExtraInfo")) {
        var cred = false;
        if (getPath(v, "associatedCookies")) |cookies| if (cookies == .array) for (cookies.array.items) |ck| {
            const br = getPath(ck, "blockedReasons") orelse {
                cred = true; // 막은 까닭이 없다 — 실렸다
                break;
            };
            if (br == .array and br.array.items.len == 0) {
                cred = true;
                break;
            }
        };
        const hs = getPath(v, "headers");
        if (header(hs, "authorization") != null or header(hs, "cookie") != null or header(hs, "proxy-authorization") != null) cred = true;
        return .{ .extra_info = .{ .rid = rid, .credentialed = cred } };
    }
    if (std.mem.eql(u8, method, "Network.responseReceived")) {
        const ct = header(getPath(v, "response.headers"), "content-type") orelse "";
        return .{ .response = .{
            .rid = rid,
            .mime = str(v, "response.mimeType"),
            .from_sw = boolean(v, "response.fromServiceWorker"),
            .charset = hasCharset(ct),
            .prefetch = boolean(v, "response.fromPrefetchCache"),
        } };
    }
    if (std.mem.eql(u8, method, "Network.loadingFinished")) return .{ .finished = .{ .rid = rid } };
    if (std.mem.eql(u8, method, "Network.loadingFailed")) return .{ .failed = .{ .rid = rid } };
    if (std.mem.eql(u8, method, "Network.requestServedFromCache")) return .{ .from_cache = .{ .rid = rid } };
    return null;
}

// ── 표 ────────────────────────────────────────────────────────────────────────────────────────────────────

/// CEF 시작 하나(`body_expected` 로 알린 요청 — 끝은 꼭 하나).
pub const Candidate = struct {
    request: u64,
    key: Key,
    /// IO 스레드의 `on_before_resource_load` 시각(mach µs — CDP `timestamp` 와 같은 시계, J1).
    t_io_us: i64,
    /// 보이는 규칙에 드는 칸(프레임·앞 문서·첫 사이트·initiator)의 해시 — 다른 후보와 다르면 모호하다.
    attr: u64,
    /// 덮이는 호스트인가(설정이 꺼졌을 때 — 리다이렉트마다 다시 정한다). 켜져 있으면 늘 참.
    covered: bool = true,
    /// CEF 헤더에 쿠키·인증 헤더가 있었다(ExtraInfo 가 없을 때와 함께 쓴다).
    cef_credentialed: bool = false,
    claimed: bool = false,
    /// CEF 끝을 본 UI 시각(µs, 0 = 아직).
    ended_at: i64 = 0,
    /// 같은 번호로 다시 시작한 시도면 앞 시도의 IO 시각(0 = 첫 시도) — 앞 시도 때 시작한 CDP 요청과 짓지 않는다(`tryDecide`).
    prev_t_io_us: i64 = 0,
};

const CdpState = enum { open, finished, failed, cached };

const Cdp = struct {
    rid: Rid,
    key_url: u64,
    key_method: u64,
    ts_us: i64,
    /// 응답의 서비스 워커 갈래(응답 전이면 거짓).
    sw: bool = false,
    state: CdpState = .open,
    prefetch: bool = false,
    mime: [msg.max_net_mime_bytes]u8 = undefined,
    mime_len: u8 = 0,
    charset: bool = false,
    data_bytes: u64 = 0,
    /// ExtraInfo 가 실린 것을 알렸다 / 모른다.
    credentialed: bool = false,
    saw_extra: bool = false,
    /// 끝(성공·실패)을 본 UI 시각 — 후보를 기다리는 시한의 기준.
    done_at: i64 = 0,
    /// requestWillBeSent 를 봤다(ExtraInfo 가 먼저 와 자리만 잡은 동안 거짓 — 짝을 찾지 않는다).
    has_key: bool = true,
    /// 같은 requestId 로 같은 주소·메서드를 다시 보낸 때(0 = 없었다) — Chromium 이 이 요청을 다시 시작했다(CEF 는 같은 번호로 새 시작을 낸다,
    /// CDP 는 리다이렉트로 알린다 — 판정 `body-restart-same-id` 실측). 본문은 마지막 시도의 것이라 짝은 그때 시작한 CEF 시도와 짓는다.
    restart_ts_us: i64 = 0,

    fn key(self: *const Cdp) Key {
        return .{ .url = self.key_url, .method = self.key_method, .sw = self.sw };
    }

    /// 짝을 찾는 기준 시각 — 다시 보냈으면 그때, 아니면 처음 보낸 때.
    fn anchor(self: *const Cdp) i64 {
        return if (self.restart_ts_us != 0) self.restart_ts_us else self.ts_us;
    }

    fn mimeSlice(self: *const Cdp) []const u8 {
        return self.mime[0..self.mime_len];
    }
};

const Waiting = struct {
    request: u64,
    rid: Rid,
    since: i64,
    bytes: u64,
    mime: [msg.max_net_mime_bytes]u8 = undefined,
    mime_len: u8 = 0,
    charset: bool,
    credentialed: bool,
};

/// 보낸 `getResponseBody` 하나.
pub const Inflight = struct {
    id: i32,
    browser: BrowserId,
    session: u32,
    request: u64,
    decoded: u64,
    mime: [msg.max_net_mime_bytes]u8 = undefined,
    mime_len: u8 = 0,
    charset: bool,
    credentialed: bool,

    pub fn mimeSlice(self: *const Inflight) []const u8 {
        return self.mime[0..self.mime_len];
    }
};

const DropMark = struct { url: u64, t_us: i64 };

const Bucket = struct {
    tokens: f64,
    at_us: i64 = 0,

    fn refill(self: *Bucket, rate: f64, burst: f64, now_us: i64) void {
        if (self.at_us == 0) self.at_us = now_us;
        if (now_us > self.at_us) {
            self.tokens = @min(burst, self.tokens + @as(f64, @floatFromInt(now_us - self.at_us)) / 1e6 * rate);
            self.at_us = now_us;
        }
    }
};

pub const Tab = struct {
    browser: BrowserId = 0,
    /// 0 = 기록하지 않는다. maru 가 켤 때 매긴 번호(`net_record.session`).
    session: u32 = 0,
    /// 쏟아짐 밸브가 멈췄다(세션은 그대로 — maru 가 다시 켜야 풀린다).
    paused: bool = false,
    cands: std.ArrayList(Candidate) = .empty,
    cdp: std.ArrayList(Cdp) = .empty,
    waiting: std.ArrayList(Waiting) = .empty,
    inflight: usize = 0,
    drops: [max_drop_marks]DropMark = undefined,
    drop_len: usize = 0,
    drop_next: usize = 0,
    /// 표지가 넘쳤다 — 이 시각까지의 창은 모두 모호하다.
    drop_overflow_until: i64 = 0,
    bodies: Bucket = .{ .tokens = tab_bodies_per_s },
    bytes: Bucket = .{ .tokens = tab_bytes_per_s },
    /// 쏟아짐 밸브 — 지금 초의 이벤트 수와 넘은 초가 이어진 수.
    flood_second: i64 = 0,
    flood_count: u32 = 0,
    flood_over: u8 = 0,

    pub fn recording(self: *const Tab) bool {
        return self.session != 0 and !self.paused;
    }

    fn deinit(self: *Tab, gpa: std.mem.Allocator) void {
        self.cands.deinit(gpa);
        self.cdp.deinit(gpa);
        self.waiting.deinit(gpa);
    }
};

/// 표가 내는 일 — 부른 쪽(`net_body.zig`)이 차례로 한다.
pub const Action = union(enum) {
    /// `getResponseBody` 를 보낸다(`inflight` 에 이미 적었다).
    fetch: struct { browser: BrowserId, id: i32, rid: Rid },
    /// 본문 없이 끝을 보낸다.
    end: struct { browser: BrowserId, session: u32, request: u64, state: State, flags: Flags = .{}, decoded: u64 = 0 },
    /// 쏟아짐 밸브가 그 탭의 기록을 멈췄다 — `Network.disable` 을 보내고 maru 에 알린다.
    pause: struct { browser: BrowserId, session: u32 },
};

pub const Table = struct {
    tabs: [max_tabs]Tab = @splat(.{}),
    inflight: std.ArrayList(Inflight) = .empty,
    next_id: i32 = id_base,
    global_bytes: Bucket = .{ .tokens = global_bytes_per_s },
    actions: std.ArrayList(Action) = .empty,

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        for (&self.tabs) |*t| t.deinit(gpa);
        self.inflight.deinit(gpa);
        self.actions.deinit(gpa);
    }

    pub fn tabOf(self: *Table, browser: BrowserId) ?*Tab {
        if (browser == 0) return null;
        for (&self.tabs) |*t| if (t.browser == browser) return t;
        return null;
    }

    pub fn recording(self: *Table, browser: BrowserId) bool {
        const t = self.tabOf(browser) orelse return false;
        return t.recording();
    }

    /// 어느 탭이든 기록하는가(IO 스레드의 값싼 판단에 쓰는 값을 부른 쪽이 원자 변수로 옮긴다).
    pub fn anyRecording(self: *const Table) bool {
        for (&self.tabs) |*t| if (t.browser != 0 and t.recording()) return true;
        return false;
    }

    fn emit(self: *Table, gpa: std.mem.Allocator, a: Action) std.mem.Allocator.Error!void {
        try self.actions.append(gpa, a);
    }

    /// 쌓인 일을 `out`(빈 목록)과 바꿔 가져간다 — 일을 하는 동안 표가 새 일을 쌓아도 가져간 목록은 그대로다(부른 쪽이 비우고 다시 부른다).
    pub fn swapActions(self: *Table, out: *std.ArrayList(Action)) void {
        std.debug.assert(out.items.len == 0);
        std.mem.swap(std.ArrayList(Action), &self.actions, out);
    }

    // ── 켜고 끄기 ──────────────────────────────────────────────────────────────────────────────────────────

    /// `net_record` 켬 — 자리를 잡고 세션을 적는다. 이미 켜져 있으면 앞 세션의 것을 `recording_stopped` 로 끝내고 새 세션으로. 자리가 없으면 거짓.
    pub fn start(self: *Table, gpa: std.mem.Allocator, browser: BrowserId, session: u32) std.mem.Allocator.Error!bool {
        if (session == 0) return false;
        if (self.tabOf(browser)) |t| {
            try self.finishAll(gpa, t, .recording_stopped);
            t.session = session;
            t.paused = false;
            t.flood_over = 0;
            return true;
        }
        for (&self.tabs) |*t| if (t.browser == 0) {
            t.* = .{ .browser = browser, .session = session };
            return true;
        };
        return false;
    }

    /// `net_record` 끔 — 기다리던 것·짝이 없는 것 모두 `recording_stopped`, 보낸 호출의 늦은 결과는 버린다(세대 — J6: disable 의 답이 2.8 초
    /// 늦을 수 있다).
    pub fn stop(self: *Table, gpa: std.mem.Allocator, browser: BrowserId) std.mem.Allocator.Error!void {
        const t = self.tabOf(browser) orelse return;
        try self.finishAll(gpa, t, .recording_stopped);
        t.deinit(gpa);
        t.* = .{};
    }

    /// 렌더러가 죽었다(J5 — 보낸 호출은 다음 이동까지 답이 없다): 그 탭의 것을 모두 `detached` 로 끝낸다. 기록은 그대로다(다시 켜지 않아도
    /// 이벤트가 이어진다 — J5).
    pub fn rendererGone(self: *Table, gpa: std.mem.Allocator, browser: BrowserId) std.mem.Allocator.Error!void {
        const t = self.tabOf(browser) orelse return;
        try self.finishAll(gpa, t, .detached);
    }

    /// 브라우저가 닫힌다 — `detached` 로 끝내고 자리를 비운다.
    pub fn closed(self: *Table, gpa: std.mem.Allocator, browser: BrowserId) std.mem.Allocator.Error!void {
        const t = self.tabOf(browser) orelse return;
        try self.finishAll(gpa, t, .detached);
        t.deinit(gpa);
        t.* = .{};
    }

    /// 그 탭의 기다림·보낸 호출·후보를 모두 `state` 로 끝낸다(끝은 후보마다 하나 — 보낸 호출의 후보는 그 호출이 끝낸다).
    fn finishAll(self: *Table, gpa: std.mem.Allocator, t: *Tab, state: State) std.mem.Allocator.Error!void {
        var i: usize = 0;
        while (i < self.inflight.items.len) {
            const f = self.inflight.items[i];
            if (f.browser != t.browser) {
                i += 1;
                continue;
            }
            try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = f.session, .request = f.request, .state = state } });
            _ = self.inflight.swapRemove(i);
            t.inflight -|= 1;
        }
        for (t.waiting.items) |w| try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = w.request, .state = state } });
        t.waiting.clearRetainingCapacity();
        for (t.cands.items) |c| if (!c.claimed) try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = c.request, .state = state } });
        t.cands.clearRetainingCapacity();
        t.cdp.clearRetainingCapacity();
        t.inflight = 0;
    }

    // ── CEF 쪽(UI 스레드의 보내는 task) ──────────────────────────────────────────────────────────────────────

    /// 기록하는 탭의 CEF 시작 하나를 후보로 적는다 — 적었으면 참(그 요청의 `net_begin` 에 `body_expected` 를 세운다 — 끝은 꼭 하나).
    /// 같은 번호의 후보가 있으면 다시 시작이다(`restartCand` — 앞 시도의 끝을 여기서 낸다: 부른 쪽은 이 시작의 `net_begin` 보다 먼저 보낸다).
    pub fn cefBegin(self: *Table, gpa: std.mem.Allocator, browser: BrowserId, c: Candidate) std.mem.Allocator.Error!bool {
        const t = self.tabOf(browser) orelse return false;
        if (!t.recording()) return false;
        var prev: i64 = 0;
        for (t.cands.items, 0..) |e, i| if (e.request == c.request) {
            prev = e.t_io_us;
            try self.restartCand(gpa, t, i);
            break;
        };
        if (t.cands.items.len >= max_candidates) {
            // 가장 오래된 것을 놓는다 — 짝이 있으면(가져갈 본문이 있다) 남기고 짝 없는 것부터.
            const victim = for (t.cands.items, 0..) |e, i| {
                if (!e.claimed) break i;
            } else return false;
            try self.emit(gpa, .{ .end = .{ .browser = browser, .session = t.session, .request = t.cands.items[victim].request, .state = .busy } });
            _ = t.cands.orderedRemove(victim);
        }
        var cand = c;
        cand.claimed = false;
        cand.ended_at = 0;
        cand.prev_t_io_us = prev;
        try t.cands.append(gpa, cand);
        return true;
    }

    /// W9d① 적대 리뷰 후 × W9d②: CEF 가 같은 번호로 다시 시작했다(Critical-CH — W9d① 이 앞 기록을 `restarted` 로 끝낸다). 앞 시도의 후보를
    /// 어디에 있든(짝 없음·자리 기다림·보낸 호출) 지금 `restarted` 로 끝낸다 — maru 는 본문 frame 을 그 번호의 가장 새 기록에 붙이므로 앞 시도의
    /// 끝이 새 시작 뒤로 가면 새 기록에 붙는다. 보낸 호출은 목록에서 빼 늦은 답을 버린다(`takeInflight` 가 못 찾는다). 한 번호의 후보는 늘 하나다.
    fn restartCand(self: *Table, gpa: std.mem.Allocator, t: *Tab, i: usize) std.mem.Allocator.Error!void {
        const old = t.cands.items[i];
        for (t.waiting.items, 0..) |w, wi| if (w.request == old.request) {
            _ = t.waiting.orderedRemove(wi);
            break;
        };
        for (self.inflight.items, 0..) |f, fi| if (f.browser == t.browser and f.request == old.request) {
            _ = self.inflight.swapRemove(fi);
            t.inflight -|= 1;
            break;
        };
        try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = old.request, .state = .restarted } });
        _ = t.cands.orderedRemove(i);
    }

    /// CEF 응답 — 설정이 꺼졌을 때 응답을 보낸 호스트가 덮이는가(`net_response` 의 헤더를 덜어 낼지와 같은 결정 — 리다이렉트 뒤의 호스트다).
    pub fn cefCovered(self: *Table, browser: BrowserId, request: u64, covered: bool) void {
        const t = self.tabOf(browser) orelse return;
        for (t.cands.items) |*c| if (c.request == request) {
            c.covered = covered;
        };
    }

    /// CEF 끝 — 짝이 없으면 시한 뒤 `unmatched`.
    pub fn cefEnd(self: *Table, browser: BrowserId, request: u64, now_us: i64) void {
        const t = self.tabOf(browser) orelse return;
        for (t.cands.items) |*c| if (c.request == request and c.ended_at == 0) {
            c.ended_at = @max(now_us, 1);
        };
    }

    /// 문이 그 탭의 요청을 넘겼다(IO 시각·주소 해시) — 그 창 안의 같은 주소 짝은 모호하다.
    pub fn noteDrop(self: *Table, browser: BrowserId, url_hash: u64, t_us: i64) void {
        const t = self.tabOf(browser) orelse return;
        if (!t.recording()) return;
        if (t.drop_len == max_drop_marks) {
            // 덮어쓰기 전에 가장 오래된 표지의 시각까지 모두 모호하게 둔다 — 잊은 표지가 짝을 맞게 보이게 하지 않는다.
            t.drop_overflow_until = @max(t.drop_overflow_until, t.drops[t.drop_next].t_us);
        } else t.drop_len += 1;
        t.drops[t.drop_next] = .{ .url = url_hash, .t_us = t_us };
        t.drop_next = (t.drop_next + 1) % max_drop_marks;
    }

    /// 표지를 남길 자리가 없었다(IO 스레드의 상자가 찼다) — 이 시각까지의 창은 모두 모호하다.
    pub fn noteDropOverflow(self: *Table, browser: BrowserId, t_us: i64) void {
        const t = self.tabOf(browser) orelse return;
        t.drop_overflow_until = @max(t.drop_overflow_until, t_us);
    }

    // ── CDP 쪽 ──────────────────────────────────────────────────────────────────────────────────────────────

    fn cdpIndex(t: *Tab, rid: []const u8) ?usize {
        var i = t.cdp.items.len;
        while (i > 0) {
            i -= 1;
            if (t.cdp.items[i].rid.eql(rid)) return i;
        }
        return null;
    }

    /// 쏟아짐 밸브 — 이 이벤트로 그 탭을 멈추면 참.
    fn floodCheck(self: *Table, gpa: std.mem.Allocator, t: *Tab, now_us: i64) std.mem.Allocator.Error!bool {
        const second = @divFloor(now_us, 1_000_000);
        if (second != t.flood_second) {
            // 바로 앞 초가 넘었으면 이어진 수를 늘리고, 아니면(넘지 않았거나 초를 건너뛰었다) 다시 센다.
            t.flood_over = if (second == t.flood_second + 1 and t.flood_count > flood_events_per_s) t.flood_over +| 1 else 0;
            t.flood_second = second;
            t.flood_count = 0;
        }
        t.flood_count += 1;
        if (t.flood_count == flood_events_per_s + 1 and t.flood_over + 1 >= flood_seconds) {
            try self.finishAll(gpa, t, .recording_stopped);
            t.paused = true;
            try self.emit(gpa, .{ .pause = .{ .browser = t.browser, .session = t.session } });
            return true;
        }
        return false;
    }

    /// CDP `Network.*` 사건 하나(`now_us` 는 UI 시각). 메서드를 표가 쓰지 않아도 쏟아짐을 세려고 부른다(`ev` 가 null).
    pub fn cdpEvent(self: *Table, gpa: std.mem.Allocator, browser: BrowserId, ev: ?Event, now_us: i64) std.mem.Allocator.Error!void {
        const t = self.tabOf(browser) orelse return;
        if (!t.recording()) return;
        if (try self.floodCheck(gpa, t, now_us)) return;
        const e = ev orelse return;
        switch (e) {
            .will_be_sent => |v| {
                if (cdpIndex(t, v.rid)) |i| {
                    // ExtraInfo 가 먼저 와 자리만 있던 요청이면 열쇠를 채운다. 아니면 리다이렉트 홉 — 열쇠는 첫 주소의 것.
                    const r = &t.cdp.items[i];
                    if (!r.has_key and !v.redirect) {
                        r.key_url = v.url_hash;
                        r.key_method = v.method_hash;
                        r.ts_us = v.ts_us;
                        r.has_key = true;
                        r.prefetch = r.prefetch or v.prefetch;
                    } else if (r.has_key and v.url_hash == r.key_url and v.method_hash == r.key_method) {
                        // 같은 주소를 다시 보냈다 — 다시 시작(실측: Critical-CH 의 403 을 리다이렉트 응답으로 싣는다). 받은 바이트는 앞 시도의 것.
                        r.restart_ts_us = v.ts_us;
                        r.data_bytes = 0;
                    }
                    return;
                }
                if (v.redirect) return; // 첫 홉을 못 봤다 — 옮겨 간 주소는 CEF 의 열쇠(첫 주소)가 아니다
                const rid = Rid.init(v.rid) orelse return;
                if (t.cdp.items.len >= max_cdp) _ = t.cdp.orderedRemove(0);
                try t.cdp.append(gpa, .{ .rid = rid, .key_url = v.url_hash, .key_method = v.method_hash, .ts_us = v.ts_us, .prefetch = v.prefetch, .has_key = true });
            },
            .extra_info => |v| {
                const i = cdpIndex(t, v.rid) orelse blk: {
                    // ExtraInfo 가 requestWillBeSent 보다 먼저 올 수 있다 — 자리를 먼저 잡는다(열쇠는 requestWillBeSent 가 채운다, 그 전에는
                    // 어느 후보와도 맞지 않는다).
                    const rid = Rid.init(v.rid) orelse return;
                    if (t.cdp.items.len >= max_cdp) _ = t.cdp.orderedRemove(0);
                    try t.cdp.append(gpa, .{ .rid = rid, .key_url = 0, .key_method = 0, .ts_us = std.math.maxInt(i64), .has_key = false });
                    break :blk t.cdp.items.len - 1;
                };
                t.cdp.items[i].saw_extra = true;
                if (v.credentialed) t.cdp.items[i].credentialed = true;
            },
            .response => |v| {
                const i = cdpIndex(t, v.rid) orelse return;
                const r = &t.cdp.items[i];
                r.sw = v.from_sw;
                if (v.prefetch) r.prefetch = true;
                const m = v.mime[0..@min(v.mime.len, r.mime.len)];
                @memcpy(r.mime[0..m.len], m);
                r.mime_len = @intCast(m.len);
                r.charset = v.charset;
            },
            .data => |v| {
                const i = cdpIndex(t, v.rid) orelse return;
                t.cdp.items[i].data_bytes +|= v.bytes;
            },
            .from_cache => |v| {
                const i = cdpIndex(t, v.rid) orelse return;
                t.cdp.items[i].state = .cached;
            },
            .finished => |v| {
                const i = cdpIndex(t, v.rid) orelse return;
                const r = &t.cdp.items[i];
                if (r.state == .cached or r.prefetch or !r.has_key) {
                    _ = t.cdp.orderedRemove(i); // CEF 가 보지 못한 요청(메모리 캐시·추측 미리 받기 — J1·J3)
                    return;
                }
                r.state = .finished;
                r.done_at = @max(now_us, 1);
                try self.tryDecide(gpa, t, i, now_us);
            },
            .failed => |v| {
                const i = cdpIndex(t, v.rid) orelse return;
                const r = &t.cdp.items[i];
                if (r.state == .cached or r.prefetch or !r.has_key) {
                    _ = t.cdp.orderedRemove(i);
                    return;
                }
                r.state = .failed;
                r.done_at = @max(now_us, 1);
                try self.tryDecide(gpa, t, i, now_us);
            },
        }
    }

    /// 끝난 CDP 요청 `i` 의 짝을 찾아 판정한다. 아직 후보가 없으면 그대로 둔다(`tick` 이 다시 본다).
    fn tryDecide(self: *Table, gpa: std.mem.Allocator, t: *Tab, i: usize, now_us: i64) std.mem.Allocator.Error!void {
        const r = t.cdp.items[i];
        const key = r.key();
        // 시각의 기준 — 다시 보낸 요청은 다시 보낸 때(다시 시작한 CEF 시도가 그때 시작했다).
        const ts = r.anchor();
        // 차례 k — 같은 열쇠의 다른 CDP 요청 중 먼저 시작해 아직 짝을 정하지 않은 것(열렸거나 끝나 짝을 기다린다 — 정한 것은 목록에서
        // 빠졌다). 끝난 것도 세야 한다: 앞 요청이 CEF 기록을 기다리는 동안 뒤 요청이 끝나면 앞 요청의 짝을 가져갔다.
        var k: usize = 0;
        for (t.cdp.items, 0..) |o, j| {
            if (j == i or o.state == .cached or o.prefetch or !o.has_key) continue;
            if (o.key_url != key.url or o.key_method != key.method) continue;
            if (o.anchor() < ts or (o.anchor() == ts and j < i)) k += 1;
        }
        // 후보 — 같은 열쇠의 짝 없는 CEF 시작(창 안), IO 시각 차례. 다시 시작한 시도의 후보는 앞 시도 때 시작한(다시 보내지 않은) CDP 요청과
        // 짓지 않는다 — 그 본문은 버려진 앞 시도의 것이다(다른 requestId 로 보이는 다시 시작).
        var picks: [64]usize = undefined;
        var n: usize = 0;
        for (t.cands.items, 0..) |c, ci| {
            if (c.claimed or !c.key.eql(key)) continue;
            if (c.t_io_us < ts - window_before_us or c.t_io_us > ts + window_after_us) continue;
            if (c.prev_t_io_us != 0 and r.restart_ts_us == 0 and r.ts_us <= c.prev_t_io_us + window_before_us) continue;
            if (n == picks.len) break;
            picks[n] = ci;
            n += 1;
        }
        const Ctx = struct {
            cands: []const Candidate,
            fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return ctx.cands[a].t_io_us < ctx.cands[b].t_io_us;
            }
        };
        std.mem.sort(usize, picks[0..n], Ctx{ .cands = t.cands.items }, Ctx.lessThan);
        if (n < k + 1) {
            // 짝이 아직 오지 않았다(CEF 기록은 10 ms 묶음) — 시한이 지나면 CEF 가 보지 못한 요청으로 놓는다(본문 없음, maru 에 기록도 없다).
            if (now_us - r.done_at >= cef_grace_us) _ = t.cdp.orderedRemove(i);
            return;
        }
        const ci = picks[k];
        var ambiguous = false;
        for (picks[0..n]) |o| if (o != ci and t.cands.items[o].attr != t.cands.items[ci].attr) {
            ambiguous = true;
        };
        if (t.drop_overflow_until != 0 and ts - window_before_us <= t.drop_overflow_until) ambiguous = true;
        for (t.drops[0..t.drop_len]) |d| if (d.url == key.url and d.t_us >= ts - window_before_us and d.t_us <= ts + window_after_us) {
            ambiguous = true;
        };
        const cand = t.cands.items[ci];
        _ = t.cdp.orderedRemove(i);
        try self.decide(gpa, t, ci, cand, r, ambiguous, now_us);
    }

    /// 짝지은 요청의 판정 — 끝내거나(본문 없음) 받으러 간다.
    fn decide(self: *Table, gpa: std.mem.Allocator, t: *Tab, ci: usize, cand: Candidate, r: Cdp, ambiguous: bool, now_us: i64) std.mem.Allocator.Error!void {
        // 실린 자격 증명(UB1): ExtraInfo 가 알렸거나, 오지 않았으면 실린 것으로 친다(J12 — 서비스 워커·메모리 캐시엔 없다), CEF 헤더에 있으면 실렸다.
        const cred = r.credentialed or !r.saw_extra or cand.cef_credentialed;
        var flags: Flags = .{ .credentialed = cred };
        const end = struct {
            fn f(s: *Table, g: std.mem.Allocator, tab: *Tab, idx: usize, request: u64, state: State, fl: Flags, decoded: u64) std.mem.Allocator.Error!void {
                try s.emit(g, .{ .end = .{ .browser = tab.browser, .session = tab.session, .request = request, .state = state, .flags = fl, .decoded = decoded } });
                _ = tab.cands.orderedRemove(idx);
            }
        }.f;
        if (ambiguous) return end(self, gpa, t, ci, cand.request, .ambiguous, flags, r.data_bytes);
        if (r.state == .failed) return end(self, gpa, t, ci, cand.request, if (r.data_bytes > 0) .partial else .request_failed, flags, r.data_bytes);
        if (!cand.covered) return end(self, gpa, t, ci, cand.request, .not_covered, flags, r.data_bytes);
        const class = mimeClass(r.mimeSlice());
        if (class == .binary) return end(self, gpa, t, ci, cand.request, if (r.data_bytes == 0) .no_body else .not_text, flags, r.data_bytes);
        if (r.data_bytes > msg.max_net_body_bytes) return end(self, gpa, t, ci, cand.request, .over_cap, flags, r.data_bytes);
        flags = .{ .credentialed = cred };
        // 받으러 간다 — 자리가 없으면 잠시 기다린다(넘치면 busy).
        t.cands.items[ci].claimed = true;
        var w: Waiting = .{ .request = cand.request, .rid = r.rid, .since = now_us, .bytes = r.data_bytes, .charset = r.charset, .credentialed = cred };
        @memcpy(w.mime[0..r.mime_len], r.mime[0..r.mime_len]);
        w.mime_len = r.mime_len;
        if (t.waiting.items.len >= max_waiting_per_tab) {
            try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = cand.request, .state = .busy, .flags = flags, .decoded = r.data_bytes } });
            self.removeCand(t, cand.request);
            return;
        }
        try t.waiting.append(gpa, w);
        try self.pump(gpa, t, now_us);
    }

    fn removeCand(self: *Table, t: *Tab, request: u64) void {
        _ = self;
        for (t.cands.items, 0..) |c, i| if (c.request == request) {
            _ = t.cands.orderedRemove(i);
            return;
        };
    }

    /// 기다리는 본문을 자리·양동이가 허락하는 만큼 보낸다(만료된 것은 `busy`).
    fn pump(self: *Table, gpa: std.mem.Allocator, t: *Tab, now_us: i64) std.mem.Allocator.Error!void {
        while (t.waiting.items.len > 0) {
            const w = t.waiting.items[0];
            if (now_us - w.since > waiting_expiry_us) {
                try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = w.request, .state = .busy, .flags = .{ .credentialed = w.credentialed }, .decoded = w.bytes } });
                self.removeCand(t, w.request);
                _ = t.waiting.orderedRemove(0);
                continue;
            }
            if (t.inflight >= max_inflight_per_tab or self.inflight.items.len >= max_inflight) return;
            t.bodies.refill(tab_bodies_per_s, tab_bodies_per_s, now_us);
            t.bytes.refill(tab_bytes_per_s, tab_bytes_per_s, now_us);
            self.global_bytes.refill(global_bytes_per_s, global_bytes_per_s, now_us);
            const need: f64 = @floatFromInt(@max(w.bytes, 1));
            if (t.bodies.tokens < 1 or t.bytes.tokens < need or self.global_bytes.tokens < need) return;
            t.bodies.tokens -= 1;
            t.bytes.tokens -= need;
            self.global_bytes.tokens -= need;
            const id = self.next_id;
            self.next_id = if (self.next_id + 1 >= id_end) id_base else self.next_id + 1;
            var f: Inflight = .{ .id = id, .browser = t.browser, .session = t.session, .request = w.request, .decoded = w.bytes, .charset = w.charset, .credentialed = w.credentialed };
            @memcpy(f.mime[0..w.mime_len], w.mime[0..w.mime_len]);
            f.mime_len = w.mime_len;
            try self.inflight.append(gpa, f);
            t.inflight += 1;
            _ = t.waiting.orderedRemove(0);
            try self.emit(gpa, .{ .fetch = .{ .browser = t.browser, .id = id, .rid = w.rid } });
        }
    }

    /// 우리 대역의 결과가 왔다 — 보낸 호출이면 꺼내 준다(세대가 바뀌어 버린 호출이면 null — 늦은 답은 버린다). 부른 쪽이 풀어 보낸 뒤
    /// `bodyDone` 을 부른다.
    pub fn takeInflight(self: *Table, id: i32) ?Inflight {
        for (self.inflight.items, 0..) |f, i| if (f.id == id) {
            _ = self.inflight.swapRemove(i);
            if (self.tabOf(f.browser)) |t| {
                t.inflight -|= 1;
                if (t.session != f.session) return null;
            } else return null;
            return f;
        };
        return null;
    }

    /// 받은 본문을 보냈거나 끝냈다 — 후보를 지우고 다음 기다림을 보낸다.
    pub fn bodyDone(self: *Table, gpa: std.mem.Allocator, f: Inflight, now_us: i64) std.mem.Allocator.Error!void {
        const t = self.tabOf(f.browser) orelse return;
        self.removeCand(t, f.request);
        try self.pump(gpa, t, now_us);
    }

    /// 주기적으로(UI task) — 기다리던 CDP 끝의 짝을 다시 보고, 짝 없는 CEF 요청을 `unmatched` 로 정하고, 기다리는 본문을 보낸다.
    pub fn tick(self: *Table, gpa: std.mem.Allocator, now_us: i64) std.mem.Allocator.Error!void {
        for (&self.tabs) |*t| {
            if (t.browser == 0 or t.session == 0) continue;
            // 끝난 CDP 요청(짝을 기다린다) — 앞에서부터.
            var i: usize = 0;
            while (i < t.cdp.items.len) {
                const before = t.cdp.items.len;
                if (t.cdp.items[i].state == .finished or t.cdp.items[i].state == .failed) try self.tryDecide(gpa, t, i, now_us);
                if (t.cdp.items.len == before) i += 1;
            }
            var c: usize = 0;
            while (c < t.cands.items.len) {
                const cand = t.cands.items[c];
                if (!cand.claimed and cand.ended_at != 0 and now_us - cand.ended_at >= unclaimed_expiry_us) {
                    try self.emit(gpa, .{ .end = .{ .browser = t.browser, .session = t.session, .request = cand.request, .state = .unmatched, .flags = .{ .credentialed = cand.cef_credentialed } } });
                    _ = t.cands.orderedRemove(c);
                    continue;
                }
                c += 1;
            }
            // 오래된 문 넘김 표지는 잊는다(어떤 창에도 들지 않는다).
            if (t.drop_overflow_until != 0 and now_us - t.drop_overflow_until > window_after_us + unclaimed_expiry_us) t.drop_overflow_until = 0;
            try self.pump(gpa, t, now_us);
        }
    }

    /// 아직 할 일이 있는가(주기 task 를 이어 걸지).
    pub fn busy(self: *const Table) bool {
        for (&self.tabs) |*t| if (t.browser != 0 and (t.cands.items.len > 0 or t.cdp.items.len > 0 or t.waiting.items.len > 0)) return true;
        return self.inflight.items.len > 0;
    }
};

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const gpa_t = testing.allocator;

const H = struct {
    table: Table = .{},
    /// 번호마다 마지막 끝의 상태.
    ended: std.AutoHashMapUnmanaged(u64, State) = .empty,
    /// 번호마다 끝 수와 적은 시작(시도) 수 — 같은 번호로 다시 시작하면 시도가 여럿이다(끝은 시도마다 꼭 하나).
    end_counts: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    attempts: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    ends: usize = 0,
    fetches: std.ArrayList(Action) = .empty,
    paused: usize = 0,

    fn deinit(self: *H) void {
        self.table.deinit(gpa_t);
        self.ended.deinit(gpa_t);
        self.end_counts.deinit(gpa_t);
        self.attempts.deinit(gpa_t);
        self.fetches.deinit(gpa_t);
    }

    /// 끝 하나를 센다 — 그 번호의 적은 시도 수(`cand` 를 거치지 않은 시작은 하나로 친다)보다 많으면 실패(끝은 시도마다 꼭 하나).
    fn noteEnd(self: *H, request: u64, state: State) !void {
        const gop = try self.end_counts.getOrPut(gpa_t, request);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (gop.value_ptr.* > @max(1, self.attempts.get(request) orelse 1)) return error.SecondEnd;
        try self.ended.put(gpa_t, request, state);
        self.ends += 1;
    }

    /// 쌓인 일을 모은다 — 같은 시도에 끝이 둘이면 실패(끝은 꼭 하나).
    fn drain(self: *H) !void {
        var list: std.ArrayList(Action) = .empty;
        defer list.deinit(gpa_t);
        self.table.swapActions(&list);
        for (list.items) |a| switch (a) {
            .end => |e| try self.noteEnd(e.request, e.state),
            .fetch => try self.fetches.append(gpa_t, a),
            .pause => self.paused += 1,
        };
    }

    fn cand(self: *H, browser: BrowserId, request: u64, url: []const u8, t_io: i64, opts: struct { method: []const u8 = "GET", sw: bool = false, attr: u64 = 1, covered: bool = true }) !bool {
        const ok = try self.table.cefBegin(gpa_t, browser, .{ .request = request, .key = .{ .url = hashUrl8(url), .method = hashMethod(opts.method), .sw = opts.sw }, .t_io_us = t_io, .attr = opts.attr, .covered = opts.covered });
        // 앞 시도의 끝(다시 시작)은 이 시작보다 먼저 센다 — sidecar 는 앞 시도의 끝을 이 시작의 `net_begin` 보다 먼저 보낸다.
        try self.drain();
        if (ok) {
            const gop = try self.attempts.getOrPut(gpa_t, request);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        return ok;
    }

    fn ev(self: *H, browser: BrowserId, e: Event, now: i64) !void {
        try self.table.cdpEvent(gpa_t, browser, e, now);
        try self.drain();
    }

    fn sent(self: *H, browser: BrowserId, rid: []const u8, url: []const u8, ts: i64, now: i64) !void {
        try self.ev(browser, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(url), .method_hash = hashMethod("GET"), .ts_us = ts } }, now);
        try self.ev(browser, .{ .extra_info = .{ .rid = rid, .credentialed = false } }, now);
    }

    fn respond(self: *H, browser: BrowserId, rid: []const u8, mime: []const u8, bytes: u64, now: i64) !void {
        try self.ev(browser, .{ .response = .{ .rid = rid, .mime = mime, .from_sw = false, .charset = true } }, now);
        if (bytes > 0) try self.ev(browser, .{ .data = .{ .rid = rid, .bytes = bytes } }, now);
    }

    fn finish(self: *H, browser: BrowserId, rid: []const u8, now: i64) !void {
        try self.ev(browser, .{ .finished = .{ .rid = rid } }, now);
    }

    /// 보낸 호출의 CEF 요청 번호들(차례대로).
    fn fetchedRequests(self: *H, out: []u64) []u64 {
        var n: usize = 0;
        for (self.fetches.items) |a| {
            const id = a.fetch.id;
            for (self.table.inflight.items) |f| if (f.id == id and n < out.len) {
                out[n] = f.request;
                n += 1;
            };
        }
        return out[0..n];
    }
};

test "W9d②: 주소 해시 — UTF-16 과 UTF-8 이 같은 값, 조각(#)은 떼고, 대리 쌍도 같게" {
    const cases = [_][]const u8{ "https://a.test/x?q=1", "https://a.test/한글/😀?x=%ED%95%9C", "http://u:p@a.test/<>\"" };
    for (cases) |s| {
        var u16buf: [256]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&u16buf, s);
        try testing.expectEqual(hashUrl8(s), hashUrl16(u16buf[0..n]));
    }
    // CEF 는 조각을 싣고 CDP 는 뗀다(J1).
    var b16: [64]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&b16, "https://a.test/p#frag");
    try testing.expectEqual(hashUrl8("https://a.test/p"), hashUrl16(b16[0..n]));
    try testing.expectEqual(hashUrl8("https://a.test/p#x"), hashUrl8("https://a.test/p"));
    try testing.expect(hashUrl8("https://a.test/p") != hashUrl8("https://a.test/q"));
    // 긴 주소(버퍼 256 을 넘어 여러 번 나눠 넣는다)도 같다.
    var long: [3000]u8 = undefined;
    @memset(&long, 'a');
    @memcpy(long[0..15], "https://a.test/");
    var l16: [3000]u16 = undefined;
    const ln = try std.unicode.utf8ToUtf16Le(&l16, &long);
    try testing.expectEqual(hashUrl8(&long), hashUrl16(l16[0..ln]));
}

test "W9d②: MIME 가르기 — 글(text/*·JSON·XML·JS·+json·+xml), 글 아님(이미지·글꼴·octet-stream·이벤트 흐름), 빈 것은 모른다" {
    for ([_][]const u8{ "text/plain", "TEXT/HTML; charset=utf-8", "application/json", "application/problem+json", "application/xml", "image/svg+xml", "application/javascript", "text/css", "application/x-www-form-urlencoded", "application/ld+json" }) |m| try testing.expectEqual(MimeClass.text, mimeClass(m));
    for ([_][]const u8{ "image/png", "font/woff2", "application/octet-stream", "video/mp4", "application/wasm", "text/event-stream", "application/pdf" }) |m| try testing.expectEqual(MimeClass.binary, mimeClass(m));
    try testing.expectEqual(MimeClass.unknown, mimeClass(""));
    try testing.expect(hasCharset("text/plain; Charset=EUC-KR"));
    try testing.expect(!hasCharset("text/plain"));
}

test "W9d②: 결과 풀기 — JSON 글, base64(글이면 글·아니면 바이너리), 빈 본문, 실패·모양이 틀린 결과, charset 없는 text/plain 의 windows-1252 되돌리기" {
    {
        const d = try decodeResult(gpa_t, true, "{\"body\":\"{\\\"a\\\":\\\"\\uD55C\\\"}\",\"base64Encoded\":false}", "application/json", false);
        defer gpa_t.free(d.bytes);
        try testing.expectEqual(State.captured, d.state);
        try testing.expectEqualStrings("{\"a\":\"한\"}", d.bytes);
        try testing.expect(!d.flags.redecoded and !d.flags.binary);
    }
    {
        // 잘못된 UTF-8 JSON 은 base64 로 온다(J11) — 바이트 그대로, 바이너리 표시.
        const d = try decodeResult(gpa_t, true, "{\"body\":\"/wB7\",\"base64Encoded\":true}", "application/json", true);
        defer gpa_t.free(d.bytes);
        try testing.expect(d.state == .captured and d.flags.binary);
        try testing.expectEqualSlices(u8, &.{ 0xff, 0x00, 0x7b }, d.bytes);
    }
    {
        // 글인 base64 는 글.
        const d = try decodeResult(gpa_t, true, "{\"body\":\"7ZWc\",\"base64Encoded\":true}", "text/plain", true);
        defer gpa_t.free(d.bytes);
        try testing.expect(d.state == .captured and !d.flags.binary);
        try testing.expectEqualStrings("한", d.bytes);
    }
    {
        // UTF-8 「한」(ED 95 9C) 을 windows-1252 로 푼 깨진 글 「í•œ」 — 되돌린다.
        const d = try decodeResult(gpa_t, true, "{\"body\":\"\\u00ed\\u2022\\u0153 ok\",\"base64Encoded\":false}", "text/plain", false);
        defer gpa_t.free(d.bytes);
        try testing.expect(d.state == .captured and d.flags.redecoded);
        try testing.expectEqualStrings("한 ok", d.bytes);
    }
    {
        // charset 이 있으면 되돌리지 않는다. 되돌릴 수 없는 글(표에 없는 글자)은 표시만.
        const d = try decodeResult(gpa_t, true, "{\"body\":\"\\u00ed\\u2022\\u0153\",\"base64Encoded\":false}", "text/plain", true);
        defer gpa_t.free(d.bytes);
        try testing.expect(!d.flags.redecoded and !d.flags.chromium_decoded);
        const e = try decodeResult(gpa_t, true, "{\"body\":\"\\uD55C\",\"base64Encoded\":false}", "text/plain", false);
        defer gpa_t.free(e.bytes);
        try testing.expect(e.flags.chromium_decoded and !e.flags.redecoded);
        // 라틴 글이 우연히 UTF-8 이 되지 않으면(é 하나) 그대로 — 표시만.
        const f = try decodeResult(gpa_t, true, "{\"body\":\"caf\\u00e9\",\"base64Encoded\":false}", "text/csv", false);
        defer gpa_t.free(f.bytes);
        try testing.expect(f.flags.chromium_decoded);
        try testing.expectEqualStrings("café", f.bytes);
        // HTML 은 되돌리지 않는다(J11 — 맞게 풀렸다).
        const g = try decodeResult(gpa_t, true, "{\"body\":\"\\u00ed\\u2022\\u0153\",\"base64Encoded\":false}", "text/html", false);
        defer gpa_t.free(g.bytes);
        try testing.expect(!g.flags.redecoded and !g.flags.chromium_decoded);
    }
    try testing.expectEqual(State.no_body, (try decodeResult(gpa_t, true, "{\"body\":\"\",\"base64Encoded\":false}", "text/plain", true)).state);
    try testing.expectEqual(State.unavailable, (try decodeResult(gpa_t, false, "{\"code\":-32000}", "text/plain", true)).state);
    try testing.expectEqual(State.unavailable, (try decodeResult(gpa_t, true, "[1]", "text/plain", true)).state);
    try testing.expectEqual(State.unavailable, (try decodeResult(gpa_t, true, "{\"body\":\"!!!\",\"base64Encoded\":true}", "image/png", true)).state);
    var cp: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 0x80, 0xe9, 0x9f }, toCp1252("€éŸ", &cp).?);
    try testing.expect(toCp1252("한", &cp) == null);
}

test "W9d②: CDP 이벤트 고르기 — requestWillBeSent(리다이렉트·미리 받기), ExtraInfo 의 실린 쿠키·인증, responseReceived, dataReceived 훑기" {
    const P = struct {
        fn ev(method: []const u8, json: []const u8) !Event {
            const p = try std.json.parseFromSlice(std.json.Value, gpa_t, json, .{});
            defer p.deinit();
            var e = parseEvent(method, p.value) orelse return error.NoEvent;
            // 글 칸은 p 를 빌린다 — 시험은 값만 본다.
            switch (e) {
                .will_be_sent => |*v| v.rid = "",
                .extra_info => |*v| v.rid = "",
                .response => |*v| {
                    v.rid = "";
                    v.mime = "";
                },
                else => {},
            }
            return e;
        }
    };
    const w = (try P.ev("Network.requestWillBeSent", "{\"requestId\":\"1.2\",\"timestamp\":12.5,\"type\":\"XHR\",\"request\":{\"url\":\"https://a.test/x#f\",\"method\":\"POST\"}}")).will_be_sent;
    try testing.expectEqual(hashUrl8("https://a.test/x"), w.url_hash);
    try testing.expectEqual(hashMethod("POST"), w.method_hash);
    try testing.expectEqual(@as(i64, 12_500_000), w.ts_us);
    try testing.expect(!w.redirect and !w.prefetch);
    try testing.expect((try P.ev("Network.requestWillBeSent", "{\"requestId\":\"1.2\",\"timestamp\":1,\"redirectResponse\":{},\"request\":{\"url\":\"u\",\"method\":\"GET\"}}")).will_be_sent.redirect);
    try testing.expect((try P.ev("Network.requestWillBeSent", "{\"requestId\":\"A\",\"timestamp\":1,\"type\":\"Prefetch\",\"request\":{\"url\":\"u\",\"method\":\"GET\"}}")).will_be_sent.prefetch);
    try testing.expect((try P.ev("Network.requestWillBeSentExtraInfo", "{\"requestId\":\"1\",\"associatedCookies\":[{\"blockedReasons\":[]}],\"headers\":{}}")).extra_info.credentialed);
    try testing.expect(!(try P.ev("Network.requestWillBeSentExtraInfo", "{\"requestId\":\"1\",\"associatedCookies\":[{\"blockedReasons\":[\"SameSiteLax\"]}],\"headers\":{\"Accept\":\"*\"}}")).extra_info.credentialed);
    try testing.expect((try P.ev("Network.requestWillBeSentExtraInfo", "{\"requestId\":\"1\",\"associatedCookies\":[],\"headers\":{\"Authorization\":\"Basic x\"}}")).extra_info.credentialed);
    const r = (try P.ev("Network.responseReceived", "{\"requestId\":\"1\",\"response\":{\"mimeType\":\"text/plain\",\"fromServiceWorker\":true,\"headers\":{\"Content-Type\":\"text/plain\"}}}")).response;
    try testing.expect(r.from_sw and !r.charset);
    try testing.expect(parseEvent("Network.loadingFinished", .{ .object = .empty }) == null); // requestId 없음
    const d = scanData("{\"requestId\":\"77.3\",\"timestamp\":1.0,\"dataLength\":4096,\"encodedDataLength\":10}").?.data;
    try testing.expectEqualStrings("77.3", d.rid);
    try testing.expectEqual(@as(u64, 4096), d.bytes);
    try testing.expect(scanData("{\"requestId\":\"1\"}") == null);
    try testing.expect(wanted("Network.loadingFinished") and !wanted("Network.dataReceived") and !wanted("Page.frameNavigated"));
}

test "W9d②: 맞추기 — CDP 가 먼저 와도 CEF 가 먼저 와도 짝을 짓고 받으러 간다, 짝이 없는 CDP 요청은 시한 뒤 놓고 짝이 없는 CEF 요청은 unmatched 하나" {
    var h: H = .{};
    defer h.deinit();
    try testing.expect(try h.table.start(gpa_t, 5, 1));
    // ① CEF 먼저.
    try testing.expect(try h.cand(5, 100, "https://a.test/a.json", 1_000_000, .{}));
    try h.sent(5, "1.1", "https://a.test/a.json", 999_500, 1_000_100);
    try h.respond(5, "1.1", "application/json", 30, 1_000_200);
    try h.finish(5, "1.1", 1_000_300);
    var buf: [8]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{100}, h.fetchedRequests(&buf));
    // ② CDP 끝이 CEF 시작보다 먼저(J1 — 빠른 로컬 요청) — 기다렸다가 짓는다.
    try h.sent(5, "1.2", "https://a.test/b.json", 2_000_000, 2_000_000);
    try h.respond(5, "1.2", "application/json", 10, 2_000_100);
    try h.finish(5, "1.2", 2_000_200);
    try testing.expectEqual(@as(usize, 1), h.fetches.items.len);
    try testing.expect(try h.cand(5, 101, "https://a.test/b.json", 2_000_900, .{}));
    try h.table.tick(gpa_t, 2_010_000);
    try h.drain();
    // 자리는 탭마다 2 — 첫 것이 쥐고 있어도 둘째는 받으러 간다.
    try testing.expectEqualSlices(u64, &.{ 100, 101 }, h.fetchedRequests(&buf));
    // ③ 짝이 없는 CDP 요청(메모리 캐시가 아닌데 CEF 가 보지 못했다 — 다른 프로세스 iframe 등) — 시한 뒤 놓는다(끝 없음 — maru 에 기록이 없다).
    try h.sent(5, "1.3", "https://a.test/c.json", 3_000_000, 3_000_000);
    try h.finish(5, "1.3", 3_000_100);
    try h.table.tick(gpa_t, 3_000_100 + cef_grace_us);
    try h.drain();
    try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.cdp.items.len);
    // ④ 짝이 없는 CEF 요청 — CEF 끝 뒤 시한이 지나면 unmatched 하나.
    try testing.expect(try h.cand(5, 102, "https://iframe.test/x", 4_000_000, .{}));
    h.table.cefEnd(5, 102, 4_100_000);
    try h.table.tick(gpa_t, 4_100_000 + unclaimed_expiry_us - 1);
    try h.drain();
    try testing.expect(h.ended.get(102) == null);
    try h.table.tick(gpa_t, 4_100_000 + unclaimed_expiry_us);
    try h.drain();
    try testing.expectEqual(State.unmatched, h.ended.get(102).?);
    // ⑤ 창 밖(CDP 시작 2 초 넘어 뒤의 CEF 시작)은 짝이 아니다.
    try testing.expect(try h.cand(5, 103, "https://a.test/d", 9_000_000, .{}));
    try h.sent(5, "1.5", "https://a.test/d", 6_000_000, 9_000_100);
    try h.finish(5, "1.5", 9_000_200);
    for (h.table.tabOf(5).?.cands.items) |c| if (c.request == 103) try testing.expect(!c.claimed);
}

test "W9d②: 같은 주소의 동시 요청은 시작 차례대로 — 먼저 시작해 아직 열린 CDP 요청 수만큼 건너뛴다(J2), 메서드·서비스 워커 갈래가 다르면 다른 열쇠" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    for (0..3) |i| _ = try h.cand(5, 200 + i, "https://a.test/same", 1_000_000 + @as(i64, @intCast(i)) * 100, .{});
    for (0..3) |i| {
        var rb: [8]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rb, "s.{d}", .{i});
        try h.sent(5, rid, "https://a.test/same", 999_000 + @as(i64, @intCast(i)) * 100, 1_000_000);
        try h.respond(5, rid, "text/plain", 5, 1_000_500);
    }
    // 셋째가 먼저 끝난다 — 앞의 둘이 아직 열렸으니 셋째 후보(202)를 갖는다.
    try h.finish(5, "s.2", 1_001_000);
    try h.finish(5, "s.0", 1_001_100);
    var buf: [8]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 202, 200 }, h.fetchedRequests(&buf));
    // 메서드가 다르면 짝이 아니다.
    _ = try h.cand(5, 300, "https://a.test/m", 2_000_000, .{});
    try h.ev(5, .{ .will_be_sent = .{ .rid = "m.1", .url_hash = hashUrl8("https://a.test/m"), .method_hash = hashMethod("POST"), .ts_us = 1_999_900 } }, 2_000_000);
    try h.finish(5, "m.1", 2_000_100);
    try h.table.tick(gpa_t, 2_000_100 + cef_grace_us);
    try h.drain();
    try testing.expect(!h.table.tabOf(5).?.cands.items[h.table.tabOf(5).?.cands.items.len - 1].claimed);
    // 서비스 워커가 준 응답(fromServiceWorker)은 서비스 워커 갈래의 CEF 요청과만(J3). 보낸 둘을 먼저 돌려준다(탭마다 자리 2).
    for (h.fetches.items) |a| if (h.table.takeInflight(a.fetch.id)) |f| try h.table.bodyDone(gpa_t, f, 2_500_000);
    try h.drain();
    _ = try h.cand(5, 400, "https://a.test/swdata", 3_000_000, .{ .sw = false });
    _ = try h.cand(5, 401, "https://a.test/swdata", 3_000_050, .{ .sw = true });
    try h.sent(5, "w.1", "https://a.test/swdata", 2_999_900, 3_000_000);
    try h.ev(5, .{ .response = .{ .rid = "w.1", .mime = "application/json", .from_sw = true, .charset = true } }, 3_000_100);
    try h.ev(5, .{ .data = .{ .rid = "w.1", .bytes = 9 } }, 3_000_100);
    try h.finish(5, "w.1", 3_000_200);
    const last = h.fetches.items[h.fetches.items.len - 1].fetch.id;
    for (h.table.inflight.items) |f| if (f.id == last) try testing.expectEqual(@as(u64, 401), f.request);
}

test "W9d②: ExtraInfo 가 먼저 와도 실린 자격 증명을 잃지 않는다, 앞 요청이 CEF 기록을 기다리는 동안 끝난 뒤 요청은 앞 요청의 짝을 가져가지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    try h.ev(5, .{ .extra_info = .{ .rid = "e.1", .credentialed = false } }, 1_000_000);
    try h.ev(5, .{ .will_be_sent = .{ .rid = "e.1", .url_hash = hashUrl8("https://a.test/e"), .method_hash = hashMethod("GET"), .ts_us = 1_000_000 } }, 1_000_000);
    _ = try h.cand(5, 1, "https://a.test/e", 1_000_100, .{});
    try h.respond(5, "e.1", "image/png", 5, 1_000_200);
    try h.finish(5, "e.1", 1_000_300);
    try testing.expectEqual(State.not_text, h.ended.get(1).?);
    // 자격 증명 표시는 ExtraInfo 의 것(실리지 않았다).
    try h.drain();
    // 앞(A)·뒤(B) 둘 다 끝났는데 CEF 기록이 아직 — 오면 A 가 먼저 것을, B 가 뒤 것을 갖는다.
    try h.sent(5, "A", "https://a.test/s", 2_000_000, 2_000_000);
    try h.sent(5, "B", "https://a.test/s", 2_000_010, 2_000_010);
    try h.respond(5, "A", "text/plain", 1, 2_000_020);
    try h.respond(5, "B", "text/plain", 1, 2_000_020);
    try h.finish(5, "A", 2_000_030);
    _ = try h.cand(5, 10, "https://a.test/s", 2_000_100, .{});
    _ = try h.cand(5, 11, "https://a.test/s", 2_000_110, .{});
    try h.finish(5, "B", 2_000_200); // B 가 먼저 판정 기회를 얻는다 — A 가 아직 목록에 있으니 k = 1
    try h.table.tick(gpa_t, 2_000_300);
    try h.drain();
    var buf: [4]u64 = undefined;
    const got = h.fetchedRequests(&buf);
    try testing.expectEqual(@as(usize, 2), got.len);
    // 보낸 차례는 B(11) 다음 A(10) — 짝은 시작 차례 그대로다.
    try testing.expectEqualSlices(u64, &.{ 11, 10 }, got);
}

test "W9d②: 모호함 — 보이는 규칙이 다른 후보가 창 안에 있거나, 그 탭이 같은 주소의 요청을 문에서 넘긴 창 안이면 ambiguous(본문 없음)" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    _ = try h.cand(5, 10, "https://a.test/x", 1_000_000, .{ .attr = 1 }); // 주 프레임
    _ = try h.cand(5, 11, "https://a.test/x", 1_000_100, .{ .attr = 2 }); // 같은 사이트 iframe — 보이는 규칙이 다르다
    try h.sent(5, "a.1", "https://a.test/x", 999_000, 1_000_000);
    try h.respond(5, "a.1", "text/plain", 3, 1_000_200);
    try h.finish(5, "a.1", 1_000_300);
    try testing.expectEqual(State.ambiguous, h.ended.get(10).?);
    // 문 넘김(같은 주소) 창 안.
    _ = try h.cand(5, 20, "https://a.test/y", 2_000_000, .{});
    h.table.noteDrop(5, hashUrl8("https://a.test/y"), 2_000_050);
    try h.sent(5, "b.1", "https://a.test/y", 1_999_000, 2_000_000);
    try h.respond(5, "b.1", "text/plain", 3, 2_000_200);
    try h.finish(5, "b.1", 2_000_300);
    try testing.expectEqual(State.ambiguous, h.ended.get(20).?);
    // 다른 주소의 넘김은 상관없다 — 짝을 지어 받으러 간다.
    _ = try h.cand(5, 30, "https://a.test/z", 3_000_000, .{});
    h.table.noteDrop(5, hashUrl8("https://a.test/other"), 3_000_050);
    try h.sent(5, "c.1", "https://a.test/z", 2_999_000, 3_000_000);
    try h.respond(5, "c.1", "text/plain", 3, 3_000_200);
    try h.finish(5, "c.1", 3_000_300);
    try testing.expect(h.ended.get(30) == null);
    try testing.expectEqual(@as(usize, 1), h.fetches.items.len);
    // 표지가 넘치면 가장 오래된 표지까지의 창은 모두 모호하다.
    for (0..max_drop_marks + 1) |i| h.table.noteDrop(5, @intCast(i), 4_000_000 + @as(i64, @intCast(i)));
    _ = try h.cand(5, 40, "https://a.test/w", 4_000_000, .{});
    try h.sent(5, "d.1", "https://a.test/w", 3_999_000, 4_000_000);
    try h.respond(5, "d.1", "text/plain", 3, 4_000_000);
    try h.finish(5, "d.1", 4_000_000);
    try testing.expectEqual(State.ambiguous, h.ended.get(40).?);
}

test "W9d②: 판정 — 넘침(dataReceived 합 > 1 MiB, 스크립트도), 글 아님, 빈 본문, 끊김·실패, 설정 끔에 덮이지 않음, 메모리 캐시는 짝을 찾지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const Case = struct { req: u64, mime: []const u8, bytes: u64, fail: bool = false, covered: bool = true, want: ?State };
    const cases = [_]Case{
        .{ .req = 1, .mime = "application/javascript", .bytes = msg.max_net_body_bytes + 1, .want = .over_cap },
        .{ .req = 2, .mime = "image/png", .bytes = 900, .want = .not_text },
        .{ .req = 3, .mime = "image/png", .bytes = 0, .want = .no_body },
        .{ .req = 4, .mime = "text/plain", .bytes = 40, .fail = true, .want = .partial },
        .{ .req = 5, .mime = "", .bytes = 0, .fail = true, .want = .request_failed },
        .{ .req = 6, .mime = "text/plain", .bytes = 4, .covered = false, .want = .not_covered },
        .{ .req = 7, .mime = "text/plain", .bytes = msg.max_net_body_bytes, .want = null }, // 꼭 상한 — 받으러 간다
    };
    for (cases, 0..) |c, i| {
        const t: i64 = @intCast(10_000_000 * (i + 1));
        var ub: [32]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "https://a.test/{d}", .{c.req});
        var rb: [8]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rb, "r.{d}", .{c.req});
        _ = try h.cand(5, c.req, url, t, .{ .covered = c.covered });
        try h.sent(5, rid, url, t - 100, t);
        try h.respond(5, rid, c.mime, c.bytes, t + 10);
        if (c.fail) try h.ev(5, .{ .failed = .{ .rid = rid } }, t + 20) else try h.finish(5, rid, t + 20);
        if (c.want) |w| try testing.expectEqual(w, h.ended.get(c.req).?) else try testing.expect(h.ended.get(c.req) == null);
    }
    // 메모리 캐시에서 온 요청은 같은 주소의 CEF 요청과 짝을 짓지 않는다(J1 — CEF 가 보지 못한다).
    _ = try h.cand(5, 50, "https://a.test/cached", 100_000_000, .{});
    try h.sent(5, "mc", "https://a.test/cached", 99_999_000, 100_000_000);
    try h.ev(5, .{ .from_cache = .{ .rid = "mc" } }, 100_000_000);
    try h.finish(5, "mc", 100_000_100);
    for (h.table.tabOf(5).?.cands.items) |c| if (c.request == 50) try testing.expect(!c.claimed);
    try testing.expect(h.ended.get(50) == null);
}

test "W9d②: 동시·초당 상한 — 탭마다 2·전체 8, 자리가 나면 다음 것, 기다림이 넘치면 busy, 오래 기다리면 busy, 늦게 온 옛 세대의 결과는 버린다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    var t: i64 = 1_000_000;
    for (0..40) |i| {
        var ub: [32]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "https://a.test/q{d}", .{i});
        var rb: [8]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rb, "q.{d}", .{i});
        _ = try h.cand(5, 1000 + i, url, t, .{});
        try h.sent(5, rid, url, t - 10, t);
        try h.respond(5, rid, "text/plain", 10, t);
        try h.finish(5, rid, t);
        t += 10;
    }
    try testing.expectEqual(@as(usize, 2), h.fetches.items.len); // 탭마다 2
    try testing.expectEqual(@as(usize, max_waiting_per_tab), h.table.tabOf(5).?.waiting.items.len);
    try testing.expectEqual(@as(usize, 40 - 2 - max_waiting_per_tab), h.ends); // 넘친 것은 busy
    var it = h.ended.valueIterator();
    while (it.next()) |s| try testing.expectEqual(State.busy, s.*);
    // 하나가 돌아오면 다음 것을 보낸다.
    const f = h.table.takeInflight(h.fetches.items[0].fetch.id).?;
    try h.table.bodyDone(gpa_t, f, t);
    try h.drain();
    try testing.expectEqual(@as(usize, 3), h.fetches.items.len);
    // 오래 기다린 것은 busy.
    try h.table.tick(gpa_t, t + waiting_expiry_us + 1);
    try h.drain();
    try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.waiting.items.len);
    // 끄고 다시 켜면 보낸 호출의 결과는 버린다(세대).
    const old = h.fetches.items[2].fetch.id;
    try h.table.stop(gpa_t, 5);
    try h.drain();
    _ = try h.table.start(gpa_t, 5, 2);
    try testing.expect(h.table.takeInflight(old) == null);
}

test "W9d②: 초당 본문 수 — 20 개를 넘으면 기다린다(시간이 지나면 보낸다)" {
    var h: H = .{};
    defer h.deinit();
    for (1..6) |b| _ = try h.table.start(gpa_t, b, 1);
    // 다섯 탭이 하나씩 — 전체 8 자리 안. 한 탭에서 결과를 곧 돌려주며 30 개를 같은 순간에.
    var t: i64 = 5_000_000;
    var got: usize = 0;
    for (0..30) |i| {
        var ub: [32]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "https://a.test/r{d}", .{i});
        var rb: [8]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rb, "r.{d}", .{i});
        _ = try h.cand(1, 5000 + i, url, t, .{});
        try h.sent(1, rid, url, t - 10, t);
        try h.respond(1, rid, "text/plain", 10, t);
        try h.finish(1, rid, t);
        while (got < h.fetches.items.len) : (got += 1) {
            const f = h.table.takeInflight(h.fetches.items[got].fetch.id).?;
            try h.table.bodyDone(gpa_t, f, t);
            try h.drain();
        }
    }
    try testing.expectEqual(@as(usize, 20), h.fetches.items.len); // 버스트 20
    t += 500_000; // 0.5 초 — 10 개 더
    try h.table.tick(gpa_t, t);
    try h.drain();
    while (got < h.fetches.items.len) : (got += 1) {
        const f = h.table.takeInflight(h.fetches.items[got].fetch.id).?;
        try h.table.bodyDone(gpa_t, f, t);
        try h.drain();
    }
    try testing.expectEqual(@as(usize, 30), h.fetches.items.len);
}

test "W9d②: 끄기·렌더러 죽음·닫힘 — 기다림·보낸 호출·짝 없는 후보 모두 끝을 하나씩(recording_stopped·detached), 꺼진 탭은 후보를 적지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    _ = try h.cand(5, 1, "https://a.test/1", 1_000_000, .{}); // 짝 없음
    _ = try h.cand(5, 2, "https://a.test/2", 1_000_000, .{});
    try h.sent(5, "2", "https://a.test/2", 999_000, 1_000_000);
    try h.respond(5, "2", "text/plain", 3, 1_000_000);
    try h.finish(5, "2", 1_000_000); // 보낸 호출
    try h.table.rendererGone(gpa_t, 5);
    try h.drain();
    try testing.expectEqual(State.detached, h.ended.get(1).?);
    try testing.expectEqual(State.detached, h.ended.get(2).?);
    try testing.expect(h.table.recording(5)); // 기록은 그대로(J5)
    _ = try h.cand(5, 3, "https://a.test/3", 2_000_000, .{});
    try h.table.stop(gpa_t, 5);
    try h.drain();
    try testing.expectEqual(State.recording_stopped, h.ended.get(3).?);
    try testing.expect(!(try h.cand(5, 4, "https://a.test/4", 3_000_000, .{})));
    _ = try h.table.start(gpa_t, 6, 9);
    _ = try h.cand(6, 7, "https://a.test/7", 1, .{});
    try h.table.closed(gpa_t, 6);
    try h.drain();
    try testing.expectEqual(State.detached, h.ended.get(7).?);
    try testing.expect(h.table.tabOf(6) == null);
}

test "W9d②: 쏟아짐 밸브 — 초당 5000 을 2 초 넘기면 멈추고(pause 하나), 멈춘 동안은 후보를 적지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    _ = try h.cand(5, 1, "https://a.test/1", 1, .{});
    var now: i64 = 10_000_000;
    for (0..flood_events_per_s + 10) |_| try h.table.cdpEvent(gpa_t, 5, null, now);
    now += 1_000_000;
    for (0..flood_events_per_s + 10) |_| try h.table.cdpEvent(gpa_t, 5, null, now);
    try h.drain();
    try testing.expectEqual(@as(usize, 1), h.paused);
    try testing.expectEqual(State.recording_stopped, h.ended.get(1).?);
    try testing.expect(!h.table.recording(5));
    try testing.expect(!(try h.cand(5, 2, "https://a.test/2", 2, .{})));
    // 다시 켜면 풀린다.
    _ = try h.table.start(gpa_t, 5, 2);
    try testing.expect(h.table.recording(5));
}

test "W9d②: 끝은 꼭 하나 — 무작위 사건 차례(CEF·CDP 의 엇갈림, 실패·캐시, 넘김, 끄기·렌더러 죽음, 같은 번호 다시 시작·CDP 의 같은 주소 다시 보냄)에도 적은 시도마다 끝이 하나다" {
    var prng = std.Random.DefaultPrng.init(0x9d2e);
    const r = prng.random();
    for (0..60) |round| {
        var h: H = .{};
        defer h.deinit();
        _ = try h.table.start(gpa_t, 5, 1);
        var registered: std.ArrayList(u64) = .empty;
        defer registered.deinit(gpa_t);
        var now: i64 = 1_000_000;
        var next_req: u64 = 1;
        for (0..400) |_| {
            now += r.intRangeAtMost(i64, 0, 40_000);
            const url_i = r.intRangeLessThan(u8, 0, 6);
            var ub: [32]u8 = undefined;
            const url = try std.fmt.bufPrint(&ub, "https://a.test/{d}", .{url_i});
            var rb: [16]u8 = undefined;
            const rid = try std.fmt.bufPrint(&rb, "{d}.{d}", .{ round, r.intRangeLessThan(u16, 0, 40) });
            switch (r.intRangeLessThan(u8, 0, 14)) {
                0, 1 => {
                    if (try h.cand(5, next_req, url, now + r.intRangeAtMost(i64, -3000, 50_000), .{ .attr = r.intRangeAtMost(u64, 1, 2) })) try registered.append(gpa_t, next_req);
                    next_req += 1;
                },
                2 => try h.sent(5, rid, url, now, now),
                3 => try h.respond(5, rid, if (r.boolean()) "text/plain" else "image/png", r.intRangeAtMost(u64, 0, 2 << 20), now),
                4 => try h.finish(5, rid, now),
                5 => try h.ev(5, .{ .failed = .{ .rid = rid } }, now),
                6 => try h.ev(5, .{ .from_cache = .{ .rid = rid } }, now),
                7 => h.table.cefEnd(5, r.intRangeLessThan(u64, 1, next_req + 1), now),
                8 => h.table.noteDrop(5, hashUrl8(url), now),
                9 => {
                    try h.table.tick(gpa_t, now);
                    try h.drain();
                },
                10 => if (h.table.inflight.items.len > 0) {
                    const f = h.table.inflight.items[r.intRangeLessThan(usize, 0, h.table.inflight.items.len)];
                    if (h.table.takeInflight(f.id)) |got| {
                        // 결과를 받아 보냈다고 치고 끝을 낸다(부른 쪽이 하는 일).
                        try h.noteEnd(got.request, .captured);
                        try h.table.bodyDone(gpa_t, got, now);
                        try h.drain();
                    }
                },
                // 같은 번호 다시 시작(W9d① 적대 리뷰 후 × W9d②) — 앞 시도가 어디에 있든(짝 없음·기다림·보낸 호출·이미 끝남).
                12 => if (registered.items.len > 0) {
                    const req = registered.items[r.intRangeLessThan(usize, 0, registered.items.len)];
                    _ = try h.cand(5, req, url, now + r.intRangeAtMost(i64, -3000, 50_000), .{ .attr = r.intRangeAtMost(u64, 1, 2) });
                },
                // CDP 가 같은 requestId 로 같은 주소를 다시 보낸다(다시 시작 — 리다이렉트로 알린다).
                13 => try h.ev(5, .{ .will_be_sent = .{ .rid = rid, .url_hash = hashUrl8(url), .method_hash = hashMethod("GET"), .ts_us = now, .redirect = true } }, now),
                else => if (r.intRangeLessThan(u8, 0, 10) == 0) {
                    try h.table.rendererGone(gpa_t, 5);
                    try h.drain();
                },
            }
        }
        try h.table.stop(gpa_t, 5);
        try h.drain();
        for (registered.items) |req| if (h.ended.get(req) == null) return error.MissingEnd;
        var it = h.attempts.iterator();
        while (it.next()) |kv| if ((h.end_counts.get(kv.key_ptr.*) orelse 0) != kv.value_ptr.*) return error.MissingEnd;
    }
}

// ── 같은 번호 다시 시작(W9d① 적대 리뷰 후 × W9d②) ──
// 시험이 증명하는 것: CEF 가 같은 번호로 다시 시작하면(Critical-CH — 판정 `body-restart-same-id`) 앞 시도의 후보는 그 시작 안에서 끝을 꼭 하나 낸다
// (`restarted` — 짝 없음·기다림·보낸 호출 어디에 있든, 보낸 호출의 늦은 답은 버린다) — 그 끝은 새 시작의 `net_begin` 보다 먼저 나가므로 maru 는
// 번호가 같은 두 기록을 가른다. 새 시도는 새 후보다(`body_expected`). 짝은 그 시도의 CDP 요청과만: CDP 가 같은 requestId 로 같은 주소를 다시
// 보내면(실측 — 리다이렉트로 알린다) 그 요청의 시작은 다시 보낸 때이고, 그 전에 끝나도 앞 시도의 후보와 짓지 않는다(새 후보를 기다린다). 다른
// requestId 로 보이는 앞 시도의 CDP 요청은 새 후보와 짓지 않는다. 브라우저 탭에서 중요한 이유 — 확인 페이지(403)의 본문과 다시 시작한 이동의
// 진짜 페이지 본문이 서로의 기록에 붙으면 에이전트는 다른 응답을 그 요청의 것으로 읽는다.

fn stateIs(h: *const H, request: u64, want: State) bool {
    const s = h.ended.get(request) orelse return false;
    return s == want;
}

fn endCount(h: *const H, request: u64) u32 {
    return h.end_counts.get(request) orelse 0;
}

const cch = "https://so.test/q";

test "W9d② × 다시 시작 S1: 실측 꼴 — CEF 시작·CDP 가 같은 requestId 로 같은 주소를 다시 보냄·CEF 끝·같은 번호 시작 — 앞 시도는 그 시작 안에서 restarted 하나, 새 시도의 본문을 받는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const t0: i64 = 249_909_872_356;
    try h.sent(5, "R", cch, t0, t0);
    try testing.expect(try h.cand(5, 9, cch, t0 + 2_144, .{}));
    try h.ev(5, .{ .will_be_sent = .{ .rid = "R", .url_hash = hashUrl8(cch), .method_hash = hashMethod("GET"), .ts_us = t0 + 196_641, .redirect = true } }, t0 + 196_674);
    try h.respond(5, "R", "text/html", 50, t0 + 197_000);
    h.table.cefEnd(5, 9, t0 + 207_548);
    // 같은 번호의 시작 — 앞 시도의 끝은 이 시작 안에서 나간다(새 `net_begin` 보다 먼저).
    try testing.expect(try h.cand(5, 9, cch, t0 + 197_191, .{}));
    try testing.expectEqual(@as(u32, 1), endCount(&h, 9));
    try testing.expect(stateIs(&h, 9, .restarted));
    try testing.expectEqual(@as(usize, 1), h.table.tabOf(5).?.cands.items.len);
    try h.finish(5, "R", t0 + 221_229);
    var buf: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{9}, h.fetchedRequests(&buf));
    try testing.expectEqualStrings("R", h.fetches.items[0].fetch.rid.slice());
    const f = h.table.takeInflight(h.fetches.items[0].fetch.id).?;
    try h.noteEnd(f.request, .captured);
    try h.table.bodyDone(gpa_t, f, t0 + 230_000);
    try h.drain();
    try testing.expectEqual(@as(u32, 2), endCount(&h, 9));
    try testing.expect(!h.table.busy());
}

test "W9d② × 다시 시작 S2: CDP 끝이 같은 번호의 새 시작보다 먼저 와도 앞 시도의 후보와 짓지 않는다 — 새 후보가 오면 짓는다, 오지 않으면 놓는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const t0: i64 = 10_000_000;
    try h.sent(5, "R", cch, t0, t0);
    try testing.expect(try h.cand(5, 9, cch, t0 + 2_000, .{}));
    try h.ev(5, .{ .will_be_sent = .{ .rid = "R", .url_hash = hashUrl8(cch), .method_hash = hashMethod("GET"), .ts_us = t0 + 196_000, .redirect = true } }, t0 + 196_100);
    try h.respond(5, "R", "text/html", 50, t0 + 197_000);
    h.table.cefEnd(5, 9, t0 + 200_000);
    try h.finish(5, "R", t0 + 205_000);
    try testing.expectEqual(@as(usize, 0), h.fetches.items.len); // 앞 시도의 후보(t0+2ms)는 다시 보낸 때(t0+196ms)의 창 밖
    try testing.expect(try h.cand(5, 9, cch, t0 + 196_500, .{}));
    try testing.expect(stateIs(&h, 9, .restarted));
    try h.table.tick(gpa_t, t0 + 215_000);
    try h.drain();
    var buf: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{9}, h.fetchedRequests(&buf));
    // 새 시작이 오지 않으면(처리기가 다시 시작을 다음 홉으로 봤다 — 시작을 보내지 않는다) CDP 요청은 시한 뒤 놓고 앞 후보는 unmatched.
    var g: H = .{};
    defer g.deinit();
    _ = try g.table.start(gpa_t, 5, 1);
    try g.sent(5, "R", cch, t0, t0);
    try testing.expect(try g.cand(5, 9, cch, t0 + 2_000, .{}));
    try g.ev(5, .{ .will_be_sent = .{ .rid = "R", .url_hash = hashUrl8(cch), .method_hash = hashMethod("GET"), .ts_us = t0 + 196_000, .redirect = true } }, t0 + 196_100);
    try g.finish(5, "R", t0 + 205_000);
    g.table.cefEnd(5, 9, t0 + 206_000);
    try g.table.tick(gpa_t, t0 + 206_000 + unclaimed_expiry_us);
    try g.drain();
    try testing.expectEqual(@as(usize, 0), g.fetches.items.len);
    try testing.expect(stateIs(&g, 9, .unmatched));
    try testing.expect(!g.table.busy());
}

test "W9d② × 다시 시작 S3: 앞 시도의 본문을 받는 중(보낸 호출)이면 restarted 로 곧 끝내고 늦은 답은 버린다 — 다른 requestId 로 보인 앞 시도의 CDP 요청은 새 후보와 짓지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const t0: i64 = 20_000_000;
    // ① 보낸 호출.
    try h.sent(5, "A1", cch, t0, t0);
    try testing.expect(try h.cand(5, 9, cch, t0 + 1_500, .{}));
    try h.respond(5, "A1", "text/html", 20, t0 + 50_000);
    try h.finish(5, "A1", t0 + 60_000);
    try testing.expectEqual(@as(usize, 1), h.fetches.items.len);
    const old_id = h.fetches.items[0].fetch.id;
    try testing.expect(try h.cand(5, 9, cch, t0 + 300_000, .{}));
    try testing.expect(stateIs(&h, 9, .restarted));
    try testing.expectEqual(@as(u32, 1), endCount(&h, 9));
    try testing.expect(h.table.takeInflight(old_id) == null); // 늦은 답은 버린다
    try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.inflight);
    try h.sent(5, "A2", cch, t0 + 299_400, t0 + 299_500);
    try h.respond(5, "A2", "text/html", 30, t0 + 310_000);
    try h.finish(5, "A2", t0 + 320_000);
    try testing.expectEqual(@as(usize, 2), h.fetches.items.len);
    try testing.expectEqualStrings("A2", h.fetches.items[1].fetch.rid.slice());
    // ② 앞 시도의 CDP 요청(다른 requestId)이 새 시작 뒤에 끝난다 — 새 후보와 짓지 않는다.
    var g: H = .{};
    defer g.deinit();
    _ = try g.table.start(gpa_t, 5, 1);
    try g.sent(5, "B1", cch, t0, t0);
    try testing.expect(try g.cand(5, 9, cch, t0 + 1_500, .{}));
    try testing.expect(try g.cand(5, 9, cch, t0 + 300_000, .{}));
    try testing.expect(stateIs(&g, 9, .restarted));
    try g.respond(5, "B1", "text/html", 20, t0 + 301_000);
    try g.finish(5, "B1", t0 + 302_000);
    try testing.expectEqual(@as(usize, 0), g.fetches.items.len);
    try g.table.tick(gpa_t, t0 + 302_000 + cef_grace_us);
    try g.drain();
    try g.sent(5, "B2", cch, t0 + 299_500, t0 + 600_000);
    try g.respond(5, "B2", "text/html", 30, t0 + 610_000);
    try g.finish(5, "B2", t0 + 620_000);
    try testing.expectEqual(@as(usize, 1), g.fetches.items.len);
    try testing.expectEqualStrings("B2", g.fetches.items[0].fetch.rid.slice());
}

test "W9d② × 다시 시작 S4: 앞 시도가 자리를 기다리면(동시 상한) restarted 로 끝내고 기다림에서 뺀다 — 자리가 나도 앞 시도의 본문을 받으러 가지 않는다" {
    var h: H = .{};
    defer h.deinit();
    _ = try h.table.start(gpa_t, 5, 1);
    const t0: i64 = 30_000_000;
    // 다른 둘이 탭의 자리(2)를 쥔다.
    for (0..2) |i| {
        var ub: [32]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "https://a.test/o{d}", .{i});
        var rb: [8]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rb, "o.{d}", .{i});
        _ = try h.cand(5, 100 + i, url, t0, .{});
        try h.sent(5, rid, url, t0 - 10, t0);
        try h.respond(5, rid, "text/plain", 10, t0);
        try h.finish(5, rid, t0);
    }
    try h.sent(5, "W", cch, t0, t0);
    _ = try h.cand(5, 9, cch, t0 + 1_000, .{});
    try h.respond(5, "W", "text/html", 10, t0 + 2_000);
    try h.finish(5, "W", t0 + 3_000);
    try testing.expectEqual(@as(usize, 1), h.table.tabOf(5).?.waiting.items.len);
    try testing.expect(try h.cand(5, 9, cch, t0 + 200_000, .{}));
    try testing.expect(stateIs(&h, 9, .restarted));
    try testing.expectEqual(@as(usize, 0), h.table.tabOf(5).?.waiting.items.len);
    const f = h.table.takeInflight(h.fetches.items[0].fetch.id).?;
    try h.noteEnd(f.request, .captured);
    try h.table.bodyDone(gpa_t, f, t0 + 210_000);
    try h.drain();
    try testing.expectEqual(@as(usize, 2), h.fetches.items.len); // 앞 시도(W)는 받으러 가지 않는다
    try testing.expectEqual(@as(u32, 1), endCount(&h, 9));
}
