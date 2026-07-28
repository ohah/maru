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
    /// scope close(`.pane`/`.tab`)가 파괴 전 dirty 스냅샷을 **이미 한 번 요청했나**. 브릿지가 영영 답하지
    /// 않아도 두 번째 시도는 그냥 진행하게 하는 once-only 래치다 — 없으면 편집 가능 파일이 든 pane이
    /// 영원히 안 닫힌다(docs/file-panel.md §3.2).
    close_snapshot_requested: bool = false,
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
    collapsed: bool = false,
    /// Explorer launcher로 한 번 열린 도크인지. content와 분리해 explicit-empty 도크도 재시작 뒤 유지한다.
    presented: bool = false,
    entries: []const PersistedEntry = &.{},
    groups: []const PersistedGroup = &.{},
    tree: []const PersistedTreeNode = &.{},
    focused_group: usize = 0,
};

/// FP16: 도크는 **탐색기 전용**이라 그룹 트리도 파일 소유도 없다. 남은 것은 도크 자신의 배치 상태와,
/// 워크스페이스 파일을 읽어 들일 때 잠깐 드는 **평탄한 복원 목록**뿐이다. 파일 entry의 런타임 소유는
/// `session_model.Term.file_entry`이고(§1), 이 구조체는 그 entry를 만들어 넘겨 주기만 한다.
///
/// 옛 `DockGroup`/`DockTree`/drop 기계(`commitEntryDrop`·`removeGroup`·`pruneEmptyGroups`)는 "도크 안에서
/// 여러 파일을 동시에 보여 준다"는 기능이 워크스페이스 pane split으로 흡수되면서 통째로 사라졌다.
pub const DockPanel = struct {
    allocator: std.mem.Allocator,
    entry_ids: *EntryIdAllocator,
    side: Side = .right,
    size: u32 = 0,
    collapsed: bool = false,
    presented: bool = false,
    /// `restore`가 채우는 복원 목록. 호출자가 Term으로 **이관하면 비운다**(path 소유도 함께 넘어간다).
    restored: std.ArrayList(Entry) = .empty,
    /// 복원 당시 활성이던 entry의 index(없으면 null).
    restored_active: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, entry_ids: *EntryIdAllocator) !DockPanel {
        return .{ .allocator = allocator, .entry_ids = entry_ids };
    }

    pub fn deinit(self: *DockPanel) void {
        for (self.restored.items) |entry| self.allocator.free(entry.path);
        self.restored.deinit(self.allocator);
        self.* = undefined;
    }

    /// 아직 Term으로 이관되지 않은 복원 entry 수.
    pub fn restoredCount(self: *const DockPanel) usize {
        return self.restored.items.len;
    }

    /// 와이어 상태에서 도크 배치와 **평탄한 복원 목록**을 만든다. 옛 다중 group 배치(`groups`/`tree`)도
    /// 계속 읽되 preorder로 평탄화한다 — FP16에는 그 배치를 담을 그릇이 없고, 파일은 활성 워크스페이스의
    /// 활성 pane에 이어 붙는다(docs/file-panel.md §5.0 마이그레이션 규칙).
    pub fn restore(allocator: std.mem.Allocator, entry_ids: *EntryIdAllocator, state: PersistedState) !DockPanel {
        if (state.entries.len > max_entries or state.groups.len > max_groups) return error.InvalidPersistedState;
        if (state.groups.len != 0 and state.entries.len != 0) return error.InvalidPersistedState;
        var panel = try DockPanel.init(allocator, entry_ids);
        errdefer panel.deinit();
        panel.side = state.side;
        panel.size = state.size;
        panel.collapsed = state.collapsed;
        panel.presented = state.presented;

        if (state.groups.len != 0) {
            if (state.tree.len != state.groups.len * 2 - 1 or state.focused_group >= state.groups.len)
                return error.InvalidPersistedState;
            // tree는 배치 정보라 FP16에서 쓸 데가 없지만, 손상된 파일을 조용히 받아들이지 않도록 형태는 검증한다.
            var node_index: usize = 0;
            const seen = try allocator.alloc(bool, state.groups.len);
            defer allocator.free(seen);
            @memset(seen, false);
            try validateRestoredTree(state.tree, &node_index, seen);
            if (node_index != state.tree.len) return error.InvalidPersistedState;
            for (seen) |value| if (!value) return error.InvalidPersistedState;

            for (state.groups, 0..) |persisted_group, group_index| {
                const group_is_focused = group_index == state.focused_group;
                try panel.appendRestored(persisted_group.entries, group_is_focused);
            }
            return panel;
        }

        if (state.tree.len != 0) return error.InvalidPersistedState;
        try panel.appendRestored(state.entries, true);
        return panel;
    }

    /// 한 group(또는 단일 목록)의 entry를 복원 목록 끝에 잇는다. 경로 중복·허용되지 않는 mode·빈 경로는
    /// 와이어 오류다. `active_owner`는 이 묶음의 active가 **창 전체 활성**을 뜻하는지다(옛 focused group).
    fn appendRestored(self: *DockPanel, entries: []const PersistedEntry, active_owner: bool) !void {
        for (entries) |entry| {
            if (entry.path.len == 0 or !entry.mode.allowedFor(entry.kind)) return error.InvalidPersistedState;
            for (self.restored.items) |existing| {
                if (std.mem.eql(u8, existing.path, entry.path)) return error.InvalidPersistedState;
            }
            if (self.restored.items.len >= max_entries) return error.InvalidPersistedState;
            const owned = try self.allocator.dupe(u8, entry.path);
            errdefer self.allocator.free(owned);
            try self.restored.append(self.allocator, .{
                .id = try self.entry_ids.next(),
                .path = owned,
                .kind = entry.kind,
                .mode = entry.mode,
            });
            if (entry.active and active_owner) self.restored_active = self.restored.items.len - 1;
        }
    }

    fn validateRestoredTree(nodes: []const PersistedTreeNode, index: *usize, seen: []bool) !void {
        if (index.* >= nodes.len) return error.InvalidPersistedState;
        const node = nodes[index.*];
        index.* += 1;
        switch (node) {
            .leaf => |group_index| {
                if (group_index >= seen.len or seen[group_index]) return error.InvalidPersistedState;
                seen[group_index] = true;
            },
            .split => |persisted_split| {
                if (persisted_split.ratio_milli < 50 or persisted_split.ratio_milli > 950)
                    return error.InvalidPersistedState;
                try validateRestoredTree(nodes, index, seen);
                try validateRestoredTree(nodes, index, seen);
            },
        }
    }
};

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
