//! 문서별 이력 항목을 작업 ID로 연결한다. 경로·뷰·본문 사본은 기록하지 않는다.
//! Record ID는 배열 압축 뒤에도 바뀌지 않으며 문서 registry마다 독립된 공간이다.
const std = @import("std");
const registry = @import("../document_registry.zig");
const step = @import("step.zig");
pub const Member = struct { document: registry.Handle, epoch: u64, entry: u64 };
pub const Record = struct {
    id: u64,
    members: []Member,
    direction: step.Direction = .undo,
    invalid: bool = false,
    pub fn deinit(self: *Record, a: std.mem.Allocator) void {
        a.free(self.members);
    }
};
pub const State = struct {
    records: std.ArrayList(Record) = .empty,
    next_id: u64 = 1,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        for (self.records.items) |*record| record.deinit(a);
        self.records.deinit(a);
    }
    pub fn prepare(self: *State, a: std.mem.Allocator, members: []const Member) !Record {
        if (self.next_id == std.math.maxInt(u64)) return error.OperationIdExhausted;
        if (members.len < 2) return error.NotMultipleDocuments;
        for (members, 0..) |m, i| {
            if (m.entry == 0 or m.epoch == std.math.maxInt(u64)) return error.InvalidMember;
            for (members[0..i]) |other| if (std.meta.eql(m.document, other.document)) return error.DuplicateDocument;
        }
        try self.records.ensureUnusedCapacity(a, 1);
        return .{ .id = self.next_id, .members = try a.dupe(Member, members) };
    }
    /// 호출자는 본문 결산 전에 슬롯을 준비하고 같은 actor 사건 안에서 게시한다.
    pub fn publish(self: *State, record: Record) void {
        std.debug.assert(record.id == self.next_id);
        self.records.appendAssumeCapacity(record);
        self.next_id += 1;
    }
    pub fn get(self: *State, id: u64) ?*Record {
        for (self.records.items) |*record| if (record.id == id) return record;
        return null;
    }
    pub fn find(self: *const State, document: registry.Handle, epoch: u64, entry: u64, direction: step.Direction) ?u64 {
        for (self.records.items) |record| {
            if (record.direction != direction) continue;
            for (record.members) |m| if (std.meta.eql(document, m.document) and epoch == m.epoch and entry == m.entry) return record.id;
        }
        return null;
    }
    pub fn remove(self: *State, a: std.mem.Allocator, id: u64) void {
        for (self.records.items, 0..) |record, i| if (record.id == id) {
            var removed = self.records.orderedRemove(i);
            removed.deinit(a);
            return;
        };
    }
    pub fn closeDocument(self: *State, document: registry.Handle) void {
        for (self.records.items) |*record| for (record.members) |m| {
            if (std.meta.eql(document, m.document)) record.invalid = true;
        };
    }
    /// 항목 폐기·초기화 뒤 연결만 정산한다. 다른 문서의 정상 Undo/Redo는 건드리지 않는다.
    pub fn prune(self: *State, a: std.mem.Allocator, context: anytype, contains: anytype) void {
        var i: usize = 0;
        while (i < self.records.items.len) {
            var any = false;
            var all = true;
            for (self.records.items[i].members) |m| {
                const live = contains(context, m);
                any = any or live;
                all = all and live;
            }
            if (!any) {
                var removed = self.records.orderedRemove(i);
                removed.deinit(a);
            } else {
                if (!all) self.records.items[i].invalid = true;
                i += 1;
            }
        }
    }
};

const testing = std.testing;
const fixture_members = [_]Member{
    .{ .document = .{ .slot = 0, .generation = 1 }, .epoch = 1, .entry = 1 },
    .{ .document = .{ .slot = 1, .generation = 1 }, .epoch = 1, .entry = 1 },
};
fn allocationProbe(a: std.mem.Allocator) !void {
    var state = State{};
    defer state.deinit(a);
    var record = try state.prepare(a, &fixture_members);
    errdefer record.deinit(a);
    try testing.expectEqual(@as(usize, 0), state.records.items.len);
    try testing.expectEqual(@as(u64, 1), state.next_id);
    state.publish(record);
    try testing.expectEqual(@as(u64, 2), state.next_id);
}
test "LHT5 연결 예약 실패는 미게시 상태와 신원을 보존한다" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationProbe, .{});
}
test "LHT6 배열 압축 epoch와 generation은 지난 연결을 되살리지 않는다" {
    var state = State{};
    defer state.deinit(testing.allocator);
    const one = try state.prepare(testing.allocator, &fixture_members);
    state.publish(one);
    var next = fixture_members;
    next[0].entry = 2;
    next[1].entry = 2;
    const two = try state.prepare(testing.allocator, &next);
    state.publish(two);
    state.remove(testing.allocator, one.id);
    try testing.expectEqual(two.id, state.find(next[0].document, 1, 2, .undo).?);
    var reused = next[0].document;
    reused.generation += 1;
    try testing.expectEqual(@as(?u64, null), state.find(reused, 1, 2, .undo));
    try testing.expectEqual(@as(?u64, null), state.find(next[0].document, 2, 2, .undo));
    state.closeDocument(next[1].document);
    try testing.expect(state.get(two.id).?.invalid);
    const live = struct {
        fn contains(n: usize, m: Member) bool {
            return m.document.slot < n;
        }
    }.contains;
    state.prune(testing.allocator, @as(usize, 1), live);
    try testing.expect(state.get(two.id) != null);
    state.prune(testing.allocator, @as(usize, 0), live);
    try testing.expect(state.get(two.id) == null);
}
