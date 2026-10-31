//! File-tree popup rows and their commands share one ordered catalog.
//! Hosts validate target identity and perform native operations separately.
const std = @import("std");
const i18n = @import("../i18n.zig");
const RowKind = @import("../session/file_tree.zig").RowKind;
pub const Target = enum { background, root, directory, file };
pub const Action = enum { new_file, new_folder, rename, trash, open_file, open_folder, add_root, remove_root };
pub const Item = struct {
    action: Action,
    key: i18n.Key,
    pub fn label(self: Item) [:0]const u8 {
        return i18n.t(self.key);
    }
};
const create = [_]Item{ .{ .action = .new_file, .key = .ctx_new_file }, .{ .action = .new_folder, .key = .ctx_new_folder } };
const mutate = [_]Item{ .{ .action = .rename, .key = .ctx_rename }, .{ .action = .trash, .key = .ctx_move_to_trash } };
const open = [_]Item{ .{ .action = .open_file, .key = .ctx_open_file }, .{ .action = .open_folder, .key = .ctx_open_folder }, .{ .action = .add_root, .key = .ctx_add_folder_to_workspace } };
const roots = open ++ [_]Item{.{ .action = .remove_root, .key = .ctx_remove_folder_from_workspace }};
const regular_root = create ++ roots;
const entry = create ++ mutate;
pub const max_items = regular_root.len;
pub fn targetForRow(kind: RowKind) ?Target {
    return switch (kind) {
        .root => .root,
        .directory => .directory,
        .file => .file,
        .recent_header, .recent_file => null,
    };
}
pub fn items(target: Target, symlink: bool) []const Item {
    return switch (target) {
        .background => &open,
        .root => if (symlink) &roots else &regular_root,
        .directory => if (symlink) &mutate else &entry,
        .file => &entry,
    };
}
pub fn actionAt(target: Target, symlink: bool, selected: usize) ?Action {
    const rows = items(target, symlink);
    return if (selected < rows.len) rows[selected].action else null;
}
pub fn labels(target: Target, symlink: bool, out: *[max_items][]const u8) []const []const u8 {
    const rows = items(target, symlink);
    for (rows, 0..) |row, i| out[i] = row.label();
    return out[0..rows.len];
}
fn expectActions(target: Target, symlink: bool, expected: []const Action) !void {
    const actual = items(target, symlink);
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |action, i| try std.testing.expectEqual(action, actionAt(target, symlink, i).?);
}
test "file tree context menu regular root keeps creation and root actions" {
    try expectActions(.root, false, &.{ .new_file, .new_folder, .open_file, .open_folder, .add_root, .remove_root });
}
test "file tree context menu symlink root dispatch follows visible rows" {
    try expectActions(.root, true, &.{ .open_file, .open_folder, .add_root, .remove_root });
}
test "file tree context menu symlink directory cannot create children" {
    try expectActions(.directory, true, &.{ .rename, .trash });
    try expectActions(.directory, false, &.{ .new_file, .new_folder, .rename, .trash });
}
test "file tree context menu symlink file keeps parent creation actions" {
    try expectActions(.file, true, &.{ .new_file, .new_folder, .rename, .trash });
    try expectActions(.file, false, &.{ .new_file, .new_folder, .rename, .trash });
}
test "file tree context menu background and nonentry rows stay separate" {
    try expectActions(.background, false, &.{ .open_file, .open_folder, .add_root });
    try std.testing.expect(targetForRow(.recent_header) == null);
    try std.testing.expect(targetForRow(.recent_file) == null);
    try std.testing.expectEqual(Target.root, targetForRow(.root).?);
}
test "file tree context menu invalid selection cannot dispatch" {
    for (std.enums.values(Target)) |target| {
        for ([_]bool{ false, true }) |symlink| {
            try std.testing.expect(actionAt(target, symlink, items(target, symlink).len) == null);
            try std.testing.expect(actionAt(target, symlink, std.math.maxInt(usize)) == null);
        }
    }
}
test "file tree context menu label and action come from the same item" {
    var buffer: [max_items][]const u8 = undefined;
    const visible = labels(.root, true, &buffer);
    try std.testing.expectEqual(@as(usize, 4), visible.len);
    try std.testing.expectEqualStrings(i18n.t(.ctx_open_file), visible[0]);
    try std.testing.expectEqualStrings(i18n.t(.ctx_remove_folder_from_workspace), visible[3]);
    try std.testing.expectEqual(i18n.Key.ctx_rename, items(.directory, true)[0].key);
}
