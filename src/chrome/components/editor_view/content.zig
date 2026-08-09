//! 편집기 **본문 텍스트**를 draw op으로 낸다 — gutter 오른쪽에 파일 내용을 그리는 부분.
//!
//! 자리는 [geometry.zig](geometry.zig)의 `content` 영역이고(§4.1), 텍스트 경로는 **셀**이다
//! ([native-editor.md](../../../../docs/native-editor.md) §2.0) — 등폭 고정이 세로 정렬·블록 선택·
//! goal column의 전제이므로 measured 경로를 쓰지 않는다.
//!
//! **N1 범위**: 랩·접힘·가상 텍스트가 없다. 그래서 시각 행 하나가 논리 줄 하나에 대응하고, §4의
//! 세로 축 변환이 항등이다. 그 단계들이 붙을 자리는 §4가 이미 정의해 두었으므로 여기서는 **입력을
//! `Row` 배열로 받아** 나중에 시각 매핑 결과를 그대로 끼울 수 있게 한다(gutter가 같은 방식이다).

const std = @import("std");
const chrome = @import("../../../chrome.zig");
const geometry = @import("geometry.zig");

const draw = chrome.draw;
const tokens = chrome.tokens;

/// 그릴 줄 하나. `bytes`는 **줄바꿈을 뺀 내용**이며 문서 버퍼를 빌려 쓴다(복사하지 않는다).
pub const Row = struct {
    bytes: []const u8,
    /// 이 줄이 그려질 시각 행 인덱스(뷰포트 기준 0부터).
    visual_row: u16,
};

pub const Props = struct {
    layout: geometry.Layout,
    rows: []const Row,
    cell_w_px: u16,
    cell_h_px: u16,
    origin_px: draw.Px,
    /// 탭 하나가 밀어내는 칸 수. 탭은 **고정 폭이 아니라 다음 탭스톱까지**다(§4 가로 축).
    tab_width: u16 = 4,
    /// 가로 스크롤 오프셋(셀). N1에서는 항상 0이지만 구조를 미리 둔다 — §1.1이 가로 스크롤을
    /// 기본으로 정했고, 나중에 얹으면 이 함수의 자르기 규칙을 다시 짜야 한다.
    scroll_cols: u16 = 0,
};

pub const text_role: tokens.ColorRole = .surface_fg;

/// 본문 draw op을 채우고 쓴 개수를 돌려준다. **할당하지 않는다.**
///
/// 탭은 **공백으로 전개해서** 넘긴다. 셀 경로가 `\t`를 그리면 폰트에 없는 글리프가 되거나 한 칸으로
/// 뭉개져 들여쓰기가 무너진다. 전개는 여기서 하고 렌더러는 완성된 문자열만 받는다.
///
/// 전개는 **탭스톱 기준**이다 — `tab_width`만큼 무조건 넣는 것이 아니라 다음 배수까지 채운다.
/// `a\tb`에서 탭이 3칸이고 `ab\tc`에서 2칸인 것이 그 차이이며, 이걸 틀리면 코드 들여쓰기가 어긋난다.
pub fn build(props: Props, out: []draw.Op, text_scratch: []u8, runs: []draw.Run) !usize {
    if (props.layout.content.isEmpty()) return 0;

    var op_count: usize = 0;
    var scratch_used: usize = 0;
    var run_used: usize = 0;

    for (props.rows) |row| {
        const expanded = expandTabs(row.bytes, props.tab_width, text_scratch[scratch_used..]) catch
            return error.OutOfSpace;
        scratch_used += expanded.len;

        // 빈 줄은 op을 만들지 않는다 — 그릴 것이 없는데 op을 내면 프레임 예산만 먹는다.
        if (expanded.len == 0) continue;

        if (run_used >= runs.len) return error.OutOfSpace;
        runs[run_used] = .{ .text = expanded };
        const run_slice = runs[run_used .. run_used + 1];
        run_used += 1;

        if (op_count >= out.len) return error.OutOfSpace;
        out[op_count] = .{ .text = .{
            .origin = .{
                .x = props.origin_px.x +
                    @as(i32, props.layout.content.start) * @as(i32, props.cell_w_px),
                .y = props.origin_px.y + @as(i32, row.visual_row) * @as(i32, props.cell_h_px),
            },
            .runs = run_slice,
            .role = text_role,
            // 본문 영역을 넘는 글자는 자른다. 이것이 없으면 긴 줄이 gutter 옆 창 밖까지 그려진다.
            .max_cols = props.layout.content.width,
        } };
        op_count += 1;
    }

    return op_count;
}

/// 탭을 다음 탭스톱까지의 공백으로 편다.
///
/// **UTF-8을 해석하지 않는다.** 탭스톱은 화면 열 기준이고 다중 byte 문자는 열 수가 byte 수와 다르지만,
/// N1에서는 그 차이가 탭 정렬에만 영향을 준다. 정확한 열 계산은 §4의 폭 합(L2 캐시)이 붙을 때
/// 함께 온다 — 지금 어설픈 근사를 넣으면 나중에 두 곳을 고쳐야 한다. **ASCII 들여쓰기는 정확하고**,
/// 그것이 코드 파일에서 탭이 쓰이는 거의 모든 경우다.
pub fn expandTabs(bytes: []const u8, tab_width: u16, out: []u8) ![]u8 {
    // 탭이 없으면 원본을 그대로 빌려준다 — 복사도 저장소도 쓰지 않는다(흔한 경우다).
    if (std.mem.indexOfScalar(u8, bytes, '\t') == null) return @constCast(bytes);

    const width = if (tab_width == 0) 1 else tab_width;
    var used: usize = 0;
    var col: usize = 0;

    for (bytes) |b| {
        if (b == '\t') {
            const stop = ((col / width) + 1) * width;
            const pad = stop - col;
            if (used + pad > out.len) return error.OutOfSpace;
            @memset(out[used..][0..pad], ' ');
            used += pad;
            col = stop;
        } else {
            if (used + 1 > out.len) return error.OutOfSpace;
            out[used] = b;
            used += 1;
            // continuation byte(0b10xxxxxx)는 새 글자가 아니므로 열을 세지 않는다. 이것만으로도
            // 한글이 섞인 줄의 탭 정렬이 byte 수 기준보다 훨씬 낫다.
            if (b & 0xC0 != 0x80) col += 1;
        }
    }
    return out[0..used];
}

/// 뷰포트에 보이는 줄들을 본문 행으로 편다. 랩·접힘이 없는 N1 경로다(gutter의 `rowsForRange`와 짝).
///
/// `line_at`은 0-based 논리 줄 번호로 그 줄의 내용을 돌려주는 함수다 — 이 모듈이 `LineIndex`를
/// import하지 않기 위해 콜백으로 받는다. chrome은 session을 props로만 읽는다는 레이어 규약이다.
pub fn rowsForRange(
    ctx: anytype,
    line_at: fn (@TypeOf(ctx), usize) ?[]const u8,
    first_line: usize,
    count: u16,
    out: []Row,
) []Row {
    const n = @min(count, out.len);
    var written: u16 = 0;
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const bytes = line_at(ctx, first_line + i) orelse break; // 문서 끝을 넘었다
        out[written] = .{ .bytes = bytes, .visual_row = i };
        written += 1;
    }
    return out[0..written];
}

const testing = std.testing;

test "expandTabs: 탭이 없으면 원본을 그대로 빌려준다" {
    var out: [32]u8 = undefined;
    const r = try expandTabs("hello", 4, &out);
    try testing.expectEqualStrings("hello", r);
}

test "expandTabs: 탭스톱까지 채운다 — 고정 폭이 아니다" {
    var out: [64]u8 = undefined;

    // 열 0의 탭은 4칸, 열 1의 탭은 3칸이다. 고정 4칸이면 둘 다 4가 되어 들여쓰기가 어긋난다.
    try testing.expectEqualStrings("    x", try expandTabs("\tx", 4, &out));
    var out2: [64]u8 = undefined;
    try testing.expectEqualStrings("a   x", try expandTabs("a\tx", 4, &out2));
    var out3: [64]u8 = undefined;
    try testing.expectEqualStrings("abc x", try expandTabs("abc\tx", 4, &out3));
    var out4: [64]u8 = undefined;
    try testing.expectEqualStrings("abcd    x", try expandTabs("abcd\tx", 4, &out4));
}

test "expandTabs: 연속 탭" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("        x", try expandTabs("\t\tx", 4, &out));
}

test "expandTabs: 탭 폭 0은 1로 본다 — 0으로 나누지 않는다" {
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings(" x", try expandTabs("\tx", 0, &out));
}

test "expandTabs: UTF-8 continuation byte는 열로 세지 않는다" {
    var out: [64]u8 = undefined;
    // "가"는 3 byte지만 글자 하나다. byte 수로 세면 탭이 열 3에서 시작해 1칸만 나오는데,
    // 글자 수로 세면 열 1이라 3칸이 나온다.
    const r = try expandTabs("가\tx", 4, &out);
    try testing.expectEqualStrings("가   x", r);
}

test "expandTabs: 저장소가 모자라면 실패한다" {
    var out: [2]u8 = undefined;
    try testing.expectError(error.OutOfSpace, expandTabs("\tabc", 4, &out));
}

fn testProps(layout: geometry.Layout, rows: []const Row) Props {
    return .{
        .layout = layout,
        .rows = rows,
        .cell_w_px = 8,
        .cell_h_px = 16,
        .origin_px = .{ .x = 0, .y = 0 },
    };
}

test "본문은 gutter 오른쪽에서 시작한다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{.{ .bytes = "const x = 1;", .visual_row = 0 }};

    var ops: [4]draw.Op = undefined;
    var scratch: [128]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    const n = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqual(@as(usize, 1), n);
    // gutter 8셀 뒤에서 시작해야 한다(여백 1 + 번호 5 + 접기 1 + 여백 1).
    try testing.expectEqual(@as(i32, 8 * 8), ops[0].text.origin.x);
    try testing.expectEqualStrings("const x = 1;", ops[0].text.runs[0].text);
}

test "행 간격이 gutter와 같다 — 줄 번호와 본문이 나란히 서야 한다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .bytes = "a", .visual_row = 0 },
        .{ .bytes = "b", .visual_row = 1 },
        .{ .bytes = "c", .visual_row = 2 },
    };

    var ops: [8]draw.Op = undefined;
    var scratch: [128]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqual(@as(i32, 0), ops[0].text.origin.y);
    try testing.expectEqual(@as(i32, 16), ops[1].text.origin.y);
    try testing.expectEqual(@as(i32, 32), ops[2].text.origin.y);
}

test "본문 폭을 넘는 줄은 max_cols로 잘린다 — 창 밖까지 그리지 않는다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{.{ .bytes = "x", .visual_row = 0 }};

    var ops: [4]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqual(layout.content.width, ops[0].text.max_cols);
}

test "빈 줄은 op을 만들지 않는다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .bytes = "a", .visual_row = 0 },
        .{ .bytes = "", .visual_row = 1 },
        .{ .bytes = "c", .visual_row = 2 },
    };

    var ops: [8]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    const n = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqual(@as(usize, 2), n);
    // 세 번째 줄은 시각 행 2를 유지해야 한다 — 빈 줄을 건너뛰었다고 위로 당겨지면 안 된다.
    try testing.expectEqual(@as(i32, 32), ops[1].text.origin.y);
}

test "탭이 든 줄은 전개돼 그려진다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{.{ .bytes = "if x:\n\treturn", .visual_row = 0 }};

    var ops: [4]draw.Op = undefined;
    var scratch: [128]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    // 줄 안에 `\n`이 있을 일은 없지만(줄 단위로 들어온다) 탭 전개만 확인한다.
    try testing.expect(std.mem.indexOfScalar(u8, ops[0].text.runs[0].text, '\t') == null);
}

test "본문 영역이 없으면 아무것도 그리지 않는다" {
    const layout = geometry.compute(5, 10, .{}); // gutter가 뷰보다 넓다
    const rows = [_]Row{.{ .bytes = "x", .visual_row = 0 }};

    var ops: [4]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    try testing.expectEqual(@as(usize, 0), try build(testProps(layout, &rows), &ops, &scratch, &runs));
}

test "각 op이 자기 run을 가리킨다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .bytes = "first", .visual_row = 0 },
        .{ .bytes = "second", .visual_row = 1 },
    };

    var ops: [4]draw.Op = undefined;
    var scratch: [128]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqualStrings("first", ops[0].text.runs[0].text);
    try testing.expectEqualStrings("second", ops[1].text.runs[0].text);
}
