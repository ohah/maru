//! 스크롤 컨테이너의 좌표계다 — backing pixel 하나가 단위이고, 이 모듈 밖으로 분수 좌표가 나가지 않는다.
//!
//! 단일 출처: docs/scroll-view.md. 소비처(도크·파일 탐색기·소스 컨트롤·...)는 상태를 자기가 소유하고
//! 그 값의 legal range와 전이만 여기서 받는다. 이 모듈은 tree·paint·host를 읽지 않는다.
//!
//! **`project`가 build보다 먼저 온다**는 것이 CSS `overflow: auto`와 갈라지는 지점이다(§2.1). 브라우저는
//! 자식을 다 만든 뒤 넘치는 부분을 자르지만, 여기서는 보이지 않는 항목의 노드도 텍스트도 만들지 않는다.
//! 그래서 창(window)을 정하는 것이 자르는 것보다 앞선다.
//!
//! 지금 여기 있는 것은 **좌표계뿐이다.** §2가 ScrollView 소유라고 적은 것 중 스크롤바 entry 발행과
//! viewport clip은 아직 `session_dock/build.zig`가, 분수 휠 residue와 selection follow는 아직 host가
//! 들고 있다. 파일 이름은 목적지를 가리키고, 그 나머지는 SV1b·SV1c가 옮긴다(docs/implementation-plan.md).
//! 이 주석은 다음 사람이 "여기 없으면 아무 데도 없다"고 오해하지 않게 하기 위한 것이다.

const std = @import("std");

/// 소비처가 소유하는 상태다. 이 모듈은 legal range와 전이만 정한다. 분수 wheel 입력은 일부러 밖에
/// 남긴다 — tree rect와 GPU draw rect가 정수여야 셀 경계에서 흔들리지 않는다.
pub const State = struct {
    offset_y_px: u32 = 0,

    pub fn scrollByPx(self: *State, delta_px: i64, max_offset_px: u32) bool {
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

    pub fn clamp(self: *State, max_offset_px: u32) void {
        self.offset_y_px = @min(self.offset_y_px, max_offset_px);
    }

    /// 유지 중인 offset을 wheel 입력과 **같은** 유계 좌표계로만 교체한다. refresh/resize anchor는
    /// 새로 삽입된 그룹 헤더 밑으로 카드가 밀리면 clamp 전에 음수일 수 있으므로 입력이 부호 있는 값이다.
    pub fn setOffsetPx(self: *State, requested_offset_px: i64, max_offset_px: u32) bool {
        const clamped: u32 = @intCast(std.math.clamp(requested_offset_px, @as(i64, 0), @as(i64, max_offset_px)));
        if (clamped == self.offset_y_px) return false;
        self.offset_y_px = clamped;
        return true;
    }

    pub fn reset(self: *State) void {
        self.offset_y_px = 0;
    }
};

pub const Projection = struct {
    content_height_px: u32,
    max_offset_px: u32,
    offset_y_px: u32,
    first_index: usize,
    /// 반환된 첫 항목이 시작하는 local y다. 0이거나 음수이며, 분수가 아니다.
    first_origin_y_px: i32,
    end_exclusive: usize,
};

/// `project`의 비-항목 입력. 항목 높이는 소비처가 comptime 함수로 준다.
pub const Extent = struct {
    /// `itemHeightPx`가 `[0, count)`의 **모든** index에 답할 수 있어야 한다. 항목 열과 이 수는
    /// 별개 인자라 어긋날 수 있으므로, 소비처는 둘을 한 자리에서 만든다 — 도크의
    /// `ArchiveScrollItems.extent()`가 그 형태다. 여기서 범위를 다시 검사하지 않는 것은 검사를
    /// 잊어서가 아니라, 항목 열을 소유한 쪽이 유일하게 그 답을 알기 때문이다.
    count: usize,
    gap_px: u32,
    viewport_h_px: u32,
};

/// Page 키는 일부러 카드 하나를 화면에 남긴다. viewport가 0에 가까우면 page step이 의미가 없으므로
/// 고정 chrome 치수에서 움직임을 만들어내지 않는다.
pub fn pageStepPx(viewport_h_px: u32, item_h_px: u32) u32 {
    return viewport_h_px -| item_h_px;
}

/// 소비처가 항목의 content-space top과 그 안에서의 비음수 변위를 계산해 넘기면, 스냅샷이 통째로
/// 교체되는 순간에도 같은 자리를 유지한다. 포화·clamp 산술을 여기 두어 재정렬된 anchor가 유계
/// 좌표를 넘지 못하게 한다.
pub fn anchorOffsetPx(item_top_px: u32, intra_item_y_px: u32, max_offset_px: u32) u32 {
    const requested = @as(u64, item_top_px) + @as(u64, intra_item_y_px);
    return @intCast(@min(requested, @as(u64, max_offset_px)));
}

/// Scrollbar의 logical 치수. terminal cell이 아니라 소비처의 metrics가 backing scale에서 resolve한다.
pub const ScrollbarMetrics = struct {
    width_px: u32,
    /// track의 오른쪽 끝과 scroll-area content edge 사이 여백.
    inset_x_px: u32,
    /// content가 아무리 길어도 thumb이 이보다 얇아지지 않는다 — 집을 수 없는 thumb은 affordance가 아니다.
    min_thumb_px: u32,
};

/// track/thumb의 backing-pixel 기하. paint·hit-test·drag가 **같은 값 하나**를 소비한다. 이 struct는
/// 상태가 없으므로 매 프레임 같은 입력에서 같은 결과가 나온다.
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

/// scroll-area의 published content rect. scrollbar 기하를 여기서 다시 계산하지 않고 **완성된 tree가
/// 발행한 값**을 읽는 것이 핵심이다 — 그래야 scroll-area가 움직여도 스크롤바가 따라간다(§4).
pub const ContentRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// scroll-area 오른쪽에 남아 있는 컨테이너 padding 폭. 스크롤바는 **그 여백 안에** 놓여 content와
    /// 겹치지 않는다. 여백이 모자라면 아예 그리지 않는다 — 목록 위에 겹쳐 그리는 대안은 사용자가
    /// "UI랑 겹쳐 보인다"고 보고한 바로 그 상태다.
    gutter_w: f32,
};

/// 스크롤할 것이 없거나 자리가 안 나오면 `null`이며, 그 경우 어떤 track/thumb도 발행하지 않는다 —
/// 넘치지 않는 목록에 스크롤바를 그리면 사용자에게 없는 여백을 있다고 말하는 셈이다.
pub fn scrollbarGeometry(
    content: ContentRect,
    content_height_px: u32,
    offset_px: u32,
    m: ScrollbarMetrics,
) ?ScrollbarGeometry {
    if (content.w <= 0 or content.h <= 0 or m.width_px == 0) return null;
    const viewport_h_px: u32 = @intFromFloat(@max(content.h, 0));
    const max_offset = content_height_px -| viewport_h_px;
    if (max_offset == 0) return null;
    const width: f32 = @floatFromInt(m.width_px);
    if (content.gutter_w < width) return null;

    const track_h = content.h;
    const proportional = track_h * content.h / @as(f32, @floatFromInt(content_height_px));
    const thumb_h = @min(track_h, @max(@as(f32, @floatFromInt(m.min_thumb_px)), proportional));
    const travel = track_h - thumb_h;
    const clamped_offset = @min(offset_px, max_offset);
    const ratio = @as(f32, @floatFromInt(clamped_offset)) / @as(f32, @floatFromInt(max_offset));
    return .{
        // 여백 안에서 가운데. 컨테이너 바깥 edge에 붙이면 rounded clip에 닿아 잘려 보이고, content에
        // 붙이면 다시 카드와 겹친다.
        .track_x = content.x + content.w + (content.gutter_w - width) / 2,
        .track_y = content.y,
        .track_w = width,
        .track_h = track_h,
        .thumb_y = content.y + travel * ratio,
        .thumb_h = thumb_h,
        .max_offset_px = max_offset,
    };
}

/// 유계 항목 열을 allocation 없이 창으로 자른다.
///
/// 높이를 **나눗셈이 아니라 walk로** 구하는 것이 계약이다(§3). 항목 높이가 같다는 보장이 없기
/// 때문이다 — 도크는 그룹 헤더와 카드가 다르고 펼친 카드는 또 다르다. `first_index * item_h`는
/// 그 순간 틀린 답을 낸다. `itemHeightPx`가 comptime인 덕에 이 알고리즘은 소비처의 레코드 타입을
/// 모른 채로 남는다.
pub fn project(
    context: anytype,
    comptime itemHeightPx: fn (@TypeOf(context), usize) u32,
    extent: Extent,
    requested_offset_px: u32,
) Projection {
    const count = extent.count;
    var content_height: u32 = 0;
    for (0..count) |index| {
        content_height +|= itemHeightPx(context, index);
        if (index + 1 < count) content_height +|= extent.gap_px;
    }
    const max_offset = content_height -| extent.viewport_h_px;
    const offset = @min(requested_offset_px, max_offset);

    var cursor: u32 = 0;
    var first = count;
    for (0..count) |index| {
        const h = itemHeightPx(context, index);
        const end = cursor +| h;
        if (end > offset) {
            first = index;
            break;
        }
        cursor = end +| if (index + 1 < count) extent.gap_px else 0;
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
    while (end < count and y < @as(i64, extent.viewport_h_px)) : (end += 1) {
        y += @as(i64, itemHeightPx(context, end));
        if (end + 1 < count) y += extent.gap_px;
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

const FixtureKind = enum { group, card };

const Fixture = struct {
    kinds: []const FixtureKind,
    group_h_px: u32,
    card_h_px: u32,
    expanded_index: ?usize = null,
    expanded_h_px: u32 = 0,
};

fn fixtureHeight(fixture: Fixture, index: usize) u32 {
    if (fixture.kinds[index] == .card and fixture.expanded_index != null and fixture.expanded_index.? == index)
        return fixture.expanded_h_px;
    return switch (fixture.kinds[index]) {
        .group => fixture.group_h_px,
        .card => fixture.card_h_px,
    };
}

test "project clips partial first and last item without a trailing gap" {
    const kinds = [_]FixtureKind{ .group, .card, .card };
    const fixture = Fixture{ .kinds = &kinds, .group_h_px = 20, .card_h_px = 50 };
    const result = project(fixture, fixtureHeight, .{ .count = kinds.len, .gap_px = 10, .viewport_h_px = 60 }, 35);
    try std.testing.expectEqual(@as(u32, 140), result.content_height_px);
    try std.testing.expectEqual(@as(u32, 80), result.max_offset_px);
    try std.testing.expectEqual(@as(usize, 1), result.first_index);
    try std.testing.expectEqual(@as(i32, -5), result.first_origin_y_px);
    try std.testing.expectEqual(@as(usize, 3), result.end_exclusive);
}

test "project reserves one expanded item in the same scroll coordinate" {
    const kinds = [_]FixtureKind{ .group, .card, .card };
    const fixture = Fixture{
        .kinds = &kinds,
        .group_h_px = 20,
        .card_h_px = 50,
        .expanded_index = 1,
        .expanded_h_px = 170,
    };
    const result = project(fixture, fixtureHeight, .{ .count = kinds.len, .gap_px = 0, .viewport_h_px = 100 }, 60);
    // group 20 + 펼친 카드 170 + 보통 카드 50. viewport가 펼침 안에서 시작하므로 그 원점과 다음
    // 카드가 같은 170px 사각형을 써야 한다.
    try std.testing.expectEqual(@as(u32, 240), result.content_height_px);
    try std.testing.expectEqual(@as(u32, 140), result.max_offset_px);
    try std.testing.expectEqual(@as(usize, 1), result.first_index);
    try std.testing.expectEqual(@as(i32, -40), result.first_origin_y_px);
    try std.testing.expectEqual(@as(usize, 2), result.end_exclusive);
}

test "project walks heights instead of dividing by a uniform item height" {
    // 높이가 섞이면 나눗셈 근사(`offset / item_h`)와 답이 갈린다. 이 case가 그 차이를 고정한다.
    const kinds = [_]FixtureKind{ .group, .card, .group, .card };
    const fixture = Fixture{ .kinds = &kinds, .group_h_px = 20, .card_h_px = 100 };
    const result = project(fixture, fixtureHeight, .{ .count = kinds.len, .gap_px = 0, .viewport_h_px = 100 }, 130);
    // 누적: group [0,20) card [20,120) group [120,140) card [140,240).
    // offset 130은 세 번째 항목 안이다. 균일 높이 100으로 나눴다면 index 1이 나왔을 것이다.
    try std.testing.expectEqual(@as(usize, 2), result.first_index);
    try std.testing.expectEqual(@as(i32, -10), result.first_origin_y_px);
}

test "scroll state clamps each backing pixel boundary" {
    var state = State{};
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
    try std.testing.expect(scrollbarGeometry(.{ .x = 0, .y = 0, .w = 200, .h = 400, .gutter_w = 40 }, 400, 0, m) == null);
    try std.testing.expect(scrollbarGeometry(.{ .x = 0, .y = 0, .w = 200, .h = 400, .gutter_w = 40 }, 300, 0, m) == null);
    // 여백이 track 폭을 못 담으면 그리지 않는다 — 목록 위에 겹쳐 그리는 대안은 두지 않는다.
    try std.testing.expect(scrollbarGeometry(.{ .x = 0, .y = 0, .w = 200, .h = 400, .gutter_w = 4 }, 4000, 0, m) == null);
}

test "scrollbar thumb spans the visible proportion and reaches both ends" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    const content = ContentRect{ .x = 10, .y = 20, .w = 200, .h = 400, .gutter_w = 40 };
    const top = scrollbarGeometry(content, 1600, 0, m).?;
    try std.testing.expectEqual(@as(f32, 226), top.track_x); // 10 + 200 + (40 - 8) / 2
    try std.testing.expectEqual(@as(f32, 20), top.track_y);
    try std.testing.expectEqual(@as(u32, 1200), top.max_offset_px);
    // 보이는 비율 400/1600 = 1/4.
    try std.testing.expectEqual(@as(f32, 100), top.thumb_h);
    try std.testing.expectEqual(@as(f32, 20), top.thumb_y);

    const bottom = scrollbarGeometry(content, 1600, 1200, m).?;
    // 맨 아래에서 thumb 밑변이 track 밑변과 정확히 맞는다.
    try std.testing.expectApproxEqAbs(bottom.track_y + bottom.track_h - bottom.thumb_h, bottom.thumb_y, 0.01);
}

test "scrollbar thumb never gets too thin to grab" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    // 아주 긴 목록: 비례 높이는 0.04px지만 최소 높이가 이긴다.
    const geometry = scrollbarGeometry(.{ .x = 0, .y = 0, .w = 200, .h = 400, .gutter_w = 40 }, 4_000_000, 0, m).?;
    try std.testing.expectEqual(@as(f32, 24), geometry.thumb_h);
}

test "scrollbar drag round trips every reachable offset and clamps beyond the track" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    const geometry = scrollbarGeometry(.{ .x = 0, .y = 5, .w = 180, .h = 400, .gutter_w = 40 }, 1200, 0, m).?;
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

test "withOffset predicts exactly what the next published geometry will be" {
    // 이 함수는 track click이 목록을 옮긴 **직후**, 아직 새 tree가 발행되기 전에 이어지는 드래그의
    // grab 기준점을 만든다. 그러므로 계약은 "그럴듯한 thumb 위치"가 아니라 **다음 프레임이 발행할
    // 바로 그 값**이다. 두 경로가 갈리면 손을 뗐다 잡을 때마다 thumb이 눈에 띄게 튄다.
    //
    // 이 계약을 보는 판정자가 없었다: `withOffset`의 비율을 절반으로 바꿔도 전체 스위트가 초록이었다.
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    const content = ContentRect{ .x = 10, .y = 20, .w = 200, .h = 400, .gutter_w = 40 };
    const at_top = scrollbarGeometry(content, 1600, 0, m).?;
    for ([_]u32{ 0, 1, 250, 600, 1199, 1200, 99_999 }) |offset| {
        const published = scrollbarGeometry(content, 1600, offset, m).?;
        try std.testing.expectApproxEqAbs(published.thumb_y, at_top.withOffset(offset).thumb_y, 0.01);
    }
    // 스크롤할 것이 없으면 옮길 곳도 없다.
    const fixed = ScrollbarGeometry{ .track_x = 0, .track_y = 0, .track_w = 8, .track_h = 100, .thumb_y = 0, .thumb_h = 100, .max_offset_px = 0 };
    try std.testing.expectEqual(@as(f32, 0), fixed.withOffset(50).thumb_y);
}

test "thumb and track containment use half-open bounds so adjacent pixels never both hit" {
    const geometry = ScrollbarGeometry{ .track_x = 100, .track_y = 20, .track_w = 8, .track_h = 400, .thumb_y = 60, .thumb_h = 40, .max_offset_px = 1200 };
    // thumb의 위 경계는 포함, 아래 경계는 제외다. 닫힌 구간이면 thumb 바로 아래 1px이 thumb이자
    // track이라 같은 down이 드래그와 점프 둘 다로 읽힌다.
    try std.testing.expect(geometry.thumbContains(60));
    try std.testing.expect(geometry.thumbContains(99.9));
    try std.testing.expect(!geometry.thumbContains(100));
    try std.testing.expect(!geometry.thumbContains(59.9));
    // track은 x도 본다 — gutter 밖 클릭이 스크롤로 새면 안 된다.
    try std.testing.expect(geometry.trackContains(100, 20));
    try std.testing.expect(geometry.trackContains(107.9, 419.9));
    try std.testing.expect(!geometry.trackContains(108, 200));
    try std.testing.expect(!geometry.trackContains(99.9, 200));
    try std.testing.expect(!geometry.trackContains(104, 420));
    try std.testing.expect(!geometry.trackContains(104, 19.9));
}

test "track click centers the thumb at the pointer" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    const geometry = scrollbarGeometry(.{ .x = 0, .y = 0, .w = 180, .h = 400, .gutter_w = 40 }, 1200, 0, m).?;
    // 트랙 정중앙을 누르면 thumb 중앙이 거기 오므로 offset도 대략 절반이다.
    const middle = geometry.offsetForTrackClick(geometry.track_y + geometry.track_h / 2);
    try std.testing.expect(middle > geometry.max_offset_px * 4 / 10);
    try std.testing.expect(middle < geometry.max_offset_px * 6 / 10);
    try std.testing.expectEqual(@as(u32, 0), geometry.offsetForTrackClick(geometry.track_y));
}
