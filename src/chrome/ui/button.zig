//! Generic Button builder — B1-generic-component.
//!
//! 지금까지 command 표면은 소비자가 각자 만들었다. Session Dock은 `tree.button`(자식 없는 leaf)에
//! label을 자기 view로 따로 그렸고, 그 label의 전경·크기·아이콘 배치를 컴포넌트가 알고 있었다.
//! 그러면 두 번째 소비자가 같은 결정을 다시 내리고, 값이 갈리는 순간 "보이는 것과 눌리는 것"이
//! 어긋난다.
//!
//! 이 모듈은 그 결정을 한 곳으로 모은다. 호출자는 의미(`variant`·`size`·`leading_icon`·label)만
//! 선언하고, 최소 hit target·아이콘 슬롯 치수·label 자리는 여기가 token에서 계산한다.
//!
//! **자식은 호출자 소유 버퍼의 슬라이스로 받는다.** 처음에는 단일 `UiNode` 값으로 받아 "정확히
//! 하나"를 타입으로 강제하려 했지만, 그러면 node가 사라진 스택 슬롯을 가리킨다 — 값으로 받은
//! 파라미터의 주소를 자식으로 실을 수 없다. 다른 builder들과 같이 호출자가 자기 버퍼에 label을
//! 두고 그 슬라이스를 넘긴다. "정확히 하나의 Text child"는 그래서 런타임 검증이며, zero/two/non-Text
//! 각각이 구분되는 오류를 낸다(docs/metal-ui-layout.md B1).
//!
//! **아이콘은 codepoint + 주입된 predicate다.** `chrome`은 경계 가드 때문에 `renderer`를 import할
//! 수 없어 등록 집합(`renderer.icon_glyph.isRegisteredIcon`)을 직접 볼 수 없다. `chrome/text_layout.zig`가
//! 이미 쓰는 predicate 주입 선례를 따른다. 닫힌 `IconId` enum을 새로 두지 않는 이유는 그것이 등록
//! 집합과 동기화해야 할 두 번째 목록이 되기 때문이다.

const std = @import("std");
const icons = @import("../../icons.zig"); // 등록 아이콘 이름↔codepoint(테스트 registry가 실제 등록 cp를 쓰게)
const layout = @import("layout.zig");
const spacing = @import("spacing.zig");
const tree = @import("tree.zig");
const typography = @import("typography.zig");
const ui_style = @import("style.zig");

pub const ButtonError = error{
    /// label이 `Text` node가 아니다. Button의 content rect·ellipsis·accessible label source가
    /// 한 tree에서 나와야 하므로 container/card/button을 label로 받지 않는다.
    InvalidButtonLabel,
    /// label이 없다. accessible name이 없는 command는 keyboard·VoiceOver 사용자에게 목적지가 없다.
    MissingButtonLabel,
    /// label이 둘 이상이다. 어느 것이 content rect와 accessible name을 소유하는지 갈리므로 막는다.
    MultipleButtonChildren,
    /// 등록되지 않은 아이콘 codepoint. 합성 게이트가 그리지 못하는 값을 published tree에 넣으면
    /// 슬롯만 차지한 빈 자리가 되므로 후보 단계에서 막는다.
    UnregisteredIcon,
    /// 호출자가 준 max가 size floor보다 작다. 작은 창에서 hit target을 조용히 압축하지 않는다.
    ButtonMaxBelowFloor,
};

/// 최소 hit target을 주는 닫힌 축. 값 자체가 아니라 "어느 밀도의 command인가"를 고른다.
pub const ButtonSize = enum {
    /// 기본 command. Session Dock의 action row가 이 밀도다.
    default,
    /// 밀집한 utility 자리(헤더 슬롯 등). floor는 여전히 pointer가 놓칠 수 없는 크기다.
    compact,

    /// logical point floor. backing pixel 환산은 `spacing.pointsPx`가 한 번만 한다.
    ///
    /// `session_dock.types.ButtonMetrics`는 자기 action row의 **완성 높이**(48pt)를 갖고, 이 값은
    /// 그것과 경쟁하지 않는 **하한**이다. 둘이 같은 사실의 두 출처가 되지 않도록: 소비자가 자기
    /// 높이를 알면 `style.min_height`로 넘기고 builder가 둘 중 큰 쪽을 쓴다.
    pub fn minHeightPt(self: ButtonSize) u16 {
        return switch (self) {
            .default => 32,
            .compact => 24,
        };
    }

    /// 아이콘 슬롯의 한 변. label line box와 같은 축에 놓이므로 role line-height와 함께 쓴다.
    fn iconExtentPt(self: ButtonSize) u16 {
        return switch (self) {
            .default => 18,
            .compact => 14,
        };
    }

    fn iconGap(self: ButtonSize) spacing.Space {
        return switch (self) {
            .default => .xs,
            .compact => .xxs,
        };
    }
};

/// 등록 아이콘 판정을 주입받는다. `chrome`은 `renderer`를 import할 수 없다.
pub const IconRegistry = struct {
    context: *const anyopaque,
    isRegistered: *const fn (context: *const anyopaque, codepoint: u21) bool,

    pub fn contains(self: IconRegistry, codepoint: u21) bool {
        return self.isRegistered(self.context, codepoint);
    }
};

pub const LeadingIcon = struct {
    codepoint: u21,
    registry: IconRegistry,
};

pub const ButtonProps = struct {
    id: tree.UiId,
    action: tree.UiAction,
    variant: ui_style.ButtonVariant = .secondary,
    size: ButtonSize = .default,
    paint: ui_style.PaintStyle = .{},
    style: layout.UiStyle = .{},
    overflow: layout.Overflow = .clip,
    leading_icon: ?LeadingIcon = null,
    /// backing scale × 소비자 zoom. label artifact·layout·hit-test가 같은 값을 받아야 하므로
    /// 호출자가 자기 snapshot의 값을 그대로 넘긴다.
    scale_milli: u32 = 1000,
};

/// 하나의 command를 선언한다. `children`은 `ui.text(...)`가 만든 `Text` node **정확히 하나**를 담은,
/// 호출자 소유 버퍼의 슬라이스여야 한다.
pub fn button(props: ButtonProps, children: []const tree.UiNode) ButtonError!tree.UiNode {
    if (children.len == 0) return error.MissingButtonLabel;
    if (children.len > 1) return error.MultipleButtonChildren;
    if (children[0].kind() != .text) return error.InvalidButtonLabel;

    var style = props.style;
    const floor_px: f32 = @floatFromInt(spacing.pointsPx(props.size.minHeightPt(), props.scale_milli));
    // 호출자의 min과 size floor를 하나로 합친다. 둘 다 있으면 더 큰 쪽이 이긴다 — floor는 pointer가
    // 놓칠 수 없는 크기이지 권장값이 아니다.
    style.min_height = if (style.min_height) |caller| @max(caller, floor_px) else floor_px;
    if (style.max_height) |max| {
        if (max < style.min_height.?) return error.ButtonMaxBelowFloor;
    }

    var icon: ?tree.LeadingIconProps = null;
    if (props.leading_icon) |declared| {
        if (!declared.registry.contains(declared.codepoint)) return error.UnregisteredIcon;
        const line_height = typography.lineHeightPx(.button_label, props.scale_milli);
        const extent = spacing.pointsPx(props.size.iconExtentPt(), props.scale_milli);
        icon = .{
            .codepoint = declared.codepoint,
            // 슬롯은 label line box를 넘지 않는다. 넘으면 아이콘이 baseline을 흔들어 label이
            // 아래로 밀린다 — B1이 없애려는 그 증상이다.
            .extent_px = @intCast(@min(extent, line_height)),
            .gap_px = @intCast(spacing.px(props.size.iconGap(), props.scale_milli)),
        };
    }

    return tree.buttonWithLabel(.{
        .id = props.id,
        .style = style,
        .variant = props.variant,
        .paint = props.paint,
        .action = props.action,
        .overflow = props.overflow,
        .leading_icon = icon,
    }, children);
}

test "label must be exactly one Text node" {
    const label = [_]tree.UiNode{tree.text(.{ .id = 2, .value = "이어하기" })};
    const ok = try button(.{ .id = 1, .action = .{ .id = 7 } }, &label);
    try std.testing.expectEqual(tree.NodeKind.button, ok.kind());
    try std.testing.expectEqual(@as(usize, 1), ok.children.len);
    try std.testing.expectEqual(tree.NodeKind.text, ok.children[0].kind());

    // 없거나 둘 이상이면 어느 것이 content rect와 accessible name을 소유하는지 갈린다.
    try std.testing.expectError(error.MissingButtonLabel, button(.{ .id = 1, .action = .{ .id = 7 } }, &.{}));
    const two = [_]tree.UiNode{
        tree.text(.{ .id = 2, .value = "가" }),
        tree.text(.{ .id = 3, .value = "나" }),
    };
    try std.testing.expectError(error.MultipleButtonChildren, button(.{ .id = 1, .action = .{ .id = 7 } }, &two));

    // card/container/button label은 content rect와 accessible label source를 갈라놓으므로 막는다.
    const card_label = [_]tree.UiNode{tree.card(.{ .id = 3, .variant = .surface }, &.{})};
    try std.testing.expectError(error.InvalidButtonLabel, button(.{ .id = 1, .action = .{ .id = 7 } }, &card_label));
}

test "each button keeps its own label after the builder returns" {
    // 회귀: 처음 구현은 값으로 받은 label의 주소를 자식으로 실어, 반환 즉시 사라진 스택 슬롯을
    // 가리켰다. 한 번만 만들어 바로 읽으면 우연히 통과하므로, **여러 개를 만든 뒤** 서로의 label이
    // 살아 있는지 본다.
    var labels: [3]tree.UiNode = .{
        tree.text(.{ .id = 10, .value = "하나" }),
        tree.text(.{ .id = 11, .value = "둘" }),
        tree.text(.{ .id = 12, .value = "셋" }),
    };
    var buttons: [3]tree.UiNode = undefined;
    for (&buttons, 0..) |*slot, index| {
        slot.* = try button(.{ .id = index + 1, .action = .{ .id = index + 100 } }, labels[index..][0..1]);
    }
    for (buttons, 0..) |node, index| {
        try std.testing.expectEqual(@as(usize, 1), node.children.len);
        try std.testing.expectEqual(labels[index].id, node.children[0].id);
        try std.testing.expectEqualStrings(labels[index].props.text.value, node.children[0].props.text.value);
    }
}

test "size floor raises the caller minimum and rejects a smaller max" {
    const label = [_]tree.UiNode{tree.text(.{ .id = 2, .value = "실행" })};

    // 호출자가 min을 생략하면 floor가 그대로 들어간다.
    const bare = try button(.{ .id = 1, .action = .{ .id = 7 }, .size = .default }, &label);
    try std.testing.expectEqual(@as(f32, 32), bare.style.min_height.?);

    // 호출자 min이 더 크면 그 값이 이긴다 — floor는 하한이지 고정값이 아니다.
    const taller = try button(.{
        .id = 1,
        .action = .{ .id = 7 },
        .style = .{ .min_height = 48 },
    }, &label);
    try std.testing.expectEqual(@as(f32, 48), taller.style.min_height.?);

    // compact도 floor를 가진다 — 밀집한 자리라고 hit target이 사라지지 않는다.
    const compact = try button(.{ .id = 1, .action = .{ .id = 7 }, .size = .compact }, &label);
    try std.testing.expectEqual(@as(f32, 24), compact.style.min_height.?);

    // max가 floor를 밑돌면 조용히 압축하지 않고 후보를 실패시킨다.
    try std.testing.expectError(error.ButtonMaxBelowFloor, button(.{
        .id = 1,
        .action = .{ .id = 7 },
        .style = .{ .max_height = 20 },
    }, &label));
}

const TestRegistry = struct {
    const registered: u21 = icons.codepoint(.refresh);

    fn isRegistered(_: *const anyopaque, codepoint: u21) bool {
        return codepoint == registered;
    }

    fn any() IconRegistry {
        return .{ .context = @ptrCast(&registered), .isRegistered = isRegistered };
    }
};

test "leading icon is registered, bounded by the label line box, and gapped from token space" {
    const label = [_]tree.UiNode{tree.text(.{ .id = 2, .value = "로그" })};

    const node = try button(.{
        .id = 1,
        .action = .{ .id = 7 },
        .leading_icon = .{ .codepoint = TestRegistry.registered, .registry = TestRegistry.any() },
    }, &label);
    const icon = node.props.button.leading_icon.?;
    try std.testing.expectEqual(TestRegistry.registered, icon.codepoint);
    // 슬롯은 label line box를 넘지 않는다.
    try std.testing.expect(icon.extent_px <= typography.lineHeightPx(.button_label, 1000));
    try std.testing.expect(icon.gap_px > 0);

    // 미등록 codepoint는 published tree에 들어가지 못한다 — 합성 게이트가 못 그리면 빈 슬롯이 된다.
    try std.testing.expectError(error.UnregisteredIcon, button(.{
        .id = 1,
        .action = .{ .id = 7 },
        .leading_icon = .{ .codepoint = 0xF00FF, .registry = TestRegistry.any() },
    }, &label));

    // 아이콘이 없으면 슬롯도 없다 — label만 있는 command가 빈 자리를 남기지 않는다.
    const plain = try button(.{ .id = 1, .action = .{ .id = 7 } }, &label);
    try std.testing.expect(plain.props.button.leading_icon == null);
}

test "scale carries into floor and icon slot exactly once" {
    const label = [_]tree.UiNode{tree.text(.{ .id = 2, .value = "확대" })};
    const zoomed = try button(.{
        .id = 1,
        .action = .{ .id = 7 },
        .scale_milli = 2000,
        .leading_icon = .{ .codepoint = TestRegistry.registered, .registry = TestRegistry.any() },
    }, &label);

    // floor와 슬롯이 같은 scale로 한 번만 환산된다. 소비자가 다시 곱하면 두 배가 된다.
    try std.testing.expectEqual(@as(f32, @floatFromInt(spacing.pointsPx(32, 2000))), zoomed.style.min_height.?);
    const icon = zoomed.props.button.leading_icon.?;
    try std.testing.expect(icon.extent_px <= typography.lineHeightPx(.button_label, 2000));
}
