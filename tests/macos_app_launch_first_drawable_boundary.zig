const std = @import("std");

test "L1 launch gate preserves product startup and isolates every ambient profile" {
    const allocator = std.testing.allocator;
    const swift = try read(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(swift);
    const harness = try read(allocator, "src/platform/macos/app_launch_first_drawable.zig");
    defer allocator.free(harness);
    const build = try read(allocator, "build.zig");
    defer allocator.free(build);
    const validator = try read(allocator, "tools/perf/macos_app_launch_first_drawable_validator.zig");
    defer allocator.free(validator);

    const launch_gate = between(
        build,
        "const app_launch_first_drawable_step = b.step(",
        "\n        const macos_app_smoke_step = b.step(",
    ) orelse return error.MissingLaunchGate;
    try std.testing.expect(std.mem.indexOf(u8, launch_gate, "-Doptimize") == null);
    try std.testing.expectEqual(@as(usize, 2), count(launch_gate, "tools/perf/macos_app_launch_first_drawable_validator.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(launch_gate, "--maru-expect-tests=2"));
    try std.testing.expectEqual(@as(usize, 0), count(launch_gate, "MARU_MACOS_APP_SMOKE_MS"));

    const draw = between(swift, "private func drawMetalFrame() {", "\n    // view가 drawableSize") orelse
        return error.MissingDrawOwner;
    const successful = std.mem.indexOf(u8, draw, "if drew {") orelse return error.MissingDrawOwner;
    const frame = std.mem.indexOfPos(u8, draw, successful, "metalFramesDrawn += 1") orelse return error.MissingDrawOwner;
    const submit = std.mem.indexOfPos(u8, draw, frame, "appLaunchFirstDrawableSubmitNs = submit") orelse
        return error.MissingDrawOwner;
    const terminate = std.mem.indexOfPos(u8, draw, submit, "DispatchQueue.main.async { NSApp.terminate(nil) }") orelse
        return error.MissingDrawOwner;
    try std.testing.expect(successful < frame and frame < submit and submit < terminate);
    try std.testing.expectEqual(@as(usize, 1), count(swift, "if smokeMode || appLaunchFirstDrawableArmed { return .terminateNow }"));

    inline for (.{
        "envPair(allocator, \"HOME\"",                   "envPair(allocator, \"CFFIXED_USER_HOME\"",
        "envPair(allocator, \"XDG_CACHE_HOME\"",         "envPair(allocator, \"XDG_CONFIG_HOME\"",
        "envPair(allocator, \"CODEX_HOME\"",             "envPair(allocator, \"CLAUDE_CONFIG_DIR\"",
        "envPair(allocator, \"TMPDIR\"",                 "envPair(allocator, \"MARU_CONFIG\"",
        "envPair(allocator, \"MARU_SESSION_HOST_ROOT\"", "envPair(allocator, \"MARU_APP_SUMMARY_PATH\"",
    }) |setting| try std.testing.expectEqual(@as(usize, 1), count(harness, setting));
    try std.testing.expectEqual(@as(usize, 1), count(harness, "envPair(allocator, \"PATH\", \"/usr/bin:/bin:/usr/sbin:/sbin\")"));
    try std.testing.expectEqual(@as(usize, 1), count(harness, "execve(app_path.ptr, &argv, &child_env)"));
    try std.testing.expectEqual(@as(usize, 0), count(harness, "std.c.environ"));
    try std.testing.expectEqual(@as(usize, 0), count(harness, "MARU_MACOS_APP_SMOKE_MS"));
    try std.testing.expectEqual(@as(usize, 0), count(harness, "MARU_NO_WORKSPACE_RESTORE"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, ".ignore_unknown_fields = false"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, ".duplicate_field_behavior = .@\"error\""));
}

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(2 * 1024 * 1024));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        total += 1;
        offset = index + needle.len;
    }
    return total;
}

fn between(haystack: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const begin = std.mem.indexOf(u8, haystack, start) orelse return null;
    const finish = std.mem.indexOfPos(u8, haystack, begin + start.len, end) orelse return null;
    return haystack[begin..finish];
}
