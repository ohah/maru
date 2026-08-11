//! gutter에 **무엇을 그리는가** — 줄 번호와 줄 단위 표식.
//!
//! 어디에 그리는지는 [geometry.zig](geometry.zig)가 답한다(§4.1). 두 파일을 가르는 이유는 그리기와
//! hit-test가 같은 레이아웃 소스를 공유해야 하기 때문이다([chrome-strategy.md](../../../../docs/chrome-strategy.md) §5.4) —
//! 레이아웃을 여기 두면 hit-test가 그것을 복제하게 된다.
//!
//! **텍스트는 셀 격자에 놓는다.** 줄 번호는 본문과 같은 등폭 격자에 서므로 advance 누적 배치를 쓰지 않는다
//! ([native-editor-layering.md](../../../../docs/native-editor-layering.md) §2.0) — 본문 줄과 1:1로 세로 정렬돼야 하고,
//! 편집기 폰트 크기를 키우면 함께 커져야 한다.

const std = @import("std");
const chrome = @import("../../../chrome.zig");
const geometry = @import("geometry.zig");
const visual_map = @import("visual_map.zig"); // §4 세로 축 — 본문이 정한 시각 배치를 따른다

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
pub const max_digits = 20; // 호출자가 gutter 몫을 떼어 둘 때 쓴다(lab.zig 참고)

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

        // 문자열 하나로 낸다. 백엔드가 `cell_w_px`를 보고 **글자마다 셀 인덱스를 세어** 놓으므로
        // (`platform/macos/chrome/system_text.zig`) 자리마다 op을 쪼갤 필요가 없다.
        if (run_used >= runs.len) return error.OutOfSpace;
        runs[run_used] = .{ .text = text };
        const run_slice = runs[run_used .. run_used + 1];
        run_used += 1;

        if (op_count >= out.len) return error.OutOfSpace;
        out[op_count] = .{ .text = .{
            .origin = .{
                .x = props.origin_px.x + @as(i32, col) * @as(i32, props.cell_w_px),
                .y = props.origin_px.y + @as(i32, row.visual_row) * @as(i32, props.cell_h_px),
            },
            .runs = run_slice,
            .role = line_number_role,
            .max_cols = field_cols,
            .font_px = props.font_px,
            .line_height_px = props.cell_h_px,
            .cell_w_px = props.cell_w_px,
        } };
        op_count += 1;
    }

    return .{ .ops = op_count, .bytes = scratch_used, .runs = run_used };
}

/// 이 행 수·최대 줄 번호로 그릴 때 **필요한 저장소 상한**. 호출자가 gutter 몫을 미리 떼어 둘 때 쓴다.
///
/// **`max_digits`로 잡으면 안 된다.** 그것은 `usize` 최대(20자리)라 실제 줄 번호(한두 자리)의 열 배를
/// 예약하게 되고, 그만큼 본문이 근거 없이 줄어든다 — 저장소를 나눠 쓰므로 한쪽의 과잉이 곧 다른 쪽의
/// 손실이다. 자릿수 계산이 여기 있는 이유는 `build`의 규칙(1-based로 찍는다)과 같은 곳에 두기
/// 위해서다. 호출자가 세면 그 규칙을 복제하게 된다.
pub fn scratchNeeded(row_count: usize, max_line_number: usize) usize {
    var digits: usize = 1;
    var n = max_line_number;
    while (n >= 10) : (n /= 10) digits += 1;
    return row_count * digits;
}

/// 본문이 정한 시각 배치를 gutter 행으로 옮긴다 — **랩이 켜졌을 때 쓴다.**
///
/// **이것이 gutter 행을 만드는 유일한 경로다.** 랩이 꺼지면 조각이 항상 0이라 논리 줄과 1:1로
/// 떨어지므로, "줄 번호를 순서대로 센다"는 별도 함수가 필요 없다 — 그런 함수(`rowsForRange`)가
/// 있었으나 **랩이 켜졌을 때 번호가 본문과 어긋나는 길**이라 지웠다(적대적 검증이 그 상태를 실제로
/// 잡았다). 어디서
/// 접혔는지는 본문을 전개해 나눠 본 쪽만 알기 때문에(`content.build` → `visual_map.VisualRow`),
/// **본문이 답을 내고 gutter가 따른다.** 둘이 각자 세면 번호가 본문과 어긋난다.
///
/// `first_line`은 뷰포트 첫 논리 줄의 0-based 인덱스다.
pub fn rowsForVisual(visual: []const visual_map.VisualRow, first_line: usize, out: []Row) []Row {
    const n = @min(visual.len, out.len);
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const v = visual[i];
        out[i] = .{
            // **랩으로 이어진 행은 번호를 비운다**(§4). 판정은 `VisualRow`가 소유한다 — 여기서
            // `piece == 0`을 다시 쓰면 규칙이 두 곳에 생긴다.
            .number = if (v.showsLineNumber()) first_line + v.line + 1 else null,
            .visual_row = i,
        };
    }
    return out[0..n];
}

const testing = std.testing;

test "랩 + 세로 스크롤: 뷰포트가 문서 중간부터여도 번호가 맞는다" {
    // **이 조합에 가드가 없었다.** 랩 테스트는 first_row=0이고 스크롤 캡처는 랩이 꺼져 있어,
    // 둘이 겹치는 자리를 아무도 보지 않았다. `first_line + v.line + 1`이 그 자리다.
    //
    // 문서 5줄 중 **줄 1부터** 보이고, 그 줄이 좁은 본문에서 세 조각으로 접힌 상황이다.
    const visual = [_]visual_map.VisualRow{
        .{ .line = 0, .piece = 0 }, // 문서의 줄 1 → 번호 2
        .{ .line = 0, .piece = 1 }, // 이어짐 → 번호 없음
        .{ .line = 0, .piece = 2 },
        .{ .line = 1, .piece = 0 }, // 번호 3
        .{ .line = 2, .piece = 0 }, // 번호 4
    };
    var buf: [8]Row = undefined;
    const rows = rowsForVisual(&visual, 1, &buf); // first_line = 1

    try testing.expectEqual(@as(usize, 5), rows.len);
    try testing.expectEqual(@as(usize, 2), rows[0].number.?);
    try testing.expect(rows[1].number == null);
    try testing.expect(rows[2].number == null);
    try testing.expectEqual(@as(usize, 3), rows[3].number.?);
    try testing.expectEqual(@as(usize, 4), rows[4].number.?);

    // 시각 행 인덱스는 **화면 기준 0부터**다 — 스크롤 위치를 더하면 안 된다.
    try testing.expectEqual(@as(u16, 0), rows[0].visual_row);
    try testing.expectEqual(@as(u16, 4), rows[4].visual_row);
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

test "scratchNeeded: 실제 자릿수만큼만 요구한다 — max_digits로 잡으면 20배다" {
    try testing.expectEqual(@as(usize, 45), scratchNeeded(45, 9)); // 1자리
    try testing.expectEqual(@as(usize, 90), scratchNeeded(45, 10)); // 2자리 경계
    try testing.expectEqual(@as(usize, 90), scratchNeeded(45, 99));
    try testing.expectEqual(@as(usize, 135), scratchNeeded(45, 100));
    try testing.expectEqual(@as(usize, 0), scratchNeeded(0, 12345));

    // **`build`가 실제로 쓰는 양을 넘지 않는가.** 이 둘이 갈리면 예약이 모자라 gutter가 죽는다.
    const layout = geometry.compute(80, 100, .{});
    const rows = [_]Row{
        .{ .number = 98, .visual_row = 0 },
        .{ .number = 99, .visual_row = 1 },
        .{ .number = 100, .visual_row = 2 },
    };
    var ops: [8]draw.Op = undefined;
    var scratch: [64]u8 = undefined;
    var runs: [8]draw.Run = undefined;
    const w = try build(testProps(layout, &rows), &ops, &scratch, &runs);
    try testing.expect(w.bytes <= scratchNeeded(rows.len, 100));
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
