//! 외부 포매터(tooling §8.2t, 계획 docs/plans/editor-external-formatter.md) — 순수 층: 설정 값 읽기, 저장소 설정 감지,
//! 실행 파일 고르기, argv, 결과 본문을 편집 덩어리로 바꾸기. 파일 시스템은 호출자가 넘긴 `fs`(`exists`·`isExecutable`·`read`)로만
//! 본다 — 실행·시한·신뢰는 플랫폼 층(`format_process`·`editor/format.zig`)이 한다.
//!
//! **저장소가 고른 포매터를 따른다**(2026-10-12 사용자 결정): `auto` 면 문서 폴더에서 저장소 루트까지 올라가며 가장 가까운 Prettier
//! 설정을 찾고, 있으면 Prettier 다(실행 파일이 없어도 Prettier — 언어 서버로 물러서면 다른 스타일로 바꾼다). 실행 파일은 가장 가까운
//! `node_modules/.bin/prettier`, 없으면 PATH(호출자).

const std = @import("std");
const language = @import("language.zig");
const delta = @import("delta.zig");
const diff = @import("diff.zig");
const edit_ops = @import("ops/edit_ops.zig");
const config_theme = @import("../../config/theme.zig");

/// 설정 `editor.formatter.<언어>` 의 값 — 단일 출처는 설정 층(`config/theme.zig` `FormatterChoice`).
pub const Choice = config_theme.FormatterChoice;

pub fn parseChoice(text: []const u8) ?Choice {
    return std.meta.stringToEnum(Choice, std.mem.trim(u8, text, " \t"));
}

/// 그 문서의 문법에 걸린 설정 값(설정의 언어 칸 — 문법 이름으로 찾는다; `none` 은 `auto`).
pub fn choiceFor(choices: []const Choice, g: language.Grammar) Choice {
    if (g == .none) return .auto;
    const i = config_theme.formatterLanguageIndex(@tagName(g)) orelse return .auto;
    return choices[i];
}

/// 외부 포매터의 종류(EF2 가 ruff·black·사용자 명령을 더한다).
pub const Kind = enum {
    prettier,

    pub fn displayName(self: Kind) []const u8 {
        return switch (self) {
            .prettier => "Prettier",
        };
    }

    /// PATH·`node_modules/.bin` 에서 찾을 실행 파일 이름.
    pub fn exeName(self: Kind) []const u8 {
        return switch (self) {
            .prettier => "prettier",
        };
    }
};

/// Prettier 가 기본으로 다루는 문법 — `auto` 가 Prettier 를 감지하는 문법이다.
pub fn prettierHandles(g: language.Grammar) bool {
    return switch (g) {
        .javascript, .typescript, .tsx, .json, .css, .html, .markdown => true,
        else => false,
    };
}

/// Prettier 설정 파일(공식 문서의 이름 목록). `package.json` 의 `"prettier"` 키는 따로 본다.
pub const prettier_config_names = [_][]const u8{
    ".prettierrc",
    ".prettierrc.json",
    ".prettierrc.json5",
    ".prettierrc.yaml",
    ".prettierrc.yml",
    ".prettierrc.toml",
    ".prettierrc.js",
    ".prettierrc.cjs",
    ".prettierrc.mjs",
    ".prettierrc.ts",
    ".prettierrc.cts",
    ".prettierrc.mts",
    "prettier.config.js",
    "prettier.config.cjs",
    "prettier.config.mjs",
    "prettier.config.ts",
    "prettier.config.cts",
    "prettier.config.mts",
};

/// 읽을 `package.json` 의 상한 — 넘으면 `"prettier"` 키를 안 본다(설정 파일이 아니다).
pub const max_package_json_bytes: usize = 1 << 20;

/// `package.json` 본문의 최상위에 `"prettier"` 키가 있나(값은 무엇이든 — 설정 객체 또는 공유 설정 이름).
pub fn packageJsonHasPrettier(allocator: std.mem.Allocator, text: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return false;
    defer parsed.deinit();
    return switch (parsed.value) {
        .object => |o| o.contains("prettier"),
        else => false,
    };
}

/// `doc_dir` 에서 `root` 까지(둘 다 포함) 위로 올라가는 폴더들. `doc_dir` 가 `root` 아래가 아니면 `root` 하나만.
pub const DirsUp = struct {
    cur: ?[]const u8,
    root: []const u8,

    pub fn init(doc_dir: []const u8, root: []const u8) DirsUp {
        const r = trimSlash(root);
        const d = trimSlash(doc_dir);
        return .{ .cur = if (isUnder(d, r)) d else r, .root = r };
    }

    pub fn next(self: *DirsUp) ?[]const u8 {
        const d = self.cur orelse return null;
        if (std.mem.eql(u8, d, self.root)) {
            self.cur = null;
        } else {
            const parent = std.fs.path.dirname(d) orelse self.root;
            self.cur = if (isUnder(parent, self.root)) parent else self.root;
        }
        return d;
    }
};

fn trimSlash(p: []const u8) []const u8 {
    if (p.len > 1 and p[p.len - 1] == '/') return p[0 .. p.len - 1];
    return p;
}

/// `path` 가 `root` 자신이거나 그 아래인가(경로 성분 경계).
fn isUnder(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (std.mem.eql(u8, root, "/")) return path.len > 1 and path[0] == '/';
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

/// 감지 결과의 설정 파일(저장소 루트 기준 상대 경로를 `out` 에) — 없으면 `null`.
/// `fs` 는 `exists(path) bool` 과 `read(path, buf) ?[]const u8`(상한 `buf.len`)를 가진다.
pub fn findPrettierConfig(allocator: std.mem.Allocator, fs: anytype, doc_dir: []const u8, root: []const u8, out: []u8) ?[]const u8 {
    var dirs = DirsUp.init(doc_dir, root);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (dirs.next()) |dir| {
        for (prettier_config_names) |name| {
            const p = join(&path_buf, dir, name) orelse continue;
            if (fs.exists(p)) return relative(out, root, p);
        }
        const pj = join(&path_buf, dir, "package.json") orelse continue;
        if (!fs.exists(pj)) continue;
        const text = fs.read(pj, max_package_json_bytes) orelse continue;
        defer fs.freeRead(text);
        if (packageJsonHasPrettier(allocator, text)) return relative(out, root, pj);
    }
    return null;
}

/// 가장 가까운 `node_modules/.bin/<exe>`(문서 폴더에서 루트까지) — 실행할 수 있는 파일만. 없으면 `null`(호출자가 PATH 를 본다).
pub fn findLocalBin(fs: anytype, doc_dir: []const u8, root: []const u8, exe: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var dirs = DirsUp.init(doc_dir, root);
    while (dirs.next()) |dir| {
        const p = std.fmt.bufPrint(out, "{s}/node_modules/.bin/{s}", .{ if (std.mem.eql(u8, dir, "/")) "" else dir, exe }) catch continue;
        if (fs.isExecutable(p)) return p;
    }
    return null;
}

fn join(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ if (std.mem.eql(u8, dir, "/")) "" else dir, name }) catch null;
}

fn relative(out: []u8, root: []const u8, path: []const u8) ?[]const u8 {
    const r = trimSlash(root);
    const rel = if (std.mem.eql(u8, r, "/")) path[1..] else if (path.len > r.len + 1) path[r.len + 1 ..] else path;
    if (rel.len > out.len) return null;
    @memcpy(out[0..rel.len], rel);
    return out[0..rel.len];
}

/// 그 문서를 무엇으로 포맷하나.
pub const Plan = union(enum) {
    /// 언어 서버(지금 동작).
    lsp,
    /// 포맷하지 않는다(설정 `off`).
    off,
    /// 외부 포매터. `config` 는 감지한 설정 파일(루트 기준 — 설정으로 고른 것이면 없을 수 있다).
    external: struct { kind: Kind, config: ?[]const u8 },
};

/// 설정 값과 감지 결과로 정한다. `detected` 는 그 문법에서 감지한 Prettier 설정(`auto` 일 때만 쓴다).
pub fn plan(choice: Choice, g: language.Grammar, detected: ?[]const u8) Plan {
    return switch (choice) {
        .lsp => .lsp,
        .off => .off,
        .prettier => .{ .external = .{ .kind = .prettier, .config = detected } },
        .auto => if (prettierHandles(g) and detected != null) .{ .external = .{ .kind = .prettier, .config = detected } } else .lsp,
    };
}

/// 실행할 argv(셸 없이). `path` 는 문서의 경로 — 포매터가 그 경로로 설정·ignore·파서를 고른다.
pub fn argv(kind: Kind, exe: []const u8, path: []const u8) [3][]const u8 {
    return switch (kind) {
        .prettier => .{ exe, "--stdin-filepath", path },
    };
}

/// 포매터 결과 본문(`new`)을 지금 본문(`old`)에 대한 편집으로 — 줄 대응의 덩어리마다 하나, 덩어리 안은 같은 머리·꼬리를 떼어 낸다
/// (`edit_ops.reloadChange`). 덩어리 하나로 합치면 그 사이의 커서가 첫 변경 자리로 끌려간다. 줄은 끝의 개행까지 한 줄이다(CRLF 를
/// 그대로 견준다). 같으면 빈 조각, 대응을 못 만들 만큼 크면 문서 하나짜리 편집 하나(`reloadChange`). `text` 는 `new` 를 빌린다.
pub fn changesFor(allocator: std.mem.Allocator, old: []const u8, new: []const u8) error{OutOfMemory}![]delta.Change {
    if (std.mem.eql(u8, old, new)) return allocator.alloc(delta.Change, 0);
    const old_lines = try splitKeep(allocator, old);
    defer allocator.free(old_lines);
    const new_lines = try splitKeep(allocator, new);
    defer allocator.free(new_lines);
    const hs = try diff.hunks(allocator, old_lines, new_lines, .{}) orelse {
        const one = try allocator.alloc(delta.Change, 1);
        one[0] = edit_ops.reloadChange(old, new);
        return one;
    };
    defer allocator.free(hs);
    var out: std.ArrayList(delta.Change) = .empty;
    errdefer out.deinit(allocator);
    for (hs) |h| {
        const os = offsetOf(old, old_lines, h.old_start);
        const oe = offsetOf(old, old_lines, h.old_end);
        const ns = offsetOf(new, new_lines, h.new_start);
        const ne = offsetOf(new, new_lines, h.new_end);
        const c = edit_ops.reloadChange(old[os..oe], new[ns..ne]);
        if (c.start == c.end and c.text.len == 0) continue;
        try out.append(allocator, .{ .start = os + c.start, .end = os + c.end, .text = c.text });
    }
    return out.toOwnedSlice(allocator);
}

/// 줄마다 끝의 개행까지(마지막 줄은 개행이 없을 수 있다). 빈 본문은 줄 없음.
fn splitKeep(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const end = if (nl) |i| i + 1 else text.len;
        try lines.append(allocator, text[start..end]);
        start = end;
    }
    return lines.toOwnedSlice(allocator);
}

/// `i` 번째 줄의 시작 바이트(`i == lines.len` 이면 본문 끝).
fn offsetOf(text: []const u8, lines: []const []const u8, i: usize) usize {
    if (i >= lines.len) return text.len;
    return @intFromPtr(lines[i].ptr) - @intFromPtr(text.ptr);
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 판정자의 가짜 파일 시스템 — 있는 파일과 그 내용, 실행 파일.
const FakeFs = struct {
    files: []const struct { path: []const u8, text: []const u8 = "", exec: bool = false },

    fn find(self: FakeFs, p: []const u8) ?usize {
        for (self.files, 0..) |f, i| if (std.mem.eql(u8, f.path, p)) return i;
        return null;
    }
    pub fn exists(self: FakeFs, p: []const u8) bool {
        return self.find(p) != null;
    }
    pub fn isExecutable(self: FakeFs, p: []const u8) bool {
        const i = self.find(p) orelse return false;
        return self.files[i].exec;
    }
    pub fn read(self: FakeFs, p: []const u8, limit: usize) ?[]const u8 {
        const i = self.find(p) orelse return null;
        if (self.files[i].text.len > limit) return null;
        return self.files[i].text;
    }
    pub fn freeRead(_: FakeFs, _: []const u8) void {}
};

test "EXF1 설정 값과 계획 — auto 는 Prettier 문법에서 감지한 설정이 있을 때만 Prettier, 아니면 언어 서버; lsp·off·prettier 는 감지와 무관 (tooling §8.2t)" {
    try testing.expectEqual(Choice.auto, parseChoice("auto").?);
    try testing.expectEqual(Choice.prettier, parseChoice(" prettier ").?);
    try testing.expectEqual(Choice.off, parseChoice("off").?);
    try testing.expectEqual(Choice.lsp, parseChoice("lsp").?);
    try testing.expect(parseChoice("Prettier") == null);
    try testing.expect(parseChoice("") == null);
    try testing.expect(parseChoice("ruff") == null); // EF2
    try testing.expect(plan(.auto, .typescript, ".prettierrc") == .external);
    try testing.expectEqualStrings(".prettierrc", plan(.auto, .tsx, ".prettierrc").external.config.?);
    try testing.expect(plan(.auto, .typescript, null) == .lsp);
    try testing.expect(plan(.auto, .python, ".prettierrc") == .lsp); // Prettier 가 다루지 않는 문법
    try testing.expect(plan(.lsp, .typescript, ".prettierrc") == .lsp);
    try testing.expect(plan(.off, .typescript, ".prettierrc") == .off);
    try testing.expect(plan(.prettier, .python, null) == .external); // 적었으면 감지 없이
    for ([_]language.Grammar{ .javascript, .typescript, .tsx, .json, .css, .html, .markdown }) |g| try testing.expect(prettierHandles(g));
    for ([_]language.Grammar{ .none, .zig, .c, .cpp, .python, .go, .rust, .java, .ruby, .php, .kotlin, .bash }) |g| try testing.expect(!prettierHandles(g));
    const av = argv(.prettier, "/r/node_modules/.bin/prettier", "/r/src/a.ts");
    try testing.expectEqualStrings("/r/node_modules/.bin/prettier", av[0]);
    try testing.expectEqualStrings("--stdin-filepath", av[1]);
    try testing.expectEqualStrings("/r/src/a.ts", av[2]);
}

test "EXF2 Prettier 감지 — 문서 폴더에서 루트까지 가장 가까운 설정(이름 목록·package.json 의 prettier 키), 루트 밖은 안 보고, 실행 파일은 가장 가까운 node_modules/.bin" {
    const a = testing.allocator;
    const fs: FakeFs = .{
        .files = &.{
            .{ .path = "/repo/.prettierrc.json" },
            .{ .path = "/repo/pkg/package.json", .text = "{\"name\":\"p\",\"prettier\":\"@acme/prettier-config\"}" },
            .{ .path = "/repo/other/package.json", .text = "{\"name\":\"o\",\"devDependencies\":{\"prettier\":\"3\"}}" }, // 의존성은 설정이 아니다
            .{ .path = "/outside/.prettierrc" },
            .{ .path = "/repo/node_modules/.bin/prettier", .exec = true },
            .{ .path = "/repo/pkg/node_modules/.bin/prettier", .exec = false }, // 실행 못 함 — 건너뛴다
        },
    };
    var out: [256]u8 = undefined;
    try testing.expectEqualStrings("pkg/package.json", findPrettierConfig(a, fs, "/repo/pkg/src", "/repo", &out).?);
    try testing.expectEqualStrings(".prettierrc.json", findPrettierConfig(a, fs, "/repo/other/src", "/repo", &out).?); // 의존성뿐 — 위로
    try testing.expectEqualStrings(".prettierrc.json", findPrettierConfig(a, fs, "/repo", "/repo/", &out).?);
    // 루트 밖 문서 폴더는 루트만 본다(`/outside` 는 안 본다).
    try testing.expectEqualStrings(".prettierrc.json", findPrettierConfig(a, fs, "/outside", "/repo", &out).?);
    const none: FakeFs = .{ .files = &.{.{ .path = "/outside/.prettierrc" }} };
    try testing.expect(findPrettierConfig(a, none, "/repo/x", "/repo", &out) == null);
    var bin: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/repo/node_modules/.bin/prettier", findLocalBin(fs, "/repo/pkg/src", "/repo", "prettier", &bin).?);
    try testing.expect(findLocalBin(none, "/repo/pkg", "/repo", "prettier", &bin) == null);
    // package.json 키 판정.
    try testing.expect(packageJsonHasPrettier(a, "{\"prettier\":{\"semi\":false}}"));
    try testing.expect(!packageJsonHasPrettier(a, "{\"dependencies\":{\"prettier\":\"3\"}}"));
    try testing.expect(!packageJsonHasPrettier(a, "not json"));
    try testing.expect(!packageJsonHasPrettier(a, "[\"prettier\"]"));
    // 위로 올라가기 — 경로 성분 경계(`/repox` 는 `/repo` 아래가 아니다).
    var it = DirsUp.init("/repo/a/b", "/repo");
    try testing.expectEqualStrings("/repo/a/b", it.next().?);
    try testing.expectEqualStrings("/repo/a", it.next().?);
    try testing.expectEqualStrings("/repo", it.next().?);
    try testing.expect(it.next() == null);
    var it2 = DirsUp.init("/repox/a", "/repo");
    try testing.expectEqualStrings("/repo", it2.next().?);
    try testing.expect(it2.next() == null);
}

test "EXF3 결과 본문을 덩어리마다 편집으로 — 떨어진 두 곳은 둘이고 그 사이 커서는 제자리, 덩어리 안은 같은 머리·꼬리를 뗀다; 같으면 없음; CRLF·끝 개행 (tooling §8.2t)" {
    const a = testing.allocator;
    const old = "const a=1\nkeep(1)\nkeep(2)\nconst b=2\n";
    const new = "const a = 1;\nkeep(1)\nkeep(2)\nconst b = 2;\n";
    const cs = try changesFor(a, old, new);
    defer a.free(cs);
    try testing.expectEqual(@as(usize, 2), cs.len);
    try testing.expect((delta.Delta{ .changes = cs }).isWellFormed());
    // 적용하면 결과와 같다.
    var applied: std.ArrayList(u8) = .empty;
    defer applied.deinit(a);
    var at: usize = 0;
    for (cs) |c| {
        try applied.appendSlice(a, old[at..c.start]);
        try applied.appendSlice(a, c.text);
        at = c.end;
    }
    try applied.appendSlice(a, old[at..]);
    try testing.expectEqualStrings(new, applied.items);
    // 사이 줄(`keep(2)` 안)의 커서는 움직이지 않는다 — 앞 덩어리의 길이 변화만큼만 민다.
    const caret = std.mem.indexOf(u8, old, "(2)").?;
    const want = std.mem.indexOf(u8, new, "(2)").?;
    try testing.expectEqual(want, delta.mapOffset(.{ .changes = cs }, caret));
    // 덩어리 안의 머리·꼬리를 뗐다 — 첫 편집은 `const a` 뒤에서 시작한다.
    try testing.expect(cs[0].start >= "const a".len);
    {
        const same = try changesFor(a, old, old);
        defer a.free(same);
        try testing.expectEqual(@as(usize, 0), same.len);
    }
    {
        // CRLF 를 그대로 견준다 — 줄 끝만 바뀐 것도 편집이다.
        const crlf = try changesFor(a, "a\r\nb\r\n", "a\nb\r\n");
        defer a.free(crlf);
        try testing.expectEqual(@as(usize, 1), crlf.len);
        try testing.expectEqualStrings("", crlf[0].text);
        try testing.expectEqual(@as(usize, 1), crlf[0].start);
        try testing.expectEqual(@as(usize, 2), crlf[0].end);
    }
    {
        // 끝 개행을 더했다.
        const tail = try changesFor(a, "x", "x\n");
        defer a.free(tail);
        try testing.expectEqual(@as(usize, 1), tail.len);
        try testing.expectEqualStrings("\n", tail[0].text);
    }
    try testing.checkAllAllocationFailures(a, struct {
        fn f(al: std.mem.Allocator) !void {
            const r = try changesFor(al, "const a=1\nk\nconst b=2\n", "const a = 1;\nk\nconst b = 2;\n");
            al.free(r);
        }
    }.f, .{});
}

test "EXF4 설정의 언어 칸은 편집기 문법 이름과 같다(`none` 빼고) — 문법을 더하면 설정 칸도; 칸으로 그 문법의 값을 찾는다" {
    const fields = @typeInfo(language.Grammar).@"enum".fields;
    try testing.expectEqual(fields.len - 1, config_theme.formatter_languages.len);
    inline for (fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "none")) continue;
        try testing.expect(config_theme.formatterLanguageIndex(f.name) != null);
    }
    var choices: [config_theme.formatter_languages.len]Choice = @splat(.auto);
    choices[config_theme.formatterLanguageIndex("typescript").?] = .off;
    try testing.expectEqual(Choice.off, choiceFor(&choices, .typescript));
    try testing.expectEqual(Choice.auto, choiceFor(&choices, .tsx));
    try testing.expectEqual(Choice.auto, choiceFor(&choices, .none));
}
