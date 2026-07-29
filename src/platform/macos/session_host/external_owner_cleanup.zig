//! Backend-neutral, final-address cleanup descriptors for cross-owner aggregate teardown.
//!
//! This leaf knows no ledger, intent, pump, or destination type. A descriptor is cleanup
//! authority only at its sealed address. Moving that authority requires `moveFrozen`, which
//! tombstones the source before publishing the destination; copying the struct is never valid.

const std = @import("std");
const frozen_cleanup_guard = @import("frozen_cleanup_guard.zig");
const owner_seal = @import("external_owner_seal.zig");

pub const Digest = owner_seal.Digest;

pub const Lifecycle = enum {
    empty,
    frozen,
    spent,
    quarantined,
};

pub const FrozenOwnerCleanupDescriptor = struct {
    saved_self_addr: usize = 0,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    allocation_addr: usize = 0,
    allocation_len: usize = 0,
    allocation_alignment: std.mem.Alignment = .@"1",
    content_digest: Digest = [_]u8{0} ** 32,
    lifecycle: Lifecycle = .empty,
    digest: Digest = [_]u8{0} ** 32,
};

pub const Error = error{
    InvalidSource,
    InvalidDestination,
    InvalidAlias,
};

pub const FinishResult = enum {
    cleaned,
    already_spent,
    quarantined,
    callback_reentry,
};

pub fn callbackActive() bool {
    return frozen_cleanup_guard.active();
}

pub fn freezeOwnedSlice(
    out: *FrozenOwnerCleanupDescriptor,
    allocator: std.mem.Allocator,
    allocation: []u8,
) Error!void {
    try validateFreezeOwnedSlice(out, allocation);
    freezeOwnedSliceUnchecked(out, allocator, allocation);
}

pub fn validateFreezeOwnedSlice(
    out: *const FrozenOwnerCleanupDescriptor,
    allocation: []const u8,
) Error!void {
    try validateFreezeOwnedSliceAligned(out, allocation, .@"1");
}

pub fn validateFreezeOwnedSliceAligned(
    out: *const FrozenOwnerCleanupDescriptor,
    allocation: []const u8,
    alignment: std.mem.Alignment,
) Error!void {
    if (!isPristine(out)) return error.InvalidDestination;
    if (allocation.len == 0) return error.InvalidSource;
    const allocation_addr = @intFromPtr(allocation.ptr);
    if (!std.mem.isAligned(allocation_addr, alignment.toByteUnits()))
        return error.InvalidSource;
    if (rangesOverlap(
        @intFromPtr(out),
        @sizeOf(FrozenOwnerCleanupDescriptor),
        allocation_addr,
        allocation.len,
    )) return error.InvalidAlias;
}

pub fn freezeOwnedSliceUnchecked(
    out: *FrozenOwnerCleanupDescriptor,
    allocator: std.mem.Allocator,
    allocation: []const u8,
) void {
    freezeOwnedSliceAlignedUnchecked(out, allocator, allocation, .@"1");
}

pub fn freezeOwnedSliceAlignedUnchecked(
    out: *FrozenOwnerCleanupDescriptor,
    allocator: std.mem.Allocator,
    allocation: []const u8,
    alignment: std.mem.Alignment,
) void {
    const allocation_addr = @intFromPtr(allocation.ptr);
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .allocator = allocator,
        .allocator_ptr_addr = @intFromPtr(allocator.ptr),
        .allocator_vtable_addr = @intFromPtr(allocator.vtable),
        .allocation_addr = allocation_addr,
        .allocation_len = allocation.len,
        .allocation_alignment = alignment,
        .content_digest = contentDigest(allocation),
        .lifecycle = .frozen,
        .digest = undefined,
    };
    out.digest = descriptorDigest(out);
}

/// Publishes a descriptor from a content seal that the caller validated before its no-fail
/// mutation barrier. This avoids re-hashing potentially multi-megabyte payloads between source
/// tombstone and destination authority publication.
pub fn freezeOwnedSliceFromSealUnchecked(
    out: *FrozenOwnerCleanupDescriptor,
    allocator: std.mem.Allocator,
    allocation: []const u8,
    sealed_content_digest: Digest,
) void {
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .allocator = allocator,
        .allocator_ptr_addr = @intFromPtr(allocator.ptr),
        .allocator_vtable_addr = @intFromPtr(allocator.vtable),
        .allocation_addr = @intFromPtr(allocation.ptr),
        .allocation_len = allocation.len,
        .allocation_alignment = .@"1",
        .content_digest = sealed_content_digest,
        .lifecycle = .frozen,
        .digest = undefined,
    };
    out.digest = descriptorDigest(out);
}

/// Moves final-address cleanup authority without invoking an allocator callback.
pub fn moveFrozen(
    source: *FrozenOwnerCleanupDescriptor,
    out: *FrozenOwnerCleanupDescriptor,
) Error!void {
    try validateMoveFrozen(source, out);
    moveFrozenUnchecked(source, out);
}

pub fn validateMoveFrozen(
    source: *const FrozenOwnerCleanupDescriptor,
    out: *const FrozenOwnerCleanupDescriptor,
) Error!void {
    if (!validate(source)) return error.InvalidSource;
    if (!isPristine(out)) return error.InvalidDestination;
    if (rangesOverlap(
        @intFromPtr(source),
        @sizeOf(FrozenOwnerCleanupDescriptor),
        @intFromPtr(out),
        @sizeOf(FrozenOwnerCleanupDescriptor),
    ) or rangesOverlap(
        @intFromPtr(out),
        @sizeOf(FrozenOwnerCleanupDescriptor),
        source.allocation_addr,
        source.allocation_len,
    )) return error.InvalidAlias;
}

pub fn moveFrozenUnchecked(
    source: *FrozenOwnerCleanupDescriptor,
    out: *FrozenOwnerCleanupDescriptor,
) void {
    const moved = source.*;
    source.lifecycle = .spent;
    source.digest = descriptorDigest(source);
    out.* = moved;
    out.saved_self_addr = @intFromPtr(out);
    out.digest = descriptorDigest(out);
}

pub fn finishCallbackHidden(
    descriptor: *FrozenOwnerCleanupDescriptor,
) FinishResult {
    switch (descriptor.lifecycle) {
        .spent => return .already_spent,
        .empty, .quarantined => return .quarantined,
        .frozen => {},
    }
    if (!validate(descriptor)) {
        descriptor.* = .{ .lifecycle = .quarantined };
        return .quarantined;
    }
    if (!frozen_cleanup_guard.enter()) return .callback_reentry;
    defer frozen_cleanup_guard.leave();
    const allocator = descriptor.allocator;
    const allocation_alignment = descriptor.allocation_alignment;
    const allocation =
        @as([*]u8, @ptrFromInt(descriptor.allocation_addr))[0..descriptor.allocation_len];
    descriptor.* = .{ .lifecycle = .spent };
    allocator.rawFree(allocation, allocation_alignment, @returnAddress());
    return .cleaned;
}

pub fn validate(descriptor: *const FrozenOwnerCleanupDescriptor) bool {
    if (descriptor.saved_self_addr != @intFromPtr(descriptor) or
        descriptor.lifecycle != .frozen or
        descriptor.allocation_addr == 0 or
        descriptor.allocation_len == 0 or
        !std.mem.isAligned(
            descriptor.allocation_addr,
            descriptor.allocation_alignment.toByteUnits(),
        ) or
        @intFromPtr(descriptor.allocator.ptr) != descriptor.allocator_ptr_addr or
        @intFromPtr(descriptor.allocator.vtable) != descriptor.allocator_vtable_addr or
        !std.mem.eql(
            u8,
            &descriptor.digest,
            &descriptorDigest(descriptor),
        ))
        return false;
    const allocation =
        @as([*]const u8, @ptrFromInt(descriptor.allocation_addr))[0..descriptor.allocation_len];
    return std.mem.eql(
        u8,
        &descriptor.content_digest,
        &contentDigest(allocation),
    );
}

pub fn contentDigest(bytes: []const u8) Digest {
    var writer = owner_seal.Writer.init("MARUOCD1");
    writer.writeBytes(bytes);
    return writer.finish();
}

fn descriptorDigest(
    descriptor: *const FrozenOwnerCleanupDescriptor,
) Digest {
    var writer = owner_seal.Writer.init("MARUOCL1");
    writer.writeUsize(descriptor.saved_self_addr);
    writer.writeUsize(descriptor.allocator_ptr_addr);
    writer.writeUsize(descriptor.allocator_vtable_addr);
    writer.writeUsize(descriptor.allocation_addr);
    writer.writeUsize(descriptor.allocation_len);
    writer.writeU8(@intFromEnum(descriptor.allocation_alignment));
    writer.writeBytes(&descriptor.content_digest);
    writer.writeU8(@intFromEnum(descriptor.lifecycle));
    return writer.finish();
}

pub fn isPristine(descriptor: *const FrozenOwnerCleanupDescriptor) bool {
    return descriptor.saved_self_addr == 0 and
        descriptor.allocator_ptr_addr == 0 and
        descriptor.allocator_vtable_addr == 0 and
        descriptor.allocation_addr == 0 and
        descriptor.allocation_len == 0 and
        descriptor.lifecycle == .empty and
        std.mem.allEqual(u8, &descriptor.content_digest, 0) and
        std.mem.allEqual(u8, &descriptor.digest, 0);
}

fn rangesOverlap(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

test "frozen cleanup authority moves once and copied descriptors are invalid" {
    const allocation = try std.testing.allocator.dupe(u8, "aggregate-cleanup");
    var first: FrozenOwnerCleanupDescriptor = .{};
    try freezeOwnedSlice(&first, std.testing.allocator, allocation);
    var copied = first;
    try std.testing.expect(!validate(&copied));
    var second: FrozenOwnerCleanupDescriptor = .{};
    try moveFrozen(&first, &second);
    try std.testing.expectEqual(Lifecycle.spent, first.lifecycle);
    try std.testing.expect(validate(&second));
    try std.testing.expectEqual(
        FinishResult.cleaned,
        finishCallbackHidden(&second),
    );
    try std.testing.expectEqual(
        FinishResult.already_spent,
        finishCallbackHidden(&second),
    );
}

test "frozen cleanup preserves the allocator alignment contract" {
    const allocation = try std.testing.allocator.allocWithOptions(
        u8,
        37,
        .@"64",
        null,
    );
    @memset(allocation, 0xa5);
    var descriptor: FrozenOwnerCleanupDescriptor = .{};
    try validateFreezeOwnedSliceAligned(
        &descriptor,
        allocation,
        .@"64",
    );
    freezeOwnedSliceAlignedUnchecked(
        &descriptor,
        std.testing.allocator,
        allocation,
        .@"64",
    );
    try std.testing.expectEqual(
        std.mem.Alignment.@"64",
        descriptor.allocation_alignment,
    );
    try std.testing.expect(validate(&descriptor));
    try std.testing.expectEqual(
        FinishResult.cleaned,
        finishCallbackHidden(&descriptor),
    );
}
