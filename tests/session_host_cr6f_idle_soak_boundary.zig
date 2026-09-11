const std = @import("std");

test "CR6f idle soak is continuous actual-host evidence isolated from user session state" {
    const allocator = std.testing.allocator;
    const runner = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/session_host_slow_observer_e2e.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(runner);
    const validator = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tools/perf/session_host_cr6f_idle_soak_validator.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(validator);
    const build = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "build.zig", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(build);

    for ([_][]const u8{
        "const idle_soak_window_ms: u64 = 10_000;",
        "const idle_soak_window_count: usize = 60;",
        "exec /bin/cat",
        "/tmp/maru-slow-observer-",
        "c.mkdir(session_dir.ptr, 0o700)",
        ".session_root_kind = \"fixture_nonce_0700\"",
        ".windows = idle_soak_windows[0..idle_soak_windows_written]",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, runner, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, runner, "MARU_SESSION_HOST_ROOT") == null);
    try std.testing.expect(std.mem.indexOf(u8, runner, "getenv(") == null);
    for ([_][]const u8{
        "idle_soak_window_ns: u64 = 10 * std.time.ns_per_s",
        "idle_soak_window_count: usize = 60",
        "return error.IdentityChanged",
        "return error.IdleWorkObserved",
        "return error.CpuBudgetExceeded",
        "return error.ResourceDrift",
        "return error.MissingFinalWake",
        "return error.IncompleteCleanup",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, validator, needle) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        build,
        "test-session-host-cr6f-idle-soak-macos",
    ) != null);
}
