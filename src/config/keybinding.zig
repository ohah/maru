const std = @import("std");
const action_mod = @import("action.zig");
const terminal = @import("../terminal.zig");

// This file intentionally stays pure Zig and does not know about TOML, AppKit,
// or global-hotkey registration. Keeping the resolver here lets us test the
// user-facing keybinding rules before platform event code starts calling them.

pub const KeyBindingError = error{
    EmptyChord,
    EmptyChordPart,
    DuplicateModifier,
    MissingKey,
    MultipleKeys,
    UnknownChordPart,
    InvalidFunctionKey,
    DuplicateAppBinding,
    DuplicateTerminalBinding,
    AppTerminalBindingConflict,
    InvalidControlKey,
};

pub const KeyName = union(enum) {
    char: u21,
    enter,
    escape,
    tab,
    backspace,
    delete,
    insert,
    home,
    end,
    page_up,
    page_down,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    function: u8,

    pub fn eql(self: KeyName, other: KeyName) bool {
        return switch (self) {
            .char => |value| other == .char and other.char == value,
            .enter => other == .enter,
            .escape => other == .escape,
            .tab => other == .tab,
            .backspace => other == .backspace,
            .delete => other == .delete,
            .insert => other == .insert,
            .home => other == .home,
            .end => other == .end,
            .page_up => other == .page_up,
            .page_down => other == .page_down,
            .arrow_up => other == .arrow_up,
            .arrow_down => other == .arrow_down,
            .arrow_left => other == .arrow_left,
            .arrow_right => other == .arrow_right,
            .function => |value| other == .function and other.function == value,
        };
    }
};

pub const KeyChord = struct {
    modifiers: terminal.ModifierSet = .{},
    key: KeyName,

    pub fn parse(raw: []const u8) KeyBindingError!KeyChord {
        // The parser accepts the human config spelling first. Platform-specific
        // key events are normalized later with fromKeyEvent so config files and
        // AppKit do not need to share string parsing code.
        if (raw.len == 0) return error.EmptyChord;

        var modifiers: terminal.ModifierSet = .{};
        var key: ?KeyName = null;
        var parts = std.mem.splitScalar(u8, raw, '+');
        while (parts.next()) |part| {
            if (part.len == 0) return error.EmptyChordPart;
            if (parseModifier(part)) |modifier| {
                try setModifier(&modifiers, modifier);
                continue;
            }

            const parsed_key = try parseKey(part);
            if (key != null) return error.MultipleKeys;
            key = parsed_key;
        }

        return .{
            .modifiers = modifiers,
            .key = key orelse return error.MissingKey,
        };
    }

    pub fn fromKeyEvent(event: terminal.KeyEvent) ?KeyChord {
        return .{
            .modifiers = event.modifiers,
            .key = keyNameFromTerminalKey(event.key) orelse return null,
        };
    }

    pub fn eql(self: KeyChord, other: KeyChord) bool {
        return std.meta.eql(self.modifiers, other.modifiers) and self.key.eql(other.key);
    }

    /// chord를 **config 표기**(parse가 받아들이는 정확한 ASCII 철자)로 직렬화한다 — keybind recorder의 write-back
    /// (`keybind = <여기> = <action>`)용. parse와 round-trip 가능(`parse(toConfigString(c)) == c`, 테스트 보장).
    /// modifier는 Cmd+Ctrl+Alt+Shift 순(parse는 순서 무관), 키는 parseKey의 짝(Esc/Tab/Up/F1/Space/Plus/글자). 표시용
    /// `command_catalog.formatChord`(⌘⇧ 기호)와 달리 파일에 쓸 수 있는 표기다. buf는 max_chord_display_len(32)면 충분.
    pub fn toConfigString(self: KeyChord, buf: []u8) []const u8 {
        var w: usize = 0;
        const put = struct {
            fn s(b: []u8, i: *usize, text: []const u8) void {
                if (i.* >= b.len) return;
                const n = @min(text.len, b.len - i.*);
                @memcpy(b[i.*..][0..n], text[0..n]);
                i.* += n;
            }
        }.s;
        if (self.modifiers.command) put(buf, &w, "Cmd+");
        if (self.modifiers.control) put(buf, &w, "Ctrl+");
        if (self.modifiers.option) put(buf, &w, "Alt+");
        if (self.modifiers.shift) put(buf, &w, "Shift+");
        switch (self.key) {
            .char => |c| {
                if (c == ' ') {
                    put(buf, &w, "Space");
                } else if (c == '+') {
                    put(buf, &w, "Plus");
                } else {
                    var tmp: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(c, &tmp) catch 0;
                    put(buf, &w, tmp[0..n]);
                }
            },
            .enter => put(buf, &w, "Enter"),
            .escape => put(buf, &w, "Esc"),
            .tab => put(buf, &w, "Tab"),
            .backspace => put(buf, &w, "Backspace"),
            .delete => put(buf, &w, "Delete"),
            .insert => put(buf, &w, "Insert"),
            .home => put(buf, &w, "Home"),
            .end => put(buf, &w, "End"),
            .page_up => put(buf, &w, "PageUp"),
            .page_down => put(buf, &w, "PageDown"),
            .arrow_up => put(buf, &w, "Up"),
            .arrow_down => put(buf, &w, "Down"),
            .arrow_left => put(buf, &w, "Left"),
            .arrow_right => put(buf, &w, "Right"),
            .function => |n| {
                var tmp: [8]u8 = undefined;
                put(buf, &w, std.fmt.bufPrint(&tmp, "F{d}", .{n}) catch "F1");
            },
        }
        return buf[0..w];
    }
};

pub const TerminalInputMacro = union(enum) {
    send_control: u21,
    send_text: []const u8,
    send_escape_sequence: []const u8,

    pub fn bytes(self: TerminalInputMacro, buffer: *[terminal.input.encoded_key_buffer_len]u8) KeyBindingError![]const u8 {
        // Terminal macros produce bytes, not AppAction values. That separation
        // prevents a shortcut like Cmd+B from accidentally doing both "new tab"
        // and "send Ctrl+B to the shell".
        return switch (self) {
            .send_control => |codepoint| blk: {
                buffer[0] = terminal.input.controlByte(codepoint) catch return error.InvalidControlKey;
                break :blk buffer[0..1];
            },
            .send_text => |text| text,
            .send_escape_sequence => |sequence| sequence,
        };
    }
};

pub const AppBinding = struct {
    chord: KeyChord,
    action: action_mod.Action,
};

/// 전역(OS) 단축키 바인딩 — chord를 OS 레벨에 등록하고(`global:` 접두사), 누르면 GlobalAction을 수행한다.
/// in-app `KeyBindingResolver`를 안 거친다(OS 핫키 콜백이 dispatch). app 바인딩과 별도 네임스페이스다.
pub const GlobalBinding = struct {
    chord: KeyChord,
    action: action_mod.GlobalAction,
};

pub const TerminalBinding = struct {
    chord: KeyChord,
    input: TerminalInputMacro,
};

pub const ResolvedKey = union(enum) {
    app_action: action_mod.Action,
    terminal_input: []const u8,
    ignored,
};

/// WKWebView가 first responder일 때 Swift가 그대로 소비하는 typed route. raw ordinal은 app-host ABI 계약이다.
pub const WebKeyRoute = enum(u32) {
    pass_through = 0,
    app_action = 1,
    consume_unbound = 2,
    web_editor = 3,
};

const WebResolution = union(enum) {
    pass_through,
    app_action: action_mod.Action,
    consume_unbound,
    web_editor,

    fn route(self: WebResolution) WebKeyRoute {
        return switch (self) {
            .pass_through => .pass_through,
            .app_action => .app_action,
            .consume_unbound => .consume_unbound,
            .web_editor => .web_editor,
        };
    }
};

/// 빌트인 기본 terminal 바인딩 — macOS 줄 편집 관례를 셸 시퀀스로 매핑한다(Ghostty 기본 keybind와
/// 동작 일치). 흩어진 특수 케이스(Swift 하드코딩, ad-hoc 분기) 대신 한 테이블(데이터)로 둔다.
/// resolve 순서: 사용자 config 바인딩(override 가능) → 이 빌트인 → "안 묶인 Cmd → ignored" fallthrough.
/// 빌트인을 Cmd-무시보다 먼저 봐야 Cmd 편집 조합이 전부 ignored로 새지 않는다. KeyChord.eql이
/// modifier를 정확히 비교하므로 Cmd+Backspace만 매칭한다(Cmd+Shift+Backspace 등은 안 됨).
/// Option+Backspace(단어 삭제 `\x1b\x7f`)는 encodeKey의 meta-ESC가 이미 처리해 여기 없다.
pub const default_terminal_bindings = [_]TerminalBinding{
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .backspace }, .input = .{ .send_text = "\x15" } }, // Cmd+Backspace: 줄 시작까지 삭제(Ctrl+U)
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .arrow_left }, .input = .{ .send_text = "\x01" } }, // Cmd+Left: 줄 시작(Ctrl+A)
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .arrow_right }, .input = .{ .send_text = "\x05" } }, // Cmd+Right: 줄 끝(Ctrl+E)
    .{ .chord = .{ .modifiers = .{ .option = true }, .key = .arrow_left }, .input = .{ .send_escape_sequence = "\x1bb" } }, // Option+Left: 단어 왼쪽(Meta-b)
    .{ .chord = .{ .modifiers = .{ .option = true }, .key = .arrow_right }, .input = .{ .send_escape_sequence = "\x1bf" } }, // Option+Right: 단어 오른쪽(Meta-f)
};

/// 빌트인 기본 app(탭/창) 바인딩 — Mac 관례를 app action으로 매핑한다(Terminal.app/iTerm2/브라우저
/// 공통: Cmd+T=새 탭). 'T'는 글자라 normalizeEventChar가 대문자로 fold해 Shift 유무와 무관하게
/// 매칭된다(layout 안전). resolve 순서: 사용자 바인딩 → 빌트인 terminal → '''이 빌트인 app''' →
/// Cmd-무시 fallthrough. Cmd+Shift+]/[(다음/이전 탭)은 Shift+문자가 layout마다 달라(`]`→`}`) 별도
/// 처리가 필요해 탭바 UI(클릭 전환)와 함께 후속에서 추가한다.
pub const default_app_bindings = [_]AppBinding{
    // Cmd+Ctrl+D: 편집기에서 다음 일치에 커서 추가(VSCode ⌘D). **임시 chord다** — §9.1이 확정한
    // 것은 `⌘D`이지만 편집기 포커스 컨텍스트가 서야 터미널의 pane split과 갈라 쓸 수 있다.
    // 자세한 근거는 `action.zig`의 `add_next_occurrence`가 든다.
    .{ .chord = .{ .modifiers = .{ .command = true, .control = true }, .key = .{ .char = 'D' } }, .action = .add_next_occurrence },
    // 편집기 편집 일습(§3.3·§3.5). **셋 다 터미널이 쓰지 않는 chord다** — 여기까지 안 묶인 Cmd 조합은
    // 아래 fallthrough 에서 `.ignored` 가 되므로, 배선 전에는 **누르면 아무 일도 안 일어나는 상태**였다.
    // 그 사이 undo 스택은 계약대로 다 서 있었고(`93bd67f7`) 부르는 길만 커맨드 팔레트뿐이었다 —
    // 사용자에게는 「undo 가 없는 것」과 거의 같았다(docs/plans/native-editor.md "키 chord").
    //
    // **컨텍스트 게이트는 액션 쪽이 이미 갖고 있다**: `stepHistory`·`saveDocument` 가 `term.kind != .editor`
    // 를 먼저 보고 거절하므로, 터미널 Term 에서 눌러도 전과 같이 아무 일도 안 일어난다. 그래서 이 셋은
    // ⌘C 처럼 「컨텍스트가 서야 양보할 수 있는」 부류가 아니다(§9.1 이 ⌘C 에만 그 조건을 건 이유).
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'Z' } }, .action = .editor_undo }, // Cmd+Z
    .{ .chord = .{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = 'Z' } }, .action = .editor_redo }, // Cmd+Shift+Z
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'S' } }, .action = .editor_save }, // Cmd+S
    // 탭 풀 모델: ⌘T=활성 pane에 새 Term(탭), ⌘⇧T=새 워크스페이스(사이드바 탭). normalizeEventChar가 't'를
    // 'T'로 fold하므로 char는 같고 shift 유무(modifier 정확 비교)로 갈린다. 워크스페이스 생성은 사이드바 "+"가
    // 생기기 전 ⌘⇧T를 임시로 둔다(단일 출처: docs/tabs-splits-layout.md).
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'T' } }, .action = .new_term }, // Cmd+T: 활성 pane에 새 Term
    .{ .chord = .{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = 'T' } }, .action = .new_tab }, // Cmd+Shift+T: 새 워크스페이스
    .{ .chord = .{ .modifiers = .{ .command = true, .option = true }, .key = .{ .char = 'T' } }, .action = .new_web_tab }, // Cmd+Option+T: 활성 pane에 새 브라우저 Term(⌘T=new_term의 web 버전, ⌥로 구분)
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'O' } }, .action = .open_file_panel }, // Cmd+O: Markdown/HTML을 현재 창 도크에 열기(macOS Open 관례)
    .{ .chord = .{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = 'E' } }, .action = .toggle_file_panel_focus }, // Cmd+Shift+E: workspace pane <-> file dock focus
    // Cmd+E: 파일 패널 읽기 <-> 소스. 라이브 프리뷰 폐기로 markdown이 읽기로 시작하게 되면서, 이 chord가
    // 없으면 편집에 들어가는 유일한 길이 헤더 mode 선택기 마우스 클릭뿐이다.
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'E' } }, .action = .toggle_file_panel_mode },
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'W' } }, .action = .close_focused }, // Cmd+W: 파일 도크 focus면 파일 탭, 아니면 Term cascade
    // split(pane) 순환: ⌘]=다음, ⌘[=이전(활성 워크스페이스 안에서 wrap, 분할 없으면 무동작). shift 없는 대괄호라
    // char는 ]/[ 그대로다(브레이스 }/{ 는 shift일 때만). 워크스페이스 ⌘⇧]/⌘⇧[ · Term ⌘⌥]/⌘⌥[ 와 modifier로
    // 갈린다(사용자 요청 배치 — ⌘[]를 split 이동에 둔다).
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = ']' } }, .action = .next_pane },
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = '[' } }, .action = .previous_pane },
    // Cmd+Shift+]/[ : 다음/이전 워크스페이스(wrap). Swift는 charactersIgnoringModifiers로 char를 보내는데, Cmd
    // 조합에서 Shift가 적용돼 닫는/여는 중괄호(}/{)로 올 수도, 대괄호(]/[)가 그대로 올 수도 있다(OS/레이아웃
    // 차이). 두 변형을 모두 묶는다. 모디파이어는 정확 비교라 shift=true가 필수다.
    .{ .chord = .{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = ']' } }, .action = .next_tab },
    .{ .chord = .{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = '}' } }, .action = .next_tab },
    .{ .chord = .{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = '[' } }, .action = .previous_tab },
    .{ .chord = .{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = '{' } }, .action = .previous_tab },
    // Cmd+1~9: N번째 워크스페이스(사이드바 탭)로 바로 전환(select_tab은 0-based라 N-1). 범위 밖이면 switchTab이
    // no-op. 브라우저/터미널 공통 관습(베이스: Safari/Terminal.app/iTerm2의 Cmd+숫자 탭 전환). 숫자 키는
    // normalizeEventChar가 안 fold하고 Swift가 char로 그대로 줘 그대로 매칭된다. 모디파이어 정확 비교.
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = '1' } }, .action = .{ .select_tab = 0 } },
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = '2' } }, .action = .{ .select_tab = 1 } },
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = '3' } }, .action = .{ .select_tab = 2 } },
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = '4' } }, .action = .{ .select_tab = 3 } },
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = '5' } }, .action = .{ .select_tab = 4 } },
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = '6' } }, .action = .{ .select_tab = 5 } },
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = '7' } }, .action = .{ .select_tab = 6 } },
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = '8' } }, .action = .{ .select_tab = 7 } },
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = '9' } }, .action = .{ .select_tab = 8 } },
    // Cmd+D: 활성 panel 좌우 분할, Cmd+Shift+D: 상하 분할. normalizeEventChar가 'd'를 'D'로 fold하므로
    // 두 칸의 char는 같고(shift만 다름) 모디파이어 정확 비교로 갈린다. 방향 규칙은 docs/tabs-splits-layout.md.
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'D' } }, .action = .split_horizontal },
    .{ .chord = .{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = 'D' } }, .action = .split_vertical },
    // Cmd+Option+화살표: split 탭에서 방향으로 pane 포커스 이동(iTerm2식). 모디파이어 정확 비교라
    // Option+화살표(단어 이동)·Cmd+화살표(줄 처음/끝)와 안 겹친다(둘 다 command+option은 아님).
    .{ .chord = .{ .modifiers = .{ .command = true, .option = true }, .key = .arrow_left }, .action = .focus_pane_left },
    .{ .chord = .{ .modifiers = .{ .command = true, .option = true }, .key = .arrow_right }, .action = .focus_pane_right },
    .{ .chord = .{ .modifiers = .{ .command = true, .option = true }, .key = .arrow_up }, .action = .focus_pane_up },
    .{ .chord = .{ .modifiers = .{ .command = true, .option = true }, .key = .arrow_down }, .action = .focus_pane_down },
    // Cmd+Option+]/[ : Term(가로 탭) 순환 — ⌘[]를 split 이동에 양보하고 Term을 여기로 옮겼다(사용자 요청). shift
    // 없는 대괄호 char(]/[) + command·option 정확 비교. (focus_pane 방향 이동은 위 화살표, 대괄호는 Term 순환.)
    .{ .chord = .{ .modifiers = .{ .command = true, .option = true }, .key = .{ .char = ']' } }, .action = .next_term },
    .{ .chord = .{ .modifiers = .{ .command = true, .option = true }, .key = .{ .char = '[' } }, .action = .previous_term },
    // Cmd+A: 전체 선택(Select All). macOS 앱 보편 단축키 — Terminal.app/iTerm2도 터미널 내용 전체를 선택한다.
    // 셸 줄-시작은 Ctrl+A(C0)라 안 겹친다. normalizeEventChar가 'a'를 'A'로 fold, 모디파이어 정확 비교.
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'A' } }, .action = .select_all },
    // Cmd+K: 화면 + 스크롤백 비우기(clear_screen). iTerm2/Terminal.app/Ghostty 공통 Mac 단축키(Ghostty 기본도 ⌘K).
    // 셸 줄-삭제는 Ctrl+K(C0)라 안 겹친다. normalizeEventChar가 'k'를 'K'로 fold, 모디파이어 정확 비교(Shift 등은 별개).
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'K' } }, .action = .clear_screen },
    // Cmd+Shift+P: 커맨드 팝업 토글(VS Code/Sublime/Zed 관례). 'p'→'P' fold, 모디파이어 정확 비교(Shift 필수라
    // Cmd+P[프린트 관습]와 안 겹친다). 팝업 열림 동안엔 handleKeyEvent가 키를 팝업으로 가로채 이 경로 안 탄다.
    .{ .chord = .{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = 'P' } }, .action = .toggle_command_palette },
    // Cmd+,: 세팅 화면 토글(macOS Settings 관례 — System Settings/대부분 앱). 콤마 키, Cmd만(Shift 없음). 기존
    // "Open Config…" 메뉴는 ⌘, keyEquivalent를 양보(Swift에서 제거)하고 메뉴 클릭으로만 남는다(config-gui §10).
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = ',' } }, .action = .toggle_settings },
    // Cmd+F: 스크롤백 Find 토글(macOS 보편 Find 단축키 — Terminal.app/iTerm2/브라우저 관례). 'f'→'F' fold,
    // 모디파이어 정확 비교(셸 Ctrl+F[커서 전진]와 안 겹친다). Find 열림 동안엔 handleKeyEvent가 키를 검색 입력으로
    // 가로채 이 경로 안 탄다(Enter=다음 매치, Shift+Enter=이전, Esc=닫기).
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'F' } }, .action = .toggle_find },
    // Cmd+Option+F: 찾기 + **바꾸기** 줄(§5.1 — VSCode·Xcode·TextEdit이 같은 자리다). ⌘F가 한 줄을
    // 유지하는 대신 이 chord가 두 줄을 연다 — 평범한 찾기에서 오버레이가 본문을 더 가리지 않는다.
    .{ .chord = .{ .modifiers = .{ .command = true, .option = true }, .key = .{ .char = 'F' } }, .action = .toggle_find_replace },
    // Cmd+G/Cmd+Shift+G: Find 오버레이가 **닫혀 있어도** 보존된 검색어로 다음/이전 매치로 점프(macOS Find Next/
    // Previous 관례 — Safari/TextEdit 등). 'g'→'G' fold, 모디파이어 정확 비교(Shift 유무로 방향). Find가 열린
    // 동안엔 모달 라우팅이 ⌘+글자를 가로채 닫으므로(Enter로 네비) 이 바인딩은 닫힌 경우를 위한 것이다.
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'G' } }, .action = .find_next },
    .{ .chord = .{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = 'G' } }, .action = .find_previous },
    // Cmd+Option+G: 사이드바 그룹 만들기(create_group) — 활성 워크스페이스에 그룹 시작 마커를 얹어 그 아래 연속
    // 카드를 접이식 그룹으로 묶는다. Cmd+Shift+G는 find_previous가 선점하고, Cmd+Opt는 pane/Term 이동 modifier
    // 그룹이나 'G' 키는 미사용이라 충돌이 없다(사용자 결정 — docs/sidebar-groups.md §7). 'g'→'G' fold, 정확 비교.
    // ungroup/rename_group은 저빈도라 기본 키 없이 팔레트·우클릭·설정 리바인더로만 노출한다.
    .{ .chord = .{ .modifiers = .{ .command = true, .option = true }, .key = .{ .char = 'G' } }, .action = .create_group },
    // Cmd+Option+Shift+G: 형제 그룹으로 분리(create_sibling_group, SG5-3) — create_group(Cmd+Opt+G, depth+1 중첩)과
    // **Shift로 구분**한다. Cmd+Shift+G는 find_previous, Cmd+Opt+G는 create_group이 선점하나 Cmd+Opt+Shift+G는 미사용이라
    // 충돌이 없다(그룹 안 카드 → 같은 depth 형제, 최상위 → depth 1). docs/sidebar-groups.md §7·§10.
    .{ .chord = .{ .modifiers = .{ .command = true, .option = true, .shift = true }, .key = .{ .char = 'G' } }, .action = .create_sibling_group },
    // 런타임 폰트 크기(macOS/브라우저/Ghostty 관례). ⌘=(또는 ⌘+)=키우기, ⌘-(또는 ⌘_)=줄이기, ⌘0=리셋.
    // '=' 키를 Shift와 함께 누르면 '+'가, '-'는 '_'가 오므로 양쪽을 다 묶어 키캡 표기(+/-)와 실제 글자(=/-)를
    // 모두 잡는다(모디파이어 정확 비교). 숫자/기호라 normalizeEventChar가 그대로 통과시킨다. 셸 입력과 안 겹친다.
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = '=' } }, .action = .increase_font_size },
    .{ .chord = .{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = '+' } }, .action = .increase_font_size },
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = '-' } }, .action = .decrease_font_size },
    .{ .chord = .{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = '_' } }, .action = .decrease_font_size },
    .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = '0' } }, .action = .reset_font_size },
};

pub const KeyBindingResolver = struct {
    app_bindings: []const AppBinding = &.{},
    terminal_bindings: []const TerminalBinding = &.{},
    /// 사용자가 `keybind = <chord> = unbind`로 끈 빌트인 기본 바인딩의 chord 목록. resolve가 이 chord를
    /// 만나면 빌트인 terminal/app 테이블을 **건너뛰어**(사용자 바인딩 다음) 기본 동작을 무력화한다 — Cmd 조합은
    /// fallthrough로 `.ignored`(아무 동작 안 함), 그 외는 encodeKey로 셸 입력이 된다. unbind는 app action이
    /// 아니라 "기본 끄기"라 Action union에 넣지 않고 별도 chord 목록으로 둔다(dispatchAppAction switch 무관).
    unbinds: []const KeyChord = &.{},

    pub fn validate(self: KeyBindingResolver) KeyBindingError!void {
        // Validation rejects ambiguous config up front. Runtime key handling
        // should be a simple decision, not a place where we guess whether the
        // app or the shell should receive the same chord.
        for (self.app_bindings, 0..) |left, left_index| {
            for (self.app_bindings[left_index + 1 ..]) |right| {
                if (left.chord.eql(right.chord)) return error.DuplicateAppBinding;
            }
            for (self.terminal_bindings) |terminal_binding| {
                if (left.chord.eql(terminal_binding.chord)) return error.AppTerminalBindingConflict;
            }
        }

        for (self.terminal_bindings, 0..) |left, left_index| {
            for (self.terminal_bindings[left_index + 1 ..]) |right| {
                if (left.chord.eql(right.chord)) return error.DuplicateTerminalBinding;
            }
            // A send_control macro whose codepoint has no C0 mapping (e.g. a
            // digit) can only fail when the key is pressed. Validate it up front
            // so a bad binding is a config-load error, not a mid-session key
            // failure. resolve() relies on this so it never has to handle an
            // invalid control codepoint at runtime.
            switch (left.input) {
                .send_control => |codepoint| {
                    _ = terminal.input.controlByte(codepoint) catch return error.InvalidControlKey;
                },
                else => {},
            }
        }
    }

    pub fn resolve(
        self: KeyBindingResolver,
        event: terminal.KeyEvent,
        buffer: *[terminal.input.encoded_key_buffer_len]u8,
        // active surface의 현재 인코딩 모드(DECCKM 등). 매크로 binding엔 영향 없고 fallback
        // encodeKey에만 적용된다 — 모드는 TerminalCore가 추적하고 호출자가 매 키마다 읽어 넘긴다.
        encode_options: terminal.input.EncodeOptions,
    ) !ResolvedKey {
        const chord = KeyChord.fromKeyEvent(event) orelse return .ignored;

        for (self.app_bindings) |binding| {
            if (binding.chord.eql(chord)) return .{ .app_action = binding.action };
        }

        for (self.terminal_bindings) |binding| {
            if (binding.chord.eql(chord)) {
                return .{ .terminal_input = try binding.input.bytes(buffer) };
            }
        }

        // 사용자가 이 chord를 unbind 했으면 빌트인 기본 테이블을 건너뛴다(사용자 바인딩으로도 안 잡힌 경우).
        // 그러면 Cmd 조합은 아래 .ignored(아무 동작 안 함), 그 외는 encodeKey로 셸 입력이 된다 — "기본 끄기".
        const unbound = self.isUnbound(chord);

        // 빌트인 기본 바인딩(macOS 줄 편집). 사용자 바인딩 다음, Cmd-무시 fallthrough 전에 본다 —
        // 안 그러면 Cmd+Backspace/←/→가 아래 .ignored로 새 나간다. unbind 된 chord는 건너뛴다.
        if (!unbound) {
            for (default_terminal_bindings) |binding| {
                if (binding.chord.eql(chord)) {
                    return .{ .terminal_input = try binding.input.bytes(buffer) };
                }
            }

            // 빌트인 app 바인딩(Cmd+T=새 탭 등). 사용자 바인딩·빌트인 terminal 다음, Cmd-무시 fallthrough
            // 전에 본다 — 안 그러면 Cmd+T가 아래 .ignored로 새 나가 탭이 안 열린다. unbind 된 chord는 건너뛴다.
            for (default_app_bindings) |binding| {
                if (binding.chord.eql(chord)) return .{ .app_action = binding.action };
            }
        }

        if (event.modifiers.command) {
            // 여기까지 안 묶인 Cmd 조합은 macOS 앱 단축키다(Cmd+S/Q...). 셸로 raw 글자를 보내면
            // Cmd+S가 's'를 타이핑하므로 무시한다. 편집용 Cmd 조합은 위 빌트인 테이블이 이미 가져간다.
            return .ignored;
        }

        return .{ .terminal_input = try terminal.input.encodeKey(event, buffer, encode_options) };
    }

    pub const FileTreeResolution = union(enum) {
        app_action: action_mod.Action,
        tree_default,
        consumed,
    };

    /// project tree context는 셸 바이트를 절대 내보내지 않는다. 사용자 app binding이 최우선이고, terminal macro나
    /// explicit unbind는 chord를 소비해 tree 기본키도 막는다. 둘 다 없을 때 built-in app action, 그 다음 tree 기본키다.
    pub fn resolveFileTree(self: KeyBindingResolver, event: terminal.KeyEvent, is_tree_default: bool) FileTreeResolution {
        const chord = KeyChord.fromKeyEvent(event) orelse return .consumed;
        for (self.app_bindings) |binding| {
            if (binding.chord.eql(chord)) return .{ .app_action = binding.action };
        }
        for (self.terminal_bindings) |binding| {
            if (binding.chord.eql(chord)) return .consumed;
        }
        if (self.isUnbound(chord)) return .consumed;
        for (default_app_bindings) |binding| {
            if (binding.chord.eql(chord)) return .{ .app_action = binding.action };
        }
        return if (is_tree_default) .tree_default else .consumed;
    }

    /// Web context는 PTY 바이트를 절대 내보내지 않는다. 사용자 app rebind가 최우선이고 terminal macro와 explicit
    /// unbind는 소비한다. Markdown 편집 모드에서는 WebKit의 표준 편집 chord가 built-in app/terminal default보다
    /// 먼저 소유하며, 그 밖의 built-in app action만 앱으로 되돌린다.
    pub fn resolveWeb(self: KeyBindingResolver, event: terminal.KeyEvent, editable: bool) WebKeyRoute {
        return self.resolveWebDetailed(event, editable).route();
    }

    pub fn resolveWebAppAction(self: KeyBindingResolver, event: terminal.KeyEvent, editable: bool) ?action_mod.Action {
        return switch (self.resolveWebDetailed(event, editable)) {
            .app_action => |action| action,
            else => null,
        };
    }

    fn resolveWebDetailed(self: KeyBindingResolver, event: terminal.KeyEvent, editable: bool) WebResolution {
        const chord = KeyChord.fromKeyEvent(event) orelse return .pass_through;
        for (self.app_bindings) |binding| {
            if (binding.chord.eql(chord)) return .{ .app_action = binding.action };
        }
        for (self.terminal_bindings) |binding| {
            if (binding.chord.eql(chord)) return .consume_unbound;
        }
        if (self.isUnbound(chord)) return .consume_unbound;
        if (editable and isWebEditorDefault(chord)) return .web_editor;
        for (default_app_bindings) |binding| {
            if (binding.chord.eql(chord)) return .{ .app_action = binding.action };
        }
        return .pass_through;
    }

    /// chord가 사용자 unbind 목록에 있는가 — resolve가 빌트인 기본 테이블을 건너뛸지 정하는 데 쓴다.
    fn isUnbound(self: KeyBindingResolver, chord: KeyChord) bool {
        for (self.unbinds) |unbound| {
            if (unbound.eql(chord)) return true;
        }
        return false;
    }
};

fn isWebEditorDefault(chord: KeyChord) bool {
    if (!chord.modifiers.command) return true;
    if (chord.modifiers.control or chord.modifiers.option) return false;
    return switch (chord.key) {
        .char => |c| if (c > 0x7f) false else switch (std.ascii.toUpper(@as(u8, @intCast(c)))) {
            'A', 'C', 'F', 'S', 'V', 'X', 'Z' => true,
            else => false,
        },
        .enter => !chord.modifiers.shift,
        .backspace, .delete, .arrow_left, .arrow_right, .arrow_up, .arrow_down, .home, .end => true,
        else => false,
    };
}

const ModifierName = enum { control, option, shift, command };

fn parseModifier(raw: []const u8) ?ModifierName {
    if (std.ascii.eqlIgnoreCase(raw, "Ctrl")) return .control;
    if (std.ascii.eqlIgnoreCase(raw, "Alt")) return .option;
    if (std.ascii.eqlIgnoreCase(raw, "Shift")) return .shift;
    if (std.ascii.eqlIgnoreCase(raw, "Cmd")) return .command;
    return null;
}

fn setModifier(modifiers: *terminal.ModifierSet, modifier: ModifierName) KeyBindingError!void {
    switch (modifier) {
        .control => {
            if (modifiers.control) return error.DuplicateModifier;
            modifiers.control = true;
        },
        .option => {
            if (modifiers.option) return error.DuplicateModifier;
            modifiers.option = true;
        },
        .shift => {
            if (modifiers.shift) return error.DuplicateModifier;
            modifiers.shift = true;
        },
        .command => {
            if (modifiers.command) return error.DuplicateModifier;
            modifiers.command = true;
        },
    }
}

fn parseKey(raw: []const u8) KeyBindingError!KeyName {
    if (raw.len == 1) {
        const byte = raw[0];
        if (std.ascii.isAlphabetic(byte)) return .{ .char = std.ascii.toUpper(byte) };
        if (std.ascii.isDigit(byte) or isAllowedPunctuation(byte)) return .{ .char = byte };
    }

    if (std.ascii.eqlIgnoreCase(raw, "Esc")) return .escape;
    if (std.ascii.eqlIgnoreCase(raw, "Tab")) return .tab;
    if (std.ascii.eqlIgnoreCase(raw, "Enter")) return .enter;
    if (std.ascii.eqlIgnoreCase(raw, "Space")) return .{ .char = ' ' };
    // '+' is the chord-part separator, so the literal plus key cannot be written
    // inline. Accept the "Plus" spelling so `Cmd+Plus` binds the '+' key.
    if (std.ascii.eqlIgnoreCase(raw, "Plus")) return .{ .char = '+' };
    if (std.ascii.eqlIgnoreCase(raw, "Backspace")) return .backspace;
    if (std.ascii.eqlIgnoreCase(raw, "Delete")) return .delete;
    if (std.ascii.eqlIgnoreCase(raw, "Insert")) return .insert;
    if (std.ascii.eqlIgnoreCase(raw, "Home")) return .home;
    if (std.ascii.eqlIgnoreCase(raw, "End")) return .end;
    if (std.ascii.eqlIgnoreCase(raw, "PageUp")) return .page_up;
    if (std.ascii.eqlIgnoreCase(raw, "PageDown")) return .page_down;
    if (std.ascii.eqlIgnoreCase(raw, "Up")) return .arrow_up;
    if (std.ascii.eqlIgnoreCase(raw, "Down")) return .arrow_down;
    if (std.ascii.eqlIgnoreCase(raw, "Left")) return .arrow_left;
    if (std.ascii.eqlIgnoreCase(raw, "Right")) return .arrow_right;
    if (raw.len >= 2 and (raw[0] == 'F' or raw[0] == 'f')) {
        const value = std.fmt.parseUnsigned(u8, raw[1..], 10) catch return error.InvalidFunctionKey;
        if (value == 0 or value > 24) return error.InvalidFunctionKey;
        return .{ .function = value };
    }

    return error.UnknownChordPart;
}

fn keyNameFromTerminalKey(key: terminal.Key) ?KeyName {
    // terminal.Key가 home/end/insert/delete/page_up/page_down/function 변형을 가지면서, 그 키들의
    // 바인딩이 실제 키 이벤트와 매칭된다(이전엔 죽은 설정이었다). F13~F24는 terminal.Key의 function이
    // 1~12만 물리 키로 들어오므로 설정으론 적되 매칭되지 않을 수 있다(F13+는 후속).
    return switch (key) {
        .char => |codepoint| .{ .char = normalizeEventChar(codepoint) },
        .enter => .enter,
        .escape => .escape,
        .tab => .tab,
        .backspace => .backspace,
        .delete => .delete,
        .insert => .insert,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .arrow_up => .arrow_up,
        .arrow_down => .arrow_down,
        .arrow_left => .arrow_left,
        .arrow_right => .arrow_right,
        .function => |n| .{ .function = n },
    };
}

fn normalizeEventChar(codepoint: u21) u21 {
    // Fold ASCII letters to uppercase so a typed 'b' matches a parsed 'B'. parseKey
    // uses std.ascii.toUpper for the same fold; reuse it here so the two paths
    // cannot drift. Non-ASCII codepoints pass through unchanged.
    if (codepoint > std.math.maxInt(u8)) return codepoint;
    return std.ascii.toUpper(@intCast(codepoint));
}

fn isAllowedPunctuation(byte: u8) bool {
    return switch (byte) {
        ',', '.', '/', ';', '\'', '[', ']', '-', '=', '`' => true,
        else => false,
    };
}

test "parses key chords with canonical modifiers and keys" {
    const chord = try KeyChord.parse("ctrl+cmd+,");

    try std.testing.expect(chord.modifiers.control);
    try std.testing.expect(chord.modifiers.command);
    try std.testing.expect(!chord.modifiers.option);
    try std.testing.expect(chord.key.eql(.{ .char = ',' }));

    try std.testing.expect((try KeyChord.parse("Shift+Alt+F13")).key.eql(.{ .function = 13 }));
    try std.testing.expect((try KeyChord.parse("Cmd+B")).key.eql(.{ .char = 'B' }));
}

test "rejects ambiguous key chord strings" {
    try std.testing.expectError(error.DuplicateModifier, KeyChord.parse("Cmd+Cmd+B"));
    try std.testing.expectError(error.UnknownChordPart, KeyChord.parse("Command+B"));
    try std.testing.expectError(error.MissingKey, KeyChord.parse("Ctrl+Cmd"));
    try std.testing.expectError(error.MultipleKeys, KeyChord.parse("Ctrl+B+C"));
    try std.testing.expectError(error.InvalidFunctionKey, KeyChord.parse("F25"));
}

test "parses the literal plus key via the Plus spelling" {
    try std.testing.expect((try KeyChord.parse("Cmd+Plus")).key.eql(.{ .char = '+' }));
    // The bare '+' separator still cannot be a key, so an empty part errors.
    try std.testing.expectError(error.EmptyChordPart, KeyChord.parse("Cmd++"));
}

test "toConfigString round-trips through parse (keybind recorder write-back)" {
    var buf: [32]u8 = undefined;
    const cases = [_]KeyChord{
        .{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = 'T' } },
        .{ .modifiers = .{ .control = true, .option = true }, .key = .{ .char = ' ' } }, // Space
        .{ .modifiers = .{ .command = true }, .key = .{ .char = '+' } }, // Plus
        .{ .modifiers = .{ .command = true }, .key = .arrow_up },
        .{ .modifiers = .{ .shift = true }, .key = .{ .function = 5 } },
        .{ .modifiers = .{}, .key = .escape },
        .{ .modifiers = .{ .control = true, .option = true, .shift = true, .command = true }, .key = .page_down },
    };
    for (cases) |c| {
        const s = c.toConfigString(&buf);
        const parsed = try KeyChord.parse(s);
        try std.testing.expect(parsed.eql(c)); // parse(toConfigString(c)) == c
    }
    // 표기 확인(사람이 읽는 철자) — option은 "Alt"(parseModifier 짝), 순서는 Cmd→Ctrl→Alt→Shift.
    try std.testing.expectEqualStrings("Cmd+Shift+T", (KeyChord{ .modifiers = .{ .command = true, .shift = true }, .key = .{ .char = 'T' } }).toConfigString(&buf));
    try std.testing.expectEqualStrings("Ctrl+Alt+Space", (KeyChord{ .modifiers = .{ .control = true, .option = true }, .key = .{ .char = ' ' } }).toConfigString(&buf));
}

test "validate rejects a send_control macro with no C0 mapping" {
    // A digit has no control byte; this must fail at config validation, not when
    // the key is later pressed.
    try std.testing.expectError(error.InvalidControlKey, (KeyBindingResolver{
        .terminal_bindings = &.{
            .{ .chord = try KeyChord.parse("Ctrl+1"), .input = .{ .send_control = '1' } },
        },
    }).validate());
}

test "send_control accepts non-letter C0 controls like Ctrl+[" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{
        .terminal_bindings = &.{
            .{ .chord = try KeyChord.parse("Cmd+E"), .input = .{ .send_control = '[' } },
        },
    };
    try resolver.validate();
    const resolved = try resolver.resolve(.{
        .key = .{ .char = 'e' },
        .modifiers = .{ .command = true },
    }, &buffer, .{});
    try std.testing.expectEqualStrings("\x1b", resolved.terminal_input); // Ctrl+[ == ESC
}

test "unbound Ctrl with an unmapped key types the character instead of erroring" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};
    try std.testing.expectEqualStrings(
        "1",
        (try resolver.resolve(.{
            .key = .{ .char = '1' },
            .modifiers = .{ .control = true },
        }, &buffer, .{})).terminal_input,
    );
}

test "resolver prioritizes app actions and blocks conflicting terminal macros" {
    const chord = try KeyChord.parse("Cmd+B");
    const resolver: KeyBindingResolver = .{
        .app_bindings = &.{.{ .chord = chord, .action = .new_tab }},
        .terminal_bindings = &.{.{ .chord = chord, .input = .{ .send_control = 'b' } }},
    };

    try std.testing.expectError(error.AppTerminalBindingConflict, resolver.validate());
}

test "resolver consumes configured app actions before terminal input" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{
        .app_bindings = &.{.{ .chord = try KeyChord.parse("Cmd+T"), .action = .new_tab }},
    };
    try resolver.validate();

    const resolved = try resolver.resolve(.{
        .key = .{ .char = 't' },
        .modifiers = .{ .command = true },
    }, &buffer, .{});

    try std.testing.expectEqual(action_mod.Action.new_tab, resolved.app_action);
}

/// 빌트인 표 **어디에도 없는** Cmd+글자 하나(테스트 전용).
///
/// **테스트가 글자를 손으로 고르지 않게 한다.** 「안 묶인 Cmd 조합은 셸로 안 샌다」를 지키는 판정자가
/// 여럿인데, 그들이 각자 `'s'` 를 예시로 박아 두고 있었다 — 2026-08-27 에 ⌘S·⌘Z 를 배선하자 **넷이
/// 동시에 깨졌다**. 규율이 깨진 것이 아니라 예시가 유효하지 않게 된 것이고, 그 구분이 커밋을 열기
/// 전에는 보이지 않는다.
///
/// 여기서 표를 훑어 고르면 표가 자라도 판정자가 따라온다. 남는 글자가 없으면 그 자체가 답할 것이
/// 없어진 상태이므로 comptime 에 멈춘다.
/// **상수이지 함수가 아니다.** `@compileError` 는 함수 본문에 있으면 **도달 가능성과 무관하게**
/// 평가되므로(첫 판이 그랬다), 계산 전체를 comptime 블록에 둔다.
pub const unbound_command_char: u21 = blk: {
    for ("BCHIJLMNQRUVXY") |candidate| {
        var taken = false;
        for (default_app_bindings) |b| switch (b.chord.key) {
            .char => |c| if (c == candidate) {
                taken = true;
            },
            else => {},
        };
        for (default_terminal_bindings) |b| switch (b.chord.key) {
            .char => |c| if (c == candidate) {
                taken = true;
            },
            else => {},
        };
        if (!taken) break :blk candidate;
    }
    @compileError("빌트인 표가 후보 글자를 전부 먹었다 — 후보를 늘리거나 판정 방식을 다시 본다");
};

test "built-in app bindings: 편집기 편집 일습이 chord 를 갖는다 (⌘Z·⌘⇧Z·⌘S)" {
    // **이 셋이 없던 동안 기능은 다 서 있었다** — undo 스택은 §3.3 계약대로 완성됐는데 부르는 길이
    // 커맨드 팔레트뿐이라 사용자에게는 「undo 가 없는 것」과 거의 같았다. 계획 문서의 「남은 것」
    // 목록은 각 기능의 완료만 적고 *"어떤 키가 부르는가"* 는 아무도 자기 것으로 적지 않았다.
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};

    // 소문자로 눌러도 `normalizeEventChar` 가 대문자로 fold 한다(⌘T 와 같은 규율).
    const z = try resolver.resolve(.{ .key = .{ .char = 'z' }, .modifiers = .{ .command = true } }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.editor_undo, z.app_action);
    const sz = try resolver.resolve(.{ .key = .{ .char = 'Z' }, .modifiers = .{ .command = true, .shift = true } }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.editor_redo, sz.app_action);
    const s_key = try resolver.resolve(.{ .key = .{ .char = 's' }, .modifiers = .{ .command = true } }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.editor_save, s_key.app_action);

    // **⌘Z 와 ⌘⇧Z 는 modifier 정확 비교로 갈린다.** shift 를 무시하면 redo 가 undo 를 덮어 되돌리기만
    // 남는다 — `.eql` 이 부분 일치였다면 이 단언이 깨진다.
    try std.testing.expect(std.meta.activeTag(z.app_action) != std.meta.activeTag(sz.app_action));

    // **사용자 바인딩이 이긴다.** 빌트인은 사용자 표 **다음**에 보므로(`resolve` 의 순서) 이 셋도
    // 사용자가 다른 것으로 바꿀 수 있어야 한다 — 빌트인을 먼저 보면 그 자유가 사라진다.
    const overridden: KeyBindingResolver = .{ .app_bindings = &.{
        .{ .chord = .{ .modifiers = .{ .command = true }, .key = .{ .char = 'Z' } }, .action = .new_term },
    } };
    const user_z = try overridden.resolve(.{ .key = .{ .char = 'z' }, .modifiers = .{ .command = true } }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.new_term, user_z.app_action);

    // **끌 수도 있어야 한다.** `unbind` 하면 빌트인 표를 건너뛰고 Cmd 조합이므로 `.ignored` 로 떨어진다 —
    // 배선 전 상태로 정확히 돌아간다. 이것이 없으면 새 기본 chord 가 사용자에게 **강제**가 된다.
    const unbound_z: KeyBindingResolver = .{ .unbinds = &.{
        .{ .modifiers = .{ .command = true }, .key = .{ .char = 'Z' } },
    } };
    try std.testing.expectEqual(
        ResolvedKey.ignored,
        try unbound_z.resolve(.{ .key = .{ .char = 'z' }, .modifiers = .{ .command = true } }, &buffer, .{}),
    );
}

test "웹 편집 필드의 ⌘Z·⌘S 는 빌트인 편집기 chord 에 안 뺏긴다 (순서 계약)" {
    // **위험이 실재했다.** ⌘Z·⌘S 를 `default_app_bindings` 에 넣는 순간, 웹 편집 필드(주소창·CM6·
    // 브라우저 폼)에서 그 키가 WebKit 대신 편집기 액션으로 갈 수 있다 — 그러면 웹에서 되돌리기가 죽는다.
    //
    // 막는 것은 `resolveWebDetailed` 의 **순서** 하나다: `isWebEditorDefault` 가 `default_app_bindings`
    // **앞**에 있다. 그 순서가 뒤집히면 이 단언이 깨진다 — 지금은 우연히 맞는 것이 아니라 계약이다.
    const resolver: KeyBindingResolver = .{};
    inline for (.{ 'z', 's', 'a', 'c', 'f', 'v', 'x' }) |c| {
        const ev = terminal.KeyEvent{ .key = .{ .char = c }, .modifiers = .{ .command = true } };
        try std.testing.expectEqual(WebKeyRoute.web_editor, resolver.resolveWeb(ev, true));
        // **편집 불가 문서에서는 이야기가 다르다** — 거기서는 빌트인이 가져가고, 활성 Term 이 웹이라
        // 편집기 액션은 `term.kind != .editor` 로 거절된다(무동작). 뺏기는 것이 아니라 갈 곳이 없다.
        _ = resolver.resolveWeb(ev, false);
    }

    // ⌘⇧Z 는 `isWebEditorDefault` 목록에 **없다**(그 함수는 shift 를 안 가리는 대신 글자로만 판정하고
    // `Z` 는 목록에 있다) — 편집 필드에서도 같은 갈래로 간다. 이 줄은 그 사실을 고정한다.
    const redo = terminal.KeyEvent{ .key = .{ .char = 'z' }, .modifiers = .{ .command = true, .shift = true } };
    try std.testing.expectEqual(WebKeyRoute.web_editor, resolver.resolveWeb(redo, true));
}

test "built-in app bindings: Cmd+T new_term, Cmd+Shift+T new_tab (tab model)" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{}; // 사용자 바인딩 없음 — default_app_bindings가 가져가야

    // 글자 't'는 normalizeEventChar가 'T'로 fold. ⌘T → 활성 pane에 새 Term, ⌘⇧T → 새 워크스페이스.
    const t = try resolver.resolve(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.new_term, t.app_action);
    const st = try resolver.resolve(.{ .key = .{ .char = 'T' }, .modifiers = .{ .command = true, .shift = true } }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.new_tab, st.app_action);
    // ⌘⌥T → 활성 pane에 새 브라우저 Term(new_term의 web 버전). ⌘T·⌘⇧T와 modifier로 갈린다.
    const ot = try resolver.resolve(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true, .option = true } }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.new_web_tab, ot.app_action);

    // 안 묶인 Cmd 조합은 그대로 ignored(셸로 글자 안 샘). **글자는 계산해서 고른다** — 손으로 박으면
    // 그 글자가 묶이는 날 이 판정자가 규율이 아니라 예시 때문에 깨진다(`unboundCommandChar` 주석).
    try std.testing.expect((try resolver.resolve(.{
        .key = .{ .char = unbound_command_char },
        .modifiers = .{ .command = true },
    }, &buffer, .{})) == .ignored);
}

test "built-in app binding resolves Cmd+O to open_file_panel" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};
    const resolved = try resolver.resolve(.{
        .key = .{ .char = 'o' },
        .modifiers = .{ .command = true },
    }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.open_file_panel, resolved.app_action);
}

test "built-in app binding resolves Cmd+K to clear_screen without user config" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};
    // 'k'는 normalizeEventChar가 'K'로 fold → default_app_bindings의 'K'와 매칭. 화면+스크롤백 비우기.
    const resolved = try resolver.resolve(.{
        .key = .{ .char = 'k' },
        .modifiers = .{ .command = true },
    }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.clear_screen, resolved.app_action);
}

test "built-in app binding resolves Cmd+W to close_focused without user config" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};
    // 'w'는 normalizeEventChar가 'W'로 fold → default_app_bindings의 'W'와 매칭(Shift 무관). 활성 Term 닫기.
    const resolved = try resolver.resolve(.{
        .key = .{ .char = 'w' },
        .modifiers = .{ .command = true },
    }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.close_focused, resolved.app_action);
}

test "file panel focus toggle owns Cmd+Shift+E and remains rebindable/unbindable" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const defaults: KeyBindingResolver = .{};
    const resolved = try defaults.resolve(.{
        .key = .{ .char = 'e' },
        .modifiers = .{ .command = true, .shift = true },
    }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.toggle_file_panel_focus, resolved.app_action);

    const rebound: KeyBindingResolver = .{ .app_bindings = &.{.{ .chord = try KeyChord.parse("Cmd+E"), .action = .toggle_file_panel_focus }} };
    try std.testing.expectEqual(action_mod.Action.toggle_file_panel_focus, (try rebound.resolve(.{
        .key = .{ .char = 'e' },
        .modifiers = .{ .command = true },
    }, &buffer, .{})).app_action);

    const unbound: KeyBindingResolver = .{ .unbinds = &.{try KeyChord.parse("Cmd+Shift+E")} };
    try std.testing.expect((try unbound.resolve(.{
        .key = .{ .char = 'e' },
        .modifiers = .{ .command = true, .shift = true },
    }, &buffer, .{})) == .ignored);
}

test "file tree context honors app override and unbind without leaking terminal macros" {
    const up = terminal.KeyEvent{ .key = .arrow_up };
    const custom: KeyBindingResolver = .{
        .app_bindings = &.{.{ .chord = try KeyChord.parse("Up"), .action = .new_tab }},
    };
    try std.testing.expectEqual(action_mod.Action.new_tab, custom.resolveFileTree(up, true).app_action);

    const unbound: KeyBindingResolver = .{ .unbinds = &.{try KeyChord.parse("Up")} };
    try std.testing.expect(unbound.resolveFileTree(up, true) == .consumed);

    const macro: KeyBindingResolver = .{
        .terminal_bindings = &.{.{ .chord = try KeyChord.parse("Up"), .input = .{ .send_text = "leak" } }},
    };
    try std.testing.expect(macro.resolveFileTree(up, true) == .consumed);

    const defaults: KeyBindingResolver = .{};
    try std.testing.expect(defaults.resolveFileTree(up, true) == .tree_default);
    const close = defaults.resolveFileTree(.{ .key = .{ .char = 'w' }, .modifiers = .{ .command = true } }, false);
    try std.testing.expectEqual(action_mod.Action.close_focused, close.app_action);
}

test "web context gives editable defaults to WebKit after user override and unbind" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(WebKeyRoute.pass_through));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(WebKeyRoute.app_action));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(WebKeyRoute.consume_unbound));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(WebKeyRoute.web_editor));
    const save = terminal.KeyEvent{ .key = .{ .char = 's' }, .modifiers = .{ .command = true } };
    const find = terminal.KeyEvent{ .key = .{ .char = 'f' }, .modifiers = .{ .command = true } };
    const close = terminal.KeyEvent{ .key = .{ .char = 'w' }, .modifiers = .{ .command = true } };
    const activate = terminal.KeyEvent{ .key = .enter, .modifiers = .{ .command = true } };
    const defaults: KeyBindingResolver = .{};
    try std.testing.expectEqual(WebKeyRoute.web_editor, defaults.resolveWeb(save, true));
    try std.testing.expectEqual(WebKeyRoute.web_editor, defaults.resolveWeb(find, true));
    try std.testing.expectEqual(WebKeyRoute.web_editor, defaults.resolveWeb(activate, true));
    try std.testing.expectEqual(WebKeyRoute.pass_through, defaults.resolveWeb(activate, false));
    try std.testing.expectEqual(WebKeyRoute.app_action, defaults.resolveWeb(close, true));
    try std.testing.expectEqual(WebKeyRoute.app_action, defaults.resolveWeb(find, false));

    const rebound: KeyBindingResolver = .{ .app_bindings = &.{.{ .chord = try KeyChord.parse("Cmd+S"), .action = .new_tab }} };
    try std.testing.expectEqual(WebKeyRoute.app_action, rebound.resolveWeb(save, true));
    try std.testing.expectEqual(action_mod.Action.new_tab, rebound.resolveWebAppAction(save, true).?);
    const unbound: KeyBindingResolver = .{ .unbinds = &.{try KeyChord.parse("Cmd+S")} };
    try std.testing.expectEqual(WebKeyRoute.consume_unbound, unbound.resolveWeb(save, true));
    const macro: KeyBindingResolver = .{ .terminal_bindings = &.{.{ .chord = try KeyChord.parse("Cmd+S"), .input = .{ .send_text = "leak" } }} };
    try std.testing.expectEqual(WebKeyRoute.consume_unbound, macro.resolveWeb(save, true));

    const activate_rebound: KeyBindingResolver = .{ .app_bindings = &.{.{ .chord = try KeyChord.parse("Cmd+Enter"), .action = .new_tab }} };
    try std.testing.expectEqual(WebKeyRoute.app_action, activate_rebound.resolveWeb(activate, true));
    const activate_unbound: KeyBindingResolver = .{ .unbinds = &.{try KeyChord.parse("Cmd+Enter")} };
    try std.testing.expectEqual(WebKeyRoute.consume_unbound, activate_unbound.resolveWeb(activate, true));
    const activate_macro: KeyBindingResolver = .{ .terminal_bindings = &.{.{ .chord = try KeyChord.parse("Cmd+Enter"), .input = .{ .send_text = "leak" } }} };
    try std.testing.expectEqual(WebKeyRoute.consume_unbound, activate_macro.resolveWeb(activate, true));
}

test "web context keeps terminal navigation defaults inside an editable WebView" {
    const resolver: KeyBindingResolver = .{};
    try std.testing.expectEqual(WebKeyRoute.web_editor, resolver.resolveWeb(.{ .key = .backspace, .modifiers = .{ .command = true } }, true));
    try std.testing.expectEqual(WebKeyRoute.web_editor, resolver.resolveWeb(.{ .key = .arrow_left, .modifiers = .{ .command = true } }, true));
    try std.testing.expectEqual(WebKeyRoute.pass_through, resolver.resolveWeb(.{ .key = .arrow_left, .modifiers = .{ .command = true } }, false));
}

test "unbind skips the built-in default: Cmd chord becomes ignored, others fall through to the shell" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    // Cmd+T(빌트인 new_term)와 Cmd+Left(빌트인 줄 시작 Ctrl+A)를 unbind.
    const resolver: KeyBindingResolver = .{
        .unbinds = &.{ try KeyChord.parse("Cmd+T"), try KeyChord.parse("Cmd+Left") },
    };
    try resolver.validate();

    // Cmd+T: 빌트인 new_term을 건너뛰고 Cmd-무시로 → ignored(새 Term 안 열림, 's'처럼 글자도 안 샘).
    try std.testing.expect((try resolver.resolve(.{
        .key = .{ .char = 't' },
        .modifiers = .{ .command = true },
    }, &buffer, .{})) == .ignored);

    // Cmd+Left: 빌트인 terminal 매크로(Ctrl+A)를 건너뛰고 Cmd-무시로 → ignored(줄 시작으로 안 감).
    try std.testing.expect((try resolver.resolve(.{
        .key = .arrow_left,
        .modifiers = .{ .command = true },
    }, &buffer, .{})) == .ignored);

    // unbind 안 된 Cmd+W는 그대로 빌트인 close_focused.
    try std.testing.expectEqual(action_mod.Action.close_focused, (try resolver.resolve(.{
        .key = .{ .char = 'w' },
        .modifiers = .{ .command = true },
    }, &buffer, .{})).app_action);
}

test "user binding still wins over unbind for the same chord (override, not disable)" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    // 같은 chord가 사용자 app 바인딩으로도 있으면 그게 우선(unbind는 빌트인만 끈다 — 사용자 바인딩 다음에 본다).
    const resolver: KeyBindingResolver = .{
        .app_bindings = &.{.{ .chord = try KeyChord.parse("Cmd+T"), .action = .new_tab }},
        .unbinds = &.{try KeyChord.parse("Cmd+T")},
    };
    const resolved = try resolver.resolve(.{
        .key = .{ .char = 't' },
        .modifiers = .{ .command = true },
    }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.new_tab, resolved.app_action);
}

test "built-in app bindings resolve Cmd+Shift+]/[ to next/previous tab for both bracket variants" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};
    // ]/} 둘 다 next_tab(OS가 Shift를 적용해 }로 주든 ]로 주든).
    for ([_]u21{ ']', '}' }) |c| {
        const r = try resolver.resolve(.{ .key = .{ .char = c }, .modifiers = .{ .command = true, .shift = true } }, &buffer, .{});
        try std.testing.expectEqual(action_mod.Action.next_tab, r.app_action);
    }
    // [/{ 둘 다 previous_tab.
    for ([_]u21{ '[', '{' }) |c| {
        const r = try resolver.resolve(.{ .key = .{ .char = c }, .modifiers = .{ .command = true, .shift = true } }, &buffer, .{});
        try std.testing.expectEqual(action_mod.Action.previous_tab, r.app_action);
    }
    // Shift 없는 Cmd+]/[ 는 split(pane) 순환(워크스페이스가 아니라) — modifier로 갈린다.
    const nt = try resolver.resolve(.{ .key = .{ .char = ']' }, .modifiers = .{ .command = true } }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.next_pane, nt.app_action);
    const pt = try resolver.resolve(.{ .key = .{ .char = '[' }, .modifiers = .{ .command = true } }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.previous_pane, pt.app_action);
    // Cmd+Option+]/[ 는 Term(가로 탭) 순환 — ⌘[]를 split에 양보하고 Term을 ⌘⌥[]로 옮겼다(사용자 요청).
    const not_ = try resolver.resolve(.{ .key = .{ .char = ']' }, .modifiers = .{ .command = true, .option = true } }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.next_term, not_.app_action);
    const pot = try resolver.resolve(.{ .key = .{ .char = '[' }, .modifiers = .{ .command = true, .option = true } }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.previous_term, pot.app_action);
}

test "built-in app bindings resolve Cmd+1..9 to select_tab(N-1)" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};
    // Cmd+1 → 워크스페이스 0, Cmd+2 → 1, … Cmd+9 → 8 (0-based select_tab).
    for ([_]u21{ '1', '2', '3', '4', '5', '6', '7', '8', '9' }, 0..) |c, i| {
        const r = try resolver.resolve(.{ .key = .{ .char = c }, .modifiers = .{ .command = true } }, &buffer, .{});
        try std.testing.expectEqual(action_mod.Action{ .select_tab = i }, r.app_action);
    }
}

test "built-in app bindings resolve Cmd+D / Cmd+Shift+D to horizontal / vertical split" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};
    // 'd'는 normalizeEventChar가 'D'로 fold → Cmd+D(shift 없음)는 좌우, Cmd+Shift+D는 상하. shift만으로 갈린다.
    const h = try resolver.resolve(.{ .key = .{ .char = 'd' }, .modifiers = .{ .command = true } }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.split_horizontal, h.app_action);
    const v = try resolver.resolve(.{ .key = .{ .char = 'D' }, .modifiers = .{ .command = true, .shift = true } }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.split_vertical, v.app_action);
}

test "built-in app bindings resolve Cmd+Option+arrows to directional pane focus" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};
    const mods: terminal.ModifierSet = .{ .command = true, .option = true };
    const l = try resolver.resolve(.{ .key = .arrow_left, .modifiers = mods }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.focus_pane_left, l.app_action);
    const r = try resolver.resolve(.{ .key = .arrow_right, .modifiers = mods }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.focus_pane_right, r.app_action);
    const u = try resolver.resolve(.{ .key = .arrow_up, .modifiers = mods }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.focus_pane_up, u.app_action);
    const d = try resolver.resolve(.{ .key = .arrow_down, .modifiers = mods }, &buffer, .{});
    try std.testing.expectEqual(action_mod.Action.focus_pane_down, d.app_action);
    // Cmd만(Option 없음)인 화살표는 app 액션이 아니라 터미널 줄-이동 바인딩(Ctrl+A=줄 시작) — 모디파이어
    // 정확 비교라 pane 이동(command+option)과 안 겹친다.
    const cmd_only = try resolver.resolve(.{ .key = .arrow_left, .modifiers = .{ .command = true } }, &buffer, .{});
    try std.testing.expect(cmd_only == .terminal_input);
}

test "resolver rejects duplicate app and terminal bindings separately" {
    try std.testing.expectError(error.DuplicateAppBinding, (KeyBindingResolver{
        .app_bindings = &.{
            .{ .chord = try KeyChord.parse("Cmd+T"), .action = .new_tab },
            .{ .chord = try KeyChord.parse("Cmd+T"), .action = .close_tab },
        },
    }).validate());

    try std.testing.expectError(error.DuplicateTerminalBinding, (KeyBindingResolver{
        .terminal_bindings = &.{
            .{ .chord = try KeyChord.parse("F13"), .input = .{ .send_escape_sequence = "\x1b[25~" } },
            .{ .chord = try KeyChord.parse("F13"), .input = .{ .send_text = "duplicate" } },
        },
    }).validate());
}

test "resolver maps focused terminal macro to terminal bytes" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{
        .terminal_bindings = &.{.{
            .chord = try KeyChord.parse("Cmd+B"),
            .input = .{ .send_control = 'b' },
        }},
    };
    try resolver.validate();

    const resolved = try resolver.resolve(.{
        .key = .{ .char = 'b' },
        .modifiers = .{ .command = true },
    }, &buffer, .{});

    try std.testing.expectEqualStrings("\x02", resolved.terminal_input);
}

test "resolver maps text and escape sequence terminal macros to terminal bytes" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{
        .terminal_bindings = &.{
            .{ .chord = try KeyChord.parse("Ctrl+Up"), .input = .{ .send_escape_sequence = "\x1b[1;5A" } },
            .{ .chord = try KeyChord.parse("Cmd+1"), .input = .{ .send_text = "one" } },
        },
    };
    try resolver.validate();

    try std.testing.expectEqualStrings(
        "\x1b[1;5A",
        (try resolver.resolve(.{ .key = .arrow_up, .modifiers = .{ .control = true } }, &buffer, .{})).terminal_input,
    );
    try std.testing.expectEqualStrings(
        "one",
        (try resolver.resolve(.{ .key = .{ .char = '1' }, .modifiers = .{ .command = true } }, &buffer, .{})).terminal_input,
    );
}

test "resolver leaves ordinary terminal keys alone and ignores unbound command keys" {
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver: KeyBindingResolver = .{};

    try std.testing.expectEqualStrings(
        "\x02",
        (try resolver.resolve(.{
            .key = .{ .char = 'b' },
            .modifiers = .{ .control = true },
        }, &buffer, .{})).terminal_input,
    );
    try std.testing.expectEqualStrings(
        "b",
        (try resolver.resolve(.{ .key = .{ .char = 'b' } }, &buffer, .{})).terminal_input,
    );
    try std.testing.expectEqual(
        ResolvedKey.ignored,
        try resolver.resolve(.{
            .key = .{ .char = unbound_command_char }, // 계산해서 고른다(위 헬퍼 주석)
            .modifiers = .{ .command = true },
        }, &buffer, .{}),
    );
}

test "keybind: function/editing keys parse and match real terminal key events" {
    // 설정 표기 파싱
    try std.testing.expect((try KeyChord.parse("Delete")).key.eql(.delete));
    try std.testing.expect((try KeyChord.parse("Home")).key.eql(.home));
    try std.testing.expect((try KeyChord.parse("PageUp")).key.eql(.page_up));
    try std.testing.expect((try KeyChord.parse("Cmd+F5")).key.eql(.{ .function = 5 }));
    // 이제 실제 terminal.Key 이벤트와 매칭된다(이전엔 죽은 설정).
    var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolver = KeyBindingResolver{ .app_bindings = &.{
        .{ .chord = .{ .key = .delete }, .action = .close_tab },
        .{ .chord = .{ .key = .{ .function = 5 } }, .action = .new_tab },
    } };
    const r1 = try resolver.resolve(.{ .key = .delete }, &buf, .{});
    try std.testing.expectEqual(action_mod.Action.close_tab, r1.app_action);
    const r2 = try resolver.resolve(.{ .key = .{ .function = 5 } }, &buf, .{});
    try std.testing.expectEqual(action_mod.Action.new_tab, r2.app_action);
}

test "resolve: built-in macOS line-editing bindings (Cmd/Option) override the ignore-Cmd fallthrough" {
    var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const r = KeyBindingResolver{}; // 사용자 바인딩 없음 — 빌트인만
    // Cmd 편집 조합 → 셸 시퀀스(예전엔 .ignored로 새던 것).
    try std.testing.expectEqualStrings("\x15", (try r.resolve(.{ .key = .backspace, .modifiers = .{ .command = true } }, &buf, .{})).terminal_input);
    try std.testing.expectEqualStrings("\x01", (try r.resolve(.{ .key = .arrow_left, .modifiers = .{ .command = true } }, &buf, .{})).terminal_input);
    try std.testing.expectEqualStrings("\x05", (try r.resolve(.{ .key = .arrow_right, .modifiers = .{ .command = true } }, &buf, .{})).terminal_input);
    // Option 단어 이동.
    try std.testing.expectEqualStrings("\x1bb", (try r.resolve(.{ .key = .arrow_left, .modifiers = .{ .option = true } }, &buf, .{})).terminal_input);
    try std.testing.expectEqualStrings("\x1bf", (try r.resolve(.{ .key = .arrow_right, .modifiers = .{ .option = true } }, &buf, .{})).terminal_input);
    // 안 묶인 다른 Cmd 조합은 그대로 .ignored(글자는 계산해서 고른다 — `unboundCommandChar`).
    try std.testing.expectEqual(ResolvedKey.ignored, try r.resolve(.{ .key = .{ .char = unbound_command_char }, .modifiers = .{ .command = true } }, &buf, .{}));
    // 정확한 modifier만 — Cmd+Shift+Backspace는 빌트인 매칭 안 되고 .ignored.
    try std.testing.expectEqual(ResolvedKey.ignored, try r.resolve(.{ .key = .backspace, .modifiers = .{ .command = true, .shift = true } }, &buf, .{}));
    // Option+Backspace는 encodeKey의 meta-ESC(\x1b\x7f)로 — 빌트인 아님.
    try std.testing.expectEqualStrings("\x1b\x7f", (try r.resolve(.{ .key = .backspace, .modifiers = .{ .option = true } }, &buf, .{})).terminal_input);
}

test "resolve: user terminal binding overrides a built-in default" {
    var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const user = [_]TerminalBinding{
        .{ .chord = .{ .modifiers = .{ .command = true }, .key = .backspace }, .input = .{ .send_text = "X" } },
    };
    const r = KeyBindingResolver{ .terminal_bindings = &user };
    // 사용자 바인딩이 빌트인보다 우선.
    try std.testing.expectEqualStrings("X", (try r.resolve(.{ .key = .backspace, .modifiers = .{ .command = true } }, &buf, .{})).terminal_input);
}
