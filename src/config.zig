pub const action = @import("config/action.zig");
pub const appearance = @import("config/appearance.zig");
pub const theme = @import("config/theme.zig");

pub const Action = action.Action;
pub const Config = theme.Config;
pub const CursorConfig = theme.CursorConfig;
pub const CursorShape = theme.CursorShape;
pub const FontConfig = theme.FontConfig;
pub const ResolvedAppearance = appearance.ResolvedAppearance;
pub const ResolvedCursor = appearance.ResolvedCursor;
pub const ResolvedFontRequest = appearance.ResolvedFontRequest;
pub const ResolvedTheme = appearance.ResolvedTheme;
pub const ResolveError = appearance.ResolveError;
pub const ThemeConfig = theme.ThemeConfig;
pub const parseHexColor = appearance.parseHexColor;
pub const parseAction = action.parseAction;
pub const resolveAppearance = appearance.resolve;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in config/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
