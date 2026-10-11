//! Host-owned format must survive transport and handoff without a namespace downgrade.
test {
    _ = @import("platform/macos/session_host/remote_runtime.zig");
    _ = @import("platform/macos/session_host/client.zig");
    _ = @import("platform/macos/session_host/host_adapter.zig");
    _ = @import("platform/macos/session_host/handoff_codec.zig");
    _ = @import("platform/macos/session_host/runtime_metadata_wire.zig");
    _ = @import("platform/macos/session_host/server.zig");
    _ = @import("platform/macos/session_host/runtime_manager.zig");
}
