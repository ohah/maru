//! CR3a-2a final-address owner for one settled GenerationTransport response.
//!
//! Request/TX backing is never stored here. Only an accepted response owns bytes; typed reject and
//! uncertain outcomes carry the pointer-free settled receipt so every branch has one terminalizer.

const std = @import("std");
const contract = @import("generation_attachment_contract.zig");

/// Mirrors the neutral host-protocol control-frame cap. The session-host barrel pins equality to
/// `protocol.max_control_json`; keeping the value here preserves standalone component tests.
pub const max_owned_response_bytes: usize = 256 * 1024;

pub const DeinitOutcome = enum {
    cleaned,
    already_terminal,
    corrupt,
};

pub const ExecutedResponse = struct {
    self_addr: usize = 0,
    owner_seal_addr: usize = 0,
    incarnation: u64 = 0,
    lifecycle: contract.ExecutedResponseLifecycle = .pristine,
    result: ?contract.ExecuteResult = null,
    payload_digest: u64 = 0,
    allocator: ?std.mem.Allocator = null,
    owned_bytes: []u8 = &.{},

    pub const InitError = error{
        DestinationOccupied,
        InvalidIncarnation,
        InvalidResult,
        InvalidPayload,
        AliasedPayload,
    };

    fn pristine(self: *const ExecutedResponse) bool {
        return self.self_addr == 0 and self.owner_seal_addr == 0 and self.incarnation == 0 and
            self.lifecycle == .pristine and self.result == null and
            self.payload_digest == 0 and self.allocator == null and
            self.owned_bytes.len == 0;
    }

    pub fn canInitializeWithOwner(
        self: *const ExecutedResponse,
        owner_seal: *const contract.ExecutedResponseOwnerSeal,
    ) bool {
        return self.pristine() and owner_seal.self_addr == 0 and
            owner_seal.lifecycle == .pristine and !rangesOverlapTyped(self, owner_seal);
    }

    pub fn initAcceptedInPlace(
        out: *ExecutedResponse,
        allocator: std.mem.Allocator,
        owner_seal: *contract.ExecutedResponseOwnerSeal,
        incarnation: u64,
        correlated: contract.CorrelatedExecutedCall,
        owned_bytes: []u8,
    ) InitError!void {
        if (!out.canInitializeWithOwner(owner_seal))
            return error.DestinationOccupied;
        if (incarnation == 0) return error.InvalidIncarnation;
        if (!correlated.executed_call.valid()) return error.InvalidResult;
        if (owned_bytes.len == 0 or owned_bytes.len > max_owned_response_bytes)
            return error.InvalidPayload;
        const out_start = @intFromPtr(out);
        const out_end = std.math.add(usize, out_start, @sizeOf(ExecutedResponse)) catch
            return error.AliasedPayload;
        const bytes_start = @intFromPtr(owned_bytes.ptr);
        const bytes_end = std.math.add(usize, bytes_start, owned_bytes.len) catch
            return error.AliasedPayload;
        const seal_start = @intFromPtr(owner_seal);
        const seal_end = std.math.add(usize, seal_start, @sizeOf(contract.ExecutedResponseOwnerSeal)) catch
            return error.AliasedPayload;
        if ((out_start < bytes_end and bytes_start < out_end) or
            (seal_start < bytes_end and bytes_start < seal_end))
            return error.AliasedPayload;

        contract.ExecutedResponseOwnerSeal.initInPlace(owner_seal, incarnation) catch
            return error.InvalidIncarnation;
        out.* = .{
            .self_addr = out_start,
            .owner_seal_addr = @intFromPtr(owner_seal),
            .incarnation = incarnation,
            .lifecycle = .accepted,
            .result = .{ .accepted = correlated },
            .payload_digest = payloadDigest(owned_bytes),
            .allocator = allocator,
            .owned_bytes = owned_bytes,
        };
    }

    pub fn initWithoutPayloadInPlace(
        out: *ExecutedResponse,
        owner_seal: *contract.ExecutedResponseOwnerSeal,
        incarnation: u64,
        result: contract.ExecuteResult,
    ) InitError!void {
        if (!out.canInitializeWithOwner(owner_seal))
            return error.DestinationOccupied;
        if (incarnation == 0) return error.InvalidIncarnation;
        const lifecycle: contract.ExecutedResponseLifecycle = switch (result) {
            .accepted => return error.InvalidResult,
            .typed_reject => |correlated| if (correlated.executed_call.valid() and
                correlated.responseMatchesPrepared())
                .typed_reject
            else
                return error.InvalidResult,
            .uncertain_or_connection_failure => |executed| if (executed.valid())
                .uncertain_or_connection_failure
            else
                return error.InvalidResult,
        };
        contract.ExecutedResponseOwnerSeal.initInPlace(owner_seal, incarnation) catch
            return error.InvalidIncarnation;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .owner_seal_addr = @intFromPtr(owner_seal),
            .incarnation = incarnation,
            .lifecycle = lifecycle,
            .result = result,
        };
    }

    pub fn borrowAccepted(
        self: *const ExecutedResponse,
        owner_seal: *const contract.ExecutedResponseOwnerSeal,
    ) error{ NotAccepted, Corrupt }![]const u8 {
        if (self.self_addr != @intFromPtr(self) or self.incarnation == 0 or
            self.owner_seal_addr == 0 or self.owner_seal_addr != @intFromPtr(owner_seal))
            return error.Corrupt;
        if (!owner_seal.valid(self.incarnation)) return error.Corrupt;
        if (self.lifecycle != .accepted) return error.NotAccepted;
        if (self.result == null or self.allocator == null or self.owned_bytes.len == 0 or
            self.payload_digest == 0 or payloadDigest(self.owned_bytes) != self.payload_digest)
            return error.Corrupt;
        switch (self.result.?) {
            .accepted => |correlated| if (!correlated.executed_call.valid()) return error.Corrupt,
            else => return error.Corrupt,
        }
        return self.owned_bytes;
    }

    pub fn deinit(
        self: *ExecutedResponse,
        owner_seal: *contract.ExecutedResponseOwnerSeal,
    ) DeinitOutcome {
        if (self.self_addr != @intFromPtr(self) or self.incarnation == 0)
            return .corrupt;
        if (self.lifecycle == .terminal) return .already_terminal;
        if (self.owner_seal_addr == 0 or self.owner_seal_addr != @intFromPtr(owner_seal))
            return .corrupt;
        switch (self.lifecycle) {
            .accepted => {
                _ = self.borrowAccepted(owner_seal) catch return .corrupt;
                const allocator = self.allocator.?;
                const bytes = self.owned_bytes;
                owner_seal.terminalize(self.incarnation) catch return .corrupt;
                self.owned_bytes = &.{};
                self.allocator = null;
                self.payload_digest = 0;
                self.owner_seal_addr = 0;
                self.result = null;
                self.lifecycle = .terminal;
                allocator.free(bytes);
                return .cleaned;
            },
            .typed_reject, .uncertain_or_connection_failure => {
                if (self.allocator != null or self.owned_bytes.len != 0 or self.payload_digest != 0)
                    return .corrupt;
                owner_seal.terminalize(self.incarnation) catch return .corrupt;
            },
            .pristine, .terminal => unreachable,
        }
        self.result = null;
        self.owner_seal_addr = 0;
        self.lifecycle = .terminal;
        return .cleaned;
    }

    fn payloadDigest(bytes: []const u8) u64 {
        const digest = std.hash.Wyhash.hash(0x4d_52_53_48, bytes);
        return if (digest == 0) 1 else digest;
    }
};

fn rangesOverlapTyped(a: anytype, b: anytype) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    const a_end = std.math.add(usize, a_start, @sizeOf(@TypeOf(a.*))) catch return true;
    const b_end = std.math.add(usize, b_start, @sizeOf(@TypeOf(b.*))) catch return true;
    return a_start < b_end and b_start < a_end;
}

const ResponseReentrantFreeAllocator = struct {
    parent: std.mem.Allocator,
    target: ?*ExecutedResponse = null,
    target_owner: ?*contract.ExecutedResponseOwnerSeal = null,
    armed: bool = false,
    reentered: bool = false,
    free_calls: usize = 0,
    nested_outcome: ?DeinitOutcome = null,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.free_calls += 1;
        if (self.armed and !self.reentered) {
            self.reentered = true;
            self.nested_outcome = self.target.?.deinit(self.target_owner.?);
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

test "CR3a-2a accepted response tombstones before allocator free callback reentry" {
    var probe = ResponseReentrantFreeAllocator{ .parent = std.testing.allocator };
    const prepared = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 51,
        .request_id = 53,
        .request_digest = 59,
    }).?;
    const executed = contract.ExecutedCallReceipt.fromPrepared(prepared).?;
    const correlated = contract.CorrelatedExecutedCall.init(executed, 53).?;
    const bytes = try probe.allocator().dupe(u8, "accepted");
    var owner: contract.ExecutedResponseOwnerSeal = .{};
    var response: ExecutedResponse = .{};
    try response.initAcceptedInPlace(probe.allocator(), &owner, 61, correlated, bytes);
    probe.target = &response;
    probe.target_owner = &owner;
    probe.armed = true;
    try std.testing.expectEqual(DeinitOutcome.cleaned, response.deinit(&owner));
    probe.armed = false;
    try std.testing.expect(probe.reentered);
    try std.testing.expectEqual(DeinitOutcome.already_terminal, probe.nested_outcome.?);
    try std.testing.expectEqual(@as(usize, 1), probe.free_calls);
}

test "CR3a-2a accepted executed response frees once and copied owner frees zero" {
    var response: ExecutedResponse = .{};
    var response_owner: contract.ExecutedResponseOwnerSeal = .{};
    const prepared = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 3,
        .request_id = 5,
        .request_digest = 7,
    }).?;
    const executed = contract.ExecutedCallReceipt.fromPrepared(prepared).?;
    const correlated = contract.CorrelatedExecutedCall.init(executed, 5).?;
    const bytes = try std.testing.allocator.dupe(u8, "accepted");

    try response.initAcceptedInPlace(std.testing.allocator, &response_owner, 11, correlated, bytes);
    try std.testing.expectEqualStrings("accepted", try response.borrowAccepted(&response_owner));
    const stale_same_address = response;
    var copied = response;
    try std.testing.expectEqual(DeinitOutcome.corrupt, copied.deinit(&response_owner));
    try std.testing.expectEqual(DeinitOutcome.cleaned, response.deinit(&response_owner));
    try std.testing.expectEqual(DeinitOutcome.already_terminal, response.deinit(&response_owner));
    response = stale_same_address;
    try std.testing.expectError(error.Corrupt, response.borrowAccepted(&response_owner));
    try std.testing.expectEqual(DeinitOutcome.corrupt, response.deinit(&response_owner));
}

test "CR3a-2a reject and uncertain executed responses own no payload" {
    const prepared = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 13,
        .request_id = 17,
        .request_digest = 19,
    }).?;
    const executed = contract.ExecutedCallReceipt.fromPrepared(prepared).?;
    const correlated = contract.CorrelatedExecutedCall.init(executed, 17).?;

    var rejected: ExecutedResponse = .{};
    var rejected_owner: contract.ExecutedResponseOwnerSeal = .{};
    try rejected.initWithoutPayloadInPlace(&rejected_owner, 23, .{ .typed_reject = correlated });
    try std.testing.expectError(error.NotAccepted, rejected.borrowAccepted(&rejected_owner));
    try std.testing.expectEqual(DeinitOutcome.cleaned, rejected.deinit(&rejected_owner));

    var uncertain: ExecutedResponse = .{};
    var uncertain_owner: contract.ExecutedResponseOwnerSeal = .{};
    try uncertain.initWithoutPayloadInPlace(&uncertain_owner, 29, .{ .uncertain_or_connection_failure = executed });
    try std.testing.expectError(error.NotAccepted, uncertain.borrowAccepted(&uncertain_owner));
    try std.testing.expectEqual(DeinitOutcome.cleaned, uncertain.deinit(&uncertain_owner));

    const mismatched = contract.CorrelatedExecutedCall.init(executed, 18).?;
    var invalid_reject: ExecutedResponse = .{};
    var invalid_owner: contract.ExecutedResponseOwnerSeal = .{};
    try std.testing.expectError(
        error.InvalidResult,
        invalid_reject.initWithoutPayloadInPlace(&invalid_owner, 31, .{ .typed_reject = mismatched }),
    );
}

test "CR3a-2a accepted response owner rejects control cap plus one without taking bytes" {
    const prepared = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 31,
        .request_id = 37,
        .request_digest = 41,
    }).?;
    const executed = contract.ExecutedCallReceipt.fromPrepared(prepared).?;
    const correlated = contract.CorrelatedExecutedCall.init(executed, 37).?;
    const bytes = try std.testing.allocator.alloc(u8, max_owned_response_bytes + 1);
    defer std.testing.allocator.free(bytes);
    var response: ExecutedResponse = .{};
    var response_owner: contract.ExecutedResponseOwnerSeal = .{};
    try std.testing.expectError(
        error.InvalidPayload,
        response.initAcceptedInPlace(std.testing.allocator, &response_owner, 43, correlated, bytes),
    );
    try std.testing.expect(response.pristine());
}
