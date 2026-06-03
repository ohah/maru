const terminal = @import("../terminal.zig");

pub const Backend = enum {
    metal,
    webgpu,
    d3d12,
    vulkan,
};

pub const RenderFrame = struct {
    backend: Backend,
    snapshot: terminal.RenderSnapshot,
};

pub fn initialBackendForMacOS() Backend {
    return .metal;
}

test "macOS renderer starts with Metal" {
    try @import("std").testing.expectEqual(Backend.metal, initialBackendForMacOS());
}
