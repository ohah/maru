const std = @import("std");

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
}

test "CR3b R1 경계는 raw Client escape 없이 admission close만 연다" {
    const allocator = std.testing.allocator;
    const adapter = try readSource(allocator, "src/platform/macos/session_host/host_adapter.zig");
    defer allocator.free(adapter);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);

    try std.testing.expectEqual(@as(usize, 0), count(adapter, "pub fn logicalClient("));
    try std.testing.expectEqual(@as(usize, 0), count(backend, ".logicalClient()"));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub const testing = if (@import(\"builtin\").is_test) struct"));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn prepareAdmissionClose("));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn commitAdmissionClose("));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn cancelAdmissionClose("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub const PreparedAdmissionClose = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "fn withCurrent("));

    // R1은 current를 닫기만 한다. 교체·retire·generation 증가는 R2 전까지 제품 경로에 없어야 한다.
    // 제품 초기화와 같은 모듈의 기존 fixture 여섯 곳만 generation 1을 만든다. R1은 증가·교체 문법을 추가하지 않는다.
    try std.testing.expectEqual(@as(usize, 7), count(slot, ".connection_generation = 1"));
    try std.testing.expectEqual(@as(usize, 0), count(slot, "connection_generation +="));
    try std.testing.expectEqual(@as(usize, 0), count(slot, "retired_node"));
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
