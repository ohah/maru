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
        .limited(256 * 1024),
    ) catch |err| {
        std.debug.print("boundary check could not read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer allocator.free(text);

    scanImports(text, rule, path, violations);
}

// @import 경로를 훑어 금지 레이어 import를 센다. 단순 `@import("` 부분문자열이 아니라
// @import / `(` / `"` 사이의 공백·개행을 허용한다. 그렇지 않으면 trailing comma가 붙은
// 줄바꿈 형태(`@import(\n    "../pty/x.zig",\n)`)가 zig fmt를 통과하면서 경계 검사를
// 빠져나가, 금지 import가 mise run check(fmt-check + check-boundaries)와 CI를 그대로
// 통과한다.
fn scanImports(text: []const u8, rule: Rule, path: []const u8, violations: *usize) void {
    scanImportsWithDiagnostics(text, rule, path, violations, true);
}

fn scanImportsQuiet(text: []const u8, rule: Rule, path: []const u8, violations: *usize) void {
    scanImportsWithDiagnostics(text, rule, path, violations, false);
}

fn scanImportsWithDiagnostics(
    text: []const u8,
    rule: Rule,
    path: []const u8,
    violations: *usize,
    emit_diagnostics: bool,
) void {
    var index: usize = 0;
    const builtin = "@import";
    while (std.mem.indexOfPos(u8, text, index, builtin)) |found| {
        index = found + builtin.len;

        var cursor = skipWhitespace(text, found + builtin.len);
        if (cursor >= text.len or text[cursor] != '(') continue;
        cursor = skipWhitespace(text, cursor + 1);
        if (cursor >= text.len or text[cursor] != '"') continue;

        const path_start = cursor + 1;
        const end = std.mem.indexOfScalarPos(u8, text, path_start, '"') orelse break;
        const import_path = text[path_start..end];
        index = end + 1;

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
}

fn skipWhitespace(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    return i;
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
