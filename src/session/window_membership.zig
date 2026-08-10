//! WindowMembershipSnapshot — window↔surface membership 최소 DTO + `metadata:{self|window|all}` scope 판정
//! (L2 순수, OS-중립). M0b(docs/window-surface-mobility.md §8, docs/control-plane.md §3,
//! docs/control-plane-security.md §8.3~§8.4).
//!
//! full `WindowGraph`(M1)를 짓기 전에, control-plane Phase 1이 소비할 두 계약 — `metadata:window` scope 판정과
//! "2-window+quick 전역 surface_id 비충돌" — 을 검증하기 위한 최소 형태다. `WindowGraph` 도입 후엔 같은 membership
//! 정보의 **읽기 출처만** graph로 바뀌고, 여기 DTO/enum/필터 계약은 그대로 유지된다(docs/window-surface-mobility.md §3).
//!
//! **범위(딱 이것만)**: 순수 DTO + `window_kind` enum + scope 필터 순수 함수. 실제 membership 채움(collector)·
//! 소켓·ABI·Swift 창 열거·scope 발급(auth)은 여기 없다 — 이 slice의 테스트는 손으로 만든 fake snapshot으로만 돈다.
//! scope를 **누가 발급하는지**(capability auth)는 control-plane Phase 1(§8.3~§8.5)이고, 이 파일은 발급된 scope로
//! **어느 surface가 보이는지 판정만** 한다(§8.3의 "응답을 자기 (surface_id, generation) 하나로 필터링"의 판정 절반).
//!
//! **generation은 M0b 범위 밖(M0a와 동일)**: self scope의 문서 정의는 "자기 (surface_id, generation) 하나"지만,
//! generation은 surface_id를 유지한 채 런타임만 갈리는 경로를 다루는 M1에서 모델한다(docs/control-plane.md §3
//! defense-in-depth). 이 DTO는 surface_id만 담고, self 판정도 surface_id 동일성으로 한다.

const std = @import("std");

/// window 분류자. **분류만** 하고 값에 라우팅 의미를 넣지 않는다(docs/control-plane.md §3 "quick terminal 정책").
/// 이 판별자는 M0b 전까지 코드에 없었다 — quick은 Swift 전용 `quick` 참조·`QuickTerminalPanel`·Zig `chrome_minimal`
/// 플래그로 분산돼 있었고(app_session.zig `SessionConfig.chrome_minimal`), M0b가 중립 enum으로 신규 도입한다.
pub const WindowKind = enum {
    /// 일반 창(사이드바·탭 바가 있는 full chrome). 앱 전역 surface_id 공간을 quick과 공유한다.
    normal,
    /// quick terminal(싱글톤 dropdown, `chrome_minimal`). 별도 window 위치 메타데이터를 가지되 같은 surface 모델이다.
    /// `metadata:all` 같은 명시 grant가 있을 때만 일반 창 열거에 포함된다(docs/control-plane.md §3, docs/control-plane-security.md §8.4).
    quick,
};

/// 한 window의 membership 최소 DTO: `{window_id, window_kind, [surface_id]}`.
/// `window_id`는 현재 위치 메타데이터(opaque)일 뿐 라우팅 키가 아니고(docs/window-surface-mobility.md §1),
/// `surface_ids`는 그 window에 속한 surface들의 앱 전역 유일 id다(M0a `SurfaceIdAllocator` 발급).
pub const WindowMembershipSnapshot = struct {
    window_id: u64,
    window_kind: WindowKind,
    /// 이 window 안의 surface_id 목록. borrowed slice(DTO는 소유하지 않는다 — collector/graph가 소유).
    surface_ids: []const u64,

    /// 이 window가 해당 surface를 포함하는가.
    pub fn containsSurface(self: WindowMembershipSnapshot, surface_id: u64) bool {
        for (self.surface_ids) |sid| {
            if (sid == surface_id) return true;
        }
        return false;
    }
};

/// metadata 열거/조회 scope(docs/control-plane-security.md §8.3). 이 파일은 **판정만** 한다 — grant는 Phase 1 auth.
pub const MetadataScope = enum {
    /// 자기 surface 하나(호출 surface_id). `sessions.list`/`get`/`subscribe`가 자기 (surface_id) 하나로 필터링.
    self,
    /// 호출 surface가 현재 속한 window 안의 surface들(현재 window membership 기준 — 이동하면 재평가, §6).
    window,
    /// primary + quick 포함 전체 window의 surface(명시 grant 필요).
    all,
};

/// caller가 속한 window snapshot을 찾는다(없으면 null). 앱 전역 surface_id가 유일하므로 정상적으로는 한 window에만
/// 나타나야 하지만, fake/조립 입력이 어긋나도 첫 매치만 반환해 판정을 결정론적으로 둔다.
pub fn windowOfSurface(
    windows: []const WindowMembershipSnapshot,
    caller_surface_id: u64,
) ?WindowMembershipSnapshot {
    for (windows) |w| {
        if (w.containsSurface(caller_surface_id)) return w;
    }
    return null;
}

/// scope 판정 핵심 술어: granted `scope` 하에서 caller가 `candidate_surface_id`를 볼 수 있는가.
/// 이것이 필터의 pointwise 원자다 — Phase 1 dispatcher는 응답 후보(surface)마다 이 술어로 걸러
/// "허용 surface 집합"을 만든다(§8.3). 존재/generation 확인·authz 실패의 균일 `unauthorized`는 상위(§8.3)에서 별도.
///
/// - `.self`  : candidate가 caller 자신일 때만(같은 창의 다른 surface도 안 보임).
/// - `.window`: caller가 속한 window의 surface일 때만(caller가 어느 window에도 없으면 아무것도 안 보임).
/// - `.all`   : 어느 window(quick 포함)든 존재하는 surface면 허용(union — 없는 surface는 볼 수 없음).
pub fn scopeAllowsSurface(
    windows: []const WindowMembershipSnapshot,
    caller_surface_id: u64,
    scope: MetadataScope,
    candidate_surface_id: u64,
) bool {
    return switch (scope) {
        .self => candidate_surface_id == caller_surface_id,
        .window => blk: {
            const w = windowOfSurface(windows, caller_surface_id) orelse break :blk false;
            break :blk w.containsSurface(candidate_surface_id);
        },
        .all => blk: {
            for (windows) |w| {
                if (w.containsSurface(candidate_surface_id)) break :blk true;
            }
            break :blk false;
        },
    };
}

/// granted `scope`로 caller가 볼 수 있는 surface 집합을 `out` 버퍼에 채워 그 slice를 돌려준다(할당 없음).
/// 후보 모집단 = `windows` 전체의 surface(중복 없다고 가정 — 앱 전역 surface_id 유일). 순서는 windows·surface_ids 순.
/// `out`이 모자라면 넘치는 건 조용히 버린다(순수 판정 함수라 에러를 만들지 않는다 — 버퍼 크기는 호출자가 보장).
/// scope 필터의 "집합" 형태로, dispatcher의 `sessions.list` 응답 필터와 같은 모양이다(§6·§8.3).
pub fn collectVisibleSurfaces(
    windows: []const WindowMembershipSnapshot,
    caller_surface_id: u64,
    scope: MetadataScope,
    out: []u64,
) []u64 {
    var n: usize = 0;
    for (windows) |w| {
        for (w.surface_ids) |sid| {
            if (!scopeAllowsSurface(windows, caller_surface_id, scope, sid)) continue;
            if (n >= out.len) return out[0..n];
            out[n] = sid;
            n += 1;
        }
    }
    return out[0..n];
}

// ── 테스트 fixture: 일반 창 A/B + quick 창 하나(손으로 만든 fake — 실제 population은 Phase 1 collector) ──────────
// caller는 창 A의 surface 10으로 고정한다. 창 A={10,11}, 창 B={20,21}, quick={30}.
const fx_a_ids = [_]u64{ 10, 11 };
const fx_b_ids = [_]u64{ 20, 21 };
const fx_q_ids = [_]u64{30};
const fx_windows = [_]WindowMembershipSnapshot{
    .{ .window_id = 1, .window_kind = .normal, .surface_ids = &fx_a_ids },
    .{ .window_id = 2, .window_kind = .normal, .surface_ids = &fx_b_ids },
    .{ .window_id = 3, .window_kind = .quick, .surface_ids = &fx_q_ids },
};

test "self scope: caller surface 하나만 — 같은 창 다른 surface·다른 창·quick 안 보임" {
    // pointwise 술어.
    try std.testing.expect(scopeAllowsSurface(&fx_windows, 10, .self, 10)); // 자기 자신
    try std.testing.expect(!scopeAllowsSurface(&fx_windows, 10, .self, 11)); // 같은 창의 다른 surface도 self엔 안 보임
    try std.testing.expect(!scopeAllowsSurface(&fx_windows, 10, .self, 20)); // 다른 일반 창
    try std.testing.expect(!scopeAllowsSurface(&fx_windows, 10, .self, 30)); // quick

    // 집합 형태: 정확히 [10].
    var buf: [8]u64 = undefined;
    const visible = collectVisibleSurfaces(&fx_windows, 10, .self, &buf);
    try std.testing.expectEqualSlices(u64, &.{10}, visible);
}

test "window scope: caller가 속한 window surface만 — 다른 창·quick 안 보임" {
    // caller=10 → 창 A={10,11}.
    try std.testing.expect(scopeAllowsSurface(&fx_windows, 10, .window, 10));
    try std.testing.expect(scopeAllowsSurface(&fx_windows, 10, .window, 11)); // 같은 창
    try std.testing.expect(!scopeAllowsSurface(&fx_windows, 10, .window, 20)); // 다른 일반 창
    try std.testing.expect(!scopeAllowsSurface(&fx_windows, 10, .window, 21));
    try std.testing.expect(!scopeAllowsSurface(&fx_windows, 10, .window, 30)); // quick

    var buf: [8]u64 = undefined;
    const visible = collectVisibleSurfaces(&fx_windows, 10, .window, &buf);
    try std.testing.expectEqualSlices(u64, &.{ 10, 11 }, visible);

    // 방어: caller가 어느 window에도 없으면 window scope는 아무것도 안 보인다.
    const orphan = collectVisibleSurfaces(&fx_windows, 999, .window, &buf);
    try std.testing.expectEqual(@as(usize, 0), orphan.len);
}

test "all scope: quick 포함 전체 window의 surface" {
    for ([_]u64{ 10, 11, 20, 21, 30 }) |sid| {
        try std.testing.expect(scopeAllowsSurface(&fx_windows, 10, .all, sid));
    }
    // 존재하지 않는 surface는 all에서도 안 보인다(union이지 무제한 허용이 아님).
    try std.testing.expect(!scopeAllowsSurface(&fx_windows, 10, .all, 999));

    var buf: [8]u64 = undefined;
    const visible = collectVisibleSurfaces(&fx_windows, 10, .all, &buf);
    try std.testing.expectEqualSlices(u64, &.{ 10, 11, 20, 21, 30 }, visible); // quick(30) 포함
}

test "2-window+quick: 앱 전역 allocator 발급 surface_id는 세 window에서 유일(비충돌)" {
    // M0a SurfaceIdAllocator와 결합 — 세 window의 surface를 하나의 앱 전역 allocator에서 발급한다.
    const surface_id = @import("surface_id.zig");
    var ids: surface_id.SurfaceIdAllocator = .{};

    const a_ids = [_]u64{ ids.next(), ids.next() }; // 창 A(normal)
    const b_ids = [_]u64{ ids.next(), ids.next() }; // 창 B(normal)
    const q_ids = [_]u64{ids.next()}; // quick

    const windows = [_]WindowMembershipSnapshot{
        .{ .window_id = 1, .window_kind = .normal, .surface_ids = &a_ids },
        .{ .window_id = 2, .window_kind = .normal, .surface_ids = &b_ids },
        .{ .window_id = 3, .window_kind = .quick, .surface_ids = &q_ids },
    };

    // 전역 유일성: 세 window를 통틀어 어떤 surface_id도 겹치지 않는다.
    // (per-session 카운터였다면 A[0]=B[0]=quick[0]=1이라 충돌 — M0a가 그걸 없앤다.)
    var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer seen.deinit();
    for (windows) |w| {
        for (w.surface_ids) |sid| {
            try std.testing.expect(!seen.contains(sid)); // 이미 다른 window에서 안 나왔어야
            try seen.put(sid, {});
        }
    }
    // 명시적으로: A·B·quick의 첫 surface가 서로 다르다(per-session이면 전부 1이라 충돌).
    try std.testing.expect(a_ids[0] != b_ids[0]);
    try std.testing.expect(b_ids[0] != q_ids[0]);
    try std.testing.expect(a_ids[0] != q_ids[0]);

    // scope 판정도 발급된 실제 id에서 동작한다: 창 A caller는 window scope로 B·quick을 못 본다.
    try std.testing.expect(scopeAllowsSurface(&windows, a_ids[0], .window, a_ids[1]));
    try std.testing.expect(!scopeAllowsSurface(&windows, a_ids[0], .window, b_ids[0]));
    try std.testing.expect(!scopeAllowsSurface(&windows, a_ids[0], .window, q_ids[0]));
}

test "collectVisibleSurfaces: out 버퍼가 모자라면 문서화된 대로 앞에서부터 잘라 채운다" {
    // all scope는 5개(10,11,20,21,30)를 낸다. out이 3칸뿐이면 windows·surface_ids 순의 앞 3개만 채우고 멈춘다
    // (순수 판정 함수라 에러 없이 조용히 절단 — 버퍼 크기는 호출자가 보장하는 계약). 이 절단 분기를 테스트로 고정한다.
    var small: [3]u64 = undefined;
    const visible = collectVisibleSurfaces(&fx_windows, 10, .all, &small);
    try std.testing.expectEqual(@as(usize, 3), visible.len);
    try std.testing.expectEqualSlices(u64, &.{ 10, 11, 20 }, visible);
}

test "window_kind: normal과 quick 분류(값에 라우팅 의미 없이 분류만)" {
    const normal_win = WindowMembershipSnapshot{ .window_id = 1, .window_kind = .normal, .surface_ids = &fx_a_ids };
    const quick_win = WindowMembershipSnapshot{ .window_id = 3, .window_kind = .quick, .surface_ids = &fx_q_ids };
    try std.testing.expectEqual(WindowKind.normal, normal_win.window_kind);
    try std.testing.expectEqual(WindowKind.quick, quick_win.window_kind);
    try std.testing.expect(normal_win.window_kind != quick_win.window_kind);
}

// ── 커버리지 보강(test/foundation-coverage-gaps) ──────────────────────────────────────────────────────────

// 문서화된 결정론 계약(line 58~59): 앱 전역 surface_id는 정상적으로 한 window에만 나타나지만, fake/조립 입력이
// 어긋나 같은 surface가 두 window에 실려도 windowOfSurface는 **첫 매치만** 반환한다(판정을 결정론적으로 고정).
// 이 불변식이 무너지면 window scope 판정이 입력 순서에 따라 흔들린다.
test "windowOfSurface: 같은 surface가 두 window에 중복돼도 첫 매치만 반환(결정론)" {
    const dup_a = [_]u64{ 10, 99 };
    const dup_b = [_]u64{99}; // 99가 A·B 양쪽에 등장(어긋난 입력)
    const windows = [_]WindowMembershipSnapshot{
        .{ .window_id = 1, .window_kind = .normal, .surface_ids = &dup_a },
        .{ .window_id = 2, .window_kind = .normal, .surface_ids = &dup_b },
    };
    const w = windowOfSurface(&windows, 99).?;
    try std.testing.expectEqual(@as(u64, 1), w.window_id); // 첫 매치(window 1), 둘째(window 2) 아님.
    // 없는 surface는 null.
    try std.testing.expect(windowOfSurface(&windows, 12345) == null);
}

// 경계값: collectVisibleSurfaces의 절단 분기(`if (n >= out.len)`)의 극단 = out.len==0. 어떤 것도 쓰지 않고
// 즉시 빈 slice를 돌려줘야 한다(첫 write 전 절단, out-of-bounds 없음).
test "collectVisibleSurfaces: out 길이 0이면 아무것도 쓰지 않고 빈 slice(절단 경계 극단)" {
    var none: [0]u64 = undefined;
    const visible = collectVisibleSurfaces(&fx_windows, 10, .all, &none);
    try std.testing.expectEqual(@as(usize, 0), visible.len);
}
