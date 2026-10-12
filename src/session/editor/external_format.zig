//! 외부 포매터(tooling §8.2t, 계획 docs/plans/editor-external-formatter.md) — 순수 층: 설정 값, 저장소 설정 감지(JS 계열·Python·Rust 의
//! edition), 실행 파일 자리, argv(사용자 명령 포함), 결과 본문을 편집 덩어리로 바꾸기. 파일 시스템은 호출자가 넘긴 `fs`(`exists`·
//! `isExecutable`·`read`·`freeRead`)로만 본다 — 실행·시한·신뢰는 플랫폼 층(`format_process`·`editor/format.zig`)이 한다.
//!
//! **저장소가 고른 포매터를 따른다**(2026-10-12 사용자 결정): `auto` 면 문서 폴더에서 저장소 루트까지 올라가며 그 문법을 다루는 도구의
//! 설정을 찾는다. JS 계열은 Prettier·Biome·oxfmt — **둘 이상이면 고르지 않고 알린다**(사용자 결정). Python 은 포맷 설정이 있는 쪽(ruff·
//! black). Rust·Zig 는 언어 서버가 포맷할 수 있으면 언어 서버(같은 도구를 부른다), 아니면 rustfmt·zig fmt 를 직접.

const std = @import("std");
const language = @import("language.zig");
const delta = @import("delta.zig");
const diff = @import("diff.zig");
const edit_ops = @import("ops/edit_ops.zig");
const config_theme = @import("../../config/theme.zig");

/// 설정 `editor.formatter.<언어>` 의 값 — 단일 출처는 설정 층(`config/theme.zig`).
pub const Choice = config_theme.FormatterChoice;
pub const Setting = config_theme.FormatterSetting;

/// 기다림·저장 완료 안내가 공유하는 포매터 이름 사본. 설정을 다시 읽어도 빌린 문자열이 남지 않는다.
pub const Name = struct {
    buf: [64]u8 = undefined,
    len: u8 = 0,

    pub fn of(text: []const u8) Name {
        var n: Name = .{};
        const len = @min(text.len, n.buf.len);
        @memcpy(n.buf[0..len], text[0..len]);
        n.len = @intCast(len);
        return n;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
};

/// 그 문서의 문법에 걸린 설정(설정의 언어 칸 — 문법 이름으로 찾는다; `none` 은 `auto`).
pub fn settingFor(settings: []const Setting, g: language.Grammar) Setting {
    if (g == .none) return .{};
    const i = config_theme.formatterLanguageIndex(@tagName(g)) orelse return .{};
    return settings[i];
}

/// 외부 포매터의 종류.
pub const Kind = enum {
    prettier,
    biome,
    oxfmt,
    ruff,
    black,
    rustfmt,
    zig_fmt,
    /// 사용자 명령(`command: ‹argv›`).
    command,

    pub fn displayName(self: Kind) []const u8 {
        return switch (self) {
            .prettier => "Prettier",
            .biome => "Biome",
            .oxfmt => "oxfmt",
            .ruff => "Ruff",
            .black => "Black",
            .rustfmt => "rustfmt",
            .zig_fmt => "zig fmt",
            .command => "command",
        };
    }

    /// 찾을 실행 파일 이름(`command` 는 명령 줄의 첫 낱말 — `commandArgs`).
    pub fn exeName(self: Kind) []const u8 {
        return switch (self) {
            .prettier => "prettier",
            .biome => "biome",
            .oxfmt => "oxfmt",
            .ruff => "ruff",
            .black => "black",
            .rustfmt => "rustfmt",
            .zig_fmt => "zig",
            .command => "",
        };
    }

    /// 저장소 안에서 먼저 볼 실행 파일 폴더(문서 폴더에서 루트까지 각 폴더 아래) — 저장소가 고정한 버전.
    pub fn localBinDirs(self: Kind) []const []const u8 {
        return switch (self) {
            .prettier, .biome, .oxfmt => &.{"node_modules/.bin"},
            .ruff, .black => &.{ ".venv/bin", "venv/bin" },
            .rustfmt, .zig_fmt, .command => &.{},
        };
    }

    /// `kindFor` 의 거꾸로 — 설정의 선택지(포매터 이름)에서 종류.
    pub fn fromChoice(c: Choice) ?Kind {
        return switch (c) {
            .prettier => .prettier,
            .biome => .biome,
            .oxfmt => .oxfmt,
            .ruff => .ruff,
            .black => .black,
            .rustfmt => .rustfmt,
            .zig_fmt => .zig_fmt,
            .command => .command,
            .auto, .lsp, .off => null,
        };
    }
};

/// JS 계열 도구가 그 문법을 다루나(공식 언어 지원표 — Biome 은 HTML 이 따로 켜야 하고 Markdown 이 없다; oxfmt 는 HTML·Markdown 을
/// 내장 Prettier 로 다룬다).
pub fn jsToolHandles(kind: Kind, g: language.Grammar) bool {
    return switch (kind) {
        .prettier, .oxfmt => switch (g) {
            .javascript, .typescript, .tsx, .json, .css, .html, .markdown => true,
            else => false,
        },
        .biome => switch (g) {
            .javascript, .typescript, .tsx, .json, .css => true,
            else => false,
        },
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
pub const biome_config_names = [_][]const u8{ "biome.json", "biome.jsonc" };
pub const oxfmt_config_names = [_][]const u8{ ".oxfmtrc.json", ".oxfmtrc.jsonc" };

const js_tools = [_]Kind{ .prettier, .biome, .oxfmt };

fn jsConfigNames(kind: Kind) []const []const u8 {
    return switch (kind) {
        .prettier => &prettier_config_names,
        .biome => &biome_config_names,
        .oxfmt => &oxfmt_config_names,
        else => &.{},
    };
}

/// 읽을 설정 파일(`package.json`·`pyproject.toml`·`Cargo.toml`)의 상한 — 넘으면 안 본다.
pub const max_config_read_bytes: usize = 1 << 20;

/// `package.json` 본문의 최상위에 `"prettier"` 키가 있나(값은 무엇이든 — 설정 객체 또는 공유 설정 이름).
pub fn packageJsonHasPrettier(allocator: std.mem.Allocator, text: []const u8) bool {
    return packageJsonHasKey(allocator, text, "prettier");
}

/// `package.json` 본문의 최상위에 그 키가 있나(Prettier 의 `"prettier"`, ESLint 의 `"eslintConfig"` — 보조 서버 tooling §8.2u).
pub fn packageJsonHasKey(allocator: std.mem.Allocator, text: []const u8, key: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return false;
    defer parsed.deinit();
    return switch (parsed.value) {
        .object => |o| o.contains(key),
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

/// JS 계열 감지 — 그 문법을 다루는 도구마다 문서 폴더에서 루트까지 가장 가까운 설정(루트 기준 상대 경로를 `out[도구]` 에).
pub const JsDetected = struct {
    /// `js_tools` 순서(Prettier·Biome·oxfmt)의 가장 가까운 설정 — 없으면 `null`.
    configs: [js_tools.len]?[]const u8 = @splat(null),

    pub fn count(self: JsDetected) usize {
        var n: usize = 0;
        for (self.configs) |c| if (c != null) {
            n += 1;
        };
        return n;
    }

    /// 감지한 도구 이름을 `·` 로 이은 것(알림 — 「Prettier·Biome 설정이 함께 있습니다」).
    pub fn names(self: JsDetected, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        var first = true;
        for (self.configs, js_tools) |c, k| if (c != null) {
            if (!first) w.writeAll("·") catch {};
            w.writeAll(k.displayName()) catch {};
            first = false;
        };
        return w.buffered();
    }
};

pub fn detectJs(allocator: std.mem.Allocator, fs: anytype, g: language.Grammar, doc_dir: []const u8, root: []const u8, out: *[js_tools.len][std.fs.max_path_bytes]u8) JsDetected {
    var found: JsDetected = .{};
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dirs = DirsUp.init(doc_dir, root);
    while (dirs.next()) |dir| {
        for (js_tools, 0..) |k, ti| {
            if (found.configs[ti] != null or !jsToolHandles(k, g)) continue;
            for (jsConfigNames(k)) |name| {
                const p = join(&path_buf, dir, name) orelse continue;
                if (fs.exists(p)) {
                    found.configs[ti] = relative(&out[ti], root, p);
                    break;
                }
            }
            if (k == .prettier and found.configs[ti] == null) {
                const pj = join(&path_buf, dir, "package.json") orelse continue;
                if (!fs.exists(pj)) continue;
                const text = fs.read(pj, max_config_read_bytes) orelse continue;
                defer fs.freeRead(text);
                if (packageJsonHasPrettier(allocator, text)) found.configs[ti] = relative(&out[ti], root, pj);
            }
        }
    }
    return found;
}

/// TOML 본문에 그 표 머리(`[tool.ruff.format]`)가 있나 — 해석기 없이 줄 단위로(머리 줄의 앞뒤 공백·뒤 주석은 허용). `prefix` 면 그 아래
/// 표(`[tool.ruff.lint]`)도 든다.
pub fn tomlHasTable(text: []const u8, name: []const u8, prefix: bool) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var l = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOfScalar(u8, l, '#')) |h| l = std.mem.trimEnd(u8, l[0..h], " \t");
        // 배열 표(`[[tool.black]]`)는 따로 거르지 않는다 — 안쪽이 `[tool.black]` 이라 이름과 맞지 않는다(변이 D8 등가).
        if (l.len < 2 or l[0] != '[' or l[l.len - 1] != ']') continue;
        const inner = std.mem.trim(u8, l[1 .. l.len - 1], " \t");
        if (std.mem.eql(u8, inner, name)) return true;
        if (prefix and inner.len > name.len and std.mem.startsWith(u8, inner, name) and inner[name.len] == '.') return true;
    }
    return false;
}

pub const PyDetected = struct { kind: Kind, config: []const u8 };

/// Python 감지(사용자 결정 「포맷 설정이 있는 쪽」) — 문서 폴더에서 루트까지 Python 설정(`pyproject.toml`·`ruff.toml`·`.ruff.toml`)이 있는
/// 가장 가까운 폴더에서: ruff 의 포맷 설정(`[tool.ruff.format]`·ruff.toml 의 `[format]`)이면 ruff, 아니면 `[tool.black]` 이면 black,
/// 그것도 없고 ruff 설정만 있으면 ruff. 그 폴더에 둘 다 없으면 위로.
pub fn detectPython(fs: anytype, doc_dir: []const u8, root: []const u8, out: []u8) ?PyDetected {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dirs = DirsUp.init(doc_dir, root);
    while (dirs.next()) |dir| {
        var ruff_format: ?[]const u8 = null;
        var ruff_any: ?[]const u8 = null;
        var black: ?[]const u8 = null;
        for ([_][]const u8{ "ruff.toml", ".ruff.toml" }) |name| {
            const p = join(&path_buf, dir, name) orelse continue;
            if (!fs.exists(p)) continue;
            const text = fs.read(p, max_config_read_bytes) orelse continue;
            defer fs.freeRead(text);
            if (ruff_any == null) ruff_any = name;
            if (tomlHasTable(text, "format", false)) ruff_format = name;
            break; // ruff 는 `ruff.toml` 을 `.ruff.toml` 보다 먼저 본다
        }
        if (join(&path_buf, dir, "pyproject.toml")) |pp| if (fs.exists(pp)) if (fs.read(pp, max_config_read_bytes)) |text| {
            defer fs.freeRead(text);
            if (ruff_format == null and tomlHasTable(text, "tool.ruff.format", false)) ruff_format = "pyproject.toml";
            if (tomlHasTable(text, "tool.black", false)) black = "pyproject.toml";
            if (ruff_any == null and tomlHasTable(text, "tool.ruff", true)) ruff_any = "pyproject.toml";
        };
        const pick: ?PyDetected = if (ruff_format) |n| .{ .kind = .ruff, .config = n } else if (black) |n| .{ .kind = .black, .config = n } else if (ruff_any) |n| .{ .kind = .ruff, .config = n } else null;
        if (pick) |pk| {
            const full = join(&path_buf, dir, pk.config) orelse return null;
            return .{ .kind = pk.kind, .config = relative(out, root, full) orelse return null };
        }
    }
    return null;
}

/// `Cargo.toml` 의 `[package]` 의 `edition = "2021"` — rustfmt 를 직접 부를 때 넘긴다(rustfmt 의 기본은 2015 라 `async fn` 등이 깨진다;
/// rust-analyzer 도 Cargo 의 edition 을 넘긴다). 없거나 모양이 틀리면 `null`.
pub fn cargoEdition(text: []const u8) ?[]const u8 {
    var in_package = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len > 0 and l[0] == '[') {
            in_package = std.mem.eql(u8, l, "[package]");
            continue;
        }
        if (!in_package or !std.mem.startsWith(u8, l, "edition")) continue;
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        if (std.mem.trim(u8, l[0..eq], " \t").len != "edition".len) continue;
        const v = std.mem.trim(u8, l[eq + 1 ..], " \t");
        if (v.len < 3 or v[0] != '"') continue;
        const close = std.mem.indexOfScalarPos(u8, v, 1, '"') orelse continue;
        const e = v[1..close];
        if (e.len != 4) continue;
        for (e) |c| if (c < '0' or c > '9') return null;
        return e;
    }
    return null;
}

/// 문서 폴더에서 루트까지 그 이름의 가장 가까운 파일(절대 경로를 `out` 에) — `Cargo.toml` 처럼.
pub fn findNearest(fs: anytype, doc_dir: []const u8, root: []const u8, name: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var dirs = DirsUp.init(doc_dir, root);
    while (dirs.next()) |dir| {
        const p = join(out, dir, name) orelse continue;
        if (fs.exists(p)) return p;
    }
    return null;
}

/// 저장소 안의 실행 파일 — 문서 폴더에서 루트까지 각 폴더의 `localBinDirs` 아래 가장 가까운 것(실행할 수 있는 파일만). 없으면 `null`
/// (호출자가 PATH 를 본다).
pub fn findLocalBin(fs: anytype, kind: Kind, doc_dir: []const u8, root: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    return findLocalBinIn(fs, kind.localBinDirs(), kind.exeName(), doc_dir, root, out);
}

/// `findLocalBin` 의 몸 — 폴더 목록과 실행 파일 이름으로(보조 언어 서버 tooling §8.2u 도 같은 규칙으로 찾는다).
pub fn findLocalBinIn(fs: anytype, bins: []const []const u8, exe: []const u8, doc_dir: []const u8, root: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (bins.len == 0) return null;
    var dirs = DirsUp.init(doc_dir, root);
    while (dirs.next()) |dir| {
        for (bins) |b| {
            const p = std.fmt.bufPrint(out, "{s}/{s}/{s}", .{ if (std.mem.eql(u8, dir, "/")) "" else dir, b, exe }) catch continue;
            if (fs.isExecutable(p)) return p;
        }
    }
    return null;
}

/// 그 문서를 무엇으로 포맷하나.
pub const Plan = union(enum) {
    /// 언어 서버(지금 동작).
    lsp,
    /// 포맷하지 않는다(설정 `off`).
    off,
    /// JS 계열 도구의 설정이 둘 이상 — 고르지 않고 알린다(사용자 결정).
    conflict: JsDetected,
    /// 외부 포매터. `config` 는 감지한 설정 파일(루트 기준 — 설정으로 고른 것이면 없을 수 있다).
    external: struct { kind: Kind, config: ?[]const u8 = null },
};

/// 설정과 감지 결과로 정한다. `js`·`py` 는 그 문법에서 감지한 것(호출자가 그 문법일 때만 감지한다), `lsp_can_format` 은 그 문서의 언어
/// 서버가 지금 포맷할 수 있나(Rust·Zig 의 `auto`).
pub fn plan(setting: Setting, g: language.Grammar, js: JsDetected, py: ?PyDetected, lsp_can_format: bool) Plan {
    switch (setting.choice) {
        .lsp => return .lsp,
        .off => return .off,
        .auto => {},
        else => |c| {
            const k = Kind.fromChoice(c).?;
            // 적어 둔 도구가 감지한 그 도구면 설정 파일도 보인다.
            const cfg: ?[]const u8 = for (js.configs, js_tools) |cf, t| {
                if (t == k) break cf;
            } else if (py) |p| (if (p.kind == k) p.config else null) else null;
            return .{ .external = .{ .kind = k, .config = cfg } };
        },
    }
    switch (js.count()) {
        0 => {},
        1 => for (js.configs, js_tools) |cf, t| if (cf) |c| return .{ .external = .{ .kind = t, .config = c } },
        else => return .{ .conflict = js },
    }
    if (g == .python) if (py) |p| return .{ .external = .{ .kind = p.kind, .config = p.config } };
    if (!lsp_can_format) switch (g) {
        .rust => return .{ .external = .{ .kind = .rustfmt } },
        .zig => return .{ .external = .{ .kind = .zig_fmt } },
        else => {},
    };
    return .lsp;
}

/// 사용자 명령 줄을 낱말로 — 공백으로 가르고 큰따옴표로 묶는다(이스케이프 없음). 낱말은 `text` 를 빌린다. 빈 줄·닫히지 않은 따옴표·낱말이
/// 너무 많으면 `null`.
pub fn commandArgs(text: []const u8, out: *[max_args][]const u8) ?[]const []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (true) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i >= text.len) break;
        if (n == out.len) return null;
        if (text[i] == '"') {
            const close = std.mem.indexOfScalarPos(u8, text, i + 1, '"') orelse return null;
            out[n] = text[i + 1 .. close];
            i = close + 1;
        } else {
            const start = i;
            while (i < text.len and text[i] != ' ' and text[i] != '\t') i += 1;
            out[n] = text[start..i];
        }
        n += 1;
    }
    if (n == 0 or out[0].len == 0) return null;
    return out[0..n];
}

/// argv 의 상한.
pub const max_args: usize = 32;

/// 실행할 argv(셸 없이) — `exe` 는 찾은 실행 파일(사용자 명령이면 그 첫 낱말을 찾은 것). `path` 는 문서 경로(포매터가 설정·ignore·파서를
/// 고른다), `edition` 은 rustfmt 의 Cargo edition, `command` 는 사용자 명령 줄(`{path}` 가 문서 경로로 바뀐다 — 낱말 안에서도). 낱말은
/// `buf` 에 쓰거나 입력을 빌린다. 못 만들면 `null`.
pub const Argv = struct {
    items: [max_args][]const u8 = undefined,
    len: usize = 0,
    buf: [4 * std.fs.max_path_bytes]u8 = undefined,
    used: usize = 0,

    pub fn slice(self: *const Argv) []const []const u8 {
        return self.items[0..self.len];
    }

    fn push(self: *Argv, a: []const u8) bool {
        if (self.len == max_args) return false;
        self.items[self.len] = a;
        self.len += 1;
        return true;
    }

    /// `{path}` 를 바꾼 낱말을 `buf` 에 만든다.
    fn pushReplaced(self: *Argv, a: []const u8, path: []const u8) bool {
        if (std.mem.indexOf(u8, a, "{path}") == null) return self.push(a);
        const start = self.used;
        var rest = a;
        while (std.mem.indexOf(u8, rest, "{path}")) |at| {
            if (!self.append(rest[0..at]) or !self.append(path)) return false;
            rest = rest[at + "{path}".len ..];
        }
        if (!self.append(rest)) return false;
        return self.push(self.buf[start..self.used]);
    }

    fn append(self: *Argv, bytes: []const u8) bool {
        if (self.used + bytes.len > self.buf.len) return false;
        @memcpy(self.buf[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
        return true;
    }
};

pub fn argv(out: *Argv, kind: Kind, exe: []const u8, path: []const u8, edition: ?[]const u8, command: []const u8) bool {
    out.* = .{};
    if (!out.push(exe)) return false;
    switch (kind) {
        .prettier, .oxfmt => return out.push("--stdin-filepath") and out.push(path),
        .biome => {
            const start = out.used;
            if (!out.append("--stdin-file-path=") or !out.append(path)) return false;
            return out.push("format") and out.push(out.buf[start..out.used]);
        },
        .ruff => return out.push("format") and out.push("--stdin-filename") and out.push(path) and out.push("-"),
        .black => return out.push("-q") and out.push("--stdin-filename") and out.push(path) and out.push("-"),
        .rustfmt => {
            if (!out.push("--emit") or !out.push("stdout")) return false;
            if (edition) |e| return out.push("--edition") and out.push(e);
            return true;
        },
        .zig_fmt => return out.push("fmt") and out.push("--stdin"),
        .command => {
            var words: [max_args][]const u8 = undefined;
            const ws = commandArgs(command, &words) orelse return false;
            for (ws[1..]) |w| if (!out.pushReplaced(w, path)) return false;
            return true;
        },
    }
}

/// 사용자 명령의 이름(첫 낱말의 끝 이름 — 알림·정보 명령).
pub fn commandName(command: []const u8) []const u8 {
    var words: [max_args][]const u8 = undefined;
    const ws = commandArgs(command, &words) orelse return "command";
    return std.fs.path.basename(ws[0]);
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

test "EXF1 설정과 계획 — 적어 둔 포매터는 감지와 무관(감지했으면 설정 파일도), lsp·off, auto 는 JS 감지가 하나면 그것·둘 이상이면 알림·Python 감지·Rust·Zig 는 언어 서버가 못 할 때만 (tooling §8.2t)" {
    const none: JsDetected = .{};
    var one: JsDetected = .{};
    one.configs[1] = "biome.json";
    var two: JsDetected = .{};
    two.configs[0] = ".prettierrc";
    two.configs[2] = ".oxfmtrc.json";
    const py: PyDetected = .{ .kind = .black, .config = "pyproject.toml" };
    try testing.expect(plan(.{ .choice = .lsp }, .typescript, one, null, true) == .lsp);
    try testing.expect(plan(.{ .choice = .off }, .typescript, one, null, true) == .off);
    try testing.expectEqual(Kind.biome, plan(.{}, .typescript, one, null, true).external.kind);
    try testing.expectEqualStrings("biome.json", plan(.{}, .typescript, one, null, true).external.config.?);
    try testing.expect(plan(.{}, .typescript, two, null, true) == .conflict);
    var nb: [64]u8 = undefined;
    try testing.expectEqualStrings("Prettier·oxfmt", plan(.{}, .typescript, two, null, true).conflict.names(&nb));
    try testing.expect(plan(.{}, .typescript, none, null, true) == .lsp);
    // 적어 둔 포매터 — 감지와 무관, 감지한 그 도구면 설정 파일까지.
    try testing.expectEqual(Kind.prettier, plan(.{ .choice = .prettier }, .typescript, two, null, true).external.kind);
    try testing.expectEqualStrings(".prettierrc", plan(.{ .choice = .prettier }, .typescript, two, null, true).external.config.?);
    try testing.expect(plan(.{ .choice = .biome }, .typescript, two, null, true).external.config == null);
    try testing.expectEqual(Kind.command, plan(.{ .choice = .command, .command = "gofumpt" }, .go, none, null, true).external.kind);
    // Python.
    try testing.expectEqual(Kind.black, plan(.{}, .python, none, py, true).external.kind);
    try testing.expect(plan(.{}, .python, none, null, true) == .lsp);
    // Rust·Zig — 언어 서버가 포맷할 수 있으면 언어 서버, 아니면 직접.
    try testing.expect(plan(.{}, .rust, none, null, true) == .lsp);
    try testing.expectEqual(Kind.rustfmt, plan(.{}, .rust, none, null, false).external.kind);
    try testing.expectEqual(Kind.zig_fmt, plan(.{}, .zig, none, null, false).external.kind);
    try testing.expect(plan(.{}, .go, none, null, false) == .lsp); // 직접 부를 도구가 정해지지 않은 언어
    // 도구별 다루는 문법.
    for ([_]language.Grammar{ .javascript, .typescript, .tsx, .json, .css, .html, .markdown }) |g| {
        try testing.expect(jsToolHandles(.prettier, g));
        try testing.expect(jsToolHandles(.oxfmt, g));
    }
    for ([_]language.Grammar{ .javascript, .typescript, .tsx, .json, .css }) |g| try testing.expect(jsToolHandles(.biome, g));
    try testing.expect(!jsToolHandles(.biome, .html) and !jsToolHandles(.biome, .markdown));
    try testing.expect(!jsToolHandles(.prettier, .python) and !jsToolHandles(.ruff, .python));
}

test "EXF2 JS 계열 감지 — 도구마다 문서 폴더에서 루트까지 가장 가까운 설정(이름 목록·package.json 의 prettier 키), 그 문법을 다루는 도구만, 루트 밖은 안 보고, 실행 파일은 가장 가까운 저장소 폴더" {
    const a = testing.allocator;
    const fs: FakeFs = .{
        .files = &.{
            .{ .path = "/repo/.prettierrc.json" },
            .{ .path = "/repo/pkg/package.json", .text = "{\"name\":\"p\",\"prettier\":\"@acme/prettier-config\"}" },
            .{ .path = "/repo/other/package.json", .text = "{\"name\":\"o\",\"devDependencies\":{\"prettier\":\"3\"}}" }, // 의존성은 설정이 아니다
            .{ .path = "/repo/web/biome.jsonc" },
            .{ .path = "/outside/.prettierrc" },
            .{ .path = "/repo/node_modules/.bin/prettier", .exec = true },
            .{ .path = "/repo/pkg/node_modules/.bin/prettier", .exec = false }, // 실행 못 함 — 건너뛴다
            .{ .path = "/repo/py/.venv/bin/ruff", .exec = true },
        },
    };
    var out: [3][std.fs.max_path_bytes]u8 = undefined;
    {
        const d = detectJs(a, fs, .typescript, "/repo/pkg/src", "/repo", &out);
        try testing.expectEqualStrings("pkg/package.json", d.configs[0].?);
        try testing.expectEqual(@as(usize, 1), d.count());
    }
    try testing.expectEqualStrings(".prettierrc.json", detectJs(a, fs, .typescript, "/repo/other/src", "/repo", &out).configs[0].?); // 의존성뿐 — 위로
    {
        // 두 도구 — 루트의 Prettier 와 `web/` 의 Biome.
        const d = detectJs(a, fs, .tsx, "/repo/web/src", "/repo", &out);
        try testing.expectEqual(@as(usize, 2), d.count());
        try testing.expectEqualStrings("web/biome.jsonc", d.configs[1].?);
    }
    // Markdown 은 Biome 이 다루지 않는다 — Prettier 하나.
    try testing.expectEqual(@as(usize, 1), detectJs(a, fs, .markdown, "/repo/web", "/repo", &out).count());
    // 루트 밖 문서 폴더는 루트만 본다(`/outside` 는 안 본다).
    try testing.expectEqualStrings(".prettierrc.json", detectJs(a, fs, .typescript, "/outside", "/repo", &out).configs[0].?);
    const nothing: FakeFs = .{ .files = &.{.{ .path = "/outside/.prettierrc" }} };
    try testing.expectEqual(@as(usize, 0), detectJs(a, nothing, .typescript, "/repo/x", "/repo", &out).count());
    var bin: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/repo/node_modules/.bin/prettier", findLocalBin(fs, .prettier, "/repo/pkg/src", "/repo", &bin).?);
    try testing.expectEqualStrings("/repo/py/.venv/bin/ruff", findLocalBin(fs, .ruff, "/repo/py/a", "/repo", &bin).?);
    try testing.expect(findLocalBin(fs, .rustfmt, "/repo", "/repo", &bin) == null); // 저장소 폴더를 안 본다(PATH)
    try testing.expect(findLocalBin(nothing, .prettier, "/repo/pkg", "/repo", &bin) == null);
    try testing.expect(packageJsonHasPrettier(a, "{\"prettier\":{\"semi\":false}}"));
    try testing.expect(!packageJsonHasPrettier(a, "{\"dependencies\":{\"prettier\":\"3\"}}"));
    try testing.expect(!packageJsonHasPrettier(a, "not json"));
    try testing.expect(!packageJsonHasPrettier(a, "[\"prettier\"]"));
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

test "EXF6 Python 감지 — 포맷 설정이 있는 쪽(ruff 의 포맷 표 → black → ruff 설정만), 가장 가까운 폴더, ruff.toml 의 [format], TOML 머리 줄(주석·공백·아래 표·배열 표)" {
    const fs: FakeFs = .{
        .files = &.{
            .{ .path = "/r/pyproject.toml", .text = "[project]\nname='x'\n[tool.ruff]\nline-length=100\n[tool.black]\nline-length = 88\n" },
            .{ .path = "/r/a/pyproject.toml", .text = "[tool.ruff.format] # 포맷도 ruff\nquote-style='single'\n[tool.black]\n" },
            .{ .path = "/r/b/ruff.toml", .text = "line-length=99\n  [format]  \n" },
            .{ .path = "/r/c/pyproject.toml", .text = "[tool.ruff.lint]\nselect=['E']\n" },
            .{ .path = "/r/d/pyproject.toml", .text = "[project]\nname='d'\n" }, // 도구 설정 없음 — 위로
            .{ .path = "/r/e/.ruff.toml", .text = "[[format.x]]\n" }, // 배열 표는 `[format]` 이 아니다
        },
    };
    var out: [std.fs.max_path_bytes]u8 = undefined;
    {
        const d = detectPython(fs, "/r", "/r", &out).?;
        try testing.expectEqual(Kind.black, d.kind); // ruff 는 린터만, 포맷은 black
        try testing.expectEqualStrings("pyproject.toml", d.config);
    }
    try testing.expectEqual(Kind.ruff, detectPython(fs, "/r/a", "/r", &out).?.kind); // 포맷 표가 이긴다
    {
        const d = detectPython(fs, "/r/b/x", "/r", &out).?;
        try testing.expectEqual(Kind.ruff, d.kind);
        try testing.expectEqualStrings("b/ruff.toml", d.config);
    }
    try testing.expectEqual(Kind.ruff, detectPython(fs, "/r/c", "/r", &out).?.kind); // ruff 설정만
    try testing.expectEqual(Kind.black, detectPython(fs, "/r/d", "/r", &out).?.kind); // 위로 올라가 루트의 것
    try testing.expectEqual(Kind.ruff, detectPython(fs, "/r/e", "/r", &out).?.kind); // `.ruff.toml` 이 있다 — 포맷 표는 없지만 ruff 설정
    const empty: FakeFs = .{ .files = &.{} };
    try testing.expect(detectPython(empty, "/r", "/r", &out) == null);
    try testing.expect(tomlHasTable("[tool.ruff]\n", "tool.ruff", false));
    try testing.expect(tomlHasTable("  [ tool.ruff ]  # c\n", "tool.ruff", false));
    try testing.expect(!tomlHasTable("[tool.ruffx]\n", "tool.ruff", true));
    try testing.expect(tomlHasTable("[tool.ruff.lint]\n", "tool.ruff", true));
    try testing.expect(!tomlHasTable("[tool.ruff.lint]\n", "tool.ruff", false));
    try testing.expect(!tomlHasTable("x = \"[tool.black]\"\n", "tool.black", false));
}

test "EXF7 Rust edition — [package] 의 edition 만(다른 표·주석 아닌 값·모양 틀림은 아님), 가장 가까운 Cargo.toml" {
    try testing.expectEqualStrings("2021", cargoEdition("[package]\nname = \"x\"\nedition = \"2021\"\n").?);
    try testing.expectEqualStrings("2024", cargoEdition("[package]\n  edition=\"2024\"  \n[dependencies]\n").?);
    try testing.expect(cargoEdition("[workspace.package]\nedition = \"2021\"\n") == null);
    try testing.expect(cargoEdition("[package]\neditions = \"2021\"\n") == null);
    try testing.expect(cargoEdition("[package]\nedition = 2021\n") == null);
    try testing.expect(cargoEdition("[package]\nedition = \"20x1\"\n") == null);
    try testing.expect(cargoEdition("edition = \"2021\"\n") == null); // [package] 밖
    const fs: FakeFs = .{ .files = &.{.{ .path = "/w/crates/a/Cargo.toml" }} };
    var out: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/w/crates/a/Cargo.toml", findNearest(fs, "/w/crates/a/src", "/w", "Cargo.toml", &out).?);
    try testing.expect(findNearest(fs, "/w/other", "/w", "Cargo.toml", &out) == null);
}

test "EXF8 argv — 도구마다 공식 모양(stdin→stdout), 사용자 명령은 큰따옴표·{path}(낱말 안에서도)·첫 낱말은 찾은 실행 파일; 틀린 명령은 못 만든다" {
    var a: Argv = undefined;
    const want = struct {
        fn eq(got: []const []const u8, exp: []const []const u8) !void {
            try testing.expectEqual(exp.len, got.len);
            for (exp, got) |e, g| try testing.expectEqualStrings(e, g);
        }
    }.eq;
    try testing.expect(argv(&a, .prettier, "/b/prettier", "/r/a.ts", null, ""));
    try want(a.slice(), &.{ "/b/prettier", "--stdin-filepath", "/r/a.ts" });
    try testing.expect(argv(&a, .biome, "/b/biome", "/r/a.ts", null, ""));
    try want(a.slice(), &.{ "/b/biome", "format", "--stdin-file-path=/r/a.ts" });
    try testing.expect(argv(&a, .oxfmt, "/b/oxfmt", "/r/a.ts", null, ""));
    try want(a.slice(), &.{ "/b/oxfmt", "--stdin-filepath", "/r/a.ts" });
    try testing.expect(argv(&a, .ruff, "/b/ruff", "/r/a.py", null, ""));
    try want(a.slice(), &.{ "/b/ruff", "format", "--stdin-filename", "/r/a.py", "-" });
    try testing.expect(argv(&a, .black, "/b/black", "/r/a.py", null, ""));
    try want(a.slice(), &.{ "/b/black", "-q", "--stdin-filename", "/r/a.py", "-" });
    try testing.expect(argv(&a, .rustfmt, "/b/rustfmt", "/r/a.rs", "2021", ""));
    try want(a.slice(), &.{ "/b/rustfmt", "--emit", "stdout", "--edition", "2021" });
    try testing.expect(argv(&a, .rustfmt, "/b/rustfmt", "/r/a.rs", null, ""));
    try want(a.slice(), &.{ "/b/rustfmt", "--emit", "stdout" });
    try testing.expect(argv(&a, .zig_fmt, "/b/zig", "/r/a.zig", null, ""));
    try want(a.slice(), &.{ "/b/zig", "fmt", "--stdin" });
    try testing.expect(argv(&a, .command, "/usr/local/bin/gofumpt", "/r/a b.go", null, "gofumpt -extra \"--file={path}.bak\" {path}"));
    try want(a.slice(), &.{ "/usr/local/bin/gofumpt", "-extra", "--file=/r/a b.go.bak", "/r/a b.go" });
    try testing.expect(!argv(&a, .command, "/x", "/r/a", null, "say \"unclosed"));
    try testing.expect(!argv(&a, .command, "/x", "/r/a", null, "   "));
    var words: [max_args][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 3), commandArgs("  a  \"b c\" d ", &words).?.len);
    try testing.expectEqualStrings("b c", commandArgs("a \"b c\"", &words).?[1]);
    try testing.expect(commandArgs("\"\" x", &words) == null); // 빈 첫 낱말
    try testing.expectEqualStrings("gofumpt", commandName("/opt/bin/gofumpt -w"));
    try testing.expectEqualStrings("command", commandName(""));
}

test "EXF4 설정의 언어 칸은 편집기 문법 이름과 같다(`none` 빼고) — 문법을 더하면 설정 칸도; 칸으로 그 문법의 값을 찾는다; 설정 값 읽기" {
    const fields = @typeInfo(language.Grammar).@"enum".fields;
    try testing.expectEqual(fields.len - 1, config_theme.formatter_languages.len);
    inline for (fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "none")) continue;
        try testing.expect(config_theme.formatterLanguageIndex(f.name) != null);
    }
    var settings: [config_theme.formatter_languages.len]Setting = @splat(.{});
    settings[config_theme.formatterLanguageIndex("typescript").?] = .{ .choice = .off };
    try testing.expectEqual(Choice.off, settingFor(&settings, .typescript).choice);
    try testing.expectEqual(Choice.auto, settingFor(&settings, .tsx).choice);
    try testing.expectEqual(Choice.auto, settingFor(&settings, .none).choice);
    // 설정 값의 철자.
    const ps = config_theme.parseFormatterSetting;
    try testing.expectEqual(Choice.zig_fmt, ps("zig-fmt").?.choice);
    try testing.expect(ps("zig_fmt") == null);
    try testing.expect(ps("command") == null);
    try testing.expectEqualStrings("ruff format -", ps("command:  ruff format - ").?.command);
    try testing.expect(ps("command:  ") == null);
    try testing.expectEqual(Choice.biome, ps(" biome ").?.choice);
    try testing.expect(ps("Biome") == null);
    // 선택지 ↔ 종류.
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        const k: Kind = @enumFromInt(f.value);
        const c = std.meta.stringToEnum(Choice, f.name).?;
        try testing.expectEqual(k, Kind.fromChoice(c).?);
    }
}
