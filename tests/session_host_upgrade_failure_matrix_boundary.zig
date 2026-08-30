const std = @import("std");

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "U5 first failure matrix keeps every process and product rollback leaf" {
    const process = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/exec_upgrade_e2e.zig",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(process);
    const build = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
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
    for (required_process_cases) |name| try std.testing.expect(contains(process, name));

    try std.testing.expect(contains(build, "test-session-host-upgrade-failure-matrix"));
    try std.testing.expect(contains(build, "session_host_upgrade_failure_process_tests"));
    try std.testing.expect(contains(build, "--maru-expect-tests=14"));
    try std.testing.expect(contains(build, "failure_matrix_step.dependOn(&run_session_host_product_rollback_tests.step)"));
    try std.testing.expect(contains(build, "failure_matrix_step.dependOn(&run_session_host_nonempty_rollback_tests.step)"));
}
