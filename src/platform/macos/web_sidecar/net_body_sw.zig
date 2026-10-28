//! 서비스 워커 CDP 의 표(W9d② — docs/plans/web-osr-backend.md 「서비스 워커 갈래 새 설계」). CEF 를 모른다 — `net_body.zig` 가 원시 CDP
//! 메시지와 시각을 준다. UI 스레드 하나만 쓴다.
//!
//! S1(길 닦기): 기록하는 탭의 페이지 세션에 `Target.setAutoAttach` 를 건 뒤 붙는 서비스 워커 세션의 표와 세대.
//!   - 붙이기는 `Network.enable` 의 **성공 답 뒤에만**(`arm`) — 켬이 실패해도 auto-attach 가 남아 서비스 워커가 멈추지 않는 길을 막는다(공격 2 A1).
//!   - 기록이 멈추는 모든 길이 `detachAll` 을 부른다(`net_body_table` 의 `.detach_workers` 일 — 끔·밸브·켬 실패·등록 실패·렌더러 죽음·탭 닫힘·
//!     DevTools 떨어짐). 세대를 올려 옛 세션의 늦은 사건을 버린다(공격 2 A8).
//!   - 붙이지 않은(떼는 중·옛 세대·기록하지 않는) 탭에 온 `attachedToTarget` 은 곧 떼라고 답한다(`attached` → `.detach`).
//!   - 원시 메시지의 sessionId 는 끝이 꼭 `,"sessionId":"<16 진>"}` 이고 표에 있는 것만 받는다(공격 2 A12 — 모르면 CEF 에 맡긴다).
//!
//! 시험이 증명하는 것(S1): 원시 메시지 가르기(끝의 sessionId·머리의 id·메서드), 붙이기는 켬 답 뒤에만, 세대·떼기·모르는 세션, 자리 상한,
//! 타깃 epoch.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const BrowserId = protocol.message.BrowserId;

pub const max_tabs = @import("registry.zig").capacity;
/// 붙은 워커 세션 수 상한(sidecar 전체) — 기록하는 탭 × 그 출처의 서비스 워커. 넘치면 새 세션은 곧 뗀다(그 워커의 W 는 보이지 않는다 —
/// 잇기는 그 탭을 어둠으로 친다, S3b).
pub const max_sessions: usize = 64;
pub const max_sid_bytes: usize = 64;

/// 원시 메시지 끝의 `,"sessionId":"…"}` 에서 sessionId(16 진 글자 1..64)를 꺼낸다. 아니면 null — 페이지 세션의 메시지다.
/// CDP 는 자식 세션의 메시지에 sessionId 를 맨 끝에 붙인다(실측 p1 — 285/285). 끝을 꼭 맞춰야 한다: 페이지의 큰 본문 답이 끝 근처에 비슷한 글을
/// 품어도 JSON 글 안의 따옴표는 이스케이프되어 `"}` 로 끝나는 꼴을 만들지 못한다.
pub fn sessionTail(m: []const u8) ?[]const u8 {
    if (m.len < 20 or m[m.len - 1] != '}' or m[m.len - 2] != '"') return null;
    var i = m.len - 2;
    while (i > 0 and i > m.len -| (max_sid_bytes + 3)) {
        i -= 1;
        const ch = m[i];
        if (ch == '"') break;
        if (!std.ascii.isHex(ch)) return null;
    } else return null;
    const sid = m[i + 1 .. m.len - 2];
    if (sid.len == 0) return null;
    const key = ",\"sessionId\":";
    if (i < key.len or !std.mem.eql(u8, m[i - key.len .. i], key)) return null;
    return sid;
}

/// 원시 메시지가 명령의 답이면 그 번호(머리가 `{"id":N`), 아니면 null(사건).
pub fn resultId(m: []const u8) ?i64 {
    const head = "{\"id\":";
    if (!std.mem.startsWith(u8, m, head)) return null;
    var j: usize = head.len;
    var n: i64 = 0;
    var digits: usize = 0;
    while (j < m.len and m[j] >= '0' and m[j] <= '9' and digits < 12) : (j += 1) {
        n = n * 10 + (m[j] - '0');
        digits += 1;
    }
    if (digits == 0) return null;
    return n;
}

/// 사건의 메서드 이름(머리 `{"method":"…"` — Chromium 은 method 를 맨 앞에 쓴다). 아니면 null.
pub fn eventMethod(m: []const u8) ?[]const u8 {
    const head = "{\"method\":\"";
    if (!std.mem.startsWith(u8, m, head)) return null;
    const rest = m[head.len..@min(m.len, head.len + 96)];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

/// 답이 성공인가(`"result":` 가 있고 `"error":` 가 머리에 없다).
pub fn resultOk(m: []const u8) bool {
    const head = m[0..@min(m.len, 48)];
    return std.mem.indexOf(u8, head, "\"result\":") != null and std.mem.indexOf(u8, head, "\"error\":") == null;
}

pub fn hashId(s: []const u8) u64 {
    return @max(1, std.hash.Wyhash.hash(0x5763, s));
}

pub const Session = struct {
    sid: [max_sid_bytes]u8 = undefined,
    sid_len: u8 = 0,
    browser: BrowserId = 0,
    /// `targetId` 의 해시 — 같은 서비스 워커에 탭마다 세션이 따로 붙는다(실측 r1).
    target: u64 = 0,
    gen: u32 = 0,
    /// 그 타깃이 다시 뜬 수(`Inspector.targetReloadedAfterCrash` — requestId 를 다시 쓸 수 있다, 공격 2 A13).
    epoch: u32 = 0,
    /// 이 세션으로 보낸 `Network.enable` 의 번호(0 = 아직) — 답이 오면 `enabled_wall_us`.
    enable_id: i64 = 0,
    /// `Network.enable` 성공 답을 받은 벽시계(µs — 0 = 아직). 이 뒤에 워커에 닿은 응답만 보인다(S3b 의 C3a).
    enabled_wall_us: i64 = 0,

    pub fn sidSlice(self: *const Session) []const u8 {
        return self.sid[0..self.sid_len];
    }
};

pub const TabState = struct {
    browser: BrowserId = 0,
    /// 떼기마다 오른다 — 붙은 세션의 세대가 다르면 옛 사건이다.
    gen: u32 = 1,
    /// `setAutoAttach{autoAttach:true}` 를 보냈다(떼기 전까지).
    armed: bool = false,
    /// 렌더러가 죽어 뗐다 — 다음 새 문서에서 다시 건다(기록은 이어진다 — J5).
    rearm_on_doc: bool = false,
};

pub const Attach = enum { keep, detach };

pub const Sw = struct {
    sessions: [max_sessions]Session = @splat(.{}),
    tabs: [max_tabs]TabState = @splat(.{}),

    fn tab(self: *Sw, browser: BrowserId) ?*TabState {
        if (browser == 0) return null;
        for (&self.tabs) |*t| if (t.browser == browser) return t;
        for (&self.tabs) |*t| if (t.browser == 0) {
            t.* = .{ .browser = browser };
            return t;
        };
        return null;
    }

    pub fn armed(self: *Sw, browser: BrowserId) bool {
        const t = self.tab(browser) orelse return false;
        return t.armed;
    }

    /// `Network.enable` 성공 답 — 붙이기를 건다(보낼 것이면 참; 이미 걸었으면 거짓).
    pub fn arm(self: *Sw, browser: BrowserId) bool {
        const t = self.tab(browser) orelse return false;
        if (t.armed) return false;
        t.armed = true;
        t.rearm_on_doc = false;
        return true;
    }

    /// 페이지 세션의 `Target.attachedToTarget`(서비스 워커) — 붙인 탭이면 세션을 적고 `keep`(부른 쪽이 그 세션에 `Network.enable`), 아니면
    /// `detach`(부른 쪽이 `Target.detachFromTarget`). 자리가 없어도 `detach`.
    pub fn attached(self: *Sw, browser: BrowserId, sid: []const u8, target_id: []const u8) Attach {
        const t = self.tab(browser) orelse return .detach;
        if (!t.armed or sid.len == 0 or sid.len > max_sid_bytes) return .detach;
        if (self.find(sid)) |s| {
            // 같은 세션이 다시 알려졌다(두 번 건 auto-attach) — 그대로 둔다.
            if (s.browser == browser) return .keep;
            return .detach;
        }
        for (&self.sessions) |*s| if (s.browser == 0) {
            s.* = .{ .browser = browser, .target = hashId(target_id), .gen = t.gen };
            @memcpy(s.sid[0..sid.len], sid);
            s.sid_len = @intCast(sid.len);
            return .keep;
        };
        return .detach;
    }

    /// 이 세션으로 보낸 `Network.enable` 의 번호를 적는다.
    pub fn noteEnable(self: *Sw, sid: []const u8, id: i64) void {
        if (self.find(sid)) |s| s.enable_id = id;
    }

    /// 세션의 답 — `Network.enable` 의 것이면 성공일 때 벽시계를 적는다. 그 세션이면 참.
    pub fn result(self: *Sw, sid: []const u8, id: i64, ok: bool, wall_us: i64) bool {
        const s = self.find(sid) orelse return false;
        if (s.enable_id == id and ok and s.enabled_wall_us == 0) s.enabled_wall_us = @max(wall_us, 1);
        return true;
    }

    /// `Target.detachedFromTarget` — 그 세션을 지운다.
    pub fn detached(self: *Sw, sid: []const u8) void {
        if (self.find(sid)) |s| s.* = .{};
    }

    /// 타깃이 다시 떴다(같은 세션 — 실측 b: 다시 attach 가 오지 않는다). requestId 가 다시 쓰일 수 있어 epoch 를 올린다.
    pub fn reloaded(self: *Sw, sid: []const u8) void {
        if (self.find(sid)) |s| s.epoch +%= 1;
    }

    pub fn find(self: *Sw, sid: []const u8) ?*Session {
        for (&self.sessions) |*s| if (s.browser != 0 and std.mem.eql(u8, s.sidSlice(), sid)) return s;
        return null;
    }

    /// 지금 세대의 세션인가(옛 세대·모르는 세션의 사건은 버린다).
    pub fn live(self: *Sw, sid: []const u8) ?*Session {
        const s = self.find(sid) orelse return null;
        const t = self.tab(s.browser) orelse return null;
        if (s.gen != t.gen or !t.armed) return null;
        return s;
    }

    /// 기록이 멈춘다 — 그 탭의 세션을 모두 지우고 세대를 올린다. 걸려 있었으면 참(부른 쪽이 `setAutoAttach{autoAttach:false}` 를 보낸다 —
    /// 실측: 답보다 먼저 붙은 세션마다 `detachedFromTarget` 이 오고, 그 뒤 +28 초에 서비스 워커가 멈췄다).
    pub fn detachAll(self: *Sw, browser: BrowserId) bool {
        const t = self.tab(browser) orelse return false;
        const was = t.armed;
        t.armed = false;
        t.gen +%= 1;
        for (&self.sessions) |*s| if (s.browser == browser) {
            s.* = .{};
        };
        return was;
    }

    /// 렌더러가 죽어 뗐다 — 다음 새 문서에서 다시 건다.
    pub fn setRearm(self: *Sw, browser: BrowserId) void {
        if (self.tab(browser)) |t| t.rearm_on_doc = true;
    }

    /// 다시 걸 때가 되었나(한 번만 참).
    pub fn takeRearm(self: *Sw, browser: BrowserId) bool {
        const t = self.tab(browser) orelse return false;
        if (!t.rearm_on_doc) return false;
        t.rearm_on_doc = false;
        return true;
    }

    /// 탭이 닫혔다 — 자리를 비운다.
    pub fn forget(self: *Sw, browser: BrowserId) void {
        _ = self.detachAll(browser);
        for (&self.tabs) |*t| if (t.browser == browser) {
            t.* = .{};
        };
    }

    pub fn sessionCount(self: *const Sw, browser: BrowserId) usize {
        var n: usize = 0;
        for (self.sessions) |s| if (s.browser != 0 and (browser == 0 or s.browser == browser)) {
            n += 1;
        };
        return n;
    }
};

// ── 시험 ─────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "S1: 원시 메시지 가르기 — 끝의 sessionId 는 꼭 맞을 때만, 머리의 답 번호·사건 메서드" {
    try testing.expectEqualStrings("8B44E1A0FF", sessionTail("{\"method\":\"Network.requestWillBeSent\",\"params\":{\"a\":1},\"sessionId\":\"8B44E1A0FF\"}").?);
    try testing.expectEqualStrings("E0F8", sessionTail("{\"id\":1342177281,\"result\":{},\"sessionId\":\"E0F8\"}").?);
    // 페이지 세션의 메시지 — sessionId 가 params 안에만 있다(Target.attachedToTarget).
    try testing.expect(sessionTail("{\"method\":\"Target.attachedToTarget\",\"params\":{\"sessionId\":\"8B44\",\"waitingForDebugger\":false}}") == null);
    // 글 값 안의 꼴은 이스케이프되어 끝이 맞지 않는다.
    try testing.expect(sessionTail("{\"id\":5,\"result\":{\"body\":\"x,\\\"sessionId\\\":\\\"AB\\\"}\"}}") == null);
    try testing.expect(sessionTail("{\"id\":5,\"result\":{\"body\":\"x\"},\"sessionId\":\"ZZ\"}") == null); // 16 진 아님
    try testing.expect(sessionTail("{\"id\":5,\"result\":{},\"sessionId\":\"\"}") == null);
    try testing.expect(sessionTail("{\"id\":5,\"result\":{},\"sessionIdX\":\"AB\"}") == null);
    try testing.expect(sessionTail("") == null);
    try testing.expectEqual(@as(?i64, 1342177281), resultId("{\"id\":1342177281,\"result\":{},\"sessionId\":\"E0F8\"}"));
    try testing.expect(resultId("{\"method\":\"X\"}") == null);
    try testing.expectEqualStrings("Network.responseReceived", eventMethod("{\"method\":\"Network.responseReceived\",\"params\":{}}").?);
    try testing.expect(eventMethod("{\"id\":1}") == null);
    try testing.expect(resultOk("{\"id\":1,\"result\":{},\"sessionId\":\"AB\"}"));
    try testing.expect(!resultOk("{\"id\":1,\"error\":{\"code\":-32000},\"sessionId\":\"AB\"}"));
}

test "S1: 붙이기는 켬 답 뒤에만 — 걸지 않은 탭에 온 세션은 떼고, 떼기는 세대를 올려 옛 세션의 사건을 버린다" {
    var sw: Sw = .{};
    // 걸기 전에 온 attach(다른 길로 걸린 것·경쟁)는 뗀다.
    try testing.expectEqual(Attach.detach, sw.attached(5, "AA", "T1"));
    try testing.expect(sw.arm(5));
    try testing.expect(!sw.arm(5)); // 두 번 걸지 않는다
    try testing.expectEqual(Attach.keep, sw.attached(5, "AA", "T1"));
    try testing.expectEqual(Attach.keep, sw.attached(5, "AA", "T1")); // 같은 세션이 다시 알려져도 하나
    try testing.expectEqual(@as(usize, 1), sw.sessionCount(5));
    sw.noteEnable("AA", 77);
    try testing.expect(sw.result("AA", 77, true, 1_000));
    try testing.expectEqual(@as(i64, 1_000), sw.find("AA").?.enabled_wall_us);
    try testing.expect(sw.live("AA") != null);
    try testing.expect(sw.live("BB") == null); // 모르는 세션
    // 떼기 — 걸려 있었다(부른 쪽이 setAutoAttach{false} 를 보낸다), 세션은 없어지고 옛 세션의 사건은 버린다.
    try testing.expect(sw.detachAll(5));
    try testing.expect(!sw.detachAll(5)); // 두 번째는 보낼 것이 없다
    try testing.expect(sw.live("AA") == null);
    try testing.expectEqual(Attach.detach, sw.attached(5, "AC", "T1")); // 뗀 뒤 늦게 온 attach 는 뗀다
    // 다시 켬 — 새 세대.
    try testing.expect(sw.arm(5));
    try testing.expectEqual(Attach.keep, sw.attached(5, "AD", "T1"));
    try testing.expect(sw.live("AD") != null);
    // 다른 탭의 세션 번호를 이 탭이 알리면 뗀다.
    try testing.expect(sw.arm(6));
    try testing.expectEqual(Attach.detach, sw.attached(6, "AD", "T1"));
    sw.forget(5);
    try testing.expectEqual(@as(usize, 0), sw.sessionCount(5));
}

test "S1: 자리 상한 — 넘치면 새 세션은 떼고, 다시 뜬 타깃은 epoch 를 올린다, 떨어진 세션은 지운다" {
    var sw: Sw = .{};
    try testing.expect(sw.arm(5));
    var buf: [8]u8 = undefined;
    for (0..max_sessions) |i| {
        const sid = try std.fmt.bufPrint(&buf, "{X:0>4}", .{i});
        try testing.expectEqual(Attach.keep, sw.attached(5, sid, "T"));
    }
    try testing.expectEqual(Attach.detach, sw.attached(5, "FFFFF", "T"));
    sw.detached("0000");
    try testing.expectEqual(Attach.keep, sw.attached(5, "FFFFF", "T"));
    sw.reloaded("FFFFF");
    try testing.expectEqual(@as(u32, 1), sw.find("FFFFF").?.epoch);
    try testing.expect(!sw.result("0000", 1, true, 5)); // 지운 세션의 답은 모른다
}
