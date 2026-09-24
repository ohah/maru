const std = @import("std");
const max_source_bytes = 2 * 1024 * 1024;

test "CR3a-2e 경계는 batch 예약을 attach wire보다 앞에 두고 post-attach mint를 금지한다" {
    const allocator = std.testing.allocator;
    const attachment = try std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        "src/platform/macos/session_host/generation_attachment.zig",
        allocator,
        .limited(max_source_bytes),
        .of(u8),
        0,
    );
    defer allocator.free(attachment);
    const adapter = try std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        "src/platform/macos/session_host/host_adapter.zig",
        allocator,
        .limited(max_source_bytes),
        .of(u8),
        0,
    );
    defer allocator.free(adapter);
    const prepare = std.mem.indexOf(u8, attachment, "reserveGenerationBatchAdapter(") orelse
        return error.TestUnexpectedResult;
    const execute = std.mem.indexOf(u8, attachment, "prepareRequest(") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(prepare < execute);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, attachment, "reserveGenerationBatchAdapter("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, attachment, "mintGenerationBatchAdapter("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, attachment, "preflightPreparedStream(state.stream_id)"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, attachment, "bindPreparedStreamNoFail(state.stream_id)"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, adapter, "pub fn reserveGenerationBatchAdapter("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, attachment, "ExternalInboxLedger"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, adapter, "ExternalInboxLedger"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, attachment, "retired"));
}
