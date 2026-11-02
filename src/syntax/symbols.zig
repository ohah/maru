//! 고정 머리줄에 필요한 조상과 파일 전체의 심볼 존재 여부를 서로 구분한다.
//! 전체 목록을 매번 만들지 않고, 편집된 이전 트리와 현재 트리의 변경 범위에서만 개수를 고친다.
const std = @import("std");
const c = @import("tree_sitter_c");
const change_ranges = @import("changes.zig");

extern var ts_current_free: *const fn (?*anyopaque) callconv(.c) void;

pub const Work = struct {
    ancestor_nodes: u64 = 0,
    summary_nodes: u64 = 0,
    rebuild_nodes: u64 = 0,
    reused_changes: u64 = 0,
    compared_changes: u64 = 0,
};

const NodeContext = struct {
    pub fn hash(_: NodeContext, node: c.TSNode) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&node.id));
    }
    pub fn eql(_: NodeContext, a: c.TSNode, b: c.TSNode) bool {
        return c.ts_node_eq(a, b);
    }
};
const Nodes = std.HashMapUnmanaged(c.TSNode, void, NodeContext, 80);
const NeverStop = struct {
    pub fn isRequested(_: @This()) bool {
        return false;
    }
};

/// 이전 분류의 트리를 참조 계수 사본으로 보존한다. 편집은 이 사본에도 같은 좌표 변환을 적용한다.
/// 노드 종류와 이름 유무는 옛 분류 그대로이므로 새 트리와 다른 범위의 개수만 빼고 더할 수 있다.
pub const Summary = struct {
    tree: ?*c.TSTree = null,
    generation: u64 = std.math.maxInt(u64),
    count: usize = 0,
    edited: ?struct { lo: u32, hi: u32 } = null,
    edits: u64 = 0,

    /// 현재 집계만 새 뷰의 트리로 옮긴다. 편집 중인 과거 요약은 현재 트리를 설명하지 못한다.
    pub fn copyReady(self: *const Summary, current: *c.TSTree, generation: u64) ?Summary {
        if (self.tree == null or self.generation != generation or self.edits != 0 or self.edited != null) return null;
        // 수신 provider의 트리와도 참조를 분리해야 다음 편집이 요약에 두 번 적용되지 않는다.
        const tree = c.ts_tree_copy(current) orelse return null;
        return .{ .tree = tree, .generation = generation, .count = self.count };
    }

    pub fn invalidate(self: *Summary) void {
        if (self.tree) |tree| c.ts_tree_delete(tree);
        self.* = .{};
    }

    pub fn edit(self: *Summary, e: *const c.TSInputEdit) void {
        self.edits +|= 1;
        if (self.tree) |tree| c.ts_tree_edit(tree, e);
        // 구조가 같은 선언을 통째로 지우면 changed_ranges가 비어도 옛 선언을 빼야 한다.
        // 여러 편집의 좌표를 마지막 문서 축으로 옮긴 뒤 합집합의 경계를 보존한다.
        const previous = self.edited;
        const lo = if (previous) |r| @min(r.lo, e.start_byte) else e.start_byte;
        const hi = if (previous) |r| blk: {
            const shifted = if (r.hi <= e.start_byte) r.hi else if (r.hi >= e.old_end_byte) r.hi - e.old_end_byte + e.new_end_byte else e.new_end_byte;
            break :blk @max(shifted, e.new_end_byte);
        } else e.new_end_byte;
        self.edited = .{ .lo = lo, .hi = hi };
    }

    pub fn hasSymbols(self: *Summary, allocator: std.mem.Allocator, current: ?*c.TSTree, generation: u64, supported: bool, adapter: anytype, work: *Work, changes: ?change_ranges.Batch) error{OutOfMemory}!bool {
        return self.hasSymbolsCancellable(allocator, current, generation, supported, adapter, work, changes, NeverStop{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Cancelled => unreachable,
        };
    }

    /// 워커의 준비도 기존 증분 집계를 사용한다. 중간 취소 때는 새 판을 발행하지 않는다.
    pub fn hasSymbolsCancellable(self: *Summary, allocator: std.mem.Allocator, current: ?*c.TSTree, generation: u64, supported: bool, adapter: anytype, work: *Work, changes: ?change_ranges.Batch, stop: anytype) error{ OutOfMemory, Cancelled }!bool {
        if (stop.isRequested()) return error.Cancelled;
        const tree = current orelse {
            self.invalidate();
            return false;
        };
        if (!supported) {
            self.invalidate();
            return false;
        }
        if (self.tree != null and self.generation == generation) return self.count != 0;
        var count: usize = 0;
        if (self.tree) |previous| {
            var len: u32 = 0;
            // Summary는 이 Provider 안에서만 산다. 자기 이전 트리에 편집 하나를 모두 받은 때만 빌린다.
            const shared = if (changes) |value| value.borrow(self.generation, generation, self.edits) else null;
            const ranges = if (shared != null) null else c.ts_tree_get_changed_ranges(previous, tree, &len);
            defer if (ranges != null) ts_current_free(@ptrCast(ranges));
            if (shared != null) work.reused_changes +|= 1 else work.compared_changes +|= 1;
            var before: Nodes = .empty;
            defer before.deinit(allocator);
            var after: Nodes = .empty;
            defer after.deinit(allocator);
            const range_count: usize = if (shared) |items| items.len else len;
            for (0..range_count) |i| {
                const lo = if (shared) |items| items[i].lo else ranges[i].start_byte;
                const hi = if (shared) |items| items[i].hi else ranges[i].end_byte;
                try touched(allocator, previous, lo, hi, adapter, work, &before, stop);
                try touched(allocator, tree, lo, hi, adapter, work, &after, stop);
            }
            if (self.edited) |r| {
                try touched(allocator, previous, r.lo, r.hi, adapter, work, &before, stop);
                try touched(allocator, tree, r.lo, r.hi, adapter, work, &after, stop);
            }
            // 이전 집계와 맞지 않으면 다시 센다. 정상 편집 판정자는 재구축이 없다는 것도 확인한다.
            count = if (before.count() <= self.count) self.count - before.count() + after.count() else try fullCount(tree, adapter, work, stop);
        } else count = try fullCount(tree, adapter, work, stop);
        if (stop.isRequested()) return error.Cancelled;
        // 새 참조를 확보한 뒤 옛 참조를 놓아 실패 시 기존 집계를 보존한다.
        const next = c.ts_tree_copy(tree) orelse return error.OutOfMemory;
        if (self.tree) |previous| c.ts_tree_delete(previous);
        self.tree = next;
        self.count = count;
        self.generation = generation;
        self.edited = null;
        self.edits = 0;
        return count != 0;
    }
};

fn fullCount(tree: *c.TSTree, adapter: anytype, work: *Work, stop: anytype) error{Cancelled}!usize {
    var cursor = c.ts_tree_cursor_new(c.ts_tree_root_node(tree));
    defer c.ts_tree_cursor_delete(&cursor);
    var count: usize = 0;
    while (true) {
        if (stop.isRequested()) return error.Cancelled;
        work.rebuild_nodes +|= 1;
        if (adapter.isSymbol(c.ts_tree_cursor_current_node(&cursor))) count += 1;
        if (c.ts_tree_cursor_goto_first_child(&cursor)) continue;
        while (true) {
            if (stop.isRequested()) return error.Cancelled;
            if (c.ts_tree_cursor_goto_next_sibling(&cursor)) break;
            if (!c.ts_tree_cursor_goto_parent(&cursor)) return count;
        }
    }
}

/// 경계에 닿는 0폭 노드도 포함한다. 삭제된 옛 선언은 편집 후 같은 byte로 접히기 때문이다.
/// 자식 위치 검색으로 앞의 형제를 건너뛰며, 재귀 대신 커서로 문서 깊이와 호출 스택을 분리한다.
fn touched(allocator: std.mem.Allocator, tree: *c.TSTree, lo: u32, hi: u32, adapter: anytype, work: *Work, out: *Nodes, stop: anytype) error{ OutOfMemory, Cancelled }!void {
    var cursor = c.ts_tree_cursor_new(c.ts_tree_root_node(tree));
    defer c.ts_tree_cursor_delete(&cursor);
    while (true) {
        if (stop.isRequested()) return error.Cancelled;
        const node = c.ts_tree_cursor_current_node(&cursor);
        work.summary_nodes +|= 1;
        if (c.ts_node_end_byte(node) >= lo and c.ts_node_start_byte(node) <= hi) {
            if (adapter.isSymbol(node)) try out.put(allocator, node, {});
            const child = if (lo == 0) c.ts_tree_cursor_goto_first_child(&cursor) else c.ts_tree_cursor_goto_first_child_for_byte(&cursor, lo - 1) >= 0;
            if (child) continue;
        }
        while (true) {
            if (stop.isRequested()) return error.Cancelled;
            if (c.ts_tree_cursor_goto_next_sibling(&cursor)) {
                if (c.ts_node_start_byte(c.ts_tree_cursor_current_node(&cursor)) <= hi) break;
            }
            if (!c.ts_tree_cursor_goto_parent(&cursor)) return;
        }
    }
}

/// 각 줄 끝에서 부모를 따라간다. Dart의 형제 시그니처/본문도 같은 분류로 보완한다.
pub fn ancestors(allocator: std.mem.Allocator, tree: *c.TSTree, offsets: []const u32, adapter: anytype, work: *Work, out: anytype) error{OutOfMemory}!void {
    var seen: Nodes = .empty;
    defer seen.deinit(allocator);
    var chain: std.ArrayList(c.TSNode) = .empty;
    defer chain.deinit(allocator);
    var chain_seen: Nodes = .empty;
    defer chain_seen.deinit(allocator);
    const root = c.ts_tree_root_node(tree);
    for (offsets) |offset| {
        chain.clearRetainingCapacity();
        chain_seen.clearRetainingCapacity();
        const at = @min(offset, c.ts_node_end_byte(root));
        var node = c.ts_node_descendant_for_byte_range(root, at, at);
        while (!c.ts_node_is_null(node)) : (node = c.ts_node_parent(node)) {
            work.ancestor_nodes +|= 1;
            if (adapter.inGap(node, at)) |signature| {
                work.ancestor_nodes +|= 1;
                try appendNode(allocator, &chain, &chain_seen, signature);
            }
            if (adapter.symbol(node) != null) try appendNode(allocator, &chain, &chain_seen, node);
            if (adapter.extended(node)) |signature| {
                work.ancestor_nodes +|= 1;
                try appendNode(allocator, &chain, &chain_seen, signature);
            }
        }
        var depth: usize = 0;
        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            node = chain.items[i];
            var symbol = adapter.symbol(node) orelse unreachable;
            symbol.depth = @intCast(@min(depth, @TypeOf(adapter).depth_limit));
            depth += 1;
            const entry = try seen.getOrPut(allocator, node);
            if (!entry.found_existing) try out.append(allocator, symbol);
        }
    }
}

fn appendNode(allocator: std.mem.Allocator, chain: *std.ArrayList(c.TSNode), seen: *Nodes, node: c.TSNode) error{OutOfMemory}!void {
    const entry = try seen.getOrPut(allocator, node);
    if (!entry.found_existing) try chain.append(allocator, node);
}
