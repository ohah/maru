//! P5c3d product E2E의 hermetic fixture와 제품 경로 경계.
//!
//! 같은 MRSH major라는 이유만으로 현재 제품 모듈을 재사용한 test double은 구 host 호환성을
//! 증명하지 못한다. 고정 source/provenance와 실제 subprocess gate가 함께 존재해야 한다.

const std = @import("std");

test "p5c3d compatibility fixture is frozen source with provenance and a product process caller" {
    const allocator = std.testing.allocator;
    const fixture = try read(
        allocator,
        "tests/fixtures/session_host_pre_p5b3_v2.zig",
        2 * 1024 * 1024,
    );
    defer allocator.free(fixture);
    const provenance = try read(
        allocator,
        "tests/fixtures/session_host_pre_p5b3_v2_provenance.zig",
        64 * 1024,
    );
    defer allocator.free(provenance);
    const e2e = try read(
        allocator,
        "tests/session_host_3d_e2e.zig",
        2 * 1024 * 1024,
    );
    defer allocator.free(e2e);
    const product_e2e = try read(
        allocator,
        "tests/session_host_3d_product_e2e.zig",
        2 * 1024 * 1024,
    );
    defer allocator.free(product_e2e);
    const matrix = try read(
        allocator,
        "docs/verification-matrix.md",
        3 * 1024 * 1024,
    );
    defer allocator.free(matrix);

    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, fixture, "@import(\"maru\")"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, fixture, "@import(\"session_host\")"));
    // The frozen peer must not know either future additive field by name. Compatibility is proved
    // by the old object decoder ignoring them, not by teaching the fixture a special-case shim.
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, fixture, "separators_hex"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, fixture, "\\\"all\\\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, fixture, "runtime.select_op.legacy\\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, fixture, "runtime.selected_text.legacy\\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, provenance, "pub const source_revision ="));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, provenance, "pub const source_sha256 ="));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, provenance, "pub const expected_fingerprint ="));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, e2e, "MARU_SESSION_HOST_PRE_P5B3_EXE"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, e2e, "MARU_SESSION_HOST_PRODUCT_EXE"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, product_e2e, "MARU_SESSION_HOST_PRODUCT_EXE"));
    try std.testing.expect(std.mem.indexOf(u8, product_e2e, "spawnSessionHostSupervisedForTest") != null);
    try std.testing.expect(std.mem.indexOf(u8, product_e2e, "expectAnsiOracle") != null);
    // P5c3d의 actual product gate가 존재하는데 상단 이력 문장만 미완료로 남으면
    // 검증 매트릭스가 서로 반대 상태를 말한다. 제품 증거와 상태 표기를 함께 고정한다.
    try std.testing.expect(std.mem.indexOf(u8, matrix, "P5c3d E2E는 미완료다") == null);
    try std.testing.expect(std.mem.indexOf(u8, matrix, "P5c3d의 built host/runtime/attach-child 호환성 E2E") != null);
}

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}
