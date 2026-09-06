//! Command 카탈로그 — 메뉴바·커맨드 팝업이 공유하는 "수행 가능한 액션 목록"의 단일 출처(Zig).
//! 각 엔트리는 `action_key`(= parseAction 문자열, 양방향)·사람이 읽는 `title`·현재 바인딩 표시 chord로
//! 구성된다. UI(NSMenu/SwiftUI)는 이 목록을 그리고 선택 시 action_key를 되돌려보내 dispatch만 한다
//! (네이티브 최소 — quick terminal·global hotkey와 같은 경계). Ghostty `ghostty_command_s`와 같은 형태.
//!
//! 베이스/의사결정: action 집합은 config/action.zig(단일 출처), title은 UI 표시 문자열이라 여기 둔다.
//! 바인딩 표시는 keybinding 테이블을 action→chord로 역스캔한다(resolve의 역). select_tab은 ⌘1..9에
//! 맞춰 0..8을 개별 엔트리로 편다(Ghostty goto_tab과 같은 결).

const std = @import("std");
const maru = @import("maru");

const Action = maru.config.Action;
const GlobalAction = maru.config.GlobalAction;
const GlobalBinding = maru.config.GlobalBinding;
const KeyChord = maru.config.KeyChord;
const KeyName = maru.config.keybinding.KeyName;
const KeyBindingResolver = maru.config.KeyBindingResolver;
const editor_context_bindings = maru.config.keybinding.editor_context_bindings;
const default_app_bindings = maru.config.keybinding.default_app_bindings;

/// 카탈로그 한 항목(정적). action_key/title은 컴파일타임 문자열 리터럴(널 종단) — ABI에서 그대로 가리킨다.
pub const Entry = struct {
    action: Action,
    key: [:0]const u8,
    title: [:0]const u8,
};

/// 메뉴·팝업에 노출할 in-app 액션 목록. action_key는 parseAction이 받는 문자열과 정확히 일치해야 한다
/// (round-trip 테스트가 고정). 순서 = 표시 순서(파생 정렬은 UI가 한다).
pub const entries = [_]Entry{
    .{ .action = .new_term, .key = "new_term", .title = "New Terminal" },
    .{ .action = .new_tab, .key = "new_tab", .title = "New Workspace" },
    // 활성 pane에 web(브라우저) Term 생성(4e-5 command 승격 — env 훅 MARU_WEB_PANEL 대체). 기본 키바인딩 ⌘⌥T(default_app_bindings 역스캔으로 메뉴·팔릿에 자동 표시).
    .{ .action = .new_web_tab, .key = "new_web_tab", .title = "New Browser Tab" },
    .{ .action = .open_file_panel, .key = "open_file_panel", .title = "Open File Panel…" },
    .{ .action = .close_focused, .key = "close_focused", .title = "Close" },
    .{ .action = .close_term, .key = "close_term", .title = "Close Terminal" },
    .{ .action = .close_tab, .key = "close_tab", .title = "Close Workspace" },
    .{ .action = .next_term, .key = "next_term", .title = "Next Terminal" },
    .{ .action = .previous_term, .key = "previous_term", .title = "Previous Terminal" },
    .{ .action = .next_tab, .key = "next_tab", .title = "Next Workspace" },
    .{ .action = .previous_tab, .key = "previous_tab", .title = "Previous Workspace" },
    .{ .action = .split_horizontal, .key = "split_horizontal", .title = "Split Right" },
    .{ .action = .split_vertical, .key = "split_vertical", .title = "Split Down" },
    .{ .action = .toggle_file_panel_dock_side, .key = "toggle_file_panel_dock_side", .title = "Move File Panel Right/Bottom" },
    .{ .action = .toggle_file_panel_focus, .key = "toggle_file_panel_focus", .title = "Toggle File Panel Focus" },
    .{ .action = .toggle_file_panel_mode, .key = "toggle_file_panel_mode", .title = "Toggle File Panel Mode" },
    .{ .action = .focus_file_tree, .key = "focus_file_tree", .title = "Focus File Tree" },
    .{ .action = .new_file, .key = "new_file", .title = "New File…" },
    .{ .action = .new_directory, .key = "new_directory", .title = "New Directory…" },
    .{ .action = .rename_file_tree_entry, .key = "rename_file_tree_entry", .title = "Rename File Tree Entry" },
    .{ .action = .delete_file_tree_entry, .key = "delete_file_tree_entry", .title = "Move File Tree Entry to Trash" },
    .{ .action = .focus_pane_left, .key = "focus_pane_left", .title = "Focus Pane Left" },
    .{ .action = .focus_pane_right, .key = "focus_pane_right", .title = "Focus Pane Right" },
    .{ .action = .focus_pane_up, .key = "focus_pane_up", .title = "Focus Pane Up" },
    .{ .action = .focus_pane_down, .key = "focus_pane_down", .title = "Focus Pane Down" },
    .{ .action = .next_pane, .key = "next_pane", .title = "Next Pane" },
    .{ .action = .previous_pane, .key = "previous_pane", .title = "Previous Pane" },
    // 활성 pane을 새 단독 워크스페이스로 분리(grip 드래그의 키보드/팔릿 버전). 기본 키바인딩 없음 — 팔릿이 발견 경로.
    .{ .action = .move_pane_to_new_workspace, .key = "move_pane_to_new_workspace", .title = "Move Pane to New Workspace" },
    // 사용자 지정 이름(rename) — 활성 대상을 인라인 편집기로 연다(custom_name). 기본 키바인딩이 없어 팔릿이 주
    // 발견 경로다(+ 더블클릭·우클릭). select_all과 같은 일반 액션.
    .{ .action = .rename_workspace, .key = "rename_workspace", .title = "Rename Workspace" },
    .{ .action = .rename_pane, .key = "rename_pane", .title = "Rename Pane" },
    .{ .action = .rename_term, .key = "rename_term", .title = "Rename Terminal" },
    // 사이드바 그룹(접이식 워크스페이스 묶음) — create_group만 기본 키 Cmd+Opt+G(catalogMenuItem이 chord 표시),
    // ungroup·rename_group은 기본 키 없이 팝업/우클릭이 발견 경로. 단일 출처: docs/sidebar-groups.md §7.
    .{ .action = .create_group, .key = "create_group", .title = "New Group" },
    .{ .action = .create_sibling_group, .key = "create_sibling_group", .title = "New Sibling Group" },
    .{ .action = .ungroup, .key = "ungroup", .title = "Ungroup" },
    .{ .action = .rename_group, .key = "rename_group", .title = "Rename Group" },
    // remove_from_group=이 워크스페이스 하나만 그룹에서 빼 최상위로(ungroup=그룹 통째 해제와 다름). 기본 키 없이 팝업/우클릭 발견.
    .{ .action = .remove_from_group, .key = "remove_from_group", .title = "Remove from Group" },
    // promote_to_top_level=이 워크스페이스를 **제자리에서** 최상위 섬으로 승격(§14.5·§14.7 promote-in-place, top_level만 세팅·pin
    // 불변). remove_from_group(이동+unpin)과 구별. 기본 키 없이 우클릭 "여기서 최상위로 분리"·팝업이 발견 경로.
    .{ .action = .promote_to_top_level, .key = "promote_to_top_level", .title = "Promote to Top Level" },
    .{ .action = .select_all, .key = "select_all", .title = "Select All" },
    // 화면+스크롤백 비우기(⌘K). select_all과 같은 일반 코어 액션 — 메뉴/팝업에 노출, 메뉴는 ⌘K chord를 표시한다.
    .{ .action = .clear_screen, .key = "clear_screen", .title = "Clear" },
    // 런타임 폰트 크기(⌘+/⌘-/⌘0). 모달 토글(toggle_find 등)과 달리 일반 액션이라 팝업/메뉴에 노출한다 —
    // 메뉴는 catalogMenuItem이 바인딩 chord(⌘+/⌘-/⌘0)를 그대로 표시한다(select_all과 같은 결).
    .{ .action = .increase_font_size, .key = "increase_font_size", .title = "Bigger" },
    .{ .action = .decrease_font_size, .key = "decrease_font_size", .title = "Smaller" },
    .{ .action = .reset_font_size, .key = "reset_font_size", .title = "Actual Size" },
    // 스크롤백 Find(⌘F)·다음/이전 매치(⌘G/⌘⇧G). **toggle_command_palette(팝업 자기 토글 — 재귀)와 달리**
    // Find는 별개 모달이라 팝업에 띄운다(선택 시 acceptPalette가 팝업을 닫고 Find를 연다). 메뉴 Find 서브메뉴는
    // keyEquivalent 없이(키바인딩 가림 방지) 별도지만, 팝업은 chord를 표시만 한다(가로채지 않음 — 안전).
    .{ .action = .toggle_find, .key = "toggle_find", .title = "Find" },
    .{ .action = .toggle_find_replace, .key = "toggle_find_replace", .title = "Find and Replace" },
    .{ .action = .toggle_find_match_case, .key = "toggle_find_match_case", .title = "Find: Match Case" },
    .{ .action = .toggle_find_whole_word, .key = "toggle_find_whole_word", .title = "Find: Whole Word" },
    .{ .action = .toggle_find_in_selection, .key = "toggle_find_in_selection", .title = "Find: In Selection" },
    .{ .action = .toggle_find_diff_side, .key = "toggle_find_diff_side", .title = "Find: Other Diff Column" },
    .{ .action = .delete_lines, .key = "delete_lines", .title = "Editor: Delete Line" },
    .{ .action = .duplicate_lines, .key = "duplicate_lines", .title = "Editor: Duplicate Line" },
    .{ .action = .move_lines_up, .key = "move_lines_up", .title = "Editor: Move Line Up" },
    .{ .action = .move_lines_down, .key = "move_lines_down", .title = "Editor: Move Line Down" },
    .{ .action = .indent_lines, .key = "indent_lines", .title = "Editor: Indent Lines" },
    .{ .action = .outdent_lines, .key = "outdent_lines", .title = "Editor: Outdent Lines" },
    .{ .action = .transform_to_uppercase, .key = "transform_to_uppercase", .title = "Editor: Transform to Uppercase" },
    .{ .action = .transform_to_lowercase, .key = "transform_to_lowercase", .title = "Editor: Transform to Lowercase" },
    .{ .action = .toggle_editor_wrap, .key = "toggle_editor_wrap", .title = "Editor: Toggle Word Wrap" },
    .{ .action = .copy_editor_selection, .key = "copy_editor_selection", .title = "Editor: Copy Selection" },
    .{ .action = .add_next_occurrence, .key = "add_next_occurrence", .title = "Editor: Add Next Occurrence" },
    .{ .action = .jump_to_bracket, .key = "jump_to_bracket", .title = "Editor: Go to Bracket" },
    .{ .action = .add_cursor_above, .key = "add_cursor_above", .title = "Editor: Add Cursor Above" },
    .{ .action = .add_cursor_below, .key = "add_cursor_below", .title = "Editor: Add Cursor Below" },
    .{ .action = .editor_undo, .key = "editor_undo", .title = "Editor: Undo" },
    .{ .action = .editor_redo, .key = "editor_redo", .title = "Editor: Redo" },
    .{ .action = .editor_save, .key = "editor_save", .title = "Editor: Save" },
    .{ .action = .fold_all, .key = "fold_all", .title = "Editor: Fold All" },
    .{ .action = .unfold_all, .key = "unfold_all", .title = "Editor: Unfold All" },
    .{ .action = .fold_level_1, .key = "fold_level_1", .title = "Editor: Fold Level 1" },
    .{ .action = .fold_level_2, .key = "fold_level_2", .title = "Editor: Fold Level 2" },
    .{ .action = .fold_level_3, .key = "fold_level_3", .title = "Editor: Fold Level 3" },
    .{ .action = .toggle_symbol_picker, .key = "toggle_symbol_picker", .title = "Editor: Go to Symbol in File" },
    .{ .action = .find_next, .key = "find_next", .title = "Find Next" },
    .{ .action = .find_previous, .key = "find_previous", .title = "Find Previous" },
    .{ .action = .{ .select_tab = 0 }, .key = "select_tab:0", .title = "Select Workspace 1" },
    .{ .action = .{ .select_tab = 1 }, .key = "select_tab:1", .title = "Select Workspace 2" },
    .{ .action = .{ .select_tab = 2 }, .key = "select_tab:2", .title = "Select Workspace 3" },
    .{ .action = .{ .select_tab = 3 }, .key = "select_tab:3", .title = "Select Workspace 4" },
    .{ .action = .{ .select_tab = 4 }, .key = "select_tab:4", .title = "Select Workspace 5" },
    .{ .action = .{ .select_tab = 5 }, .key = "select_tab:5", .title = "Select Workspace 6" },
    .{ .action = .{ .select_tab = 6 }, .key = "select_tab:6", .title = "Select Workspace 7" },
    .{ .action = .{ .select_tab = 7 }, .key = "select_tab:7", .title = "Select Workspace 8" },
    .{ .action = .{ .select_tab = 8 }, .key = "select_tab:8", .title = "Select Workspace 9" },
    // 활성 pane을 N번 워크스페이스에 합치기(merge — grip 드래그를 그 카드에 드롭하는 것의 키보드 버전). select_tab처럼
    // 0..8을 개별 엔트리로 편다. 기본 키바인딩 없음 — 팔릿이 발견 경로. tmux join-pane -t N 결.
    .{ .action = .{ .move_pane_to_workspace = 0 }, .key = "move_pane_to_workspace:0", .title = "Move Pane to Workspace 1" },
    .{ .action = .{ .move_pane_to_workspace = 1 }, .key = "move_pane_to_workspace:1", .title = "Move Pane to Workspace 2" },
    .{ .action = .{ .move_pane_to_workspace = 2 }, .key = "move_pane_to_workspace:2", .title = "Move Pane to Workspace 3" },
    .{ .action = .{ .move_pane_to_workspace = 3 }, .key = "move_pane_to_workspace:3", .title = "Move Pane to Workspace 4" },
    .{ .action = .{ .move_pane_to_workspace = 4 }, .key = "move_pane_to_workspace:4", .title = "Move Pane to Workspace 5" },
    .{ .action = .{ .move_pane_to_workspace = 5 }, .key = "move_pane_to_workspace:5", .title = "Move Pane to Workspace 6" },
    .{ .action = .{ .move_pane_to_workspace = 6 }, .key = "move_pane_to_workspace:6", .title = "Move Pane to Workspace 7" },
    .{ .action = .{ .move_pane_to_workspace = 7 }, .key = "move_pane_to_workspace:7", .title = "Move Pane to Workspace 8" },
    .{ .action = .{ .move_pane_to_workspace = 8 }, .key = "move_pane_to_workspace:8", .title = "Move Pane to Workspace 9" },
    // maru CLI를 PATH에 설치(VS Code "Install 'code' command" 결). 기본 키바인딩 없음 — 팝업이 발견 경로.
    .{ .action = .install_cli, .key = "install_cli", .title = "Install CLI" },
    // 모든 설정을 내장 기본값으로 초기화(통합 리셋). 기본 키바인딩 없음 — 팝업이 발견 경로.
    .{ .action = .reset_settings, .key = "reset_settings", .title = "Reset All Settings to Defaults" },
};

/// 전역(OS) 단축키 카탈로그 한 항목(정적). in-app `Entry`와 평행하되 action이 GlobalAction이다. action_key는
/// parseGlobalAction이 받는 문자열과 일치(round-trip 테스트가 고정), title은 한글 UI 표시 문자열.
pub const GlobalEntry = struct {
    action: GlobalAction,
    key: [:0]const u8,
    /// 표시 제목이 아니라 **키**를 든다 — 이 목록이 컨테이너 레벨 배열이라 comptime 이고, 런타임
    /// 조회(`i18n.t`)는 거기서 쓸 수 없다. 해석은 소비처가 `title()` 로 한다(세팅 행 라벨·검색 두 곳).
    title_key: maru.i18n.Key,

    /// 현재 언어로 푼 표시 제목.
    pub fn title(self: GlobalEntry) []const u8 {
        return maru.i18n.t(self.title_key);
    }
};

/// 세팅 `.global_hotkey` 섹션에 노출할 전역 액션 목록(3개). in-app `entries`와 달리 빌트인 기본 chord가 없다 —
/// 사용자가 `keybind = global:<chord> = <action>`로 명시하지 않으면 미지정이다(chordForGlobalAction이 null).
pub const global_entries = [_]GlobalEntry{
    .{ .action = .toggle_window, .key = "toggle_window", .title_key = .cmd_toggle_window },
    .{ .action = .show_window, .key = "show_window", .title_key = .cmd_show_window },
    .{ .action = .toggle_quick_terminal, .key = "toggle_quick_terminal", .title_key = .cmd_toggle_quick },
};

/// 한 전역 액션에 현재 묶인 chord를 찾는다(표시용). in-app `chordForAction`과 달리 빌트인 기본 바인딩이 없으므로
/// 사용자 `global_bindings`만 스캔한다(없으면 null = "(미지정)"). 첫 매칭을 반환(파싱이 chord별 한 줄로 dedup).
pub fn chordForGlobalAction(bindings: []const GlobalBinding, action: GlobalAction) ?KeyChord {
    for (bindings) |binding| {
        if (binding.action == action) return binding.chord;
    }
    return null;
}

/// chord 표시 문자열의 최대 바이트(modifiers 4개 × 3바이트 + 키 심볼 + 여유). 32면 충분하다.
pub const max_chord_display_len = 32;

fn appendStr(buf: []u8, len: *usize, s: []const u8) void {
    if (len.* + s.len > buf.len) return; // 넘치면 잘라낸다(여기 오면 안 됨 — max_chord_display_len 보장).
    @memcpy(buf[len.*..][0..s.len], s);
    len.* += s.len;
}

/// 한 액션에 현재 묶인 chord를 찾는다(표시용). resolve와 같은 우선순위: 사용자 app_bindings 먼저, 없으면
/// 빌트인 default_app_bindings(단, 사용자가 unbind한 chord는 건너뜀 — resolve의 unbind 처리와 일치).
/// 안 묶였으면 null. select_tab 같은 payload 액션은 std.meta.eql로 payload까지 비교한다.
pub fn chordForAction(resolver: KeyBindingResolver, action: Action) ?KeyChord {
    for (resolver.app_bindings) |binding| {
        if (std.meta.eql(binding.action, action)) return binding.chord;
    }
    // **편집기 컨텍스트 기본키도 표시한다**(§편집기 Term 컨텍스트 「메뉴 keyEquivalent 층」).
    // 이것이 없으면 `⌘D`·`⌥Z`·`⌥↑↓` 가 배선돼 있는데도 팔레트가 **「단축키 없음」**이라고 말해
    // 발견조차 안 된다(실측). 전역 표보다 **먼저** 보는 것은 `resolveEditor` 의 순서와 같다.
    //
    // **메뉴에 chord 가 새로 달리지는 않는다** — 이 표의 액션들은 팔레트 카탈로그에만 있고
    // `catalogMenuItem` 이 거는 스무 항목에 하나도 없다(실측). 즉 바뀌는 것은 팔레트 표시뿐이다.
    for (editor_context_bindings) |binding| {
        if (std.meta.eql(binding.action, action)) return binding.chord;
    }
    for (default_app_bindings) |binding| {
        if (!std.meta.eql(binding.action, action)) continue;
        var unbound = false;
        for (resolver.unbinds) |u| {
            if (u.eql(binding.chord)) {
                unbound = true;
                break;
            }
        }
        if (!unbound) return binding.chord;
    }
    return null;
}

/// 비-modifier 키 1개의 macOS 표준 표시 글리프를 buf에 쓰고 그 slice를 돌려준다 — formatChord 키 글리프의 단일
/// 출처(글자는 대문자 fold, 특수키 표준 기호 ↩⎋⇥⌫⌦↖↘⇞⇟ ←→↑↓, function은 F{n}). buf는 8바이트면 충분.
fn keyGlyph(key: KeyName, buf: []u8) []const u8 {
    var len: usize = 0;
    switch (key) {
        .char => |c| {
            // 표시용 대문자 fold(영문). 그 외 코드포인트는 그대로.
            const cp: u21 = if (c >= 'a' and c <= 'z') c - 32 else c;
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &utf8) catch 0;
            appendStr(buf, &len, utf8[0..n]);
        },
        .enter => appendStr(buf, &len, "↩"),
        .escape => appendStr(buf, &len, "⎋"),
        .tab => appendStr(buf, &len, "⇥"),
        .backspace => appendStr(buf, &len, "⌫"),
        .delete => appendStr(buf, &len, "⌦"),
        .insert => appendStr(buf, &len, "Ins"),
        .home => appendStr(buf, &len, "↖"),
        .end => appendStr(buf, &len, "↘"),
        .page_up => appendStr(buf, &len, "⇞"),
        .page_down => appendStr(buf, &len, "⇟"),
        .arrow_up => appendStr(buf, &len, "↑"),
        .arrow_down => appendStr(buf, &len, "↓"),
        .arrow_left => appendStr(buf, &len, "←"),
        .arrow_right => appendStr(buf, &len, "→"),
        .function => |n| {
            appendStr(buf, &len, "F");
            var numbuf: [3]u8 = undefined;
            appendStr(buf, &len, std.fmt.bufPrint(&numbuf, "{d}", .{n}) catch "");
        },
    }
    return buf[0..len];
}

/// chord를 macOS 관례 표시 문자열로 만든다(modifier 순서 ⌃⌥⇧⌘ 뒤에 키 심볼). 메뉴 단축키 표시·팝업
/// 보조 텍스트용. 버퍼에 쓰고 그 slice를 돌려준다(호출자가 소유 문자열로 복사). 안 묶인 액션은 호출 전에 걸러야 한다.
pub fn formatChord(chord: KeyChord, buf: []u8) []const u8 {
    var len: usize = 0;
    if (chord.modifiers.control) appendStr(buf, &len, "⌃");
    if (chord.modifiers.option) appendStr(buf, &len, "⌥");
    if (chord.modifiers.shift) appendStr(buf, &len, "⇧");
    if (chord.modifiers.command) appendStr(buf, &len, "⌘");
    var kbuf: [8]u8 = undefined;
    appendStr(buf, &len, keyGlyph(chord.key, &kbuf));
    return buf[0..len];
}

/// modifier 비트마스크(NSMenuItem.keyEquivalentModifierMask로 Swift가 매핑). 안정 인코딩 — .h에 같은 값 문서화.
pub const mod_shift: u32 = 1;
pub const mod_control: u32 = 2;
pub const mod_option: u32 = 4;
pub const mod_command: u32 = 8;

/// chord의 modifier를 비트마스크로(위 상수). Swift가 NSEvent.ModifierFlags로 옮긴다.
pub fn modifierMask(chord: KeyChord) u32 {
    var m: u32 = 0;
    if (chord.modifiers.shift) m |= mod_shift;
    if (chord.modifiers.control) m |= mod_control;
    if (chord.modifiers.option) m |= mod_option;
    if (chord.modifiers.command) m |= mod_command;
    return m;
}

/// NSMenuItem.keyEquivalent 문자열을 buf에 쓴다(그 slice 반환). 글자 키는 **소문자**(AppKit 관례 — shift는
/// keyEquivalentModifierMask로 표현하지 keyEquivalent 글자를 바꾸지 않는다), 화살표·기능키 등 특수키는 AppKit
/// function-key unichar(0xF700+, NSUpArrowFunctionKey 등)로 emit한다. 인코딩 실패/버퍼 부족이면 빈 slice.
/// (platform/macos 모듈이라 AppKit 전용 unichar 상수를 Zig에 두는 게 경계상 허용 — keyEquivalent는 AppKit 개념.)
pub fn keyEquivalent(chord: KeyChord, buf: []u8) []const u8 {
    const cp: u21 = switch (chord.key) {
        .char => |c| if (c >= 'A' and c <= 'Z') c + 32 else c, // 소문자 fold
        .arrow_up => 0xF700, // NSUpArrowFunctionKey
        .arrow_down => 0xF701,
        .arrow_left => 0xF702,
        .arrow_right => 0xF703,
        .enter => 0x0D,
        .tab => 0x09,
        .escape => 0x1B,
        .backspace => 0x08,
        .delete => 0xF728, // NSDeleteFunctionKey(forward delete)
        .insert => 0xF727, // NSInsertFunctionKey
        .home => 0xF729,
        .end => 0xF72B,
        .page_up => 0xF72C,
        .page_down => 0xF72D,
        .function => |n| 0xF704 + @as(u21, n) -| 1, // NSF1FunctionKey=0xF704
    };
    var utf8: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &utf8) catch return "";
    if (len > buf.len) return "";
    @memcpy(buf[0..len], utf8[0..len]);
    return buf[0..len];
}

test "catalog action_key가 parseAction으로 round-trip된다(양방향 일치)" {
    for (entries) |entry| {
        const parsed = maru.config.parseAction(entry.key) orelse {
            std.debug.print("parseAction failed for key: {s}\n", .{entry.key});
            return error.UnparsableActionKey;
        };
        try std.testing.expect(std.meta.eql(parsed, entry.action));
    }
}

test "formatChord: modifier 순서·키 심볼" {
    var buf: [max_chord_display_len]u8 = undefined;
    try std.testing.expectEqualStrings("⌘T", formatChord(.{ .modifiers = .{ .command = true }, .key = .{ .char = 'T' } }, &buf));
    try std.testing.expectEqualStrings("⇧⌘T", formatChord(.{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = 't' } }, &buf)); // 소문자→대문자 fold
    try std.testing.expectEqualStrings("⌥⌘←", formatChord(.{ .modifiers = .{ .command = true, .option = true }, .key = .arrow_left }, &buf));
    try std.testing.expectEqualStrings("⌘1", formatChord(.{ .modifiers = .{ .command = true }, .key = .{ .char = '1' } }, &buf));
    try std.testing.expectEqualStrings("⌘]", formatChord(.{ .modifiers = .{ .command = true }, .key = .{ .char = ']' } }, &buf));
    try std.testing.expectEqualStrings("⌃⌥⇧⌘F5", formatChord(.{ .modifiers = .{ .control = true, .option = true, .shift = true, .command = true }, .key = .{ .function = 5 } }, &buf));
}

test "chordForAction: 빌트인·사용자·unbind" {
    // 빌트인: new_term은 Cmd+T(default_app_bindings).
    const builtin_resolver: KeyBindingResolver = .{};
    const new_term_chord = chordForAction(builtin_resolver, .new_term).?;
    try std.testing.expect(new_term_chord.modifiers.command and !new_term_chord.modifiers.shift);
    try std.testing.expect(new_term_chord.key.eql(.{ .char = 'T' }));
    const open_file_chord = chordForAction(builtin_resolver, .open_file_panel).?;
    try std.testing.expect(open_file_chord.modifiers.command and !open_file_chord.modifiers.shift);
    try std.testing.expect(open_file_chord.key.eql(.{ .char = 'O' }));

    // 기본 바인딩 없는 액션(close_tab)은 null.
    try std.testing.expect(chordForAction(builtin_resolver, .close_tab) == null);

    // 사용자 바인딩이 우선: close_tab을 Cmd+K로.
    const user_chord = try KeyChord.parse("Cmd+K");
    const user_resolver: KeyBindingResolver = .{ .app_bindings = &.{.{ .chord = user_chord, .action = .close_tab }} };
    try std.testing.expect(chordForAction(user_resolver, .close_tab).?.key.eql(.{ .char = 'K' }));

    // 빌트인 chord를 unbind하면 표시도 사라진다(null).
    const unbind_resolver: KeyBindingResolver = .{ .unbinds = &.{try KeyChord.parse("Cmd+T")} };
    try std.testing.expect(chordForAction(unbind_resolver, .new_term) == null);
}

test "keyEquivalent/modifierMask: NSMenuItem용 소문자 글자·mask·화살표 unichar" {
    var buf: [8]u8 = undefined;
    // Cmd+T → "t" + command.
    const t = KeyChord{ .modifiers = .{ .command = true }, .key = .{ .char = 'T' } };
    try std.testing.expectEqualStrings("t", keyEquivalent(t, &buf));
    try std.testing.expectEqual(mod_command, modifierMask(t));
    // Cmd+Shift+T → "t"(소문자 유지) + command|shift.
    const st = KeyChord{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = 'T' } };
    try std.testing.expectEqualStrings("t", keyEquivalent(st, &buf));
    try std.testing.expectEqual(mod_command | mod_shift, modifierMask(st));
    // Cmd+1 → "1" + command.
    const one = KeyChord{ .modifiers = .{ .command = true }, .key = .{ .char = '1' } };
    try std.testing.expectEqualStrings("1", keyEquivalent(one, &buf));
    // Cmd+Opt+Left → 화살표 unichar 0xF702 + command|option.
    const left = KeyChord{ .modifiers = .{ .command = true, .option = true }, .key = .arrow_left };
    var expect: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(0xF702, &expect);
    try std.testing.expectEqualStrings(expect[0..n], keyEquivalent(left, &buf));
    try std.testing.expectEqual(mod_command | mod_option, modifierMask(left));
}

test "global catalog action_key가 parseGlobalAction으로 round-trip된다(양방향 일치)" {
    for (global_entries) |entry| {
        const parsed = maru.config.parseGlobalAction(entry.key) orelse {
            std.debug.print("parseGlobalAction failed for key: {s}\n", .{entry.key});
            return error.UnparsableGlobalActionKey;
        };
        try std.testing.expectEqual(parsed, entry.action);
    }
    // 카탈로그가 GlobalAction enum 전체를 덮는지(빠진 액션이 없게).
    try std.testing.expectEqual(@typeInfo(GlobalAction).@"enum".fields.len, global_entries.len);
}

test "chordForGlobalAction: 사용자 global_bindings만 스캔(빌트인 기본 없음)" {
    // 빈 목록 → 모두 null(in-app과 달리 빌트인 기본 chord가 없다).
    try std.testing.expect(chordForGlobalAction(&.{}, .toggle_window) == null);

    const bindings = [_]GlobalBinding{
        .{ .chord = try KeyChord.parse("Cmd+Alt+Space"), .action = .toggle_window },
        .{ .chord = try KeyChord.parse("Cmd+Alt+T"), .action = .show_window },
    };
    try std.testing.expect(chordForGlobalAction(&bindings, .toggle_window).?.eql(try KeyChord.parse("Cmd+Alt+Space")));
    try std.testing.expect(chordForGlobalAction(&bindings, .show_window).?.eql(try KeyChord.parse("Cmd+Alt+T")));
    // 안 묶인 액션은 null.
    try std.testing.expect(chordForGlobalAction(&bindings, .toggle_quick_terminal) == null);
}

test "KB_SYM3 팔레트가 편집기 액션의 chord 를 표시한다 — 배선하면 화면이 따라온다" {
    // **팔레트 행의 chord 는 손으로 적는 것이 아니라 `default_app_bindings` 역스캔 결과다.**
    // 그래서 표에 chord 를 더하면 화면이 저절로 따라오는데, 그 「저절로」가 지금까지
    // 이 액션들에 대해 **한 번도 검증되지 않았다**(2026-08-31). 배선을 지우고도 팔레트가
    // 전과 같아 보이면 아무도 못 알아챈다.
    var buf: [max_chord_display_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};

    // **`⇧⌘O` 이지 `⌘⇧O` 가 아니다** — `formatChord` 는 애플 표준 순서 `⌃⌥⇧⌘` 를 따른다.
    // 처음에 `⌘⇧O` 로 적었다가 이 판정자에 잡혔다(2026-09-01). 문서·PR 에도 같은 오기가 있었다.
    try std.testing.expectEqualStrings("⇧⌘O", formatChord(chordForAction(resolver, .toggle_symbol_picker).?, &buf));
    try std.testing.expectEqualStrings("⌘Z", formatChord(chordForAction(resolver, .editor_undo).?, &buf));
    try std.testing.expectEqualStrings("⌘S", formatChord(chordForAction(resolver, .editor_save).?, &buf));
    // **찾기 규칙 토글 넷이 같은 가족이다** — 수식자가 갈리면 사용자가 셋을 외운 손버릇이
    // 넷째에서 안 먹는다(§5.1 「어느 열을 보는지 …」가 `⌥⌘D` 를 그 가족으로 정했다).
    try std.testing.expectEqualStrings("⌥⌘C", formatChord(chordForAction(resolver, .toggle_find_match_case).?, &buf));
    try std.testing.expectEqualStrings("⌥⌘W", formatChord(chordForAction(resolver, .toggle_find_whole_word).?, &buf));
    try std.testing.expectEqualStrings("⌥⌘L", formatChord(chordForAction(resolver, .toggle_find_in_selection).?, &buf));
    try std.testing.expectEqualStrings("⌥⌘D", formatChord(chordForAction(resolver, .toggle_find_diff_side).?, &buf));

    // **chord 가 없는 편집기 액션은 null 이어야 한다** — 없는 것을 있다고 그리면 사용자가
    // 안 되는 키를 누른다. 이 여섯이 왜 비어 있는지는 docs/configuration-input.md 가 소유한다.
    inline for (.{ Action.fold_all, Action.fold_level_1, Action.fold_level_2, Action.fold_level_3 }) |a| {
        try std.testing.expect(chordForAction(resolver, a) == null);
    }

    // **팔레트에 그 항목이 실제로 있다** — chord 만 맞고 행이 없으면 닿을 길이 여전히 없다.
    var found = false;
    for (entries) |entry| {
        if (std.meta.eql(entry.action, Action.toggle_symbol_picker)) found = true;
    }
    try std.testing.expect(found);

    // 열 넘기기도 같다 — 빌트인 chord 를 사용자가 unbind 하면 팔레트가 **유일한 도달 경로**다.
    var found_side = false;
    for (entries) |entry| {
        if (std.meta.eql(entry.action, Action.toggle_find_diff_side)) found_side = true;
    }
    try std.testing.expect(found_side);
}

test "select_tab은 0..8로 펼쳐지고 ⌘1..9로 표시된다" {
    var buf: [max_chord_display_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};
    // select_tab:0 → Cmd+1.
    try std.testing.expectEqualStrings("⌘1", formatChord(chordForAction(resolver, .{ .select_tab = 0 }).?, &buf));
    // select_tab:8 → Cmd+9.
    try std.testing.expectEqualStrings("⌘9", formatChord(chordForAction(resolver, .{ .select_tab = 8 }).?, &buf));
}
