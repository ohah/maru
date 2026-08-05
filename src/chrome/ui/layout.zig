//! Metal chrome이 공유하는 typed flex/rect 계산의 순수 기반이다.
//!
//! 이 모듈은 DOM·CSS parser나 platform renderer를 대체하지 않는다. component가 props에서
//! 만든 `Item`과 host가 가진 available backing-pixel size만 받아 동일한 `UiRect`를 낸다.
//! ML2의 rect tree, ML3의 paint/hit-test는 이 값을 다시 계산하지 않고 소비해야 한다.
//! 따라서 잘못된 style은 관대하게 보정하지 않고 error로 끝내 caller가 draw/hit 대상을
//! 만들지 않게 한다. 단일 출처: docs/metal-ui-layout.md §3~§5.

const std = @import("std");

/// CSS 문자열 대신 사용하는 닫힌 길이 vocabulary. px는 backing-pixel, percent는
/// definite한 parent content axis의 0..1 비율이다.
pub const UiLength = union(enum) {
    auto,
    px: f32,
    percent: f32,
    fill: f32,
};

pub const UiEdges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn horizontal(self: UiEdges) f32 {
        return self.left + self.right;
    }

    pub fn vertical(self: UiEdges) f32 {
        return self.top + self.bottom;
    }
};

pub const UiSize = struct {
    width: f32 = 0,
    height: f32 = 0,
};

/// Layout 결과는 border box다. `UiStyle.padding`은 text measure가 낸 content size에만
/// 더해지고, px/percent/basis로 지정한 값은 border box 전체 크기다. 이 규칙은 native
/// chrome의 fixed hit target과 paint rect가 서로 달라지는 것을 막는다.
pub const UiRect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

/// 두 rect의 교집합 — clip을 접는 모든 곳의 단일 출처(`ui/tree`의 ancestor clip fold, `ui/paint`의 카드
/// 배경, component의 장식 quad). 빈 교집합은 위치에 의미가 없으므로 `a`(부모/뷰포트) 경계로 접어,
/// "자식 clip은 항상 부모 clip 안"이라는 불변식이 면적 0짜리 rect 때문에 깨져 보이지 않게 한다.
pub fn intersectRect(a: UiRect, b: UiRect) UiRect {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.width, b.x + b.width);
    const bottom = @min(a.y + a.height, b.y + b.height);
    if (right <= left or bottom <= top) return .{
        .x = @min(@max(left, a.x), a.x + a.width),
        .y = @min(@max(top, a.y), a.y + a.height),
        .width = 0,
        .height = 0,
    };
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

test "intersectRect folds an empty result into the parent so clip containment still holds" {
    const parent = UiRect{ .x = 0, .y = 100, .width = 200, .height = 50 };
    const inside = intersectRect(parent, .{ .x = 10, .y = 110, .width = 20, .height = 20 });
    try std.testing.expectEqual(@as(f32, 20), inside.width);
    // 완전히 아래로 벗어난 자식: 면적 0이되 원점은 부모 경계 안이어야 한다.
    const below = intersectRect(parent, .{ .x = 10, .y = 500, .width = 20, .height = 20 });
    try std.testing.expectEqual(@as(f32, 0), below.height);
    try std.testing.expect(below.y >= parent.y);
    try std.testing.expect(below.y <= parent.y + parent.height);
}

pub const Direction = enum { row, column };
pub const Justify = enum { start, center, end, space_between };
pub const Align = enum { start, center, end, stretch };
pub const Overflow = enum { visible, clip };

pub const FlexStyle = struct {
    grow: f32 = 0,
    shrink: f32 = 1,
    basis: ?UiLength = null,
};

/// v1에는 `.flex`만 존재한다. grid 값 자체를 노출하지 않아 지원하지 않는 style이
/// 조용히 다른 layout으로 fallback하는 일을 막는다.
pub const Display = enum { flex };

pub const UiStyle = struct {
    width: UiLength = .auto,
    height: UiLength = .auto,
    min_width: ?f32 = null,
    max_width: ?f32 = null,
    min_height: ?f32 = null,
    max_height: ?f32 = null,
    margin: UiEdges = .{},
    padding: UiEdges = .{},
    gap: f32 = 0,
    display: Display = .flex,
    flex: FlexStyle = .{},
    /// Child가 container의 align_items를 바꾸고 싶을 때만 쓴다. 실제 hover/pressed
    /// 같은 runtime state가 아니라 immutable layout prop이다.
    align_self: ?Align = null,
};

pub const MeasureConstraint = struct {
    /// Fixed px/percent size가 있으면 알려 주고, auto/fill이면 null이다.
    known_width: ?f32 = null,
    known_height: ?f32 = null,
    /// Parent content box에서 own margin·padding을 뺀 최대 content 측정 가능 크기다.
    available_width: ?f32 = null,
    available_height: ?f32 = null,
};

pub const MeasureFn = *const fn (context: ?*const anyopaque, constraint: MeasureConstraint) UiSize;

pub const Item = struct {
    style: UiStyle = .{},
    measure_context: ?*const anyopaque = null,
    measure: ?MeasureFn = null,
};

pub const FlexContainer = struct {
    /// Container도 같은 UiStyle을 쓴다. 이 core에서는 children 배치에 영향을 주는
    /// padding/gap만 읽고, width/height는 parent가 전달한 `size`에서 이미 해소됐다.
    style: UiStyle = .{},
    size: UiSize,
    direction: Direction = .row,
    justify: Justify = .start,
    align_items: Align = .stretch,
    overflow: Overflow = .visible,
};

/// Caller-owned scratch를 강제해 layout hot path에서 allocation/lock/I/O가 생기지
/// 않게 한다. 이 데이터는 result가 아니므로 draw/hit-test에 넘기지 않는다.
pub const FlexScratch = struct {
    target_main: f32 = 0,
    base_cross: f32 = 0,
    margin_main_before: f32 = 0,
    margin_main_after: f32 = 0,
    margin_cross_before: f32 = 0,
    margin_cross_after: f32 = 0,
    min_main: ?f32 = null,
    max_main: ?f32 = null,
    min_cross: ?f32 = null,
    max_cross: ?f32 = null,
    grow: f32 = 0,
    shrink: f32 = 1,
    cross_auto: bool = false,
    frozen: bool = false,
    align_self: ?Align = null,
};

pub const LayoutResult = struct {
    content_rect: UiRect,
    /// overflow clip이면 child draw/hit-test가 함께 사용해야 할 content rect다.
    clip_rect: ?UiRect,
};

pub const LayoutError = error{
    ItemCountMismatch,
    InvalidNumber,
    NegativeValue,
    PercentOutOfRange,
    MinGreaterThanMax,
    IndefinitePercent,
    FillRequiresFlex,
    FillOnCrossAxis,
    FillAndGrow,
    FillInBasis,
    InvalidMeasuredSize,
};

/// A definite parent axis가 없으면 percentage를 임의 값으로 바꾸지 않는다. tree를
/// 가진 ML2는 이 error를 diagnostic으로 기록하고 해당 node의 draw/hit을 만들지 않는다.
pub fn resolveLength(length: UiLength, parent_axis: ?f32, auto_size: f32) LayoutError!f32 {
    try validateNonNegativeFinite(auto_size);
    return switch (length) {
        .auto => auto_size,
        .px => |value| blk: {
            try validateNonNegativeFinite(value);
            break :blk value;
        },
        .percent => |ratio| blk: {
            try validatePercent(ratio);
            const parent = parent_axis orelse return error.IndefinitePercent;
            try validateNonNegativeFinite(parent);
            break :blk parent * ratio;
        },
        .fill => return error.FillRequiresFlex,
    };
}

/// 하나의 row/column line을 계산한다. `out`과 `scratch`는 items와 같은 길이여야 한다.
/// 실패 시 out을 빈 rect로 남겨 이전 frame의 rect를 실수로 재사용하지 않게 한다.
pub fn layoutFlex(container: FlexContainer, items: []const Item, scratch: []FlexScratch, out: []UiRect) LayoutError!LayoutResult {
    for (out) |*rect| rect.* = .{};
    if (scratch.len != items.len or out.len != items.len) return error.ItemCountMismatch;

    try validateSize(container.size);
    try validateEdges(container.style.padding);
    try validateNonNegativeFinite(container.style.gap);

    const content_rect = UiRect{
        .x = container.style.padding.left,
        .y = container.style.padding.top,
        .width = nonNegativeDifference(container.size.width, container.style.padding.horizontal()),
        .height = nonNegativeDifference(container.size.height, container.style.padding.vertical()),
    };
    const result: LayoutResult = .{
        .content_rect = content_rect,
        .clip_rect = if (container.overflow == .clip) content_rect else null,
    };
    if (items.len == 0) return result;

    const main_available = mainSize(content_rect, container.direction);
    const cross_available = crossSize(content_rect, container.direction);
    const gaps_total = try finiteProduct(container.style.gap, @as(f32, @floatFromInt(items.len - 1)));

    for (items, scratch) |item, *entry| {
        try validateItemStyle(item.style, container.direction);
        const measured = try measure(item, content_rect);
        const main_length = mainLength(item.style, container.direction);
        const cross_length = crossLength(item.style, container.direction);
        const basis = item.style.flex.basis;

        const base_main = if (basis) |value|
            try resolveBasis(value, main_available, mainOf(measured, container.direction))
        else
            try resolveLengthOrFillBase(main_length, main_available, mainOf(measured, container.direction));
        const base_cross = try resolveLength(cross_length, cross_available, crossOf(measured, container.direction));

        entry.* = .{
            .target_main = clamp(base_main, minimumOrZero(mainMin(item.style, container.direction)), mainMax(item.style, container.direction)),
            .base_cross = clamp(base_cross, minimumOrZero(crossMin(item.style, container.direction)), crossMax(item.style, container.direction)),
            .margin_main_before = mainMarginBefore(item.style.margin, container.direction),
            .margin_main_after = mainMarginAfter(item.style.margin, container.direction),
            .margin_cross_before = crossMarginBefore(item.style.margin, container.direction),
            .margin_cross_after = crossMarginAfter(item.style.margin, container.direction),
            .min_main = minimumOrZero(mainMin(item.style, container.direction)),
            .max_main = mainMax(item.style, container.direction),
            .min_cross = minimumOrZero(crossMin(item.style, container.direction)),
            .max_cross = crossMax(item.style, container.direction),
            .grow = effectiveGrow(main_length, item.style.flex.grow),
            .shrink = item.style.flex.shrink,
            .cross_auto = isAuto(cross_length),
            .align_self = item.style.align_self,
        };
    }

    try distributeFlex(main_available - gaps_total, scratch);
    try placeItems(container, content_rect, scratch, out);
    for (out) |rect| validateRect(rect) catch |err| {
        for (out) |*stale| stale.* = .{};
        return err;
    };
    return result;
}

/// `UiNode` root처럼 다른 flex parent의 `Item`이 아닌 style도 같은 closed vocabulary로
/// 검증할 때 쓴다. caller가 성공한 layout만 publish하게 해 invalid root가 임의 rect로
/// 보이는 fallback을 막는다.
pub fn validateItemStyle(style: UiStyle, direction: Direction) LayoutError!void {
    try validateLength(style.width);
    try validateLength(style.height);
    try validateEdges(style.margin);
    try validateEdges(style.padding);
    try validateNonNegativeFinite(style.gap);
    try validateMinMax(style.min_width, style.max_width);
    try validateMinMax(style.min_height, style.max_height);
    try validateNonNegativeFinite(style.flex.grow);
    try validateNonNegativeFinite(style.flex.shrink);
    if (style.flex.basis) |basis| {
        try validateLength(basis);
        if (isFill(basis)) return error.FillInBasis;
    }

    const main = mainLength(style, direction);
    const cross = crossLength(style, direction);
    if (isFill(cross)) return error.FillOnCrossAxis;
    if (isFill(main) and style.flex.grow != 0) return error.FillAndGrow;
}

fn validateLength(length: UiLength) LayoutError!void {
    switch (length) {
        .auto => {},
        .px => |value| try validateNonNegativeFinite(value),
        .percent => |value| try validatePercent(value),
        .fill => |value| {
            if (!std.math.isFinite(value)) return error.InvalidNumber;
            if (value <= 0) return error.NegativeValue;
        },
    }
}

fn validatePercent(value: f32) LayoutError!void {
    if (!std.math.isFinite(value)) return error.InvalidNumber;
    if (value < 0 or value > 1) return error.PercentOutOfRange;
}

fn validateNonNegativeFinite(value: f32) LayoutError!void {
    if (!std.math.isFinite(value)) return error.InvalidNumber;
    if (value < 0) return error.NegativeValue;
}

fn validateEdges(edges: UiEdges) LayoutError!void {
    try validateNonNegativeFinite(edges.top);
    try validateNonNegativeFinite(edges.right);
    try validateNonNegativeFinite(edges.bottom);
    try validateNonNegativeFinite(edges.left);
    // 각 edge가 유한해도 합은 f32에서 overflow할 수 있다. content rect와 measure가
    // 서로 다른 방식으로 infinity를 삼키지 않도록 edge 경계에서 먼저 막는다.
    try validateNonNegativeFinite(edges.horizontal());
    try validateNonNegativeFinite(edges.vertical());
}

fn validateSize(size: UiSize) LayoutError!void {
    try validateNonNegativeFinite(size.width);
    try validateNonNegativeFinite(size.height);
}

fn validateMinMax(minimum: ?f32, maximum: ?f32) LayoutError!void {
    if (minimum) |value| try validateNonNegativeFinite(value);
    if (maximum) |value| try validateNonNegativeFinite(value);
    if (minimum != null and maximum != null and minimum.? > maximum.?) return error.MinGreaterThanMax;
}

fn measure(item: Item, content_rect: UiRect) LayoutError!UiSize {
    const known_width = if (knownLength(item.style.width, content_rect.width)) |value|
        nonNegativeDifference(value, item.style.padding.horizontal())
    else
        null;
    const known_height = if (knownLength(item.style.height, content_rect.height)) |value|
        nonNegativeDifference(value, item.style.padding.vertical())
    else
        null;
    const raw: UiSize = if (item.measure) |callback|
        callback(item.measure_context, .{
            .known_width = known_width,
            .known_height = known_height,
            .available_width = nonNegativeDifference(nonNegativeDifference(content_rect.width, item.style.margin.horizontal()), item.style.padding.horizontal()),
            .available_height = nonNegativeDifference(nonNegativeDifference(content_rect.height, item.style.margin.vertical()), item.style.padding.vertical()),
        })
    else
        .{};
    validateSize(raw) catch return error.InvalidMeasuredSize;
    // Callback은 content를 측정한다. Padding은 one-source로 이 레이어에서만 더해
    // component별로 text rect와 pointer rect가 달라지는 것을 피한다.
    return .{
        .width = try finiteSum(raw.width, item.style.padding.horizontal()),
        .height = try finiteSum(raw.height, item.style.padding.vertical()),
    };
}

fn knownLength(length: UiLength, parent_axis: f32) ?f32 {
    return switch (length) {
        .px => |value| value,
        .percent => |ratio| parent_axis * ratio,
        .auto, .fill => null,
    };
}

fn resolveBasis(length: UiLength, parent_axis: f32, measured: f32) LayoutError!f32 {
    return resolveLength(length, parent_axis, measured);
}

fn resolveLengthOrFillBase(length: UiLength, parent_axis: f32, measured: f32) LayoutError!f32 {
    return switch (length) {
        .fill => 0,
        else => try resolveLength(length, parent_axis, measured),
    };
}

fn effectiveGrow(length: UiLength, explicit: f32) f32 {
    return switch (length) {
        .fill => |weight| weight,
        else => explicit,
    };
}

/// min/max에 닿은 child만 freeze하고 남은 free space를 재분배한다. 매 pass에서 한 개
/// 이상 freeze되므로 items.len번 안에 끝나고, scratch 외 allocation이 없다.
fn distributeFlex(main_available_without_gaps: f32, scratch: []FlexScratch) LayoutError!void {
    var pass: usize = 0;
    while (pass < scratch.len) : (pass += 1) {
        const free = main_available_without_gaps - try occupiedMain(scratch);
        if (free == 0) return;

        var total_weight: f32 = 0;
        for (scratch) |entry| {
            if (entry.frozen) continue;
            total_weight = try finiteSum(total_weight, if (free > 0) entry.grow else try finiteProduct(entry.target_main, entry.shrink));
        }
        if (total_weight <= 0) return;

        var froze_any = false;
        for (scratch) |*entry| {
            if (entry.frozen) continue;
            const weight = if (free > 0) entry.grow else try finiteProduct(entry.target_main, entry.shrink);
            if (weight == 0) continue;
            const proposed = try finiteSum(entry.target_main, try finiteProduct(free, weight / total_weight));
            const constrained = clamp(proposed, entry.min_main, entry.max_main);
            if (constrained != proposed) {
                entry.target_main = constrained;
                entry.frozen = true;
                froze_any = true;
            }
        }
        if (!froze_any) {
            for (scratch) |*entry| {
                if (entry.frozen) continue;
                const weight = if (free > 0) entry.grow else try finiteProduct(entry.target_main, entry.shrink);
                if (weight != 0) entry.target_main = try finiteSum(entry.target_main, try finiteProduct(free, weight / total_weight));
            }
            return;
        }
    }
}

fn occupiedMain(scratch: []const FlexScratch) LayoutError!f32 {
    var total: f32 = 0;
    for (scratch) |entry| {
        total = try finiteSum(total, entry.margin_main_before);
        total = try finiteSum(total, entry.target_main);
        total = try finiteSum(total, entry.margin_main_after);
    }
    return total;
}

fn placeItems(container: FlexContainer, content_rect: UiRect, scratch: []const FlexScratch, out: []UiRect) LayoutError!void {
    const main_available = mainSize(content_rect, container.direction);
    const cross_available = crossSize(content_rect, container.direction);
    const occupied = try finiteSum(try occupiedMain(scratch), try finiteProduct(container.style.gap, @as(f32, @floatFromInt(scratch.len - 1))));
    const remaining = @max(0, main_available - occupied);
    const main_offset: f32 = switch (container.justify) {
        .start, .space_between => 0,
        .center => remaining / 2,
        .end => remaining,
    };
    const extra_gap: f32 = if (container.justify == .space_between and scratch.len > 1)
        remaining / @as(f32, @floatFromInt(scratch.len - 1))
    else
        0;

    var cursor = try finiteSum(mainOrigin(content_rect, container.direction), main_offset);
    for (scratch, out) |entry, *rect| {
        cursor = try finiteSum(cursor, entry.margin_main_before);
        const alignment = entry.align_self orelse container.align_items;
        const cross_room = nonNegativeDifference(cross_available, entry.margin_cross_before + entry.margin_cross_after);
        const cross_size = if (entry.cross_auto and alignment == .stretch)
            clamp(cross_room, entry.min_cross, entry.max_cross)
        else
            entry.base_cross;
        const cross_remaining = @max(0, cross_room - cross_size);
        const cross_offset: f32 = switch (alignment) {
            .start, .stretch => 0,
            .center => cross_remaining / 2,
            .end => cross_remaining,
        };
        const main_pos = cursor;
        const cross_pos = try finiteSum(try finiteSum(crossOrigin(content_rect, container.direction), entry.margin_cross_before), cross_offset);
        rect.* = rectForAxes(container.direction, main_pos, cross_pos, entry.target_main, cross_size);
        cursor = try finiteSum(cursor, entry.target_main);
        cursor = try finiteSum(cursor, entry.margin_main_after);
        cursor = try finiteSum(cursor, container.style.gap);
        cursor = try finiteSum(cursor, extra_gap);
    }
}

fn clamp(value: f32, minimum: ?f32, maximum: ?f32) f32 {
    var result = value;
    if (minimum) |bound| result = @max(result, bound);
    if (maximum) |bound| result = @min(result, bound);
    return result;
}

/// Length가 음수가 될 수 없으므로 explicit min이 없어도 shrink의 하한은 0이다.
/// 이 값을 `null`로 흘리면 tiny container에서 음수 rect가 생겨 draw/hit이 갈라진다.
fn minimumOrZero(minimum: ?f32) ?f32 {
    return minimum orelse 0;
}

fn nonNegativeDifference(total: f32, subtrahend: f32) f32 {
    return @max(0, total - subtrahend);
}

fn finiteSum(left: f32, right: f32) LayoutError!f32 {
    const result = left + right;
    if (!std.math.isFinite(result)) return error.InvalidNumber;
    return result;
}

fn finiteProduct(left: f32, right: f32) LayoutError!f32 {
    const result = left * right;
    if (!std.math.isFinite(result)) return error.InvalidNumber;
    return result;
}

fn validateRect(rect: UiRect) LayoutError!void {
    try validateNonNegativeFinite(rect.width);
    try validateNonNegativeFinite(rect.height);
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y)) return error.InvalidNumber;
}

fn mainLength(style: UiStyle, direction: Direction) UiLength {
    return switch (direction) {
        .row => style.width,
        .column => style.height,
    };
}

fn crossLength(style: UiStyle, direction: Direction) UiLength {
    return switch (direction) {
        .row => style.height,
        .column => style.width,
    };
}

fn mainMin(style: UiStyle, direction: Direction) ?f32 {
    return switch (direction) {
        .row => style.min_width,
        .column => style.min_height,
    };
}

fn mainMax(style: UiStyle, direction: Direction) ?f32 {
    return switch (direction) {
        .row => style.max_width,
        .column => style.max_height,
    };
}

fn crossMin(style: UiStyle, direction: Direction) ?f32 {
    return switch (direction) {
        .row => style.min_height,
        .column => style.min_width,
    };
}

fn crossMax(style: UiStyle, direction: Direction) ?f32 {
    return switch (direction) {
        .row => style.max_height,
        .column => style.max_width,
    };
}

fn mainMarginBefore(edges: UiEdges, direction: Direction) f32 {
    return switch (direction) {
        .row => edges.left,
        .column => edges.top,
    };
}

fn mainMarginAfter(edges: UiEdges, direction: Direction) f32 {
    return switch (direction) {
        .row => edges.right,
        .column => edges.bottom,
    };
}

fn crossMarginBefore(edges: UiEdges, direction: Direction) f32 {
    return switch (direction) {
        .row => edges.top,
        .column => edges.left,
    };
}

fn crossMarginAfter(edges: UiEdges, direction: Direction) f32 {
    return switch (direction) {
        .row => edges.bottom,
        .column => edges.right,
    };
}

fn mainSize(rect: UiRect, direction: Direction) f32 {
    return switch (direction) {
        .row => rect.width,
        .column => rect.height,
    };
}

fn crossSize(rect: UiRect, direction: Direction) f32 {
    return switch (direction) {
        .row => rect.height,
        .column => rect.width,
    };
}

fn mainOf(size: UiSize, direction: Direction) f32 {
    return switch (direction) {
        .row => size.width,
        .column => size.height,
    };
}

fn crossOf(size: UiSize, direction: Direction) f32 {
    return switch (direction) {
        .row => size.height,
        .column => size.width,
    };
}

fn mainOrigin(rect: UiRect, direction: Direction) f32 {
    return switch (direction) {
        .row => rect.x,
        .column => rect.y,
    };
}

fn crossOrigin(rect: UiRect, direction: Direction) f32 {
    return switch (direction) {
        .row => rect.y,
        .column => rect.x,
    };
}

fn rectForAxes(direction: Direction, main_x: f32, cross_y: f32, main_size: f32, cross_size: f32) UiRect {
    return switch (direction) {
        .row => .{ .x = main_x, .y = cross_y, .width = main_size, .height = cross_size },
        .column => .{ .x = cross_y, .y = main_x, .width = cross_size, .height = main_size },
    };
}

fn isAuto(length: UiLength) bool {
    return length == .auto;
}

fn isFill(length: UiLength) bool {
    return length == .fill;
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

test "UiLength: px/percent/auto는 definite parent에서 resolve하고 indefinite percent는 fail-close한다" {
    try std.testing.expectEqual(@as(f32, 24), try resolveLength(.{ .px = 24 }, 100, 1));
    try std.testing.expectEqual(@as(f32, 25), try resolveLength(.{ .percent = 0.25 }, 100, 1));
    try std.testing.expectEqual(@as(f32, 7), try resolveLength(.auto, null, 7));
    try std.testing.expectError(error.IndefinitePercent, resolveLength(.{ .percent = 0.5 }, null, 0));
    try std.testing.expectError(error.FillRequiresFlex, resolveLength(.{ .fill = 1 }, 100, 0));
}

test "layoutFlex: row의 px percent auto fill과 padding margin gap을 하나의 rect source로 계산한다" {
    const FixedProbe = struct {
        fn measure(_: ?*const anyopaque, constraint: MeasureConstraint) UiSize {
            std.debug.assert(constraint.known_width.? == 15); // border box 20 - padding 5
            return .{ .height = 10 };
        }
    };
    const Probe = struct {
        fn measure(_: ?*const anyopaque, constraint: MeasureConstraint) UiSize {
            std.debug.assert(constraint.known_width == null);
            std.debug.assert(constraint.available_width.? == 85); // parent 90 - own padding 5
            return .{ .width = 20, .height = 10 };
        }
    };
    const items = [_]Item{
        .{ .style = .{ .width = .{ .px = 20 }, .height = .auto, .padding = .{ .left = 2, .right = 3 } }, .measure = FixedProbe.measure },
        .{ .style = .{ .width = .{ .percent = 0.25 }, .height = .auto } },
        .{ .style = .{ .width = .auto, .height = .auto, .padding = .{ .left = 2, .right = 3 } }, .measure = Probe.measure },
        .{ .style = .{ .width = .{ .fill = 1 }, .height = .auto, .margin = .{ .left = 2 } } },
    };
    var scratch: [items.len]FlexScratch = undefined;
    var out: [items.len]UiRect = undefined;
    const result = try layoutFlex(.{
        .size = .{ .width = 100, .height = 40 },
        .style = .{ .padding = .{ .left = 5, .right = 5 }, .gap = 2 },
    }, &items, &scratch, &out);

    try std.testing.expectEqual(UiRect{ .x = 5, .y = 0, .width = 90, .height = 40 }, result.content_rect);
    try std.testing.expectEqual(@as(f32, 5), out[0].x);
    try std.testing.expectEqual(@as(f32, 20), out[0].width);
    try std.testing.expectEqual(@as(f32, 27), out[1].x);
    try std.testing.expectEqual(@as(f32, 22.5), out[1].width);
    try std.testing.expectEqual(@as(f32, 51.5), out[2].x);
    try std.testing.expectEqual(@as(f32, 25), out[2].width); // text 20 + horizontal padding 5
    try std.testing.expectEqual(@as(f32, 80.5), out[3].x); // item margin은 flex 사용 공간 뒤에 적용
    try std.testing.expectEqual(@as(f32, 14.5), out[3].width);
    try std.testing.expectEqual(@as(f32, 40), out[0].height); // auto cross axis + stretch
}

test "layoutFlex: column, align/justify, overflow clip은 같은 backing-pixel rect를 낸다" {
    const items = [_]Item{
        .{ .style = .{ .width = .{ .px = 20 }, .height = .{ .px = 10 } } },
        .{ .style = .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .align_self = .end } },
    };
    var scratch: [items.len]FlexScratch = undefined;
    var out: [items.len]UiRect = undefined;
    const result = try layoutFlex(.{
        .size = .{ .width = 50, .height = 50 },
        .style = .{ .padding = .{ .top = 5, .bottom = 5 }, .gap = 2 },
        .direction = .column,
        .justify = .center,
        .align_items = .center,
        .overflow = .clip,
    }, &items, &scratch, &out);

    try std.testing.expectEqual(UiRect{ .x = 0, .y = 5, .width = 50, .height = 40 }, result.clip_rect.?);
    try std.testing.expectEqual(UiRect{ .x = 15, .y = 14, .width = 20, .height = 10 }, out[0]);
    try std.testing.expectEqual(UiRect{ .x = 40, .y = 26, .width = 10, .height = 10 }, out[1]);
}

test "layoutFlex: min/max에 닿은 grow item을 freeze하고 남은 free space를 재분배한다" {
    const items = [_]Item{
        .{ .style = .{ .width = .{ .fill = 1 }, .height = .auto, .max_width = 20 } },
        .{ .style = .{ .width = .{ .fill = 1 }, .height = .auto } },
    };
    var scratch: [items.len]FlexScratch = undefined;
    var out: [items.len]UiRect = undefined;
    _ = try layoutFlex(.{ .size = .{ .width = 100, .height = 20 } }, &items, &scratch, &out);
    try std.testing.expectEqual(@as(f32, 20), out[0].width);
    try std.testing.expectEqual(@as(f32, 80), out[1].width);
}

test "layoutFlex: fill weight는 basis를 유지한 뒤 남은 공간만 grow로 나눈다" {
    const items = [_]Item{
        .{ .style = .{ .width = .{ .fill = 1 }, .height = .auto, .flex = .{ .basis = .{ .px = 20 } } } },
        .{ .style = .{ .width = .{ .fill = 1 }, .height = .auto } },
    };
    var scratch: [items.len]FlexScratch = undefined;
    var out: [items.len]UiRect = undefined;
    _ = try layoutFlex(.{ .size = .{ .width = 100, .height = 20 } }, &items, &scratch, &out);
    try std.testing.expectEqual(@as(f32, 60), out[0].width); // basis 20 + 남은 80의 절반
    try std.testing.expectEqual(@as(f32, 40), out[1].width);

    const invalid_basis = [_]Item{.{ .style = .{ .flex = .{ .basis = .{ .fill = 1 } } } }};
    var invalid_scratch: [invalid_basis.len]FlexScratch = undefined;
    var invalid_out: [invalid_basis.len]UiRect = undefined;
    try std.testing.expectError(error.FillInBasis, layoutFlex(.{ .size = .{ .width = 20, .height = 20 } }, &invalid_basis, &invalid_scratch, &invalid_out));
}

test "layoutFlex: shrink도 min에 닿은 item을 freeze하고 tiny content에서 NaN rect를 만들지 않는다" {
    const items = [_]Item{
        .{ .style = .{ .width = .{ .px = 80 }, .height = .auto, .min_width = 70 } },
        .{ .style = .{ .width = .{ .px = 80 }, .height = .auto } },
    };
    var scratch: [items.len]FlexScratch = undefined;
    var out: [items.len]UiRect = undefined;
    _ = try layoutFlex(.{ .size = .{ .width = 100, .height = 1 } }, &items, &scratch, &out);
    try std.testing.expectEqual(@as(f32, 70), out[0].width);
    try std.testing.expectEqual(@as(f32, 30), out[1].width);

    _ = try layoutFlex(.{
        .size = .{},
        .style = .{ .padding = .{ .left = 9, .right = 9, .top = 9, .bottom = 9 } },
    }, &items, &scratch, &out);
    for (out) |rect| {
        try std.testing.expect(std.math.isFinite(rect.x));
        try std.testing.expect(std.math.isFinite(rect.y));
        try std.testing.expect(std.math.isFinite(rect.width));
        try std.testing.expect(std.math.isFinite(rect.height));
    }
}

test "layoutFlex: invalid number, invalid fill, cross-axis fill, mismatch는 빈 rect로 fail-close한다" {
    const bad_percent = [_]Item{.{ .style = .{ .width = .{ .percent = 2 } } }};
    var scratch: [1]FlexScratch = undefined;
    var out = [_]UiRect{.{ .x = 99, .width = 99 }};
    try std.testing.expectError(error.PercentOutOfRange, layoutFlex(.{ .size = .{ .width = 20, .height = 20 } }, &bad_percent, &scratch, &out));
    try std.testing.expectEqual(UiRect{}, out[0]);

    const cross_fill = [_]Item{.{ .style = .{ .width = .{ .px = 1 }, .height = .{ .fill = 1 } } }};
    try std.testing.expectError(error.FillOnCrossAxis, layoutFlex(.{ .size = .{ .width = 20, .height = 20 } }, &cross_fill, &scratch, &out));
    const duplicate_grow = [_]Item{.{ .style = .{ .width = .{ .fill = 1 }, .flex = .{ .grow = 1 } } }};
    try std.testing.expectError(error.FillAndGrow, layoutFlex(.{ .size = .{ .width = 20, .height = 20 } }, &duplicate_grow, &scratch, &out));
    try std.testing.expectError(error.InvalidNumber, resolveLength(.{ .px = std.math.nan(f32) }, 1, 0));
    try std.testing.expectError(error.ItemCountMismatch, layoutFlex(.{ .size = .{ .width = 20, .height = 20 } }, &bad_percent, &.{}, &out));

    const BadMeasure = struct {
        fn measure(_: ?*const anyopaque, _: MeasureConstraint) UiSize {
            return .{ .width = std.math.inf(f32) };
        }
    };
    const bad_measure = [_]Item{.{ .measure = BadMeasure.measure }};
    try std.testing.expectError(error.InvalidMeasuredSize, layoutFlex(.{ .size = .{ .width = 20, .height = 20 } }, &bad_measure, &scratch, &out));

    const three_items = [_]Item{ .{}, .{}, .{} };
    var three_scratch: [three_items.len]FlexScratch = undefined;
    var three_out = [_]UiRect{ .{ .width = 1 }, .{ .width = 1 }, .{ .width = 1 } };
    try std.testing.expectError(error.InvalidNumber, layoutFlex(.{
        .size = .{ .width = 20, .height = 20 },
        .style = .{ .gap = std.math.floatMax(f32) },
    }, &three_items, &three_scratch, &three_out));
    for (three_out) |rect| try std.testing.expectEqual(UiRect{}, rect);
}
