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
// 지금은 src 트리가 작고 알려져 있어 파일 목록을 직접 적는다.
// 후속 작업: 디렉터리 워킹으로 바꿔 새 파일을 자동으로 포함한다.

const Forbidden = struct {
    layer: []const u8,
    // true이면 구현 디렉터리("layer/...")만 금지하고 공개 barrel("layer.zig")은 허용한다.
    private_only: bool = false,
};

const Rule = struct {
    layer: []const u8,
    files: []const []const u8,
    forbidden: []const Forbidden,
};

const rules = [_]Rule{
    .{
        .layer = "terminal",
        .files = &.{
            "src/terminal.zig",
            "src/terminal/core.zig",
            "src/terminal/input.zig",
            "src/terminal/types.zig",
        },
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "renderer" },
        },
    },
    .{
        .layer = "renderer",
        .files = &.{ "src/renderer.zig", "src/renderer/types.zig" },
        .forbidden = &.{.{ .layer = "pty" }},
    },
    .{
        .layer = "plugin",
        .files = &.{ "src/plugin.zig", "src/plugin/registry.zig" },
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "terminal", .private_only = true },
        },
    },
    .{
        .layer = "pty",
        .files = &.{ "src/pty.zig", "src/pty/types.zig" },
        .forbidden = &.{.{ .layer = "terminal", .private_only = true }},
    },
};

test "facade layers do not import forbidden layers" {
    const allocator = std.testing.allocator;
    var violations: usize = 0;

    for (rules) |rule| {
        for (rule.files) |path| {
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

            var index: usize = 0;
            const marker = "@import(\"";
            while (std.mem.indexOfPos(u8, text, index, marker)) |start| {
                const path_start = start + marker.len;
                const end = std.mem.indexOfScalarPos(u8, text, path_start, '"') orelse break;
                const import_path = text[path_start..end];
                index = end + 1;

                for (rule.forbidden) |forbidden| {
                    if (importTraversesLayer(import_path, forbidden)) {
                        std.debug.print(
                            "boundary violation: {s} ({s} layer) imports forbidden layer '{s}' via \"{s}\"\n",
                            .{ path, rule.layer, forbidden.layer, import_path },
                        );
                        violations += 1;
                    }
                }
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 0), violations);
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
