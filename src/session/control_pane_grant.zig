//! control_pane_grant — pane-bound confirm-grant 저장소 (L2 순수, §9.2 Model B).
//!
//! **1e-confirm(§9.2 개정 2026-07-13)**: browser capability의 **대화형 주 경로**. cap fd/nonce 대신, 사용자가 확인
//! 모달로 승인한 "pane P의 에이전트가 target web surface W를 scope S로 제어" grant를 **tty-검증 pane 신원**에 묶어
//! 저장한다. **bearer 토큰 없음** — 다음 요청이 `auth.self`(selector=pane)로 재연결하면 §8.4 tty 게이트가 pane을
//! 재검증하고 이 store를 조회한다. browser authz는 "세션 cap 인가 **OR** pane grant 보유"의 **가법 합성**(§9.2,
//! 22차 [1] ambient-self 불변식과 정합 — 제시가 기존 권한을 revoke 안 함).
//!
//! **L2 순수**: std + control_capability(`ScopeClass`)만 import. OS/소켓/GUI 0(tests/boundary/imports.zig가 강제).
//! 런타임 인스턴스 소유는 L4(app_host_abi — `control_cap_store` 선례). 확인 모달·held-request 흐름은 L4
//! (1e-confirm-1b/2). 이 파일은 grant 집합 CRUD만.
//!
//! **수명(§9.2)**: grant는 두 surface(pane·target)가 살아있는 동안 유효. surface close/generation 변경 시
//! `removeSurface`로 무효(그 surface가 pane이든 target이든). 세션(프로세스) 한정 — 영속 저장 안 함(재시작=빈 store=
//! default-deny). scope는 **per-scope 별도 grant**(browser가 browser_storage를 함의하지 않음 — 각기 다른 확인, §9.4 D5).
//!
//! **쿠키 권한은 사이트에 묶는다**(사용자 결정 2026-09-24 — docs/plans/web-osr-backend.md 「쿠키 권한은 사이트에」): 확인
//! 모달은 「이 사이트의 쿠키」를 묻는데 grant 가 (pane, target) 에만 묶여 있어, 허용받은 탭을 다른 사이트로 옮기면 그
//! 사이트의 HttpOnly 세션 쿠키까지 읽을 수 있었다. `browser_storage` grant 는 모달이 보인 호스트를 들고, 그 호스트와 하위
//! 도메인에서만 인가한다(`authorizes`). 인가는 반드시 `authorizes` 로 한다 — `hasGrant` 는 존재만 본다(메뉴·revoke 용).

const std = @import("std");
const capmod = @import("control_capability.zig");
const net_policy = @import("web_sidecar/net_policy.zig");

/// DNS 이름 상한(RFC 1035 — 점 포함 253 바이트).
pub const max_host_bytes: usize = 253;

/// grant 가 묶인 호스트(소문자). 빈 값은 어떤 호스트도 인가하지 않는다. 값 타입이라 grant·provenance 로 복사된다.
pub const GrantHost = struct {
    buf: [max_host_bytes]u8 = undefined,
    len: u8 = 0,

    /// 호스트를 소문자로 담는다. 비었거나 상한을 넘으면 빈 값(어떤 호스트도 인가하지 않음).
    pub fn init(host: []const u8) GrantHost {
        var out: GrantHost = .{};
        if (host.len == 0 or host.len > max_host_bytes) return out;
        for (host, 0..) |c, i| out.buf[i] = std.ascii.toLower(c);
        out.len = @intCast(host.len);
        return out;
    }

    pub fn slice(self: *const GrantHost) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn eql(a: *const GrantHost, b: *const GrantHost) bool {
        return std.mem.eql(u8, a.slice(), b.slice());
    }
};

/// `current` 가 `granted` 이거나 그 하위 도메인인가(대소문자 무시, 점 경계). 규칙의 단일 출처는 `web_sidecar/net_policy.zig` 다 —
/// W9d① 의 sidecar 가 같은 규칙으로 「덮이는 호스트」 를 가른다(같은 파일을 쓴다).
pub const hostCovers = net_policy.hostCovers;

/// http(s) URL 의 호스트(다른 스킴·호스트 없는 URL 은 null) — 단일 출처는 `net_policy.hostOfUrl`.
pub const hostOfUrl = net_policy.hostOfUrl;

/// 사이트에 묶이는 scope 인가 — 쿠키(`browser_storage`)와 네트워크 기록(`browser_network` — W9d①: 요청 헤더에 그 사이트의 로그인 쿠키가
/// 들어 있다)는 모달이 보인 호스트와 그 하위 도메인에서만 인가한다. `browser` 는 호스트를 보지 않는다.
pub fn hostBound(scope: capmod.ScopeClass) bool {
    return scope == .browser_storage or scope == .browser_network;
}

/// 확인된 grant 한 건: pane P의 에이전트 → target web surface W, scope S.
pub const PaneGrant = struct {
    /// 요청 pane의 selector surface_id(§8.4 self-origin, tty-검증). 이 pane의 재연결이 grant를 조회한다.
    pane: u64,
    /// 제어 대상 web surface_id.
    target: u64,
    /// `browser` | `browser_storage` | `browser_network`(§9.4 D5). 각 scope는 **별도 grant**(별도 확인).
    scope: capmod.ScopeClass,
    /// `browser_storage`·`browser_network` 가 묶인 호스트(모달이 보인 URL 의 호스트 — `hostBound`). `browser` 는 보지 않는다.
    host: GrantHost = .{},
    /// 어느 호스트든 인가한다(W9d① — 에이전트가 연 탭의 태어날 때 `browser_network` grant: 사용자 결정 2026-10-15 「에이전트가 연 탭은 묻지
    /// 않는다」 — 에이전트가 그 탭을 어디로 옮기든 다시 묻지 않는다). 모달로 받은 grant 는 늘 거짓.
    any_host: bool = false,
    /// 에이전트 탭과 함께 넣은 `browser_network` grant 의 자리다 — `max_grants` 상한 밖에서 센다(W9d① 적대 리뷰 1 회차 F6: 탭마다 두 자리를
    /// 쓰면 pane 넷 × 탭 여덟에 표가 차, 사용자가 「허용」 한 모달이 저장되지 못하고 -32002 로 끝났다). 사용자가 모달로 다시 허용하면 보통
    /// grant 가 된다(그때 상한 안이 잠시 넘칠 수 있다 — 자리는 늘지 않고, 넘친 동안 새 보통 grant 만 `Full`).
    birth: bool = false,
    /// 저장소가 새 자리를 기록할 때 매기는 번호(W9c① — 1 부터, 다시 쓰지 않는다). 같은 자리를 다시 허용하면 그대로이고, 철회 뒤 다시
    /// 허용하면 새 번호다. `browser_network` 를 다른 호스트로 다시 허용하면 새 동의라 새 번호다(W9d① 적대 리뷰 1 회차 F1 — 읽는 쪽이 새로
    /// 시작한다). 넘긴 값은 쓰지 않는다. 자리 비교(`eql`)·인가에는 쓰지 않는다.
    id: u64 = 0,

    /// 같은 grant 자리인가(pane·target·scope) — 호스트는 자리의 값이다(다시 허용하면 바뀐다).
    pub fn eql(a: PaneGrant, b: PaneGrant) bool {
        return a.pane == b.pane and a.target == b.target and a.scope == b.scope;
    }
};

/// bounded — 한 세션의 (pane × target × scope) grant 상한. 실무상 pane 소수 × surface 소수 × 2 scope라 넉넉.
/// 초과=`error.Full`(호출자 방어 — 정상 사용선 도달 안 함). DoS-safe 고정 배열(allocator 불요). 에이전트 탭의 태어날 때 네트워크
/// grant(`birth`)는 이 상한 밖에서 따로 센다 — 각각 그 탭의 제어 grant 와 짝이라 그 수도 `max_grants` 를 넘지 않는다.
pub const max_grants: usize = 64;
/// 표의 실제 자리 수 — 상한 안의 grant 와 태어날 때의 grant 를 함께 담는다.
pub const capacity: usize = 2 * max_grants;

/// pane-bound grant 집합. 고정 배열(주소 안정 불필요·값 복사 안전). L4가 인스턴스 소유(메인 스레드 — §8.8).
pub const PaneGrantStore = struct {
    grants: [capacity]PaneGrant = undefined,
    len: usize = 0,
    /// 다음 새 자리의 번호(W9c①) — `clearAll`·철회로도 되돌리지 않는다(같은 번호가 다른 허락에 다시 쓰이면 콘솔이 그 허락을 앞 허락의
    /// 연속으로 봤다).
    next_id: u64 = 1,

    fn find(self: *PaneGrantStore, g: PaneGrant) ?*PaneGrant {
        for (self.grants[0..self.len]) |*e| if (e.eql(g)) return e;
        return null;
    }

    fn findConst(self: *const PaneGrantStore, pane: u64, target: u64, scope: capmod.ScopeClass) ?*const PaneGrant {
        const want: PaneGrant = .{ .pane = pane, .target = target, .scope = scope };
        for (self.grants[0..self.len]) |*e| if (e.eql(want)) return e;
        return null;
    }

    /// grant 기록. 같은 (pane, target, scope) 가 이미 있으면 호스트만 바꾼다(다시 허용한 사이트가 새 범위다 — 번호는 그대로). 단
    /// `browser_network` 의 호스트가 바뀌면 새 번호다(F1 — 그 사이트의 요청은 이 허락 뒤의 것만 보여야 한다: 읽는 쪽은 번호로 가리니 새
    /// 번호면 새로 시작한다). 새 자리는 새 번호를 받는다(`g.id` 는 쓰지 않는다). 신규가 상한 초과면 `error.Full`(`birth` 는 따로 센다).
    pub fn grant(self: *PaneGrantStore, g: PaneGrant) error{Full}!void {
        if (self.find(g)) |existing| {
            const new_consent = g.scope == .browser_network and (!existing.host.eql(&g.host) or existing.any_host != g.any_host);
            existing.host = g.host;
            existing.any_host = g.any_host;
            existing.birth = existing.birth and g.birth;
            if (new_consent) {
                existing.id = self.next_id;
                self.next_id += 1;
            }
            return;
        }
        if (!self.room(g.birth)) return error.Full;
        self.grants[self.len] = g;
        self.grants[self.len].id = self.next_id;
        self.next_id += 1;
        self.len += 1;
    }

    /// 상한 밖에서 세는 태어날 때 grant 의 수.
    fn birthCount(self: *const PaneGrantStore) usize {
        var n: usize = 0;
        for (self.grants[0..self.len]) |*e| n += @intFromBool(e.birth);
        return n;
    }

    /// 새 자리를 하나 더 둘 수 있는가 — 보통 grant 는 `max_grants` 안에서, 태어날 때 grant(`birth`)는 따로 `max_grants` 까지.
    pub fn room(self: *const PaneGrantStore, birth: bool) bool {
        if (self.len >= capacity) return false;
        const births = self.birthCount();
        return if (birth) births < max_grants else self.len - births < max_grants;
    }

    /// W9d① 적대 리뷰 1 회차 F5(설정 `browser.agent-network-full` 이 꺼졌을 때): 사용자가 그 탭을 몰았다 — 그 탭의 어느 호스트든 grant 를
    /// 그때의 사이트(`host`)에 묶는다. 다른 사이트는 다시 묻는다. 번호는 그대로다(새 동의가 아니라 좁힘 — 더 숨기는 쪽). 바꿨으면 참.
    pub fn narrowAnyHost(self: *PaneGrantStore, target: u64, host: GrantHost) bool {
        var changed = false;
        for (self.grants[0..self.len]) |*e| if (e.target == target and e.scope == .browser_network and e.any_host) {
            e.any_host = false;
            e.host = host;
            changed = true;
        };
        return changed;
    }

    /// (pane, target, scope) grant 가 **있는가만** 본다 — 인가에는 쓰지 않는다(`authorizes`). 메뉴·revoke·시험용.
    pub fn hasGrant(self: *const PaneGrantStore, pane: u64, target: u64, scope: capmod.ScopeClass) bool {
        return self.findConst(pane, target, scope) != null;
    }

    /// 인가: grant 가 있고, `browser_storage` 면 대상 문서의 지금 호스트(`current_host` — http(s) 가 아니면 null)가 grant
    /// 호스트이거나 그 하위 도메인이어야 한다. browser authz 합성(control_browser)과 확인 dedup 이 호출한다.
    pub fn authorizes(self: *const PaneGrantStore, pane: u64, target: u64, scope: capmod.ScopeClass, current_host: ?[]const u8) bool {
        const g = self.findConst(pane, target, scope) orelse return false;
        if (!hostBound(scope) or g.any_host) return true;
        return hostCovers(g.host.slice(), current_host orelse return false);
    }

    /// grant 가 (pane, target, scope) 자리에 **그 호스트로** 아직 있는가(실행 직전 재확인 — 사이에 다른 사이트로 다시
    /// 허용됐으면 옛 호스트로 시작한 op 는 권한을 잃는다). `browser` 는 호스트를 보지 않는다.
    pub fn stillGrants(self: *const PaneGrantStore, pane: u64, target: u64, scope: capmod.ScopeClass, host: *const GrantHost) bool {
        const g = self.findConst(pane, target, scope) orelse return false;
        return !hostBound(scope) or g.host.eql(host);
    }

    /// (pane, target, scope) grant 의 번호(없으면 null) — W9c①: 콘솔이 「같은 허락으로 읽는 쪽인가」 를 가른다.
    pub fn idOf(self: *const PaneGrantStore, pane: u64, target: u64, scope: capmod.ScopeClass) ?u64 {
        const g = self.findConst(pane, target, scope) orelse return null;
        return g.id;
    }

    /// (pane, target, scope) grant 의 지금 값(없으면 null).
    pub fn get(self: *const PaneGrantStore, pane: u64, target: u64, scope: capmod.ScopeClass) ?PaneGrant {
        const g = self.findConst(pane, target, scope) orelse return null;
        return g.*;
    }

    /// (pane, target, scope) grant 의 호스트(없으면 null).
    pub fn hostOf(self: *const PaneGrantStore, pane: u64, target: u64, scope: capmod.ScopeClass) ?GrantHost {
        const g = self.findConst(pane, target, scope) orelse return null;
        return g.host;
    }

    /// 특정 grant 취소(명시 revoke). 없으면 무동작. grant가 dedup이라 유일 — 첫 매칭 swap-remove 후 종료.
    pub fn revoke(self: *PaneGrantStore, pane: u64, target: u64, scope: capmod.ScopeClass) void {
        const want: PaneGrant = .{ .pane = pane, .target = target, .scope = scope };
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.grants[i].eql(want)) {
                self.grants[i] = self.grants[self.len - 1];
                self.len -= 1;
                return;
            }
        }
    }

    /// 부여한 grant를 **전부 취소**한다(§9.2 revoke UX — 메뉴 "Revoke Browser Grants"). len=0 리셋(PaneGrant는 값
    /// 타입·고정 배열이라 원소 free 불요). 이후 isGranted는 전부 false → browser 요청이 다시 확인 모달을 거친다.
    pub fn clearAll(self: *PaneGrantStore) void {
        self.len = 0;
    }

    /// surface close/generation 변경 시: 그 surface가 **pane이든 target이든** 걸린 grant 전부 제거(§9.2 수명).
    /// pane close=그 에이전트 사라짐, target close=제어 대상 사라짐 — 어느 쪽이든 grant 무의미. swap-remove라
    /// 제거 후 i를 안 늘려(swap해 온 원소 재검사) 여러 매칭도 한 패스에 정리.
    pub fn removeSurface(self: *PaneGrantStore, surface_id: u64) void {
        var i: usize = 0;
        while (i < self.len) {
            if (self.grants[i].pane == surface_id or self.grants[i].target == surface_id) {
                self.grants[i] = self.grants[self.len - 1];
                self.len -= 1;
            } else {
                i += 1;
            }
        }
    }
};

// ══ 테스트(헤드리스, Linux CI 포함 — 순수 집합 로직) ═══════════════════════════════════════════════════════════
const testing = std.testing;

test "grant + hasGrant: 기록한 (pane,target,scope)만 인가, 없는 건 거부" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try testing.expect(store.hasGrant(5, 11, .browser));
    try testing.expect(!store.hasGrant(5, 11, .browser_storage)); // scope 별도
    try testing.expect(!store.hasGrant(5, 12, .browser)); // target 별도
    try testing.expect(!store.hasGrant(6, 11, .browser)); // pane 별도
    try testing.expect(!store.hasGrant(11, 5, .browser)); // pane↔target 뒤집기 무관
}

test "grant idempotent: 같은 grant 반복 기록해도 len 1" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try testing.expectEqual(@as(usize, 1), store.len);
    try testing.expect(store.hasGrant(5, 11, .browser));
}

test "scope 별도 grant: browser와 browser_storage는 각기 따로 확인·저장(D5)" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try testing.expect(store.hasGrant(5, 11, .browser));
    try testing.expect(!store.hasGrant(5, 11, .browser_storage)); // browser가 storage 함의 안 함
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage });
    try testing.expect(store.hasGrant(5, 11, .browser) and store.hasGrant(5, 11, .browser_storage));
    try testing.expectEqual(@as(usize, 2), store.len);
}

test "revoke: 특정 grant만 제거, 나머지 유지" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try store.grant(.{ .pane = 5, .target = 12, .scope = .browser });
    store.revoke(5, 11, .browser);
    try testing.expect(!store.hasGrant(5, 11, .browser));
    try testing.expect(store.hasGrant(5, 12, .browser)); // 다른 grant 보존
    try testing.expectEqual(@as(usize, 1), store.len);
    store.revoke(5, 99, .browser); // 없는 grant revoke = 무동작
    try testing.expectEqual(@as(usize, 1), store.len);
}

test "clearAll: 부여한 grant 전부 취소(§9.2 revoke UX), 이후 isGranted 전부 false" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try store.grant(.{ .pane = 5, .target = 12, .scope = .browser_storage });
    try store.grant(.{ .pane = 7, .target = 20, .scope = .browser });
    store.clearAll();
    try testing.expectEqual(@as(usize, 0), store.len);
    try testing.expect(!store.hasGrant(5, 11, .browser));
    try testing.expect(!store.hasGrant(5, 12, .browser_storage));
    try testing.expect(!store.hasGrant(7, 20, .browser));
    // clearAll 후 새 grant 정상.
    try store.grant(.{ .pane = 1, .target = 2, .scope = .browser });
    try testing.expect(store.hasGrant(1, 2, .browser));
}

test "removeSurface: surface가 pane이든 target이든 걸린 grant 전부 제거(무관 grant 보존)" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser }); // 11=target
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage }); // 11=target
    try store.grant(.{ .pane = 11, .target = 20, .scope = .browser }); // 11=pane
    try store.grant(.{ .pane = 5, .target = 20, .scope = .browser }); // 11 무관
    store.removeSurface(11); // 11이 pane이든 target이든 전부
    try testing.expect(!store.hasGrant(5, 11, .browser));
    try testing.expect(!store.hasGrant(5, 11, .browser_storage));
    try testing.expect(!store.hasGrant(11, 20, .browser));
    try testing.expect(store.hasGrant(5, 20, .browser)); // 11 무관 grant만 남음
    try testing.expectEqual(@as(usize, 1), store.len);
}

test "bounded: max_grants 초과 신규는 Full, 초과 상태서 기존 grant 조회·idempotent는 정상" {
    var store: PaneGrantStore = .{};
    var i: u64 = 0;
    while (i < max_grants) : (i += 1) {
        try store.grant(.{ .pane = 1, .target = i, .scope = .browser }); // 서로 다른 target 32개
    }
    try testing.expectEqual(max_grants, store.len);
    // 이미 있는 grant 재기록(idempotent)은 Full 안 남.
    try store.grant(.{ .pane = 1, .target = 0, .scope = .browser });
    // 신규는 Full.
    try testing.expectError(error.Full, store.grant(.{ .pane = 1, .target = 999, .scope = .browser }));
    // 하나 revoke하면 다시 여유.
    store.revoke(1, 0, .browser);
    try store.grant(.{ .pane = 1, .target = 999, .scope = .browser });
    try testing.expect(store.hasGrant(1, 999, .browser));
}

test "browser_storage 는 허용한 호스트와 그 하위 도메인에서만 인가한다 — 다른 사이트로 옮긴 탭은 거절" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage, .host = GrantHost.init("GitHub.com") });
    try testing.expect(store.authorizes(5, 11, .browser_storage, "github.com"));
    try testing.expect(store.authorizes(5, 11, .browser_storage, "gist.github.com"));
    try testing.expect(store.authorizes(5, 11, .browser_storage, "a.b.GITHUB.com"));
    try testing.expect(!store.authorizes(5, 11, .browser_storage, "mybank.co.kr")); // 탭을 옮겨 은행 쿠키 — 거절
    try testing.expect(!store.authorizes(5, 11, .browser_storage, "evilgithub.com")); // 점 경계
    try testing.expect(!store.authorizes(5, 11, .browser_storage, "github.com.evil.io"));
    try testing.expect(!store.authorizes(5, 11, .browser_storage, "com"));
    try testing.expect(!store.authorizes(5, 11, .browser_storage, null)); // data:·about: — 문서 호스트 없음
    try testing.expect(!store.authorizes(5, 12, .browser_storage, "github.com")); // 다른 탭
    // 하위 도메인 grant 는 부모·형제를 덮지 않는다.
    try store.grant(.{ .pane = 5, .target = 13, .scope = .browser_storage, .host = GrantHost.init("mail.google.com") });
    try testing.expect(!store.authorizes(5, 13, .browser_storage, "google.com"));
    try testing.expect(!store.authorizes(5, 13, .browser_storage, "drive.google.com"));
    try testing.expect(store.authorizes(5, 13, .browser_storage, "x.mail.google.com"));
    // 빈 호스트로 남은 grant 는 아무 호스트도 인가하지 않는다.
    try store.grant(.{ .pane = 5, .target = 14, .scope = .browser_storage });
    try testing.expect(!store.authorizes(5, 14, .browser_storage, "github.com"));
    // browser scope 는 호스트를 보지 않는다.
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try testing.expect(store.authorizes(5, 11, .browser, "mybank.co.kr"));
    try testing.expect(store.authorizes(5, 11, .browser, null));
}

test "다시 허용하면 호스트가 바뀌고, 옛 호스트로 시작한 op 는 stillGrants 에서 권한을 잃는다" {
    var store: PaneGrantStore = .{};
    const old = GrantHost.init("github.com");
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage, .host = old });
    try testing.expect(store.stillGrants(5, 11, .browser_storage, &old));
    const new = GrantHost.init("gitlab.com");
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage, .host = new });
    try testing.expectEqual(@as(usize, 1), store.len); // 자리는 하나
    try testing.expect(!store.authorizes(5, 11, .browser_storage, "github.com"));
    try testing.expect(store.authorizes(5, 11, .browser_storage, "gitlab.com"));
    try testing.expect(!store.stillGrants(5, 11, .browser_storage, &old));
    try testing.expect(store.stillGrants(5, 11, .browser_storage, &new));
    store.revoke(5, 11, .browser_storage);
    try testing.expect(!store.stillGrants(5, 11, .browser_storage, &new));
}

test "W9d①: browser_network grant 도 사이트에 묶인다 — 쿠키와 같은 호스트 규칙, browser 를 함의하지도 받지도 않는다" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser_network, .host = GrantHost.init("app.test") });
    try testing.expect(store.authorizes(5, 11, .browser_network, "app.test"));
    try testing.expect(store.authorizes(5, 11, .browser_network, "api.app.test"));
    try testing.expect(!store.authorizes(5, 11, .browser_network, "bank.test"));
    try testing.expect(!store.authorizes(5, 11, .browser_network, null));
    try testing.expect(!store.authorizes(5, 11, .browser, "app.test")); // 따로 묻는다
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try testing.expect(!store.authorizes(5, 11, .browser_storage, "app.test"));
    const h = GrantHost.init("app.test");
    try testing.expect(store.stillGrants(5, 11, .browser_network, &h));
    const other = GrantHost.init("bank.test");
    try testing.expect(!store.stillGrants(5, 11, .browser_network, &other));
    try testing.expect(hostBound(.browser_network) and hostBound(.browser_storage) and !hostBound(.browser));
    // 에이전트가 연 탭의 태어날 때 grant 는 어느 호스트든(문서가 없어도) 인가한다.
    try store.grant(.{ .pane = 6, .target = 12, .scope = .browser_network, .any_host = true });
    try testing.expect(store.authorizes(6, 12, .browser_network, "bank.test"));
    try testing.expect(store.authorizes(6, 12, .browser_network, null));
}

test "W9d① 적대 리뷰 1 회차 재현 F1·F5: 네트워크 grant 를 다른 호스트로 다시 허용하면 새 번호(새 동의), 같은 호스트면 그대로, 좁히기는 번호를 두고 그때의 사이트에 묶는다" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser_network, .host = GrantHost.init("a.test") });
    const first = store.idOf(5, 11, .browser_network).?;
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser_network, .host = GrantHost.init("A.test") });
    try testing.expectEqual(first, store.idOf(5, 11, .browser_network).?); // 같은 사이트 — 이어진다
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser_network, .host = GrantHost.init("bank.test") });
    const second = store.idOf(5, 11, .browser_network).?;
    try testing.expect(second != first); // 다른 사이트 — 새 동의
    // 쿠키 grant 는 번호를 그대로 둔다(읽는 쪽의 시작점이 없다).
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage, .host = GrantHost.init("a.test") });
    const cookie = store.idOf(5, 11, .browser_storage).?;
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage, .host = GrantHost.init("bank.test") });
    try testing.expectEqual(cookie, store.idOf(5, 11, .browser_storage).?);
    // 좁히기 — 어느 호스트든 grant 만, 번호는 그대로.
    try store.grant(.{ .pane = 6, .target = 12, .scope = .browser_network, .any_host = true, .birth = true });
    const birth = store.idOf(6, 12, .browser_network).?;
    try testing.expect(!store.narrowAnyHost(11, GrantHost.init("x.test"))); // 이미 묶인 grant 는 그대로
    try testing.expect(store.narrowAnyHost(12, GrantHost.init("agent.test")));
    try testing.expectEqual(birth, store.idOf(6, 12, .browser_network).?);
    try testing.expect(store.authorizes(6, 12, .browser_network, "agent.test"));
    try testing.expect(!store.authorizes(6, 12, .browser_network, "bank.test"));
    try testing.expect(!store.narrowAnyHost(12, GrantHost.init("bank.test"))); // 두 번째 몰기는 바꾸지 않는다
    try testing.expectEqualStrings("agent.test", store.hostOf(6, 12, .browser_network).?.slice());
}

test "W9d① 적대 리뷰 1 회차 재현 F6: 태어날 때 grant 는 64 자리 상한 밖에서 센다 — 보통 grant 64 개와 태어날 때 grant 64 개를 함께 담고, 그 넘어는 Full" {
    var store: PaneGrantStore = .{};
    for (0..max_grants) |i| try store.grant(.{ .pane = 1, .target = 100 + i, .scope = .browser_network, .any_host = true, .birth = true });
    try testing.expect(store.room(false)); // 태어날 때 grant 가 다 차도 사용자의 모달은 저장된다
    try testing.expect(!store.room(true));
    try testing.expectError(error.Full, store.grant(.{ .pane = 1, .target = 999, .scope = .browser_network, .any_host = true, .birth = true }));
    for (0..max_grants) |i| try store.grant(.{ .pane = 2, .target = 100 + i, .scope = .browser });
    try testing.expect(!store.room(false));
    try testing.expectError(error.Full, store.grant(.{ .pane = 3, .target = 1, .scope = .browser_network, .host = GrantHost.init("a.test") }));
    try testing.expectEqual(capacity, store.len);
    // 다시 허용(있는 자리)은 꽉 찼어도 된다.
    try store.grant(.{ .pane = 2, .target = 100, .scope = .browser });
}

test "hostOfUrl: http(s) 호스트만 — 다른 스킴과 호스트 없는 URL 은 null" {
    try testing.expectEqualStrings("github.com", hostOfUrl("https://github.com/ohah/maru?x=1").?);
    try testing.expectEqualStrings("127.0.0.1", hostOfUrl("http://127.0.0.1:8080/a").?);
    try testing.expectEqualStrings("Mail.Google.com", hostOfUrl("HTTPS://Mail.Google.com").?);
    try testing.expect(hostOfUrl("data:text/html,hi") == null);
    try testing.expect(hostOfUrl("about:blank") == null);
    try testing.expect(hostOfUrl("file:///etc/passwd") == null);
    try testing.expect(hostOfUrl("not a url") == null);
    try testing.expect(hostOfUrl("") == null);
    // 사용자 정보로 호스트를 속여도 진짜 호스트를 준다.
    try testing.expectEqualStrings("evil.io", hostOfUrl("https://github.com@evil.io/").?);
}

test "W9c①: grant 번호 — 새 자리마다 새 번호, 다시 허용은 그대로, 철회 뒤 다시 허용·전부 취소 뒤에도 겹치지 않는다" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try store.grant(.{ .pane = 5, .target = 12, .scope = .browser });
    const a = store.idOf(5, 11, .browser).?;
    const b = store.idOf(5, 12, .browser).?;
    try testing.expect(a != 0 and b != 0 and a != b);
    try testing.expect(store.idOf(5, 11, .browser_storage) == null);
    // 같은 자리를 다시 허용(호스트만 바뀐다)하면 번호는 그대로 — 같은 허락이다.
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser, .host = GrantHost.init("x.test") });
    try testing.expectEqual(a, store.idOf(5, 11, .browser).?);
    // 철회하고 다시 허용하면 새 번호 — 철회 전의 읽기가 묶인 것을 이어받지 않는다.
    store.revoke(5, 11, .browser);
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    const c = store.idOf(5, 11, .browser).?;
    try testing.expect(c != a and c != b);
    // 전부 취소해도 번호는 처음으로 돌아가지 않는다.
    store.clearAll();
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    const d = store.idOf(5, 11, .browser).?;
    try testing.expect(d != a and d != b and d != c);
    // 탭이 닫혀 사라진 자리도 같다.
    store.removeSurface(11);
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try testing.expect(store.idOf(5, 11, .browser).? != d);
    // 넘긴 값의 번호는 쓰지 않는다 — 번호는 저장소가 매긴다.
    try store.grant(.{ .pane = 9, .target = 9, .scope = .browser, .id = a });
    try testing.expect(store.idOf(9, 9, .browser).? != a);
}

test "GrantHost: 상한을 넘거나 빈 호스트는 빈 값" {
    try testing.expectEqual(@as(u8, 0), GrantHost.init("").len);
    const long = [_]u8{'a'} ** (max_host_bytes + 1);
    try testing.expectEqual(@as(u8, 0), GrantHost.init(&long).len);
    const max = [_]u8{'a'} ** max_host_bytes;
    try testing.expectEqual(@as(u8, max_host_bytes), GrantHost.init(&max).len);
}

test {
    testing.refAllDecls(@This());
}
