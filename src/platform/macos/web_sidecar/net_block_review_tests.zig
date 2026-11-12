//! W9d③ 20 회 적대 검증 1–10 회차(검증자 A)의 순수 공격을 회귀 시험으로 남긴 것(docs/plans/web-osr-backend.md 「W9d③ 20 회 적대 검증」).
//! CEF 를 쓰지 않는다 — 패턴 풀기·맞추기(`net_block`), 막기 표(`net_block_table` — 홉·사이트 묶기·D2 토큰·귀속), 서비스 워커 길 판정(`sw_share`),
//! Network 도메인 주인(`net_domain`).
//!
//! 시험이 증명하는 것(회차마다): R1 거절 까닭 12 가지가 모두 닿고(`.path` 포함 — 어느 주소에도 맞을 수 없는 꼴), 경계·wire 의 닫힌 칸; R2 무작위
//! 30 만 주소 꼴과 독립 참조의 대조, `*` 가 스킴·호스트에만 있으면 경로가 정확히 그것(문서의 뜻), 단위 겹침 없음, KMP 대 단순 glob; R3 홉 사이에
//! 바뀐 규칙; R4 사이트 묶기 표; R6 서비스 워커 길의 경계(규칙을 쥔 모르는 탭은 덮였다 — MED-2); R7 귀속(바뀐 이동의 귀속은 남지 않는다 — N5);
//! R9 Network 도메인의 모든 차례; R10 D2 토큰(갈래가 다른 이동은 가져가지 않는다 — LOW-3, 친 글의 Chromium 꼴 — LOW-4, 번호 0 — N6).
//! 2 차(`A2-*`)·3 차(`A3-*` — 문서 없이 끝난 iframe 이동의 기록, 들어오는 서비스 워커 이동의 호스트, beforeunload 처리기를 기다리는 토큰, 묶인
//! 토큰의 끝) 검증의 공격도 같은 꼴로 남겼다.
//! 브라우저 탭에서 중요한 이유 — 막기 규칙은 사용자 탭의 요청도 막는다: 새는 쪽(막아야 할 것이 지나감)과 넘치는 쪽(사용자의 이동이 막힘)이 모두
//! 사용자가 겪는 일이다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const nb = protocol.net_block;
const msg = protocol.message;
const net_fields = protocol.net_fields;
const table_mod = @import("net_block_table.zig");
const sw_share = @import("sw_share.zig");
const net_domain = @import("net_domain.zig");

const testing = std.testing;
const rep = @import("array_repeat").repeat;
const n_why = @typeInfo(nb.Why).@"enum".field_names.len;

fn why(text: []const u8) ?nb.Why {
    return switch (nb.parse(text)) {
        .ok => null,
        .err => |w| w,
    };
}

fn normOf(text: []const u8, buf: []u8) []const u8 {
    return switch (nb.parse(text)) {
        .ok => |p| blk: {
            const n = p.norm();
            @memcpy(buf[0..n.len], n);
            break :blk buf[0..n.len];
        },
        .err => |w| std.fmt.bufPrint(buf, "<{s}>", .{w.name()}) catch "<>",
    };
}

fn m8(pattern: []const u8, url: []const u8) bool {
    const p = switch (nb.parse(pattern)) {
        .ok => |p| p,
        .err => unreachable,
    };
    return nb.matchUrl(u8, &p, url);
}

// ── R1: parse / normalize — bad input ───────────────────────────────────────────────────────────────

test "A-R1: 거절 까닭 12 가지가 모두 새 입력으로 닿는다(`.path` 포함), 경계, 대조는 문서대로 정규화된다" {
    const Case = struct { text: []const u8, want: ?nb.Why };
    const long_ok = "*://*/" ++ rep("a", 512 - 6);
    const long_bad = "*://*/" ++ rep("a", 512 - 6 + 1);
    const host253 = rep("a", 253);
    const host254 = rep("a", 254);
    const cases = [_]Case{
        .{ .text = "", .want = .empty },
        .{ .text = long_ok, .want = null },
        .{ .text = long_bad, .want = .too_long },
        .{ .text = "https://a.test/\xc3\xa9", .want = .not_ascii },
        .{ .text = "https://a.test/\x80", .want = .not_ascii },
        .{ .text = "https://xn--bcher-kva.test/", .want = null },
        .{ .text = "https://a.test/\x00", .want = .control_or_space },
        .{ .text = "https://a.test/x\r\nHost: evil", .want = .control_or_space },
        .{ .text = "https://a .test/", .want = .control_or_space },
        .{ .text = "https://a#b.test/", .want = .fragment },
        .{ .text = "https://@a.test/", .want = .userinfo },
        .{ .text = "https://a.test@/", .want = .userinfo },
        .{ .text = "https:/a.test/", .want = .scheme },
        .{ .text = "://a.test/", .want = .scheme },
        .{ .text = "javascript://a.test/", .want = .scheme },
        .{ .text = "*s://a.test/", .want = .scheme },
        .{ .text = "HtTpS://a.test/", .want = null },
        .{ .text = "https://a.test:8080:90/", .want = .host },
        .{ .text = "https://[::1/", .want = .host },
        .{ .text = "https://[]/", .want = .host },
        .{ .text = "https://[::1]x/", .want = .host },
        .{ .text = "https://*.*.a.test/", .want = .host },
        .{ .text = "https://a.test?x/", .want = .host },
        .{ .text = "https://" ++ host253 ++ "/", .want = null },
        .{ .text = "https://" ++ host254 ++ "/", .want = .host },
        .{ .text = "https://a.test:99999/", .want = .port },
        .{ .text = "https://a.test:123456/", .want = .port },
        .{ .text = "https://[::1]:/", .want = .port },
        .{ .text = "https://a.test:65535/", .want = null },
        .{ .text = "*://*.a.test/" ++ rep("*", 7), .want = .too_many_stars },
        .{ .text = "*://*.a.test/" ++ rep("*", 6), .want = null },
        .{ .text = "https://a.test/%G0", .want = .escape },
        .{ .text = "https://a.test/%%41", .want = .escape },
        .{ .text = "https://a.test/%4", .want = .escape },
        .{ .text = "https://a.test/%41", .want = null },
        .{ .text = "https://a.test/x/../y", .want = .path },
    };
    var bad: usize = 0;
    for (cases) |cse| {
        const got = why(cse.text);
        if (got != cse.want) {
            bad += 1;
            std.debug.print("A-R1 mismatch {s}: got {?s} want {?s}\n", .{ cse.text[0..@min(cse.text.len, 60)], if (got) |g| g.name() else null, if (cse.want) |w| w.name() else null });
        }
    }
    // Which reasons did we reach?
    var reached: [n_why]bool = @splat(false);
    for (cases) |cse| if (why(cse.text)) |w| {
        reached[@backingInt(w)] = true;
    };
    var n_reached: usize = 0;
    for (reached) |r| n_reached += @intFromBool(r);
    try testing.expectEqual(@as(usize, 0), bad);
    try testing.expectEqual(reached.len, n_reached); // N1: `.path` 도 닿는다(전에는 11/12)
}

test "A-R1: 무작위 30 만 개 — 어느 입력도 풀기를 무너뜨리지 않고, `.path` 는 맞을 수 없는 경로에서만 나온다" {
    var prng = std.Random.DefaultPrng.init(0xA1A1);
    const r = prng.random();
    const alphabet = "htps:/*.a[]?%@#:0123456789x";
    var buf: [40]u8 = undefined;
    var path_hits: usize = 0;
    var counts: [n_why]usize = @splat(0);
    for (0..300_000) |_| {
        const n = r.intRangeAtMost(usize, 1, buf.len);
        for (buf[0..n]) |*c| c.* = alphabet[r.intRangeLessThan(usize, 0, alphabet.len)];
        // half the time start with a valid scheme
        if (r.boolean() and n > 8) @memcpy(buf[0..7], "http://");
        if (why(buf[0..n])) |w| {
            counts[@backingInt(w)] += 1;
            if (w == .path) {
                path_hits += 1;
                // 이 알파벳에는 `\\`·`"`·`<`·`>` 가 없다 — `.path` 는 점 조각(`/.`·`/..` 로 끝나는 조각)에서만 나와야 한다.
                const t = buf[0..n];
                const q = std.mem.indexOfScalar(u8, t, '?') orelse t.len;
                const dot_seg = std.mem.indexOf(u8, t[0..q], "/./") != null or std.mem.indexOf(u8, t[0..q], "/../") != null or
                    std.mem.endsWith(u8, t[0..q], "/.") or std.mem.endsWith(u8, t[0..q], "/..");
                try testing.expect(dot_seg);
            }
        }
    }
    try testing.expect(counts[@backingInt(nb.Why.scheme)] > 0 and counts[@backingInt(nb.Why.host)] > 0 and path_hits > 0);
}

test "A-R1 N2: 어느 주소에도 맞을 수 없는 패턴은 거절한다 — 끝 점 둘, Chromium 이 다른 꼴로 바꾸는 IP, 점 조각·`\\`·`\"` 경로 (전에는 받아 죽은 규칙)" {
    var b: [600]u8 = undefined;
    try testing.expectEqual(@as(?nb.Why, .host), why("https://a.test../x"));
    try testing.expectEqual(@as(?nb.Why, .host), why("http://[::FFFF:1.2.3.4]/x"));
    try testing.expectEqual(@as(?nb.Why, .host), why("http://[0:0::1]/x"));
    try testing.expectEqual(@as(?nb.Why, .host), why("http://0x7f.0.0.1/x"));
    try testing.expectEqual(@as(?nb.Why, .host), why("http://2130706433/x"));
    try testing.expectEqual(@as(?nb.Why, .host), why("http://127.1/x"));
    try testing.expectEqual(@as(?nb.Why, .host), why("http://0177.0.0.1/x"));
    try testing.expectEqual(@as(?nb.Why, .host), why("http://256.0.0.1/x"));
    try testing.expectEqual(@as(?nb.Why, .path), why("https://a.test/x/../y"));
    try testing.expectEqual(@as(?nb.Why, .path), why("https://a.test/x/./y"));
    try testing.expectEqual(@as(?nb.Why, .path), why("https://a.test/x/%2e%2E/y"));
    try testing.expectEqual(@as(?nb.Why, .path), why("https://a.test/x/../")); // 끝의 `/x/..` 만이면 앞부분 꼴로 산다(2 차 검증 N-A2-1 — 아래)
    try testing.expectEqual(@as(?nb.Why, .path), why("https://a.test/a\\b"));
    try testing.expectEqual(@as(?nb.Why, .path), why("https://a.test/\"q\""));
    try testing.expectEqual(@as(?nb.Why, .path), why("https://a.test/p?q=<x>"));
    // 실측 CEF 154(고침의 탐침): 경로의 `{}|^` 와 백틱, 쿼리의 `'` 는 `%XX` 로 간다 — 그 꼴의 패턴은 맞지 않는다. 쿼리의 `{}|^` 는 그대로.
    for ([_][]const u8{ "https://a.test/a{b}", "https://a.test/a|b", "https://a.test/a^b", "https://a.test/a`b", "https://a.test/p?q='x'" }) |t| try testing.expectEqual(@as(?nb.Why, .path), why(t));
    try testing.expectEqual(@as(?nb.Why, null), why("https://a.test/p?q={x}|y^z`w"));
    try testing.expectEqual(@as(?nb.Why, null), why("https://a.test/it's"));
    // 대조: 정규 꼴 IP·점이 낀 이름·`*` 가 낀 조각·쿼리의 `..`·`\\` 는 받는다.
    try testing.expectEqual(@as(?nb.Why, null), why("http://127.0.0.1/x"));
    try testing.expectEqual(@as(?nb.Why, null), why("http://[::1]/x"));
    try testing.expectEqual(@as(?nb.Why, null), why("http://[::ffff:102:304]/x"));
    try testing.expectEqual(@as(?nb.Why, null), why("https://a.test/..x/.y./*..*"));
    try testing.expectEqual(@as(?nb.Why, null), why("https://a.test/p?x=../y\\z"));
    try testing.expectEqual(@as(?nb.Why, null), why("https://a.test./x"));
    try testing.expectEqual(@as(?nb.Why, null), why("http://1.2.3.4.test/x"));
    const rows = [_][]const u8{
        "https://a.test../x",
        "http://a.test:00080/x",
        "https://A.TEST.:443",
        "http://[::FFFF:1.2.3.4]/x",
        "http://[0:0::1]/x",
        "http://0x7f.0.0.1/x",
        "http://2130706433/x",
        "https://a.test/x/../y",
        "https://a.test/a\\b",
        "*://*",
        "*://a.test",
        "*://*.a.test/",
    };
    _ = rows;
    try testing.expectEqualStrings("http://a.test/x", normOf("http://a.test:00080/x", &b));
    try testing.expectEqualStrings("https://a.test/", normOf("https://A.TEST.:443", &b));
    try testing.expectEqualStrings("*://*/*", normOf("*://*", &b));
    try testing.expectEqualStrings("*://a.test/*", normOf("*://a.test", &b));
    try testing.expectEqualStrings("*://*.a.test/", normOf("*://*.a.test/", &b));
}

test "A-R1: wire 의 checkBlock 이 망가진 net_block 을 거절한다(번호 0·중복·서비스 워커 종류 비트·정규형 아닌 패턴·틀린 엄격 호스트·빈 사이트·33 개)" {
    var v: msg.NetBlock = .{ .browser = 1, .generation = 1, .count = 1 };
    v.rules[0] = .{ .id = 1, .site = "a.test", .pattern = "https://a.test/" };
    try net_fields.checkBlock(v);
    var rejects: usize = 0;
    const Mut = *const fn (*msg.NetBlock) void;
    const muts = [_]Mut{
        struct {
            fn f(x: *msg.NetBlock) void {
                x.rules[0].id = 0;
            }
        }.f,
        struct {
            fn f(x: *msg.NetBlock) void {
                x.count = 2;
                x.rules[1] = x.rules[0];
            }
        }.f,
        struct {
            fn f(x: *msg.NetBlock) void {
                x.rules[0].types = 1 << 15;
            }
        }.f,
        struct {
            fn f(x: *msg.NetBlock) void {
                x.rules[0].types = 1 << 18;
            }
        }.f,
        struct {
            fn f(x: *msg.NetBlock) void {
                x.rules[0].pattern = "https://A.test/";
            }
        }.f,
        struct {
            fn f(x: *msg.NetBlock) void {
                x.rules[0].pattern = "https://a.test";
            }
        }.f,
        struct {
            fn f(x: *msg.NetBlock) void {
                x.strict_site = "a test";
            }
        }.f,
        struct {
            fn f(x: *msg.NetBlock) void {
                x.rules[0].site = "";
            }
        }.f,
        struct {
            fn f(x: *msg.NetBlock) void {
                x.count = 33;
            }
        }.f,
    };
    for (muts) |mf| {
        var w = v;
        mf(&w);
        if (net_fields.checkBlock(w)) |_| {} else |_| rejects += 1;
    }
    try testing.expectEqual(muts.len, rejects);
}

// ── R2: matching evasion vs an independent reference of the documented semantics ──────────────────

/// Reference of docs/control-plane-browser.md: `*` anywhere in the pattern → glob over path+query (last piece anchored at end);
/// no `*` → the parsed URL's prefix (exact host, path prefix). Host case-insensitive; trailing dot removed both sides; port: none = any.
const RefPat = struct {
    scheme: u8, // 0 http 1 https 2 any
    host_kind: u8, // 0 any 1 wildcard 2 exact
    host: []const u8,
    port: ?u16,
    path: []const u8,
};

/// Wildcard DP (O(|p|·|t|)) — dp[j] = pattern prefix i matches text prefix j.
fn refGlob(pat: []const u8, text: []const u8) bool {
    var dp: [257]bool = @splat(false);
    std.debug.assert(text.len < dp.len);
    dp[0] = true;
    for (pat) |pc| {
        var next: [257]bool = @splat(false);
        if (pc == '*') {
            var any = false;
            for (0..text.len + 1) |j| {
                any = any or dp[j];
                next[j] = any;
            }
        } else {
            for (1..text.len + 1) |j| next[j] = dp[j - 1] and text[j - 1] == pc;
        }
        dp = next;
    }
    return dp[text.len];
}

fn refMatch(p: RefPat, any_star: bool, u_scheme: u8, u_host: []const u8, u_port: u16, u_path: []const u8) bool {
    if (p.scheme != 2 and p.scheme != u_scheme) return false;
    switch (p.host_kind) {
        0 => {},
        1 => if (!(std.ascii.eqlIgnoreCase(u_host, p.host) or (u_host.len > p.host.len and std.ascii.endsWithIgnoreCase(u_host, p.host) and u_host[u_host.len - p.host.len - 1] == '.'))) return false,
        else => if (!std.ascii.eqlIgnoreCase(u_host, p.host)) return false,
    }
    if (p.port) |v| if (v != u_port) return false;
    const path = if (u_path.len == 0) "/" else u_path;
    if (any_star) return refGlob(p.path, path);
    return std.mem.startsWith(u8, path, p.path);
}

test "A-R2: 무작위 30 만 주소 꼴(대소문자·기본/명시 포트·끝 점·사용자 정보·조각·쿼리·IPv6·스킴 *) — matchUrl u8/u16 과 독립 참조가 같다" {
    var prng = std.Random.DefaultPrng.init(0xA2A2_0001);
    const r = prng.random();
    const hosts = [_][]const u8{ "a.test", "b.a.test", "a.test.evil", "evila.test", "[::1]", "127.0.0.1" };
    const palpha = "ab/?%";
    var disagree: usize = 0;
    var star_scheme_exact_divergence: usize = 0;
    var total: usize = 0;
    var matched: usize = 0;
    var pb: [256]u8 = undefined;
    var ub: [256]u8 = undefined;
    var u16b: [256]u16 = undefined;
    for (0..300_000) |_| {
        total += 1;
        // pattern
        const sch = r.intRangeLessThan(u8, 0, 3);
        const hk = r.intRangeLessThan(u8, 0, 3);
        const ph = hosts[r.intRangeLessThan(usize, 0, if (hk == 1) 4 else hosts.len)];
        const pport: ?u16 = if (r.intRangeLessThan(u8, 0, 4) == 0) 8080 else null;
        var path_buf: [16]u8 = undefined;
        path_buf[0] = '/';
        const pl = r.intRangeAtMost(usize, 0, 8);
        var stars: usize = 0;
        for (1..pl + 1) |i| {
            if (r.intRangeLessThan(u8, 0, 5) == 0 and stars < 5) {
                path_buf[i] = '*';
                stars += 1;
            } else path_buf[i] = palpha[r.intRangeLessThan(usize, 0, 3)]; // a b / only in patterns ('?' ok too but keep simple)
        }
        const ppath = path_buf[0 .. pl + 1];
        var w: std.Io.Writer = .fixed(&pb);
        w.writeAll(switch (sch) {
            0 => "http://",
            1 => "https://",
            else => "*://",
        }) catch unreachable;
        switch (hk) {
            0 => w.writeAll("*") catch unreachable,
            1 => w.print("*.{s}", .{ph}) catch unreachable,
            else => w.writeAll(ph) catch unreachable,
        }
        if (pport) |v| w.print(":{d}", .{v}) catch unreachable;
        w.writeAll(ppath) catch unreachable;
        const ptext = w.buffered();
        const parsed = switch (nb.parse(ptext)) {
            .ok => |p| p,
            .err => continue,
        };
        const any_star = std.mem.indexOfScalar(u8, ptext, '*') != null;
        // URL
        const us = r.intRangeLessThan(u8, 0, 2);
        const uh = hosts[r.intRangeLessThan(usize, 0, hosts.len)];
        const up: u16 = switch (r.intRangeLessThan(u8, 0, 4)) {
            0 => 8080,
            1 => if (us == 1) 443 else 80,
            else => 0, // implicit
        };
        const upper_host = r.intRangeLessThan(u8, 0, 4) == 0;
        const trail_dot = r.intRangeLessThan(u8, 0, 6) == 0 and uh[0] != '[';
        const userinfo = r.intRangeLessThan(u8, 0, 6) == 0;
        var upath_buf: [24]u8 = undefined;
        upath_buf[0] = '/';
        const ul = r.intRangeAtMost(usize, 0, 14);
        for (1..ul + 1) |i| upath_buf[i] = palpha[r.intRangeLessThan(usize, 0, 4)];
        const upath = upath_buf[0 .. ul + 1];
        const frag = r.intRangeLessThan(u8, 0, 5) == 0;
        var w2: std.Io.Writer = .fixed(&ub);
        w2.writeAll(if (us == 1) "https://" else "http://") catch unreachable;
        if (userinfo) w2.writeAll("u:p@") catch unreachable;
        for (uh) |c| w2.writeByte(if (upper_host) std.ascii.toUpper(c) else c) catch unreachable;
        if (trail_dot) w2.writeByte('.') catch unreachable;
        if (up != 0) w2.print(":{d}", .{up}) catch unreachable;
        w2.writeAll(upath) catch unreachable;
        if (frag) w2.writeAll("#a*b/?") catch unreachable;
        const utext = w2.buffered();
        const eff_port: u16 = if (up != 0) up else if (us == 1) 443 else 80;
        const ref_pat: RefPat = .{
            .scheme = sch,
            .host_kind = hk,
            .host = ph,
            // pattern default port removal (documented): http:80 / https:443 → any. Not applicable for 8080.
            .port = pport,
            .path = if (any_star and pl == 0 and std.mem.eql(u8, ppath, "/") and false) "/*" else ppath,
        };
        const want = refMatch(ref_pat, any_star, us, uh, eff_port, upath);
        const got8 = nb.matchUrl(u8, &parsed, utext);
        for (utext, 0..) |c, i| u16b[i] = c;
        const got16 = nb.matchUrl(u16, &parsed, u16b[0..utext.len]);
        if (got8) matched += 1;
        if (got8 != want or got16 != want) {
            disagree += 1;
            if (disagree <= 5) std.debug.print("A-R2 disagree pat={s} url={s} want={} got8={} got16={}\n", .{ ptext, utext, want, got8, got16 });
        }
        // How often does the `*` scheme/host change a path-prefix rule into an exact-path rule?
        if (any_star and std.mem.indexOfScalar(u8, ppath, '*') == null) {
            const as_prefix = std.mem.startsWith(u8, upath, ppath);
            if (as_prefix != want) star_scheme_exact_divergence += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), disagree);
    try testing.expect(matched > 0 and star_scheme_exact_divergence > 0 and total == 300_000);
}

test "A-R2 LOW-1: `*` 가 스킴·호스트에만 있으면 경로는 정확히 그것이다(문서의 뜻 — 그 아래까지는 `/ads*`) — 뜻은 그대로, 문서·주석을 고쳤다" {
    const rows = [_]struct { p: []const u8, u: []const u8 }{
        .{ .p = "http://a.test/ads", .u = "http://a.test/ads/banner.js" },
        .{ .p = "*://a.test/ads", .u = "http://a.test/ads/banner.js" },
        .{ .p = "http://*.a.test/ads", .u = "http://a.test/ads/banner.js" },
        .{ .p = "http://a.test/collect", .u = "http://a.test/collect?id=1" },
        .{ .p = "*://a.test/collect", .u = "http://a.test/collect?id=1" },
        .{ .p = "*://*.a.test/", .u = "http://x.a.test/anything" },
        .{ .p = "http://a.test/", .u = "http://a.test/anything" },
        .{ .p = "*://a.test/ads*", .u = "http://a.test/ads/banner.js" },
        .{ .p = "*://a.test/ads/*", .u = "http://a.test/ads/banner.js" },
        .{ .p = "*://a.test/collect*", .u = "http://a.test/collect?id=1" },
    };
    var res: [rows.len]bool = undefined;
    for (rows, 0..) |row, i| res[i] = m8(row.p, row.u);
    try testing.expect(res[0] and !res[1] and !res[2] and res[3] and !res[4] and !res[5] and res[6] and res[7] and res[8] and res[9]);
}

test "A-R2: ASCII 밖·이스케이프 단위는 패턴 바이트와 겹치지 않는다, 문서화된 빠져나가기(소문자 %2f·대문자 경로), data·blob·about 은 맞지 않는다" {
    const p = switch (nb.parse("https://a.test/*track*")) {
        .ok => |v| v,
        .err => unreachable,
    };
    // 'track' with one unit shifted by 0x100 — must not match.
    var hits: usize = 0;
    const base = "https://a.test/xtrackx";
    var u: [base.len]u16 = undefined;
    for (base, 0..) |c, i| u[i] = c;
    for (16..21) |i| {
        var v = u;
        v[i] += 0x100;
        if (nb.matchUrl(u16, &p, &v)) hits += 1;
    }
    const lower_esc = m8("https://a.test/a%2Fb", "https://a.test/a%2fb");
    const upper_path = m8("https://a.test/admin", "https://a.test/ADMIN");
    const data = m8("*://*/*", "data:text/html,https://a.test/");
    const blob = m8("*://*/*", "blob:https://a.test/uuid");
    const about = m8("*://*/*", "about:blank");
    try testing.expectEqual(@as(usize, 0), hits);
    try testing.expect(!lower_esc and !upper_path); // 문서화된 빠져나가기 — 바뀌면 문서도
    try testing.expect(!data and !blob and !about);
}

test "A-R2: 되풀이가 많은 세 글자 알파벳·겹친 `*`·빈 조각 — KMP glob 과 단순 glob 이 30 만 번 같다(작성자와 다른 씨앗)" {
    var prng = std.Random.DefaultPrng.init(0xA2A2_0002);
    const r = prng.random();
    const alpha = "aab";
    var pb: [64]u8 = undefined;
    var tb: [96]u8 = undefined;
    var dis: usize = 0;
    var pos: usize = 0;
    for (0..300_000) |_| {
        pb[0] = '/';
        const pl = r.intRangeAtMost(usize, 0, 18);
        var stars: usize = 0;
        for (1..pl + 1) |i| {
            if (stars < 8 and r.intRangeLessThan(u8, 0, 3) == 0) {
                pb[i] = '*';
                stars += 1;
            } else pb[i] = alpha[r.intRangeLessThan(usize, 0, alpha.len)];
        }
        const pp = pb[0 .. pl + 1];
        tb[0] = '/';
        const tl = r.intRangeAtMost(usize, 0, 60);
        for (1..tl + 1) |i| tb[i] = alpha[r.intRangeLessThan(usize, 0, alpha.len)];
        const tp = tb[0 .. tl + 1];
        var full: [96]u8 = undefined;
        const pat_text = std.fmt.bufPrint(&full, "https://a.test{s}", .{pp}) catch unreachable;
        const p = switch (nb.parse(pat_text)) {
            .ok => |v| v,
            .err => continue,
        };
        var ufull: [128]u8 = undefined;
        const url = std.fmt.bufPrint(&ufull, "https://a.test{s}", .{tp}) catch unreachable;
        const want = if (p.glob) refGlob(pp, tp) else std.mem.startsWith(u8, tp, pp);
        const got = nb.matchUrl(u8, &p, url);
        if (got) pos += 1;
        if (got != want) dis += 1;
    }
    try testing.expectEqual(@as(usize, 0), dis);
    try testing.expect(pos > 0);
}

// ── R3 (pure part): a rule set swapped between redirect hops is seen by the next hop ─────────────────

fn compiled(gpa: std.mem.Allocator, browser: msg.BrowserId, gen: u32, rules: []const msg.NetBlockRule) !?*table_mod.RuleSet {
    var v: msg.NetBlock = .{ .browser = browser, .generation = gen, .count = @intCast(rules.len) };
    for (rules, 0..) |rr, i| v.rules[i] = rr;
    const c = try table_mod.compile(gpa, v);
    return c.set;
}

fn u16s(comptime s: []const u8) [s.len]u16 {
    var out: [s.len]u16 = undefined;
    for (s, 0..) |ch, i| out[i] = ch;
    return out;
}

test "A-R3: 같은 요청의 홉 1 과 홉 2 사이에 바뀐 규칙이 홉 2 를 막고, 홉 1 이 쥔 옛 묶음은 놓을 때까지 산다" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/other" }}), "", 1);
    t.committed(7, 70, "a.test", 0);
    const hop1 = u16s("https://a.test/r/slow");
    const a1 = t.acquire(70, 55, false, 0, 1000).?;
    const v1 = table_mod.decideTab(&a1, &hop1, 13, false, "a.test");
    // swap while hop 1 is still held
    try t.swap(gpa, tab, try compiled(gpa, 7, 2, &.{.{ .id = 2, .site = "a.test", .pattern = "https://a.test/m/" }}), "", 1);
    t.reap(gpa);
    const retired_alive = t.retired.items.len;
    t.release(70, &a1, v1, false, 0);
    const hop2 = u16s("https://a.test/m/late");
    const a2 = t.acquire(70, 55, false, 0, 1001).?;
    const v2 = table_mod.decideTab(&a2, &hop2, 13, false, "a.test");
    t.release(70, &a2, v2, false, 0);
    _ = table_mod.takeOne(&t, 7);
    t.reap(gpa);
    try testing.expect(v1 == .pass and retired_alive == 1 and v2 == .block and t.retired.items.len == 0);
}

// ── R4 (pure part): site binding — unknown page, other-site dormant, departing-document beacon ────────

test "A-R4: 사이트 묶기 표 — 페이지 호스트(pageHost)와 판정(잠든 규칙·떠난 문서의 비콘·다른 사이트 iframe·맨 위를 모름)" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 1, .site = "a.test", .pattern = "*://*/*" }}), "", 1);
    const url = u16s("https://cdn.test/x.js");
    const Row = struct { top: []const u8, fp: []const u8, want: std.meta.Tag(table_mod.Verdict) };
    const rows = [_]Row{
        .{ .top = "a.test", .fp = "a.test", .want = .block },
        .{ .top = "www.a.test", .fp = "a.test", .want = .block }, // narrower top within site
        .{ .top = "b.test", .fp = "b.test", .want = .pass }, // dormant
        .{ .top = "b.test", .fp = "a.test", .want = .block }, // departing a.test document's beacon after commit of b.test
        .{ .top = "a.test", .fp = "b.test", .want = .pass }, // departing b.test document's beacon after commit of a.test (control)
        .{ .top = "a.test", .fp = "", .want = .block }, // cross-site iframe in a.test page
        .{ .top = "", .fp = "", .want = .unknown_page }, // about:blank top
        .{ .top = "", .fp = "a.test", .want = .block },
        .{ .top = "a.test.evil", .fp = "a.test.evil", .want = .pass },
        .{ .top = "evila.test", .fp = "evila.test", .want = .pass },
    };
    var bad: usize = 0;
    for (rows) |row| {
        t.committed(7, 70, row.top, 0);
        const a = t.acquire(70, 9, false, 0, 1).?;
        const page = protocol.net_policy.pageHost(row.fp, a.topHost());
        const v = table_mod.decideTab(&a, &url, 3, false, page);
        t.release(70, &a, v, false, 0);
        if (std.meta.activeTag(v) != row.want) {
            bad += 1;
            std.debug.print("A-R4 row top={s} fp={s} got {s} want {s}\n", .{ row.top, row.fp, @tagName(v), @tagName(row.want) });
        }
    }
    const h = table_mod.takeOne(&t, 7).?;
    try testing.expect(bad == 0 and h.skipped_unknown_page == 1);
}

// ── R6 (pure part): D3a decision boundaries ───────────────────────────────────────────────────────────

test "A-R6 MED-2·N3: sw_share.decide 의 경계 — 32 탭 모두 쥠은 막고, 넘침(목록 밖 브라우저)은 거부하되 세며, 규칙을 쥔 모르는 탭은 덮였다" {
    var facts: [33]sw_share.TabFacts = undefined;
    for (&facts, 0..) |*f, i| f.* = .{ .browser = @intCast(i + 1), .rule_id = 5 };
    const all32 = sw_share.decide(facts[0..32]);
    facts[32] = .{ .browser = 0, .unknown = true };
    const with_overflow = sw_share.decide(facts[0..33]);
    facts[3].rule_id = 0;
    const one_unruled = sw_share.decide(facts[0..32]);
    const unk: [2]sw_share.TabFacts = .{ .{ .browser = 1, .unknown = true, .rule_id = 5 }, .{ .browser = 2, .unknown = true } };
    const all_unknown = sw_share.decide(&unk);
    const self_unknown = sw_share.decide(unk[0..1]); // 규칙을 쥔 탭 혼자, 빈 주소 프레임(늦게 뜨는 iframe)이 있다 — MED-2 재현
    const none_ruled = sw_share.decide(unk[1..2]);
    try testing.expect(all32 == .block and with_overflow == .not_applied and one_unruled == .not_applied);
    try testing.expect(all_unknown == .not_applied and self_unknown == .block and none_ruled == .pass);
}

test "A-R6: serviceWorkerRule — 종류를 단 규칙은 건너뛰고, 사이트가 확정된 맨 위 호스트와 진행 중 이동의 호스트를 모두 덮어야 한다" {
    const gpa = testing.allocator;
    const set = (try compiled(gpa, 7, 1, &.{
        .{ .id = 1, .types = nb.typeBits("image").?, .site = "a.test", .pattern = "*://*/*" },
        .{ .id = 2, .site = "a.test", .pattern = "https://a.test/s/" },
    })).?;
    defer gpa.destroy(set);
    const url = u16s("https://a.test/s/x");
    const parts = nb.splitUrl(u16, &url).?;
    var bg: nb.Budget = .{};
    const r_committed = table_mod.serviceWorkerRule(set, parts, &.{"a.test"}, &bg);
    const r_midnav_other = table_mod.serviceWorkerRule(set, parts, &.{ "a.test", "b.test" }, &bg);
    const r_empty_top = table_mod.serviceWorkerRule(set, parts, &.{""}, &bg);
    const r_none = table_mod.serviceWorkerRule(set, parts, &.{}, &bg);
    try testing.expect(r_committed != null and r_committed.?.id == 2 and r_midnav_other == null and r_empty_top == null and r_none == null);
}

// ── R7 (pure part): SW-path navigation attribution by URL hash ─────────────────────────────────────────

test "A-R7 N5: 귀속 — 그 주소의 진행 중 주 프레임 이동을 가진 탭만, 바뀐(새 이동이 시작된) 이동의 귀속은 남지 않는다" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    _ = t.ensure(1, 10);
    _ = t.ensure(2, 20);
    const u = table_mod.canonHash(u8, "https://a.test/s/nav");
    _ = t.beforeBrowse(1, 10, true, false, .other, 0, u, 1, "a.test", 100);
    // B has no pending nav to u — a subresource SW fetch of the same URL attributes nothing to B.
    t.noteServiceWorkerMainBlock(20, u, 21);
    t.noteServiceWorkerMainBlock(10, u, 11);
    const b_rule = t.mainBlockRule(20, u);
    // A's navigation is superseded by another navigation (no load error for u) — the attribution stays.
    _ = t.beforeBrowse(1, 10, true, false, .other, 0, table_mod.canonHash(u8, "https://a.test/other"), 1, "a.test", 200);
    t.committed(1, 10, "a.test", 0);
    // 한참 뒤 같은 주소가 다른 까닭(-102 등)으로 실패해도 막힘으로 적지 않는다(전에는 규칙 11 로 적었다).
    const later = t.mainBlockRule(10, u);
    try testing.expectEqual(@as(u32, 0), b_rule);
    try testing.expectEqual(@as(u32, 0), later);
}

// ── R9 (pure): Network domain ownership — every order of 4 toggles, final state invariants ─────────────

test "A-R9: net_domain — {엄격 켬·끔, 기록 켬·끔} 24 차례 × 밸브 자리 6 — 엄격이 꺼지면 우회가 남지 않고, 엄격 중에는 disable 이 없다" {
    const Op = enum { s_on, s_off, r_on, r_off, valve };
    const ops = [_]Op{ .s_on, .s_off, .r_on, .r_off };
    var perm: [4]usize = .{ 0, 1, 2, 3 };
    var orders: usize = 0;
    var violations: usize = 0;
    var bypass_first_violations: usize = 0;
    // Heap's algorithm over 4 elements, each order also with a valve inserted at every position.
    var c: [4]usize = @splat(0);
    var i: usize = 0;
    const run = struct {
        fn f(p: [4]usize, valve_at: ?usize, viol: *usize, bfv: *usize) void {
            var d: net_domain.Domain = .{};
            var seq: [5]Op = undefined;
            var n: usize = 0;
            for (p, 0..) |k, j| {
                if (valve_at) |vat| if (vat == j) {
                    seq[n] = .valve;
                    n += 1;
                };
                seq[n] = ops[k];
                n += 1;
            }
            // Model of the CDP-side state: enabled? bypass flag?
            var enabled = false;
            var flag = false;
            for (seq[0..n]) |op| {
                const cmds = switch (op) {
                    .s_on => d.strictOn(true),
                    .s_off => d.strictOff(),
                    .r_on => d.recordOn(),
                    .r_off => d.recordOff(),
                    .valve => d.valve(),
                };
                var saw_disable_before_bypass_off = false;
                var saw_disable = false;
                for (cmds.slice()) |cmd| switch (cmd) {
                    .enable_light, .enable_record => enabled = true,
                    .disable => {
                        enabled = false;
                        saw_disable = true;
                    },
                    .bypass_on => flag = true,
                    .bypass_off => {
                        flag = false;
                        if (saw_disable) saw_disable_before_bypass_off = true;
                    },
                    .cond_set, .cond_clear, .online_off, .online_on => unreachable, // W9e② 조건은 이 차례에 없다
                };
                if (saw_disable_before_bypass_off) bfv.* += 1;
                // invariants after each op
                const strict_effective = enabled and flag;
                if (d.strict and !strict_effective) viol.* += 1; // strict silently stopped
                if (!d.strict and flag) viol.* += 1; // dormant flag would resurrect on next enable
                if (d.recording and !enabled) viol.* += 1;
            }
        }
    }.f;
    run(perm, null, &violations, &bypass_first_violations);
    orders += 1;
    for (0..5) |vat| run(perm, vat, &violations, &bypass_first_violations);
    while (i < 4) {
        if (c[i] < i) {
            if (i % 2 == 0) std.mem.swap(usize, &perm[0], &perm[i]) else std.mem.swap(usize, &perm[c[i]], &perm[i]);
            run(perm, null, &violations, &bypass_first_violations);
            for (0..5) |vat| run(perm, vat, &violations, &bypass_first_violations);
            orders += 1;
            c[i] += 1;
            i = 0;
        } else {
            c[i] = 0;
            i += 1;
        }
    }
    try testing.expect(orders == 24 and violations == 0 and bypass_first_violations == 0);
}

test "A-R9: CDP 번호 대역이 겹치지 않는다(엄격·본문·DevTools·미디어)" {
    const strict_lo: i64 = 1 << 27;
    const strict_hi: i64 = (1 << 27) + (1 << 20);
    const body_lo: i64 = 1 << 28;
    const body_hi: i64 = 1 << 29;
    const dt_lo: i64 = 1 << 29;
    const dt_hi: i64 = 1 << 30;
    const media_lo: i64 = 1 << 30;
    const disjoint = strict_lo < strict_hi and strict_hi <= body_lo and body_hi <= dt_lo and dt_hi <= media_lo;
    try testing.expect(disjoint);
    try testing.expectEqual(@as(i64, @import("net_body_table.zig").id_base), body_lo);
    try testing.expectEqual(@as(i64, @import("devtools_table.zig").id_base), dt_lo);
}

// ── R10 (pure): D2 tokens ─────────────────────────────────────────────────────────────────────────────

test "A-R10 LOW-3: D2 — 아무 일도 하지 않은 사용자의 뒤로 뒤 1 초 안의 에이전트 이동은 토큰을 가져가지 못한다(갈래가 다르다), 진짜 기록 이동은 가져간다" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/blk/" }}), "", 1);
    t.committed(7, 70, "a.test", 0);
    // User presses back with nothing to go back to (or a same-document entry) — no on_before_browse.
    t.userNavAction(7, 70, .history, 1000);
    // 400 ms later the agent navigates (agentNavigate → navigate{user:false} → obb, not a redirect).
    const agent_url = "https://a.test/blk/secret";
    const canon = table_mod.canonHash(u8, agent_url);
    const user_flag = t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 1400);
    const a = t.acquire(70, 99, true, canon, 1401).?;
    const u = u16s(agent_url);
    const v = table_mod.decideTab(&a, &u, 0, true, "");
    t.release(70, &a, v, true, canon);
    // Control: 1001 ms later the same agent navigation is blocked.
    var t2: table_mod.Table = .{};
    defer t2.deinit(gpa);
    const tab2 = t2.ensure(7, 70).?;
    try t2.swap(gpa, tab2, try compiled(gpa, 7, 1, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/blk/" }}), "", 1);
    t2.userNavAction(7, 70, .history, 1000);
    _ = t2.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 2001);
    const a2 = t2.acquire(70, 99, true, canon, 2002).?;
    const v2 = table_mod.decideTab(&a2, &u, 0, true, "");
    t2.release(70, &a2, v2, true, canon);
    try testing.expect(!user_flag and v == .block and v2 == .block);
    // 대조: 사용자의 뒤로가 시작한 기록 이동(전이 종류 FORWARD_BACK)은 가져간다 — 새로 고침 토큰은 기록 이동이 못 가져간다.
    t2.userNavAction(7, 70, .history, 3000);
    try testing.expect(t2.beforeBrowse(7, 70, true, false, .history, 0, canon, 1, "a.test", 3100));
    t2.userNavAction(7, 70, .reload, 4000);
    try testing.expect(!t2.beforeBrowse(7, 70, true, false, .history, 0, canon, 1, "a.test", 4100));
    try testing.expect(t2.beforeBrowse(7, 70, true, false, .reload, 0, canon, 1, "a.test", 4200));
    // bfcache·같은 문서 기록 이동(on_before_browse 없이 주소 확정)은 남은 토큰을 거둔다.
    t2.userNavAction(7, 70, .history, 5000);
    t2.committed(7, 70, "a.test", 0);
    try testing.expect(!t2.beforeBrowse(7, 70, true, false, .history, 0, canon, 1, "a.test", 5100));
    // 에이전트의 navigate 가 남은 토큰을 거둔다.
    t2.userNavAction(7, 70, .reload, 6000);
    t2.agentNavigate(70);
    try testing.expect(!t2.beforeBrowse(7, 70, true, false, .reload, 0, canon, 1, "a.test", 6100));
    try testing.expectEqual(table_mod.NavKind.history, table_mod.NavKind.fromTransition(0x0100_0000 | 1));
    try testing.expectEqual(table_mod.NavKind.reload, table_mod.NavKind.fromTransition(8));
    try testing.expectEqual(table_mod.NavKind.other, table_mod.NavKind.fromTransition(1));
}

test "A-R10 LOW-4: D2 — 친 글과 Chromium(GURL) 꼴이 같은 해시다(빈칸·점 조각·? 앞의 / 없음·IP 꼴·따옴표·역슬래시 포함 9 꼴)" {
    const Row = struct { typed: []const u8, gurl: []const u8 };
    const rows = [_]Row{
        .{ .typed = "HTTP://A.TEST:80/x", .gurl = "http://a.test/x" },
        .{ .typed = "https://a.test", .gurl = "https://a.test/" },
        .{ .typed = "https://a.test/x#frag", .gurl = "https://a.test/x#frag" },
        .{ .typed = "https://a.test/a b", .gurl = "https://a.test/a%20b" },
        .{ .typed = "https://a.test/x/../y", .gurl = "https://a.test/y" },
        .{ .typed = "https://a.test?q=1", .gurl = "https://a.test/?q=1" },
        .{ .typed = "http://127.1/x", .gurl = "http://127.0.0.1/x" },
        .{ .typed = "https://a.test/\"q\"", .gurl = "https://a.test/%22q%22" },
        .{ .typed = "https://a.test/a\\b", .gurl = "https://a.test/a/b" },
    };
    var lost: usize = 0;
    var gb: [64]u16 = undefined;
    for (rows) |row| {
        for (row.gurl, 0..) |ch, i| gb[i] = ch;
        // 비교는 sidecar 가 하는 대로 — 친 글(u8)과 CEF 가 넘긴 GURL 꼴(u16).
        if (table_mod.canonHash(u8, row.typed) != table_mod.canonHash(u16, gb[0..row.gurl.len])) lost += 1;
    }
    try testing.expectEqual(@as(usize, 0), lost); // 전에는 6/9
}

test "A-R10 N6: D2 — 같은 주소의 speculation 요청(번호 0)은 묶인 토큰을 쓰지 못하고 막힌다, 진짜 이동 요청이 토큰을 쓴다" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/blk/" }}), "", 1);
    t.committed(7, 70, "a.test", 0);
    const url = "https://a.test/blk/u";
    const canon = table_mod.canonHash(u8, url);
    t.userNavigate(7, 70, canon, 1000);
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 1001);
    const u = u16s(url);
    const a0 = t.acquire(70, 0, true, canon, 1002).?; // id 0, main frame (prerender main frame)
    const v0 = table_mod.decideTab(&a0, &u, 0, true, "");
    t.release(70, &a0, v0, true, canon);
    const a1 = t.acquire(70, 77, true, canon, 1003).?; // the real request
    const v1 = table_mod.decideTab(&a1, &u, 0, true, "");
    t.release(70, &a1, v1, true, canon);
    // reuse: another request id 0 later
    const a2 = t.acquire(70, 0, true, canon, 1004).?;
    const v2 = table_mod.decideTab(&a2, &u, 0, true, "");
    t.release(70, &a2, v2, true, canon);
    try testing.expect(v0 == .block and v1 == .user_exempt and v2 == .block);
}

test "A-R10: D2 — 예외는 요청 번호 하나(그 홉들까지), 하위 자원·뒤의 같은 주소 이동은 막힌다, 쓰지 않은 토큰은 5 초, 에이전트의 navigate 가 거둔다" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/blk/" }}), "", 1);
    t.committed(7, 70, "a.test", 0);
    const url = "https://a.test/blk/u";
    const canon = table_mod.canonHash(u8, url);
    const u = u16s(url);
    t.userNavigate(7, 70, canon, 1000);
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 1001);
    const a1 = t.acquire(70, 77, true, canon, 1002).?;
    const v1 = table_mod.decideTab(&a1, &u, 0, true, "");
    t.release(70, &a1, v1, true, canon);
    // redirect hop of the same request
    const a1b = t.acquire(70, 77, true, table_mod.canonHash(u8, "https://a.test/blk/v"), 1003).?;
    const vu = u16s("https://a.test/blk/v");
    const v1b = table_mod.decideTab(&a1b, &vu, 0, true, "");
    t.release(70, &a1b, v1b, true, 0);
    // subresource of the exempt page
    const asub = t.acquire(70, 78, false, 0, 1004).?;
    const vs = table_mod.decideTab(&asub, &u, 4, false, "a.test");
    t.release(70, &asub, vs, false, 0);
    // agent navigation to the same URL 2 s later (new request id)
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 3000);
    const a2 = t.acquire(70, 90, true, canon, 3001).?;
    const v2 = table_mod.decideTab(&a2, &u, 0, true, "");
    t.release(70, &a2, v2, true, canon);
    // url token unused for 5 s then an agent nav to that URL at 5.9 s (token window) and 6.1 s
    t.userNavigate(7, 70, canon, 10_000);
    const in_window = t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 14_900);
    // 3 차 검증 LOW-A3-3: 시계는 몸짓 뒤 다른 주 프레임 이동이 시작된 때부터 돈다 — 그 뒤 5 초가 지나면 끝난다.
    t.userNavigate(7, 70, canon, 20_000);
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, table_mod.canonHash(u8, "https://a.test/page-own"), 1, "a.test", 20_050);
    const after_window = t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 25_051);
    try testing.expect(v1 == .user_exempt and v1b == .user_exempt and vs == .block and v2 == .block and in_window and !after_window);
    // 쓰지 않은 사용자 토큰은 에이전트·복원의 navigate 가 거둔다(sidecar `browsers.navigate` 가 부른다 — LOW-3).
    t.userNavigate(7, 70, canon, 30_000);
    t.agentNavigate(70);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 30_100));
}

// ── 2 차 검증(검증자 A2 — 6077ecc4c 를 다시 친 1–10 회차)의 순수 공격 ─────────────────────────────────────────────

test "A2-R1: 정규형은 고정점 — 받은 무작위 패턴 30 만 개를 정규형으로 다시 풀면 같은 정규형(maru 가 보내고 checkBlock 이 요구한다)" {
    var prng = std.Random.DefaultPrng.init(0xa2_01);
    const r = prng.random();
    const schemes = [_][]const u8{ "http", "HTTPS", "*", "https", "Http" };
    const hosts = [_][]const u8{ "*", "*.a.test", "*.A.TEST.", "a.test", "A.test.", "127.0.0.1", "[::1]", "[0:0::1]", "[::FFFF:102:304]", "xn--x.test", "a_b.test", "127.0.0.1.", "1.2.3", "0x7f.0.0.1" };
    const ports = [_][]const u8{ "", "", ":80", ":443", ":080", ":00443", ":8080", ":65535", ":0", ":" };
    const pieces = [_][]const u8{ "a", "/", "*", ".", "..", "%2e", "%2E", "%41", "%af", "?", "=", "&", "'", "\"", "\\", "{", "|", "^", "`", "~", "@", ":", "[", "]", "%", "%2f", ";" };
    var accepted: usize = 0;
    var tb: [600]u8 = undefined;
    var nbuf: [600]u8 = undefined;
    for (0..300_000) |_| {
        var w: std.Io.Writer = .fixed(&tb);
        w.writeAll(schemes[r.uintLessThan(usize, schemes.len)]) catch {};
        w.writeAll("://") catch {};
        w.writeAll(hosts[r.uintLessThan(usize, hosts.len)]) catch {};
        w.writeAll(ports[r.uintLessThan(usize, ports.len)]) catch {};
        if (r.uintLessThan(u8, 5) != 0) {
            w.writeAll("/") catch {};
            for (0..r.uintLessThan(usize, 8)) |_| w.writeAll(pieces[r.uintLessThan(usize, pieces.len)]) catch {};
        }
        const p = switch (nb.parse(w.buffered())) {
            .ok => |p| p,
            .err => continue,
        };
        accepted += 1;
        const n = p.norm();
        @memcpy(nbuf[0..n.len], n);
        switch (nb.parse(nbuf[0..n.len])) {
            .ok => |q| if (!std.mem.eql(u8, q.norm(), nbuf[0..n.len])) {
                std.debug.print("unstable: {s} -> {s} -> {s}\n", .{ w.buffered(), nbuf[0..n.len], q.norm() });
                return error.TestUnexpectedResult;
            },
            .err => |e| {
                std.debug.print("normal form rejected: {s} -> {s} ({s})\n", .{ w.buffered(), nbuf[0..n.len], e.name() });
                return error.TestUnexpectedResult;
            },
        }
    }
    try testing.expect(accepted > 50_000);
}

test "A2-R1 N-A2-1: 앞부분 꼴 패턴의 끝 조각이 점 조각이어도 받는다(`/.` 은 `/.well-known` 의 앞부분) — 뒤에 `/` 가 오거나 쿼리 앞이거나 glob 이면 여전히 거절" {
    const Row = struct { pattern: []const u8, url: []const u8 };
    for ([_]Row{
        .{ .pattern = "https://a.test/.", .url = "https://a.test/.well-known/x" },
        .{ .pattern = "https://a.test/..", .url = "https://a.test/..foo" },
        .{ .pattern = "https://a.test/x/%2E", .url = "https://a.test/x/%2Ehidden" },
        .{ .pattern = "https://a.test/x/.", .url = "https://a.test/x/.env" },
        .{ .pattern = "https://a.test/x/%2e%2E", .url = "https://a.test/x/%2E%2Eq" },
    }) |row| {
        try testing.expect(why(row.pattern) == null);
        try testing.expect(m8(row.pattern, row.url));
    }
    // 맞을 수 없는 꼴은 그대로 거절 — 뒤에 `/`(Chromium 이 푼다), 쿼리 앞(경로가 거기서 끝난다), glob(끝에 묶인다).
    for ([_][]const u8{ "https://a.test/./x", "https://a.test/../", "https://a.test/.?q", "https://a.test/x/%2E?a", "*://a.test/.", "https://a.test/*/." }) |p| {
        try testing.expectEqual(@as(?nb.Why, .path), why(p));
    }
    // 우회 꼴(전의 안내)도 그대로 받는다.
    try testing.expect(m8("https://a.test/.*", "https://a.test/.well-known/x"));
}

test "A2-R2: url_canon.hash 는 같은 글의 u8(maru — 친 글)·u16(CEF) 꼴에 같다 — 무작위 30 만(ASCII 호스트, 경로·쿼리·조각에 ASCII 밖 글자 포함)" {
    var prng = std.Random.DefaultPrng.init(0xa2_02);
    const r = prng.random();
    const parts = [_][]const u8{ "/", "\\", ".", "..", "%2e", "%2E", " ", "\"", "<", "{", "|", "^", "`", "'", "?", "#", "%zz", "%41", "\xc3\xa9", "\xed\x95\x9c", "@", "x", "\x7f", "\x01" };
    const hosts = [_][]const u8{ "a.test", "A.TEST.", "127.1", "[::1]", "u@a.test", "a.test:8080", "a.test:", "127.0.0.%31", "%41.test" };
    var hashed: usize = 0;
    var tb: [256]u8 = undefined;
    var t16: [256]u16 = undefined;
    for (0..300_000) |_| {
        var w: std.Io.Writer = .fixed(&tb);
        w.writeAll(if (r.boolean()) "http://" else "https://") catch {};
        w.writeAll(hosts[r.uintLessThan(usize, hosts.len)]) catch {};
        w.writeAll(if (r.boolean()) "/" else "\\") catch {};
        for (0..r.uintLessThan(usize, 10)) |_| w.writeAll(parts[r.uintLessThan(usize, parts.len)]) catch {};
        const s = w.buffered();
        const n = std.unicode.utf8ToUtf16Le(&t16, s) catch continue;
        const a = protocol.url_canon.hash(u8, 7, s);
        const b = protocol.url_canon.hash(u16, 7, t16[0..n]);
        if (a == null and b == null) continue;
        hashed += 1;
        if (a == null or b == null or a.? != b.?) {
            std.debug.print("u8/u16 disagree: {s}\n", .{s});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(hashed > 100_000);
}

test "A2-R10 N-A2-3: 퍼센트로 쓴 호스트를 친 이동도 Chromium 꼴과 같은 해시다(GURL 은 호스트의 %XX 를 풀고 IP·소문자로 맞춘다)" {
    const same = struct {
        fn f(typed: []const u8, gurl: []const u8) !void {
            var g16: [128]u16 = undefined;
            for (gurl, 0..) |ch, i| g16[i] = ch;
            try testing.expectEqual(table_mod.canonHash(u16, g16[0..gurl.len]), table_mod.canonHash(u8, typed));
        }
    }.f;
    try same("http://127.0.0.%31:8080/blk/x", "http://127.0.0.1:8080/blk/x");
    try same("http://%31%32%37.1/x", "http://127.0.0.1/x");
    try same("http://%41.Test/x", "http://a.test/x");
    try same("http://a%2Eb.test/x", "http://a.b.test/x");
    // 다른 호스트는 다르다, 풀 수 없는 꼴은 그 글 그대로 잰다(GURL 이 거절한다 — 이동이 없다).
    try testing.expect(table_mod.canonHash(u8, "http://127.0.0.%32/x") != table_mod.canonHash(u8, "http://127.0.0.1/x"));
    try testing.expect(table_mod.canonHash(u8, "http://a%zz.test/x") != table_mod.canonHash(u8, "http://a.test/x"));
}

test "A2-R6 MED-A2-1: 늦게 뜨는 iframe 이 있는(모름) 규칙 탭이 그 출처를 보이지 않으면 T(O) 에서 빠진다 — 혼자면 빈 T(막지 않음), 그 출처를 보이는 규칙 없는 탭 곁에서는 「적용 안 됨」 을 받지 않는다" {
    // 판정에 넣는 것은 부른 쪽(`blocking.serviceWorkerSelect`)이 `role` 로 고른다 — 그 고르기를 그대로 흉내 낸다.
    const Tab = struct { browser: msg.BrowserId, shows: bool, unknown: bool, rule: u32 };
    const pick = struct {
        fn f(tabs: []const Tab, out: []sw_share.TabFacts) []sw_share.TabFacts {
            var n: usize = 0;
            for (tabs) |t| {
                if (sw_share.role(t.shows, t.unknown, t.rule != 0, false) == .skip) continue;
                out[n] = .{ .browser = t.browser, .unknown = t.unknown, .rule_id = t.rule };
                n += 1;
            }
            return out[0..n];
        }
    }.f;
    var buf: [4]sw_share.TabFacts = undefined;
    // (a) 혼자 — 아무도 그 출처를 보이지 않는다: 빈 T.
    try testing.expectEqual(sw_share.Outcome.empty, sw_share.decide(pick(&.{.{ .browser = 2, .shows = false, .unknown = true, .rule = 41 }}, &buf)));
    // (b) 그 출처를 보이는 규칙 없는 탭 곁 — 규칙 탭은 몫이 없어 「적용 안 됨」 을 받지 않는다(pass).
    const b = pick(&.{ .{ .browser = 1, .shows = true, .unknown = false, .rule = 0 }, .{ .browser = 2, .shows = false, .unknown = true, .rule = 41 } }, &buf);
    try testing.expect(b.len == 1 and b[0].browser == 1);
    try testing.expectEqual(sw_share.Outcome.pass, sw_share.decide(b));
    // MED-2 그대로: 보이는 규칙 탭의 제 iframe 이 모름이어도 막는다.
    try testing.expectEqual(sw_share.Outcome.block, sw_share.decide(pick(&.{.{ .browser = 2, .shows = true, .unknown = true, .rule = 41 }}, &buf)));
    // 보수 규칙 그대로: 보인다고 증명되지 않은 모르는 **규칙 없는** 탭은 보이는 규칙 탭의 막기를 거부한다(센다).
    try testing.expectEqual(sw_share.Outcome.not_applied, sw_share.decide(pick(&.{ .{ .browser = 1, .shows = true, .unknown = false, .rule = 51 }, .{ .browser = 3, .shows = false, .unknown = true, .rule = 0 } }, &buf)));
    // 거부권 몫만 있으면 막지도 세지도 않는다.
    try testing.expectEqual(sw_share.Outcome.pass, sw_share.decide(pick(&.{.{ .browser = 3, .shows = false, .unknown = true, .rule = 0 }}, &buf)));
}

test "A2-R10 LOW-A2-3: 친 주소가 같은 문서 이동(조각만 다름)으로 확정되면 주소 토큰은 끝난다 — 5 초 안의 새로 고침(누가 시작했든)이 가져가지 못한다" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/blk/" }}), "", 1);
    const cur = "https://a.test/blk/cur";
    const canon = table_mod.canonHash(u8, cur);
    t.committed(7, 70, "a.test", canon);
    // 사용자가 지금 주소 + `#frag` 를 친다 — 같은 문서 이동: `on_before_browse` 없이 주소 확정만.
    t.userNavigate(7, 70, table_mod.canonHash(u8, cur ++ "#frag"), 1000);
    t.committed(7, 70, "a.test", table_mod.canonHash(u8, cur ++ "#frag"));
    const user_flag = t.beforeBrowse(7, 70, true, false, .reload, 0, canon, 1, "a.test", 1300);
    const u = u16s(cur);
    const a = t.acquire(70, 55, true, canon, 1301).?;
    const v = table_mod.decideTab(&a, &u, 0, true, "");
    t.release(70, &a, v, true, canon);
    try testing.expect(!user_flag and std.meta.eql(v, table_mod.Verdict{ .block = 1 }));
    // 대조: 다른 주소의 확정(옛 문서의 pushState)은 토큰을 거두지 않는다 — 그 사용자 이동은 아직 가는 중이다.
    t.userNavigate(7, 70, canon, 2000);
    t.committed(7, 70, "a.test", table_mod.canonHash(u8, "https://a.test/blk/other"));
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 2010));
}

test "A2-R10 LOW-A2-3: 사용자의 뒤로가 iframe 만 옮겼으면 기록 토큰은 그 iframe 이동이 쓴다 — 1 초 안의 주 프레임 기록 이동(에이전트·페이지)이 가져가지 못한다" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/blk/" }}), "", 1);
    t.committed(7, 70, "a.test", 0);
    t.userNavAction(7, 70, .history, 1000);
    _ = t.beforeBrowse(7, 70, false, false, .history, 9, table_mod.canonHash(u8, "https://a.test/p/sub?f1"), 1, "a.test", 1005);
    const target = "https://a.test/blk/h1";
    const canon = table_mod.canonHash(u8, target);
    const user_flag = t.beforeBrowse(7, 70, true, false, .history, 0, canon, 1, "a.test", 1300);
    const u = u16s(target);
    const a = t.acquire(70, 56, true, canon, 1301).?;
    const v = table_mod.decideTab(&a, &u, 0, true, "");
    t.release(70, &a, v, true, canon);
    try testing.expect(!user_flag and std.meta.eql(v, table_mod.Verdict{ .block = 1 }));
    // 대조: 기록 이동이 아닌 iframe 이동(광고 iframe 의 새 문서)은 사용자의 토큰을 거두지 않는다.
    t.userNavAction(7, 70, .history, 2000);
    _ = t.beforeBrowse(7, 70, false, false, .other, 9, table_mod.canonHash(u8, "https://a.test/ad"), 1, "a.test", 2005);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .history, 0, canon, 1, "a.test", 2010));
}

test "A2-R10 LOW-A2-3: 에이전트의 다른 곳으로 가는 이동(wire 의 다른 주소 navigate·뒤로·앞으로·멈춤 — sidecar 가 agentNavigate 로)은 주소·다음 이동·묶인 토큰 모두를 거둔다(DevTools 호출은 W9d④ v1 SEVERE-2 부터 거두지 않고 다툼 — net_block_table 끝 시험)" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/blk/" }}), "", 1);
    t.committed(7, 70, "a.test", 0);
    const url = "https://a.test/blk/x";
    const canon = table_mod.canonHash(u8, url);
    const u = u16s(url);
    // 사용자의 이동이 서비스 워커 길로 받아졌다 — 묶인 토큰을 IO 의 첫 홉이 쓰지 않았다. 에이전트의 새로 고침이 그 묶음을 가져가지 못한다.
    t.userNavigate(7, 70, canon, 1000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 1001));
    t.agentNavigate(70);
    _ = t.beforeBrowse(7, 70, true, false, .reload, 0, canon, 1, "a.test", 1200);
    const a = t.acquire(70, 60, true, canon, 1201).?;
    const v = table_mod.decideTab(&a, &u, 0, true, "");
    t.release(70, &a, v, true, canon);
    try testing.expectEqual(table_mod.Verdict{ .block = 1 }, v);
    // 새 문서가 서면(`on_load_start` — `frameSettled`) 묶인 토큰도 끝난다. 옛 문서의 주소 확정(pushState)은 거두지 않는다.
    t.userNavigate(7, 70, canon, 3000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 3001));
    t.committed(7, 70, "a.test", table_mod.canonHash(u8, "https://a.test/old#pushed"));
    try testing.expectEqual(canon, t.find(7).?.bound_url);
    t.frameSettled(70, true, 0);
    _ = t.beforeBrowse(7, 70, true, false, .reload, 0, canon, 1, "a.test", 3100);
    const b = t.acquire(70, 61, true, canon, 3101).?;
    const vb = table_mod.decideTab(&b, &u, 0, true, "");
    t.release(70, &b, vb, true, canon);
    try testing.expectEqual(table_mod.Verdict{ .block = 1 }, vb);
}

test "A2-R10 LOW-A2-4: 떠나기 확인이 떠 있는 동안 토큰의 시계가 멈춘다 — 6 초 뒤 떠나기도 그 사용자의 이동은 예외, 머무르기·취소는 거두고, 10 분 넘게는 거둔다" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/blk/" }}), "", 1);
    t.committed(7, 70, "a.test", 0);
    const canon = table_mod.canonHash(u8, "https://a.test/blk/bu2");
    // 친 주소 — 확인이 100 ms 에 뜨고 6 초 뒤에 떠나기.
    t.userNavigate(7, 70, canon, 1000);
    t.holdTokens(70, 4, 1100);
    t.releaseHold(70, 99, false, 7100); // 다른 대화상자의 답(취소)은 풀지도 거두지도 않는다
    t.releaseHold(70, 4, true, 7100);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 7110));
    // 새로 고침 — 1.5 초 뒤 떠나기.
    t.userNavAction(7, 70, .reload, 10_000);
    t.holdTokens(70, 5, 10_050);
    t.releaseHold(70, 5, true, 11_550);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .reload, 0, canon, 1, "a.test", 11_560));
    // 머무르기 — 거둔다(그 몸짓은 이동을 시작하지 않았다).
    t.userNavigate(7, 70, canon, 20_000);
    t.holdTokens(70, 6, 20_100);
    t.releaseHold(70, 6, false, 20_500);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 20_510));
    // 답 없이 치움(새 이동·상태 비우기) — 거둔다.
    t.userNavigate(7, 70, canon, 30_000);
    t.holdTokens(70, 7, 30_100);
    t.releaseHold(70, 0, false, 30_200);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 30_210));
    // 상한 — 10 분 넘게 떠 있었으면 거둔다.
    t.userNavigate(7, 70, canon, 40_000);
    t.holdTokens(70, 8, 40_100);
    t.releaseHold(70, 8, true, 40_100 + table_mod.hold_max_ms + 1);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 40_100 + table_mod.hold_max_ms + 2));
    // 토큰이 없을 때 뜬 확인(페이지의 이동)은 아무것도 멈추지 않는다 — 뒤의 떠나기가 지난 토큰을 되살리지 않는다(시계가 돈 뒤 5 초·상한 모두).
    t.userNavigate(7, 70, canon, 50_000);
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, table_mod.canonHash(u8, "https://a.test/page-own"), 1, "a.test", 50_010);
    t.holdTokens(70, 9, 60_000);
    t.releaseHold(70, 9, true, 70_000);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 70_010));
    t.userNavigate(7, 70, canon, 100_000);
    t.holdTokens(70, 10, 100_000 + table_mod.start_cap_ms + 1);
    t.releaseHold(70, 10, true, 100_000 + table_mod.start_cap_ms + 5_000);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 100_000 + table_mod.start_cap_ms + 5_010));
}

test "A2-R8 LOW-A2-2: 끊긴 주 프레임 이동(ERR_ABORTED)은 그 주소의 진행 중 기록만 놓는다 — 밀려 끊긴 옛 이동의 끊김은 새 이동의 기록을 지우지 않는다" {
    var t: table_mod.Table = .{};
    defer t.deinit(testing.allocator);
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, 11, 101, "a.test", 0);
    t.mainAborted(70, 11);
    try testing.expect(t.find(7).?.pendingMain() == null);
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, 12, 102, "b.test", 10);
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, 13, 103, "c.test", 20); // 새 이동이 앞 이동을 밀었다
    t.mainAborted(70, 12); // 밀린 옛 이동의 끊김
    try testing.expectEqual(@as(u64, 13), t.find(7).?.pendingMain().?.url);
}

// ── 3 차 검증(검증자 A3 — 8485a891e 를 친 1·2·6·8·10 회차)의 순수 공격 — 「finding」 으로 박던 지금 동작을 고친 뒤의 답으로. 실제 CEF 판정은
// `--review-block-v20a3`. ──────────────────────────────────────────────────────────────────────────────────────────

test "A3-R6 MED-A3-1: 문서 없이 끝난 하위 프레임 이동(204·다운로드 — 끊김, 빈 응답 — 오류 페이지, 막힘)과 떨어져 나간 iframe 은 그 프레임의 진행 중 기록을 놓는다 — 사이트가 다른 iframe 은 열쇠가 바뀌어 주소로 찾고, 오류 페이지 프레임은 그 출처를 「보이지」 않는다" {
    var t: table_mod.Table = .{};
    defer t.deinit(testing.allocator);
    const o = table_mod.originHash("http://127.0.0.1:9");
    const shows = struct {
        fn f(tab: *const table_mod.Tab, origin: u64) bool {
            for (tab.pending[0..tab.pending_len]) |p| if (p.origin == origin) return true;
            return false;
        }
    }.f;
    const url_204 = table_mod.canonHash(u8, "http://127.0.0.1:9/n204?a3");
    // 탭(localhost)의 iframe F 가 127.0.0.1 로 이동을 시작했다(on_before_browse — 하위 프레임).
    _ = t.beforeBrowse(7, 70, false, false, .other, 0xF, url_204, o, "127.0.0.1", 1000);
    const tab = t.find(7).?;
    try testing.expect(shows(tab, o));
    // 주 프레임의 끊김은 하위 프레임 기록을 놓지 않는다.
    t.mainAborted(70, url_204);
    try testing.expect(shows(tab, o));
    // 204·다운로드 — 같은 프레임의 on_load_error ERR_ABORTED(실측 CEF 154: 같은 프레임 번호). 다른 프레임·다른 주소의 끝은 놓지 않는다.
    t.subframeEnded(70, 0xE, table_mod.canonHash(u8, "http://127.0.0.1:9/other"), false);
    try testing.expect(shows(tab, o));
    t.subframeEnded(70, 0xF, url_204, false);
    try testing.expect(!shows(tab, o) and !tab.isErrFrame(0xF)); // 전에는 30 초 동안 「보였다」; 끊김은 옛 문서가 남는다 — 오류 페이지 아님
    // 빈 응답 — 사이트가 다른 iframe 의 오류 페이지는 새 프레임 번호로 on_load_error(-324)(실측) — 주소로 찾고, 그 프레임은 오류 페이지다.
    const uclose = table_mod.canonHash(u8, "http://127.0.0.1:9/a3/close");
    _ = t.beforeBrowse(7, 70, false, false, .other, 0x10, uclose, o, "127.0.0.1", 2000);
    t.subframeEnded(70, 0x11, uclose, true);
    try testing.expect(!shows(tab, o) and tab.isErrFrame(0x11) and !tab.isErrFrame(0x10));
    // 막기 규칙이 막음(-20) — 막은 그때 기록을 놓고, 그 주소로 on_load_error 없이 서는 문서는 오류 페이지로 친다(방어 — 실측은 같은 번호의
    // on_load_error -20 이라 위의 오류 갈래가 적는다).
    const ublk = table_mod.canonHash(u8, "http://127.0.0.1:9/blkifr?a3");
    const tab_set = try compiled(testing.allocator, 7, 1, &.{.{ .id = 42, .site = "localhost", .pattern = "*://*/blkifr*" }});
    try t.swap(testing.allocator, tab, tab_set, "", 1);
    t.committed(7, 70, "localhost", 0);
    _ = t.beforeBrowse(7, 70, false, false, .other, 0x12, ublk, o, "127.0.0.1", 3000);
    const ifr = u16s("http://127.0.0.1:9/blkifr?a3");
    const a = t.acquire(70, 90, false, 0, 3001).?;
    const v = table_mod.decideTab(&a, &ifr, 1, false, "localhost");
    t.releaseNav(70, &a, v, false, true, ublk);
    try testing.expectEqual(table_mod.Verdict{ .block = 42 }, v);
    try testing.expect(!shows(tab, o)); // 막은 그때 그 이동은 끝났다
    t.subframeStarted(70, 0x13, ublk);
    try testing.expect(!shows(tab, o) and tab.isErrFrame(0x13));
    // 진짜 문서(사이트가 다른 iframe 이 섰다)는 주소로 기록을 놓고 오류 페이지가 아니다; 같은 프레임에 새 문서가 서면 오류 표시도 지운다.
    const uok = table_mod.canonHash(u8, "http://127.0.0.1:9/p/sub?a3ok");
    _ = t.beforeBrowse(7, 70, false, false, .other, 0x14, uok, o, "127.0.0.1", 4000);
    t.subframeStarted(70, 0x15, uok);
    try testing.expect(!shows(tab, o) and !tab.isErrFrame(0x15));
    t.subframeStarted(70, 0x11, uok);
    try testing.expect(!tab.isErrFrame(0x11));
    // 떨어져 나간 프레임(이동 중에 지워진 iframe)은 기록·오류 표시 모두.
    _ = t.beforeBrowse(7, 70, false, false, .other, 0x16, uok, o, "127.0.0.1", 5000);
    t.subframeGone(70, 0x16);
    t.subframeGone(70, 0x13);
    try testing.expect(!shows(tab, o) and !tab.isErrFrame(0x13));
    // 주 프레임의 새 문서 — 옛 문서의 오류 프레임 표시를 모두 지운다.
    t.subframeEnded(70, 0x17, uclose, true);
    t.frameSettled(70, true, 0);
    try testing.expect(!tab.isErrFrame(0x17));
    // 놓는 이가 없는 끝(재지 못한 길)의 받침 — 하위 프레임은 짧게(10 초), 주 프레임은 30 초 그대로.
    _ = t.beforeBrowse(7, 70, false, false, .other, 0x18, 13, o, "127.0.0.1", 6000);
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, 14, o, "127.0.0.1", 6000);
    tab.expire(6000 + table_mod.subframe_ttl_ms - 1);
    try testing.expect(shows(tab, o) and tab.pending_len == 2);
    tab.expire(6000 + table_mod.subframe_ttl_ms + 1);
    try testing.expect(tab.pending_len == 1 and tab.pendingMain() != null);
    tab.expire(6000 + table_mod.pending_ttl_ms + 1);
    try testing.expectEqual(@as(u8, 0), tab.pending_len);
}

test "A3-R10 LOW-A3-3: 대화상자 없이 오래 도는 beforeunload — 몸짓 뒤 아무 주 프레임 이동도 시작되지 않은 동안 토큰은 기다린다(새로 고침 2 초·친 주소 6 초·1.5 초 뒤 확인), 다른 이동이 시작되면 그때부터 1 초·5 초, 상한 30 초" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/blk/" }}), "", 1);
    t.committed(7, 70, "a.test", 0);
    const canon = table_mod.canonHash(u8, "https://a.test/blk/busy");
    // 새로 고침 — 처리기가 2 초 돈다(실측 CEF 154: 2008 ms 뒤에 불러왔다, 대화상자 0). 전에는 막혔다.
    t.userNavAction(7, 70, .reload, 1000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .reload, 0, canon, 1, "a.test", 3008));
    // 뒤로 — 2 초.
    t.userNavAction(7, 70, .history, 4000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .history, 0, canon, 1, "a.test", 6007));
    // 친 주소 — 처리기가 6 초.
    t.userNavigate(7, 70, canon, 10_000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 16_008));
    // 1.5 초 돈 뒤 확인을 묻는다 — 확인이 뜰 때 토큰이 살아 있어 시계가 멈춘다, 200 ms 뒤 떠나기.
    t.userNavAction(7, 70, .reload, 20_000);
    t.holdTokens(70, 4, 21_500);
    t.releaseHold(70, 4, true, 21_700);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .reload, 0, canon, 1, "a.test", 21_710));
    // 대조: 몸짓 뒤 다른 주 프레임 이동(페이지의 것)이 시작됐으면 그때부터 1 초 — 그 뒤의 같은 갈래 이동은 가져가지 못한다.
    t.userNavAction(7, 70, .reload, 30_000);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon +% 7, 1, "a.test", 30_100));
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .reload, 0, canon, 1, "a.test", 31_101));
    // 대조: 상한 — 30 초 넘게 아무 이동도 없으면 끝난다.
    t.userNavigate(7, 70, canon, 40_000);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 40_000 + table_mod.start_cap_ms + 1));
    // 에이전트의 이동·멈춤은 기다리는 토큰도 거둔다(2 차 검증의 보장 그대로).
    t.userNavAction(7, 70, .reload, 80_000);
    t.agentNavigate(70);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .reload, 0, canon, 1, "a.test", 82_000));
}

test "A3-R6 MED-A3-2: 서비스 워커 길의 규칙 사이트 — 그 탭의 진행 중 주 프레임 이동 자체면 그 이동의 호스트만(탭 길과 같다), 다른 요청은 확정된 맨 위와 진행 중 호스트 모두" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 81, .site = "127.0.0.1", .pattern = "http://127.0.0.1:9/s/swblk" }}), "", 1);
    const set = tab.set.?;
    t.committed(7, 70, "localhost", 0);
    const url = u16s("http://127.0.0.1:9/s/swblknav1");
    const canon = table_mod.canonHash(u16, &url);
    const parts = nb.splitUrl(u16, &url).?;
    var hb: [2][]const u8 = undefined;
    // 탭이 localhost 에 확정된 채 127.0.0.1 의 서비스 워커 범위 주소로 옮기는 중이다(그 이동 요청이 서비스 워커 길로 온다).
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, canon, table_mod.urlOriginHash(u16, &url), "127.0.0.1", 100);
    // 그 이동을 대신 받는 서비스 워커는 목적지(127.0.0.1)의 것 — 요청을 낸 출처가 이동의 목적지 출처다.
    var bg: nb.Budget = .{};
    // 목적지의 맨 위 서비스 워커라 요청의 쿠키 첫 사이트가 목적지 사이트다(실측 — 5 차 검증 LOW 의 판별).
    const nav_hosts = table_mod.swHosts(tab, canon, table_mod.urlOriginHash(u16, &url), "127.0.0.1", &hb);
    try testing.expect(nav_hosts.len == 1 and std.mem.eql(u8, nav_hosts[0], "127.0.0.1"));
    try testing.expectEqual(@as(u32, 81), table_mod.serviceWorkerRule(set, parts, nav_hosts, &bg).?.id); // 전에는 없음 — 막지도 세지도 않았다
    // 같은 탭의 다른 요청(떠나는 문서의 하위 자원·다른 주소)은 두 호스트 모두 — 규칙의 사이트가 localhost 를 덮지 않으니 없음.
    const other = u16s("http://127.0.0.1:9/s/swblk-sub");
    const other_hosts = table_mod.swHosts(tab, table_mod.canonHash(u16, &other), table_mod.urlOriginHash(u16, &other), "127.0.0.1", &hb);
    try testing.expect(other_hosts.len == 2);
    try testing.expect(table_mod.serviceWorkerRule(set, nb.splitUrl(u16, &other).?, other_hosts, &bg) == null);
    // 진행 중 이동이 없으면 확정된 호스트만.
    t.committed(7, 70, "127.0.0.1", canon);
    const settled = table_mod.swHosts(tab, canon, table_mod.urlOriginHash(u16, &url), "127.0.0.1", &hb);
    try testing.expect(settled.len == 1 and std.mem.eql(u8, settled[0], "127.0.0.1"));
}

test "A3-R10 N-A3-1: 묶인 사용자 토큰은 그 이동이 문서 없이 끝나면(204·다운로드 — 끊김) 거둔다, 새 주 프레임 이동이 대신해도 — 규칙이 없어 IO 가 쓰지 않았어도" {
    var t: table_mod.Table = .{};
    defer t.deinit(testing.allocator);
    const canon = table_mod.canonHash(u8, "https://a.test/n204?t12x");
    t.committed(7, 70, "a.test", 0);
    t.userNavigate(7, 70, canon, 1000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 1001));
    try testing.expectEqual(canon, t.find(7).?.bound_url);
    t.mainAborted(70, canon); // 204 — ERR_ABORTED
    try testing.expectEqual(@as(u64, 0), t.find(7).?.bound_url); // 전에는 5 초 남아 페이지의 같은 주소 이동이 가져갔다
    t.userNavigate(7, 70, canon, 2000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 2001));
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, canon +% 1, 1, "a.test", 2002); // 다른 이동이 대신했다
    try testing.expectEqual(@as(u64, 0), t.find(7).?.bound_url);
    // 리다이렉트 홉은 묶음을 잇는다(대조).
    t.userNavigate(7, 70, canon, 3000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, canon, 1, "a.test", 3001));
    _ = t.beforeBrowse(7, 70, true, true, .other, 0, canon +% 2, 1, "a.test", 3002);
    try testing.expectEqual(canon, t.find(7).?.bound_url);
}

// ── 4 차 검증(A4 — 1d8fe6522 를 친 판): 6·8·10 회차의 순수 공격, 고친 뒤의 답 ─────────────────────────────────────────────────

/// A4-R6 의 꼴: 탭(localhost)의 iframe(열쇠 0x20)이 127.0.0.1 의 주소로 가다 규칙 42 에 막혔다(IO 의 고르기가 그 주소를 적는다).
fn a4BlockSub(t: *table_mod.Table, frame: u64, url: []const u8, at: i64) !u64 {
    const o = table_mod.originHash("http://127.0.0.1:9");
    const canon = table_mod.canonHash(u8, url);
    // 프레임 0 — 진행 중 기록 없이 막힌다(기록이 받침 시한으로 사라진 뒤 — 표시의 프레임을 모른다).
    if (frame != 0) _ = t.beforeBrowse(7, 70, false, false, .other, frame, canon, o, "127.0.0.1", at);
    var ub: [128]u16 = undefined;
    for (url, 0..) |ch, i| ub[i] = ch;
    const a = t.acquire(70, @intCast(90 + at), false, 0, at + 1).?;
    const v = table_mod.decideTab(&a, ub[0..url.len], 1, false, "localhost");
    t.releaseNav(70, &a, v, false, true, canon);
    try testing.expectEqual(table_mod.Verdict{ .block = 42 }, v);
    return canon;
}

fn a4Tab(t: *table_mod.Table) !*table_mod.Tab {
    const tab = t.ensure(7, 70).?;
    const set1 = try compiled(testing.allocator, 7, 1, &.{ .{ .id = 41, .site = "localhost", .pattern = "*://*/s/swlate*" }, .{ .id = 42, .site = "localhost", .pattern = "*://*/blkifr*" } });
    try t.swap(testing.allocator, tab, set1, "", 1);
    t.committed(7, 70, "localhost", 0);
    return tab;
}

test "A4-R6 A-MED: 막은 하위 프레임 주소의 표시(blocked_sub)는 그 막힘이 끝나면(on_load_error -20) 지워진다 — 규칙을 뺀 뒤 같은 주소로 정말 선 iframe 은 오류 페이지가 아니다(그 탭은 그 출처를 보인다)" {
    var t: table_mod.Table = .{};
    defer t.deinit(testing.allocator);
    const tab = try a4Tab(&t);
    const ublk = try a4BlockSub(&t, 0x20, "http://127.0.0.1:9/blkifr?a4", 1000);
    // 실측 CEF 154: 같은 프레임 번호의 on_load_error -20(오류 페이지).
    t.subframeEnded(70, 0x20, ublk, true);
    try testing.expect(tab.isErrFrame(0x20));
    // 에이전트가 규칙 42 를 뺀다(41 은 남긴다) — 같은 문서에서 페이지가 iframe 을 같은 주소로 다시 부른다: 이제 막히지 않는다.
    const set2 = try compiled(testing.allocator, 7, 2, &.{.{ .id = 41, .site = "localhost", .pattern = "*://*/s/swlate*" }});
    try t.swap(testing.allocator, tab, set2, "", 2);
    _ = t.beforeBrowse(7, 70, false, false, .other, 0x20, ublk, table_mod.originHash("http://127.0.0.1:9"), "127.0.0.1", 2000);
    const ifr = u16s("http://127.0.0.1:9/blkifr?a4");
    const a2 = t.acquire(70, 91, false, 0, 2001).?;
    const v2 = table_mod.decideTab(&a2, &ifr, 1, false, "localhost");
    t.releaseNav(70, &a2, v2, false, true, ublk);
    try testing.expectEqual(table_mod.Verdict.pass, v2);
    // 사이트가 다른 iframe 의 진짜 문서는 새 렌더 프레임 열쇠로 선다(실측) — 그 프레임은 127.0.0.1 을 보인다.
    t.subframeStarted(70, 0x21, ublk);
    try testing.expect(!tab.isErrFrame(0x21)); // 전에는 남은 blocked_sub 가 진짜 문서를 오류 페이지로 쳐 나열이 건너뛰었다
}

test "A4-R6 A-MED: 표시를 지우는 셋은 저마다 듣는다 — 그 주소의 끝(subframeEnded)·규칙 바꾸기(swap)·그 프레임의 새 이동(beforeBrowse — 5 차 NIT: 다른 프레임의 같은 주소 이동은 아니다), 무관한 사건은 지우지 않는다(MED-A3-1 의 방어 그대로)" {
    const gpa = testing.allocator;
    const ublk_text = "http://127.0.0.1:9/blkifr?a4x";
    const Way = enum { ended, swap, nav_same_url, nav_same_frame, unrelated_nav, unrelated_end, unrelated_end_frameless };
    for (std.enums.values(Way)) |way| {
        var t: table_mod.Table = .{};
        defer t.deinit(gpa);
        const tab = try a4Tab(&t);
        const ublk = try a4BlockSub(&t, if (way == .unrelated_end_frameless) 0 else 0x20, ublk_text, 1000);
        switch (way) {
            .ended => t.subframeEnded(70, 0x30, ublk, false), // 끊김(다른 열쇠 — 주소로)
            .swap => try t.swap(gpa, tab, try compiled(gpa, 7, 2, &.{.{ .id = 42, .site = "localhost", .pattern = "*://*/blkifr*" }}), "", 2),
            .nav_same_url => _ = t.beforeBrowse(7, 70, false, false, .other, 0x31, ublk, 1, "127.0.0.1", 1500),
            .nav_same_frame => _ = t.beforeBrowse(7, 70, false, false, .other, 0x20, table_mod.canonHash(u8, "http://127.0.0.1:9/other"), 1, "127.0.0.1", 1500),
            .unrelated_nav => _ = t.beforeBrowse(7, 70, false, false, .other, 0x32, table_mod.canonHash(u8, "http://127.0.0.1:9/other"), 1, "127.0.0.1", 1500),
            .unrelated_end, .unrelated_end_frameless => t.subframeEnded(70, 0x33, table_mod.canonHash(u8, "http://127.0.0.1:9/other"), true),
        }
        // on_load_error 없이 그 주소로 문서가 선다(재지 못한 갈래의 방어 — 그 갈래면 오류 페이지).
        t.subframeStarted(70, 0x21, ublk);
        // 5 차 검증 NIT: 다른 프레임(0x31)의 같은 주소 새 이동은 0x20 의 표시를 지우지 않는다(프레임마다 — 같은 주소로 막힌 iframe 여럿의 표시를 지켰다).
        const want_err = way == .nav_same_url or way == .unrelated_nav or way == .unrelated_end or way == .unrelated_end_frameless;
        if (tab.isErrFrame(0x21) != want_err) std.debug.print("A4-R6 갈래 {s}: 오류 페이지 {}\n", .{ @tagName(way), tab.isErrFrame(0x21) });
        try testing.expectEqual(want_err, tab.isErrFrame(0x21));
    }
}

test "A4-R6 A-LOW: 서비스 워커 길의 이동 자체 판정은 요청을 낸 출처가 그 이동의 목적지 출처일 때만 — 떠나는 옛 문서(다른 출처)가 그 이동 주소로 낸 하위 자원은 확정된 호스트와 이동 호스트 모두(MED-A3-2 의 들어오는 이동은 그대로)" {
    const gpa = testing.allocator;
    var t: table_mod.Table = .{};
    defer t.deinit(gpa);
    const tab = t.ensure(7, 70).?;
    try t.swap(gpa, tab, try compiled(gpa, 7, 1, &.{.{ .id = 91, .site = "localhost", .pattern = "http://localhost:9/s4/hang*" }}), "", 1);
    const set = tab.set.?;
    // 탭은 127.0.0.1(서비스 워커가 다스림)에 확정된 채 localhost 로 옮기는 중이다.
    t.committed(7, 70, "127.0.0.1", 0);
    const nav = u16s("http://localhost:9/s4/hang?a4nav");
    const canon = table_mod.canonHash(u16, &nav);
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, canon, table_mod.urlOriginHash(u16, &nav), "localhost", 100);
    var hb: [2][]const u8 = undefined;
    var bg: nb.Budget = .{};
    const parts = nb.splitUrl(u16, &nav).?;
    // 옛 문서(127.0.0.1)의 서비스 워커가 그 이동 주소로 낸 fetch — 탭 길이면 페이지 호스트 127.0.0.1 이라 지나간다.
    const old_doc = table_mod.swHosts(tab, canon, table_mod.originHash("http://127.0.0.1:9"), "127.0.0.1", &hb);
    try testing.expect(old_doc.len == 2);
    try testing.expect(table_mod.serviceWorkerRule(set, parts, old_doc, &bg) == null); // 전에는 규칙 91 이 막았다(실측 nav-rej)
    // 이동 자체(목적지 localhost 의 서비스 워커가 대신 받는다) — 그 이동의 호스트만(탭 길과 같다).
    const itself = table_mod.swHosts(tab, canon, table_mod.urlOriginHash(u16, &nav), "localhost", &hb);
    try testing.expect(itself.len == 1 and std.mem.eql(u8, itself[0], "localhost"));
    try testing.expectEqual(@as(u32, 91), table_mod.serviceWorkerRule(set, parts, itself, &bg).?.id);
}

test "A4-R10 A-LOW: 사용자의 뒤로·앞으로 토큰 — 이동을 시작한 뒤의 지금 항목(Chromium 이 건너뛸 항목을 건너뛴 실제 대상)으로 판정한다, 이동이 미뤄졌으면 바로 옆 항목, 읽지 못하면 남긴다" {
    const A: u64 = 0xa;
    const X: u64 = 0xb;
    const H = table_mod.HistoryAt;
    // [X, A(몸짓 없는 같은 주소 pushState — 건너뜀), A] — 뒤로가 A 를 건너뛰어 X 로 간다: 남긴다(전에는 바로 옆 A 만 보아 토큰 없이 막혔다).
    try testing.expect(table_mod.historyTokenStays(H{ .index = 2, .url = A, .step_url = A }, H{ .index = 0, .url = X }));
    // [X, A, A(iframe 만 옮긴 항목)] — 뒤로가 바로 옆 A(같은 주 프레임 주소)로 간다: 거둔다(3 차 LOW-A3-4 그대로).
    try testing.expect(!table_mod.historyTokenStays(H{ .index = 2, .url = A, .step_url = A }, H{ .index = 1, .url = A }));
    // 이동이 미뤄졌다(지금 항목이 그대로 — 진행 중 항목 없음): 바로 옆 항목으로(전의 판정).
    try testing.expect(!table_mod.historyTokenStays(H{ .index = 2, .url = A, .step_url = A }, H{ .index = 2, .url = A }));
    try testing.expect(table_mod.historyTokenStays(H{ .index = 2, .url = A, .step_url = X }, H{ .index = 2, .url = A }));
    try testing.expect(table_mod.historyTokenStays(H{ .index = 0, .url = A }, H{ .index = 0, .url = A })); // 옆을 모른다
    // 앞으로도 같다.
    try testing.expect(table_mod.historyTokenStays(H{ .index = 0, .url = A, .step_url = A }, H{ .index = 2, .url = X }));
    // 읽지 못하면 남긴다.
    try testing.expect(table_mod.historyTokenStays(null, H{ .index = 0, .url = A }));
    try testing.expect(table_mod.historyTokenStays(H{ .index = 1, .url = A, .step_url = A }, null));
    // 거두기는 기록 토큰만 — 새로 고침 토큰은 그대로.
    var t: table_mod.Table = .{};
    defer t.deinit(testing.allocator);
    const canon = table_mod.canonHash(u8, "https://a.test/blk/x");
    t.userNavAction(7, 70, .history, 1000);
    t.dropHistoryToken(70);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .history, 0, canon, 1, "a.test", 1010));
    t.userNavAction(7, 70, .reload, 2000);
    t.dropHistoryToken(70);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .reload, 0, canon, 1, "a.test", 2010));
    // 거두지 않으면 그 기록 이동이 쓴다.
    t.userNavAction(7, 70, .history, 3000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .history, 0, canon, 1, "a.test", 3010));
}

test "A4-R10 A-LOW: 처리기를 부르거나 멈춘 페이지 스크립트를 잇는 에이전트의 DevTools 호출도 사용자 토큰을 거둔다 — 읽기 허용 목록 밖은 모두(새 메서드도)" {
    const st = @import("devtools_table.zig");
    for ([_][]const u8{
        "Page.handleJavaScriptDialog", // alert·confirm 뒤의 페이지 스크립트를 잇는다(그 뒤의 location·history 이동), 떠나기 확인의 답
        "Page.setWebLifecycleState", // freeze·resume 처리기
        "CSS.setStyleTexts", // 스타일 바꾸기 — transitionend·ResizeObserver·IntersectionObserver 처리기
        "Animation.seekAnimations", // animationend·finish 처리기
        "DOMStorage.setDOMStorageItem", // 같은 출처의 다른 문서(같은 탭의 iframe·다른 탭)에 storage 처리기
        "ServiceWorker.dispatchSyncEvent", // 서비스 워커 처리기 — clients 에 postMessage·client.navigate
        "ServiceWorker.skipWaiting", // controllerchange 처리기(흔한 꼴: location.reload())
        // 앞의 목록(2·3 차)도 그대로.
        "Page.navigate",
        "Page.reload",
        "Page.navigateToHistoryEntry",
        "Runtime.evaluate",
        "Runtime.callFunctionOn",
        "Input.dispatchKeyEvent",
        "DOM.focus",
        "DOM.setFileInputFiles",
        "DOM.scrollIntoViewIfNeeded",
        "Emulation.setDeviceMetricsOverride",
        "Debugger.resume",
        "Page.setDocumentContent",
        // 모르는·새 메서드, 읽기 이름의 꼴만 닮은 것.
        "Foo.bar",
        "DOM.getDocumentX",
        "dom.getDocument",
        "Page.createIsolatedWorld",
        "Network.setCookie",
        "Storage.clearDataForOrigin",
    }) |m| {
        if (!st.startsNavigation(m)) std.debug.print("A4-R10 거두지 않음: {s}\n", .{m});
        try testing.expect(st.startsNavigation(m));
    }
    // 읽기는 남긴다 — maru 의 snapshot·찾기·화면 찍기·저장소 읽기·kick 이 쓰는 것.
    for ([_][]const u8{
        "DOM.getDocument",            "DOM.querySelector",           "DOM.describeNode",          "DOM.resolveNode",
        "DOM.getContentQuads",        "Page.captureScreenshot",      "Page.getLayoutMetrics",     "Page.getFrameTree",
        "Page.getNavigationHistory",  "Accessibility.getFullAXTree", "Accessibility.queryAXTree", "Runtime.releaseObjectGroup",
        "Runtime.terminateExecution", "Network.getCookies",          "Target.getTargetInfo",
    }) |m| try testing.expect(!st.startsNavigation(m));
    try testing.expect(!st.startsNavigation(protocol.message.devtools_kick_method));
}
