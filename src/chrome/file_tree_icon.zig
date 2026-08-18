//! 파일 탐색기가 쓰는 filesystem 비의존 semantic 아이콘 분류기다. caller가 그 결과를 투영된 행 옆에
//! 보관하고, render·pointer 경로는 `IconKind`를 등록된 PUA codepoint로 내리기만 한다.

const std = @import("std");
const icons = @import("../icons.zig");
const tokens = @import("tokens.zig");

pub const IconKind = enum(u8) {
    none,
    recent,
    folder,
    folder_open,
    folder_source,
    folder_test,
    folder_docs,
    folder_assets,
    folder_config,
    folder_dependency,
    folder_output,
    file,
    code,
    web,
    data,
    config,
    git,
    image,
    document,
    archive,
    package,
    /// 웹/스크립트 계열 **세분화**(2026-08-18). 글리프는 `web` 과 같은 실루엣을 공유하고 **색으로 가른다** —
    /// maru 아이콘은 단색 coverage 라 작은 셀에 언어 글자(JS·TS)를 넣으면 뭉개진다. 참고 디자인(VS Code 계열)이
    /// 모양+색으로 가르는 것을 색 축만 취한 것이고, 모양까지 가르려면 언어마다 SVG 를 그려야 한다(후속).
    ///
    /// **끝에 추가한다** — `IconKind` 는 `file_tree.Row.icon_kind` 에 raw u8 로 실려 다니므로 중간에 끼우면
    /// 그 값의 의미가 통째로 밀린다.
    js,
    ts,
    markup,
    style,
};

pub const RowType = enum { empty, recent_header, recent_file, root, directory, file };

pub fn classify(row_type: RowType, basename: []const u8, expanded: bool) IconKind {
    return switch (row_type) {
        .empty => .none,
        .recent_header => .recent,
        .root, .directory => classifyDirectory(basename, expanded),
        .recent_file, .file => classifyFile(basename),
    };
}

fn classifyDirectory(name: []const u8, expanded: bool) IconKind {
    if (anyName(name, &.{ "src", "source", "sources", "lib", "include" })) return .folder_source;
    if (anyName(name, &.{ "test", "tests", "spec", "specs", "fixture", "fixtures", "__tests__" })) return .folder_test;
    if (anyName(name, &.{ "doc", "docs", "documentation" })) return .folder_docs;
    if (anyName(name, &.{ "asset", "assets", "image", "images", "public", "static" })) return .folder_assets;
    if (anyName(name, &.{ "config", "configs", ".config", ".github" })) return .folder_config;
    if (anyName(name, &.{ "node_modules", "vendor", "vendors", "packages", "deps", "dependencies" })) return .folder_dependency;
    if (anyName(name, &.{ "build", "dist", "out", "output", "target", "zig-out", ".cache" })) return .folder_output;
    return if (expanded) .folder_open else .folder;
}

fn classifyFile(name: []const u8) IconKind {
    if (anyName(name, &.{ ".gitignore", ".gitattributes", ".gitmodules", ".gitkeep" })) return .git;
    if (anyName(name, &.{ "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "cargo.toml", "cargo.lock", "build.zig.zon", "composer.json", "gemfile" })) return .package;
    if (anyName(name, &.{ "dockerfile", "makefile", "justfile", "cmakelists.txt", ".editorconfig" })) return .config;
    const ext = extension(name) orelse return .file;
    if (anyName(ext, &.{ "zig", "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "swift", "rs", "go", "java", "kt", "kts", "py", "rb", "php", "lua", "sh", "bash", "zsh", "fish", "ps1", "sql" })) return .code;
    if (anyName(ext, &.{ "js", "jsx", "mjs", "cjs" })) return .js;
    if (anyName(ext, &.{ "ts", "tsx", "mts", "cts" })) return .ts;
    if (anyName(ext, &.{ "html", "htm", "vue", "svelte", "astro" })) return .markup;
    if (anyName(ext, &.{ "css", "scss", "sass", "less", "styl" })) return .style;
    if (anyName(ext, &.{ "json", "jsonc", "csv", "tsv", "xml", "graphql", "gql", "proto" })) return .data;
    if (anyName(ext, &.{ "yaml", "yml", "toml", "ini", "conf", "cfg", "properties", "env" })) return .config;
    if (anyName(ext, &.{ "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tiff", "heic" })) return .image;
    if (anyName(ext, &.{ "md", "mdx", "txt", "rst", "adoc", "pdf", "doc", "docx" })) return .document;
    if (anyName(ext, &.{ "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz" })) return .archive;
    if (anyName(ext, &.{ "lock", "jar", "war", "whl", "gem", "deb", "rpm", "dmg", "pkg" })) return .package;
    return .file;
}

fn extension(name: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (dot == 0 or dot + 1 == name.len) return null;
    return name[dot + 1 ..];
}

fn anyName(actual: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| if (std.ascii.eqlIgnoreCase(actual, candidate)) return true;
    return false;
}

/// 아이콘 셀에 줄 색. **분류와 같은 자리에 둔다** — 종류를 아는 곳이 색도 정해야 두 매핑이 갈리지 않는다
/// (렌더가 자기 표를 따로 들면 새 `IconKind` 를 더할 때 한쪽만 갱신된다).
///
/// null 이면 행 색을 그대로 쓴다: 폴더와 `none`/`recent` 가 그렇다. **폴더는 색을 주지 않는다** — 트리에서
/// 폴더는 이미 chevron·들여쓰기·굵기로 구분되고, 거기까지 칠하면 화면이 색으로 가득 차 정작 파일 종류
/// 신호가 묻힌다(사용자 요청의 요지는 "파일 종류가 먼저 읽히게"다).
pub fn colorRole(kind: IconKind) ?tokens.ColorRole {
    return switch (kind) {
        .none, .recent => null,
        .folder, .folder_open, .folder_source, .folder_test, .folder_docs, .folder_assets, .folder_config, .folder_dependency, .folder_output => null,
        .code => .file_icon_code_fg,
        .web => .file_icon_web_fg,
        .data => .file_icon_data_fg,
        .config => .file_icon_config_fg,
        .git => .file_icon_config_fg, // git 메타파일은 설정 계열로 묶는다(색을 하나 더 늘릴 만큼 자주 보이지 않는다)
        .image => .file_icon_media_fg,
        .document => .file_icon_doc_fg,
        .archive, .package => .file_icon_package_fg,
        // 웹 계열 넷은 서로 다른 색으로 갈린다(글리프는 같다) — 한 폴더에 js·ts·css 가 섞이는 것이 흔하고,
        // 그때 색이 유일한 구분 신호가 된다.
        .js => .file_icon_web_fg,
        .ts => .file_icon_ts_fg,
        .markup => .file_icon_markup_fg,
        .style => .file_icon_style_fg,
        .file => null, // 분류되지 않은 일반 파일 — 색을 주면 "종류를 안다"는 잘못된 신호가 된다
    };
}

pub fn codepoint(kind: IconKind) ?u21 {
    return switch (kind) {
        .none => null,
        .recent => icons.codepoint(.recent),
        .folder => icons.codepoint(.folder),
        .folder_open => icons.codepoint(.folder_open),
        .folder_source => icons.codepoint(.folder_source),
        .folder_test => icons.codepoint(.folder_test),
        .folder_docs => icons.codepoint(.folder_docs),
        .folder_assets => icons.codepoint(.folder_assets),
        .folder_config => icons.codepoint(.folder_config),
        .folder_dependency => icons.codepoint(.folder_dependency),
        .folder_output => icons.codepoint(.folder_output),
        .file => icons.codepoint(.file),
        .code => icons.codepoint(.file_code),
        .web => icons.codepoint(.web),
        // 세분화된 넷은 **같은 실루엣**을 쓴다(위 `IconKind` 주석) — 색이 구분을 맡는다.
        .js, .ts, .markup, .style => icons.codepoint(.web),
        .data => icons.codepoint(.data),
        .config => icons.codepoint(.file_config),
        .git => icons.codepoint(.git_branch),
        .image => icons.codepoint(.image),
        .document => icons.codepoint(.document),
        .archive => icons.codepoint(.archive),
        .package => icons.codepoint(.package),
    };
}

pub fn codepointFromRaw(raw: u8) ?u21 {
    const kind = std.enums.fromInt(IconKind, raw) orelse return codepoint(.file);
    return codepoint(kind);
}

test "file tree icon: directory semantic groups and open fallback" {
    try std.testing.expectEqual(IconKind.folder_source, classify(.directory, "SRC", false));
    try std.testing.expectEqual(IconKind.folder_test, classify(.directory, "__tests__", true));
    try std.testing.expectEqual(IconKind.folder_dependency, classify(.directory, "node_modules", false));
    try std.testing.expectEqual(IconKind.folder_open, classify(.directory, "unknown", true));
    try std.testing.expectEqual(IconKind.folder, classify(.directory, "unknown", false));
}

test "file tree icon: extension groups are ASCII-insensitive with generic fallback" {
    try std.testing.expectEqual(IconKind.code, classify(.file, "main.ZIG", false));
    try std.testing.expectEqual(IconKind.ts, classify(.file, "view.TSX", false));
    try std.testing.expectEqual(IconKind.document, classify(.file, "README.md", false));
    try std.testing.expectEqual(IconKind.image, classify(.file, "logo.SVG", false));
    try std.testing.expectEqual(IconKind.git, classify(.file, ".gitignore", false));
    try std.testing.expectEqual(IconKind.file, classify(.file, "unknown.zzz", false));
    try std.testing.expectEqual(IconKind.file, classify(.file, "LICENSE", false));
}

// 웹 계열은 **색으로 갈린다**(글리프는 공유) — 한 폴더에 js·ts·css 가 섞이는 것이 흔하고, 그때 색이
// 유일한 구분 신호다. 그래서 ⑴ 분류가 넷으로 갈리고 ⑵ 색은 서로 다르되 ⑶ 글리프는 같아야 한다.
test "file tree icon: 웹 계열은 색으로 갈리고 글리프는 공유한다" {
    try std.testing.expectEqual(IconKind.js, classify(.file, "app.js", false));
    try std.testing.expectEqual(IconKind.js, classify(.file, "bundle.MJS", false));
    try std.testing.expectEqual(IconKind.ts, classify(.file, "main.ts", false));
    try std.testing.expectEqual(IconKind.markup, classify(.file, "index.html", false));
    try std.testing.expectEqual(IconKind.markup, classify(.file, "Page.vue", false));
    try std.testing.expectEqual(IconKind.style, classify(.file, "theme.scss", false));

    // 색은 넷이 서로 다르다.
    const roles = [_]?tokens.ColorRole{ colorRole(.js), colorRole(.ts), colorRole(.markup), colorRole(.style) };
    for (roles, 0..) |a, i| {
        try std.testing.expect(a != null);
        for (roles[i + 1 ..]) |b| try std.testing.expect(a.? != b.?);
    }
    // 글리프는 같다 — 모양까지 가르려면 언어마다 SVG 가 필요하다(후속).
    const cp = codepoint(.js).?;
    try std.testing.expectEqual(cp, codepoint(.ts).?);
    try std.testing.expectEqual(cp, codepoint(.markup).?);
    try std.testing.expectEqual(cp, codepoint(.style).?);
    try std.testing.expectEqual(cp, codepoint(.web).?);
}
