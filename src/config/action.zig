const std = @import("std");

pub const Action = union(enum) {
    new_tab,
    close_tab,
    select_tab: usize,
    previous_tab,
    next_tab,
};

pub fn parseAction(value: []const u8) ?Action {
    // Action parsing lives away from theme/config structs because keybinding
    // grammar will grow independently from colors and font settings.
    if (std.mem.eql(u8, value, "new_tab")) return .new_tab;
    if (std.mem.eql(u8, value, "close_tab")) return .close_tab;
    if (std.mem.eql(u8, value, "previous_tab")) return .previous_tab;
    if (std.mem.eql(u8, value, "next_tab")) return .next_tab;

    const prefix = "select_tab:";
    if (std.mem.startsWith(u8, value, prefix)) {
        const index = std.fmt.parseUnsigned(usize, value[prefix.len..], 10) catch return null;
        return .{ .select_tab = index };
    }

    return null;
}

test "parse configured actions" {
    try std.testing.expectEqual(Action.new_tab, parseAction("new_tab").?);
    try std.testing.expectEqual(Action.close_tab, parseAction("close_tab").?);

    const action = parseAction("select_tab:3").?;
    try std.testing.expectEqual(@as(usize, 3), action.select_tab);
    try std.testing.expect(parseAction("unknown") == null);
}
