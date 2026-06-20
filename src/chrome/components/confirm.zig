//! Confirm — 예/아니오 확인 모달(키보드 전용, hit-test 없음). notice의 형제 컴포넌트로, chrome 계약을 그대로
//! 따른다: State(순수 데이터+전이) + view(state, props, tokens → ChromeDraw, 순수) + handle(event, *state → ?Action).
//! notice는 "알림 후 dismiss"라 의도가 1개(dismissed)지만, confirm은 파괴적 동작(닫기) 전 **확인/취소** 분기가
//! 필요해 의도가 2개(confirmed/cancelled)다 — host가 confirmed면 보류한 닫기를 실행, cancelled면 버린다.
//! 쓰임새: 실행 중인 명령이 있는 터미널/워크스페이스/창을 닫으려 할 때 데이터 손실을 막는 확인(다른 터미널의
//! "running process가 있는 창 닫기" 확인과 같은 목적 — iTerm2/Terminal.app/Ghostty 관례). 라이프사이클(언제 열고
//! 무엇을 보류했는지)은 host가 소유한다. 단일 출처: docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");

/// 이 컴포넌트가 그리는 레이어(최상위 모달). notice와 동일 — host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = draw.Layer.modal;

/// 확인창 아래 줄에 항상 그리는 키 안내. 메시지(host가 주입)와 달리 정적이라 컴포넌트가 소유한다.
/// Enter/Y = 닫기 진행, Esc/N = 취소. 표준 확인 다이얼로그 키 관례(기본 동작은 안전한 취소가 아니라 명시
/// 확인이라, 기본 포커스 표기는 두지 않고 두 키를 동등하게 안내한다).
pub const hint = "Enter·Y 닫기   Esc·N 취소";

/// 순수 상태 — message 슬롯 + open 플래그(notice와 동형). host가 닫기를 보류하며 show를 부른다.
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

/// handle이 돌려주는 intent. host가 받아 후처리한다 — confirmed면 보류한 닫기를 실행, cancelled면 보류를 버린다.
/// (notice는 dismissed 하나뿐이지만 confirm은 파괴적 동작 분기라 둘로 나뉜다.)
pub const Action = enum { confirmed, cancelled };

/// 키 이벤트 처리. 열려 있을 때만 동작 — Enter/Y면 confirmed, Esc/N이면 cancelled, 둘 다 닫는다. 그 외 키는
/// **소비**하되 Action 없음(모달이라 뒤(터미널)로 안 흘린다 — host가 라우팅에서 소비 처리). 닫혀 있으면
/// null(라우팅 안 가로챔). Y/N은 대소문자 무시 — 확인 다이얼로그 관례.
pub fn handle(ev: input.InputEvent, state: *State) ?Action {
    if (!state.open) return null;
    switch (ev) {
        .key => |k| switch (k.key) {
            .enter => {
                state.dismiss();
                return .confirmed;
            },
            .escape => {
                state.dismiss();
                return .cancelled;
            },
            .char => switch (k.codepoint) {
                'y', 'Y' => {
                    state.dismiss();
                    return .confirmed;
                },
                'n', 'N' => {
                    state.dismiss();
                    return .cancelled;
                },
                else => return null, // 다른 글자는 소비만(모달 — 뒤로 안 샘)
            },
            else => return null,
        },
    }
}

/// 중앙 모달 박스(배경 fill + focus 테두리 + 메시지 줄 + 안내 줄)를 `out`에 append한다. 안 열렸으면 무동작.
/// 순수: state·props·tokens만 읽는다. ops·runs 슬라이스는 호출자가 준 frame arena가 소유한다. 폭/클램프 로직은
/// notice.view와 동형(soft-lock 방지·사이드바 침범 방지)이되, 메시지+안내 **두 줄**이라 박스 높이가 한 줄 더 크고
/// 박스 폭은 두 줄 중 넓은 쪽 기준이다.
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

    // 박스 폭 = 두 줄(메시지·안내) 중 넓은 쪽 표시 폭 + 좌우 여백. notice와 같은 이유로 터미널 영역(사이드바
    // 오른쪽) 칸 수로 clamp한다 — 넘으면 사이드바를 침범하거나 우측 오버플로. 표시 폭은 코드포인트 근사라
    // wide(EAW=2) 문자는 과소측정될 수 있다(notice와 동일 한계 — 정확한 display-width 보정은 후속).
    const term_w_px = m.backing_width_px -| m.sidebar_width_px;
    const term_cols = term_w_px / cw;
    // notice와 동일: term_cols==0(터미널 영역이 한 셀보다 좁음)이면만 생략한다(중앙배치 뺄셈 언더플로 방지).
    // 1~3칸이어도 작은 박스라도 그린다 — '열림이지만 안 보임'이면 handle이 모든 키를 소비해 soft-lock이 된다.
    if (term_cols == 0) return;
    const pad: u32 = p.shape.modal_padding_px;
    const avail_cols = (term_w_px -| 2 * pad) / cw;
    const msg_cols: u32 = @intCast(std.unicode.utf8CountCodepoints(state.message) catch state.message.len);
    const hint_cols: u32 = @intCast(std.unicode.utf8CountCodepoints(hint) catch hint.len);
    const content_cols = @max(msg_cols, hint_cols);
    const box_cols = @max(@min(content_cols + 2 * tk.space.modal_margin_cells, avail_cols), 1);
    const box_w = box_cols * cw;
    const box_h = 4 * ch; // 위 여백 + 메시지 + 안내 + 아래 여백 (notice보다 한 줄 큼)

    // 터미널 영역 안에서 중앙 배치(notice와 동일). box_w <= term_w_px라 (term_w_px - box_w)는 비음수.
    const sidebar = @as(i32, @intCast(m.sidebar_width_px));
    const x = sidebar + @as(i32, @intCast((term_w_px - box_w) / 2));
    const y = @divTrunc(@as(i32, @intCast(m.backing_height_px)) - @as(i32, @intCast(box_h)), 2);
    const rect = draw.Rect{ .x = x, .y = y, .w = box_w, .h = box_h };

    const bg_r = p.shape.corner_radius_px;
    const bw = p.shape.border_width_px;
    // notice와 동일한 모달 배경: 둥근 quad + quad 테두리(focus_accent). tui(0)면 셀 배경 + 아래 Op.border 셀.
    try out.append(arena, .{ .quad = .{ .rect = rect, .fill_role = .surface_bg, .corner_radii = .{ bg_r, bg_r, bg_r, bg_r }, .border_widths = .{ bw, bw, bw, bw }, .border_role = .focus_accent } });
    try out.append(arena, .{ .border = .{
        .rect = rect,
        .sides = .{ .top = true, .right = true, .bottom = true, .left = true },
        .role = .focus_accent,
    } });
    const text_x = x + @as(i32, @intCast(tk.space.modal_margin_cells * cw));
    // 메시지 줄(가운데 위) — runs는 arena 소유.
    const msg_runs = try arena.alloc(draw.Run, 1);
    msg_runs[0] = .{ .text = state.message };
    try out.append(arena, .{ .text = .{
        .origin = .{ .x = text_x, .y = y + @as(i32, @intCast(ch)) },
        .runs = msg_runs,
        .role = .surface_fg,
    } });
    // 안내 줄(메시지 아래 한 줄) — 같은 좌측 여백, 흐린 역할(muted_fg)로 메시지와 위계를 준다.
    const hint_runs = try arena.alloc(draw.Run, 1);
    hint_runs[0] = .{ .text = hint };
    try out.append(arena, .{ .text = .{
        .origin = .{ .x = text_x, .y = y + @as(i32, @intCast(2 * ch)) },
        .runs = hint_runs,
        .role = .muted_fg,
    } });
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// notice와 같은 헤드리스 3종(상태 전이 / 입력→intent / view ops)으로 증명한다 — macOS·렌더 없이. confirm은
// notice와 달리 confirmed/cancelled **2-갈래**라, Enter/Y와 Esc/N이 서로 다른 intent를 내는지가 핵심 계약이다.

test "confirm state: show/dismiss" {
    var s = State{};
    try std.testing.expect(!s.open);
    s.show("실행 중인 명령이 있습니다. 닫을까요?");
    try std.testing.expect(s.open);
    try std.testing.expectEqualStrings("실행 중인 명령이 있습니다. 닫을까요?", s.message);
    s.dismiss();
    try std.testing.expect(!s.open);
}

test "confirm handle: Enter/Y=confirmed · Esc/N=cancelled · 닫힘이면 null · 다른 키는 소비" {
    var s = State{};
    // 닫혀 있으면 무동작(라우팅 안 가로챔).
    try std.testing.expect(handle(.{ .key = .{ .key = .enter } }, &s) == null);

    s.show("x");
    try std.testing.expectEqual(Action.confirmed, handle(.{ .key = .{ .key = .enter } }, &s).?);
    try std.testing.expect(!s.open); // confirmed면 닫힘

    s.show("x");
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .{ .key = .escape } }, &s).?);
    try std.testing.expect(!s.open); // cancelled면 닫힘

    s.show("x");
    try std.testing.expectEqual(Action.confirmed, handle(.{ .key = .{ .key = .char, .codepoint = 'y' } }, &s).?);
    s.show("x");
    try std.testing.expectEqual(Action.confirmed, handle(.{ .key = .{ .key = .char, .codepoint = 'Y' } }, &s).?);
    s.show("x");
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .{ .key = .char, .codepoint = 'n' } }, &s).?);
    s.show("x");
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .{ .key = .char, .codepoint = 'N' } }, &s).?);

    // 다른 글자는 소비만(intent 없음, 모달이라 뒤로 안 샘) — 여전히 열려 있음.
    s.show("x");
    try std.testing.expect(handle(.{ .key = .{ .key = .char, .codepoint = 'a' } }, &s) == null);
    try std.testing.expect(s.open);
}

test "confirm view: 닫힘이면 ops 0, 열림이면 fill+border+message+hint(4 ops, modal)" {
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

    s.show("running: vim");
    try view(&s, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 4), out.items.len); // notice보다 text 1개 더(안내 줄)
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[1] == .border);
    try std.testing.expect(out.items[2] == .text);
    try std.testing.expect(out.items[3] == .text);
    try std.testing.expectEqualStrings("running: vim", out.items[2].text.runs[0].text);
    try std.testing.expectEqualStrings(hint, out.items[3].text.runs[0].text);
    // 안내 줄은 메시지 줄보다 한 줄 아래.
    try std.testing.expect(out.items[3].text.origin.y > out.items[2].text.origin.y);
    // 모달 박스는 터미널 영역(사이드바 오른쪽) 안.
    try std.testing.expect(out.items[0].quad.rect.x >= 40);
}

test "confirm view: 좁은 창(1~3칸)이어도 작은 박스를 그린다 — soft-lock 방지(notice와 동일)" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    // term 영역 = backing − sidebar = 60 − 40 = 20px, cw=8 → term_cols=2.
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
    s.show("실행 중인 명령이 있습니다");
    try view(&s, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 4), out.items.len); // 생략 안 함 — 작아도 그린다(보여서 Esc 가능)
    const box = out.items[0].quad.rect;
    try std.testing.expect(box.w > 0 and box.w <= 20); // term 영역 안(오버플로/언더플로 없음)
    try std.testing.expect(box.x >= 40); // 사이드바 오른쪽 유지

    // term_cols==0이면 생략(중앙배치 뺄셈 언더플로 방지) — notice와 동일.
    out.clearRetainingCapacity();
    const narrow = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 45, .backing_height_px = 600 } };
    try view(&s, narrow, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // term_w=5px < cw=8 → term_cols=0 → 생략
}
