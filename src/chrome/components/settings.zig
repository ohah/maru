//! Settings — schema-주도 세팅 모달(폼). config 스키마의 각 필드를 한 행(라벨 + 위젯)으로 그린다(CS-4-4).
//! palette/find처럼 ChromeHost가 소유하는 오버레이 모달이지만, 행 목록은 platform이 config 스키마에서 빌드해
//! 주입한다(컴포넌트는 config·스키마를 모름 — palette `Row` 선례, L1/L3 경계). 박스 기하는 modal_box 공유
//! 프리미티브, control 위젯은 toggle 등 leaf 컴포넌트를 재사용한다. State(open·selected) + view(rows→박스+행) +
//! handle(키 네비/토글/닫기) + handlePointer(행/위젯 hit-test). 단일 출처: docs/config-gui.md §2·§4.
//!
//! 위젯은 FieldRow.kind union으로 가른다 — bool(toggle, CS-4-4b)·number(slider, CS-4-1b). enum(dropdown)·text·
//! color와 Section 네비·검색은 후속(지금은 한 평면 목록).

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const modal_box = @import("modal_box.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW 표시폭) — 라벨 폭 측정(modal_box와 같은 규약)
const toggle = @import("toggle.zig");
const slider = @import("slider.zig");
const dropdown = @import("dropdown.zig");

/// 최상위 모달 레이어(palette/notice와 동일).
pub const layer = modal_box.layer;

/// 한 설정 행(platform이 config 스키마에서 빌드해 주입). kind union으로 위젯 종류를 가른다 — CS-4-4b는 bool(toggle),
/// CS-4-1b는 number(slider) 추가. 후속에 enum(dropdown)·text·color로 확장. 값은 config가 소유(주입만).
pub const FieldRow = struct {
    label: []const u8, // 행 라벨(meta.doc 또는 키)
    kind: Kind,

    pub const Kind = union(enum) {
        toggle: bool, // 현재 on/off
        slider: Slider, // 현재 값 + 범위(f32/u32; value/min/max는 f64로 통일)
        dropdown: []const u8, // enum 현재 변형 표시 토큰(클릭/←→로 순환 — platform이 schema.cycleEnum)
    };
    pub const Slider = struct { value: f64, min: f64, max: f64 };

    /// 슬라이더 값의 정규화 위치(0..1). min==max면 0(0분모 가드).
    fn sliderRatio(s: Slider) f32 {
        if (s.max <= s.min) return 0;
        return @floatCast(std.math.clamp((s.value - s.min) / (s.max - s.min), 0, 1));
    }
};

/// 순수 상태 — 열림 + 포커스된 행 + 슬라이더 드래그 상태. 행 데이터(rows)는 State에 두지 않고 매 프레임 platform이
/// 주입한다(config 단일 출처 — palette 선례). 값도 config가 소유하므로 handle은 의도(toggle/slider_set/adjust)만
/// 내고 실제 변경+write-back은 platform이 한다. slider 드래그 중엔 pending_ratio에 최신 ratio를 담아 platform이 읽는다.
pub const State = struct {
    open: bool = false,
    selected: usize = 0,
    /// 현재 행 수 — platform이 매 프레임 setFieldCount로 주입(palette.setResultCount 선례). host 키 라우팅이 행 목록
    /// 없이 handle(k,&state)를 부를 수 있게(wrap 가드).
    count: usize = 0,
    /// 슬라이더 드래그 진행 중(down이 슬라이더에서 시작해 up까지). move를 그 행에 캡처한다(divider 드래그 패턴).
    dragging: bool = false,
    /// 드래그/클릭이 만든 최신 슬라이더 ratio(0..1). platform이 .slider_set에서 읽어 rows[selected]의 값으로 매핑한다.
    pending_ratio: f32 = 0,

    pub fn show(self: *State) void {
        self.open = true;
        self.selected = 0;
        self.dragging = false;
    }
    pub fn hide(self: *State) void {
        self.open = false;
        self.dragging = false;
    }
    pub fn setFieldCount(self: *State, n: usize) void {
        self.count = n;
        if (n > 0 and self.selected >= n) self.selected = n - 1;
    }
    pub fn moveSelection(self: *State, delta: i32) void {
        if (self.count == 0) return;
        const c: i32 = @intCast(self.count);
        const cur: i32 = @intCast(@min(self.selected, self.count - 1));
        const next = @mod(cur + delta, c);
        self.selected = @intCast(if (next < 0) next + c else next);
    }
};

/// handle/handlePointer가 돌려주는 intent. platform이 rows[selected] 기준으로 처리:
///   toggle=bool flip, slider_set=pending_ratio→값 매핑, adjust_left/right=slider 한 스텝, selection_changed=재렌더,
///   close=hide, consumed=소비만(모달 뒤로 안 샘). 값 종류 판정(toggle인지 slider인지)은 platform이 rows로 한다.
pub const Action = enum { close, toggle, slider_set, adjust_left, adjust_right, selection_changed, consumed };

const label_gap_cols: u32 = 2; // 라벨과 우측 위젯 사이 최소 간격(칸)

/// control 열 폭(칸) — 모든 행이 같은 우측 열을 공유한다(가장 넓은 위젯=slider 기준). 픽셀 폭을 cw로 ceil. view/
/// hitTest 단일 출처. toggle은 이 열 안에서 우측정렬(slider 오른쪽 끝과 맞춤).
fn controlCols(ch: u32, cw: u32) u32 {
    return (slider.width(ch) + cw - 1) / @max(cw, 1);
}

const Layout = struct {
    box: modal_box.Box,
    ctrl_cols: u32,
    first_field_row: u32,
};

const title_rows: u32 = 2; // 제목(0) + 빈 줄(1)

fn computeLayout(rows: []const FieldRow, p: props.ChromeProps, tk: *const tokens.Tokens) ?Layout {
    const cw = @max(p.metrics.cell_width_px, 1);
    const ch = @max(p.metrics.cell_height_px, 1);
    const ctrl_cols = controlCols(ch, cw);
    var content_cols: u32 = overlay_input.displayCols(title_text);
    for (rows) |r| {
        const row_cols = overlay_input.displayCols(r.label) + label_gap_cols + ctrl_cols;
        content_cols = @max(content_cols, row_cols);
    }
    const content_rows = title_rows + @as(u32, @intCast(rows.len));
    const box = modal_box.layout(content_cols, content_rows, p, tk) orelse return null;
    return .{ .box = box, .ctrl_cols = ctrl_cols, .first_field_row = title_rows };
}

/// 필드 i의 control 열 rect(콘텐츠 우측, ctrl_cols 폭, 행 높이). slider는 이 전체를 쓰고, toggle은 이 안에서 우측정렬한다.
fn fieldControlRect(l: Layout, i: usize) draw.Rect {
    const box = l.box;
    const row = l.first_field_row + @as(u32, @intCast(i));
    const ctrl_x = box.inner_x + @as(i32, @intCast((box.inner_cols -| l.ctrl_cols) * box.cw));
    return .{ .x = ctrl_x, .y = modal_box.rowY(box, row), .w = l.ctrl_cols * box.cw, .h = box.ch };
}

/// control 열 안의 toggle rect — 우측정렬(slider 오른쪽 끝과 맞춤). hit-test/view 공유.
fn toggleRectIn(ctrl: draw.Rect, ch: u32) draw.Rect {
    const w = toggle.width(ch);
    return .{ .x = ctrl.x + @as(i32, @intCast(ctrl.w -| w)), .y = ctrl.y, .w = w, .h = ch };
}

const title_text = "Settings";

/// 모달 박스 + 제목 + 각 필드 행(선택 하이라이트 → 라벨 → 위젯[toggle|slider])을 그린다. 빈 rows여도 제목 박스는 띄운다.
/// 순수: state·rows·props·tokens만 읽는다. out/op은 호출자(platform) frame arena 소유.
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
        if (i == state.selected) {
            try modal_box.fillCells(box, box.inner_x, content_row, box.inner_cols, .tab_hover_bg, arena, out);
        }
        try modal_box.text(box, box.inner_x, content_row, r.label, .surface_fg, arena, out);
        const ctrl = fieldControlRect(l, i);
        switch (r.kind) {
            .toggle => |v| {
                var ts = toggle.State{ .value = v };
                try toggle.view(&ts, toggleRectIn(ctrl, box.ch), tk, arena, out);
            },
            .slider => |s| try slider.view(ctrl, FieldRow.sliderRatio(s), tk, arena, out),
            .dropdown => |cur| try dropdown.view(ctrl, cur, tk, arena, out),
        }
    }
}

/// 키 처리(열려 있을 때만 host 호출). ↑↓=행 이동, ←→=선택 행 조절(slider 스텝; toggle은 platform이 무시), Space/Enter=
/// 선택 행 활성(toggle flip; slider는 무시), Esc=닫기, 그 외=소비. 값 종류 판정은 platform이 rows[selected]로 한다.
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
        .left => return if (state.count == 0) .consumed else .adjust_left,
        .right => return if (state.count == 0) .consumed else .adjust_right,
        .enter => return if (state.count == 0) .consumed else .toggle,
        .char => return if (k.codepoint == ' ' and state.count > 0) .toggle else .consumed,
        else => return .consumed,
    }
}

/// 포인터 처리(열려 있을 때만). up=드래그 종료(소비). down=박스 밖이면 닫기, 안이면 행 선택 후 위젯별:
///   slider 위→드래그 시작 + pending_ratio + .slider_set, toggle 위→.toggle, 그 외(라벨)→.selection_changed.
///   move=드래그 중이고 선택 행이 slider면 pending_ratio 갱신 + .slider_set, 아니면 소비. 우클릭=소비.
pub fn handlePointer(
    ev: input.PointerEvent,
    rows: []const FieldRow,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    state: *State,
) Action {
    if (ev.button != .left) return .consumed;
    const l = computeLayout(rows, p, tk) orelse return .consumed;
    const box = l.box;

    if (ev.phase == .up) {
        state.dragging = false;
        return .consumed;
    }
    if (ev.phase == .move) {
        // 드래그 중이고 선택 행이 slider면 x→ratio로 추적(divider 라이브 드래그 패턴). 아니면 소비.
        if (!state.dragging or state.selected >= rows.len) return .consumed;
        if (rows[state.selected].kind != .slider) return .consumed;
        state.pending_ratio = slider.ratioAt(fieldControlRect(l, state.selected), ev.x_px);
        return .slider_set;
    }
    // down.
    const bx: f64 = @floatFromInt(box.rect.x);
    const by: f64 = @floatFromInt(box.rect.y);
    const inside = ev.x_px >= bx and ev.x_px < bx + @as(f64, @floatFromInt(box.rect.w)) and
        ev.y_px >= by and ev.y_px < by + @as(f64, @floatFromInt(box.rect.h));
    if (!inside) {
        state.hide();
        return .close;
    }
    for (rows, 0..) |r, i| {
        const ctrl = fieldControlRect(l, i);
        const ry: f64 = @floatFromInt(ctrl.y);
        if (ev.y_px >= ry and ev.y_px < ry + @as(f64, @floatFromInt(ctrl.h))) {
            state.selected = i;
            switch (r.kind) {
                .toggle => return if (toggle.hitTest(toggleRectIn(ctrl, box.ch), ev.x_px, ev.y_px)) .toggle else .selection_changed,
                .slider => {
                    if (!slider.hitTest(ctrl, ev.x_px, ev.y_px)) return .selection_changed;
                    state.dragging = true;
                    state.pending_ratio = slider.ratioAt(ctrl, ev.x_px);
                    return .slider_set;
                },
                .dropdown => return if (dropdown.hitTest(ctrl, ev.x_px, ev.y_px)) .toggle else .selection_changed, // 클릭 → 변형 순환(.toggle=활성)
            }
        }
    }
    return .consumed; // 박스 안 비-행(제목/여백) — 소비만
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

test "settings handle: ↑↓ 네비·←→ 조절·Space/Enter 토글·Esc 닫기·그 외 소비" {
    var s = State{};
    s.show();
    s.setFieldCount(3);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .up }, &s));
    try std.testing.expectEqual(Action.adjust_left, handle(.{ .key = .left }, &s)); // slider 스텝 다운(platform 판정)
    try std.testing.expectEqual(Action.adjust_right, handle(.{ .key = .right }, &s));
    try std.testing.expectEqual(Action.toggle, handle(.{ .key = .enter }, &s));
    try std.testing.expectEqual(Action.toggle, handle(.{ .key = .char, .codepoint = ' ' }, &s));
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .char, .codepoint = 'a' }, &s));
    // count 0 → enter/space/←→ 대상 없음 → consumed.
    s.setFieldCount(0);
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .enter }, &s));
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .left }, &s));
    // Esc → close + hide.
    try std.testing.expectEqual(Action.close, handle(.{ .key = .escape }, &s));
    try std.testing.expect(!s.open);
}

test "settings view: 닫힘=0 ops, 열림=frame+제목+toggle 행(pill+knob)+slider 행(트랙+채움+thumb)" {
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
        .{ .label = "Cursor blink", .kind = .{ .toggle = true } },
        .{ .label = "Font size", .kind = .{ .slider = .{ .value = 14, .min = 1, .max = 512 } } },
    };
    try view(&s, &rows, test_props, &tk, arena, &out);
    // frame(quad+border)=2, 제목=1. 행0(선택: fill+label+toggle pill+knob)=4. 행1(label + slider 트랙+채움+thumb)=4.
    try std.testing.expect(out.items[0] == .quad and out.items[1] == .border);
    try std.testing.expect(out.items[2] == .text); // 제목
    try std.testing.expect(out.items[3] == .fill); // 행0 선택 하이라이트
    try std.testing.expectEqualStrings("Cursor blink", out.items[4].text.runs[0].text);
    try std.testing.expectEqual(tokens.ColorRole.accent_bar, out.items[5].quad.fill_role); // toggle on(앰버)
    // 행1: 라벨 + slider(tui — 채움 accent_bar + thumb surface_fg, muted 트랙 없음).
    try std.testing.expectEqualStrings("Font size", out.items[7].text.runs[0].text);
    try std.testing.expectEqual(tokens.ColorRole.accent_bar, out.items[8].quad.fill_role); // slider 채움
    const lastq = out.items[out.items.len - 1];
    try std.testing.expectEqual(tokens.ColorRole.surface_fg, lastq.quad.fill_role); // slider thumb
}

test "settings handlePointer: 박스 밖=닫기, toggle 클릭=.toggle, slider 드래그=.slider_set+pending_ratio, 라벨=.selection_changed" {
    const tk = testTokens();
    var s = State{};
    s.show();
    const rows = [_]FieldRow{
        .{ .label = "A", .kind = .{ .toggle = false } },
        .{ .label = "Size", .kind = .{ .slider = .{ .value = 1, .min = 1, .max = 100 } } },
    };
    const l = computeLayout(&rows, test_props, &tk).?;

    // 박스 밖(0,0) 좌클릭 → 닫기.
    try std.testing.expectEqual(Action.close, handlePointer(.{ .phase = .down, .x_px = 0, .y_px = 0 }, &rows, test_props, &tk, &s));
    try std.testing.expect(!s.open);

    // 행0 toggle 중앙 클릭 → 선택=0 + .toggle.
    s.show();
    const tgl = toggleRectIn(fieldControlRect(l, 0), test_props.metrics.cell_height_px);
    try std.testing.expectEqual(Action.toggle, handlePointer(.{ .phase = .down, .x_px = @floatFromInt(tgl.x + 4), .y_px = @floatFromInt(tgl.y + 4) }, &rows, test_props, &tk, &s));
    try std.testing.expectEqual(@as(usize, 0), s.selected);

    // 행1 slider 우측 끝 근처 down → 선택=1 + 드래그 시작 + .slider_set + pending_ratio≈1.
    const c1 = fieldControlRect(l, 1);
    const right_x: f64 = @floatFromInt(c1.x + @as(i32, @intCast(c1.w)) - 2);
    const mid_y: f64 = @floatFromInt(c1.y + 4);
    try std.testing.expectEqual(Action.slider_set, handlePointer(.{ .phase = .down, .x_px = right_x, .y_px = mid_y }, &rows, test_props, &tk, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expect(s.dragging);
    try std.testing.expect(s.pending_ratio > 0.9);

    // 드래그 move(왼쪽으로) → .slider_set + pending_ratio 작아짐.
    try std.testing.expectEqual(Action.slider_set, handlePointer(.{ .phase = .move, .x_px = @floatFromInt(c1.x + 2), .y_px = mid_y }, &rows, test_props, &tk, &s));
    try std.testing.expect(s.pending_ratio < 0.1);

    // up → 드래그 종료(소비).
    try std.testing.expectEqual(Action.consumed, handlePointer(.{ .phase = .up, .x_px = right_x, .y_px = mid_y }, &rows, test_props, &tk, &s));
    try std.testing.expect(!s.dragging);

    // 행0 라벨 영역 클릭(control 왼쪽 — 위젯 밖) → .selection_changed.
    const c0 = fieldControlRect(l, 0);
    try std.testing.expectEqual(Action.selection_changed, handlePointer(.{ .phase = .down, .x_px = @floatFromInt(l.box.inner_x + 2), .y_px = @floatFromInt(c0.y + 4) }, &rows, test_props, &tk, &s));
    try std.testing.expectEqual(@as(usize, 0), s.selected);
}
