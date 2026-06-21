//! config 직렬화(역파싱) — `theme.Config`를 `key = value` 토큰 목록(`KeyValue`)으로 펼친다.
//!
//! 이것은 `loader.parse`의 **대칭 역연산**이다: parse가 텍스트→Config라면 `configKeyValues`는 Config→키/값이다.
//! 세팅 GUI(앱→config 파일 양방향 반영, docs/settings-page.md Phase S0)가 이 목록에서 바꾼 키만 골라
//! `loader.updateConfigText`로 원본에 in-place 반영한다 — 통째 재작성이 아니라 부분 갱신이라 주석·미파싱 키가
//! 보존된다(sidebar 토글이 쓰던 패턴의 일반화). 새 config 키를 추가하는 PR은 **parse와 이 함수를 같이** 늘려,
//! round-trip 대칭 테스트(`parse(render(configKeyValues(cfg))) == cfg`)가 둘의 누락을 못박는다(단일 출처 정합).
//!
//! 경계: 값 토큰은 loader의 파서가 받아들이는 **정확한 표기**여야 한다(예: `input.ime-enter`는 `commit-only`,
//! enum tag(`commit_only`)가 아님). 그래서 enum은 @tagName에 기대지 않고 명시 매핑한다. 색/숫자/문자열은 그대로,
//! 부동소수는 `{d}`(Zig의 shortest round-trip 표기)로 적어 parse가 같은 f32 비트로 되돌린다(테스트가 보장).
//!
//! **theme.preset은 역으로 못 복원한다** — preset은 parse 시점에 개별 theme.* 색으로 펼쳐지고 Config에 그 이름이
//! 남지 않으므로, 직렬화는 항상 펼쳐진 개별 색을 적는다(색 값은 동등, preset 이름만 잃는다). GUI가 preset을 고른
//! 직후엔 개별 색을 안 건드리는 한 사용자의 `theme.preset` 줄은 updateConfigText가 보존한다.

const std = @import("std");
const theme = @import("theme.zig");
const loader = @import("loader.zig");

pub const KeyValue = loader.KeyValue;

fn cursorShapeToken(s: theme.CursorShape) []const u8 {
    return switch (s) {
        .block => "block",
        .bar => "bar",
        .underline => "underline",
    };
}

fn chromeThemeToken(t: theme.ChromeTheme) []const u8 {
    return switch (t) {
        .tui => "tui",
        .rich => "rich",
    };
}

fn ambiguousWidthToken(w: theme.AmbiguousWidth) []const u8 {
    return switch (w) {
        .narrow => "narrow",
        .wide => "wide",
    };
}

fn pageKeysToken(p: theme.PageKeys) []const u8 {
    return switch (p) {
        .passthrough => "passthrough",
        .scroll => "scroll",
    };
}

fn shiftEnterToken(s: theme.ShiftEnter) []const u8 {
    return switch (s) {
        .newline => "newline",
        .native => "native",
    };
}

fn imeEnterToken(i: theme.ImeEnter) []const u8 {
    return switch (i) {
        .newline => "newline",
        .commit_only => "commit-only", // 토큰은 하이픈 — @tagName(commit_only)와 다르다
    };
}

fn quickScreenToken(s: theme.QuickTerminalScreen) []const u8 {
    return switch (s) {
        .main => "main",
        .mouse => "mouse",
    };
}

fn quickPositionToken(p: theme.QuickTerminalPosition) []const u8 {
    return switch (p) {
        .top => "top",
        .bottom => "bottom",
        .left => "left",
        .right => "right",
        .center => "center",
    };
}

fn quickChromeToken(c: theme.QuickTerminalChrome) []const u8 {
    return switch (c) {
        .full => "full",
        .minimal => "minimal",
    };
}

fn boolToken(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// `theme.Config`의 모든 필드를 정규 `key = value` 목록으로 펼친다. 반환 슬라이스와 그 안의 동적 값 문자열
/// (숫자/색은 allocPrint)은 모두 `arena`가 소유한다 — 호출자는 arena 하나를 만들어 넘기고, 텍스트를 만든 뒤
/// 통째로 free한다(개별 free 불필요). enum/bool 토큰은 정적 리터럴이라 alloc하지 않는다.
///
/// **canonical full dump** — 기본값과 같은 키도 모두 포함한다. "기본값 위 override만 쓰기"(파일 비대화 방지)는
/// 호출자(serialize 정책)가 이 목록을 default와 비교해 거르는 식으로 정한다(docs/settings-page.md S0-1). 여기서는
/// parse와의 1:1 대칭만 책임진다.
pub fn configKeyValues(arena: std.mem.Allocator, config: theme.Config) ![]const KeyValue {
    var list: std.ArrayList(KeyValue) = .empty;

    // font.*
    try list.append(arena, .{ .key = "font.family", .value = config.font.family });
    try list.append(arena, .{ .key = "font.size", .value = try std.fmt.allocPrint(arena, "{d}", .{config.font.size}) });
    try list.append(arena, .{ .key = "font.size-step", .value = try std.fmt.allocPrint(arena, "{d}", .{config.font.size_step}) });
    try list.append(arena, .{ .key = "font.line-height", .value = try std.fmt.allocPrint(arena, "{d}", .{config.font.line_height}) });
    try list.append(arena, .{ .key = "font.letter-spacing", .value = try std.fmt.allocPrint(arena, "{d}", .{config.font.letter_spacing}) });

    // theme.* (색 문자열 그대로; palette는 non-null 인덱스만)
    try list.append(arena, .{ .key = "theme.background", .value = config.theme.background });
    try list.append(arena, .{ .key = "theme.foreground", .value = config.theme.foreground });
    try list.append(arena, .{ .key = "theme.cursor", .value = config.theme.cursor });
    try list.append(arena, .{ .key = "theme.selection", .value = config.theme.selection });
    for (config.theme.palette, 0..) |entry, i| {
        const color = entry orelse continue; // null = 그 인덱스는 기본 xterm — 줄 안 만든다(parse가 기본 폴백)
        try list.append(arena, .{
            .key = try std.fmt.allocPrint(arena, "theme.palette.{d}", .{i}),
            .value = color,
        });
    }

    // cursor.*
    try list.append(arena, .{ .key = "cursor.shape", .value = cursorShapeToken(config.cursor.shape) });
    try list.append(arena, .{ .key = "cursor.blink", .value = boolToken(config.cursor.blink) });

    // chrome / text
    try list.append(arena, .{ .key = "chrome.theme", .value = chromeThemeToken(config.chrome_theme) });
    try list.append(arena, .{ .key = "text.blink", .value = boolToken(config.blink_text) });
    try list.append(arena, .{ .key = "text.ambiguous-width", .value = ambiguousWidthToken(config.ambiguous_width) });
    try list.append(arena, .{ .key = "theme.bold-is-bright", .value = boolToken(config.bold_is_bright) });

    // input.*
    try list.append(arena, .{ .key = "input.page-keys", .value = pageKeysToken(config.input.page_keys) });
    try list.append(arena, .{ .key = "input.shift-enter", .value = shiftEnterToken(config.input.shift_enter) });
    try list.append(arena, .{ .key = "input.ime-enter", .value = imeEnterToken(config.input.ime_enter) });

    // window.padding-* (4방 개별 — x/y alias는 parse 전용 입력 편의라 역직렬화는 4방으로 정규화한다)
    try list.append(arena, .{ .key = "window.padding-top", .value = try std.fmt.allocPrint(arena, "{d}", .{config.window_padding_top}) });
    try list.append(arena, .{ .key = "window.padding-right", .value = try std.fmt.allocPrint(arena, "{d}", .{config.window_padding_right}) });
    try list.append(arena, .{ .key = "window.padding-bottom", .value = try std.fmt.allocPrint(arena, "{d}", .{config.window_padding_bottom}) });
    try list.append(arena, .{ .key = "window.padding-left", .value = try std.fmt.allocPrint(arena, "{d}", .{config.window_padding_left}) });

    // term
    try list.append(arena, .{ .key = "term", .value = config.term });

    // notifications / scrollback / bell / shell-integration
    try list.append(arena, .{ .key = "notifications.agent-complete", .value = boolToken(config.notifications.agent_complete) });
    try list.append(arena, .{ .key = "scrollback.lines", .value = try std.fmt.allocPrint(arena, "{d}", .{config.scrollback.lines}) });
    try list.append(arena, .{ .key = "bell.audible", .value = boolToken(config.bell.audible) });
    try list.append(arena, .{ .key = "shell-integration.ssh", .value = boolToken(config.shell_integration.ssh) });

    // sidebar.*
    try list.append(arena, .{ .key = "sidebar.show-branch", .value = boolToken(config.sidebar.show_branch) });
    try list.append(arena, .{ .key = "sidebar.show-folder", .value = boolToken(config.sidebar.show_folder) });

    // workspace.*
    try list.append(arena, .{ .key = "workspace.root", .value = config.workspace.root });
    try list.append(arena, .{ .key = "workspace.tab-inherit-cwd", .value = boolToken(config.workspace.tab_inherit_cwd) });
    try list.append(arena, .{ .key = "workspace.split-inherit-cwd", .value = boolToken(config.workspace.split_inherit_cwd) });

    // quick-terminal.*
    try list.append(arena, .{ .key = "quick-terminal.height", .value = try std.fmt.allocPrint(arena, "{d}", .{config.quick_terminal.height_fraction}) });
    try list.append(arena, .{ .key = "quick-terminal.width", .value = try std.fmt.allocPrint(arena, "{d}", .{config.quick_terminal.width_fraction}) });
    try list.append(arena, .{ .key = "quick-terminal.auto-hide", .value = boolToken(config.quick_terminal.auto_hide) });
    try list.append(arena, .{ .key = "quick-terminal.screen", .value = quickScreenToken(config.quick_terminal.screen) });
    try list.append(arena, .{ .key = "quick-terminal.position", .value = quickPositionToken(config.quick_terminal.position) });
    try list.append(arena, .{ .key = "quick-terminal.chrome", .value = quickChromeToken(config.quick_terminal.chrome) });
    try list.append(arena, .{ .key = "quick-terminal.minimal-tabs", .value = boolToken(config.quick_terminal.minimal_tabs) });

    return list.toOwnedSlice(arena);
}

/// 직렬화된 키/값 목록 중 특정 키 하나의 값을 찾는다(GUI가 "이 키만 써라"로 고를 때 + 테스트 편의). 없으면 null.
pub fn valueForKey(kvs: []const KeyValue, key: []const u8) ?[]const u8 {
    for (kvs) |kv| {
        if (std.mem.eql(u8, kv.key, key)) return kv.value;
    }
    return null;
}

// ── round-trip 대칭 테스트 ──────────────────────────────────────────────────────────────────────
// parse(render(configKeyValues(cfg)))가 원래 cfg 필드를 그대로 복원하는지 못박는다. parse와 configKeyValues 중
// 한쪽만 새 키를 다루면 여기서 깨진다(둘을 같이 늘리게 강제하는 가드). Linux CI(순수)에서 돈다.

test "round-trip: configKeyValues → updateConfigText → parse가 모든 필드를 복원한다" {
    const a = std.testing.allocator;

    // 전 필드를 기본과 다르게 둔 Config(기본값 누수로 통과하는 가짜 green 방지).
    var cfg: theme.Config = .{};
    cfg.font.family = "Iosevka Term";
    cfg.font.size = 16.5;
    cfg.font.size_step = 2;
    cfg.font.line_height = 1.25;
    cfg.font.letter_spacing = -1.5;
    cfg.theme.background = "#001122";
    cfg.theme.foreground = "#ffeedd";
    cfg.theme.cursor = "#abcdef";
    cfg.theme.selection = "#102030";
    cfg.theme.palette[1] = "#d35f5f";
    cfg.theme.palette[14] = "#70c0b1";
    cfg.cursor.shape = .underline;
    cfg.cursor.blink = false;
    cfg.chrome_theme = .rich;
    cfg.blink_text = true;
    cfg.ambiguous_width = .wide;
    cfg.bold_is_bright = true;
    cfg.input.page_keys = .passthrough;
    cfg.input.shift_enter = .native;
    cfg.input.ime_enter = .commit_only;
    cfg.window_padding_top = 1;
    cfg.window_padding_right = 2;
    cfg.window_padding_bottom = 3;
    cfg.window_padding_left = 4;
    cfg.term = "xterm-256color";
    cfg.notifications.agent_complete = false;
    cfg.scrollback.lines = 5000;
    cfg.bell.audible = false;
    cfg.shell_integration.ssh = true;
    cfg.sidebar.show_branch = false;
    cfg.sidebar.show_folder = false;
    cfg.workspace.root = "~/projects";
    cfg.workspace.tab_inherit_cwd = false;
    cfg.workspace.split_inherit_cwd = false;
    cfg.quick_terminal.height_fraction = 0.6;
    cfg.quick_terminal.width_fraction = 0.5;
    cfg.quick_terminal.auto_hide = false;
    cfg.quick_terminal.screen = .mouse;
    cfg.quick_terminal.position = .bottom;
    cfg.quick_terminal.chrome = .minimal;
    cfg.quick_terminal.minimal_tabs = true;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const kvs = try configKeyValues(arena.allocator(), cfg);
    const text = try loader.updateConfigText(a, "", kvs); // 빈 원본 → 전 키 append
    defer a.free(text);

    var parsed = try loader.parse(a, text);
    defer parsed.deinit();
    const got = parsed.config;

    try std.testing.expectEqualStrings("Iosevka Term", got.font.family);
    try std.testing.expectEqual(@as(f32, 16.5), got.font.size);
    try std.testing.expectEqual(@as(f32, 2), got.font.size_step);
    try std.testing.expectEqual(@as(f32, 1.25), got.font.line_height);
    try std.testing.expectEqual(@as(f32, -1.5), got.font.letter_spacing);
    try std.testing.expectEqualStrings("#001122", got.theme.background);
    try std.testing.expectEqualStrings("#ffeedd", got.theme.foreground);
    try std.testing.expectEqualStrings("#abcdef", got.theme.cursor);
    try std.testing.expectEqualStrings("#102030", got.theme.selection);
    try std.testing.expectEqualStrings("#d35f5f", got.theme.palette[1].?);
    try std.testing.expectEqualStrings("#70c0b1", got.theme.palette[14].?);
    try std.testing.expectEqual(@as(?[]const u8, null), got.theme.palette[0]); // 안 적은 인덱스는 기본(null)
    try std.testing.expectEqual(theme.CursorShape.underline, got.cursor.shape);
    try std.testing.expectEqual(false, got.cursor.blink);
    try std.testing.expectEqual(theme.ChromeTheme.rich, got.chrome_theme);
    try std.testing.expectEqual(true, got.blink_text);
    try std.testing.expectEqual(theme.AmbiguousWidth.wide, got.ambiguous_width);
    try std.testing.expectEqual(true, got.bold_is_bright);
    try std.testing.expectEqual(theme.PageKeys.passthrough, got.input.page_keys);
    try std.testing.expectEqual(theme.ShiftEnter.native, got.input.shift_enter);
    try std.testing.expectEqual(theme.ImeEnter.commit_only, got.input.ime_enter);
    try std.testing.expectEqual(@as(u32, 1), got.window_padding_top);
    try std.testing.expectEqual(@as(u32, 2), got.window_padding_right);
    try std.testing.expectEqual(@as(u32, 3), got.window_padding_bottom);
    try std.testing.expectEqual(@as(u32, 4), got.window_padding_left);
    try std.testing.expectEqualStrings("xterm-256color", got.term);
    try std.testing.expectEqual(false, got.notifications.agent_complete);
    try std.testing.expectEqual(@as(u32, 5000), got.scrollback.lines);
    try std.testing.expectEqual(false, got.bell.audible);
    try std.testing.expectEqual(true, got.shell_integration.ssh);
    try std.testing.expectEqual(false, got.sidebar.show_branch);
    try std.testing.expectEqual(false, got.sidebar.show_folder);
    try std.testing.expectEqualStrings("~/projects", got.workspace.root);
    try std.testing.expectEqual(false, got.workspace.tab_inherit_cwd);
    try std.testing.expectEqual(false, got.workspace.split_inherit_cwd);
    try std.testing.expectEqual(@as(f32, 0.6), got.quick_terminal.height_fraction);
    try std.testing.expectEqual(@as(f32, 0.5), got.quick_terminal.width_fraction);
    try std.testing.expectEqual(false, got.quick_terminal.auto_hide);
    try std.testing.expectEqual(theme.QuickTerminalScreen.mouse, got.quick_terminal.screen);
    try std.testing.expectEqual(theme.QuickTerminalPosition.bottom, got.quick_terminal.position);
    try std.testing.expectEqual(theme.QuickTerminalChrome.minimal, got.quick_terminal.chrome);
    try std.testing.expectEqual(true, got.quick_terminal.minimal_tabs);
}

test "valueForKey: 직렬화 목록에서 단일 키 값을 고른다" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cfg: theme.Config = .{};
    cfg.cursor.shape = .bar;
    const kvs = try configKeyValues(arena.allocator(), cfg);
    try std.testing.expectEqualStrings("bar", valueForKey(kvs, "cursor.shape").?);
    try std.testing.expectEqual(@as(?[]const u8, null), valueForKey(kvs, "no.such.key"));
}
