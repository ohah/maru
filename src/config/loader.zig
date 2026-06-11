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
    diagnostics: []const Diagnostic,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }

    /// 파싱된 키바인딩으로 resolver를 만든다(app 바인딩만 — terminal 바인딩 config는 후속).
    pub fn keyBindingResolver(self: Parsed) keybinding.KeyBindingResolver {
        return .{ .app_bindings = self.keybindings };
    }
};

const max_font_size: f32 = 512.0;
const min_font_size: f32 = 1.0;

/// config 텍스트를 raw Config로 파싱한다(파일시스템 무관, 순수). 알 수 없는 key/잘못된 값은
/// 기본값 유지 + diagnostic. OOM만 에러.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) LoadError!Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var config: theme.Config = .{};
    var diags: std.ArrayList(Diagnostic) = .empty;
    var binds: std.ArrayList(keybinding.AppBinding) = .empty;

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

        try applyKey(a, &config, &binds, &diags, line_no, key, value);
    }

    return .{
        .arena = arena,
        .config = config,
        .keybindings = try binds.toOwnedSlice(a),
        .diagnostics = try diags.toOwnedSlice(a),
    };
}

fn applyKey(
    a: std.mem.Allocator,
    config: *theme.Config,
    binds: *std.ArrayList(keybinding.AppBinding),
    diags: *std.ArrayList(Diagnostic),
    line_no: usize,
    key: []const u8,
    value: []const u8,
) LoadError!void {
    if (std.mem.eql(u8, key, "keybind")) {
        return applyKeybind(a, binds, diags, line_no, value);
    }
    if (std.mem.eql(u8, key, "font.family")) {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            try diags.append(a, .{ .line = line_no, .message = "font.family가 비어 있음 — 기본값 유지" });
            return;
        }
        config.font.family = try a.dupe(u8, trimmed);
    } else if (std.mem.eql(u8, key, "font.size")) {
        const size = std.fmt.parseFloat(f32, value) catch {
            try diags.append(a, .{ .line = line_no, .message = "font.size가 숫자가 아님 — 기본값 유지" });
            return;
        };
        if (!(size >= min_font_size and size <= max_font_size)) {
            try diags.append(a, .{ .line = line_no, .message = "font.size가 1~512 범위 밖 — 기본값 유지" });
            return;
        }
        config.font.size = size;
    } else if (std.mem.eql(u8, key, "theme.background")) {
        config.theme.background = try dupValidColor(a, diags, line_no, key, value, config.theme.background);
    } else if (std.mem.eql(u8, key, "theme.foreground")) {
        config.theme.foreground = try dupValidColor(a, diags, line_no, key, value, config.theme.foreground);
    } else if (std.mem.eql(u8, key, "theme.cursor")) {
        config.theme.cursor = try dupValidColor(a, diags, line_no, key, value, config.theme.cursor);
    } else if (std.mem.eql(u8, key, "theme.selection")) {
        config.theme.selection = try dupValidColor(a, diags, line_no, key, value, config.theme.selection);
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
    } else {
        try diags.append(a, .{ .line = line_no, .message = "알 수 없는 key — 무시" });
    }
}

/// `keybind = <chord> = <action>` 한 줄을 AppBinding으로. chord는 KeyChord.parse(사람 표기 —
/// 예 `Cmd+T`, `Ctrl+Cmd+1`), action은 parseAction. 오류는 diagnostic(forgiving). 같은 chord가 이미
/// 있으면 첫 줄을 살리고 무시한다 — resolver.validate가 중복으로 실패하지 않게 파싱에서 미리 dedup.
fn applyKeybind(
    a: std.mem.Allocator,
    binds: *std.ArrayList(keybinding.AppBinding),
    diags: *std.ArrayList(Diagnostic),
    line_no: usize,
    value: []const u8,
) LoadError!void {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse {
        try diags.append(a, .{ .line = line_no, .message = "keybind는 `<조합> = <action>` 형식이어야 한다" });
        return;
    };
    const chord_str = std.mem.trim(u8, value[0..eq], &std.ascii.whitespace);
    const action_str = std.mem.trim(u8, value[eq + 1 ..], &std.ascii.whitespace);

    const chord = keybinding.KeyChord.parse(chord_str) catch {
        try diags.append(a, .{ .line = line_no, .message = "키 조합을 못 읽음(예: Cmd+T, Ctrl+Cmd+1) — 무시" });
        return;
    };
    const act = action_mod.parseAction(action_str) orelse {
        try diags.append(a, .{ .line = line_no, .message = "알 수 없는 action(new_tab/close_tab/next_tab/previous_tab/select_tab:N) — 무시" });
        return;
    };
    for (binds.items) |existing| {
        if (existing.chord.eql(chord)) {
            try diags.append(a, .{ .line = line_no, .message = "이미 바인딩된 키 조합 — 무시(첫 줄 우선)" });
            return;
        }
    }
    try binds.append(a, .{ .chord = chord, .action = act });
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

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

/// 빈 기본 결과(파일 없음/HOME 없음 등). config 텍스트를 안 읽었으므로 arena도 비어 있다.
fn emptyDefault(allocator: std.mem.Allocator) Parsed {
    return .{ .arena = std.heap.ArenaAllocator.init(allocator), .config = .{}, .keybindings = &.{}, .diagnostics = &.{} };
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

/// 기본 경로에서 config를 로드한다(경로 해석 + 파일 읽기 + 파싱). dev session이 시작 시 호출하는
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
        \\theme.background = #001122
        \\theme.foreground = #ffeedd
        \\cursor.shape = bar
        \\cursor.blink = false
    );
    defer p.deinit();
    try std.testing.expectEqualStrings("JetBrains Mono", p.config.font.family);
    try std.testing.expectEqual(@as(f32, 16), p.config.font.size);
    try std.testing.expectEqualStrings("#001122", p.config.theme.background);
    try std.testing.expectEqualStrings("#ffeedd", p.config.theme.foreground);
    try std.testing.expectEqual(theme.CursorShape.bar, p.config.cursor.shape);
    try std.testing.expectEqual(false, p.config.cursor.blink);
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
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
        \\missing equals
    );
    defer p.deinit();
    // 잘못된 값은 전부 기본값 유지.
    try std.testing.expectEqual(defaults.font.size, p.config.font.size);
    try std.testing.expectEqual(defaults.cursor.shape, p.config.cursor.shape);
    try std.testing.expectEqual(defaults.cursor.blink, p.config.cursor.blink);
    try std.testing.expectEqualStrings(defaults.theme.background, p.config.theme.background);
    // 6개 문제 줄 각각 diagnostic(누락 '=' 포함).
    try std.testing.expectEqual(@as(usize, 6), p.diagnostics.len);
}

test "parse: resolved appearance never fails on parsed config (values pre-validated)" {
    var p = try parse(std.testing.allocator,
        \\font.size = 999
        \\theme.cursor = #zzzzzz
    );
    defer p.deinit();
    // 잘못된 값은 default로 걸러졌으므로 resolve가 성공해야 한다.
    _ = try appearance.resolve(p.config);
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

test "parse: keybindings empty when none configured; appearance keys unaffected" {
    var p = try parse(std.testing.allocator, "font.size = 13\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.keybindings.len);
    try std.testing.expectEqual(@as(f32, 13), p.config.font.size);
}
