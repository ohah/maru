//! Filesystem-free semantic icon classifier for the file explorer. The caller stores the result
//! beside the projected row; render and pointer paths only lower `IconKind` to a registered PUA.

const std = @import("std");
const icons = @import("../icons.zig");

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
    if (anyName(ext, &.{ "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte", "html", "htm", "css", "scss", "sass", "less" })) return .web;
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
    try std.testing.expectEqual(IconKind.web, classify(.file, "view.TSX", false));
    try std.testing.expectEqual(IconKind.document, classify(.file, "README.md", false));
    try std.testing.expectEqual(IconKind.image, classify(.file, "logo.SVG", false));
    try std.testing.expectEqual(IconKind.git, classify(.file, ".gitignore", false));
    try std.testing.expectEqual(IconKind.file, classify(.file, "unknown.zzz", false));
    try std.testing.expectEqual(IconKind.file, classify(.file, "LICENSE", false));
}
