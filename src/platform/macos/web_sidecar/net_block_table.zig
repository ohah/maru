//! 요청 막기의 표(W9d③ — docs/plans/web-osr-backend.md 「W9d③ 결정·실측」). CEF 를 모른다 — 시각·번호·주소 단위는 호출자가 준다(CEF SDK 없이
//! 기본 test 에서 돈다). 잠금도 없다 — `network.zig` 의 뮤텍스 하나 아래에서만 부른다(IO 스레드의 처리기 고르기와 UI 스레드가 함께 쓴다).
//!
//! - **규칙 묶음(RCU)**: maru 의 `net_block` 이 오면 UI 스레드가 패턴을 미리 풀어(`net_block.parse` — KMP 실패 표까지) 새 묶음을 만들고 잠금
//!   아래에서 탭의 포인터만 바꾼다. IO 스레드는 잠금 아래에서 포인터와 `readers` 를 잡고 **잠금 밖에서** 맞춘다(맞추기가 다른 탭의 요청을 붙잡지
//!   않게). 바뀐 옛 묶음은 은퇴 목록에 두었다가 보내는 task(`flush`)가 `readers` 0 일 때 마지막 수를 보내고 푼다.
//! - **수**: 규칙마다 원자 u32(포화 — 넘침으로 0 이 되지 않게). 보내는 task 가 보낸 뒤의 차이만 `net_block_hits` 로 모은다(maru 가 누적한다 —
//!   sidecar 가 다시 뜨면 0 부터라도 차이라 맞다).
//! - **D2 토큰**(사용자 결정 D2 「항상 통과」): maru 의 `navigate{user}` 는 그 주소(정규 꼴의 해시)에, `nav_action{user}` 는 「다음 주 프레임
//!   이동 하나 — **그 몸짓의 이동**」(1 초 — 뒤로·앞으로는 기록 이동, 새로 고침은 새로 고침 이동만 가져간다; 20 회 검증 A LOW-3: 아무 일도
//!   하지 않은 뒤로 뒤 1 초 안의 에이전트 이동이 토큰을 가져갔다)에 토큰을 건다. 에이전트·복원의 **다른 곳으로 가는** `navigate`·`nav_action`(멈춤
//!   포함), 주 프레임 주소 확정(bfcache·같은 문서 이동 — `on_before_browse` 가 없다; 친 주소와 같은 주소의 확정은 주소 토큰도), iframe 의 기록
//!   이동(사용자의 뒤로가 iframe 만 옮겼다)이 남은 토큰을 거둔다. 이동을 시작할 수 있는 에이전트의 DevTools 호출과 같은 곳(친 주소와 같은 주소·
//!   새로 고침)으로 가는 에이전트 이동은 거두지 않고 **다툼**(`contested`)으로 둔다 — 그 토큰의 창 안의 맞는 이동은 모두 사용자 것(진짜; W9d④ v1
//!   검증 SEVERE-2, 사용자 결정 2026-11-11 「고침」 — 2 차 검증 LOW-A2-3 의 거두기는 겹친 `Runtime.evaluate` 하나로 사용자의 이동을 막힘·가짜로
//!   만들었다). 떠나기 확인이 떠 있는 동안은 토큰의 시계를 멈춘다(`holdTokens` — LOW-A2-4). 토큰의 시계는 몸짓 뒤 다른 주 프레임 이동이 시작될 때
//!   돌기 시작한다 — 그 전에는 옛 문서의 beforeunload 처리기를 기다린다(`start_cap_ms` — 3 차 검증 LOW-A3-3). 수(규칙·탭 몫)는 센 때의 세대로
//!   보낸다(3 차 검증 NEW-B3-1 — `TabCounts`·`stale`). UI 스레드의 `on_before_browse`(주 프레임 — 늘 IO 의 처리기 고르기보다 먼저, 실측 J-B15 0.3 ms)가 토큰을 그
//!   이동의 주소에 묶고, IO 의 고르기가 그 이동의 첫 홉에서 소비해 **요청 번호**를 예외로 둔다 — 리다이렉트의 다음 홉(같은 번호 — J-B2)도 막지
//!   않는다. 하위 자원은 그대로 막는다. W9d④(가짜 응답)도 같은 답을 쓴다: 소비는 규칙과 무관하다(`consumeExempt` — 막기 규칙이 없는 탭에서도
//!   소비해야 가짜만 있는 탭에서 D2 가 듣는다, W9d④ §13 P2-1). 처리기 고르기가 요청마다 한 번 묻고 막기(`acquire` — 같은 번호면 같은 답)·가짜가
//!   그 답을 함께 본다. Q2 의 사람 입력 창은 `nav_exempt.zig`(가짜만).
//! - **진행 중 이동**(서비스 워커 길·§6.3): `on_before_browse`(주·하위 프레임)가 적고(탭마다 8 — 넘치면 그 탭은 「모름」), 확정·문서 시작·오류·
//!   끊김(하위 프레임의 오류·끊김·떨어져 나감도 — 3 차 검증 MED-A3-1)이 지우고, 30 초는 재지 못한 끝의 받침이다. 서비스 워커가 대신 받아 오는 이동은 그 이동의 `on_before_browse` 뒤에 온다(실측 D3(i) — 0.4–0.9 ms 먼저).
//! - **막힌 주 프레임 이동의 귀속**(§6.3): 막은 주 프레임 주소의 해시와 규칙을 적어 두면 `on_load_error` 가 실패 주소의 해시로 짝짓는다(오류
//!   번호로 가르지 않는다 — 서비스 워커 길은 -2 다, 실측 sw3).
//!
//! 시험이 증명하는 것: 묶음 바꾸기와 readers·은퇴(쥔 동안 풀지 않는다), 포화 수와 차이(은퇴 묶음의 마지막 수 포함), 맞추기의 사이트 묶기(주 프레임
//! 홉은 그 홉 호스트, 하위 자원은 페이지 호스트 — 모르면 막지 않고 센다), 종류, 첫 맞는 규칙, D2(주소 토큰·다음 이동 토큰·1 초·홉 포함·하위
//! 자원은 막힘), 진행 중 이동 표(8·30 초·넘침 → 모름), 귀속 짝. 2 차 검증의 거두기·멈춤·끊김은 `net_block_review_tests.zig` 의 `A2-*`, 3 차
//! 검증의 하위 프레임 끝·들어오는 이동의 호스트·시계 시작·묶음 끝은 `A3-*`, 수의 세대(NEW-B3-1)·켬 몫(N-B3-d)·요청마다 한 번(N-A3-2)은 여기.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const msg = protocol.message;
const nb = protocol.net_block;
const net_policy = protocol.net_policy;
const BrowserId = msg.BrowserId;

/// 탭 자리 — sidecar 의 브라우저 상한과 같다.
pub const capacity = @import("registry.zig").capacity;
/// 탭마다 기억하는 진행 중 이동 수(주·하위 프레임 — 넘치면 그 탭은 「모름」).
pub const max_pending: usize = 8;
/// 진행 중 이동을 잊는 시한(확정·오류가 오지 않은 이동 — 멈춤·다운로드).
pub const pending_ttl_ms: i64 = 30_000;
/// 하위 프레임의 진행 중 이동을 잊는 시한 — 끝(문서 시작·오류·끊김·떨어져 나감)이 놓으므로 이것은 재지 못한 끝의 받침이라 짧게(3 차 검증
/// MED-A3-1: 놓는 이가 없던 끝난 iframe 이동이 30 초 동안 그 탭을 그 출처를 「보이는」 탭으로 남겼다). 그보다 오래 걸리는 iframe 이동은 그동안
/// 그 출처의 증명이 아니다(그 프레임은 옛 주소·빈 주소로 나열된다 — 빈 주소면 「모름」).
pub const subframe_ttl_ms: i64 = 10_000;
/// `nav_action{user}` 토큰의 시한(다음 주 프레임 이동 하나) — 그 몸짓 뒤 **다른 주 프레임 이동이 시작된 때부터** 잰다(`start_cap_ms`).
pub const nav_token_ms: i64 = 1_000;
/// `navigate{user}` 토큰의 시한 — 보통 수 ms 안에 `on_before_browse` 가 온다. 넉넉히 두되 남지 않게(시계는 위와 같이 시작한다).
pub const url_token_ms: i64 = 5_000;
/// 몸짓 뒤 아무 주 프레임 이동도 시작되지 않은 동안 토큰이 기다리는 상한(3 차 검증 LOW-A3-3: Chromium 은 사용자의 이동을 시작하기 전에 옛 문서의
/// beforeunload 처리기를 끝까지 돌린다 — 대화상자 없이 2 초·6 초 도는 처리기 뒤의 새로 고침·뒤로·친 주소가 몸짓 시각부터 잰 1 초·5 초를 넘겨
/// 막혔다, 실측 4/4). 그 사이 옛 문서의 주 프레임은 처리기에 붙잡혀 제 이동을 시작하지 못한다 — 다른 주 프레임 이동이 먼저 시작되면 그때부터
/// 1 초·5 초 시계가 돈다. 이 상한을 넘게 도는 처리기 뒤의 이동은 규칙대로(문서화된 틈).
pub const start_cap_ms: i64 = 30_000;
/// 같은 요청의 리다이렉트 홉마다 「적용 안 됨」 을 세지 않게 기억하는 요청 번호 수(3 차 검증 N-A3-2).
pub const counted_requests: usize = 64;
/// 지난 세대의 탭 몫 수를 세대째로 쥐는 자리(3 차 검증 NEW-B3-1 — 보내기 전에 세대가 바뀐 수).
pub const max_stale: usize = 4;
/// 탭마다 기억하는 오류 페이지 하위 프레임 수 — 나열이 탭마다 보는 프레임 상한(`sw_share.max_frames`, 넘으면 그 탭은 「모름」)과 같다. 자리가
/// 모자라면(떠난 프레임의 열쇠가 남아 찬 꼴) 잊지 않고 그 탭을 「오류 페이지를 다 알지 못함」(`Tab.err_unsure`)으로 둔다 — 그 탭의 하위 프레임은
/// 「보일지도」 로 나열되고(`ErrSnapshot.view`) 서비스 워커 길은 그것을 막는 쪽으로만 쓴다(`sw_share.role`). 5 차 검증 MED: 전에는 8 자리가 넘치면
/// 가장 오래된 것을 덮어 그 프레임이 실패 주소의 출처를 「보인다」 로 나열됐다 — 주석은 「보수 쪽」 이라 했지만 그 탭이 맞는 규칙을 쥐면 아무 탭도
/// 보이지 않는 출처의 요청을 막고(넘침), 쥐지 않으면 거부권으로 그 출처를 정말 보이는 다른 탭의 규칙을 「적용 안 됨」 으로 만들었다(샘 — 실측 n=9·12).
pub const max_err_frames: usize = @import("sw_share.zig").max_frames;
/// 탭마다 기억하는, 막기 규칙이 막은 하위 프레임 이동 수(그 막힘이 끝나면 지운다 — 함께 막혀 끝을 기다리는 iframe 수만큼). 자리가 없으면 그 표시를
/// 잃는 대신 `err_unsure`(위와 같은 까닭 — 표시를 잃은 막힘의 오류 페이지가 「보인다」 로 나열되지 않게).
pub const max_blocked_sub: usize = 64;

/// 막기 규칙이 막은 하위 프레임 이동 하나 — 주소(정규 꼴 해시)와 그 이동의 프레임 열쇠(진행 중 기록에서 — 모르면 0).
pub const BlockedSub = struct { url: u64 = 0, frame: u64 = 0 };
/// 떠나기 확인이 토큰의 시계를 멈추는 상한(2 차 검증 LOW-A2-4) — 더 오래 떠 있다 답하면 토큰을 거둔다(그 이동은 규칙대로).
pub const hold_max_ms: i64 = 10 * 60_000;

/// 규칙 하나(미리 푼 패턴과 수).
pub const Rule = struct {
    id: u32 = 0,
    types: u32 = 0,
    site_buf: [msg.max_net_host_bytes]u8 = undefined,
    site_len: u8 = 0,
    pattern: nb.Pattern = .{},
    hits: std.atomic.Value(u32) = .init(0),
    sw_hits: std.atomic.Value(u32) = .init(0),
    sw_not_applied: std.atomic.Value(u32) = .init(0),
    /// 보낸 수(UI 스레드만).
    sent_hits: u32 = 0,
    sent_sw_hits: u32 = 0,
    sent_sw_not_applied: u32 = 0,

    pub fn site(self: *const Rule) []const u8 {
        return self.site_buf[0..self.site_len];
    }
};

/// 규칙 밖의 탭 몫 수(문 넘김·모르는 페이지·나눔 표시·엄격의 리다이렉트 어긋남) — 센 때의 세대로 보낸다(3 차 검증 NEW-B3-1: 보낼 때의 세대를 싣자
/// 탭을 비우기 직전에 센 수가 빈 세대를 달고 가 maru 가 받았다 — 다음 pane 의 결과에 보였다).
pub const TabCounts = struct {
    unrecorded: u32 = 0,
    skipped_unknown_page: u32 = 0,
    sw_shared: bool = false,
    strict_redirect_missed: u32 = 0,
    strict_redirect_bypassed: u32 = 0,

    pub fn any(self: *const TabCounts) bool {
        return self.unrecorded > 0 or self.skipped_unknown_page > 0 or self.sw_shared or self.strict_redirect_missed > 0 or self.strict_redirect_bypassed > 0;
    }

    fn merge(self: *TabCounts, o: TabCounts) void {
        self.unrecorded +|= o.unrecorded;
        self.skipped_unknown_page +|= o.skipped_unknown_page;
        self.sw_shared = self.sw_shared or o.sw_shared;
        self.strict_redirect_missed +|= o.strict_redirect_missed;
        self.strict_redirect_bypassed +|= o.strict_redirect_bypassed;
    }
};

/// 지난 세대의 탭 몫 수.
pub const Stale = struct { generation: u32 = 0, counts: TabCounts = .{} };

/// 세대 a 가 b 보다 앞인가(u32 가 돌아도 — maru 의 세대는 0 을 건너뛰며 돈다; 3 차 검증 N-A3-4).
pub fn genBefore(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}

/// 원자 수를 하나 올린다 — 포화(u32 최대에서 멈춘다). 어느 스레드에서나.
pub fn bump(v: *std.atomic.Value(u32)) void {
    var cur = v.load(.monotonic);
    while (cur != std.math.maxInt(u32)) {
        cur = v.cmpxchgWeak(cur, cur + 1, .monotonic, .monotonic) orelse return;
    }
}

/// 한 탭의 규칙 묶음 — 바뀌지 않는다(수만 원자로 오른다). `readers`·`retired` 는 잠금 아래.
pub const RuleSet = struct {
    browser: BrowserId,
    generation: u32,
    count: u8 = 0,
    rules: [nb.max_rules]Rule = undefined,
    /// 종류를 달지 않은 규칙이 있다(서비스 워커 길은 그것만 본다 — §12 P1-7).
    any_untyped: bool = false,
    readers: u32 = 0,

    pub fn slice(self: *RuleSet) []Rule {
        return self.rules[0..self.count];
    }
};

/// `net_block` 의 규칙을 미리 풀어 새 묶음을 만든다(UI 스레드 — 잠금 밖). 규칙이 없으면 null(엄격 모드만일 수 있다). codec 이 패턴을 이미
/// 봤다 — 그래도 풀리지 않는 규칙은 빼고 거짓을 함께 돌려준다.
pub fn compile(gpa: std.mem.Allocator, v: msg.NetBlock) error{OutOfMemory}!struct { set: ?*RuleSet, ok: bool } {
    if (v.count == 0) return .{ .set = null, .ok = true };
    const set = try gpa.create(RuleSet);
    set.* = .{ .browser = v.browser, .generation = v.generation };
    var ok = true;
    for (v.rules[0..v.count]) |r| {
        const p = switch (nb.parse(r.pattern)) {
            .ok => |p| p,
            .err => {
                ok = false;
                continue;
            },
        };
        const dst = &set.rules[set.count];
        dst.* = .{ .id = r.id, .types = r.types, .pattern = p };
        const n = @min(r.site.len, dst.site_buf.len);
        @memcpy(dst.site_buf[0..n], r.site[0..n]);
        dst.site_len = @intCast(n);
        if (r.types == 0) set.any_untyped = true;
        set.count += 1;
    }
    return .{ .set = set, .ok = ok };
}

// ── 주소의 정규 꼴 해시(D2·§6.3) ────────────────────────────────────────────────────────────────────────

/// 주소의 정규 꼴 해시 — maru 가 보낸 글(u8 — 사용자가 친 주소)과 CEF 의 GURL 꼴(u16)이 같은 이동이면 같은 값이 되게, 양쪽에 Chromium 의
/// 정규화를 흉내 낸 `url_canon.hash` 를 쓴다(스킴·호스트 소문자, 끝 점·기본 포트 뗌, IP 꼴, 빈 경로는 `/`, `\` 는 `/`, 점 조각 풀기, GURL 이 `%XX`
/// 로 바꾸는 글자, 사용자 정보·조각 뗌 — 20 회 검증 A LOW-4: 전에는 빈칸·`..`·`"`·`\`·`a.test?q`·`127.1` 을 친 사용자의 이동이 D2 예외를 잃고
/// 막혔다). http(s) 가 아니면 단위 그대로. 남은 틈(문서화): 국제화 호스트(punycode), 4 KiB 넘는 경로의 점 조각.
pub fn canonHash(comptime T: type, url: []const T) u64 {
    if (protocol.url_canon.hash(T, 0x9d3, url)) |v| return v;
    var h = std.hash.Wyhash.init(0x9d3);
    for (url) |u| h.update(std.mem.asBytes(&@as(u16, u)));
    return h.final();
}

/// 출처 글(`scheme://host[:port]`)의 해시(소문자) — 서비스 워커 길의 출처 비교와 캐시 열쇠.
pub fn originHash(origin: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x0919);
    for (origin) |ch| h.update(&.{std.ascii.toLower(ch)});
    return h.final();
}

/// 주소(단위)의 출처 해시 — `originHash(net_policy.originOf(url))` 와 같은 값(http(s) 만 — 아니면 0).
pub fn urlOriginHash(comptime T: type, url: []const T) u64 {
    const parts = nb.splitUrl(T, url) orelse return 0;
    var h = std.hash.Wyhash.init(0x0919);
    h.update(if (parts.scheme == .https) "https://" else "http://");
    for (parts.host) |u| {
        if (u > 0x7f) return 0; // GURL 은 ASCII 호스트다 — 모르는 꼴
        h.update(&.{std.ascii.toLower(@intCast(u))});
    }
    const default: u16 = if (parts.scheme == .https) 443 else 80;
    if (parts.port != default) {
        var pb: [8]u8 = undefined;
        h.update(std.fmt.bufPrint(&pb, ":{d}", .{parts.port}) catch unreachable);
    }
    return h.final();
}

/// 주소(단위)의 호스트를 u8 로(소문자, ASCII 만 — 아니면 빈 글).
pub fn urlHost(comptime T: type, url: []const T, out: *[msg.max_net_host_bytes]u8) []const u8 {
    const parts = nb.splitUrl(T, url) orelse return out[0..0];
    if (parts.host.len > out.len) return out[0..0];
    for (parts.host, 0..) |u, i| {
        if (u > 0x7f) return out[0..0];
        out[i] = std.ascii.toLower(@intCast(u));
    }
    return out[0..parts.host.len];
}

// ── 탭 ──────────────────────────────────────────────────────────────────────────────────────────────────

/// 주 프레임 이동의 갈래(CEF 전이 종류 — `on_before_browse` 의 요청). D2 의 `nav_action` 토큰은 같은 갈래의 이동만 가져간다.
pub const NavKind = enum(u8) {
    other,
    /// 뒤로·앞으로(`TT_FORWARD_BACK_FLAG`).
    history,
    /// 새로 고침(`TT_RELOAD`).
    reload,

    /// CEF `cef_transition_type_t` 값에서.
    pub fn fromTransition(t: u32) NavKind {
        if (t & 0x0100_0000 != 0) return .history;
        if (t & 0xff == 8) return .reload;
        return .other;
    }
};

/// 기록의 지금 항목(`blocking.historyAt` — CEF `get_navigation_entries` 의 current 는 진행 중인 기록 이동이 있으면 그 대상 항목이다).
pub const HistoryAt = struct {
    index: usize,
    /// 지금 항목의 주 프레임 주소(정규 꼴 해시).
    url: u64,
    /// 그 방향(뒤로 -1·앞으로 +1)의 바로 옆 항목 주소 — 없거나 읽지 못하면 null.
    step_url: ?u64 = null,
};

/// 사용자의 뒤로·앞으로에 건 기록 토큰을 남길까. 토큰은 몸짓 앞에 걸고, 그 기록 이동을 **시작한 뒤** 다시 읽은 지금 항목(`after` — 진행 중 항목)이
/// Chromium 이 고른 실제 대상이다: 몸짓 없이 생긴 항목(기록 조작 개입 — 같은 주소 pushState 등)을 건너뛴 그 대상의 주 프레임 주소가 앞 항목
/// (`before`)과 같으면 iframe 만·같은 주소의 같은 문서로 가는 것이라 주 프레임 이동이 없다 — 거둔다(3 차 검증 LOW-A3-4 그대로). 다르면 남긴다
/// (4 차 검증 A-LOW: 바로 옆 항목만 보아, 건너뛰는 같은 주소 항목 너머 다른 문서로 가는 사용자의 뒤로가 예외를 잃고 막혔다). 지금 항목이 그대로면
/// (이동이 미뤄졌다 — 진행 중 항목이 없다) 바로 옆 항목으로 본다(전의 판정). 읽지 못하면 남긴다.
pub fn historyTokenStays(before: ?HistoryAt, after: ?HistoryAt) bool {
    const b = before orelse return true;
    const a = after orelse return true;
    if (a.index != b.index) return a.url != b.url;
    const next = b.step_url orelse return true;
    return next != b.url;
}

/// 진행 중 이동 하나(`on_before_browse` — 주·하위 프레임).
pub const Pending = struct {
    frame: u64 = 0,
    main: bool = false,
    origin: u64 = 0,
    url: u64 = 0,
    at_ms: i64 = 0,
    /// D2 토큰이 걸린 사용자 이동이다(주 프레임만).
    user: bool = false,
    host_buf: [msg.max_net_host_bytes]u8 = undefined,
    host_len: u8 = 0,

    pub fn host(self: *const Pending) []const u8 {
        return self.host_buf[0..self.host_len];
    }
};

/// 나열(`blocking.enumerate`)이 본 프레임 하나의 출처 O 에 대한 몫.
pub const FrameView = enum {
    /// O 의 문서가 아니다(다른 출처·오류 페이지).
    other,
    /// O 를 보인다.
    shows,
    /// O 의 주소지만 잊힌 오류 페이지일 수 있다(`Tab.err_unsure` 인 탭의 하위 프레임 — 5 차 검증 MED).
    maybe,
};

/// 나열이 탭마다 잠금 아래에서 베끼는 오류 페이지 사실(`Tab.errSnapshot`).
pub const ErrSnapshot = struct {
    frames: [max_err_frames]u64 = @splat(0),
    unsure: bool = false,

    /// 그 하위 프레임에 오류 페이지 표시가 있다(나열이 건너뛴다).
    pub fn isErr(self: *const ErrSnapshot, key: u64) bool {
        return key != 0 and std.mem.indexOfScalar(u64, &self.frames, key) != null;
    }

    /// 오류 페이지 표시가 없는 프레임 하나의 몫 — `same_origin` 은 그 프레임 주소의 출처가 O 인가. 표시를 다 적지 못한 탭(`unsure`)의 하위 프레임은
    /// 잊힌 오류 페이지일 수 있어 「보일지도」(주 프레임은 표시와 무관하다 — 그 문서의 주소다).
    pub fn view(self: *const ErrSnapshot, main: bool, same_origin: bool) FrameView {
        if (!same_origin) return .other;
        if (!main and self.unsure) return .maybe;
        return .shows;
    }
};

pub const Tab = struct {
    browser: BrowserId = 0,
    cef_id: c_int = 0,
    used: bool = false,
    set: ?*RuleSet = null,
    /// 엄격 모드가 묶인 사이트(빈 = 끔).
    strict_site_buf: [msg.max_net_host_bytes]u8 = undefined,
    strict_site_len: u8 = 0,
    /// W9d④: 가짜의 엄격 모드가 묶인 사이트(빈 = 끔) — 엄격의 CDP(Network 도메인)는 하나라 막기의 것과 함께 본다(`strictCovers`).
    mock_strict_buf: [msg.max_net_host_bytes]u8 = undefined,
    mock_strict_len: u8 = 0,
    /// 확정된 맨 위 문서 호스트(`on_address_change` — 막힌 주 프레임 이동은 주소를 바꾸지 않는다, 실측 J-B4). 비면 모른다.
    top_buf: [msg.max_net_host_bytes]u8 = undefined,
    top_len: u8 = 0,
    /// 마지막으로 적용한 `net_block` 의 세대(수와 함께 보낸다 — maru 는 모두 버린 세대보다 앞선 수를 버린다, 20 회 검증 B N4).
    generation: u32 = 0,
    /// 설정 `browser.agent-network-full`(그 탭의 `net_watch` — 3 차 검증 N-B3-d): 거짓이면 켜졌을 때만 보이는 수(서비스 워커 길·나눔 표시·다른
    /// 사이트 리다이렉트)를 **세지 않는다**(W9d① 처럼 원천에서 — maru 가 받을 때만 거르면 끈 동안 센 수가 켠 직후 보내져 적혔다). 보낼 때도 본다.
    full: bool = false,
    /// 보낼 탭 몫 수(잠금 아래) — 지금 세대(`generation`)의 것. 엄격 모드의 리다이렉트 어긋남(20 회 검증 A MED-1 — `blocking.zig` 가 문서
    /// 확정 때 센다): 엄격 사이트로 들어왔는데 서비스 워커가 다스림, 엄격 사이트에서 나갔는데 우회됨.
    counts: TabCounts = .{},
    /// 보내기 전에 세대가 바뀐 수(그 세대째로 보낸다 — NEW-B3-1). 묶음을 바꿀 때 옮기고, 옛 묶음을 쥔 IO 요청이 바뀐 뒤 놓은 수도 여기로.
    stale: [max_stale]Stale = @splat(.{}),
    stale_len: u8 = 0,
    // D2. 토큰마다 시한과 「시계가 돌기 시작했다」(몸짓 뒤 다른 주 프레임 이동이 시작됐다 — `start_cap_ms`).
    url_token: u64 = 0,
    url_token_until: i64 = 0,
    url_token_started: bool = false,
    nav_token_until: i64 = 0,
    nav_token_started: bool = false,
    /// `nav_action` 토큰이 기다리는 이동의 갈래(뒤로·앞으로 = `history`, 새로 고침 = `reload`).
    nav_token_kind: NavKind = .other,
    /// 다툼(W9d④ v1 검증 SEVERE-2 — 사용자 결정 2026-11-11 「고침」): 사용자 토큰이 산 동안 에이전트가 이동을 시작할 수 있는 DevTools 호출을 했거나
    /// 같은 곳(친 주소와 같은 주소·새로 고침)으로 몰았다 — 다음 주 프레임 이동이 누구의 것인지 가를 수 없다. 거두지 않고(거두면 사용자가 친 주소·
    /// 새로 고침이 에이전트의 `Runtime.evaluate` 하나로 가짜·막힘이 됐다) 그 토큰의 창 안에서 맞는 이동을 **모두** 사용자 것으로 본다(진짜 —
    /// fail-safe; 에이전트의 그 이동도 진짜가 될 수 있다). 토큰이 끝나면(새 문서·시한·거둠) 풀린다.
    contested: bool = false,
    /// 가는 중인 사용자의 주 프레임 이동(토큰을 쓴 이동 — 주소 해시·시한·새로 고침인가). 그 문서가 서거나 끊기거나 다른 곳으로 가는 이동이 대신하면
    /// 지운다. 다툼의 판정만 쓴다(토큰을 다 쓴 뒤 — 묶음도 첫 홉이 썼다 — 겹친 같은 주소의 에이전트 이동도 사용자 것으로 보려고, v1 SEVERE-2 실측:
    /// 느린 서버로 가는 사용자 이동 중 에이전트 eval 의 `location.href` 같은 주소가 가짜였다).
    user_nav_url: u64 = 0,
    user_nav_until: i64 = 0,
    user_nav_reload: bool = false,
    /// 떠나기 확인이 떠 있다 — 그 시각과 대화상자 번호(`holdTokens` — 토큰의 시계가 멈춘다).
    hold_at: ?i64 = null,
    hold_request: u32 = 0,
    /// `on_before_browse` 가 토큰을 묶은 이동 주소(정규 꼴 해시) — IO 의 고르기가 첫 홉에서 소비한다.
    bound_url: u64 = 0,
    bound_until: i64 = 0,
    /// 예외로 둔 요청 번호(그 이동의 모든 홉).
    exempt_request: u64 = 0,
    // 진행 중 이동.
    pending: [max_pending]Pending = undefined,
    pending_len: u8 = 0,
    /// 표가 넘쳐 잊은 이동이 있다 — 그 시각부터 `pending_ttl_ms` 동안 이 탭은 「모름」.
    overflow_until: i64 = 0,
    /// 막은 주 프레임 이동(§6.3 — 실패 주소의 해시와 규칙).
    last_main_block_url: u64 = 0,
    last_main_block_rule: u32 = 0,
    /// 오류 페이지를 보이는 하위 프레임(프레임 열쇠) — Chromium 은 그 프레임의 주소를 실패한 주소로 두지만 문서는 그 출처의 것이 아니다(불투명
    /// 출처 — 그 출처의 서비스 워커를 쓰지 않는다). 나열(`blocking.enumerate`)이 그 프레임을 「보인다」 로 세지 않게(3 차 검증 MED-A3-1: 빈 응답·
    /// 막힌 iframe 의 오류 페이지가 그 탭을 그 출처를 보이는 탭으로 남겼다).
    err_frames: [max_err_frames]u64 = @splat(0),
    /// 오류 페이지 표시나 막은 하위 프레임 표시의 자리가 모자라 하나를 적지 못했다(5 차 검증 MED) — 이 탭의 하위 프레임 어느 것이 오류 페이지인지
    /// 다 알지 못한다. 주 프레임의 새 문서가 지운다(옛 하위 프레임이 모두 사라졌다).
    err_unsure: bool = false,
    /// 막기 규칙이 막은 하위 프레임 이동의 주소(정규 꼴 해시) — 그 주소로 서는 문서는 오류 페이지다. 실측(CEF 154)으로는 -20 의 하위 프레임이 같은
    /// 프레임 번호의 `on_load_error` 로 끝났다(그 갈래가 오류 표시를 적는다) — 이것은 `on_load_error` 없이 `on_load_start` 로 서는 갈래의 방어다.
    /// 그 막힘이 끝나면 지운다(4 차 검증 A-MED: 주 프레임 새 문서까지 남아, 규칙을 뺀 뒤 같은 주소로 정말 선 iframe 을 오류 페이지로 쳐 그 탭이 그
    /// 출처를 보이는데도 T(O) 에서 빠졌다 — 그 출처의 서비스 워커 요청이 막혀야 할 때 지나갔다): 그 막힘의 끝(`subframeEnded` — 오류·끊김),
    /// 규칙 바꾸기(`swap` — 표시는 그 규칙의 막힘이다), 그 프레임의 새 이동(`beforeBrowse` — 그 이동은 다시 판정된다)·떨어져 나감(`subframeGone`).
    /// 표시는 프레임마다다(5 차 검증 NIT: 주소로 모두 지워, 같은 주소로 막힌 다른 프레임의 표시까지 사라졌다) — 끝·문서 시작은 그 프레임·주소의 것
    /// (없으면 그 주소의 것 하나 — 사이트가 다른 iframe 은 열쇠가 바뀐다)을 하나 꺼내고, 새 이동·떨어져 나감은 그 프레임의 것만 지운다.
    blocked_sub: [max_blocked_sub]BlockedSub = @splat(.{}),

    pub fn strictSite(self: *const Tab) []const u8 {
        return self.strict_site_buf[0..self.strict_site_len];
    }

    pub fn mockStrictSite(self: *const Tab) []const u8 {
        return self.mock_strict_buf[0..self.mock_strict_len];
    }

    /// W9d④: 막기나 가짜의 엄격이 켜져 있다.
    pub fn anyStrict(self: *const Tab) bool {
        return self.strict_site_len != 0 or self.mock_strict_len != 0;
    }

    /// W9d④: 그 호스트를 막기 엄격 사이트나 가짜 엄격 사이트가 덮는다(엄격의 원하는 값 — W9d④ 계획 §8).
    pub fn strictCovers(self: *const Tab, host: []const u8) bool {
        if (host.len == 0) return false;
        if (self.strict_site_len != 0 and net_policy.hostCovers(self.strictSite(), host)) return true;
        return self.mock_strict_len != 0 and net_policy.hostCovers(self.mockStrictSite(), host);
    }

    pub fn setMockStrict(self: *Tab, site: []const u8) void {
        const n = @min(site.len, self.mock_strict_buf.len);
        @memcpy(self.mock_strict_buf[0..n], site[0..n]);
        self.mock_strict_len = @intCast(n);
    }

    pub fn topHost(self: *const Tab) []const u8 {
        return self.top_buf[0..self.top_len];
    }

    pub fn expire(self: *Tab, now_ms: i64) void {
        var i: usize = 0;
        while (i < self.pending_len) {
            if (now_ms - self.pending[i].at_ms > (if (self.pending[i].main) pending_ttl_ms else subframe_ttl_ms)) {
                self.pending[i] = self.pending[self.pending_len - 1];
                self.pending_len -= 1;
            } else i += 1;
        }
    }

    /// 진행 중인 주 프레임 이동(가장 최근 것).
    pub fn pendingMain(self: *const Tab) ?*const Pending {
        var best: ?*const Pending = null;
        for (self.pending[0..self.pending_len]) |*p| if (p.main and (best == null or p.at_ms >= best.?.at_ms)) {
            best = p;
        };
        return best;
    }

    /// 진행 중 이동 표가 넘쳤다(그 동안 「모름」).
    pub fn unknownPending(self: *const Tab, now_ms: i64) bool {
        return now_ms < self.overflow_until;
    }

    /// 그 하위 프레임이 오류 페이지를 보인다.
    pub fn isErrFrame(self: *const Tab, key: u64) bool {
        return key != 0 and std.mem.indexOfScalar(u64, &self.err_frames, key) != null;
    }

    /// 나열이 베낄 오류 페이지 사실(잠금 아래).
    pub fn errSnapshot(self: *const Tab) ErrSnapshot {
        return .{ .frames = self.err_frames, .unsure = self.err_unsure };
    }

    /// 오류 페이지 표시를 적는다 — 빈 자리가 없으면 덮지 않고 `err_unsure`(5 차 검증 MED).
    fn addErrFrame(self: *Tab, key: u64) void {
        if (key == 0 or self.isErrFrame(key)) return;
        for (&self.err_frames) |*k| if (k.* == 0) {
            k.* = key;
            return;
        };
        self.err_unsure = true;
    }

    /// 막기 규칙이 하위 프레임 이동을 막았다 — 그 주소와 프레임(진행 중 기록에서)을 적고 그 기록을 놓는다(그 이동은 여기서 끝났다 — 오류 페이지의
    /// 시작이 그 주소를 싣지 않을 수 있다).
    fn markBlockedSub(self: *Tab, url_canon: u64) void {
        var frame: u64 = 0;
        for (self.pending[0..self.pending_len]) |p| if (!p.main and p.url == url_canon) {
            frame = p.frame;
            break;
        };
        self.releaseSubframe(0, url_canon);
        for (&self.blocked_sub) |*b| if (b.url == 0) {
            b.* = .{ .url = url_canon, .frame = frame };
            return;
        };
        self.err_unsure = true; // 자리가 없다 — 이 막힘의 오류 페이지를 알아보지 못할 수 있다(5 차 검증 MED)
    }

    /// 그 프레임의 막은 하위 프레임 표시를 지운다(그 프레임의 새 이동·떨어져 나감 — 그 막힘은 끝났다). 프레임을 모르고 적힌 표시(0)만 주소로 —
    /// 같은 주소로 막힌 **다른** 프레임의 표시는 남긴다(5 차 검증 NIT: 주소로 모두 지웠다).
    fn dropBlockedSubOf(self: *Tab, frame: u64, url_canon: u64) void {
        for (&self.blocked_sub) |*b| if (b.url != 0 and ((frame != 0 and b.frame == frame) or (b.frame == 0 and url_canon != 0 and b.url == url_canon))) {
            b.* = .{};
        };
    }

    /// 그 막힘의 끝·그 주소의 문서 시작 — 표시 하나를 꺼내 참: 그 프레임·주소의 것, 없으면 그 주소의 것 하나(사이트가 다른 iframe 은 끝·문서 시작의
    /// 프레임 열쇠가 막을 때와 다르다 — 실측 CEF 154; 같은 주소로 막힌 다른 프레임의 표시는 남는다 — 5 차 검증 NIT).
    fn takeBlockedSub(self: *Tab, frame: u64, url_canon: u64) bool {
        if (url_canon == 0) return false;
        if (frame != 0) for (&self.blocked_sub) |*b| if (b.url == url_canon and b.frame == frame) {
            b.* = .{};
            return true;
        };
        for (&self.blocked_sub) |*b| if (b.url == url_canon) {
            b.* = .{};
            return true;
        };
        return false;
    }

    fn removeErrFrame(self: *Tab, key: u64) void {
        for (&self.err_frames) |*k| if (k.* == key) {
            k.* = 0;
        };
    }

    /// 하위 프레임의 진행 중 기록 하나를 놓는다 — 그 프레임 열쇠로, 없으면 그 주소로(사이트가 다른 iframe 은 새 렌더 프레임에 문서가 서 열쇠가
    /// 바뀐다 — 실측 CEF 154: `on_before_browse` 와 `on_load_start`·`on_load_error` 의 프레임 번호가 다르다).
    fn releaseSubframe(self: *Tab, key: u64, url_canon: u64) void {
        var i: usize = 0;
        var by_key = false;
        while (i < self.pending_len) {
            const p = &self.pending[i];
            if (!p.main and key != 0 and p.frame == key) {
                self.pending[i] = self.pending[self.pending_len - 1];
                self.pending_len -= 1;
                by_key = true;
            } else i += 1;
        }
        if (by_key or url_canon == 0) return;
        for (self.pending[0..self.pending_len], 0..) |p, j| if (!p.main and p.url == url_canon) {
            self.pending[j] = self.pending[self.pending_len - 1];
            self.pending_len -= 1;
            return;
        };
    }

    /// 그 세대에 센 탭 몫 수의 자리(지금 세대면 `counts`, 아니면 지난 세대의 자리 — 없으면 만들고, 자리가 차면 가장 앞선 세대의 자리에 합쳐
    /// 그 앞선 세대로 보낸다: maru 의 바닥이 버리는 쪽으로 — 다음 pane 에 옛 수가 보이는 것보다 수 하나를 잃는 편이 낫다).
    pub fn countsFor(self: *Tab, generation: u32) *TabCounts {
        if (generation == self.generation) return &self.counts;
        return self.staleFor(generation);
    }

    /// 지난 세대의 자리(`countsFor` 의 그 갈래 — 묶음을 바꾸는 `swap` 은 지금 세대의 수를 이리로 옮긴다).
    fn staleFor(self: *Tab, generation: u32) *TabCounts {
        for (self.stale[0..self.stale_len]) |*st| if (st.generation == generation) return &st.counts;
        if (self.stale_len < max_stale) {
            self.stale[self.stale_len] = .{ .generation = generation };
            self.stale_len += 1;
            return &self.stale[self.stale_len - 1].counts;
        }
        var oldest: usize = 0;
        for (self.stale[0..self.stale_len], 0..) |st, i| if (genBefore(st.generation, self.stale[oldest].generation)) {
            oldest = i;
        };
        if (genBefore(generation, self.stale[oldest].generation)) self.stale[oldest].generation = generation;
        return &self.stale[oldest].counts;
    }

    /// 탭 몫 수를 모두 버린다(지켜보기가 꺼졌다 — maru 는 이미 지웠다).
    fn dropCounts(self: *Tab) void {
        self.counts = .{};
        self.stale_len = 0;
    }

    /// 사용자 토큰을 모두 거둔다(에이전트의 다른 곳으로 가는 이동·멈춤 — 그 몸짓의 이동은 오지 않는다).
    fn dropTokens(self: *Tab) void {
        self.url_token = 0;
        self.nav_token_until = 0;
        self.bound_url = 0;
        self.hold_at = null;
        self.contested = false;
        self.user_nav_url = 0;
    }

    /// 산 사용자 토큰이 있다(주소·다음 이동 — 묶인 이동·가는 중인 사용자 이동 포함).
    fn tokensAlive(self: *const Tab, now_ms: i64) bool {
        return (self.url_token != 0 and now_ms < self.url_token_until) or now_ms < self.nav_token_until or (self.bound_url != 0 and now_ms < self.bound_until) or self.userNavLive(now_ms);
    }

    /// 사용자의 주 프레임 이동이 가는 중이다(문서가 아직 서지 않았다).
    fn userNavLive(self: *const Tab, now_ms: i64) bool {
        return self.user_nav_url != 0 and now_ms < self.user_nav_until;
    }

    /// 몸짓의 것이 아닌 주 프레임 이동이 시작됐다 — 아직 시계가 돌지 않은 토큰은 지금부터 잰다(LOW-A3-3: 그 몸짓의 이동이 처리기에 붙잡혀
    /// 있지 않다는 표지 — 페이지·다른 것의 이동이 끼어들 수 있는 동안은 짧게).
    fn startClocks(self: *Tab, now_ms: i64) void {
        if (self.url_token != 0 and !self.url_token_started) {
            self.url_token_started = true;
            self.url_token_until = @min(self.url_token_until, now_ms + url_token_ms);
        }
        if (now_ms < self.nav_token_until and !self.nav_token_started) {
            self.nav_token_started = true;
            self.nav_token_until = @min(self.nav_token_until, now_ms + nav_token_ms);
        }
    }
};

/// 처리기 고르기의 답(IO 스레드).
pub const Verdict = union(enum) {
    /// 막지 않는다(규칙이 맞지 않거나 규칙이 없다).
    pass,
    /// 그 규칙으로 막는다.
    block: u32,
    /// D2 — 사용자 이동이라 막지 않는다.
    user_exempt,
    /// 페이지(맨 위 문서)를 몰라 막지 않았다(센다).
    unknown_page,
};

pub const Table = struct {
    tabs: [capacity]Tab = @splat(.{}),
    /// 규칙이 있는 탭 수 — 0 이면 처리기 고르기가 아무것도 보지 않는다(가장 흔한 길).
    with_rules: usize = 0,
    /// 「적용 안 됨」 을 이미 센 서비스 워커 요청 번호(리다이렉트 홉마다 세지 않게 — 3 차 검증 N-A3-2: 한 요청 302 → 둘째 홉이 +2).
    sw_counted: [counted_requests]u64 = @splat(0),
    sw_counted_next: usize = 0,
    /// 바뀌어 은퇴한 묶음(readers 0 이 되면 마지막 수를 보내고 푼다 — UI 스레드).
    retired: std.ArrayList(*RuleSet) = .empty,

    pub fn find(self: *Table, browser: BrowserId) ?*Tab {
        for (&self.tabs) |*t| if (t.used and t.browser == browser) return t;
        return null;
    }

    pub fn findCef(self: *Table, cef_id: c_int) ?*Tab {
        for (&self.tabs) |*t| if (t.used and t.cef_id == cef_id) return t;
        return null;
    }

    /// 탭 자리(CEF 번호로 — 없으면 만든다). 목록 밖 브라우저(입양 전 팝업)는 `browser` 0 으로 둔다 — 진행 중 이동만 적는다(규칙이 없다). 자리가
    /// 없으면 null.
    pub fn ensure(self: *Table, browser: BrowserId, cef_id: c_int) ?*Tab {
        if (self.findCef(cef_id)) |t| {
            if (browser != 0) t.browser = browser;
            return t;
        }
        for (&self.tabs) |*t| if (!t.used) {
            t.* = .{ .used = true, .browser = browser, .cef_id = cef_id };
            return t;
        };
        return null;
    }

    /// 탭의 묶음과 엄격 사이트를 바꾼다(잠금 아래 — 묶음은 잠금 밖에서 만들었다). 옛 묶음은 은퇴 목록으로. 세대가 바뀌면 아직 보내지 않은
    /// 탭 몫 수는 옛 세대의 자리로 옮긴다(NEW-B3-1 — 그 세대째로 보낸다).
    pub fn swap(self: *Table, gpa: std.mem.Allocator, t: *Tab, set: ?*RuleSet, strict_site: []const u8, generation: u32) error{OutOfMemory}!void {
        if (generation != t.generation) {
            if (t.counts.any()) {
                const old = t.counts;
                t.counts = .{};
                t.staleFor(t.generation).merge(old);
            }
            t.generation = generation;
        }
        if (t.set) |old| {
            try self.retired.append(gpa, old);
            self.with_rules -= 1;
        }
        // 막은 하위 프레임 표시는 바뀌기 전 규칙의 막힘이다 — 새 규칙 아래의 같은 주소는 다시 판정된다(4 차 검증 A-MED).
        t.blocked_sub = @splat(.{});
        t.set = set;
        if (set != null) self.with_rules += 1;
        const n = @min(strict_site.len, t.strict_site_buf.len);
        @memcpy(t.strict_site_buf[0..n], strict_site[0..n]);
        t.strict_site_len = @intCast(n);
    }

    /// 탭을 잊는다(브라우저 닫힘 — 규칙·엄격·진행 중 표 모두). 묶음은 은퇴 목록으로.
    pub fn forget(self: *Table, gpa: std.mem.Allocator, cef_id: c_int) error{OutOfMemory}!void {
        const t = self.findCef(cef_id) orelse return;
        try self.swap(gpa, t, null, "", 0);
        t.* = .{};
    }

    /// 탭의 규칙만 버린다(지켜보기가 꺼졌다 — 진행 중 표·주소는 남긴다: 서비스 워커 길의 다른 탭 판정에 쓴다). 아직 보내지 않은 탭의 수도
    /// 버린다(maru 는 이미 모두 지웠다 — 20 회 검증 B N4).
    pub fn dropRules(self: *Table, gpa: std.mem.Allocator, browser: BrowserId) error{OutOfMemory}!void {
        const t = self.find(browser) orelse return;
        try self.swap(gpa, t, null, "", t.generation);
        t.dropCounts();
    }

    /// 설정 `browser.agent-network-full` 이 바뀌었다(`net_watch`) — 끄면 아직 보내지 않은 켬 몫의 수도 버린다(N-B3-d).
    pub fn setFull(self: *Table, browser: BrowserId, cef_id: c_int, full: bool) void {
        const t = self.ensure(browser, cef_id) orelse return;
        t.full = full;
        if (full) return;
        t.counts.sw_shared = false;
        t.counts.strict_redirect_bypassed = 0;
        for (t.stale[0..t.stale_len]) |*st| {
            st.counts.sw_shared = false;
            st.counts.strict_redirect_bypassed = 0;
        }
        // 지금 묶음과 같은 브라우저의 은퇴 묶음 모두(4 차 검증 B-LOW-1: 규칙을 바꾼 뒤 보내기 전에 끄고 다시 켜면 은퇴 묶음의 켬 몫이 끈 뒤 frame 에
        // 실려 maru 가 끌 때 지운 수가 되살아났다 — 보낼 때의 거르기는 다시 켠 `full` 을 본다).
        if (t.set) |set| forgetSw(set);
        for (self.retired.items) |set| if (set.browser == browser) forgetSw(set);
    }

    /// 묶음의 서비스 워커 수를 보낸 것으로 친다(보내지 않고 버린다).
    fn forgetSw(set: *RuleSet) void {
        for (set.slice()) |*r| {
            r.sent_sw_hits = r.sw_hits.load(.monotonic);
            r.sent_sw_not_applied = r.sw_not_applied.load(.monotonic);
        }
    }

    /// 이 서비스 워커 요청의 「적용 안 됨」 을 셀까(같은 요청의 앞 홉에서 셌으면 거짓 — N-A3-2). 번호 0 은 늘 센다(가를 수 없다). 센다고 적는다.
    pub fn firstNotApplied(self: *Table, request: u64) bool {
        if (request == 0) return true;
        if (std.mem.indexOfScalar(u64, &self.sw_counted, request) != null) return false;
        self.sw_counted[self.sw_counted_next] = request;
        self.sw_counted_next = (self.sw_counted_next + 1) % counted_requests;
        return true;
    }

    // ── IO 스레드: 처리기 고르기 ────────────────────────────────────────────────────────────────────

    /// 탭 길의 요청 하나를 맞출 준비(잠금 아래): 그 탭의 묶음을 잡는다(`readers`). D2 의 소비도 여기서 — 이 이동이 토큰을 묶은 주소의 첫 홉이면
    /// 요청 번호를 예외로 두고, 이미 예외인 번호면 그대로 둔다. 묶음이 없으면 null.
    pub fn acquire(self: *Table, cef_id: c_int, request: u64, main_nav: bool, url_canon: u64, now_ms: i64) ?Acquired {
        const t = self.findCef(cef_id) orelse return null;
        const set = t.set orelse return null;
        const exempt = self.consumeExempt(cef_id, request, main_nav, url_canon, now_ms);
        set.readers += 1;
        var a: Acquired = .{ .set = set, .user_exempt = exempt };
        const n = t.top_len;
        @memcpy(a.top_buf[0..n], t.top_buf[0..n]);
        a.top_len = n;
        return a;
    }

    /// D2 의 소비(잠금 아래 — 규칙 묶음과 무관하다, W9d④ §13 P2-1): 이 주 프레임 이동 요청이 토큰을 묶은 주소의 첫 홉이면 요청 번호를 예외로
    /// 두고 참, 이미 예외인 번호면 참. 같은 번호로 몇 번 물어도 같은 답이다(처리기 고르기가 먼저 묻고 `acquire` 가 다시 묻는다).
    /// 번호 0(speculation prefetch·prerender — 실측 J-B11)은 토큰을 쓰지도 예외를 받지도 않는다(20 회 검증 A N6: 사용자가 친 주소의 미리
    /// 불러오기가 토큰을 먼저 가져가 진짜 이동이 막혔다 — 그 요청은 규칙대로 막히고 진짜 이동이 토큰을 쓴다).
    pub fn consumeExempt(self: *Table, cef_id: c_int, request: u64, main_nav: bool, url_canon: u64, now_ms: i64) bool {
        if (!main_nav or request == 0) return false;
        const t = self.findCef(cef_id) orelse return false;
        if (request == t.exempt_request) return true;
        if (t.bound_url != 0 and t.bound_url == url_canon and now_ms < t.bound_until) {
            t.exempt_request = request;
            // 다툼이면 묶음을 남긴다 — 같은 주소로 겹친 둘째 이동(에이전트 것이 먼저 첫 홉에 닿았을 수 있다)의 첫 홉도 예외(v1 SEVERE-2). 새 문서·끊김·
            // 다른 이동·시한이 거둔다.
            if (!t.contested) t.bound_url = 0;
            return true;
        }
        return false;
    }

    /// 잡은 묶음을 놓고 답을 적는다(잠금 아래) — 막았으면 그 규칙의 수, 모르는 페이지면 그 수, 주 프레임 이동을 막았으면 귀속.
    pub fn release(self: *Table, cef_id: c_int, a: *const Acquired, verdict: Verdict, main_nav: bool, url_canon: u64) void {
        self.releaseNav(cef_id, a, verdict, main_nav, false, url_canon);
    }

    /// `release` 와 같고, `sub_nav` 면 하위 프레임 이동이다(막았으면 그 주소를 적는다 — 그 프레임의 다음 문서 시작이 오류 페이지다, MED-A3-1).
    pub fn releaseNav(self: *Table, cef_id: c_int, a: *const Acquired, verdict: Verdict, main_nav: bool, sub_nav: bool, url_canon: u64) void {
        a.set.readers -= 1;
        const t = self.findCef(cef_id) orelse return;
        switch (verdict) {
            // 잡은 묶음의 세대로 센다(NEW-B3-1 — 잡은 뒤 maru 가 탭을 비웠어도 이 수는 옛 규칙의 것이다).
            .unknown_page => t.countsFor(a.set.generation).skipped_unknown_page +|= 1,
            .block => |rule| if (main_nav) {
                t.last_main_block_url = url_canon;
                t.last_main_block_rule = rule;
            } else if (sub_nav and url_canon != 0) {
                t.markBlockedSub(url_canon);
            },
            else => {},
        }
    }

    /// 문을 지나지 못해 기록 없이 막았다(fail closed) — 막은 규칙의 세대로 센다(NEW-B3-1).
    pub fn noteUnrecorded(self: *Table, cef_id: c_int, generation: u32) void {
        if (self.findCef(cef_id)) |t| t.countsFor(generation).unrecorded +|= 1;
    }

    // ── UI 스레드: 주소·이동 ─────────────────────────────────────────────────────────────────────────

    /// 주 프레임 주소가 바뀌었다(확정) — 맨 위 호스트, 진행 중인 주 프레임 이동을 지운다. `url_canon` 은 확정된 주소의 정규 꼴 해시.
    pub fn committed(self: *Table, browser: BrowserId, cef_id: c_int, host: []const u8, url_canon: u64) void {
        const t = self.ensure(browser, cef_id) orelse return;
        const n = @min(host.len, t.top_buf.len);
        @memcpy(t.top_buf[0..n], host[0..n]);
        t.top_len = @intCast(n);
        clearPending(t, true, 0);
        // `on_before_browse` 없이 확정된 이동(bfcache 로 돌아감·같은 문서 기록 이동)이 사용자의 뒤로·앞으로였다 — 남은 토큰을 다른 이동이
        // 가져가지 않게 거둔다(20 회 검증 A LOW-3).
        t.nav_token_until = 0;
        // 사용자가 친 주소가 같은 문서 이동(조각만 다름 — `on_before_browse` 가 없다)으로 확정됐다 — 토큰을 쓴 셈이다(2 차 검증 LOW-A2-3: 남은
        // 5 초 토큰을 에이전트의 새로 고침·페이지의 같은 주소 이동이 가져갔다). 다른 주소의 확정(옛 문서의 pushState)은 거두지 않는다 — 사용자의
        // 이동은 아직 가는 중일 수 있다(떠나기 확인). 묶인 토큰은 새 문서의 시작이 거둔다(`frameSettled` — 같은 문서 확정은 묶인 이동의 것이 아니다).
        if (t.url_token != 0 and t.url_token == url_canon) t.url_token = 0;
    }

    /// 그 프레임의 이동이 끝났다(문서 시작·오류) — 그 프레임의 진행 중 이동을 지운다(주 프레임이면 `frame` 무시).
    pub fn frameSettled(self: *Table, cef_id: c_int, main: bool, frame: u64) void {
        const t = self.findCef(cef_id) orelse return;
        clearPending(t, main, frame);
        // 주 프레임에 새 문서(또는 오류 페이지)가 섰다 — 묶인 사용자 토큰의 이동은 끝났다(같은 문서 이동에는 오지 않는다 — 옛 문서의 pushState 가 사용자의
        // 이동을 거두지 않게 주소 확정이 아니라 여기서; 2 차 검증 LOW-A2-3). 옛 문서의 하위 프레임은 사라졌다 — 그 오류 페이지 표시도.
        if (main) {
            t.bound_url = 0;
            // 다툼의 창은 새 문서가 서면 끝난다(그 뒤의 이동은 에이전트가 따로 몬 것이다).
            t.user_nav_url = 0;
            if (t.contested) {
                t.url_token = 0;
                t.nav_token_until = 0;
                t.contested = false;
            }
            t.err_frames = @splat(0);
            t.err_unsure = false;
            t.blocked_sub = @splat(.{});
        }
    }

    /// 하위 프레임에 문서가 섰다(`on_load_start`) — 그 프레임의 진행 중 기록을 놓고(열쇠, 없으면 주소 — MED-A3-1), 막기 규칙이 막은 이동의 주소면
    /// 그 문서는 오류 페이지다(그 출처를 보이지 않는다), 아니면 그 프레임의 오류 표시를 지운다.
    pub fn subframeStarted(self: *Table, cef_id: c_int, frame: u64, url_canon: u64) void {
        const t = self.findCef(cef_id) orelse return;
        t.releaseSubframe(frame, url_canon);
        if (t.takeBlockedSub(frame, url_canon)) {
            t.addErrFrame(frame);
            return;
        }
        t.removeErrFrame(frame);
    }

    /// 주 프레임 이동이 끊겼다(ERR_ABORTED — 오류 페이지 없음) — 진행 중 주 프레임 이동이 그 주소면 놓는다(밀려 끊긴 옛 이동의 끊김이 새 이동의
    /// 기록을 지우지 않게 — 주소로 가른다).
    pub fn mainAborted(self: *Table, cef_id: c_int, url_canon: u64) void {
        const t = self.findCef(cef_id) orelse return;
        // 묶인 사용자 토큰의 이동이 끝났다(204·다운로드 — 문서가 서지 않는다, 3 차 검증 N-A3-1: 규칙이 없어 IO 가 쓰지 않은 묶음이 5 초 남아
        // 그 뒤 더한 규칙 아래 페이지의 같은 주소 이동이 가져갔다).
        // 다툼이면 남긴다 — 같은 주소로 겹친 두 이동 중 밀려 끊긴 쪽의 끊김이 남은 쪽의 묶음을 지우지 않게(v1 SEVERE-2; 시한·새 문서가 거둔다).
        if (t.bound_url == url_canon and !t.contested) t.bound_url = 0;
        if (t.user_nav_url == url_canon and !t.contested) t.user_nav_url = 0;
        const p = t.pendingMain() orelse return;
        if (p.url == url_canon) clearPending(t, true, 0);
    }

    /// 하위 프레임의 이동이 끝났다(오류·끊김 — 204·다운로드·빈 응답·막힘, 문서가 서지 않는다; 떨어져 나감) — 그 프레임의 진행 중 기록을
    /// 놓는다(3 차 검증 MED-A3-1: 놓는 이가 문서 시작·30 초뿐이라 끝나지 않은 iframe 이동이 그 탭을 30 초 동안 그 출처를 「보이는」 탭으로
    /// 남겨 — 아무도 보이지 않는 출처의 서비스 워커 요청이 다른 사이트 규칙으로 막혔다).
    /// `url_canon` — 실패한 주소(열쇠가 바뀐 프레임의 기록을 주소로 찾는다), `error_page` — 그 프레임에 오류 페이지가 섰다(끊김 ERR_ABORTED 는
    /// 아니다 — 옛 문서가 남는다).
    pub fn subframeEnded(self: *Table, cef_id: c_int, frame: u64, url_canon: u64, error_page: bool) void {
        const t = self.findCef(cef_id) orelse return;
        t.releaseSubframe(frame, url_canon);
        // 막은 이동이면 그 막힘은 여기서 끝났다 — 오류 페이지는 아래 표시가 맡는다(4 차 검증 A-MED: 남은 표시가 뒤에 같은 주소로 정말 선 문서를
        // 오류 페이지로 쳤다). 그 프레임의 표시만(없으면 그 주소의 것 하나 — 5 차 검증 NIT: 같은 주소로 막힌 다른 프레임의 표시까지 지웠다).
        _ = t.takeBlockedSub(frame, url_canon);
        if (error_page) t.addErrFrame(frame);
    }

    /// 하위 프레임이 떨어져 나갔다 — 그 프레임의 진행 중 기록과 오류 표시를 지운다.
    pub fn subframeGone(self: *Table, cef_id: c_int, frame: u64) void {
        const t = self.findCef(cef_id) orelse return;
        if (frame == 0) return;
        t.releaseSubframe(frame, 0);
        t.removeErrFrame(frame);
        t.dropBlockedSubOf(frame, 0); // 그 프레임의 막힘도 끝났다(5 차 검증 NIT — 프레임별로)
    }

    fn clearPending(t: *Tab, main: bool, frame: u64) void {
        var i: usize = 0;
        while (i < t.pending_len) {
            const p = &t.pending[i];
            if ((main and p.main) or (!main and !p.main and p.frame == frame)) {
                t.pending[i] = t.pending[t.pending_len - 1];
                t.pending_len -= 1;
            } else i += 1;
        }
    }

    /// `navigate{user}` — 그 주소(정규 꼴 해시)에 토큰.
    pub fn userNavigate(self: *Table, browser: BrowserId, cef_id: c_int, url_canon: u64, now_ms: i64) void {
        const t = self.ensure(browser, cef_id) orelse return;
        t.contested = false; // 새 몸짓 — 다툼은 이 토큰이 산 동안의 에이전트 호출로만
        t.url_token = url_canon;
        t.url_token_until = now_ms + start_cap_ms;
        t.url_token_started = false;
    }

    /// `nav_action{user}` — 다음 주 프레임 이동 하나(그 갈래 — `kind`)에 토큰(1 초). 기록 이동이 갈 곳이 없으면 부르지 않는다(`browsers.zig`).
    pub fn userNavAction(self: *Table, browser: BrowserId, cef_id: c_int, kind: NavKind, now_ms: i64) void {
        const t = self.ensure(browser, cef_id) orelse return;
        t.contested = false;
        t.nav_token_until = now_ms + start_cap_ms;
        t.nav_token_started = false;
        t.nav_token_kind = kind;
    }

    /// 사용자 것이 아닌 이동이 **다른 곳으로** 곧 시작한다(에이전트·복원·재생의 다른 주소 `navigate`, 뒤로·앞으로, 누구든 멈춤 — 20 회 검증 A LOW-3)
    /// — 남은 사용자 토큰을 모두 거둔다(그 이동이 가져가지 않게). 이 이동은 진행 중인 사용자 이동을 대신한다(같은 프레임의 새 이동).
    pub fn agentNavigate(self: *Table, cef_id: c_int) void {
        const t = self.findCef(cef_id) orelse return;
        t.dropTokens();
    }

    /// 에이전트·복원의 `navigate`(그 주소의 정규 꼴 해시) — 산 주소 토큰과 **같은 주소**면 거두지 않고 다툼으로 둔다(v1 SEVERE-2: 사용자가 친 주소
    /// 바로 뒤 에이전트가 같은 주소로 몰면 그 이동이 사용자의 것을 대신해 사용자가 친 주소에서 에이전트의 가짜를 봤다 — 같은 곳이면 둘 다 진짜).
    /// 다른 주소면 `agentNavigate` 와 같다.
    pub fn agentNavigateTo(self: *Table, cef_id: c_int, url_canon: u64, now_ms: i64) void {
        const t = self.findCef(cef_id) orelse return;
        const url_live = t.url_token != 0 and t.url_token == url_canon and now_ms < t.url_token_until;
        // 사용자 이동이 이미 `on_before_browse` 에서 토큰을 썼다(가는 중) — 같은 주소면 그것도 같은 곳이다.
        const going = t.user_nav_url == url_canon and t.userNavLive(now_ms);
        if (url_live or going) {
            t.nav_token_until = 0; // 기록·새로 고침 토큰은 이 이동의 것이 아니다
            t.contested = true;
            return;
        }
        t.dropTokens();
    }

    /// 에이전트·복원의 새로 고침 — 산 새로 고침 토큰이 있으면 같은 곳(지금 문서)이라 거두지 않고 다툼으로(v1 SEVERE-2), 아니면 `agentNavigate`.
    pub fn agentReload(self: *Table, cef_id: c_int, now_ms: i64) void {
        const t = self.findCef(cef_id) orelse return;
        const reload_live = now_ms < t.nav_token_until and t.nav_token_kind == .reload;
        // 사용자의 새로 고침이 이미 토큰을 썼다(가는 중 — 같은 문서로).
        const going = t.user_nav_reload and t.userNavLive(now_ms);
        if (reload_live or going) {
            t.url_token = 0; // 새로 고침은 친 주소로 가지 않는다
            if (!reload_live) t.nav_token_until = 0;
            t.contested = true;
            return;
        }
        t.dropTokens();
    }

    /// 이동을 시작할 수 있는 에이전트의 DevTools 호출(`devtools_table.startsNavigationCall` — 읽기 목록 밖: 스크립트·누르기·`Page.reload`·기록 이동…)
    /// — 어디로 갈지(가기나 할지) 모른다. 산 토큰이 있으면 **거두지 않고** 다툼으로 둔다(W9d④ v1 검증 SEVERE-2 — 사용자 결정 2026-11-11 「고침」:
    /// 전에는 거둬(W9d③ 2 차 검증 LOW-A2-3) 사용자가 친 주소·새로 고침의 주 문서가 겹친 `Runtime.evaluate "1"` 하나로 가짜·막힘이 됐다 — 5/5·3/3,
    /// 옛 문서의 beforeunload 동안은 그 길이 전체가 창). 대가(fail-safe): 그 창 안에 에이전트가 같은 주소·같은 갈래로 몬 이동도 진짜로 지나간다.
    pub fn agentDevtoolsCall(self: *Table, cef_id: c_int, now_ms: i64) void {
        const t = self.findCef(cef_id) orelse return;
        if (t.tokensAlive(now_ms)) t.contested = true;
    }

    /// 사용자의 뒤로·앞으로가 주 프레임 문서를 옮기지 않는다(`historyTokenStays` 거짓) — 그 몸짓에 건 기록 토큰을 거둔다(벌써 쓴 토큰은 이미 0).
    pub fn dropHistoryToken(self: *Table, cef_id: c_int) void {
        const t = self.findCef(cef_id) orelse return;
        if (t.nav_token_kind == .history) t.nav_token_until = 0;
    }

    /// 떠나기 확인(beforeunload)이 떴다 — 살아 있는 사용자 토큰의 시계를 멈춘다(2 차 검증 LOW-A2-4: 사용자가 친 이동·새로 고침은 확인에 답한
    /// **뒤에야** `on_before_browse` 가 와, 6 초 뒤에 답하면 토큰이 지나 그 사용자의 이동이 막혔다). 토큰이 없으면 아무것도 하지 않는다(그 확인은
    /// 사용자 몸짓의 이동 것이 아니다). `request` — 그 대화상자의 번호(답이 짝짓는다).
    pub fn holdTokens(self: *Table, cef_id: c_int, request: u32, now_ms: i64) void {
        const t = self.findCef(cef_id) orelse return;
        const alive = (t.url_token != 0 and now_ms < t.url_token_until) or now_ms < t.nav_token_until;
        if (!alive) return;
        t.hold_at = now_ms;
        t.hold_request = request;
    }

    /// 떠나기 확인이 닫혔다 — 떠나기면 멈춘 동안만큼 토큰을 늘리고(`hold_max_ms` 까지 — 넘게 떠 있었으면 거둔다), 머무르기·취소·렌더러 죽음이면
    /// 거둔다(이동이 시작되지 않았다 — 몸짓이 이동을 남기지 않으면 토큰도 남기지 않는다). `request` 0 은 그 탭의 어느 확인이든.
    pub fn releaseHold(self: *Table, cef_id: c_int, request: u32, leave: bool, now_ms: i64) void {
        const t = self.findCef(cef_id) orelse return;
        const since = t.hold_at orelse return;
        if (request != 0 and request != t.hold_request) return;
        const held = now_ms - since;
        t.hold_at = null;
        if (!leave or held > hold_max_ms) {
            t.url_token = 0;
            t.nav_token_until = 0;
            t.contested = false;
            t.user_nav_url = 0;
            return;
        }
        t.url_token_until +|= held;
        t.nav_token_until +|= held;
    }

    /// `on_before_browse` — 진행 중 이동을 적고(서비스 워커 길·귀속), 주 프레임이면 D2 토큰을 그 주소에 묶는다. 사용자 이동이었으면 참.
    /// `is_redirect` — 같은 이동의 다음 홉이다(CEF `on_before_browse` 의 인자): 앞 홉이 사용자 이동이었으면 이 홉도(서비스 워커 길의 D2 예외 —
    /// 탭 길은 요청 번호로 이미 예외다).
    /// `nav` — 이 이동의 갈래(CEF 전이 종류 — `nav_action` 토큰은 같은 갈래만 가져간다).
    pub fn beforeBrowse(self: *Table, browser: BrowserId, cef_id: c_int, main: bool, is_redirect: bool, nav: NavKind, frame: u64, url_canon: u64, origin: u64, host: []const u8, now_ms: i64) bool {
        const t = self.ensure(browser, cef_id) orelse return false;
        t.expire(now_ms);
        var user = false;
        if (main) {
            if (is_redirect) {
                if (t.pendingMain()) |prev| user = prev.user;
            } else {
                // 새 이동 — 앞 이동이 남긴 막힘 귀속은 이것과 무관하다(20 회 검증 A N5: 바뀐 이동의 귀속이 남아 뒤의 같은 주소 실패를 막힘으로 적었다).
                t.last_main_block_url = 0;
                t.last_main_block_rule = 0;
                if (t.url_token != 0 and now_ms < t.url_token_until and t.url_token == url_canon) {
                    user = true;
                    // 다툼이면 쓰지 않는다 — 같은 주소의 다른 이동(사용자의 것일 수 있다)도 그 창 안이면 진짜(v1 SEVERE-2). 시계는 지금부터.
                    if (t.contested) {
                        if (!t.url_token_started) {
                            t.url_token_started = true;
                            t.url_token_until = @min(t.url_token_until, now_ms + url_token_ms);
                        }
                    } else t.url_token = 0;
                } else if (now_ms < t.nav_token_until and nav != .other and nav == t.nav_token_kind) {
                    user = true;
                    if (t.contested) {
                        if (!t.nav_token_started) {
                            t.nav_token_started = true;
                            t.nav_token_until = @min(t.nav_token_until, now_ms + nav_token_ms);
                        }
                    } else t.nav_token_until = 0;
                } else if (t.contested and t.user_nav_url == url_canon and t.userNavLive(now_ms)) {
                    // 다툼 중 이미 묶인(토큰을 쓴) 사용자 이동과 같은 주소로 겹친 이동 — 그것이 사용자 이동을 대신하므로 그것도 사용자 것(v1 SEVERE-2:
                    // 사용자 이동의 `on_before_browse` 가 에이전트의 eval·navigate 보다 먼저 와 토큰을 썼다 — 그 뒤 같은 주소의 에이전트 이동이 가짜였다).
                    user = true;
                } else t.startClocks(now_ms);
                // 새 주 프레임 이동은 앞에 묶인 이동을 대신한다(N-A3-1 — 그 이동은 끝났다).
                t.bound_url = 0;
            }
            if (user and !is_redirect) {
                t.bound_url = url_canon;
                t.bound_until = now_ms + url_token_ms;
                t.user_nav_url = url_canon;
                t.user_nav_until = now_ms + start_cap_ms;
                t.user_nav_reload = nav == .reload;
            } else if (!user and !is_redirect and t.user_nav_url != url_canon) {
                t.user_nav_url = 0; // 다른 곳으로 가는 이동이 사용자 이동을 대신한다
            }
        } else {
            // 하위 프레임의 새 이동 — 그 프레임의 막은 표시는 끝났다(이 이동은 다시 판정되고, 또 막히면 다시 적힌다 — 4 차 검증 A-MED). 같은 주소로
            // 막혀 끝을 기다리는 **다른** 프레임의 표시는 남긴다(5 차 검증 NIT — 전에는 주소로 지워, 같은 주소 iframe 여럿이 차례로 막히면 앞 프레임들의
            // 표시가 다음 프레임의 이동 시작에 사라졌다).
            t.dropBlockedSubOf(frame, url_canon);
            if (nav == .history and nav == t.nav_token_kind and now_ms < t.nav_token_until) {
                // 사용자의 뒤로·앞으로가 iframe 만 옮겼다(함께 쓰는 기록) — 그 몸짓의 이동은 이것이다. 토큰을 거둔다(2 차 검증 LOW-A2-3: 남은 토큰을
                // 1 초 안의 에이전트·페이지의 주 프레임 기록 이동이 가져갔다).
                t.nav_token_until = 0;
            }
        }
        // 같은 프레임의 앞 이동(리다이렉트의 앞 홉 포함)은 이 홉이 대신한다.
        clearPending(t, main, frame);
        if (t.pending_len == max_pending) {
            t.overflow_until = now_ms + pending_ttl_ms;
            // 가장 오래된 것을 잊는다(그 탭은 그동안 「모름」 — 서비스 워커 길에서 거부권).
            var oldest: usize = 0;
            for (t.pending[0..t.pending_len], 0..) |p, i| if (p.at_ms < t.pending[oldest].at_ms) {
                oldest = i;
            };
            t.pending[oldest] = t.pending[t.pending_len - 1];
            t.pending_len -= 1;
        }
        var p: Pending = .{ .frame = frame, .main = main, .origin = origin, .url = url_canon, .at_ms = now_ms, .user = main and user };
        const n = @min(host.len, p.host_buf.len);
        @memcpy(p.host_buf[0..n], host[0..n]);
        p.host_len = @intCast(n);
        t.pending[t.pending_len] = p;
        t.pending_len += 1;
        return user;
    }

    /// `on_load_error`(주 프레임) — 실패 주소가 막은 이동이면 그 규칙(짝은 한 번).
    pub fn mainBlockRule(self: *Table, cef_id: c_int, failed_canon: u64) u32 {
        const t = self.findCef(cef_id) orelse return 0;
        if (t.last_main_block_rule == 0 or t.last_main_block_url != failed_canon) return 0;
        const r = t.last_main_block_rule;
        t.last_main_block_rule = 0;
        t.last_main_block_url = 0;
        return r;
    }

    /// 서비스 워커 길이 막은 요청이 그 탭의 진행 중 주 프레임 이동이면 귀속을 적는다(§6.3).
    pub fn noteServiceWorkerMainBlock(self: *Table, cef_id: c_int, url_canon: u64, rule: u32) void {
        const t = self.findCef(cef_id) orelse return;
        const p = t.pendingMain() orelse return;
        if (p.url != url_canon) return;
        t.last_main_block_url = url_canon;
        t.last_main_block_rule = rule;
    }

    // ── 보내는 task: 수의 차이 ───────────────────────────────────────────────────────────────────────

    /// 그 탭의 보낼 차이를 세대마다 한 frame 으로 모은다(앞선 세대부터 — `out` 은 `max_frames` 자리): 탭 몫 수는 센 세대(`counts`·`stale`), 규칙의
    /// 차이는 그 규칙 묶음의 세대(지금 묶음·은퇴 묶음 — 같은 세대의 같은 번호는 합친다; 3 차 검증 NEW-B3-1: 모두 지금 세대를 달아 탭을 비운 세대의
    /// frame 에 옛 규칙의 수가 실렸다 — maru 는 번호로 버렸지만 세대가 거짓이었다). 보낼 것이 없으면 0. 자리가 모자라면(닿지 않는다 — 은퇴 묶음은
    /// 보내면 곧 풀린다) 가장 앞선 세대의 frame 에 합친다(버리는 쪽).
    pub fn takeHits(self: *Table, browser: BrowserId, out: []msg.NetBlockHits) usize {
        var n: usize = 0;
        var full = true;
        const t_opt = self.find(browser);
        if (t_opt) |t| {
            full = t.full;
            for (t.stale[0..t.stale_len]) |st| if (st.counts.any()) addCounts(frameFor(out, &n, browser, st.generation), st.counts, full);
            t.stale_len = 0;
            if (t.counts.any()) addCounts(frameFor(out, &n, browser, t.generation), t.counts, full);
            t.counts = .{};
            if (t.set) |set| if (pendingDelta(set)) collect(set, frameFor(out, &n, browser, set.generation));
        }
        for (self.retired.items) |set| if (set.browser == browser and pendingDelta(set)) collect(set, frameFor(out, &n, browser, set.generation));
        // 설정이 꺼졌으면 켬 몫의 규칙 수는 싣지 않는다(N-B3-d — 보낼 때도 본다).
        if (!full) for (out[0..n]) |*f| for (f.entries[0..f.count]) |*e| {
            e.sw_hits = 0;
            e.sw_not_applied = 0;
        };
        // 비게 된 frame(켬 몫만 있었다)은 뺀다.
        var k: usize = 0;
        for (out[0..n]) |f| {
            var rule_any = false;
            for (f.entries[0..f.count]) |e| rule_any = rule_any or e.hits > 0 or e.sw_hits > 0 or e.sw_not_applied > 0;
            if (rule_any or f.unrecorded > 0 or f.skipped_unknown_page > 0 or f.sw_shared_with_unruled_tab or f.strict_redirect_missed > 0 or f.strict_redirect_bypassed > 0) {
                out[k] = f;
                k += 1;
            }
        }
        // 앞선 세대부터.
        std.mem.sort(msg.NetBlockHits, out[0..k], {}, struct {
            fn lt(_: void, x: msg.NetBlockHits, y: msg.NetBlockHits) bool {
                return genBefore(x.generation, y.generation);
            }
        }.lt);
        return k;
    }

    /// 보낼 차이가 있는 브라우저들(지금 탭과 은퇴 묶음의 것 — `out` 에, 겹치지 않게).
    pub fn browsersWithHits(self: *Table, out: []BrowserId) []BrowserId {
        var n: usize = 0;
        const add = struct {
            fn f(o: []BrowserId, len: *usize, b: BrowserId) void {
                for (o[0..len.*]) |x| if (x == b) return;
                if (len.* == o.len) return;
                o[len.*] = b;
                len.* += 1;
            }
        }.f;
        for (&self.tabs) |*t| {
            if (!t.used) continue;
            const has = t.counts.any() or t.stale_len > 0 or (if (t.set) |s| pendingDelta(s) else false);
            if (has) add(out, &n, t.browser);
        }
        for (self.retired.items) |set| if (pendingDelta(set)) add(out, &n, set.browser);
        return out[0..n];
    }

    /// readers 0 인 은퇴 묶음을 푼다(마지막 수는 `takeHits` 가 먼저 가져갔다).
    pub fn reap(self: *Table, gpa: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < self.retired.items.len) {
            const set = self.retired.items[i];
            if (set.readers == 0 and !pendingDelta(set)) {
                gpa.destroy(set);
                _ = self.retired.swapRemove(i);
            } else i += 1;
        }
    }

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        for (&self.tabs) |*t| if (t.set) |s| {
            gpa.destroy(s);
            t.set = null;
        };
        for (self.retired.items) |s| gpa.destroy(s);
        self.retired.deinit(gpa);
    }
};

/// 처리기 고르기가 잡은 것 — 묶음과 맞추기에 쓸 탭의 사실(잠금 밖에서 쓴다).
pub const Acquired = struct {
    set: *RuleSet,
    user_exempt: bool,
    top_buf: [msg.max_net_host_bytes]u8 = undefined,
    top_len: u8 = 0,

    pub fn topHost(self: *const Acquired) []const u8 {
        return self.top_buf[0..self.top_len];
    }
};

/// 한 탭의 보낼 frame 자리 수(`takeHits` 의 `out`) — 지난 세대 탭 몫·지금 세대·은퇴 묶음 몇.
pub const max_frames: usize = max_stale + 5;

/// 그 세대의 frame(없으면 만든다 — 자리가 없으면 가장 앞선 세대의 frame 에 합친다).
fn frameFor(out: []msg.NetBlockHits, n: *usize, browser: BrowserId, generation: u32) *msg.NetBlockHits {
    for (out[0..n.*]) |*f| if (f.generation == generation) return f;
    if (n.* < out.len) {
        out[n.*] = .{ .browser = browser, .generation = generation };
        n.* += 1;
        return &out[n.* - 1];
    }
    var oldest: usize = 0;
    for (out[0..n.*], 0..) |f, i| if (genBefore(f.generation, out[oldest].generation)) {
        oldest = i;
    };
    if (genBefore(generation, out[oldest].generation)) out[oldest].generation = generation;
    return &out[oldest];
}

/// 탭 몫 수를 frame 에 더한다(설정이 꺼졌으면 켬 몫을 뺀다 — N-B3-d).
fn addCounts(f: *msg.NetBlockHits, c: TabCounts, full: bool) void {
    f.unrecorded +|= c.unrecorded;
    f.skipped_unknown_page +|= c.skipped_unknown_page;
    f.sw_shared_with_unruled_tab = f.sw_shared_with_unruled_tab or (full and c.sw_shared);
    f.strict_redirect_missed +|= c.strict_redirect_missed;
    if (full) f.strict_redirect_bypassed +|= c.strict_redirect_bypassed;
}

fn pendingDelta(set: *RuleSet) bool {
    for (set.slice()) |*r| {
        if (r.hits.load(.monotonic) != r.sent_hits or r.sw_hits.load(.monotonic) != r.sent_sw_hits or r.sw_not_applied.load(.monotonic) != r.sent_sw_not_applied) return true;
    }
    return false;
}

fn collect(set: *RuleSet, out: *msg.NetBlockHits) void {
    for (set.slice()) |*r| {
        const h = r.hits.load(.monotonic);
        const s = r.sw_hits.load(.monotonic);
        const n = r.sw_not_applied.load(.monotonic);
        const dh = h -% r.sent_hits;
        const ds = s -% r.sent_sw_hits;
        const dn = n -% r.sent_sw_not_applied;
        r.sent_hits = h;
        r.sent_sw_hits = s;
        r.sent_sw_not_applied = n;
        if (dh == 0 and ds == 0 and dn == 0) continue;
        const slot = for (out.entries[0..out.count]) |*e| {
            if (e.rule_id == r.id) break e;
        } else blk: {
            if (out.count == out.entries.len) return;
            out.entries[out.count] = .{ .rule_id = r.id };
            out.count += 1;
            break :blk &out.entries[out.count - 1];
        };
        slot.hits +|= dh;
        slot.sw_hits +|= ds;
        slot.sw_not_applied +|= dn;
    }
}

// ── 맞추기(잠금 밖 — 잡은 묶음으로) ──────────────────────────────────────────────────────────────────

/// 탭 길 요청의 답 — `main_nav` 면 그 홉 주소의 호스트를 규칙 사이트가 덮어야 하고(홉마다 — J-B2), 아니면 페이지 호스트(`page_host` —
/// `net_policy.pageHost`)를. 페이지를 모르면(빈 글) 맞는 규칙이 있어도 막지 않고 `unknown_page`. D2 예외는 주 프레임 이동만. 맞추기는 요청 하나의
/// 예산(`nb.Budget` — 4 차 검증 B-LOW-4) 안에서 — 넘으면 남은 규칙의 가운데 조각은 맞은 것으로 친다(막는 쪽).
pub fn decideTab(a: *const Acquired, url: []const u16, resource_type: u8, main_nav: bool, page_host: []const u8) Verdict {
    var budget: nb.Budget = .{};
    return decideTabBudget(a, url, resource_type, main_nav, page_host, &budget);
}

/// `decideTab` 과 같고 예산을 부른 쪽이 준다(시험).
pub fn decideTabBudget(a: *const Acquired, url: []const u16, resource_type: u8, main_nav: bool, page_host: []const u8, budget: *nb.Budget) Verdict {
    if (main_nav and a.user_exempt) return .user_exempt;
    const parts = nb.splitUrl(u16, url) orelse return .pass;
    var hb: [msg.max_net_host_bytes]u8 = undefined;
    const hop_host = if (main_nav) urlHost(u16, url, &hb) else "";
    var unknown = false;
    for (a.set.slice()) |*r| {
        if (!nb.typeMatches(r.types, resource_type)) continue;
        // 사이트를 먼저 본다(값싸다 — 잠든 규칙은 주소를 훑지 않아 예산을 쓰지 않는다).
        if (main_nav) {
            if (!net_policy.hostCovers(r.site(), hop_host)) continue;
        } else if (page_host.len != 0) {
            if (!net_policy.hostCovers(r.site(), page_host)) continue;
        }
        if (!nb.matchPartsBudget(u16, &r.pattern, parts, budget)) continue;
        if (!main_nav and page_host.len == 0) {
            unknown = true;
            continue;
        }
        bump(&r.hits);
        return .{ .block = r.id };
    }
    return if (unknown) .unknown_page else .pass;
}

/// 서비스 워커 길에서 그 탭의 규칙 사이트가 덮어야 할 호스트(`serviceWorkerRule` 의 `top_hosts`). 이 요청이 그 탭의 진행 중 주 프레임 이동
/// **자체**면(서비스 워커가 대신 받는 이동 — 그 이동의 주소 해시와 같고, 요청을 낸 출처 `initiator_origin` 이 그 이동의 목적지 출처다: 그 출처의
/// 서비스 워커가 이동을 대신 받는 꼴) 그 이동(마지막 홉)의 호스트만 — 탭 길이 주 프레임 홉을 그 홉의 호스트로 정하는 것과 같다(3 차 검증 MED-A3-2:
/// 다른 사이트에서 규칙의 사이트로 들어오는 이동이 확정된 옛 호스트 때문에 규칙을 잃어 막히지도 세어지지도 않았다 2/2 — 같은 이동이 탭 길이면 -20).
/// 아니면 확정된 맨 위 호스트와 진행 중 주 프레임 이동의 호스트 모두(떠나는 중인 탭의 하위 자원은 어느 문서의 것인지 모른다 — 둘 다 덮어야; 4 차 검증
/// A-LOW: 다른 출처의 옛 문서가 그 이동 주소로 낸 하위 자원까지 이동 자체로 쳐 이동 사이트의 규칙이 옛 문서의 요청을 막았다 — 탭 길이면 페이지
/// 호스트라 지나간다).
/// 5 차 검증 LOW: 출처만으로는 떠나는 옛 문서 안의 **목적지 출처 iframe**(제 서비스 워커 — 분할 저장소)이 그 이동 주소로 낸 하위 자원도 이동 자체로
/// 쳐 이동 사이트의 규칙이 옛 문서의 요청을 막았다(실측 `A5-R6-sw-iframe-dest-origin` — 탭 길이면 페이지 호스트라 지나간다). 그래서 요청의 「쿠키의
/// 첫 사이트」(`first_party_host` — CEF `get_first_party_for_cookies` 의 호스트)도 본다(`swNavItself`).
pub fn swHosts(t: *const Tab, url_canon: u64, initiator_origin: u64, first_party_host: []const u8, out: *[2][]const u8) []const []const u8 {
    if (t.pendingMain()) |p| {
        if (swNavItself(t, url_canon, initiator_origin, first_party_host) == .yes) {
            out[0] = p.host();
            return out[0..1];
        }
        out[0] = t.topHost();
        out[1] = p.host();
        return out[0..2];
    }
    out[0] = t.topHost();
    return out[0..1];
}

/// `swNavItself` 의 답 — 이동이 아니다(그 요청을 쓰지 않는다)·가를 수 없다·이동 자체다.
pub const SwNav = enum { no, ambiguous, yes };

/// 서비스 워커 길의 요청이 그 탭의 진행 중 주 프레임 이동 **자체**인가(`swHosts` 는 `yes` 만, §6.3 의 귀속은 `yes`·`ambiguous`). 주소 해시가 그
/// 이동의 것이고 요청을 낸 출처가 그 목적지 출처이며, 요청의 쿠키 첫 사이트가 그것을 증명할 때만 `yes`:
///   - 이동을 대신 받는 서비스 워커는 목적지의 맨 위(첫 사이트) 서비스 워커라 첫 사이트가 목적지의 사이트다(실측 CEF 154 — `A3-R6-sw-nav-entering-site`
///     의 이동 요청 `http://127.0.0.1/`). 다른 사이트 맨 위 문서 안의 iframe 의 서비스 워커는 분할 저장소의 제3자라 첫 사이트가 **비었다**(실측
///     `A5-R6-sw-iframe-dest-origin` 의 iframe 요청 `[]`) — 이동 자체가 아니다.
///   - 옛 맨 위 문서가 목적지와 같은 사이트면(맨 위 호스트도 그 첫 사이트 안) 그 문서의 목적지 출처 iframe 도 같은 첫 사이트를 싣는다 — 가를 근거가
///     없다(서비스 워커 길에는 이동 표지가 없다: 자원 종류 XHR·`is_navigation` 0·전이 0 — 실측). 그 경우(`ambiguous`)는 호스트를 이동 자체로 정하지
///     않는다(탭 길의 떠나는 탭 하위 자원 판정 — 두 호스트). 귀속은 남긴다(전과 같다 — 같은 사이트 안의 서비스 워커 범위 이동이 막히면 그 오류
///     페이지가 규칙을 싣는다). 맨 위가 비었으면(첫 이동 — 옛 문서가 없다) 이동 자체다.
pub fn swNavItself(t: *const Tab, url_canon: u64, initiator_origin: u64, first_party_host: []const u8) SwNav {
    const p = t.pendingMain() orelse return .no;
    if (p.url != url_canon or p.origin != initiator_origin) return .no;
    if (!net_policy.hostCovers(first_party_host, p.host())) return .no;
    const top = t.topHost();
    return if (top.len == 0 or !net_policy.hostCovers(first_party_host, top)) .yes else .ambiguous;
}

/// 서비스 워커 길에서 그 탭이 쥔, 사이트가 `top_hosts`(`swHosts`) 모두를 덮고 이 주소에 맞는 종류 없는 첫 규칙. 사이트를 먼저 본다(값싸다 —
/// 덮지 않는 규칙은 주소를 훑지 않는다). 맞추기는 그 요청의 예산(`budget` — 모든 탭이 함께 쓴다, 4 차 검증 B-LOW-4) 안에서.
pub fn serviceWorkerRule(set: *RuleSet, parts: nb.UrlParts(u16), top_hosts: []const []const u8, budget: *nb.Budget) ?*Rule {
    if (!set.any_untyped or top_hosts.len == 0) return null;
    for (set.slice()) |*r| {
        if (r.types != 0) continue; // 종류를 단 규칙은 서비스 워커 길에 듣지 않는다(§12 P1-7)
        const covers = for (top_hosts) |h| {
            if (h.len == 0 or !net_policy.hostCovers(r.site(), h)) break false;
        } else true;
        if (!covers) continue;
        if (!nb.matchPartsBudget(u16, &r.pattern, parts, budget)) continue;
        return r;
    }
    return null;
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn u16s(comptime s: []const u8) [s.len]u16 {
    var out: [s.len]u16 = undefined;
    for (s, 0..) |ch, i| out[i] = ch;
    return out;
}

/// 시험: 그 탭의 보낼 frame 이 하나뿐일 때 그것(없으면 null).
pub fn takeOne(t: *Table, browser: BrowserId) ?msg.NetBlockHits {
    var out: [max_frames]msg.NetBlockHits = undefined;
    const n = t.takeHits(browser, &out);
    std.debug.assert(n <= 1);
    return if (n == 1) out[0] else null;
}

fn blockMsg(browser: BrowserId, gen: u32, rules: []const msg.NetBlockRule, strict: []const u8) msg.NetBlock {
    var v: msg.NetBlock = .{ .browser = browser, .generation = gen, .strict_site = strict, .count = @intCast(rules.len) };
    for (rules, 0..) |r, i| v.rules[i] = r;
    return v;
}

fn install(t: *Table, browser: BrowserId, cef: c_int, rules: []const msg.NetBlockRule) !void {
    const c = try compile(testing.allocator, blockMsg(browser, 1, rules, ""));
    try testing.expect(c.ok);
    const tab = t.ensure(browser, cef).?;
    try t.swap(testing.allocator, tab, c.set, "", 1);
}

test "W9d③: 묶음 바꾸기 — 잡은 동안 옛 묶음은 풀지 않고, 놓은 뒤 마지막 수를 보내고 푼다, 규칙 수는 0 이면 처리기가 보지 않는다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), t.with_rules);
    try install(&t, 7, 70, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/blk" }});
    try testing.expectEqual(@as(usize, 1), t.with_rules);
    t.committed(7, 70, "a.test", 0);
    const url = u16s("https://a.test/blk/x");
    var a = t.acquire(70, 11, false, 0, 0).?;
    // 쥔 사이에 새 묶음으로 바뀐다.
    try install(&t, 7, 70, &.{.{ .id = 2, .site = "a.test", .pattern = "https://a.test/other" }});
    try testing.expectEqual(@as(usize, 1), t.with_rules);
    try testing.expectEqual(@as(usize, 1), t.retired.items.len);
    const v = decideTab(&a, &url, 4, false, "a.test");
    try testing.expectEqual(Verdict{ .block = 1 }, v); // 옛 묶음으로 맞췄다
    t.reap(testing.allocator);
    try testing.expectEqual(@as(usize, 1), t.retired.items.len); // 아직 쥐고 있다
    t.release(70, &a, v, false, 0);
    t.reap(testing.allocator);
    try testing.expectEqual(@as(usize, 1), t.retired.items.len); // 보내지 않은 수가 있다
    const h = takeOne(&t, 7).?;
    try testing.expectEqual(@as(u8, 1), h.count);
    try testing.expectEqual(@as(u32, 1), h.entries[0].rule_id);
    try testing.expectEqual(@as(u32, 1), h.entries[0].hits);
    t.reap(testing.allocator);
    try testing.expectEqual(@as(usize, 0), t.retired.items.len);
    try testing.expect(takeOne(&t, 7) == null); // 차이만
    try t.dropRules(testing.allocator, 7);
    try testing.expectEqual(@as(usize, 0), t.with_rules);
}

test "W9d③: 수는 포화하고 차이만 보낸다 — 같은 번호가 지금·은퇴 묶음에 있으면 합친다, 문 넘김·모르는 페이지·나눔 표시도" {
    var v = std.atomic.Value(u32).init(std.math.maxInt(u32) - 1);
    bump(&v);
    bump(&v);
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), v.load(.monotonic));
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try install(&t, 7, 70, &.{.{ .id = 3, .site = "a.test", .pattern = "*://*/*" }});
    t.tabs[0].set.?.rules[0].hits.store(5, .monotonic);
    try install(&t, 7, 70, &.{.{ .id = 3, .site = "a.test", .pattern = "*://*/*" }}); // 같은 번호의 새 묶음
    t.tabs[0].set.?.rules[0].sw_not_applied.store(2, .monotonic);
    t.noteUnrecorded(70, 1);
    t.tabs[0].full = true;
    t.tabs[0].counts.sw_shared = true;
    var buf: [8]BrowserId = undefined;
    try testing.expectEqual(@as(usize, 1), t.browsersWithHits(&buf).len);
    const h = takeOne(&t, 7).?;
    try testing.expectEqual(@as(u8, 1), h.count);
    try testing.expectEqual(@as(u32, 5), h.entries[0].hits);
    try testing.expectEqual(@as(u32, 2), h.entries[0].sw_not_applied);
    try testing.expect(h.unrecorded == 1 and h.sw_shared_with_unruled_tab);
    try testing.expectEqual(@as(usize, 0), t.browsersWithHits(&buf).len);
    // 20 회 검증: 수는 지금 세대를 싣는다(B N4 — maru 가 모두 버린 세대의 늦은 수를 가른다), 엄격의 리다이렉트 어긋남(A MED-1)도 차이로 보낸다.
    t.tabs[0].counts.strict_redirect_missed = 2;
    t.tabs[0].counts.strict_redirect_bypassed = 1;
    const h2 = takeOne(&t, 7).?;
    try testing.expect(h2.generation == 1 and h2.strict_redirect_missed == 2 and h2.strict_redirect_bypassed == 1 and h2.count == 0);
    try testing.expect(takeOne(&t, 7) == null);
    // 지켜보기가 꺼졌다 — 아직 보내지 않은 탭의 수는 버린다(maru 는 이미 지웠다).
    t.noteUnrecorded(70, 1);
    t.tabs[0].counts.strict_redirect_missed = 1;
    try t.dropRules(testing.allocator, 7);
    t.reap(testing.allocator);
    const h3 = takeOne(&t, 7);
    try testing.expect(h3 == null or (h3.?.unrecorded == 0 and h3.?.strict_redirect_missed == 0));
}

test "W9d③: 사이트 묶기 — 하위 자원은 페이지 호스트(모르면 막지 않고 센다), 주 프레임 홉은 그 홉의 호스트, 종류, 첫 맞는 규칙" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try install(&t, 7, 70, &.{
        .{ .id = 1, .types = nb.typeBits("image").?, .site = "a.test", .pattern = "*://*.cdn.test/*" },
        .{ .id = 2, .site = "a.test", .pattern = "*://*.cdn.test/*" },
        .{ .id = 3, .site = "localhost", .pattern = "http://127.0.0.1/*" },
    });
    const img = u16s("https://x.cdn.test/a.png");
    var a = t.acquire(70, 1, false, 0, 0).?;
    try testing.expectEqual(Verdict{ .block = 1 }, decideTab(&a, &img, 4, false, "a.test"));
    try testing.expectEqual(Verdict{ .block = 2 }, decideTab(&a, &img, 13, false, "app.a.test")); // xhr — 종류 없는 규칙, 하위 도메인 페이지
    try testing.expectEqual(Verdict.pass, decideTab(&a, &img, 13, false, "b.test")); // 다른 사이트에서는 잠든다
    try testing.expectEqual(Verdict.unknown_page, decideTab(&a, &img, 13, false, "")); // 페이지를 모른다
    const nav = u16s("http://127.0.0.1/page");
    try testing.expectEqual(Verdict.pass, decideTab(&a, &nav, 0, true, "")); // 주 프레임 홉 127.0.0.1 — 규칙 3 의 사이트 localhost 가 덮지 않는다
    try testing.expectEqual(Verdict{ .block = 3 }, decideTab(&a, &nav, 13, false, "localhost")); // localhost 페이지의 하위 자원
    t.release(70, &a, .unknown_page, false, 0);
    try testing.expectEqual(@as(u32, 1), t.tabs[0].counts.skipped_unknown_page);
}

test "W9d③: D2 — 사용자 이동의 주소 토큰·다음 이동 토큰(1 초)은 그 이동의 첫 홉에서 번호를 예외로(리다이렉트 홉 포함), 하위 자원·다른 이동은 막는다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try install(&t, 7, 70, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/" }});
    t.committed(7, 70, "a.test", 0);
    const typed = "https://a.test";
    const cef_url = u16s("https://a.test/");
    const canon_cef = canonHash(u16, &cef_url);
    try testing.expectEqual(canonHash(u8, typed), canon_cef); // 주소창 글과 GURL 꼴이 같은 이동으로 읽힌다
    try testing.expectEqual(canonHash(u8, "HTTPS://A.test:443/#x"), canon_cef);
    t.userNavigate(7, 70, canonHash(u8, typed), 1000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, canon_cef, 0, "a.test", 1001));
    var a = t.acquire(70, 55, true, canon_cef, 1002).?;
    try testing.expectEqual(Verdict.user_exempt, decideTab(&a, &cef_url, 0, true, ""));
    t.release(70, &a, .user_exempt, true, canon_cef);
    // 같은 번호의 다음 홉(리다이렉트) — 주소가 달라도 예외.
    const hop = u16s("https://a.test/next");
    try testing.expect(t.beforeBrowse(7, 70, true, true, .other, 0, canonHash(u16, &hop), 0, "a.test", 1003)); // 리다이렉트 홉은 앞 홉의 사용자 표시를 잇는다
    a = t.acquire(70, 55, true, canonHash(u16, &hop), 1003).?;
    try testing.expectEqual(Verdict.user_exempt, decideTab(&a, &hop, 0, true, ""));
    t.release(70, &a, .pass, true, 0);
    // 하위 자원은 막는다.
    a = t.acquire(70, 56, false, 0, 1004).?;
    try testing.expectEqual(Verdict{ .block = 1 }, decideTab(&a, &cef_url, 13, false, "a.test"));
    t.release(70, &a, .pass, false, 0);
    // 다른 이동(다른 번호) — 막는다.
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon_cef, 0, "a.test", 1005));
    a = t.acquire(70, 57, true, canon_cef, 1006).?;
    try testing.expectEqual(Verdict{ .block = 1 }, decideTab(&a, &cef_url, 0, true, ""));
    t.release(70, &a, .{ .block = 1 }, true, canon_cef);
    try testing.expectEqual(@as(u32, 1), t.mainBlockRule(70, canon_cef)); // 귀속(한 번)
    try testing.expectEqual(@as(u32, 0), t.mainBlockRule(70, canon_cef));
    // 뒤로·새로고침 토큰은 다음 주 프레임 이동 하나(그 갈래 — 새로 고침은 새로 고침 이동만), 1 초.
    t.userNavAction(7, 70, .reload, 2000);
    try testing.expect(!t.beforeBrowse(7, 70, false, false, .reload, 9, canon_cef, 0, "a.test", 2001)); // 하위 프레임은 쓰지 않는다
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon_cef, 0, "a.test", 2002)); // 갈래가 다른 이동(에이전트·페이지)은 못 가져간다
    try testing.expect(t.beforeBrowse(7, 70, true, false, .reload, 0, canon_cef, 0, "a.test", 2002));
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .reload, 0, canon_cef, 0, "a.test", 2003)); // 한 번만
    t.userNavAction(7, 70, .history, 3000);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon_cef, 0, "a.test", 3001)); // 다른 주 프레임 이동이 시작됐다 — 시계가 돈다
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .history, 0, canon_cef, 0, "a.test", 4002)); // 그로부터 1 초 지남
    // 아무 주 프레임 이동도 시작되지 않은 동안은 기다린다(옛 문서의 beforeunload 처리기 — 3 차 검증 LOW-A3-3), 상한까지.
    t.userNavAction(7, 70, .history, 10_000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .history, 0, canon_cef, 0, "a.test", 10_000 + start_cap_ms - 1));
    t.userNavAction(7, 70, .history, 50_000);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .history, 0, canon_cef, 0, "a.test", 50_000 + start_cap_ms + 1));
    // 주소 토큰은 다른 주소의 이동에 묶이지 않는다.
    t.userNavigate(7, 70, canonHash(u8, "https://a.test/typed"), 5000);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon_cef, 0, "a.test", 5001));
}

test "W9d③: 진행 중 이동 표 — 8 개까지, 확정·문서 시작·30 초가 지우고, 넘치면 그 탭은 30 초 「모름」, 같은 프레임의 새 홉은 앞 홉을 대신한다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, 11, 101, "a.test", 0);
    _ = t.beforeBrowse(7, 70, true, true, .other, 0, 12, 102, "b.test", 1); // 리다이렉트 홉
    const tab = t.find(7).?;
    try testing.expectEqual(@as(u8, 1), tab.pending_len);
    try testing.expectEqualStrings("b.test", tab.pendingMain().?.host());
    for (0..7) |i| _ = t.beforeBrowse(7, 70, false, false, .other, 100 + i, 20 + i, 200, "f.test", 2);
    try testing.expectEqual(@as(u8, 8), tab.pending_len);
    try testing.expect(!tab.unknownPending(3));
    _ = t.beforeBrowse(7, 70, false, false, .other, 999, 30, 300, "g.test", 3);
    try testing.expect(tab.unknownPending(4));
    try testing.expect(!tab.unknownPending(3 + pending_ttl_ms));
    t.frameSettled(70, false, 999);
    t.committed(7, 70, "b.test", 0);
    try testing.expect(tab.pendingMain() == null);
    try testing.expectEqualStrings("b.test", tab.topHost());
    _ = t.beforeBrowse(7, 70, false, false, .other, 1000, 40, 400, "h.test", 100_000); // 오래된 것은 시한에 지워진다
    try testing.expectEqual(@as(u8, 1), tab.pending_len);
}

test "W9d③: 서비스 워커 길의 규칙 — 종류 없는 규칙만, 사이트가 그 탭의 맨 위 호스트(확정·진행 중 대상) 모두를 덮어야" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try install(&t, 7, 70, &.{
        .{ .id = 1, .types = nb.typeBits("xhr").?, .site = "a.test", .pattern = "https://a.test/api/*" },
        .{ .id = 2, .site = "a.test", .pattern = "https://a.test/api/*" },
    });
    const set = t.tabs[0].set.?;
    const url = u16s("https://a.test/api/x");
    const parts = nb.splitUrl(u16, &url).?;
    var bg: nb.Budget = .{};
    try testing.expectEqual(@as(u32, 2), serviceWorkerRule(set, parts, &.{"a.test"}, &bg).?.id);
    try testing.expect(serviceWorkerRule(set, parts, &.{ "a.test", "b.test" }, &bg) == null); // 다른 사이트로 옮기는 중
    try testing.expect(serviceWorkerRule(set, parts, &.{""}, &bg) == null); // 모르는 맨 위
    try testing.expect(serviceWorkerRule(set, parts, &.{}, &bg) == null);
}

test "W9d③: 출처 해시 — 주소에서 낸 것과 출처 글에서 낸 것이 같다(기본 포트·대소문자), http(s) 밖은 0" {
    const u = u16s("https://User:pw@A.test/x?y");
    try testing.expectEqual(originHash("https://a.test"), urlOriginHash(u16, &u));
    try testing.expectEqual(originHash("http://127.0.0.1:5555"), urlOriginHash(u8, "http://127.0.0.1:5555/s/page"));
    try testing.expect(urlOriginHash(u8, "http://127.0.0.1:5555/") != urlOriginHash(u8, "http://127.0.0.1:5556/"));
    try testing.expectEqual(@as(u64, 0), urlOriginHash(u8, "about:blank"));
    var hb: [msg.max_net_host_bytes]u8 = undefined;
    try testing.expectEqualStrings("a.test", urlHost(u16, &u, &hb));
}

test "W9d③ 변이: 번호 0(speculation) 이동은 예외가 아니다, 묶은 토큰·주소 토큰은 시한이 지나면 듣지 않는다, 확정은 진행 중 주 프레임 이동을 지운다, 서비스 워커 길의 귀속은 그 주소만, 목록 밖에서 만든 자리는 나중 번호를 얻는다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try install(&t, 7, 70, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/" }});
    t.committed(7, 70, "a.test", 0);
    const url = u16s("https://a.test/");
    const canon = canonHash(u16, &url);
    // 사용자 이동이 한 번도 없었던 탭의 번호 0 주 프레임 이동(speculation prerender — 실측 J-B11) — 예외 번호의 처음 값 0 과 같아도 막는다.
    var a = t.acquire(70, 0, true, canon, 10).?;
    try testing.expectEqual(Verdict{ .block = 1 }, decideTab(&a, &url, 0, true, ""));
    t.release(70, &a, .{ .block = 1 }, true, canon);
    // 묶은 토큰(`bound_until` — url_token_ms)이 지난 첫 홉은 예외가 아니다.
    t.userNavigate(7, 70, canon, 1000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, canon, 0, "a.test", 1001));
    a = t.acquire(70, 41, true, canon, 1001 + url_token_ms + 1).?;
    try testing.expectEqual(Verdict{ .block = 1 }, decideTab(&a, &url, 0, true, ""));
    t.release(70, &a, .{ .block = 1 }, true, canon);
    // 주소 토큰도 시계가 돈 뒤 url_token_ms 가 지나면(또는 아무 이동도 없이 상한이 지나면) 그 이동을 사용자 이동으로 읽지 않는다.
    t.userNavigate(7, 70, canon, 20_000);
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, canon +% 1, 0, "a.test", 20_001);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon, 0, "a.test", 20_001 + url_token_ms + 1));
    t.userNavigate(7, 70, canon, 60_000);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, canon, 0, "a.test", 60_000 + start_cap_ms + 1));
    // 확정이 진행 중 주 프레임 이동을 지운다(넘침으로 지워진 것이 아니라).
    const tab = t.find(7).?;
    try testing.expect(tab.pendingMain() != null);
    t.committed(7, 70, "a.test", 0);
    try testing.expect(tab.pendingMain() == null);
    // 서비스 워커 길의 귀속은 진행 중 주 프레임 이동의 주소일 때만(앞의 탭 길 귀속은 먼저 비운다).
    _ = t.mainBlockRule(70, canon);
    const other = u16s("https://a.test/other");
    _ = t.beforeBrowse(7, 70, true, false, .other, 0, canon, 0, "a.test", 30_000);
    t.noteServiceWorkerMainBlock(70, canonHash(u16, &other), 1);
    try testing.expectEqual(@as(u32, 0), t.mainBlockRule(70, canonHash(u16, &other)));
    t.noteServiceWorkerMainBlock(70, canon, 1);
    try testing.expectEqual(@as(u32, 1), t.mainBlockRule(70, canon));
    // 목록 밖(번호 0)으로 만든 자리 — 나중에 번호를 알면 그 번호로 찾는다(수·토큰이 그 탭에 간다).
    t.committed(0, 80, "b.test", 0);
    try testing.expect(t.find(9) == null);
    t.userNavAction(9, 80, .reload, 0);
    try testing.expectEqual(@as(c_int, 80), t.find(9).?.cef_id);
}

test "W9d③ 3 차 검증 NEW-B3-1(B3 R12 LATE-RETAG): 탭 몫 수는 센 때의 세대를 싣는다 — 보내기 전에 빈 net_block 이 와도, 옛 묶음을 쥔 요청이 그 뒤에 놓아도 옛 세대로(maru 의 바닥이 버린다), 새 세대의 수는 따로, 자리가 차면 앞선 세대로 합친다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try install(&t, 7, 70, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/blk" }}); // 세대 1
    t.committed(7, 70, "a.test", 0);
    t.noteUnrecorded(70, 1); // 세대 1 에서 센 문 넘김(보내기 task 는 10 ms 뒤)
    var a = t.acquire(70, 11, false, 0, 0).?; // IO 스레드가 세대 1 의 묶음을 쥐었다
    try t.swap(testing.allocator, t.findCef(70).?, null, "", 2); // maru 가 탭을 비웠다(빈 net_block 세대 2)
    const url = u16s("https://a.test/blk/x");
    const v = decideTab(&a, &url, 4, false, ""); // 페이지를 몰라 막지 않고 센다 — 옛 규칙으로
    try testing.expectEqual(Verdict.unknown_page, v);
    t.release(70, &a, v, false, 0);
    t.noteUnrecorded(70, 1); // 세대 1 의 묶음으로 막은 요청을 바뀐 뒤 센다(`tabSelect` 가 준 세대)
    const h = takeOne(&t, 7).?;
    try testing.expect(h.generation == 1 and h.unrecorded == 2 and h.skipped_unknown_page == 1); // 전에는 세대 2(빈 세대)를 달았다
    try testing.expect(takeOne(&t, 7) == null);
    // 지난 세대와 지금 세대의 수가 함께 있으면 두 frame — 앞선 세대부터.
    t.noteUnrecorded(70, 1);
    t.noteUnrecorded(70, 2);
    var out: [max_frames]msg.NetBlockHits = undefined;
    const n = t.takeHits(7, &out);
    try testing.expect(n == 2 and out[0].generation == 1 and out[0].unrecorded == 1 and out[1].generation == 2 and out[1].unrecorded == 1);
    // 지난 세대 자리가 차면(넷) 다섯째는 가장 앞선 세대의 자리에 합쳐 그 앞선 세대로 간다(버리는 쪽).
    for ([_]u32{ 10, 11, 12, 13, 9 }) |g| t.noteUnrecorded(70, g);
    const m = t.takeHits(7, &out);
    var total: u32 = 0;
    for (out[0..m]) |f| total += f.unrecorded;
    try testing.expect(m == max_stale and total == 5 and out[0].generation == 9 and out[0].unrecorded == 2);
    // 세대가 u32 를 돌아도 앞선 것을 고른다(N-A3-4).
    try testing.expect(genBefore(std.math.maxInt(u32), 1) and !genBefore(1, std.math.maxInt(u32)));
    // 규칙의 수도 그 묶음의 세대로 — 세대 20 의 규칙이 막은 수가 빈 세대 21 뒤에 나가도 세대 20 의 frame(전에는 지금 세대를 달았다).
    const c20 = try compile(testing.allocator, blockMsg(7, 20, &.{.{ .id = 5, .site = "a.test", .pattern = "https://a.test/blk" }}, ""));
    try t.swap(testing.allocator, t.findCef(70).?, c20.set, "", 20);
    var b = t.acquire(70, 12, false, 0, 0).?;
    const vb = decideTab(&b, &url, 4, false, "a.test");
    try t.swap(testing.allocator, t.findCef(70).?, null, "", 21);
    t.release(70, &b, vb, false, 0);
    const hb = takeOne(&t, 7).?;
    try testing.expect(vb == .block and hb.generation == 20 and hb.count == 1 and hb.entries[0].rule_id == 5 and hb.entries[0].hits == 1);
    t.reap(testing.allocator);
}

test "W9d③ 3 차 검증 N-B3-d: 설정 agent-network-full 이 꺼진 탭은 켬 몫(나눔·다른 사이트 리다이렉트·규칙의 서비스 워커 수)을 보내지 않는다 — 끄면 쌓인 것도 버리고, 켠 뒤의 것만" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try install(&t, 7, 70, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/blk" }});
    t.setFull(7, 70, true);
    const r = &t.tabs[0].set.?.rules[0];
    bump(&r.sw_not_applied);
    t.tabs[0].counts.sw_shared = true;
    t.tabs[0].counts.strict_redirect_bypassed = 1;
    t.tabs[0].counts.strict_redirect_missed = 1;
    t.setFull(7, 70, false); // 끈다 — 켬 동안 쌓인 켬 몫은 버린다
    bump(&r.sw_hits); // 끈 동안 셌다면(sidecar 는 세지 않지만 보낼 때도 본다)
    bump(&r.hits);
    const h = takeOne(&t, 7).?;
    try testing.expect(!h.sw_shared_with_unruled_tab and h.strict_redirect_bypassed == 0 and h.strict_redirect_missed == 1);
    try testing.expect(h.count == 1 and h.entries[0].hits == 1 and h.entries[0].sw_hits == 0 and h.entries[0].sw_not_applied == 0);
    t.setFull(7, 70, true);
    bump(&r.sw_hits);
    const h2 = takeOne(&t, 7).?;
    try testing.expect(h2.count == 1 and h2.entries[0].sw_hits == 1); // 켠 뒤의 것만(끈 동안의 것은 보낸 것으로 넘겼다)
}

test "W9d③ 3 차 검증 변이(N-B3-d): 켬 그대로의 net_watch 는 쌓인 켬 몫을 지우지 않는다, 보내기 전(10 ms 안)에 끄고 다시 켜도 끌 때 버린 켬 몫(지금·지난 세대, 규칙의 서비스 워커 수)은 되살아나지 않는다, 끈 동안 놓인 켬 몫은 보낼 때도 거른다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try install(&t, 7, 70, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/blk" }});
    t.setFull(7, 70, true);
    const r = &t.tabs[0].set.?.rules[0];
    // 켬 그대로 다시(호스트만 바뀐 net_watch) — 쌓인 것은 그대로 간다.
    bump(&r.sw_hits);
    t.tabs[0].counts.sw_shared = true;
    t.tabs[0].counts.strict_redirect_bypassed = 1;
    t.setFull(7, 70, true);
    const h0 = takeOne(&t, 7).?;
    try testing.expect(h0.sw_shared_with_unruled_tab and h0.strict_redirect_bypassed == 1 and h0.count == 1 and h0.entries[0].sw_hits == 1);
    // 켬 동안 센 켬 몫(지금 세대·지난 세대 자리) → 끔 → 보내기 전에 다시 켬: 끌 때 버렸다.
    bump(&r.sw_hits);
    bump(&r.sw_not_applied);
    t.tabs[0].counts.sw_shared = true;
    t.tabs[0].counts.strict_redirect_bypassed = 1;
    t.tabs[0].countsFor(0).sw_shared = true;
    t.setFull(7, 70, false);
    t.setFull(7, 70, true);
    try testing.expect(takeOne(&t, 7) == null);
    // 끈 동안 놓인 켬 몫(원천은 세지 않는다 — 보낼 때도 거른다), 탭 길 수는 간다.
    t.setFull(7, 70, false);
    t.tabs[0].counts.sw_shared = true;
    t.tabs[0].counts.strict_redirect_bypassed = 1;
    t.tabs[0].counts.unrecorded = 1;
    const h1 = takeOne(&t, 7).?;
    try testing.expect(!h1.sw_shared_with_unruled_tab and h1.strict_redirect_bypassed == 0 and h1.unrecorded == 1);
}

test "W9d③ 3 차 검증 변이(NEW-B3-1): 보내는 frame 은 앞선 세대부터 — 은퇴 묶음(세대 20)의 규칙 수가 지금 세대(21)의 탭 몫보다 뒤에 모여도" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const tab = t.ensure(7, 70).?;
    const c20 = try compile(testing.allocator, blockMsg(7, 20, &.{.{ .id = 5, .site = "a.test", .pattern = "https://a.test/blk" }}, ""));
    try t.swap(testing.allocator, tab, c20.set, "", 20);
    bump(&tab.set.?.rules[0].hits);
    const c21 = try compile(testing.allocator, blockMsg(7, 21, &.{.{ .id = 6, .site = "a.test", .pattern = "https://a.test/other" }}, ""));
    try t.swap(testing.allocator, tab, c21.set, "", 21);
    t.noteUnrecorded(70, 21);
    var out: [max_frames]msg.NetBlockHits = undefined;
    const n = t.takeHits(7, &out);
    try testing.expect(n == 2);
    try testing.expect(out[0].generation == 20 and out[0].count == 1 and out[0].entries[0].rule_id == 5 and out[0].entries[0].hits == 1);
    try testing.expect(out[1].generation == 21 and out[1].unrecorded == 1 and out[1].count == 0);
    t.reap(testing.allocator);
    try testing.expectEqual(@as(usize, 0), t.retired.items.len);
}

test "W9d③ 3 차 검증 N-A3-2: 서비스 워커 요청의 「적용 안 됨」 은 요청 번호마다 한 번(리다이렉트 홉마다 불린다), 번호 0 은 가를 수 없어 늘 센다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try testing.expect(t.firstNotApplied(41));
    try testing.expect(!t.firstNotApplied(41)); // 302 뒤 둘째 홉
    try testing.expect(t.firstNotApplied(42));
    try testing.expect(t.firstNotApplied(0) and t.firstNotApplied(0));
    for (0..counted_requests) |i| _ = t.firstNotApplied(1000 + i); // 오래된 번호는 밀려난다
    try testing.expect(t.firstNotApplied(41));
}

test "W9d④ §13 P2-1: D2 의 소비는 규칙과 무관하다 — 막기 규칙이 없는 탭(가짜만·둘 다 없음)에서도 첫 홉이 예외가 되고, 같은 번호는 몇 번 물어도 같은 답, 번호 0 은 쓰지 않는다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    // 규칙 묶음이 없다 — `acquire` 는 null 이지만 공용 답(`consumeExempt`)은 선다(W9d③ 은 묶음이 없으면 토큰을 보기 전에 돌아갔다).
    t.userNavigate(7, 70, 111, 1000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 111, 0, "a.test", 1001));
    try testing.expect(t.acquire(70, 55, true, 111, 1002) == null);
    try testing.expect(!t.consumeExempt(70, 0, true, 111, 1002)); // speculation(번호 0)은 쓰지 않는다 — 묶음은 남는다(20 회 검증 A N6)
    try testing.expect(t.consumeExempt(70, 55, true, 111, 1002));
    try testing.expect(t.consumeExempt(70, 55, true, 222, 1003)); // 같은 번호의 다음 홉 — 주소가 달라도
    try testing.expect(!t.consumeExempt(70, 55, false, 111, 1003)); // 하위 자원은 예외가 아니다
    try testing.expect(!t.consumeExempt(70, 56, true, 111, 1004)); // 묶음은 첫 홉 하나
    // 처리기 고르기가 먼저 묻고 막기의 `acquire` 가 다시 물어도 같은 답(막기·가짜 둘 다 있는 탭 — 막기가 토큰을 먹어 가짜가 모르던 꼴의 회귀).
    try install(&t, 7, 70, &.{.{ .id = 1, .site = "a.test", .pattern = "https://a.test/*" }});
    t.userNavigate(7, 70, 333, 2000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 333, 0, "a.test", 2001));
    try testing.expect(t.consumeExempt(70, 77, true, 333, 2002));
    var a = t.acquire(70, 77, true, 333, 2002).?;
    try testing.expect(a.user_exempt);
    t.release(70, &a, .user_exempt, true, 333);
}

test "W9d④: 엄격의 원하는 값 — 막기·가짜의 엄격 사이트 어느 쪽이든 덮으면, 둘 다 비면 꺼짐" {
    var tab: Tab = .{};
    try testing.expect(!tab.anyStrict() and !tab.strictCovers("a.test"));
    tab.setMockStrict("a.test");
    try testing.expect(tab.anyStrict() and tab.strictCovers("x.a.test") and !tab.strictCovers("b.test") and !tab.strictCovers(""));
    @memcpy(tab.strict_site_buf[0..6], "b.test");
    tab.strict_site_len = 6;
    try testing.expect(tab.strictCovers("b.test") and tab.strictCovers("a.test"));
    tab.setMockStrict("");
    try testing.expect(tab.anyStrict() and !tab.strictCovers("a.test") and tab.strictCovers("b.test"));
}

test "W9d④ v1 SEVERE-2(사용자 결정 2026-11-11 「고침」): 에이전트의 DevTools 호출은 사용자의 토큰(친 주소·새로 고침·뒤로)을 거두지 않는다 — 다툼으로 두고 그 창 안의 맞는 이동은 모두 사용자 것(같은 주소로 겹친 에이전트 이동도 진짜), 새 문서가 서면 끝, 다툼이 없으면 한 번만, 다른 곳으로 가는 에이전트 이동은 그대로 거둔다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    // 친 주소 + 곧 에이전트의 `Runtime.evaluate`(읽기 목록 밖) — 거두지 않는다.
    t.userNavigate(7, 70, 111, 1000);
    t.agentDevtoolsCall(70, 1001);
    try testing.expect(t.find(7).?.contested and t.find(7).?.url_token == 111);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 111, 0, "a.test", 1002));
    try testing.expect(t.consumeExempt(70, 41, true, 111, 1003));
    // 같은 주소로 겹친 둘째 이동(누구 것인지 모른다) — 그 창 안이면 그것도 사용자 것, 첫 홉도 예외(묶음을 남겼다).
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 111, 0, "a.test", 1004));
    try testing.expect(t.consumeExempt(70, 42, true, 111, 1005));
    // 밀려 끊긴 쪽의 끊김이 남은 쪽의 묶음을 지우지 않는다.
    t.mainAborted(70, 111);
    try testing.expect(t.consumeExempt(70, 43, true, 111, 1006));
    // 다른 주소의 이동은 토큰을 가져가지 못한다(주소에 묶임).
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, 999, 0, "a.test", 1007));
    // 새 문서가 섰다 — 다툼의 창이 끝난다.
    t.frameSettled(70, true, 0);
    try testing.expect(!t.find(7).?.contested);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, 111, 0, "a.test", 1008));
    // 다툼 없이(에이전트 호출 없음)는 전처럼 한 번만.
    t.userNavigate(7, 70, 222, 2000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 222, 0, "a.test", 2001));
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, 222, 0, "a.test", 2002));
    // 새로 고침 + 에이전트 호출 — 새로 고침 이동은 사용자 것.
    t.userNavAction(7, 70, .reload, 3000);
    t.agentDevtoolsCall(70, 3001);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .reload, 0, 333, 0, "a.test", 3002));
    t.frameSettled(70, true, 0);
    // 떠나기 확인이 길게 도는 옛 문서(이동이 아직 시작되지 않았다) — 그 사이의 에이전트 호출도 거두지 않는다.
    t.userNavigate(7, 70, 444, 4000);
    t.agentDevtoolsCall(70, 4100);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 444, 0, "a.test", 4500));
    t.frameSettled(70, true, 0);
    // 산 토큰이 없으면 다툼도 없다.
    t.agentDevtoolsCall(70, 5000);
    try testing.expect(!t.find(7).?.contested);
    // 에이전트·복원의 navigate — 친 주소와 같은 주소면 다툼(둘 다 진짜), 다른 주소면 거둔다.
    t.userNavigate(7, 70, 555, 6000);
    t.agentNavigateTo(70, 555, 6001);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 555, 0, "a.test", 6002));
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 555, 0, "a.test", 6003));
    t.frameSettled(70, true, 0);
    t.userNavigate(7, 70, 666, 7000);
    t.agentNavigateTo(70, 667, 7001);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, 666, 0, "a.test", 7002));
    // 에이전트의 새로 고침 — 산 새로 고침 토큰이면 다툼, 뒤로(다른 곳)·멈춤은 거둔다.
    t.userNavAction(7, 70, .reload, 8000);
    t.agentReload(70, 8001);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .reload, 0, 333, 0, "a.test", 8002));
    t.frameSettled(70, true, 0);
    t.userNavAction(7, 70, .history, 9000);
    t.agentReload(70, 9001); // 기록 토큰은 새로 고침의 것이 아니다 — 거둔다
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .history, 0, 333, 0, "a.test", 9002));
    t.userNavAction(7, 70, .reload, 10_000);
    t.agentNavigate(70);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .reload, 0, 333, 0, "a.test", 10_001));
    // 다툼의 창도 시계가 있다 — 사용자 이동의 문서가 서지 않아도 그 이동을 「가는 중」 으로 보는 것은 30 초(`start_cap_ms`)까지.
    t.userNavigate(7, 70, 777, 11_000);
    t.agentDevtoolsCall(70, 11_001);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 777, 0, "a.test", 11_002));
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 777, 0, "a.test", 11_002 + url_token_ms + 1));
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, 777, 0, "a.test", 11_002 + url_token_ms + 1 + start_cap_ms + 1));
}

test "W9d④ v1 SEVERE-2 실측 뒤: 사용자 이동이 먼저 `on_before_browse` 에서 토큰을 써 묶인 뒤(가는 중)의 에이전트 호출·같은 주소 이동 — 다툼이면 묶인 사용자 이동과 같은 주소의 이동도 사용자 것, 다른 주소는 아니다, 새 문서가 서면 끝" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    // 친 주소 → 곧 `on_before_browse`(토큰을 쓴다) → 에이전트 eval(`location.href` 같은 주소) → 그 이동의 `on_before_browse`.
    t.userNavigate(7, 70, 111, 1000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 111, 0, "a.test", 1001));
    t.agentDevtoolsCall(70, 1002);
    try testing.expect(t.find(7).?.contested); // 묶인 이동이 살아 있다
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 111, 0, "a.test", 1003));
    try testing.expect(t.consumeExempt(70, 51, true, 111, 1004));
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, 222, 0, "a.test", 1005)); // 다른 주소는 아니다(묶음도 대신한다)
    t.frameSettled(70, true, 0);
    // wire 의 에이전트 navigate 가 사용자 이동의 `on_before_browse` 뒤에 왔다(같은 주소).
    t.userNavigate(7, 70, 333, 2000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 333, 0, "a.test", 2001));
    t.agentNavigateTo(70, 333, 2002);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 333, 0, "a.test", 2003));
    t.frameSettled(70, true, 0);
    // 같은 갈래(묶인 뒤)의 에이전트 새로 고침 — 지금 문서로 겹친다.
    t.userNavAction(7, 70, .reload, 3000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .reload, 0, 444, 0, "a.test", 3001));
    t.agentReload(70, 3002);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .reload, 0, 444, 0, "a.test", 3003));
    t.frameSettled(70, true, 0);
    // 다툼 없이(에이전트 호출 없음) 묶인 뒤의 같은 주소 이동은 사용자 것이 아니다(전과 같다).
    t.userNavigate(7, 70, 555, 4000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 555, 0, "a.test", 4001));
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, 555, 0, "a.test", 4002));
}

test "W9d④ v1 SEVERE-2 실측 뒤 2: 사용자 이동이 토큰·묶음을 다 쓰고(첫 홉까지) 느린 서버로 가는 중의 에이전트 eval — 같은 주소의 그 이동도 사용자 것, 다른 곳으로 가는 이동이 대신하면·문서가 서면·끊기면 끝" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    t.userNavigate(7, 70, 111, 1000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 111, 0, "a.test", 1001));
    try testing.expect(t.consumeExempt(70, 61, true, 111, 1002)); // 첫 홉 — 토큰·묶음을 다 썼다
    t.agentDevtoolsCall(70, 1100); // 서버가 느리다 — 옛 문서에서 에이전트 eval
    try testing.expect(t.find(7).?.contested);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 111, 0, "a.test", 1101)); // `location.href` 같은 주소
    try testing.expect(t.consumeExempt(70, 62, true, 111, 1102));
    t.frameSettled(70, true, 0);
    try testing.expect(!t.find(7).?.contested and t.find(7).?.user_nav_url == 0);
    // 다른 곳으로 가는 이동이 사용자 이동을 대신했다 — 그 뒤 같은 주소의 이동은 사용자 것이 아니다.
    t.userNavigate(7, 70, 222, 2000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 222, 0, "a.test", 2001));
    t.agentDevtoolsCall(70, 2002);
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, 999, 0, "a.test", 2003));
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, 222, 0, "a.test", 2004));
    t.frameSettled(70, true, 0);
    // 다툼 없이는 가는 중인 사용자 이동도 다툼을 만들지 않는다(에이전트 호출이 없으면 같은 주소 둘째 이동은 그대로).
    t.userNavigate(7, 70, 333, 3000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 333, 0, "a.test", 3001));
    try testing.expect(!t.beforeBrowse(7, 70, true, false, .other, 0, 333, 0, "a.test", 3002));
    // 끊긴 사용자 이동(204·다운로드)은 가는 중이 아니다 — 그 뒤 에이전트 호출은 다툼을 만들지 않는다.
    t.userNavigate(7, 70, 444, 4000);
    try testing.expect(t.beforeBrowse(7, 70, true, false, .other, 0, 444, 0, "a.test", 4001));
    try testing.expect(t.consumeExempt(70, 63, true, 444, 4002));
    t.mainAborted(70, 444);
    t.agentDevtoolsCall(70, 4003);
    try testing.expect(!t.find(7).?.contested);
}
