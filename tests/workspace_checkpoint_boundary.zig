//! P4 C1의 layering과 effect ownership을 소스 경계로 고정한다.

const std = @import("std");
const build_source = @import("support/build_source.zig");
/// 빌드 등록을 **문자열이 아니라 구조로** 본다. 모듈 배선이 필요 없다 — 이 파일은 모듈 루트가
/// 아니라 상대 경로로 `tests/support/` 를 볼 수 있다(`tests/boundary/` 아래는 그게 안 된다).
const build_graph = @import("support/build_graph.zig");

test "P4 C1 경계는 pure coordinator와 caller-owned side effects를 고정한다" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/session/workspace_checkpoint.zig",
        allocator,
        .limited(128 * 1024),
    );
    defer allocator.free(source);
    const facade = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/session.zig",
        allocator,
        .limited(256 * 1024),
    );
    defer allocator.free(facade);
    const build = try build_source.read(allocator);
    defer allocator.free(build);

    for ([_][]const u8{
        "std.posix",
        "std.fs",
        "std.Io",
        "std.time",
        "@import(\"../app",
        "@import(\"../platform",
        "@import(\"../pty",
    }) |forbidden| {
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, forbidden));
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, facade, "pub const workspace_checkpoint = @import(\"session/workspace_checkpoint.zig\");"));
    var graph = try build_graph.parse(allocator);
    defer graph.deinit();
    // 스텝 선언을 **구조로** 센다 — 문자열은 설명문·인자에 적힌 같은 이름도 세고,
    // 더 긴 이름의 앞부분에도 걸린다.
    try std.testing.expectEqual(@as(usize, 1), graph.countSteps("test-workspace-checkpoint-coordinator"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "replyApplicationShouldTerminate"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, ".detach("));
}
