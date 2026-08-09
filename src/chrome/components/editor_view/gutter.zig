//! gutter에 **무엇을 그리는가** — 줄 번호와 줄 단위 표식.
//!
//! 어디에 그리는지는 [geometry.zig](geometry.zig)가 답한다(§4.1). 두 파일을 가르는 이유는 그리기와
//! hit-test가 같은 레이아웃 소스를 공유해야 하기 때문이다([chrome-strategy.md](../../../../docs/chrome-strategy.md) §5.4) —
//! 레이아웃을 여기 두면 hit-test가 그것을 복제하게 된다.
//!
//! **텍스트는 셀 경로다.** 줄 번호는 본문과 같은 등폭 격자에 서므로 measured 경로를 쓰지 않는다
//! ([native-editor.md](../../../../docs/native-editor.md) §2.0) — 본문 줄과 1:1로 세로 정렬돼야 하고,
//! 편집기 폰트 크기를 키우면 함께 커져야 한다.

const std = @import("std");
const chrome = @import("../../../chrome.zig");
const geometry = @import("geometry.zig");

const draw = chrome.draw;
const tokens = chrome.tokens;

/// 한 줄이 gutter에 요구하는 것. 본문 행 하나에 대응한다.
///
/// **랩이 켜지면 한 논리 줄이 여러 시각 행이 되지만 번호는 첫 행에만 붙는다**(§4). 그래서 `number`가
/// optional이다 — 이어지는 랩 행은 번호 없이 자리만 차지한다.
pub const Row = struct {
    /// 1-based 줄 번호. 랩으로 이어진 행이면 null.
    number: ?usize,
    /// 이 행이 그려질 시각 행 인덱스(뷰포트 기준 0부터).
    visual_row: u16,
};

/// gutter가 그려질 자리와 무엇을 켤지.
pub const Props = struct {
    layout: geometry.Layout,
    rows: []const Row,
    /// 셀 하나의 픽셀 크기. 셀 좌표를 draw op의 픽셀 좌표로 바꾸는 데만 쓴다.
    cell_w_px: u16,
    cell_h_px: u16,
    /// 이 뷰의 폰트 크기(device px). 셀 크기와 **같은 폰트에서** 나와야 배치와 글자가 어긋나지 않는다.
    font_px: u16,
    /// 편집기 뷰의 좌상단 픽셀 원점. 뷰가 창 안 어디에 있든 gutter는 그 기준으로 그려진다.
    origin_px: draw.Px,
};

/// 줄 번호 색. 본문보다 흐리게 둔다 — 주요 편집기가 줄 번호를 눈에 덜 띄게 만드는 방식이 **크기가
/// 아니라 색**이고(§4.1), 셀 경로에서는 색이 셀마다 이미 있어 공짜다.
pub const line_number_role: tokens.ColorRole = .muted_fg;

/// 줄 번호를 담는 최대 자릿수. `usize`를 십진으로 찍을 때 필요한 상한이며, 이보다 긴 문서는 없다.
const max_digits = 20;

/// 이 호출이 각 저장소에서 **실제로 쓴 양**. 호출자가 그다음 소비자에게 남은 자리를 넘길 때 쓴다.
///
/// 개수를 돌려주지 않고 호출자가 다시 계산하게 두면 그 계산이 이 함수의 내부 규칙(랩 행은 건너뛴다,
/// 자릿수만큼 쓴다)을 복제하게 되고, 여기가 바뀌면 조용히 어긋난다. 실제로 Lab이 그렇게 짜여 있었다.
pub const Written = struct {
    ops: usize,
    bytes: usize,
    runs: usize,
};

/// gutter draw op을 `out`에 채우고 각 저장소에서 쓴 양을 돌려준다.
///
/// **할당하지 않는다.** 호출자가 준 저장소만 쓰며, 모자라면 `error.OutOfSpace`로 **fail-close**한다 —
/// 조용히 잘라 내면 아래쪽 줄 번호가 사라진 채 캡처가 통과한다.
///
/// 줄 번호는 **우측 정렬**이다(Monaco와 같다). 자릿수가 다른 줄이 좌측 정렬되면 본문과의 간격이
/// 줄마다 달라져 읽기 흐름이 끊긴다.
pub fn build(props: Props, out: []draw.Op, text_scratch: []u8, runs: []draw.Run) !Written {
    if (props.layout.line_numbers.isEmpty()) return .{ .ops = 0, .bytes = 0, .runs = 0 };

    var op_count: usize = 0;
    var scratch_used: usize = 0;
    var run_used: usize = 0;

    for (props.rows) |row| {
        const number = row.number orelse continue; // 랩 이어짐 행은 번호가 없다

        if (scratch_used + max_digits > text_scratch.len) return error.OutOfSpace;
        const text = std.fmt.bufPrint(text_scratch[scratch_used..], "{d}", .{number}) catch
            return error.OutOfSpace;
        scratch_used += text.len;

        // 우측 정렬: 영역 오른쪽 끝에서 글자 수만큼 왼쪽으로 민다.
        //
        // **여기서는 byte 수가 곧 셀 수다** — 줄 번호는 언제나 ASCII 숫자이므로 전각·결합 문자가
        // 없다. 본문은 그렇지 않아 `content.expandTabs`가 `width.cellWidth`로 센다.
        const field_cols = props.layout.line_numbers.width;
        const len: u16 = @intCast(@min(text.len, field_cols));
        const col = props.layout.line_numbers.start + (field_cols - len);

        // **자리마다 op을 낸다.** 문자열 하나로 넘기면 백엔드가 measured advance로 이어 붙이는데,
        // 그 advance가 셀 폭과 미세하게 달라(등폭 폰트도 7.8px vs 셀 8px 같은 차이가 난다) 두 번째
        // 글자부터 격자를 벗어난다 — 실측에서 `9`와 `10`의 오른쪽 끝이 기본 2px, 큰 폰트 4px
        // 어긋났다. 폰트 크기를 셀에서 파생해도 이 차이는 남는다(그렇게 해 보고 확인했다).
        //
        // op 원점은 우리가 셀 좌표로 주므로 **한 op에 한 글자면 벗어날 수 없다.** 줄 번호는 길어야
        // 여섯 자라 op 부담이 작고, 본문에는 이 방법을 쓸 수 없다(한 줄 60자면 op이 폭발한다).
        // 근본 해법은 백엔드가 cluster 폭으로 셀 인덱스를 세어 스냅하는 것이며 별도 작업으로 남는다.
        const y = props.origin_px.y + @as(i32, row.visual_row) * @as(i32, props.cell_h_px);
        for (text, 0..) |_, digit_index| {
            if (run_used >= runs.len) return error.OutOfSpace;
            runs[run_used] = .{ .text = text[digit_index .. digit_index + 1] };
            const run_slice = runs[run_used .. run_used + 1];
            run_used += 1;

            if (op_count >= out.len) return error.OutOfSpace;
            const digit_col = col + @as(u16, @intCast(digit_index));
            out[op_count] = .{ .text = .{
                .origin = .{
                    .x = props.origin_px.x + @as(i32, digit_col) * @as(i32, props.cell_w_px),
                    .y = y,
                },
                .runs = run_slice,
                .role = line_number_role,
                .max_cols = 1,
                .font_px = props.font_px,
                .line_height_px = props.cell_h_px,
            } };
            op_count += 1;
        }
    }

    return .{ .ops = op_count, .bytes = scratch_used, .runs = run_used };
}

/// 뷰포트에 보이는 논리 줄들을 gutter 행으로 편다. 랩·접힘이 없는 N1 경로다.
///
/// 랩이 붙으면 이 함수가 시각 매핑(`visual_map.zig`)의 결과를 받도록 바뀐다 — **그때 호출부만 바뀌고
/// `build`는 그대로**이므로, `Row`가 optional 번호를 갖는 것이 지금은 쓰이지 않아도 미리 있는 이유다.
pub fn rowsForRange(first_line: usize, count: u16, out: []Row) []Row {
    const n = @min(count, out.len);
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        out[i] = .{ .number = first_line + i + 1, .visual_row = i }; // 화면 표시는 1-based
    }
    return out[0..n];
}

const testing = std.testing;

test "rowsForRange: 0-based 줄을 1-based 표시 번호로 바꾼다" {
    var buf: [4]Row = undefined;
    const rows = rowsForRange(0, 3, &buf);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(@as(usize, 1), rows[0].number.?);
    try testing.expectEqual(@as(usize, 3), rows[2].number.?);
    try testing.expectEqual(@as(u16, 0), rows[0].visual_row);
}

test "rowsForRange: 스크롤된 뷰포트는 첫 줄부터 센다" {
    var buf: [4]Row = undefined;
    const rows = rowsForRange(41, 2, &buf);

    try testing.expectEqual(@as(usize, 42), rows[0].number.?);
    try testing.expectEqual(@as(u16, 0), rows[0].visual_row); // 화면에서는 첫 행이다
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

test "줄 번호는 우측 정렬된다 — 자릿수가 달라도 본문과의 간격이 같아야 한다" {
    const layout = geometry.compute(80, 100, .{});
    const rows = [_]Row{
        .{ .number = 1, .visual_row = 0 },
        .{ .number = 100, .visual_row = 1 },
    };

    var ops: [8]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqual(@as(usize, 2), w.ops);

    // 여백 1셀 뒤 번호 영역이 열 1~6이므로 "1"은 열 5, "100"은 열 3에서 시작한다 — 오른쪽 끝이 같다.
    try testing.expectEqual(@as(i32, 5 * 8), ops[0].text.origin.x);
    try testing.expectEqual(@as(i32, 3 * 8), ops[1].text.origin.x);
    try testing.expectEqualStrings("1", ops[0].text.runs[0].text);
    try testing.expectEqualStrings("100", ops[1].text.runs[0].text);
}

test "행 간격은 셀 높이를 따른다 — 본문 줄과 1:1로 정렬돼야 한다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .number = 1, .visual_row = 0 },
        .{ .number = 2, .visual_row = 1 },
        .{ .number = 3, .visual_row = 2 },
    };

    var ops: [8]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    try testing.expectEqual(@as(i32, 0), ops[0].text.origin.y);
    try testing.expectEqual(@as(i32, 16), ops[1].text.origin.y);
    try testing.expectEqual(@as(i32, 32), ops[2].text.origin.y);
}

test "뷰 원점이 옮겨지면 gutter 전체가 함께 옮겨진다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{.{ .number = 1, .visual_row = 0 }};

    var ops: [4]draw.Op = undefined;
    var scratch: [32]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    var props = testProps(layout, &rows);
    props.origin_px = .{ .x = 100, .y = 50 };
    _ = try build(props, &ops, &scratch, &runs);

    try testing.expectEqual(@as(i32, 100 + 5 * 8), ops[0].text.origin.x);
    try testing.expectEqual(@as(i32, 50), ops[0].text.origin.y);
}

test "랩으로 이어진 행은 번호를 그리지 않는다 — 자리만 차지한다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .number = 1, .visual_row = 0 },
        .{ .number = null, .visual_row = 1 }, // 1번 줄의 랩 이어짐
        .{ .number = 2, .visual_row = 2 },
    };

    var ops: [8]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    // 행은 셋인데 op은 둘이다.
    try testing.expectEqual(@as(usize, 2), w.ops);
    // 쓴 byte도 둘의 자릿수 합이어야 한다("1"·"2" = 2). 호출자가 이 값으로 남은 자리를 넘긴다.
    try testing.expectEqual(@as(usize, 2), w.bytes);
    try testing.expectEqual(@as(usize, 2), w.runs);
    try testing.expectEqualStrings("2", ops[1].text.runs[0].text);
    // 두 번째 번호는 시각 행 2에 있어야 한다 — 랩 행을 건너뛴 만큼 내려간다.
    try testing.expectEqual(@as(i32, 32), ops[1].text.origin.y);
}

test "줄 번호를 끄면 아무것도 그리지 않는다" {
    const layout = geometry.compute(80, 10, .{ .line_numbers = false });
    const rows = [_]Row{.{ .number = 1, .visual_row = 0 }};

    var ops: [4]draw.Op = undefined;
    var scratch: [32]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs);
    try testing.expectEqual(@as(usize, 0), w.ops);
    try testing.expectEqual(@as(usize, 0), w.bytes);
}

test "저장소가 모자라면 조용히 자르지 않고 실패한다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .number = 1, .visual_row = 0 },
        .{ .number = 2, .visual_row = 1 },
    };

    var ops: [1]draw.Op = undefined; // 하나만 담을 수 있다
    var scratch: [64]u8 = undefined;
    var runs: [8]draw.Run = undefined;

    try testing.expectError(error.OutOfSpace, build(testProps(layout, &rows), &ops, &scratch, &runs));
}

test "자릿수가 영역보다 길면 잘라 내지 않고 왼쪽 끝에 맞춘다" {
    // 줄 수가 적어 영역이 5셀인데 번호가 6자리인 경우 — 뷰포트가 문서 끝을 넘어간 비정상 상태지만
    // 좌표가 음수로 가면 gutter 밖에 글자가 찍힌다. 그것만 막는다.
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{.{ .number = 123_456, .visual_row = 0 }};

    var ops: [4]draw.Op = undefined;
    var scratch: [32]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    // 여백 1셀 뒤가 번호 영역의 시작이다. 음수로 가서 gutter 밖에 찍히는 것만 막는다.
    try testing.expectEqual(@as(i32, 1 * 8), ops[0].text.origin.x);
}

test "각 op이 자기 run을 가리킨다 — 공유 버퍼를 덮어쓰지 않는다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .number = 7, .visual_row = 0 },
        .{ .number = 8, .visual_row = 1 },
    };

    var ops: [4]draw.Op = undefined;
    var scratch: [32]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    _ = try build(testProps(layout, &rows), &ops, &scratch, &runs);

    // 두 op이 같은 run을 가리키면 마지막 글자가 둘 다에 나온다.
    try testing.expectEqualStrings("7", ops[0].text.runs[0].text);
    try testing.expectEqualStrings("8", ops[1].text.runs[0].text);
}
