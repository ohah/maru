const std = @import("std");

// 이 테스트는 docs/implementation-plan.md의 facade import 경계를 강제한다.
// Maru 아키텍처 전체는 TerminalCore가 PTY/platform/renderer를 모른다는 전제 위에
// 서 있다(clean-room VT 코어를 교체 가능하고 headless로 테스트 가능하게 유지하기
// 위해서다). "리뷰에서 조심한다"는 규칙만으로는 이를 보장할 수 없으므로, 한 레이어가
// 금지된 레이어를 import하는 순간 빌드를 실패시킨다.
//
// 금지에는 두 종류가 있다(implementation-plan.md "1단계 boundary checker 최소 요구사항"의 초기 금지 규칙).
//   - 레이어 전체 금지: 공개 barrel("layer.zig")과 구현 디렉터리("layer/...") 모두 금지.
//     예) terminal -> pty/platform/renderer, renderer -> pty, plugin -> pty.
//   - private 구현만 금지: 구현 디렉터리("layer/...")만 금지하고 공개 barrel은 허용.
//     예) pty/plugin -> terminal. pty는 terminal.Size 같은 공개 타입은 써도 되지만
//     terminal/core.zig 같은 내부 구현은 만지면 안 된다.
//
// 새 파일이 추가될 때마다 이 테스트 파일을 고치는 방식은 쉽게 빠뜨린다.
// 그래서 facade barrel 파일은 명시하되, 구현 폴더는 재귀적으로 훑어 새
// `*.zig` 파일도 자동으로 경계 검사를 받게 한다.

const Forbidden = struct {
    layer: []const u8,
    // true이면 구현 디렉터리("layer/...")만 금지하고 공개 barrel("layer.zig")은 허용한다.
    private_only: bool = false,
};

const Rule = struct {
    layer: []const u8,
    barrel: []const u8,
    implementation_dir: []const u8,
    forbidden: []const Forbidden,
};

const rules = [_]Rule{
    .{
        .layer = "terminal",
        .barrel = "src/terminal.zig",
        .implementation_dir = "src/terminal",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "renderer" },
        },
    },
    .{
        .layer = "renderer",
        .barrel = "src/renderer.zig",
        .implementation_dir = "src/renderer",
        .forbidden = &.{.{ .layer = "pty" }},
    },
    .{
        .layer = "plugin",
        .barrel = "src/plugin.zig",
        .implementation_dir = "src/plugin",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "terminal", .private_only = true },
        },
    },
    .{
        .layer = "pty",
        .barrel = "src/pty.zig",
        .implementation_dir = "src/pty",
        .forbidden = &.{.{ .layer = "terminal", .private_only = true }},
    },
};

test "facade layers do not import forbidden layers" {
    const allocator = std.testing.allocator;
    var violations: usize = 0;

    for (rules) |rule| {
        try checkFile(allocator, rule, rule.barrel, &violations);
        try checkDirectory(allocator, rule, rule.implementation_dir, &violations);
    }

    try std.testing.expectEqual(@as(usize, 0), violations);
}

fn checkDirectory(
    allocator: std.mem.Allocator,
    rule: Rule,
    dir_path: []const u8,
    violations: *usize,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path });
        defer allocator.free(path);

        try checkFile(allocator, rule, path, violations);
    }
}

fn checkFile(
    allocator: std.mem.Allocator,
    rule: Rule,
    path: []const u8,
    violations: *usize,
) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        // 소스 한 파일당 읽기 상한. import 스캔용이라 넉넉히 둔다 — core.zig가 256KB를 넘어서며
        // (정상적 코드 성장) StreamTooLong이 났다. 1MB면 당분간 모든 파일을 커버한다.
        .limited(1024 * 1024),
    ) catch |err| {
        std.debug.print("boundary check could not read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer allocator.free(text);

    // std.zig.Tokenizer는 sentinel 종료 버퍼([:0]u8)를 요구한다.
    const text_z = try allocator.dupeZ(u8, text);
    defer allocator.free(text_z);

    scanImports(text_z, rule, path, violations);
}

// @import 경로를 훑어 금지 레이어 import를 센다. 단순 부분문자열 스캔이 아니라
// std.zig.Tokenizer로 토큰화해 실제 `@import` `(` string_literal 시퀀스만 import로 본다.
// 그래야 (1) `@import`와 `(` 사이에 주석·개행·공백이 있어도 잡고(부분문자열 스캐너는
// `@import // 주석\n(...)`을 놓쳤다), (2) 주석이나 문자열 리터럴 안에 적힌
// `@import("../x")`를 오탐하지 않는다. 토크나이저는 일반 주석을 토큰으로 내보내지 않고,
// doc 주석·일반/multiline 문자열은 builtin이 아닌 단일 토큰으로 내보내므로 둘 다 자연히 처리된다.
fn scanImports(text: [:0]const u8, rule: Rule, path: []const u8, violations: *usize) void {
    scanImportsWithDiagnostics(text, rule, path, violations, true);
}

fn scanImportsQuiet(text: [:0]const u8, rule: Rule, path: []const u8, violations: *usize) void {
    scanImportsWithDiagnostics(text, rule, path, violations, false);
}

fn scanImportsWithDiagnostics(
    text: [:0]const u8,
    rule: Rule,
    path: []const u8,
    violations: *usize,
    emit_diagnostics: bool,
) void {
    var tokenizer = std.zig.Tokenizer.init(text);
    // `@import` / `(` / string_literal 가 연속으로 나올 때만 실제 import로 본다.
    var saw_import = false;
    var saw_paren = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .builtin => {
                saw_import = std.mem.eql(u8, text[token.loc.start..token.loc.end], "@import");
                saw_paren = false;
            },
            .l_paren => {
                saw_paren = saw_import;
                saw_import = false;
            },
            .string_literal => {
                if (saw_paren) {
                    // string_literal 토큰은 따옴표를 포함한다("..."). import 경로는
                    // 이스케이프 없는 단순 경로라 양끝 따옴표만 벗긴다.
                    const raw = text[token.loc.start..token.loc.end];
                    const import_path = raw[1 .. raw.len - 1];
                    for (rule.forbidden) |forbidden| {
                        if (importTraversesLayer(import_path, forbidden)) {
                            // 실제 파일을 검사할 때만 진단을 출력한다. 아래 unit test는 일부러
                            // 금지 import fixture를 넣기 때문에, 거기서 같은 메시지를 찍으면
                            // `mise run check`가 성공해도 실패처럼 보여 triage를 방해한다.
                            if (emit_diagnostics) {
                                std.debug.print(
                                    "boundary violation: {s} ({s} layer) imports forbidden layer '{s}' via \"{s}\"\n",
                                    .{ path, rule.layer, forbidden.layer, import_path },
                                );
                            }
                            violations.* += 1;
                        }
                    }
                }
                saw_import = false;
                saw_paren = false;
            },
            else => {
                saw_import = false;
                saw_paren = false;
            },
        }
    }
}

fn importTraversesLayer(import_path: []const u8, forbidden: Forbidden) bool {
    // import 경로는 "../pty/types.zig"나 "core.zig" 같은 상대 경로다.
    var it = std.mem.splitScalar(u8, import_path, '/');
    while (it.next()) |seg| {
        // 구현 디렉터리로 진입: segment가 정확히 레이어 이름("pty", "terminal" ...).
        if (std.mem.eql(u8, seg, forbidden.layer)) return true;
        // 공개 barrel("layer.zig"): 레이어 전체 금지일 때만 위반으로 본다.
        if (!forbidden.private_only and
            std.mem.endsWith(u8, seg, ".zig") and
            std.mem.eql(u8, seg[0 .. seg.len - 4], forbidden.layer)) return true;
    }
    return false;
}

test "importTraversesLayer distinguishes barrel from private implementation" {
    // 레이어 전체 금지: barrel과 구현 디렉터리 둘 다 잡는다.
    try std.testing.expect(importTraversesLayer("../pty/types.zig", .{ .layer = "pty" }));
    try std.testing.expect(importTraversesLayer("../pty.zig", .{ .layer = "pty" }));
    // private 구현만 금지: 구현 디렉터리는 잡고 공개 barrel은 허용한다.
    try std.testing.expect(importTraversesLayer("../terminal/core.zig", .{ .layer = "terminal", .private_only = true }));
    try std.testing.expect(!importTraversesLayer("../terminal.zig", .{ .layer = "terminal", .private_only = true }));
    // 무관한 import는 잡지 않는다.
    try std.testing.expect(!importTraversesLayer("core.zig", .{ .layer = "pty" }));
    try std.testing.expect(!importTraversesLayer("std", .{ .layer = "renderer" }));
}

test "scanImports catches zig fmt-clean whitespace and multi-line @import forms" {
    const rule = Rule{
        .layer = "terminal",
        .barrel = "src/terminal.zig",
        .implementation_dir = "src/terminal",
        .forbidden = &.{.{ .layer = "pty" }},
    };

    // 단일행: 기존에도 잡혔다.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import(\"../pty/types.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // trailing comma 줄바꿈 형태: zig fmt --check를 통과하면서 예전 `@import("` 마커를 빠져나갔다.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import(\n    \"../pty/types.zig\",\n);", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // @import 와 `(` 사이 공백.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import (\"../pty/types.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 허용되는 import(std, 공개 barrel)는 잡지 않는다.
    {
        var v: usize = 0;
        scanImportsQuiet("const s = @import(\"std\");\nconst t = @import(\"../terminal.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}

test "scanImports tokenizes, so comments and string literals neither evade nor false-positive" {
    const rule = Rule{
        .layer = "terminal",
        .barrel = "src/terminal.zig",
        .implementation_dir = "src/terminal",
        .forbidden = &.{.{ .layer = "pty" }},
    };

    // `@import`와 `(` 사이 줄 주석: zig fmt-clean이고 유효한 Zig지만 부분문자열 스캐너는
    // 놓쳤다. 토크나이저는 주석을 건너뛰므로 실제 import로 잡아야 한다.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import // sneaky\n    (\"../pty/types.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 줄 주석 안의 금지 경로 언급: 실제 import가 아니므로 오탐하면 안 된다.
    {
        var v: usize = 0;
        scanImportsQuiet("// historically used @import(\"../pty/types.zig\")\nconst a = @import(\"std\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // doc 주석 안의 금지 경로 언급: 오탐하면 안 된다.
    {
        var v: usize = 0;
        scanImportsQuiet("/// see @import(\"../pty/types.zig\")\npub const a = @import(\"std\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // multiline 문자열 안의 금지 경로 언급: 오탐하면 안 된다.
    {
        var v: usize = 0;
        scanImportsQuiet("const s =\n    \\\\@import(\"../pty/types.zig\")\n;", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}
