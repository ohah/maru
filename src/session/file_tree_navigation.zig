//! 파일 트리의 transient 선택과 키보드 탐색 정책. L4는 키 이벤트를 `Intent`로 번역하고
//! 실제 디렉터리 toggle/파일 열기만 수행한다. 이 모듈은 OS·렌더러·파일시스템을 모른다.

const std = @import("std");
const file_tree = @import("file_tree.zig");

pub const Selection = struct {
    kind: ?file_tree.RowKind = null,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    index_hint: usize = 0,

    pub fn clear(self: *Selection) void {
        self.kind = null;
        self.path_len = 0;
        self.index_hint = 0;
    }

    pub fn path(self: *const Selection) ?[]const u8 {
        if (self.kind == null) return null;
        return self.path_buf[0..self.path_len];
    }

    pub fn set(self: *Selection, rows: []const file_tree.Row, row_index: usize) bool {
        if (row_index >= rows.len) return false;
        const identity = file_tree.rowIdentity(rows[row_index]) orelse return false;
        if (identity.path.len > self.path_buf.len) return false;
        @memcpy(self.path_buf[0..identity.path.len], identity.path);
        self.path_len = identity.path.len;
        self.kind = identity.kind;
        self.index_hint = row_index;
        return true;
    }

    pub fn index(self: *const Selection, rows: []const file_tree.Row) ?usize {
        const kind = self.kind orelse return null;
        const wanted: file_tree.RowIdentity = .{ .kind = kind, .path = self.path_buf[0..self.path_len] };
        if (self.index_hint < rows.len) if (file_tree.rowIdentity(rows[self.index_hint])) |identity| {
            if (identity.eql(wanted)) return self.index_hint;
        };
        return file_tree.findIdentity(rows, wanted);
    }

    /// async rebuild 뒤 exact identity, visible ancestor, 위치 이웃 순으로 선택을 복원한다.
    pub fn reconcile(self: *Selection, rows: []const file_tree.Row) ?usize {
        const kind = self.kind orelse return null;
        const wanted: file_tree.RowIdentity = .{ .kind = kind, .path = self.path_buf[0..self.path_len] };
        const resolved = file_tree.reconcileIdentity(rows, wanted, self.index_hint) orelse {
            self.clear();
            return null;
        };
        _ = self.set(rows, resolved);
        return resolved;
    }
};

pub const Intent = enum {
    previous,
    next,
    collapse_or_parent,
    expand_or_child,
    activate,
    first,
    last,
    page_up,
    page_down,
};

pub const Result = union(enum) {
    none,
    select: usize,
    activate: usize,
};

pub fn navigate(rows: []const file_tree.Row, selected: usize, intent: Intent, page_rows: usize) Result {
    if (selected >= rows.len or file_tree.rowIdentity(rows[selected]) == null) return .none;
    return switch (intent) {
        .previous => if (file_tree.adjacentActionable(rows, selected, -1)) |index| .{ .select = index } else .none,
        .next => if (file_tree.adjacentActionable(rows, selected, 1)) |index| .{ .select = index } else .none,
        .first => if (actionableAtOrAfter(rows, 0)) |index| .{ .select = index } else .none,
        .last => if (actionableAtOrBefore(rows, rows.len)) |index| .{ .select = index } else .none,
        .page_up => blk: {
            const step = @max(@as(usize, 1), page_rows);
            const index = actionableAtOrAfter(rows, selected -| step) orelse break :blk .none;
            break :blk .{ .select = index };
        },
        .page_down => blk: {
            const step = @max(@as(usize, 1), page_rows);
            const target = @min(selected +| step, rows.len -| 1);
            const index = actionableAtOrBefore(rows, target) orelse break :blk .none;
            break :blk .{ .select = index };
        },
        .collapse_or_parent => collapseOrParent(rows, selected),
        .expand_or_child => expandOrChild(rows, selected),
        .activate => .{ .activate = selected },
    };
}

pub fn scrollIntoView(current: usize, selected: usize, visible_rows: usize) usize {
    if (visible_rows == 0) return current;
    if (selected < current) return selected;
    if (selected >= current +| visible_rows) return selected + 1 - visible_rows;
    return current;
}

fn collapseOrParent(rows: []const file_tree.Row, selected: usize) Result {
    switch (rows[selected]) {
        .recent_header => |v| if (!v.collapsed) return .{ .activate = selected },
        .root => |v| if (v.expanded) return .{ .activate = selected },
        .directory => |v| if (v.expanded) return .{ .activate = selected },
        else => {},
    }
    return if (file_tree.parentIndex(rows, selected)) |index| .{ .select = index } else .none;
}

fn expandOrChild(rows: []const file_tree.Row, selected: usize) Result {
    switch (rows[selected]) {
        .recent_header => |v| if (v.collapsed) return .{ .activate = selected },
        .root => |v| if (!v.expanded) return .{ .activate = selected },
        .directory => |v| if (!v.expanded) return .{ .activate = selected },
        else => return .none,
    }
    return if (file_tree.firstChildIndex(rows, selected)) |index| .{ .select = index } else .none;
}

fn actionableAtOrAfter(rows: []const file_tree.Row, start: usize) ?usize {
    var index = @min(start, rows.len);
    while (index < rows.len) : (index += 1) if (file_tree.rowIdentity(rows[index]) != null) return index;
    return null;
}

fn actionableAtOrBefore(rows: []const file_tree.Row, start: usize) ?usize {
    if (rows.len == 0) return null;
    var index = @min(start, rows.len - 1) + 1;
    while (index > 0) {
        index -= 1;
        if (file_tree.rowIdentity(rows[index]) != null) return index;
    }
    return null;
}

const test_rows = [_]file_tree.Row{
    .{ .root = .{ .path = "/repo", .label = "repo", .expanded = true, .loading = false } },
    .{ .directory = .{ .path = "/repo/docs", .label = "docs", .depth = 1, .expanded = true, .loading = false, .symlink = false } },
    .{ .file = .{ .path = "/repo/docs/a.md", .label = "a.md", .depth = 2, .supported = true, .open = false, .active = false, .dirty = false, .external_change = false, .symlink = false } },
    .{ .empty = {} },
    .{ .file = .{ .path = "/repo/z.md", .label = "z.md", .depth = 1, .supported = true, .open = false, .active = false, .dirty = false, .external_change = false, .symlink = false } },
};

test "selection follows identity and falls back after rebuild" {
    var selection: Selection = .{};
    try std.testing.expect(selection.set(&test_rows, 2));
    try std.testing.expectEqualStrings("/repo/docs/a.md", selection.path().?);

    const reordered = [_]file_tree.Row{ test_rows[0], test_rows[1], test_rows[4], test_rows[2] };
    try std.testing.expectEqual(@as(?usize, 3), selection.reconcile(&reordered));
    try std.testing.expectEqual(@as(?usize, 3), selection.index(&reordered));

    const collapsed = [_]file_tree.Row{test_rows[0]};
    try std.testing.expectEqual(@as(?usize, 0), selection.reconcile(&collapsed));
    try std.testing.expectEqualStrings("/repo", selection.path().?);
}

test "all navigation intents use actionable rows and tree hierarchy" {
    try std.testing.expectEqual(Result{ .select = 0 }, navigate(&test_rows, 1, .previous, 2));
    try std.testing.expectEqual(Result{ .select = 2 }, navigate(&test_rows, 1, .next, 2));
    try std.testing.expectEqual(Result{ .select = 0 }, navigate(&test_rows, 2, .first, 2));
    try std.testing.expectEqual(Result{ .select = 4 }, navigate(&test_rows, 0, .last, 2));
    try std.testing.expectEqual(Result{ .select = 0 }, navigate(&test_rows, 2, .page_up, 2));
    try std.testing.expectEqual(Result{ .select = 2 }, navigate(&test_rows, 0, .page_down, 3));
    try std.testing.expectEqual(Result{ .activate = 1 }, navigate(&test_rows, 1, .collapse_or_parent, 2));
    try std.testing.expectEqual(Result{ .select = 1 }, navigate(&test_rows, 0, .expand_or_child, 2));
    try std.testing.expectEqual(Result{ .activate = 2 }, navigate(&test_rows, 2, .activate, 2));
    try std.testing.expectEqual(Result.none, navigate(&test_rows, 2, .expand_or_child, 2));

    const collapsed = [_]file_tree.Row{.{ .directory = .{
        .path = "/repo/docs",
        .label = "docs",
        .depth = 1,
        .expanded = false,
        .loading = false,
        .symlink = false,
    } }};
    try std.testing.expectEqual(Result{ .activate = 0 }, navigate(&collapsed, 0, .expand_or_child, 1));
}

test "scroll into view keeps selection inside viewport" {
    try std.testing.expectEqual(@as(usize, 2), scrollIntoView(4, 2, 5));
    try std.testing.expectEqual(@as(usize, 4), scrollIntoView(4, 7, 5));
    try std.testing.expectEqual(@as(usize, 5), scrollIntoView(4, 9, 5));
    try std.testing.expectEqual(@as(usize, 4), scrollIntoView(4, 99, 0));
}
