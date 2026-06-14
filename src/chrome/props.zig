//! Props = 컴포넌트가 읽는 **불변 모델 뷰**(seam). host가 매 프레임 session/terminal 모델에서 빌드해
//! 넘긴다. 컴포넌트는 session을 직접 모른다(raw *Pane/*Split를 노출하지 않는다). C0/Notice는 metrics만
//! 필요하다. workspaces·active_tree(LeafRect/DividerSeg)·pane_tabs 같은 풀 필드는 tabbar/sidebar 이주
//! (C2/C3)에서 추가한다. 단일 출처: docs/chrome-strategy.md §5.5, docs/layering-and-portability.md §3.

/// 그리드/픽셀 메트릭(전부 plain 값 — terminal 타입을 import하지 않는다).
pub const CellMetrics = struct {
    cell_width_px: u32,
    cell_height_px: u32,
    sidebar_width_px: u32,
    backing_width_px: u32,
    backing_height_px: u32,
    chrome_minimal: bool = false,
};

pub const ChromeProps = struct {
    metrics: CellMetrics,
};
