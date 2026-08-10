const std = @import("std");

const run_a = @embedFile("process_seal_fresh_exec_a");
const run_b = @embedFile("process_seal_fresh_exec_b");
const record_magic = "MRPSv1\x00\x00";

test "C3-3b2a product singleton is fresh across independent execs" {
    const first = try parseRecord(run_a);
    const second = try parseRecord(run_b);
    try std.testing.expect(first != second);
}

fn parseRecord(record: []const u8) !u64 {
    try std.testing.expectEqual(@as(usize, 16), record.len);
    try std.testing.expectEqualSlices(u8, record_magic, record[0..8]);
    const tag = std.mem.readInt(u64, record[8..16], .little);
    try std.testing.expect(tag != 0);
    return tag;
}
