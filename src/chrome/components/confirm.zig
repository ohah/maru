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
const modal_box = @import("modal_box.zig");

/// 이 컴포넌트가 그리는 레이어(최상위 모달, modal_box 공유 — notice와 동일). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = modal_box.layer;

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

/// 메시지 줄 + 안내 줄(2줄)을 중앙 모달 박스로 그린다 — 박스 기하·폭 clamp·soft-lock 가드·배경 quad+테두리는
/// modal_box.view 단일 출처에 위임한다(notice는 1줄, confirm은 2줄). 안 열렸으면 무동작. 메시지=surface_fg,
/// 안내=muted_fg(위계). 순수: state·props·tokens만 읽는다.
pub fn view(
    state: *const State,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (!state.open) return;
    try modal_box.view(&.{
        .{ .text = state.message, .role = .surface_fg },
        .{ .text = hint, .role = .muted_fg },
    }, p, tk, arena, out);
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
    // 모달 박스는 터미널 영역(사이드바 오른쪽) 안. 박스 기하 엣지케이스(soft-lock 가드·폭 clamp·rich 패딩)는
    // modal_box.zig 테스트가 단일 출처로 커버한다(여긴 confirm이 2줄을 넘겨 4 ops·역할·줄 순서를 내는지 위임 확인).
    try std.testing.expect(out.items[0].quad.rect.x >= 40);
}
