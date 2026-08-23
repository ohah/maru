//! 편집기 본문의 **화면 좌표 → (행, 논리 줄, 줄 안 byte)**.
//!
//! `content.byteAtPoint` 가 줄 하나 안의 걸음을 소유하고, 이 파일은 그 앞의 다섯 단계를 소유한다:
//! 좌표 묶기 → gutter 거르기 → 행 고르기 → 행 → 원본 줄 → 줄 안 byte.
//!
//! ## 왜 여기(중립)에 있는가
//!
//! macOS `app_session/editor.zig` 의 `hitTestBody` 가 이 계산을 갖고 있었다. Windows 편집기 표면이
//! 같은 것을 필요로 하는데 **다시 쓰면 안 된다** — 그 함수 주석에는 적대적 검증이 찾은 결함이
//! 다섯 적혀 있고(아래 각 단계가 그 기록이다), 다시 쓰면 그 다섯을 다시 밟는다.
//!
//! 플랫폼이 남기는 것은 **자기 상태에서 입력을 모으는 일**뿐이다: 굳힌 기하, 그 프레임이 그린 행
//! 배열, 행 → 원본 줄 표, 줄 텍스트. 문서 offset 으로 바꾸는 마지막 걸음도 호출자 몫이다 — 줄
//! 시작 offset 은 문서 모델(session)이 알고 chrome 은 모른다.
//!
//! ## 계약: 굳힌 값만 받는다
//!
//! `Geometry` 와 `rows` 는 **그 프레임이 실제로 쓴 값**이어야 한다. 클릭 시점에 다시 구하면 행
//! 배열과 다른 프레임의 값이 되고, 실측으로 폭이 바뀐 뒤 클릭의 80%가·폰트가 바뀐 뒤 93%가 다른
//! 답을 냈다. **둘을 섞어도 같은 결과다** — 굳은 열에 live 셀 폭을 곱하면 그 곱 자체가 어느
//! 프레임의 것도 아니게 된다.

const std = @import("std");

const content = @import("content.zig");
const visual_map = @import("../../ui/visual_map.zig");

/// 그 프레임이 본문을 그린 기하(창 좌표·px). **렌더가 굳혀 넘긴다**(위 계약).
pub const Geometry = struct {
    /// 본문 사각의 왼쪽 위(창 좌표).
    body_x: i32,
    body_y: i32,
    /// 본문 사각 안에서 **글자가 시작하는 x**(gutter 뒤). 이보다 왼쪽은 gutter 다.
    content_left_px: u32,
    /// 본문이 쓰는 열 수.
    content_width: u16,
    cell_w_px: u16,
    cell_h_px: u16,
    /// 그 프레임이 쓴 **탭 폭**. 셀 크기와 같은 이유로 든다 — 탭 폭이 곧 열 계산이라 한 칸만
    /// 달라도 클릭이 글자에서 밀린다.
    tab_width: u8,
};

pub const Point = struct {
    /// 몇 번째 시각 행인가(0-based, 화면 기준).
    row: usize,
    /// 원본 **논리 줄** 인덱스.
    line: usize,
    /// 그 줄 안의 byte offset.
    byte_in_line: usize,
};

/// 본문 좌표를 찍는다. `null` 이면 이 좌표가 본문의 것이 아니다 — 그린 행이 없거나 **gutter** 다.
///
/// - `rows`: 그 프레임이 그린 시각 행들(`frame.Scratch.visual_rows[0..written.visual_rows]`).
/// - `row_lines`: 행 → **원본 논리 줄**. `rows` 와 같은 축·같은 길이여야 한다.
///   **`u32` 다** — macOS 가 `editor_hit_lines: []u32` 로 들고 있고 `VisualRow.line` 도 같은 폭이다.
///   `usize` 로 받았다가 **macOS CI 가** `expected []const usize, found []u32` 로 잡았다. 이 기계에서
///   그 파일은 CoreText 를 링크하는 아티팩트 안에서만 컴파일되어 로컬 게이트가 못 본다 — 그 축을
///   건드리면 **양쪽 필드 타입을 눈으로 맞춰야 한다.**
/// - `lines`: 논리 줄 텍스트. `row_lines` 의 값으로 인덱싱한다.
///
/// **행 → 원본 줄을 여기서 풀지 않는다.** 접힘이 켜지면 보이는 줄과 원본 줄이 다른데, 그 표는
/// 렌더 시점에 이미 만들어졌다. 여기서 live 상태로 다시 풀면 프레임 사이에 바뀐 값을 읽는다 —
/// 실측으로 접힘 뒤 클릭이 36 줄 어긋났다.
pub fn bodyPoint(
    geom: Geometry,
    rows: []const visual_map.VisualRow,
    row_lines: []const u32,
    lines: []const []const u8,
    x_px: f64,
    y_px: f64,
) ?Point {
    if (rows.len == 0) return null;
    // **행 배열과 줄 표는 같은 축이다.** 길이가 갈리면 아래 인덱싱이 엉뚱한 줄을 집는다.
    if (row_lines.len < rows.len) return null;
    // **셀 0 가드가 없다** — 기하가 기본값(0)인 상태는 *"한 번도 안 그렸다"* 또는 *"해제됐다"* 뿐이고
    // 둘 다 `rows.len == 0` 이라 위에서 이미 걸린다. 그린 프레임의 셀 크기는 0 일 수 없다.
    const cell_h: i64 = @intCast(geom.cell_h_px);

    // **캐스트 전에 묶는다.** `@intFromFloat` 는 표현 불가능한 값(무한대·i64 범위 밖)에서 illegal
    // behavior 이고 안전 빌드에서 죽는다 — 이 함수는 계약상 *"드래그가 본문을 벗어나는 것은 정상"* 인
    // 자리라 극단값이 오는 것을 막을 수 없다.
    //
    // **NaN 가드는 죽은 코드가 아니라 "답을 정하는" 코드다.** Zig 의 `@min`/`@max` 는 NaN 을
    // **흡수한다**(실측: `@max(-lim, @min(lim, nan)) = 1073741824`) — 그래서 가드가 없어도 안 죽는다.
    // 대신 NaN 이 **화면 맨 오른쪽**으로 해석되어 행 끝을 답한다. 가드는 그것을 **0(= gutter → null)**
    // 으로 정한다. 둘 다 안 죽지만 답이 다르므로, 아래 테스트가 그 답을 못 박는다 — 안 박아 두면
    // 가드를 지운 뮤턴트가 살아남는다(실제로 살아남았다).
    const px_limit: f64 = 1 << 30;
    const clamped_x: f64 = if (std.math.isNan(x_px)) 0 else @max(-px_limit, @min(px_limit, x_px));
    const clamped_y: f64 = if (std.math.isNan(y_px)) 0 else @max(-px_limit, @min(px_limit, y_px));
    const rel_x_raw: i64 = @as(i64, @intFromFloat(clamped_x)) - @as(i64, geom.body_x);
    const rel_y: i64 = @as(i64, @intFromFloat(clamped_y)) - @as(i64, geom.body_y);

    const content_left_px: i64 = @intCast(geom.content_left_px);
    if (rel_x_raw < content_left_px) return null; // gutter — 이 좌표계가 받지 않는다
    // **본문 오른쪽 밖을 여기서 묶지 않는다.** *"행 끝 너머 → 그 행의 끝"* 을 실제로 지키는 것은
    // `byteAtPoint` 의 `next_col > row_end_col` break 다. 여기서 한 번 더 묶어도 답이 안 바뀐다 —
    // 실측: 랩 끔·500 바이트 줄·`content_width = 89` 에서 사각 밖 +500px 클릭이 clamp 유무와
    // 무관하게 **89** 를 냈고, 그 clamp 를 지운 뮤턴트를 판정자 열셋이 하나도 못 잡았다.

    // 세로는 clamp 한다. 행이 음수면 첫 행, 넘치면 마지막 행 — 드래그가 위아래로 벗어나는 자리다.
    const row_i: usize = if (rel_y < 0) 0 else blk: {
        const r: usize = @intCast(@divFloor(rel_y, cell_h));
        break :blk @min(r, rows.len - 1);
    };
    const v = rows[row_i];

    const source_line: usize = row_lines[row_i];
    if (source_line >= lines.len) return null;

    const text = lines[source_line];
    const off_in_line = content.byteAtPoint(
        text,
        geom.tab_width,
        @min(v.start_byte, text.len),
        v.start_byte_col,
        v.start_col,
        geom.content_width,
        // **여기 clamp 가 없다.** 식은 뺄셈이고 `body_x` 는 화면 좌표에서 오므로 위 gutter 가드가
        // 하한을 세웠다. 그래서 `rel_x_raw ≤ px_limit = 2^30` 이고 뺄셈이 그것을 더 키우지 못한다.
        // 실측으로 극단 입력 36 발(±1e300·±inf·NaN·2^40)에서 죽지 않고, clamp 를 지운 뮤턴트를
        // 판정자 15 개가 하나도 못 잡았다.
        @intCast(rel_x_raw - content_left_px),
        geom.cell_w_px,
    );
    return .{ .row = row_i, .line = source_line, .byte_in_line = off_in_line };
}

const testing = std.testing;

fn fixtureRows(n: usize, buf: []visual_map.VisualRow) []visual_map.VisualRow {
    for (buf[0..n], 0..) |*r, i| r.* = .{ .line = @intCast(i), .piece = 0 };
    return buf[0..n];
}

test "gutter 는 안 받는다" {
    var buf: [4]visual_map.VisualRow = undefined;
    const rows = fixtureRows(3, &buf);
    const row_lines = [_]u32{ 0, 1, 2 };
    const lines = [_][]const u8{ "aaaa", "bbbb", "cccc" };
    const g = Geometry{ .body_x = 10, .body_y = 20, .content_left_px = 40, .content_width = 80, .cell_w_px = 9, .cell_h_px = 19, .tab_width = 4 };
    // body_x + content_left_px = 50 이 글자 시작이다. 그보다 왼쪽은 gutter.
    try testing.expect(bodyPoint(g, rows, &row_lines, &lines, 49, 25) == null);
    try testing.expect(bodyPoint(g, rows, &row_lines, &lines, 50, 25) != null);
}

test "세로는 묶는다 — 위아래로 벗어나도 첫·마지막 행이다" {
    var buf: [4]visual_map.VisualRow = undefined;
    const rows = fixtureRows(3, &buf);
    const row_lines = [_]u32{ 0, 1, 2 };
    const lines = [_][]const u8{ "aaaa", "bbbb", "cccc" };
    const g = Geometry{ .body_x = 0, .body_y = 0, .content_left_px = 0, .content_width = 80, .cell_w_px = 9, .cell_h_px = 19, .tab_width = 4 };
    try testing.expectEqual(@as(usize, 0), bodyPoint(g, rows, &row_lines, &lines, 0, -1000).?.row);
    try testing.expectEqual(@as(usize, 2), bodyPoint(g, rows, &row_lines, &lines, 0, 100_000).?.row);
    try testing.expectEqual(@as(usize, 1), bodyPoint(g, rows, &row_lines, &lines, 0, 20).?.row);
}

test "극단 좌표에서 안 죽는다 — 드래그는 화면 밖으로 나간다" {
    var buf: [4]visual_map.VisualRow = undefined;
    const rows = fixtureRows(2, &buf);
    const row_lines = [_]u32{ 0, 1 };
    const lines = [_][]const u8{ "hello world", "second line" };
    const g = Geometry{ .body_x = 5, .body_y = 5, .content_left_px = 0, .content_width = 80, .cell_w_px = 9, .cell_h_px = 19, .tab_width = 4 };
    // 무한대·거대값 — `@intFromFloat` 가 곧장 illegal behavior 인 자리다.
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 1e300, -1e300, 1 << 40 }) |bad| {
        _ = bodyPoint(g, rows, &row_lines, &lines, bad, 10);
        _ = bodyPoint(g, rows, &row_lines, &lines, 10, bad);
    }
}

test "NaN 은 원점으로 본다 — 안 죽는 것만으로는 부족하다" {
    // **답을 못 박는다.** `@min`/`@max` 가 NaN 을 흡수하므로 가드가 없어도 안 죽지만, 그때 NaN 은
    // **화면 맨 오른쪽**이 되어 행 끝을 답한다. 어느 쪽이든 죽지 않으니 "안 죽는다" 판정으로는
    // 가드를 지운 뮤턴트가 살아남는다 — 실제로 살아남았고, 이 테스트가 그 구멍을 메운다.
    var buf: [4]visual_map.VisualRow = undefined;
    const rows = fixtureRows(2, &buf);
    const row_lines = [_]u32{ 0, 1 };
    const lines = [_][]const u8{ "hello world", "second line" };
    // gutter 가 있는 기하 — NaN 이 0 으로 접히면 gutter 라 `null` 이고, 오른쪽 끝으로 접히면 값이 온다.
    const g = Geometry{ .body_x = 0, .body_y = 0, .content_left_px = 40, .content_width = 80, .cell_w_px = 9, .cell_h_px = 19, .tab_width = 4 };
    try testing.expect(bodyPoint(g, rows, &row_lines, &lines, std.math.nan(f64), 10) == null);
    // 세로 NaN 도 같은 규칙 — 첫 행이다(맨 아래가 아니다).
    const p = bodyPoint(g, rows, &row_lines, &lines, 45, std.math.nan(f64)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), p.row);
}

test "행 표가 짧으면 안 받는다 — 두 축이 갈린 상태" {
    var buf: [4]visual_map.VisualRow = undefined;
    const rows = fixtureRows(3, &buf);
    const row_lines = [_]u32{ 0, 1 }; // 행 셋인데 표는 둘
    const lines = [_][]const u8{ "aaaa", "bbbb" };
    const g = Geometry{ .body_x = 0, .body_y = 0, .content_left_px = 0, .content_width = 80, .cell_w_px = 9, .cell_h_px = 19, .tab_width = 4 };
    try testing.expect(bodyPoint(g, rows, &row_lines, &lines, 0, 0) == null);
}

test "행 → 원본 줄 표를 그대로 따른다 — 접힘이면 순차가 아니다" {
    var buf: [4]visual_map.VisualRow = undefined;
    const rows = fixtureRows(3, &buf);
    // 접힌 상태: 화면 셋째 행이 원본 42 번째 줄이다.
    const row_lines = [_]u32{ 0, 7, 42 };
    var lines_buf: [43][]const u8 = undefined;
    for (&lines_buf, 0..) |*l, i| l.* = if (i == 42) "the answer line" else "filler";
    const g = Geometry{ .body_x = 0, .body_y = 0, .content_left_px = 0, .content_width = 80, .cell_w_px = 9, .cell_h_px = 19, .tab_width = 4 };
    const p = bodyPoint(g, rows, &row_lines, &lines_buf, 0, 40).?;
    try testing.expectEqual(@as(usize, 2), p.row);
    // **여기가 실측으로 36 줄 어긋났던 자리다** — 행 인덱스를 줄 인덱스로 쓰면 2 가 나온다.
    try testing.expectEqual(@as(usize, 42), p.line);
}

test "줄 표가 범위를 벗어나면 안 받는다" {
    var buf: [4]visual_map.VisualRow = undefined;
    const rows = fixtureRows(1, &buf);
    const row_lines = [_]u32{99};
    const lines = [_][]const u8{"only one"};
    const g = Geometry{ .body_x = 0, .body_y = 0, .content_left_px = 0, .content_width = 80, .cell_w_px = 9, .cell_h_px = 19, .tab_width = 4 };
    try testing.expect(bodyPoint(g, rows, &row_lines, &lines, 0, 0) == null);
}
