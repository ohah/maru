//! Session Dock의 platform-neutral input DTO다.
//!
//! 이 파일은 archive scanner의 record나 AppSession을 보관하지 않는다. platform은 이미 redaction과
//! scope/filter를 끝낸 화면용 문자열만 이 구조로 투영하고, component는 그 immutable snapshot만 읽는다.

const std = @import("std");
const layout = @import("../../ui/layout.zig");
const spacing = @import("../../ui/spacing.zig");

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

/// Detail data is already redacted by the host worker.  The dock compares neither its text nor
/// its provider identity; it only projects the immutable value for one selected card.
pub const DetailState = enum { loading, ready, stale, unavailable };
pub const TurnRole = enum { user, assistant };

pub const Turn = struct {
    role: TurnRole,
    text: []const u8,
};

/// Only the card whose stable archive identity equals `Props.expanded_identity` may carry this
/// value.  `Card.selected` remains keyboard/hover selection, not a proxy for expansion.
pub const Expanded = struct {
    state: DetailState,
    turns: []const Turn = &.{},
    action_record_count: u32 = 0,
    resume_enabled: bool = false,
    reveal_enabled: bool = false,
    focus_live_enabled: bool = false,
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
    expanded: ?Expanded = null,
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
    /// Backing pixels per logical point. Semantic components use this only to reserve role
    /// line boxes; platform adapters still own actual glyph ink/baseline measurement.
    scale_milli: u32 = 1000,
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
    /// The host owns this stable identity and clears it atomically with detail/action capture
    /// when a snapshot replacement changes `(provider, session_id, device, inode)`.
    expanded_identity: ?u64 = null,
    /// The first virtualized item origin relative to the content clip. It is normally zero or
    /// negative, but can be positive when an offset lands in an inter-item gap.
    content_first_item_origin_y_px: i32 = 0,
    items: []const Item = &.{},
};

pub const Metrics = struct {
    header_h: u32,
    scope_h: u32,
    search_h: u32,
    group_h: u32,
    card_h: u32,
    expanded_detail_h: u32,
    expanded_actions_h: u32,
    /// Header/scope/search 사이의 세로 gap. 이 값은 cell-aligned control text의 clip 안전성과
    /// reference-like fixed-chrome breathing room을 함께 보장한다.
    control_gap: u32,
    /// Group/card 사이의 목록 gap. 목록은 row bottom divider로 구분하므로 기본값은 0이다.
    item_gap: u32,
    /// Expanded action siblings 사이의 가로 gap. 기본 목록 divider와 달리 버튼은 서로 독립된 target으로
    /// 보여야 하므로, shared row 안에서도 경계를 맞닿게 두지 않는다.
    action_gap: u32,
    pad: u32,

    /// Cell metric에서만 파생해 fixed/response layout 모두 같은 density를 갖게 한다. 기본 목록은 세 줄
    /// (title·summary·metadata)을 6행 row 안에 둔다. title/summary/metadata 사이에 cell 하나씩을
    /// 남겨 작은 terminal 행처럼 붙어 보이지 않게 하되, row 사이의 별도 외곽 card gap은 만들지 않는다.
    /// Header/scope/search의 1/2행 control gap은 목록과 분리한다. 그것을 줄이면 cell-based text lowering이
    /// control glyph를 앞 cell로 내리고 own clip에 의해 사라지게 할 수 있다.
    /// 바깥 padding은 cell 한 행으로 유지해, content의 첫 group/카드 text가 CoreText cell lowering 뒤 clip
    /// 밖으로 이동하지 않고 exact vertical centring을 계속 지킨다.
    /// viewport가 작아도 build 단계가 empty rect로 fail-close하므로 component가 별도 pixel magic number를
    /// 들고 있지 않다.
    pub fn fromCellHeight(cell_height_px: u32, scale_milli: u32) Metrics {
        const ch = @max(cell_height_px, 1);
        const button = ButtonMetrics.resolve(scale_milli);
        return .{
            // Title/count stack과 trailing utility cluster가 같은 header 안에서 숨 막히지 않도록 4행.
            .header_h = ch * 4,
            .scope_h = ch * 3,
            .search_h = ch * 3,
            .group_h = ch * 3,
            .card_h = ch * 6,
            // Reserve the same bounded space for loading/ready/stale/unavailable so the action
            // row never jumps while a background detail result arrives.  The text view may use
            // at most three two-line turns inside this rect.
            .expanded_detail_h = ch * 10,
            // The action target is native Chrome geometry. The surrounding archive list remains
            // cell-derived until AS4-f moves all DockMetrics, but terminal font size cannot
            // shrink this explicit command below the 48pt target.
            .expanded_actions_h = button.minimum_height_px,
            .control_gap = ch,
            .item_gap = 0,
            .action_gap = @max(ch / 2, 4),
            .pad = @max(ch + ch / 2, 12),
        };
    }
};

/// Metrics of one measured action-content group. These values use Chrome logical points and the
/// backing scale only; terminal cell width and SVG viewBox whitespace are not padding inputs.
pub const ButtonMetrics = struct {
    content_inset_x_px: u32,
    content_inset_y_px: u32,
    leading_icon_extent_px: u32,
    leading_icon_gap_px: u32,
    minimum_height_px: u32,

    pub fn resolve(scale_milli: u32) ButtonMetrics {
        // Props default to 1000, but malformed/pre-render snapshots may still carry zero.
        // `view.effectiveScale` uses the same fallback; matching it here keeps the published
        // action rect large enough for the content artifact rather than producing a blank button.
        const scale = if (scale_milli == 0) 1000 else scale_milli;
        return .{
            .content_inset_x_px = geometryPx(spacing.px(.md, scale)),
            .content_inset_y_px = geometryPx(spacing.px(.sm, scale)),
            .leading_icon_extent_px = geometryPx(spacing.pointsPx(18, scale)),
            .leading_icon_gap_px = geometryPx(spacing.px(.xs, scale)),
            .minimum_height_px = geometryPx(spacing.pointsPx(48, scale)),
        };
    }

    fn geometryPx(value: u32) u32 {
        return @min(value, @as(u32, std.math.maxInt(i32)));
    }
};

test "Metrics keeps the three-line session list readable without inter-row whitespace" {
    const m = Metrics.fromCellHeight(32, 1000);
    try std.testing.expectEqual(@as(u32, 192), m.card_h);
    try std.testing.expectEqual(@as(u32, 96), m.scope_h);
    try std.testing.expectEqual(@as(u32, 32), m.control_gap);
    try std.testing.expectEqual(@as(u32, 0), m.item_gap);
    try std.testing.expectEqual(@as(u32, 16), m.action_gap);
    try std.testing.expectEqual(@as(u32, 48), m.pad);
    // view.zig places base rows at 1/3/5 cell heights. Their cells fit before the divider while
    // every information line keeps one full cell of separation.
    try std.testing.expect(m.card_h >= 6 * 32);
}

test "ButtonMetrics is independent of terminal cell height and scales in backing pixels" {
    const one_x = ButtonMetrics.resolve(1000);
    const two_x = ButtonMetrics.resolve(2000);
    try std.testing.expectEqual(@as(u32, 16), one_x.content_inset_x_px);
    try std.testing.expectEqual(@as(u32, 12), one_x.content_inset_y_px);
    try std.testing.expectEqual(@as(u32, 18), one_x.leading_icon_extent_px);
    try std.testing.expectEqual(@as(u32, 8), one_x.leading_icon_gap_px);
    try std.testing.expectEqual(@as(u32, 48), one_x.minimum_height_px);
    try std.testing.expectEqual(one_x.minimum_height_px * 2, two_x.minimum_height_px);
    try std.testing.expectEqual(one_x.minimum_height_px, ButtonMetrics.resolve(0).minimum_height_px);
    const extreme = ButtonMetrics.resolve(std.math.maxInt(u32)).minimum_height_px;
    try std.testing.expect(extreme > 0);
    try std.testing.expect(extreme <= @as(u32, std.math.maxInt(i32)));
}
