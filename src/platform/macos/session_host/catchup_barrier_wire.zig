//! Dependency-free CR4 catch-up barrier wire constants.
//!
//! `protocol.zig` stays platform-neutral, while the higher identity contract imports platform owner types. Keeping the
//! released raw kind/version/payload size here prevents parallel literals without creating an import cycle.

pub const kind_raw: u16 = 14;
pub const version: u16 = 1;
pub const payload_size: usize = 96;

comptime {
    if (kind_raw == 0 or version == 0 or payload_size > std.math.maxInt(u32)) unreachable;
}

const std = @import("std");
