//! Release evidence must execute the preserved signed candidate, not a fresh developer bundle.

const std = @import("std");

test "baseline gates share one signed candidate app and have no developer fallback" {
    const build = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(build);

    const start = std.mem.indexOf(u8, build, "const signed_candidate_app = b.option(") orelse
        return error.MissingSignedCandidateAppOption;
    const end = std.mem.indexOfPos(u8, build, start, "const session_host_cr6d_appkit_step =") orelse
        return error.MissingBaselineGateBoundary;
    const baseline = build[start..end];

    try expectContains(baseline, "session-host-signed-candidate-app");
    try expectContains(baseline, "\"{s}/Contents/MacOS/maru-macos-app\",\n            .{signed_candidate_app}");
    try expectContains(baseline, "\"{s}/Contents/MacOS/maru\",\n            .{signed_candidate_app}");
    try expectContains(baseline, "\"MARU_SESSION_HOST_CR6C_APP_EXE\",\n            signed_candidate_app_exe,");
    try expectContains(baseline, "\"MARU_SESSION_HOST_CR6C_PRODUCT_EXE\",\n            signed_candidate_product_exe,");
    try std.testing.expectEqual(@as(usize, 1), count(baseline, "\"session-host-signed-candidate-app\""));
    try std.testing.expectEqual(@as(usize, 3), count(baseline, "signed_candidate_app_exe"));
    try std.testing.expectEqual(@as(usize, 2), count(baseline, "signed_candidate_product_exe"));
    try std.testing.expectEqual(@as(usize, 2), count(baseline, "MARU_SESSION_HOST_CR6C_APP_EXE"));
    try std.testing.expectEqual(@as(usize, 1), count(baseline, "MARU_SESSION_HOST_CR6C_PRODUCT_EXE"));
    try std.testing.expect(std.mem.indexOf(u8, baseline, "zig-out/Maru.app") == null);
    try std.testing.expect(std.mem.indexOf(u8, baseline, "dependOn(&macos_app_bundle.step)") == null);
    try std.testing.expect(std.mem.indexOf(u8, baseline, "MARU_WEB_APP_ROOT") == null);
    try std.testing.expect(std.mem.indexOf(u8, baseline, "file_panel_web_build") == null);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |found| {
        total += 1;
        offset = found + needle.len;
    }
    return total;
}
