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
const content = @import("content.zig");
const geometry = @import("geometry.zig");
const gutter = @import("gutter.zig");
const scrollbar = @import("scrollbar.zig");
const surface = @import("surface.zig");
const visual_map = @import("visual_map.zig");
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

pub const Props = struct {
    /// **문서 전체의 논리 줄들.** 화면 몫만 잘라 넘기면 안 된다 — 스크롤바 길이가 문서 전체의
    /// 시각 행 수에서 나오는데(§4.1a), 잘린 배열로는 그것을 셀 수 없어 막대가 실제보다 짧아진다
    /// (골든 `editor-scrollbar-wrapped-range`가 그 회귀를 잡았다).
    ///
    /// 큰 문서에서 이 계수가 비싸지면 `total_visual_rows`로 미리 센 값을 넘겨 건너뛴다.
    lines: []const []const u8,
    /// 화면 맨 위에 올 논리 줄(0-based). 여기서부터 그리고, 줄 번호도 여기서 시작한다.
    first_line: usize,
    /// 첫 줄의 몇 번째 **조각**부터 그리는가. 랩이 켜졌을 때 화면이 줄 중간에서 시작하는 상태다
    /// (§4 — 세로 스크롤이 시각 행 단위다). 범위를 넘으면 `content`가 0으로 접는다.
    first_piece: u32 = 0,
    /// 가로 스크롤 오프셋(열). 랩이 켜져 있으면 의미가 없다.
    first_col: u16 = 0,
    /// 문서 전체의 논리 줄 수. 보통 `lines.len`이지만, 줄 번호 자릿수(gutter 폭)를 문서 전체
    /// 기준으로 잡아야 하므로 따로 받는다.
    total_lines: usize,
    /// **이 줄이 추가인가 삭제인가**(비교 본문). 논리 줄 인덱스로 읽는다. `null`이면 밴드를 그리지
    /// 않는다 — 문서 편집기는 이 축이 없다.
    row_bands: ?[]const RowBand = null,
    /// 논리 줄마다 바뀐 글자 범위(없으면 빈 슬라이스). `row_bands`와 같은 인덱스 축이다.
    row_marks: ?[]const []const Mark = null,
    /// **줄 번호를 밖에서 준다**(논리 줄 인덱스로 읽는 표, `null` 항목 = 번호 없음). diff 본문이
    /// 쓴다 — 좌우가 나란히 서지만 번호는 각자 문서의 것이고, 짝을 맞추려 넣은 빈 행에는 번호가
    /// 없다. `null`이면 지금까지대로 `first_line + 줄 + 1`이다.
    line_numbers: ?[]const ?u32 = null,
    /// 문서 전체의 **시각 행** 수를 이미 알고 있으면 여기 넣는다. `null`이면 `lines`를 훑어 센다 —
    /// 줄당 전개가 들어가므로 큰 문서에서는 호출자가 캐시한 값을 주는 편이 낫다(§2 L2 캐시).
    ///
    /// **이것만 주면 막대 위치는 여전히 여기서 센다**(화면 맨 위 줄까지의 접두 합계). 그 계수까지
    /// 건너뛰려면 `first_visual_row`를 함께 준다 — 하나만 주고 나머지를 논리 줄로 대신하면 랩된
    /// 문서에서 막대가 틀린 자리에 선다(리뷰가 그 상태를 잡았다).
    total_visual_rows: ?u32 = null,
    /// 화면 맨 위 줄까지의 **시각 행** 수. `null`이면 여기서 센다.
    first_visual_row: ?u32 = null,
    /// 그릴 수 있는 시각 행 수(뷰포트 높이 / 셀 높이).
    visible_rows: u16,
    wrap: bool,
    tab_width: u8 = 4,

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

/// 비교 본문에서 한 줄이 무엇인가. **`none`은 색을 칠하지 않는다** — context와, 짝을 맞추려 넣은 빈
/// 행이 여기 든다(빈 행에 색을 칠하면 "그 자리에 무언가 있다"고 말하게 된다).
pub const RowBand = enum { none, added, removed };

/// 줄 배경의 세기. **알파로 얹는다** — 배경색을 가정하면 한쪽 테마에서 글자가 안 읽힌다
/// (CM6 `diff-theme.ts`가 같은 이유로 16%를 썼다. 여기 값은 그 관측을 옮긴 것이다).
pub const band_alpha: u8 = 41; // ≈16%
/// **바뀐 글자**의 세기(§3.5 "줄 전체에 옅은 색을 깔고 바뀐 글자만 진하게"). 줄 배경 위에 한 겹 더
/// 얹으므로 그 차이가 곧 "이 글자가 달라졌다"는 신호다(CM6 `diff-theme.ts`가 34%를 쓴 그 자리다).
pub const mark_alpha: u8 = 87; // ≈34%
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

pub const Written = struct {
    ops: usize,
    /// **문서 전체**의 시각 행 수(랩 포함). 스크롤 입력이 "이 문서가 화면에 다 들어가는가"를 이 값으로
    /// 판정한다 — 논리 줄 수로는 랩된 문서에서 그 판정이 틀린다(입력 쪽이 접힘을 모른다).
    total_visual_rows: u32,
    /// 실제로 그린 시각 행 수. 호출자가 스크롤 clamp에 쓴다.
    visual_rows: usize,
    /// 저장소가 모자라 잘린 몫이 있는가. 캡처에는 빈 자리로 나타난다.
    truncated: bool,
    /// 그린 막대의 기하. 스크롤이 필요 없으면 `null`이고 그때는 막대 op도 없다.
    /// 드래그·클릭을 붙일 때 호출자가 쓴다(`scroll_area.offsetForPointer`).
    scrollbar: ?scroll_area.ScrollbarGeometry,
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
        scratch.content_rows[n] = .{ .bytes = props.lines[props.first_line + n] };
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
        gutter.scratchNeeded(@intCast(visual_budget), props.total_lines),
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
    const total_visual: u32 = props.total_visual_rows orelse blk: {
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
    const band_ops = paintBands(props, layout, scratch.visual_rows[0..cw.visual_rows], scratch.ops[bg.ops + cw.ops + gw.ops ..], scratch.count_scratch);

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
    }, scratch.ops[bg.ops + cw.ops + gw.ops + band_ops ..]);

    return .{
        .total_visual_rows = total_visual,
        .ops = bg.ops + cw.ops + gw.ops + sw.ops + band_ops,
        .visual_rows = cw.visual_rows,
        .truncated = cw.truncated_rows > 0 or gw.dropped_rows > 0,
        .scrollbar = sw.geometry,
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
        // **접힌 조각에는 아직 칠하지 않는다.** 열 계산이 줄 처음부터이므로 두 번째 조각의 열은
        // 그 조각이 어디서 시작하는지를 알아야 하는데, 그 값은 `visual_map`이 자를 때만 안다.
        // 접힘 조각 경계를 프레임까지 들고 오는 것은 별도 작업이라, 그때까지 랩된 줄은 **밴드만**
        // 남는다(강조가 엉뚱한 자리에 서는 것보다 없는 편이 낫다).
        if (v.piece != 0) continue;
        const marks = (props.row_marks orelse continue);
        if (idx >= marks.len) continue;
        const row_marks = marks[idx];
        if (row_marks.len == 0) continue;
        const line = if (idx < props.lines.len) props.lines[idx] else continue;

        // **줄을 한 번만 지난다.** 위치마다 앞부분을 다시 펴면 마크가 많은 줄에서 비용이 곱으로 붙는다
        // (200자 줄에 마크 100개 = 한 행에 4만 스텝, 화면 50행이면 프레임당 수백만). 물어볼 위치를
        // 모아 한 번에 채운다 — 저장소가 모자라면 앞에서부터 담을 수 있는 만큼만 그린다.
        const max_pairs = @min(row_marks.len, scratch_cols.len / (2 * @sizeOf(u32)));
        if (max_pairs == 0) continue;
        const offsets = std.mem.bytesAsSlice(u32, scratch_cols[0 .. max_pairs * 2 * @sizeOf(u32)]);
        for (row_marks[0..max_pairs], 0..) |m, k| {
            offsets[k * 2] = m.start;
            offsets[k * 2 + 1] = m.start + m.len;
        }
        // 화면 오른쪽 끝을 넘으면 멈춘다 — 그 뒤 마크는 어차피 아래에서 잘린다.
        content.columnsAtOffsets(line, props.tab_width, offsets, offsets, @as(u32, props.first_col) + layout.content.width); // 제자리 채우기
        for (row_marks[0..max_pairs], 0..) |_, k| {
            if (n >= out.len) break;
            const start_col = offsets[k * 2];
            const end_col = offsets[k * 2 + 1];
            if (end_col <= start_col) continue;
            // 가로 스크롤·본문 폭 밖은 자른다 — 넘치면 gutter나 옆 열을 침범한다.
            // **왼쪽도 자른다.** 화면 밖에서 시작하는 마크를 그대로 쓰면 아래 뺄셈이 음수가 되고
            // (u32라 오버플로로 죽는다), 가로 스크롤이 붙는 순간 그 자리에서 터진다.
            const from = @max(start_col, props.first_col);
            const to = @min(end_col, @as(u32, props.first_col) + layout.content.width);
            if (to <= from) continue;
            // **본문은 gutter 뒤에서 시작한다.** pane 원점부터 세면 강조가 줄 번호 위에 선다
            // (첫 캡처가 정확히 그랬다) — 본문 시작 열(`contentLeft`)을 더한다.
            const col_on_screen: u32 = @as(u32, layout.contentLeft()) + (from - props.first_col);
            const x = props.rect.x + @as(i32, @intCast(col_on_screen * props.cell_w_px));
            out[n] = .{ .quad = .{
                .rect = .{ .x = x, .y = y, .w = (to - from) * props.cell_w_px, .h = props.cell_h_px },
                .fill_role = role,
                .alpha = mark_alpha,
            } };
            n += 1;
        }
    }
    return n;
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

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
    const long = "z" ** 500;
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
        .lines = &lines,
        .first_line = 0,
        .total_lines = 1,
        .row_bands = &bands,
        .visible_rows = 6,
        .wrap = true,
        .rect = .{ .x = 0, .y = 0, .w = 120, .h = 96 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 10,
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

test "랩된 줄: 첫 조각에만 강조가 서고 이어진 조각에는 안 선다" {
    // **의도된 한계를 고정한다.** 두 번째 조각의 시작 열은 `visual_map`이 자를 때만 아는 값이라,
    // 지금은 첫 조각에만 그린다. 이 테스트가 없으면 나중에 조각 경계를 넘길 때 "원래 그려졌는지"를
    // 아무도 모른다 — 한계인지 회귀인지 구분이 안 된다.
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
        .lines = &lines,
        .first_line = 0,
        .total_lines = 1,
        .row_bands = &bands,
        .row_marks = &marks,
        .visible_rows = 6,
        .wrap = true,
        .rect = .{ .x = 0, .y = 0, .w = 120, .h = 96 },
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 16,
        .total_cols = 10,
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
    // 강조는 **첫 조각(y = 0)에만** 선다 — 접힌 뒤쪽 마크는 지금 그리지 않는다.
    try testing.expect(n > 0);
    for (mark_rows[0..n]) |y| try testing.expectEqual(@as(i32, 0), y);
    // 밴드는 조각 전부에 깔린다(그쪽은 이미 고정돼 있다) — 강조만 첫 조각인 것이 이 한계다.
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
