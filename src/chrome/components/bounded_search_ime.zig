//! Fixed-storage search transaction shared by callers with distinct capacity and filter policies.
const input = @import("../../inline_text_input.zig");
pub const Range = input.Range;
pub const Result = enum { none, commit, rollback };
pub const Key = enum { enter, backspace, other };
pub const Decision = struct { result: Result = .none, consumed: bool };
pub fn StateWithLimits(comptime query_capacity: usize, comptime marked_capacity: usize) type {
    const ContextType = input.BoundedContext(query_capacity, marked_capacity);
    return struct {
        const Self = @This();
        pub const Context = ContextType;
        context: Context = .{},
        before: ?Context = null,
        in_key: bool = false,
        rejected: bool = false,

        pub fn invalidate(self: *Self) void {
            self.* = .{};
        }
        pub fn sync(self: *Self, query: []const u8, preedit: []const u8) ?*Context {
            if (self.in_key and self.rejected) return null;
            if (!self.context.matches(query, preedit) and !self.context.reset(query, preedit)) return null;
            return &self.context;
        }
        pub fn begin(self: *Self, query: []const u8, preedit: []const u8) void {
            self.finish();
            const context = self.sync(query, preedit) orelse {
                self.in_key = true;
                self.rejected = true;
                return;
            };
            self.before = context.*;
            self.in_key = true;
        }
        pub fn finish(self: *Self) void {
            self.before = null;
            self.in_key = false;
            self.rejected = false;
        }
        pub fn insert(self: *Self, bytes: []const u8, replacement: ?Range) bool {
            if (self.rejected) return false;
            const before = self.context;
            if (!self.context.insert(bytes, replacement)) {
                self.context = before;
                if (self.in_key) self.rejected = true;
                return false;
            }
            return true;
        }
        pub fn marked(self: *Self, bytes: []const u8, selected: Range, replacement: ?Range) bool {
            if (self.rejected) return false;
            const before = self.context;
            if (!self.context.setMarked(bytes, selected, replacement)) {
                self.context = before;
                if (self.in_key) self.rejected = true;
                return false;
            }
            // Clearing a candidate preview restores the retained committed word;
            // deleting the preview bytes alone would erase it from the projection.
            if (bytes.len == 0) if (before.marked) |mark| {
                const suffix = before.len - mark.end;
                const length = before.committed_len;
                _ = self.context.reset(before.committed[0..length], "");
                const at = length - @min(length, suffix);
                self.context.selected = .{ .start = at, .end = at };
                self.context.pending = before.pending;
            };
            return true;
        }
        pub fn end(self: *Self, deleted: bool) Result {
            if (self.rejected) {
                if (self.before) |before| self.context = before;
                return .rollback;
            }
            if (!self.context.pending) return .none;
            if (deleted) self.context.cancelInsertedScalar();
            return .commit;
        }
        pub fn finishKey(self: *Self, key: ?Key, changed: bool, deleted: bool) Decision {
            const result = self.end(deleted);
            if (result != .none) return .{ .result = result, .consumed = true };
            if (changed) return .{ .consumed = true };
            const value = key orelse return .{ .consumed = true };
            if (value == .enter and self.context.preedit().len > 0) return .{ .consumed = true };
            if (value == .backspace and deleted) {
                return .{ .result = if (self.context.deleteBackward()) .commit else .none, .consumed = true };
            }
            return .{ .consumed = false };
        }
        pub fn commitAll(self: *Self) bool {
            return !self.rejected and self.context.admitMarked();
        }
    };
}
