//! Session Dock의 platform-neutral input DTO다.
//!
//! 이 파일은 archive scanner의 record나 AppSession을 보관하지 않는다. platform은 이미 redaction과
//! scope/filter를 끝낸 화면용 문자열만 이 구조로 투영하고, component는 그 immutable snapshot만 읽는다.

const layout = @import("../../ui/layout.zig");

pub const Scope = enum { workspace, project, all };

pub const Provider = enum {
    codex,
    claude,

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .codex => "Codex",
            .claude => "Claude",
        };
    }
};

/// `identity`는 platform이 snapshot generation과 함께 검증하는 opaque 값이다. component는 이 값을
/// 비교/표시/명령 인자로 해석하지 않고 action table에 그대로 되돌린다.
pub const Card = struct {
    identity: u64,
    provider: Provider,
    title: []const u8,
    summary: []const u8,
    metadata: []const u8,
    selected: bool = false,
};

pub const Group = struct {
    identity: u64,
    label: []const u8,
    count: u16,
    collapsed: bool = false,
};

/// Projection은 group/card 순서를 이미 정했으며, component는 filesystem/JSONL을 읽어 재정렬하지 않는다.
pub const Item = union(enum) {
    group: Group,
    card: Card,
};

pub const Props = struct {
    viewport_px: layout.UiSize,
    cell_width_px: u32,
    cell_height_px: u32,
    snapshot_generation: u64,
    displayed_count: u16,
    recent_limit: u16 = 500,
    scope: Scope = .all,
    workspace_scope_enabled: bool = true,
    project_scope_enabled: bool = true,
    search: []const u8 = "",
    search_focused: bool = false,
    loading: bool = false,
    refreshing: bool = false,
    spinner_phase: u3 = 0,
    items: []const Item = &.{},
};

pub const Metrics = struct {
    header_h: u32,
    scope_h: u32,
    search_h: u32,
    group_h: u32,
    card_h: u32,
    gap: u32,
    pad: u32,

    /// Cell metric에서만 파생해 fixed/response layout 모두 같은 density를 갖게 한다. viewport가 작아도
    /// build 단계가 empty rect로 fail-close하므로 component가 별도 pixel magic number를 들고 있지 않다.
    pub fn fromCellHeight(cell_height_px: u32) Metrics {
        const ch = @max(cell_height_px, 1);
        return .{
            .header_h = ch * 3,
            .scope_h = ch * 2,
            .search_h = ch * 2,
            .group_h = ch * 2,
            .card_h = ch * 5,
            .gap = @max(ch / 2, 4),
            .pad = @max(ch, 8),
        };
    }
};
