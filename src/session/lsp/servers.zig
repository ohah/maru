//! 언어 → 언어 서버 **내장 표**(docs/editor-surface-tooling.md §8.2a 「서버 찾기」·「설치 안내」). PATH 에서 실행 파일 이름으로 찾고,
//! 없으면 설치 명령을 새 터미널 탭에 **입력만** 한다(§8.1a — Enter 는 사용자). config override 는 2단.

const std = @import("std");
const language = @import("../editor/language.zig");

pub const Server = struct {
    /// PATH 에서 찾을 실행 파일 이름(argv[0]).
    exe: []const u8,
    /// 나머지 인자(`--stdio` 등).
    args: []const []const u8,
    /// LSP `languageId`.
    language_id: []const u8,
    /// 설치 명령(brew·npm·rustup·go). 사용자 환경이 다르면 2단의 override 가 맡는다.
    install: []const u8,
};

const stdio = [_][]const u8{"--stdio"};
const lsp_stdio = [_][]const u8{ "--lsp", "--stdio" };
const none = [_][]const u8{};

/// TS 계열의 후보 셋(§8.2a 「서버 찾기」, 2026-09-20 사용자 결정 「tsgo 도 되어야」) — PATH 에 있는 **첫** 것을 쓴다. `language_id` 는 문법마다
/// 다르므로 `candidatesFor` 가 채워 낸다.
const ts_native_install = "npm i -g @typescript/native-preview";
const ts_legacy_install = "npm i -g typescript-language-server typescript@5";
fn tsCandidates(comptime language_id: []const u8) [3]Server {
    return .{
        .{ .exe = "tsgo", .args = &lsp_stdio, .language_id = language_id, .install = ts_native_install },
        .{ .exe = "typescript-language-server", .args = &stdio, .language_id = language_id, .install = ts_legacy_install },
        // typescript@7 의 `tsc` 는 같은 네이티브 LSP 다. TS 5 의 `tsc` 는 `--lsp` 를 몰라 곧 죽고 backoff 뒤 「실패」로 선다(계약이 그렇게 적었다).
        .{ .exe = "tsc", .args = &lsp_stdio, .language_id = language_id, .install = ts_native_install },
    };
}
const ts_candidates = tsCandidates("typescript");
const tsx_candidates = tsCandidates("typescriptreact");
const js_candidates = tsCandidates("javascript");

/// 문법 → 서버 **후보들**(우선순위 순). 이름표가 없는 언어는 빈 슬라이스. 대부분은 하나다.
pub fn candidatesFor(g: language.Grammar) []const Server {
    return switch (g) {
        .zig => &[_]Server{.{ .exe = "zls", .args = &none, .language_id = "zig", .install = "brew install zls" }},
        .c => &[_]Server{.{ .exe = "clangd", .args = &none, .language_id = "c", .install = "brew install llvm" }},
        .cpp => &[_]Server{.{ .exe = "clangd", .args = &none, .language_id = "cpp", .install = "brew install llvm" }},
        .typescript => &ts_candidates,
        .tsx => &tsx_candidates,
        .javascript => &js_candidates,
        .rust => &[_]Server{.{ .exe = "rust-analyzer", .args = &none, .language_id = "rust", .install = "rustup component add rust-analyzer" }},
        .python => &[_]Server{.{ .exe = "pyright-langserver", .args = &stdio, .language_id = "python", .install = "npm i -g pyright" }},
        .go => &[_]Server{.{ .exe = "gopls", .args = &none, .language_id = "go", .install = "go install golang.org/x/tools/gopls@latest" }},
        .none, .json, .markdown, .java, .ruby, .php, .kotlin, .bash, .css, .html => &.{},
    };
}

/// 문법 → **첫 후보**. 이름표가 없는 언어는 `null` — 상태바 항목도 없다(§8.2a). PATH 를 보지 않는다 — 설치된 것을 고르는 것은 `resolve`.
pub fn forGrammar(g: language.Grammar) ?Server {
    const c = candidatesFor(g);
    return if (c.len == 0) null else c[0];
}

/// 후보 중 PATH 에 있는 **첫** 것; 하나도 없으면 첫 후보(「없음」의 이름·설치 명령이 그것). `installed` 는 실행 파일 이름으로 묻는다(순수 — 판정자가 표를 끼운다).
pub fn resolve(g: language.Grammar, ctx: anytype, comptime installed: fn (@TypeOf(ctx), []const u8) bool) ?Server {
    const c = candidatesFor(g);
    if (c.len == 0) return null;
    for (c) |s| if (installed(ctx, s.exe)) return s;
    return c[0];
}

/// 서버 하나를 **여러 언어가 나눠 쓰는가** — c 와 cpp 는 같은 clangd, ts·tsx·js 는 같은 tsserver. 프로세스는 `(root, exe)` 마다
/// 하나이므로 키는 이것이다.
pub fn processKey(s: Server) []const u8 {
    return s.exe;
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "LSI1 이름표 — zig·c·cpp·ts·tsx·js·rust·python·go 는 서버가 있고 나머지는 없다; ts 계열은 --stdio, 같은 서버는 같은 키 (§8.2a)" {
    try testing.expectEqualStrings("zls", forGrammar(.zig).?.exe);
    try testing.expectEqualStrings("clangd", forGrammar(.c).?.exe);
    try testing.expectEqualStrings("clangd", forGrammar(.cpp).?.exe);
    try testing.expectEqualStrings("cpp", forGrammar(.cpp).?.language_id);
    try testing.expectEqualStrings(processKey(forGrammar(.c).?), processKey(forGrammar(.cpp).?));
    const ts = forGrammar(.typescript).?; // 첫 후보 = tsgo
    try testing.expectEqualStrings("tsgo", ts.exe);
    try testing.expectEqual(@as(usize, 2), ts.args.len);
    try testing.expectEqualStrings("--lsp", ts.args[0]);
    try testing.expectEqualStrings("--stdio", ts.args[1]);
    try testing.expectEqualStrings("typescriptreact", forGrammar(.tsx).?.language_id);
    try testing.expectEqual(@as(usize, 0), forGrammar(.zig).?.args.len);
    try testing.expect(forGrammar(.none) == null and forGrammar(.markdown) == null and forGrammar(.json) == null);
    // 설치 명령은 전부 있고 개행이 없다(한 줄을 입력한다).
    inline for (@typeInfo(language.Grammar).@"enum".fields) |f| {
        const g: language.Grammar = @enumFromInt(f.value);
        if (forGrammar(g)) |s| {
            try testing.expect(s.install.len > 0);
            try testing.expect(std.mem.indexOfScalar(u8, s.install, '\n') == null);
        }
    }
}

test "LSI2 TS 후보 셋 — tsgo → typescript-language-server → tsc 순으로 PATH 에 있는 첫 것, 하나도 없으면 첫 후보(설치 명령은 native-preview); 언어마다 language_id (§8.2a)" {
    const Ctx = struct { have: []const []const u8 };
    const has = struct {
        fn f(c: Ctx, exe: []const u8) bool {
            for (c.have) |h| if (std.mem.eql(u8, h, exe)) return true;
            return false;
        }
    }.f;
    try testing.expectEqualStrings("tsgo", resolve(.typescript, Ctx{ .have = &.{ "tsc", "typescript-language-server", "tsgo" } }, has).?.exe);
    const legacy = resolve(.tsx, Ctx{ .have = &.{ "tsc", "typescript-language-server" } }, has).?;
    try testing.expectEqualStrings("typescript-language-server", legacy.exe);
    try testing.expectEqualStrings("--stdio", legacy.args[0]);
    try testing.expectEqualStrings("typescriptreact", legacy.language_id);
    const tsc = resolve(.javascript, Ctx{ .have = &.{"tsc"} }, has).?;
    try testing.expectEqualStrings("tsc", tsc.exe);
    try testing.expectEqualStrings("--lsp", tsc.args[0]);
    try testing.expectEqualStrings("javascript", tsc.language_id);
    const missing = resolve(.typescript, Ctx{ .have = &.{} }, has).?;
    try testing.expectEqualStrings("tsgo", missing.exe);
    try testing.expect(std.mem.indexOf(u8, missing.install, "@typescript/native-preview") != null);
    try testing.expectEqualStrings("clangd", resolve(.c, Ctx{ .have = &.{} }, has).?.exe); // 후보 하나면 그것
    try testing.expect(resolve(.markdown, Ctx{ .have = &.{"tsgo"} }, has) == null);
    try testing.expectEqual(@as(usize, 3), candidatesFor(.typescript).len);
}
