//! Props = 컴포넌트가 읽는 **불변 모델 뷰**(seam). host가 매 프레임 session/terminal 모델에서 빌드해
//! 넘긴다. 컴포넌트는 session을 직접 모른다(raw *Pane/*Split를 노출하지 않는다). C0/Notice는 metrics만
//! 필요하다. workspaces·active_tree(LeafRect/DividerSeg)·pane_tabs 같은 풀 필드는 tabbar/sidebar 이주
//! (C2/C3)에서 추가한다. 단일 출처: docs/chrome-strategy.md §5.5, docs/layering-and-portability.md §3.

/// 그리드/픽셀 메트릭(전부 plain 값 — terminal 타입을 import하지 않는다).
pub const CellMetrics = struct {
    cell_width_px: u32,
    cell_height_px: u32,
    sidebar_width_px: u32, // 런타임 가변(사용자 드래그) — session 실측값이 권위
    sidebar_slot_height_px: u32 = 0, // 사이드바 워크스페이스 한 슬롯의 높이(= cell_height × ratio, cell 높이가 아님).
    // sidebar 컴포넌트의 밴드 view·hit-test가 슬롯↔px 변환에 쓴다(C3a). 기본 0 = 사이드바 꺼짐/미설정(view 무동작).
    backing_width_px: u32,
    backing_height_px: u32,
    // minimal 세션(사이드바·pane 탭 바 숨김)인지. C2/C3 사이드바·탭바 컴포넌트가 렌더 게이트로 읽는다
    // (chrome-strategy.md §5.5 계획). sidebar_width_px==0으로 완전 파생되진 않는다(탭 바도 숨기므로) — 별도 신호.
    chrome_minimal: bool = false,
};

pub const ChromeProps = struct {
    metrics: CellMetrics,
};
