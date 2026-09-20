//! 자동완성 **문서 패널**(docs/editor-surface-tooling.md §8.2g-d) — 목록 상자(`suggest_box`) **옆**에 서는 줄 상자. 내용(줄)은 platform 이
//! 만든다(강조 항목의 `detail` 줄 + 빈 줄 + `documentation` 을 `hover_text.reduce` 로 — chrome 이 모르는 층). 줄 배치·크기·행 스크롤은
//! `hover_box` 의 것을 그대로 쓰고(`hover_box.size`·`viewAt`), 자리만 다르다 — `popup_box.placeBeside`(오른쪽 → 왼쪽 → 아래 → 위).
//!
//! **모달이 아니다** — 키를 가로채지 않고(`⌃Space` 토글은 platform 의 일), 받는 포인터는 패널 안 휠뿐.
const std = @import("std");
const draw = @import("../draw.zig");
const props = @import("../props.zig");
const tokens = @import("../tokens.zig");
const popup_box = @import("popup_box.zig");
const hover_box = @import("hover_box.zig");
const suggest_box = @import("suggest_box.zig");

pub const layer = suggest_box.layer;
pub const Line = hover_box.Line;
/// 목록 상자와의 간격(칸).
pub const gap_cols: u32 = 1;

pub const State = struct {
    /// 펼침 — 목록이 닫혀도 남는다(§8.2g-d 「세션 동안 기억」). 그릴지는 `open and lines.len > 0` 에 목록 상자가 열려 있는가까지.
    expanded: bool = false,
    scroll_rows: u32 = 0,

    pub fn toggle(self: *State) void {
        self.expanded = !self.expanded;
        self.scroll_rows = 0;
    }
    /// 휠(행 단위) — 넘치는 줄이 있을 때만. 움직였으면 true.
    pub fn scrollBy(self: *State, delta_rows: i32, line_count: usize) bool {
        const visible: usize = @min(line_count, hover_box.max_rows);
        const max_off: u32 = @intCast(line_count - visible);
        const cur: i64 = self.scroll_rows;
        const next: i64 = std.math.clamp(cur + delta_rows, 0, @as(i64, max_off));
        if (next == cur) return false;
        self.scroll_rows = @intCast(next);
        return true;
    }
};

/// 패널 rect — 목록 상자 `beside` 옆. 펼치지 않았거나 줄이 없거나 자리가 없으면 null.
pub fn boxRect(state: *const State, lines: []const Line, beside: draw.Rect, p: props.ChromeProps) ?draw.Rect {
    if (!state.expanded) return null;
    const sz = hover_box.size(lines) orelse return null;
    const cw = @max(p.metrics.cell_width_px, 1);
    const ch = @max(p.metrics.cell_height_px, 1);
    const placed = popup_box.placeBeside(sz.cols * cw, sz.rows * ch, beside, gap_cols * cw, p) orelse return null;
    return placed.rect;
}

pub fn contains(state: *const State, lines: []const Line, beside: draw.Rect, p: props.ChromeProps, x_px: f64, y_px: f64) bool {
    const r = boxRect(state, lines, beside, p) orelse return false;
    return x_px >= @as(f64, @floatFromInt(r.x)) and x_px < @as(f64, @floatFromInt(r.x)) + @as(f64, @floatFromInt(r.w)) and
        y_px >= @as(f64, @floatFromInt(r.y)) and y_px < @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h));
}

pub fn view(state: *const State, lines: []const Line, beside: draw.Rect, p: props.ChromeProps, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    const rect = boxRect(state, lines, beside, p) orelse return;
    try hover_box.viewAt(rect, lines, state.scroll_rows, p, arena, out);
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testProps() props.ChromeProps {
    return .{ .metrics = .{ .cell_width_px = 10, .cell_height_px = 20, .sidebar_width_px = 0, .backing_width_px = 1200, .backing_height_px = 800 } };
}

test "SGD1 문서 패널 — 펼쳐야 서고, 목록 상자 오른쪽 한 칸 옆 위 맞춤, 크기는 hover_box 규칙, 줄은 rect 안에, 휠은 넘칠 때만, 자리 없으면 왼쪽 (§8.2g-d)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = testProps();
    const beside = draw.Rect{ .x = 300, .y = 200, .w = 400, .h = 60 };
    const lines = [_]Line{ .{ .text = "fn lazy() -> i32" }, .{ .text = "" }, .{ .text = "Lazy import." } };
    var st = State{};
    try testing.expect(boxRect(&st, &lines, beside, p) == null); // 접혀 있다
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&st, &lines, beside, p, arena, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    st.toggle();
    const r = boxRect(&st, &lines, beside, p).?;
    try testing.expectEqual(@as(i32, 300 + 400 + 10), r.x); // 오른쪽, 간격 1칸
    try testing.expectEqual(@as(i32, 200), r.y); // 위 맞춤
    try testing.expectEqual(@as(u32, (16 + 2) * 10), r.w); // 가장 긴 줄 16 + 좌우 1칸
    try testing.expectEqual(@as(u32, 3 * 20), r.h);
    try view(&st, &lines, beside, p, arena, &out);
    try testing.expectEqual(@as(usize, 1 + 2), out.items.len); // 테두리 quad + 빈 줄 뺀 텍스트 둘
    try testing.expect(out.items[0] == .quad);
    try testing.expectEqualStrings("fn lazy() -> i32", out.items[1].text.runs[0].text);
    try testing.expectEqual(r.y + 2 * 20, out.items[2].text.origin.y); // 셋째 줄
    try testing.expect(contains(&st, &lines, beside, p, 720, 210));
    try testing.expect(!contains(&st, &lines, beside, p, 700, 210));
    // 휠 — 세 줄은 안 넘친다.
    try testing.expect(!st.scrollBy(1, lines.len));
    var many: [20]Line = undefined;
    for (&many, 0..) |*l, i| l.* = .{ .text = if (i % 2 == 0) "a" else "b" };
    try testing.expect(st.scrollBy(1, many.len));
    try testing.expectEqual(@as(u32, 1), st.scroll_rows);
    try testing.expect(!st.scrollBy(100, many.len) or st.scroll_rows == 8); // 20 - 12
    try testing.expect(st.scrollBy(-100, many.len)); // 위로는 0 에서 묶인다(적대적 5회차 C10)
    try testing.expectEqual(@as(u32, 0), st.scroll_rows);
    try testing.expect(!st.scrollBy(-1, many.len));
    // 스크롤 값이 넘쳐도 그리기는 마지막 창을 보인다(적대적 5회차 C5 — 직접 세운 값도 묶는다).
    st.scroll_rows = 100;
    var out3: std.ArrayList(draw.Op) = .empty;
    try view(&st, &many, beside, p, arena, &out3);
    try testing.expectEqual(@as(usize, 1 + 12), out3.items.len);
    try testing.expectEqualStrings("a", out3.items[1].text.runs[0].text); // 20 - 12 = 8 번째부터(짝수 → a)
    st.toggle(); // 접으면 스크롤도 0
    try testing.expectEqual(@as(u32, 0), st.scroll_rows);
    st.toggle();
    // 오른쪽 경계는 밖이다(적대적 5회차 C7).
    try testing.expect(!contains(&st, &lines, beside, p, @floatFromInt(r.x + @as(i32, @intCast(r.w))), 210));
    try testing.expect(contains(&st, &lines, beside, p, @floatFromInt(r.x + @as(i32, @intCast(r.w)) - 1), 210));
    // 폭 상한 80(hover_box 규칙 — 적대적 5회차 C8).
    var long_buf: [120]u8 = undefined;
    @memset(&long_buf, 'x');
    const wide = [_]Line{.{ .text = &long_buf }};
    try testing.expectEqual(@as(u32, (80 + 2) * 10), boxRect(&st, &wide, beside, p).?.w);
    // 오른쪽에 자리가 없으면 왼쪽.
    const right_edge = draw.Rect{ .x = 1000, .y = 200, .w = 150, .h = 60 };
    const l = boxRect(&st, &lines, right_edge, p).?;
    try testing.expectEqual(@as(i32, 1000 - 10 - 180), l.x);
}
