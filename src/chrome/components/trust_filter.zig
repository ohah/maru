//! Pure matching for trust/environment snapshots; labels and authority stay with the host.
const std = @import("std");
const grapheme = @import("../../grapheme.zig");
pub const Plan = struct {
    comparison: []const u8,
    owned: ?[]u8,
    shown: std.ArrayList(usize) = .empty,
    /// A legacy comparison may borrow raw bytes on normalization OOM. The caller
    /// must keep raw_query alive until publication/deinit; native admission is strict.
    pub fn init(a: std.mem.Allocator, count: usize, raw_query: []const u8, legacy_fallback: bool) !Plan {
        const owned = grapheme.composeHangul(a, raw_query) catch |err| if (legacy_fallback) null else return err;
        var p: Plan = .{ .comparison = owned orelse raw_query, .owned = owned };
        errdefer p.deinit(a);
        try p.shown.ensureTotalCapacity(a, count);
        return p;
    }
    pub fn deinit(self: *Plan, a: std.mem.Allocator) void {
        if (self.owned) |q| a.free(q);
        self.shown.deinit(a);
    }
    /// The optional display label is provided only for trust mode, never environment values.
    pub fn consider(self: *Plan, index: usize, text: []const u8, display: ?[]const u8) void {
        if (self.comparison.len == 0 or std.ascii.findIgnoreCase(text, self.comparison) != null or
            (if (display) |label| std.ascii.findIgnoreCase(label, self.comparison) != null else false)) self.shown.appendAssumeCapacity(index);
    }
};

test "trust picker IME model preserves raw NFD and searches rendered trust labels" {
    const a = std.testing.allocator;
    var p = try Plan.init(a, 3, "한", false);
    defer p.deinit(a);
    p.consider(0, "/repo/한", "~/한");
    p.consider(1, "ENV_NAME", null);
    p.consider(2, "/repo/韓", null);
    try std.testing.expectEqualStrings("한", p.comparison);
    try std.testing.expectEqualSlices(usize, &.{0}, p.shown.items);
    var remote = try Plan.init(a, 1, "HOST:", false);
    defer remote.deinit(a);
    remote.consider(0, "/repo", "host:/repo");
    try std.testing.expectEqualSlices(usize, &.{0}, remote.shown.items);
}

test "trust picker IME model environment names do not search values or exclusion labels" {
    const a = std.testing.allocator;
    var p = try Plan.init(a, 2, "SECRET_VALUE", false);
    defer p.deinit(a);
    p.consider(0, "KEY", null);
    p.consider(1, "SECRET_VALUE_NAME", null);
    try std.testing.expectEqualSlices(usize, &.{1}, p.shown.items);
}

test "trust picker IME model strict preparation unwinds every allocation failure" {
    const Scenario = struct {
        fn run(a: std.mem.Allocator) !void {
            var p = try Plan.init(a, 50, "한", false);
            defer p.deinit(a);
            p.consider(0, "한", null);
            try std.testing.expectEqualSlices(usize, &.{0}, p.shown.items);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}

test "trust picker IME model legacy normalization failure borrows raw comparison while native rejects" {
    const a = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var p = try Plan.init(failing.allocator(), 0, "한", true);
    defer p.deinit(failing.allocator());
    try std.testing.expect(p.owned == null);
    try std.testing.expectEqualStrings("한", p.comparison);
    try std.testing.expectError(error.OutOfMemory, Plan.init(failing.allocator(), 0, "한", false));
}

test "trust picker IME model localized prompts leave room for the composing caret" {
    const palette = @import("palette.zig");
    const props = @import("../props.zig");
    const overlay = @import("overlay_input.zig");
    const i18n = @import("../../i18n.zig");
    const p: props.ChromeProps = .{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 180, .backing_width_px = 960, .backing_height_px = 600 } };
    const layout = overlay.panelLayout(p).?;
    for ([_]i18n.Lang{ .en, .ko }) |lang| {
        for ([_]i18n.Key{ .lsp_trust_list_prompt, .lsp_trust_list_empty, .lsp_env_list_prompt, .lsp_env_list_empty, .lsp_env_list_pending }) |key| {
            var state: palette.State = .{};
            defer state.deinit(std.testing.allocator);
            state.show();
            state.prompt = i18n.tIn(lang, key);
            try state.input.query.appendSlice(std.testing.allocator, "한");
            const caret = palette.caretRect(&state, p) orelse return error.CaretOutsidePicker;
            try std.testing.expect(caret.x >= layout.x);
            try std.testing.expect(caret.x + @as(i32, @intCast(caret.w)) <= layout.x + @as(i32, @intCast(layout.panel_cols * layout.cw)));
        }
    }
}
