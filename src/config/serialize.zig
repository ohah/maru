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
const schema = @import("schema.zig");

pub const KeyValue = loader.KeyValue;

// 모든 enum/bool/색 토큰 헬퍼(cursorShapeToken·chromeThemeToken·ambiguousWidthToken·boolToken·pageKeysToken·
// shiftEnterToken·imeEnterToken·quick*Token)는 스키마-주도 이주(CS-1/CS-2/CS-2b)로 schema.serializeValue가
// 대신한다 — 전부 제거. configKeyValues의 수동 emit은 이제 특수(palette.N·workspace.root·shell.args·env.*)만.

/// `theme.Config`의 모든 필드를 정규 `key = value` 목록으로 펼친다. 반환 슬라이스와 그 안의 동적 값 문자열
/// (숫자/색은 allocPrint)은 모두 `arena`가 소유한다 — 호출자는 arena 하나를 만들어 넘기고, 텍스트를 만든 뒤
/// 통째로 free한다(개별 free 불필요). enum/bool 토큰은 정적 리터럴이라 alloc하지 않는다.
///
/// **canonical full dump** — 기본값과 같은 키도 모두 포함한다. "기본값 위 override만 쓰기"(파일 비대화 방지)는
/// 호출자(serialize 정책)가 이 목록을 default와 비교해 거르는 식으로 정한다(docs/settings-page.md S0-1). 여기서는
/// parse와의 1:1 대칭만 책임진다.
pub fn configKeyValues(arena: std.mem.Allocator, config: theme.Config) ![]const KeyValue {
    var list: std.ArrayList(KeyValue) = .empty;

    // 스키마-주도 스칼라(sub-struct 전부 + 최상위 스칼라 chrome.theme·text.*·theme.bold-is-bright·window.padding-*·
    // term)를 먼저 emit(CS-1+CS-2+CS-2b). 아래 수동 블록은 **특수만**(theme.palette.N·workspace.root·shell.args·env.*).
    // 단일 출처: docs/config-schema.md.
    try schema.appendSerialized(arena, config, &list);

    // 특수: theme.palette.N(인덱스), workspace.root(절대경로 검증), shell.args(공백-토큰 리스트), env.<KEY>(동적).
    for (config.theme.palette, 0..) |entry, i| {
        const color = entry orelse continue; // null = 그 인덱스는 기본 xterm — 줄 안 만든다(parse가 기본 폴백)
        try list.append(arena, .{ .key = try std.fmt.allocPrint(arena, "theme.palette.{d}", .{i}), .value = color });
    }
    // 구문 색 역할 override: non-null만 emit(팔레트·커서 색과 동형 — null=파생이라 줄을 안 만든다). 키는
    // theme.syntaxRoleKey 단일 출처라 loader 파싱과 어긋날 수 없다(comptime 문자열이라 allocPrint도 없다).
    inline for (@typeInfo(theme.SyntaxRole).@"enum".fields) |f| {
        const role: theme.SyntaxRole = @enumFromInt(f.value);
        if (config.theme.syntax[f.value]) |c| {
            try list.append(arena, .{ .key = comptime theme.syntaxRoleKey(role), .value = c });
        }
    }
    // 커서 색 override: non-null만 emit한다(null=테마 폴백이라 줄 안 만듦 — palette와 동형). 스키마-주도가
    // nullable을 안 다뤄 여기 수동으로 둔다(loader 수동 핸들러와 짝). 정적/arena 문자열 그대로 빌려준다.
    if (config.cursor.color) |c| try list.append(arena, .{ .key = "cursor.color", .value = c });
    if (config.cursor.text) |c| try list.append(arena, .{ .key = "cursor.text", .value = c });
    try list.append(arena, .{ .key = "workspace.root", .value = config.workspace.root });
    try list.append(arena, .{ .key = "shell.args", .value = try std.mem.join(arena, " ", config.shell.args) });
    for (config.env) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue; // '=' 없으면 형식 오류 — 건너뜀
        try list.append(arena, .{ .key = try std.fmt.allocPrint(arena, "env.{s}", .{entry[0..eq]}), .value = entry[eq + 1 ..] });
    }

    return list.toOwnedSlice(arena);
}

/// 직렬화된 키/값 목록 중 특정 키 하나의 값을 찾는다(GUI가 "이 키만 써라"로 고를 때 + 테스트 편의). 없으면 null.
pub fn valueForKey(kvs: []const KeyValue, key: []const u8) ?[]const u8 {
    for (kvs) |kv| {
        if (std.mem.eql(u8, kv.key, key)) return kv.value;
    }
    return null;
}

/// 주어진 키들의 **현재 값만** config 텍스트에 in-place 반영한다(즉시-저장 GUI write-back의 토대 — S0-1b). 각 키의
/// 값은 `configKeyValues`(스키마 직렬화 단일 출처)에서 가져오고, `updateConfigText`로 부분 갱신해 주석·미파싱 키·다른
/// 줄을 보존한다. **override-only by construction** — 넘긴 키만 쓰므로 기본값 40개를 파일에 쏟지 않는다(full-dump 회피).
/// `configKeyValues`가 emit하는 키(스키마 스칼라 + 특수 workspace.root·shell.args, 그리고 설정된 palette.N·env.*)만
/// 처리한다. 거기 없는 키(`keybind`·`theme.preset`·오타)는 `valueForKey`가 null이라 **스킵**한다(그 키는 호출처가
/// 자체 직렬화). 반환은 owned(`allocator`). 사이드바 ⚙ 토글이 쓰던 2키 하드코딩을 이걸로 일반화.
pub fn updateForKeys(allocator: std.mem.Allocator, original: []const u8, config: theme.Config, keys: []const []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const all = try configKeyValues(aa, config);
    var updates: std.ArrayList(KeyValue) = .empty;
    for (keys) |k| {
        const v = valueForKey(all, k) orelse continue; // 스키마 키만 — 특수 키는 호출처 책임
        // **기본 키에 쓴다.** 파일에 `<key>.<OS>` 줄이 있으면 그쪽이 계속 이길 수 있다 — GUI write-back
        // 경로 전체(updateConfigText·removeConfigLines·parseKeybindLine)가 접미를 모르기 때문이다.
        // 한 곳만 접미를 알게 하면 오히려 값이 사라진다(리뷰 실측: 기본 줄의 값을 접미 줄에 덮어썼다).
        // 알려진 한계로 문서에 적었다 — docs/configuration.md "OS별 값".
        try updates.append(aa, .{ .key = k, .value = v });
    }
    return loader.updateConfigText(allocator, original, updates.items);
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
    cfg.theme.syntax[@intFromEnum(theme.SyntaxRole.keyword)] = "#c678dd"; // SC4: 구문 색도 같은 대칭(수동 emit ↔ 수동 파싱)
    cfg.theme.syntax[@intFromEnum(theme.SyntaxRole.type_name)] = "#56b6c2"; // 키가 `type`인 예외 역할도 왕복하는가
    cfg.cursor.color = "#ff5555"; // nullable 색 round-trip(loader 수동 핸들러 ↔ serialize 수동 emit) 대칭 검증
    cfg.cursor.text = "#101010";
    cfg.blink_text = true;
    cfg.ambiguous_width = .wide;
    cfg.emoji_width = .narrow; // 기본 wide의 반대값 — 기본값 누수로 통과하는 가짜 green 방지(round-trip 강제)
    cfg.bold_is_bright = true;
    cfg.input.page_keys = .passthrough;
    cfg.input.shift_enter = .native;
    cfg.input.ime_enter = .commit_only;
    cfg.window_padding_top = 1;
    cfg.window_padding_right = 2;
    cfg.window_padding_bottom = 3;
    cfg.window_padding_left = 4;
    cfg.term = "xterm-256color";
    cfg.env = &.{ "EDITOR=nvim", "MY_VAR=a b c" }; // 내부 공백 보존도 함께 검증
    cfg.shell.command = "/opt/homebrew/bin/fish";
    cfg.shell.args = &.{ "-i", "-l" };
    cfg.scrollback.lines = 5000;
    cfg.bell.audible = false;
    cfg.shell_integration.ssh = true;
    // 셋 다 기본과 다른 값으로 — 기본값 누수로 통과하는 가짜 green 방지(위 sidebar.width와 같은 규율).
    cfg.ssh.server_alive_interval = 30;
    cfg.ssh.server_alive_count_max = 5;
    cfg.ssh.reconnect = false;
    cfg.sidebar.show_branch = false;
    cfg.sidebar.show_folder = false;
    cfg.sidebar.width_pt = 250; // 기본 180과 다른 값 — u32 키(sidebar.width) round-trip 대칭 강제(기본값 누수 가짜 green 방지)
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
    try std.testing.expectEqualStrings("#ff5555", got.cursor.color.?);
    try std.testing.expectEqualStrings("#c678dd", got.theme.syntax[@intFromEnum(theme.SyntaxRole.keyword)].?);
    try std.testing.expectEqualStrings("#56b6c2", got.theme.syntax[@intFromEnum(theme.SyntaxRole.type_name)].?);
    // 안 정한 역할은 줄을 만들지 않는다(null=파생 — 파일이 부풀지 않는다).
    try std.testing.expect(got.theme.syntax[@intFromEnum(theme.SyntaxRole.string)] == null);
    try std.testing.expectEqualStrings("#101010", got.cursor.text.?);
    try std.testing.expectEqual(true, got.blink_text);
    try std.testing.expectEqual(theme.AmbiguousWidth.wide, got.ambiguous_width);
    try std.testing.expectEqual(theme.EmojiWidth.narrow, got.emoji_width);
    try std.testing.expectEqual(true, got.bold_is_bright);
    try std.testing.expectEqual(theme.PageKeys.passthrough, got.input.page_keys);
    try std.testing.expectEqual(theme.ShiftEnter.native, got.input.shift_enter);
    try std.testing.expectEqual(theme.ImeEnter.commit_only, got.input.ime_enter);
    try std.testing.expectEqual(@as(u32, 1), got.window_padding_top);
    try std.testing.expectEqual(@as(u32, 2), got.window_padding_right);
    try std.testing.expectEqual(@as(u32, 3), got.window_padding_bottom);
    try std.testing.expectEqual(@as(u32, 4), got.window_padding_left);
    try std.testing.expectEqualStrings("xterm-256color", got.term);
    try std.testing.expectEqual(@as(usize, 2), got.env.len);
    try std.testing.expectEqualStrings("EDITOR=nvim", got.env[0]);
    try std.testing.expectEqualStrings("MY_VAR=a b c", got.env[1]); // env.<KEY> round-trip + 내부 공백 보존
    try std.testing.expectEqualStrings("/opt/homebrew/bin/fish", got.shell.command);
    try std.testing.expectEqual(@as(usize, 2), got.shell.args.len);
    try std.testing.expectEqualStrings("-i", got.shell.args[0]);
    try std.testing.expectEqualStrings("-l", got.shell.args[1]); // shell.args join↔split round-trip
    try std.testing.expectEqual(@as(u32, 5000), got.scrollback.lines);
    try std.testing.expectEqual(false, got.bell.audible);
    try std.testing.expectEqual(true, got.shell_integration.ssh);
    try std.testing.expectEqual(@as(u32, 30), got.ssh.server_alive_interval);
    try std.testing.expectEqual(@as(u32, 5), got.ssh.server_alive_count_max);
    try std.testing.expectEqual(false, got.ssh.reconnect);
    try std.testing.expectEqual(false, got.sidebar.show_branch);
    try std.testing.expectEqual(false, got.sidebar.show_folder);
    try std.testing.expectEqual(@as(u32, 250), got.sidebar.width_pt);
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

test "round-trip: quick-terminal.* 기본값(width sentinel 0 포함)은 직렬화→재파싱 시 diagnostic 없음 (code-review 후속)" {
    // GUI write-back이 기본 config를 저장→reload할 때, sentinel 기본값(quick-terminal.width=0='height 따라감')이
    // range 밖이면 spurious diagnostic이 났다(width range 하한을 0으로 수정). quick-terminal.* 키가 깨끗이
    // round-trip되는지 좁게 검증한다(빈 문자열 기본값 workspace.root/shell.command은 full-dump의 별개 이슈 —
    // override-only 직렬화 S0-1b에서 다룬다). 새 quick-terminal sentinel이 range 밖이면 이 테스트가 잡는다.
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const kvs = try configKeyValues(arena.allocator(), .{}); // 전 필드 기본(width_fraction=0 포함)
    const text = try loader.updateConfigText(a, "", kvs);
    defer a.free(text);
    var parsed = try loader.parse(a, text);
    defer parsed.deinit();
    for (parsed.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "quick-terminal") != null) {
            std.debug.print("기본 round-trip에서 quick-terminal diagnostic: {s}\n", .{d.message});
            return error.UnexpectedQuickTerminalDiagnostic;
        }
    }
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

test "updateForKeys: 넘긴 키만 현재값으로 부분 갱신, 나머지/주석 보존, 비-스키마 키 스킵 (S0-1b)" {
    const a = std.testing.allocator;
    var cfg: theme.Config = .{};
    cfg.cursor.blink = false; // 기본 true에서 변경
    cfg.font.size = 16; // 변경했지만 키를 안 넘기면 안 써져야 함(override-only)

    const removed_settings =
        "workspace.restore-claude = true\n" ++
        "workspace.restore-codex = false\n" ++
        "notifications.agent-complete = true\n";
    const original = "# 사용자 주석\ncursor.blink = true\nfont.family = Menlo\n" ++ removed_settings;
    // cursor.blink만 갱신 요청(+ configKeyValues에 없는 키 keybind는 스킵돼야 — keybind/preset/오타는 valueForKey null)
    const text = try updateForKeys(a, original, cfg, &.{ "cursor.blink", "keybind" });
    defer a.free(text);

    var p = try loader.parse(a, text);
    defer p.deinit();
    try std.testing.expectEqual(false, p.config.cursor.blink); // 갱신됨
    try std.testing.expectEqual(@as(f32, 14), p.config.font.size); // 안 넘김 → 텍스트에 없음 → 기본 14(override-only)
    try std.testing.expectEqualStrings("Menlo", p.config.font.family); // 원본 다른 줄 보존
    try std.testing.expect(std.mem.indexOf(u8, text, "# 사용자 주석") != null); // 주석 보존
    try std.testing.expect(std.mem.indexOf(u8, text, removed_settings) != null); // 제거된 미지 키도 사용자 원문 그대로 보존
    try std.testing.expect(std.mem.indexOf(u8, text, "keybind") == null); // configKeyValues에 없는 키는 스킵(안 써짐)
}
