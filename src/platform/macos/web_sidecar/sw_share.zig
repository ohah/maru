//! 서비스 워커 길의 막기 판정(W9d③ D3(a) — docs/plans/web-osr-backend.md 「W9d③ 결정·실측」 §6.2). CEF 를 모른다 — 브라우저마다의 사실(그 출처를
//! 보이는가·모르는가·쥔 규칙·사용자 이동)은 `network.zig` 가 IO 스레드에서 CEF 프레임 API 로 나열해 준다(실측 7–22 µs).
//!
//! 왜 「모든 탭」 인가(사용자 결정 D3 2026-10-21 — 서비스 워커는 켜 둔다): 서비스 워커는 출처 하나에 하나라 그 출처를 보이는 탭들이 나눠 쓴다.
//! 서비스 워커가 대신 보낸 요청(공유 context 처리기 — 브라우저가 없다)은 어느 탭의 것인지 모른다 — 에이전트 탭의 규칙으로 막으면 같은 출처를
//! 보이는 사용자 탭의 요청까지 막힌다. 그래서 그 출처를 보이는 살아 있는 탭 **모두**가 맞는 규칙을 쥘 때만 막는다.
//!   - T(O) 가 비면 막지 않는다(§12 P1-1 — 빈 집합의 「모두」 는 참이다: 탭이 닫힌 뒤 남은 서비스 워커의 동기화·푸시 요청을 막게 된다).
//!   - 탭마다의 몫(`role` — 2 차 검증 MED-A2-1 이 정한 규칙):
//!       · **O 를 보인다고 증명된 탭**(확정된 프레임 주소나 진행 중 이동 기록의 출처가 O)만 T(O) 의 몫이다. 그 탭이 맞는 규칙을 쥐면 덮였다 — 그
//!         탭에 모르는 프레임이 있어도(20 회 검증 A MED-2: 늦게 뜨는 iframe 하나가 규칙을 쥔 그 탭의 막기를 말없이 껐다; 그 탭의 어느 문서든
//!         규칙의 사이트 안이라 규칙이 그 요청을 막는 것이 맞다). 맞는 규칙이 없으면 거부한다.
//!       · **O 를 보인다고 증명되지 않았지만 모르는 프레임이 있는 탭**(빈 주소 프레임·프레임 64 개 넘게·진행 중 이동 표가 넘침·목록 밖 브라우저·
//!         브라우저 목록이 넘침): 맞는 규칙을 쥐었으면 **빠진다** — 덮지도 거부하지도 않는다(2 차 검증 MED-A2-1: 덮는 몫으로 넣자 아무도 보이지 않는
//!         출처의 요청이 막히고 — 빈 T 규칙이 깨짐 — 무관한 탭에 「적용 안 됨」 이 세어졌다; 그 모르는 프레임이 O 라 해도 그 탭의 규칙이 그 요청을
//!         막는 것이 맞으니 지킬 것이 없다 — 단 진행 중 이동 표가 넘친 탭은 잊은 이동이 규칙이 잠든 다른 사이트로 가는 중일 수 있어 규칙을 쥐지 않은
//!         것으로 친다). 맞는 규칙이 없으면 **거부권**(보수 규칙 — P1-3·4: 그 프레임이 O 일 수 있고 그러면 막힐 요청의
//!         주인이다). 거부하면 덮는 탭마다 「적용 안 됨」 으로 센다 — 말없이 지나가지 않는다. 그런 탭만 있으면(덮는 탭이 없으면) 막을 것도 셀 것도 없다.
//!       · O 를 보이지 않고 모르는 것도 없는 탭은 빠진다.
//!   - 그 탭의 진행 중 사용자 이동이 이 요청이면(서비스 워커가 그 이동을 대신 받아 온다 — 실측 sw3) 막지 않는다(D2 — P1-12).
//!   - 막지 못했는데 맞는 규칙을 쥔 탭이 있으면 「적용 안 됨」(`sw_not_applied`)을 센다.
//! 출처를 보이는가(T(O) 의 몫)는 확정된 프레임 주소(나열)와 `on_before_browse` 가 적은 진행 중 이동(나열은 옮기는 중인 탭의 옛 주소를 보인다 —
//! 실측 D3(i), P1-2)의 합이다. 나열은 (출처, 위상 세대)로 캐시한다 — UI 의 사건(이동 시작·주소·문서 시작·오류·프레임 떨어짐·만들어짐·닫힘)이
//! 세대를 올린다(§12 P2-4 — 맞는 서비스 워커 요청이 쏟아져도 요청마다 나열하지 않게).
//!
//! 시험이 증명하는 것: 빈 T, 모두 쥠, 하나라도 규칙 없음·모름, 사용자 이동 예외, 「적용 안 됨」 의 대상, 탭의 몫(`role`), 캐시의 세대·출처·자리 넘김.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const BrowserId = protocol.message.BrowserId;

/// 나열하는 브라우저 수 상한 — 넘으면 남은 브라우저는 「모름」 하나로 친다(거부권).
pub const max_browsers: usize = 32;
/// 브라우저 하나에서 보는 프레임 수 상한 — 넘으면 그 브라우저는 「모름」.
pub const max_frames: usize = 64;
/// 캐시 자리.
pub const cache_slots: usize = 8;

/// 확정된 주소로 본 브라우저 하나(나열의 결과 — 요청 주소와 무관해 캐시한다).
pub const Member = struct {
    /// CEF 브라우저 번호(IO 스레드는 maru 의 목록을 읽지 않는다 — 막기 표가 CEF 번호로 탭을 찾는다).
    cef_id: c_int = 0,
    /// 어느 프레임이든(주·하위) 확정된 주소의 출처가 O 다.
    shows: bool = false,
    /// 빈 주소 프레임·프레임 상한 넘음·읽지 못함.
    unknown: bool = false,
    /// O 의 주소인 하위 프레임이 있지만 잊힌 오류 페이지일 수 있다(오류 페이지 표시를 다 적지 못한 탭 — 5 차 검증 MED, `net_block_table.ErrSnapshot`).
    maybe: bool = false,
};

/// 출처 하나의 나열 결과.
pub const Membership = struct {
    count: u8 = 0,
    members: [max_browsers]Member = undefined,
    /// 브라우저가 상한을 넘었다(나머지는 「모름」).
    overflow: bool = false,

    pub fn slice(self: *const Membership) []const Member {
        return self.members[0..self.count];
    }

    pub fn add(self: *Membership, m: Member) void {
        if (self.count == self.members.len) {
            self.overflow = true;
            return;
        }
        self.members[self.count] = m;
        self.count += 1;
    }
};

/// (출처 해시, 위상 세대) → 나열 결과. 세대가 다르면 쓰지 않는다.
pub const Cache = struct {
    origins: [cache_slots]u64 = @splat(0),
    generations: [cache_slots]u64 = @splat(0),
    values: [cache_slots]Membership = undefined,
    next: usize = 0,

    pub fn get(self: *const Cache, origin: u64, generation: u64) ?Membership {
        for (self.origins, self.generations, 0..) |o, g, i| if (o == origin and o != 0 and g == generation) return self.values[i];
        return null;
    }

    pub fn put(self: *Cache, origin: u64, generation: u64, m: Membership) void {
        for (self.origins, 0..) |o, i| if (o == origin) {
            self.generations[i] = generation;
            self.values[i] = m;
            return;
        };
        self.origins[self.next] = origin;
        self.generations[self.next] = generation;
        self.values[self.next] = m;
        self.next = (self.next + 1) % cache_slots;
    }
};

/// T(O) 안의 탭 하나에 대해 판정에 쓰는 사실(요청 주소에 따라 다르다 — 캐시하지 않는다).
pub const TabFacts = struct {
    browser: BrowserId,
    /// 모르는 것이 있는 탭(거부권 몫이거나 모르는 프레임이 있는 보이는 탭) — 판정은 `rule_id` 만 본다(쥐었으면 덮였다, 아니면 거부).
    unknown: bool = false,
    /// 이 탭의 진행 중 사용자 이동이 이 요청 주소다(D2).
    user_nav: bool = false,
    /// 이 탭이 쥔 맞는 규칙(종류 없음·패턴·사이트가 그 탭의 맨 위 호스트 모두를 덮음)의 번호(0 = 없음)와 표 안의 자리(부른 쪽이 수를 올린다).
    rule_id: u32 = 0,
    rule_slot: u8 = 0,
};

pub const Outcome = enum {
    /// T(O) 가 비었다 — 막지 않고 세지 않는다.
    empty,
    /// 사용자 이동이다(D2) — 막지 않는다.
    user_nav,
    /// 모든 탭이 맞는 규칙을 쥐었다 — 막는다(탭마다 그 규칙의 `sw_hits`).
    block,
    /// 맞는 규칙을 쥔 탭이 있지만 규칙 없는 탭(모르는 탭 포함)이 있다 — 막지 않는다(규칙을 쥔 탭마다 `sw_not_applied`).
    not_applied,
    /// 맞는 규칙을 쥔 탭이 없다.
    pass,
};

/// 나열·진행 중 이동으로 본 탭 하나의 T(O) 몫(위 머리말의 규칙 — 부른 쪽은 `skip` 이면 그 탭을 판정에 넣지 않는다).
pub const Role = enum {
    /// 빠진다(O 를 보이지 않고 모르는 것도 없다, 또는 보인다고 증명되지 않았고 맞는 규칙을 쥐었다, 또는 「보일지도」 인데 맞는 규칙이 없다).
    skip,
    /// O 를 보인다(맞는 규칙을 쥐었으면 덮고, 아니면 거부한다).
    shows,
    /// 보인다고 증명되지 않았지만 모르는 프레임이 있고 맞는 규칙이 없다 — 거부권만.
    veto,
};

/// `maybe` — 「보일지도」(오류 페이지일 수 있는 O 주소 하위 프레임 — 5 차 검증 MED): 맞는 규칙을 쥐었으면 덮는 몫(그 탭이 O 를 보이지 않으면 아무도
/// 보이지 않는 출처의 요청을 막을 수 있다 — 넘침), 아니면 빠진다(그 탭이 O 를 보이면 다른 탭의 규칙이 그 탭 몫의 요청을 막을 수 있다 — 넘침). 어느
/// 쪽도 새지 않는다: 덮어서 막기를 끄지도, 거부해서 다른 탭의 규칙을 「적용 안 됨」 으로 만들지도 않는다(전에는 잊힌 오류 프레임을 「보인다」 로 쳐
/// 규칙 없는 탭의 거부권이 정말 보이는 탭의 막기를 껐다 — 실측 n=9). 「모름」 의 거부권은 그대로다.
pub fn role(shows: bool, unknown: bool, ruled: bool, maybe: bool) Role {
    if (shows) return .shows;
    if (maybe and ruled) return .shows;
    if (unknown and !ruled) return .veto;
    return .skip;
}

pub fn decide(facts: []const TabFacts) Outcome {
    if (facts.len == 0) return .empty;
    for (facts) |f| if (f.user_nav) return .user_nav;
    var any_rule = false;
    var all = true;
    for (facts) |f| {
        // 규칙을 쥔 탭은 모르는 프레임이 있어도 덮였다 — 「모름」 은 규칙 없는 탭에게만 거부권이다(MED-2).
        if (f.rule_id != 0) any_rule = true else all = false;
    }
    if (all) return .block;
    return if (any_rule) .not_applied else .pass;
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "W9d③: 서비스 워커 길 — 빈 T 는 막지 않는다, 모두 쥐면 막는다, 규칙 없는·모르는 탭이 하나라도 있으면 「적용 안 됨」, 사용자 이동은 예외" {
    try testing.expectEqual(Outcome.empty, decide(&.{}));
    try testing.expectEqual(Outcome.block, decide(&.{ .{ .browser = 1, .rule_id = 3 }, .{ .browser = 2, .rule_id = 9 } }));
    try testing.expectEqual(Outcome.not_applied, decide(&.{ .{ .browser = 1, .rule_id = 3 }, .{ .browser = 2 } }));
    try testing.expectEqual(Outcome.not_applied, decide(&.{ .{ .browser = 1, .rule_id = 3 }, .{ .browser = 0, .unknown = true } }));
    try testing.expectEqual(Outcome.pass, decide(&.{ .{ .browser = 1 }, .{ .browser = 2, .unknown = true } }));
    // 20 회 검증 A MED-2: 규칙을 쥔 탭은 빈 주소 프레임(늦게 뜨는 iframe)이 있어도 덮였다 — 혼자면 막고, 규칙 없는 탭과 함께면 「적용 안 됨」.
    try testing.expectEqual(Outcome.block, decide(&.{.{ .browser = 1, .unknown = true, .rule_id = 3 }}));
    try testing.expectEqual(Outcome.block, decide(&.{ .{ .browser = 1, .unknown = true, .rule_id = 3 }, .{ .browser = 2, .rule_id = 4 } }));
    try testing.expectEqual(Outcome.not_applied, decide(&.{ .{ .browser = 1, .unknown = true, .rule_id = 3 }, .{ .browser = 0, .unknown = true } }));
    try testing.expectEqual(Outcome.user_nav, decide(&.{ .{ .browser = 1, .rule_id = 3, .user_nav = true }, .{ .browser = 2, .rule_id = 3 } }));
}

test "W9d③ 2 차 검증 MED-A2-1: T(O) 의 몫 — 보이는 탭만 덮고, 보인다고 증명되지 않은 모르는 탭은 규칙을 쥐었으면 빠지고 아니면 거부권만" {
    try testing.expectEqual(Role.shows, role(true, false, true, false));
    try testing.expectEqual(Role.shows, role(true, true, true, false)); // MED-2 — 제 iframe 이 불러오는 중이어도 덮는다
    try testing.expectEqual(Role.shows, role(true, true, false, false));
    try testing.expectEqual(Role.skip, role(false, true, true, false)); // MED-A2-1 — 늦게 뜨는 iframe 이 있는 다른 사이트의 규칙 탭
    try testing.expectEqual(Role.veto, role(false, true, false, false));
    try testing.expectEqual(Role.skip, role(false, false, true, false));
    try testing.expectEqual(Role.skip, role(false, false, false, false));
    // 5 차 검증 MED: 「보일지도」 는 규칙을 쥐면 덮고 아니면 빠진다(거부하지 않는다) — 「모름」 이 함께면 그 거부권은 그대로.
    try testing.expectEqual(Role.shows, role(false, false, true, true));
    try testing.expectEqual(Role.skip, role(false, false, false, true));
    try testing.expectEqual(Role.veto, role(false, true, false, true));
    try testing.expectEqual(Role.shows, role(false, true, true, true));
}

test "W9d③: 나열 캐시 — 같은 출처·세대만 쓰고, 세대가 오르면 버리고, 자리가 차면 오래된 것부터 덮는다" {
    var c: Cache = .{};
    var m: Membership = .{};
    m.add(.{ .cef_id = 1, .shows = true });
    c.put(11, 5, m);
    try testing.expectEqual(@as(u8, 1), c.get(11, 5).?.count);
    try testing.expect(c.get(11, 6) == null);
    try testing.expect(c.get(12, 5) == null);
    for (0..cache_slots) |i| c.put(100 + i, 5, .{});
    try testing.expect(c.get(11, 5) == null);
    var big: Membership = .{};
    for (0..max_browsers + 1) |i| big.add(.{ .cef_id = @intCast(i) });
    try testing.expect(big.overflow and big.count == max_browsers);
}
