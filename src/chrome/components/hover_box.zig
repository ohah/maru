//! 호버 박스 — 편집기 낱말 옆에 뜨는 **텍스트 블록 상자**(docs/native-editor-ui.md §8.3 · editor-surface-tooling §8.2b).
//!
//! 기하는 `popup_box`(앵커 아래, 안 들어가면 위로 뒤집고 workspace 로 당김)가 단일 출처이고 이 모듈은 **줄 배치와 자체 스크롤**만
//! 안다. 내용(줄)은 platform 이 만든다 — 진단 문장(i18n)과 서버 마크다운 축소(`session/editor/hover_text`)는 chrome 이 모르는 층이다.
//!
//! **모달이 아니다**(§8.2b 「모달 아님」) — 키를 가로채지 않고, 받는 포인터는 상자 안 휠뿐. `send_helper` 와 같은 자리
//! (`modalInputRole` = `.not_an_overlay`).
//!
//! 폭은 가장 긴 줄(EAW 표시폭) + 좌우 1칸, 상한 `max_cols`; 높이는 줄 수, 상한 `max_rows`. 넘치면 행 단위로 스크롤하고 긴 줄은
//! 상한 폭에서 자른다(랩 없음 — 시그니처는 한 줄로 읽히는 편이 낫다).

const std = @import("std");
const draw = @import("../draw.zig");
const props = @import("../props.zig");
const tokens = @import("../tokens.zig");
const popup_box = @import("popup_box.zig");
const overlay_input = @import("overlay_input.zig");

pub const layer = draw.Layer.modal;

/// 폭 상한(칸) — VS Code 기본 최대 폭(≈500px)과 같은 자릿수(§8.2b).
pub const max_cols: u32 = 80;
/// 높이 상한(행).
pub const max_rows: u32 = 12;
/// 좌우 패딩(칸).
pub const pad_cols: u32 = 1;

/// 한 줄의 색 역할. 진단 줄은 severity 색, 코드 줄은 본문 색, 그 밖은 약한 색이 아니라 본문 색이다(읽는 글이다).
pub const Line = struct {
    text: []const u8,
    role: tokens.ColorRole = .surface_fg,
    /// 줄 안의 **강조 구간**(byte 반열림) — 시그니처 힌트의 활성 파라미터(§8.2d). raster 는 run 마다 색만 내므로 색 role 로 강조한다.
    emphasis: ?Emphasis = null,

    /// 기본은 테마 accent(`accent_bar` — 탭 언더바·사이드바 활성 막대와 같은 색). `focus_accent`(사이드바 활성 배경)는 어두운 테마에서
    /// 회색이라 **덜** 강조돼 보였다(캡처 실측).
    pub const Emphasis = struct { lo: u32, hi: u32, role: tokens.ColorRole = .accent_bar };
};

pub const State = struct {
    open: bool = false,
    /// 앵커 셀(낱말 첫 글자)의 좌상단과 높이 — 상자는 그 **아래**에 선다(`below_flip_up`).
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,
    anchor_h: u32 = 0,
    /// 첫 보이는 줄(행 단위 스크롤).
    scroll_rows: u32 = 0,

    pub fn show(self: *State, x: i32, y: i32, h: u32) void {
        self.* = .{ .open = true, .anchor_x = x, .anchor_y = y, .anchor_h = h, .scroll_rows = 0 };
    }

    pub fn hide(self: *State) void {
        self.open = false;
        self.scroll_rows = 0;
    }

    /// 휠(행 단위) — 넘치는 줄이 있을 때만 움직인다. 움직였으면 true.
    pub fn scrollBy(self: *State, delta_rows: i32, line_count: usize) bool {
        const visible: usize = @min(line_count, max_rows);
        const max_off: u32 = @intCast(line_count - visible);
        const cur: i64 = self.scroll_rows;
        const next: i64 = std.math.clamp(cur + delta_rows, 0, @as(i64, max_off));
        if (next == cur) return false;
        self.scroll_rows = @intCast(next);
        return true;
    }
};

/// 상자 크기(칸·행) — 줄 목록에서. 빈 목록은 null.
pub const Size = struct { cols: u32, rows: u32 };
pub fn size(lines: []const Line) ?Size {
    if (lines.len == 0) return null;
    var widest: u32 = 0;
    for (lines) |l| widest = @max(widest, overlay_input.displayCols(l.text));
    return .{ .cols = @min(widest, max_cols) + 2 * pad_cols, .rows = @intCast(@min(lines.len, max_rows)) };
}

/// 상자 rect — `popup_box.below_flip_up` 으로 앵커 아래, 안 들어가면 위. 빈 목록·자리 없음이면 null.
pub fn boxRect(state: *const State, lines: []const Line, p: props.ChromeProps) ?draw.Rect {
    const sz = size(lines) orelse return null;
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    // **넓은 도메인에서 곱하고 좁힌다**(context_menu A46 과 같은 축).
    const w_wide: u64 = @as(u64, sz.cols) * @as(u64, cw);
    const h_wide: u64 = @as(u64, sz.rows) * @as(u64, ch);
    const box_w: u32 = @intCast(@min(w_wide, @as(u64, std.math.maxInt(u32))));
    const box_h: u32 = @intCast(@min(h_wide, @as(u64, std.math.maxInt(u32))));
    // **모달 quad 는 `modal_padding_px` 만큼 사방으로 커져 그려진다**(metal_lowering `appendModalQuad`). 그 padding 이 낱말 줄을
    // 덮지 않게 그만큼 띄운다 — 제품 캡처 실측: 12px 이 앵커 줄의 아래 2/3 를 가렸다. 위로 뒤집힐 때도 같은 간격이다.
    const placed = popup_box.place(box_w, box_h, .{
        .anchor = .{ .x = state.anchor_x, .y = state.anchor_y, .w = 0, .h = state.anchor_h },
        .vertical = .below_flip_up,
        .gap_px = p.shape.modal_padding_px,
    }, p) orelse return null;
    return .{ .x = placed.rect.x, .y = placed.rect.y, .w = box_w, .h = box_h };
}

/// 화면에 **보이는** 상자 — `boxRect` 를 모달 padding 만큼 키운 것. sticky 판정·휠 라우팅은 보이는 것을 기준으로 한다.
pub fn visibleRect(state: *const State, lines: []const Line, p: props.ChromeProps) ?draw.Rect {
    const r = boxRect(state, lines, p) orelse return null;
    const pad = p.shape.modal_padding_px;
    return r.outset(.{ .left = pad, .right = pad, .top = pad, .bottom = pad });
}

/// 포인터가 상자 안인가 — sticky 판정(§8.2b 「상자 위는 남는다」)과 휠 라우팅이 쓴다.
pub fn contains(state: *const State, lines: []const Line, p: props.ChromeProps, x_px: f64, y_px: f64) bool {
    if (!state.open or !std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return false;
    const rect = visibleRect(state, lines, p) orelse return false;
    const x0: f64 = @floatFromInt(rect.x);
    const y0: f64 = @floatFromInt(rect.y);
    return x_px >= x0 and x_px < x0 + @as(f64, @floatFromInt(rect.w)) and y_px >= y0 and y_px < y0 + @as(f64, @floatFromInt(rect.h));
}

/// 상한 폭에 맞춰 자른 줄(EAW 표시폭 기준, 글자 경계에서). 자를 것이 없으면 그대로.
pub fn clipLine(text: []const u8, cols: u32) []const u8 {
    if (overlay_input.displayCols(text) <= cols) return text;
    const utf8 = std.unicode.Utf8View.init(text) catch return text[0..@min(text.len, cols)];
    var it = utf8.iterator();
    var used: u32 = 0;
    var end: usize = 0;
    while (it.nextCodepointSlice()) |cp| {
        const w = overlay_input.displayCols(cp);
        if (used + w > cols) break;
        used += w;
        end += cp.len;
    }
    return text[0..end];
}

/// 배경 quad + 테두리 + 보이는 줄 텍스트. 안 열렸거나 줄이 없으면 무동작. 순수: state·lines·props 만 읽는다.
pub fn view(
    state: *const State,
    lines: []const Line,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    _ = tk;
    if (!state.open) return;
    const rect = boxRect(state, lines, p) orelse return;
    const cw = @max(p.metrics.cell_width_px, 1);
    const ch = @max(p.metrics.cell_height_px, 1);
    const bg_r = p.shape.corner_radius_px;
    const bw = p.shape.border_width_px;
    try out.append(arena, .{ .quad = .{ .rect = rect, .fill_role = .surface_bg, .corner_radii = .{ bg_r, bg_r, bg_r, bg_r }, .border_widths = .{ bw, bw, bw, bw }, .border_role = .focus_accent } });
    const visible: usize = @min(lines.len, max_rows);
    const first: usize = @min(state.scroll_rows, lines.len - visible);
    const inner_cols: u32 = @intCast(@max(rect.w / cw, 2 * pad_cols) - 2 * pad_cols);
    for (lines[first .. first + visible], 0..) |l, i| {
        if (l.text.len == 0) continue;
        const row_y = rect.y + @as(i32, @intCast(i)) * @as(i32, @intCast(ch));
        const shown = clipLine(l.text, inner_cols);
        // 강조 구간이 잘린 줄 안에 온전히 들면 run 셋(앞·강조·뒤), 아니면 run 하나 — 잘린 자리에 걸치면 강조하지 않는다(반쪽 강조는 오독).
        const runs = if (l.emphasis) |e| blk: {
            if (e.lo < e.hi and e.hi <= shown.len) {
                const r = try arena.alloc(draw.Run, 3);
                r[0] = .{ .text = shown[0..e.lo] };
                r[1] = .{ .text = shown[e.lo..e.hi], .role = e.role };
                r[2] = .{ .text = shown[e.hi..] };
                break :blk r;
            }
            const r = try arena.alloc(draw.Run, 1);
            r[0] = .{ .text = shown };
            break :blk r;
        } else blk: {
            const r = try arena.alloc(draw.Run, 1);
            r[0] = .{ .text = shown };
            break :blk r;
        };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + @as(i32, @intCast(cw * pad_cols)), .y = row_y }, .runs = runs, .role = l.role } });
    }
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testProps() props.ChromeProps {
    return .{ .metrics = .{ .cell_width_px = 10, .cell_height_px = 20, .sidebar_width_px = 0, .backing_width_px = 1200, .backing_height_px = 800 } };
}

fn testTokens() tokens.Tokens {
    const Rgb = @import("../../color.zig").Rgb;
    return .{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
}

test "HOVX1 크기 — 가장 긴 줄 + 좌우 1칸, 폭 80·높이 12 상한; 긴 줄은 글자 경계에서 잘린다 (§8.2b)" {
    const short = [_]Line{ .{ .text = "int x" }, .{ .text = "가나다" } };
    const s = size(&short).?;
    try testing.expectEqual(@as(u32, 6 + 2), s.cols); // 가나다 = 6칸
    try testing.expectEqual(@as(u32, 2), s.rows);
    var long_buf: [200]u8 = undefined;
    @memset(&long_buf, 'x');
    var many: [20]Line = undefined;
    for (&many) |*l| l.* = .{ .text = &long_buf };
    const m = size(&many).?;
    try testing.expectEqual(max_cols + 2, m.cols);
    try testing.expectEqual(max_rows, m.rows);
    try testing.expectEqual(@as(usize, 80), clipLine(&long_buf, 80).len);
    try testing.expectEqualStrings("가나", clipLine("가나다", 5)); // 5칸에 2칸 글자 셋은 안 든다 — 둘
    try testing.expectEqualStrings("ab", clipLine("ab", 80));
    try testing.expect(size(&.{}) == null);
}

test "HOVX2 스크롤 — 넘치는 만큼만, 보이는 줄은 scroll_rows 부터 12줄; contains 는 boxRect 그대로" {
    var st: State = .{};
    st.show(100, 100, 20);
    var many: [15]Line = undefined;
    for (&many, 0..) |*l, i| l.* = .{ .text = if (i % 2 == 0) "even" else "odd" };
    try testing.expect(st.scrollBy(1, many.len));
    try testing.expect(st.scrollBy(10, many.len));
    try testing.expectEqual(@as(u32, 3), st.scroll_rows); // 15 - 12
    try testing.expect(!st.scrollBy(1, many.len));
    try testing.expect(st.scrollBy(-100, many.len));
    try testing.expectEqual(@as(u32, 0), st.scroll_rows);
    const two = [_]Line{ .{ .text = "a" }, .{ .text = "b" } };
    try testing.expect(!st.scrollBy(1, two.len)); // 안 넘치면 안 움직인다
    var p = testProps();
    p.shape.modal_padding_px = 12;
    const rect = boxRect(&st, &many, p).?;
    try testing.expectEqual(@as(u32, 12 * 20), rect.h);
    try testing.expectEqual(@as(i32, 120 + 12), rect.y); // 앵커(100, h 20) 아래 + 모달 padding — 보이는 상자가 앵커 줄에 닿지 않는다
    try testing.expectEqual(@as(i32, 120), visibleRect(&st, &many, p).?.y);
    try testing.expect(contains(&st, &many, p, @floatFromInt(rect.x - 6), @floatFromInt(rect.y - 6))); // padding 띠도 상자다
    try testing.expect(contains(&st, &many, p, @floatFromInt(rect.x + 1), @floatFromInt(rect.y + 1)));
    try testing.expect(!contains(&st, &many, p, @floatFromInt(rect.x - 13), @floatFromInt(rect.y + 1))); // padding 밖은 아니다
    st.hide();
    try testing.expect(!contains(&st, &many, p, @floatFromInt(rect.x + 1), @floatFromInt(rect.y + 1)));
}

test "HOVX4 강조 구간 — run 셋(앞·강조·뒤)으로 갈라 강조 run 만 role 이 다르다; 잘린 자리에 걸치면 강조하지 않는다 (§8.2d)" {
    const p = testProps();
    var st: State = .{};
    st.show(100, 100, 20);
    const one = [_]Line{.{ .text = "int add(int a, int b)", .emphasis = .{ .lo = 8, .hi = 13 } }};
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ops: std.ArrayList(draw.Op) = .empty;
    const tk = testTokens();
    try view(&st, &one, p, &tk, arena, &ops);
    for (ops.items) |op| if (op == .text) {
        try testing.expectEqual(@as(usize, 3), op.text.runs.len);
        try testing.expectEqualStrings("int add(", op.text.runs[0].text);
        try testing.expectEqualStrings("int a", op.text.runs[1].text);
        try testing.expectEqual(tokens.ColorRole.accent_bar, op.text.runs[1].role.?);
        try testing.expect(op.text.runs[0].role == null and op.text.runs[2].role == null);
        try testing.expectEqualStrings(", int b)", op.text.runs[2].text);
    };
    // 상한 폭에서 잘려 강조 구간이 걸치면 run 하나 — 반쪽 강조를 내지 않는다.
    var long_buf: [120]u8 = undefined;
    @memset(&long_buf, 'x');
    const long = [_]Line{.{ .text = &long_buf, .emphasis = .{ .lo = 70, .hi = 100 } }};
    var ops2: std.ArrayList(draw.Op) = .empty;
    try view(&st, &long, p, &tk, arena, &ops2);
    for (ops2.items) |op| if (op == .text) try testing.expectEqual(@as(usize, 1), op.text.runs.len);
}

test "HOVX3 view — 배경 하나 + 빈 줄을 뺀 텍스트 op, 스크롤한 만큼 건너뛴다, 화면 아래면 위로 뒤집힌다" {
    const p = testProps();
    var st: State = .{};
    st.show(100, 100, 20);
    var many: [15]Line = undefined;
    for (&many, 0..) |*l, i| l.* = .{ .text = if (i == 1) "" else "line", .role = if (i == 0) .diagnostic_error else .surface_fg };
    _ = st.scrollBy(2, many.len);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ops: std.ArrayList(draw.Op) = .empty;
    const tk = testTokens();
    try view(&st, &many, p, &tk, arena, &ops);
    var quads: usize = 0;
    var texts: usize = 0;
    for (ops.items) |op| switch (op) {
        .quad => quads += 1,
        .text => texts += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), quads);
    try testing.expectEqual(@as(usize, 12), texts); // 2..14 — 빈 줄(1)은 이미 지나갔다
    // 첫 텍스트 op 는 세 번째 줄(scroll 2)이고 색은 본문 색이다(진단 줄 0 은 지나갔다).
    for (ops.items) |op| if (op == .text) {
        try testing.expectEqual(tokens.ColorRole.surface_fg, op.text.role);
        break;
    };
    // 화면 아래쪽 앵커 → **위로 뒤집힌다**(아래로 당기는 것이 아니다 — 당기면 상자가 앵커 줄을 덮는다, 변이 B4). 앵커 700 에
    // 12행(240px) 상자: 아래는 안 들어가고(700+20+240 > 780), 당기면 540..780 이 앵커를 덮는다. 뒤집으면 앵커 위 padding 간격을 두고 끝난다.
    var pp = p;
    pp.shape.modal_padding_px = 12;
    st.show(100, 700, 20);
    const rect = boxRect(&st, &many, pp).?;
    try testing.expectEqual(@as(i32, 700 - 240 - 12), rect.y);
    try testing.expect(rect.y + @as(i32, @intCast(rect.h)) + 12 <= 700);
    // 닫히면 아무것도 안 낸다.
    st.hide();
    var none: std.ArrayList(draw.Op) = .empty;
    try view(&st, &many, p, &tk, arena, &none);
    try testing.expectEqual(@as(usize, 0), none.items.len);
}
