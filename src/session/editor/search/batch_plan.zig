//! 모든 원문을 검증한 뒤에만 편집 목록을 돌려준다. 실제 문서 변경과 저장은 host 책임이다.
const std = @import("std");
const batch = @import("batch.zig");
const request = @import("request.zig");
const preview = @import("preview.zig");
const delta = @import("../delta.zig");

pub const Body = struct { absolute: []const u8, source: request.Source, text: []const u8 };
pub const Item = struct {
    plan: preview.Plan,
    changes: []delta.Change,
    fn deinit(self: *Item, a: std.mem.Allocator) void {
        a.free(self.changes);
        self.plan.deinit(a);
    }
};
pub const Prepared = struct {
    items: std.ArrayList(Item) = .empty,
    effective: usize = 0,
    pub fn deinit(self: *Prepared, a: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(a);
        self.items.deinit(a);
    }
    /// 대상 순서와 원문 신원을 함께 검사한다. 앞 파일 준비 성공은 아직 편집 성공이 아니다.
    pub fn prepare(a: std.mem.Allocator, spec: *const batch.Specification, bodies: []const Body, total_limit: usize, file_limit: usize, cancelled: *const std.atomic.Value(bool)) !Prepared {
        if (cancelled.load(.acquire)) return error.Cancelled;
        if (bodies.len != spec.targets.items.len) return error.StaleTargets;
        var bytes: usize = 0;
        for (spec.targets.items, bodies) |target, body| {
            if (!std.mem.eql(u8, target.absolute, body.absolute) or !std.meta.eql(target.source, body.source)) return error.StaleTargets;
            if (body.text.len > total_limit -| bytes) return error.TooLarge;
            bytes += body.text.len;
        }
        var self: Prepared = .{};
        errdefer self.deinit(a);
        try self.items.ensureTotalCapacity(a, bodies.len);
        for (spec.targets.items, bodies) |target, body| {
            var plan = try preview.prepare(a, body.text, spec.needle, spec.replacement, spec.options, target.ranges.items, file_limit, cancelled);
            errdefer plan.deinit(a);
            // changes의 문자열은 Plan.after를 빌린다. 최종 actor 반영까지 둘을 함께 보존한다.
            const changes = try plan.changes(a);
            self.items.appendAssumeCapacity(.{ .plan = plan, .changes = changes });
            if (changes.len > 0) self.effective += 1;
        }
        if (cancelled.load(.acquire)) return error.Cancelled;
        return self;
    }
};

const testing = std.testing;
const identity: request.Identity = .{ .request = 1, .root = 1, .models = 1 };
const span = @import("event.zig").Range{ .start = .{ .line = 0, .byte = 0 }, .end = .{ .line = 0, .byte = 3 } };
fn path(comptime second: bool) []const u8 {
    return if (@import("builtin").os.tag == .windows) (if (second) "C:\\b" else "C:\\a") else (if (second) "/b" else "/a");
}
fn specification(a: std.mem.Allocator, replacement: []const u8) !batch.Specification {
    return batch.Specification.capture(a, identity, .complete, "foo", replacement, .{}, &.{
        .{ .absolute = path(false), .root_index = 0, .source = .disk, .ranges = &.{span} },
        .{ .absolute = path(true), .root_index = 0, .source = .disk, .ranges = &.{span} },
    });
}
fn fixtureBodies() [2]Body {
    return .{ .{ .absolute = path(false), .source = .disk, .text = "foo A" }, .{ .absolute = path(true), .source = .disk, .text = "foo B" } };
}
fn ownedProbe(a: std.mem.Allocator) !void {
    var spec = try specification(a, "bar");
    defer spec.deinit(a);
    const cancelled = std.atomic.Value(bool).init(false);
    var prepared = try Prepared.prepare(a, &spec, &fixtureBodies(), 10, 10, &cancelled);
    defer prepared.deinit(a);
    try testing.expectEqual(@as(usize, 2), prepared.effective);
    try testing.expectEqualStrings("bar A", prepared.items.items[0].plan.after);
    try testing.expectEqualStrings("bar B", prepared.items.items[1].plan.after);
    try testing.expectEqualStrings("bar", prepared.items.items[1].changes[0].text);
    for (spec.targets.items) |target| try testing.expectEqual(batch.Outcome.pending, target.outcome);
}
test "RPBP1 전체 준비는 모든 대상의 독립 Plan과 편집을 보존한다" {
    try ownedProbe(testing.allocator);
}
test "RPBP2 모든 준비 할당 실패는 앞 파일의 Plan까지 해제한다" {
    try testing.checkAllAllocationFailures(testing.allocator, ownedProbe, .{});
}
test "RPBP3 마지막 파일 원문 불일치는 부분 준비를 반환하지 않는다" {
    var spec = try specification(testing.allocator, "bar");
    defer spec.deinit(testing.allocator);
    var input = fixtureBodies();
    input[1].text = "xxx B";
    const cancelled = std.atomic.Value(bool).init(false);
    try testing.expectError(error.StaleMatch, Prepared.prepare(testing.allocator, &spec, &input, 10, 10, &cancelled));
    try testing.expectEqualStrings("foo A", input[0].text);
    for (spec.targets.items) |target| try testing.expectEqual(batch.Outcome.pending, target.outcome);
}
test "RPBP4 대상 순서 신원 총량 취소를 편집 전에 거절한다" {
    var spec = try specification(testing.allocator, "bar");
    defer spec.deinit(testing.allocator);
    const cancelled = std.atomic.Value(bool).init(false);
    var input = fixtureBodies();
    std.mem.swap(Body, &input[0], &input[1]);
    try testing.expectError(error.StaleTargets, Prepared.prepare(testing.allocator, &spec, &input, 10, 10, &cancelled));
    input = fixtureBodies();
    try testing.expectError(error.StaleTargets, Prepared.prepare(testing.allocator, &spec, input[0..1], 10, 10, &cancelled));
    try testing.expectError(error.TooLarge, Prepared.prepare(testing.allocator, &spec, &input, 10, 4, &cancelled));
    try testing.expectError(error.TooLarge, Prepared.prepare(testing.allocator, &spec, &input, 9, 10, &cancelled));
    input[1].source = .{ .model = .{ .document = .{ .owner = 1, .slot = 0, .generation = 1 }, .revision = 1, .composition = 0 } };
    try testing.expectError(error.StaleTargets, Prepared.prepare(testing.allocator, &spec, &input, 10, 10, &cancelled));
    const stopped = std.atomic.Value(bool).init(true);
    try testing.expectError(error.Cancelled, Prepared.prepare(testing.allocator, &spec, &fixtureBodies(), 10, 10, &stopped));
}
test "RPBP5 같은 문자열 치환은 유효 편집과 Undo 대상으로 세지 않는다" {
    var spec = try specification(testing.allocator, "foo");
    defer spec.deinit(testing.allocator);
    const cancelled = std.atomic.Value(bool).init(false);
    var prepared = try Prepared.prepare(testing.allocator, &spec, &fixtureBodies(), 10, 10, &cancelled);
    defer prepared.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), prepared.effective);
    for (prepared.items.items) |item| try testing.expectEqual(@as(usize, 0), item.changes.len);
}
