//! External URLs must not reinterpret paths or consume startup requests twice.
//! These independent literals protect file identity and navigation before OS wiring.
const std = @import("std");
const url = @import("editor_app_url.zig");

test "editor app URL grammar preserves encoded file names" {
    const cases = .{
        .{ "maru://open?path=%2Ftmp%2Fa%2Bb.zig&line=42&column=7", "/tmp/a+b.zig" },
        .{ "MARU://OPEN?path=%2Ftmp%2Fa%252Fb", "/tmp/a%2Fb" },
        .{ "maru://open?path=/tmp/a+b", "/tmp/a+b" },
        .{ "maru://open?path=%2Ftmp%2Fa%26b%3Dc", "/tmp/a&b=c" },
        .{ "maru://open?path=%2Ftmp%2F%ED%95%9C", "/tmp/한" },
    };
    inline for (cases) |c| {
        var request = try url.parse(std.testing.allocator, c[0]);
        defer request.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(c[1], request.path);
    }
    var request = try url.parse(std.testing.allocator, cases[0][0]);
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 42), request.line);
    try std.testing.expectEqual(@as(u32, 7), request.column);
}

test "editor app URL rejects ambiguous grammar and numeric overflow" {
    const bad = [_][]const u8{
        "http://open?path=/tmp/a",                 "maru://open/?path=/tmp/a",              "maru://user@open?path=/tmp/a",
        "maru://open:1?path=/tmp/a",               "maru://open?path=/tmp/a#x",             "maru://open?path=/tmp/a&",
        "maru://open?path=/tmp/a&path=/tmp/b",     "maru://open?%70ath=/tmp/a",             "maru://open?path=/tmp/a&x=1",
        "maru://open?path=a",                      "maru://open?path=",                     "maru://open?path=/tmp/%",
        "maru://open?path=/tmp/%GG",               "maru://open?path=/tmp/%FF",             "maru://open?path=/tmp/%00",
        "maru://open?path=/tmp/%0A",               "maru://open?path=/tmp/a&column=1",      "maru://open?path=/tmp/a&line=0",
        "maru://open?path=/tmp/a&line=-1",         "maru://open?path=/tmp/a&line=+1",       "maru://open?path=/tmp/a&line=4294967296",
        "maru://open?path=/tmp/a&line=1&column=0", "maru://open?path=/tmp/a&line=1&line=2", "maru://open?path=/tmp/a&line=1&column=1&column=2",
    };
    for (bad) |raw| try std.testing.expectError(error.InvalidURL, url.parse(std.testing.allocator, raw));
}

test "editor app URL ready queue is bounded FIFO and terminal stop" {
    var queue: url.Queue = .{};
    defer queue.stop(std.testing.allocator);
    try queue.offer(std.testing.allocator, "maru://open?path=/tmp/a&line=1");
    try queue.offer(std.testing.allocator, "maru://open?path=/tmp/b&line=2");
    try std.testing.expect(queue.take() == null);
    queue.ready();
    queue.ready();
    var first = queue.take().?;
    defer first.deinit(std.testing.allocator);
    var second = queue.take().?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/a", first.path);
    try std.testing.expectEqualStrings("/tmp/b", second.path);
    try std.testing.expectEqual(@as(u64, 1), first.id);
    try std.testing.expectEqual(@as(u64, 2), second.id);
    try std.testing.expect(queue.take() == null);
    try std.testing.expectEqual(@as(usize, 0), queue.raw_bytes);
    for (0..32) |_| try queue.offer(std.testing.allocator, "maru://open?path=/tmp/a");
    try std.testing.expectError(error.Full, queue.offer(std.testing.allocator, "maru://open?path=/tmp/b"));
    queue.stop(std.testing.allocator);
    queue.ready();
    try std.testing.expectError(error.Stopped, queue.offer(std.testing.allocator, "maru://open?path=/tmp/b"));
    try std.testing.expect(queue.take() == null);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var queue: url.Queue = .{};
    defer queue.stop(allocator);
    try queue.offer(allocator, "maru://open?path=/tmp/a");
    try queue.offer(allocator, "maru://open?path=/tmp/b");
    queue.ready();
    var request = queue.take().?;
    defer request.deinit(allocator);
}

test "editor app URL allocation failures release every queued path" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "editor app URL path and aggregate byte limits and ring reuse" {
    const raw = "maru://open?path=/" ++ ("%41" ** 4095);
    var queue: url.Queue = .{};
    defer queue.stop(std.testing.allocator);
    for (0..5) |_| try queue.offer(std.testing.allocator, raw);
    try std.testing.expectError(error.Full, queue.offer(std.testing.allocator, raw));
    queue.ready();
    for (0..5) |_| {
        var item = queue.take().?;
        try std.testing.expectEqual(@as(usize, 4096), item.path.len);
        item.deinit(std.testing.allocator);
    }
    for (0..100) |_| {
        try queue.offer(std.testing.allocator, "maru://open?path=/tmp/again");
        var item = queue.take().?;
        try std.testing.expectEqualStrings("/tmp/again", item.path);
        item.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), queue.raw_bytes);
    try std.testing.expectError(error.TooLong, url.parse(std.testing.allocator, "maru://open?path=/" ++ ("a" ** 4096)));
    try std.testing.expectError(error.TooLong, url.parse(std.testing.allocator, "x" ** 16385));
}

test "editor app URL independent encoder corpus five deterministic seeds" {
    const hex = "0123456789ABCDEF";
    // The encoder starts from expected filename bytes rather than reusing parser
    // logic. Five seeds cover raw delimiter/percent/plus bytes in encoded values.
    for ([_]u64{ 7, 19, 31, 53, 97 }) |seed| {
        var random = std.Random.DefaultPrng.init(seed);
        for (0..200) |_| {
            var filename: [65]u8 = undefined;
            filename[0] = '/';
            for (filename[1..]) |*byte| byte.* = random.random().intRangeAtMost(u8, 32, 126);
            var encoded: ["maru://open?path=".len + 65 * 3]u8 = undefined;
            @memcpy(encoded[0.."maru://open?path=".len], "maru://open?path=");
            var cursor: usize = "maru://open?path=".len;
            for (filename) |byte| {
                encoded[cursor] = '%';
                encoded[cursor + 1] = hex[byte >> 4];
                encoded[cursor + 2] = hex[byte & 15];
                cursor += 3;
            }
            var request = try url.parse(std.testing.allocator, &encoded);
            defer request.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(&filename, request.path);
        }
    }
}
