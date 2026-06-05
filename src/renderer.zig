pub const draw_list = @import("renderer/draw_list.zig");
pub const types = @import("renderer/types.zig");

pub const Backend = types.Backend;
pub const DrawCell = draw_list.DrawCell;
pub const DrawList = draw_list.DrawList;
pub const RenderFrame = types.RenderFrame;
pub const buildDrawList = draw_list.buildDrawList;
pub const initialBackendForMacOS = types.initialBackendForMacOS;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in renderer/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
