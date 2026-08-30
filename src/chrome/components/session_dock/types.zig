//! Session Dock의 platform-neutral input DTO다.
//!
//! 이 파일은 archive scanner의 record나 AppSession을 보관하지 않는다. platform은 이미 redaction과
//! scope/filter를 끝낸 화면용 문자열만 이 구조로 투영하고, component는 그 immutable snapshot만 읽는다.

const std = @import("std");
const i18n = @import("../../../i18n.zig"); // 표시 문자열 단일 출처
const layout = @import("../../ui/layout.zig");
const scroll_area = @import("../../ui/scroll_area.zig");
const spacing = @import("../../ui/spacing.zig");
const tokens = @import("../../tokens.zig"); // 색은 role 로만 지목한다(literal RGB 금지)
const ui_icon = @import("../../ui/icon.zig"); // 아이콘 슬롯 크기 토큰 단일 출처(ui/button과 같은 값을 쓴다)
const typography = @import("../../ui/typography.zig");

pub const Scope = enum { workspace, project, all };

/// 목록 정렬 방향. 키는 항상 transcript의 마지막 활동 시각이고(docs/agent-session-list.md §2.3), 이
/// 값은 **방향만** 정한다. 스캔 순서는 방향과 무관하게 늘 최신 우선이다 — 부분 publish가 최신부터
/// 차오르는 것과 같은 근거다.
pub const SortOrder = enum {
    newest_first,
    oldest_first,

    pub fn label(self: SortOrder) []const u8 {
        return switch (self) {
            .newest_first => i18n.t(.sd_sort_newest),
            .oldest_first => i18n.t(.sd_sort_oldest),
        };
    }

    pub fn toggled(self: SortOrder) SortOrder {
        return switch (self) {
            .newest_first => .oldest_first,
            .oldest_first => .newest_first,
        };
    }
};

pub const Provider = enum {
    codex,
    claude,

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .codex => "Codex",
            .claude => "Claude",
        };
    }

    /// provider 이름을 그릴 색 역할. 실제 색은 토큰 층이 소유하고(`tokens.ColorRole` 주석) 이 함수는
    /// 매핑만 한다 — 컴포넌트가 literal RGB를 들고 있으면 테마를 갈 수 없다. provider 를 추가하면
    /// 이 switch 가 컴파일 에러로 색 결정을 요구한다.
    pub fn colorRole(self: Provider) tokens.ColorRole {
        return switch (self) {
            .codex => .agent_codex_fg,
            .claude => .agent_claude_fg,
        };
    }
};

/// 상세 데이터는 host worker가 이미 redaction을 끝냈다. dock은 그 텍스트도 provider identity도
/// 비교하지 않고, 선택된 카드 하나의 불변 값을 투영하기만 한다.
pub const DetailState = enum { loading, ready, stale, unavailable };
pub const TurnRole = enum { user, assistant };

pub const Turn = struct {
    role: TurnRole,
    text: []const u8,
};

/// 안정 archive identity가 `Props.expanded_identity`와 같은 카드만 이 값을 실을 수 있다.
/// `Card.selected`는 여전히 키보드/hover 선택이며 펼침 상태의 대역이 아니다.
pub const Expanded = struct {
    state: DetailState,
    turns: []const Turn = &.{},
    action_record_count: u32 = 0,
    resume_enabled: bool = false,
    reveal_enabled: bool = false,
    focus_live_enabled: bool = false,
};

/// `identity`는 platform이 snapshot generation과 함께 검증하는 opaque 값이다. component는 이 값을
/// 비교/표시/명령 인자로 해석하지 않고 action table에 그대로 되돌린다.
/// 카드 메타데이터 줄은 **세그먼트 목록**이지 문장 하나가 아니다. 셋을 한 문자열로 뭉치면 그 줄 전체가
/// 한 색이 되어(옛 동작) 개수·시각·모델이 같은 무게로 읽힌다. 세그먼트로 두면 컴포넌트가 구분자와 색을
/// 소유해 위계를 준다 — 개수는 본문색, 시각은 muted, 모델은 provider 계열색(docs/agent-session-list.md §3).
///
/// 각 세그먼트는 **이미 지역화된 최종 문자열**이다(어순은 언어가 정한다). 빈 세그먼트는 구분자까지 함께
/// 빠진다 — subagent가 없는 카드가 흔하다.
pub const CardMetadata = struct {
    messages: []const u8 = "",
    age: []const u8 = "",
    model: []const u8 = "",
    subagents: []const u8 = "",
};

pub const Card = struct {
    identity: u64,
    provider: Provider,
    title: []const u8,
    summary: []const u8,
    metadata: CardMetadata,
    selected: bool = false,
    expanded: ?Expanded = null,
};

pub const Group = struct {
    identity: u64,
    label: []const u8,
    count: u16,
    collapsed: bool = false,
};

/// Projection은 group/card 순서를 이미 정했으며, component는 filesystem/JSONL을 읽어 재정렬하지 않는다.
pub const Item = union(enum) {
    group: Group,
    card: Card,
};

/// 스크롤해도 목록 상단에 남는 그룹 헤더(docs/scroll-area.md §4.7).
///
/// **`items` 창 밖일 수 있으므로 그룹 값을 여기 따로 싣는다.** 가상화는 보이는 항목만 넘기는데,
/// 상단에 걸린 그룹은 이미 위로 스크롤되어 나갔을 수 있다. 어느 그룹인지·그것이 content-space
/// 어디인지는 전체 목록을 아는 host만 안다.
pub const StickyGroup = struct {
    group: Group,
    /// content-space top(스크롤 offset을 빼기 전).
    top_px: u32,
    /// **다음** 그룹의 content-space top. 그것이 올라오면 이 헤더를 밀어낸다. 마지막 그룹이면 null이고
    /// 밀어내는 것이 없다.
    next_top_px: ?u32 = null,
};

pub const Props = struct {
    viewport_px: layout.UiSize,
    cell_width_px: u32,
    cell_height_px: u32,
    /// 논리 Dock point당 backing 픽셀을 해석한 값 — device backing scale에 host가 소유한 bounded
    /// SessionDockUiZoom을 합성한 것이다. semantic 컴포넌트는 이 값을 role line box를 잡는 데만 쓰고,
    /// 실제 glyph ink/baseline 측정은 여전히 platform adapter가 소유한다.
    scale_milli: u32 = 1000,
    snapshot_generation: u64,
    displayed_count: u16,
    recent_limit: u16 = 500,
    scope: Scope = .all,
    sort_order: SortOrder = .newest_first,
    workspace_scope_enabled: bool = true,
    project_scope_enabled: bool = true,
    search: []const u8 = "",
    /// IME marked text는 platform이 `search`로 확정하기 전까지 표시 전용이다. 이 값을 불변 DTO에 두면
    /// 필드가 활성 입력 소유자가 보는 것을 그대로 그리면서도, 확정되지 않은 조합이 archive 투영을
    /// 바꾸는 일은 막는다.
    search_preedit: []const u8 = "",
    search_focused: bool = false,
    search_cursor_visible: bool = false,
    loading: bool = false,
    refreshing: bool = false,
    /// 스캔이 사용자 이력의 일부만 훑었다. read budget 소진, 크기 초과 파일, 읽기/parse 실패가 모두
    /// 여기로 모인다. **정책적 제외(worker 판정)는 포함하지 않는다** — 정상 동작이 상시 경고로 보이면
    /// 경고가 무의미해진다. 헤더가 이 값을 문구로 바꿔 "목록이 전부가 아니다"를 사용자에게 알린다
    /// (docs/agent-session-list.md §4).
    partial: bool = false,
    spinner_phase: u3 = 0,
    /// 이 안정 identity는 host가 소유한다. snapshot 교체로 `(provider, session_id, device, inode)`가
    /// 바뀌면 detail/action capture와 함께 atomic하게 지운다.
    expanded_identity: ?u64 = null,
    /// content clip 기준으로 본 첫 가상화 아이템의 origin이다. 보통 0이거나 음수지만, offset이 아이템
    /// 사이 간격에 떨어지면 양수가 될 수 있다.
    content_first_item_origin_y_px: i32 = 0,
    /// 스크롤 목록 **전체**의 content 높이와 현재 offset(backing px). 가상화 때문에 component는 보이는
    /// 아이템만 받으므로, scrollbar가 얼마나 긴 목록의 어디를 보고 있는지는 이 두 값으로만 알 수 있다.
    /// 둘 다 host의 `scroll_area.project` 결과이며, 0이면 scrollbar를 발행하지 않는다.
    scroll_content_height_px: u32 = 0,
    /// 스크롤바 fade 의 최종 alpha(0xFF=선명). **`view` 만 읽는다 — `build` 는 쓰지 않는다.**
    /// tree 에 실으면 프레임마다 tree 가 달라져 발행 경로의 동등 비교가 매번 실패한다
    /// (계약 §7 — 그래서 이 값은 paint 시점에 얹는다). 산술은 host 가 소유한다.
    scrollbar_alpha: u8 = 0xFF,
    scroll_offset_px: u32 = 0,
    items: []const Item = &.{},
    /// null이면 상단에 걸린 그룹이 없다 — 첫 그룹에 닿기 전이라 흐름 위의 행이 그대로 보인다.
    sticky_group: ?StickyGroup = null,
};

/// Session Dock의 모든 소비자가 공유하는 불변 geometry snapshot 하나다. host는 가상화와 휠 이동에,
/// build는 publish할 UiRectTree에, view는 컴포넌트가 소유한 텍스트 offset에 같은 값을 쓴다. terminal
/// 셀 메트릭을 이 타입에서 빼 두어야 terminal family/line-spacing이 보이는 Chrome hit target을 움직이지
/// 못한다. host는 명시적으로 bounded UI zoom을 `scale_milli`에 합성할 수 있다.
pub const DockMetrics = struct {
    // 상단 view switcher의 높이는 더 이상 여기 없다. 그 바는 terminal tab bar와 **아래 경계선을 맞춰야**
    // 하는 유일한 도크 chrome이라, 두 소비자가 공유하는 logical token(`chrome.tokens` `space.bar_height_pt`)
    // 하나가 소유한다(docs/file-explorer.md §3.5). DockMetrics에 남겨 두면 같은 높이의 출처가 둘이 되고,
    // 그러면 한쪽만 바뀌어 경계선이 다시 어긋난다 — 그게 이 필드를 지운 이유다. 아래 필드들은 그 바 **아래**
    // 도크 본문의 치수라 계속 Dock UI zoom에 비례한다.
    header_h: u32,
    scope_h: u32,
    search_h: u32,
    group_h: u32,
    card_h: u32,
    expanded_detail_h: u32,
    expanded_actions_h: u32,
    /// Header/scope/search 사이의 fixed Chrome gap.
    control_gap: u32,
    /// Group/card 사이의 목록 gap. 목록은 row bottom divider로 구분하므로 기본값은 0이다.
    item_gap: u32,
    /// Expanded action siblings 사이의 가로 gap. 기본 목록 divider와 달리 버튼은 서로 독립된 target으로
    /// 보여야 하므로, shared row 안에서도 경계를 맞닿게 두지 않는다.
    action_gap: u32,
    root_inset: u32,
    header_content_inset_x: u32,
    header_host_label_w: u32,
    header_host_icon_extent: u32,
    header_host_icon_gap: u32,
    header_utility_gap: u32,
    header_refresh_extent: u32,
    /// 정렬 토글의 고정 slot 폭. 가장 긴 label(`오래된순`, 한글 4자)과 좌우 여백이 들어가는 값으로
    /// 고정한다 — label 길이에 따라 slot이 늘었다 줄면 그 옆의 `로컬`과 refresh가 방향을 바꿀 때마다
    /// 움직인다.
    ///
    /// 이 slot의 label은 cell 격자가 아니라 measured `center_in_rect`로 놓는다. cols 양자화 경로는 폭
    /// 예산을 `floor(available/cell_width)`로 깎아, slot에 실제로 들어가는 글자까지 미리 잘라 버렸다.
    header_sort_extent: u32,
    /// 정렬 토글의 line box 높이. control role 한 줄이며, 이 값이 있어야 header가 토글을 세로 중앙에
    /// 놓는다.
    header_sort_line_h: u32,
    header_trailing_inset: u32,
    /// 정렬 토글을 발행하려면 제목에 **최소한 이만큼**은 남아야 한다.
    ///
    /// `headerFitsSortToggle`의 의도는 "utility가 제목을 통째로 밀어내는 구간에서는 토글을 뺀다"인데,
    /// 판정이 utility 폭만 봤을 때는 제목 폭 0을 허용했다. 그러면 `view.headerStack`의 `available_px <= 0`
    /// (또는 `max_cols == 0`)에 걸려 **토글은 있는데 제목도 개수도 없는 헤더**가 나온다 — 무엇을 보고
    /// 있는지가 사라지는 것이 바로 그 주석이 막으려던 상태다.
    ///
    /// 값은 logical pt다. terminal cell 폭으로 정의하면 폰트를 바꿀 때마다 토글이 나타났다 사라진다.
    header_title_min_w: u32,
    group_disclosure_inset_x: u32,
    group_disclosure_extent: u32,
    group_disclosure_label_gap: u32,
    /// 스크롤바 track 폭·content edge와의 여백·최소 thumb 높이.
    scrollbar_width: u32,
    scrollbar_inset_x: u32,
    scrollbar_min_thumb: u32,
    card_inset_x: u32,
    /// 카드 우측 disclosure chevron과 그 왼쪽 텍스트 사이의 최소 여백. 제목·요약·metadata의 폭 예산은
    /// 이 값과 disclosure slot을 함께 뺀 뒤 계산한다 — 그러지 않으면 measured ellipsis가 chevron 바로
    /// 옆까지(심하면 그 아래까지) 밀려 두 요소가 한 덩어리로 보인다(사용자 보고).
    card_disclosure_gap: u32,
    card_title_y: u32,
    card_summary_y: u32,
    card_metadata_y: u32,
    detail_inset_x: u32,
    detail_heading_y: u32,
    detail_record_y: u32,
    detail_turn_y: u32,
    detail_turn_step: u32,

    /// 카드 본문 텍스트가 침범하면 안 되는 우측 폭. disclosure slot 자체와 그 바깥 inset, 그리고 둘
    /// 사이의 최소 여백을 합친다. `cardDisclosure`가 slot을 놓는 식과 같은 항을 쓰므로, 한쪽만 바뀌어
    /// 텍스트가 chevron 아래로 흘러드는 상태가 생길 수 없다.
    /// scrollbar 기하 모듈이 받는 형태. 치수의 단일 출처를 `DockMetrics` 하나로 유지한다.
    pub fn scrollbarMetrics(self: DockMetrics) scroll_area.ScrollbarMetrics {
        return .{
            .width_px = self.scrollbar_width,
            .inset_x_px = self.scrollbar_inset_x,
            .min_thumb_px = self.scrollbar_min_thumb,
        };
    }

    pub fn cardDisclosureReserve(self: DockMetrics) u32 {
        return self.card_inset_x + self.group_disclosure_extent + self.card_disclosure_gap;
    }

    pub fn resolve(scale_milli: u32) DockMetrics {
        const scale = effectiveScale(scale_milli);
        const button = ButtonMetrics.resolve(scale_milli);
        // **카드 여백은 `sm`, 줄 간격은 `xxs`**(2026-08-25 밀도 조정). 기본 폭에서 카드가 102pt 라
        // 700pt 도크에 6개뿐이었고, 그 높이의 **28pt 가 여백·간격**이었다(위아래 16 + 줄 사이 8 둘).
        // 파일 탐색기가 행 높이를 고를 때 쓴 것과 같은 기준이다 — "넉넉한 30px 는 한 화면 행 수가 약
        // 2/3 로 줄어 기각"(계획 문서 §3). 여기서는 반대 방향으로 같은 저울을 쓴다: 여백을 한 단
        // 줄이면 카드가 102 → 86pt 가 되어 같은 높이에 **8개**가 들어온다.
        //
        // 값은 spacing 토큰으로 둔다 — 리터럴로 적으면 다음 조정에서 이 카드만 척도 밖으로 나간다.
        const card_inset = spacing.px(.sm, scale);
        const card_title_y = card_inset;
        const card_summary_y = saturatedAdd(saturatedAdd(card_title_y, typography.lineHeightPx(.card_heading, scale)), spacing.px(.xxs, scale));
        const card_metadata_y = saturatedAdd(saturatedAdd(card_summary_y, typography.lineHeightPx(.body, scale)), spacing.px(.xxs, scale));
        const detail_inset = spacing.px(.md, scale);
        const detail_heading_y = detail_inset;
        const detail_record_y = saturatedAdd(saturatedAdd(detail_heading_y, typography.lineHeightPx(.body, scale)), spacing.px(.xxs, scale));
        const detail_turn_y = @max(saturatedAdd(saturatedAdd(detail_record_y, typography.lineHeightPx(.metadata, scale)), spacing.px(.sm, scale)), spacing.pointsPx(64, scale));
        const detail_turn_step = saturatedAdd(saturatedAdd(saturatedAdd(typography.lineHeightPx(.overline, scale), spacing.px(.xxs, scale)), typography.lineHeightPx(.body, scale)), spacing.px(.sm, scale));
        return .{
            // Heading + supporting + 4pt stack gap + 12pt vertical inset on each side.
            .header_h = geometryPx(@max(spacing.pointsPx(76, scale), saturatedAdd(saturatedAdd(saturatedAdd(typography.lineHeightPx(.dock_heading, scale), typography.lineHeightPx(.supporting, scale)), spacing.px(.xxs, scale)), saturatedMul(spacing.px(.sm, scale), 2)))),
            // scope는 **필터 세그먼트**이지 action button이 아니다. 48pt action 하한을 같이 쓰면 검색 필드와
            // 같은 덩치가 되어 도크 상단이 컨트롤 두 줄로 꽉 찬다(사용자 보고 2026-08-11: "작업공간·프로젝트·
            // 전체가 너무 크다", 36pt로 낮춘 뒤에도 "좀 더 작게"). control 한 줄 + xxs 여백을 자기 하한으로
            // 두어 검색 필드(48pt)의 절반 남짓한 얇은 필터 줄로 읽히게 한다.
            //
            // 30pt는 pointer target 최소치(그룹 행 48pt)보다 **낮고 그것이 의도다**: 세그먼트는 가로로 도크
            // 1/3폭(자동 폭 640pt에서 약 200pt)을 차지하므로 타깃 면적 자체는 그 행보다 훨씬 넓다. 한때
            // 26pt까지 내렸다가 되돌린 값이다(사용자 2026-08-12: "너무 줄였다") — 바닥은 line box 17pt이지만
            // 실제로 얇아 보이는 한계가 그보다 높다.
            .scope_h = geometryPx(@max(spacing.pointsPx(30, scale), saturatedAdd(typography.lineHeightPx(.control, scale), saturatedMul(spacing.px(.xxs, scale), 2)))),
            .search_h = geometryPx(@max(button.minimum_height_px, saturatedAdd(typography.lineHeightPx(.control, scale), saturatedMul(spacing.px(.sm, scale), 2)))),
            .group_h = geometryPx(@max(spacing.pointsPx(48, scale), saturatedAdd(typography.lineHeightPx(.group_heading, scale), saturatedMul(spacing.px(.sm, scale), 2)))),
            // 하한은 "role line box 합이 지나치게 작아졌을 때의 바닥"이지 목표 높이가 아니다. typography를
            // 낮춘 뒤에도 112pt가 계산값(98px @1x)을 이겨 카드 안에 14px이 빈 여백으로 남았다 — 글자만 작아지고
            // 밀도는 그대로여서 어색했다. 계산값이 이기도록 낮춰 타이포 변화가 밀도에 그대로 반영되게 한다.
            // 그룹 행의 48pt 하한은 성격이 다르다(포인터 타깃 최소 크기)라서 건드리지 않는다.
            // **하한도 함께 내린다**(2026-08-25). 여백·간격을 한 단 줄여 계산값이 86pt 가 됐는데 96pt
            // 하한이 그것을 다시 이기면 위 문장이 경고하는 상태가 재현된다 — 여백만 줄고 밀도는 그대로다.
            // 새 하한은 **포인터 타깃 최소**(48pt — 그룹 행·버튼과 같은 값)라 "왜 이 숫자인가"에 답이 있다.
            .card_h = geometryPx(@max(spacing.pointsPx(48, scale), saturatedAdd(saturatedAdd(card_metadata_y, typography.lineHeightPx(.metadata, scale)), card_inset))),
            .expanded_detail_h = geometryPx(@max(spacing.pointsPx(256, scale), saturatedAdd(saturatedSub(saturatedAdd(detail_turn_y, saturatedMul(detail_turn_step, 3)), spacing.px(.sm, scale)), detail_inset))),
            .expanded_actions_h = button.minimum_height_px,
            .control_gap = geometryPx(spacing.px(.sm, scale)),
            .item_gap = 0,
            .action_gap = geometryPx(spacing.px(.xs, scale)),
            .root_inset = geometryPx(spacing.px(.lg, scale)),
            .header_content_inset_x = geometryPx(spacing.px(.xs, scale)),
            // The provenance pair has enough room for its 18pt SVG, 8pt gap, and the host label
            // without asking terminal-cell metrics where a Chrome header control should begin.
            //
            // **이 72pt 는 한국어 라벨("로컬")을 재고 정한 값이다** — 계약 §6.1 이 경계하는 모양이다.
            // 지금은 영어("Local")가 더 좁게 들어가 넘치지 않으므로 값을 그대로 둔다. 호스트 라벨이
            // 늘거나(원격 이름) 라틴보다 넓은 문자를 쓰는 언어가 붙으면 그때는 라벨에서 계산해야 한다 —
            // 알림 패널이 같은 이유로 이미 상수에서 계산으로 바뀌었다(`notifications.minPanelCols`).
            .header_host_label_w = geometryPx(spacing.pointsPx(72, scale)),
            .header_host_icon_extent = geometryPx(spacing.pointsPx(ui_icon.Size.default.extentPt(), scale)),
            .header_host_icon_gap = geometryPx(spacing.px(.xs, scale)),
            .header_utility_gap = geometryPx(spacing.px(.sm, scale)),
            // A 24pt target gives the 18pt registered refresh glyph three logical points of
            // optical breathing room on every side.  The 20pt trailing inset matches the
            // shared dock content edge, so neither the SVG nor the spinner reads as clipped.
            .header_refresh_extent = geometryPx(spacing.pointsPx(24, scale)),
            // 가장 긴 label `오래된순`(한글 4자)이 좌우 여백과 함께 들어가야 한다. 72pt였을 때는 도크 텍스트가
            // 사용자 monospace face라(폰트 전략) 한글 4자가 slot을 넘겨 `…`로 잘렸다(사용자 보고). control
            // 13pt 기준 한글 4자는 약 62pt이므로 좌우 여백을 포함해 84pt로 둔다.
            .header_sort_extent = geometryPx(spacing.pointsPx(84, scale)),
            .header_sort_line_h = geometryPx(typography.lineHeightPx(.control, scale)),
            .header_trailing_inset = geometryPx(spacing.px(.lg, scale)),
            // 48pt면 dock_heading으로 한글 세 자 남짓이다. 제목이 `…` 하나로 줄어드는 것까지는 허용하되,
            // 아예 사라지는 구간은 만들지 않는다.
            .header_title_min_w = geometryPx(spacing.pointsPx(48, scale)),
            // The root already contributes the dock's 20pt content inset. The disclosure gets
            // only its local 8pt slot, preventing the chevron from inheriting a second 20pt.
            .group_disclosure_inset_x = geometryPx(spacing.px(.xs, scale)),
            .group_disclosure_extent = geometryPx(spacing.pointsPx(20, scale)),
            .group_disclosure_label_gap = geometryPx(spacing.px(.xs, scale)),
            // 스크롤바는 8pt track을 content edge에서 4pt 안쪽에 둔다. thumb 최소 높이 24pt는 파일
            // 탐색기 스크롤바와 같은 값으로, 아주 긴 목록에서도 집을 수 있는 크기를 보장한다.
            .scrollbar_width = geometryPx(spacing.pointsPx(8, scale)),
            .scrollbar_inset_x = geometryPx(spacing.pointsPx(4, scale)),
            .scrollbar_min_thumb = geometryPx(spacing.pointsPx(24, scale)),
            .card_inset_x = geometryPx(card_inset),
            .card_disclosure_gap = geometryPx(spacing.px(.sm, scale)),
            .card_title_y = geometryPx(card_title_y),
            .card_summary_y = geometryPx(card_summary_y),
            .card_metadata_y = geometryPx(card_metadata_y),
            .detail_inset_x = geometryPx(detail_inset),
            .detail_heading_y = geometryPx(detail_heading_y),
            .detail_record_y = geometryPx(detail_record_y),
            .detail_turn_y = geometryPx(detail_turn_y),
            .detail_turn_step = geometryPx(detail_turn_step),
        };
    }

    /// `include_sort`는 published tree가 정렬 토글을 실제로 냈는지다. 좁은 도크에서는 토글을 빼므로
    /// 예약 폭도 함께 줄어야 한다 — 두 값이 어긋나면 `로컬`이 refresh 위로 겹치거나 제목이 필요 이상으로
    /// 잘린다.
    /// 정렬 토글을 발행해도 되는가. 최소 도크 폭이 120pt라(session/dock_layout.zig) utility control이
    /// 제목을 통째로 밀어내는 폭이 실제로 존재한다. 그 구간에서는 토글보다 "무엇을 보고 있는지"가
    /// 먼저다 — 토글을 빼고 제목에 자리를 준다.
    pub fn headerFitsSortToggle(self: DockMetrics, header_width_px: u32) bool {
        return header_width_px >= saturatedAdd(saturatedAdd(self.headerUtilityWidth(true), self.header_content_inset_x), self.header_title_min_w);
    }

    pub fn headerUtilityWidth(self: DockMetrics, include_sort: bool) u32 {
        // host label · gap · 정렬 토글 · gap · refresh · trailing inset. heading stack이 이 폭만큼
        // 자리를 비워야 제목이 utility control 밑으로 들어가지 않는다.
        var total = saturatedAdd(self.header_host_label_w, self.header_utility_gap);
        if (include_sort) {
            total = saturatedAdd(total, self.header_sort_extent);
            total = saturatedAdd(total, self.header_utility_gap);
        }
        total = saturatedAdd(total, self.header_refresh_extent);
        return geometryPx(saturatedAdd(total, self.header_trailing_inset));
    }
};

/// 측정된 action-content 묶음 하나의 메트릭이다. 이 값들은 Chrome 논리 point와 해석된 Dock scale만
/// 쓴다 — terminal 셀 폭이나 SVG viewBox 여백은 padding 입력이 아니다.
pub const ButtonMetrics = struct {
    content_inset_x_px: u32,
    content_inset_y_px: u32,
    leading_icon_extent_px: u32,
    leading_icon_gap_px: u32,
    minimum_height_px: u32,

    pub fn resolve(scale_milli: u32) ButtonMetrics {
        // Props default to 1000, but malformed/pre-render snapshots may still carry zero.
        // `view.effectiveScale` uses the same fallback; matching it here keeps the published
        // action rect large enough for the content artifact rather than producing a blank button.
        const scale = effectiveScale(scale_milli);
        return .{
            .content_inset_x_px = geometryPx(spacing.px(.md, scale)),
            .content_inset_y_px = geometryPx(spacing.px(.sm, scale)),
            .leading_icon_extent_px = geometryPx(spacing.pointsPx(ui_icon.Size.default.extentPt(), scale)),
            .leading_icon_gap_px = geometryPx(spacing.px(.xs, scale)),
            .minimum_height_px = geometryPx(spacing.pointsPx(48, scale)),
        };
    }
};

fn effectiveScale(scale_milli: u32) u32 {
    return if (scale_milli == 0) 1000 else scale_milli;
}

fn geometryPx(value: u32) u32 {
    return @min(value, @as(u32, std.math.maxInt(i32)));
}

fn saturatedAdd(a: u32, b: u32) u32 {
    return a +| b;
}

fn saturatedSub(a: u32, b: u32) u32 {
    return a -| b;
}

fn saturatedMul(a: u32, b: u32) u32 {
    return a *| b;
}

test "DockMetrics fixes all Session Dock geometry independently of terminal cells" {
    const m = DockMetrics.resolve(1000);
    try std.testing.expectEqual(@as(u32, 76), m.header_h);
    // scope는 action button 하한(48pt)이 아니라 자기 하한 30pt를 쓴다 — 검색 필드보다 확실히 낮은 얇은 필터 줄.
    try std.testing.expectEqual(@as(u32, 30), m.scope_h);
    try std.testing.expect(m.scope_h < m.search_h);
    // 하한이 계산값(line box + 여백)을 이겨야 위아래 여백이 남는다. 뒤집히면 글자가 상자에 꽉 찬다.
    try std.testing.expect(m.scope_h > typography.lineHeightPx(.control, 1000));
    try std.testing.expectEqual(@as(u32, 48), m.search_h);
    try std.testing.expectEqual(@as(u32, 48), m.group_h);
    // 카드 높이는 이제 하한이 아니라 role line box 합이 정한다(96pt 하한 < 98px 계산값). 그래서 이 값은
    // typography를 바꾸면 함께 움직이는 것이 정상이고, 그때 이 단언도 같이 갱신한다.
    // 여백(md → sm)과 줄 간격(xs → xxs)을 한 단 줄여 98 → 86 이 됐다(2026-08-25 밀도 조정): 위아래 12 +
    // 제목 20 + 4 + 요약 18 + 4 + 메타 16 = 86. typography 나 spacing 을 바꾸면 함께 움직이는 것이
    // 정상이고, 그때 이 단언도 같이 갱신한다.
    try std.testing.expectEqual(@as(u32, 86), m.card_h);
    try std.testing.expectEqual(@as(u32, 256), m.expanded_detail_h);
    try std.testing.expectEqual(@as(u32, 48), m.expanded_actions_h);
    try std.testing.expectEqual(@as(u32, 12), m.control_gap);
    try std.testing.expectEqual(@as(u32, 0), m.item_gap);
    try std.testing.expectEqual(@as(u32, 8), m.action_gap);
    try std.testing.expectEqual(@as(u32, 20), m.root_inset);
    try std.testing.expectEqual(@as(u32, 8), m.header_content_inset_x);
    try std.testing.expectEqual(@as(u32, 72), m.header_host_label_w);
    try std.testing.expectEqual(@as(u32, 18), m.header_host_icon_extent);
    try std.testing.expectEqual(@as(u32, 8), m.header_host_icon_gap);
    try std.testing.expectEqual(@as(u32, 12), m.header_utility_gap);
    try std.testing.expectEqual(@as(u32, 24), m.header_refresh_extent);
    try std.testing.expectEqual(@as(u32, 84), m.header_sort_extent);
    try std.testing.expectEqual(@as(u32, 20), m.header_trailing_inset);
    try std.testing.expectEqual(@as(u32, 48), m.header_title_min_w);
    try std.testing.expectEqual(@as(u32, 8), m.group_disclosure_inset_x);
    try std.testing.expectEqual(@as(u32, 20), m.group_disclosure_extent);
    try std.testing.expectEqual(@as(u32, 8), m.group_disclosure_label_gap);
    // host label 72 + gap 12 + 정렬 토글 84 + gap 12 + refresh 24 + trailing inset 20.
    try std.testing.expectEqual(@as(u32, 224), m.headerUtilityWidth(true));
    // 좁은 도크에서 토글을 빼면 예전 폭으로 돌아간다.
    try std.testing.expectEqual(@as(u32, 128), m.headerUtilityWidth(false));
    // utility 224 + content inset 8 + 제목 최소 48 = 280이 경계다. 제목이 0폭으로 짜부라지는 구간에서는
    // 토글을 내지 않는다 — 그 구간이 바로 "토글은 있는데 제목이 없는 헤더"였다.
    try std.testing.expect(m.headerFitsSortToggle(280));
    try std.testing.expect(!m.headerFitsSortToggle(279));
    try std.testing.expect(!m.headerFitsSortToggle(160));
    try std.testing.expect(m.card_metadata_y < m.card_h);
    try std.testing.expect(m.detail_turn_y + m.detail_turn_step * 3 <= m.expanded_detail_h);
}

test "scope segment keeps room for its label across the whole bounded dock zoom range" {
    // scope를 26pt까지 낮춘 뒤 남은 위험은 하나다: 어떤 scale에서 control line box가 상자를 이기면
    // `view.centeredLabel`이 통째로 return해 **라벨이 사라진다**. 도크 UI zoom은 750~1500 milli로
    // clamp되고(agent_dock.zig `session_dock_ui_zoom_*`) 거기에 Retina 2x가 곱해지므로 3000까지 본다.
    for ([_]u32{ 750, 1000, 1250, 1500, 2000, 2500, 3000 }) |milli| {
        const m = DockMetrics.resolve(milli);
        try std.testing.expect(m.scope_h > typography.lineHeightPx(.control, milli));
        // 검색 필드보다 낮다는 위계도 scale에 무관해야 한다 — 한쪽만 하한에 걸리면 뒤집힌다.
        try std.testing.expect(m.scope_h < m.search_h);
        // 정렬 토글 slot도 같은 이유로 자기 line box보다 넓어야 한다.
        try std.testing.expect(m.header_sort_extent > m.header_sort_line_h);
    }
}

test "DockMetrics scales with one resolved Dock scale" {
    const one_x = DockMetrics.resolve(1000);
    const two_x = DockMetrics.resolve(2000);
    inline for (std.meta.fields(DockMetrics)) |field| {
        try std.testing.expectEqual(@field(one_x, field.name) * 2, @field(two_x, field.name));
    }
    try std.testing.expectEqual(one_x.header_h, DockMetrics.resolve(0).header_h);
}

test "DockMetrics fails closed at extreme backing scale without overflow" {
    const m = DockMetrics.resolve(std.math.maxInt(u32));
    inline for (std.meta.fields(DockMetrics)) |field| {
        try std.testing.expect(@field(m, field.name) <= @as(u32, std.math.maxInt(i32)));
    }
}

test "ButtonMetrics is independent of terminal cell height and scales in backing pixels" {
    const one_x = ButtonMetrics.resolve(1000);
    const two_x = ButtonMetrics.resolve(2000);
    try std.testing.expectEqual(@as(u32, 16), one_x.content_inset_x_px);
    try std.testing.expectEqual(@as(u32, 12), one_x.content_inset_y_px);
    try std.testing.expectEqual(@as(u32, 18), one_x.leading_icon_extent_px);
    try std.testing.expectEqual(@as(u32, 8), one_x.leading_icon_gap_px);
    try std.testing.expectEqual(@as(u32, 48), one_x.minimum_height_px);
    try std.testing.expectEqual(one_x.minimum_height_px * 2, two_x.minimum_height_px);
    try std.testing.expectEqual(one_x.minimum_height_px, ButtonMetrics.resolve(0).minimum_height_px);
    const extreme = ButtonMetrics.resolve(std.math.maxInt(u32)).minimum_height_px;
    try std.testing.expect(extreme > 0);
    try std.testing.expect(extreme <= @as(u32, std.math.maxInt(i32)));
}
