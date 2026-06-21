//! Toggle — on/off 스위치 위젯(설정 폼의 bool 행). chrome **위젯 컴포넌트의 첫 선례**(CS-4-1): notice/find
//! 같은 자기-중앙 모달과 달리, 세팅 셸(CS-4-4)이 각 행의 control rect에 배치해 쓰는 **leaf 컴포넌트**라 view/
//! hitTest가 host props가 아니라 **주어진 rect**를 기준으로 그린다. 계약은 다른 컴포넌트와 동형: State(순수
//! 데이터) + view(순수, rect+tokens→ops) + hitTest(순수) + handlePointer/handleKey(State mutate + intent).
//! 모양은 tokens.space(rich>0 → 둥근 pill+원형 knob, tui=0 → 직각)로 분기 없이 두 룩(C4b 박스와 동형). 색은
//! ColorRole(켜짐=focus_accent 트랙, 꺼짐=tab_hover_bg 트랙, knob=surface_fg)이라 백엔드가 토큰으로 해석한다.
//! 단일 출처: docs/config-gui.md §2·§6, docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const input = @import("../input.zig");

/// 순수 상태 — 켜짐/꺼짐. 셸이 config 키의 현재값으로 시드하고, handle이 바꾸면 그 키만 write-back(override)한다.
pub const State = struct { value: bool = false };

/// handle이 돌려주는 intent. 셸이 받아 그 키를 write-back(즉시-저장; config-gui §7). 값 자체는 State에 이미 반영됨.
pub const Action = enum { changed };

/// pill 폭 ÷ pill 높이 = 9/5(트랙이 knob 두 자리 + 여백). 셸이 control 영역 폭 예약·우측정렬에 width()로 쓴다.
const pill_aspect_num: u32 = 9;
const pill_aspect_den: u32 = 5;

/// 주어진 행 높이에서 toggle pill이 차지하는 픽셀 폭. 셸이 행 control 열 레이아웃에 쓴다(높이는 행 높이에 맞춤).
pub fn width(row_height_px: u32) u32 {
    return row_height_px * pill_aspect_num / pill_aspect_den;
}

/// pill 기하(view와 hitTest의 **단일 레이아웃** — chrome 계약 §5.4 view↔hitTest 공유). control rect 좌상단에서
/// 시작하는 pill(폭 width(h), 높이 h)과 knob(여백 pad 안쪽 정사각, 꺼짐=좌·켜짐=우)을 돌려준다.
const Geom = struct {
    pill: draw.Rect,
    knob: draw.Rect,
    pad: u32,
};

fn geom(rect: draw.Rect, value: bool) Geom {
    const ph = rect.h;
    const pw = width(ph);
    const pad = @max(@as(u32, 1), ph / 8); // 트랙 안쪽 여백(knob과 트랙 가장자리 사이)
    const kd = ph -| (2 * pad); // knob 지름(정사각 한 변)
    const knob_x: i32 = if (value)
        rect.x + @as(i32, @intCast(pw -| pad -| kd)) // 켜짐 = 우측
    else
        rect.x + @as(i32, @intCast(pad)); // 꺼짐 = 좌측
    return .{
        .pill = .{ .x = rect.x, .y = rect.y, .w = pw, .h = ph },
        .knob = .{ .x = knob_x, .y = rect.y + @as(i32, @intCast(pad)), .w = kd, .h = kd },
        .pad = pad,
    };
}

/// (x,y)가 toggle pill 안인가 — 클릭 hit-test. view와 같은 geom을 써 "보이는 pill == 눌리는 pill". 셀 0/비유한 가드.
pub fn hitTest(rect: draw.Rect, x_px: f64, y_px: f64) bool {
    if (rect.w == 0 or rect.h == 0 or !std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return false;
    const g = geom(rect, false); // pill 위치는 value 무관(knob만 좌우로 움직임)
    const px0: f64 = @floatFromInt(g.pill.x);
    const py0: f64 = @floatFromInt(g.pill.y);
    return x_px >= px0 and x_px < px0 + @as(f64, @floatFromInt(g.pill.w)) and
        y_px >= py0 and y_px < py0 + @as(f64, @floatFromInt(g.pill.h));
}

/// 포인터 처리 — pill 위 **좌클릭 down**이면 값 토글 + `.changed`. drag/up·우클릭·pill 밖은 무동작(null).
/// (confirm/context_menu가 down에서 동작하는 것과 같은 규율 — 즉각 토글.)
pub fn handlePointer(ev: input.PointerEvent, rect: draw.Rect, state: *State) ?Action {
    if (ev.phase != .down or ev.button != .left) return null;
    if (!hitTest(rect, ev.x_px, ev.y_px)) return null;
    state.value = !state.value;
    return .changed;
}

/// 키 처리 — Space/Enter면 값 토글 + `.changed`(셸이 포커스된 행에 위임). 그 외 키는 null(셸이 다른 행 이동 등 처리).
pub fn handleKey(k: input.InputEvent.KeyEvent, state: *State) ?Action {
    const toggled = k.key == .enter or (k.key == .char and k.codepoint == ' ');
    if (!toggled) return null;
    state.value = !state.value;
    return .changed;
}

/// pill(트랙) + knob를 control rect에 그린다. 켜짐=focus_accent 트랙, 꺼짐=tab_hover_bg 트랙, knob=surface_fg.
/// rich(space.corner_radius_px>0)면 pill/knob를 완전 둥글게(반지름=높이/2 → pill·원형), tui(0)면 직각(셀 룩) —
/// 같은 코드가 두 룩(C4b 박스와 동형). 순수: state·rect·tokens만 읽는다. out/op은 호출자(셸) frame arena 소유.
pub fn view(
    state: *const State,
    rect: draw.Rect,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (rect.w == 0 or rect.h == 0) return;
    const g = geom(rect, state.value);
    const round = tk.space.corner_radius_px > 0; // rich=둥근, tui=직각
    const pill_r: u16 = if (round) @intCast(@min(g.pill.h / 2, @as(u32, std.math.maxInt(u16)))) else 0;
    const knob_r: u16 = if (round) @intCast(@min(g.knob.h / 2, @as(u32, std.math.maxInt(u16)))) else 0;
    try out.append(arena, .{ .quad = .{
        .rect = g.pill,
        .fill_role = if (state.value) .focus_accent else .tab_hover_bg,
        .corner_radii = .{ pill_r, pill_r, pill_r, pill_r },
    } });
    try out.append(arena, .{ .quad = .{
        .rect = g.knob,
        .fill_role = .surface_fg,
        .corner_radii = .{ knob_r, knob_r, knob_r, knob_r },
    } });
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// 위젯 컴포넌트의 첫 구현이라, 헤드리스로 (1) hit-test (2) 포인터/키 → 토글+intent (3) view가 pill+knob ops를
// 내고 knob이 켜짐/꺼짐에 따라 좌우로 가는지를 증명한다 — macOS·렌더 없이.

const test_rect = draw.Rect{ .x = 100, .y = 50, .w = 60, .h = 20 };

test "toggle width: 행 높이 × 9/5" {
    try std.testing.expectEqual(@as(u32, 36), width(20)); // 20*9/5
}

test "toggle hitTest: pill 안=true, 밖/비유한=false" {
    // pill = x:100..136(width(20)=36), y:50..70.
    try std.testing.expect(hitTest(test_rect, 110, 60));
    try std.testing.expect(hitTest(test_rect, 100, 50)); // 좌상 경계 포함
    try std.testing.expect(!hitTest(test_rect, 136, 60)); // 우측 밖(>=136)
    try std.testing.expect(!hitTest(test_rect, 110, 70)); // 하단 밖(>=70)
    try std.testing.expect(!hitTest(test_rect, 200, 60)); // 멀리 밖
    try std.testing.expect(!hitTest(test_rect, std.math.inf(f64), 60));
    try std.testing.expect(!hitTest(.{ .x = 0, .y = 0, .w = 0, .h = 20 }, 0, 0)); // 0폭
}

test "toggle handlePointer: pill 위 좌클릭 down=토글+changed, 그 외=무동작" {
    var s = State{};
    // 좌클릭 down 안 → 토글.
    try std.testing.expectEqual(Action.changed, handlePointer(.{ .phase = .down, .x_px = 110, .y_px = 60 }, test_rect, &s).?);
    try std.testing.expect(s.value);
    // 다시 → 꺼짐.
    try std.testing.expectEqual(Action.changed, handlePointer(.{ .phase = .down, .x_px = 110, .y_px = 60 }, test_rect, &s).?);
    try std.testing.expect(!s.value);
    // pill 밖 down → 무동작.
    try std.testing.expect(handlePointer(.{ .phase = .down, .x_px = 200, .y_px = 60 }, test_rect, &s) == null);
    try std.testing.expect(!s.value);
    // up/move·우클릭 → 무동작(즉각 토글은 down만).
    try std.testing.expect(handlePointer(.{ .phase = .up, .x_px = 110, .y_px = 60 }, test_rect, &s) == null);
    try std.testing.expect(handlePointer(.{ .phase = .down, .x_px = 110, .y_px = 60, .button = .right }, test_rect, &s) == null);
    try std.testing.expect(!s.value);
}

test "toggle handleKey: Space/Enter=토글, 그 외=null" {
    var s = State{};
    try std.testing.expectEqual(Action.changed, handleKey(.{ .key = .char, .codepoint = ' ' }, &s).?);
    try std.testing.expect(s.value);
    try std.testing.expectEqual(Action.changed, handleKey(.{ .key = .enter }, &s).?);
    try std.testing.expect(!s.value);
    try std.testing.expect(handleKey(.{ .key = .char, .codepoint = 'a' }, &s) == null); // 다른 글자
    try std.testing.expect(handleKey(.{ .key = .escape }, &s) == null);
    try std.testing.expect(!s.value);
}

test "toggle view: pill+knob 2개, knob이 꺼짐=좌·켜짐=우, tui=직각·rich=둥근" {
    const Rgb = @import("../../color.zig").Rgb;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // tui 토큰(corner_radius_px=0) — 직각.
    const tui = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    var out: std.ArrayList(draw.Op) = .empty;

    // 꺼짐: pill(tab_hover_bg) + knob(좌, pad=2 → x=102).
    var off = State{ .value = false };
    try view(&off, test_rect, &tui, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[0] == .quad and out.items[1] == .quad);
    try std.testing.expectEqual(tokens.ColorRole.tab_hover_bg, out.items[0].quad.fill_role); // 트랙 꺼짐색
    try std.testing.expectEqual(tokens.ColorRole.surface_fg, out.items[1].quad.fill_role); // knob
    try std.testing.expectEqual(@as(i32, 102), out.items[1].quad.rect.x); // 좌측(x+pad)
    try std.testing.expectEqual(@as(u16, 0), out.items[0].quad.corner_radii[0]); // tui=직각

    // 켜짐: 트랙 focus_accent + knob 우측(x = 100 + 36 - 2 - 16 = 118; kd=20-2*2=16).
    out.clearRetainingCapacity();
    var on = State{ .value = true };
    try view(&on, test_rect, &tui, arena, &out);
    try std.testing.expectEqual(tokens.ColorRole.focus_accent, out.items[0].quad.fill_role);
    try std.testing.expectEqual(@as(i32, 118), out.items[1].quad.rect.x); // 우측

    // rich(corner_radius_px>0): pill 완전 둥글(반지름=h/2=10), knob 원형(반지름=kd/2=8).
    out.clearRetainingCapacity();
    var rich = tui;
    rich.space.corner_radius_px = 8;
    try view(&on, test_rect, &rich, arena, &out);
    try std.testing.expectEqual(@as(u16, 10), out.items[0].quad.corner_radii[0]); // pill h/2
    try std.testing.expectEqual(@as(u16, 8), out.items[1].quad.corner_radii[0]); // knob kd/2
}
