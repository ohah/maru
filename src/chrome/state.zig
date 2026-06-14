//! Chrome 상호작용 상태 단일 소유(hover/drag 등). 현재 app_dev_session에 흩어진 15개 필드
//! (hovered_slot/hovered_tab/divider_drag/tab_drag_*/…)를 한 곳으로 모아, 트리 변형 시 stale 포인터
//! 무효화의 **단일 출처**가 되게 한다(흩어진 null화로 한 경로를 빠뜨리는 UAF 방지).
//!
//! C0(Notice는 키보드 전용)는 상호작용 상태가 없어 비어 있다. hover/drag 필드와
//! `invalidateForStructuralChange`(S1 구조-무효화 계약)는 tabbar/divider 이주(C2/C3)에서 채워진다.
//! 핵심 계약(미리 자리만): 트리(split/tab/pane)가 바뀌면 host가 이 메서드를 불러 라이브-트리를 가리키던
//! 포인터를 일괄 무효화한다 — 스냅샷 가드는 UAF를 못 잡으므로 이 계약이 필수다.
//! 단일 출처: docs/chrome-strategy.md §5.5, docs/layering-and-portability.md §6.

pub const ChromeState = struct {
    // C2/C3에서 추가: hovered_slot: ?usize, hovered_tab, divider_drag, tab_drag_*, …

    /// 트리 변형 후 해제될 노드를 가리키던 hover/drag 포인터를 일괄 무효화(단일 출처). **이미 배선됨**(S1):
    /// session의 Pane-해제 chokepoint(`DevSession.invalidateForFreedPane` ← `destroyPane`)가 이 메서드를 부른다.
    /// 지금은 무동작 — 라이브-트리 포인터를 아직 session이 소유하기 때문이다. C2/C3에서 핸들 기반 드래그 상태가
    /// ChromeState로 이주하면 그 무효화를 여기서 떠맡는다(호출 지점은 chokepoint라 그대로 유지). 멱등이어야 한다
    /// (chokepoint가 Pane마다 부르므로) — 핸들 null화는 반복해도 안전.
    pub fn invalidateForStructuralChange(self: *ChromeState) void {
        _ = self;
    }
};
