//! 파일 도크 FP7의 OS-중립 트리 모델. 디렉터리 열거/FSEvents는 L4가 백그라운드에서 수행하고,
//! 이 모듈은 완성된 snapshot·접힘·멀티루트·최근 파일·렌더 row만 소유한다. 따라서 render tick은
//! 디스크를 읽지 않고 `rows`만 소비한다(docs/file-panel.md §7).

const std = @import("std");
const file_panel_bridge = @import("file_panel_bridge.zig");

/// 디렉터리 경로와 자식 이름을 **`/`로** 잇는다.
///
/// L2(session)의 경로 계약은 POSIX다 — 절대 경로는 선행 `/`, 구분자는 `/`이고, 다른 L2 코드(`file_panel_bridge`)는
/// 입력에 역슬래시가 있으면 아예 거부한다. 그런데 `std.fs.path.join`은 **호스트 native** 구분자를 쓴다: Windows
/// 호스트에서는 같은 트리가 `/repo` + `docs` → `/repo\docs`가 돼, `recordOpened`가 `/`로 쪼개 기억해 둔 확장 자식과
/// 문자열이 어긋나고 lazy scan 요청이 조용히 사라진다(실측: Windows에서 이 테스트가 null panic).
/// **규칙: L2에서 구분자를 만들어 내는 자리는 항상 POSIX 구분자를 쓴다.** 구분자를 *읽는* 쪽(`isAbsolute`·`dirname`·
/// `basename`)은 Windows 구현도 `/`를 함께 받아들이므로 그대로 둔다. macOS/Linux에서는 native == posix라 무변화다.
fn joinPosix(allocator: std.mem.Allocator, directory_path: []const u8, name: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, directory_path, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed, name });
}

pub const max_roots: usize = 256; // DockPanel metadata 상한과 동일 — 열린 파일마다 서로 다른 root여도 bounded.
pub const max_recent: usize = 32;
pub const max_children_per_directory: usize = 4096;
pub const max_materialized_nodes: usize = 16 * 1024;
pub const scan_queue_capacity: usize = 1024;
pub const watcher_debounce_ms: u32 = 200;

/// Zed `file_scan_exclusions` 기본값을 베이스로 한 metadata/OS 잡음 목록. 일반 dotfile·`.github`는
/// 숨기지 않는다. 대소문자 비교는 macOS 기본 파일시스템 관례에 맞춰 ASCII-insensitive다.
pub const default_exclusions = [_][]const u8{
    ".git", ".svn", ".hg", ".jj", "CVS", ".DS_Store", "Thumbs.db", ".classpath", ".settings",
};

pub const Kind = enum(u8) {
    file,
    directory,
    symlink_file,
    symlink_directory,
    other,

    pub fn isDirectory(self: Kind) bool {
        return self == .directory or self == .symlink_directory;
    }

    pub fn isSymlink(self: Kind) bool {
        return self == .symlink_file or self == .symlink_directory;
    }
};

pub const EntryInput = struct {
    name: []const u8,
    kind: Kind,
    identity: ?Identity = null,
};

pub const IdentityKind = enum(u8) { regular = 1, directory = 2, symlink = 3, other = 4 };
pub const Identity = struct {
    device: u64,
    inode: u64,
    kind: u8,

    pub fn eql(self: Identity, other: Identity) bool {
        return self.device == other.device and self.inode == other.inode and self.kind == other.kind;
    }
};

pub const RootMode = enum(u8) { inferred, explicit };

pub const RootCapability = struct {
    path: []const u8,
    identity: Identity,
};

pub const OpenState = struct {
    path: []const u8,
    active: bool = false,
    dirty: bool = false,
    external_change: bool = false,
};

pub const Row = union(enum) {
    recent_header: struct { collapsed: bool, count: u8, icon_kind: u8 = 0 },
    recent_file: FileRow,
    root: struct { path: []const u8, label: []const u8, expanded: bool, loading: bool, identity: ?Identity = null, icon_kind: u8 = 0 },
    directory: DirectoryRow,
    file: FileRow,
    empty: void,

    pub const DirectoryRow = struct {
        path: []const u8,
        label: []const u8,
        depth: u16,
        expanded: bool,
        loading: bool,
        symlink: bool,
        identity: ?Identity = null,
        icon_kind: u8 = 0,
    };

    pub const FileRow = struct {
        path: []const u8,
        label: []const u8,
        depth: u16,
        supported: bool,
        open: bool,
        active: bool,
        dirty: bool,
        external_change: bool,
        symlink: bool,
        identity: ?Identity = null,
        icon_kind: u8 = 0,
    };
};

/// L3 classifier result stored on the immutable row snapshot without importing the upper layer.
/// Zero means unclassified/none; AppSession annotates every newly projected row exactly once.
pub fn rowIconKind(row: Row) u8 {
    return switch (row) {
        .recent_header => |v| v.icon_kind,
        .recent_file => |v| v.icon_kind,
        .root => |v| v.icon_kind,
        .directory => |v| v.icon_kind,
        .file => |v| v.icon_kind,
        .empty => 0,
    };
}

/// 렌더 row의 위치와 분리된 transient selection identity. async scan·접기·watcher rebuild 뒤에도
/// 같은 대상이면 선택을 복원할 수 있도록 path와 의미 종류만 사용한다. `path`는 Row/Tree가 소유한 borrowed slice다.
pub const RowKind = enum(u8) { recent_header, recent_file, root, directory, file };

pub const RowIdentity = struct {
    kind: RowKind,
    path: []const u8,

    pub fn eql(self: RowIdentity, other: RowIdentity) bool {
        return self.kind == other.kind and std.mem.eql(u8, self.path, other.path);
    }
};

pub fn rowIdentity(row: Row) ?RowIdentity {
    return switch (row) {
        .recent_header => .{ .kind = .recent_header, .path = "" },
        .recent_file => |v| .{ .kind = .recent_file, .path = v.path },
        .root => |v| .{ .kind = .root, .path = v.path },
        .directory => |v| .{ .kind = .directory, .path = v.path },
        .file => |v| .{ .kind = .file, .path = v.path },
        .empty => null,
    };
}

pub fn rowDepth(row: Row) ?u16 {
    return switch (row) {
        .recent_header, .root => 0,
        .recent_file => |v| v.depth,
        .directory => |v| v.depth,
        .file => |v| v.depth,
        .empty => null,
    };
}

pub fn findIdentity(rows: []const Row, wanted: RowIdentity) ?usize {
    for (rows, 0..) |row, index| if (rowIdentity(row)) |identity| {
        if (identity.eql(wanted)) return index;
    };
    return null;
}

/// `index`의 논리 부모. project row는 앞쪽의 첫 얕은 project row, recent file은 recent header다.
pub fn parentIndex(rows: []const Row, index: usize) ?usize {
    if (index >= rows.len) return null;
    const identity = rowIdentity(rows[index]) orelse return null;
    if (identity.kind == .recent_file) {
        var i = index;
        while (i > 0) {
            i -= 1;
            if (rows[i] == .recent_header) return i;
        }
        return null;
    }
    if (identity.kind == .recent_header or identity.kind == .root) return null;
    const depth = rowDepth(rows[index]) orelse return null;
    var i = index;
    while (i > 0) {
        i -= 1;
        const candidate = rowIdentity(rows[i]) orelse continue;
        if (candidate.kind == .recent_header or candidate.kind == .recent_file) continue;
        const candidate_depth = rowDepth(rows[i]) orelse continue;
        if (candidate_depth < depth) return i;
    }
    return null;
}

/// 펼쳐진 directory/root 또는 recent header 바로 아래의 첫 자식. 다음 row가 더 깊거나 recent file일 때만 인정한다.
pub fn firstChildIndex(rows: []const Row, index: usize) ?usize {
    if (index >= rows.len or index + 1 >= rows.len) return null;
    const identity = rowIdentity(rows[index]) orelse return null;
    return switch (identity.kind) {
        .recent_header => if (rows[index + 1] == .recent_file) index + 1 else null,
        .root, .directory => blk: {
            const depth = rowDepth(rows[index]) orelse break :blk null;
            const next_identity = rowIdentity(rows[index + 1]) orelse break :blk null;
            if (next_identity.kind == .recent_header or next_identity.kind == .recent_file) break :blk null;
            const next_depth = rowDepth(rows[index + 1]) orelse break :blk null;
            break :blk if (next_depth > depth) index + 1 else null;
        },
        else => null,
    };
}

pub fn adjacentActionable(rows: []const Row, index: usize, direction: i8) ?usize {
    if (rows.len == 0 or direction == 0) return null;
    if (direction > 0) {
        var i = @min(index +| 1, rows.len);
        while (i < rows.len) : (i += 1) if (rowIdentity(rows[i]) != null) return i;
    } else {
        var i = @min(index, rows.len);
        while (i > 0) {
            i -= 1;
            if (rowIdentity(rows[i]) != null) return i;
        }
    }
    return null;
}

/// rebuild에서 identity가 사라졌을 때 조작 가능한 조상, 이전 위치의 다음 행, 이전 행 순으로 결정한다.
pub fn reconcileIdentity(rows: []const Row, wanted: RowIdentity, previous_index: usize) ?usize {
    return reconcileIdentityCounted(rows, wanted, previous_index, null);
}

fn reconcileIdentityCounted(rows: []const Row, wanted: RowIdentity, previous_index: usize, visits_out: ?*usize) ?usize {
    var deepest_ancestor: ?usize = null;
    var deepest_ancestor_len: usize = 0;
    var recent_header: ?usize = null;
    var next_neighbor: ?usize = null;
    var previous_neighbor: ?usize = null;
    var visits: usize = 0;
    defer {
        if (visits_out) |out| out.* = visits;
    }

    // exact·조상·이웃을 같은 순회에서 모아 frame-tick rebuild 비용을 O(materialized rows)로 고정한다.
    for (rows, 0..) |row, index| {
        visits += 1;
        const identity = rowIdentity(row) orelse continue;
        if (identity.eql(wanted)) return index;
        if (identity.kind == .recent_header) recent_header = index;
        if (index >= previous_index) {
            if (next_neighbor == null) next_neighbor = index;
        } else {
            previous_neighbor = index;
        }
        if (wanted.kind != .recent_file and wanted.path.len > 0 and
            (identity.kind == .root or identity.kind == .directory) and
            identity.path.len < wanted.path.len and pathWithin(wanted.path, identity.path) and
            identity.path.len > deepest_ancestor_len)
        {
            deepest_ancestor = index;
            deepest_ancestor_len = identity.path.len;
        }
    }
    if (wanted.kind == .recent_file and recent_header != null) return recent_header;
    return deepest_ancestor orelse next_neighbor orelse previous_neighbor;
}

const Node = struct {
    name: []u8,
    path: []u8,
    kind: Kind,
    identity: ?Identity = null,
    children: std.ArrayList(Node) = .empty,
    loaded: bool = false,
    expanded: bool = false,
    loading: bool = false,

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| child.deinit(allocator);
        self.children.deinit(allocator);
        allocator.free(self.name);
        allocator.free(self.path);
        self.* = undefined;
    }

    fn clone(self: *const Node, allocator: std.mem.Allocator) !Node {
        var copy: Node = .{
            .name = try allocator.dupe(u8, self.name),
            .path = undefined,
            .kind = self.kind,
            .identity = self.identity,
            .loaded = self.loaded,
            .expanded = self.expanded,
            .loading = self.loading,
        };
        errdefer allocator.free(copy.name);
        copy.path = try allocator.dupe(u8, self.path);
        errdefer allocator.free(copy.path);
        errdefer {
            for (copy.children.items) |*child| child.deinit(allocator);
            copy.children.deinit(allocator);
        }
        try copy.children.ensureTotalCapacity(allocator, self.children.items.len);
        for (self.children.items) |*child| copy.children.appendAssumeCapacity(try child.clone(allocator));
        return copy;
    }
};

/// 렌더 row가 가리키는 경로(헤더·empty row는 null). ET-CWD 스크롤 보정이 "그 경로의 행"을 찾는 데 쓴다.
pub fn rowPath(row: Row) ?[]const u8 {
    return switch (row) {
        .root => |r| r.path,
        .directory => |d| d.path,
        .file => |f| f.path,
        .recent_file => |r| r.path,
        .recent_header, .empty => null,
    };
}

pub const Tree = struct {
    allocator: std.mem.Allocator,
    root_mode: RootMode = .inferred,
    root_generation: u64 = 1,
    roots: std.ArrayList(Node) = .empty,
    recent: std.ArrayList([]u8) = .empty, // oldest → newest; row projection reverses it.
    recent_collapsed: bool = false,
    scan_requests: std.ArrayList([]u8) = .empty,
    watch_requests: std.ArrayList([]u8) = .empty,
    reveal_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) Tree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tree) void {
        for (self.roots.items) |*root| root.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        for (self.recent.items) |path| self.allocator.free(path);
        self.recent.deinit(self.allocator);
        for (self.scan_requests.items) |path| self.allocator.free(path);
        self.scan_requests.deinit(self.allocator);
        for (self.watch_requests.items) |path| self.allocator.free(path);
        self.watch_requests.deinit(self.allocator);
        if (self.reveal_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    /// 루트 교체·파일 열기처럼 여러 L3/L4 상태를 함께 바꾸는 호출자가 실패 가능한 준비를 별도 후보에서
    /// 끝낸 뒤 무실패 swap할 수 있도록 현재 snapshot을 깊은 복제한다. 파일시스템 I/O는 하지 않는다.
    pub fn clone(self: *const Tree) !Tree {
        var copy = Tree.init(self.allocator);
        errdefer copy.deinit();
        copy.root_mode = self.root_mode;
        copy.root_generation = self.root_generation;
        copy.recent_collapsed = self.recent_collapsed;

        try copy.roots.ensureTotalCapacity(self.allocator, self.roots.items.len);
        for (self.roots.items) |*root| copy.roots.appendAssumeCapacity(try root.clone(self.allocator));
        try clonePathList(self.allocator, self.recent.items, &copy.recent);
        try clonePathList(self.allocator, self.scan_requests.items, &copy.scan_requests);
        try clonePathList(self.allocator, self.watch_requests.items, &copy.watch_requests);
        if (self.reveal_path) |path| copy.reveal_path = try self.allocator.dupe(u8, path);
        return copy;
    }

    /// replace/add/remove는 기존 materialized subtree를 곧 버리므로 16K node 전체를 복제하지 않는다.
    /// root metadata(identity 포함)와 recent만 O(root+recent)로 복제하고 모든 root를 lazy rescan한다.
    pub fn cloneForRootTransaction(self: *const Tree) !Tree {
        var copy = Tree.init(self.allocator);
        errdefer copy.deinit();
        copy.root_mode = self.root_mode;
        copy.root_generation = self.root_generation;
        copy.recent_collapsed = self.recent_collapsed;
        try copy.roots.ensureTotalCapacity(self.allocator, self.roots.items.len);
        try copy.scan_requests.ensureTotalCapacity(self.allocator, self.roots.items.len);
        for (self.roots.items) |root| {
            const path = try self.allocator.dupe(u8, root.path);
            errdefer self.allocator.free(path);
            const name = try self.allocator.dupe(u8, root.name);
            errdefer self.allocator.free(name);
            const scan = try self.allocator.dupe(u8, root.path);
            errdefer self.allocator.free(scan);
            copy.roots.appendAssumeCapacity(.{
                .name = name,
                .path = path,
                .kind = .directory,
                .identity = root.identity,
                .expanded = true,
                .loading = true,
            });
            copy.scan_requests.appendAssumeCapacity(scan);
        }
        try clonePathList(self.allocator, self.recent.items, &copy.recent);
        if (self.reveal_path) |path| copy.reveal_path = try self.allocator.dupe(u8, path);
        return copy;
    }

    /// 아직 열거할 project root나 다시 열 수 있는 recent entry가 있는가. L4는 이 값으로 마지막 파일 탭을
    /// 닫은 뒤에도 빈 editor group과 tree를 유지하되, 앱 시작의 완전히 빈 dock은 숨긴다.
    pub fn hasContent(self: *const Tree) bool {
        return self.roots.items.len > 0 or self.recent.items.len > 0;
    }

    pub fn rootMode(self: *const Tree) RootMode {
        return self.root_mode;
    }

    pub fn rootGeneration(self: *const Tree) u64 {
        return self.root_generation;
    }

    pub fn rootCount(self: *const Tree) usize {
        return self.roots.items.len;
    }

    pub fn rootAt(self: *const Tree, index: usize) ?[]const u8 {
        return if (index < self.roots.items.len) self.roots.items[index].path else null;
    }

    /// 파일 행을 열기 직전에 L4가 namespace capability를 재검증할 수 있도록, 해당 path를
    /// 소유하는 가장 구체적인 pinned root를 돌려준다. identity가 아직 없는 inferred/lazy root는
    /// 권한으로 사용할 수 없으므로 fail closed한다.
    pub fn rootCapabilityForPath(self: *const Tree, path: []const u8) ?RootCapability {
        var best: ?RootCapability = null;
        for (self.roots.items) |root| {
            const identity = root.identity orelse continue;
            if (!pathWithin(path, root.path)) continue;
            if (best == null or root.path.len > best.?.path.len) best = .{
                .path = root.path,
                .identity = identity,
            };
        }
        return best;
    }

    /// root picker worker가 canonical directory fd에서 얻은 identity를 publish 후보에 고정한다.
    /// 이후 첫 scan이 같은 path의 교체를 감지하면 snapshot을 적용하지 않는다.
    pub fn pinRootIdentity(self: *Tree, path: []const u8, identity: Identity) bool {
        for (self.roots.items) |*root| {
            if (!std.mem.eql(u8, root.path, path)) continue;
            root.identity = identity;
            return true;
        }
        return false;
    }

    pub fn shouldExcludeName(name: []const u8) bool {
        for (default_exclusions) |excluded| if (std.ascii.eqlIgnoreCase(name, excluded)) return true;
        return false;
    }

    /// 열린 파일에서 platform이 결정한 repo root(없으면 부모)를 합류시키고 MRU를 갱신한다. 새 root는 펼친
    /// 상태로 첫 lazy scan만 예약한다. 실제 readdir는 takeScanRequest를 소비하는 L4 worker가 한다.
    pub fn recordOpened(self: *Tree, file_path: []const u8, root_path: []const u8) !void {
        if (file_path.len == 0 or root_path.len == 0 or !std.fs.path.isAbsolute(file_path) or
            !std.fs.path.isAbsolute(root_path)) return error.InvalidPath;
        const reveal = try self.allocator.dupe(u8, file_path);
        var recent_owned: ?[]u8 = null;
        var recent_index: ?usize = null;
        for (self.recent.items, 0..) |path, i| if (std.mem.eql(u8, path, file_path)) {
            recent_index = i;
            break;
        };
        if (recent_index == null) {
            recent_owned = self.allocator.dupe(u8, file_path) catch |err| {
                self.allocator.free(reveal);
                return err;
            };
        }
        self.recent.ensureUnusedCapacity(self.allocator, 1) catch |err| {
            self.allocator.free(reveal);
            if (recent_owned) |owned| self.allocator.free(owned);
            return err;
        };
        if (self.root_mode == .inferred) self.ensureRoot(root_path) catch |err| {
            self.allocator.free(reveal);
            if (recent_owned) |owned| self.allocator.free(owned);
            return err;
        };
        if (recent_index) |i| {
            const owned = self.recent.orderedRemove(i);
            self.recent.appendAssumeCapacity(owned);
        } else {
            if (self.recent.items.len >= max_recent) self.allocator.free(self.recent.orderedRemove(0));
            self.recent.appendAssumeCapacity(recent_owned.?);
            recent_owned = null;
        }
        if (self.reveal_path) |old| self.allocator.free(old);
        self.reveal_path = reveal;
        self.continueReveal() catch {};
    }

    /// ET-CWD: 이미 있는 root 안의 **디렉터리**를 reveal 대상으로 건다(docs/file-explorer.md §1). 파일 열기가 쓰는
    /// `reveal_path` intent를 그대로 재사용하므로 ancestor 펼치기·lazy scan·intent 종료가 전부 기존 경로다.
    ///
    /// root 밖 경로는 **무동작**이다 — 자동으로 root를 추가하면 `cd ~` 한 번에 홈 전체가 root가 되고
    /// (`explicit` 모드에서는) 사용자가 고른 root를 덮어 영속까지 오염된다(§1의 기각 이유).
    /// 이미 같은 경로를 reveal 중이면 무동작(폴링 관측이 같은 값을 반복해 보내도 재시도가 쌓이지 않게).
    pub const DirectoryReveal = enum {
        /// 경로가 비어 있거나 root 밖이라 Tree 상태를 바꾸지 않았다.
        rejected,
        /// 같은 대상의 기존 intent가 남아 있다. 새 scan은 만들지 않지만 caller는 그 대상의 화면 보정을 할 수 있다.
        already_target,
        /// 새 대상 intent를 받아 ancestor lazy reveal을 시작했다.
        accepted,
    };

    /// 결과는 root 밖 거부와 기존 같은 intent를 구별한다. CWD follow는 후자에서도 그 경로를 viewport로
    /// 보정해야 하지만 전자는 이전 파일-open intent를 새 CWD의 대상으로 오인하면 안 된다.
    pub fn revealDirectory(self: *Tree, path: []const u8) !DirectoryReveal {
        if (path.len == 0 or !std.fs.path.isAbsolute(path)) return .rejected;
        var within = false;
        for (self.roots.items) |root| if (pathWithin(path, root.path)) {
            within = true;
            break;
        };
        if (!within) return .rejected;
        if (self.reveal_path) |cur| if (std.mem.eql(u8, cur, path)) return .already_target;
        const owned = try self.allocator.dupe(u8, path);
        if (self.reveal_path) |old| self.allocator.free(old);
        self.reveal_path = owned;
        self.continueReveal() catch {};
        return .accepted;
    }

    fn ensureRoot(self: *Tree, root_path: []const u8) !void {
        var nested_roots: usize = 0;
        for (self.roots.items) |root| {
            // 가장 짧은 공통 ancestor root만 유지한다. 겹친 root projection은 같은 path+row-kind를 두 번 만들어
            // selection/toggle identity를 모호하게 하므로 child root는 기존 parent에 흡수하고, 새 parent는 child를 대체한다.
            if (pathWithin(root_path, root.path)) return;
            if (pathWithin(root.path, root_path)) nested_roots += 1;
        }
        if (self.roots.items.len - nested_roots >= max_roots) return error.TooManyRoots;
        const owned_path = try self.allocator.dupe(u8, root_path);
        errdefer self.allocator.free(owned_path);
        const owned_name = try self.allocator.dupe(u8, std.fs.path.basename(root_path));
        errdefer self.allocator.free(owned_name);
        const scan_path = try self.allocator.dupe(u8, root_path);
        errdefer self.allocator.free(scan_path);
        const watch_path = try self.allocator.dupe(u8, root_path);
        errdefer self.allocator.free(watch_path);
        try self.roots.ensureUnusedCapacity(self.allocator, 1);
        try self.scan_requests.ensureUnusedCapacity(self.allocator, 1);
        try self.watch_requests.ensureUnusedCapacity(self.allocator, 1);
        var root_i: usize = 0;
        while (root_i < self.roots.items.len) {
            if (!pathWithin(self.roots.items[root_i].path, root_path)) {
                root_i += 1;
                continue;
            }
            var removed = self.roots.orderedRemove(root_i);
            removed.deinit(self.allocator);
        }
        var request_i: usize = 0;
        while (request_i < self.scan_requests.items.len) {
            if (!pathWithin(self.scan_requests.items[request_i], root_path)) {
                request_i += 1;
                continue;
            }
            self.allocator.free(self.scan_requests.orderedRemove(request_i));
        }
        request_i = 0;
        while (request_i < self.watch_requests.items.len) {
            if (!pathWithin(self.watch_requests.items[request_i], root_path)) {
                request_i += 1;
                continue;
            }
            self.allocator.free(self.watch_requests.orderedRemove(request_i));
        }
        self.roots.appendAssumeCapacity(.{
            .name = owned_name,
            .path = owned_path,
            .kind = .directory,
            .expanded = true,
            .loading = true,
        });
        self.scan_requests.appendAssumeCapacity(scan_path);
        self.watch_requests.appendAssumeCapacity(watch_path);
        self.bumpRootGeneration();
    }

    fn bumpRootGeneration(self: *Tree) void {
        self.root_generation +%= 1;
        if (self.root_generation == 0) self.root_generation = 1;
    }

    /// Canonical absolute roots로 explicit snapshot을 원자 교체한다. 기존 expanded snapshot은 root 변경의
    /// correctness 권위가 아니므로 버리고 새 lazy scan을 예약한다.
    pub fn replaceExplicitRoots(self: *Tree, paths: []const []const u8) !void {
        if (paths.len > max_roots) return error.TooManyRoots;
        var staged_roots: std.ArrayList(Node) = .empty;
        var staged_scans: std.ArrayList([]u8) = .empty;
        errdefer {
            for (staged_roots.items) |*root| root.deinit(self.allocator);
            staged_roots.deinit(self.allocator);
            for (staged_scans.items) |path| self.allocator.free(path);
            staged_scans.deinit(self.allocator);
        }
        try staged_roots.ensureTotalCapacity(self.allocator, paths.len);
        try staged_scans.ensureTotalCapacity(self.allocator, paths.len);
        for (paths) |path| {
            if (path.len == 0 or path.len > std.fs.max_path_bytes or !std.fs.path.isAbsolute(path) or
                !std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
            var covered = false;
            for (staged_roots.items) |root| if (pathWithin(path, root.path)) {
                covered = true;
                break;
            };
            if (covered) continue;
            var i: usize = 0;
            while (i < staged_roots.items.len) {
                if (!pathWithin(staged_roots.items[i].path, path)) {
                    i += 1;
                    continue;
                }
                var removed = staged_roots.orderedRemove(i);
                removed.deinit(self.allocator);
                self.allocator.free(staged_scans.orderedRemove(i));
            }
            const owned_path = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned_path);
            const owned_name = try self.allocator.dupe(u8, std.fs.path.basename(path));
            errdefer self.allocator.free(owned_name);
            const scan_path = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(scan_path);
            var preserved_identity: ?Identity = null;
            for (self.roots.items) |root| if (std.mem.eql(u8, root.path, path)) {
                preserved_identity = root.identity;
                break;
            };
            staged_roots.appendAssumeCapacity(.{
                .name = owned_name,
                .path = owned_path,
                .kind = .directory,
                .identity = preserved_identity,
                .expanded = true,
                .loading = true,
            });
            staged_scans.appendAssumeCapacity(scan_path);
        }
        for (self.roots.items) |*root| root.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        for (self.scan_requests.items) |path| self.allocator.free(path);
        self.scan_requests.deinit(self.allocator);
        self.roots = staged_roots;
        self.scan_requests = staged_scans;
        staged_roots = .empty;
        staged_scans = .empty;
        self.root_mode = .explicit;
        self.bumpRootGeneration();
    }

    pub fn addExplicitRoot(self: *Tree, path: []const u8) !void {
        var paths: [max_roots + 1][]const u8 = undefined;
        for (self.roots.items, 0..) |root, i| paths[i] = root.path;
        paths[self.roots.items.len] = path;
        try self.replaceExplicitRoots(paths[0 .. self.roots.items.len + 1]);
    }

    pub fn removeExplicitRoot(self: *Tree, path: []const u8) !bool {
        var paths: [max_roots][]const u8 = undefined;
        var n: usize = 0;
        var found = false;
        for (self.roots.items) |root| {
            if (std.mem.eql(u8, root.path, path)) {
                found = true;
                continue;
            }
            paths[n] = root.path;
            n += 1;
        }
        if (!found) return false;
        try self.replaceExplicitRoots(paths[0..n]);
        return true;
    }

    /// Native watcher를 explorer roots + 열린 entry parents의 canonical union으로 재구성할 one-shot 목록.
    /// 모든 allocation을 stage한 뒤 swap해 OOM이면 기존 native watcher 요청 상태를 보존한다.
    pub fn resetWatchRequests(self: *Tree, extra_roots: []const []const u8) !void {
        var staged: std.ArrayList([]u8) = .empty;
        errdefer {
            for (staged.items) |path| self.allocator.free(path);
            staged.deinit(self.allocator);
        }
        try staged.ensureTotalCapacity(self.allocator, self.roots.items.len + extra_roots.len);
        for (self.roots.items) |root| try appendNormalizedWatchRoot(self.allocator, &staged, root.path);
        for (extra_roots) |path| try appendNormalizedWatchRoot(self.allocator, &staged, path);
        for (self.watch_requests.items) |path| self.allocator.free(path);
        self.watch_requests.deinit(self.allocator);
        self.watch_requests = staged;
        staged = .empty;
    }

    fn appendNormalizedWatchRoot(allocator: std.mem.Allocator, roots: *std.ArrayList([]u8), path: []const u8) !void {
        if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.InvalidPath;
        for (roots.items) |root| if (pathWithin(path, root)) return;
        var i: usize = 0;
        while (i < roots.items.len) {
            if (!pathWithin(roots.items[i], path)) {
                i += 1;
                continue;
            }
            allocator.free(roots.orderedRemove(i));
        }
        roots.appendAssumeCapacity(try allocator.dupe(u8, path));
    }

    fn pushRecent(self: *Tree, file_path: []const u8) !void {
        var found: ?usize = null;
        for (self.recent.items, 0..) |path, i| if (std.mem.eql(u8, path, file_path)) {
            found = i;
            break;
        };
        if (found) |i| {
            const owned = self.recent.orderedRemove(i);
            try self.recent.append(self.allocator, owned);
            return;
        }
        const owned = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(owned);
        if (self.recent.items.len >= max_recent) {
            const dropped = self.recent.orderedRemove(0);
            self.allocator.free(dropped);
        }
        try self.recent.append(self.allocator, owned);
    }

    pub fn toggleRecent(self: *Tree) void {
        self.recent_collapsed = !self.recent_collapsed;
    }

    /// 폴더는 Zed `scan_symlinks=expanded`처럼 사용자가 펼친 시점에만 scan한다. 일반 폴더와 symlink 폴더
    /// 모두 lazy이며, L4가 canonical cycle/root 정책을 적용한 결과만 snapshot으로 돌려준다.
    pub fn toggleDirectory(self: *Tree, path: []const u8) !bool {
        const node = self.findNode(path) orelse return error.NotFound;
        if (!node.kind.isDirectory()) return error.NotDirectory;
        node.expanded = !node.expanded;
        if (node.expanded and !node.loaded and !node.loading) {
            node.loading = true;
            try self.enqueueScan(node.path);
        }
        return node.expanded;
    }

    pub fn invalidatePath(self: *Tree, changed_path: []const u8) !void {
        for (self.roots.items) |*root| {
            if (!pathWithin(changed_path, root.path)) continue;
            const target = deepestExpandedDirectory(root, changed_path) orelse root;
            target.loading = true;
            try self.enqueueScan(target.path);
            return;
        }
    }

    fn enqueueScan(self: *Tree, path: []const u8) !void {
        for (self.scan_requests.items) |queued| if (std.mem.eql(u8, queued, path)) return;
        if (self.scan_requests.items.len >= scan_queue_capacity) {
            // 이벤트를 조용히 drop하면 tree가 영구 stale해진다. overflow는 세부 요청을 버리고 모든 root를
            // 다시 예약하는 coarse recovery로 접는다. root 수 자체가 max_roots로 bounded다.
            for (self.scan_requests.items) |queued| self.allocator.free(queued);
            self.scan_requests.clearRetainingCapacity();
            for (self.roots.items) |root| {
                const owned = try self.allocator.dupe(u8, root.path);
                try self.scan_requests.append(self.allocator, owned);
            }
            return;
        }
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.scan_requests.append(self.allocator, owned);
    }

    /// backend in-flight 상한에 걸린 요청을 다음 tick에 다시 넣는다. 중복 제거·overflow recovery는 최초 요청과 같다.
    pub fn requeueScan(self: *Tree, path: []const u8) !void {
        try self.enqueueScan(path);
    }

    /// 반환 slice 소유권은 호출자에게 이동한다. L4는 background scan 작업에 복사 없이 넘기고 완료 뒤 free한다.
    pub fn takeScanRequest(self: *Tree) ?[]u8 {
        if (self.scan_requests.items.len == 0) return null;
        return self.scan_requests.orderedRemove(0);
    }

    /// A root picker commit transfers its retained directory capability to the exact first scan path.
    /// Removing by bytes keeps other existing roots queued in stable order for multi-root add.
    pub fn takeScanRequestForPath(self: *Tree, path: []const u8) ?[]u8 {
        for (self.scan_requests.items, 0..) |request, index| {
            if (std.mem.eql(u8, request, path)) return self.scan_requests.orderedRemove(index);
        }
        return null;
    }

    /// 새 multi-root만 한 번 반환한다. Swift FSEvents adapter가 복사한 뒤 free한다.
    pub fn takeWatchRequest(self: *Tree) ?[]u8 {
        if (self.watch_requests.items.len == 0) return null;
        return self.watch_requests.orderedRemove(0);
    }

    pub fn peekWatchRequest(self: *const Tree) ?[]const u8 {
        if (self.watch_requests.items.len == 0) return null;
        return self.watch_requests.items[0];
    }

    pub fn containsRootPath(self: *const Tree, path: []const u8) bool {
        for (self.roots.items) |root| if (std.mem.eql(u8, root.path, path)) return true;
        return false;
    }

    /// Deepest project root containing a mutation target. Returned bytes remain Tree-owned.
    pub fn rootForMutation(self: *const Tree, path: []const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        for (self.roots.items) |root| {
            if (!pathWithin(path, root.path)) continue;
            if (best == null or root.path.len > best.?.len) best = root.path;
        }
        return best;
    }

    /// Rename/delete post-commit maintenance for the bounded recent list. Project nodes are refreshed
    /// through the existing background snapshot path; recent paths have no scanner owner, so the model
    /// updates them explicitly and atomically with respect to row projection.
    pub fn remapRecent(self: *Tree, old_prefix: []const u8, new_prefix: []const u8) !void {
        var staged: [max_recent]?[]u8 = .{null} ** max_recent;
        errdefer for (staged) |path| if (path) |owned| self.allocator.free(owned);
        for (self.recent.items, 0..) |path, i| {
            if (!pathWithin(path, old_prefix)) continue;
            staged[i] = try std.mem.concat(self.allocator, u8, &.{ new_prefix, path[old_prefix.len..] });
        }
        for (self.recent.items, 0..) |*path, i| if (staged[i]) |owned| {
            self.allocator.free(path.*);
            path.* = owned;
            staged[i] = null;
        };
    }

    pub fn recentCount(self: *const Tree) usize {
        return self.recent.items.len;
    }

    pub fn recentAt(self: *const Tree, index: usize) ?[]const u8 {
        return if (index < self.recent.items.len) self.recent.items[index] else null;
    }

    /// Caller preallocates the replacement off the completion path. The swap is allocation-free and
    /// rejects a stale index/path so recent and dock can share one rename commit.
    pub fn replaceRecentOwned(self: *Tree, index: usize, expected: []const u8, replacement: []u8) bool {
        if (index >= self.recent.items.len or !std.mem.eql(u8, self.recent.items[index], expected)) return false;
        self.allocator.free(self.recent.items[index]);
        self.recent.items[index] = replacement;
        return true;
    }

    pub fn removeRecentWithin(self: *Tree, removed_prefix: []const u8) void {
        var i: usize = 0;
        while (i < self.recent.items.len) {
            if (!pathWithin(self.recent.items[i], removed_prefix)) {
                i += 1;
                continue;
            }
            self.allocator.free(self.recent.orderedRemove(i));
        }
    }

    pub fn pathWithinRoot(path: []const u8, root: []const u8) bool {
        return pathWithin(path, root);
    }

    pub fn applySnapshot(self: *Tree, directory_path: []const u8, inputs: []const EntryInput) !void {
        return self.applySnapshotWithIdentity(directory_path, null, inputs);
    }

    pub fn applySnapshotWithIdentity(self: *Tree, directory_path: []const u8, identity: ?Identity, inputs: []const EntryInput) !void {
        const node = self.findNode(directory_path) orelse return error.NotFound;
        if (node.identity) |expected| if (identity) |actual| {
            if (!expected.eql(actual)) return error.IdentityMismatch;
        };
        try self.applySnapshotLimited(directory_path, inputs, max_materialized_nodes);
        if (identity) |value| (self.findNode(directory_path) orelse return error.NotFound).identity = value;
    }

    fn applySnapshotLimited(self: *Tree, directory_path: []const u8, inputs: []const EntryInput, node_limit: usize) !void {
        const dir = self.findNode(directory_path) orelse return error.NotFound;
        if (!dir.kind.isDirectory()) return error.NotDirectory;
        var staged: std.ArrayList(Node) = .empty;
        errdefer {
            for (staged.items) |*node| node.deinit(self.allocator);
            staged.deinit(self.allocator);
        }
        try staged.ensureTotalCapacity(self.allocator, @min(inputs.len, max_children_per_directory));
        const replacing_count = countNode(dir.*) - 1;
        const base_count = self.materializedNodeCount() - replacing_count;
        var accepted: usize = 0;
        var staged_node_count: usize = 0;
        for (inputs) |input| {
            if (accepted >= max_children_per_directory) break;
            if (!validBasename(input.name) or shouldExcludeName(input.name)) continue;
            var node_weight: usize = 1;
            for (dir.children.items) |old| {
                if (old.kind == input.kind and std.mem.eql(u8, old.name, input.name)) {
                    node_weight = countNode(old);
                    break;
                }
            }
            const remaining = node_limit -| base_count;
            if (node_weight > remaining -| staged_node_count) continue;
            const name = try self.allocator.dupe(u8, input.name);
            errdefer self.allocator.free(name);
            const path = try joinPosix(self.allocator, directory_path, input.name);
            errdefer self.allocator.free(path);
            staged.appendAssumeCapacity(.{ .name = name, .path = path, .kind = input.kind, .identity = input.identity });
            accepted += 1;
            staged_node_count += node_weight;
        }
        std.mem.sort(Node, staged.items, {}, nodeLessThan);

        // 새 snapshot 할당이 모두 성공한 뒤에만 기존 lazy subtree 상태를 같은 path/kind 노드로 이전한다.
        // 따라서 OOM이면 기존 화면이 그대로고, 성공이면 펼친 폴더가 watcher refresh마다 접히지 않는다.
        for (staged.items) |*next| {
            for (dir.children.items) |*old| {
                if (old.kind != next.kind or !std.mem.eql(u8, old.path, next.path)) continue;
                next.children = old.children;
                old.children = .empty;
                next.loaded = old.loaded;
                next.expanded = old.expanded;
                next.loading = old.loading;
                break;
            }
        }
        for (dir.children.items) |*old| old.deinit(self.allocator);
        dir.children.deinit(self.allocator);
        dir.children = staged;
        dir.loaded = true;
        dir.loading = false;
        self.continueReveal() catch {};
    }

    pub fn failSnapshot(self: *Tree, directory_path: []const u8) void {
        const dir = self.findNode(directory_path) orelse return;
        dir.loading = false;
    }

    pub fn buildRows(self: *const Tree, allocator: std.mem.Allocator, open: []const OpenState, out: *std.ArrayList(Row)) !void {
        out.clearRetainingCapacity();
        if (self.roots.items.len == 0) {
            try out.append(allocator, .{ .empty = {} });
        } else {
            // Artifact 기준: 탐색의 주 대상인 project roots를 먼저, MRU는 보조 섹션으로 맨 아래에 둔다.
            // 최근 파일이 위에서 긴 목록을 차지해 실제 tree를 밀어내던 기존 순서를 뒤집되 Row/클릭 계약은 유지한다.
            for (self.roots.items) |root| {
                try out.append(allocator, .{ .root = .{
                    .path = root.path,
                    .label = if (root.name.len > 0) root.name else root.path,
                    .expanded = root.expanded,
                    .loading = root.loading,
                    .identity = root.identity,
                } });
                if (root.expanded) try appendChildrenRows(allocator, root.children.items, 1, open, out);
            }
        }
        try out.append(allocator, .{ .recent_header = .{
            .collapsed = self.recent_collapsed,
            .count = @intCast(@min(self.recent.items.len, std.math.maxInt(u8))),
        } });
        if (!self.recent_collapsed) {
            var i = self.recent.items.len;
            while (i > 0) {
                i -= 1;
                const path = self.recent.items[i];
                try out.append(allocator, .{ .recent_file = fileRow(path, std.fs.path.basename(path), 1, false, open) });
            }
        }
    }

    fn appendChildrenRows(allocator: std.mem.Allocator, children: []const Node, depth: u16, open: []const OpenState, out: *std.ArrayList(Row)) !void {
        for (children) |node| {
            if (node.kind.isDirectory()) {
                try out.append(allocator, .{ .directory = .{
                    .path = node.path,
                    .label = node.name,
                    .depth = depth,
                    .expanded = node.expanded,
                    .loading = node.loading,
                    .symlink = node.kind.isSymlink(),
                    .identity = node.identity,
                } });
                if (node.expanded) try appendChildrenRows(allocator, node.children.items, depth +| 1, open, out);
            } else {
                var row = fileRow(node.path, node.name, depth, node.kind.isSymlink(), open);
                row.identity = node.identity;
                try out.append(allocator, .{ .file = row });
            }
        }
    }

    fn fileRow(path: []const u8, label: []const u8, depth: u16, symlink: bool, open: []const OpenState) Row.FileRow {
        var result = Row.FileRow{
            .path = path,
            .label = label,
            .depth = depth,
            .supported = supportedFile(path),
            .open = false,
            .active = false,
            .dirty = false,
            .external_change = false,
            .symlink = symlink,
        };
        for (open) |state| if (std.mem.eql(u8, state.path, path)) {
            result.open = true;
            result.active = state.active;
            result.dirty = state.dirty;
            result.external_change = state.external_change;
            break;
        };
        return result;
    }

    pub fn supportedFile(path: []const u8) bool {
        // 도크로 열 수 있는 kind인지의 단일 출처는 openKindForPath다(§2.2). 여기서 확장자를 따로 나열하면
        // FP12 text/code처럼 트리 클릭만 안 열리는 드리프트가 난다.
        return file_panel_bridge.openKindForPath(path) != null;
    }

    fn findNode(self: *Tree, path: []const u8) ?*Node {
        for (self.roots.items) |*root| if (findNodeRecursive(root, path)) |node| return node;
        return null;
    }

    fn findNodeRecursive(node: *Node, path: []const u8) ?*Node {
        if (std.mem.eql(u8, node.path, path)) return node;
        for (node.children.items) |*child| if (findNodeRecursive(child, path)) |found| return found;
        return null;
    }

    fn materializedNodeCount(self: *const Tree) usize {
        var count: usize = 0;
        for (self.roots.items) |root| count += countNode(root);
        return count;
    }

    /// Zed형 auto-reveal. snapshot에 보이는 ancestor를 순서대로 펼치며 아직 안 읽은 다음 폴더만 lazy scan한다.
    /// 파일까지 찾거나 loaded directory에 경로가 없으면 intent를 끝내 무한 재시도를 막는다.
    fn continueReveal(self: *Tree) !void {
        const target = self.reveal_path orelse return;
        var root_match: ?*Node = null;
        for (self.roots.items) |*root| if (pathWithin(target, root.path)) {
            root_match = root;
            break;
        };
        var current = root_match orelse return;
        current.expanded = true;
        while (true) {
            if (!current.loaded) {
                if (!current.loading) {
                    current.loading = true;
                    try self.enqueueScan(current.path);
                }
                return;
            }
            var next: ?*Node = null;
            for (current.children.items) |*child| if (pathWithin(target, child.path)) {
                next = child;
                break;
            };
            const child = next orelse {
                self.clearReveal();
                return;
            };
            if (std.mem.eql(u8, child.path, target) and !child.kind.isDirectory()) {
                self.clearReveal();
                return;
            }
            if (!child.kind.isDirectory()) {
                self.clearReveal();
                return;
            }
            child.expanded = true;
            current = child;
        }
    }

    /// 지금 걸린 비동기 reveal intent(없으면 null). 동기적으로 이미 materialize된 대상은 `revealDirectory`
    /// 반환값은 true지만 여기서는 null일 수 있다.
    pub fn revealTarget(self: *const Tree) ?[]const u8 {
        return self.reveal_path;
    }

    fn clearReveal(self: *Tree) void {
        const path = self.reveal_path orelse return;
        self.reveal_path = null;
        self.allocator.free(path);
    }

    fn countNode(node: Node) usize {
        var count: usize = 1;
        for (node.children.items) |child| count += countNode(child);
        return count;
    }
};

fn clonePathList(allocator: std.mem.Allocator, source: []const []u8, out: *std.ArrayList([]u8)) !void {
    try out.ensureTotalCapacity(allocator, source.len);
    for (source) |path| out.appendAssumeCapacity(try allocator.dupe(u8, path));
}

fn validBasename(name: []const u8) bool {
    return name.len > 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfScalar(u8, name, '/') == null and std.mem.indexOfScalar(u8, name, 0) == null and
        std.unicode.utf8ValidateSlice(name);
}

fn pathWithin(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root) or path.len <= root.len) return false;
    return root.len == 1 and root[0] == '/' or path[root.len] == '/';
}

fn deepestExpandedDirectory(node: *Node, path: []const u8) ?*Node {
    if (!node.expanded or !pathWithin(path, node.path)) return null;
    var best: *Node = node;
    for (node.children.items) |*child| {
        if (!child.kind.isDirectory()) continue;
        if (deepestExpandedDirectory(child, path)) |candidate| best = candidate;
    }
    return best;
}

fn nodeLessThan(_: void, a: Node, b: Node) bool {
    if (a.kind.isDirectory() != b.kind.isDirectory()) return a.kind.isDirectory();
    return naturalLess(a.name, b.name);
}

/// Zed의 기본 natural sort와 같은 사용자 가시 규칙: ASCII case-insensitive, 숫자 run은 값 길이로 비교해
/// `file2 < file10`, 동률이면 원문 byte로 안정적인 tie-break를 둔다.
fn naturalLess(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (ai < a.len and bi < b.len) {
        if (std.ascii.isDigit(a[ai]) and std.ascii.isDigit(b[bi])) {
            const a_start = ai;
            const b_start = bi;
            while (ai < a.len and std.ascii.isDigit(a[ai])) : (ai += 1) {}
            while (bi < b.len and std.ascii.isDigit(b[bi])) : (bi += 1) {}
            var az = a_start;
            var bz = b_start;
            while (az + 1 < ai and a[az] == '0') : (az += 1) {}
            while (bz + 1 < bi and b[bz] == '0') : (bz += 1) {}
            const al = ai - az;
            const bl = bi - bz;
            if (al != bl) return al < bl;
            const order = std.mem.order(u8, a[az..ai], b[bz..bi]);
            if (order != .eq) return order == .lt;
            continue;
        }
        const ac = std.ascii.toLower(a[ai]);
        const bc = std.ascii.toLower(b[bi]);
        if (ac != bc) return ac < bc;
        ai += 1;
        bi += 1;
    }
    if (a.len != b.len) return a.len < b.len;
    return std.mem.order(u8, a, b) == .lt;
}

test "supportedFile mirrors openKindForPath (md/html/text), not a hardcoded md/html list" {
    // FP12 회귀 가드: 트리 클릭 열기 게이트가 확장자를 따로 나열하면 text/code가 트리에서만 안 열린다.
    try std.testing.expect(Tree.supportedFile("/repo/readme.MD"));
    try std.testing.expect(Tree.supportedFile("/repo/page.html"));
    try std.testing.expect(Tree.supportedFile("/repo/pkg.json"));
    try std.testing.expect(Tree.supportedFile("/repo/main.py"));
    try std.testing.expect(Tree.supportedFile("/repo/style.css"));
    try std.testing.expect(Tree.supportedFile("/repo/photo.png")); // FP14: image kind로 지원.
    try std.testing.expect(Tree.supportedFile("/repo/doc.pdf")); // FP15: pdf kind로 지원.
    try std.testing.expect(Tree.supportedFile("/repo/clip.mp4")); // FP15: media kind(OS 코덱 allowlist)로 지원.
    // 아직 kind가 없는 바이너리·allowlist 밖 컨테이너는 트리에서도 안 열린다(외부 앱).
    try std.testing.expect(!Tree.supportedFile("/repo/archive.zip"));
    try std.testing.expect(!Tree.supportedFile("/repo/clip.webm"));
}

test "file tree uses Zed-style exclusions while retaining useful dot directories" {
    try std.testing.expect(Tree.shouldExcludeName(".git"));
    try std.testing.expect(Tree.shouldExcludeName(".DS_Store"));
    try std.testing.expect(!Tree.shouldExcludeName(".github"));
    try std.testing.expect(!Tree.shouldExcludeName(".env"));
}

test "file tree lazy scan preserves expanded descendants across watcher snapshots" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.recordOpened("/repo/docs/readme.md", "/repo");
    const first = tree.takeScanRequest().?;
    defer allocator.free(first);
    try std.testing.expectEqualStrings("/repo", first);
    try tree.applySnapshot("/repo", &.{
        .{ .name = ".git", .kind = .directory },
        .{ .name = ".github", .kind = .directory },
        .{ .name = "file10.md", .kind = .file },
        .{ .name = "file2.md", .kind = .file },
        .{ .name = "docs", .kind = .directory },
    });
    const docs_request = tree.takeScanRequest().?;
    defer allocator.free(docs_request);
    try std.testing.expectEqualStrings("/repo/docs", docs_request);
    try tree.applySnapshot("/repo/docs", &.{.{ .name = "guide.md", .kind = .file }});

    // root watcher refresh가 같은 docs 노드의 lazy subtree/expanded 상태를 보존한다.
    try tree.applySnapshot("/repo", &.{
        .{ .name = "file2.md", .kind = .file },
        .{ .name = "file10.md", .kind = .file },
        .{ .name = "docs", .kind = .directory },
    });
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    try tree.buildRows(allocator, &.{.{ .path = "/repo/docs/guide.md", .active = true, .dirty = true }}, &rows);
    try std.testing.expectEqual(@as(usize, 7), rows.items.len); // root + docs + guide + sorted files + recent header/file
    try std.testing.expect(rows.items[0] == .root);
    try std.testing.expect(rows.items[1] == .directory and rows.items[1].directory.expanded);
    try std.testing.expect(rows.items[2] == .file and rows.items[2].file.active and rows.items[2].file.dirty);
    try std.testing.expectEqualStrings("file2.md", rows.items[3].file.label);
    try std.testing.expectEqualStrings("file10.md", rows.items[4].file.label);
    try std.testing.expect(rows.items[5] == .recent_header);
}

test "file tree multi-root MRU is deduplicated and symlink directories scan only on expansion" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.recordOpened("/a/readme.md", "/a");
    try tree.recordOpened("/b/page.html", "/b");
    try tree.recordOpened("/a/readme.md", "/a");
    try std.testing.expectEqual(@as(usize, 2), tree.roots.items.len);
    try std.testing.expectEqual(@as(usize, 2), tree.recent.items.len);
    try std.testing.expectEqualStrings("/a/readme.md", tree.recent.items[1]);
    const a_req = tree.takeScanRequest().?;
    defer allocator.free(a_req);
    const b_req = tree.takeScanRequest().?;
    defer allocator.free(b_req);
    try tree.applySnapshot("/a", &.{.{ .name = "linked", .kind = .symlink_directory }});
    try std.testing.expect(tree.takeScanRequest() == null);
    _ = try tree.toggleDirectory("/a/linked");
    const linked = tree.takeScanRequest().?;
    defer allocator.free(linked);
    try std.testing.expectEqualStrings("/a/linked", linked);
}

test "snapshot node cap counts preserved expanded subtrees" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.recordOpened("/a/readme.md", "/a");
    try tree.recordOpened("/b/readme.md", "/b");
    try tree.applySnapshotLimited("/a", &.{.{ .name = "docs", .kind = .directory }}, 5);
    _ = try tree.toggleDirectory("/a/docs");
    try tree.applySnapshotLimited("/a/docs", &.{
        .{ .name = "one.md", .kind = .file },
        .{ .name = "two.md", .kind = .file },
    }, 5);
    try std.testing.expectEqual(@as(usize, 5), tree.materializedNodeCount());

    // /a refresh가 docs의 두 자식(가중치 3)을 보존하면 남는 slot이 없다. child root만 1로 세면
    // extra까지 받아 실제 node가 limit 6으로 넘는다.
    try tree.applySnapshotLimited("/a", &.{
        .{ .name = "docs", .kind = .directory },
        .{ .name = "extra.md", .kind = .file },
    }, 5);
    try std.testing.expectEqual(@as(usize, 5), tree.materializedNodeCount());
    try std.testing.expect(tree.findNode("/a/extra.md") == null);
    try std.testing.expect(tree.findNode("/a/docs/two.md") != null);
}

test "file tree path boundary does not confuse sibling prefixes" {
    try std.testing.expect(pathWithin("/repo/a.md", "/repo"));
    try std.testing.expect(!pathWithin("/repository/a.md", "/repo"));
    try std.testing.expect(pathWithin("/x", "/"));
}

test "file tree row identity survives reorder and falls back to visible ancestor" {
    const before = [_]Row{
        .{ .root = .{ .path = "/repo", .label = "repo", .expanded = true, .loading = false } },
        .{ .directory = .{ .path = "/repo/docs", .label = "docs", .depth = 1, .expanded = true, .loading = false, .symlink = false } },
        .{ .file = .{ .path = "/repo/docs/a.md", .label = "a.md", .depth = 2, .supported = true, .open = false, .active = false, .dirty = false, .external_change = false, .symlink = false } },
        .{ .recent_header = .{ .collapsed = false, .count = 1 } },
        .{ .recent_file = .{ .path = "/repo/docs/a.md", .label = "a.md", .depth = 1, .supported = true, .open = false, .active = false, .dirty = false, .external_change = false, .symlink = false } },
    };
    const selected = rowIdentity(before[2]).?;
    const reordered = [_]Row{
        before[0],
        .{ .file = .{ .path = "/repo/z.md", .label = "z.md", .depth = 1, .supported = true, .open = false, .active = false, .dirty = false, .external_change = false, .symlink = false } },
        before[1],
        before[2],
        before[3],
        before[4],
    };
    try std.testing.expectEqual(@as(?usize, 3), reconcileIdentity(&reordered, selected, 2));

    const collapsed = [_]Row{ before[0], before[1], before[3], before[4] };
    try std.testing.expectEqual(@as(?usize, 1), reconcileIdentity(&collapsed, selected, 3));
    try std.testing.expect(!rowIdentity(before[2]).?.eql(rowIdentity(before[4]).?)); // 같은 path라도 project/recent는 별개.
}

test "file tree parent child and actionable adjacency ignore empty rows" {
    const rows = [_]Row{
        .{ .root = .{ .path = "/repo", .label = "repo", .expanded = true, .loading = false } },
        .{ .directory = .{ .path = "/repo/docs", .label = "docs", .depth = 1, .expanded = true, .loading = false, .symlink = false } },
        .{ .file = .{ .path = "/repo/docs/a.md", .label = "a.md", .depth = 2, .supported = true, .open = false, .active = false, .dirty = false, .external_change = false, .symlink = false } },
        .{ .empty = {} },
        .{ .recent_header = .{ .collapsed = false, .count = 1 } },
        .{ .recent_file = .{ .path = "/repo/docs/a.md", .label = "a.md", .depth = 1, .supported = true, .open = false, .active = false, .dirty = false, .external_change = false, .symlink = false } },
    };
    try std.testing.expectEqual(@as(?usize, 1), firstChildIndex(&rows, 0));
    try std.testing.expectEqual(@as(?usize, 2), firstChildIndex(&rows, 1));
    try std.testing.expectEqual(@as(?usize, 1), parentIndex(&rows, 2));
    try std.testing.expectEqual(@as(?usize, 4), parentIndex(&rows, 5));
    try std.testing.expectEqual(@as(?usize, 4), adjacentActionable(&rows, 2, 1));
    try std.testing.expectEqual(@as(?usize, 2), adjacentActionable(&rows, 4, -1));
}

test "file tree overlapping roots normalize to one ancestor so row identities stay unique" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.recordOpened("/tmp/a/sub/y.md", "/tmp/a/sub");
    try std.testing.expectEqual(@as(usize, 1), tree.roots.items.len);
    try tree.recordOpened("/tmp/a/x.md", "/tmp/a"); // 새 parent가 기존 nested root를 흡수한다.
    try std.testing.expectEqual(@as(usize, 1), tree.roots.items.len);
    try std.testing.expectEqualStrings("/tmp/a", tree.roots.items[0].path);
    try tree.recordOpened("/tmp/a/sub/z.md", "/tmp/a/sub"); // nested root 재추가도 parent에 흡수.
    try std.testing.expectEqual(@as(usize, 1), tree.roots.items.len);
}

test "file tree content remains after the last open entry becomes recent history" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try std.testing.expect(!tree.hasContent());
    try tree.recordOpened("/repo/a.md", "/repo");
    try std.testing.expect(tree.hasContent());
}

test "missing deep selection reconcile visits maximum materialized rows once" {
    const allocator = std.testing.allocator;
    const rows = try allocator.alloc(Row, max_materialized_nodes);
    defer allocator.free(rows);
    for (rows) |*row| row.* = .{ .file = .{
        .path = "/repo/existing.md",
        .label = "existing.md",
        .depth = 1,
        .supported = true,
        .open = false,
        .active = false,
        .dirty = false,
        .external_change = false,
        .symlink = false,
    } };
    var deep_path: [std.fs.max_path_bytes]u8 = undefined;
    deep_path[0] = '/';
    for (deep_path[1..], 1..) |*byte, i| byte.* = if (i % 2 == 0) '/' else 'a';
    var visits: usize = 0;
    try std.testing.expectEqual(
        @as(?usize, max_materialized_nodes / 2),
        reconcileIdentityCounted(rows, .{ .kind = .file, .path = &deep_path }, max_materialized_nodes / 2, &visits),
    );
    try std.testing.expectEqual(max_materialized_nodes, visits);
}

test "file tree explicit roots replace add remove and outside open stays recent-only" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    const initial_generation = tree.rootGeneration();
    try tree.replaceExplicitRoots(&.{"/project/a"});
    try std.testing.expectEqual(RootMode.explicit, tree.rootMode());
    try std.testing.expect(tree.rootGeneration() != initial_generation);
    try tree.addExplicitRoot("/project/b");
    try std.testing.expectEqual(@as(usize, 2), tree.rootCount());
    try tree.recordOpened("/outside/readme.md", "/outside");
    try std.testing.expectEqual(@as(usize, 2), tree.rootCount());
    try std.testing.expectEqualStrings("/outside/readme.md", tree.recentAt(0).?);
    try std.testing.expect(try tree.removeExplicitRoot("/project/a"));
    try std.testing.expectEqual(@as(usize, 1), tree.rootCount());
    try tree.replaceExplicitRoots(&.{});
    try std.testing.expectEqual(@as(usize, 0), tree.rootCount());
    try std.testing.expect(tree.hasContent()); // recent는 explicit root 교체와 독립이다.
}

test "file tree ET-CWD: revealDirectory는 root 안만 걸고 같은 경로를 반복하지 않는다" {
    // file-explorer §1 정책 3·2: root 밖 cwd는 **무동작**(자동 root 추가 금지 — `cd ~` 한 번에 홈 전체가 root가 되는 것을
    // 막는다), 같은 값이 반복 관측돼도 intent를 새로 걸지 않는다(관측은 폴링이라 매 tick 같은 값이 온다).
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/project"});

    // root 밖 → intent 없음.
    try std.testing.expectEqual(Tree.DirectoryReveal.rejected, try tree.revealDirectory("/elsewhere/deep"));
    try std.testing.expect(tree.revealTarget() == null);

    // 상대경로·빈 문자열도 무동작(절대경로만 받는다).
    try std.testing.expectEqual(Tree.DirectoryReveal.rejected, try tree.revealDirectory("relative/path"));
    try std.testing.expectEqual(Tree.DirectoryReveal.rejected, try tree.revealDirectory(""));
    try std.testing.expect(tree.revealTarget() == null);

    // root 안 → intent가 선다. root는 lazy라 아직 안 읽혔으므로 intent가 유지된 채 scan을 기다린다.
    try std.testing.expectEqual(Tree.DirectoryReveal.accepted, try tree.revealDirectory("/project/src/session"));
    try std.testing.expectEqualStrings("/project/src/session", tree.revealTarget().?);

    // 같은 경로 반복 → 그대로(무동작). 다른 경로면 교체.
    try std.testing.expectEqual(Tree.DirectoryReveal.already_target, try tree.revealDirectory("/project/src/session"));
    try std.testing.expectEqualStrings("/project/src/session", tree.revealTarget().?);
    try std.testing.expectEqual(Tree.DirectoryReveal.accepted, try tree.revealDirectory("/project/docs"));
    try std.testing.expectEqualStrings("/project/docs", tree.revealTarget().?);

    // root 자체도 유효한 대상이다(cd로 프로젝트 루트에 돌아온 경우).
    try std.testing.expectEqual(Tree.DirectoryReveal.accepted, try tree.revealDirectory("/project"));
    try std.testing.expectEqualStrings("/project", tree.revealTarget().?);
}

test "file tree ET-CWD: reveal은 root·접힘·영속 축을 건드리지 않는다" {
    // file-explorer §1의 핵심 — root 교체(replaceExplicitRoots)가 접힘 스냅샷을 버리고 root_generation을 올리는 것과 달리,
    // reveal은 그 축을 하나도 안 건드린다. 그래서 `cd`마다 트리가 리셋되지 않는다.
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/project"});
    const gen_before = tree.rootGeneration();
    const roots_before = tree.rootCount();

    try std.testing.expectEqual(Tree.DirectoryReveal.accepted, try tree.revealDirectory("/project/src"));

    try std.testing.expectEqual(gen_before, tree.rootGeneration()); // ★ root_generation 불변
    try std.testing.expectEqual(roots_before, tree.rootCount()); // ★ root 목록 불변
    try std.testing.expectEqualStrings("/project", tree.rootAt(0).?);
}

test "file tree ET-CWD: lazy reveal completes at a loaded directory and cancels when its next ancestor is absent" {
    // file-explorer §1의 자동 gate: CWD reveal은 미물질화 ancestor를 하나씩 scan하되, 대상 directory가
    // materialize되면 끝나야 하고 snapshot에 다음 ancestor가 없으면 stale intent를 남겨 재시도하면 안 된다.
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/project"});

    try std.testing.expectEqual(Tree.DirectoryReveal.accepted, try tree.revealDirectory("/project/src"));
    const root_scan = tree.takeScanRequest().?;
    defer allocator.free(root_scan);
    try std.testing.expectEqualStrings("/project", root_scan);
    try tree.applySnapshot("/project", &.{
        .{ .name = "src", .kind = .directory },
        .{ .name = "other", .kind = .directory },
    });
    const src_scan = tree.takeScanRequest().?;
    defer allocator.free(src_scan);
    try std.testing.expectEqualStrings("/project/src", src_scan);
    try tree.applySnapshot("/project/src", &.{});
    try std.testing.expect(tree.revealTarget() == null); // target directory까지 loaded → 완료

    try std.testing.expectEqual(Tree.DirectoryReveal.accepted, try tree.revealDirectory("/project/other/missing"));
    const other_scan = tree.takeScanRequest().?;
    defer allocator.free(other_scan);
    try std.testing.expectEqualStrings("/project/other", other_scan);
    try tree.applySnapshot("/project/other", &.{});
    try std.testing.expect(tree.revealTarget() == null); // missing ancestor → 취소, 무한 재시도 금지
}

test "file tree explicit root cap plus one is atomic" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();

    var buffers: [max_roots + 1][32]u8 = undefined;
    var paths: [max_roots + 1][]const u8 = undefined;
    for (&buffers, 0..) |*buffer, index| {
        paths[index] = try std.fmt.bufPrint(buffer, "/project-{d}", .{index});
    }
    try tree.replaceExplicitRoots(paths[0..max_roots]);
    const generation = tree.rootGeneration();
    try std.testing.expectEqual(max_roots, tree.rootCount());
    try std.testing.expectError(error.TooManyRoots, tree.addExplicitRoot(paths[max_roots]));
    try std.testing.expectEqual(generation, tree.rootGeneration());
    try std.testing.expectEqual(max_roots, tree.rootCount());
    try std.testing.expectEqualStrings(paths[0], tree.rootAt(0).?);
    try std.testing.expectEqualStrings(paths[max_roots - 1], tree.rootAt(max_roots - 1).?);
}

test "file tree watcher requests normalize explorer and open-entry safety roots" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/project"});
    try tree.resetWatchRequests(&.{ "/project/sub", "/outside", "/outside/deeper" });
    const first = tree.takeWatchRequest().?;
    defer allocator.free(first);
    const second = tree.takeWatchRequest().?;
    defer allocator.free(second);
    try std.testing.expectEqualStrings("/project", first);
    try std.testing.expectEqualStrings("/outside", second);
    try std.testing.expect(tree.takeWatchRequest() == null);
}

test "file tree transaction clone is independent and pinned root rejects replacement identity" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/project"});
    const pinned: Identity = .{ .device = 7, .inode = 11, .kind = @intFromEnum(IdentityKind.directory) };
    try std.testing.expect(tree.pinRootIdentity("/project", pinned));
    try tree.applySnapshotWithIdentity("/project", pinned, &.{.{ .name = "docs", .kind = .directory }});

    var candidate = try tree.clone();
    defer candidate.deinit();
    try candidate.addExplicitRoot("/outside");
    try std.testing.expectEqual(@as(usize, 1), tree.rootCount());
    try std.testing.expectEqual(@as(usize, 2), candidate.rootCount());

    const replaced: Identity = .{ .device = 7, .inode = 12, .kind = @intFromEnum(IdentityKind.directory) };
    try std.testing.expectError(error.IdentityMismatch, candidate.applySnapshotWithIdentity("/project", replaced, &.{}));
    try std.testing.expect(try candidate.removeExplicitRoot("/outside"));
    try std.testing.expectError(error.IdentityMismatch, candidate.applySnapshotWithIdentity("/project", replaced, &.{}));
    try std.testing.expectError(error.IdentityMismatch, tree.applySnapshotWithIdentity("/project", replaced, &.{}));
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    try tree.buildRows(allocator, &.{}, &rows);
    try std.testing.expectEqualStrings("docs", rows.items[1].directory.label);
}
