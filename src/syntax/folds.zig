//! 구문 접힘 후보의 증분 캐시. 소유자가 allocator와 함께 해제하며 조회의 allocator를 보관하지 않는다.
//! 실제 편집 범위와 tree-sitter의 구조 변경 범위를 함께 사용한다. 실패한 캐시는 폐기해 다음 조회가 재구축한다.
const std = @import("std");
const c = @import("tree_sitter_c");
extern var ts_current_free: *const fn (?*anyopaque) callconv(.c) void;
pub const Span = struct { start_row: u32, end_row: u32 };

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
    const Record = struct { lo: u32, hi: u32 };
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
        return .{ .row = @intCast(row), .column = @intCast(offset - lines[row].start) };
    }
    fn visit(self: *Cache, current: *c.TSTree, kinds: []const []const u8, a: std.mem.Allocator, lo: u32, hi: u32, full: bool) !void {
        var cur = c.ts_tree_cursor_new(c.ts_tree_root_node(current));
        defer c.ts_tree_cursor_delete(&cur);
        while (true) {
            const node = c.ts_tree_cursor_current_node(&cur);
            self.nodes +|= 1;
            if (full or (c.ts_node_start_byte(node) <= hi and c.ts_node_end_byte(node) >= lo)) {
                if (candidate(kinds, node)) |r| try self.records.append(a, r);
                if (if (full or lo == 0) c.ts_tree_cursor_goto_first_child(&cur) else c.ts_tree_cursor_goto_first_child_for_byte(&cur, lo - 1) >= 0) continue;
            }
            while (true) {
                if (c.ts_tree_cursor_goto_next_sibling(&cur)) {
                    if (full or c.ts_node_start_byte(c.ts_tree_cursor_current_node(&cur)) <= hi) break;
                }
                if (!c.ts_tree_cursor_goto_parent(&cur)) return;
            }
        }
    }
    pub fn query(self: *Cache, a: std.mem.Allocator, parser: *c.TSParser, tree: ?*c.TSTree, generation: u64, kinds: []const []const u8, lines: anytype, out: *std.ArrayList(Span)) error{OutOfMemory}!void {
        out.clearRetainingCapacity();
        const current = tree orelse {
            self.invalidate();
            return;
        };
        // 편집 통지를 놓쳤거나 다른 provider로 바뀌면 이전 좌표를 신뢰하지 않는다.
        if (self.parser != parser or generation != self.synced_gen +| self.edits) self.invalidate();
        errdefer {
            self.invalidate();
            out.clearRetainingCapacity();
        }

        if (lines.len == 0) {
            self.invalidate();
            return;
        }
        if (self.tree) |previous| {
            var count: u32 = 0;
            const ranges = c.ts_tree_get_changed_ranges(previous, current, &count);
            defer if (ranges != null) ts_current_free(@ptrCast(ranges));
            // 추가 범위의 중복은 마지막에 위치로 합친다. 최장 후보가 없어져도 짧은 후보를 보존한다.
            // 변경 범위를 합쳐 큰 간격까지 걷지 않도록 구간마다 따로 순회한다.
            for (0..count + 1) |i| {
                const lo = if (i < count) ranges[i].start_byte else if (self.dirty) |r| r.lo else continue;
                const hi = if (i < count) ranges[i].end_byte else self.dirty.?.hi;
                var n: usize = 0;
                for (self.records.items) |r| {
                    self.scanned_records +|= 1;
                    if (r.lo <= hi and r.hi >= lo) continue;
                    self.records.items[n] = r;
                    n += 1;
                }
                self.records.items.len = n;
                try self.visit(current, kinds, a, lo, hi, false);
            }
        } else {
            self.records.clearRetainingCapacity();
            try self.visit(current, kinds, a, 0, std.math.maxInt(u32), true);
        }
        std.mem.sort(Record, self.records.items, {}, struct {
            fn lt(_: void, x: Record, y: Record) bool {
                if (x.lo != y.lo) return x.lo < y.lo;
                return x.hi > y.hi;
            }
        }.lt);
        var n: usize = 0;
        for (self.records.items) |r| {
            if (n > 0 and std.meta.eql(self.records.items[n - 1], r)) continue;
            self.records.items[n] = r;
            n += 1;
        }
        self.records.items.len = n;
        for (self.records.items) |r| {
            const start = point(lines, r.lo);
            const end = point(lines, r.hi);
            const ep = end.row - @as(u32, if (end.column == 0 and end.row > start.row) 1 else 0);
            if (ep <= start.row) continue;
            if (out.items.len > 0 and out.items[out.items.len - 1].start_row == start.row) {
                out.items[out.items.len - 1].end_row = @max(out.items[out.items.len - 1].end_row, ep);
            } else try out.append(a, .{ .start_row = start.row, .end_row = ep });
        }
        const next = c.ts_tree_copy(current) orelse return error.OutOfMemory;
        if (self.tree) |previous| c.ts_tree_delete(previous);
        self.tree = next;
        self.dirty = null;
        self.synced_gen = generation;
        self.edits = 0;
        self.parser = parser;
    }
};
