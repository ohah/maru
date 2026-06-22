//! Notice — 손상/오류 알림 모달(키보드 전용, hit-test 없음). chrome 컴포넌트 **계약의 exemplar**:
//!   State(순수 데이터+전이) + view(state, props, tokens → ChromeDraw, 순수) + handle(event, *state → ?Action).
//! 규칙(기존 palette/find 패턴 승계): State는 렌더를 모르고, view는 State를 읽기만, handle은 State를
//! mutate + intent(Action) 반환. 라이프사이클(언제 열고)은 host가 소유. 단일 출처: docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const modal_box = @import("modal_box.zig");

/// 이 컴포넌트가 그리는 레이어(최상위 모달, modal_box 공유). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = modal_box.layer;

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
/// host가 `.key`/`.pointer`를 가르므로(CS-4-0) 이 handle은 KeyEvent만 받는다 — 포인터는 host.handlePointer.
pub fn handle(k: input.InputEvent.KeyEvent, state: *State) ?Action {
    if (!state.open) return null;
    switch (k.key) {
        .enter, .escape => {
            state.dismiss();
            return .dismissed;
        },
        else => return null,
    }
}

/// 메시지 한 줄을 중앙 모달 박스로 그린다 — 박스 기하·폭 clamp·soft-lock 가드·배경 quad+테두리는 modal_box.view
/// 단일 출처에 위임한다(notice/confirm 공유). 안 열렸으면 무동작. 순수: state·props·tokens만 읽는다.
pub fn view(
    state: *const State,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (!state.open) return;
    try modal_box.view(&.{.{ .text = state.message, .role = .surface_fg }}, p, tk, arena, out);
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
    try std.testing.expect(handle(.{ .key = .enter }, &s) == null); // 닫혀 있으면 무동작
    s.show("x");
    try std.testing.expectEqual(Action.dismissed, handle(.{ .key = .escape }, &s).?);
    try std.testing.expect(!s.open);
    s.show("y");
    try std.testing.expectEqual(Action.dismissed, handle(.{ .key = .enter }, &s).?);
    s.show("z");
    try std.testing.expect(handle(.{ .key = .char, .codepoint = 'a' }, &s) == null); // 소비하되 action 없음
    try std.testing.expect(s.open); // 평문 키로는 안 닫힘
}

test "notice view: 닫힘이면 ops 0, 열림이면 quad+text(modal)" {
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
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[1] == .text);
    try std.testing.expectEqualStrings("file corrupt", out.items[1].text.runs[0].text);
    // 모달 박스는 터미널 영역(사이드바 오른쪽) 안, 화면 중앙쯤. 박스 기하 엣지케이스(soft-lock 가드·폭 clamp·
    // rich 패딩 침범)는 modal_box.zig 테스트가 단일 출처로 커버한다(notice/confirm 공유 — 여기선 위임만 확인).
    try std.testing.expect(out.items[0].quad.rect.x >= 40);
    try std.testing.expect(out.items[0].quad.rect.w > 0);
}
