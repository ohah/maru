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
    depth: u16 = 0,
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
        var hidden_below: ?u16 = null;
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
