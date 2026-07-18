const std = @import("std");
const split_tree = @import("split_tree.zig");

/// 파일 패널 도크의 창-로컬 배치. 실제 rect 계산과 config 기본 크기는 FP3가 소유하며, `size == 0`은 그
/// 런타임 기본을 사용한다는 뜻이다. FP1이 아직 정해지지 않은 픽셀/point 정책을 선점하지 않게 하는 sentinel이다.
pub const Side = enum { right, bottom };

/// 창 하나가 보존하는 파일 entry 상한. workspace.v1이 window 한 줄에 반복 키를 두는 FP1 포맷이므로 reader의
/// 손상-input 작업량 bound와 live 모델의 저장 가능 상태를 같은 계약으로 맞춘다. 비활성 WKWebView 해제 상한(기본 8)과
/// 달리 이 값은 가벼운 탭 metadata 수 상한이다.
pub const max_entries: usize = 256;

/// 한 창 도크의 editor group 상한. 분할 UI는 보통 한 자릿수지만 workspace 입력이 빈 leaf를 무한히 만들지
/// 못하게 모델과 reader가 같은 bound를 쓴다. 64 groups면 preorder node도 최대 127개로 고정된다.
pub const max_groups: usize = 64;

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
    /// FP6 two-phase dirty mirror. source editor가 비활성/읽기 모드로 넘어갈 때 true로 세우고 shell의 강제
    /// setDirty snapshot ack에서만 내린다. ack 전에는 non-dirty라도 live view eviction 대상이 아니다.
    dirty_sync_pending: bool = false,
    /// FSEvents가 디스크 변경을 알렸는데 source editor가 dirty라 자동 reload하지 못한 상태. 사용자의 buffer를
    /// 덮지 않으며 트리/헤더에 conflict를 표시하고 저장도 명시적 해결 전까지 거부한다.
    external_change: bool = false,
    external_change_generation: u64 = 0,
    /// 사용자 승인 뒤 실제 web read/replace 성공 ack를 기다리는 2-phase reload. 완료 전에는 dirty/conflict 보호를
    /// 유지하며 workspace에는 저장하지 않는다.
    conflict_reload_pending: bool = false,
    conflict_reload_generation: u64 = 0,
    /// atomic write 직후 dirty ack/FSEvents 순서가 뒤집혀 자기 저장을 외부 충돌로 오인하지 않게 하는 bounded latch.
    /// 첫 exact-path event가 소비하거나 grace tick이 만료하며 workspace에는 저장하지 않는다.
    self_write_grace_ticks: u16 = 0,
    self_write_hash: u64 = 0,
    self_write_verifications: u8 = 0,
    /// FP3 runtime handle. workspace.v1에는 저장하지 않고 복원/재소환 때 앱 전역 allocator에서 새 id를 발급한다.
    surface_id: u64 = 0,
    /// FP6 live-view LRU clock. workspace에는 저장하지 않는 런타임 값이며 값이 작을수록 오래 안 본 entry다.
    last_seen: u64 = 0,
};

/// workspace.v1에 들어가는 entry 부분집합. dirty는 파일 내용이 아니라 휘발성 편집 상태라 의도적으로 빠진다.
pub const PersistedEntry = struct {
    path: []const u8,
    kind: EntryKind,
    mode: Mode = .read,
    active: bool = false,
};

pub const PersistedGroup = struct {
    entries: []const PersistedEntry = &.{},
};

/// FP8 다중 그룹 split tree의 preorder DTO. terminal pane tree와 같은 full-binary/self-delimiting 규칙을 쓰되
/// leaf는 `PersistedState.groups` 인덱스를 가리킨다. ratio는 결정적 텍스트 왕복을 위해 천분율로 저장한다.
pub const PersistedTreeNode = union(enum) {
    leaf: usize,
    split: Split,

    pub const Split = struct {
        direction: split_tree.SplitDirection,
        ratio_milli: u16,
    };
};

/// 단일 그룹은 기존 `entries`만 써 byte-compatible하게 유지한다. FP8 다중 그룹만 `groups/tree/focused_group`을
/// 채운다. 두 표현을 동시에 허용하지 않아 reader/writer가 어느 트리를 복원할지 모호해지지 않게 한다.
pub const PersistedState = struct {
    side: Side = .right,
    size: u32 = 0,
    /// project tree 열 폭(pt). 0은 현재 폰트 기준 기본 18셀을 뜻한다. 실제 배치는 editor 최소 28셀·tree 최소
    /// 12셀로 clamp하며, 창이 좁으면 tree를 숨긴다.
    tree_size: u32 = 0,
    collapsed: bool = false,
    entries: []const PersistedEntry = &.{},
    groups: []const PersistedGroup = &.{},
    tree: []const PersistedTreeNode = &.{},
    focused_group: usize = 0,
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
    tree_size: u32 = 0,
    collapsed: bool = false,
    focused_group: *DockGroup,

    pub fn init(allocator: std.mem.Allocator) !DockPanel {
        const group = try allocator.create(DockGroup);
        group.* = DockGroup.init(allocator);
        return .{ .allocator = allocator, .tree = .{ .leaf = group }, .focused_group = group };
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

    pub fn singleGroupConst(self: *const DockPanel) ?*const DockGroup {
        return switch (self.tree) {
            .leaf => |group| group,
            .split => null,
        };
    }

    pub fn entryCountTotal(self: *const DockPanel) usize {
        return entryCount(self.tree);
    }

    pub fn groupCount(self: *const DockPanel) usize {
        return DockTree.leafCount(self.tree);
    }

    pub fn focusedGroup(self: *DockPanel) *DockGroup {
        return self.focused_group;
    }

    pub fn focusedGroupConst(self: *const DockPanel) *const DockGroup {
        return self.focused_group;
    }

    pub fn focusGroup(self: *DockPanel, group: *DockGroup) bool {
        if (!containsGroup(self.tree, group)) return false;
        self.focused_group = group;
        return true;
    }

    /// preorder group index. workspace serialization과 L4 scratch layout이 같은 안정된 순서를 공유한다.
    pub fn groupAt(self: *DockPanel, index: usize) ?*DockGroup {
        var cursor: usize = 0;
        return groupAtIndex(self.tree, index, &cursor);
    }

    pub fn groupAtConst(self: *const DockPanel, index: usize) ?*const DockGroup {
        var cursor: usize = 0;
        return groupAtIndexConst(self.tree, index, &cursor);
    }

    pub fn groupIndex(self: *const DockPanel, target: *const DockGroup) ?usize {
        var cursor: usize = 0;
        return indexOfGroup(self.tree, target, &cursor);
    }

    pub fn groupForSurfaceId(self: *DockPanel, surface_id: u64) ?*DockGroup {
        if (surface_id == 0) return null;
        return findGroupForSurfaceId(self.tree, surface_id);
    }

    /// runtime surface id로 파일 entry를 찾는다. FP8 다중 그룹에서도 같은 API가 재귀 tree 전체를 찾는다.
    pub fn entryForSurfaceId(self: *DockPanel, surface_id: u64) ?*Entry {
        if (surface_id == 0) return null;
        return findSurfaceId(self.tree, surface_id);
    }

    pub const OpenResult = struct {
        group: *DockGroup,
        index: usize,
        created: bool,
        previous_active: ?usize,
    };

    pub const PathLocation = struct { group: *DockGroup, index: usize };

    pub fn pathLocation(self: *DockPanel, path: []const u8) ?PathLocation {
        return findPath(self.tree, path);
    }

    /// 경로 유일성은 그룹이 아니라 창 도크 전체 불변식이다. FP8 분할 뒤에도 같은 파일을 다른 그룹 target으로 다시
    /// 열면 원래 entry를 활성화하고 그 group/index를 돌려 UI가 해당 그룹에 focus를 옮길 수 있게 한다.
    pub fn open(self: *DockPanel, target: *DockGroup, path: []const u8, kind: EntryKind) !OpenResult {
        if (path.len == 0) return error.InvalidPath;
        if (!containsGroup(self.tree, target)) return error.GroupNotFound;
        if (findPath(self.tree, path)) |found| {
            const previous_active = found.group.active;
            found.group.active = found.index;
            self.focused_group = found.group;
            return .{ .group = found.group, .index = found.index, .created = false, .previous_active = previous_active };
        }
        if (entryCount(self.tree) >= max_entries) return error.TooManyEntries;
        const previous_active = target.active;
        const index = try target.openLocal(path, kind);
        self.focused_group = target;
        return .{ .group = target, .index = index, .created = true, .previous_active = previous_active };
    }

    fn containsGroup(node: DockTree.Node, target: *DockGroup) bool {
        return switch (node) {
            .leaf => |group| group == target,
            .split => |sp| containsGroup(sp.a, target) or containsGroup(sp.b, target),
        };
    }

    fn findPath(node: DockTree.Node, path: []const u8) ?PathLocation {
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

    fn groupAtIndex(node: DockTree.Node, target_index: usize, cursor: *usize) ?*DockGroup {
        return switch (node) {
            .leaf => |group| blk: {
                const current = cursor.*;
                cursor.* += 1;
                break :blk if (current == target_index) group else null;
            },
            .split => |sp| groupAtIndex(sp.a, target_index, cursor) orelse groupAtIndex(sp.b, target_index, cursor),
        };
    }

    fn groupAtIndexConst(node: DockTree.Node, target_index: usize, cursor: *usize) ?*const DockGroup {
        return switch (node) {
            .leaf => |group| blk: {
                const current = cursor.*;
                cursor.* += 1;
                break :blk if (current == target_index) group else null;
            },
            .split => |sp| groupAtIndexConst(sp.a, target_index, cursor) orelse groupAtIndexConst(sp.b, target_index, cursor),
        };
    }

    fn indexOfGroup(node: DockTree.Node, target: *const DockGroup, cursor: *usize) ?usize {
        return switch (node) {
            .leaf => |group| blk: {
                const current = cursor.*;
                cursor.* += 1;
                break :blk if (group == target) current else null;
            },
            .split => |sp| indexOfGroup(sp.a, target, cursor) orelse indexOfGroup(sp.b, target, cursor),
        };
    }

    fn firstGroup(node: DockTree.Node) *DockGroup {
        return switch (node) {
            .leaf => |group| group,
            .split => |sp| firstGroup(sp.a),
        };
    }

    fn findSurfaceId(node: DockTree.Node, surface_id: u64) ?*Entry {
        return switch (node) {
            .leaf => |group| blk: {
                for (group.entries.items) |*entry| {
                    if (entry.surface_id == surface_id) break :blk entry;
                }
                break :blk null;
            },
            .split => |sp| findSurfaceId(sp.a, surface_id) orelse findSurfaceId(sp.b, surface_id),
        };
    }

    fn findGroupForSurfaceId(node: DockTree.Node, surface_id: u64) ?*DockGroup {
        return switch (node) {
            .leaf => |group| blk: {
                for (group.entries.items) |entry| if (entry.surface_id == surface_id) break :blk group;
                break :blk null;
            },
            .split => |sp| findGroupForSurfaceId(sp.a, surface_id) orelse findGroupForSurfaceId(sp.b, surface_id),
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
        self.focused_group = group;
        return group;
    }

    /// 마지막 그룹은 도크 모델의 루트이므로 제거하지 않는다. 중첩 leaf 제거 시 SplitTree가 돌려준 split 노드를
    /// 호출자가 정확히 한 번 destroy하고, 제거된 그룹의 entry/path도 함께 정리한다.
    pub fn removeGroup(self: *DockPanel, target: *DockGroup) bool {
        const freed = DockTree.removeLeaf(&self.tree, target) orelse return false;
        const was_focused = self.focused_group == target;
        target.deinit();
        self.allocator.destroy(target);
        self.allocator.destroy(freed);
        if (was_focused) self.focused_group = firstGroup(self.tree);
        return true;
    }

    /// workspace.v1 DTO에서 라이브 소유 모델을 복구한다. 단일 그룹 legacy 표현과 FP8 preorder 표현은 상호 배타다.
    /// dirty/runtime handle은 persisted DTO에 없으므로 항상 초기값으로 돌아온다.
    pub fn restore(allocator: std.mem.Allocator, state: PersistedState) !DockPanel {
        if (state.entries.len > max_entries or state.groups.len > max_groups) return error.InvalidPersistedState;
        if (state.groups.len != 0 and state.entries.len != 0) return error.InvalidPersistedState;
        var panel = try DockPanel.init(allocator);
        errdefer panel.deinit();
        panel.side = state.side;
        panel.size = state.size;
        panel.tree_size = state.tree_size;
        panel.collapsed = state.collapsed;

        if (state.groups.len != 0) {
            if (state.tree.len != state.groups.len * 2 - 1 or state.focused_group >= state.groups.len) return error.InvalidPersistedState;

            const groups = try allocator.alloc(*DockGroup, state.groups.len);
            defer allocator.free(groups);
            var initialized: usize = 0;
            errdefer for (groups[0..initialized]) |group| {
                group.deinit();
                allocator.destroy(group);
            };
            var total_entries: usize = 0;
            for (state.groups, 0..) |persisted_group, group_index| {
                total_entries = std.math.add(usize, total_entries, persisted_group.entries.len) catch return error.InvalidPersistedState;
                if (total_entries > max_entries) return error.InvalidPersistedState;
                const group = try allocator.create(DockGroup);
                group.* = DockGroup.init(allocator);
                groups[group_index] = group;
                initialized += 1;
                try restoreEntries(group, persisted_group.entries);
                for (groups[0..group_index]) |prior_group| {
                    for (group.entries.items) |entry| if (prior_group.findPath(entry.path) != null) return error.InvalidPersistedState;
                }
            }

            const seen = try allocator.alloc(bool, groups.len);
            defer allocator.free(seen);
            @memset(seen, false);
            var node_index: usize = 0;
            const new_tree = try restoreTree(allocator, state.tree, &node_index, groups, seen);
            errdefer DockTree.deinit(allocator, new_tree);
            if (node_index != state.tree.len) return error.InvalidPersistedState;
            for (seen) |value| if (!value) return error.InvalidPersistedState;

            const old_group = panel.singleGroup().?;
            old_group.deinit();
            allocator.destroy(old_group);
            panel.tree = new_tree;
            panel.focused_group = groups[state.focused_group];
            initialized = 0; // ownership moved into panel.tree
            return panel;
        }

        if (state.tree.len != 0) return error.InvalidPersistedState;
        const group = panel.singleGroup().?;
        try restoreEntries(group, state.entries);
        panel.focused_group = group;
        return panel;
    }

    fn restoreEntries(group: *DockGroup, entries: []const PersistedEntry) !void {
        var active: ?usize = null;
        for (entries) |entry| {
            if (entry.path.len == 0 or group.findPath(entry.path) != null) return error.InvalidPersistedState;
            const i = try group.openLocal(entry.path, entry.kind);
            group.entries.items[i].mode = entry.mode;
            group.entries.items[i].dirty = false;
            if (entry.active) {
                if (active != null) return error.InvalidPersistedState;
                active = i;
            }
        }
        if (entries.len > 0 and active == null) return error.InvalidPersistedState;
        group.active = active;
    }

    fn restoreTree(
        allocator: std.mem.Allocator,
        nodes: []const PersistedTreeNode,
        index: *usize,
        groups: []const *DockGroup,
        seen: []bool,
    ) !DockTree.Node {
        if (index.* >= nodes.len) return error.InvalidPersistedState;
        const node = nodes[index.*];
        index.* += 1;
        return switch (node) {
            .leaf => |group_index| blk: {
                if (group_index >= groups.len or seen[group_index]) return error.InvalidPersistedState;
                seen[group_index] = true;
                break :blk .{ .leaf = groups[group_index] };
            },
            .split => |persisted_split| blk: {
                if (persisted_split.ratio_milli < 50 or persisted_split.ratio_milli > 950) return error.InvalidPersistedState;
                const a = try restoreTree(allocator, nodes, index, groups, seen);
                errdefer DockTree.deinit(allocator, a);
                const b = try restoreTree(allocator, nodes, index, groups, seen);
                errdefer DockTree.deinit(allocator, b);
                const split = try allocator.create(DockTree.Split);
                split.* = .{
                    .direction = persisted_split.direction,
                    .ratio = @as(f32, @floatFromInt(persisted_split.ratio_milli)) / 1000.0,
                    .a = a,
                    .b = b,
                };
                break :blk .{ .split = split };
            },
        };
    }

    /// 단일 그룹은 legacy entries, 다중 그룹은 preorder groups/tree로 투영한다. path bytes는 계속 DockPanel
    /// 소유이고 DTO 컨테이너만 `freePersistedState`가 해제한다.
    pub fn persistedState(self: *DockPanel, allocator: std.mem.Allocator) !PersistedState {
        if (self.singleGroup()) |group| {
            const entries = try persistEntries(allocator, group);
            return .{ .side = self.side, .size = self.size, .tree_size = self.tree_size, .collapsed = self.collapsed, .entries = entries };
        }

        const group_count = self.groupCount();
        if (group_count > max_groups) return error.InvalidPersistedState;
        const groups = try allocator.alloc(PersistedGroup, group_count);
        errdefer allocator.free(groups);
        var completed: usize = 0;
        errdefer for (groups[0..completed]) |group| if (group.entries.len > 0) allocator.free(group.entries);
        for (groups, 0..) |*persisted_group, index| {
            const group = self.groupAt(index) orelse return error.InvalidPersistedState;
            persisted_group.* = .{ .entries = try persistEntries(allocator, group) };
            completed += 1;
        }
        if (entryCount(self.tree) > max_entries) return error.InvalidPersistedState;
        const nodes = try allocator.alloc(PersistedTreeNode, group_count * 2 - 1);
        errdefer allocator.free(nodes);
        var node_index: usize = 0;
        try persistTree(self, self.tree, nodes, &node_index);
        if (node_index != nodes.len) return error.InvalidPersistedState;
        const focused_group = self.groupIndex(self.focused_group) orelse return error.InvalidPersistedState;
        return .{
            .side = self.side,
            .size = self.size,
            .tree_size = self.tree_size,
            .collapsed = self.collapsed,
            .groups = groups,
            .tree = nodes,
            .focused_group = focused_group,
        };
    }

    fn persistEntries(allocator: std.mem.Allocator, group: *const DockGroup) ![]PersistedEntry {
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
        return entries;
    }

    fn persistTree(self: *const DockPanel, node: DockTree.Node, out: []PersistedTreeNode, index: *usize) !void {
        if (index.* >= out.len) return error.InvalidPersistedState;
        switch (node) {
            .leaf => |group| {
                out[index.*] = .{ .leaf = self.groupIndex(group) orelse return error.InvalidPersistedState };
                index.* += 1;
            },
            .split => |split| {
                const ratio_milli: u16 = @intFromFloat(@round(split_tree.clampRatio(split.ratio) * 1000.0));
                out[index.*] = .{ .split = .{ .direction = split.direction, .ratio_milli = ratio_milli } };
                index.* += 1;
                try persistTree(self, split.a, out, index);
                try persistTree(self, split.b, out, index);
            },
        }
    }
};

pub fn freePersistedState(allocator: std.mem.Allocator, state: *PersistedState) void {
    if (state.entries.len > 0) allocator.free(state.entries);
    for (state.groups) |group| if (group.entries.len > 0) allocator.free(group.entries);
    if (state.groups.len > 0) allocator.free(state.groups);
    if (state.tree.len > 0) allocator.free(state.tree);
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

test "dock panel: entryForSurfaceId searches nested groups and rejects zero" {
    var panel = try DockPanel.init(std.testing.allocator);
    defer panel.deinit();
    const first = panel.singleGroup().?;
    _ = try panel.open(first, "/tmp/a.md", .markdown);
    first.entries.items[0].surface_id = 41;
    const second = try panel.splitGroup(first, .horizontal, 0.5);
    _ = try panel.open(second, "/tmp/b.md", .markdown);
    second.entries.items[0].surface_id = 42;

    try std.testing.expect(panel.entryForSurfaceId(0) == null);
    try std.testing.expect(panel.entryForSurfaceId(99) == null);
    try std.testing.expectEqualStrings("/tmp/a.md", panel.entryForSurfaceId(41).?.path);
    try std.testing.expectEqualStrings("/tmp/b.md", panel.entryForSurfaceId(42).?.path);
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
        .tree_size = 190,
        .collapsed = true,
        .entries = &entries,
    });
    defer panel.deinit();

    const group = panel.singleGroup().?;
    try std.testing.expectEqual(Side.bottom, panel.side);
    try std.testing.expectEqual(@as(u32, 360), panel.size);
    try std.testing.expectEqual(@as(u32, 190), panel.tree_size);
    try std.testing.expect(panel.collapsed);
    try std.testing.expectEqual(@as(?usize, 0), group.active);
    try std.testing.expectEqual(Mode.source_edit, group.entries.items[0].mode);
    try std.testing.expect(!group.entries.items[0].dirty);
    try std.testing.expect(!group.entries.items[1].dirty);
}

test "dock panel: live state exports legacy single group and FP8 multi-group preorder DTO" {
    var panel = try DockPanel.init(std.testing.allocator);
    defer panel.deinit();
    panel.side = .bottom;
    panel.size = 480;
    panel.tree_size = 210;

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
    try std.testing.expectEqual(@as(u32, 210), state.tree_size);
    try std.testing.expectEqual(@as(usize, 2), state.entries.len);
    try std.testing.expectEqualStrings("/tmp/a.md", state.entries[0].path);
    try std.testing.expectEqual(Mode.source_edit, state.entries[0].mode);
    try std.testing.expect(state.entries[0].active);
    try std.testing.expect(!state.entries[1].active);

    const second = try panel.splitGroup(group, .horizontal, 0.5);
    _ = try panel.open(second, "/tmp/c.md", .markdown);
    var split_state = try panel.persistedState(std.testing.allocator);
    defer freePersistedState(std.testing.allocator, &split_state);
    try std.testing.expectEqual(@as(usize, 0), split_state.entries.len);
    try std.testing.expectEqual(@as(usize, 2), split_state.groups.len);
    try std.testing.expectEqual(@as(usize, 3), split_state.tree.len);
    try std.testing.expectEqual(@as(usize, 1), split_state.focused_group);
    try std.testing.expectEqual(@as(u32, 210), split_state.tree_size);
    try std.testing.expectEqual(split_tree.SplitDirection.horizontal, split_state.tree[0].split.direction);
    try std.testing.expectEqual(@as(u16, 500), split_state.tree[0].split.ratio_milli);
    try std.testing.expectEqual(@as(usize, 0), split_state.tree[1].leaf);
    try std.testing.expectEqual(@as(usize, 1), split_state.tree[2].leaf);
    try std.testing.expect(panel.removeGroup(second));

    group.active = 99;
    try std.testing.expectError(error.InvalidPersistedState, panel.persistedState(std.testing.allocator));

    const ambiguous = [_]PersistedEntry{
        .{ .path = "/tmp/a.md", .kind = .markdown, .active = false },
    };
    try std.testing.expectError(error.InvalidPersistedState, DockPanel.restore(std.testing.allocator, .{ .entries = &ambiguous }));
}

test "dock panel: nested multi-group persistence restores focus entries and split ratios" {
    var panel = try DockPanel.init(std.testing.allocator);
    defer panel.deinit();
    const a = panel.singleGroup().?;
    _ = try panel.open(a, "/tmp/a.md", .markdown);
    const b = try panel.splitGroup(a, .horizontal, 0.4);
    _ = try panel.open(b, "/tmp/b.html", .html);
    const c = try panel.splitGroup(b, .vertical, 0.7);
    _ = try panel.open(c, "/tmp/c.md", .markdown);
    b.entries.items[0].mode = .source_edit;
    try std.testing.expectEqual(c, panel.focusedGroup());

    var state = try panel.persistedState(std.testing.allocator);
    defer freePersistedState(std.testing.allocator, &state);
    var restored = try DockPanel.restore(std.testing.allocator, state);
    defer restored.deinit();

    try std.testing.expectEqual(@as(usize, 3), restored.groupCount());
    try std.testing.expectEqualStrings("/tmp/a.md", restored.groupAt(0).?.entries.items[0].path);
    try std.testing.expectEqual(Mode.source_edit, restored.groupAt(1).?.entries.items[0].mode);
    try std.testing.expectEqualStrings("/tmp/c.md", restored.groupAt(2).?.entries.items[0].path);
    try std.testing.expectEqual(restored.groupAt(2).?, restored.focusedGroup());
    try std.testing.expect(!restored.groupAt(1).?.entries.items[0].dirty);

    var roundtrip = try restored.persistedState(std.testing.allocator);
    defer freePersistedState(std.testing.allocator, &roundtrip);
    try std.testing.expectEqual(@as(u16, 400), roundtrip.tree[0].split.ratio_milli);
    try std.testing.expectEqual(@as(u16, 700), roundtrip.tree[2].split.ratio_milli);
}

test "dock panel: multi-group restore rejects duplicate path and duplicate leaf" {
    const a_entries = [_]PersistedEntry{.{ .path = "/tmp/a.md", .kind = .markdown, .active = true }};
    const b_entries = [_]PersistedEntry{.{ .path = "/tmp/a.md", .kind = .markdown, .active = true }};
    const groups = [_]PersistedGroup{ .{ .entries = &a_entries }, .{ .entries = &b_entries } };
    const tree = [_]PersistedTreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .leaf = 0 },
        .{ .leaf = 1 },
    };
    try std.testing.expectError(error.InvalidPersistedState, DockPanel.restore(std.testing.allocator, .{ .groups = &groups, .tree = &tree }));

    const distinct_b = [_]PersistedEntry{.{ .path = "/tmp/b.md", .kind = .markdown, .active = true }};
    const distinct_groups = [_]PersistedGroup{ .{ .entries = &a_entries }, .{ .entries = &distinct_b } };
    const duplicate_leaf = [_]PersistedTreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .leaf = 0 },
        .{ .leaf = 0 },
    };
    try std.testing.expectError(error.InvalidPersistedState, DockPanel.restore(std.testing.allocator, .{ .groups = &distinct_groups, .tree = &duplicate_leaf }));
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
