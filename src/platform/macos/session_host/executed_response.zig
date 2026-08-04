//! CR3a-2a final-address owner for one settled GenerationTransport response.
//!
//! Request/TX backing is never stored here. Only an accepted response owns bytes; typed reject and
//! uncertain outcomes carry the pointer-free settled receipt so every branch has one terminalizer.

const std = @import("std");
const contract = @import("generation_attachment_contract.zig");

pub const AllocationProvenance = struct {
    guard_addr: usize,
    node_addr: usize,
    operation_incarnation: u64,
    generation: u64,

    pub fn valid(self: AllocationProvenance) bool {
        return self.guard_addr != 0 and self.node_addr != 0 and
            self.operation_incarnation != 0 and self.generation != 0;
    }
};

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
    result_present: u8 = 0,
    result_tag: u8 = 0,
    executed_transport_incarnation: u64 = 0,
    executed_request_id: u64 = 0,
    executed_request_digest: u64 = 0,
    correlation_request_id: u64 = 0,
    payload_digest: u64 = 0,
    allocator_present: u8 = 0,
    allocator_ptr: usize = 0,
    allocator_vtable: usize = 0,
    owned_addr: usize = 0,
    owned_len: usize = 0,
    allocation_guard_addr: usize = 0,
    allocation_node_addr: usize = 0,
    allocation_operation_incarnation: u64 = 0,
    allocation_generation: u64 = 0,
    terminal_digest: u64 = 0,

    pub const InitError = error{
        DestinationOccupied,
        InvalidIncarnation,
        InvalidResult,
        InvalidPayload,
        AliasedPayload,
    };

    pub fn lifecycleRawValid(self: *const ExecutedResponse) bool {
        const raw = @as(*const u8, @ptrCast(&self.lifecycle)).*;
        return raw <= @intFromEnum(contract.ExecutedResponseLifecycle.terminal);
    }

    pub fn pristine(self: *const ExecutedResponse) bool {
        // Caller-owned destination storage is an opaque byte container until initialization.
        // Requiring its complete representation to be zero avoids interpreting enum padding or
        // future fields as typed values and makes newly added authority fields fail closed.
        return std.mem.allEqual(u8, std.mem.asBytes(self), 0);
    }

    pub fn canInitializeWithOwner(
        self: *const ExecutedResponse,
        owner_seal: *const contract.ExecutedResponseOwnerSeal,
    ) bool {
        return self.pristine() and owner_seal.lifecycleRawValid() and
            owner_seal.self_addr == 0 and
            owner_seal.lifecycle == .pristine and !rangesOverlapTyped(self, owner_seal);
    }

    pub fn initAcceptedFromPromotedInPlace(
        out: *ExecutedResponse,
        allocator: std.mem.Allocator,
        owner_seal: *contract.ExecutedResponseOwnerSeal,
        incarnation: u64,
        correlated: contract.CorrelatedExecutedCall,
        owned_bytes: []u8,
        provenance: AllocationProvenance,
    ) InitError!void {
        if (!out.canInitializeWithOwner(owner_seal))
            return error.DestinationOccupied;
        if (incarnation == 0) return error.InvalidIncarnation;
        if (!correlated.executed_call.valid()) return error.InvalidResult;
        if (owned_bytes.len == 0 or owned_bytes.len > max_owned_response_bytes)
            return error.InvalidPayload;
        if (!provenance.valid()) return error.InvalidPayload;
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

        out.* = .{
            .self_addr = out_start,
            .owner_seal_addr = @intFromPtr(owner_seal),
            .incarnation = incarnation,
            .lifecycle = .accepted,
            .result_present = 1,
            .result_tag = @intFromEnum(contract.ExecuteOutcome.accepted),
            .executed_transport_incarnation = correlated.executed_call.prepared_call.transport_incarnation,
            .executed_request_id = correlated.executed_call.prepared_call.request_id,
            .executed_request_digest = correlated.executed_call.prepared_call.request_digest,
            .correlation_request_id = correlated.response_request_id,
            .payload_digest = payloadDigest(owned_bytes),
            .allocator_present = 1,
            .allocator_ptr = @intFromPtr(allocator.ptr),
            .allocator_vtable = @intFromPtr(allocator.vtable),
            .owned_addr = @intFromPtr(owned_bytes.ptr),
            .owned_len = owned_bytes.len,
            .allocation_guard_addr = provenance.guard_addr,
            .allocation_node_addr = provenance.node_addr,
            .allocation_operation_incarnation = provenance.operation_incarnation,
            .allocation_generation = provenance.generation,
        };
        contract.ExecutedResponseOwnerSeal.initInPlace(
            owner_seal,
            incarnation,
            out_start,
            responseTranscriptDigest(out),
        ) catch {
            out.* = .{};
            return error.InvalidIncarnation;
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
        const executed = switch (result) {
            .accepted => unreachable,
            .typed_reject => |correlated| correlated.executed_call,
            .uncertain_or_connection_failure => |receipt| receipt,
        };
        const correlation_request_id: u64 = switch (result) {
            .accepted => unreachable,
            .typed_reject => |correlated| correlated.response_request_id,
            .uncertain_or_connection_failure => 0,
        };
        out.* = .{
            .self_addr = @intFromPtr(out),
            .owner_seal_addr = @intFromPtr(owner_seal),
            .incarnation = incarnation,
            .lifecycle = lifecycle,
            .result_present = 1,
            .result_tag = @intFromEnum(std.meta.activeTag(result)),
            .executed_transport_incarnation = executed.prepared_call.transport_incarnation,
            .executed_request_id = executed.prepared_call.request_id,
            .executed_request_digest = executed.prepared_call.request_digest,
            .correlation_request_id = correlation_request_id,
        };
        contract.ExecutedResponseOwnerSeal.initInPlace(
            owner_seal,
            incarnation,
            @intFromPtr(out),
            responseTranscriptDigest(out),
        ) catch {
            out.* = .{};
            return error.InvalidIncarnation;
        };
    }

    pub fn borrowAccepted(
        self: *const ExecutedResponse,
        owner_seal: *const contract.ExecutedResponseOwnerSeal,
    ) error{ NotAccepted, Corrupt }![]const u8 {
        if (!self.lifecycleRawValid() or self.self_addr != @intFromPtr(self) or
            self.incarnation == 0 or
            self.owner_seal_addr == 0 or self.owner_seal_addr != @intFromPtr(owner_seal))
            return error.Corrupt;
        if (!owner_seal.valid(self.incarnation)) return error.Corrupt;
        if (self.lifecycle != .accepted) return error.NotAccepted;
        if (!self.transcriptMatchesOwner(owner_seal) or self.result_present != 1 or
            self.result_tag != @intFromEnum(contract.ExecuteOutcome.accepted) or
            !self.resultScalarsValid(true) or
            self.allocator_present != 1 or self.allocator_ptr == 0 or
            self.allocator_vtable == 0 or self.owned_addr == 0 or self.owned_len == 0 or
            self.owned_len > max_owned_response_bytes or self.payload_digest == 0)
            return error.Corrupt;
        if (self.allocation_guard_addr == 0 or self.allocation_node_addr == 0 or
            self.allocation_operation_incarnation == 0 or self.allocation_generation == 0)
            return error.Corrupt;
        _ = std.math.add(usize, self.owned_addr, self.owned_len) catch return error.Corrupt;
        const bytes: []const u8 = @as([*]const u8, @ptrFromInt(self.owned_addr))[0..self.owned_len];
        if (payloadDigest(bytes) != self.payload_digest) return error.Corrupt;
        return bytes;
    }

    pub fn deinit(
        self: *ExecutedResponse,
        owner_seal: *contract.ExecutedResponseOwnerSeal,
    ) DeinitOutcome {
        if (!self.lifecycleRawValid() or self.self_addr != @intFromPtr(self) or
            self.incarnation == 0)
            return .corrupt;
        if (self.lifecycle == .terminal)
            return if (self.terminalTombstoneMatchesOwner(owner_seal))
                .already_terminal
            else
                .corrupt;
        if (self.owner_seal_addr == 0 or self.owner_seal_addr != @intFromPtr(owner_seal))
            return .corrupt;
        switch (self.lifecycle) {
            .accepted => {
                const borrowed = self.borrowAccepted(owner_seal) catch return .corrupt;
                const allocator = std.mem.Allocator{
                    .ptr = @ptrFromInt(self.allocator_ptr),
                    .vtable = @ptrFromInt(self.allocator_vtable),
                };
                const bytes: []u8 = @constCast(borrowed);
                owner_seal.terminalize(self.incarnation) catch return .corrupt;
                self.owned_addr = 0;
                self.owned_len = 0;
                self.allocator_present = 0;
                self.allocator_ptr = 0;
                self.allocator_vtable = 0;
                self.payload_digest = 0;
                self.allocation_guard_addr = 0;
                self.allocation_node_addr = 0;
                self.allocation_operation_incarnation = 0;
                self.allocation_generation = 0;
                self.owner_seal_addr = 0;
                self.clearResult();
                self.lifecycle = .terminal;
                self.terminal_digest = terminalTombstoneDigest(self);
                allocator.free(bytes);
                return if (self.terminalTombstoneMatchesOwner(owner_seal))
                    .cleaned
                else
                    .corrupt;
            },
            .typed_reject, .uncertain_or_connection_failure => {
                const expected_result_tag: u8 = switch (self.lifecycle) {
                    .typed_reject => @intFromEnum(contract.ExecuteOutcome.typed_reject),
                    .uncertain_or_connection_failure => @intFromEnum(contract.ExecuteOutcome.uncertain_or_connection_failure),
                    else => unreachable,
                };
                if (!self.transcriptMatchesOwner(owner_seal) or self.result_present != 1 or
                    self.result_tag != expected_result_tag or
                    !self.resultScalarsValid(self.lifecycle == .typed_reject) or
                    self.allocator_present != 0 or self.allocator_ptr != 0 or
                    self.allocator_vtable != 0 or self.owned_addr != 0 or self.owned_len != 0 or
                    self.payload_digest != 0 or self.allocation_guard_addr != 0 or
                    self.allocation_node_addr != 0 or self.allocation_operation_incarnation != 0 or
                    self.allocation_generation != 0)
                    return .corrupt;
                owner_seal.terminalize(self.incarnation) catch return .corrupt;
            },
            .pristine, .terminal => unreachable,
        }
        self.clearResult();
        self.owner_seal_addr = 0;
        self.lifecycle = .terminal;
        self.terminal_digest = terminalTombstoneDigest(self);
        return if (self.terminalTombstoneMatchesOwner(owner_seal)) .cleaned else .corrupt;
    }

    fn clearResult(self: *ExecutedResponse) void {
        self.result_present = 0;
        self.result_tag = 0;
        self.executed_transport_incarnation = 0;
        self.executed_request_id = 0;
        self.executed_request_digest = 0;
        self.correlation_request_id = 0;
    }

    fn terminalTombstoneMatchesOwner(
        self: *const ExecutedResponse,
        owner_seal: *const contract.ExecutedResponseOwnerSeal,
    ) bool {
        return self.terminalTombstoneExact() and
            owner_seal.lifecycleRawValid() and owner_seal.settledExact() and
            owner_seal.lifecycle == .terminal and
            owner_seal.incarnation == self.incarnation and
            owner_seal.response_addr == @intFromPtr(self) and
            owner_seal.response_digest != 0;
    }

    /// Checks the response-local half of a terminal pair. This is private validation only: once
    /// the registry-owned seal is released, no caller may use the local tombstone as cleanup or
    /// replay authority.
    fn terminalTombstoneExact(self: *const ExecutedResponse) bool {
        return self.lifecycleRawValid() and self.self_addr == @intFromPtr(self) and
            self.incarnation != 0 and self.lifecycle == .terminal and
            self.owner_seal_addr == 0 and self.result_present == 0 and
            self.result_tag == 0 and self.executed_transport_incarnation == 0 and
            self.executed_request_id == 0 and self.executed_request_digest == 0 and
            self.correlation_request_id == 0 and self.payload_digest == 0 and
            self.allocator_present == 0 and self.allocator_ptr == 0 and
            self.allocator_vtable == 0 and self.owned_addr == 0 and self.owned_len == 0 and
            self.allocation_guard_addr == 0 and self.allocation_node_addr == 0 and
            self.allocation_operation_incarnation == 0 and self.allocation_generation == 0 and
            self.terminal_digest != 0 and
            self.terminal_digest == terminalTombstoneDigest(self);
    }

    fn resultScalarsValid(self: *const ExecutedResponse, correlated: bool) bool {
        if (self.executed_transport_incarnation == 0 or self.executed_request_id == 0 or
            self.executed_request_digest == 0)
            return false;
        return if (correlated)
            self.correlation_request_id == self.executed_request_id
        else
            self.correlation_request_id == 0;
    }

    fn transcriptMatchesOwner(
        self: *const ExecutedResponse,
        owner_seal: *const contract.ExecutedResponseOwnerSeal,
    ) bool {
        return owner_seal.response_addr == @intFromPtr(self) and
            owner_seal.response_digest == responseTranscriptDigest(self);
    }

    fn payloadDigest(bytes: []const u8) u64 {
        const digest = std.hash.Wyhash.hash(0x4d_52_53_48, bytes);
        return if (digest == 0) 1 else digest;
    }
};

fn responseTranscriptDigest(response: *const ExecutedResponse) u64 {
    var hasher = std.hash.Wyhash.init(0x4d_52_53_48_52_45_53_50);
    inline for (std.meta.fields(ExecutedResponse)) |field|
        hasher.update(std.mem.asBytes(&@field(response, field.name)));
    const digest = hasher.final();
    return if (digest == 0) 1 else digest;
}

comptime {
    const FieldSpec = struct { name: []const u8, field_type: type };
    const expected_fields = [_]FieldSpec{
        .{ .name = "self_addr", .field_type = usize },
        .{ .name = "owner_seal_addr", .field_type = usize },
        .{ .name = "incarnation", .field_type = u64 },
        .{ .name = "lifecycle", .field_type = contract.ExecutedResponseLifecycle },
        .{ .name = "result_present", .field_type = u8 },
        .{ .name = "result_tag", .field_type = u8 },
        .{ .name = "executed_transport_incarnation", .field_type = u64 },
        .{ .name = "executed_request_id", .field_type = u64 },
        .{ .name = "executed_request_digest", .field_type = u64 },
        .{ .name = "correlation_request_id", .field_type = u64 },
        .{ .name = "payload_digest", .field_type = u64 },
        .{ .name = "allocator_present", .field_type = u8 },
        .{ .name = "allocator_ptr", .field_type = usize },
        .{ .name = "allocator_vtable", .field_type = usize },
        .{ .name = "owned_addr", .field_type = usize },
        .{ .name = "owned_len", .field_type = usize },
        .{ .name = "allocation_guard_addr", .field_type = usize },
        .{ .name = "allocation_node_addr", .field_type = usize },
        .{ .name = "allocation_operation_incarnation", .field_type = u64 },
        .{ .name = "allocation_generation", .field_type = u64 },
        .{ .name = "terminal_digest", .field_type = u64 },
    };
    const actual_fields = std.meta.fields(ExecutedResponse);
    if (actual_fields.len != expected_fields.len)
        @compileError("ExecutedResponse schema changed without lifecycle review");
    for (actual_fields, expected_fields) |actual, expected|
        if (!std.mem.eql(u8, actual.name, expected.name) or actual.type != expected.field_type)
            @compileError("ExecutedResponse schema changed without lifecycle review");
}

fn terminalTombstoneDigest(response: *const ExecutedResponse) u64 {
    var hasher = std.hash.Wyhash.init(0x4d_52_53_48_52_54_4f_4d);
    inline for (.{
        response.self_addr,
        @as(usize, @intCast(response.incarnation)),
        @as(usize, @as(*const u8, @ptrCast(&response.lifecycle)).*),
    }) |value| hasher.update(std.mem.asBytes(&value));
    const digest = hasher.final();
    return if (digest == 0) 1 else digest;
}

fn rangesOverlapTyped(a: anytype, b: anytype) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    const a_end = std.math.add(usize, a_start, @sizeOf(@TypeOf(a.*))) catch return true;
    const b_end = std.math.add(usize, b_start, @sizeOf(@TypeOf(b.*))) catch return true;
    return a_start < b_end and b_start < a_end;
}

const ResponseReentrantFreeAllocator = struct {
    const OwnerDrift = enum { none, response_addr, response_digest, incarnation, lifecycle, terminal_digest };

    parent: std.mem.Allocator,
    target: ?*ExecutedResponse = null,
    target_owner: ?*contract.ExecutedResponseOwnerSeal = null,
    armed: bool = false,
    reentered: bool = false,
    free_calls: usize = 0,
    nested_outcome: ?DeinitOutcome = null,
    owner_drift: OwnerDrift = .none,

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
        if (self.target_owner) |owner| switch (self.owner_drift) {
            .none => {},
            .response_addr => owner.response_addr +%= 1,
            .response_digest => owner.response_digest +%= 1,
            .incarnation => owner.incarnation +%= 1,
            .lifecycle => owner.lifecycle = .live,
            .terminal_digest => owner.terminal_digest +%= 1,
        };
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

fn testAllocationProvenance(generation: u64) AllocationProvenance {
    return .{
        .guard_addr = 0x101,
        .node_addr = 0x102,
        .operation_incarnation = 0x103,
        .generation = generation,
    };
}

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
    try response.initAcceptedFromPromotedInPlace(
        probe.allocator(),
        &owner,
        61,
        correlated,
        bytes,
        testAllocationProvenance(61),
    );
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

    try response.initAcceptedFromPromotedInPlace(
        std.testing.allocator,
        &response_owner,
        11,
        correlated,
        bytes,
        testAllocationProvenance(11),
    );
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
        response.initAcceptedFromPromotedInPlace(
            std.testing.allocator,
            &response_owner,
            43,
            correlated,
            bytes,
            testAllocationProvenance(43),
        ),
    );
    try std.testing.expect(response.pristine());
}

test "CR3a-2a response and owner lifecycle raw discriminators fail closed exhaustively" {
    var response_raw: [@sizeOf(ExecutedResponse)]u8 align(@alignOf(ExecutedResponse)) =
        [_]u8{0} ** @sizeOf(ExecutedResponse);
    const response: *ExecutedResponse = @ptrCast(&response_raw);
    var owner_raw: [@sizeOf(contract.ExecutedResponseOwnerSeal)]u8 align(@alignOf(contract.ExecutedResponseOwnerSeal)) =
        [_]u8{0} ** @sizeOf(contract.ExecutedResponseOwnerSeal);
    const owner: *contract.ExecutedResponseOwnerSeal = @ptrCast(&owner_raw);

    for (0..256) |value| {
        response_raw[@offsetOf(ExecutedResponse, "lifecycle")] = @intCast(value);
        const response_valid = value <= @intFromEnum(contract.ExecutedResponseLifecycle.terminal);
        try std.testing.expectEqual(response_valid, response.lifecycleRawValid());
        if (!response_valid) {
            try std.testing.expect(!response.canInitializeWithOwner(owner));
            try std.testing.expectError(error.Corrupt, response.borrowAccepted(owner));
            try std.testing.expectEqual(DeinitOutcome.corrupt, response.deinit(owner));
        }
    }

    response_raw = [_]u8{0} ** @sizeOf(ExecutedResponse);
    for (0..256) |value| {
        owner_raw[@offsetOf(contract.ExecutedResponseOwnerSeal, "lifecycle")] = @intCast(value);
        const owner_valid = value <= @intFromEnum(contract.ExecutedResponseOwnerLifecycle.terminal);
        try std.testing.expectEqual(owner_valid, owner.lifecycleRawValid());
        if (!owner_valid) {
            try std.testing.expect(!response.canInitializeWithOwner(owner));
            try std.testing.expect(!owner.valid(1));
            try std.testing.expect(!owner.settledExact());
            try std.testing.expectError(error.InvalidState, owner.terminalize(1));
        }
    }
}

test "CR3a-2a pristine response rejects every nonzero storage byte without typed projection" {
    var raw: [@sizeOf(ExecutedResponse)]u8 align(@alignOf(ExecutedResponse)) =
        [_]u8{0} ** @sizeOf(ExecutedResponse);
    const response: *ExecutedResponse = @ptrCast(&raw);
    var owner: contract.ExecutedResponseOwnerSeal = .{};
    for (0..raw.len) |offset| {
        raw[offset] = 0xff;
        try std.testing.expect(!response.canInitializeWithOwner(&owner));
        raw[offset] = 0;
    }
}

test "CR3a-2a accepted response authenticates every scalar before payload or allocator access" {
    const prepared = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 71,
        .request_id = 73,
        .request_digest = 79,
    }).?;
    const correlated = contract.CorrelatedExecutedCall.init(
        contract.ExecutedCallReceipt.fromPrepared(prepared).?,
        prepared.request_id,
    ).?;
    const bytes = try std.testing.allocator.dupe(u8, "sealed-response");
    var owner: contract.ExecutedResponseOwnerSeal = .{};
    var response: ExecutedResponse = .{};
    try response.initAcceptedFromPromotedInPlace(
        std.testing.allocator,
        &owner,
        83,
        correlated,
        bytes,
        testAllocationProvenance(83),
    );

    const Field = enum {
        result_present,
        result_tag,
        executed_transport_incarnation,
        executed_request_id,
        executed_request_digest,
        correlation_request_id,
        payload_digest,
        allocator_present,
        allocator_ptr,
        allocator_vtable,
        owned_addr,
        owned_len,
    };
    inline for (std.enums.values(Field)) |field| {
        var forged = response;
        switch (field) {
            .result_present => forged.result_present = 0xff,
            .result_tag => forged.result_tag = 0xff,
            .executed_transport_incarnation => forged.executed_transport_incarnation +%= 1,
            .executed_request_id => forged.executed_request_id +%= 1,
            .executed_request_digest => forged.executed_request_digest +%= 1,
            .correlation_request_id => forged.correlation_request_id +%= 1,
            .payload_digest => forged.payload_digest +%= 1,
            .allocator_present => forged.allocator_present = 0xff,
            .allocator_ptr => forged.allocator_ptr = 1,
            .allocator_vtable => forged.allocator_vtable = 1,
            .owned_addr => forged.owned_addr = 1,
            .owned_len => forged.owned_len = max_owned_response_bytes,
        }
        try std.testing.expectError(error.Corrupt, forged.borrowAccepted(&owner));
        try std.testing.expectEqual(DeinitOutcome.corrupt, forged.deinit(&owner));
    }
    try std.testing.expectEqual(DeinitOutcome.cleaned, response.deinit(&owner));
}

test "CR3a-2a forged terminal lifecycle cannot bypass live response cleanup authority" {
    const prepared = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 89,
        .request_id = 97,
        .request_digest = 101,
    }).?;
    const correlated = contract.CorrelatedExecutedCall.init(
        contract.ExecutedCallReceipt.fromPrepared(prepared).?,
        prepared.request_id,
    ).?;
    const bytes = try std.testing.allocator.dupe(u8, "live-response");
    var owner: contract.ExecutedResponseOwnerSeal = .{};
    var response: ExecutedResponse = .{};
    try response.initAcceptedFromPromotedInPlace(
        std.testing.allocator,
        &owner,
        103,
        correlated,
        bytes,
        testAllocationProvenance(103),
    );

    var forged = response;
    forged.lifecycle = .terminal;
    try std.testing.expectEqual(DeinitOutcome.corrupt, forged.deinit(&owner));
    try std.testing.expectEqual(DeinitOutcome.cleaned, response.deinit(&owner));
    var pristine_owner: contract.ExecutedResponseOwnerSeal = .{};
    try std.testing.expectEqual(DeinitOutcome.corrupt, response.deinit(&pristine_owner));
    var drifted_terminal = response;
    drifted_terminal.terminal_digest +%= 1;
    try std.testing.expect(!drifted_terminal.terminalTombstoneExact());
    try std.testing.expectEqual(DeinitOutcome.corrupt, drifted_terminal.deinit(&owner));
    try std.testing.expectEqual(DeinitOutcome.already_terminal, response.deinit(&owner));
}

test "CR3a-2a response free callback owner drift cannot publish settled cleanup" {
    inline for (.{
        ResponseReentrantFreeAllocator.OwnerDrift.response_addr,
        .response_digest,
        .incarnation,
        .lifecycle,
        .terminal_digest,
    }) |drift| {
        var probe = ResponseReentrantFreeAllocator{
            .parent = std.testing.allocator,
            .owner_drift = drift,
        };
        const prepared = contract.PreparedCallReceipt.init(.{
            .transport_incarnation = 107,
            .request_id = 109,
            .request_digest = 113,
        }).?;
        const correlated = contract.CorrelatedExecutedCall.init(
            contract.ExecutedCallReceipt.fromPrepared(prepared).?,
            prepared.request_id,
        ).?;
        const bytes = try probe.allocator().dupe(u8, "owner-drift");
        var owner: contract.ExecutedResponseOwnerSeal = .{};
        var response: ExecutedResponse = .{};
        try response.initAcceptedFromPromotedInPlace(
            probe.allocator(),
            &owner,
            127,
            correlated,
            bytes,
            testAllocationProvenance(127),
        );
        probe.target_owner = &owner;
        try std.testing.expectEqual(DeinitOutcome.corrupt, response.deinit(&owner));
        try std.testing.expectEqual(@as(usize, 1), probe.free_calls);
        try std.testing.expect(!owner.settledExact());
    }
}
