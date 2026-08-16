//! Chrome 디자인 토큰(데이터). 컴포넌트는 `tokens.get(role)`만 읽고 `if (rich)` 분기를 절대 안 한다 —
//! 테마 전환 = 토큰셋 교체(컴포넌트 코드 불변). tui와 rich는 같은 struct의 두 값. 현재 코드에 흩어진
//! 색 파생(lighten +24/+48 등)·픽셀 상수(사이드바 폭·슬롯 높이)를 여기로 모은다.
//! 단일 출처: docs/chrome-strategy.md §5.1, docs/layering-and-portability.md §6.

const std = @import("std");
const Rgb = @import("../color.zig").Rgb;

/// rich 토큰 색 파생(neutral — config의 appearance.lighten을 chrome이 import 못 하므로 여기 둔다). 채널별 ±delta를
/// [0,255]로 clamp. rich가 tui의 sidebar_active-공유 role을 분리할 때만 쓴다(tui는 안 씀 — 원본 테마 색 그대로).
fn clampChannel(c: u8, delta: i16) u8 {
    return @intCast(std.math.clamp(@as(i16, c) + delta, 0, 255));
}
fn lightenRgb(rgb: Rgb, delta: u8) Rgb {
    return .{ .r = clampChannel(rgb.r, delta), .g = clampChannel(rgb.g, delta), .b = clampChannel(rgb.b, delta) };
}
fn darkenRgb(rgb: Rgb, delta: u8) Rgb {
    const d: i16 = -@as(i16, delta);
    return .{ .r = clampChannel(rgb.r, d), .g = clampChannel(rgb.g, d), .b = clampChannel(rgb.b, d) };
}

/// 단축키 힌트 키캡(KH-5) 배경 — 패널 대비 **항상 또렷**하게. 패널이 어두우면 밝게, 밝으면 어둡게 한다(루미넌스
/// 기준). 단순 lighten은 light 테마에서 near-white로 saturate돼 밝은 패널에 묻히고(리뷰 #1), 순백 패널에선 fill이
/// surface_bg와 같아져 사라진다. Rec.601 근사 루미넌스(정수)로 명암을 갈라 light·dark 양쪽에서 대비를 보장한다.
fn keycapBg(panel: Rgb) Rgb {
    const lum: u16 = (@as(u16, panel.r) * 77 + @as(u16, panel.g) * 150 + @as(u16, panel.b) * 29) >> 8;
    return if (lum < 128) lightenRgb(panel, 40) else darkenRgb(panel, 40);
}

/// 패널 안쪽의 count pill/detail처럼 한 단계 들어간 표면. 어두운 테마에서는 panel보다 더
/// 어둡고, 밝은 테마에서는 더 밝아야 양쪽 모두 "구멍"처럼 보이면서 raw RGB를 강제하지 않는다.
fn insetBg(panel: Rgb) Rgb {
    const lum: u16 = (@as(u16, panel.r) * 77 + @as(u16, panel.g) * 150 + @as(u16, panel.b) * 29) >> 8;
    return if (lum < 128) darkenRgb(panel, 14) else lightenRgb(panel, 14);
}

/// 하단 상태바 배경 — 사이드바와 **같은 톤이되 구분은 되게**. 사이드바 색을 **터미널 배경의 반대
/// 방향으로** 한 단계 옮긴다.
///
/// 왜 `insetBg`(루미넌스 기준 recessed)를 안 쓰나: 라이트 테마에서 사이드바는 터미널보다 **어두운데**
/// insetBg는 밝은 패널을 더 밝게 옮겨 터미널 배경과 붙어 버린다(실측 Solarized: 252,246,227 vs
/// 터미널 253,246,227 — 차이 0). 상태바는 사이드바와도 터미널과도 달라야 하므로 기준이 루미넌스가
/// 아니라 **터미널로부터의 방향**이다(사용자 제보: 사이드바와 같고, 터미널과 같아도 구분이 안 된다).
pub fn statusBarBg(sidebar: Rgb, terminal: Rgb) Rgb {
    const ls: u16 = (@as(u16, sidebar.r) * 77 + @as(u16, sidebar.g) * 150 + @as(u16, sidebar.b) * 29) >> 8;
    const lt: u16 = (@as(u16, terminal.r) * 77 + @as(u16, terminal.g) * 150 + @as(u16, terminal.b) * 29) >> 8;
    return if (ls >= lt) lightenRgb(sidebar, 14) else darkenRgb(sidebar, 14);
}

/// 상태바 **상단 경계선** 색. 바 배경에 divider 규칙을 한 번 더 적용한다.
///
/// 이 선은 위(터미널)와 아래(상태바) **둘 다와** 달라야 의미가 있다. `dividerBg`는 기준색의 명암 반대
/// 방향으로 옮기고, 바 색 자체가 이미 터미널 반대 방향으로 옮겨진(`statusBarBg`) 색이라 — 다크에선
/// 터미널<바<선, 라이트에선 터미널>바>선으로 세 색이 한 방향으로 벌어져 양쪽 대비가 동시에 보장된다.
pub fn statusBarBorder(sidebar: Rgb, terminal: Rgb) Rgb {
    return dividerBg(statusBarBg(sidebar, terminal));
}

/// Panel 경계선은 interactive active color에서 파생하지 않는다. active와 panel의 우연한 조합(예:
/// panel=40, active=64, active-24=40)이 1px rule을 배경과 완전히 같게 만들어 목록 경계가 사라졌기
/// 때문이다. 명암 반대 방향의 작은 이동은 dark/light panel 모두에서 semantic divider가 배경과 다름을
/// 보장하며 tui/rich가 같은 content hierarchy를 유지하게 한다.
fn dividerBg(panel: Rgb) Rgb {
    const lum: u16 = (@as(u16, panel.r) * 77 + @as(u16, panel.g) * 150 + @as(u16, panel.b) * 29) >> 8;
    return if (lum < 128) lightenRgb(panel, 24) else darkenRgb(panel, 24);
}

/// 색 역할(semantic). 컴포넌트는 역할만 알고, 실제 Rgb는 토큰이 준다. divider는 panel background 대비에서
/// 오고, focus_accent/drop_zone은 rich에서 분리할 수 있게 별도 role로 둔다.
pub const ColorRole = enum {
    surface_bg,
    surface_fg,
    muted_fg,
    /// 패널 안쪽으로 한 단계 들어간 면. 개수 pill이나 inset 상세가 dark 테마 literal에 기대거나
    /// 상호작용용 탭 색을 잘못 끌어 쓰지 않고 이 역할을 쓴다.
    inset_bg,
    tab_active_bg,
    tab_hover_bg,
    /// 목록 행(에이전트 행·토글) 호버 — **활성 밴드 위에 겹쳐도 구분되어야** 하므로 활성보다 한 단계 밝다.
    /// `tab_hover_bg`(배경↔활성 중간)를 쓰면 활성 카드의 목록에서 활성색보다 어두워 호버가 사라지고,
    /// `tab_active_bg`를 쓰면 활성색과 **완전히 같아** 역시 구분이 0이다(사용자 제보).
    row_hover_bg,
    divider,
    focus_accent,
    drop_zone,
    search_match,
    search_match_current,
    selection,
    cursor,
    accent_bar, // U1(C4b 이후): maru accent — **테마-구동**(ThemeColors.accent). 프리셋별 시그니처 색(null이면 브랜드 앰버 폴백). 탭/포커스 언더바·사이드바 활성 좌측 막대·세팅 강조가 소비(U2).
    keycap_bg, // KH-5: 단축키 힌트 키캡(키별 박스) 배경 — 패널 대비(명암 기준 밝게/어둡게)라 tui·rich·light·dark 모두 또렷(keycapBg).
    /// 파괴적 action의 면. `ThemeColors`에 아직 semantic 오류 입력이 없어서, 컴포넌트로 literal RGB를
    /// 흘리는 대신 이 토큰 층이 보수적 폴백을 소유한다.
    danger_bg,
    danger_fg,
    /// git 상태 색(소스 컨트롤 목록의 상태 문자·아이콘). **`danger_*`와 같은 규율**로 이 층이 보수적
    /// 폴백을 소유한다 — `ThemeColors`에 semantic 입력(성공/경고)이 아직 없기 때문이고, 생기면 이
    /// 매핑만 바뀐다(컴포넌트 코드는 역할만 읽으므로 불변).
    ///
    /// **역할이 셋인 이유**: 사용자가 목록을 훑을 때 가르는 것은 "고친 것 / 새로 생긴 것 / 없어진 것"
    /// 셋이다. 추적되지 않은 파일(`U`)은 "새로 생긴 것"이라 `git_added_fg`를 함께 쓴다(VS Code 관례).
    /// **색만으로 구분하지 않는다** — 상태 문자가 함께 있고, 색은 그 글자를 빨리 찾게 돕는 보조다.
    git_modified_fg,
    git_added_fg,
    git_deleted_fg,
    /// **터미널 본문 배경.** chrome 표면(`surface_bg` — 사이드바·도크)과 **다른 색**이고, 그 차이가
    /// 의미다: 이 색이 칠해진 자리는 "셸/문서 내용이 사는 곳"이다.
    ///
    /// 네이티브 편집기 뷰가 이것을 쓴다(§4.1b) — 편집기는 도크가 아니라 **터미널이 있던 자리**를
    /// 채우므로, 탭을 오갈 때 같은 pane의 바탕이 밝아졌다 어두워지면 안 된다(2026-08-13 사용자 결정).
    terminal_bg,
    /// **비교 본문의 추가·삭제 밴드**(native-editor-ui.md §7). 배경 위에 **알파로 얹는 색**이라
    /// 본문 토큰만큼 밝힐 필요가 없고(대비 목표 3.0), 그래서 `syntax_theme.diffFromTheme`가
    /// 터미널 팔레트의 bright green/red에서 파생한다 — 사용자가 테마를 바꾸면 diff도 같이 바뀌어야
    /// 한 창 안에서 색 언어가 갈리지 않는다.
    ///
    /// **역할은 색만 정하고 세기는 op이 정한다**(`Quad.alpha`) — 같은 색이 줄 배경(옅게)과 좌측
    /// 띠(진하게)에 함께 쓰이므로, 세기까지 역할로 나누면 토큰이 두 배가 되고 둘이 어긋난다.
    diff_added_bg,
    diff_removed_bg,
};

/// 비-색 레이아웃 토큰(픽셀/비율, 정적 디자인 값 — rich는 바꾼다). chrome-strategy.md §5.1이 정의한 계획 기반
/// 토큰이라, 아직 소비처가 없어도(C2/C3 컴포넌트에서 읽음) 계획 링크와 함께 둔다(메모리 no-defensive 예외).
/// 단 **런타임 가변값(사이드바 폭 — 사용자 드래그)은 토큰이 아니라 props**(metrics.sidebar_width_px, 동적)로 흐른다
/// — 정적 토큰에 하드코딩하면 stale 출처가 되므로 토큰에 두지 않는다.
/// 활성 탭 룩(`chrome.tab-style` 직교 축 — chrome-strategy.md §7). chrome **중립** enum이라 platform이 config
/// `ChromeTabStyle`을 이 값으로 매핑한다(chrome은 config를 import 안 함 — 색이 ThemeColors로 흐르는 것과 동형).
/// 스타일은 활성 탭 *세그먼트 안의 fill*만 바꾸고 세그먼트 기하(`tabbar.segOf`)는 불변이라 hit-test/드래그/✕는 그대로(§5.4).
/// pill은 TS2(둥근 inset quad). rich 경로에서만 의미(tui는 셀 밴드 유지).
pub const TabActiveStyle = enum(u8) {
    connected = 0, // U-tab2: 본문색 cutout(바 전체 높이) + 앰버/muted 언더바 — 아래 본문과 이어짐
    underline = 1, // 배경 fill 없음 + 앰버/muted 언더바만 — 가장 미니멀
    pill = 2, // 둥근 inset 캡슐을 strip보다 밝은 lifted 회색으로 채우고 옅은 밝은 테두리 — 떠 있는 pill(실제 Warp 벤치마킹), 포커스=fill 밝기
};

pub const Spacing = struct {
    modal_margin_cells: u32 = 2, // 모달 박스 좌우 안쪽 여백(셀) — Notice가 소비
    sidebar_slot_height_ratio_milli: u32 = 2500, // 사이드바 슬롯 높이 = 2.5×cell. C2/C3 사이드바 컴포넌트가 소비(계획)
    // C4b: chrome 박스 모양(rich GPU quad). tui=0(직각·테두리 없음 → lowering이 셀 fill 유지), rich>0(둥근·테두리).
    // 컴포넌트 view가 이 값을 Op.quad.corner_radii/border_widths에 실어, 같은 코드가 두 룩을 만든다(C4a 색 분리와 동형).
    corner_radius_px: u16 = 0,
    border_width_px: u16 = 0,
    // C4b 모달: 그림자(GpuShadow). tui=0(그림자 없음 — 모달이 rich quad 안 내므로 무관), rich>0(떠 보임).
    shadow_blur_px: u16 = 0,
    shadow_offset_y_px: u16 = 0,
    shadow_alpha: u8 = 0, // 0xAARRGGBB의 A(RGB는 검정 0). 0이면 그림자 안 보임.
    // C4b 모달: 배경 quad가 텍스트 영역보다 큰 안쪽 여백(px). tui=0(딱 맞는 셀 배경), rich>0(텍스트 주변 여백).
    // platform lowering이 모달 quad/shadow rect를 이 값만큼 사방 확장(텍스트 셀은 그대로) — 텍스트가 박스 안쪽에 든다.
    modal_padding_px: u16 = 0,
    // U1: 사이드바 카드 좌측 accent 막대 폭(px). tui=0(막대 없음), rich>0. 막대색은 카드별(우클릭 "바: …", tab.accent_color)
    // 이라 chrome이 아니라 platform(app_session rebuildSidebar per-tab accent 루프)이 이 폭으로 직접 GpuQuad를 그린다.
    // chrome은 이 값으로 카드 텍스트 좌측 여백만 예약한다(buildSidebarTitleDrawList indent — 막대 위 정합·단일 출처).
    accent_bar_width_px: u16 = 0,
    // U2: 사이드바 카드 **텍스트 좌측 여백**(px) — accent 막대 폭과 더해 텍스트 시작 col을 정한다. 밴드·막대 기하는
    // 이제 행 전체라 이 값을 쓰지 않는다(docs/sidebar-agent-list.md §3.2 — 클릭 판정 정합). tui=0, rich>0.
    card_gap_px: u16 = 0,
    // SG3: 사이드바 그룹 안 카드(depth 1)의 좌측 들여쓰기(px) — 그룹 헤더 아래 카드가 소속을 시각적으로 보이게 살짝
    // 안으로. hit-test·view가 공유하는 단일 값(§5.4)이라 여기 한 곳에서만 정의한다. platform buildSidebarTitleDrawList가
    // ceil(이 값/cw)만큼 grouped 카드 이름 앞에 공백을 넣어 들여쓴다. tui=0(들여쓰기 없음), rich≈1~2ch. docs/sidebar-groups.md §5.
    group_indent_px: u16 = 0,
    // U-tab: rich 탭 하나의 고정 폭(컬럼). 0이면 균등분할(tui — 바를 탭 수로 나눠 stretch). >0이면 고정폭 — 탭이
    // 내용과 무관히 이 폭, 적으면 왼쪽정렬+빈 영역, 많으면 넘쳐(가로 스크롤 대상) 잘린다. 제목 ~N자 + ✕ 2칸 기준.
    tab_width_cols: u16 = 0,
    // U-tab: rich 탭 바 텍스트 위아래 세로 패딩(px). 바 높이 = cell_height + 2*이값, 제목은 가운데(탭 세로 여유).
    // tui=0이면 바 = cell 1칸(기존).
    tab_bar_pad_y_px: u16 = 3, // tui 기본도 세로 패딩 — grip 핸들·탭 제목이 바 세로 가운데에 오게(0이면 상단에 붙어 답답). rich는 6으로 override.
    // U-tab2: 활성 탭 하단 maru-앰버 언더바(active indicator) 두께(px). 탭바 하단 하이라인(line_thickness_px)과
    // **분리**해 활성 신호를 더 굵고 또렷하게 한다. tui=0(셀 밴드 경로라 미사용), rich>0. appendActiveTabHighlight가 소비.
    tab_underbar_px: u16 = 0,
    // TS1: 활성 탭 룩(chrome.tab-style 직교 축 — §7). platform buildChromeTokens가 appearance.chrome_tab_style→이 값으로
    // 매핑하고 appendActiveTabHighlight가 분기(connected=cutout+언더바 / underline=언더바만 / pill=둥근 inset+테두리). tui는 셀 밴드라 미사용.
    tab_active_style: TabActiveStyle = .connected,
    // TS2: pill 스타일의 세로 inset(px) — 바 위아래에서 이만큼 들여 둥근 pill이 strip 위에 떠 보인다. radius는
    // corner_radius_px, 테두리 두께는 border.line_thickness_px 재사용. connected/underline은 미사용. rich>0.
    tab_pill_inset_px: u16 = 0,
    // BAR-H: 창 상단 chrome 바(터미널 pane 탭 바·도크 뷰 스위처)가 **함께 쓰는** 높이(pt, 폰트 독립).
    // >0이면 그 값이 곧 바 높이다 — terminal cell이 식에 들어가지 않는다. 0이면 셀 파생
    // (`cell_height + 2*tab_bar_pad_y_px`)으로 떨어진다.
    //
    // **여기 있는 이유**: 이 값은 두 chrome이 공유하는 정렬 계약이다. 도크 뷰 스위처는 예전에
    // `DockMetrics.view_switcher_h`(40pt)를, 터미널 탭 바는 셀 파생 높이를 따로 써서 두 바의 아래 경계선이
    // 어긋나 있었다(사용자 보고). 두 소비자가 이 token 하나를 보면 어떤 값이든 정렬은 자동으로 성립한다
    // (docs/agent-session-list-layout.md §2.1.3이 예고한 해법).
    //
    // **셀 항을 `@max`로도 섞지 않는 이유**: 한때 `@max(이값, cell + 2*pad)`였는데, 그러면 terminal 폰트가
    // 도크 기하를 정하게 되어(docs/layering-and-portability.md 금지) `font-scale-rects` fixture가 실제로
    // 깨졌다 — 14pt↔24pt에서 도크 rect가 12px 밀렸고, `tab_bar_pad_y_px`가 backing px 고정이라 1x↔2x 비례도
    // 어긋났다. Ghostty는 폰트 확대가 탭 바를 건드리지 않고 VS Code는 chrome을 `window.zoomLevel`에만 묶는데,
    // 그 관례가 옳았다. 셀 항이 막으려던 것(큰 폰트에서 탭 제목이 바 밖으로 넘침)은 탭 제목이 terminal 셀
    // 그리드로 렌더되기 때문이며, 진짜 해법은 그 텍스트를 chrome 폰트로 옮기는 것이지 chrome을 폰트에
    // 묶는 것이 아니다.
    //
    // **tui=0(셀 파생)은 의도다.** tui는 "터미널 셀 격자에 정렬된 미니멀 chrome"이 정체성이고, 탭 바 배경도
    // 셀 한 행(`paneBarBgCell`)이라 셀에서 떨어진 높이를 주면 배경이 위쪽만 칠해진다. 그 경로에서는 폰트
    // 파생이 결함이 아니라 요구사항이다. 어느 쪽이든 **두 바가 같은 식을 쓰므로 정렬은 유지된다**.
    bar_height_pt: u16 = 0,
};

/// 테두리/선 토큰. tui는 ~2px 띠(reserved-kind). rich에서 radius 등을 추가한다.
pub const Border = struct {
    line_thickness_px: u32 = 2,
};

/// `Tokens.tui`가 받는 resolved 테마 색(config.ResolvedTheme의 chrome-중립 투영). chrome은 config를 import하지
/// 않으므로(경계) 호출자(platform)가 ResolvedTheme에서 이 plain Rgb들만 뽑아 넘긴다. 역할→색 매핑 자체는
/// tui()가 단일 출처로 소유한다. background는 현재 어떤 역할도 안 써서 제외(필요해지면 추가).
pub const ThemeColors = struct {
    foreground: Rgb,
    sidebar_background: Rgb,
    sidebar_foreground: Rgb,
    sidebar_active: Rgb,
    search_match: Rgb,
    search_match_current: Rgb,
    selection: Rgb,
    cursor: Rgb,
    /// 터미널 본문 배경(`ResolvedTheme.background`). `sidebar_background`와 **별개 입력**이다 —
    /// 둘은 테마에서 서로 다른 값이고, 편집기·터미널이 같은 바탕을 공유하려면 이 값이 필요하다.
    terminal_background: Rgb,
    accent: Rgb, // maru accent(테마-구동) — accent_bar 역할이 소비. 호출자가 ResolvedTheme.accent를 넘긴다(null은 resolve가 앰버로 폴백).
    /// 비교 본문의 추가·삭제 색. 호출자가 `syntax_theme.diffFromTheme(theme)`를 넘긴다 — chrome은
    /// 그 파생 규칙(팔레트 bright green/red + 최소 대비)을 몰라도 되고, 웹(CM6)과 네이티브가 **같은
    /// 함수**에서 색을 받는다.
    diff_added: Rgb,
    diff_removed: Rgb,
};

/// 한 테마 = 토큰 묶음. `Tokens.tui(theme)`가 resolved 테마 색에서 15개 ColorRole을 채운다(C0 구현).
/// `Tokens.rich(...)`는 C4. 컴포넌트는 이 값만 소비한다.
pub const Tokens = struct {
    palette: std.EnumArray(ColorRole, Rgb),
    space: Spacing = .{},
    border: Border = .{},

    /// tui 토큰셋: resolved 테마(chrome-중립 ThemeColors)에서 15개 ColorRole을 채운다 — **역할→색 매핑의 단일
    /// 출처**. focus_accent/tab_*/drop_zone은 sidebar_active를 공유하고, divider는 sidebar_background의 명암
    /// 반대 방향으로 파생해 light/dark 모두에서 panel과 다른 RGB를 보장한다. rich도 divider의 출처를 바꾸지 않는다.
    /// muted_fg는 C0에선 sidebar_foreground. initFill 기본값은 15역할을
    /// 전부 명시 set하므로 실제로 안 쓰이지만(foreground로 채워 둠) EnumArray 초기화에 필요하다.
    pub fn tui(theme: ThemeColors) Tokens {
        var palette = std.EnumArray(ColorRole, Rgb).initFill(theme.foreground);
        palette.set(.surface_bg, theme.sidebar_background);
        palette.set(.surface_fg, theme.sidebar_foreground);
        palette.set(.muted_fg, theme.sidebar_foreground);
        palette.set(.inset_bg, insetBg(theme.sidebar_background));
        palette.set(.tab_active_bg, theme.sidebar_active);
        palette.set(.tab_hover_bg, theme.sidebar_active);
        palette.set(.row_hover_bg, theme.sidebar_active);
        palette.set(.divider, dividerBg(theme.sidebar_background));
        palette.set(.focus_accent, theme.sidebar_active);
        palette.set(.drop_zone, theme.sidebar_active);
        palette.set(.search_match, theme.search_match);
        palette.set(.search_match_current, theme.search_match_current);
        palette.set(.selection, theme.selection);
        palette.set(.cursor, theme.cursor);
        palette.set(.accent_bar, theme.accent); // maru accent(테마-구동) — 프리셋별 시그니처 색. config.accent null이면 resolve가 브랜드 앰버(#dda15e)로 폴백. rich가 상속.
        palette.set(.keycap_bg, keycapBg(theme.sidebar_background)); // KH-5: 키캡 배경 = 패널 대비(명암 기준 밝게/어둡게) — tui·rich 공통으로 light·dark 모두 또렷.
        // Error remains role-only at product call sites. A future ThemeColors.error field will
        // replace this mapping once, without changing Card variants or Metal lowering.
        palette.set(.danger_bg, .{ .r = 176, .g = 52, .b = 60 });
        palette.set(.danger_fg, .{ .r = 255, .g = 255, .b = 255 });
        // 고친 것은 **테마 accent**를 쓴다 — 목록에서 가장 흔한 상태이고, 창 전체의 시그니처 색과 같은
        // 계열이어야 도크만 남의 팔레트로 보이지 않는다(VS Code도 M을 노랑/앰버 계열로 둔다).
        palette.set(.git_modified_fg, theme.accent);
        // 새로 생긴 것·없어진 것은 테마에 대응 입력이 없어 보수적 폴백을 둔다(danger_*와 같은 자리).
        // 어두운 배경·밝은 배경 양쪽에서 읽히도록 중간 명도를 고른다.
        palette.set(.git_added_fg, .{ .r = 87, .g = 166, .b = 74 });
        palette.set(.git_deleted_fg, .{ .r = 199, .g = 84, .b = 80 });
        palette.set(.terminal_bg, theme.terminal_background);
        palette.set(.diff_added_bg, theme.diff_added);
        palette.set(.diff_removed_bg, theme.diff_removed);
        return .{ .palette = palette };
    }

    /// rich 토큰셋(C4a): tui 색에서 출발해 tui가 sidebar_active로 **공유**하던 role(focus_accent/drop_zone/
    /// tab_hover_bg)을 분리된 파생색으로 채운다. divider는 panel 대비 semantic role이라 tui 값 그대로 유지하고,
    /// focus_accent 밝게, drop_zone 밝게, tab_hover 어둡게,
    /// muted_fg 더 흐리게. 컴포넌트는 같은 role을 읽으므로 코드 불변(테마=토큰셋 교체). 둥근 모서리(C4b)는 space.corner_radius_px/border_width_px로 분리(tui=0 → 직각·셀 fill).
    /// 그라데이션·shadow는 후속. 색 파생은 lightenRgb/darkenRgb(neutral, config import 없이).
    pub fn rich(theme: ThemeColors) Tokens {
        var tk = tui(theme);
        tk.palette.set(.focus_accent, lightenRgb(theme.sidebar_active, 40));
        tk.palette.set(.drop_zone, lightenRgb(theme.sidebar_active, 16));
        tk.palette.set(.tab_hover_bg, darkenRgb(theme.sidebar_active, 12));
        tk.palette.set(.muted_fg, darkenRgb(theme.sidebar_foreground, 48));
        // C4b: rich 박스 모양 — 둥근 모서리 + 얇은 테두리(tui는 0=직각·셀 fill 유지). 컴포넌트 view가
        // 이 값을 Op.quad에 실어 GPU quad 프리미티브로 lowering된다(같은 코드, 토큰만 다름).
        tk.space.corner_radius_px = 8;
        tk.space.border_width_px = 1;
        // 모달 그림자: 작고 옅게(사용자 피드백 "너무 크고 짙어요") — blur 14→9, offset 6→4, alpha 0x70(≈44%)→0x38(≈22%).
        // 은은히 떠 보이되 무겁지 않게.
        tk.space.shadow_blur_px = 9;
        tk.space.shadow_offset_y_px = 4;
        tk.space.shadow_alpha = 0x38;
        // C4b 모달 패딩: 배경 박스를 텍스트보다 사방 12px 크게 — 팝업 텍스트 주변에 여백(사용자 피드백 "여유").
        tk.space.modal_padding_px = 12;
        // U1: 사이드바 카드 좌측 accent 막대 3px. tui=0(막대 없음). 막대색은 카드별(우클릭 "바: …")이라 platform이
        // 이 폭으로 직접 그리고(활성=기본 앰버·지정 카드=지정색), chrome은 카드 텍스트 좌측 여백만 이 폭으로 예약한다.
        tk.space.accent_bar_width_px = 3;
        // U2: 카드 **텍스트 좌측 들여쓰기** 8px(accent 막대 폭과 함께 텍스트 시작 col을 정한다).
        // **밴드 인셋이 아니다** — 예전엔 이 값으로 밴드까지 사방 인셋해 "떠 있는 카드"로 분리했으나, 클릭
        // 판정(slotAt)이 행 전체라 밴드 밖 8px을 눌러도 카드가 눌렸다. 사용자 결정(2026-07-28)으로 밴드는
        // 행 전체가 됐고(docs/sidebar-agent-list.md §3.2), 이 토큰은 텍스트 여백만 든다.
        tk.space.card_gap_px = 8;
        // SG3: 그룹 안 카드 들여쓰기 16px(≈2ch) — 헤더 아래 카드가 소속을 시각적으로 보이게(브라우저 탭 그룹/VSCode 폴더 관례). docs/sidebar-groups.md §5.
        tk.space.group_indent_px = 16;
        // U-tab: rich 탭 고정 폭 16칸(제목 ~14 + ✕ 2) — 균등 stretch 대신(적으면 빈 영역, 넘치면 가로 스크롤 대상).
        tk.space.tab_width_cols = 16;
        // U-tab: 탭 바 세로 패딩 8px(텍스트 위아래) — 바 높이 = cell + 16, 제목 가운데. Warp식 넉넉한 탭 바(상단 탭바 폴리시).
        tk.space.tab_bar_pad_y_px = 8;
        // U-tab2: 활성 탭 앰버 언더바 3px(하단 하이라인 1~2px보다 굵게) — "활성/포커스 탭" 신호를 또렷하게.
        tk.space.tab_underbar_px = 3;
        // TS2: pill 스타일 세로 inset 4px(바 위아래) — lifted 회색으로 채운 둥근 캡슐이 strip 위에 떠 보이게(Warp식).
        tk.space.tab_pill_inset_px = 4;
        // BAR-H: rich 상단 바 40pt 고정 — 도크 뷰 스위처가 쓰던 `DockMetrics.view_switcher_h`와 **같은 값**을
        // 이제 터미널 탭 바도 함께 본다(두 바의 아래 경계선 정렬). 고정이므로 terminal 폰트를 바꿔도 두 바가
        // 함께 제자리에 있고, 도크 rect가 폰트에 흔들리지 않는다(`font-scale-rects` fixture).
        tk.space.bar_height_pt = 40;
        // KH-5: rich 키캡도 tui와 같은 keycapBg(패널 대비 — 명암 기준)를 쓴다. tui()가 이미 keycap_bg를 그렇게 깔았으므로
        // rich는 override하지 않는다(별도 처리 불필요 — light·dark 모두 또렷). 셀-그리드라 키캡은 fill(셀 배경)이고 둥근
        // GPU quad는 글리프에 가려 못 쓴다(shortcut_hints.view 주석).
        return tk;
    }

    pub fn get(self: *const Tokens, role: ColorRole) Rgb {
        return self.palette.get(role);
    }
};

test "Tokens.tui maps resolved theme colors to the semantic roles" {
    const c = struct {
        fn rgb(r: u8, g: u8, b: u8) Rgb {
            return .{ .r = r, .g = g, .b = b };
        }
    };
    const tk = Tokens.tui(.{
        .foreground = c.rgb(1, 1, 1),
        .sidebar_background = c.rgb(2, 2, 2),
        .sidebar_foreground = c.rgb(3, 3, 3),
        .sidebar_active = c.rgb(4, 4, 4),
        .search_match = c.rgb(5, 5, 5),
        .search_match_current = c.rgb(6, 6, 6),
        .selection = c.rgb(7, 7, 7),
        .cursor = c.rgb(8, 8, 8),
        .terminal_background = c.rgb(8, 8, 8), // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .diff_added = c.rgb(64, 160, 64), // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = c.rgb(176, 64, 64),
        .accent = c.rgb(9, 9, 9),
    });
    try std.testing.expectEqual(c.rgb(2, 2, 2), tk.get(.surface_bg));
    try std.testing.expectEqual(c.rgb(0, 0, 0), tk.get(.inset_bg)); // dark surface는 한 단계 recessed
    try std.testing.expectEqual(c.rgb(3, 3, 3), tk.get(.surface_fg));
    try std.testing.expectEqual(c.rgb(4, 4, 4), tk.get(.focus_accent)); // sidebar_active 공유
    try std.testing.expectEqual(c.rgb(26, 26, 26), tk.get(.divider)); // sidebar_background(2) 대비 파생 = 26
    try std.testing.expectEqual(c.rgb(8, 8, 8), tk.get(.cursor));
}

test "keycap_bg는 패널(surface_bg)과 항상 대비 — 어두우면 밝게·밝으면 어둡게 (리뷰 #1/#2 회귀 가드)" {
    // 단축키 힌트 키캡이 패널색과 같아지면(이전 KH-5의 tui=surface_bg·light 테마 near-white saturate) 키 박스가 사라진다.
    // keycapBg가 명암으로 갈라 light·dark 양쪽, tui·rich 양쪽에서 surface_bg와 다르고 올바른 방향으로 대비함을 고정한다.
    const c = struct {
        fn rgb(r: u8, g: u8, b: u8) Rgb {
            return .{ .r = r, .g = g, .b = b };
        }
        fn theme(bg: Rgb) ThemeColors {
            return .{ .foreground = rgb(128, 128, 128), .sidebar_background = bg, .sidebar_foreground = rgb(180, 180, 180), .sidebar_active = rgb(120, 120, 120), .search_match = rgb(5, 5, 5), .search_match_current = rgb(6, 6, 6), .selection = rgb(7, 7, 7), .cursor = rgb(8, 8, 8), .terminal_background = rgb(10, 10, 10), .accent = rgb(9, 9, 9), .diff_added = rgb(64, 160, 64), .diff_removed = rgb(176, 64, 64) };
        }
    };
    // 어두운 패널 → keycap이 더 밝게(대비).
    inline for ([_]Tokens{ Tokens.tui(c.theme(c.rgb(20, 20, 20))), Tokens.rich(c.theme(c.rgb(20, 20, 20))) }) |tk| {
        try std.testing.expect(!std.meta.eql(tk.get(.keycap_bg), tk.get(.surface_bg))); // 패널과 안 같음(안 사라짐)
        try std.testing.expect(tk.get(.keycap_bg).r > tk.get(.surface_bg).r); // 어두운 패널 → 더 밝게
    }
    // 밝은(near-white) 패널 → keycap이 더 어둡게(단순 lighten이면 near-white로 saturate돼 묻혔다 — 리뷰 #1).
    inline for ([_]Tokens{ Tokens.tui(c.theme(c.rgb(238, 232, 213))), Tokens.rich(c.theme(c.rgb(238, 232, 213))) }) |tk| {
        try std.testing.expect(!std.meta.eql(tk.get(.keycap_bg), tk.get(.surface_bg)));
        try std.testing.expect(tk.get(.keycap_bg).r < tk.get(.surface_bg).r); // 밝은 패널 → 더 어둡게
    }
}

test "inset_bg는 dark/light 테마에서 surface와 반대 방향으로 분리된다" {
    const c = struct {
        fn rgb(r: u8, g: u8, b: u8) Rgb {
            return .{ .r = r, .g = g, .b = b };
        }
        fn theme(bg: Rgb) ThemeColors {
            return .{ .foreground = rgb(128, 128, 128), .sidebar_background = bg, .sidebar_foreground = rgb(180, 180, 180), .sidebar_active = rgb(120, 120, 120), .search_match = rgb(5, 5, 5), .search_match_current = rgb(6, 6, 6), .selection = rgb(7, 7, 7), .cursor = rgb(8, 8, 8), .terminal_background = rgb(10, 10, 10), .accent = rgb(9, 9, 9), .diff_added = rgb(64, 160, 64), .diff_removed = rgb(176, 64, 64) };
        }
    };
    inline for ([_]Tokens{ Tokens.tui(c.theme(c.rgb(40, 40, 40))), Tokens.rich(c.theme(c.rgb(40, 40, 40))) }) |tk| {
        try std.testing.expect(tk.get(.inset_bg).r < tk.get(.surface_bg).r);
    }
    inline for ([_]Tokens{ Tokens.tui(c.theme(c.rgb(220, 220, 220))), Tokens.rich(c.theme(c.rgb(220, 220, 220))) }) |tk| {
        try std.testing.expect(tk.get(.inset_bg).r > tk.get(.surface_bg).r);
    }
}

test "Tokens.rich separates the sidebar_active-shared roles into derived colors (tui 불변)" {
    const c = struct {
        fn rgb(r: u8, g: u8, b: u8) Rgb {
            return .{ .r = r, .g = g, .b = b };
        }
    };
    const theme = ThemeColors{
        .foreground = c.rgb(200, 200, 200),
        .sidebar_background = c.rgb(20, 20, 20),
        .sidebar_foreground = c.rgb(180, 180, 180),
        .sidebar_active = c.rgb(100, 100, 100),
        .search_match = c.rgb(5, 5, 5),
        .search_match_current = c.rgb(6, 6, 6),
        .selection = c.rgb(7, 7, 7),
        .cursor = c.rgb(8, 8, 8),
        .terminal_background = c.rgb(8, 8, 8), // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .diff_added = c.rgb(64, 160, 64), // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = c.rgb(176, 64, 64),
        .accent = c.rgb(9, 9, 9),
    };
    const t = Tokens.tui(theme);
    const r = Tokens.rich(theme);
    // tui: focus_accent/drop_zone/tab_hover_bg = sidebar_active(공유), divider = panel 대비 파생. rich: interactive role만 분리 파생.
    try std.testing.expectEqual(c.rgb(44, 44, 44), t.get(.divider)); // sidebar_background(20) 대비 파생 = 44
    try std.testing.expectEqual(c.rgb(44, 44, 44), r.get(.divider)); // rich도 panel 대비 규칙 유지
    try std.testing.expectEqual(c.rgb(140, 140, 140), r.get(.focus_accent)); // lighten 40
    try std.testing.expectEqual(c.rgb(116, 116, 116), r.get(.drop_zone)); // lighten 16
    try std.testing.expectEqual(c.rgb(88, 88, 88), r.get(.tab_hover_bg)); // darken 12
    try std.testing.expectEqual(c.rgb(132, 132, 132), r.get(.muted_fg)); // sidebar_fg(180) darken 48
    // 분리됨: divider != focus_accent != tab_active_bg(=sidebar_active 그대로).
    try std.testing.expectEqual(c.rgb(100, 100, 100), r.get(.tab_active_bg)); // 활성은 원색 유지
    try std.testing.expect(!std.meta.eql(r.get(.divider), r.get(.focus_accent)));
    // rich가 안 건드리는 role은 tui와 동일.
    try std.testing.expectEqual(t.get(.surface_bg), r.get(.surface_bg));
    try std.testing.expectEqual(t.get(.cursor), r.get(.cursor));
    try std.testing.expectEqual(t.get(.search_match), r.get(.search_match));
}

test "divider is always distinct from the panel in tui and rich, including the prior active collision" {
    const c = struct {
        fn rgb(value: u8) Rgb {
            return .{ .r = value, .g = value, .b = value };
        }
        fn theme(background: u8, active: u8) ThemeColors {
            return .{
                .foreground = rgb(220),
                .sidebar_background = rgb(background),
                .sidebar_foreground = rgb(180),
                .sidebar_active = rgb(active),
                .search_match = rgb(5),
                .search_match_current = rgb(6),
                .selection = rgb(7),
                .cursor = rgb(8),
                .terminal_background = rgb(8), // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
                .diff_added = rgb(96),
                .diff_removed = rgb(112),
                .accent = rgb(9),
            };
        }
    };
    inline for ([_]ThemeColors{ c.theme(40, 64), c.theme(240, 180), c.theme(0, 255), c.theme(255, 0) }) |theme| {
        const tui = Tokens.tui(theme);
        const rich = Tokens.rich(theme);
        try std.testing.expect(!std.meta.eql(tui.get(.divider), tui.get(.surface_bg)));
        try std.testing.expect(!std.meta.eql(rich.get(.divider), rich.get(.surface_bg)));
        try std.testing.expectEqual(tui.get(.divider), rich.get(.divider));
    }
}

test "divider keeps the documented 24-channel separation away from gamut endpoints" {
    const theme = ThemeColors{
        .foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_background = .{ .r = 40, .g = 40, .b = 40 },
        .sidebar_foreground = .{ .r = 180, .g = 180, .b = 180 },
        .sidebar_active = .{ .r = 64, .g = 64, .b = 64 },
        .search_match = .{ .r = 5, .g = 5, .b = 5 },
        .search_match_current = .{ .r = 6, .g = 6, .b = 6 },
        .selection = .{ .r = 7, .g = 7, .b = 7 },
        .cursor = .{ .r = 8, .g = 8, .b = 8 },
        .terminal_background = .{ .r = 8, .g = 8, .b = 8 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .diff_added = .{ .r = 64, .g = 160, .b = 64 },
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .accent = .{ .r = 9, .g = 9, .b = 9 },
    };
    inline for ([_]Tokens{ Tokens.tui(theme), Tokens.rich(theme) }) |tk| {
        try std.testing.expectEqual(@as(u8, 64), tk.get(.divider).r);
        try std.testing.expectEqual(@as(u8, 64), tk.get(.divider).g);
        try std.testing.expectEqual(@as(u8, 64), tk.get(.divider).b);
    }
}

test "Tokens.rich sets box-shape tokens (radius/border) while tui keeps 0" {
    const theme = ThemeColors{
        .foreground = .{ .r = 200, .g = 200, .b = 200 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 180, .g = 180, .b = 180 },
        .sidebar_active = .{ .r = 100, .g = 100, .b = 100 },
        .search_match = .{ .r = 5, .g = 5, .b = 5 },
        .search_match_current = .{ .r = 6, .g = 6, .b = 6 },
        .selection = .{ .r = 7, .g = 7, .b = 7 },
        .cursor = .{ .r = 8, .g = 8, .b = 8 },
        .terminal_background = .{ .r = 8, .g = 8, .b = 8 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .diff_added = .{ .r = 64, .g = 160, .b = 64 },
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .accent = .{ .r = 9, .g = 9, .b = 9 },
    };
    const t = Tokens.tui(theme);
    const r = Tokens.rich(theme);
    // tui: 모양 토큰 0(직각·테두리 없음 → lowering이 셀 fill 유지). rich: >0(둥근·테두리 → GPU quad).
    try std.testing.expectEqual(@as(u16, 0), t.space.corner_radius_px);
    try std.testing.expectEqual(@as(u16, 0), t.space.border_width_px);
    try std.testing.expect(r.space.corner_radius_px > 0);
    try std.testing.expect(r.space.border_width_px > 0);
    // 비-모양 space(슬롯 높이 비율)는 tui·rich 동일 — 모양만 분리한다.
    try std.testing.expectEqual(t.space.sidebar_slot_height_ratio_milli, r.space.sidebar_slot_height_ratio_milli);
}

test "statusBarBg: 사이드바와도 터미널과도 구분된다(다크·라이트 모두)" {
    const cases = [_]struct { name: []const u8, term: Rgb, side: Rgb }{
        .{ .name = "다크 기본", .term = .{ .r = 40, .g = 44, .b = 52 }, .side = .{ .r = 64, .g = 68, .b = 76 } },
        .{ .name = "Solarized 라이트", .term = .{ .r = 253, .g = 246, .b = 227 }, .side = .{ .r = 238, .g = 232, .b = 213 } },
        .{ .name = "Catppuccin 라이트", .term = .{ .r = 239, .g = 241, .b = 245 }, .side = .{ .r = 230, .g = 233, .b = 239 } },
    };
    for (cases) |c| {
        const bar = statusBarBg(c.side, c.term);
        // **둘 다에서 떨어져야** 한다. 하나라도 붙으면 사용자가 경계를 못 본다.
        try std.testing.expect(channelDistance(bar, c.side) >= 10);
        try std.testing.expect(channelDistance(bar, c.term) >= 10);
    }
}

test "statusBarBorder: 위(터미널)·아래(바) 양쪽과 구분되고 세 색이 한 방향으로 벌어진다" {
    const cases = [_]struct { name: []const u8, term: Rgb, side: Rgb }{
        .{ .name = "다크 기본", .term = .{ .r = 40, .g = 44, .b = 52 }, .side = .{ .r = 64, .g = 68, .b = 76 } },
        .{ .name = "Solarized 라이트", .term = .{ .r = 253, .g = 246, .b = 227 }, .side = .{ .r = 238, .g = 232, .b = 213 } },
        .{ .name = "Catppuccin 라이트", .term = .{ .r = 239, .g = 241, .b = 245 }, .side = .{ .r = 230, .g = 233, .b = 239 } },
    };
    for (cases) |c| {
        const bar = statusBarBg(c.side, c.term);
        const line = statusBarBorder(c.side, c.term);
        // 선이 바에 묻히면 안 그린 것과 같고, 터미널에 묻히면 경계가 아니라 얼룩으로 보인다.
        try std.testing.expect(channelDistance(line, bar) >= 10);
        try std.testing.expect(channelDistance(line, c.term) >= 10);
        // 터미널 → 바 → 선이 **같은 방향**으로 간다(단조). 방향이 꺾이면 선이 터미널 쪽으로 되돌아가
        // 대비가 우연에 기댄다.
        const lt = testLum(c.term);
        const lb = testLum(bar);
        const ll = testLum(line);
        if (lb >= lt) try std.testing.expect(ll > lb) else try std.testing.expect(ll < lb);
    }
}

/// 테스트용 명암 — 토큰 내부와 같은 가중치.
fn testLum(c: Rgb) u16 {
    return (@as(u16, c.r) * 77 + @as(u16, c.g) * 150 + @as(u16, c.b) * 29) >> 8;
}

/// 채널 평균 거리 — 색 비교용 테스트 도우미.
fn channelDistance(a: Rgb, b: Rgb) u16 {
    const dr = if (a.r > b.r) a.r - b.r else b.r - a.r;
    const dg = if (a.g > b.g) a.g - b.g else b.g - a.g;
    const db = if (a.b > b.b) a.b - b.b else b.b - a.b;
    return (@as(u16, dr) + @as(u16, dg) + @as(u16, db)) / 3;
}

test "git 상태 역할: 셋이 서로 다르고, 고친 것은 테마 accent를 따라간다" {
    // 소스 컨트롤 목록이 `M`·`A`/`U`·`D`를 색으로도 가른다(글자와 **함께** — 색만으로 구분하지 않는다).
    // 셋이 같은 값으로 접히면 그 보조 신호가 사라지므로 역할 분리 자체를 고정한다.
    const theme: ThemeColors = .{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 200, .g = 200, .b = 200 },
        .sidebar_background = .{ .r = 30, .g = 30, .b = 30 },
        .sidebar_foreground = .{ .r = 200, .g = 200, .b = 200 },
        .sidebar_active = .{ .r = 60, .g = 60, .b = 60 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 13, .g = 14, .b = 15 },
        .accent = .{ .r = 221, .g = 161, .b = 94 },
    };
    const tk = Tokens.tui(theme);
    const modified = tk.get(.git_modified_fg);
    const added = tk.get(.git_added_fg);
    const deleted = tk.get(.git_deleted_fg);
    try std.testing.expectEqual(theme.accent, modified); // 창 시그니처 색을 따라간다
    try std.testing.expect(!std.meta.eql(added, deleted));
    try std.testing.expect(!std.meta.eql(added, modified));
    // rich도 같은 값을 물려받는다(룩이 달라도 상태 색의 의미는 같다).
    const rich_tokens = Tokens.rich(theme);
    try std.testing.expectEqual(modified, rich_tokens.get(.git_modified_fg));
    try std.testing.expectEqual(added, rich_tokens.get(.git_added_fg));
}

test "비교 밴드 색은 자기 역할에만 산다 — 다른 역할을 덮지 않는다" {
    // 새 역할을 더하면서 팔레트 채우기 한 줄을 잘못 쓰면(복사·붙여넣기) 다른 역할이 조용히 같은 색이
    // 된다 — 화면에서는 "왜 이 칩이 초록이지?"로만 보인다. 두 색을 **명백히 다른 값**으로 넣고,
    // 나머지 역할이 그 값을 안 받는지 본다.
    const c = struct {
        fn rgb(r: u8, g: u8, b: u8) Rgb {
            return .{ .r = r, .g = g, .b = b };
        }
    };
    const theme: ThemeColors = .{
        .foreground = c.rgb(200, 200, 200),
        .sidebar_background = c.rgb(30, 30, 30),
        .sidebar_foreground = c.rgb(200, 200, 200),
        .sidebar_active = c.rgb(60, 60, 60),
        .search_match = c.rgb(70, 70, 70),
        .search_match_current = c.rgb(80, 80, 80),
        .selection = c.rgb(90, 90, 90),
        .cursor = c.rgb(100, 100, 100),
        .terminal_background = c.rgb(10, 10, 10),
        .accent = c.rgb(110, 110, 110),
        .diff_added = c.rgb(1, 250, 2), // 팔레트 어디에도 없는 값
        .diff_removed = c.rgb(250, 1, 2),
    };
    inline for ([_]Tokens{ Tokens.tui(theme), Tokens.rich(theme) }) |tk| {
        try std.testing.expectEqual(theme.diff_added, tk.get(.diff_added_bg));
        try std.testing.expectEqual(theme.diff_removed, tk.get(.diff_removed_bg));
        inline for (@typeInfo(ColorRole).@"enum".fields) |f| {
            const role: ColorRole = @enumFromInt(f.value);
            if (role == .diff_added_bg or role == .diff_removed_bg) continue;
            try std.testing.expect(!std.meta.eql(tk.get(role), theme.diff_added));
            try std.testing.expect(!std.meta.eql(tk.get(role), theme.diff_removed));
        }
    }
}
