//! Props = 컴포넌트가 읽는 **불변 모델 뷰**(seam). host가 매 프레임 session/terminal 모델에서 빌드해
//! 넘긴다. 컴포넌트는 session을 직접 모른다(raw *Pane/*Split를 노출하지 않는다). C0/Notice는 metrics만
//! 필요하다. workspaces·active_tree(LeafRect/DividerSeg)·pane_tabs 같은 풀 필드는 tabbar/sidebar 이주
//! (C2/C3)에서 추가한다. 단일 출처: docs/chrome-strategy.md §5.5, docs/layering-and-portability.md §3.

/// 그리드/픽셀 메트릭(전부 plain 값 — terminal 타입을 import하지 않는다).
pub const CellMetrics = struct {
    cell_width_px: u32,
    cell_height_px: u32,
    sidebar_width_px: u32, // 런타임 가변(사용자 드래그) — session 실측값이 권위
    sidebar_slot_height_px: u32 = 0, // 사이드바 워크스페이스 **카드** 한 슬롯의 높이(= cell_height × ratio, cell 높이가 아님).
    // sidebar 컴포넌트의 밴드 view·hit-test가 슬롯↔px 변환에 쓴다(C3a). 기본 0 = 사이드바 꺼짐/미설정(view 무동작).
    sidebar_header_row_h_px: u32 = 0, // **그룹 헤더 row**의 높이(가변 높이 — 카드=slot·헤더=이 값, 얇은 한 줄; SG3b-2-ii,
    // docs/sidebar-groups.md §5). hit-test(slotAt/rowTop/dragTargetSlot의 rowHeight 누적)·렌더가 카드와 다른 높이로 쓴다.
    // 기본 0. 위 sidebar_slot_height_px와 이름이 비슷한 상단 사이드바 헤더(검색바·아이콘, 아래 문단)와는 다른 값이다.
    // 상단 헤더(검색바·아이콘) 높이는 platform이 hit-test(slotAt/headerHit)에 직접 넘기고 .m이 사이드바 셀 py_top에
    // 더한다 — 밴드 view는 슬롯 상대 좌표라 상단 헤더를 모른다(lowerSidebar의 rect.y/slot_h 행 역산과 일치).
    /// 사이드바 우측에서 스크롤바가 **상시** 예약하는 폭(track 폭 + inset). 밴드·카드 텍스트가 이만큼
    /// 좁아진다 — 스크롤바가 나타나고 사라져도 폭이 안 변해야 목록이 reflow하지 않는다
    /// (docs/scroll-area.md §4). 0이면 예약 없음(스크롤바가 카드 위에 뜨던 옛 동작).
    sidebar_scroll_gutter_px: u32 = 0,
    /// 오버레이(팔레트·세팅) 목록 우측에서 스크롤바가 **상시** 예약하는 폭. 사이드바 gutter와 같은
    /// 규율이다 — 막대가 나타나고 사라져도 폭이 안 변해야 목록이 reflow하지 않는다. 0이면 예약 없음.
    overlay_scroll_gutter_px: u32 = 0,
    backing_width_px: u32,
    backing_height_px: u32,
    // 사이드바·titlebar만 뺀 전체 workspace rect. terminal·divider·전역 파일 도크를 모두 포함하며,
    // 전역 모달/palette 중심의 권위다. workspace_present=false인 옛 호출자만 레거시 backing-sidebar로 폴백.
    workspace_x_px: u32 = 0,
    workspace_y_px: u32 = 0,
    workspace_width_px: u32 = 0,
    workspace_height_px: u32 = 0,
    workspace_present: bool = false, // zero-size 권위 rect와 legacy 미지정 sentinel을 구분한다.
    // minimal 세션(사이드바·pane 탭 바 숨김)인지. C2/C3 사이드바·탭바 컴포넌트가 렌더 게이트로 읽는다
    // (chrome-strategy.md §5.5 계획). sidebar_width_px==0으로 완전 파생되진 않는다(탭 바도 숨기므로) — 별도 신호.
    chrome_minimal: bool = false,
};

/// C4b 박스 모양 토큰(seam) — host가 tokens.space에서 빌드해 넘긴다. tui=0(직각 → lowering이 셀 fill),
/// rich>0(둥근 → GPU quad). 컴포넌트는 이 값을 Op.quad에 실어 같은 코드로 두 룩을 만든다(C4a 색 분리와 동형).
pub const ShapeTokens = struct {
    corner_radius_px: u16 = 0,
    border_width_px: u16 = 0,
    // C4b 모달: 배경 박스가 텍스트보다 큰 안쪽 여백(px). view가 폭 상한을 이 값의 2배만큼 줄여(텍스트 폭 양보)
    // platform lowering의 ±pad 확장 후에도 박스가 터미널 영역 안에 들도록 한다(box geometry 단일 출처=view).
    modal_padding_px: u16 = 0,
    // NOTE: `card_gap_px`는 여기 없다. 밴드 인셋이 폐기되면서(docs/sidebar-agent-list.md §3.2 — 밴드=클릭 행)
    // chrome 쪽 소비처가 0이 됐고, 남은 용도(카드 텍스트 좌측 들여쓰기)는 platform이 `tokens.space.card_gap_px`를
    // 직접 읽는다. 값을 props로 계속 실어 나르면 "여길 바꾸면 카드 간격이 바뀐다"는 거짓 seam이 남는다.
};

/// 활성 pane(분할 leaf)의 backing px 사각형 — 사이드바·탭 바·window padding을 뺀 셀 그리드 영역(platform
/// `active_pane_rect` 미러). **find 오버레이를 활성 pane 우상단에 붙이는 위치의 단일 출처**다. palette는 안 쓴다
/// (전역 명령이라 창 중앙 유지 — overlay_input.panelLayout). w==0이면 미초기화 → findLayout이 창 전체(사이드바
/// 오른쪽 터미널 영역)로 폴백해 단일-pane·헤드리스 테스트에서도 안전하다. 좌표·크기는 split_tree.Rect와 같은 u32.
pub const PaneRect = struct { x: u32 = 0, y: u32 = 0, w: u32 = 0, h: u32 = 0 };

pub fn workspaceRect(m: CellMetrics) PaneRect {
    if (m.workspace_present) return .{
        .x = m.workspace_x_px,
        .y = m.workspace_y_px,
        .w = m.workspace_width_px,
        .h = m.workspace_height_px,
    };
    return .{ .x = m.sidebar_width_px, .y = 0, .w = m.backing_width_px -| m.sidebar_width_px, .h = m.backing_height_px };
}

test "workspaceRect distinguishes an authoritative zero-size workspace from legacy omission" {
    const base = CellMetrics{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 200, .backing_width_px = 1200, .backing_height_px = 800 };
    try @import("std").testing.expectEqual(PaneRect{ .x = 200, .y = 0, .w = 1000, .h = 800 }, workspaceRect(base));

    var authoritative = base;
    authoritative.workspace_x_px = 200;
    authoritative.workspace_y_px = 40;
    authoritative.workspace_width_px = 0;
    authoritative.workspace_height_px = 0;
    authoritative.workspace_present = true;
    try @import("std").testing.expectEqual(PaneRect{ .x = 200, .y = 40, .w = 0, .h = 0 }, workspaceRect(authoritative));
}

pub const ChromeProps = struct {
    metrics: CellMetrics,
    /// C4b: 박스 모양(둥근 모서리·테두리). tui=0(직각·셀 fill), rich>0(둥근·GPU quad).
    shape: ShapeTokens = .{},
    /// 활성 pane rect(find 오버레이 위치 단일 출처). 기본 0 = 미초기화(findLayout이 창 전체로 폴백).
    active_pane: PaneRect = .{},
};
