// 실측 사본에만 주입한다. 제품 선택 전의 프로토타입이며 동일 allocator를 쓰는 실험 범위다.
pub const FoldProbe = struct {
    pub const mode: u8 = EW2_MODE;
    pub var force: bool = false;
    pub var clock_ns: i64 = 0;
    pub var delay_ns: i64 = 150_000_000;
    records: std.ArrayList(Record) = .empty,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    tree: ?*c.TSTree = null,
    dirty: ?struct { lo: u32, hi: u32 } = null,
    deadline: i64 = 0,
    mapped: bool = false,
    nodes: u64 = 0,
    scanned_records: u64 = 0,
    const Record = struct { lo: u32, hi: u32, start: c.TSPoint, end: c.TSPoint };
    pub fn deinit(self: *FoldProbe) void {
        self.records.deinit(self.allocator);
        if (self.tree) |t| c.ts_tree_delete(t);
        self.* = .{};
    }
    pub fn edit(self: *FoldProbe, e: *const c.TSInputEdit) void {
        self.deadline = clock_ns + delay_ns;
        if (mode != 1) return;
        if (self.tree) |t| c.ts_tree_edit(t, e);
        var n: usize = 0;
        for (self.records.items) |r| {
            self.scanned_records += 1;
            if (r.hi >= e.start_byte and r.lo <= e.old_end_byte) continue;
            var next = r;
            if (r.lo > e.old_end_byte) {
                next.lo = r.lo - e.old_end_byte + e.new_end_byte;
                next.hi = r.hi - e.old_end_byte + e.new_end_byte;
                next.start = movePoint(r.start, e);
                next.end = movePoint(r.end, e);
            }
            self.records.items[n] = next;
            n += 1;
        }
        self.records.items.len = n;
        const lo = if (self.dirty) |r| @min(r.lo, e.start_byte) else e.start_byte;
        const hi = if (self.dirty) |r| @max(e.new_end_byte, if (r.hi <= e.start_byte) r.hi else if (r.hi >= e.old_end_byte) r.hi - e.old_end_byte + e.new_end_byte else e.new_end_byte) else e.new_end_byte;
        self.dirty = .{ .lo = lo, .hi = hi };
    }
    fn movePoint(p: c.TSPoint, e: *const c.TSInputEdit) c.TSPoint {
        return .{ .row = p.row - e.old_end_point.row + e.new_end_point.row, .column = if (p.row == e.old_end_point.row) p.column - e.old_end_point.column + e.new_end_point.column else p.column };
    }
    fn candidate(p: *Provider, node: c.TSNode) ?Record {
        const sp = c.ts_node_start_point(node);
        const ep = c.ts_node_end_point(node);
        const row = ep.row - @as(u32, if (ep.column == 0 and ep.row > sp.row) 1 else 0);
        if (row <= sp.row or !Provider.hasKind(p.slot.fold_kinds, c.ts_node_type(node))) return null;
        return .{ .lo = c.ts_node_start_byte(node), .hi = c.ts_node_end_byte(node), .start = sp, .end = ep };
    }
    fn visit(self: *FoldProbe, p: *Provider, a: std.mem.Allocator, lo: u32, hi: u32, full: bool) !void {
        var cur = c.ts_tree_cursor_new(c.ts_tree_root_node(p.tree.?));
        defer c.ts_tree_cursor_delete(&cur);
        while (true) {
            const node = c.ts_tree_cursor_current_node(&cur);
            self.nodes += 1;
            if (full or (c.ts_node_start_byte(node) <= hi and c.ts_node_end_byte(node) >= lo)) {
                if (candidate(p, node)) |r| try self.records.append(a, r);
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
    pub fn query(self: *FoldProbe, p: *Provider, a: std.mem.Allocator, out: *std.ArrayList(Provider.FoldSpan)) !void {
        self.allocator = a;
        out.clearRetainingCapacity();
        const current = p.tree orelse return;
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
                    self.scanned_records += 1;
                    if (r.lo <= hi and r.hi >= lo) continue;
                    self.records.items[n] = r;
                    n += 1;
                }
                self.records.items.len = n;
                try self.visit(p, a, lo, hi, false);
            }
        } else {
            self.records.clearRetainingCapacity();
            try self.visit(p, a, 0, std.math.maxInt(u32), true);
        }
        std.mem.sort(Record, self.records.items, {}, struct {
            fn lt(_: void, x: Record, y: Record) bool {
                if (x.lo != y.lo) return x.lo < y.lo;
                return x.hi > y.hi;
            }
        }.lt);
        var n: usize = 0;
        for (self.records.items) |r| {
            if (n > 0 and std.meta.eql(self.records.items[n-1], r)) continue;
            self.records.items[n] = r;
            n += 1;
        }
        self.records.items.len = n;
        for (self.records.items) |r| {
            const ep = r.end.row - @as(u32, if (r.end.column == 0 and r.end.row > r.start.row) 1 else 0);
            if (out.items.len > 0 and out.items[out.items.len-1].start_row == r.start.row) {
                out.items[out.items.len-1].end_row = @max(out.items[out.items.len-1].end_row, ep);
            } else try out.append(a, .{ .start_row = r.start.row, .end_row = ep });
        }
        const next = c.ts_tree_copy(current) orelse return error.OutOfMemory;
        if (self.tree) |previous| c.ts_tree_delete(previous);
        self.tree = next;
        self.dirty = null;
    }
};
