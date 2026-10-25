//! Dynamic OverlayInput projection and key transaction. The snapshot belongs to
//! the key, not a movable find.State slot; no host pointer survives a state swap.
const std = @import("std");
const input = @import("../../inline_text_input.zig");
const Owned = @import("../../inline_text_input_owned.zig").OwnedContext;
const Field = @import("overlay_input.zig").OverlayInput;
pub const Range = input.Range;
pub const Key = enum { enter, backspace, replay, other };
pub const Decision = struct { consumed: bool = false, changed: bool = false, replay: bool = false };

pub const Transaction = struct {
    before: ?Owned = null,
    active: bool = false,
    touched: bool = false,
    rejected: bool = false,
    pub fn begin(self: *Transaction, allocator: std.mem.Allocator, p: *Projection, field: *Field) void {
        self.finish(allocator);
        self.active = true;
        _ = p.sync(allocator, field) orelse {
            self.rejected = true;
            self.touched = true;
            return;
        };
        self.before = p.context.clone(allocator) catch {
            self.rejected = true;
            self.touched = true;
            return;
        };
    }
    pub fn finish(self: *Transaction, allocator: std.mem.Allocator) void {
        if (self.before) |*before| before.deinit(allocator);
        self.* = .{};
    }
};

pub const Projection = struct {
    context: Owned = .{},
    pub fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        self.context.deinit(allocator);
    }
    pub fn invalidate(self: *Projection) void {
        self.context.value.valid = false;
    }
    pub fn current(self: *const Projection, field: *const Field) ?*const input.DynamicContext {
        return if (self.context.value.matches(field.query.items, field.preedit.items)) &self.context.value else null;
    }
    pub fn sync(self: *Projection, allocator: std.mem.Allocator, field: *Field) ?*input.DynamicContext {
        if (self.current(field) == null) {
            self.context.reserve(allocator, field.query.items.len, field.preedit.items.len) catch return null;
            if (!self.context.value.reset(field.query.items, field.preedit.items)) return null;
        }
        return &self.context.value;
    }
    fn prepare(self: *Projection, allocator: std.mem.Allocator, field: *Field, extra: usize) bool {
        const c = &self.context.value;
        const sum = std.math.add(usize, c.len, extra) catch return false;
        const needed = @max(sum, @max(c.base_len, c.committed_len));
        self.context.reserve(allocator, needed, needed) catch return false;
        field.query.ensureTotalCapacity(allocator, needed) catch return false;
        field.preedit.ensureTotalCapacity(allocator, needed) catch return false;
        return true;
    }
    fn reject(tx: ?*Transaction) bool {
        if (tx) |t| t.rejected = true;
        return false;
    }
    fn touched(tx: ?*Transaction) bool {
        if (tx) |t| {
            t.touched = true;
            return t.rejected;
        }
        return false;
    }
    fn preview(self: *Projection, field: *Field) void {
        field.preedit.clearRetainingCapacity();
        field.preedit.appendSliceAssumeCapacity(self.context.value.preedit());
    }
    fn publish(self: *Projection, field: *Field) bool {
        const c = &self.context.value;
        const bytes = c.committed[0..c.committedLength()];
        const changed = !std.mem.eql(u8, field.query.items, bytes);
        field.query.clearRetainingCapacity();
        field.query.appendSliceAssumeCapacity(bytes);
        c.accepted(field.query.items);
        self.preview(field);
        return changed;
    }
    pub fn insert(self: *Projection, allocator: std.mem.Allocator, field: *Field, bytes: []const u8, replacement: ?Range, tx: ?*Transaction) bool {
        if (touched(tx)) return false;
        _ = self.sync(allocator, field) orelse return reject(tx);
        if (!self.prepare(allocator, field, bytes.len) or !self.context.value.insert(bytes, replacement)) return reject(tx);
        self.preview(field);
        if (tx == null) _ = self.publish(field);
        return true;
    }
    pub fn marked(self: *Projection, allocator: std.mem.Allocator, field: *Field, bytes: []const u8, selected: Range, replacement: ?Range, tx: ?*Transaction) bool {
        if (touched(tx)) return false;
        _ = self.sync(allocator, field) orelse return reject(tx);
        if (!self.prepare(allocator, field, bytes.len)) return reject(tx);
        const c = &self.context.value;
        const suffix: ?usize = if (bytes.len == 0) if (c.marked) |mark| c.len - mark.end else null else null;
        if (!c.setMarked(bytes, selected, replacement)) return reject(tx);
        if (suffix) |length| {
            const pending = c.pending;
            const n = c.committed_len;
            @memcpy(c.scratch[0..n], c.committed[0..n]);
            _ = c.reset(c.scratch[0..n], "");
            const at = n - @min(n, length);
            c.selected = .{ .start = at, .end = at };
            c.pending = pending;
        }
        self.preview(field);
        return true;
    }
    pub fn commitAll(self: *Projection, allocator: std.mem.Allocator, field: *Field) ?bool {
        _ = self.sync(allocator, field) orelse return null;
        if (!self.prepare(allocator, field, 0) or !self.context.value.admitMarked()) return null;
        return self.publish(field);
    }
    pub fn deleteBackward(self: *Projection, allocator: std.mem.Allocator, field: *Field) bool {
        _ = self.sync(allocator, field) orelse return false;
        if (!self.prepare(allocator, field, 0) or !self.context.value.deleteBackward()) return false;
        return self.publish(field);
    }
    pub fn rollback(self: *Projection, allocator: std.mem.Allocator, field: *Field, tx: *Transaction) void {
        if (tx.before) |before| {
            self.context.deinit(allocator);
            self.context = before;
            tx.before = null;
            const c = &self.context.value;
            field.query.clearRetainingCapacity();
            field.query.appendSliceAssumeCapacity(c.base[0..c.base_len]);
            self.preview(field);
        }
    }
    pub fn finishKey(self: *Projection, allocator: std.mem.Allocator, field: *Field, tx: *Transaction, key: ?Key, deleted: bool) Decision {
        if (tx.rejected) {
            self.rollback(allocator, field, tx);
            return .{ .consumed = true };
        }
        if (self.context.value.pending) {
            if (deleted) self.context.value.cancelInsertedScalar();
            const changed = self.publish(field);
            return .{ .consumed = true, .changed = changed, .replay = key == .replay };
        }
        if (tx.touched) return .{ .consumed = true };
        const event = key orelse return .{ .consumed = true };
        if (self.context.value.preedit().len > 0 and event == .enter) return .{ .consumed = true };
        if (event == .backspace and deleted) return .{ .consumed = true, .changed = self.deleteBackward(allocator, field) };
        return .{};
    }
};

test "find input IME retains long UTF16 query suffix and commit boundary" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    var p: Projection = .{};
    defer p.deinit(a);
    var tx: Transaction = .{};
    defer tx.finish(a);
    var long: [1200]u8 = undefined;
    @memset(&long, 'x');
    try field.query.appendSlice(a, &long);
    try field.query.appendSlice(a, "😀한z");
    tx.begin(a, &p, &field);
    try std.testing.expect(p.marked(a, &field, "韓", .{ .location = 1, .length = 0 }, .{ .location = 1202, .length = 1 }, &tx));
    try std.testing.expectEqualStrings("😀한z", field.query.items[1200..]);
    try std.testing.expectEqualStrings("😀韓z", p.context.value.text()[1200..]);
    try std.testing.expect(p.insert(a, &field, "韓", null, &tx));
    const result = p.finishKey(a, &field, &tx, .enter, false);
    try std.testing.expect(result.consumed and result.changed and !result.replay);
    try std.testing.expectEqualStrings("😀韓z", field.query.items[1200..]);
}

test "find input IME failed callback rolls back the whole key" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    try field.query.appendSlice(a, "old");
    var p: Projection = .{};
    defer p.deinit(a);
    var tx: Transaction = .{};
    defer tx.finish(a);
    tx.begin(a, &p, &field);
    try std.testing.expect(p.insert(a, &field, "x", null, &tx));
    try std.testing.expect(!p.marked(a, &field, "한", .{ .location = 99, .length = 0 }, null, &tx));
    try std.testing.expect(p.finishKey(a, &field, &tx, .enter, false).consumed);
    try std.testing.expectEqualStrings("old", field.query.items);
    try std.testing.expectEqualStrings("old", p.context.value.text());
}

test "find input IME all allocation sites release deep snapshot" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var field: Field = .{};
            defer field.deinit(allocator);
            try field.query.appendSlice(allocator, "keep😀tail");
            var p: Projection = .{};
            defer p.deinit(allocator);
            var tx: Transaction = .{};
            defer tx.finish(allocator);
            tx.begin(allocator, &p, &field);
            if (tx.rejected) return error.OutOfMemory;
            if (!p.marked(allocator, &field, "한", .{ .location = 1, .length = 0 }, .{ .location = 4, .length = 2 }, &tx)) return error.OutOfMemory;
            if (!p.insert(allocator, &field, "韓", null, &tx)) return error.OutOfMemory;
            const result = p.finishKey(allocator, &field, &tx, .enter, false);
            try std.testing.expect(result.changed and result.consumed);
            try std.testing.expectEqualStrings("keep韓tail", field.query.items);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}

test "find input IME cancellation preserves canonical query and navigation signal" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    try field.query.appendSlice(a, "한 tail");
    var p: Projection = .{};
    defer p.deinit(a);
    var tx: Transaction = .{};
    defer tx.finish(a);
    tx.begin(a, &p, &field);
    try std.testing.expect(p.marked(a, &field, "韓", .{ .location = 1, .length = 0 }, .{ .location = 0, .length = 1 }, &tx));
    try std.testing.expect(p.marked(a, &field, "", .{ .location = 0, .length = 0 }, null, &tx));
    const result = p.finishKey(a, &field, &tx, null, false);
    try std.testing.expect(result.consumed and !result.changed);
    try std.testing.expectEqualStrings("한 tail", field.query.items);
    try std.testing.expectEqualStrings("한 tail", p.context.value.text());
}

test "find input IME NFD is preserved verbatim" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    var p: Projection = .{};
    defer p.deinit(a);
    try std.testing.expect(p.insert(a, &field, "한", null, null));
    try std.testing.expectEqualStrings("한", field.query.items);
}

test "find input IME standalone Enter remains an action" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    var p: Projection = .{};
    defer p.deinit(a);
    var tx: Transaction = .{};
    defer tx.finish(a);
    tx.begin(a, &p, &field);
    try std.testing.expect(!p.finishKey(a, &field, &tx, .enter, false).consumed);
}

test "find input IME candidate Enter without callback stays consumed" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    try field.preedit.appendSlice(a, "한");
    var p: Projection = .{};
    defer p.deinit(a);
    var tx: Transaction = .{};
    defer tx.finish(a);
    tx.begin(a, &p, &field);
    try std.testing.expect(p.finishKey(a, &field, &tx, .enter, false).consumed);
    try std.testing.expectEqualStrings("한", field.preedit.items);
}

test "find input IME permitted navigation replays after publication" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    var p: Projection = .{};
    defer p.deinit(a);
    var tx: Transaction = .{};
    defer tx.finish(a);
    tx.begin(a, &p, &field);
    try std.testing.expect(p.insert(a, &field, "한", null, &tx));
    const result = p.finishKey(a, &field, &tx, .replay, false);
    try std.testing.expect(result.consumed and result.changed and result.replay);
}

test "find input IME snapshot survives field disposal" {
    const a = std.testing.allocator;
    var field: Field = .{};
    try field.query.appendSlice(a, "old");
    var p: Projection = .{};
    var tx: Transaction = .{};
    defer tx.finish(a);
    tx.begin(a, &p, &field);
    field.deinit(a);
    p.deinit(a);
    try std.testing.expectEqualStrings("old", tx.before.?.value.text());
}

test "find input IME query and replacement have independent composition" {
    const a = std.testing.allocator;
    var fields: [2]Field = .{ .{}, .{} };
    var models: [2]Projection = .{ .{}, .{} };
    defer for (&fields, &models) |*f, *p| {
        f.deinit(a);
        p.deinit(a);
    };
    for (&fields, &models, [_][]const u8{ "한", "字" }) |*f, *p, bytes| {
        try std.testing.expect(p.marked(a, f, bytes, .{ .location = 1, .length = 0 }, null, null));
    }
    try std.testing.expect(models[0].commitAll(a, &fields[0]).?);
    try std.testing.expectEqualStrings("한", fields[0].query.items);
    try std.testing.expectEqualStrings("", fields[1].query.items);
    try std.testing.expectEqualStrings("字", fields[1].preedit.items);
}

test "find input IME rejects surrogate half without editing" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    try field.query.appendSlice(a, "😀tail");
    var p: Projection = .{};
    defer p.deinit(a);
    var tx: Transaction = .{};
    defer tx.finish(a);
    tx.begin(a, &p, &field);
    try std.testing.expect(!p.insert(a, &field, "x", .{ .location = 1, .length = 0 }, &tx));
    _ = p.finishKey(a, &field, &tx, .enter, false);
    try std.testing.expectEqualStrings("😀tail", field.query.items);
}

test "find input IME external text invalidates borrowed context" {
    const a = std.testing.allocator;
    var field: Field = .{};
    defer field.deinit(a);
    var p: Projection = .{};
    defer p.deinit(a);
    _ = p.sync(a, &field).?;
    try field.query.appendSlice(a, "external");
    try std.testing.expect(p.current(&field) == null);
    try std.testing.expectEqualStrings("external", p.sync(a, &field).?.text());
}
