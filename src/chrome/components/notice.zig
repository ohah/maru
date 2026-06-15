//! Notice — 손상/오류 알림 모달(키보드 전용, hit-test 없음). chrome 컴포넌트 **계약의 exemplar**:
//!   State(순수 데이터+전이) + view(state, props, tokens → ChromeDraw, 순수) + handle(event, *state → ?Action).
//! 규칙(기존 palette/find 패턴 승계): State는 렌더를 모르고, view는 State를 읽기만, handle은 State를
//! mutate + intent(Action) 반환. 라이프사이클(언제 열고)은 host가 소유. 단일 출처: docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");

/// 이 컴포넌트가 그리는 레이어(최상위 모달). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = draw.Layer.modal;

/// 순수 상태 — message 슬롯 + open 플래그. host(또는 복원 손상 감지)가 show를 부른다.
pub const State = struct {
    open: bool = false,
    message: []const u8 = "",

    pub fn show(self: *State, message: []const u8) void {
        self.message = message;
        self.open = true;
    }

    pub fn dismiss(self: *State) void {
        self.open = false;
    }
};

/// handle이 돌려주는 intent. host가 받아 후처리(여기선 닫기 외 부수효과 없음).
pub const Action = enum { dismissed };

/// 키 이벤트 처리. 열려 있을 때만 동작 — Enter/Esc면 닫고 `dismissed`. 그 외 키는 **소비**하되 Action
/// 없음(모달이라 뒤(터미널)로 안 흘린다 — host가 라우팅에서 소비 처리). 닫혀 있으면 null(라우팅 안 가로챔).
pub fn handle(ev: input.InputEvent, state: *State) ?Action {
    if (!state.open) return null;
    switch (ev) {
        .key => |k| switch (k.key) {
            .enter, .escape => {
                state.dismiss();
                return .dismissed;
            },
            else => return null,
        },
    }
}

/// 중앙 모달 박스(배경 fill + focus 테두리 + 메시지 text)를 `out`에 append한다. 안 열렸으면 무동작.
/// 순수: state·props·tokens만 읽는다. ops·runs 슬라이스는 호출자가 준 frame arena가 소유한다.
pub fn view(
    state: *const State,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (!state.open) return;
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);

    // 박스 폭 = 메시지 표시 폭 + 좌우 여백, 단 **터미널 영역(사이드바 오른쪽) 칸 수를 넘지 않게 clamp**한다 —
    // 넘으면 박스가 사이드바를 침범하거나 우측으로 오버플로한다(좁은 창·넓은 사이드바). 표시 폭은 코드포인트
    // 근사라 wide(EAW=2) 문자는 과소측정돼 박스 우측서 잘릴 수 있다 — 정확한 display-width 보정은 후속.
    const term_w_px = m.backing_width_px -| m.sidebar_width_px;
    const term_cols = term_w_px / cw;
    // 0칸(터미널 영역이 한 셀보다 좁은 비정상 창)이면만 생략한다. 1~3칸이어도 작은 박스라도 그린다 —
    // 모달이 '열림이지만 안 보임'이면 handleKeyEvent가 모든 키를 소비해 터미널이 멈춘 듯 보이는 soft-lock이
    // 된다(리뷰 발견). box_cols는 아래에서 term_cols로 clamp되므로(≥1) box_w ≤ term_w_px가 유지돼 중앙배치
    // 뺄셈이 안전하다. (term_cols==0은 box_w=cw > term_w_px라 뺄셈이 언더플로하므로 반드시 생략.)
    if (term_cols == 0) return;
    const msg_cols: u32 = @intCast(std.unicode.utf8CountCodepoints(state.message) catch state.message.len);
    const box_cols = @max(@min(msg_cols + 2 * tk.space.modal_margin_cells, term_cols), 1);
    const box_w = box_cols * cw;
    const box_h = 3 * ch; // 위 여백 한 줄 + 메시지 한 줄 + 아래 여백 한 줄

    // 터미널 영역 안에서 중앙 배치. box_w <= term_w_px(위 clamp)라 (term_w_px - box_w)는 비음수 → x는 항상
    // 사이드바 오른쪽에 머문다.
    const sidebar = @as(i32, @intCast(m.sidebar_width_px));
    const x = sidebar + @as(i32, @intCast((term_w_px - box_w) / 2));
    const y = @divTrunc(@as(i32, @intCast(m.backing_height_px)) - @as(i32, @intCast(box_h)), 2);
    const rect = draw.Rect{ .x = x, .y = y, .w = box_w, .h = box_h };

    const bg_r = p.shape.corner_radius_px;
    const bw = p.shape.border_width_px;
    // C4b 모달: 배경을 quad로(둥근+테두리) — tui(0)면 셀 배경 + 아래 Op.border 셀(무변화), rich(>0)면 둥근
    // quad + quad 테두리(focus_accent). rich에선 아래 Op.border 셀을 rasterize가 skip(직각 중복 방지).
    try out.append(arena, .{ .quad = .{ .rect = rect, .fill_role = .surface_bg, .corner_radii = .{ bg_r, bg_r, bg_r, bg_r }, .border_widths = .{ bw, bw, bw, bw }, .border_role = .focus_accent } });
    try out.append(arena, .{ .border = .{
        .rect = rect,
        .sides = .{ .top = true, .right = true, .bottom = true, .left = true },
        .role = .focus_accent,
    } });
    // 메시지는 좌측 여백 + 한 줄 아래(가운데 줄)에 그린다. runs는 arena 소유.
    const runs = try arena.alloc(draw.Run, 1);
    runs[0] = .{ .text = state.message };
    try out.append(arena, .{ .text = .{
        .origin = .{ .x = x + @as(i32, @intCast(tk.space.modal_margin_cells * cw)), .y = y + @as(i32, @intCast(ch)) },
        .runs = runs,
        .role = .surface_fg,
    } });
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// Notice는 chrome 컴포넌트 계약의 첫 구현이라, 헤드리스로 (1) 상태 전이 (2) 입력→intent (3) view가
// 기대 ops를 내는지를 증명한다 — macOS·렌더 없이.

test "notice state: show/dismiss" {
    var s = State{};
    try std.testing.expect(!s.open);
    s.show("손상됨");
    try std.testing.expect(s.open);
    try std.testing.expectEqualStrings("손상됨", s.message);
    s.dismiss();
    try std.testing.expect(!s.open);
}

test "notice handle: Enter/Esc 닫고 dismissed, 닫힘이면 null" {
    var s = State{};
    try std.testing.expect(handle(.{ .key = .{ .key = .enter } }, &s) == null); // 닫혀 있으면 무동작
    s.show("x");
    try std.testing.expectEqual(Action.dismissed, handle(.{ .key = .{ .key = .escape } }, &s).?);
    try std.testing.expect(!s.open);
    s.show("y");
    try std.testing.expectEqual(Action.dismissed, handle(.{ .key = .{ .key = .enter } }, &s).?);
    s.show("z");
    try std.testing.expect(handle(.{ .key = .{ .key = .char, .codepoint = 'a' } }, &s) == null); // 소비하되 action 없음
    try std.testing.expect(s.open); // 평문 키로는 안 닫힘
}

test "notice view: 닫힘이면 ops 0, 열림이면 fill+border+text(modal)" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    var s = State{};
    try view(&s, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 닫힘

    s.show("file corrupt");
    try view(&s, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[1] == .border);
    try std.testing.expect(out.items[2] == .text);
    try std.testing.expectEqualStrings("file corrupt", out.items[2].text.runs[0].text);
    // 모달 박스는 터미널 영역(사이드바 오른쪽) 안, 화면 중앙쯤.
    try std.testing.expect(out.items[0].quad.rect.x >= 40);
    try std.testing.expect(out.items[0].quad.rect.w > 0);
}

test "notice view: 좁은 창(1~3칸)이어도 작은 박스를 그린다 — soft-lock 방지" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    // term 영역 = backing − sidebar = 60 − 40 = 20px, cw=8 → term_cols=2(예전 <4 가드면 생략됐다).
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 60,
        .backing_height_px = 600,
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    var s = State{};
    s.show("file corrupt"); // 메시지가 2칸보다 길어도 box_cols는 term_cols(2)로 clamp.
    try view(&s, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len); // 생략 안 함 — 작아도 그린다(보여서 Esc 가능)
    const box = out.items[0].quad.rect;
    try std.testing.expect(box.w > 0 and box.w <= 20); // term 영역 안(오버플로/언더플로 없음)
    try std.testing.expect(box.x >= 40); // 사이드바 오른쪽 유지

    // term_cols==0(터미널 영역이 한 셀보다 좁음)은 여전히 생략(중앙배치 뺄셈 언더플로 방지).
    out.clearRetainingCapacity();
    const narrow = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 45, .backing_height_px = 600 } };
    try view(&s, narrow, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // term_w=5px < cw=8 → term_cols=0 → 생략
}
