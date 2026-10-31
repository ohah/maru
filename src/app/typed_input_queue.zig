//! Local FIFO shared by native hosts. Protocol spans retain privacy across
//! partial writes and window transfer; ordinary input retains its trace policy.
const std = @import("std");
const input = @import("input_owner.zig");
/// Suppression and dead targets must not replay old input after authority or
/// process state changes. Backpressure and transient write errors retain it.
pub fn discardOnError(err: anyerror) bool {
    return switch (err) {
        error.ProcessExited, error.UnknownSurface, error.InputSuppressed => true,
        else => false,
    };
}
pub const retain_max: usize = 64 * 1024;
const Span = struct { start: usize, end: usize };
pub const Chunk = struct { bytes: []const u8, sensitive: bool };
pub const Queue = struct {
    buf: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    spans: std.ArrayList(Span) = .empty,

    pub fn deinit(self: *Queue, a: std.mem.Allocator) void {
        self.buf.deinit(a);
        self.spans.deinit(a);
        self.* = .{};
    }
    pub fn append(self: *Queue, a: std.mem.Allocator, batch: input.InputBatch) !void {
        const sensitive = batch.kind == .osc52_response;
        if (sensitive and batch.normalize_first_newlines) return error.InvalidNormalization;
        const count = std.math.add(usize, batch.first.len, batch.second.len) catch return error.OutOfMemory;
        if (count == 0) return;
        // Reserve both owners before changing either logical length. Failure
        // can change capacity, never the existing bytes or their privacy tags.
        if (sensitive) try self.spans.ensureUnusedCapacity(a, 1);
        try self.buf.ensureUnusedCapacity(a, count);
        const start = self.buf.items.len;
        self.buf.appendSliceAssumeCapacity(batch.first);
        if (batch.normalize_first_newlines) for (self.buf.items[start..]) |*b| {
            if (b.* == '\n') b.* = '\r';
        };
        self.buf.appendSliceAssumeCapacity(batch.second);
        if (sensitive) self.spans.appendAssumeCapacity(.{ .start = start, .end = self.buf.items.len });
    }
    pub fn next(self: *const Queue) ?Chunk {
        if (self.offset >= self.buf.items.len) return null;
        for (self.spans.items) |span| {
            if (span.end <= self.offset) continue;
            if (span.start > self.offset) return .{ .bytes = self.buf.items[self.offset..@min(span.start, self.buf.items.len)], .sensitive = false };
            return .{ .bytes = self.buf.items[self.offset..@min(span.end, self.buf.items.len)], .sensitive = true };
        }
        return .{ .bytes = self.buf.items[self.offset..], .sensitive = false };
    }
    pub fn advance(self: *Queue, count: usize) !void {
        const chunk = self.next() orelse {
            if (count != 0) return error.InvalidProgress;
            return;
        };
        if (count > chunk.bytes.len) return error.InvalidProgress;
        self.offset += count;
    }
    pub fn reset(self: *Queue, a: std.mem.Allocator) void {
        self.offset = 0;
        if (self.buf.capacity > retain_max) self.buf.clearAndFree(a) else self.buf.clearRetainingCapacity();
        if (self.spans.capacity > retain_max / @sizeOf(Span)) self.spans.clearAndFree(a) else self.spans.clearRetainingCapacity();
    }
    pub fn reserveRemaining(self: *Queue, a: std.mem.Allocator, source: Queue) !void {
        try self.buf.ensureUnusedCapacity(a, source.buf.items.len -| source.offset);
        try self.spans.ensureUnusedCapacity(a, source.spans.items.len);
    }
    /// Structural moves reserve both arrays first; capture then cannot allocate.
    pub fn appendRemainingAssumeCapacity(self: *Queue, source: Queue) void {
        if (source.offset >= source.buf.items.len) return;
        const base = self.buf.items.len;
        self.buf.appendSliceAssumeCapacity(source.buf.items[source.offset..]);
        for (source.spans.items) |span| {
            if (span.end <= source.offset) continue;
            self.spans.appendAssumeCapacity(.{ .start = base + (@max(span.start, source.offset) - source.offset), .end = base + (@min(span.end, source.buf.items.len) - source.offset) });
        }
    }
};

fn expectChunk(q: *Queue, bytes: []const u8, sensitive: bool) !void {
    const chunk = q.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(bytes, chunk.bytes);
    try std.testing.expectEqual(sensitive, chunk.sensitive);
}

test "typed input queue preserves FIFO privacy spans and normalization" {
    var q: Queue = .{};
    defer q.deinit(std.testing.allocator);
    try q.append(std.testing.allocator, .{ .kind = .ime_commit, .first = "a\n", .normalize_first_newlines = true });
    try q.append(std.testing.allocator, .{ .kind = .osc52_response, .first = "secret\r\n" });
    try q.append(std.testing.allocator, .{ .kind = .paste, .first = "tail" });
    try expectChunk(&q, "a\r", false);
    try q.advance(2);
    try expectChunk(&q, "secret\r\n", true);
    try q.advance(8);
    try expectChunk(&q, "tail", false);
    const before = q.buf.items.len;
    try std.testing.expectError(error.InvalidNormalization, q.append(std.testing.allocator, .{ .kind = .osc52_response, .first = "x\n", .normalize_first_newlines = true }));
    try std.testing.expectEqual(before, q.buf.items.len);
}

test "typed input queue partial stalled and invalid progress preserve ownership" {
    var q: Queue = .{};
    defer q.deinit(std.testing.allocator);
    try q.append(std.testing.allocator, .{ .kind = .osc52_response, .first = "abcdef" });
    try q.advance(2);
    try q.advance(0);
    try expectChunk(&q, "cdef", true);
    try std.testing.expectError(error.InvalidProgress, q.advance(5));
    try expectChunk(&q, "cdef", true);
    try q.advance(4);
    try std.testing.expect(q.next() == null);
    try std.testing.expectError(error.InvalidProgress, q.advance(1));
}

test "typed input queue window transfer rebases sensitive remaining spans" {
    const a = std.testing.allocator;
    var source: Queue = .{};
    defer source.deinit(a);
    var dest: Queue = .{};
    defer dest.deinit(a);
    try source.append(a, .{ .kind = .paste, .first = "a" });
    try source.append(a, .{ .kind = .osc52_response, .first = "secret" });
    try source.append(a, .{ .kind = .paste, .first = "TAIL" });
    try source.advance(1);
    try source.advance(2);
    try dest.append(a, .{ .kind = .paste, .first = "X" });
    try dest.reserveRemaining(a, source);
    dest.appendRemainingAssumeCapacity(source);
    try expectChunk(&dest, "X", false);
    try dest.advance(1);
    try expectChunk(&dest, "cret", true);
    try dest.advance(4);
    try expectChunk(&dest, "TAIL", false);
    try expectChunk(&source, "cret", true);
}

fn allocationProbe(backing: std.mem.Allocator) !void {
    // Force allocation rather than address-dependent resize success so every
    // exercised growth point receives a deterministic failure index.
    var moving = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
    const a = moving.allocator();
    var q: Queue = .{};
    defer q.deinit(a);
    try q.append(a, .{ .kind = .paste, .first = "X" });
    const payload: [1024]u8 = @splat('s');
    try std.testing.expect(q.buf.capacity < payload.len);
    q.append(a, .{ .kind = .osc52_response, .first = &payload }) catch |err| {
        try expectChunk(&q, "X", false);
        try std.testing.expectEqual(@as(usize, 0), q.spans.items.len);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), q.spans.items.len);
    var dest: Queue = .{};
    defer dest.deinit(a);
    try dest.reserveRemaining(a, q);
    dest.appendRemainingAssumeCapacity(q);
    try expectChunk(&dest, "X", false);
    try dest.advance(1);
    try expectChunk(&dest, &payload, true);
}

test "typed input queue append and transfer allocation failures are transactional" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "typed input queue reset drops large payload and all privacy metadata" {
    var q: Queue = .{};
    defer q.deinit(std.testing.allocator);
    try q.buf.ensureTotalCapacity(std.testing.allocator, retain_max + 1);
    try q.append(std.testing.allocator, .{ .kind = .osc52_response, .first = "secret" });
    q.reset(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), q.buf.capacity);
    try std.testing.expectEqual(@as(usize, 0), q.spans.items.len);
    try std.testing.expectEqual(@as(usize, 0), q.offset);
    try std.testing.expect(q.next() == null);
    try q.append(std.testing.allocator, .{ .kind = .paste, .first = "new" });
    try expectChunk(&q, "new", false);
}
