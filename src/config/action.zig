const std = @import("std");

pub const Action = union(enum) {
    // 워크스페이스(사이드바 탭) 단위. 탭 풀 모델에선 ⌘⇧T/⌘⇧[]가 워크스페이스, ⌘T/⌘[]는 아래 Term이다.
    new_tab,
    close_tab,
    select_tab: usize,
    previous_tab,
    next_tab,
    // 활성 pane 안의 Term(가로 탭 = 터미널) 단위(탭 모델). ⌘T=새 Term, ⌘W=활성 Term 닫기(마지막이면 pane→워크
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
    // 활성 터미널의 전체 내용(스크롤백 + 화면)을 선택한다(Select All, 관례상 ⌘A). 코어 selection 상태라
    // dispatchAppAction이 core.selectAll로 넘긴다. clipboard 쓰기(copy)는 NSPasteboard(OS) 소유라 Action이
    // 아니다(경계: Zig는 selection, Swift는 clipboard).
    select_all,
    // 커맨드 팝업(Cmd+Shift+P)을 토글한다. 앱 UI 상태(PaletteState)라 dispatchAppAction이 열고/닫는다.
    // 카탈로그(command_catalog.entries)에는 안 넣는다 — 팝업이 자기 토글을 목록에 보이는 재귀를 피한다.
    toggle_command_palette,
    // 스크롤백 Find(⌘F)를 토글한다. 앱 UI 상태(chrome find 컴포넌트)라 dispatchAppAction이 열고/닫는다.
    // 모달이 열린 동안 키는 검색 입력으로 라우팅된다(handleKeyEvent). **카탈로그에 넣어 커맨드 팝업에 노출한다**
    // (선택 시 acceptPalette가 팝업을 닫고 Find를 연다) — 자기 토글이라 재귀인 toggle_command_palette와 달리 Find는
    // 별개 모달이라 띄워도 된다. 단 메뉴 Find 서브메뉴는 keyEquivalent 없이 따로(키바인딩 가림 방지).
    toggle_find,
    // 스크롤백 Find의 다음/이전 매치로 이동(⌘G/⌘⇧G) — **오버레이가 닫혀 있어도** 동작한다(보존된 검색어로
    // 재검색해 네비게이션, macOS Find Next 관례). dispatchAppAction이 findNavigate로 넘긴다. 오버레이가 열린
    // 동안엔 모달 라우팅이 키를 가로채므로(Enter/Shift+Enter가 next/prev) 이 액션은 닫힌 경우를 위한 것이다.
    find_next,
    find_previous,
    // 런타임 폰트 크기 조절(⌘+/⌘-/⌘0). dispatchAppAction이 appearance.font.size를 바꾸고 cell 메트릭·grid를
    // 다시 잡는다(코어 resize와 같은 reflow). step은 DevSession 상수(1pt 고정 — 파라미터화는 후속). reset은
    // config 기본값(base_font_size)으로 되돌린다. 콘텐츠 reflow는 없다(셀 크기·grid 차원만 변경, Ghostty 동일).
    increase_font_size,
    decrease_font_size,
    reset_font_size,
    // 런타임 폰트 크기를 절대값(pt)으로 지정한다. config 바인딩 전용(`set_font_size:18`처럼) — 절대값이라
    // 메뉴/팝업엔 안 넣는다(어느 크기인지 고정 못 함). dispatchAppAction이 setFontSize로 넘겨 [6,72]pt로 클램프.
    // 키 프리셋(예: ⌘⌥1=14, ⌘⌥2=18)을 사용자가 직접 묶을 수 있다.
    set_font_size: f32,
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
    if (std.mem.eql(u8, value, "select_all")) return .select_all;
    if (std.mem.eql(u8, value, "toggle_command_palette")) return .toggle_command_palette;
    if (std.mem.eql(u8, value, "toggle_find")) return .toggle_find;
    if (std.mem.eql(u8, value, "find_next")) return .find_next;
    if (std.mem.eql(u8, value, "find_previous")) return .find_previous;
    if (std.mem.eql(u8, value, "increase_font_size")) return .increase_font_size;
    if (std.mem.eql(u8, value, "decrease_font_size")) return .decrease_font_size;
    if (std.mem.eql(u8, value, "reset_font_size")) return .reset_font_size;

    const prefix = "select_tab:";
    if (std.mem.startsWith(u8, value, prefix)) {
        const index = std.fmt.parseUnsigned(usize, value[prefix.len..], 10) catch return null;
        return .{ .select_tab = index };
    }

    const fs_prefix = "set_font_size:";
    if (std.mem.startsWith(u8, value, fs_prefix)) {
        const size = std.fmt.parseFloat(f32, value[fs_prefix.len..]) catch return null;
        if (!std.math.isFinite(size)) return null; // nan/inf 거부(std.meta.eql 비교·클램프 안전)
        return .{ .set_font_size = size };
    }

    return null;
}

/// 전역(OS) 단축키 전용 동작 — 앱이 비활성이어도 OS가 단축키를 잡아 Swift가 수행한다. 창 가시성 같은
/// NSWindow 동작이라 Zig의 `dispatchAppAction`(터미널/탭 조작)이 할 수 없다. 그래서 in-app `Action`과
/// 분리한다(별도 enum — `dispatchAppAction`의 exhaustive switch를 오염시키지 않는다. unbind와 같은 결정).
pub const GlobalAction = enum {
    toggle_window, // 창이 숨김/비활성이면 보이고 앞으로(show+activate), 활성+보임이면 숨김(orderOut) — 진짜 토글.
    show_window, // 항상 창을 보이고 앞으로 가져온다(숨기지 않음).
    toggle_quick_terminal, // quick terminal(별도 세션 오버레이 패널)을 토글한다 — 숨김이면 보이고, 보임이면 숨김.
};

/// 전역 단축키 동작 문자열을 파싱한다(`global:<chord> = <여기>`). 알 수 없으면 null(forgiving).
pub fn parseGlobalAction(value: []const u8) ?GlobalAction {
    if (std.mem.eql(u8, value, "toggle_window")) return .toggle_window;
    if (std.mem.eql(u8, value, "show_window")) return .show_window;
    if (std.mem.eql(u8, value, "toggle_quick_terminal")) return .toggle_quick_terminal;
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
    try std.testing.expectEqual(Action.select_all, parseAction("select_all").?);
    try std.testing.expectEqual(Action.toggle_command_palette, parseAction("toggle_command_palette").?);
    try std.testing.expectEqual(Action.toggle_find, parseAction("toggle_find").?);
    try std.testing.expectEqual(Action.find_next, parseAction("find_next").?);
    try std.testing.expectEqual(Action.find_previous, parseAction("find_previous").?);
    try std.testing.expectEqual(Action.increase_font_size, parseAction("increase_font_size").?);
    try std.testing.expectEqual(Action.decrease_font_size, parseAction("decrease_font_size").?);
    try std.testing.expectEqual(Action.reset_font_size, parseAction("reset_font_size").?);

    const action = parseAction("select_tab:3").?;
    try std.testing.expectEqual(@as(usize, 3), action.select_tab);
    try std.testing.expect(parseAction("unknown") == null);

    // set_font_size:N — 절대 폰트 크기(파라미터 액션). 정수·소수 모두, 비숫자·비유한은 null.
    try std.testing.expectEqual(@as(f32, 18), parseAction("set_font_size:18").?.set_font_size);
    try std.testing.expectEqual(@as(f32, 13.5), parseAction("set_font_size:13.5").?.set_font_size);
    try std.testing.expect(parseAction("set_font_size:abc") == null);
    try std.testing.expect(parseAction("set_font_size:") == null);
    try std.testing.expect(parseAction("set_font_size:inf") == null); // 비유한 거부
}

test "parse global actions" {
    try std.testing.expectEqual(GlobalAction.toggle_window, parseGlobalAction("toggle_window").?);
    try std.testing.expectEqual(GlobalAction.show_window, parseGlobalAction("show_window").?);
    try std.testing.expectEqual(GlobalAction.toggle_quick_terminal, parseGlobalAction("toggle_quick_terminal").?);
    try std.testing.expect(parseGlobalAction("new_tab") == null); // in-app action은 전역 동작이 아님
    try std.testing.expect(parseGlobalAction("unknown") == null);
}
