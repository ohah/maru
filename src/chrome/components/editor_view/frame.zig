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
const content = @import("content.zig");
const geometry = @import("geometry.zig");
const gutter = @import("gutter.zig");
const scrollbar = @import("scrollbar.zig");
const surface = @import("surface.zig");
const visual_map = @import("visual_map.zig");
const scroll_area = @import("../../ui/scroll_area.zig");

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
    /// 문서 전체의 **시각 행** 수를 이미 알고 있으면 여기 넣는다. `null`이면 `lines`를 훑어 센다 —
    /// 줄당 전개가 들어가므로 큰 문서에서는 호출자가 캐시한 값을 주는 편이 낫다(§2 L2 캐시).
    total_visual_rows: ?u32 = null,
    /// 그릴 수 있는 시각 행 수(뷰포트 높이 / 셀 높이).
    visible_rows: u16,
    wrap: bool,
    tab_width: u8 = 4,

    /// 뷰 전체가 차지하는 픽셀 사각. 배경이 이것을 덮는다(§4.1b).
    rect: draw.Rect,
    cell_w_px: u16,
    cell_h_px: u16,
    font_px: u16,
    /// 본문이 쓸 수 있는 열 수. 스크롤바 gutter를 뺀 값을 호출자가 준다.
    total_cols: u16,
    /// 스크롤바가 설 오른쪽 여백(px).
    scrollbar_gutter_px: u32,
    metrics: scroll_area.ScrollbarMetrics,
};

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
    const bg = surface.build(.{ .rect = props.rect }, scratch.ops);

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
        break :blk sum;
    };

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
        .first_visual_row = @intCast(@min(props.first_line, std.math.maxInt(u32))),
        .cell_h_px = props.cell_h_px,
        .metrics = props.metrics,
    }, scratch.ops[bg.ops + cw.ops + gw.ops ..]);

    return .{
        .ops = bg.ops + cw.ops + gw.ops + sw.ops,
        .visual_rows = cw.visual_rows,
        .truncated = cw.truncated_rows > 0 or gw.dropped_rows > 0,
        .scrollbar = sw.geometry,
    };
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
