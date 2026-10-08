//! 요청 세대와 열린 경로 점유는 결과 수와 무관하다. 실패한 사본도 디스크 결과를 되살리지 않는다.
const std = @import("std");
const event = @import("event.zig");
pub const Status = enum { running, complete, cancelled, partial, failed };
pub const Limits = struct { matches: usize = 20_000, result_bytes: usize, event_bytes: usize };
pub const Identity = struct { request: u64, root: u64, models: u64 };
pub const DocumentIdentity = struct { owner: usize, slot: usize, generation: u64 };
pub const Source = union(enum) { disk, model: struct { document: DocumentIdentity, revision: u64, composition: u64 } };
pub const Row = struct { source: Source, match: event.Match, root_index: usize = 0 };
/// worker와 owner가 같은 root 상대 경로 축을 쓴다. 상위 이동·절대 경로는 받지 않는다.
pub fn relativePath(input: []const u8) ![]const u8 {
    var path = input;
    while (std.mem.startsWith(u8, path, "./")) path = path[2..];
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPath;
    return path;
}
pub const State = struct {
    identity: Identity,
    limits: Limits,
    status: Status = .running,
    rows: std.ArrayList(Row) = .empty,
    occupied: std.StringHashMapUnmanaged(void) = .{},
    matches: usize = 0,
    bytes: usize = 0,
    excluded: usize = 0,

    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        for (self.rows.items) |*row| row.match.deinit(a);
        self.rows.deinit(a);
        var keys = self.occupied.keyIterator();
        while (keys.next()) |key| a.free(key.*);
        self.occupied.deinit(a);
    }
    pub fn occupy(self: *State, a: std.mem.Allocator, input: []const u8) !void {
        const path = try relativePath(input);
        if (self.occupied.contains(path)) return;
        const copy = try a.dupe(u8, path);
        errdefer a.free(copy);
        try self.occupied.put(a, copy, {});
    }
    pub fn accepts(self: *const State, identity: Identity) bool {
        return self.status == .running and std.meta.eql(self.identity, identity);
    }
    /// 성공 시에만 소유권이 이동한다. 거절·OOM은 호출자가 해제한다.
    pub fn append(self: *State, a: std.mem.Allocator, identity: Identity, source: Source, match: event.Match) !bool {
        if (!self.accepts(identity)) return false;
        const path = try relativePath(match.path);
        if (source == .disk and self.occupied.contains(path)) return false;
        return self.appendSelected(a, identity, source, match);
    }
    /// root별 선정과 전역 점유 판정을 끝낸 coordinator만 사용한다.
    pub fn appendSelected(self: *State, a: std.mem.Allocator, identity: Identity, source: Source, match: event.Match) !bool {
        if (!self.accepts(identity)) return false;
        _ = try relativePath(match.path);
        const count = match.ranges.len;
        if (count == 0) return false;
        const bytes = std.math.add(usize, match.path.len, match.text.len) catch return error.ResultTooLarge;
        const payload = std.math.add(usize, bytes, std.math.mul(usize, count, @sizeOf(event.Range)) catch return error.ResultTooLarge) catch return error.ResultTooLarge;
        const size = std.math.add(usize, payload, @sizeOf(Row)) catch return error.ResultTooLarge;
        if (count > self.limits.matches -| self.matches or size > self.limits.result_bytes -| self.bytes) {
            self.status = .partial;
            return false;
        }
        try self.rows.append(a, .{ .source = source, .match = match });
        self.matches += count;
        self.bytes += size;
        return true;
    }
    pub fn cancel(self: *State) void {
        self.status = .cancelled;
    }
    pub fn finish(self: *State, status: Status) void {
        if (self.status == .running) self.status = status;
    }
};

test "PSR1 열린 경로는 0건·실패에도 디스크 결과를 억제한다" {
    const a = std.testing.allocator;
    var state: State = .{ .identity = .{ .request = 1, .root = 2, .models = 3 }, .limits = .{ .result_bytes = 4096, .event_bytes = 4096 } };
    defer state.deinit(a);
    try state.occupy(a, "./a.txt");
    try state.occupy(a, "././a.txt");
    var match: event.Match = .{ .path = try a.dupe(u8, "./a.txt"), .text = try a.dupe(u8, "foo"), .ranges = try a.alloc(event.Range, 1) };
    defer match.deinit(a);
    match.ranges[0] = .{ .start = .{ .line = 0, .byte = 0 }, .end = .{ .line = 0, .byte = 3 } };
    try std.testing.expect(!try state.append(a, state.identity, .disk, match));
    state.excluded = 1;
    try std.testing.expect(!try state.append(a, state.identity, .disk, match));
    state.cancel();
    try std.testing.expect(!state.accepts(state.identity));
    state.finish(.complete);
    try std.testing.expectEqual(Status.cancelled, state.status);
}
test "PSR2 결과 상한과 오래된 세대는 terminal 상태를 덮어쓰지 않는다" {
    const a = std.testing.allocator;
    var state: State = .{ .identity = .{ .request = 1, .root = 2, .models = 3 }, .limits = .{ .matches = 0, .result_bytes = 0, .event_bytes = 64 } };
    defer state.deinit(a);
    var match: event.Match = .{ .path = try a.dupe(u8, "a"), .text = try a.dupe(u8, "foo"), .ranges = try a.alloc(event.Range, 1) };
    defer match.deinit(a);
    try std.testing.expect(!try state.append(a, .{ .request = 0, .root = 2, .models = 3 }, .disk, match));
    try std.testing.expectEqual(Status.running, state.status);
    try std.testing.expect(!try state.append(a, state.identity, .disk, match));
    state.finish(.complete);
    try std.testing.expectEqual(Status.partial, state.status);
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var current: State = .{ .identity = .{ .request = 1, .root = 1, .models = 1 }, .limits = .{ .result_bytes = 4096, .event_bytes = 4096 } };
            defer current.deinit(alloc);
            try current.occupy(alloc, "occupied.txt");
            const path = try alloc.dupe(u8, "a.txt");
            errdefer alloc.free(path);
            const text = try alloc.dupe(u8, "foo");
            errdefer alloc.free(text);
            const ranges = try alloc.alloc(event.Range, 1);
            errdefer alloc.free(ranges);
            ranges[0] = .{ .start = .{ .line = 0, .byte = 0 }, .end = .{ .line = 0, .byte = 3 } };
            try std.testing.expect(try current.append(alloc, current.identity, .disk, .{ .path = path, .text = text, .ranges = ranges }));
        }
    }.run, .{});
}
