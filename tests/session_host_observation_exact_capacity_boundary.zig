const std = @import("std");

test "C3-3b2b0 RuntimeObservation exact-capacity boundary" {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        "src/app/term_runtime_backend.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
        .of(u8),
        0,
    );
    defer std.testing.allocator.free(source);

    const replace_start = std.mem.indexOf(u8, source, "    pub fn replace(") orelse
        return error.TestUnexpectedResult;
    const view_start = std.mem.indexOfPos(u8, source, replace_start, "    pub fn view(") orelse
        return error.TestUnexpectedResult;
    const replace_source = source[replace_start..view_start];

    try std.testing.expectEqual(@as(usize, 1), count(source, "pub fn replace("));
    try std.testing.expectEqual(@as(usize, 0), count(source, "pub fn replaceExact("));
    try std.testing.expectEqual(@as(usize, 1), count(replace_source, "ensureTotalCapacityPrecise("));
    try std.testing.expectEqual(@as(usize, 1), count(replace_source, "appendSliceAssumeCapacity("));
    try std.testing.expectEqual(@as(usize, 0), count(replace_source, ".appendSlice(allocator,"));
    try std.testing.expectEqual(@as(usize, 8), count(replace_source, "exactOwnedCopy("));
    inline for (.{
        "next.cwd = try exactOwnedCopy",
        "next.cwd_host = try exactOwnedCopy",
        "next.window_title = try exactOwnedCopy",
        "next.ssh_remote_dest = try exactOwnedCopy",
        "next.clipboard_read_target = try exactOwnedCopy",
        "next.foreground_processes = try exactOwnedCopy",
        "next.agent_progress = try exactOwnedCopy",
    }) |marker| try std.testing.expectEqual(@as(usize, 1), count(replace_source, marker));
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
