//! 편집기 뷰 한 프레임을 조립한다 — 배경·본문·gutter·스크롤바를 **한 번의 호출로**
//! ([native-editor-visual-mapping.md](../../../../docs/native-editor-visual-mapping.md) §4).
//!
//! **왜 조립이 따로 있는가.** 네 컴포넌트는 각자 순수하지만 **순서와 저장소 분배가 계약이다**:
//! 배경이 맨 앞이어야 글자를 안 덮고(§4.1b), 본문이 gutter보다 먼저 돌아야 랩된 줄의 시각 배치를
//! 정하며(§4 세로 축), 그 순서 때문에 gutter 몫을 **미리 떼어 두지 않으면** 긴 줄 하나가 저장소를
//! 다 써서 줄 번호가 통째로 사라진다(적대적 검증이 실제로 잡았다).
//!
//! 그 규칙이 호출자마다 복제되면 **Chrome Lab 캡처가 제품을 예고하지 못한다** — 둘이 조금씩 다른
//! 그림을 그리게 되고, 골든이 지키는 것은 Lab 쪽뿐이다. 그래서 조립을 여기 한 곳에 두고 Lab과
//! 제품이 같은 함수를 부른다.
//!
//! **할당하지 않는다.** L3 컴포넌트 계약대로 저장소는 호출자가 준다(`Scratch`).

const std = @import("std");
const draw = @import("../../draw.zig");
const tokens = @import("../../tokens.zig");
pub const content = @import("content.zig");
const geometry = @import("geometry.zig");
const gutter = @import("gutter.zig");
const scrollbar = @import("scrollbar.zig");
const surface = @import("surface.zig");
const visual_map = @import("../../ui/visual_map.zig");
const scroll_area = @import("../../ui/scroll_area.zig");

/// 내용(gutter·본문·스크롤바)이 뷰 사각에서 안쪽으로 들어가는 여백(px).
///
/// **배경은 이 여백을 쓰지 않는다** — 배경은 뷰 사각 전체를 덮고(§4.1b "뷰포트 전체를 덮는다") 내용만
/// 들어간다. 그래서 pane 가장자리까지 색이 차면서도 글자가 경계에 붙지 않는다.
///
/// **왜 필요한가(2026-08-14 실측).** 활성 pane의 **포커스 테두리**가 pane body 사각에 2px로 그려지는데
/// 그것이 **셀 위 층**(over)이라 여백이 없으면 첫 글자 행의 윗부분과 스크롤바를 덮는다. 터미널은 창
/// padding이 그 자리를 비워 줘서 겪지 않던 문제이고, 편집기는 창 padding을 쓰지 않기로 했으므로
/// (visual-mapping §4.1b) **뷰가 자기 여백을 갖는다.** 값은 테두리 두께(2px)보다 커야 한다.
pub const content_inset_px: u32 = 4;

/// 배경이 덮을 사각에서 **내용이 설 사각**을 뽑는다. 호출자가 열 수·스크롤바 gutter를 이 사각으로
/// 계산해야 스크롤바가 뷰 밖으로 밀려나지 않는다 — 제품과 Chrome Lab이 같은 함수를 쓴다.
pub fn contentRect(rect: draw.Rect) draw.Rect {
    const e: u16 = @intCast(content_inset_px);
    return rect.inset(.{ .left = e, .right = e, .top = e, .bottom = e });
}

/// 가로로 밀 수 있는 **최대 열**. §3.8의 "초장문·극단 입력에서 기능을 줄인다"를 이 축에 적용한 값이다.
///
/// **왜 상한이 필요한가**: 렌더는 화면 시작 열까지 줄을 지나며 버리는데(`content.expandTabs`), 그
/// 비용이 화면 폭이 아니라 **밀린 거리**에 비례한다. 20만 자 한 줄에서 60,000열까지 밀면 고치기 전
/// 프레임당 498ms였다(적대적 검증 2026-08-16 실측, Debug/arm64). 출력 가능한 ASCII를 싸게 건너뛰어
/// 13.6ms까지 줄였지만 **여전히 거리에 비례한다** — 상수 배 개선이지 구조가 바뀐 것이 아니다.
///
/// **업계도 대체로 상한을 둔다**: Monaco는 `stopRenderingLineAfter`(기본 10,000자)를 넘으면 렌더를
/// 멈추고, Emacs는 `so-long` 모드로 기능을 끄며, Vim은 `synmaxcol`을 둔다. "긴 줄을 제대로 처리한다"가
/// 아니라 "긴 줄에서는 줄인다"가 흔한 답이다.
///
/// **구조적 해결은 열↔byte 인덱스다**(Zed·xi 계열의 rope + 노드별 집계). 그것이 들어오면 이 상한은
/// 없어진다 — 그 자리는 [visual-mapping §4.1c](../../../../docs/native-editor-visual-mapping.md)가
/// 소유하고, 폭 합 캐시와 같은 슬라이스에 있다.
/// 가로 스크롤바가 서는가. **본문 높이를 정하기 전에** 물어야 한다 — 막대가 자리를 먹기 때문이다
/// (§4.1a: *"랩이 켜지면 가로 범위가 0이 되어 사라지고, 그때 본문 높이가 그만큼 늘어난다"*).
///
/// 규칙을 여기 한 곳에 둔다. 호출자가 높이를 줄일 때와 `build`가 막대를 그릴 때 **같은 답**이어야
/// 하는데, 두 곳에 각자 적으면 한쪽만 고쳐져 막대가 자리 없이 그려지거나(마지막 줄을 덮는다) 자리만
/// 비고 막대가 없다.
pub fn showsHorizontalBar(wrap: bool, content_max_cols: ?u32, view_cols: u16) bool {
    if (wrap) return false; // 랩은 넘칠 것을 없앤다 — 축 자체가 없다
    const max_cols = content_max_cols orelse return false; // 아직 안 셌다
    return max_cols > view_cols;
}

/// 랩 계수를 **한 프레임에 몇 줄까지** 진행할지(§2.1 점진 계수). 줄마다 독립이라 나눠 셀 수 있고,
/// 그래서 이 작업은 워커가 아니라 메인에 남는다.
///
/// 값의 근거: 실측으로 랩 켠 줄 하나가 약 3.1µs다(2만 줄 62ms, ReleaseFast). 2,048줄이면 프레임당
/// 약 6.4ms로 60fps 예산(16.7ms) 안에 들어오고, 2만 줄 문서가 10프레임(약 167ms)에 정확해진다.
/// 더 잘게 쪼개면 정확해지기까지 더 오래 걸리고, 크게 잡으면 한 프레임이 예산을 넘는다.
pub const count_chunk_lines: usize = 2048;

pub const max_first_col: u16 = 10_000;

/// 가장 긴 줄을 셀 때 **여기까지만 센다**. `max_first_col`을 넘는 부분은 어차피 못 가므로 세는 것이
/// 낭비다 — 5MB짜리 한 줄(minified)에서 첫 가로 휠이 **149ms**였다(적대적 검증 2026-08-16 실측).
///
/// 여유분 4,096은 **화면에 보일 수 있는 최대 열**을 넉넉히 잡은 값이다. 그래야 "상한에 걸렸다"는
/// 사실만으로 `max_cols - visible >= max_first_col`이 성립해, 창 크기가 나중에 바뀌어도 갈 수 있는
/// 거리가 줄지 않는다(8K 폭 화면에 4px 셀이어도 3,840열이다).
pub const max_cols_count_limit: u32 = @as(u32, max_first_col) + 4096;

/// 탭 한 칸이 몇 열인가. **여기가 단일 출처다** — 제품은 아직 config로 이 값을 안 받고 이 기본을
/// 그대로 쓰는데, 가로 스크롤 상한을 세는 쪽이 다른 값을 쓰면 가장 긴 줄의 끝에 못 닿는다.
pub const default_tab_width: u8 = 4;

pub const Props = struct {
    /// **문서 전체의 논리 줄들.** 화면 몫만 잘라 넘기면 안 된다 — 스크롤바 길이가 문서 전체의
    /// 시각 행 수에서 나오는데(§4.1a), 잘린 배열로는 그것을 셀 수 없어 막대가 실제보다 짧아진다
    /// (골든 `editor-scrollbar-wrapped-range`가 그 회귀를 잡았다).
    ///
    /// 큰 문서에서 이 계수가 비싸지면 `total_visual_rows`로 미리 센 값을 넘겨 건너뛴다.
    lines: []const []const u8,
    /// **줄별 구문 강조 색 구간**(§5.3 1층). `lines`와 **같은 축**으로 색인한다 — `i`번째 원소가
    /// `lines[i]`의 색이다.
    ///
    /// **비어 있어도 되고, `lines`보다 짧아도 된다.** 없는 줄은 무색으로 그린다(§5) — 파싱이
    /// 아직 안 끝났거나 grammar가 없는 문서가 그렇고, 그때 화면은 색만 없지 멀쩡하다. 배열
    /// 길이를 맞추라고 요구하면 호출자가 빈 배열을 만들어 채우는 일이 생긴다.
    ///
    /// 열 기준이며 오름차순·비겹침이라는 계약은 `content.Row.colors`가 소유한다.
    line_colors: []const []const content.ColorSpan = &.{},
    /// 화면 맨 위에 올 논리 줄(0-based). 여기서부터 그리고, 줄 번호도 여기서 시작한다.
    first_line: usize,
    /// 첫 줄의 몇 번째 **조각**부터 그리는가. 랩이 켜졌을 때 화면이 줄 중간에서 시작하는 상태다
    /// (§4 — 세로 스크롤이 시각 행 단위다). 범위를 넘으면 `content`가 0으로 접는다.
    first_piece: u32 = 0,
    /// 가로 스크롤 오프셋(열). 랩이 켜져 있으면 의미가 없다.
    first_col: u16 = 0,
    /// 문서에서 **가장 긴 줄**의 표시 폭(열). 가로 스크롤바가 이 값으로 막대 길이를 정한다.
    ///
    /// **보이는 줄이 아니라 문서 전체다** — 보이는 줄만 보면 세로로 굴릴 때마다 막대 길이가
    /// 출렁인다(가로 스크롤 상한이 같은 이유로 문서 전체를 본다). `null`이면 **가로 막대를 그리지
    /// 않는다**: 아직 세지 않았거나, 이 축을 안 쓰는 호출자(비교 뷰)다.
    content_max_cols: ?u32 = null,
    /// 문서 전체의 논리 줄 수. 보통 `lines.len`이지만, 줄 번호 자릿수(gutter 폭)를 문서 전체
    /// 기준으로 잡아야 하므로 따로 받는다.
    total_lines: usize,
    /// **이 줄이 추가인가 삭제인가**(비교 본문). 논리 줄 인덱스로 읽는다. `null`이면 밴드를 그리지
    /// 않는다 — 문서 편집기는 이 축이 없다.
    row_bands: ?[]const RowBand = null,
    /// 논리 줄마다 바뀐 글자 범위(없으면 빈 슬라이스). `row_bands`와 같은 인덱스 축이다.
    row_marks: ?[]const []const Mark = null,
    /// 논리 줄마다의 **선택 범위**(§4.1g). `row_marks`와 같은 축이고, diff가 아니어도 선다.
    /// 선택은 문서 전체 offset인데 그것을 줄로 자르는 것은 제품의 일이다 — 컴포넌트는 어느 줄이
    /// 문서 몇 번째 byte에서 시작하는지 모른다.
    selection_marks: ?[]const []const Mark = null,
    /// **검색 결과**(§5.1). `selection_marks`와 같은 축이고, 한 줄에 여러 개가 설 수 있다 —
    /// 선택은 이어진 하나라 줄마다 최대 하나였지만 매치는 그렇지 않다.
    ///
    /// **축 이름 주의**: 여기서 "줄"은 **이 컴포넌트가 받은 `lines` 배열의 첨자**다. 제품이
    /// 접힘을 켜면 그 배열은 `editor_visible_lines`(보이는 줄)이므로 제품 쪽 주석은 같은 값을
    /// **"보이는 줄 축"**이라 부른다. 컴포넌트는 접힘을 모르니 그 이름을 쓸 수 없을 뿐 **같은
    /// 것**이다 — §4.1g가 이 두 이름을 섞어 여러 번 틀린 이력이 있어 여기 적어 둔다.
    search_marks: ?[]const []const Mark = null,
    /// 그 중 **지금 보고 있는 매치**. `search_marks` 안에 이미 들어 있고 이것은 어느 것인지만
    /// 가리킨다 — 따로 담으면 두 목록이 어긋날 수 있고, 그러면 색이 둘인 매치나 색이 없는 매치가 난다.
    search_current: ?CurrentMatch = null,
    /// **커서 자리** — 보이는 줄마다 그 줄 안 byte offset들(오름차순).
    ///
    /// `selection_marks`와 **같은 축·같은 모양**이다(줄별, 줄 안 offset). 길이 0인 위치라 마크로
    /// 표현할 수 없어 따로 든다 — 마크의 `len`을 0으로 두면 `paintRowMarks`가 그리는 사각이
    /// 폭 0이 되어 보이지 않는다.
    ///
    /// **byte로 받고 열은 여기서 구한다.** 제품이 픽셀을 계산해 넘기면 hit-test와 다른 산술이
    /// 두 곳에 생긴다 — §5.4가 *"view와 hitTest가 하나의 픽셀-레이아웃 소스를 공유한다"*를 MUST로
    /// 둔 자리이고, 이 슬라이스가 실제로 그 두 번째 출처를 지었다가 걷어냈다.
    carets: ?[]const []const u32 = null,
    /// 지금 커서를 그릴 순간인가(blink). 세션의 `blink_visible`이 그대로 온다 —
    /// rename·검색 caret이 쓰는 값과 같은 것이라 **깜빡임 위상이 화면 안에서 하나다.**
    caret_visible: bool = true,
    /// **줄 번호를 밖에서 준다**(논리 줄 인덱스로 읽는 표, `null` 항목 = 번호 없음). diff 본문이
    /// 쓴다 — 좌우가 나란히 서지만 번호는 각자 문서의 것이고, 짝을 맞추려 넣은 빈 행에는 번호가
    /// 없다. `null`이면 지금까지대로 `first_line + 줄 + 1`이다.
    line_numbers: ?[]const ?u32 = null,
    /// 논리 줄마다의 **접힘 표식**(줄 인덱스로 읽는다). `null`이면 접힘 칸이 빈다 — 접힘을 모르는
    /// 호출자(비교 뷰 등)는 그대로 두면 된다.
    folds: ?[]const gutter.Fold = null,
    /// 문서 전체의 **시각 행** 수를 이미 알고 있으면 여기 넣는다. `null`이면 `lines`를 훑어 센다 —
    /// 줄당 전개가 들어가므로 큰 문서에서는 호출자가 캐시한 값을 주는 편이 낫다(§2 L2 캐시).
    ///
    /// **이것만 주면 막대 위치는 여전히 여기서 센다**(화면 맨 위 줄까지의 접두 합계). 그 계수까지
    /// 건너뛰려면 `first_visual_row`를 함께 준다 — 하나만 주고 나머지를 논리 줄로 대신하면 랩된
    /// 문서에서 막대가 틀린 자리에 선다(리뷰가 그 상태를 잡았다).
    total_visual_rows: ?u32 = null,
    /// 화면 맨 위 줄까지의 **시각 행** 수. `null`이면 여기서 센다.
    first_visual_row: ?u32 = null,
    /// 줄별 시각 행 수를 프레임 사이에 살려 두는 캐시(`RowCache`). 주면 조건이 같은 다음 프레임부터
    /// 계수를 건너뛰고, 조건이 갈리면 **여기서 다시 채운다** — 호출자는 저장소만 대면 된다.
    ///
    /// `total_visual_rows`·`first_visual_row`를 직접 준 경우 그쪽이 이긴다(호출자가 이미 아는 값이다).
    row_cache: ?*RowCache = null,
    /// 그릴 수 있는 시각 행 수(뷰포트 높이 / 셀 높이).
    visible_rows: u16,
    wrap: bool,
    /// **기본값이 없다 — 호출자가 반드시 넘긴다.** 기본값을 두면 그것이 두 번째 출처가 되고, 안 넘긴
    /// 호출자가 조용히 그리로 떨어진다. 13차 적대적 검증이 그것을 잡았다: `diff_frame`의
    /// `Props`·`Shared`에서만 기본값을 지웠더니 Chrome Lab의 **본문 렌더**가 이쪽 기본값으로
    /// 떨어졌다.
    ///
    /// **그 둘이 갈릴 수 있었다고 적었던 것은 거짓이다**(14차). Lab의 가로 막대 상한도 `Props`
    /// 기본값도 결국 `default_tab_width` 하나에서 오므로 정의상 함께 움직인다. 실제로 갈릴 수
    /// 있었던 자리는 Lab이 gutter 행 수에 박아 둔 **리터럴 `4`** 하나였고 그것은 따로 고쳤다.
    /// 기본값을 지우는 이유는 그 사고가 아니라 원칙이다 — 누락을 컴파일 에러로 만든다.
    tab_width: u8,

    /// **내용**(gutter·본문·스크롤바)이 설 사각. 호출자가 `contentRect`로 뽑아 넘긴다.
    rect: draw.Rect,
    /// 배경이 덮을 사각(§4.1b "뷰포트 전체"). `null`이면 `rect`와 같다 — 여백 없이 그리는 호출자용.
    background_rect: ?draw.Rect = null,
    cell_w_px: u16,
    cell_h_px: u16,
    font_px: u16,
    /// 본문이 쓸 수 있는 열 수. 스크롤바 gutter를 뺀 값을 호출자가 준다.
    total_cols: u16,
    /// 스크롤바가 설 오른쪽 여백(px).
    scrollbar_gutter_px: u32,
    metrics: scroll_area.ScrollbarMetrics,
};

/// 바뀐 **글자** 범위(그 줄 안 바이트). `session/editor/intraline.zig`가 계산하고, 무엇이 한 글자인지는
/// 그 호출자가 cluster 경계로 정한다 — 여기서는 이미 정해진 범위를 열로 옮겨 칠하기만 한다.
pub const Mark = struct { start: u32, len: u32 };

/// 지금 네비게이션이 가리키는 검색 결과 — 줄(`search_marks`와 **같은 축**)과 그 줄 안 시작 byte.
///
/// `Mark`를 쓰지 않는 이유: 길이는 이미 `search_marks` 쪽에 있고, 여기 또 두면 둘이 다를 수 있다.
pub const CurrentMatch = struct { line: u32, start: u32 };

/// 비교 본문에서 한 줄이 무엇인가. **`none`은 색을 칠하지 않는다** — context와, 짝을 맞추려 넣은 빈
/// 행이 여기 든다(빈 행에 색을 칠하면 "그 자리에 무언가 있다"고 말하게 된다).
pub const RowBand = enum { none, added, removed };

/// 줄 배경의 세기. **알파로 얹는다** — 배경색을 가정하면 한쪽 테마에서 글자가 안 읽힌다
/// (CM6 `diff-theme.ts`가 같은 이유로 16%를 썼다. 여기 값은 그 관측을 옮긴 것이다).
pub const band_alpha: u8 = 41; // ≈16%
/// **선택**의 세기. 캡처로 정했다 — 30%로 두니 어두운 테마에서 배경(20,20,20)과 선택 띠가
/// (31,41,53)이라 **거의 구별되지 않았다**. 선택은 "지금 무엇을 골랐는가"를 말하는 것이므로 diff의
/// 바뀐 글자(`mark_alpha` 34%)보다 진해도 된다 — 그쪽은 이미 깔린 줄 배경 **위에** 얹는 강조라
/// 기준이 다르다. 글자가 읽히는 선은 지킨다.
pub const selection_alpha: u8 = 115; // ≈45%
/// **바뀐 글자**의 세기(§3.5 "줄 전체에 옅은 색을 깔고 바뀐 글자만 진하게"). 줄 배경 위에 한 겹 더
/// 얹으므로 그 차이가 곧 "이 글자가 달라졌다"는 신호다(CM6 `diff-theme.ts`가 34%를 쓴 그 자리다).
pub const mark_alpha: u8 = 87; // ≈34%

/// 검색 결과 강조. 색 자체가 검색용(`search_match`)이라 선택처럼 진하게 얹지 않아도 눈에 띄고,
/// **글자를 읽을 수 있어야** 다음 매치인지 판단할 수 있다 — 그래서 선택(45%)보다 옅다.
pub const search_alpha: u8 = 92; // ≈36%
/// 현재 매치는 **더 진하다**. 같은 세기면 여럿 중 어느 것이 현재인지 색상만으로 구분해야 하는데,
/// 테마에 따라 두 색이 가까울 수 있다(사용자 테마는 우리가 못 고른다).
pub const search_current_alpha: u8 = 153; // ≈60%

/// 검색 강조가 남겨 두어야 하는 op 수 — 세로·가로 스크롤바가 각각 하나씩 쓴다
/// (`scrollbar.build`/`buildHorizontal`의 `.ops = 1`). 자세한 이유는 `build`의 호출부에 있다.
pub const scrollbar_reserve_ops: usize = 2;
/// 좌측 색 띠의 세기와 두께. **색만으로 구분하지 않기 위한 장치다**(editor-surface-dock.md §3.5) —
/// 색각 이상에서 초록/빨강이 같아 보여도 띠의 유무와 위치가 남는다.
pub const strip_alpha: u8 = 153; // ≈60%
pub const strip_width_px: u16 = 2;

/// 호출자 소유 저장소. **어느 것이든 모자라면 그 부분이 잘릴 뿐 죽지 않는다** — 화면이 조금 빈
/// 것이 크래시보다 낫고, 그 상태는 골든이 즉시 잡는다.
pub const Scratch = struct {
    ops: []draw.Op,
    text_bytes: []u8,
    runs: []draw.Run,
    /// `lines`를 `content.Row`로 옮겨 담는 자리.
    content_rows: []content.Row,
    /// 본문이 정한 시각 배치. gutter가 이것을 그대로 따른다.
    visual_rows: []visual_map.VisualRow,
    gutter_rows: []gutter.Row,
    /// 스크롤바 길이를 내려면 문서 줄마다 시각 행 수를 세야 한다(§4.1a).
    row_counts: []u32,
    /// 그 계수에 쓰는 탭 전개 버퍼. 줄마다 재사용한다.
    count_scratch: []u8,
};

/// 줄마다의 시각 행 수를 **프레임 사이에 살려 두는** 호출자 소유 캐시.
///
/// **왜 필요한가.** 스크롤바 길이는 문서 전체의 시각 행 수에서 나오는데(§4.1a) 그 계수가 문서
/// 크기에 비례한다. 캐시가 없으면 정지 상태에서도 **매 프레임** 전 문서를 다시 접어 본다 — 실측으로
/// 4,000줄 랩 문서가 프레임당 12.9ms였다(ReleaseFast, 2026-08-18). 60fps 예산의 76%다.
///
/// **왜 접두합인가.** 총합만 캐시하면 막대 **위치**(화면 맨 위 줄까지의 시각 행 수)를 여전히 매
/// 프레임 세야 하고, 문서 끝으로 내려갈수록 그 비용이 문서 전체에 수렴한다. `prefix[i]`가 0..i 줄의
/// 합이면 총합도 위치도 조회 하나다.
///
/// **저장소는 호출자가 준다**(`Scratch`와 같은 규율) — 컴포넌트는 할당하지 않는다. 자리가 모자라면
/// 캐시를 쓰지 않고 예전 경로로 내려갈 뿐 죽지 않는다.
pub const RowCache = struct {
    /// `prefix[i]` = 0번 줄부터 `i-1`번 줄까지의 시각 행 합(`prefix[0] = 0`). 유효하려면 길이가
    /// `lines.len + 1` 이상이어야 한다.
    prefix: []u32,
    /// 아래 다섯이 **전부** 같을 때만 위 접두합이 유효하다. 하나라도 다르면 다시 센다.
    ///
    /// **줄 배열은 주소와 길이 둘 다 본다** — 접힘이 바뀌면 보이는 줄 배열이 갈리는데, 같은 버퍼를
    /// 재사용하면 주소가 같고 길이만 달라질 수 있다(그 반대도 마찬가지다).
    lines_ptr: usize = 0,
    lines_len: usize = 0,
    /// 본문이 쓰는 **열 수**. 창 리사이즈·gutter 자릿수 변화가 여기로 들어온다 — 랩이 갈리는 값이라
    /// 이것이 바뀌면 모든 줄의 행 수가 바뀔 수 있다.
    content_width: u16 = 0,
    wrap: bool = false,
    tab_width: u8 = 0,
    /// 채워진 적이 있는가. 위 키가 우연히 0으로 맞는 첫 프레임을 유효로 읽지 않기 위한 플래그다.
    filled: bool = false,
    /// **조건이 갈려도 다시 세지 않는다**(§2.1 "저하 동작을 허용한다" — *"랩은 직전 결과를 쓴다"*).
    ///
    /// 폭을 **라이브로 바꾸는 드래그** 중에 호출자가 켠다. 그동안은 모든 줄의 조각 수가 매 프레임
    /// 달라져 캐시가 매번 무효가 되는데, 그 계수는 문서 크기에 비례하므로(실측: 2만 줄 랩 문서에서
    /// 프레임당 60.9ms, ReleaseFast) 드래그가 그만큼 뻑뻑해진다. 막대 길이가 잠깐 옛 폭 기준인 것이
    /// 드래그가 16fps로 끊기는 것보다 낫다 — 그리고 드래그가 끝나면 그 프레임이 정확히 다시 센다.
    ///
    /// **아직 한 번도 안 채워졌으면 이 플래그는 무시된다** — 보여 줄 "직전 값"이 없으므로 저하할 것이
    /// 없고, 그 상태로 넘기면 막대가 통째로 틀린다.
    hold: bool = false,
    /// **몇 줄까지 정확히 셌는가**(§2.1 점진 계수). `prefix[0..filled_upto]`만 실제 계수 결과이고,
    /// 그 뒤는 아직 안 봤다. `lines_len`과 같아지면 완성이다.
    ///
    /// 아직 덜 센 구간은 **줄당 한 행**으로 친다 — 랩을 모르니 최소값이고, 프레임이 지날수록 실제
    /// 값으로 수렴한다. 그동안 막대는 실제보다 짧게(문서가 짧다고) 보이지만 화면은 멈추지 않는다
    /// (§2.1 "저하 동작을 허용한다"와 같은 축이다).
    filled_upto: usize = 0,

    /// 문서 전체의 시각 행 수. 아직 안 센 구간은 줄당 한 행으로 친다.
    fn totalRows(self: *const RowCache, lines_len: usize) u32 {
        const counted = self.prefix[@min(self.filled_upto, lines_len)];
        const rest = lines_len -| self.filled_upto;
        return counted +| @as(u32, @intCast(@min(rest, std.math.maxInt(u32))));
    }

    /// 화면 맨 위 줄까지의 시각 행 수. 같은 근사를 쓴다.
    fn rowsBefore(self: *const RowCache, line: usize) u32 {
        if (line <= self.filled_upto) return self.prefix[line];
        const counted = self.prefix[self.filled_upto];
        const rest = line - self.filled_upto;
        return counted +| @as(u32, @intCast(@min(rest, std.math.maxInt(u32))));
    }

    /// 그 줄의 행 수를 캐시가 알고 있는가(안 셌으면 호출자가 직접 센다).
    fn rowsOf(self: *const RowCache, line: usize) ?u32 {
        if (line >= self.filled_upto) return null;
        return self.prefix[line + 1] - self.prefix[line];
    }

    /// **행 수를 아직 다 못 셌는가**(§2.1 점진 계수). 그 동안 안 센 줄은 한 행으로 쳐서 총 행 수가
    /// 실제보다 작고, 그래서 **스크롤바가 실제보다 짧다** — 사용자가 보는 저하다.
    ///
    /// **랩이 꺼져 있으면 저하가 아니다**: 그때는 한 줄이 정확히 한 행이라 근사가 곧 정답이다.
    /// 판정을 여기 두는 이유는 그 사실(근사의 조건)이 계수 규칙과 같은 자리에 있어야 하기 때문이다 —
    /// 상태바가 자기 식으로 다시 재면 "세는 중"이라고 말하면서 화면은 이미 정확할 수 있다.
    pub fn countingIncomplete(self: *const RowCache) bool {
        return self.wrap and self.filled and self.filled_upto < self.lines_len;
    }

    /// 지금 그리는 조건에서 이 캐시를 그대로 쓸 수 있는가.
    fn hits(self: *const RowCache, lines: []const []const u8, width: u16, wrap: bool, tab_width: u8) bool {
        return self.filled and
            self.lines_ptr == @intFromPtr(lines.ptr) and
            self.lines_len == lines.len and
            self.content_width == width and
            self.wrap == wrap and
            self.tab_width == tab_width and
            self.prefix.len > lines.len;
    }
};

/// 스크롤 상한 한 쌍. 익명 struct로 두면 분기마다 타입이 갈린다.
pub const MaxTop = struct { line: usize, piece: u32 };

pub const Written = struct {
    ops: usize,
    /// **문서 전체**의 시각 행 수(랩 포함). 스크롤 입력이 "이 문서가 화면에 다 들어가는가"를 이 값으로
    /// 판정한다 — 논리 줄 수로는 랩된 문서에서 그 판정이 틀린다(입력 쪽이 접힘을 모른다).
    total_visual_rows: u32,
    /// 스크롤 **상한** `(줄, 조각)` — 맨 아래에서 한 화면을 채우는 위치(§4.1d).
    ///
    /// **입력이 이것을 읽는다.** 입력 쪽에서 구하려면 문서 끝에서 거꾸로 조각을 누적해야 하는데
    /// clamp는 매 프레임 돌아 그때마다 수십~수백 줄을 다시 조각내게 된다. 여기서는 이미 센
    /// `row_counts`를 뒤에서부터 훑기만 하면 된다. `total_visual_rows`를 싣는 것과 같은 관례다.
    ///
    /// 문서가 화면에 다 들어가면 `(0, 0)`이다. 호출자가 `total_visual_rows`를 미리 줘 계수를
    /// 건너뛰었으면 줄별 조각 수를 모르므로 **논리 줄 하나 = 한 행**으로 근사한다(그 경우 랩이
    /// 없다는 뜻이거나, 근사가 허용되는 자리다 — 같은 근사를 `total_visual`도 쓴다).
    max_top_line: usize,
    max_top_piece: u32,
    /// 실제로 그린 시각 행 수. 호출자가 스크롤 clamp에 쓴다.
    visual_rows: usize,
    /// 저장소가 모자라 잘린 몫이 있는가. 캡처에는 빈 자리로 나타난다.
    truncated: bool,
    /// 그린 막대의 기하. 스크롤이 필요 없으면 `null`이고 그때는 막대 op도 없다.
    /// 드래그·클릭을 붙일 때 호출자가 쓴다(`scroll_area.offsetForPointer`).
    scrollbar: ?scroll_area.ScrollbarGeometry,
    /// 그린 **가로** 막대의 기하. 축이 뒤집혀 타입이 따로다(`scrollbar.HorizontalGeometry`) — 세로와
    /// 한 타입에 담으면 `thumb_y`가 사실은 x라는 식이 된다. 랩이 켜졌거나 넘치지 않으면 `null`이다.
    horizontal_scrollbar: ?scrollbar.HorizontalGeometry = null,
};

/// 한 프레임을 조립해 `scratch.ops` 앞쪽을 채운다. 반환한 `ops` 개수만큼이 유효하다.
pub fn build(props: Props, scratch: Scratch) Written {
    const layout = geometry.compute(props.total_cols, props.total_lines, .{});

    // ── 1) 배경 ────────────────────────────────────────────────────────────────
    // **맨 앞이어야 한다**(painter). 뒤로 가면 글자를 덮는다(§4.1b).
    const bg = surface.build(.{ .rect = props.background_rect orelse props.rect }, scratch.ops);

    // ── 2) 본문 ────────────────────────────────────────────────────────────────
    // **gutter보다 먼저 돈다.** 랩이 켜지면 어느 논리 줄이 몇 행으로 접히는지는 전개해 나눠 본
    // 쪽만 알기 때문이다(§4 세로 축) — 둘이 각자 세면 랩된 줄에서 번호가 본문과 어긋난다.
    var n: usize = 0;
    while (n < scratch.content_rows.len and props.first_line + n < props.lines.len) : (n += 1) {
        const li = props.first_line + n;
        scratch.content_rows[n] = .{
            .bytes = props.lines[li],
            // **짧은 배열을 허용한다** — 없는 줄은 무색이다(위 `line_colors` 계약).
            .colors = if (li < props.line_colors.len) props.line_colors[li] else &.{},
        };
    }
    const visual_budget = @min(props.visible_rows, scratch.visual_rows.len);

    // **gutter 몫을 먼저 뗀다.** 본문이 먼저 도는 순서의 대가다 — 긴 줄 하나가 저장소를 다 쓰면
    // 뒤에 도는 gutter가 줄 번호를 못 그린다. 본문이 덜 그려지면 그 줄만 짧게 보이지만, 번호가
    // 없으면 화면 전체가 문서의 어디인지 알 수 없다.
    //
    // 예약은 **실제 자릿수**로 잡는다. `max_digits`로 잡으면 실제의 스무 배를 떼어 본문이 근거
    // 없이 줄어든다 — 저장소를 나눠 쓰므로 한쪽의 과잉이 다른 쪽의 손실이다.
    const gutter_reserve = @min(
        scratch.text_bytes.len / 2,
        // 표식 몫은 **표식을 실제로 그릴 때만** 뗀다 — 접힘 칸이 없는 레이아웃(`features.folding = false`)
        // 에서 예약만 늘리면 그만큼 본문이 근거 없이 줄어든다.
        gutter.scratchNeeded(@intCast(visual_budget), props.total_lines, props.folds != null and !layout.folding.isEmpty()),
    );
    const content_scratch = scratch.text_bytes[0 .. scratch.text_bytes.len - gutter_reserve];

    const cw = content.build(.{
        .layout = layout,
        .rows = scratch.content_rows[0..n],
        .wrap = props.wrap,
        .first_col = props.first_col,
        .first_piece = props.first_piece,
        .tab_width = props.tab_width,
        .cell_w_px = props.cell_w_px,
        .cell_h_px = props.cell_h_px,
        .origin_px = .{ .x = props.rect.x, .y = props.rect.y },
        .font_px = props.font_px,
    }, scratch.ops[bg.ops..], content_scratch, scratch.runs, scratch.visual_rows[0..visual_budget]);

    // ── 3) gutter ──────────────────────────────────────────────────────────────
    // 본문이 정한 시각 배치를 그대로 따른다 — 이어진 조각에는 번호가 비어야 한다.
    const grows = gutter.rowsForVisual(
        scratch.visual_rows[0..cw.visual_rows],
        props.first_line,
        props.line_numbers,
        props.folds,
        scratch.gutter_rows,
    );
    const gw = gutter.build(.{
        .layout = layout,
        .rows = grows,
        .cell_w_px = props.cell_w_px,
        .cell_h_px = props.cell_h_px,
        .origin_px = .{ .x = props.rect.x, .y = props.rect.y },
        .font_px = props.font_px,
    }, scratch.ops[bg.ops + cw.ops ..], scratch.text_bytes[cw.bytes..], scratch.runs[cw.runs..]);

    // ── 4) 스크롤바 ────────────────────────────────────────────────────────────
    // **문서 전체의 시각 행 수**라야 막대 길이가 맞는다(§4.1a) — 논리 줄로 세면 랩된 문서에서
    // 실제보다 짧아 보이고, 화면에 그린 행으로 세면 늘 꽉 찬 것으로 판정돼 막대가 사라진다.
    // 랩이 켜지면 논리 줄 하나가 여러 시각 행이 되므로, 막대의 위치도 **시각 행**으로 세야 한다.
    // `first_line`(논리)을 그대로 쓰면 랩된 문서에서 막대가 실제보다 위에 선다 — 세로 스크롤이
    // 붙기 전에는 늘 0이라 아무도 못 봤다(적대적 검증에서 드러났다).
    var first_visual: u32 = @intCast(@min(props.first_line, std.math.maxInt(u32)));
    var counted_rows: usize = 0; // 아래에서 실제로 센 줄 수(막대 위치 계산이 같은 값을 쓴다)

    // **캐시가 있으면 조건이 갈릴 때만 센다.** 여기서 채우는 이유는 계수에 필요한 `content.width`가
    // 이 안에서 정해지기 때문이다 — 호출자가 그 폭을 다시 구하면 출처가 둘이 되고, 갈리는 순간
    // 막대 길이가 화면과 어긋난다(같은 부류를 §4.1e에서 이미 잡았다).
    //
    // 자리가 모자라면 **조용히 예전 경로로 내려간다**(`Scratch`와 같은 규율) — 캐시는 빠르게 하는
    // 장치이지 정확성의 전제가 아니다.
    const cache: ?*RowCache = blk: {
        const c = props.row_cache orelse break :blk null;
        if (c.prefix.len <= props.lines.len) break :blk null;
        if (!c.hits(props.lines, layout.content.width, props.wrap, props.tab_width)) {
            // **저하**: 드래그 중이면 옛 값을 그대로 쓴다(§2.1). 단 **줄 배열이 그대로일 때만**이다 —
            // 저하가 겨냥하는 것은 폭이 바뀌는 드래그이고, 그동안 문서의 줄 집합은 변하지 않는다.
            // 줄이 바뀌었는데 옛 접두합을 쓰면 그것은 "직전 결과"가 아니라 **다른 문서의 값**이다.
            if (c.hold and c.filled and
                c.lines_ptr == @intFromPtr(props.lines.ptr) and
                c.lines_len == props.lines.len) break :blk c;
            // **조건이 갈렸다 — 처음부터 다시 센다.** 키는 여기서 갱신하고 진행도만 0으로 되돌린다.
            // 그래야 다음 프레임이 `hits`로 들어와 **이어서** 셀 수 있다(그러지 않으면 매 프레임
            // 처음부터 다시 시작해 영영 끝나지 않는다).
            c.lines_ptr = @intFromPtr(props.lines.ptr);
            c.lines_len = props.lines.len;
            c.content_width = layout.content.width;
            c.wrap = props.wrap;
            c.tab_width = props.tab_width;
            c.filled = true;
            c.filled_upto = 0;
            c.prefix[0] = 0;
        }
        // **이번 프레임 몫만 센다**(§2.1 점진 계수). 줄마다 독립이라 나눌 수 있고, 그래서 이 작업은
        // 워커가 아니라 메인에 남는다. 다 셀 때까지 호출자가 프레임을 계속 요청한다.
        if (c.filled_upto < props.lines.len) {
            const end = @min(props.lines.len, c.filled_upto + count_chunk_lines);
            var sum: u32 = c.prefix[c.filled_upto];
            var i: usize = c.filled_upto;
            while (i < end) : (i += 1) {
                sum +|= content.rowCount(props.lines[i], props.tab_width, layout.content.width, props.wrap, scratch.count_scratch).rows;
                c.prefix[i + 1] = sum;
            }
            c.filled_upto = end;
        }
        break :blk c;
    };

    const total_visual: u32 = props.total_visual_rows orelse if (cache) |c| c.totalRows(props.lines.len) else blk: {
        var sum: u32 = 0;
        var counted: usize = 0;
        while (counted < props.lines.len and counted < scratch.row_counts.len) : (counted += 1) {
            const c = content.rowCount(
                props.lines[counted],
                props.tab_width,
                layout.content.width,
                props.wrap,
                scratch.count_scratch,
            );
            scratch.row_counts[counted] = c.rows;
            sum +|= c.rows;
        }
        // **못 센 줄은 논리 줄 하나로 친다.** `row_counts`가 문서보다 짧으면 나머지를 0으로 두게
        // 되는데, 그러면 막대가 문서 끝에 닿아 있는 것처럼 보인다 — 랩을 모르니 최소값으로 잡는다.
        if (props.lines.len > counted) sum +|= @intCast(props.lines.len - counted);
        counted_rows = counted;
        break :blk sum;
    };
    // 화면 맨 위 줄까지의 **시각 행 수** = 막대가 서야 할 자리. 논리 줄로 세면 랩된 문서에서 막대가
    // 실제보다 위에 선다.
    //
    // **호출자가 주지 않았으면 여기서 센다** — `total_visual_rows`만 받고 이 값을 논리 줄로 대신하면
    // 바로 그 문서(큰 문서·랩)에서 막대가 틀린다(리뷰가 그 상태를 잡았다). 계수는 화면 맨 위 줄까지만
    // 돌고, 이미 센 구간은 그 결과를 재사용한다.
    if (props.first_visual_row) |given| {
        first_visual = given;
    } else if (cache) |c| {
        // 캐시가 있으면 접두합 조회 하나다 — 문서 끝으로 내려가도 비용이 늘지 않는다.
        first_visual = c.rowsBefore(@min(props.first_line, props.lines.len));
    } else {
        var prefix: u32 = 0;
        const upto = @min(props.first_line, props.lines.len);
        for (0..upto) |i| {
            prefix +|= if (i < counted_rows)
                scratch.row_counts[i]
            else
                content.rowCount(props.lines[i], props.tab_width, layout.content.width, props.wrap, scratch.count_scratch).rows;
        }
        first_visual = prefix;
    }

    // ── 5) diff 밴드 ──────────────────────────────────────────────────────────
    // **스크롤바보다 먼저 낸다.** 밴드는 열 폭 전체를 덮으므로(스크롤바 gutter 포함) 나중에 내면
    // 막대 위에 16% 색이 덧칠돼 thumb이 줄무늬로 보인다(리뷰 지적 — 처음엔 마지막에 냈다).
    //
    // **본문이 정한 시각 배치를 그대로 따른다**(gutter와 같은 이유) — 랩된 줄은 이어진 조각에도
    // 같은 색이 깔려야 한 줄로 읽힌다.
    //
    // **quad로 낸다.** `fill`은 셀 격자로 내려가는데(`metal_lowering.paintRectBg`) 이 밴드는 gutter와
    // 스크롤바 자리까지 덮어 격자 밖으로 나간다 — 배경(`surface`)이 같은 이유로 quad인 것과 같다.
    // 글자는 셀 파이프라인이라 늘 quad 위에 그려진다.
    // **스크롤 상한을 여기서 센다**(§4.1d) — 문서 끝에서 거꾸로 한 화면을 채운다.
    const max_top: MaxTop = blk: {
        const visible: u32 = @max(visual_budget, 1);
        if (total_visual <= visible) break :blk .{ .line = 0, .piece = 0 };
        var need: u32 = visible;
        var i: usize = props.lines.len;
        while (i > 0) {
            i -= 1;
            // **여기서는 근사하면 안 된다.** `row_counts`는 문서 **앞에서부터** 채워지는데 이 훑기는
            // **뒤에서부터** 간다 — 4096줄을 넘는 문서에서는 뒤쪽이 전부 "1행"으로 잡혀 상한이 너무
            // 위에 서고, 끝까지 굴려도 **마지막 줄들이 손에 안 닿는다**(실측: 5000줄 랩 문서에서
            // 마지막 17줄. 적대적 검증 2026-08-16). 필요한 것은 마지막 한 화면분뿐이라 그 줄만
            // 직접 센다 — 앞에서 이미 센 구간은 그 값을 재사용한다.
            // **아직 안 센 줄은 캐시가 모른다** — 그 구간은 직접 센다. 이 훑기는 마지막 한 화면분뿐이라
            // 점진 중에도 싸다.
            const rows: u32 = if (cache) |c|
                (c.rowsOf(i) orelse content.rowCount(props.lines[i], props.tab_width, layout.content.width, props.wrap, scratch.count_scratch).rows)
            else if (i < counted_rows)
                scratch.row_counts[i]
            else
                content.rowCount(
                    props.lines[i],
                    props.tab_width,
                    layout.content.width,
                    props.wrap,
                    scratch.count_scratch,
                ).rows;
            if (rows >= need) break :blk .{ .line = i, .piece = rows - need };
            need -= rows;
        }
        break :blk .{ .line = 0, .piece = 0 };
    };

    const band_ops = paintBands(props, layout, scratch.visual_rows[0..cw.visual_rows], scratch.ops[bg.ops + cw.ops + gw.ops ..], scratch.count_scratch);
    // **선택은 밴드 뒤에 얹는다** — diff 줄 배경 위에 선택이 보여야지 그 반대면 선택한 줄이
    // 어느 것인지 흐려진다. 글자보다도 뒤라 알파로 얹어도 내용이 읽힌다.
    const sel_ops = paintSelection(props, layout, scratch.visual_rows[0..cw.visual_rows], scratch.ops[bg.ops + cw.ops + gw.ops + band_ops ..], scratch.count_scratch);
    // **검색 결과는 선택 위에 얹는다.** 선택 안에서 검색하는 경우가 있고(§5.1의 "선택 영역 내에서만"이
    // 그 자리다), 그때 매치가 선택에 묻히면 검색이 아무 일도 안 한 것처럼 보인다.
    // **막대 몫을 남겨 둔다.** 검색 강조는 **줄당 개수에 상한이 없는 유일한 층**이고(선택은
    // 구조적으로 줄당 하나다), 조립 순서상 두 스크롤바보다 **앞**이라 예산을 다 먹으면 막대가
    // 통째로 안 그려진다. 그런데 `scrollbar.build`는 op이 0이어도 **기하는 그대로 반환**하므로
    // 히트테스트는 살아 있다 — "안 보이는데 드래그는 되는" 상태가 된다.
    //
    // 도달 가능한 수치다(적대적 검증 2026-08-23 실측). 이 저장소의 `app_session.zig`에서 공백
    // 한 칸을 검색할 때 80행×160열 창에 그려질 마크 수:
    //
    // | 통계 | 값 |
    // |---|---|
    // | 중앙값 | 720 |
    // | 2,560 초과 창 | **0.4%**(64,792개 중 271개) |
    // | 최댓값 | **3,120**(16,130줄부터) |
    //
    // **전형값이 아니라 꼬리다** — 그래도 막는 이유는 그 꼬리에서 나는 증상이 "안 보이는데
    // 드래그는 되는" 상태여서다. 그리고 **검색이 실제로 쓸 수 있는 자리는 2,560이 아니라
    // 앞 층들을 뺀 ≈2,238**이므로(행마다 배경·본문·gutter·밴드·선택이 먼저 먹는다) 넘침은
    // 위 표보다 조금 일찍 시작한다.
    //
    // 예약은 **두 개**면 충분하다 — 세로·가로 막대가 각각 정확히 op 하나를 쓴다(`scrollbar.zig`의
    // 두 `return .{ .ops = 1, ... }`이 유일한 방출 지점이고 트랙·캡을 안 그린다). 잘리는 쪽은
    // 검색 강조이고, 그쪽은 잘려도 **화면이 조용히 덜 말할 뿐** 조작이 거짓이 되지는 않는다.
    //
    // **이 예약은 검색 층에만 걸린다.** 앞의 배경·본문·gutter·밴드·선택은 여전히 무예약이라,
    // 그쪽이 먼저 다 먹으면 막대는 그대로 굶는다(기존 상태이고 이 슬라이스가 만든 것이 아니다).
    // 검색만 예약하는 이유는 **줄당 개수에 상한이 없는 층이 그것뿐**이어서다.
    const find_base = bg.ops + cw.ops + gw.ops + band_ops + sel_ops;
    const find_room = (scratch.ops.len -| find_base) -| scrollbar_reserve_ops;
    const find_ops = paintSearch(props, layout, scratch.visual_rows[0..cw.visual_rows], scratch.ops[find_base..][0..find_room], scratch.count_scratch);

    // **커서는 검색 위, 막대 앞이다.** 위 예약과 같은 이유로 막대 몫을 남기고, 커서도 줄당 개수에
    // 상한이 없으므로(만 개까지) 남은 자리 안에서만 그린다 — `paintCarets`가 넘으면 자른다.
    const caret_base = find_base + find_ops;
    const caret_room = (scratch.ops.len -| caret_base) -| scrollbar_reserve_ops;
    const caret_ops = paintCarets(props, layout, scratch.visual_rows[0..cw.visual_rows], scratch.ops[caret_base..][0..caret_room]);

    const sw = scrollbar.build(.{
        .content = .{
            .x = @floatFromInt(props.rect.x),
            .y = @floatFromInt(props.rect.y),
            .w = @floatFromInt(@as(u32, props.total_cols) * props.cell_w_px),
            // **실제로 보이는 높이**여야 한다. 창 전체 높이를 주면 문서가 늘 다 들어간다고
            // 판정돼 막대가 안 그려진다.
            .h = @floatFromInt(@as(u32, visual_budget) * props.cell_h_px),
            .gutter_w = @floatFromInt(props.scrollbar_gutter_px),
        },
        .total_visual_rows = total_visual,
        .first_visual_row = first_visual,
        .cell_h_px = props.cell_h_px,
        .metrics = props.metrics,
    }, scratch.ops[caret_base + caret_ops ..]);

    // ── 5) 가로 스크롤바 ───────────────────────────────────────────────────────
    // **본문 아래 거터에 선다.** 호출자가 그 자리를 이미 비워 두었다(`showsHorizontalBar`로 물어
    // `visible_rows`를 줄인다) — 여기서 자리를 만들 수는 없다. 랩이면 축 자체가 없다.
    const hw = if (showsHorizontalBar(props.wrap, props.content_max_cols, layout.content.width))
        scrollbar.buildHorizontal(.{
            .content = .{
                .x = @floatFromInt(props.rect.x + @as(i32, layout.contentLeft()) * @as(i32, props.cell_w_px)),
                .y = @floatFromInt(props.rect.y),
                .w = @floatFromInt(@as(u32, layout.content.width) * props.cell_w_px),
                .h = @floatFromInt(@as(u32, visual_budget) * props.cell_h_px),
                .gutter_w = @floatFromInt(props.scrollbar_gutter_px),
            },
            .total_cols = props.content_max_cols.?,
            .first_col = props.first_col,
            .cell_w_px = props.cell_w_px,
            .metrics = props.metrics,
        }, scratch.ops[caret_base + caret_ops + sw.ops ..])
    else
        scrollbar.HorizontalWritten{ .ops = 0 };

    return .{
        .total_visual_rows = total_visual,
        .max_top_line = max_top.line,
        .max_top_piece = max_top.piece,
        .ops = bg.ops + cw.ops + gw.ops + sw.ops + band_ops + sel_ops + find_ops + caret_ops + hw.ops,
        .visual_rows = cw.visual_rows,
        .truncated = cw.truncated_rows > 0 or gw.dropped_rows > 0,
        .scrollbar = sw.geometry,
        .horizontal_scrollbar = hw.geometry,
    };
}

/// 시각 행마다 밴드를 깐다. 반환 = 쓴 op 수(저장소가 모자라면 거기서 멈춘다 — 잘릴 뿐 죽지 않는다).
/// **창 투명도는 이 밴드에 곱해지지 않는다**(`terminal_bg` 역할만 곱해진다 —
/// `chrome_draw_lowering.appendBackgroundQuadsWithTerminalOpacity`). 밴드는 바탕이 아니라 바탕 위에
/// 얹는 표시라 글자와 같은 취급이 맞다 — 투명한 창에서 바탕이 옅어질수록 밴드도 함께 옅어지면
/// "어느 줄이 바뀌었나"가 창 설정에 따라 사라진다.
fn paintBands(props: Props, layout: geometry.Layout, visual: []const visual_map.VisualRow, out: []draw.Op, scratch_cols: []u8) usize {
    const bands = props.row_bands orelse return 0;
    var n: usize = 0;
    for (visual, 0..) |v, i| {
        if (n + 2 > out.len) break; // 줄 배경 + 띠 = 둘씩 든다
        const idx = props.first_line + v.line;
        if (idx >= bands.len) continue;
        const role: tokens.ColorRole = switch (bands[idx]) {
            .none => continue,
            .added => .diff_added_bg,
            .removed => .diff_removed_bg,
        };
        const y = props.rect.y + @as(i32, @intCast(i * props.cell_h_px));
        out[n] = .{ .quad = .{
            .rect = .{ .x = props.rect.x, .y = y, .w = props.rect.w, .h = props.cell_h_px },
            .fill_role = role,
            .alpha = band_alpha,
        } };
        out[n + 1] = .{ .quad = .{
            .rect = .{ .x = props.rect.x, .y = y, .w = strip_width_px, .h = props.cell_h_px },
            .fill_role = role,
            .alpha = strip_alpha,
        } };
        n += 2;

        // ── 바뀐 글자 ────────────────────────────────────────────────────────
        // **이어진 조각에도 칠한다**(2026-08-19). 오랫동안 `v.piece != 0`이면 통째로 건너뛰었는데,
        // 이유는 *"그 조각이 어디서 시작하는지를 `visual_map`이 자를 때만 안다"*는 것이었다. 이제
        // 그 값이 행마다 실려 온다(`VisualRow.start_col` — §4.1g ①). 랩을 켜고 긴 줄을 보면 첫
        // 조각만 강조되고 나머지가 비던 것이 이것으로 닫힌다.
        //
        // **`start_col`이 가로 스크롤도 함께 담는다.** 랩이 꺼지면 조각이 하나이고 그 값이 곧
        // `first_col`이며(그렇게 초기화한다), 랩이 켜지면 가로 축이 없어 `first_col`이 0이라
        // 조각 누적만 남는다 — 두 경우가 한 식으로 처리되므로 아래에서 그것만 쓴다.
        const row_start_col: u32 = v.start_col;
        const marks = (props.row_marks orelse continue);
        if (idx >= marks.len) continue;
        const row_marks = marks[idx];
        if (row_marks.len == 0) continue;
        const line = if (idx < props.lines.len) props.lines[idx] else continue;

        n += paintRowMarks(props, layout, .{
            .line = line,
            .row_start_col = row_start_col,
            .y = y,
            .marks = row_marks,
            .role = role,
            .alpha = mark_alpha,
        }, out[n..], scratch_cols);
    }
    return n;
}

/// 한 행의 **글자 범위 강조**를 화면 quad로 놓는다. diff의 "바뀐 글자"와 본문 선택이 같은 길을 쓴다.
///
/// **둘로 갈리면 안 되는 이유가 §4.1c에 있다** — 열 계산 규칙이 두 곳에 있으면 하나만 고쳐져 강조가
/// 7칸 밀린 전례가 그것이다. 색과 세기만 다르고 나머지는 같다.
const RowMarkPaint = struct {
    line: []const u8,
    row_start_col: u32,
    y: i32,
    marks: []const Mark,
    role: tokens.ColorRole,
    alpha: u8,
};

fn paintRowMarks(props: Props, layout: geometry.Layout, p: RowMarkPaint, out: []draw.Op, scratch_cols: []u8) usize {
    var n: usize = 0;
    // **줄을 한 번만 지난다.** 위치마다 앞부분을 다시 펴면 마크가 많은 줄에서 비용이 곱으로 붙는다
    // (200자 줄에 마크 100개 = 한 행에 4만 스텝, 화면 50행이면 프레임당 수백만). 물어볼 위치를
    // 모아 한 번에 채운다 — 저장소가 모자라면 앞에서부터 담을 수 있는 만큼만 그린다.
    const max_pairs = @min(p.marks.len, scratch_cols.len / (2 * @sizeOf(u32)));
    if (max_pairs == 0) return 0;
    const offsets = std.mem.bytesAsSlice(u32, scratch_cols[0 .. max_pairs * 2 * @sizeOf(u32)]);
    for (p.marks[0..max_pairs], 0..) |m, k| {
        offsets[k * 2] = m.start;
        offsets[k * 2 + 1] = m.start + m.len;
    }
    // 화면 오른쪽 끝을 넘으면 멈춘다 — 그 뒤 마크는 어차피 아래에서 잘린다.
    content.columnsAtOffsets(p.line, props.tab_width, offsets, offsets, p.row_start_col + layout.content.width); // 제자리 채우기
    for (p.marks[0..max_pairs], 0..) |_, k| {
        if (n >= out.len) break;
        const start_col = offsets[k * 2];
        const end_col = offsets[k * 2 + 1];
        if (end_col <= start_col) continue;
        // 가로 스크롤·본문 폭 밖은 자른다 — 넘치면 gutter나 옆 열을 침범한다.
        // **왼쪽도 자른다.** 화면 밖에서 시작하는 마크를 그대로 쓰면 아래 뺄셈이 음수가 되고
        // (u32라 오버플로로 죽는다), 가로 스크롤이 붙는 순간 그 자리에서 터진다.
        const from = @max(start_col, p.row_start_col);
        const to = @min(end_col, p.row_start_col + layout.content.width);
        if (to <= from) continue;
        // **본문은 gutter 뒤에서 시작한다.** pane 원점부터 세면 강조가 줄 번호 위에 선다
        // (첫 캡처가 정확히 그랬다) — 본문 시작 열(`contentLeft`)을 더한다.
        const col_on_screen: u32 = @as(u32, layout.contentLeft()) + (from - p.row_start_col);
        const x = props.rect.x + @as(i32, @intCast(col_on_screen * props.cell_w_px));
        out[n] = .{ .quad = .{
            .rect = .{ .x = x, .y = p.y, .w = (to - from) * props.cell_w_px, .h = props.cell_h_px },
            .fill_role = p.role,
            .alpha = p.alpha,
        } };
        n += 1;
    }
    return n;
}

/// 본문 **텍스트 선택**을 그린다(§4.1g 배선). `row_bands`와 달리 diff가 아니어도 선다.
///
/// 줄별 byte 범위를 받는다 — 선택은 문서 전체 offset이지만 그것을 줄로 자르는 것은 **제품의 일**이다
/// (컴포넌트는 어느 줄이 문서 몇 번째 byte에서 시작하는지 모른다). `row_marks`와 같은 축이다.
fn paintSelection(props: Props, layout: geometry.Layout, visual: []const visual_map.VisualRow, out: []draw.Op, scratch_cols: []u8) usize {
    const sel = props.selection_marks orelse return 0;
    var n: usize = 0;
    for (visual, 0..) |v, i| {
        if (n >= out.len) break;
        const idx = props.first_line + v.line;
        if (idx >= sel.len or idx >= props.lines.len) continue;
        if (sel[idx].len == 0) continue;
        n += paintRowMarks(props, layout, .{
            .line = props.lines[idx],
            .row_start_col = v.start_col,
            .y = props.rect.y + @as(i32, @intCast(i)) * @as(i32, props.cell_h_px),
            .marks = sel[idx],
            .role = .selection,
            .alpha = selection_alpha,
        }, out[n..], scratch_cols);
    }
    return n;
}

/// **커서**를 그린다(§3.2 — 커서는 배열이다).
///
/// **선택·검색보다 위다.** 커서는 "지금 타이핑이 어디로 가는가"를 말하는 유일한 표시라, 무엇에
/// 가려지면 사용자가 자기 입력이 어디로 갈지 모른다. 그래서 조립에서 마지막 본문 층이다.
///
/// **폭은 한 셀이 아니라 2px 막대다.** 셀 폭으로 그리면 CJK 위에서 절반만 덮고 탭 위에서 반쪽에
/// 서는데, 그보다 근본적으로 **커서는 글자 사이에 있는 것**이라 글자 폭을 가질 이유가 없다.
/// (블록 커서는 overtype 모드의 표현이고 그 모드가 아직 없다.)
///
/// **줄당 개수에 상한이 없는 둘째 층이다** — 검색 강조가 첫째다. 커서가 만 개까지 갈 수 있으므로
/// (`selection.max_cursors`) 예산을 다 먹으면 뒤에 오는 스크롤바가 통째로 안 그려지고, 그때
/// `scrollbar.build`는 기하를 그대로 반환해 **"안 보이는데 드래그는 되는"** 상태가 된다.
/// 그래서 호출자가 남겨 준 몫(`out`) 안에서만 그리고 넘으면 **조용히 자른다** — 커서 몇 개가
/// 안 보이는 것이 막대가 사라지는 것보다 낫다.
/// **`scratch_cols`를 받지 않는다.** 띠·검색은 한 줄에서 여러 offset을 한꺼번에 열로 옮기느라
/// 임시 배열이 필요하지만, 커서는 한 자리씩이라 그럴 것이 없다 — 안 쓰는 인자를 "대칭이니까"
/// 받아 두면 읽는 사람이 그것이 쓰인다고 믿는다.
fn paintCarets(props: Props, layout: geometry.Layout, visual: []const visual_map.VisualRow, out: []draw.Op) usize {
    if (!props.caret_visible) return 0;
    const rows = props.carets orelse return 0;

    var n: usize = 0;
    for (visual, 0..) |row, i| {
        if (row.line >= rows.len) continue;
        const offsets = rows[row.line];
        if (offsets.len == 0) continue;
        const line = if (row.line < props.lines.len) props.lines[row.line] else continue;

        // **행의 y는 `visual` 배열 인덱스로 센다** — `paintSelection`이 쓰는 것과 같은 산술이다.
        // `row.screen_row`가 아닌 이유는 그 값이 이 배열의 인덱스와 다를 수 있어서다.
        const y = props.rect.y + @as(i32, @intCast(i)) * @as(i32, props.cell_h_px);
        for (offsets) |off| {
            if (n >= out.len) return n; // 예산 끝 — 막대 몫을 지킨다
            const col = columnOfOffset(line, props.tab_width, off, row.start_col + layout.content.width);
            if (col < row.start_col) continue; // 이 행보다 앞이다(랩)
            const on_screen = col - row.start_col;
            if (on_screen >= layout.content.width) continue; // 이 행보다 뒤다
            const x = props.rect.x +
                @as(i32, @intCast((@as(u32, layout.contentLeft()) + on_screen) * props.cell_w_px));
            // **불투명하게 그린다.** 띠·검색은 글자를 읽어야 해서 알파로 얹지만, 커서는 그 자리에
            // 글자가 없다(글자 **사이**다) — 반투명하게 두면 배경색이 비쳐 흐릿한 막대가 된다.
            out[n] = .{ .quad = .{
                .rect = .{ .x = x, .y = y, .w = caret_width_px, .h = props.cell_h_px },
                .fill_role = .cursor,
            } };
            n += 1;
        }
    }
    return n;
}

/// 커서 막대 폭(px). **셀 폭과 무관한 상수다** — 폰트를 키워도 커서가 뚱뚱해지지 않는다.
pub const caret_width_px: u32 = 2;

/// 줄 안 byte offset이 몇 열인가. `columnsAtOffsets`를 하나짜리로 부르는 얇은 감쌈이다 —
/// **열 계산을 여기서 다시 짜지 않는다**(§5.4: 하나의 픽셀-레이아웃 소스).
fn columnOfOffset(line: []const u8, tab_width: u16, offset: u32, stop_col: u32) u32 {
    var one = [_]u32{offset};
    var out = [_]u32{0};
    content.columnsAtOffsets(line, tab_width, &one, &out, stop_col);
    return out[0];
}

/// **검색 결과**를 그린다(§5.1). 선택과 같은 축·같은 열 계산을 쓰고 색과 세기만 다르다.
///
/// **현재 매치만 갈라 다른 색으로 그린다.** 갈라 두 배열로 받지 않는 이유는 어긋남이다 — 목록이
/// 둘이면 한쪽에만 있는 매치(색이 없다)나 양쪽에 있는 매치(두 번 칠해 더 진하다)가 날 수 있고,
/// 둘 다 "검색이 이상하다"로 보인다. 하나에서 골라내면 그 상태가 표현 불가능하다.
fn paintSearch(props: Props, layout: geometry.Layout, visual: []const visual_map.VisualRow, out: []draw.Op, scratch_cols: []u8) usize {
    const rows = props.search_marks orelse return 0;
    var n: usize = 0;

    // ── 1) 현재 매치 먼저 ────────────────────────────────────────────────────
    //
    // **행 루프 밖에서 따로 돈다.** 초판은 "그 줄 안에서" 현재 매치를 앞으로 당겼는데, 그것으로는
    // **예산이 그 행에 닿기 전에 마르는 경우**를 못 막는다 — 실측 조건(80행, 행당 39마크)에서
    // 대략 58행째에 마르고, 현재 매치가 그 아래면 그대로 떨어진다. 그러면 주변 매치는 보통 색으로
    // 남고 **현재 위치 표시만 없는 화면**이 된다: Enter가 어디로 갈지 화면이 말해 주지 못한다.
    //
    // 먼저 한 번 돌면 현재 매치는 **op이 하나라도 남아 있는 한** 그려진다(2라운드 적대적 검증이
    // 실측으로 잡았다 — `ops`를 6·8·9로 좁혀 보면 초판은 셋 다 현재 매치가 0개였다).
    //
    // **랩된 줄은 조각마다 quad가 날 수 있다.** 초판 주석은 "실제로 quad가 나는 조각은 하나"라
    // 적었는데 **거짓이다** — 마크가 조각 경계를 넘으면 `paintRowMarks`가 조각마다 잘린 조각을
    // 그린다(적대적 검증 2026-08-24 실측: 52자 마크가 조각 5개에서 quad 5개). 그리기는 옳고,
    // 틀린 것은 그 주석이 옆의 예산 계산 근거를 오도했다는 점이다.
    if (props.search_current) |cur| {
        for (visual, 0..) |v, i| {
            if (n >= out.len) break;
            const idx = props.first_line + v.line;
            if (idx != cur.line or idx >= rows.len or idx >= props.lines.len) continue;
            const marks = rows[idx];
            const k = for (marks, 0..) |m, mi| {
                if (m.start == cur.start) break mi;
            } else continue;
            n += paintRowMarks(props, layout, .{
                .line = props.lines[idx],
                .row_start_col = v.start_col,
                .y = props.rect.y + @as(i32, @intCast(i)) * @as(i32, props.cell_h_px),
                .marks = marks[k .. k + 1],
                .role = .search_match_current,
                .alpha = search_current_alpha,
            }, out[n..], scratch_cols);
        }
    }

    // ── 2) 나머지 ────────────────────────────────────────────────────────────
    //
    // **셋으로 나눠 같은 함수를 부른다.** 열 계산이 한 곳에 있어야 한다는 규칙(§4.1c)이 여기서도
    // 그대로다 — 현재 매치만 따로 계산하면 그 하나가 7칸 밀리는 전례를 반복한다.
    for (visual, 0..) |v, i| {
        if (n >= out.len) break;
        const idx = props.first_line + v.line;
        if (idx >= rows.len or idx >= props.lines.len) continue;
        const marks = rows[idx];
        if (marks.len == 0) continue;
        const paint = RowMarkPaint{
            .line = props.lines[idx],
            .row_start_col = v.start_col,
            .y = props.rect.y + @as(i32, @intCast(i)) * @as(i32, props.cell_h_px),
            .marks = marks,
            .role = .search_match,
            .alpha = search_alpha,
        };

        // 현재 매치가 이 줄에 있나. 없으면 한 번에 그린다 — 대부분의 줄이 이쪽이다.
        //
        // **같은 `start`를 가진 마크는 한 줄에 둘일 수 없다**(그래서 이 조회가 모호하지 않다):
        // ⑴ 이 행은 문서 줄 하나의 매치만 받고, ⑵ 그 줄 안에서 매치는 겹치지 않아 `start`가
        // 엄격히 증가하며, ⑶ 보이는 줄 번호 표에 중복이 없어 같은 문서 줄이 두 행에 실리지 않는다.
        const cur: ?usize = blk: {
            const c = props.search_current orelse break :blk null;
            if (c.line != idx) break :blk null;
            for (marks, 0..) |m, k| {
                if (m.start == c.start) break :blk k;
            }
            break :blk null;
        };
        const k = cur orelse {
            n += paintRowMarks(props, layout, paint, out[n..], scratch_cols);
            continue;
        };

        // 그 하나는 위에서 이미 그렸다 — 앞뒤만 채운다.
        var p_before = paint;
        p_before.marks = marks[0..k];
        if (p_before.marks.len > 0) n += paintRowMarks(props, layout, p_before, out[n..], scratch_cols);

        var p_after = paint;
        p_after.marks = marks[k + 1 ..];
        if (p_after.marks.len > 0 and n < out.len) n += paintRowMarks(props, layout, p_after, out[n..], scratch_cols);
    }
    return n;
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "계수가 끝나기 전에는 저하라고 말한다 — 랩이 꺼져 있으면 아니다 (§2.1)" {
    // 안 센 줄을 한 행으로 치므로 총 행 수가 실제보다 작고, 그래서 **스크롤바가 짧다**. 그 사실을
    // 상태바가 말해야 한다(조용히 줄어들면 사용자는 버그로 읽는다).
    var prefix: [8]u32 = @splat(0);
    var cache: RowCache = .{ .prefix = &prefix, .wrap = true, .filled = true, .lines_len = 4, .filled_upto = 2 };
    try std.testing.expect(cache.countingIncomplete());

    cache.filled_upto = 4; // 다 셌다
    try std.testing.expect(!cache.countingIncomplete());

    // **랩이 꺼져 있으면 근사가 곧 정답이다**(한 줄 = 한 행) — 저하가 아니다.
    cache.wrap = false;
    cache.filled_upto = 2;
    try std.testing.expect(!cache.countingIncomplete());

    // 아직 채우지도 않았으면(조건이 갈려 무효) 그건 저하가 아니라 **다음 프레임에 다시 세는 것**이다.
    cache.wrap = true;
    cache.filled = false;
    try std.testing.expect(!cache.countingIncomplete());
}

const TestBuffers = struct {
    ops: [256]draw.Op = undefined,
    text_bytes: [2048]u8 = undefined,
    runs: [256]draw.Run = undefined,
    content_rows: [64]content.Row = undefined,
    visual_rows: [64]visual_map.VisualRow = undefined,
    gutter_rows: [64]gutter.Row = undefined,
    row_counts: [64]u32 = undefined,
    count_scratch: [4096]u8 = undefined,

    fn scratch(self: *TestBuffers) Scratch {
        return .{
            .ops = &self.ops,
            .text_bytes = &self.text_bytes,
            .runs = &self.runs,
            .content_rows = &self.content_rows,
            .visual_rows = &self.visual_rows,
            .gutter_rows = &self.gutter_rows,
            .row_counts = &self.row_counts,
            .count_scratch = &self.count_scratch,
        };
    }
};

fn testProps(lines: []const []const u8, wrap: bool) Props {
    return .{
        .tab_width = default_tab_width,
        .lines = lines,
        .first_line = 0,
        .total_lines = lines.len,
        .visible_rows = 20,
        .wrap = wrap,
        .rect = .{ .x = 0, .y = 0, .w = 480, .h = 320 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 13,
        .total_cols = 58,
        .scrollbar_gutter_px = 16,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    };
}

// ── `RowCache` — 줄별 행 수를 프레임 사이에 살려 두는 캐시(§2.1) ──────────────────────────────
//
// **이 테스트들이 증명하는 것**: 캐시를 켜도 답이 달라지지 않고(같은 그림), 조건이 갈리면 반드시
// 다시 센다는 것. 둘 다 **조용히** 틀린다 — 낡은 캐시를 쓰면 op 개수도 크래시도 정상이고 막대
// 길이만 어긋나므로, 화면을 재는 테스트가 없으면 아무도 못 본다.

test "캐시를 켜도 답이 같다 — 캐시는 빠르게 할 뿐 값을 바꾸지 않는다" {
    var bufs: TestBuffers = .{};
    const long = "x" ** 200; // 뷰 폭보다 길어 여러 조각으로 접힌다
    const lines = [_][]const u8{ long, "short", long, "tail" };

    const without = build(testProps(&lines, true), bufs.scratch());

    var prefix: [lines.len + 1]u32 = undefined;
    var cache: RowCache = .{ .prefix = &prefix };
    var props = testProps(&lines, true);
    props.row_cache = &cache;
    const with = build(props, bufs.scratch());

    try testing.expect(without.total_visual_rows > lines.len); // 실제로 접혔다(둘 다 의미 있는 값이다)
    try testing.expectEqual(without.total_visual_rows, with.total_visual_rows);
    try testing.expectEqual(without.max_top_line, with.max_top_line);
    try testing.expectEqual(without.max_top_piece, with.max_top_piece);
}

test "폭이 바뀌면 캐시를 다시 센다 — 랩이 갈리는 값이다" {
    var bufs: TestBuffers = .{};
    const long = "x" ** 200;
    const lines = [_][]const u8{ long, long };
    var prefix: [lines.len + 1]u32 = undefined;
    var cache: RowCache = .{ .prefix = &prefix };

    var wide = testProps(&lines, true);
    wide.row_cache = &cache;
    const w1 = build(wide, bufs.scratch());

    // 창을 좁힌다 — 같은 줄이 더 많은 조각으로 접힌다. 캐시가 폭을 안 보면 옛 값이 그대로 나온다.
    var narrow = testProps(&lines, true);
    narrow.row_cache = &cache;
    narrow.total_cols = 24;
    narrow.rect = .{ .x = 0, .y = 0, .w = 24 * 8, .h = 320 };
    const w2 = build(narrow, bufs.scratch());

    try testing.expect(w2.total_visual_rows > w1.total_visual_rows);
}

test "랩을 끄면 캐시를 다시 센다 — 조각이 사라진다" {
    var bufs: TestBuffers = .{};
    const long = "x" ** 200;
    const lines = [_][]const u8{ long, long };
    var prefix: [lines.len + 1]u32 = undefined;
    var cache: RowCache = .{ .prefix = &prefix };

    var wrapped = testProps(&lines, true);
    wrapped.row_cache = &cache;
    const on = build(wrapped, bufs.scratch());

    var flat = testProps(&lines, false);
    flat.row_cache = &cache;
    const off = build(flat, bufs.scratch());

    try testing.expect(on.total_visual_rows > lines.len); // 켰을 때는 접혔고
    try testing.expectEqual(@as(u32, lines.len), off.total_visual_rows); // 끄면 줄마다 한 행이다
}

test "캐시 자리가 모자라면 예전 경로로 내려간다 — 없는 것보다 낫지만 전제는 아니다" {
    var bufs: TestBuffers = .{};
    const lines = [_][]const u8{ "one", "two", "three" };
    // 줄 수 + 1이 필요한데 하나 모자라게 준다.
    var prefix: [lines.len]u32 = undefined;
    var cache: RowCache = .{ .prefix = &prefix };
    var props = testProps(&lines, false);
    props.row_cache = &cache;

    const w = build(props, bufs.scratch());
    try testing.expectEqual(@as(u32, lines.len), w.total_visual_rows); // 답은 그대로다
    try testing.expect(!cache.filled); // 자리가 없으니 채우지도 않았다
}

test "hold를 켜면 폭이 바뀌어도 다시 세지 않는다 — §2.1 저하 동작" {
    var bufs: TestBuffers = .{};
    const long = "x" ** 200;
    const lines = [_][]const u8{ long, long };
    var prefix: [lines.len + 1]u32 = undefined;
    var cache: RowCache = .{ .prefix = &prefix };

    var wide = testProps(&lines, true);
    wide.row_cache = &cache;
    const before = build(wide, bufs.scratch());

    // 드래그가 시작됐다 — 폭이 바뀌어도 옛 값을 그대로 쓴다.
    cache.hold = true;
    var narrow = testProps(&lines, true);
    narrow.row_cache = &cache;
    narrow.total_cols = 24;
    narrow.rect = .{ .x = 0, .y = 0, .w = 24 * 8, .h = 320 };
    const held = build(narrow, bufs.scratch());
    try testing.expectEqual(before.total_visual_rows, held.total_visual_rows);

    // 드래그가 끝났다 — 같은 폭이지만 이번에는 정확히 센다.
    cache.hold = false;
    const settled = build(narrow, bufs.scratch());
    try testing.expect(settled.total_visual_rows > before.total_visual_rows);
}

test "hold여도 아직 안 채워진 캐시는 센다 — 보여 줄 직전 값이 없다" {
    var bufs: TestBuffers = .{};
    const long = "x" ** 200;
    const lines = [_][]const u8{ long, long };
    var prefix: [lines.len + 1]u32 = undefined;
    var cache: RowCache = .{ .prefix = &prefix, .hold = true };
    var props = testProps(&lines, true);
    props.row_cache = &cache;

    const w = build(props, bufs.scratch());
    try testing.expect(cache.filled); // 저하하지 않고 채웠다
    try testing.expect(w.total_visual_rows > lines.len); // 그래서 막대가 맞다
}

test "hold 중 문서가 짧아지면 저하하지 않는다 — 옛 접두합이 지금 문서를 못 덮는다" {
    var bufs: TestBuffers = .{};
    const long = "x" ** 200;
    const four = [_][]const u8{ long, long, long, long };
    var prefix: [four.len + 1]u32 = undefined;
    var cache: RowCache = .{ .prefix = &prefix };

    var full = testProps(&four, true);
    full.row_cache = &cache;
    _ = build(full, bufs.scratch());

    // 접힘 등으로 보이는 줄이 줄었다. hold여도 옛 값을 쓰면 안 되는 자리다.
    cache.hold = true;
    const two = [_][]const u8{ long, long };
    var fewer = testProps(&two, true);
    fewer.row_cache = &cache;
    const w = build(fewer, bufs.scratch());
    try testing.expectEqual(cache.prefix[two.len], w.total_visual_rows); // 지금 문서 기준으로 다시 셌다
    try testing.expectEqual(@as(usize, two.len), cache.lines_len);
}

test "막대 위치도 캐시에서 나온다 — 문서 중간에서도 같은 답이다" {
    var bufs: TestBuffers = .{};
    const long = "x" ** 200;
    // **문서가 화면보다 확실히 커야 한다** — 다 들어가면 막대가 아예 없어(`scrollbar == null`) 이
    // 테스트가 아무것도 비교하지 못한다.
    const lines = [_][]const u8{ long, long, long, long, long, long, long, long, "tail" };

    var mid_plain = testProps(&lines, true);
    mid_plain.first_line = 2;
    const without = build(mid_plain, bufs.scratch());

    var prefix: [lines.len + 1]u32 = undefined;
    var cache: RowCache = .{ .prefix = &prefix };
    var mid_cached = testProps(&lines, true);
    mid_cached.first_line = 2;
    mid_cached.row_cache = &cache;
    const with = build(mid_cached, bufs.scratch());

    // 막대 위치는 `first_visual_row`에서 나오고 그것이 op 좌표에 실린다 — 기하로 비교한다.
    try testing.expect(without.scrollbar != null);
    try testing.expect(with.scrollbar != null);
    try testing.expectEqual(without.scrollbar.?.thumb_y, with.scrollbar.?.thumb_y);
    try testing.expectEqual(without.scrollbar.?.thumb_h, with.scrollbar.?.thumb_h);
}

test "점진 계수: 한 프레임에 다 세지 않고 이어서 완성한다 (§2.1)" {
    var bufs: TestBuffers = .{};
    const long = "x" ** 200;
    // chunk보다 확실히 긴 문서라야 나뉘는 것이 보인다.
    const n = count_chunk_lines + 100;
    var lines_buf: [count_chunk_lines + 100][]const u8 = undefined;
    for (&lines_buf) |*l| l.* = long;
    const lines = lines_buf[0..n];

    var prefix: [count_chunk_lines + 101]u32 = undefined;
    var cache: RowCache = .{ .prefix = &prefix };
    var props = testProps(lines, true);
    props.row_cache = &cache;

    const first = build(props, bufs.scratch());
    try testing.expectEqual(count_chunk_lines, cache.filled_upto); // 딱 한 몫만 셌다

    // 아직 안 센 줄은 한 행으로 치므로 **실제보다 짧다** — 반대로 나오면 막대가 문서 밖을 가리킨다.
    const second = build(props, bufs.scratch());
    try testing.expectEqual(n, cache.filled_upto); // 두 번째에 완성
    try testing.expect(second.total_visual_rows > first.total_visual_rows);

    // 완성 뒤에는 값이 안정된다(다시 세지 않는다).
    const third = build(props, bufs.scratch());
    try testing.expectEqual(second.total_visual_rows, third.total_visual_rows);
    try testing.expectEqual(n, cache.filled_upto);
}

test "점진 계수: 조건이 갈리면 진행도를 0으로 되돌리고 다시 시작한다" {
    var bufs: TestBuffers = .{};
    const long = "x" ** 200;
    const n = count_chunk_lines + 100;
    var lines_buf: [count_chunk_lines + 100][]const u8 = undefined;
    for (&lines_buf) |*l| l.* = long;
    const lines = lines_buf[0..n];

    var prefix: [count_chunk_lines + 101]u32 = undefined;
    var cache: RowCache = .{ .prefix = &prefix };
    var props = testProps(lines, true);
    props.row_cache = &cache;
    _ = build(props, bufs.scratch());
    _ = build(props, bufs.scratch());
    try testing.expectEqual(n, cache.filled_upto);

    // 폭이 바뀌었다 — 옛 계수는 무효다.
    var narrow = testProps(lines, true);
    narrow.row_cache = &cache;
    narrow.total_cols = 24;
    narrow.rect = .{ .x = 0, .y = 0, .w = 24 * 8, .h = 320 };
    _ = build(narrow, bufs.scratch());
    try testing.expectEqual(count_chunk_lines, cache.filled_upto); // 처음부터 다시, 한 몫만
}

test "점진 계수: hold 중에는 진행하지 않는다 — 드래그가 끝나야 센다" {
    var bufs: TestBuffers = .{};
    const long = "x" ** 200;
    const n = count_chunk_lines + 100;
    var lines_buf: [count_chunk_lines + 100][]const u8 = undefined;
    for (&lines_buf) |*l| l.* = long;
    const lines = lines_buf[0..n];

    var prefix: [count_chunk_lines + 101]u32 = undefined;
    var cache: RowCache = .{ .prefix = &prefix };
    var props = testProps(lines, true);
    props.row_cache = &cache;
    _ = build(props, bufs.scratch()); // 한 몫 셌다
    const at_hold_start = cache.filled_upto;

    // 드래그가 시작됐다 — 폭이 바뀌어도 옛 결과를 쓰고 진행도 하지 않는다.
    cache.hold = true;
    var narrow = testProps(lines, true);
    narrow.row_cache = &cache;
    narrow.total_cols = 24;
    narrow.rect = .{ .x = 0, .y = 0, .w = 24 * 8, .h = 320 };
    _ = build(narrow, bufs.scratch());
    _ = build(narrow, bufs.scratch());
    try testing.expectEqual(at_hold_start, cache.filled_upto); // 그대로다

    // 놓으면 새 폭으로 처음부터 다시 시작한다.
    cache.hold = false;
    _ = build(narrow, bufs.scratch());
    try testing.expectEqual(count_chunk_lines, cache.filled_upto);
}

test "배경이 맨 앞에 온다 — painter 순서" {
    var bufs: TestBuffers = .{};
    const w = build(testProps(&.{ "one", "two" }, false), bufs.scratch());
    try testing.expect(w.ops >= 2);
    // 첫 op이 배경 quad가 아니면 글자가 덮인다.
    try testing.expect(bufs.ops[0] == .quad);
}

test "랩된 줄 다음의 번호가 본문과 같은 행에 선다 — gutter가 본문 배치를 따른다" {
    var bufs: TestBuffers = .{};
    // 뷰 폭보다 긴 줄 하나 + 짧은 줄 하나. 앞 줄이 여러 시각 행으로 접히므로, 뒷 줄의 번호는
    // **그 조각들 아래**에 와야 한다. gutter가 논리 줄로 제 행을 세면 번호가 위로 올라온다.
    //
    // **`visual_rows` 배열을 직접 보면 안 된다** — 그것은 본문이 채운 것이라 gutter를 망가뜨려도
    // 그대로다(적대적 검증이 그 뮤턴트를 통과시켰다). gutter가 실제로 그린 op의 y를 본다.
    const long = "x" ** 200;
    const props = testProps(&.{ long, "second" }, true);
    const w = build(props, bufs.scratch());
    try testing.expect(w.visual_rows > 2); // 앞 줄이 실제로 접혔다

    const layout = geometry.compute(props.total_cols, props.total_lines, .{});
    const content_start_px = props.rect.x + @as(i32, layout.content.start) * @as(i32, props.cell_w_px);
    var lowest_gutter_y: i32 = props.rect.y;
    var gutter_ops: usize = 0;
    for (bufs.ops[0..w.ops]) |op| {
        if (op == .text and op.text.origin.x < content_start_px) {
            gutter_ops += 1;
            lowest_gutter_y = @max(lowest_gutter_y, op.text.origin.y);
        }
    }
    try testing.expectEqual(@as(usize, 2), gutter_ops); // 논리 줄 둘 = 번호 둘(이어진 조각은 비운다)

    // 마지막 번호(둘째 줄)는 앞 줄의 조각들 **아래**에 선다.
    const expected_y = props.rect.y + @as(i32, @intCast(w.visual_rows - 1)) * @as(i32, props.cell_h_px);
    try testing.expectEqual(expected_y, lowest_gutter_y);
}

/// gutter가 실제로 줄 번호를 그렸는가. **본문 op과 구별해야 한다** — 둘 다 `.text`라서 개수만
/// 세면 gutter가 통째로 죽어도 본문 op이 그 자리를 메워 통과한다(적대적 검증이 그 뮤턴트를
/// 통과시켰다). gutter는 본문 시작 열보다 **왼쪽에** 그리므로 x로 가른다.
fn gutterTextOps(ops: []const draw.Op, props: Props) usize {
    const layout = geometry.compute(props.total_cols, props.total_lines, .{});
    const content_start_px = props.rect.x + @as(i32, layout.content.start) * @as(i32, props.cell_w_px);
    var seen: usize = 0;
    for (ops) |op| {
        if (op == .text and op.text.origin.x < content_start_px) seen += 1;
    }
    return seen;
}

test "긴 줄이 저장소를 다 써도 줄 번호가 남는다 — gutter 몫을 먼저 뗀다" {
    var bufs: TestBuffers = .{};
    var s = bufs.scratch();
    // **저장소를 좁혀 경쟁을 실제로 만든다.** 넉넉하면 본문이 다 쓰고도 gutter 몫이 남아,
    // 예약을 지워도 캡처가 같다 — 그 상태로는 이 테스트가 아무것도 판정하지 못한다.
    s.text_bytes = s.text_bytes[0..256];
    // 탭이 섞인 긴 줄들. `expandTabs`가 원본을 빌리지 못해 scratch를 실제로 소비한다.
    const heavy = "\t" ** 40 ++ "y" ** 300;
    const props = testProps(&.{ heavy, heavy, heavy }, true);
    const w = build(props, s);

    try testing.expect(gutterTextOps(bufs.ops[0..w.ops], props) > 0);
}

test "저장소가 넉넉하면 둘 다 그려진다 — 위 테스트의 대조군" {
    var bufs: TestBuffers = .{};
    const props = testProps(&.{ "alpha", "beta", "gamma" }, false);
    const w = build(props, bufs.scratch());
    try testing.expect(gutterTextOps(bufs.ops[0..w.ops], props) > 0);
    // 본문도 나온다 — gutter만 남고 본문이 사라진 상태를 위 테스트와 구별한다.
    const layout = geometry.compute(props.total_cols, props.total_lines, .{});
    const content_start_px = props.rect.x + @as(i32, layout.content.start) * @as(i32, props.cell_w_px);
    var body: usize = 0;
    for (bufs.ops[0..w.ops]) |op| {
        if (op == .text and op.text.origin.x >= content_start_px) body += 1;
    }
    try testing.expect(body > 0);
}

test "막대 길이는 뷰 사각이 아니라 보이는 행 수로 판정한다" {
    var bufs: TestBuffers = .{};
    // **문서를 `visible_rows`와 `rect.h`의 사이에 둔다**(11 < 15 < 20). 뷰 사각 높이로 판정하면
    // 문서가 다 들어간다고 보아 막대가 사라지고, 보이는 행 수로 판정해야 막대가 선다 —
    // 두 값이 같으면 어느 쪽으로 재도 결과가 같아 아무것도 판정하지 못한다(적대적 검증이
    // 그 뮤턴트를 통과시켰다).
    var many: [15][]const u8 = undefined;
    for (&many) |*l| l.* = "line";
    var props = testProps(&many, false);
    props.visible_rows = 11; // rect.h(320px / 16 = 20행)보다 작다
    const w = build(props, bufs.scratch());
    try testing.expect(w.scrollbar != null);
}

test "문서가 화면에 다 들어가면 막대가 없다" {
    var bufs: TestBuffers = .{};
    const w = build(testProps(&.{ "a", "b", "c" }, false), bufs.scratch());
    try testing.expect(w.scrollbar == null);
}

test "저장소가 좁아도 죽지 않는다 — 잘린 사실을 알린다" {
    var bufs: TestBuffers = .{};
    var s = bufs.scratch();
    s.text_bytes = s.text_bytes[0..16]; // 한 줄도 못 담는 크기
    // **탭을 넣어야 본문이 실제로 잘린다.** `content`에는 *"전개가 원본과 같으면 저장소를 안 쓴다"*는
    // 빠른 길이 있어 `z`만 있는 줄은 저장소가 0이어도 온전히 그려진다 — 그래서 이 테스트가 보던
    // 절단은 사실 **gutter 쪽**이었고, 그것은 `build`가 줄마다 20바이트 여유를 요구하던 결함이었다
    // (적대적 검증 2026-08-17에 고쳤다). 그 결함을 고치자 이 케이스가 통과할 수 없게 됐다 —
    // 이름이 말하는 계약을 실제로 재현하도록 입력을 고친다.
    const long = "\t" ++ ("z" ** 500);
    const w = build(testProps(&.{ long, long }, true), s);
    try testing.expect(w.ops >= 1); // 배경은 나온다
    try testing.expect(w.truncated);
}

test "row_counts가 문서보다 짧아도 나머지를 논리 줄로 친다" {
    var bufs: TestBuffers = .{};
    var s = bufs.scratch();
    s.row_counts = s.row_counts[0..2]; // 100줄 문서에 계수 자리가 2개뿐
    var many: [100][]const u8 = undefined;
    for (&many) |*l| l.* = "line";
    var props = testProps(&many, false);
    props.visible_rows = 10;
    const w = build(props, s);
    // 못 센 98줄을 0으로 두면 문서가 다 보인다고 판정돼 막대가 사라진다.
    try testing.expect(w.scrollbar != null);
}

test "미리 센 시각 행 수를 주면 그것을 쓴다" {
    var bufs: TestBuffers = .{};
    var props = testProps(&.{ "a", "b" }, false);
    props.visible_rows = 2;
    props.total_visual_rows = 400; // 문서는 2줄인데 캐시가 400행이라고 한다
    const w = build(props, bufs.scratch());
    try testing.expect(w.scrollbar != null); // 캐시 값을 따랐다
}

test "밴드는 바뀐 줄에만 서고 빈 행에는 안 선다" {
    // **빈 행에 색을 칠하면 "그 자리에 무언가 있다"고 말하게 된다.** 좌우를 나란히 놓는 배치에서
    // 그것은 반대쪽 줄이 이 문서에도 있는 것처럼 읽힌다.
    var ops: [64]draw.Op = undefined;
    var text: [512]u8 = undefined;
    var runs: [64]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [128]u8 = undefined;

    const lines = [_][]const u8{ "keep", "gone", "", "tail" };
    const bands = [_]RowBand{ .none, .removed, .none, .none }; // 3행은 짝을 맞추려 넣은 빈 행
    const w = build(.{
        .tab_width = default_tab_width,
        .lines = &lines,
        .first_line = 0,
        .total_lines = 4,
        .row_bands = &bands,
        .visible_rows = 4,
        .wrap = false,
        .rect = .{ .x = 0, .y = 0, .w = 400, .h = 64 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 40,
        .scrollbar_gutter_px = 12,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    var band_quads: usize = 0;
    var strip_quads: usize = 0;
    for (ops[0..w.ops]) |op| {
        if (op != .quad) continue;
        const q = op.quad;
        if (q.fill_role != .diff_removed_bg and q.fill_role != .diff_added_bg) continue;
        if (q.rect.w == strip_width_px) strip_quads += 1 else band_quads += 1;
        // 밴드가 붙는 행은 **하나뿐**이다 — 줄 하나가 바뀌었다.
        try testing.expectEqual(@as(i32, 16), q.rect.y); // 두 번째 행(0-based 1 × 16px)
    }
    try testing.expectEqual(@as(usize, 1), band_quads);
    try testing.expectEqual(@as(usize, 1), strip_quads);
}

test "밴드는 스크롤을 따라간다 — 표를 절대 인덱스로 읽는다" {
    // gutter 번호에서 같은 구멍이 있었다(뷰포트 기준으로 읽으면 화면 맨 위가 늘 표의 0번이 된다).
    // 밴드가 그러면 스크롤한 비교에서 **엉뚱한 줄에 색이 깔린다** — 그것은 틀린 정보다.
    var ops: [64]draw.Op = undefined;
    var text: [512]u8 = undefined;
    var runs: [64]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [128]u8 = undefined;

    const lines = [_][]const u8{ "a", "b", "c", "d", "e" };
    const bands = [_]RowBand{ .none, .none, .none, .added, .none }; // 4번째 줄만 추가
    const w = build(.{
        .tab_width = default_tab_width,
        .lines = &lines,
        .first_line = 2, // 화면 맨 위가 문서의 3번째 줄
        .total_lines = 5,
        .row_bands = &bands,
        .visible_rows = 3,
        .wrap = false,
        .rect = .{ .x = 0, .y = 0, .w = 400, .h = 48 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 40,
        .scrollbar_gutter_px = 12,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    var found: usize = 0;
    for (ops[0..w.ops]) |op| {
        if (op != .quad or op.quad.fill_role != .diff_added_bg) continue;
        // 문서 4번째 줄 = 화면 두 번째 행(첫 행이 3번째 줄) → y = 16.
        try testing.expectEqual(@as(i32, 16), op.quad.rect.y);
        found += 1;
    }
    try testing.expectEqual(@as(usize, 2), found); // 줄 배경 + 좌측 띠
}

test "랩된 줄은 이어진 조각까지 한 색이다 — 한 줄로 읽혀야 한다" {
    var ops: [64]draw.Op = undefined;
    var text: [512]u8 = undefined;
    var runs: [64]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [256]u8 = undefined;

    // 본문 폭보다 긴 줄 하나 — 랩이 켜지면 여러 조각으로 접힌다.
    const lines = [_][]const u8{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"};
    const bands = [_]RowBand{.removed};
    const w = build(.{
        .tab_width = default_tab_width,
        .lines = &lines,
        .first_line = 0,
        .total_lines = 1,
        .row_bands = &bands,
        .visible_rows = 6,
        .wrap = true,
        .rect = .{ .x = 0, .y = 0, .w = 160, .h = 96 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 20,
        .scrollbar_gutter_px = 0,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    var rows_painted: usize = 0;
    for (ops[0..w.ops]) |op| {
        if (op != .quad or op.quad.fill_role != .diff_removed_bg) continue;
        if (op.quad.rect.w != strip_width_px) rows_painted += 1; // 줄 배경만 센다
    }
    // 접힌 조각이 둘 이상이고, **그 전부**에 색이 깔린다(한 조각만 칠하면 줄이 끊겨 보인다).
    try testing.expect(w.visual_rows > 1);
    try testing.expectEqual(w.visual_rows, rows_painted);
}

test "랩된 문서에서 막대가 시각 행 자리에 선다 — 논리 줄로 세면 위에 붙는다" {
    // 세로 스크롤이 붙기 전에는 `first_line`이 늘 0이라 이 차이가 안 보였다. 스크롤이 살아나면
    // 랩된 문서에서 막대가 실제 위치보다 **위**에 서고, 사용자는 문서 중간에서 막대를 위쪽에서 본다.
    var ops: [128]draw.Op = undefined;
    var text: [1024]u8 = undefined;
    var runs: [128]draw.Run = undefined;
    var content_rows: [32]content.Row = undefined;
    var visual_rows: [32]visual_map.VisualRow = undefined;
    var gutter_rows: [32]gutter.Row = undefined;
    var counts: [32]u32 = undefined;
    var count_scratch: [256]u8 = undefined;

    // 줄마다 본문 폭의 두 배 → 랩이 켜지면 줄당 시각 행 2개.
    const long_line = "aaaaaaaaaaaaaaaaaaaa";
    var lines_buf: [10][]const u8 = undefined;
    for (&lines_buf) |*l| l.* = long_line;

    const scratch: Scratch = .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    };
    const base: Props = .{
        .tab_width = default_tab_width,
        .lines = &lines_buf,
        .first_line = 0,
        .total_lines = lines_buf.len,
        .visible_rows = 4,
        .wrap = true,
        .rect = .{ .x = 0, .y = 0, .w = 160, .h = 64 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 10,
        .scrollbar_gutter_px = 12,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    };

    const top = build(base, scratch);
    var scrolled = base;
    scrolled.first_line = 5; // 문서의 절반 — 랩 때문에 시각 행으로는 10번째다
    const mid = build(scrolled, scratch);

    const a = top.scrollbar orelse return error.NoScrollbar;
    const b = mid.scrollbar orelse return error.NoScrollbar;
    try testing.expect(b.thumb_y > a.thumb_y);
    // **논리 줄로 세면 5/10 = 절반이 아니라 5/20 = 1/4 자리에 선다.** 그 차이를 여기서 고정한다:
    // 시각 행 기준이면 thumb이 트랙의 대략 절반 아래에 있어야 한다.
    const track_mid = a.track_y + (a.track_h - b.thumb_h) / 2;
    try testing.expect(b.thumb_y >= track_mid - 1);
}

test "밴드는 스크롤바보다 먼저 나온다 — 나중이면 막대 위에 색이 덧칠된다" {
    // 밴드는 열 폭 **전체**를 덮는다(스크롤바 gutter 포함). 순서가 뒤면 16% 색이 thumb 위에 얹혀
    // 막대가 줄무늬로 보인다. op 순서는 그대로 painter 순서다.
    var ops: [64]draw.Op = undefined;
    var text: [512]u8 = undefined;
    var runs: [64]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [128]u8 = undefined;

    const lines = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
    const bands = [_]RowBand{ .removed, .none, .none, .none, .none, .none, .none, .none };
    const w = build(.{
        .tab_width = default_tab_width,
        .lines = &lines,
        .first_line = 0,
        .total_lines = lines.len,
        .row_bands = &bands,
        .visible_rows = 3, // 문서가 화면보다 길다 → 막대가 그려진다
        .wrap = false,
        .rect = .{ .x = 0, .y = 0, .w = 400, .h = 48 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 40,
        .scrollbar_gutter_px = 12,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });
    try testing.expect(w.scrollbar != null); // 막대가 실제로 그려졌다

    var band_at: ?usize = null;
    var bar_at: ?usize = null;
    for (ops[0..w.ops], 0..) |op, i| {
        if (op != .quad) continue;
        if (op.quad.fill_role == .diff_removed_bg) {
            if (band_at == null) band_at = i;
        } else if (op.quad.fill_role != .terminal_bg) {
            if (bar_at == null) bar_at = i; // 막대(트랙·thumb)
        }
    }
    try testing.expect(band_at != null and bar_at != null);
    try testing.expect(band_at.? < bar_at.?);
}

test "막대 위치는 total_visual_rows를 받은 경로에서도 시각 행 기준이다" {
    // 그 인자는 큰 문서에서 계수를 건너뛰라고 열어 둔 것인데, 그때만 논리 줄로 되돌아가면 **바로 그
    // 문서에서** 막대가 틀린다(리뷰 지적 — 처음엔 계수 블록 안에서만 고쳤다).
    var ops: [128]draw.Op = undefined;
    var text: [1024]u8 = undefined;
    var runs: [128]draw.Run = undefined;
    var content_rows: [32]content.Row = undefined;
    var visual_rows: [32]visual_map.VisualRow = undefined;
    var gutter_rows: [32]gutter.Row = undefined;
    var counts: [32]u32 = undefined;
    var count_scratch: [256]u8 = undefined;

    var lines_buf: [10][]const u8 = undefined;
    for (&lines_buf) |*l| l.* = "aaaaaaaaaaaaaaaaaaaa"; // 본문 폭의 두 배 → 줄당 2행
    const scratch: Scratch = .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    };
    var props: Props = .{
        .tab_width = default_tab_width,
        .lines = &lines_buf,
        .first_line = 5,
        .total_lines = lines_buf.len,
        .visible_rows = 4,
        .wrap = true,
        .rect = .{ .x = 0, .y = 0, .w = 160, .h = 64 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 10,
        .scrollbar_gutter_px = 12,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    };
    // 먼저 직접 세게 한 뒤, **그 값을 그대로 먹여** 두 경로가 같은 자리에 막대를 세우는지 본다.
    // (미리 센 값을 준다는 것은 "같은 문서를 안다"는 뜻이므로, 다른 숫자를 넣고 비교하면 그건
    // 코드가 아니라 픽스처를 시험하는 것이다 — 처음에 그렇게 써서 틀렸다.)
    const counted = build(props, scratch);
    try testing.expect(counted.total_visual_rows > lines_buf.len); // 실제로 접혔다
    props.total_visual_rows = counted.total_visual_rows;
    const given = build(props, scratch);

    const a = given.scrollbar orelse return error.NoScrollbar;
    const b = counted.scrollbar orelse return error.NoScrollbar;
    // 하나만 논리 줄로 되돌아가면 여기서 갈린다.
    try testing.expectEqual(b.thumb_y, a.thumb_y);
}

test "바뀐 글자만 한 겹 더 진하다 — 줄 밴드 위에 그 범위만 얹는다" {
    var ops: [64]draw.Op = undefined;
    var text: [512]u8 = undefined;
    var runs: [64]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [256]u8 = undefined;

    const lines = [_][]const u8{"const a = 1;"};
    const bands = [_]RowBand{.removed};
    const marks_row = [_]Mark{.{ .start = 6, .len = 1 }}; // "a"
    const marks = [_][]const Mark{&marks_row};
    const w = build(.{
        .tab_width = default_tab_width,
        .lines = &lines,
        .first_line = 0,
        .total_lines = 1,
        .row_bands = &bands,
        .row_marks = &marks,
        .visible_rows = 1,
        .wrap = false,
        .rect = .{ .x = 0, .y = 0, .w = 400, .h = 16 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 40,
        .scrollbar_gutter_px = 12,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    var mark: ?draw.Op.Quad = null;
    for (ops[0..w.ops]) |op| {
        if (op != .quad or op.quad.fill_role != .diff_removed_bg) continue;
        if (op.quad.alpha == mark_alpha) mark = op.quad;
    }
    const m = mark orelse return error.NoMark;
    // 일곱 번째 글자 하나 = 본문 시작 열 + 6, 한 칸.
    const layout = geometry.compute(40, 1, .{});
    try testing.expectEqual(@as(i32, (@as(i32, layout.contentLeft()) + 6) * 8), m.rect.x);
    try testing.expectEqual(@as(u32, 8), m.rect.w);
    try testing.expect(mark_alpha > band_alpha); // 줄보다 진하다(그 차이가 신호다)
}

test "탭이 있어도 강조가 글자 위에 선다 — 열은 전개 뒤 기준이다" {
    var ops: [64]draw.Op = undefined;
    var text: [512]u8 = undefined;
    var runs: [64]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [256]u8 = undefined;

    const lines = [_][]const u8{"\tx"}; // 탭(4열) 뒤 x
    const bands = [_]RowBand{.added};
    const marks_row = [_]Mark{.{ .start = 1, .len = 1 }}; // "x"
    const marks = [_][]const Mark{&marks_row};
    const w = build(.{
        .lines = &lines,
        .first_line = 0,
        .total_lines = 1,
        .row_bands = &bands,
        .row_marks = &marks,
        .visible_rows = 1,
        .wrap = false,
        .tab_width = 4,
        .rect = .{ .x = 0, .y = 0, .w = 400, .h = 16 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 40,
        .scrollbar_gutter_px = 12,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });
    for (ops[0..w.ops]) |op| {
        if (op != .quad or op.quad.alpha != mark_alpha) continue;
        const layout = geometry.compute(40, 1, .{});
        try testing.expectEqual(@as(i32, (@as(i32, layout.contentLeft()) + 4) * 8), op.quad.rect.x); // 탭이 편 4열 뒤
        return;
    }
    return error.NoMark;
}

test "마크가 저장소보다 많으면 앞에서부터 그리고 죽지 않는다" {
    // 열 계산용 저장소(`count_scratch`)를 마크 쌍이 나눠 쓴다. 모자랄 때 죽거나 남의 자리를 쓰면
    // 안 되고, **앞에서부터 담을 수 있는 만큼**만 그린다(잘림은 이 컴포넌트의 기존 규율이다).
    var ops: [256]draw.Op = undefined;
    var text: [2048]u8 = undefined;
    var runs: [256]draw.Run = undefined;
    var content_rows: [8]content.Row = undefined;
    var visual_rows: [8]visual_map.VisualRow = undefined;
    var gutter_rows: [8]gutter.Row = undefined;
    var counts: [8]u32 = undefined;
    var count_scratch: [16]u8 = undefined; // u32 넷 = 마크 두 쌍만 들어간다

    const line = "abcdefghijklmnop";
    const lines = [_][]const u8{line};
    const bands = [_]RowBand{.added};
    var marks_row: [8]Mark = undefined;
    for (&marks_row, 0..) |*m, i| m.* = .{ .start = @intCast(i * 2), .len = 1 };
    const marks = [_][]const Mark{&marks_row};

    const w = build(.{
        .tab_width = default_tab_width,
        .lines = &lines,
        .first_line = 0,
        .total_lines = 1,
        .row_bands = &bands,
        .row_marks = &marks,
        .visible_rows = 1,
        .wrap = false,
        .rect = .{ .x = 0, .y = 0, .w = 400, .h = 16 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 40,
        .scrollbar_gutter_px = 12,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    var painted: usize = 0;
    for (ops[0..w.ops]) |op| {
        if (op == .quad and op.quad.alpha == mark_alpha) painted += 1;
    }
    // 여덟 개를 요구했지만 저장소가 두 쌍뿐이라 둘만 그린다 — 그리고 죽지 않는다.
    try testing.expectEqual(@as(usize, 2), painted);
}

test "가로로 밀면 강조도 함께 밀리고 본문 밖은 잘린다" {
    // 지금 제품은 `first_col`이 0 고정이지만 컴포넌트는 그 축을 이미 받는다. 여기서 안 막으면
    // 가로 스크롤이 붙는 순간 강조가 gutter나 옆 열을 침범한다.
    var ops: [256]draw.Op = undefined;
    var text: [2048]u8 = undefined;
    var runs: [256]draw.Run = undefined;
    var content_rows: [8]content.Row = undefined;
    var visual_rows: [8]visual_map.VisualRow = undefined;
    var gutter_rows: [8]gutter.Row = undefined;
    var counts: [8]u32 = undefined;
    var count_scratch: [256]u8 = undefined;

    const line = "0123456789abcdef";
    const lines = [_][]const u8{line};
    const bands = [_]RowBand{.added};
    const marks_row = [_]Mark{ .{ .start = 1, .len = 1 }, .{ .start = 12, .len = 2 } };
    const marks = [_][]const Mark{&marks_row};
    const layout = geometry.compute(12, 1, .{});

    const w = build(.{
        .tab_width = default_tab_width,
        .lines = &lines,
        .first_line = 0,
        .first_col = 10, // 열 10부터 보인다 — 앞의 마크는 화면 밖이다
        .total_lines = 1,
        .row_bands = &bands,
        .row_marks = &marks,
        .visible_rows = 1,
        .wrap = false,
        .rect = .{ .x = 0, .y = 0, .w = 96, .h = 16 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 12,
        .scrollbar_gutter_px = 12,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    var found: usize = 0;
    for (ops[0..w.ops]) |op| {
        if (op != .quad or op.quad.alpha != mark_alpha) continue;
        found += 1;
        // 화면 밖(열 1)의 마크는 안 그려지고, 열 12~13짜리는 밀린 만큼 앞으로 온다.
        try testing.expectEqual(@as(i32, (@as(i32, layout.contentLeft()) + 2) * 8), op.quad.rect.x);
        // 본문 폭 밖으로 넘지 않는다.
        try testing.expect(op.quad.rect.x + @as(i32, @intCast(op.quad.rect.w)) <= @as(i32, (@as(i32, layout.contentLeft()) + @as(i32, layout.content.width)) * 8));
    }
    try testing.expectEqual(@as(usize, 1), found);
}

test "랩된 줄: 마크가 어느 조각에 있든 그 조각에 강조가 선다" {
    // **옛 이름은 "첫 조각에만 선다"였고 그 한계를 고정한다고 적혀 있었다.** 한계는 §4.1g ①이
    // 없앴다(`VisualRow.start_col`).
    //
    // **그런데 그 테스트는 애초에 판정력이 없었다.** `total_cols = 10`에 gutter가 8열을 먹어 본문이
    // **2열**이었고, 20글자 줄이 조각 10개가 되며 `visible_rows = 6`이라 뒤쪽 마크(byte 15 = 8번째
    // 조각)가 **화면 밖**이었다 — 옛 동작이든 새 동작이든 y=0 하나만 나왔다. 이름이 말하는 것을
    // 확인하지 못하는 테스트였고, 그래서 조건을 고쳐 **마크 둘이 서로 다른 보이는 조각**에 오게 한다.
    var ops: [256]draw.Op = undefined;
    var text: [2048]u8 = undefined;
    var runs: [256]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [256]u8 = undefined;

    // 본문이 좁아 한 줄이 여러 조각으로 접힌다. 마크를 **앞뒤 양쪽**에 둔다.
    const line = "aaaaaaaaaaaaaaaaaaaa";
    const lines = [_][]const u8{line};
    const bands = [_]RowBand{.removed};
    const marks_row = [_]Mark{ .{ .start = 1, .len = 1 }, .{ .start = 15, .len = 1 } };
    const marks = [_][]const Mark{&marks_row};

    const w = build(.{
        .tab_width = default_tab_width,
        .lines = &lines,
        .first_line = 0,
        .total_lines = 1,
        .row_bands = &bands,
        .row_marks = &marks,
        .visible_rows = 6,
        .wrap = true,
        .rect = .{ .x = 0, .y = 0, .w = 160, .h = 96 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 20,
        .scrollbar_gutter_px = 0,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    try testing.expect(w.visual_rows > 1); // 실제로 접혔다
    var mark_rows: [8]i32 = undefined;
    var n: usize = 0;
    for (ops[0..w.ops]) |op| {
        if (op != .quad or op.quad.alpha != mark_alpha) continue;
        if (n < mark_rows.len) {
            mark_rows[n] = op.quad.rect.y;
            n += 1;
        }
    }
    // **강조가 서로 다른 행에 선다** — 마크 둘이 다른 조각에 있으므로. 옛 계약에서는 뒤쪽이
    // 통째로 빠져 y가 전부 0이었다.
    try testing.expect(n >= 2);
    var saw_first = false;
    var saw_later = false;
    for (mark_rows[0..n]) |y| {
        if (y == 0) saw_first = true;
        if (y > 0) saw_later = true;
    }
    try testing.expect(saw_first);
    try testing.expect(saw_later);
}

test "강조도 스크롤을 따라간다 — 표와 줄을 같은 절대 인덱스로 읽는다" {
    // 밴드에서 같은 종류의 구멍이 있었다(뷰포트 기준으로 읽으면 화면 맨 위가 늘 0번이 된다). 마크는
    // 거기에 **줄 본문 조회가 하나 더** 붙는다 — `props.lines[idx]`. 둘 중 하나만 어긋나도 강조가
    // 엉뚱한 줄에, 혹은 맞는 줄의 엉뚱한 열에 선다.
    var ops: [64]draw.Op = undefined;
    var text: [512]u8 = undefined;
    var runs: [64]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [256]u8 = undefined;

    // 줄마다 길이가 다르다 — 표를 잘못 읽으면 열이 티 나게 어긋난다.
    const lines = [_][]const u8{ "a", "bb", "cccc", "ddddddd", "e" };
    const bands = [_]RowBand{ .none, .none, .none, .added, .none };
    const marks_3 = [_]Mark{.{ .start = 5, .len = 2 }}; // "ddddddd"의 6~7번째 글자
    const marks = [_][]const Mark{ &.{}, &.{}, &.{}, &marks_3, &.{} };

    const w = build(.{
        .tab_width = default_tab_width,
        .lines = &lines,
        .first_line = 2, // 화면 맨 위가 문서의 3번째 줄
        .total_lines = lines.len,
        .row_bands = &bands,
        .row_marks = &marks,
        .visible_rows = 3,
        .wrap = false,
        .rect = .{ .x = 0, .y = 0, .w = 400, .h = 48 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 40,
        .scrollbar_gutter_px = 12,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    const layout = geometry.compute(40, lines.len, .{});
    var found: usize = 0;
    for (ops[0..w.ops]) |op| {
        if (op != .quad or op.quad.alpha != mark_alpha) continue;
        found += 1;
        // 문서 4번째 줄 = 화면 두 번째 행(첫 행이 3번째 줄) → y = 16.
        try testing.expectEqual(@as(i32, 16), op.quad.rect.y);
        // 그 줄의 byte 5 = 열 5(ASCII) → 본문 시작 열 + 5.
        try testing.expectEqual(@as(i32, (@as(i32, layout.contentLeft()) + 5) * 8), op.quad.rect.x);
        try testing.expectEqual(@as(u32, 2 * 8), op.quad.rect.w);
    }
    try testing.expectEqual(@as(usize, 1), found);
}

test "가로 막대는 넘칠 때만, 그리고 본문 아래 자리에 그려진다" {
    // **컴포넌트가 통과해도 배선이 빠지면 화면에는 안 나온다** — 접힘에서 같은 자리를 겪었다.
    // 여기서는 `build`가 실제로 op을 내는지, 그리고 그 op이 본문 **아래**에 있는지 본다.
    var ops: [64]draw.Op = undefined;
    var text: [512]u8 = undefined;
    var runs: [64]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [128]u8 = undefined;

    const lines = [_][]const u8{ "aaa", "bbb" };
    const scratch: Scratch = .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    };
    const base: Props = .{
        .tab_width = default_tab_width,
        .lines = &lines,
        .first_line = 0,
        .total_lines = lines.len,
        .visible_rows = 2,
        .wrap = false,
        .rect = .{ .x = 0, .y = 0, .w = 400, .h = 48 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 40,
        .scrollbar_gutter_px = 12,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    };

    // ① 가장 긴 줄을 아직 안 셌다(`null`) — 그리지 않는다. 길이를 모르는데 막대를 두면 거짓말이다.
    const w_unknown = build(base, scratch);

    // ② 넘친다 — 막대가 하나 더 나온다.
    var p_wide = base;
    p_wide.content_max_cols = 500; // 본문은 40열 남짓이다
    const w_wide = build(p_wide, scratch);
    try testing.expect(w_wide.ops > w_unknown.ops);

    // 그 막대는 **본문 아래**에 있다 — 마지막 줄을 덮으면 §3.8이 막으려는 "화면과 내용이 다른" 상태다.
    const body_bottom: i32 = @as(i32, base.rect.y) + @as(i32, base.visible_rows) * @as(i32, base.cell_h_px);
    var found_below = false;
    for (ops[0..w_wide.ops]) |op| {
        if (op != .quad) continue;
        if (op.quad.fill_role == .terminal_bg) continue;
        if (op.quad.rect.y >= body_bottom) found_below = true;
    }
    try testing.expect(found_below);

    // ③ 랩이 켜지면 넘칠 것이 없다 — 축 자체가 사라진다(§4).
    var p_wrap = p_wide;
    p_wrap.wrap = true;
    const w_wrap = build(p_wrap, scratch);
    try testing.expect(w_wrap.ops <= w_unknown.ops + 1); // 가로 막대 몫이 없다

    // ④ 판정 규칙은 한 곳이다 — 호출자가 높이를 줄일 때 쓰는 답과 같아야 한다.
    try testing.expect(showsHorizontalBar(false, 500, 40));
    try testing.expect(!showsHorizontalBar(true, 500, 40)); // 랩
    try testing.expect(!showsHorizontalBar(false, null, 40)); // 안 셌다
    try testing.expect(!showsHorizontalBar(false, 40, 40)); // 딱 들어간다
}

test "줄 끝까지 선택해도 띠가 선다 — 캡처가 잡은 자리 (§4.1g)" {
    // **캡처가 아니었으면 못 봤다.** Lab 픽스처가 우연히 `start + len == 줄 길이`였고, 그 행만
    // 띠가 **통째로 안 그려졌다**(다른 두 행은 멀쩡했다). 줄 끝까지 드래그하는 것은 흔한 동작이라
    // 그대로 두면 "가끔 선택이 안 보인다"가 된다.
    var ops: [128]draw.Op = undefined;
    var text: [1024]u8 = undefined;
    var runs: [128]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [512]u8 = undefined;

    const lines = [_][]const u8{"fn render(self: *View) void {"}; // 29 byte
    const to_eol = [_]Mark{.{ .start = 10, .len = 19 }}; // 10 + 19 == 29 = 줄 끝
    const sel = [_][]const Mark{&to_eol};

    const total_cols: u16 = 48;
    const w = build(.{
        .lines = &lines,
        .first_line = 0,
        .total_lines = 1,
        .selection_marks = &sel,
        .visible_rows = 2,
        .wrap = false,
        .tab_width = default_tab_width,
        .rect = .{ .x = 0, .y = 0, .w = @as(u32, total_cols) * 8, .h = 32 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = total_cols,
        .scrollbar_gutter_px = 0,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    var found: ?draw.Op = null;
    for (ops[0..w.ops]) |op| {
        if (op == .quad and op.quad.fill_role == .selection) found = op;
    }
    const q = (found orelse return error.SelectionToEndOfLineNotPainted).quad;
    try std.testing.expectEqual(@as(u32, 19 * 8), q.rect.w); // 10열~29열 = 19칸
}

test "선택 띠가 diff가 아닌 본문에도 서고, 가로 스크롤 밖은 잘린다 (§4.1g)" {
    // **`row_bands`가 없어도 서야 한다.** 선택은 diff와 무관하고, `paintBands`는 밴드가 없으면
    // 통째로 돌아가므로 그 함수에 얹으면 단일 편집기에서 선택이 영영 안 보인다.
    var ops: [128]draw.Op = undefined;
    var text: [1024]u8 = undefined;
    var runs: [128]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [512]u8 = undefined;

    const lines = [_][]const u8{ "hello world", "second line" };
    const sel_row0 = [_]Mark{.{ .start = 6, .len = 5 }}; // "world"
    const sel_none = [_]Mark{};
    const sel = [_][]const Mark{ &sel_row0, &sel_none };

    const total_cols: u16 = 24;
    const scratch: Scratch = .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    };
    const base_props: Props = .{
        .lines = &lines,
        .first_line = 0,
        .total_lines = 2,
        .visible_rows = 4,
        .wrap = false,
        .tab_width = default_tab_width,
        .rect = .{ .x = 0, .y = 0, .w = @as(u32, total_cols) * 8, .h = 64 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = total_cols,
        .scrollbar_gutter_px = 0,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    };

    // 선택이 없을 때의 op 수를 기준선으로 삼는다.
    const without = build(base_props, scratch);

    var with_props = base_props;
    with_props.selection_marks = &sel;
    const with = build(with_props, scratch);

    // **띠 하나가 늘어야 한다** — 첫 줄에만 선택이 있다.
    try std.testing.expectEqual(without.ops + 1, with.ops);

    // 그 op이 selection 색이고, 본문 시작 열 뒤에 선다.
    var found: ?draw.Op = null;
    for (ops[0..with.ops]) |op| {
        if (op == .quad and op.quad.fill_role == .selection) found = op;
    }
    const q = (found orelse return error.NoSelectionQuad).quad;
    try std.testing.expectEqual(@as(u32, 5 * 8), q.rect.w); // "world" 다섯 칸
    try std.testing.expect(q.rect.x > 0); // gutter 위가 아니다

    // **가로 스크롤 밖은 잘린다.** 8열을 밀면 "world"(6~10열)가 왼쪽 밖으로 나간다.
    var scrolled = with_props;
    scrolled.first_col = 12;
    const cut = build(scrolled, scratch);
    var still: bool = false;
    for (ops[0..cut.ops]) |op| {
        if (op == .quad and op.quad.fill_role == .selection) still = true;
    }
    try std.testing.expect(!still);
}

test "랩된 줄의 이어진 조각에도 글자 강조가 선다 — 오래 비어 있던 자리 (§4.1g)" {
    // **`v.piece != 0`이면 통째로 건너뛰던 자리다.** 조각이 어디서 시작하는지 몰라서였고, 이제
    // `VisualRow.start_col`이 그 값을 실어 온다. 이 테스트가 없으면 그 필드가 실려 있어도 아무도
    // 안 쓰는 상태로 조용히 돌아갈 수 있다.
    var ops: [128]draw.Op = undefined;
    var text: [1024]u8 = undefined;
    var runs: [128]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [512]u8 = undefined;

    // 본문 폭보다 긴 줄 하나 — 랩을 켜면 조각 둘이 된다.
    const lines = [_][]const u8{"aaaaaaaaaabbbbbbbbbb"};
    const bands = [_]RowBand{.removed};
    // **두 번째 조각 안**의 글자를 강조한다(byte 12~13). 첫 조각만 그리던 시절에는 이것이 안 나왔다.
    const marks_row = [_]Mark{.{ .start = 12, .len = 2 }};
    const marks = [_][]const Mark{&marks_row};

    const total_cols: u16 = 20; // gutter를 빼면 본문이 10열 남짓 — 20글자 줄이 두 조각이 된다
    const w = build(.{
        .tab_width = default_tab_width,
        .lines = &lines,
        .first_line = 0,
        .total_lines = 1,
        .row_bands = &bands,
        .row_marks = &marks,
        .visible_rows = 4,
        .wrap = true,
        .rect = .{ .x = 0, .y = 0, .w = @as(u32, total_cols) * 8, .h = 64 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = total_cols,
        .scrollbar_gutter_px = 0,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    // 전제: 실제로 두 조각으로 접혔다.
    try testing.expect(w.visual_rows >= 2);
    try testing.expectEqual(@as(u32, 0), visual_rows[0].piece);
    try testing.expectEqual(@as(u32, 1), visual_rows[1].piece);
    // 두 번째 조각은 첫 조각 폭만큼 밀린 열에서 시작한다.
    try testing.expect(visual_rows[1].start_col > 0);

    // 강조가 **두 번째 조각의 행**에 섰는가. 그 행의 y는 첫 행 아래다.
    var found_on_second_row = false;
    for (ops[0..w.ops]) |op| {
        if (op != .quad or op.quad.fill_role != .diff_removed_bg) continue;
        if (op.quad.alpha != mark_alpha) continue;
        if (op.quad.rect.y >= 16) found_on_second_row = true;
    }
    try testing.expect(found_on_second_row);
}

test "CRT1 커서 수만큼 막대가 서고, blink가 꺼지면 하나도 안 선다 (§3.2)" {
    // **커서가 여럿인데 하나만 그려도 화면은 "커서가 있다"로 보인다** — 그 상태에서 타이핑하면
    // 안 보이는 자리에도 글자가 들어간다. 그래서 **수를 센다**(대입이면 중복·누락을 못 잡는다는
    // 것을 `SRCH1`이 뮤턴트로 확인했다).
    var ops: [128]draw.Op = undefined;
    var text: [1024]u8 = undefined;
    var runs: [128]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [512]u8 = undefined;

    const lines = [_][]const u8{"abc def ghi"};
    const row_carets = [_]u32{ 0, 4, 8 };
    const carets = [_][]const u32{&row_carets};
    const total_cols: u16 = 40;

    for ([_]bool{ true, false }) |visible| {
        const w = build(.{
            .lines = &lines,
            .first_line = 0,
            .total_lines = 1,
            .carets = &carets,
            .caret_visible = visible,
            .visible_rows = 2,
            .wrap = false,
            .tab_width = default_tab_width,
            .rect = .{ .x = 0, .y = 0, .w = @as(u32, total_cols) * 8, .h = 32 },
            .cell_w_px = 8,
            .cell_h_px = 16,
            .font_px = 16,
            .total_cols = total_cols,
            .scrollbar_gutter_px = 0,
            .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
        }, .{
            .ops = &ops,
            .text_bytes = &text,
            .runs = &runs,
            .content_rows = &content_rows,
            .visual_rows = &visual_rows,
            .gutter_rows = &gutter_rows,
            .row_counts = &counts,
            .count_scratch = &count_scratch,
        });

        var n: usize = 0;
        var xs: [8]i32 = undefined;
        for (ops[0..w.ops]) |op| {
            if (op != .quad) continue;
            if (op.quad.fill_role != .cursor) continue;
            if (n < xs.len) xs[n] = op.quad.rect.x;
            n += 1;
        }
        if (!visible) {
            // **blink가 꺼지면 하나도 없다** — 안 사라지면 커서가 아니라 그냥 막대다.
            try std.testing.expectEqual(@as(usize, 0), n);
            continue;
        }
        try std.testing.expectEqual(@as(usize, 3), n);
        // 셋이 서로 다른 자리다(한 자리에 겹쳐 그리면 수는 맞고 화면은 틀린다).
        try std.testing.expect(xs[0] != xs[1] and xs[1] != xs[2]);
        // 열 간격이 셀 폭의 배수다 — 0·4·8열이므로 32px 간격이다.
        try std.testing.expectEqual(@as(i32, 32), xs[1] - xs[0]);
        try std.testing.expectEqual(@as(i32, 32), xs[2] - xs[1]);
        // **폭은 셀 폭이 아니라 막대 폭이다.**
        for (ops[0..w.ops]) |op| {
            if (op == .quad and op.quad.fill_role == .cursor) {
                try std.testing.expectEqual(caret_width_px, op.quad.rect.w);
                try std.testing.expectEqual(@as(u32, 16), op.quad.rect.h); // 셀 높이
            }
        }
    }
}

test "CRT3 랩이 걸린 줄에서 caret은 한 번만, 제 행에 선다 (§4.1g)" {
    // **랩에서 caret이 어느 행에 서는지 아무도 재지 않았다**(적대적 검증 2026-08-26 — 행 앞을
    // 거르는 `col < row.start_col`을 없앤 뮤턴트가 살아남았다). 거르지 않으면 **같은 caret이
    // 그 줄의 모든 시각 행에 선다** — 화면에는 커서가 여러 개로 보이고, 어느 것이 진짜인지
    // 알 수 없다.
    //
    // 이음매 선택(위 행 끝이냐 아래 행 머리냐)은 아직 **결정이 아니라 부수효과**다
    // (`native-editor-visual-mapping.md` §4 `assoc`) — 여기서는 그 선택을 고정하지 않고
    // **"한 번만 선다"**와 **"제 행에 선다"**만 잰다.
    var ops: [128]draw.Op = undefined;
    var text: [1024]u8 = undefined;
    var runs: [128]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [512]u8 = undefined;

    // 20칸 폭에 40자 — 두 시각 행으로 접힌다.
    const lines = [_][]const u8{"0123456789abcdefghijABCDEFGHIJklmnopqrst"};
    const total_cols: u16 = 20;
    // 25번째 글자 = 둘째 시각 행의 5번째 칸.
    const row_carets = [_]u32{25};
    const carets = [_][]const u32{&row_carets};

    const w = build(.{
        .lines = &lines,
        .first_line = 0,
        .total_lines = 1,
        .carets = &carets,
        .caret_visible = true,
        .visible_rows = 4,
        .wrap = true,
        .tab_width = default_tab_width,
        .rect = .{ .x = 0, .y = 0, .w = @as(u32, total_cols) * 8, .h = 64 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = total_cols,
        .scrollbar_gutter_px = 0,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    var n: usize = 0;
    var y: i32 = -1;
    for (ops[0..w.ops]) |op| {
        if (op != .quad) continue;
        if (op.quad.fill_role != .cursor) continue;
        n += 1;
        y = op.quad.rect.y;
    }
    // **한 번만** — 거르지 않으면 두 행 모두에 선다.
    try std.testing.expectEqual(@as(usize, 1), n);
    // **둘째 시각 행**이다 — 첫 행(y=0)에 서면 랩을 무시한 것이다.
    try std.testing.expect(y >= 16);
}

test "CRT2 커서가 많아도 스크롤바가 살아남는다 (예약이 실제로 작동하는가)" {
    // **예약을 뒀다와 예약이 작동한다는 다르다.** 커서는 줄당 개수에 상한이 없는 둘째 층이라
    // (검색이 첫째) 예산을 다 먹으면 뒤에 오는 막대가 통째로 안 그려지고, 그때 `scrollbar.build`는
    // op이 0이어도 **기하를 그대로 반환**해 "안 보이는데 드래그는 되는" 상태가 된다.
    //
    // op 배열을 **커서가 넘칠 만큼만** 준다. 처음엔 64로 줬는데 그러면 앞 층들(배경·본문·gutter·
    // 밴드·선택)이 먼저 다 먹어 막대가 굶었고 — 그것은 **이 슬라이스가 만든 상태가 아니라**
    // 위 주석이 "기존 상태"라 적어 둔 무예약 층들의 문제다 — 판정자가 엉뚱한 것을 재고 있었다.
    // 앞 층이 들어가고 **커서만 넘치는** 크기여야 예약이 실제로 판정된다.
    var ops: [256]draw.Op = undefined;
    var text: [4096]u8 = undefined;
    var runs: [256]draw.Run = undefined;
    var content_rows: [64]content.Row = undefined;
    var visual_rows: [64]visual_map.VisualRow = undefined;
    var gutter_rows: [64]gutter.Row = undefined;
    var counts: [64]u32 = undefined;
    var count_scratch: [1024]u8 = undefined;

    // **막대가 실제로 설 조건을 만든다.** 처음엔 한 줄짜리 문서에 `content_max_cols`도 없이 줬는데,
    // 그러면 세로는 문서가 다 들어가서, 가로는 `showsHorizontalBar`가 `content_max_cols`를 요구해서
    // **둘 다 애초에 안 그려진다** — 판정자가 "굶었다"와 "원래 없다"를 구분하지 못했다(실측:
    // 예약으로 남은 자리 2칸이 멀쩡히 비어 있는데 `bar_n == 0`이었다).
    const lines = [_][]const u8{ "x" ** 400, "y" ** 400, "z" ** 400, "w" ** 400 };
    var many: [400]u32 = undefined;
    for (&many, 0..) |*c, i| c.* = @intCast(i);
    const carets = [_][]const u32{ &many, &.{}, &.{}, &.{} };

    const total_cols: u16 = 40;
    const w = build(.{
        .lines = &lines,
        .first_line = 0,
        .total_lines = 4,
        .carets = &carets,
        .caret_visible = true,
        .content_max_cols = 400, // 가로 막대가 서는 조건
        .visible_rows = 2, // 4줄 중 2줄만 보인다 — 세로 막대가 서는 조건
        .wrap = false,
        .tab_width = default_tab_width,
        .rect = .{ .x = 0, .y = 0, .w = @as(u32, total_cols) * 8, .h = 32 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 400, // 가로가 넘쳐 **가로 막대도** 선다
        // **막대가 설 자리를 준다.** gutter가 0이면 `scrollbarGeometry`가 `null`을 내 막대가
        // 아예 안 그려진다 — 실측으로 확인했다(자리 2칸이 남았는데도 thumb이 0이었다).
        .scrollbar_gutter_px = 12,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    // 커서가 잘렸다 — 그것이 이 판정자가 만들려는 상태다.
    var caret_n: usize = 0;
    var bar_n: usize = 0;
    for (ops[0..w.ops]) |op| {
        if (op != .quad) continue;
        // `switch` prong은 comptime 값을 요구하는데 `thumb_role`은 다른 모듈의 상수라 여기서는
        // `if`가 맞다 — 값을 여기 베껴 적으면 그것이 두 번째 출처가 된다.
        if (op.quad.fill_role == .cursor) caret_n += 1;
        if (op.quad.fill_role == scrollbar.thumb_role) bar_n += 1;
    }
    try std.testing.expect(caret_n < many.len); // 실제로 잘렸나 — 아니면 판정이 공허하다
    // **막대는 그려졌다.** 굶었다면 여기서 0이고, 화면에 없는데 드래그는 되는 상태가 된다.
    try std.testing.expect(bar_n > 0);
}

test "SRCH1 검색 결과는 두 색으로 선다 — 현재 매치 하나만 다르다 (§5.1)" {
    // **뮤턴트로 잡힌 빈자리다**(적대적 검증 2026-08-23). `paintSearch`의 현재 매치 분기를
    // 통째로 없애 전부 `.search_match`로 그려도 이 저장소의 판정자 **전부가 초록이었다** —
    // 그 계약("Enter가 어디로 가는지 화면이 말한다")이 Lab 캡처(사람 눈)에만 걸려 있었다.
    var ops: [128]draw.Op = undefined;
    var text: [1024]u8 = undefined;
    var runs: [128]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [512]u8 = undefined;

    const lines = [_][]const u8{"row row row"}; // 0, 4, 8
    const row_marks = [_]Mark{ .{ .start = 0, .len = 3 }, .{ .start = 4, .len = 3 }, .{ .start = 8, .len = 3 } };
    const marks = [_][]const Mark{&row_marks};

    const total_cols: u16 = 40;
    const w = build(.{
        .lines = &lines,
        .first_line = 0,
        .total_lines = 1,
        .search_marks = &marks,
        // **가운데 것**이 현재다 — 첫 것을 고르면 "앞에서 자른 것"과, 마지막을 고르면 "뒤에서
        // 자른 것"과 구별되지 않아 셋으로 가르는 코드가 판정되지 않는다.
        .search_current = .{ .line = 0, .start = 4 },
        .visible_rows = 2,
        .wrap = false,
        .tab_width = default_tab_width,
        .rect = .{ .x = 0, .y = 0, .w = @as(u32, total_cols) * 8, .h = 32 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = total_cols,
        .scrollbar_gutter_px = 0,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    var normal_x: [4]i32 = undefined;
    var normal: usize = 0;
    var current_n: usize = 0;
    var current: ?draw.Op.Quad = null;
    for (ops[0..w.ops]) |op| {
        if (op != .quad) continue;
        switch (op.quad.fill_role) {
            .search_match => {
                if (normal < normal_x.len) normal_x[normal] = op.quad.rect.x;
                normal += 1;
            },
            .search_match_current => {
                current_n += 1;
                current = op.quad;
            },
            else => {},
        }
    }
    // 셋 중 둘은 보통 색, **하나만** 현재 색이다.
    try std.testing.expectEqual(@as(usize, 2), normal);
    // **세어야 한다 — 대입이면 중복 칠을 못 잡는다.** 초판은 마지막 것을 덮어써서, 현재 매치를
    // 두 번 그리는 뮤턴트가 저장소 3,347개를 전부 지나갔다(적대적 검증 2026-08-24). 두 번 칠하면
    // 알파가 두 번 먹어 그 하나만 진해진다 — `paintSearch` doc이 "표현 불가능하다"고 적어 둔 상태다.
    try std.testing.expectEqual(@as(usize, 1), current_n);
    const q = current orelse return error.CurrentMatchNotPainted;
    // 그 하나가 **가운데 매치 자리**에 선다 — 색만 맞고 자리가 틀리면 화면이 거짓말한다.
    // (열 계산을 다시 하지 않고 이웃 둘 사이에 있는지로 본다 — §4.1c가 금지한 두 번째 출처를
    // 판정자가 만들지 않게.)
    try std.testing.expect(normal_x[0] < q.rect.x and q.rect.x < normal_x[1]);
    try std.testing.expectEqual(@as(u32, 3 * 8), q.rect.w);
    // 세기도 갈린다 — 사용자 테마에서 두 색이 가까울 수 있고, 그때는 이것만이 구분을 준다.
    try std.testing.expectEqual(search_current_alpha, q.alpha);
    try std.testing.expect(search_current_alpha != search_alpha);
}

test "SRCH2 매치가 예산을 말려도 스크롤바는 선다 — 안 보이는데 드래그되는 상태를 막는다" {
    // **실측으로 도달 가능함이 확인된 자리다**(적대적 검증 2026-08-23): 이 저장소의
    // `app_session.zig`에서 공백 한 칸을 검색하면 80행×160열 창에 그려질 마크가 3,120개인데
    // 제품 예산은 2,560이다.
    //
    // 넘치면 `scrollbar.build`가 빈 슬라이스를 받아 op 0으로 돌아가는데 **기하는 그대로
    // 반환한다** — 막대가 안 보이는 자리에서 드래그만 잡히는 상태가 된다.
    // **일부러 좁힌다** — 3,000개짜리 창을 흉내 내지 않고 같은 상태를 만든다. 본문·gutter가
    // 들어갈 만큼은 남기고(그쪽이 마르면 이 판정자가 다른 것을 재게 된다) 검색이 그 뒤를
    // 다 먹을 만큼 좁힌다.
    var ops: [96]draw.Op = undefined;
    var text: [1024]u8 = undefined;
    var runs: [64]draw.Run = undefined;
    var content_rows: [64]content.Row = undefined;
    var visual_rows: [64]visual_map.VisualRow = undefined;
    var gutter_rows: [64]gutter.Row = undefined;
    var counts: [64]u32 = undefined;
    var count_scratch: [512]u8 = undefined;

    // 한 줄에 마크를 잔뜩 — 예산을 확실히 넘긴다.
    var many: [40]Mark = undefined;
    for (&many, 0..) |*m, i| m.* = .{ .start = @intCast(i * 2), .len = 1 };
    const marks_row = many[0..];
    var rows_buf: [40][]const Mark = undefined;
    for (&rows_buf) |*r| r.* = marks_row;

    var lines_buf: [40][]const u8 = undefined;
    for (&lines_buf) |*l| l.* = "a a a a a a a a a a a a a a a a a a a a";

    const total_cols: u16 = 200; // 본문보다 넓다 — 가로 막대가 설 조건
    const w = build(.{
        .lines = &lines_buf,
        .first_line = 0,
        .total_lines = 40,
        .search_marks = &rows_buf,
        .content_max_cols = 200, // 본문보다 길다 — 가로 막대가 설 조건(`showsHorizontalBar`)
        .visible_rows = 8,
        .wrap = false,
        .tab_width = default_tab_width,
        .rect = .{ .x = 0, .y = 0, .w = 320, .h = 8 * 16 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = total_cols,
        .scrollbar_gutter_px = 8,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    // 검색 강조가 예산을 다 먹었어도 **두 막대가 그려져야 한다**.
    var vertical = false;
    var horizontal = false;
    for (ops[0..w.ops]) |op| {
        if (op != .quad) continue;
        if (op.quad.fill_role == scrollbar.thumb_role and op.quad.alpha == scrollbar.thumb_alpha) {
            // 세로 막대는 본문 오른쪽 거터, 가로 막대는 본문 아래 거터에 선다 — y로 가른다.
            if (op.quad.rect.y >= @as(i32, 7 * 16)) horizontal = true else vertical = true;
        }
    }
    try std.testing.expect(vertical);
    try std.testing.expect(horizontal);
    // 그리고 그 자리는 기하와 일치해야 한다(기하만 살고 그림이 없는 상태를 막는 것이 목적이다).
    try std.testing.expect(w.scrollbar != null);
    try std.testing.expect(w.horizontal_scrollbar != null);
}

test "SRCH3 예산이 말라도 **현재 매치**는 남는다 — 위치 표시가 먼저다" {
    // **살아 있던 뮤턴트를 닫는다**(2라운드 적대적 검증). 현재 매치를 마지막에 그리도록 되돌려도
    // 저장소 806개가 전부 초록이었다 — `SRCH2`는 `search_current`를 아예 안 넘기고 `SRCH1`은
    // 예산이 남아돈다. 즉 "Enter가 어디로 갈지 화면이 말한다"는 계약이 다시 무판정이었다.
    //
    // 예산이 마르면 **주변 매치를 잃는 쪽**이 옳다. 반대로 현재 매치를 잃으면 색이 하나뿐인
    // 화면이 되어, 사용자는 여러 매치 중 어디에 서 있는지 알 수 없다.
    var text: [1024]u8 = undefined;
    var runs: [64]draw.Run = undefined;
    var content_rows: [16]content.Row = undefined;
    var visual_rows: [16]visual_map.VisualRow = undefined;
    var gutter_rows: [16]gutter.Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [512]u8 = undefined;

    const lines = [_][]const u8{"a a a a a"}; // 0,2,4,6,8
    const row_marks = [_]Mark{
        .{ .start = 0, .len = 1 }, .{ .start = 2, .len = 1 }, .{ .start = 4, .len = 1 },
        .{ .start = 6, .len = 1 }, .{ .start = 8, .len = 1 },
    };
    const marks = [_][]const Mark{&row_marks};

    // **일부러 마르게 한다.** 배경·본문·gutter가 먼저 먹고 나면 검색 몫이 마크 다섯을 못 담는다.
    var ops: [8]draw.Op = undefined;
    const total_cols: u16 = 24;
    const w = build(.{
        .lines = &lines,
        .first_line = 0,
        .total_lines = 1,
        .search_marks = &marks,
        .search_current = .{ .line = 0, .start = 8 }, // **맨 끝** — 앞에서 마르면 떨어진다
        .visible_rows = 2,
        .wrap = false,
        .tab_width = default_tab_width,
        .rect = .{ .x = 0, .y = 0, .w = @as(u32, total_cols) * 8, .h = 32 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = total_cols,
        .scrollbar_gutter_px = 0,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    var normal: usize = 0;
    var current: usize = 0;
    for (ops[0..w.ops]) |op| {
        if (op != .quad) continue;
        switch (op.quad.fill_role) {
            .search_match => normal += 1,
            .search_match_current => current += 1,
            else => {},
        }
    }
    // **현재 매치는 하나 있어야 한다.** 예산이 말랐으니 나머지는 다 못 그렸을 수 있다.
    try std.testing.expectEqual(@as(usize, 1), current);
    // 그리고 실제로 말랐어야 판정이 성립한다 — 다 들어갔으면 이 테스트는 아무것도 안 잰다.
    try std.testing.expect(normal < row_marks.len - 1);
}

test "SRCH4 현재 매치가 **아래쪽 행**에 있어도 예산에 안 밀린다 (행 루프 밖 선행 패스)" {
    // **`SRCH3`가 못 재는 절반이다**(적대적 검증 2026-08-24). 그쪽은 줄이 하나라, 현재 매치를
    // "그 행 안에서 먼저"(1라운드 모양) 그려도 통과한다. 그런데 1라운드가 부족했던 근거는
    // *"예산이 **그 행에 닿기 전에** 마른다"*였고, 그 상황은 **행이 둘 이상**이라야 난다.
    //
    // 그래서 여기서는 매치가 잔뜩인 행을 여러 개 두고 **현재 매치를 아래쪽 행**에 둔다.
    // 선행 패스가 행 루프 **밖**에 있어야만 그 하나가 살아남는다.
    var text: [2048]u8 = undefined;
    var runs: [64]draw.Run = undefined;
    var content_rows: [32]content.Row = undefined;
    var visual_rows: [32]visual_map.VisualRow = undefined;
    var gutter_rows: [32]gutter.Row = undefined;
    var counts: [32]u32 = undefined;
    var count_scratch: [512]u8 = undefined;

    const row_marks = [_]Mark{
        .{ .start = 0, .len = 1 }, .{ .start = 2, .len = 1 }, .{ .start = 4, .len = 1 },
        .{ .start = 6, .len = 1 }, .{ .start = 8, .len = 1 },
    };
    var lines_buf: [6][]const u8 = undefined;
    for (&lines_buf) |*l| l.* = "a a a a a";
    var rows_buf: [6][]const Mark = undefined;
    for (&rows_buf) |*r| r.* = row_marks[0..];

    // 앞 행들이 예산을 먹고 나면 **마지막 행에는 자리가 안 남는다**. (배경·본문·gutter가 먼저
    // 먹으므로 너무 좁히면 검색 층 자체가 0이 되어 판정이 성립하지 않는다 — 아래 `normal > 0`이
    // 그 상태를 막는다.)
    var ops: [24]draw.Op = undefined;
    const total_cols: u16 = 24;
    const w = build(.{
        .lines = &lines_buf,
        .first_line = 0,
        .total_lines = lines_buf.len,
        .search_marks = &rows_buf,
        .search_current = .{ .line = 5, .start = 8 }, // **마지막 행의 마지막 매치**
        .visible_rows = 6,
        .wrap = false,
        .tab_width = default_tab_width,
        .rect = .{ .x = 0, .y = 0, .w = @as(u32, total_cols) * 8, .h = 6 * 16 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = total_cols,
        .scrollbar_gutter_px = 0,
        .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
    }, .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    });

    var normal: usize = 0;
    var current: usize = 0;
    var current_y: i32 = -1;
    for (ops[0..w.ops]) |op| {
        if (op != .quad) continue;
        switch (op.quad.fill_role) {
            .search_match => normal += 1,
            .search_match_current => {
                current += 1;
                current_y = op.quad.rect.y;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), current);
    // 그리고 그것이 **마지막 행**에 섰다 — 행 루프 안에서 그렸다면 거기까지 예산이 못 간다.
    try std.testing.expectEqual(@as(i32, 5 * 16), current_y);
    // 판정이 성립하려면 **실제로 마르되 검색 층이 죽지는 않아야** 한다.
    try std.testing.expect(normal > 0);
    try std.testing.expect(normal < row_marks.len * lines_buf.len - 1);
}
