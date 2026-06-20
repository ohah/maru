//! Confirm — 예/아니오 확인 다이얼로그(키보드 전용, hit-test 없음). **재사용 가능한 디자인 시스템 컴포넌트**:
//! 메시지 + 두 버튼 라벨을 host가 주입하면(`show(message, .{ .confirm = "닫기", .cancel = "취소" })`) 경계선 패널 +
//! accent 기본 버튼 + 보조 버튼 + 키 안내(Enter/Esc)를 그린다. 닫기 확인뿐 아니라 삭제·저장 등 어떤 확인에도 쓴다 —
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

/// 버튼 아래에 그리는 정적 키 라벨 — 어느 키가 어느 버튼인지(Enter=기본, Esc=취소). 키는 handle이 고정하므로
/// (Enter/Y=confirm, Esc/N=cancel) 라벨도 정적이다. 버튼 라벨(닫기/삭제 등)과 달리 host가 안 바꾼다.
const key_confirm = "Enter";
const key_cancel = "Esc";

/// show가 받는 버튼 라벨(기본값 있음). 호출자는 `.{}`(기본 확인/취소)나 `.{ .confirm = "삭제", .cancel = "취소" }`처럼
/// 용도에 맞는 라벨을 준다 — 컴포넌트가 닫기 전용이 아니라 범용이게 하는 재사용 seam.
pub const Buttons = struct {
    confirm: []const u8 = "확인",
    cancel: []const u8 = "취소",
};

/// 순수 상태 — message + 버튼 라벨 + open 플래그. host가 보류(pending)하며 show를 부른다. 라벨은 show가 채운다.
pub const State = struct {
    open: bool = false,
    message: []const u8 = "",
    confirm_label: []const u8 = "확인",
    cancel_label: []const u8 = "취소",

    pub fn show(self: *State, message: []const u8, buttons: Buttons) void {
        self.message = message;
        self.confirm_label = buttons.confirm;
        self.cancel_label = buttons.cancel;
        self.open = true;
    }

    pub fn dismiss(self: *State) void {
        self.open = false;
    }
};

/// handle이 돌려주는 intent. host가 받아 후처리한다 — confirmed면 보류한 동작을 실행, cancelled면 버린다.
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

/// 확인 다이얼로그를 그린다 — 경계선 패널(modal_box.frame) 안에 (1) 메시지(중앙), (2) 가운데 버튼 행: 기본 버튼은
/// accent 배경(focus_accent) + 대비색 라벨로 강조, 보조 버튼은 plain, (3) 버튼 아래 키 안내(Enter/Esc, muted). 안
/// 열렸으면 무동작. 박스 기하/중앙배치/폭 clamp/soft-lock은 modal_box 단일 출처. 순수: state·props·tokens만 읽는다.
pub fn view(
    state: *const State,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (!state.open) return;

    const msg_cols = overlay_input.displayCols(state.message);
    const confirm_cols = overlay_input.displayCols(state.confirm_label);
    const cancel_cols = overlay_input.displayCols(state.cancel_label);
    const btn_pad = 1; // 기본 버튼 라벨 좌우 패딩(accent 배경이 라벨을 감싸 버튼처럼 보이게)
    const default_btn_cols = confirm_cols + 2 * btn_pad;
    const gap = 3; // 두 버튼 사이 간격(칸)
    const btn_row_cols = default_btn_cols + gap + cancel_cols;
    const content_cols = @max(msg_cols, btn_row_cols);

    // 콘텐츠 4행: 0=메시지, 1=(빈 줄), 2=버튼, 3=키 라벨. modal_box가 사방 여백을 더해 패널처럼 보이게 한다.
    const box = modal_box.layout(content_cols, 4, p, tk) orelse return;
    try modal_box.frame(box, p, arena, out);

    // (1) 메시지 — 중앙.
    try modal_box.text(box, modal_box.centerX(box, msg_cols), 0, state.message, .surface_fg, arena, out);

    // (2) 버튼 행 — 그룹(기본+gap+보조)을 중앙 정렬. 기본 버튼: accent 배경 fill 먼저(painter order: bg→glyph) +
    //     대비색(surface_bg) 라벨. 보조 버튼: plain(surface_fg). 라벨은 버튼 패딩만큼 우측에서 시작.
    const group_x = modal_box.centerX(box, btn_row_cols);
    try modal_box.fillCells(box, group_x, 2, default_btn_cols, .focus_accent, arena, out);
    try modal_box.text(box, group_x + @as(i32, @intCast(btn_pad * box.cw)), 2, state.confirm_label, .surface_bg, arena, out);
    const cancel_x = group_x + @as(i32, @intCast((default_btn_cols + gap) * box.cw));
    try modal_box.text(box, cancel_x, 2, state.cancel_label, .surface_fg, arena, out);

    // (3) 키 안내 — Enter는 기본 버튼 아래 중앙, Esc는 보조 버튼 아래 중앙(muted). 각 버튼 영역 폭 안에서 가운데.
    const enter_off = (default_btn_cols -| overlay_input.displayCols(key_confirm)) / 2;
    try modal_box.text(box, group_x + @as(i32, @intCast(enter_off * box.cw)), 3, key_confirm, .muted_fg, arena, out);
    const esc_off = (cancel_cols -| overlay_input.displayCols(key_cancel)) / 2;
    try modal_box.text(box, cancel_x + @as(i32, @intCast(esc_off * box.cw)), 3, key_cancel, .muted_fg, arena, out);
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
    // 구조: accent 기본 버튼 배경 fill 1개 + 메시지·기본라벨·보조라벨·키(Enter/Esc) 텍스트. 순서에 무관하게 존재 확인.
    var saw_accent_fill = false;
    var saw_msg = false;
    var saw_confirm = false;
    var saw_cancel = false;
    var saw_enter = false;
    var saw_esc = false;
    for (out.items) |op| switch (op) {
        .fill => |f| if (f.role == .focus_accent) {
            saw_accent_fill = true;
        },
        .text => |t| {
            const txt = t.runs[0].text;
            if (std.mem.eql(u8, txt, "실행 중인 명령이 있습니다.")) saw_msg = true;
            if (std.mem.eql(u8, txt, "닫기")) saw_confirm = true;
            if (std.mem.eql(u8, txt, "취소")) saw_cancel = true;
            if (std.mem.eql(u8, txt, key_confirm)) saw_enter = true;
            if (std.mem.eql(u8, txt, key_cancel)) saw_esc = true;
        },
        else => {},
    };
    try std.testing.expect(saw_accent_fill); // 기본 버튼이 accent 배경으로 강조됨
    try std.testing.expect(saw_msg and saw_confirm and saw_cancel and saw_enter and saw_esc);
    // 박스는 터미널 영역(사이드바 오른쪽) 안. 기하 엣지케이스는 modal_box.zig 테스트가 단일 출처로 커버.
    try std.testing.expect(out.items[0].quad.rect.x >= 40);
}
