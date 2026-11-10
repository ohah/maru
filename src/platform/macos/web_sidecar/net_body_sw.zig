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
//!
//! 재검증 12 차(새로 뜨는 워커를 멈춰 붙이기 — `net_body.zig` 머리): 놓기(`Runtime.runIfWaitingForDebugger`) 답을 기다리는 세션(`Pend` — 그 답 뒤에야
//! 뗀다), 답 앞에 세션이 사라진 워커의 건지기(`Rescue` — 살아 있는 탭에서 `Target.attachToTarget`), 멈춘 타깃에 다시 붙는 세션의 epoch(`stopped`). 시험이
//! 증명하는 것: 답의 번호·세션이 맞을 때만 빼기·떨어짐·탭 닫힘·시한·뗄 표시, 건지기의 한 타깃 한 자리·곧 해 보기·다시 해 보는 사이·횟수·타깃마다 위 끝·
//! 실패 답, 두 탭이 같은 다음 epoch 를 쓰기.

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
/// 재검증 12 차(눈먼 때를 뿌리에서): 멈춰 붙은 세션(`attachedToTarget.waitingForDebugger` — `waitForDebuggerOnStart:true` 로 새로 뜬 워커)의 놓기
/// (`Runtime.runIfWaitingForDebugger`) 답을 기다리는 자리 수(sidecar 전체 — `Sw.pend`). 그 답 앞에 그 세션을 떼면 워커가 영영 멈출 수 있다(워커의
/// DevTools 쪽이 아직 서지 않았을 때 — 실측 `swwait-offrace`, Playwright `CRSession.detach` 가 놓기 답을 기다린 뒤 떼는 까닭).
pub const max_pend: usize = 256;
/// 놓기 답을 기다리는 위 끝(단조 µs) — 지나면 그 워커를 건지기로 넘긴다(`Rescue`). 답은 워커의 스크립트를 받아 그 스레드가 선 뒤에야 오므로
/// 느린 망에서 길 수 있다 — 넉넉히.
pub const pend_timeout_us: i64 = 30_000_000;
/// 재검증 12 차: 놓기 답 앞에 세션이 사라진(Chromium 이 스스로 뗐다 — 다른 출처로 옮김·탭 닫힘) 멈춘 워커를 다시 붙여 놓는 자리 수(`Sw.rescue`).
/// 놓기 답 앞에 세션이 사라지면 그 워커는 스레드가 선 뒤 아무도 놓지 않는 채 멈춘다(실측 `swwait-navrace`·`swwait-closerace` 4/5 — 다시 붙은
/// 세션의 놓기가 풀었다).
pub const max_rescue: usize = 64;
/// 건지기를 다시 해 보는 사이와 횟수(타깃이 없으면 붙이기가 실패로 답해 곧 지운다).
pub const rescue_retry_us: i64 = 300_000;
pub const rescue_tries: u8 = 60;
/// 한 타깃을 건지는 횟수의 위 끝(건진 세션도 놓기 답 앞에 또 사라지면 다시 건진다 — 답이 끝내 오지 않는 꼴에서 붙임·건지기가 끝없이 돌지
/// 않게; PHASE0 `MARU_WEB_TEST_SW_NOREPLY` 에서 1 초 시한으로 5 571 번 돌았다). 기억은 `rescue_memory` 개(가장 오래된 것부터 잊는다).
pub const rescue_per_target: u8 = 3;
pub const rescue_memory: usize = 64;

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
    /// 재검증 12 차(⑩′ — 사용자 결정 2026-11-06): 기록 중 이 세션의 워커 출처가 그 탭의 맨 위 출처였다(그 탭이 다녀간 사이트). 그 탭이 떠나도 떼지
    /// 않는다(`foreign_since` 는 서 — 사건은 밸브에 세지 않고 W 는 맞추기에 넣지 않는다) — 돌아오면 이미 붙어 켜진 세션이라 눈먼 때가 없다. 떼는 것은
    /// 기록이 끝날 때(모든 정리 길)와 몫을 넘을 때(가장 오래 떠나 있던 것부터 — `takeEvicted`)뿐이다.
    visited: bool = false,
    /// maru 가 뗐다(뗌 명령을 보냈다 — 그 떨어짐은 다시 붙이지 않는다).
    detaching: bool = false,
    /// 재검증 12 차: 그 탭이 그 출처로 돌아왔다(맨 위 출처의 것이 되었다 — `takeReturned` 가 한 번 내준다).
    returned: bool = false,
    /// 재검증 13 차: 그 워커가 멈춰 뗄 차례다(`stopTarget` 이 세우고 `takeStopping` 이 한 번 내준다)·그 멈춤을 이미 다뤘다(늦게 닿은 제 멈춤 알림이
    /// 다시 훑지 않게 — 그 사이 같은 `targetId` 로 다시 뜬 워커의 새 세션을 떼지 않는다).
    stopping: bool = false,
    stop_seen: bool = false,
    /// `targetId`(다시 붙일 때).
    target_id: [max_sid_bytes]u8 = undefined,
    target_len: u8 = 0,

    pub fn sidSlice(self: *const Session) []const u8 {
        return self.sid[0..self.sid_len];
    }

    pub fn targetSlice(self: *const Session) []const u8 {
        return self.target_id[0..self.target_len];
    }

    /// 다녀간 출처의 세션이 그 탭을 떠나 있다(맨 위 출처가 아니다).
    pub fn away(self: *const Session) bool {
        return self.visited and self.foreign_since != 0;
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

/// 재검증 12 차: 놓기 답을 기다리는 멈춰 붙은 세션 하나(`Sw.pend`).
pub const Pend = struct {
    browser: BrowserId = 0,
    sid: [max_sid_bytes]u8 = undefined,
    sid_len: u8 = 0,
    /// 놓기 명령의 번호(그 세션의 답으로 온다).
    id: i64 = 0,
    /// 놓은 단조 µs(0 = 빈 자리).
    since: i64 = 0,
    /// 답 뒤에 뗀다(기록하지 않는 탭·서비스 워커 아닌 타깃·몫 밖 — Puppeteer `silentDetach`).
    detach: bool = false,
    /// 그 타깃의 `targetId`(건지기 — 세션이 답 앞에 사라지면 이것으로 다시 붙는다).
    target: [max_sid_bytes]u8 = undefined,
    target_len: u8 = 0,

    pub fn sidSlice(self: *const Pend) []const u8 {
        return self.sid[0..self.sid_len];
    }

    pub fn targetSlice(self: *const Pend) []const u8 {
        return self.target[0..self.target_len];
    }
};

/// 재검증 12 차: 건질 멈춘 워커 하나 — 살아 있는 탭의 페이지 세션에서 `Target.attachToTarget` 로 붙어(그 붙음이 오면 놓고 답 뒤에 뗀다).
pub const Rescue = struct {
    target: [max_sid_bytes]u8 = undefined,
    target_len: u8 = 0,
    /// 먼저 해 볼 탭(0 = 아무 탭 — 그 탭이 닫혔다).
    hint: BrowserId = 0,
    /// 넣은 단조 µs(0 = 빈 자리)·다음에 해 볼 때·해 본 수·마지막 붙이기 명령의 번호(실패 답이면 지운다).
    since: i64 = 0,
    next_try: i64 = 0,
    tries: u8 = 0,
    cmd_id: i64 = 0,
    /// 재검증 12 차: 다녀간 출처의 붙여 두기(Chromium 이 떠날 때 뗀 세션 — 다시 붙인 세션은 다녀간 출처의 것으로·손으로 붙인 것으로 적는다).
    keep: bool = false,
    /// 재검증 13 차: 붙여 두기를 넣을 때 그 탭(`hint`)의 세대(`TabState.gen`). 그 사이 기록을 끄고 다시 켰으면(세대가 올랐다) 새 기록의 범위가 아니다 —
    /// 다시 붙이지 않고(`keepCurrent`), 붙음이 이미 오면 다녀간 출처로 적지 않는다(검증 v20r-A 4 회차의 관찰 — 떠날 때의 다시 붙이기가 나는 사이의 끔 → 켬).
    gen: u32 = 0,
    /// 놓아야 할 워커(멈춰 붙은 채 세션이 사라졌다 — `rescueAdd`)도 이 자리에 있나. 붙여 두기만이면(거짓) 그 탭에서만 다시 붙인다 — 그 탭이 닫히면
    /// 버린다(재검증 12 차 회귀 `v20l-r15-race`: 닫히는 탭의 떨어짐을 붙여 두기로 받아 다른 탭에 붙였다 놓고 떼어, 그 탭의 auto 세션이 Chromium 의
    /// auto 목록에서 빠졌다 — 기록을 꺼도 떨어지지 않아 SW 가 멈추지 않았다).
    release: bool = false,

    pub fn targetSlice(self: *const Rescue) []const u8 {
        return self.target[0..self.target_len];
    }
};

/// `park` — 몫을 넘었다(재검증 7 차 N13): 세워 두었다(부른 쪽은 `Network.enable` 을 보내지 않고 시한 뒤 뗀다 — `takeForeign`).
/// 재검증 12 차: `shadow` — 그 탭이 그 워커에 이미 켜진 세션(다녀간 출처의 붙여 둔 세션)을 쥔다 — 이 세션(돌아올 때 Chromium 이 다시 붙인 것)은
/// 켜지 않고 쥐어만 둔다(사건이 두 번 오지 않게; 떼면 Chromium 이 곧 다시 붙인다). 눈먼 때도 없다.
pub const Attach = enum { keep, park, detach, shadow };

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
    /// 재검증 12 차: 그림자(`Attach.shadow` — 시한 없이 기록이 끝날 때까지). (12 차의 `manual` 은 적기만 하고 읽는 곳이 없어 13 차에 걷었다 —
    /// 기록이 멈추는 길(`net_body.detachWorkers`)은 auto·손을 가리지 않고 쥔 세션을 모두 하나하나 뗀다.)
    shadow: bool = false,
    /// 재검증 13 차: 그 세션의 워커(`targetId` 해시와 글) — 워커가 멈추면(`Inspector.targetCrashed`) 그 워커를 쥔 세운·그림자 세션도 모두 떼고
    /// (`stopTarget` — D-v20r-1), 다시 뜸의 놓기가 답 앞에 떨어지면 건진다(빈 `targetId` 로는 건지지 못했다).
    target: u64 = 0,
    target_id: [max_sid_bytes]u8 = undefined,
    target_len: u8 = 0,
    /// 재검증 13 차: 워커가 멈춰 뗄 차례다(`takeStopping` 이 한 번 내준다)·그 멈춤을 이미 다뤘다(`Session.stop_seen` 과 같다).
    stopping: bool = false,
    stop_seen: bool = false,
};

pub const Sw = struct {
    sessions: [max_sessions]Session = @splat(.{}),
    tabs: [max_tabs]TabState = @splat(.{}),
    parked: [max_parked]Parked = @splat(.{}),
    pend: [max_pend]Pend = @splat(.{}),
    rescue: [max_rescue]Rescue = @splat(.{}),
    /// 건진 타깃(`targetId` 해시)과 그 횟수 — `rescue_per_target` 을 넘으면 더 건지지 않는다.
    rescued: [rescue_memory]struct { target: u64 = 0, n: u8 = 0 } = @splat(.{}),
    rescued_next: usize = 0,
    /// 재검증 12 차: 다녀간 출처의 세션을 붙여 두는가(거짓 = 11 차 길 — 판정자의 대조 `MARU_WEB_SW_KEEP=0`).
    keep_visited: bool = true,
    /// 재검증 12 차: 몫으로 뺀 다녀간 출처 세션(부른 쪽이 뗀다 — `takeEvicted`).
    evicted: [4]Session = @splat(.{}),
    /// 재검증 12 차: 타깃마다 다음 세션이 쓸 epoch(`stopped`·`reloaded` — 가장 오래된 것부터 잊는다).
    epochs: [256]struct { target: u64 = 0, epoch: u32 = 0 } = @splat(.{}),
    epochs_next: usize = 0,

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
        if (self.parkedIndex(sid)) |k| return if (self.parked[k].browser != browser) .detach else if (self.parked[k].shadow) .shadow else .park;
        const th = hashId(target_id);
        // 재검증 12 차: 그 탭이 그 워커에 이미 켠 세션을 쥐었다(다녀간 출처의 붙여 둔 세션) — 그림자로 쥔다.
        for (self.sessions) |o| if (o.browser == browser and o.target == th and o.enable_id != 0 and !o.detaching) {
            return if (self.parkShadow(browser, sid, target_id)) .shadow else .detach;
        };
        // 탭 몫은 맨 위 출처의 세션만 센다 — 떼기를 기다리는 남의 출처 세션(이동 전 출처의 워커 — `foreign_grace_us`)이 몫을 쥐면 옮겨 간
        // 출처의 워커가 붙지 못했다(v20l r14-many 실측: 워커 70 개 출처에서 옮긴 탭). 남의 출처 세션은 따로 묶는다(`noteOrigin`).
        // 재검증 7 차(N13): 몫을 넘으면 세워 둔다(곧 떼면 되풀이되었다).
        // 재검증 12 차: 다녀간 출처의 붙여 둔 세션도 몫(탭 16·전체 64)에 센다 — 차면 가장 오래 떠나 있던 것을 뗀다(부른 쪽 — `takeEvicted`; 그 출처로
        // 돌아오면 처음 만남 — 어둠). 재검증 13 차(LOW-Q1): 탭 몫의 빼기는 새 세션이 맨 위 출처의 것으로 정해진 뒤에(`noteOrigin` 의 `.own`) — 전에는
        // 출처를 알기 전에 빼, 남의 출처 iframe 의 워커(남의 출처 몫에 셀 것)가 붙어도 붙여 둔 세션 하나를 잃었다.
        if (self.ownCount(browser) >= max_sessions_per_tab) return if (self.park(browser, sid, target_id, now_us)) .park else .detach;
        const free = for (self.sessions) |o| {
            if (o.browser == 0) break true;
        } else false;
        // 전체 64 가 찼다 — 새 세션의 자리가 있어야 하므로(출처와 무관) 모든 탭 가운데 가장 오래 떠나 있던 다녀간 출처 세션을 뺀다(다른 탭의 것일 수
        // 있다 — 그 탭이 그 출처로 돌아오면 처음 만남; 글 `docs/control-plane-browser.md`).
        if (!free) self.evictAway(0);
        for (&self.sessions) |*s| if (s.browser == 0) {
            s.* = .{ .browser = browser, .target = th, .gen = t.gen, .epoch = self.epochOf(th) };
            @memcpy(s.sid[0..sid.len], sid);
            s.sid_len = @intCast(sid.len);
            const tl = @min(target_id.len, max_sid_bytes);
            @memcpy(s.target_id[0..tl], target_id[0..tl]);
            s.target_len = @intCast(tl);
            return .keep;
        };
        return if (self.park(browser, sid, target_id, now_us)) .park else .detach;
    }

    /// 재검증 12 차: 그 탭(0 = 모든 탭)의 가장 오래 떠나 있던 다녀간 출처 세션을 표에서 빼 `evicted` 에 둔다(부른 쪽이 뗀다 — `takeEvicted`).
    fn evictAway(self: *Sw, browser: BrowserId) void {
        var best: ?usize = null;
        for (self.sessions, 0..) |o, k| if (o.browser != 0 and (browser == 0 or o.browser == browser) and o.away()) {
            if (best == null or o.foreign_since < self.sessions[best.?].foreign_since) best = k;
        };
        const k = best orelse return;
        for (&self.evicted) |*e| if (e.browser == 0) {
            e.* = self.sessions[k];
            break;
        };
        self.sessions[k] = .{};
    }

    fn evictedFree(self: *const Sw) bool {
        for (self.evicted) |e| if (e.browser == 0) return true;
        return false;
    }

    /// 몫으로 뺀(뗄) 세션 하나(null 까지 되풀이 — 부른 쪽이 뗀다).
    pub fn takeEvicted(self: *Sw) ?Session {
        for (&self.evicted) |*e| if (e.browser != 0) {
            const out = e.*;
            e.* = .{};
            return out;
        };
        return null;
    }

    /// 그 탭의 다녀간 출처 세션 가운데 떠나 있는 것의 수.
    pub fn awayCount(self: *const Sw, browser: BrowserId) usize {
        var n: usize = 0;
        for (self.sessions) |o| if (o.browser == browser and o.browser != 0 and o.away()) {
            n += 1;
        };
        return n;
    }

    /// 재검증 12 차: 그림자 세션을 시한 없이 쥔다(자리가 없으면 거짓 — 부른 쪽이 뗀다).
    fn parkShadow(self: *Sw, browser: BrowserId, sid: []const u8, target_id: []const u8) bool {
        if (!self.park(browser, sid, target_id, std.math.maxInt(i64) / 4)) return false;
        self.parked[self.parkedIndex(sid).?].shadow = true;
        return true;
    }

    /// 재검증 12 차: 그 세션을 다녀간 출처의 것으로(손으로 다시 붙인 세션 — 떠나 있는 동안 붙었다).
    pub fn markVisited(self: *Sw, sid: []const u8) void {
        if (!self.keep_visited) return;
        if (self.find(sid)) |s| s.visited = true;
    }

    /// maru 가 그 세션을 뗀다(그 떨어짐은 다시 붙이지 않는다).
    pub fn markDetaching(self: *Sw, sid: []const u8) void {
        if (self.find(sid)) |s| s.detaching = true;
    }

    /// 재검증 12 차: 그 세션이 떨어졌다 — Chromium 이 뗀 다녀간 출처 세션(기록 중·maru 가 떼지 않았다)이면 그 복사를 돌려준다(부른 쪽이 다시 붙인다).
    pub fn keepAfterDetach(self: *Sw, sid: []const u8) ?Session {
        const s = self.find(sid) orelse return null;
        if (!s.visited or s.detaching or s.target_len == 0) return null;
        const t = self.tab(s.browser) orelse return null;
        if (!t.armed or s.gen != t.gen) return null;
        return s.*;
    }

    /// 그 탭이 돌아온(맨 위 출처의 것이 된) 다녀간 출처 세션 하나(한 번만 — 부른 쪽이 그 워커의 떠나 있던 눈먼 때를 보통으로 바꾼다).
    pub fn takeReturned(self: *Sw, browser: BrowserId) ?Session {
        for (&self.sessions) |*s| if (s.browser == browser and s.returned) {
            s.returned = false;
            return s.*;
        };
        return null;
    }

    /// 재검증 7 차(N13): 세션 하나를 세워 둔다(자리가 없으면 거짓 — 부른 쪽이 곧 뗀다).
    fn park(self: *Sw, browser: BrowserId, sid: []const u8, target_id: []const u8, since: i64) bool {
        if (sid.len == 0 or sid.len > max_sid_bytes) return false;
        for (&self.parked) |*p| if (p.browser == 0) {
            p.* = .{ .browser = browser, .since = since, .target = if (target_id.len == 0) 0 else hashId(target_id) };
            @memcpy(p.sid[0..sid.len], sid);
            p.sid_len = @intCast(sid.len);
            const tl = @min(target_id.len, max_sid_bytes);
            @memcpy(p.target_id[0..tl], target_id[0..tl]);
            p.target_len = @intCast(tl);
            return true;
        };
        return false;
    }

    /// 재검증 13 차: 세션(옛 세대도)·세운·그림자 세션의 워커 `targetId`(모르면 빈 글) — 다시 뜸의 놓기가 답 앞에 떨어지면 그것으로 건진다(전에는 빈
    /// 글을 넘겨 건지지 못했다 — 검증 v20r-A 2 회차의 관찰).
    pub fn targetOf(self: *Sw, sid: []const u8) []const u8 {
        if (self.find(sid)) |s| return s.targetSlice();
        const k = self.parkedIndex(sid) orelse return "";
        return self.parked[k].target_id[0..self.parked[k].target_len];
    }

    /// 재검증 13 차(D-v20r-1·LOW-L1): 세션 `sid` 의 워커가 멈췄다(`Inspector.targetCrashed`) — 그 워커를 쥔 maru 세션을 **모든 탭에서** 뗄 차례로
    /// 세운다(산 세션·옛 세대 세션·세운 세션·그림자 — `takeStopping` 이 하나씩 내준다; `sid` 자신이 표에 없으면 부른 쪽이 그것만 뗀다). Chromium 은
    /// 세션이 남은 멈춘 호스트를 다시 쓴다 — 다시 뜬 워커가 같은 `targetId` 로 **멈추지 않고** 떠(그 세션은 이미 붙어 있다) 새 auto 세션은 떠 있는 워커에
    /// 붙고(처음 만남의 눈먼 때 — 어둠), 그 사이 시작한 W 의 기록은 설명되지 않아 그 출처를 기록하는 탭들이 기록이 끝날 때까지 어두웠다(검증 v20r
    /// `v20r-ss-away`·`ss-two`·`shstop` 0/20). 모두 떼면 다시 뜸은 새 호스트·새 `targetId` 로 새로 멈춰 붙는다. 뗄 세션은 `detaching` 으로 적어 그
    /// 떨어짐을 붙여 두기가 다시 붙이지 않게 하고(`keepAfterDetach`), 그 워커의 건지기(붙여 두기·놓기 — 멈춘 워커에는 놓을 것이 없다)를 지운다.
    /// 다음 epoch 도 적는다(`stopped` 와 같다). 돌려주는 것은 그 워커의 해시(0 = 모른다).
    /// 시한 떼기를 이미 기다리는 세션(남의 출처 세션·몫 밖에 세운 세션 — 3 초 안에 떨어진다)은 훑지 않는다 — 그 출처의 본문은 잇지 않고, 훑으면 iframe
    /// 워커가 쏟아질 때 뗌 명령만 늘었다(`v20m-r13-flood` 12 차 1 426 → 2 050 남짓 — 시험 문턱 2 000). 멈춤을 받은 산 세션 자신은 12 차처럼 뗀다.
    pub fn stopTarget(self: *Sw, sid: []const u8) u64 {
        const me = self.find(sid);
        const mk = self.parkedIndex(sid);
        // 이미 다룬 멈춤이다(앞서 다른 세션의 멈춤이 이 세션까지 훑었다 — 늦게 닿은 제 알림).
        if (me) |s| if (s.stop_seen) return 0;
        if (mk) |k| if (self.parked[k].stop_seen) return 0;
        const th: u64 = if (me) |s| s.target else if (mk) |k| self.parked[k].target else 0;
        if (th == 0) {
            if (mk) |k| if (self.parked[k].shadow) {
                self.parked[k].stop_seen = true;
                self.parked[k].stopping = true;
            };
            return 0;
        }
        for (&self.sessions) |*s| if (s.browser != 0 and s.target == th and !s.stop_seen) {
            if (s.foreign_since != 0 and !s.visited and !std.mem.eql(u8, s.sidSlice(), sid)) continue; // 시한 떼기를 기다린다
            s.stop_seen = true;
            // 그 타깃에 다음에 붙는 세션은 다음 epoch 로 시작한다(12 차 `stopped`) — 멈춘 호스트가 남아 같은 `targetId` 로 다시 뜨면 새 세션의 requestId
            // 가 옛 W 의 열쇠와 겹칠 수 있다(공격 2 A13). 탭마다 같은 값이 서도록 「그 세션 epoch + 1」 의 최대로 둔다.
            self.noteEpoch(th, s.epoch +% 1);
            if (s.detaching) continue; // 이미 뗌을 보냈다
            s.detaching = true;
            s.stopping = true;
        };
        for (&self.parked) |*p| if (p.browser != 0 and p.target == th and !p.stop_seen and p.shadow) {
            p.stop_seen = true;
            p.stopping = true;
        };
        for (&self.rescue) |*x| if (x.since != 0 and hashId(x.target[0..x.target_len]) == th) {
            x.* = .{};
        };
        return th;
    }

    /// 재검증 13 차: 워커가 멈춰 뗄 세션 하나(null 까지 되풀이 — 부른 쪽이 그 놓기 기다림을 지우고 곧 뗀다). 세션은 떨어짐 알림까지 표에 남는다.
    pub fn takeStopping(self: *Sw) ?struct { browser: BrowserId, sid: [max_sid_bytes]u8, sid_len: u8 } {
        for (&self.sessions) |*s| if (s.browser != 0 and s.stopping) {
            s.stopping = false;
            return .{ .browser = s.browser, .sid = s.sid, .sid_len = s.sid_len };
        };
        for (&self.parked) |*p| if (p.browser != 0 and p.stopping) {
            p.stopping = false;
            return .{ .browser = p.browser, .sid = p.sid, .sid_len = p.sid_len };
        };
        return null;
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
        // 재검증 12 차: 다녀간 출처의 붙여 둔 세션은 남의 출처 몫에 세지 않는다(탭 몫에 센다 — `awayCount`).
        for (self.sessions) |s| if (s.browser == browser and s.browser != 0 and s.foreign_since != 0 and !s.visited) {
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
            if (self.keep_visited) s.visited = true;
            // 재검증 13 차(LOW-Q1): 맨 위 출처의 세션이 된 뒤에야 탭 몫(맨 위 + 떠나 있는 세션 16)을 넘는지 본다 — 넘으면 가장 오래 떠나 있던 것부터
            // 뺀다(부른 쪽이 뗀다 — `takeEvicted`). `s` 는 떠나 있지 않으므로 빠지지 않는다.
            const b = s.browser;
            while (self.ownCount(b) + self.awayCount(b) > max_sessions_per_tab and self.awayCount(b) > 0 and self.evictedFree()) self.evictAway(b);
            return .own;
        }
        if (s.foreign_since == 0 and self.foreignCount(s.browser) >= max_foreign_per_tab) {
            const parked = self.park(s.browser, sid, s.targetSlice(), @max(now_us, 1));
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
                if (s.visited) s.returned = true;
                if (self.keep_visited) s.visited = true;
            } else if (!own and s.foreign_since == 0 and s.visited) {
                // 재검증 12 차: 다녀간 출처의 세션 — 떼지 않고 떠나 있음으로 둔다(사건은 밸브에 세지 않고 W 는 맞추기에 넣지 않는다).
                s.foreign_since = @max(now_us, 1);
            } else if (!own and s.foreign_since == 0) {
                // 재검증 7 차(N13): 남의 출처 몫을 넘는 앞 출처 세션은 곧 뗀다(세워 두고 시한을 지난 것으로 — 다음 `takeForeign`). 전에는 출처를
                // 잇달아 바꾸면 앞 출처 세션이 모두 시한까지 남아 한 탭이 전체 64 를 쥐었다(v20m P13b).
                if (self.foreignCount(browser) >= max_foreign_per_tab) {
                    if (self.park(browser, s.sidSlice(), s.targetSlice(), @max(now_us, 1) - foreign_grace_us)) {
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
        for (&self.sessions) |*s| if (s.browser != 0 and s.foreign_since != 0 and !s.visited and now_us - s.foreign_since >= foreign_grace_us) {
            const out = s.*;
            s.* = .{};
            return out;
        };
        for (&self.parked) |*p| if (p.browser != 0 and !p.shadow and now_us - p.since >= foreign_grace_us) {
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
        for (self.sessions) |s| if (s.browser != 0 and s.foreign_since != 0 and !s.visited) {
            at = if (at) |a| @min(a, s.foreign_since) else s.foreign_since;
        };
        for (self.parked) |p| if (p.browser != 0 and !p.shadow) {
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
        if (self.find(sid)) |s| {
            s.epoch +%= 1;
            self.noteEpoch(s.target, s.epoch);
        }
    }

    /// 그 타깃의 다음 세션이 쓸 epoch(모르면 0).
    pub fn epochOf(self: *const Sw, target: u64) u32 {
        for (self.epochs) |e| if (e.target == target and target != 0) return e.epoch;
        return 0;
    }

    fn noteEpoch(self: *Sw, target: u64, epoch: u32) void {
        if (target == 0) return;
        for (&self.epochs) |*e| if (e.target == target) {
            e.epoch = @max(e.epoch, epoch);
            return;
        };
        self.epochs[self.epochs_next] = .{ .target = target, .epoch = epoch };
        self.epochs_next = (self.epochs_next + 1) % self.epochs.len;
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

    /// 재검증 12 차: 놓기를 보냈다 — 그 답을 기다린다(자리가 없으면 거짓 — 부른 쪽은 뗄 세션이면 곧 뗀다).
    pub fn pendAdd(self: *Sw, browser: BrowserId, sid: []const u8, target: []const u8, id: i64, now_us: i64, detach: bool) bool {
        if (browser == 0 or sid.len == 0 or sid.len > max_sid_bytes or target.len > max_sid_bytes or id == 0) return false;
        for (&self.pend) |*p| if (p.since == 0) {
            p.* = .{ .browser = browser, .id = id, .since = @max(now_us, 1), .detach = detach };
            @memcpy(p.sid[0..sid.len], sid);
            p.sid_len = @intCast(sid.len);
            @memcpy(p.target[0..target.len], target);
            p.target_len = @intCast(target.len);
            return true;
        };
        return false;
    }

    /// 그 탭(닫힘·DevTools 떨어짐)의 놓기 답을 기다리던 세션을 모두 빼 돌려준다(부른 쪽이 건지기로 넘긴다 — null 까지 되풀이).
    pub fn pendOfBrowser(self: *Sw, browser: BrowserId) ?Pend {
        for (self.pend, 0..) |p, k| if (p.since != 0 and p.browser == browser) return self.pendTake(k);
        return null;
    }

    /// 재검증 12 차: 그 타깃을 건지기로 넣는다(이미 있으면 그대로 — 자리가 없으면 거짓).
    pub fn rescueAdd(self: *Sw, target: []const u8, hint: BrowserId, now_us: i64) bool {
        return self.rescueAddAs(target, hint, now_us, false);
    }

    /// 재검증 12 차: `keep` — 다녀간 출처의 붙여 두기(같은 타깃 한 자리 — 이미 있으면 그 표시만 더한다).
    pub fn rescueAddAs(self: *Sw, target: []const u8, hint: BrowserId, now_us: i64, keep: bool) bool {
        if (target.len == 0 or target.len > max_sid_bytes) return false;
        const gen: u32 = if (self.tab(hint)) |t| t.gen else 0;
        for (&self.rescue) |*x| if (x.since != 0 and std.mem.eql(u8, x.target[0..x.target_len], target)) {
            if (keep) {
                x.keep = true;
                x.hint = hint;
                x.gen = gen;
            } else x.release = true;
            return true;
        };
        // 같은 타깃을 이미 여러 번 건졌다 — 더 하지 않는다. 재검증 12 차: 붙여 두기(`keep`)의 다시 붙음은 세지 않는다 — 손 세션은 Chromium 이 떼지 않아
        // 되풀이되지 않는다(그 타깃이 끝나면 붙이기가 실패로 답해 지운다); 세면 다른 탭·앞 판의 건지기가 그 타깃의 붙여 두기를 막았다(실측 `v20l-reentry`
        // 전체 판 0/20 — 같은 SW 를 앞 사례들이 세 번 넘게 건졌다).
        const th = hashId(target);
        const seen = for (&self.rescued) |*r| {
            if (r.target == th and r.n > 0) break r;
        } else null;
        if (seen) |r| {
            if (!keep and r.n >= rescue_per_target) return false;
        }
        for (&self.rescue) |*x| if (x.since == 0) {
            x.* = .{ .hint = hint, .since = @max(now_us, 1), .next_try = now_us, .keep = keep, .release = !keep, .gen = gen };
            @memcpy(x.target[0..target.len], target);
            x.target_len = @intCast(target.len);
            if (keep) {} else if (seen) |r| r.n += 1 else {
                self.rescued[self.rescued_next] = .{ .target = th, .n = 1 };
                self.rescued_next = (self.rescued_next + 1) % rescue_memory;
            }
            return true;
        };
        return false;
    }

    /// 그 타깃이 탭 `browser` 에 붙었다 — 건지기에서 빼고 참(부른 쪽이 놓고 답 뒤에 뗀다). 재검증 13 차(LOW-Q2): 붙여 두기(`keep`)는 그 탭(`hint`)의
    /// 붙음만 가져간다 — 전에는 어느 탭의 붙음이든 꺼내, 탭 A 의 다시 붙이기가 날던 사이 탭 C 의 auto 붙음이 먼저 오면 C 가 그 건지기를 가져가고 A 는
    /// 붙여 둔 세션을 잃었다(돌아오면 처음 만남 — 어둠). 놓을 워커(`release`)는 아무 탭의 붙음이 놓는다 — 다른 탭이 가져가면 놓기 몫만 빼고 붙여 두기
    /// 몫은 그 탭을 위해 남긴다.
    pub fn rescueTake(self: *Sw, target: []const u8, browser: BrowserId) ?Rescue {
        if (target.len == 0) return null;
        for (&self.rescue) |*x| if (x.since != 0 and std.mem.eql(u8, x.target[0..x.target_len], target)) {
            const own_tab = x.hint != 0 and x.hint == browser;
            if (x.keep and !own_tab) {
                if (!x.release) return null;
                var out = x.*;
                out.keep = false;
                x.release = false;
                return out;
            }
            const out = x.*;
            x.* = .{};
            return out;
        };
        return null;
    }

    /// 재검증 13 차: 붙여 두기의 다시 붙이기가 아직 그 탭의 지금 기록의 것인가(그 탭이 살아 기록 중이고 넣을 때의 세대 그대로). 아니면 다시 붙이지
    /// 않고, 붙음이 오면 다녀간 출처로 적지 않는다.
    pub fn keepCurrent(self: *Sw, x: Rescue) bool {
        if (!x.keep or x.hint == 0) return false;
        const t = self.tab(x.hint) orelse return false;
        return t.armed and t.gen == x.gen;
    }

    /// 붙이기 명령 `id` 가 실패로 답했다(그 타깃이 없다) — 그 건지기를 지운다(참).
    pub fn rescueFailed(self: *Sw, id: i64) bool {
        for (&self.rescue) |*x| if (x.since != 0 and x.cmd_id == id) {
            x.* = .{};
            return true;
        };
        return false;
    }

    /// 지금 해 볼 건지기 하나(해 본 수를 올리고 다음 때를 미룬다 — 횟수를 넘으면 지운다). null 까지 되풀이.
    pub fn rescueDue(self: *Sw, now_us: i64) ?*Rescue {
        for (&self.rescue) |*x| if (x.since != 0 and x.next_try <= now_us) {
            if (x.tries >= rescue_tries) {
                x.* = .{};
                continue;
            }
            x.tries += 1;
            x.next_try = now_us + rescue_retry_us;
            return x;
        };
        return null;
    }

    /// 가장 이른 다음 해 볼 때(없으면 null).
    pub fn nextRescue(self: *const Sw) ?i64 {
        var at: ?i64 = null;
        for (self.rescue) |x| if (x.since != 0) {
            at = if (at) |v| @min(v, x.next_try) else x.next_try;
        };
        return at;
    }

    pub fn rescueCount(self: *const Sw) usize {
        var n: usize = 0;
        for (self.rescue) |x| if (x.since != 0) {
            n += 1;
        };
        return n;
    }

    fn pendTake(self: *Sw, k: usize) Pend {
        const out = self.pend[k];
        self.pend[k] = .{};
        return out;
    }

    /// 그 세션의 답 `id` 가 기다리던 놓기의 것이면 빼 돌려준다.
    pub fn pendDone(self: *Sw, sid: []const u8, id: i64) ?Pend {
        for (self.pend, 0..) |p, k| if (p.since != 0 and p.id == id and std.mem.eql(u8, p.sid[0..p.sid_len], sid)) return self.pendTake(k);
        return null;
    }

    /// 그 세션이 떨어졌다 — 기다리던 놓기를 빼 돌려준다(뗄 것이 없다).
    pub fn pendGone(self: *Sw, sid: []const u8) ?Pend {
        for (self.pend, 0..) |p, k| if (p.since != 0 and std.mem.eql(u8, p.sid[0..p.sid_len], sid)) return self.pendTake(k);
        return null;
    }

    /// 시한(`timeout_us`)이 지난 놓기 하나를 빼 돌려준다(null 까지 되풀이).
    pub fn pendExpired(self: *Sw, now_us: i64, timeout_us: i64) ?Pend {
        for (self.pend, 0..) |p, k| if (p.since != 0 and now_us - p.since >= timeout_us) return self.pendTake(k);
        return null;
    }

    /// 그 세션의 놓기 답을 기다리면 답 뒤에 떼게 둔다(참) — 남의 출처 시한 떼기가 답 앞에 떼지 않게.
    pub fn pendMarkDetach(self: *Sw, sid: []const u8) bool {
        for (&self.pend) |*p| if (p.since != 0 and std.mem.eql(u8, p.sid[0..p.sid_len], sid)) {
            p.detach = true;
            return true;
        };
        return false;
    }

    /// 그 탭(0 = 모두)의 놓기 답을 기다리는 수.
    pub fn pendCount(self: *const Sw, browser: BrowserId) usize {
        var n: usize = 0;
        for (self.pend) |p| if (p.since != 0 and (browser == 0 or p.browser == browser)) {
            n += 1;
        };
        return n;
    }

    /// 가장 이른 놓은 때(없으면 null — 부른 쪽이 시한 확인을 건다).
    pub fn nextPend(self: *const Sw) ?i64 {
        var at: ?i64 = null;
        for (self.pend) |p| if (p.since != 0) {
            at = if (at) |a| @min(a, p.since) else p.since;
        };
        return at;
    }

    /// 탭이 닫혔다 — 자리를 비운다(놓기 답을 기다리던 세션은 부른 쪽이 먼저 건지기로 넘긴다 — `pendOfBrowser`).
    pub fn forget(self: *Sw, browser: BrowserId) void {
        for (&self.pend) |*p| if (p.since != 0 and p.browser == browser) {
            p.* = .{};
        };
        // 재검증 12 차: 그 탭의 붙여 두기만인 건지기는 버린다(놓을 워커가 아니다 — 다른 탭에 붙이면 그 탭의 auto 세션을 Chromium 목록에서 뺀다).
        for (&self.rescue) |*x| if (x.since != 0 and x.hint == browser and !x.release) {
            x.* = .{};
        };
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
/// 재검증 9 차(LOW-A): 머리의 표 칸 — 적은 차례 번호와 함께(오래된 것부터 잊는다).
pub const SigSlot = struct { sig: Sig, seq: u64 };
pub const SigOrder = struct { key: WKey, seq: u64 };

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
    /// 재검증 10 차(구조 규칙 — 잇는 때 다시 본다): 짝을 처음 맺은 판정의 단조 시각과 그 탭(`notePairAt`). 그 뒤에 안 것(다른 W 의 자리·눈먼 때)이
    /// 그 판정을 무르는지 P 를 잇는 때 본다(`Table.pairStale`) — 그 시각 뒤에 시작한 보이는 W 는 그 기록의 주인일 수 없다(기록은 판정 앞에 왔고,
    /// 보이는 W 의 IO 는 시작 사건 뒤다 — J1).
    paired_at: i64 = 0,
    pair_tab: BrowserId = 0,
    /// 재검증 11 차(LOW-K′): 남의 출처 세션의 사본으로만 보았다(`Link.foreign_order` 에 든다). 맨 위 출처 세션의 사본이 오면 거짓으로 바꾸고
    /// `order` 로 옮긴다 — 어느 탭이든 맨 위 출처로 보는 W 는 남의 W 가 아니다.
    foreign: bool = false,
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
    /// 재검증 11 차(LOW-R1): 이 τ 를 쓴 W 가운데 아직 `ws` 에 있는 수(남의 W 를 놓을 때 줄인다 — 0 이면 칸을 지운다). `nondisk`·`disk` 는 줄이지 않는다
    /// (독 τ 는 독으로 남는다).
    live: u16 = 0,
};

/// 재검증 10 차(MED-P1·P2): Zig 의 열린 주소 해시 표(`HashMapUnmanaged`)는 지운 칸에 묘비를 남기고 표가 자랄 때에만 치운다(지울 때 `available` 을
/// 되돌려 받아 자라지 않는다 — std `hash_map.zig` 의 `removeByIndex`). 지우기만 하고 자라지 않는 장수 표에서 빈 칸이 0 에 다가가면 없는 열쇠
/// 찾기가 표 전체를 훑었다(검증 v20p-B Q19-d·e·f — 머리 표 줄이기 한 번 68–72 ms ReleaseFast·583–596 ms Debug, W 응답 하나 211 ns → 222 µs).
/// 지운 수가 자리의 1/4 에 닿으면 제자리에서 다시 짓는다(`rehash` — O(자리), 지운 하나마다 갚으면 O(1)). 넣기는 묘비를 다시 쓰니 묘비 수는
/// 지운 수 이하다 — 다시 지은 뒤 묘비는 늘 자리의 1/4 아래다. 다시 짓는 동안 그 표의 칸 포인터는 무효다 — 부른 쪽은 쥐지 않는다.
pub const Tombs = struct {
    n: u32 = 0,
    /// 재검증 11 차(LOW-T — 시험): 지운 수의 누적과 다시 지은 수(지울 때마다 다시 짓는 퇴행을 셈으로 본다 — 검증 v20q 변이 Q11).
    total: u64 = 0,
    rebuilds: u32 = 0,

    pub fn removed(self: *Tombs, map: anytype, k: u32) void {
        if (k == 0) return;
        self.n +|= k;
        self.total +|= k;
        const cap = map.capacity();
        if (cap == 0 or @as(u64, self.n) * 4 < cap) return;
        const M = @TypeOf(map.*);
        map.rehash(std.hash_map.AutoContext(@FieldType(M.KV, "key")){});
        self.n = 0;
        self.rebuilds +|= 1;
    }
};

/// 재검증 10 차(LOW-K): 응답 표에 남의 출처 세션의 W 를 쥐는 수 — 맨 위 출처 W 의 `max_ws` 와 따로 센다. 남의 W 는 τ 독 검사에만 쓰인다(맞추기에
/// 들지 않는다 — 짝이 없다). 전에는 같은 차례 목록에 들어 밸브에 세지 않는 남의 응답 16 384 가 맨 위 출처 W 를 쫓아냈다(검증 v20p-B Q11-w).
pub const max_foreign_ws: usize = 4_096;
pub const foreign_evict_batch: usize = 512;

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
    /// 재검증 10 차(구조 규칙): P 를 잇는 때 다시 보니 짝을 맺은 판정 뒤에 안 것이 그 짝을 무른다 — 그 기록의 IO 를 제 자리에 품는 다른 W(판정
    /// 때 이미 시작했다)·그 기록을 가진 탭의 눈먼 때·잊은 자리(`Table.pairStale`).
    w_stale,
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
    /// 재검증 8 차(R-1): 응답을 기다리는 W 의 머리(시작 사건 때 — 응답 때 `ws` 로 옮긴다, 실패하면 지운다). 재검증 9 차(LOW-A): `max_ws` 에 닿으면
    /// 가장 오래된 것부터 `evict_batch` 만큼 잊는다(그 W 들은 머리를 몰라 잇지 않는다 — 잃는 쪽). 전에는 통째로 비워 그때 응답을 기다리던 W 를
    /// 모두 잃었고, 실패한 W 의 칸은 지우지 않아 쌓였다(검증 v20o-B P11-s·P19-s).
    sigs: std.AutoHashMapUnmanaged(WKey, SigSlot) = .empty,
    /// 재검증 9 차(LOW-A): 머리를 적은 차례(`sig_head` 앞은 잊었다). 칸의 `seq` 가 표의 것과 다르면 지운 뒤 다시 적은 것이라 건너뛴다. 길이는
    /// `2 * max_ws` 에 닿으면 산 칸만 남겨 줄인다(산 칸은 `max_ws` 이하).
    sig_order: std.ArrayList(SigOrder) = .empty,
    sig_head: usize = 0,
    sig_seq: u64 = 0,
    taus: std.AutoHashMapUnmanaged(i64, TauEntry) = .empty,
    /// 넣은 차례(쫓아내기 — 홉 τ 는 `hop_order`).
    order: std.ArrayList(WKey) = .empty,
    /// 재검증 10 차(LOW-K): 남의 출처 세션 W 의 넣은 차례(`max_foreign_ws` — 맨 위 출처 W 를 쫓아내지 않는다).
    foreign_order: std.ArrayList(WKey) = .empty,
    /// 재검증 10 차(MED-P1·P2): 표마다 지운 수(`Tombs`).
    ws_tombs: Tombs = .{},
    sigs_tombs: Tombs = .{},
    taus_tombs: Tombs = .{},
    explained_tombs: Tombs = .{},
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
        self.sig_order.deinit(gpa);
        self.taus.deinit(gpa);
        self.order.deinit(gpa);
        self.foreign_order.deinit(gpa);
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
        self.sig_order.clearRetainingCapacity();
        self.sig_head = 0;
        self.taus.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
        self.foreign_order.clearRetainingCapacity();
        self.hop_order.clearRetainingCapacity();
        self.explained.clearRetainingCapacity();
        self.horizon = 0;
        // `clearRetainingCapacity` 는 칸 표시를 모두 비운다(묘비도).
        self.ws_tombs = .{};
        self.sigs_tombs = .{};
        self.taus_tombs = .{};
        self.explained_tombs = .{};
    }

    fn evict(self: *Link) void {
        const n = @min(evict_batch, self.order.items.len);
        var gone: [3]u32 = .{ 0, 0, 0 };
        for (self.order.items[0..n]) |k| {
            const w = self.ws.get(k) orelse continue;
            if (w.tau != 0) {
                self.horizon = @max(self.horizon, w.tau);
                if (self.taus.remove(w.tau)) gone[1] += 1;
            }
            if (w.pair != 0 and self.explained.remove(w.pair)) gone[2] += 1;
            if (self.ws.remove(k)) gone[0] += 1;
        }
        self.order.replaceRangeAssumeCapacity(0, n, &.{});
        const hn = @min(evict_batch, self.hop_order.items.len);
        for (self.hop_order.items[0..hn]) |tau| self.horizon = @max(self.horizon, tau);
        self.hop_order.replaceRangeAssumeCapacity(0, hn, &.{});
        // 재검증 10 차(MED-P2): 지운 칸의 묘비 — 쫓아내기가 이어지는 오래 도는 기록에서 표를 다시 짓는다.
        self.ws_tombs.removed(&self.ws, gone[0]);
        self.taus_tombs.removed(&self.taus, gone[1]);
        self.explained_tombs.removed(&self.explained, gone[2]);
    }

    /// 재검증 10 차(LOW-K): 남의 출처 세션 W 를 오래된 것부터 `foreign_evict_batch` 만큼 놓는다. 지평은 올리지 않는다 — 그 τ 를 맨 위 출처 W 도
    /// 함께 썼으면 그 τ 칸(독 — 둘 이상)을 남기고, 남의 W 만 쓴 τ 칸은 지운다. 남의 W 는 맨 위 출처 문서의 요청 P 에 답하지 않는다(C0 — 다른 출처의
    /// 워커는 이 문서를 다스리지 않는다)라 그 τ 의 P 가 다른 W 로 이어지는 일은 없다; 남은 칸이 지운 W 를 가리키면 `horizon` 까닭으로 잇지 않는다.
    fn evictForeign(self: *Link) void {
        const n = @min(foreign_evict_batch, self.foreign_order.items.len);
        var gone: [3]u32 = .{ 0, 0, 0 };
        for (self.foreign_order.items[0..n]) |k| {
            const w = self.ws.get(k) orelse continue;
            // 재검증 11 차(LOW-K′): 맨 위 출처 세션의 사본이 와 `order` 로 옮긴 W — 여기서는 차례 칸만 버린다.
            if (!w.foreign) continue;
            // 재검증 11 차(LOW-R1): τ 칸은 그 τ 를 쓴 W 가 `ws` 에 하나도 남지 않으면 지운다(전에는 「그 W 하나뿐」 일 때만 — 디스크 적중과 τ 를 나눈 남의
            // 응답의 칸이 지평 없이 영영 남았다, 검증 v20q-B Q11-c). 남은 W 가 있으면 칸(독·셈)은 그대로다 — 칸의 W 가 지운 W 면 `horizon` 까닭으로
            // 잇지 않는다. 짝을 맺은 남의 W 의 `explained` 도 지운다(`evict` 와 같다).
            if (w.tau != 0) if (self.taus.getPtr(w.tau)) |e| {
                e.live -|= 1;
                if (e.live == 0 and !e.hop and self.taus.remove(w.tau)) gone[1] += 1;
            };
            if (w.pair != 0 and self.explained.remove(w.pair)) gone[2] += 1;
            if (self.ws.remove(k)) gone[0] += 1;
        }
        self.foreign_order.replaceRangeAssumeCapacity(0, n, &.{});
        self.ws_tombs.removed(&self.ws, gone[0]);
        self.taus_tombs.removed(&self.taus, gone[1]);
        self.explained_tombs.removed(&self.explained, gone[2]);
    }

    /// 재검증 8 차(R-1): 워커 요청의 시작 사건(리다이렉트 홉이 아닌 것) — 그 머리를 응답 때까지 둔다. 탭 사이 사본이 다른 머리로 오면 모르는 것으로.
    /// 재검증 9 차(LOW-A): 부른 쪽은 맨 위 출처 세션의 W 만 적는다(남의 출처 세션의 W 는 맞추기에 들지 않아 쓸 데가 없고, 쏟아짐 밸브에 세지 않아
    /// 표를 빠르게 채운다 — P11-s).
    pub fn noteSent(self: *Link, gpa: std.mem.Allocator, key: WKey, sig: Sig) std.mem.Allocator.Error!void {
        if (self.ws.getPtr(key)) |w| {
            // 응답 뒤의 늦은 사본 — 다르면 그 W 의 머리를 모르는 것으로(잇지 않는다).
            if (w.sig.method != sig.method or w.sig.range != sig.range) w.sig = .{};
            return;
        }
        if (self.sigs.getPtr(key)) |e| {
            if (e.sig.method != sig.method or e.sig.range != sig.range) e.sig = .{};
            return;
        }
        if (self.sigs.count() >= max_ws) self.evictSigs();
        if (self.sig_order.items.len >= 2 * max_ws) self.compactSigs();
        try self.sigs.ensureUnusedCapacity(gpa, 1);
        try self.sig_order.ensureUnusedCapacity(gpa, 1);
        self.sig_seq +%= 1;
        self.sigs.putAssumeCapacityNoClobber(key, .{ .sig = sig, .seq = self.sig_seq });
        self.sig_order.appendAssumeCapacity(.{ .key = key, .seq = self.sig_seq });
    }

    /// 재검증 9 차(LOW-A): 워커 요청이 응답 없이 끝났다(`loadingFailed`) — 그 머리를 지운다(전에는 응답 때에만 지워 실패한 W 의 칸이 쌓였다 — P19-s).
    pub fn forgetSig(self: *Link, key: WKey) void {
        if (self.sigs.remove(key)) self.sigs_tombs.removed(&self.sigs, 1);
    }

    /// 재검증 9 차(LOW-A): 머리의 표가 찼다 — 가장 오래된 것부터 `evict_batch` 만큼 잊는다(그 W 들은 머리를 몰라 잇지 않는다 — 잃는 쪽).
    fn evictSigs(self: *Link) void {
        var gone: u32 = 0;
        while (self.sigs.count() > max_ws - evict_batch and self.sig_head < self.sig_order.items.len) : (self.sig_head += 1) {
            const o = self.sig_order.items[self.sig_head];
            const e = self.sigs.get(o.key) orelse continue;
            if (e.seq == o.seq and self.sigs.remove(o.key)) gone += 1;
        }
        self.sigs_tombs.removed(&self.sigs, gone);
    }

    /// 재검증 9 차(LOW-A): 차례 목록을 산 칸만으로 줄인다(자리를 이미 쥐고 있어 할당하지 않는다).
    fn compactSigs(self: *Link) void {
        var n: usize = 0;
        for (self.sig_order.items[self.sig_head..]) |o| {
            const e = self.sigs.get(o.key) orelse continue;
            if (e.seq != o.seq) continue;
            self.sig_order.items[n] = o;
            n += 1;
        }
        self.sig_order.shrinkRetainingCapacity(n);
        self.sig_head = 0;
    }

    /// 워커 응답(`responseReceived`) — τ 색인에 넣는다. 같은 W 가 다른 탭 세션으로 다시 오면 같은 값이면 둔다(다르면 그 W 는 `bad`).
    pub fn noteResponse(self: *Link, gpa: std.mem.Allocator, key: WKey, tau: i64, disk: bool, excl: bool, status: u16) std.mem.Allocator.Error!void {
        return self.noteResponseFrom(gpa, key, tau, disk, excl, status, false);
    }

    /// `foreign` — 재검증 10 차(LOW-K): 남의 출처 세션의 W(맞추기에 들지 않는다 — τ 독 검사에만). 따로 센다(`foreign_order`).
    pub fn noteResponseFrom(self: *Link, gpa: std.mem.Allocator, key: WKey, tau: i64, disk: bool, excl: bool, status: u16, foreign: bool) std.mem.Allocator.Error!void {
        if (self.ws.getPtr(key)) |w| {
            if (w.tau != tau or w.disk != disk) w.bad = true;
            // 재검증 11 차(LOW-K′): 남의 출처 세션의 사본이 먼저 닿은 W 에 맨 위 출처 세션의 사본이 왔다 — 맨 위 출처 W 로 옮긴다(남의 쏟음에 지평
            // 없이 놓이지 않게; 남의 차례 칸은 `evictForeign` 이 건너뛴다). 사본의 차례는 경쟁이라 「처음 닿은 사본」 으로 가르면 다른 탭이 그 출처를
            // iframe 으로 품을 때 맨 위 출처 W 의 절반 남짓이 남의 W 로 셈해졌다(검증 v20q-B Q11-b).
            const promote = !foreign and w.foreign;
            if (promote) w.foreign = false;
            if (self.sigs.remove(key)) self.sigs_tombs.removed(&self.sigs, 1);
            if (promote) {
                // `evict` 는 `order` 앞의 W 만 지운다 — 이 W(아직 `order` 에 없다)는 남는다.
                if (self.order.items.len >= max_ws) self.evict();
                try self.order.append(gpa, key);
            }
            return;
        }
        if (foreign) {
            if (self.foreign_order.items.len >= max_foreign_ws) self.evictForeign();
        } else if (self.order.items.len >= max_ws) self.evict();
        const sig: Sig = if (self.sigs.fetchRemove(key)) |kv| blk: {
            self.sigs_tombs.removed(&self.sigs, 1);
            break :blk kv.value.sig;
        } else .{};
        try self.ws.put(gpa, key, .{ .tau = tau, .disk = disk, .excluded = excl, .status = status, .sig = sig, .foreign = foreign });
        try (if (foreign) &self.foreign_order else &self.order).append(gpa, key);
        if (tau == 0 or tau <= self.horizon) return; // τ 없음(data:·blob:) — C2 / 지평 이하는 넣지 않는다(그 τ 의 P 는 지평으로 막힌다)
        const g = try self.taus.getOrPut(gpa, tau);
        if (!g.found_existing) {
            g.value_ptr.* = .{ .first = key, .sig = sig, .status = status };
        } else if (g.value_ptr.sig.method != sig.method or g.value_ptr.sig.range != sig.range or g.value_ptr.status != status) {
            // 재검증 8 차(R-1): 같은 τ 를 머리·상태가 다른 W 가 함께 썼다(GET 200 · HEAD · 206 — 바이트가 다르다) — 독 τ(영영).
            g.value_ptr.mixed = true;
        }
        g.value_ptr.live +|= 1;
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
        return self.notePairAt(gpa, key, q, 0, 0);
    }

    /// 재검증 10 차: 짝을 맺은 판정의 탭·단조 시각과 함께(`W.paired_at`·`pair_tab` — 처음 맺은 것만; 같은 짝을 뒤 탭이 다시 맺어도 앞 판정의
    /// 시각이 기준이다 — 그 시각 뒤에 시작한 W 는 그 기록의 주인일 수 없다).
    pub fn notePairAt(self: *Link, gpa: std.mem.Allocator, key: WKey, q: u64, browser: BrowserId, now_us: i64) std.mem.Allocator.Error!void {
        const w = self.ws.getPtr(key) orelse {
            // 응답 전에 짝이 정해지지 않는다(짝은 응답 때) — 응답이 버려졌으면(지평) 짝만 적는다.
            try self.explained.put(gpa, q, {});
            return;
        };
        if (w.pair != 0 and w.pair != q) w.bad = true;
        if (w.pair == 0) {
            w.pair = q;
            w.paired_at = now_us;
            w.pair_tab = browser;
        }
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
    // 재검증 12 차: 붙여 두기를 끈 길(`keep_visited` 거짓 — 11 차 그대로; 붙여 두는 길은 「재검증 12 차(⑩′)」 시험).
    var m: Sw = .{ .keep_visited = false };
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
    // 재검증 12 차: 붙여 두기를 끈 길(11 차 그대로 — 붙여 두는 길은 「재검증 12 차(⑩′)」 시험).
    var sw: Sw = .{ .keep_visited = false };
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

test "재검증 9 차(LOW-A·M2): 머리의 표가 차면 가장 오래된 것부터 잊는다 — 막 적은 W 의 머리는 남아 잇고, 실패한 W 의 칸은 지우며, 차례 목록은 2 × max_ws 를 넘지 않는다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    l.raiseVisible(5, 1);
    const get: Sig = .{ .method = 0x6e7 };
    var buf: [16]u8 = undefined;
    for (0..max_ws) |i| try l.noteSent(gpa_t, WKey.of(1, 0, try std.fmt.bufPrint(&buf, "s{d}", .{i})), get);
    try testing.expectEqual(@as(u32, max_ws), l.sigs.count());
    // 하나 더 — 가장 오래된 `evict_batch` 를 잊고 새것과 그 앞의 것들은 남는다(전에는 표를 통째로 비웠다).
    const late = WKey.of(1, 0, "late");
    try l.noteSent(gpa_t, late, get);
    try testing.expectEqual(@as(u32, max_ws - evict_batch + 1), l.sigs.count());
    try testing.expect(l.sigs.contains(late));
    try testing.expect(!l.sigs.contains(WKey.of(1, 0, "s0")));
    try testing.expect(!l.sigs.contains(WKey.of(1, 0, try std.fmt.bufPrint(&buf, "s{d}", .{evict_batch - 1}))));
    try testing.expect(l.sigs.contains(WKey.of(1, 0, try std.fmt.bufPrint(&buf, "s{d}", .{evict_batch}))));
    // 넘친 뒤에도 남은 W 가 응답하면 머리가 같은 P 를 잇는다.
    const mid = WKey.of(1, 0, try std.fmt.bufPrint(&buf, "s{d}", .{max_ws - 2}));
    try l.noteResponse(gpa_t, mid, 9_000, false, false, 200);
    try l.notePair(gpa_t, mid, 91);
    try testing.expect(l.decide(5, 9_000, .network, get) == .link);
    // 잊은 W 는 머리를 모른다 — 잇지 않는다(잃는 쪽).
    const old = WKey.of(1, 0, "s1");
    try l.noteResponse(gpa_t, old, 9_100, false, false, 200);
    try l.notePair(gpa_t, old, 92);
    try testing.expectEqual(@as(?Reason, .sig), reasonOf(l.decide(5, 9_100, .network, get)));
    // 실패한 W 의 칸은 지운다.
    l.forgetSig(late);
    try testing.expect(!l.sigs.contains(late));
    // 시작·실패가 오래 이어져도 표는 늘지 않고 차례 목록은 2 × max_ws 를 넘지 않는다.
    const n0 = l.sigs.count();
    for (0..3 * max_ws) |i| {
        const k = WKey.of(2, 0, try std.fmt.bufPrint(&buf, "f{d}", .{i}));
        try l.noteSent(gpa_t, k, get);
        l.forgetSig(k);
    }
    try testing.expectEqual(n0, l.sigs.count());
    try testing.expect(l.sig_order.items.len <= 2 * max_ws);
}

/// 재검증 8 차: 판정의 까닭(잇거나 기다리면 null) — 시험이 union 칸을 곧바로 읽어 변이에서 panic 으로 멈추지 않게.
fn reasonOf(v: Verdict) ?Reason {
    return switch (v) {
        .ambiguous => |a| a.reason,
        else => null,
    };
}

// ── 재검증 10 차 ─────────────────────────────────────────────────────────────────────────────────────────────

extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;

fn tombsOf(m: anytype) usize {
    var n: usize = 0;
    const md = m.metadata orelse return 0;
    for (0..m.capacity()) |x| {
        if (md[x].isTombstone()) n += 1;
    }
    return n;
}

test "재검증 10 차(LOW-T — 변이 N8·N18): 머리의 표 — 지운 뒤 다시 적은 열쇠는 옛 차례 칸에서 잊히지 않고 제 차례까지 남는다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    const get: Sig = .{ .method = 0x6e7 };
    var buf: [16]u8 = undefined;
    const again = WKey.of(1, 0, "again");
    try l.noteSent(gpa_t, again, get); // 맨 앞 차례
    l.forgetSig(again); // 실패로 지웠다
    for (0..max_ws / 2) |i| try l.noteSent(gpa_t, WKey.of(1, 0, try std.fmt.bufPrint(&buf, "s{d}", .{i})), get);
    try l.noteSent(gpa_t, again, get); // 같은 번호로 다시(새 차례)
    for (max_ws / 2..max_ws) |i| try l.noteSent(gpa_t, WKey.of(1, 0, try std.fmt.bufPrint(&buf, "s{d}", .{i})), get);
    // 표가 차 가장 오래된 `evict_batch` 를 잊는다 — 옛 차례 칸(맨 앞)은 다시 적은 칸이 아니라 건너뛴다.
    try l.noteSent(gpa_t, WKey.of(1, 0, "x"), get);
    try testing.expect(l.sigs.contains(again));
    try testing.expect(!l.sigs.contains(WKey.of(1, 0, "s0")));
    try testing.expect(l.sigs.contains(WKey.of(1, 0, try std.fmt.bufPrint(&buf, "s{d}", .{max_ws / 2 - 1}))));
}

test "재검증 10 차(LOW-T — 변이 N9) · v20p-B Q19-c: 머리의 표를 산 칸으로 4 × max_ws 넣어도(잊기·차례 목록 줄이기가 여러 번) 표는 max_ws 를 넘지 않고 가장 새 것이 남는다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    const get: Sig = .{ .method = 0x6e7 };
    var buf: [16]u8 = undefined;
    var worst: u64 = 0;
    for (0..4 * max_ws) |i| {
        const a = clock_gettime_nsec_np(16);
        try l.noteSent(gpa_t, WKey.of(1, 0, try std.fmt.bufPrint(&buf, "s{d}", .{i})), get);
        worst = @max(worst, clock_gettime_nsec_np(16) - a);
        try testing.expect(l.sigs.count() <= max_ws);
    }
    try testing.expect(l.sig_order.items.len <= 2 * max_ws);
    try testing.expect(l.sigs.contains(WKey.of(1, 0, try std.fmt.bufPrint(&buf, "s{d}", .{4 * max_ws - 1}))));
    try testing.expect(!l.sigs.contains(WKey.of(1, 0, try std.fmt.bufPrint(&buf, "s{d}", .{3 * max_ws - evict_batch}))));
    std.debug.print("\n[10 차 Q19-c] live fill {d}: worst call {d} µs\n", .{ 4 * max_ws, worst / 1000 });
}

test "재검증 10 차(MED-P1) · v20p-B Q19-f: 머리의 표가 한 번의 무더기(동시 2 048)로 자란 뒤 보통의 보냄·응답이 오래 이어져도 묘비는 자리의 1/4 아래이고, 줄이기(차례 목록)의 한 번 값이 묶인다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    const get: Sig = .{ .method = 0x6e7 };
    var buf: [24]u8 = undefined;
    for (0..2048) |i| try l.noteSent(gpa_t, WKey.of(7, 0, try std.fmt.bufPrint(&buf, "b{d}", .{i})), get);
    // 셋은 끝내 응답하지 않는다(떼어진 세션의 W — 표가 비지 않는다).
    for (3..2048) |i| l.forgetSig(WKey.of(7, 0, try std.fmt.bufPrint(&buf, "b{d}", .{i})));
    var worst: u64 = 0;
    var i: usize = 0;
    for (0..6) |_| {
        for (0..2 * max_ws) |_| {
            i += 1;
            const k = WKey.of(8, 0, try std.fmt.bufPrint(&buf, "c{d}", .{i}));
            const a = clock_gettime_nsec_np(16);
            try l.noteSent(gpa_t, k, get);
            try l.noteResponse(gpa_t, k, 0, false, false, 200); // 머리를 응답 표로 옮긴다(τ 없음 — 색인에는 넣지 않는다)
            worst = @max(worst, clock_gettime_nsec_np(16) - a);
        }
        try testing.expect(tombsOf(&l.sigs) * 4 <= l.sigs.capacity());
    }
    std.debug.print("\n[10 차 Q19-f] sigs {d} cap {d} tombstones {d} · worst call {d} µs\n", .{ l.sigs.count(), l.sigs.capacity(), tombsOf(&l.sigs), worst / 1000 });
    // 전에는 줄이기 한 번이 68–72 ms(ReleaseFast)·583–596 ms(Debug)였다.
    try testing.expect(worst < 40_000_000);
}

test "재검증 10 차(MED-P2) · v20p-B Q19-e: 응답한 W 의 표(ws·taus·explained)는 max_ws 를 넘겨 쫓아내기가 오래 이어져도 묘비가 자리의 1/4 아래이고 응답 하나의 값이 묶인다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    var buf: [24]u8 = undefined;
    var i: usize = 0;
    var worst_mean: u64 = 0;
    for (0..12) |_| {
        var total: u64 = 0;
        for (0..max_ws) |_| {
            i += 1;
            const k = WKey.of(8, 0, try std.fmt.bufPrint(&buf, "r{d}", .{i}));
            const a = clock_gettime_nsec_np(16);
            try l.noteResponse(gpa_t, k, 1_700_000_000_000_000 + @as(i64, @intCast(i)) * 10, false, false, 200);
            try l.notePair(gpa_t, k, 1_000_000 + i);
            total += clock_gettime_nsec_np(16) - a;
        }
        worst_mean = @max(worst_mean, total / max_ws);
        try testing.expect(tombsOf(&l.ws) * 4 <= l.ws.capacity());
        try testing.expect(tombsOf(&l.taus) * 4 <= l.taus.capacity());
        try testing.expect(tombsOf(&l.explained) * 4 <= l.explained.capacity());
    }
    std.debug.print("\n[10 차 Q19-e] ws {d} cap {d} · worst round mean {d} ns · ws removed {d} rebuilds {d}\n", .{ l.ws.count(), l.ws.capacity(), worst_mean, l.ws_tombs.total, l.ws_tombs.rebuilds });
    // 재검증 11 차(LOW-T — 검증 v20q 변이 Q11): 다시 짓기는 지운 수가 자리의 1/4 에 닿을 때마다 한 번 — 다시 지은 뒤 셈을 0 으로 두지 않으면(지울
    // 때마다 다시 짓는 퇴행) 시간 위 끝은 못 보지만 이 셈이 본다.
    try testing.expect(l.ws_tombs.rebuilds > 0);
    try testing.expect(@as(u64, l.ws_tombs.rebuilds) * (l.ws.capacity() / 4) <= l.ws_tombs.total);
    // 전에는 판 11–13 에서 응답 하나 222 µs(ReleaseFast — 표 전체 훑기)였다.
    try testing.expect(worst_mean < 50_000);
}

test "재검증 10 차(LOW-K): 남의 출처 세션의 W 는 따로 센다 — max_foreign_ws 를 넘으면 오래된 남의 W 만 놓고(지평은 그대로), 맨 위 출처 W 와 나눈 τ 는 독으로 남고, 남의 W 만 쓴 τ 는 지운다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    l.raiseVisible(5, 1);
    const get: Sig = .{ .method = 0x6e7 };
    const own = WKey.of(1, 0, "own");
    try l.noteSent(gpa_t, own, get);
    try l.noteResponse(gpa_t, own, 5_000, false, false, 200);
    try l.notePair(gpa_t, own, 31);
    // 맨 위 출처 W 와 τ 를 나눈 남의 W(가장 오래된 — 먼저 놓인다).
    try l.noteResponseFrom(gpa_t, WKey.of(9, 0, "shared"), 5_000, false, false, 200, true);
    var buf: [24]u8 = undefined;
    for (0..max_foreign_ws + 100) |i| try l.noteResponseFrom(gpa_t, WKey.of(9, 0, try std.fmt.bufPrint(&buf, "f{d}", .{i})), 10_000 + @as(i64, @intCast(i)), false, false, 200, true);
    try testing.expect(l.foreign_order.items.len <= max_foreign_ws);
    try testing.expect(l.ws.contains(own));
    try testing.expectEqual(@as(i64, 0), l.horizon);
    try testing.expect(!l.ws.contains(WKey.of(9, 0, "shared")));
    // 나눈 τ 는 둘이 쓴 독 τ — 남의 W 를 놓아도 그대로(잇지 않는다).
    const why = reasonOf(l.decide(5, 5_000, .network, get));
    try testing.expect(why == .mixed or why == .many);
    // 남의 W 만 쓴 τ 는 지웠다(놓은 W 의 τ — 기다림 → 시한 뒤 `no_worker`).
    try testing.expect(!l.taus.contains(10_000));
    try testing.expect(l.taus.contains(10_000 + @as(i64, @intCast(max_foreign_ws + 99))));
    // 맨 위 출처 W 는 남의 W 에 밀리지 않는다 — 남의 W 를 아무리 쏟아도 `order` 는 하나.
    try testing.expectEqual(@as(usize, 1), l.order.items.len);
}

test "재검증 10 차(MED-P1 — 실패로 지우기): 머리의 표는 보냄·실패(forgetSig)를 오래 되풀이해도 묘비가 자리의 1/4 아래다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    const get: Sig = .{ .method = 0x6e7 };
    var buf: [24]u8 = undefined;
    for (0..2048) |i| try l.noteSent(gpa_t, WKey.of(7, 0, try std.fmt.bufPrint(&buf, "b{d}", .{i})), get);
    for (3..2048) |i| l.forgetSig(WKey.of(7, 0, try std.fmt.bufPrint(&buf, "b{d}", .{i})));
    for (0..100_000) |i| {
        const k = WKey.of(8, 0, try std.fmt.bufPrint(&buf, "f{d}", .{i}));
        try l.noteSent(gpa_t, k, get);
        l.forgetSig(k);
    }
    try testing.expectEqual(@as(u32, 3), l.sigs.count());
    try testing.expect(tombsOf(&l.sigs) * 4 <= l.sigs.capacity());
}

// ── 검증 v20q 4 회차 탐침(묘비 — 높은 적재) ─────────────────────────────────────────────────────────────

fn v20qFreeOf(m: anytype) usize {
    var n: usize = 0;
    const md = m.metadata orelse return 0;
    for (0..m.capacity()) |x| {
        if (md[x].isFree()) n += 1;
    }
    return n;
}

test "v20q R4-a(묘비 — 적재 0.78 근처): 응답이 끝내 오지 않은 W 의 머리 13 000 이 남은 표에서 보냄·응답을 오래 되풀이하면 빈 칸·한 부름 최악·줄이기 값은" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    const get: Sig = .{ .method = 0x6e7 };
    var buf: [24]u8 = undefined;
    const stale: usize = if (std.c.getenv("V20Q_STALE")) |s| std.fmt.parseInt(usize, std.mem.span(s), 10) catch 13_000 else 13_000;
    for (0..stale) |i| try l.noteSent(gpa_t, WKey.of(7, 0, try std.fmt.bufPrint(&buf, "d{d}", .{i})), get);
    const cap0 = l.sigs.capacity();
    var worst: u64 = 0;
    var worst_at: usize = 0;
    var min_free: usize = std.math.maxInt(usize);
    var max_tomb: usize = 0;
    var rehashes: usize = 0;
    var last_n: u32 = 0;
    const iters: usize = 120_000;
    for (0..iters) |i| {
        const k = WKey.of(8, 0, try std.fmt.bufPrint(&buf, "c{d}", .{i}));
        const a = clock_gettime_nsec_np(16);
        try l.noteSent(gpa_t, k, get);
        try l.noteResponse(gpa_t, k, 0, false, false, 200);
        const d = clock_gettime_nsec_np(16) - a;
        if (d > worst) {
            worst = d;
            worst_at = i;
        }
        if (l.sigs_tombs.n < last_n) rehashes += 1;
        last_n = l.sigs_tombs.n;
        if (i % 97 == 0) {
            min_free = @min(min_free, v20qFreeOf(&l.sigs));
            max_tomb = @max(max_tomb, tombsOf(&l.sigs));
        }
    }
    std.debug.print("\n[v20q R4-a] stale {d} cap {d}->{d} count {d} · min free {d} · max tombs {d} · rehash {d} · worst call {d} µs at {d} · sig_order {d}\n", .{ stale, cap0, l.sigs.capacity(), l.sigs.count(), min_free, max_tomb, rehashes, worst / 1000, worst_at, l.sig_order.items.len });
    try testing.expect(min_free > 0);
}

test "재검증 11 차(LOW-K′) · v20q R3-a: 같은 W 를 남의 출처로 보는 탭이 먼저 응답을 넣어도 맨 위 출처로 보는 탭의 사본이 오면 맨 위 출처 W 다 — 남의 W 4 096 뒤에도 남는다(10 차는 놓았다); 남의 사본으로만 본 W 는 상한에서 놓이고(지평 없이) 그 τ 칸이 지워진다" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    l.raiseVisible(5, 1);
    const get: Sig = .{ .method = 0x6e7 };
    const w1 = WKey.of(1, 0, "w1");
    try l.noteSent(gpa_t, w1, get); // 탭 5(맨 위 출처 세션)의 시작 사건
    try l.noteResponseFrom(gpa_t, w1, 5_000, false, false, 200, true); // 탭 6(남의 출처 세션)이 먼저 응답을 넣었다
    try testing.expect(l.ws.get(w1).?.foreign);
    try l.noteResponse(gpa_t, w1, 5_000, false, false, 200); // 탭 5 의 사본 — 맨 위 출처 W 로 옮긴다
    try testing.expect(!l.ws.get(w1).?.foreign);
    // 맨 위 출처 차례에 든다(상한에서 맨 위 출처 W 로 쫓긴다 — 영영 남지 않는다).
    try testing.expect(for (l.order.items) |k| {
        if (k.target == w1.target and k.rid == w1.rid) break true;
    } else false);
    try l.notePairAt(gpa_t, w1, 31, 5, 100);
    const v0 = l.decide(5, 5_000, .network, get);
    // 남의 사본으로만 본 W3(τ 6 000) — 상한(`>=`)에서 놓인다.
    const w3 = WKey.of(3, 0, "w3");
    try l.noteResponseFrom(gpa_t, w3, 6_000, false, false, 200, true);
    var buf: [24]u8 = undefined;
    for (0..max_foreign_ws - 1) |i| try l.noteResponseFrom(gpa_t, WKey.of(9, 0, try std.fmt.bufPrint(&buf, "f{d}", .{i})), 10_000 + @as(i64, @intCast(i)), false, false, 200, true);
    const kept = l.ws.contains(w1);
    const gone3 = !l.ws.contains(w3);
    // 같은 τ 의 다른 맨 위 출처 W(µs 까지 같은 τ — 실제로는 드물다) — W1 이 남아 독 τ(`many`).
    const w2 = WKey.of(2, 0, "w2");
    try l.noteSent(gpa_t, w2, get);
    try l.noteResponse(gpa_t, w2, 5_000, false, false, 200);
    try l.notePairAt(gpa_t, w2, 77, 5, 200);
    const v1 = l.decide(5, 5_000, .network, get);
    std.debug.print("\n[v20q R3-a] before {s} · w1 kept {} · w3 evicted {} (τ 칸 {}) · horizon {d} · after {s}\n", .{ @tagName(v0), kept, gone3, l.taus.contains(6_000), l.horizon, @tagName(v1) });
    try testing.expect(v0 == .link and kept and gone3 and !l.taus.contains(6_000) and l.horizon == 0);
    try testing.expect(v1 == .ambiguous and v1.ambiguous.reason == .many);
}

test "재검증 11 차(LOW-R1) · v20q-B Q11-c: 남의 W 놓기(evictForeign)는 디스크 적중과 τ 를 나눈 남의 W 의 τ 칸·짝을 맺은 남의 W 의 explained 칸도 지운다 — 표가 남의 W 상한 안에 묶이고 지평은 그대로(10 차는 40 960 판 뒤 taus 41 415·explained 10 240)" {
    var l: Link = .{};
    defer l.deinit(gpa_t);
    var buf: [32]u8 = undefined;
    const rounds = 10 * max_foreign_ws;
    for (0..rounds) |i| {
        const tau: i64 = 1_700_000_000_000_000 + @as(i64, @intCast(i)) * 10;
        // 같은 남의 워커가 네트워크로 받은 응답과, 그 뒤 HTTP 캐시(디스크)에서 같은 τ 로 다시 받은 응답.
        try l.noteResponseFrom(gpa_t, WKey.of(9, 0, try std.fmt.bufPrint(&buf, "n{d}", .{i})), tau, false, false, 200, true);
        try l.noteResponseFrom(gpa_t, WKey.of(9, 0, try std.fmt.bufPrint(&buf, "d{d}", .{i})), tau, true, false, 200, true);
        // 다른 탭의 맨 위 출처 세션이 짝을 맺는 W(첫 사본이 남의 세션으로 닿았다 — 남의 W 로 셈해졌다).
        if (i % 4 == 0) {
            const k = WKey.of(10, 0, try std.fmt.bufPrint(&buf, "p{d}", .{i}));
            try l.noteResponseFrom(gpa_t, k, tau + 3, false, false, 200, true);
            try l.notePairAt(gpa_t, k, 5_000_000 + i, 6, 1);
        }
    }
    std.debug.print("\n[v20q Q11-c] after {d} rounds: ws {d} foreign_order {d} taus {d} explained {d} horizon {d}\n", .{ rounds, l.ws.count(), l.foreign_order.items.len, l.taus.count(), l.explained.count(), l.horizon });
    try testing.expect(l.ws.count() <= max_foreign_ws);
    try testing.expect(l.taus.count() <= l.ws.count());
    try testing.expect(l.explained.count() <= l.ws.count());
    try testing.expectEqual(@as(i64, 0), l.horizon);
    // 남은 칸은 산 W 를 가리킨다(쫓긴 W 의 칸이 남지 않는다).
    var it = l.taus.valueIterator();
    while (it.next()) |e| try testing.expect(e.live > 0);
}

test "재검증 12 차: 놓기 답 기다리기(`pend`) — 답의 번호·세션이 맞을 때만 빼고, 떨어짐·탭 닫힘·시한은 빼어 건지기로(부른 쪽), 뗄 표시는 남의 출처 시한 떼기가 덧붙인다" {
    var sw: Sw = .{};
    try std.testing.expect(sw.arm(5));
    try std.testing.expect(sw.pendAdd(5, "AA", "T1", 101, 1_000, false));
    try std.testing.expect(sw.pendAdd(5, "BB", "T2", 102, 2_000, true));
    try std.testing.expect(sw.pendAdd(6, "CC", "T3", 103, 3_000, false));
    try std.testing.expect(!sw.pendAdd(5, "DD", "T4", 0, 3_000, false)); // 번호 없음
    try std.testing.expectEqual(@as(usize, 2), sw.pendCount(5));
    try std.testing.expectEqual(@as(?i64, 1_000), sw.nextPend());
    // 다른 세션의 같은 번호·같은 세션의 다른 번호는 빼지 않는다.
    try std.testing.expect(sw.pendDone("BB", 101) == null);
    try std.testing.expect(sw.pendDone("AA", 102) == null);
    // 기록이 멈춰도(세션 표를 비워도) 놓기 답은 기다린다(관찰자는 남는다).
    _ = sw.detachAll(5);
    try std.testing.expectEqual(@as(usize, 2), sw.pendCount(5));
    const a = sw.pendDone("AA", 101).?;
    try std.testing.expect(!a.detach and std.mem.eql(u8, a.targetSlice(), "T1"));
    const g = sw.pendGone("BB").?;
    try std.testing.expect(g.detach and std.mem.eql(u8, g.targetSlice(), "T2"));
    try std.testing.expect(sw.pendGone("BB") == null);
    // 시한 — 가장 이른 것부터, 탭 닫힘은 그 탭의 것을 모두.
    try std.testing.expect(sw.pendExpired(3_000 + pend_timeout_us - 1, pend_timeout_us) == null);
    try std.testing.expect(std.mem.eql(u8, sw.pendExpired(3_000 + pend_timeout_us, pend_timeout_us).?.sidSlice(), "CC"));
    try std.testing.expect(sw.pendAdd(7, "FF", "T6", 105, 5_000, true));
    try std.testing.expect(sw.pendAdd(7, "GG", "T7", 106, 5_000, false));
    try std.testing.expect(sw.pendMarkDetach("GG"));
    try std.testing.expect(sw.pendAdd(8, "HH", "T8", 107, 5_000, false)); // 다른 탭의 것은 남는다
    var n: usize = 0;
    while (sw.pendOfBrowser(7)) |p| : (n += 1) try std.testing.expect(p.detach and p.browser == 7);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, 1), sw.pendCount(0));
    try std.testing.expect(std.mem.eql(u8, sw.pendOfBrowser(8).?.sidSlice(), "HH"));
    try std.testing.expectEqual(@as(usize, 0), sw.pendCount(0));
    // 자리 상한.
    var bb: [8]u8 = undefined;
    for (0..max_pend) |k| try std.testing.expect(sw.pendAdd(9, std.fmt.bufPrint(&bb, "S{d}", .{k}) catch unreachable, "T", @intCast(k + 1), 1, false));
    try std.testing.expect(!sw.pendAdd(9, "XX", "T", 9_999, 1, false));
    sw.forget(9);
    try std.testing.expectEqual(@as(usize, 0), sw.pendCount(0));
}

test "재검증 12 차: 건지기(`rescue`) — 같은 타깃은 한 번, 붙으면 빼고, 붙이기 실패 답이면 지우고, 다시 해 보는 사이·횟수를 넘으면 지운다" {
    var sw: Sw = .{};
    try std.testing.expect(sw.rescueAdd("T1", 5, 1_000));
    try std.testing.expect(sw.rescueAdd("T1", 6, 1_100)); // 이미 있다 — 그대로
    try std.testing.expect(!sw.rescueAdd("", 5, 1_000));
    try std.testing.expect(sw.rescueAdd("T2", 0, 1_000));
    try std.testing.expectEqual(@as(usize, 2), sw.rescueCount());
    try std.testing.expectEqual(@as(?i64, 1_000), sw.nextRescue()); // 처음 해 보기는 곧
    const x = sw.rescueDue(1_000).?;
    try std.testing.expectEqual(@as(BrowserId, 5), x.hint);
    x.cmd_id = 77;
    const y = sw.rescueDue(1_000).?;
    try std.testing.expect(std.mem.eql(u8, y.targetSlice(), "T2"));
    try std.testing.expect(sw.rescueDue(1_000 + rescue_retry_us - 1) == null); // 다음 때는 사이 뒤
    try std.testing.expectEqual(@as(?i64, 1_000 + rescue_retry_us), sw.nextRescue());
    try std.testing.expect(sw.rescueFailed(77));
    try std.testing.expect(!sw.rescueFailed(77));
    try std.testing.expect(sw.rescueTake("T2", 5) != null);
    try std.testing.expect(sw.rescueTake("T2", 5) == null);
    try std.testing.expectEqual(@as(usize, 0), sw.rescueCount());
    try std.testing.expect(sw.rescueAdd("T3", 5, 0));
    var tries: usize = 0;
    var now: i64 = 0;
    while (tries < rescue_tries + 5) : (tries += 1) {
        if (sw.rescueDue(now) == null) break;
        now += rescue_retry_us;
    }
    try std.testing.expectEqual(@as(usize, rescue_tries), tries);
    try std.testing.expectEqual(@as(usize, 0), sw.rescueCount());
    // 한 타깃은 `rescue_per_target` 번까지(T3 은 위에서 한 번 넣었다).
    for (1..rescue_per_target) |_| {
        try std.testing.expect(sw.rescueAdd("T3", 5, 0));
        try std.testing.expect(sw.rescueTake("T3", 5) != null);
    }
    try std.testing.expect(!sw.rescueAdd("T3", 5, 0));
    var bb: [8]u8 = undefined;
    for (0..max_rescue) |k| try std.testing.expect(sw.rescueAdd(std.fmt.bufPrint(&bb, "R{d}", .{k}) catch unreachable, 5, 1));
    try std.testing.expect(!sw.rescueAdd("RX", 5, 1));
}

test "재검증 12 차: 멈춘 워커에 다시 붙는 세션은 다음 epoch — 두 탭이 같은 값을 쓰고, 다시 뜸도 적는다(같은 targetId 의 requestId 가 옛 W 와 겹치지 않게)" {
    var sw: Sw = .{};
    try std.testing.expect(sw.arm(5));
    try std.testing.expect(sw.arm(6));
    try std.testing.expectEqual(Attach.keep, sw.attached(5, "A1", "T"));
    try std.testing.expectEqual(Attach.keep, sw.attached(6, "B1", "T"));
    try std.testing.expectEqual(@as(u32, 0), sw.find("A1").?.epoch);
    // 두 탭 모두 멈춤을 본다 — 다음 epoch 는 1(두 번 오르지 않는다).
    _ = sw.stopTarget("A1");
    _ = sw.stopTarget("B1");
    sw.detached("A1");
    sw.detached("B1");
    try std.testing.expectEqual(Attach.keep, sw.attached(5, "A2", "T"));
    try std.testing.expectEqual(Attach.keep, sw.attached(6, "B2", "T"));
    try std.testing.expectEqual(@as(u32, 1), sw.find("A2").?.epoch);
    try std.testing.expectEqual(@as(u32, 1), sw.find("B2").?.epoch);
    // 다시 뜸(같은 세션)도 적는다 — 그 뒤 새 세션은 그 위에서.
    sw.reloaded("A2");
    try std.testing.expectEqual(@as(u32, 2), sw.find("A2").?.epoch);
    sw.detached("A2");
    try std.testing.expectEqual(Attach.keep, sw.attached(5, "A3", "T"));
    try std.testing.expectEqual(@as(u32, 2), sw.find("A3").?.epoch);
    // 다른 타깃은 0.
    try std.testing.expectEqual(Attach.keep, sw.attached(5, "C1", "U"));
    try std.testing.expectEqual(@as(u32, 0), sw.find("C1").?.epoch);
}

test "재검증 12 차(⑩′): 다녀간 출처의 세션은 떠나도 떼지 않는다 — 떠나 있음(`away` — 밸브·맞추기 밖)·남의 출처 몫에 세지 않음·시한 떼기 없음, 돌아오면 맨 위 출처의 것(한 번 `takeReturned`), 처음부터 남의 출처였던 세션은 지금처럼 시한 뒤 뗀다" {
    var sw: Sw = .{};
    const A: u64 = 0xA;
    const B: u64 = 0xB;
    try std.testing.expect(sw.arm(5));
    try std.testing.expectEqual(Attach.keep, sw.attachedAt(5, "S1", "TA", 10));
    try std.testing.expectEqual(Origin.own, sw.noteOrigin("S1", A, A, 10));
    try std.testing.expect(sw.find("S1").?.visited);
    // 남의 출처 iframe 의 워커(처음부터 맨 위 출처가 아니었다).
    try std.testing.expectEqual(Attach.keep, sw.attachedAt(5, "S2", "TB", 20));
    try std.testing.expectEqual(Origin.foreign, sw.noteOrigin("S2", B, A, 20));
    try std.testing.expect(!sw.find("S2").?.visited);
    // 그 탭이 C 로 떠난다.
    _ = sw.retarget(5, 0xC, 1_000);
    const s1 = sw.find("S1").?;
    try std.testing.expect(s1.away() and s1.foreign_since != 0);
    try std.testing.expectEqual(@as(usize, 1), sw.foreignCount(5)); // S2 만
    try std.testing.expectEqual(@as(usize, 1), sw.awayCount(5));
    // 시한 뒤 — 남의 출처 S2 만 뗀다.
    const gone = sw.takeForeign(1_000 + foreign_grace_us).?;
    try std.testing.expect(std.mem.eql(u8, gone.sidSlice(), "S2"));
    try std.testing.expect(sw.takeForeign(1_000 + foreign_grace_us * 10) == null);
    try std.testing.expect(sw.find("S1") != null);
    // A 로 돌아온다 — 맨 위 출처의 것, 돌아옴을 한 번 알린다.
    _ = sw.retarget(5, A, 5_000_000);
    try std.testing.expect(!sw.find("S1").?.away());
    try std.testing.expectEqual(@as(i64, 5_000_000), sw.find("S1").?.own_since);
    const r = sw.takeReturned(5).?;
    try std.testing.expect(std.mem.eql(u8, r.sidSlice(), "S1"));
    try std.testing.expect(sw.takeReturned(5) == null);
    // 대조: 붙여 두기를 끄면 다녀간 출처도 떠나면 시한 뒤 뗀다(11 차 길).
    var off: Sw = .{ .keep_visited = false };
    try std.testing.expect(off.arm(5));
    _ = off.attachedAt(5, "S1", "TA", 10);
    _ = off.noteOrigin("S1", A, A, 10);
    _ = off.retarget(5, 0xC, 1_000);
    try std.testing.expect(std.mem.eql(u8, off.takeForeign(1_000 + foreign_grace_us).?.sidSlice(), "S1"));
    // 남의 출처 몫(탭 4)이 찬 탭에서 떠나도 다녀간 출처 세션은 세워 두지 않는다(곧 떼는 길 — 남의 출처 세션만).
    var full: Sw = .{};
    try std.testing.expect(full.arm(8));
    _ = full.attachedAt(8, "V", "TV", 10);
    _ = full.noteOrigin("V", A, A, 10);
    var sb: [8]u8 = undefined;
    for (0..max_foreign_per_tab) |i| {
        const sid = std.fmt.bufPrint(&sb, "F{d}", .{i}) catch unreachable;
        _ = full.attachedAt(8, sid, sid, 20);
        _ = full.noteOrigin(sid, 0xF0 + i, A, 20);
    }
    try std.testing.expectEqual(max_foreign_per_tab, full.foreignCount(8));
    _ = full.retarget(8, 0xC, 1_000);
    try std.testing.expect(full.find("V").?.away());
    try std.testing.expectEqual(@as(usize, 1), full.awayCount(8));
    for (0..max_foreign_per_tab) |_| try std.testing.expect(!std.mem.eql(u8, full.takeForeign(1_000 + foreign_grace_us).?.sidSlice(), "V"));
    try std.testing.expect(full.takeForeign(1_000 + foreign_grace_us * 10) == null);
}

test "재검증 12 차(⑩′): 그 탭이 그 워커에 켠 세션을 쥐면 새 세션은 그림자(켜지 않고 시한 없이 쥔다), Chromium 이 뗀 다녀간 출처 세션은 다시 붙일 것으로 내주고(maru 가 뗀 것·옛 세대는 아니다), 몫(탭 16)이 차면 가장 오래 떠나 있던 세션부터 뺀다" {
    var sw: Sw = .{};
    try std.testing.expect(sw.arm(5));
    _ = sw.attachedAt(5, "M1", "TA", 10);
    _ = sw.noteOrigin("M1", 0xA, 0xA, 10);
    sw.noteEnable("M1", 77);
    try std.testing.expectEqual(Attach.shadow, sw.attachedAt(5, "X1", "TA", 20));
    try std.testing.expectEqual(Attach.shadow, sw.attachedAt(5, "X1", "TA", 30)); // 다시 알려져도
    try std.testing.expect(sw.takeForeign(std.math.maxInt(i64) / 8) == null); // 그림자는 시한 떼기가 없다
    try std.testing.expect(sw.nextForeign() == null);
    // 다른 탭은 그림자가 아니다.
    try std.testing.expect(sw.arm(6));
    try std.testing.expectEqual(Attach.keep, sw.attachedAt(6, "Y1", "TA", 40));
    // Chromium 이 뗐다 — 다시 붙일 것으로.
    const k = sw.keepAfterDetach("M1").?;
    try std.testing.expect(std.mem.eql(u8, k.targetSlice(), "TA"));
    sw.markDetaching("M1");
    try std.testing.expect(sw.keepAfterDetach("M1") == null); // maru 가 뗀 것
    try std.testing.expect(std.mem.eql(u8, sw.targetOf("X1"), "TA")); // 재검증 13 차: 그림자도 그 워커를 안다
    // 옛 세대(기록이 멈췄다)는 다시 붙이지 않는다.
    _ = sw.attachedAt(6, "Y2", "TC", 50);
    _ = sw.noteOrigin("Y2", 0xC, 0xC, 50);
    _ = sw.detachAll(6);
    try std.testing.expect(sw.keepAfterDetach("Y2") == null);
    // 몫: 탭 7 에 떠나 있는 세션 15 개 + 맨 위 출처 1 개 — 새 세션은 가장 오래 떠난 것을 뺀다.
    try std.testing.expect(sw.arm(7));
    var sb: [8]u8 = undefined;
    var tb: [8]u8 = undefined;
    for (0..15) |i| {
        const sid = std.fmt.bufPrint(&sb, "A{d}", .{i}) catch unreachable;
        const tid = std.fmt.bufPrint(&tb, "T{d}", .{i}) catch unreachable;
        try std.testing.expectEqual(Attach.keep, sw.attachedAt(7, sid, tid, 100));
        _ = sw.noteOrigin(sid, 0x100 + i, 0x100 + i, 100);
        _ = sw.retarget(7, 0x200 + i, 1_000 + @as(i64, @intCast(i)));
    }
    try std.testing.expectEqual(@as(usize, 15), sw.awayCount(7));
    _ = sw.attachedAt(7, "N0", "TN0", 2_000);
    _ = sw.noteOrigin("N0", 0x214, 0x214, 2_000);
    try std.testing.expect(sw.takeEvicted() == null);
    // 재검증 13 차(LOW-Q1): 출처를 알기 전에는 빼지 않는다 — 남의 출처 iframe 의 워커(남의 출처 몫에 센다)는 붙여 둔 세션을 빼지 않는다.
    try std.testing.expectEqual(Attach.keep, sw.attachedAt(7, "F1", "TF1", 2_500));
    try std.testing.expect(sw.takeEvicted() == null);
    try std.testing.expectEqual(Origin.foreign, sw.noteOrigin("F1", 0x999, 0x214, 2_500));
    try std.testing.expect(sw.takeEvicted() == null);
    try std.testing.expectEqual(@as(usize, 15), sw.awayCount(7));
    // 맨 위 출처의 새 세션이면 그때 가장 오래 떠나 있던 것을 뺀다.
    try std.testing.expectEqual(Attach.keep, sw.attachedAt(7, "N1", "TN1", 3_000));
    try std.testing.expect(sw.takeEvicted() == null);
    try std.testing.expectEqual(Origin.own, sw.noteOrigin("N1", 0x214, 0x214, 3_000));
    const ev = sw.takeEvicted().?;
    try std.testing.expect(std.mem.eql(u8, ev.sidSlice(), "A0")); // 가장 오래 떠나 있던 것
    try std.testing.expect(sw.takeEvicted() == null);
    try std.testing.expect(sw.find("A0") == null);
    try std.testing.expectEqual(@as(usize, 16), sw.ownCount(7) + sw.awayCount(7));
}

test "재검증 12 차: 건지기의 붙여 두기 표시 — 같은 타깃 한 자리에 표시만 더하고 꺼내면 그 표시와 함께" {
    var sw: Sw = .{};
    try std.testing.expect(sw.rescueAdd("T", 5, 0));
    try std.testing.expect(sw.rescueAddAs("T", 5, 0, true));
    try std.testing.expectEqual(@as(usize, 1), sw.rescueCount());
    const x = sw.rescueTake("T", 5).?;
    try std.testing.expect(x.keep and x.hint == 5 and x.release);
    try std.testing.expect(sw.rescueTake("T", 5) == null);
    // 붙여 두기만(놓을 워커가 아니다)은 그 탭이 닫히면 버리고, 놓을 워커의 것은 남긴다(다른 탭에서 건진다).
    try std.testing.expect(sw.rescueAddAs("K", 5, 0, true));
    try std.testing.expect(sw.rescueAdd("R", 5, 0));
    // 붙여 두기가 먼저 든 타깃에 놓을 워커가 더해지면 그 자리는 놓을 것이다(그 탭이 닫혀도 다른 탭에서 건진다).
    try std.testing.expect(sw.rescueAddAs("M", 5, 0, true));
    try std.testing.expect(sw.rescueAdd("M", 5, 0));
    try std.testing.expect(sw.rescueAddAs("O", 6, 0, true));
    sw.forget(5);
    try std.testing.expect(sw.rescueTake("K", 5) == null);
    const o = sw.rescueTake("O", 6).?;
    try std.testing.expect(o.hint == 6 and o.keep and !o.release);
    const m = sw.rescueTake("M", 5).?;
    try std.testing.expect(m.keep and m.release);
    const r = sw.rescueTake("R", 7).?; // 놓을 워커는 아무 탭의 붙음이 놓는다
    try std.testing.expect(r.release and !r.keep);
}

test "재검증 13 차(LOW-Q2): 붙여 두기의 다시 붙이기는 그 탭의 붙음만 가져간다 — 다른 탭의 auto 붙음이 먼저 와도 남고, 놓을 워커 몫만 그 탭이 가져간다" {
    var sw: Sw = .{};
    try std.testing.expect(sw.arm(5));
    try std.testing.expect(sw.arm(6));
    // 탭 5 가 떠날 때의 다시 붙이기(붙여 두기만) — 탭 6 의 auto 붙음이 먼저 온다.
    try std.testing.expect(sw.rescueAddAs("K", 5, 0, true));
    try std.testing.expect(sw.rescueTake("K", 6) == null); // 12 차: 탭 6 이 가져가 탭 5 는 붙여 둔 세션을 잃었다
    try std.testing.expectEqual(@as(usize, 1), sw.rescueCount());
    const k = sw.rescueTake("K", 5).?;
    try std.testing.expect(k.keep and k.hint == 5 and sw.keepCurrent(k));
    // 놓을 워커이기도 하면 — 탭 6 의 붙음이 놓기 몫만 가져가고 붙여 두기는 탭 5 를 위해 남는다.
    try std.testing.expect(sw.rescueAddAs("B", 5, 0, true));
    try std.testing.expect(sw.rescueAdd("B", 0, 0));
    const r6 = sw.rescueTake("B", 6).?;
    try std.testing.expect(r6.release and !r6.keep);
    const r5 = sw.rescueTake("B", 5).?;
    try std.testing.expect(r5.keep and !r5.release);
    try std.testing.expectEqual(@as(usize, 0), sw.rescueCount());
}

test "재검증 13 차(검증 v20r-A 4 회차의 관찰): 붙여 두기의 다시 붙이기는 그 탭의 세대를 적는다 — 그 사이 기록을 끄고 다시 켰으면(세대가 오른다) 지금 기록의 것이 아니다" {
    var sw: Sw = .{};
    try std.testing.expect(sw.arm(5));
    try std.testing.expect(sw.rescueAddAs("K", 5, 0, true));
    const before = sw.rescue[0];
    try std.testing.expect(sw.keepCurrent(before));
    // 끔 → 켬(떠날 때의 다시 붙이기가 나는 사이).
    _ = sw.detachAll(5);
    try std.testing.expect(!sw.keepCurrent(before)); // 꺼져 있다
    try std.testing.expect(sw.arm(5));
    try std.testing.expect(!sw.keepCurrent(before)); // 새 기록(세대가 올랐다)
    // 새 기록에서 넣은 다시 붙이기는 지금의 것.
    try std.testing.expect(sw.rescueAddAs("K2", 5, 0, true));
    try std.testing.expect(sw.keepCurrent(sw.rescue[1]));
    // 탭이 닫혔다(자리가 없다)·놓을 워커만인 자리는 붙여 두기가 아니다.
    try std.testing.expect(sw.rescueAdd("R", 5, 0));
    try std.testing.expect(!sw.keepCurrent(sw.rescue[2]));
    sw.forget(5);
    try std.testing.expect(!sw.keepCurrent(before));
}

test "재검증 13 차(D-v20r-1·LOW-L1): 워커가 멈추면 그 워커를 쥔 세션을 모든 탭에서 뗄 차례로 — 산 세션·그림자·다른 탭(시한 떼기를 기다리는 세운·남의 출처 세션은 그대로), 붙여 두기는 다시 붙이지 않고 그 워커의 건지기는 지운다" {
    var sw: Sw = .{};
    for ([_]BrowserId{ 5, 6, 7 }) |b| try std.testing.expect(sw.arm(b));
    // 탭 5: 다녀간 출처의 붙여 둔 세션(켰다) + 돌아올 때 Chromium 이 다시 붙인 그림자.
    _ = sw.attachedAt(5, "L5", "TA", 10);
    _ = sw.noteOrigin("L5", 0xA, 0xA, 10);
    sw.noteEnable("L5", 7);
    try std.testing.expectEqual(Attach.shadow, sw.attachedAt(5, "G5", "TA", 20));
    // 탭 6: 같은 워커의 산 세션. 탭 7: 몫을 넘어 세운 같은 워커의 세션·남의 출처 세션(둘 다 시한 떼기를 기다린다 — 훑지 않는다). 다른 워커(TB)의
    // 세션은 그대로.
    _ = sw.attachedAt(6, "L6", "TA", 30);
    _ = sw.noteOrigin("L6", 0xA, 0xA, 30);
    try std.testing.expect(sw.park(7, "P7", "TA", 40));
    _ = sw.attachedAt(7, "F7", "TA", 45);
    try std.testing.expectEqual(Origin.foreign, sw.noteOrigin("F7", 0xA, 0xF, 45));
    _ = sw.attachedAt(5, "OB", "TB", 50);
    _ = sw.noteOrigin("OB", 0xA, 0xA, 50);
    // 그 워커의 붙여 두기 다시 붙이기와 놓기 건지기, 다른 워커의 건지기.
    try std.testing.expect(sw.rescueAddAs("TA", 5, 0, true));
    try std.testing.expect(sw.rescueAdd("TB", 5, 0));
    // 그림자 세션이 멈춤을 받았다(12 차는 아무것도 하지 않았다 — 그림자가 멈춘 호스트를 쥐어 다시 뜸이 멈추지 않았다).
    try std.testing.expectEqual(hashId("TA"), sw.stopTarget("G5"));
    var got: [8][]const u8 = undefined;
    var bufs: [8][max_sid_bytes]u8 = undefined;
    var n: usize = 0;
    while (sw.takeStopping()) |x| : (n += 1) {
        bufs[n] = x.sid;
        got[n] = bufs[n][0..x.sid_len];
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(!sw.find("F7").?.detaching);
    for ([_][]const u8{ "L5", "G5", "L6" }) |want| {
        const hit = for (got[0..n]) |g| {
            if (std.mem.eql(u8, g, want)) break true;
        } else false;
        try std.testing.expect(hit);
    }
    try std.testing.expect(sw.takeStopping() == null); // 한 번만
    // 뗄 세션의 떨어짐은 붙여 두기가 다시 붙이지 않는다(멈춘 워커에 다시 붙으면 다시 같은 호스트를 쥔다).
    try std.testing.expect(sw.keepAfterDetach("L5") == null);
    // 그 워커의 건지기는 지웠고 다른 워커의 것은 남는다.
    try std.testing.expectEqual(@as(usize, 1), sw.rescueCount());
    try std.testing.expect(sw.rescueTake("TB", 5) != null);
    // 다른 워커의 세션은 그대로, 같은 워커의 다음 세션은 다음 epoch.
    try std.testing.expect(!sw.find("OB").?.detaching);
    sw.detached("L5");
    try std.testing.expectEqual(Attach.keep, sw.attachedAt(5, "N5", "TA", 60));
    try std.testing.expectEqual(@as(u32, 1), sw.find("N5").?.epoch);
    // 산 세션 L6 이 제 멈춤을 늦게 받는다 — 이미 다룬 멈춤이라 다시 훑지 않는다(그 사이 같은 `targetId` 로 다시 뜬 워커의 새 세션 N5 를 떼지 않는다).
    try std.testing.expectEqual(@as(u64, 0), sw.stopTarget("L6"));
    try std.testing.expect(sw.takeStopping() == null);
    try std.testing.expect(!sw.find("N5").?.detaching);
    // 그 새 세션의 워커가 다시 멈추면 그때는 다룬다(다음 epoch).
    try std.testing.expectEqual(hashId("TA"), sw.stopTarget("N5"));
    var again: usize = 0;
    while (sw.takeStopping()) |x| : (again += 1) try std.testing.expect(std.mem.eql(u8, x.sid[0..x.sid_len], "N5"));
    try std.testing.expectEqual(@as(usize, 1), again);
    try std.testing.expectEqual(@as(u32, 2), sw.epochOf(hashId("TA")));
    // 표에 없는 세션은 모른다(부른 쪽이 그것만 뗀다).
    try std.testing.expectEqual(@as(u64, 0), sw.stopTarget("ZZ"));
    try std.testing.expect(sw.takeStopping() == null);
}
