//! Chrome text hierarchy.  This is intentionally separate from terminal `font.*`: Chrome
//! components name a semantic role, while the platform text adapter later resolves the actual
//! system face, fallback chain, point size, and line metrics once per snapshot.

const std = @import("std");

pub const ChromeTextRole = enum(u4) {
    dock_heading,
    supporting,
    control,
    group_heading,
    card_heading,
    body,
    metadata,
    overline,
    button_label,
};

pub const Weight = enum { regular, medium, semibold };

/// Point-equivalent tokens.  The platform adapter converts this once with the backing scale;
/// components must never recreate a role with a raw size or baseline nudge.
pub const Token = struct {
    point_size: u8,
    line_height: u8,
    weight: Weight,
};

/// 사용자 보고(2026-08-05): 도크 텍스트가 같은 화면의 터미널 글자보다 눈에 띄게 컸다. Chrome **scale**은
/// terminal `font.size`/line spacing과 의도적으로 독립이지만(그 독립성이 계약이다 —
/// docs/agent-session-list-layout.md §2.1.1), 절대값 자체는 조정 가능한 결정이라 두 단계 낮춘다. 이 값은
/// `DockMetrics`가 카드/행 높이를 계산하는 입력이기도 해서 목록 밀도도 함께 조금 촘촘해진다.
///
/// **face는 그 독립성의 대상이 아니다.** 어느 폰트로 그릴지는 여기서 정하지 않고 platform adapter가
/// 사용자 `font.family`로 해석한다(위 헤더 주석의 역할 분담 그대로, docs/font-strategy.md "Chrome
/// 텍스트 face"). 그래서 이 표를 face 이유로 바꿀 일은 없다 — 여기 있는 것은 크기 위계뿐이다.
pub fn token(role: ChromeTextRole) Token {
    return switch (role) {
        .dock_heading => .{ .point_size = 16, .line_height = 22, .weight = .semibold },
        .supporting => .{ .point_size = 12, .line_height = 16, .weight = .regular },
        .control => .{ .point_size = 13, .line_height = 17, .weight = .medium },
        .group_heading => .{ .point_size = 14, .line_height = 18, .weight = .semibold },
        .card_heading => .{ .point_size = 14, .line_height = 20, .weight = .semibold },
        .body => .{ .point_size = 13, .line_height = 18, .weight = .regular },
        .metadata => .{ .point_size = 12, .line_height = 16, .weight = .regular },
        .overline => .{ .point_size = 11, .line_height = 15, .weight = .medium },
        .button_label => .{ .point_size = 13, .line_height = 17, .weight = .semibold },
    };
}

/// Line box height in backing pixels.  Scaling is explicit and saturating so a bad caller never
/// creates an infinite/zero line box that could publish an invalid Chrome tree.
pub fn lineHeightPx(role: ChromeTextRole, scale_milli: u32) u32 {
    const scaled = @as(u64, token(role).line_height) * @as(u64, scale_milli);
    return @intCast(@min((scaled + 999) / 1000, std.math.maxInt(u32)));
}

test "every Chrome text role has a positive fixed token" {
    inline for (@typeInfo(ChromeTextRole).@"enum".fields) |field| {
        const role: ChromeTextRole = @enumFromInt(field.value);
        const value = token(role);
        try std.testing.expect(value.point_size > 0);
        try std.testing.expect(value.line_height >= value.point_size);
    }
}

test "line height converts point-equivalent token once at backing scale" {
    try std.testing.expectEqual(@as(u32, 22), lineHeightPx(.dock_heading, 1000));
    try std.testing.expectEqual(@as(u32, 44), lineHeightPx(.dock_heading, 2000));
    try std.testing.expectEqual(@as(u32, 24), lineHeightPx(.metadata, 1500));
}
