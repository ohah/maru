//! 파일 도크 FP7의 OS-중립 트리 모델. 디렉터리 열거/FSEvents는 L4가 백그라운드에서 수행하고,
//! 이 모듈은 완성된 snapshot·접힘·멀티루트·최근 파일·렌더 row만 소유한다. 따라서 render tick은
//! 디스크를 읽지 않고 `rows`만 소비한다(docs/file-panel.md §7).

const std = @import("std");
const path_shape = @import("../path_shape.zig");
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

/// **직접 연 핸들을 `fstat` 한 값**만 담는 봉투. 부모 순회가 준 항목 identity 와 섞이지 않게 **타입으로**
/// 가른다 — 이름만 다른 두 필드로는 실수를 못 막는다는 것이 2026-08-21 결함의 교훈이다.
///
/// **축이 셋이다.** 같은 경로라도 재는 방법마다 다른 값이 나온다:
///
/// | 축 | 재는 방법 | 무엇을 가리키나 |
/// |---|---|---|
/// | `readdir` | 디렉터리 순회가 준 inode | 그 디렉터리 엔트리 |
/// | `lstat` | `fstatat` + `SYMLINK_NOFOLLOW` | 링크 자신 |
/// | `fstat` | 열린 핸들 | 링크가 가리키는 실체 |
///
/// macOS 에서는 셋이 실제로 갈린다 — 심링크(`/etc`)는 물론이고 **firmlink**(`/Users`·`/private`·
/// `/opt`·`/cores`)에서는 `readdir` 이 주는 합성 inode 가 `lstat` 과도 다르다(실측: `Users`
/// readdir=1152921500312570703 · lstat=14494 · fstat=14494).
///
/// 스냅샷 검증은 **`fstat` 축끼리만** 비교해야 하므로 그 값만 이 타입으로 감싼다. 다른 축의 값을 넣으려면
/// 명시적으로 감싸야 하고, 그 자리가 곧 "축을 바꾸고 있다"는 표시가 된다.
pub const ScanIdentity = struct {
    value: Identity,

    pub fn eql(self: ScanIdentity, other: ScanIdentity) bool {
        return self.value.eql(other.value);
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
        /// git 이 무시하는 항목인가(`check-ignore`). 렌더가 흐리게 그린다 — `node_modules` 같은 줄이
        /// 추적되는 소스와 같은 무게로 읽히면 훑기가 어렵다(사용자 요청 2026-08-18).
        ///
        /// **판정은 git 이 한다.** 우리가 `.gitignore` 를 파싱하지 않는 이유는 부정·중첩·`**` 문법을 다시
        /// 구현해야 하고 git 과 미세하게 어긋날 수 있어서다. 저장소가 아니거나 아직 안 물어본 항목은
        /// false 이고, 그때는 지금과 같은 모습이다(모르면 흐리게 하지 않는다).
        ignored: bool = false,
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
        /// git 이 무시하는 항목인가 — `DirectoryRow.ignored` 와 같은 계약이다.
        ignored: bool = false,
    };
};

/// L3 classifier result stored on the immutable row snapshot without importing the upper layer.
/// Zero means unclassified/none; AppSession annotates every newly projected row exactly once.
/// 행이 git 무시 대상인가. 아이콘 종류와 같은 자리에서 꺼내 렌더가 한 번만 묻는다.
pub fn rowIgnored(row: Row) bool {
    return switch (row) {
        .directory => |v| v.ignored,
        .file, .recent_file => |v| v.ignored,
        else => false,
    };
}

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
    /// **부모 디렉터리를 훑어 얻은** 그 항목의 identity. 링크는 링크 자신을 가리키고(`lstat` 축),
    /// 삭제·이름변경 가드가 같은 축(`fstatat` + `SYMLINK_NOFOLLOW`)으로 다시 재 비교한다.
    identity: ?Identity = null,
    /// **이 디렉터리를 직접 열어 잰** identity(`fstat` — 타입이 축을 봉인한다). 위 `identity`와 **축이 다르다** — 링크를 따라간
    /// 실체를 가리키고, macOS 루트의 firmlink(`/Users`·`/private`·`/opt`·`/cores`)에서는 `readdir` 이
    /// 주는 합성 inode 와도 다르다(실측 2026-08-21: `Users` readdir=1152921500312570703 · lstat=14494).
    ///
    /// **그래서 스냅샷 검증은 이 값끼리만 비교한다.** 예전에는 부모가 준 `identity` 를 기대값으로 삼고
    /// 직접 잰 값과 견줬는데, 그 둘은 재배치가 없어도 어긋난다 — macOS 에서 root 를 `/` 로 열면 `System`
    /// 을 뺀 거의 모든 항목이 걸려, 펼칠 때마다 "폴더가 바뀌었으니 다시 여세요" 안내가 다시 떴다
    /// (사용자 보고 2026-08-21 — 안내가 끊이지 않아 조작이 막혔다).
    scan_identity: ?ScanIdentity = null,
    children: std.ArrayList(Node) = .empty,
    loaded: bool = false,
    expanded: bool = false,
    loading: bool = false,
    /// git 이 무시하는 항목인가(`check-ignore` 결과). 기본 false = **모름** — 저장소가 아니거나 아직
    /// 안 물어본 상태에서 흐리게 그리지 않기 위해서다(`Row.ignored` 주석과 같은 계약).
    ignored: bool = false,

    /// 노드를 **새로 만들며 이어받아야 하는 파일시스템 신원**을 한자리에서 옮긴다.
    ///
    /// **이 파일에는 그런 자리가 넷이다** — 복제(`clone`)·스냅샷 이전(`applySnapshotLimited`)·root
    /// 재구성(`replaceExplicitRoots`)·root 트랜잭션(`cloneForRootTransaction`). 새 축 필드를 넣을 때
    /// 넷을 다 고쳐야 한다는 규율이 **사람 기억에 의존하면 반드시 하나를 놓친다**: 2026-08-21 적대적
    /// 검증에서 `scan_identity` 를 넣으며 넷 중 셋을 연달아 놓쳤고, 그때마다 재배치 감지가 조용히
    /// 죽었다(빠뜨림은 게이트도 컴파일러도 못 잡는다 — 기존 테스트의 `expectError` 가 잡았다).
    ///
    /// 그래서 **옮기는 규칙을 함수 하나로 모은다.** 축이 또 늘면 여기만 고치면 된다.
    fn inheritIdentityFrom(self: *Node, source: Node) void {
        self.identity = source.identity;
        self.scan_identity = source.scan_identity;
    }

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
            .loaded = self.loaded,
            .expanded = self.expanded,
            .loading = self.loading,
        };
        // **신원은 같은 규칙을 지난다**(위 `inheritIdentityFrom` 주석 — 빠뜨리면 재배치 감지가 죽는다).
        copy.inheritIdentityFrom(self.*);
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
            // subtree 는 곧 버리고 다시 읽지만 root 폴더 자체가 바뀐 것은 아니므로 **신원은 따라온다** —
            // 안 옮기면 트랜잭션을 열 때마다 재배치 감지가 초기화된다.
            copy.roots.appendAssumeCapacity(.{
                .name = name,
                .path = path,
                .kind = .directory,
                .expanded = true,
                .loading = true,
            });
            copy.roots.items[copy.roots.items.len - 1].inheritIdentityFrom(root);
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

    /// ET-CWD: 트리가 지금 **정확히 이 폴더 하나**를 root로 두고 있는가(docs/file-explorer.md §1 정책 2).
    ///
    /// 따라가기는 `cd` 마다 root를 갈아끼운다. 그 전에 "이미 그 자리인가"를 묻지 않으면, 복원된 root가
    /// 마침 터미널 cwd와 같을 때 시작하자마자 재스캔과 watcher 재등록이 한 번 헛돈다.
    ///
    /// **root 하나**를 요구한다. 사용자가 "작업공간에 폴더 추가…"로 여러 root를 둔 상태는 cwd 하나와
    /// 일치한다고 말할 수 없다 — 그 경우는 따라가기가 교체하는 것이 맞다(그 대가는 §1 결정 박스에 있다).
    pub fn rootIsExactly(self: *const Tree, path: []const u8) bool {
        if (self.roots.items.len != 1) return false;
        return std.mem.eql(u8, self.roots.items[0].path, path);
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
            // **신원은 남긴다.** root 목록을 다시 세우는 것은 그 폴더가 바뀌었다는 뜻이 아니다(다른
            // root 를 더하거나 빼는 일이 대부분이다) — 버리면 다음 스캔이 "첫 스캔"이 되어 무엇이 오든
            // 받아들이고 재배치 감지가 죽는다.
            var previous: ?Node = null;
            for (self.roots.items) |root| if (std.mem.eql(u8, root.path, path)) {
                previous = root;
                break;
            };
            staged_roots.appendAssumeCapacity(.{
                .name = owned_name,
                .path = owned_path,
                .kind = .directory,
                .expanded = true,
                .loading = true,
            });
            if (previous) |old_root| staged_roots.items[staged_roots.items.len - 1].inheritIdentityFrom(old_root);
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

    /// 루트만 남기고 펼친 폴더를 모두 접는다. **루트는 접지 않는다** — 루트까지 접으면 화면에 폴더 이름 한
    /// 줄만 남아, 되돌리려면 방금 지운 것과 같은 수의 클릭이 든다(그 상태는 도크를 닫은 것과 구분되지 않는다).
    ///
    /// scan 을 예약하지 않는다. 접기는 **이미 읽은 것을 감추는** 동작이라, 다시 펼칠 때 `toggleDirectory` 가
    /// 그때 필요한 것만 읽는다(접는 김에 재스캔하면 큰 트리에서 접기가 느려진다 — 새로 고침은 별개 동작이다).
    ///
    /// 되돌린 것이 하나라도 있으면 true. 호출자가 "이미 다 접혀 있었다"를 no-op 으로 둘 수 있게 한다.
    pub fn collapseAll(self: *Tree) bool {
        var changed = false;
        for (self.roots.items) |*root| {
            for (root.children.items) |*child| {
                if (collapseSubtree(child)) changed = true;
            }
        }
        return changed;
    }

    fn collapseSubtree(node: *Node) bool {
        var changed = false;
        if (node.expanded) {
            node.expanded = false;
            changed = true;
        }
        // 자식도 접어 둔다 — 접힌 부모 아래의 펼침 상태가 살아 있으면 부모를 다시 펼쳤을 때 접기 전 깊이가
        // 통째로 돌아온다(사용자가 방금 없앤 것이 되살아난다).
        for (node.children.items) |*child| {
            if (collapseSubtree(child)) changed = true;
        }
        return changed;
    }

    /// **펼쳐 둔 디렉터리를 전부 다시 읽으라고 예약한다**(RF5a — 원격 감시).
    ///
    /// 원격 감시자는 `change` 한 줄만 낸다 — **어디가** 바뀌었는지 안 싣는다([계획](../../docs/plans/remote-file-tree.md)
    /// ③ 확정: 채널 하나를 두 뷰가 나눠 쓰되 프로토콜은 안 늘린다). 그래서 무효화가 거칠다:
    /// 경로 하나를 지목하는 `invalidatePath` 대신, **지금 화면에 내용이 보이는 디렉터리 전부**를 큐에
    /// 넣는다. 접힌 것은 넣지 않는다 — 안 보이는 것을 다시 읽으면 왕복만 늘고 화면은 그대로다
    /// (펼칠 때 `toggleDirectory` 가 어차피 읽는다).
    ///
    /// 재예약은 **자기 제한적이다**: `enqueueScan` 이 같은 경로를 중복 제거하고, 큐가 넘치면 root 만
    /// 남기는 coarse recovery 로 접히며, 실행 쪽 상한(원격 슬롯)이 왕복 수를 잡는다. 그래서 트리거가
    /// 몰려도 예약이 무한히 자라지 않는다.
    ///
    /// 되돌린 것이 하나라도 있으면 true(호출자가 「읽을 것이 없었다」를 no-op 으로 둘 수 있게).
    pub fn invalidateExpanded(self: *Tree) !bool {
        var any = false;
        for (self.roots.items) |*root| {
            if (!root.expanded) continue;
            root.loading = true;
            try self.enqueueScan(root.path);
            any = true;
            for (root.children.items) |*child| {
                if (try self.enqueueExpandedSubtree(child)) any = true;
            }
        }
        return any;
    }

    fn enqueueExpandedSubtree(self: *Tree, node: *Node) !bool {
        if (!node.expanded) return false;
        var any = false;
        if (node.kind.isDirectory()) {
            node.loading = true;
            try self.enqueueScan(node.path);
            any = true;
        }
        for (node.children.items) |*child| {
            if (try self.enqueueExpandedSubtree(child)) any = true;
        }
        return any;
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

    /// **비교의 양변이 같은 축이어야 한다**(`scan_identity`) — 부모가 훑어 준 값은 링크 자신·firmlink
    /// 합성 inode 라 직접 잰 값과 원래 다르다. 첫 스캔은 기준을 세우고(비교 없음) 그다음부터 재배치를
    /// 잡는다: 같은 경로를 다시 열었는데 실체가 달라졌으면 그때가 진짜 `IdentityMismatch` 다.
    pub fn applySnapshotWithIdentity(self: *Tree, directory_path: []const u8, identity: ?ScanIdentity, inputs: []const EntryInput) !void {
        const node = self.findNode(directory_path) orelse return error.NotFound;
        if (node.scan_identity) |expected| if (identity) |actual| {
            if (!expected.eql(actual)) return error.IdentityMismatch;
        };
        try self.applySnapshotLimited(directory_path, inputs, max_materialized_nodes);
        if (identity) |value| {
            const node_after = self.findNode(directory_path) orelse return error.NotFound;
            node_after.scan_identity = value;
            // **`identity` 도 계속 갱신한다.** 디렉터리 노드의 그 값은 예전부터 "직접 잰 값"이었고
            // (부모가 준 항목 값이 아니라) 삭제·이름변경 가드가 그것을 쓴다 — 여기서 안 채우면 root
            // 처럼 부모가 없는 노드는 영영 비어, 그 가드가 대상을 식별하지 못한다.
            node_after.identity = value.value;
        }
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
                // **파일시스템 신원도 함께 옮긴다.** 기준선을 watcher refresh 마다 버리면 "같은 경로가
                // 다른 실체로 바뀌었다" 를 영영 못 잡는다 — 그 자리가 곧 이 검사의 존재 이유다.
                next.inheritIdentityFrom(old.*);
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

    /// 경로로 노드를 찾아 무시 표시를 남긴다(`check-ignore` 결과 반영). 못 찾으면 조용히 넘어간다 —
    /// 질의가 도는 사이 트리가 접히거나 새로 읽혀 그 경로가 사라질 수 있고, 그건 오류가 아니다.
    ///
    /// **표시만 한다**: 자식으로 전파하지 않는다. git 은 무시된 디렉터리 안을 다시 판정하지 않으므로
    /// (그 안을 물어도 같은 답이다) 펼쳐 보이는 항목마다 물어보는 이 설계에서는 전파가 필요 없고,
    /// 전파하면 `.gitignore` 의 부정 규칙(`!keep.txt`)이 있는 트리에서 틀린 답을 만든다.
    pub fn markIgnored(self: *Tree, path: []const u8, ignored: bool) void {
        for (self.roots.items) |*root| {
            if (markIgnoredIn(root.children.items, path, ignored)) return;
        }
    }

    fn markIgnoredIn(children: []Node, path: []const u8, ignored: bool) bool {
        for (children) |*node| {
            if (std.mem.eql(u8, node.path, path)) {
                node.ignored = ignored;
                return true;
            }
            if (markIgnoredIn(node.children.items, path, ignored)) return true;
        }
        return false;
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

    /// **단일 자식 디렉터리 체인의 끝**을 찾는다(compact 표시). `a/b/c` 처럼 중간에 디렉터리 하나만
    /// 있는 구간은 한 줄로 접어 보이는 것이 훑기 쉽다(사용자가 제시한 참고 트리의 `release / app`).
    ///
    /// **아직 읽지 않았거나 읽는 중인 노드에서 멈춘다** — 자식 수를 모르는 상태에서 접으면 다 읽힌 뒤
    /// 줄이 바뀌어 보이는 것이 흔들린다. 파일이 섞여 있거나 자식이 둘 이상이면 거기서 끝난다.
    fn compactChainEnd(node: *const Node) *const Node {
        var cur = node;
        while (cur.loaded and !cur.loading and cur.children.items.len == 1) {
            const only = &cur.children.items[0];
            if (!only.kind.isDirectory()) break;
            cur = only;
        }
        return cur;
    }

    /// 접힌 줄의 라벨 — 마지막 노드의 경로에서 **첫 노드의 부모 경로**를 뗀 나머지(`b/c`)다. 새 문자열을
    /// 만들지 않으므로 할당이 없고, 여러 단계 체인도 그대로 담긴다.
    fn compactLabel(head: *const Node, tail: *const Node) []const u8 {
        if (head == tail) return head.name;
        const parent_len = head.path.len - head.name.len; // head.path = `<parent>/<head.name>`
        if (tail.path.len <= parent_len) return tail.name; // 방어: 경로가 기대 형태가 아니면 이름만
        return tail.path[parent_len..];
    }

    fn appendChildrenRows(allocator: std.mem.Allocator, children: []const Node, depth: u16, open: []const OpenState, out: *std.ArrayList(Row)) !void {
        for (children) |*node| {
            if (node.kind.isDirectory()) {
                // 체인의 **끝 노드**가 그 줄의 주인이다: 접기/펼치기·경로 매칭이 그것을 향해야 펼쳤을 때
                // 실제 내용이 나온다(중간 노드를 펼쳐 봐야 또 한 겹이 나올 뿐이다).
                const tail = compactChainEnd(node);
                try out.append(allocator, .{
                    .directory = .{
                        .path = tail.path,
                        .label = compactLabel(node, tail),
                        .depth = depth,
                        .expanded = tail.expanded,
                        .loading = tail.loading,
                        .symlink = node.kind.isSymlink(),
                        // 둘 다 **tail**에서 온다. 접힌 줄이 가리키는 디렉터리가 tail 이므로(위 주석),
                        // 무시 판정도 화면에 보이는 그 경로의 것이어야 한다 — 중간 노드에서 가져오면 사용자가
                        // 보는 경로와 흐려지는 근거가 어긋난다.
                        .identity = tail.identity,
                        .ignored = tail.ignored,
                    },
                });
                if (tail.expanded) try appendChildrenRows(allocator, tail.children.items, depth +| 1, open, out);
            } else {
                var row = fileRow(node.path, node.name, depth, node.kind.isSymlink(), open);
                row.identity = node.identity;
                row.ignored = node.ignored;
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

    /// 지금 걸린 비동기 reveal intent(없으면 null). `recordOpened`가 건 대상이 이미 materialize돼 있으면
    /// 그 자리에서 intent가 소멸하므로 여기서는 null이다 — "안 걸렸다"와 "이미 끝났다"는 구분되지 않는다.
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

/// 이름 한 칸이 유효한가. 이 술어는 **파일시스템 스캔 결과를 거른다**(`ingest` — 실재하는 디렉터리 엔트리).
///
/// **역슬래시는 막지 않는다.** 사용자 입력을 받는 `file_tree_mutation.validateName`은 막지만 여기는 반대다:
/// Windows에서 `\`는 **파일명에 쓸 수 없는 문자**라 스캔 결과에 들어올 수 없고, POSIX에서는 `a\b`가 평범한
/// 파일 이름이다. 그러므로 여기서 거부하면 Windows에서 얻는 것은 없고 POSIX에서는 **그 파일이 트리에서
/// 조용히 사라진다**(오류도 안 뜬다 — 호출부가 `continue`한다). Windows에서 만든 압축을 풀면 실제로 생기는
/// 이름이다. 적대적 검증에서 잡은 회귀라 여기 못 박는다.
fn validBasename(name: []const u8) bool {
    return name.len > 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfScalar(u8, name, '/') == null and std.mem.indexOfScalar(u8, name, 0) == null and
        std.unicode.utf8ValidateSlice(name);
}

fn pathWithin(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root) or path.len <= root.len) return false;
    // 루트가 이미 구분자로 끝나면(`/`·`C:/`) 한 칸을 더 요구하면 안 된다 — 그러면 첫 자식이 통째로 밖으로
    // 보인다. 예전엔 그 예외가 POSIX 루트(`/`)만 알아 드라이브 루트에 대응이 없었다(docs/windows-platform.md §5).
    // **경계는 `/`만 본다**: 이 모듈의 경로 계약이 POSIX라(위 joinPosix, docs/layering-and-portability.md §4.1)
    // 여기서 `\`까지 구분자로 세면 POSIX에서 `p\q`라는 평범한 파일 이름이 디렉터리 `p`의 자식으로 둔갑한다.
    return path_shape.endsWithSep(root) or path[root.len] == '/';
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

test "file tree ET-CWD: rootIsExactly는 그 폴더 하나일 때만 참이다" {
    // file-explorer §1 정책 2의 no-op 가드다. 이 판정이 헐거우면 `cd` 마다 이미 서 있는 root를 다시 세워
    // 재스캔·watcher 재등록이 헛돌고, 반대로 빡빡하면 따라가기가 아예 안 걸린다. 둘 다 조용한 증상이다.
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/project"});

    try std.testing.expect(tree.rootIsExactly("/project"));
    try std.testing.expect(!tree.rootIsExactly("/project/src")); // 하위는 "그 자리"가 아니다 — 교체 대상이다
    try std.testing.expect(!tree.rootIsExactly("/")); // 상위도 마찬가지
    try std.testing.expect(!tree.rootIsExactly("/project2")); // 접두만 겹치는 형제를 같다고 읽으면 안 된다
    try std.testing.expect(!tree.rootIsExactly(""));

    // multi-root는 cwd 하나와 "일치"한다고 말할 수 없다. 그중 하나가 cwd여도 거짓이어야 교체가 걸린다.
    try tree.replaceExplicitRoots(&.{ "/project", "/other" });
    try std.testing.expect(!tree.rootIsExactly("/project"));
}

test "file tree lazy reveal completes at a loaded directory and cancels when its next ancestor is absent" {
    // 파일 열기의 auto-reveal 계약: 미물질화 ancestor를 하나씩 scan하되 대상이 materialize되면 intent를
    // 끝내야 하고, snapshot에 다음 ancestor가 없으면 stale intent를 남겨 무한 재시도하면 안 된다.
    // ET-CWD가 2026-08-31까지 이 intent에 cwd를 넣었지만(§1), 이제 진입점은 파일 열기 하나다.
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/project"});

    try tree.recordOpened("/project/src/main.zig", "/project");
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
    try tree.applySnapshot("/project/src", &.{
        .{ .name = "main.zig", .kind = .file },
    });
    try std.testing.expect(tree.revealTarget() == null); // 대상 파일까지 materialize → 완료

    try tree.recordOpened("/project/other/missing/deep.txt", "/project");
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

test "스냅샷 검증은 직접 잰 축끼리만 견준다 — 부모가 준 항목 identity 와 섞지 않는다" {
    // 사용자 보고(2026-08-21): 탐색기 root 를 `/` 로 열면 "폴더가 바뀌었으니 다시 여세요" 안내가
    // 끊이지 않아 조작이 막혔다. 원인은 **축이 다른 두 값을 견준 것**이다 — 부모 순회는 `readdir` 이
    // 준 항목 정보를(심링크면 링크 자신, macOS firmlink 면 합성 inode) 싣고, 그 폴더를 펼치면 열린
    // 핸들을 `fstat` 해 실체를 잰다. 실측: `/etc` 는 링크(1152921500312570782) 대 실체(808658951),
    // `/Users` 는 firmlink 라 심링크가 아닌데도 readdir(1152921500312570703) 대 lstat/fstat(14494).
    //
    // 재배치가 없어도 어긋나므로 **첫 비교부터 거짓 경보**였다. 지금은 직접 잰 값이 기준선이 되고,
    // 그 축끼리 달라졌을 때만 진짜 `IdentityMismatch` 다.
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/project"});

    // 부모가 준 항목 identity(링크 자신 축) — 노드에 실린다.
    const from_parent: Identity = .{ .device = 1, .inode = 111, .kind = @intFromEnum(IdentityKind.symlink) };
    try tree.applySnapshot("/project", &.{.{ .name = "link", .kind = .symlink_directory, .identity = from_parent }});

    // 그 폴더를 펼쳐 직접 잰 값은 **실체**라 위와 다르다. 옛 코드는 여기서 IdentityMismatch 였다.
    const scanned: ScanIdentity = .{ .value = .{ .device = 1, .inode = 222, .kind = @intFromEnum(IdentityKind.directory) } };
    try tree.applySnapshotWithIdentity("/project/link", scanned, &.{.{ .name = "inside.txt", .kind = .file }});

    // 같은 축으로 다시 오면 통과한다(정상 refresh).
    try tree.applySnapshotWithIdentity("/project/link", scanned, &.{.{ .name = "inside.txt", .kind = .file }});

    // **재배치는 여전히 잡는다** — 같은 경로가 다른 실체를 열면 그때가 진짜 mismatch 다.
    const replaced: ScanIdentity = .{ .value = .{ .device = 1, .inode = 333, .kind = @intFromEnum(IdentityKind.directory) } };
    try std.testing.expectError(
        error.IdentityMismatch,
        tree.applySnapshotWithIdentity("/project/link", replaced, &.{}),
    );

    // 삭제·이름변경 가드가 읽는 `identity` 는 **계속 채워진다**(직접 잰 값 — 예전 동작 그대로).
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    try tree.buildRows(allocator, &.{}, &rows);
    for (rows.items) |row| switch (row) {
        .directory => |dir| if (std.mem.eql(u8, dir.path, "/project/link")) {
            try std.testing.expect(dir.identity != null);
            try std.testing.expectEqual(@as(u64, 222), dir.identity.?.inode);
        },
        else => {},
    };
}

test "file tree transaction clone is independent and pinned root rejects replacement identity" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/project"});
    const pinned: Identity = .{ .device = 7, .inode = 11, .kind = @intFromEnum(IdentityKind.directory) };
    const pinned_scan: ScanIdentity = .{ .value = pinned };
    try std.testing.expect(tree.pinRootIdentity("/project", pinned));
    try tree.applySnapshotWithIdentity("/project", pinned_scan, &.{.{ .name = "docs", .kind = .directory }});

    var candidate = try tree.clone();
    defer candidate.deinit();
    try candidate.addExplicitRoot("/outside");
    try std.testing.expectEqual(@as(usize, 1), tree.rootCount());
    try std.testing.expectEqual(@as(usize, 2), candidate.rootCount());

    const replaced: ScanIdentity = .{ .value = .{ .device = 7, .inode = 12, .kind = @intFromEnum(IdentityKind.directory) } };
    try std.testing.expectError(error.IdentityMismatch, candidate.applySnapshotWithIdentity("/project", replaced, &.{}));
    try std.testing.expect(try candidate.removeExplicitRoot("/outside"));
    try std.testing.expectError(error.IdentityMismatch, candidate.applySnapshotWithIdentity("/project", replaced, &.{}));
    try std.testing.expectError(error.IdentityMismatch, tree.applySnapshotWithIdentity("/project", replaced, &.{}));
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    try tree.buildRows(allocator, &.{}, &rows);
    try std.testing.expectEqualStrings("docs", rows.items[1].directory.label);
}

// 단일 자식 디렉터리 체인은 **한 줄로 접어** 보인다(사용자가 제시한 참고 트리의 `release / app`).
// 여기서 고정하는 것은 셋이다: ⑴ 라벨이 이어진 경로이고 ⑵ 그 줄의 주인은 **끝 노드**이며(펼치기·경로
// 매칭이 그것을 향한다) ⑶ **아직 안 읽은 노드에서는 접지 않는다**(자식 수를 모르는 채 접으면 다 읽힌 뒤
// 줄이 바뀐다).
test "file tree compact: 단일 자식 디렉터리 체인은 한 줄로 접히고 끝 노드가 그 줄의 주인이다" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/w"});

    // /w → release → app → main.zig. release·app 은 각각 자식이 하나뿐이다.
    try tree.applySnapshot("/w", &.{.{ .name = "release", .kind = .directory }});
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);

    // 아직 release 를 안 읽었다 — 접지 않는다(자식 수를 모른다).
    try tree.buildRows(allocator, &.{}, &rows);
    var saw_plain = false;
    for (rows.items) |row| switch (row) {
        .directory => |d| if (std.mem.eql(u8, d.label, "release")) {
            saw_plain = true;
        },
        else => {},
    };
    try std.testing.expect(saw_plain);

    // 읽고 나면 접힌다: release/app 한 줄.
    try tree.applySnapshot("/w/release", &.{.{ .name = "app", .kind = .directory }});
    try tree.applySnapshot("/w/release/app", &.{.{ .name = "main.zig", .kind = .file }});
    try tree.buildRows(allocator, &.{}, &rows);
    var compact_label: ?[]const u8 = null;
    var compact_path: ?[]const u8 = null;
    for (rows.items) |row| switch (row) {
        .directory => |d| if (d.depth == 1) {
            compact_label = d.label;
            compact_path = d.path;
        },
        else => {},
    };
    try std.testing.expectEqualStrings("release/app", compact_label.?);
    try std.testing.expectEqualStrings("/w/release/app", compact_path.?); // 끝 노드가 주인이다

    // 그 줄을 펼치면 **끝 노드의 자식**이 나온다(중간을 한 번 더 펼칠 필요가 없다).
    _ = try tree.toggleDirectory(compact_path.?);
    try tree.buildRows(allocator, &.{}, &rows);
    var saw_child = false;
    for (rows.items) |row| switch (row) {
        .file => |f| if (std.mem.eql(u8, f.label, "main.zig")) {
            saw_child = true;
        },
        else => {},
    };
    try std.testing.expect(saw_child);

    // 자식이 둘이 되면 더는 접지 않는다.
    try tree.applySnapshot("/w/release", &.{ .{ .name = "app", .kind = .directory }, .{ .name = "notes.md", .kind = .file } });
    try tree.buildRows(allocator, &.{}, &rows);
    var saw_release_only = false;
    for (rows.items) |row| switch (row) {
        .directory => |d| if (d.depth == 1 and std.mem.eql(u8, d.label, "release")) {
            saw_release_only = true;
        },
        else => {},
    };
    try std.testing.expect(saw_release_only);
}

test "file tree compact + 무시: 접힌 줄의 무시 판정은 **끝 노드**에서 온다" {
    // 두 기능이 만나는 자리다(체인 접기 ← → git 무시 표시). 접힌 줄이 가리키는 경로는 끝 노드이므로
    // 흐려지는 근거도 그 노드에서 와야 한다 — 중간 노드에서 가져오면 사용자가 보는 경로와 어긋난다.
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/w"});
    try tree.applySnapshot("/w", &.{.{ .name = "build", .kind = .directory }});
    try tree.applySnapshot("/w/build", &.{.{ .name = "out", .kind = .directory }});
    try tree.applySnapshot("/w/build/out", &.{.{ .name = "app.js", .kind = .file }});

    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);

    // 끝 노드만 무시로 표시한다(git 이 실제로 답하는 대상은 화면에 보이는 그 경로다).
    tree.markIgnored("/w/build/out", true);
    try tree.buildRows(allocator, &.{}, &rows);
    var found = false;
    for (rows.items) |row| switch (row) {
        .directory => |d| if (std.mem.eql(u8, d.path, "/w/build/out")) {
            try std.testing.expectEqualStrings("build/out", d.label); // 접힌 줄이 맞다
            try std.testing.expect(d.ignored);
            found = true;
        },
        else => {},
    };
    try std.testing.expect(found);

    // 중간 노드만 표시된 상태로는 그 줄이 흐려지지 않는다 — 판정의 출처가 끝 노드 하나임을 못 박는다.
    tree.markIgnored("/w/build/out", false);
    tree.markIgnored("/w/build", true);
    try tree.buildRows(allocator, &.{}, &rows);
    for (rows.items) |row| switch (row) {
        .directory => |d| if (std.mem.eql(u8, d.path, "/w/build/out")) {
            try std.testing.expect(!d.ignored);
        },
        else => {},
    };
}

test "전체 접기: 루트는 남기고 그 아래를 모두 접는다" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/w"});
    while (tree.takeScanRequest()) |owned| std.testing.allocator.free(owned);
    try tree.applySnapshot("/w", &.{
        .{ .name = "src", .kind = .directory },
        .{ .name = "a.txt", .kind = .file },
    });
    _ = try tree.toggleDirectory("/w/src");
    while (tree.takeScanRequest()) |owned| std.testing.allocator.free(owned);
    try tree.applySnapshot("/w/src", &.{.{ .name = "deep", .kind = .directory }});
    _ = try tree.toggleDirectory("/w/src/deep");

    try std.testing.expect(tree.collapseAll());
    // 루트는 그대로 펼쳐져 있다 — 접으면 남는 것이 이름 한 줄뿐이다.
    try std.testing.expect(tree.roots.items[0].expanded);
    try std.testing.expect(!tree.findNode("/w/src").?.expanded);
    // 접힌 부모 **아래**도 접힌다. 안 그러면 부모를 다시 펼쳤을 때 접기 전 깊이가 통째로 돌아온다.
    try std.testing.expect(!tree.findNode("/w/src/deep").?.expanded);
    // 이미 다 접혀 있으면 바뀐 것이 없다(호출자가 no-op 으로 둘 수 있다).
    try std.testing.expect(!tree.collapseAll());
}

test "전체 접기는 scan 을 예약하지 않는다 — 감추는 동작이지 다시 읽는 동작이 아니다" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/w"});
    while (tree.takeScanRequest()) |owned| std.testing.allocator.free(owned);
    try tree.applySnapshot("/w", &.{.{ .name = "src", .kind = .directory }});
    _ = try tree.toggleDirectory("/w/src");
    while (tree.takeScanRequest()) |owned| std.testing.allocator.free(owned);

    _ = tree.collapseAll();
    try std.testing.expect(tree.takeScanRequest() == null);
}

test "펼친 것만 다시 읽는다: 접힌 서브트리는 예약에 안 든다 (RF5a)" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/w"});
    while (tree.takeScanRequest()) |owned| std.testing.allocator.free(owned);
    try tree.applySnapshot("/w", &.{
        .{ .name = "open", .kind = .directory },
        .{ .name = "shut", .kind = .directory },
        .{ .name = "a.txt", .kind = .file },
    });
    _ = try tree.toggleDirectory("/w/open");
    while (tree.takeScanRequest()) |owned| std.testing.allocator.free(owned);
    try tree.applySnapshot("/w/open", &.{.{ .name = "deep", .kind = .directory }});
    _ = try tree.toggleDirectory("/w/open/deep");
    while (tree.takeScanRequest()) |owned| std.testing.allocator.free(owned);

    try std.testing.expect(try tree.invalidateExpanded());

    // root + 펼친 둘 = 셋. 접힌 `shut` 과 파일은 안 든다(안 보이는 것을 읽으면 왕복만 는다).
    var seen: std.ArrayList([]u8) = .empty;
    defer {
        for (seen.items) |p| std.testing.allocator.free(p);
        seen.deinit(std.testing.allocator);
    }
    while (tree.takeScanRequest()) |owned| try seen.append(std.testing.allocator, owned);
    try std.testing.expectEqual(@as(usize, 3), seen.items.len);
    var has_root = false;
    var has_open = false;
    var has_deep = false;
    for (seen.items) |p| {
        if (std.mem.eql(u8, p, "/w")) has_root = true;
        if (std.mem.eql(u8, p, "/w/open")) has_open = true;
        if (std.mem.eql(u8, p, "/w/open/deep")) has_deep = true;
        try std.testing.expect(!std.mem.eql(u8, p, "/w/shut"));
        try std.testing.expect(!std.mem.eql(u8, p, "/w/a.txt"));
    }
    try std.testing.expect(has_root and has_open and has_deep);
}

test "트리거가 몰려도 예약이 안 자란다 — 중복 제거가 진다 (RF5a)" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{"/w"});
    while (tree.takeScanRequest()) |owned| std.testing.allocator.free(owned);
    try tree.applySnapshot("/w", &.{.{ .name = "src", .kind = .directory }});
    _ = try tree.toggleDirectory("/w/src");
    while (tree.takeScanRequest()) |owned| std.testing.allocator.free(owned);

    // 감시자가 트리거를 연달아 냈다 — 큐는 그래도 「root + src」 둘이다.
    for (0..50) |_| _ = try tree.invalidateExpanded();
    var count: usize = 0;
    while (tree.takeScanRequest()) |owned| {
        std.testing.allocator.free(owned);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "펼친 것이 없으면 예약도 없다 — 호출자가 no-op 으로 둔다 (RF5a)" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();
    // root 조차 없는 빈 트리(원격이 아직 안 붙었거나 못 읽어 접힌 상태).
    try std.testing.expect(!try tree.invalidateExpanded());
    try std.testing.expect(tree.takeScanRequest() == null);
}
