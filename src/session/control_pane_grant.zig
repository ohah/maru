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

/// `current` 가 `granted` 이거나 그 하위 도메인인가(대소문자 무시). `github.com` 은 `gist.github.com` 을 덮지만
/// `evilgithub.com` 은 덮지 않는다(점 경계). 거꾸로 하위 도메인 grant 는 부모·형제를 덮지 않는다. 어느 쪽이든 비면 false.
pub fn hostCovers(granted: []const u8, current: []const u8) bool {
    if (granted.len == 0 or current.len == 0) return false;
    if (current.len == granted.len) return std.ascii.eqlIgnoreCase(current, granted);
    if (current.len < granted.len + 1) return false;
    const tail = current[current.len - granted.len ..];
    return current[current.len - granted.len - 1] == '.' and std.ascii.eqlIgnoreCase(tail, granted);
}

/// http(s) URL 의 호스트. 다른 스킴(data:·about:·file: — 쿠키가 없다)이나 호스트 없는 URL 은 null.
pub fn hostOfUrl(url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return null;
    const host = uri.host orelse return null;
    const raw = switch (host) {
        .raw => |r| r,
        .percent_encoded => |p| p,
    };
    return if (raw.len == 0) null else raw;
}

/// 확인된 grant 한 건: pane P의 에이전트 → target web surface W, scope S.
pub const PaneGrant = struct {
    /// 요청 pane의 selector surface_id(§8.4 self-origin, tty-검증). 이 pane의 재연결이 grant를 조회한다.
    pane: u64,
    /// 제어 대상 web surface_id.
    target: u64,
    /// `browser` | `browser_storage`(§9.4 D5). 각 scope는 **별도 grant**(별도 확인).
    scope: capmod.ScopeClass,
    /// `browser_storage` 가 묶인 호스트(모달이 보인 URL 의 호스트). `browser` 는 보지 않는다.
    host: GrantHost = .{},

    /// 같은 grant 자리인가(pane·target·scope) — 호스트는 자리의 값이다(다시 허용하면 바뀐다).
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

    fn find(self: *PaneGrantStore, g: PaneGrant) ?*PaneGrant {
        for (self.grants[0..self.len]) |*e| if (e.eql(g)) return e;
        return null;
    }

    fn findConst(self: *const PaneGrantStore, pane: u64, target: u64, scope: capmod.ScopeClass) ?*const PaneGrant {
        const want: PaneGrant = .{ .pane = pane, .target = target, .scope = scope };
        for (self.grants[0..self.len]) |*e| if (e.eql(want)) return e;
        return null;
    }

    /// grant 기록. 같은 (pane, target, scope) 가 이미 있으면 호스트만 바꾼다(다시 허용한 사이트가 새 범위다). 신규가 용량
    /// 초과면 `error.Full`.
    pub fn grant(self: *PaneGrantStore, g: PaneGrant) error{Full}!void {
        if (self.find(g)) |existing| {
            existing.host = g.host;
            return;
        }
        if (self.len >= max_grants) return error.Full;
        self.grants[self.len] = g;
        self.len += 1;
    }

    /// (pane, target, scope) grant 가 **있는가만** 본다 — 인가에는 쓰지 않는다(`authorizes`). 메뉴·revoke·시험용.
    pub fn hasGrant(self: *const PaneGrantStore, pane: u64, target: u64, scope: capmod.ScopeClass) bool {
        return self.findConst(pane, target, scope) != null;
    }

    /// 인가: grant 가 있고, `browser_storage` 면 대상 문서의 지금 호스트(`current_host` — http(s) 가 아니면 null)가 grant
    /// 호스트이거나 그 하위 도메인이어야 한다. browser authz 합성(control_browser)과 확인 dedup 이 호출한다.
    pub fn authorizes(self: *const PaneGrantStore, pane: u64, target: u64, scope: capmod.ScopeClass, current_host: ?[]const u8) bool {
        const g = self.findConst(pane, target, scope) orelse return false;
        if (scope != .browser_storage) return true;
        return hostCovers(g.host.slice(), current_host orelse return false);
    }

    /// grant 가 (pane, target, scope) 자리에 **그 호스트로** 아직 있는가(실행 직전 재확인 — 사이에 다른 사이트로 다시
    /// 허용됐으면 옛 호스트로 시작한 op 는 권한을 잃는다). `browser` 는 호스트를 보지 않는다.
    pub fn stillGrants(self: *const PaneGrantStore, pane: u64, target: u64, scope: capmod.ScopeClass, host: *const GrantHost) bool {
        const g = self.findConst(pane, target, scope) orelse return false;
        return scope != .browser_storage or g.host.eql(host);
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
