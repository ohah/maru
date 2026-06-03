pub const registry = @import("plugin/registry.zig");

pub const Registry = registry.Registry;
pub const loadConfiguredPlugins = registry.loadConfiguredPlugins;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in plugin/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
