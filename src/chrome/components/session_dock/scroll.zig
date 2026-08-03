//! Integer backing-pixel scroll projection for the Session Dock.
//!
//! The dock deliberately keeps this arithmetic separate from its platform host: paint, pointer
//! hit-testing, and future scrollbar code must all receive the same clipped item window.

const std = @import("std");

pub const Kind = enum { group, card };

pub const Metrics = struct {
    group_h_px: u32,
    card_h_px: u32,
    gap_px: u32,
    /// At most one disclosure is open.  Keeping its entry index and fully reserved height in
    /// the projection metrics means virtualization, clipping and hit-testing all agree on the
    /// same content-space geometry; the host never applies a second detail-only y offset.
    expanded_card_index: ?usize = null,
    expanded_card_h_px: u32 = 0,

    pub fn itemHeight(self: Metrics, kind: Kind, index: usize) u32 {
        if (kind == .card and self.expanded_card_index != null and self.expanded_card_index.? == index)
            return self.expanded_card_h_px;
        return switch (kind) {
            .group => self.group_h_px,
            .card => self.card_h_px,
        };
    }
};

/// The host owns this tiny state, but only this module decides its legal range.  Fractional wheel
/// input is intentionally kept outside `offset_y_px`: tree rects and GPU draw rects stay integral.
pub const SessionDockScrollState = struct {
    offset_y_px: u32 = 0,

    pub fn scrollByPx(self: *SessionDockScrollState, delta_px: i64, max_offset_px: u32) bool {
        const current: u64 = self.offset_y_px;
        const maximum: u64 = max_offset_px;
        const next: u64 = if (delta_px >= 0)
            @min(maximum, current +| @as(u64, @intCast(delta_px)))
        else
            current -| (@as(u64, @intCast(-(delta_px + 1))) + 1);
        const clamped: u32 = @intCast(next);
        if (clamped == self.offset_y_px) return false;
        self.offset_y_px = clamped;
        return true;
    }

    pub fn clamp(self: *SessionDockScrollState, max_offset_px: u32) void {
        self.offset_y_px = @min(self.offset_y_px, max_offset_px);
    }

    /// Replaces the retained offset only through the same bounded coordinate system used by
    /// wheel input.  A refresh/resize anchor may be negative before clamping when a card moved
    /// below a newly inserted group header, so the public input is signed.
    pub fn setOffsetPx(self: *SessionDockScrollState, requested_offset_px: i64, max_offset_px: u32) bool {
        const clamped: u32 = @intCast(std.math.clamp(requested_offset_px, @as(i64, 0), @as(i64, max_offset_px)));
        if (clamped == self.offset_y_px) return false;
        self.offset_y_px = clamped;
        return true;
    }

    pub fn reset(self: *SessionDockScrollState) void {
        self.offset_y_px = 0;
    }
};

pub const Projection = struct {
    content_height_px: u32,
    max_offset_px: u32,
    offset_y_px: u32,
    first_index: usize,
    /// The first returned item starts at this local y. It is zero or negative, never fractional.
    first_origin_y_px: i32,
    end_exclusive: usize,
};

/// Page keys deliberately leave one full card in view.  A tiny/zero viewport has no meaningful
/// page step and must not manufacture motion from the fixed chrome metrics.
pub fn pageStepPx(viewport_h_px: u32, card_h_px: u32) u32 {
    return viewport_h_px -| card_h_px;
}

/// The host computes a card's content-space top and carries a non-negative intra-card displacement
/// across an immutable snapshot replacement.  Keeping the saturating/clamping arithmetic here
/// makes a reordered anchor unable to overflow the bounded scroll coordinate.
pub fn anchorOffsetPx(card_top_px: u32, intra_card_y_px: u32, max_offset_px: u32) u32 {
    const requested = @as(u64, card_top_px) + @as(u64, intra_card_y_px);
    return @intCast(@min(requested, @as(u64, max_offset_px)));
}

/// Projects a bounded item sequence without allocation. `itemAt` is comptime so the generic
/// algorithm remains independent from archive/provider record types.
pub fn project(
    items: anytype,
    comptime itemAt: fn (@TypeOf(items), usize) Kind,
    metrics: Metrics,
    viewport_h_px: u32,
    requested_offset_px: u32,
) Projection {
    const count = items.len;
    var content_height: u32 = 0;
    for (0..count) |index| {
        content_height +|= metrics.itemHeight(itemAt(items, index), index);
        if (index + 1 < count) content_height +|= metrics.gap_px;
    }
    const max_offset = content_height -| viewport_h_px;
    const offset = @min(requested_offset_px, max_offset);

    var cursor: u32 = 0;
    var first = count;
    for (0..count) |index| {
        const h = metrics.itemHeight(itemAt(items, index), index);
        const end = cursor +| h;
        if (end > offset) {
            first = index;
            break;
        }
        cursor = end +| if (index + 1 < count) metrics.gap_px else 0;
    }
    if (first == count) return .{
        .content_height_px = content_height,
        .max_offset_px = max_offset,
        .offset_y_px = offset,
        .first_index = count,
        .first_origin_y_px = 0,
        .end_exclusive = count,
    };

    var end = first;
    const first_origin: i64 = @as(i64, cursor) - @as(i64, offset);
    var y = first_origin;
    while (end < count and y < @as(i64, viewport_h_px)) : (end += 1) {
        y += @as(i64, metrics.itemHeight(itemAt(items, end), end));
        if (end + 1 < count) y += metrics.gap_px;
    }
    return .{
        .content_height_px = content_height,
        .max_offset_px = max_offset,
        .offset_y_px = offset,
        .first_index = first,
        .first_origin_y_px = @intCast(std.math.clamp(first_origin, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32)))),
        .end_exclusive = end,
    };
}

fn fixtureKind(items: []const Kind, index: usize) Kind {
    return items[index];
}

test "project clips partial first and last item without a trailing gap" {
    const items = [_]Kind{ .group, .card, .card };
    const slice: []const Kind = &items;
    const result = project(slice, fixtureKind, .{ .group_h_px = 20, .card_h_px = 50, .gap_px = 10 }, 60, 35);
    try std.testing.expectEqual(@as(u32, 140), result.content_height_px);
    try std.testing.expectEqual(@as(u32, 80), result.max_offset_px);
    try std.testing.expectEqual(@as(usize, 1), result.first_index);
    try std.testing.expectEqual(@as(i32, -5), result.first_origin_y_px);
    try std.testing.expectEqual(@as(usize, 3), result.end_exclusive);
}

test "project reserves one expanded card in the same scroll coordinate" {
    const items = [_]Kind{ .group, .card, .card };
    const slice: []const Kind = &items;
    const result = project(slice, fixtureKind, .{
        .group_h_px = 20,
        .card_h_px = 50,
        .gap_px = 0,
        .expanded_card_index = 1,
        .expanded_card_h_px = 170,
    }, 100, 60);
    // group 20 + expanded card 170 + ordinary card 50. The viewport starts inside the
    // disclosure itself, so its origin and the following card must use that one 170px rect.
    try std.testing.expectEqual(@as(u32, 240), result.content_height_px);
    try std.testing.expectEqual(@as(u32, 140), result.max_offset_px);
    try std.testing.expectEqual(@as(usize, 1), result.first_index);
    try std.testing.expectEqual(@as(i32, -40), result.first_origin_y_px);
    try std.testing.expectEqual(@as(usize, 2), result.end_exclusive);
}

test "scroll state clamps each backing pixel boundary" {
    var state = SessionDockScrollState{};
    try std.testing.expect(state.scrollByPx(1, 9));
    try std.testing.expectEqual(@as(u32, 1), state.offset_y_px);
    _ = state.scrollByPx(100, 9);
    try std.testing.expectEqual(@as(u32, 9), state.offset_y_px);
    _ = state.scrollByPx(-100, 9);
    try std.testing.expectEqual(@as(u32, 0), state.offset_y_px);
    _ = state.scrollByPx(std.math.maxInt(i64), 9);
    try std.testing.expectEqual(@as(u32, 9), state.offset_y_px);
    _ = state.scrollByPx(std.math.minInt(i64), 9);
    try std.testing.expectEqual(@as(u32, 0), state.offset_y_px);
    try std.testing.expect(state.setOffsetPx(7, 9));
    try std.testing.expectEqual(@as(u32, 7), state.offset_y_px);
    _ = state.setOffsetPx(-1, 9);
    try std.testing.expectEqual(@as(u32, 0), state.offset_y_px);
}

test "page and anchor helpers preserve bounded pixel semantics" {
    try std.testing.expectEqual(@as(u32, 0), pageStepPx(0, 72));
    try std.testing.expectEqual(@as(u32, 0), pageStepPx(72, 72));
    try std.testing.expectEqual(@as(u32, 128), pageStepPx(200, 72));
    try std.testing.expectEqual(@as(u32, 145), anchorOffsetPx(120, 25, 400));
    try std.testing.expectEqual(@as(u32, 400), anchorOffsetPx(399, 9, 400));
    try std.testing.expectEqual(@as(u32, 400), anchorOffsetPx(std.math.maxInt(u32), std.math.maxInt(u32), 400));
}
