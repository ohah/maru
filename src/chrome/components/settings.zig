//! Settings — schema-주도 세팅 모달(폼). config 스키마의 각 필드를 한 행(라벨 + 위젯)으로 그린다(CS-4-4).
//! palette/find처럼 ChromeHost가 소유하는 오버레이 모달이지만, 행 목록은 platform이 config 스키마에서 빌드해
//! 주입한다(컴포넌트는 config·스키마를 모름 — palette `Row` 선례, L1/L3 경계). 박스 기하는 modal_box 공유
//! 프리미티브, control 위젯은 toggle 등 leaf 컴포넌트를 재사용한다. State(open·selected) + view(rows→박스+행) +
//! handle(키 네비/토글/닫기) + handlePointer(행/위젯 hit-test). 단일 출처: docs/config-gui.md §2·§4.
//!
//! CS-4-4 최소 범위: bool 필드(toggle)만. enum/number/text/color 위젯과 Section 네비·검색은 후속에 FieldRow.kind
//! union으로 확장한다(지금은 한 평면 목록).

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const modal_box = @import("modal_box.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW 표시폭) — 라벨 폭 측정(modal_box와 같은 규약)
const toggle = @import("toggle.zig");

/// 최상위 모달 레이어(palette/notice와 동일).
pub const layer = modal_box.layer;

/// 한 설정 행(platform이 config 스키마에서 빌드해 주입). CS-4-4 최소는 bool(toggle)만 — value가 현재 config 값이다.
/// 후속 위젯(enum/number/...)은 value를 kind union으로 일반화한다(지금은 단일 타입이라 평면).
pub const FieldRow = struct {
    label: []const u8, // 행 라벨(meta.doc 또는 키)
    value: bool, // 현재 toggle 값(config에서 읽어 주입)
};

/// 순수 상태 — 열림 + 포커스된 행. 행 데이터(rows)는 State에 두지 않고 매 프레임 platform이 주입한다(config 단일
/// 출처 — palette가 결과 행을 주입하는 것과 같은 규율). 토글 값도 config가 소유하므로 handle은 "그 행을 토글하라"는
/// 의도만 내고 실제 flip+write-back은 platform이 한다.
pub const State = struct {
    open: bool = false,
    selected: usize = 0,
    /// 현재 행 수 — platform이 매 프레임 setFieldCount로 주입한다(palette.setResultCount 선례). host의 키 라우팅이
    /// 행 목록 없이 handle(k, &state)를 부를 수 있게(wrap·toggle 가드에 필요한 count를 State가 든다).
    count: usize = 0,

    pub fn show(self: *State) void {
        self.open = true;
        self.selected = 0;
    }
    pub fn hide(self: *State) void {
        self.open = false;
    }
    /// 행 수를 주입하고 selected를 범위 안으로 clamp(행이 줄어 stale selection 방지).
    pub fn setFieldCount(self: *State, n: usize) void {
        self.count = n;
        if (n > 0 and self.selected >= n) self.selected = n - 1;
    }
    /// 포커스 행 이동(wrap). count(State)가 0이면 무동작.
    pub fn moveSelection(self: *State, delta: i32) void {
        if (self.count == 0) return;
        const c: i32 = @intCast(self.count);
        const cur: i32 = @intCast(@min(self.selected, self.count - 1));
        const next = @mod(cur + delta, c);
        self.selected = @intCast(if (next < 0) next + c else next);
    }
};

/// handle/handlePointer가 돌려주는 intent. platform이 받아 처리: toggle=rows[selected] 키 flip+write-back,
/// close=hide, selection_changed=재렌더(부수효과 없음), consumed=소비만(모달 뒤로 안 샘).
pub const Action = enum { close, toggle, selection_changed, consumed };

const label_gap_cols: u32 = 2; // 라벨과 우측 위젯 사이 최소 간격(칸)

/// toggle 위젯이 차지하는 칸 수(픽셀 폭을 cw로 ceil). view/hitTest의 control 열 폭 단일 출처.
fn toggleCols(ch: u32, cw: u32) u32 {
    const w = toggle.width(ch);
    return (w + cw - 1) / @max(cw, 1);
}

/// view와 hitTest가 공유하는 배치(§5.4 단일 레이아웃). 박스 + 위젯 열 폭 + 첫 필드 행을 돌려준다. null=생략(좁은 창).
const Layout = struct {
    box: modal_box.Box,
    tgl_cols: u32,
    first_field_row: u32, // 콘텐츠 행 기준(0=제목, 1=빈줄, 2~=필드)
};

const title_rows: u32 = 2; // 제목(0) + 빈 줄(1)

fn computeLayout(rows: []const FieldRow, p: props.ChromeProps, tk: *const tokens.Tokens) ?Layout {
    const cw = @max(p.metrics.cell_width_px, 1);
    const ch = @max(p.metrics.cell_height_px, 1);
    const tgl_cols = toggleCols(ch, cw);
    var content_cols: u32 = overlay_input.displayCols(title_text);
    for (rows) |r| {
        const row_cols = overlay_input.displayCols(r.label) + label_gap_cols + tgl_cols;
        content_cols = @max(content_cols, row_cols);
    }
    const content_rows = title_rows + @as(u32, @intCast(rows.len));
    const box = modal_box.layout(content_cols, content_rows, p, tk) orelse return null;
    return .{ .box = box, .tgl_cols = tgl_cols, .first_field_row = title_rows };
}

/// 필드 i(0-based)의 toggle control rect — 콘텐츠 영역 우측정렬(라벨은 좌측). view가 그리고 hitTest가 클릭 판정.
fn fieldToggleRect(l: Layout, i: usize) draw.Rect {
    const box = l.box;
    const row = l.first_field_row + @as(u32, @intCast(i));
    const ctrl_x = box.inner_x + @as(i32, @intCast((box.inner_cols -| l.tgl_cols) * box.cw));
    return .{ .x = ctrl_x, .y = modal_box.rowY(box, row), .w = toggle.width(box.ch), .h = box.ch };
}

const title_text = "Settings";

/// 모달 박스 + 제목 + 각 필드 행(선택 하이라이트 → 라벨 텍스트 → toggle)을 그린다. 빈 rows여도 제목 박스는 띄운다
/// (열렸다는 피드백 + Esc 안내). 순수: state·rows·props·tokens만 읽는다. out/op은 호출자(platform) frame arena 소유.
pub fn view(
    state: *const State,
    rows: []const FieldRow,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (!state.open) return;
    const l = computeLayout(rows, p, tk) orelse return;
    const box = l.box;
    try modal_box.frame(box, p, arena, out);
    try modal_box.text(box, box.inner_x, 0, title_text, .surface_fg, arena, out);

    for (rows, 0..) |r, i| {
        const content_row = l.first_field_row + @as(u32, @intCast(i));
        // 선택 행 하이라이트(라벨/위젯보다 먼저 — painter order).
        if (i == state.selected) {
            try modal_box.fillCells(box, box.inner_x, content_row, box.inner_cols, .tab_hover_bg, arena, out);
        }
        try modal_box.text(box, box.inner_x, content_row, r.label, .surface_fg, arena, out);
        var ts = toggle.State{ .value = r.value };
        try toggle.view(&ts, fieldToggleRect(l, i), tk, arena, out);
    }
}

/// 키 처리(열려 있을 때만 host가 호출). ↑↓=행 이동, Space/Enter=선택 행 토글, Esc=닫기, 그 외=소비(모달 뒤로 안 샘).
/// 행 수는 State.count(platform이 setFieldCount로 주입)를 본다. 실제 토글 flip은 platform(.toggle 받고 rows[selected]).
pub fn handle(k: input.InputEvent.KeyEvent, state: *State) Action {
    switch (k.key) {
        .escape => {
            state.hide();
            return .close;
        },
        .up => {
            state.moveSelection(-1);
            return .selection_changed;
        },
        .down => {
            state.moveSelection(1);
            return .selection_changed;
        },
        .enter => return if (state.count == 0) .consumed else .toggle,
        .char => return if (k.codepoint == ' ' and state.count > 0) .toggle else .consumed,
        else => return .consumed,
    }
}

/// 포인터 처리(열려 있을 때만). 박스 밖 좌클릭 down=닫기(바깥 클릭 dismiss). 박스 안: 행 위 좌클릭 down이면 그 행을
/// 선택하고, toggle 위에서면 .toggle(platform이 flip), 라벨 영역이면 .selection_changed. drag/up·우클릭·그 외=소비.
pub fn handlePointer(
    ev: input.PointerEvent,
    rows: []const FieldRow,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    state: *State,
) Action {
    if (ev.phase != .down or ev.button != .left) return .consumed;
    const l = computeLayout(rows, p, tk) orelse return .consumed;
    const box = l.box;
    // 박스 밖 클릭 → 닫기(바깥 클릭 dismiss 관례).
    const bx: f64 = @floatFromInt(box.rect.x);
    const by: f64 = @floatFromInt(box.rect.y);
    const inside = ev.x_px >= bx and ev.x_px < bx + @as(f64, @floatFromInt(box.rect.w)) and
        ev.y_px >= by and ev.y_px < by + @as(f64, @floatFromInt(box.rect.h));
    if (!inside) {
        state.hide();
        return .close;
    }
    // 행 hit-test: control rect의 세로 범위(행)로 어느 필드인지 판정.
    for (rows, 0..) |_, i| {
        const rect = fieldToggleRect(l, i);
        const ry: f64 = @floatFromInt(rect.y);
        if (ev.y_px >= ry and ev.y_px < ry + @as(f64, @floatFromInt(rect.h))) {
            state.selected = i;
            return if (toggle.hitTest(rect, ev.x_px, ev.y_px)) .toggle else .selection_changed;
        }
    }
    return .consumed; // 박스 안 비-행(제목/여백) 클릭 — 소비만
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

const test_props = props.ChromeProps{ .metrics = .{
    .cell_width_px = 8,
    .cell_height_px = 16,
    .sidebar_width_px = 40,
    .backing_width_px = 1000,
    .backing_height_px = 600,
} };

fn testTokens() tokens.Tokens {
    const Rgb = @import("../../color.zig").Rgb;
    return tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
}

test "settings state: show/hide/setFieldCount clamp/moveSelection wrap" {
    var s = State{};
    s.show();
    s.setFieldCount(3);
    try std.testing.expect(s.open);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    s.moveSelection(1);
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    s.moveSelection(-1);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    s.moveSelection(-1); // wrap to last
    try std.testing.expectEqual(@as(usize, 2), s.selected);
    s.moveSelection(1); // wrap to first
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    // setFieldCount이 줄면 selected clamp.
    s.selected = 2;
    s.setFieldCount(2);
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    s.setFieldCount(0); // 0이면 clamp 안 함(0행)
    s.moveSelection(1); // count 0 → no-op
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    s.hide();
    try std.testing.expect(!s.open);
}

test "settings handle: ↑↓ 네비·Space/Enter 토글·Esc 닫기·그 외 소비" {
    var s = State{};
    s.show();
    s.setFieldCount(3);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .up }, &s));
    try std.testing.expectEqual(Action.toggle, handle(.{ .key = .enter }, &s));
    try std.testing.expectEqual(Action.toggle, handle(.{ .key = .char, .codepoint = ' ' }, &s));
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .char, .codepoint = 'a' }, &s));
    try std.testing.expectEqual(Action.toggle, handle(.{ .key = .enter }, &s));
    // count 0 → enter/space는 토글 대상 없음 → consumed.
    s.setFieldCount(0);
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .enter }, &s));
    // Esc → close + hide.
    try std.testing.expectEqual(Action.close, handle(.{ .key = .escape }, &s));
    try std.testing.expect(!s.open);
}

test "settings view: 닫힘=0 ops, 열림=frame(quad+border)+제목+행(하이라이트·라벨·toggle pill+knob)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    var out: std.ArrayList(draw.Op) = .empty;

    var s = State{};
    try view(&s, &.{}, test_props, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 닫힘

    s.show();
    const rows = [_]FieldRow{
        .{ .label = "Cursor blink", .value = true },
        .{ .label = "Bold is bright", .value = false },
    };
    try view(&s, &rows, test_props, &tk, arena, &out);
    // frame(quad+border)=2, 제목 text=1, 행0(선택: fill+label+toggle pill+knob=4), 행1(label+toggle pill+knob=3) = 10.
    try std.testing.expectEqual(@as(usize, 10), out.items.len);
    try std.testing.expect(out.items[0] == .quad and out.items[1] == .border);
    try std.testing.expect(out.items[2] == .text); // 제목
    try std.testing.expectEqualStrings(title_text, out.items[2].text.runs[0].text);
    try std.testing.expect(out.items[3] == .fill); // 행0 선택 하이라이트
    try std.testing.expect(out.items[4] == .text); // 행0 라벨
    try std.testing.expectEqualStrings("Cursor blink", out.items[4].text.runs[0].text);
    try std.testing.expect(out.items[5] == .quad and out.items[6] == .quad); // 행0 toggle pill+knob
    try std.testing.expectEqual(tokens.ColorRole.focus_accent, out.items[5].quad.fill_role); // value=true → 켜짐색
    try std.testing.expect(out.items[7] == .text); // 행1 라벨(선택 아님 → 하이라이트 없음)
    try std.testing.expectEqual(tokens.ColorRole.tab_hover_bg, out.items[8].quad.fill_role); // 행1 value=false → 꺼짐색
}

test "settings handlePointer: 박스 밖=닫기, toggle 위=.toggle+선택, 라벨=.selection_changed" {
    const tk = testTokens();
    var s = State{};
    s.show();
    const rows = [_]FieldRow{
        .{ .label = "A", .value = false },
        .{ .label = "B", .value = false },
    };
    const l = computeLayout(&rows, test_props, &tk).?;

    // 박스 밖(0,0) 좌클릭 → 닫기.
    try std.testing.expectEqual(Action.close, handlePointer(.{ .phase = .down, .x_px = 0, .y_px = 0 }, &rows, test_props, &tk, &s));
    try std.testing.expect(!s.open);

    // 행1의 toggle 중앙 클릭 → 선택=1 + .toggle.
    s.show();
    const r1 = fieldToggleRect(l, 1);
    const tx: f64 = @floatFromInt(r1.x + 4);
    const ty: f64 = @floatFromInt(r1.y + 4);
    try std.testing.expectEqual(Action.toggle, handlePointer(.{ .phase = .down, .x_px = tx, .y_px = ty }, &rows, test_props, &tk, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);

    // 행0 라벨 영역(control rect 왼쪽, 같은 행 y) 클릭 → 선택=0 + .selection_changed(toggle 밖).
    const r0 = fieldToggleRect(l, 0);
    const ly: f64 = @floatFromInt(r0.y + 4);
    try std.testing.expectEqual(Action.selection_changed, handlePointer(.{ .phase = .down, .x_px = @floatFromInt(l.box.inner_x + 2), .y_px = ly }, &rows, test_props, &tk, &s));
    try std.testing.expectEqual(@as(usize, 0), s.selected);

    // up/move·우클릭 → 소비.
    try std.testing.expectEqual(Action.consumed, handlePointer(.{ .phase = .up, .x_px = tx, .y_px = ty }, &rows, test_props, &tk, &s));
}
