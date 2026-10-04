//! 심볼 제공자와 무관한 아웃라인 스냅숏이다. 이름을 소유하므로 문서 편집 뒤에도 빌린 바이트가 남지 않는다.
const std = @import("std");

pub const Symbol = struct {
    label: []const u8,
    start: u32,
    end: u32,
    target: u32,
};

pub const Item = struct {
    symbol: Symbol,
    parent: ?usize = null,
    depth: u32 = 0,
    expandable: bool = false,
    collapsed: bool = false,
};

pub const Model = struct {
    items: std.ArrayList(Item) = .empty,
    visible: std.ArrayList(usize) = .empty,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| allocator.free(item.symbol.label);
        self.items.deinit(allocator);
        self.visible.deinit(allocator);
        self.* = .{};
    }

    /// 준비가 다 끝나기 전에는 기존 스냅숏을 건드리지 않는다. 호출자는 실패 시 옛 동작을 비활성화한다.
    pub fn replace(self: *Model, allocator: std.mem.Allocator, symbols: []const Symbol, document_len: usize) !void {
        var next: Model = .{};
        errdefer next.deinit(allocator);
        try next.items.ensureTotalCapacity(allocator, symbols.len);
        try next.visible.ensureTotalCapacity(allocator, symbols.len);
        for (symbols) |sym| {
            if (sym.start >= sym.end or sym.end > document_len or sym.target < sym.start or
                sym.target >= sym.end or sym.label.len == 0 or !std.unicode.utf8ValidateSlice(sym.label)) continue;
            const label = try allocator.dupe(u8, sym.label);
            // 선언 이름에 줄바꿈·탭이 있어도 목록 한 줄의 경계를 벗어나지 않는다.
            for (label) |*byte| if (byte.* < 0x20 or byte.* == 0x7f) {
                byte.* = ' ';
            };
            var owned = sym;
            owned.label = label;
            next.items.appendAssumeCapacity(.{ .symbol = owned });
        }
        std.mem.sort(Item, next.items.items, {}, struct {
            fn less(_: void, a: Item, b: Item) bool {
                if (a.symbol.start != b.symbol.start) return a.symbol.start < b.symbol.start;
                if (a.symbol.end != b.symbol.end) return a.symbol.end > b.symbol.end;
                return a.symbol.target < b.symbol.target;
            }
        }.less);
        // 정렬 뒤 열린 조상을 따라간다. 겹치지만 포함되지 않는 범위는 거짓 자식으로 만들지 않는다.
        var parent: ?usize = null;
        for (next.items.items, 0..) |*item, index| {
            while (parent) |p| {
                const ancestor = next.items.items[p];
                if (ancestor.symbol.start <= item.symbol.start and ancestor.symbol.end >= item.symbol.end and
                    (ancestor.symbol.start != item.symbol.start or ancestor.symbol.end != item.symbol.end)) break;
                parent = ancestor.parent;
            }
            item.parent = parent;
            if (parent) |p| {
                item.depth = next.items.items[p].depth +| 1;
                next.items.items[p].expandable = true;
            }
            parent = index;
            next.visible.appendAssumeCapacity(index);
        }
        self.deinit(allocator);
        self.* = next;
    }

    pub fn toggle(self: *Model, index: usize) bool {
        if (index >= self.items.items.len or !self.items.items[index].expandable) return false;
        self.items.items[index].collapsed = !self.items.items[index].collapsed;
        self.visible.clearRetainingCapacity();
        var hidden_below: ?u32 = null;
        for (self.items.items, 0..) |item, i| {
            if (hidden_below) |depth| {
                if (item.depth > depth) continue;
                hidden_below = null;
            }
            self.visible.appendAssumeCapacity(i);
            if (item.collapsed) hidden_below = item.depth;
        }
        return true;
    }

    /// 종료 offset은 포함하지 않는다. 접힌 자식 안에 있는 커서는 보이는 가장 가까운 조상으로 표시한다.
    pub fn active(self: *const Model, caret: usize) ?usize {
        var found: ?usize = null;
        for (self.visible.items) |index| {
            const sym = self.items.items[index].symbol;
            if (sym.start <= caret and caret < sym.end) {
                if (found == null or sym.end - sym.start < self.items.items[found.?].symbol.end - self.items.items[found.?].symbol.start)
                    found = index;
            }
        }
        return found;
    }
};

// 범위와 실제 표시 인덱스를 판정한다. 같은 이름 두 개를 클릭해도 서로 다른 위치로 가야 한다.
test "outline hierarchy sorts symbols and preserves nested collapse" {
    var model: Model = .{};
    defer model.deinit(std.testing.allocator);
    try model.replace(std.testing.allocator, &.{
        .{ .label = "same", .start = 20, .end = 40, .target = 21 },
        .{ .label = "Class", .start = 0, .end = 90, .target = 1 },
        .{ .label = "same", .start = 50, .end = 80, .target = 51 },
        .{ .label = "child", .start = 55, .end = 70, .target = 56 },
        .{ .label = "last", .start = 90, .end = 100, .target = 91 },
    }, 100);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, model.visible.items);
    try std.testing.expectEqual(@as(?usize, 3), model.active(60));
    try std.testing.expectEqual(@as(?usize, 4), model.active(90));
    try std.testing.expectEqual(@as(?usize, null), model.active(100));
    try std.testing.expect(model.toggle(2));
    try std.testing.expectEqual(@as(?usize, 2), model.active(60));
    try std.testing.expect(model.toggle(0));
    try std.testing.expectEqualSlices(usize, &.{ 0, 4 }, model.visible.items);
    try std.testing.expect(model.toggle(0));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 4 }, model.visible.items);
    try std.testing.expect(!model.toggle(1));
}

test "outline rejects malformed ranges and keeps crossing symbols as siblings" {
    var model: Model = .{};
    defer model.deinit(std.testing.allocator);
    try model.replace(std.testing.allocator, &.{
        .{ .label = "한글\n이름", .start = 0, .end = 10, .target = 1 },
        .{ .label = "cross", .start = 5, .end = 15, .target = 6 },
        .{ .label = "bad", .start = 2, .end = 1, .target = 2 },
        .{ .label = "past", .start = 3, .end = 22, .target = 3 },
        .{ .label = "target", .start = 3, .end = 6, .target = 6 },
        .{ .label = "\xff", .start = 3, .end = 6, .target = 4 },
    }, 20);
    try std.testing.expectEqual(@as(usize, 2), model.items.items.len);
    try std.testing.expectEqualStrings("한글 이름", model.items.items[0].symbol.label);
    try std.testing.expectEqual(@as(?usize, null), model.items.items[1].parent);
}

fn replaceFailure(allocator: std.mem.Allocator) !void {
    var model: Model = .{};
    defer model.deinit(allocator);
    const first = [_]Symbol{.{ .label = "before", .start = 0, .end = 9, .target = 1 }};
    try model.replace(allocator, &first, 10);
    model.replace(allocator, &.{
        .{ .label = "after", .start = 0, .end = 9, .target = 1 },
        .{ .label = "child", .start = 2, .end = 7, .target = 3 },
    }, 10) catch |err| {
        try std.testing.expectEqualStrings("before", model.items.items[0].symbol.label);
        try std.testing.expectEqualSlices(usize, &.{0}, model.visible.items);
        return err;
    };
}

test "outline replacement allocation failures leave the previous snapshot intact" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, replaceFailure, .{});
}

test "outline 깊은 계층도 접힘에서 자식을 남기지 않는다" {
    const n = 65538;
    const a = std.testing.allocator;
    const symbols = try a.alloc(Symbol, n);
    defer a.free(symbols);
    for (symbols, 0..) |*s, i| s.* = .{ .label = "x", .start = @intCast(i), .end = @intCast(n * 2 - i), .target = @intCast(i) };
    var model: Model = .{};
    defer model.deinit(a);
    try model.replace(a, symbols, n * 2);
    try std.testing.expect(model.toggle(65535));
    try std.testing.expectEqual(@as(usize, 65536), model.visible.items.len);
}

test "outline 섞인 입력과 반복 접힘을 별도 부모 모델과 대조한다" {
    const n = 127;
    var canonical: [n]Symbol = undefined;
    canonical[0] = .{ .label = "same", .start = 0, .end = 1024, .target = 0 };
    for (1..n) |i| {
        const parent = canonical[(i - 1) / 2];
        const middle = parent.start + (parent.end - parent.start) / 2;
        const start = if (i % 2 == 1) parent.start + 1 else middle;
        canonical[i] = .{ .label = "same", .start = start, .end = if (i % 2 == 1) middle else parent.end - 1, .target = start };
    }
    for (0..5) |seed| {
        var random = std.Random.DefaultPrng.init(seed);
        var shuffled = canonical;
        random.random().shuffle(Symbol, &shuffled);
        var model: Model = .{};
        defer model.deinit(std.testing.allocator);
        try model.replace(std.testing.allocator, &shuffled, 1024);
        var model_for_id: [n]usize = undefined;
        var id_for_model: [n]usize = undefined;
        for (model.items.items, 0..) |item, index| {
            for (canonical, 0..) |sym, id| if (sym.start == item.symbol.start) {
                model_for_id[id] = index;
                id_for_model[index] = id;
                break;
            };
        }
        var collapsed = [_]bool{false} ** n;
        for (0..250) |_| {
            const id = random.random().uintLessThan(usize, n);
            const expandable = id * 2 + 1 < n;
            try std.testing.expectEqual(expandable, model.toggle(model_for_id[id]));
            if (expandable) collapsed[id] = !collapsed[id];
            var visible: usize = 0;
            for (model.items.items, 0..) |item, index| {
                const original = id_for_model[index];
                var cursor = original;
                var hidden = false;
                var depth: u32 = 0;
                // 오라클은 범위 정렬이나 모델의 depth를 쓰지 않고 생성한 이진 트리의 부모를 따른다.
                while (cursor != 0) {
                    cursor = (cursor - 1) / 2;
                    hidden = hidden or collapsed[cursor];
                    depth += 1;
                }
                try std.testing.expectEqual(depth, item.depth);
                const parent: ?usize = if (original == 0) null else model_for_id[(original - 1) / 2];
                try std.testing.expectEqual(parent, item.parent);
                if (!hidden) {
                    try std.testing.expect(visible < model.visible.items.len);
                    try std.testing.expectEqual(index, model.visible.items[visible]);
                    visible += 1;
                }
            }
            try std.testing.expectEqual(visible, model.visible.items.len);
        }
    }
}
