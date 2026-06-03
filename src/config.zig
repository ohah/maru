pub const action = @import("config/action.zig");
pub const theme = @import("config/theme.zig");

pub const Action = action.Action;
pub const Config = theme.Config;
pub const FontConfig = theme.FontConfig;
pub const ThemeConfig = theme.ThemeConfig;
pub const parseAction = action.parseAction;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in config/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
