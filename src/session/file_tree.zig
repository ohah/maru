//! 파일 도크 FP7의 OS-중립 트리 모델. 디렉터리 열거/FSEvents는 L4가 백그라운드에서 수행하고,
//! 이 모듈은 완성된 snapshot·접힘·멀티루트·최근 파일·렌더 row만 소유한다. 따라서 render tick은
//! 디스크를 읽지 않고 `rows`만 소비한다(docs/file-panel.md §7).

const std = @import("std");

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
};

pub const OpenState = struct {
    path: []const u8,
    active: bool = false,
    dirty: bool = false,
    external_change: bool = false,
};

pub const Row = union(enum) {
    recent_header: struct { collapsed: bool, count: u8 },
    recent_file: FileRow,
    root: struct { path: []const u8, label: []const u8, expanded: bool, loading: bool },
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
    };
};

const Node = struct {
    name: []u8,
    path: []u8,
    kind: Kind,
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
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
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
        errdefer self.allocator.free(reveal);
        try self.ensureRoot(root_path);
        try self.pushRecent(file_path);
        if (self.reveal_path) |old| self.allocator.free(old);
        self.reveal_path = reveal;
        self.continueReveal() catch {};
    }

    fn ensureRoot(self: *Tree, root_path: []const u8) !void {
        for (self.roots.items) |root| if (std.mem.eql(u8, root.path, root_path)) return;
        if (self.roots.items.len >= max_roots) return error.TooManyRoots;
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
        self.roots.appendAssumeCapacity(.{
            .name = owned_name,
            .path = owned_path,
            .kind = .directory,
            .expanded = true,
            .loading = true,
        });
        self.scan_requests.appendAssumeCapacity(scan_path);
        self.watch_requests.appendAssumeCapacity(watch_path);
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

    pub fn pathWithinRoot(path: []const u8, root: []const u8) bool {
        return pathWithin(path, root);
    }

    pub fn applySnapshot(self: *Tree, directory_path: []const u8, inputs: []const EntryInput) !void {
        return self.applySnapshotLimited(directory_path, inputs, max_materialized_nodes);
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
            const path = try std.fs.path.join(self.allocator, &.{ directory_path, input.name });
            errdefer self.allocator.free(path);
            staged.appendAssumeCapacity(.{ .name = name, .path = path, .kind = input.kind });
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
        if (self.roots.items.len == 0) {
            try out.append(allocator, .{ .empty = {} });
            return;
        }
        for (self.roots.items) |root| {
            try out.append(allocator, .{ .root = .{
                .path = root.path,
                .label = if (root.name.len > 0) root.name else root.path,
                .expanded = root.expanded,
                .loading = root.loading,
            } });
            if (root.expanded) try appendChildrenRows(allocator, root.children.items, 1, open, out);
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
                } });
                if (node.expanded) try appendChildrenRows(allocator, node.children.items, depth +| 1, open, out);
            } else {
                try out.append(allocator, .{ .file = fileRow(node.path, node.name, depth, node.kind.isSymlink(), open) });
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
        const ext = std.fs.path.extension(path);
        return std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".html");
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
    try std.testing.expectEqual(@as(usize, 7), rows.items.len); // recent header/file + root + docs + guide + sorted files
    try std.testing.expect(rows.items[2] == .root);
    try std.testing.expect(rows.items[3] == .directory and rows.items[3].directory.expanded);
    try std.testing.expect(rows.items[4] == .file and rows.items[4].file.active and rows.items[4].file.dirty);
    try std.testing.expectEqualStrings("file2.md", rows.items[5].file.label);
    try std.testing.expectEqualStrings("file10.md", rows.items[6].file.label);
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
