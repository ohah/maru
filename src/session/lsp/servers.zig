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
const none = [_][]const u8{};

/// 문법 → 서버. 이름표가 없는 언어는 `null` — 상태바 항목도 없다(§8.2a).
pub fn forGrammar(g: language.Grammar) ?Server {
    return switch (g) {
        .zig => .{ .exe = "zls", .args = &none, .language_id = "zig", .install = "brew install zls" },
        .c => .{ .exe = "clangd", .args = &none, .language_id = "c", .install = "brew install llvm" },
        .cpp => .{ .exe = "clangd", .args = &none, .language_id = "cpp", .install = "brew install llvm" },
        .typescript => .{ .exe = "typescript-language-server", .args = &stdio, .language_id = "typescript", .install = "npm i -g typescript-language-server typescript@5" },
        .tsx => .{ .exe = "typescript-language-server", .args = &stdio, .language_id = "typescriptreact", .install = "npm i -g typescript-language-server typescript@5" },
        .javascript => .{ .exe = "typescript-language-server", .args = &stdio, .language_id = "javascript", .install = "npm i -g typescript-language-server typescript@5" },
        .rust => .{ .exe = "rust-analyzer", .args = &none, .language_id = "rust", .install = "rustup component add rust-analyzer" },
        .python => .{ .exe = "pyright-langserver", .args = &stdio, .language_id = "python", .install = "npm i -g pyright" },
        .go => .{ .exe = "gopls", .args = &none, .language_id = "go", .install = "go install golang.org/x/tools/gopls@latest" },
        .none, .json, .markdown, .java, .ruby, .php, .kotlin, .bash, .css, .html => null,
    };
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
    const ts = forGrammar(.typescript).?;
    try testing.expectEqual(@as(usize, 1), ts.args.len);
    try testing.expectEqualStrings("--stdio", ts.args[0]);
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
