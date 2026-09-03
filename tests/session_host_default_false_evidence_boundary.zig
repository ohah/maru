//! The baseline leaf must come from the signed product's post-bootstrap typed snapshot, never from
//! caller-provided result booleans or the developer's real config/session-host namespace.

const std = @import("std");

test "default false leaf observes the closed post-bootstrap ABI state" {
    const harness = try read("src/platform/macos/session_host/cr6c_appkit_smoke.zig", 1024 * 1024);
    defer std.testing.allocator.free(harness);
    const header = try read("src/platform/macos/app_host_abi.h", 256 * 1024);
    defer std.testing.allocator.free(header);
    const swift = try read("src/platform/macos/MaruAppHost.swift", 2 * 1024 * 1024);
    defer std.testing.allocator.free(swift);

    try expectContains(header, "MARU_SESSION_DEFAULT_FALSE_OBSERVATION_MATCHED");
    try expectContains(header, "maru_macos_session_default_false_observation");
    try expectContains(swift, "MARU_SESSION_DEFAULT_FALSE_EVIDENCE_SMOKE");
    try expectContains(swift, "maru_macos_session_default_false_observation()");
    try expectContains(harness, "MARU_SESSION_HOST_DEFAULT_FALSE_TEST_UUID");
    try expectContains(harness, "release_evidence.default_false_leaf_schema");
}

test "default false leaf pins the signed candidate and publishes exclusively" {
    const source = try read("src/platform/macos/session_host/cr6c_appkit_smoke.zig", 1024 * 1024);
    defer std.testing.allocator.free(source);

    try expectContains(source, "MARU_SESSION_HOST_DEFAULT_FALSE_CANDIDATE_DMG");
    try expectContains(source, "MARU_SESSION_HOST_DEFAULT_FALSE_FROZEN_EXE");
    try expectContains(source, "validateDefaultFalseCandidate");
    try expectContains(source, ".exclusive = true");
    try expectContains(source, ".permissions = std.Io.File.Permissions.fromMode(0o600)");
    try expectContains(source, "resolved_default = false");
    try expectContains(source, "explicit_override_present = false");
    try expectContains(source, "signed_product = true");
}

test "default false product run owns an empty isolated config root" {
    const build = try read("build.zig", 2 * 1024 * 1024);
    defer std.testing.allocator.free(build);
    const swift = try read("src/platform/macos/MaruAppHost.swift", 2 * 1024 * 1024);
    defer std.testing.allocator.free(swift);

    try expectContains(build, "macos-session-host-default-false-evidence");
    try expectContains(build, "session-host-default-false-home");
    try expectContains(swift, "isSessionHostDefaultFalseEvidenceMode");
    try std.testing.expect(std.mem.indexOf(u8, build, "MARU_SESSION_HOST_DEFAULT_FALSE_RESULT") == null);
}

fn read(path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(limit));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}
