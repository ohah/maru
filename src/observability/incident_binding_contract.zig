//! CR0b managed Client 등록의 pointer-free 인계 계약.
//!
//! HostPool과 ClientSlot은 서로를 import하지 않는다. 두 owner는 이 고정 크기 projection만 공유해
//! fallible map 예약, final-address Client binding, no-fail map publication의 순서를 증명한다.

const std = @import("std");

pub const HostClass = enum(u8) {
    current = 1,
    previous = 2,
    external = 3,
};

pub const PublicationLifecycle = enum(u8) {
    pristine = 0,
    prepared = 1,
    bound = 2,
    consumed = 3,
};

pub const IncidentBinding = struct {
    client_addr: u64 = 0,
    host_id: u128 = 0,
    host_adapter_generation: u64 = 0,
    connection_generation: u64 = 0,
    wire_major: u16 = 0,
    host_class_raw: u8 = 0,
    seal: [32]u8 = [_]u8{0} ** 32,
};

pub const PreparedHostPublication = struct {
    self_addr: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    pool_addr: u64 = 0,
    host_id: u128 = 0,
    adapter_addr: u64 = 0,
    adapter_generation: u64 = 0,
    owned_raw: u8 = 0,
    lifecycle_raw: u8 = 0,
    seal: [32]u8 = [_]u8{0} ** 32,
};

pub const IncidentBindingPublication = struct {
    client_addr: u64 = 0,
    binding_seal: [32]u8 = [_]u8{0} ** 32,
};

pub fn validBindingShape(value: IncidentBinding) bool {
    return value.client_addr != 0 and value.host_id != 0 and value.host_adapter_generation != 0 and
        value.connection_generation != 0 and value.wire_major != 0 and
        std.enums.fromInt(HostClass, value.host_class_raw) != null and !allZero(value.seal);
}

pub fn validPreparedShape(value: PreparedHostPublication, expected_addr: usize) bool {
    return value.self_addr == expected_addr and value.pid != 0 and value.process_nonce != 0 and
        value.pool_addr != 0 and value.host_id != 0 and value.adapter_addr != 0 and
        value.adapter_generation != 0 and value.owned_raw == 1 and
        (value.lifecycle_raw == @intFromEnum(PublicationLifecycle.prepared) or
            value.lifecycle_raw == @intFromEnum(PublicationLifecycle.bound)) and !allZero(value.seal);
}

pub fn validPublicationShape(value: IncidentBindingPublication) bool {
    return value.client_addr != 0 and !allZero(value.binding_seal);
}

fn allZero(bytes: [32]u8) bool {
    return std.mem.allEqual(u8, &bytes, 0);
}

fn recursivelyPointerFree(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer, .@"fn" => false,
        .array => |info| recursivelyPointerFree(info.child),
        .optional => |info| recursivelyPointerFree(info.child),
        .error_union => |info| recursivelyPointerFree(info.payload),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (!recursivelyPointerFree(field.type)) break :blk false;
            break :blk true;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| if (!recursivelyPointerFree(field.type)) break :blk false;
            break :blk true;
        },
        else => true,
    };
}

test "CR0b binding 계약은 managed Client identity의 exact scalar schema를 고정한다" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(IncidentBinding));
    try std.testing.expectEqual(@as(usize, 7), std.meta.fields(IncidentBinding).len);
}

test "CR0b binding 계약은 HostPool publication permit의 exact scalar schema를 고정한다" {
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(PreparedHostPublication));
    try std.testing.expectEqual(@as(usize, 10), std.meta.fields(PreparedHostPublication).len);
}

test "CR0b binding 계약은 publication evidence의 exact scalar schema를 고정한다" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(IncidentBindingPublication));
    try std.testing.expectEqual(@as(usize, 2), std.meta.fields(IncidentBindingPublication).len);
}

test "CR0b binding 계약은 세 DTO를 재귀 pointer-free로 유지한다" {
    try std.testing.expect(recursivelyPointerFree(IncidentBinding));
    try std.testing.expect(recursivelyPointerFree(PreparedHostPublication));
    try std.testing.expect(recursivelyPointerFree(IncidentBindingPublication));
}

test "CR0b binding 계약은 host class와 publication lifecycle raw를 닫힌 값으로만 허용한다" {
    try std.testing.expectEqual(@as(usize, 3), std.meta.fields(HostClass).len);
    try std.testing.expectEqual(@as(usize, 4), std.meta.fields(PublicationLifecycle).len);
    try std.testing.expect(std.enums.fromInt(HostClass, 0) == null);
    try std.testing.expect(std.enums.fromInt(PublicationLifecycle, 4) == null);
}

test "CR0b binding 계약은 zero identity와 zero seal을 publication authority로 인정하지 않는다" {
    try std.testing.expect(!validBindingShape(.{}));
    try std.testing.expect(!validPreparedShape(.{}, 1));
    try std.testing.expect(!validPublicationShape(.{}));
}
