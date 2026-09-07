//! The signed harness consumes one caller-owned absent root and never removes an old artifact.

const std = @import("std");

test "signed upgrade harness requires an explicit isolated root and exclusive output" {
    const source = @embedFile("session_host_signed_upgrade_e2e.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "isolated_root: []u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const isolated_root_raw = args.next()") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "try requireAbsentArtifact(artifact_path)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "invalidateArtifact") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "\"/tmp/{s}\"") == null);
}

test "both opt-in gates pass distinct fixed roots as the sixth harness argument" {
    const build = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "build.zig", std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(build);
    try std.testing.expect(std.mem.indexOf(u8, build, "session-host-signed-upgrade-root") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "zig-out/session-host-signed-upgrade/run-root") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "zig-out/session-host-signed-upgrade-near-max/run-root") != null);
}
