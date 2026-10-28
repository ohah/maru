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
//! S2(τ 로 잇기 — `Link`): 서비스 워커가 답한 페이지 응답 P 의 `responseTime`(τ — 벽시계 µs)을 워커 응답 W 의 τ 와 정확히 맞춘다(복제·그대로
//! 넘김·다른 탭의 메모는 τ 를 지니고 만든 응답은 새 τ 를 받는다 — 실측 PHASE0 c). 기준 C1(출처 network 만 — http-cache·cache-storage 는
//! 가리킨 기록을 `ambiguous`), C2(τ 있음), C3a(τ ≥ VS — 기록을 켠 때·붙은 워커 세션의 enable 답의 최대, 벽시계가 뒤로 뛴 폭만큼 더),
//! C4(디스크 아닌 W 가 꼭 하나·독 τ·홉 τ·빼는 꼴·나쁜 W·지평), C5(짝 — 표가 W 의 응답 때 정해 `notePair`). C0·C3b′·C6·C7′ 은 표의 몫.
//!
//! 시험이 증명하는 것(S1): 원시 메시지 가르기(끝의 sessionId·머리의 id·메서드), 붙이기는 켬 답 뒤에만, 세대·떼기·모르는 세션, 자리 상한,
//! 타깃 epoch. (S2) C1·C2·C3a·C4·지평·빼는 꼴, 세계 모의기 퍼즈(τ 고리 — 적대 워커의 복제·메모·디스크 적중(같은 τ 다른 본문)·µs 충돌·
//! 기록 전 메모·만든 응답·Cache Storage: 이은 기록의 본문 == P 가 받은 본문).

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

// ── S2: τ 로 잇기(계획 v2 §3 — C1·C2·C3a·C4·C5 의 짝 결과) ─────────────────────────────────────────────────────────────

/// 서비스 워커가 준 페이지 응답의 출처(`serviceWorkerResponseSource`).
pub const Src = enum { network, http_cache, cache_storage, fallback, none };

pub fn srcOf(s: []const u8) Src {
    if (std.mem.eql(u8, s, "network")) return .network;
    if (std.mem.eql(u8, s, "http-cache")) return .http_cache;
    if (std.mem.eql(u8, s, "cache-storage")) return .cache_storage;
    if (std.mem.eql(u8, s, "fallback-code")) return .fallback;
    return .none;
}

/// `responseTime`(벽시계 ms, f64 — µs 까지 실린다)을 µs 정수로. 없거나 이상하면 0(공격 3 L1 — P·W 를 같은 파서로 읽는다).
pub fn tauMicros(ms: ?f64) i64 {
    const v = ms orelse return 0;
    if (!(v > 0 and v < 1e15)) return 0;
    return @intFromFloat(@round(v * 1000.0));
}

/// 워커 요청 하나의 열쇠 — (타깃·epoch, requestId). 같은 서비스 워커의 사건이 탭마다 세션으로 따로 와도 하나다(실측 r1 — 같은 requestId).
pub const WKey = struct {
    target: u64,
    rid: u64,

    pub fn of(target: u64, epoch: u32, rid: []const u8) WKey {
        return .{ .target = target +% @as(u64, epoch) *% 0x9E37_79B9_7F4A_7C15, .rid = hashId(rid) };
    }
};

/// 워커 요청을 맞추기·「설명」 에서 빼는가(공격 1 H2·공격 3 M1): 브라우저가 낸 navigation preload(`preload-N`), 워커가 받은 응답이 다시 서비스
/// 워커의 것(race 라우트), preflight(OPTIONS·`Preflight`), http(s) 밖의 주소(`data:`·`blob:`), 워커 스크립트(sw.js·importScripts — CEF 기록이
/// 없다, PHASE0 d). 이것들은 서비스 워커 갈래 CEF 기록이 없다 — 맞추기에 넣으면 남의 기록을 가져가거나 「설명」 한다. τ 색인에는 남긴다(빼면 같은
/// τ 의 다른 W 가 「꼭 하나」 로 보인다).
pub fn excluded(rid: []const u8, method: []const u8, kind: []const u8, url: []const u8, from_sw: bool) bool {
    if (std.mem.startsWith(u8, rid, "preload-")) return true;
    if (from_sw) return true;
    if (std.mem.eql(u8, method, "OPTIONS") or std.mem.eql(u8, kind, "Preflight")) return true;
    if (std.mem.eql(u8, kind, "Script")) return true;
    if (!(std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://"))) return true;
    return false;
}

pub const W = struct {
    tau: i64 = 0,
    disk: bool = false,
    excluded: bool = false,
    status: u16 = 0,
    /// 응답이 둘 왔다(requestId 재사용 — 공격 2 A13) 또는 짝을 의심해 끝냈다 — 이 W 를 가리키는 P 는 `ambiguous`.
    bad: bool = false,
    /// 짝(CEF 기록 번호 — 0 = 아직). 탭 둘이 다른 짝을 주면 `bad`.
    pair: u64 = 0,
};

pub const TauEntry = struct {
    /// 이 τ 의 첫 W(무엇이든 — C1 의 표시용)와 첫 디스크 아닌 W.
    first: WKey,
    nd_key: ?WKey = null,
    nondisk: u16 = 0,
    disk: u16 = 0,
    /// 어느 W 의 리다이렉트 홉 τ 였다.
    hop: bool = false,
};

/// 판정의 까닭(시험 로그·판정이 본다 — 계획의 「알고 둔 틈」 이름).
pub const Reason = enum {
    /// C1 — Cache Storage(원본 τ 와 만든 τ 가 섞인다)·HTTP 캐시(같은 τ 의 HEAD·Range 적중이 다른 바이트 — 이번 PR 은 모두).
    cache_storage,
    http_cache,
    /// C3a — 붙기 전에 받은 응답(메모).
    before_visible,
    /// C3b′ — 설명되지 않은 서비스 워커 갈래 기록(문 넘김 표지 포함)이 P 의 응답 앞에 있다.
    dark,
    unexplained,
    /// C4.
    no_worker,
    many,
    hop,
    excluded,
    horizon,
    bad_worker,
    /// C5 — 짝이 아직·없다·탭에 없다.
    unpaired,
    not_in_tab,
    /// C6.
    status,
    record_failed,
    /// C0 — 다른 출처 문서의 요청.
    frame_origin,
};

pub const Verdict = union(enum) {
    /// 아직 정하지 못한다(W·짝이 아직) — 시한까지 다시 본다.
    wait,
    /// 잇지 않는다(가리킨 기록이 없다 — `fallback-code`·출처 없음·τ 없음).
    skip,
    /// 잇지 않는다 — `q`(0 이 아니면) 를 `ambiguous` 로 끝낸다.
    ambiguous: struct { reason: Reason, q: u64 = 0 },
    /// q 에 P 의 본문을 붙인다(C0·C3b′·C6·C7′ 은 부른 쪽 — 표).
    link: struct { q: u64, w: WKey, status: u16 },
};

/// τ 색인 상한(sidecar 전체 W 수)과 쫓아내는 묶음.
pub const max_ws: usize = 16_384;
pub const evict_batch: usize = 1_024;
/// C3a 의 여유(벽시계 µs) — 붙는 답과 τ 를 같은 벽시계로 재니 0 이어도 되지만 닫힌 쪽으로 둔다.
pub const visible_margin_us: i64 = 1_000;

pub const Link = struct {
    ws: std.AutoHashMapUnmanaged(WKey, W) = .empty,
    taus: std.AutoHashMapUnmanaged(i64, TauEntry) = .empty,
    /// 넣은 차례(쫓아내기 — 홉 τ 는 `hop_order`).
    order: std.ArrayList(WKey) = .empty,
    hop_order: std.ArrayList(i64) = .empty,
    /// 지평 — 쫓아낸 τ 의 최대(홉 τ 포함). 이하 τ 의 P 는 `ambiguous`, 이하 τ 의 새 W 는 넣지 않는다(공격 1 M6).
    horizon: i64 = 0,
    /// 어느 탭의 표에서든 W 와 짝이 된 CEF 기록 번호(C3b′ 의 「설명됨」 — 탭 사이 사본이 같은 번호다, K3).
    explained: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// 탭마다 VS(벽시계 µs — C3a): 기록을 켠 때·붙은 워커 세션의 enable 답의 최대.
    vs: [max_tabs]struct { browser: BrowserId = 0, wall_us: i64 = 0 } = @splat(.{}),
    /// sidecar 가 본 벽시계 − 단조 시계의 최대와, 그보다 뒤로 뛴 가장 큰 폭(µs — 공격 1 M7: 기록 전에 벽시계가 뒤로 뛰면 그 전 메모의 τ 가 VS
    /// 보다 커진다).
    off_max: i64 = std.math.minInt(i64),
    back_max: i64 = 0,

    pub fn deinit(self: *Link, gpa: std.mem.Allocator) void {
        self.ws.deinit(gpa);
        self.taus.deinit(gpa);
        self.order.deinit(gpa);
        self.hop_order.deinit(gpa);
        self.explained.deinit(gpa);
    }

    /// 시계 표본(벽 − 단조) — 사건마다 부른다. 뒤로 뛴 폭을 쌓는다(줄지 않는다).
    pub fn clockSample(self: *Link, wall_us: i64, mono_us: i64) void {
        const off = wall_us - mono_us;
        if (off > self.off_max) self.off_max = off;
        self.back_max = @max(self.back_max, self.off_max - off);
    }

    fn vsSlot(self: *Link, browser: BrowserId) ?*@TypeOf(self.vs[0]) {
        for (&self.vs) |*v| if (v.browser == browser) return v;
        for (&self.vs) |*v| if (v.browser == 0) {
            v.* = .{ .browser = browser };
            return v;
        };
        return null;
    }

    /// 기록을 켰다·워커 세션의 enable 답이 왔다 — VS 를 올린다(max — 새 타깃마다, 공격 1 M5·공격 2 A6).
    pub fn raiseVisible(self: *Link, browser: BrowserId, wall_us: i64) void {
        const v = self.vsSlot(browser) orelse return;
        v.wall_us = @max(v.wall_us, wall_us);
    }

    pub fn visibleSince(self: *const Link, browser: BrowserId) i64 {
        for (self.vs) |v| if (v.browser == browser) return v.wall_us + self.back_max + visible_margin_us;
        return std.math.maxInt(i64);
    }

    /// 탭의 기록이 끝났다 — VS 를 비운다(다시 켜면 다시 선다).
    pub fn forgetTab(self: *Link, browser: BrowserId) void {
        for (&self.vs) |*v| if (v.browser == browser) {
            v.* = .{};
        };
    }

    /// 기록하는 탭이 없다 — 모두 비운다(공격 2 A14).
    pub fn clear(self: *Link) void {
        self.ws.clearRetainingCapacity();
        self.taus.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
        self.hop_order.clearRetainingCapacity();
        self.explained.clearRetainingCapacity();
        self.horizon = 0;
    }

    fn evict(self: *Link) void {
        const n = @min(evict_batch, self.order.items.len);
        for (self.order.items[0..n]) |k| {
            const w = self.ws.get(k) orelse continue;
            if (w.tau != 0) {
                self.horizon = @max(self.horizon, w.tau);
                _ = self.taus.remove(w.tau);
            }
            if (w.pair != 0) _ = self.explained.remove(w.pair);
            _ = self.ws.remove(k);
        }
        self.order.replaceRangeAssumeCapacity(0, n, &.{});
        const hn = @min(evict_batch, self.hop_order.items.len);
        for (self.hop_order.items[0..hn]) |tau| self.horizon = @max(self.horizon, tau);
        self.hop_order.replaceRangeAssumeCapacity(0, hn, &.{});
    }

    /// 워커 응답(`responseReceived`) — τ 색인에 넣는다. 같은 W 가 다른 탭 세션으로 다시 오면 같은 값이면 둔다(다르면 그 W 는 `bad`).
    pub fn noteResponse(self: *Link, gpa: std.mem.Allocator, key: WKey, tau: i64, disk: bool, excl: bool, status: u16) std.mem.Allocator.Error!void {
        if (self.ws.getPtr(key)) |w| {
            if (w.tau != tau or w.disk != disk) w.bad = true;
            return;
        }
        if (self.order.items.len >= max_ws) self.evict();
        try self.ws.put(gpa, key, .{ .tau = tau, .disk = disk, .excluded = excl, .status = status });
        try self.order.append(gpa, key);
        if (tau == 0 or tau <= self.horizon) return; // τ 없음(data:·blob:) — C2 / 지평 이하는 넣지 않는다(그 τ 의 P 는 지평으로 막힌다)
        const g = try self.taus.getOrPut(gpa, tau);
        if (!g.found_existing) g.value_ptr.* = .{ .first = key };
        if (disk) g.value_ptr.disk +|= 1 else {
            g.value_ptr.nondisk +|= 1;
            if (g.value_ptr.nd_key == null) g.value_ptr.nd_key = key;
        }
    }

    /// 워커 요청의 리다이렉트 홉 응답 τ(`redirectResponse.responseTime`) — 그 τ 를 가리키는 P 는 홉의 것이다(C4).
    pub fn noteHop(self: *Link, gpa: std.mem.Allocator, key: WKey, tau: i64) std.mem.Allocator.Error!void {
        if (tau == 0 or tau <= self.horizon) return;
        if (self.hop_order.items.len >= max_ws) self.evict();
        const g = try self.taus.getOrPut(gpa, tau);
        if (!g.found_existing) g.value_ptr.* = .{ .first = key };
        g.value_ptr.hop = true;
        try self.hop_order.append(gpa, tau);
    }

    /// 표가 W 의 짝을 정했다(W 의 응답 때 — 공격 3 H3). 탭 둘이 다른 기록을 주면 그 W 는 `bad`.
    pub fn notePair(self: *Link, gpa: std.mem.Allocator, key: WKey, q: u64) std.mem.Allocator.Error!void {
        const w = self.ws.getPtr(key) orelse {
            // 응답 전에 짝이 정해지지 않는다(짝은 응답 때) — 응답이 버려졌으면(지평) 짝만 적는다.
            try self.explained.put(gpa, q, {});
            return;
        };
        if (w.pair != 0 and w.pair != q) w.bad = true;
        if (w.pair == 0) w.pair = q;
        try self.explained.put(gpa, q, {});
    }

    /// 표가 W 의 짝을 의심해 끝냈다(둘 이상의 타깃·갈림) — 그 W 를 가리키는 P 는 `ambiguous`.
    pub fn noteBad(self: *Link, key: WKey) void {
        if (self.ws.getPtr(key)) |w| w.bad = true;
    }

    pub fn isExplained(self: *const Link, q: u64) bool {
        return self.explained.contains(q);
    }

    /// C1·C2·C3a·C4·C5 — P(그 탭 `browser`)를 어느 W·기록에 잇는가. C0·C3b′·C6·C7′ 은 부른 쪽(표).
    pub fn decide(self: *const Link, browser: BrowserId, tau: i64, src: Src) Verdict {
        switch (src) {
            .fallback, .none => return .skip,
            .cache_storage, .http_cache => {
                const reason: Reason = if (src == .cache_storage) .cache_storage else .http_cache;
                // 가리킨 W 의 기록은 `ambiguous`(그 기록의 응답일 수도, 만든 응답일 수도 — C1).
                const e = self.taus.get(tau) orelse return .{ .ambiguous = .{ .reason = reason } };
                const w = self.ws.get(e.first) orelse return .{ .ambiguous = .{ .reason = reason } };
                return .{ .ambiguous = .{ .reason = reason, .q = w.pair } };
            },
            .network => {},
        }
        if (tau == 0) return .skip; // C2
        if (tau < self.visibleSince(browser)) return .{ .ambiguous = .{ .reason = .before_visible } }; // C3a
        if (tau <= self.horizon) return .{ .ambiguous = .{ .reason = .horizon } };
        const e = self.taus.get(tau) orelse return .wait; // W 가 아직(시한 뒤 `no_worker`)
        if (e.hop) return .{ .ambiguous = .{ .reason = .hop } };
        if (e.nondisk == 0) return .wait; // 디스크 적중뿐 — 네트워크 W 가 아직
        if (e.nondisk > 1) return .{ .ambiguous = .{ .reason = .many } }; // 독 τ(영영 — 지우지 않는다)
        const key = e.nd_key orelse return .wait;
        const w = self.ws.get(key) orelse return .{ .ambiguous = .{ .reason = .horizon } };
        if (w.excluded) return .{ .ambiguous = .{ .reason = .excluded } };
        if (w.bad) return .{ .ambiguous = .{ .reason = .bad_worker, .q = w.pair } };
        if (w.pair == 0) return .wait; // 짝이 아직(시한 뒤 `unpaired`)
        return .{ .link = .{ .q = w.pair, .w = key, .status = w.status } };
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

const gpa_t = std.testing.allocator;

test "S2 C1·C2: 출처 network 만 잇는다 — http-cache·cache-storage 는 가리킨 기록을 ambiguous, 만든 응답·출처 없음·τ 없음은 잇지 않는다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    l.raiseVisible(5, 1_000_000);
    const k = WKey.of(1, 0, "1.1");
    try l.noteResponse(gpa_t, k, 2_000_000, false, false, 200);
    try l.notePair(gpa_t, k, 77);
    try testing.expectEqual(Verdict{ .link = .{ .q = 77, .w = k, .status = 200 } }, l.decide(5, 2_000_000, .network));
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .http_cache, .q = 77 } }, l.decide(5, 2_000_000, .http_cache));
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .cache_storage, .q = 77 } }, l.decide(5, 2_000_000, .cache_storage));
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .cache_storage } }, l.decide(5, 9_000_000, .cache_storage)); // 만든 응답을 put — τ 가 없다
    try testing.expectEqual(Verdict.skip, l.decide(5, 2_000_000, .fallback));
    try testing.expectEqual(Verdict.skip, l.decide(5, 2_000_000, .none));
    try testing.expectEqual(Verdict.skip, l.decide(5, 0, .network));
    try testing.expectEqual(Src.http_cache, srcOf("http-cache"));
    try testing.expectEqual(Src.none, srcOf("weird"));
    try testing.expectEqual(@as(i64, 1_793_149_143_299_712), tauMicros(1.793149143299712e+12));
    try testing.expectEqual(@as(i64, 5_000), tauMicros(5));
    try testing.expectEqual(@as(i64, 0), tauMicros(null));
    try testing.expectEqual(@as(i64, 0), tauMicros(-1));
}

test "S2 C3a: 붙기 전에 받은 응답(메모)은 ambiguous — VS 는 새 워커 세션의 enable 답마다 오르고, 벽시계가 뒤로 뛴 폭만큼 더 닫힌다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    const k = WKey.of(1, 0, "1.1");
    try l.noteResponse(gpa_t, k, 5_000_000, false, false, 200);
    try l.notePair(gpa_t, k, 9);
    // 기록하지 않는 탭 — VS 가 없다(닫힌 쪽).
    try testing.expectEqual(Reason.before_visible, l.decide(5, 5_000_000, .network).ambiguous.reason);
    l.raiseVisible(5, 4_000_000);
    try testing.expect(l.decide(5, 5_000_000, .network) == .link);
    // 늦게 붙은 타깃(새 범위·갱신) — 그 enable 답 앞의 τ 는 닫힌다.
    l.raiseVisible(5, 6_000_000);
    try testing.expectEqual(Reason.before_visible, l.decide(5, 5_000_000, .network).ambiguous.reason);
    l.raiseVisible(5, 1_000); // 내려가지 않는다
    try testing.expectEqual(Reason.before_visible, l.decide(5, 5_000_000, .network).ambiguous.reason);
    // 경계: VS + 여유.
    const k2 = WKey.of(1, 0, "1.2");
    try l.noteResponse(gpa_t, k2, 6_000_000 + visible_margin_us, false, false, 200);
    try l.notePair(gpa_t, k2, 10);
    try testing.expect(l.decide(5, 6_000_000 + visible_margin_us, .network) == .link);
    try testing.expectEqual(Reason.before_visible, l.decide(5, 6_000_000 + visible_margin_us - 1, .network).ambiguous.reason);
    // 벽시계가 뒤로 2 초 뛰었다 — VS 가 그만큼 늦게 선다(뛰기 전의 메모 τ 가 VS 보다 클 수 있다).
    l.clockSample(10_000_000, 1_000);
    l.clockSample(8_000_000, 2_000);
    try testing.expectEqual(@as(i64, 2_001_000), l.back_max);
    try testing.expectEqual(Reason.before_visible, l.decide(5, 6_000_000 + visible_margin_us, .network).ambiguous.reason);
    l.forgetTab(5);
    try testing.expectEqual(Reason.before_visible, l.decide(5, 9_000_000_000, .network).ambiguous.reason);
}

test "S2 C4: τ 가 꼭 하나 — 같은 τ 의 디스크 아닌 W 둘은 영영 독, 디스크 적중은 걸러 네트워크 W 를, 홉 τ·빼는 꼴·나쁜 W·지평은 ambiguous, W·짝이 아직이면 기다린다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    l.raiseVisible(5, 1);
    // 아직 W 가 없다.
    try testing.expectEqual(Verdict.wait, l.decide(5, 3_000, .network));
    // 디스크 적중이 먼저 온 τ — 네트워크 W 를 기다린다.
    const d = WKey.of(1, 0, "d");
    try l.noteResponse(gpa_t, d, 3_000, true, false, 200);
    try testing.expectEqual(Verdict.wait, l.decide(5, 3_000, .network));
    const n = WKey.of(1, 0, "n");
    try l.noteResponse(gpa_t, n, 3_000, false, false, 200);
    try testing.expectEqual(Verdict.wait, l.decide(5, 3_000, .network)); // 짝이 아직
    try l.notePair(gpa_t, n, 31);
    try testing.expectEqual(Verdict{ .link = .{ .q = 31, .w = n, .status = 200 } }, l.decide(5, 3_000, .network));
    // 다른 타깃의 같은 τ(µs 충돌) — 독. 짝이 있어도.
    try l.noteResponse(gpa_t, WKey.of(2, 0, "z"), 3_000, false, false, 200);
    try testing.expectEqual(Reason.many, l.decide(5, 3_000, .network).ambiguous.reason);
    // 홉 τ.
    const r = WKey.of(1, 0, "r");
    try l.noteHop(gpa_t, r, 4_000);
    try l.noteResponse(gpa_t, r, 4_500, false, false, 200);
    try l.notePair(gpa_t, r, 40);
    try testing.expectEqual(Reason.hop, l.decide(5, 4_000, .network).ambiguous.reason);
    try testing.expect(l.decide(5, 4_500, .network) == .link);
    // 빼는 꼴(preload 등) — τ 색인에는 있다.
    const p = WKey.of(1, 0, "preload-3");
    try l.noteResponse(gpa_t, p, 5_000, false, true, 200);
    try testing.expectEqual(Reason.excluded, l.decide(5, 5_000, .network).ambiguous.reason);
    // 같은 W 가 다른 τ 로 다시(requestId 재사용) — 나쁜 W.
    const q = WKey.of(1, 0, "q");
    try l.noteResponse(gpa_t, q, 6_000, false, false, 200);
    try l.notePair(gpa_t, q, 60);
    try l.noteResponse(gpa_t, q, 6_100, false, false, 200);
    try testing.expectEqual(Reason.bad_worker, l.decide(5, 6_000, .network).ambiguous.reason);
    // 탭 둘이 다른 짝 — 나쁜 W, 그 기록도 ambiguous 로.
    const s = WKey.of(1, 0, "s");
    try l.noteResponse(gpa_t, s, 7_000, false, false, 200);
    try l.notePair(gpa_t, s, 70);
    try l.notePair(gpa_t, s, 71);
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .bad_worker, .q = 70 } }, l.decide(5, 7_000, .network));
    try testing.expect(l.isExplained(70) and l.isExplained(71));
    // 짝을 의심해 끝낸 W.
    const u = WKey.of(1, 0, "u");
    try l.noteResponse(gpa_t, u, 8_000, false, false, 200);
    l.noteBad(u);
    try testing.expectEqual(Reason.bad_worker, l.decide(5, 8_000, .network).ambiguous.reason);
}

test "S2 지평: 넘쳐 쫓아낸 τ 이하는 ambiguous, 그 이하 τ 의 새 W 는 넣지 않는다 — 쫓아낸 짝의 「설명됨」 도 지운다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    l.raiseVisible(5, 1);
    var buf: [16]u8 = undefined;
    for (0..max_ws) |i| {
        const k = WKey.of(1, 0, try std.fmt.bufPrint(&buf, "w{d}", .{i}));
        try l.noteResponse(gpa_t, k, 10_000 + @as(i64, @intCast(i)), false, false, 200);
        try l.notePair(gpa_t, k, 100 + i);
    }
    try testing.expect(l.decide(5, 10_000, .network) == .link);
    try l.noteResponse(gpa_t, WKey.of(1, 0, "x"), 999_999, false, false, 200);
    try testing.expectEqual(@as(i64, 10_000 + evict_batch - 1), l.horizon);
    try testing.expectEqual(Reason.horizon, l.decide(5, 10_000, .network).ambiguous.reason);
    try testing.expect(!l.isExplained(100));
    try testing.expect(l.decide(5, 10_000 + evict_batch, .network) == .link);
    // 지평 이하 τ 의 늦은 W 는 넣지 않는다 — 그 τ 의 P 는 여전히 지평으로.
    try l.noteResponse(gpa_t, WKey.of(1, 0, "late"), 10_005, false, false, 200);
    try testing.expectEqual(Reason.horizon, l.decide(5, 10_005, .network).ambiguous.reason);
    l.clear();
    try testing.expectEqual(@as(i64, 0), l.horizon);
}

test "S2: 빼는 워커 요청 — preload·워커가 받은 서비스 워커 응답·preflight·스크립트·http(s) 밖" {
    try testing.expect(excluded("preload-12", "GET", "Other", "https://a/x", false));
    try testing.expect(excluded("7.1", "GET", "Fetch", "https://a/x", true));
    try testing.expect(excluded("ab12", "OPTIONS", "Preflight", "https://a/x", false));
    try testing.expect(excluded("7.2", "GET", "Script", "https://a/sw.js", false));
    try testing.expect(excluded("7.3", "GET", "Other", "data:application/json,1", false));
    try testing.expect(excluded("7.4", "GET", "Fetch", "blob:https://a/1", false));
    try testing.expect(!excluded("7.5", "GET", "Fetch", "https://a/x", false));
    try testing.expect(!excluded("7.6", "POST", "Fetch", "HTTP://a/x", false));
}

// ── S2 세계 모의기(τ 고리 — 짝은 이상적, C3b′ 는 「P 의 응답 앞에 시작한 fetch 의 W 는 모두 왔다」 로 둔다). 적대 워커가 받은 응답을 아무 P 에
// 주고(복제·메모·다른 탭), 같은 항목의 디스크 적중(HEAD·Range — 같은 τ 다른 본문), 만든 응답, Cache Storage, preload, 기록 전 메모, µs 충돌을
// 섞는다. 참: 잇는 기록 q 의 본문 id == P 가 받은 본문 id. 셋째 조건(C3b′)·C5 의 참은 S3b 의 맞물린 퍼즈가 본다. ──

test "S2 퍼즈(세계 모의기 — τ 고리): 이은 기록의 본문은 늘 P 가 받은 본문이다" {
    var prng = std.Random.DefaultPrng.init(0x5c0d_e002);
    const rnd = prng.random();
    var links: usize = 0;
    var ambs: usize = 0;
    var waits: usize = 0;
    var round: usize = 0;
    while (round < 400) : (round += 1) {
        var l: Link = .{};
        defer l.deinit(gpa_t);
        const vs: i64 = 1_000_000;
        l.raiseVisible(5, vs);
        const Fetch = struct { tau: i64, body: u64, q: u64, disk: bool, excl: bool, visible: bool, key: WKey };
        var fs: [64]Fetch = undefined;
        var n: usize = 0;
        var base: i64 = vs + visible_margin_us;
        var body_id: u64 = 1;
        // 기록 전 메모(보이지 않는다 — τ < VS).
        const memo_n = rnd.uintLessThan(usize, 3);
        for (0..memo_n) |_| {
            fs[n] = .{ .tau = vs - 1 - @as(i64, rnd.uintLessThan(u32, 50_000)), .body = body_id, .q = 0, .disk = false, .excl = false, .visible = false, .key = WKey.of(9, 0, "memo") };
            body_id += 1;
            n += 1;
        }
        const k_total = 8 + rnd.uintLessThan(usize, 40);
        var rb: [24]u8 = undefined;
        while (n < k_total) : (n += 1) {
            const kind = rnd.uintLessThan(u8, 10);
            const target: u64 = 1 + rnd.uintLessThan(u64, 3);
            const key = WKey.of(target, 0, try std.fmt.bufPrint(&rb, "{d}.{d}", .{ round, n }));
            if (kind == 0 and n > memo_n) {
                // 앞 네트워크 fetch 의 항목에 대한 디스크 적중(HEAD·Range — 같은 τ, 다른 본문).
                const src_i = memo_n + rnd.uintLessThan(usize, n - memo_n);
                fs[n] = .{ .tau = fs[src_i].tau, .body = body_id, .q = 5000 + n, .disk = true, .excl = false, .visible = true, .key = key };
            } else {
                // 네트워크 fetch — µs 충돌이 잦게(작은 범위).
                base += @as(i64, rnd.uintLessThan(u32, 30));
                fs[n] = .{ .tau = base, .body = body_id, .q = 5000 + n, .disk = false, .excl = kind == 1, .visible = true, .key = key };
            }
            body_id += 1;
        }
        // W 를 섞인 차례로 알린다(짝도 응답 때).
        for (fs[0..n]) |f| if (f.visible) {
            try l.noteResponse(gpa_t, f.key, f.tau, f.disk, f.excl, 200);
            if (!f.excl) try l.notePair(gpa_t, f.key, f.q);
        };
        // P: 받은 응답 중 아무것이나(복제·메모·다른 탭), 또는 만든 응답·Cache Storage.
        var pi: usize = 0;
        while (pi < 30) : (pi += 1) {
            const pick = rnd.uintLessThan(u8, 10);
            if (pick == 0) {
                // 만든 응답 — 새 τ(아무 W 의 τ 와 같을 수도 있다 — 그래도 출처가 fallback-code 라 잇지 않는다).
                const v = l.decide(5, base - @as(i64, rnd.uintLessThan(u32, 200)), .fallback);
                try testing.expect(v == .skip);
                continue;
            }
            const f = fs[rnd.uintLessThan(usize, n)];
            const src: Src = if (f.disk) .http_cache else if (pick == 1) .cache_storage else .network;
            const v = l.decide(5, f.tau, src);
            switch (v) {
                .link => |x| {
                    links += 1;
                    // 참: q 의 fetch 의 본문 == P 가 받은 본문(f.body).
                    var q_body: u64 = 0;
                    for (fs[0..n]) |g| if (g.q == x.q and g.visible) {
                        q_body = g.body;
                    };
                    if (q_body != f.body) {
                        std.debug.print("S2 fuzz WRONG round {d}: P body {d} (tau {d} src {s}) linked q {d} body {d}\n", .{ round, f.body, f.tau, @tagName(src), x.q, q_body });
                        return error.TestUnexpectedResult;
                    }
                    try testing.expect(src == .network);
                },
                .ambiguous => ambs += 1,
                .wait => waits += 1,
                .skip => {},
            }
        }
    }
    std.debug.print("\n[S2 fuzz] links {d} · ambiguous {d} · wait {d}\n", .{ links, ambs, waits });
    try testing.expect(links > 1000);
}
