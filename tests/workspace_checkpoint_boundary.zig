//! P4 C1의 layering과 effect ownership을 소스 경계로 고정한다.

const std = @import("std");

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
    const build = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
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
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, build, "test-workspace-checkpoint-coordinator"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "replyApplicationShouldTerminate"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, ".detach("));
}
