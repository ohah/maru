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
//! 타깃 epoch. 재검증 7 차: 남의 출처 세션의 탭마다 몫(N13)과 넘친 세션을 세워 두기(곧 떼면 되풀이되었다), 벽시계 뒤로 뛰기의 잃음이 그 폭
//! 동안뿐인 것(N19a)과 한가한 동안의 뛰기(N19b). (S2) C1·C2·C3a·C4·지평·빼는 꼴, 세계 모의기 퍼즈(τ 고리 — 적대 워커의 복제·메모·디스크 적중(같은 τ 다른 본문)·µs 충돌·
//! 기록 전 메모·만든 응답·Cache Storage: 이은 기록의 본문 == P 가 받은 본문).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const BrowserId = protocol.message.BrowserId;

pub const max_tabs = @import("registry.zig").capacity;
/// 붙은 워커 세션 수 상한(sidecar 전체) — 기록하는 탭 × 그 출처의 서비스 워커. 넘치면 새 세션은 곧 뗀다(그 워커의 W 는 보이지 않는다 —
/// 잇기는 그 탭을 어둠으로 친다, S3b).
pub const max_sessions: usize = 64;
/// 재검증 6 차 F14c: 탭 하나가 쥘 수 있는 세션 수 — 넷이 모여야 전체가 찬다(W9d① 의 동시 요청과 같은 꼴). 전에는 한 탭(서비스 워커가 많은
/// 출처)이 64 를 다 쥐면 그 뒤 기록을 켠 다른 탭의 세션은 모두 곧 떼어져 그 탭의 서비스 워커 본문을 모두 잃었다(v20l r14-many — 70 개 중 64).
pub const max_sessions_per_tab: usize = 16;
/// 재검증 6 차 F13: 탭의 맨 위 출처가 아닌 워커 세션(다른 출처 iframe 의 워커·이동 전후)을 떼기까지 기다리는 때(단조 µs). 곧 떼지 않는 까닭:
/// 이동하는 탭에 새 출처의 워커가 붙는 사건과 맨 위 주소가 바뀌는 사건(`on_address_change`)은 차례가 정해지지 않았다 — 먼저 붙은 새 출처의
/// 워커를 곧 떼면 다시 붙을 때까지 그 출처의 W 를 잃어 서비스 워커 갈래 기록이 설명되지 않는다(어둠). 기다리는 동안 맨 위 출처가 그 워커의
/// 것이 되면 남긴다(`retarget`).
pub const foreign_grace_us: i64 = 3_000_000;
pub const max_sid_bytes: usize = 64;
/// 재검증 7 차(N13): 탭 하나가 쥘 수 있는 남의 출처 세션 수 — 탭 몫 16(맨 위 출처)과 따로 묶는다. 전에는 남의 출처 세션을 어디에도 세지 않아
/// 다른 출처 iframe 이 워커를 잇달아 띄우는 탭 하나가 전체 64 를 쥐었고(그동안 다른 기록 탭의 워커가 붙지 못해 0/20), 넘친 세션을 곧 떼면
/// Chromium 이 같은 워커를 다시 붙여 붙임·뗌이 30 초에 16 000 번 되풀이되었다(실측 v20m r13-flood).
pub const max_foreign_per_tab: usize = 4;
/// 재검증 7 차(N13): 몫을 넘은 세션은 곧 떼지 않고 `Network.enable` 없이 「세워 둔다」(`Sw.parked`) — 그 사건은 삼키고 `foreign_grace_us`
/// 뒤에 뗀다. 곧 떼면 Chromium 의 auto-attach 가 같은 워커를 곧 다시 붙여 되풀이했다 — 세워 두면 되풀이가 그 시한마다 한 번으로 준다. 자리가
/// 없으면 곧 뗀다(전의 길). 자리 수: 실측 r13-flood(다른 출처 iframe 이 200 ms 마다 워커 다섯을 띄우고 3.5 초 뒤 푼다 — 동시에 약 90)에서 64 는
/// 넘쳐 같은 워커를 57 번까지 다시 붙였다 — 넉넉히 256(한 자리 약 80 바이트).
pub const max_parked: usize = 256;

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
    /// 재검증 6 차 F13: 워커 스크립트 주소의 출처 해시(`net_body_table.originHash` — 0 = 모른다)와, 그 탭의 맨 위 출처가 아니게 된 단조 시각
    /// (0 = 맨 위 출처의 워커). 0 이 아니면 `foreign_grace_us` 뒤에 뗀다(`takeForeign`).
    origin: u64 = 0,
    foreign_since: i64 = 0,
    /// 재검증 6 차 F13·D1: 남의 출처였다가 맨 위 출처의 것이 된 단조 시각(0 = 붙을 때부터 맨 위 출처의 것). 그 앞에 시작한 이 세션의 W 는
    /// 제 기록이 이 탭에 없을 수 있어(문은 그때의 맨 위 출처로 붙일 탭을 골랐다) 맞추기에 넣지 않는다(`Table.workerEventFrom`).
    own_since: i64 = 0,

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

/// `park` — 몫을 넘었다(재검증 7 차 N13): 세워 두었다(부른 쪽은 `Network.enable` 을 보내지 않고 시한 뒤 뗀다 — `takeForeign`).
pub const Attach = enum { keep, park, detach };

/// 재검증 7 차: `noteOrigin` 의 답 — 맨 위 출처의 세션·남의 출처 세션(시한 뒤 뗀다)·남의 출처 몫을 넘어 세워 둔 세션(표에서 빠졌다)·세워 둘
/// 자리도 없어 표에서 뺀 세션(부른 쪽이 곧 뗀다).
pub const Origin = enum { own, foreign, park, drop };

/// 재검증 7 차(N13): 세워 둔 세션(표 밖 — 사건은 모르는 세션으로 삼킨다).
const Parked = struct {
    browser: BrowserId = 0,
    sid: [max_sid_bytes]u8 = undefined,
    sid_len: u8 = 0,
    /// 이 시각 + `foreign_grace_us` 에 뗀다.
    since: i64 = 0,
};

pub const Sw = struct {
    sessions: [max_sessions]Session = @splat(.{}),
    tabs: [max_tabs]TabState = @splat(.{}),
    parked: [max_parked]Parked = @splat(.{}),

    /// 그 탭의 자리(없으면 null). 자리를 잡는 것은 `arm` 하나다 — 재검증 6 차(F16 과 같은 꼴): 전에는 묻기만 하는 길(끔의 `detachAll` 등)도
    /// 자리를 잡아, 기록을 끈 뒤 닫힌 탭(표에 없어 닫힘의 떼기 일이 오지 않는다)의 자리가 남았다 — 32 번이면 새 탭에 붙이기를 걸지 못했다.
    fn tab(self: *Sw, browser: BrowserId) ?*TabState {
        if (browser == 0) return null;
        for (&self.tabs) |*t| if (t.browser == browser) return t;
        return null;
    }

    fn tabOrNew(self: *Sw, browser: BrowserId) ?*TabState {
        if (self.tab(browser)) |t| return t;
        if (browser == 0) return null;
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

    /// 자리를 쥔 탭 수(시험이 새는 자리를 본다).
    pub fn tabCount(self: *const Sw) usize {
        var n: usize = 0;
        for (self.tabs) |t| if (t.browser != 0) {
            n += 1;
        };
        return n;
    }

    /// `Network.enable` 성공 답 — 붙이기를 건다(보낼 것이면 참; 이미 걸었으면 거짓).
    pub fn arm(self: *Sw, browser: BrowserId) bool {
        const t = self.tabOrNew(browser) orelse return false;
        if (t.armed) return false;
        t.armed = true;
        t.rearm_on_doc = false;
        return true;
    }

    /// 페이지 세션의 `Target.attachedToTarget`(서비스 워커) — 붙인 탭이면 세션을 적고 `keep`(부른 쪽이 그 세션에 `Network.enable`), 아니면
    /// `detach`(부른 쪽이 `Target.detachFromTarget`). 자리가 없어도(전체 `max_sessions`·그 탭 `max_sessions_per_tab` — 재검증 6 차 F14c) `detach`.
    pub fn attached(self: *Sw, browser: BrowserId, sid: []const u8, target_id: []const u8) Attach {
        return self.attachedAt(browser, sid, target_id, 0);
    }

    /// `attached` — 세워 둘 때의 시각(`now_us` — 그 뒤 `foreign_grace_us` 에 뗀다)을 준다.
    pub fn attachedAt(self: *Sw, browser: BrowserId, sid: []const u8, target_id: []const u8, now_us: i64) Attach {
        const t = self.tab(browser) orelse return .detach;
        if (!t.armed or sid.len == 0 or sid.len > max_sid_bytes) return .detach;
        if (self.find(sid)) |s| {
            // 같은 세션이 다시 알려졌다(두 번 건 auto-attach) — 그대로 둔다.
            if (s.browser == browser) return .keep;
            return .detach;
        }
        if (self.parkedIndex(sid)) |k| return if (self.parked[k].browser == browser) .park else .detach;
        // 탭 몫은 맨 위 출처의 세션만 센다 — 떼기를 기다리는 남의 출처 세션(이동 전 출처의 워커 — `foreign_grace_us`)이 몫을 쥐면 옮겨 간
        // 출처의 워커가 붙지 못했다(v20l r14-many 실측: 워커 70 개 출처에서 옮긴 탭). 남의 출처 세션은 따로 묶는다(`noteOrigin`).
        // 재검증 7 차(N13): 몫을 넘으면 세워 둔다(곧 떼면 되풀이되었다).
        if (self.ownCount(browser) >= max_sessions_per_tab) return if (self.park(browser, sid, now_us)) .park else .detach;
        for (&self.sessions) |*s| if (s.browser == 0) {
            s.* = .{ .browser = browser, .target = hashId(target_id), .gen = t.gen };
            @memcpy(s.sid[0..sid.len], sid);
            s.sid_len = @intCast(sid.len);
            return .keep;
        };
        return if (self.park(browser, sid, now_us)) .park else .detach;
    }

    /// 재검증 7 차(N13): 세션 하나를 세워 둔다(자리가 없으면 거짓 — 부른 쪽이 곧 뗀다).
    fn park(self: *Sw, browser: BrowserId, sid: []const u8, since: i64) bool {
        if (sid.len == 0 or sid.len > max_sid_bytes) return false;
        for (&self.parked) |*p| if (p.browser == 0) {
            p.* = .{ .browser = browser, .since = since };
            @memcpy(p.sid[0..sid.len], sid);
            p.sid_len = @intCast(sid.len);
            return true;
        };
        return false;
    }

    fn parkedIndex(self: *const Sw, sid: []const u8) ?usize {
        for (self.parked, 0..) |p, k| if (p.browser != 0 and std.mem.eql(u8, p.sid[0..p.sid_len], sid)) return k;
        return null;
    }

    /// 세워 둔 세션인가(시험·진단).
    pub fn isParked(self: *const Sw, sid: []const u8) bool {
        return self.parkedIndex(sid) != null;
    }

    pub fn parkedCount(self: *const Sw, browser: BrowserId) usize {
        var n: usize = 0;
        for (self.parked) |p| if (p.browser != 0 and (browser == 0 or p.browser == browser)) {
            n += 1;
        };
        return n;
    }

    /// 남의 출처 세션 수(떼기를 기다린다 — 그 탭의 따로 묶은 몫, 재검증 7 차 N13).
    pub fn foreignCount(self: *const Sw, browser: BrowserId) usize {
        var n: usize = 0;
        for (self.sessions) |s| if (s.browser == browser and s.browser != 0 and s.foreign_since != 0) {
            n += 1;
        };
        return n;
    }

    /// 재검증 6 차 F13: 붙은 세션의 출처(워커 스크립트 주소의 출처 해시)를 적고 그 탭의 맨 위 출처 `top` 과 견준다 — 같으면 참(맨 위 출처의
    /// 워커), 아니면 `foreign_since` 를 세운다(부른 쪽이 `foreign_grace_us` 뒤에 뗀다 — `takeForeign`). 모르는 출처(0)는 늘 남의 것이다.
    /// 재검증 7 차(N13): 남의 출처 세션이 그 탭의 몫(`max_foreign_per_tab`)을 넘으면 표에서 빼 세워 둔다(`.park` — 부른 쪽은 enable 하지 않는다).
    pub fn noteOrigin(self: *Sw, sid: []const u8, origin: u64, top: u64, now_us: i64) Origin {
        const s = self.find(sid) orelse return .foreign;
        s.origin = origin;
        const own = origin != 0 and origin == top;
        if (own) {
            if (s.foreign_since != 0) s.own_since = @max(now_us, 1);
            s.foreign_since = 0;
            return .own;
        }
        if (s.foreign_since == 0 and self.foreignCount(s.browser) >= max_foreign_per_tab) {
            const parked = self.park(s.browser, sid, @max(now_us, 1));
            s.* = .{};
            return if (parked) .park else .drop;
        }
        if (s.foreign_since == 0) s.foreign_since = @max(now_us, 1);
        return .foreign;
    }

    pub fn isForeign(self: *Sw, sid: []const u8) bool {
        const s = self.find(sid) orelse return false;
        return s.foreign_since != 0;
    }

    /// 재검증 6 차 F13: 그 탭의 맨 위 출처가 `top` 으로 바뀌었다 — 세션마다 다시 견준다. 맨 위 출처의 것이 아니게 된 세션(앞 문서 출처의
    /// 워커)은 `foreign_since` 를 세우고, 맨 위 출처의 것이 된 세션(이동 중 주소가 바뀌기 전에 붙은 새 출처의 워커)은 풀어 그 enable 답의
    /// 벽시계(아직이면 0) 중 최대를 돌려준다 — 부른 쪽이 그 탭의 VS 를 올린다(남의 출처인 동안에는 올리지 않았다).
    pub fn retarget(self: *Sw, browser: BrowserId, top: u64, now_us: i64) i64 {
        var raise: i64 = 0;
        for (&self.sessions) |*s| if (s.browser == browser) {
            const own = s.origin != 0 and s.origin == top;
            if (own and s.foreign_since != 0) {
                s.foreign_since = 0;
                s.own_since = @max(now_us, 1);
                raise = @max(raise, s.enabled_wall_us);
            } else if (!own and s.foreign_since == 0) {
                // 재검증 7 차(N13): 남의 출처 몫을 넘는 앞 출처 세션은 곧 뗀다(세워 두고 시한을 지난 것으로 — 다음 `takeForeign`). 전에는 출처를
                // 잇달아 바꾸면 앞 출처 세션이 모두 시한까지 남아 한 탭이 전체 64 를 쥐었다(v20m P13b).
                if (self.foreignCount(browser) >= max_foreign_per_tab) {
                    if (self.park(browser, s.sidSlice(), @max(now_us, 1) - foreign_grace_us)) {
                        s.* = .{};
                        continue;
                    }
                }
                s.foreign_since = @max(now_us, 1);
            }
        };
        return raise;
    }

    /// 재검증 6 차 F13: 시한(`foreign_grace_us`)이 지난 남의 출처 세션 하나를 표에서 빼 돌려준다(부른 쪽이 떼고 null 까지 되풀이).
    /// 재검증 7 차(N13): 세워 둔 세션도 시한이 지나면 돌려준다(그 출처는 0).
    pub fn takeForeign(self: *Sw, now_us: i64) ?Session {
        for (&self.sessions) |*s| if (s.browser != 0 and s.foreign_since != 0 and now_us - s.foreign_since >= foreign_grace_us) {
            const out = s.*;
            s.* = .{};
            return out;
        };
        for (&self.parked) |*p| if (p.browser != 0 and now_us - p.since >= foreign_grace_us) {
            var out: Session = .{ .browser = p.browser, .sid_len = p.sid_len };
            @memcpy(out.sid[0..p.sid_len], p.sid[0..p.sid_len]);
            p.* = .{};
            return out;
        };
        return null;
    }

    /// 아직 떼지 않은 남의 출처 세션 중 가장 이른 `foreign_since`(없으면 null — 부른 쪽이 다음 확인을 건다).
    pub fn nextForeign(self: *const Sw) ?i64 {
        var at: ?i64 = null;
        for (self.sessions) |s| if (s.browser != 0 and s.foreign_since != 0) {
            at = if (at) |a| @min(a, s.foreign_since) else s.foreign_since;
        };
        for (self.parked) |p| if (p.browser != 0) {
            at = if (at) |a| @min(a, p.since) else p.since;
        };
        return at;
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
        if (self.parkedIndex(sid)) |k| self.parked[k] = .{};
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
        // 세워 둔 세션도 — `setAutoAttach{autoAttach:false}` 가 붙은 세션을 모두 뗀다(닫힘이면 세션이 이미 죽었다).
        for (&self.parked) |*p| if (p.browser == browser) {
            p.* = .{};
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

    /// 맨 위 출처의 세션 수(떼기를 기다리는 남의 출처 세션은 빼고 — 탭 몫).
    pub fn ownCount(self: *const Sw, browser: BrowserId) usize {
        var n: usize = 0;
        for (self.sessions) |s| if (s.browser == browser and s.browser != 0 and s.foreign_since == 0) {
            n += 1;
        };
        return n;
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

/// 타깃·epoch 의 열쇠(타깃이 다시 뜨면 requestId 가 다시 쓰일 수 있다 — 공격 2 A13).
pub fn targetKey(target: u64, epoch: u32) u64 {
    return target +% @as(u64, epoch) *% 0x9E37_79B9_7F4A_7C15;
}

/// 워커 요청 하나의 열쇠 — (타깃·epoch, requestId). 같은 서비스 워커의 사건이 탭마다 세션으로 따로 와도 하나다(실측 r1 — 같은 requestId).
pub const WKey = struct {
    target: u64,
    rid: u64,

    pub fn of(target: u64, epoch: u32, rid: []const u8) WKey {
        return .{ .target = targetKey(target, epoch), .rid = hashId(rid) };
    }
};

/// 워커 요청을 맞추기·「설명」 에서 빼는가(공격 1 H2·공격 3 M1): 브라우저가 낸 navigation preload(`preload-N`), 워커가 받은 응답이 다시 서비스
/// 워커의 것(race 라우트), preflight(OPTIONS·`Preflight`), http(s) 밖의 주소(`data:`·`blob:`), 워커 스크립트(sw.js·importScripts). 이것들은 대개
/// 서비스 워커 갈래 CEF 기록이 없다(PHASE0 d) — 맞추기에 넣으면 남의 기록을 가져가거나 「설명」 한다. 재검증 6 차 D4: 새 워커의 importScripts·
/// module import 와 명시 OPTIONS 는 기록이 생긴다(1–10 회차 4 회차 실측) — 맞추기에는 넣지 않고 그 기록을 설명만 한다(`explainable`). τ 색인에는 남긴다(빼면 같은
/// τ 의 다른 W 가 「꼭 하나」 로 보인다).
pub fn excluded(rid: []const u8, method: []const u8, kind: []const u8, url: []const u8, from_sw: bool) bool {
    if (std.mem.startsWith(u8, rid, "preload-")) return true;
    if (from_sw) return true;
    if (std.mem.eql(u8, method, "OPTIONS") or std.mem.eql(u8, kind, "Preflight")) return true;
    if (std.mem.eql(u8, kind, "Script")) return true;
    if (!(std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://"))) return true;
    return false;
}

/// 재검증 6 차 D4: 빼는 꼴 가운데 CEF 서비스 워커 갈래 기록이 생기는 것 — 새 워커의 `importScripts`·module `import`(`type:Script` — 1–10 회차
/// 4 회차 실측, PHASE0 d 와 다르다)와 명시 `OPTIONS` fetch(사전 요청 `Preflight` 는 아니다). 짝은 맺지 않되 그 기록을 「설명」 해 탭을 어둠으로
/// 치지 않는다(`net_body_table.explainExcluded`). preload·워커가 받은 서비스 워커 응답·http(s) 밖은 아니다.
pub fn explainable(rid: []const u8, method: []const u8, kind: []const u8, url: []const u8, from_sw: bool) bool {
    if (std.mem.startsWith(u8, rid, "preload-") or from_sw) return false;
    if (!(std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://"))) return false;
    if (std.mem.eql(u8, kind, "Preflight")) return false;
    return std.mem.eql(u8, kind, "Script") or std.mem.eql(u8, method, "OPTIONS");
}

/// 재검증 8 차(R-1): 요청의 머리 가운데 응답의 바이트를 가르는 것 — 메서드의 해시(`hashMethod` — 0 = 모른다: 워커 요청의 시작 사건을 잃었거나
/// 탭 사이 사본이 서로 다르게 왔다)와 `Range` 머리 값의 해시(0 = 없다). µs τ 가 같은 두 응답은 HTTP 캐시가 한 네트워크 응답을 나눠 준 것이지만,
/// 같은 τ 를 GET(200)·HEAD(200, 빈 본문)·Range(206, 앞부분)가 함께 나눈다(실측 v20n-r2h 10/10 — 1–10 회차 2 회차). 그래서 「τ 가 같으면 본문이
/// 같다」 는 머리가 같을 때만 선다.
pub const Sig = struct { method: u64 = 0, range: u64 = 0 };

pub const W = struct {
    tau: i64 = 0,
    disk: bool = false,
    excluded: bool = false,
    status: u16 = 0,
    /// 재검증 8 차(R-1): 이 W 의 머리(시작 사건에서 — `Link.noteSent`). 모르면 0 — 그 W 로는 잇지 않는다.
    sig: Sig = .{},
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
    /// 재검증 8 차(R-1): 이 τ 의 첫 W 의 머리·상태와, 머리·상태가 다른 W 가 이 τ 를 함께 썼는가(디스크 적중 포함 — 독 τ). 같은 τ 의 HEAD·206 은
    /// GET 200 과 바이트가 다르다 — 그런 τ 는 어느 P 에도 잇지 않는다.
    sig: Sig = .{},
    status: u16 = 0,
    mixed: bool = false,
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
    /// 재검증 8 차(R-1) — P 의 머리(메서드·`Range`)가 고른 W 와 다르다(그 W 는 τ 를 나눈 다른 응답 — HEAD·Range) / 고른 W 가 부분 응답(206 —
    /// 바이트가 `Range` 에 달렸다) / 같은 τ 에 머리·상태가 다른 W 가 있다(독 τ).
    sig,
    partial,
    mixed,
    /// C5 — 짝이 아직·없다·탭에 없다.
    unpaired,
    not_in_tab,
    /// C6.
    status,
    record_failed,
    /// C0 — 다른 출처 문서의 요청.
    frame_origin,
    /// 진단(표의 W 판정) — 워커 W 의 짝을 의심했다: 다른 타깃·두 맞추기 갈림·물 높이 시한·실패한 요청이 쥔 기록·뒤 요청의 기록 기다림 시한·그 밖.
    w_cross_target,
    w_split,
    w_late,
    w_held,
    w_pending_split,
    w_doubt,
    /// 재검증 7 차(겹침 규칙): 판정 창에 같은 주소·메서드의 다른 W(짝을 맺은 것·지운 것·시작을 잃은 것 모두)가 겹친다 / 이 W 가 시작을 잃었다 /
    /// 판정 창이 워커 세션의 눈먼 때(붙기 전·enable 답 전)에 닿는다 — 그 창의 기록은 모두 본문 없이. 6 차의 `w_surplus`·`w_clock` 을 갈음한다.
    w_overlap,
    w_lost_start,
    w_blind,
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
/// 재검증 6 차: 벽시계의 느린 흐름으로 치는 빠르기의 위 끝(ppm — BSD `adjtime` 의 slew 상한 500 ppm). 이보다 빨리 뒤로 간 것만 뛰기로 친다.
pub const slew_ppm: i64 = 500;
/// 재검증 7 차(N19b): 흐름의 몫을 셀 때 표본 사이를 이만큼까지만 친다(그보다 긴 사이는 이만큼의 흐름만 허락한다 — 5 ms).
pub const slew_window_us: i64 = 10_000_000;
/// 재검증 7 차: 이보다 작은 뒤로 감은 뛰기로 치지 않는다(벽·단조를 잇달아 읽는 사이의 흔들림 — `visible_margin_us` 와 같다).
pub const jump_tolerance_us: i64 = 1_000;

pub const Link = struct {
    ws: std.AutoHashMapUnmanaged(WKey, W) = .empty,
    /// 재검증 8 차(R-1): 응답을 기다리는 W 의 머리(시작 사건 때 — 응답 때 `ws` 로 옮긴다). `max_ws` 에 닿으면 비운다(그 W 들은 머리를 몰라
    /// 잇지 않는다 — 잃는 쪽).
    sigs: std.AutoHashMapUnmanaged(WKey, Sig) = .empty,
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
    /// 본 뒤로 뛰기의 가장 큰 폭(진단·시험 — 재검증 7 차부터 C3a 는 이것을 VS 에 더하지 않는다, `jump_high`).
    back_max: i64 = 0,
    /// 재검증 7 차(N19a): 뒤로 뛰기를 본 때의 「뛰기 전 벽시계」(그때까지 본 어떤 τ 보다 크거나 같다)의 최대. 뛰기 **뒤에** 올리는 VS 는 이 값보다
    /// 앞에 서지 않는다(`raiseVisible`) — 뛰기 전의 메모 τ 는 모두 이 값 이하다. 뛰기 앞에 선 VS 는 그대로다(그 앞의 메모 τ 는 그 VS 보다 작다 —
    /// 같은 벽시계로 쟀다). 벽시계가 이 값을 지나면 뜻이 없어진다. 전에는 뛴 폭(`back_max`)을 sidecar 가 끝날 때까지 모든 VS 에 더해, 5 분 뒤로
    /// 뛰면 그 뒤 기록마다 붙은 뒤 5 분 동안의 서비스 워커 본문을 잃었다(v20m P19). 처음 판은 이 값을 모든 VS 에 씌워, 무거운 부하에서 벽·단조를
    /// 잇달아 읽는 사이에 밀린 표본(뛰기로 보인다 — 폭은 ms)마다 앞에 선 VS 가 「지금」 으로 올라 그 앞의 응답을 모두 잃었다(판정 v20fa 의 SW
    /// 사례가 차례로 0 — 실측).
    jump_high: i64 = std.math.minInt(i64),
    /// 마지막 표본의 단조 시각(재검증 6 차 — 기준 `off_max` 를 느린 흐름만큼 따라 내린다).
    last_mono: i64 = 0,

    pub fn deinit(self: *Link, gpa: std.mem.Allocator) void {
        self.ws.deinit(gpa);
        self.sigs.deinit(gpa);
        self.taus.deinit(gpa);
        self.order.deinit(gpa);
        self.hop_order.deinit(gpa);
        self.explained.deinit(gpa);
    }

    /// 시계 표본(벽 − 단조) — 사건마다 부른다. 뒤로 뛴 폭의 최대를 남긴다(줄지 않는다).
    /// 재검증 6 차: 느린 흐름(NTP 의 slew — 벽시계가 단조보다 조금 느리게 간다, 실측 −27 ppm)은 뒤로 뛴 것이 아니다 — 흐르는 벽시계에서도 옛 응답의
    /// τ 는 지금의 벽시계보다 작다(C3a 가 막는 것은 「뒤로 뛰기 앞의 메모 τ 가 VS 보다 크다」 뿐). 전에는 그 흐름이 기준(`off_max`)과의 차로 끝없이
    /// 쌓여(시간당 약 0.1 초) sidecar 가 오래 돌수록 붙은 직후의 응답이 모두 C3a 로 버려졌다(판정 `v20l-ctrl`: 12 분 뒤 20/20 → 0/20). 그래서
    /// 기준을 `slew_ppm` 만큼 따라 내리고, 그보다 빠르게 내려간 폭(뛰기·표본 사이의 지연)만 남긴다.
    ///
    /// 재검증 7 차: 흐름의 몫은 표본 사이를 `slew_window_us` 까지만 친다(N19b — 한가한 한 시간이면 1.8 초 뒤로 뛰기를 흐름으로 삼켰다; 실제 흐름은
    /// 그 사이 97 ms 남짓이라 그것은 뛰기로 치고 잃는 것은 그만큼이다). 뛰기를 보면 그때의 뛰기 전 벽시계를 `jump_high` 로 남기고 기준을 새
    /// 벽시계로 다시 잡는다(그 뒤 표본마다 다시 뛰기로 보지 않는다).
    pub fn clockSample(self: *Link, wall_us: i64, mono_us: i64) void {
        const off = wall_us - mono_us;
        if (self.off_max == std.math.minInt(i64)) {
            self.off_max = off;
            self.last_mono = mono_us;
            return;
        }
        const dt = @min(@max(mono_us - self.last_mono, 0), slew_window_us);
        self.last_mono = @max(self.last_mono, mono_us);
        const allowed = @divTrunc(dt * slew_ppm, 1_000_000);
        const floor = self.off_max - allowed;
        if (floor - off > jump_tolerance_us) {
            // 뒤로 뛰었다 — 뛰기 전 벽시계(기준 + 지금 단조)까지의 τ 는 뛰기 앞의 것일 수 있다.
            self.back_max = @max(self.back_max, floor - off);
            self.jump_high = @max(self.jump_high, floor + mono_us);
            self.off_max = off;
            return;
        }
        self.off_max = @max(off, floor);
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
        // 재검증 7 차(N19a): 뛰기 뒤에 올리는 VS 는 뛰기 전 벽시계까지(`jump_high` — 뛰기가 없으면 최소).
        v.wall_us = @max(v.wall_us, @max(wall_us, self.jump_high));
    }

    pub fn visibleSince(self: *const Link, browser: BrowserId) i64 {
        for (self.vs) |v| if (v.browser == browser) return v.wall_us + visible_margin_us;
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
        self.sigs.clearRetainingCapacity();
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

    /// 재검증 8 차(R-1): 워커 요청의 시작 사건(리다이렉트 홉이 아닌 것) — 그 머리를 응답 때까지 둔다. 탭 사이 사본이 다른 머리로 오면 모르는 것으로.
    pub fn noteSent(self: *Link, gpa: std.mem.Allocator, key: WKey, sig: Sig) std.mem.Allocator.Error!void {
        if (self.ws.getPtr(key)) |w| {
            // 응답 뒤의 늦은 사본 — 다르면 그 W 의 머리를 모르는 것으로(잇지 않는다).
            if (w.sig.method != sig.method or w.sig.range != sig.range) w.sig = .{};
            return;
        }
        if (self.sigs.count() >= max_ws) self.sigs.clearRetainingCapacity();
        const g = try self.sigs.getOrPut(gpa, key);
        if (!g.found_existing) {
            g.value_ptr.* = sig;
        } else if (g.value_ptr.method != sig.method or g.value_ptr.range != sig.range) g.value_ptr.* = .{};
    }

    /// 워커 응답(`responseReceived`) — τ 색인에 넣는다. 같은 W 가 다른 탭 세션으로 다시 오면 같은 값이면 둔다(다르면 그 W 는 `bad`).
    pub fn noteResponse(self: *Link, gpa: std.mem.Allocator, key: WKey, tau: i64, disk: bool, excl: bool, status: u16) std.mem.Allocator.Error!void {
        if (self.ws.getPtr(key)) |w| {
            if (w.tau != tau or w.disk != disk) w.bad = true;
            _ = self.sigs.remove(key);
            return;
        }
        if (self.order.items.len >= max_ws) self.evict();
        const sig: Sig = if (self.sigs.fetchRemove(key)) |kv| kv.value else .{};
        try self.ws.put(gpa, key, .{ .tau = tau, .disk = disk, .excluded = excl, .status = status, .sig = sig });
        try self.order.append(gpa, key);
        if (tau == 0 or tau <= self.horizon) return; // τ 없음(data:·blob:) — C2 / 지평 이하는 넣지 않는다(그 τ 의 P 는 지평으로 막힌다)
        const g = try self.taus.getOrPut(gpa, tau);
        if (!g.found_existing) {
            g.value_ptr.* = .{ .first = key, .sig = sig, .status = status };
        } else if (g.value_ptr.sig.method != sig.method or g.value_ptr.sig.range != sig.range or g.value_ptr.status != status) {
            // 재검증 8 차(R-1): 같은 τ 를 머리·상태가 다른 W 가 함께 썼다(GET 200 · HEAD · 206 — 바이트가 다르다) — 독 τ(영영).
            g.value_ptr.mixed = true;
        }
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

    /// C3a(τ 가 VS 앞) — 잇지 않는다. 재검증 6 차 F16b: 그래도 τ 로 W 와 그 짝을 찾아 가리킨 기록을 `ambiguous` 로 끝낸다(C7′ — 「P 가 가리켰지만
    /// 잇지 못했다」; 전에는 q 없이 끝내 그 기록이 시한 뒤 `unmatched`, 곧 「어느 페이지도 받지 않았다」 로 보였다). W 는 보였는데 짝이 아직이면
    /// 짝이 설 때까지 기다린다(시한이 지나면 부른 쪽이 q 없이 놓는다 — 잃는 쪽). 어느 길도 잇지 않는다.
    fn beforeVisible(self: *const Link, tau: i64) Verdict {
        const none: Verdict = .{ .ambiguous = .{ .reason = .before_visible } };
        const e = self.taus.get(tau) orelse return none;
        const w = self.ws.get(e.nd_key orelse e.first) orelse return none;
        if (w.pair == 0) return if (w.excluded or w.bad or e.hop) none else .wait;
        return .{ .ambiguous = .{ .reason = .before_visible, .q = w.pair } };
    }

    /// C1·C2·C3a·C4·C5 — P(그 탭 `browser`)를 어느 W·기록에 잇는가. C0·C3b′·C6·C7′ 은 부른 쪽(표).
    ///
    /// 재검증 8 차(R-1): `p` 는 P 의 머리(메서드·`Range`). τ 가 꼭 하나인 W 도 그 머리가 P 와 같을 때만 잇는다 — 같은 τ 를 GET 200·HEAD·206 이
    /// 함께 나누고(실측 10/10), 워커 W 의 응답을 눈먼 때 밖에서도 잃는다(실측 7 실행 중 1) — 둘이 겹치면 응답을 잃은 GET W 의 P 가 τ 를 나눈 HEAD W
    /// 의 기록을 가리켜 그 기록에 GET 본문이 붙을 수 있었다. 머리를 모르는 W(시작을 잃었다 — 0)·부분 응답(206)·머리가 섞인 τ 는 잇지 않는다.
    /// 머리가 다르면 그 W 의 기록은 이 P 의 것이 아니다 — 끝내지 않는다(그 W 의 제 P 가 잇는다).
    pub fn decide(self: *const Link, browser: BrowserId, tau: i64, src: Src, p: Sig) Verdict {
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
        if (tau < self.visibleSince(browser)) return self.beforeVisible(tau); // C3a
        if (tau <= self.horizon) return .{ .ambiguous = .{ .reason = .horizon } };
        const e = self.taus.get(tau) orelse return .wait; // W 가 아직(시한 뒤 `no_worker`)
        if (e.hop) return .{ .ambiguous = .{ .reason = .hop } };
        if (e.mixed) return .{ .ambiguous = .{ .reason = .mixed } }; // 재검증 8 차(R-1): 머리·상태가 다른 W 가 나눈 τ — 독 τ(영영)
        if (e.nondisk == 0) return .wait; // 디스크 적중뿐 — 네트워크 W 가 아직
        if (e.nondisk > 1) return .{ .ambiguous = .{ .reason = .many } }; // 독 τ(영영 — 지우지 않는다)
        const key = e.nd_key orelse return .wait;
        const w = self.ws.get(key) orelse return .{ .ambiguous = .{ .reason = .horizon } };
        if (w.excluded) return .{ .ambiguous = .{ .reason = .excluded } };
        if (w.bad) return .{ .ambiguous = .{ .reason = .bad_worker, .q = w.pair } };
        // 재검증 8 차(R-1): 머리가 P 와 같은 W 만(메서드·`Range` — 모르면 잇지 않는다), 부분 응답(206)은 잇지 않는다.
        if (w.sig.method != p.method or w.sig.range != p.range) return .{ .ambiguous = .{ .reason = .sig } };
        if (w.status == 206) return .{ .ambiguous = .{ .reason = .partial } };
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

test "S1: 자리 상한 — 넘치면 새 세션은 세워 두고(탭마다 16·전체 64 — 재검증 6 차 F14c, 재검증 7 차 N13: 곧 떼지 않고 시한 뒤), 세워 둘 자리도 없으면 뗀다, 다시 뜬 타깃은 epoch 를 올린다, 떨어진 세션은 지운다" {
    var sw: Sw = .{};
    var buf: [8]u8 = undefined;
    // 탭 넷이 16 씩 — 다섯째 탭은 전체가 차 세워 둔다. 한 탭이 16 을 넘겨 쥐지 못해 다른 탭이 제 몫을 쓴다.
    for (0..4) |b| {
        try testing.expect(sw.arm(5 + b));
        for (0..max_sessions_per_tab) |i| {
            const sid = try std.fmt.bufPrint(&buf, "{X:0>4}", .{b * 100 + i});
            try testing.expectEqual(Attach.keep, sw.attachedAt(5 + b, sid, "T", 1_000));
        }
        const extra = try std.fmt.bufPrint(&buf, "E{X:0>4}", .{b});
        try testing.expectEqual(Attach.park, sw.attachedAt(5 + b, extra, "T", 1_000));
        try testing.expectEqual(Attach.park, sw.attachedAt(5 + b, extra, "T", 1_000)); // 다시 알려져도 세운 그대로
    }
    try testing.expectEqual(max_sessions, sw.sessionCount(0));
    try testing.expect(sw.arm(9));
    try testing.expectEqual(Attach.park, sw.attachedAt(9, "DDDDD", "T", 1_000));
    try testing.expectEqual(@as(usize, 5), sw.parkedCount(0));
    try testing.expect(sw.live("DDDDD") == null); // 세운 세션의 사건은 삼킨다
    // 시한 뒤 뗀다(세운 것도 — 출처는 모른다).
    var due: usize = 0;
    while (sw.takeForeign(1_000 + foreign_grace_us)) |x| {
        try testing.expect(x.origin == 0);
        due += 1;
    }
    try testing.expectEqual(@as(usize, 5), due);
    // 세워 둘 자리도 차면 곧 뗀다(전의 길).
    for (0..max_parked) |i| {
        const sid = try std.fmt.bufPrint(&buf, "P{X:0>4}", .{i});
        try testing.expectEqual(Attach.park, sw.attachedAt(9, sid, "T", 2_000));
    }
    try testing.expectEqual(Attach.detach, sw.attachedAt(9, "QQQQ", "T", 2_000));
    _ = sw.detachAll(9); // 기록이 멈추면 세운 세션도 함께 떨어진다
    try testing.expectEqual(@as(usize, 0), sw.parkedCount(0));
    try testing.expectEqual(Attach.park, sw.attached(5, "FFFFF", "T"));
    sw.detached("0000");
    sw.detached("FFFFF"); // 세운 세션이 떨어지면 그 자리도 비운다
    try testing.expect(!sw.isParked("FFFFF"));
    try testing.expectEqual(Attach.keep, sw.attached(5, "FFFFF", "T"));
    sw.reloaded("FFFFF");
    try testing.expectEqual(@as(u32, 1), sw.find("FFFFF").?.epoch);
    try testing.expect(!sw.result("0000", 1, true, 5)); // 지운 세션의 답은 모른다
    // 재검증 6 차: 남의 출처가 된 세션(떼기를 기다린다)은 탭 몫에 세지 않는다 — 옮겨 간 출처의 워커가 붙는다(전체 자리가 있으면).
    var m: Sw = .{};
    try testing.expect(m.arm(5));
    for (0..max_sessions_per_tab) |i| {
        const sid = try std.fmt.bufPrint(&buf, "{X:0>4}", .{i});
        try testing.expectEqual(Attach.keep, m.attached(5, sid, "T"));
        _ = m.noteOrigin(sid, 0x11, 0x11, 10);
    }
    try testing.expectEqual(Attach.park, m.attached(5, "CCCCC", "T"));
    _ = m.retarget(5, 0x77, 1_000);
    try testing.expectEqual(Attach.keep, m.attached(5, "CCCCD", "T"));
    try testing.expectEqual(@as(usize, 1), m.ownCount(5));
    // 재검증 7 차(N13): 남의 것이 된 앞 출처 세션은 따로 묶은 몫(`max_foreign_per_tab`)까지만 남고 나머지는 곧 뗄 것으로 세워 둔다.
    try testing.expectEqual(max_foreign_per_tab, m.foreignCount(5));
    try testing.expectEqual(1 + max_sessions_per_tab - max_foreign_per_tab, m.parkedCount(5));
    var now_due: usize = 0;
    while (m.takeForeign(1_000)) |_| now_due += 1;
    try testing.expectEqual(max_sessions_per_tab - max_foreign_per_tab, now_due); // 몫을 넘은 앞 출처 세션은 곧(시한을 지난 것으로)
}

test "재검증 6 차 F13: 맨 위 출처가 아닌 워커 세션은 시한 뒤 뗀다 — 맨 위 출처가 그 워커의 것이 되면 남기고 그때 VS 를 올릴 값을 준다, 떠난 출처의 워커는 시한을 세운다" {
    var sw: Sw = .{};
    const o1: u64 = 0x11;
    const o2: u64 = 0x22;
    const x2: u64 = 0x33;
    try testing.expect(sw.arm(5));
    // 맨 위 출처(o1)의 워커 — 남긴다.
    try testing.expectEqual(Attach.keep, sw.attached(5, "A1", "T1"));
    try testing.expect(sw.noteOrigin("A1", o1, o1, 1_000) == .own);
    // iframe 출처(같은 사이트·다른 출처 o2, 다른 사이트 x2)의 워커 — 붙지만 남의 것.
    try testing.expectEqual(Attach.keep, sw.attached(5, "B2", "T2"));
    try testing.expect(sw.noteOrigin("B2", o2, o1, 2_000) != .own);
    try testing.expectEqual(Attach.keep, sw.attached(5, "C3", "T3"));
    try testing.expect(sw.noteOrigin("C3", x2, o1, 2_500) != .own);
    // 출처를 모르는 워커도 남의 것.
    try testing.expectEqual(Attach.keep, sw.attached(5, "D4", "T4"));
    try testing.expect(sw.noteOrigin("D4", 0, o1, 2_600) != .own);
    try testing.expect(sw.isForeign("B2") and !sw.isForeign("A1"));
    try testing.expectEqual(@as(?i64, 2_000), sw.nextForeign());
    // 시한 전에는 떼지 않는다.
    try testing.expect(sw.takeForeign(2_000 + foreign_grace_us - 1) == null);
    // 시한 뒤 — 남의 것만, 하나씩.
    var gone: usize = 0;
    while (sw.takeForeign(2_600 + foreign_grace_us)) |x| {
        try testing.expect(!std.mem.eql(u8, x.sidSlice(), "A1"));
        gone += 1;
    }
    try testing.expectEqual(@as(usize, 3), gone);
    try testing.expectEqual(@as(usize, 1), sw.sessionCount(5));
    try testing.expect(sw.nextForeign() == null);
    // 이동 중: 새 출처(o2)의 워커가 주소가 바뀌기 전에 붙는다 — 남의 것으로 시작해 enable 답이 온다.
    try testing.expectEqual(Attach.keep, sw.attached(5, "E5", "T5"));
    try testing.expect(sw.noteOrigin("E5", o2, o1, 10_000) != .own);
    sw.noteEnable("E5", 9);
    _ = sw.result("E5", 9, true, 7_777);
    // 주소가 바뀐다(o1 → o2): E5 는 풀려 그 enable 답으로 VS 를 올리고, 앞 문서 출처의 A1 은 시한을 세운다.
    try testing.expectEqual(@as(i64, 7_777), sw.retarget(5, o2, 10_500));
    try testing.expect(!sw.isForeign("E5") and sw.isForeign("A1"));
    try testing.expectEqual(@as(?i64, 10_500), sw.nextForeign());
    // 시한 안에 o1 로 돌아오면 A1 도 다시 남긴다(올릴 enable 답이 없으면 0).
    try testing.expectEqual(@as(i64, 0), sw.retarget(5, o1, 11_000));
    try testing.expect(!sw.isForeign("A1") and sw.isForeign("E5"));
    // 다른 탭의 세션은 건드리지 않는다.
    try testing.expect(sw.arm(6));
    try testing.expectEqual(Attach.keep, sw.attached(6, "F6", "T1"));
    try testing.expect(sw.noteOrigin("F6", o2, o2, 12_000) == .own);
    _ = sw.retarget(5, x2, 12_000);
    try testing.expect(!sw.isForeign("F6"));
}

test "재검증 6 차(F16 과 같은 꼴): 묻기만 하는 길은 탭 자리를 잡지 않는다 — 기록을 끈 뒤 닫힌 탭(닫힘의 떼기가 오지 않는다)의 자리가 남지 않는다" {
    var sw: Sw = .{};
    var b: BrowserId = 1;
    while (b <= 200) : (b += 1) {
        // 끈 탭·기록한 적 없는 탭에 온 묻기·떼기.
        _ = sw.detachAll(b);
        _ = sw.armed(b);
        _ = sw.takeRearm(b);
        sw.setRearm(b);
        try testing.expectEqual(Attach.detach, sw.attached(b, "AA", "T"));
    }
    try testing.expectEqual(@as(usize, 0), sw.tabCount());
    // 기록한 탭은 끈 뒤에도 자리가 남는다(세대) — 닫힘(`forget`)이 비운다.
    try testing.expect(sw.arm(7));
    _ = sw.detachAll(7);
    try testing.expectEqual(@as(usize, 1), sw.tabCount());
    sw.forget(7);
    try testing.expectEqual(@as(usize, 0), sw.tabCount());
}

const gpa_t = std.testing.allocator;

test "S2 C1·C2: 출처 network 만 잇는다 — http-cache·cache-storage 는 가리킨 기록을 ambiguous, 만든 응답·출처 없음·τ 없음은 잇지 않는다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    l.raiseVisible(5, 1_000_000);
    const k = WKey.of(1, 0, "1.1");
    try l.noteResponse(gpa_t, k, 2_000_000, false, false, 200);
    try l.notePair(gpa_t, k, 77);
    try testing.expectEqual(Verdict{ .link = .{ .q = 77, .w = k, .status = 200 } }, l.decide(5, 2_000_000, .network, .{}));
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .http_cache, .q = 77 } }, l.decide(5, 2_000_000, .http_cache, .{}));
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .cache_storage, .q = 77 } }, l.decide(5, 2_000_000, .cache_storage, .{}));
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .cache_storage } }, l.decide(5, 9_000_000, .cache_storage, .{})); // 만든 응답을 put — τ 가 없다
    try testing.expectEqual(Verdict.skip, l.decide(5, 2_000_000, .fallback, .{}));
    try testing.expectEqual(Verdict.skip, l.decide(5, 2_000_000, .none, .{}));
    try testing.expectEqual(Verdict.skip, l.decide(5, 0, .network, .{}));
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
    try testing.expectEqual(Reason.before_visible, l.decide(5, 5_000_000, .network, .{}).ambiguous.reason);
    l.raiseVisible(5, 4_000_000);
    try testing.expect(l.decide(5, 5_000_000, .network, .{}) == .link);
    // 늦게 붙은 타깃(새 범위·갱신) — 그 enable 답 앞의 τ 는 닫힌다.
    l.raiseVisible(5, 6_000_000);
    try testing.expectEqual(Reason.before_visible, l.decide(5, 5_000_000, .network, .{}).ambiguous.reason);
    l.raiseVisible(5, 1_000); // 내려가지 않는다
    try testing.expectEqual(Reason.before_visible, l.decide(5, 5_000_000, .network, .{}).ambiguous.reason);
    // 경계: VS + 여유.
    const k2 = WKey.of(1, 0, "1.2");
    try l.noteResponse(gpa_t, k2, 6_000_000 + visible_margin_us, false, false, 200);
    try l.notePair(gpa_t, k2, 10);
    try testing.expect(l.decide(5, 6_000_000 + visible_margin_us, .network, .{}) == .link);
    try testing.expectEqual(Reason.before_visible, l.decide(5, 6_000_000 + visible_margin_us - 1, .network, .{}).ambiguous.reason);
    // 벽시계가 뒤로 2 초 뛰었다 — 뛰기 앞에 선 VS 는 그대로(그 앞의 메모 τ 는 그 VS 보다 작다), 뛰기 뒤에 올리는 VS 는 뛰기 전 벽시계까지
    // (재검증 7 차 N19a — 뛰기 전의 메모 τ 가 뛴 뒤의 VS 보다 클 수 있다).
    l.clockSample(10_000_000, 1_000);
    l.clockSample(8_000_000, 2_000);
    try testing.expectEqual(@as(i64, 2_001_000), l.back_max);
    try testing.expect(l.decide(5, 6_000_000 + visible_margin_us, .network, .{}) == .link);
    l.raiseVisible(5, 8_000_500); // 뛴 뒤 새 타깃의 enable 답
    try testing.expectEqual(@as(i64, 9_999_000 + 2_000 + visible_margin_us), l.visibleSince(5));
    try testing.expectEqual(Reason.before_visible, l.decide(5, 9_000_000, .network, .{}).ambiguous.reason);
    l.forgetTab(5);
    try testing.expectEqual(Reason.before_visible, l.decide(5, 9_000_000_000, .network, .{}).ambiguous.reason);
}

test "재검증 6 차 F16b: C3a(VS 앞 τ)도 τ 로 W 의 짝을 찾아 그 기록을 ambiguous 로 — 짝이 아직이면 기다리고, 어느 길도 잇지 않는다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    l.raiseVisible(5, 9_000_000);
    const k = WKey.of(1, 0, "1.1");
    try l.noteResponse(gpa_t, k, 5_000_000, false, false, 200);
    // W 는 보였는데 짝이 아직 — 기다린다(잇지 않는다).
    try testing.expectEqual(Verdict.wait, l.decide(5, 5_000_000, .network, .{}));
    try l.notePair(gpa_t, k, 44);
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .before_visible, .q = 44 } }, l.decide(5, 5_000_000, .network, .{}));
    // W 가 없는 τ — q 없이.
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .before_visible } }, l.decide(5, 5_000_001, .network, .{}));
    // 빼는 꼴·나쁜 W 는 짝이 없어도 기다리지 않는다.
    const e = WKey.of(1, 0, "preload-1");
    try l.noteResponse(gpa_t, e, 6_000_000, false, true, 200);
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .before_visible } }, l.decide(5, 6_000_000, .network, .{}));
    const bw = WKey.of(1, 0, "2.2");
    try l.noteResponse(gpa_t, bw, 6_500_000, false, false, 200);
    l.noteBad(bw);
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .before_visible } }, l.decide(5, 6_500_000, .network, .{}));
    // VS 가 없는 탭(기록하지 않는다)도 같다.
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .before_visible, .q = 44 } }, l.decide(6, 5_000_000, .network, .{}));
}

test "재검증 6 차: 벽시계의 느린 흐름(slew)은 뒤로 뛴 폭으로 쌓이지 않는다 — 한 시간 −27 ppm 이 흘러도 VS 는 그대로, 뛰기는 남는다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    const wall0: i64 = 1_700_000_000_000_000;
    var mono: i64 = 1_000_000;
    // 1 초마다 한 표본, 한 시간 — 벽시계가 단조보다 27 ppm 느리다(실측).
    for (0..3600) |k| {
        const elapsed = @as(i64, @intCast(k)) * 1_000_000;
        l.clockSample(wall0 + elapsed - @divTrunc(elapsed * 27, 1_000_000), mono + elapsed);
    }
    try testing.expect(l.back_max < 1_000); // 전에는 약 97 ms
    // 이제 벽시계가 뒤로 2 초 뛴다 — 남는다(줄지 않는다).
    mono += 3600 * 1_000_000;
    l.clockSample(wall0 + 3600 * 1_000_000 - 97_200 - 2_000_000, mono + 1_000);
    try testing.expect(l.back_max >= 1_999_000);
    const after = l.back_max;
    for (1..100) |k| l.clockSample(wall0 + 3600 * 1_000_000 - 97_200 - 2_000_000 + @as(i64, @intCast(k)) * 1_000_000, mono + 1_000 + @as(i64, @intCast(k)) * 1_000_000);
    try testing.expectEqual(after, l.back_max);
    // 재검증 7 차(N19a): 뛰기 전 벽시계가 남는다 — 그보다 앞의 VS 는 그 값까지 올라간다. 벽시계가 그 값을 지난 뒤 붙은 세션의 VS 는 그대로다
    // (뛴 폭을 영영 더하지 않는다).
    const high = l.jump_high;
    try testing.expect(high >= wall0 + 3600 * 1_000_000 - 97_200 - 1_000);
    l.raiseVisible(5, high - 1_500_000);
    try testing.expectEqual(high + visible_margin_us, l.visibleSince(5));
    l.raiseVisible(6, high + 10_000_000);
    try testing.expectEqual(high + 10_000_000 + visible_margin_us, l.visibleSince(6));
}

test "S2 C4: τ 가 꼭 하나 — 같은 τ 의 디스크 아닌 W 둘은 영영 독, 디스크 적중은 걸러 네트워크 W 를, 홉 τ·빼는 꼴·나쁜 W·지평은 ambiguous, W·짝이 아직이면 기다린다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    l.raiseVisible(5, 1);
    // 아직 W 가 없다.
    try testing.expectEqual(Verdict.wait, l.decide(5, 3_000, .network, .{}));
    // 디스크 적중이 먼저 온 τ — 네트워크 W 를 기다린다.
    const d = WKey.of(1, 0, "d");
    try l.noteResponse(gpa_t, d, 3_000, true, false, 200);
    try testing.expectEqual(Verdict.wait, l.decide(5, 3_000, .network, .{}));
    const n = WKey.of(1, 0, "n");
    try l.noteResponse(gpa_t, n, 3_000, false, false, 200);
    try testing.expectEqual(Verdict.wait, l.decide(5, 3_000, .network, .{})); // 짝이 아직
    try l.notePair(gpa_t, n, 31);
    try testing.expectEqual(Verdict{ .link = .{ .q = 31, .w = n, .status = 200 } }, l.decide(5, 3_000, .network, .{}));
    // 다른 타깃의 같은 τ(µs 충돌) — 독. 짝이 있어도.
    try l.noteResponse(gpa_t, WKey.of(2, 0, "z"), 3_000, false, false, 200);
    try testing.expectEqual(Reason.many, l.decide(5, 3_000, .network, .{}).ambiguous.reason);
    // 홉 τ.
    const r = WKey.of(1, 0, "r");
    try l.noteHop(gpa_t, r, 4_000);
    try l.noteResponse(gpa_t, r, 4_500, false, false, 200);
    try l.notePair(gpa_t, r, 40);
    try testing.expectEqual(Reason.hop, l.decide(5, 4_000, .network, .{}).ambiguous.reason);
    try testing.expect(l.decide(5, 4_500, .network, .{}) == .link);
    // 빼는 꼴(preload 등) — τ 색인에는 있다.
    const p = WKey.of(1, 0, "preload-3");
    try l.noteResponse(gpa_t, p, 5_000, false, true, 200);
    try testing.expectEqual(Reason.excluded, l.decide(5, 5_000, .network, .{}).ambiguous.reason);
    // 같은 W 가 다른 τ 로 다시(requestId 재사용) — 나쁜 W.
    const q = WKey.of(1, 0, "q");
    try l.noteResponse(gpa_t, q, 6_000, false, false, 200);
    try l.notePair(gpa_t, q, 60);
    try l.noteResponse(gpa_t, q, 6_100, false, false, 200);
    try testing.expectEqual(Reason.bad_worker, l.decide(5, 6_000, .network, .{}).ambiguous.reason);
    // 탭 둘이 다른 짝 — 나쁜 W, 그 기록도 ambiguous 로.
    const s = WKey.of(1, 0, "s");
    try l.noteResponse(gpa_t, s, 7_000, false, false, 200);
    try l.notePair(gpa_t, s, 70);
    try l.notePair(gpa_t, s, 71);
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .bad_worker, .q = 70 } }, l.decide(5, 7_000, .network, .{}));
    try testing.expect(l.isExplained(70) and l.isExplained(71));
    // 짝을 의심해 끝낸 W.
    const u = WKey.of(1, 0, "u");
    try l.noteResponse(gpa_t, u, 8_000, false, false, 200);
    l.noteBad(u);
    try testing.expectEqual(Reason.bad_worker, l.decide(5, 8_000, .network, .{}).ambiguous.reason);
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
    try testing.expect(l.decide(5, 10_000, .network, .{}) == .link);
    try l.noteResponse(gpa_t, WKey.of(1, 0, "x"), 999_999, false, false, 200);
    try testing.expectEqual(@as(i64, 10_000 + evict_batch - 1), l.horizon);
    try testing.expectEqual(Reason.horizon, l.decide(5, 10_000, .network, .{}).ambiguous.reason);
    try testing.expect(!l.isExplained(100));
    try testing.expect(l.decide(5, 10_000 + evict_batch, .network, .{}) == .link);
    // 지평 이하 τ 의 늦은 W 는 넣지 않는다 — 그 τ 의 P 는 여전히 지평으로.
    try l.noteResponse(gpa_t, WKey.of(1, 0, "late"), 10_005, false, false, 200);
    try testing.expectEqual(Reason.horizon, l.decide(5, 10_005, .network, .{}).ambiguous.reason);
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
                const v = l.decide(5, base - @as(i64, rnd.uintLessThan(u32, 200)), .fallback, .{});
                try testing.expect(v == .skip);
                continue;
            }
            const f = fs[rnd.uintLessThan(usize, n)];
            const src: Src = if (f.disk) .http_cache else if (pick == 1) .cache_storage else .network;
            const v = l.decide(5, f.tau, src, .{});
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

// ── 재검증 7 차 기준: 재검증 6 차 적대 검증 11–20 회차(v20m-B)의 탐침 — 고치기 전에 실패했고 고친 뒤의 성질을 단언한다 ──

test "재검증 7 차 기준 · 탐침 v20m P13a(F14c): 떼기를 기다리는 남의 출처 세션은 탭 몫에 세지 않는다 — iframe 출처 워커가 3 초 안에 잇달아 뜨는 탭 하나가 전체 64 를 쥐어 다른 탭의 제 워커가 붙지 못한다" {
    var sw: Sw = .{};
    var buf: [8]u8 = undefined;
    const o1: u64 = 0x11; // 탭 5 의 맨 위 출처
    const o2: u64 = 0x22; // 탭 5 의 iframe 출처
    try testing.expect(sw.arm(5));
    try testing.expect(sw.arm(6));
    try testing.expectEqual(Attach.keep, sw.attached(5, "A000", "TA"));
    try testing.expect(sw.noteOrigin("A000", o1, o1, 1_000) == .own);
    // iframe 출처의 워커 80 개가 3 초 안에 뜬다(등록마다 새 타깃) — 붙을 때는 몫을 본 뒤 남의 것이 된다.
    var kept: usize = 0;
    for (0..80) |i| {
        const sid = try std.fmt.bufPrint(&buf, "{X:0>4}", .{0x100 + i});
        if (sw.attached(5, sid, sid) == .keep) {
            _ = sw.noteOrigin(sid, o2, o1, 1_000 + @as(i64, @intCast(i)) * 30_000);
            kept += 1;
        }
    }
    const held = sw.sessionCount(5);
    // 다른 탭(6)의 맨 위 출처 워커.
    const other = sw.attached(6, "B000", "TB");
    std.debug.print("\n[탐침 v20m P13a] tab 5 kept {d} foreign + 1 own → holds {d}/{d} sessions · tab 6's own worker: {s}\n", .{ kept, held, max_sessions, @tagName(other) });
    // 바라는 것(문서 「한 탭에 붙는 워커는 16 개·sidecar 전체 64 개까지」·F14c 의 뜻): 한 탭이 전체를 쥐지 않고 다른 탭의 워커는 붙는다.
    try testing.expect(held <= max_sessions_per_tab and other == .keep);
}

test "재검증 7 차 기준 · 탐침 v20m P13b(F14c·F13): 3 초 안에 맨 위 출처를 넷 바꾸면(출처마다 워커 16) 한 탭이 64 를 쥔다 — 앞 출처 세션은 떼기를 기다리며 몫에 세지 않는다" {
    var sw: Sw = .{};
    var buf: [8]u8 = undefined;
    try testing.expect(sw.arm(5));
    try testing.expect(sw.arm(6));
    var now: i64 = 1_000;
    for (0..4) |o| {
        const origin: u64 = 0x10 + o;
        _ = sw.retarget(5, origin, now); // 이동 — 앞 출처의 세션은 남의 것(떼기 기다림)
        for (0..max_sessions_per_tab) |i| {
            const sid = try std.fmt.bufPrint(&buf, "{X:0>4}", .{o * 0x100 + i});
            if (sw.attached(5, sid, sid) == .keep) _ = sw.noteOrigin(sid, origin, origin, now);
        }
        now += 700_000; // 0.7 초마다 이동
    }
    const held = sw.sessionCount(5);
    const other = sw.attached(6, "B000", "TB");
    std.debug.print("\n[탐침 v20m P13b] after 4 origin changes in 2.1 s tab 5 holds {d}/{d} · tab 6's own worker: {s}\n", .{ held, max_sessions, @tagName(other) });
    try testing.expect(other == .keep);
}

test "재검증 7 차 N19a·N19b(탐침 v20m P19): 벽시계가 X 뒤로 뛰어도 잃는 것은 그 뒤 X 동안뿐이다(전에는 sidecar 가 끝날 때까지 기록마다) — 한가한 동안의 뛰기도 흐름으로 삼키지 않는다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    const wall0: i64 = 1_700_000_000_000_000;
    var mono: i64 = 1_000_000;
    l.clockSample(wall0, mono);
    // 사용자가 시계를 5 분 뒤로(또는 잠에서 깬 뒤 NTP 가 한 번에 고친다).
    mono += 1_000_000;
    const jump_wall = wall0 + 1_000_000 - 300_000_000;
    l.clockSample(jump_wall, mono);
    try testing.expect(l.back_max >= 299_000_000);
    // 뛴 직후 붙은 세션 — VS 는 뛰기 전 벽시계까지 오른다(뛰기 앞의 메모 τ 는 그보다 작다 — C3a 가 막는다).
    l.raiseVisible(7, jump_wall + 1_000);
    try testing.expect(l.visibleSince(7) >= wall0 + 1_000_000);
    const memo = WKey.of(3, 0, "9.0");
    try l.noteResponse(gpa_t, memo, wall0 + 900_000, false, false, 200);
    try l.notePair(gpa_t, memo, 76);
    try testing.expect(l.decide(7, wall0 + 900_000, .network, .{}) == .ambiguous);
    // 한 시간 뒤 새 기록 — 워커 세션의 enable 답(지금 벽시계) 뒤 60 초의 응답은 잇는다(전에는 before_visible — v20m P19).
    mono += 3600 * 1_000_000;
    const now_wall = jump_wall + 3600 * 1_000_000;
    l.clockSample(now_wall, mono);
    l.raiseVisible(8, now_wall);
    const k = WKey.of(3, 0, "9.1");
    try l.noteResponse(gpa_t, k, now_wall + 60_000_000, false, false, 200);
    try l.notePair(gpa_t, k, 77);
    const v = l.decide(8, now_wall + 60_000_000, .network, .{});
    std.debug.print("\n[N19a] back_max {d} ms · P 60 s after enable (1 h after the jump) → {s}\n", .{ @divTrunc(l.back_max, 1000), @tagName(v) });
    try testing.expect(v == .link);
    // N19b: 한가한 한 시간 사이의 1.5 초 뒤로 뛰기 — 흐름의 몫은 표본 사이 10 초까지만(5 ms) 쳐서 뛰기로 본다(전에는 1.8 초까지 삼켰다).
    var m: Link = .{};
    defer m.deinit(gpa_t);
    m.clockSample(wall0, 1_000_000);
    m.clockSample(wall0 + 3600 * 1_000_000 - 1_500_000, 1_000_000 + 3600 * 1_000_000);
    std.debug.print("[N19b] 1.5 s step back during a 1 h idle gap → back_max {d} µs\n", .{m.back_max});
    try testing.expect(m.back_max >= 1_490_000);
    try testing.expect(m.jump_high >= wall0 + 3600 * 1_000_000 - 10_000);
    // 부하로 벽·단조를 읽는 사이가 밀린 표본(5 ms 뒤로 보인다 — 실제 뛰기가 아니다): 앞에 선 VS 는 그대로라 그 앞의 응답도 잇는다(처음 판은 VS 를
    // 그 표본의 「지금」 으로 올려 앞 응답을 모두 잃었다 — 판정 v20fa).
    var q: Link = .{};
    defer q.deinit(gpa_t);
    q.clockSample(wall0, 1_000_000);
    q.raiseVisible(9, wall0 + 1_000);
    const kq = WKey.of(3, 0, "9.9");
    try q.noteResponse(gpa_t, kq, wall0 + 500_000, false, false, 200);
    try q.notePair(gpa_t, kq, 99);
    q.clockSample(wall0 + 600_000 - 5_000, 1_000_000 + 600_000);
    q.clockSample(wall0 + 700_000, 1_000_000 + 700_000);
    try testing.expect(q.back_max >= 4_000);
    try testing.expect(q.decide(9, wall0 + 500_000, .network, .{}) == .link);
}

test "v20n R6-a: 기록을 끈 동안(워커 세션이 없어 시계 표본이 없다) 벽시계가 60 s 뒤로 뛰고 다시 켜면 — 켤 때의 VS 는 낮게 서지만 첫 워커 메시지의 표본이 뛰기를 보고 enable 답의 VS 가 뛰기 전 벽시계 위로 선다(그 앞 메모 τ 는 C3a 로 막힌다)" {
    var l: Link = .{};
    defer l.deinit(testing.allocator);
    const b: BrowserId = 7;
    const m0: i64 = 1_000_000_000;
    const w0: i64 = 1_700_000_000_000_000;
    // 첫 기록 세션 — 표본이 있다. 메모 τ 는 그때의 벽시계.
    l.clockSample(w0, m0);
    l.raiseVisible(b, w0);
    // 첫 세션이 30 분 이어지는 동안 표본이 이어지고, 끄기 10 s 전에 메모를 받았다.
    var k: i64 = 1;
    while (k <= 180) : (k += 1) l.clockSample(w0 + k * 10_000_000, m0 + k * 10_000_000);
    const memo_tau = w0 + 1_790_000_000;
    l.forgetTab(b);
    l.clear(); // 기록하는 탭이 없다 — τ 색인만 비우고 시계 기준은 남는다
    // 끈 뒤(표본 없음) 벽시계가 60 s 뒤로 뛰었다. 10 s 뒤 다시 켬 — 켤 때의 VS 는 표본 없이 지금 벽시계로.
    const m1 = m0 + 1_810_000_000;
    const w1 = w0 + 1_810_000_000 - 60_000_000;
    l.raiseVisible(b, w1);
    try testing.expect(l.visibleSince(b) < memo_tau); // 이 사이에는 C3a 가 그 메모를 막지 못한다(다만 잇기는 첫 enable 답 뒤다)
    // 첫 워커 메시지(`workerScriptLoaded`)의 표본 → enable 답의 VS.
    l.clockSample(w1 + 100_000, m1 + 100_000);
    l.raiseVisible(b, w1 + 150_000);
    try testing.expect(l.visibleSince(b) > memo_tau);
    try testing.expect(l.decide(b, memo_tau, .network, .{}) == .ambiguous);
}

test "재검증 8 차 R-1: τ 를 나눈 W 는 머리(메서드·Range)가 P 와 같을 때만 잇는다 — 머리를 모르는 W·206·머리·상태가 섞인 τ 는 잇지 않는다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    l.raiseVisible(5, 1);
    const get: Sig = .{ .method = 0x6e7, .range = 0 };
    const head: Sig = .{ .method = 0x4ead, .range = 0 };
    const rng: Sig = .{ .method = 0x6e7, .range = 0x5241 };
    // HEAD W 하나만 보인다(같은 τ 의 GET W 는 응답을 잃었다) — GET P 는 잇지 않는다(기록은 끝내지 않는다 — 그 W 의 제 P 가 잇는다).
    const h1 = WKey.of(1, 0, "h1");
    try l.noteSent(gpa_t, h1, head);
    try l.noteResponse(gpa_t, h1, 3_000, false, false, 200);
    try l.notePair(gpa_t, h1, 31);
    try testing.expectEqual(Verdict{ .ambiguous = .{ .reason = .sig } }, l.decide(5, 3_000, .network, get));
    try testing.expectEqual(Verdict{ .link = .{ .q = 31, .w = h1, .status = 200 } }, l.decide(5, 3_000, .network, head));
    // Range W(206) — 머리가 같아도 잇지 않는다.
    const r1 = WKey.of(1, 0, "r1");
    try l.noteSent(gpa_t, r1, rng);
    try l.noteResponse(gpa_t, r1, 4_000, false, false, 206);
    try l.notePair(gpa_t, r1, 41);
    try testing.expectEqual(@as(?Reason, .sig), reasonOf(l.decide(5, 4_000, .network, get)));
    try testing.expectEqual(@as(?Reason, .partial), reasonOf(l.decide(5, 4_000, .network, rng)));
    // 시작 사건을 잃은 W(머리를 모른다) — 잇지 않는다.
    const uk = WKey.of(1, 0, "u1");
    try l.noteResponse(gpa_t, uk, 5_000, false, false, 200);
    try l.notePair(gpa_t, uk, 51);
    try testing.expectEqual(@as(?Reason, .sig), reasonOf(l.decide(5, 5_000, .network, get)));
    // 같은 τ 에 GET 200(네트워크)과 HEAD(디스크 적중)가 함께 — 독 τ(GET P 도).
    const g2 = WKey.of(1, 0, "g2");
    try l.noteSent(gpa_t, g2, get);
    try l.noteResponse(gpa_t, g2, 6_000, false, false, 200);
    try l.notePair(gpa_t, g2, 61);
    try testing.expect(l.decide(5, 6_000, .network, get) == .link);
    const h2 = WKey.of(1, 0, "h2");
    try l.noteSent(gpa_t, h2, head);
    try l.noteResponse(gpa_t, h2, 6_000, true, false, 200);
    try testing.expectEqual(@as(?Reason, .mixed), reasonOf(l.decide(5, 6_000, .network, get)));
    // 탭 사이 사본이 다른 머리로 왔다 — 모르는 것으로.
    const c1 = WKey.of(1, 0, "c1");
    try l.noteSent(gpa_t, c1, get);
    try l.noteSent(gpa_t, c1, head);
    try l.noteResponse(gpa_t, c1, 7_000, false, false, 200);
    try l.notePair(gpa_t, c1, 71);
    try testing.expectEqual(@as(?Reason, .sig), reasonOf(l.decide(5, 7_000, .network, get)));
    // 머리의 표는 응답 때 옮겨 비운다.
    try testing.expectEqual(@as(u32, 0), l.sigs.count());
}

/// 재검증 8 차: 판정의 까닭(잇거나 기다리면 null) — 시험이 union 칸을 곧바로 읽어 변이에서 panic 으로 멈추지 않게.
fn reasonOf(v: Verdict) ?Reason {
    return switch (v) {
        .ambiguous => |a| a.reason,
        else => null,
    };
}
