const std = @import("std");
const split_tree = @import("split_tree.zig");

/// 파일 패널 도크의 창-로컬 배치. 실제 rect 계산과 config 기본 크기는 FP3가 소유하며, `size == 0`은 그
/// 런타임 기본을 사용한다는 뜻이다. FP1이 아직 정해지지 않은 픽셀/point 정책을 선점하지 않게 하는 sentinel이다.
pub const Side = enum { right, bottom };

/// 창 하나가 보존하는 파일 entry 상한. workspace.v1이 window 한 줄에 반복 키를 두는 FP1 포맷이므로 reader의
/// 손상-input 작업량 bound와 live 모델의 저장 가능 상태를 같은 계약으로 맞춘다. 비활성 WKWebView 해제 상한(기본 8)과
/// 달리 이 값은 가벼운 탭 metadata 수 상한이다.
pub const max_entries: usize = 256;

/// 콘텐츠 종류는 WebKit 구성 선택에 쓰이는 L2 정책 값이다. 브라우저 탭을 도크로 보내는 후속 확장은 이 닫힌 목록에
/// 새 값을 더하되, 트리·탭 소유 모델은 그대로 재사용한다(docs/file-panel.md §1).
pub const EntryKind = enum { markdown, html };

/// v1 모드. HTML 소스 편집 UI는 아직 없지만 상태/포맷은 mode를 kind와 직교하게 보존해 후속 추가가 모델 migration을
/// 요구하지 않게 한다. 실제 UI가 허용할 조합은 FP6의 정책 배선이 제한한다.
pub const Mode = enum { read, source_edit };

pub const Entry = struct {
    path: []u8,
    kind: EntryKind,
    mode: Mode = .read,
    dirty: bool = false,
};

/// workspace.v1에 들어가는 entry 부분집합. dirty는 파일 내용이 아니라 휘발성 편집 상태라 의도적으로 빠진다.
pub const PersistedEntry = struct {
    path: []const u8,
    kind: EntryKind,
    mode: Mode = .read,
    active: bool = false,
};

/// FP1 workspace.v1 DTO. 그룹 트리는 FP8 전까지 직렬화하지 않으므로 entries는 암묵적인 단일 그룹에 속한다.
/// 기본값이면 window 라인에 어떤 dock 키도 쓰지 않아 옛 파일의 byte 고정점이 유지된다.
pub const PersistedState = struct {
    side: Side = .right,
    size: u32 = 0,
    collapsed: bool = false,
    entries: []const PersistedEntry = &.{},
};

pub const DockGroup = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    active: ?usize = null,

    fn init(allocator: std.mem.Allocator) DockGroup {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *DockGroup) void {
        for (self.entries.items) |entry| self.allocator.free(entry.path);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn findPath(self: *const DockGroup, path: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, path)) return i;
        }
        return null;
    }

    /// 파일 경로는 한 그룹에서 유일하다. 이미 열린 경로면 entry를 늘리지 않고 기존 탭만 활성화한다.
    fn openLocal(self: *DockGroup, path: []const u8, kind: EntryKind) !usize {
        if (path.len == 0) return error.InvalidPath;
        if (self.findPath(path)) |i| {
            self.active = i;
            return i;
        }
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.entries.append(self.allocator, .{ .path = owned, .kind = kind });
        const i = self.entries.items.len - 1;
        self.active = i;
        return i;
    }
};

/// 기존 workspace split 수학을 파일 그룹 leaf에 그대로 인스턴스화한다. 트리는 split 노드만 소유하고 DockPanel이
/// 각 `*DockGroup` leaf의 주소 안정성과 해제를 책임진다.
pub const DockTree = split_tree.SplitTree(*DockGroup);

pub const DockPanel = struct {
    allocator: std.mem.Allocator,
    tree: DockTree.Node,
    side: Side = .right,
    size: u32 = 0,
    collapsed: bool = false,

    pub fn init(allocator: std.mem.Allocator) !DockPanel {
        const group = try allocator.create(DockGroup);
        group.* = DockGroup.init(allocator);
        return .{ .allocator = allocator, .tree = .{ .leaf = group } };
    }

    pub fn deinit(self: *DockPanel) void {
        deinitGroups(self.allocator, self.tree);
        DockTree.deinit(self.allocator, self.tree);
        self.* = undefined;
    }

    fn deinitGroups(allocator: std.mem.Allocator, node: DockTree.Node) void {
        switch (node) {
            .leaf => |group| {
                group.deinit();
                allocator.destroy(group);
            },
            .split => |sp| {
                deinitGroups(allocator, sp.a);
                deinitGroups(allocator, sp.b);
            },
        }
    }

    pub fn singleGroup(self: *DockPanel) ?*DockGroup {
        return switch (self.tree) {
            .leaf => |group| group,
            .split => null,
        };
    }

    pub const OpenResult = struct {
        group: *DockGroup,
        index: usize,
        created: bool,
    };

    /// 경로 유일성은 그룹이 아니라 창 도크 전체 불변식이다. FP8 분할 뒤에도 같은 파일을 다른 그룹 target으로 다시
    /// 열면 원래 entry를 활성화하고 그 group/index를 돌려 UI가 해당 그룹에 focus를 옮길 수 있게 한다.
    pub fn open(self: *DockPanel, target: *DockGroup, path: []const u8, kind: EntryKind) !OpenResult {
        if (path.len == 0) return error.InvalidPath;
        if (!containsGroup(self.tree, target)) return error.GroupNotFound;
        if (findPath(self.tree, path)) |found| {
            found.group.active = found.index;
            return .{ .group = found.group, .index = found.index, .created = false };
        }
        if (entryCount(self.tree) >= max_entries) return error.TooManyEntries;
        const index = try target.openLocal(path, kind);
        return .{ .group = target, .index = index, .created = true };
    }

    fn containsGroup(node: DockTree.Node, target: *DockGroup) bool {
        return switch (node) {
            .leaf => |group| group == target,
            .split => |sp| containsGroup(sp.a, target) or containsGroup(sp.b, target),
        };
    }

    fn findPath(node: DockTree.Node, path: []const u8) ?struct { group: *DockGroup, index: usize } {
        return switch (node) {
            .leaf => |group| if (group.findPath(path)) |index| .{ .group = group, .index = index } else null,
            .split => |sp| findPath(sp.a, path) orelse findPath(sp.b, path),
        };
    }

    fn entryCount(node: DockTree.Node) usize {
        return switch (node) {
            .leaf => |group| group.entries.items.len,
            .split => |sp| entryCount(sp.a) + entryCount(sp.b),
        };
    }

    /// FP8 UI가 쓸 additive 연산을 FP1 모델에서 먼저 고정한다. target leaf는 a에 남고 새 빈 그룹은 b가 된다.
    pub fn splitGroup(self: *DockPanel, target: *DockGroup, direction: split_tree.SplitDirection, ratio: f32) !*DockGroup {
        const group = try self.allocator.create(DockGroup);
        errdefer self.allocator.destroy(group);
        group.* = DockGroup.init(self.allocator);
        errdefer group.deinit();

        const split = try self.allocator.create(DockTree.Split);
        errdefer self.allocator.destroy(split);
        split.* = .{
            .direction = direction,
            .ratio = split_tree.clampRatio(ratio),
            .a = .{ .leaf = target },
            .b = .{ .leaf = group },
        };
        if (!DockTree.replaceLeaf(&self.tree, target, .{ .split = split })) return error.GroupNotFound;
        return group;
    }

    /// 마지막 그룹은 도크 모델의 루트이므로 제거하지 않는다. 중첩 leaf 제거 시 SplitTree가 돌려준 split 노드를
    /// 호출자가 정확히 한 번 destroy하고, 제거된 그룹의 entry/path도 함께 정리한다.
    pub fn removeGroup(self: *DockPanel, target: *DockGroup) bool {
        const freed = DockTree.removeLeaf(&self.tree, target) orelse return false;
        target.deinit();
        self.allocator.destroy(target);
        self.allocator.destroy(freed);
        return true;
    }

    /// workspace.v1의 단일 그룹 DTO에서 라이브 소유 모델을 복구한다. dirty는 persisted DTO에 없으므로 항상 false다.
    pub fn restore(allocator: std.mem.Allocator, state: PersistedState) !DockPanel {
        if (state.entries.len > max_entries) return error.InvalidPersistedState;
        var panel = try DockPanel.init(allocator);
        errdefer panel.deinit();
        panel.side = state.side;
        panel.size = state.size;
        panel.collapsed = state.collapsed;

        const group = panel.singleGroup().?;
        var active: ?usize = null;
        for (state.entries) |entry| {
            if (entry.path.len == 0 or group.findPath(entry.path) != null) return error.InvalidPersistedState;
            const i = try group.openLocal(entry.path, entry.kind);
            group.entries.items[i].mode = entry.mode;
            group.entries.items[i].dirty = false;
            if (entry.active) {
                if (active != null) return error.InvalidPersistedState;
                active = i;
            }
        }
        if (state.entries.len > 0 and active == null) return error.InvalidPersistedState;
        group.active = active;
        return panel;
    }

    /// 현재 FP1 포맷이 표현할 수 있는 단일 그룹만 빌려온 path slice로 투영한다. 반환 entries 컨테이너만 호출자가
    /// `freePersistedState`로 해제하며 path bytes는 계속 DockPanel 소유다.
    pub fn persistedState(self: *DockPanel, allocator: std.mem.Allocator) !PersistedState {
        const group = self.singleGroup() orelse return error.MultipleGroupsNotPersistable;
        if ((group.entries.items.len > 0 and group.active == null) or
            (group.active != null and group.active.? >= group.entries.items.len) or
            group.entries.items.len > max_entries) return error.InvalidPersistedState;
        const entries = try allocator.alloc(PersistedEntry, group.entries.items.len);
        for (group.entries.items, 0..) |entry, i| entries[i] = .{
            .path = entry.path,
            .kind = entry.kind,
            .mode = entry.mode,
            .active = group.active != null and group.active.? == i,
        };
        return .{ .side = self.side, .size = self.size, .collapsed = self.collapsed, .entries = entries };
    }
};

pub fn freePersistedState(allocator: std.mem.Allocator, state: *PersistedState) void {
    if (state.entries.len > 0) allocator.free(state.entries);
    state.* = .{};
}

test "dock panel: single group owns entries and reopening a path activates instead of duplicating" {
    var panel = try DockPanel.init(std.testing.allocator);
    defer panel.deinit();

    const group = panel.singleGroup().?;
    try std.testing.expectEqual(Side.right, panel.side);
    try std.testing.expectEqual(@as(u32, 0), panel.size);
    try std.testing.expect(!panel.collapsed);
    try std.testing.expectEqual(@as(usize, 1), DockTree.leafCount(panel.tree));

    try std.testing.expectEqual(@as(usize, 0), (try panel.open(group, "/tmp/a.md", .markdown)).index);
    try std.testing.expectEqual(@as(usize, 1), (try panel.open(group, "/tmp/b.html", .html)).index);
    try std.testing.expectEqual(@as(?usize, 1), group.active);
    try std.testing.expectEqual(@as(usize, 0), (try panel.open(group, "/tmp/a.md", .markdown)).index);
    try std.testing.expectEqual(@as(?usize, 0), group.active);
    try std.testing.expectEqual(@as(usize, 2), group.entries.items.len);

    group.entries.items[0].mode = .source_edit;
    group.entries.items[0].dirty = true;
    try std.testing.expectEqual(Mode.source_edit, group.entries.items[0].mode);
    try std.testing.expect(group.entries.items[0].dirty);
}

test "dock panel: replaceLeaf split lays out two file groups in the dock rect" {
    var panel = try DockPanel.init(std.testing.allocator);
    defer panel.deinit();

    const first = panel.singleGroup().?;
    _ = try panel.open(first, "/tmp/a.md", .markdown);
    const second = try panel.splitGroup(first, .horizontal, 0.5);
    _ = try panel.open(second, "/tmp/b.md", .markdown);

    var out: std.ArrayList(DockTree.LeafRect) = .empty;
    defer out.deinit(std.testing.allocator);
    try DockTree.layout(std.testing.allocator, panel.tree, .{ .x = 100, .y = 20, .w = 600, .h = 400 }, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(first, out.items[0].leaf);
    try std.testing.expectEqual(split_tree.Rect{ .x = 100, .y = 20, .w = 300, .h = 400 }, out.items[0].rect);
    try std.testing.expectEqual(second, out.items[1].leaf);
    try std.testing.expectEqual(split_tree.Rect{ .x = 400, .y = 20, .w = 300, .h = 400 }, out.items[1].rect);
}

test "dock panel: nested three-group tree emits dividers and removeLeaf restores siblings" {
    var panel = try DockPanel.init(std.testing.allocator);
    defer panel.deinit();

    const a = panel.singleGroup().?;
    const b = try panel.splitGroup(a, .horizontal, 0.5);
    const c = try panel.splitGroup(b, .vertical, 0.25);
    _ = try panel.open(a, "/tmp/a.md", .markdown);
    _ = try panel.open(b, "/tmp/b.md", .markdown);
    _ = try panel.open(c, "/tmp/c.html", .html);

    var dividers: std.ArrayList(DockTree.DividerSeg) = .empty;
    defer dividers.deinit(std.testing.allocator);
    try DockTree.layoutDividers(std.testing.allocator, panel.tree, .{ .x = 0, .y = 0, .w = 800, .h = 600 }, &dividers);
    try std.testing.expectEqual(@as(usize, 2), dividers.items.len);
    try std.testing.expectEqual(@as(u32, 400), dividers.items[0].pos);
    try std.testing.expectEqual(@as(u32, 150), dividers.items[1].pos);

    try std.testing.expect(panel.removeGroup(b));
    try std.testing.expectEqual(@as(usize, 2), DockTree.leafCount(panel.tree));
    try std.testing.expect(panel.removeGroup(a));
    try std.testing.expectEqual(@as(usize, 1), DockTree.leafCount(panel.tree));
    try std.testing.expectEqual(c, panel.singleGroup().?);
    try std.testing.expect(!panel.removeGroup(c));
}

test "dock panel: bottom placement uses the same group tree across a wide dock rect" {
    var panel = try DockPanel.init(std.testing.allocator);
    defer panel.deinit();
    panel.side = .bottom;

    const left = panel.singleGroup().?;
    const right = try panel.splitGroup(left, .horizontal, 0.25);
    var out: std.ArrayList(DockTree.LeafRect) = .empty;
    defer out.deinit(std.testing.allocator);
    try DockTree.layout(std.testing.allocator, panel.tree, .{ .x = 0, .y = 500, .w = 1200, .h = 240 }, &out);

    try std.testing.expectEqual(Side.bottom, panel.side);
    try std.testing.expectEqual(split_tree.Rect{ .x = 0, .y = 500, .w = 300, .h = 240 }, out.items[0].rect);
    try std.testing.expectEqual(left, out.items[0].leaf);
    try std.testing.expectEqual(split_tree.Rect{ .x = 300, .y = 500, .w = 900, .h = 240 }, out.items[1].rect);
    try std.testing.expectEqual(right, out.items[1].leaf);
}

test "dock panel: persisted single group restores entries but deliberately resets dirty" {
    const entries = [_]PersistedEntry{
        .{ .path = "/tmp/a.md", .kind = .markdown, .mode = .source_edit, .active = true },
        .{ .path = "/tmp/b.html", .kind = .html, .mode = .read, .active = false },
    };
    var panel = try DockPanel.restore(std.testing.allocator, .{
        .side = .bottom,
        .size = 360,
        .collapsed = true,
        .entries = &entries,
    });
    defer panel.deinit();

    const group = panel.singleGroup().?;
    try std.testing.expectEqual(Side.bottom, panel.side);
    try std.testing.expectEqual(@as(u32, 360), panel.size);
    try std.testing.expect(panel.collapsed);
    try std.testing.expectEqual(@as(?usize, 0), group.active);
    try std.testing.expectEqual(Mode.source_edit, group.entries.items[0].mode);
    try std.testing.expect(!group.entries.items[0].dirty);
    try std.testing.expect(!group.entries.items[1].dirty);
}

test "dock panel: live single group exports workspace DTO and rejects unrepresentable or ambiguous state" {
    var panel = try DockPanel.init(std.testing.allocator);
    defer panel.deinit();
    panel.side = .bottom;
    panel.size = 480;

    const group = panel.singleGroup().?;
    _ = try panel.open(group, "/tmp/a.md", .markdown);
    _ = try panel.open(group, "/tmp/b.html", .html);
    group.entries.items[0].dirty = true;
    group.entries.items[0].mode = .source_edit;
    group.active = 0;

    var state = try panel.persistedState(std.testing.allocator);
    defer freePersistedState(std.testing.allocator, &state);
    try std.testing.expectEqual(Side.bottom, state.side);
    try std.testing.expectEqual(@as(u32, 480), state.size);
    try std.testing.expectEqual(@as(usize, 2), state.entries.len);
    try std.testing.expectEqualStrings("/tmp/a.md", state.entries[0].path);
    try std.testing.expectEqual(Mode.source_edit, state.entries[0].mode);
    try std.testing.expect(state.entries[0].active);
    try std.testing.expect(!state.entries[1].active);

    const second = try panel.splitGroup(group, .horizontal, 0.5);
    try std.testing.expectError(error.MultipleGroupsNotPersistable, panel.persistedState(std.testing.allocator));
    try std.testing.expect(panel.removeGroup(second));

    group.active = 99;
    try std.testing.expectError(error.InvalidPersistedState, panel.persistedState(std.testing.allocator));

    const ambiguous = [_]PersistedEntry{
        .{ .path = "/tmp/a.md", .kind = .markdown, .active = false },
    };
    try std.testing.expectError(error.InvalidPersistedState, DockPanel.restore(std.testing.allocator, .{ .entries = &ambiguous }));
}

test "dock panel: reopening a path in another group activates the original entry without duplicating it" {
    var panel = try DockPanel.init(std.testing.allocator);
    defer panel.deinit();

    const first = panel.singleGroup().?;
    const created = try panel.open(first, "/tmp/a.md", .markdown);
    try std.testing.expect(created.created);
    const second = try panel.splitGroup(first, .horizontal, 0.5);

    const reopened = try panel.open(second, "/tmp/a.md", .markdown);
    try std.testing.expect(!reopened.created);
    try std.testing.expectEqual(first, reopened.group);
    try std.testing.expectEqual(@as(usize, 0), reopened.index);
    try std.testing.expectEqual(@as(?usize, 0), first.active);
    try std.testing.expectEqual(@as(usize, 0), second.entries.items.len);
}

test "dock panel: live entry bound matches workspace persistence at 256 and rejects 257" {
    var panel = try DockPanel.init(std.testing.allocator);
    defer panel.deinit();
    const group = panel.singleGroup().?;

    var path_buf: [64]u8 = undefined;
    for (0..max_entries) |i| {
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/{d}.md", .{i});
        _ = try panel.open(group, path, .markdown);
    }
    try std.testing.expectEqual(max_entries, group.entries.items.len);
    try std.testing.expectError(error.TooManyEntries, panel.open(group, "/tmp/overflow.md", .markdown));

    var state = try panel.persistedState(std.testing.allocator);
    defer freePersistedState(std.testing.allocator, &state);
    try std.testing.expectEqual(max_entries, state.entries.len);
}
