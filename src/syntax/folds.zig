//! 구문 접힘 후보의 증분 캐시. 소유자가 allocator와 함께 해제하며 조회의 allocator를 보관하지 않는다.
//! 실제 편집 범위와 tree-sitter의 구조 변경 범위를 함께 사용한다. 실패한 캐시는 폐기해 다음 조회가 재구축한다.
const std = @import("std");
const c = @import("tree_sitter_c");
extern var ts_current_free: *const fn (?*anyopaque) callconv(.c) void;
pub const Span = struct { start_row: u32, end_row: u32 };
const change_ranges = @import("changes.zig");
pub const Change = change_ranges.Range;
pub const Changes = change_ranges.Batch;
const NeverStop = struct {
    pub fn isRequested(_: @This()) bool {
        return false;
    }
};

pub fn hasKind(kinds: []const []const u8, raw: [*c]const u8) bool {
    const name = std.mem.span(raw);
    for (kinds) |kind| if (std.mem.eql(u8, kind, name)) return true;
    return false;
}
pub const Cache = struct {
    records: std.ArrayList(Record) = .empty,
    tree: ?*c.TSTree = null,
    dirty: ?struct { lo: u32, hi: u32 } = null,
    synced_gen: u64 = 0,
    edits: u64 = 0,
    parser: ?*c.TSParser = null,
    nodes: u64 = 0,
    scanned_records: u64 = 0,
    reused_changes: u64 = 0,
    compared_changes: u64 = 0,
    const Record = struct { lo: u32, hi: u32 };
    /// 처리하지 않은 편집이 없는 byte 후보만 새 뷰의 parser·세대에 묶는다.
    pub fn copyMatched(self: *const Cache, a: std.mem.Allocator, source_parser: *c.TSParser, source_gen: u64, target_parser: *c.TSParser, target_gen: u64) error{OutOfMemory}!?Cache {
        var result: Cache = .{};
        errdefer result.deinit(a);
        if (!try self.copyMatchedInto(a, source_parser, source_gen, target_parser, target_gen, &result)) return null;
        return result;
    }
    /// 기존 버퍼를 재사용하되 source와 대상의 native 참조는 분리한다. 실패는 대상을 바꾸지 않는다.
    pub fn copyMatchedInto(self: *const Cache, a: std.mem.Allocator, source_parser: *c.TSParser, source_gen: u64, target_parser: *c.TSParser, target_gen: u64, target: *Cache) error{OutOfMemory}!bool {
        std.debug.assert(self != target);
        if (self.tree == null or self.parser != source_parser or self.synced_gen != source_gen or self.edits != 0 or self.dirty != null) return false;
        const tree = c.ts_tree_copy(self.tree.?) orelse return error.OutOfMemory;
        errdefer c.ts_tree_delete(tree);
        try target.records.ensureTotalCapacity(a, self.records.items.len);
        if (target.tree) |old| c.ts_tree_delete(old);
        target.records.clearRetainingCapacity();
        target.records.appendSliceAssumeCapacity(self.records.items);
        target.tree = tree;
        target.synced_gen = target_gen;
        target.parser = target_parser;
        target.dirty = null;
        target.edits = 0;
        return true;
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
        if (self.tree) |t| c.ts_tree_delete(t);
        self.* = .{};
    }
    pub fn invalidate(self: *Cache) void {
        if (self.tree) |tree| c.ts_tree_delete(tree);
        self.tree = null;
        self.records.clearRetainingCapacity();
        self.dirty = null;
        self.edits = 0;
    }
    pub fn edit(self: *Cache, raw: anytype) void {
        // 목록이 없으면 다음 조회가 현재 트리 전체에서 시작한다. 편집 이력을 잡아 둘 필요가 없다.
        if (self.tree == null) return;
        const value: c.TSInputEdit = .{ .start_byte = raw.start_byte, .old_end_byte = raw.old_end_byte, .new_end_byte = raw.new_end_byte, .start_point = .{ .row = raw.start_point.row, .column = raw.start_point.column }, .old_end_point = .{ .row = raw.old_end_point.row, .column = raw.old_end_point.column }, .new_end_point = .{ .row = raw.new_end_point.row, .column = raw.new_end_point.column } };
        const e = &value;
        self.edits +|= 1;
        if (self.tree) |t| c.ts_tree_edit(t, e);
        var n: usize = 0;
        for (self.records.items) |r| {
            self.scanned_records +|= 1;
            if (r.hi >= e.start_byte and r.lo <= e.old_end_byte) continue;
            var next = r;
            if (r.lo > e.old_end_byte) {
                next.lo = r.lo - e.old_end_byte + e.new_end_byte;
                next.hi = r.hi - e.old_end_byte + e.new_end_byte;
            }
            self.records.items[n] = next;
            n += 1;
        }
        self.records.items.len = n;
        const lo = if (self.dirty) |r| @min(r.lo, e.start_byte) else e.start_byte;
        const hi = if (self.dirty) |r| @max(e.new_end_byte, if (r.hi <= e.start_byte) r.hi else if (r.hi >= e.old_end_byte) r.hi - e.old_end_byte + e.new_end_byte else e.new_end_byte) else e.new_end_byte;
        self.dirty = .{ .lo = lo, .hi = hi };
    }
    fn candidate(kinds: []const []const u8, node: c.TSNode) ?Record {
        if (!hasKind(kinds, c.ts_node_type(node))) return null;
        // 현재 노드의 여러 줄 여부만 거른다. 후보 행을 저장하거나 옛 행을 이동시키지는 않는다.
        const start = c.ts_node_start_point(node);
        const end = c.ts_node_end_point(node);
        const last = end.row - @as(u32, if (end.column == 0 and end.row > start.row) 1 else 0);
        if (last <= start.row) return null;
        return .{ .lo = c.ts_node_start_byte(node), .hi = c.ts_node_end_byte(node) };
    }
    // 행 좌표는 편집 통지의 근사치로 밀지 않고 현재 문서가 소유한 줄 인덱스에서 구한다.
    fn point(lines: anytype, offset: u32) c.TSPoint {
        var lo: usize = 0;
        var hi: usize = lines.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (lines[mid].start <= offset) lo = mid + 1 else hi = mid;
        }
        const row = lo -| 1;
        return pointAtRow(lines, offset, row);
    }
    fn pointAtRow(lines: anytype, offset: u32, row: usize) c.TSPoint {
        return .{ .row = @intCast(row), .column = @intCast(offset - lines[row].start) };
    }
    const PointLookup = struct { value: c.TSPoint, linear_steps: u8 };
    // 같은 조회 안의 근처 줄만 최대 여덟 칸 확인한다. 큰 이동이나 역방향은 기존 이진 탐색을 쓴다.
    // 줄 번호를 편집 너머로 보관하지 않으며, 중첩 범위의 끝이 뒤로 가도 문서 전체를 다시 걷지 않는다.
    fn pointNear(lines: anytype, offset: u32, hint: *usize) PointLookup {
        var row = @min(hint.*, lines.len - 1);
        var steps: u8 = 0;
        if (lines[row].start <= offset) {
            while (steps < 8 and row + 1 < lines.len and lines[row + 1].start <= offset) : (steps += 1) row += 1;
            if (row + 1 == lines.len or lines[row + 1].start > offset) {
                hint.* = row;
                return .{ .value = pointAtRow(lines, offset, row), .linear_steps = steps };
            }
        }
        const value = point(lines, offset);
        hint.* = value.row;
        return .{ .value = value, .linear_steps = steps };
    }
    fn visit(self: *Cache, current: *c.TSTree, kinds: []const []const u8, a: std.mem.Allocator, lo: u32, hi: u32, full: bool, stop: anytype) !void {
        var cur = c.ts_tree_cursor_new(c.ts_tree_root_node(current));
        defer c.ts_tree_cursor_delete(&cur);
        while (true) {
            if (stop.isRequested()) return error.Cancelled;
            const node = c.ts_tree_cursor_current_node(&cur);
            self.nodes +|= 1;
            if (full or (c.ts_node_start_byte(node) <= hi and c.ts_node_end_byte(node) >= lo)) {
                if (candidate(kinds, node)) |r| try self.records.append(a, r);
                if (if (full or lo == 0) c.ts_tree_cursor_goto_first_child(&cur) else c.ts_tree_cursor_goto_first_child_for_byte(&cur, lo - 1) >= 0) continue;
            }
            while (true) {
                if (stop.isRequested()) return error.Cancelled;
                if (c.ts_tree_cursor_goto_next_sibling(&cur)) {
                    if (full or c.ts_node_start_byte(c.ts_tree_cursor_current_node(&cur)) <= hi) break;
                }
                if (!c.ts_tree_cursor_goto_parent(&cur)) return;
            }
        }
    }
    fn orderLess(_: void, x: Record, y: Record) bool {
        return if (x.lo != y.lo) x.lo < y.lo else x.hi > y.hi;
    }
    // 겹친 후보의 안정적 삭제와 뒤쪽 후보의 같은 좌표 이동은 기존 순서를 보존한다.
    // 여덟 개 이하는 사본 실측에서 이동 비용이 작았던 추가분이다. 결과 개수의 상한은 아니다.
    // 구조 범위가 있거나 추가분이 크면 기존 전체 정렬을 사용한다.
    fn orderRecords(items: []Record, prefix: ?usize) void {
        if (prefix) |n| {
            std.debug.assert(n <= items.len);
            if (items.len - n <= 8) {
                for (items[0..n], 0..) |value, i| {
                    if (i != 0) std.debug.assert(!orderLess({}, value, items[i - 1]));
                }
                for (n..items.len) |i| {
                    const value = items[i];
                    var lo: usize = 0;
                    var hi = i;
                    while (lo < hi) {
                        const mid = lo + (hi - lo) / 2;
                        if (orderLess({}, items[mid], value)) lo = mid + 1 else hi = mid;
                    }
                    std.mem.copyBackwards(Record, items[lo + 1 .. i + 1], items[lo..i]);
                    items[lo] = value;
                }
                return;
            }
        }
        std.mem.sort(Record, items, {}, orderLess);
    }
    /// byte 후보 준비와 행 투영을 분리한다. 워커는 문서/뷰의 줄 배열을 빌리지 않는다.
    /// 취소·OOM 뒤 부분 후보를 현재 판으로 공개하지 않고 다음 조회가 다시 구축한다.
    pub fn prepare(self: *Cache, a: std.mem.Allocator, parser: *c.TSParser, tree: ?*c.TSTree, generation: u64, changes: ?Changes, kinds: []const []const u8, stop: anytype) error{ OutOfMemory, Cancelled }!void {
        if (stop.isRequested()) return error.Cancelled;
        const current = tree orelse {
            self.invalidate();
            return;
        };
        if (self.parser != parser or generation != self.synced_gen +| self.edits) self.invalidate();
        errdefer self.invalidate();
        if (self.tree != null and self.parser == parser and self.synced_gen == generation and self.edits == 0 and self.dirty == null) return;
        var ordered_prefix: ?usize = null;
        if (self.tree) |previous| {
            var count: u32 = 0;
            // 직전 세대의 편집 하나를 모두 받은 경우만 Provider의 불변 범위를 빌린다.
            // 늦은 뷰·범위 넘침·전체 교체는 기존의 두 트리 비교로 되돌아간다.
            const shared: ?[]const Change = if (changes) |value|
                value.borrow(self.synced_gen, generation, self.edits)
            else
                null;
            const ranges = if (shared != null) null else c.ts_tree_get_changed_ranges(previous, current, &count);
            if (shared != null) self.reused_changes +|= 1 else self.compared_changes +|= 1;
            const range_count: usize = if (shared) |items| items.len else count;
            if (range_count == 0) ordered_prefix = self.records.items.len;
            defer if (ranges != null) ts_current_free(@ptrCast(ranges));
            // 추가 범위의 중복은 마지막에 위치로 합친다. 최장 후보가 없어져도 짧은 후보를 보존한다.
            // 변경 범위를 합쳐 큰 간격까지 걷지 않도록 구간마다 따로 순회한다.
            for (0..range_count + 1) |i| {
                const lo = if (i < range_count) (if (shared) |items| items[i].lo else ranges[i].start_byte) else if (self.dirty) |r| r.lo else continue;
                const hi = if (i < range_count) (if (shared) |items| items[i].hi else ranges[i].end_byte) else self.dirty.?.hi;
                var n: usize = 0;
                for (self.records.items) |r| {
                    if (stop.isRequested()) return error.Cancelled;
                    self.scanned_records +|= 1;
                    if (r.lo <= hi and r.hi >= lo) continue;
                    self.records.items[n] = r;
                    n += 1;
                }
                self.records.items.len = n;
                if (range_count == 0) ordered_prefix = n;
                try self.visit(current, kinds, a, lo, hi, false, stop);
            }
        } else {
            self.records.clearRetainingCapacity();
            try self.visit(current, kinds, a, 0, std.math.maxInt(u32), true, stop);
        }
        orderRecords(self.records.items, ordered_prefix);
        var n: usize = 0;
        for (self.records.items) |r| {
            if (n > 0 and std.meta.eql(self.records.items[n - 1], r)) continue;
            self.records.items[n] = r;
            n += 1;
        }
        self.records.items.len = n;
        if (stop.isRequested()) return error.Cancelled;
        const next = c.ts_tree_copy(current) orelse return error.OutOfMemory;
        if (self.tree) |previous| c.ts_tree_delete(previous);
        self.tree = next;
        self.dirty = null;
        self.synced_gen = generation;
        self.edits = 0;
        self.parser = parser;
    }

    pub fn query(self: *Cache, a: std.mem.Allocator, parser: *c.TSParser, tree: ?*c.TSTree, generation: u64, changes: ?Changes, kinds: []const []const u8, lines: anytype, out: *std.ArrayList(Span)) error{OutOfMemory}!void {
        out.clearRetainingCapacity();
        errdefer {
            self.invalidate();
            out.clearRetainingCapacity();
        }
        if (lines.len == 0) {
            self.invalidate();
            return;
        }
        self.prepare(a, parser, tree, generation, changes, kinds, NeverStop{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Cancelled => unreachable,
        };
        if (self.tree == null) return;
        var start_hint: usize = 0;
        var end_hint: usize = 0;
        for (self.records.items) |r| {
            const start = pointNear(lines, r.lo, &start_hint).value;
            const end = pointNear(lines, r.hi, &end_hint).value;
            const ep = end.row - @as(u32, if (end.column == 0 and end.row > start.row) 1 else 0);
            if (ep <= start.row) continue;
            if (out.items.len > 0 and out.items[out.items.len - 1].start_row == start.row) {
                out.items[out.items.len - 1].end_row = @max(out.items[out.items.len - 1].end_row, ep);
            } else try out.append(a, .{ .start_row = start.row, .end_row = ep });
        }
    }
};

const PointLine = struct { start: u32 };

fn expectNearPoint(lines: []const PointLine, offset: u32, hint: *usize) !void {
    var row: usize = 0;
    for (lines, 0..) |line, i| {
        if (line.start > offset) break;
        row = i;
    }
    const lookup = Cache.pointNear(lines, offset, hint);
    try std.testing.expectEqual(@as(u32, @intCast(row)), lookup.value.row);
    try std.testing.expectEqual(offset - lines[row].start, lookup.value.column);
    try std.testing.expectEqual(row, hint.*);
    try std.testing.expect(lookup.linear_steps <= 8);
}

test "fold point hint 한 줄과 범위 밖의 이전 힌트를 안전하게 처리한다" {
    const lines = [_]PointLine{.{ .start = 0 }};
    var hint: usize = std.math.maxInt(usize);
    for ([_]u32{ 0, 1, 100, 0 }) |offset| try expectNearPoint(&lines, offset, &hint);
}

test "fold point hint 줄 경계와 여덟 칸 전진 경계가 이진 탐색과 같다" {
    var lines: [64]PointLine = undefined;
    for (&lines, 0..) |*line, i| line.start = @intCast(i * 4);
    var hint: usize = 0;
    for ([_]u32{ 0, 32, 0, 36, 4, 3, 4, 31, 32, 35, 36, 255, 256 }) |offset| try expectNearPoint(&lines, offset, &hint);
}

test "fold point hint 중첩된 끝 좌표의 역방향과 큰 도약을 제한된 탐색으로 처리한다" {
    var lines: [4096]PointLine = undefined;
    for (&lines, 0..) |*line, i| line.start = @intCast(i * 3);
    var hint: usize = 0;
    for ([_]u32{ 12000, 100, 120, 11500, 101, 11999, 0, 12285 }) |offset| try expectNearPoint(&lines, offset, &hint);
}

test "fold point hint 서로 다른 줄 길이와 같은 좌표 반복을 보존한다" {
    const lines = [_]PointLine{ .{ .start = 0 }, .{ .start = 3 }, .{ .start = 4 }, .{ .start = 8 }, .{ .start = 15 }, .{ .start = 16 }, .{ .start = 20 } };
    var hint: usize = 0;
    for (0..24) |i| {
        try expectNearPoint(&lines, @intCast(i), &hint);
        try expectNearPoint(&lines, @intCast(i), &hint);
    }
    for (0..24) |i| try expectNearPoint(&lines, @intCast(23 - i), &hint);
}

test "fold point hint 무작위 줄 인덱스와 앞뒤 조회를 독립 전수 탐색과 대조한다" {
    var prng = std.Random.DefaultPrng.init(0x504f494e54);
    const random = prng.random();
    var lines: [2048]PointLine = undefined;
    var start: u32 = 0;
    for (&lines) |*line| {
        line.start = start;
        start += 1 + random.uintLessThan(u32, 100);
    }
    var hint: usize = 0;
    var offset: u32 = 0;
    for (0..5000) |i| {
        offset = if (i % 7 == 0) random.uintLessThan(u32, start) else (offset + random.uintLessThan(u32, 100)) % start;
        try expectNearPoint(&lines, offset, &hint);
    }
}

test "fold order 작은 추가분은 동률과 빈 목록에서도 전체 정렬과 같다" {
    // 비교 함수 자체가 뒤집혀도 함께 틀리는 oracle이 되지 않도록 고정 정답도 둔다.
    const golden = [_]Cache.Record{ .{ .lo = 0, .hi = 0 }, .{ .lo = 2, .hi = 4 }, .{ .lo = 5, .hi = 9 }, .{ .lo = 5, .hi = 8 }, .{ .lo = 5, .hi = 8 } };
    const input = [_]Cache.Record{ golden[0], golden[1], golden[3], golden[2], golden[4] };
    for ([_]?usize{ null, 3 }) |prefix| {
        var tied = input;
        Cache.orderRecords(&tied, prefix);
        try std.testing.expectEqualDeep(&golden, &tied);
    }
    var prng = std.Random.DefaultPrng.init(0x12a5bf);
    const random = prng.random();
    var actual: [129]Cache.Record = undefined;
    var expected: [129]Cache.Record = undefined;
    for (0..4096) |_| {
        const n = random.uintLessThan(usize, actual.len + 1);
        const tail = random.uintLessThan(usize, @min(n, 16) + 1);
        const prefix = n - tail;
        for (actual[0..n]) |*value| {
            const lo = random.uintLessThan(u32, 32);
            value.* = .{ .lo = lo, .hi = lo + random.uintLessThan(u32, 32) };
        }
        std.mem.sort(Cache.Record, actual[0..prefix], {}, Cache.orderLess);
        @memcpy(expected[0..n], actual[0..n]);
        std.mem.sort(Cache.Record, expected[0..n], {}, Cache.orderLess);
        Cache.orderRecords(actual[0..n], prefix);
        try std.testing.expectEqualDeep(expected[0..n], actual[0..n]);
    }
}

test "fold order 겹친 후보 삭제와 뒤쪽 좌표 이동 뒤에도 순서를 보존한다" {
    var prng = std.Random.DefaultPrng.init(0x8e91ac);
    const random = prng.random();
    var items: [2048]Cache.Record = undefined;
    var expected: [2048]Cache.Record = undefined;
    var n: usize = 128;
    for (items[0..n], 0..) |*value, i| value.* = .{ .lo = @intCast(i * 8), .hi = @intCast(i * 8 + 6) };
    for (0..200) |round| {
        const start = if (round == 0) 0 else random.uintLessThan(u32, 1024);
        const old_end = if (round == 0) 65535 else start + random.uintLessThan(u32, 32);
        const new_end = if (round == 0) 0 else start + random.uintLessThan(u32, 32);
        var kept: usize = 0;
        for (items[0..n]) |value| {
            if (value.hi >= start and value.lo <= old_end) continue;
            var next = value;
            if (value.lo > old_end) {
                next.lo = value.lo - old_end + new_end;
                next.hi = value.hi - old_end + new_end;
            }
            items[kept] = next;
            kept += 1;
        }
        for (items[0..kept], 0..) |value, i| {
            if (i != 0) try std.testing.expect(!Cache.orderLess({}, value, items[i - 1]));
        }
        const extra = random.uintLessThan(usize, 9);
        for (items[kept .. kept + extra]) |*value| {
            const lo = random.uintLessThan(u32, 2048);
            value.* = .{ .lo = lo, .hi = lo + random.uintLessThan(u32, 64) };
        }
        n = kept + extra;
        @memcpy(expected[0..n], items[0..n]);
        std.mem.sort(Cache.Record, expected[0..n], {}, Cache.orderLess);
        Cache.orderRecords(items[0..n], kept);
        try std.testing.expectEqualDeep(expected[0..n], items[0..n]);
    }
}
