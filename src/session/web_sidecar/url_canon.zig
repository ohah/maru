//! 주소의 Chromium 꼴(GURL 정규화)을 흉내 낸 순수 규칙(W9d③ 20 회 검증 — docs/plans/web-osr-backend.md 「W9d③ 결정·실측」) — sidecar 와 maru 가
//! 같은 파일을 쓴다. 쓰는 곳이 둘이다:
//!   - **D2 토큰의 주소 비교**(`hash` — sidecar `net_block_table.canonHash`): 사용자가 주소창에 친 글(u8)과 `on_before_browse` 가 주는 GURL 꼴(u16)이
//!     같은 이동이면 같은 값이어야 한다. 전에는 스킴·호스트 소문자·기본 포트·빈 경로만 맞춰, Chromium 이 고쳐 쓰는 꼴(빈칸 → `%20`, `/x/../y` →
//!     `/y`, `"` → `%22`, `\` → `/`, `a.test?q` → `a.test/?q`, `127.1` → `127.0.0.1`)을 친 사용자의 이동이 막혔다(20 회 검증 A LOW-4 — 9 꼴 중 6 꼴).
//!     그래서 같은 함수를 **양쪽에** 쓴다: GURL 꼴은 이미 정규라 그대로 지나가고(멱등), 친 글은 GURL 이 하는 대로 고쳐진다. 고칠지 애매한 글자
//!     (`{`·`}`·`|`·`^`·쿼리의 `'`)는 양쪽에서 똑같이 `%XX` 로 바꾸므로 GURL 이 어느 쪽을 택해도 같은 값이 된다. 남은 틈(문서화): 국제화 호스트
//!     (punycode 로 바뀐다), 4 KiB 넘는 경로의 점 조각.
//!   - **패턴 호스트 검사**(`ipv4`·`ipv6` — maru·sidecar 의 `net_block.parse`): GURL 은 IP 호스트를 한 꼴로 바꾸므로(`0x7f.0.0.1`·`2130706433`·
//!     `127.1` → `127.0.0.1`, `[0:0::1]` → `[::1]`) 다른 꼴로 쓴 패턴은 어느 주소에도 맞지 않는다 — 말없이 받지 않고 거절한다(20 회 검증 A N2).
//!
//! IP 규칙의 출처: WHATWG URL Standard 의 IPv4 파서(「ends in a number」 — 10·8(앞 0)·16(`0x`) 진수, 1–4 조각, 마지막 조각이 남은 바이트를 채운다)와
//! IPv6 직렬화(RFC 5952 — 소문자, 앞 0 없음, 둘 이상 이어진 0 조각 중 가장 긴 첫 자리를 `::`, 끼운 IPv4 도 16 진 조각). Chromium `url_canon_ip` 가 같은
//! 규칙을 따른다(실측: 판정자 `--network-block` 의 `block-url-forms` — `0x7f.0.0.1`·`2130706433`·`127.1`·`0177.0.0.1` 이 모두 127.0.0.1 로 막혔다).
//!
//! 시험이 증명하는 것: 20 회 검증 A 의 9 꼴(친 글과 GURL 꼴이 같은 값), GURL 꼴의 멱등, 다른 주소는 다른 값(경로·쿼리·포트·호스트), IPv4 의 진수·
//! 조각 수·범위·실패, IPv6 의 줄임·끼운 IPv4·정규 꼴 판정.

const std = @import("std");

/// 점 조각을 풀 때 쓰는 경로 자리(넘으면 풀지 않고 그대로 잰다 — 문서화된 틈).
pub const max_resolve_bytes: usize = 4096;

// ── IPv4 ─────────────────────────────────────────────────────────────────────────────────────────────────

pub const Ipv4 = union(enum) {
    /// IPv4 호스트가 아니다(마지막 조각이 수가 아니다 — 이름이다).
    not_ip,
    /// IPv4 로 읽어야 하는데 틀렸다(GURL 은 그 주소를 거절한다).
    invalid,
    ok: u32,
};

/// 조각 하나를 수로(10·8·16 진). 빈 글이나 글자가 틀리면 null.
fn ipv4Number(comptime T: type, part: []const T) ?u64 {
    if (part.len == 0) return null;
    var digits = part;
    var radix: u8 = 10;
    if (digits.len >= 2 and digits[0] == '0' and (digits[1] == 'x' or digits[1] == 'X')) {
        radix = 16;
        digits = digits[2..];
        if (digits.len == 0) return 0;
    } else if (digits.len >= 2 and digits[0] == '0') {
        radix = 8;
        digits = digits[1..];
    }
    var v: u64 = 0;
    for (digits) |u| {
        if (u > 0x7f) return null;
        const d = std.fmt.charToDigit(@intCast(u), radix) catch return null;
        v = v * radix + d;
        if (v > 0xffff_ffff) return std.math.maxInt(u64); // 넘침 — 범위 검사가 거절한다
    }
    return v;
}

/// 호스트(대괄호 밖)를 IPv4 로 읽는다 — URL Standard 의 「ends in a number」 규칙.
pub fn ipv4(comptime T: type, host: []const T) Ipv4 {
    if (host.len == 0) return .not_ip;
    // 끝 점 하나는 뗀다(`127.0.0.1.` — 조각이 둘 이상일 때).
    const trimmed = if (host[host.len - 1] == '.' and std.mem.indexOfScalar(T, host[0 .. host.len - 1], '.') != null) host[0 .. host.len - 1] else host;
    const last = if (std.mem.lastIndexOfScalar(T, trimmed, '.')) |k| trimmed[k + 1 ..] else trimmed;
    const all_digits = last.len > 0 and for (last) |u| {
        if (u < '0' or u > '9') break false;
    } else true;
    if (!all_digits and ipv4Number(T, last) == null) return .not_ip;
    var nums: [4]u64 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(T, trimmed, '.');
    while (it.next()) |p| {
        if (n == nums.len) return .invalid;
        nums[n] = ipv4Number(T, p) orelse return .invalid;
        n += 1;
    }
    for (nums[0 .. n - 1]) |v| if (v > 255) return .invalid;
    const shift: u6 = @intCast(8 * (5 - n));
    if (nums[n - 1] >= (@as(u64, 1) << shift)) return .invalid;
    var addr: u64 = nums[n - 1];
    for (nums[0 .. n - 1], 0..) |v, i| addr += v << @intCast(8 * (3 - i));
    return .{ .ok = @intCast(addr) };
}

/// 점 넷의 10 진 꼴(GURL 이 주는 꼴).
pub fn ipv4Text(addr: u32, buf: *[15]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ addr >> 24, (addr >> 16) & 0xff, (addr >> 8) & 0xff, addr & 0xff }) catch unreachable;
}

// ── IPv6 ─────────────────────────────────────────────────────────────────────────────────────────────────

/// 대괄호 안의 글을 여덟 조각으로. 틀리면 null.
pub fn ipv6(comptime T: type, inner: []const T) ?[8]u16 {
    var out: [8]u16 = @splat(0);
    if (inner.len == 0) return null;
    var head: [8]u16 = undefined;
    var head_n: usize = 0;
    var tail: [8]u16 = undefined;
    var tail_n: usize = 0;
    var compressed = false;
    var i: usize = 0;
    if (inner.len >= 2 and inner[0] == ':' and inner[1] == ':') {
        compressed = true;
        i = 2;
    } else if (inner[0] == ':') return null;
    while (i < inner.len) {
        // 끼운 IPv4(마지막 32 비트)?
        var j = i;
        while (j < inner.len and inner[j] != ':') j += 1;
        const piece = inner[i..j];
        const has_dot = for (piece) |u| {
            if (u == '.') break true;
        } else false;
        const dst = if (compressed) &tail else &head;
        const dn = if (compressed) &tail_n else &head_n;
        if (has_dot) {
            if (j != inner.len) return null;
            // 끼운 IPv4 는 10 진 점 넷만(URL Standard).
            var q: [4]u16 = undefined;
            var qn: usize = 0;
            var it = std.mem.splitScalar(T, piece, '.');
            while (it.next()) |d| {
                if (qn == 4 or d.len == 0 or d.len > 3) return null;
                if (d.len > 1 and d[0] == '0') return null;
                var v: u16 = 0;
                for (d) |u| {
                    if (u < '0' or u > '9') return null;
                    v = v * 10 + @as(u16, @intCast(u - '0'));
                }
                if (v > 255) return null;
                q[qn] = v;
                qn += 1;
            }
            if (qn != 4 or dn.* + 2 > 8) return null;
            dst[dn.*] = (q[0] << 8) | q[1];
            dst[dn.* + 1] = (q[2] << 8) | q[3];
            dn.* += 2;
            i = j;
            break;
        }
        if (piece.len == 0 or piece.len > 4) return null;
        var v: u16 = 0;
        for (piece) |u| {
            if (u > 0x7f) return null;
            v = v * 16 + (std.fmt.charToDigit(@intCast(u), 16) catch return null);
        }
        if (dn.* == 8) return null;
        dst[dn.*] = v;
        dn.* += 1;
        i = j;
        if (i == inner.len) break;
        // `:` 하나 또는 `::`.
        i += 1;
        if (i < inner.len and inner[i] == ':') {
            if (compressed) return null;
            compressed = true;
            i += 1;
            if (i == inner.len) break;
        } else if (i == inner.len) return null; // 끝의 `:` 하나
    }
    if (compressed) {
        if (head_n + tail_n > 7) return null;
        for (head[0..head_n], 0..) |v, k| out[k] = v;
        for (tail[0..tail_n], 0..) |v, k| out[8 - tail_n + k] = v;
    } else {
        if (head_n != 8) return null;
        out = head;
    }
    return out;
}

/// RFC 5952 꼴(대괄호 없이) — 소문자, 앞 0 없음, 둘 이상 이어진 0 조각 중 가장 긴(같으면 앞) 자리를 `::`.
pub fn ipv6Text(groups: [8]u16, buf: *[39]u8) []const u8 {
    var best_start: usize = 8;
    var best_len: usize = 0;
    var k: usize = 0;
    while (k < 8) {
        if (groups[k] != 0) {
            k += 1;
            continue;
        }
        var e = k;
        while (e < 8 and groups[e] == 0) e += 1;
        if (e - k > best_len) {
            best_start = k;
            best_len = e - k;
        }
        k = e;
    }
    if (best_len < 2) best_start = 8;
    var w: std.Io.Writer = .fixed(buf);
    var g: usize = 0;
    while (g < 8) {
        if (g == best_start) {
            w.writeAll("::") catch unreachable;
            g += best_len;
            continue;
        }
        if (g != 0 and g != best_start + best_len) w.writeAll(":") catch unreachable;
        w.print("{x}", .{groups[g]}) catch unreachable;
        g += 1;
    }
    return w.buffered();
}

// ── 주소 해시(D2) ────────────────────────────────────────────────────────────────────────────────────────

fn isHexUnit(comptime T: type, u: T) bool {
    return u <= 0x7f and std.ascii.isHex(@intCast(u));
}

fn upperHex(comptime T: type, u: T) u8 {
    return std.ascii.toUpper(@intCast(u));
}

/// 경로에서 `%XX` 로 바꾸는 글자 — GURL 이 바꾸는 것(제어·빈칸·`"`·`<`·`>`·`` ` ``·`{`·`}`·DEL·ASCII 밖)과 애매한 `|`·`^`(양쪽이 같이 바꿔 상관없다).
fn pathEscapes(c: u32) bool {
    return c <= 0x20 or c >= 0x7f or switch (c) {
        '"', '<', '>', '`', '{', '}', '|', '^' => true,
        else => false,
    };
}

/// 쿼리에서 `%XX` 로 바꾸는 글자 — 제어·빈칸·`"`·`<`·`>`·DEL·ASCII 밖, 그리고 애매한 `'`(특수 스킴의 쿼리 — 양쪽이 같이 바꾼다).
fn queryEscapes(c: u32) bool {
    return c <= 0x20 or c >= 0x7f or switch (c) {
        '"', '<', '>', '\'' => true,
        else => false,
    };
}

/// 정규 바이트를 받는 쪽 — 해시에 흘리거나(`buf` 없음 — 작은 자리에 모아 덩어리로 넣는다: IO 스레드가 2 MiB 주소를 바이트마다 넣지 않게)
/// 버퍼에 모은다(점 조각을 풀 경로).
const Sink = struct {
    h: *std.hash.Wyhash,
    buf: ?[]u8 = null,
    len: usize = 0,
    over: bool = false,
    stage: [256]u8 = undefined,
    staged: usize = 0,

    fn byte(self: *Sink, b: u8) void {
        if (self.buf) |buf| {
            if (self.len == buf.len) {
                self.over = true;
                return;
            }
            buf[self.len] = b;
            self.len += 1;
            return;
        }
        if (self.staged == self.stage.len) self.flush();
        self.stage[self.staged] = b;
        self.staged += 1;
    }

    fn flush(self: *Sink) void {
        self.h.update(self.stage[0..self.staged]);
        self.staged = 0;
    }

    fn escaped(self: *Sink, b: u8) void {
        const hex = "0123456789ABCDEF";
        self.byte('%');
        self.byte(hex[b >> 4]);
        self.byte(hex[b & 0xf]);
    }
};

/// 단위 하나를 정규 바이트로(바꿀 글자는 `%XX` — u16 의 ASCII 밖 단위는 UTF-8 로 바꾼 바이트마다).
fn emitUnit(comptime T: type, sink: *Sink, u: T, escapes: *const fn (u32) bool) void {
    const c: u32 = u;
    if (!escapes(c)) return sink.byte(@intCast(c));
    if (T == u8 or c < 0x80) return sink.escaped(@intCast(c & 0xff));
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(c), &tmp) catch {
        sink.escaped(@intCast(c >> 8));
        sink.escaped(@intCast(c & 0xff));
        return;
    };
    for (tmp[0..n]) |b| sink.escaped(b);
}

/// 경로·쿼리 글(조각 뺀)을 정규 바이트로 흘린다 — 기존 `%xx` 는 대문자로, 경로의 `\` 는 `/` 로.
fn emitRange(comptime T: type, sink: *Sink, text: []const T, in_query: bool) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const u = text[i];
        if (u == '%' and i + 2 < text.len and isHexUnit(T, text[i + 1]) and isHexUnit(T, text[i + 2])) {
            sink.byte('%');
            sink.byte(upperHex(T, text[i + 1]));
            sink.byte(upperHex(T, text[i + 2]));
            i += 2;
            continue;
        }
        if (!in_query and u == '\\') {
            sink.byte('/');
            continue;
        }
        emitUnit(T, sink, u, if (in_query) &queryEscapes else &pathEscapes);
    }
}

/// 조각이 점 하나(`.`·`%2E`)인가, 둘(`..`·`.%2E`·`%2E.`·`%2E%2E`)인가 — 정규 바이트(대문자 이스케이프) 위에서.
fn dotKind(seg: []const u8) u2 {
    if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "%2E")) return 1;
    if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".%2E") or std.mem.eql(u8, seg, "%2E.") or std.mem.eql(u8, seg, "%2E%2E")) return 2;
    return 0;
}

/// 정규 바이트 경로(`/` 로 시작)의 점 조각을 푼다(RFC 3986 remove_dot_segments — GURL 과 같다). 제자리에서, 새 길이를 돌려준다.
fn resolveDots(path: []u8) usize {
    var out: usize = 0; // path[0..out] 이 지금까지의 결과
    var i: usize = 0;
    while (i < path.len) {
        // 조각 하나: path[i] == '/' 다음부터 다음 '/' 앞까지.
        var j = i + 1;
        while (j < path.len and path[j] != '/') j += 1;
        const seg = path[i + 1 .. j];
        const last = j == path.len;
        switch (dotKind(seg)) {
            1 => {
                if (last) {
                    path[out] = '/';
                    out += 1;
                }
            },
            2 => {
                // 앞 조각 하나를 지운다.
                while (out > 0) {
                    out -= 1;
                    if (path[out] == '/') break;
                }
                if (last) {
                    path[out] = '/';
                    out += 1;
                }
            },
            else => {
                std.mem.copyForwards(u8, path[out..], path[i..j]);
                out += j - i;
            },
        }
        i = j;
    }
    if (out == 0) {
        path[0] = '/';
        out = 1;
    }
    return out;
}

/// 경로에 점 조각이나 `\` 가 있는가(없으면 버퍼 없이 바로 흘린다 — GURL 꼴은 늘 여기).
fn needsResolve(comptime T: type, path: []const T) bool {
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '\\') return true;
        if (path[i] != '/') {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < path.len and path[j] != '/' and path[j] != '\\') j += 1;
        const seg = path[i + 1 .. j];
        if (seg.len >= 1 and seg.len <= 6) {
            var tmp: [6]u8 = undefined;
            var ok = true;
            for (seg, 0..) |u, k| {
                if (u > 0x7f) ok = false else tmp[k] = std.ascii.toUpper(@intCast(u));
            }
            if (ok and dotKind(tmp[0..seg.len]) != 0) return true;
        }
        i = j;
    }
    return false;
}

/// http(s) 주소의 부분(정규화 전 — 권한은 `/`·`\`·`?`·`#` 에서 끝난다: 특수 스킴은 `\` 를 `/` 로 읽는다).
fn Parts(comptime T: type) type {
    return struct { https: bool, host: []const T, port: u16, path: []const T, query: ?[]const T };
}

fn split(comptime T: type, url: []const T) ?Parts(T) {
    var colon: usize = 0;
    while (colon < url.len and colon < 8 and url[colon] != ':') colon += 1;
    if (colon >= url.len or url[colon] != ':') return null;
    const https = eqlIgnoreCase(T, url[0..colon], "https");
    if (!https and !eqlIgnoreCase(T, url[0..colon], "http")) return null;
    var a = colon + 1;
    // 특수 스킴은 `//`·`\\`·`/\` 를 모두 받는다.
    var slashes: usize = 0;
    while (a < url.len and slashes < 2 and (url[a] == '/' or url[a] == '\\')) : (a += 1) slashes += 1;
    if (slashes != 2) return null;
    var a_end = a;
    while (a_end < url.len and url[a_end] != '/' and url[a_end] != '\\' and url[a_end] != '?' and url[a_end] != '#') a_end += 1;
    var h_start = a;
    for (url[a..a_end], a..) |u, k| if (u == '@') {
        h_start = k + 1;
    };
    var h_end = a_end;
    var port: u16 = if (https) 443 else 80;
    var j = a_end;
    while (j > h_start) {
        j -= 1;
        if (url[j] == ']') break;
        if (url[j] == ':') {
            var v: u32 = 0;
            for (url[j + 1 .. a_end]) |u| {
                if (u < '0' or u > '9') return null;
                v = v * 10 + @as(u32, @intCast(u - '0'));
                if (v > 65535) return null;
            }
            if (j + 1 < a_end) port = @intCast(v);
            h_end = j;
            break;
        }
    }
    var end = a_end;
    while (end < url.len and url[end] != '#') end += 1;
    const rest = url[a_end..end];
    const q = std.mem.indexOfScalar(T, rest, '?');
    return .{
        .https = https,
        .host = url[h_start..h_end],
        .port = port,
        .path = if (q) |k| rest[0..k] else rest,
        .query = if (q) |k| rest[k + 1 ..] else null,
    };
}

fn eqlIgnoreCase(comptime T: type, units: []const T, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |u, ch| {
        const l: T = if (u >= 'A' and u <= 'Z') u + 32 else u;
        if (l != ch) return false;
    }
    return true;
}

/// GURL 꼴로 맞춘 주소의 해시(스킴·호스트·포트·경로·쿼리 — 사용자 정보·조각은 뺀다). http(s) 가 아니면 null(부른 쪽이 단위 그대로 잰다).
pub fn hash(comptime T: type, seed: u64, url: []const T) ?u64 {
    const parts = split(T, url) orelse return null;
    var h = std.hash.Wyhash.init(seed);
    h.update(if (parts.https) "s" else "p");
    // 호스트의 `%XX` 는 GURL 이 먼저 푼다(`127.0.0.%31` → `127.0.0.1`, `%41.test` → `a.test` — 2 차 검증 N-A2-3: 친 이동이 예외를 잃었다). 푼 글이
    // ASCII 가 아니거나 이스케이프가 틀렸으면 그 글 그대로 잰다(국제화 호스트 — 문서화된 틈, 틀린 꼴은 GURL 이 거절해 이동이 없다).
    var decoded: [max_host_decode]u8 = undefined;
    if (decodeHost(T, parts.host, &decoded)) |d| {
        hashHost(u8, &h, d);
    } else hashHost(T, &h, parts.host);
    h.update(std.mem.asBytes(&parts.port));
    h.update("/");
    // 경로 — 비면 `/`(권한 다음은 늘 `/`·`\\`·`?`·`#` 라 경로가 있으면 `/`·`\\` 로 시작한다).
    var sink: Sink = .{ .h = &h };
    if (parts.path.len == 0) {
        sink.byte('/');
    } else if (needsResolve(T, parts.path)) {
        var buf: [max_resolve_bytes]u8 = undefined;
        var b: Sink = .{ .h = &h, .buf = &buf };
        emitRange(T, &b, parts.path, false);
        if (b.over) {
            emitRange(T, &sink, parts.path, false); // 너무 길다 — 풀지 않고 잰다(문서화된 틈)
        } else {
            sink.flush();
            const n = resolveDots(buf[0..b.len]);
            h.update(buf[0..n]);
        }
    } else emitRange(T, &sink, parts.path, false);
    if (parts.query) |q| {
        sink.byte('?');
        emitRange(T, &sink, q, true);
    }
    sink.flush();
    return h.final();
}

/// 호스트 — IP 는 값으로, 이름은 소문자·끝 점 뗌.
fn hashHost(comptime T: type, h: *std.hash.Wyhash, raw: []const T) void {
    var host = raw;
    if (host.len > 0 and host[host.len - 1] == '.' and host[0] != '[') host = host[0 .. host.len - 1];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        if (ipv6(T, host[1 .. host.len - 1])) |g| {
            h.update("6");
            for (g) |v| h.update(std.mem.asBytes(&v));
        } else for (host) |u| h.update(std.mem.asBytes(&@as(u16, u)));
    } else switch (ipv4(T, host)) {
        .ok => |v| {
            h.update("4");
            h.update(std.mem.asBytes(&v));
        },
        else => {
            h.update("n");
            for (host) |u| {
                const l: u16 = if (u >= 'A' and u <= 'Z') @as(u16, u) + 32 else @as(u16, u);
                h.update(std.mem.asBytes(&l));
            }
        },
    }
}

/// 호스트의 `%XX` 를 푼 ASCII 글(퍼센트가 없거나, 틀렸거나, 푼 바이트가 ASCII 가 아니거나, 너무 길면 null — 부른 쪽은 그 글 그대로 잰다).
fn decodeHost(comptime T: type, host: []const T, out: *[max_host_decode]u8) ?[]const u8 {
    if (std.mem.indexOfScalar(T, host, '%') == null) return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < host.len) : (i += 1) {
        if (n == out.len) return null;
        const u = host[i];
        if (u > 0x7f) return null;
        if (u == '%') {
            if (i + 2 >= host.len or !isHexUnit(T, host[i + 1]) or !isHexUnit(T, host[i + 2])) return null;
            const v = (std.fmt.charToDigit(@intCast(host[i + 1]), 16) catch unreachable) * 16 + (std.fmt.charToDigit(@intCast(host[i + 2]), 16) catch unreachable);
            if (v >= 0x80 or v == '%') return null;
            out[n] = v;
            i += 2;
        } else out[n] = @intCast(u);
        n += 1;
    }
    return out[0..n];
}

const max_host_decode: usize = 256;

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn utf16(comptime s: []const u8) [s.len]u16 {
    var out: [s.len]u16 = undefined;
    for (s, 0..) |ch, i| out[i] = ch;
    return out;
}

fn same(typed: []const u8, comptime gurl: []const u8) !void {
    const a = hash(u8, 1, typed) orelse return error.TestUnexpectedResult;
    const g16 = utf16(gurl);
    const b = hash(u16, 1, &g16) orelse return error.TestUnexpectedResult;
    if (a != b) {
        std.debug.print("typed {s} and GURL {s} differ\n", .{ typed, gurl });
        return error.TestUnexpectedResult;
    }
    // GURL 꼴은 이미 정규 — u8 로 넣어도 같은 값(멱등).
    try testing.expectEqual(b, hash(u8, 1, gurl).?);
}

test "W9d③ 20 회 검증 A LOW-4: 사용자가 친 아홉 꼴과 Chromium 이 고쳐 쓴 꼴(GURL)이 같은 값 — 그래서 그 이동이 D2 예외를 받는다" {
    try same("HTTP://A.TEST:80/x", "http://a.test/x");
    try same("https://a.test", "https://a.test/");
    try same("https://a.test/x#frag", "https://a.test/x#frag");
    try same("https://a.test/a b", "https://a.test/a%20b");
    try same("https://a.test/x/../y", "https://a.test/y");
    try same("https://a.test?q=1", "https://a.test/?q=1");
    try same("http://127.1/x", "http://127.0.0.1/x");
    try same("https://a.test/\"q\"", "https://a.test/%22q%22");
    try same("https://a.test/a\\b", "https://a.test/a/b");
    // 더: 점 조각의 이스케이프 꼴·끝의 점 조각·쿼리의 빈칸·ASCII 밖 경로·IPv6 줄임·10 진 IPv4·사용자 정보.
    try same("https://a.test/a/%2e%2E/b/./c/.", "https://a.test/b/c/");
    try same("https://a.test/a/b/..", "https://a.test/a/");
    try same("https://a.test/p?q=a b\"<>", "https://a.test/p?q=a%20b%22%3C%3E");
    try same("https://a.test/한", "https://a.test/%ED%95%9C");
    try same("http://[0:0::1]:8080/", "http://[::1]:8080/");
    try same("http://2130706433/", "http://127.0.0.1/");
    try same("http://user:pw@a.test/x", "http://a.test/x");
    try same("http:\\\\a.test\\x", "http://a.test/x");
    // 2 차 검증 N-A2-3: 호스트의 `%XX` 는 GURL 이 먼저 푼다.
    try same("http://127.0.0.%31:8080/x", "http://127.0.0.1:8080/x");
    try same("http://%41.Test/x", "http://a.test/x");
}

test "W9d③ 20 회 검증 A LOW-4: 다른 주소는 다른 값 — 경로·쿼리·포트·호스트·스킴, 경로의 `%2F` 는 `/` 가 아니다" {
    const pairs = [_][2][]const u8{
        .{ "https://a.test/x", "https://a.test/y" },
        .{ "https://a.test/x", "https://a.test/x?" },
        .{ "https://a.test/x?a=1", "https://a.test/x?a=2" },
        .{ "https://a.test:8443/x", "https://a.test/x" },
        .{ "https://a.test/x", "http://a.test/x" },
        .{ "https://a.test/x", "https://b.test/x" },
        .{ "https://a.test/a%2Fb", "https://a.test/a/b" },
        .{ "http://127.0.0.1/", "http://127.0.0.2/" },
        .{ "https://a.test/x/..y", "https://a.test/" },
    };
    for (pairs) |p| try testing.expect(hash(u8, 1, p[0]).? != hash(u8, 1, p[1]).?);
    try testing.expect(hash(u8, 1, "data:text/html,x") == null);
}

test "W9d③ 20 회 검증: IPv4 — 진수·조각 수·범위·이름(끝이 수가 아니다)·실패(GURL 이 거절하는 꼴)" {
    const Case = struct { []const u8, ?u32 };
    for ([_]Case{
        .{ "127.0.0.1", 0x7f000001 },       .{ "0x7f.0.0.1", 0x7f000001 }, .{ "0177.0.0.1", 0x7f000001 }, .{ "2130706433", 0x7f000001 },
        .{ "127.1", 0x7f000001 },           .{ "127.0.1", 0x7f000001 },    .{ "127.0.0.1.", 0x7f000001 }, .{ "0x", 0 },
        .{ "255.255.255.255", 0xffffffff },
    }) |c| try testing.expectEqual(Ipv4{ .ok = c[1].? }, ipv4(u8, c[0]));
    for ([_][]const u8{ "a.test", "localhost", "1.2.a", "x1" }) |h| try testing.expectEqual(Ipv4.not_ip, ipv4(u8, h));
    for ([_][]const u8{ "256.0.0.1", "1.2.3.4.5", "a.1", "1.2.3.256", "4294967296", "08.1.1.1", "1..2.3" }) |h| try testing.expectEqual(Ipv4.invalid, ipv4(u8, h));
    var b: [15]u8 = undefined;
    try testing.expectEqualStrings("127.0.0.1", ipv4Text(0x7f000001, &b));
}

test "W9d③ 20 회 검증: IPv6 — 줄임·끼운 IPv4·틀린 꼴, RFC 5952 꼴(가장 긴 0 자리, 하나짜리 0 은 줄이지 않는다)" {
    var b: [39]u8 = undefined;
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "::1", "::1" },                                .{ "0:0::1", "::1" },                                .{ "::FFFF:1.2.3.4", "::ffff:102:304" },
        .{ "2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1" }, .{ "2001:db8:0:1:1:1:1:1", "2001:db8:0:1:1:1:1:1" }, .{ "1::", "1::" },
        .{ "::", "::" },                                  .{ "0001:00:0:0:0:0:0:1", "1::1" },
    }) |c| try testing.expectEqualStrings(c[1], ipv6Text(ipv6(u8, c[0]) orelse return error.TestUnexpectedResult, &b));
    for ([_][]const u8{ "", ":1", "1:", "1:::2", "1::2::3", "12345::", "g::", "1:2:3:4:5:6:7:8:9", "::1.2.3", "::01.2.3.4", "1.2.3.4::" }) |s| try testing.expect(ipv6(u8, s) == null);
}
