//! 편집기 **본문 텍스트**를 draw op으로 낸다 — gutter 오른쪽에 파일 내용을 그리는 부분.
//!
//! 자리는 [geometry.zig](geometry.zig)의 `content` 영역이고(§4.1), 배치는 **셀 격자**다
//! ([native-editor-layering.md](../../../../docs/native-editor-layering.md) §2.0) — 등폭 고정이 세로 정렬·블록 선택·
//! goal column의 전제이므로 measured 경로를 쓰지 않는다.
//!
//! **N1 범위**: 랩은 있고(`wrap` prop — `visual_map`이 나눈다) **접힘·가상 텍스트는 없다.** 랩이
//! 꺼지면 시각 행 하나가 논리 줄 하나에 대응해 §4 세로 축이 항등으로 떨어진다.
//!
//! **시각 배치를 이 모듈이 정한다.** 어느 논리 줄이 몇 행으로 접히는지는 전개해서 나눠 본 쪽만 알기
//! 때문이다 — gutter는 `visual_out`으로 받은 결과를 따른다(`gutter.rowsForVisual`). 둘이 각자 행을
//! 세면 랩된 줄에서 번호가 본문과 어긋난다.

const std = @import("std");
const builtin = @import("builtin");
const chrome = @import("../../../chrome.zig");
const geometry = @import("geometry.zig");
const text_layout = @import("../../text_layout.zig"); // 텍스트 셀 배치 단일 출처(cluster 분절·폭)
const display_width = @import("../../../display_width.zig"); // §4.2 표시 폭 — 셀 배치(system_text)와 같은 규칙
const hazard = @import("../../../hazard.zig"); // §3.8 적대적 입력 판정 — 순수 유니코드(레이어 무관 중립)
const visual_map = @import("../../ui/visual_map.zig"); // §4 세로 축 — 전개된 줄을 시각 행으로 나눈다

const draw = chrome.draw;
const tokens = chrome.tokens;

/// 그릴 **논리 줄** 하나. `bytes`는 **줄바꿈을 뺀 내용**이며 문서 버퍼를 빌려 쓴다(복사하지 않는다).
///
/// **시각 행 인덱스를 담지 않는다.** 랩이 켜지면 이 줄이 시각 행 몇 개가 될지는 전개해서 나눠 봐야
/// 알 수 있으므로(`visual_map` 참고) 호출자가 미리 정할 수 없다. 배치는 `build`가 정해 `visual_out`에
/// 돌려주고 gutter가 그것을 따른다.
pub const Row = struct {
    bytes: []const u8,
    /// **이 줄의 색 구간**(§5.3 구문 강조 1층). 비어 있으면 줄 전체가 본문색이다 —
    /// grammar가 없거나 파싱이 실패했을 때가 그렇고, 그것이 §5의 *"무색"*이다.
    ///
    /// **논리 열 기준이다**(byte가 아니다). 이 모듈은 이미 열로 배치를 정하고, byte→열 변환은
    /// `columnsAtOffsets` 하나가 소유한다 — 여기서 다시 변환하면 탭스톱 규칙이 두 곳이 되고
    /// 그 둘은 갈린다(이 파일이 반복해서 적어 둔 함정이다). 그래서 **호출자가 그 함수로 옮겨서**
    /// 넘긴다.
    ///
    /// **오름차순이고 겹치지 않아야 한다.** 겹치면 뒤엣것이 조용히 무시된다 — tree-sitter는 한
    /// 범위에 캡처를 여럿 내므로(그 모듈 머리말 참고) **겹침 해소는 호출자의 일**이다.
    colors: []const ColorSpan = &.{},
};

/// 한 색 구간. `end_col`은 **배타적**이다.
pub const ColorSpan = struct {
    start_col: u32,
    end_col: u32,
    role: tokens.ColorRole,
};

pub const Props = struct {
    layout: geometry.Layout,
    rows: []const Row,
    /// 랩. 켜지면 논리 줄 하나가 본문 폭에서 접혀 시각 행 여럿이 된다(§4 세로 축).
    /// 꺼지면 줄이 본문 폭에서 잘리고 그 너머는 `first_col`로 본다.
    wrap: bool = false,
    /// **가로 스크롤 위치**(§4). 본문의 이 열부터 그린다. gutter는 이 값에 밀리지 않는다 —
    /// 줄 번호와 diff 색 띠는 늘 보여야 한다.
    ///
    /// **랩이 켜지면 0이어야 한다.** 줄이 폭 안에 들어와 스크롤할 것이 없기 때문인데, 이 모듈은
    /// 그것을 강제하지 않는다 — §4가 정한 대로 **범위 clamp가 처리할 몫**이고(랩이면 최대 범위가
    /// 0이 되어 위치가 0으로 눌린다) 그 clamp는 스크롤바 슬라이스에 속한다. 여기서 따로 0을 박으면
    /// 규칙이 두 곳에 생긴다.
    first_col: u16 = 0,
    /// **첫 논리 줄에서 건너뛸 조각 수** — 랩된 줄의 *중간 행*부터 화면이 시작할 때 쓴다.
    ///
    /// 세로 스크롤이 시각 행 단위이려면 이것이 있어야 한다(`visual_map.RowIndex.resolve`가 주는
    /// `piece`가 그대로 들어온다). 없으면 뷰포트가 논리 줄 경계에서만 멈출 수 있어, **랩된 줄
    /// 하나가 화면보다 길면 그 아래를 볼 방법이 없다.**
    first_piece: u32 = 0,
    cell_w_px: u16,
    cell_h_px: u16,
    /// 이 뷰의 폰트 크기(device px). 셀 크기와 **같은 폰트에서** 나와야 배치와 글자가 어긋나지 않는다.
    font_px: u16,
    origin_px: draw.Px,
    /// 탭 하나가 밀어내는 칸 수. 탭은 **고정 폭이 아니라 다음 탭스톱까지**다(§4 가로 축).
    tab_width: u16 = 4,
};

pub const text_role: tokens.ColorRole = .surface_fg;

/// 조각 텍스트를 **색이 갈리는 자리에서** run으로 쪼갠다. 쓴 run 수를 돌려준다.
///
/// **열을 여기서 다시 센다 — 다만 규칙은 빌려 쓴다.** `columnsOf`와 **같은 걸음**(cluster 분절 +
/// `display_width`)이라 2칸 글자·§3.8 표기에서 갈리지 않는다. 새 규칙을 쓰면 색 경계가 글자에서
/// 밀리는데, 그 어긋남은 크래시도 테스트 실패도 없이 화면에만 나타난다.
///
/// **run 예산이 다하면 마지막 칸에 남은 글자를 통째로 싣는다.** 색은 그 자리의 것으로 번지지만
/// **글자는 하나도 안 잃는다** — 이 파일이 scratch·op 예산에서 내린 판단(줄이지 화면을 지우지
/// 않는다)과 같은 방향이다.
///
/// 그러려면 **마지막 칸을 미리 비워 둬야 한다**(`written + 1 >= out_runs.len`에서 멈춘다).
/// 처음에는 그냥 `written >= out_runs.len`에서 멈췄는데, 그러면 꼬리를 쓸 칸이 없어 **줄 끝이
/// 조용히 사라졌다** — `HL14`가 그것을 잡았고, 위 주석은 코드가 안 하는 일을 적고 있었다.
fn writeRuns(text: []const u8, start_col: u32, colors: []const ColorSpan, out_runs: []draw.Run) usize {
    if (out_runs.len == 0) return 0;
    // **색이 없으면 한 run이다.** 흔한 경우(grammar 없음·무색 줄)라 걷지 않고 빠져나간다.
    if (colors.len == 0) {
        out_runs[0] = .{ .text = text };
        return 1;
    }

    var written: usize = 0;
    var i: usize = 0;
    var col: u32 = start_col;
    var seg_start: usize = 0;
    var cursor: usize = 0; // colors 를 앞으로만 훑는다 — 줄당 한 번 지나간다
    var seg_role: ?tokens.ColorRole = roleAt(colors, &cursor, col);

    while (i < text.len) {
        const base = text_layout.decodeCodepoint(text, i);
        const end = @min(text_layout.clusterEndAfter(text, i, base.advance), text.len);
        const n = @max(1, end - i);
        const role = roleAt(colors, &cursor, col);
        if (role != seg_role) {
            if (i > seg_start) {
                // **마지막 칸은 꼬리 몫이다.** 여기서 다 쓰면 남은 글자를 실을 자리가 없다.
                if (written + 1 >= out_runs.len) break;
                out_runs[written] = .{ .text = text[seg_start..i], .role = seg_role };
                written += 1;
                seg_start = i;
            }
            seg_role = role;
        }
        col += display_width.clusterCols(text, i, i + n);
        i += n;
    }
    if (seg_start < text.len and written < out_runs.len) {
        out_runs[written] = .{ .text = text[seg_start..], .role = seg_role };
        written += 1;
    }
    // 예산이 0이 되어 아무것도 못 쓴 경우는 위에서 걸렀지만, 그래도 **빈 run 묶음을 내지 않는다** —
    // 그러면 op이 아무 글자도 안 그린다.
    if (written == 0) {
        out_runs[0] = .{ .text = text };
        written = 1;
    }
    return written;
}

/// `col`을 덮는 구간의 역할. `cursor`는 **뒤로 가지 않는다** — 한 줄을 한 번만 지나간다.
fn roleAt(colors: []const ColorSpan, cursor: *usize, col: u32) ?tokens.ColorRole {
    while (cursor.* < colors.len and colors[cursor.*].end_col <= col) cursor.* += 1;
    if (cursor.* >= colors.len) return null;
    const c = colors[cursor.*];
    return if (col >= c.start_col and col < c.end_col) c.role else null;
}

/// gutter와 같은 이유로 각 저장소에서 쓴 양을 돌려준다(`gutter.Written` 참고).
pub const Written = struct {
    ops: usize,
    bytes: usize,
    runs: usize,
    /// `visual_out`에 채운 시각 행 수. 랩이 꺼지면 논리 줄 수와 같고, 켜지면 그보다 많을 수 있다.
    visual_rows: usize = 0,
    /// 저장소가 모자라 **끝까지 만들지 못한 줄의 수**.
    ///
    /// 절단은 실패가 아니지만(그래서 `build`가 성공한다) **조용해서도 안 된다** — 화면에서는 그냥
    /// 짧은 줄로 보여서 사용자가 "여기가 줄 끝"이라고 착각한다.
    /// [document-model.md](../../../../docs/native-editor-document-model.md) §3.0이 축소 단계마다
    /// *"사용자에게 왜 줄었는지 알린다(조용히 꺼지면 버그로 보인다)"*를 요구하므로, 알릴 수단
    /// (상태바)이 붙을 때까지 **값만 여기까지 올려 둔다.**
    truncated_rows: usize = 0,
};

/// 본문 draw op을 채우고 쓴 양을 돌려준다. **할당하지 않는다.**
///
/// 탭은 **공백으로 전개해서** 넘긴다. 셀 경로가 `\t`를 그리면 폰트에 없는 글리프가 되거나 한 칸으로
/// 뭉개져 들여쓰기가 무너진다. 전개는 여기서 하고 렌더러는 완성된 문자열만 받는다.
///
/// 전개는 **탭스톱 기준**이다 — `tab_width`만큼 무조건 넣는 것이 아니라 다음 배수까지 채운다.
/// `a\tb`에서 탭이 3칸이고 `ab\tc`에서 2칸인 것이 그 차이이며, 이걸 틀리면 코드 들여쓰기가 어긋난다.
/// `visual_out`은 **몇 행까지 그릴지의 상한이기도 하다** — 뷰포트 높이만큼 주면 화면을 채운 순간
/// 멈춘다. 랩이 켜지면 논리 줄 하나가 화면 전체를 덮을 수 있으므로 이 상한이 없으면 긴 줄에서
/// 무한히 op을 낸다.
pub fn build(
    props: Props,
    out: []draw.Op,
    text_scratch: []u8,
    runs: []draw.Run,
    visual_out: []visual_map.VisualRow,
) Written {
    // **랩이 켜지면 가로 위치는 0이다**(§4). 줄이 폭 안에 들어와 스크롤할 것이 없기 때문이고,
    // 그 방침대로면 범위 clamp가 위치를 0으로 눌러 준다 — **그 clamp가 아직 없으므로 여기서
    // 강제한다.** 안 그러면 "밀린 채 접히는" 상태가 되는데, 그건 계약에 없는 동작이다(실측:
    // 첫 조각만 밀리고 나머지가 그 뒤에서 이어진다).
    std.debug.assert(!props.wrap or props.first_col == 0);

    if (props.layout.content.isEmpty()) return .{ .ops = 0, .bytes = 0, .runs = 0 };

    var op_count: usize = 0;
    var scratch_used: usize = 0;
    var run_used: usize = 0;
    var visual_row: u16 = 0;
    var truncated_rows: usize = 0;

    const view_cols = props.layout.content.width;

    for (props.rows, 0..) |row, line_idx| {
        if (visual_row >= visual_out.len) break; // 화면이 찼다

        // **전개 상한은 앞으로 그릴 수 있는 행 수만큼이다.** 랩이 꺼지면 한 행(`view_cols`)이고,
        // 켜지면 남은 행을 다 채울 만큼(`남은 행 × view_cols`)이다. 어느 쪽이든 **화면 폭·높이에
        // 비례**하지 줄 길이에 비례하지 않는다 — 이 상한이 없으면 minified JS 한 줄이 scratch를
        // 삼켜 `build` 전체가 죽는다.
        const rows_left: usize = visual_out.len - visual_row;
        // **건너뛸 조각도 전개해야 한다.** `first_piece`가 가리키는 조각은 화면에 없지만 그 앞
        // 글자를 지나야 거기에 닿는다 — 예산에서 빼면 화면 아래쪽이 조용히 빈다(코드 리뷰가
        // 실측으로 잡았다: 5조각 줄에 `first_piece=2`, 3행 뷰포트에서 조각 3·4가 사라지고 다음
        // 논리 줄이 올라왔다).
        const skip_hint: usize = if (line_idx == 0) props.first_piece else 0;
        const budget_cols: usize = if (props.wrap)
            (skip_hint + rows_left) * @as(usize, view_cols)
        else
            view_cols;
        const expand_cols: u32 = @intCast(@min(budget_cols, std.math.maxInt(u32)));

        // **전개는 실패하지 않는다.** 저장소가 모자라면 거기까지만 만들고 `truncated`로 알린다 —
        // 긴 줄 하나가 프레임 전체를 지우던 결함(#2086)이 랩에서 되살아나지 않게 하는 자리다.
        const r = expandTabs(row.bytes, props.tab_width, text_scratch[scratch_used..], .{ .start = props.first_col, .count = expand_cols });
        const expanded = r.text;
        // **탭이 없으면 scratch를 쓰지 않았다.** 그때도 길이를 더하면 저장소가 실제보다 빨리 차서
        // 아래쪽 줄이 근거 없이 OutOfSpace로 죽고, 호출자에게 보고하는 `bytes`도 과대해진다.
        scratch_used += r.scratch_used;
        if (r.truncated) truncated_rows += 1;

        // **`first_piece`가 실제 조각 수를 넘으면 무시한다.** 그대로 두면 **첫 논리 줄이 통째로
        // 사라지고 다음 줄이 그 자리에 올라온다** — 리사이즈 한 번에 화면이 문서의 다른 곳으로
        // 튀는 셈이다. 줄을 지우느니 처음부터 보여준다.
        //
        // **assert로 막지 않는다.** 처음엔 `assert(first_piece < have)`를 넣었는데, 그것이 아래
        // fallback에 닿기 전에 앱을 죽였다(적대적 검증이 재현했다). 넘는 값은 **일어날 수 있는
        // 상태**다 — `RowIndex` 주석 자체가 "무효화를 호출자가 판단한다"고 적었고, 뷰 폭·탭 폭·랩
        // 토글이 바뀌면 살아남은 스크롤 위치가 곧 그 값이 된다. assert는 "절대 일어나면 안 되는
        // 것"에 쓰는 도구이지, 복구 가능한 낡은 입력에 쓰는 것이 아니다.
        const skip: u32 = if (line_idx == 0 and props.first_piece != 0) blk: {
            var probe = visual_map.pieces(expanded, view_cols, props.wrap);
            var have: u32 = 0;
            while (probe.next()) |_| have += 1;
            break :blk if (props.first_piece >= have) 0 else props.first_piece;
        } else 0;

        var it = visual_map.pieces(expanded, view_cols, props.wrap);
        var piece_idx: u32 = 0;

        // **조각 시작을 두 축으로 따라간다** — 열과 **원본 byte**(§4.1g).
        //
        // 열은 조각 폭을 누적하면 나온다(`Piece.cols`). 원본 byte는 그렇게 안 된다: 조각 경계는
        // **전개 텍스트** 기준이라(탭이 공백 여럿, §3.8 문자가 표기로 바뀐 뒤) 그 offset이 문서 위치가
        // 아니다. 그래서 원본을 `stepColumn`으로 **병행해** 걷는다 — 두 걸음이 어긋나지 않는 근거는
        // **열의 정의가 두 좌표계에서 같다**는 것이고, 무작위 600줄에서 0건 불일치로 쟀다(§4.1g 실측).
        //
        // 걷는 총 거리는 줄을 한 번 지나는 것이다(조각마다 앞에서 다시 시작하지 않는다).
        //
        // **시작 열은 `first_col`이다.** 전개가 거기서부터 만들어지므로(`expandTabs`의 `.start`)
        // 첫 조각도 줄 머리가 아니라 그 자리에서 시작한다. 랩이 켜지면 `first_col`은 0이고(랩은
        // 넘칠 것을 없애 가로 축을 지운다 — §4), 랩이 꺼지면 조각이 하나라 이 값이 그대로 남는다.
        // 그래서 두 경우가 같은 식으로 처리된다.
        var start_col: u32 = props.first_col;
        var src_i: usize = 0;
        var src_col: u32 = 0;

        while (it.next()) |piece| : (piece_idx += 1) {
            // **원본을 이 조각의 시작 열까지 전진시킨다 — 걸친 cluster는 렌더가 하는 대로 따른다.**
            //
            // 전개가 걸친 것을 처리하는 방식이 **종류마다 다르고**, 병행 걸음이 그것을 따라야 한다:
            //
            // - **일반 cluster**는 *"통째로 뺀다"*(`expandTabs`의 `col >= range.start`) — 셀 격자라
            //   반쪽을 그릴 수 없다. 그래서 화면 0열의 byte는 **버려진 cluster 다음**이고, 걸음도
            //   지나가야 한다.
            // - **탭**은 *"공백이라 걸쳐도 잘라 낼 수 있다"*(`from = @max(col, range.start)`) — 잔여
            //   폭이 화면 0열부터 그려진다. 그래서 그 자리의 byte는 **탭 자신**이고, 걸음은 머문다.
            // - **§3.8 표기**도 같다(`shown_from`) — ASCII 문자열이라 잘라 그린다.
            //
            // 셋을 한 규칙으로 뭉치면 어느 쪽이든 어긋난다. 실측(적대적 검증 3·4회차): 지나가기만
            // 하면 한글 straddle은 19% → 0%로 낫지만 **랩+탭이 0% → 26.4%로 깨지고**, 머물기만 하면
            // 그 반대다.
            //
            // 머무는 경우 `src_col`이 `start_col`보다 작게 남는데, 그 값이 `start_byte_col`로 실려
            // **탭스톱 계산의 시작점**이 된다(탭 폭은 줄 절대 열로 정해진다).
            while (src_i < row.bytes.len and src_col < start_col) {
                const st = stepColumn(row.bytes, src_i, src_col, props.tab_width);
                if (st.next_col > start_col) {
                    // 걸쳤다. 렌더가 잘라 그리는 종류면 여기 머물고, 버리는 종류면 지나간다.
                    const splits = splitsWhenStraddling(row.bytes, src_i);
                    if (!splits) {
                        src_i = st.next_byte;
                        src_col = st.next_col;
                    }
                    break;
                }
                src_i = st.next_byte;
                src_col = st.next_col;
            }
            // **첫 줄의 앞 조각들은 화면 위로 지나간 부분이다.** 행을 세지도 배치를 채우지도
            // 않는다 — 그 조각들은 화면에 없다.
            // **누적은 건너뛴 조각에도 일어나야 한다.** `skip`이 가리키는 앞 조각들은 화면 위로
            // 지나갔지만 **열은 지나간 만큼 밀려 있다** — 여기서 안 더하면 화면 첫 행의 시작 열이
            // 0이 되어 그 줄 전체의 강조가 왼쪽으로 밀린다.
            defer start_col += piece.cols;
            if (piece_idx < skip) continue;
            if (visual_row >= visual_out.len) break;

            // **빈 조각도 시각 행을 차지한다.** 그릴 글자가 없어도 그 행은 화면에서 한 줄이고 gutter가
            // 번호를 그려야 한다 — op만 건너뛰고 행은 센다. 이걸 빼면 빈 줄 아래의 번호가 밀린다.
            visual_out[visual_row] = .{
                .line = @intCast(line_idx),
                .piece = piece_idx,
                // **화면 0열의 열**과 **시작 byte의 열**을 따로 싣는다. 걸친 것을 지나갔으면 둘이
                // 같고(`src_col`), 머물렀으면 byte 쪽이 더 작다(위 루프 주석).
                .start_col = @max(src_col, start_col),
                .start_byte = @intCast(src_i),
                .start_byte_col = src_col,
            };
            const text = piece.slice(expanded);
            defer visual_row += 1;
            if (text.len == 0) continue;

            // **op·run 예산이 다해도 죽지 않는다.** scratch를 절단으로 바꾼 것과 같은 이유이고
            // (#2086: 화면에 덜 나오는 것 > 편집기가 통째로 안 그려지는 것), **랩이 붙으면서 이
            // 경로가 실제로 위험해졌다** — 한 줄이 op을 여러 개 쓰므로 긴 줄 하나가 예산을 다 쓸 수
            // 있다. 그때 에러를 올리면 그 줄만이 아니라 프레임 전체가 사라진다.
            //
            // **배치(`visual_out`)는 이미 채웠으므로 gutter가 번호를 그린다** — 본문만 비고 번호는
            // 나온다. 번호가 없으면 화면 전체가 어느 위치인지 알 수 없다는 것이 같은 PR의 결론이다.
            if (run_used >= runs.len or op_count >= out.len) continue;

            const run_start = run_used;
            run_used += writeRuns(text, @max(src_col, start_col), row.colors, runs[run_used..]);
            const run_slice = runs[run_start..run_used];

            out[op_count] = .{
                .text = .{
                    .origin = .{
                        .x = props.origin_px.x +
                            @as(i32, props.layout.content.start) * @as(i32, props.cell_w_px),
                        .y = props.origin_px.y + @as(i32, visual_row) * @as(i32, props.cell_h_px),
                    },
                    .runs = run_slice,
                    .role = text_role,
                    // 본문 영역을 넘는 글자는 자른다. 랩이 꺼졌을 때 긴 줄이 gutter 옆 창 밖까지
                    // 그려지는 것을 막는 마지막 방어선이다(랩이 켜지면 조각이 이미 폭 안이다).
                    .max_cols = view_cols,
                    // 등폭 셀 격자에 그린다(§2.0) — 폰트 크기가 셀에서 나오고 글자 x가 셀 배수로 스냅된다.
                    .font_px = props.font_px,
                    .line_height_px = props.cell_h_px,
                    .cell_w_px = props.cell_w_px,
                },
            };
            op_count += 1;
        }
    }

    return .{
        .ops = op_count,
        .bytes = scratch_used,
        .runs = run_used,
        .visual_rows = visual_row,
        .truncated_rows = truncated_rows,
    };
}

/// 이 줄이 차지하는 **시각 행 수**. 스크롤바가 문서 전체 길이를 알아야 해서 필요하다
/// (§2 캐시 표의 "시각행 수·시각행 ↔ 논리행", L3 소유).
///
/// **전개를 거쳐 센다 — 열을 따로 세지 않는다.** 처음에는 `visual_map`에 "전개하지 않고 열만 세는"
/// 경량 경로를 두었는데, 같은 규칙을 두 곳에 쓰자마자 갈렸다. 교차 검증으로 잰 불일치가 **990건 중
/// 80건**이었고 원인이 매번 달랐다:
///
/// - 행 머리에서 넘치면 또 넘기던 것(뷰보다 넓은 글자)
/// - 탭이 행 경계에서 **쪼개진다**는 것(2칸 글자와 달리 공백 여럿이라 이어진다)
/// - `col`이 뷰 폭을 넘은 상태에서의 정수 언더플로(`가<TAB>나`·뷰 1열)
/// - §3.8 표기가 **1칸 글자 여덟 개**로 쪼개져 여러 행에 걸치는 것
///
/// 마지막 하나까지 맞추려면 전개 로직을 통째로 복제해야 한다. 그래서 복제를 버리고 **전개 결과를
/// 그대로 나눈다** — 규칙이 한 곳에만 있으므로 갈릴 수 없다.
///
/// `scratch`는 한 줄분이면 되고 줄마다 재사용한다. 모자라면 `expandTabs`가 절단해 행 수가 실제보다
/// 적어지는데, **그 사실을 `RowCount.truncated`로 함께 돌려준다** — §3.8이 "초장문에서 기능을
/// 줄인다"고 허용한 범위이지만 **조용해서는 안 되기 때문이다**(그 값이 스크롤바 길이가 되므로,
/// 알리지 않으면 문서가 일찍 끝난 것처럼 보인다).
/// `rowCount`에 줄 저장소를 **얼마나 줘야 하는가**. 세는 쪽과 그리는 쪽이 이 값을 함께 쓴다 —
/// 둘이 갈리면 같은 줄의 행 수가 달라진다.
///
/// **8 KiB로는 모자랐다**: 탭이 든 1만 바이트 줄(TSV·로그)이 8 KiB에서 **103행**, 넉넉한 저장소에서
/// **250행**이었다(실측. 적대적 검증 2026-08-17). 랩에서 그 줄의 59%가 그려지지도 닿지도 않는다.
/// 위의 "전개가 원본과 같으면 저장소를 안 쓴다" 빠른 길은 **탭이 있으면 안 탄다** — 그래서 한글 긴
/// 줄에서 겪은 같은 사고(60행 대 1,305행. 2026-08-16)가 탭 줄에는 그대로 남아 있었다.
///
/// 64 KiB면 전개 6만 열까지 덮는다. 그보다 긴 줄은 여전히 절단되지만 `RowCount.truncated`가 알린다.
pub const count_scratch_bytes: usize = 64 * 1024;

pub fn rowCount(bytes: []const u8, tab_width: u16, view_cols: u16, wrap: bool, scratch: []u8) RowCount {
    if (!wrap or view_cols == 0) return .{ .rows = 1 };

    // **전개가 원본과 같으면 저장소를 쓰지 않는다.** 탭도 §3.8 표기도 없으면 `expandTabs`가 만들
    // 텍스트가 원본 그대로이므로 그것을 그대로 센다 — `expandTabs`의 원본 대여 길은 `isAsciiOnly`를
    // 요구하는데(열 상한을 byte로 지키려고), 여기서는 열 상한이 없어 그 조건이 필요 없다.
    //
    // **이게 없으면 긴 비ASCII 줄에서 조각 수가 조용히 적게 나온다**: 6만 자 한글 줄이 8KB 저장소로
    // **60행**, 넉넉한 저장소로 **1,305행**이었다(실측 — 21배). 세로 스크롤이 그 줄의 5%까지만
    // 닿는다는 뜻이다(적대적 검증 2026-08-16).
    if (std.mem.indexOfScalar(u8, bytes, '\t') == null and !hazard.containsAny(bytes)) {
        var plain = visual_map.pieces(bytes, view_cols, wrap);
        var m: u32 = 0;
        while (plain.next()) |_| m += 1;
        return .{ .rows = @max(m, 1) };
    }

    const r = expandTabs(bytes, tab_width, scratch, .{ .count = std.math.maxInt(u32) });
    var it = visual_map.pieces(r.text, view_cols, wrap);
    var n: u32 = 0;
    while (it.next()) |_| n += 1;
    return .{ .rows = n, .truncated = r.truncated };
}

/// `rowCount`의 결과. **절단 여부를 함께 돌려준다** — 이 모듈의 다른 곳과 같은 규율이다
/// (`Written.truncated_rows` 주석의 §3.0 인용 참고). 절단되면 행 수가 실제보다 적고, 그대로
/// 스크롤바 길이가 되면 **문서가 일찍 끝난 것처럼 보이는데** 왜인지 알려주는 신호가 없다.
pub const RowCount = struct {
    rows: u32,
    truncated: bool = false,
};

/// 텍스트가 차지하는 **열 수**. cluster 단위로 세고 폭은 `display_width`가 정한다 — `visual_map`이
/// 조각을 자를 때 쓰는 것과 **같은 규칙**이라 두 곳이 갈리지 않는다.
pub fn columnsOf(text: []const u8) u32 {
    var col: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const base = text_layout.decodeCodepoint(text, i);
        const end = @min(text_layout.clusterEndAfter(text, i, base.advance), text.len);
        const n = @max(1, end - i);
        col += display_width.clusterCols(text, i, i + n);
        i += n;
    }
    return col;
}

/// 줄 안 **바이트 위치**가 화면의 몇 번째 열에서 시작하는가. 탭 전개를 포함한다.
///
/// **앞부분을 실제로 펴서 센다.** 별도의 걷기를 새로 쓰면 탭스톱·cluster·폭 규칙이 두 곳이 되고,
/// 그 둘은 반드시 갈린다(이 저장소가 이미 그런 사고를 겪었다). 탭스톱은 열 0에서 시작하므로
/// **앞부분만 펴도 전체를 편 것의 앞부분과 같다** — 그래서 이 방식이 성립한다.
///
/// `byte_off`는 cluster 경계여야 한다(호출자가 그렇게 만든다 — intra-line 토큰이 cluster다).
/// 저장소가 모자라면 편 결과가 잘리고 열도 그만큼 적게 나온다(죽지 않는다).
pub fn columnOfByte(bytes: []const u8, tab_width: u16, byte_off: usize, scratch: []u8) u32 {
    const off = @min(byte_off, bytes.len);
    if (off == 0) return 0;
    const r = expandTabs(bytes[0..off], tab_width, scratch, .{ .count = std.math.maxInt(u32) });
    return columnsOf(r.text);
}

/// 클릭 지점이 줄의 어느 **원본 byte**인가 — 역방향 변환
/// ([visual-mapping](../../../docs/native-editor-visual-mapping.md) §4.1g의 ④).
///
/// **입력이 픽셀인 이유**는 걸친 cluster의 앞/뒤를 그것으로만 가르기 때문이다. `Selection`은 caret
/// 모델이라 커서가 글자 *사이*에 놓이므로 **1칸 글자에도 앞과 뒤 두 자리**가 있고, 칸으로만 판정하면
/// 그 둘이 같은 답을 받는다(소스의 대부분이 1칸 ASCII다). CM6의 `assoc`, Win32의 trailing edge와 같은
/// 판정이다.
///
/// **결과는 늘 유효하다** — §10이 *"항상 유효한 offset을 반환(clamp)"*이라 정했다. 그래서 역방향은
/// 왕복이 아니고, 불변식은 *"결과가 cluster 경계이고 줄 범위 안"*이라는 더 약한 것이다.
///
/// `start_byte`·`start_col`은 **이 행이 시작하는 자리**다(`visual_map.VisualRow`). 줄 머리부터 걷지
/// 않으므로 거리가 행 폭 이내로 유지된다 — 랩을 켜면 가로 상한이 없어 줄 머리부터 걸으면 줄 길이에
/// 비례한다(§4.1g 실측).
///
/// `x_px`는 **본문 사각 안의 x**다(gutter를 뺀 뒤). gutter는 접힘 화살표가 먼저 가져가므로 이 함수에
/// 오지 않는다.
pub fn byteAtPoint(
    bytes: []const u8,
    tab_width: u16,
    start_byte: usize,
    /// `start_byte`가 있는 **절대 열**(탭스톱 계산의 시작점 — `VisualRow.start_byte_col`).
    start_byte_col: u32,
    /// 화면 0열에 해당하는 **절대 열**(`VisualRow.start_col`). 걸친 탭·§3.8 표기를 렌더가 잘라
    /// 그리면 `start_byte_col`보다 크다.
    screen_col0: u32,
    row_cols: u32,
    x_px: i32,
    cell_w_px: u16,
) usize {
    if (cell_w_px == 0 or bytes.len == 0) return @min(start_byte, bytes.len);
    // 행 왼쪽 밖은 **그 행의 시작**이다(줄 시작이 아니다 — 랩된 두 번째 행부터 둘이 다르다).
    if (x_px <= 0) return @min(start_byte, bytes.len);

    const click_px: u32 = @intCast(x_px);
    // 이 행이 덮는 열 범위. 그 너머는 **행 끝**으로 clamp한다.
    const row_end_col: u32 = screen_col0 +| row_cols;

    var i = @min(start_byte, bytes.len);
    var col = start_byte_col;
    while (i < bytes.len) {
        // **탭스톱은 절대 열로 센다** — 그래서 `col`이 화면 0열이 아니라 진짜 열이어야 한다.
        const st = stepColumn(bytes, i, col, tab_width);
        if (st.next_col > row_end_col) break; // 이 행을 넘어간다 — 행 끝이다

        // (초판에 있던 "화면 왼쪽 밖은 지나간다" 분기는 **구조적으로 도달 불가**라 뺐다 — 계측에서
        //  실행 0회였다. `build`가 세우는 불변식 때문이다: 걸친 것이 잘리는 종류면 걸음이 그 cluster
        //  **안에 머물러** 첫 걸음의 `next_col`이 이미 `screen_col0`을 넘고, 버리는 종류면
        //  `start_byte_col == screen_col0`이라 마찬가지다. 열은 그 뒤로 단조 증가한다.)

        // cluster가 차지하는 픽셀 범위 `[lo, hi)`. 중점보다 왼쪽이면 앞, 아니면 뒤.
        // 잘려 들어온 cluster는 왼쪽이 화면 0에 붙는다.
        //
        // **중점은 정수 나눗셈으로 내린다.** `cell_w_px`가 정수라 폭이 홀수면 중점이 반 픽셀에
        // 걸린다 — 어긋나 봐야 1픽셀이라 보이지 않지만, 방향을 안 정하면 구현마다 답이 갈린다.
        // **뺄셈을 saturating으로 둔다.** 이 걸음이 `screen_col0` 뒤에서 시작한다는 것은 `build`가
        // 세우는 불변식(`start_byte_col <= start_col`)에 기대는데, 그 결합이 이 함수 밖에 있어
        // 호출자가 바뀌면 조용히 깨진다 — 그때 `-`는 u32 언더플로로 **죽는다**. 답이 달라지지
        // 않으면서 죽지만 않게 한다(7차 적대적 검증이 짚었다).
        // (`if (col > screen_col0)` 가드는 뺐다 — `-|`가 saturating이라 그 경우 이미 0이고, 9차
        //  적대적 검증이 **동치 뮤턴트**로 확인했다.)
        const lo = (col -| screen_col0) * cell_w_px;
        const hi = (st.next_col -| screen_col0) * cell_w_px;
        if (click_px < lo + (hi - lo) / 2) return i;
        if (click_px < hi) return st.next_byte;

        i = st.next_byte;
        col = st.next_col;
    }
    // 행 끝 너머 — 마지막으로 지난 자리다.
    return i;
}

/// 시작 열에 **걸쳤을 때** 전개가 그것을 잘라 그리는 종류인가(§4.1g).
///
/// 렌더는 걸친 것을 둘로 나눠 다룬다 — **자를 수 있으면 자르고**(탭은 공백, §3.8은 ASCII 표기),
/// **못 자르면 통째로 버린다**(셀 격자라 글자 반쪽을 그릴 수 없다). 병행 걸음이 그 판정을 따라야
/// `start_byte`가 화면과 맞는다.
///
/// **cluster 전체를 훑는다 — 첫 codepoint만 보면 틀린다.** GB9가 ZWJ를 앞 글자에 흡수하므로
/// `ad<ZWJ>min`은 첫 cp가 정상인데 뒤에 hazard가 붙어 있고, 렌더는 그것을 자른다(`expandTabs`가
/// 같은 이유로 `hazard_in_cluster`를 cluster 단위로 정한다). 첫 cp만 보면 그 갈래를 통째로
/// 지나가게 되고, 실측으로 그런 줄의 **25.6%**가 화면과 다른 글자를 답했다(적대적 검증 5회차).
fn splitsWhenStraddling(bytes: []const u8, i: usize) bool {
    if (bytes[i] == '\t') return true;
    const base = text_layout.decodeCodepoint(bytes, i);
    const end = @min(text_layout.clusterEndAfter(bytes, i, base.advance), bytes.len);
    var scan = i;
    while (scan < end) {
        if (hazard.classifyInText(bytes, scan) != null) return true;
        const seq = std.unicode.utf8ByteSequenceLength(bytes[scan]) catch 1;
        scan += @max(1, @min(seq, end - scan));
    }
    return false;
}

/// 한 걸음: 이 위치의 cluster(또는 탭)를 지나면 **다음 byte와 다음 열**이 어디인가.
///
/// **탭스톱·cluster 분절·표시 폭이 여기 한 곳에만 있다.** 이 규칙을 두 번 쓰면 두 곳이 갈리고,
/// 그러면 강조가 글자에서 밀린다 — 실제로 그렇게 갈렸다(전개 루프에는 화면 상한이 있는데 열 계산
/// 쪽에는 없었다). CodeMirror가 `countColumn`/`findColumn` 하나로 두고 view·commands·language가
/// 모두 그것을 부르는 것과 같은 구조다(코드 표현이 아니라 **구조**를 참고했다).
pub const Step = struct { next_byte: usize, next_col: u32 };

/// `stepColumn`이 **느린 경로**(디코드 + cluster 경계 + §3.8 훑기 + 폭 조회)를 탄 횟수.
///
/// **시간 대신 이것을 센다.** 빠른 경로가 사라지면 5만 줄 소스에서 첫 가로 휠이 28ms에서 501ms가
/// 되는데, 그 회귀를 wall-clock으로 재면 러너 부하와 구분이 안 된다 — 같은 축의 도크 셰이핑
/// 게이트가 부하 있는 머신에서 **변경 없이도 6회 중 5회** 빨간불이었고(`performance-budget.md`),
/// 편집기 쪽 200ms 선도 부하가 크면 229ms로 넘겼다. 알고 싶은 것은 *얼마나 빠른가*가 아니라
/// *빠른 경로를 탔는가*이고, 그것은 정확히 세진다.
///
/// **`is_test`로 묶지 않았다.** 그러면 제품 빌드에서 `void`가 되어 읽는 쪽이 comptime 분기를
/// 들어야 하는데, 이 두 변수는 `usize` 둘이고 증가는 hot loop 안 `+= 1` 하나다. 실측으로 이
/// 게이트의 3.3M 걸음에서 시간 차이가 안 보였다(19ms/157ms — 계측 전과 같은 자리).
pub var slow_path_steps: usize = 0;
/// `stepColumn`이 불린 총 횟수. **훑은 양**을 재는 축이다 — 셈이 상한에서 멈추는지 여기서 보인다.
pub var total_steps: usize = 0;

pub fn stepColumn(bytes: []const u8, i: usize, col: u32, tab_width: u16) Step {
    total_steps += 1;
    const stop_width: u32 = if (tab_width == 0) 1 else tab_width;
    if (bytes[i] == '\t') return .{ .next_byte = i + 1, .next_col = ((col / stop_width) + 1) * stop_width };

    // **가장 흔한 걸음을 먼저 끝낸다.** 출력 가능한 ASCII 뒤에 또 ASCII(또는 줄 끝)가 오면 cluster는
    // 한 바이트에서 끝나고 폭은 1이며 §3.8 위험 문자도 아니다 — cluster를 늘리는 것(결합 문자·ZWJ·
    // 지역표시자)은 **전부 0x80 이상**이고, ASCII 중 유일한 예외인 CR+LF는 0x20 미만이라 이 범위 밖이다.
    // 그러면 디코드·cluster 경계·hazard 훑기·폭 조회가 전부 불필요하다.
    //
    // **이 길이 없으면 §3.8 검사 비용이 모든 줄에 붙는다** — 5만 줄 소스에서 첫 가로 휠이 511ms였다
    // (Debug, macOS arm64). 적대적 검증 2026-08-16이 재고 넣었다.
    const b = bytes[i];
    if (b >= 0x20 and b < 0x7F and (i + 1 >= bytes.len or bytes[i + 1] < 0x80)) {
        return .{ .next_byte = i + 1, .next_col = col + 1 };
    }

    slow_path_steps += 1;
    const base = text_layout.decodeCodepoint(bytes, i);
    const end = @min(text_layout.clusterEndAfter(bytes, i, base.advance), bytes.len);

    // **위험 문자도 같은 규칙을 따라야 한다**(§3.8). `expandTabs`는 그것을 `<U+202E>` 같은 표기로
    // 바꿔 그리고 **그 글자 수만큼** 열을 민다. 여기서 원본 폭으로 세면 강조가 그만큼 밀린다 —
    // 실측: `\u{202E}abc`에서 `a`가 8열에 서는데 이 함수는 1열이라고 했다(적대적 검증 2026-08-16).
    //
    // **cluster 안을 봐야 한다.** GB9가 ZWJ를 앞 글자에 흡수하므로 cluster 단위로만 보면
    // `ad<ZWJ>min`의 ZWJ를 놓친다 — `expandTabs`가 같은 이유로 codepoint 단위로 내려간다.
    var scan = i;
    var hazard_in_cluster = false;
    while (scan < end) {
        if (hazard.classifyInText(bytes, scan) != null) {
            hazard_in_cluster = true;
            break;
        }
        const seq = std.unicode.utf8ByteSequenceLength(bytes[scan]) catch 1;
        scan += @max(1, @min(seq, end - scan));
    }
    if (hazard_in_cluster) {
        // **cluster를 통째로 지난다 — 중간에서 끊으면 안 된다.** 전개 루프는 이 cluster 안을
        // codepoint 단위로 훑되 경계 `[i, end)`는 그대로 두는데, 여기서 한 cp만 지나고 돌아가면
        // 다음 호출이 **중간부터 다시 분절**해 다른 cluster가 나온다(오라클 대조가 12 vs 15로 잡았다).
        // 그래서 안쪽 합을 여기서 다 세고 `end`로 넘어간다.
        // **codepoint 폭을 그냥 더하면 안 된다.** 전개 결과는 다시 분절되어 그려지므로
        // `😀<ZWJ>😀`는 **한 글자 2칸**이지 2+0+2가 아니다(오라클 대조가 12 vs 15로 잡았다).
        // 그래서 위험하지 않은 **연속 구간은 통째로** 세고(그 구간이 렌더에서 그대로 남는다),
        // 위험 cp만 표기 글자 수로 센다.
        var cp_i = i;
        var run_start = i;
        var advanced: u32 = 0;
        while (cp_i < end) {
            const cp_len = @max(1, @min(std.unicode.utf8ByteSequenceLength(bytes[cp_i]) catch 1, end - cp_i));
            if (hazard.classifyInText(bytes, cp_i)) |_| {
                if (cp_i > run_start) advanced += columnsOf(bytes[run_start..cp_i]);
                const cp = std.unicode.utf8Decode(bytes[cp_i .. cp_i + cp_len]) catch 0xFFFD;
                var shown_buf: [hazard.max_display_len]u8 = undefined;
                advanced += @intCast(hazard.displayText(cp, &shown_buf).len);
                run_start = cp_i + cp_len;
            }
            cp_i += cp_len;
        }
        if (end > run_start) advanced += columnsOf(bytes[run_start..end]);
        return .{ .next_byte = end, .next_col = col + advanced };
    }

    const n = @max(1, end - i);
    return .{ .next_byte = i + n, .next_col = col + display_width.clusterCols(bytes, i, i + n) };
}

/// 원본 줄 하나가 화면에서 차지하는 **열 수**. 탭 전개도 §3.8 표기도 `stepColumn` 규칙 그대로 센다 —
/// 가로 스크롤 상한이 이 값에서 나오므로 렌더와 갈리면 줄 끝에 못 닿거나 빈 자리가 남는다.
pub fn lineColumns(bytes: []const u8, tab_width: u16) u32 {
    return lineColumnsUpTo(bytes, tab_width, std.math.maxInt(u32));
}

/// 같은 값을 세되 **`limit`에 닿으면 멈춘다**(마지막 cluster만큼 넘길 수 있다). 호출자가 상한 너머를
/// 쓰지 않는다면 줄 끝까지 셀 이유가 없다 — 5MB짜리 한 줄에서 그 차이가 149ms였다.
pub fn lineColumnsUpTo(bytes: []const u8, tab_width: u16, limit: u32) u32 {
    var col: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len and col < limit) {
        const s = stepColumn(bytes, i, col, tab_width); // 규칙은 한 곳에만 있다
        i = s.next_byte;
        col = s.next_col;
    }
    return col;
}

/// 정렬된 바이트 위치들의 열을 **한 번 훑어** 채운다. `offsets`는 오름차순이어야 하고, `out`은 같은
/// 길이다.
///
/// **왜 `columnOfByte`를 반복하지 않는가.** 그쪽은 위치마다 앞부분을 다시 펴므로 마크가 많은 줄에서
/// 비용이 곱으로 붙는다(200자 줄에 마크 100개면 한 행에 4만 스텝, 화면 50행이면 프레임당 수백만).
/// 여기서는 줄을 한 번만 지난다.
///
/// **탭스톱 규칙은 아래 전개 루프와 같아야 한다** — 두 곳이 갈리면 강조가 글자에서 밀린다. 그래서
/// 테스트가 이 함수를 `columnOfByte`(실제 전개로 세는 쪽)와 무작위 입력에서 대조한다.
/// **`out`이 `offsets`와 같은 메모리여도 된다**(제자리 채우기 — 편집기 프레임이 저장소를 아끼려고
/// 그렇게 부른다). 각 칸은 **읽어서 소비한 뒤에** 덮이고 `next`는 뒤로 가지 않으므로 안전하다.
/// 앞칸을 되읽는 수정을 넣으면 이 성질이 깨진다 — 아래 대조 테스트가 그것을 잡는다.
///
/// `offsets`·`out`은 **바이트 정렬(alignment)이 어긋난** 슬라이스일 수 있다(호출자가 byte 저장소를
/// 빌려 쓴다 — 편집기 프레임이 그렇게 한다). 그래서 `align(1)`을 받는다. 위의 "오름차순"은 **값의
/// 순서**를 말하는 것이고 이것은 **메모리 정렬**이다 — 한국어로 둘 다 "정렬"이라 예전 주석은 뒤
/// 문장이 앞 계약을 뒤집는 것처럼 읽혔다.
pub fn columnsAtOffsets(bytes: []const u8, tab_width: u16, offsets: []align(1) const u32, out: []align(1) u32, stop_col: u32) void {
    // **계약을 지키지 않으면 소리 내어 죽는다.** 오름차순이 아니면 이 함수는 틀린 열을 조용히 내고,
    // 강조가 엉뚱한 글자 위에 선다 — 크래시도 테스트 실패도 없이 화면만 틀린다. 지금 유일한 생산자
    // (`session/editor/intraline`)는 이 성질을 무작위 테스트로 지키지만, `row_marks`에 다른 생산자가
    // 붙는 순간(검색 강조·진단 표시) 그 보장은 따라오지 않는다. ReleaseFast에서는 사라진다.
    if (std.debug.runtime_safety and offsets.len > 1) {
        for (offsets[1..], 0..) |v, i| std.debug.assert(v >= offsets[i]);
    }
    // **화면 오른쪽 끝을 넘으면 멈춘다.** `expandTabs`가 훑는 범위에 상한을 둔 것과 같은 이유다 —
    // 없으면 minified JS처럼 한 줄이 수 MB인 파일에서 화면 밖까지 끝까지 지나간다. 위치가 오름차순
    // 이므로 그 뒤는 전부 화면 밖이고, 남은 자리에는 상한 열을 채워 호출자가 잘라 내게 한다.
    var col: u32 = 0;
    var i: usize = 0;
    var next: usize = 0;
    while (next < offsets.len and offsets[next] <= 0) : (next += 1) out[next] = 0;
    while (i < bytes.len and next < offsets.len) {
        const s = stepColumn(bytes, i, col, tab_width); // 규칙은 한 곳에만 있다
        i = s.next_byte;
        col = s.next_col;
        while (next < offsets.len and offsets[next] <= i) : (next += 1) out[next] = col;
        if (col >= stop_col) break;
    }
    // 줄 끝(또는 화면 끝)을 넘는 위치는 그 열이다.
    while (next < offsets.len) : (next += 1) out[next] = col;
}

/// 탭을 다음 탭스톱까지의 공백으로 편다.
///
/// **열은 [text_layout](../../text_layout.zig)의 cluster 단위로 센다.** 그 모듈이 chrome 텍스트 셀
/// 배치의 단일 출처이고 렌더가 같은 분절을 쓰므로, 여기서 다른 단위로 세면 탭 위치가 화면과 갈린다.
///
/// **codepoint가 아니라 cluster여야 한다.** 이모지 ZWJ 가족·지역표시자 국기·NFD 한글은 codepoint가
/// 여럿인데 화면에서는 한 cluster(1~2칸)다 — codepoint로 세면 탭 뒤 내용이 여러 칸 오른쪽으로 밀린다.
/// 한글·CJK·이모지가 두 칸이고 결합 문자가 0칸인 것도 그 모듈의 판정을 따른다.
///
/// VSCode도 같은 계열 규칙을 쓴다: `cursorColumns.ts`의 `_nextVisibleColumn`이 탭이면 탭스톱,
/// 전각·이모지면 `+2`, 나머지는 `+1`이다.
/// 전개 결과와 **그것이 저장소를 얼마나 썼는지**. 둘을 함께 돌려주는 이유는 탭이 없을 때 원본을
/// 빌려주기 때문이다 — 그 경우 `text.len > 0`이지만 `scratch_used == 0`이라, 호출자가 길이로
/// 저장소 소비를 추정하면 틀린다.
/// `limit`을 넘지 않는 가장 가까운 UTF-8 경계. 중간에서 자르면 깨진 글자가 그려진다.
/// 전부 ASCII인가. **원본을 빌려주는 길의 전제**다 — 그래야 `1byte = 1열`이라 열 상한을 byte로
/// 정확히 지킬 수 있다(위 `expandTabs` 주석 ⑶).
fn isAsciiOnly(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b >= 0x80) return false;
    }
    return true;
}

fn utf8BoundaryAtMost(bytes: []const u8, limit: usize) usize {
    if (limit >= bytes.len) return bytes.len;
    var i = limit;
    // continuation byte(0b10xxxxxx)에 서 있으면 글자 시작까지 물러난다.
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

pub const Expanded = struct {
    text: []const u8,
    scratch_used: usize,
    /// 저장소가 모자라 **줄을 끝까지 만들지 못했는가.** 호출자가 "다 그렸다"고 착각하지 않게 알린다.
    truncated: bool = false,
};

/// **저장소가 모자라면 거기까지만 만들고 성공으로 돌아온다 — 에러가 아니다.**
///
/// 초판은 `error.OutOfSpace`를 올렸는데, 호출자가 그것을 프레임 전체의 실패로 다루므로 **긴 줄 하나가
/// 편집기를 통째로 지웠다**(#2086이 고친 결함). 랩이 붙으면서 같은 일이 되살아났다 — 랩은 한 줄에
/// `남은 행 × 뷰 열수`만큼 저장소를 쓸 수 있어서, 화면이 크면 그 예산이 저장소보다 커진다.
///
/// **열수로 환산해 미리 막을 수는 없다.** 열당 byte가 문자마다 다르고(ASCII 1, 한글 1.5, 이모지 2)
/// 결합 문자를 수백 개 붙인 cluster는 **1열에 수백 byte**라 상한이 없다. 그래서 환산 대신 여기서
/// 경계를 지킨다 — 화면에 덜 나오는 것과 편집기가 안 그려지는 것 중 전자를 고른다(§3.8이 "초장문·극단
/// 입력에서 기능을 줄인다"고 허용한 범위다).
/// 그릴 열 구간. `start`는 **가로 스크롤 위치**(§4)이고, 랩이 켜지면 계약상 늘 0이다.
pub const ColRange = struct {
    /// 이 열 앞은 만들지 않는다.
    start: u16 = 0,
    /// 이 열수만큼 만든다.
    ///
    /// **u32다.** 화면 폭은 u16이면 충분하지만 `rowCount`가 **줄 전체**를 요구하고, u16이면
    /// 65535열에서 잘려 긴 줄의 행 수가 조용히 상한에 걸린다(1 MiB scratch를 줘도 200KB 줄을
    /// 5462행으로 셌다 — 실제는 16667행. 코드 리뷰가 잡았다).
    count: u32,

    fn stop(self: ColRange) usize {
        return @as(usize, self.start) + @as(usize, self.count);
    }
};

pub fn expandTabs(bytes: []const u8, tab_width: u16, out: []u8, range: ColRange) Expanded {
    // **판정에도 상한이 있어야 한다.** 탭·위험 문자가 없으면 원본을 빌려주는 최적화는 유지하되,
    // 그 판정을 **줄 전체가 아니라 화면에 닿을 만큼만** 본다. 초판은 상한이 없어 `indexOfScalar`와
    // `containsAny`(UTF-8 디코드)가 줄 끝까지 갔고, minified JS처럼 한 줄이 수 MB인 파일에서 매
    // 프레임 그만큼을 훑었다 — 화면엔 `max_cols`만 보이는데.
    //
    // 상한은 **열이 아니라 byte**로 잡는다. 열당 byte는 문자마다 달라(ASCII 1, 한글 1.5, 이모지 2)
    // 정확히 환산하려면 결국 훑어야 하므로, UTF-8 최대 4byte를 열마다 가정해 넉넉히 잡는다.
    // 결합 문자를 수백 개 붙인 적대적 입력에서는 이 범위가 `max_cols` 열을 못 채워 오른쪽이 빌 수
    // 있는데, 그것은 §3.8이 "초장문·극단 입력에서 기능을 줄인다"고 허용한 범위다.
    // **`start`가 크면 그만큼 훑는다 — 비용이 화면 폭에만 비례하지 않는다.** 실측(60001byte 한 줄,
    // 화면 52열): start 0 → 216byte, 1000 → 4216, 10000 → 40216. 화면에 나오는 것은 늘 52열인데
    // 앞을 세느라 그만큼을 지나간다.
    //
    // **가로 스크롤 입력이 붙으면 이것이 실제 비용이 된다**(끝까지 민 상태에서 매 프레임, 줄마다).
    // 고치려면 열→byte 인덱스를 줄마다 캐시해야 하는데, 그 캐시는 §2 표의 폭 합 캐시와 같은 자리에
    // 있어야 하므로 그 슬라이스로 미룬다. 지금은 `first_col`이 호출자가 주는 고정값이라 드러나지 않는다.
    const scan_limit = utf8BoundaryAtMost(bytes, range.stop() * 4 + 8);
    const head = bytes[0..scan_limit];
    // **원본을 빌려주는 길에는 조건이 셋이다.**
    //
    // ⑴ `start == 0` — 가로로 밀린 상태에서는 앞을 잘라내야 하는데, 열↔byte 환산이 문자마다 달라
    //    (한글 1.5, 이모지 2) byte로 자르면 어긋난다.
    // ⑵ 탭·위험 문자가 없다 — 둘 다 원본과 다른 글자를 만들어야 한다.
    // ⑶ **ASCII만 있다** — 그래야 `1byte = 1열`이라 열 상한을 byte로 정확히 지킬 수 있다.
    //
    // ⑶이 없으면 **2칸 글자가 오른쪽 경계에 걸칠 때 통째로 넘어가고 렌더러가 반쪽을 그린다**
    // (실측: 마지막 셀에 한글 왼쪽 절반이 남았다). 상한을 루프에만 두고 이 길에는 두지 않았던 것이
    // 원인이며, 랩이 켜졌을 때는 `visual_map`이 뒤에서 다시 잘라 가려져 있었다.
    if (range.start == 0 and
        std.mem.indexOfScalar(u8, head, '\t') == null and
        !hazard.containsAny(head) and
        isAsciiOnly(head))
    {
        // ASCII는 1byte가 1열이므로 열 상한을 그대로 byte로 쓴다.
        return .{ .text = head[0..@min(head.len, @as(usize, range.count))], .scratch_used = 0 };
    }

    const stop_width = if (tab_width == 0) 1 else tab_width;
    var used: usize = 0;
    var col: usize = 0;
    var i: usize = 0;

    while (i < bytes.len) {
        // **보이지 않을 부분은 만들지 않는다.** 렌더러가 `max_cols`로 자르므로 그 너머는 화면에
        // 닿지 않는다 — 여기서 멈추면 비용이 **줄 길이가 아니라 화면 폭에 비례**한다.
        //
        // 초판은 이 상한이 없어서, 탭·위험 문자가 없으면 원본을 빌려주는 early return으로 복사를
        // 피하되 **그 판정에 줄 전체를 훑었다**(`indexOfScalar` + `containsAny`의 UTF-8 디코드).
        // minified JS처럼 한 줄이 수 MB인 파일에서 매 프레임 그만큼을 훑는 셈이고, 탭이 하나라도
        // 있으면 전개가 scratch를 넘겨 `build` **전체**가 OutOfSpace로 죽었다(그 줄만이 아니다).
        //
        // 상한을 두면 복사량이 화면 폭 수준(수백 바이트)이라 early return이 아끼던 것보다 싸고,
        // **scratch 사용량에 상한이 생겨 OutOfSpace가 구조적으로 사라진다.** §3.8의 "초장문 줄 축소"가
        // 요구하는 기능 축소는 별개이며(임계는 §10에서 잰다), 이 상한은 임계 없이도 서는 장치다.
        if (col >= range.stop()) break;

        // **화면 시작 열 앞의 출력 가능한 ASCII는 지나가기만 한다.** 그 구간은 어차피 아무것도
        // 내보내지 않는데, 아래 경로는 글자마다 cluster 분절과 §3.8 훑기를 돈다 — 비용이 화면 폭이
        // 아니라 **밀린 거리**에 비례한다. 20만 자 한 줄에서 `first_col`이 60,000이면 **프레임당
        // 498ms**였다(Debug, macOS arm64. 적대적 검증 2026-08-16이 재고 고쳤다. 이 파일 위 주석이
        // 예언해 둔 그 비용이고, 가로 스크롤 입력이 붙으면서 실제가 됐다).
        //
        // cluster를 늘리는 것은 전부 0x80 이상이라 다음 바이트만 보면 한 글자임이 **증명된다**
        // (`stepColumn`의 같은 판정). 탭·§3.8 문자는 이 범위 밖이라 아래 경로가 그대로 맡는다.
        if (col < range.start) {
            const b = bytes[i];
            if (b >= 0x20 and b < 0x7F and (i + 1 >= bytes.len or bytes[i + 1] < 0x80)) {
                i += 1;
                col += 1;
                continue;
            }
        }

        if (bytes[i] == '\t') {
            const stop = ((col / stop_width) + 1) * stop_width;
            // **가로로 밀린 만큼은 만들지 않는다.** 탭은 공백이라 걸쳐도 잘라 낼 수 있다 —
            // 아래 일반 cluster와 다른 점이고, 그래서 왼쪽 경계에 탭이 걸리면 빈칸이 생기지 않는다.
            const from = @max(col, @as(usize, range.start));
            // 오른쪽도 같은 이유로 잘라 낸다 — 탭은 공백이라 걸쳐도 나눌 수 있다.
            const to = @min(stop, range.stop());
            const pad = if (to > from) to - from else 0;
            if (used + pad > out.len) return .{ .text = out[0..used], .scratch_used = used, .truncated = true };
            @memset(out[used..][0..pad], ' ');
            used += pad;
            col = stop;
            i += 1;
            continue;
        }

        // cluster 하나를 통째로 옮기고 그 **셀 폭**만큼 열을 센다. 잘린 UTF-8은 여기까지 오지
        // 않지만(§3.5가 열 때 거부한다) `decodeCodepoint`가 U+FFFD로 물러나므로 여기서 죽지 않는다.
        const base = text_layout.decodeCodepoint(bytes, i);
        const end = @min(text_layout.clusterEndAfter(bytes, i, base.advance), bytes.len);
        const n = @max(1, end - i);

        // **위험 문자는 보이는 표기로 바꿔 그린다**(§3.8). 지우거나 문서를 고치는 것이 아니라
        // **표시만** 바꾸는 것이다 — 버퍼의 바이트는 그대로이고, 저장하면 원본이 나간다.
        //
        // BiDi 제어 문자가 대표적인데, 폭 0이라 보이지 않으면서 주변 텍스트의 표시 순서를 바꾼다
        // (Trojan Source). 그리지 않으면 화면과 실제 내용이 달라져 §3.8의 불변식이 깨진다.
        //
        // **cluster 안을 들여다봐야 한다.** UAX#29 GB9가 ZWJ·결합 문자를 앞 글자의 cluster로
        // 흡수하므로(`clusterEndAfter`), cluster 단위로만 훑으면 `ad<ZWJ>min`의 ZWJ가 `d`의
        // cluster에 묻혀 그대로 지나간다 — 실제로 그렇게 안 보이는 캡처를 확인했다.
        var scan = i;
        var hazard_in_cluster = false;
        while (scan < end) {
            if (hazard.classifyInText(bytes, scan) != null) {
                hazard_in_cluster = true;
                break;
            }
            const step = std.unicode.utf8ByteSequenceLength(bytes[scan]) catch 1;
            scan += @max(1, @min(step, end - scan));
        }

        if (hazard_in_cluster) {
            // 이 cluster는 **codepoint 단위로** 처리한다 — 위험한 것만 표기로 바꾸고 나머지는
            // 그대로 옮긴다. cluster를 통째로 표기로 바꾸면 정상 글자까지 사라진다.
            var cp_i = i;
            // **위험하지 않은 연속 구간은 통째로 세야 한다.** 내보낸 텍스트는 다시 분절되어 그려지므로
            // `😀<ZWJ>😀`는 **한 글자 2칸**이지 2+0+2가 아니다. codepoint 폭을 그냥 더하면 `col`이
            // 실제 화면보다 앞서고, **그 뒤 탭이 틀린 탭스톱에 선다**(적대적 검증 2026-08-16이
            // `columnOfByte` 대조로 잡았다 — 29 vs 32).
            var run_start = i;
            while (cp_i < end) {
                const cp_len = @max(1, @min(std.unicode.utf8ByteSequenceLength(bytes[cp_i]) catch 1, end - cp_i));
                if (hazard.classifyInText(bytes, cp_i)) |_| {
                    const cp = std.unicode.utf8Decode(bytes[cp_i .. cp_i + cp_len]) catch 0xFFFD;
                    var mark: [hazard.max_display_len]u8 = undefined;
                    const shown = hazard.displayText(cp, &mark);

                    // **표기는 경계에서 잘라서라도 그린다 — 2칸 글자와 다르다.**
                    //
                    // 2칸 글자를 통째로 빼는 것은 반쪽이 깨진 글자이기 때문인데, 표기는 ASCII
                    // 문자열이라 부분도 읽힌다(`<U+20`). 그리고 **빼면 §3.8이 깨진다** — 위험 문자가
                    // 화면에서 사라지고 앞뒤가 붙어, 그 절이 막으려던 Trojan Source가 그대로 통과한다.
                    // 실측으로 확인했다: `ab<U+202E>cd`를 5열 창에 넣었더니 **`abcd`**가 나왔다.
                    //
                    // 잘린 조각이 이상해 보이는 것은 맞다. 그래도 **아무것도 안 보이는 것보다 낫다** —
                    // 사용자가 "여기 뭔가 있다"를 안다. 탭을 걸쳐도 잘라 내는 것과 같은 취급이다.
                    // **여기서는 `col < stop`이 보장되지 않는다.** 루프 머리의 판정은 cluster마다
                    // 한 번이고, 이 안쪽 cp 루프는 `col += shown.len`으로 열을 계속 밀기 때문이다 —
                    // 한 cluster에 hazard cp와 정상 cp가 함께 있으면(ZWJ가 앞 글자에 흡수되는 경우)
                    // 두 번째 cp에서 이미 창을 넘어설 수 있다. **`stop - col`을 그대로 빼면 usize가
                    // 언더플로해 패닉한다** — 적대적 검증이 `a<ZWJ><ZWJ>b<ZWJ>c`로 재현했다.
                    if (col >= range.stop()) break;
                    const shown_from = if (col < range.start) @min(shown.len, range.start - col) else 0;
                    const shown_to = @min(shown.len, range.stop() - col);
                    if (shown_to > shown_from) {
                        const part = shown[shown_from..shown_to];
                        if (used + part.len > out.len) return .{ .text = out[0..used], .scratch_used = used, .truncated = true };
                        @memcpy(out[used..][0..part.len], part);
                        used += part.len;
                    }
                    // 표기가 차지하는 칸은 그 글자 수다 — 원래 codepoint의 폭(0일 수도 있다)이 아니다.
                    col += shown.len;
                    run_start = cp_i + cp_len; // 여기서 정상 구간이 새로 시작한다
                } else {
                    // 같은 이유로 오른쪽도 여기서 다시 본다 — 이 분기(한 cluster 안의 정상 cp)에는
                    // 경계 판정이 아예 없어서, 창을 넘긴 글자가 그대로 나갔다.
                    // 이 cp가 **실제로 미는 칸** = 구간을 여기까지 세었을 때와 직전까지 세었을 때의 차.
                    // 앞 글자에 흡수되는 cp(ZWJ·결합 문자)는 0이 되어 화면과 같아진다.
                    const before = if (cp_i > run_start) columnsOf(bytes[run_start..cp_i]) else 0;
                    const cw = columnsOf(bytes[run_start .. cp_i + cp_len]) -| before;
                    if (col + cw > range.stop()) break;

                    // **열 누적은 조건 밖이다.** 밀린 앞부분에서 `col`이 안 늘면 `range.start`에
                    // 영영 닿지 못해 줄 전체가 사라진다.
                    if (col >= range.start) {
                        if (used + cp_len > out.len) return .{ .text = out[0..used], .scratch_used = used, .truncated = true };
                        @memcpy(out[used..][0..cp_len], bytes[cp_i .. cp_i + cp_len]);
                        used += cp_len;
                    }
                    col += cw;
                }
                cp_i += cp_len;
            }
            i = end;
            continue;
        }

        // **cluster 전체를 넘긴다**(§4.2) — base 코드포인트만 보면 VS16(❤️)과 국기를 1칸으로 세어
        // 컬러 글리프가 절반 크기로 그려진다. 터미널의 `width.cellWidth`와 갈리는 지점이다.
        const w = display_width.clusterCols(bytes, i, end);

        // **오른쪽 경계에 걸쳐도 통째로 뺀다.** 위 `col >= range.stop()`은 cluster의 **시작** 열만
        // 보므로 걸친 글자가 통째로 들어가고, 자르는 것은 렌더러의 픽셀 예산이다 — 그러면 **반쪽이
        // 그려진다**(실측: 마지막 셀에 한글 왼쪽 절반이 남았다). 랩이 켜졌을 때는 `visual_map`이
        // 같은 판정으로 막는데, 꺼지면 아무도 막지 않아 비대칭이었다.
        if (col + w > range.stop()) break;

        // **가로로 밀린 앞부분은 열만 세고 만들지 않는다.** 왼쪽 경계에 2칸 글자가 걸치면 마찬가지로
        // **통째로 뺀다**(왼쪽에 한 칸이 빈다) — 셀 격자라 반쪽을 그릴 수 없다.
        if (col >= range.start) {
            if (used + n > out.len) return .{ .text = out[0..used], .scratch_used = used, .truncated = true };
            @memcpy(out[used..][0..n], bytes[i..][0..n]);
            used += n;
        }
        col += w;
        i += n;
    }
    return .{ .text = out[0..used], .scratch_used = used };
}

const testing = std.testing;

/// 테스트용 시각 배치 저장소. `build`가 배치를 여기 채우고, 랩을 보는 테스트만 내용을 확인한다.
var test_visual: [64]visual_map.VisualRow = undefined;

/// 테스트용 열 상한. 아래 케이스는 전부 짧아서 상한에 닿지 않으므로, 이 값은 "상한이 없을 때와 같다"를
/// 뜻한다 — 상한 자체의 동작은 전용 테스트가 따로 본다.
const test_max_cols: u16 = 999;

test "expandTabs: 탭이 없으면 원본을 그대로 빌려준다" {
    var out: [32]u8 = undefined;
    const r = expandTabs("hello", 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings("hello", r.text);
    // 저장소를 쓰지 않았다 — 이 값을 길이로 추정하면 호출자의 회계가 어긋난다.
    try testing.expectEqual(@as(usize, 0), r.scratch_used);
}

test "expandTabs: 탭스톱까지 채운다 — 고정 폭이 아니다" {
    var out: [64]u8 = undefined;

    // 열 0의 탭은 4칸, 열 1의 탭은 3칸이다. 고정 4칸이면 둘 다 4가 되어 들여쓰기가 어긋난다.
    try testing.expectEqualStrings("    x", (expandTabs("\tx", 4, &out, .{ .count = test_max_cols })).text);
    var out2: [64]u8 = undefined;
    try testing.expectEqualStrings("a   x", (expandTabs("a\tx", 4, &out2, .{ .count = test_max_cols })).text);
    var out3: [64]u8 = undefined;
    try testing.expectEqualStrings("abc x", (expandTabs("abc\tx", 4, &out3, .{ .count = test_max_cols })).text);
    var out4: [64]u8 = undefined;
    try testing.expectEqualStrings("abcd    x", (expandTabs("abcd\tx", 4, &out4, .{ .count = test_max_cols })).text);
}

test "expandTabs: 연속 탭" {
    var out: [64]u8 = undefined;
    const r = expandTabs("\t\tx", 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings("        x", r.text);
    try testing.expectEqual(@as(usize, 9), r.scratch_used); // 전개했으므로 길이만큼 썼다
}

test "expandTabs: 탭 폭 0은 1로 본다 — 0으로 나누지 않는다" {
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings(" x", (expandTabs("\tx", 0, &out, .{ .count = test_max_cols })).text);
}

test "expandTabs: 한글은 두 칸이다 — 글자 수로 세면 정렬이 한 칸 어긋난다" {
    var out: [64]u8 = undefined;
    // "가"는 3 byte, 1글자, **2칸**이다. 탭은 열 2에서 시작하므로 다음 탭스톱(4)까지 2칸.
    // byte 수로 세면 3칸을 건너뛰고, 글자 수로 세면 3칸을 넣는다 — 둘 다 틀린다.
    const r = expandTabs("가\tx", 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings("가  x", r.text);
}

test "expandTabs: 전각 둘이면 탭스톱을 이미 채운다" {
    var out: [64]u8 = undefined;
    // "가나"는 4칸이라 열 4 = 탭스톱 경계. 탭은 다음 스톱(8)까지 4칸을 넣는다.
    const r = expandTabs("가나\tx", 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings("가나    x", r.text);
}

test "expandTabs: 결합 문자는 0칸이다" {
    var out: [64]u8 = undefined;
    // U+0301(combining acute)은 앞 글자에 붙으므로 열을 차지하지 않는다. "e" 1칸 + 결합 0칸 = 열 1.
    const r = expandTabs("e\u{0301}\tx", 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings("e\u{0301}   x", r.text);
}

test "expandTabs: 잘린 UTF-8에서도 죽지 않는다 — 화면이 통째로 비면 안 된다" {
    var out: [64]u8 = undefined;
    // "가"의 첫 두 byte만. §3.5가 열 때 거부하므로 정상 경로엔 없지만 여기서 죽으면 안 된다.
    const r = expandTabs("\xEA\xB0\tx", 4, &out, .{ .count = test_max_cols });
    try testing.expect(r.text.len > 0);
}

test "expandTabs: 저장소가 모자라면 거기까지만 만들고 truncated로 알린다" {
    // **실패하지 않는다.** 초판은 `error.OutOfSpace`를 올렸는데, `build`가 그것을 프레임 전체의
    // 실패로 다뤄서 긴 줄 하나가 편집기를 통째로 지웠다(#2086). 랩이 붙자 같은 일이 되살아났고
    // (한 줄이 `남은 행 × 뷰 열수`만큼 저장소를 쓸 수 있다) 적대적 검증이 그것을 잡았다.
    var out: [6]u8 = undefined;
    const r = expandTabs("\tabc", 4, &out, .{ .count = test_max_cols });
    try testing.expect(r.truncated);
    try testing.expectEqualStrings("    ab", r.text); // 탭 4칸 + 두 글자까지, `c`는 못 넣었다

    // **탭은 통째로 넣거나 안 넣는다.** 남은 자리에 맞춰 일부만 채우면 탭스톱이 깨져 그 뒤 들여쓰기가
    // 전부 어긋난다 — 덜 그리는 편이 낫다.
    var tight: [2]u8 = undefined;
    const t = expandTabs("\tabc", 4, &tight, .{ .count = test_max_cols });
    try testing.expect(t.truncated);
    try testing.expectEqual(@as(usize, 0), t.text.len);
}

test "op·run 예산이 모자라도 build는 성공하고 번호 배치는 남긴다" {
    // **`build`는 이제 실패하지 않는다.** 랩이 붙으면서 한 줄이 op을 여러 개 쓰게 됐고, 그때
    // 에러를 올리면 긴 줄 하나가 프레임 전체를 지운다(#2086이 scratch에서 고친 것과 같은 결함이
    // op·run 경로에 남아 있었다).
    const layout = geometry.compute(40, 3, .{});
    var scratch: [512]u8 = undefined;
    var vrows: [16]visual_map.VisualRow = undefined;
    const rows = [_]Row{ .{ .bytes = "aaa" }, .{ .bytes = "bbb" }, .{ .bytes = "ccc" } };

    for ([_]usize{ 0, 1, 2, 3 }) |cap| {
        var ops: [4]draw.Op = undefined;
        var runs: [4]draw.Run = undefined;
        const w = build(testProps(layout, &rows), ops[0..cap], &scratch, runs[0..cap], &vrows);
        try testing.expectEqual(@min(cap, rows.len), w.ops);
        // **배치는 예산과 무관하게 다 채운다** — gutter가 번호를 그려야 화면이 어느 위치인지 안다.
        try testing.expectEqual(rows.len, w.visual_rows);
    }
}

test "랩된 줄에서 op이 다해도 그 줄의 나머지 조각이 배치에서 사라지지 않는다" {
    // **`continue`와 `break`의 차이가 여기서만 드러난다.** 랩이 꺼지면 줄당 조각이 하나라 둘이
    // 같은 결과를 내고, 실제로 앞선 테스트가 그 차이를 못 잡았다(반증이 통과했다).
    //
    // `break`면 그 줄의 남은 조각이 배치에서 통째로 빠지고 **다음 논리 줄이 그 자리를 차지한다** —
    // gutter가 따라가는 배치가 어긋나므로 번호가 본문과 갈린다.
    const layout = geometry.compute(20, 1, .{}); // 본문이 좁아 한 줄이 여러 조각이 된다
    var scratch: [512]u8 = undefined;
    var vrows: [16]visual_map.VisualRow = undefined;
    var ops: [1]draw.Op = undefined; // **op은 하나뿐**
    var runs: [1]draw.Run = undefined;

    const rows = [_]Row{ .{ .bytes = "0123456789" ** 4 }, .{ .bytes = "second" } };
    var props = testProps(layout, &rows);
    props.wrap = true;

    const w = build(props, &ops, &scratch, &runs, &vrows);
    try testing.expectEqual(@as(usize, 1), w.ops); // 예산만큼만 그렸다

    // 첫 줄이 여러 조각으로 접혔고 **그 조각들이 배치에 그대로 있다**.
    //
    // **`vrows[2]`부터 갈린다.** 배치를 예산 확인 **전에** 채우므로 `break`여도 조각 하나는 더
    // 들어간다 — 처음엔 `vrows[1]`을 보고 반증이 통과했다(검증이 틀린 자리를 봤다).
    try testing.expect(w.visual_rows >= 4);
    try testing.expectEqual(@as(u32, 0), vrows[0].line);
    try testing.expectEqual(@as(u32, 0), vrows[1].line);
    try testing.expectEqual(@as(u32, 0), vrows[2].line); // `break`면 여기가 줄 1이 된다
    try testing.expectEqual(@as(u32, 2), vrows[2].piece);
}

test "저장소가 모자라도 build는 성공하고 나머지 줄을 계속 그린다" {
    // 이것이 #2086의 계약이다 — **화면에 덜 나오는 것**과 **편집기가 통째로 안 그려지는 것** 중
    // 전자를 고른다. 랩이 켜진 상태에서 검증한다(랩이 저장소를 가장 많이 쓴다).
    const layout = geometry.compute(40, 3, .{});
    var ops: [16]draw.Op = undefined;
    var runs: [16]draw.Run = undefined;
    var vrows: [8]visual_map.VisualRow = undefined;
    var tiny: [8]u8 = undefined; // 한 줄도 못 담는 저장소

    const rows = [_]Row{
        .{ .bytes = "\t" ++ "0123456789" ** 30 }, // 저장소를 넘기는 긴 줄
        .{ .bytes = "\tsecond" },
        .{ .bytes = "\tthird" },
    };
    var props = testProps(layout, &rows);
    props.wrap = true;

    const w = build(props, &ops, &tiny, &runs, &vrows);
    // **죽지 않았다.** 그리고 시각 행을 계속 냈으므로 gutter가 번호를 그릴 수 있다.
    try testing.expect(w.visual_rows > 0);
    try testing.expect(w.bytes <= tiny.len);
    // **조용하지 않다.** 절단은 실패가 아니지만 화면에서는 그냥 짧은 줄로 보이므로, 호출자가
    // 알 수 있어야 한다(§3.0 "왜 줄었는지 알린다").
    try testing.expect(w.truncated_rows > 0);
}

/// 전개 결과의 표시 폭. **cluster 단위로 센다** — codepoint로 세면 ZWJ 가족이 8칸으로 잡혀
/// 거짓 양성이 난다(적대적 검증 중 실제로 그 함정에 빠졌다).
fn testCols(t: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < t.len) {
        const base = text_layout.decodeCodepoint(t, i);
        const end = @min(text_layout.clusterEndAfter(t, i, base.advance), t.len);
        const step = @max(1, end - i);
        n += display_width.clusterCols(t, i, i + step);
        i += step;
    }
    return n;
}

test "rowCount는 실제로 그리는 조각 수와 언제나 같다" {
    // **이 테스트가 있는 이유**: 처음엔 "전개하지 않고 열만 세는" 경량 경로를 따로 두었는데, 같은
    // 규칙을 두 곳에 쓰자마자 990건 중 80건이 갈렸다(원인이 매번 달랐다 — 행 머리 처리, 탭이
    // 쪼개지는 것, 정수 언더플로, §3.8 표기가 1칸 글자 여덟 개로 나뉘는 것). 복제를 버리고 전개
    // 결과를 그대로 세도록 바꾼 뒤 0건이 됐다.
    //
    // 그 복제가 되살아나지 않게 **여기서 두 경로가 같음을 고정한다.**
    var out: [8192]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    const lines = [_][]const u8{
        "",                            "a",
        "0123456789" ** 6,
        "가나다라마바사아자차" ** 3,
        "\ta\tb\tc",
        "\t\t\t가나다",
        "a가b나c다" ** 6,
        "ab\u{202E}cd",                "\u{202E}" ** 5,
        "a\u{200D}\u{200D}b\u{200D}c",
        "👨\u{200D}👩\u{200D}👧" ** 6,
        "e\u{0301}\u{0301}가나" ** 4,
        "  들여쓰기 있는 한글 줄입니다 길게 길게",
        "\tx" ** 20,                   "\u{1F1F0}\u{1F1F7}" ** 8,
        "\u{2764}\u{FE0F}" ** 10,      "\t",
        "\t\t\t\t",
        "가\t나",
        "a\t가\tb", // ← 언더플로를 재현했던 모양
        "\t가",
        "가가\t가",
    };
    var ops: [256]draw.Op = undefined;
    var runs: [256]draw.Run = undefined;
    var vrows: [256]visual_map.VisualRow = undefined;

    for (lines) |line| {
        for ([_]u16{ 1, 2, 3, 5, 8, 13, 20, 52, 80 }) |cols| {
            for ([_]u16{ 0, 1, 2, 4, 8 }) |tab| {
                // **실제로 그리는 경로는 `build`다.** 초판은 여기서 `expandTabs` → `pieces`를 직접
                // 불렀는데, 그것은 `rowCount`의 본문을 그대로 옮겨 적은 것이라 **항상 통과했다** —
                // 코드 리뷰가 그것을 잡았고, 그래서 `first_piece`가 전개 예산을 갉아먹어 화면
                // 아래가 비는 결함이 이 테스트를 그냥 지나갔다.
                // gutter 없이 본문만 `cols`칸 — `geometry.compute`는 줄 수에서 gutter 폭을
                // 파생하므로 원하는 본문 폭을 정확히 만들 수 없다.
                const layout = geometry.Layout{
                    .leading_margin = .{ .start = 0, .width = 0 },
                    .line_numbers = .{ .start = 0, .width = 0 },
                    .folding = .{ .start = 0, .width = 0 },
                    .content_gap = .{ .start = 0, .width = 0 },
                    .content = .{ .start = 0, .width = cols },
                };
                var props = testProps(layout, &.{.{ .bytes = line }});
                props.wrap = true;
                props.tab_width = tab;
                const w = build(props, &ops, &out, &runs, &vrows);

                const rc = rowCount(line, tab, cols, true, &scratch);
                // 저장소가 모자라 어느 쪽이든 절단됐으면 비교 대상이 아니다 — 그건 §3.8 축소이고
                // 아래 별도 테스트가 본다.
                if (w.truncated_rows == 0 and !rc.truncated) {
                    try testing.expectEqual(w.visual_rows, rc.rows);
                }
            }
        }
    }
}

test "first_piece: 랩된 줄의 중간 행부터 화면이 시작한다" {
    // **세로 스크롤이 시각 행 단위이려면 이것이 있어야 한다.** 없으면 뷰포트가 논리 줄 경계에서만
    // 멈출 수 있어, 랩된 줄 하나가 화면보다 길면 그 아래를 볼 방법이 없다.
    const layout = geometry.compute(20, 2, .{});
    var ops: [16]draw.Op = undefined;
    var runs: [16]draw.Run = undefined;
    var vrows: [8]visual_map.VisualRow = undefined;
    var scratch: [256]u8 = undefined;

    const long = "0123456789" ** 4;
    const rows = [_]Row{ .{ .bytes = long }, .{ .bytes = "next" } };
    var props = testProps(layout, &rows);
    props.wrap = true;

    // 건너뛰지 않으면 첫 조각부터. **첫 조각의 길이는 본문 폭이 정한다** — 숫자를 적으면 gutter
    // 배분이 바뀔 때마다 낡는다(접기 칸이 1→2셀이 되며 실제로 그랬다).
    const all = build(props, &ops, &scratch, &runs, &vrows);
    try testing.expectEqualStrings(long[0..layout.content.width], ops[0].text.runs[0].text);
    const total = all.visual_rows;

    // 두 조각을 건너뛰면 세 번째 조각이 화면 첫 행이다.
    props.first_piece = 2;
    const skipped = build(props, &ops, &scratch, &runs, &vrows);
    try testing.expectEqual(@as(u32, 0), vrows[0].line);
    try testing.expectEqual(@as(u32, 2), vrows[0].piece);
    // **행이 정확히 둘 줄었다** — 건너뛴 조각은 세지도 배치를 채우지도 않는다.
    try testing.expectEqual(total - 2, skipped.visual_rows);

    // 첫 행이 화면 맨 위(y=0)에 온다.
    try testing.expectEqual(@as(i32, 0), ops[0].text.origin.y);
}

test "first_piece가 있어도 화면 아래까지 채운다 — 전개 예산이 건너뛴 조각을 포함한다" {
    // **코드 리뷰가 실측한 재현을 그대로 옮겼다.** 전개 예산을 `rows_left`만으로 잡으면 건너뛴
    // 조각이 그 예산을 먹어, 뷰포트 아래쪽이 조용히 비고 **다음 논리 줄이 그 자리로 올라온다.**
    //
    // 앞선 `first_piece` 테스트들은 뷰포트가 넉넉해 예산이 남았기 때문에 이것을 못 잡았다 —
    // **뷰포트가 작을 때만 드러난다.**
    const layout = geometry.Layout{
        .leading_margin = .{ .start = 0, .width = 0 },
        .line_numbers = .{ .start = 0, .width = 0 },
        .folding = .{ .start = 0, .width = 0 },
        .content_gap = .{ .start = 0, .width = 0 },
        .content = .{ .start = 0, .width = 12 },
    };
    var ops: [16]draw.Op = undefined;
    var runs: [16]draw.Run = undefined;
    var vrows: [3]visual_map.VisualRow = undefined; // **3행짜리 뷰포트**
    var scratch: [1024]u8 = undefined;

    // 60칸 → 12열에서 5조각.
    const rows = [_]Row{ .{ .bytes = "0123456789" ** 6 }, .{ .bytes = "next" } };
    var props = testProps(layout, &rows);
    props.wrap = true;
    props.first_piece = 2;

    const w = build(props, &ops, &scratch, &runs, &vrows);

    // 화면 세 행이 **전부 첫 줄의 조각 2·3·4**여야 한다.
    try testing.expectEqual(@as(usize, 3), w.visual_rows);
    for (0..3) |i| {
        try testing.expectEqual(@as(u32, 0), vrows[i].line);
        try testing.expectEqual(@as(u32, @intCast(i + 2)), vrows[i].piece);
    }
    // 다음 논리 줄이 올라오지 않았다.
    try testing.expectEqual(@as(usize, 3), w.ops);
}

test "first_piece가 범위를 넘으면 줄을 지우지 않고 처음부터 보여준다" {
    // 스크롤 위치가 뷰 폭·탭 폭·랩 토글 변경 뒤에도 살아남으면 이 상태가 된다. 그대로 두면
    // **첫 논리 줄이 통째로 사라지고 다음 줄이 그 자리로 올라온다** — 리사이즈 한 번에 화면이
    // 문서의 다른 곳으로 튄다(코드 리뷰가 지적했다).
    //
    // **범위를 넘는 값을 실제로 넣어 본다.** 초판은 여기에 assert를 두었다가 그것이 fallback에
    // 닿기 전에 앱을 죽였다 — 넘는 값은 복구 가능한 낡은 입력이지 프로그래밍 오류가 아니다.
    const layout = geometry.Layout{
        .leading_margin = .{ .start = 0, .width = 0 },
        .line_numbers = .{ .start = 0, .width = 0 },
        .folding = .{ .start = 0, .width = 0 },
        .content_gap = .{ .start = 0, .width = 0 },
        .content = .{ .start = 0, .width = 12 },
    };
    var ops: [16]draw.Op = undefined;
    var runs: [16]draw.Run = undefined;
    var vrows: [8]visual_map.VisualRow = undefined;
    var scratch: [512]u8 = undefined;

    // 24칸 → 12열에서 2조각. 마지막 유효 조각(1)까지는 정상 동작해야 한다.
    const rows = [_]Row{ .{ .bytes = "0123456789" ** 2 ++ "abcd" }, .{ .bytes = "next" } };
    var props = testProps(layout, &rows);
    props.wrap = true;
    props.first_piece = 1;

    const w = build(props, &ops, &scratch, &runs, &vrows);
    try testing.expectEqual(@as(u32, 0), vrows[0].line);
    try testing.expectEqual(@as(u32, 1), vrows[0].piece);
    try testing.expect(w.visual_rows >= 2);
    try testing.expectEqual(@as(u32, 1), vrows[1].line);

    // **조각 수(2)를 넘는 값들.** 죽지 않고, 첫 줄이 조각 0부터 온전히 나와야 한다.
    for ([_]u32{ 2, 3, 100, 10_000, std.math.maxInt(u32) }) |over| {
        props.first_piece = over;
        const r = build(props, &ops, &scratch, &runs, &vrows);
        try testing.expect(r.visual_rows >= 2);
        try testing.expectEqual(@as(u32, 0), vrows[0].line);
        try testing.expectEqual(@as(u32, 0), vrows[0].piece); // 처음부터 보여준다
    }
}

test "first_piece는 첫 줄에만 적용된다 — 뒤따르는 줄이 잘리면 안 된다" {
    const layout = geometry.compute(20, 2, .{});
    var ops: [16]draw.Op = undefined;
    var runs: [16]draw.Run = undefined;
    var vrows: [8]visual_map.VisualRow = undefined;
    var scratch: [256]u8 = undefined;

    // 두 줄 다 랩된다. `first_piece`가 둘째 줄에도 걸리면 그 줄 앞부분이 사라진다.
    const rows = [_]Row{ .{ .bytes = "aaaaaaaaaaaaaaaaaaaaaaaa" }, .{ .bytes = "bbbbbbbbbbbbbbbbbbbbbbbb" } };
    var props = testProps(layout, &rows);
    props.wrap = true;
    props.first_piece = 1;

    _ = build(props, &ops, &scratch, &runs, &vrows);
    // 줄 1은 **조각 0부터** 나와야 한다.
    var saw_line1_piece0 = false;
    for (vrows[0..4]) |v| {
        if (v.line == 1 and v.piece == 0) saw_line1_piece0 = true;
    }
    try testing.expect(saw_line1_piece0);
}

test "rowCount: 65535열을 넘는 줄도 끝까지 센다 — u16 상한에 걸리지 않는다" {
    // 초판은 열 예산을 `ColRange.count`(u16)로 넘겨 **scratch와 무관하게** 65535열에서 잘렸다.
    // 코드 리뷰 실측: 200KB 줄·12열·1MiB scratch에서 5462행(실제 16667행). 이 PR이 고치려던
    // "긴 줄 아래를 볼 방법이 없다"가 그대로 되살아나는 자리다.
    const line = "0123456789" ** 8000; // 80,000칸
    var scratch: [131072]u8 = undefined;
    const r = rowCount(line, 4, 12, true, &scratch);
    try testing.expect(!r.truncated);
    try testing.expectEqual(@as(u32, 80000 / 12 + 1), r.rows); // 6667행 — u16 상한(5462)이 아니다
}

test "rowCount: 저장소가 모자라면 절단을 보고한다 — 조용히 짧아지지 않는다" {
    // 절단 자체는 §3.8이 허용하지만 **조용해서는 안 된다**(`Written.truncated_rows`와 같은 규율).
    // 이 값이 없으면 스크롤바가 문서보다 짧게 그려지는데 왜인지 알 길이 없다.
    const line = "\t" ++ ("0123456789" ** 200);
    var tiny: [64]u8 = undefined;
    const r = rowCount(line, 4, 12, true, &tiny);
    try testing.expect(r.truncated);

    var big: [8192]u8 = undefined;
    const full = rowCount(line, 4, 12, true, &big);
    try testing.expect(!full.truncated);
    try testing.expect(full.rows > r.rows); // 절단된 쪽이 실제로 짧다
}

test "rowCount: 랩이 꺼지면 언제나 한 행이다" {
    var scratch: [64]u8 = undefined;
    try testing.expectEqual(@as(u32, 1), rowCount("0123456789" ** 10, 4, 20, false, &scratch).rows);
    try testing.expectEqual(@as(u32, 1), rowCount("", 4, 20, false, &scratch).rows);
    // 뷰 폭이 0이면 접을 수 없다 — 0으로 나누거나 무한히 도는 대신 한 행으로 둔다.
    try testing.expectEqual(@as(u32, 1), rowCount("긴 줄", 4, 0, true, &scratch).rows);
}

test "어떤 시작 열·폭 조합에서도 창 폭을 넘지 않는다" {
    // 왼쪽·오른쪽 경계를 **동시에** 지키는지 본다. 한쪽만 고치면 반대쪽에서 2칸 글자가 걸쳐
    // 렌더러가 반쪽을 그린다(실측으로 잡은 결함이다).
    var out: [512]u8 = undefined;
    const inputs = [_][]const u8{
        "0123456789" ** 8,
        "가나다라마바사아자차" ** 4,
        "a가b나c다" ** 8,
        "\t\t가나다라마",
        "ab\u{202E}cd가나다", // §3.8 표기(8칸)가 경계에 걸리는 경우
        "\ta\tb\t가\t나",
        "👨‍👩‍👧x가나", // ZWJ 가족 — cluster로 세지 않으면 여기서 틀린다
        "\u{1F1F0}\u{1F1F7}가", // 지역표시자 국기
        "e\u{0301}\u{0301}가나", // 결합 문자
        // **한 cluster 안에 hazard cp와 정상 cp가 함께 있는 경우.** ZWJ가 앞 글자에 흡수되므로
        // (UAX#29 GB9) cp 루프가 여러 번 돌고, 그 안에서 `col`이 창을 넘어설 수 있다 —
        // 적대적 검증이 여기서 **정수 언더플로 패닉**을 재현했다(`stop - col`).
        "a\u{200D}b",
        "a\u{200D}\u{200D}b\u{200D}c",
        "가\u{200D}\u{200D}\u{200D}나다",
        "a\u{0301}\u{200B}b",
        "\u{200D}" ** 20,
        "\t가\u{200D}나\t다",
        "",
        "가",
        "\t",
    };
    for (inputs) |line| {
        for (0..25) |start| {
            for ([_]u16{ 1, 2, 3, 5, 8, 20, 52 }) |count| {
                const r = expandTabs(line, 4, &out, .{ .start = @intCast(start), .count = count });
                try testing.expect(testCols(r.text) <= count);
                try testing.expect(std.unicode.utf8ValidateSlice(r.text));
            }
        }
    }
}

test "랩이 켜지면 가로 위치가 0이어야 한다 — 계약을 코드가 강제한다" {
    // §4는 랩이면 범위 clamp가 위치를 0으로 누른다고 정했는데 **그 clamp가 아직 없다.** 그래서
    // `build`가 assert로 막는다 — 없으면 "밀린 채 접히는" 정의되지 않은 상태가 만들어진다.
    // (Zig의 assert는 Debug/ReleaseSafe에서만 도므로 여기서는 **허용되는 조합만** 확인한다.)
    const layout = geometry.compute(40, 1, .{});
    var ops: [8]draw.Op = undefined;
    var runs: [8]draw.Run = undefined;
    var vrows: [4]visual_map.VisualRow = undefined;
    var scratch: [128]u8 = undefined;
    const rows = [_]Row{.{ .bytes = "0123456789" }};

    var wrapped = testProps(layout, &rows);
    wrapped.wrap = true;
    wrapped.first_col = 0; // 랩이면 0만 허용
    _ = build(wrapped, &ops, &scratch, &runs, &vrows);

    var scrolled = testProps(layout, &rows);
    scrolled.wrap = false;
    scrolled.first_col = 5; // 랩이 꺼졌으면 밀 수 있다
    const w = build(scrolled, &ops, &scratch, &runs, &vrows);
    try testing.expectEqualStrings("56789", ops[0].text.runs[0].text);
    try testing.expectEqual(@as(usize, 1), w.visual_rows);
}

test "가로 스크롤: 시작 열 앞은 만들지 않는다" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("0123456789", expandTabs("0123456789", 4, &out, .{ .count = 20 }).text);
    try testing.expectEqualStrings("56789", expandTabs("0123456789", 4, &out, .{ .start = 5, .count = 20 }).text);
    // 시작 열 + 폭이 함께 창을 만든다.
    try testing.expectEqualStrings("567", expandTabs("0123456789", 4, &out, .{ .start = 5, .count = 3 }).text);
    // 줄 끝을 넘어가면 빈다 — 아래쪽이 비는 세로 스크롤과 같다.
    try testing.expectEqualStrings("", expandTabs("0123456789", 4, &out, .{ .start = 20, .count = 5 }).text);
}

test "가로 스크롤: 2칸 글자가 경계에 걸치면 통째로 뺀다 — 반쪽을 그릴 수 없다" {
    var out: [64]u8 = undefined;
    // "a가나": a(열0) 가(열1~2) 나(열3~4)
    try testing.expectEqualStrings("가나", expandTabs("a가나", 4, &out, .{ .start = 1, .count = 10 }).text);
    // start=2는 `가`의 **둘째 칸**이다. 반쪽은 못 그리므로 통째로 빼고 왼쪽 한 칸이 빈다.
    try testing.expectEqualStrings("나", expandTabs("a가나", 4, &out, .{ .start = 2, .count = 10 }).text);
    try testing.expectEqualStrings("나", expandTabs("a가나", 4, &out, .{ .start = 3, .count = 10 }).text);
}

test "가로 스크롤: 탭은 걸쳐도 잘라 낸다 — 공백이라 반쪽이 없다" {
    var out: [64]u8 = undefined;
    // "\tx" → 탭이 열 0~3(4칸), x가 열 4
    try testing.expectEqualStrings("    x", expandTabs("\tx", 4, &out, .{ .count = 10 }).text);
    try testing.expectEqualStrings("  x", expandTabs("\tx", 4, &out, .{ .start = 2, .count = 10 }).text);
    try testing.expectEqualStrings("x", expandTabs("\tx", 4, &out, .{ .start = 4, .count = 10 }).text);
}

test "가로 스크롤: 탭스톱은 줄 처음부터 센다 — 밀린 위치에서 다시 세지 않는다" {
    var out: [64]u8 = undefined;
    // "ab\tc": 탭이 열 2에서 시작해 열 4까지(2칸), c는 열 4.
    try testing.expectEqualStrings("ab  c", expandTabs("ab\tc", 4, &out, .{ .count = 10 }).text);
    // start=1에서 다시 세면 탭이 3칸이 되어 `c`가 한 칸 밀린다. 그러면 화면을 가로로 밀 때
    // **들여쓰기가 흔들려** 코드가 다르게 보인다.
    try testing.expectEqualStrings("b  c", expandTabs("ab\tc", 4, &out, .{ .start = 1, .count = 10 }).text);
}

test "가로 스크롤: 위험 문자 표기가 경계에서 잘려도 사라지지는 않는다 (§3.8)" {
    var out: [64]u8 = undefined;
    const line = "ab\u{202E}cd"; // a(0) b(1) <U+202E>(2~9) c(10) d(11)
    try testingEqual("ab<U+202E>cd", expandTabs(line, 4, &out, .{ .count = 40 }).text);
    try testingEqual("<U+202E>cd", expandTabs(line, 4, &out, .{ .start = 2, .count = 40 }).text);

    // **표기는 2칸 글자와 달리 잘라서 그린다.** 통째로 빼면 위험 문자가 화면에서 사라지고 앞뒤가
    // 붙어(`abcd`) §3.8이 막으려던 Trojan Source가 그대로 통과한다 — 실제로 그 상태였다.
    try testingEqual("ab<U+", expandTabs(line, 4, &out, .{ .count = 5 }).text);
    try testingEqual("ab<U+202E", expandTabs(line, 4, &out, .{ .count = 9 }).text);
    try testingEqual("U+202E>cd", expandTabs(line, 4, &out, .{ .start = 3, .count = 40 }).text);
    try testingEqual(">cd", expandTabs(line, 4, &out, .{ .start = 9, .count = 40 }).text);

    // **어느 창에서도 `abcd`가 되지 않는다** — 그것이 이 규칙이 지키는 것이다.
    for (0..14) |start| {
        for (1..14) |count| {
            const r = expandTabs(line, 4, &out, .{ .start = @intCast(start), .count = @intCast(count) });
            try testing.expect(!std.mem.eql(u8, r.text, "abcd"));
        }
    }
}

fn testingEqual(want: []const u8, got: []const u8) !void {
    return testing.expectEqualStrings(want, got);
}

test "가로 스크롤: 밀린 줄도 UTF-8이 온전하다" {
    var out: [64]u8 = undefined;
    const line = "가나다라마바사";
    for (0..14) |start| {
        const r = expandTabs(line, 4, &out, .{ .start = @intCast(start), .count = 6 });
        try testing.expect(std.unicode.utf8ValidateSlice(r.text));
    }
}

test "절단은 UTF-8을 깨지 않는다 — 반쪽 글자를 그리면 안 된다" {
    // 저장소 크기를 바꿔 가며 **모든 절단 지점**을 훑는다. 한 지점만 보면 우연히 경계에 맞을 수 있다.
    const line = "\t가나다라마바사아자차";
    for (4..40) |cap| {
        var buf: [64]u8 = undefined;
        const r = expandTabs(line, 4, buf[0..cap], .{ .count = 200 });
        try testing.expect(std.unicode.utf8ValidateSlice(r.text));
    }
}

test "긴 줄은 본문이 저장소를 끝까지 쓴다 — 뒤에 그릴 것이 있으면 호출자가 몫을 떼어야 한다" {
    // **`lab.zig`의 `gutter_reserve`가 있는 이유다.** 본문을 먼저 그리도록 순서를 바꾸면서, 긴 줄이
    // 저장소를 다 삼켜 뒤에 도는 gutter가 `OutOfSpace`로 죽는 것을 적대적 검증이 실제로 잡았다.
    //
    // **Lab fixture로는 그 상태가 재현되지 않는다** — 거기 줄들은 대부분 탭이 없어 원본을 빌려주고,
    // 긴 줄이 맨 끝이라 앞 줄들이 이미 행을 소비해 전개 예산이 작아진다. 그래서 계약을 여기서 고정한다.
    const layout = geometry.compute(40, 2, .{});
    var ops: [64]draw.Op = undefined;
    var runs: [64]draw.Run = undefined;
    var vrows: [32]visual_map.VisualRow = undefined;
    var scratch: [128]u8 = undefined;

    const rows = [_]Row{.{ .bytes = "\t" ++ "0123456789" ** 40 }};
    var props = testProps(layout, &rows);
    props.wrap = true;

    const w = build(props, &ops, &scratch, &runs, &vrows);
    // 저장소를 **끝까지** 썼다 — 이 상태로 gutter를 부르면 그릴 자리가 없다.
    try testing.expectEqual(scratch.len, w.bytes);
}

test "저장소가 넉넉하면 절단을 보고하지 않는다 — truncated_rows가 늘 켜져 있지 않다" {
    const layout = geometry.compute(40, 2, .{});
    var ops: [8]draw.Op = undefined;
    var runs: [8]draw.Run = undefined;
    var vrows: [4]visual_map.VisualRow = undefined;
    var scratch: [256]u8 = undefined;

    const rows = [_]Row{ .{ .bytes = "\tshort" }, .{ .bytes = "\talso short" } };
    const w = build(testProps(layout, &rows), &ops, &scratch, &runs, &vrows);
    try testing.expectEqual(@as(usize, 0), w.truncated_rows);
}

fn testProps(layout: geometry.Layout, rows: []const Row) Props {
    return .{
        .layout = layout,
        .rows = rows,
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 13,
        .origin_px = .{ .x = 0, .y = 0 },
    };
}

test "본문은 gutter 오른쪽에서 시작한다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{.{ .bytes = "const x = 1;" }};

    var ops: [4]draw.Op = undefined;
    var scratch: [128]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    const w = build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

    try testing.expectEqual(@as(usize, 1), w.ops);
    // **셀 수를 손으로 적지 않는다** — 배분은 `geometry`가 소유하고(여백 1 + 번호 5 + 접기 2 + 여백 1),
    // 여기서 다시 적으면 그쪽이 바뀔 때 이 판정이 조용히 낡는다(실제로 접기 칸이 1→2셀이 되며 그랬다).
    try testing.expectEqual(@as(i32, @as(i32, layout.contentLeft()) * 8), ops[0].text.origin.x);
    try testing.expectEqualStrings("const x = 1;", ops[0].text.runs[0].text);
}

test "행 간격이 gutter와 같다 — 줄 번호와 본문이 나란히 서야 한다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .bytes = "a" },
        .{ .bytes = "b" },
        .{ .bytes = "c" },
    };

    var ops: [8]draw.Op = undefined;
    var scratch: [128]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    _ = build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

    try testing.expectEqual(@as(i32, 0), ops[0].text.origin.y);
    try testing.expectEqual(@as(i32, 16), ops[1].text.origin.y);
    try testing.expectEqual(@as(i32, 32), ops[2].text.origin.y);
}

test "본문 폭을 넘는 줄은 max_cols로 잘린다 — 창 밖까지 그리지 않는다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{.{ .bytes = "x" }};

    var ops: [4]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    _ = build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

    try testing.expectEqual(layout.content.width, ops[0].text.max_cols);
}

test "빈 줄은 op을 만들지 않는다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .bytes = "a" },
        .{ .bytes = "" },
        .{ .bytes = "c" },
    };

    var ops: [8]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    const w = build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

    try testing.expectEqual(@as(usize, 2), w.ops);
    // 세 번째 줄은 시각 행 2를 유지해야 한다 — 빈 줄을 건너뛰었다고 위로 당겨지면 안 된다.
    try testing.expectEqual(@as(i32, 32), ops[1].text.origin.y);
}

test "탭이 든 줄은 전개돼 그려진다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{.{ .bytes = "if x:\n\treturn" }};

    var ops: [4]draw.Op = undefined;
    var scratch: [128]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    _ = build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

    // 줄 안에 `\n`이 있을 일은 없지만(줄 단위로 들어온다) 탭 전개만 확인한다.
    try testing.expect(std.mem.indexOfScalar(u8, ops[0].text.runs[0].text, '\t') == null);
}

test "본문 영역이 없으면 아무것도 그리지 않는다" {
    const layout = geometry.compute(5, 10, .{}); // gutter가 뷰보다 넓다
    const rows = [_]Row{.{ .bytes = "x" }};

    var ops: [4]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    const w = build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);
    try testing.expectEqual(@as(usize, 0), w.ops);
}

test "각 op이 자기 run을 가리킨다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .bytes = "first" },
        .{ .bytes = "second" },
    };

    var ops: [4]draw.Op = undefined;
    var scratch: [128]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    _ = build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

    try testing.expectEqualStrings("first", ops[0].text.runs[0].text);
    try testing.expectEqualStrings("second", ops[1].text.runs[0].text);
}

test "탭 없는 줄이 이어져도 저장소를 소비하지 않는다 — 회계가 정확해야 아래 줄이 안 죽는다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .bytes = "aaaa" },
        .{ .bytes = "bbbb" },
        .{ .bytes = "cccc" },
    };

    var ops: [8]draw.Op = undefined;
    // 저장소를 일부러 작게 준다. 탭이 없으니 한 byte도 쓰지 않아야 한다 — 길이를 더하는 옛 회계로는
    // 12 byte를 요구해 여기서 죽었다.
    var scratch: [4]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    const w = build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

    try testing.expectEqual(@as(usize, 3), w.ops);
    try testing.expectEqual(@as(usize, 0), w.bytes);
}

test "탭 있는 줄과 없는 줄이 섞여도 회계가 맞는다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .bytes = "plain" },
        .{ .bytes = "\tx" }, // 전개하면 5 byte("    x")
    };

    var ops: [8]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    const w = build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

    try testing.expectEqual(@as(usize, 2), w.ops);
    try testing.expectEqual(@as(usize, 5), w.bytes); // 탭 있는 줄만 셌다
    try testing.expectEqualStrings("plain", ops[0].text.runs[0].text);
    try testing.expectEqualStrings("    x", ops[1].text.runs[0].text);
}

test "expandTabs: 여러 codepoint로 된 cluster도 한 단위로 센다" {
    var out: [64]u8 = undefined;
    // "e" + U+0301(결합 악센트)는 cluster 하나이고 1칸이다. codepoint로 세면 2칸이 되어
    // 탭이 한 칸 덜 들어간다.
    const r = expandTabs("e\u{0301}\tx", 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings("e\u{0301}   x", r.text);
}

test "expandTabs: 지역표시자 국기는 한 cluster다" {
    var out: [64]u8 = undefined;
    // U+1F1F0 U+1F1F7(KR)은 codepoint 둘이지만 화면에서 한 cluster(2칸)다.
    // codepoint로 세면 4칸으로 계산돼 탭 위치가 어긋난다.
    const r = expandTabs("\u{1F1F0}\u{1F1F7}\tx", 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings("\u{1F1F0}\u{1F1F7}  x", r.text);
}

test "expandTabs: BiDi 제어 문자를 보이는 표기로 바꾼다 — Trojan Source 방어" {
    var out: [128]u8 = undefined;
    // U+202E(RLO)는 폭 0이라 보이지 않으면서 뒤 텍스트를 역순으로 보이게 한다.
    const r = expandTabs("// \u{202E}x", 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings("// <U+202E>x", r.text);
}

test "expandTabs: 제어 문자도 보이게 한다 — 편집기에 온 ESC는 파일의 바이트다" {
    var out: [128]u8 = undefined;
    const r = expandTabs("a\x1bb", 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings("a<U+001B>b", r.text);
}

test "expandTabs: 위험 문자만 있고 탭이 없어도 전개된다" {
    var out: [128]u8 = undefined;
    // 탭 유무로만 판단하면 이 줄이 원본 그대로 나가 숨은 문자가 안 보인다.
    const r = expandTabs("\u{200B}", 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings("<U+200B>", r.text);
    try testing.expect(r.scratch_used > 0);
}

test "expandTabs: 표기 폭이 열 계산에 반영된다 — 뒤따르는 탭이 어긋나지 않는다" {
    var out: [128]u8 = undefined;
    // "<U+200B>"는 8칸이다. 그 뒤 탭은 열 8에서 시작하므로 다음 탭스톱(12)까지 4칸.
    const r = expandTabs("\u{200B}\tx", 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings("<U+200B>    x", r.text);
}

test "expandTabs: 평범한 줄은 여전히 원본을 빌려준다 — 저장소를 쓰지 않는다" {
    var out: [8]u8 = undefined;
    const r = expandTabs("const x = 1;", 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings("const x = 1;", r.text);
    try testing.expectEqual(@as(usize, 0), r.scratch_used);
}

test "expandTabs: cluster 안에 묻힌 ZWJ도 드러낸다 — GB9가 앞 글자에 흡수한다" {
    var out: [128]u8 = undefined;
    // `ad<ZWJ>min`은 화면에서 `admin`과 같아 보인다. UAX#29가 ZWJ를 `d`의 cluster로 흡수하므로
    // cluster 단위로만 훑으면 이 문자를 놓친다.
    const r = expandTabs("ad\u{200D}min", 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings("ad<U+200D>min", r.text);
}

test "expandTabs: 이모지 가족은 그대로 둔다 — 정상 ZWJ까지 표기로 바꾸면 안 된다" {
    var out: [128]u8 = undefined;
    const family = "\u{1F468}\u{200D}\u{1F469}";
    const r = expandTabs(family, 4, &out, .{ .count = test_max_cols });
    try testing.expectEqualStrings(family, r.text);
}

test "긴 줄은 화면 폭에서 멈춘다 — 비용이 줄 길이가 아니라 화면 폭에 비례한다" {
    // minified JS처럼 한 줄이 아주 긴 파일이 실제로 있다(§3.8 "초장문 단일 줄"). 상한이 없으면
    // 매 프레임 줄 전체를 훑었다 — 화면엔 `max_cols`만 보이는데.
    var long: [4096]u8 = undefined;
    @memset(&long, 'a');
    long[0] = '\t'; // 탭이 있어야 전개 경로로 간다(없으면 열 계산만 하고 지나간다)

    var out: [64]u8 = undefined;
    const r = expandTabs(&long, 4, &out, .{ .count = 16 });
    // 상한 16칸이면 탭 4칸 + 'a' 12개 = 16칸까지만 만든다. 4096바이트를 전개하지 않는다.
    try testing.expectEqual(@as(usize, 16), r.text.len);
    try testing.expect(r.scratch_used <= 64);
}

test "상한이 있으면 작은 scratch로도 긴 줄이 통과한다 — build 전체가 죽지 않는다" {
    // 초판은 줄 전체를 전개해 scratch를 넘겼고, 그 실패가 `build` 전체를 죽였다(그 줄만이 아니라).
    var long: [2048]u8 = undefined;
    @memset(&long, 'x');
    long[0] = '\t';

    var rows = [_]Row{.{ .bytes = &long }};
    var ops: [4]draw.Op = undefined;
    var scratch: [128]u8 = undefined; // 줄 길이(2048)보다 훨씬 작다
    var runs: [4]draw.Run = undefined;
    const layout = geometry.compute(40, 1, .{});

    const w = build(.{
        .layout = layout,
        .rows = &rows,
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 13,
        .origin_px = .{ .x = 0, .y = 0 },
    }, &ops, &scratch, &runs, &test_visual);

    try testing.expectEqual(@as(usize, 1), w.ops);
    // 쓴 양이 화면 폭 수준이다 — 줄 길이와 무관하다.
    try testing.expect(w.bytes <= layout.content.width + 8);
}

test "상한에 안 닿는 줄은 전과 같다" {
    var out: [64]u8 = undefined;
    const r = expandTabs("a\tb", 4, &out, .{ .count = 80 });
    try testing.expectEqualStrings("a   b", r.text);
}

test "판정도 상한까지만 훑는다 — 긴 줄에서 비용이 줄 길이에 비례하지 않는다" {
    // 탭·위험 문자가 **없는** 긴 줄. 초판은 이 경우 원본을 빌려주되 그 판정에 줄 전체를 훑었다.
    var long: [8192]u8 = undefined;
    @memset(&long, 'a');
    var out: [8]u8 = undefined;

    const r = expandTabs(&long, 4, &out, .{ .count = 20 });
    try testing.expectEqual(@as(usize, 0), r.scratch_used); // 여전히 빌려준다
    // **줄 전체를 돌려주지 않는다** — 화면 폭 기준 상한까지만이라 뒤쪽은 보지도 않았다.
    try testing.expect(r.text.len < long.len);
    try testing.expect(r.text.len >= 20); // 화면을 채울 만큼은 준다
}

test "상한이 UTF-8 중간을 자르지 않는다" {
    // 한글은 3바이트다. 상한이 글자 중간에 떨어지면 깨진 글자가 그려진다.
    var buf: [3000]u8 = undefined;
    var i: usize = 0;
    while (i + 3 <= buf.len) : (i += 3) @memcpy(buf[i..][0..3], "가");
    var out: [8]u8 = undefined;

    const r = expandTabs(buf[0..i], 4, &out, .{ .count = 10 });
    // 3의 배수여야 한글 경계에서 잘린 것이다.
    try testing.expectEqual(@as(usize, 0), r.text.len % 3);
    try testing.expect(std.unicode.utf8ValidateSlice(r.text));
}

test "바이트 → 열: 탭 전개와 2칸 글자를 화면과 같은 규칙으로 센다" {
    // **이 값이 어긋나면 강조가 엉뚱한 글자 위에 선다.** 그래서 판정을 실제 전개 결과와 대조한다 —
    // 별도 걷기를 새로 쓰면 탭스톱·폭 규칙이 두 곳이 되고 그 둘은 반드시 갈린다.
    var scratch: [256]u8 = undefined;
    const tw: u16 = 4;

    // ASCII: 바이트 = 열.
    try testing.expectEqual(@as(u32, 0), columnOfByte("const x", tw, 0, &scratch));
    try testing.expectEqual(@as(u32, 5), columnOfByte("const x", tw, 5, &scratch));

    // 탭: 다음 탭스톱까지 채운다(무조건 tab_width가 아니다).
    try testing.expectEqual(@as(u32, 4), columnOfByte("a\tb", tw, 2, &scratch)); // "a"+탭 → 열 4
    try testing.expectEqual(@as(u32, 8), columnOfByte("abcde\tx", tw, 6, &scratch)); // 5열 뒤 탭 → 8

    // 2칸 글자: 한 글자가 두 열이다.
    try testing.expectEqual(@as(u32, 2), columnOfByte("한a", tw, 3, &scratch)); // '한' = 3byte / 2열

    // **전체를 편 결과와 같은 값이다**(단일 출처 확인).
    inline for ([_][]const u8{ "const x = 1;", "a\tb\tc", "한글 x", "\t\t", "" }) |line| {
        const whole = expandTabs(line, tw, &scratch, .{ .count = std.math.maxInt(u32) });
        const by_sum = columnsOf(whole.text);
        var tail: [256]u8 = undefined;
        try testing.expectEqual(by_sum, columnOfByte(line, tw, line.len, &tail));
    }
}

test "한 번 훑기와 실제 전개가 같은 열을 준다 — 무작위 300줄" {
    // 두 구현이 갈리면 강조가 글자에서 밀린다. 느린 쪽(`columnOfByte` — 실제로 펴서 센다)을 판정자로
    // 두고, 빠른 쪽이 그것과 같은지 본다.
    var scratch: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    var case_i: usize = 0;
    while (case_i < 300) : (case_i += 1) {
        var line_buf: [64]u8 = undefined;
        const n = rnd.uintLessThan(usize, line_buf.len);
        var len: usize = 0;
        while (len < n) {
            // **§3.8 문자가 알파벳에 있어야 한다.** 예전 알파벳은 탭·한글·이모지·ASCII뿐이라,
            // 위험 문자에서 두 구현이 갈린 것을 300줄을 돌고도 못 봤다(적대적 검증 2026-08-16).
            const pick = rnd.uintLessThan(u8, 9);
            const piece: []const u8 = switch (pick) {
                0 => "\t",
                1 => "한",
                2 => "a",
                3 => " ",
                4 => "😀",
                5 => "\u{202E}", // BiDi override — Trojan Source
                6 => "\u{200D}", // ZWJ — 앞 글자 cluster에 흡수된다
                7 => "\u{00AD}", // soft hyphen — 보이지 않는다
                else => "z",
            };
            if (len + piece.len > line_buf.len) break;
            @memcpy(line_buf[len .. len + piece.len], piece);
            len += piece.len;
        }
        const line = line_buf[0..len];
        const tw: u16 = if (rnd.boolean()) 4 else 8;

        // cluster 경계에서만 물어본다(마크가 그렇게 만들어진다).
        var offsets: [64]u32 = undefined;
        var expected: [64]u32 = undefined;
        var count: usize = 0;
        var i: usize = 0;
        while (i <= line.len and count < offsets.len) {
            offsets[count] = @intCast(i);
            var tail: [4096]u8 = undefined;
            expected[count] = columnOfByte(line, tw, i, &tail);
            count += 1;
            if (i == line.len) break;
            const base = text_layout.decodeCodepoint(line, i);
            const end = @min(text_layout.clusterEndAfter(line, i, base.advance), line.len);
            i += @max(1, end - i);
        }

        var got: [64]u32 = undefined;
        columnsAtOffsets(line, tw, offsets[0..count], got[0..count], std.math.maxInt(u32));
        for (0..count) |k| {
            if (expected[k] != got[k]) {
                std.debug.print("\n[불일치] 줄=", .{});
                for (line) |b| std.debug.print("{X:0>2} ", .{b});
                std.debug.print("\n  offset={d} 오라클={d} 빠른쪽={d} tw={d}\n", .{ offsets[k], expected[k], got[k], tw });
                return error.Mismatch;
            }
        }
        _ = &scratch;
    }
}

test "제자리 채우기가 따로 받은 것과 같은 답을 준다 — 프레임이 그렇게 부른다" {
    // `frame.paintBands`가 저장소를 아끼려고 `columnsAtOffsets(line, tw, offsets, offsets, …)`로
    // **같은 메모리**를 넘긴다. 지금은 칸을 소비한 뒤에 덮어서 안전한데, 그 성질은 코드를 읽어야만
    // 보인다 — 앞칸을 되읽는 수정이 들어오면 조용히 틀린 열이 나온다. 무작위로 대조한다.
    var prng = std.Random.DefaultPrng.init(0xa11a_5eed);
    const rnd = prng.random();
    const vocab = [_][]const u8{ "a", "\t", "가", "😀", "e\u{0301}", "  " };
    var round: usize = 0;
    while (round < 500) : (round += 1) {
        var line: [160]u8 = undefined;
        var n: usize = 0;
        var pieces = rnd.uintLessThan(usize, 40);
        while (pieces > 0 and n + 8 < line.len) : (pieces -= 1) {
            const w = vocab[rnd.uintLessThan(usize, vocab.len)];
            @memcpy(line[n..][0..w.len], w);
            n += w.len;
        }
        const bytes = line[0..n];

        var raw: [16]u32 = undefined;
        const cnt = rnd.uintLessThan(usize, raw.len) + 1;
        for (raw[0..cnt]) |*o| o.* = rnd.uintAtMost(u32, @intCast(n + 4));
        std.mem.sort(u32, raw[0..cnt], {}, std.sort.asc(u32)); // 계약: 오름차순

        const stop = rnd.uintAtMost(u32, 200);
        var separate: [16]u32 = undefined;
        columnsAtOffsets(bytes, 4, raw[0..cnt], separate[0..cnt], stop);

        var inplace: [16]u32 = undefined;
        @memcpy(inplace[0..cnt], raw[0..cnt]);
        columnsAtOffsets(bytes, 4, inplace[0..cnt], inplace[0..cnt], stop);

        try std.testing.expectEqualSlices(u32, separate[0..cnt], inplace[0..cnt]);
    }
}

test "위험 문자가 있는 줄도 마크 열이 렌더와 같다 — §3.8" {
    // 렌더(`expandTabs`)는 위험 문자를 `<U+202E>` 같은 표기로 바꾸고 그 **글자 수만큼** 열을 민다.
    // 마크 열을 세는 `columnsAtOffsets`는 원본 폭(BiDi 제어 = 0칸)만 본다. 갈리면 강조가 밀린다.
    const line = "\u{202E}abc";
    var buf: [64]u8 = undefined;
    const e = expandTabs(line, 4, &buf, .{ .start = 0, .count = 60 });

    // "abc"는 바이트 3에서 시작한다(U+202E는 3바이트).
    const offs = [_]u32{3};
    var got = [_]u32{0};
    columnsAtOffsets(line, 4, &offs, &got, 1000);
    try std.testing.expectEqual(@as(u32, @intCast(e.text.len - 3)), got[0]);
}

test "lineColumns가 실제 전개와 같은 열 수를 준다 — 탭·2칸 글자·§3.8 표기" {
    var scratch: [512]u8 = undefined;
    for ([_][]const u8{
        "",
        "abc",
        "\tabc",
        "a\tb",
        "한글abc",
        "😀\t가",
        "\u{202E}abc",
        "ad\u{200D}min\tx",
        "\u{00AD}\u{00AD}z",
        // 빠른 길(출력 가능한 ASCII만)과 그 경계 — 제어 문자·DEL은 빠른 길을 타면 안 된다.
        "plain ascii only 12345 !@#~",
        "ctrl\x01here",
        "del\x7Fhere",
    }) |line| {
        const e = expandTabs(line, 4, &scratch, .{ .count = std.math.maxInt(u32) });
        try std.testing.expectEqual(columnsOf(e.text), lineColumns(line, 4));
    }
}

test "가로로 민 전개가 앞을 잘라 편 것과 같다 — 건너뛰기가 결과를 바꾸면 안 된다" {
    // `expandTabs`는 화면 시작 열 앞을 **지나가기만** 한다. 그 구간에서 출력 가능한 ASCII를
    // 한 바이트씩 건너뛰는 지름길을 넣었는데(가로로 멀리 밀면 프레임당 498ms였다), 빠르면서 틀리면
    // 최악이다. **앞을 실제로 잘라 편 것**과 대조한다.
    //
    // 탭이 없는 줄만 본다 — 탭스톱은 절대 열에 걸리므로 앞을 자르면 정의상 달라진다.
    var prng = std.Random.DefaultPrng.init(0x5c0117);
    const rnd = prng.random();
    const vocab = [_][]const u8{ "a", "z", " ", "한", "😀", "\u{202E}", "\u{200D}", "e\u{0301}" };
    var round: usize = 0;
    while (round < 400) : (round += 1) {
        var line: [256]u8 = undefined;
        var n: usize = 0;
        var pieces = rnd.uintLessThan(usize, 40);
        while (pieces > 0 and n + 8 < line.len) : (pieces -= 1) {
            const w = vocab[rnd.uintLessThan(usize, vocab.len)];
            @memcpy(line[n..][0..w.len], w);
            n += w.len;
        }
        const bytes = line[0..n];
        const start: u16 = @intCast(rnd.uintAtMost(usize, 40));
        const count: u32 = rnd.uintAtMost(u32, 30) + 1;

        var a_buf: [1024]u8 = undefined;
        const got = expandTabs(bytes, 4, &a_buf, .{ .start = start, .count = count });

        // 참조: `start` 열까지 한 걸음씩 지나 그 byte에서 자른 뒤, 처음부터 편다.
        var ref_i: usize = 0;
        var ref_col: u32 = 0;
        while (ref_i < bytes.len and ref_col < start) {
            const s = stepColumn(bytes, ref_i, ref_col, 4);
            ref_i = s.next_byte;
            ref_col = s.next_col;
        }
        // 걸쳐서 `start`를 넘어섰으면 잘라 낸 쪽과 남긴 쪽이 다를 수 있다 — 그건 계약이 정한
        // 경계 처리라 이 대조의 대상이 아니다.
        if (ref_col != start) continue;
        var b_buf: [1024]u8 = undefined;
        const ref = expandTabs(bytes[ref_i..], 4, &b_buf, .{ .start = 0, .count = count });

        try std.testing.expectEqualStrings(ref.text, got.text);
    }
}

test "긴 비ASCII 줄도 저장소와 무관하게 같은 조각 수를 준다 — 안 그러면 끝에 못 닿는다" {
    const n = 60_000;
    const a = try std.testing.allocator.alloc(u8, n * 3);
    defer std.testing.allocator.free(a);
    var i: usize = 0;
    while (i < n) : (i += 1) @memcpy(a[i * 3 ..][0..3], "한");

    var small: [8192]u8 = undefined;
    const big = try std.testing.allocator.alloc(u8, 4 << 20);
    defer std.testing.allocator.free(big);

    const r_small = rowCount(a, 4, 92, true, &small);
    const r_big = rowCount(a, 4, 92, true, big);
    // 고치기 전: 8KB → 60행, 4MB → 1,305행(21배 차이). 지금은 저장소를 안 쓴다.
    try std.testing.expectEqual(r_big.rows, r_small.rows);
    try std.testing.expect(!r_small.truncated);
    try std.testing.expect(r_small.rows > 1000);
}

test "탭이 든 긴 줄도 행 수가 절단되지 않는다" {
    // 8 KiB 저장소에서는 **103행**이었고 실제는 **250행**이다 — 랩에서 그 줄의 59%가 못 닿는다.
    // 빠른 길(전개 없음)은 탭이 있으면 안 타므로, 저장소 크기가 그대로 답이 된다.
    const a = std.testing.allocator;
    const line = try a.alloc(u8, 10_000);
    defer a.free(line);
    var i: usize = 0;
    while (i < line.len) : (i += 2) {
        line[i] = 'a';
        line[i + 1] = '\t';
    }

    const big = try a.alloc(u8, 1 << 20);
    defer a.free(big);
    const want = rowCount(line, 4, 80, true, big);
    try std.testing.expect(!want.truncated); // 기준 자체가 절단됐으면 판정이 공허하다

    const scratch = try a.alloc(u8, count_scratch_bytes);
    defer a.free(scratch);
    const got = rowCount(line, 4, 80, true, scratch);
    try std.testing.expect(!got.truncated);
    try std.testing.expectEqual(want.rows, got.rows);
    try std.testing.expect(got.rows > 200); // 8 KiB였다면 103행이다
}

/// **측정용 프로토타입** — 목표 열 이하에서 가장 가까운 cluster 경계의 원본 byte.
///
/// `stepColumn`을 되짚을 뿐이라 탭스톱·cluster 분절·§3.8 표기 규칙이 갈리지 않는다.
fn byteAtColumnProto(bytes: []const u8, tab_width: u16, target_col: u32) usize {
    var i: usize = 0;
    var col: u32 = 0;
    while (i < bytes.len) {
        const st = stepColumn(bytes, i, col, tab_width);
        if (st.next_col > target_col) break;
        i = st.next_byte;
        col = st.next_col;
    }
    return i;
}

/// **측정용 프로토타입** — 전개하지 않고 **원본에서** 랩 조각 경계를 낸다.
///
/// 역방향(`hitTestBody`)이 원본 byte offset을 돌려주어야 하므로(§4.1g — `Selection`이 byte 기반),
/// 조각 경계도 원본 byte였으면 좋겠다. 지금은 `visual_map.Pieces`가 **전개 텍스트**를 자르므로
/// 그 경계가 전개 좌표계에 있다. 이 프로토타입은 "원본에서 같은 규칙으로 자르면 같은 경계가
/// 나오는가"를 재기 위한 것이다 — 같으면 전개 없이 갈 수 있고, 다르면 그 길은 죽는다.
fn piecesFromSourceProto(bytes: []const u8, tab_width: u16, view_cols: u16, out: []u32) usize {
    if (out.len == 0) return 0;
    var n: usize = 0;
    out[n] = 0;
    n += 1;
    if (bytes.len == 0 or view_cols == 0) return n;

    var i: usize = 0;
    var abs_col: u32 = 0; // 줄 전체 기준 — 탭스톱이 이 값으로 정해진다
    var row_start_byte: usize = 0;
    var row_start_col: u32 = 0;
    while (i < bytes.len) {
        const st = stepColumn(bytes, i, abs_col, tab_width);
        if (st.next_col - row_start_col > view_cols) {
            if (i == row_start_byte) {
                // 한 cluster가 뷰보다 넓다 — 그래도 하나는 넣고 전진한다(`Pieces`와 같은 규칙).
                i = st.next_byte;
                abs_col = st.next_col;
            }
            if (n >= out.len) return n;
            out[n] = @intCast(i);
            n += 1;
            row_start_byte = i;
            row_start_col = abs_col;
            continue;
        }
        i = st.next_byte;
        abs_col = st.next_col;
    }
    return n;
}

test "[실측] 원본 기준 랩 분할은 전개 기준과 갈리는가" {
    // **§4.1g의 (가)안이 여기서 살거나 죽는다.** 전개하지 않고 원본에서 조각을 나눌 수 있으면
    // 역방향이 원본 byte를 곧장 다루고, 전개 좌표계 ↔ 원본 좌표계 환산이 통째로 없어진다.
    //
    // §4.1c가 이미 비슷한 것을 기록해 두었다 — 행 수를 세는 "경량 경로"를 따로 두었다가 990건 중
    // 80건이 갈렸고, 원인 중 하나가 **탭이 행 경계에서 쪼개진다는 것**이었다. 그 결론은 "전개 결과를
    // 그대로 세면 규칙이 한 곳이라 갈릴 수 없다"였다. 그 판단이 이 방향에도 그대로 적용되는지 **재서**
    // 확인한다 — 문서가 그렇다고 적혀 있다는 것과 지금 이 코드가 그렇다는 것은 다른 말이다.
    const alloc = std.testing.allocator;
    const alphabet = [_][]const u8{
        "a",  "b",
        "가",
        "나",
        "😀",
        "\t", " ",
        "z",
        "\u{202E}", // BiDi override — §3.8 표기로 8칸이 된다
        "\u{200D}", // ZWJ — cluster를 늘린다
        "\u{00AD}", // soft hyphen
    };
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rand = prng.random();

    var mismatch: usize = 0;
    var total: usize = 0;
    var first_bad: ?struct { cols: u16, tab: u16, src: usize, exp: usize } = null;

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    const scratch = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(scratch);
    const src_starts = try alloc.alloc(u32, 4096);
    defer alloc.free(src_starts);

    for (0..600) |_| {
        line.clearRetainingCapacity();
        const len = 100 + rand.uintLessThan(usize, 500);
        for (0..len) |_| try line.appendSlice(alloc, alphabet[rand.uintLessThan(usize, alphabet.len)]);
        // **현실적인 본문 폭으로 잰다**(적대적 검증 5회차). 초판은 2~31열이었는데 2열에서는 2칸
        // 글자가 **늘** 행을 걸치므로 쪼개짐 비율이 구조적으로 부풀려진다. 실제 본문은 80~200열이다.
        const view_cols: u16 = @intCast(80 + rand.uintLessThan(u16, 121));
        const tab_width: u16 = @intCast(1 + rand.uintLessThan(u16, 8));

        // ① 지금 경로 — 전개한 뒤 `visual_map`이 자른다.
        const exp = expandTabs(line.items, tab_width, scratch, .{ .count = std.math.maxInt(u32) });
        var it = visual_map.pieces(exp.text, view_cols, true);
        var expanded_pieces: usize = 0;
        while (it.next()) |_| expanded_pieces += 1;

        // ② 프로토타입 — 원본에서 같은 규칙으로 자른다.
        const source_pieces = piecesFromSourceProto(line.items, tab_width, view_cols, src_starts);

        total += 1;
        if (expanded_pieces != source_pieces) {
            mismatch += 1;
            if (first_bad == null) first_bad = .{
                .cols = view_cols,
                .tab = tab_width,
                .src = source_pieces,
                .exp = expanded_pieces,
            };
        }
    }
    std.debug.print(
        "\n[실측] 원본 기준 vs 전개 기준 랩 분할: {d}/{d} 불일치\n",
        .{ mismatch, total },
    );
    if (first_bad) |b| std.debug.print(
        "  첫 불일치: view_cols={d} tab_width={d} → 원본 {d}조각, 전개 {d}조각\n",
        .{ b.cols, b.tab, b.src, b.exp },
    );
}

test "[실측] 대조 도구부터 검증한다 — 탭도 §3.8도 없으면 두 방식이 같아야 한다" {
    // **17%라는 수치는 `piecesFromSourceProto`가 `visual_map.Pieces`의 규칙을 옳게 흉내 냈을 때만
    // 뜻이 있다.** 프로토타입에 버그가 있으면 그 불일치는 "좌표계가 갈린다"가 아니라 "내 흉내가
    // 틀렸다"를 잰 것이 된다.
    //
    // 그래서 **갈릴 이유가 없는 입력**으로 먼저 맞춘다: 탭도 §3.8 문자도 없는 줄은 전개해도 원본과
    // 같은 바이트열이므로 두 방식이 **정확히 같은 조각**을 내야 한다. 여기서 어긋나면 위 수치를
    // 믿을 수 없다.
    const alloc = std.testing.allocator;
    const alphabet = [_][]const u8{ "a", "b", "z", "가", "나", "😀", " " }; // 탭·hazard 없음
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const rand = prng.random();

    var mismatch: usize = 0;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    const scratch = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(scratch);
    const src_starts = try alloc.alloc(u32, 4096);
    defer alloc.free(src_starts);

    for (0..600) |_| {
        line.clearRetainingCapacity();
        const len = 100 + rand.uintLessThan(usize, 500);
        for (0..len) |_| try line.appendSlice(alloc, alphabet[rand.uintLessThan(usize, alphabet.len)]);
        const view_cols: u16 = @intCast(80 + rand.uintLessThan(u16, 121));
        const tab_width: u16 = @intCast(1 + rand.uintLessThan(u16, 8));

        const exp = expandTabs(line.items, tab_width, scratch, .{ .count = std.math.maxInt(u32) });
        if (exp.truncated) continue;
        var it = visual_map.pieces(exp.text, view_cols, true);
        var expanded_pieces: usize = 0;
        while (it.next()) |_| expanded_pieces += 1;
        const source_pieces = piecesFromSourceProto(line.items, tab_width, view_cols, src_starts);
        if (expanded_pieces != source_pieces) mismatch += 1;
    }
    std.debug.print("\n[실측] 대조 도구 자기검증(탭·§3.8 없음): {d}/600 불일치\n", .{mismatch});
    // **여기가 0이 아니면 위 17%는 좌표계가 아니라 이 도구를 잰 것이다.**
    try std.testing.expectEqual(@as(usize, 0), mismatch);
}

test "[실측] 열이 두 좌표계의 다리가 되는가 — 전개 byte ↔ 원본 byte" {
    // **(가)안이 죽은 뒤 남은 길이다.** 조각 경계는 전개 좌표계에 있고(`visual_map.Pieces`),
    // `Selection`은 원본 byte를 요구한다. 둘을 **열**로 이으면 새 규칙 없이 왕복할 수 있다:
    //
    //   전개 byte --`columnsOf`--> 열 --`stepColumn` 되짚기--> 원본 byte
    //
    // 성립 조건은 **열의 정의가 두 좌표계에서 같다**는 것이다. 원본 쪽은 `stepColumn`이 세고
    // (탭스톱·§3.8 표기 포함), 전개 쪽은 전개 결과를 `columnsOf`가 센다 — 정의상 같아야 하지만,
    // §4.1c가 "이 정의를 어긴 자리가 두 곳 있었다"고 적은 자리라 **재서** 확인한다.
    const alloc = std.testing.allocator;
    const alphabet = [_][]const u8{
        "a",        "b",
        "가",
        "나",
        "😀",
        "\t",       " ",
        "z",        "\u{202E}",
        "\u{200D}", "\u{00AD}",
    };
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    var col_mismatch: usize = 0;
    var roundtrip_bad: usize = 0;
    var checked_pieces: usize = 0;
    var lines: usize = 0;
    var split_tab: usize = 0;
    var split_wide: usize = 0;
    var split_other: usize = 0;

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    const scratch = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(scratch);
    const scratch2 = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(scratch2);

    for (0..600) |_| {
        line.clearRetainingCapacity();
        const len = 100 + rand.uintLessThan(usize, 500);
        for (0..len) |_| try line.appendSlice(alloc, alphabet[rand.uintLessThan(usize, alphabet.len)]);
        // **현실적인 본문 폭으로 잰다**(적대적 검증 5회차). 초판은 2~31열이었는데 2열에서는 2칸
        // 글자가 **늘** 행을 걸치므로 쪼개짐 비율이 구조적으로 부풀려진다. 실제 본문은 80~200열이다.
        const view_cols: u16 = @intCast(80 + rand.uintLessThan(u16, 121));
        const tab_width: u16 = @intCast(1 + rand.uintLessThan(u16, 8));
        lines += 1;

        const exp = expandTabs(line.items, tab_width, scratch, .{ .count = std.math.maxInt(u32) });
        if (exp.truncated) continue;

        // ① 열 정의가 두 좌표계에서 같은가.
        if (lineColumns(line.items, tab_width) != columnsOf(exp.text)) col_mismatch += 1;

        // ② 조각 시작을 열로 옮기고, 그 열에서 원본 byte를 얻어 **다시 열로** 돌아온다.
        var it = visual_map.pieces(exp.text, view_cols, true);
        while (it.next()) |p| {
            const col_at_piece = columnsOf(exp.text[0..p.start]);
            const src_off = byteAtColumnProto(line.items, tab_width, col_at_piece);
            const back = columnOfByte(line.items, tab_width, src_off, scratch2);
            checked_pieces += 1;
            if (back != col_at_piece) {
                roundtrip_bad += 1;
                // **무엇이 그 자리에 있었나.** 조각 시작이 원본 cluster의 **안쪽**이면 대응하는
                // byte가 없다 — 결함이 아니라 구조적 사실이다(§10 "역방향은 왕복이 아니다").
                // 어느 문자가 그렇게 쪼개지는지 세어 결정표의 근거로 삼는다.
                if (src_off < line.items.len) {
                    const b = line.items[src_off];
                    if (b == '\t') split_tab += 1 else if (b >= 0x80) split_wide += 1 else split_other += 1;
                }
            }
        }
    }
    std.debug.print(
        "\n[실측] 열 정의 불일치 {d}/{d}줄 · 조각 시작이 원본 cluster 안쪽 {d}/{d} (탭 {d} · 넓은글자·표기 {d} · 그밖 {d})\n",
        .{ col_mismatch, lines, roundtrip_bad, checked_pieces, split_tab, split_wide, split_other },
    );
}

test "조각 시작 열과 원본 byte가 실제 조각과 맞는다 — 무작위 대조" {
    // **`build`가 행마다 실어 주는 `(start_col, start_byte)`가 옳은가**(§4.1g). 이 값이 틀리면
    // 랩된 줄에서 강조가 밀리고 클릭이 엉뚱한 글자를 가리킨다 — 그리고 **둘 다 조용히 틀린다**.
    //
    // 판정은 왕복이 아니라 **독립 계산과의 대조**다: 조각 시작 열은 전개 텍스트에서 직접 세고
    // (`columnsOf(expanded[0..piece.start])` + `first_col`), 원본 byte는 그 열에서 원본을 걸어 얻는다.
    // `build`의 누적 경로와 다른 길이므로 같은 답이 나오면 그 누적이 맞다는 뜻이다.
    const alloc = std.testing.allocator;
    const alphabet = [_][]const u8{
        "a",        "b",        "z",
        "가",
        "나",
        "😀",
        "\t",       " ",        "\u{202E}",
        "\u{200D}", "\u{00AD}",
    };
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rand = prng.random();

    const scratch = try alloc.alloc(u8, 256 * 1024);
    defer alloc.free(scratch);
    const scratch2 = try alloc.alloc(u8, 256 * 1024);
    defer alloc.free(scratch2);

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);

    var checked: usize = 0;
    for (0..300) |_| {
        line.clearRetainingCapacity();
        const len = 20 + rand.uintLessThan(usize, 200);
        for (0..len) |_| try line.appendSlice(alloc, alphabet[rand.uintLessThan(usize, alphabet.len)]);
        const view_cols: u16 = @intCast(20 + rand.uintLessThan(u16, 60));
        const tab_width: u16 = @intCast(1 + rand.uintLessThan(u16, 8));

        const exp = expandTabs(line.items, tab_width, scratch, .{ .count = std.math.maxInt(u32) });
        if (exp.truncated) continue;

        var it = visual_map.pieces(exp.text, view_cols, true);
        var acc: u32 = 0; // `build`가 하는 것과 같은 누적
        while (it.next()) |piece| {
            // ① 열: 누적한 값이 전개 텍스트에서 직접 센 값과 같은가.
            const direct_col = columnsOf(exp.text[0..piece.start]);
            try std.testing.expectEqual(direct_col, acc);

            // ② 원본 byte: 그 열에서 원본을 걸어 얻은 위치와 같은가.
            const direct_byte = byteAtColumnProto(line.items, tab_width, acc);
            const back = columnOfByte(line.items, tab_width, direct_byte, scratch2);
            // 걸친 cluster면 그 시작에 머문다 — 열이 뒤로 물러날 수는 있어도 넘어서지 않는다.
            try std.testing.expect(back <= acc);

            acc += piece.cols;
            checked += 1;
        }
        // 마지막 누적은 줄 전체 열과 같아야 한다 — 조각들이 줄을 빠짐없이 덮는다.
        try std.testing.expectEqual(lineColumns(line.items, tab_width), acc);
    }
    try std.testing.expect(checked > 300); // 대조가 실제로 돌았다
}

test "byteAtPoint: 아무 픽셀을 쏴도 cluster 경계이고 줄 범위 안이다 (§4.1g 주 판정)" {
    // **§10이 정한 세 번째 불변식이 이 슬라이스의 주 판정이다.** 역방향은 왕복이 아니므로 등식을
    // 기대할 수 없고(실측: 조각 시작의 48%가 원본 cluster 경계가 아니다), 대신 *"결과가 cluster
    // 경계이고 범위 안"*이라는 더 약한 것을 지킨다.
    //
    // 알파벳에 §3.8 문자가 들어 있다 — §4.1c가 정한 규율이고, **Vim이 아직 못 고친 함정**이 정확히
    // 이 종류다(conceal 폭이 1보다 크면 커서가 틀린 자리에 선다, neovim#25915).
    const alloc = std.testing.allocator;
    const alphabet = [_][]const u8{
        "a",        "b",        "z",
        "가",
        "나",
        "😀",
        "\t",       " ",        "\u{202E}",
        "\u{200D}", "\u{00AD}",
    };
    var prng = std.Random.DefaultPrng.init(0xD00D);
    const rand = prng.random();

    const scratch = try alloc.alloc(u8, 256 * 1024);
    defer alloc.free(scratch);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);

    var shots: usize = 0;
    for (0..300) |_| {
        line.clearRetainingCapacity();
        const len = 20 + rand.uintLessThan(usize, 120);
        for (0..len) |_| try line.appendSlice(alloc, alphabet[rand.uintLessThan(usize, alphabet.len)]);
        const tab_width: u16 = @intCast(1 + rand.uintLessThan(u16, 8));
        const cell_w: u16 = @intCast(6 + rand.uintLessThan(u16, 10));
        const view_cols: u16 = @intCast(20 + rand.uintLessThan(u16, 60));

        const exp = expandTabs(line.items, tab_width, scratch, .{ .count = std.math.maxInt(u32) });
        if (exp.truncated) continue;

        // 행마다 그 행의 시작 정보를 만들고, 그 안팎으로 좌표를 쏜다.
        var it = visual_map.pieces(exp.text, view_cols, true);
        var acc: u32 = 0;
        while (it.next()) |piece| {
            const start_byte = byteAtColumnProto(line.items, tab_width, acc);
            defer acc += piece.cols;

            for (0..12) |_| {
                // 행 밖(음수·오른쪽 한참)까지 포함해 쏜다 — 드래그는 화면을 벗어난다.
                const span: i32 = @intCast((piece.cols + 8) * cell_w);
                const x: i32 = @as(i32, @intCast(rand.uintLessThan(u32, @intCast(span + 40)))) - 20;
                const off = byteAtPoint(line.items, tab_width, start_byte, acc, acc, piece.cols, x, cell_w);
                shots += 1;

                // ⑴ 줄 범위 안
                try std.testing.expect(off <= line.items.len);
                // ⑵ cluster 경계 — **줄 머리에서 걸어 도달하는 자리인가.**
                //
                //    초판은 "그 위치에서 줄 끝까지 걸으면 도달한다"를 봤는데 **항진명제**였다:
                //    `stepColumn`은 늘 1 이상 전진하고 `next_byte`를 `@min(…, len)`으로 묶으므로
                //    어떤 시작점에서도 끝에 닿는다(8차 적대적 검증이 실측했다 — 경계 아닌 시작점
                //    9개를 하나도 못 걸렀다).
                var reachable = off == 0;
                var walk: usize = 0;
                var wcol: u32 = 0;
                while (walk < line.items.len and walk < off) {
                    const st = stepColumn(line.items, walk, wcol, tab_width);
                    walk = st.next_byte;
                    wcol = st.next_col;
                    if (walk == off) reachable = true;
                }
                try std.testing.expect(reachable);
                // ⑶ 이 행이 시작한 자리보다 앞으로 가지 않는다
                try std.testing.expect(off >= start_byte);
            }
        }
    }
    try std.testing.expect(shots > 1000);
}

test "byteAtPoint 결정표: 걸친 자리마다 무엇을 답하는가 (§4.1g)" {
    // 계약의 표를 그대로 고정한다. **폭이 다른 셋을 같은 규칙으로 판정한다** — 2칸 글자·탭·8칸 표기.
    const cw: u16 = 10;

    {
        // ① 2칸 글자: 왼쪽 절반이면 앞(0), 오른쪽이면 뒤(3바이트 = "가" 다음).
        const line = "가나";
        try std.testing.expectEqual(@as(usize, 0), byteAtPoint(line, 4, 0, 0, 0, 4, 0, cw));
        try std.testing.expectEqual(@as(usize, 0), byteAtPoint(line, 4, 0, 0, 0, 4, 9, cw));
        try std.testing.expectEqual(@as(usize, 3), byteAtPoint(line, 4, 0, 0, 0, 4, 10, cw));
        try std.testing.expectEqual(@as(usize, 3), byteAtPoint(line, 4, 0, 0, 0, 4, 19, cw));
    }
    {
        // ② 탭(폭 4 → 40px): 같은 절반 규칙. 20px가 경계다.
        const line = "\tx";
        try std.testing.expectEqual(@as(usize, 0), byteAtPoint(line, 4, 0, 0, 0, 5, 19, cw));
        try std.testing.expectEqual(@as(usize, 1), byteAtPoint(line, 4, 0, 0, 0, 5, 20, cw));
    }
    {
        // ③ §3.8 표기: `\u{202E}`가 `<U+202E>` 8칸(80px)으로 그려진다. 40px가 경계다.
        //    **안으로 들어가지 않는다** — 그 안에는 문서에 없는 offset뿐이다.
        const line = "\u{202E}x";
        try std.testing.expectEqual(@as(usize, 0), byteAtPoint(line, 4, 0, 0, 0, 9, 39, cw));
        try std.testing.expectEqual(@as(usize, 3), byteAtPoint(line, 4, 0, 0, 0, 9, 40, cw)); // U+202E는 3바이트
    }
    {
        // ④ 행 끝 너머 → 행 끝. 행 왼쪽 밖 → 행 시작.
        const line = "ab";
        try std.testing.expectEqual(@as(usize, 2), byteAtPoint(line, 4, 0, 0, 0, 2, 9_999, cw));
        try std.testing.expectEqual(@as(usize, 0), byteAtPoint(line, 4, 0, 0, 0, 2, -50, cw));
    }
    {
        // ⑤ **랩된 두 번째 행**: "줄 끝"이 아니라 "행 끝"이다(적대적 검증 19회차).
        //    "abcdef"를 2열씩 끊었다고 보고 세 번째 행(start_col=4, start_byte=4, cols=2)을 본다.
        //    그 행 오른쪽 너머를 눌러도 **줄 맨 끝(6)이 아니라 그 행의 끝**에서 멈춘다.
        const line = "abcdefghij";
        try std.testing.expectEqual(@as(usize, 6), byteAtPoint(line, 4, 4, 4, 4, 2, 9_999, cw));
        // 그 행의 왼쪽 밖은 줄 시작(0)이 아니라 **행 시작**(4)이다.
        try std.testing.expectEqual(@as(usize, 4), byteAtPoint(line, 4, 4, 4, 4, 2, -1, cw));
    }
}

test "byteAtPoint: 왼쪽에서 잘린 cluster는 보이는 잔여분의 중점으로 가른다 (§4.1g)" {
    // **`start_byte_col`이 `screen_col0`과 다른 유일한 경우이고, 그것을 재는 유일한 테스트다.**
    // 7차 적대적 검증이 잡았다: 다른 모든 호출이 두 인자에 같은 값을 넘겨, 계약이 명문화한 "보이는
    // 잔여분의 중점"이 코드에 고정돼 있지 않았다(cluster 전체 중점으로 바꿔도 전 스위트가 통과했다).
    const cw: u16 = 10;

    {
        // 탭(폭 4, 절대 열 [0,4))이 화면 0열=절대 2에서 잘렸다 → 보이는 잔여 2칸(20px).
        // 잔여분 중점은 10px다. 그 왼쪽이면 탭 앞(0), 오른쪽이면 탭 뒤(1바이트).
        const line = "\tX";
        try std.testing.expectEqual(@as(usize, 0), byteAtPoint(line, 4, 0, 0, 2, 4, 0, cw));
        try std.testing.expectEqual(@as(usize, 0), byteAtPoint(line, 4, 0, 0, 2, 4, 9, cw));
        try std.testing.expectEqual(@as(usize, 1), byteAtPoint(line, 4, 0, 0, 2, 4, 10, cw));
        try std.testing.expectEqual(@as(usize, 1), byteAtPoint(line, 4, 0, 0, 2, 4, 19, cw));

        // **cluster 전체의 중점(20px)으로 가르면 이 셋이 전부 0이 된다** — 계약이 배격한 해석이다.
        // 그 중점은 화면 **밖**이라(절대 열 2 = 화면 0) 보이는 픽셀 전부가 한쪽으로 간다.
    }
    {
        // §3.8 표기: `\u{202E}`가 `<U+202E>` 8칸이 되고, 화면 0열=절대 5에서 잘렸다 → 잔여 3칸(30px).
        // 잔여분 중점은 15px. 표기 **안으로 들어가지 않는다** — 앞이면 0, 뒤면 그 문자 다음(3바이트).
        const line = "\u{202E}Y";
        try std.testing.expectEqual(@as(usize, 0), byteAtPoint(line, 4, 0, 0, 5, 3, 14, cw));
        try std.testing.expectEqual(@as(usize, 3), byteAtPoint(line, 4, 0, 0, 5, 3, 15, cw));
    }
}

test "byteAtPoint: 홀수 셀 폭에서도 중점 반올림 방향이 고정이다 (§4.1g)" {
    // **코퍼스가 전부 짝수 폭이라 이 규칙이 원리상 안 보였다**(8차 적대적 검증). 제품 fixture는
    // `cell_width_px = 8`, 다른 단위 테스트는 `cw = 10`이라 `hi - lo`가 늘 짝수이고, 그러면 내림과
    // 올림이 같은 답을 낸다 — §4.1g가 문단 하나를 들여 *"중점도 정수 나눗셈으로 내린다"*고 정하고
    // 7px 셀 예까지 들었는데 그 방향을 바꿔도 전 스위트가 통과했다.
    //
    // 작은 폰트에서 홀수 셀 폭은 실제로 나온다.
    const cw: u16 = 7;
    const line = "\tX"; // 탭 폭 3 → 21px. 중점은 10.5px이고 **내림이면 10**이다.
    try std.testing.expectEqual(@as(usize, 0), byteAtPoint(line, 3, 0, 0, 0, 3, 9, cw));
    // 10px은 내림 중점과 같으므로 "오른쪽"이다 — 올림(11)이면 여기서 0이 나온다.
    try std.testing.expectEqual(@as(usize, 1), byteAtPoint(line, 3, 0, 0, 0, 3, 10, cw));
}

test "byteAtPoint: 시작 열이 화면 0열보다 뒤여도 죽지 않는다 (saturating)" {
    // **`-|`가 실제로 하는 일을 재는 유일한 테스트다.** 9차 적대적 검증이 이 경로가 도달 가능함을
    // 보였다 — `-`로 되돌리면 여기서 u32 언더플로로 **SIGABRT**다.
    //
    // 정상 경로에서는 `build`가 `start_byte_col <= start_col`을 세우므로 안 온다. 그런데 그 결합이
    // 이 함수 밖에 있어 호출자가 하나 늘면 조용히 깨지고, 그때 죽는 것보다 답을 내는 편이 낫다
    // (§10이 *"항상 유효한 offset"*이라 정한 것과 같은 결).
    // **값을 못 박는다.** `off <= 3`은 이 인자에서 **항진명제**였다 — 모든 반환 경로가 `≤ bytes.len`
    // 이라 어떤 답이든 통과했고, 행 끝 반환을 `start_byte`로 바꾼 뮤턴트(3→0)를 못 잡았다(11차
    // 적대적 검증). `screen_col0`이 줄 전체보다 뒤라 걸음이 한 칸도 못 서고 행 끝으로 나가므로 3이다.
    const off = byteAtPoint("abc", 4, 0, 0, 5, 10, 4, 8);
    try std.testing.expectEqual(@as(usize, 3), off);
}

// **계측 자신을 먼저 잰다.** 이 카운터가 안 오르면 그것을 쓰는 게이트가 전부 **거짓 초록**이 된다 —
// 실제로 그런 일이 있었다: 앵커 문자열이 이 파일에 세 번 나오는데 첫 번째(`splitsWhenStraddling`)에
// 계측이 들어가, 빠른 경로를 막는 뮤턴트에서 시간은 28ms→1825ms로 튀는데 카운터는 0이었다. 그때
// "카운터로는 못 잡는다"고 결론낼 뻔했다(적대적 검증 규율: 검증 도구부터 검증한다).
test "stepColumn 계측이 두 경로를 갈라 센다" {
    const line = "\t\tconst result = try computeSomething(a, b);";

    // 탭 + 출력 가능한 ASCII만 — 빠른 경로로만 걷는다.
    total_steps = 0;
    slow_path_steps = 0;
    _ = lineColumnsUpTo(line, 4, 1000);
    try std.testing.expectEqual(line.len, total_steps); // 한 바이트에 한 걸음
    try std.testing.expectEqual(@as(usize, 0), slow_path_steps);

    // 한글 한 글자를 섞으면 그 자리만 느린 경로다 — 위가 "항상 0"이 아니라는 대조군.
    total_steps = 0;
    slow_path_steps = 0;
    _ = lineColumnsUpTo("ab한cd", 4, 1000);
    try std.testing.expect(slow_path_steps > 0);
    try std.testing.expect(slow_path_steps < total_steps);
}

test "왕복 불변식 ①: 보이는 offset은 왕복한다 — 실제 페인트 경로로 (§4.1g)" {
    // **계약이 "지금 검증할 수 없다"고 적어 둔 불변식이다**(§4.1g: *"`caretRect`(정방향)는 아직
    // 없다 — 커서가 생기는 N2의 일이고, 그래서 왕복 불변식 ①②는 지금 검증할 수 없다"*).
    //
    // **정방향을 새로 짓지 않는다.** `columnsAtOffsets`가 이미 "이 byte는 몇 열인가"를 답하고
    // `paintRowMarks`가 그것으로 x를 낸다 — caret도 같은 길을 타야 §5.4의 "view와 hitTest가 하나의
    // 픽셀-레이아웃 소스를 공유한다"가 지켜진다. 처음에 `caretSpan`이라는 정방향 함수를 따로
    // 지었다가 **같은 걸음을 두 번 걷는 두 번째 출처**임을 깨닫고 걷어냈다.
    //
    // 왕복은 **정방향에서만** 성립한다: 가려지지 않은 offset은 화면에 자기 자리가 정확히 하나 있고
    // 그 자리를 다시 물으면 자신이 나온다. 역방향은 clamp라 여럿이 하나로 간다(불변식 ③).
    const cases = [_][]const u8{
        "hello world",
        "\ttabbed\ttext",
        "한글과 ascii 섞임",
        "emoji 🙂 mid",
        "a\tb\tc",
    };
    const cell_w: u16 = 8;
    for (cases) |bytes| {
        for ([_]u16{ 2, 4, 8 }) |tab| {
            const row_cols: u32 = 400; // 줄이 통째로 한 행에 들어간다
            var off: u32 = 0;
            while (off <= bytes.len) : (off += 1) {
                // ① 정방향: byte → 열 → 픽셀 (paintRowMarks와 같은 산술)
                var one = [_]u32{off};
                var col_out = [_]u32{0};
                content_columnsAtOffsets(bytes, tab, &one, &col_out, row_cols);
                const x_px: i32 = @intCast(col_out[0] * cell_w);

                // ② 역방향: 픽셀 → byte
                const back = byteAtPoint(bytes, tab, 0, 0, 0, row_cols, x_px, cell_w);

                // ③ 왕복: 되돌아온 offset의 열이 같아야 한다. **byte가 아니라 열로 비교한다** —
                //    cluster 중간을 가리키는 offset은 같은 자리를 뜻하는 다른 byte로 접히고,
                //    그것은 clamp가 아니라 §3.1의 offset이 byte 축이라서 생기는 동치다.
                var back_one = [_]u32{@intCast(back)};
                var back_col = [_]u32{0};
                content_columnsAtOffsets(bytes, tab, &back_one, &back_col, row_cols);
                try std.testing.expectEqual(col_out[0], back_col[0]);
            }
        }
    }
}

/// 위 판정자가 쓰는 얇은 감쌈 — `columnsAtOffsets`는 `[]align(1)`을 받는다.
fn content_columnsAtOffsets(bytes: []const u8, tab: u16, offsets: []u32, out: []u32, stop_col: u32) void {
    columnsAtOffsets(bytes, tab, offsets, out, stop_col);
}

// ── 구문 강조 색 분할(§5.3) ────────────────────────────────────────────────────

/// run 묶음의 글자를 이어 붙인다. **어떤 분할이든 원본과 같아야 한다** — 색을 넣다가 글자를
/// 잃거나 겹치는 것이 이 층에서 가장 나쁜 회귀이고, 화면에서는 "글자가 사라졌다"로 보인다.
fn joinRuns(out: []u8, rs: []const draw.Run) []const u8 {
    var n: usize = 0;
    for (rs) |r| {
        @memcpy(out[n .. n + r.text.len], r.text);
        n += r.text.len;
    }
    return out[0..n];
}

test "HL10 색 구간이 없으면 run 하나 — 흔한 경로가 안 느려진다" {
    var rs: [8]draw.Run = undefined;
    const n = writeRuns("const x = 1;", 0, &.{}, &rs);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("const x = 1;", rs[0].text);
    // 역할이 없어야 op 의 본문색이 그대로 쓰인다(`run.role orelse text.role`).
    try testing.expectEqual(@as(?tokens.ColorRole, null), rs[0].role);
}

test "HL11 색 경계에서 쪼개지고, 이어 붙이면 원본이다" {
    const text = "const x = 1;";
    const colors = [_]ColorSpan{
        .{ .start_col = 0, .end_col = 5, .role = .syntax_keyword }, // const
        .{ .start_col = 10, .end_col = 11, .role = .syntax_number }, // 1
    };
    var rs: [16]draw.Run = undefined;
    const n = writeRuns(text, 0, &colors, &rs);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(text, joinRuns(&buf, rs[0..n]));

    // 첫 run 은 키워드, 그 다음은 무색, 숫자 자리에서 다시 색이 붙는다.
    try testing.expectEqualStrings("const", rs[0].text);
    try testing.expectEqual(tokens.ColorRole.syntax_keyword, rs[0].role.?);
    try testing.expectEqual(@as(?tokens.ColorRole, null), rs[1].role);
    var saw_number = false;
    for (rs[0..n]) |r| {
        if (r.role) |role| if (role == .syntax_number) {
            try testing.expectEqualStrings("1", r.text);
            saw_number = true;
        };
    }
    try testing.expect(saw_number);
}

test "HL12 2칸 글자에서 경계가 안 밀린다 — 글자 수가 아니라 열로 센다" {
    // 한글은 한 글자가 **두 열**이다. 열 대신 글자 수로 세면 경계가 오른쪽으로 밀리고, 그
    // 어긋남은 크래시 없이 화면에만 나온다(이 파일이 반복해서 적어 둔 함정).
    const text = "가나ab"; // 열: 가=0..2, 나=2..4, a=4, b=5
    const colors = [_]ColorSpan{.{ .start_col = 2, .end_col = 5, .role = .syntax_string }};
    var rs: [16]draw.Run = undefined;
    const n = writeRuns(text, 0, &colors, &rs);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(text, joinRuns(&buf, rs[0..n]));

    try testing.expectEqualStrings("가", rs[0].text);
    try testing.expectEqual(@as(?tokens.ColorRole, null), rs[0].role);
    try testing.expectEqualStrings("나a", rs[1].text); // 열 2~4 가 '나', 4 가 'a'
    try testing.expectEqual(tokens.ColorRole.syntax_string, rs[1].role.?);
    try testing.expectEqualStrings("b", rs[2].text);
    try testing.expectEqual(@as(?tokens.ColorRole, null), rs[2].role);
}

test "HL13 시작 열이 0이 아니어도 맞는다 — 가로 스크롤·랩된 조각" {
    // 조각은 줄 머리에서 시작하지 않는다(`first_col`·랩). 시작 열을 안 넘기면 그 조각 전체의
    // 색이 왼쪽으로 밀린다.
    const text = "x = 1;"; // 이 조각이 논리 열 6 에서 시작한다고 하자
    const colors = [_]ColorSpan{.{ .start_col = 10, .end_col = 11, .role = .syntax_number }};
    var rs: [16]draw.Run = undefined;
    const n = writeRuns(text, 6, &colors, &rs);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(text, joinRuns(&buf, rs[0..n]));
    var colored: []const u8 = "";
    for (rs[0..n]) |r| if (r.role != null) {
        colored = r.text;
    };
    try testing.expectEqualStrings("1", colored);
}

test "HL14 run 예산이 모자라도 글자를 잃지 않는다" {
    // 색 구간이 많으면 run 이 그만큼 늘어난다. 예산이 다했을 때 **남은 글자를 버리면** 줄 끝이
    // 사라지는데, 그것은 scratch·op 예산에서 이 파일이 내린 판단(줄이지 화면을 지우지 않는다)과
    // 어긋난다.
    const text = "abcdef";
    const colors = [_]ColorSpan{
        .{ .start_col = 0, .end_col = 1, .role = .syntax_keyword },
        .{ .start_col = 2, .end_col = 3, .role = .syntax_string },
        .{ .start_col = 4, .end_col = 5, .role = .syntax_number },
    };
    var rs: [2]draw.Run = undefined; // 일부러 모자라게
    const n = writeRuns(text, 0, &colors, &rs);
    try testing.expect(n <= rs.len);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(text, joinRuns(&buf, rs[0..n]));
}

test "HL15 build 를 지나도 색이 붙는다 — 탭 전개 뒤에도 경계가 글자에 선다" {
    // 위 판정자들은 `writeRuns`만 본다. 실제 경로는 **탭을 전개한 뒤** 그것을 부르므로, 탭이
    // 있는 줄에서 경계가 맞는지는 `build`를 지나야 확인된다.
    //
    // `\tab` → 전개하면 `    ab`(탭 폭 4). 논리 열은 탭이 0..4, a=4, b=5.
    const colors = [_]ColorSpan{.{ .start_col = 4, .end_col = 5, .role = .syntax_keyword }};
    var rows = [_]Row{.{ .bytes = "\tab", .colors = &colors }};
    var ops: [4]draw.Op = undefined;
    var scratch: [128]u8 = undefined;
    var runs: [8]draw.Run = undefined;

    const w = build(.{
        .layout = geometry.compute(40, 1, .{}),
        .rows = &rows,
        .cell_w_px = 8,
        .cell_h_px = 16,
        .font_px = 13,
        .origin_px = .{ .x = 0, .y = 0 },
    }, &ops, &scratch, &runs, &test_visual);

    try testing.expectEqual(@as(usize, 1), w.ops);
    try testing.expect(w.runs >= 2); // 색 경계가 있으니 한 run 으로 안 끝난다

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("    ab", joinRuns(&buf, runs[0..w.runs]));

    var colored: []const u8 = "";
    for (runs[0..w.runs]) |r| if (r.role) |role| {
        try testing.expectEqual(tokens.ColorRole.syntax_keyword, role);
        colored = r.text;
    };
    // 탭이 4열을 먹었으므로 열 4 는 `a`다. 전개를 안 세면 여기가 공백이 된다.
    try testing.expectEqualStrings("a", colored);
}

test "HL16 줄 끝 토큰의 색도 실린다 — 꼬리 run 이 무색이 되지 않는다" {
    // **앞의 판정자들은 줄 앞쪽만 본다.** `HL11`은 첫 run 과 숫자 자리를 보고 `HL12`·`HL13`도
    // 가운데를 본다 — 그래서 **꼬리 run 의 역할을 버리는** 뮤턴트가 살아남았다(적대적 검증).
    // 줄의 마지막 토큰이 무색이 되는 것은 화면에서 바로 보이는 결함이다.
    const text = "x = 1;";
    const colors = [_]ColorSpan{
        .{ .start_col = 0, .end_col = 1, .role = .syntax_property },
        // **마지막 열까지 덮는다** — 꼬리가 색 구간 안에서 끝나야 그 run 이 역할을 갖는다.
        .{ .start_col = 4, .end_col = 6, .role = .syntax_number },
    };
    var rs: [16]draw.Run = undefined;
    const n = writeRuns(text, 0, &colors, &rs);

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(text, joinRuns(&buf, rs[0..n]));

    // **마지막 run** 이 색을 갖고 줄 끝 글자를 담아야 한다.
    const last = rs[n - 1];
    try testing.expectEqual(tokens.ColorRole.syntax_number, last.role.?);
    try testing.expectEqualStrings("1;", last.text);
}
