const std = @import("std");

pub const Action = union(enum) {
    // 워크스페이스(사이드바 탭) 단위. cmux 풀 모델에선 ⌘⇧T/⌘⇧[]가 워크스페이스, ⌘T/⌘[]는 아래 Term이다.
    new_tab,
    close_tab,
    select_tab: usize,
    previous_tab,
    next_tab,
    // 활성 pane 안의 Term(가로 탭 = 터미널) 단위(cmux식). ⌘T=새 Term, ⌘W=활성 Term 닫기(마지막이면 pane→워크
    // 스페이스로 cascade), ⌘]/⌘[=다음/이전 Term. 워크스페이스(위)와 modifier(shift 유무)로 갈린다.
    new_term,
    close_term,
    previous_term,
    next_term,
    // 활성 panel을 둘로 나눈다(split). horizontal=좌우(새 panel이 오른쪽), vertical=상하(새 panel이 아래).
    // 방향 이름은 분할선(divider)의 방향이 아니라 '나란히 놓이는 축'을 따른다 — 단일 출처: docs/tabs-splits-layout.md.
    split_horizontal,
    split_vertical,
    // split 탭에서 포커스를 방향으로 옮긴다(키보드 pane 이동). 방향 반평면 + 정렬로 인접 panel을 고른다.
    focus_pane_left,
    focus_pane_right,
    focus_pane_up,
    focus_pane_down,
};

pub fn parseAction(value: []const u8) ?Action {
    // Action parsing lives away from theme/config structs because keybinding
    // grammar will grow independently from colors and font settings.
    if (std.mem.eql(u8, value, "new_tab")) return .new_tab;
    if (std.mem.eql(u8, value, "close_tab")) return .close_tab;
    if (std.mem.eql(u8, value, "previous_tab")) return .previous_tab;
    if (std.mem.eql(u8, value, "next_tab")) return .next_tab;
    if (std.mem.eql(u8, value, "split_horizontal")) return .split_horizontal;
    if (std.mem.eql(u8, value, "split_vertical")) return .split_vertical;
    if (std.mem.eql(u8, value, "focus_pane_left")) return .focus_pane_left;
    if (std.mem.eql(u8, value, "focus_pane_right")) return .focus_pane_right;
    if (std.mem.eql(u8, value, "focus_pane_up")) return .focus_pane_up;
    if (std.mem.eql(u8, value, "focus_pane_down")) return .focus_pane_down;
    if (std.mem.eql(u8, value, "new_term")) return .new_term;
    if (std.mem.eql(u8, value, "close_term")) return .close_term;
    if (std.mem.eql(u8, value, "previous_term")) return .previous_term;
    if (std.mem.eql(u8, value, "next_term")) return .next_term;

    const prefix = "select_tab:";
    if (std.mem.startsWith(u8, value, prefix)) {
        const index = std.fmt.parseUnsigned(usize, value[prefix.len..], 10) catch return null;
        return .{ .select_tab = index };
    }

    return null;
}

/// 전역(OS) 단축키 전용 동작 — 앱이 비활성이어도 OS가 단축키를 잡아 Swift가 수행한다. 창 가시성 같은
/// NSWindow 동작이라 Zig의 `dispatchAppAction`(터미널/탭 조작)이 할 수 없다. 그래서 in-app `Action`과
/// 분리한다(별도 enum — `dispatchAppAction`의 exhaustive switch를 오염시키지 않는다. unbind와 같은 결정).
pub const GlobalAction = enum {
    toggle_window, // 창이 숨김/비활성이면 보이고 앞으로(show+activate), 활성+보임이면 숨김(orderOut) — 진짜 토글.
    show_window, // 항상 창을 보이고 앞으로 가져온다(숨기지 않음).
};

/// 전역 단축키 동작 문자열을 파싱한다(`global:<chord> = <여기>`). 알 수 없으면 null(forgiving).
pub fn parseGlobalAction(value: []const u8) ?GlobalAction {
    if (std.mem.eql(u8, value, "toggle_window")) return .toggle_window;
    if (std.mem.eql(u8, value, "show_window")) return .show_window;
    return null;
}

test "parse configured actions" {
    try std.testing.expectEqual(Action.new_tab, parseAction("new_tab").?);
    try std.testing.expectEqual(Action.close_tab, parseAction("close_tab").?);

    try std.testing.expectEqual(Action.split_horizontal, parseAction("split_horizontal").?);
    try std.testing.expectEqual(Action.split_vertical, parseAction("split_vertical").?);
    try std.testing.expectEqual(Action.focus_pane_left, parseAction("focus_pane_left").?);
    try std.testing.expectEqual(Action.focus_pane_down, parseAction("focus_pane_down").?);
    try std.testing.expectEqual(Action.new_term, parseAction("new_term").?);
    try std.testing.expectEqual(Action.close_term, parseAction("close_term").?);
    try std.testing.expectEqual(Action.next_term, parseAction("next_term").?);
    try std.testing.expectEqual(Action.previous_term, parseAction("previous_term").?);

    const action = parseAction("select_tab:3").?;
    try std.testing.expectEqual(@as(usize, 3), action.select_tab);
    try std.testing.expect(parseAction("unknown") == null);
}

test "parse global actions" {
    try std.testing.expectEqual(GlobalAction.toggle_window, parseGlobalAction("toggle_window").?);
    try std.testing.expectEqual(GlobalAction.show_window, parseGlobalAction("show_window").?);
    try std.testing.expect(parseGlobalAction("new_tab") == null); // in-app action은 전역 동작이 아님
    try std.testing.expect(parseGlobalAction("unknown") == null);
}
