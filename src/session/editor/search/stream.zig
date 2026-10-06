//! stdout 조각은 UTF-8/JSON 경계와 무관하다. 한 전문만 모으고 소유권을 parser로 넘긴다.
const std = @import("std");
pub const Stream = struct {
    pending: std.ArrayList(u8) = .empty,
    max_event_bytes: usize,
    failed: bool = false,
    pub fn deinit(self: *Stream, a: std.mem.Allocator) void {
        self.pending.deinit(a);
    }
    pub fn consume(self: *Stream, a: std.mem.Allocator, data: []const u8, context: anytype, callback: anytype) !void {
        if (self.failed) return error.StreamFailed;
        errdefer self.failed = true;
        var from: usize = 0;
        while (from < data.len) {
            const newline = std.mem.indexOfScalarPos(u8, data, from, '\n');
            const end = newline orelse data.len;
            if (end - from > self.max_event_bytes -| self.pending.items.len) return error.EventTooLarge;
            try self.pending.appendSlice(a, data[from..end]);
            if (newline == null) return;
            if (self.pending.items.len == 0) return error.EmptyEvent;
            try callback(context, self.pending.items);
            self.pending.clearRetainingCapacity();
            from = end + 1;
        }
    }
    pub fn finish(self: *Stream) !void {
        if (self.failed) return error.StreamFailed;
        if (self.pending.items.len != 0) {
            self.failed = true;
            return error.IncompleteEvent;
        }
    }
};

test "PSS1 every byte split preserves complete UTF8 JSON events" {
    const a = std.testing.allocator;
    const input = "{\"text\":\"가😀\"}\n{}\n";
    const Sink = struct {
        values: std.ArrayList(u8) = .empty,
        fn accept(self: *@This(), value: []const u8) !void {
            try self.values.appendSlice(std.testing.allocator, value);
            try self.values.append(std.testing.allocator, '\n');
        }
    };
    {
        var sink: Sink = .{};
        defer sink.values.deinit(a);
        var stream: Stream = .{ .max_event_bytes = input.len };
        defer stream.deinit(a);
        for (0..input.len) |i| try stream.consume(a, input[i..][0..1], &sink, Sink.accept);
        try stream.finish();
        try std.testing.expectEqualStrings(input, sink.values.items);
    }
    for (0..input.len + 1) |split| {
        var sink: Sink = .{};
        defer sink.values.deinit(a);
        var stream: Stream = .{ .max_event_bytes = input.len };
        defer stream.deinit(a);
        try stream.consume(a, input[0..split], &sink, Sink.accept);
        try stream.consume(a, input[split..], &sink, Sink.accept);
        try stream.finish();
        try std.testing.expectEqualStrings(input, sink.values.items);
    }
}

test "PSS2 truncated and oversized streams do not become successful zero results" {
    const a = std.testing.allocator;
    const Sink = struct {
        fn accept(_: void, _: []const u8) !void {}
    };
    var stream: Stream = .{ .max_event_bytes = 3 };
    defer stream.deinit(a);
    try stream.consume(a, "{}", {}, Sink.accept);
    try std.testing.expectError(error.EventTooLarge, stream.consume(a, "xx", {}, Sink.accept));
    try std.testing.expectError(error.StreamFailed, stream.finish());
    // 정확한 상한은 허용하고 callback 실패 뒤에는 추가 입력을 차단한다.
    var exact: Stream = .{ .max_event_bytes = 2 };
    defer exact.deinit(a);
    try exact.consume(a, "{}\n", {}, Sink.accept);
    try exact.finish();
    const Reject = struct {
        fn accept(_: void, _: []const u8) !void {
            return error.Rejected;
        }
    };
    var rejected: Stream = .{ .max_event_bytes = 2 };
    defer rejected.deinit(a);
    try std.testing.expectError(error.Rejected, rejected.consume(a, "{}\n", {}, Reject.accept));
    try std.testing.expectError(error.StreamFailed, rejected.consume(a, "{}\n", {}, Sink.accept));
    try std.testing.expectError(error.StreamFailed, rejected.finish());
    // 할당 실패도 정상 완료나 빈 검색 결과로 바뀌지 않는다.
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var exhausted: Stream = .{ .max_event_bytes = 2 };
    defer exhausted.deinit(failing.allocator());
    try std.testing.expectError(error.OutOfMemory, exhausted.consume(failing.allocator(), "{}", {}, Sink.accept));
    try std.testing.expectError(error.StreamFailed, exhausted.finish());
    var truncated: Stream = .{ .max_event_bytes = 32 };
    defer truncated.deinit(a);
    try truncated.consume(a, "{}", {}, Sink.accept);
    try std.testing.expectError(error.IncompleteEvent, truncated.finish());
}
