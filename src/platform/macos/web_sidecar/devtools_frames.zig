//! 다른 사이트 iframe(OOPIF)의 DevTools 세션 표(사용자 결정 2026-11-20 「iframe·폴더 둘 다」 — CEF 를 모르는 부분, `pure_tests`). 다른 사이트의
//! iframe 은 다른 렌더러 프로세스라 그 탭의 root DevTools 연결에서 그 문서가 보이지 않는다(실측 — `DOM.describeNode` 에 `frameId` 만 있고
//! `contentDocument` 가 없다, `Page.getFrameTree` 에도 없다). maru 의 업로드가 그 frame 의 칸에 넣으려면 그 frame 의 타깃에 붙은 자식 세션
//! (`flatten`)으로 호출을 보내야 한다. 이 표는 (탭, frame) 마다 그 세션을 쥔다 — 붙이기·보내기는 `devtools.zig` 가 한다.
//!
//! - **붙이기**: OOPIF 의 DevTools 타깃은 누군가 찾기 전에는 없다 — `attachToTarget{frameId}` 만 보내면 「No target with given id found」(실측
//!   probe-attach-oopif, CEF 154). 그래서 root 로 `Target.getTargetInfo{}`(이 탭 자신의 page 타깃 id) → `Target.getTargets{filter:[{type:"iframe"}]}`
//!   (타깃이 생긴다 — 그 답에 그 frame 이 `type:"iframe"` 이고 `targetId == frameId` 로 있다) → `Target.attachToTarget{targetId, flatten:true}`. 그 답의
//!   sessionId 를 쥐고 세워 둔 호출을 그 세션으로 보낸다. 그 frame 이 iframe 타깃이 아니거나(page·worker 를 가리키는 id — 렌더러가 보고한 frameId 를
//!   믿지 않는다, 공격 A1-5) 그 `parentId` 사슬이 이 탭의 page 타깃에 닿지 않으면(목록은 브라우저 전체다 — 다른 탭의 iframe, 적대 검증 3·4 회차) 붙지 않는다.
//! - **새로 붙지 않는 호출**: 붙기는 걷기의 처음 호출(`Page.getFrameTree`·`Page.createIsolatedWorld`)에만 — 원격 객체(objectId)를 싣는 호출은 그 객체를
//!   만든 세션이어야 뜻이 있다(공격 A1-3). 세션이 없으면 보내지 않고 `send_failed`(확실히 안 갔다 — 넣기면 「넣지 않았다」).
//! - **허용 목록**: frame 세션으로는 업로드가 쓰는 메서드만(`frameMethodAllowed` — 공격 A1-5: 둘째 세션이 새 특권 통로가 되지 않게).
//! - **쉬는 세션**: 마지막으로 쓴 지 `idle_ms` 넘고 보낸 호출이 없는 세션만 뗀다(op 사이의 틈에 떼지 않게 — 공격 A1-4). 자리가 없으면 그 호출은 `busy`.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const message = protocol.message;
const BrowserId = message.BrowserId;

/// 세션 자리 — 탭마다, 모두.
pub const per_browser: usize = 4;
pub const capacity: usize = 16;
/// 쉰 세션을 떼는 때(마지막 쓴 뒤). 업로드의 걷기·넣기·읽기는 ms 단위로 이어진다 — 사본을 만드는 동안(오래 걸릴 수 있다)은 객체를 쥐지 않는다.
pub const idle_ms: i64 = 10_000;
/// 이 표의 root 호출(목록·붙기·떼기) 번호 대역 — 다른 사용처와 겹치지 않는다(흉내 1<<26, 기록 1<<28, 표 1<<29, 막기 1<<27, trace 1<<25).
pub const id_base: i32 = 1 << 24;
pub const id_end: i32 = (1 << 24) + (1 << 20);
pub const max_frame_bytes = message.max_devtools_frame_bytes;
pub const max_sid_bytes = 64;

/// `info`(이 탭 자신의 page 타깃 id — 붙을 iframe 이 이 탭의 것인지 가른다) → `listing`(그 OOPIF 의 타깃을 만들고 부모 사슬을 본다) → `attaching` → `ready`.
pub const State = enum { info, listing, attaching, ready };

pub const Session = struct {
    browser: BrowserId,
    frame_buf: [max_frame_bytes]u8 = undefined,
    frame_len: u8 = 0,
    sid_buf: [max_sid_bytes]u8 = undefined,
    sid_len: u8 = 0,
    state: State = .info,
    /// 기다리는 root 호출(목록·붙기)의 번호.
    req: i32 = 0,
    /// 세대 — 자리를 열 때마다 새 값(같은 frame 에 다시 붙은 세션과 앞 세션을 가른다: 시한이 지난 호출이 새 세션의 `inflight` 를 줄이지 않게 —
    /// 적대 검증 3·4 회차).
    gen: u32 = 0,
    /// 이 탭 자신의 page 타깃 id(`info` 의 답) — iframe 타깃의 부모 사슬이 여기 닿아야 붙는다.
    own_buf: [max_sid_bytes]u8 = undefined,
    own_len: u8 = 0,
    last_ms: i64,
    /// 이 세션으로 보내 아직 답을 받지 않은 호출 수(떼지 않는다).
    inflight: u16 = 0,

    pub fn frame(self: *const Session) []const u8 {
        return self.frame_buf[0..self.frame_len];
    }
    pub fn sid(self: *const Session) []const u8 {
        return self.sid_buf[0..self.sid_len];
    }
    pub fn own(self: *const Session) []const u8 {
        return self.own_buf[0..self.own_len];
    }
};

pub const Table = struct {
    slots: [capacity]?Session = @splat(null),
    next_id: i32 = id_base,
    next_gen: u32 = 1,

    pub fn takeId(self: *Table) i32 {
        const id = self.next_id;
        self.next_id = if (self.next_id + 1 >= id_end) id_base else self.next_id + 1;
        return id;
    }

    pub fn find(self: *Table, browser: BrowserId, f: []const u8) ?*Session {
        for (&self.slots) |*s| if (s.*) |*v| if (v.browser == browser and std.mem.eql(u8, v.frame(), f)) return v;
        return null;
    }

    pub fn bySid(self: *Table, sid: []const u8) ?*Session {
        for (&self.slots) |*s| if (s.*) |*v| if (v.state == .ready and std.mem.eql(u8, v.sid(), sid)) return v;
        return null;
    }

    /// 그 (탭, frame) 의 그 세대 세션(보낸 호출의 세션 — 같은 frame 에 새로 붙은 세션이 아니다).
    pub fn findGen(self: *Table, browser: BrowserId, f: []const u8, gen: u32) ?*Session {
        const s = self.find(browser, f) orelse return null;
        return if (s.gen == gen) s else null;
    }

    pub fn byReq(self: *Table, id: i32) ?*Session {
        for (&self.slots) |*s| if (s.*) |*v| if (v.state != .ready and v.req == id) return v;
        return null;
    }

    pub const Open = union(enum) {
        /// 새 자리(목록부터) — `evicted` 가 있으면 그 세션을 먼저 뗀다(sid 는 그 값으로).
        ok: struct { session: *Session, evicted: ?Session },
        /// 자리가 없다(모두 쓰는 중) — 그 호출은 `busy`.
        full,
    };

    /// 새 세션 자리를 연다. 탭의 자리·모든 자리가 차면 쉰 지 `idle_ms` 넘고 보낸 호출이 없는 것 가운데 가장 오래된 것을 비운다.
    pub fn open(self: *Table, browser: BrowserId, f: []const u8, now_ms: i64) Open {
        std.debug.assert(f.len > 0 and f.len <= max_frame_bytes);
        var of_browser: usize = 0;
        var used: usize = 0;
        for (self.slots) |s| if (s) |v| {
            used += 1;
            if (v.browser == browser) of_browser += 1;
        };
        var evicted: ?Session = null;
        if (of_browser >= per_browser or used >= capacity) {
            const only_browser = of_browser >= per_browser;
            var oldest: ?*?Session = null;
            for (&self.slots) |*s| if (s.*) |v| {
                if (only_browser and v.browser != browser) continue;
                if (v.inflight != 0 or v.state != .ready or now_ms - v.last_ms < idle_ms) continue;
                if (oldest == null or v.last_ms < oldest.?.*.?.last_ms) oldest = s;
            };
            const slot = oldest orelse return .full;
            evicted = slot.*;
            slot.* = null;
        }
        for (&self.slots) |*s| if (s.* == null) {
            s.* = .{ .browser = browser, .last_ms = now_ms, .gen = self.next_gen };
            self.next_gen +%= 1;
            if (self.next_gen == 0) self.next_gen = 1;
            const v = &s.*.?;
            @memcpy(v.frame_buf[0..f.len], f);
            v.frame_len = @intCast(f.len);
            return .{ .ok = .{ .session = v, .evicted = evicted } };
        };
        return .full;
    }

    pub fn remove(self: *Table, s: *Session) void {
        for (&self.slots) |*x| if (x.*) |*v| if (v == s) {
            x.* = null;
            return;
        };
    }

    /// 쉰 지 `idle_ms` 넘고 보낸 호출이 없는 ready 세션 하나를 꺼낸다(뗄 것 — null 까지 되풀이).
    pub fn takeIdle(self: *Table, now_ms: i64) ?Session {
        for (&self.slots) |*x| if (x.*) |v| if (v.state == .ready and v.inflight == 0 and now_ms - v.last_ms >= idle_ms) {
            x.* = null;
            return v;
        };
        return null;
    }

    /// 그 탭의 세션 하나를 꺼낸다(탭이 닫혔다·root 가 떨어졌다 — null 까지).
    pub fn takeForBrowser(self: *Table, browser: BrowserId) ?Session {
        for (&self.slots) |*x| if (x.*) |v| if (v.browser == browser) {
            x.* = null;
            return v;
        };
        return null;
    }

    pub fn isEmpty(self: *const Table) bool {
        for (self.slots) |s| if (s != null) return false;
        return true;
    }
};

/// frame 세션으로 보낼 수 있는 메서드 — maru 의 업로드가 쓰는 것만(공격 A1-5).
pub fn frameMethodAllowed(method: []const u8) bool {
    for ([_][]const u8{ "Page.getFrameTree", "Page.createIsolatedWorld", "Runtime.evaluate", "Runtime.callFunctionOn", "Runtime.releaseObjectGroup", "DOM.describeNode", "DOM.resolveNode", "DOM.setFileInputFiles" }) |m|
        if (std.mem.eql(u8, method, m)) return true;
    return false;
}

/// 세션이 없을 때 붙여도 되는 호출인가 — 걷기의 처음 호출(원격 객체를 싣지 않는다 — 공격 A1-3).
pub fn attachAllowed(method: []const u8) bool {
    return std.mem.eql(u8, method, "Page.getFrameTree") or std.mem.eql(u8, method, "Page.createIsolatedWorld");
}

/// `Target.getTargetInfo{}`(root — 그 탭 자신)의 답의 targetId.
pub fn ownTargetOf(gpa: std.mem.Allocator, result: []const u8, out: []u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, result, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const info = parsed.value.object.get("targetInfo") orelse return null;
    if (info != .object) return null;
    const id = info.object.get("targetId") orelse return null;
    if (id != .string or id.string.len == 0 or id.string.len > out.len) return null;
    @memcpy(out[0..id.string.len], id.string);
    return out[0..id.string.len];
}

/// `Target.getTargets` 의 답에 그 frame 이 **이 탭의** iframe 타깃으로 있는가 — `targetId == frame`·`type == "iframe"` 이고, 그 `parentId` 를 따라
/// 올라가면(다른 사이트 iframe 안의 다른 사이트 iframe 은 그 iframe 타깃을 부모로 둔다) 이 탭의 page 타깃(`own`)에 닿는다. 그 목록은 브라우저 전체의
/// 것이다(적대 검증 3·4 회차 — 렌더러가 보고한 frameId 로 다른 탭의 iframe 에 붙지 않게).
pub fn targetsHaveIframeIn(gpa: std.mem.Allocator, result: []const u8, frame: []const u8, own: []const u8) bool {
    if (own.len == 0) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, result, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const infos = parsed.value.object.get("targetInfos") orelse return false;
    if (infos != .array) return false;
    var cur: []const u8 = frame;
    var hops: usize = 0;
    while (hops < 16) : (hops += 1) {
        const t = iframeTarget(infos.array.items, cur) orelse return false;
        const parent = t.object.get("parentId") orelse return false;
        if (parent != .string) return false;
        if (std.mem.eql(u8, parent.string, own)) return true;
        cur = parent.string; // 그 부모도 iframe 타깃이어야 한다(아니면 다른 탭·모르는 것)
    }
    return false;
}

fn iframeTarget(items: []const std.json.Value, id: []const u8) ?std.json.Value {
    for (items) |t| {
        if (t != .object) continue;
        const tid = t.object.get("targetId") orelse continue;
        const kind = t.object.get("type") orelse continue;
        if (tid == .string and kind == .string and std.mem.eql(u8, tid.string, id) and std.mem.eql(u8, kind.string, "iframe")) return t;
    }
    return null;
}

/// `Target.attachToTarget` 의 답의 sessionId(16 진 1..64 자). 아니면 null.
pub fn sessionIdOf(result: []const u8) ?[]const u8 {
    const key = "\"sessionId\":\"";
    const at = std.mem.indexOf(u8, result, key) orelse return null;
    const rest = result[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const sid = rest[0..end];
    if (sid.len == 0 or sid.len > max_sid_bytes) return null;
    for (sid) |b| if (!std.ascii.isHex(b)) return null;
    return sid;
}

/// 자식 세션의 원시 답(`{"id":N,"result":{…},"sessionId":"…"}` 또는 `"error":{…}`)에서 `result`·`error` 객체 글을 잘라 낸다(그 세션의 sid 로 끝난다는
/// 것은 부른 쪽이 `sessionTail` 로 보았다). 모양이 다르면 null.
pub fn rawBody(m: []const u8, sid: []const u8) ?struct { ok: bool, body: []const u8 } {
    if (!std.mem.startsWith(u8, m, "{\"id\":")) return null;
    var j: usize = 6;
    while (j < m.len and m[j] >= '0' and m[j] <= '9') j += 1;
    const ok = std.mem.startsWith(u8, m[j..], ",\"result\":");
    const err = std.mem.startsWith(u8, m[j..], ",\"error\":");
    if (!ok and !err) return null;
    const start = j + (if (ok) ",\"result\":".len else ",\"error\":".len);
    const tail_len = ",\"sessionId\":\"".len + sid.len + "\"}".len;
    if (m.len < start + tail_len) return null;
    const body = m[start .. m.len - tail_len];
    if (body.len == 0 or body[0] != '{' or body[body.len - 1] != '}') return null;
    return .{ .ok = ok, .body = body };
}

/// 세션이 사라진 뒤 그 세션으로 보냈던 호출에 줄 CDP 오류(엔진이 「문서가 사라졌다」 로 읽는 글 — Chromium 의 같은 경우의 글).
pub const session_gone_error = "{\"code\":-32001,\"message\":\"Session with given id not found.\"}";
/// 그 frame 이 iframe 타깃이 아니다·없다(엔진이 「frame 이 사라졌다」 로 읽는 글).
pub const no_frame_error = "{\"code\":-32000,\"message\":\"No frame for given id found\"}";
/// 목록에 그 frame 이 이 탭의 iframe 타깃으로 없다(다른 탭의 iframe·page·worker 의 id — 부모 사슬) — 엔진에는 `no_frame_error` 와 같고(「No frame」),
/// 판정자가 「이 탭에 없다」 로 거절한 것을 가른다(적대 검증 14 회차 — 다른 까닭의 같은 글이면 그 검사를 지워도 판정이 통했다).
pub const not_this_tab_error = "{\"code\":-32000,\"message\":\"No frame for given id found in this tab\"}";

// ── 시험 ──
const testing = std.testing;

test "frame 세션 표: 탭마다 넷·모두 열여섯 — 차면 쉰 지 10 초 넘고 보낸 호출이 없는 ready 세션 가운데 가장 오래된 것을 비우고, 없으면 full" {
    var t: Table = .{};
    var frames: [5][4]u8 = undefined;
    for (&frames, 0..) |*f, i| f.* = .{ 'A', 'B', 'C', '0' + @as(u8, @intCast(i)) };
    for (0..per_browser) |i| {
        const r = t.open(7, &frames[i], 100 + @as(i64, @intCast(i)));
        r.ok.session.state = .ready;
        r.ok.session.sid_len = 2;
        r.ok.session.sid_buf[0] = 'E';
        r.ok.session.sid_buf[1] = '0' + @as(u8, @intCast(i));
    }
    // 아직 쉬지 않았다 — full.
    try testing.expect(t.open(7, &frames[4], 200) == .full);
    // 다른 탭은 자리가 있다.
    try testing.expect(t.open(8, &frames[4], 200) == .ok);
    // 10 초 뒤 — 가장 오래된(ABC0) 것을 비운다. 보낸 호출이 있는 것은 비우지 않는다.
    t.find(7, &frames[0]).?.inflight = 1;
    const r = t.open(7, &frames[4], 100 + idle_ms + 5);
    try testing.expectEqualStrings("ABC1", r.ok.evicted.?.frame());
    try testing.expect(t.find(7, &frames[1]) == null);
    try testing.expect(t.find(7, &frames[0]) != null);
    try testing.expect(t.bySid("E0") != null);
}

test "frame 세션 표: 쉰 세션 꺼내기·탭의 세션 꺼내기·번호 대역" {
    var t: Table = .{ .next_id = id_end - 1 };
    try testing.expectEqual(id_end - 1, t.takeId());
    try testing.expectEqual(id_base, t.takeId());
    const a = t.open(1, "AA", 0).ok.session;
    a.state = .ready;
    a.req = 5;
    try testing.expect(t.byReq(5) == null); // ready 는 번호로 찾지 않는다
    const b = t.open(1, "BB", 0).ok.session;
    b.req = 6;
    try testing.expect(a.gen != b.gen and a.gen != 0); // 자리마다 새 세대(같은 frame 에 다시 붙은 세션을 가른다)
    try testing.expect(t.findGen(1, "BB", b.gen) == b and t.findGen(1, "BB", a.gen) == null);
    try testing.expect(t.byReq(6) == b);
    try testing.expect(t.takeIdle(idle_ms - 1) == null);
    try testing.expectEqualStrings("AA", t.takeIdle(idle_ms).?.frame());
    try testing.expect(t.takeIdle(idle_ms * 2) == null); // listing 은 쉰 것이 아니다
    try testing.expectEqualStrings("BB", t.takeForBrowser(1).?.frame());
    try testing.expect(t.isEmpty());
}

test "frame 세션: 허용 목록·붙여도 되는 호출·getTargets 의 iframe·sessionId·원시 답 자르기" {
    try testing.expect(frameMethodAllowed("DOM.setFileInputFiles"));
    for ([_][]const u8{ "Network.enable", "Target.attachToTarget", "Page.navigate", "Input.dispatchMouseEvent", "Runtime.runIfWaitingForDebugger" }) |m| try testing.expect(!frameMethodAllowed(m));
    try testing.expect(attachAllowed("Page.createIsolatedWorld") and attachAllowed("Page.getFrameTree"));
    try testing.expect(!attachAllowed("DOM.setFileInputFiles") and !attachAllowed("Runtime.releaseObjectGroup"));
    // 이 탭(P1)의 iframe AB12, 그 안의 다른 사이트 iframe A2(부모 AB12), 다른 탭(P2)의 iframe CD34, page 타깃 EF56.
    const targets = "{\"targetInfos\":[{\"targetId\":\"AB12\",\"type\":\"iframe\",\"parentId\":\"P1\"},{\"targetId\":\"A2\",\"type\":\"iframe\",\"parentId\":\"AB12\"},{\"targetId\":\"CD34\",\"type\":\"iframe\",\"parentId\":\"P2\"},{\"targetId\":\"EF56\",\"type\":\"page\"}]}";
    try testing.expect(targetsHaveIframeIn(testing.allocator, targets, "AB12", "P1"));
    try testing.expect(targetsHaveIframeIn(testing.allocator, targets, "A2", "P1")); // 중첩 — 사슬이 이 탭에 닿는다
    try testing.expect(!targetsHaveIframeIn(testing.allocator, targets, "CD34", "P1")); // 다른 탭의 iframe — 붙지 않는다
    try testing.expect(!targetsHaveIframeIn(testing.allocator, targets, "EF56", "P1")); // page 타깃 — 붙지 않는다
    try testing.expect(!targetsHaveIframeIn(testing.allocator, targets, "ZZ99", "P1"));
    try testing.expect(!targetsHaveIframeIn(testing.allocator, targets, "AB12", ""));
    try testing.expect(!targetsHaveIframeIn(testing.allocator, "[", "AB12", "P1"));
    // 부모 사슬이 고리면 끝이 있다.
    try testing.expect(!targetsHaveIframeIn(testing.allocator, "{\"targetInfos\":[{\"targetId\":\"X1\",\"type\":\"iframe\",\"parentId\":\"X2\"},{\"targetId\":\"X2\",\"type\":\"iframe\",\"parentId\":\"X1\"}]}", "X1", "P1"));
    var ob: [64]u8 = undefined;
    try testing.expectEqualStrings("P1", ownTargetOf(testing.allocator, "{\"targetInfo\":{\"targetId\":\"P1\",\"type\":\"page\"}}", &ob).?);
    try testing.expect(ownTargetOf(testing.allocator, "{}", &ob) == null);
    try testing.expectEqualStrings("2DA9D3CC", sessionIdOf("{\"sessionId\":\"2DA9D3CC\"}").?);
    try testing.expect(sessionIdOf("{\"sessionId\":\"x\\\"y\"}") == null);
    const raw = "{\"id\":536870913,\"result\":{\"object\":{\"objectId\":\"1.2\"}},\"sessionId\":\"AB\"}";
    const got = rawBody(raw, "AB").?;
    try testing.expect(got.ok);
    try testing.expectEqualStrings("{\"object\":{\"objectId\":\"1.2\"}}", got.body);
    const e = rawBody("{\"id\":9,\"error\":{\"code\":-32000,\"message\":\"x\"},\"sessionId\":\"AB\"}", "AB").?;
    try testing.expect(!e.ok);
    try testing.expectEqualStrings("{\"code\":-32000,\"message\":\"x\"}", e.body);
    try testing.expect(rawBody("{\"method\":\"X\",\"params\":{},\"sessionId\":\"AB\"}", "AB") == null);
}
