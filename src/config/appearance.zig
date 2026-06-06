const std = @import("std");
const color = @import("../color.zig");
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
    background: color.Rgb,
    foreground: color.Rgb,
    cursor: color.Rgb,
    selection: color.Rgb,
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

fn resolveFont(config: theme.FontConfig) ResolveError!ResolvedFontRequest {
    // space/tab/CR/LF만이 아니라 vertical tab(0x0b)/form feed(0x0c)를 포함한 ASCII 공백
    // 전체를 trim한다. 일부만 깎으면 그런 공백만으로 된 family가 len 검사를 통과해 빈
    // 폰트명이 renderer로 샌다.
    const family = std.mem.trim(u8, config.family, &std.ascii.whitespace);
    if (family.len == 0) return error.EmptyFontFamily;
    if (!(config.size >= 1.0 and config.size <= 512.0)) return error.InvalidFontSize;

    return .{
        // 이 slice는 raw config 문자열을 빌린다. 아직 config 파일 parser가 없으므로
        // 별도 allocator를 들이지 않고, 소유권을 늘려야 하는 시점은 설정 reload 구현 때로 둔다.
        .family = family,
        .size = config.size,
    };
}

fn resolveTheme(config: theme.ThemeConfig) ResolveError!ResolvedTheme {
    return .{
        .background = try parseHexColor(config.background),
        .foreground = try parseHexColor(config.foreground),
        .cursor = try parseHexColor(config.cursor),
        .selection = try parseHexColor(config.selection),
    };
}

pub fn parseHexColor(value: []const u8) ResolveError!color.Rgb {
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
    try std.testing.expectEqual(color.Rgb{ .r = 0x10, .g = 0x10, .b = 0x10 }, resolved.theme.background);
    try std.testing.expectEqual(color.Rgb{ .r = 0xe8, .g = 0xe8, .b = 0xe8 }, resolved.theme.foreground);
    try std.testing.expectEqual(color.Rgb{ .r = 0xff, .g = 0xff, .b = 0xff }, resolved.theme.cursor);
    try std.testing.expectEqual(color.Rgb{ .r = 0x33, .g = 0x44, .b = 0x55 }, resolved.theme.selection);
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
    try std.testing.expectEqual(color.Rgb{ .r = 0xff, .g = 0xff, .b = 0xff }, resolved.theme.foreground);
    try std.testing.expectEqual(color.Rgb{ .r = 0xff, .g = 0x00, .b = 0xaa }, resolved.theme.cursor);
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
    try std.testing.expectEqual(color.Rgb{ .r = 0xab, .g = 0xcd, .b = 0xef }, try parseHexColor("#ABCdef"));
    try std.testing.expectError(error.InvalidHexColorFormat, parseHexColor("101010"));
    try std.testing.expectError(error.InvalidHexColorFormat, parseHexColor("#fff"));
    try std.testing.expectError(error.InvalidHexColorFormat, parseHexColor("1234567")); // 7자이지만 '#'가 없음
    try std.testing.expectError(error.InvalidHexColorDigit, parseHexColor("#12GG00"));
    try std.testing.expectError(error.InvalidHexColorDigit, parseHexColor("#12#456")); // 중간 '#'는 hex digit이 아님
}

test "appearance resolver trims all ascii whitespace from font family" {
    // space/tab/CR/LF만이 아니라 vertical tab(0x0b)/form feed(0x0c)까지 trim해야,
    // 그런 공백만으로 이뤄진 family가 빈 폰트명으로 새지 않는다.
    const resolved = try resolve(.{ .font = .{ .family = "\x0b\x0c Menlo \x0c\x0b", .size = 14 } });
    try std.testing.expectEqualStrings("Menlo", resolved.font.family);
    try std.testing.expectError(error.EmptyFontFamily, resolve(.{ .font = .{ .family = "\x0b\x0c", .size = 14 } }));
}

test "appearance resolver font size accepts inclusive bounds and rejects non-finite" {
    // 가드는 의도적으로 !(size>=1 and size<=512) 형태다. naive한 (size<1 or size>512)로
    // 바꾸면 NaN이 통과하므로, 경계값과 NaN/inf를 함께 고정한다.
    try std.testing.expectEqual(@as(f32, 1), (try resolve(.{ .font = .{ .family = "Menlo", .size = 1.0 } })).font.size);
    try std.testing.expectEqual(@as(f32, 512), (try resolve(.{ .font = .{ .family = "Menlo", .size = 512.0 } })).font.size);
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = std.math.nan(f32) } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = std.math.inf(f32) } }));
    try std.testing.expectError(error.InvalidFontSize, resolve(.{ .font = .{ .family = "Menlo", .size = -std.math.inf(f32) } }));
}

test "appearance resolver rejects an invalid color in any theme field" {
    // resolveTheme이 background/foreground/cursor/selection 4개 필드를 각각 검증하는지
    // 고정한다. 한 필드라도 parseHexColor를 빠뜨리면 깨진 색이 renderer로 샌다.
    try std.testing.expectError(error.InvalidHexColorFormat, resolve(.{ .theme = .{ .background = "bad" } }));
    try std.testing.expectError(error.InvalidHexColorDigit, resolve(.{ .theme = .{ .foreground = "#0011ZZ" } }));
    try std.testing.expectError(error.InvalidHexColorFormat, resolve(.{ .theme = .{ .cursor = "#fff" } }));
    try std.testing.expectError(error.InvalidHexColorFormat, resolve(.{ .theme = .{ .selection = "123456" } }));
}

test "appearance resolver preserves the underline cursor shape" {
    // .block/.bar 외에 세 번째 shape도 frame까지 그대로 전달되는지 고정한다.
    const resolved = try resolve(.{ .cursor = .{ .shape = .underline, .blink = false } });
    try std.testing.expectEqual(theme.CursorShape.underline, resolved.cursor.shape);
    try std.testing.expect(!resolved.cursor.blink);
}
