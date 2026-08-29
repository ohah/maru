//! 파일 패널 전역 도크의 순수 기하. 창 backing px에서 터미널·도크·divider·tab/header/content rect를 한 번에
//! 파생해 렌더·hit-test·WKWebView 전이가 같은 좌표를 소비하게 한다. AppKit/renderer/PTY 의존은 없다.

const std = @import("std");
const i18n = @import("../i18n.zig"); // 표시 문자열 단일 출처
const dock_panel = @import("dock_panel.zig");
const layout_math = @import("layout_math.zig");
const Rect = @import("split_tree.zig").Rect;

/// FP16: 도크가 탐색기·소스 컨트롤을 보일 때의 자동 폭 기준. 420/240pt는 editor(문서 본문) + tree를 함께
/// 담던 시절의 값이라 트리만 있는 지금은 화면을 절반 가까이 먹는다. 좌측 사이드바(카드 목록)와 같은
/// 성격의 목록 열이므로 그쪽 기본값에 맞춘다 — `theme.SidebarConfig.width_pt` 기본 180pt와 같은 값이다
/// (레이어가 달라 상수를 공유하진 못하고 값만 맞춘다, 그 필드 주석과 같은 규율).
/// 하한도 "문서를 담아야 한다"는 근거가 사라져 사이드바 하한(120pt)과 같은 자리로 내린다.
pub const default_right_pt: u32 = 180;
/// Session Dock은 제목·세그먼트·검색·카드 metadata가 한 column 안에 공존하므로, `size == 0` 자동 상태에서만
/// explorer/source-control보다 넓게 시작한다. 수동으로 저장한 nonzero size는 이 값으로 덮지 않는다.
pub const default_agent_sessions_right_pt: u32 = 640;
/// 이미지 갤러리는 **격자**라 한 열짜리 목록보다 넓어야 열이 선다. 썸네일이 160px(계약 §5.2)이고 2x 디스플레이면
/// 80pt이므로, 4열(320pt)에 여백과 스크롤 거터를 더한 자리다. **첫 값이며 격자를 실제로 그린 뒤 조정한다** —
/// 지금은 열 수를 실측한 적이 없다.
pub const default_image_gallery_right_pt: u32 = 420;
pub const min_right_pt: u32 = 120;
/// bottom은 가로 띠라 성격이 다르다(폭이 아니라 높이). 트리 행이 몇 줄은 보여야 하므로 그대로 둔다.
pub const default_bottom_pt: u32 = 300;
pub const min_bottom_pt: u32 = 160;
/// dock Zig divider target을 넓히는 최대 logical-point 폭. native에는 이 값을 그대로 내리지 않고,
/// `AppSession.collectWebSurfaces`가 최종 padded frame과 이 target의 edge별 교집합만 ABI로 전달한다.
pub const divider_grab_band_pt: u32 = 10;

/// 위 최대 logical 폭을 Zig backing-pixel target으로 올림 변환한다. native pass-through는 이 target과
/// final WebView frame의 교집합만 소비해 1x/분수/2x에서도 resize target 밖 dead band를 만들지 않는다.
pub fn dividerGrabBandPx(scale_milli: u32) u32 {
    const scale = if (scale_milli == 0) 1000 else scale_milli;
    return @intCast((@as(u64, divider_grab_band_pt) * scale + 999) / 1000);
}

pub const Geometry = struct {
    /// 사이드바와 titlebar strip만 제외한 전체 작업영역. terminal·divider·dock의 합이며 전역 모달 중심의 권위다.
    workspace: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// 왼쪽 사이드바 띠 — **작업영역 왼쪽 밖**이다(`workspace.x` 가 이 폭만큼 밀려 있다).
    ///
    /// **왜 여기 있나**: 입력 라우팅이 "이 좌표가 어느 영역인가" 를 한 곳에서 물어야 하는데
    /// (`regionAt`), 사이드바만 그 목록에 없어서 호출자가 `x < sidebar_width_px` 를 손으로 적어야
    /// 했다. 그러면 경계 한 픽셀이 플랫폼마다 갈린다 — 도크·디바이더가 이미 겪은 실패다.
    ///
    /// **창 맨 위에서 시작한다 — 타이틀바 띠를 포함한다.** 그 띠의 사이드바 폭만큼은 창 chrome 이
    /// 아니라 **사이드바 헤더의 아이콘 줄**이다: macOS 는 그 자리에 신호등이 있어 아이콘을 오른쪽에
    /// 몰았고(`sidebar.headerHit` 의 마지막 줄이 "줄0 좌측 = 네이티브 신호등 영역"), Windows 는
    /// 캡션 버튼이 오른쪽 끝이라 그 자리가 비어 있다. 띠 아래에서 시작하게 두면 아이콘 줄과 창
    /// 버튼이 **다른 줄에 놓여** 띠가 둘로 갈린다(사용자 지적 2026-08-25).
    ///
    /// 아래로는 작업영역 바닥까지다 — 상태바는 창 전폭이라 사이드바 밖이다.
    sidebar: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    terminal: Rect,
    dock: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    divider: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// 도크 최상단 뷰 스위처(docs/file-explorer.md §3.5). 옛 제목 행을 흡수해 **chrome 2행**을 쓰고, 도크가
    /// 낮으면 1행 → 0행 순으로 줄인다 — 스위처가 콘텐츠를 굶기지 않는다.
    view_bar: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// 현재 뷰 영역 = 도크에서 `view_bar`를 뺀 나머지. FP16에서 도크에 남은 건 탐색기뿐이었고 그때는 이게
    /// 도크 전체였다. 옛 `editor`/`tab_bar`/`header`/`content`(그룹 split tree의 좌측 칼럼과 그 chrome)와 그 둘을
    /// 가르던 `tree_divider`는 대상이 사라져 없앴다 — 파일 탭 바·헤더 밴드는 이제 워크스페이스 pane이 소유한다(§3.1).
    tree: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// 현재 뷰의 본문(스크롤 영역) = 뷰 영역 전체. 옛 `tree_header`("탐색기" 제목 한 행)는 **제거했다** —
    /// 뷰 스위처가 지금 보는 뷰를 이미 알려 주므로 같은 말을 글자로 한 번 더 적을 이유가 없고, 그 자리를
    /// 아이콘 영역에 돌려줬다(사용자 요청 2026-07-31).
    tree_content: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// 창 바닥 상태표시줄(SB1). **창 전폭**이라 `workspace`(사이드바·titlebar 제외) 안에 살지 않는다 —
    /// x=0이고 w=창 전체 폭이라, 사이드바 strip 아래까지 지나간다. 그래서 `compute`가 `available`을 만들기
    /// **전에** 창 높이에서 먼저 깎는다: 그래야 terminal·dock·divider가 전부 한 번에 짧아진다.
    ///
    /// **기본값을 일부러 안 준다.** 기본값을 주면 아래 조기 반환 셋(`!visible`·`dock_w==0`·`dock_h==0`)이
    /// 컴파일 에러 없이 빈 rect를 흘려, 가장 흔한 상태에서만 상태바가 조용히 사라진다
    /// (docs/metal-ui-layout-paint.md §5 "rect를 더하는 것과 자리를 예약하는 것은 다르다"). `terminal`과 같은 규칙이다.
    status_bar: Rect,
    dock_size_px: u32 = 0,
};

/// 헤더 우측의 mode 토글 + dirty/conflict 표시 영역. 경로는 이 rect 왼쪽까지만 그린다.
///
/// **폭 산정**: markdown은 `읽기|리치|소스` 세 슬롯이고 각 라벨이 CJK 2셀×2글자 = 4칸이다. 여기에 렌더가
/// 슬롯마다 1칸을 여백으로 쓰므로(`range.start + 1`) 슬롯당 5칸이 필요하고, dirty·conflict 글리프가 둘 다
/// 보이면 4칸이 더 빠진다. 18칸이면 (18-4)/3 = 4칸/슬롯이라 첫 라벨이 잘렸다 — 19칸으로 올려 세 슬롯 모두
/// 최소 5칸을 확보한다. 슬롯이 늘면 이 값도 함께 늘려야 한다.
pub const header_control_cols: u32 = 19;

pub const HeaderCellLayout = struct {
    control_start: u16,
    mode_end: u16,
    dirty_col: ?u16,
    conflict_col: ?u16,
};

pub const HeaderModeDescriptor = struct {
    mode: dock_panel.Mode,
    /// 표시 문자열이 아니라 **키**를 든다 — 이 목록이 컨테이너 레벨 배열이라 comptime 이고,
    /// 런타임 조회(`i18n.t`)는 거기서 쓸 수 없다(`unable to resolve comptime value`).
    /// 해석은 그리는 쪽이 한다(`label()` 헬퍼). 소비처가 둘뿐이라 전파 비용도 작다.
    label_key: i18n.Key,

    /// 현재 언어로 푼 표시 문자열.
    pub fn label(self: HeaderModeDescriptor) []const u8 {
        return i18n.t(self.label_key);
    }
};

/// ABI ordinal과 독립인 헤더 시각 순서와 label의 단일 출처. markdown은 `읽기|리치|소스`, svg는 `읽기|소스`다.
/// kind가 늘어나면 여기 모드 리스트만 더한다 — layout/render/hit-test는 `modesForKind`를 순회한다.
pub const markdown_header_modes = [_]HeaderModeDescriptor{
    .{ .mode = .read, .label_key = .dock_read },
    .{ .mode = .rich, .label_key = .dock_rich },
    .{ .mode = .source_edit, .label_key = .dock_source },
};

/// svg는 문서모델로 다룰 대상이 아니라 리치가 없다(§2.5) — 프리뷰와 XML 소스 둘뿐이다.
pub const header_modes = [_]HeaderModeDescriptor{
    .{ .mode = .read, .label_key = .dock_read },
    .{ .mode = .source_edit, .label_key = .dock_source },
};

/// 이 kind가 헤더에 노출하는 mode 선택지(순서=시각 순서). 빈 슬라이스면 mode 선택기가 없다(html·text·image·pdf).
pub fn modesForKind(kind: dock_panel.EntryKind) []const HeaderModeDescriptor {
    return switch (kind) {
        .markdown => &markdown_header_modes,
        .svg => &header_modes,
        // diff는 읽기 전용 비교 결과라 mode 선택지가 없다(docs/editor-surface-dock.md §3.5).
        .html, .text, .image, .media, .pdf, .diff => &.{},
    };
}

fn modeSlotForKind(kind: dock_panel.EntryKind, mode: dock_panel.Mode) ?usize {
    for (modesForKind(kind), 0..) |descriptor, slot| if (descriptor.mode == mode) return slot;
    return null;
}

pub const HeaderModeCellRange = struct { start: u16, end: u16 };

/// mode selector 폭을 kind의 mode 개수로 균등 분할한 한 슬롯의 cell 범위. markdown=1/3씩, svg=1/2씩. 마지막 슬롯은
/// 반올림 잔여를 흡수해 정확히 `mode_end`에서 끝난다.
pub fn headerModeCellRange(layout: HeaderCellLayout, kind: dock_panel.EntryKind, mode: dock_panel.Mode) ?HeaderModeCellRange {
    const modes = modesForKind(kind);
    if (modes.len == 0) return null;
    const idx = modeSlotForKind(kind, mode) orelse return null;
    const width: u16 = layout.mode_end - layout.control_start;
    const count: u16 = @intCast(modes.len);
    const start = layout.control_start + @as(u16, @intCast((@as(u32, width) * idx) / count));
    const end = if (idx + 1 == modes.len)
        layout.mode_end
    else
        layout.control_start + @as(u16, @intCast((@as(u32, width) * (idx + 1)) / count));
    return .{ .start = start, .end = end };
}

/// Header render/background/hit-test가 공유하는 cell 권위. 각 status는 glyph 1칸+간격 1칸을 우측에서
/// 예약하며 mode rect는 status 시작 전까지만 끝난다. mode 슬롯 분할은 `headerModeCellRange`가 kind별로 한다.
pub fn headerCellLayout(cols: u16, dirty: bool, external_change: bool) ?HeaderCellLayout {
    if (cols < 6) return null;
    const control_cols: u16 = @intCast(@min(header_control_cols, cols));
    const control_start = cols - control_cols;
    const available = cols - control_start;
    var status_count: u16 = 0;
    const show_conflict = external_change and available >= 8;
    if (show_conflict) status_count += 1;
    const show_dirty = dirty and available >= 6 + (status_count + 1) * 2;
    if (show_dirty) status_count += 1;
    const mode_end = cols - status_count * 2;
    var cursor = mode_end;
    var dirty_col: ?u16 = null;
    var conflict_col: ?u16 = null;
    if (show_conflict) {
        conflict_col = cursor;
        cursor += 2;
    }
    if (show_dirty) dirty_col = cursor;
    return .{
        .control_start = control_start,
        .mode_end = mode_end,
        .dirty_col = dirty_col,
        .conflict_col = conflict_col,
    };
}

/// FP16: 헤더 밴드는 도크가 아니라 **파일 Term**이 소유한다. 그래서 이 함수군은 `Geometry` 대신 호출자가
/// 계산한 밴드 rect를 받는다 — pane leaf에서 나온 rect든 옛 도크 rect든 배치 규칙은 하나다.
pub fn headerControlRect(header: Rect, cell_width_px: u32) ?Rect {
    if (cell_width_px == 0 or header.w < cell_width_px * 6) return null;
    const cols = @min(header_control_cols, header.w / cell_width_px);
    const width = cols * cell_width_px;
    return .{ .x = header.x + header.w - width, .y = header.y, .w = width, .h = header.h };
}

/// 헤더 mode 선택지 한 칸의 rect(markdown `읽기|라이브|소스`·svg `읽기|소스`). 전체 control을 토글 버튼 하나로
/// 취급하지 않고 보이는 구간과 클릭되는 구간이 같은 rect를 공유한다. 모드 선택기가 없는 kind(html·text)는 null.
pub fn headerModeRect(header: Rect, cell_width_px: u32, kind: dock_panel.EntryKind, mode: dock_panel.Mode, dirty: bool, external_change: bool) ?Rect {
    if (modesForKind(kind).len == 0) return null;
    const control = headerControlRect(header, cell_width_px) orelse return null;
    const cols: u16 = @intCast(header.w / cell_width_px);
    const layout = headerCellLayout(cols, dirty, external_change) orelse return null;
    const range = headerModeCellRange(layout, kind, mode) orelse return null;
    const start_col = range.start;
    const end_col = range.end;
    if (end_col <= start_col) return null;
    return .{ .x = header.x + @as(u32, start_col) * cell_width_px, .y = control.y, .w = @as(u32, end_col - start_col) * cell_width_px, .h = control.h };
}

pub fn headerModeAt(header: Rect, cell_width_px: u32, kind: dock_panel.EntryKind, dirty: bool, external_change: bool, x_px: f64, y_px: f64) ?dock_panel.Mode {
    for (modesForKind(kind)) |descriptor| {
        if (headerModeRect(header, cell_width_px, kind, descriptor.mode, dirty, external_change)) |r| if (layout_math.pointInRect(x_px, y_px, r)) return descriptor.mode;
    }
    return null;
}

/// 헤더 draw-list의 external-change `!` 한 칸과 같은 rect. mode 토글의 넓은 control rect보다 먼저
/// hit-test해, 충돌 표식을 누르면 편집 모드가 바뀌는 대신 명시적 disk reload 확인으로 라우팅한다.
pub fn headerConflictRect(header: Rect, cell_width_px: u32, dirty: bool) ?Rect {
    if (cell_width_px == 0) return null;
    const cols: u16 = @intCast(header.w / cell_width_px);
    const layout = headerCellLayout(cols, dirty, true) orelse return null;
    const col = layout.conflict_col orelse return null;
    return .{
        .x = header.x + @as(u32, col) * cell_width_px,
        .y = header.y,
        .w = cell_width_px,
        .h = header.h,
    };
}

pub fn headerDirtyRect(header: Rect, cell_width_px: u32, external_change: bool) ?Rect {
    if (cell_width_px == 0) return null;
    const cols: u16 = @intCast(header.w / cell_width_px);
    const layout = headerCellLayout(cols, true, external_change) orelse return null;
    const col = layout.dirty_col orelse return null;
    return .{ .x = header.x + @as(u32, col) * cell_width_px, .y = header.y, .w = cell_width_px, .h = header.h };
}

pub const Input = struct {
    backing_width_px: u32,
    backing_height_px: u32,
    sidebar_width_px: u32,
    /// 창 상단 띠 높이(px). **terminal과 dock이 같이 쓴다** — 예전에는 dock만 별도 기준선(`dock_top_px`)을
    /// 받아 terminal title strip이 커져도 제자리에 있었는데, 그러면 두 상단 바의 **시작선**이 갈려 아래
    /// 경계선을 맞춰 놔도 여전히 어긋난다(사용자 보고). 기준선 하나만 남겨 그 갈래를 구조적으로 없앤다.
    titlebar_height_px: u32,
    cell_width_px: u32,
    cell_height_px: u32,
    scale_milli: u32,
    divider_px: u32,
    side: dock_panel.Side,
    size_pt: u32,
    visible: bool,
    /// `size_pt == 0`일 때만 자동 기본 폭을 고르는 현재 view. 수동 폭은 계속 하나의 dock state가 소유한다.
    view: dock_panel.View = .explorer,
    /// 뷰 스위처 바 높이(px). 호출자가 **pane 탭 바와 같은 값**을 넘겨 두 바의 아래 경계선이 한 줄로 맞는다
    /// (docs/file-explorer.md §3.5). 그 값은 chrome 행의 배수가 아니므로(폰트 독립 하한과 셀 파생 높이 중
    /// 큰 쪽) 여기서 파생하지 않고 호출자가 공유 단일 출처(`chromeBarHeightPx`)를 그대로 넘긴다.
    ///
    /// 이 레이어는 그 값이 어디서 왔는지 알지 못하고 알 필요도 없다 — 높이 정책이 chrome token으로 옮겨간
    /// 뒤에도 이 필드의 계약은 "호출자가 정한 바 높이, 0이면 바 없음"으로 그대로다.
    view_bar_px: u32 = 0,
    /// 창 바닥 상태표시줄 높이(px, 창 전폭). 0이면 상태바 없음 — 그때 `compute`의 모든 출력은 이 필드가
    /// 없던 때와 **같다**(S1은 0으로만 들어와 byte-identical, S2가 실제 높이로 뒤집는다).
    status_bar_px: u32 = 0,
};

/// 하나의 도크를 유지하면서도 자동 상태만 consumer가 요구하는 가독성 폭을 고른다. 새 view를 추가하면
/// 여기에서 명시적으로 기본값을 정해야 하며, unknown enum/persistence fallback은 dock_panel.View reader가 맡는다.
pub fn defaultRightPtForView(view: dock_panel.View) u32 {
    return switch (view) {
        .agent_sessions => default_agent_sessions_right_pt,
        .image_gallery => default_image_gallery_right_pt,
        .explorer, .source_control => default_right_pt,
    };
}

/// 포인터 하나가 **어느 영역의 것인가**. 순수 판정이라 창도 OS도 모른다.
///
/// **왜 여기인가**: 판정의 근거가 `Geometry` 뿐이고, 그것을 만드는 자리가 여기다. 호출자마다
/// `x >= dock.x and …` 를 적으면 경계 한 픽셀이 각자 달라진다 — 디바이더는 **잡기 띠**(grab band)라
/// 눈에 보이는 선보다 넓고, 그 사실을 아는 곳이 여기 하나여야 한다.
///
/// **순서가 계약이다**: 디바이더를 **먼저** 본다. 잡기 띠는 터미널·도크와 겹치므로, 나중에 보면
/// 겹친 폭만큼 영영 못 잡는다.
pub const Region = enum {
    /// 어느 영역도 아니다(상태바·타이틀바 띠의 **사이드바 밖 부분**·창 밖).
    none,
    /// 왼쪽 사이드바 띠(헤더·카드 목록). 그 **안에서** 어디인지는 `chrome.components.sidebar` 의
    /// `headerHit`·`slotAt` 이 가른다 — 여기는 "사이드바냐 아니냐" 까지다.
    sidebar,
    terminal,
    /// 도크 안이지만 뷰 스위처 바다.
    view_bar,
    /// 도크의 본문(파일 트리·소스 컨트롤…).
    dock_content,
    /// 도크 폭을 바꾸는 잡기 띠.
    divider,
};

pub fn regionAt(geom: Geometry, x_px: f64, y_px: f64) Region {
    // **사이드바가 먼저다.** 작업영역 밖이라 아래 판정들과 겹치지 않지만, 순서를 적어 두는 편이
    // 나중에 겹치는 자리(스크롤바·리사이즈 띠)가 생겼을 때 규칙이 분명하다.
    if (contains(geom.sidebar, x_px, y_px)) return .sidebar;
    if (contains(geom.divider, x_px, y_px)) return .divider;
    if (contains(geom.view_bar, x_px, y_px)) return .view_bar;
    if (contains(geom.tree_content, x_px, y_px)) return .dock_content;
    // **도크 안이지만 본문도 스위처도 아닌 자리**(여백)는 도크가 먹는다 — 터미널로 흘리면 도크
    // 여백을 눌렀을 때 셸에 선택이 생긴다.
    if (contains(geom.dock, x_px, y_px)) return .dock_content;
    if (contains(geom.terminal, x_px, y_px)) return .terminal;
    return .none;
}

/// 작업영역에서 **유도한** 사이드바 띠 — 그 왼쪽 전부, 같은 세로 범위.
///
/// 유도하는 이유: 폭·시작 y 를 두 곳에서 따로 만들면 한쪽만 고칠 때 **그린 자리와 눌리는 자리가
/// 갈린다.** `workspace.x` 가 이미 "사이드바가 먹은 폭" 이므로 그 하나에서 전부 나온다.
fn sidebarOf(ws: Rect) Rect {
    return .{ .x = 0, .y = 0, .w = ws.x, .h = ws.y +| ws.h };
}

fn contains(r: Rect, x_px: f64, y_px: f64) bool {
    if (r.w == 0 or r.h == 0) return false;
    const x0: f64 = @floatFromInt(r.x);
    const y0: f64 = @floatFromInt(r.y);
    return x_px >= x0 and y_px >= y0 and
        x_px < x0 + @as(f64, @floatFromInt(r.w)) and
        y_px < y0 + @as(f64, @floatFromInt(r.h));
}

pub fn compute(in: Input) Geometry {
    // 상태바는 **창 전폭**(사이드바 아래까지)이라 `available` 밖에 산다. 그래서 창 높이에서 **먼저** 깎고,
    // 아래 모든 기하가 그 짧아진 높이(`usable_h`)에서 파생되게 한다 — terminal·dock·divider·조기 반환이
    // 전부 한 지점에서 정합한다. 창보다 크게 요청되면 창 높이로 clamp(작업영역 0은 허용, 음수는 없다).
    const status_bar_h = @min(in.status_bar_px, in.backing_height_px);
    const usable_h = in.backing_height_px -| status_bar_h;
    const status_bar = Rect{ .x = 0, .y = usable_h, .w = in.backing_width_px, .h = status_bar_h };
    const available = Rect{
        .x = in.sidebar_width_px,
        .y = in.titlebar_height_px,
        .w = in.backing_width_px -| in.sidebar_width_px,
        .h = usable_h -| in.titlebar_height_px,
    };
    if (!in.visible or available.w == 0 or available.h == 0) return .{ .workspace = available, .sidebar = sidebarOf(available), .terminal = available, .status_bar = status_bar };

    // 도크는 terminal과 **같은 `available`**에서 시작한다. 예전에는 right dock만 별도 기준선을 받아
    // terminal title strip이 커져도 제자리에 있었는데, 그러면 두 상단 바의 시작선이 갈린다 — 아래
    // 경계선을 맞춰 놔도 시작이 다르면 여전히 어긋나 보인다(사용자 보고). 상태바가 먹은 높이는 `usable_h`가
    // 이미 반영했으므로 기준선은 이 rect 하나로 끝난다.
    const scale = if (in.scale_milli == 0) 1000 else in.scale_milli;
    const requested_pt = if (in.size_pt != 0) in.size_pt else switch (in.side) {
        .right => defaultRightPtForView(in.view),
        .bottom => default_bottom_pt,
    };
    const requested_px = layout_math.ptToPx(requested_pt, scale);
    const divider = @min(in.divider_px, switch (in.side) {
        .right => available.w,
        .bottom => available.h,
    });
    const chrome_h = @min(in.cell_height_px, available.h);

    return switch (in.side) {
        .right => right: {
            const min_dock = layout_math.ptToPx(min_right_pt, scale);
            const min_terminal = @max(2 * in.cell_width_px, layout_math.ptToPx(320, scale));
            const max_dock = available.w -| divider -| min_terminal;
            const dock_w = @min(@max(requested_px, @min(min_dock, max_dock)), max_dock);
            if (dock_w == 0) break :right .{ .workspace = available, .sidebar = sidebarOf(available), .terminal = available, .status_bar = status_bar };
            const term_w = available.w -| divider -| dock_w;
            const dock_x = available.x + term_w + divider;
            const dock = Rect{ .x = dock_x, .y = available.y, .w = dock_w, .h = available.h };
            break :right fromDock(
                available,
                .{ .x = available.x, .y = available.y, .w = term_w, .h = available.h },
                dock,
                .{ .x = available.x + term_w, .y = available.y, .w = divider, .h = available.h },
                status_bar,
                chrome_h,
                dock_w,
                in.cell_width_px,
                scale,
                in.view_bar_px,
            );
        },
        .bottom => bottom: {
            const min_dock = layout_math.ptToPx(min_bottom_pt, scale);
            const min_terminal = @max(2 * in.cell_height_px, layout_math.ptToPx(180, scale));
            const max_dock = available.h -| divider -| min_terminal;
            const dock_h = @min(@max(requested_px, @min(min_dock, max_dock)), max_dock);
            if (dock_h == 0) break :bottom .{ .workspace = available, .sidebar = sidebarOf(available), .terminal = available, .status_bar = status_bar };
            const term_h = available.h -| divider -| dock_h;
            const dock_y = available.y + term_h + divider;
            const dock = Rect{ .x = available.x, .y = dock_y, .w = available.w, .h = dock_h };
            break :bottom fromDock(
                available,
                .{ .x = available.x, .y = available.y, .w = available.w, .h = term_h },
                dock,
                .{ .x = available.x, .y = available.y + term_h, .w = available.w, .h = divider },
                status_bar,
                chrome_h,
                dock_h,
                in.cell_width_px,
                scale,
                in.view_bar_px,
            );
        },
    };
}

fn fromDock(workspace: Rect, terminal: Rect, dock: Rect, divider: Rect, status_bar: Rect, chrome_h: u32, dock_size_px: u32, cell_width_px: u32, scale_milli: u32, view_bar_px: u32) Geometry {
    _ = cell_width_px;
    _ = scale_milli;
    _ = chrome_h;
    // 도크 최상단이 뷰 스위처(chrome 2행)이고 그 아래가 현재 뷰의 본문이다. 옛 제목 행을 흡수했으므로
    // 아이콘이 앉는 영역이 두 배가 된다. 낮은 도크에서는 2행 → 1행 → 0행으로 줄여 **콘텐츠를 먼저 남긴다**
    // — 스위처를 다 그리려다 본문이 0이 되는 쪽이 더 나쁘다.
    // 바 높이는 pane 탭 바와 같은 값을 그대로 쓴다(경계선 정렬). 그 높이를 넣으면 본문이 사라질 만큼 도크가
    // 낮으면 바를 접는다 — 스위처를 그리려다 콘텐츠가 0이 되는 쪽이 더 나쁘다.
    const view_bar_h = if (dock.h > view_bar_px) view_bar_px else 0;
    const view_area_y = dock.y + view_bar_h;
    const view_area_h = dock.h -| view_bar_h;
    return .{
        .workspace = workspace,
        .sidebar = sidebarOf(workspace),
        .terminal = terminal,
        .dock = dock,
        .divider = divider,
        .status_bar = status_bar,
        .view_bar = .{ .x = dock.x, .y = dock.y, .w = dock.w, .h = view_bar_h },
        .tree = .{ .x = dock.x, .y = view_area_y, .w = dock.w, .h = view_area_h },
        .tree_content = .{ .x = dock.x, .y = view_area_y, .w = dock.w, .h = view_area_h },
        .dock_size_px = dock_size_px,
    };
}

/// terminal↔dock 외곽 divider의 실제 mouse target. render 선보다 넓은 영역과 bottom 쪽 비대칭 정책을
/// `dockDividerAtPoint`와 WebView native pass-through projection이 함께 소비한다.
pub fn outerDividerHitRect(g: Geometry, side: dock_panel.Side, hit_slop: u32) Rect {
    if (g.divider.w == 0 or g.divider.h == 0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    return switch (side) {
        .right => blk: {
            const start = @max(g.workspace.x, g.divider.x -| hit_slop);
            const end = @min(g.workspace.x +| g.workspace.w, g.divider.x +| g.divider.w +| hit_slop);
            break :blk .{ .x = start, .y = g.divider.y, .w = end -| start, .h = g.divider.h };
        },
        // dock 쪽은 tab/header라 WebView와 맞닿지 않고, 클릭을 훔치지 않도록 terminal 쪽만 확장한다.
        .bottom => blk: {
            const start = @max(g.workspace.y, g.divider.y -| hit_slop);
            const end = @min(g.workspace.y +| g.workspace.h, g.divider.y +| g.divider.h);
            break :blk .{ .x = g.divider.x, .y = start, .w = g.divider.w, .h = end -| start };
        },
    };
}

/// clamp된 실효 backing-px 폭을 다시 영속 pt로 되돌린다. **내부·max 경계는 올림** — 내림하면 1.5x처럼 px/pt가
/// 나누어떨어지지 않는 배율에서 `compute -> 저장 -> compute`마다 최대 1px씩 줄고, 올림값이 max를 1px 넘어도 다음
/// compute의 같은 max clamp가 원래 실효 폭을 복원하므로 고정점이다. 단 **min 경계(width==min_px)** 만은 올림이
/// min을 1px 넘겨 compute의 min clamp-up이 못 되돌리므로(하한에 영영 도달 못 함) **내림**해 정확히 min으로 복원한다.
/// min_px=0이면 하한 경계가 없어(outer dock resize) 항상 올림이다.
pub fn sizePtForEffectiveWidth(width_px: u32, min_px: u32, scale_milli: u32) u32 {
    const scale = if (scale_milli == 0) 1000 else scale_milli;
    const num = @as(u64, width_px) * 1000;
    const rounded = if (min_px != 0 and width_px <= min_px) num / scale else (num + (scale - 1)) / scale;
    return @intCast(@min(rounded, std.math.maxInt(u32)));
}

/// 잡기 띠의 **어느 지점에서 시작했든** `포인터 이동량 == 디바이더 이동량`이 되게 하는 보정.
///
/// `sizePtForPointer(g, side, x + grabOffsetPx(g, side, x, y), y, scale)` 가 **누른 순간의 크기를
/// 그대로** 내도록 맞춘 값이다. 이 보정이 없으면 첫 이동에서 잡기 띠 폭만큼 막대가 튄다.
///
/// **부호가 함정이라 여기 둔다.** `sizePtForPointer` 의 짝이고, 아래 왕복 테스트가 그 둘을 함께
/// 고정한다 — 각자 적으면 한쪽 부호만 틀려도 "끌면 반대로 간다" 가 된다.
pub fn grabOffsetPx(g: Geometry, side: dock_panel.Side, x_px: f64, y_px: f64) f64 {
    return switch (side) {
        .right => @as(f64, @floatFromInt(g.dock.x)) - x_px,
        .bottom => @as(f64, @floatFromInt(g.dock.y)) - y_px,
    };
}

pub fn sizePtForPointer(g: Geometry, side: dock_panel.Side, x_px: f64, y_px: f64, scale_milli: u32) ?u32 {
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    const raw: f64 = switch (side) {
        .right => @as(f64, @floatFromInt(g.dock.x + g.dock.w)) - x_px,
        .bottom => @as(f64, @floatFromInt(g.dock.y + g.dock.h)) - y_px,
    };
    const px: u32 = if (raw <= 0) 0 else @intFromFloat(@min(raw, @as(f64, @floatFromInt(std.math.maxInt(u32)))));
    const scale = if (scale_milli == 0) 1000 else scale_milli;
    // pt 0은 compute의 "미설정=기본값" 센티널이다. 라이브 드래그가 이 값을 만들면(포인터가 도크 반대 경계를 지나
    // raw<=0) divider를 끝까지 줄였는데 최소가 아니라 기본 크기로 튄다 → 최소 1을 보장하고, 실제 하한 clamp는
    // compute가 editor/tree 가독성 하한과 함께 적용한다.
    return @max(@as(u32, 1), @as(u32, @intCast((@as(u64, px) * 1000) / scale)));
}

test "right and bottom dock geometry share terminal and chrome boundaries" {
    const base = Input{ .backing_width_px = 1600, .backing_height_px = 1000, .sidebar_width_px = 240, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 2000, .divider_px = 4, .side = .right, .size_pt = 300, .visible = true };
    const right = compute(base);
    try std.testing.expectEqual(Rect{ .x = 240, .y = 40, .w = 1360, .h = 960 }, right.workspace);
    try std.testing.expectEqual(@as(u32, 600), right.dock.w);
    try std.testing.expectEqual(right.divider.x + right.divider.w, right.dock.x);
    // 도크 = 뷰 바 + 현재 뷰 영역(§3.5). 옛 editor 칼럼과 그 chrome(tab_bar/header/content)은 없다.
    try std.testing.expectEqual(right.dock.x, right.view_bar.x);
    try std.testing.expectEqual(right.dock.y, right.view_bar.y);
    try std.testing.expectEqual(right.dock.w, right.view_bar.w);
    try std.testing.expectEqual(right.dock.h, right.view_bar.h + right.tree.h); // 남김없이 나뉜다
    try std.testing.expectEqual(right.view_bar.y + right.view_bar.h, right.tree.y);
    try std.testing.expectEqual(right.dock.w, right.tree.w);
    try std.testing.expectEqual(right.tree, right.tree_content); // 제목 행이 없어 본문이 뷰 영역 전체다
    try std.testing.expectEqual(@as(u32, 0), right.view_bar.h); // view_bar_px 미지정 → 바 없음

    const bottom = compute(.{ .backing_width_px = base.backing_width_px, .backing_height_px = base.backing_height_px, .sidebar_width_px = base.sidebar_width_px, .titlebar_height_px = base.titlebar_height_px, .cell_width_px = base.cell_width_px, .cell_height_px = base.cell_height_px, .scale_milli = base.scale_milli, .divider_px = base.divider_px, .side = .bottom, .size_pt = 200, .visible = true });
    try std.testing.expectEqual(right.workspace, bottom.workspace);
    try std.testing.expectEqual(@as(u32, 400), bottom.dock.h);
    try std.testing.expectEqual(bottom.divider.y + bottom.divider.h, bottom.dock.y);
    try std.testing.expectEqual(base.sidebar_width_px, bottom.dock.x);
}

test "낮은 도크에서는 뷰 바부터 접어 콘텐츠를 남긴다" {
    // chrome 한 행(cell_height 20 × scale 2000 → 40px)도 못 넣는 높이면 바를 0으로 접는다. 두 행을 억지로
    // 넣어 본문이 0이 되는 쪽이 더 나쁘다(스위처가 콘텐츠를 굶기지 않는다 — docs/file-explorer.md §3.5).
    // chrome 한 행(cell_height_px)보다 낮은 도크를 직접 만들어 계약만 본다 — compute의 pt 클램프를 거치면
    // 이 경계를 재현하기 어렵다(하한이 먼저 걸린다).
    const dock = Rect{ .x = 0, .y = 100, .w = 300, .h = 12 };
    const tiny = fromDock(.{ .x = 0, .y = 0, .w = 300, .h = 112 }, .{ .x = 0, .y = 0, .w = 300, .h = 100 }, dock, .{ .x = 0, .y = 96, .w = 300, .h = 4 }, .{ .x = 0, .y = 112, .w = 300, .h = 0 }, 20, 12, 10, 1000, 24);
    try std.testing.expectEqual(@as(u32, 0), tiny.view_bar.h);
    try std.testing.expectEqual(dock.h, tiny.tree.h);
    try std.testing.expectEqual(dock.y, tiny.tree.y);
    // 한 행이 들어가면 바가 서고 그만큼 뷰 영역이 줄어든다.
    // 바 높이는 넘겨받은 값 그대로다(pane 탭 바와 같은 값 → 경계선 정렬).
    const roomy = fromDock(.{ .x = 0, .y = 0, .w = 300, .h = 200 }, .{ .x = 0, .y = 0, .w = 300, .h = 100 }, .{ .x = 0, .y = 100, .w = 300, .h = 100 }, .{ .x = 0, .y = 96, .w = 300, .h = 4 }, .{ .x = 0, .y = 200, .w = 300, .h = 0 }, 20, 100, 10, 1000, 24);
    try std.testing.expectEqual(@as(u32, 24), roomy.view_bar.h);
    try std.testing.expectEqual(@as(u32, 76), roomy.tree.h);
}

// 도크와 terminal은 **같은 상단 기준선**에서 시작한다. 예전에는 right dock만 별도 `dock_top_px`를 받아
// title strip이 커져도 제자리에 있었는데, 그러면 두 상단 바의 아래 경계선을 맞춰 놔도 시작이 갈려 여전히
// 어긋나 보인다(사용자 보고). 호출자가 title strip을 어떤 식으로 정하든(폰트·사이드바 접힘) 이 레이어는
// 그 값 하나만 쓴다 — 갈래가 없으므로 두 바는 항상 같은 y에서 시작한다.
test "dock and terminal share one top origin whatever the title strip is" {
    const tall = compute(.{
        .backing_width_px = 1600,
        .backing_height_px = 1000,
        .sidebar_width_px = 240,
        .titlebar_height_px = 64, // 큰 terminal font가 title strip을 키운 상태
        .cell_width_px = 10,
        .cell_height_px = 36,
        .scale_milli = 1000,
        .divider_px = 2,
        .view_bar_px = 40,
        .side = .right,
        .size_pt = 400,
        .visible = true,
    });
    try std.testing.expectEqual(@as(u32, 64), tall.terminal.y);
    try std.testing.expectEqual(tall.terminal.y, tall.dock.y); // 도크가 따라 내려온다
    try std.testing.expectEqual(tall.terminal.y, tall.divider.y);
    try std.testing.expectEqual(tall.dock.y, tall.view_bar.y); // view bar는 도크 최상단
    try std.testing.expectEqual(@as(u32, 40), tall.view_bar.h);
    try std.testing.expectEqual(@as(u32, 104), tall.tree_content.y); // 64 + 40

    // 사이드바 접힘처럼 title strip이 **다른 값**으로 바뀌어도 갈래가 생기지 않는다.
    var collapsed_in = @as(Input, .{
        .backing_width_px = 1600,
        .backing_height_px = 1000,
        .sidebar_width_px = 0, // 접힘 = 사이드바 폭 0
        .titlebar_height_px = 60, // 접힘 하한(30pt @2x)이 그대로 두 소비자에게 간다
        .cell_width_px = 10,
        .cell_height_px = 36,
        .scale_milli = 1000,
        .divider_px = 2,
        .view_bar_px = 40,
        .side = .right,
        .size_pt = 400,
        .visible = true,
    });
    const collapsed = compute(collapsed_in);
    try std.testing.expectEqual(@as(u32, 60), collapsed.terminal.y);
    try std.testing.expectEqual(collapsed.terminal.y, collapsed.dock.y);
    try std.testing.expectEqual(collapsed.terminal.y, collapsed.divider.y);

    // bottom 도크도 같은 기준선을 쓴다(원래 그랬고, 기준선 통합으로 깨지지 않았는지 고정한다).
    collapsed_in.side = .bottom;
    const bottom = compute(collapsed_in);
    try std.testing.expectEqual(@as(u32, 60), bottom.terminal.y);
    try std.testing.expectEqual(bottom.terminal.y + bottom.terminal.h, bottom.divider.y);
}

test "dock geometry collapses and clamps to leave a terminal floor" {
    const hidden = compute(.{ .backing_width_px = 800, .backing_height_px = 600, .sidebar_width_px = 200, .titlebar_height_px = 30, .cell_width_px = 8, .cell_height_px = 16, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 700, .visible = false });
    try std.testing.expectEqual(@as(u32, 600), hidden.terminal.w);
    try std.testing.expectEqual(@as(u32, 0), hidden.dock.w);

    const clamped = compute(.{ .backing_width_px = 800, .backing_height_px = 600, .sidebar_width_px = 200, .titlebar_height_px = 30, .cell_width_px = 8, .cell_height_px = 16, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 700, .visible = true });
    try std.testing.expect(clamped.terminal.w >= 320);
    try std.testing.expectEqual(clamped.terminal.w + clamped.divider.w + clamped.dock.w, hidden.terminal.w);

    const damaged = compute(.{ .backing_width_px = 800, .backing_height_px = 600, .sidebar_width_px = 200, .titlebar_height_px = 30, .cell_width_px = 8, .cell_height_px = 16, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = std.math.maxInt(u32), .visible = true });
    try std.testing.expect(damaged.terminal.w >= 320); // 손상 workspace의 u32 max도 overflow 없이 실효 크기로 clamp.
    try std.testing.expectEqual(damaged.terminal.w + damaged.divider.w + damaged.dock.w, hidden.terminal.w);
}

test "auto right dock widens only the agent sessions view and preserves explicit size" {
    const base = Input{
        .backing_width_px = 1600,
        .backing_height_px = 900,
        .sidebar_width_px = 200,
        .titlebar_height_px = 32,
        .cell_width_px = 8,
        .cell_height_px = 16,
        .scale_milli = 1000,
        .divider_px = 2,
        .side = .right,
        .size_pt = 0,
        .visible = true,
    };
    const explorer = compute(base);
    const archive = compute(.{ .backing_width_px = base.backing_width_px, .backing_height_px = base.backing_height_px, .sidebar_width_px = base.sidebar_width_px, .titlebar_height_px = base.titlebar_height_px, .cell_width_px = base.cell_width_px, .cell_height_px = base.cell_height_px, .scale_milli = base.scale_milli, .divider_px = base.divider_px, .side = base.side, .size_pt = 0, .visible = true, .view = .agent_sessions });
    const explicit = compute(.{ .backing_width_px = base.backing_width_px, .backing_height_px = base.backing_height_px, .sidebar_width_px = base.sidebar_width_px, .titlebar_height_px = base.titlebar_height_px, .cell_width_px = base.cell_width_px, .cell_height_px = base.cell_height_px, .scale_milli = base.scale_milli, .divider_px = base.divider_px, .side = base.side, .size_pt = 220, .visible = true, .view = .agent_sessions });

    try std.testing.expectEqual(@as(u32, default_right_pt), explorer.dock.w);
    try std.testing.expectEqual(@as(u32, default_agent_sessions_right_pt), archive.dock.w);
    try std.testing.expectEqual(@as(u32, 220), explicit.dock.w);
}

test "resize pointer maps backing pixels to persisted points and rejects non-finite" {
    const g = compute(.{ .backing_width_px = 1200, .backing_height_px = 800, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 2000, .divider_px = 2, .side = .right, .size_pt = 300, .visible = true });
    const expected_pt: u32 = @intCast((@as(u64, g.dock_size_px + 100) * 1000) / 2000);
    try std.testing.expectEqual(@as(?u32, expected_pt), sizePtForPointer(g, .right, @floatFromInt(g.dock.x - 100), 0, 2000));
    try std.testing.expectEqual(@as(?u32, null), sizePtForPointer(g, .right, std.math.nan(f64), 0, 2000));
}

test "markdown 헤더는 상태 글리프가 모두 보여도 세 mode 라벨 폭을 지킨다" {
    // 회귀: 3분할이 되면서 18칸으로는 dirty ●와 conflict !가 동시에 보일 때 첫 슬롯이 4칸으로 줄어
    // "읽기"(CJK 2셀×2)가 잘렸다. 렌더가 슬롯마다 1칸을 여백으로 쓰므로 슬롯당 5칸이 필요하다.
    const header: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 20 };
    const cell: u32 = 10;
    inline for (.{ .{ true, true }, .{ true, false }, .{ false, true }, .{ false, false } }) |flags| {
        const dirty = flags[0];
        const external = flags[1];
        inline for (.{ dock_panel.Mode.read, .rich, .source_edit }) |m| {
            const rect = headerModeRect(header, cell, .markdown, m, dirty, external).?;
            // rect.w는 픽셀이다 — 라벨 4칸 + 여백 1칸.
            try std.testing.expect(rect.w >= 5 * cell);
        }
    }
}

test "파일 헤더 밴드 control rect는 우측 정렬되고 좁은 밴드에서도 경계 안이다" {
    // FP16: 헤더 밴드는 파일 Term 소유라 도크 기하와 무관하다 — 밴드 rect를 직접 준다(pane이 계산한 값).
    const header: Rect = .{ .x = 400, .y = 60, .w = 600, .h = 20 };
    const control = headerControlRect(header, 10).?;
    try std.testing.expectEqual(header.x + header.w, control.x + control.w);
    try std.testing.expectEqual(@as(u32, header_control_cols * 10), control.w);
    const conflict = headerConflictRect(header, 10, false).?;
    try std.testing.expectEqual(header.x + header.w - 20, conflict.x);
    try std.testing.expectEqual(@as(u32, 10), conflict.w);
    try std.testing.expect(conflict.x >= control.x);
    // markdown 헤더는 읽기|리치|소스 3모드다(§2.5). 세 슬롯이 control rect를 빈틈없이 채워야 한다.
    const read = headerModeRect(header, 10, .markdown, .read, false, false).?;
    const rich = headerModeRect(header, 10, .markdown, .rich, false, false).?;
    const edit = headerModeRect(header, 10, .markdown, .source_edit, false, false).?;
    try std.testing.expectEqual(control.x, read.x);
    try std.testing.expectEqual(read.x + read.w, rich.x);
    try std.testing.expectEqual(rich.x + rich.w, edit.x);
    try std.testing.expectEqual(control.x + control.w, edit.x + edit.w);
    try std.testing.expectEqual(@as(?dock_panel.Mode, .read), headerModeAt(header, 10, .markdown, false, false, @floatFromInt(read.x + 1), @floatFromInt(read.y + 1)));
    try std.testing.expectEqual(@as(?dock_panel.Mode, .rich), headerModeAt(header, 10, .markdown, false, false, @floatFromInt(rich.x + 1), @floatFromInt(rich.y + 1)));
    try std.testing.expectEqual(@as(?dock_panel.Mode, .source_edit), headerModeAt(header, 10, .markdown, false, false, @floatFromInt(edit.x + 1), @floatFromInt(edit.y + 1)));
    try std.testing.expectEqual(@as(?dock_panel.Mode, null), headerModeAt(header, 10, .html, false, false, @floatFromInt(edit.x + 1), @floatFromInt(edit.y + 1)));

    inline for (.{ false, true }) |dirty| inline for (.{ false, true }) |external| {
        const read_mode = headerModeRect(header, 10, .markdown, .read, dirty, external).?;
        const rich_mode = headerModeRect(header, 10, .markdown, .rich, dirty, external).?;
        const source = headerModeRect(header, 10, .markdown, .source_edit, dirty, external).?;
        const cells = headerCellLayout(@intCast(header.w / 10), dirty, external).?;
        try std.testing.expectEqual(header.x + @as(u32, cells.control_start) * 10, read_mode.x); // 첫 슬롯=control_start
        try std.testing.expectEqual(read_mode.x + read_mode.w, rich_mode.x); // 인접
        try std.testing.expectEqual(rich_mode.x + rich_mode.w, source.x); // 인접
        try std.testing.expectEqual(header.x + @as(u32, cells.mode_end) * 10, source.x + source.w); // 마지막=mode_end
        if (dirty) {
            const status = headerDirtyRect(header, 10, external).?;
            try std.testing.expect(headerModeAt(header, 10, .markdown, dirty, external, @floatFromInt(status.x + 1), @floatFromInt(status.y + 1)) == null);
        }
        if (external) {
            const status = headerConflictRect(header, 10, dirty).?;
            try std.testing.expect(headerModeAt(header, 10, .markdown, dirty, external, @floatFromInt(status.x + 1), @floatFromInt(status.y + 1)) == null);
        }
    };
}

test "헤더 mode 슬롯은 kind별로 나뉜다 (markdown thirds, svg halves) before status" {
    const bare = headerCellLayout(6, true, true).?;
    try std.testing.expectEqual(@as(u16, 6), bare.mode_end);
    try std.testing.expectEqual(@as(?u16, null), bare.conflict_col);
    try std.testing.expectEqual(@as(?u16, null), bare.dirty_col);

    const conflict_only = headerCellLayout(8, true, true).?;
    try std.testing.expectEqual(@as(?u16, 6), conflict_only.conflict_col);
    try std.testing.expectEqual(@as(?u16, null), conflict_only.dirty_col);
    const both = headerCellLayout(10, true, true).?;
    try std.testing.expectEqual(@as(?u16, 6), both.conflict_col);
    try std.testing.expectEqual(@as(?u16, 8), both.dirty_col);

    // markdown: 3개 슬롯이 control_start..mode_end를 연속으로 덮는다.
    var md_prev: ?u16 = null;
    for (modesForKind(.markdown)) |d| {
        const range = headerModeCellRange(both, .markdown, d.mode).?;
        if (md_prev) |p| try std.testing.expectEqual(p, range.start);
        md_prev = range.end;
        try std.testing.expect(d.label().len > 0);
    }
    try std.testing.expectEqual(@as(?u16, both.mode_end), md_prev);
    // svg: 2개 슬롯(읽기·소스).
    try std.testing.expectEqual(@as(usize, 2), modesForKind(.svg).len);
    const svg_read = headerModeCellRange(both, .svg, .read).?;
    const svg_source = headerModeCellRange(both, .svg, .source_edit).?;
    try std.testing.expectEqual(both.control_start, svg_read.start);
    try std.testing.expectEqual(svg_read.end, svg_source.start);
    try std.testing.expectEqual(both.mode_end, svg_source.end);
    // html·text는 mode 선택기가 없다.
    try std.testing.expectEqual(@as(usize, 0), modesForKind(.html).len);
    try std.testing.expectEqual(@as(usize, 0), modesForKind(.text).len);
}

// SB1-S1: 상태바 seam. 이 조각은 **자리만 내고 높이는 0**이라, `status_bar_px`를 안 넘기거나 0으로 넘기면
// 나머지 기하가 seam 이전과 **완전히 같아야** 한다. 그래야 S2의 높이 flip이 유일한 시각 변화가 된다.
test "SB1-S1: status_bar_px가 0이면 나머지 기하가 seam 이전과 같다" {
    const base = Input{
        .backing_width_px = 1600,
        .backing_height_px = 1000,
        .sidebar_width_px = 240,
        .titlebar_height_px = 28,
        .cell_width_px = 8,
        .cell_height_px = 20,
        .scale_milli = 1000,
        .divider_px = 4,
        .side = .right,
        .size_pt = 300,
        .visible = true,
    };
    const implicit = compute(base); // 필드를 아예 안 준 경우(기본값 0)
    var explicit_in = base;
    explicit_in.status_bar_px = 0;
    const explicit = compute(explicit_in);
    try std.testing.expectEqual(implicit, explicit);
    // 높이 0이면 상태바는 창 바닥에 붙은 빈 띠다 — 폭은 **창 전폭**(사이드바를 안 뺀다)이다.
    try std.testing.expectEqual(@as(u32, 0), implicit.status_bar.h);
    try std.testing.expectEqual(@as(u32, 1600), implicit.status_bar.w);
    try std.testing.expectEqual(@as(u32, 0), implicit.status_bar.x);
    try std.testing.expectEqual(@as(u32, 1000), implicit.status_bar.y);
    // 작업영역은 창 바닥까지 그대로다(깎인 것 없음).
    try std.testing.expectEqual(@as(u32, 1000 - 28), implicit.workspace.h);
}

// 높이가 실제로 서면(S2가 할 일) 그 높이만큼 **작업영역이 짧아져야** 한다 — rect만 더하고 자리를 안 빼면
// 상태바가 터미널 위에 겹쳐 그려진다(docs/metal-ui-layout-paint.md §5). seam 단계에서 그 계약을 미리 고정한다.
test "SB1-S1: status_bar_px는 작업영역·도크·divider를 그만큼 짧게 만든다" {
    const base = Input{
        .backing_width_px = 1600,
        .backing_height_px = 1000,
        .sidebar_width_px = 240,
        .titlebar_height_px = 28,
        .cell_width_px = 8,
        .cell_height_px = 20,
        .scale_milli = 1000,
        .divider_px = 4,
        .side = .bottom,
        .size_pt = 300,
        .visible = true,
    };
    var with_bar = base;
    with_bar.status_bar_px = 24;
    const zero = compute(base);
    const bar = compute(with_bar);

    try std.testing.expectEqual(@as(u32, 24), bar.status_bar.h);
    try std.testing.expectEqual(@as(u32, 1000 - 24), bar.status_bar.y);
    try std.testing.expectEqual(@as(u32, 1600), bar.status_bar.w); // 전폭 — 사이드바 아래까지
    // 작업영역이 정확히 그만큼 줄고, 바닥이 상태바 윗변과 맞닿는다(겹침도 틈도 없다).
    try std.testing.expectEqual(zero.workspace.h - 24, bar.workspace.h);
    try std.testing.expectEqual(bar.status_bar.y, bar.workspace.y + bar.workspace.h);
    // bottom 도크도 함께 올라와 상태바를 침범하지 않는다.
    try std.testing.expect(bar.dock.y + bar.dock.h <= bar.status_bar.y);
    try std.testing.expect(bar.divider.y + bar.divider.h <= bar.status_bar.y);

    // **right 도크도 같은 계약을 진다.** bottom만 보면 "세로로 자르는 쪽만 맞다"에 그친다 — right는 폭을
    // 나누지만 높이는 `available.h`를 통째로 받으므로 상태바를 침범할 수 있는 경로가 따로 있다.
    var right_in = base;
    right_in.side = .right;
    right_in.status_bar_px = 24;
    const right = compute(right_in);
    try std.testing.expect(right.dock.h > 0); // 계약이 공허하지 않은지(도크가 실제로 섰는지) 먼저 본다
    try std.testing.expect(right.dock.y + right.dock.h <= right.status_bar.y);
    try std.testing.expect(right.terminal.y + right.terminal.h <= right.status_bar.y);
}

// 조기 반환 셋(`!visible`·`dock_w==0`·`dock_h==0`)도 상태바를 날라야 한다. `Geometry.status_bar`에 기본값을
// 안 준 이유가 이것이다 — 기본값이 있으면 이 세 경로만 조용히 빈 rect를 흘린다(가장 흔한 상태가 도크 숨김이다).
test "SB1-S1: 도크가 없거나 0폭·0높이여도 상태바 rect는 그대로 나온다" {
    const base = Input{
        .backing_width_px = 1600,
        .backing_height_px = 1000,
        .sidebar_width_px = 240,
        .titlebar_height_px = 28,
        .cell_width_px = 8,
        .cell_height_px = 20,
        .scale_milli = 1000,
        .divider_px = 4,
        .side = .right,
        .size_pt = 300,
        .visible = false, // 조기 반환 ①: 도크 숨김
        .status_bar_px = 24,
    };
    const hidden = compute(base);
    try std.testing.expectEqual(@as(u32, 24), hidden.status_bar.h);
    try std.testing.expectEqual(@as(u32, 1000 - 24), hidden.status_bar.y);
    try std.testing.expectEqual(hidden.status_bar.y, hidden.workspace.y + hidden.workspace.h);

    // 조기 반환 ②: 폭 하한이 터미널 최소폭에 밀려 dock_w가 0이 되는 좁은 창.
    var narrow = base;
    narrow.visible = true;
    narrow.backing_width_px = 260; // 사이드바 240을 빼면 20px — 도크가 설 자리가 없다
    const squeezed = compute(narrow);
    try std.testing.expectEqual(@as(u32, 0), squeezed.dock.w);
    try std.testing.expectEqual(@as(u32, 24), squeezed.status_bar.h);
    try std.testing.expectEqual(@as(u32, 260), squeezed.status_bar.w);

    // 조기 반환 ③: bottom에서 높이 하한에 밀려 dock_h가 0이 되는 낮은 창.
    var flat = base;
    flat.visible = true;
    flat.side = .bottom;
    flat.backing_height_px = 90; // titlebar 28 + 상태바 24를 빼면 도크가 설 자리가 없다
    const flattened = compute(flat);
    try std.testing.expectEqual(@as(u32, 0), flattened.dock.h);
    try std.testing.expectEqual(@as(u32, 24), flattened.status_bar.h);
    try std.testing.expectEqual(@as(u32, 90 - 24), flattened.status_bar.y);
}

// 상태바가 창보다 크게 요청되면 창 높이로 clamp한다 — 작업영역 0은 허용하되 underflow는 없다.
test "SB1-S1: 창보다 큰 상태바 요청은 창 높이로 clamp된다" {
    const geometry = compute(.{
        .backing_width_px = 800,
        .backing_height_px = 100,
        .sidebar_width_px = 0,
        .titlebar_height_px = 28,
        .cell_width_px = 8,
        .cell_height_px = 20,
        .scale_milli = 1000,
        .divider_px = 4,
        .side = .bottom,
        .size_pt = 300,
        .visible = true,
        .status_bar_px = 5000,
    });
    try std.testing.expectEqual(@as(u32, 100), geometry.status_bar.h);
    try std.testing.expectEqual(@as(u32, 0), geometry.status_bar.y);
    try std.testing.expectEqual(@as(u32, 0), geometry.workspace.h);
}

test "dock divider grab band rounds logical points up at fractional backing scales" {
    try std.testing.expectEqual(@as(u32, 10), dividerGrabBandPx(0));
    try std.testing.expectEqual(@as(u32, 10), dividerGrabBandPx(1000));
    try std.testing.expectEqual(@as(u32, 13), dividerGrabBandPx(1250));
    try std.testing.expectEqual(@as(u32, 15), dividerGrabBandPx(1500));
    try std.testing.expectEqual(@as(u32, 20), dividerGrabBandPx(2000));
}

const region_testing = std.testing;

fn regionFixture() Geometry {
    return compute(.{
        .backing_width_px = 1000,
        .backing_height_px = 600,
        .sidebar_width_px = 0,
        .titlebar_height_px = 0,
        .cell_width_px = 9,
        .cell_height_px = 19,
        .scale_milli = 1000,
        .divider_px = dividerGrabBandPx(1000),
        .side = .right,
        .size_pt = 0,
        .visible = true,
        .view = .explorer,
        .view_bar_px = 38,
        .status_bar_px = 0,
    });
}

test "regionAt: 터미널·디바이더·도크가 갈린다" {
    const g = regionFixture();
    try region_testing.expectEqual(Region.terminal, regionAt(g, 10, 10));
    try region_testing.expectEqual(Region.divider, regionAt(g, @floatFromInt(g.divider.x + g.divider.w / 2), 10));
    try region_testing.expectEqual(Region.dock_content, regionAt(g, @floatFromInt(g.dock.x + 5), @floatFromInt(g.tree_content.y + 5)));
}

test "regionAt: 디바이더를 먼저 본다 — 잡기 띠가 이웃과 겹친다" {
    const g = regionFixture();
    // 잡기 띠는 눈에 보이는 선보다 넓다. 그 안의 점은 이웃 사각형에도 들 수 있는데, **디바이더가
    // 이긴다** — 안 그러면 겹친 폭만큼 막대를 영영 못 잡는다.
    var x = g.divider.x;
    while (x < g.divider.x + g.divider.w) : (x += 1) {
        try region_testing.expectEqual(Region.divider, regionAt(g, @floatFromInt(x), 100));
    }
}

test "regionAt: 도크 여백도 도크가 먹는다 — 터미널로 안 흘린다" {
    const g = regionFixture();
    // 뷰 스위처 바 위(도크 안, 본문 밖)를 눌러도 터미널이 아니다.
    const y: f64 = @floatFromInt(g.dock.y + 1);
    const r = regionAt(g, @floatFromInt(g.dock.x + 1), y);
    try region_testing.expect(r == .view_bar or r == .dock_content);
}

test "regionAt: 도크가 없으면 전부 터미널이다" {
    const g = compute(.{
        .backing_width_px = 200, // 도크 최소 폭보다 좁다 → 도크가 사라진다
        .backing_height_px = 600,
        .sidebar_width_px = 0,
        .titlebar_height_px = 0,
        .cell_width_px = 9,
        .cell_height_px = 19,
        .scale_milli = 1000,
        .divider_px = dividerGrabBandPx(1000),
        .side = .right,
        .size_pt = 0,
        .visible = true,
        .view = .explorer,
        .view_bar_px = 38,
        .status_bar_px = 0,
    });
    try region_testing.expectEqual(@as(u32, 0), g.dock.w);
    try region_testing.expectEqual(Region.terminal, regionAt(g, 100, 100));
    try region_testing.expectEqual(Region.terminal, regionAt(g, 199, 599));
}

test "regionAt: 창 밖은 none 이다" {
    const g = regionFixture();
    try region_testing.expectEqual(Region.none, regionAt(g, -1, 100));
    try region_testing.expectEqual(Region.none, regionAt(g, 100, -1));
    try region_testing.expectEqual(Region.none, regionAt(g, 5000, 100));
}

test "grabOffsetPx: 잡기 띠 어디를 눌러도 누른 순간 크기가 안 바뀐다" {
    const g = regionFixture();
    const want_pt = sizePtForEffectiveWidth(g.dock.w, 0, 1000);
    var x = g.divider.x;
    while (x < g.divider.x + g.divider.w) : (x += 1) {
        const px: f64 = @floatFromInt(x);
        const off = grabOffsetPx(g, .right, px, 100);
        const got = sizePtForPointer(g, .right, px + off, 100, 1000).?;
        try region_testing.expectEqual(want_pt, got);
    }
}

test "grabOffsetPx: 왼쪽으로 끌면 도크가 넓어진다 — 부호" {
    const g = regionFixture();
    const start: f64 = @floatFromInt(g.divider.x + g.divider.w / 2);
    const off = grabOffsetPx(g, .right, start, 100);
    const at_start = sizePtForPointer(g, .right, start + off, 100, 1000).?;
    // 왼쪽(더 작은 x)으로 20px 끌면 도크가 20pt 넓어진다.
    const moved = sizePtForPointer(g, .right, start - 20 + off, 100, 1000).?;
    try region_testing.expectEqual(at_start + 20, moved);
    // 오른쪽으로 끌면 좁아진다.
    const shrunk = sizePtForPointer(g, .right, start + 20 + off, 100, 1000).?;
    try region_testing.expectEqual(at_start - 20, shrunk);
}

test "사이드바가 자기 영역을 갖는다 — 띠를 포함해 창 맨 위부터, 작업영역 왼쪽" {
    const g = compute(.{
        .backing_width_px = 1000,
        .backing_height_px = 640,
        .sidebar_width_px = 180,
        .titlebar_height_px = 38,
        .cell_width_px = 8,
        .cell_height_px = 19,
        .scale_milli = 1000,
        .divider_px = 10,
        .side = .right,
        .size_pt = 220,
        .visible = true,
    });
    try std.testing.expectEqual(@as(u32, 0), g.sidebar.x);
    try std.testing.expectEqual(@as(u32, 180), g.sidebar.w);
    // **창 맨 위부터다 — 띠를 포함한다.** 그 자리가 헤더의 아이콘 줄이고, 창 버튼과 같은 줄에
    // 서야 한다(사용자 지적 2026-08-25). 띠 아래에서 시작하면 줄이 둘로 갈린다.
    try std.testing.expectEqual(@as(u32, 0), g.sidebar.y);
    // 작업영역과 **가로로 안 겹친다**: 사이드바 오른쪽 끝이 작업영역 왼쪽 끝이다.
    try std.testing.expectEqual(g.sidebar.w, g.workspace.x);
    // 세로로는 작업영역보다 **띠 높이만큼 길다**, 그리고 바닥은 같다(상태바 위).
    try std.testing.expectEqual(g.workspace.y + g.workspace.h, g.sidebar.y + g.sidebar.h);
    try std.testing.expectEqual(g.workspace.h + 38, g.sidebar.h);
}

test "regionAt: 사이드바·띠·터미널이 갈린다" {
    const g = compute(.{
        .backing_width_px = 1000,
        .backing_height_px = 640,
        .sidebar_width_px = 180,
        .titlebar_height_px = 38,
        .cell_width_px = 8,
        .cell_height_px = 19,
        .scale_milli = 1000,
        .divider_px = 10,
        .side = .right,
        .size_pt = 220,
        .visible = true,
    });
    // 사이드바 안.
    try std.testing.expectEqual(Region.sidebar, regionAt(g, 90, 300));
    // 사이드바 **오른쪽 경계 바로 밖**은 터미널이다(경계 한 픽셀을 고정한다).
    try std.testing.expectEqual(Region.sidebar, regionAt(g, 179, 300));
    try std.testing.expectEqual(Region.terminal, regionAt(g, 180, 300));
    // **타이틀바 띠도 사이드바 폭 안이면 사이드바다.** 그 자리가 헤더의 아이콘 줄이라 창 버튼과
    // 같은 줄에 선다 — 띠 아래에서 시작하게 두면 줄이 둘로 갈린다(사용자 지적 2026-08-25).
    try std.testing.expectEqual(Region.sidebar, regionAt(g, 90, 10));
    try std.testing.expectEqual(Region.sidebar, regionAt(g, 90, 38));
    // 사이드바 **밖**의 띠는 여전히 창 chrome 이다 — 캡션 버튼·드래그가 그 자리를 먹는다.
    try std.testing.expectEqual(Region.none, regionAt(g, 400, 10));
}

test "상태바가 서면 사이드바가 그만큼 짧아진다 — 둘이 안 겹친다" {
    const g = compute(.{
        .backing_width_px = 1000,
        .backing_height_px = 640,
        .sidebar_width_px = 180,
        .titlebar_height_px = 38,
        .cell_width_px = 8,
        .cell_height_px = 19,
        .scale_milli = 1000,
        .divider_px = 10,
        .side = .right,
        .size_pt = 220,
        .visible = true,
        .status_bar_px = 27,
    });
    // 상태바는 **창 전폭**이라 사이드바 아래까지 지나간다(status-bar.md §1).
    try std.testing.expectEqual(@as(u32, 0), g.status_bar.x);
    try std.testing.expectEqual(@as(u32, 1000), g.status_bar.w);
    // **사이드바 바닥 = 상태바 윗변.** 겹치면 카드가 바 뒤로 숨고, 틈이 벌어지면 배경이 끊긴다.
    try std.testing.expectEqual(g.status_bar.y, g.sidebar.y + g.sidebar.h);
    // 터미널·도크도 같은 선에서 멈춘다.
    try std.testing.expect(g.terminal.y + g.terminal.h <= g.status_bar.y);
    try std.testing.expect(g.dock.y + g.dock.h <= g.status_bar.y);
    // 사이드바는 여전히 **창 맨 위**부터다 — 상태바가 그것을 안 건드린다.
    try std.testing.expectEqual(@as(u32, 0), g.sidebar.y);
}

test "도크를 접어도 사이드바는 남는다" {
    const base = Input{
        .backing_width_px = 1000,
        .backing_height_px = 640,
        .sidebar_width_px = 180,
        .titlebar_height_px = 38,
        .cell_width_px = 8,
        .cell_height_px = 19,
        .scale_milli = 1000,
        .divider_px = 10,
        .side = .right,
        .size_pt = 220,
        .visible = false,
    };
    const g = compute(base);
    // 도크가 없어도 띠는 그대로다 — 접기가 사이드바를 지우면 왼쪽이 통째로 사라진다.
    try std.testing.expectEqual(@as(u32, 180), g.sidebar.w);
    try std.testing.expectEqual(Region.sidebar, regionAt(g, 90, 300));
}
