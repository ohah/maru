const std = @import("std");

pub const Action = union(enum) {
    new_tab,
    close_tab,
    select_tab: usize,
    previous_tab,
    next_tab,
    // 활성 panel을 둘로 나눈다(split). horizontal=좌우(새 panel이 오른쪽), vertical=상하(새 panel이 아래).
    // 방향 이름은 분할선(divider)의 방향이 아니라 '나란히 놓이는 축'을 따른다 — 단일 출처: docs/tabs-splits-layout.md.
    split_horizontal,
    split_vertical,
};

pub fn parseAction(value: []const u8) ?Action {
    // Action parsing lives away from theme/config structs because keybinding
    // grammar will grow independently from colors and font settings.
    if (std.mem.eql(u8, value, "new_tab")) return .new_tab;
    if (std.mem.eql(u8, value, "close_tab")) return .close_tab;
    if (std.mem.eql(u8, value, "previous_tab")) return .previous_tab;
    if (std.mem.eql(u8, value, "next_tab")) return .next_tab;
    if (std.mem.eql(u8, value, "split_horizontal")) return .split_horizontal;
    if (std.mem.eql(u8, value, "split_vertical")) return .split_vertical;

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

    try std.testing.expectEqual(Action.split_horizontal, parseAction("split_horizontal").?);
    try std.testing.expectEqual(Action.split_vertical, parseAction("split_vertical").?);

    const action = parseAction("select_tab:3").?;
    try std.testing.expectEqual(@as(usize, 3), action.select_tab);
    try std.testing.expect(parseAction("unknown") == null);
}
