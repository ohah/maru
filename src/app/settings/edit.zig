//! An edit owns its key and rollback value across frame rebuilds and reloads.
//! A persistence failure keeps the transaction open; only the matching reply
//! can finish it. Hosts must apply previews without writing the config file.
const std = @import("std");

pub const Text = struct {
    bytes: [1024]u8 = undefined,
    len: usize = 0,
    fn copy(value: []const u8) !Text {
        if (value.len > 1024) return error.TextTooLong;
        var out: Text = .{ .len = value.len };
        @memcpy(out.bytes[0..value.len], value);
        return out;
    }
    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Request = struct { generation: u64, key: Text, value: Text, persist: bool };
pub const Edit = struct {
    generation: u64 = 0,
    active: bool = false,
    key: Text = .{},
    original: Text = .{},

    pub fn begin(self: *Edit, key: []const u8, original: []const u8) !void {
        if (self.active) return error.EditInProgress;
        if (key.len == 0) return error.EmptyKey;
        const owned_key = try Text.copy(key);
        const owned_value = try Text.copy(original);
        const next = std.math.add(u64, self.generation, 1) catch return error.GenerationExhausted;
        self.* = .{ .generation = next, .active = true, .key = owned_key, .original = owned_value };
    }
    pub fn request(self: *const Edit, selected_key: []const u8, value: []const u8, persist: bool) !?Request {
        if (!self.active or !std.mem.eql(u8, selected_key, self.key.slice())) return null;
        return .{ .generation = self.generation, .key = self.key, .value = try Text.copy(value), .persist = persist };
    }
    pub fn rollback(self: *const Edit) ?Request {
        if (!self.active) return null;
        return .{ .generation = self.generation, .key = self.key, .value = self.original, .persist = false };
    }
    pub fn finish(self: *Edit, generation: u64, succeeded: bool) void {
        if (self.active and self.generation == generation and succeeded) self.active = false;
    }
};

test "Settings edit rejects a foreign selected key" {
    var edit: Edit = .{};
    try edit.begin("font.size", "14");
    try std.testing.expect((try edit.request("scrollback.limit", "24", true)) == null);
}
test "Settings edit rollback owns the original bytes" {
    var edit: Edit = .{};
    var original = [_]u8{ '1', '4' };
    try edit.begin("font.size", &original);
    original[0] = '9';
    const rollback = edit.rollback().?;
    try std.testing.expectEqualStrings("14", rollback.value.slice());
    try std.testing.expectEqualStrings("font.size", rollback.key.slice());
    try std.testing.expect(!rollback.persist);
}
test "Settings edit previews never request persistence" {
    var edit: Edit = .{};
    try edit.begin("ui.language", "auto");
    try std.testing.expect(!(try edit.request("ui.language", "en", false)).?.persist);
    try std.testing.expect((try edit.request("ui.language", "en", true)).?.persist);
}
test "Settings edit failed persistence retains rollback" {
    var edit: Edit = .{};
    try edit.begin("font.size", "14");
    edit.finish(edit.generation, false);
    try std.testing.expect(edit.active);
    try std.testing.expect(edit.rollback() != null);
}
test "Settings edit stale replies cannot close a later edit" {
    var edit: Edit = .{};
    try edit.begin("font.size", "14");
    const old = edit.generation;
    edit.finish(old, true);
    try edit.begin("font.family", "Cascadia Mono");
    edit.finish(old, true);
    try std.testing.expect(edit.active);
}
