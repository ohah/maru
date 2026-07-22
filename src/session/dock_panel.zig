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
/// 새 값을 더하되, 트리·탭 소유 모델은 그대로 재사용한다(docs/file-panel.md §1·§2.2). `text`는 markdown과 같은
/// 신뢰 shell·`maru.file.read/write` 브리지를 쓰지만 라이브 프리뷰·mode 선택기·링크가 없는 소스 전용 편집기다(FP12).
pub const EntryKind = enum {
    markdown,
    html,
    text,
    svg,
    image,
    pdf,

    /// 신뢰 shell에서 CM6를 마운트하고 `maru.file.read/write` 브리지로 편집하는 kind인지. read/write·dirty·저장·
    /// document epoch·외부변경·초기 hydration identity 보호 게이트가 이 술어를 공유한다(§2.2·§3). markdown 라이브
    /// 프리뷰·링크·readAsset·mermaid 전용 경로는 별도로 `== .markdown`을 유지한다. svg는 소스 편집(xml)이 이 브리지를
    /// 쓰고 읽기 모드는 격리 render origin의 sanitize 프리뷰다(§2.2·FP13).
    pub fn usesEditorBridge(self: EntryKind) bool {
        return switch (self) {
            .markdown, .text, .svg => true,
            // image(FP14)는 신뢰 shell이지만 CM6 편집기가 없다(readSelfImage로 자기 바이너리만 읽어 panzoom read
            // 프리뷰). html·pdf는 격리 loadFileURL. 셋 다 CM6 편집기·editor_epoch 문서 흐름을 쓰지 않는다(§2.2).
            .html, .image, .pdf => false,
        };
    }
};

/// 파일 도크 표시 모드. enum ordinal은 C ABI raw 값, workspaceName/parseWorkspaceName은 workspace 문자열 wire의
/// 정책 SSOT다. 헤더의 시각 순서·kind별 선택지는 `dock_layout.modesForKind`가 별도로 고정한다. HTML은 read만 허용하고
/// Markdown의 두 편집 모드는 같은 dirty/save 수명 계약을 소비한다.
pub const Mode = enum(u32) {
    read = 0,
    source_edit = 1,
    live_preview = 2,

    /// 새 entry의 시작 모드는 kind 정책에서 한 번만 정한다. 복원 entry는 workspace에 저장된 mode를 그대로
    /// 덮어쓰므로 이 기본값과 독립이고, HTML은 실행 가능한 문서라 계속 read-only로 시작한다.
    pub fn defaultFor(kind: EntryKind) Mode {
        return switch (kind) {
            // 라이브 프리뷰는 백로그(2026-07-22)라 markdown도 읽기로 시작한다. 라이브 재도입 시 .live_preview로 되돌린다.
            .markdown => .read,
            // html·pdf=격리 loadFileURL, image=신뢰 뷰어+readSelfImage(FP14) — 셋 다 read 뷰 전용(편집·모드 없음).
            .html, .image, .pdf => .read,
            .text => .source_edit,
            .svg => .read, // 이미지 미리보기가 먼저(VSCode SVG 프리뷰 관례).
        };
    }

    pub fn allowedFor(self: Mode, kind: EntryKind) bool {
        return switch (kind) {
            // markdown은 읽기|소스만(라이브 백로그). 저장된 live-preview entry는 복원 시 parseDockEntry가 defaultFor로 clamp한다.
            .markdown => self == .read or self == .source_edit,
            .html, .image, .pdf => self == .read, // read 뷰 전용(편집·모드 없음).
            .text => self == .source_edit,
            .svg => self == .read or self == .source_edit, // 라이브 없음.
        };
    }

    pub fn isEditable(self: Mode) bool {
        return self == .source_edit or self == .live_preview;
    }

    pub fn workspaceName(self: Mode) []const u8 {
        return switch (self) {
            .read => "read",
            .source_edit => "source-edit",
            .live_preview => "live-preview",
        };
    }

    pub fn parseWorkspaceName(raw: []const u8) ?Mode {
        inline for (std.enums.values(Mode)) |mode| {
            if (std.mem.eql(u8, raw, mode.workspaceName())) return mode;
        }
        return null;
    }
};

/// 파일 entry의 앱-런타임 전역 identity. path는 rename으로, surface_id는 LRU eviction/recreate로 바뀔 수 있어
/// drag·비동기 ack가 위치를 다시 찾는 키로 쓸 수 없다. 0은 미할당 sentinel이며 발급한 값은 close 뒤에도 재사용하지 않는다.
pub const EntryId = u64;

/// AppRuntime이 인스턴스 하나를 소유하고 각 DockPanel에 주입하는 순수 L2 발급기. 메인 actor 전용이며, wrap 시
/// 0이나 과거 값을 재발급하는 대신 fail-closed한다.
pub const EntryIdAllocator = struct {
    next_id: EntryId = 1,

    pub fn next(self: *EntryIdAllocator) !EntryId {
        if (self.next_id == 0 or self.next_id == std.math.maxInt(EntryId)) return error.EntryIdExhausted;
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

pub const Entry = struct {
    id: EntryId,
    path: []u8,
    kind: EntryKind,
    /// 런타임 entry 생성자는 신규 정책(`Mode.defaultFor`)인지 복원된 명시 mode인지 반드시 선택한다.
    /// wire 호환용 `.read` fallback은 `PersistedEntry`에만 남겨 둘을 조용히 섞지 않는다.
    mode: Mode,
    dirty: bool = false,
    /// FP6 two-phase dirty mirror. source editor가 비활성/읽기 모드로 넘어갈 때 true로 세우고 shell의 강제
    /// setDirty snapshot ack에서만 내린다. ack 전에는 non-dirty라도 live view eviction 대상이 아니다.
    dirty_sync_pending: bool = false,
    /// shell이 보고한 CM6 문서 revision. close request의 request_id/revision ack와 함께 stale clean/save 완료를 거부한다.
    editor_revision: u64 = 0,
    /// 같은 surface에서 WebContent document가 교체돼 revision clock이 0으로 돌아가도 이전 document의 ACK가 새
    /// 편집 상태를 덮지 못하게 하는 런타임 generation. bridge beginDocument만 증가시키며 workspace에는 저장하지 않는다.
    editor_epoch: u64 = 0,
    /// document id는 신뢰 shell URL이 가진 surface-local 단조 navigation identity다. 같은 document의 begin 재시도는
    /// idempotent하게 같은 epoch를 받고, 이전 document의 늦은 begin/read는 거부한다. surface id 교체 시 새 수명으로 본다.
    editor_surface_id: u64 = 0,
    editor_document_id: u64 = 0,
    editor_document_active: bool = false,
    /// dirty/pending document를 잃은 WebContent reload는 disk hydration으로 clean을 추정할 수 없다. 명시적 복구 UX가
    /// 생길 때까지 save/clean ACK/eviction/mutation을 fail-close하는 catastrophic recovery latch다.
    editor_recovery_required: bool = false,
    /// 마지막 성공 Markdown read/save의 디스크 content token. 저장 직전 같은 inode의 in-place 외부 변경도 감지한다.
    disk_content_hash: u64 = 0,
    disk_content_hash_valid: bool = false,
    /// Materialized explorer row에서 새 Markdown entry를 만든 경우 최초 hydration이 같은 regular file을
    /// 읽는지 확인하는 transient identity. workspace에는 저장하지 않으며 첫 exact-fd read 뒤 해제한다.
    initial_file_identity_device: u64 = 0,
    initial_file_identity_inode: u64 = 0,
    initial_file_identity_kind: u8 = 0,
    initial_file_identity_pending: bool = false,
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
    /// File-tree rename/delete reservation. Nonzero blocks bridge reads/writes, dirty reports, reload and
    /// close until the exact background request commits or rolls back. It is transient and never persisted.
    mutation_pending_id: u64 = 0,
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
    /// Explorer launcher로 한 번 열린 도크인지. content와 분리해 explicit-empty 도크도 재시작 뒤 유지한다.
    presented: bool = false,
    entries: []const PersistedEntry = &.{},
    groups: []const PersistedGroup = &.{},
    tree: []const PersistedTreeNode = &.{},
    focused_group: usize = 0,
};

pub const DockGroup = struct {
    allocator: std.mem.Allocator,
    runtime_id: u64,
    entries: std.ArrayList(Entry) = .empty,
    active: ?usize = null,
    /// 탭 바 가로 스크롤 오프셋(컬럼). 탭은 고정폭이라 넘치면 스크롤한다(터미널 pane.tab_scroll_cols와 동형).
    /// 요청값은 렌더/히트테스트에서 [0,max]로 clamp되므로 stale 값이 자동 정정된다(런타임 전용, 영속 안 함).
    tab_scroll_cols: u32 = 0,

    fn init(allocator: std.mem.Allocator, runtime_id: u64) DockGroup {
        return .{ .allocator = allocator, .runtime_id = runtime_id };
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
    fn openLocal(self: *DockGroup, entry_id: EntryId, path: []const u8, kind: EntryKind) !usize {
        if (entry_id == 0) return error.InvalidEntryId;
        if (path.len == 0) return error.InvalidPath;
        if (self.findPath(path)) |i| {
            self.active = i;
            return i;
        }
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.entries.append(self.allocator, .{
            .id = entry_id,
            .path = owned,
            .kind = kind,
            .mode = Mode.defaultFor(kind),
        });
        const i = self.entries.items.len - 1;
        self.active = i;
        return i;
    }

    /// 단일 파일 탭을 순서 보존으로 제거하고 소유권을 호출자에게 넘긴다. 호출자는 runtime surface/one-shot을
    /// 정리한 뒤 `removed.path`를 allocator로 해제해야 한다. 활성 탭이면 오른쪽 이웃을 우선하고, 없으면 왼쪽을
    /// 활성화한다. 비활성 탭 제거는 기존 활성 항목의 identity를 보존하도록 index만 보정한다.
    pub fn remove(self: *DockGroup, index: usize) ?Entry {
        if (index >= self.entries.items.len) return null;
        const old_active = self.active;
        const removed = self.entries.orderedRemove(index);
        if (self.entries.items.len == 0) {
            self.active = null;
        } else if (old_active) |active| {
            if (active == index) {
                self.active = if (index < self.entries.items.len) index else self.entries.items.len - 1;
            } else if (active > index) {
                self.active = active - 1;
            }
        }
        return removed;
    }
};

/// 기존 workspace split 수학을 파일 그룹 leaf에 그대로 인스턴스화한다. 트리는 split 노드만 소유하고 DockPanel이
/// 각 `*DockGroup` leaf의 주소 안정성과 해제를 책임진다.
pub const DockTree = split_tree.SplitTree(*DockGroup);

pub const DockDropEdge = enum { left, right, top, bottom };

/// 탭 바 boundary는 source 제거 전 보이는 0...N 좌표다. split은 editor 전체 X자 방향 zone의 결과다.
pub const DockDropTarget = union(enum) {
    tab_bar: usize,
    split: DockDropEdge,
};

pub const DropResult = struct {
    changed: bool,
    source_successor_entry_id: ?EntryId,
    destination_active_entry_id: EntryId,
    destination_surface_id: ?u64,
};

pub const DockPanel = struct {
    allocator: std.mem.Allocator,
    entry_ids: *EntryIdAllocator,
    tree: DockTree.Node,
    side: Side = .right,
    size: u32 = 0,
    tree_size: u32 = 0,
    collapsed: bool = false,
    presented: bool = false,
    focused_group: *DockGroup,
    next_group_id: u64 = 2,

    pub fn init(allocator: std.mem.Allocator, entry_ids: *EntryIdAllocator) !DockPanel {
        const group = try allocator.create(DockGroup);
        group.* = DockGroup.init(allocator, 1);
        return .{ .allocator = allocator, .entry_ids = entry_ids, .tree = .{ .leaf = group }, .focused_group = group };
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

    pub fn groupForRuntimeId(self: *DockPanel, runtime_id: u64) ?*DockGroup {
        if (runtime_id == 0) return null;
        return findGroupForRuntimeId(self.tree, runtime_id);
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
    pub const EntryLocation = struct { group: *DockGroup, index: usize };
    pub const EntryLookupCounters = struct { entry_visits: usize = 0 };

    pub fn pathLocation(self: *DockPanel, path: []const u8) ?PathLocation {
        return findPath(self.tree, path);
    }

    pub fn entryLocation(self: *const DockPanel, entry_id: EntryId) ?EntryLocation {
        return self.entryLocationCounted(entry_id, null);
    }

    pub fn entryLocationCounted(self: *const DockPanel, entry_id: EntryId, counters: ?*EntryLookupCounters) ?EntryLocation {
        if (entry_id == 0) return null;
        return findEntryId(self.tree, entry_id, counters);
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
            self.presented = true;
            return .{ .group = found.group, .index = found.index, .created = false, .previous_active = previous_active };
        }
        if (entryCount(self.tree) >= max_entries) return error.TooManyEntries;
        const previous_active = target.active;
        const entry_id = try self.entry_ids.next();
        const index = try target.openLocal(entry_id, path, kind);
        self.focused_group = target;
        self.presented = true;
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

    fn findEntryId(node: DockTree.Node, entry_id: EntryId, counters: ?*EntryLookupCounters) ?EntryLocation {
        return switch (node) {
            .leaf => |group| blk: {
                for (group.entries.items, 0..) |entry, index| {
                    if (counters) |stats| stats.entry_visits += 1;
                    if (entry.id == entry_id) break :blk .{ .group = group, .index = index };
                }
                break :blk null;
            },
            .split => |sp| findEntryId(sp.a, entry_id, counters) orelse findEntryId(sp.b, entry_id, counters),
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

    fn firstEmptyGroup(node: DockTree.Node, skip: ?*const DockGroup) ?*DockGroup {
        return switch (node) {
            .leaf => |group| if (group.entries.items.len == 0 and (skip == null or group != skip.?)) group else null,
            .split => |sp| firstEmptyGroup(sp.a, skip) orelse firstEmptyGroup(sp.b, skip),
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

    fn findGroupForRuntimeId(node: DockTree.Node, runtime_id: u64) ?*DockGroup {
        return switch (node) {
            .leaf => |group| if (group.runtime_id == runtime_id) group else null,
            .split => |sp| findGroupForRuntimeId(sp.a, runtime_id) orelse findGroupForRuntimeId(sp.b, runtime_id),
        };
    }

    fn activeEntryId(group: *const DockGroup) ?EntryId {
        const index = group.active orelse return null;
        if (index >= group.entries.items.len) return null;
        return group.entries.items[index].id;
    }

    fn activeSurfaceId(group: *const DockGroup) ?u64 {
        const index = group.active orelse return null;
        if (index >= group.entries.items.len) return null;
        const surface_id = group.entries.items[index].surface_id;
        return if (surface_id == 0) null else surface_id;
    }

    fn indexForEntryId(group: *const DockGroup, entry_id: EntryId) ?usize {
        for (group.entries.items, 0..) |entry, index| if (entry.id == entry_id) return index;
        return null;
    }

    fn pendingGroupRuntimeId(self: *const DockPanel) !u64 {
        if (self.next_group_id == 0 or self.next_group_id == std.math.maxInt(u64)) return error.GroupIdExhausted;
        return self.next_group_id;
    }

    /// 단일 entry drop transaction. 모든 allocation/capacity reserve를 source detach 전에 끝내므로 오류가 나면
    /// entry/dirty/surface/tree/active/focus가 그대로다. 성공 commit 구간은 orderedRemove/insertAssumeCapacity와
    /// 미리 만든 tree node 교체뿐이라 실패하지 않는다.
    pub fn commitEntryDrop(
        self: *DockPanel,
        entry_id: EntryId,
        target_group_id: u64,
        target: DockDropTarget,
    ) !DropResult {
        const source = self.entryLocation(entry_id) orelse return error.EntryNotFound;
        const destination = self.groupForRuntimeId(target_group_id) orelse return error.GroupNotFound;

        switch (target) {
            .tab_bar => |boundary| {
                if (boundary > destination.entries.items.len) return error.InvalidDropTarget;
                if (source.group == destination) {
                    const active_id = activeEntryId(source.group) orelse return error.InvalidModel;
                    if (boundary == source.index or boundary == source.index + 1) {
                        return .{
                            .changed = false,
                            .source_successor_entry_id = active_id,
                            .destination_active_entry_id = active_id,
                            .destination_surface_id = activeSurfaceId(source.group),
                        };
                    }
                    const adjusted = boundary - @intFromBool(boundary > source.index);
                    const moved = source.group.entries.orderedRemove(source.index);
                    source.group.entries.insertAssumeCapacity(adjusted, moved);
                    source.group.active = indexForEntryId(source.group, active_id) orelse unreachable;
                    return .{
                        .changed = true,
                        .source_successor_entry_id = active_id,
                        .destination_active_entry_id = active_id,
                        .destination_surface_id = activeSurfaceId(source.group),
                    };
                }

                try destination.entries.ensureUnusedCapacity(self.allocator, 1);
                const moved = source.group.remove(source.index) orelse unreachable;
                const source_successor = activeEntryId(source.group);
                destination.entries.insertAssumeCapacity(boundary, moved);
                destination.active = boundary;
                self.focused_group = destination;
                if (source.group.entries.items.len == 0) std.debug.assert(self.removeGroup(source.group));
                return .{
                    .changed = true,
                    .source_successor_entry_id = source_successor,
                    .destination_active_entry_id = moved.id,
                    .destination_surface_id = if (moved.surface_id == 0) null else moved.surface_id,
                };
            },
            .split => |edge| {
                // 유일한 entry를 같은 leaf에서 떼 새 leaf에 넣고 옛 leaf를 접으면 관측 가능한 split이 남지 않는다.
                // cap/allocation보다 먼저 판정해 명시적 split action과 body drop이 빈 sibling을 만들지 않게 한다.
                if (source.group == destination and source.group.entries.items.len == 1) {
                    return .{
                        .changed = false,
                        .source_successor_entry_id = entry_id,
                        .destination_active_entry_id = entry_id,
                        .destination_surface_id = activeSurfaceId(source.group),
                    };
                }
                if (self.groupCount() >= max_groups) return error.TooManyGroups;
                const runtime_id = try self.pendingGroupRuntimeId();
                const group = try self.allocator.create(DockGroup);
                errdefer self.allocator.destroy(group);
                group.* = DockGroup.init(self.allocator, runtime_id);
                errdefer group.deinit();
                try group.entries.ensureTotalCapacity(self.allocator, 1);

                const split = try self.allocator.create(DockTree.Split);
                errdefer self.allocator.destroy(split);
                const direction: split_tree.SplitDirection = switch (edge) {
                    .left, .right => .horizontal,
                    .top, .bottom => .vertical,
                };
                const new_first = edge == .left or edge == .top;
                split.* = .{
                    .direction = direction,
                    .ratio = 0.5,
                    .a = if (new_first) .{ .leaf = group } else .{ .leaf = destination },
                    .b = if (new_first) .{ .leaf = destination } else .{ .leaf = group },
                };

                self.next_group_id += 1; // 모든 fallible 준비가 끝난 no-fail commit에서만 ID를 소비한다.
                const moved = source.group.remove(source.index) orelse unreachable;
                const source_successor = activeEntryId(source.group);
                group.entries.appendAssumeCapacity(moved);
                group.active = 0;
                std.debug.assert(DockTree.replaceLeaf(&self.tree, destination, .{ .split = split }));
                self.focused_group = group;
                if (source.group.entries.items.len == 0) std.debug.assert(self.removeGroup(source.group));
                return .{
                    .changed = true,
                    .source_successor_entry_id = source_successor,
                    .destination_active_entry_id = moved.id,
                    .destination_surface_id = if (moved.surface_id == 0) null else moved.surface_id,
                };
            },
        }
    }

    /// FP8 UI가 쓸 additive 연산을 FP1 모델에서 먼저 고정한다. target leaf는 a에 남고 새 빈 그룹은 b가 된다.
    fn splitGroup(self: *DockPanel, target: *DockGroup, direction: split_tree.SplitDirection, ratio: f32) !*DockGroup {
        if (!containsGroup(self.tree, target)) return error.GroupNotFound;
        if (self.groupCount() >= max_groups) return error.TooManyGroups;
        const group = try self.allocator.create(DockGroup);
        errdefer self.allocator.destroy(group);
        const runtime_id = try self.pendingGroupRuntimeId();
        group.* = DockGroup.init(self.allocator, runtime_id);
        errdefer group.deinit();

        const split = try self.allocator.create(DockTree.Split);
        errdefer self.allocator.destroy(split);
        split.* = .{
            .direction = direction,
            .ratio = split_tree.clampRatio(ratio),
            .a = .{ .leaf = target },
            .b = .{ .leaf = group },
        };
        self.next_group_id += 1; // allocation 실패는 runtime id cursor까지 byte-identical하게 보존한다.
        std.debug.assert(DockTree.replaceLeaf(&self.tree, target, .{ .split = split }));
        self.focused_group = group;
        return group;
    }

    /// 마지막 그룹은 도크 모델의 루트이므로 제거하지 않는다. focused leaf 제거 시 보이는 preorder에서 오른쪽,
    /// 없으면 왼쪽 이웃으로 focus를 넘긴다. 중첩 leaf 제거 시 SplitTree가 돌려준 split 노드를 호출자가 정확히
    /// 한 번 destroy하고, 제거된 그룹의 entry/path도 함께 정리한다.
    pub fn removeGroup(self: *DockPanel, target: *DockGroup) bool {
        const target_index = if (self.focused_group == target) self.groupIndex(target) else null;
        const freed = DockTree.removeLeaf(&self.tree, target) orelse return false;
        const was_focused = self.focused_group == target;
        target.deinit();
        self.allocator.destroy(target);
        self.allocator.destroy(freed);
        if (was_focused) {
            const successor_index = @min(target_index orelse 0, self.groupCount() - 1);
            self.focused_group = self.groupAt(successor_index) orelse firstGroup(self.tree);
        }
        return true;
    }

    /// 추가 empty leaf는 모델 밖으로 publish하지 않는다. content가 하나라도 있으면 모든 empty leaf를 접고,
    /// 전체가 비었으면 focused root 하나만 보존한다. 순회/제거는 group cap(64) 안이며 allocation·I/O가 없다.
    pub fn pruneEmptyGroups(self: *DockPanel) usize {
        const all_empty = self.entryCountTotal() == 0;
        var removed: usize = 0;
        while (self.groupCount() > 1) {
            const target = firstEmptyGroup(self.tree, if (all_empty) self.focused_group else null) orelse break;
            if (!self.removeGroup(target)) break;
            removed += 1;
        }
        return removed;
    }

    pub fn hasRedundantEmptyGroup(self: *const DockPanel) bool {
        return self.groupCount() > 1 and firstEmptyGroup(self.tree, null) != null;
    }

    /// workspace.v1 DTO에서 라이브 소유 모델을 복구한다. 단일 그룹 legacy 표현과 FP8 preorder 표현은 상호 배타다.
    /// dirty/runtime handle은 persisted DTO에 없으므로 항상 초기값으로 돌아온다.
    pub fn restore(allocator: std.mem.Allocator, entry_ids: *EntryIdAllocator, state: PersistedState) !DockPanel {
        if (state.entries.len > max_entries or state.groups.len > max_groups) return error.InvalidPersistedState;
        if (state.groups.len != 0 and state.entries.len != 0) return error.InvalidPersistedState;
        var panel = try DockPanel.init(allocator, entry_ids);
        errdefer panel.deinit();
        panel.side = state.side;
        panel.size = state.size;
        panel.tree_size = state.tree_size;
        panel.collapsed = state.collapsed;
        panel.presented = state.presented;

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
                group.* = DockGroup.init(allocator, @as(u64, @intCast(group_index)) + 1);
                groups[group_index] = group;
                initialized += 1;
                try restoreEntries(entry_ids, group, persisted_group.entries);
                for (groups[0..group_index]) |prior_group| {
                    for (group.entries.items) |entry| if (prior_group.findPath(entry.path) != null) return error.InvalidPersistedState;
                }
            }
            panel.next_group_id = @as(u64, @intCast(state.groups.len)) + 1;

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
            _ = panel.pruneEmptyGroups();
            return panel;
        }

        if (state.tree.len != 0) return error.InvalidPersistedState;
        const group = panel.singleGroup().?;
        try restoreEntries(entry_ids, group, state.entries);
        panel.focused_group = group;
        return panel;
    }

    fn restoreEntries(entry_ids: *EntryIdAllocator, group: *DockGroup, entries: []const PersistedEntry) !void {
        var active: ?usize = null;
        for (entries) |entry| {
            if (entry.path.len == 0 or group.findPath(entry.path) != null or !entry.mode.allowedFor(entry.kind)) return error.InvalidPersistedState;
            const i = try group.openLocal(try entry_ids.next(), entry.path, entry.kind);
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
        // 추가 empty leaf는 runtime transition 중에도 workspace wire로 publish하지 않는다. Production split/remove는
        // transaction API를 쓰고, 이 guard는 향후 low-level 호출 누락을 fail-closed한다.
        if (self.hasRedundantEmptyGroup()) return error.InvalidPersistedState;
        if (self.singleGroup()) |group| {
            const entries = try persistEntries(allocator, group);
            return .{ .side = self.side, .size = self.size, .tree_size = self.tree_size, .collapsed = self.collapsed, .presented = self.presented, .entries = entries };
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
            .presented = self.presented,
            .groups = groups,
            .tree = nodes,
            .focused_group = focused_group,
        };
    }

    fn persistEntries(allocator: std.mem.Allocator, group: *const DockGroup) ![]PersistedEntry {
        if ((group.entries.items.len > 0 and group.active == null) or
            (group.active != null and group.active.? >= group.entries.items.len) or
            group.entries.items.len > max_entries) return error.InvalidPersistedState;
        for (group.entries.items) |entry| if (!entry.mode.allowedFor(entry.kind)) return error.InvalidPersistedState;
        const entries = try allocator.alloc(PersistedEntry, group.entries.items.len);
        for (group.entries.items, 0..) |entry, i| {
            entries[i] = .{
                .path = entry.path,
                .kind = entry.kind,
                .mode = entry.mode,
                .active = group.active != null and group.active.? == i,
            };
        }
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

test "EntryKind/Mode policy: markdown, html, text (FP12 §2.2)" {
    // 신뢰 편집 브리지 kind: markdown+text만. html은 격리 read-only.
    try std.testing.expect(EntryKind.markdown.usesEditorBridge());
    try std.testing.expect(EntryKind.text.usesEditorBridge());
    try std.testing.expect(!EntryKind.html.usesEditorBridge());

    // 기본 모드: markdown=읽기(라이브 백로그), html=읽기, text=소스.
    try std.testing.expectEqual(Mode.read, Mode.defaultFor(.markdown));
    try std.testing.expectEqual(Mode.read, Mode.defaultFor(.html));
    try std.testing.expectEqual(Mode.source_edit, Mode.defaultFor(.text));
    try std.testing.expectEqual(Mode.read, Mode.defaultFor(.image)); // FP14: read 뷰 전용.
    try std.testing.expectEqual(Mode.read, Mode.defaultFor(.pdf)); // FP15: read 뷰 전용.

    // 허용 모드: markdown=읽기|소스(라이브 백로그), html=read만, text=source_edit만, image/pdf=read만(격리 loadFileURL).
    try std.testing.expect(Mode.read.allowedFor(.markdown) and Mode.source_edit.allowedFor(.markdown) and !Mode.live_preview.allowedFor(.markdown));
    try std.testing.expect(Mode.read.allowedFor(.html) and !Mode.source_edit.allowedFor(.html) and !Mode.live_preview.allowedFor(.html));
    try std.testing.expect(Mode.source_edit.allowedFor(.text) and !Mode.read.allowedFor(.text) and !Mode.live_preview.allowedFor(.text));
    inline for (.{ EntryKind.image, EntryKind.pdf }) |kind| {
        try std.testing.expect(Mode.read.allowedFor(kind) and !Mode.source_edit.allowedFor(kind) and !Mode.live_preview.allowedFor(kind));
    }

    // 새 entry의 기본 모드는 항상 자기 kind에서 허용된다(복원 검증 불변식과 일치). 모든 kind를 exhaustive하게 검증한다.
    inline for (std.enums.values(EntryKind)) |kind| {
        try std.testing.expect(Mode.defaultFor(kind).allowedFor(kind));
    }
}

test "entry id allocator: monotonic nonzero and exhaustion fails closed" {
    var ids: EntryIdAllocator = .{};
    try std.testing.expectEqual(@as(EntryId, 1), try ids.next());
    try std.testing.expectEqual(@as(EntryId, 2), try ids.next());
    ids.next_id = std.math.maxInt(EntryId);
    try std.testing.expectError(error.EntryIdExhausted, ids.next());
    try std.testing.expectEqual(std.math.maxInt(EntryId), ids.next_id);
}

test "dock panel drop: same-group visible boundaries preserve active identity" {
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
    defer panel.deinit();
    const group = panel.singleGroup().?;
    _ = try panel.open(group, "/tmp/a.md", .markdown);
    _ = try panel.open(group, "/tmp/b.md", .markdown);
    _ = try panel.open(group, "/tmp/c.md", .markdown);
    group.active = 2;
    const a = group.entries.items[0].id;
    const b = group.entries.items[1].id;
    const c = group.entries.items[2].id;

    const no_op = try panel.commitEntryDrop(b, group.runtime_id, .{ .tab_bar = 2 });
    try std.testing.expect(!no_op.changed);
    try std.testing.expectEqualSlices(EntryId, &.{ a, b, c }, &.{ group.entries.items[0].id, group.entries.items[1].id, group.entries.items[2].id });

    const moved = try panel.commitEntryDrop(a, group.runtime_id, .{ .tab_bar = 3 });
    try std.testing.expect(moved.changed);
    try std.testing.expectEqualSlices(EntryId, &.{ b, c, a }, &.{ group.entries.items[0].id, group.entries.items[1].id, group.entries.items[2].id });
    try std.testing.expectEqual(c, group.entries.items[group.active.?].id);
    try std.testing.expectEqual(c, moved.destination_active_entry_id);
}

test "dock panel drop: cross-group active and background moves preserve entry state" {
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
    defer panel.deinit();
    const source = panel.singleGroup().?;
    _ = try panel.open(source, "/tmp/a.md", .markdown);
    _ = try panel.open(source, "/tmp/b.md", .markdown);
    _ = try panel.open(source, "/tmp/c.md", .markdown);
    const destination = try panel.splitGroup(source, .horizontal, 0.5);
    _ = try panel.open(destination, "/tmp/d.md", .markdown);
    source.active = 1;
    const a = source.entries.items[0].id;
    const b = source.entries.items[1].id;
    const c = source.entries.items[2].id;
    source.entries.items[0].dirty = true;
    source.entries.items[0].surface_id = 77;

    const background = try panel.commitEntryDrop(a, destination.runtime_id, .{ .tab_bar = 0 });
    try std.testing.expect(background.changed);
    try std.testing.expectEqual(b, background.source_successor_entry_id.?);
    try std.testing.expectEqual(a, background.destination_active_entry_id);
    try std.testing.expectEqual(@as(?u64, 77), background.destination_surface_id);
    try std.testing.expect(destination.entries.items[0].dirty);
    try std.testing.expectEqual(a, destination.entries.items[0].id);
    try std.testing.expectEqual(b, source.entries.items[source.active.?].id);

    const active = try panel.commitEntryDrop(b, destination.runtime_id, .{ .tab_bar = destination.entries.items.len });
    try std.testing.expectEqual(c, active.source_successor_entry_id.?);
    try std.testing.expectEqual(b, destination.entries.items[destination.active.?].id);
    try std.testing.expectEqual(c, source.entries.items[source.active.?].id);
}

test "dock panel drop: four direction zones create deterministic preorder without empty source" {
    const cases = [_]struct { edge: DockDropEdge, new_first: bool, direction: split_tree.SplitDirection }{
        .{ .edge = .left, .new_first = true, .direction = .horizontal },
        .{ .edge = .right, .new_first = false, .direction = .horizontal },
        .{ .edge = .top, .new_first = true, .direction = .vertical },
        .{ .edge = .bottom, .new_first = false, .direction = .vertical },
    };
    for (cases) |case| {
        var entry_ids: EntryIdAllocator = .{};
        var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
        defer panel.deinit();
        const source = panel.singleGroup().?;
        _ = try panel.open(source, "/tmp/a.md", .markdown);
        _ = try panel.open(source, "/tmp/b.md", .markdown);
        const entry_id = source.entries.items[1].id;
        _ = try panel.commitEntryDrop(entry_id, source.runtime_id, .{ .split = case.edge });

        try std.testing.expectEqual(@as(usize, 2), panel.groupCount());
        try std.testing.expectEqual(@as(usize, 1), source.entries.items.len);
        const moved_group = panel.entryLocation(entry_id).?.group;
        try std.testing.expectEqual(case.new_first, panel.groupAt(0).? == moved_group);
        try std.testing.expectEqual(case.direction, panel.tree.split.direction);
        try std.testing.expectEqual(moved_group, panel.focusedGroup());
    }
}

test "dock panel drop: splitting the only entry into its own leaf is allocation-free no-op" {
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
    defer panel.deinit();
    const source = panel.singleGroup().?;
    _ = try panel.open(source, "/tmp/a.md", .markdown);
    const entry_id = source.entries.items[0].id;
    const next_group_before = panel.next_group_id;

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    panel.allocator = counting.allocator();
    const result = try panel.commitEntryDrop(entry_id, source.runtime_id, .{ .split = .right });
    panel.allocator = std.testing.allocator;

    try std.testing.expect(!result.changed);
    try std.testing.expectEqual(@as(usize, 1), panel.groupCount());
    try std.testing.expectEqual(entry_id, source.entries.items[0].id);
    try std.testing.expectEqual(next_group_before, panel.next_group_id);
    try std.testing.expectEqual(@as(usize, 0), counting.allocations);
}

test "dock panel drop: moving the final source entry collapses that leaf and focuses destination" {
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
    defer panel.deinit();
    const source = panel.singleGroup().?;
    _ = try panel.open(source, "/tmp/a.md", .markdown);
    const entry_id = source.entries.items[0].id;
    const destination = try panel.splitGroup(source, .horizontal, 0.5);
    _ = try panel.open(destination, "/tmp/b.md", .markdown);

    const result = try panel.commitEntryDrop(entry_id, destination.runtime_id, .{ .tab_bar = 1 });
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(@as(usize, 1), panel.groupCount());
    try std.testing.expectEqual(destination, panel.singleGroup().?);
    try std.testing.expectEqual(destination, panel.focusedGroup());
    try std.testing.expectEqual(entry_id, destination.entries.items[1].id);
}

test "dock panel drop: group cap rejects before mutating entry or tree" {
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
    defer panel.deinit();
    const source = panel.singleGroup().?;
    _ = try panel.open(source, "/tmp/a.md", .markdown);
    _ = try panel.open(source, "/tmp/b.md", .markdown);
    const entry_id = source.entries.items[0].id;
    var target = source;
    while (panel.groupCount() < max_groups) target = try panel.splitGroup(target, .horizontal, 0.5);
    const before_tree = panel.tree;
    var leaves: std.ArrayList(DockTree.LeafRect) = .empty;
    defer leaves.deinit(std.testing.allocator);
    try leaves.ensureTotalCapacity(std.testing.allocator, max_groups);
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    panel.allocator = counting.allocator();
    try std.testing.expectError(error.TooManyGroups, panel.commitEntryDrop(entry_id, target.runtime_id, .{ .split = .right }));
    try DockTree.layout(counting.allocator(), panel.tree, .{ .x = 0, .y = 0, .w = 6400, .h = 1200 }, &leaves);
    panel.allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), counting.allocations);
    try std.testing.expect(!counting.has_induced_failure);
    try std.testing.expectEqual(before_tree.split, panel.tree.split);
    try std.testing.expectEqual(entry_id, source.entries.items[0].id);
    try std.testing.expectEqual(@as(usize, max_groups), panel.groupCount());
}

test "dock panel drop: destination reserve OOM leaves source destination active and focus unchanged" {
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
    defer panel.deinit();
    const source = panel.singleGroup().?;
    _ = try panel.open(source, "/tmp/oom.md", .markdown);
    const entry_id = source.entries.items[0].id;
    source.entries.items[0].dirty = true;
    source.entries.items[0].surface_id = 91;
    const destination = try panel.splitGroup(source, .horizontal, 0.5);
    const focused_before = panel.focusedGroup();
    const next_group_before = panel.next_group_id;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    panel.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, panel.commitEntryDrop(entry_id, destination.runtime_id, .{ .tab_bar = 0 }));
    panel.allocator = std.testing.allocator;

    try std.testing.expectEqual(@as(usize, 1), source.entries.items.len);
    try std.testing.expectEqual(entry_id, source.entries.items[0].id);
    try std.testing.expect(source.entries.items[0].dirty);
    try std.testing.expectEqual(@as(u64, 91), source.entries.items[0].surface_id);
    try std.testing.expectEqual(@as(?usize, 0), source.active);
    try std.testing.expectEqual(@as(usize, 0), destination.entries.items.len);
    try std.testing.expectEqual(focused_before, panel.focusedGroup());
    try std.testing.expectEqual(next_group_before, panel.next_group_id);
}

test "dock panel drop: every split allocation failure preserves model and runtime id cursor" {
    inline for (0..3) |fail_index| {
        var entry_ids: EntryIdAllocator = .{};
        var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
        defer panel.deinit();
        const source = panel.singleGroup().?;
        _ = try panel.open(source, "/tmp/split-oom.md", .markdown);
        _ = try panel.open(source, "/tmp/split-oom-sibling.md", .markdown);
        const entry_id = source.entries.items[0].id;
        source.active = 0;
        source.entries.items[0].dirty_sync_pending = true;
        source.entries.items[0].surface_id = 92;
        const focused_before = panel.focusedGroup();
        const next_group_before = panel.next_group_id;

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        panel.allocator = failing.allocator();
        try std.testing.expectError(error.OutOfMemory, panel.commitEntryDrop(entry_id, source.runtime_id, .{ .split = .left }));
        panel.allocator = std.testing.allocator;

        try std.testing.expectEqual(@as(usize, 1), panel.groupCount());
        try std.testing.expectEqual(@as(usize, 2), source.entries.items.len);
        try std.testing.expectEqual(entry_id, source.entries.items[0].id);
        try std.testing.expect(source.entries.items[0].dirty_sync_pending);
        try std.testing.expectEqual(@as(u64, 92), source.entries.items[0].surface_id);
        try std.testing.expectEqual(@as(?usize, 0), source.active);
        try std.testing.expectEqual(focused_before, panel.focusedGroup());
        try std.testing.expectEqual(next_group_before, panel.next_group_id);
    }
}

test "dock panel: single group owns entries and reopening a path activates instead of duplicating" {
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
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
    try std.testing.expectEqual(Mode.read, group.entries.items[0].mode); // markdown=읽기(라이브 백로그)
    try std.testing.expectEqual(Mode.read, group.entries.items[1].mode);

    group.entries.items[0].mode = .source_edit;
    group.entries.items[0].dirty = true;
    try std.testing.expectEqual(Mode.source_edit, group.entries.items[0].mode);
    try std.testing.expect(group.entries.items[0].dirty);
}

test "dock panel mode defaults are kind-owned while restore preserves an explicit mode" {
    try std.testing.expectEqual(Mode.read, Mode.defaultFor(.markdown)); // 라이브 백로그
    try std.testing.expectEqual(Mode.read, Mode.defaultFor(.html));

    var entry_ids: EntryIdAllocator = .{};
    const persisted = [_]PersistedEntry{.{
        .path = "/tmp/restored.md",
        .kind = .markdown,
        .mode = .source_edit,
        .active = true,
    }};
    var restored = try DockPanel.restore(std.testing.allocator, &entry_ids, .{ .entries = &persisted });
    defer restored.deinit();
    try std.testing.expectEqual(Mode.source_edit, restored.singleGroup().?.entries.items[0].mode);
}

test "dock panel: entryForSurfaceId searches nested groups and rejects zero" {
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
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
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
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
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
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
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
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
    var entry_ids: EntryIdAllocator = .{};
    const entries = [_]PersistedEntry{
        .{ .path = "/tmp/a.md", .kind = .markdown, .mode = .source_edit, .active = true },
        .{ .path = "/tmp/b.html", .kind = .html, .mode = .read, .active = false },
    };
    var panel = try DockPanel.restore(std.testing.allocator, &entry_ids, .{
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
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
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
    try std.testing.expectError(error.InvalidPersistedState, panel.persistedState(std.testing.allocator));
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
    try std.testing.expectError(error.InvalidPersistedState, DockPanel.restore(std.testing.allocator, &entry_ids, .{ .entries = &ambiguous }));
}

test "dock panel: nested multi-group persistence restores focus entries and split ratios" {
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
    defer panel.deinit();
    const a = panel.singleGroup().?;
    _ = try panel.open(a, "/tmp/a.md", .markdown);
    const b = try panel.splitGroup(a, .horizontal, 0.4);
    _ = try panel.open(b, "/tmp/b.md", .markdown);
    const c = try panel.splitGroup(b, .vertical, 0.7);
    _ = try panel.open(c, "/tmp/c.md", .markdown);
    b.entries.items[0].mode = .source_edit;
    try std.testing.expectEqual(c, panel.focusedGroup());

    var state = try panel.persistedState(std.testing.allocator);
    defer freePersistedState(std.testing.allocator, &state);
    var restored = try DockPanel.restore(std.testing.allocator, &entry_ids, state);
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

test "dock panel: restore collapses legacy empty leaves before publishing focus" {
    var entry_ids: EntryIdAllocator = .{};
    const a_entries = [_]PersistedEntry{.{ .path = "/tmp/a.md", .kind = .markdown, .active = true }};
    const b_entries = [_]PersistedEntry{.{ .path = "/tmp/b.md", .kind = .markdown, .active = true }};
    const groups = [_]PersistedGroup{
        .{ .entries = &a_entries },
        .{ .entries = &.{} },
        .{ .entries = &b_entries },
    };
    const tree = [_]PersistedTreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .leaf = 0 },
        .{ .split = .{ .direction = .vertical, .ratio_milli = 500 } },
        .{ .leaf = 1 },
        .{ .leaf = 2 },
    };

    var restored = try DockPanel.restore(std.testing.allocator, &entry_ids, .{
        .groups = &groups,
        .tree = &tree,
        .focused_group = 1,
    });
    defer restored.deinit();

    try std.testing.expectEqual(@as(usize, 2), restored.groupCount());
    try std.testing.expectEqualStrings("/tmp/a.md", restored.groupAt(0).?.entries.items[0].path);
    try std.testing.expectEqualStrings("/tmp/b.md", restored.groupAt(1).?.entries.items[0].path);
    try std.testing.expectEqual(restored.groupAt(1).?, restored.focusedGroup());
}

test "dock panel: all-empty legacy restore keeps only the focused model root" {
    var entry_ids: EntryIdAllocator = .{};
    const groups = [_]PersistedGroup{ .{ .entries = &.{} }, .{ .entries = &.{} }, .{ .entries = &.{} } };
    const tree = [_]PersistedTreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .leaf = 0 },
        .{ .split = .{ .direction = .vertical, .ratio_milli = 500 } },
        .{ .leaf = 1 },
        .{ .leaf = 2 },
    };

    var restored = try DockPanel.restore(std.testing.allocator, &entry_ids, .{
        .groups = &groups,
        .tree = &tree,
        .focused_group = 1,
    });
    defer restored.deinit();

    try std.testing.expectEqual(@as(usize, 1), restored.groupCount());
    try std.testing.expectEqual(@as(usize, 0), restored.focusedGroup().entries.items.len);
}

test "dock panel: multi-group restore rejects duplicate path and duplicate leaf" {
    var entry_ids: EntryIdAllocator = .{};
    const a_entries = [_]PersistedEntry{.{ .path = "/tmp/a.md", .kind = .markdown, .active = true }};
    const b_entries = [_]PersistedEntry{.{ .path = "/tmp/a.md", .kind = .markdown, .active = true }};
    const groups = [_]PersistedGroup{ .{ .entries = &a_entries }, .{ .entries = &b_entries } };
    const tree = [_]PersistedTreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .leaf = 0 },
        .{ .leaf = 1 },
    };
    try std.testing.expectError(error.InvalidPersistedState, DockPanel.restore(std.testing.allocator, &entry_ids, .{ .groups = &groups, .tree = &tree }));

    const distinct_b = [_]PersistedEntry{.{ .path = "/tmp/b.md", .kind = .markdown, .active = true }};
    const distinct_groups = [_]PersistedGroup{ .{ .entries = &a_entries }, .{ .entries = &distinct_b } };
    const duplicate_leaf = [_]PersistedTreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .leaf = 0 },
        .{ .leaf = 0 },
    };
    try std.testing.expectError(error.InvalidPersistedState, DockPanel.restore(std.testing.allocator, &entry_ids, .{ .groups = &distinct_groups, .tree = &duplicate_leaf }));
}

test "dock panel: reopening a path in another group activates the original entry without duplicating it" {
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
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
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
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

test "dock group: removing active prefers right then left and keeps an empty group" {
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
    defer panel.deinit();
    const group = panel.singleGroup().?;
    _ = try panel.open(group, "/tmp/a.md", .markdown);
    _ = try panel.open(group, "/tmp/b.md", .markdown);
    _ = try panel.open(group, "/tmp/c.md", .markdown);

    group.active = 1;
    var removed = group.remove(1).?;
    try std.testing.expectEqualStrings("/tmp/b.md", removed.path);
    std.testing.allocator.free(removed.path);
    try std.testing.expectEqual(@as(?usize, 1), group.active);
    try std.testing.expectEqualStrings("/tmp/c.md", group.entries.items[1].path);

    removed = group.remove(1).?;
    std.testing.allocator.free(removed.path);
    try std.testing.expectEqual(@as(?usize, 0), group.active);
    removed = group.remove(0).?;
    std.testing.allocator.free(removed.path);
    try std.testing.expectEqual(@as(?usize, null), group.active);
    try std.testing.expectEqual(@as(usize, 0), group.entries.items.len);
}

test "dock group: removing background entry preserves active identity" {
    var entry_ids: EntryIdAllocator = .{};
    var panel = try DockPanel.init(std.testing.allocator, &entry_ids);
    defer panel.deinit();
    const group = panel.singleGroup().?;
    _ = try panel.open(group, "/tmp/a.md", .markdown);
    _ = try panel.open(group, "/tmp/b.md", .markdown);
    _ = try panel.open(group, "/tmp/c.md", .markdown);
    group.active = 2;
    group.entries.items[2].surface_id = 77;
    const removed = group.remove(0).?;
    defer std.testing.allocator.free(removed.path);
    try std.testing.expectEqual(@as(?usize, 1), group.active);
    try std.testing.expectEqual(@as(u64, 77), group.entries.items[group.active.?].surface_id);
}

test "dock mode policy keeps HTML read-only and both Markdown editors dirty-capable" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(Mode.read));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(Mode.source_edit));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(Mode.live_preview));
    try std.testing.expect(Mode.read.allowedFor(.markdown));
    try std.testing.expect(!Mode.live_preview.allowedFor(.markdown)); // 라이브 백로그
    try std.testing.expect(Mode.source_edit.allowedFor(.markdown));
    try std.testing.expect(Mode.read.allowedFor(.html));
    try std.testing.expect(!Mode.live_preview.allowedFor(.html));
    try std.testing.expect(!Mode.source_edit.allowedFor(.html));
    try std.testing.expect(!Mode.read.isEditable());
    try std.testing.expect(Mode.live_preview.isEditable());
    try std.testing.expect(Mode.source_edit.isEditable());
    inline for (std.enums.values(Mode)) |mode| {
        try std.testing.expectEqual(mode, Mode.parseWorkspaceName(mode.workspaceName()).?);
    }
    try std.testing.expect(Mode.parseWorkspaceName("future") == null);
}

test "dock panel: restore rejects a persisted HTML editor mode" {
    var entry_ids: EntryIdAllocator = .{};
    const entries = [_]PersistedEntry{.{ .path = "/tmp/a.html", .kind = .html, .mode = .live_preview, .active = true }};
    try std.testing.expectError(error.InvalidPersistedState, DockPanel.restore(std.testing.allocator, &entry_ids, .{ .entries = &entries }));
}
