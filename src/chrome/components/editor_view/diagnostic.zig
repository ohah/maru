//! 진단 표시의 chrome 쪽 어휘(docs/native-editor-visual-mapping.md §5.4). **session 을 import 하지 않는다** — severity 는 platform 이
//! `session.editor.diagnostic.Severity` 에서 옮겨 담는다(`syntax_capture.Role` → `ColorRole` 과 같은 모양). 네 자리(밑줄·gutter·
//! 막대·미니맵)가 전부 이 하나에서 색과 글리프를 받는다 — 자리마다 표를 두면 한 severity 가 자리마다 다른 색이 된다.

const tokens = @import("../../tokens.zig");

/// 낮은 것부터 — 비교는 `@intFromEnum` 으로.
pub const Level = enum(u8) {
    hint = 0,
    info = 1,
    warning = 2,
    err = 3,

    pub fn role(self: Level) tokens.ColorRole {
        return switch (self) {
            .err => .diagnostic_error,
            .warning => .diagnostic_warning,
            .info => .diagnostic_info,
            .hint => .diagnostic_hint,
        };
    }

    /// gutter 한 셀에 서는 글리프(§5.4). `✖`·`⚠`·`ℹ` 는 폰트 폴백이 넓고 한 셀에 든다; hint 는 가운뎃점.
    pub fn glyph(self: Level) []const u8 {
        return switch (self) {
            .err => "✖",
            .warning => "⚠",
            .info => "ℹ",
            .hint => "·",
        };
    }

    pub fn atLeast(self: Level, other: Level) bool {
        return @intFromEnum(self) >= @intFromEnum(other);
    }
};

/// 한 줄의 밑줄 조각 — 줄 안 byte(`frame.Mark` 와 같은 축) + severity.
pub const Mark = struct { start: u32, len: u32, level: Level };

/// 막대·미니맵 마커 하나 — 줄(보이는 줄 축) + severity.
pub const LineMark = struct { line: u32, level: Level };

const std = @import("std");
test "DGL1 severity 마다 role·글리프가 하나씩이고 순서가 error > warning > info > hint (§5.4)" {
    try std.testing.expectEqual(tokens.ColorRole.diagnostic_error, Level.err.role());
    try std.testing.expectEqual(tokens.ColorRole.diagnostic_hint, Level.hint.role());
    try std.testing.expectEqualStrings("✖", Level.err.glyph());
    try std.testing.expectEqualStrings("⚠", Level.warning.glyph());
    try std.testing.expect(Level.err.atLeast(.warning) and !Level.info.atLeast(.warning));
}
