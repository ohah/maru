//! Compatibility entry point; native identity belongs to the Windows platform.
const native = @import("maru").win32_file_identity;
pub const Identity = native.Identity;
pub const Error = native.Error;
