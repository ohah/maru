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

const std = @import("std");
const capmod = @import("control_capability.zig");

/// 확인된 grant 한 건: pane P의 에이전트 → target web surface W, scope S.
pub const PaneGrant = struct {
    /// 요청 pane의 selector surface_id(§8.4 self-origin, tty-검증). 이 pane의 재연결이 grant를 조회한다.
    pane: u64,
    /// 제어 대상 web surface_id.
    target: u64,
    /// `browser` | `browser_storage`(§9.4 D5). 각 scope는 **별도 grant**(별도 확인).
    scope: capmod.ScopeClass,

    pub fn eql(a: PaneGrant, b: PaneGrant) bool {
        return a.pane == b.pane and a.target == b.target and a.scope == b.scope;
    }
};

/// bounded — 한 세션의 (pane × target × scope) grant 상한. 실무상 pane 소수 × surface 소수 × 2 scope라 넉넉.
/// 초과=`error.Full`(호출자 방어 — 정상 사용선 도달 안 함). DoS-safe 고정 배열(allocator 불요).
pub const max_grants: usize = 32;

/// pane-bound grant 집합. 고정 배열(주소 안정 불필요·값 복사 안전). L4가 인스턴스 소유(메인 스레드 — §8.8).
pub const PaneGrantStore = struct {
    grants: [max_grants]PaneGrant = undefined,
    len: usize = 0,

    fn contains(self: *const PaneGrantStore, g: PaneGrant) bool {
        for (self.grants[0..self.len]) |e| if (e.eql(g)) return true;
        return false;
    }

    /// grant 기록(idempotent — 이미 있으면 무동작 성공). 신규가 용량 초과면 `error.Full`.
    pub fn grant(self: *PaneGrantStore, g: PaneGrant) error{Full}!void {
        if (self.contains(g)) return; // dedup — grant는 유일
        if (self.len >= max_grants) return error.Full;
        self.grants[self.len] = g;
        self.len += 1;
    }

    /// (pane, target, scope) grant 보유? browser authz 합성(control_browser)이 호출.
    pub fn isGranted(self: *const PaneGrantStore, pane: u64, target: u64, scope: capmod.ScopeClass) bool {
        return self.contains(.{ .pane = pane, .target = target, .scope = scope });
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

test "grant + isGranted: 기록한 (pane,target,scope)만 인가, 없는 건 거부" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try testing.expect(store.isGranted(5, 11, .browser));
    try testing.expect(!store.isGranted(5, 11, .browser_storage)); // scope 별도
    try testing.expect(!store.isGranted(5, 12, .browser)); // target 별도
    try testing.expect(!store.isGranted(6, 11, .browser)); // pane 별도
    try testing.expect(!store.isGranted(11, 5, .browser)); // pane↔target 뒤집기 무관
}

test "grant idempotent: 같은 grant 반복 기록해도 len 1" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try testing.expectEqual(@as(usize, 1), store.len);
    try testing.expect(store.isGranted(5, 11, .browser));
}

test "scope 별도 grant: browser와 browser_storage는 각기 따로 확인·저장(D5)" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try testing.expect(store.isGranted(5, 11, .browser));
    try testing.expect(!store.isGranted(5, 11, .browser_storage)); // browser가 storage 함의 안 함
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage });
    try testing.expect(store.isGranted(5, 11, .browser) and store.isGranted(5, 11, .browser_storage));
    try testing.expectEqual(@as(usize, 2), store.len);
}

test "revoke: 특정 grant만 제거, 나머지 유지" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try store.grant(.{ .pane = 5, .target = 12, .scope = .browser });
    store.revoke(5, 11, .browser);
    try testing.expect(!store.isGranted(5, 11, .browser));
    try testing.expect(store.isGranted(5, 12, .browser)); // 다른 grant 보존
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
    try testing.expect(!store.isGranted(5, 11, .browser));
    try testing.expect(!store.isGranted(5, 12, .browser_storage));
    try testing.expect(!store.isGranted(7, 20, .browser));
    // clearAll 후 새 grant 정상.
    try store.grant(.{ .pane = 1, .target = 2, .scope = .browser });
    try testing.expect(store.isGranted(1, 2, .browser));
}

test "removeSurface: surface가 pane이든 target이든 걸린 grant 전부 제거(무관 grant 보존)" {
    var store: PaneGrantStore = .{};
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser }); // 11=target
    try store.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage }); // 11=target
    try store.grant(.{ .pane = 11, .target = 20, .scope = .browser }); // 11=pane
    try store.grant(.{ .pane = 5, .target = 20, .scope = .browser }); // 11 무관
    store.removeSurface(11); // 11이 pane이든 target이든 전부
    try testing.expect(!store.isGranted(5, 11, .browser));
    try testing.expect(!store.isGranted(5, 11, .browser_storage));
    try testing.expect(!store.isGranted(11, 20, .browser));
    try testing.expect(store.isGranted(5, 20, .browser)); // 11 무관 grant만 남음
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
    try testing.expect(store.isGranted(1, 999, .browser));
}

test {
    testing.refAllDecls(@This());
}
