const std = @import("std");
const build_source = @import("support/build_source.zig");
/// 빌드 등록을 **문자열이 아니라 구조로** 본다. 모듈 배선이 필요 없다 — 이 파일은 모듈 루트가
/// 아니라 상대 경로로 `tests/support/` 를 볼 수 있다(`tests/boundary/` 아래는 그게 안 된다).
const build_graph = @import("support/build_graph.zig");

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

fn enumBody(source: []const u8) ![]const u8 {
    const start_marker = "pub const PostcommitFault = enum {";
    const start = std.mem.indexOf(u8, source, start_marker) orelse
        return error.TestUnexpectedResult;
    const body_start = start + start_marker.len;
    const end = std.mem.indexOfPos(u8, source, body_start, "\n};") orelse
        return error.TestUnexpectedResult;
    return source[body_start..end];
}

test "U5 restore postcommit fault vocabulary is closed and absent from the product entrypoint" {
    const activation = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/restore_activation.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(activation);
    const main = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(main);
    const e2e = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/session_host_nonempty_rollback_e2e.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(e2e);
    const runner = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tools/session_host_restore_postcommit_test_runner.zig",
        std.testing.allocator,
        .limited(16 * 1024),
    );
    defer std.testing.allocator.free(runner);
    const build = try build_source.read(std.testing.allocator);
    defer std.testing.allocator.free(build);

    try std.testing.expectEqual(
        @as(usize, 1),
        count(activation, "pub const PostcommitFault = enum {"),
    );
    var fields = std.mem.splitScalar(u8, try enumBody(activation), '\n');
    var fault_count: usize = 0;
    while (fields.next()) |line| {
        const name = std.mem.trim(u8, line, " \t,");
        if (name.len == 0 or std.mem.eql(u8, name, "none")) continue;
        try std.testing.expect(std.ascii.isAlphabetic(name[0]));
        for (name) |byte|
            try std.testing.expect(std.ascii.isAlphanumeric(byte) or byte == '_');
        try std.testing.expect(count(main, name) == 0);
        fault_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), fault_count);
    try std.testing.expect(count(activation, "runWithPostcommitFaultForTest") == 1);
    try std.testing.expect(count(activation, "if (!fault.consumed) return error.PostcommitFaultNotConsumed") == 2);
    try std.testing.expect(count(e2e, "std.enums.values(sh.restore_activation.PostcommitFault)") == 1);
    try std.testing.expect(count(e2e, "if (fault == .none or fault == .rollback_promotion) continue;") == 1);
    try std.testing.expect(count(e2e, "runRestoreFaultCase(null, .rollback_promotion, 3, .postcommit_status_only)") == 1);
    try std.testing.expect(count(e2e, "expectPostcommitVocabularyAbsentFromProduct") == 2);
    try std.testing.expect(count(e2e, "const rollback_source = if (postcommit_fault != null) self else product;") == 1);
    try std.testing.expect(count(e2e, "restore postcommit fail-stop rows never execute rollback") == 1);
    try std.testing.expect(count(e2e, "restore postcommit promotion failure keeps the real PTY status-only") == 1);
    try std.testing.expect(count(runner, "--restore-activation-postcommit-fault") == 1);
    try std.testing.expect(count(runner, "std.mem.eql(u8, first, \"__session-host\")") == 1);
    try std.testing.expect(count(runner, "std.process.exit(94)") == 1);
    var graph = try build_graph.parse(std.testing.allocator);
    defer graph.deinit();
    // 스텝 선언을 **구조로** 센다 — 문자열은 설명문·인자에 적힌 같은 이름도 센다.
    try std.testing.expectEqual(@as(usize, 1), graph.countSteps("test-session-host-upgrade-restore-postcommit-failure-matrix"));
    try std.testing.expect(count(build, "run_session_host_restore_postcommit_tests.addArg(\"--maru-expect-tests=2\")") == 1);
    // 매달기도 **구조로** 본다 — 문자열은 `.step` 이 붙었는지·줄바꿈이 들었는지에 흔들린다.
    try std.testing.expect(graph.dependsOn("session_host_restore_postcommit_step", "run_session_host_restore_postcommit_tests"));
}
