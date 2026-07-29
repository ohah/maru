//! Dependency-free external RX provenance DTOs.
//!
//! Parser mechanics, inbox accounting, recovery, and future trace consumers share these values
//! without importing one another. These are observations only: none carries cleanup or commit
//! authority.

pub const RxIdentity = struct {
    attach_instance_id: u64 = 0,
    destination_slot_addr: usize = 0,
};

pub const RxRange = struct {
    identity: RxIdentity,
    start_absolute: u64,
    end_absolute: u64,
};

pub const RxWatermark = struct {
    identity: RxIdentity,
    absolute: u64,
};

test "external RX DTOs stay pointer-free observations" {
    const std = @import("std");
    try std.testing.expect(!@typeInfo(RxIdentity).@"struct".is_tuple);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(RxIdentity).@"struct".fields.len);
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(RxRange).@"struct".fields.len);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(RxWatermark).@"struct".fields.len);
}
