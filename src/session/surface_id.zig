//! SurfaceIdAllocator — 앱 인스턴스 전역 surface_id 발급기 (L2 순수, OS-중립).
//!
//! `surface_id`는 앱 인스턴스 전역 unique **opaque** u64다. 값 비트에는 window/session/local index 의미를
//! 넣지 않는다 — 단조 증가하는 카운터일 뿐이며, **절대 재사용하지 않는다**(죽은 surface를 가리키는 옛 selector가
//! 새 surface로 리다이렉트될 수 없게 하는 주 방어 — docs/control-plane.md §3). generation은 M0a 범위 밖으로,
//! surface_id를 유지한 채 런타임만 갈리는 경로를 다루는 M1에서 모델한다.
//!
//! **스레드 계약: 메인 스레드 전용(plain u64, atomic 아님).** 발급 호출처(app_session.createTerm ← createTab·
//! createPane·createTermFromSurface/restore)는 전부 메인 이벤트이고, 리더 스레드는 core_mutex 아래 ring/scrollback만
//! 만지고 세션 트리(따라서 이 allocator)는 건드리지 않는다. 그래서 원자성 없이 plain u64로 둔다. 이 타입은 L2
//! 순수 코드라 "어느 스레드가 메인인가"라는 앱 문맥을 모르므로 런타임 assert 대신 이 주석으로 계약을 고정한다
//! (docs/window-surface-mobility.md §8 M0a: "assert(main-thread) 주석으로 계약을 고정"). 인스턴스 소유는 L4다
//! (app_session이 앱 전역 인스턴스 하나를 모든 창에 공유 — M1 AppRuntime이 그 소유를 넘겨받는다).

const std = @import("std");

pub const SurfaceIdAllocator = struct {
    /// 다음에 발급할 값. 1부터 시작한다 — 0은 절대 발급하지 않아 "미할당" sentinel로 쓸 수 있다(기존 per-session
    /// 카운터도 1부터였다 — 앱 최초 surface는 그대로 id 1이라 발급 시작값 동작이 보존된다).
    next_id: u64 = 1,

    /// 다음 surface_id를 발급한다. 단조 증가·비재사용(발급값은 다시 나오지 않는다). 메인 스레드 전용(위 계약).
    pub fn next(self: *SurfaceIdAllocator) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

test "monotonic: 연속 발급은 엄격히 순증가한다" {
    var a: SurfaceIdAllocator = .{};
    var prev = a.next();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const cur = a.next();
        try std.testing.expect(cur > prev);
        prev = cur;
    }
}

test "non-reuse: 한 번 발급한 값은 다시 발급되지 않는다" {
    var a: SurfaceIdAllocator = .{};
    var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer seen.deinit();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const id = a.next();
        try std.testing.expect(!seen.contains(id)); // 이미 나온 적 없어야 한다
        try seen.put(id, {});
    }
}

test "opaque: 값에 window/session/local index 의미가 없다 — 단조 카운터일 뿐" {
    // 두 allocator가 독립이라도 각자 1,2,3,…을 그대로 낸다(값에 인스턴스 식별 비트가 인코딩돼 있지 않다).
    // 계약: 외부는 surface_id를 위치·기원을 설명하지 않는 불투명 handle로만 취급한다(docs/control-plane.md §3).
    var a: SurfaceIdAllocator = .{};
    var b: SurfaceIdAllocator = .{};
    try std.testing.expectEqual(@as(u64, 1), a.next());
    try std.testing.expectEqual(@as(u64, 2), a.next());
    try std.testing.expectEqual(@as(u64, 1), b.next()); // b는 a와 무관하게 1부터 — 값에 인스턴스 비트 없음
    try std.testing.expectEqual(@as(u64, 3), a.next());
}
