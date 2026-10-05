//! Compatibility entry point; native identity belongs to the Windows platform.
const native = @import("../file_identity.zig");
pub const Identity = native.Identity;
pub const Error = native.Error;
