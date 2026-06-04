pub const core = @import("terminal/core.zig");
pub const input = @import("terminal/input.zig");
pub const types = @import("terminal/types.zig");
pub const width = @import("terminal/width.zig");

pub const Cell = types.Cell;
pub const Color = types.Color;
pub const Cursor = types.Cursor;
pub const DirtyRegion = types.DirtyRegion;
pub const Key = input.Key;
pub const KeyEvent = input.KeyEvent;
pub const ModifierSet = input.ModifierSet;
pub const RenderSnapshot = types.RenderSnapshot;
pub const Rgb = types.Rgb;
pub const Size = types.Size;
pub const Style = types.Style;
pub const TerminalCore = core.TerminalCore;
pub const cellWidth = width.cellWidth;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in terminal/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
