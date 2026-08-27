//! 파일이 어떤 **언어**인가 — 확장자·파일명에서 정한다.
//!
//! **§5가 이 절을 소유한다고 세 곳이 가리키는데 §5에는 그 절이 없었다**(적대적 검증 2026-08-27).
//! §5는 하이라이트 스팬이고 언어를 `init(문서 bytes, 언어)`의 **입력으로 받는** 쪽이다 —
//! 어떻게 정하는지는 아무도 소유하지 않았다. 계약은 **문서 모델 §3.7a**가 새로 소유하고 이 모듈이
//! 코드 쪽 단일 출처다. 묻는 곳이 셋이라 답하는 곳이 하나여야 했다:
//!
//! - **주석 토글**(§3.7) — `lineComment`가 그 문법을 준다. **이 슬라이스의 유일한 실소비처다.**
//! - **클립보드 `language`**(§3.4) — 붙여넣기가 언어별 판단을 하려면 필요하다.
//! - **상태바 언어 표시**(layering §4.1) — 배치는 `status-bar.md`가 소유하고 **아직 칸이 없다**.
//!
//! **tree-sitter는 여기 없다 — 다만 막혀서가 아니다.** 의존성은 2026-08-09 사용자 논의를 거친
//! 예외로 `project-rules.md` §의존성에 적혀 있다(초판 주석은 *"논의 전이라 채택 불가"*라고 적었는데
//! **규칙을 확인하지 않고 쓴 것이라 틀렸다**). 여기 없는 이유는 다른 것이다: 언어 판정은 grammar의
//! **전제**이지 결과가 아니라서 — 붙을 때 그대로 넘겨주는 입력이 된다 — 먼저 서도 순서가 뒤집히지
//! 않고, grammar 없이도 주석 토글이 성립한다.
//!
//! **아이콘 표(`chrome/file_tree_icon.zig`)와 어휘가 다르다.** 그쪽은 zig·rs·py를 **한 아이콘**으로
//! 뭉뚱그리고 이쪽은 **낱낱이** 갈라야 한다(주석 문법이 다르다). 그래서 표를 합치지 않는다 —
//! 합치면 한쪽의 뭉뚱그림이 다른 쪽의 정확도를 깎는다.

const std = @import("std");

/// 아는 언어. **주석 문법이 갈리는 단위**로 나눈다 — 색을 위해 더 잘게 나누는 것은 grammar가
/// 붙을 때의 일이고, 지금 그렇게 나누면 읽는 사람 없는 구분이 생긴다.
pub const Language = enum {
    zig,
    c_like, // c·h·cpp·hpp·m·mm·java·js·ts·go·rs·swift·kt·cs — 전부 `//`와 `/* */`
    shell, // sh·bash·zsh·fish·py·rb·pl·yaml·toml·conf — `#`
    lisp, // lisp·clj·scm — `;`
    sql, // sql — `--`
    lua, // lua — `--`와 `--[[ ]]`
    html, // html·xml·svg·vue — `<!-- -->`만
    css, // css·scss·less — `/* */`만
    plain, // 모르는 것 — **주석 토글이 no-op이다**(§3.7)

    /// 사람이 읽는 이름. 상태바가 쓸 자리이고, **없으면 표시하지 않는다**(layering §4.1).
    pub fn displayName(self: Language) ?[]const u8 {
        return switch (self) {
            .zig => "Zig",
            .c_like => "C-like",
            .shell => "Shell",
            .lisp => "Lisp",
            .sql => "SQL",
            .lua => "Lua",
            .html => "HTML",
            .css => "CSS",
            .plain => null,
        };
    }

    /// 줄 주석 문법. `null`이면 그 언어에 줄 주석이 없다.
    ///
    /// **`plain`이 `null`인 것이 계약이다**(§3.7 — *"없으면 주석 토글이 no-op"*). 모르는 파일에
    /// 아무 문법이나 넣으면 사용자가 **그 언어에 없는 문자**를 문서에 박게 된다.
    pub fn lineComment(self: Language) ?[]const u8 {
        return switch (self) {
            .zig, .c_like => "//",
            .shell => "#",
            .lisp => ";",
            .sql, .lua => "--",
            .html, .css, .plain => null,
        };
    }
};

/// 확장자·파일명으로 언어를 정한다.
///
/// **파일명을 먼저 본다** — `Makefile`·`Dockerfile`처럼 확장자가 없는데 문법이 정해진 것들이 있다.
pub fn forPath(path: []const u8) Language {
    const name = std.fs.path.basename(path);
    // **확장자가 없는 이름들.** 셸 계열(`#` 주석)로 묶는다 — 이들을 모르면 `.zshrc`를 열고
    // `⌘/`를 눌렀을 때 아무 일도 일어나지 않는다.
    if (anyIgnoreCase(name, &.{
        "Makefile", "Dockerfile", "Justfile",      ".gitignore", ".gitconfig",
        ".zshrc",   ".zshenv",    ".zprofile",     ".bashrc",    ".bash_profile",
        ".profile", ".npmrc",     ".editorconfig",
    })) return .shell;

    // **마지막 점 뒤가 확장자다** — `editor.test.zig`는 zig이고 `app.min.js`는 js다(LANG5).
    // 이름이 점으로 끝나면 여기서 빈 확장자가 나오고, 어느 목록에도 없어 `.plain`으로 떨어진다.
    // **따로 막지 않는다** — `name[name.len..]`은 빈 슬라이스라 안전하고, 막아 봐야 같은 답이
    // 두 곳에서 나온다(적대적 검증 2026-08-27: 그 방어를 지워도 판정자가 하나도 안 죽었다).
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .plain;
    const ext = name[dot + 1 ..];

    if (eqlIgnoreCase(ext, "zig")) return .zig;
    if (anyIgnoreCase(ext, &.{
        "c",    "h",  "cc",    "cpp", "cxx", "hpp", "hh",    "m",    "mm",
        "java", "js", "jsx",   "mjs", "cjs", "ts",  "tsx",   "mts",  "cts",
        "go",   "rs", "swift", "kt",  "kts", "cs",  "scala", "dart", "php",
    })) return .c_like;
    if (anyIgnoreCase(ext, &.{
        "sh",   "bash", "zsh",  "fish", "py",   "rb",  "pl",  "r",
        "yaml", "yml",  "toml", "ini",  "conf", "cfg", "env", "mk",
    })) return .shell;
    if (anyIgnoreCase(ext, &.{ "lisp", "clj", "cljs", "scm", "el" })) return .lisp;
    if (eqlIgnoreCase(ext, "sql")) return .sql;
    if (eqlIgnoreCase(ext, "lua")) return .lua;
    if (anyIgnoreCase(ext, &.{ "html", "htm", "xml", "svg", "vue", "svelte" })) return .html;
    if (anyIgnoreCase(ext, &.{ "css", "scss", "sass", "less" })) return .css;
    return .plain;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn anyIgnoreCase(ext: []const u8, list: []const []const u8) bool {
    for (list) |e| if (eqlIgnoreCase(ext, e)) return true;
    return false;
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "LANG1: 확장자가 언어를 정한다 — 대소문자는 안 가린다" {
    try testing.expectEqual(Language.zig, forPath("/a/b/main.zig"));
    try testing.expectEqual(Language.c_like, forPath("x.CPP")); // 대문자 확장자도 흔하다
    try testing.expectEqual(Language.shell, forPath("deploy.sh"));
    try testing.expectEqual(Language.sql, forPath("q.sql"));
    try testing.expectEqual(Language.css, forPath("a.scss"));
    try testing.expectEqual(Language.html, forPath("index.html"));
}

test "LANG6: 셸 rc 파일과 점으로 끝나는 이름 (§3.7a)" {
    // **`.zshrc`는 확장자가 없다.** `.` 뒤를 확장자로 보면 "zshrc"가 되는데 그런 확장자는 없어
    // `plain`으로 떨어지고, 사용자는 셸 설정 파일에서 `⌘/`가 죽은 것을 본다.
    try std.testing.expectEqual(Language.shell, forPath("/Users/x/.zshrc"));
    try std.testing.expectEqual(Language.shell, forPath("/Users/x/.bash_profile"));
    try std.testing.expectEqual(@as(?[]const u8, "#"), forPath(".zshrc").lineComment());

    // **이름이 점으로 끝나면 확장자가 빈 문자열이다.** 따로 막지 않아도 `plain`이어야 한다
    // — 이 판정자가 그 전제를 잡고 있어야 방어를 지운 것이 안전하다.
    try std.testing.expectEqual(Language.plain, forPath("weird."));
    try std.testing.expectEqual(Language.plain, forPath("/tmp/weird."));
    try std.testing.expectEqual(@as(?[]const u8, null), forPath("weird.").lineComment());
}

test "LANG5: 점이 여럿인 이름은 마지막 점 뒤가 확장자다" {
    // **`a.test.zig`·`app.min.js`처럼 점이 여럿인 이름이 흔하다.** 첫 점을 구분자로 삼으면
    // `test.zig`가 확장자가 되어 아무것도 못 알아본다 — 그 상태로 뮤턴트가 살아남았다
    // (적대적 검증 2026-08-27).
    try testing.expectEqual(Language.zig, forPath("editor.test.zig"));
    try testing.expectEqual(Language.c_like, forPath("app.min.js"));
    try testing.expectEqual(Language.shell, forPath("docker-compose.override.yml"));
    // 경로에 점이 있어도 **파일명만** 본다.
    try testing.expectEqual(Language.zig, forPath("/a.b/c.d/main.zig"));
}

test "LANG2: 모르면 plain이고, 그때 주석 토글은 no-op이다 (§3.7)" {
    // **모르는 파일에 아무 문법이나 넣으면 사용자가 그 언어에 없는 문자를 문서에 박는다.**
    try testing.expectEqual(Language.plain, forPath("data.bin"));
    try testing.expectEqual(Language.plain, forPath("noext"));
    try testing.expectEqual(Language.plain, forPath("trailing."));
    try testing.expect(Language.plain.lineComment() == null);
    try testing.expect(Language.plain.displayName() == null); // 상태바도 표시 안 한다
}

test "LANG3: 확장자 없는 이름도 안다 — Makefile·Dockerfile" {
    // 확장자가 없는데 문법이 정해진 것들이 있다. **이름을 먼저 봐야** 잡힌다.
    try testing.expectEqual(Language.shell, forPath("/p/Makefile"));
    try testing.expectEqual(Language.shell, forPath("dockerfile")); // 소문자로도 쓴다
    try testing.expectEqual(Language.shell, forPath(".gitignore"));
    // **숨김 파일의 점은 확장자 구분자가 아니다** — `.gitignore`가 "gitignore 확장자"가 아니다.
    try testing.expectEqual(Language.plain, forPath(".unknownrc"));
}

test "LANG4: 줄 주석 문법이 언어마다 갈린다 (§3.7)" {
    try testing.expectEqualStrings("//", Language.zig.lineComment().?);
    try testing.expectEqualStrings("//", Language.c_like.lineComment().?);
    try testing.expectEqualStrings("#", Language.shell.lineComment().?);
    try testing.expectEqualStrings(";", Language.lisp.lineComment().?);
    try testing.expectEqualStrings("--", Language.sql.lineComment().?);
    // **HTML·CSS는 줄 주석이 없다** — 블록만 있다. 없는 것을 있다고 하면 `<!--`가 반쪽만 들어간다.
    try testing.expect(Language.html.lineComment() == null);
    try testing.expect(Language.css.lineComment() == null);
}
