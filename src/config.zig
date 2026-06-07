pub const action = @import("config/action.zig");
pub const appearance = @import("config/appearance.zig");
pub const keybinding = @import("config/keybinding.zig");
pub const theme = @import("config/theme.zig");

pub const Action = action.Action;
pub const Config = theme.Config;
pub const CursorConfig = theme.CursorConfig;
pub const CursorShape = theme.CursorShape;
pub const FontConfig = theme.FontConfig;
pub const ResolveError = appearance.ResolveError;
pub const ResolvedAppearance = appearance.ResolvedAppearance;
pub const ResolvedCursor = appearance.ResolvedCursor;
pub const ResolvedFontRequest = appearance.ResolvedFontRequest;
pub const ResolvedTheme = appearance.ResolvedTheme;
pub const ThemeConfig = theme.ThemeConfig;
pub const AppBinding = keybinding.AppBinding;
pub const KeyBindingError = keybinding.KeyBindingError;
pub const KeyBindingResolver = keybinding.KeyBindingResolver;
pub const KeyChord = keybinding.KeyChord;
pub const ResolvedKey = keybinding.ResolvedKey;
pub const TerminalBinding = keybinding.TerminalBinding;
pub const TerminalInputMacro = keybinding.TerminalInputMacro;
pub const parseAction = action.parseAction;
pub const parseHexColor = appearance.parseHexColor;
pub const resolveAppearance = appearance.resolve;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in config/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
