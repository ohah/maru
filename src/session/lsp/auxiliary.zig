//! 보조 언어 서버(docs/editor-surface-tooling.md §8.2u — 계획 docs/plans/editor-auxiliary-servers.md)의 순수 부분: 문법 → 보조 서버 **표**와
//! 저장소 설정 **감지**. 주 서버 표(`servers.candidatesFor` — 후보 중 하나)와 달리 보조 서버는 주 서버와 **함께** 뜬다. 진단과 code action 만
//! 맡는다(2026-10-13 사용자 결정).
//!
//! 저장소 설정이 있을 때만 띄운다(사용자 결정) — 문서 폴더에서 저장소 루트까지 그 도구의 설정을 찾는다. 찾기·실행 파일 폴더는 외부
//! 포매터(§8.2t)의 함수를 그대로 쓴다(두 벌이면 한쪽만 낡는다).

const std = @import("std");
const language = @import("../editor/language.zig");
const servers = @import("servers.zig");
const external_format = @import("../editor/external_format.zig");

pub const Tool = enum {
    ruff,
    eslint,
    biome,
    oxlint,

    /// 사람에게 보이는 이름(정보 명령).
    pub fn displayName(self: Tool) []const u8 {
        return switch (self) {
            .ruff => "ruff",
            .eslint => "ESLint",
            .biome => "Biome",
            .oxlint => "oxlint",
        };
    }
};

pub const Auxiliary = struct {
    tool: Tool,
    server: servers.Server,
    /// 저장소 안에서 먼저 볼 실행 파일 폴더(문서 폴더에서 루트까지 각 폴더 아래) — 외부 포매터와 같은 자리.
    bin_dirs: []const []const u8,
    /// pull 진단만 내는 서버(ESLint — 2026-10-13 실측: push 를 40 초 기다려도 오지 않는다). 그 클라이언트에만 `textDocument.diagnostic` 을
    /// 알리고 문서를 보낼 때마다 묻는다.
    pull_diagnostics: bool = false,
    /// `workspace/configuration` 에 이 서버의 고정 설정으로 답한다(ESLint — 설정 객체가 없으면 진단 요청이 실패한다). `settingsJson` 이 만든다.
    answers_configuration: bool = false,
    /// 그 문법 안에서도 이 확장자의 파일에만 붙는다(빈 목록 = 그 문법의 파일 전부). Biome 의 CSS — 문법 `.css` 는 `scss`·`less` 도 덮지만
    /// Biome 은 그 둘을 다루지 않는다(languageId 를 `scss`·`less` 로 보내면 진단이 없고 `css` 로 보내면 거짓 구문 오류 — 2026-10-13 실측).
    extensions: []const []const u8 = &.{},

    /// 그 경로의 문서에 붙나(`extensions` — 대소문자 무시).
    pub fn appliesTo(self: Auxiliary, path: []const u8) bool {
        if (self.extensions.len == 0) return true;
        const ext = std.fs.path.extension(path);
        if (ext.len < 2) return false;
        for (self.extensions) |e| if (std.ascii.eqlIgnoreCase(ext[1..], e)) return true;
        return false;
    }
};

const ruff_args = [_][]const u8{"server"};
const stdio_args = [_][]const u8{"--stdio"};
const eslint: Auxiliary = .{
    .tool = .eslint,
    // `language_id` 는 쓰지 않는다 — 문서마다 그 문법의 값을 보낸다(`servers.languageIdFor`).
    .server = .{ .exe = "vscode-eslint-language-server", .args = &stdio_args, .language_id = "javascript", .install = "npm i -g vscode-langservers-extracted" },
    .bin_dirs = &.{"node_modules/.bin"},
    .pull_diagnostics = true,
    .answers_configuration = true,
};
const ruff: Auxiliary = .{
    .tool = .ruff,
    .server = .{ .exe = "ruff", .args = &ruff_args, .language_id = "python", .install = "pip install ruff" },
    .bin_dirs = &.{ ".venv/bin", "venv/bin" },
};
// Biome·oxlint(AS4) — 둘 다 push 진단이고 `workspace/configuration` 을 거부해도 돈다(2026-10-13 실측, 계획 editor-auxiliary-servers).
const biome_args = [_][]const u8{"lsp-proxy"};
const biome: Auxiliary = .{
    .tool = .biome,
    .server = .{ .exe = "biome", .args = &biome_args, .language_id = "javascript", .install = "npm i -D @biomejs/biome" },
    .bin_dirs = &.{"node_modules/.bin"},
};
// Biome 은 JSON·CSS 도 린트한다(AS5 — 그때는 주 서버 표가 없었고, LS1 부터 주 서버와 함께 간다). CSS 는 `.css` 파일만(위 `extensions`).
const biome_css: Auxiliary = .{ .tool = .biome, .server = biome.server, .bin_dirs = biome.bin_dirs, .extensions = &.{"css"} };
const oxlint_args = [_][]const u8{"--lsp"};
const oxlint: Auxiliary = .{
    .tool = .oxlint,
    .server = .{ .exe = "oxlint", .args = &oxlint_args, .language_id = "javascript", .install = "npm i -D oxlint" },
    .bin_dirs = &.{"node_modules/.bin"},
};

/// 문법 → 보조 서버들(주 서버 다음에 붙는다 — 이 순서로 `⌘.` 메뉴를 합치고 저장 시 묻는다). 없으면 빈 슬라이스. 설정을 찾은 것은
/// 전부 뜬다(계획 AS4 결정 — 옮기는 중인 저장소는 ESLint 와 oxlint 를 함께 쓴다).
pub fn forGrammar(g: language.Grammar) []const Auxiliary {
    return switch (g) {
        .python => &[_]Auxiliary{ruff},
        .javascript, .typescript, .tsx => &[_]Auxiliary{ eslint, biome, oxlint },
        .json => &[_]Auxiliary{biome},
        .css => &[_]Auxiliary{biome_css},
        else => &.{},
    };
}

/// 실행 파일 이름 → 그 보조 서버(클라이언트가 든 `server.exe` 에서 되찾는다). 주 서버면 `null`.
pub fn byExe(exe: []const u8) ?Auxiliary {
    inline for (.{ ruff, eslint, biome, oxlint }) |a| if (std.mem.eql(u8, a.server.exe, exe)) return a;
    return null;
}

/// 그 도구의 저장소 설정 — 문서 폴더에서 루트까지 가장 가까운 것(절대 경로를 `out` 에). 없으면 `null`(띄우지 않는다).
/// - ruff: `ruff.toml`·`.ruff.toml`(있으면 그것 — ruff 가 설정으로 읽는다), 또는 `pyproject.toml` 의 `[tool.ruff]`·`[tool.ruff.<무엇>]`.
/// - ESLint: flat 설정 `eslint.config.{js,mjs,cjs,ts,mts,cts}`, 옛 설정 `.eslintrc`·`.eslintrc.{js,cjs,json,yaml,yml}`, 또는 `package.json` 의
///   최상위 `eslintConfig`(의존성은 설정이 아니다).
/// - Biome: `biome.json`·`biome.jsonc`(외부 포매터의 목록 그대로 — 두 벌이면 한쪽만 낡는다).
/// - oxlint: `.oxlintrc.json`·`.oxlintrc.jsonc`·`oxlint.config.ts`·`oxlint.config.mts`(oxlint 1.87 이 작업 폴더에서 찾는 목록).
pub const eslint_config_names = [_][]const u8{
    "eslint.config.js", "eslint.config.mjs", "eslint.config.cjs", "eslint.config.ts", "eslint.config.mts", "eslint.config.cts",
    ".eslintrc",        ".eslintrc.js",      ".eslintrc.cjs",     ".eslintrc.json",   ".eslintrc.yaml",    ".eslintrc.yml",
};

pub const oxlint_config_names = [_][]const u8{ ".oxlintrc.json", ".oxlintrc.jsonc", "oxlint.config.ts", "oxlint.config.mts" };

pub fn detect(allocator: std.mem.Allocator, fs: anytype, tool: Tool, doc_dir: []const u8, root: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var dirs = external_format.DirsUp.init(doc_dir, root);
    while (dirs.next()) |dir| switch (tool) {
        inline .biome, .oxlint => |t| for (if (t == .biome) &external_format.biome_config_names else &oxlint_config_names) |name| {
            const p = join(out, dir, name) orelse continue;
            if (fs.exists(p)) return p;
        },
        .eslint => {
            for (eslint_config_names) |name| {
                const p = join(out, dir, name) orelse continue;
                if (fs.exists(p)) return p;
            }
            const pj = join(out, dir, "package.json") orelse continue;
            if (!fs.exists(pj)) continue;
            const text = fs.read(pj, external_format.max_config_read_bytes) orelse continue;
            defer fs.freeRead(text);
            if (external_format.packageJsonHasKey(allocator, text, "eslintConfig")) return pj;
        },
        .ruff => {
            for ([_][]const u8{ "ruff.toml", ".ruff.toml" }) |name| {
                const p = join(out, dir, name) orelse continue;
                if (fs.exists(p)) return p;
            }
            const pp = join(out, dir, "pyproject.toml") orelse continue;
            if (!fs.exists(pp)) continue;
            const text = fs.read(pp, external_format.max_config_read_bytes) orelse continue;
            defer fs.freeRead(text);
            if (external_format.tomlHasTable(text, "tool.ruff", true)) return pp;
        },
    };
    return null;
}

/// `workspace/configuration` 에 답할 그 서버의 고정 설정(JSON 원문, 소유) — 답하지 않는 서버면 `null`.
/// ESLint: vscode-eslint 확장이 보내는 설정의 모양(2026-10-13 실측 — 객체가 없으면 진단 요청이 `workingDirectory` 를, `experimental` 이 없으면
/// `useFlatConfig` 를 못 읽어 실패한다).
/// 검사는 켜고(`validate: on`, 타이핑마다), 저장 시 고치기는 서버가 알아서 하지 않는다(`codeActionOnSave` 는 우리 `⌘S` 가 kind 로 묻는다 —
/// §8.2s), 포맷은 하지 않는다(외부 포매터 §8.2t). 작업 폴더는 저장소 루트.
pub fn settingsJson(allocator: std.mem.Allocator, tool: Tool, root_uri: []const u8, root_name: []const u8) error{OutOfMemory}!?[]u8 {
    // 빈 객체 `{}` — 빈 익명 리터럴 `.{}` 는 튜플이라 `[]` 로 나간다.
    const Empty = struct {};
    return switch (tool) {
        .ruff, .biome, .oxlint => null,
        .eslint => try std.json.Stringify.valueAlloc(allocator, .{
            .validate = "on",
            // 서버가 `settings.experimental.useFlatConfig` 를 읽는다 — 객체가 없으면 진단 요청이 `reading 'useFlatConfig'` 로 실패한다(진짜 서버
            // 4.10 실측). `useFlatConfig` 는 두지 않는다 — 서버가 ESLint 판에 맞춰 flat 설정을 알아본다(ESLint 9 는 넣으면 경고한다).
            .experimental = Empty{},
            .packageManager = "npm",
            .useESLintClass = false,
            .codeActionOnSave = .{ .enable = false, .mode = "all" },
            .format = false,
            .quiet = false,
            .onIgnoredFiles = "off",
            .options = Empty{},
            .rulesCustomizations = [_]i32{}, // `u8` 배열은 JSON 문자열이 된다 — 빈 배열로
            .run = "onType",
            .problems = .{ .shortenToSingleLine = false },
            .nodePath = null,
            .workingDirectory = .{ .mode = "auto" },
            .workspaceFolder = .{ .uri = root_uri, .name = root_name },
            .codeAction = .{
                .disableRuleComment = .{ .enable = true, .location = "separateLine" },
                .showDocumentation = .{ .enable = false },
            },
        }, .{}),
    };
}

fn join(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ if (std.mem.eql(u8, dir, "/")) "" else dir, name }) catch null;
}

const testing = std.testing;

const FakeFs = struct {
    files: []const struct { path: []const u8, text: []const u8 = "" },

    fn find(self: FakeFs, p: []const u8) ?usize {
        for (self.files, 0..) |f, i| if (std.mem.eql(u8, f.path, p)) return i;
        return null;
    }
    pub fn exists(self: FakeFs, p: []const u8) bool {
        return self.find(p) != null;
    }
    pub fn read(self: FakeFs, p: []const u8, limit: usize) ?[]const u8 {
        const i = self.find(p) orelse return null;
        if (self.files[i].text.len > limit) return null;
        return self.files[i].text;
    }
    pub fn freeRead(_: FakeFs, _: []const u8) void {}
};

test "AUX1 보조 서버 표 — Python 에 ruff server, JS·TS·TSX 에 ESLint(pull·설정 답)·Biome·oxlint 순서, JSON·CSS 에 Biome(CSS 는 .css 만), 그 밖의 문법은 없음, exe 로 되찾기 (tooling §8.2u)" {
    const py = forGrammar(.python);
    try testing.expectEqual(@as(usize, 1), py.len);
    try testing.expectEqual(Tool.ruff, py[0].tool);
    try testing.expectEqualStrings("ruff", py[0].server.exe);
    try testing.expectEqualStrings("server", py[0].server.args[0]);
    try testing.expectEqualStrings("python", py[0].server.language_id);
    try testing.expect(!py[0].pull_diagnostics and !py[0].answers_configuration);
    for ([_]language.Grammar{ .javascript, .typescript, .tsx }) |g| {
        const js = forGrammar(g);
        try testing.expectEqual(@as(usize, 3), js.len);
        try testing.expectEqual(Tool.eslint, js[0].tool);
        try testing.expectEqualStrings("vscode-eslint-language-server", js[0].server.exe);
        try testing.expectEqualStrings("--stdio", js[0].server.args[0]);
        try testing.expect(js[0].pull_diagnostics and js[0].answers_configuration);
        // Biome·oxlint 는 push 진단이고 설정 요청은 거부한다(실측 — 거부해도 돈다).
        try testing.expectEqual(Tool.biome, js[1].tool);
        try testing.expectEqualStrings("biome", js[1].server.exe);
        try testing.expectEqualStrings("lsp-proxy", js[1].server.args[0]);
        try testing.expectEqual(Tool.oxlint, js[2].tool);
        try testing.expectEqualStrings("oxlint", js[2].server.exe);
        try testing.expectEqualStrings("--lsp", js[2].server.args[0]);
        for (js) |a| {
            try testing.expectEqual(@as(usize, 1), a.server.args.len);
            try testing.expectEqualStrings("node_modules/.bin", a.bin_dirs[0]);
            if (a.tool != .eslint) try testing.expect(!a.pull_diagnostics and !a.answers_configuration);
        }
    }
    try testing.expectEqual(Tool.eslint, byExe("vscode-eslint-language-server").?.tool);
    try testing.expectEqual(Tool.biome, byExe("biome").?.tool);
    try testing.expectEqual(Tool.oxlint, byExe("oxlint").?.tool);
    for ([_]language.Grammar{ .zig, .rust, .go, .c, .markdown, .html, .none }) |g| try testing.expectEqual(@as(usize, 0), forGrammar(g).len);
    // JSON·CSS 에는 Biome 하나(AS5). CSS 는 `.css` 파일만 — `scss`·`less` 는 Biome 이 다루지 않는다.
    for ([_]language.Grammar{ .json, .css }) |g| {
        const b = forGrammar(g);
        try testing.expectEqual(@as(usize, 1), b.len);
        try testing.expectEqual(Tool.biome, b[0].tool);
        try testing.expectEqualStrings("lsp-proxy", b[0].server.args[0]);
    }
    try testing.expect(forGrammar(.json)[0].appliesTo("/r/a.json"));
    try testing.expect(forGrammar(.css)[0].appliesTo("/r/s.css") and forGrammar(.css)[0].appliesTo("/r/S.CSS"));
    for ([_][]const u8{ "/r/s.scss", "/r/s.less", "/r/css", "/r/s." }) |p| try testing.expect(!forGrammar(.css)[0].appliesTo(p));
    for (forGrammar(.typescript)) |a| try testing.expect(a.appliesTo("/r/a.ts"));
    try testing.expectEqual(Tool.ruff, byExe("ruff").?.tool);
    try testing.expect(byExe("pyright-langserver") == null);
    // 주 서버 표와 이름이 겹치면 `(root, exe)` 열쇠가 두 역할을 한 클라이언트로 합친다.
    for (std.enums.values(language.Grammar)) |g| for (servers.candidatesFor(g)) |s| try testing.expect(byExe(s.exe) == null);
}

test "AUX6 보조 서버가 있는 문법엔 주 서버도 있고, 그 주 서버는 보조 서버가 붙는 확장자를 다룬다 — 「보조 서버만」인 문서는 없다(LS1 부터; 계획 editor-lsp-servers-expand)" {
    // 정보 명령·신뢰 관리·동기화가 이 불변식에 기대어 「보조 서버만」 갈래를 두지 않는다(`editor/lsp.zig`). 깨지면(주 서버 없는 문법에 보조 서버를
    // 더하면) 그 갈래가 다시 필요하다 — 이 판정자가 먼저 깨진다.
    for (std.enums.values(language.Grammar)) |g| {
        const auxes = forGrammar(g);
        if (auxes.len == 0) continue;
        const primary = servers.forGrammar(g) orelse return error.AuxWithoutPrimary;
        for (auxes) |a| for (a.extensions) |e| {
            var buf: [32]u8 = undefined;
            try testing.expect(primary.serves(try std.fmt.bufPrint(&buf, "/r/a.{s}", .{e})));
        };
        try testing.expectEqual(@as(usize, 0), primary.skip_extensions.len); // 다루지 않는 확장자가 생기면 위 갈래를 다시 본다
    }
}

test "AUX2 ruff 감지 — 가장 가까운 ruff.toml·.ruff.toml·pyproject [tool.ruff…], 다른 표만 있으면 아님, 루트 밖은 안 봄 (tooling §8.2u)" {
    var out: [std.fs.max_path_bytes]u8 = undefined;
    // ① 문서 폴더의 ruff.toml 이 루트의 pyproject 보다 가깝다.
    const fs1: FakeFs = .{ .files = &.{
        .{ .path = "/r/pyproject.toml", .text = "[tool.ruff]\nline-length = 100\n" },
        .{ .path = "/r/pkg/ruff.toml", .text = "" },
    } };
    try testing.expectEqualStrings("/r/pkg/ruff.toml", detect(testing.allocator, fs1, .ruff, "/r/pkg/sub", "/r", &out).?);
    try testing.expectEqualStrings("/r/pyproject.toml", detect(testing.allocator, fs1, .ruff, "/r/other", "/r", &out).?);
    // ② 아래 표(`[tool.ruff.lint]`)만 있어도 ruff 설정이다.
    const fs2: FakeFs = .{ .files = &.{.{ .path = "/r/pyproject.toml", .text = "[project]\nname='x'\n\n[tool.ruff.lint]\nselect = [\"F\"]\n" }} };
    try testing.expectEqualStrings("/r/pyproject.toml", detect(testing.allocator, fs2, .ruff, "/r", "/r", &out).?);
    // ③ 다른 도구의 표만(`[tool.black]`·이름이 앞만 같은 `[tool.ruffle]`) — 아니다.
    const fs3: FakeFs = .{ .files = &.{.{ .path = "/r/pyproject.toml", .text = "[tool.black]\n[tool.ruffle]\n" }} };
    try testing.expect(detect(testing.allocator, fs3, .ruff, "/r/a", "/r", &out) == null);
    // ④ `.ruff.toml` 도 설정이다.
    const fs4: FakeFs = .{ .files = &.{.{ .path = "/r/.ruff.toml" }} };
    try testing.expectEqualStrings("/r/.ruff.toml", detect(testing.allocator, fs4, .ruff, "/r/a", "/r", &out).?);
    // ⑤ 루트 밖(상위 폴더)의 설정은 안 본다.
    const fs5: FakeFs = .{ .files = &.{.{ .path = "/ruff.toml" }} };
    try testing.expect(detect(testing.allocator, fs5, .ruff, "/r/a", "/r", &out) == null);
}

test "AUX3 ESLint 감지 — 가장 가까운 flat·옛 설정, package.json 의 eslintConfig(의존성은 아님), 루트 밖은 안 봄 (tooling §8.2u)" {
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const a = testing.allocator;
    const fs1: FakeFs = .{ .files = &.{
        .{ .path = "/r/eslint.config.mjs" },
        .{ .path = "/r/pkg/.eslintrc.json", .text = "{}" },
    } };
    try testing.expectEqualStrings("/r/pkg/.eslintrc.json", detect(a, fs1, .eslint, "/r/pkg/src", "/r", &out).?);
    try testing.expectEqualStrings("/r/eslint.config.mjs", detect(a, fs1, .eslint, "/r/web", "/r", &out).?);
    for (eslint_config_names) |name| {
        var pbuf: [64]u8 = undefined;
        const p = try std.fmt.bufPrint(&pbuf, "/r/{s}", .{name});
        const fs: FakeFs = .{ .files = &.{.{ .path = p }} };
        try testing.expectEqualStrings(p, detect(a, fs, .eslint, "/r/x", "/r", &out).?);
    }
    const pkg: FakeFs = .{ .files = &.{.{ .path = "/r/package.json", .text = "{\"name\":\"x\",\"eslintConfig\":{\"rules\":{}}}" }} };
    try testing.expectEqualStrings("/r/package.json", detect(a, pkg, .eslint, "/r/x", "/r", &out).?);
    const dep: FakeFs = .{ .files = &.{.{ .path = "/r/package.json", .text = "{\"devDependencies\":{\"eslint\":\"9\"}}" }} };
    try testing.expect(detect(a, dep, .eslint, "/r/x", "/r", &out) == null);
    const outside: FakeFs = .{ .files = &.{.{ .path = "/eslint.config.js" }} };
    try testing.expect(detect(a, outside, .eslint, "/r/x", "/r", &out) == null);
    // ruff 설정은 ESLint 가 아니다(도구마다 따로).
    const ruff_only: FakeFs = .{ .files = &.{.{ .path = "/r/ruff.toml" }} };
    try testing.expect(detect(a, ruff_only, .eslint, "/r", "/r", &out) == null);
}

test "AUX4 ESLint 의 고정 설정 — validate·workingDirectory·작업 폴더가 있고 서버의 저장 시 고치기·포맷은 끈다; ruff·Biome·oxlint 는 답하지 않는다 (tooling §8.2u)" {
    const a = testing.allocator;
    for ([_]Tool{ .ruff, .biome, .oxlint }) |t| try testing.expect((try settingsJson(a, t, "file:///r", "r")) == null);
    const blob = (try settingsJson(a, .eslint, "file:///r", "r")).?;
    defer a.free(blob);
    var p = try std.json.parseFromSlice(std.json.Value, a, blob, .{});
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqualStrings("on", o.get("validate").?.string);
    try testing.expectEqualStrings("auto", o.get("workingDirectory").?.object.get("mode").?.string);
    try testing.expectEqualStrings("file:///r", o.get("workspaceFolder").?.object.get("uri").?.string);
    try testing.expect(!o.get("format").?.bool);
    try testing.expect(!o.get("codeActionOnSave").?.object.get("enable").?.bool);
    try testing.expectEqualStrings("onType", o.get("run").?.string);
    try testing.expect(o.get("rulesCustomizations").? == .array); // 문자열이 아니다
    try testing.expect(o.get("experimental").? == .object); // 없으면 서버가 `useFlatConfig` 를 못 읽어 진단 요청이 실패한다
    try testing.expect(o.get("options").? == .object); // ESLint 생성자 옵션 — 배열이 아니다
    try testing.expect(o.get("useFlatConfig") == null and o.get("experimental").?.object.get("useFlatConfig") == null);
}

test "AUX5 Biome·oxlint 감지 — 설정 파일 이름마다, 가장 가까운 것, 도구마다 따로, 루트 밖은 안 봄 (tooling §8.2u)" {
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const a = testing.allocator;
    inline for (.{ .{ Tool.biome, &external_format.biome_config_names }, .{ Tool.oxlint, &oxlint_config_names } }) |row| {
        for (row[1]) |name| {
            var pbuf: [64]u8 = undefined;
            const p = try std.fmt.bufPrint(&pbuf, "/r/{s}", .{name});
            const fs: FakeFs = .{ .files = &.{.{ .path = p }} };
            try testing.expectEqualStrings(p, detect(a, fs, row[0], "/r/x", "/r", &out).?);
        }
    }
    try testing.expectEqual(@as(usize, 2), external_format.biome_config_names.len);
    try testing.expectEqual(@as(usize, 4), oxlint_config_names.len);
    // 가장 가까운 것 — 하위 패키지의 설정이 루트의 것보다 먼저.
    const nested: FakeFs = .{ .files = &.{ .{ .path = "/r/biome.json" }, .{ .path = "/r/pkg/biome.jsonc" }, .{ .path = "/r/.oxlintrc.json" }, .{ .path = "/r/pkg/oxlint.config.ts" } } };
    try testing.expectEqualStrings("/r/pkg/biome.jsonc", detect(a, nested, .biome, "/r/pkg/src", "/r", &out).?);
    try testing.expectEqualStrings("/r/biome.json", detect(a, nested, .biome, "/r/web", "/r", &out).?);
    try testing.expectEqualStrings("/r/pkg/oxlint.config.ts", detect(a, nested, .oxlint, "/r/pkg/src", "/r", &out).?);
    // 도구마다 따로 — ESLint 설정은 Biome·oxlint 가 아니고, Biome 설정은 oxlint 가 아니다.
    const eslint_only: FakeFs = .{ .files = &.{.{ .path = "/r/eslint.config.js" }} };
    try testing.expect(detect(a, eslint_only, .biome, "/r", "/r", &out) == null);
    try testing.expect(detect(a, eslint_only, .oxlint, "/r", "/r", &out) == null);
    const biome_only: FakeFs = .{ .files = &.{.{ .path = "/r/biome.json" }} };
    try testing.expect(detect(a, biome_only, .oxlint, "/r", "/r", &out) == null);
    try testing.expect(detect(a, biome_only, .eslint, "/r", "/r", &out) == null);
    const outside: FakeFs = .{ .files = &.{ .{ .path = "/biome.json" }, .{ .path = "/.oxlintrc.json" } } };
    try testing.expect(detect(a, outside, .biome, "/r/x", "/r", &out) == null);
    try testing.expect(detect(a, outside, .oxlint, "/r/x", "/r", &out) == null);
}
