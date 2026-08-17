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
const visual_map = @import("../../ui/visual_map.zig"); // §4 세로 축 — 본문이 정한 시각 배치를 따른다

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
    /// 이 줄이 접을 수 있는 머리인가, 접혀 있는가. `none`이면 접힘 칸이 빈다.
    fold: Fold = .none,
};

/// gutter 접힘 칸에 그릴 표식. **늘 그린다 — hover가 아니다.**
///
/// VSCode는 화살표를 hover에서만 보이지만 **N1에는 편집기 pane에 포인터 경로가 없다**(§4.1f) —
/// hover 규칙을 흉내 내면 표식이 영영 안 보인다. Vim `foldcolumn`이 같은 조건에서 `-`(열림)·
/// `+`(닫힘)을 **늘 그린다**. 그 선례를 따른다.
pub const Fold = enum {
    /// 접을 수 있는 자리가 아니다.
    none,
    /// 접을 수 있는 머리인데 지금은 펼쳐져 있다.
    open,
    /// 접혀 있다 — **아래에 숨은 줄이 있다는 유일한 표시**다.
    collapsed,

    /// 그릴 글자. 삼각형은 방향이 곧 뜻이라(아래=펼침, 오른쪽=접힘) 기호를 외울 필요가 없다.
    pub fn glyph(self: Fold) ?[]const u8 {
        return switch (self) {
            .none => null,
            .open => "\u{25BE}", // ▾
            .collapsed => "\u{25B8}", // ▸
        };
    }
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
    /// 저장소가 모자라 **번호를 못 그린 줄 수**. 절단은 실패가 아니지만 조용해서도 안 된다 —
    /// 번호가 빈 줄은 화면에서 "랩으로 이어진 행"과 구분되지 않기 때문이다(§4).
    dropped_rows: usize = 0,
};

/// gutter draw op을 `out`에 채우고 각 저장소에서 쓴 양을 돌려준다.
///
/// **할당하지 않는다.** 호출자가 준 저장소만 쓰며, **모자라면 거기까지만 그린다.**
///
/// 초판은 `error.OutOfSpace`로 fail-close했다 — "조용히 잘라 내면 아래쪽 줄 번호가 사라진 채
/// 캡처가 통과한다"는 이유였다. 그런데 호출자가 이 에러를 프레임 전체의 실패로 다루므로 **번호 몇
/// 개가 아니라 편집기가 통째로 사라진다**(#2086이 `content`에서 고친 것과 같은 결함). 본문이
/// 먼저 그려지는 순서(§4 — 배치를 본문이 정한다)에서는 본문이 op을 다 쓰면 여기에 0이 남을 수
/// 있어, 적대적 검증이 실제로 그 상태를 재현했다.
///
/// 조용해지지 않도록 `Written.dropped_rows`로 **몇 줄을 못 그렸는지 알린다.**
///
/// 줄 번호는 **우측 정렬**이다(Monaco와 같다). 자릿수가 다른 줄이 좌측 정렬되면 본문과의 간격이
/// 줄마다 달라져 읽기 흐름이 끊긴다.
pub fn build(props: Props, out: []draw.Op, text_scratch: []u8, runs: []draw.Run) Written {
    if (props.layout.line_numbers.isEmpty()) return .{ .ops = 0, .bytes = 0, .runs = 0 };

    var op_count: usize = 0;
    var scratch_used: usize = 0;
    var run_used: usize = 0;

    var dropped: usize = 0;
    for (props.rows) |row| {
        // **접힘 표식을 번호보다 먼저 낸다.** 번호가 없는 행(랩 이어짐)에서 `continue`가 걸리기
        // 때문이다 — 뒤에 두면 접힌 줄이 랩된 경우에 표식이 사라진다.
        if (!props.layout.folding.isEmpty()) {
            if (row.fold.glyph()) |g| {
                if (scratch_used + g.len <= text_scratch.len and run_used < runs.len and op_count < out.len) {
                    const mark = text_scratch[scratch_used..][0..g.len];
                    @memcpy(mark, g);
                    scratch_used += g.len;
                    runs[run_used] = .{ .text = mark };
                    const mark_slice = runs[run_used .. run_used + 1];
                    run_used += 1;
                    out[op_count] = .{ .text = .{
                        .origin = .{
                            .x = props.origin_px.x + @as(i32, props.layout.folding.start) * @as(i32, props.cell_w_px),
                            .y = props.origin_px.y + @as(i32, row.visual_row) * @as(i32, props.cell_h_px),
                        },
                        .runs = mark_slice,
                        .role = line_number_role,
                        .max_cols = props.layout.folding.width,
                        .font_px = props.font_px,
                        .line_height_px = props.cell_h_px,
                        .cell_w_px = props.cell_w_px,
                    } };
                    op_count += 1;
                }
            }
        }

        const number = row.number orelse continue; // 랩 이어짐 행은 번호가 없다

        // **여유를 `max_digits`로 요구하지 않는다.** 그것은 `usize` 최대(20자리)라, 실제로는 서너
        // 바이트면 되는 줄에 스무 바이트를 요구해 **예약이 정확한데도 뒤쪽 줄을 버렸다** — 호출자가
        // `scratchNeeded`(행 × 실제 자릿수)로 딱 맞게 떼어 주면 마지막 대여섯 줄의 번호가 사라졌다
        // (실측: 3자리 40행에 120바이트를 주면 33행까지만 그려졌다. 적대적 검증 2026-08-17).
        // 모자람 판정은 `bufPrint`에 맡긴다 — 실제로 쓸 수 있는지를 아는 유일한 자리다.
        if (run_used >= runs.len or op_count >= out.len) {
            dropped += 1;
            continue;
        }
        const text = std.fmt.bufPrint(text_scratch[scratch_used..], "{d}", .{number}) catch {
            dropped += 1;
            continue;
        };
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
        runs[run_used] = .{ .text = text };
        const run_slice = runs[run_used .. run_used + 1];
        run_used += 1;

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

    return .{ .ops = op_count, .bytes = scratch_used, .runs = run_used, .dropped_rows = dropped };
}

/// 이 행 수·최대 줄 번호로 그릴 때 **필요한 저장소 상한**. 호출자가 gutter 몫을 미리 떼어 둘 때 쓴다.
///
/// **`max_digits`로 잡으면 안 된다.** 그것은 `usize` 최대(20자리)라 실제 줄 번호(한두 자리)의 열 배를
/// 예약하게 되고, 그만큼 본문이 근거 없이 줄어든다 — 저장소를 나눠 쓰므로 한쪽의 과잉이 곧 다른 쪽의
/// 손실이다. 자릿수 계산이 여기 있는 이유는 `build`의 규칙(1-based로 찍는다)과 같은 곳에 두기
/// 위해서다. 호출자가 세면 그 규칙을 복제하게 된다.
///
/// **접힘 표식 몫이 따로 붙는다.** 화살표는 3바이트짜리 UTF-8이고 `build`가 번호보다 **먼저** 쓰므로,
/// 이 몫이 빠지면 앞 행의 화살표가 뒤 행의 번호를 밀어낸다 — 실측으로 3자리 40행 화면에서 **23줄의
/// 번호가 사라졌다**(적대적 검증 2026-08-17). 접힘 표식을 안 넘기는 호출자(비교 뷰)는 `false`를 줘
/// 예약을 늘리지 않는다.
pub fn scratchNeeded(row_count: usize, max_line_number: usize, folds: bool) usize {
    var digits: usize = 1;
    var n = max_line_number;
    while (n >= 10) : (n /= 10) digits += 1;
    return row_count * (digits + if (folds) fold_mark_bytes else 0);
}

/// 접힘 표식 하나가 쓰는 최대 바이트. `Fold.glyph()`에서 유도한다 — 글자를 바꾸면 예약이 함께
/// 따라오게 하려고 상수를 손으로 적지 않는다.
pub const fold_mark_bytes: usize = blk: {
    var m: usize = 0;
    for (std.enums.values(Fold)) |f| {
        if (f.glyph()) |g| m = @max(m, g.len);
    }
    break :blk m;
};

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
pub fn rowsForVisual(
    visual: []const visual_map.VisualRow,
    first_line: usize,
    /// **번호를 밖에서 준다면** 그 표를 논리 줄 인덱스로 읽는다(`null` 항목 = 번호 없는 줄).
    /// diff 본문이 이 자리를 쓴다 — 좌우 행은 나란히 서지만 번호는 **각자 문서**의 것이고,
    /// 짝을 맞추려고 넣은 빈 행에는 번호가 없다(없는 줄에 번호를 붙이면 거짓이다).
    /// `null`이면 지금까지대로 `first_line + 줄 + 1`이다.
    numbers: ?[]const ?u32,
    /// 논리 줄마다의 접힘 표식(줄 인덱스로 읽는다). `null`이면 표식을 안 그린다.
    folds: ?[]const Fold,
    out: []Row,
) []Row {
    const n = @min(visual.len, out.len);
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const v = visual[i];
        out[i] = .{
            // **랩으로 이어진 행은 번호를 비운다**(§4). 판정은 `VisualRow`가 소유한다 — 여기서
            // `piece == 0`을 다시 쓰면 규칙이 두 곳에 생긴다.
            .number = if (!v.showsLineNumber()) null else if (numbers) |table| blk: {
                const idx = first_line + v.line;
                break :blk if (idx < table.len) (if (table[idx]) |num| @as(usize, num) else null) else null;
            } else first_line + v.line + 1,
            .visual_row = i,
            // **이어진 조각에는 안 붙인다** — 한 줄에 표식이 여러 개 서면 접힌 줄 수를 오해한다.
            .fold = if (!v.showsLineNumber()) .none else if (folds) |table| blk: {
                const idx = first_line + v.line;
                break :blk if (idx < table.len) table[idx] else .none;
            } else .none,
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
    const rows = rowsForVisual(&visual, 1, null, null, &buf); // first_line = 1

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
    try testing.expectEqual(@as(usize, 45), scratchNeeded(45, 9, false)); // 1자리
    try testing.expectEqual(@as(usize, 90), scratchNeeded(45, 10, false)); // 2자리 경계
    try testing.expectEqual(@as(usize, 90), scratchNeeded(45, 99, false));
    try testing.expectEqual(@as(usize, 135), scratchNeeded(45, 100, false));
    try testing.expectEqual(@as(usize, 0), scratchNeeded(0, 12345, false));

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
    const w = build(testProps(layout, &rows), &ops, &scratch, &runs);
    try testing.expect(w.bytes <= scratchNeeded(rows.len, 100, false));
}

test "접힘 표식은 랩 이어짐 행에 반복되지 않고 표 밖을 지어내지 않는다" {
    // **가드가 없었다.** 규칙은 `rowsForVisual` 주석에만 있어서, "이어진 조각에는 안 붙인다"를
    // 지워도 아무 테스트가 깨지지 않았다 — 접힌 줄이 랩되면 화살표가 행마다 서서 **접힌 줄 수를
    // 오해하게 만든다**(적대적 검증 2026-08-17). 줄 번호가 같은 규칙을 이미 테스트로 지키고 있으므로
    // 표식도 같은 자리에서 지킨다.
    const visual = [_]visual_map.VisualRow{
        .{ .line = 0, .piece = 0 }, // 접힌 머리
        .{ .line = 0, .piece = 1 }, // 그 줄의 이어진 조각
        .{ .line = 1, .piece = 0 }, // 표 밖(길이 1)
    };
    const folds = [_]Fold{.collapsed};
    var buf: [4]Row = undefined;
    const rows = rowsForVisual(&visual, 0, null, &folds, &buf);
    try testing.expectEqual(Fold.collapsed, rows[0].fold);
    try testing.expectEqual(Fold.none, rows[1].fold); // 이어진 조각에는 안 선다
    try testing.expectEqual(Fold.none, rows[2].fold); // 표가 짧으면 지어내지 않는다

    // **표를 안 주면 접힘 칸이 빈다** — 접힘을 모르는 호출자(비교 뷰)가 그대로 지나간다.
    const bare = rowsForVisual(&visual, 0, null, null, &buf);
    for (bare) |r| try testing.expectEqual(Fold.none, r.fold);
}

test "접힘 표식도 세로 스크롤에서 표를 절대 인덱스로 읽는다" {
    // 번호가 겪은 결함과 같은 자리다(*"표를 뷰포트 기준으로 읽으면 화면 맨 위가 늘 표의 0번"*).
    // 표식이 한 칸 밀리면 **접힌 줄이 아닌 곳에 ▸가 서서** 접을 수 없는 자리를 접을 수 있다고 말한다.
    const visual = [_]visual_map.VisualRow{ .{ .line = 0, .piece = 0 }, .{ .line = 1, .piece = 0 } };
    const folds = [_]Fold{ .none, .none, .collapsed, .open };
    var buf: [4]Row = undefined;
    const rows = rowsForVisual(&visual, 2, null, &folds, &buf); // first_line = 2
    try testing.expectEqual(Fold.collapsed, rows[0].fold);
    try testing.expectEqual(Fold.open, rows[1].fold);
}

test "접힘 표식 몫까지 예약한다 — 예약이 모자라면 뒤쪽 줄 번호가 사라진다" {
    // **예약은 gutter가 받는 최소 크기다.** `frame`은 본문에 `text_bytes - gutter_reserve`만 주고
    // 남은 것을 gutter에 넘기므로, 본문이 자기 몫을 다 쓴 화면(긴 줄들)에서 gutter가 갖는 것은
    // 정확히 이 예약뿐이다. 화살표는 3바이트짜리 UTF-8이고 **번호보다 먼저** 쓰이므로, 그 몫이
    // 예약에서 빠져 있으면 앞 행의 화살표가 뒤 행의 번호를 밀어낸다 —
    // "번호가 없으면 화면 전체가 문서의 어디인지 알 수 없다"는 그 예약의 존재 이유가 무력해진다
    // (적대적 검증 2026-08-17).
    const layout = geometry.compute(80, 100, .{});
    var rows: [40]Row = undefined;
    for (&rows, 0..) |*r, i| r.* = .{ .number = 100 + i, .visual_row = @intCast(i), .fold = .collapsed };

    // **행마다 op이 둘이다**(화살표 + 번호) — 저장소를 재는 테스트가 op 부족으로 먼저 걸리면
    // 무엇이 모자랐는지 갈리지 않는다.
    var ops: [rows.len * 2]draw.Op = undefined;
    var runs: [rows.len * 2]draw.Run = undefined;
    const need = scratchNeeded(rows.len, 100 + rows.len, true);
    const scratch = try testing.allocator.alloc(u8, need);
    defer testing.allocator.free(scratch);

    const w = build(testProps(layout, &rows), &ops, scratch, runs[0..]);
    try testing.expectEqual(@as(usize, 0), w.dropped_rows); // 한 줄도 못 그린 것이 없다
    try testing.expect(w.bytes <= need);
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
    const w = build(testProps(layout, &rows), &ops, &scratch, &runs);

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
    _ = build(testProps(layout, &rows), &ops, &scratch, &runs);

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
    _ = build(props, &ops, &scratch, &runs);

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
    const w = build(testProps(layout, &rows), &ops, &scratch, &runs);

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
    const w = build(testProps(layout, &rows), &ops, &scratch, &runs);
    try testing.expectEqual(@as(usize, 0), w.ops);
    try testing.expectEqual(@as(usize, 0), w.bytes);
}

test "저장소가 모자라면 거기까지만 그리고 못 그린 줄 수를 알린다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .number = 1, .visual_row = 0 },
        .{ .number = 2, .visual_row = 1 },
    };

    var ops: [1]draw.Op = undefined; // 하나만 담을 수 있다
    var scratch: [64]u8 = undefined;
    var runs: [8]draw.Run = undefined;

    // **실패하지 않는다.** 초판은 `error.OutOfSpace`를 올렸는데, 호출자가 그것을 프레임 전체의
    // 실패로 다루므로 **번호 몇 개가 아니라 편집기가 통째로 사라졌다**(#2086이 `content`에서 고친
    // 것과 같은 결함). 본문이 먼저 그려지는 순서에서는 본문이 op을 다 쓰면 여기에 0이 남을 수 있어
    // 실제로 일어난다 — 적대적 검증이 재현했다.
    const w = build(testProps(layout, &rows), &ops, &scratch, &runs);
    try testing.expectEqual(@as(usize, 1), w.ops); // 담을 수 있는 만큼은 그렸다
    try testing.expectEqual(@as(usize, 1), w.dropped_rows); // 그리고 못 그린 줄을 알린다
}

test "op·run·문자 저장소 어느 쪽이 모자라도 죽지 않는다" {
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{
        .{ .number = 1, .visual_row = 0 },
        .{ .number = 2, .visual_row = 1 },
        .{ .number = 3, .visual_row = 2 },
    };
    for ([_]usize{ 0, 1, 2, 3 }) |cap| {
        var ops: [4]draw.Op = undefined;
        var runs: [4]draw.Run = undefined;
        var scratch: [64]u8 = undefined;
        const w = build(testProps(layout, &rows), ops[0..cap], &scratch, runs[0..cap]);
        try testing.expectEqual(@min(cap, rows.len), w.ops);
        try testing.expectEqual(rows.len - @min(cap, rows.len), w.dropped_rows);
    }
    // 문자 저장소만 모자란 경우도 같다. **번호 세 개가 각 1바이트이므로 3바이트 미만이 진짜 모자란
    // 크기다** — 예전에는 `build`가 줄마다 `max_digits`(20) 여유를 요구해 5바이트도 "모자람"이었고,
    // 그 요구가 결함이었다(예약이 정확한데도 뒤쪽 줄을 버렸다). 그것을 고치면서 이 값들도 실제
    // 경계로 옮긴다.
    for ([_]usize{ 0, 1, 2 }) |sc| {
        var ops: [8]draw.Op = undefined;
        var runs: [8]draw.Run = undefined;
        var scratch: [64]u8 = undefined;
        const w = build(testProps(layout, &rows), &ops, scratch[0..sc], &runs);
        try testing.expect(w.dropped_rows > 0);
    }
}

test "자릿수가 영역보다 길면 잘라 내지 않고 왼쪽 끝에 맞춘다" {
    // 줄 수가 적어 영역이 5셀인데 번호가 6자리인 경우 — 뷰포트가 문서 끝을 넘어간 비정상 상태지만
    // 좌표가 음수로 가면 gutter 밖에 글자가 찍힌다. 그것만 막는다.
    const layout = geometry.compute(80, 10, .{});
    const rows = [_]Row{.{ .number = 123_456, .visual_row = 0 }};

    var ops: [4]draw.Op = undefined;
    var scratch: [32]u8 = undefined;
    var runs: [4]draw.Run = undefined;
    _ = build(testProps(layout, &rows), &ops, &scratch, &runs);

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
    _ = build(testProps(layout, &rows), &ops, &scratch, &runs);

    // 두 op이 같은 run을 가리키면 마지막 글자가 둘 다에 나온다.
    try testing.expectEqualStrings("7", ops[0].text.runs[0].text);
    try testing.expectEqualStrings("8", ops[1].text.runs[0].text);
}

test "번호를 밖에서 주면 그것을 쓴다 — diff는 좌우가 각자 문서의 번호를 단다" {
    // **순차 번호로는 diff를 그릴 수 없다.** 왼쪽에서 삭제된 줄과 오른쪽에서 추가된 줄이 같은 높이에
    // 서지만 번호는 각자 문서의 것이고, 짝을 맞추려 넣은 빈 행에는 번호가 아예 없어야 한다.
    const visual = [_]visual_map.VisualRow{
        .{ .line = 0, .piece = 0 },
        .{ .line = 1, .piece = 0 },
        .{ .line = 2, .piece = 0 },
    };
    const numbers = [_]?u32{ 7, null, 8 }; // 가운데가 빈 행(filler)
    var buf: [8]Row = undefined;
    const rows = rowsForVisual(&visual, 0, &numbers, null, &buf);
    try testing.expectEqual(@as(?usize, 7), rows[0].number);
    try testing.expectEqual(@as(?usize, null), rows[1].number);
    try testing.expectEqual(@as(?usize, 8), rows[2].number);
}

test "밖에서 준 번호도 랩 이어짐에는 안 붙는다 — 두 규칙이 겹치는 자리" {
    const visual = [_]visual_map.VisualRow{
        .{ .line = 0, .piece = 0 },
        .{ .line = 0, .piece = 1 }, // 이어진 조각
    };
    const numbers = [_]?u32{42};
    var buf: [4]Row = undefined;
    const rows = rowsForVisual(&visual, 0, &numbers, null, &buf);
    try testing.expectEqual(@as(?usize, 42), rows[0].number);
    try testing.expectEqual(@as(?usize, null), rows[1].number);
}

test "표가 짧으면 번호를 지어내지 않는다" {
    const visual = [_]visual_map.VisualRow{ .{ .line = 0, .piece = 0 }, .{ .line = 1, .piece = 0 } };
    const numbers = [_]?u32{5};
    var buf: [4]Row = undefined;
    const rows = rowsForVisual(&visual, 0, &numbers, null, &buf);
    try testing.expectEqual(@as(?usize, 5), rows[0].number);
    try testing.expectEqual(@as(?usize, null), rows[1].number);
}

test "밖에서 준 번호 + 세로 스크롤: 표를 절대 인덱스로 읽는다" {
    // **이 조합이 늘 빈다.** 위 랩+스크롤 테스트가 그것을 두고 *"둘이 겹치는 자리를 아무도 보지
    // 않았다"*고 적었는데, 번호 주입이 들어오며 같은 자리가 하나 더 생겼다 — 표를 뷰포트 기준으로
    // 읽으면 스크롤한 diff에서 번호가 통째로 어긋난다(화면 맨 위가 늘 표의 0번이 된다).
    const visual = [_]visual_map.VisualRow{
        .{ .line = 0, .piece = 0 }, // first_line=2 → 표의 2번
        .{ .line = 1, .piece = 0 }, // 표의 3번
    };
    const numbers = [_]?u32{ 10, 11, 12, null, 13 };
    var buf: [4]Row = undefined;
    const rows = rowsForVisual(&visual, 2, &numbers, null, &buf);
    try testing.expectEqual(@as(?usize, 12), rows[0].number);
    try testing.expectEqual(@as(?usize, null), rows[1].number); // 그 자리가 빈 행이다
}
