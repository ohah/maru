//! 검색 결과를 빌리지 않는 배치 명세. 편집·저장 정책과 문서 포인터는 host가 소유한다.
const std = @import("std");
const request = @import("request.zig");
const event = @import("event.zig");
const query = @import("query.zig");
pub const Selection = struct {
    /// host가 root capability로 해석한 정규화 절대 경로다. 물리 파일 별칭 판정은 여기서 하지 않는다.
    absolute: []const u8,
    root_index: usize,
    source: request.Source,
    ranges: []const event.Range,
};
pub const Outcome = enum { pending, unchanged, applied, saved, save_failed };
pub const Target = struct {
    absolute: []u8,
    root_index: usize,
    source: request.Source,
    ranges: std.ArrayList(event.Range) = .empty,
    outcome: Outcome = .pending,
    save_failure: ?anyerror = null,
    fn deinit(self: *Target, a: std.mem.Allocator) void {
        a.free(self.absolute);
        self.ranges.deinit(a);
    }
};
pub const Specification = struct {
    identity: request.Identity,
    needle: []u8,
    replacement: []u8,
    options: query.Options,
    targets: std.ArrayList(Target) = .empty,
    matches: usize = 0,
    pub fn deinit(self: *Specification, a: std.mem.Allocator) void {
        for (self.targets.items) |*target| target.deinit(a);
        self.targets.deinit(a);
        a.free(self.needle);
        a.free(self.replacement);
        freeGlobs(a, self.options.includes);
        freeGlobs(a, self.options.excludes);
    }
    /// 결과와 입력의 수명을 분리한다. 실패할 때 호출자의 선택이나 기존 명세를 바꾸지 않는다.
    pub fn capture(a: std.mem.Allocator, request_identity: request.Identity, status: request.Status, needle: []const u8, replacement: []const u8, options: query.Options, selections: []const Selection) !Specification {
        if (status != .complete) return error.IncompleteResults;
        if (needle.len == 0 or !std.unicode.utf8ValidateSlice(needle) or !std.unicode.utf8ValidateSlice(replacement)) return error.InvalidInput;
        if (selections.len == 0) return error.NoTargets;
        const owned_needle = try a.dupe(u8, needle);
        errdefer a.free(owned_needle);
        const owned_replacement = try a.dupe(u8, replacement);
        errdefer a.free(owned_replacement);
        const includes = try cloneGlobs(a, options.includes);
        errdefer freeGlobs(a, includes);
        const excludes = try cloneGlobs(a, options.excludes);
        errdefer freeGlobs(a, excludes);
        var self: Specification = .{ .identity = request_identity, .needle = owned_needle, .replacement = owned_replacement, .options = options };
        self.options.includes = includes;
        self.options.excludes = excludes;
        errdefer {
            for (self.targets.items) |*target| target.deinit(a);
            self.targets.deinit(a);
        }
        for (selections) |chosen| {
            if (!std.fs.path.isAbsolute(chosen.absolute) or std.mem.indexOfScalar(u8, chosen.absolute, 0) != null or chosen.ranges.len == 0) return error.InvalidTarget;
            if (chosen.source == .model and chosen.source.model.composition != 0) return error.CompositionPending;
            var selected: ?usize = null;
            for (self.targets.items, 0..) |target, i| {
                const same_path = std.mem.eql(u8, target.absolute, chosen.absolute);
                const same_document = target.source == .model and chosen.source == .model and std.meta.eql(target.source.model.document, chosen.source.model.document);
                if (same_path or same_document) {
                    if (!same_path or !std.meta.eql(target.source, chosen.source)) return error.ConflictingTarget;
                    selected = i;
                    break;
                }
            }
            const index = selected orelse blk: {
                const path = try a.dupe(u8, chosen.absolute);
                errdefer a.free(path);
                try self.targets.append(a, .{ .absolute = path, .root_index = chosen.root_index, .source = chosen.source });
                break :blk self.targets.items.len - 1;
            };
            try self.targets.items[index].ranges.appendSlice(a, chosen.ranges);
        }
        // 처리 순서는 최초 선택 순서다. 범위만 원문 순서로 정렬해 파일/일치 중복을 제거한다.
        for (self.targets.items) |*target| {
            std.mem.sort(event.Range, target.ranges.items, {}, lessRange);
            var count: usize = 0;
            for (target.ranges.items) |range| {
                if (lessPosition(range.end, range.start)) return error.InvalidRange;
                if (count > 0) {
                    const previous = target.ranges.items[count - 1];
                    if (std.meta.eql(previous, range)) continue;
                    if (lessPosition(range.start, previous.end)) return error.OverlappingRanges;
                }
                target.ranges.items[count] = range;
                count += 1;
            }
            target.ranges.items.len = count;
            self.matches = std.math.add(usize, self.matches, count) catch return error.TooManyMatches;
        }
        return self;
    }
};
// Options 안의 glob도 요청 수명에 속한다. 바깥 구조만 복사하면 검색 갱신 후 dangling이 된다.
fn cloneGlobs(a: std.mem.Allocator, globs: []const []const u8) ![]const []const u8 {
    const result = try a.alloc([]const u8, globs.len);
    var n: usize = 0;
    errdefer {
        for (result[0..n]) |glob| a.free(glob);
        a.free(result);
    }
    for (globs) |glob| {
        result[n] = try a.dupe(u8, glob);
        n += 1;
    }
    return result;
}
fn freeGlobs(a: std.mem.Allocator, globs: []const []const u8) void {
    for (globs) |glob| a.free(glob);
    a.free(globs);
}
fn lessPosition(a: event.Position, b: event.Position) bool {
    return a.line < b.line or (a.line == b.line and a.byte < b.byte);
}
fn lessRange(_: void, a: event.Range, b: event.Range) bool {
    return lessPosition(a.start, b.start) or (std.meta.eql(a.start, b.start) and lessPosition(a.end, b.end));
}
const testing = std.testing;
const identity: request.Identity = .{ .request = 1, .root = 2, .models = 3 };
const source: request.Source = .{ .model = .{ .document = .{ .owner = 5, .slot = 0, .generation = 1 }, .revision = 2, .composition = 0 } };
fn fixtureRange(start: u32, end: u32) event.Range {
    return .{ .start = .{ .line = 0, .byte = start }, .end = .{ .line = 0, .byte = end } };
}
fn pathA() []const u8 {
    return if (@import("builtin").os.tag == .windows) "C:\\a.txt" else "/a.txt";
}
fn pathB() []const u8 {
    return if (@import("builtin").os.tag == .windows) "C:\\b.txt" else "/b.txt";
}
fn ownedProbe(a: std.mem.Allocator) !void {
    var needle = [_]u8{ 'f', 'o', 'o' };
    var replacement = [_]u8{ 'b', 'a', 'r' };
    var include = [_]u8{ '*', '.', 'z' };
    var exclude = [_]u8{ '*', '.', 'b' };
    var spans = [_]event.Range{ fixtureRange(4, 7), fixtureRange(0, 3) };
    var spec = try Specification.capture(a, identity, .complete, &needle, &replacement, .{ .includes = &.{&include}, .excludes = &.{&exclude} }, &.{
        .{ .absolute = pathA(), .root_index = 0, .source = source, .ranges = &spans },
        .{ .absolute = pathA(), .root_index = 1, .source = source, .ranges = &.{fixtureRange(0, 3)} },
        .{ .absolute = pathB(), .root_index = 0, .source = .disk, .ranges = &.{fixtureRange(0, 3)} },
    });
    defer spec.deinit(a);
    @memset(&include, 'x');
    @memset(&exclude, 'x');
    @memset(&needle, 'x');
    @memset(&replacement, 'x');
    spans[0] = fixtureRange(99, 100);
    try testing.expectEqualStrings("*.z", spec.options.includes[0]);
    try testing.expectEqualStrings("*.b", spec.options.excludes[0]);
    try testing.expectEqualStrings("foo", spec.needle);
    try testing.expectEqualStrings("bar", spec.replacement);
    try testing.expectEqual(@as(usize, 2), spec.targets.items.len);
    try testing.expectEqual(@as(usize, 3), spec.matches);
    try testing.expectEqualSlices(event.Range, &.{ fixtureRange(0, 3), fixtureRange(4, 7) }, spec.targets.items[0].ranges.items);
    try testing.expectEqualStrings(pathB(), spec.targets.items[1].absolute);
    for (spec.targets.items) |t| try testing.expect(t.outcome == .pending and t.save_failure == null);
}
test "RPB1 명세는 입력 결과와 범위를 독립 소유하고 중복 선택을 한 번만 처리한다" {
    try ownedProbe(testing.allocator);
}
test "RPB2 선택 명세와 결과 슬롯의 모든 할당 실패를 정리한다" {
    try testing.checkAllAllocationFailures(testing.allocator, ownedProbe, .{});
}
test "RPB3 같은 경로의 독립 문서 revision 또는 model disk 충돌을 거절한다" {
    for (0..4) |mode| {
        var other = source;
        if (mode == 0) other.model.document.generation += 1;
        if (mode == 1) other.model.revision += 1;
        if (mode == 2) other = .disk;
        try testing.expectError(error.ConflictingTarget, Specification.capture(testing.allocator, identity, .complete, "foo", "bar", .{}, &.{
            .{ .absolute = pathA(), .root_index = 0, .source = source, .ranges = &.{fixtureRange(0, 3)} },
            .{ .absolute = if (mode == 3) pathB() else pathA(), .root_index = 1, .source = other, .ranges = &.{fixtureRange(0, 3)} },
        }));
    }
}
test "RPB4 불완전 결과 조합 잘못된 범위와 겹치는 범위는 시작 전에 거절한다" {
    for ([_]request.Status{ .running, .partial, .failed, .cancelled }) |status|
        try testing.expectError(error.IncompleteResults, Specification.capture(testing.allocator, identity, status, "foo", "bar", .{}, &.{}));
    var composing = source;
    composing.model.composition = 1;
    try testing.expectError(error.CompositionPending, Specification.capture(testing.allocator, identity, .complete, "foo", "bar", .{}, &.{.{ .absolute = pathA(), .root_index = 0, .source = composing, .ranges = &.{fixtureRange(0, 3)} }}));
    try testing.expectError(error.InvalidRange, Specification.capture(testing.allocator, identity, .complete, "foo", "bar", .{}, &.{.{ .absolute = pathA(), .root_index = 0, .source = source, .ranges = &.{fixtureRange(3, 0)} }}));
    try testing.expectError(error.OverlappingRanges, Specification.capture(testing.allocator, identity, .complete, "foo", "bar", .{}, &.{.{ .absolute = pathA(), .root_index = 0, .source = source, .ranges = &.{ fixtureRange(0, 3), fixtureRange(2, 4) } }}));
}
test "RPB5 빈 매치 중복과 인접 범위는 경계를 확장하지 않는다" {
    var spec = try Specification.capture(testing.allocator, identity, .complete, "^|foo", "bar", .{ .regex = true }, &.{.{ .absolute = pathA(), .root_index = 0, .source = source, .ranges = &.{ fixtureRange(3, 3), fixtureRange(0, 0), fixtureRange(0, 0), fixtureRange(0, 3) } }});
    defer spec.deinit(testing.allocator);
    try testing.expectEqualSlices(event.Range, &.{ fixtureRange(0, 0), fixtureRange(0, 3), fixtureRange(3, 3) }, spec.targets.items[0].ranges.items);
}
