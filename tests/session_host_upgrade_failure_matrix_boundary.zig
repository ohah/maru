const std = @import("std");
const build_source = @import("support/build_source.zig");

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// 줄 맨 앞(들여쓰기 0)의 `test "` 만 센다 — 러너가 컴파일하는 최상위 test 선언이 그것이다.
/// 문자열·주석 안에 적힌 `test "` 는 줄 맨 앞에 오지 않으므로 세지 않는다.
fn countTopLevelTests(source: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "test \"")) n += 1;
    }
    return n;
}

test "U5 first failure matrix keeps every process and product rollback leaf" {
    const process = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/exec_upgrade_e2e.zig",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(process);
    const build = try build_source.read(std.testing.allocator);
    defer std.testing.allocator.free(build);

    const required_process_cases = [_][]const u8{
        "U3 distinct old-source fixture execs new image with same host/child/runtime and exact-once exit",
        "U3 old exec syscall failure closes inherited slots and resumes original owner",
        "U3 controlled target pre-commit failure execs staged old rollback image without losing PTY",
        "U3 corrupt primary is rejected by old readback before exec and original owner resumes",
        "U3 corrupt backup is rejected by old readback before exec and original owner resumes",
        "U3 valid but divergent backup is rejected before exec and original owner resumes",
        "U3 incompatible target preflight exits before exec and original owner resumes",
        "U3 hung target preflight is killed and reaped at deadline before original owner resumes",
        "U3 target adoption failpoint is caught by common rollback handler without touching child",
        "U3 target path replacement after old validation is rejected by recorded identity",
        "U3 consecutive N-1 to N success and N to N+1 failure rolls back to N with live PTY",
        "U3 second target preflight failure resumes committed N owner without host exit",
        "U3 second exec syscall failure closes slots and resumes committed N owner",
        "U3 rollback self-image promotion failure keeps runtime committed and withdraws upgrade capability",
    };
    // 이름이 파일 «어딘가» 에 있는 것이 아니라 **test 선언** 으로 있어야 한다.
    for (required_process_cases) |name| {
        const declaration = try std.fmt.allocPrint(std.testing.allocator, "test \"{s}\"", .{name});
        defer std.testing.allocator.free(declaration);
        try std.testing.expect(contains(process, declaration));
    }
    // 그리고 파일의 test 선언 수가 목록 길이와 **같다** — 목록에 없는 test 가 몰래 늘거나 줄지 않는다.
    // 이 둘이 합쳐지면 «목록 = 파일의 test 전부» 다(이름은 서로 다르다).
    try std.testing.expectEqual(required_process_cases.len, countTopLevelTests(process));

    try std.testing.expect(contains(build, "test-session-host-upgrade-failure-matrix"));
    try std.testing.expect(contains(build, "session_host_upgrade_failure_process_tests"));
    // **숫자를 글자로 못 박지 않고 목록에서 계산한다.** 호출자와 인자를 함께 적는 것은 그대로다
    // (2026-09-02 에 `build.zig` 전체에서 `=14` 를 찾던 단언이 **무관한 아티팩트**의 14 로 통과하던
    // 것을 막으려고 넣었다).
    //
    // 그런데 그때 이 아티팩트의 수를 **15** 로 적었다. 이 파일은 07-24 부터 지금까지 test 가 줄곧
    // **14** 개이고, 바로 위 목록도 14 개다. 이 판정자는 `check-boundaries`(CI)에서 빌드 소스의
    // «글자» 만 봤고, 실제 수를 세는 `test-session-host-upgrade-failure-matrix` 는 CI 밖이라
    // `expected 15, compiled 14` 로 3 주 가까이 빨간 채 아무도 못 봤다(2026-09-23 발견).
    // 목록 길이에서 만들면 목록·파일·빌드 기대값 셋이 다시 어긋날 수 없다.
    const expected_arg = std.fmt.comptimePrint(
        "run_session_host_upgrade_failure_process_tests.addArg(\"--maru-expect-tests={d}\")",
        .{required_process_cases.len},
    );
    try std.testing.expect(contains(build, expected_arg));
    try std.testing.expect(contains(build, "failure_matrix_step.dependOn(&run_session_host_product_rollback_tests.step)"));
    try std.testing.expect(contains(build, "failure_matrix_step.dependOn(&run_session_host_nonempty_rollback_tests.step)"));
}
