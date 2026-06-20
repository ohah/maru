//! Confirm — 예/아니오 확인 다이얼로그(키보드 전용, hit-test 없음). **재사용 가능한 디자인 시스템 컴포넌트**:
//! 메시지 + 두 버튼 라벨을 host가 주입하면(`show(message, .{ .confirm = "닫기", .cancel = "취소" })`) 경계선 패널 +
//! 가운데 버튼 두 개(라벨에 TUI식 [Y]/[N] 단축키)를 그리고, ←/→로 포커스를 옮기면 accent 강조가 따라간다(Enter는
//! 포커스된 버튼 실행). 닫기 확인뿐 아니라 삭제·저장 등 어떤 확인에도 쓴다 —
//! 컴포넌트는 "무엇을 확인하는지"를 모르고(중립), handle은 의도(confirmed/cancelled)만 돌려준다. host가 confirmed면
//! 보류한 동작을 실행, cancelled면 버린다. chrome 계약: State(순수 데이터+전이) + view(순수) + handle(intent 반환).
//! 박스 기하·중앙배치·폭 clamp는 modal_box 프리미티브(단일 출처)에 위임한다. 단일 출처: docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const modal_box = @import("modal_box.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW 표시폭) — 중앙 정렬·박스 폭 계산

/// 이 컴포넌트가 그리는 레이어(최상위 모달, modal_box 공유 — notice와 동일). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = modal_box.layer;

/// 버튼에 표시하는 단축키 마커 — TUI 관례의 Y/N(Enter/Esc도 handle이 받지만, 표시는 짧은 Y/N로 통일해 영어
/// 단어를 안 섞는다). 버튼 라벨 앞에 "[Y] "/"[N] "로 붙여 어느 키가 어느 버튼인지 보인다(키는 handle이 고정).
const key_confirm = "Y";
const key_cancel = "N";

/// show가 받는 버튼 라벨(기본값 있음). 호출자는 `.{}`(기본 확인/취소)나 `.{ .confirm = "삭제", .cancel = "취소" }`처럼
/// 용도에 맞는 라벨을 준다 — 컴포넌트가 닫기 전용이 아니라 범용이게 하는 재사용 seam.
pub const Buttons = struct {
    confirm: []const u8 = "확인",
    cancel: []const u8 = "취소",
};

/// 어느 버튼에 포커스가 있나(←/→로 이동). Enter가 포커스된 버튼을 실행한다. 열 때마다 기본 = confirm(Enter=확정 유지).
pub const Focus = enum { confirm, cancel };

/// 순수 상태 — message + 버튼 라벨 + 포커스 + open 플래그. host가 보류(pending)하며 show를 부른다. 라벨은 show가 채운다.
pub const State = struct {
    open: bool = false,
    message: []const u8 = "",
    confirm_label: []const u8 = "확인",
    cancel_label: []const u8 = "취소",
    focused: Focus = .confirm,

    pub fn show(self: *State, message: []const u8, buttons: Buttons) void {
        self.message = message;
        self.confirm_label = buttons.confirm;
        self.cancel_label = buttons.cancel;
        self.focused = .confirm; // 열 때마다 기본 포커스 = 확정 버튼(Enter=확정, ←/→로 이동)
        self.open = true;
    }

    pub fn dismiss(self: *State) void {
        self.open = false;
    }
};

/// handle이 돌려주는 intent. host가 받아 후처리한다 — confirmed면 보류한 동작을 실행, cancelled면 버린다.
/// (notice는 dismissed 하나뿐이지만 confirm은 파괴적 동작 분기라 둘로 나뉜다.)
pub const Action = enum { confirmed, cancelled };

/// 키 이벤트 처리. 열려 있을 때만 동작:
///   ←/→ : 두 버튼 사이 포커스 이동(소비, intent 없음 → host가 재렌더). Enter : **포커스된** 버튼 실행
///   (confirm/cancelled). Esc : 항상 cancelled(취소 관례). Y/N : 포커스와 무관하게 직접 실행(대소문자 무시 단축키).
/// 그 외 키는 소비하되 Action 없음(모달이라 뒤(터미널)로 안 흘린다). 닫혀 있으면 null(라우팅 안 가로챔).
pub fn handle(ev: input.InputEvent, state: *State) ?Action {
    if (!state.open) return null;
    switch (ev) {
        .key => |k| switch (k.key) {
            .left, .right => {
                // 버튼이 둘뿐이라 좌/우 모두 토글. 포커스만 바꾸고 소비(host가 재렌더, 결정은 아직).
                state.focused = if (state.focused == .confirm) .cancel else .confirm;
                return null;
            },
            .enter => {
                state.dismiss();
                return if (state.focused == .confirm) .confirmed else .cancelled; // 포커스된 버튼 실행
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

/// 확인 다이얼로그를 그린다 — 경계선 패널(modal_box.frame) 안에 (1) 메시지(중앙), (2) 가운데 버튼 행: **포커스된**
/// 버튼이 accent 배경(focus_accent) + 대비색 라벨로 강조되고 나머지는 은은한 배경(tab_hover_bg)이다(←/→로 강조가
/// 옮겨감). 두 버튼 다 라벨에 TUI식 단축키 마커([Y]/[N])를 단다(별도 영어 키 줄 없음). 안 열렸으면 무동작. 박스
/// 기하/중앙배치/폭 clamp/soft-lock은 modal_box 단일 출처. 순수: state·props·tokens만 읽는다.
pub fn view(
    state: *const State,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (!state.open) return;

    // 버튼 라벨에 단축키 마커를 통합한다("[Y] 닫기"·"[N] 취소") — 영어 단어(Enter/Esc) 줄 없이 TUI식 Y/N 단축키를
    // 버튼 안에 보인다. arena에 만들어 view 동안 유효(out의 text op이 이 슬라이스를 가리킴).
    const confirm_text = try std.fmt.allocPrint(arena, "[{s}] {s}", .{ key_confirm, state.confirm_label });
    const cancel_text = try std.fmt.allocPrint(arena, "[{s}] {s}", .{ key_cancel, state.cancel_label });
    const msg_cols = overlay_input.displayCols(state.message);
    const confirm_cols = overlay_input.displayCols(confirm_text);
    const cancel_cols = overlay_input.displayCols(cancel_text);
    const btn_pad = 1; // 버튼 라벨 좌우 패딩(배경이 라벨을 감싸 버튼처럼 보이게)
    const default_btn_cols = confirm_cols + 2 * btn_pad;
    const cancel_btn_cols = cancel_cols + 2 * btn_pad; // 보조 버튼도 같은 패딩 — 둘 다 버튼 느낌
    const gap = 2; // 두 버튼 사이 간격(칸) — 둘 다 버튼이라 살짝 좁혀 균형
    const btn_row_cols = default_btn_cols + gap + cancel_btn_cols;
    const content_cols = @max(msg_cols, btn_row_cols);

    // 콘텐츠 3행: 0=메시지, 1=(빈 줄), 2=버튼([Y]/[N] 단축키 포함). modal_box가 사방 여백을 더해 패널처럼 보이게 한다.
    const box = modal_box.layout(content_cols, 3, p, tk) orelse return;
    try modal_box.frame(box, p, arena, out);

    // (1) 메시지 — 중앙.
    try modal_box.text(box, modal_box.centerX(box, msg_cols), 0, state.message, .surface_fg, arena, out);

    // (2) 버튼 행 — 그룹(기본+gap+보조)을 중앙 정렬. **둘 다 배경 fill로 버튼처럼** 보이게 한다(painter order: bg→glyph).
    //     **포커스된 버튼이 accent**(focus_accent + 대비색 surface_bg 라벨)로 강조되고, 나머지는 은은한 배경
    //     (tab_hover_bg + surface_fg 라벨)이다. ←/→로 포커스가 옮겨가면 강조도 따라 이동한다(어느 버튼이 Enter
    //     대상인지 보임). 라벨은 버튼 패딩만큼 우측에서 시작.
    const confirm_focused = state.focused == .confirm;
    const confirm_bg: tokens.ColorRole = if (confirm_focused) .focus_accent else .tab_hover_bg;
    const confirm_fg: tokens.ColorRole = if (confirm_focused) .surface_bg else .surface_fg;
    const cancel_bg: tokens.ColorRole = if (confirm_focused) .tab_hover_bg else .focus_accent;
    const cancel_fg: tokens.ColorRole = if (confirm_focused) .surface_fg else .surface_bg;
    const group_x = modal_box.centerX(box, btn_row_cols);
    try modal_box.fillCells(box, group_x, 2, default_btn_cols, confirm_bg, arena, out);
    try modal_box.text(box, group_x + @as(i32, @intCast(btn_pad * box.cw)), 2, confirm_text, confirm_fg, arena, out);
    const cancel_btn_x = group_x + @as(i32, @intCast((default_btn_cols + gap) * box.cw));
    try modal_box.fillCells(box, cancel_btn_x, 2, cancel_btn_cols, cancel_bg, arena, out);
    try modal_box.text(box, cancel_btn_x + @as(i32, @intCast(btn_pad * box.cw)), 2, cancel_text, cancel_fg, arena, out);
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// 헤드리스로 (1) 상태 전이+라벨 주입 (2) 입력→intent 2-갈래 (3) view가 버튼 다이얼로그 구조를 내는지 증명한다.

test "confirm state: show가 메시지+버튼 라벨을 주입, dismiss로 닫힘(재사용 — 라벨 가변)" {
    var s = State{};
    try std.testing.expect(!s.open);
    s.show("정말 삭제할까요?", .{ .confirm = "삭제", .cancel = "취소" });
    try std.testing.expect(s.open);
    try std.testing.expectEqualStrings("정말 삭제할까요?", s.message);
    try std.testing.expectEqualStrings("삭제", s.confirm_label); // 닫기 전용이 아니라 라벨 주입(재사용)
    try std.testing.expectEqualStrings("취소", s.cancel_label);
    s.dismiss();
    try std.testing.expect(!s.open);
    // 기본 라벨(.{})도 동작.
    s.show("x", .{});
    try std.testing.expectEqualStrings("확인", s.confirm_label);
}

test "confirm handle: Enter/Y=confirmed · Esc/N=cancelled · 닫힘이면 null · 다른 키는 소비" {
    var s = State{};
    // 닫혀 있으면 무동작(라우팅 안 가로챔).
    try std.testing.expect(handle(.{ .key = .{ .key = .enter } }, &s) == null);

    s.show("x", .{});
    try std.testing.expectEqual(Action.confirmed, handle(.{ .key = .{ .key = .enter } }, &s).?);
    try std.testing.expect(!s.open); // confirmed면 닫힘

    s.show("x", .{});
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .{ .key = .escape } }, &s).?);
    try std.testing.expect(!s.open); // cancelled면 닫힘

    s.show("x", .{});
    try std.testing.expectEqual(Action.confirmed, handle(.{ .key = .{ .key = .char, .codepoint = 'y' } }, &s).?);
    s.show("x", .{});
    try std.testing.expectEqual(Action.confirmed, handle(.{ .key = .{ .key = .char, .codepoint = 'Y' } }, &s).?);
    s.show("x", .{});
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .{ .key = .char, .codepoint = 'n' } }, &s).?);
    s.show("x", .{});
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .{ .key = .char, .codepoint = 'N' } }, &s).?);

    // 다른 글자는 소비만(intent 없음, 모달이라 뒤로 안 샘) — 여전히 열려 있음.
    s.show("x", .{});
    try std.testing.expect(handle(.{ .key = .{ .key = .char, .codepoint = 'a' } }, &s) == null);
    try std.testing.expect(s.open);
}

test "confirm handle: ←/→로 포커스 이동, Enter는 포커스된 버튼 실행 (Esc는 항상 취소)" {
    var s = State{};
    s.show("x", .{}); // 기본 포커스 = confirm
    try std.testing.expectEqual(Focus.confirm, s.focused);

    // → 이동 → cancel 포커스(소비, intent 없음 — 재렌더는 host).
    try std.testing.expect(handle(.{ .key = .{ .key = .right } }, &s) == null);
    try std.testing.expectEqual(Focus.cancel, s.focused);
    try std.testing.expect(s.open); // 포커스 이동은 안 닫음

    // 이 상태에서 Enter → 포커스된 cancel 실행(닫기 아님!).
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .{ .key = .enter } }, &s).?);
    try std.testing.expect(!s.open);

    // ← 도 토글(버튼 둘뿐) — confirm→cancel.
    s.show("x", .{});
    try std.testing.expect(handle(.{ .key = .{ .key = .left } }, &s) == null);
    try std.testing.expectEqual(Focus.cancel, s.focused);
    // 다시 ← → confirm으로.
    try std.testing.expect(handle(.{ .key = .{ .key = .left } }, &s) == null);
    try std.testing.expectEqual(Focus.confirm, s.focused);
    // confirm 포커스에서 Enter → confirmed.
    try std.testing.expectEqual(Action.confirmed, handle(.{ .key = .{ .key = .enter } }, &s).?);

    // Esc는 포커스와 무관하게 항상 취소.
    s.show("x", .{});
    _ = handle(.{ .key = .{ .key = .right } }, &s); // cancel 포커스로 옮겨도
    s.focused = .confirm; // 다시 confirm 포커스라도
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .{ .key = .escape } }, &s).?);
}

test "confirm view: 닫힘이면 ops 0, 열림이면 패널(quad+border)+accent 기본 버튼+메시지·버튼·키 텍스트" {
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

    s.show("실행 중인 명령이 있습니다.", .{ .confirm = "닫기", .cancel = "취소" });
    try view(&s, p, &tk, arena, &out);
    // 프레임이 먼저(quad 배경 + border 테두리).
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[1] == .border);
    // 구조: 두 버튼 배경 fill(기본=accent, 보조=tab_hover_bg) + 메시지 + 단축키 통합 버튼 라벨("[Y] 닫기"/"[N] 취소").
    // 영어 단어(Enter/Esc) 줄은 없다 — 단축키는 [Y]/[N]로 라벨에 통합. 순서에 무관하게 존재 확인.
    var saw_accent_fill = false;
    var saw_cancel_fill = false;
    var saw_msg = false;
    var saw_confirm = false;
    var saw_cancel = false;
    for (out.items) |op| switch (op) {
        .fill => |f| {
            if (f.role == .focus_accent) saw_accent_fill = true;
            if (f.role == .tab_hover_bg) saw_cancel_fill = true;
        },
        .text => |t| {
            const txt = t.runs[0].text;
            if (std.mem.eql(u8, txt, "실행 중인 명령이 있습니다.")) saw_msg = true;
            if (std.mem.eql(u8, txt, "[Y] 닫기")) saw_confirm = true; // 단축키 통합 라벨
            if (std.mem.eql(u8, txt, "[N] 취소")) saw_cancel = true;
        },
        else => {},
    };
    try std.testing.expect(saw_accent_fill); // 기본 버튼이 accent 배경으로 강조됨
    try std.testing.expect(saw_cancel_fill); // 보조 버튼(취소)도 배경 fill로 버튼 느낌
    try std.testing.expect(saw_msg and saw_confirm and saw_cancel); // 메시지 + [Y]/[N] 버튼 라벨
    // 박스는 터미널 영역(사이드바 오른쪽) 안. 기하 엣지케이스는 modal_box.zig 테스트가 단일 출처로 커버.
    try std.testing.expect(out.items[0].quad.rect.x >= 40);
}

test "confirm view: 포커스가 accent 강조를 이동시킨다(←/→ 선택 가시화)" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // accent(focus_accent) fill의 x를 찾는 헬퍼 — 포커스된 버튼 위치.
    const findAccentX = struct {
        fn run(ops: []const draw.Op) i32 {
            for (ops) |op| switch (op) {
                .fill => |f| if (f.role == .focus_accent) return f.rect.x,
                else => {},
            };
            return -1;
        }
    }.run;

    var s = State{};
    var out_confirm: std.ArrayList(draw.Op) = .empty;
    s.show("실행 중인 명령이 있습니다.", .{ .confirm = "닫기", .cancel = "취소" }); // 기본 포커스 = confirm(왼쪽 버튼)
    try view(&s, p, &tk, arena, &out_confirm);
    const accent_x_confirm = findAccentX(out_confirm.items);

    var out_cancel: std.ArrayList(draw.Op) = .empty;
    s.focused = .cancel; // 포커스를 취소(오른쪽 버튼)로
    try view(&s, p, &tk, arena, &out_cancel);
    const accent_x_cancel = findAccentX(out_cancel.items);

    try std.testing.expect(accent_x_confirm >= 0 and accent_x_cancel >= 0);
    // 포커스가 오른쪽(취소) 버튼으로 가면 accent 강조도 오른쪽으로 이동한다.
    try std.testing.expect(accent_x_cancel > accent_x_confirm);
}
