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

pub fn token(role: ChromeTextRole) Token {
    return switch (role) {
        .dock_heading => .{ .point_size = 20, .line_height = 26, .weight = .semibold },
        .supporting => .{ .point_size = 15, .line_height = 20, .weight = .regular },
        .control => .{ .point_size = 16, .line_height = 20, .weight = .medium },
        .group_heading => .{ .point_size = 17, .line_height = 22, .weight = .semibold },
        .card_heading => .{ .point_size = 18, .line_height = 24, .weight = .semibold },
        .body => .{ .point_size = 16, .line_height = 22, .weight = .regular },
        .metadata => .{ .point_size = 15, .line_height = 20, .weight = .regular },
        .overline => .{ .point_size = 14, .line_height = 20, .weight = .medium },
        .button_label => .{ .point_size = 16, .line_height = 20, .weight = .semibold },
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
    try std.testing.expectEqual(@as(u32, 26), lineHeightPx(.dock_heading, 1000));
    try std.testing.expectEqual(@as(u32, 52), lineHeightPx(.dock_heading, 2000));
    try std.testing.expectEqual(@as(u32, 30), lineHeightPx(.metadata, 1500));
}
