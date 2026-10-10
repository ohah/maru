//! 자동완성 목록 상자(docs/editor-surface-tooling.md §8.2g · §8.2g-e · native-editor-ui §8.2) — 낱말 첫 글자 셀 **아래**(안 들어가면 위)에
//! 뜨는 창 행 목록. 기하는 `popup_box`(호버 상자와 같은 규율), 이 모듈은 **행 배치·창(상한 10행)·선택 강조·kind 아이콘·일치 글자·두 열(label·detail)** 만
//! 안다. 항목은 platform 이 만든다(필터·정렬·일치 자리는 `session/lsp/completion`).
//!
//! 키는 여기서 가로채지 않는다 — 규칙 3(ui §8: `↑↓`/`Enter`/`Tab`/`Esc` 만 소비, 나머지는 편집기로)은 platform 의 편집기 키 경로가 든다.
//! `modalInputRole` 에는 `.not_an_overlay` 로 선다(호버 상자와 같은 자리).
//!
//! **디자인 시스템 목록**(§8.2g-e, 2026-10-10) — 우클릭 메뉴·팔레트와 같은 가족이되 **촘촘하다**(VS Code 의 suggest 위젯 — `suggest.css`, MIT,
//! 동작·치수만): 첫 op 는 **직각 패널 quad**(surface_bg + focus_accent 테두리 · 그림자 — `independent_panel` 이라 모서리 0 이어도 GPU 패널)이고,
//! 패딩은 메뉴의 12px 가 아니라 **테두리 폭**이라 행이 테두리에 붙는다(`panelPadding` → `Quad.panel_padding_px`). 선택 행은 **폭 가득** 셀 배경으로
//! 칠한다(tab_active_bg `.fill`). 나머지 행은 배경이 없다. **모서리를 두지 않는다** — 1배율에서 1px 테두리 + 둥근 모서리는 안티에일리어싱으로
//! 번져 경계선이 흐렸고, 촘촘한 목록에는 둥근 모서리가 쓸모가 없었다(사용자 지적 2026-10-10).
//! 행 = kind 아이콘(2칸, kind 색) · 간격 · label(일치 글자는 accent) + 꼬리 · … · 오른쪽 · 우패딩.

const std = @import("std");
const icons = @import("../../icons.zig");
const draw = @import("../draw.zig");
const props = @import("../props.zig");
const tokens = @import("../tokens.zig");
const icon = @import("../ui/icon.zig");
const popup_box = @import("popup_box.zig");
const overlay_input = @import("overlay_input.zig");
const text_layout = @import("../text_layout.zig");

pub const layer = draw.Layer.modal;
/// 패널이 직각이라 lowering 이 「모서리 0 인 첫 quad 도 GPU 패널로」 치게 한다(`draw.ChromeDraw.independent_panel` — 그림자·테두리·패딩).
/// 이 draw 를 내는 곳(`ChromeHost.collectSuggestBoxDraws`·Chrome Lab)이 이 값을 싣는다.
pub const independent_panel = true;

/// 창 높이 상한(행) — VS Code 기본 12 와 같은 자릿수.
pub const max_rows: u32 = 10;
/// 폭 상한(칸).
pub const max_cols: u32 = 60;
/// label 과 detail 사이 최소 간격(칸).
pub const gap_cols: u32 = 2;
/// kind 아이콘이 서는 열 — 맨 앞(VS Code 는 행 안쪽 2px 뒤 16px 아이콘; 우리 아이콘은 SVG 안쪽 여백이 그 몫이다).
pub const icon_col: u32 = 0;
/// kind 아이콘 열(칸) — 등록 SVG 아이콘은 2칸이다(`ui.icon.chrome_run_span`, `wide_icons`).
pub const icon_cols: u32 = icon.chrome_run_span;
/// label 이 시작하는 열 — 아이콘 · 간격 1(VS Code 아이콘 뒤 4px — 칸 격자의 최소 단위가 한 칸이다).
pub const label_col: u32 = icon_col + icon_cols + 1;
/// 오른쪽 열 뒤 우패딩(칸) — VS Code 행의 `padding-right: 10px` 자리.
pub const right_pad_cols: u32 = 1;
/// label·오른쪽 밖의 고정 칸(label 앞 + 우패딩).
pub const chrome_cols: u32 = label_col + right_pad_cols;

/// 패널이 행 rect 보다 사방으로 큰 폭 — **테두리 폭**(VS Code 처럼 행이 테두리 바로 안에 붙는다; 메뉴의 `modal_padding_px` 12 는 촘촘한 목록에
/// 너무 컸다 — 사용자 지적 2026-10-10). lowering(`Quad.panel_padding_px`)·배치(`visible_outset_px`)·포인터(`visibleRect`)·문서 패널 간격이 이 값 하나를 쓴다.
pub fn panelPadding(p: props.ChromeProps) u16 {
    return p.shape.border_width_px;
}

pub const Row = struct {
    label: []const u8,
    /// 오른쪽 열(옅게, 우측 정렬) — 제품은 `labelDetails.description` 이 있으면 그것, 없으면 `detail` 을 싣는다(§8.2g-c).
    detail: []const u8 = "",
    /// label 바로 뒤에 간격 없이 붙는 꼬리(옅게) — `labelDetails.detail`(§8.2g-c).
    label_detail: []const u8 = "",
    /// kind 글자(§8.2g-b, `completion.kindGlyph`) — label 앞 아이콘 열이 이것으로 아이콘과 색을 고른다(`kindStyle`). 모르는 글자면 빈 칸.
    kind: u8 = ' ',
    /// 치는 접두사가 맞춘 **label 의 바이트 자리**(오름차순, `completion.matchPositions`) — 그 글자를 accent 로(§8.2g-e). 빈 것은 강조 없음.
    match: []const u32 = &.{},
};

/// kind 글자 → 아이콘과 색(§8.2g-e). 색은 구문 강조와 같은 뜻의 역할 — 함수는 함수 색, 타입은 타입 색. 모양이 kind 를 가르므로 색은 가족만 맞춘다
/// (변수·속성은 같은 색). 버퍼 단어는 확신이 낮은 후보라 옅게.
pub const KindStyle = struct { icon: icons.Icon, role: tokens.ColorRole };

pub fn kindStyle(kind: u8) ?KindStyle {
    return switch (kind) {
        'f' => .{ .icon = .kind_function, .role = .syntax_function },
        'v' => .{ .icon = .kind_variable, .role = .syntax_property },
        't' => .{ .icon = .kind_type, .role = .syntax_type_name },
        'k' => .{ .icon = .kind_keyword, .role = .syntax_keyword },
        'm' => .{ .icon = .kind_module, .role = .syntax_tag },
        's' => .{ .icon = .kind_snippet, .role = .syntax_string },
        'p' => .{ .icon = .kind_property, .role = .syntax_property },
        'w' => .{ .icon = .kind_word, .role = .muted_fg },
        else => null,
    };
}

/// 넘칠 때 오른쪽 열이 이 아래로는 안 접힌다(§8.2g-c 「접기」) — 오른쪽이 이보다 짧으면 그 길이까지.
pub const right_min_cols: u32 = 16;
/// 상자가 그 문턱보다도 좁을 때 label 이 최소로 지키는 칸(§8.2g-c) — label 은 고르는 대상이라 0 이 되면 안 된다.
pub const label_min_cols: u32 = 4;

/// 한 행이 `usable` 칸(패딩·kind·간격 뺀 뒤)에 들어가도록 접은 결과(§8.2g-c): 오른쪽 → label_detail → label 순.
pub const Fold = struct { label: u32, label_detail: u32, right: u32 };

pub fn fold(label_w: u32, label_detail_w: u32, right_w: u32, usable: u32) Fold {
    const left_w = label_w + label_detail_w;
    var right: u32 = 0;
    var left_room: u32 = usable;
    if (right_w > 0) {
        // 오른쪽에 남는 칸(간격 2 뒤) — 넘치면 문턱까지만 접는다.
        const spare = usable -| gap_cols -| left_w;
        right = @min(right_w, @max(spare, right_min_cols)); // 바깥 @min 이 짧은 오른쪽을 이미 묶는다(적대적 1회차 A9: 안쪽 @min 은 등가라 뺐다)
        right = @min(right, usable -| gap_cols -| @min(label_w, label_min_cols)); // 상자가 문턱보다도 좁으면 label 몫을 남기고 있는 만큼
        left_room = usable -| gap_cols -| right;
    }
    const ld = if (left_w <= left_room) label_detail_w else @min(label_detail_w, left_room -| label_w);
    const label = @min(label_w, left_room);
    return .{ .label = label, .label_detail = ld, .right = right };
}

pub const State = struct {
    open: bool = false,
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,
    anchor_h: u32 = 0,
    selected: usize = 0,
    /// 창의 첫 행 — `windowStart` 로 선택을 따른다.
    scroll: usize = 0,

    pub fn show(self: *State, x: i32, y: i32, h: u32) void {
        self.* = .{ .open = true, .anchor_x = x, .anchor_y = y, .anchor_h = h };
    }

    pub fn hide(self: *State) void {
        self.open = false;
        self.selected = 0;
        self.scroll = 0;
    }

    /// 앵커만 갱신(프레임마다 다시 잰다 — 스크롤·랩이 바뀌면 자리가 바뀐다).
    pub fn moveAnchor(self: *State, x: i32, y: i32, h: u32) void {
        self.anchor_x = x;
        self.anchor_y = y;
        self.anchor_h = h;
    }

    /// 선택 이동 — **wrap 한다**(VS Code 의 suggest 목록은 끝에서 처음으로 돈다 — `editor.suggest` 는 `loop` 기본). 창은 따라온다.
    pub fn move(self: *State, delta: i64, count: usize) void {
        if (count == 0) return;
        const n: i64 = @intCast(count);
        const cur: i64 = @intCast(@min(self.selected, count - 1));
        self.selected = @intCast(@mod(cur + delta, n));
        self.scroll = overlay_input.windowStart(count, max_rows, self.selected, self.scroll);
    }

    /// 목록이 갈아 끼워졌다 — 선택을 `sel` 로 두고 창을 다시 맞춘다.
    pub fn reset(self: *State, sel: usize, count: usize) void {
        self.selected = if (count == 0) 0 else @min(sel, count - 1);
        self.scroll = overlay_input.windowStart(count, max_rows, self.selected, 0);
    }
};

pub const Size = struct { cols: u32, rows: u32, label_cols: u32 };

/// 폭 = 아이콘 2 + 간격 1 + 가장 긴 (label + label_detail) + (오른쪽이 있으면 간격 2 + 가장 긴 오른쪽) + 우패딩 1, 상한 `max_cols`;
/// 높이 = min(행 수, 10).
pub fn size(rows: []const Row) ?Size {
    if (rows.len == 0) return null;
    var label_w: u32 = 0;
    var detail_w: u32 = 0;
    for (rows) |r| {
        label_w = @max(label_w, overlay_input.displayCols(r.label) + overlay_input.displayCols(r.label_detail));
        detail_w = @max(detail_w, overlay_input.displayCols(r.detail));
    }
    const want: u64 = @as(u64, label_w) + chrome_cols + (if (detail_w > 0) @as(u64, gap_cols + detail_w) else 0);
    return .{ .cols = @intCast(@min(want, @as(u64, max_cols))), .rows = @intCast(@min(rows.len, max_rows)), .label_cols = label_w };
}

/// 행이 서는 rect(칸 격자) — 클릭·문서 패널 자리·판정이 이것을 쓴다. **보이는** 패널은 이보다 사방 `panelPadding` 크다(`visibleRect`).
pub fn boxRect(state: *const State, rows: []const Row, p: props.ChromeProps) ?draw.Rect {
    if (!state.open) return null;
    const sz = size(rows) orelse return null;
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    const w_wide: u64 = @as(u64, sz.cols) * @as(u64, cw);
    const h_wide: u64 = @as(u64, sz.rows) * @as(u64, ch);
    const box_w: u32 = @intCast(@min(w_wide, @as(u64, std.math.maxInt(u32))));
    const box_h: u32 = @intCast(@min(h_wide, @as(u64, std.math.maxInt(u32))));
    // 패널 quad 는 사방 `panelPadding` 커져 그려진다(metal_lowering `appendModalQuad` · `Quad.panel_padding_px`) — 앵커 줄과의 간격도, workspace
    // 경계 여백도 **보이는** 테두리에서 센다(hover_box 와 같은 규율 — `Placement.visible_outset_px`). 보이는 윗단이 앵커 줄 아랫단에 닿는다.
    const pad = panelPadding(p);
    const placed = popup_box.place(box_w, box_h, .{
        .anchor = .{ .x = state.anchor_x, .y = state.anchor_y, .w = 0, .h = state.anchor_h },
        .vertical = .below_flip_up,
        .gap_px = pad,
        .visible_outset_px = pad,
    }, p) orelse return null;
    return .{ .x = placed.rect.x, .y = placed.rect.y, .w = box_w, .h = box_h };
}

/// 화면에 **보이는** 패널 — `boxRect` 를 `panelPadding` 만큼 키운 것. 포인터가 이 안이면 목록의 것이다(테두리를 누르면 닫지 않고 삼킨다).
pub fn visibleRect(state: *const State, rows: []const Row, p: props.ChromeProps) ?draw.Rect {
    const r = boxRect(state, rows, p) orelse return null;
    const pad = panelPadding(p);
    return r.outset(.{ .left = pad, .right = pad, .top = pad, .bottom = pad });
}

pub fn contains(state: *const State, rows: []const Row, p: props.ChromeProps, x_px: f64, y_px: f64) bool {
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return false;
    const r = visibleRect(state, rows, p) orelse return false;
    const x0: f64 = @floatFromInt(r.x);
    const y0: f64 = @floatFromInt(r.y);
    return x_px >= x0 and x_px < x0 + @as(f64, @floatFromInt(r.w)) and y_px >= y0 and y_px < y0 + @as(f64, @floatFromInt(r.h));
}

/// 창에 보이는 행들 — `[scroll, scroll+rows)`.
pub fn visible(state: *const State, rows: []const Row) []const Row {
    const n: usize = @min(rows.len, max_rows);
    const start = @min(state.scroll, rows.len -| n);
    return rows[start .. start + n];
}

pub fn view(state: *const State, rows: []const Row, p: props.ChromeProps, _: *const tokens.Tokens, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    const rect = boxRect(state, rows, p) orelse return;
    const sz = size(rows) orelse return;
    const cw = @max(p.metrics.cell_width_px, 1);
    const ch = @max(p.metrics.cell_height_px, 1);
    const box_cols: u32 = rect.w / cw;
    const bw = p.shape.border_width_px;
    const pad = panelPadding(p);
    // 패널 — 이 draw 의 첫 quad(직각, `independent_panel`)라 lowering 이 패딩(테두리 폭)·그림자를 단다.
    try out.append(arena, .{ .quad = .{ .rect = rect, .fill_role = .surface_bg, .border_widths = .{ bw, bw, bw, bw }, .border_role = .focus_accent, .panel_padding_px = pad } });
    const start = @min(state.scroll, rows.len -| sz.rows);
    const shown = visible(state, rows);
    for (shown, 0..) |r, i| {
        const abs = start + i;
        const row_y = rect.y + @as(i32, @intCast(i)) * @as(i32, @intCast(ch));
        // 선택 행 — 폭 가득한 셀 배경(직각이라 셀 격자에 그대로 앉고, 글자 셀이 그 배경을 지닌다).
        if (abs == state.selected) try out.append(arena, .{ .fill = .{ .rect = .{ .x = rect.x, .y = row_y, .w = rect.w, .h = ch }, .role = .tab_active_bg } });
        // kind 아이콘 — 등록 아이콘만 2칸으로 재게 **자기 op** 에 둔다(`wide_icons` 는 사용자 글에 켜지 않는다 — draw.Text 주석).
        if (kindStyle(r.kind)) |k| {
            const run = try arena.alloc(draw.Run, 1);
            run[0] = .{ .text = icons.utf8(k.icon) };
            try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + @as(i32, @intCast(icon_col * cw)), .y = row_y }, .runs = run, .role = k.role, .wide_icons = true } });
        }
        // label(일치 글자는 accent) + 꼬리(옅게, 간격 없이). 넘치면 `fold` 의 순서로 접는다(§8.2g-c).
        const f = fold(overlay_input.displayCols(r.label), overlay_input.displayCols(r.label_detail), overlay_input.displayCols(r.detail), box_cols -| chrome_cols);
        const label = try overlay_input.truncateToCols(arena, r.label, f.label);
        const label_detail = if (f.label_detail == 0) "" else try overlay_input.truncateToCols(arena, r.label_detail, f.label_detail);
        var runs: std.ArrayList(draw.Run) = .empty;
        try appendMatchRuns(arena, &runs, label, label.ptr != r.label.ptr, r.match); // 접혔으면 `truncateToCols` 가 새 글(머리 + `…`)을 준다
        if (label_detail.len > 0) try runs.append(arena, .{ .text = label_detail, .role = .muted_fg });
        if (runs.items.len > 0) try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + @as(i32, @intCast(label_col * cw)), .y = row_y }, .runs = runs.items, .role = .surface_fg } });
        // 오른쪽(옅게) — 우패딩 앞에 붙인다.
        if (f.right > 0) {
            const detail = try overlay_input.truncateToCols(arena, r.detail, f.right);
            const dcols = overlay_input.displayCols(detail);
            const col = box_cols -| right_pad_cols -| dcols;
            const run = try arena.alloc(draw.Run, 1);
            run[0] = .{ .text = detail };
            try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + @as(i32, @intCast(col * cw)), .y = row_y }, .runs = run, .role = .muted_fg } });
        }
    }
}

/// `shown`(label 그대로, 또는 `truncated` 면 접은 것 — 원래 머리 바이트 + `…`)을 일치 여부가 같은 글자끼리 run 으로 나눈다. 글자는 **첫 바이트**가
/// `match` 에 있으면 일치다. 접혀 사라진 자리와 붙인 `…` 는 일치가 아니다. 글자 경계는 그리는 쪽과 **같은 디코더**(`text_layout.decodeCodepoint`)로
/// 잰다 — 깨진 바이트에서 길이만 보는 디코더로 자르면 뒤 글자(`가`)가 run 사이에서 쪼개져 한 칸 넓게 그려졌다(적대적 6회차).
fn appendMatchRuns(arena: std.mem.Allocator, runs: *std.ArrayList(draw.Run), shown: []const u8, truncated: bool, match: []const u32) !void {
    if (shown.len == 0) return;
    // 원래 label 의 머리인 몫 — 그 뒤(붙인 `…`)는 일치가 아니다. 바이트 비교로 재지 않는다: label 에 진짜 `…` 가 있으면(`wait…what` 을 5칸으로) 붙인
    // `…` 까지 머리로 읽혔다(적대적 6회차).
    const head: usize = if (truncated) shown.len -| "…".len else shown.len;
    var mi: usize = 0;
    var run_start: usize = 0;
    var run_hit: ?bool = null;
    var bi: usize = 0;
    while (bi < shown.len) {
        const end = bi + text_layout.decodeCodepoint(shown, bi).advance;
        while (mi < match.len and match[mi] < bi) mi += 1;
        const hit = end <= head and mi < match.len and match[mi] == bi;
        if (run_hit) |prev| if (prev != hit) {
            try runs.append(arena, .{ .text = shown[run_start..bi], .role = if (prev) .accent_bar else null });
            run_start = bi;
        };
        run_hit = hit;
        bi = end;
    }
    try runs.append(arena, .{ .text = shown[run_start..], .role = if (run_hit orelse false) .accent_bar else null });
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

test "SGB1 크기·창 — 폭은 label+detail(상한 60), 높이는 min(행, 10), 선택이 창을 따라 굴러가고 wrap 한다 (§8.2g)" {
    var rows: [25]Row = undefined;
    for (&rows, 0..) |*r, i| r.* = .{ .label = if (i % 2 == 0) "printf" else "puts", .detail = "int" };
    const sz = size(&rows).?;
    try testing.expectEqual(@as(u32, 6 + 4 + 2 + 3), sz.cols); // label + (아이콘 2 · 간격 1 · 우패딩 1) + 간격 2 + detail
    try testing.expectEqual(@as(u32, 10), sz.rows);
    var st = State{};
    st.show(100, 200, 20);
    st.reset(0, rows.len);
    try testing.expectEqual(@as(usize, 0), st.scroll);
    st.move(-1, rows.len); // wrap → 24, 창은 끝
    try testing.expectEqual(@as(usize, 24), st.selected);
    try testing.expectEqual(@as(usize, 15), st.scroll);
    st.move(1, rows.len); // wrap → 0
    try testing.expectEqual(@as(usize, 0), st.selected);
    try testing.expectEqual(@as(usize, 0), st.scroll);
    for (0..12) |_| st.move(1, rows.len);
    try testing.expectEqual(@as(usize, 12), st.selected);
    try testing.expectEqual(@as(usize, 3), st.scroll); // 12 가 창 마지막 행
    try testing.expectEqual(@as(usize, 10), visible(&st, &rows).len);
    try testing.expect(size(&.{}) == null);
    st.reset(5, 3); // 목록이 줄면 clamp
    try testing.expectEqual(@as(usize, 2), st.selected);
    st.move(1, 0); // 빈 목록은 무동작
}

/// 한 행의 글자를 칸 격자로 다시 세운다(판정용) — 행 y 의 text op 를 그 op 의 열에 놓는다. 등록 아이콘(`icons.Icon`)은 `@` + 빈 칸(2칸).
fn cellLine(arena: std.mem.Allocator, ops: []const draw.Op, rect: draw.Rect, row_y: i32, cw: u32) ![]const u8 {
    const cols = rect.w / cw;
    const cells = try arena.alloc([]const u8, cols);
    @memset(cells, " ");
    for (ops) |op| {
        if (op != .text or op.text.origin.y != row_y) continue;
        var col: usize = @intCast(@divTrunc(op.text.origin.x - rect.x, @as(i32, @intCast(cw))));
        for (op.text.runs) |run| {
            var it = (try std.unicode.Utf8View.init(run.text)).iterator();
            while (it.nextCodepointSlice()) |g| {
                const c = try std.unicode.utf8Decode(g);
                const wide = op.text.wide_icons and std.enums.fromInt(icons.Icon, c) != null; // 등록 아이콘만 2칸 — lowering 과 같은 규칙
                if (col < cols) cells[col] = if (wide) "@" else g;
                col += if (wide) 2 else overlay_input.displayCols(g);
            }
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    for (cells) |c| try buf.appendSlice(arena, c);
    return buf.items;
}

/// 행 y 에서 x 열에 선 text op.
fn textAt(ops: []const draw.Op, x: i32, y: i32) ?draw.Op.Text {
    for (ops) |op| if (op == .text and op.text.origin.x == x and op.text.origin.y == y) return op.text;
    return null;
}

test "SGB2 그리기 — 닫히면 무동작; 열리면 패널 quad 하나 위에 창 행만, 선택 행만 폭 가득 칠함, 아이콘 · label · 오른쪽 자리 (§8.2g · §8.2g-e)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = testProps();
    p.shape.border_width_px = 1;
    const tk = testTokens();
    const rows = [_]Row{ .{ .label = "add", .detail = "int" }, .{ .label = "add_x", .kind = 'f' }, .{ .label = "printf", .detail = "int (const char *, ...)" } };
    var st = State{};
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&st, &rows, p, &tk, arena, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    st.show(300, 100, 20);
    st.reset(1, rows.len);
    const r = boxRect(&st, &rows, p).?;
    try testing.expect(r.y >= 120);
    try testing.expectEqual(@as(u32, 3 * 20), r.h);
    try view(&st, &rows, p, &tk, arena, &out);
    // 패널 quad 가 첫 op(이 draw 의 첫 quad → `independent_panel` 이라 직각이어도 lowering 의 패널)이고 상자 rect 그대로, **직각**이다.
    try testing.expect(out.items[0] == .quad);
    try testing.expectEqual([4]u16{ 0, 0, 0, 0 }, out.items[0].quad.corner_radii);
    try testing.expectEqual(r, out.items[0].quad.rect);
    try testing.expectEqual(tokens.ColorRole.surface_bg, out.items[0].quad.fill_role);
    try testing.expectEqual(tokens.ColorRole.focus_accent, out.items[0].quad.border_role.?);
    try testing.expectEqual([4]u16{ 1, 1, 1, 1 }, out.items[0].quad.border_widths); // 테두리는 토큰 폭(적대적 1회차 M6 — role 만 보면 폭 0 이 통과했다)
    // 다른 행에는 배경이 없다 — 선택 행(1)만 폭 가득한 셀 배경(`.fill`), 행 rect 그대로. 패널 뒤 quad 는 없다(둥근 widget 이 아니다).
    var pills: usize = 0;
    for (out.items[1..]) |op| switch (op) {
        .quad => return error.TestUnexpectedResult,
        .fill => |f| {
            pills += 1;
            try testing.expectEqual(tokens.ColorRole.tab_active_bg, f.role);
            try testing.expectEqual(draw.Rect{ .x = r.x, .y = r.y + 20, .w = r.w, .h = 20 }, f.rect);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), pills);
    const line0 = try cellLine(arena, out.items, r, r.y, 10);
    try testing.expectEqual(@as(usize, r.w / 10), line0.len);
    try testing.expect(std.mem.startsWith(u8, line0, "   add ")); // 아이콘 없음(빈 2칸) · 간격 · label — 행이 테두리에 붙는다(VS Code)
    try testing.expect(std.mem.endsWith(u8, line0, "int ")); // detail 우측 + 우패딩
    try testing.expect(std.mem.startsWith(u8, try cellLine(arena, out.items, r, r.y + 20, 10), "@  add_x")); // kind 아이콘(2칸, 맨 앞) · `_` 는 그대로다(dropdown 과 다르다)
    const ic = textAt(out.items, r.x, r.y + 20).?;
    try testing.expect(ic.wide_icons); // 등록 아이콘은 2칸 — 자기 op 에만 켠다
    try testing.expectEqualStrings(icons.utf8(.kind_function), ic.runs[0].text);
    try testing.expectEqual(tokens.ColorRole.syntax_function, ic.role);
    try testing.expect(textAt(out.items, r.x, r.y) == null); // kind 없는 행은 아이콘 op 이 없다
    const lbl = textAt(out.items, r.x + 30, r.y).?;
    try testing.expect(!lbl.wide_icons); // 사용자 글(label)은 끈다 — 우연한 PUA 가 칸을 바꾸지 않게
    try testing.expectEqual(tokens.ColorRole.surface_fg, lbl.role);
    try testing.expect(lbl.runs[0].role == null); // label 은 op 의 색
    const right = textAt(out.items, r.x + @as(i32, @intCast(r.w)) - 40, r.y).?; // `int` 3칸 + 우패딩 1
    try testing.expectEqualStrings("int", right.runs[0].text);
    try testing.expectEqual(tokens.ColorRole.muted_fg, right.role); // 오른쪽은 옅게
    // 위로 뒤집힘 — 아래에 자리가 없으면 앵커 위.
    st.moveAnchor(300, 780, 20);
    const up = boxRect(&st, &rows, p).?;
    try testing.expect(up.y + @as(i32, @intCast(up.h)) <= 780);
    // 스크롤된 창 — 알약은 **절대 첨자**의 선택 행에 선다(창 안 첨자로 재면 선택이 10번째 뒤일 때 알약이 사라진다, 적대적 1회차 M5).
    var many: [25]Row = undefined;
    for (&many, 0..) |*m, i| m.* = .{ .label = if (i % 2 == 0) "alpha" else "beta" };
    var sc = State{};
    sc.show(300, 100, 20);
    sc.reset(0, many.len);
    for (0..12) |_| sc.move(1, many.len); // 선택 12, 창 3..13
    try testing.expectEqual(@as(usize, 3), sc.scroll);
    var out_sc: std.ArrayList(draw.Op) = .empty;
    try view(&sc, &many, p, &tk, arena, &out_sc);
    const rs = boxRect(&sc, &many, p).?;
    var pill_y: ?i32 = null;
    for (out_sc.items[1..]) |op| if (op == .fill) {
        try testing.expect(pill_y == null);
        pill_y = op.fill.rect.y;
    };
    try testing.expectEqual(rs.y + (12 - 3) * 20, pill_y.?);
}

test "SGB3 labelDetails — 꼬리는 label 뒤에 옅게, 오른쪽은 description; 폭은 (label+꼬리)+오른쪽; 넘치면 오른쪽(16 문턱) → 꼬리 → label 순으로 접는다 (§8.2g-c)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = testProps();
    const tk = testTokens();
    // 폭: (7 + 31) + 4 + 2 + 20 = 64 → 상한 60.
    const rows = [_]Row{ .{ .label = "HashMap", .label_detail = "(use std::collections::HashMap)", .detail = "HashMap<{unknown}, V>", .kind = 't' }, .{ .label = "printf", .label_detail = "(const char *, ...)", .detail = "int", .kind = 'f' }, .{ .label = "word", .kind = 'w' } };
    try testing.expectEqual(@as(u32, 60), size(&rows).?.cols);
    var st = State{};
    st.show(100, 100, 20);
    st.reset(0, rows.len);
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&st, &rows, p, &tk, arena, &out);
    const r = boxRect(&st, &rows, p).?;
    const l0 = try cellLine(arena, out.items, r, r.y, 10);
    try testing.expectEqual(@as(usize, 60), overlay_input.displayCols(l0));
    // 쓸 칸 60 − 4 = 56: 오른쪽 16 문턱 → 왼쪽 38 = label 7 + 꼬리 31(그대로). 꼬리는 간격 없이.
    try testing.expect(std.mem.startsWith(u8, l0, "@  HashMap(use std::collections::HashMap)  "));
    try testing.expect(std.mem.endsWith(u8, l0, "HashMap<{unknow… ")); // 오른쪽은 16 문턱까지 접혔다(15 글자 + …)
    const lbl0 = textAt(out.items, r.x + 30, r.y).?;
    try testing.expectEqualStrings("(use std::collections::HashMap)", lbl0.runs[1].text);
    try testing.expectEqual(tokens.ColorRole.muted_fg, lbl0.runs[1].role.?);
    const l1 = try cellLine(arena, out.items, r, r.y + 20, 10);
    try testing.expect(std.mem.startsWith(u8, l1, "@  printf(const char *, ...)"));
    try testing.expect(std.mem.endsWith(u8, l1, "int ")); // description 이 없으면 제품이 detail 을 오른쪽에 싣는다(여기선 그 자리)
    const l2 = try cellLine(arena, out.items, r, r.y + 40, 10);
    try testing.expectEqualStrings("@  word", std.mem.trimEnd(u8, l2, " ")); // 버퍼 단어 — 꼬리도 오른쪽도 없다
    try testing.expectEqual(@as(usize, 1), textAt(out.items, r.x + 30, r.y + 40).?.runs.len);
    // fold 의 순서 — 순수.
    try testing.expectEqual(Fold{ .label = 7, .label_detail = 31, .right = 16 }, fold(7, 31, 20, 56)); // 오른쪽만 접힌다(문턱)
    try testing.expectEqual(Fold{ .label = 7, .label_detail = 31, .right = 8 }, fold(7, 31, 8, 56)); // 오른쪽이 문턱보다 짧으면 그 길이
    try testing.expectEqual(Fold{ .label = 7, .label_detail = 23, .right = 16 }, fold(7, 31, 20, 48)); // 그래도 넘치면 꼬리부터
    try testing.expectEqual(Fold{ .label = 7, .label_detail = 0, .right = 16 }, fold(7, 31, 20, 25)); // 꼬리가 다 접힌다
    try testing.expectEqual(Fold{ .label = 5, .label_detail = 0, .right = 16 }, fold(7, 31, 20, 23)); // 마지막에 label
    try testing.expectEqual(Fold{ .label = 7, .label_detail = 31, .right = 0 }, fold(7, 31, 0, 56)); // 오른쪽 없음 — 전부
    try testing.expectEqual(Fold{ .label = 7, .label_detail = 13, .right = 0 }, fold(7, 31, 0, 20)); // 오른쪽 없음 — 꼬리 접힘
    try testing.expectEqual(Fold{ .label = 4, .label_detail = 0, .right = 3 }, fold(7, 31, 20, 9)); // 상자가 문턱보다 좁으면 label 4 를 남기고 있는 만큼
    try testing.expectEqual(Fold{ .label = 2, .label_detail = 0, .right = 0 }, fold(2, 0, 20, 4)); // 오른쪽 자리가 아예 없다
    // 그리기도 fold 의 label 값을 쓴다 — 아주 긴 label 은 `…` 로(적대적 1회차 A18: fold 만 재고 그림은 안 쟀다).
    const long = [_]Row{.{ .label = "a_very_long_label_that_exceeds_the_sixty_column_box_by_a_lot_of_columns", .detail = "T" }};
    var st2 = State{};
    st2.show(100, 100, 20);
    st2.reset(0, 1);
    var out2: std.ArrayList(draw.Op) = .empty;
    try view(&st2, &long, p, &tk, arena, &out2);
    const r2 = boxRect(&st2, &long, p).?;
    const ll = try cellLine(arena, out2.items, r2, r2.y, 10);
    try testing.expectEqual(@as(usize, 60), overlay_input.displayCols(ll));
    try testing.expect(std.mem.indexOf(u8, ll, "…") != null);
    try testing.expect(std.mem.endsWith(u8, ll, "T ")); // 오른쪽(1칸)은 산다 — label 이 접혔다
}

test "SGB4 디자인 시스템 — kind 아이콘과 색, 일치 글자 accent(접힌 자리·…·여러 바이트), 직각 패널·셀 배경 선택, 패널 패딩 = 테두리 폭, 보이는 패널이 포인터와 경계를 정한다 (§8.2g-e)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // kind 글자 → 아이콘·색. 모르는 글자는 아이콘이 없다.
    const kinds = "fvtkmspw";
    const want_icons = [_]icons.Icon{ .kind_function, .kind_variable, .kind_type, .kind_keyword, .kind_module, .kind_snippet, .kind_property, .kind_word };
    const want_roles = [_]tokens.ColorRole{ .syntax_function, .syntax_property, .syntax_type_name, .syntax_keyword, .syntax_tag, .syntax_string, .syntax_property, .muted_fg };
    for (kinds, want_icons, want_roles) |k, ic, role| {
        try testing.expectEqual(ic, kindStyle(k).?.icon);
        try testing.expectEqual(role, kindStyle(k).?.role);
    }
    try testing.expect(kindStyle(' ') == null);
    try testing.expect(kindStyle('x') == null);
    // 일치 글자 — 접두사(0..n), 흩어진 부분열, 접혀 사라진 자리, 여러 바이트 글자.
    const Case = struct { shown: []const u8, truncated: bool = false, match: []const u32, want: []const []const u8, hit: []const bool };
    const cases = [_]Case{
        .{ .shown = "printf", .match = &.{ 0, 1, 2 }, .want = &.{ "pri", "ntf" }, .hit = &.{ true, false } },
        .{ .shown = "printf", .match = &.{ 0, 2, 5 }, .want = &.{ "p", "r", "i", "nt", "f" }, .hit = &.{ true, false, true, false, true } },
        .{ .shown = "printf", .match = &.{}, .want = &.{"printf"}, .hit = &.{false} },
        .{ .shown = "pri…", .truncated = true, .match = &.{ 1, 5 }, .want = &.{ "p", "r", "i…" }, .hit = &.{ false, true, false } }, // 5(f)는 접혀 사라졌다
        .{ .shown = "pri…", .truncated = true, .match = &.{ 0, 1, 2, 3 }, .want = &.{ "pri", "…" }, .hit = &.{ true, false } }, // 3(n)은 `…` 의 첫 바이트 자리 — `…` 는 일치가 아니다(적대적 1회차 M4)
        .{ .shown = "가나다", .match = &.{3}, .want = &.{ "가", "나", "다" }, .hit = &.{ false, true, false } },
        // label 의 진짜 `…` — 접힌 꼬리 `…` 와 바이트가 같아도 붙인 것은 일치가 아니다(`wait…what` 을 5칸으로, 접두사 `wait…`).
        .{ .shown = "wait…", .truncated = true, .match = &.{ 0, 1, 2, 3, 4 }, .want = &.{ "wait", "…" }, .hit = &.{ true, false } },
        // 접히지 않은 label 의 진짜 `…` 는 일치일 수 있다.
        .{ .shown = "a…b", .match = &.{ 0, 1 }, .want = &.{ "a…", "b" }, .hit = &.{ true, false } },
        // 깨진 바이트(E9 뒤 EA 는 이어짐 바이트가 아니다) — 그리는 디코더처럼 E9 한 바이트가 한 글자, `가`(EA B0 80)는 쪼개지지 않는다(적대적 6회차).
        .{ .shown = "\xE9\xEA\xB0\x80x", .match = &.{ 0, 4 }, .want = &.{ "\xE9", "\xEA\xB0\x80", "x" }, .hit = &.{ true, false, true } },
    };
    for (cases) |c| {
        var runs: std.ArrayList(draw.Run) = .empty;
        try appendMatchRuns(arena, &runs, c.shown, c.truncated, c.match);
        try testing.expectEqual(c.want.len, runs.items.len);
        for (runs.items, c.want, c.hit) |run, w, h| {
            try testing.expectEqualStrings(w, run.text);
            try testing.expectEqual(h, run.role != null and run.role.? == .accent_bar);
        }
    }
    // 그리기까지 — 일치 run 이 label op 에 실린다.
    var p = testProps();
    const tk = testTokens();
    const rows = [_]Row{ .{ .label = "printf", .kind = 'f', .match = &.{ 0, 1, 2 } }, .{ .label = "pRINT", .kind = 'q' } };
    var st = State{};
    st.show(300, 100, 20);
    st.reset(0, rows.len);
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&st, &rows, p, &tk, arena, &out);
    const r = boxRect(&st, &rows, p).?;
    const lbl = textAt(out.items, r.x + 30, r.y).?;
    try testing.expectEqualStrings("pri", lbl.runs[0].text);
    try testing.expectEqual(tokens.ColorRole.accent_bar, lbl.runs[0].role.?);
    try testing.expect(textAt(out.items, r.x, r.y + 20) == null); // 모르는 kind 는 빈 칸
    // 그리기 단계의 접힌 label — `…` 가 원래 label 의 일치 자리(55)에 와도 강조하지 않는다. 함수에 **원래** label 을 넘겨야 그 판정이 선다
    // (접힌 글을 두 번 넘기면 `…` 의 첫 바이트가 일치로 칠해졌다 — 적대적 4회차).
    var long_label: [70]u8 = undefined;
    @memset(&long_label, 'b');
    long_label[0] = 'a';
    const folded = [_]Row{.{ .label = &long_label, .match = &.{ 0, 55 } }}; // 쓸 칸 56 → 55 글자 + `…`(바이트 55)
    var stf = State{};
    stf.show(100, 100, 20);
    stf.reset(0, 1);
    var out_f: std.ArrayList(draw.Op) = .empty;
    try view(&stf, &folded, p, &tk, arena, &out_f);
    const rf = boxRect(&stf, &folded, p).?;
    const lf = textAt(out_f.items, rf.x + 30, rf.y).?;
    try testing.expectEqual(@as(usize, 2), lf.runs.len);
    try testing.expectEqualStrings("a", lf.runs[0].text);
    try testing.expect(std.mem.endsWith(u8, lf.runs[1].text, "b…"));
    try testing.expect(lf.runs[1].role == null);
    // 직각 — 토큰 반지름이 커도 패널은 모서리 0(1배율 1px 테두리 + 둥근 모서리는 번져 경계선이 흐렸다), 선택 행은 셀 배경 `.fill`(반지름이 없다).
    p.shape.corner_radius_px = 30;
    p.shape.border_width_px = 3;
    var out_big: std.ArrayList(draw.Op) = .empty;
    try view(&st, &rows, p, &tk, arena, &out_big);
    try testing.expectEqual([4]u16{ 0, 0, 0, 0 }, out_big.items[0].quad.corner_radii);
    try testing.expectEqual(@as(?u16, 3), out_big.items[0].quad.panel_padding_px); // 패널 패딩 = 테두리 폭(메뉴의 12 가 아니다)
    try testing.expect(out_big.items[1] == .fill and out_big.items[1].fill.role == .tab_active_bg);
    try testing.expect(independent_panel); // 직각 패널을 GPU 패널로 — 이 값을 draw 에 싣는 곳은 `SGD3`·host 판정자가 본다
    // 보이는 패널 — 패딩(테두리 폭) 안 포인터는 목록의 것, 경계 여백도 보이는 테두리에서. 메뉴 토큰(`modal_padding_px`)은 이 목록에 안 쓴다.
    p.shape.modal_padding_px = 12;
    const rp = boxRect(&st, &rows, p).?;
    // 네 변 모두 — 안쪽 끝(패딩 − 1)은 목록의 것, 바깥(패딩)은 아니다(적대적 4회차: 왼쪽·아래만 재면 오른쪽·위 패딩을 0 으로 해도 초록).
    const x0 = rp.x;
    const y0 = rp.y;
    const x1 = rp.x + @as(i32, @intCast(rp.w));
    const y1 = rp.y + @as(i32, @intCast(rp.h));
    const Pt = struct { x: i32, y: i32, in: bool };
    for ([_]Pt{
        .{ .x = x0 - 3, .y = y0, .in = true }, .{ .x = x0 - 4, .y = y0, .in = false },
        .{ .x = x1 + 2, .y = y0, .in = true }, .{ .x = x1 + 3, .y = y0, .in = false },
        .{ .x = x0, .y = y0 - 3, .in = true }, .{ .x = x0, .y = y0 - 4, .in = false },
        .{ .x = x0, .y = y1 + 2, .in = true }, .{ .x = x0, .y = y1 + 3, .in = false },
    }) |pt| try testing.expectEqual(pt.in, contains(&st, &rows, p, @floatFromInt(pt.x), @floatFromInt(pt.y)));
    try testing.expect(!contains(&st, &rows, p, std.math.nan(f64), 0));
    try testing.expectEqual(rp.y, 100 + 20 + 3); // 보이는 윗단이 앵커 줄 아랫단에 닿는다
    // 아래에 자리가 없으면 **뒤집는다** — 보이는 아랫단이 앵커 줄 윗단에 닿는다. 당기면(`below_clamp`) 상자가 앵커 줄을 덮는다(적대적 1회차 M7).
    st.moveAnchor(300, 740, 20); // 아래: 763 + 40 > 경계 777 — 안 들어간다
    const flip = boxRect(&st, &rows, p).?;
    try testing.expectEqual(@as(i32, 740), flip.y + @as(i32, @intCast(flip.h)) + 3);
    st.moveAnchor(1190, 100, 20); // 오른쪽 끝 — 보이는 우단이 workspace 끝에서 한 칸 안쪽
    const edge = boxRect(&st, &rows, p).?;
    try testing.expectEqual(@as(i32, 1200 - 10), edge.x + @as(i32, @intCast(edge.w)) + 3); // 딱 한 칸 — `<=` 로 재면 여백을 두 배로 해도 초록(적대적 4회차)
    st.hide();
    try testing.expect(!contains(&st, &rows, p, @floatFromInt(rp.x), @floatFromInt(rp.y)));
}
