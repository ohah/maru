//! 언어 → 언어 서버 **내장 표**(docs/editor-surface-tooling.md §8.2a 「서버 찾기」·「설치 안내」). 실행 파일 이름으로 찾고(PATH → 통상 설치 위치 — 찾기는 플랫폼 층),
//! 없으면 설치 명령을 새 터미널 탭에 **입력만** 한다(§8.1a — Enter 는 사용자). config override 는 2단.

const std = @import("std");
const language = @import("../editor/language.zig");

pub const Server = struct {
    /// 찾을 실행 파일 이름(argv[0]).
    exe: []const u8,
    /// 나머지 인자(`--stdio` 등).
    args: []const []const u8,
    /// LSP `languageId`.
    language_id: []const u8,
    /// 설치 명령(brew·npm·rustup·go). 사용자 환경이 다르면 2단의 override 가 맡는다.
    install: []const u8,
    /// 그 문법인데도 **이 서버가 다루지 않는 확장자**(대소문자 무시, 점 없이). 그런 문서에는 주 서버가 없다 — Bash 서버는 `.zsh` 에
    /// shellcheck 를 돌려 zsh shebang 파일마다 「ShellCheck only supports sh/bash…」 오류를 냈다(계획 editor-lsp-servers-expand LS1 실측).
    skip_extensions: []const []const u8 = &.{},
    /// 파일 진단을 pull 로만 내는 서버(push 를 안 한다 — ESLint 2026-10-13 실측, tsgo·ruby-lsp 계획 editor-lsp-servers-expand LS2·LS4 실측). 그 서버의 클라이언트에만
    /// `initialize` 에서 `textDocument.diagnostic` 을 알리고 문서를 보낼 때마다 묻는다(§8.2u). 주 서버·보조 서버가 같은 칸이다.
    pull_diagnostics: bool = false,
    /// pull 앞에 장벽을 친다 — 장벽 요청(`rpc.pullBarrierRequest`)의 답이 온 뒤에 pull 을 묻는다(§8.2u). 요청을 읽기 스레드가 **그때 적용된
    /// 본문**으로 곧 파싱하고 didChange 는 작업 스레드가 나중에 적용하는 서버 — ruby-lsp(계획 editor-lsp-servers-expand LS4 실측: 바로 묻든
    /// 30 ms 를 띄우든 타이핑 중 옛 본문의 진단을 계산해 다음 편집까지 캐시했다). 다른 pull 서버는 didChange 를 먼저 적용한다(tsgo·ESLint — 바로 묻는다).
    pull_barrier: bool = false,
    /// gopls는 provider를 알리고도 기본 설정에서는 빈 토큰을 낸다(v0.20 실측).
    enable_semantic_tokens: bool = false,

    /// 그 경로의 문서를 다루나(`skip_extensions`).
    pub fn serves(self: Server, path: []const u8) bool {
        const ext = std.fs.path.extension(path);
        if (ext.len < 2) return true;
        for (self.skip_extensions) |e| if (std.ascii.eqlIgnoreCase(ext[1..], e)) return false;
        return true;
    }
};

const stdio = [_][]const u8{"--stdio"};
const lsp_stdio = [_][]const u8{ "--lsp", "--stdio" };
const none = [_][]const u8{};
const start = [_][]const u8{"start"}; // bash-language-server
const taplo_lsp = [_][]const u8{ "lsp", "stdio" };
const dart_lsp = [_][]const u8{ "language-server", "--protocol=lsp" };

/// TS 계열의 후보 셋(§8.2a 「서버 찾기」, 2026-09-20 사용자 결정 「tsgo 도 되어야」) — 찾아지는 **첫** 것을 쓴다. `language_id` 는 문법마다
/// 다르므로 `candidatesFor` 가 채워 낸다.
const ts_native_install = "npm i -g @typescript/native-preview";
const ts_legacy_install = "npm i -g typescript-language-server typescript@5";
fn tsCandidates(comptime language_id: []const u8) [3]Server {
    return .{
        // TS 7 네이티브는 파일 진단을 pull 로만 낸다 — push 는 tsconfig 의 진단뿐이다(계획 editor-lsp-servers-expand LS2 실측: 2026-01~07 판 전부).
        .{ .exe = "tsgo", .args = &lsp_stdio, .language_id = language_id, .install = ts_native_install, .pull_diagnostics = true },
        .{ .exe = "typescript-language-server", .args = &stdio, .language_id = language_id, .install = ts_legacy_install }, // push 로 낸다(실측)
        // typescript@7 의 `tsc` 는 같은 네이티브 LSP 다(그래서 pull 도 같다). TS 5 의 `tsc` 는 `--lsp` 를 몰라 곧 죽고 backoff 뒤 「실패」로 선다(계약이 그렇게 적었다).
        .{ .exe = "tsc", .args = &lsp_stdio, .language_id = language_id, .install = ts_native_install, .pull_diagnostics = true },
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
        // Objective-C 도 clangd 다(같은 실행 파일 — LSP 언어 ID 는 `objective-c`). 진단의 출처가 언어 서버뿐이 되며(§5.4, 2026-10-15 사용자 결정)
        // 매크로를 펼치는 진짜 진단이 여기서 온다 — tree-sitter 는 전처리기를 몰라 정상 코드에 거짓 오류를 냈다.
        .objc => &[_]Server{.{ .exe = "clangd", .args = &none, .language_id = "objective-c", .install = "brew install llvm" }},
        .typescript => &ts_candidates,
        .tsx => &tsx_candidates,
        .javascript => &js_candidates,
        .rust => &[_]Server{.{ .exe = "rust-analyzer", .args = &none, .language_id = "rust", .install = "rustup component add rust-analyzer" }},
        .python => &[_]Server{.{ .exe = "pyright-langserver", .args = &stdio, .language_id = "python", .install = "npm i -g pyright" }},
        .go => &[_]Server{.{ .exe = "gopls", .args = &none, .language_id = "go", .install = "go install golang.org/x/tools/gopls@latest", .enable_semantic_tokens = true }},
        // 언어 서버 후보 확대 LS1(계획 editor-lsp-servers-expand — 2026-10-16, maru 와 같은 능력으로 실측해 통과한 열다섯).
        .swift => &[_]Server{.{ .exe = "sourcekit-lsp", .args = &none, .language_id = "swift", .install = "xcode-select --install" }},
        .dart => &[_]Server{.{ .exe = "dart", .args = &dart_lsp, .language_id = "dart", .install = "brew install dart-sdk" }},
        // `DOTNET_ROOT` 가 셸에 있어야 뜬다(brew .NET 의 caveat) — 서버 찾기는 사용자 셸의 환경을 그대로 쓴다(tooling §8.2a 「설치 안내」).
        .csharp => &[_]Server{.{ .exe = "csharp-ls", .args = &none, .language_id = "csharp", .install = "dotnet tool install --global csharp-ls" }},
        // metals 는 저장(`didSave`)에 컴파일한다 — 진단도 저장에 바뀐다. 첫 기동은 빌드 도구를 내려받는다(실측 79 s).
        .scala => &[_]Server{.{ .exe = "metals", .args = &none, .language_id = "scala", .install = "brew install metals" }},
        .java => &[_]Server{.{ .exe = "jdtls", .args = &none, .language_id = "java", .install = "brew install jdtls" }},
        .kotlin => &[_]Server{.{ .exe = "kotlin-language-server", .args = &none, .language_id = "kotlin", .install = "brew install kotlin-language-server" }},
        .php => &[_]Server{.{ .exe = "intelephense", .args = &stdio, .language_id = "php", .install = "npm i -g intelephense" }},
        .lua => &[_]Server{.{ .exe = "lua-language-server", .args = &none, .language_id = "lua", .install = "brew install lua-language-server" }},
        // 진단은 shellcheck 가 있을 때만 낸다(없으면 호버·완성만) — 설치 안내에 함께 적는다.
        .bash => &[_]Server{.{ .exe = "bash-language-server", .args = &start, .language_id = "shellscript", .install = "npm i -g bash-language-server", .skip_extensions = &.{"zsh"} }},
        .yaml => &[_]Server{.{ .exe = "yaml-language-server", .args = &stdio, .language_id = "yaml", .install = "npm i -g yaml-language-server" }},
        .toml => &[_]Server{.{ .exe = "taplo", .args = &taplo_lsp, .language_id = "toml", .install = "brew install taplo" }},
        .dockerfile => &[_]Server{.{ .exe = "docker-langserver", .args = &stdio, .language_id = "dockerfile", .install = "npm i -g dockerfile-language-server-nodejs" }},
        // JSON·CSS 는 보조 서버 Biome(§8.2u AS5)와 함께 간다 — 칸이 따로라 서로의 진단을 지우지 않는다.
        .json => &[_]Server{.{ .exe = "vscode-json-language-server", .args = &stdio, .language_id = "json", .install = "npm i -g vscode-langservers-extracted" }},
        .css => &[_]Server{.{ .exe = "vscode-css-language-server", .args = &stdio, .language_id = "css", .install = "npm i -g vscode-langservers-extracted" }},
        .html => &[_]Server{.{ .exe = "vscode-html-language-server", .args = &stdio, .language_id = "html", .install = "npm i -g vscode-langservers-extracted" }},
        // Ruby(LS4) — push 를 안 하고 pull 진단만 낸다(`pull_diagnostics`), 그 앞에 장벽을 친다(`pull_barrier`). 공식 권장은 프로젝트 Ruby 의 `gem install ruby-lsp` 지만 macOS 기본 Ruby
        // 로는 안 되는 경우가 있어 자기 Ruby 를 든 Homebrew 공식을 낸다(계획 editor-lsp-servers-expand 의 2026-10-20·21 실측이 이것 — 0.26.11). 첫
        // 기동에 저장소의 `Gemfile` 을 평가하고 `bundle install` 을 돈다.
        .ruby => &[_]Server{.{ .exe = "ruby-lsp", .args = &none, .language_id = "ruby", .install = "brew install ruby-lsp", .pull_diagnostics = true, .pull_barrier = true }},
        // 싣지 않는다(계획 「싣지 않는 것」 — 실측): SQL·Markdown·XML·DTD·Make 는 쓸 만한 서버가 없다.
        .none, .markdown, .xml, .dtd, .make, .sql => &.{},
    };
}

/// 문법 → **첫 후보**. 이름표가 없는 언어는 `null` — 상태바 항목도 없다(§8.2a). PATH 를 보지 않는다 — 설치된 것을 고르는 것은 `resolve`.
pub fn forGrammar(g: language.Grammar) ?Server {
    const c = candidatesFor(g);
    return if (c.len == 0) null else c[0];
}

/// 후보 중 찾아지는 **첫** 것; 하나도 없으면 첫 후보(「없음」의 이름·설치 명령이 그것). `installed` 는 실행 파일 이름으로 묻는다(순수 — 판정자가 표를 끼운다).
pub fn resolve(g: language.Grammar, ctx: anytype, comptime installed: fn (@TypeOf(ctx), []const u8) bool) ?Server {
    const c = candidatesFor(g);
    if (c.len == 0) return null;
    for (c) |s| if (installed(ctx, s.exe)) return s;
    return c[0];
}

/// 그 문법의 LSP `languageId` — 문서마다 이것을 보낸다(`didOpen`). TS·TSX·JS 는 서버 하나(`(root, exe)` 열쇠)를 나눠 쓰므로 클라이언트를 세운
/// 문서의 값(`Server.language_id`)을 그대로 쓰면 `.ts` 를 먼저 연 뒤의 `.tsx` 가 `typescript` 로 간다 — ESLint(보조 서버 tooling §8.2u)는
/// 이 값으로 검사 여부를 가른다. 보조 서버 Biome 은 이 값으로 해석기를 고른다(CSS 를 `javascript` 로 보내면 JS 구문 오류, 2026-10-13 실측) —
/// JSON·CSS 는 이제 주 서버 표가 있어(LS1) 그 값이 곧 `json`·`css` 다. 이름표 없는 문법은 `null`(호출자가 서버의 값을 쓴다).
pub fn languageIdFor(g: language.Grammar) ?[]const u8 {
    const c = candidatesFor(g);
    return if (c.len > 0) c[0].language_id else null;
}

/// 그 **문서**의 `languageId` — 문법의 값이되, 한 문법이 방언을 덮는 확장자는 그 방언의 이름이다. CSS 문법은 `.scss`·`.less` 도 덮는데
/// CSS 서버(vscode-css-language-server — 셋을 다 안다)에 `css` 로 보내면 `$c: red;`·`@c: red;` 에 거짓 오류가 셋씩 섰다(LS1 실측 —
/// `scss`·`less` 로 보내면 0). 다른 문법은 `languageIdFor` 그대로다.
pub fn languageIdForPath(g: language.Grammar, path: []const u8) ?[]const u8 {
    if (g == .css) {
        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".scss")) return "scss";
        if (std.ascii.eqlIgnoreCase(ext, ".less")) return "less";
    }
    return languageIdFor(g);
}

/// 서버 하나를 **여러 언어가 나눠 쓰는가** — c 와 cpp 는 같은 clangd, ts·tsx·js 는 같은 tsserver. 프로세스는 `(root, exe)` 마다
/// 하나이므로 키는 이것이다.
pub fn processKey(s: Server) []const u8 {
    return s.exe;
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "LSI1 이름표 — zig·c·cpp·objc·ts·tsx·js·rust·python·go 와 LS1 의 열다섯·LS4 의 Ruby 는 서버가 있고, SQL·Markdown·XML·DTD·Make·평문은 없다; ts 계열은 --stdio, 같은 서버는 같은 키 (§8.2a)" {
    try testing.expectEqualStrings("zls", forGrammar(.zig).?.exe);
    try testing.expectEqualStrings("clangd", forGrammar(.c).?.exe);
    try testing.expectEqualStrings("clangd", forGrammar(.cpp).?.exe);
    try testing.expectEqualStrings("cpp", forGrammar(.cpp).?.language_id);
    try testing.expectEqualStrings(processKey(forGrammar(.c).?), processKey(forGrammar(.cpp).?));
    // Objective-C 도 clangd — 언어 ID 만 다르고 같은 서버 프로세스다(2026-10-15, 진단은 언어 서버로만).
    try testing.expectEqualStrings("clangd", forGrammar(.objc).?.exe);
    try testing.expectEqualStrings("objective-c", forGrammar(.objc).?.language_id);
    try testing.expectEqualStrings(processKey(forGrammar(.c).?), processKey(forGrammar(.objc).?));
    const ts = forGrammar(.typescript).?; // 첫 후보 = tsgo
    try testing.expectEqualStrings("tsgo", ts.exe);
    try testing.expectEqual(@as(usize, 2), ts.args.len);
    try testing.expectEqualStrings("--lsp", ts.args[0]);
    try testing.expectEqualStrings("--stdio", ts.args[1]);
    try testing.expectEqualStrings("typescriptreact", forGrammar(.tsx).?.language_id);
    try testing.expectEqual(@as(usize, 0), forGrammar(.zig).?.args.len);
    // 싣지 않은 것(계획 editor-lsp-servers-expand 「싣지 않는 것」 — 실측).
    inline for (.{ .none, .markdown, .xml, .dtd, .make, .sql }) |g| try testing.expect(forGrammar(g) == null);
    // 설치 명령은 전부 있고 개행이 없다(한 줄을 입력한다).
    inline for (@import("type_info_fields").enumFields(language.Grammar)) |f| {
        const g: language.Grammar = @fromBackingInt(@intCast(f.value));
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

test "LSS1 문서의 languageId 는 그 문법의 값이다 — 서버를 나눠 쓰는 TS·TSX·JS 도 문서마다 (tooling §8.2u)" {
    try std.testing.expectEqualStrings("typescript", languageIdFor(.typescript).?);
    try std.testing.expectEqualStrings("typescriptreact", languageIdFor(.tsx).?);
    try std.testing.expectEqualStrings("javascript", languageIdFor(.javascript).?);
    try std.testing.expectEqualStrings("python", languageIdFor(.python).?);
    try std.testing.expectEqualStrings("json", languageIdFor(.json).?); // 주 서버(LS1)와 보조 서버(Biome)가 같은 값을 받는다
    try std.testing.expectEqualStrings("css", languageIdFor(.css).?);
    try std.testing.expect(languageIdFor(.markdown) == null);
}

test "LSI3 언어 서버 후보 확대 LS1 — 열다섯의 실행 파일·인자·languageId·설치 명령이 실측한 그대로다 (계획 editor-lsp-servers-expand)" {
    const Row = struct { g: language.Grammar, exe: []const u8, args: []const []const u8, id: []const u8, install: []const u8 };
    const rows = [_]Row{
        .{ .g = .swift, .exe = "sourcekit-lsp", .args = &.{}, .id = "swift", .install = "xcode-select --install" },
        .{ .g = .dart, .exe = "dart", .args = &.{ "language-server", "--protocol=lsp" }, .id = "dart", .install = "brew install dart-sdk" },
        .{ .g = .csharp, .exe = "csharp-ls", .args = &.{}, .id = "csharp", .install = "dotnet tool install --global csharp-ls" },
        .{ .g = .scala, .exe = "metals", .args = &.{}, .id = "scala", .install = "brew install metals" },
        .{ .g = .java, .exe = "jdtls", .args = &.{}, .id = "java", .install = "brew install jdtls" },
        .{ .g = .kotlin, .exe = "kotlin-language-server", .args = &.{}, .id = "kotlin", .install = "brew install kotlin-language-server" },
        .{ .g = .php, .exe = "intelephense", .args = &.{"--stdio"}, .id = "php", .install = "npm i -g intelephense" },
        .{ .g = .lua, .exe = "lua-language-server", .args = &.{}, .id = "lua", .install = "brew install lua-language-server" },
        .{ .g = .bash, .exe = "bash-language-server", .args = &.{"start"}, .id = "shellscript", .install = "npm i -g bash-language-server" },
        .{ .g = .yaml, .exe = "yaml-language-server", .args = &.{"--stdio"}, .id = "yaml", .install = "npm i -g yaml-language-server" },
        .{ .g = .toml, .exe = "taplo", .args = &.{ "lsp", "stdio" }, .id = "toml", .install = "brew install taplo" },
        .{ .g = .dockerfile, .exe = "docker-langserver", .args = &.{"--stdio"}, .id = "dockerfile", .install = "npm i -g dockerfile-language-server-nodejs" },
        .{ .g = .json, .exe = "vscode-json-language-server", .args = &.{"--stdio"}, .id = "json", .install = "npm i -g vscode-langservers-extracted" },
        .{ .g = .css, .exe = "vscode-css-language-server", .args = &.{"--stdio"}, .id = "css", .install = "npm i -g vscode-langservers-extracted" },
        .{ .g = .html, .exe = "vscode-html-language-server", .args = &.{"--stdio"}, .id = "html", .install = "npm i -g vscode-langservers-extracted" },
    };
    for (rows) |r| {
        errdefer std.debug.print("LSI3 {s}\n", .{@tagName(r.g)});
        const c = candidatesFor(r.g);
        try testing.expectEqual(@as(usize, 1), c.len);
        try testing.expectEqualStrings(r.exe, c[0].exe);
        try testing.expectEqual(r.args.len, c[0].args.len);
        for (r.args, c[0].args) |a, b| try testing.expectEqualStrings(a, b);
        try testing.expectEqualStrings(r.id, c[0].language_id);
        try testing.expectEqualStrings(r.id, languageIdFor(r.g).?);
        try testing.expectEqualStrings(r.install, c[0].install);
        try testing.expect(!c[0].pull_diagnostics); // 열다섯은 push 로 낸다(실측)
    }
}

test "LSI8 TS 7 네이티브(`tsgo`·TS 7 의 `tsc`)는 파일 진단을 pull 로만 낸다 — 그 둘만 pull 칸이 켜지고 `typescript-language-server` 는 push; 주 서버 표에서 pull 칸이 켜진 자리는 TS·TSX·JS 마다 그 둘과 Ruby 하나, 모두 일곱 (계획 editor-lsp-servers-expand LS2·LS4)" {
    inline for (.{ .typescript, .tsx, .javascript }) |g| {
        const c = candidatesFor(g);
        try testing.expectEqualStrings("tsgo", c[0].exe);
        try testing.expect(c[0].pull_diagnostics);
        try testing.expectEqualStrings("typescript-language-server", c[1].exe);
        try testing.expect(!c[1].pull_diagnostics);
        try testing.expectEqualStrings("tsc", c[2].exe);
        try testing.expect(c[2].pull_diagnostics);
    }
    // 표를 훑어 **켜진 자리를 센다** — pull 칸은 실측으로 push 를 안 낸 서버에만(켜면 그 서버에 묻는 요청이 문서마다 늘고, 꺼 두면 진단이 영영 안 온다).
    var n: usize = 0;
    for (std.enums.values(language.Grammar)) |g| for (candidatesFor(g)) |s| {
        if (s.pull_diagnostics) {
            try testing.expect(std.mem.eql(u8, s.exe, "tsgo") or std.mem.eql(u8, s.exe, "tsc") or std.mem.eql(u8, s.exe, "ruby-lsp"));
            n += 1;
        }
    };
    try testing.expectEqual(@as(usize, 7), n);
}

test "LSI9 Ruby(`ruby-lsp`) — pull 진단만 내는 주 서버(그 앞에 장벽 — 서버 표에서 이 하나뿐), 인자 없음, languageId `ruby`, 설치는 Homebrew 공식 (계획 editor-lsp-servers-expand LS4)" {
    const c = candidatesFor(.ruby);
    try testing.expectEqual(@as(usize, 1), c.len);
    const r = c[0];
    try testing.expectEqualStrings("ruby-lsp", r.exe);
    try testing.expectEqual(@as(usize, 0), r.args.len);
    try testing.expectEqualStrings("ruby", r.language_id);
    try testing.expectEqualStrings("ruby", languageIdFor(.ruby).?);
    try testing.expectEqualStrings("brew install ruby-lsp", r.install);
    try testing.expect(r.pull_diagnostics);
    try testing.expect(r.pull_barrier);
    // 장벽 칸이 켜진 자리는 이 하나뿐이다(LS4 — tsgo·tsc·ESLint 는 didChange 를 먼저 적용한다). 장벽은 pull 서버에만 뜻이 있다.
    var n: usize = 0;
    for (std.enums.values(language.Grammar)) |g| for (candidatesFor(g)) |sv| if (sv.pull_barrier) {
        try testing.expect(sv.pull_diagnostics);
        n += 1;
    };
    try testing.expectEqual(@as(usize, 1), n);
}

test "LSI4 문서마다 — CSS 문법의 `.scss`·`.less` 는 그 방언의 languageId, Bash 서버는 `.zsh` 를 안 다룬다(LS1 실측) (계획 editor-lsp-servers-expand)" {
    try testing.expectEqualStrings("css", languageIdForPath(.css, "/r/a.css").?);
    try testing.expectEqualStrings("scss", languageIdForPath(.css, "/r/a.SCSS").?);
    try testing.expectEqualStrings("less", languageIdForPath(.css, "/r/a.less").?);
    try testing.expectEqualStrings("json", languageIdForPath(.json, "/r/a.scss").?); // 방언 이름은 CSS 문법에만
    try testing.expect(languageIdForPath(.markdown, "/r/a.md") == null);
    const sh = forGrammar(.bash).?;
    try testing.expect(sh.serves("/r/a.sh") and sh.serves("/r/a.bash") and sh.serves("/r/script"));
    try testing.expect(!sh.serves("/r/a.zsh") and !sh.serves("/r/a.ZSH"));
    try testing.expect(forGrammar(.css).?.serves("/r/a.scss")); // CSS 서버는 셋을 다 안다
}
