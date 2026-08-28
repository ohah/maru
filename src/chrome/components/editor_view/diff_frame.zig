//! 나란한 비교 한 프레임(§7 — 좌우 배치가 기본).
//!
//! **새 렌더 경로가 아니다.** `frame.build`를 두 번 부르는 조합일 뿐이고, 각 열은 지금까지의 편집기
//! 뷰와 같은 것이다(§7: *"diff는 별도 렌더 경로가 아니라 §4 시각 매핑·§5 스팬·§6 미니맵을 그대로 쓰는
//! 소비자다"*). 그래서 gutter·스크롤바·랩·hazard가 공짜로 따라온다.
//!
//! **왜 컴포넌트 층인가**: 제품(`app_session/editor.zig`)과 Chrome Lab이 **같은 함수**를 불러야 캡처가
//! 제품을 예고한다. 한쪽만 조합을 들고 있으면 골든은 초록인데 제품만 틀린 상태가 만들어진다 — 편집기
//! 배경 층에서 실제로 그랬다(`background_layer` 주석).
//!
//! 세로는 하나, 가로는 각자다(§3.5). 세로를 공유하는 것은 **같은 줄이 같은 높이에 서야** 비교가
//! 성립하기 때문이고, 가로를 나누는 것은 양쪽 줄 길이가 달라 한쪽을 따라가면 다른 쪽이 엉뚱한 곳을
//! 보기 때문이다(CM6 `diff-layout.ts`가 같은 결론을 적어 두었다).

const std = @import("std");
const draw = @import("../../draw.zig");
const scroll_area = @import("../../ui/scroll_area.zig");
const scrollbar_mod = @import("scrollbar.zig");
const frame = @import("frame.zig");
const gutter = @import("gutter.zig");
const geometry = @import("geometry.zig"); // 본문 열 수 — 가로 막대가 서는지 판정할 때 쓴다

/// 한 쪽이 그릴 것.
pub const Side = struct {
    /// 그 열의 행마다 **선택 범위**(§4.1g). 단일 편집기와 비교 뷰가 **둘 다** 쓴다 — 비교는
    /// 좌우가 각자 자기 것을 넘긴다(한 번에 한 열만 고르므로 한쪽은 `null`이다).
    selection_marks: ?[]const []const frame.Mark = null,

    /// 그 열의 행마다 **검색 결과**(§5.1)와 그 중 현재 매치. 단일 편집기만 채운다 —
    /// 비교 뷰 검색은 어느 쪽을 검색하는지부터 정해야 하고, 그것은 가로 스크롤·히트테스트가
    /// 좌우를 가른 뒤의 일이다(같은 슬라이스에 든다).
    search_marks: ?[]const []const frame.Mark = null,
    search_current: ?frame.CurrentMatch = null,

    /// 그 쪽 **행**들의 표시 텍스트. 좌우 길이가 같아야 같은 인덱스가 같은 높이다.
    lines: []const []const u8,
    /// 줄별 **구문 강조 색 구간**(§5.3). `lines`와 같은 축이고, 짧거나 비어도 된다 —
    /// 없는 줄은 무색이다. **단일 편집기만 채운다**(비교 뷰는 문서가 둘이라 provider도 둘이고,
    /// 그 축을 가르는 것은 좌우 히트테스트가 선 뒤의 일이다 — `search_marks`와 같은 이유).
    line_colors: []const []const frame.content.ColorSpan = &.{},
    /// gutter 자릿수를 정하는 **문서** 줄 수(행 수가 아니다). `null`이면 `lines.len`.
    total_lines: ?usize = null,
    /// 행마다의 줄 번호(`null` 항목 = 짝을 맞추려 넣은 빈 행). `null`이면 순차 번호.
    numbers: ?[]const ?u32 = null,
    /// 가로 스크롤(열). **각자다** — 공유하면 반대쪽이 엉뚱한 곳을 본다.
    first_col: u16 = 0,
    /// 행마다 추가/삭제/없음. **왼쪽은 삭제만, 오른쪽은 추가만** 담는 것이 §3.5의 배치 계약이다 —
    /// 한쪽에 둘 다 담으면 좌우를 나눈 이유가 사라진다.
    bands: ?[]const frame.RowBand = null,
    /// 행마다 바뀐 글자 범위(§3.5 "바뀐 글자만 진하게").
    marks: ?[]const []const frame.Mark = null,
    /// 행마다의 접힘 표식. **비교 뷰는 접지 않으므로**(§4.1f) 그쪽은 `null`이고, 단일 파일
    /// 편집기가 이 경로를 함께 지나므로 여기에 자리가 있다.
    folds: ?[]const gutter.Fold = null,
    /// 문서에서 **가장 긴 줄**의 표시 폭(열) — 가로 스크롤바가 이 값으로 막대 길이를 정한다.
    /// `null`이면 막대를 그리지 않는다(아직 안 셌거나 이 축을 안 쓰는 호출자).
    ///
    /// **비교 뷰는 `null`로 둔다** — §3.5의 "가로는 각자다"를 지키려면 좌우 열이 각자 막대를 가져야
    /// 하는데, 그 히트테스트가 아직 없다(계획 표의 "비교 뷰의 가로 스크롤"과 같은 슬라이스다).
    content_max_cols: ?u32 = null,
    /// 줄별 시각 행 수 캐시(`frame.RowCache`). **열마다 각자다** — 좌우는 줄 배열도 폭도 다르므로
    /// 하나를 공유하면 매 프레임 서로의 캐시를 무효화한다. `null`이면 캐시 없이 그린다.
    row_cache: ?*frame.RowCache = null,
};

pub const Props = struct {
    left: Side,
    right: Side,
    /// 두 열이 **공유하는** 세로 위치(행 인덱스).
    first_line: usize = 0,
    /// 첫 행에서 건너뛸 **조각 수**(§4.1d). 세로를 공유하므로 좌우 공통이다.
    first_piece: u32 = 0,
    wrap: bool = false,
    /// **기본값이 없다 — 호출자가 반드시 넘긴다.** 기본값을 두면 그것이 두 번째 출처가 되고,
    /// "렌더가 쓰는 값"을 참조하는 쪽(hit-test)이 조용히 갈린다. 두 번 그렇게 갈렸다: 2차 적대적
    /// 검증은 이 자리가 `4`를 하드코딩해 `frame.default_tab_width`를 바꿔도 렌더가 안 따라오는 것을
    /// 잡았고, 12차는 제품이 `editor_tab_width` 필드를 쓰기 시작한 뒤에도 **호출자가 안 넘기면
    /// 기본값으로 떨어지는** 것을 잡았다(Chrome Lab이 그랬다 — 오늘은 둘 다 4라 안 보이지만 설정이
    /// 배선되는 순간 *"캡처가 제품을 예고한다"*가 깨진다). 기본값을 없애면 그 갈림이 **컴파일
    /// 에러**가 된다.
    tab_width: u8,
    /// 내용이 설 사각(호출자가 여백을 이미 반영해 넘긴다).
    rect: draw.Rect,
    /// 배경이 덮을 바깥 사각. 각 열의 배경은 여기서 자기 몫으로 잘린다 — 바깥 가장자리만 여백만큼
    /// 물리고 가운데는 물리지 않는다(뒤로 물리면 반대쪽 본문 밑으로 들어간다).
    background_rect: ?draw.Rect = null,
    cell_w_px: u16,
    cell_h_px: u16,
    font_px: u16,
};

pub const Written = struct {
    ops: usize,
    /// 두 열 중 **더 긴 쪽**의 문서 시각 행 수. 세로를 공유하므로 스크롤 상한은 긴 쪽이 정한다.
    total_visual_rows: u32,
    /// 스크롤 상한 `(줄, 조각)` — 세로를 공유하므로 **더 긴 쪽**이 정한다(§4.1d).
    max_top_line: usize = 0,
    max_top_piece: u32 = 0,
    visual_rows: usize,
    truncated: bool,
    /// **각 열이 실제로 채운 행 수.** `visual_rows`는 둘 중 큰 값이라 어느 쪽이 몇 줄인지 모른다 —
    /// 비교 뷰 히트테스트가 좌우 행 배열을 따로 굳히려면 이 둘이 필요하다(§4.1g "비교 뷰").
    /// 저장소는 `splitScratch`가 이미 반으로 갈라 각 열이 자기 몫만 채운다.
    left_visual_rows: usize = 0,
    right_visual_rows: usize = 0,
    /// 오른쪽 열이 시작하는 x. 히트테스트(어느 열을 눌렀나)가 쓴다 — 제품은 같은 판정을
    /// `isRightColumn`으로 하고, 그쪽은 `columns()`를 다시 불러 같은 값을 얻는다.
    split_x: i32,
    /// 좌우 막대의 기하(드래그가 잡는다). **세로는 값이 같지만 자리가 둘**이라 각각 낸다 — 어느 쪽을
    /// 눌러도 같은 곳으로 가지만, 눌렀는지 판정하려면 두 자리를 다 알아야 한다.
    ///
    /// **가로는 값도 다르다**(§3.5 — 가로는 각자다). 원본과 수정본의 가장 긴 줄이 달라 막대 길이도
    /// 갈린다.
    left_scrollbar: ?scroll_area.ScrollbarGeometry = null,
    right_scrollbar: ?scroll_area.ScrollbarGeometry = null,
    left_horizontal_scrollbar: ?scrollbar_mod.HorizontalGeometry = null,
    right_horizontal_scrollbar: ?scrollbar_mod.HorizontalGeometry = null,
};

pub const Columns = struct { left: draw.Rect, right: draw.Rect };

/// 좌우 열의 자리. **가운데 한 칸을 비운다** — 두 본문이 맞닿으면 어느 쪽 글자인지 읽히지 않는다
/// (색 띠가 붙기 전에도 배치만으로 갈라져 보여야 한다). 나머지 픽셀은 오른쪽이 가져가 pane 오른쪽
/// 끝에 칠하지 않은 띠가 남지 않게 한다.
pub fn columns(inner: draw.Rect, cell_w_px: u16) Columns {
    const gap: u32 = @max(cell_w_px, 1);
    const usable = inner.w -| gap;
    const left_w = usable / 2;
    return .{
        .left = .{ .x = inner.x, .y = inner.y, .w = left_w, .h = inner.h },
        .right = .{
            .x = inner.x + @as(i32, @intCast(left_w + gap)),
            .y = inner.y,
            .w = usable -| left_w,
            .h = inner.h,
        },
    };
}

/// 한 열의 폭에서 나오는 값들. **편집기 하나든 diff의 한 쪽이든 같은 계산이다** — 두 곳에 두면
/// 좌우 열만 다르게 어긋난다.
pub const SideMetrics = struct {
    metrics: scroll_area.ScrollbarMetrics,
    total_cols: u16,
    scrollbar_gutter_px: u32,
    visible_rows: u16,
    /// **가로 막대가 아래에서 먹는 자리**(px). 0이면 막대가 서지 않는다.
    ///
    /// 세로 막대가 폭을 먹는 것과 대칭이다(§4.1a "가로 스크롤바는 세로와 짝이다") — 본문 위에
    /// 겹쳐 그리면 마지막 줄이 막대에 가리고, 그것은 §3.8이 막으려는 "화면과 파일 내용이 다른"
    /// 상태다. 그래서 `visible_rows`가 이미 이만큼 줄어 있다.
    horizontal_gutter_px: u32 = 0,
};

/// 스크롤바 기하. 제품과 Lab이 같은 값을 써야 캡처가 제품을 예고한다.
pub const scrollbar_metrics: scroll_area.ScrollbarMetrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };

/// 가로 막대가 서는지를 호출자가 알려 준다. **본문 높이를 정하는 자리가 여기 하나뿐**이라
/// (`visible_rows`) 그 판정도 여기로 들어와야 자리와 막대가 갈리지 않는다. 판정 규칙 자체는
/// `frame.showsHorizontalBar`가 소유한다 — 여기서 다시 세지 않는다.
pub fn sideMetricsWith(inner_w: u32, inner_h: u32, cell_w_px: u16, cell_h_px: u16, shows_horizontal_bar: bool) SideMetrics {
    var m = sideMetrics(inner_w, inner_h, cell_w_px, cell_h_px);
    if (!shows_horizontal_bar) return m;

    const ch: u32 = @max(cell_h_px, 1);
    const bar_px = scrollbar_metrics.gutterPx();
    m.horizontal_gutter_px = bar_px;
    m.visible_rows = @intCast(@min((inner_h -| bar_px) / ch, @as(u32, std.math.maxInt(u16))));
    return m;
}

pub fn sideMetrics(inner_w: u32, inner_h: u32, cell_w_px: u16, cell_h_px: u16) SideMetrics {
    // **스크롤바가 자리를 먹는다**(§4.1a) — 본문 위에 겹치면 오른쪽 끝 글자가 막대에 가려지고,
    // §3.8이 "보이는 것과 파일 내용이 달라지면 안 된다"를 요구하는 편집기에서 그것은 특히 나쁘다.
    const cw: u32 = @max(cell_w_px, 1);
    const ch: u32 = @max(cell_h_px, 1);
    const total_cols: u16 = @intCast(@min(
        (inner_w -| scrollbar_metrics.gutterPx()) / cw,
        @as(u32, std.math.maxInt(u16)),
    ));
    return .{
        .metrics = scrollbar_metrics,
        .total_cols = total_cols,
        // **남은 폭 전부가 스크롤바 gutter다.** `total_cols`가 버림이라 본문이 셀 경계에서 끝나고,
        // 요구한 폭보다 넓은 자투리가 생긴다 — 그것을 포함하지 않으면 막대가 오른쪽 끝에서 뜬다.
        .scrollbar_gutter_px = inner_w -| (@as(u32, total_cols) * cw),
        .visible_rows = @intCast(@min(inner_h / ch, @as(u32, std.math.maxInt(u16)))),
    };
}

/// 두 열이 함께 쓰는 값. 열 하나만 그리는 호출자(단일 편집기)도 이것을 쓴다.
pub const Shared = struct {
    first_line: usize = 0,
    /// 첫 논리 줄에서 건너뛸 **조각 수**(§4.1d). 세로를 공유하므로 이것도 좌우 공통이다 —
    /// 같은 시각 행에서 시작해야 같은 줄이 같은 높이에 선다.
    first_piece: u32 = 0,
    wrap: bool = false,
    /// 커서 자리(줄별 byte offset)와 지금 그릴 순간인가. **비교 뷰는 안 쓴다** — 좌우 두 문서라
    /// 커서가 어느 쪽 것인지 판정이 선행하고(§4.1g "비교 뷰"), 그 판정은 아직 없다. 단일 편집기가
    /// 이 구조를 함께 쓰므로 자리만 뚫어 둔다.
    carets: ?[]const []const u32 = null,
    caret_visible: bool = true,
    /// **기본값이 없다 — 호출자가 반드시 넘긴다.** 기본값을 두면 그것이 두 번째 출처가 되고,
    /// "렌더가 쓰는 값"을 참조하는 쪽(hit-test)이 조용히 갈린다. 두 번 그렇게 갈렸다: 2차 적대적
    /// 검증은 이 자리가 `4`를 하드코딩해 `frame.default_tab_width`를 바꿔도 렌더가 안 따라오는 것을
    /// 잡았고, 12차는 제품이 `editor_tab_width` 필드를 쓰기 시작한 뒤에도 **호출자가 안 넘기면
    /// 기본값으로 떨어지는** 것을 잡았다(Chrome Lab이 그랬다 — 오늘은 둘 다 4라 안 보이지만 설정이
    /// 배선되는 순간 *"캡처가 제품을 예고한다"*가 깨진다). 기본값을 없애면 그 갈림이 **컴파일
    /// 에러**가 된다.
    tab_width: u8,
    cell_w_px: u16,
    cell_h_px: u16,
    font_px: u16,
    /// 가로 막대 자리를 **양쪽 다** 뗄 것인가. `null`이면 각 열이 자기 `content_max_cols`로 정한다
    /// (단일 편집기 경로가 그렇다 — 열이 하나뿐이라 통일할 것이 없다).
    ///
    /// **비교 뷰는 이것을 반드시 준다.** 막대는 본문 아래 여백에서 **자리를 먹으므로**(§4.1a) 한쪽만
    /// 서면 그쪽 `visible_rows`가 한 행 작아지는데, 스크롤 상한(`max_top`)은 `build`가 **한쪽 값만**
    /// 골라 쓴다(세로를 공유하므로 — §3.5). 그러면 짧아진 쪽이 문서 끝에 못 닿거나 긴 쪽 아래가
    /// 빈다. 좌우를 같은 판정으로 묶으면 `visible_rows`가 같아져 그 어긋남이 생기지 않는다.
    force_horizontal_bar: ?bool = null,
};

/// 한 열을 그린다. 좌표는 `rect`가 정하므로 **열이 어디에 있든** 같은 함수다.
pub fn buildSide(
    side: Side,
    shared: Shared,
    rect: draw.Rect,
    background: ?draw.Rect,
    scratch: frame.Scratch,
) frame.Written {
    // **가로 막대가 자리를 먹으므로 높이를 먼저 줄인다**(§4.1a) — 판정 규칙은 `frame`이 소유한다.
    // 열 수(`total_cols`)를 알아야 판정할 수 있는데 그 값이 이 계산에서 나오므로, 한 번 재고 나서
    // 막대가 서면 다시 잰다. 두 번째 계산은 폭을 안 바꾸므로(막대는 아래에만 붙는다) 열 수는 같다.
    const probe = sideMetrics(rect.w, rect.h, shared.cell_w_px, shared.cell_h_px);
    const shows_h_bar = shared.force_horizontal_bar orelse
        frame.showsHorizontalBar(shared.wrap, side.content_max_cols, geometry.compute(probe.total_cols, side.total_lines orelse side.lines.len, .{}).content.width);
    const m = sideMetricsWith(rect.w, rect.h, shared.cell_w_px, shared.cell_h_px, shows_h_bar);
    return frame.build(.{
        .line_colors = side.line_colors,
        .lines = side.lines,
        .first_line = shared.first_line,
        .first_piece = shared.first_piece,
        .first_col = side.first_col,
        .total_lines = side.total_lines orelse side.lines.len,
        .line_numbers = side.numbers,
        .folds = side.folds,
        .content_max_cols = side.content_max_cols,
        .row_cache = side.row_cache,
        .selection_marks = side.selection_marks,
        .search_marks = side.search_marks,
        .search_current = side.search_current,
        .row_bands = side.bands,
        .row_marks = side.marks,
        .visible_rows = m.visible_rows,
        .wrap = shared.wrap,
        .carets = shared.carets,
        .caret_visible = shared.caret_visible,
        .tab_width = shared.tab_width,
        .rect = rect,
        .background_rect = background,
        .cell_w_px = shared.cell_w_px,
        .cell_h_px = shared.cell_h_px,
        .font_px = shared.font_px,
        .total_cols = m.total_cols,
        .scrollbar_gutter_px = m.scrollbar_gutter_px,
        .metrics = m.metrics,
    }, scratch);
}

const ScratchPair = struct { first: frame.Scratch, second: frame.Scratch };

/// 저장소를 반으로 가른다. **두 결과가 동시에 살아 있어야 한다** — op이 text·run을 가리키므로
/// 같은 버퍼를 두 번 쓰면 왼쪽 글자가 오른쪽 것으로 덮인다.
pub fn splitScratch(s: frame.Scratch) ScratchPair {
    return .{
        .first = .{
            .ops = s.ops[0 .. s.ops.len / 2],
            .text_bytes = s.text_bytes[0 .. s.text_bytes.len / 2],
            .runs = s.runs[0 .. s.runs.len / 2],
            .content_rows = s.content_rows[0 .. s.content_rows.len / 2],
            .visual_rows = s.visual_rows[0 .. s.visual_rows.len / 2],
            .gutter_rows = s.gutter_rows[0 .. s.gutter_rows.len / 2],
            .row_counts = s.row_counts[0 .. s.row_counts.len / 2],
            .count_scratch = s.count_scratch[0 .. s.count_scratch.len / 2],
        },
        .second = .{
            .ops = s.ops[s.ops.len / 2 ..],
            .text_bytes = s.text_bytes[s.text_bytes.len / 2 ..],
            .runs = s.runs[s.runs.len / 2 ..],
            .content_rows = s.content_rows[s.content_rows.len / 2 ..],
            .visual_rows = s.visual_rows[s.visual_rows.len / 2 ..],
            .gutter_rows = s.gutter_rows[s.gutter_rows.len / 2 ..],
            .row_counts = s.row_counts[s.row_counts.len / 2 ..],
            .count_scratch = s.count_scratch[s.count_scratch.len / 2 ..],
        },
    };
}

/// 좌우 두 열을 `scratch.ops` 앞쪽에 채운다.
pub fn build(props: Props, scratch: frame.Scratch) Written {
    const cols = columns(props.rect, props.cell_w_px);
    const half = splitScratch(scratch);
    const outer = props.background_rect orelse props.rect;
    const left_bg_x = outer.x;
    const right_bg_end = outer.x + @as(i32, @intCast(outer.w));

    // **막대 판정을 좌우가 함께 한다**(§3.5 세로 공유). 한쪽만 서면 그쪽 `visible_rows`가 한 행
    // 작아지는데 아래에서 `max_top`은 한쪽 값만 고르므로, 짧아진 쪽이 끝에 못 닿거나 긴 쪽 아래가
    // 빈다. 한쪽이라도 넘치면 **양쪽 다** 자리를 뗀다 — 안 넘치는 쪽에는 빈 띠가 남지만 그것이
    // 스크롤이 끝에 안 닿는 것보다 낫다.
    const wants_h_bar =
        frame.showsHorizontalBar(props.wrap, props.left.content_max_cols, geometry.compute(sideMetrics(cols.left.w, cols.left.h, props.cell_w_px, props.cell_h_px).total_cols, props.left.total_lines orelse props.left.lines.len, .{}).content.width) or
        frame.showsHorizontalBar(props.wrap, props.right.content_max_cols, geometry.compute(sideMetrics(cols.right.w, cols.right.h, props.cell_w_px, props.cell_h_px).total_cols, props.right.total_lines orelse props.right.lines.len, .{}).content.width);
    const shared: Shared = .{
        .first_line = props.first_line,
        .first_piece = props.first_piece,
        .wrap = props.wrap,
        .tab_width = props.tab_width,
        .cell_w_px = props.cell_w_px,
        .cell_h_px = props.cell_h_px,
        .font_px = props.font_px,
        .force_horizontal_bar = wants_h_bar,
    };
    const lw = buildSide(props.left, shared, cols.left, .{
        .x = left_bg_x,
        .y = outer.y,
        .w = @intCast(cols.right.x - left_bg_x),
        .h = outer.h,
    }, half.first);

    const rw = buildSide(props.right, shared, cols.right, .{
        .x = cols.right.x,
        .y = outer.y,
        .w = @intCast(@max(right_bg_end - cols.right.x, 0)),
        .h = outer.h,
    }, half.second);

    // 두 열의 op을 앞쪽으로 모은다 — 호출자는 `ops[0..n]` 하나만 안다. 목적지가 원본보다 앞이므로
    // 전진 복사가 안전하다(왼쪽이 저장소 절반을 다 쓰지 않는 한 겹치지도 않는다).
    const moved = @min(rw.ops, scratch.ops.len -| lw.ops);
    std.mem.copyForwards(draw.Op, scratch.ops[lw.ops..][0..moved], half.second.ops[0..moved]);
    // **상한은 더 긴 쪽이 정한다.** 세로를 공유하므로 짧은 쪽 기준으로 멈추면 긴 쪽의 끝을 못 본다
    // (`total_visual_rows`를 `@max`로 잡는 것과 같은 이유).
    const longer = if (rw.total_visual_rows > lw.total_visual_rows) rw else lw;
    return .{
        .total_visual_rows = @max(lw.total_visual_rows, rw.total_visual_rows),
        .max_top_line = longer.max_top_line,
        .max_top_piece = longer.max_top_piece,
        .ops = lw.ops + moved,
        .visual_rows = @max(lw.visual_rows, rw.visual_rows),
        .left_visual_rows = lw.visual_rows,
        .right_visual_rows = rw.visual_rows,
        .truncated = lw.truncated or rw.truncated or moved < rw.ops,
        .split_x = cols.right.x,
        .left_scrollbar = lw.scrollbar,
        .right_scrollbar = rw.scrollbar,
        .left_horizontal_scrollbar = lw.horizontal_scrollbar,
        .right_horizontal_scrollbar = rw.horizontal_scrollbar,
    };
}

const testing = std.testing;

test "한쪽만 넘쳐도 양쪽이 같은 높이를 쓴다 — 막대 자리를 좌우가 함께 뗀다 (§3.5)" {
    // 가로 막대는 본문 아래 여백에서 **자리를 먹는다**(§4.1a). 한쪽만 서면 그쪽 `visible_rows`가 한 행
    // 작아지는데 `max_top`은 `build`가 한쪽 값만 고르므로(세로를 공유하니까 — §3.5), 짧아진 쪽이 문서
    // 끝에 못 닿거나 긴 쪽 아래가 빈다. 그래서 **한쪽이라도 넘치면 양쪽 다** 뗀다.
    //
    // 판정: 오른쪽만 넘치는 프레임의 그린 행 수가, 아무도 안 넘치는 프레임보다 **적어야** 한다.
    // 한쪽만 뗐다면 `@max(lw, rw)`가 안 뗀 쪽 값을 골라 둘이 같아진다(그 뮤턴트가 여기서 죽는다).
    var ops: [512]draw.Op = undefined;
    var text: [4096]u8 = undefined;
    var runs: [512]draw.Run = undefined;
    var content_rows: [128]@import("content.zig").Row = undefined;
    var visual_rows: [128]@import("../../ui/visual_map.zig").VisualRow = undefined;
    var gutter_rows: [128]gutter.Row = undefined;
    var counts: [128]u32 = undefined;
    var count_scratch: [256]u8 = undefined;
    const s: frame.Scratch = .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    };

    // 화면(20행)보다 긴 문서라야 "행이 줄었다"가 관측된다.
    var lines: [40][]const u8 = undefined;
    for (&lines) |*l| l.* = "ok";
    const rect: draw.Rect = .{ .x = 0, .y = 0, .w = 640, .h = 320 }; // 320/16 = 20행

    const spilled = build(.{
        .tab_width = frame.default_tab_width,
        .left = .{ .lines = &lines, .content_max_cols = 4 },
        .right = .{ .lines = &lines, .content_max_cols = 400 }, // 오른쪽만 넘친다
        .rect = rect,
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 13,
    }, s);

    const flat = build(.{
        .tab_width = frame.default_tab_width,
        .left = .{ .lines = &lines, .content_max_cols = 4 },
        .right = .{ .lines = &lines, .content_max_cols = 4 }, // 아무도 안 넘친다
        .rect = rect,
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 13,
    }, s);

    try testing.expect(flat.visual_rows > 0); // 실제로 그렸다
    try testing.expect(spilled.visual_rows < flat.visual_rows); // 양쪽 다 자리를 뗐다
}

test "두 열이 서로를 침범하지 않고 가운데 한 칸이 빈다" {
    const cols = columns(.{ .x = 0, .y = 0, .w = 801, .h = 600 }, 8);
    try testing.expect(cols.left.x + @as(i32, @intCast(cols.left.w)) <= cols.right.x);
    try testing.expectEqual(@as(i32, 8), cols.right.x - (cols.left.x + @as(i32, @intCast(cols.left.w))));
    // **자투리를 남기지 않는다** — 남기면 pane 오른쪽 끝에 칠하지 않은 띠가 선다.
    try testing.expectEqual(@as(u32, 801), cols.left.w + 8 + cols.right.w);
}

test "열이 원점을 따라간다 — pane 안 어디에 있든 같은 함수다" {
    const cols = columns(.{ .x = 100, .y = 50, .w = 400, .h = 200 }, 10);
    try testing.expectEqual(@as(i32, 100), cols.left.x);
    try testing.expectEqual(@as(i32, 100 + 195 + 10), cols.right.x);
}

test "저장소가 겹치지 않는다 — 겹치면 한쪽 글자가 반대쪽 것으로 바뀐다" {
    var ops: [64]draw.Op = undefined;
    var text: [256]u8 = undefined;
    var runs: [64]draw.Run = undefined;
    var content_rows: [16]@import("content.zig").Row = undefined;
    var visual_rows: [16]@import("../../ui/visual_map.zig").VisualRow = undefined;
    var gutter_rows: [16]@import("gutter.zig").Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [64]u8 = undefined;
    const s: frame.Scratch = .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    };
    const pair = splitScratch(s);
    try testing.expect(@intFromPtr(pair.first.text_bytes.ptr) + pair.first.text_bytes.len <= @intFromPtr(pair.second.text_bytes.ptr));
    try testing.expect(@intFromPtr(pair.first.runs.ptr) + pair.first.runs.len * @sizeOf(draw.Run) <= @intFromPtr(pair.second.runs.ptr));
    try testing.expectEqual(ops.len / 2, pair.first.ops.len);
}

test "저장소가 모자라도 죽지 않고 잘린다 — 두 열이 절반씩만 받는다" {
    // 컴포넌트의 기존 계약이다(*"어느 것이든 모자라면 그 부분이 잘릴 뿐 죽지 않는다"*). 두 열로
    // 갈리면 열당 예산이 절반이라 **한 열만 그려지는** 상태가 새로 생긴다 — 그때도 죽지 않아야 하고,
    // `truncated`가 그 사실을 말해야 한다(캡처에는 빈 자리로 나타난다).
    var ops: [3]draw.Op = undefined; // 열당 1개 — 배경 하나면 끝난다
    var text: [8]u8 = undefined;
    var runs: [2]draw.Run = undefined;
    var content_rows: [2]@import("content.zig").Row = undefined;
    var visual_rows: [2]@import("../../ui/visual_map.zig").VisualRow = undefined;
    var gutter_rows: [2]@import("gutter.zig").Row = undefined;
    var counts: [2]u32 = undefined;
    var count_scratch: [8]u8 = undefined;

    const left = [_][]const u8{ "aaaa", "bbbb" };
    const right = [_][]const u8{ "cccc", "dddd" };
    const w = build(.{
        .tab_width = frame.default_tab_width,
        .left = .{ .lines = &left },
        .right = .{ .lines = &right },
        .rect = .{ .x = 0, .y = 0, .w = 400, .h = 100 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
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
    try testing.expect(w.ops <= ops.len);
    try testing.expect(w.truncated); // 잘렸다는 사실이 조용히 사라지지 않는다
}

test "op 배열이 비어도 죽지 않는다" {
    var ops: [0]draw.Op = undefined;
    var text: [0]u8 = undefined;
    var runs: [0]draw.Run = undefined;
    var content_rows: [0]@import("content.zig").Row = undefined;
    var visual_rows: [0]@import("../../ui/visual_map.zig").VisualRow = undefined;
    var gutter_rows: [0]@import("gutter.zig").Row = undefined;
    var counts: [0]u32 = undefined;
    var count_scratch: [0]u8 = undefined;
    const line = [_][]const u8{"x"};
    const w = build(.{
        .tab_width = frame.default_tab_width,
        .left = .{ .lines = &line },
        .right = .{ .lines = &line },
        .rect = .{ .x = 0, .y = 0, .w = 200, .h = 50 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
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
    try testing.expectEqual(@as(usize, 0), w.ops);
}

test "아주 좁거나 낮은 자리에서도 죽지 않는다 — 분할 pane은 실제로 이만큼 좁아진다" {
    // 두 열로 갈리면 **각 열이 pane의 절반**이라, 단일 편집기가 겪지 않던 폭에서 돈다. 0폭·1픽셀·
    // 셀보다 좁은 폭에서 나눗셈이나 인덱스가 터지면 화면이 아니라 앱이 죽는다.
    var ops: [128]draw.Op = undefined;
    var text: [512]u8 = undefined;
    var runs: [128]draw.Run = undefined;
    var content_rows: [16]@import("content.zig").Row = undefined;
    var visual_rows: [16]@import("../../ui/visual_map.zig").VisualRow = undefined;
    var gutter_rows: [16]@import("gutter.zig").Row = undefined;
    var counts: [16]u32 = undefined;
    var count_scratch: [128]u8 = undefined;
    const scratch: frame.Scratch = .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
    };
    const left = [_][]const u8{ "aaaa", "" };
    const right = [_][]const u8{ "", "bbbb" };

    var w: u32 = 0;
    while (w <= 64) : (w += 1) {
        var h: u32 = 0;
        while (h <= 40) : (h += 8) {
            const out = build(.{
                .tab_width = frame.default_tab_width,
                .left = .{ .lines = &left, .total_lines = 1 },
                .right = .{ .lines = &right, .total_lines = 1 },
                .rect = .{ .x = 0, .y = 0, .w = w, .h = h },
                .cell_w_px = 8,
                .cell_h_px = 16,
                .font_px = 16,
            }, scratch);
            // 그린 op이 저장소를 넘지 않는다(넘으면 아래 호출자가 남의 메모리를 읽는다).
            try testing.expect(out.ops <= ops.len);
            // 두 열이 서로를 침범하지 않는다 — 폭이 0이어도 오른쪽이 왼쪽 앞에 서지 않는다.
            const cols = columns(.{ .x = 0, .y = 0, .w = w, .h = h }, 8);
            try testing.expect(cols.right.x >= cols.left.x + @as(i32, @intCast(cols.left.w)));
        }
    }
}

test "셀 크기가 0이어도 죽지 않는다 — 폰트 측정 전 프레임이 그렇다" {
    // 제품은 `cell_width_px == 0`이면 프레임을 아예 건너뛰지만, 컴포넌트가 그 가정에 기대면 안 된다
    // (Lab·다른 호출자는 그 가드를 지나지 않는다). 나눗셈이 0을 만나면 그 자리에서 죽는다.
    var ops: [32]draw.Op = undefined;
    var text: [128]u8 = undefined;
    var runs: [32]draw.Run = undefined;
    var content_rows: [8]@import("content.zig").Row = undefined;
    var visual_rows: [8]@import("../../ui/visual_map.zig").VisualRow = undefined;
    var gutter_rows: [8]@import("gutter.zig").Row = undefined;
    var counts: [8]u32 = undefined;
    var count_scratch: [64]u8 = undefined;
    const line = [_][]const u8{"x"};
    const out = build(.{
        .tab_width = frame.default_tab_width,
        .left = .{ .lines = &line },
        .right = .{ .lines = &line },
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .cell_w_px = 0,
        .cell_h_px = 0,
        .font_px = 0,
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
    try testing.expect(out.ops <= ops.len);
}
