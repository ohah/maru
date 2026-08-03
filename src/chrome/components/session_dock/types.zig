//! Session Dock의 platform-neutral input DTO다.
//!
//! 이 파일은 archive scanner의 record나 AppSession을 보관하지 않는다. platform은 이미 redaction과
//! scope/filter를 끝낸 화면용 문자열만 이 구조로 투영하고, component는 그 immutable snapshot만 읽는다.

const std = @import("std");
const layout = @import("../../ui/layout.zig");
const spacing = @import("../../ui/spacing.zig");
const typography = @import("../../ui/typography.zig");

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

/// One immutable geometry snapshot for all Session Dock consumers. The host gets this same
/// value for virtualization and wheel motion; build gets it for the published UiRectTree; view
/// gets it for component-owned text offsets. Keeping terminal-cell metrics out of this type
/// prevents a terminal-font preference from moving a visible Chrome hit target.
pub const DockMetrics = struct {
    /// Session Dock을 고르는 상단 view switcher의 고정 높이. 이 값은 terminal tab bar와
    /// 공유하지 않는다. terminal zoom이 Session Dock의 content origin을 움직이면 component가
    /// 고정하던 card/action rect 계약도 함께 깨지기 때문이다.
    view_switcher_h: u32,
    header_h: u32,
    scope_h: u32,
    search_h: u32,
    group_h: u32,
    card_h: u32,
    expanded_detail_h: u32,
    expanded_actions_h: u32,
    /// Header/scope/search 사이의 fixed Chrome gap.
    control_gap: u32,
    /// Group/card 사이의 목록 gap. 목록은 row bottom divider로 구분하므로 기본값은 0이다.
    item_gap: u32,
    /// Expanded action siblings 사이의 가로 gap. 기본 목록 divider와 달리 버튼은 서로 독립된 target으로
    /// 보여야 하므로, shared row 안에서도 경계를 맞닿게 두지 않는다.
    action_gap: u32,
    root_inset: u32,
    header_content_inset_x: u32,
    header_host_label_w: u32,
    header_host_icon_extent: u32,
    header_host_icon_gap: u32,
    header_utility_gap: u32,
    header_refresh_extent: u32,
    header_trailing_inset: u32,
    group_disclosure_inset_x: u32,
    group_disclosure_extent: u32,
    group_disclosure_label_gap: u32,
    card_inset_x: u32,
    card_title_y: u32,
    card_summary_y: u32,
    card_metadata_y: u32,
    detail_inset_x: u32,
    detail_heading_y: u32,
    detail_record_y: u32,
    detail_turn_y: u32,
    detail_turn_step: u32,

    pub fn resolve(scale_milli: u32) DockMetrics {
        const scale = effectiveScale(scale_milli);
        const button = ButtonMetrics.resolve(scale_milli);
        const card_inset = spacing.px(.md, scale);
        const card_title_y = card_inset;
        const card_summary_y = saturatedAdd(saturatedAdd(card_title_y, typography.lineHeightPx(.card_heading, scale)), spacing.px(.xs, scale));
        const card_metadata_y = saturatedAdd(saturatedAdd(card_summary_y, typography.lineHeightPx(.body, scale)), spacing.px(.xs, scale));
        const detail_inset = spacing.px(.md, scale);
        const detail_heading_y = detail_inset;
        const detail_record_y = saturatedAdd(saturatedAdd(detail_heading_y, typography.lineHeightPx(.body, scale)), spacing.px(.xxs, scale));
        const detail_turn_y = @max(saturatedAdd(saturatedAdd(detail_record_y, typography.lineHeightPx(.metadata, scale)), spacing.px(.sm, scale)), spacing.pointsPx(64, scale));
        const detail_turn_step = saturatedAdd(saturatedAdd(saturatedAdd(typography.lineHeightPx(.overline, scale), spacing.px(.xxs, scale)), typography.lineHeightPx(.body, scale)), spacing.px(.sm, scale));
        return .{
            .view_switcher_h = geometryPx(spacing.pointsPx(40, scale)),
            // Heading + supporting + 4pt stack gap + 12pt vertical inset on each side.
            .header_h = geometryPx(@max(spacing.pointsPx(76, scale), saturatedAdd(saturatedAdd(saturatedAdd(typography.lineHeightPx(.dock_heading, scale), typography.lineHeightPx(.supporting, scale)), spacing.px(.xxs, scale)), saturatedMul(spacing.px(.sm, scale), 2)))),
            .scope_h = geometryPx(@max(button.minimum_height_px, saturatedAdd(typography.lineHeightPx(.control, scale), saturatedMul(spacing.px(.sm, scale), 2)))),
            .search_h = geometryPx(@max(button.minimum_height_px, saturatedAdd(typography.lineHeightPx(.control, scale), saturatedMul(spacing.px(.sm, scale), 2)))),
            .group_h = geometryPx(@max(spacing.pointsPx(48, scale), saturatedAdd(typography.lineHeightPx(.group_heading, scale), saturatedMul(spacing.px(.sm, scale), 2)))),
            .card_h = geometryPx(@max(spacing.pointsPx(112, scale), saturatedAdd(saturatedAdd(card_metadata_y, typography.lineHeightPx(.metadata, scale)), spacing.px(.sm, scale)))),
            .expanded_detail_h = geometryPx(@max(spacing.pointsPx(256, scale), saturatedAdd(saturatedSub(saturatedAdd(detail_turn_y, saturatedMul(detail_turn_step, 3)), spacing.px(.sm, scale)), detail_inset))),
            .expanded_actions_h = button.minimum_height_px,
            .control_gap = geometryPx(spacing.px(.sm, scale)),
            .item_gap = 0,
            .action_gap = geometryPx(spacing.px(.xs, scale)),
            .root_inset = geometryPx(spacing.px(.lg, scale)),
            .header_content_inset_x = geometryPx(spacing.px(.xs, scale)),
            // The provenance pair has enough room for its 18pt SVG, 8pt gap, and Korean label
            // without asking terminal-cell metrics where a Chrome header control should begin.
            .header_host_label_w = geometryPx(spacing.pointsPx(72, scale)),
            .header_host_icon_extent = geometryPx(spacing.pointsPx(18, scale)),
            .header_host_icon_gap = geometryPx(spacing.px(.xs, scale)),
            .header_utility_gap = geometryPx(spacing.px(.sm, scale)),
            // A 24pt target gives the 18pt registered refresh glyph three logical points of
            // optical breathing room on every side.  The 20pt trailing inset matches the
            // shared dock content edge, so neither the SVG nor the spinner reads as clipped.
            .header_refresh_extent = geometryPx(spacing.pointsPx(24, scale)),
            .header_trailing_inset = geometryPx(spacing.px(.lg, scale)),
            // The root already contributes the dock's 20pt content inset. The disclosure gets
            // only its local 8pt slot, preventing the chevron from inheriting a second 20pt.
            .group_disclosure_inset_x = geometryPx(spacing.px(.xs, scale)),
            .group_disclosure_extent = geometryPx(spacing.pointsPx(20, scale)),
            .group_disclosure_label_gap = geometryPx(spacing.px(.xs, scale)),
            .card_inset_x = geometryPx(card_inset),
            .card_title_y = geometryPx(card_title_y),
            .card_summary_y = geometryPx(card_summary_y),
            .card_metadata_y = geometryPx(card_metadata_y),
            .detail_inset_x = geometryPx(detail_inset),
            .detail_heading_y = geometryPx(detail_heading_y),
            .detail_record_y = geometryPx(detail_record_y),
            .detail_turn_y = geometryPx(detail_turn_y),
            .detail_turn_step = geometryPx(detail_turn_step),
        };
    }

    /// The host uses exactly this sum before projecting the virtualized content viewport.  It
    /// intentionally lives beside the rect values so adding a fixed control cannot make build
    /// and wheel/scroll disagree about where the first item starts.
    pub fn fixedChromeHeight(self: DockMetrics) u32 {
        return geometryPx(saturatedAdd(saturatedAdd(saturatedAdd(saturatedAdd(saturatedMul(self.root_inset, 2), self.header_h), self.scope_h), self.search_h), saturatedMul(self.control_gap, 3)));
    }

    pub fn headerUtilityWidth(self: DockMetrics) u32 {
        return geometryPx(saturatedAdd(saturatedAdd(saturatedAdd(self.header_host_label_w, self.header_utility_gap), self.header_refresh_extent), self.header_trailing_inset));
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
        const scale = effectiveScale(scale_milli);
        return .{
            .content_inset_x_px = geometryPx(spacing.px(.md, scale)),
            .content_inset_y_px = geometryPx(spacing.px(.sm, scale)),
            .leading_icon_extent_px = geometryPx(spacing.pointsPx(18, scale)),
            .leading_icon_gap_px = geometryPx(spacing.px(.xs, scale)),
            .minimum_height_px = geometryPx(spacing.pointsPx(48, scale)),
        };
    }
};

fn effectiveScale(scale_milli: u32) u32 {
    return if (scale_milli == 0) 1000 else scale_milli;
}

fn geometryPx(value: u32) u32 {
    return @min(value, @as(u32, std.math.maxInt(i32)));
}

fn saturatedAdd(a: u32, b: u32) u32 {
    return a +| b;
}

fn saturatedSub(a: u32, b: u32) u32 {
    return a -| b;
}

fn saturatedMul(a: u32, b: u32) u32 {
    return a *| b;
}

test "DockMetrics fixes all Session Dock geometry independently of terminal cells" {
    const m = DockMetrics.resolve(1000);
    try std.testing.expectEqual(@as(u32, 40), m.view_switcher_h);
    try std.testing.expectEqual(@as(u32, 76), m.header_h);
    try std.testing.expectEqual(@as(u32, 48), m.scope_h);
    try std.testing.expectEqual(@as(u32, 48), m.search_h);
    try std.testing.expectEqual(@as(u32, 48), m.group_h);
    try std.testing.expectEqual(@as(u32, 112), m.card_h);
    try std.testing.expectEqual(@as(u32, 256), m.expanded_detail_h);
    try std.testing.expectEqual(@as(u32, 48), m.expanded_actions_h);
    try std.testing.expectEqual(@as(u32, 12), m.control_gap);
    try std.testing.expectEqual(@as(u32, 0), m.item_gap);
    try std.testing.expectEqual(@as(u32, 8), m.action_gap);
    try std.testing.expectEqual(@as(u32, 20), m.root_inset);
    try std.testing.expectEqual(@as(u32, 8), m.header_content_inset_x);
    try std.testing.expectEqual(@as(u32, 72), m.header_host_label_w);
    try std.testing.expectEqual(@as(u32, 18), m.header_host_icon_extent);
    try std.testing.expectEqual(@as(u32, 8), m.header_host_icon_gap);
    try std.testing.expectEqual(@as(u32, 12), m.header_utility_gap);
    try std.testing.expectEqual(@as(u32, 24), m.header_refresh_extent);
    try std.testing.expectEqual(@as(u32, 20), m.header_trailing_inset);
    try std.testing.expectEqual(@as(u32, 8), m.group_disclosure_inset_x);
    try std.testing.expectEqual(@as(u32, 20), m.group_disclosure_extent);
    try std.testing.expectEqual(@as(u32, 8), m.group_disclosure_label_gap);
    try std.testing.expectEqual(@as(u32, 128), m.headerUtilityWidth());
    try std.testing.expectEqual(@as(u32, 248), m.fixedChromeHeight());
    try std.testing.expect(m.card_metadata_y < m.card_h);
    try std.testing.expect(m.detail_turn_y + m.detail_turn_step * 3 <= m.expanded_detail_h);
}

test "DockMetrics scales only with backing scale" {
    const one_x = DockMetrics.resolve(1000);
    const two_x = DockMetrics.resolve(2000);
    inline for (std.meta.fields(DockMetrics)) |field| {
        try std.testing.expectEqual(@field(one_x, field.name) * 2, @field(two_x, field.name));
    }
    try std.testing.expectEqual(one_x.header_h, DockMetrics.resolve(0).header_h);
}

test "DockMetrics fails closed at extreme backing scale without overflow" {
    const m = DockMetrics.resolve(std.math.maxInt(u32));
    inline for (std.meta.fields(DockMetrics)) |field| {
        try std.testing.expect(@field(m, field.name) <= @as(u32, std.math.maxInt(i32)));
    }
    try std.testing.expect(m.fixedChromeHeight() <= @as(u32, std.math.maxInt(i32)));
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
