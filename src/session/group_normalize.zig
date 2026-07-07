//! 사이드바 그룹 정규화 — **L2 순수 함수**(OS-중립). M3c(docs/window-surface-mobility.md §8A.4).
//!
//! 위치 파생 그룹 모델(docs/sidebar-groups.md §2.1)의 **정규화 프리미티브**를 L4 `app_session`에서 이 L2 모듈로
//! **리프트**한다(§8A.4 결정: "L2로 리프트한다"). 승계·핀 재정규화·depth 파생은 인접 tab/meta 슬라이스만 읽고/쓰는
//! **순수 연산**(할당·surface·registry·drag-preview 미참조)이라, `WindowGraph.moveWorkspace`(그룹 workspace 창 간
//! 이동)와 L4 `closeTab`/`removeFromGroupForTab`이 **같은 함수를 재사용**한다(재구현·shim 금지 —
//! [[full-removal-no-legacy-shims]]). 행동 보존이 핵심: 이 함수들은 L4 원본과 **동일 결과**를 내야 하고
//! (기존 sidebar 그룹 테스트가 리프트 후에도 green), 발산은 곧 회귀다.
//!
//! **generic over `*T`**: 두 호출처가 "그룹 필드를 든 노드의 포인터 슬라이스"를 그대로 넘긴다 —
//!   - L4 `app_session`: `self.tabs.items`(`[]*Tab`, `T = session_model.Tab`).
//!   - L2 `window_graph`: 원본 `WorkspaceMeta`를 가리키는 `[]*WorkspaceMeta`(`moveWorkspace`가 임시로 수집).
//! `items[i]`가 `*T`라 `items[i].group_start`는 auto-deref로 읽고, `items[i].pinned = x`는 포인터를 통해 실제 노드를
//! 갱신한다(값 복사가 아니라 원본 mutate). `T`는 아래 필드를 모두 가져야 한다(duck-typed comptime):
//! `group_start: ?[]const u8`, `group_collapsed: bool`, `group_depth: u8`, `group_color: u32`,
//! `pinned: bool`, `local_pinned: bool`, `top_level: bool`.
//!
//! **drag-preview 게이트는 L4에 남는다**(§8A.4): `normalizePinnedFromGroups`의 `sidebar_drag_preview != null` early
//! return은 라이브 드래그 상태 의존이라 L4 호출부(`app_session`)의 얇은 wrapper가 판정하고, 이 L2 코어는 순수하게
//! 정규화만 한다. **스레드**: 메인 스레드 전용(세션 트리는 메인 이벤트에서만 만진다 — window_graph.zig 계약과 동일).
//! L2 순수라 런타임 assert 대신 주석으로 고정한다.

const std = @import("std");

/// 위치 파생 정규화 depth 스택 상한(무한 중첩·u8 오버플로 방지). app_session의 옛 `max_group_nesting`과 동일 값 —
/// 리프트로 단일 출처가 이 L2 모듈로 이동한다(L4 wrapper는 이 상수를 신경 쓸 필요 없이 위임만).
pub const max_group_nesting: usize = 32;

/// 위치 idx 시점의 위치 파생 depth를 재계산한다(스택 재실행). idx가 마커면 그 마커의 정규화 eff_depth, 카드면 소속
/// 그룹 depth(0=최상위). create_group(중첩 생성 depth=카드 depth+1)·groupSubtreeEnd(마커 eff_depth)·
/// normalizePinnedFromGroups가 공유한다. **order-aware(SG8a)**: `order`(위치→원본 순열)·`group_depth`(위치별 마커
/// 선언 depth)가 non-null이면 그 가상 배치 위에서 계산하고, **둘 다 null이면 items를 identity로** 스캔한다 — null
/// 경로는 옛 L4 동작과 byte-identical(드래그/create 경로가 그대로 쓴다). 순수 함수(할당 없음, 스택 버퍼만).
pub fn effectiveDepthAt(comptime T: type, items: []const *T, idx: usize, order: ?[]const usize, group_depth: ?[]const u8) u8 {
    const n = if (order) |o| o.len else items.len;
    var stack: [max_group_nesting]u8 = undefined;
    var top: usize = 0;
    var prev_pinned: ?bool = null; // 핀 리전 경계 추적(§12 GP1)
    var i: usize = 0;
    while (i < idx and i < n) : (i += 1) {
        const ti = if (order) |o| o[i] else i;
        const pin = items[ti].pinned;
        if (prev_pinned) |pp| if (pin != pp) { // 핀 리전 경계 → 스택 리셋(subtree는 리전을 못 넘는다)
            top = 0;
        };
        if (items[ti].top_level) top = 0; // §2.1 재설계(§14) top_level edge 경계 — 최상위 복귀(pass1과 동형)
        prev_pinned = pin;
        if (items[ti].group_start != null) {
            const dd: u8 = @max(@as(u8, 1), if (group_depth) |g| g[i] else items[ti].group_depth);
            while (top > 0 and stack[top - 1] >= dd) top -= 1;
            const parent: u8 = if (top > 0) stack[top - 1] else 0;
            if (top < stack.len) {
                stack[top] = parent + 1;
                top += 1;
            }
        }
    }
    if (idx < n) {
        const ti = if (order) |o| o[idx] else idx;
        const pin = items[ti].pinned;
        if (prev_pinned) |pp| if (pin != pp) { // idx가 새 핀 리전의 첫 위치면 스택 리셋(카드=0·마커=parent+1 from empty)
            top = 0;
        };
        if (items[ti].top_level) top = 0; // §2.1 재설계(§14) top_level edge 경계 — idx가 top카드면 depth 0
        if (items[ti].group_start != null) {
            const dd: u8 = @max(@as(u8, 1), if (group_depth) |g| g[idx] else items[ti].group_depth);
            while (top > 0 and stack[top - 1] >= dd) top -= 1;
            const parent: u8 = if (top > 0) stack[top - 1] else 0;
            return parent + 1;
        }
    }
    return if (top > 0) stack[top - 1] else 0;
}

/// from(자기 포함)에서 **위로** 가장 가까운 group_start 마커의 인덱스 — §2.1 소속 파생(각 카드의 소속 = 자기 위에서
/// 가장 가까운 그룹 시작 마커). 위에 마커가 없으면 null(최상위 카드). **핀 리전 클램프(§12 GP1)**: 소속 마커는 from과
/// **같은 핀 리전**이어야 한다(pin ⊃ group). **top_level 클램프(§14)**: 상위 마커 스캔이 top_level 최상위 복귀 지점에
/// 닿으면 null(top-level run은 그룹 아님). `clearStaleLocalPins`와 `WindowGraph.moveWorkspace`(멤버/최상위 판정)가
/// 공유한다. from은 유효 인덱스라 가정.
pub fn enclosingGroupMarkerIndex(comptime T: type, items: []const *T, from: usize) ?usize {
    const pin = items[from].pinned;
    var i = from;
    while (true) : (i -= 1) {
        if (items[i].pinned != pin) return null; // 핀 리전 경계를 넘음 — 이 리전엔 상위 마커 없음
        if (items[i].top_level) return null; // §14: 최상위 복귀 지점 — top-level run은 그룹 아님
        if (items[i].group_start != null) return i;
        if (i == 0) return null;
    }
}

/// 그룹 시작 마커 노드(from)의 마커(group_start/collapsed/depth/color/**pinned**)를 **다음 노드**로 승계한다 —
/// closeTab(닫힘)·removeFromGroupForTab(빼기)·moveWorkspace(창 간 이동) 공유(§8A.4 (b)). 다음 노드가 존재하고 자기
/// group_start가 없을 때만(연속 파티션상 "그룹 안 다음 카드") 소유권을 이전하고 true를 반환한다(from.group_start는
/// null화 — double-free 방지). 승계 불가(다음 없음·이미 마커·다른 핀 리전·다음이 top_level leaf)면 false를 반환하고
/// from.group_start는 그대로 둔다(호출자가 free/이동 처리 — 그룹 소멸). 소속 카드는 위치 파생이라 별도 이전 없음(§2.1).
/// **same-region 가드(§12 GP1)**·**leaf-only 가드(§13.8·§14.1)**는 옛 L4 로직 그대로 — 승계 대상 next는 같은 핀 리전
/// (`next.pinned == src.pinned`)이고 `!next.top_level`(경계 홀더는 그룹 헤더가 될 수 없음)일 때만 진짜 멤버다. from은
/// 유효 인덱스라 가정. 문자열(group_start)은 노드 소유(borrowed 이전만) — 이 함수는 free하지 않는다.
pub fn inheritGroupMarker(comptime T: type, items: []*T, from: usize) bool {
    const src = items[from];
    const marker = src.group_start orelse return false;
    if (from + 1 < items.len and items[from + 1].group_start == null and
        items[from + 1].pinned == src.pinned and !items[from + 1].top_level)
    {
        const next = items[from + 1];
        next.group_start = marker; // 소유권 이전(SG5-2 색·SG5-3 depth도 마커 따라 이동, 자식은 위치 파생 유지)
        next.group_collapsed = src.group_collapsed;
        next.group_depth = src.group_depth;
        next.group_color = src.group_color;
        next.pinned = src.pinned; // 그룹 고정 권위 승계(§12.7 보강 6 — 승계로 고정 소실 방지)
        src.group_start = null; // double-free 방지(다음 노드가 소유)
        return true;
    }
    return false;
}

/// 그룹 멤버 카드의 `pinned`를 **enclosing 그룹 마커의 pinned로 재기록**한다(그룹 고정 C2, docs/sidebar-groups.md
/// §12.5 GP2). 마커 탭 pinned = 그룹 고정 **권위**, 멤버 카드 pinned = 파생 캐시라, 전역 partition(countPinnedTabs 등)이
/// 마커만 읽고 옮기면 그룹이 shred되므로 멤버를 마커 값으로 동기한다. **suffix-exclusion(§12.5 + code-review #3)**:
/// 각 최상위 그룹의 pin-무시 구조 subtree [i, e)(effectiveDepthAt + 형제/얕은 마커 break + **top_level 하드 break**)에서
/// 마커 pin이 **마지막으로 일치**하는 위치 last_match까지를 진짜 멤버 범위로 보고 재기록하고, 그 뒤 꼬리(다음 핀 리전의
/// genuine 최상위 카드)는 **배제**한다 — 사이에 낀 desync 멤버는 흡수(치유)하되 pin 경계를 넘어 오염시키지 않는다.
/// top_level 0개면 옛 suffix-exclusion과 byte-identical. **순수 코어** — L4의 `sidebar_drag_preview != null` 드래그
/// 게이트는 L4 wrapper가 판정한다(§8A.4: drag 게이트는 L4 잔류).
pub fn normalizePinnedFromGroups(comptime T: type, items: []*T) void {
    const n = items.len;
    var i: usize = 0;
    while (i < n) {
        const marker = items[i];
        if (marker.group_start == null) {
            i += 1; // 최상위 카드(top_level 복귀 카드 포함) — 개별 pin이라 자기 값 유지(재기록 없음)
            continue;
        }
        const eff = effectiveDepthAt(T, items, i, null, null);
        const pin = marker.pinned; // 마커 = 그룹 고정 권위(§12.2)
        var e = i + 1;
        while (e < n) : (e += 1) {
            const t = items[e];
            if (t.group_start != null and @max(@as(u8, 1), t.group_depth) <= eff) break; // 형제/얕은 마커 = soft 구조 경계
            if (t.top_level) break; // §14 top_level 서브파티션 경계 — 그룹 뒤 top카드에서 subtree 끝
        }
        // suffix-exclusion: 마커 pin이 마지막으로 일치하는 위치까지가 진짜 멤버 범위. 그 뒤 꼬리는 다음 리전 genuine 카드라 배제.
        var last_match = i;
        var k = i + 1;
        while (k < e) : (k += 1) if (items[k].pinned == pin) {
            last_match = k;
        };
        k = i + 1;
        while (k <= last_match) : (k += 1) items[k].pinned = pin; // 진짜 멤버(사이 desync 흡수)만 마커 pin으로 재기록
        i = e; // 구조 subtree 통째 처리 — 꼬리/top카드는 다음 마커/리전이 다룬다
    }
}

/// 그룹 leaf 멤버가 **아닌** 노드(그룹 마커·최상위 카드)의 stale `local_pinned`를 클리어한다(GL §13.7 보강4). 로컬 pin은
/// "그룹 안 leaf 멤버의 위치 고정"이라(§13.8), 멤버가 top-level로 전이하면(ungroup·removeFromGroup·창 간 이동 등) 로컬
/// pin이 무의미해진다 — 고아 stale 📌를 원천 차단한다. 판정: `group_start != null`(마커)이거나 `enclosingGroupMarkerIndex
/// == null`(어느 그룹에도 안 속한 최상위 카드)면 클리어. 중첩 부모 그룹으로 재소속된 멤버는 여전히 그룹 안 leaf라 유지된다.
/// 로컬 pin 0개면 no-op(byte-identical). 전이 지점(ungroupTab·removeFromGroupForTab·promoteTabToTopLevelInPlace·
/// commitSidebarDragPreview·beginGroupForTab·moveWorkspace)이 각자 정렬 **뒤** 1회 부른다 — 단일 출처 위생 스윕.
pub fn clearStaleLocalPins(comptime T: type, items: []*T) void {
    for (items, 0..) |t, i| {
        if (!t.local_pinned) continue;
        if (t.group_start != null or enclosingGroupMarkerIndex(T, items, i) == null) t.local_pinned = false;
    }
}

test {
    std.testing.refAllDecls(@This());
}
