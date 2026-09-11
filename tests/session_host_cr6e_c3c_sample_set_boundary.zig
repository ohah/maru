const std = @import("std");

test "CR6e-c3c sample-set keeps twenty sequential isolated product runs and one strict aggregate" {
    const allocator = std.testing.allocator;
    const build = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "build.zig", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(build);
    const collector = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/cr6e_c3c_sample_set.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(collector);
    const fingerprint = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/cr6e_c3c_sample_set_fingerprint.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(fingerprint);
    const validator = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tools/perf/session_host_cr6e_c3c_sample_set_validator.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(validator);
    const sample_start = std.mem.indexOf(u8, build, "const c3c_sample_set_step") orelse
        return error.MissingSampleSetBuildBlock;
    const sample_end_relative = std.mem.indexOf(
        u8,
        build[sample_start..],
        "const app_launch_first_drawable_step",
    ) orelse return error.MissingSampleSetBuildBlockEnd;
    const sample_build = build[sample_start .. sample_start + sample_end_relative];

    for ([_][]const u8{
        "for (0..20) |sample_index|",
        "prepare_sample.step.dependOn(c3c_sample_previous)",
        "run_sample.step.dependOn(&prepare_sample.step)",
        "isolateMacosProductTest(",
        "cr6e-c3c-sample-{d}",
        "MARU_NO_WORKSPACE_RESTORE",
        "zig-out/maru-macos-app/session-host-cr6e-c3c-home",
        "macos-session-host-cr6e-c3c-sample-set",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, sample_build, needle) != null);
    for ([_][]const u8{
        "sample_count: usize = 20",
        "maru.session-host-cr6e-c3c-sample-set.v1",
        "try c3c.validateArtifact(row.raw)",
        "row.latency_ns != row.raw.input_frame.latency_ns",
        "sample_set_p95_cap_ns",
        "sample_set_hang_cap_ns",
        "SampleSetP95BudgetExceeded",
        "SampleHangBudgetExceeded",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, validator, needle) != null);
    for ([_][]const u8{
        "measurement_fingerprint.sha256File(app_path.ptr)",
        "measurement_fingerprint.sha256File(product_path.ptr)",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, fingerprint, needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, collector, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, collector, "EnvironmentChanged") != null);
    try std.testing.expect(std.mem.indexOf(u8, sample_build, "MARU_SESSION_HOST_ROOT") == null);
}
