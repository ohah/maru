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

// ─────────────────────────────────────────────────────────────────────────────
// 역방향: (논리 줄, 줄 안 byte) → 화면 좌표
// ─────────────────────────────────────────────────────────────────────────────

/// 문서의 한 자리가 화면 어디에 그려졌나. `bodyPoint` 와 **같은 굳힌 값**을 받는다 — 다른 프레임의
/// 기하로 풀면 실제로 그려진 자리와 어긋난다(위 계약).
pub const Anchor = struct {
    /// 몇 번째 시각 행인가(0-based, 화면 기준).
    row: usize,
    /// 그 자리 **셀의 왼쪽 위**(창 좌표·px). 아래에 무언가를 띄우려면 호출자가 `cell_h_px` 를 더한다.
    x_px: i32,
    y_px: i32,
};

/// 문서 자리를 화면 좌표로 되돌린다. `null` 이면 **그 자리가 이 프레임에 안 그려졌다** — 스크롤로
/// 벗어났거나 접혀 있다. 부르는 쪽은 그것을 "띄우지 않는다"로 읽어야 한다: 없는 자리에 띄우면
/// 상자가 엉뚱한 줄 옆에 선다.
///
/// **`bodyPoint` 의 역이지 근사가 아니다** — 열 계산은 `content.columnsAtOffsets` 하나가 하고
/// (`frame.columnOfOffset` 과 같은 함수다), 가로 원점도 그쪽이 쓰는 `start_col` 을 그대로 쓴다.
/// 여기서 다시 세면 탭스톱 규칙이 세 번째로 생긴다.
///
/// **랩된 줄은 조각이 여럿이다.** 그 줄의 행 중 `start_byte` 가 이 byte 를 넘지 않는 **마지막**
/// 행이 그 자리를 담은 행이다. 조각 경계에 정확히 걸친 byte 는 **뒤 조각**에 속한다 — 렌더가
/// 그 조각의 0 열에 그리므로 앞 조각의 오른쪽 끝에 띄우면 화면과 한 행 어긋난다.
///
/// 가로로는 **본문 사각 안에 묶는다**. 가로 스크롤로 왼쪽/오른쪽 밖에 있는 자리는 그 변에 붙는다 —
/// 사각 밖 좌표를 그대로 내면 호출자가 화면 밖에 상자를 띄운다.
pub fn bodyAnchor(
    geom: Geometry,
    rows: []const visual_map.VisualRow,
    row_lines: []const u32,
    lines: []const []const u8,
    line: usize,
    byte_in_line: usize,
) ?Anchor {
    if (rows.len == 0) return null;
    if (row_lines.len < rows.len) return null; // 두 축이 갈린 상태 — `bodyPoint` 와 같은 거절
    if (line >= lines.len) return null;
    if (line > std.math.maxInt(u32)) return null; // 아래 대조가 u32 축이다

    // 그 줄의 행 중 이 byte 를 담은 행. 랩이면 여럿이고, 없으면 화면 밖이다.
    var row_i: ?usize = null;
    for (rows, 0..) |v, i| {
        if (row_lines[i] != @as(u32, @intCast(line))) continue;
        if (row_i == null) {
            row_i = i; // 그 줄의 첫 조각 — byte 가 그보다 앞이면(있을 수 없다) 여기다
            if (v.start_byte == 0) continue;
        }
        if (v.start_byte <= byte_in_line) row_i = i;
    }
    const idx = row_i orelse return null;
    const v = rows[idx];

    const text = lines[line];
    var one = [_]u32{@intCast(@min(byte_in_line, text.len))};
    var out = [_]u32{0};
    // **화면 오른쪽 끝에서 멈춘다.** 이 함수는 프레임마다 불리고(상자가 떠 있는 동안), 걸음은
    // `offset` 에 비례한다 — 한 줄이 수 MB 인 minified 파일에서 끝 쪽을 고르면 **매 프레임 그
    // 줄을 통째로 훑는다**. 상한을 주어도 답이 안 바뀌는 이유는 아래 clamp 다: 오른쪽 변 너머는
    // 어차피 변에 묶이므로, 그 너머의 정확한 열을 알 필요가 없다(`columnsAtOffsets` 는 멈춘 열을
    // 남은 자리에 채운다). `expandTabs` 가 같은 이유로 같은 상한을 쓴다.
    const stop_col: u32 = v.start_col +| @as(u32, geom.content_width) +| 1;
    content.columnsAtOffsets(text, geom.tab_width, &one, &out, stop_col);
    const col = out[0];

    // 행 안에서 몇 칸째인가. 앞 조각/가로 스크롤 밖이면 0 칸(왼쪽 변).
    const in_row: u32 = if (col > v.start_col) col - v.start_col else 0;
    const max_col: u32 = if (geom.content_width > 0) geom.content_width - 1 else 0;
    const clamped: u32 = @min(in_row, max_col);

    return .{
        .row = idx,
        .x_px = geom.body_x + @as(i32, @intCast(geom.content_left_px)) +
            @as(i32, @intCast(clamped * geom.cell_w_px)),
        .y_px = geom.body_y + @as(i32, @intCast(idx)) * @as(i32, geom.cell_h_px),
    };
}

test "bodyAnchor: bodyPoint 의 역 — 같은 기하에서 찍은 자리로 돌아온다" {
    var buf: [8]visual_map.VisualRow = undefined;
    const rows = fixtureRows(3, &buf);
    const row_lines = [_]u32{ 0, 1, 2 };
    const lines = [_][]const u8{ "aaaa", "bbbb", "cccc" };
    const g = Geometry{ .body_x = 10, .body_y = 20, .content_left_px = 40, .content_width = 80, .cell_w_px = 9, .cell_h_px = 19, .tab_width = 4 };

    const a = bodyAnchor(g, rows, &row_lines, &lines, 1, 2) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), a.row);
    // 그 좌표를 다시 찍으면 같은 자리다.
    const p = bodyPoint(g, rows, &row_lines, &lines, @floatFromInt(a.x_px), @floatFromInt(a.y_px)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), p.line);
    try testing.expectEqual(@as(usize, 2), p.byte_in_line);
}

test "bodyAnchor: 안 그려진 줄은 null — 스크롤로 벗어난 자리에 띄우지 않는다" {
    var buf: [8]visual_map.VisualRow = undefined;
    const rows = fixtureRows(2, &buf);
    const row_lines = [_]u32{ 10, 11 }; // 화면은 10·11 줄만 그렸다
    var lines_buf: [20][]const u8 = undefined;
    for (&lines_buf) |*l| l.* = "filler";
    const g = Geometry{ .body_x = 0, .body_y = 0, .content_left_px = 0, .content_width = 80, .cell_w_px = 9, .cell_h_px = 19, .tab_width = 4 };
    try testing.expect(bodyAnchor(g, rows, &row_lines, &lines_buf, 3, 0) == null);
    try testing.expect(bodyAnchor(g, rows, &row_lines, &lines_buf, 11, 0) != null);
    // 줄 표 밖(문서에 없는 줄)도 거절이다.
    try testing.expect(bodyAnchor(g, rows, &row_lines, &lines_buf, 999, 0) == null);
}

test "bodyAnchor: 탭은 탭스톱까지 센다 — 열 계산이 한 곳이라는 것" {
    var buf: [8]visual_map.VisualRow = undefined;
    const rows = fixtureRows(1, &buf);
    const row_lines = [_]u32{0};
    const lines = [_][]const u8{"\tx"};
    const g = Geometry{ .body_x = 0, .body_y = 0, .content_left_px = 0, .content_width = 80, .cell_w_px = 10, .cell_h_px = 19, .tab_width = 4 };
    // 탭 하나 뒤의 `x` 는 4 열이다(탭 폭 4). 셀 폭 10 이므로 40px.
    const a = bodyAnchor(g, rows, &row_lines, &lines, 0, 1) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 40), a.x_px);
}

test "bodyAnchor: 랩된 줄은 byte 를 담은 조각의 행이다" {
    var buf: [8]visual_map.VisualRow = undefined;
    // 한 논리 줄이 조각 셋으로 랩됐다(각 4 byte).
    buf[0] = .{ .line = 0, .piece = 0, .start_col = 0, .start_byte = 0, .start_byte_col = 0 };
    buf[1] = .{ .line = 0, .piece = 1, .start_col = 4, .start_byte = 4, .start_byte_col = 4 };
    buf[2] = .{ .line = 0, .piece = 2, .start_col = 8, .start_byte = 8, .start_byte_col = 8 };
    const rows = buf[0..3];
    const row_lines = [_]u32{ 0, 0, 0 };
    const lines = [_][]const u8{"abcdefghijkl"};
    const g = Geometry{ .body_x = 0, .body_y = 0, .content_left_px = 0, .content_width = 4, .cell_w_px = 10, .cell_h_px = 19, .tab_width = 4 };

    try testing.expectEqual(@as(usize, 0), bodyAnchor(g, rows, &row_lines, &lines, 0, 1).?.row);
    // **조각 경계의 byte 는 뒤 조각이다** — 앞 조각 오른쪽 끝에 띄우면 화면과 한 행 어긋난다.
    const b = bodyAnchor(g, rows, &row_lines, &lines, 0, 4) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), b.row);
    try testing.expectEqual(@as(i32, 0), b.x_px); // 그 조각의 0 열
    try testing.expectEqual(@as(usize, 2), bodyAnchor(g, rows, &row_lines, &lines, 0, 9).?.row);
}

test "bodyAnchor: 가로로 사각 밖이면 변에 묶는다" {
    var buf: [8]visual_map.VisualRow = undefined;
    const rows = fixtureRows(1, &buf);
    const row_lines = [_]u32{0};
    var long: [200]u8 = undefined;
    @memset(&long, 'z');
    const lines = [_][]const u8{&long};
    const g = Geometry{ .body_x = 0, .body_y = 0, .content_left_px = 0, .content_width = 10, .cell_w_px = 10, .cell_h_px = 19, .tab_width = 4 };
    // 190 열은 폭 10 칸 밖이다 — 오른쪽 변(9 칸)에 붙는다.
    const a = bodyAnchor(g, rows, &row_lines, &lines, 0, 190) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 90), a.x_px);
}

test "bodyAnchor: 가로로 굴린 화면에서도 보이는 자리를 가리킨다 (적대적 3회차)" {
    // **`start_col` 이 가로 스크롤을 함께 담는다**(랩이 꺼지면 조각이 하나이고 그 값이 곧 `first_col`
    // 이다 — `frame.paintBands` 가 같은 값을 같은 이유로 쓴다). 그 뺄셈이 빠지면 오른쪽으로 굴린
    // 화면에서 상자가 **굴린 칸 수만큼** 오른쪽으로 밀린다.
    var buf: [8]visual_map.VisualRow = undefined;
    buf[0] = .{ .line = 0, .piece = 0, .start_col = 10, .start_byte = 10, .start_byte_col = 10 };
    const rows = buf[0..1];
    const row_lines = [_]u32{0};
    var long: [40]u8 = undefined;
    @memset(&long, 'x');
    const lines = [_][]const u8{&long};
    const g = Geometry{ .body_x = 0, .body_y = 0, .content_left_px = 0, .content_width = 20, .cell_w_px = 10, .cell_h_px = 19, .tab_width = 4 };

    // 12 열은 화면의 **2 번째 칸**이다(10 열부터 보인다).
    const a = bodyAnchor(g, rows, &row_lines, &lines, 0, 12) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 20), a.x_px);
    // 굴린 자리보다 **앞**은 왼쪽 변에 붙는다(화면 밖을 가리키지 않는다).
    const before = bodyAnchor(g, rows, &row_lines, &lines, 0, 3) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 0), before.x_px);
}

test "bodyAnchor: 긴 줄에서도 답이 같다 — 상한은 걸음만 줄인다 (적대적 5회차)" {
    // 이 함수는 상자가 떠 있는 **매 프레임** 불리고 걸음은 `offset` 에 비례한다. 화면 오른쪽 끝에서
    // 멈추게 해도 답이 안 바뀌어야 그 상한이 정당하다 — 바뀌면 그것은 최적화가 아니라 결함이다.
    var buf: [8]visual_map.VisualRow = undefined;
    const rows = fixtureRows(1, &buf);
    const row_lines = [_]u32{0};
    var long: [200_000]u8 = undefined;
    @memset(&long, 'q');
    const lines = [_][]const u8{&long};
    const g = Geometry{ .body_x = 7, .body_y = 3, .content_left_px = 40, .content_width = 80, .cell_w_px = 9, .cell_h_px = 19, .tab_width = 4 };

    // 화면 **안**: 정확한 열이어야 한다(상한이 여기까지 오면 안 된다).
    const inside = bodyAnchor(g, rows, &row_lines, &lines, 0, 30) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 7 + 40 + 30 * 9), inside.x_px);
    // 화면 **밖**: 어느 쪽이든 오른쪽 변이다(79 칸).
    const far = bodyAnchor(g, rows, &row_lines, &lines, 0, 199_999) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 7 + 40 + 79 * 9), far.x_px);
    const nearer = bodyAnchor(g, rows, &row_lines, &lines, 0, 500) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(far.x_px, nearer.x_px); // 변 너머는 전부 같은 답이다
}
