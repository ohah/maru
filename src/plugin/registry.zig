const std = @import("std");

pub const Registry = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        _ = self;
    }

    pub fn count(self: *const Registry) usize {
        _ = self;
        return 0;
    }
};

pub fn loadConfiguredPlugins(registry: *Registry) !void {
    // No plugins is a valid runtime state. The core app must boot without a
    // plugin directory, plugin config, or Wasm runtime so future extension work
    // cannot become a hard dependency for the basic shell experience.
    _ = registry;
}

test "empty plugin registry is valid" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try loadConfiguredPlugins(&registry);
    try std.testing.expectEqual(@as(usize, 0), registry.count());
}
