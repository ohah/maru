//! config 파일 로더 — `key = value` 텍스트(Ghostty식, `#` 주석)를 raw `theme.Config`로 파싱한다.
//!
//! 설계 원칙:
//! - **순수 parser**(`parse`)와 I/O 래퍼(`loadFile`)를 분리해, 파싱 규칙은 파일시스템 없이
//!   단위 테스트로 고정한다(Linux CI 포함).
//! - **forgiving**: 알 수 없는 key, 잘못된 값, `=` 누락은 *치명적이지 않다*. 해당 필드는 기본값을
//!   쓰고 diagnostic(줄 번호 + 메시지)으로 남긴다. 한 줄 오타가 전체 설정을 깨지 않는다 — 사용자가
//!   "Maru가 망가졌다"고 느끼지 않게. 치명적 오류는 메모리 부족뿐이다.
//! - **값 검증 재사용**: 색은 `appearance.parseHexColor`, 크기 범위/family 비어있음 검사를 그대로
//!   써서, resolve가 다시 실패하지 않도록 *valid 아니면 default*만 Config에 담는다.
//! - **소유권**: 문자열 값(font.family)은 arena에 복사한다. resolve가 family 슬라이스를 빌리므로,
//!   Parsed(arena)는 그걸로 만든 ResolvedAppearance보다 오래 살아야 한다(호출자가 보관).

const std = @import("std");
const theme = @import("theme.zig");
const appearance = @import("appearance.zig");
const keybinding = @import("keybinding.zig");
const action_mod = @import("action.zig");
const terminal = @import("../terminal.zig");

pub const LoadError = std.mem.Allocator.Error;

/// 비치명 진단 — 어느 줄에서 무엇이 무시됐는지. 메시지는 arena 소유.
pub const Diagnostic = struct {
    line: usize,
    message: []const u8,
};

/// 파싱 결과. arena가 config의 문자열·키바인딩 slice·diagnostic 메시지를 소유한다 — config를 쓰는
/// 동안(특히 resolve가 family를, KeyBindingResolver가 keybindings를 빌리는 동안) 살아 있어야 한다.
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    config: theme.Config,
    /// 사용자 정의 app 키바인딩(`keybind = <chord> = <action>`). chord 중복은 파싱 단계에서
    /// 걸러져(첫 줄 우선) 그대로 KeyBindingResolver.app_bindings로 넣어도 validate가 통과한다.
    keybindings: []const keybinding.AppBinding,
    /// 사용자가 끈 빌트인 기본 바인딩의 chord(`keybind = <chord> = unbind`). resolve가 이 chord에서
    /// 빌트인 테이블을 건너뛴다. keybindings와 같은 dedup 풀(chord별 한 줄)이라 둘이 겹치지 않는다.
    unbinds: []const keybinding.KeyChord,
    /// 사용자 정의 terminal 키바인딩(`keybind = <chord> = text:|esc:|ctrl:<payload>`) — 키에 셸로 보낼
    /// 바이트(매크로)를 묶는다. app 바인딩·unbind와 같은 dedup 풀이라 chord가 충돌하지 않아 그대로
    /// KeyBindingResolver.terminal_bindings로 넣어도 validate(app↔terminal 충돌 검사)가 통과한다.
    terminal_bindings: []const keybinding.TerminalBinding,
    /// 전역(OS) 단축키 바인딩(`keybind = global:<chord> = toggle_window|show_window`). OS 레벨에 등록되어
    /// 앱이 비활성이어도 동작한다 — in-app resolver를 안 거치고 별도 네임스페이스다(자기들끼리만 dedup).
    /// 플랫폼(Swift)이 이 목록을 읽어 RegisterEventHotKey로 등록한다(a2). chord→가상 키코드 매핑은 platform.
    global_bindings: []const keybinding.GlobalBinding,
    diagnostics: []const Diagnostic,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }

    /// 파싱된 키바인딩으로 resolver를 만든다(app 바인딩 + unbind + terminal 매크로).
    pub fn keyBindingResolver(self: Parsed) keybinding.KeyBindingResolver {
        return .{
            .app_bindings = self.keybindings,
            .terminal_bindings = self.terminal_bindings,
            .unbinds = self.unbinds,
        };
    }
};

const max_font_size: f32 = 512.0;
const min_font_size: f32 = 1.0;
// font.size-step 허용 범위 — theme.zig가 단일 출처(resolveFont도 같은 const를 써 drift 없음).
const max_font_step: f32 = theme.font_size_step_max;
const min_font_step: f32 = theme.font_size_step_min;
// font.line-height / font.letter-spacing 허용 범위 — theme.zig 단일 출처(resolveFont도 같은 const 공유, drift 없음).
const max_line_height: f32 = theme.font_line_height_max;
const min_line_height: f32 = theme.font_line_height_min;
const max_letter_spacing: f32 = theme.font_letter_spacing_max;
const min_letter_spacing: f32 = theme.font_letter_spacing_min;

/// config 텍스트를 raw Config로 파싱한다(파일시스템 무관, 순수). 알 수 없는 key/잘못된 값은
/// 기본값 유지 + diagnostic. OOM만 에러.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) LoadError!Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var config: theme.Config = .{};
    var diags: std.ArrayList(Diagnostic) = .empty;
    var binds: std.ArrayList(keybinding.AppBinding) = .empty;
    var unbinds: std.ArrayList(keybinding.KeyChord) = .empty;
    var term_binds: std.ArrayList(keybinding.TerminalBinding) = .empty;
    var global_binds: std.ArrayList(keybinding.GlobalBinding) = .empty;

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue; // 빈 줄 / 주석

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            try diags.append(a, .{ .line = line_no, .message = "'=' 없음 — `key = value` 형식이어야 한다" });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], &std.ascii.whitespace);
        const value = std.mem.trim(u8, line[eq + 1 ..], &std.ascii.whitespace);

        try applyKey(a, &config, &binds, &unbinds, &term_binds, &global_binds, &diags, line_no, key, value);
    }

    return .{
        .arena = arena,
        .config = config,
        .keybindings = try binds.toOwnedSlice(a),
        .unbinds = try unbinds.toOwnedSlice(a),
        .terminal_bindings = try term_binds.toOwnedSlice(a),
        .global_bindings = try global_binds.toOwnedSlice(a),
        .diagnostics = try diags.toOwnedSlice(a),
    };
}

fn applyKey(
    a: std.mem.Allocator,
    config: *theme.Config,
    binds: *std.ArrayList(keybinding.AppBinding),
    unbinds: *std.ArrayList(keybinding.KeyChord),
    term_binds: *std.ArrayList(keybinding.TerminalBinding),
    global_binds: *std.ArrayList(keybinding.GlobalBinding),
    diags: *std.ArrayList(Diagnostic),
    line_no: usize,
    key: []const u8,
    value: []const u8,
) LoadError!void {
    if (std.mem.eql(u8, key, "keybind")) {
        return applyKeybind(a, binds, unbinds, term_binds, global_binds, diags, line_no, value);
    }
    if (std.mem.eql(u8, key, "font.family")) {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            try diags.append(a, .{ .line = line_no, .message = "font.family가 비어 있음 — 기본값 유지" });
            return;
        }
        config.font.family = try a.dupe(u8, trimmed);
    } else if (std.mem.eql(u8, key, "font.size")) {
        config.font.size = parseFloatInRange(value, min_font_size, max_font_size) orelse {
            try diags.append(a, .{ .line = line_no, .message = "font.size가 1~512 범위 밖이거나 숫자가 아님 — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "font.size-step")) {
        config.font.size_step = parseFloatInRange(value, min_font_step, max_font_step) orelse {
            try diags.append(a, .{ .line = line_no, .message = "font.size-step이 0.1~32 범위 밖이거나 숫자가 아님 — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "font.line-height")) {
        config.font.line_height = parseFloatInRange(value, min_line_height, max_line_height) orelse {
            try diags.append(a, .{ .line = line_no, .message = "font.line-height가 0.5~3.0 범위 밖이거나 숫자가 아님 — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "font.letter-spacing")) {
        // min을 음수로 줘 칸 좁힘을 허용한다(NaN은 parseFloatInRange가 범위검사로 함께 거부).
        config.font.letter_spacing = parseFloatInRange(value, min_letter_spacing, max_letter_spacing) orelse {
            try diags.append(a, .{ .line = line_no, .message = "font.letter-spacing이 -8~32 범위 밖이거나 숫자가 아님 — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "theme.preset")) {
        // 이름 붙은 컬러 테마(프리셋). config.theme를 통째로 그 색 세트로 깐다(theme.presetColors가 단일 출처).
        // 개별 theme.* 키가 이 줄 *뒤에* 오면 그 색만 override한다(loader 순차 적용 — 나중 줄 우선). 프리셋 색은
        // 정적 리터럴이라 arena dupe 불필요. 알 수 없는 값은 forgiving(기본 maru 유지 + diagnostic).
        const preset = parseThemePreset(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "theme.preset은 maru|ghostty|gruvbox-dark|solarized-dark|solarized-light|dracula|catppuccin-mocha|catppuccin-latte — 기본값 유지" });
            return;
        };
        config.theme = theme.presetColors(preset);
    } else if (std.mem.eql(u8, key, "theme.background")) {
        config.theme.background = try dupValidColor(a, diags, line_no, key, value, config.theme.background);
    } else if (std.mem.eql(u8, key, "theme.foreground")) {
        config.theme.foreground = try dupValidColor(a, diags, line_no, key, value, config.theme.foreground);
    } else if (std.mem.eql(u8, key, "theme.cursor")) {
        config.theme.cursor = try dupValidColor(a, diags, line_no, key, value, config.theme.cursor);
    } else if (std.mem.eql(u8, key, "theme.selection")) {
        config.theme.selection = try dupValidColor(a, diags, line_no, key, value, config.theme.selection);
    } else if (std.mem.startsWith(u8, key, "theme.palette.")) {
        // ANSI 16색 override: theme.palette.0~.15 = #RRGGBB. suffix를 u8로 파싱해 0~15 범위 검사. 인덱스가 비정수·
        // 범위 밖이면 forgiving(diagnostic + 무시), 색은 dupValidColor가 검증(틀린 색도 forgiving). OSC4가 없을 때의
        // base라 per-core OSC4 표가 아니라 config에 둔다(렌더 폴백이 OSC4 → config → xterm256 우선순위로 쓴다).
        const suffix = key["theme.palette.".len..];
        const idx = std.fmt.parseInt(u8, suffix, 10) catch {
            try diags.append(a, .{ .line = line_no, .message = "theme.palette.N의 N은 0~15 정수여야 함 — 무시" });
            return;
        };
        if (idx > 15) {
            try diags.append(a, .{ .line = line_no, .message = "theme.palette.N의 N은 0~15 범위 — 무시" });
            return;
        }
        // 색 검증·arena dupe·diagnostic은 dupValidColor 재사용(단일 출처). 슬롯은 ?[]const u8라 sentinel ""을
        // current로 넘긴다 — 틀린 색이면 dupValidColor가 ""(diagnostic 후)를 돌려주므로 그때만 슬롯을 안 건드려
        // 기존(보통 null) 값을 유지한다(forgiving). 유효하면 dupe된 색으로 갱신.
        const validated = try dupValidColor(a, diags, line_no, key, value, "");
        if (validated.len != 0) config.theme.palette[idx] = validated;
    } else if (std.mem.eql(u8, key, "cursor.shape")) {
        config.cursor.shape = parseCursorShape(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "cursor.shape는 block|bar|underline — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "cursor.blink")) {
        config.cursor.blink = parseBool(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "cursor.blink는 true|false — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "input.page-keys")) {
        config.input.page_keys = parsePageKeys(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "input.page-keys는 passthrough|scroll — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "input.shift-enter")) {
        config.input.shift_enter = parseShiftEnter(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "input.shift-enter는 newline|native — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "input.ime-enter")) {
        config.input.ime_enter = parseImeEnter(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "input.ime-enter는 newline|commit-only — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "quick-terminal.height")) {
        config.quick_terminal.height_fraction = parseFloatInRange(value, 0.1, 1.0) orelse {
            try diags.append(a, .{ .line = line_no, .message = "quick-terminal.height는 0.1~1.0(예: 0.45) — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "quick-terminal.width")) {
        config.quick_terminal.width_fraction = parseFloatInRange(value, 0.1, 1.0) orelse {
            try diags.append(a, .{ .line = line_no, .message = "quick-terminal.width는 0.1~1.0(예: 0.6) — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "quick-terminal.auto-hide")) {
        config.quick_terminal.auto_hide = parseBool(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "quick-terminal.auto-hide는 true|false — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "quick-terminal.screen")) {
        config.quick_terminal.screen = parseQuickTerminalScreen(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "quick-terminal.screen은 main|mouse — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "quick-terminal.position")) {
        config.quick_terminal.position = parseQuickTerminalPosition(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "quick-terminal.position은 top|bottom|left|right|center — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "quick-terminal.chrome")) {
        config.quick_terminal.chrome = parseQuickTerminalChrome(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "quick-terminal.chrome은 full|minimal — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "quick-terminal.minimal-tabs")) {
        config.quick_terminal.minimal_tabs = parseBool(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "quick-terminal.minimal-tabs는 true|false — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "chrome.theme")) {
        config.chrome_theme = if (std.mem.eql(u8, value, "rich")) .rich else if (std.mem.eql(u8, value, "tui")) .tui else {
            try diags.append(a, .{ .line = line_no, .message = "chrome.theme은 tui|rich — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "sidebar.show-branch")) {
        config.sidebar.show_branch = parseBool(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "sidebar.show-branch는 true|false — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "sidebar.show-folder")) {
        config.sidebar.show_folder = parseBool(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "sidebar.show-folder는 true|false — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "text.blink")) {
        config.blink_text = parseBool(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "text.blink은 true|false — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "notifications.agent-complete")) {
        config.notifications.agent_complete = parseBool(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "notifications.agent-complete는 true|false — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "scrollback.lines")) {
        config.scrollback.lines = parseUintMax(value, 100000) orelse {
            try diags.append(a, .{ .line = line_no, .message = "scrollback.lines는 0~100000 정수 — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "bell.audible")) {
        config.bell.audible = parseBool(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "bell.audible은 true|false — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "window.padding-top")) {
        config.window_padding_top = parseUintMax(value, 256) orelse {
            try diags.append(a, .{ .line = line_no, .message = "window.padding-top은 0~256 정수 — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "window.padding-bottom")) {
        config.window_padding_bottom = parseUintMax(value, 256) orelse {
            try diags.append(a, .{ .line = line_no, .message = "window.padding-bottom은 0~256 정수 — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "window.padding-left")) {
        config.window_padding_left = parseUintMax(value, 256) orelse {
            try diags.append(a, .{ .line = line_no, .message = "window.padding-left는 0~256 정수 — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "window.padding-right")) {
        config.window_padding_right = parseUintMax(value, 256) orelse {
            try diags.append(a, .{ .line = line_no, .message = "window.padding-right는 0~256 정수 — 기본값 유지" });
            return;
        };
    } else if (std.mem.eql(u8, key, "window.padding-x")) {
        // x는 left+right 동시 alias(대칭 좌우 여백). 한 번 파싱해 두 필드에 같은 값. 명시 left/right와 혼용 시
        // loader가 줄을 순차 적용하므로 "마지막 줄 우선"이 자동(padding-x=10 다음 padding-left=20 → left=20,right=10).
        const v = parseUintMax(value, 256) orelse {
            try diags.append(a, .{ .line = line_no, .message = "window.padding-x는 0~256 정수 — 기본값 유지" });
            return;
        };
        config.window_padding_left = v;
        config.window_padding_right = v;
    } else if (std.mem.eql(u8, key, "window.padding-y")) {
        // y는 top+bottom 동시 alias(대칭 상하 여백). x와 동일하게 순차 적용 → 마지막 줄 우선.
        const v = parseUintMax(value, 256) orelse {
            try diags.append(a, .{ .line = line_no, .message = "window.padding-y는 0~256 정수 — 기본값 유지" });
            return;
        };
        config.window_padding_top = v;
        config.window_padding_bottom = v;
    } else if (std.mem.eql(u8, key, "term")) {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            try diags.append(a, .{ .line = line_no, .message = "term이 비어 있음 — 기본값 유지" });
            return;
        }
        config.term = try a.dupe(u8, trimmed);
    } else if (std.mem.eql(u8, key, "shell-integration.ssh")) {
        config.shell_integration.ssh = parseBool(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "shell-integration.ssh는 true|false — 기본값 유지" });
            return;
        };
    } else {
        try diags.append(a, .{ .line = line_no, .message = "알 수 없는 key — 무시" });
    }
}

fn parseQuickTerminalScreen(value: []const u8) ?theme.QuickTerminalScreen {
    if (std.mem.eql(u8, value, "main")) return .main;
    if (std.mem.eql(u8, value, "mouse")) return .mouse;
    return null;
}

fn parseQuickTerminalPosition(value: []const u8) ?theme.QuickTerminalPosition {
    if (std.mem.eql(u8, value, "top")) return .top;
    if (std.mem.eql(u8, value, "bottom")) return .bottom;
    if (std.mem.eql(u8, value, "left")) return .left;
    if (std.mem.eql(u8, value, "right")) return .right;
    if (std.mem.eql(u8, value, "center")) return .center;
    return null;
}

fn parseQuickTerminalChrome(value: []const u8) ?theme.QuickTerminalChrome {
    if (std.mem.eql(u8, value, "full")) return .full;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    return null;
}

fn parsePageKeys(value: []const u8) ?theme.PageKeys {
    if (std.mem.eql(u8, value, "passthrough")) return .passthrough;
    if (std.mem.eql(u8, value, "scroll")) return .scroll;
    return null;
}

fn parseShiftEnter(value: []const u8) ?theme.ShiftEnter {
    if (std.mem.eql(u8, value, "newline")) return .newline;
    if (std.mem.eql(u8, value, "native")) return .native;
    return null;
}

fn parseImeEnter(value: []const u8) ?theme.ImeEnter {
    if (std.mem.eql(u8, value, "newline")) return .newline;
    if (std.mem.eql(u8, value, "commit-only")) return .commit_only;
    return null;
}

/// `keybind = <chord> = <rhs>` 한 줄을 처리한다. chord에 `global:` 접두사가 있으면 전역(OS) 단축키이고
/// rhs는 GlobalAction(toggle_window/show_window)이다(별도 네임스페이스 — 자기들끼리만 dedup). 접두사가
/// 없으면 in-app 바인딩이고 rhs는 셋 중 하나다:
///   - `unbind` → 그 chord의 빌트인 기본을 끈다(unbinds).
///   - `text:`/`esc:`/`ctrl:` 매크로 → 키에 셸로 보낼 바이트를 묶는다(terminal_bindings).
///   - 그 외 → app action(parseAction → keybindings).
/// chord는 KeyChord.parse(사람 표기 — 예 `Cmd+T`). 오류는 diagnostic(forgiving). 같은 chord가 이미
/// (bind/unbind/terminal 어디든) 있으면 첫 줄을 살리고 무시한다 — chord별 한 줄이라 resolver가 모순 없이
/// 본다(app 우선 → terminal → unbind로 빌트인 끄기). 세 풀을 한 dedup로 묶어 app↔terminal 충돌도 막는다.
fn applyKeybind(
    a: std.mem.Allocator,
    binds: *std.ArrayList(keybinding.AppBinding),
    unbinds: *std.ArrayList(keybinding.KeyChord),
    term_binds: *std.ArrayList(keybinding.TerminalBinding),
    global_binds: *std.ArrayList(keybinding.GlobalBinding),
    diags: *std.ArrayList(Diagnostic),
    line_no: usize,
    value: []const u8,
) LoadError!void {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse {
        try diags.append(a, .{ .line = line_no, .message = "keybind는 `<조합> = <action>` 형식이어야 한다" });
        return;
    };
    const chord_str = std.mem.trim(u8, value[0..eq], &std.ascii.whitespace);
    const rhs = std.mem.trim(u8, value[eq + 1 ..], &std.ascii.whitespace);

    // `global:` 접두사 → 전역(OS) 단축키. 접두사를 떼고 chord를 파싱한 뒤 GlobalAction으로 처리한다.
    if (std.mem.startsWith(u8, chord_str, "global:")) {
        return applyGlobalKeybind(a, global_binds, diags, line_no, std.mem.trim(u8, chord_str["global:".len..], &std.ascii.whitespace), rhs);
    }

    const chord = keybinding.KeyChord.parse(chord_str) catch {
        try diags.append(a, .{ .line = line_no, .message = "키 조합을 못 읽음(예: Cmd+T, Ctrl+Cmd+1) — 무시" });
        return;
    };
    // chord는 bind/unbind/terminal을 통틀어 한 번만(첫 줄 우선). 세 풀을 함께 검사해 같은 chord가
    // 갈라지지 않게 한다(app↔terminal 충돌도 여기서 막아 resolver.validate가 통과한다).
    if (chordAlreadyBound(binds.items, unbinds.items, term_binds.items, chord)) {
        try diags.append(a, .{ .line = line_no, .message = "이미 바인딩된 키 조합 — 무시(첫 줄 우선)" });
        return;
    }

    // rhs가 `unbind`면 그 chord의 빌트인 기본을 끈다(app action 아님 — 별도 목록).
    if (std.mem.eql(u8, rhs, "unbind")) {
        try unbinds.append(a, chord);
        return;
    }

    // rhs가 터미널 매크로(text:/esc:/ctrl:)면 셸로 보낼 바이트를 묶는다. `.invalid`(접두사인데 payload
    // 오류)는 parseTerminalMacro가 이미 diagnostic을 남겼고, app action으로 재해석하지 않고 그 줄을 버린다.
    switch (try parseTerminalMacro(a, diags, line_no, rhs)) {
        .macro => |macro| {
            try term_binds.append(a, .{ .chord = chord, .input = macro });
            return;
        },
        .invalid => return,
        .not_macro => {}, // 접두사 아님 — 아래 app action으로
    }

    const act = action_mod.parseAction(rhs) orelse {
        try diags.append(a, .{ .line = line_no, .message = "알 수 없는 action(unbind/text:/esc:/ctrl:/new_tab/close_tab/select_tab:N 등) — 무시" });
        return;
    };
    try binds.append(a, .{ .chord = chord, .action = act });
}

/// `keybind = global:<chord> = <global action>` 한 줄을 GlobalBinding으로. chord_str은 `global:` 접두사를
/// 이미 뗀 상태다. action은 toggle_window/show_window만. 전역 chord끼리만 dedup한다(in-app과 별도
/// 네임스페이스 — OS 핫키라 같은 조합이 in-app에도 있을 수 있고 충돌이 아니다). 오류는 diagnostic(forgiving).
fn applyGlobalKeybind(
    a: std.mem.Allocator,
    global_binds: *std.ArrayList(keybinding.GlobalBinding),
    diags: *std.ArrayList(Diagnostic),
    line_no: usize,
    chord_str: []const u8,
    rhs: []const u8,
) LoadError!void {
    const chord = keybinding.KeyChord.parse(chord_str) catch {
        try diags.append(a, .{ .line = line_no, .message = "전역 키 조합을 못 읽음(예: global:Cmd+Opt+Space) — 무시" });
        return;
    };
    const act = action_mod.parseGlobalAction(rhs) orelse {
        try diags.append(a, .{ .line = line_no, .message = "알 수 없는 전역 action(toggle_window/show_window) — 무시" });
        return;
    };
    for (global_binds.items) |existing| {
        if (existing.chord.eql(chord)) {
            try diags.append(a, .{ .line = line_no, .message = "이미 등록된 전역 키 조합 — 무시(첫 줄 우선)" });
            return;
        }
    }
    try global_binds.append(a, .{ .chord = chord, .action = act });
}

/// chord가 이미 묶였는가(bind/unbind/terminal 세 풀 통틀어). keybind dedup의 단일 출처 — 셋 중 한 곳에만
/// 들어가게 해 app↔terminal 충돌·중복을 파싱 단계에서 막는다(첫 줄 우선). 순수 함수.
fn chordAlreadyBound(
    binds: []const keybinding.AppBinding,
    unbinds: []const keybinding.KeyChord,
    term_binds: []const keybinding.TerminalBinding,
    chord: keybinding.KeyChord,
) bool {
    for (binds) |b| if (b.chord.eql(chord)) return true;
    for (unbinds) |c| if (c.eql(chord)) return true;
    for (term_binds) |b| if (b.chord.eql(chord)) return true;
    return false;
}

/// parseTerminalMacro의 3-상태 결과 — 접두사 여부와 파싱 성공을 한 번에 표현해 호출자가 매크로 접두사
/// 목록을 다시 안 봐도 되게 한다(접두사 목록은 parseTerminalMacro 한 곳이 단일 출처).
const MacroParse = union(enum) {
    not_macro, // text:/esc:/ctrl: 접두사가 아님 — app action으로 시도하라.
    invalid, // 접두사인데 payload 오류(diagnostic 이미 남김) — 그 줄을 버려라(app action 재해석 금지).
    macro: keybinding.TerminalInputMacro,
};

/// 터미널 매크로 rhs를 파싱한다.
///   - `text:<문자열>`  → send_text(payload 그대로 셸로).
///   - `esc:<payload>`  → send_escape_sequence("\x1b" + payload — ESC를 앞에 붙인 시퀀스. 예 `esc:[2J`).
///   - `ctrl:<글자한자>` → send_control(그 글자의 C0 컨트롤 바이트. 예 `ctrl:[` = ESC).
/// payload(text/esc)는 arena에 복사해 binding이 소유한다(Parsed가 사는 동안 유효). 빈 payload·여러 글자
/// ctrl·C0 매핑 없는 ctrl은 diagnostic + `.invalid`(forgiving). 접두사가 아니면 `.not_macro`.
fn parseTerminalMacro(
    a: std.mem.Allocator,
    diags: *std.ArrayList(Diagnostic),
    line_no: usize,
    rhs: []const u8,
) LoadError!MacroParse {
    if (std.mem.startsWith(u8, rhs, "text:")) {
        const payload = rhs["text:".len..];
        if (payload.len == 0) {
            try diags.append(a, .{ .line = line_no, .message = "text: 뒤 내용이 비어 있음 — 무시" });
            return .invalid;
        }
        return .{ .macro = .{ .send_text = try a.dupe(u8, payload) } };
    }
    if (std.mem.startsWith(u8, rhs, "esc:")) {
        const payload = rhs["esc:".len..];
        if (payload.len == 0) {
            try diags.append(a, .{ .line = line_no, .message = "esc: 뒤 내용이 비어 있음 — 무시" });
            return .invalid;
        }
        // ESC(0x1b)를 앞에 붙인 시퀀스. 예 `esc:[2J` → "\x1b[2J"(화면 지우기).
        const seq = try std.fmt.allocPrint(a, "\x1b{s}", .{payload});
        return .{ .macro = .{ .send_escape_sequence = seq } };
    }
    if (std.mem.startsWith(u8, rhs, "ctrl:")) {
        const payload = rhs["ctrl:".len..];
        // 정확히 한 codepoint여야 한다(Ctrl+<글자>). UTF-8 한 글자 길이와 payload 길이가 같아야 통과.
        const seq_len = std.unicode.utf8ByteSequenceLength(if (payload.len > 0) payload[0] else 0) catch {
            try diags.append(a, .{ .line = line_no, .message = "ctrl: 뒤는 글자 한 자여야 함 — 무시" });
            return .invalid;
        };
        if (payload.len != seq_len) {
            try diags.append(a, .{ .line = line_no, .message = "ctrl: 뒤는 글자 한 자여야 함 — 무시" });
            return .invalid;
        }
        const cp = std.unicode.utf8Decode(payload) catch {
            try diags.append(a, .{ .line = line_no, .message = "ctrl: 글자를 못 읽음 — 무시" });
            return .invalid;
        };
        // C0 컨트롤로 매핑되는 글자만(@A-Z[\]^_ space ?). 로드 시 걸러야 키 누를 때 resolve가 안 터진다.
        _ = terminal.input.controlByte(cp) catch {
            try diags.append(a, .{ .line = line_no, .message = "ctrl: 글자가 컨트롤 문자로 매핑 안 됨(@,A~Z,[,\\,],^,_,Space,? 가능) — 무시" });
            return .invalid;
        };
        return .{ .macro = .{ .send_control = cp } };
    }
    return .not_macro;
}

/// 색 문자열을 appearance.parseHexColor로 검증(값 의미 단일 출처)한 뒤 arena에 복사해 돌려준다.
/// 형식이 틀리면 diagnostic + 기존(기본) 값을 유지한다.
fn dupValidColor(
    a: std.mem.Allocator,
    diags: *std.ArrayList(Diagnostic),
    line_no: usize,
    key: []const u8,
    value: []const u8,
    current: []const u8,
) LoadError![]const u8 {
    _ = key;
    _ = appearance.parseHexColor(value) catch {
        try diags.append(a, .{ .line = line_no, .message = "색이 #RRGGBB 형식이 아님 — 기본값 유지" });
        return current;
    };
    return try a.dupe(u8, value);
}

fn parseCursorShape(value: []const u8) ?theme.CursorShape {
    if (std.mem.eql(u8, value, "block")) return .block;
    if (std.mem.eql(u8, value, "bar")) return .bar;
    if (std.mem.eql(u8, value, "underline")) return .underline;
    return null;
}

fn parseThemePreset(value: []const u8) ?theme.ThemePreset {
    if (std.mem.eql(u8, value, "maru")) return .maru;
    if (std.mem.eql(u8, value, "ghostty")) return .ghostty;
    if (std.mem.eql(u8, value, "gruvbox-dark")) return .gruvbox_dark;
    if (std.mem.eql(u8, value, "solarized-dark")) return .solarized_dark;
    if (std.mem.eql(u8, value, "solarized-light")) return .solarized_light;
    if (std.mem.eql(u8, value, "dracula")) return .dracula;
    if (std.mem.eql(u8, value, "catppuccin-mocha")) return .catppuccin_mocha;
    if (std.mem.eql(u8, value, "catppuccin-latte")) return .catppuccin_latte;
    return null;
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

/// 음이 아닌 정수를 [0, max]로 파싱한다 — 음수/비정수/max 초과는 null(기본값 유지). 0은 유효.
/// padding(max=256: grid를 0으로 만드는 비정상 큰 값 가드)·scrollback(max=100000: 행당 ptr 슬롯 ring
/// 메모리 폭주 가드)이 같은 forgiving 패턴을 공유한다.
fn parseUintMax(value: []const u8, max: u32) ?u32 {
    const n = std.fmt.parseInt(u32, std.mem.trim(u8, value, &std.ascii.whitespace), 10) catch return null;
    return if (n <= max) n else null;
}

/// 실수를 [min, max]로 파싱한다 — 비실수는 null. 범위 검사는 `!(>=min and <=max)`로 NaN까지 함께
/// 거부한다(NaN은 두 비교가 모두 false라 항상 reject). font 크기/스텝/줄높이/자간·quick-terminal 비율이
/// 같은 forgiving 패턴을 공유한다(letter-spacing은 음수 허용 — min을 음수로 줘 호출처가 정한다).
fn parseFloatInRange(value: []const u8, min: f32, max: f32) ?f32 {
    const n = std.fmt.parseFloat(f32, value) catch return null;
    return if (n >= min and n <= max) n else null;
}

/// config 한 줄을 갱신할 키·값 쌍. value는 이미 직렬화된 토큰(`true`/`false` 등).
pub const KeyValue = struct { key: []const u8, value: []const u8 };

/// 원본 config 텍스트를 줄 단위로 순회해 `updates`의 키를 `key = value`로 **in-place 교체**한다 —
/// 주석·빈 줄·미파싱 키·갱신 대상이 아닌 줄은 그대로 보존하고, 원본에 없던 키만 파일 끝에 append한다.
/// 앱(view options 토글)→config 부분 갱신용. 통째 재작성은 사용자 주석·미파싱 키를 전부 잃으므로 택하지
/// 않았다([document-basis-and-decision]: 보존을 우선). 교체 줄은 `key = value`로 정규화하므로 그 줄에
/// 달려 있던 인라인 주석/비표준 공백은 사라진다(round-trip 테스트가 보존 범위를 못박는다). 반환은 owned.
pub fn updateConfigText(allocator: std.mem.Allocator, original: []const u8, updates: []const KeyValue) LoadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const applied = try allocator.alloc(bool, updates.len);
    defer allocator.free(applied);
    @memset(applied, false);

    var it = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        const trimmed = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        var replaced = false;
        if (trimmed.len > 0 and trimmed[0] != '#') {
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const k = std.mem.trim(u8, trimmed[0..eq], &std.ascii.whitespace);
                for (updates, 0..) |u, i| {
                    if (!applied[i] and std.mem.eql(u8, k, u.key)) {
                        try out.appendSlice(allocator, u.key);
                        try out.appendSlice(allocator, " = ");
                        try out.appendSlice(allocator, u.value);
                        applied[i] = true;
                        replaced = true;
                        break;
                    }
                }
            }
        }
        if (!replaced) try out.appendSlice(allocator, raw_line);
    }
    // 원본에 없던 키는 끝에 append(직전 줄이 개행으로 안 끝나면 개행 먼저).
    for (updates, 0..) |u, i| {
        if (applied[i]) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
        try out.appendSlice(allocator, u.key);
        try out.appendSlice(allocator, " = ");
        try out.appendSlice(allocator, u.value);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// 빈 기본 결과(파일 없음/HOME 없음 등). config 텍스트를 안 읽었으므로 arena도 비어 있다.
fn emptyDefault(allocator: std.mem.Allocator) Parsed {
    return .{ .arena = std.heap.ArenaAllocator.init(allocator), .config = .{}, .keybindings = &.{}, .unbinds = &.{}, .terminal_bindings = &.{}, .global_bindings = &.{}, .diagnostics = &.{} };
}

/// 경로에서 config를 읽어 파싱한다. 파일이 없거나 읽기 실패면 기본 Config(빈 arena)를 돌려준다
/// (forgiving — 설정 파일이 없어도 터미널은 정상 동작해야 한다). OOM만 에러.
pub fn loadFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) LoadError!Parsed {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch {
        // 없음/권한/크기 초과 등 — 기본값으로 시작한다(빈 arena).
        return emptyDefault(allocator);
    };
    defer allocator.free(source);
    return parse(allocator, source);
}

/// 기본 config 경로(owned). `$MARU_CONFIG`가 있으면 그것을, 없으면 `$HOME/.config/maru/config`.
/// HOME이 없으면 null(설정 없이 기본값). Ghostty와 같은 위치/형식 관례.
pub fn defaultConfigPath(allocator: std.mem.Allocator) LoadError!?[]const u8 {
    if (std.c.getenv("MARU_CONFIG")) |override_z| {
        const override = std.mem.span(override_z);
        if (override.len > 0) return try allocator.dupe(u8, override);
    }
    const home_z = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_z);
    if (home.len == 0) return null;
    return try std.fmt.allocPrint(allocator, "{s}/.config/maru/config", .{home});
}

/// 기본 경로에서 config를 로드한다(경로 해석 + 파일 읽기 + 파싱). app session이 시작 시 호출하는
/// 단일 진입점. 경로/파일이 없으면 기본 Config. 호출자는 Parsed(arena)를 세션 동안 보관해야 한다
/// (resolve가 font.family 슬라이스를 빌린다).
pub fn loadDefault(io: std.Io, allocator: std.mem.Allocator) LoadError!Parsed {
    const path = (try defaultConfigPath(allocator)) orelse return emptyDefault(allocator);
    defer allocator.free(path);
    return loadFile(io, allocator, path);
}

test "parse: full config sets every field" {
    var p = try parse(std.testing.allocator,
        \\# Maru config
        \\font.family = JetBrains Mono
        \\font.size = 16
        \\font.size-step = 2
        \\font.line-height = 1.25
        \\font.letter-spacing = 1.5
        \\theme.background = #001122
        \\theme.foreground = #ffeedd
        \\cursor.shape = bar
        \\cursor.blink = false
        \\chrome.theme = rich
        \\sidebar.show-branch = false
        \\sidebar.show-folder = false
        \\text.blink = true
        \\input.shift-enter = native
        \\input.ime-enter = commit-only
        \\window.padding-x = 12
        \\window.padding-y = 6
        \\notifications.agent-complete = false
    );
    defer p.deinit();
    try std.testing.expectEqualStrings("JetBrains Mono", p.config.font.family);
    try std.testing.expectEqual(@as(f32, 16), p.config.font.size);
    try std.testing.expectEqual(@as(f32, 2), p.config.font.size_step); // font.size-step 파싱(기본 1)
    try std.testing.expectEqual(@as(f32, 1.25), p.config.font.line_height); // font.line-height 파싱(기본 1.0)
    try std.testing.expectEqual(@as(f32, 1.5), p.config.font.letter_spacing); // font.letter-spacing 파싱(기본 0.0)
    try std.testing.expectEqualStrings("#001122", p.config.theme.background);
    try std.testing.expectEqualStrings("#ffeedd", p.config.theme.foreground);
    try std.testing.expectEqual(theme.CursorShape.bar, p.config.cursor.shape);
    try std.testing.expectEqual(false, p.config.cursor.blink);
    try std.testing.expectEqual(theme.ChromeTheme.rich, p.config.chrome_theme); // C4a chrome.theme 파싱
    try std.testing.expectEqual(false, p.config.sidebar.show_branch); // sidebar.show-branch 파싱(기본 true)
    try std.testing.expectEqual(false, p.config.sidebar.show_folder); // sidebar.show-folder 파싱(기본 true)
    try std.testing.expectEqual(true, p.config.blink_text); // text.blink 파싱(기본 false)
    try std.testing.expectEqual(theme.ShiftEnter.native, p.config.input.shift_enter); // input.shift-enter 파싱(기본 newline)
    try std.testing.expectEqual(theme.ImeEnter.commit_only, p.config.input.ime_enter); // input.ime-enter 파싱(기본 newline)
    try std.testing.expectEqual(@as(u32, 12), p.config.window_padding_left); // window.padding-x alias → left+right
    try std.testing.expectEqual(@as(u32, 12), p.config.window_padding_right);
    try std.testing.expectEqual(@as(u32, 6), p.config.window_padding_top); // window.padding-y alias → top+bottom
    try std.testing.expectEqual(@as(u32, 6), p.config.window_padding_bottom);
    try std.testing.expectEqual(false, p.config.notifications.agent_complete); // notifications.agent-complete 파싱(기본 true)
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
}

test "updateConfigText: in-place 키 교체로 주석·다른 줄 보존, 없는 키는 append, round-trip" {
    const a = std.testing.allocator;
    const original =
        \\# 내 설정
        \\font.size = 16
        \\sidebar.show-branch = true
        \\theme.background = #001122
        \\
    ;
    const updates = [_]KeyValue{
        .{ .key = "sidebar.show-branch", .value = "false" }, // 기존 줄 교체
        .{ .key = "sidebar.show-folder", .value = "false" }, // 원본에 없음 → append
    };
    const updated = try updateConfigText(a, original, &updates);
    defer a.free(updated);
    // 주석·갱신 대상이 아닌 줄 보존
    try std.testing.expect(std.mem.indexOf(u8, updated, "# 내 설정") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "font.size = 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "theme.background = #001122") != null);
    // 기존 줄 in-place 교체(true→false), append
    try std.testing.expect(std.mem.indexOf(u8, updated, "sidebar.show-branch = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "sidebar.show-branch = true") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "sidebar.show-folder = false") != null);
    // round-trip: 갱신 텍스트를 다시 파싱하면 새 값
    var p = try parse(a, updated);
    defer p.deinit();
    try std.testing.expectEqual(false, p.config.sidebar.show_branch);
    try std.testing.expectEqual(false, p.config.sidebar.show_folder);
}

test "updateConfigText: 빈 원본에도 키를 append한다(파일 없음 케이스)" {
    const a = std.testing.allocator;
    const updates = [_]KeyValue{.{ .key = "sidebar.show-branch", .value = "false" }};
    const updated = try updateConfigText(a, "", &updates);
    defer a.free(updated);
    try std.testing.expectEqualStrings("sidebar.show-branch = false\n", updated);
}

test "parse: window padding defaults to left/right=8, top/bottom=4; bad/out-of-range values are forgiving" {
    // 키 없으면 기본 좌우 8·상하 4(사실상 표준 inset).
    var d = try parse(std.testing.allocator, "font.size = 14");
    defer d.deinit();
    try std.testing.expectEqual(@as(u32, 8), d.config.window_padding_left);
    try std.testing.expectEqual(@as(u32, 8), d.config.window_padding_right);
    try std.testing.expectEqual(@as(u32, 4), d.config.window_padding_top);
    try std.testing.expectEqual(@as(u32, 4), d.config.window_padding_bottom);
    // 0은 유효(셀이 가장자리에 붙음). 비정수·256 초과는 기본값 유지 + diagnostic.
    var p = try parse(std.testing.allocator,
        \\window.padding-x = 0
        \\window.padding-y = abc
        \\window.padding-x = 999
    );
    defer p.deinit();
    // 첫 줄 x=0 → left=right=0; 셋째 줄 x=999는 거부돼 0 유지(left·right 둘 다).
    try std.testing.expectEqual(@as(u32, 0), p.config.window_padding_left);
    try std.testing.expectEqual(@as(u32, 0), p.config.window_padding_right);
    // y=abc 거부 → 상하 기본 4 유지.
    try std.testing.expectEqual(@as(u32, 4), p.config.window_padding_top);
    try std.testing.expectEqual(@as(u32, 4), p.config.window_padding_bottom);
    try std.testing.expectEqual(@as(usize, 2), p.diagnostics.len); // abc + 999 두 건
}

test "parse: window padding 4-way individual keys (top/right/bottom/left)" {
    var p = try parse(std.testing.allocator,
        \\window.padding-top = 1
        \\window.padding-right = 2
        \\window.padding-bottom = 3
        \\window.padding-left = 4
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(u32, 1), p.config.window_padding_top);
    try std.testing.expectEqual(@as(u32, 2), p.config.window_padding_right);
    try std.testing.expectEqual(@as(u32, 3), p.config.window_padding_bottom);
    try std.testing.expectEqual(@as(u32, 4), p.config.window_padding_left);
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    // 개별 키 forgiving: 비정수는 그 한 필드만 기본 유지 + diagnostic(나머지 정상).
    var f = try parse(std.testing.allocator,
        \\window.padding-top = nope
        \\window.padding-left = 20
    );
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 4), f.config.window_padding_top); // nope 거부 → 기본 4
    try std.testing.expectEqual(@as(u32, 20), f.config.window_padding_left);
    try std.testing.expectEqual(@as(usize, 1), f.diagnostics.len);
}

test "parse: padding-x sets left+right (alias); last line wins when aliasing mixes with explicit keys" {
    // x는 left·right 둘 다 같은 값으로 설정(대칭 alias).
    var a = try parse(std.testing.allocator, "window.padding-x = 10");
    defer a.deinit();
    try std.testing.expectEqual(@as(u32, 10), a.config.window_padding_left);
    try std.testing.expectEqual(@as(u32, 10), a.config.window_padding_right);
    // 마지막 줄 우선(loader 순차 적용): padding-x=10 다음 padding-left=20 → left=20, right=10(x가 깐 값 유지).
    // 베이스/결정: 비대칭 padding엔 단일 표준이 없어, 사실상 표준 키 순서 의미(나중 키가 덮어씀)를 채택.
    var m = try parse(std.testing.allocator,
        \\window.padding-x = 10
        \\window.padding-left = 20
    );
    defer m.deinit();
    try std.testing.expectEqual(@as(u32, 20), m.config.window_padding_left);
    try std.testing.expectEqual(@as(u32, 10), m.config.window_padding_right);
    // 반대 순서: padding-left=20 먼저 깔고 padding-x=10이 left·right 둘 다 10으로 덮는다(마지막 줄 우선).
    var r = try parse(std.testing.allocator,
        \\window.padding-left = 20
        \\window.padding-x = 10
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 10), r.config.window_padding_left);
    try std.testing.expectEqual(@as(u32, 10), r.config.window_padding_right);
    // y alias도 동일하게 top+bottom 동시.
    var y = try parse(std.testing.allocator,
        \\window.padding-y = 6
        \\window.padding-bottom = 12
    );
    defer y.deinit();
    try std.testing.expectEqual(@as(u32, 6), y.config.window_padding_top);
    try std.testing.expectEqual(@as(u32, 12), y.config.window_padding_bottom);
}

test "parse: font.size-step out-of-range/non-numeric is forgiving (keeps default 1)" {
    const defaults = theme.Config{};
    {
        var p = try parse(std.testing.allocator, "font.size-step = 0\n"); // 0(무동작)·음수는 거부
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.size_step, p.config.font.size_step);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.size-step = abc\n");
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.size_step, p.config.font.size_step);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.size-step = 4.5\n"); // 유효(소수)
        defer p.deinit();
        try std.testing.expectEqual(@as(f32, 4.5), p.config.font.size_step);
        try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    }
}

test "parse: font.line-height parses valid; out-of-range/non-numeric is forgiving (keeps default 1.0)" {
    const defaults = theme.Config{};
    {
        var p = try parse(std.testing.allocator, "font.line-height = 1.5\n"); // 유효(소수 배수)
        defer p.deinit();
        try std.testing.expectEqual(@as(f32, 1.5), p.config.font.line_height);
        try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.line-height = 0.4\n"); // 0.5 미만 → 거부
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.line_height, p.config.font.line_height);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.line-height = 4\n"); // 3.0 초과 → 거부
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.line_height, p.config.font.line_height);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.line-height = tall\n"); // 비숫자 → 거부
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.line_height, p.config.font.line_height);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: font.letter-spacing parses valid (incl. negative); out-of-range/non-numeric is forgiving" {
    const defaults = theme.Config{};
    {
        var p = try parse(std.testing.allocator, "font.letter-spacing = 2.5\n"); // 양수 유효
        defer p.deinit();
        try std.testing.expectEqual(@as(f32, 2.5), p.config.font.letter_spacing);
        try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.letter-spacing = -1.5\n"); // 음수 유효(칸 좁힘)
        defer p.deinit();
        try std.testing.expectEqual(@as(f32, -1.5), p.config.font.letter_spacing);
        try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.letter-spacing = -16\n"); // -8 미만 → 거부
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.letter_spacing, p.config.font.letter_spacing);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.letter-spacing = 64\n"); // 32 초과 → 거부
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.letter_spacing, p.config.font.letter_spacing);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.letter-spacing = wide\n"); // 비숫자 → 거부
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.letter_spacing, p.config.font.letter_spacing);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: comments and blank lines are ignored; family keeps internal spaces" {
    var p = try parse(std.testing.allocator,
        \\
        \\   # a comment
        \\font.family =   Comic Code   Ligatures
        \\
    );
    defer p.deinit();
    try std.testing.expectEqualStrings("Comic Code   Ligatures", p.config.font.family);
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
}

test "parse: forgiving — unknown key and bad values keep defaults with diagnostics" {
    const defaults: theme.Config = .{};
    var p = try parse(std.testing.allocator,
        \\font.size = huge
        \\cursor.shape = triangle
        \\cursor.blink = maybe
        \\theme.background = not-a-color
        \\nonsense.key = 1
        \\chrome.theme = neon
        \\missing equals
    );
    defer p.deinit();
    // 잘못된 값은 전부 기본값 유지.
    try std.testing.expectEqual(defaults.font.size, p.config.font.size);
    try std.testing.expectEqual(defaults.cursor.shape, p.config.cursor.shape);
    try std.testing.expectEqual(defaults.cursor.blink, p.config.cursor.blink);
    try std.testing.expectEqualStrings(defaults.theme.background, p.config.theme.background);
    try std.testing.expectEqual(defaults.chrome_theme, p.config.chrome_theme); // 미지값(neon) → tui 폴백(C4a)
    // 7개 문제 줄 각각 diagnostic(chrome.theme=neon·누락 '=' 포함).
    try std.testing.expectEqual(@as(usize, 7), p.diagnostics.len);
}

test "parse: theme.palette.N parses ANSI 16 overrides; out-of-range/bad index/color are forgiving" {
    const defaults: theme.Config = .{};
    var p = try parse(std.testing.allocator,
        \\theme.palette.0 = #ff0000
        \\theme.palette.15 = #00ff00
        \\theme.palette.16 = #abcdef
        \\theme.palette.7 = not-a-color
        \\theme.palette.x = #112233
    );
    defer p.deinit();
    // 유효한 인덱스(0, 15)는 색을 담는다.
    try std.testing.expectEqualStrings("#ff0000", p.config.theme.palette[0].?);
    try std.testing.expectEqualStrings("#00ff00", p.config.theme.palette[15].?);
    // 범위 밖 인덱스(16)·잘못된 색(7)·비정수 인덱스(x)는 forgiving — 그 인덱스는 null 유지(기본 xterm).
    try std.testing.expect(p.config.theme.palette[7] == null);
    // override 안 한 다른 인덱스도 기본값(null) 유지.
    try std.testing.expectEqual(defaults.theme.palette[1], p.config.theme.palette[1]);
    // 문제 줄 3개(인덱스 16 범위 밖, 인덱스 7 색 형식, 인덱스 x 비정수) 각각 diagnostic.
    try std.testing.expectEqual(@as(usize, 3), p.diagnostics.len);

    // 파싱된 config는 resolve가 실패하지 않아야 한다(valid 색만 담기므로) + override가 ResolvedTheme까지 전파.
    const ra = try appearance.resolve(p.config);
    try std.testing.expectEqual(@as(?terminal.Rgb, terminal.Rgb{ .r = 0xff, .g = 0x00, .b = 0x00 }), ra.theme.palette[0]);
    try std.testing.expectEqual(@as(?terminal.Rgb, terminal.Rgb{ .r = 0x00, .g = 0xff, .b = 0x00 }), ra.theme.palette[15]);
    try std.testing.expect(ra.theme.palette[7] == null); // 잘못된 색은 안 담겨 기본 폴백
}

test "parse: theme.preset selects a named color theme as base; individual theme.* keys override" {
    const defaults: theme.Config = .{};

    // ghostty 프리셋: 배경/전경 + ANSI 16색이 Ghostty 기본색으로 깔린다(xterm 표준과 다름).
    var g = try parse(std.testing.allocator, "theme.preset = ghostty");
    defer g.deinit();
    try std.testing.expectEqualStrings("#282c34", g.config.theme.background);
    try std.testing.expectEqualStrings("#ffffff", g.config.theme.foreground);
    try std.testing.expectEqualStrings("#1d1f21", g.config.theme.palette[0].?); // Ghostty black
    try std.testing.expectEqualStrings("#eaeaea", g.config.theme.palette[15].?); // Ghostty bright white
    try std.testing.expectEqual(@as(usize, 0), g.diagnostics.len);

    // maru 프리셋 = struct default(기본 테마). 명시해도 기본값과 같고, 팔레트는 xterm 표준 폴백(null).
    var m = try parse(std.testing.allocator, "theme.preset = maru");
    defer m.deinit();
    try std.testing.expectEqualStrings(defaults.theme.background, m.config.theme.background);
    try std.testing.expect(m.config.theme.palette[0] == null);
    try std.testing.expectEqual(@as(usize, 0), m.diagnostics.len);

    // 프리셋은 base — 그 뒤 개별 theme.* 키가 일부만 override(순차 적용, 나중 줄 우선).
    var o = try parse(std.testing.allocator,
        \\theme.preset = ghostty
        \\theme.background = #000000
    );
    defer o.deinit();
    try std.testing.expectEqualStrings("#000000", o.config.theme.background); // override
    try std.testing.expectEqualStrings("#ffffff", o.config.theme.foreground); // 프리셋 유지
    try std.testing.expectEqualStrings("#1d1f21", o.config.theme.palette[0].?); // 프리셋 팔레트 유지

    // 알 수 없는 프리셋은 forgiving — maru 기본 유지 + diagnostic 1건.
    var b = try parse(std.testing.allocator, "theme.preset = bogus");
    defer b.deinit();
    try std.testing.expectEqualStrings(defaults.theme.background, b.config.theme.background);
    try std.testing.expectEqual(@as(usize, 1), b.diagnostics.len);

    // 파싱된 ghostty config는 resolve가 성공해야 한다(색 전부 유효) + background/palette가 ResolvedTheme까지 전파.
    const ra = try appearance.resolve(g.config);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0x28, .g = 0x2c, .b = 0x34 }, ra.theme.background);
    try std.testing.expectEqual(@as(?terminal.Rgb, terminal.Rgb{ .r = 0x1d, .g = 0x1f, .b = 0x21 }), ra.theme.palette[0]);
}

test "parse: theme.preset supports all named presets with correct palettes; light themes pin sidebar colors" {
    // 대표 다크 프리셋: 배경 + 특징 팔레트 색.
    var gv = try parse(std.testing.allocator, "theme.preset = gruvbox-dark");
    defer gv.deinit();
    try std.testing.expectEqualStrings("#282828", gv.config.theme.background);
    try std.testing.expectEqualStrings("#fb4934", gv.config.theme.palette[9].?); // gruvbox bright red

    var dr = try parse(std.testing.allocator, "theme.preset = dracula");
    defer dr.deinit();
    try std.testing.expectEqualStrings("#282a36", dr.config.theme.background);
    try std.testing.expectEqualStrings("#bd93f9", dr.config.theme.palette[4].?); // dracula purple

    var sd = try parse(std.testing.allocator, "theme.preset = solarized-dark");
    defer sd.deinit();
    try std.testing.expectEqualStrings("#002b36", sd.config.theme.background);

    var cm = try parse(std.testing.allocator, "theme.preset = catppuccin-mocha");
    defer cm.deinit();
    try std.testing.expectEqualStrings("#1e1e2e", cm.config.theme.background);
    try std.testing.expectEqualStrings("#89b4fa", cm.config.theme.palette[4].?); // mocha blue
    try std.testing.expectEqualStrings("#585b70", cm.config.theme.selection); // 가독성 위해 어두운 surface2(rosewater 아님)

    // 다크 프리셋은 사이드바 명시 안 함(배경에서 파생).
    try std.testing.expect(gv.config.theme.sidebar_background == null);

    // 라이트 프리셋: 사이드바를 배경보다 어둡게 명시(파생 lighten이 라이트 배경에서 흰색이 되는 함정 회피).
    var sl = try parse(std.testing.allocator, "theme.preset = solarized-light");
    defer sl.deinit();
    try std.testing.expectEqualStrings("#fdf6e3", sl.config.theme.background);
    try std.testing.expectEqualStrings("#eee8d5", sl.config.theme.sidebar_background.?);
    try std.testing.expectEqualStrings("#ded8c5", sl.config.theme.sidebar_active.?);

    var cl = try parse(std.testing.allocator, "theme.preset = catppuccin-latte");
    defer cl.deinit();
    try std.testing.expectEqualStrings("#eff1f5", cl.config.theme.background);
    try std.testing.expectEqualStrings("#e6e9ef", cl.config.theme.sidebar_background.?);

    // 라이트 프리셋도 resolve 성공(모든 색 유효) + 명시 사이드바가 ResolvedTheme까지 전파(파생 아님).
    const ra = try appearance.resolve(cl.config);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xef, .g = 0xf1, .b = 0xf5 }, ra.theme.background);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xe6, .g = 0xe9, .b = 0xef }, ra.theme.sidebar_background);
}

test "parse: resolved appearance never fails on parsed config (values pre-validated)" {
    var p = try parse(std.testing.allocator,
        \\font.size = 999
        \\theme.cursor = #zzzzzz
        \\chrome.theme = rich
    );
    defer p.deinit();
    // 잘못된 값은 default로 걸러졌으므로 resolve가 성공해야 한다.
    const ra = try appearance.resolve(p.config);
    try std.testing.expectEqual(theme.ChromeTheme.rich, ra.chrome_theme); // config→ResolvedAppearance 전파(C4a)
}

test "loadFile: missing path yields default config, not an error" {
    var p = try loadFile(std.testing.io, std.testing.allocator, "/nonexistent/maru/config-xyz");
    defer p.deinit();
    const defaults: theme.Config = .{};
    try std.testing.expectEqualStrings(defaults.font.family, p.config.font.family);
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
}

test "parse: keybind lines become app bindings; bad/duplicate ones are forgiving diagnostics" {
    var p = try parse(std.testing.allocator,
        \\keybind = Cmd+T = new_tab
        \\keybind = Cmd+W = close_tab
        \\keybind = Ctrl+Cmd+1 = select_tab:0
        \\keybind = Cmd+T = next_tab
        \\keybind = Bogus+Z = new_tab
        \\keybind = Cmd+Q = launch_rockets
        \\keybind = missing action
    );
    defer p.deinit();
    // 유효한 3개만 바인딩(중복 Cmd+T는 첫 줄 우선, 나머지 3줄은 오류).
    try std.testing.expectEqual(@as(usize, 3), p.keybindings.len);
    try std.testing.expectEqual(action_mod.Action.new_tab, p.keybindings[0].action);
    try std.testing.expectEqual(action_mod.Action.close_tab, p.keybindings[1].action);
    try std.testing.expectEqual(@as(usize, 0), p.keybindings[2].action.select_tab);
    // 중복 + 잘못된 chord + 알 수 없는 action + '=' 누락 = 4 diagnostic.
    try std.testing.expectEqual(@as(usize, 4), p.diagnostics.len);
    // 중복이 걸러졌으므로 resolver.validate가 통과한다.
    try p.keyBindingResolver().validate();
}

test "parse: keybind = <chord> = unbind collects unbinds; dedups across binds and unbinds" {
    var p = try parse(std.testing.allocator,
        \\keybind = Cmd+T = unbind
        \\keybind = Cmd+D = unbind
        \\keybind = Cmd+W = close_tab
        \\keybind = Cmd+T = new_tab
        \\keybind = Cmd+W = unbind
    );
    defer p.deinit();
    // unbind 2개(Cmd+T, Cmd+D), app 바인딩 1개(Cmd+W=close_tab). 뒤의 Cmd+T(new_tab)·Cmd+W(unbind)는 중복이라 무시.
    try std.testing.expectEqual(@as(usize, 2), p.unbinds.len);
    try std.testing.expect(p.unbinds[0].eql(try keybinding.KeyChord.parse("Cmd+T")));
    try std.testing.expect(p.unbinds[1].eql(try keybinding.KeyChord.parse("Cmd+D")));
    try std.testing.expectEqual(@as(usize, 1), p.keybindings.len);
    try std.testing.expectEqual(action_mod.Action.close_tab, p.keybindings[0].action);
    // 중복 2줄(Cmd+T 재바인딩, Cmd+W 언바인드) = 2 diagnostic.
    try std.testing.expectEqual(@as(usize, 2), p.diagnostics.len);
    // resolver가 unbind를 그대로 받는다(validate 통과).
    const resolver = p.keyBindingResolver();
    try resolver.validate();
    try std.testing.expectEqual(@as(usize, 2), resolver.unbinds.len);
}

test "parse: text:/esc:/ctrl: become terminal macros; bad payloads are forgiving" {
    var p = try parse(std.testing.allocator,
        \\keybind = F2 = text:hello
        \\keybind = F4 = esc:[2J
        \\keybind = Cmd+E = ctrl:[
        \\keybind = Cmd+X = ctrl:1
        \\keybind = F3 = text:
        \\keybind = Cmd+Y = ctrl:ab
    );
    defer p.deinit();
    // 유효 3개(text/esc/ctrl). 나머지 3줄은 오류(C0 매핑 없는 ctrl:1, 빈 text:, 여러 글자 ctrl:ab).
    try std.testing.expectEqual(@as(usize, 3), p.terminal_bindings.len);
    try std.testing.expectEqual(@as(usize, 0), p.keybindings.len);
    try std.testing.expectEqual(@as(usize, 3), p.diagnostics.len);

    // text:hello → send_text "hello".
    try std.testing.expectEqualStrings("hello", p.terminal_bindings[0].input.send_text);
    // esc:[2J → ESC를 앞에 붙인 send_escape_sequence "\x1b[2J".
    try std.testing.expectEqualStrings("\x1b[2J", p.terminal_bindings[1].input.send_escape_sequence);
    // ctrl:[ → send_control '[' (resolve 시 controlByte로 ESC가 된다).
    try std.testing.expectEqual(@as(u21, '['), p.terminal_bindings[2].input.send_control);

    // resolver가 매크로를 받고 app↔terminal 충돌 없이 validate 통과(세 풀이 같은 dedup).
    const resolver = p.keyBindingResolver();
    try resolver.validate();
    try std.testing.expectEqual(@as(usize, 3), resolver.terminal_bindings.len);

    // 실제 resolve: Cmd+E → ctrl:[ → ESC(0x1b) 한 바이트.
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolved = try resolver.resolve(.{ .key = .{ .char = 'e' }, .modifiers = .{ .command = true } }, &buffer, .{});
    try std.testing.expectEqualStrings("\x1b", resolved.terminal_input);
}

test "parse: global: prefix collects global bindings separate from in-app pools" {
    var p = try parse(std.testing.allocator,
        \\keybind = global:Cmd+Alt+Space = toggle_window
        \\keybind = global:Cmd+Alt+T = show_window
        \\keybind = Cmd+T = new_tab
        \\keybind = global:Cmd+Alt+Space = show_window
        \\keybind = global:Cmd+Alt+X = bogus_action
    );
    defer p.deinit();
    // 유효 전역 2개(Space=toggle, T=show). in-app 1개(Cmd+T=new_tab). 나머지 2줄은 오류(중복 Space, bogus action).
    try std.testing.expectEqual(@as(usize, 2), p.global_bindings.len);
    try std.testing.expectEqual(action_mod.GlobalAction.toggle_window, p.global_bindings[0].action);
    try std.testing.expectEqual(action_mod.GlobalAction.show_window, p.global_bindings[1].action);
    try std.testing.expect(p.global_bindings[0].chord.eql(try keybinding.KeyChord.parse("Cmd+Alt+Space")));
    // in-app 풀은 전역과 분리 — Cmd+T(new_tab)는 그대로.
    try std.testing.expectEqual(@as(usize, 1), p.keybindings.len);
    try std.testing.expectEqual(action_mod.Action.new_tab, p.keybindings[0].action);
    // 중복 전역 + 알 수 없는 전역 action = 2 diagnostic.
    try std.testing.expectEqual(@as(usize, 2), p.diagnostics.len);
    // 전역은 resolver에 안 들어간다(in-app 전용) — resolver는 keybindings/unbinds/terminal만.
    const resolver = p.keyBindingResolver();
    try resolver.validate();
    try std.testing.expectEqual(@as(usize, 1), resolver.app_bindings.len);
}

test "parse: same chord can be both global and in-app (separate namespaces, no conflict)" {
    var p = try parse(std.testing.allocator,
        \\keybind = global:Cmd+T = toggle_window
        \\keybind = Cmd+T = new_tab
    );
    defer p.deinit();
    // 전역 Cmd+T와 in-app Cmd+T는 다른 네임스페이스(OS 핫키 vs 앱 키 경로) — 둘 다 살고 충돌 없음.
    try std.testing.expectEqual(@as(usize, 1), p.global_bindings.len);
    try std.testing.expectEqual(@as(usize, 1), p.keybindings.len);
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    try p.keyBindingResolver().validate();
}

test "parse: a chord can't be both an app action and a terminal macro (first line wins)" {
    var p = try parse(std.testing.allocator,
        \\keybind = Cmd+T = new_tab
        \\keybind = Cmd+T = text:oops
    );
    defer p.deinit();
    // 첫 줄(app)만 살고 둘째(terminal)는 중복으로 무시 → app↔terminal 충돌이 안 생긴다.
    try std.testing.expectEqual(@as(usize, 1), p.keybindings.len);
    try std.testing.expectEqual(@as(usize, 0), p.terminal_bindings.len);
    try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    try p.keyBindingResolver().validate(); // 충돌 없음
}

test "parse: keybindings empty when none configured; appearance keys unaffected" {
    var p = try parse(std.testing.allocator, "font.size = 13\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.keybindings.len);
    try std.testing.expectEqual(@as(f32, 13), p.config.font.size);
}

test "parse: input.page-keys scroll(default)/passthrough + invalid is forgiving" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqual(theme.PageKeys.scroll, p.config.input.page_keys); // 기본(Mac 관례)
    }
    {
        var p = try parse(std.testing.allocator, "input.page-keys = passthrough\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.PageKeys.passthrough, p.config.input.page_keys); // opt-in
    }
    {
        var p = try parse(std.testing.allocator, "input.page-keys = bogus\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.PageKeys.scroll, p.config.input.page_keys); // 잘못된 값 → 기본 유지
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: input.shift-enter newline(default)/native + invalid is forgiving" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqual(theme.ShiftEnter.newline, p.config.input.shift_enter); // 기본(멀티라인 줄바꿈)
    }
    {
        var p = try parse(std.testing.allocator, "input.shift-enter = native\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.ShiftEnter.native, p.config.input.shift_enter); // opt-out(기존 동작)
    }
    {
        var p = try parse(std.testing.allocator, "input.shift-enter = bogus\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.ShiftEnter.newline, p.config.input.shift_enter); // 잘못된 값 → 기본 유지
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: input.ime-enter newline(default)/commit-only + invalid is forgiving" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqual(theme.ImeEnter.newline, p.config.input.ime_enter); // 기본(확정+개행)
    }
    {
        var p = try parse(std.testing.allocator, "input.ime-enter = commit-only\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.ImeEnter.commit_only, p.config.input.ime_enter); // opt-out(조합만 확정)
    }
    {
        var p = try parse(std.testing.allocator, "input.ime-enter = bogus\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.ImeEnter.newline, p.config.input.ime_enter); // 잘못된 값 → 기본 유지
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: scrollback.lines + bell.audible (defaults and forgiving)" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 1000), p.config.scrollback.lines); // 기본
        try std.testing.expectEqual(true, p.config.bell.audible); // 기본
    }
    {
        var p = try parse(std.testing.allocator, "scrollback.lines = 5000\n");
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 5000), p.config.scrollback.lines);
    }
    {
        var p = try parse(std.testing.allocator, "scrollback.lines = 0\n"); // 0=비활성, 유효
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 0), p.config.scrollback.lines);
    }
    {
        var p = try parse(std.testing.allocator, "scrollback.lines = 999999\n"); // 상한 초과 → 기본 + 진단
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 1000), p.config.scrollback.lines);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "scrollback.lines = abc\n"); // 비정수 → 기본
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 1000), p.config.scrollback.lines);
    }
    {
        var p = try parse(std.testing.allocator, "bell.audible = false\n");
        defer p.deinit();
        try std.testing.expectEqual(false, p.config.bell.audible);
    }
    {
        var p = try parse(std.testing.allocator, "bell.audible = bogus\n"); // 잘못 → 기본 true + 진단
        defer p.deinit();
        try std.testing.expectEqual(true, p.config.bell.audible);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: shell-integration.ssh (opt-in, default off, forgiving)" {
    {
        var p = try parse(std.testing.allocator, ""); // 기본 off — ssh 라우팅은 명시 opt-in
        defer p.deinit();
        try std.testing.expectEqual(false, p.config.shell_integration.ssh);
    }
    {
        var p = try parse(std.testing.allocator, "shell-integration.ssh = true\n");
        defer p.deinit();
        try std.testing.expectEqual(true, p.config.shell_integration.ssh);
    }
    {
        var p = try parse(std.testing.allocator, "shell-integration.ssh = nope\n"); // 잘못 → 기본 false + 진단
        defer p.deinit();
        try std.testing.expectEqual(false, p.config.shell_integration.ssh);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: quick-terminal options (height/auto-hide/screen) with defaults and forgiving" {
    {
        // 기본값.
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqual(@as(f32, 0.45), p.config.quick_terminal.height_fraction);
        try std.testing.expectEqual(true, p.config.quick_terminal.auto_hide);
        try std.testing.expectEqual(theme.QuickTerminalScreen.main, p.config.quick_terminal.screen);
        try std.testing.expectEqual(theme.QuickTerminalPosition.top, p.config.quick_terminal.position);
        try std.testing.expectEqual(theme.QuickTerminalChrome.full, p.config.quick_terminal.chrome);
        try std.testing.expectEqual(false, p.config.quick_terminal.minimal_tabs);
        try std.testing.expectEqual(@as(f32, 0), p.config.quick_terminal.width_fraction); // 미설정 → 0(height 따라감)
    }
    {
        var p = try parse(std.testing.allocator,
            \\quick-terminal.height = 0.6
            \\quick-terminal.width = 0.8
            \\quick-terminal.auto-hide = false
            \\quick-terminal.screen = mouse
            \\quick-terminal.position = bottom
            \\quick-terminal.chrome = minimal
            \\quick-terminal.minimal-tabs = true
        );
        defer p.deinit();
        try std.testing.expectEqual(@as(f32, 0.6), p.config.quick_terminal.height_fraction);
        try std.testing.expectEqual(@as(f32, 0.8), p.config.quick_terminal.width_fraction);
        try std.testing.expectEqual(false, p.config.quick_terminal.auto_hide);
        try std.testing.expectEqual(theme.QuickTerminalScreen.mouse, p.config.quick_terminal.screen);
        try std.testing.expectEqual(theme.QuickTerminalPosition.bottom, p.config.quick_terminal.position);
        try std.testing.expectEqual(theme.QuickTerminalChrome.minimal, p.config.quick_terminal.chrome);
        try std.testing.expectEqual(true, p.config.quick_terminal.minimal_tabs);
        try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    }
    {
        // 잘못된 값들 → 전부 기본값 유지 + diagnostic.
        var p = try parse(std.testing.allocator,
            \\quick-terminal.height = 2.0
            \\quick-terminal.height = huge
            \\quick-terminal.width = 1.5
            \\quick-terminal.auto-hide = maybe
            \\quick-terminal.screen = projector
            \\quick-terminal.position = diagonal
            \\quick-terminal.chrome = fancy
            \\quick-terminal.minimal-tabs = yes
        );
        defer p.deinit();
        try std.testing.expectEqual(@as(f32, 0.45), p.config.quick_terminal.height_fraction);
        try std.testing.expectEqual(@as(f32, 0), p.config.quick_terminal.width_fraction); // 범위 밖 → 0 유지
        try std.testing.expectEqual(true, p.config.quick_terminal.auto_hide);
        try std.testing.expectEqual(theme.QuickTerminalScreen.main, p.config.quick_terminal.screen);
        try std.testing.expectEqual(theme.QuickTerminalPosition.top, p.config.quick_terminal.position);
        try std.testing.expectEqual(theme.QuickTerminalChrome.full, p.config.quick_terminal.chrome);
        try std.testing.expectEqual(false, p.config.quick_terminal.minimal_tabs);
        try std.testing.expectEqual(@as(usize, 8), p.diagnostics.len);
    }
    {
        // center 위치(가장자리 없이 중앙 페이드).
        var p = try parse(std.testing.allocator, "quick-terminal.position = center");
        defer p.deinit();
        try std.testing.expectEqual(theme.QuickTerminalPosition.center, p.config.quick_terminal.position);
        try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    }
}

test "parse: term default xterm-maru, override, empty is forgiving" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqualStrings("xterm-maru", p.config.term); // 전환된 기본값(조건부+폴백은 pty가 처리)
    }
    {
        var p = try parse(std.testing.allocator, "term = xterm-256color\n");
        defer p.deinit();
        try std.testing.expectEqualStrings("xterm-256color", p.config.term); // 사용자가 명시로 되돌릴 수 있다
    }
    {
        var p = try parse(std.testing.allocator, "term =   \n");
        defer p.deinit();
        try std.testing.expectEqualStrings("xterm-maru", p.config.term); // 빈 값 → 기본 유지
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}
