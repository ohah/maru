//! Executable sentinel proving the focused RemoteRuntime component still exposes typed controls.

const remote = @import("remote_runtime");

pub fn main() void {
    comptime {
        if (!@hasDecl(remote.RemoteRuntime, "resize"))
            @compileError("RemoteRuntime resize control disappeared");
        if (!@hasDecl(remote.RemoteRuntime, "requestResync"))
            @compileError("RemoteRuntime resync control disappeared");
    }
}
