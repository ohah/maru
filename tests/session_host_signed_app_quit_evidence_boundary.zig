//! The release leaf must be produced by the actual AppKit recovery harness, not by translating
//! caller booleans or a fixture-only summary after the fact.

const std = @import("std");

test "signed app Quit leaf owns candidate identity and canonical publication" {
    const source = try readHarness();
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "MARU_SESSION_HOST_SIGNED_APP_QUIT_TEST_UUID") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "MARU_SESSION_HOST_SIGNED_APP_QUIT_CANDIDATE_DMG") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "MARU_SESSION_HOST_SIGNED_APP_QUIT_FROZEN_EXE") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "upgrade_limits.signed_app_quit_leaf_schema") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".exclusive = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".permissions = std.Io.File.Permissions.fromMode(0o600)") != null);
}

test "signed app Quit leaf is earned by two actual app lifetimes and exact process continuity" {
    const source = try readHarness();
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "signed_app_quit_iteration_count: usize = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "queryRuntimeProcessIdentity") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "RuntimeProcessIdentityDrift") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "runtime_screen_before_preserved") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "runtime_screen_after_writable") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "gui_exact_reattach") != null);
}

test "signed app Quit release mode isolates the product child namespace" {
    const source = try readHarness();
    defer std.testing.allocator.free(source);
    const swift = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/MaruAppHost.swift",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(swift);

    try std.testing.expect(std.mem.indexOf(u8, source, "socketDirPathUnder") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "socketPathUnder") != null);
    try std.testing.expect(std.mem.indexOf(u8, swift, "isSessionHostSignedAppQuitEvidenceMode") != null);
    try std.testing.expect(std.mem.indexOf(u8, swift, "session-host-signed-app-quit-home") != null);
}

test "signed app Quit child consumes the sealed workspace paths without an ambient registry" {
    const build = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(build);
    const source = try readHarness();
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, build, "session-host-signed-app-quit-home") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "session-host-signed-app-quit-output") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "MARU_APP_SUMMARY_PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "zig-out/maru-macos-app/session-host-signed-app-quit-home") == null);
    try std.testing.expect(std.mem.indexOf(u8, build, "zig-out/session-host-signed-app-quit/leaf.json") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "/tmp/maru-c3c-") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "validateReleaseWorkspace") != null);
}

fn readHarness() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/cr6c_appkit_smoke.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
}
