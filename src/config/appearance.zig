const std = @import("std");
const terminal = @import("../terminal.zig");
const theme = @import("theme.zig");

pub const ResolveError = error{
    EmptyFontFamily,
    InvalidFontSize,
    InvalidHexColorFormat,
    InvalidHexColorDigit,
};

pub const ResolvedFontRequest = struct {
    family: []const u8,
    size: f32,
};

pub const ResolvedTheme = struct {
    background: terminal.Rgb,
    foreground: terminal.Rgb,
    cursor: terminal.Rgb,
    selection: terminal.Rgb,
};

pub const ResolvedCursor = struct {
    shape: theme.CursorShape,
    blink: bool,
};

pub const ResolvedAppearance = struct {
    font: ResolvedFontRequest,
    theme: ResolvedTheme,
    cursor: ResolvedCursor,
};

pub fn resolve(config: theme.Config) ResolveError!ResolvedAppearance {
    // raw Config는 사용자가 적은 문자열을 그대로 들고 있다. renderer/backend가 그 값을
    // 매번 해석하면 실패 원인이 frame loop 안으로 숨어버리므로, 앱 시작 또는 설정 reload
    // 시점에 한 번 검증된 ResolvedAppearance로 바꾼다.
    return .{
        .font = try resolveFont(config.font),
        .theme = try resolveTheme(config.theme),
        .cursor = .{
            .shape = config.cursor.shape,
            .blink = config.cursor.blink,
        },
    };
}

pub fn resolveFont(config: theme.FontConfig) ResolveError!ResolvedFontRequest {
    const family = std.mem.trim(u8, config.family, " \t\r\n");
    if (family.len == 0) return error.EmptyFontFamily;
    if (!(config.size >= 1.0 and config.size <= 512.0)) return error.InvalidFontSize;

    return .{
        // 이 slice는 raw config 문자열을 빌린다. 아직 config 파일 parser가 없으므로
        // 별도 allocator를 들이지 않고, 소유권을 늘려야 하는 시점은 설정 reload 구현 때로 둔다.
        .family = family,
        .size = config.size,
    };
}

pub fn resolveTheme(config: theme.ThemeConfig) ResolveError!ResolvedTheme {
    return .{
        .background = try parseHexColor(config.background),
        .foreground = try parseHexColor(config.foreground),
        .cursor = try parseHexColor(config.cursor),
        .selection = try parseHexColor(config.selection),
    };
}

pub fn parseHexColor(value: []const u8) ResolveError!terminal.Rgb {
    // v1 설정은 일부러 #RRGGBB만 허용한다. CSS 색 이름이나 짧은 #RGB까지 받으면
    // 사용자는 편하지만, 어느 단계에서 어떤 형식으로 normalize됐는지 추적하기 어렵다.
    if (value.len != 7 or value[0] != '#') return error.InvalidHexColorFormat;
    return .{
        .r = try parseHexByte(value[1..3]),
        .g = try parseHexByte(value[3..5]),
        .b = try parseHexByte(value[5..7]),
    };
}

fn parseHexByte(two: []const u8) ResolveError!u8 {
    std.debug.assert(two.len == 2);
    const high = try hexNibble(two[0]);
    const low = try hexNibble(two[1]);
    return (high << 4) | low;
}

fn hexNibble(byte: u8) ResolveError!u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidHexColorDigit,
    };
}

test "default appearance resolves to renderer-friendly values" {
    // 기본 설정이 통과해야 앱이 설정 파일 없이도 화면을 띄울 수 있다. 이 테스트는
    // font/theme/cursor 기본값이 renderer가 바로 소비할 값으로 normalize되는지 고정한다.
    const resolved = try resolve(.{});

    try std.testing.expectEqualStrings("JetBrains Mono", resolved.font.family);
    try std.testing.expectEqual(@as(f32, 14), resolved.font.size);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0x10, .g = 0x10, .b = 0x10 }, resolved.theme.background);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xe8, .g = 0xe8, .b = 0xe8 }, resolved.theme.foreground);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xff, .g = 0xff, .b = 0xff }, resolved.theme.cursor);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0x33, .g = 0x44, .b = 0x55 }, resolved.theme.selection);
    try std.testing.expectEqual(theme.CursorShape.block, resolved.cursor.shape);
    try std.testing.expect(resolved.cursor.blink);
}

test "appearance resolver trims font family and preserves cursor options" {
    const resolved = try resolve(.{
        .font = .{ .family = "  Menlo  ", .size = 16 },
        .theme = .{
            .background = "#000000",
            .foreground = "#FFFFFF",
            .cursor = "#ff00AA",
            .selection = "#123456",
        },
        .cursor = .{ .shape = .bar, .blink = false },
    });

    try std.testing.expectEqualStrings("Menlo", resolved.font.family);
    try std.testing.expectEqual(@as(f32, 16), resolved.font.size);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xff, .g = 0xff, .b = 0xff }, resolved.theme.foreground);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xff, .g = 0x00, .b = 0xaa }, resolved.theme.cursor);
    try std.testing.expectEqual(theme.CursorShape.bar, resolved.cursor.shape);
    try std.testing.expect(!resolved.cursor.blink);
}

test "appearance resolver rejects invalid font values" {
    try std.testing.expectError(error.EmptyFontFamily, resolve(.{ .font = .{ .family = " \t\n", .size = 14 } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = 0 } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = -1 } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = 600 } }));
}

test "hex color parser accepts only full rgb hex colors" {
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xab, .g = 0xcd, .b = 0xef }, try parseHexColor("#ABCdef"));
    try std.testing.expectError(error.InvalidHexColorFormat, parseHexColor("101010"));
    try std.testing.expectError(error.InvalidHexColorFormat, parseHexColor("#fff"));
    try std.testing.expectError(error.InvalidHexColorDigit, parseHexColor("#12GG00"));
}
