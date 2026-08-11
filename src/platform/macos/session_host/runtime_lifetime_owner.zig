//! Inline final-address lifetime authority for staged RemoteRuntime preparation.
//!
//! The row is authenticated before any typed state decision.  It intentionally reserves close
//! and reader fields now, while this slice permits only idle <-> exclusive preparation.

const std = @import("std");
const builtin = @import("builtin");
const seal_types = @import("event_cleanup_seal.zig");
const process_seal = @import("process_seal_service.zig");
const settlement = @import("pending_event_settlement_contract.zig");

pub const State = enum(u8) { idle = 0, exclusive_active = 1, closing = 2 };
pub const OperationKind = enum(u8) { none = 0, preparation = 1, close = 2, settlement = 3 };

pub const AcquireError = error{ Busy, InvalidOwner };
const SettlementContention = struct {
    remaining: usize = 0,
    fn consume(self: *SettlementContention) bool {
        if (self.remaining == 0) return false;
        self.remaining -= 1;
        return true;
    }
};
threadlocal var settlement_contention: if (builtin.is_test) SettlementContention else void =
    if (builtin.is_test) .{} else {};

pub const RuntimeOperationLease = struct {
    lifetime_owner_addr: u64 = 0,
    runtime_addr: u64 = 0,
    pending_owner_addr: u64 = 0,
    pid: u32 = 0,
    reserved_pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    owner_incarnation: u64 = 0,
    operation_incarnation: u64 = 0,
    operation_kind_raw: u8 = 0,
    consumed_raw: u8 = 0,
    reserved: [6]u8 = [_]u8{0} ** 6,
    operation_seal: seal_types.CleanupSeal = [_]u8{0} ** 32,

    pub fn identity(self: RuntimeOperationLease) seal_types.RuntimeOperationIdentity {
        return .{
            .lifetime_owner_addr = self.lifetime_owner_addr,
            .runtime_addr = self.runtime_addr,
            .pending_owner_addr = self.pending_owner_addr,
            .pid = self.pid,
            .reserved_pid = self.reserved_pid,
            .process_nonce = self.process_nonce,
            .thread_id = self.thread_id,
            .owner_incarnation = self.owner_incarnation,
            .operation_incarnation = self.operation_incarnation,
            .operation_kind_raw = self.operation_kind_raw,
            .operation_seal = self.operation_seal,
        };
    }
};

pub const RuntimeSettlementLease = struct {
    self_addr: u64 = 0,
    lifecycle_raw: u8 = 0,
    reserved: [7]u8 = [_]u8{0} ** 7,
    operation: RuntimeOperationLease = .{},
    ranges_digest: settlement.Digest = settlement.zero_digest,
    pristine_digest: settlement.Digest = settlement.zero_digest,
    preflight_proof_seal_digest: settlement.Digest = settlement.zero_digest,
    lease_seal: settlement.Digest = settlement.zero_digest,
};

const SettlementLifecycle = enum(u8) { pristine = 0, prepared = 1, admitted = 2, consumed = 3 };

pub const RuntimeLifetimeOwner = struct {
    state_raw: u8 = 0,
    operation_kind_raw: u8 = 0,
    reader_count: u16 = 0,
    reserved: [4]u8 = [_]u8{0} ** 4,
    self_addr: u64 = 0,
    runtime_addr: u64 = 0,
    pending_owner_addr: u64 = 0,
    pid: u32 = 0,
    reserved_pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    owner_incarnation: u64 = 0,
    next_operation_incarnation: u64 = 0,
    active_operation_incarnation: u64 = 0,
    close_generation: u64 = 0,
    operation_seal: seal_types.CleanupSeal = [_]u8{0} ** 32,

    pub fn currentProcessDomainMatches(self: *const RuntimeLifetimeOwner) bool {
        return self.pid == process_seal.currentProcessId() and
            self.thread_id == @as(u64, @intCast(std.Thread.getCurrentId()));
    }

    pub fn initInPlace(
        self: *RuntimeLifetimeOwner,
        runtime_addr: u64,
        pending_owner_addr: u64,
        process_nonce: u64,
        owner_incarnation: u64,
    ) process_seal.ReadyError!void {
        const pid = process_seal.currentProcessId();
        if (!self.pristine() or runtime_addr == 0 or pending_owner_addr == 0 or
            process_nonce == 0 or owner_incarnation == 0) return error.ProcessDomainMismatch;
        // Readiness is the only fallible step.  Constructors therefore still see a pristine row
        // on recoverable failure, and publication below is a callback-free no-fail suffix.
        try process_seal.validateReady(pid, process_nonce);
        self.* = .{
            .self_addr = @intFromPtr(self),
            .runtime_addr = runtime_addr,
            .pending_owner_addr = pending_owner_addr,
            .pid = pid,
            .process_nonce = process_nonce,
            .thread_id = @intCast(std.Thread.getCurrentId()),
            .owner_incarnation = owner_incarnation,
            .next_operation_incarnation = 1,
        };
        self.operation_seal = process_seal.pendingOperationSeal(
            pid,
            process_nonce,
            self.sealInput(),
        ) catch process_seal.fatalIntegrity(.invalid_runtime_lifetime);
    }

    pub fn preflightPreparation(self: *const RuntimeLifetimeOwner) AcquireError!seal_types.RuntimeOperationPreflight {
        if (!self.validRawAndSeal()) return error.InvalidOwner;
        if (self.state_raw != @intFromEnum(State.idle)) return error.Busy;
        if (self.next_operation_incarnation == std.math.maxInt(u64))
            process_seal.fatalIntegrity(.counter_exhausted);
        return .{
            .lifetime_owner_addr = self.self_addr,
            .runtime_addr = self.runtime_addr,
            .pending_owner_addr = self.pending_owner_addr,
            .pid = self.pid,
            .reserved_pid = self.reserved_pid,
            .process_nonce = self.process_nonce,
            .thread_id = self.thread_id,
            .owner_incarnation = self.owner_incarnation,
            .expected_next_operation = self.next_operation_incarnation,
            .expected_operation_seal = self.operation_seal,
        };
    }

    pub fn acquirePreparation(
        self: *RuntimeLifetimeOwner,
        preflight: seal_types.RuntimeOperationPreflight,
    ) AcquireError!RuntimeOperationLease {
        if (!self.validRawAndSeal() or !preflightMatches(self, preflight)) return error.InvalidOwner;
        if (self.state_raw != @intFromEnum(State.idle)) return error.Busy;
        const incarnation = self.next_operation_incarnation;
        if (incarnation == 0 or incarnation == std.math.maxInt(u64))
            process_seal.fatalIntegrity(.counter_exhausted);
        self.next_operation_incarnation = incarnation + 1;
        self.active_operation_incarnation = incarnation;
        self.state_raw = @intFromEnum(State.exclusive_active);
        self.operation_kind_raw = @intFromEnum(OperationKind.preparation);
        self.operation_seal = process_seal.pendingOperationSeal(
            self.pid,
            self.process_nonce,
            self.sealInput(),
        ) catch process_seal.fatalIntegrity(.invalid_runtime_lifetime);
        return .{
            .lifetime_owner_addr = self.self_addr,
            .runtime_addr = self.runtime_addr,
            .pending_owner_addr = self.pending_owner_addr,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
            .thread_id = self.thread_id,
            .owner_incarnation = self.owner_incarnation,
            .operation_incarnation = incarnation,
            .operation_kind_raw = @intFromEnum(OperationKind.preparation),
            .operation_seal = self.operation_seal,
        };
    }

    /// Commits a previously validated preflight after the external event registry has entered
    /// preparation_pending.  Returning an error here would strand that canonical blocker, so any
    /// drift is proof loss and terminates through the process-wide integrity leaf.
    pub fn acquirePreparationNoFail(
        self: *RuntimeLifetimeOwner,
        preflight: seal_types.RuntimeOperationPreflight,
    ) RuntimeOperationLease {
        return self.acquirePreparation(preflight) catch
            process_seal.fatalIntegrity(.invalid_runtime_lifetime);
    }

    pub fn acquireSettlement(
        self: *RuntimeLifetimeOwner,
        out: *RuntimeSettlementLease,
        proof: settlement.SettlementScratchPreflightProof,
    ) AcquireError!settlement.RuntimeSettlementLeaseBinding {
        if (builtin.is_test and settlement_contention.consume()) return error.Busy;
        if (!self.validRawAndSeal() or !settlementLeasePristine(out) or
            !settlement.validScratchPreflightProof(proof) or proof.pid != self.pid or
            proof.process_nonce != self.process_nonce or proof.thread_id != self.thread_id)
            return error.InvalidOwner;
        if (self.state_raw != @intFromEnum(State.idle)) return error.Busy;
        const incarnation = self.next_operation_incarnation;
        if (incarnation == 0 or incarnation == std.math.maxInt(u64))
            process_seal.fatalIntegrity(.counter_exhausted);

        self.next_operation_incarnation = incarnation + 1;
        self.active_operation_incarnation = incarnation;
        self.state_raw = @intFromEnum(State.exclusive_active);
        self.operation_kind_raw = @intFromEnum(OperationKind.settlement);
        self.operation_seal = process_seal.pendingOperationSeal(
            self.pid,
            self.process_nonce,
            self.sealInput(),
        ) catch process_seal.fatalIntegrity(.invalid_runtime_lifetime);

        out.self_addr = @intFromPtr(out);
        out.operation = self.operationReceipt(incarnation, .settlement);
        out.ranges_digest = proof.ranges_digest;
        out.pristine_digest = proof.pristine_digest;
        out.preflight_proof_seal_digest = digestValue(proof.proof_seal);
        out.lease_seal = settlement.sealRuntimeSettlementLease(
            self.pid,
            self.process_nonce,
            out.self_addr,
            @sizeOf(RuntimeSettlementLease),
            @alignOf(RuntimeSettlementLease),
            out.operation.identity(),
            out.ranges_digest,
            out.pristine_digest,
            out.preflight_proof_seal_digest,
        ) catch process_seal.fatalIntegrity(.invalid_runtime_lifetime);
        out.lifecycle_raw = @intFromEnum(SettlementLifecycle.prepared);

        var binding: settlement.RuntimeSettlementLeaseBinding = .{
            .lease_addr = out.self_addr,
            .lifetime_owner_addr = self.self_addr,
            .operation_identity = out.operation.identity(),
            .ranges_digest = out.ranges_digest,
            .pristine_digest = out.pristine_digest,
            .preflight_proof_seal_digest = out.preflight_proof_seal_digest,
            .lease_seal_digest = digestValue(out.lease_seal),
        };
        binding.binding_seal = settlement.sealRuntimeSettlementBinding(binding) catch
            process_seal.fatalIntegrity(.invalid_runtime_lifetime);
        return binding;
    }

    pub fn abortSettlementPreAdmissionNoFail(self: *RuntimeLifetimeOwner, lease: *RuntimeSettlementLease) void {
        self.finishSettlement(lease, .prepared);
    }

    pub fn consumeSettlementNoFail(self: *RuntimeLifetimeOwner, lease: *RuntimeSettlementLease) void {
        self.finishSettlement(lease, .admitted);
    }

    pub fn validateSettlement(self: *const RuntimeLifetimeOwner, lease: *const RuntimeSettlementLease) bool {
        return self.validateSettlementAtLifecycle(lease, .prepared);
    }

    pub fn validatePreparedSettlementBinding(
        self: *const RuntimeLifetimeOwner,
        lease: *const RuntimeSettlementLease,
        binding: settlement.RuntimeSettlementLeaseBinding,
    ) bool {
        return self.validateSettlementBindingAtLifecycle(lease, binding, .prepared);
    }

    pub fn admitSettlementNoFail(
        self: *RuntimeLifetimeOwner,
        lease: *RuntimeSettlementLease,
        binding: settlement.RuntimeSettlementLeaseBinding,
    ) void {
        if (!self.validateSettlementBindingAtLifecycle(lease, binding, .prepared))
            process_seal.fatalIntegrity(.invalid_runtime_lifetime);
        lease.lifecycle_raw = @intFromEnum(SettlementLifecycle.admitted);
    }

    pub fn validateAdmittedSettlementBinding(
        self: *const RuntimeLifetimeOwner,
        lease: *const RuntimeSettlementLease,
        binding: settlement.RuntimeSettlementLeaseBinding,
    ) bool {
        return self.validateSettlementBindingAtLifecycle(lease, binding, .admitted);
    }

    fn validateSettlementAtLifecycle(
        self: *const RuntimeLifetimeOwner,
        lease: *const RuntimeSettlementLease,
        lifecycle: SettlementLifecycle,
    ) bool {
        if (!self.validRawAndSeal() or lease.self_addr != @intFromPtr(lease) or
            lease.lifecycle_raw != @intFromEnum(lifecycle) or
            !std.mem.allEqual(u8, &lease.reserved, 0) or lease.operation.consumed_raw != 0 or
            !std.mem.allEqual(u8, &lease.operation.reserved, 0) or
            self.operation_kind_raw != @intFromEnum(OperationKind.settlement) or
            !operationReceiptMatches(self, &lease.operation, .settlement)) return false;
        const expected = settlement.sealRuntimeSettlementLease(
            self.pid,
            self.process_nonce,
            lease.self_addr,
            @sizeOf(RuntimeSettlementLease),
            @alignOf(RuntimeSettlementLease),
            lease.operation.identity(),
            lease.ranges_digest,
            lease.pristine_digest,
            lease.preflight_proof_seal_digest,
        ) catch return false;
        return std.crypto.timing_safe.eql(settlement.Digest, expected, lease.lease_seal);
    }

    fn validateSettlementBindingAtLifecycle(
        self: *const RuntimeLifetimeOwner,
        lease: *const RuntimeSettlementLease,
        binding: settlement.RuntimeSettlementLeaseBinding,
        lifecycle: SettlementLifecycle,
    ) bool {
        if (!self.validateSettlementAtLifecycle(lease, lifecycle) or
            !settlement.validRuntimeSettlementBinding(binding)) return false;
        return binding.lease_addr == lease.self_addr and binding.lifetime_owner_addr == self.self_addr and
            std.meta.eql(binding.operation_identity, lease.operation.identity()) and
            std.crypto.timing_safe.eql(settlement.Digest, binding.ranges_digest, lease.ranges_digest) and
            std.crypto.timing_safe.eql(settlement.Digest, binding.pristine_digest, lease.pristine_digest) and
            std.crypto.timing_safe.eql(settlement.Digest, binding.preflight_proof_seal_digest, lease.preflight_proof_seal_digest) and
            std.crypto.timing_safe.eql(settlement.Digest, binding.lease_seal_digest, digestValue(lease.lease_seal));
    }

    pub fn validateAfterCallback(
        self: *const RuntimeLifetimeOwner,
        lease: *const RuntimeOperationLease,
    ) bool {
        // A fork must be rejected before inherited row or secret material is consulted.
        if (process_seal.currentProcessId() != lease.pid) return false;
        if (!self.validRawAndSeal() or lease.consumed_raw != 0 or
            !std.mem.allEqual(u8, &lease.reserved, 0)) return false;
        return self.state_raw == @intFromEnum(State.exclusive_active) and
            self.operation_kind_raw == @intFromEnum(OperationKind.preparation) and
            lease.lifetime_owner_addr == self.self_addr and lease.runtime_addr == self.runtime_addr and
            lease.pending_owner_addr == self.pending_owner_addr and lease.pid == self.pid and
            lease.reserved_pid == 0 and lease.process_nonce == self.process_nonce and
            lease.thread_id == self.thread_id and lease.thread_id == @as(u64, @intCast(std.Thread.getCurrentId())) and
            lease.owner_incarnation == self.owner_incarnation and
            lease.operation_incarnation == self.active_operation_incarnation and
            lease.operation_kind_raw == self.operation_kind_raw and
            std.crypto.timing_safe.eql(seal_types.CleanupSeal, lease.operation_seal, self.operation_seal);
    }

    pub fn consume(self: *RuntimeLifetimeOwner, lease: *RuntimeOperationLease) void {
        self.finish(lease);
    }

    pub fn abort(self: *RuntimeLifetimeOwner, lease: *RuntimeOperationLease) void {
        self.finish(lease);
    }

    fn finish(self: *RuntimeLifetimeOwner, lease: *RuntimeOperationLease) void {
        if (!self.validateAfterCallback(lease))
            process_seal.fatalIntegrity(.invalid_runtime_lifetime);
        self.state_raw = @intFromEnum(State.idle);
        self.operation_kind_raw = @intFromEnum(OperationKind.none);
        self.active_operation_incarnation = 0;
        self.operation_seal = process_seal.pendingOperationSeal(
            self.pid,
            self.process_nonce,
            self.sealInput(),
        ) catch process_seal.fatalIntegrity(.invalid_runtime_lifetime);
        lease.consumed_raw = 1;
    }

    fn finishSettlement(
        self: *RuntimeLifetimeOwner,
        lease: *RuntimeSettlementLease,
        lifecycle: SettlementLifecycle,
    ) void {
        if (!self.validateSettlementAtLifecycle(lease, lifecycle))
            process_seal.fatalIntegrity(.invalid_runtime_lifetime);
        self.finishOperation(&lease.operation);
        lease.lifecycle_raw = @intFromEnum(SettlementLifecycle.consumed);
    }

    fn finishOperation(self: *RuntimeLifetimeOwner, lease: *RuntimeOperationLease) void {
        self.state_raw = @intFromEnum(State.idle);
        self.operation_kind_raw = @intFromEnum(OperationKind.none);
        self.active_operation_incarnation = 0;
        self.operation_seal = process_seal.pendingOperationSeal(
            self.pid,
            self.process_nonce,
            self.sealInput(),
        ) catch process_seal.fatalIntegrity(.invalid_runtime_lifetime);
        lease.consumed_raw = 1;
    }

    fn operationReceipt(self: *const RuntimeLifetimeOwner, incarnation: u64, kind: OperationKind) RuntimeOperationLease {
        return .{
            .lifetime_owner_addr = self.self_addr,
            .runtime_addr = self.runtime_addr,
            .pending_owner_addr = self.pending_owner_addr,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
            .thread_id = self.thread_id,
            .owner_incarnation = self.owner_incarnation,
            .operation_incarnation = incarnation,
            .operation_kind_raw = @intFromEnum(kind),
            .operation_seal = self.operation_seal,
        };
    }

    fn pristine(self: *const RuntimeLifetimeOwner) bool {
        // Do not inspect struct padding: it is not semantic state and may be undefined.
        return self.state_raw == 0 and self.operation_kind_raw == 0 and self.reader_count == 0 and
            std.mem.allEqual(u8, &self.reserved, 0) and self.self_addr == 0 and
            self.runtime_addr == 0 and self.pending_owner_addr == 0 and self.pid == 0 and
            self.reserved_pid == 0 and self.process_nonce == 0 and self.thread_id == 0 and
            self.owner_incarnation == 0 and self.next_operation_incarnation == 0 and
            self.active_operation_incarnation == 0 and self.close_generation == 0 and
            std.mem.allEqual(u8, &self.operation_seal, 0);
    }

    fn sealInput(self: *const RuntimeLifetimeOwner) seal_types.PendingOperationSealInput {
        return .{
            .state_raw = self.state_raw,
            .operation_kind_raw = self.operation_kind_raw,
            .reader_count = self.reader_count,
            .reserved = self.reserved,
            .self_addr = self.self_addr,
            .runtime_addr = self.runtime_addr,
            .pending_owner_addr = self.pending_owner_addr,
            .pid = self.pid,
            .reserved_pid = self.reserved_pid,
            .process_nonce = self.process_nonce,
            .thread_id = self.thread_id,
            .owner_incarnation = self.owner_incarnation,
            .next_operation_incarnation = self.next_operation_incarnation,
            .active_operation_incarnation = self.active_operation_incarnation,
            .close_generation = self.close_generation,
        };
    }

    fn validRawAndSeal(self: *const RuntimeLifetimeOwner) bool {
        if (process_seal.currentProcessId() != self.pid or
            self.self_addr != @intFromPtr(self) or self.runtime_addr == 0 or
            self.pending_owner_addr == 0 or self.process_nonce == 0 or self.thread_id == 0 or
            self.thread_id != @as(u64, @intCast(std.Thread.getCurrentId())) or
            self.owner_incarnation == 0 or self.next_operation_incarnation == 0 or
            self.reserved_pid != 0 or !std.mem.allEqual(u8, &self.reserved, 0) or
            self.reader_count != 0 or self.close_generation != 0 or self.state_raw > 2 or
            self.operation_kind_raw > 3) return false;
        const shape_ok = (self.state_raw == 0 and self.operation_kind_raw == 0 and self.active_operation_incarnation == 0) or
            (self.state_raw == 1 and
                (self.operation_kind_raw == @intFromEnum(OperationKind.preparation) or
                    self.operation_kind_raw == @intFromEnum(OperationKind.settlement)) and
                self.active_operation_incarnation != 0);
        // 이 owner는 closing/close를 authorize하지 못하며 이후 lifecycle owner가 따로 mint해야 한다.
        if (!shape_ok) return false;
        const expected = process_seal.pendingOperationSeal(
            self.pid,
            self.process_nonce,
            self.sealInput(),
        ) catch return false;
        return std.crypto.timing_safe.eql(seal_types.CleanupSeal, expected, self.operation_seal);
    }

    fn forceNextForTest(self: *RuntimeLifetimeOwner, value: u64) void {
        if (!@import("builtin").is_test) unreachable;
        self.next_operation_incarnation = value;
        self.operation_seal = process_seal.pendingOperationSeal(
            self.pid,
            self.process_nonce,
            self.sealInput(),
        ) catch process_seal.fatalIntegrity(.invalid_runtime_lifetime);
    }
};

pub const testing = if (builtin.is_test) struct {
    pub fn armSettlementContention(count: usize) void {
        if (settlement_contention.remaining != 0) @panic("settlement contention seam replayed");
        settlement_contention.remaining = count;
    }
} else struct {};

fn preflightMatches(owner: *const RuntimeLifetimeOwner, value: seal_types.RuntimeOperationPreflight) bool {
    return value.lifetime_owner_addr == owner.self_addr and value.runtime_addr == owner.runtime_addr and
        value.pending_owner_addr == owner.pending_owner_addr and value.pid == owner.pid and
        value.reserved_pid == 0 and value.process_nonce == owner.process_nonce and
        value.thread_id == owner.thread_id and value.owner_incarnation == owner.owner_incarnation and
        value.expected_next_operation == owner.next_operation_incarnation and
        std.crypto.timing_safe.eql(seal_types.CleanupSeal, value.expected_operation_seal, owner.operation_seal);
}

fn settlementLeasePristine(lease: *const RuntimeSettlementLease) bool {
    return lease.self_addr == 0 and lease.lifecycle_raw == 0 and
        std.mem.allEqual(u8, &lease.reserved, 0) and
        std.meta.eql(lease.operation, RuntimeOperationLease{}) and
        std.mem.allEqual(u8, &lease.ranges_digest, 0) and
        std.mem.allEqual(u8, &lease.pristine_digest, 0) and
        std.mem.allEqual(u8, &lease.preflight_proof_seal_digest, 0) and
        std.mem.allEqual(u8, &lease.lease_seal, 0);
}

fn operationReceiptMatches(
    owner: *const RuntimeLifetimeOwner,
    lease: *const RuntimeOperationLease,
    kind: OperationKind,
) bool {
    return process_seal.currentProcessId() == lease.pid and
        owner.state_raw == @intFromEnum(State.exclusive_active) and
        lease.lifetime_owner_addr == owner.self_addr and lease.runtime_addr == owner.runtime_addr and
        lease.pending_owner_addr == owner.pending_owner_addr and lease.pid == owner.pid and
        lease.reserved_pid == 0 and lease.process_nonce == owner.process_nonce and
        lease.thread_id == owner.thread_id and lease.thread_id == @as(u64, @intCast(std.Thread.getCurrentId())) and
        lease.owner_incarnation == owner.owner_incarnation and
        lease.operation_incarnation == owner.active_operation_incarnation and
        lease.operation_kind_raw == @intFromEnum(kind) and lease.operation_kind_raw == owner.operation_kind_raw and
        std.crypto.timing_safe.eql(seal_types.CleanupSeal, lease.operation_seal, owner.operation_seal);
}

fn digestValue(value: settlement.Digest) settlement.Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(&value);
    var result: settlement.Digest = undefined;
    hasher.final(&result);
    return result;
}

comptime {
    if (@alignOf(RuntimeLifetimeOwner) > 16 or @sizeOf(RuntimeLifetimeOwner) > 256)
        @compileError("RuntimeLifetimeOwner exceeds its inline budget");
}

test "C3-3b2b3 runtime lifetime owner seals exclusive preparation exact once" {
    const ready_identity: ?process_seal.ReadyIdentity = process_seal.currentReadyIdentity() catch |err| switch (err) {
        error.NotReady => null,
        else => return err,
    };
    // The focused module starts with a fresh seal service and proves the real overflow death path.
    // The aggregate suite may already own a different canonical nonce; it must reuse that domain
    // rather than pretending a fork can reinitialize PID-bound inherited authority.
    if (ready_identity == null and
        (@import("builtin").os.tag == .macos or @import("builtin").os.tag == .linux))
    {
        const overflow_child = std.c.fork();
        if (overflow_child < 0) return error.TestUnexpectedResult;
        if (overflow_child == 0) {
            const child_pid = process_seal.currentProcessId();
            const child_nonce: u64 = 0xaabb_ccdd;
            var child_owner: RuntimeLifetimeOwner = .{};
            child_owner.initInPlace(0x1000, 0x2000, child_nonce, 1) catch |err| switch (err) {
                error.NotReady => {},
                else => std.c._exit(125),
            };
            if (!child_owner.pristine()) std.c._exit(125);
            const child_ready = process_seal.prepare(child_pid, child_nonce) catch std.c._exit(125);
            process_seal.commitReady(child_ready);
            child_owner.initInPlace(0x1000, 0x2000, child_nonce, 1) catch std.c._exit(125);
            child_owner.forceNextForTest(std.math.maxInt(u64));
            _ = child_owner.preflightPreparation() catch std.c._exit(124);
            std.c._exit(123);
        }
        var overflow_status: c_int = 0;
        try std.testing.expectEqual(overflow_child, std.c.waitpid(overflow_child, &overflow_status, 0));
        const overflow_unsigned: u32 = @bitCast(overflow_status);
        try std.testing.expect(std.c.W.IFEXITED(overflow_unsigned));
        try std.testing.expectEqual(@as(u8, 86), @as(u8, @intCast(std.c.W.EXITSTATUS(overflow_unsigned))));
    }

    const pid = process_seal.currentProcessId();
    const nonce: u64 = if (ready_identity) |identity|
        identity.process_nonce
    else
        0x1122_3344_5566_7788;
    if (ready_identity == null) {
        const ready = try process_seal.prepare(pid, nonce);
        process_seal.commitReady(ready);
    }

    var owner: RuntimeLifetimeOwner = .{};
    try owner.initInPlace(0x1000, 0x2000, nonce, 7);
    const stale_preflight = try owner.preflightPreparation();
    var lease = try owner.acquirePreparation(stale_preflight);
    try std.testing.expect(owner.validateAfterCallback(&lease));
    try std.testing.expectError(error.Busy, owner.preflightPreparation());

    var copied_owner = owner;
    try std.testing.expect(!copied_owner.validateAfterCallback(&lease));
    var copied_lease = lease;
    copied_lease.operation_incarnation += 1;
    try std.testing.expect(!owner.validateAfterCallback(&copied_lease));

    owner.consume(&lease);
    try std.testing.expectEqual(@as(u8, 1), lease.consumed_raw);
    try std.testing.expect(!owner.validateAfterCallback(&lease));
    try std.testing.expectError(error.InvalidOwner, owner.acquirePreparation(stale_preflight));

    const next_preflight = try owner.preflightPreparation();
    var next_lease = try owner.acquirePreparation(next_preflight);
    try std.testing.expectEqual(@as(u64, 2), next_lease.operation_incarnation);
    owner.abort(&next_lease);

    if (@import("builtin").os.tag == .macos or @import("builtin").os.tag == .linux) {
        const fork_child = std.c.fork();
        if (fork_child < 0) return error.TestUnexpectedResult;
        if (fork_child == 0) {
            _ = owner.preflightPreparation() catch |err| switch (err) {
                error.InvalidOwner => std.c._exit(0),
                else => std.c._exit(124),
            };
            std.c._exit(123);
        }
        var fork_status: c_int = 0;
        try std.testing.expectEqual(fork_child, std.c.waitpid(fork_child, &fork_status, 0));
        const fork_unsigned: u32 = @bitCast(fork_status);
        try std.testing.expect(std.c.W.IFEXITED(fork_unsigned));
        try std.testing.expectEqual(@as(u8, 0), @as(u8, @intCast(std.c.W.EXITSTATUS(fork_unsigned))));
    }

    // All five inputs use independent typed domains even when their scalar material is zero.
    const operation = try process_seal.pendingOperationSeal(pid, nonce, .{
        .state_raw = 0,
        .operation_kind_raw = 0,
        .reader_count = 0,
        .reserved = [_]u8{0} ** 4,
        .self_addr = 0,
        .runtime_addr = 0,
        .pending_owner_addr = 0,
        .pid = 0,
        .reserved_pid = 0,
        .process_nonce = 0,
        .thread_id = 0,
        .owner_incarnation = 0,
        .next_operation_incarnation = 0,
        .active_operation_incarnation = 0,
        .close_generation = 0,
    });
    const release = try process_seal.pendingReleaseSeal(pid, nonce, std.mem.zeroes(seal_types.PendingReleaseSealInput));
    const receipt = try process_seal.pendingSourceReceiptSeal(pid, nonce, std.mem.zeroes(seal_types.PendingSourceReceiptSealInput));
    const source = try process_seal.pendingSourceLeaseSeal(pid, nonce, std.mem.zeroes(seal_types.PendingSourceLeaseSealInput));
    const frame = try process_seal.pendingPreparationFrameSeal(pid, nonce, std.mem.zeroes(seal_types.PendingPreparationFrameSealInput));
    const values = [_]seal_types.CleanupSeal{ operation, release, receipt, source, frame };
    for (values, 0..) |left, left_index| for (values, 0..) |right, right_index| {
        if (left_index != right_index)
            try std.testing.expect(!std.mem.eql(u8, &left, &right));
    };
}
