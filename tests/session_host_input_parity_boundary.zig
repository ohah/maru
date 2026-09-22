//! P4 input parity micro-gate source and focused-build boundary.

const std = @import("std");
const build_source = @import("support/build_source.zig");
/// 빌드 등록을 **문자열이 아니라 구조로** 본다. 모듈 배선이 필요 없다 — 이 파일은 모듈 루트가
/// 아니라 상대 경로로 `tests/support/` 를 볼 수 있다(`tests/boundary/` 아래는 그게 안 된다).
const build_graph = @import("support/build_graph.zig");

test "P4 input parity 경계는 AppSession 관측에서 actual host reader PTY까지 한 gate로 묶는다" {
    const allocator = std.testing.allocator;
    const app = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const manager = try readSource(allocator, "src/platform/macos/session_host/runtime_manager.zig");
    defer allocator.free(manager);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const build = try build_source.read(allocator);
    defer allocator.free(build);
    const persistent = try readSource(allocator, "docs/persistent-session-host.md");
    defer allocator.free(persistent);
    const plan = try readSource(allocator, "docs/implementation-plan.md");
    defer allocator.free(plan);
    const verification = try readSource(allocator, "docs/verification-matrix.md");
    defer allocator.free(verification);
    const commands = try readSource(allocator, "docs/development-commands.md");
    defer allocator.free(commands);

    try std.testing.expectEqual(@as(usize, 1), count(app, "test \"host-backed motion 리포팅:"));
    try std.testing.expectEqual(@as(usize, 1), count(app, "if (tracking != .any)"));
    try std.testing.expectEqual(@as(usize, 1), count(app, ".button = 3"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "test \"P4 input parity: host reader writes DECSET 1003 motion to the real PTY\""));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "test \"runtime manager: host selection scroll-and-extend is fenced before authoritative copy\""));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "return self.backend_impl.backend().enqueueCoreCommand(handle, .{ .report_mouse"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, ".scroll_and_extend => |step|"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "if (!rr.supportsSelectionState()) return;"));

    var graph = try build_graph.parse(allocator);
    defer graph.deinit();
    // 스텝 선언을 **구조로** 센다 — 문자열은 설명문·인자에 적힌 같은 이름도 세고,
    // 더 긴 이름의 앞부분에도 걸린다.
    try std.testing.expectEqual(@as(usize, 1), graph.countSteps("test-session-host-input-parity"));
    // 매달기도 **구조로** 본다 — 문자열은 `.step` 이 붙었는지·줄바꿈이 들었는지에 흔들린다.
    try std.testing.expect(graph.dependsOn("session_host_input_parity_step", "session_host_e2c_step"));
    try std.testing.expect(std.mem.indexOf(u8, persistent, "고빈도 1003 hover와 selection autoscroll은") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "P4 parity micro-gate (완료)") != null);
    try std.testing.expect(std.mem.indexOf(u8, verification, "P4 input parity micro-gate: 구현.") != null);
    try std.testing.expectEqual(@as(usize, 1), count(commands, "`zig build test-session-host-input-parity`"));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        result += 1;
        start = index + needle.len;
    }
    return result;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(8 * 1024 * 1024),
    );
}
