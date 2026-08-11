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
const chrome = @import("../../../chrome.zig");
const geometry = @import("geometry.zig");
const text_layout = @import("../../text_layout.zig"); // 텍스트 셀 배치 단일 출처(cluster 분절·폭)
const display_width = @import("../../../display_width.zig"); // §4.2 표시 폭 — 셀 배치(system_text)와 같은 규칙
const hazard = @import("../../../hazard.zig"); // §3.8 적대적 입력 판정 — 순수 유니코드(레이어 무관 중립)
const visual_map = @import("visual_map.zig"); // §4 세로 축 — 전개된 줄을 시각 행으로 나눈다

const draw = chrome.draw;
const tokens = chrome.tokens;

/// 그릴 **논리 줄** 하나. `bytes`는 **줄바꿈을 뺀 내용**이며 문서 버퍼를 빌려 쓴다(복사하지 않는다).
///
/// **시각 행 인덱스를 담지 않는다.** 랩이 켜지면 이 줄이 시각 행 몇 개가 될지는 전개해서 나눠 봐야
/// 알 수 있으므로(`visual_map` 참고) 호출자가 미리 정할 수 없다. 배치는 `build`가 정해 `visual_out`에
/// 돌려주고 gutter가 그것을 따른다.
pub const Row = struct {
    bytes: []const u8,
};

pub const Props = struct {
    layout: geometry.Layout,
    rows: []const Row,
    /// 랩. 켜지면 논리 줄 하나가 본문 폭에서 접혀 시각 행 여럿이 된다(§4 세로 축).
    /// 꺼지면 줄이 본문 폭에서 잘리고 그 너머는 가로 스크롤로 본다 — **가로 스크롤은 아직 없다.**
    wrap: bool = false,
    cell_w_px: u16,
    cell_h_px: u16,
    /// 이 뷰의 폰트 크기(device px). 셀 크기와 **같은 폰트에서** 나와야 배치와 글자가 어긋나지 않는다.
    font_px: u16,
    origin_px: draw.Px,
    /// 탭 하나가 밀어내는 칸 수. 탭은 **고정 폭이 아니라 다음 탭스톱까지**다(§4 가로 축).
    tab_width: u16 = 4,
};

pub const text_role: tokens.ColorRole = .surface_fg;

/// gutter와 같은 이유로 각 저장소에서 쓴 양을 돌려준다(`gutter.Written` 참고).
pub const Written = struct {
    ops: usize,
    bytes: usize,
    runs: usize,
    /// `visual_out`에 채운 시각 행 수. 랩이 꺼지면 논리 줄 수와 같고, 켜지면 그보다 많을 수 있다.
    visual_rows: usize = 0,
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
) !Written {
    if (props.layout.content.isEmpty()) return .{ .ops = 0, .bytes = 0, .runs = 0, .visual_rows = 0 };

    var op_count: usize = 0;
    var scratch_used: usize = 0;
    var run_used: usize = 0;
    var visual_row: u16 = 0;

    const view_cols = props.layout.content.width;

    for (props.rows, 0..) |row, line_idx| {
        if (visual_row >= visual_out.len) break; // 화면이 찼다

        // **전개 상한은 앞으로 그릴 수 있는 행 수만큼이다.** 랩이 꺼지면 한 행(`view_cols`)이고,
        // 켜지면 남은 행을 다 채울 만큼(`남은 행 × view_cols`)이다. 어느 쪽이든 **화면 폭·높이에
        // 비례**하지 줄 길이에 비례하지 않는다 — 이 상한이 없으면 minified JS 한 줄이 scratch를
        // 삼켜 `build` 전체가 죽는다.
        const rows_left: usize = visual_out.len - visual_row;
        const budget_cols: usize = if (props.wrap) rows_left * @as(usize, view_cols) else view_cols;
        const expand_cols: u16 = @intCast(@min(budget_cols, std.math.maxInt(u16)));

        const r = expandTabs(row.bytes, props.tab_width, text_scratch[scratch_used..], expand_cols) catch
            return error.OutOfSpace;
        const expanded = r.text;
        // **탭이 없으면 scratch를 쓰지 않았다.** 그때도 길이를 더하면 저장소가 실제보다 빨리 차서
        // 아래쪽 줄이 근거 없이 OutOfSpace로 죽고, 호출자에게 보고하는 `bytes`도 과대해진다.
        scratch_used += r.scratch_used;

        var it = visual_map.pieces(expanded, view_cols, props.wrap);
        var piece_idx: u16 = 0;
        while (it.next()) |piece| : (piece_idx += 1) {
            if (visual_row >= visual_out.len) break;

            // **빈 조각도 시각 행을 차지한다.** 그릴 글자가 없어도 그 행은 화면에서 한 줄이고 gutter가
            // 번호를 그려야 한다 — op만 건너뛰고 행은 센다. 이걸 빼면 빈 줄 아래의 번호가 밀린다.
            visual_out[visual_row] = .{ .line = @intCast(line_idx), .piece = piece_idx };
            const text = piece.slice(expanded);
            defer visual_row += 1;
            if (text.len == 0) continue;

            if (run_used >= runs.len) return error.OutOfSpace;
            runs[run_used] = .{ .text = text };
            const run_slice = runs[run_used .. run_used + 1];
            run_used += 1;

            if (op_count >= out.len) return error.OutOfSpace;
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

    return .{ .ops = op_count, .bytes = scratch_used, .runs = run_used, .visual_rows = visual_row };
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
};

pub fn expandTabs(bytes: []const u8, tab_width: u16, out: []u8, max_cols: u16) !Expanded {
    // **판정에도 상한이 있어야 한다.** 탭·위험 문자가 없으면 원본을 빌려주는 최적화는 유지하되,
    // 그 판정을 **줄 전체가 아니라 화면에 닿을 만큼만** 본다. 초판은 상한이 없어 `indexOfScalar`와
    // `containsAny`(UTF-8 디코드)가 줄 끝까지 갔고, minified JS처럼 한 줄이 수 MB인 파일에서 매
    // 프레임 그만큼을 훑었다 — 화면엔 `max_cols`만 보이는데.
    //
    // 상한은 **열이 아니라 byte**로 잡는다. 열당 byte는 문자마다 달라(ASCII 1, 한글 1.5, 이모지 2)
    // 정확히 환산하려면 결국 훑어야 하므로, UTF-8 최대 4byte를 열마다 가정해 넉넉히 잡는다.
    // 결합 문자를 수백 개 붙인 적대적 입력에서는 이 범위가 `max_cols` 열을 못 채워 오른쪽이 빌 수
    // 있는데, 그것은 §3.8이 "초장문·극단 입력에서 기능을 줄인다"고 허용한 범위다.
    const scan_limit = utf8BoundaryAtMost(bytes, @as(usize, max_cols) * 4 + 8);
    const head = bytes[0..scan_limit];
    if (std.mem.indexOfScalar(u8, head, '\t') == null and !hazard.containsAny(head)) {
        return .{ .text = head, .scratch_used = 0 };
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
        if (col >= max_cols) break;
        if (bytes[i] == '\t') {
            const stop = ((col / stop_width) + 1) * stop_width;
            const pad = stop - col;
            if (used + pad > out.len) return error.OutOfSpace;
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
            while (cp_i < end) {
                const cp_len = @max(1, @min(std.unicode.utf8ByteSequenceLength(bytes[cp_i]) catch 1, end - cp_i));
                if (hazard.classifyInText(bytes, cp_i)) |_| {
                    const cp = std.unicode.utf8Decode(bytes[cp_i .. cp_i + cp_len]) catch 0xFFFD;
                    var mark: [hazard.max_display_len]u8 = undefined;
                    const shown = hazard.displayText(cp, &mark);
                    if (used + shown.len > out.len) return error.OutOfSpace;
                    @memcpy(out[used..][0..shown.len], shown);
                    used += shown.len;
                    // 표기가 차지하는 칸은 그 글자 수다 — 원래 codepoint의 폭(0일 수도 있다)이 아니다.
                    col += shown.len;
                } else {
                    if (used + cp_len > out.len) return error.OutOfSpace;
                    @memcpy(out[used..][0..cp_len], bytes[cp_i .. cp_i + cp_len]);
                    used += cp_len;
                    const cp = std.unicode.utf8Decode(bytes[cp_i .. cp_i + cp_len]) catch 0xFFFD;
                    col += text_layout.clusterCols(cp, null);
                }
                cp_i += cp_len;
            }
            i = end;
            continue;
        }

        if (used + n > out.len) return error.OutOfSpace;
        @memcpy(out[used..][0..n], bytes[i..][0..n]);
        used += n;
        // **cluster 전체를 넘긴다**(§4.2) — base 코드포인트만 보면 VS16(❤️)과 국기를 1칸으로 세어
        // 컬러 글리프가 절반 크기로 그려진다. 터미널의 `width.cellWidth`와 갈리는 지점이다.
        col += display_width.clusterCols(bytes, i, end);
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
    const r = try expandTabs("hello", 4, &out, test_max_cols);
    try testing.expectEqualStrings("hello", r.text);
    // 저장소를 쓰지 않았다 — 이 값을 길이로 추정하면 호출자의 회계가 어긋난다.
    try testing.expectEqual(@as(usize, 0), r.scratch_used);
}

test "expandTabs: 탭스톱까지 채운다 — 고정 폭이 아니다" {
    var out: [64]u8 = undefined;

    // 열 0의 탭은 4칸, 열 1의 탭은 3칸이다. 고정 4칸이면 둘 다 4가 되어 들여쓰기가 어긋난다.
    try testing.expectEqualStrings("    x", (try expandTabs("\tx", 4, &out, test_max_cols)).text);
    var out2: [64]u8 = undefined;
    try testing.expectEqualStrings("a   x", (try expandTabs("a\tx", 4, &out2, test_max_cols)).text);
    var out3: [64]u8 = undefined;
    try testing.expectEqualStrings("abc x", (try expandTabs("abc\tx", 4, &out3, test_max_cols)).text);
    var out4: [64]u8 = undefined;
    try testing.expectEqualStrings("abcd    x", (try expandTabs("abcd\tx", 4, &out4, test_max_cols)).text);
}

test "expandTabs: 연속 탭" {
    var out: [64]u8 = undefined;
    const r = try expandTabs("\t\tx", 4, &out, test_max_cols);
    try testing.expectEqualStrings("        x", r.text);
    try testing.expectEqual(@as(usize, 9), r.scratch_used); // 전개했으므로 길이만큼 썼다
}

test "expandTabs: 탭 폭 0은 1로 본다 — 0으로 나누지 않는다" {
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings(" x", (try expandTabs("\tx", 0, &out, test_max_cols)).text);
}

test "expandTabs: 한글은 두 칸이다 — 글자 수로 세면 정렬이 한 칸 어긋난다" {
    var out: [64]u8 = undefined;
    // "가"는 3 byte, 1글자, **2칸**이다. 탭은 열 2에서 시작하므로 다음 탭스톱(4)까지 2칸.
    // byte 수로 세면 3칸을 건너뛰고, 글자 수로 세면 3칸을 넣는다 — 둘 다 틀린다.
    const r = try expandTabs("가\tx", 4, &out, test_max_cols);
    try testing.expectEqualStrings("가  x", r.text);
}

test "expandTabs: 전각 둘이면 탭스톱을 이미 채운다" {
    var out: [64]u8 = undefined;
    // "가나"는 4칸이라 열 4 = 탭스톱 경계. 탭은 다음 스톱(8)까지 4칸을 넣는다.
    const r = try expandTabs("가나\tx", 4, &out, test_max_cols);
    try testing.expectEqualStrings("가나    x", r.text);
}

test "expandTabs: 결합 문자는 0칸이다" {
    var out: [64]u8 = undefined;
    // U+0301(combining acute)은 앞 글자에 붙으므로 열을 차지하지 않는다. "e" 1칸 + 결합 0칸 = 열 1.
    const r = try expandTabs("e\u{0301}\tx", 4, &out, test_max_cols);
    try testing.expectEqualStrings("e\u{0301}   x", r.text);
}

test "expandTabs: 잘린 UTF-8에서도 죽지 않는다 — 화면이 통째로 비면 안 된다" {
    var out: [64]u8 = undefined;
    // "가"의 첫 두 byte만. §3.5가 열 때 거부하므로 정상 경로엔 없지만 여기서 죽으면 안 된다.
    const r = try expandTabs("\xEA\xB0\tx", 4, &out, test_max_cols);
    try testing.expect(r.text.len > 0);
}

test "expandTabs: 저장소가 모자라면 실패한다" {
    var out: [2]u8 = undefined;
    try testing.expectError(error.OutOfSpace, expandTabs("\tabc", 4, &out, test_max_cols));
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
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

    try testing.expectEqual(@as(usize, 1), w.ops);
    // gutter 8셀 뒤에서 시작해야 한다(여백 1 + 번호 5 + 접기 1 + 여백 1).
    try testing.expectEqual(@as(i32, 8 * 8), ops[0].text.origin.x);
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
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

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
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

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
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

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
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

    // 줄 안에 `\n`이 있을 일은 없지만(줄 단위로 들어온다) 탭 전개만 확인한다.
    try testing.expect(std.mem.indexOfScalar(u8, ops[0].text.runs[0].text, '\t') == null);
}

test "본문 영역이 없으면 아무것도 그리지 않는다" {
    const layout = geometry.compute(5, 10, .{}); // gutter가 뷰보다 넓다
    const rows = [_]Row{.{ .bytes = "x" }};

    var ops: [4]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);
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
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

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
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

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
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs, &test_visual);

    try testing.expectEqual(@as(usize, 2), w.ops);
    try testing.expectEqual(@as(usize, 5), w.bytes); // 탭 있는 줄만 셌다
    try testing.expectEqualStrings("plain", ops[0].text.runs[0].text);
    try testing.expectEqualStrings("    x", ops[1].text.runs[0].text);
}

test "expandTabs: 여러 codepoint로 된 cluster도 한 단위로 센다" {
    var out: [64]u8 = undefined;
    // "e" + U+0301(결합 악센트)는 cluster 하나이고 1칸이다. codepoint로 세면 2칸이 되어
    // 탭이 한 칸 덜 들어간다.
    const r = try expandTabs("e\u{0301}\tx", 4, &out, test_max_cols);
    try testing.expectEqualStrings("e\u{0301}   x", r.text);
}

test "expandTabs: 지역표시자 국기는 한 cluster다" {
    var out: [64]u8 = undefined;
    // U+1F1F0 U+1F1F7(KR)은 codepoint 둘이지만 화면에서 한 cluster(2칸)다.
    // codepoint로 세면 4칸으로 계산돼 탭 위치가 어긋난다.
    const r = try expandTabs("\u{1F1F0}\u{1F1F7}\tx", 4, &out, test_max_cols);
    try testing.expectEqualStrings("\u{1F1F0}\u{1F1F7}  x", r.text);
}

test "expandTabs: BiDi 제어 문자를 보이는 표기로 바꾼다 — Trojan Source 방어" {
    var out: [128]u8 = undefined;
    // U+202E(RLO)는 폭 0이라 보이지 않으면서 뒤 텍스트를 역순으로 보이게 한다.
    const r = try expandTabs("// \u{202E}x", 4, &out, test_max_cols);
    try testing.expectEqualStrings("// <U+202E>x", r.text);
}

test "expandTabs: 제어 문자도 보이게 한다 — 편집기에 온 ESC는 파일의 바이트다" {
    var out: [128]u8 = undefined;
    const r = try expandTabs("a\x1bb", 4, &out, test_max_cols);
    try testing.expectEqualStrings("a<U+001B>b", r.text);
}

test "expandTabs: 위험 문자만 있고 탭이 없어도 전개된다" {
    var out: [128]u8 = undefined;
    // 탭 유무로만 판단하면 이 줄이 원본 그대로 나가 숨은 문자가 안 보인다.
    const r = try expandTabs("\u{200B}", 4, &out, test_max_cols);
    try testing.expectEqualStrings("<U+200B>", r.text);
    try testing.expect(r.scratch_used > 0);
}

test "expandTabs: 표기 폭이 열 계산에 반영된다 — 뒤따르는 탭이 어긋나지 않는다" {
    var out: [128]u8 = undefined;
    // "<U+200B>"는 8칸이다. 그 뒤 탭은 열 8에서 시작하므로 다음 탭스톱(12)까지 4칸.
    const r = try expandTabs("\u{200B}\tx", 4, &out, test_max_cols);
    try testing.expectEqualStrings("<U+200B>    x", r.text);
}

test "expandTabs: 평범한 줄은 여전히 원본을 빌려준다 — 저장소를 쓰지 않는다" {
    var out: [8]u8 = undefined;
    const r = try expandTabs("const x = 1;", 4, &out, test_max_cols);
    try testing.expectEqualStrings("const x = 1;", r.text);
    try testing.expectEqual(@as(usize, 0), r.scratch_used);
}

test "expandTabs: cluster 안에 묻힌 ZWJ도 드러낸다 — GB9가 앞 글자에 흡수한다" {
    var out: [128]u8 = undefined;
    // `ad<ZWJ>min`은 화면에서 `admin`과 같아 보인다. UAX#29가 ZWJ를 `d`의 cluster로 흡수하므로
    // cluster 단위로만 훑으면 이 문자를 놓친다.
    const r = try expandTabs("ad\u{200D}min", 4, &out, test_max_cols);
    try testing.expectEqualStrings("ad<U+200D>min", r.text);
}

test "expandTabs: 이모지 가족은 그대로 둔다 — 정상 ZWJ까지 표기로 바꾸면 안 된다" {
    var out: [128]u8 = undefined;
    const family = "\u{1F468}\u{200D}\u{1F469}";
    const r = try expandTabs(family, 4, &out, test_max_cols);
    try testing.expectEqualStrings(family, r.text);
}

test "긴 줄은 화면 폭에서 멈춘다 — 비용이 줄 길이가 아니라 화면 폭에 비례한다" {
    // minified JS처럼 한 줄이 아주 긴 파일이 실제로 있다(§3.8 "초장문 단일 줄"). 상한이 없으면
    // 매 프레임 줄 전체를 훑었다 — 화면엔 `max_cols`만 보이는데.
    var long: [4096]u8 = undefined;
    @memset(&long, 'a');
    long[0] = '\t'; // 탭이 있어야 전개 경로로 간다(없으면 열 계산만 하고 지나간다)

    var out: [64]u8 = undefined;
    const r = try expandTabs(&long, 4, &out, 16);
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

    const w = try build(.{
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
    const r = try expandTabs("a\tb", 4, &out, 80);
    try testing.expectEqualStrings("a   b", r.text);
}

test "판정도 상한까지만 훑는다 — 긴 줄에서 비용이 줄 길이에 비례하지 않는다" {
    // 탭·위험 문자가 **없는** 긴 줄. 초판은 이 경우 원본을 빌려주되 그 판정에 줄 전체를 훑었다.
    var long: [8192]u8 = undefined;
    @memset(&long, 'a');
    var out: [8]u8 = undefined;

    const r = try expandTabs(&long, 4, &out, 20);
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

    const r = try expandTabs(buf[0..i], 4, &out, 10);
    // 3의 배수여야 한글 경계에서 잘린 것이다.
    try testing.expectEqual(@as(usize, 0), r.text.len % 3);
    try testing.expect(std.unicode.utf8ValidateSlice(r.text));
}
