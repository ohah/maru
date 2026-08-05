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

/// Scrollbar의 logical 치수. terminal cell이 아니라 `DockMetrics`가 backing scale에서 resolve한다.
pub const ScrollbarMetrics = struct {
    width_px: u32,
    /// track의 오른쪽 끝과 scroll-area content edge 사이 여백.
    inset_x_px: u32,
    /// content가 아무리 길어도 thumb이 이보다 얇아지지 않는다 — 집을 수 없는 thumb은 affordance가 아니다.
    min_thumb_px: u32,
};

/// track/thumb의 backing-pixel 기하. paint·hit-test·drag가 **같은 값 하나**를 소비한다. 이 struct는
/// 상태가 없으므로 매 프레임 같은 입력에서 같은 결과가 나온다(file explorer scrollbar와 같은 규율).
pub const ScrollbarGeometry = struct {
    track_x: f32,
    track_y: f32,
    track_w: f32,
    track_h: f32,
    thumb_y: f32,
    thumb_h: f32,
    max_offset_px: u32,

    /// thumb을 잡은 지점(`grab_dy` = 누른 y - thumb top)을 유지한 채 pointer를 따라가는 offset.
    /// 반환값은 이미 [0, max_offset_px]로 clamp되어 있다.
    pub fn offsetForPointer(self: ScrollbarGeometry, pointer_y: f64, grab_dy: f32) u32 {
        if (!std.math.isFinite(pointer_y) or !std.math.isFinite(grab_dy)) return 0;
        const travel = self.track_h - self.thumb_h;
        if (travel <= 0 or self.max_offset_px == 0) return 0;
        const thumb_top = std.math.clamp(
            pointer_y - @as(f64, grab_dy),
            @as(f64, self.track_y),
            @as(f64, self.track_y + travel),
        );
        const ratio = (thumb_top - @as(f64, self.track_y)) / @as(f64, travel);
        const scaled = @round(ratio * @as(f64, @floatFromInt(self.max_offset_px)));
        return @intFromFloat(std.math.clamp(scaled, 0, @as(f64, @floatFromInt(self.max_offset_px))));
    }

    /// thumb 바깥 track click은 그 지점에 thumb 중앙을 놓는다. 이후 드래그와 같은 매핑을 쓰므로
    /// 눌렀다 끌기 시작하는 순간 위치가 튀지 않는다.
    pub fn offsetForTrackClick(self: ScrollbarGeometry, pointer_y: f64) u32 {
        return self.offsetForPointer(pointer_y, self.thumb_h / 2);
    }

    pub fn thumbContains(self: ScrollbarGeometry, y: f64) bool {
        return y >= self.thumb_y and y < self.thumb_y + self.thumb_h;
    }

    pub fn trackContains(self: ScrollbarGeometry, x: f64, y: f64) bool {
        return x >= self.track_x and x < self.track_x + self.track_w and
            y >= self.track_y and y < self.track_y + self.track_h;
    }

    /// 같은 track에서 offset만 바뀐 기하. track click이 목록을 옮긴 **직후**의 thumb 위치를 알아야
    /// 이어지는 드래그의 grab 지점이 튀지 않는데, 그 시점에는 아직 새 tree가 발행되지 않았다.
    pub fn withOffset(self: ScrollbarGeometry, offset_px: u32) ScrollbarGeometry {
        if (self.max_offset_px == 0) return self;
        var next = self;
        const travel = self.track_h - self.thumb_h;
        const ratio = @as(f32, @floatFromInt(@min(offset_px, self.max_offset_px))) / @as(f32, @floatFromInt(self.max_offset_px));
        next.thumb_y = self.track_y + travel * ratio;
        return next;
    }
};

/// scroll-area content rect와 projection 결과에서 scrollbar 기하를 만든다. 스크롤할 것이 없거나
/// 자리가 안 나오면 `null`이며, 그 경우 어떤 track/thumb도 발행하지 않는다 — 넘치지 않는 목록에
/// 스크롤바를 그리면 사용자에게 없는 여백을 있다고 말하는 셈이다.
pub fn scrollbarGeometry(
    content_x: f32,
    content_y: f32,
    content_w: f32,
    content_h: f32,
    content_height_px: u32,
    offset_px: u32,
    m: ScrollbarMetrics,
) ?ScrollbarGeometry {
    if (content_w <= 0 or content_h <= 0 or m.width_px == 0) return null;
    const viewport_h_px: u32 = @intFromFloat(@max(content_h, 0));
    const max_offset = content_height_px -| viewport_h_px;
    if (max_offset == 0) return null;
    const occupied: f32 = @floatFromInt(m.width_px + m.inset_x_px);
    if (content_w <= occupied) return null;

    const track_h = content_h;
    const proportional = track_h * content_h / @as(f32, @floatFromInt(content_height_px));
    const thumb_h = @min(track_h, @max(@as(f32, @floatFromInt(m.min_thumb_px)), proportional));
    const travel = track_h - thumb_h;
    const clamped_offset = @min(offset_px, max_offset);
    const ratio = @as(f32, @floatFromInt(clamped_offset)) / @as(f32, @floatFromInt(max_offset));
    return .{
        .track_x = content_x + content_w - @as(f32, @floatFromInt(m.width_px + m.inset_x_px)),
        .track_y = content_y,
        .track_w = @floatFromInt(m.width_px),
        .track_h = track_h,
        .thumb_y = content_y + travel * ratio,
        .thumb_h = thumb_h,
        .max_offset_px = max_offset,
    };
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

test "scrollbar geometry only exists when the list actually overflows" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    // 넘치지 않으면 발행하지 않는다 — 없는 여백을 있다고 말하지 않기 위해서다.
    try std.testing.expect(scrollbarGeometry(0, 0, 200, 400, 400, 0, m) == null);
    try std.testing.expect(scrollbarGeometry(0, 0, 200, 400, 300, 0, m) == null);
    // 폭이 track+inset을 못 담으면 그리지 않는다(잘린 스크롤바를 내지 않는다).
    try std.testing.expect(scrollbarGeometry(0, 0, 12, 400, 4000, 0, m) == null);
}

test "scrollbar thumb spans the visible proportion and reaches both ends" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    const top = scrollbarGeometry(10, 20, 200, 400, 1600, 0, m).?;
    try std.testing.expectEqual(@as(f32, 198), top.track_x); // 10 + 200 - 8 - 4
    try std.testing.expectEqual(@as(f32, 20), top.track_y);
    try std.testing.expectEqual(@as(u32, 1200), top.max_offset_px);
    // 보이는 비율 400/1600 = 1/4.
    try std.testing.expectEqual(@as(f32, 100), top.thumb_h);
    try std.testing.expectEqual(@as(f32, 20), top.thumb_y);

    const bottom = scrollbarGeometry(10, 20, 200, 400, 1600, 1200, m).?;
    // 맨 아래에서 thumb 밑변이 track 밑변과 정확히 맞는다.
    try std.testing.expectApproxEqAbs(bottom.track_y + bottom.track_h - bottom.thumb_h, bottom.thumb_y, 0.01);
}

test "scrollbar thumb never gets too thin to grab" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    // 아주 긴 목록: 비례 높이는 0.04px지만 최소 높이가 이긴다.
    const geometry = scrollbarGeometry(0, 0, 200, 400, 4_000_000, 0, m).?;
    try std.testing.expectEqual(@as(f32, 24), geometry.thumb_h);
}

test "scrollbar drag round trips every reachable offset and clamps beyond the track" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    const geometry = scrollbarGeometry(0, 5, 180, 400, 1200, 0, m).?;
    const travel = geometry.track_h - geometry.thumb_h;
    // thumb top을 정확히 그 offset의 위치에 놓으면 같은 offset이 돌아온다.
    for ([_]u32{ 0, 1, 137, 400, 799, 800 }) |wanted| {
        if (wanted > geometry.max_offset_px) continue;
        const y = geometry.track_y + travel * @as(f32, @floatFromInt(wanted)) / @as(f32, @floatFromInt(geometry.max_offset_px));
        try std.testing.expectEqual(wanted, geometry.offsetForPointer(y, 0));
    }
    // track 밖으로 끌어도 범위를 넘지 않는다.
    try std.testing.expectEqual(@as(u32, 0), geometry.offsetForPointer(-10_000, 0));
    try std.testing.expectEqual(geometry.max_offset_px, geometry.offsetForPointer(10_000, 0));
    // 비유한 좌표는 기하를 무의미하게 만들므로 흘려보내지 않는다.
    try std.testing.expectEqual(@as(u32, 0), geometry.offsetForPointer(std.math.nan(f64), 0));
}

test "track click centers the thumb at the pointer" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    const geometry = scrollbarGeometry(0, 0, 180, 400, 1200, 0, m).?;
    // 트랙 정중앙을 누르면 thumb 중앙이 거기 오므로 offset도 대략 절반이다.
    const middle = geometry.offsetForTrackClick(geometry.track_y + geometry.track_h / 2);
    try std.testing.expect(middle > geometry.max_offset_px * 4 / 10);
    try std.testing.expect(middle < geometry.max_offset_px * 6 / 10);
    try std.testing.expectEqual(@as(u32, 0), geometry.offsetForTrackClick(geometry.track_y));
}
