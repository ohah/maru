const std = @import("std");

test "C3-3b6 shutdown boundary는 제품 caller와 중립 layering을 고정한다" {
    const allocator = std.testing.allocator;
    const app = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const contract = try readSource(allocator, "src/app/shutdown_contract.zig");
    defer allocator.free(contract);
    const diagnostic = try readSource(allocator, "src/app/shutdown_diagnostic.zig");
    defer allocator.free(diagnostic);
    const client = try readSource(allocator, "src/platform/macos/session_host/client.zig");
    defer allocator.free(client);
    const connector = try readSource(allocator, "src/platform/macos/session_host/shutdown_admin_connector.zig");
    defer allocator.free(connector);
    const compatibility = try readSource(allocator, "src/platform/macos/session_host/compatibility.zig");
    defer allocator.free(compatibility);
    const baseline = try readSource(allocator, "src/platform/macos/session_host/shutdown_n1_baseline.zig");
    defer allocator.free(baseline);
    const baseline_manifest = try readSource(allocator, "tests/fixtures/session_host_n1/manifest.json");
    defer allocator.free(baseline_manifest);
    const baseline_patch = try readSource(allocator, "tests/fixtures/session_host_n1/source.patch");
    defer allocator.free(baseline_patch);
    const build_source = try readSource(allocator, "build.zig");
    defer allocator.free(build_source);

    try std.testing.expectEqual(@as(usize, 1), count(app, "backend.beginAppQuitShutdown(std.Io.Clock.awake.now(self.io).nanoseconds)"));
    try std.testing.expectEqual(@as(usize, 1), count(app, "backend.tombstoneAllRoutingForAppQuit()"));
    try std.testing.expectEqual(@as(usize, 1), count(app, "backend.terminalizeSharedConnectionsNoDestroy()"));
    try std.testing.expectEqual(@as(usize, 1), count(app, "backend.settlePendingOwnersForAppQuit()"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn settlePendingOwnersForAppQuit("));
    // end-all 제품 경로는 AppSession 확인에서 한 번 준비하고 frame tick에서 현재 ordinal 하나만 진행한다.
    try std.testing.expectEqual(@as(usize, 1), count(app, ".prepareAppQuitEndAll(now)"));
    try std.testing.expectEqual(@as(usize, 1), count(app, ".advanceAppQuitEndAllTarget("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn prepareAppQuitEndAll("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn advanceAppQuitEndAllTarget("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn runtimeInventoryUntil("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, ".runtimeInventoryUntil(deadline)"));
    const detach_term = sliceBetween(
        backend,
        "pub fn detachTerm(",
        "fn foregroundProcessGroup(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(detach_term, "entry.runtime.detachClientSide();"));
    try std.testing.expectEqual(@as(usize, 1), count(detach_term, "const removed = self.runtimes.fetchRemove(handle)"));

    const runtime_product = sliceBefore(runtime, "test \"") orelse return error.TestUnexpectedResult;
    const backend_product = sliceBefore(backend, "test \"") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), count(runtime_product, "std.Thread.spawn"));
    try std.testing.expectEqual(@as(usize, 0), count(backend_product, "std.Thread.spawn"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime_product, "blocking reader"));
    try std.testing.expectEqual(@as(usize, 1), count(backend_product, "_ = process_in_reader;"));

    // 배포 호환성이 아닌 이전 wire 회귀 기준은 보존한 binary와 base+patch identity만 허용한다. 일반 attach는 이 예외를 쓰지 않는다.
    try std.testing.expectEqual(@as(usize, 1), count(compatibility, "@import(\"shutdown_n1_baseline.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(connector, ".connectFrozenShutdownUntil("));
    try std.testing.expectEqual(@as(usize, 1), count(client, "pub fn connectFrozenShutdownUntil("));
    // Legacy hello authority is a closed policy domain: normal callers remain strict, while the
    // frozen shutdown and GUI paths cannot be confused through an ambient boolean.
    try std.testing.expectEqual(@as(usize, 1), count(client, "const LegacyHelloPolicy = enum {"));
    try std.testing.expectEqual(@as(usize, 3), count(client, "legacy_hello_policy: LegacyHelloPolicy"));
    try std.testing.expectEqual(@as(usize, 2), count(client, ".frozen_shutdown"));
    try std.testing.expectEqual(@as(usize, 1), count(baseline, "314b7912613c2e84cbf11e2cc8b0775e9e3f99fb"));
    try std.testing.expectEqual(@as(usize, 1), count(baseline, "4004256667fee2b40d41c7fe678ef44c7b5385fd4ff25410c40a9198344ce64c"));
    try std.testing.expectEqual(@as(usize, 1), count(baseline_manifest, "314b7912613c2e84cbf11e2cc8b0775e9e3f99fb"));
    try std.testing.expectEqual(@as(usize, 1), count(baseline_manifest, "bb9a180c4e085859dc35c4ff264fc0b90c0692f98810c56b6cd5982d5b106fb4"));
    try std.testing.expectEqual(@as(usize, 1), count(baseline_manifest, "4004256667fee2b40d41c7fe678ef44c7b5385fd4ff25410c40a9198344ce64c"));
    try std.testing.expectEqual(@as(usize, 2), count(baseline_patch, "+pub const "));
    try std.testing.expectEqual(@as(usize, 0), count(build_source, "session_host_2c3d_c3_3b6_red.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(build_source, "C3-3b6 실제 이전 wire 기준은 ambiguous 뒤 destructive retry를 하지 않는다"));

    inline for (.{ contract, diagnostic }) |neutral| {
        try std.testing.expectEqual(@as(usize, 0), count(neutral, "app_session"));
        try std.testing.expectEqual(@as(usize, 0), count(neutral, "remote_term_backend"));
        try std.testing.expectEqual(@as(usize, 0), count(neutral, "std.log"));
    }
}

fn sliceBefore(source: []const u8, marker: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, source, marker) orelse return null;
    return source[0..end];
}

fn sliceBetween(source: []const u8, start_marker: []const u8, end_marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, source, start_marker) orelse return null;
    const tail = source[start..];
    const end = std.mem.indexOf(u8, tail, end_marker) orelse return null;
    return tail[0..end];
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    );
}
