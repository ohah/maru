//! Heap-pinned generation-1 Client owner used by CR3a-1 HostAdapter migration.
//!
//! This module is the only adapter between the transport-neutral cleanup pin and `Client`.  CR3a-1
//! does not mint product leases or switch generations; it establishes the final-address owner that
//! CR3a-2/CR3b can safely target later.

const std = @import("std");
const builtin = @import("builtin");
const client_mod = @import("client.zig");
const lease_mod = @import("connection_lease.zig");
const cleanup_registry_mod = @import("attachment_cleanup_registry.zig");
const batch_registry_mod = @import("generation_batch_registry.zig");
const owner_seal = @import("external_owner_seal.zig");
const contract = @import("generation_attachment_contract.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const compatibility = @import("compatibility.zig");
const socket_server = @import("socket_server.zig");
const ended_purge_quarantine = @import("ended_purge_quarantine.zig");
const prepared_request_authority = @import("prepared_request_authority.zig");
const client_poison = @import("client_poison.zig");
const executed_response_mod = @import("executed_response.zig");
const rpc_response_authority = @import("rpc_response_authority.zig");
const rpc_executed_response = @import("rpc_executed_response.zig");
const response_payload_allocation = @import("response_payload_allocation.zig");

const c = std.c;
var ended_purge_quarantine_registry: ?ended_purge_quarantine.Registry = null;
var process_runtime_pid: std.atomic.Value(u32) = .init(0);
threadlocal var prepared_execution_cleanup_active_addr: usize = 0;
threadlocal var finish_permit_alias_case_for_test: u8 = 0;

test "CR3a-2c2b3b quarantine leaf participates in the session-host gate" {
    _ = ended_purge_quarantine;
}

test "CR3a-2c2b3b process runtime bootstrap is explicit and same-process idempotent" {
    try ClientSlot.initializeProcessRuntime();
    try ClientSlot.initializeProcessRuntime();
}

test "CR3a-2c2b3b fork child rejects bootstrap before inherited issuer mutex" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const ChildCleanup = struct {
        fn terminateAndReap(child_pid: std.c.pid_t) void {
            _ = std.c.kill(child_pid, std.c.SIG.KILL);
            var child_status: c_int = 0;
            while (true) {
                const waited = std.c.waitpid(child_pid, &child_status, 0);
                if (waited == child_pid or
                    (waited < 0 and std.posix.errno(waited) == .CHILD)) return;
                if (waited < 0 and std.posix.errno(waited) == .INTR) continue;
                return;
            }
        }
    };
    try ClientSlot.initializeProcessRuntime();
    while (!issuer_mutex.tryLock()) std.atomic.spinLoopHint();
    const child = std.c.fork();
    if (child < 0) {
        issuer_mutex.unlock();
        return error.TestUnexpectedResult;
    }
    if (child == 0) {
        ClientSlot.initializeProcessRuntime() catch |err|
            std.c._exit(if (err == error.ProcessDomainMismatch) 0 else 2);
        std.c._exit(3);
    }
    defer issuer_mutex.unlock();

    var status: c_int = 0;
    var attempts: usize = 0;
    while (attempts < 2000) : (attempts += 1) {
        const waited = std.c.waitpid(child, &status, std.c.W.NOHANG);
        if (waited == child) {
            const wait_status: u32 = @bitCast(status);
            try std.testing.expect(std.c.W.IFEXITED(wait_status));
            try std.testing.expectEqual(@as(u8, 0), std.c.W.EXITSTATUS(wait_status));
            return;
        }
        if (waited < 0) {
            if (std.posix.errno(waited) == .INTR) continue;
            ChildCleanup.terminateAndReap(child);
            return error.TestUnexpectedResult;
        }
        var delay_fd = std.c.pollfd{ .fd = -1, .events = 0, .revents = 0 };
        _ = std.c.poll(@ptrCast(&delay_fd), 0, 1);
    }
    ChildCleanup.terminateAndReap(child);
    return error.TestUnexpectedResult;
}

fn rawRangesOverlap(a_start: usize, a_end: usize, b_start: usize, b_end: usize) bool {
    return a_start < b_end and b_start < a_end;
}

pub const Lifecycle = enum {
    live,
    deinit_reserved,
    dead,
};

const GenerationGuardedAllocator = struct {
    const max_operation_ranges = 12;
    const OperationRangeInput = struct { start: usize, len: usize };
    const OperationRange = struct { start: usize, end: usize };
    const allocator_vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
    const RequestFreeTestObserver = struct {
        target_addr: usize = 0,
        target_len: usize = 0,
        descriptor_allocator_ptr: usize = 0,
        descriptor_allocator_vtable: usize = 0,
        entry_count: usize = 0,
        descriptor_exact: bool = false,
        cleanup_count: usize = 0,
        guard_inactive: bool = false,
        allocator_scope_restored: bool = false,
        client_scope_restored: bool = false,
        ledger_ended: bool = false,
        cleanup_settled: bool = false,
        inject_pending_before_execute: bool = false,
        pending_frame_addr: usize = 0,
        pending_frame_len: usize = 0,
        pending_injected: bool = false,
        poison_before_execute: bool = false,
        drift_request_before_execute: bool = false,
        force_not_executed: bool = false,
        registered_operation_begin_receipts: [8]u128 = [_]u128{0} ** 8,
        registered_operation_end_receipts: [8]u128 = [_]u128{0} ** 8,
        registered_operation_begin_count: usize = 0,
        registered_operation_end_count: usize = 0,
        registered_operation_active_receipt: u128 = 0,
        registered_operation_receipt_drift: bool = false,
        response_payload_addr: usize = 0,
        response_payload_len: usize = 0,
        cleanup_drift_kind: u8 = 0,
        cleanup_drift_consumed: bool = false,
        rpc_free_reentry_context: ?*anyopaque = null,
        rpc_free_reentry_fn: ?*const fn (*anyopaque) void = null,
        rpc_free_reentry_fired: bool = false,
        rpc_publication_drift_kind: u8 = 0,
        rpc_publication_txn_addr: usize = 0,
        rpc_publication_lease_addr: usize = 0,
        rpc_publication_scope_addr: usize = 0,
        rpc_publication_drift_fired: bool = false,
    };

    parent: std.mem.Allocator,
    client: ?*client_mod.Client = null,
    node_start: usize,
    node_end: usize,
    slot_start: usize,
    slot_end: usize,
    source_start: usize,
    source_end: usize,
    snapshot_owner_start: usize = 0,
    snapshot_owner_end: usize = 0,
    snapshot_out_start: usize = 0,
    snapshot_out_end: usize = 0,
    snapshot_guard_active: bool = false,
    snapshot_alias_rejected: bool = false,
    operation_ranges: [max_operation_ranges]OperationRange = undefined,
    operation_range_count: usize = 0,
    operation_guard_active: bool = false,
    operation_alias_rejected: bool = false,
    request_free_test_observer: if (builtin.is_test) RequestFreeTestObserver else void = if (builtin.is_test) .{} else {},

    fn beginOperationGuard(
        self: *GenerationGuardedAllocator,
        ranges: []const OperationRangeInput,
    ) bool {
        if (self.operation_guard_active or ranges.len > self.operation_ranges.len) return false;
        for (ranges, 0..) |range, index| {
            if (range.start == 0 or range.len == 0) return false;
            const end = std.math.add(usize, range.start, range.len) catch return false;
            self.operation_ranges[index] = .{ .start = range.start, .end = end };
        }
        self.operation_range_count = ranges.len;
        self.operation_alias_rejected = false;
        self.operation_guard_active = true;
        return true;
    }

    fn finishOperationGuard(self: *GenerationGuardedAllocator) error{InvalidOwner}!void {
        if (!self.operation_guard_active) return error.InvalidOwner;
        self.operation_guard_active = false;
        self.operation_range_count = 0;
        self.operation_ranges = undefined;
    }

    fn endOperationGuard(self: *GenerationGuardedAllocator) void {
        self.finishOperationGuard() catch
            @panic("generation operation allocator guard was not active");
    }

    fn allocator(self: *GenerationGuardedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &allocator_vtable };
    }

    fn rejects(self: *const GenerationGuardedAllocator, ptr: [*]u8, len: usize) bool {
        const start = @intFromPtr(ptr);
        const end = std.math.add(usize, start, len) catch return true;
        if (rawRangesOverlap(start, end, self.node_start, self.node_end) or
            rawRangesOverlap(start, end, self.slot_start, self.slot_end) or
            rawRangesOverlap(start, end, self.source_start, self.source_end) or
            client_mod.generationAllocationAliasesOwnedBacking(self.client.?, ptr, len) or
            (self.snapshot_guard_active and
                (rawRangesOverlap(start, end, self.snapshot_owner_start, self.snapshot_owner_end) or
                    rawRangesOverlap(start, end, self.snapshot_out_start, self.snapshot_out_end))))
            return true;
        if (self.operation_guard_active)
            for (self.operation_ranges[0..self.operation_range_count]) |range|
                if (rawRangesOverlap(start, end, range.start, range.end)) return true;
        return false;
    }

    fn recordAliasRejection(self: *GenerationGuardedAllocator) void {
        if (self.operation_guard_active) {
            self.operation_alias_rejected = true;
            self.client.?.poison(.local_invariant_violation);
        } else if (self.snapshot_guard_active) {
            self.snapshot_alias_rejected = true;
        } else {
            @panic("generation allocator returned canonical owner alias");
        }
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *GenerationGuardedAllocator = @ptrCast(@alignCast(context));
        if (!self.client.?.enterGenerationAllocatorCallback()) return null;
        defer self.client.?.leaveGenerationAllocatorCallbackUnchecked();
        const result = self.parent.vtable.alloc(
            self.parent.ptr,
            len,
            alignment,
            return_address,
        ) orelse return null;
        if (builtin.is_test and !self.request_free_test_observer.rpc_publication_drift_fired) {
            const observer = &self.request_free_test_observer;
            const target_addr = switch (observer.rpc_publication_drift_kind) {
                1 => observer.rpc_publication_txn_addr,
                2 => observer.rpc_publication_lease_addr,
                3 => observer.rpc_publication_scope_addr,
                else => 0,
            };
            if (target_addr != 0) {
                @as(*usize, @ptrFromInt(target_addr)).* = 1;
                observer.rpc_publication_drift_fired = true;
            }
        }
        if (self.rejects(result, len)) {
            self.recordAliasRejection();
            return null;
        }
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *GenerationGuardedAllocator = @ptrCast(@alignCast(context));
        if (self.rejects(memory.ptr, new_len)) {
            self.recordAliasRejection();
            return false;
        }
        if (!self.client.?.enterGenerationAllocatorCallback()) return false;
        defer self.client.?.leaveGenerationAllocatorCallbackUnchecked();
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *GenerationGuardedAllocator = @ptrCast(@alignCast(context));
        if (!self.client.?.enterGenerationAllocatorCallback()) return null;
        defer self.client.?.leaveGenerationAllocatorCallbackUnchecked();
        const result = self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse return null;
        if (self.rejects(result, new_len)) {
            self.recordAliasRejection();
            return null;
        }
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *GenerationGuardedAllocator = @ptrCast(@alignCast(context));
        if (builtin.is_test and
            @intFromPtr(memory.ptr) == self.request_free_test_observer.target_addr and
            memory.len == self.request_free_test_observer.target_len)
        {
            self.request_free_test_observer.entry_count += 1;
            self.request_free_test_observer.descriptor_exact =
                self.request_free_test_observer.descriptor_allocator_ptr == @intFromPtr(self) and
                self.request_free_test_observer.descriptor_allocator_vtable == @intFromPtr(&allocator_vtable);
        }
        if (!self.client.?.enterGenerationAllocatorCallback())
            @panic("nested generation allocator free");
        defer self.client.?.leaveGenerationAllocatorCallbackUnchecked();
        if (builtin.is_test and
            @intFromPtr(memory.ptr) == self.request_free_test_observer.target_addr and
            memory.len == self.request_free_test_observer.target_len and
            !self.request_free_test_observer.rpc_free_reentry_fired)
        {
            if (self.request_free_test_observer.rpc_free_reentry_fn) |callback| {
                self.request_free_test_observer.rpc_free_reentry_fired = true;
                callback(self.request_free_test_observer.rpc_free_reentry_context.?);
            }
        }
        self.parent.vtable.free(
            self.parent.ptr,
            memory,
            alignment,
            return_address,
        );
    }
};

pub const RpcFreeEvidenceState = enum(u8) {
    empty,
    free_call_committed,
    terminal_freed_once,
};

/// Pointer-free node-local evidence around the allocator callback. This is never cleanup
/// authority: it only prevents a stale/copy epoch from authorizing a second free or silent reuse.
pub const RpcFreeEvidenceRecord = struct {
    state: RpcFreeEvidenceState = .empty,
    response_epoch: u64 = 0,
    evidence_digest: owner_seal.Digest = [_]u8{0} ** 32,
    seal: owner_seal.Digest = [_]u8{0} ** 32,

    pub fn emptyExact(self: *const @This()) bool {
        return rpcFreeEvidenceStateRawValid(&self.state) and self.state == .empty and
            self.response_epoch == 0 and
            std.mem.allEqual(u8, &self.evidence_digest, 0) and
            std.mem.allEqual(u8, &self.seal, 0);
    }

    pub fn commitFreeCall(self: *@This(), response_epoch: u64, digest: owner_seal.Digest) bool {
        if (!self.emptyExact() or response_epoch == 0 or response_epoch == std.math.maxInt(u64) or
            std.mem.allEqual(u8, &digest, 0)) return false;
        self.* = .{
            .state = .free_call_committed,
            .response_epoch = response_epoch,
            .evidence_digest = digest,
        };
        self.seal = rpcFreeEvidenceSeal(self);
        return true;
    }

    pub fn commitTerminalFreedOnce(
        self: *@This(),
        response_epoch: u64,
        digest: owner_seal.Digest,
    ) bool {
        if (!self.exact(.free_call_committed, response_epoch, digest)) return false;
        self.state = .terminal_freed_once;
        self.seal = rpcFreeEvidenceSeal(self);
        return true;
    }

    pub fn retireFreeCall(self: *@This(), response_epoch: u64, digest: owner_seal.Digest) bool {
        if (!self.exact(.free_call_committed, response_epoch, digest)) return false;
        self.* = .{};
        return true;
    }

    pub fn prepareRetireFreeCall(
        self: *const @This(),
        response_epoch: u64,
        digest: owner_seal.Digest,
        out: *PreparedRpcFreeEvidenceRetirePermit,
    ) bool {
        if (!out.pristineExact() or !self.exact(.free_call_committed, response_epoch, digest))
            return false;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .record_addr = @intFromPtr(self),
            .response_epoch = response_epoch,
            .evidence_digest = digest,
            .free_call_committed_record_seal = self.seal,
        };
        return true;
    }

    pub fn commitEvidenceRetireNoFail(
        self: *@This(),
        permit: *PreparedRpcFreeEvidenceRetirePermit,
    ) void {
        if (!permit.exactFor(self)) @panic("RPC response free evidence retire permit mismatch");
        permit.consumed_raw = 1;
        self.* = .{};
    }

    pub fn exact(
        self: *const @This(),
        state: RpcFreeEvidenceState,
        response_epoch: u64,
        digest: owner_seal.Digest,
    ) bool {
        return rpcFreeEvidenceStateRawValid(&self.state) and state != .empty and
            self.state == state and self.response_epoch == response_epoch and
            response_epoch != 0 and std.mem.eql(u8, &self.evidence_digest, &digest) and
            std.mem.eql(u8, &self.seal, &rpcFreeEvidenceSeal(self));
    }
};

const PreparedRpcFreeEvidenceRetirePermit = struct {
    self_addr: usize = 0,
    record_addr: usize = 0,
    response_epoch: u64 = 0,
    evidence_digest: owner_seal.Digest = [_]u8{0} ** 32,
    free_call_committed_record_seal: owner_seal.Digest = [_]u8{0} ** 32,
    consumed_raw: u8 = 0,

    pub fn pristineExact(self: *const @This()) bool {
        return std.mem.eql(u8, std.mem.asBytes(self), std.mem.asBytes(&PreparedRpcFreeEvidenceRetirePermit{}));
    }

    fn exactFor(self: *const @This(), record: *const RpcFreeEvidenceRecord) bool {
        return self.self_addr == @intFromPtr(self) and self.record_addr == @intFromPtr(record) and
            self.response_epoch != 0 and self.consumed_raw == 0 and
            std.mem.eql(u8, &self.free_call_committed_record_seal, &record.seal) and
            record.exact(.free_call_committed, self.response_epoch, self.evidence_digest);
    }
};

fn rpcFreeEvidenceStateRawValid(value: *const RpcFreeEvidenceState) bool {
    return @as(*const u8, @ptrCast(value)).* <=
        @intFromEnum(RpcFreeEvidenceState.terminal_freed_once);
}

fn rpcFreeEvidenceSeal(record: *const RpcFreeEvidenceRecord) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.rpc-free-evidence.v1");
    writer.writeU8(@intFromEnum(record.state));
    writer.writeU64(record.response_epoch);
    writer.writeBytes(&record.evidence_digest);
    return writer.finish();
}

pub const ClientNode = struct {
    client: client_mod.Client,
    operation_fence: client_mod.ClientOperationFence,
    pin_owner: lease_mod.PinOwner,
    cleanup_registry: cleanup_registry_mod.AttachmentCleanupRegistry,
    batch_registry: batch_registry_mod.Registry,
    accounting_ledger: batch_registry_mod.AccountingLedger,
    guarded_allocator: GenerationGuardedAllocator,
    incarnation: lease_mod.Identity,
    next_operation_generation: u64,
    active_operation_generation: u64,
    active_operation_kind: StreamOperationKind,
    active_operation_owner_thread_incarnation: u64,
    active_operation_owner_addr: usize,
    active_operation_transport_incarnation: u64,
    active_operation_binding: contract.BindingIdentity,
    rpc_free_evidence: RpcFreeEvidenceRecord = .{},
};

fn rpcFreeEvidenceFixture(seed: u64) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.rpc-free-evidence.fixture.v1");
    writer.writeU64(seed);
    return writer.finish();
}

test "B3-4/5 RPC free evidence commits and retires one exact epoch" {
    var record: RpcFreeEvidenceRecord = .{};
    const digest = rpcFreeEvidenceFixture(1);
    try std.testing.expect(record.commitFreeCall(7, digest));
    try std.testing.expect(record.exact(.free_call_committed, 7, digest));
    try std.testing.expect(record.retireFreeCall(7, digest));
    try std.testing.expect(record.emptyExact());
}

test "B3-4/5 RPC free evidence retire permit consumes exact committed record" {
    var record: RpcFreeEvidenceRecord = .{};
    const digest = rpcFreeEvidenceFixture(0xE1);
    try std.testing.expect(record.commitFreeCall(17, digest));
    var permit: PreparedRpcFreeEvidenceRetirePermit = .{};
    try std.testing.expect(record.prepareRetireFreeCall(17, digest, &permit));
    record.commitEvidenceRetireNoFail(&permit);
    try std.testing.expect(record.emptyExact());
    try std.testing.expectEqual(@as(u8, 1), permit.consumed_raw);
}

test "CR3a-2c3b reusable response correction evidence-retire prepare drift and replay" {
    var record: RpcFreeEvidenceRecord = .{};
    const digest = rpcFreeEvidenceFixture(0xE2);
    try std.testing.expect(record.commitFreeCall(18, digest));
    var permit: PreparedRpcFreeEvidenceRetirePermit = .{};
    try std.testing.expect(record.prepareRetireFreeCall(18, digest, &permit));
    var copied = permit;
    try std.testing.expect(!copied.exactFor(&record));
    const before = record;
    copied.response_epoch +%= 1;
    try std.testing.expect(!copied.exactFor(&record));
    try std.testing.expectEqualDeep(before, record);
    record.commitEvidenceRetireNoFail(&permit);
    try std.testing.expect(!permit.exactFor(&record));
}

test "B3-4/5 RPC free evidence stale epoch and digest are mutation zero" {
    var record: RpcFreeEvidenceRecord = .{};
    const digest = rpcFreeEvidenceFixture(2);
    const foreign = rpcFreeEvidenceFixture(3);
    try std.testing.expect(record.commitFreeCall(11, digest));
    const committed = record;
    try std.testing.expect(!record.commitTerminalFreedOnce(12, digest));
    try std.testing.expectEqualDeep(committed, record);
    try std.testing.expect(!record.commitTerminalFreedOnce(11, foreign));
    try std.testing.expectEqualDeep(committed, record);
    try std.testing.expect(!record.retireFreeCall(12, digest));
    try std.testing.expectEqualDeep(committed, record);
    try std.testing.expect(!record.retireFreeCall(11, foreign));
    try std.testing.expectEqualDeep(committed, record);
}

test "B3-4/5 RPC free evidence terminal record is absorbing and cannot retire" {
    var record: RpcFreeEvidenceRecord = .{};
    const digest = rpcFreeEvidenceFixture(4);
    try std.testing.expect(record.commitFreeCall(13, digest));
    try std.testing.expect(record.commitTerminalFreedOnce(13, digest));
    const terminal = record;
    try std.testing.expect(!record.commitFreeCall(14, rpcFreeEvidenceFixture(5)));
    try std.testing.expectEqualDeep(terminal, record);
    try std.testing.expect(!record.commitTerminalFreedOnce(13, digest));
    try std.testing.expectEqualDeep(terminal, record);
    try std.testing.expect(!record.retireFreeCall(13, digest));
    try std.testing.expectEqualDeep(terminal, record);
    const state_raw: *u8 = @ptrCast(&record.state);
    var raw: u16 = @intFromEnum(RpcFreeEvidenceState.terminal_freed_once) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        state_raw.* = @intCast(raw);
        try std.testing.expect(!record.retireFreeCall(13, digest));
    }
}

test "B3-4/5 RPC free evidence blocks ClientSlot teardown until exact retire" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try ClientSlot.initializeProcessRuntime();
    var source = fixtureClient(std.testing.allocator, 0xB3458);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, std.testing.allocator, &source, 0xB3458);
    const evidence = rpcFreeEvidenceFixture(0xB3459);
    try std.testing.expect(slot.current.rpc_free_evidence.commitFreeCall(1, evidence));
    try std.testing.expectEqual(DeinitOutcome.busy, slot.tryDeinit());
    try std.testing.expect(slot.current.rpc_free_evidence.retireFreeCall(1, evidence));
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "B3-4/5 RPC free evidence four-way publication failure disposition" {
    const Fixture = struct {
        fn canonical(
            destination_addr: usize,
            response_epoch: u64,
        ) rpc_response_authority.Canonical {
            return .{
                .authority_addr = 0xB345_1000,
                .registry_incarnation = 0xB345_1001,
                .binding = .{
                    .binding_incarnation = 0xB345_1002,
                    .binding_storage_addr = 0xB345_1003,
                    .destination_addr = destination_addr,
                    .binding_reservation_id = 0xB345_1004,
                    .slot_incarnation = 0xB345_1005,
                    .node_incarnation = 0xB345_1006,
                    .host_id = 0xB345_1007,
                    .connection_generation = 1,
                    .runtime_id = 0xB345_1008,
                    .role = .controller,
                    .pid = 0xB345_1009,
                    .process_nonce = 0xB345_1010,
                },
                .transport_addr = 0xB345_1011,
                .transport_incarnation = 0xB345_1012,
                .family = .bound_observation,
                .tag = .observation,
                .request_id = 0xB345_1013,
                .request_digest = 0xB345_1014,
                .response_epoch = response_epoch,
                .destination_addr = destination_addr,
            };
        }
    };
    const Probe = struct {
        parent: std.mem.Allocator,
        free_count: usize = 0,
        drift_addr: usize = 0,

        const vtable: std.mem.Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret);
        }

        fn resize(
            ctx: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret: usize,
        ) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.parent.vtable.resize(
                self.parent.ptr,
                memory,
                alignment,
                new_len,
                ret,
            );
        }

        fn remap(
            ctx: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret: usize,
        ) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.parent.vtable.remap(
                self.parent.ptr,
                memory,
                alignment,
                new_len,
                ret,
            );
        }

        fn free(
            ctx: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            ret: usize,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.free_count += 1;
            if (self.drift_addr != 0) @as(*usize, @ptrFromInt(self.drift_addr)).* +%= 1;
            self.parent.vtable.free(self.parent.ptr, memory, alignment, ret);
        }
    };
    const Case = struct {
        destination_exact: bool,
        payload_exact: bool,
        callback_drift: bool = false,
        pre_release_drift: bool = false,
    };
    inline for (.{
        Case{ .destination_exact = true, .payload_exact = true },
        Case{ .destination_exact = true, .payload_exact = false },
        Case{ .destination_exact = false, .payload_exact = true },
        Case{ .destination_exact = false, .payload_exact = false },
        Case{ .destination_exact = true, .payload_exact = true, .callback_drift = true },
        Case{ .destination_exact = true, .payload_exact = true, .pre_release_drift = true },
    }) |case| {
        var probe: Probe = .{ .parent = std.testing.allocator };
        const allocator = probe.allocator();
        var ledger: response_payload_allocation.Ledger = .{};
        try response_payload_allocation.Ledger.initInPlace(&ledger, allocator, .{
            .guard_addr = 0xB345_2001,
            .node_addr = 0xB345_2002,
            .operation_incarnation = 0xB345_2003,
        }, 1);
        const payload = try allocator.dupe(u8, "rpc-publication-failure");
        const generation = try ledger.reserveObserved(payload.len, allocator);
        try ledger.commitObserved(generation, payload, allocator);
        const receipt = switch (ledger.classifyResponsePayloadProvenance(
            generation,
            payload,
            allocator,
            allocator,
        )) {
            .promoted => |value| value,
            .fail_stop_required => return error.TestUnexpectedResult,
        };
        var destination: RpcExecutedResponse = .{};
        if (!case.destination_exact) destination.self_addr = 0xBAD0;
        const destination_before = destination;
        const canonical = Fixture.canonical(
            @intFromPtr(&destination),
            0xB345_2004,
        );
        var cleanup: RpcPublicationPayloadCleanup = .{};
        try cleanup.arm(receipt);
        if (!case.payload_exact) cleanup.self_addr +%= 1;
        if (case.pre_release_drift) cleanup.test_pre_release_stage_drift = 1;
        if (case.callback_drift)
            probe.drift_addr = @intFromPtr(&cleanup.failure_release.self_addr);
        var free_record: RpcFreeEvidenceRecord = .{};
        const outcome = settleRpcPublicationFailureBytes(
            &free_record,
            &cleanup,
            canonical,
            .ledger_drift,
        );
        if (case.pre_release_drift) {
            try std.testing.expectEqual(@as(usize, 0), probe.free_count);
            try std.testing.expectEqual(
                RpcPublicationFailureByteDisposition.destination_exact_payload_no_free,
                outcome.disposition,
            );
            try std.testing.expectEqual(
                rpc_executed_response.ByteSettlement.terminal_no_free,
                destination.settlement,
            );
            try std.testing.expect(free_record.emptyExact());
            allocator.free(payload);
            try std.testing.expectEqual(@as(usize, 1), probe.free_count);
        } else if (case.payload_exact) {
            try std.testing.expectEqual(@as(usize, 1), probe.free_count);
            if (case.destination_exact and !case.callback_drift) {
                try std.testing.expectEqual(
                    RpcPublicationFailureByteDisposition.destination_exact_payload_freed_clean,
                    outcome.disposition,
                );
                try std.testing.expectEqual(
                    rpc_executed_response.ByteSettlement.terminal_clean,
                    destination.settlement,
                );
                try std.testing.expect(outcome.retire_clean_evidence);
                try std.testing.expect(free_record.retireFreeCall(
                    outcome.response_epoch,
                    outcome.free_evidence,
                ));
            } else if (!case.destination_exact) {
                try std.testing.expectEqual(
                    RpcPublicationFailureByteDisposition.destination_invalid_payload_freed_once,
                    outcome.disposition,
                );
                try std.testing.expectEqualDeep(destination_before, destination);
                try std.testing.expect(free_record.exact(
                    .terminal_freed_once,
                    outcome.response_epoch,
                    outcome.free_evidence,
                ));
            } else {
                try std.testing.expectEqual(
                    RpcPublicationFailureByteDisposition.destination_exact_payload_freed_once_drifted,
                    outcome.disposition,
                );
                try std.testing.expectEqualDeep(destination_before, destination);
                try std.testing.expect(free_record.exact(
                    .terminal_freed_once,
                    outcome.response_epoch,
                    outcome.free_evidence,
                ));
            }
        } else {
            try std.testing.expectEqual(@as(usize, 0), probe.free_count);
            try std.testing.expect(free_record.emptyExact());
            if (case.destination_exact) {
                try std.testing.expectEqual(
                    RpcPublicationFailureByteDisposition.destination_exact_payload_no_free,
                    outcome.disposition,
                );
                try std.testing.expectEqual(
                    rpc_executed_response.ByteSettlement.terminal_no_free,
                    destination.settlement,
                );
            } else {
                try std.testing.expectEqual(
                    RpcPublicationFailureByteDisposition.destination_invalid_payload_no_free,
                    outcome.disposition,
                );
                try std.testing.expectEqualDeep(destination_before, destination);
            }
            try ledger.releasePromotedResponse(receipt);
            try std.testing.expectEqual(@as(usize, 1), probe.free_count);
        }
        const free_count_after_settlement = probe.free_count;
        _ = settleRpcPublicationFailureBytes(
            &free_record,
            &cleanup,
            canonical,
            .ledger_drift,
        );
        try std.testing.expectEqual(free_count_after_settlement, probe.free_count);
        try ledger.endOperation();
    }

    inline for (1..14) |drift_kind| {
        const allocator = std.testing.allocator;
        var ledger: response_payload_allocation.Ledger = .{};
        try response_payload_allocation.Ledger.initInPlace(&ledger, allocator, .{
            .guard_addr = 0xB345_3001,
            .node_addr = 0xB345_3002,
            .operation_incarnation = 0xB345_3003,
        }, 1);
        const payload = try allocator.dupe(u8, "rpc-publication-forgery");
        const generation = try ledger.reserveObserved(payload.len, allocator);
        try ledger.commitObserved(generation, payload, allocator);
        const receipt = switch (ledger.classifyResponsePayloadProvenance(
            generation,
            payload,
            allocator,
            allocator,
        )) {
            .promoted => |value| value,
            .fail_stop_required => return error.TestUnexpectedResult,
        };
        var destination: RpcExecutedResponse = .{};
        const canonical = Fixture.canonical(@intFromPtr(&destination), 0xB345_3004);
        var cleanup: RpcPublicationPayloadCleanup = .{};
        try cleanup.arm(receipt);
        switch (drift_kind) {
            1 => cleanup.self_addr +%= 1,
            2 => cleanup.receipt.ledger_addr +%= 1,
            3 => cleanup.receipt.generation +%= 1,
            4 => cleanup.receipt.index +%= 1,
            5 => cleanup.receipt.allocator.ptr_addr +%= 1,
            6 => cleanup.receipt.allocator.vtable_addr +%= 1,
            7 => cleanup.receipt.addr +%= 1,
            8 => cleanup.receipt.len +%= 1,
            9 => cleanup.receipt.zero_length = !cleanup.receipt.zero_length,
            10 => cleanup.receipt.authority.guard_addr +%= 1,
            11 => cleanup.receipt.authority.node_addr +%= 1,
            12 => cleanup.receipt.authority.operation_incarnation +%= 1,
            13 => cleanup.seal[0] ^= 1,
            else => unreachable,
        }
        var free_record: RpcFreeEvidenceRecord = .{};
        const outcome = settleRpcPublicationFailureBytes(
            &free_record,
            &cleanup,
            canonical,
            .ledger_drift,
        );
        try std.testing.expectEqual(
            RpcPublicationFailureByteDisposition.destination_exact_payload_no_free,
            outcome.disposition,
        );
        try std.testing.expect(free_record.emptyExact());
        try std.testing.expect(ledger.promotedReceiptExact(receipt));
        try std.testing.expectEqual(
            rpc_executed_response.ByteSettlement.terminal_no_free,
            destination.settlement,
        );
        try ledger.releasePromotedResponse(receipt);
        try ledger.endOperation();
    }
}

pub const StreamOperationKind = enum(u8) {
    none,
    initial_snapshot,
    controller_revoke,
    ended_purge,
};

pub const StreamOperationPermit = struct {
    slot: *ClientSlot,
    registry_index: u16,
    registry_id: u64,
    slot_incarnation: u64,
    node_incarnation: u64,
    generation: u64,
    kind: StreamOperationKind,
    owner_thread_incarnation: u64,
    owner_addr: usize,
    transport_incarnation: u64,
    binding: contract.BindingIdentity,
};

pub const InitialSnapshotPermit = StreamOperationPermit;

const EndedPurgePreparationLifecycle = enum(u8) {
    empty,
    prepared,
    committing,
    consumed,
    aborted,
};

pub const EndedPurgePreparation = struct {
    self_addr: usize = 0,
    target_stream: u64 = 0,
    permit: StreamOperationPermit = undefined,
    inventory: client_mod.PreparedEndedPurgeInventory = .{},
    authority_seal: owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: EndedPurgePreparationLifecycle = .empty,

    fn rawTagsValid(self: *const EndedPurgePreparation) bool {
        const lifecycle_raw = @as(*const u8, @ptrCast(&self.lifecycle)).*;
        return lifecycle_raw <= @intFromEnum(EndedPurgePreparationLifecycle.aborted) and
            ClientSlot.streamOperationPermitRawTagsValid(&self.permit) and
            self.inventory.validPreparedAtFinalAddress();
    }

    pub fn abort(self: *EndedPurgePreparation, slot: *ClientSlot) bool {
        if (!self.rawTagsValid() or self.lifecycle != .prepared or
            self.self_addr != @intFromPtr(self) or
            !slot.streamOperationPermitLive(self.permit) or
            !std.mem.eql(u8, &self.authority_seal, &endedPurgePreparationSeal(self)))
            return false;
        slot.abortStreamOperationPermit(self.permit) catch return false;
        if (!self.inventory.abort()) @panic("validated ended purge inventory abort failed");
        self.lifecycle = .aborted;
        return true;
    }

    fn sealForCommit(self: *EndedPurgePreparation, slot: *ClientSlot) bool {
        if (slot.pid != currentPid() or
            !operationThreadMatches(slot.operation_owner_thread_incarnation))
            return false;
        const index: usize = self.permit.registry_index;
        if (index >= stream_operation_registry.len) return false;
        const entry = &stream_operation_registry[index];
        if (!self.rawTagsValid() or self.lifecycle != .prepared or
            self.self_addr != @intFromPtr(self) or
            !std.mem.eql(u8, &self.authority_seal, &endedPurgePreparationSeal(self)) or
            entry.state.load(.acquire) !=
                @intFromEnum(StreamOperationRegistryEntry.State.consume_reserved) or
            entry.id != self.permit.registry_id or
            !std.meta.eql(entry.permit, self.permit) or
            self.permit.slot != slot or
            self.permit.generation != slot.current.active_operation_generation or
            self.permit.kind != slot.current.active_operation_kind or
            self.permit.owner_thread_incarnation !=
                slot.current.active_operation_owner_thread_incarnation or
            self.permit.owner_addr != slot.current.active_operation_owner_addr or
            self.permit.transport_incarnation !=
                slot.current.active_operation_transport_incarnation or
            !std.meta.eql(self.permit.binding, slot.current.active_operation_binding))
            return false;
        self.lifecycle = .committing;
        self.authority_seal = endedPurgePreparationSeal(self);
        return true;
    }

    fn consumeAfterPermit(self: *EndedPurgePreparation, slot: *ClientSlot) void {
        if (slot.pid != currentPid() or
            !operationThreadMatches(slot.operation_owner_thread_incarnation))
            @panic("ended purge transport receipt crossed its operation thread");
        const index: usize = self.permit.registry_index;
        if (index >= stream_operation_registry.len)
            @panic("ended purge transport receipt registry index drifted");
        const entry = &stream_operation_registry[index];
        if (!self.rawTagsValid() or self.lifecycle != .committing or
            self.self_addr != @intFromPtr(self) or
            !std.mem.eql(u8, &self.authority_seal, &endedPurgePreparationSeal(self)) or
            entry.state.load(.acquire) !=
                @intFromEnum(StreamOperationRegistryEntry.State.consumed) or
            entry.id != self.permit.registry_id or
            !std.meta.eql(entry.permit, self.permit) or
            slot.current.active_operation_generation != 0 or
            slot.current.active_operation_kind != .none or
            slot.current.active_operation_owner_thread_incarnation != 0 or
            slot.current.active_operation_owner_addr != 0 or
            slot.current.active_operation_transport_incarnation != 0)
            @panic("ended purge transport receipt authority drifted");
        self.lifecycle = .consumed;
        self.authority_seal = endedPurgePreparationSeal(self);
        if (entry.state.cmpxchgStrong(
            @intFromEnum(StreamOperationRegistryEntry.State.consumed),
            @intFromEnum(StreamOperationRegistryEntry.State.empty),
            .acq_rel,
            .acquire,
        ) != null) @panic("ended purge transport receipt reclaim drifted");
    }
};

fn endedPurgePreparationSeal(prepared: *const EndedPurgePreparation) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.ended-purge.preparation.v1");
    writer.writeUsize(prepared.self_addr);
    writer.writeU64(prepared.target_stream);
    writer.writeUsize(@intFromPtr(prepared.permit.slot));
    writer.writeU16(prepared.permit.registry_index);
    writer.writeU64(prepared.permit.registry_id);
    writer.writeU64(prepared.permit.slot_incarnation);
    writer.writeU64(prepared.permit.node_incarnation);
    writer.writeU64(prepared.permit.generation);
    writer.writeU8(@intFromEnum(prepared.permit.kind));
    writer.writeU64(prepared.permit.owner_thread_incarnation);
    writer.writeUsize(prepared.permit.owner_addr);
    writer.writeU64(prepared.permit.transport_incarnation);
    writer.writeU64(prepared.permit.binding.binding_incarnation);
    writer.writeUsize(prepared.permit.binding.binding_storage_addr);
    writer.writeUsize(prepared.permit.binding.destination_addr);
    writer.writeU64(prepared.permit.binding.binding_reservation_id);
    writer.writeU64(prepared.permit.binding.slot_incarnation);
    writer.writeU64(prepared.permit.binding.node_incarnation);
    writer.writeU128(prepared.permit.binding.host_id);
    writer.writeU64(prepared.permit.binding.connection_generation);
    writer.writeU128(prepared.permit.binding.runtime_id);
    writer.writeU8(@intFromEnum(prepared.permit.binding.role));
    writer.writeU64(prepared.permit.binding.pid);
    writer.writeU64(prepared.permit.binding.process_nonce);
    writer.writeUsize(prepared.inventory.self_addr);
    writer.writeUsize(prepared.inventory.client_addr);
    writer.writeUsize(prepared.inventory.scratch_addr);
    writer.writeU64(prepared.inventory.target_stream);
    writer.writeU64(prepared.inventory.hint_index);
    writeArrayDescriptor(&writer, prepared.inventory.batches);
    writeArrayDescriptor(&writer, prepared.inventory.stream);
    writeArrayDescriptor(&writer, prepared.inventory.events);
    if (prepared.inventory.partial) |partial| {
        writer.writeBool(true);
        writer.writeU64(partial.stream_id);
        writer.writeBool(partial.is_snapshot);
        writeArrayDescriptor(&writer, partial.bytes);
        writer.writeUsize(partial.chunk_count);
    } else writer.writeBool(false);
    writer.writeUsize(prepared.inventory.batch_payload_bytes);
    writer.writeUsize(prepared.inventory.stream_payload_bytes);
    writer.writeUsize(prepared.inventory.event_payload_bytes);
    writer.writeUsize(prepared.inventory.target_batch_count);
    writer.writeUsize(prepared.inventory.target_stream_count);
    writer.writeUsize(prepared.inventory.target_event_count);
    writer.writeUsize(prepared.inventory.target_payload_bytes);
    writer.writeUsize(prepared.inventory.demux_owned_extent_bytes);
    writer.writeBytes(&prepared.inventory.batch_seal);
    writer.writeBytes(&prepared.inventory.stream_seal);
    writer.writeBytes(&prepared.inventory.event_seal);
    writer.writeBytes(&prepared.inventory.partial_seal);
    writer.writeBytes(&prepared.inventory.target_map_seal);
    writer.writeU8(@intFromEnum(prepared.inventory.lifecycle));
    writer.writeU8(@intFromEnum(prepared.lifecycle));
    return writer.finish();
}

fn writeArrayDescriptor(writer: *owner_seal.Writer, descriptor: anytype) void {
    writer.writeUsize(descriptor.address);
    writer.writeUsize(descriptor.len);
    writer.writeUsize(descriptor.capacity);
}

pub const EndedPurgePreparationError = error{
    InvalidOwner,
    Busy,
    Corrupt,
    IdentityExhausted,
    DestinationOccupied,
};

pub const InitError = error{
    InvalidSource,
    InvalidDestination,
    AliasedAllocation,
    ReentrantInit,
    ProcessDomainMismatch,
    IdentityExhausted,
    OutOfMemory,
};

pub const DeinitOutcome = enum {
    cleaned,
    busy,
    corrupt,
    already_dead,
};

pub const AttachmentBindingReservation = struct {
    cleanup: cleanup_registry_mod.Reservation,
    identity: contract.BindingIdentity,
};

pub const BindingError = cleanup_registry_mod.Error ||
    contract.PreparedAttachmentBinding.TransitionError || error{
    AdminBusy,
    PinOverflow,
    InvalidLease,
};

pub const CapabilityProjectionError = error{ InvalidOwner, Busy };

pub const CapabilityProjectionRequest = struct {
    slot_addr: usize,
    slot_incarnation: u64,
    node_incarnation: u64,
    host_id: u128,
    pid: u32,
    process_nonce: u64,
    transport_incarnation: u64,
    owner_seal_addr: usize,
    reservation: AttachmentBindingReservation,
};

pub const GenerationRequestError = error{
    Busy,
    InvalidOwner,
    Unauthorized,
    InvalidReceipt,
    IdentityExhausted,
    ResourceExhausted,
    ConnectionClosed,
    ProtocolError,
};

pub const GenerationRequestPrepare = struct {
    slot_addr: usize,
    slot_incarnation: u64,
    node_incarnation: u64,
    host_id: u128,
    pid: u32,
    process_nonce: u64,
    transport_addr: usize,
    owner_addr: usize,
    owner_size: usize,
    transport_incarnation: u64,
    owner_seal_addr: usize,
    prepared_storage_addr: usize,
    bound_stream_id: u64,
    reservation: AttachmentBindingReservation,
    request: contract.RuntimeRequest,
};

pub const GenerationPreparedRequest = struct {
    receipt: contract.PreparedCallReceipt,
    canonical: prepared_request_authority.Prepared,
};

pub const GenerationRequestAbort = struct {
    slot_addr: usize,
    slot_incarnation: u64,
    node_incarnation: u64,
    host_id: u128,
    pid: u32,
    process_nonce: u64,
    transport_addr: usize,
    transport_incarnation: u64,
    owner_seal_addr: usize,
    prepared_storage_addr: usize,
    reservation: AttachmentBindingReservation,
    receipt: contract.PreparedCallReceipt,
};

pub const GenerationTransportOwnerQuery = struct {
    slot_addr: usize,
    slot_incarnation: u64,
    node_incarnation: u64,
    host_id: u128,
    pid: u32,
    process_nonce: u64,
    transport_addr: usize,
    transport_incarnation: u64,
    owner_seal_addr: usize,
    prepared_storage_addr: usize,
    reservation: AttachmentBindingReservation,
};

pub const GenerationRequestExecute = struct {
    request: GenerationRequestAbort,
    // Execute revalidates the transport's current stream instead of trusting only the
    // stream captured in the prepared registry entry.
    bound_stream_id: u64 = 0,
    response_out_addr: usize,
    owner_addr: usize,
    owner_size: usize,
};

/// Internal-only aggregate for the GenerationTransport-owned RPC response slot. Keeping the
/// destination as a scalar here prevents the response owner type from escaping into the public
/// transport facade while still forcing containment before the first destination dereference.
pub const GenerationRpcSubstrateExecute = struct {
    request: GenerationRequestAbort,
    bound_stream_id: u64,
};

pub const GenerationExecuteError = GenerationRequestError ||
    client_mod.PreparedBlockingRpcError || error{InvalidResponseDestination};

var issuer_mutex: std.atomic.Mutex = .unlocked;
var process_issuer: ?lease_mod.IdentityIssuer = null;
threadlocal var init_active: bool = false;
threadlocal var batch_release_callback_active: bool = false;
threadlocal var operation_thread_incarnation: u64 = 0;
var next_operation_thread_incarnation: std.atomic.Value(u64) = .init(1);
var alias_quarantine_events: std.atomic.Value(u64) = .init(0);
var generation_response_incarnation_issuer: std.atomic.Value(u64) = .init(1);

const max_live_client_slots = 4096;
const ClientSlotRegistryEntry = struct {
    live: bool = false,
    ready: bool = false,
    slot_addr: usize = 0,
    node_addr: usize = 0,
    slot_incarnation: u64 = 0,
    node_incarnation: u64 = 0,
    owner_thread_incarnation: u64 = 0,
};
var client_slot_registry_mutex: std.atomic.Mutex = .unlocked;
var client_slot_registry: [max_live_client_slots]ClientSlotRegistryEntry =
    [_]ClientSlotRegistryEntry{.{}} ** max_live_client_slots;

fn registerClientSlot(entry: ClientSlotRegistryEntry) error{IdentityExhausted}!void {
    while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer client_slot_registry_mutex.unlock();
    var free_index: ?usize = null;
    for (&client_slot_registry, 0..) |*candidate, index| {
        if (candidate.live and candidate.slot_addr == entry.slot_addr)
            return error.IdentityExhausted;
        if (!candidate.live and free_index == null) free_index = index;
    }
    const index = free_index orelse return error.IdentityExhausted;
    client_slot_registry[index] = entry;
}

fn clientSlotRegistryEntry(slot_addr: usize) ?ClientSlotRegistryEntry {
    while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer client_slot_registry_mutex.unlock();
    for (client_slot_registry) |entry| {
        if (entry.live and entry.ready and entry.slot_addr == slot_addr) return entry;
    }
    return null;
}

fn publishClientSlot(expected: ClientSlotRegistryEntry) void {
    while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer client_slot_registry_mutex.unlock();
    for (&client_slot_registry) |*entry| {
        if (entry.live and entry.slot_addr == expected.slot_addr and
            std.meta.eql(entry.*, expected))
        {
            entry.ready = true;
            return;
        }
    }
    @panic("reserved ClientSlot registry publication drifted");
}

fn unregisterClientSlot(expected: ClientSlotRegistryEntry) bool {
    while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer client_slot_registry_mutex.unlock();
    for (&client_slot_registry) |*entry| {
        if (entry.live and entry.slot_addr == expected.slot_addr) {
            if (!std.meta.eql(entry.*, expected)) return false;
            entry.* = .{};
            return true;
        }
    }
    return false;
}

fn acquireOperationThreadIncarnation() error{IdentityExhausted}!u64 {
    if (operation_thread_incarnation != 0) return operation_thread_incarnation;
    var observed = next_operation_thread_incarnation.load(.acquire);
    while (true) {
        if (observed == 0 or observed == std.math.maxInt(u64))
            return error.IdentityExhausted;
        if (next_operation_thread_incarnation.cmpxchgWeak(
            observed,
            observed + 1,
            .acq_rel,
            .acquire,
        )) |actual| {
            observed = actual;
            continue;
        }
        operation_thread_incarnation = observed;
        return observed;
    }
}

fn operationThreadMatches(incarnation: u64) bool {
    return incarnation != 0 and operation_thread_incarnation == incarnation;
}

const max_stream_operation_permits = 4096;
const StreamOperationRegistryEntry = struct {
    const State = enum(u8) { empty, live, consume_reserved, consumed };

    state: std.atomic.Value(u8) = .init(@intFromEnum(State.empty)),
    id: u64 = 0,
    permit: StreamOperationPermit = undefined,
};
var stream_operation_registry_mutex: std.atomic.Mutex = .unlocked;
var stream_operation_registry: [max_stream_operation_permits]StreamOperationRegistryEntry =
    [_]StreamOperationRegistryEntry{.{}} ** max_stream_operation_permits;
var next_stream_operation_registry_id: u64 = 1;

fn registerStreamOperationPermit(fields: StreamOperationPermit) error{ AdminBusy, IdentityExhausted }!StreamOperationPermit {
    while (!stream_operation_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer stream_operation_registry_mutex.unlock();
    var index: usize = 0;
    while (index < stream_operation_registry.len and
        stream_operation_registry[index].state.load(.acquire) !=
            @intFromEnum(StreamOperationRegistryEntry.State.empty)) : (index += 1)
    {}
    if (index == stream_operation_registry.len) return error.AdminBusy;
    const id = next_stream_operation_registry_id;
    next_stream_operation_registry_id = std.math.add(u64, id, 1) catch
        return error.IdentityExhausted;
    var permit = fields;
    permit.registry_index = @intCast(index);
    permit.registry_id = id;
    const entry = &stream_operation_registry[index];
    entry.id = id;
    entry.permit = permit;
    entry.state.store(@intFromEnum(StreamOperationRegistryEntry.State.live), .release);
    return permit;
}

fn streamOperationPermitRegistryLive(permit: StreamOperationPermit) bool {
    const index: usize = permit.registry_index;
    if (index >= stream_operation_registry.len or permit.registry_id == 0) return false;
    while (!stream_operation_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer stream_operation_registry_mutex.unlock();
    const entry = &stream_operation_registry[index];
    return entry.state.load(.acquire) == @intFromEnum(StreamOperationRegistryEntry.State.live) and
        entry.id == permit.registry_id and std.meta.eql(entry.permit, permit);
}

fn unregisterStreamOperationPermit(permit: StreamOperationPermit) error{InvalidStreamOperationPermit}!void {
    const index: usize = permit.registry_index;
    if (index >= stream_operation_registry.len or permit.registry_id == 0)
        return error.InvalidStreamOperationPermit;
    while (!stream_operation_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer stream_operation_registry_mutex.unlock();
    const entry = &stream_operation_registry[index];
    if (entry.state.load(.acquire) != @intFromEnum(StreamOperationRegistryEntry.State.live) or
        entry.id != permit.registry_id or !std.meta.eql(entry.permit, permit))
        return error.InvalidStreamOperationPermit;
    if (entry.state.cmpxchgStrong(
        @intFromEnum(StreamOperationRegistryEntry.State.live),
        @intFromEnum(StreamOperationRegistryEntry.State.empty),
        .acq_rel,
        .acquire,
    ) != null) return error.InvalidStreamOperationPermit;
}

fn recordAliasQuarantine() bool {
    var observed = alias_quarantine_events.load(.acquire);
    while (true) {
        if (observed == std.math.maxInt(u64)) return false;
        if (alias_quarantine_events.cmpxchgWeak(
            observed,
            observed + 1,
            .acq_rel,
            .acquire,
        )) |actual| {
            observed = actual;
            continue;
        }
        return true;
    }
}

fn currentPid() u32 {
    return if (builtin.os.tag == .macos) @intCast(c.getpid()) else 1;
}

fn streamOperationNodeIdle(node: *const ClientNode) bool {
    const kind_raw = @as(*const u8, @ptrCast(&node.active_operation_kind)).*;
    return kind_raw <= @intFromEnum(StreamOperationKind.ended_purge) and
        node.active_operation_generation == 0 and node.active_operation_kind == .none and
        node.active_operation_owner_thread_incarnation == 0 and
        node.active_operation_owner_addr == 0 and
        node.active_operation_transport_incarnation == 0;
}

const RegisteredNodeLookup = struct {
    slot_addr: usize,
    slot_incarnation: u64,
    node: union(enum) {
        incarnation: u64,
        address: usize,
    },
    owner_thread_incarnation: ?u64 = null,
};

const RegisteredNodeOperation = struct {
    node: *ClientNode,
    registry_index: u16,
    operation_id: u64,
    pid: u32,
};

const max_registered_node_operations = 4096;
const RegisteredNodeOperationEntry = struct {
    const State = enum(u8) { empty, reserved, live, releasing };

    state: State = .empty,
    operation_id: u64 = 0,
    slot_addr: usize = 0,
    slot_incarnation: u64 = 0,
    node_addr: usize = 0,
    node_incarnation: u64 = 0,
    pid: u32 = 0,
    owner_thread_incarnation: u64 = 0,
};
var registered_node_operation_mutex: std.atomic.Mutex = .unlocked;
var registered_node_operations: [max_registered_node_operations]RegisteredNodeOperationEntry =
    [_]RegisteredNodeOperationEntry{.{}} ** max_registered_node_operations;
var registered_node_operation_free_stack: [max_registered_node_operations]u16 = blk: {
    @setEvalBranchQuota(max_registered_node_operations * 2);
    var indices: [max_registered_node_operations]u16 = undefined;
    for (&indices, 0..) |*entry, index| entry.* = @intCast(index);
    break :blk indices;
};
var registered_node_operation_free_count: usize = max_registered_node_operations;
var next_registered_node_operation_id: u64 = 1;

const RegisteredNodeOperationReservation = struct {
    index: usize,
    entry: RegisteredNodeOperationEntry,
};

fn reserveRegisteredNodeOperation(
    lookup: RegisteredNodeLookup,
) error{Busy}!RegisteredNodeOperationReservation {
    while (!registered_node_operation_mutex.tryLock()) std.atomic.spinLoopHint();
    defer registered_node_operation_mutex.unlock();
    const operation_id = next_registered_node_operation_id;
    if (operation_id == 0 or operation_id == std.math.maxInt(u64)) return error.Busy;
    if (registered_node_operation_free_count == 0) return error.Busy;
    registered_node_operation_free_count -= 1;
    const index: usize = registered_node_operation_free_stack[registered_node_operation_free_count];
    if (registered_node_operations[index].state != .empty)
        @panic("registered node operation free stack drifted");
    next_registered_node_operation_id = operation_id + 1;
    const entry: RegisteredNodeOperationEntry = .{
        .state = .reserved,
        .operation_id = operation_id,
        .slot_addr = lookup.slot_addr,
        .slot_incarnation = lookup.slot_incarnation,
        .pid = currentPid(),
        .owner_thread_incarnation = operation_thread_incarnation,
    };
    registered_node_operations[index] = entry;
    return .{ .index = index, .entry = entry };
}

fn abortRegisteredNodeOperationReservation(reservation: RegisteredNodeOperationReservation) void {
    while (!registered_node_operation_mutex.tryLock()) std.atomic.spinLoopHint();
    defer registered_node_operation_mutex.unlock();
    const entry = &registered_node_operations[reservation.index];
    if (entry.state != .reserved or entry.operation_id != reservation.entry.operation_id)
        @panic("registered node operation reservation drifted");
    entry.* = .{};
    if (registered_node_operation_free_count >= registered_node_operation_free_stack.len)
        @panic("registered node operation free stack overflow");
    registered_node_operation_free_stack[registered_node_operation_free_count] =
        @intCast(reservation.index);
    registered_node_operation_free_count += 1;
}

fn publishRegisteredNodeOperation(
    reservation: RegisteredNodeOperationReservation,
    slot_entry: ClientSlotRegistryEntry,
) RegisteredNodeOperation {
    while (!registered_node_operation_mutex.tryLock()) std.atomic.spinLoopHint();
    defer registered_node_operation_mutex.unlock();
    const entry = &registered_node_operations[reservation.index];
    if (entry.state != .reserved or entry.operation_id != reservation.entry.operation_id or
        entry.slot_addr != slot_entry.slot_addr or entry.slot_incarnation != slot_entry.slot_incarnation or
        entry.pid != currentPid() or !operationThreadMatches(entry.owner_thread_incarnation))
        @panic("registered node operation publication drifted");
    entry.node_addr = slot_entry.node_addr;
    entry.node_incarnation = slot_entry.node_incarnation;
    entry.state = .live;
    return .{
        .node = @ptrFromInt(slot_entry.node_addr),
        .registry_index = @intCast(reservation.index),
        .operation_id = entry.operation_id,
        .pid = entry.pid,
    };
}

fn resolveRegisteredNodeOperation(operation: RegisteredNodeOperation) ?*ClientNode {
    const pid = currentPid();
    const index: usize = operation.registry_index;
    if (pid == 0 or operation.pid != pid or process_runtime_pid.load(.acquire) != pid or
        index >= registered_node_operations.len or operation.operation_id == 0 or
        @intFromPtr(operation.node) == 0)
        return null;
    var observed: ?RegisteredNodeOperationEntry = null;
    while (!registered_node_operation_mutex.tryLock()) std.atomic.spinLoopHint();
    const candidate = registered_node_operations[index];
    if (candidate.state == .live and candidate.operation_id == operation.operation_id and
        candidate.node_addr == @intFromPtr(operation.node) and candidate.pid == pid and
        operationThreadMatches(candidate.owner_thread_incarnation))
    {
        observed = candidate;
    }
    // Lock order invariant: never hold the operation registry while acquiring ClientSlot registry.
    registered_node_operation_mutex.unlock();
    const expected = observed orelse return null;
    while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer client_slot_registry_mutex.unlock();
    for (client_slot_registry) |entry| {
        if (entry.live and entry.ready and entry.slot_addr == expected.slot_addr and
            entry.slot_incarnation == expected.slot_incarnation and
            entry.node_addr == expected.node_addr and entry.node_incarnation == expected.node_incarnation and
            entry.owner_thread_incarnation == expected.owner_thread_incarnation)
            return @ptrFromInt(expected.node_addr);
    }
    return null;
}

fn registeredNodeOperationOwnerEntry(
    operation: RegisteredNodeOperation,
) ?RegisteredNodeOperationEntry {
    const pid = currentPid();
    const index: usize = operation.registry_index;
    if (pid == 0 or operation.pid != pid or process_runtime_pid.load(.acquire) != pid or
        index >= registered_node_operations.len or operation.operation_id == 0 or
        @intFromPtr(operation.node) == 0)
        return null;
    while (!registered_node_operation_mutex.tryLock()) std.atomic.spinLoopHint();
    defer registered_node_operation_mutex.unlock();
    const entry = registered_node_operations[index];
    if (entry.state != .live or entry.operation_id != operation.operation_id or
        entry.node_addr != @intFromPtr(operation.node) or entry.pid != pid or
        !operationThreadMatches(entry.owner_thread_incarnation))
        return null;
    return entry;
}

fn beginRegisteredNodeOperation(
    lookup: RegisteredNodeLookup,
) error{ InvalidOwner, Busy }!RegisteredNodeOperation {
    const pid = currentPid();
    if (pid == 0 or process_runtime_pid.load(.acquire) != pid or
        lookup.slot_addr == 0 or lookup.slot_incarnation == 0 or switch (lookup.node) {
        .incarnation => |value| value == 0,
        .address => |value| value == 0,
    })
        return error.InvalidOwner;
    const reservation = reserveRegisteredNodeOperation(lookup) catch return error.Busy;
    errdefer abortRegisteredNodeOperationReservation(reservation);
    // The sole nested order is ClientSlot registry -> operation registry publication.
    while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer client_slot_registry_mutex.unlock();
    for (client_slot_registry) |entry| {
        if (!entry.live or !entry.ready or entry.slot_addr != lookup.slot_addr or
            entry.slot_incarnation != lookup.slot_incarnation or
            entry.node_addr == 0 or entry.node_incarnation == 0 or
            switch (lookup.node) {
                .incarnation => |value| entry.node_incarnation != value,
                .address => |value| entry.node_addr != value,
            } or
            (lookup.owner_thread_incarnation != null and
                entry.owner_thread_incarnation != lookup.owner_thread_incarnation.?) or
            !operationThreadMatches(entry.owner_thread_incarnation))
            continue;
        const node: *ClientNode = @ptrFromInt(entry.node_addr);
        node.client.beginClientSlotOperation() catch |err| return switch (err) {
            error.AdminBusy => error.Busy,
            else => error.InvalidOwner,
        };
        return publishRegisteredNodeOperation(reservation, entry);
    }
    return error.InvalidOwner;
}

fn endRegisteredNodeOperation(operation: RegisteredNodeOperation) void {
    const pid = currentPid();
    const index: usize = operation.registry_index;
    if (pid == 0 or operation.pid != pid or process_runtime_pid.load(.acquire) != pid or
        index >= registered_node_operations.len or operation.operation_id == 0 or
        @intFromPtr(operation.node) == 0)
        @panic("invalid registered node operation process domain");
    var node_addr: usize = 0;
    while (!registered_node_operation_mutex.tryLock()) std.atomic.spinLoopHint();
    const candidate = &registered_node_operations[index];
    if (candidate.state == .live and candidate.operation_id == operation.operation_id and
        candidate.node_addr == @intFromPtr(operation.node) and candidate.pid == pid and
        operationThreadMatches(candidate.owner_thread_incarnation))
    {
        candidate.state = .releasing;
        node_addr = candidate.node_addr;
    }
    registered_node_operation_mutex.unlock();
    if (node_addr == 0) @panic("invalid registered node operation release");
    const node: *ClientNode = @ptrFromInt(node_addr);
    if (builtin.is_test) {
        const observer = &node.guarded_allocator.request_free_test_observer;
        const receipt = (@as(u128, operation.operation_id) << 64) |
            @as(u128, operation.registry_index + 1);
        if (observer.registered_operation_active_receipt != receipt or
            observer.registered_operation_begin_count == 0 or
            observer.registered_operation_end_count == std.math.maxInt(usize) or
            observer.registered_operation_begin_count != observer.registered_operation_end_count + 1 or
            observer.registered_operation_end_count >= observer.registered_operation_end_receipts.len or
            observer.registered_operation_begin_receipts[observer.registered_operation_end_count] != receipt)
            observer.registered_operation_receipt_drift = true;
        if (observer.registered_operation_end_count < observer.registered_operation_end_receipts.len)
            observer.registered_operation_end_receipts[observer.registered_operation_end_count] = receipt;
        observer.registered_operation_end_count +|= 1;
        observer.registered_operation_active_receipt = 0;
    }
    if (!node.client.endClientSlotOperation())
        @panic("ClientSlot registered node operation fence release failed");
    while (!registered_node_operation_mutex.tryLock()) std.atomic.spinLoopHint();
    defer registered_node_operation_mutex.unlock();
    const entry = &registered_node_operations[index];
    if (entry.state != .releasing or entry.operation_id != operation.operation_id or
        entry.node_addr != node_addr)
        @panic("registered node operation release publication drifted");
    entry.* = .{};
    if (registered_node_operation_free_count >= registered_node_operation_free_stack.len)
        @panic("registered node operation free stack overflow");
    registered_node_operation_free_stack[registered_node_operation_free_count] =
        operation.registry_index;
    registered_node_operation_free_count += 1;
}

const GenerationRequestOwner = struct {
    operation: RegisteredNodeOperation,
    identity: contract.BindingIdentity,
    owner: *contract.TransportOwnerSeal,
};

/// Shared registry-first admission for every prepared-request transition. The returned operation
/// pins the canonical node until the caller settles both request backing and node authority.
fn beginGenerationRequestOwner(
    request: anytype,
    comptime allow_active_cleanup: bool,
) GenerationRequestError!GenerationRequestOwner {
    if (client_mod.generationAllocatorCallbackActive() or batch_release_callback_active)
        return error.Busy;
    if (request.slot_addr == 0 or request.slot_incarnation == 0 or
        request.node_incarnation == 0 or request.host_id == 0 or request.pid != currentPid() or
        request.process_nonce == 0 or request.transport_addr == 0 or
        request.transport_incarnation == 0 or request.owner_seal_addr == 0 or
        request.prepared_storage_addr == 0)
        return error.InvalidOwner;
    const operation = beginRegisteredNodeOperation(.{
        .slot_addr = request.slot_addr,
        .slot_incarnation = request.slot_incarnation,
        .node = .{ .incarnation = request.node_incarnation },
    }) catch |err| return switch (err) {
        error.Busy => error.Busy,
        error.InvalidOwner => error.InvalidOwner,
    };
    errdefer endRegisteredNodeOperation(operation);
    const node = operation.node;
    if (builtin.is_test) {
        const observer = &node.guarded_allocator.request_free_test_observer;
        const receipt = (@as(u128, operation.operation_id) << 64) |
            @as(u128, operation.registry_index + 1);
        if (observer.registered_operation_active_receipt != 0 or
            observer.registered_operation_begin_count != observer.registered_operation_end_count or
            observer.registered_operation_begin_count >= observer.registered_operation_begin_receipts.len)
            observer.registered_operation_receipt_drift = true;
        if (observer.registered_operation_begin_count < observer.registered_operation_begin_receipts.len)
            observer.registered_operation_begin_receipts[observer.registered_operation_begin_count] = receipt;
        observer.registered_operation_begin_count +|= 1;
        observer.registered_operation_active_receipt = receipt;
    }
    if (!streamOperationNodeIdle(node) or !node.rpc_free_evidence.emptyExact() or
        (node.pin_owner.active_cleanup != 0 and
            !(allow_active_cleanup and node.pin_owner.active_cleanup == 1)))
        return error.Busy;
    const identity = request.reservation.identity;
    if (!identity.valid() or identity.slot_incarnation != request.slot_incarnation or
        identity.node_incarnation != request.node_incarnation or identity.host_id != request.host_id or
        identity.connection_generation != 1 or identity.pid != request.pid or
        identity.process_nonce != request.process_nonce or node.client.host_id != request.host_id)
        return error.InvalidOwner;
    const owner = node.cleanup_registry.transportOwnerSeal(
        request.reservation.cleanup,
        identity,
    ) catch return error.InvalidOwner;
    if (@intFromPtr(owner) != request.owner_seal_addr or
        !owner.valid(request.transport_incarnation) or
        owner.transport_addr != request.transport_addr or
        owner.prepared_storage_addr != request.prepared_storage_addr)
        return error.InvalidOwner;
    if (comptime @hasField(@TypeOf(request), "owner_addr")) {
        if (owner.owner_addr != request.owner_addr or owner.owner_size != request.owner_size)
            return error.InvalidOwner;
    }
    return .{ .operation = operation, .identity = identity, .owner = owner };
}

/// Resolves an untrusted transport's scalar slot identity through the canonical registry before
/// converting any supplied address to a pointer. The registry lock pins the exact node operation,
/// so teardown cannot create an address ABA between resolution and capability projection.
pub fn projectGenerationCapabilities(
    request: CapabilityProjectionRequest,
) CapabilityProjectionError!contract.GenerationCapabilities {
    if (client_mod.generationAllocatorCallbackActive() or batch_release_callback_active)
        return error.Busy;
    if (request.slot_addr == 0 or request.slot_incarnation == 0 or
        request.node_incarnation == 0 or request.host_id == 0 or request.pid != currentPid() or
        request.process_nonce == 0 or request.transport_incarnation == 0 or
        request.owner_seal_addr == 0)
        return error.InvalidOwner;

    const operation = beginRegisteredNodeOperation(.{
        .slot_addr = request.slot_addr,
        .slot_incarnation = request.slot_incarnation,
        .node = .{ .incarnation = request.node_incarnation },
    }) catch |err| return switch (err) {
        error.Busy => error.Busy,
        error.InvalidOwner => error.InvalidOwner,
    };
    defer endRegisteredNodeOperation(operation);
    const node = operation.node;

    if (!streamOperationNodeIdle(node) or node.pin_owner.active_cleanup != 0)
        return error.Busy;
    const identity = request.reservation.identity;
    if (identity.slot_incarnation != request.slot_incarnation or
        identity.node_incarnation != request.node_incarnation or
        identity.host_id != request.host_id or identity.connection_generation != 1 or
        identity.pid != request.pid or identity.process_nonce != request.process_nonce)
        return error.InvalidOwner;
    const binding_owner_seal = node.cleanup_registry.transportOwnerSeal(
        request.reservation.cleanup,
        identity,
    ) catch return error.InvalidOwner;
    if (@intFromPtr(binding_owner_seal) != request.owner_seal_addr or
        !binding_owner_seal.valid(request.transport_incarnation))
        return error.InvalidOwner;
    if (node.client.host_id != request.host_id) return error.InvalidOwner;

    const profile = node.client.compatibility_profile orelse return error.InvalidOwner;
    const attach_schema_raw = @as(*const u8, @ptrCast(&profile.attach_schema)).*;
    const metadata_support_raw = @as(*const u8, @ptrCast(&node.client.metadata_support)).*;
    if (attach_schema_raw > @intFromEnum(compatibility.AttachSchema.granted_roles) or
        metadata_support_raw > @intFromEnum(contract.MetadataSupport.supported))
        return error.InvalidOwner;
    return .{
        .wire_major = node.client.wire_major,
        .screen_codec_version = node.client.screen_codec_version,
        .attach_schema = switch (profile.attach_schema) {
            .frozen_controller_only => .frozen_controller_only,
            .granted_roles => .granted_roles,
        },
        .metadata_support = switch (node.client.metadata_support) {
            .unsupported => .unsupported,
            .supported => .supported,
        },
        .peer_attach_generation = node.client.attachment_capabilities.peer_attach_generation,
        .screen_viewport_scrolled = node.client.screen_viewport_scrolled_v1,
        .async_scroll_to_bottom = node.client.async_scroll_to_bottom_v1,
        .notification_stream_auth = node.client.notification_stream_auth_v1,
        .runtime_clipboard = node.client.runtime_clipboard_v1,
        .runtime_core_command = node.client.runtime_core_command_v1,
        .runtime_link_at = node.client.runtime_link_at_v1,
        .runtime_selected_text = node.client.runtime_selected_text_v1,
    };
}

fn stringifyGenerationParams(out: []u8, value: anytype) ?[]const u8 {
    var writer = std.Io.Writer.fixed(out);
    var json: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    json.write(value) catch return null;
    return writer.buffered();
}

/// Canonical request encoder. Binding-owned runtime/stream identity is injected here exactly once;
/// no public request variant can carry a foreign identity or an encoded JSON discriminator.
fn encodeGenerationRequestParams(
    out: []u8,
    identity: contract.BindingIdentity,
    stream_id: u64,
    request: contract.ValidatedRuntimeRequest,
) ?[]const u8 {
    return switch (request) {
        .spawn_full => null,
        .attach_controller => std.fmt.bufPrint(
            out,
            "{{\"runtime_id\":\"{x:0>32}\",\"mode\":\"controller\"}}",
            .{identity.runtime_id},
        ) catch null,
        .resize => |v| stringifyGenerationParams(out, .{
            .stream_id = stream_id,
            .cols = v.cols,
            .rows = v.rows,
            .client_sequence = v.client_sequence,
        }),
        .observation, .clipboard_write, .notification, .detach => stringifyGenerationParams(out, .{ .stream_id = stream_id }),
        .selected_text => |v| stringifyGenerationParams(out, .{
            .stream_id = stream_id,
            .sr = v.start_row,
            .sc = v.start_col,
            .er = v.end_row,
            .ec = v.end_col,
            .block = v.block,
        }),
        .link_at => |v| stringifyGenerationParams(out, .{
            .stream_id = stream_id,
            .row = v.row,
            .col = v.col,
            .scopes = v.scopes,
        }),
        .find => |v| blk: {
            const query = v.bytes() orelse break :blk null;
            var hex: [512]u8 = undefined;
            const digits = "0123456789abcdef";
            for (query, 0..) |byte, index| {
                hex[index * 2] = digits[byte >> 4];
                hex[index * 2 + 1] = digits[byte & 0x0f];
            }
            break :blk stringifyGenerationParams(out, .{
                .stream_id = stream_id,
                .q = hex[0 .. query.len * 2],
                .cur = v.current,
                .scroll = v.scroll,
            });
        },
        .select_op => |v| stringifyGenerationParams(out, .{
            .stream_id = stream_id,
            .op = switch (v.kind) {
                .word => "word",
                .line => "line",
            },
            .row = v.row,
            .col = v.col,
        }),
        .core_command => |v| encodeGenerationCoreCommand(out, stream_id, v),
        .report_mouse => |v| stringifyGenerationParams(out, .{
            .stream_id = stream_id,
            .button = v.button,
            .col = v.col,
            .row = v.row,
            .x_px = v.x_px,
            .y_px = v.y_px,
            .pressed = v.pressed,
            .motion = v.motion,
            .mods = v.mods,
        }),
        .terminate => std.fmt.bufPrint(
            out,
            "{{\"runtime_id\":\"{x:0>32}\"}}",
            .{identity.runtime_id},
        ) catch null,
    };
}

fn encodeGenerationCoreCommand(
    out: []u8,
    stream_id: u64,
    command: contract.CoreCommandRequest,
) ?[]const u8 {
    return switch (command) {
        .scroll => |arg| stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "scroll", .arg = arg }),
        .scroll_to_bottom => stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "scroll_to_bottom" }),
        .scroll_to_abs => |arg| stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "scroll_to_abs", .arg = arg }),
        .scroll_to_offset => |arg| stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "scroll_to_offset", .arg = arg }),
        .report_focus => |gained| stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "report_focus", .gained = gained }),
        .set_cell_metrics => |v| stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "set_cell_metrics", .width = v.width, .height = v.height }),
        .set_default_colors => |v| stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "set_default_colors", .foreground = v.foreground, .background = v.background }),
        .set_config_palette => |palette| stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "set_config_palette", .palette = palette }),
        .set_max_scrollback => |lines| stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "set_max_scrollback", .lines = lines }),
        .set_ambiguous_wide => |wide| stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "set_ambiguous_wide", .wide = wide }),
        .set_emoji_wide => |wide| stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "set_emoji_wide", .wide = wide }),
        .set_default_cursor_shape => |shape| stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "set_default_cursor_shape", .shape = shape }),
        .set_runtime_config => |v| stringifyGenerationParams(out, .{
            .stream_id = stream_id,
            .op = "set_runtime_config",
            .lines = v.max_scrollback,
            .ambiguous_wide = v.ambiguous_wide,
            .emoji_wide = v.emoji_wide,
            .palette = v.palette,
            .foreground = v.foreground,
            .background = v.background,
            .cell_width = v.cell_width,
            .cell_height = v.cell_height,
            .cursor_shape = v.cursor_shape,
        }),
        .jump_to_prompt => |direction| stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "jump_to_prompt", .direction = direction }),
        .reset_input_modes => stringifyGenerationParams(out, .{ .stream_id = stream_id, .op = "reset_input_modes" }),
    };
}

test "CR3a-2c3b typed request encoder injects only canonical binding identities" {
    const identity: contract.BindingIdentity = .{
        .binding_incarnation = 1,
        .binding_storage_addr = 2,
        .destination_addr = 3,
        .binding_reservation_id = 4,
        .slot_incarnation = 5,
        .node_incarnation = 6,
        .host_id = 7,
        .connection_generation = 1,
        .runtime_id = 0xaa,
        .role = .controller,
        .pid = 8,
        .process_nonce = 9,
    };
    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"runtime_id\":\"000000000000000000000000000000aa\",\"mode\":\"controller\"}",
        encodeGenerationRequestParams(&buffer, identity, 77, .attach_controller).?,
    );
    try std.testing.expectEqualStrings(
        "{\"stream_id\":77,\"q\":\"61ed959c\",\"cur\":2,\"scroll\":true}",
        encodeGenerationRequestParams(&buffer, identity, 77, .{
            .find = contract.FindRequest.init("a한", 2, true).?,
        }).?,
    );
    try std.testing.expectEqualStrings(
        "{\"runtime_id\":\"000000000000000000000000000000aa\"}",
        encodeGenerationRequestParams(&buffer, identity, 77, .terminate).?,
    );
    try std.testing.expect(encodeGenerationRequestParams(
        &buffer,
        identity,
        77,
        .spawn_full,
    ) == null);
}

/// All-or-none request-side transaction. Untrusted transport addresses remain scalars until the
/// live ClientSlot registry pins the canonical node and its owner seal proves the exact transport
/// and opaque storage destinations.
pub fn prepareGenerationRequest(
    request: GenerationRequestPrepare,
) GenerationRequestError!GenerationPreparedRequest {
    const decoded = request.request.decode() orelse return error.InvalidOwner;
    if (request.owner_addr == 0 or request.owner_size == 0)
        return error.InvalidOwner;
    _ = std.math.add(usize, request.owner_addr, request.owner_size) catch
        return error.InvalidOwner;
    const tag = std.meta.activeTag(decoded);
    const family = decoded.family();
    if (family == .connection_only_denied) return error.Unauthorized;
    const admission = try beginGenerationRequestOwner(request, false);
    defer endRegisteredNodeOperation(admission.operation);
    const node = admission.operation.node;
    const identity = admission.identity;
    const decision = node.cleanup_registry.requestDecision(
        request.reservation.cleanup,
        identity,
        family,
        tag,
        request.bound_stream_id,
    ) catch return error.InvalidOwner;
    switch (decision) {
        .allowed => {},
        .unauthorized => return error.Unauthorized,
        .busy => return error.Busy,
    }

    const storage: *client_mod.PreparedBlockingRpcStorage =
        @ptrFromInt(request.prepared_storage_addr);
    var allocator_scope: client_mod.Client.GenerationAllocatorScope = .{};
    const request_ranges = [_]GenerationGuardedAllocator.OperationRangeInput{
        .{ .start = request.owner_addr, .len = request.owner_size },
        .{ .start = identity.binding_storage_addr, .len = @sizeOf(contract.PreparedAttachmentBinding) },
        .{ .start = request.prepared_storage_addr, .len = @sizeOf(client_mod.PreparedBlockingRpcStorage) },
        .{ .start = request.owner_seal_addr, .len = @sizeOf(contract.TransportOwnerSeal) },
        .{ .start = @intFromPtr(&allocator_scope), .len = @sizeOf(client_mod.Client.GenerationAllocatorScope) },
    };
    const guard = &node.guarded_allocator;
    if (!guard.beginOperationGuard(&request_ranges)) return error.InvalidOwner;
    defer guard.endOperationGuard();
    node.client.beginGenerationAllocatorScope(
        guard.allocator(),
        .rpc_prepare,
        &allocator_scope,
    ) catch |err| {
        if (err == error.IdentityExhausted) {
            node.client.poison(.local_invariant_violation);
            return error.IdentityExhausted;
        }
        return error.Busy;
    };
    defer node.client.restoreGenerationAllocatorScope(&allocator_scope) catch
        @panic("generation allocator scope restore drifted");
    var params_buffer: [4096]u8 = undefined;
    const params_json = encodeGenerationRequestParams(
        &params_buffer,
        identity,
        request.bound_stream_id,
        decoded,
    ) orelse return error.ResourceExhausted;
    const prepared_identity = node.client.prepareBlockingRpcStorage(
        storage,
        contract.requestMethod(tag),
        params_json,
    ) catch |err| {
        if (guard.operation_alias_rejected) {
            node.client.poison(.local_invariant_violation);
            return error.ProtocolError;
        }
        return mapGenerationRequestClientError(err);
    };
    const receipt = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = request.transport_incarnation,
        .request_id = prepared_identity.request_id,
        .request_digest = prepared_identity.frame_digest,
    }) orelse {
        _ = node.client.abortPreparedBlockingRpcStorageCanonical(
            storage,
            prepared_identity,
        ) catch @panic("canonical prepared request receipt rollback failed");
        return error.ProtocolError;
    };
    const canonical: prepared_request_authority.Prepared = .{
        .transport_addr = request.transport_addr,
        .transport_incarnation = request.transport_incarnation,
        .binding = identity,
        .tag = tag,
        .family = family,
        .receipt = receipt,
        .descriptor = prepared_identity.descriptor,
    };
    node.cleanup_registry.publishPreparedRequest(
        request.reservation.cleanup,
        identity,
        canonical,
    ) catch {
        const outcome = node.client.abortPreparedBlockingRpcStorageCanonical(
            storage,
            prepared_identity,
        ) catch @panic("canonical prepared request publication rollback failed");
        if (outcome == .terminal) node.client.poison(.local_invariant_violation);
        return error.ProtocolError;
    };
    return .{ .receipt = receipt, .canonical = canonical };
}

pub fn abortGenerationRequest(request: GenerationRequestAbort) GenerationRequestError!void {
    if (!request.receipt.valid()) return error.InvalidOwner;
    const admission = try beginGenerationRequestOwner(request, false);
    defer endRegisteredNodeOperation(admission.operation);
    const node = admission.operation.node;
    const identity = admission.identity;
    const maybe_canonical = node.cleanup_registry.preparedRequestForReceipt(
        request.reservation.cleanup,
        identity,
        request.transport_addr,
        request.transport_incarnation,
        request.receipt,
    ) catch return error.InvalidOwner;
    const canonical = maybe_canonical orelse return error.InvalidReceipt;
    const storage: *client_mod.PreparedBlockingRpcStorage =
        @ptrFromInt(request.prepared_storage_addr);
    const prepared_identity: client_mod.PreparedBlockingRpcIdentity = .{
        .request_id = canonical.receipt.request_id,
        .frame_digest = canonical.receipt.request_digest,
        .descriptor = canonical.descriptor,
    };
    const outcome = node.client.abortPreparedBlockingRpcStorageCanonical(
        storage,
        prepared_identity,
    ) catch |err| switch (err) {
        error.AdminBusy => return error.Busy,
        else => {
            node.cleanup_registry.settlePreparedRequest(
                request.reservation.cleanup,
                identity,
                canonical,
                true,
            ) catch @panic("ambiguous prepared request authority terminalization failed");
            node.client.poison(.local_invariant_violation);
            return error.ProtocolError;
        },
    };
    node.cleanup_registry.settlePreparedRequest(
        request.reservation.cleanup,
        identity,
        canonical,
        outcome == .terminal,
    ) catch @panic("prepared request authority settlement drifted");
    if (outcome == .terminal) {
        node.client.poison(.local_invariant_violation);
        return error.ProtocolError;
    }
}

const PreparedExecutionPhase = enum(u8) {
    prepared_unbegun,
    pre_wire_backing_live,
    post_execute_backing_settled,
    settled,
};

const FailStopReason = enum(u8) {
    authority_drift,
    backing_ambiguous,
    duplicate_settlement,
    cleanup_failure,
};

const PreparedExecutionSettlementTag = enum(u8) {
    pending,
    reusable,
    terminal,
    fail_stop_required,
};

const PreparedExecutionSettlement = struct {
    tag: PreparedExecutionSettlementTag = .pending,
    reason_raw: u8 = 0,

    fn rawValid(self: *const @This()) bool {
        const tag_raw = @as(*const u8, @ptrCast(&self.tag)).*;
        if (tag_raw > @intFromEnum(PreparedExecutionSettlementTag.fail_stop_required)) return false;
        return switch (self.tag) {
            .pending, .reusable => self.reason_raw == 0,
            .terminal => self.reason_raw < std.meta.fields(client_poison.ConnectionReason).len,
            .fail_stop_required => self.reason_raw < std.meta.fields(FailStopReason).len,
        };
    }

    fn pendingExact(self: *const @This()) bool {
        return self.rawValid() and self.tag == .pending;
    }

    fn terminalReason(self: *const @This()) ?client_poison.ConnectionReason {
        if (!self.rawValid() or self.tag != .terminal) return null;
        return @enumFromInt(self.reason_raw);
    }

    fn failStopReason(self: *const @This()) ?FailStopReason {
        if (!self.rawValid() or self.tag != .fail_stop_required) return null;
        return @enumFromInt(self.reason_raw);
    }

    fn reusable() @This() {
        return .{ .tag = .reusable };
    }

    fn terminal(reason: client_poison.ConnectionReason) @This() {
        return .{ .tag = .terminal, .reason_raw = @intFromEnum(reason) };
    }

    fn failStop(reason: FailStopReason) @This() {
        return .{ .tag = .fail_stop_required, .reason_raw = @intFromEnum(reason) };
    }
};

const SettlementOutcome = union(enum) {
    reusable,
    terminal: client_poison.ConnectionReason,
    fail_stop_required: FailStopReason,
};

const PreparedExecutionSnapshot = struct {
    txn_addr: usize,
    node_addr: usize,
    operation_id: u64,
    reservation: AttachmentBindingReservation,
    binding_identity: contract.BindingIdentity,
    canonical_prepared: prepared_request_authority.Prepared,
    prepared_identity: client_mod.PreparedBlockingRpcIdentity,
    phase: PreparedExecutionPhase,
    settlement: PreparedExecutionSettlement,
};

const PreparedExecutionCanonical = struct {
    node: *ClientNode,
    snapshot: PreparedExecutionSnapshot,
    canonical: prepared_request_authority.Prepared,
};

const PreparedExecutionTxn = struct {
    self_addr: usize = 0,
    node_addr: usize = 0,
    operation_id: u64 = 0,
    reservation: AttachmentBindingReservation = std.mem.zeroes(AttachmentBindingReservation),
    binding_identity: contract.BindingIdentity = std.mem.zeroes(contract.BindingIdentity),
    canonical_prepared: prepared_request_authority.Prepared = std.mem.zeroes(prepared_request_authority.Prepared),
    prepared_identity: client_mod.PreparedBlockingRpcIdentity = std.mem.zeroes(client_mod.PreparedBlockingRpcIdentity),
    phase: PreparedExecutionPhase = .prepared_unbegun,
    settlement: PreparedExecutionSettlement = .{},

    const InitError = error{ InvalidOwner, InvalidReceipt, ProtocolError };
    const SettlementError = error{ProtocolError};

    fn initBeforeBeginExecute(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
        request: GenerationRequestAbort,
        identity: contract.BindingIdentity,
        canonical: prepared_request_authority.Prepared,
    ) PreparedExecutionTxn.InitError!void {
        if (!self.semanticPristine()) return error.InvalidOwner;
        const node = resolveRegisteredNodeOperation(operation) orelse return error.InvalidOwner;
        if (!identity.valid() or !canonical.valid() or
            !std.meta.eql(request.reservation.identity, identity) or
            !std.meta.eql(canonical.binding, identity) or
            canonical.transport_addr != request.transport_addr or
            canonical.transport_incarnation != request.transport_incarnation or
            !canonical.receipt.matches(request.receipt) or
            canonical.descriptor.storage_addr != request.prepared_storage_addr or
            canonical.descriptor.client_addr != @intFromPtr(&node.client))
            return error.InvalidOwner;
        const present = node.cleanup_registry.preparedRequestForReceipt(
            request.reservation.cleanup,
            identity,
            request.transport_addr,
            request.transport_incarnation,
            request.receipt,
        ) catch return error.InvalidOwner;
        if (present == null or !std.meta.eql(present.?, canonical)) return error.InvalidReceipt;
        const prepared_identity = identityFromCanonical(canonical);
        const request_storage: *client_mod.PreparedBlockingRpcStorage =
            @ptrFromInt(canonical.descriptor.storage_addr);
        if (!node.client.preparedBlockingRpcStorageMatches(request_storage, prepared_identity))
            return error.ProtocolError;
        self.node_addr = @intFromPtr(node);
        self.operation_id = operation.operation_id;
        self.reservation = request.reservation;
        self.binding_identity = identity;
        self.canonical_prepared = canonical;
        self.prepared_identity = prepared_identity;
        self.phase = .prepared_unbegun;
        self.settlement = .{};
        self.self_addr = @intFromPtr(self);
    }

    fn commitBeginExecute(self: *PreparedExecutionTxn, operation: RegisteredNodeOperation) void {
        const node = self.ownerNode(operation) orelse
            @panic("prepared execution transaction begin owner drifted");
        if (self.phase != .prepared_unbegun or !self.settlement.pendingExact())
            @panic("prepared execution transaction begin drifted");
        node.cleanup_registry.beginPreparedRequestExecute(
            self.reservation.cleanup,
            self.binding_identity,
            self.canonical_prepared,
        ) catch {
            node.cleanup_registry.settlePreparedRequest(
                self.reservation.cleanup,
                self.binding_identity,
                self.canonical_prepared,
                true,
            ) catch {};
            node.client.poison(.local_invariant_violation);
            self.settlement = PreparedExecutionSettlement.failStop(.authority_drift);
            self.phase = .settled;
            failStopPreparedExecution(.authority_drift);
        };
        self.phase = .pre_wire_backing_live;
    }

    fn settleUnbegun(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
        terminal: bool,
    ) SettlementError!SettlementOutcome {
        const node = self.ownerNode(operation) orelse return error.ProtocolError;
        if (self.phase != .prepared_unbegun or !self.settlement.pendingExact())
            return error.ProtocolError;
        const present = node.cleanup_registry.preparedRequestForReceipt(
            self.reservation.cleanup,
            self.binding_identity,
            self.canonical_prepared.transport_addr,
            self.canonical_prepared.transport_incarnation,
            self.canonical_prepared.receipt,
        ) catch return error.ProtocolError;
        if (present == null or !std.meta.eql(present.?, self.canonical_prepared))
            return error.ProtocolError;
        const outcome = node.client.abortPreparedBlockingRpcStorageCanonical(
            @ptrFromInt(self.canonical_prepared.descriptor.storage_addr),
            self.prepared_identity,
        ) catch return error.ProtocolError;
        const must_terminal = terminal or outcome == .terminal;
        node.cleanup_registry.settlePreparedRequest(
            self.reservation.cleanup,
            self.binding_identity,
            self.canonical_prepared,
            must_terminal,
        ) catch return error.ProtocolError;
        self.phase = .post_execute_backing_settled;
        if (must_terminal) {
            node.client.poison(.local_invariant_violation);
            return self.publishTerminal(node.client.firstPoisonReason().?);
        }
        return self.publishReusable();
    }

    fn revalidatePreWire(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
    ) error{ InvalidOwner, InvalidReceipt }!void {
        if (self.ownerNode(operation) == null) return error.InvalidOwner;
        const expected = self.canonicalExecuting(operation) orelse return error.InvalidReceipt;
        if (!expected.node.client.preparedBlockingRpcStorageMatches(
            canonicalStorage(expected),
            expected.snapshot.prepared_identity,
        ))
            return error.InvalidReceipt;
    }

    fn rollbackPreWire(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
    ) SettlementError!SettlementOutcome {
        return self.rollbackPreWireWithLease(operation, null);
    }

    fn rollbackPreWireWithLease(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
        lease: ?*client_mod.PreparedRequestExecutionLease,
    ) SettlementError!SettlementOutcome {
        try self.requireCleanupClosed(operation);
        const expected = self.canonicalExecuting(operation) orelse return error.ProtocolError;
        const abort_outcome = if (lease) |held|
            expected.node.client.abortPreparedBlockingRpcStorageUnderExecutionLease(
                canonicalStorage(expected),
                expected.snapshot.prepared_identity,
                held,
            )
        else
            expected.node.client.abortPreparedBlockingRpcStorageCanonical(
                canonicalStorage(expected),
                expected.snapshot.prepared_identity,
            );
        const settled = abort_outcome catch {
            self.failStopAfterCallbackDrift(operation, expected, .backing_ambiguous);
            return error.ProtocolError;
        };
        const node = self.canonicalStillExact(operation, expected) orelse {
            self.failStopAfterCallbackDrift(operation, expected, .authority_drift);
            return error.ProtocolError;
        };
        self.phase = .post_execute_backing_settled;
        const terminal = settled == .terminal;
        node.cleanup_registry.settlePreparedRequest(
            expected.snapshot.reservation.cleanup,
            expected.snapshot.binding_identity,
            expected.canonical,
            terminal,
        ) catch {
            self.failStopSettlement(node, .authority_drift);
            return error.ProtocolError;
        };
        if (terminal) {
            const reason: client_poison.ConnectionReason = .local_invariant_violation;
            if (lease) |held|
                node.client.poisonPreparedRequestExecution(held, reason) catch {
                    self.failStopSettlement(node, .authority_drift);
                    return error.ProtocolError;
                }
            else
                node.client.poison(reason);
            const published_reason = if (lease) |held|
                node.client.preparedRequestExecutionPoisonReason(held) catch
                    return error.ProtocolError
            else
                node.client.firstPoisonReason();
            return self.publishTerminal(published_reason orelse reason);
        }
        return self.publishReusable();
    }

    fn settlePreWireTerminal(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
        reason: client_poison.ConnectionReason,
    ) SettlementError!SettlementOutcome {
        return self.settlePreWireTerminalWithLease(operation, reason, null);
    }

    fn settlePreWireTerminalWithLease(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
        reason: client_poison.ConnectionReason,
        lease: ?*client_mod.PreparedRequestExecutionLease,
    ) SettlementError!SettlementOutcome {
        try self.requireCleanupClosed(operation);
        const expected = self.canonicalExecuting(operation) orelse return error.ProtocolError;
        const abort_result = if (lease) |held|
            expected.node.client.abortPreparedBlockingRpcStorageUnderExecutionLease(
                canonicalStorage(expected),
                expected.snapshot.prepared_identity,
                held,
            )
        else
            expected.node.client.abortPreparedBlockingRpcStorageCanonical(
                canonicalStorage(expected),
                expected.snapshot.prepared_identity,
            );
        _ = abort_result catch {
            self.failStopAfterCallbackDrift(operation, expected, .backing_ambiguous);
            return error.ProtocolError;
        };
        const node = self.canonicalStillExact(operation, expected) orelse {
            self.failStopAfterCallbackDrift(operation, expected, .authority_drift);
            return error.ProtocolError;
        };
        self.phase = .post_execute_backing_settled;
        node.cleanup_registry.settlePreparedRequest(
            expected.snapshot.reservation.cleanup,
            expected.snapshot.binding_identity,
            expected.canonical,
            true,
        ) catch {
            self.failStopSettlement(node, .authority_drift);
            return error.ProtocolError;
        };
        if (lease) |held|
            node.client.poisonPreparedRequestExecution(held, reason) catch {
                self.failStopSettlement(node, .authority_drift);
                return error.ProtocolError;
            }
        else
            node.client.poison(reason);
        const published_reason = if (lease) |held|
            node.client.preparedRequestExecutionPoisonReason(held) catch
                return error.ProtocolError
        else
            node.client.firstPoisonReason();
        return self.publishTerminal(published_reason orelse reason);
    }

    fn retireIssuerExhausted(self: *PreparedExecutionTxn, operation: RegisteredNodeOperation) SettlementError!SettlementOutcome {
        try self.requireCleanupClosed(operation);
        const expected = self.canonicalExecuting(operation) orelse return error.ProtocolError;
        const abort_outcome = expected.node.client.abortPreparedBlockingRpcStorageCanonical(
            canonicalStorage(expected),
            expected.snapshot.prepared_identity,
        ) catch {
            self.failStopAfterCallbackDrift(operation, expected, .backing_ambiguous);
            return error.ProtocolError;
        };
        const node = self.canonicalStillExact(operation, expected) orelse {
            self.failStopAfterCallbackDrift(operation, expected, .authority_drift);
            return error.ProtocolError;
        };
        self.phase = .post_execute_backing_settled;
        node.cleanup_registry.settlePreparedRequest(
            expected.snapshot.reservation.cleanup,
            expected.snapshot.binding_identity,
            expected.canonical,
            true,
        ) catch {
            self.failStopSettlement(node, .authority_drift);
            return error.ProtocolError;
        };
        node.client.poison(.local_invariant_violation);
        const outcome = self.publishTerminal(node.client.firstPoisonReason().?);
        if (abort_outcome == .terminal) return error.ProtocolError;
        return outcome;
    }

    fn settlePostExecuteReusable(self: *PreparedExecutionTxn, operation: RegisteredNodeOperation) SettlementError!SettlementOutcome {
        try self.requireCleanupClosed(operation);
        return self.settlePostExecuteReusableUnchecked(operation);
    }

    fn settlePostExecuteReusableUnderPublicationScope(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
    ) SettlementError!SettlementOutcome {
        const node = self.ownerNode(operation) orelse return error.ProtocolError;
        if (!node.guarded_allocator.operation_guard_active) return error.ProtocolError;
        return self.settlePostExecuteReusableUnchecked(operation);
    }

    fn settlePostExecuteReusableUnchecked(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
    ) SettlementError!SettlementOutcome {
        const expected = self.postExecuteReady(operation) orelse return error.ProtocolError;
        const node = expected.node;
        self.phase = .post_execute_backing_settled;
        node.cleanup_registry.settlePreparedRequest(
            expected.snapshot.reservation.cleanup,
            expected.snapshot.binding_identity,
            expected.canonical,
            false,
        ) catch {
            self.failStopSettlement(node, .authority_drift);
            return error.ProtocolError;
        };
        return self.publishReusable();
    }

    fn settlePostExecuteTerminal(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
        fallback_reason: client_poison.ConnectionReason,
    ) SettlementError!SettlementOutcome {
        return self.settlePostExecuteTerminalWithLease(operation, fallback_reason, null);
    }

    fn settlePostExecuteTerminalWithLease(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
        fallback_reason: client_poison.ConnectionReason,
        lease: ?*client_mod.PreparedRequestExecutionLease,
    ) SettlementError!SettlementOutcome {
        try self.requireCleanupClosed(operation);
        const expected = self.postExecuteReady(operation) orelse return error.ProtocolError;
        if (lease) |held|
            expected.node.client.poisonPreparedRequestExecution(held, fallback_reason) catch
                return error.ProtocolError
        else
            expected.node.client.poison(fallback_reason);
        const node = self.canonicalStillExact(operation, expected) orelse {
            self.failStopAfterCallbackDrift(operation, expected, .authority_drift);
            return error.ProtocolError;
        };
        const observed_reason = if (lease) |held|
            node.client.preparedRequestExecutionPoisonReason(held) catch
                return error.ProtocolError
        else
            node.client.firstPoisonReason();
        const canonical_reason = observed_reason orelse {
            self.failStopAfterCallbackDrift(operation, expected, .authority_drift);
            return error.ProtocolError;
        };
        self.phase = .post_execute_backing_settled;
        node.cleanup_registry.settlePreparedRequest(
            expected.snapshot.reservation.cleanup,
            expected.snapshot.binding_identity,
            expected.canonical,
            true,
        ) catch {
            self.failStopSettlement(node, .authority_drift);
            return error.ProtocolError;
        };
        return self.publishTerminal(canonical_reason);
    }

    /// Cleanup failure is process-fatal, so do not touch possibly ambiguous request backing.
    /// Retire only the canonical registry authority, poison the connection, and publish a closed
    /// fail-stop settlement before the caller panics.
    fn failStopCleanupFailure(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
    ) SettlementOutcome {
        const node = self.ownerNode(operation) orelse
            failStopPreparedExecution(.authority_drift);
        var authority_terminal = false;
        if (self.phase == .pre_wire_backing_live) {
            const canonical = node.cleanup_registry.executingRequestForReceipt(
                self.reservation.cleanup,
                self.binding_identity,
                self.canonical_prepared.transport_addr,
                self.canonical_prepared.transport_incarnation,
                self.canonical_prepared.receipt,
            ) catch null;
            if (canonical != null and std.meta.eql(canonical.?, self.canonical_prepared)) {
                authority_terminal = blk: {
                    node.cleanup_registry.settlePreparedRequest(
                        self.reservation.cleanup,
                        self.binding_identity,
                        self.canonical_prepared,
                        true,
                    ) catch break :blk false;
                    break :blk true;
                };
            }
        }
        node.client.poison(.local_invariant_violation);
        self.settlement = PreparedExecutionSettlement.failStop(.cleanup_failure);
        self.phase = .settled;
        if (builtin.is_test and c.getenv("MARU_SESSION_HOST_RESPONSE_ALIAS_EXEC") != null and
            c.getenv("MARU_SESSION_HOST_RESPONSE_ALIAS_CASE") != null)
        {
            if (!authority_terminal or
                !node.guarded_allocator.request_free_test_observer.cleanup_drift_consumed)
                @panic("B3 strict cleanup terminal publication was not observed");
            const marker = "B3_CLEANUP_AUTHORITY_TERMINAL\n";
            _ = c.write(2, marker.ptr, marker.len);
        }
        return .{ .fail_stop_required = .cleanup_failure };
    }

    fn requireCleanupClosed(self: *PreparedExecutionTxn, operation: RegisteredNodeOperation) SettlementError!void {
        const node = self.ownerNode(operation) orelse return error.ProtocolError;
        if (node.guarded_allocator.operation_guard_active) {
            const outcome = self.failStopCleanupFailure(operation);
            self.finishOrFailStop(operation, outcome);
        }
    }

    fn finishOrFailStop(self: *PreparedExecutionTxn, operation: RegisteredNodeOperation, outcome: SettlementOutcome) void {
        if (self.ownerNode(operation) == null or self.phase != .settled or
            !settlementMatchesOutcome(self.settlement, outcome))
            @panic("prepared execution transaction finish drifted");
        switch (outcome) {
            .reusable, .terminal => {},
            .fail_stop_required => |reason| failStopPreparedExecution(reason),
        }
    }

    fn ensureSettledOrFailStop(self: *PreparedExecutionTxn, operation: RegisteredNodeOperation) void {
        if (self.self_addr == 0) {
            if (self.semanticPristine()) return;
            failStopPreparedExecution(.authority_drift);
        }
        if (self.ownerNode(operation) == null) @panic("prepared execution transaction moved, copied, or outlived its operation");
        if (self.phase == .settled) {
            if (!self.settlement.rawValid()) @panic("prepared execution transaction settlement corrupt");
            return switch (self.settlement.tag) {
                .reusable, .terminal => {},
                .pending => @panic("prepared execution transaction settled pending"),
                .fail_stop_required => failStopPreparedExecution(self.settlement.failStopReason().?),
            };
        }
        if (self.phase == .prepared_unbegun) {
            self.settlement = PreparedExecutionSettlement.reusable();
            self.phase = .settled;
            return;
        }
        _ = self.retireIssuerExhausted(operation) catch
            failStopPreparedExecution(.backing_ambiguous);
        failStopPreparedExecution(.duplicate_settlement);
    }

    fn rawTagsValid(self: *const PreparedExecutionTxn) bool {
        const phase_raw = @as(*const u8, @ptrCast(&self.phase)).*;
        return phase_raw <= @intFromEnum(PreparedExecutionPhase.settled) and
            self.settlement.rawValid() and self.rawEmbeddedTagsValid();
    }

    fn rawEmbeddedTagsValid(self: *const PreparedExecutionTxn) bool {
        return contract.attachmentRoleRawValid(&self.reservation.identity.role) and
            contract.attachmentRoleRawValid(&self.binding_identity.role) and
            contract.attachmentRoleRawValid(&self.canonical_prepared.binding.role) and
            contract.runtimeRequestTagRawValid(&self.canonical_prepared.tag) and
            contract.requestFamilyRawValid(&self.canonical_prepared.family);
    }

    fn semanticPristine(self: *const PreparedExecutionTxn) bool {
        return self.rawTagsValid() and self.self_addr == 0 and self.node_addr == 0 and
            self.operation_id == 0 and self.phase == .prepared_unbegun and
            self.settlement.pendingExact() and
            std.meta.eql(self.reservation, std.mem.zeroes(AttachmentBindingReservation)) and
            std.meta.eql(self.binding_identity, std.mem.zeroes(contract.BindingIdentity)) and
            std.meta.eql(self.canonical_prepared, std.mem.zeroes(prepared_request_authority.Prepared)) and
            std.meta.eql(self.prepared_identity, std.mem.zeroes(client_mod.PreparedBlockingRpcIdentity));
    }

    fn ownerNode(self: *const PreparedExecutionTxn, operation: RegisteredNodeOperation) ?*ClientNode {
        if (!self.rawTagsValid() or self.self_addr != @intFromPtr(self) or
            self.operation_id == 0 or self.operation_id != operation.operation_id)
            return null;
        if (!self.binding_identity.valid() or !self.reservation.identity.valid() or
            !self.canonical_prepared.valid())
            return null;
        const node = resolveRegisteredNodeOperation(operation) orelse return null;
        if (self.node_addr == @intFromPtr(node) and
            std.meta.eql(self.reservation.identity, self.binding_identity) and
            std.meta.eql(self.canonical_prepared.binding, self.binding_identity) and
            std.meta.eql(self.prepared_identity, identityFromCanonical(self.canonical_prepared)))
            return node;
        return null;
    }

    fn snapshot(self: *const PreparedExecutionTxn) PreparedExecutionSnapshot {
        return .{
            .txn_addr = @intFromPtr(self),
            .node_addr = self.node_addr,
            .operation_id = self.operation_id,
            .reservation = self.reservation,
            .binding_identity = self.binding_identity,
            .canonical_prepared = self.canonical_prepared,
            .prepared_identity = self.prepared_identity,
            .phase = self.phase,
            .settlement = self.settlement,
        };
    }

    fn matchesSnapshot(self: *const PreparedExecutionTxn, expected: PreparedExecutionSnapshot) bool {
        return self.rawTagsValid() and expected.txn_addr == @intFromPtr(self) and
            self.self_addr == expected.txn_addr and self.node_addr == expected.node_addr and
            self.operation_id == expected.operation_id and
            std.meta.eql(self.reservation, expected.reservation) and
            std.meta.eql(self.binding_identity, expected.binding_identity) and
            std.meta.eql(self.canonical_prepared, expected.canonical_prepared) and
            std.meta.eql(self.prepared_identity, expected.prepared_identity) and
            self.phase == expected.phase and std.meta.eql(self.settlement, expected.settlement);
    }

    fn canonicalExecuting(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
    ) ?PreparedExecutionCanonical {
        const node = self.ownerNode(operation) orelse return null;
        if (self.phase != .pre_wire_backing_live or !self.settlement.pendingExact()) return null;
        const transcript = self.snapshot();
        const canonical = node.cleanup_registry.executingRequestForReceipt(
            transcript.reservation.cleanup,
            transcript.binding_identity,
            transcript.canonical_prepared.transport_addr,
            transcript.canonical_prepared.transport_incarnation,
            transcript.canonical_prepared.receipt,
        ) catch return null;
        const exact = canonical orelse return null;
        if (!std.meta.eql(exact, transcript.canonical_prepared) or
            !std.meta.eql(identityFromCanonical(exact), transcript.prepared_identity))
            return null;
        return .{ .node = node, .snapshot = transcript, .canonical = exact };
    }

    fn canonicalStillExact(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
        expected: PreparedExecutionCanonical,
    ) ?*ClientNode {
        if (!self.matchesSnapshot(expected.snapshot) or
            operation.operation_id != expected.snapshot.operation_id)
            return null;
        const node = resolveRegisteredNodeOperation(operation) orelse return null;
        if (@intFromPtr(node) != expected.snapshot.node_addr) return null;
        const canonical = node.cleanup_registry.executingRequestForReceipt(
            expected.snapshot.reservation.cleanup,
            expected.snapshot.binding_identity,
            expected.canonical.transport_addr,
            expected.canonical.transport_incarnation,
            expected.canonical.receipt,
        ) catch return null;
        if (canonical == null or !std.meta.eql(canonical.?, expected.canonical)) return null;
        return node;
    }

    fn canonicalStorage(expected: PreparedExecutionCanonical) *client_mod.PreparedBlockingRpcStorage {
        return @ptrFromInt(expected.canonical.descriptor.storage_addr);
    }

    fn postExecuteReady(self: *PreparedExecutionTxn, operation: RegisteredNodeOperation) ?PreparedExecutionCanonical {
        const expected = self.canonicalExecuting(operation) orelse return null;
        if (!client_mod.Client.preparedBlockingRpcStorageSettled(canonicalStorage(expected))) return null;
        return expected;
    }

    fn publishReusable(self: *PreparedExecutionTxn) SettlementOutcome {
        self.settlement = PreparedExecutionSettlement.reusable();
        self.phase = .settled;
        return .reusable;
    }

    fn publishTerminal(
        self: *PreparedExecutionTxn,
        reason: client_poison.ConnectionReason,
    ) SettlementOutcome {
        self.settlement = PreparedExecutionSettlement.terminal(reason);
        self.phase = .settled;
        return .{ .terminal = reason };
    }

    fn failStopSettlement(
        self: *PreparedExecutionTxn,
        node: *ClientNode,
        reason: FailStopReason,
    ) void {
        node.client.poison(.local_invariant_violation);
        self.settlement = PreparedExecutionSettlement.failStop(reason);
        self.phase = .settled;
    }

    fn failStopAfterCallbackDrift(
        self: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
        expected: PreparedExecutionCanonical,
        reason: FailStopReason,
    ) void {
        if (operation.operation_id == expected.snapshot.operation_id) {
            if (resolveRegisteredNodeOperation(operation)) |node| {
                if (@intFromPtr(node) == expected.snapshot.node_addr) {
                    const canonical = node.cleanup_registry.executingRequestForReceipt(
                        expected.snapshot.reservation.cleanup,
                        expected.snapshot.binding_identity,
                        expected.canonical.transport_addr,
                        expected.canonical.transport_incarnation,
                        expected.canonical.receipt,
                    ) catch null;
                    if (canonical != null and std.meta.eql(canonical.?, expected.canonical)) {
                        node.cleanup_registry.settlePreparedRequest(
                            expected.snapshot.reservation.cleanup,
                            expected.snapshot.binding_identity,
                            expected.canonical,
                            true,
                        ) catch {};
                    }
                    node.client.poison(.local_invariant_violation);
                }
            }
        }
        self.settlement = PreparedExecutionSettlement.failStop(reason);
        self.phase = .settled;
    }
};

const PreparedRpcExecutionPhase = enum(u8) {
    pristine,
    response_reserved,
    settled,
};

const RpcExecutedResponse = rpc_executed_response.RpcExecutedResponse;

fn responseDestinationSeal(destination_addr: usize) u64 {
    var hash = std.hash.Wyhash.init(0xB303_D357);
    hash.update(std.mem.asBytes(&destination_addr));
    const seal = hash.final();
    return if (seal == 0) 1 else seal;
}

/// B3-3-only composition owner. It adds only the response authority capability; request backing
/// and request-authority settlement remain delegated to PreparedExecutionTxn.
const PreparedRpcExecutionTxn = struct {
    self_addr: usize = 0,
    request: PreparedExecutionTxn = .{},
    response: rpc_response_authority.Canonical = std.mem.zeroes(rpc_response_authority.Canonical),
    response_destination_addr: usize = 0,
    response_destination_seal: u64 = 0,
    phase: PreparedRpcExecutionPhase = .pristine,

    fn initBeforeReserve(
        self: *@This(),
        operation: RegisteredNodeOperation,
        request: GenerationRequestAbort,
        identity: contract.BindingIdentity,
        canonical: prepared_request_authority.Prepared,
        destination: *RpcExecutedResponse,
    ) PreparedExecutionTxn.InitError!void {
        if (self.self_addr != 0 or self.phase != .pristine) return error.InvalidOwner;
        const node = resolveRegisteredNodeOperation(operation) orelse return error.InvalidOwner;
        const owner_entry = registeredNodeOperationOwnerEntry(operation) orelse return error.InvalidOwner;
        const destination_addr = @intFromPtr(destination);
        const destination_len = @sizeOf(RpcExecutedResponse);
        if (byteRangesOverlap(destination_addr, destination_len, @intFromPtr(self), @sizeOf(@This())) or
            byteRangesOverlap(destination_addr, destination_len, @intFromPtr(&operation), @sizeOf(RegisteredNodeOperation)) or
            byteRangesOverlap(destination_addr, destination_len, @intFromPtr(&request), @sizeOf(GenerationRequestAbort)) or
            byteRangesOverlap(destination_addr, destination_len, owner_entry.slot_addr, @sizeOf(ClientSlot)) or
            byteRangesOverlap(destination_addr, destination_len, @intFromPtr(&registered_node_operations[operation.registry_index]), @sizeOf(RegisteredNodeOperationEntry)) or
            byteRangesOverlap(destination_addr, destination_len, @intFromPtr(node), @sizeOf(ClientNode)) or
            byteRangesOverlap(destination_addr, destination_len, canonical.descriptor.storage_addr, @sizeOf(client_mod.PreparedBlockingRpcStorage)) or
            byteRangesOverlap(destination_addr, destination_len, canonical.descriptor.frame_addr, canonical.descriptor.frame_len) or
            byteRangesOverlap(destination_addr, destination_len, canonical.binding.binding_storage_addr, @sizeOf(contract.PreparedAttachmentBinding)) or
            byteRangesOverlap(destination_addr, destination_len, canonical.transport_addr, 1) or
            !destination.pristineExact()) return error.InvalidOwner;
        try self.request.initBeforeBeginExecute(operation, request, identity, canonical);
        self.self_addr = @intFromPtr(self);
        self.response_destination_addr = destination_addr;
        self.response_destination_seal = responseDestinationSeal(destination_addr);
    }

    fn responseDestinationStillPristine(self: *const @This()) bool {
        if (self.self_addr != @intFromPtr(self) or self.response_destination_addr == 0 or
            self.response_destination_seal != responseDestinationSeal(self.response_destination_addr))
            return false;
        const destination: *const RpcExecutedResponse = @ptrFromInt(self.response_destination_addr);
        return destination.pristineExact();
    }

    fn reserveResponse(
        self: *@This(),
        operation: RegisteredNodeOperation,
    ) !void {
        if (self.self_addr != @intFromPtr(self) or self.phase != .pristine)
            return error.InvalidOwner;
        const node = self.request.ownerNode(operation) orelse return error.InvalidOwner;
        self.response = try node.cleanup_registry.reserveRpcResponseExecution(
            self.request.reservation.cleanup,
            self.request.binding_identity,
            self.request.canonical_prepared,
            self.response_destination_addr,
        );
        self.phase = .response_reserved;
    }

    fn settleReserveFailure(
        self: *@This(),
        operation: RegisteredNodeOperation,
        terminal: bool,
    ) !SettlementOutcome {
        if (self.self_addr != @intFromPtr(self) or self.phase != .pristine)
            return error.ProtocolError;
        const outcome = try self.request.settleUnbegun(operation, terminal);
        self.phase = .settled;
        return outcome;
    }

    fn settleReservedUnbegun(
        self: *@This(),
        operation: RegisteredNodeOperation,
        terminal: bool,
    ) !SettlementOutcome {
        if (self.self_addr != @intFromPtr(self) or self.phase != .response_reserved or
            self.request.phase != .prepared_unbegun)
            return error.ProtocolError;
        const outcome = try self.request.settleUnbegun(operation, terminal);
        const node = self.request.ownerNode(operation) orelse return error.ProtocolError;
        switch (outcome) {
            .reusable => try node.cleanup_registry.rollbackRpcResponseExecution(
                self.request.reservation.cleanup,
                self.request.binding_identity,
                self.response,
            ),
            .terminal => try node.cleanup_registry.settleRpcResponseExecutionTerminal(
                self.request.reservation.cleanup,
                self.request.binding_identity,
                self.response,
            ),
            .fail_stop_required => return error.ProtocolError,
        }
        self.phase = .settled;
        return outcome;
    }

    fn settlePreWire(
        self: *@This(),
        operation: RegisteredNodeOperation,
    ) !SettlementOutcome {
        return self.settlePreWireWithLease(operation, null);
    }

    fn settlePreWireWithLease(
        self: *@This(),
        operation: RegisteredNodeOperation,
        lease: ?*client_mod.PreparedRequestExecutionLease,
    ) !SettlementOutcome {
        if (self.self_addr != @intFromPtr(self) or self.phase != .response_reserved)
            return error.ProtocolError;
        const node_before = self.request.ownerNode(operation) orelse return error.ProtocolError;
        const poison_reason = if (lease) |held|
            try node_before.client.preparedRequestExecutionPoisonReason(held)
        else
            node_before.client.firstPoisonReason();
        const outcome = if (poison_reason) |reason|
            try self.request.settlePreWireTerminalWithLease(operation, reason, lease)
        else
            try self.request.rollbackPreWireWithLease(operation, lease);
        const node = self.request.ownerNode(operation) orelse return error.ProtocolError;
        switch (outcome) {
            .reusable => try node.cleanup_registry.rollbackRpcResponseExecution(
                self.request.reservation.cleanup,
                self.request.binding_identity,
                self.response,
            ),
            .terminal => try node.cleanup_registry.settleRpcResponseExecutionTerminal(
                self.request.reservation.cleanup,
                self.request.binding_identity,
                self.response,
            ),
            .fail_stop_required => return error.ProtocolError,
        }
        self.phase = .settled;
        return outcome;
    }

    fn settlePostWriteTerminal(
        self: *@This(),
        operation: RegisteredNodeOperation,
        reason: client_poison.ConnectionReason,
    ) !SettlementOutcome {
        return self.settlePostWriteTerminalWithLease(operation, reason, null);
    }

    fn settlePostWriteTerminalWithLease(
        self: *@This(),
        operation: RegisteredNodeOperation,
        reason: client_poison.ConnectionReason,
        lease: ?*client_mod.PreparedRequestExecutionLease,
    ) !SettlementOutcome {
        if (self.self_addr != @intFromPtr(self) or self.phase != .response_reserved)
            return error.ProtocolError;
        const destination_pristine_before = self.responseDestinationStillPristine();
        const outcome = try self.request.settlePostExecuteTerminalWithLease(
            operation,
            reason,
            lease,
        );
        const node = self.request.ownerNode(operation) orelse return error.ProtocolError;
        try node.cleanup_registry.settleRpcResponseExecutionTerminal(
            self.request.reservation.cleanup,
            self.request.binding_identity,
            self.response,
        );
        self.phase = .settled;
        if (!destination_pristine_before or !self.responseDestinationStillPristine()) {
            node.client.poison(.local_invariant_violation);
            return error.ProtocolError;
        }
        const destination: *RpcExecutedResponse = @ptrFromInt(self.response_destination_addr);
        destination.terminalNoFreeInPlace(
            rpcOwnerIdentity(self.response),
            rpcTerminalEvidence(self.response, reason),
        ) catch {
            node.client.poison(.local_invariant_violation);
            return error.ProtocolError;
        };
        return outcome;
    }

    fn ensureSettledOrFailStop(
        self: *@This(),
        operation: RegisteredNodeOperation,
    ) void {
        if (self.self_addr == 0) {
            if (self.phase == .pristine and self.request.semanticPristine() and
                self.response_destination_addr == 0 and self.response_destination_seal == 0)
                return;
            failStopPreparedExecution(.authority_drift);
        }
        if (self.self_addr != @intFromPtr(self) or self.request.ownerNode(operation) == null)
            failStopPreparedExecution(.authority_drift);
        if (self.phase == .settled) {
            self.request.ensureSettledOrFailStop(operation);
            return;
        }
        const outcome = switch (self.phase) {
            .pristine => self.settleReserveFailure(operation, false) catch
                failStopPreparedExecution(.cleanup_failure),
            .response_reserved => switch (self.request.phase) {
                .prepared_unbegun => self.settleReservedUnbegun(operation, false) catch
                    failStopPreparedExecution(.cleanup_failure),
                .pre_wire_backing_live => blk: {
                    const storage: *const client_mod.PreparedBlockingRpcStorage =
                        @ptrFromInt(self.request.canonical_prepared.descriptor.storage_addr);
                    if (client_mod.Client.preparedBlockingRpcStorageSettled(storage))
                        break :blk self.settlePostWriteTerminal(
                            operation,
                            self.request.ownerNode(operation).?.client.firstPoisonReason() orelse
                                .local_invariant_violation,
                        ) catch failStopPreparedExecution(.cleanup_failure);
                    break :blk self.settlePreWire(operation) catch
                        failStopPreparedExecution(.cleanup_failure);
                },
                .post_execute_backing_settled, .settled => failStopPreparedExecution(.duplicate_settlement),
            },
            .settled => unreachable,
        };
        self.request.finishOrFailStop(operation, outcome);
    }
};

fn rpcOwnerIdentity(canonical: rpc_response_authority.Canonical) rpc_executed_response.Identity {
    return .{
        .authority_addr = canonical.authority_addr,
        .registry_incarnation = canonical.registry_incarnation,
        .binding = canonical.binding,
        .transport_addr = canonical.transport_addr,
        .transport_incarnation = canonical.transport_incarnation,
        .family = canonical.family,
        .tag = canonical.tag,
        .request_id = canonical.request_id,
        .request_digest = canonical.request_digest,
        .response_epoch = canonical.response_epoch,
        .destination_addr = canonical.destination_addr,
    };
}

fn rpcAuthorityCanonical(identity: rpc_executed_response.Identity) rpc_response_authority.Canonical {
    return .{
        .authority_addr = identity.authority_addr,
        .registry_incarnation = identity.registry_incarnation,
        .binding = identity.binding,
        .transport_addr = identity.transport_addr,
        .transport_incarnation = identity.transport_incarnation,
        .family = identity.family,
        .tag = identity.tag,
        .request_id = identity.request_id,
        .request_digest = identity.request_digest,
        .response_epoch = identity.response_epoch,
        .destination_addr = identity.destination_addr,
    };
}

fn rpcTerminalEvidence(
    canonical: rpc_response_authority.Canonical,
    reason: client_poison.ConnectionReason,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.rpc-response-publication-terminal.v1");
    writer.writeU64(canonical.registry_incarnation);
    writer.writeUsize(canonical.transport_addr);
    writer.writeU64(canonical.transport_incarnation);
    writer.writeU64(canonical.request_id);
    writer.writeU64(canonical.request_digest);
    writer.writeU64(canonical.response_epoch);
    writer.writeUsize(canonical.destination_addr);
    writer.writeU8(@intFromEnum(reason));
    return writer.finish();
}

fn identityFromCanonical(
    canonical: prepared_request_authority.Prepared,
) client_mod.PreparedBlockingRpcIdentity {
    return .{
        .request_id = canonical.receipt.request_id,
        .frame_digest = canonical.receipt.request_digest,
        .descriptor = canonical.descriptor,
    };
}

fn settlementMatchesOutcome(
    settlement: PreparedExecutionSettlement,
    outcome: SettlementOutcome,
) bool {
    if (!settlement.rawValid()) return false;
    return switch (settlement.tag) {
        .pending => false,
        .reusable => outcome == .reusable,
        .terminal => switch (outcome) {
            .terminal => |other| settlement.terminalReason().? == other,
            else => false,
        },
        .fail_stop_required => switch (outcome) {
            .fail_stop_required => |other| settlement.failStopReason().? == other,
            else => false,
        },
    };
}

fn failStopPreparedExecution(reason: FailStopReason) noreturn {
    switch (reason) {
        .authority_drift => @panic("prepared execution transaction authority drift"),
        .backing_ambiguous => @panic("prepared execution transaction backing ambiguous"),
        .duplicate_settlement => @panic("prepared execution transaction duplicate settlement"),
        .cleanup_failure => @panic("prepared execution transaction cleanup failed"),
    }
}

const ResponsePayloadObserverBridge = struct {
    ledger: *response_payload_allocation.Ledger,
    guard: *GenerationGuardedAllocator,

    fn observer(self: *@This()) framing.PayloadAllocationObserver {
        return .{
            .context = self,
            .reserve_fn = reserve,
            .commit_fn = commit,
            .abort_fn = abort,
            .discard_fn = discard,
        };
    }

    fn reserve(
        context: *anyopaque,
        len: usize,
        allocator: std.mem.Allocator,
    ) error{ OutOfMemory, IdentityExhausted, ProtocolError }!u64 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.ledger.reserveObserved(len, allocator) catch |err| switch (err) {
            error.IdentityExhausted => error.IdentityExhausted,
            error.ObservationBusy => error.ProtocolError,
            else => error.ProtocolError,
        };
    }

    fn commit(
        context: *anyopaque,
        generation: u64,
        payload: []u8,
        allocator: std.mem.Allocator,
    ) error{ProtocolError}!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.ledger.commitObserved(generation, payload, allocator) catch
            return error.ProtocolError;
        if (builtin.is_test) {
            self.guard.request_free_test_observer.response_payload_addr = @intFromPtr(payload.ptr);
            self.guard.request_free_test_observer.response_payload_len = payload.len;
        }
    }

    fn abort(context: *anyopaque, generation: u64) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.ledger.abortObserved(generation) catch
            @panic("response payload observer abort drifted");
    }

    fn discard(context: *anyopaque, generation: u64) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.ledger.discardObserved(generation) catch
            @panic("response payload observer discard drifted");
    }
};

const PreparedRpcPublicationScope = struct {
    self_addr: usize = 0,
    allocator_scope: client_mod.Client.GenerationAllocatorScope = .{},
    ledger: response_payload_allocation.Ledger = .{},
    bridge: ResponsePayloadObserverBridge = undefined,
    publish_permit: rpc_response_authority.PreparedRpcTransitionPermit = .{},
    guard_active: bool = false,
    allocator_active: bool = false,
    ledger_active: bool = false,

    fn begin(
        self: *@This(),
        node: *ClientNode,
        operation: RegisteredNodeOperation,
        request: GenerationRequestAbort,
        destination: *RpcExecutedResponse,
        txn: *PreparedRpcExecutionTxn,
        lease: *client_mod.PreparedRequestExecutionLease,
        payload_cleanup: *RpcPublicationPayloadCleanup,
        storage: *client_mod.PreparedBlockingRpcStorage,
    ) !void {
        if (self.self_addr != 0 or self.guard_active or self.allocator_active or self.ledger_active)
            return error.InvalidOwner;
        self.self_addr = @intFromPtr(self);
        const guard = &node.guarded_allocator;
        const ranges = [_]GenerationGuardedAllocator.OperationRangeInput{
            .{ .start = @intFromPtr(self), .len = @sizeOf(@This()) },
            .{ .start = @intFromPtr(destination), .len = @sizeOf(RpcExecutedResponse) },
            .{ .start = @intFromPtr(txn), .len = @sizeOf(PreparedRpcExecutionTxn) },
            .{ .start = @intFromPtr(lease), .len = @sizeOf(client_mod.PreparedRequestExecutionLease) },
            .{ .start = @intFromPtr(payload_cleanup), .len = @sizeOf(RpcPublicationPayloadCleanup) },
            .{ .start = @intFromPtr(storage), .len = @sizeOf(client_mod.PreparedBlockingRpcStorage) },
            .{ .start = @intFromPtr(node), .len = @sizeOf(ClientNode) },
            .{ .start = request.slot_addr, .len = @sizeOf(ClientSlot) },
            .{ .start = request.reservation.identity.binding_storage_addr, .len = @sizeOf(contract.PreparedAttachmentBinding) },
            .{ .start = txn.request.canonical_prepared.descriptor.frame_addr, .len = txn.request.canonical_prepared.descriptor.frame_len },
            .{ .start = request.transport_addr, .len = 1 },
        };
        if (!guard.beginOperationGuard(&ranges)) {
            self.* = .{};
            return error.InvalidOwner;
        }
        self.guard_active = true;
        node.client.beginGenerationAllocatorScope(
            guard.allocator(),
            .rpc_execute,
            &self.allocator_scope,
        ) catch |err| {
            guard.endOperationGuard();
            self.* = .{};
            return err;
        };
        self.allocator_active = true;
        response_payload_allocation.Ledger.initInPlace(
            &self.ledger,
            guard.allocator(),
            .{
                .guard_addr = @intFromPtr(guard),
                .node_addr = @intFromPtr(node),
                .operation_incarnation = operation.operation_id,
            },
            1,
        ) catch |err| {
            node.client.restoreGenerationAllocatorScope(&self.allocator_scope) catch
                @panic("RPC publication allocator scope rollback drifted");
            guard.endOperationGuard();
            self.* = .{};
            return err;
        };
        self.ledger_active = true;
        self.bridge = .{
            .ledger = &self.ledger,
            .guard = guard,
        };
        if (builtin.is_test) {
            const test_observer = &guard.request_free_test_observer;
            test_observer.rpc_publication_txn_addr = @intFromPtr(txn);
            test_observer.rpc_publication_lease_addr = @intFromPtr(lease);
            test_observer.rpc_publication_scope_addr = @intFromPtr(self);
        }
        const forbidden = [_]response_payload_allocation.ForbiddenRange{
            .{ .start = @intFromPtr(self), .len = @sizeOf(@This()) },
            .{ .start = @intFromPtr(destination), .len = @sizeOf(RpcExecutedResponse) },
            .{ .start = @intFromPtr(txn), .len = @sizeOf(PreparedRpcExecutionTxn) },
            .{ .start = @intFromPtr(lease), .len = @sizeOf(client_mod.PreparedRequestExecutionLease) },
            .{ .start = @intFromPtr(payload_cleanup), .len = @sizeOf(RpcPublicationPayloadCleanup) },
            .{ .start = @intFromPtr(storage), .len = @sizeOf(client_mod.PreparedBlockingRpcStorage) },
            .{ .start = @intFromPtr(node), .len = @sizeOf(ClientNode) },
            .{ .start = request.slot_addr, .len = @sizeOf(ClientSlot) },
            .{ .start = request.reservation.identity.binding_storage_addr, .len = @sizeOf(contract.PreparedAttachmentBinding) },
            .{ .start = txn.request.canonical_prepared.descriptor.frame_addr, .len = txn.request.canonical_prepared.descriptor.frame_len },
            .{ .start = request.transport_addr, .len = 1 },
        };
        self.ledger.bindForbiddenRanges(&forbidden) catch {
            self.finish(node, null);
            return error.InvalidOwner;
        };
    }

    fn afterRequestWrite(
        self: *@This(),
        node: *ClientNode,
        request: GenerationRequestAbort,
        destination: *RpcExecutedResponse,
        txn: *PreparedRpcExecutionTxn,
        lease: *client_mod.PreparedRequestExecutionLease,
        payload_cleanup: *RpcPublicationPayloadCleanup,
        storage: *client_mod.PreparedBlockingRpcStorage,
    ) void {
        if (self.self_addr == 0) return;
        if (!self.liveExact(node))
            @panic("RPC publication response-phase rebind drifted");

        // The request frame is settled by the successful write. Keeping its former heap
        // range guarded would reject a valid response allocation that reuses that address.
        node.guarded_allocator.endOperationGuard();
        self.guard_active = false;
        const ranges = [_]GenerationGuardedAllocator.OperationRangeInput{
            .{ .start = @intFromPtr(self), .len = @sizeOf(@This()) },
            .{ .start = @intFromPtr(destination), .len = @sizeOf(RpcExecutedResponse) },
            .{ .start = @intFromPtr(txn), .len = @sizeOf(PreparedRpcExecutionTxn) },
            .{ .start = @intFromPtr(lease), .len = @sizeOf(client_mod.PreparedRequestExecutionLease) },
            .{ .start = @intFromPtr(payload_cleanup), .len = @sizeOf(RpcPublicationPayloadCleanup) },
            .{ .start = @intFromPtr(storage), .len = @sizeOf(client_mod.PreparedBlockingRpcStorage) },
            .{ .start = @intFromPtr(node), .len = @sizeOf(ClientNode) },
            .{ .start = request.slot_addr, .len = @sizeOf(ClientSlot) },
            .{ .start = request.reservation.identity.binding_storage_addr, .len = @sizeOf(contract.PreparedAttachmentBinding) },
            .{ .start = request.transport_addr, .len = 1 },
        };
        if (!node.guarded_allocator.beginOperationGuard(&ranges))
            @panic("RPC publication response-phase guard rebind failed");
        self.guard_active = true;
        const forbidden = [_]response_payload_allocation.ForbiddenRange{
            .{ .start = @intFromPtr(self), .len = @sizeOf(@This()) },
            .{ .start = @intFromPtr(destination), .len = @sizeOf(RpcExecutedResponse) },
            .{ .start = @intFromPtr(txn), .len = @sizeOf(PreparedRpcExecutionTxn) },
            .{ .start = @intFromPtr(lease), .len = @sizeOf(client_mod.PreparedRequestExecutionLease) },
            .{ .start = @intFromPtr(payload_cleanup), .len = @sizeOf(RpcPublicationPayloadCleanup) },
            .{ .start = @intFromPtr(storage), .len = @sizeOf(client_mod.PreparedBlockingRpcStorage) },
            .{ .start = @intFromPtr(node), .len = @sizeOf(ClientNode) },
            .{ .start = request.slot_addr, .len = @sizeOf(ClientSlot) },
            .{ .start = request.reservation.identity.binding_storage_addr, .len = @sizeOf(contract.PreparedAttachmentBinding) },
            .{ .start = request.transport_addr, .len = 1 },
        };
        self.ledger.rebindForbiddenRangesBeforeObservation(&forbidden) catch
            @panic("RPC publication response-phase ledger rebind failed");
    }

    fn observer(self: *@This(), node: *ClientNode) framing.PayloadAllocationObserver {
        if (!self.liveExact(node)) @panic("RPC publication observer scope drifted");
        return self.bridge.observer();
    }

    fn liveExact(self: *const @This(), node: *const ClientNode) bool {
        return self.self_addr == @intFromPtr(self) and self.guard_active and
            self.allocator_active and self.ledger_active and
            node.guarded_allocator.operation_guard_active;
    }

    fn finish(
        self: *@This(),
        node: *ClientNode,
        lease: ?*client_mod.PreparedRequestExecutionLease,
    ) void {
        if (self.self_addr == 0) return;
        if (!self.liveExact(node)) @panic("RPC publication scope finish drifted");
        self.ledger.endOperation() catch
            @panic("RPC publication payload ledger did not settle");
        self.ledger_active = false;
        if (lease) |active_lease|
            node.client.restoreGenerationAllocatorScopeUnderExecutionLease(
                &self.allocator_scope,
                active_lease,
            ) catch @panic("RPC publication allocator scope restore drifted")
        else
            node.client.restoreGenerationAllocatorScope(&self.allocator_scope) catch
                @panic("RPC publication allocator scope restore drifted");
        self.allocator_active = false;
        node.guarded_allocator.endOperationGuard();
        self.guard_active = false;
        self.self_addr = 0;
    }
};

const RpcPublicationPayloadCleanup = struct {
    self_addr: usize = 0,
    receipt: response_payload_allocation.Receipt = std.mem.zeroes(response_payload_allocation.Receipt),
    failure_release: response_payload_allocation.Ledger.PreparedFailureRelease = .{},
    test_pre_release_stage_drift: if (builtin.is_test) u8 else void = if (builtin.is_test) 0 else {},
    armed: u8 = 0,
    seal: owner_seal.Digest = [_]u8{0} ** 32,

    fn arm(self: *@This(), receipt: response_payload_allocation.Receipt) !void {
        if (self.self_addr != 0 or self.armed != 0 or
            !std.meta.eql(self.receipt, std.mem.zeroes(response_payload_allocation.Receipt)) or
            !self.failure_release.pristineExact() or !std.mem.allEqual(u8, &self.seal, 0) or
            receipt.ledger_addr == 0 or receipt.generation == 0)
            return error.InvalidOwner;
        self.* = .{
            .self_addr = @intFromPtr(self),
            .receipt = receipt,
            .armed = 1,
        };
        self.seal = rpcPublicationPayloadCleanupSeal(self);
    }

    fn takeIfExact(self: *@This()) ?response_payload_allocation.Receipt {
        if (self.self_addr != @intFromPtr(self) or self.armed != 1 or
            !self.failure_release.pristineExact() or
            !std.mem.eql(u8, &self.seal, &rpcPublicationPayloadCleanupSeal(self))) return null;
        const receipt = self.receipt;
        self.* = .{};
        return receipt;
    }
};

fn rpcPublicationPayloadCleanupSeal(cleanup: *const RpcPublicationPayloadCleanup) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.rpc-publication-payload-cleanup.v1");
    writer.writeUsize(cleanup.self_addr);
    writer.writeU8(cleanup.armed);
    writer.writeUsize(cleanup.receipt.ledger_addr);
    writer.writeU64(cleanup.receipt.generation);
    writer.writeU16(cleanup.receipt.index);
    writer.writeUsize(cleanup.receipt.addr);
    writer.writeUsize(cleanup.receipt.len);
    writer.writeBool(cleanup.receipt.zero_length);
    return writer.finish();
}

fn rpcPublicationFailureFreeEvidence(
    receipt: response_payload_allocation.Receipt,
    response_epoch: u64,
    reason: response_payload_allocation.PayloadFailStopReason,
) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.rpc-publication-failure-free.v1");
    writer.writeU64(response_epoch);
    writer.writeUsize(receipt.ledger_addr);
    writer.writeU64(receipt.generation);
    writer.writeU16(receipt.index);
    writer.writeUsize(receipt.addr);
    writer.writeUsize(receipt.len);
    writer.writeU8(@intFromEnum(reason));
    return writer.finish();
}

const RpcPublicationFailureByteDisposition = enum {
    destination_exact_payload_freed_clean,
    destination_exact_payload_no_free,
    destination_exact_payload_freed_once_drifted,
    destination_invalid_payload_freed_once,
    destination_invalid_payload_no_free,
};

const RpcPublicationFailureByteOutcome = struct {
    disposition: RpcPublicationFailureByteDisposition,
    response_epoch: u64,
    free_evidence: owner_seal.Digest = [_]u8{0} ** 32,
    retire_clean_evidence: bool = false,
};

fn closeRpcPublicationDestinationNoFree(
    destination: *RpcExecutedResponse,
    identity: rpc_executed_response.Identity,
    response: rpc_response_authority.Canonical,
) bool {
    if (destination.pristineExact()) {
        destination.terminalNoFreeInPlace(
            identity,
            rpcTerminalEvidence(response, .local_invariant_violation),
        ) catch return false;
        return true;
    }
    if (destination.liveScalarIdentityExact(identity)) {
        destination.abandonLiveNoFree(identity) catch return false;
        return true;
    }
    return false;
}

fn settleRpcPublicationFailureBytes(
    free_record: *RpcFreeEvidenceRecord,
    payload_cleanup: *RpcPublicationPayloadCleanup,
    response: rpc_response_authority.Canonical,
    reason: response_payload_allocation.PayloadFailStopReason,
) RpcPublicationFailureByteOutcome {
    const test_pre_release_stage_drift = if (builtin.is_test)
        payload_cleanup.test_pre_release_stage_drift
    else
        0;
    const destination: *RpcExecutedResponse = @ptrFromInt(response.destination_addr);
    const identity = rpcOwnerIdentity(response);
    const destination_pristine = destination.pristineExact();
    const destination_live = destination.liveScalarIdentityExact(identity);
    const receipt = payload_cleanup.takeIfExact() orelse {
        if ((destination_pristine or destination_live) and
            closeRpcPublicationDestinationNoFree(destination, identity, response))
        {
            return .{
                .disposition = .destination_exact_payload_no_free,
                .response_epoch = response.response_epoch,
            };
        }
        return .{
            .disposition = .destination_invalid_payload_no_free,
            .response_epoch = response.response_epoch,
        };
    };
    const ledger: *response_payload_allocation.Ledger = @ptrFromInt(receipt.ledger_addr);
    if (!ledger.promotedReceiptExact(receipt) or destination_live) {
        if ((destination_pristine or destination_live) and
            closeRpcPublicationDestinationNoFree(destination, identity, response))
        {
            return .{
                .disposition = .destination_exact_payload_no_free,
                .response_epoch = response.response_epoch,
            };
        }
        return .{
            .disposition = .destination_invalid_payload_no_free,
            .response_epoch = response.response_epoch,
        };
    }
    ledger.preparePromotedFailureRelease(
        receipt,
        &payload_cleanup.failure_release,
    ) catch {
        if (closeRpcPublicationDestinationNoFree(destination, identity, response)) {
            return .{
                .disposition = .destination_exact_payload_no_free,
                .response_epoch = response.response_epoch,
            };
        }
        return .{
            .disposition = .destination_invalid_payload_no_free,
            .response_epoch = response.response_epoch,
        };
    };
    const free_evidence = rpcPublicationFailureFreeEvidence(
        receipt,
        response.response_epoch,
        reason,
    );
    if (!free_record.commitFreeCall(response.response_epoch, free_evidence)) {
        ledger.abandonPreparedFailureNoFree(&payload_cleanup.failure_release);
        if (closeRpcPublicationDestinationNoFree(destination, identity, response)) {
            return .{
                .disposition = .destination_exact_payload_no_free,
                .response_epoch = response.response_epoch,
            };
        }
        return .{
            .disposition = .destination_invalid_payload_no_free,
            .response_epoch = response.response_epoch,
        };
    }
    if (builtin.is_test and test_pre_release_stage_drift != 0)
        @as(*u8, @ptrCast(&payload_cleanup.failure_release.stage)).* = 0xFF;
    const release = ledger.releasePreparedFailure(&payload_cleanup.failure_release);
    if (release == .not_freed) {
        _ = free_record.retireFreeCall(response.response_epoch, free_evidence);
        if (closeRpcPublicationDestinationNoFree(destination, identity, response)) {
            return .{
                .disposition = .destination_exact_payload_no_free,
                .response_epoch = response.response_epoch,
            };
        }
        return .{
            .disposition = .destination_invalid_payload_no_free,
            .response_epoch = response.response_epoch,
        };
    }
    if (release == .freed_clean and destination_pristine and destination.pristineExact()) {
        destination.terminalCleanAfterPublicationFailureInPlace(
            identity,
            rpcTerminalEvidence(response, .local_invariant_violation),
        ) catch {};
        if (destination.terminalExact() and destination.settlement == .terminal_clean)
            return .{
                .disposition = .destination_exact_payload_freed_clean,
                .response_epoch = response.response_epoch,
                .free_evidence = free_evidence,
                .retire_clean_evidence = true,
            };
    }
    _ = free_record.commitTerminalFreedOnce(response.response_epoch, free_evidence);
    return .{
        .disposition = if (destination_pristine)
            .destination_exact_payload_freed_once_drifted
        else
            .destination_invalid_payload_freed_once,
        .response_epoch = response.response_epoch,
        .free_evidence = free_evidence,
    };
}

fn failStopResponsePayloadProvenance(
    reason: response_payload_allocation.PayloadFailStopReason,
) noreturn {
    switch (reason) {
        .allocator_drift => @panic("response payload provenance: allocator drift"),
        .range_overflow => @panic("response payload provenance: range overflow"),
        .owner_alias => @panic("response payload provenance: owner alias"),
        .ledger_drift => @panic("response payload provenance: ledger drift"),
    }
}

fn failStopResponsePayloadTransfer(
    reason: response_payload_allocation.PayloadFailStopReason,
) noreturn {
    switch (reason) {
        .allocator_drift => @panic("response payload transfer: allocator drift"),
        .range_overflow => @panic("response payload transfer: range overflow"),
        .owner_alias => @panic("response payload transfer: owner alias"),
        .ledger_drift => @panic("response payload transfer: ledger drift"),
    }
}

const PreparedExecutionCleanup = struct {
    const CleanupStage = enum(u8) { guard, allocator, ledger };
    const CleanupLifecycle = enum(u8) { pristine, live, finishing, settled, fail_stop };
    const CleanupFailure = enum(u8) { descriptor_drift, reentry, ledger_end, allocator_restore, guard_end };
    const CleanupOutcome = union(enum) { clean, deferred_reentry, fail_stop: CleanupFailure };

    self_addr: usize = 0,
    lifecycle: CleanupLifecycle = .pristine,
    stage: CleanupStage = .guard,
    first_failure_raw: u8 = 0,

    fn init(self: *PreparedExecutionCleanup) void {
        self.* = .{
            .self_addr = @intFromPtr(self),
            .lifecycle = .live,
        };
    }

    fn advance(self: *PreparedExecutionCleanup, from: CleanupStage, to: CleanupStage) bool {
        if (!self.rawValid() or self.self_addr != @intFromPtr(self) or
            self.lifecycle != .live or self.stage != from)
            return false;
        self.stage = to;
        return true;
    }

    fn finish(
        self: *PreparedExecutionCleanup,
        expected_stage: CleanupStage,
        client: *client_mod.Client,
        guard: *GenerationGuardedAllocator,
        allocator_scope: *client_mod.Client.GenerationAllocatorScope,
        payload_ledger: *response_payload_allocation.Ledger,
    ) CleanupOutcome {
        if (builtin.is_test) {
            const observer = &guard.request_free_test_observer;
            switch (observer.cleanup_drift_kind) {
                1 => self.self_addr = 1,
                2 => self.stage = .guard,
                3 => allocator_scope.self_addr = 1,
                4 => guard.operation_guard_active = false,
                5 => payload_ledger.self_addr = 1,
                else => {},
            }
            if (observer.cleanup_drift_kind >= 1 and observer.cleanup_drift_kind <= 5)
                observer.cleanup_drift_consumed = true;
        }
        if (self.rawValid() and self.self_addr == @intFromPtr(self) and
            self.lifecycle == .finishing and
            prepared_execution_cleanup_active_addr == @intFromPtr(self))
        {
            if (self.first_failure_raw == 0)
                self.first_failure_raw = @intFromEnum(CleanupFailure.reentry) + 1;
            return .deferred_reentry;
        }

        var first: ?CleanupFailure = null;
        if (!self.rawValid() or self.self_addr != @intFromPtr(self) or
            self.lifecycle != .live or self.stage != expected_stage or
            self.first_failure_raw != 0)
            first = .descriptor_drift;
        self.self_addr = @intFromPtr(self);
        self.lifecycle = .finishing;
        self.stage = expected_stage;
        self.first_failure_raw = 0;
        const prior_active_addr = prepared_execution_cleanup_active_addr;
        if (prior_active_addr != 0 and first == null) first = .reentry;
        prepared_execution_cleanup_active_addr = @intFromPtr(self);
        defer prepared_execution_cleanup_active_addr = prior_active_addr;
        if (expected_stage == .ledger) {
            payload_ledger.endOperation() catch {
                if (first == null) first = .ledger_end;
            };
            self.revalidateFinishing(expected_stage, &first);
        }
        if (expected_stage == .ledger or expected_stage == .allocator) {
            client.restoreGenerationAllocatorScope(allocator_scope) catch {
                if (first == null) first = .allocator_restore;
            };
            self.revalidateFinishing(expected_stage, &first);
        }
        guard.finishOperationGuard() catch {
            if (first == null) first = .guard_end;
        };
        self.revalidateFinishing(expected_stage, &first);
        if (first) |failure| {
            self.first_failure_raw = @intFromEnum(failure) + 1;
            self.lifecycle = .fail_stop;
            return .{ .fail_stop = failure };
        }
        self.lifecycle = .settled;
        if (builtin.is_test) {
            const observer = &guard.request_free_test_observer;
            observer.cleanup_count += 1;
            observer.guard_inactive = !guard.operation_guard_active;
            observer.allocator_scope_restored =
                allocator_scope.lifecycle == .restored and allocator_scope.self_addr == 0;
            observer.client_scope_restored = client.active_generation_allocator_scope == null;
            observer.ledger_ended = payload_ledger.self_addr == 0 and
                !payload_ledger.active and payload_ledger.entry_count == 0;
            observer.cleanup_settled = self.lifecycle == .settled and self.first_failure_raw == 0;
        }
        return .clean;
    }

    fn finishOrFailStop(
        self: *PreparedExecutionCleanup,
        txn: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
        expected_stage: CleanupStage,
        completion: *u8,
        client: *client_mod.Client,
        guard: *GenerationGuardedAllocator,
        allocator_scope: *client_mod.Client.GenerationAllocatorScope,
        payload_ledger: *response_payload_allocation.Ledger,
    ) void {
        switch (self.finish(expected_stage, client, guard, allocator_scope, payload_ledger)) {
            .clean => completion.* = 1,
            .deferred_reentry => return,
            .fail_stop => {
                const outcome = txn.failStopCleanupFailure(operation);
                txn.finishOrFailStop(operation, outcome);
            },
        }
    }

    fn ensureFinishedOrFailStop(
        self: *PreparedExecutionCleanup,
        txn: *PreparedExecutionTxn,
        operation: RegisteredNodeOperation,
        expected_stage: CleanupStage,
        completion: *u8,
        client: *client_mod.Client,
        guard: *GenerationGuardedAllocator,
        allocator_scope: *client_mod.Client.GenerationAllocatorScope,
        payload_ledger: *response_payload_allocation.Ledger,
    ) void {
        if (completion.* == 1 and self.rawValid() and self.self_addr == @intFromPtr(self) and
            self.lifecycle == .settled and self.stage == expected_stage and self.first_failure_raw == 0)
            return;
        self.finishOrFailStop(txn, operation, expected_stage, completion, client, guard, allocator_scope, payload_ledger);
    }

    fn revalidateFinishing(
        self: *PreparedExecutionCleanup,
        expected_stage: CleanupStage,
        first: *?CleanupFailure,
    ) void {
        if (!self.rawValid() or self.self_addr != @intFromPtr(self) or
            self.lifecycle != .finishing or self.stage != expected_stage)
        {
            if (first.* == null) first.* = .descriptor_drift;
            self.self_addr = @intFromPtr(self);
            self.lifecycle = .finishing;
            self.stage = expected_stage;
        }
        if (self.first_failure_raw != 0) {
            const raw = self.first_failure_raw - 1;
            if (raw < std.meta.fields(CleanupFailure).len and first.* == null)
                first.* = @enumFromInt(raw);
            self.first_failure_raw = 0;
        }
    }

    fn rawValid(self: *const PreparedExecutionCleanup) bool {
        const lifecycle_raw = @as(*const u8, @ptrCast(&self.lifecycle)).*;
        const stage_raw = @as(*const u8, @ptrCast(&self.stage)).*;
        return lifecycle_raw <= @intFromEnum(CleanupLifecycle.fail_stop) and
            stage_raw <= @intFromEnum(CleanupStage.ledger) and
            self.first_failure_raw <= std.meta.fields(CleanupFailure).len;
    }
};

const ExecutionSettlementIntent = union(enum) {
    rollback_pre_wire,
    issuer_exhausted,
    post_execute_reusable,
    post_execute_terminal: client_poison.ConnectionReason,
};

fn settleExecutionAfterCleanup(
    cleanup: *PreparedExecutionCleanup,
    txn: *PreparedExecutionTxn,
    operation: RegisteredNodeOperation,
    expected_stage: PreparedExecutionCleanup.CleanupStage,
    completion: *u8,
    client: *client_mod.Client,
    guard: *GenerationGuardedAllocator,
    allocator_scope: *client_mod.Client.GenerationAllocatorScope,
    payload_ledger: *response_payload_allocation.Ledger,
    intent: ExecutionSettlementIntent,
) PreparedExecutionTxn.SettlementError!SettlementOutcome {
    cleanup.finishOrFailStop(
        txn,
        operation,
        expected_stage,
        completion,
        client,
        guard,
        allocator_scope,
        payload_ledger,
    );
    const outcome = switch (intent) {
        .rollback_pre_wire => try txn.rollbackPreWire(operation),
        .issuer_exhausted => try txn.retireIssuerExhausted(operation),
        .post_execute_reusable => try txn.settlePostExecuteReusable(operation),
        .post_execute_terminal => |reason| try txn.settlePostExecuteTerminal(operation, reason),
    };
    txn.finishOrFailStop(operation, outcome);
    return outcome;
}

fn finishPreparedRpcLeaseOrFailStop(
    node: *ClientNode,
    lease: *client_mod.PreparedRequestExecutionLease,
    txn: *PreparedRpcExecutionTxn,
    operation: RegisteredNodeOperation,
) void {
    node.client.finishPreparedRequestExecution(lease) catch {
        node.client.poison(.local_invariant_violation);
        txn.ensureSettledOrFailStop(operation);
        failStopPreparedExecution(.cleanup_failure);
    };
}

fn settlePreparedRpcLeaseOwnedAndReleaseOrFailStop(
    node: *ClientNode,
    lease: *client_mod.PreparedRequestExecutionLease,
    txn: *PreparedRpcExecutionTxn,
    operation: RegisteredNodeOperation,
) void {
    const storage: *const client_mod.PreparedBlockingRpcStorage =
        @ptrFromInt(txn.request.canonical_prepared.descriptor.storage_addr);
    const poison_reason = node.client.preparedRequestExecutionPoisonReason(lease) catch
        failStopPreparedExecution(.authority_drift);
    const outcome = if (client_mod.Client.preparedBlockingRpcStorageSettled(storage))
        txn.settlePostWriteTerminalWithLease(
            operation,
            poison_reason orelse .local_invariant_violation,
            lease,
        ) catch failStopPreparedExecution(.cleanup_failure)
    else
        txn.settlePreWireWithLease(operation, lease) catch
            failStopPreparedExecution(.cleanup_failure);
    txn.request.finishOrFailStop(operation, outcome);
    finishPreparedRpcLeaseOrFailStop(node, lease, txn, operation);
}

/// B3-3 product-shaped private caller. It deliberately has no public facade and publishes no
/// response payload; tests provide a peer that consumes the exact request and closes.
const PreparedRpcExecutionTestFailure = enum {
    none,
    after_response_reserve,
    after_execution_lease,
    response_epoch_exhausted,
};

const PreparedRpcExecutionMode = enum { terminal_sink, correlated_response };

const ResponseDestination = union(enum) {
    attach: *executed_response_mod.ExecutedResponse,
    rpc: void,
};

const RpcExecutionDestination = union(enum) {
    canonical: void,
    test_explicit: *RpcExecutedResponse,
};

fn resolveResponseDestination(
    owner: *const contract.TransportOwnerSeal,
    requested: ResponseDestination,
) error{InvalidResponseDestination}!ResponseDestination {
    return switch (requested) {
        .attach => |destination| blk: {
            const destination_addr = @intFromPtr(destination);
            if (!byteRangeFullyContained(
                destination_addr,
                @sizeOf(executed_response_mod.ExecutedResponse),
                owner.owner_addr,
                owner.owner_size,
            )) return error.InvalidResponseDestination;
            break :blk .{ .attach = destination };
        },
        .rpc => blk: {
            const response_addr = owner.rpc_response_addr;
            if (response_addr == 0 or response_addr % @alignOf(RpcExecutedResponse) != 0 or
                !byteRangeFullyContained(
                    response_addr,
                    @sizeOf(RpcExecutedResponse),
                    owner.owner_addr,
                    owner.owner_size,
                )) return error.InvalidResponseDestination;
            break :blk .{ .rpc = {} };
        },
    };
}

fn executePreparedRpcPrivate(
    request: GenerationRequestAbort,
    bound_stream_id: u64,
    requested_destination: RpcExecutionDestination,
    mode: PreparedRpcExecutionMode,
    test_failure: PreparedRpcExecutionTestFailure,
) !void {
    const admission = try beginGenerationRequestOwner(request, false);
    defer endRegisteredNodeOperation(admission.operation);
    const node = admission.operation.node;
    const identity = admission.identity;
    const destination: *RpcExecutedResponse = switch (requested_destination) {
        .test_explicit => |explicit| explicit,
        .canonical => switch (try resolveResponseDestination(admission.owner, .{ .rpc = {} })) {
            .rpc => @ptrFromInt(admission.owner.rpc_response_addr),
            .attach => unreachable,
        },
    };
    const prepared_admission = try node.cleanup_registry.preparedRpcAdmission(
        request.reservation.cleanup,
        identity,
        request.transport_addr,
        request.transport_incarnation,
        request.receipt,
        bound_stream_id,
    );
    if (prepared_admission.decision != .allowed) return error.Unauthorized;
    if (test_failure == .response_epoch_exhausted) {
        if (!builtin.is_test) unreachable;
        try node.cleanup_registry.exhaustRpcResponseEpochForTest(
            request.reservation.cleanup,
            identity,
        );
    }

    var txn: PreparedRpcExecutionTxn = .{};
    try txn.initBeforeReserve(
        admission.operation,
        request,
        identity,
        prepared_admission.canonical,
        destination,
    );
    defer txn.ensureSettledOrFailStop(admission.operation);
    txn.reserveResponse(admission.operation) catch |err| {
        const outcome = try txn.settleReserveFailure(
            admission.operation,
            err == error.IdentityExhausted,
        );
        txn.request.finishOrFailStop(admission.operation, outcome);
        return err;
    };
    if (test_failure == .after_response_reserve) return error.InjectedFailure;
    txn.request.commitBeginExecute(admission.operation);

    const storage: *client_mod.PreparedBlockingRpcStorage =
        @ptrFromInt(request.prepared_storage_addr);
    var lease: client_mod.PreparedRequestExecutionLease = .{};
    var publication: PreparedRpcPublicationScope = .{};
    var payload_cleanup: RpcPublicationPayloadCleanup = .{};
    if (mode == .correlated_response) publication.begin(
        node,
        admission.operation,
        request,
        destination,
        &txn,
        &lease,
        &payload_cleanup,
        storage,
    ) catch |err| {
        const outcome = try txn.settlePreWire(admission.operation);
        txn.request.finishOrFailStop(admission.operation, outcome);
        return err;
    };
    const response_allocator = node.client.beginPreparedRequestExecutionFromRegisteredOperation(
        storage,
        txn.request.prepared_identity,
        &lease,
    ) catch |err| {
        publication.finish(node, null);
        if (lease.wireProgress() != null) {
            settlePreparedRpcLeaseOwnedAndReleaseOrFailStop(
                node,
                &lease,
                &txn,
                admission.operation,
            );
        } else {
            const outcome = try txn.settlePreWire(admission.operation);
            txn.request.finishOrFailStop(admission.operation, outcome);
        }
        return err;
    };
    var lease_active = true;
    defer if (lease_active) {
        publication.finish(node, &lease);
        settlePreparedRpcLeaseOwnedAndReleaseOrFailStop(
            node,
            &lease,
            &txn,
            admission.operation,
        );
    };

    if (test_failure == .after_execution_lease) {
        publication.finish(node, &lease);
        settlePreparedRpcLeaseOwnedAndReleaseOrFailStop(node, &lease, &txn, admission.operation);
        lease_active = false;
        return error.InjectedFailure;
    }

    if (!txn.responseDestinationStillPristine()) {
        node.client.poison(.local_invariant_violation);
        publication.finish(node, &lease);
        settlePreparedRpcLeaseOwnedAndReleaseOrFailStop(node, &lease, &txn, admission.operation);
        lease_active = false;
        return error.InvalidOwner;
    }

    const executing_admission = node.cleanup_registry.executingRpcAdmission(
        request.reservation.cleanup,
        identity,
        request.transport_addr,
        request.transport_incarnation,
        request.receipt,
        bound_stream_id,
    ) catch |err| {
        publication.finish(node, &lease);
        settlePreparedRpcLeaseOwnedAndReleaseOrFailStop(node, &lease, &txn, admission.operation);
        lease_active = false;
        return err;
    };
    if (executing_admission.decision != .allowed or
        !std.meta.eql(executing_admission.canonical, prepared_admission.canonical))
    {
        publication.finish(node, &lease);
        settlePreparedRpcLeaseOwnedAndReleaseOrFailStop(node, &lease, &txn, admission.operation);
        lease_active = false;
        return error.Unauthorized;
    }
    if (!txn.responseDestinationStillPristine()) {
        node.client.poison(.local_invariant_violation);
        publication.finish(node, &lease);
        settlePreparedRpcLeaseOwnedAndReleaseOrFailStop(node, &lease, &txn, admission.operation);
        lease_active = false;
        return error.InvalidOwner;
    }

    node.client.writePreparedRequestExecution(
        storage,
        txn.request.prepared_identity,
        &lease,
    ) catch |err| {
        publication.finish(node, &lease);
        settlePreparedRpcLeaseOwnedAndReleaseOrFailStop(node, &lease, &txn, admission.operation);
        lease_active = false;
        return err;
    };
    publication.afterRequestWrite(
        node,
        request,
        destination,
        &txn,
        &lease,
        &payload_cleanup,
        storage,
    );
    if (mode == .correlated_response) {
        try node.cleanup_registry.armRpcExecutionRecovery(
            request.reservation.cleanup,
            identity,
            txn.request.canonical_prepared,
            txn.response,
        );
        try publishPreparedRpcResponse(
            request,
            admission.operation,
            identity,
            bound_stream_id,
            node,
            destination,
            &txn,
            &lease,
            response_allocator,
            &publication,
            &payload_cleanup,
        );
        lease_active = false;
        return;
    }
    node.client.observePreparedRequestTerminalSinkEof(&lease) catch |err| switch (err) {
        error.ConnectionClosed, error.ProtocolError => {},
        else => @panic("B3-3 terminal sink returned an unclassified failure"),
    };
    settlePreparedRpcLeaseOwnedAndReleaseOrFailStop(node, &lease, &txn, admission.operation);
    lease_active = false;
}

fn publishPreparedRpcResponse(
    request: GenerationRequestAbort,
    operation: RegisteredNodeOperation,
    identity: contract.BindingIdentity,
    bound_stream_id: u64,
    node: *ClientNode,
    destination: *RpcExecutedResponse,
    txn: *PreparedRpcExecutionTxn,
    lease: *client_mod.PreparedRequestExecutionLease,
    response_allocator: std.mem.Allocator,
    publication: *PreparedRpcPublicationScope,
    payload_cleanup: *RpcPublicationPayloadCleanup,
) !void {
    const response = node.client.readPreparedResponseUnderExecutionLease(
        lease,
        response_allocator,
        publication.observer(node),
    ) catch failStopRpcPublication(
        node,
        payload_cleanup,
        .ledger_drift,
    );
    const payload_receipt = switch (publication.ledger.classifyResponsePayloadProvenance(
        response.payload_observation_generation,
        response.payload,
        response.payload_allocator,
        response_allocator,
    )) {
        .promoted => |receipt| receipt,
        .fail_stop_required => |reason| failStopRpcPublication(
            node,
            payload_cleanup,
            reason,
        ),
    };
    payload_cleanup.arm(payload_receipt) catch failStopRpcPublication(
        node,
        payload_cleanup,
        .ledger_drift,
    );
    const executing_admission = node.cleanup_registry.executingRpcAdmission(
        request.reservation.cleanup,
        identity,
        request.transport_addr,
        request.transport_incarnation,
        request.receipt,
        bound_stream_id,
    ) catch {
        failStopRpcPublication(
            node,
            payload_cleanup,
            .ledger_drift,
        );
    };
    node.client.revalidatePreparedResponsePublication(lease, response_allocator) catch {
        failStopRpcPublication(
            node,
            payload_cleanup,
            .ledger_drift,
        );
    };
    if (!publication.liveExact(node) or !txn.responseDestinationStillPristine() or
        txn.request.postExecuteReady(operation) == null or executing_admission.decision != .allowed or
        !std.meta.eql(executing_admission.canonical, txn.request.canonical_prepared))
    {
        failStopRpcPublication(
            node,
            payload_cleanup,
            .ledger_drift,
        );
    }
    node.cleanup_registry.prepareRpcResponsePublished(
        request.reservation.cleanup,
        identity,
        txn.response,
        &publication.publish_permit,
    ) catch failStopRpcPublication(
        node,
        payload_cleanup,
        .ledger_drift,
    );
    switch (publication.ledger.transferPromotedRpcResponse(
        payload_receipt,
        destination,
        rpcOwnerIdentity(txn.response),
    )) {
        .transferred => {},
        .fail_stop_required => |reason| failStopRpcPublication(
            node,
            payload_cleanup,
            reason,
        ),
    }
    _ = payload_cleanup.takeIfExact() orelse
        @panic("RPC publication payload cleanup consumption drifted");
    node.cleanup_registry.commitRpcResponsePublished(
        request.reservation.cleanup,
        identity,
        txn.response,
        &publication.publish_permit,
    );
    node.cleanup_registry.commitRpcExecutionRecoveryDisarmNoFail();
    const outcome = txn.request.settlePostExecuteReusableUnderPublicationScope(operation) catch
        failStopPreparedExecution(.cleanup_failure);
    txn.request.finishOrFailStop(operation, outcome);
    publication.finish(node, lease);
    txn.phase = .settled;
    finishPreparedRpcLeaseOrFailStop(node, lease, txn, operation);
}

fn failStopRpcPublication(
    node: *ClientNode,
    payload_cleanup: *RpcPublicationPayloadCleanup,
    reason: response_payload_allocation.PayloadFailStopReason,
) noreturn {
    const recovery = node.cleanup_registry.rpcExecutionRecoveryCanonical() catch
        @panic("RPC publication canonical recovery drifted");
    const byte_outcome = settleRpcPublicationFailureBytes(
        &node.rpc_free_evidence,
        payload_cleanup,
        recovery.response,
        reason,
    );
    node.cleanup_registry.commitRpcExecutionRecoveryTerminalNoFail();
    node.client.commitPreparedExecutionRecoveryPoisonNoFail(.local_invariant_violation);
    node.client.commitPreparedExecutionRecoveryCleanupNoFail();
    if (byte_outcome.retire_clean_evidence and
        !node.rpc_free_evidence.retireFreeCall(
            byte_outcome.response_epoch,
            byte_outcome.free_evidence,
        )) @panic("RPC publication clean free evidence retire drifted");
    node.guarded_allocator.finishOperationGuard() catch
        @panic("RPC publication recovery operation guard drifted");
    if (builtin.is_test and
        node.guarded_allocator.request_free_test_observer.rpc_publication_drift_fired)
    {
        const evidence = node.cleanup_registry.rpcExecutionRecoveryEvidenceForTest(
            recovery.reservation,
            recovery.binding,
        ) catch @panic("RPC publication recovery evidence lookup failed");
        if (!evidence.request_terminal) {
            const diagnostic = "B3_RPC_RECOVERY_REQUEST_NOT_TERMINAL\n";
            _ = c.write(2, diagnostic.ptr, diagnostic.len);
        }
        if (!evidence.response_terminal) {
            const diagnostic = "B3_RPC_RECOVERY_RESPONSE_NOT_TERMINAL\n";
            _ = c.write(2, diagnostic.ptr, diagnostic.len);
        }
        if (!evidence.recovery_empty) {
            const diagnostic = "B3_RPC_RECOVERY_NOT_CONSUMED\n";
            _ = c.write(2, diagnostic.ptr, diagnostic.len);
        }
        if (!node.client.preparedExecutionRecoveryPoisonedForTest()) {
            const diagnostic = "B3_RPC_RECOVERY_NOT_POISONED\n";
            _ = c.write(2, diagnostic.ptr, diagnostic.len);
        }
        if (!evidence.request_terminal or !evidence.response_terminal or
            !evidence.recovery_empty or !node.client.preparedExecutionRecoveryPoisonedForTest())
            @panic("RPC publication recovery evidence was incomplete");
        const marker = "B3_RPC_PUBLICATION_RECOVERY_TERMINAL\n";
        _ = c.write(2, marker.ptr, marker.len);
    }
    @panic("RPC publication failed after terminal settlement");
}

fn executePreparedRpcTerminalSink(
    request: GenerationRequestAbort,
    bound_stream_id: u64,
    destination: *RpcExecutedResponse,
    test_failure: PreparedRpcExecutionTestFailure,
) !void {
    return executePreparedRpcPrivate(
        request,
        bound_stream_id,
        .{ .test_explicit = destination },
        .terminal_sink,
        test_failure,
    );
}

fn executePreparedRpcCorrelatedResponseForTest(
    request: GenerationRequestAbort,
    bound_stream_id: u64,
    destination: *RpcExecutedResponse,
) !void {
    return executePreparedRpcPrivate(
        request,
        bound_stream_id,
        .{ .test_explicit = destination },
        .correlated_response,
        .none,
    );
}

/// One ownership-only RPC cycle for GenerationTransport's canonical inline slot. Semantic
/// response bytes deliberately remain unread until the decoder slice owns that contract.
pub fn executeGenerationRpcSubstrate(execution: GenerationRpcSubstrateExecute) GenerationExecuteError!void {
    executePreparedRpcPrivate(
        execution.request,
        execution.bound_stream_id,
        .{ .canonical = {} },
        .correlated_response,
        .none,
    ) catch |err| {
        return switch (err) {
            error.CapacityExhausted,
            error.InvalidIdentity,
            error.InvalidReservation,
            error.InvalidState,
            error.InvalidStream,
            error.InvalidCanonical,
            error.InjectedFailure,
            error.InvalidDescriptor,
            error.ObservationBusy,
            => @panic("RPC substrate returned an internal-only execution error"),
            else => @errorCast(err),
        };
    };
    const response_addr = canonicalRpcResponseAddress(execution.request) catch
        @panic("RPC substrate lost its canonical response address after publication");
    const response: *RpcExecutedResponse = @ptrFromInt(response_addr);
    var borrow: rpc_executed_response.RpcResponseBorrow = .{};
    beginRpcResponseBorrow(execution.request, response, &borrow) catch
        @panic("RPC substrate borrow settlement drifted");
    finishRpcResponseOwned(execution.request, response, &borrow, .reusable) catch
        @panic("RPC substrate reusable settlement drifted");
    if (!response.pristineExact()) @panic("RPC substrate reusable slot did not rearm");
}

fn canonicalRpcResponseAddress(request: GenerationRequestAbort) GenerationRequestError!usize {
    const admission = try beginGenerationRequestOwner(request, false);
    defer endRegisteredNodeOperation(admission.operation);
    const response_addr = admission.owner.rpc_response_addr;
    if (response_addr == 0 or response_addr % @alignOf(RpcExecutedResponse) != 0 or
        !byteRangeFullyContained(
            response_addr,
            @sizeOf(RpcExecutedResponse),
            admission.owner.owner_addr,
            admission.owner.owner_size,
        )) return error.InvalidOwner;
    return response_addr;
}

test "B3-4/5 RPC substrate rejects uncontained destination before request admission" {
    var invalid_request: GenerationRequestAbort = undefined;
    @memset(std.mem.asBytes(&invalid_request), 0);
    try std.testing.expectError(error.InvalidOwner, executeGenerationRpcSubstrate(.{
        .request = invalid_request,
        .bound_stream_id = 1,
    }));
}

const RpcResponseDisposition = enum { reusable, protocol_failure };

fn failStopPermitAliasPreflight() noreturn {
    // This fixed, allocation-free write is the parent-observable sentinel. A subprocess gate can
    // bind stderr before entry without requiring env lookup or capability resolution here.
    const marker = "permit-alias-preflight-rejected\n";
    _ = c.write(2, marker.ptr, marker.len);
    @panic("permit-alias-preflight-rejected");
}

const FinishPermitRawStorage = struct {
    const TransitionPermit = rpc_response_authority.PreparedRpcTransitionPermit;
    const EvidencePermit = PreparedRpcFreeEvidenceRetirePermit;
    const RearmPermit = rpc_executed_response.PreparedReusableRearmPermit;

    const Range = struct {
        start: usize,
        len: usize,
    };

    releasing: [@sizeOf(TransitionPermit)]u8 align(@alignOf(TransitionPermit)) = undefined,
    finish_authority: [@sizeOf(TransitionPermit)]u8 align(@alignOf(TransitionPermit)) = undefined,
    evidence_retire: [@sizeOf(EvidencePermit)]u8 align(@alignOf(EvidencePermit)) = undefined,
    rearm: [@sizeOf(RearmPermit)]u8 align(@alignOf(RearmPermit)) = undefined,

    const Typed = struct {
        releasing: *TransitionPermit,
        finish_authority: *TransitionPermit,
        evidence_retire: *EvidencePermit,
        rearm: *RearmPermit,
    };

    fn ranges(self: *@This()) [4]Range {
        return .{
            .{ .start = @intFromPtr(&self.releasing), .len = @sizeOf(TransitionPermit) },
            .{ .start = @intFromPtr(&self.finish_authority), .len = @sizeOf(TransitionPermit) },
            .{ .start = @intFromPtr(&self.evidence_retire), .len = @sizeOf(EvidencePermit) },
            .{ .start = @intFromPtr(&self.rearm), .len = @sizeOf(RearmPermit) },
        };
    }

    /// This preflight reads only scalar addresses and extents. The four raw reservations remain
    /// undefined until every pair and every caller-owned range has proved disjoint.
    fn disjointFrom(self: *@This(), payload: Range, forbidden: []const Range) bool {
        _ = std.math.add(usize, payload.start, payload.len) catch return false;
        const permit_ranges = self.ranges();
        for (permit_ranges, 0..) |permit_range, index| {
            _ = std.math.add(usize, permit_range.start, permit_range.len) catch return false;
            if (byteRangesOverlap(payload.start, payload.len, permit_range.start, permit_range.len))
                return false;
            for (forbidden) |range| {
                if (byteRangesOverlap(permit_range.start, permit_range.len, range.start, range.len))
                    return false;
            }
            for (permit_ranges[index + 1 ..]) |other| {
                if (byteRangesOverlap(permit_range.start, permit_range.len, other.start, other.len))
                    return false;
            }
        }
        return true;
    }

    fn initializeDisjoint(self: *@This()) Typed {
        @memset(&self.releasing, 0);
        @memset(&self.finish_authority, 0);
        @memset(&self.evidence_retire, 0);
        @memset(&self.rearm, 0);
        return .{
            .releasing = @ptrCast(&self.releasing),
            .finish_authority = @ptrCast(&self.finish_authority),
            .evidence_retire = @ptrCast(&self.evidence_retire),
            .rearm = @ptrCast(&self.rearm),
        };
    }

    fn initializeAfterPreflightOrFail(
        self: *@This(),
        payload: Range,
        forbidden: []const Range,
    ) Typed {
        if (!self.disjointFrom(payload, forbidden)) failStopPermitAliasPreflight();
        return self.initializeDisjoint();
    }
};

pub fn armFinishPermitAliasForTest(range_index: u8) void {
    if (!builtin.is_test) @compileError("test-only finish permit alias trigger");
    if (range_index >= 4 or finish_permit_alias_case_for_test != 0)
        @panic("invalid finish permit alias test range");
    finish_permit_alias_case_for_test = range_index + 1;
}

test "B3-4/5 finish permit raw storage rejects alias and overflow before typed init" {
    var storage: FinishPermitRawStorage = undefined;
    const ranges = storage.ranges();
    const first = ranges[0];
    try std.testing.expect(!storage.disjointFrom(
        .{ .start = first.start, .len = first.len },
        &.{},
    ));
    try std.testing.expect(!storage.disjointFrom(
        .{ .start = first.start - 1, .len = 2 },
        &.{},
    ));
    try std.testing.expect(!storage.disjointFrom(
        .{ .start = first.start + first.len - 1, .len = 2 },
        &.{},
    ));
    try std.testing.expect(!storage.disjointFrom(
        .{ .start = std.math.maxInt(usize), .len = 2 },
        &.{},
    ));
    try std.testing.expect(!storage.disjointFrom(
        .{ .start = 1, .len = 1 },
        &.{.{ .start = first.start, .len = first.len }},
    ));
    try std.testing.expect(storage.disjointFrom(.{ .start = 1, .len = 1 }, &.{}));

    const typed = storage.initializeDisjoint();
    try std.testing.expect(typed.releasing.pristineExact());
    try std.testing.expect(typed.finish_authority.pristineExact());
    try std.testing.expect(typed.evidence_retire.pristineExact());
    try std.testing.expect(typed.rearm.pristineExact());
}

fn beginRpcResponseBorrow(
    request: GenerationRequestAbort,
    response: *RpcExecutedResponse,
    out: *rpc_executed_response.RpcResponseBorrow,
) !void {
    const admission = try beginGenerationRequestOwner(request, false);
    defer endRegisteredNodeOperation(admission.operation);
    const node = admission.operation.node;
    const identity = response.identity;
    const canonical = rpcAuthorityCanonical(identity);
    if (!std.meta.eql(identity.binding, admission.identity) or
        canonical.destination_addr != @intFromPtr(response)) return error.InvalidOwner;
    var permit: rpc_response_authority.PreparedRpcTransitionPermit = .{};
    var borrow_init: rpc_executed_response.PreparedBorrowInit = .{};
    const payload_addr = response.payload_addr;
    const payload_len = response.payload_len;
    inline for (.{
        .{ @intFromPtr(&admission.operation), @sizeOf(RegisteredNodeOperation) },
        .{ @intFromPtr(&permit), @sizeOf(rpc_response_authority.PreparedRpcTransitionPermit) },
        .{ @intFromPtr(&borrow_init), @sizeOf(rpc_executed_response.PreparedBorrowInit) },
        .{ @intFromPtr(out), @sizeOf(rpc_executed_response.RpcResponseBorrow) },
        .{ @intFromPtr(node), @sizeOf(ClientNode) },
    }) |range| if (byteRangesOverlap(payload_addr, payload_len, range[0], range[1]))
        return error.InvalidOwner;
    try node.cleanup_registry.prepareRpcResponseBorrowed(
        request.reservation.cleanup,
        admission.identity,
        canonical,
        &permit,
    );
    try response.prepareBorrowInit(identity, out, &borrow_init);
    node.cleanup_registry.commitRpcResponseBorrowed(
        request.reservation.cleanup,
        admission.identity,
        canonical,
        &permit,
    );
    response.commitBorrowReceiptNoFail(identity, out, &borrow_init);
}

fn finishRpcResponseOwned(
    request: GenerationRequestAbort,
    response: *RpcExecutedResponse,
    borrow: *rpc_executed_response.RpcResponseBorrow,
    disposition: RpcResponseDisposition,
) !void {
    const admission = try beginGenerationRequestOwner(request, false);
    defer endRegisteredNodeOperation(admission.operation);
    const node = admission.operation.node;
    const identity = response.identity;
    const canonical = rpcAuthorityCanonical(identity);
    if (!std.meta.eql(identity.binding, admission.identity) or
        canonical.destination_addr != @intFromPtr(response) or
        !node.rpc_free_evidence.emptyExact()) return error.InvalidOwner;
    var finish: rpc_executed_response.RpcResponseFinishTxn = undefined;
    var permit_storage: FinishPermitRawStorage = undefined;
    const payload_addr = response.payload_addr;
    const payload_len = response.payload_len;
    const forbidden = [_]FinishPermitRawStorage.Range{
        .{ .start = @intFromPtr(&admission.operation), .len = @sizeOf(RegisteredNodeOperation) },
        .{ .start = @intFromPtr(&finish), .len = @sizeOf(rpc_executed_response.RpcResponseFinishTxn) },
        .{ .start = @intFromPtr(borrow), .len = @sizeOf(rpc_executed_response.RpcResponseBorrow) },
        .{ .start = @intFromPtr(response), .len = @sizeOf(RpcExecutedResponse) },
        .{ .start = @intFromPtr(node), .len = @sizeOf(ClientNode) },
        .{ .start = admission.owner.owner_addr, .len = admission.owner.owner_size },
    };
    const payload_range = if (builtin.is_test and finish_permit_alias_case_for_test != 0) blk: {
        const range_index = finish_permit_alias_case_for_test - 1;
        finish_permit_alias_case_for_test = 0;
        break :blk permit_storage.ranges()[range_index];
    } else FinishPermitRawStorage.Range{ .start = payload_addr, .len = payload_len };
    const permits = permit_storage.initializeAfterPreflightOrFail(
        payload_range,
        &forbidden,
    );
    for (forbidden) |range| {
        if (byteRangesOverlap(payload_addr, payload_len, range.start, range.len)) {
            terminalizeBorrowedRpcResponseNoFree(
                node,
                request.reservation.cleanup,
                admission.identity,
                canonical,
                response,
                identity,
            );
        }
    }
    finish = .{};
    response.prepareFinish(identity, borrow, &finish) catch {
        terminalizeBorrowedRpcResponseNoFree(
            node,
            request.reservation.cleanup,
            admission.identity,
            canonical,
            response,
            identity,
        );
    };
    try node.cleanup_registry.prepareRpcResponseReleasing(
        request.reservation.cleanup,
        admission.identity,
        canonical,
        permits.releasing,
    );
    response.commitFreeNoFail(identity, borrow, &finish);
    node.cleanup_registry.commitRpcResponseReleasing(
        request.reservation.cleanup,
        admission.identity,
        canonical,
        permits.releasing,
    );
    const evidence = finish.freeEvidenceDigest() orelse
        @panic("RPC response finish lost free evidence");
    if (!node.rpc_free_evidence.commitFreeCall(identity.response_epoch, evidence))
        @panic("RPC response node free evidence busy");
    if (!finish.freeCaptured())
        failStopFreedRpcResponse(
            node,
            request.reservation.cleanup,
            admission.identity,
            canonical,
            evidence,
            "RPC response allocator callback settlement drifted",
        );
    switch (disposition) {
        .reusable => node.cleanup_registry.prepareRpcResponseReusable(
            request.reservation.cleanup,
            admission.identity,
            canonical,
            permits.finish_authority,
        ) catch failStopFreedRpcResponse(
            node,
            request.reservation.cleanup,
            admission.identity,
            canonical,
            evidence,
            "RPC response reusable finish preflight drifted",
        ),
        .protocol_failure => node.cleanup_registry.prepareRpcResponseTerminal(
            request.reservation.cleanup,
            admission.identity,
            canonical,
            permits.finish_authority,
        ) catch failStopFreedRpcResponse(
            node,
            request.reservation.cleanup,
            admission.identity,
            canonical,
            evidence,
            "RPC response terminal finish preflight drifted",
        ),
    }
    if (!node.rpc_free_evidence.prepareRetireFreeCall(
        identity.response_epoch,
        evidence,
        permits.evidence_retire,
    )) failStopFreedRpcResponse(
        node,
        request.reservation.cleanup,
        admission.identity,
        canonical,
        evidence,
        "RPC response evidence retire preflight drifted",
    );
    if (disposition == .reusable) response.prepareReusableRearm(&finish, permits.rearm) catch
        failStopFreedRpcResponse(
            node,
            request.reservation.cleanup,
            admission.identity,
            canonical,
            evidence,
            "RPC response reusable rearm preflight drifted",
        );
    response.finishCleanNoFail(&finish);
    switch (disposition) {
        .reusable => node.cleanup_registry.commitRpcResponseReusable(
            request.reservation.cleanup,
            admission.identity,
            canonical,
            permits.finish_authority,
        ),
        .protocol_failure => node.cleanup_registry.commitRpcResponseTerminal(
            request.reservation.cleanup,
            admission.identity,
            canonical,
            permits.finish_authority,
        ),
    }
    node.rpc_free_evidence.commitEvidenceRetireNoFail(permits.evidence_retire);
    if (disposition == .protocol_failure)
        node.client.poison(.peer_contract_violation);
    if (disposition == .reusable)
        response.commitReusableRearmNoFail(&finish, permits.rearm);
}

fn terminalizeBorrowedRpcResponseNoFree(
    node: *ClientNode,
    reservation: cleanup_registry_mod.Reservation,
    binding: contract.BindingIdentity,
    canonical: rpc_response_authority.Canonical,
    response: *RpcExecutedResponse,
    identity: rpc_executed_response.Identity,
) noreturn {
    var releasing: rpc_response_authority.PreparedRpcTransitionPermit = .{};
    var terminal: rpc_response_authority.PreparedRpcTransitionPermit = .{};
    node.cleanup_registry.prepareRpcResponseReleasing(
        reservation,
        binding,
        canonical,
        &releasing,
    ) catch @panic("RPC response no-free release preflight drifted");
    const owner_settled = if (response.abandonLiveNoFree(identity)) |_| true else |_| false;
    node.cleanup_registry.commitRpcResponseReleasing(
        reservation,
        binding,
        canonical,
        &releasing,
    );
    node.cleanup_registry.prepareRpcResponseTerminal(
        reservation,
        binding,
        canonical,
        &terminal,
    ) catch @panic("RPC response no-free terminal preflight drifted");
    node.cleanup_registry.commitRpcResponseTerminal(
        reservation,
        binding,
        canonical,
        &terminal,
    );
    node.client.poison(.local_invariant_violation);
    if (!owner_settled) @panic("RPC response no-free owner was already invalid");
    @panic("RPC response no-free terminal settlement");
}

fn failStopFreedRpcResponse(
    node: *ClientNode,
    reservation: cleanup_registry_mod.Reservation,
    identity: contract.BindingIdentity,
    canonical: rpc_response_authority.Canonical,
    evidence: owner_seal.Digest,
    message: []const u8,
) noreturn {
    if (!node.rpc_free_evidence.commitTerminalFreedOnce(canonical.response_epoch, evidence))
        @panic("RPC response terminal freed-once evidence drifted");
    var terminal: rpc_response_authority.PreparedRpcTransitionPermit = .{};
    node.cleanup_registry.prepareRpcResponseTerminal(
        reservation,
        identity,
        canonical,
        &terminal,
    ) catch {
        node.client.poison(.local_invariant_violation);
        @panic("RPC response releasing authority could not terminalize");
    };
    node.cleanup_registry.commitRpcResponseTerminal(
        reservation,
        identity,
        canonical,
        &terminal,
    );
    node.client.poison(.local_invariant_violation);
    @panic(message);
}

/// Executes the attach-compatible request while one registry operation pins the canonical
/// ClientSlot node. No node, Client, binding, or response-owner address escapes this scope.
pub fn executeGenerationRequest(
    execution: GenerationRequestExecute,
) GenerationExecuteError!contract.ExecuteResult {
    const request = execution.request;
    if (!request.receipt.valid() or execution.response_out_addr == 0 or
        execution.owner_addr == 0 or execution.owner_size == 0)
        return error.InvalidOwner;
    _ = std.math.add(usize, execution.owner_addr, execution.owner_size) catch
        return error.InvalidOwner;
    if (!byteRangeFullyContained(
        execution.response_out_addr,
        @sizeOf(executed_response_mod.ExecutedResponse),
        execution.owner_addr,
        execution.owner_size,
    )) return error.InvalidResponseDestination;

    const admission = try beginGenerationRequestOwner(request, false);
    defer endRegisteredNodeOperation(admission.operation);
    const node = admission.operation.node;
    const identity = admission.identity;
    if (execution.owner_addr != admission.owner.owner_addr or
        execution.owner_size != admission.owner.owner_size)
        return error.InvalidOwner;
    const response_out: *executed_response_mod.ExecutedResponse = @ptrFromInt(
        execution.response_out_addr,
    );
    _ = switch (try resolveResponseDestination(admission.owner, .{ .attach = response_out })) {
        .attach => |destination| destination,
        .rpc => unreachable,
    };
    const prepared_admission = node.cleanup_registry.preparedAttachAdmission(
        request.reservation.cleanup,
        identity,
        request.transport_addr,
        request.transport_incarnation,
        request.receipt,
        execution.bound_stream_id,
    ) catch |err| return switch (err) {
        error.InvalidOwner => error.InvalidOwner,
        error.InvalidReceipt => error.InvalidReceipt,
        error.InvalidResponseDestination => error.InvalidResponseDestination,
    };
    switch (prepared_admission.decision) {
        .allowed => {},
        .unauthorized => return error.Unauthorized,
        .busy => return error.Busy,
    }
    const canonical = prepared_admission.canonical;
    const storage: *client_mod.PreparedBlockingRpcStorage =
        @ptrFromInt(request.prepared_storage_addr);
    const prepared_identity: client_mod.PreparedBlockingRpcIdentity = .{
        .request_id = canonical.receipt.request_id,
        .frame_digest = canonical.receipt.request_digest,
        .descriptor = canonical.descriptor,
    };
    if (!node.client.preparedBlockingRpcStorageMatches(storage, prepared_identity)) {
        node.cleanup_registry.settlePreparedRequest(
            request.reservation.cleanup,
            identity,
            canonical,
            true,
        ) catch return error.ProtocolError;
        node.client.poison(.local_invariant_violation);
        return error.ProtocolError;
    }
    var execution_txn: PreparedExecutionTxn = .{};
    defer execution_txn.ensureSettledOrFailStop(admission.operation);
    try execution_txn.initBeforeBeginExecute(
        admission.operation,
        request,
        identity,
        canonical,
    );
    execution_txn.commitBeginExecute(admission.operation);

    const response_owner = node.cleanup_registry.responseOwnerSeal(
        request.reservation.cleanup,
        identity,
    ) catch {
        const outcome = try execution_txn.rollbackPreWire(admission.operation);
        execution_txn.finishOrFailStop(admission.operation, outcome);
        return error.InvalidOwner;
    };
    const binding: *contract.PreparedAttachmentBinding =
        @ptrFromInt(identity.binding_storage_addr);
    if (!responseDestinationValid(
        response_out,
        response_owner,
        binding,
        storage,
        execution.owner_addr,
        execution.owner_size,
        request.slot_addr,
        node,
    )) {
        const outcome = try execution_txn.rollbackPreWire(admission.operation);
        execution_txn.finishOrFailStop(admission.operation, outcome);
        return error.InvalidResponseDestination;
    }

    var allocator_scope: client_mod.Client.GenerationAllocatorScope = .{};
    var payload_ledger: response_payload_allocation.Ledger = .{};
    var execution_cleanup: PreparedExecutionCleanup = undefined;
    var cleanup_expected_stage: PreparedExecutionCleanup.CleanupStage = .guard;
    var cleanup_completion: u8 = 0;
    const response_ranges = [_]GenerationGuardedAllocator.OperationRangeInput{
        .{ .start = @intFromPtr(response_out), .len = @sizeOf(executed_response_mod.ExecutedResponse) },
        .{ .start = @intFromPtr(response_owner), .len = @sizeOf(contract.ExecutedResponseOwnerSeal) },
        .{ .start = @intFromPtr(binding), .len = @sizeOf(contract.PreparedAttachmentBinding) },
        .{ .start = @intFromPtr(storage), .len = @sizeOf(client_mod.PreparedBlockingRpcStorage) },
        .{ .start = request.transport_addr, .len = 1 },
        .{ .start = execution.owner_addr, .len = execution.owner_size },
        .{ .start = @intFromPtr(&allocator_scope), .len = @sizeOf(client_mod.Client.GenerationAllocatorScope) },
        .{ .start = @intFromPtr(&payload_ledger), .len = @sizeOf(response_payload_allocation.Ledger) },
        .{ .start = @intFromPtr(&execution_txn), .len = @sizeOf(PreparedExecutionTxn) },
        .{ .start = @intFromPtr(&execution_cleanup), .len = @sizeOf(PreparedExecutionCleanup) },
        .{ .start = @intFromPtr(&cleanup_expected_stage), .len = @sizeOf(PreparedExecutionCleanup.CleanupStage) },
        .{ .start = @intFromPtr(&cleanup_completion), .len = @sizeOf(u8) },
    };
    const forbidden_payload_ranges = [_]response_payload_allocation.ForbiddenRange{
        .{ .start = @intFromPtr(response_out), .len = @sizeOf(executed_response_mod.ExecutedResponse) },
        .{ .start = @intFromPtr(response_owner), .len = @sizeOf(contract.ExecutedResponseOwnerSeal) },
        .{ .start = @intFromPtr(binding), .len = @sizeOf(contract.PreparedAttachmentBinding) },
        .{ .start = @intFromPtr(storage), .len = @sizeOf(client_mod.PreparedBlockingRpcStorage) },
        .{ .start = request.transport_addr, .len = 1 },
        .{ .start = execution.owner_addr, .len = execution.owner_size },
        .{ .start = @intFromPtr(&allocator_scope), .len = @sizeOf(client_mod.Client.GenerationAllocatorScope) },
        .{ .start = @intFromPtr(&payload_ledger), .len = @sizeOf(response_payload_allocation.Ledger) },
        .{ .start = request.slot_addr, .len = @sizeOf(ClientSlot) },
        .{ .start = @intFromPtr(node), .len = @sizeOf(ClientNode) },
        .{ .start = @intFromPtr(&execution_txn), .len = @sizeOf(PreparedExecutionTxn) },
        .{ .start = @intFromPtr(&execution_cleanup), .len = @sizeOf(PreparedExecutionCleanup) },
        .{ .start = @intFromPtr(&cleanup_expected_stage), .len = @sizeOf(PreparedExecutionCleanup.CleanupStage) },
        .{ .start = @intFromPtr(&cleanup_completion), .len = @sizeOf(u8) },
    };
    const guard = &node.guarded_allocator;
    if (!guard.beginOperationGuard(&response_ranges)) {
        const outcome = try execution_txn.rollbackPreWire(admission.operation);
        execution_txn.finishOrFailStop(admission.operation, outcome);
        return error.InvalidOwner;
    }
    execution_cleanup.init();
    defer execution_cleanup.ensureFinishedOrFailStop(
        &execution_txn,
        admission.operation,
        cleanup_expected_stage,
        &cleanup_completion,
        &node.client,
        guard,
        &allocator_scope,
        &payload_ledger,
    );
    node.client.beginGenerationAllocatorScope(
        guard.allocator(),
        .rpc_execute,
        &allocator_scope,
    ) catch |err| {
        if (err == error.IdentityExhausted) {
            _ = try settleExecutionAfterCleanup(
                &execution_cleanup,
                &execution_txn,
                admission.operation,
                cleanup_expected_stage,
                &cleanup_completion,
                &node.client,
                guard,
                &allocator_scope,
                &payload_ledger,
                .issuer_exhausted,
            );
            return error.IdentityExhausted;
        }
        _ = try settleExecutionAfterCleanup(
            &execution_cleanup,
            &execution_txn,
            admission.operation,
            cleanup_expected_stage,
            &cleanup_completion,
            &node.client,
            guard,
            &allocator_scope,
            &payload_ledger,
            .rollback_pre_wire,
        );
        return error.Busy;
    };
    cleanup_expected_stage = .allocator;
    if (!execution_cleanup.advance(.guard, cleanup_expected_stage)) {
        execution_cleanup.finishOrFailStop(
            &execution_txn,
            admission.operation,
            cleanup_expected_stage,
            &cleanup_completion,
            &node.client,
            guard,
            &allocator_scope,
            &payload_ledger,
        );
        const outcome = execution_txn.failStopCleanupFailure(admission.operation);
        execution_txn.finishOrFailStop(admission.operation, outcome);
    }

    const response_incarnation = issueGenerationResponseIncarnation() catch {
        _ = try settleExecutionAfterCleanup(
            &execution_cleanup,
            &execution_txn,
            admission.operation,
            cleanup_expected_stage,
            &cleanup_completion,
            &node.client,
            guard,
            &allocator_scope,
            &payload_ledger,
            .issuer_exhausted,
        );
        return error.IdentityExhausted;
    };
    response_payload_allocation.Ledger.initInPlace(
        &payload_ledger,
        guard.allocator(),
        .{
            .guard_addr = @intFromPtr(guard),
            .node_addr = @intFromPtr(node),
            .operation_incarnation = response_incarnation,
        },
        1,
    ) catch |err| {
        _ = try settleExecutionAfterCleanup(
            &execution_cleanup,
            &execution_txn,
            admission.operation,
            cleanup_expected_stage,
            &cleanup_completion,
            &node.client,
            guard,
            &allocator_scope,
            &payload_ledger,
            .issuer_exhausted,
        );
        return switch (err) {
            error.IdentityExhausted => error.IdentityExhausted,
            else => error.ProtocolError,
        };
    };
    cleanup_expected_stage = .ledger;
    if (!execution_cleanup.advance(.allocator, cleanup_expected_stage)) {
        execution_cleanup.finishOrFailStop(
            &execution_txn,
            admission.operation,
            cleanup_expected_stage,
            &cleanup_completion,
            &node.client,
            guard,
            &allocator_scope,
            &payload_ledger,
        );
        const outcome = execution_txn.failStopCleanupFailure(admission.operation);
        execution_txn.finishOrFailStop(admission.operation, outcome);
    }
    payload_ledger.bindForbiddenRanges(&forbidden_payload_ranges) catch {
        _ = try settleExecutionAfterCleanup(
            &execution_cleanup,
            &execution_txn,
            admission.operation,
            cleanup_expected_stage,
            &cleanup_completion,
            &node.client,
            guard,
            &allocator_scope,
            &payload_ledger,
            .rollback_pre_wire,
        );
        node.client.poison(.local_invariant_violation);
        @panic("response payload forbidden owner inventory drifted");
    };
    var payload_observer = ResponsePayloadObserverBridge{
        .ledger = &payload_ledger,
        .guard = guard,
    };
    const executed = contract.ExecutedCallReceipt.fromPrepared(request.receipt) orelse {
        _ = try settleExecutionAfterCleanup(
            &execution_cleanup,
            &execution_txn,
            admission.operation,
            cleanup_expected_stage,
            &cleanup_completion,
            &node.client,
            guard,
            &allocator_scope,
            &payload_ledger,
            .rollback_pre_wire,
        );
        return error.InvalidReceipt;
    };
    const response_allocator = node.client.preflightPreparedBlockingRpcStorageExecution(
        storage,
    ) catch |err| {
        _ = try settleExecutionAfterCleanup(
            &execution_cleanup,
            &execution_txn,
            admission.operation,
            cleanup_expected_stage,
            &cleanup_completion,
            &node.client,
            guard,
            &allocator_scope,
            &payload_ledger,
            .rollback_pre_wire,
        );
        return err;
    };

    // The pending flush may invoke allocator callbacks. Revalidate every canonical authority
    // under the still-held registry operation immediately before the first request byte.
    if (!(node.cleanup_registry.executingRequestMatches(
        request.reservation.cleanup,
        identity,
        canonical,
    ) catch false) or
        !node.client.preparedBlockingRpcStorageMatches(storage, prepared_identity) or
        !responseDestinationValid(
            response_out,
            response_owner,
            binding,
            storage,
            execution.owner_addr,
            execution.owner_size,
            request.slot_addr,
            node,
        ))
    {
        _ = try settleExecutionAfterCleanup(
            &execution_cleanup,
            &execution_txn,
            admission.operation,
            cleanup_expected_stage,
            &cleanup_completion,
            &node.client,
            guard,
            &allocator_scope,
            &payload_ledger,
            .rollback_pre_wire,
        );
        return error.InvalidResponseDestination;
    }

    if (builtin.is_test and guard.request_free_test_observer.inject_pending_before_execute) {
        const observer = &guard.request_free_test_observer;
        if (observer.pending_frame_addr == 0 or observer.pending_frame_len == 0 or
            node.client.pending_outbound != null)
            @panic("B3 pending injection descriptor drifted");
        const frame: [*]u8 = @ptrFromInt(observer.pending_frame_addr);
        node.client.pending_outbound = .{
            .frame = frame[0..observer.pending_frame_len],
            .stream_id = 10,
        };
        observer.pending_injected = true;
        if (observer.drift_request_before_execute) {
            if (observer.target_addr == 0 or observer.target_len == 0)
                @panic("B3 request drift descriptor missing");
            const request_frame: [*]u8 = @ptrFromInt(observer.target_addr);
            request_frame[observer.target_len - 1] ^= 1;
        }
        if (observer.poison_before_execute) node.client.poison(.transport_read_failure);
    }
    const ExecutionResult = @typeInfo(
        @TypeOf(client_mod.Client.executePreparedBlockingRpcStorageWithAllocatorObserved),
    ).@"fn".return_type.?;
    const execution_result: ExecutionResult =
        if (builtin.is_test and guard.request_free_test_observer.force_not_executed)
            .{ .not_executed = error.ConnectionClosed }
        else
            node.client.executePreparedBlockingRpcStorageWithAllocatorObserved(
                storage,
                response_allocator,
                payload_observer.observer(),
            );
    if (guard.operation_alias_rejected) {
        _ = try settleExecutionAfterCleanup(
            &execution_cleanup,
            &execution_txn,
            admission.operation,
            cleanup_expected_stage,
            &cleanup_completion,
            &node.client,
            guard,
            &allocator_scope,
            &payload_ledger,
            .{ .post_execute_terminal = .local_invariant_violation },
        );
        node.client.poison(.local_invariant_violation);
        if (builtin.is_test and c.getenv("MARU_SESSION_HOST_RESPONSE_ALIAS_EXEC") != null and
            if (c.getenv("MARU_SESSION_HOST_RESPONSE_ALIAS_CASE")) |raw|
                std.mem.eql(u8, std.mem.span(raw), "response_alias")
            else
                true)
        {
            const authority_terminal = if (node.cleanup_registry.publishPreparedRequest(
                request.reservation.cleanup,
                identity,
                canonical,
            )) false else |err| err == error.InvalidState;
            if (!client_mod.Client.preparedBlockingRpcStorageSettled(storage))
                @panic("B3 strict response-alias storage was not settled");
            if (!authority_terminal)
                @panic("B3 strict response-alias authority was not terminal");
            if (node.client.firstPoisonReason() != .local_invariant_violation)
                @panic("B3 strict response-alias poison drifted");
            const marker = "B3_STRICT_ROW request=exact_wire storage=settled authority=terminal connection=fail_stop outcome=fail_stop error=fail_stop poison=local_invariant response=terminal_no_free request_free=exact_once payload_free=no_free final_zero=false\n";
            _ = c.write(2, marker.ptr, marker.len);
        }
        @panic("response payload allocator returned a canonical owner alias");
    }
    const response = switch (execution_result) {
        .not_executed => |err| {
            return switch (err) {
                error.PayloadProvenanceRejected => {
                    _ = try settleExecutionAfterCleanup(
                        &execution_cleanup,
                        &execution_txn,
                        admission.operation,
                        cleanup_expected_stage,
                        &cleanup_completion,
                        &node.client,
                        guard,
                        &allocator_scope,
                        &payload_ledger,
                        .rollback_pre_wire,
                    );
                    node.client.poison(.local_invariant_violation);
                    @panic("response payload provenance failed before execution");
                },
                else => |execution_err| {
                    _ = try settleExecutionAfterCleanup(
                        &execution_cleanup,
                        &execution_txn,
                        admission.operation,
                        cleanup_expected_stage,
                        &cleanup_completion,
                        &node.client,
                        guard,
                        &allocator_scope,
                        &payload_ledger,
                        .rollback_pre_wire,
                    );
                    return execution_err;
                },
            };
        },
        .uncertain => |err| {
            if (err == error.PayloadProvenanceRejected) {
                _ = try settleExecutionAfterCleanup(
                    &execution_cleanup,
                    &execution_txn,
                    admission.operation,
                    cleanup_expected_stage,
                    &cleanup_completion,
                    &node.client,
                    guard,
                    &allocator_scope,
                    &payload_ledger,
                    .{ .post_execute_terminal = .local_invariant_violation },
                );
                node.client.poison(.local_invariant_violation);
                @panic("response payload allocator provenance became ambiguous");
            }
            node.client.poison(.transport_read_failure);
            const result: contract.ExecuteResult = .{
                .uncertain_or_connection_failure = executed,
            };
            response_out.initWithoutPayloadInPlace(
                response_owner,
                response_incarnation,
                result,
            ) catch {
                _ = try settleExecutionAfterCleanup(
                    &execution_cleanup,
                    &execution_txn,
                    admission.operation,
                    cleanup_expected_stage,
                    &cleanup_completion,
                    &node.client,
                    guard,
                    &allocator_scope,
                    &payload_ledger,
                    .{ .post_execute_terminal = .local_invariant_violation },
                );
                node.client.poison(.local_invariant_violation);
                return error.InvalidResponseDestination;
            };
            _ = try settleExecutionAfterCleanup(
                &execution_cleanup,
                &execution_txn,
                admission.operation,
                cleanup_expected_stage,
                &cleanup_completion,
                &node.client,
                guard,
                &allocator_scope,
                &payload_ledger,
                .{ .post_execute_terminal = .transport_read_failure },
            );
            return result;
        },
        .accepted => |value| value,
    };
    const payload_receipt = switch (payload_ledger.classifyResponsePayloadProvenance(
        response.payload_observation_generation,
        response.payload,
        response.payload_allocator,
        response_allocator,
    )) {
        .promoted => |receipt| receipt,
        .fail_stop_required => |reason| {
            _ = try settleExecutionAfterCleanup(
                &execution_cleanup,
                &execution_txn,
                admission.operation,
                cleanup_expected_stage,
                &cleanup_completion,
                &node.client,
                guard,
                &allocator_scope,
                &payload_ledger,
                .{ .post_execute_terminal = .local_invariant_violation },
            );
            node.client.poison(.local_invariant_violation);
            failStopResponsePayloadProvenance(reason);
        },
    };
    const canonical_owner_drift = !(node.cleanup_registry.executingRequestMatches(
        request.reservation.cleanup,
        identity,
        canonical,
    ) catch false) or
        !responseOwnerStillPristine(response_out, response_owner);
    if (canonical_owner_drift) {
        node.client.poison(.local_invariant_violation);
        payload_ledger.releasePromotedResponse(payload_receipt) catch
            @panic("safe response provenance release drifted");
        _ = try settleExecutionAfterCleanup(
            &execution_cleanup,
            &execution_txn,
            admission.operation,
            cleanup_expected_stage,
            &cleanup_completion,
            &node.client,
            guard,
            &allocator_scope,
            &payload_ledger,
            .{ .post_execute_terminal = .local_invariant_violation },
        );
        return error.InvalidResponseDestination;
    }
    const correlated = contract.CorrelatedExecutedCall.init(
        executed,
        response.response_request_id,
    ) orelse {
        node.client.poison(.local_invariant_violation);
        payload_ledger.releasePromotedResponse(payload_receipt) catch
            @panic("safe response provenance release drifted");
        _ = try settleExecutionAfterCleanup(
            &execution_cleanup,
            &execution_txn,
            admission.operation,
            cleanup_expected_stage,
            &cleanup_completion,
            &node.client,
            guard,
            &allocator_scope,
            &payload_ledger,
            .{ .post_execute_terminal = .local_invariant_violation },
        );
        return error.InvalidReceipt;
    };
    if (!correlated.responseMatchesPrepared()) {
        node.client.poison(.response_correlation_lost);
        payload_ledger.releasePromotedResponse(payload_receipt) catch
            @panic("safe response provenance release drifted");
        _ = try settleExecutionAfterCleanup(
            &execution_cleanup,
            &execution_txn,
            admission.operation,
            cleanup_expected_stage,
            &cleanup_completion,
            &node.client,
            guard,
            &allocator_scope,
            &payload_ledger,
            .{ .post_execute_terminal = .response_correlation_lost },
        );
        return error.InvalidReceipt;
    }
    const result: contract.ExecuteResult = .{ .accepted = correlated };
    switch (payload_ledger.transferPromotedResponse(
        payload_receipt,
        response_out,
        response_owner,
        response_incarnation,
        correlated,
    )) {
        .transferred => {},
        .rejected_safe_released => {
            node.client.poison(.local_invariant_violation);
            _ = try settleExecutionAfterCleanup(
                &execution_cleanup,
                &execution_txn,
                admission.operation,
                cleanup_expected_stage,
                &cleanup_completion,
                &node.client,
                guard,
                &allocator_scope,
                &payload_ledger,
                .{ .post_execute_terminal = .local_invariant_violation },
            );
            return error.InvalidResponseDestination;
        },
        .fail_stop_required => |reason| {
            _ = try settleExecutionAfterCleanup(
                &execution_cleanup,
                &execution_txn,
                admission.operation,
                cleanup_expected_stage,
                &cleanup_completion,
                &node.client,
                guard,
                &allocator_scope,
                &payload_ledger,
                .{ .post_execute_terminal = .local_invariant_violation },
            );
            node.client.poison(.local_invariant_violation);
            failStopResponsePayloadTransfer(reason);
        },
    }
    _ = try settleExecutionAfterCleanup(
        &execution_cleanup,
        &execution_txn,
        admission.operation,
        cleanup_expected_stage,
        &cleanup_completion,
        &node.client,
        guard,
        &allocator_scope,
        &payload_ledger,
        .post_execute_reusable,
    );
    return result;
}

fn responseDestinationValid(
    response_out: *executed_response_mod.ExecutedResponse,
    response_owner: *contract.ExecutedResponseOwnerSeal,
    binding: *contract.PreparedAttachmentBinding,
    storage: *client_mod.PreparedBlockingRpcStorage,
    owner_addr: usize,
    owner_size: usize,
    slot_addr: usize,
    node: *ClientNode,
) bool {
    const out_addr = @intFromPtr(response_out);
    const seal_addr = @intFromPtr(response_owner);
    // The existing attach destination is an owned field inside GenerationAttachment, so overlap
    // with the outer owner range is required to remain legal. It must still be disjoint from every
    // canonical node/binding/storage authority; the allocator guard separately rejects payloads
    // that alias any byte of the outer owner.
    if (byteRangesOverlap(out_addr, @sizeOf(executed_response_mod.ExecutedResponse), slot_addr, @sizeOf(ClientSlot)) or
        byteRangesOverlap(out_addr, @sizeOf(executed_response_mod.ExecutedResponse), @intFromPtr(node), @sizeOf(ClientNode)) or
        byteRangesOverlap(out_addr, @sizeOf(executed_response_mod.ExecutedResponse), @intFromPtr(binding), @sizeOf(contract.PreparedAttachmentBinding)) or
        byteRangesOverlap(out_addr, @sizeOf(executed_response_mod.ExecutedResponse), @intFromPtr(storage), @sizeOf(client_mod.PreparedBlockingRpcStorage)) or
        byteRangesOverlap(seal_addr, @sizeOf(contract.ExecutedResponseOwnerSeal), owner_addr, owner_size) or
        byteRangesOverlap(seal_addr, @sizeOf(contract.ExecutedResponseOwnerSeal), @intFromPtr(binding), @sizeOf(contract.PreparedAttachmentBinding)) or
        byteRangesOverlap(seal_addr, @sizeOf(contract.ExecutedResponseOwnerSeal), @intFromPtr(storage), @sizeOf(client_mod.PreparedBlockingRpcStorage)))
        return false;
    return response_out.canInitializeWithOwner(response_owner);
}

fn byteRangeFullyContained(
    inner_addr: usize,
    inner_len: usize,
    outer_addr: usize,
    outer_len: usize,
) bool {
    if (inner_len == 0 or outer_len == 0) return false;
    const inner_end = std.math.add(usize, inner_addr, inner_len) catch return false;
    const outer_end = std.math.add(usize, outer_addr, outer_len) catch return false;
    return inner_addr >= outer_addr and inner_end <= outer_end;
}

fn responseOwnerStillPristine(
    response_out: *const executed_response_mod.ExecutedResponse,
    response_owner: *const contract.ExecutedResponseOwnerSeal,
) bool {
    return response_out.canInitializeWithOwner(response_owner);
}

fn byteRangesOverlap(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn issueGenerationResponseIncarnation() error{IdentityExhausted}!u64 {
    while (true) {
        const current = generation_response_incarnation_issuer.load(.monotonic);
        if (current == 0 or current == std.math.maxInt(u64)) return error.IdentityExhausted;
        if (generation_response_incarnation_issuer.cmpxchgWeak(
            current,
            current + 1,
            .monotonic,
            .monotonic,
        ) == null) return current;
    }
}

pub fn preflightGenerationTransportTerminalize(
    request: GenerationTransportOwnerQuery,
) error{ Busy, InvalidOwner }!void {
    const admission = beginGenerationRequestOwner(request, true) catch |err| return switch (err) {
        error.Busy => error.Busy,
        else => error.InvalidOwner,
    };
    defer endRegisteredNodeOperation(admission.operation);
    const readiness = admission.operation.node.cleanup_registry
        .transportTerminalizeReadiness(
        request.reservation.cleanup,
        admission.identity,
        admission.operation.node.pin_owner.active_cleanup == 1,
    ) catch return error.InvalidOwner;
    return switch (readiness) {
        .settled => {},
        .busy => error.Busy,
        .invalid => error.InvalidOwner,
    };
}

pub fn terminalizeGenerationTransportOwner(
    request: GenerationTransportOwnerQuery,
) error{ Busy, InvalidOwner }!void {
    const admission = beginGenerationRequestOwner(request, true) catch |err| return switch (err) {
        error.Busy => error.Busy,
        else => error.InvalidOwner,
    };
    defer endRegisteredNodeOperation(admission.operation);
    const readiness = admission.operation.node.cleanup_registry
        .transportTerminalizeReadiness(
        request.reservation.cleanup,
        admission.identity,
        admission.operation.node.pin_owner.active_cleanup == 1,
    ) catch return error.InvalidOwner;
    switch (readiness) {
        .settled => {},
        .busy => return error.Busy,
        .invalid => return error.InvalidOwner,
    }
    admission.owner.terminalize(request.transport_incarnation) catch
        return error.InvalidOwner;
}

fn mapGenerationRequestClientError(err: client_mod.PreparedBlockingRpcError) GenerationRequestError {
    return switch (err) {
        error.AdminBusy => error.Busy,
        error.Unauthorized => error.Unauthorized,
        error.OutOfMemory, error.EventQueueFull, error.DestinationOccupied => error.ResourceExhausted,
        error.ConnectionClosed, error.WriteFailed => error.ConnectionClosed,
        error.MovedOrCopied => error.InvalidOwner,
        error.InvalidPreparedRpc,
        error.EndpointAbsent,
        error.EndpointDenied,
        error.EndpointTransient,
        error.HandshakeFailed,
        error.IncompatibleVersion,
        error.ProtocolError,
        error.ExternalMode,
        => error.ProtocolError,
    };
}

fn rangesOverlapTyped(a: anytype, b: anytype) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    const a_end = std.math.add(usize, a_start, @sizeOf(@TypeOf(a.*))) catch return true;
    const b_end = std.math.add(usize, b_start, @sizeOf(@TypeOf(b.*))) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn sliceOverlapsObject(bytes: []const u8, object: anytype) bool {
    if (bytes.len == 0) return false;
    const bytes_start = @intFromPtr(bytes.ptr);
    const bytes_end = std.math.add(usize, bytes_start, bytes.len) catch return true;
    const object_start = @intFromPtr(object);
    const object_end = std.math.add(usize, object_start, @sizeOf(@TypeOf(object.*))) catch
        return true;
    return bytes_start < object_end and object_start < bytes_end;
}

fn generationBatchOwnerAliases(
    slot: *ClientSlot,
    owned: *const batch_registry_mod.OwnedBatch,
) bool {
    return sliceOverlapsObject(owned.bytes, slot) or
        sliceOverlapsObject(owned.bytes, slot.current) or
        sliceOverlapsObject(owned.bytes, owned);
}

fn checkedObjectRange(address: usize, comptime T: type) ?struct { start: usize, end: usize } {
    if (address == 0) return null;
    return .{
        .start = address,
        .end = std.math.add(usize, address, @sizeOf(T)) catch return null,
    };
}

fn endedPurgeOwnersAlias(
    entry: ClientSlotRegistryEntry,
    reservation: AttachmentBindingReservation,
    scratch: *client_mod.EndedPurgeScratch,
    out: *EndedPurgePreparation,
) bool {
    const scratch_range = checkedObjectRange(@intFromPtr(scratch), client_mod.EndedPurgeScratch) orelse
        return true;
    const out_range = checkedObjectRange(@intFromPtr(out), EndedPurgePreparation) orelse return true;
    const slot_range = checkedObjectRange(entry.slot_addr, ClientSlot) orelse return true;
    const node_range = checkedObjectRange(entry.node_addr, ClientNode) orelse return true;
    const binding_range = checkedObjectRange(
        reservation.identity.binding_storage_addr,
        contract.PreparedAttachmentBinding,
    ) orelse return true;
    const destination_range = checkedObjectRange(
        reservation.identity.destination_addr,
        lease_mod.ConnectionLease,
    ) orelse return true;
    const owners = [_]@TypeOf(slot_range){ slot_range, node_range, binding_range, destination_range };
    if (rawRangesOverlap(scratch_range.start, scratch_range.end, out_range.start, out_range.end))
        return true;
    for (owners) |owner| {
        if (rawRangesOverlap(scratch_range.start, scratch_range.end, owner.start, owner.end) or
            rawRangesOverlap(out_range.start, out_range.end, owner.start, owner.end))
            return true;
    }
    return false;
}

fn endedPurgeAliasesClientOwnedBacking(
    client: *const client_mod.Client,
    scratch: *client_mod.EndedPurgeScratch,
    out: *EndedPurgePreparation,
) bool {
    const scratch_bytes: [*]u8 = @ptrCast(scratch);
    const out_bytes: [*]u8 = @ptrCast(out);
    return client_mod.generationAllocationAliasesOwnedBacking(
        client,
        scratch_bytes,
        @sizeOf(client_mod.EndedPurgeScratch),
    ) or client_mod.generationAllocationAliasesOwnedBacking(
        client,
        out_bytes,
        @sizeOf(EndedPurgePreparation),
    );
}

fn poisonEndedPurgeCorrupt(slot: *ClientSlot) EndedPurgePreparationError {
    if (slot.current.client.firstPoisonReason() == null)
        slot.current.client.poison(.local_invariant_violation);
    return error.Corrupt;
}

fn productionIssuer() InitError!*lease_mod.IdentityIssuer {
    const pid = currentPid();
    // Fork children must fail before touching a mutex that a vanished parent thread may have held.
    if (pid == 0 or process_runtime_pid.load(.acquire) != pid)
        return error.ProcessDomainMismatch;
    while (!issuer_mutex.tryLock()) std.atomic.spinLoopHint();
    defer issuer_mutex.unlock();
    if ((process_issuer == null) != (ended_purge_quarantine_registry == null))
        @panic("process issuer and ended purge quarantine registry initialization diverged");
    return &(process_issuer orelse return error.ProcessDomainMismatch);
}

pub const ClientSlot = struct {
    const RegisteredClientOperation = struct {
        node: *ClientNode,
        registry_index: u16,
        operation_id: u64,
        pid: u32,
    };

    const ExclusiveTeardownReservation = struct {
        registry_entry: ClientSlotRegistryEntry,
        node: *ClientNode,
    };

    const PreparedStreamOperationPermitConsume = struct {
        const Lifecycle = enum(u8) { pristine, prepared, consumed };

        self_addr: usize = 0,
        registry_index: u16 = 0,
        registry_id: u64 = 0,
        slot_addr: usize = 0,
        slot_incarnation: u64 = 0,
        node_incarnation: u64 = 0,
        operation_generation: u64 = 0,
        permit_seal: owner_seal.Digest = [_]u8{0} ** 32,
        lifecycle: PreparedStreamOperationPermitConsume.Lifecycle = .pristine,
    };

    self_addr: usize,
    current: *ClientNode,
    node_allocator: std.mem.Allocator,
    incarnation: lease_mod.Identity,
    pid: u32,
    process_nonce: u64,
    operation_owner_thread_incarnation: u64,
    next_binding_incarnation: u64,
    lifecycle: Lifecycle,

    pub const ProcessRuntimeInitError = error{ProcessDomainMismatch};
    pub const EndedPurgeCommitError = error{
        InvalidOwner,
        InvalidState,
        Busy,
        Corrupt,
        ArithmeticOverflow,
        DestinationOccupied,
        QuarantineUnavailable,
    };
    pub const EndedPurgeResult = enum { purged };

    fn streamOperationPermitRawTagsValid(permit: *const StreamOperationPermit) bool {
        const kind_raw = @as(*const u8, @ptrCast(&permit.kind)).*;
        const role_raw = @as(*const u8, @ptrCast(&permit.binding.role)).*;
        return kind_raw <= @intFromEnum(StreamOperationKind.ended_purge) and
            role_raw <= @intFromEnum(contract.AttachmentRole.observer);
    }

    fn streamOperationPermitSeal(permit: StreamOperationPermit) owner_seal.Digest {
        var writer = owner_seal.Writer.init("maru.stream-operation-permit.v1");
        writer.writeUsize(@intFromPtr(permit.slot));
        writer.writeU16(permit.registry_index);
        writer.writeU64(permit.registry_id);
        writer.writeU64(permit.slot_incarnation);
        writer.writeU64(permit.node_incarnation);
        writer.writeU64(permit.generation);
        writer.writeU8(@intFromEnum(permit.kind));
        writer.writeU64(permit.owner_thread_incarnation);
        writer.writeUsize(permit.owner_addr);
        writer.writeU64(permit.transport_incarnation);
        writer.writeU64(permit.binding.binding_incarnation);
        writer.writeUsize(permit.binding.binding_storage_addr);
        writer.writeUsize(permit.binding.destination_addr);
        writer.writeU64(permit.binding.binding_reservation_id);
        writer.writeU64(permit.binding.slot_incarnation);
        writer.writeU64(permit.binding.node_incarnation);
        writer.writeU128(permit.binding.host_id);
        writer.writeU64(permit.binding.connection_generation);
        writer.writeU128(permit.binding.runtime_id);
        writer.writeU8(@intFromEnum(permit.binding.role));
        writer.writeU64(permit.binding.pid);
        writer.writeU64(permit.binding.process_nonce);
        return writer.finish();
    }

    pub fn initializeProcessRuntime() ProcessRuntimeInitError!void {
        const pid = currentPid();
        if (pid == 0) return error.ProcessDomainMismatch;
        const observed = process_runtime_pid.load(.acquire);
        if (observed != 0 and observed != pid) return error.ProcessDomainMismatch;
        if (observed == 0) {
            if (process_runtime_pid.cmpxchgStrong(0, pid, .acq_rel, .acquire)) |winner|
                if (winner != pid) return error.ProcessDomainMismatch;
        }

        while (!issuer_mutex.tryLock()) std.atomic.spinLoopHint();
        defer issuer_mutex.unlock();
        if (process_runtime_pid.load(.acquire) != pid) return error.ProcessDomainMismatch;
        if ((process_issuer == null) != (ended_purge_quarantine_registry == null))
            @panic("process issuer and ended purge quarantine registry initialization diverged");
        if (process_issuer == null) {
            var nonce: u64 = 0;
            if (builtin.os.tag == .macos) {
                std.c.arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(u64));
            } else {
                // The product owner is macOS-only.  This non-secret fallback exists solely so
                // cross-target compile tests can instantiate the type without a Darwin syscall.
                nonce = @as(u64, pid) ^ @as(u64, @intFromPtr(&process_issuer));
            }
            if (nonce == 0) nonce = 1;
            ended_purge_quarantine_registry = ended_purge_quarantine.Registry.init();
            process_issuer = lease_mod.IdentityIssuer.init(pid, nonce);
        }
    }

    pub fn initInPlace(
        out: *ClientSlot,
        node_allocator: std.mem.Allocator,
        source: *client_mod.Client,
        host_id: u128,
    ) InitError!void {
        return initInPlaceWithIssuer(
            out,
            node_allocator,
            source,
            host_id,
            try productionIssuer(),
            currentPid(),
        );
    }

    fn initInPlaceWithIssuer(
        out: *ClientSlot,
        node_allocator: std.mem.Allocator,
        source: *client_mod.Client,
        host_id: u128,
        issuer: *lease_mod.IdentityIssuer,
        pid: u32,
    ) InitError!void {
        if (@intFromPtr(out) == @intFromPtr(source)) return error.InvalidDestination;
        if (host_id == 0 or source.host_id != host_id or !source.canMoveToGenerationNode())
            return error.InvalidSource;
        const operation_owner_thread_incarnation = try acquireOperationThreadIncarnation();

        const slot_identity = issuer.reserve(.slot, pid) catch |err| return switch (err) {
            error.IdentityExhausted => error.IdentityExhausted,
            error.ProcessDomainMismatch => error.ProcessDomainMismatch,
        };
        const node_identity = issuer.reserve(.node, pid) catch |err| return switch (err) {
            error.IdentityExhausted => error.IdentityExhausted,
            error.ProcessDomainMismatch => error.ProcessDomainMismatch,
        };

        if (init_active) return error.ReentrantInit;
        init_active = true;
        defer init_active = false;

        const node = node_allocator.create(ClientNode) catch return error.OutOfMemory;
        // Until the returned address has passed checked range and alias validation it is hostile
        // allocator output, not a destroyable allocation authority.
        var destroy_node_on_error = false;
        errdefer if (destroy_node_on_error) node_allocator.destroy(node);
        const node_start = @intFromPtr(node);
        const node_end = std.math.add(usize, node_start, @sizeOf(ClientNode)) catch {
            if (!recordAliasQuarantine()) @panic("ClientSlot alias quarantine exhausted");
            return error.AliasedAllocation;
        };
        const out_start = @intFromPtr(out);
        const out_end = std.math.add(usize, out_start, @sizeOf(ClientSlot)) catch
            return error.AliasedAllocation;
        const source_start = @intFromPtr(source);
        const source_end = std.math.add(usize, source_start, @sizeOf(client_mod.Client)) catch
            return error.AliasedAllocation;
        if (rangesOverlap(node_start, node_end, out_start, out_end) or
            rangesOverlap(node_start, node_end, source_start, source_end))
        {
            // An allocator that aliases caller-owned storage cannot be trusted to destroy that
            // pointer either.  Quarantine the backing and let the product invariant wrapper
            // fail-stop; freeing here could corrupt the still-authoritative source Client.
            destroy_node_on_error = false;
            if (!recordAliasQuarantine()) @panic("ClientSlot alias quarantine exhausted");
            return error.AliasedAllocation;
        }
        destroy_node_on_error = true;

        // All failure points are above.  From here the source move and publication are one no-fail
        // suffix, leaving exactly one Client owner in the heap node.
        node.cleanup_registry = .{};
        cleanup_registry_mod.AttachmentCleanupRegistry.initInPlace(
            &node.cleanup_registry,
            node_identity.tagged,
        ) catch unreachable;
        node.batch_registry = .{};
        batch_registry_mod.Registry.initInPlace(
            &node.batch_registry,
            node_identity.tagged,
        ) catch unreachable;
        node.accounting_ledger = .{};
        batch_registry_mod.AccountingLedger.initInPlace(&node.accounting_ledger) catch unreachable;
        node.next_operation_generation = 1;
        node.active_operation_generation = 0;
        node.active_operation_kind = .none;
        node.active_operation_owner_thread_incarnation = 0;
        node.active_operation_owner_addr = 0;
        node.active_operation_transport_incarnation = 0;
        node.active_operation_binding = undefined;
        node.rpc_free_evidence = .{};
        node.guarded_allocator = .{
            .parent = source.allocator,
            .node_start = node_start,
            .node_end = node_end,
            .slot_start = out_start,
            .slot_end = out_end,
            .source_start = source_start,
            .source_end = source_end,
        };
        const registry_reservation: ClientSlotRegistryEntry = .{
            .live = true,
            .slot_addr = out_start,
            .node_addr = node_start,
            .slot_incarnation = slot_identity.tagged,
            .node_incarnation = node_identity.tagged,
            .owner_thread_incarnation = operation_owner_thread_incarnation,
        };
        try registerClientSlot(registry_reservation);
        source.moveToGenerationNode(&node.client);
        client_mod.ClientOperationFence.initInPlace(
            &node.operation_fence,
            @intFromPtr(&node.client),
            pid,
            slot_identity.tagged,
            node_identity.tagged,
            node_identity.tagged,
        );
        if (!node.client.bindOperationFence(&node.operation_fence, node_identity.tagged))
            @panic("Client operation fence binding failed");
        node.guarded_allocator.client = &node.client;
        node.client.bindGenerationAccountingLedger(&node.accounting_ledger) catch unreachable;
        node.incarnation = node_identity;
        lease_mod.PinOwner.initInPlace(
            &node.pin_owner,
            @intFromPtr(out),
            @intFromPtr(node),
            slot_identity,
            node_identity,
            host_id,
            pid,
            issuer.process_nonce,
        );
        out.* = .{
            .self_addr = @intFromPtr(out),
            .current = node,
            .node_allocator = node_allocator,
            .incarnation = slot_identity,
            .pid = pid,
            .process_nonce = issuer.process_nonce,
            .operation_owner_thread_incarnation = operation_owner_thread_incarnation,
            .next_binding_incarnation = 1,
            .lifecycle = .live,
        };
        publishClientSlot(registry_reservation);
    }

    fn rangesOverlap(a_start: usize, a_end: usize, b_start: usize, b_end: usize) bool {
        return a_start < b_end and b_start < a_end;
    }

    fn beginRegisteredClientOperation(
        self: *ClientSlot,
    ) error{ MovedOrCopied, AdminBusy }!RegisteredClientOperation {
        // Reject a fork child before touching a mutex inherited from another thread. Holding the
        // registry mutex through the shared-fence CAS closes node destroy vs operation-entry ABA:
        // teardown cannot unregister/destroy between registry validation and the Client pin.
        if (self.pid != currentPid()) return error.MovedOrCopied;
        const operation = beginRegisteredNodeOperation(.{
            .slot_addr = @intFromPtr(self),
            .slot_incarnation = self.incarnation.tagged,
            .node = .{ .address = @intFromPtr(self.current) },
            .owner_thread_incarnation = self.operation_owner_thread_incarnation,
        }) catch |err| return switch (err) {
            error.Busy => error.AdminBusy,
            error.InvalidOwner => error.MovedOrCopied,
        };
        return .{
            .node = operation.node,
            .registry_index = operation.registry_index,
            .operation_id = operation.operation_id,
            .pid = operation.pid,
        };
    }

    fn endRegisteredClientOperation(_: *ClientSlot, operation: RegisteredClientOperation) void {
        // The shared count itself keeps the node alive until this exact decrement.
        endRegisteredNodeOperation(.{
            .node = operation.node,
            .registry_index = operation.registry_index,
            .operation_id = operation.operation_id,
            .pid = operation.pid,
        });
    }

    fn beginRegisteredExclusiveTeardown(
        self: *ClientSlot,
    ) error{ MovedOrCopied, AdminBusy }!ExclusiveTeardownReservation {
        if (self.pid != currentPid() or
            !operationThreadMatches(self.operation_owner_thread_incarnation))
            return error.MovedOrCopied;
        while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
        defer client_slot_registry_mutex.unlock();
        for (&client_slot_registry) |*entry| {
            if (!entry.live or entry.slot_addr != @intFromPtr(self)) continue;
            if (entry.node_addr == 0 or entry.node_addr != @intFromPtr(self.current) or
                entry.slot_incarnation != self.incarnation.tagged or
                entry.node_incarnation == 0 or
                entry.owner_thread_incarnation != self.operation_owner_thread_incarnation)
                return error.MovedOrCopied;
            if (!entry.ready) return error.AdminBusy;
            const node: *ClientNode = @ptrFromInt(entry.node_addr);
            // Close registry admission while exclusive is held. New operations fail at the
            // registry instead of setting fence intrusion. Direct Client calls can still record
            // intrusion, so pre-callback rollback uses abortExclusive to clear both bits.
            entry.ready = false;
            node.client.tryAcquireClientSlotTeardownExclusive() catch |err| {
                entry.ready = true;
                return switch (err) {
                    error.AdminBusy => error.AdminBusy,
                    error.InvalidOwner, error.InvalidState => error.MovedOrCopied,
                };
            };
            return .{ .registry_entry = entry.*, .node = node };
        }
        return error.MovedOrCopied;
    }

    fn abortRegisteredExclusiveTeardown(
        _: *ClientSlot,
        reserved: ExclusiveTeardownReservation,
    ) void {
        while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
        defer client_slot_registry_mutex.unlock();
        for (&client_slot_registry) |*entry| {
            if (!std.meta.eql(entry.*, reserved.registry_entry)) continue;
            if (!reserved.node.client.abortClientSlotTeardownExclusive())
                @panic("ClientSlot teardown exclusive abort failed");
            entry.ready = true;
            return;
        }
        @panic("ClientSlot teardown registry reservation drifted");
    }

    pub fn valid(self: *const ClientSlot) bool {
        if (self.self_addr != @intFromPtr(self) or self.lifecycle != .live or
            self.pid != currentPid() or self.process_nonce == 0 or
            self.operation_owner_thread_incarnation == 0 or
            self.incarnation.kind() != .slot)
            return false;
        _ = self.current.cleanup_registry.count() catch return false;
        _ = self.current.batch_registry.count() catch return false;
        return self.current.incarnation.kind() == .node and
            self.current.pin_owner.self_addr == @intFromPtr(&self.current.pin_owner) and
            self.current.pin_owner.slot_addr == @intFromPtr(self) and
            self.current.pin_owner.node_addr == @intFromPtr(self.current) and
            self.current.pin_owner.slot_incarnation == self.incarnation.tagged and
            self.current.pin_owner.node_incarnation == self.current.incarnation.tagged and
            self.current.pin_owner.host_id == self.current.client.host_id and
            self.current.pin_owner.connection_generation == 1 and
            self.current.pin_owner.pid == self.pid and
            self.current.pin_owner.process_nonce == self.process_nonce and
            self.current.cleanup_registry.self_addr == @intFromPtr(&self.current.cleanup_registry) and
            self.current.cleanup_registry.incarnation == self.current.incarnation.tagged and
            self.current.batch_registry.self_addr == @intFromPtr(&self.current.batch_registry) and
            self.current.batch_registry.incarnation == self.current.incarnation.tagged and
            self.current.accounting_ledger.matchesClient(@intFromPtr(&self.current.client));
    }

    pub fn reserveAttachmentBinding(
        self: *ClientSlot,
        binding_out: *contract.PreparedAttachmentBinding,
        lease_out: *lease_mod.ConnectionLease,
        runtime_id: u128,
        role: contract.AttachmentRole,
    ) BindingError!AttachmentBindingReservation {
        const operation = try self.beginRegisteredClientOperation();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid()) return error.MovedOrCopied;
        if (self.current.active_operation_generation != 0) return error.AdminBusy;
        const protected = .{
            self,
            self.current,
            &self.current.client,
            &self.current.pin_owner,
            &self.current.cleanup_registry,
        };
        if (runtime_id == 0 or rangesOverlapTyped(binding_out, lease_out))
            return error.InvalidIdentity;
        inline for (protected) |owner| {
            if (rangesOverlapTyped(binding_out, owner) or rangesOverlapTyped(lease_out, owner))
                return error.InvalidIdentity;
        }
        if (self.next_binding_incarnation == 0 or
            self.next_binding_incarnation == std.math.maxInt(u64))
            return error.IdentityExhausted;
        if (self.current.pin_owner.cleanup_pin_count == std.math.maxInt(usize))
            return error.PinOverflow;

        const binding_incarnation = self.next_binding_incarnation;
        const reserved = try self.current.cleanup_registry.reserve(.{
            .binding_incarnation = binding_incarnation,
            .binding_storage_addr = @intFromPtr(binding_out),
            .destination_addr = @intFromPtr(lease_out),
            .slot_incarnation = self.incarnation.tagged,
            .node_incarnation = self.current.incarnation.tagged,
            .host_id = self.current.client.host_id,
            .connection_generation = 1,
            .runtime_id = runtime_id,
            .role = role,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
        });
        errdefer self.current.cleanup_registry.abort(
            reserved.reservation,
            reserved.identity,
        ) catch @panic("attachment binding reservation rollback failed");

        try contract.PreparedAttachmentBinding.initReservedInPlace(binding_out, reserved.identity);
        self.current.pin_owner.cleanup_pin_count += 1;
        self.next_binding_incarnation = binding_incarnation + 1;
        return .{ .cleanup = reserved.reservation, .identity = reserved.identity };
    }

    pub fn abortAttachmentBinding(
        self: *ClientSlot,
        binding: *contract.PreparedAttachmentBinding,
        reservation: AttachmentBindingReservation,
    ) BindingError!void {
        if (!self.valid()) return error.MovedOrCopied;
        if (self.current.active_operation_generation != 0) return error.AdminBusy;
        if (!binding.validAtFinalAddress()) return error.MovedOrCopied;
        const canonical = binding.identity orelse return error.InvalidIdentity;
        if (!canonical.matches(reservation.identity) or
            canonical.binding_storage_addr != @intFromPtr(binding) or
            (binding.lifecycle != .reserved and binding.lifecycle != .request_paired))
            return error.InvalidState;
        if (self.current.pin_owner.cleanup_pin_count == 0) return error.InvalidState;

        try self.current.cleanup_registry.abort(reservation.cleanup, canonical);
        self.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }

    pub fn abortExecutedAttachmentBinding(
        self: *ClientSlot,
        binding: *contract.PreparedAttachmentBinding,
        reservation: AttachmentBindingReservation,
        executed: contract.ExecutedCallReceipt,
    ) BindingError!void {
        if (!self.valid()) return error.MovedOrCopied;
        if (self.current.active_operation_generation != 0) return error.AdminBusy;
        if (!binding.validAtFinalAddress()) return error.MovedOrCopied;
        const canonical = binding.identity orelse return error.InvalidIdentity;
        const prepared = binding.prepared_call orelse return error.InvalidState;
        if (!canonical.matches(reservation.identity) or
            canonical.binding_storage_addr != @intFromPtr(binding) or
            binding.lifecycle != .executing or
            !executed.matchesPrepared(prepared) or
            self.current.pin_owner.cleanup_pin_count == 0)
            return error.InvalidState;
        try self.current.cleanup_registry.abort(reservation.cleanup, canonical);
        self.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }

    pub fn commitAttachmentBinding(
        self: *ClientSlot,
        binding: *contract.PreparedAttachmentBinding,
        reservation: AttachmentBindingReservation,
        accepted: contract.CorrelatedExecutedCall,
        stream_id: u64,
        lease_out: *lease_mod.ConnectionLease,
    ) BindingError!void {
        if (!self.valid()) return error.MovedOrCopied;
        if (self.current.active_operation_generation != 0) return error.AdminBusy;
        if (!binding.validAtFinalAddress()) return error.MovedOrCopied;
        const canonical = binding.identity orelse return error.InvalidIdentity;
        const prepared = binding.prepared_call orelse return error.InvalidState;
        if (!canonical.matches(reservation.identity) or
            canonical.binding_storage_addr != @intFromPtr(binding) or
            binding.lifecycle != .executing or
            !accepted.executed_call.matchesPrepared(prepared) or
            !accepted.responseMatchesPrepared() or
            canonical.destination_addr != @intFromPtr(lease_out))
            return error.InvalidState;
        if (!lease_mod.ConnectionLease.canInitFromReservedPin(
            lease_out,
            &self.current.pin_owner,
            stream_id,
            self.pid,
        )) return error.InvalidLease;

        self.current.cleanup_registry.bindStream(
            reservation.cleanup,
            canonical,
            stream_id,
        ) catch |err| return err;
        lease_mod.ConnectionLease.initFromReservedPinUnchecked(
            lease_out,
            &self.current.pin_owner,
            stream_id,
            self.pid,
        );
        binding.lifecycle = .committed;
    }

    /// Validate the complete drop transaction and publish callback activity before any attachment
    /// payload is destroyed. A successful begin creates a no-fail suffix owned by
    /// `finishActiveAttachmentDrop`; CR3a-2d later replaces this local pair with the full typed
    /// permit/retry/quarantine owner.
    pub fn beginAttachmentDrop(
        self: *ClientSlot,
        binding: *contract.PreparedAttachmentBinding,
        reservation: AttachmentBindingReservation,
        lease: *lease_mod.ConnectionLease,
    ) BindingError!void {
        const operation = try self.beginCanonicalAuthorityAccess();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid() or operation.node != self.current) return error.MovedOrCopied;
        if (operation.node.active_operation_generation != 0) return error.AdminBusy;
        if (!operation.node.rpc_free_evidence.emptyExact()) return error.AdminBusy;
        if (!binding.validAtFinalAddress()) return error.MovedOrCopied;
        if (!contract.attachmentRoleRawValid(&reservation.identity.role))
            return error.InvalidIdentity;
        const canonical = binding.identity orelse return error.InvalidIdentity;
        if (!canonical.matches(reservation.identity) or
            canonical.binding_storage_addr != @intFromPtr(binding) or
            binding.lifecycle != .committed or
            lease.stream_id == 0 or !lease.canRelease(self.pid))
            return error.InvalidLease;
        switch (try operation.node.cleanup_registry.preparedRequestSettlementReadiness(
            reservation.cleanup,
            canonical,
        )) {
            .settled => {},
            .busy => return error.AdminBusy,
            .invalid => return error.InvalidState,
        }
        switch (try operation.node.cleanup_registry.rpcResponseSettlementReadiness(
            reservation.cleanup,
            canonical,
        )) {
            .settled => {},
            .busy => return error.AdminBusy,
            .invalid => return error.InvalidState,
        }
        try operation.node.cleanup_registry.preflightBoundDrop(
            reservation.cleanup,
            canonical,
            lease.stream_id,
        );

        operation.node.cleanup_registry.beginBoundDrop(
            reservation.cleanup,
            canonical,
            lease.stream_id,
        ) catch unreachable;
        operation.node.pin_owner.active_cleanup = 1;
    }

    /// No-fail suffix for a successfully begun attachment drop. The owner must call this exactly
    /// once after destroying the payload; every invariant was sealed by `beginAttachmentDrop`.
    pub fn finishActiveAttachmentDrop(
        self: *ClientSlot,
        binding: *contract.PreparedAttachmentBinding,
        reservation: AttachmentBindingReservation,
        lease: *lease_mod.ConnectionLease,
    ) void {
        const canonical = binding.identity orelse unreachable;
        if (!self.valid() or !binding.validAtFinalAddress() or
            !canonical.matches(reservation.identity) or
            canonical.binding_storage_addr != @intFromPtr(binding) or
            binding.lifecycle != .committed or self.current.pin_owner.active_cleanup != 1 or
            lease.stream_id == 0)
            unreachable;
        self.current.client.dropBufferedStream(lease.stream_id);
        self.current.cleanup_registry.completeActiveDrop(
            reservation.cleanup,
            canonical,
            lease.stream_id,
        ) catch unreachable;
        lease.releaseDuringActiveCleanupUnchecked(&self.current.pin_owner, self.pid);
        self.current.pin_owner.active_cleanup = 0;
        binding.lifecycle = .terminal;
    }

    pub fn logicalClient(self: *ClientSlot) *client_mod.Client {
        if (!self.valid()) @panic("invalid session-host ClientSlot");
        return &self.current.client;
    }

    pub fn logicalClientConst(self: *const ClientSlot) *const client_mod.Client {
        if (!self.valid()) @panic("invalid session-host ClientSlot");
        return &self.current.client;
    }

    pub fn transportOwnerSeal(
        self: *ClientSlot,
        reservation: AttachmentBindingReservation,
    ) BindingError!*contract.TransportOwnerSeal {
        if (!self.valid() or
            !operationThreadMatches(self.operation_owner_thread_incarnation))
            return error.MovedOrCopied;
        return self.current.cleanup_registry.transportOwnerSeal(
            reservation.cleanup,
            reservation.identity,
        );
    }

    fn beginCanonicalAuthorityAccess(
        self: *ClientSlot,
    ) BindingError!RegisteredClientOperation {
        // These methods protect the canonical input authority itself, so they cannot rely on the
        // caller having reached them through GenerationTransport. Reject fork/thread aliases
        // before node dereference, then pin the exact registered node against concurrent teardown.
        if (self.pid != currentPid() or
            !operationThreadMatches(self.operation_owner_thread_incarnation))
            return error.MovedOrCopied;
        return self.beginRegisteredClientOperation() catch |err| switch (err) {
            error.MovedOrCopied => error.MovedOrCopied,
            error.AdminBusy => error.AdminBusy,
        };
    }

    pub fn controllerAuthorityLive(
        self: *ClientSlot,
        reservation: AttachmentBindingReservation,
        stream_id: u64,
    ) BindingError!bool {
        const operation = try self.beginCanonicalAuthorityAccess();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid() or operation.node != self.current) return error.MovedOrCopied;
        return operation.node.cleanup_registry.controllerAuthorityLive(
            reservation.cleanup,
            reservation.identity,
            stream_id,
        );
    }

    pub fn controllerRevokePending(
        self: *ClientSlot,
        reservation: AttachmentBindingReservation,
        stream_id: u64,
    ) BindingError!bool {
        const operation = try self.beginCanonicalAuthorityAccess();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid() or operation.node != self.current) return error.MovedOrCopied;
        return operation.node.cleanup_registry.controllerRevokePending(
            reservation.cleanup,
            reservation.identity,
            stream_id,
        );
    }

    pub fn beginControllerRevoke(
        self: *ClientSlot,
        reservation: AttachmentBindingReservation,
        stream_id: u64,
    ) BindingError!void {
        const operation = try self.beginCanonicalAuthorityAccess();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid() or operation.node != self.current) return error.MovedOrCopied;
        try operation.node.cleanup_registry.beginControllerRevoke(
            reservation.cleanup,
            reservation.identity,
            stream_id,
        );
    }

    pub fn finishControllerRevoke(
        self: *ClientSlot,
        reservation: AttachmentBindingReservation,
        stream_id: u64,
    ) BindingError!void {
        const operation = try self.beginCanonicalAuthorityAccess();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid() or operation.node != self.current) return error.MovedOrCopied;
        try operation.node.cleanup_registry.finishControllerRevoke(
            reservation.cleanup,
            reservation.identity,
            stream_id,
        );
    }

    pub fn responseOwnerSeal(
        self: *ClientSlot,
        reservation: AttachmentBindingReservation,
    ) BindingError!*contract.ExecutedResponseOwnerSeal {
        if (!self.valid()) return error.MovedOrCopied;
        return self.current.cleanup_registry.responseOwnerSeal(
            reservation.cleanup,
            reservation.identity,
        );
    }

    pub fn reserveAttachmentBindingForTest(
        self: *ClientSlot,
        binding_out: *contract.PreparedAttachmentBinding,
        lease_out: *lease_mod.ConnectionLease,
        runtime_id: u128,
    ) BindingError!AttachmentBindingReservation {
        if (!builtin.is_test) unreachable;
        return self.reserveAttachmentBinding(
            binding_out,
            lease_out,
            runtime_id,
            .controller,
        );
    }

    pub const AttachmentBatchRead = union(enum) {
        committed: batch_registry_mod.Token,
        idle,
        terminal,
    };

    pub const BatchError = client_mod.ClientError || batch_registry_mod.Error;

    pub const GenerationBatchAdapterIdentity = struct {
        slot_incarnation: u64,
        node_incarnation: u64,
        pid: u32,
        process_nonce: u64,
    };

    /// Final-address GUI batch adapter가 raw node/Client 포인터를 보관하지 않고도 exact slot을
    /// 매 호출 재검증할 수 있는 pointer-free identity다.
    pub fn generationBatchAdapterIdentity(
        self: *ClientSlot,
    ) error{MovedOrCopied}!GenerationBatchAdapterIdentity {
        if (!self.valid()) return error.MovedOrCopied;
        return .{
            .slot_incarnation = self.incarnation.tagged,
            .node_incarnation = self.current.incarnation.tagged,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
        };
    }

    pub fn matchesGenerationBatchAdapterIdentity(
        self: *ClientSlot,
        identity: GenerationBatchAdapterIdentity,
    ) bool {
        return self.valid() and self.incarnation.tagged == identity.slot_incarnation and
            self.current.incarnation.tagged == identity.node_incarnation and
            self.pid == identity.pid and self.process_nonce == identity.process_nonce;
    }

    pub fn poisonAttachmentConnection(
        self: *ClientSlot,
        reason: @import("client_poison.zig").ConnectionReason,
    ) error{MovedOrCopied}!void {
        if (!self.valid()) return error.MovedOrCopied;
        self.current.client.poison(reason);
    }

    /// Client의 allocator callback TLS는 node-local mutation 진입점들이 같은 방식으로 읽는다.
    fn generationAllocatorCallbackActive(self: *const ClientSlot) bool {
        self.current.client.rejectGenerationAllocatorCallbackReentry() catch return true;
        return false;
    }

    pub const InitialSnapshotRead = struct {
        bytes: []u8,
        allocator: std.mem.Allocator,
    };

    pub fn prepareInitialSnapshotPermit(
        self: *ClientSlot,
        owner_addr: usize,
        transport_incarnation: u64,
        binding: contract.BindingIdentity,
    ) error{ InvalidSnapshotPermit, AdminBusy, IdentityExhausted }!InitialSnapshotPermit {
        return self.prepareStreamOperationPermit(
            .initial_snapshot,
            owner_addr,
            transport_incarnation,
            binding,
        ) catch |err| switch (err) {
            error.InvalidStreamOperationPermit => error.InvalidSnapshotPermit,
            error.AdminBusy => error.AdminBusy,
            error.IdentityExhausted => error.IdentityExhausted,
        };
    }

    pub fn prepareStreamOperationPermit(
        self: *ClientSlot,
        kind: StreamOperationKind,
        owner_addr: usize,
        transport_incarnation: u64,
        binding: contract.BindingIdentity,
    ) error{ InvalidStreamOperationPermit, AdminBusy, IdentityExhausted }!StreamOperationPermit {
        if (client_mod.generationAllocatorCallbackActive()) return error.AdminBusy;
        const operation = self.beginRegisteredClientOperation() catch |err| return switch (err) {
            error.AdminBusy => error.AdminBusy,
            error.MovedOrCopied => error.InvalidStreamOperationPermit,
        };
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid() or
            !operationThreadMatches(self.operation_owner_thread_incarnation) or
            kind == .none or owner_addr == 0 or transport_incarnation == 0 or
            binding.slot_incarnation != self.incarnation.tagged or
            binding.node_incarnation != self.current.incarnation.tagged or
            binding.host_id != self.current.client.host_id or
            binding.connection_generation != 1 or binding.pid != self.pid or
            binding.process_nonce != self.process_nonce)
            return error.InvalidStreamOperationPermit;
        if (batch_release_callback_active or self.current.active_operation_generation != 0 or
            self.current.pin_owner.active_cleanup != 0)
            return error.AdminBusy;
        const generation = self.current.next_operation_generation;
        const next_generation = std.math.add(u64, generation, 1) catch
            return error.IdentityExhausted;
        const owner_thread_incarnation = self.operation_owner_thread_incarnation;
        const permit = try registerStreamOperationPermit(.{
            .slot = self,
            .registry_index = 0,
            .registry_id = 0,
            .slot_incarnation = self.incarnation.tagged,
            .node_incarnation = self.current.incarnation.tagged,
            .generation = generation,
            .kind = kind,
            .owner_thread_incarnation = owner_thread_incarnation,
            .owner_addr = owner_addr,
            .transport_incarnation = transport_incarnation,
            .binding = binding,
        });
        self.current.next_operation_generation = next_generation;
        self.current.active_operation_generation = generation;
        self.current.active_operation_kind = kind;
        self.current.active_operation_owner_thread_incarnation = owner_thread_incarnation;
        self.current.active_operation_owner_addr = owner_addr;
        self.current.active_operation_transport_incarnation = transport_incarnation;
        self.current.active_operation_binding = binding;
        return permit;
    }

    pub fn initialSnapshotPermitLive(
        self: *const ClientSlot,
        permit: InitialSnapshotPermit,
    ) bool {
        return streamOperationPermitRawTagsValid(&permit) and
            permit.kind == .initial_snapshot and self.streamOperationPermitLive(permit);
    }

    pub fn streamOperationPermitLive(
        self: *const ClientSlot,
        permit: StreamOperationPermit,
    ) bool {
        if (!streamOperationPermitRawTagsValid(&permit)) return false;
        if (!operationThreadMatches(permit.owner_thread_incarnation)) return false;
        if (!streamOperationPermitRegistryLive(permit)) return false;
        return self.valid() and permit.slot == self and
            permit.slot_incarnation == self.incarnation.tagged and
            permit.node_incarnation == self.current.incarnation.tagged and
            permit.generation != 0 and
            permit.generation == self.current.active_operation_generation and
            permit.kind != .none and permit.kind == self.current.active_operation_kind and
            permit.owner_thread_incarnation == self.operation_owner_thread_incarnation and
            permit.owner_thread_incarnation == self.current.active_operation_owner_thread_incarnation and
            permit.owner_addr == self.current.active_operation_owner_addr and
            permit.transport_incarnation == self.current.active_operation_transport_incarnation and
            std.meta.eql(permit.binding, self.current.active_operation_binding);
    }

    pub fn abortInitialSnapshotPermit(
        self: *ClientSlot,
        permit: InitialSnapshotPermit,
    ) error{InvalidSnapshotPermit}!void {
        if (!self.initialSnapshotPermitLive(permit)) return error.InvalidSnapshotPermit;
        self.abortStreamOperationPermit(permit) catch return error.InvalidSnapshotPermit;
    }

    pub fn consumeInitialSnapshotPermit(
        self: *ClientSlot,
        permit: InitialSnapshotPermit,
    ) error{InvalidSnapshotPermit}!void {
        if (!self.initialSnapshotPermitLive(permit)) return error.InvalidSnapshotPermit;
        self.consumeStreamOperationPermit(permit) catch return error.InvalidSnapshotPermit;
    }

    pub fn initialSnapshotPermitIdle(self: *const ClientSlot) bool {
        return self.streamOperationPermitIdle();
    }

    pub fn abortStreamOperationPermit(
        self: *ClientSlot,
        permit: StreamOperationPermit,
    ) error{InvalidStreamOperationPermit}!void {
        if (!self.streamOperationPermitLive(permit)) return error.InvalidStreamOperationPermit;
        if (batch_release_callback_active or self.current.pin_owner.active_cleanup != 0)
            return error.InvalidStreamOperationPermit;
        if (self.generationAllocatorCallbackActive())
            return error.InvalidStreamOperationPermit;
        try unregisterStreamOperationPermit(permit);
        self.clearStreamOperationPermit();
    }

    pub fn consumeStreamOperationPermit(
        self: *ClientSlot,
        permit: StreamOperationPermit,
    ) error{InvalidStreamOperationPermit}!void {
        if (!self.streamOperationPermitLive(permit)) return error.InvalidStreamOperationPermit;
        if (batch_release_callback_active or self.current.pin_owner.active_cleanup != 0)
            return error.InvalidStreamOperationPermit;
        if (self.generationAllocatorCallbackActive())
            return error.InvalidStreamOperationPermit;
        try unregisterStreamOperationPermit(permit);
        self.clearStreamOperationPermit();
    }

    fn prepareStreamOperationPermitConsume(
        self: *ClientSlot,
        permit: StreamOperationPermit,
        out: *PreparedStreamOperationPermitConsume,
    ) error{ InvalidStreamOperationPermit, DestinationOccupied }!void {
        if (!streamOperationPermitRawTagsValid(&permit) or self.pid != currentPid() or
            !operationThreadMatches(permit.owner_thread_incarnation))
            return error.InvalidStreamOperationPermit;
        if (!std.meta.eql(out.*, PreparedStreamOperationPermitConsume{}))
            return error.DestinationOccupied;
        const index: usize = permit.registry_index;
        if (index >= stream_operation_registry.len or permit.registry_id == 0 or
            !self.valid() or permit.slot != self or
            permit.slot_incarnation != self.incarnation.tagged or
            permit.node_incarnation != self.current.incarnation.tagged or
            permit.generation == 0 or
            permit.generation != self.current.active_operation_generation or
            permit.kind == .none or permit.kind != self.current.active_operation_kind or
            permit.owner_thread_incarnation != self.operation_owner_thread_incarnation or
            permit.owner_thread_incarnation !=
                self.current.active_operation_owner_thread_incarnation or
            permit.owner_addr != self.current.active_operation_owner_addr or
            permit.transport_incarnation != self.current.active_operation_transport_incarnation or
            !std.meta.eql(permit.binding, self.current.active_operation_binding))
            return error.InvalidStreamOperationPermit;

        while (!stream_operation_registry_mutex.tryLock()) std.atomic.spinLoopHint();
        defer stream_operation_registry_mutex.unlock();
        const entry = &stream_operation_registry[index];
        if (entry.state.load(.acquire) !=
            @intFromEnum(StreamOperationRegistryEntry.State.live) or
            entry.id != permit.registry_id or !std.meta.eql(entry.permit, permit))
            return error.InvalidStreamOperationPermit;
        if (entry.state.cmpxchgStrong(
            @intFromEnum(StreamOperationRegistryEntry.State.live),
            @intFromEnum(StreamOperationRegistryEntry.State.consume_reserved),
            .acq_rel,
            .acquire,
        ) != null) return error.InvalidStreamOperationPermit;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .registry_index = permit.registry_index,
            .registry_id = permit.registry_id,
            .slot_addr = @intFromPtr(self),
            .slot_incarnation = permit.slot_incarnation,
            .node_incarnation = permit.node_incarnation,
            .operation_generation = permit.generation,
            .permit_seal = streamOperationPermitSeal(permit),
            .lifecycle = .prepared,
        };
    }

    fn consumeStreamOperationPermitUnchecked(
        self: *ClientSlot,
        prepared: *PreparedStreamOperationPermitConsume,
    ) bool {
        if (self.pid != currentPid() or
            !operationThreadMatches(self.operation_owner_thread_incarnation))
            return false;
        const index: usize = prepared.registry_index;
        const lifecycle_raw = @as(*const u8, @ptrCast(&prepared.lifecycle)).*;
        if (index >= stream_operation_registry.len or
            lifecycle_raw != @intFromEnum(PreparedStreamOperationPermitConsume.Lifecycle.prepared) or
            prepared.self_addr != @intFromPtr(prepared) or
            prepared.registry_id == 0 or prepared.slot_addr != @intFromPtr(self) or
            prepared.slot_incarnation != self.incarnation.tagged or
            prepared.node_incarnation != self.current.incarnation.tagged or
            prepared.operation_generation == 0 or
            prepared.operation_generation != self.current.active_operation_generation)
            return false;
        const entry = &stream_operation_registry[index];
        if (entry.state.load(.acquire) !=
            @intFromEnum(StreamOperationRegistryEntry.State.consume_reserved) or
            entry.id != prepared.registry_id or
            !streamOperationPermitRawTagsValid(&entry.permit) or
            !std.mem.eql(
                u8,
                &prepared.permit_seal,
                &streamOperationPermitSeal(entry.permit),
            ) or
            entry.permit.slot != self or
            entry.permit.slot_incarnation != prepared.slot_incarnation or
            entry.permit.node_incarnation != prepared.node_incarnation or
            entry.permit.generation != prepared.operation_generation or
            entry.permit.kind != self.current.active_operation_kind or
            entry.permit.owner_thread_incarnation !=
                self.current.active_operation_owner_thread_incarnation or
            entry.permit.owner_addr != self.current.active_operation_owner_addr or
            entry.permit.transport_incarnation !=
                self.current.active_operation_transport_incarnation or
            !std.meta.eql(entry.permit.binding, self.current.active_operation_binding))
            return false;
        if (entry.state.cmpxchgStrong(
            @intFromEnum(StreamOperationRegistryEntry.State.consume_reserved),
            @intFromEnum(StreamOperationRegistryEntry.State.consumed),
            .acq_rel,
            .acquire,
        ) != null) return false;
        self.clearStreamOperationPermit();
        prepared.lifecycle = .consumed;
        return true;
    }

    pub fn streamOperationPermitIdle(self: *const ClientSlot) bool {
        return self.valid() and streamOperationNodeIdle(self.current);
    }

    pub fn prepareEndedPurge(
        self: *ClientSlot,
        transport_incarnation: u64,
        reservation: AttachmentBindingReservation,
        target_stream: u64,
        hint: client_mod.EndedEventHint,
        scratch: *client_mod.EndedPurgeScratch,
        out: *EndedPurgePreparation,
    ) EndedPurgePreparationError!void {
        // A fork child must reject from caller-owned slot storage before touching a process-global
        // mutex that may have been inherited locked by a vanished sibling thread.
        if (self.pid != currentPid()) return error.InvalidOwner;
        const registry_entry = clientSlotRegistryEntry(@intFromPtr(self)) orelse
            return error.InvalidOwner;
        if (!operationThreadMatches(registry_entry.owner_thread_incarnation))
            return error.InvalidOwner;
        if (!self.valid() or registry_entry.node_addr != @intFromPtr(self.current) or
            registry_entry.slot_incarnation != self.incarnation.tagged or
            registry_entry.node_incarnation != self.current.incarnation.tagged or
            registry_entry.owner_thread_incarnation != self.operation_owner_thread_incarnation)
            return error.InvalidOwner;
        if (endedPurgeOwnersAlias(registry_entry, reservation, scratch, out))
            return error.InvalidOwner;
        if (endedPurgeAliasesClientOwnedBacking(&self.current.client, scratch, out))
            return error.InvalidOwner;
        if (out.lifecycle != .empty or out.self_addr != 0 or out.target_stream != 0 or
            !std.mem.allEqual(u8, &out.authority_seal, 0) or
            !std.meta.eql(out.inventory, client_mod.PreparedEndedPurgeInventory{}))
            return error.DestinationOccupied;
        self.current.cleanup_registry.preflightBoundDrop(
            reservation.cleanup,
            reservation.identity,
            target_stream,
        ) catch return error.InvalidOwner;
        const idle_before = self.current.batch_registry.streamIdle(target_stream) catch {
            return poisonEndedPurgeCorrupt(self);
        };
        if (!idle_before) return error.Busy;
        const permit = self.prepareStreamOperationPermit(
            .ended_purge,
            @intFromPtr(out),
            transport_incarnation,
            reservation.identity,
        ) catch |err| return switch (err) {
            error.InvalidStreamOperationPermit => error.InvalidOwner,
            error.AdminBusy => error.Busy,
            error.IdentityExhausted => error.IdentityExhausted,
        };
        errdefer self.abortStreamOperationPermit(permit) catch
            @panic("ended purge preparation permit rollback failed");
        const idle = self.current.batch_registry.streamIdle(target_stream) catch {
            return poisonEndedPurgeCorrupt(self);
        };
        if (!idle) return error.Busy;
        self.current.client.prepareEndedPurgeInventory(
            target_stream,
            hint,
            scratch,
            &out.inventory,
        ) catch |err| switch (err) {
            error.DestinationOccupied => return error.DestinationOccupied,
            error.InvalidHint,
            error.InvalidSource,
            error.InvalidAlias,
            error.ArithmeticOverflow,
            => return poisonEndedPurgeCorrupt(self),
        };
        out.self_addr = @intFromPtr(out);
        out.target_stream = target_stream;
        out.permit = permit;
        out.lifecycle = .prepared;
        out.authority_seal = endedPurgePreparationSeal(out);
    }

    pub fn commitEndedPurge(
        self: *ClientSlot,
        scratch: *client_mod.EndedPurgeScratch,
        preparation: *EndedPurgePreparation,
    ) EndedPurgeCommitError!EndedPurgeResult {
        // Fork children must reject before touching either inherited process-global registry.
        const pid = currentPid();
        if (pid == 0 or self.pid != pid or process_runtime_pid.load(.acquire) != pid)
            return error.InvalidOwner;
        const registry_entry = clientSlotRegistryEntry(@intFromPtr(self)) orelse
            return error.InvalidOwner;
        if (!operationThreadMatches(registry_entry.owner_thread_incarnation) or
            !self.valid() or registry_entry.node_addr != @intFromPtr(self.current) or
            registry_entry.slot_incarnation != self.incarnation.tagged or
            registry_entry.node_incarnation != self.current.incarnation.tagged or
            !preparation.rawTagsValid() or preparation.lifecycle != .prepared or
            preparation.self_addr != @intFromPtr(preparation) or
            preparation.target_stream == 0 or
            preparation.permit.owner_addr != @intFromPtr(preparation) or
            preparation.inventory.scratch_addr != @intFromPtr(scratch) or
            !std.mem.eql(
                u8,
                &preparation.authority_seal,
                &endedPurgePreparationSeal(preparation),
            ) or
            !self.streamOperationPermitLive(preparation.permit))
            return error.InvalidOwner;

        self.current.client.tryAcquireEndedPurgeExclusive() catch |err| return switch (err) {
            error.AdminBusy => error.Busy,
            error.InvalidOwner => error.InvalidOwner,
            error.InvalidState => error.InvalidState,
        };
        var release_exclusive = true;
        defer if (release_exclusive and
            !self.current.client.releaseEndedPurgeExclusiveClean())
            @panic("ended purge precommit exclusive rollback failed");

        var client_prepared: client_mod.PreparedEndedPurgeCommit = .{};
        self.current.client.prepareEndedPurgeCommit(
            preparation.target_stream,
            preparation.permit.generation,
            scratch,
            &preparation.inventory,
            &client_prepared,
        ) catch |err| return switch (err) {
            error.InvalidOwner => error.InvalidOwner,
            error.InvalidState => error.Busy,
            error.Corrupt => error.Corrupt,
            error.ArithmeticOverflow => error.ArithmeticOverflow,
            error.DestinationOccupied => error.DestinationOccupied,
        };

        const quarantine_registry = &(ended_purge_quarantine_registry orelse
            @panic("ended purge quarantine registry missing after process bootstrap"));
        var quarantine_reservation: ended_purge_quarantine.Reservation = .{};
        quarantine_registry.reserve(
            self.current.incarnation.tagged,
            preparation.permit.generation,
            client_prepared.complete_owned_extent_bytes,
            &quarantine_reservation,
        ) catch |err| {
            scratch.lifecycle = .inventory_prepared;
            client_prepared = .{};
            return switch (err) {
                error.InvalidOwner => error.InvalidOwner,
                error.ArithmeticOverflow => error.ArithmeticOverflow,
                error.InvalidState, error.CapacityExceeded => error.QuarantineUnavailable,
            };
        };

        var permit_consume: PreparedStreamOperationPermitConsume = .{};
        self.prepareStreamOperationPermitConsume(
            preparation.permit,
            &permit_consume,
        ) catch |err| {
            if (!quarantine_registry.release(&quarantine_reservation))
                @panic("ended purge quarantine rollback failed");
            scratch.lifecycle = .inventory_prepared;
            client_prepared = .{};
            return switch (err) {
                error.InvalidStreamOperationPermit => error.InvalidOwner,
                error.DestinationOccupied => error.DestinationOccupied,
            };
        };
        if (!preparation.sealForCommit(self))
            @panic("ended purge transport receipt seal failed after permit consume reservation");

        const outcome = self.current.client.commitEndedPurgePrepared(
            preparation.permit.generation,
            scratch,
            &preparation.inventory,
            &client_prepared,
        );
        switch (outcome) {
            .clean => {
                if (!quarantine_registry.release(&quarantine_reservation))
                    @panic("ended purge clean quarantine release failed");
            },
            .drift_pending_finalize => {
                var commit_receipt: ended_purge_quarantine.CommitReceipt = .{};
                if (!quarantine_registry.commit(&quarantine_reservation, &commit_receipt))
                    @panic("ended purge quarantine commit failed");
                var proof: ended_purge_quarantine.ConsumedCommitProof = .{};
                if (!quarantine_registry.consumeCommitted(&commit_receipt, &proof))
                    @panic("ended purge quarantine proof consume failed");
                self.current.client.finalizeEndedPurgeNoFreePoison(
                    preparation.permit.generation,
                    &client_prepared,
                    proof,
                );
                release_exclusive = false;
            },
        }
        if (!self.consumeStreamOperationPermitUnchecked(&permit_consume))
            @panic("ended purge node permit consume failed");
        preparation.consumeAfterPermit(self);
        return .purged;
    }

    fn clearStreamOperationPermit(self: *ClientSlot) void {
        self.current.active_operation_generation = 0;
        self.current.active_operation_kind = .none;
        self.current.active_operation_owner_thread_incarnation = 0;
        self.current.active_operation_owner_addr = 0;
        self.current.active_operation_transport_incarnation = 0;
        self.current.active_operation_binding = undefined;
    }

    pub fn readInitialSnapshotGuarded(
        self: *ClientSlot,
        stream_id: u64,
        owner_addr: usize,
        owner_size: usize,
        out_addr: usize,
        out_size: usize,
    ) (client_mod.ClientError || batch_registry_mod.Error || error{
        AliasedAllocation,
        InvalidDestination,
    })!InitialSnapshotRead {
        if (!self.valid()) return error.MovedOrCopied;
        if (stream_id == 0 or owner_addr == 0 or owner_size == 0 or out_addr == 0 or out_size == 0)
            return error.InvalidDestination;
        const owner_end = std.math.add(usize, owner_addr, owner_size) catch
            return error.InvalidDestination;
        const out_end = std.math.add(usize, out_addr, out_size) catch
            return error.InvalidDestination;
        var allocator_scope: client_mod.Client.GenerationAllocatorScope = .{};
        const guard = &self.current.guarded_allocator;
        if (guard.snapshot_guard_active) return error.AdminBusy;
        const scope_ranges = [_]GenerationGuardedAllocator.OperationRangeInput{
            .{
                .start = @intFromPtr(&allocator_scope),
                .len = @sizeOf(client_mod.Client.GenerationAllocatorScope),
            },
        };
        if (!guard.beginOperationGuard(&scope_ranges)) return error.AdminBusy;
        defer guard.endOperationGuard();
        guard.snapshot_owner_start = owner_addr;
        guard.snapshot_owner_end = owner_end;
        guard.snapshot_out_start = out_addr;
        guard.snapshot_out_end = out_end;
        guard.snapshot_alias_rejected = false;
        guard.snapshot_guard_active = true;
        defer {
            guard.snapshot_guard_active = false;
            guard.snapshot_owner_start = 0;
            guard.snapshot_owner_end = 0;
            guard.snapshot_out_start = 0;
            guard.snapshot_out_end = 0;
        }
        const allocator = guard.allocator();
        try self.current.client.beginGenerationAllocatorScope(
            allocator,
            .initial_snapshot,
            &allocator_scope,
        );
        defer self.current.client.restoreGenerationAllocatorScope(&allocator_scope) catch
            @panic("generation allocator scope restore drifted");
        const bytes = self.current.client.readSnapshot(stream_id) catch |err| {
            if (guard.snapshot_alias_rejected or guard.operation_alias_rejected) {
                self.current.client.poison(.local_invariant_violation);
                return error.AliasedAllocation;
            }
            return err;
        };
        if (guard.snapshot_alias_rejected or guard.operation_alias_rejected) {
            self.current.client.poison(.local_invariant_violation);
            return error.AliasedAllocation;
        }
        return .{ .bytes = bytes, .allocator = allocator };
    }

    /// Registry entry를 먼저 ingress로 고정한 뒤 Client queue/parser owner를 옮긴다.
    pub fn readAttachmentBatch(
        self: *ClientSlot,
        stream_id: u64,
    ) BatchError!AttachmentBatchRead {
        if (!self.valid()) return error.MovedOrCopied;
        if (self.current.active_operation_generation != 0) return error.AdminBusy;
        // buffered payload의 free callback에서는 allocation 없는 exact pending sibling만 허용한다.
        // miss를 parser/socket으로 내리면 parent allocator callback 안에서 wire와 allocator를 재진입한다.
        if (batch_release_callback_active)
            try self.current.client.requireBufferedGenerationBatch(stream_id);
        // allocator callback 재진입은 registry generation을 예약하기 전에 막는다. 이 순서가 뒤집히면
        // 최종 entry를 abort해도 재진입만으로 checked-monotonic generation이 소모된다.
        var allocator_scope: client_mod.Client.GenerationAllocatorScope = .{};
        const guard = &self.current.guarded_allocator;
        const scope_ranges = [_]GenerationGuardedAllocator.OperationRangeInput{
            .{
                .start = @intFromPtr(&allocator_scope),
                .len = @sizeOf(client_mod.Client.GenerationAllocatorScope),
            },
        };
        if (!guard.beginOperationGuard(&scope_ranges)) return error.AdminBusy;
        defer guard.endOperationGuard();
        try self.current.client.beginGenerationAllocatorScope(
            guard.allocator(),
            .attachment_batch,
            &allocator_scope,
        );
        defer self.current.client.restoreGenerationAllocatorScope(&allocator_scope) catch
            @panic("generation allocator scope restore drifted");
        const reservation = try self.current.batch_registry.reserve(stream_id);
        var reservation_live = true;
        defer if (reservation_live)
            self.current.batch_registry.abort(reservation) catch
                @panic("generation batch reservation rollback drifted");
        try self.current.batch_registry.prepareIngress(reservation);
        var owned: batch_registry_mod.OwnedBatch = .{};
        switch (self.current.client.readGenerationBatch(
            &owned,
            stream_id,
            reservation.entry_generation,
        ) catch |err| {
            if (guard.operation_alias_rejected) {
                self.current.client.poison(.local_invariant_violation);
                return error.ProtocolError;
            }
            return err;
        }) {
            .idle => return .idle,
            .terminal => return .terminal,
            .committed => {
                // allocator가 payload를 slot/node/stack owner와 alias하면 어느 descriptor도 안전한
                // free 권위를 증명할 수 없다. strict GUI adapter는 registry publication 전에 fail-stop한다.
                if (generationBatchOwnerAliases(self, &owned))
                    @panic("generation batch payload aliases canonical owner");
                const token = self.current.batch_registry.commitIngressUnchecked(
                    reservation,
                    &owned,
                );
                reservation_live = false;
                return .{ .committed = token };
            },
        }
    }

    pub fn borrowAttachmentBatch(
        self: *ClientSlot,
        token: batch_registry_mod.Token,
    ) batch_registry_mod.Error!batch_registry_mod.BatchView {
        if (!self.valid()) return error.MovedOrCopied;
        return self.current.batch_registry.borrow(token);
    }

    /// Accounting consume까지 callback 전에 검증한 뒤 free→consume→entry settle을 무실패로 끝낸다.
    pub fn releaseAttachmentBatch(
        self: *ClientSlot,
        token: batch_registry_mod.Token,
    ) BatchError!void {
        const operation = try self.beginRegisteredClientOperation();
        defer self.endRegisteredClientOperation(operation);
        if (!self.valid()) return error.MovedOrCopied;
        if (self.current.active_operation_generation != 0) return error.AdminBusy;
        if (batch_release_callback_active) return error.AdminBusy;
        if (self.generationAllocatorCallbackActive()) return error.AdminBusy;
        var cleanup: batch_registry_mod.OwnedBatch = .{};
        const receipt = try self.current.batch_registry.preflightRelease(token, &cleanup);
        const accounting = try self.current.client.prepareGenerationAccountingConsume(receipt);
        self.current.batch_registry.beginReleaseUnchecked(token, &cleanup);
        {
            batch_release_callback_active = true;
            defer batch_release_callback_active = false;
            cleanup.allocator.?.free(cleanup.bytes);
        }
        self.current.client.consumeGenerationAccountingUnchecked(accounting);
        cleanup.bytes = &.{};
        cleanup.allocator = null;
        cleanup.accounting = .{ .client_addr = 0, .transfer_id = 0, .byte_count = 0 };
        cleanup.completeCleanupUnchecked();
        self.current.batch_registry.finishReleaseUnchecked(token, &cleanup);
    }

    pub fn tryDeinit(self: *ClientSlot) DeinitOutcome {
        if (self.lifecycle == .dead) return .already_dead;
        if (self.lifecycle == .deinit_reserved) return .busy;
        // Teardown shares the canonical operation thread with admission. This closes the gap
        // between a registry liveness snapshot and the first node dereference without adding a
        // second cross-thread lifetime protocol. PID is checked before the process-global mutex so
        // a fork child cannot spin on a lock inherited from a vanished sibling thread.
        if (self.pid != currentPid() or
            !operationThreadMatches(self.operation_owner_thread_incarnation)) return .corrupt;
        const reserved_registry_entry = self.beginRegisteredExclusiveTeardown() catch |err|
            return switch (err) {
                error.AdminBusy => .busy,
                error.MovedOrCopied => .corrupt,
            };
        var exclusive_reserved = true;
        defer if (exclusive_reserved)
            self.abortRegisteredExclusiveTeardown(reserved_registry_entry);
        const node = reserved_registry_entry.node;
        if (!self.valid()) return if (self.lifecycle == .deinit_reserved) .busy else .corrupt;
        if (batch_release_callback_active) return .busy;
        if (self.generationAllocatorCallbackActive()) return .busy;
        if (node.active_operation_generation != 0) return .busy;
        if (!node.rpc_free_evidence.emptyExact()) return .busy;
        if (node.pin_owner.cleanup_pin_count != 0 or
            node.pin_owner.active_cleanup != 0)
            return .busy;
        // 두 registry 중 하나를 먼저 dead로 만든 뒤 다른 쪽 busy/corrupt를 발견하면 재시도할 수 없다.
        // 둘의 전체 entry를 먼저 검증한 뒤에만 mutation suffix에 들어간다.
        const cleanup_ready = node.cleanup_registry.preflightDeinit();
        const batch_ready = node.batch_registry.preflightDeinit();
        const accounting_ready = node.accounting_ledger.preflightDeinit();
        if (cleanup_ready == .busy or batch_ready == .busy or accounting_ready == .busy)
            return .busy;
        if (cleanup_ready != .cleaned or batch_ready != .cleaned or accounting_ready != .cleaned)
            return .corrupt;
        // Client teardown owns the cross-thread operation fence. It must succeed before any slot
        // registry becomes terminal; otherwise a concurrent shared Client operation would make
        // tryDeinit return false and freeing the node would turn that retry signal into a UAF.
        if (!node.client.tryDeinitClientSlotExclusiveHeld()) return .busy;
        exclusive_reserved = false;
        switch (node.cleanup_registry.tryDeinit()) {
            .cleaned => {},
            .busy, .corrupt, .already_dead => @panic("fenced ClientSlot cleanup registry teardown drifted"),
        }
        switch (node.batch_registry.tryDeinit()) {
            .cleaned => {},
            .busy, .corrupt, .already_dead => @panic("fenced ClientSlot batch registry teardown drifted"),
        }
        self.lifecycle = .deinit_reserved;
        if (!unregisterClientSlot(reserved_registry_entry.registry_entry))
            @panic("preflighted ClientSlot registry teardown drifted");
        node.pin_owner.state = .terminal;
        switch (node.accounting_ledger.tryDeinit()) {
            .cleaned => {},
            .busy, .corrupt, .already_dead => @panic("preflighted generation accounting teardown drifted"),
        }
        self.node_allocator.destroy(node);
        self.lifecycle = .dead;
        return .cleaned;
    }

    pub fn deinit(self: *ClientSlot) void {
        if (self.tryDeinit() != .cleaned)
            @panic("session-host ClientSlot teardown invariant violated");
    }
};

test "CR3a-2a ClientSlot teardown waits for node-local attachment reservations" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xAC);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xAC);

    const reserved = try slot.current.cleanup_registry.reserve(.{
        .binding_incarnation = 101,
        .binding_storage_addr = @intFromPtr(&slot),
        .destination_addr = @intFromPtr(&slot),
        .slot_incarnation = slot.incarnation.tagged,
        .node_incarnation = slot.current.incarnation.tagged,
        .host_id = 0xAC,
        .connection_generation = 1,
        .runtime_id = 0xBD,
        .role = .controller,
        .pid = slot.pid,
        .process_nonce = slot.process_nonce,
    });
    try std.testing.expectEqual(DeinitOutcome.busy, slot.tryDeinit());
    try slot.current.cleanup_registry.abort(reserved.reservation, reserved.identity);
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a B3b-F ClientSlot preserves its node when Client teardown is busy" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Runner = struct {
        fn run(client: *client_mod.Client) void {
            if (client.call("host.info", null)) |response|
                client.allocator.free(response)
            else |_| {}
        }
    };

    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
    );
    var peer_live = true;
    defer {
        if (peer_live) _ = c.close(fds[1]);
    }
    var source = fixtureClient(allocator, 0xAD);
    source.fd = fds[0];
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xAD);

    const thread = try std.Thread.spawn(.{}, Runner.run, .{&slot.current.client});
    var ready = c.pollfd{ .fd = fds[1], .events = c.POLL.IN, .revents = 0 };
    try std.testing.expect(c.poll(@ptrCast(&ready), 1, 1_000) > 0);
    try std.testing.expect(ready.revents & c.POLL.IN != 0);
    try std.testing.expectEqual(DeinitOutcome.busy, slot.tryDeinit());
    try std.testing.expect(slot.valid());
    try std.testing.expect(clientSlotRegistryEntry(@intFromPtr(&slot)) != null);

    _ = c.close(fds[1]);
    peer_live = false;
    thread.join();
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a B3b-F allocator callback permit rejection does not intrude on exclusive teardown" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xAE);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xAE);

    try slot.current.client.tryAcquireEndedPurgeExclusive();
    try std.testing.expect(slot.current.client.enterGenerationAllocatorCallback());
    try std.testing.expectError(
        error.AdminBusy,
        slot.prepareStreamOperationPermit(.initial_snapshot, 1, 1, std.mem.zeroes(contract.BindingIdentity)),
    );
    slot.current.client.leaveGenerationAllocatorCallbackUnchecked();
    try std.testing.expect(!slot.current.client.endedPurgeFenceIntruded());
    try std.testing.expect(slot.current.client.releaseEndedPurgeExclusiveClean());
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2b1 ClientSlot은 buffered batch owner와 accounting을 exact release한다" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xB201);
    const bytes = try allocator.dupe(u8, "generation-batch");
    try source.pending_batches.append(allocator, .{
        .is_snapshot = true,
        .stream_id = 7,
        .bytes = bytes,
        .allocator = allocator,
    });
    source.pending_batch_bytes = bytes.len;

    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB201);
    const read = try slot.readAttachmentBatch(7);
    const token = switch (read) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };
    const view = try slot.borrowAttachmentBatch(token);
    try std.testing.expect(view.is_snapshot);
    try std.testing.expectEqualStrings("generation-batch", view.bytes);
    try std.testing.expectEqual(@as(usize, 1), slot.current.accounting_ledger.item_count);
    try std.testing.expectEqual(bytes.len, slot.current.accounting_ledger.byte_count);
    try std.testing.expectEqual(@as(usize, 1), try slot.current.batch_registry.count());
    try std.testing.expectEqual(DeinitOutcome.busy, slot.tryDeinit());

    try slot.releaseAttachmentBatch(token);
    try std.testing.expectEqual(@as(usize, 0), slot.current.accounting_ledger.item_count);
    try std.testing.expectEqual(@as(usize, 0), slot.current.accounting_ledger.byte_count);
    try std.testing.expectEqual(@as(usize, 0), try slot.current.batch_registry.count());
    try std.testing.expectError(error.InvalidReservation, slot.borrowAttachmentBatch(token));
    try std.testing.expectError(error.InvalidReservation, slot.releaseAttachmentBatch(token));
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2b1 ClientSlot batch token은 stream splice를 free 전에 거부한다" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xB202);
    const bytes = try allocator.dupe(u8, "owned");
    try source.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 11,
        .bytes = bytes,
        .allocator = allocator,
    });
    source.pending_batch_bytes = bytes.len;

    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB202);
    const token = switch (try slot.readAttachmentBatch(11)) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };
    var spliced = token;
    spliced.stream_id = 12;
    try std.testing.expectError(error.InvalidReservation, slot.releaseAttachmentBatch(spliced));
    try std.testing.expectEqual(@as(usize, 1), slot.current.accounting_ledger.item_count);
    try std.testing.expectEqual(bytes.len, slot.current.accounting_ledger.byte_count);
    try std.testing.expectEqualStrings("owned", (try slot.borrowAttachmentBatch(token)).bytes);

    try slot.releaseAttachmentBatch(token);
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2b1 ClientSlot polling idle은 4096회 뒤에도 registry cap을 소비하지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var source = fixtureClient(allocator, 0xB204);
    source.fd = fds[0];
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB204);

    try std.testing.expectEqual(ClientSlot.AttachmentBatchRead.idle, try slot.readAttachmentBatch(17));
    try std.testing.expectEqual(@as(usize, 0), try slot.current.batch_registry.count());
    for (1..4096) |_| {
        try std.testing.expectEqual(ClientSlot.AttachmentBatchRead.idle, try slot.readAttachmentBatch(17));
    }
    try std.testing.expectEqual(@as(usize, 0), try slot.current.batch_registry.count());

    const bytes = try allocator.dupe(u8, "after-idle");
    try slot.current.client.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 17,
        .bytes = bytes,
        .allocator = allocator,
    });
    slot.current.client.pending_batch_bytes = bytes.len;
    const token = switch (try slot.readAttachmentBatch(17)) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), try slot.current.batch_registry.count());
    try slot.releaseAttachmentBatch(token);
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2b1 batch와 stream-drop registry는 동시에 각각 4096 entry를 소유한다" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xB205);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB205);
    var batch_reservations: [batch_registry_mod.max_entries]batch_registry_mod.Reservation = undefined;
    var drop_reservations: [cleanup_registry_mod.max_entries]cleanup_registry_mod.Reserved = undefined;
    for (&batch_reservations, &drop_reservations, 0..) |*batch, *drop, index| {
        batch.* = try slot.current.batch_registry.reserve(index + 1);
        drop.* = try slot.current.cleanup_registry.reserve(.{
            .binding_incarnation = index + 1,
            .binding_storage_addr = index + 1,
            .destination_addr = index + 1,
            .slot_incarnation = slot.incarnation.tagged,
            .node_incarnation = slot.current.incarnation.tagged,
            .host_id = 0xB205,
            .connection_generation = 1,
            .runtime_id = index + 1,
            .role = .controller,
            .pid = slot.pid,
            .process_nonce = slot.process_nonce,
        });
    }
    try std.testing.expectEqual(batch_registry_mod.max_entries, try slot.current.batch_registry.count());
    try std.testing.expectEqual(cleanup_registry_mod.max_entries, try slot.current.cleanup_registry.count());
    try std.testing.expectError(error.CapacityExhausted, slot.current.batch_registry.reserve(5000));
    try std.testing.expectError(error.CapacityExhausted, slot.current.cleanup_registry.reserve(.{
        .binding_incarnation = 5000,
        .binding_storage_addr = 5000,
        .destination_addr = 5000,
        .slot_incarnation = slot.incarnation.tagged,
        .node_incarnation = slot.current.incarnation.tagged,
        .host_id = 0xB205,
        .connection_generation = 1,
        .runtime_id = 5000,
        .role = .controller,
        .pid = slot.pid,
        .process_nonce = slot.process_nonce,
    }));
    for (batch_reservations, drop_reservations) |batch, drop| {
        try slot.current.batch_registry.abort(batch);
        try slot.current.cleanup_registry.abort(drop.reservation, drop.identity);
    }
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2b1 payload alias preflight는 slot node와 callback-local owner range를 닫는다" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xB206);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB206);
    defer slot.deinit();
    var owned: batch_registry_mod.OwnedBatch = .{};
    owned.bytes = std.mem.asBytes(&slot)[0..1];
    try std.testing.expect(generationBatchOwnerAliases(&slot, &owned));
    owned.bytes = std.mem.asBytes(slot.current)[0..1];
    try std.testing.expect(generationBatchOwnerAliases(&slot, &owned));
    owned.bytes = std.mem.asBytes(&owned)[0..1];
    try std.testing.expect(generationBatchOwnerAliases(&slot, &owned));
    const separate = "separate";
    owned.bytes = @constCast(separate);
    try std.testing.expect(!generationBatchOwnerAliases(&slot, &owned));
}

test "CR3a-2b1 ClientNode move는 overlapping pending payload owner를 거부한다" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xB207);
    const bytes = try allocator.dupe(u8, "aliased");
    for ([_]u64{ 7, 8 }) |stream_id|
        try source.pending_batches.append(allocator, .{
            .is_snapshot = false,
            .stream_id = stream_id,
            .bytes = bytes,
            .allocator = allocator,
        });
    source.pending_batch_bytes = bytes.len * 2;
    var slot: ClientSlot = undefined;
    try std.testing.expectError(
        error.InvalidSource,
        ClientSlot.initInPlace(&slot, allocator, &source, 0xB207),
    );
    const alias = source.pending_batches.orderedRemove(1);
    _ = alias;
    source.pending_batch_bytes -= bytes.len;
    source.deinit();
}

const BatchFreeProbe = struct {
    parent: std.mem.Allocator,
    slot: ?*ClientSlot = null,
    observed_items_before_reentry: usize = 0,
    deinit_outcome: ?DeinitOutcome = null,
    sibling_token: ?batch_registry_mod.Token = null,
    reentry_error: ?anyerror = null,

    fn allocator(self: *BatchFreeProbe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *BatchFreeProbe = @ptrCast(@alignCast(context));
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *BatchFreeProbe = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *BatchFreeProbe = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *BatchFreeProbe = @ptrCast(@alignCast(context));
        if (self.slot) |slot| {
            self.observed_items_before_reentry = slot.current.accounting_ledger.item_count;
            self.deinit_outcome = slot.tryDeinit();
            const result = slot.readAttachmentBatch(12) catch |err| {
                self.reentry_error = err;
                self.parent.vtable.free(
                    self.parent.ptr,
                    memory,
                    alignment,
                    return_address,
                );
                return;
            };
            switch (result) {
                .committed => |token| self.sibling_token = token,
                else => self.reentry_error = error.TestUnexpectedResult,
            }
            self.slot = null;
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, return_address);
    }
};

test "CR3a-2b1 release allocator callback 동안 charge를 유지하고 sibling admission을 허용한다" {
    const allocator = std.testing.allocator;
    var probe: BatchFreeProbe = .{ .parent = allocator };
    var source = fixtureClient(allocator, 0xB203);
    const first = try probe.allocator().dupe(u8, "first");
    const sibling = try allocator.dupe(u8, "sibling");
    try source.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 11,
        .bytes = first,
        .allocator = probe.allocator(),
    });
    try source.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 12,
        .bytes = sibling,
        .allocator = allocator,
    });
    source.pending_batch_bytes = first.len + sibling.len;

    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB203);
    const first_token = switch (try slot.readAttachmentBatch(11)) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };
    probe.slot = &slot;
    try slot.releaseAttachmentBatch(first_token);
    try std.testing.expectEqual(@as(usize, 1), probe.observed_items_before_reentry);
    try std.testing.expectEqual(DeinitOutcome.busy, probe.deinit_outcome.?);
    try std.testing.expect(probe.reentry_error == null);
    const sibling_token = probe.sibling_token orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), slot.current.accounting_ledger.item_count);
    try std.testing.expectEqualStrings("sibling", (try slot.borrowAttachmentBatch(sibling_token)).bytes);
    try slot.releaseAttachmentBatch(sibling_token);
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

const GenerationAllocatorReentryProbe = struct {
    parent: std.mem.Allocator,
    same: ?*ClientSlot = null,
    foreign: ?*ClientSlot = null,
    same_token: ?batch_registry_mod.Token = null,
    foreign_token: ?batch_registry_mod.Token = null,
    deinit_target: ?*ClientSlot = null,
    release_mode: bool = false,
    armed: bool = false,
    fired: bool = false,
    same_error: ?anyerror = null,
    foreign_error: ?anyerror = null,
    same_direct_read_error: ?anyerror = null,
    foreign_direct_read_error: ?anyerror = null,
    deinit_outcome: ?DeinitOutcome = null,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn attemptReentry(self: *@This()) void {
        if (!self.armed or self.fired) return;
        self.fired = true;
        if (self.release_mode) {
            self.same.?.releaseAttachmentBatch(self.same_token.?) catch |err| {
                self.same_error = err;
            };
            self.foreign.?.releaseAttachmentBatch(self.foreign_token.?) catch |err| {
                self.foreign_error = err;
            };
            _ = self.same.?.readAttachmentBatch(91) catch |err| {
                self.same_direct_read_error = err;
            };
            _ = self.foreign.?.readAttachmentBatch(92) catch |err| {
                self.foreign_direct_read_error = err;
            };
            self.deinit_outcome = self.deinit_target.?.tryDeinit();
            return;
        }
        _ = self.same.?.readAttachmentBatch(91) catch |err| {
            self.same_error = err;
        };
        _ = self.foreign.?.readAttachmentBatch(92) catch |err| {
            self.foreign_error = err;
        };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.attemptReentry();
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.attemptReentry();
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.attemptReentry();
        return self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.attemptReentry();
        self.parent.vtable.free(self.parent.ptr, memory, alignment, return_address);
    }
};

const SnapshotOwnerAliasAllocator = struct {
    target: []u8,
    alloc_calls: usize = 0,
    free_calls: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        _ = return_address;
        const self: *@This() = @ptrCast(@alignCast(context));
        self.alloc_calls += 1;
        if (len > self.target.len or !alignment.check(@intFromPtr(self.target.ptr))) return null;
        return self.target.ptr;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = return_address;
        return false;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = return_address;
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        _ = memory;
        _ = alignment;
        _ = return_address;
        const self: *@This() = @ptrCast(@alignCast(context));
        self.free_calls += 1;
    }
};

const ScopeTokenAliasAllocator = struct {
    client: *client_mod.Client,
    offset: usize,
    alloc_calls: usize = 0,
    free_calls: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        _ = len;
        _ = return_address;
        const self: *@This() = @ptrCast(@alignCast(context));
        self.alloc_calls += 1;
        const active = self.client.active_generation_allocator_scope orelse return null;
        const target = std.math.add(usize, active.token_addr, self.offset) catch return null;
        if (!alignment.check(target)) return null;
        return @ptrFromInt(target);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = return_address;
        return false;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = return_address;
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        _ = memory;
        _ = alignment;
        _ = return_address;
        const self: *@This() = @ptrCast(@alignCast(context));
        self.free_calls += 1;
    }
};

test "CR3a-2c1 snapshot allocation rejects owner alias before the first payload write" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xB20B);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB20B);
    defer slot.deinit();

    const wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .snapshot_chunk, .stream_id = 7, .flags = protocol.Flags.end_stream },
        "snapshot-payload",
    );
    defer allocator.free(wire);
    try slot.current.client.parser.push(wire);

    var owner_storage: [256]u8 align(16) = [_]u8{0xA5} ** 256;
    var hostile = SnapshotOwnerAliasAllocator{ .target = owner_storage[0..] };
    slot.current.guarded_allocator.parent = hostile.allocator();
    try std.testing.expectError(
        error.AliasedAllocation,
        slot.readInitialSnapshotGuarded(
            7,
            @intFromPtr(&owner_storage),
            owner_storage.len,
            @intFromPtr(&owner_storage),
            owner_storage.len,
        ),
    );
    try std.testing.expect(hostile.alloc_calls > 0);
    try std.testing.expectEqual(@as(usize, 0), hostile.free_calls);
    for (owner_storage) |byte| try std.testing.expectEqual(@as(u8, 0xA5), byte);
    try std.testing.expect(slot.current.client.unusable);
}

test "CR3a-2c3b snapshot allocator rejects exact and partial scope-token aliases" {
    inline for ([_]usize{ 0, @alignOf(client_mod.Client.GenerationAllocatorScope) }) |offset| {
        const allocator = std.testing.allocator;
        var source = fixtureClient(allocator, 0x2C3B20 + offset);
        var slot: ClientSlot = undefined;
        try ClientSlot.initInPlace(&slot, allocator, &source, 0x2C3B20 + offset);
        defer slot.deinit();
        const wire = try framing.encodeFrame(
            allocator,
            .{ .kind = .snapshot_chunk, .stream_id = 7, .flags = protocol.Flags.end_stream },
            "scope-token-snapshot",
        );
        defer allocator.free(wire);
        try slot.current.client.parser.push(wire);
        var probe = ScopeTokenAliasAllocator{ .client = &slot.current.client, .offset = offset };
        slot.current.guarded_allocator.parent = probe.allocator();
        var owner_storage: [256]u8 align(16) = undefined;
        try std.testing.expectError(error.AliasedAllocation, slot.readInitialSnapshotGuarded(
            7,
            @intFromPtr(&owner_storage),
            owner_storage.len,
            @intFromPtr(&owner_storage),
            owner_storage.len,
        ));
        try std.testing.expect(probe.alloc_calls > 0);
        try std.testing.expectEqual(@as(usize, 0), probe.free_calls);
        try std.testing.expect(slot.current.client.unusable);
    }
}

test "CR3a-2c3b attachment batch allocator rejects scope-token and parser backing aliases" {
    const Case = enum { token_exact, token_partial, parser_backing };
    inline for (std.enums.values(Case)) |case| {
        const allocator = std.testing.allocator;
        const case_offset: u128 = @intFromEnum(case);
        var source = fixtureClient(allocator, 0x2C3B30 + case_offset);
        var slot: ClientSlot = undefined;
        try ClientSlot.initInPlace(&slot, allocator, &source, 0x2C3B30 + case_offset);
        defer slot.deinit();
        const wire = try framing.encodeFrame(
            allocator,
            .{ .kind = .delta_chunk, .stream_id = 7, .flags = protocol.Flags.end_stream },
            "scope-token-batch",
        );
        defer allocator.free(wire);
        try slot.current.client.parser.push(wire);

        var token_probe = ScopeTokenAliasAllocator{
            .client = &slot.current.client,
            .offset = if (case == .token_partial)
                @alignOf(client_mod.Client.GenerationAllocatorScope)
            else
                0,
        };
        var backing_probe = SnapshotOwnerAliasAllocator{
            .target = slot.current.client.parser.buf.items,
        };
        slot.current.guarded_allocator.parent = if (case == .parser_backing)
            backing_probe.allocator()
        else
            token_probe.allocator();
        try std.testing.expectError(error.ProtocolError, slot.readAttachmentBatch(7));
        if (case == .parser_backing) {
            try std.testing.expect(backing_probe.alloc_calls > 0);
            try std.testing.expectEqual(@as(usize, 0), backing_probe.free_calls);
        } else {
            try std.testing.expect(token_probe.alloc_calls > 0);
            try std.testing.expectEqual(@as(usize, 0), token_probe.free_calls);
        }
        try std.testing.expect(slot.current.client.unusable);
    }
}

test "CR3a-2b1 parser allocator callback은 same과 foreign ClientSlot mutation을 wire 전에 거부한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var probe: GenerationAllocatorReentryProbe = .{ .parent = allocator };
    const checked_allocator = probe.allocator();
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);

    var source = fixtureClient(checked_allocator, 0xB208);
    source.fd = fds[0];
    const same_sibling_bytes = try allocator.dupe(u8, "same-sibling");
    try source.pending_batches.append(checked_allocator, .{
        .is_snapshot = false,
        .stream_id = 8,
        .bytes = same_sibling_bytes,
        .allocator = allocator,
    });
    source.pending_batch_bytes = same_sibling_bytes.len;
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, checked_allocator, &source, 0xB208);
    var foreign_source = fixtureClient(allocator, 0xB209);
    const foreign_sibling_bytes = try allocator.dupe(u8, "foreign-sibling");
    try foreign_source.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 9,
        .bytes = foreign_sibling_bytes,
        .allocator = allocator,
    });
    foreign_source.pending_batch_bytes = foreign_sibling_bytes.len;
    var foreign: ClientSlot = undefined;
    try ClientSlot.initInPlace(&foreign, allocator, &foreign_source, 0xB209);
    defer foreign.deinit();
    var deinit_source = fixtureClient(allocator, 0xB20A);
    var deinit_target: ClientSlot = undefined;
    try ClientSlot.initInPlace(&deinit_target, allocator, &deinit_source, 0xB20A);
    probe.same = &slot;
    probe.foreign = &foreign;
    probe.deinit_target = &deinit_target;
    probe.same_token = switch (try slot.readAttachmentBatch(8)) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };
    probe.foreign_token = switch (try foreign.readAttachmentBatch(9)) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };

    const wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .delta_chunk, .stream_id = 7, .flags = protocol.Flags.end_stream },
        "guarded-direct",
    );
    defer allocator.free(wire);
    try socket_server.writeAll(fds[1], wire);
    probe.armed = true;
    const token = switch (try slot.readAttachmentBatch(7)) {
        .committed => |token| token,
        else => return error.TestUnexpectedResult,
    };
    probe.armed = false;

    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(error.AdminBusy, probe.same_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.foreign_error.?);
    try std.testing.expectEqual(@as(u64, 2), slot.current.batch_registry.last_generation);
    try std.testing.expectEqual(@as(u64, 1), foreign.current.batch_registry.last_generation);
    try std.testing.expectEqual(@as(usize, 2), try slot.current.batch_registry.count());
    try std.testing.expectEqual(@as(usize, 1), try foreign.current.batch_registry.count());
    try std.testing.expectEqual(@as(usize, 0), foreign.current.client.pending_batches.items.len);
    try std.testing.expect(std.meta.eql(checked_allocator, slot.current.client.allocator));
    try std.testing.expect(slot.current.client.parser.usesAllocator(checked_allocator));
    try std.testing.expectEqualStrings("guarded-direct", (try slot.borrowAttachmentBatch(token)).bytes);
    var restored_rpc: client_mod.PreparedBlockingRpcStorage = .{};
    _ = try slot.current.client.prepareBlockingRpcStorage(&restored_rpc, "host.info", null);
    try slot.current.client.abortPreparedBlockingRpcStorage(&restored_rpc);
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(&restored_rpc));

    probe.fired = false;
    probe.same_error = null;
    probe.foreign_error = null;
    probe.release_mode = true;
    probe.armed = true;
    try slot.releaseAttachmentBatch(token);
    probe.armed = false;
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(error.AdminBusy, probe.same_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.foreign_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.same_direct_read_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.foreign_direct_read_error.?);
    try std.testing.expectEqual(DeinitOutcome.busy, probe.deinit_outcome.?);
    try std.testing.expectEqual(@as(u64, 2), slot.current.batch_registry.last_generation);
    try std.testing.expectEqual(@as(u64, 1), foreign.current.batch_registry.last_generation);
    try std.testing.expectEqual(@as(usize, 1), try slot.current.batch_registry.count());
    try std.testing.expectEqual(@as(usize, 1), try foreign.current.batch_registry.count());
    try std.testing.expectEqualStrings(
        "same-sibling",
        (try slot.borrowAttachmentBatch(probe.same_token.?)).bytes,
    );
    try std.testing.expectEqualStrings(
        "foreign-sibling",
        (try foreign.borrowAttachmentBatch(probe.foreign_token.?)).bytes,
    );

    const buffered_outer_bytes = try probe.allocator().dupe(u8, "buffered-outer");
    try slot.current.client.pending_batches.append(checked_allocator, .{
        .is_snapshot = false,
        .stream_id = 10,
        .bytes = buffered_outer_bytes,
        .allocator = probe.allocator(),
    });
    slot.current.client.pending_batch_bytes += buffered_outer_bytes.len;
    const buffered_token = switch (try slot.readAttachmentBatch(10)) {
        .committed => |buffered| buffered,
        else => return error.TestUnexpectedResult,
    };
    probe.fired = false;
    probe.same_error = null;
    probe.foreign_error = null;
    probe.same_direct_read_error = null;
    probe.foreign_direct_read_error = null;
    probe.deinit_outcome = null;
    const buffered_followup_wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .delta_chunk, .stream_id = 91, .flags = protocol.Flags.end_stream },
        "after-buffered-callback",
    );
    defer allocator.free(buffered_followup_wire);
    try socket_server.writeAll(fds[1], buffered_followup_wire);
    probe.armed = true;
    try slot.releaseAttachmentBatch(buffered_token);
    probe.armed = false;
    try std.testing.expect(probe.fired);
    try std.testing.expectEqual(error.AdminBusy, probe.same_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.foreign_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.same_direct_read_error.?);
    try std.testing.expectEqual(error.AdminBusy, probe.foreign_direct_read_error.?);
    try std.testing.expectEqual(DeinitOutcome.busy, probe.deinit_outcome.?);
    try std.testing.expectEqual(@as(u64, 3), slot.current.batch_registry.last_generation);
    try std.testing.expectEqual(@as(u64, 1), foreign.current.batch_registry.last_generation);
    try std.testing.expectEqual(@as(usize, 1), try slot.current.batch_registry.count());
    try std.testing.expectEqual(@as(usize, 1), try foreign.current.batch_registry.count());
    try std.testing.expectEqualStrings(
        "same-sibling",
        (try slot.borrowAttachmentBatch(probe.same_token.?)).bytes,
    );
    try std.testing.expectEqualStrings(
        "foreign-sibling",
        (try foreign.borrowAttachmentBatch(probe.foreign_token.?)).bytes,
    );
    const followup_token = switch (try slot.readAttachmentBatch(91)) {
        .committed => |followup| followup,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(
        "after-buffered-callback",
        (try slot.borrowAttachmentBatch(followup_token)).bytes,
    );
    try slot.releaseAttachmentBatch(followup_token);
    try slot.releaseAttachmentBatch(probe.same_token.?);
    try foreign.releaseAttachmentBatch(probe.foreign_token.?);
    try std.testing.expectEqual(DeinitOutcome.cleaned, deinit_target.tryDeinit());
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2a ClientSlot transfers pre-reserved pin through attach drop and lease release" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xCA);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xCA);

    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBinding(
        &binding,
        &lease,
        0xDB,
        .controller,
    );
    try std.testing.expectEqual(@as(usize, 1), slot.current.pin_owner.cleanup_pin_count);
    const prepared = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 211,
        .request_id = 223,
        .request_digest = 227,
    }).?;
    try binding.pairRequest(prepared);
    try binding.beginExecute(prepared);
    const executed = contract.ExecutedCallReceipt.fromPrepared(prepared).?;
    const accepted = contract.CorrelatedExecutedCall.init(executed, prepared.request_id).?;
    try slot.commitAttachmentBinding(&binding, reservation, accepted, 229, &lease);
    try std.testing.expectEqual(contract.BindingLifecycle.committed, binding.lifecycle);
    try std.testing.expectEqual(@as(usize, 1), slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 1), try slot.current.cleanup_registry.count());

    var foreign = reservation;
    foreign.cleanup.reservation_id += 1;
    try std.testing.expectError(
        error.InvalidReservation,
        slot.beginAttachmentDrop(&binding, foreign, &lease),
    );
    try std.testing.expectEqual(contract.BindingLifecycle.committed, binding.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), slot.current.pin_owner.active_cleanup);
    try std.testing.expectEqual(@as(usize, 1), slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expect(lease.canRelease(slot.pid));

    try slot.beginAttachmentDrop(&binding, reservation, &lease);
    slot.finishActiveAttachmentDrop(&binding, reservation, &lease);
    try std.testing.expectEqual(contract.BindingLifecycle.terminal, binding.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), try slot.current.cleanup_registry.count());
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2a rejected attach aborts pre-reserved pin and drop entry exactly once" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xEA);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xEA);

    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBinding(&binding, &lease, 0xFB, .controller);
    const prepared = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 233,
        .request_id = 239,
        .request_digest = 241,
    }).?;
    try binding.pairRequest(prepared);
    try slot.abortAttachmentBinding(&binding, reservation);
    try std.testing.expectEqual(contract.BindingLifecycle.terminal, binding.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), try slot.current.cleanup_registry.count());
    try std.testing.expectError(
        error.InvalidState,
        slot.abortAttachmentBinding(&binding, reservation),
    );
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "CR3a-2a binding reservation rejects lease and canonical owner aliases without mutation" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xFC);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xFC);
    defer slot.deinit();

    const Shared = union {
        binding: contract.PreparedAttachmentBinding,
        lease: lease_mod.ConnectionLease,
    };
    var shared: Shared = .{ .binding = .{} };
    const binding: *contract.PreparedAttachmentBinding = @ptrCast(&shared);
    const lease: *lease_mod.ConnectionLease = @ptrCast(&shared);
    try std.testing.expectError(
        error.InvalidIdentity,
        slot.reserveAttachmentBinding(binding, lease, 0xFD, .controller),
    );
    try std.testing.expectEqual(@as(usize, 0), slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), try slot.current.cleanup_registry.count());

    var clean_binding: contract.PreparedAttachmentBinding = .{};
    const owner_lease: *lease_mod.ConnectionLease = @ptrCast(@alignCast(&slot.current.pin_owner));
    try std.testing.expectError(
        error.InvalidIdentity,
        slot.reserveAttachmentBinding(&clean_binding, owner_lease, 0xFE, .controller),
    );
    try std.testing.expectEqual(contract.BindingLifecycle.pristine, clean_binding.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), try slot.current.cleanup_registry.count());
}

fn fixtureClient(allocator: std.mem.Allocator, host_id: u128) client_mod.Client {
    return .{
        .allocator = allocator,
        .fd = -1,
        .host_id = host_id,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
}

const B33DestinationOccupyingAllocator = struct {
    parent: std.mem.Allocator,
    target_addr: usize = 0,
    target_len: usize = 0,
    destination: ?*RpcExecutedResponse = null,
    armed: bool = false,
    fired: bool = false,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ra);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ra);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ra);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.armed and @intFromPtr(memory.ptr) == self.target_addr and memory.len == self.target_len) {
            const destination = self.destination orelse @panic("B3-3 destination callback missing");
            destination.* = .{
                .self_addr = @intFromPtr(destination),
                .owner_incarnation = 0xA5,
            };
            self.fired = true;
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ra);
    }
};

const ReentrantNodeAllocator = struct {
    parent: std.mem.Allocator,
    issuer: ?*lease_mod.IdentityIssuer = null,
    nested_source: ?*client_mod.Client = null,
    nested_slot: ?*ClientSlot = null,
    outer_slot: ?*ClientSlot = null,
    alloc_reentry_fired: bool = false,
    alloc_reentry_rejected: bool = false,
    free_reentry_fired: bool = false,
    free_reentry_outcome: ?DeinitOutcome = null,

    fn allocator(self: *ReentrantNodeAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ReentrantNodeAllocator = @ptrCast(@alignCast(context));
        if (!self.alloc_reentry_fired and self.issuer != null and
            self.nested_source != null and self.nested_slot != null)
        {
            self.alloc_reentry_fired = true;
            ClientSlot.initInPlaceWithIssuer(
                self.nested_slot.?,
                self.allocator(),
                self.nested_source.?,
                self.nested_source.?.host_id,
                self.issuer.?,
                currentPid(),
            ) catch |err| {
                self.alloc_reentry_rejected = err == error.ReentrantInit;
            };
        }
        return self.parent.vtable.alloc(
            self.parent.ptr,
            len,
            alignment,
            return_address,
        );
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *ReentrantNodeAllocator = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ReentrantNodeAllocator = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *ReentrantNodeAllocator = @ptrCast(@alignCast(context));
        if (!self.free_reentry_fired) {
            self.free_reentry_fired = true;
            if (self.outer_slot) |slot| self.free_reentry_outcome = slot.tryDeinit();
        }
        self.parent.vtable.free(
            self.parent.ptr,
            memory,
            alignment,
            return_address,
        );
    }
};

test "client slot moves production Client into a heap-pinned generation-1 node" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 77);
    var source = fixtureClient(std.testing.allocator, 0xAA);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        std.testing.allocator,
        &source,
        0xAA,
        &issuer,
        currentPid(),
    );
    defer slot.deinit();
    try std.testing.expect(slot.valid());
    try std.testing.expectEqual(@as(u128, 0xAA), slot.logicalClient().host_id);
    try std.testing.expect(source.tryDeinit());
    try std.testing.expectEqual(lease_mod.IdentityKind.slot, slot.incarnation.kind());
    try std.testing.expectEqual(lease_mod.IdentityKind.node, slot.current.incarnation.kind());
}

test "client slot failure preserves source and burns identities" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 88);
    var source = fixtureClient(std.testing.allocator, 0xBB);
    defer source.deinit();
    var slot: ClientSlot = undefined;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        ClientSlot.initInPlaceWithIssuer(
            &slot,
            failing.allocator(),
            &source,
            0xBB,
            &issuer,
            currentPid(),
        ),
    );
    try std.testing.expectEqual(@as(u128, 0xBB), source.host_id);
    try std.testing.expect(source.canMoveToGenerationNode());
    try std.testing.expectEqual(@as(u64, 3), issuer.next_ordinal.load(.acquire));
}

test "client slot rejects cross-process domain before allocation or source move" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid() + 1, 99);
    var source = fixtureClient(std.testing.allocator, 0xCC);
    defer source.deinit();
    var slot: ClientSlot = undefined;
    try std.testing.expectError(
        error.ProcessDomainMismatch,
        ClientSlot.initInPlaceWithIssuer(
            &slot,
            std.testing.allocator,
            &source,
            0xCC,
            &issuer,
            currentPid(),
        ),
    );
    try std.testing.expect(source.canMoveToGenerationNode());
}

test "client slot same-address reincarnation changes both slot and node identity" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 101);
    var node_bytes: [@sizeOf(ClientNode) + @alignOf(ClientNode)]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&node_bytes);
    var slot: ClientSlot = undefined;

    var first_source = fixtureClient(std.testing.allocator, 0xD1);
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        fixed.allocator(),
        &first_source,
        0xD1,
        &issuer,
        currentPid(),
    );
    const first_slot_identity = slot.incarnation.tagged;
    const first_node_identity = slot.current.incarnation.tagged;
    const first_node_addr = @intFromPtr(slot.current);
    slot.deinit();
    fixed.reset();

    var second_source = fixtureClient(std.testing.allocator, 0xD2);
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        fixed.allocator(),
        &second_source,
        0xD2,
        &issuer,
        currentPid(),
    );
    defer slot.deinit();
    try std.testing.expectEqual(first_node_addr, @intFromPtr(slot.current));
    try std.testing.expect(slot.incarnation.tagged != first_slot_identity);
    try std.testing.expect(slot.current.incarnation.tagged != first_node_identity);
}

test "client slot teardown is busy while an exact cleanup lease pins its node" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 102);
    var source = fixtureClient(std.testing.allocator, 0xD3);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        std.testing.allocator,
        &source,
        0xD3,
        &issuer,
        currentPid(),
    );
    var lease: lease_mod.ConnectionLease = .{};
    try lease_mod.ConnectionLease.initInPlace(
        &lease,
        &slot.current.pin_owner,
        9,
        currentPid(),
    );
    try std.testing.expectEqual(DeinitOutcome.busy, slot.tryDeinit());
    try std.testing.expectEqual(lease_mod.ReleaseOutcome.released, lease.release(currentPid()));
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "fork child cannot consume or deinit an inherited generation slot" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 103);
    var source = fixtureClient(std.testing.allocator, 0xD4);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        std.testing.allocator,
        &source,
        0xD4,
        &issuer,
        currentPid(),
    );
    var inherited_lease: lease_mod.ConnectionLease = .{};
    try lease_mod.ConnectionLease.initInPlace(
        &inherited_lease,
        &slot.current.pin_owner,
        19,
        currentPid(),
    );
    defer slot.deinit();
    const child = c.fork();
    try std.testing.expect(child >= 0);
    if (child == 0) {
        const child_pid = currentPid();
        var minted: lease_mod.ConnectionLease = .{};
        const mint_rejected = if (lease_mod.ConnectionLease.initInPlace(
            &minted,
            &slot.current.pin_owner,
            20,
            child_pid,
        )) |_| false else |err| err == error.InvalidOwner;
        const release_outcome = inherited_lease.release(child_pid);
        const deinit_outcome = slot.tryDeinit();
        const mutation_zero = slot.lifecycle == .live and
            slot.current.pin_owner.cleanup_pin_count == 1 and
            inherited_lease.lifecycle == .live;
        std.c._exit(if (mint_rejected and
            release_outcome == .corrupt and
            deinit_outcome == .corrupt and
            mutation_zero) 0 else 1);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(child, c.waitpid(child, &status, 0));
    try std.testing.expectEqual(@as(c_int, 0), status);
    try std.testing.expect(slot.valid());
    try std.testing.expectEqual(
        lease_mod.ReleaseOutcome.released,
        inherited_lease.release(currentPid()),
    );
}

test "client slot rejects a valid foreign generation node splice" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 104);
    var first_source = fixtureClient(std.testing.allocator, 0xE1);
    var second_source = fixtureClient(std.testing.allocator, 0xE2);
    var first: ClientSlot = undefined;
    var second: ClientSlot = undefined;
    try ClientSlot.initInPlaceWithIssuer(
        &first,
        std.testing.allocator,
        &first_source,
        0xE1,
        &issuer,
        currentPid(),
    );
    try ClientSlot.initInPlaceWithIssuer(
        &second,
        std.testing.allocator,
        &second_source,
        0xE2,
        &issuer,
        currentPid(),
    );
    const canonical_first = first.current;
    first.current = second.current;
    try std.testing.expect(!first.valid());
    try std.testing.expectEqual(DeinitOutcome.corrupt, first.tryDeinit());
    try first.current.client.tryAcquireEndedPurgeExclusive();
    try std.testing.expect(first.current.client.releaseEndedPurgeExclusiveClean());
    first.current = @ptrFromInt(@alignOf(ClientNode));
    try std.testing.expectEqual(DeinitOutcome.corrupt, first.tryDeinit());
    first.current = canonical_first;
    const shared = try first.beginRegisteredClientOperation();
    first.current = second.current;
    first.endRegisteredClientOperation(shared);
    first.current = canonical_first;
    try first.current.client.tryAcquireEndedPurgeExclusive();
    try std.testing.expect(first.current.client.releaseEndedPurgeExclusiveClean());
    first.deinit();
    second.deinit();
}

test "client slot burns identities and rejects allocator allocation callback reentry" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 105);
    var nested_source = fixtureClient(std.testing.allocator, 0xF1);
    defer nested_source.deinit();
    var nested_slot: ClientSlot = undefined;
    var allocator = ReentrantNodeAllocator{
        .parent = std.testing.allocator,
        .issuer = &issuer,
        .nested_source = &nested_source,
        .nested_slot = &nested_slot,
    };
    var source = fixtureClient(std.testing.allocator, 0xF2);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        allocator.allocator(),
        &source,
        0xF2,
        &issuer,
        currentPid(),
    );
    allocator.outer_slot = &slot;
    slot.deinit();
    try std.testing.expect(allocator.alloc_reentry_fired);
    try std.testing.expect(allocator.alloc_reentry_rejected);
    try std.testing.expect(nested_source.canMoveToGenerationNode());
    try std.testing.expectEqual(@as(u64, 5), issuer.next_ordinal.load(.acquire));
}

test "client slot publishes deinit reservation before allocator free callback reentry" {
    var issuer = lease_mod.IdentityIssuer.init(currentPid(), 106);
    var allocator = ReentrantNodeAllocator{ .parent = std.testing.allocator };
    var source = fixtureClient(std.testing.allocator, 0xF3);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlaceWithIssuer(
        &slot,
        allocator.allocator(),
        &source,
        0xF3,
        &issuer,
        currentPid(),
    );
    allocator.outer_slot = &slot;
    slot.deinit();
    try std.testing.expect(allocator.free_reentry_fired);
    try std.testing.expectEqual(DeinitOutcome.busy, allocator.free_reentry_outcome.?);
    try std.testing.expectEqual(Lifecycle.dead, slot.lifecycle);
}

test "CR3a B3b-F direct Client intrusion aborts a reserved slot teardown without panic" {
    const Runner = struct {
        fn run(client: *client_mod.Client, rejected: *std.atomic.Value(bool)) void {
            if (!client.tryDeinit()) rejected.store(true, .release);
        }
    };
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF4);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF4);

    const reserved = try slot.beginRegisteredExclusiveTeardown();
    var rejected: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Runner.run, .{ &reserved.node.client, &rejected });
    thread.join();
    try std.testing.expect(rejected.load(.acquire));
    try std.testing.expect(reserved.node.client.endedPurgeFenceIntruded());
    slot.abortRegisteredExclusiveTeardown(reserved);
    try std.testing.expect(clientSlotRegistryEntry(@intFromPtr(&slot)) != null);
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());
}

test "client slot alias quarantine counter rejects overflow without wrapping" {
    const before = alias_quarantine_events.load(.acquire);
    defer alias_quarantine_events.store(before, .release);
    alias_quarantine_events.store(std.math.maxInt(u64), .release);
    try std.testing.expect(!recordAliasQuarantine());
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        alias_quarantine_events.load(.acquire),
    );
}

test "CR3a-2c1 node canonical snapshot permit rejects stale authority replay and binding splice" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF4);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF4);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x44);
    defer slot.abortAttachmentBinding(&binding, reservation) catch
        @panic("snapshot permit test binding cleanup drifted");

    const first = try slot.prepareInitialSnapshotPermit(0x1000, 9, reservation.identity);
    try std.testing.expect(slot.initialSnapshotPermitLive(first));
    try slot.consumeInitialSnapshotPermit(first);
    try std.testing.expect(!slot.initialSnapshotPermitLive(first));
    try std.testing.expectError(error.InvalidSnapshotPermit, slot.consumeInitialSnapshotPermit(first));

    const second = try slot.prepareInitialSnapshotPermit(0x1000, 9, reservation.identity);
    try std.testing.expect(second.generation != first.generation);
    var spliced = second;
    spliced.binding.runtime_id += 1;
    try std.testing.expect(!slot.initialSnapshotPermitLive(spliced));
    try std.testing.expectError(error.InvalidSnapshotPermit, slot.abortInitialSnapshotPermit(spliced));
    try slot.abortInitialSnapshotPermit(second);
    try std.testing.expect(slot.initialSnapshotPermitIdle());
}

test "CR3a-2c2 node stream operation permit serializes snapshot and ended purge" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF5);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF5);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x45);
    defer slot.abortAttachmentBinding(&binding, reservation) catch
        @panic("stream operation permit test binding cleanup drifted");

    var foreign_prepare_rejected: std.atomic.Value(bool) = .init(false);
    const ForeignPrepare = struct {
        fn run(
            target: *ClientSlot,
            identity: contract.BindingIdentity,
            rejected: *std.atomic.Value(bool),
        ) void {
            if (target.prepareStreamOperationPermit(
                .ended_purge,
                0x3000,
                10,
                identity,
            )) |_| {
                return;
            } else |err| {
                if (err == error.InvalidStreamOperationPermit)
                    rejected.store(true, .release);
            }
        }
    };
    const foreign_prepare = try std.Thread.spawn(
        .{},
        ForeignPrepare.run,
        .{ &slot, reservation.identity, &foreign_prepare_rejected },
    );
    foreign_prepare.join();
    try std.testing.expect(foreign_prepare_rejected.load(.acquire));
    try std.testing.expect(slot.streamOperationPermitIdle());

    const snapshot = try slot.prepareStreamOperationPermit(
        .initial_snapshot,
        0x2000,
        10,
        reservation.identity,
    );
    try std.testing.expect(slot.streamOperationPermitLive(snapshot));
    var wrong_thread_rejected: std.atomic.Value(bool) = .init(false);
    const WrongThread = struct {
        fn run(
            target: *ClientSlot,
            captured: StreamOperationPermit,
            rejected: *std.atomic.Value(bool),
        ) void {
            target.abortStreamOperationPermit(captured) catch |abort_err| {
                if (abort_err != error.InvalidStreamOperationPermit) return;
                target.consumeStreamOperationPermit(captured) catch |consume_err| {
                    if (consume_err != error.InvalidStreamOperationPermit) return;
                    if (target.streamOperationPermitLive(captured)) return;
                    rejected.store(true, .release);
                };
            };
        }
    };
    const wrong_thread = try std.Thread.spawn(
        .{},
        WrongThread.run,
        .{ &slot, snapshot, &wrong_thread_rejected },
    );
    wrong_thread.join();
    try std.testing.expect(wrong_thread_rejected.load(.acquire));
    try std.testing.expect(slot.streamOperationPermitLive(snapshot));
    try std.testing.expectError(
        error.AdminBusy,
        slot.abortAttachmentBinding(&binding, reservation),
    );
    try std.testing.expectError(error.AdminBusy, slot.readAttachmentBatch(7));
    try std.testing.expectError(
        error.AdminBusy,
        slot.releaseAttachmentBatch(std.mem.zeroes(batch_registry_mod.Token)),
    );
    try std.testing.expectError(
        error.AdminBusy,
        slot.prepareStreamOperationPermit(
            .ended_purge,
            0x3000,
            10,
            reservation.identity,
        ),
    );
    batch_release_callback_active = true;
    defer batch_release_callback_active = false;
    try std.testing.expectError(
        error.InvalidStreamOperationPermit,
        slot.abortStreamOperationPermit(snapshot),
    );
    try std.testing.expectError(
        error.InvalidStreamOperationPermit,
        slot.consumeStreamOperationPermit(snapshot),
    );
    try std.testing.expect(slot.streamOperationPermitLive(snapshot));
    try std.testing.expectError(
        error.AdminBusy,
        slot.abortAttachmentBinding(&binding, reservation),
    );
    try std.testing.expectError(
        error.AdminBusy,
        slot.prepareStreamOperationPermit(
            .ended_purge,
            0x3000,
            10,
            reservation.identity,
        ),
    );
    batch_release_callback_active = false;
    try slot.consumeStreamOperationPermit(snapshot);

    const purge = try slot.prepareStreamOperationPermit(
        .ended_purge,
        0x3000,
        10,
        reservation.identity,
    );
    try std.testing.expectEqual(StreamOperationKind.ended_purge, purge.kind);
    try std.testing.expect(slot.streamOperationPermitLive(purge));
    try std.testing.expectError(error.AdminBusy, slot.readAttachmentBatch(7));
    try std.testing.expectError(
        error.AdminBusy,
        slot.releaseAttachmentBatch(std.mem.zeroes(batch_registry_mod.Token)),
    );
    var wrong_kind = purge;
    wrong_kind.kind = .initial_snapshot;
    try std.testing.expect(!slot.streamOperationPermitLive(wrong_kind));
    try std.testing.expectError(
        error.InvalidStreamOperationPermit,
        slot.consumeStreamOperationPermit(wrong_kind),
    );
    try slot.abortStreamOperationPermit(purge);
    try std.testing.expect(slot.streamOperationPermitIdle());
}

test "CR3a-2c3a canonical authority entrypoints reject foreign thread and fork child" {
    try ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0x2C3A);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0x2C3A);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x2C3B);
    try slot.current.cleanup_registry.bindStream(
        reservation.cleanup,
        reservation.identity,
        53,
    );

    const Foreign = struct {
        fn run(
            target: *ClientSlot,
            captured: AttachmentBindingReservation,
            binding_owner: *contract.PreparedAttachmentBinding,
            lease_owner: *lease_mod.ConnectionLease,
            rejected: *std.atomic.Value(bool),
        ) void {
            const live_rejected = if (target.controllerAuthorityLive(captured, 53)) |_| false else |err| err == error.MovedOrCopied;
            const pending_rejected = if (target.controllerRevokePending(captured, 53)) |_| false else |err| err == error.MovedOrCopied;
            const begin_rejected = if (target.beginControllerRevoke(captured, 53)) |_| false else |err| err == error.MovedOrCopied;
            const finish_rejected = if (target.finishControllerRevoke(captured, 53)) |_| false else |err| err == error.MovedOrCopied;
            const drop_rejected = if (target.beginAttachmentDrop(
                binding_owner,
                captured,
                lease_owner,
            )) |_| false else |err| err == error.MovedOrCopied;
            rejected.store(
                live_rejected and pending_rejected and begin_rejected and finish_rejected and
                    drop_rejected,
                .release,
            );
        }
    };
    var rejected: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(
        .{},
        Foreign.run,
        .{ &slot, reservation, &binding, &lease, &rejected },
    );
    thread.join();
    try std.testing.expect(rejected.load(.acquire));
    try std.testing.expect(try slot.controllerAuthorityLive(reservation, 53));

    var corrupt_reservation = reservation;
    const role_raw: *u8 = @ptrCast(&corrupt_reservation.identity.role);
    var raw: u16 = @intFromEnum(contract.AttachmentRole.observer) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        role_raw.* = @intCast(raw);
        try std.testing.expectError(
            error.InvalidIdentity,
            slot.controllerAuthorityLive(corrupt_reservation, 53),
        );
        try std.testing.expectError(
            error.InvalidIdentity,
            slot.controllerRevokePending(corrupt_reservation, 53),
        );
        try std.testing.expectError(
            error.InvalidIdentity,
            slot.beginControllerRevoke(corrupt_reservation, 53),
        );
        try std.testing.expectError(
            error.InvalidIdentity,
            slot.finishControllerRevoke(corrupt_reservation, 53),
        );
        try std.testing.expectError(
            error.InvalidIdentity,
            slot.beginAttachmentDrop(&binding, corrupt_reservation, &lease),
        );
    }
    try std.testing.expect(try slot.controllerAuthorityLive(reservation, 53));

    if (builtin.os.tag == .macos) {
        const child = c.fork();
        try std.testing.expect(child >= 0);
        if (child == 0) {
            var child_rejected: std.atomic.Value(bool) = .init(false);
            Foreign.run(&slot, reservation, &binding, &lease, &child_rejected);
            const mutation_zero = slot.current.cleanup_registry.controllerAuthorityLive(
                reservation.cleanup,
                reservation.identity,
                53,
            ) catch false;
            std.c._exit(if (child_rejected.load(.acquire) and mutation_zero) 0 else 1);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, c.waitpid(child, &status, 0));
        try std.testing.expectEqual(@as(c_int, 0), status);
    }

    try slot.beginControllerRevoke(reservation, 53);
    try slot.finishControllerRevoke(reservation, 53);
    try slot.current.cleanup_registry.beginBoundDrop(
        reservation.cleanup,
        reservation.identity,
        53,
    );
    try slot.current.cleanup_registry.completeActiveDrop(
        reservation.cleanup,
        reservation.identity,
        53,
    );
    slot.current.pin_owner.cleanup_pin_count -= 1;
    binding.lifecycle = .terminal;
}

test "CR3a-2c2b3b B3b-O atomic permit receipt is exact once and delays index reuse" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF501);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF501);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x4501);
    defer slot.abortAttachmentBinding(&binding, reservation) catch
        @panic("atomic permit receipt binding cleanup drifted");

    var scratch: client_mod.EndedPurgeScratch = .{};
    var preparation: EndedPurgePreparation = .{};
    const permit = try slot.prepareStreamOperationPermit(
        .ended_purge,
        @intFromPtr(&preparation),
        17,
        reservation.identity,
    );
    preparation = .{
        .self_addr = @intFromPtr(&preparation),
        .target_stream = 9,
        .permit = permit,
        .inventory = .{
            .self_addr = @intFromPtr(&preparation.inventory),
            .client_addr = @intFromPtr(&slot.current.client),
            .scratch_addr = @intFromPtr(&scratch),
            .target_stream = 9,
            .target_event_count = 1,
            .lifecycle = .prepared,
        },
        .lifecycle = .prepared,
    };
    preparation.authority_seal = endedPurgePreparationSeal(&preparation);

    var receipt: ClientSlot.PreparedStreamOperationPermitConsume = .{};
    try slot.prepareStreamOperationPermitConsume(permit, &receipt);
    const entry = &stream_operation_registry[permit.registry_index];
    try std.testing.expectEqual(
        @intFromEnum(StreamOperationRegistryEntry.State.consume_reserved),
        entry.state.load(.acquire),
    );
    try std.testing.expect(!slot.streamOperationPermitLive(permit));

    const ForeignThreadProbe = struct {
        fn run(
            target_slot: *ClientSlot,
            target_preparation: *EndedPurgePreparation,
            target_receipt: *ClientSlot.PreparedStreamOperationPermitConsume,
            seal_result: *bool,
            consume_result: *bool,
        ) void {
            seal_result.* = target_preparation.sealForCommit(target_slot);
            consume_result.* = target_slot.consumeStreamOperationPermitUnchecked(target_receipt);
        }
    };
    var foreign_seal_result = true;
    var foreign_consume_result = true;
    const foreign_thread = try std.Thread.spawn(.{}, ForeignThreadProbe.run, .{
        &slot,
        &preparation,
        &receipt,
        &foreign_seal_result,
        &foreign_consume_result,
    });
    foreign_thread.join();
    try std.testing.expect(!foreign_seal_result);
    try std.testing.expect(!foreign_consume_result);
    try std.testing.expectEqual(
        @intFromEnum(StreamOperationRegistryEntry.State.consume_reserved),
        entry.state.load(.acquire),
    );

    var sibling_source = fixtureClient(allocator, 0xF505);
    var sibling_slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&sibling_slot, allocator, &sibling_source, 0xF505);
    defer sibling_slot.deinit();
    var sibling_binding: contract.PreparedAttachmentBinding = .{};
    var sibling_lease: lease_mod.ConnectionLease = .{};
    const sibling_reservation = try sibling_slot.reserveAttachmentBindingForTest(
        &sibling_binding,
        &sibling_lease,
        0x4505,
    );
    defer sibling_slot.abortAttachmentBinding(&sibling_binding, sibling_reservation) catch
        @panic("atomic permit sibling binding cleanup drifted");
    const sibling_permit = try sibling_slot.prepareStreamOperationPermit(
        .initial_snapshot,
        41,
        43,
        sibling_reservation.identity,
    );
    try std.testing.expect(sibling_permit.registry_index != permit.registry_index);
    try sibling_slot.consumeStreamOperationPermit(sibling_permit);
    try std.testing.expect(sibling_slot.streamOperationPermitIdle());

    const preparation_lifecycle_raw: *u8 = @ptrCast(&preparation.lifecycle);
    var raw_tag: u16 = @intFromEnum(EndedPurgePreparationLifecycle.aborted) + 1;
    while (raw_tag <= std.math.maxInt(u8)) : (raw_tag += 1) {
        preparation_lifecycle_raw.* = @intCast(raw_tag);
        try std.testing.expect(!preparation.sealForCommit(&slot));
    }
    preparation_lifecycle_raw.* = @intFromEnum(EndedPurgePreparationLifecycle.prepared);

    const permit_kind_raw: *u8 = @ptrCast(&preparation.permit.kind);
    raw_tag = @intFromEnum(StreamOperationKind.ended_purge) + 1;
    while (raw_tag <= std.math.maxInt(u8)) : (raw_tag += 1) {
        permit_kind_raw.* = @intCast(raw_tag);
        try std.testing.expect(!preparation.sealForCommit(&slot));
    }
    permit_kind_raw.* = @intFromEnum(StreamOperationKind.ended_purge);

    const binding_role_raw: *u8 = @ptrCast(&preparation.permit.binding.role);
    raw_tag = @intFromEnum(contract.AttachmentRole.observer) + 1;
    while (raw_tag <= std.math.maxInt(u8)) : (raw_tag += 1) {
        binding_role_raw.* = @intCast(raw_tag);
        try std.testing.expect(!preparation.sealForCommit(&slot));
    }
    binding_role_raw.* = @intFromEnum(permit.binding.role);

    const inventory_lifecycle_raw: *u8 = @ptrCast(&preparation.inventory.lifecycle);
    raw_tag = 3;
    while (raw_tag <= std.math.maxInt(u8)) : (raw_tag += 1) {
        inventory_lifecycle_raw.* = @intCast(raw_tag);
        try std.testing.expect(!preparation.sealForCommit(&slot));
    }
    inventory_lifecycle_raw.* = 1;

    try std.testing.expect(preparation.sealForCommit(&slot));

    var copied = receipt;
    try std.testing.expect(!slot.consumeStreamOperationPermitUnchecked(&copied));
    const receipt_lifecycle_raw: *u8 = @ptrCast(&receipt.lifecycle);
    raw_tag = @intFromEnum(ClientSlot.PreparedStreamOperationPermitConsume.Lifecycle.consumed) + 1;
    while (raw_tag <= std.math.maxInt(u8)) : (raw_tag += 1) {
        receipt_lifecycle_raw.* = @intCast(raw_tag);
        try std.testing.expect(!slot.consumeStreamOperationPermitUnchecked(&receipt));
    }
    receipt_lifecycle_raw.* =
        @intFromEnum(ClientSlot.PreparedStreamOperationPermitConsume.Lifecycle.prepared);
    try std.testing.expect(slot.consumeStreamOperationPermitUnchecked(&receipt));
    try std.testing.expectEqual(
        @intFromEnum(StreamOperationRegistryEntry.State.consumed),
        entry.state.load(.acquire),
    );
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expect(!slot.consumeStreamOperationPermitUnchecked(&receipt));
    preparation.consumeAfterPermit(&slot);
    try std.testing.expectEqual(
        @intFromEnum(StreamOperationRegistryEntry.State.empty),
        entry.state.load(.acquire),
    );

    const reused = try slot.prepareStreamOperationPermit(
        .initial_snapshot,
        19,
        23,
        reservation.identity,
    );
    try std.testing.expectEqual(permit.registry_index, reused.registry_index);
    try std.testing.expect(reused.registry_id != permit.registry_id);
    try std.testing.expect(!slot.consumeStreamOperationPermitUnchecked(&receipt));
    try slot.abortStreamOperationPermit(reused);

    var raw_state: u16 = 0;
    while (raw_state <= std.math.maxInt(u8)) : (raw_state += 1) {
        entry.state.store(@intCast(raw_state), .release);
        try std.testing.expect(!slot.streamOperationPermitLive(permit));
        try std.testing.expect(!slot.streamOperationPermitLive(reused));
        try std.testing.expect(!slot.consumeStreamOperationPermitUnchecked(&receipt));
    }
    entry.state.store(@intFromEnum(StreamOperationRegistryEntry.State.empty), .release);
}

test "CR3a-2c2b3b B3b-O validated suffix mismatch fail-stops in a subprocess" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF503);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF503);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x4503);
    defer slot.abortAttachmentBinding(&binding, reservation) catch
        @panic("suffix mismatch fixture binding cleanup drifted");

    var preparation: EndedPurgePreparation = .{};
    const permit = try slot.prepareStreamOperationPermit(
        .ended_purge,
        @intFromPtr(&preparation),
        31,
        reservation.identity,
    );
    defer if (slot.streamOperationPermitLive(permit))
        slot.abortStreamOperationPermit(permit) catch
            @panic("suffix mismatch fixture permit cleanup drifted");
    var receipt: ClientSlot.PreparedStreamOperationPermitConsume = .{};
    try slot.prepareStreamOperationPermitConsume(permit, &receipt);

    var panic_pipe: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&panic_pipe));
    defer _ = c.close(panic_pipe[0]);
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        _ = c.close(panic_pipe[0]);
        if (c.dup2(panic_pipe[1], 2) < 0) c._exit(126);
        _ = c.close(panic_pipe[1]);
        slot.pid = currentPid();
        if (!operationThreadMatches(slot.operation_owner_thread_incarnation))
            std.c._exit(4);
        receipt.registry_id +%= 1;
        if (!slot.consumeStreamOperationPermitUnchecked(&receipt))
            @panic("validated ended purge suffix mismatch");
        _ = c.write(2, "suffix mismatch returned\n", "suffix mismatch returned\n".len);
        std.c._exit(0);
    }
    _ = c.close(panic_pipe[1]);

    var status: c_int = 0;
    var attempts: usize = 0;
    while (attempts < 2_000) : (attempts += 1) {
        const waited = std.c.waitpid(child, &status, std.c.W.NOHANG);
        if (waited == child) break;
        if (waited < 0 and std.posix.errno(waited) != .INTR)
            return error.TestUnexpectedResult;
        var delay_fd = c.pollfd{ .fd = -1, .events = 0, .revents = 0 };
        _ = c.poll(@ptrCast(&delay_fd), 0, 1);
    }
    if (attempts == 2_000) {
        _ = c.kill(child, c.SIG.KILL);
        _ = c.waitpid(child, &status, 0);
        return error.TestUnexpectedResult;
    }
    const wait_status: u32 = @bitCast(status);
    try std.testing.expect(!c.W.IFEXITED(wait_status) or c.W.EXITSTATUS(wait_status) != 0);
    var panic_output: [4096]u8 = undefined;
    const panic_len = c.read(panic_pipe[0], &panic_output, panic_output.len);
    try std.testing.expect(panic_len > 0);
    const panic_bytes = panic_output[0..@intCast(panic_len)];
    try std.testing.expect(std.mem.indexOf(
        u8,
        panic_bytes,
        "validated ended purge suffix mismatch",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, panic_bytes, "suffix mismatch returned") == null);

    try std.testing.expect(slot.consumeStreamOperationPermitUnchecked(&receipt));
    const entry = &stream_operation_registry[permit.registry_index];
    try std.testing.expectEqual(
        @intFromEnum(StreamOperationRegistryEntry.State.consumed),
        entry.state.load(.acquire),
    );
    // This hostile test consumes the raw permit without the production preparation
    // completion path, so it must retire the matching node operation before fixture drop.
    slot.clearStreamOperationPermit();
    entry.state.store(@intFromEnum(StreamOperationRegistryEntry.State.empty), .release);
}

test "CR3a-2c2b3b B3b-O isolated marker executes drift and aggregate marker only proves exclusion" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // The dedicated filtered artifact supplies run-isolated-v1 and is the only destructive
    // evidence. Generic aggregates either supply skip-in-aggregate-v1 or have no marker; their OK
    // result proves only that the process-global fixture was excluded, never that it ran.
    const marker_ptr = c.getenv("MARU_SESSION_HOST_B3BO_DRIFT_SUBPROCESS") orelse return;
    const marker = std.mem.span(marker_ptr);
    if (std.mem.eql(u8, marker, "skip-in-aggregate-v1")) return;
    if (!std.mem.eql(u8, marker, "run-isolated-v1"))
        return error.InvalidDriftSubprocessMode;
    const DriftAllocator = struct {
        parent: std.mem.Allocator,
        replacement: std.mem.Allocator,
        client: ?*client_mod.Client = null,
        armed: bool = false,
        drifted: bool = false,

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
            if (self.armed and !self.drifted) {
                self.drifted = true;
                self.client.?.allocator = self.replacement;
            }
            self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
        }
    };
    try ClientSlot.initializeProcessRuntime();
    var probe = DriftAllocator{
        .parent = std.heap.page_allocator,
        .replacement = std.heap.c_allocator,
    };
    const allocator = probe.allocator();
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = c.close(fds[1]);
    var source = fixtureClient(allocator, 0xF504);
    source.fd = fds[0];
    source.build_id = try allocator.dupe(u8, "build");
    source.lifecycle = try allocator.dupe(u8, "running");
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, source.host_id);
    probe.client = &slot.current.client;
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(
        &binding,
        &lease,
        0x4504,
    );
    try slot.current.cleanup_registry.bindStream(
        reservation.cleanup,
        reservation.identity,
        9,
    );
    const ended_payload = "{\"event\":\"runtime.ended\"}";
    const event_wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .event, .stream_id = 9 },
        ended_payload,
    );
    const snapshot_wire = try framing.encodeFrame(
        allocator,
        .{
            .kind = .snapshot_chunk,
            .stream_id = 99,
            .flags = protocol.Flags.end_stream,
        },
        "snapshot",
    );
    try socket_server.writeAll(fds[1], event_wire);
    try socket_server.writeAll(fds[1], snapshot_wire);
    _ = try slot.current.client.readSnapshot(99);
    const hint = (try slot.current.client.peekEndedEventForStream(9)).candidate;
    var scratch: client_mod.EndedPurgeScratch = .{};
    var preparation: EndedPurgePreparation = .{};
    try slot.prepareEndedPurge(37, reservation, 9, hint, &scratch, &preparation);
    probe.armed = true;
    try std.testing.expectEqual(
        ClientSlot.EndedPurgeResult.purged,
        try slot.commitEndedPurge(&scratch, &preparation),
    );
    try std.testing.expect(probe.drifted);
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expectEqual(
        @intFromEnum(EndedPurgePreparationLifecycle.consumed),
        @as(*const u8, @ptrCast(&preparation.lifecycle)).*,
    );
    try std.testing.expectEqual(@as(c.fd_t, -1), slot.current.client.fd);
}

test "CR3a-2c2b3b B3b-O product clean commit purges ended event and consumes paired authority" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = c.close(fds[1]);
    var source = fixtureClient(allocator, 0xF502);
    source.fd = fds[0];
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF502);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x4502);
    try slot.current.cleanup_registry.bindStream(
        reservation.cleanup,
        reservation.identity,
        9,
    );
    defer {
        slot.current.cleanup_registry.beginBoundDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("B3b-O clean product binding cleanup drifted");
        slot.current.cleanup_registry.completeActiveDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("B3b-O clean product binding cleanup completion drifted");
        slot.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }

    const ended_payload = "{\"event\":\"runtime.ended\"}";
    const event_wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .event, .stream_id = 9 },
        ended_payload,
    );
    defer allocator.free(event_wire);
    const snapshot_wire = try framing.encodeFrame(
        allocator,
        .{
            .kind = .snapshot_chunk,
            .stream_id = 99,
            .flags = protocol.Flags.end_stream,
        },
        "snapshot",
    );
    defer allocator.free(snapshot_wire);
    try socket_server.writeAll(fds[1], event_wire);
    try socket_server.writeAll(fds[1], snapshot_wire);
    const snapshot = try slot.current.client.readSnapshot(99);
    defer allocator.free(snapshot);
    try std.testing.expectEqualStrings("snapshot", snapshot);

    const hint = (try slot.current.client.peekEndedEventForStream(9)).candidate;
    var scratch: client_mod.EndedPurgeScratch = .{};
    var preparation: EndedPurgePreparation = .{};
    try slot.prepareEndedPurge(
        29,
        reservation,
        9,
        hint,
        &scratch,
        &preparation,
    );
    try std.testing.expectEqual(
        ClientSlot.EndedPurgeResult.purged,
        try slot.commitEndedPurge(&scratch, &preparation),
    );
    try std.testing.expectEqual(EndedPurgePreparationLifecycle.consumed, preparation.lifecycle);
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expectEqual(
        client_mod.EndedEventPeek.not_ended,
        try slot.current.client.peekEndedEventForStream(9),
    );
    try std.testing.expect(slot.current.client.firstPoisonReason() == null);
}

test "CR3a-2c2b2 corrupt ended preparation poisons once and rolls back permit" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF7);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF7);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x47);
    try slot.current.cleanup_registry.bindStream(
        reservation.cleanup,
        reservation.identity,
        9,
    );
    defer {
        slot.current.cleanup_registry.beginBoundDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("ended preparation test cleanup registry drifted");
        slot.current.cleanup_registry.completeActiveDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("ended preparation test cleanup registry completion drifted");
        slot.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }
    var scratch: client_mod.EndedPurgeScratch = .{};
    var prepared: EndedPurgePreparation = .{};

    try std.testing.expectError(
        error.Corrupt,
        slot.prepareEndedPurge(
            11,
            reservation,
            9,
            .{ .event_index = 0 },
            &scratch,
            &prepared,
        ),
    );
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expectEqual(EndedPurgePreparationLifecycle.empty, prepared.lifecycle);
    try std.testing.expect(slot.current.client.firstPoisonReason().? == .local_invariant_violation);
    try std.testing.expectError(
        error.Corrupt,
        slot.prepareEndedPurge(
            11,
            reservation,
            9,
            .{ .event_index = 0 },
            &scratch,
            &prepared,
        ),
    );
    try std.testing.expect(slot.current.client.firstPoisonReason().? == .local_invariant_violation);
    try std.testing.expect(slot.streamOperationPermitIdle());
}

test "CR3a-2c2b2 busy ended preparation does not burn operation generation" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF8);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF8);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x48);
    try slot.current.cleanup_registry.bindStream(
        reservation.cleanup,
        reservation.identity,
        9,
    );
    defer {
        slot.current.cleanup_registry.beginBoundDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("busy ended preparation cleanup registry drifted");
        slot.current.cleanup_registry.completeActiveDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("busy ended preparation cleanup registry completion drifted");
        slot.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }
    var scratch: client_mod.EndedPurgeScratch = .{};
    var prepared: EndedPurgePreparation = .{};

    const batch = try slot.current.batch_registry.reserve(9);
    defer slot.current.batch_registry.abort(batch) catch
        @panic("ended preparation test batch cleanup drifted");
    const generation_before_busy = slot.current.next_operation_generation;
    try std.testing.expectError(
        error.Busy,
        slot.prepareEndedPurge(
            11,
            reservation,
            9,
            .{ .event_index = 0 },
            &scratch,
            &prepared,
        ),
    );
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expectEqual(
        generation_before_busy,
        slot.current.next_operation_generation,
    );
    try std.testing.expect(slot.current.client.firstPoisonReason() == null);
}

test "CR3a-2c2b2 ended preparation rejects wrong stream foreign binding and owner aliases before mutation" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF9);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF9);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x49);
    try slot.current.cleanup_registry.bindStream(reservation.cleanup, reservation.identity, 9);
    defer {
        slot.current.cleanup_registry.beginBoundDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("ended preparation owner preflight cleanup drifted");
        slot.current.cleanup_registry.completeActiveDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("ended preparation owner preflight cleanup completion drifted");
        slot.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }
    var scratch: client_mod.EndedPurgeScratch = .{};
    var prepared: EndedPurgePreparation = .{};
    const generation_before = slot.current.next_operation_generation;

    var foreign_thread_rejected: std.atomic.Value(bool) = .init(false);
    const ForeignPrepare = struct {
        fn run(
            target: *ClientSlot,
            captured: AttachmentBindingReservation,
            local_scratch: *client_mod.EndedPurgeScratch,
            local_out: *EndedPurgePreparation,
            rejected: *std.atomic.Value(bool),
        ) void {
            target.prepareEndedPurge(
                11,
                captured,
                9,
                .{ .event_index = 0 },
                local_scratch,
                local_out,
            ) catch |err| {
                if (err == error.InvalidOwner) rejected.store(true, .release);
            };
        }
    };
    const foreign_thread = try std.Thread.spawn(
        .{},
        ForeignPrepare.run,
        .{ &slot, reservation, &scratch, &prepared, &foreign_thread_rejected },
    );
    foreign_thread.join();
    try std.testing.expect(foreign_thread_rejected.load(.acquire));

    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        10,
        .{ .event_index = 0 },
        &scratch,
        &prepared,
    ));
    var foreign = reservation;
    foreign.identity.runtime_id += 1;
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        foreign,
        9,
        .{ .event_index = 0 },
        &scratch,
        &prepared,
    ));

    const node_scratch_addr = std.mem.alignForward(
        usize,
        @intFromPtr(slot.current),
        @alignOf(client_mod.EndedPurgeScratch),
    );
    const node_scratch: *client_mod.EndedPurgeScratch = @ptrFromInt(node_scratch_addr);
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        node_scratch,
        &prepared,
    ));
    const slot_out_addr = std.mem.alignForward(
        usize,
        @intFromPtr(&slot),
        @alignOf(EndedPurgePreparation),
    );
    const slot_out: *EndedPurgePreparation = @ptrFromInt(slot_out_addr);
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        &scratch,
        slot_out,
    ));
    const scratch_out_addr = std.mem.alignForward(
        usize,
        @intFromPtr(&scratch),
        @alignOf(EndedPurgePreparation),
    );
    const scratch_out: *EndedPurgePreparation = @ptrFromInt(scratch_out_addr);
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        &scratch,
        scratch_out,
    ));
    const binding_out_addr = std.mem.alignForward(
        usize,
        @intFromPtr(&binding),
        @alignOf(EndedPurgePreparation),
    );
    const binding_out: *EndedPurgePreparation = @ptrFromInt(binding_out_addr);
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        &scratch,
        binding_out,
    ));

    prepared.inventory.self_addr = 1;
    try std.testing.expectError(error.DestinationOccupied, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        &scratch,
        &prepared,
    ));
    prepared.inventory = .{};
    try std.testing.expectEqual(generation_before, slot.current.next_operation_generation);
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expect(slot.current.client.firstPoisonReason() == null);
}

test "CR3a-2c2b2 ended preparation seal rejects copy field splice and preserves all or none abort" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xFA);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xFA);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x4A);
    defer slot.abortAttachmentBinding(&binding, reservation) catch
        @panic("ended preparation seal binding cleanup drifted");
    var scratch: client_mod.EndedPurgeScratch = .{};
    var prepared: EndedPurgePreparation = .{};
    const permit = try slot.prepareStreamOperationPermit(
        .ended_purge,
        @intFromPtr(&prepared),
        11,
        reservation.identity,
    );
    prepared = .{
        .self_addr = @intFromPtr(&prepared),
        .target_stream = 9,
        .permit = permit,
        .inventory = .{
            .self_addr = @intFromPtr(&prepared.inventory),
            .client_addr = @intFromPtr(&slot.current.client),
            .scratch_addr = @intFromPtr(&scratch),
            .target_stream = 9,
            .target_event_count = 1,
            .lifecycle = .prepared,
        },
        .lifecycle = .prepared,
    };
    prepared.authority_seal = endedPurgePreparationSeal(&prepared);

    var copied = prepared;
    try std.testing.expect(!copied.abort(&slot));
    try std.testing.expect(slot.streamOperationPermitLive(permit));
    try std.testing.expect(prepared.inventory.validPreparedAtFinalAddress());

    prepared.inventory.events.address = 8;
    try std.testing.expect(!prepared.abort(&slot));
    try std.testing.expect(slot.streamOperationPermitLive(permit));
    prepared.inventory.events.address = 0;
    prepared.permit.binding.runtime_id += 1;
    try std.testing.expect(!prepared.abort(&slot));
    try std.testing.expect(slot.streamOperationPermitLive(permit));
    prepared.permit.binding.runtime_id -= 1;

    try std.testing.expect(prepared.abort(&slot));
    try std.testing.expect(!prepared.abort(&slot));
    try std.testing.expect(slot.streamOperationPermitIdle());
}

test "CR3a-2c2b2 stale ClientSlot prepare rejects before freed node dereference" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xFB);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xFB);
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x4B);
    try slot.abortAttachmentBinding(&binding, reservation);
    try std.testing.expectEqual(DeinitOutcome.cleaned, slot.tryDeinit());

    var scratch: client_mod.EndedPurgeScratch = .{};
    var prepared: EndedPurgePreparation = .{};
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        &scratch,
        &prepared,
    ));
}

test "CR3a-2c2b2 foreign thread teardown cannot race owner preparation" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xFC);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xFC);
    defer slot.deinit();
    var outcome: ?DeinitOutcome = null;
    const ForeignTeardown = struct {
        fn run(target: *ClientSlot, result: *?DeinitOutcome) void {
            result.* = target.tryDeinit();
        }
    };
    const thread = try std.Thread.spawn(.{}, ForeignTeardown.run, .{ &slot, &outcome });
    thread.join();
    try std.testing.expectEqual(DeinitOutcome.corrupt, outcome.?);
    try std.testing.expect(slot.valid());
}

test "B3-0.3 response destination requires full authenticated owner containment before dereference" {
    const response_size = @sizeOf(executed_response_mod.ExecutedResponse);
    const owner_addr: usize = 0x4000;
    const owner_size = response_size * 2;

    try std.testing.expect(byteRangeFullyContained(
        owner_addr,
        response_size,
        owner_addr,
        owner_size,
    ));
    try std.testing.expect(byteRangeFullyContained(
        owner_addr + owner_size - response_size,
        response_size,
        owner_addr,
        owner_size,
    ));
    try std.testing.expect(!byteRangeFullyContained(
        owner_addr - 1,
        response_size,
        owner_addr,
        owner_size,
    ));
    try std.testing.expect(!byteRangeFullyContained(
        owner_addr + owner_size - response_size + 1,
        response_size,
        owner_addr,
        owner_size,
    ));
    try std.testing.expect(!byteRangeFullyContained(
        owner_addr + owner_size,
        response_size,
        owner_addr,
        owner_size,
    ));
    try std.testing.expect(!byteRangeFullyContained(
        std.math.maxInt(usize) - response_size + 1,
        response_size,
        owner_addr,
        owner_size,
    ));
    try std.testing.expect(!byteRangeFullyContained(
        owner_addr,
        response_size,
        std.math.maxInt(usize) - owner_size + 1,
        owner_size,
    ));
}

test "B3-0.3 public execute rejects forged response destinations before authority mutation" {
    try ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0x2C3BD0);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0x2C3BD0);
    defer slot.deinit();

    const Owner = struct {
        transport_marker: u8 = 0,
        storage: client_mod.PreparedBlockingRpcStorage = .{},
        response: executed_response_mod.ExecutedResponse = .{},
        binding: contract.PreparedAttachmentBinding = .{},
        lease: lease_mod.ConnectionLease = .{},
    };
    var owner: Owner = .{};
    var outside_response: executed_response_mod.ExecutedResponse = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(
        &owner.binding,
        &owner.lease,
        0x2C3BD1,
    );
    const transport_incarnation: u64 = 0x2C3BD2;
    const transport_owner_seal = try slot.transportOwnerSeal(reservation);
    try contract.TransportOwnerSeal.initWithRpcResponseInPlace(
        transport_owner_seal,
        transport_incarnation,
        @intFromPtr(&owner),
        @sizeOf(Owner),
        @intFromPtr(&owner.transport_marker),
        @intFromPtr(&owner.storage),
        @intFromPtr(&owner.response),
    );
    const identity = reservation.identity;
    const prepared = try prepareGenerationRequest(.{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .owner_addr = @intFromPtr(&owner),
        .owner_size = @sizeOf(Owner),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .bound_stream_id = 0,
        .reservation = reservation,
        .request = contract.RuntimeRequest.attachController(),
    });
    try owner.binding.pairRequest(prepared.receipt);
    try owner.binding.beginExecute(prepared.receipt);
    const response_owner = try slot.responseOwnerSeal(reservation);
    const request: GenerationRequestAbort = .{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .reservation = reservation,
        .receipt = prepared.receipt,
    };
    const owner_addr = @intFromPtr(&owner);
    const response_size = @sizeOf(executed_response_mod.ExecutedResponse);
    slot.current.active_operation_generation = 1;
    errdefer slot.current.active_operation_generation = 0;
    var invalid_receipt_while_busy = request;
    invalid_receipt_while_busy.receipt.request_digest +%= 1;
    try std.testing.expectError(error.Busy, executeGenerationRequest(.{
        .request = invalid_receipt_while_busy,
        .response_out_addr = @intFromPtr(&owner.response),
        .owner_addr = owner_addr,
        .owner_size = @sizeOf(Owner),
    }));
    slot.current.active_operation_generation = 0;
    try std.testing.expect(!client_mod.Client.preparedBlockingRpcStorageSettled(&owner.storage));

    try std.testing.expectError(error.Unauthorized, executeGenerationRequest(.{
        .request = request,
        .bound_stream_id = 1,
        .response_out_addr = @intFromPtr(&owner.response),
        .owner_addr = owner_addr,
        .owner_size = @sizeOf(Owner),
    }));
    try std.testing.expect(!client_mod.Client.preparedBlockingRpcStorageSettled(&owner.storage));
    try std.testing.expectEqual(
        prepared_request_authority.SettlementReadiness.busy,
        try slot.current.cleanup_registry.preparedRequestSettlementReadiness(
            reservation.cleanup,
            identity,
        ),
    );
    // The request remains bound to the canonical owner seal while the outer execute wrapper
    // advertises an attacker-selected range that happens to contain its destination.  The
    // pre-admission scalar check passes; only the post-admission canonical equality check may
    // reject it, before pointer materialization or authority mutation.
    try std.testing.expectError(error.InvalidOwner, executeGenerationRequest(.{
        .request = request,
        .response_out_addr = @intFromPtr(&outside_response),
        .owner_addr = @intFromPtr(&outside_response),
        .owner_size = @sizeOf(executed_response_mod.ExecutedResponse),
    }));
    try std.testing.expect(!client_mod.Client.preparedBlockingRpcStorageSettled(&owner.storage));
    try std.testing.expectEqual(
        prepared_request_authority.SettlementReadiness.busy,
        try slot.current.cleanup_registry.preparedRequestSettlementReadiness(
            reservation.cleanup,
            identity,
        ),
    );
    try std.testing.expect(std.meta.eql(outside_response, std.mem.zeroes(executed_response_mod.ExecutedResponse)));
    try std.testing.expect(slot.current.client.firstPoisonReason() == null);

    const forged_destinations = [_]usize{
        @intFromPtr(&outside_response),
        owner_addr + @sizeOf(Owner),
        owner_addr + @sizeOf(Owner) - response_size + 1,
        owner_addr - 1,
        std.math.maxInt(usize) - response_size + 1,
    };
    for (forged_destinations) |response_out_addr| {
        try std.testing.expectError(error.InvalidResponseDestination, executeGenerationRequest(.{
            .request = request,
            .response_out_addr = response_out_addr,
            .owner_addr = owner_addr,
            .owner_size = @sizeOf(Owner),
        }));
        try std.testing.expect(!client_mod.Client.preparedBlockingRpcStorageSettled(&owner.storage));
        try std.testing.expectEqual(
            prepared_request_authority.SettlementReadiness.busy,
            try slot.current.cleanup_registry.preparedRequestSettlementReadiness(
                reservation.cleanup,
                identity,
            ),
        );
        try std.testing.expect(owner.response.canInitializeWithOwner(response_owner));
        try std.testing.expect(slot.current.client.firstPoisonReason() == null);
    }
    try std.testing.expect(std.meta.eql(outside_response, std.mem.zeroes(executed_response_mod.ExecutedResponse)));

    try abortGenerationRequest(request);
    try transport_owner_seal.terminalize(transport_incarnation);
    try slot.abortExecutedAttachmentBinding(
        &owner.binding,
        reservation,
        contract.ExecutedCallReceipt.fromPrepared(prepared.receipt).?,
    );
}

test "B3-3 private product wrapper composite failures settle both authorities" {
    const Harness = struct {
        const Scenario = enum {
            reserve_rollback,
            lease_rollback,
            response_epoch_exhausted,
            pending_ambiguity,
            request_hard_failure,
        };

        fn run(scenario: Scenario) !void {
            try ClientSlot.initializeProcessRuntime();
            const allocator = std.testing.allocator;
            var wire_fds: [2]c.fd_t = undefined;
            try std.testing.expectEqual(
                @as(c_int, 0),
                c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &wire_fds),
            );
            var peer_open = true;
            defer {
                if (peer_open) _ = c.close(wire_fds[1]);
            }
            const ordinal: u64 = @as(u64, @intFromEnum(scenario)) + 1;
            var source = fixtureClient(allocator, 0xB33C0 + ordinal);
            source.fd = wire_fds[0];
            var slot: ClientSlot = undefined;
            try ClientSlot.initInPlace(&slot, allocator, &source, 0xB33C0 + ordinal);
            defer slot.deinit();
            const Owner = struct {
                transport_marker: u8 = 0,
                storage: client_mod.PreparedBlockingRpcStorage = .{},
                response: RpcExecutedResponse = .{},
                binding: contract.PreparedAttachmentBinding = .{},
                lease: lease_mod.ConnectionLease = .{},
            };
            var owner: Owner = .{};
            const reservation = try slot.reserveAttachmentBindingForTest(
                &owner.binding,
                &owner.lease,
                0xB33D0 + ordinal,
            );
            const identity = reservation.identity;
            const attach_receipt = contract.PreparedCallReceipt.init(.{
                .transport_incarnation = 0xB33E0 + ordinal,
                .request_id = 0xB33F0 + ordinal,
                .request_digest = 0xB3400 + ordinal,
            }).?;
            try owner.binding.pairRequest(attach_receipt);
            try owner.binding.beginExecute(attach_receipt);
            const attach_executed = contract.ExecutedCallReceipt.fromPrepared(attach_receipt).?;
            const stream_id = 80 + ordinal;
            try slot.commitAttachmentBinding(
                &owner.binding,
                reservation,
                contract.CorrelatedExecutedCall.init(attach_executed, attach_receipt.request_id).?,
                stream_id,
                &owner.lease,
            );
            const transport_incarnation = 0xB3410 + ordinal;
            const transport_owner_seal = try slot.transportOwnerSeal(reservation);
            try contract.TransportOwnerSeal.initInPlace(
                transport_owner_seal,
                transport_incarnation,
                @intFromPtr(&owner),
                @sizeOf(Owner),
                @intFromPtr(&owner.transport_marker),
                @intFromPtr(&owner.storage),
            );
            const prepared = try prepareGenerationRequest(.{
                .slot_addr = @intFromPtr(&slot),
                .slot_incarnation = identity.slot_incarnation,
                .node_incarnation = identity.node_incarnation,
                .host_id = identity.host_id,
                .pid = identity.pid,
                .process_nonce = identity.process_nonce,
                .transport_addr = @intFromPtr(&owner.transport_marker),
                .owner_addr = @intFromPtr(&owner),
                .owner_size = @sizeOf(Owner),
                .transport_incarnation = transport_incarnation,
                .owner_seal_addr = @intFromPtr(transport_owner_seal),
                .prepared_storage_addr = @intFromPtr(&owner.storage),
                .bound_stream_id = stream_id,
                .reservation = reservation,
                .request = contract.RuntimeRequest.observation(),
            });
            const request: GenerationRequestAbort = .{
                .slot_addr = @intFromPtr(&slot),
                .slot_incarnation = identity.slot_incarnation,
                .node_incarnation = identity.node_incarnation,
                .host_id = identity.host_id,
                .pid = identity.pid,
                .process_nonce = identity.process_nonce,
                .transport_addr = @intFromPtr(&owner.transport_marker),
                .transport_incarnation = transport_incarnation,
                .owner_seal_addr = @intFromPtr(transport_owner_seal),
                .prepared_storage_addr = @intFromPtr(&owner.storage),
                .reservation = reservation,
                .receipt = prepared.receipt,
            };

            switch (scenario) {
                .reserve_rollback => try std.testing.expectError(
                    error.InjectedFailure,
                    executePreparedRpcTerminalSink(request, stream_id, &owner.response, .after_response_reserve),
                ),
                .lease_rollback => try std.testing.expectError(
                    error.InjectedFailure,
                    executePreparedRpcTerminalSink(request, stream_id, &owner.response, .after_execution_lease),
                ),
                .response_epoch_exhausted => try std.testing.expectError(
                    error.IdentityExhausted,
                    executePreparedRpcTerminalSink(request, stream_id, &owner.response, .response_epoch_exhausted),
                ),
                .pending_ambiguity => {
                    const flags = c.fcntl(slot.current.client.fd, c.F.GETFL, @as(c_int, 0));
                    try std.testing.expect(flags >= 0);
                    const nonblocking: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
                    try std.testing.expectEqual(
                        @as(c_int, 0),
                        c.fcntl(slot.current.client.fd, c.F.SETFL, flags | nonblocking),
                    );
                    slot.current.client.pending_outbound = .{
                        .frame = try slot.current.client.allocator.alloc(u8, 1024 * 1024),
                        .stream_id = stream_id,
                    };
                    @memset(slot.current.client.pending_outbound.?.frame, 0xA5);
                    try std.testing.expectError(
                        error.WriteFailed,
                        executePreparedRpcTerminalSink(request, stream_id, &owner.response, .none),
                    );
                },
                .request_hard_failure => {
                    _ = c.close(wire_fds[1]);
                    peer_open = false;
                    socket_server.setNoSigPipe(slot.current.client.fd);
                    try std.testing.expectError(
                        error.WriteFailed,
                        executePreparedRpcTerminalSink(request, stream_id, &owner.response, .none),
                    );
                },
            }

            try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(&owner.storage));
            try std.testing.expectEqual(
                prepared_request_authority.SettlementReadiness.settled,
                try slot.current.cleanup_registry.preparedRequestSettlementReadiness(
                    reservation.cleanup,
                    identity,
                ),
            );
            switch (scenario) {
                .reserve_rollback, .lease_rollback => {
                    try std.testing.expect(slot.current.client.firstPoisonReason() == null);
                    try std.testing.expect(owner.response.pristineExact());
                },
                .response_epoch_exhausted => {
                    try std.testing.expectEqual(
                        client_poison.ConnectionReason.local_invariant_violation,
                        slot.current.client.firstPoisonReason().?,
                    );
                    try std.testing.expect(owner.response.pristineExact());
                    try std.testing.expect(try slot.current.cleanup_registry.rpcExecutionAuthoritiesTerminalForTest(
                        reservation.cleanup,
                        identity,
                    ));
                    var byte: [1]u8 = undefined;
                    // Exhaustion terminalizes before request execution: peer observes EOF with no
                    // request byte rather than a readable prefix.
                    try std.testing.expectEqual(@as(isize, 0), c.read(wire_fds[1], &byte, byte.len));
                },
                .pending_ambiguity, .request_hard_failure => try std.testing.expect(slot.current.client.firstPoisonReason() != null),
            }
            try slot.beginAttachmentDrop(&owner.binding, reservation, &owner.lease);
            try transport_owner_seal.terminalize(transport_incarnation);
            slot.finishActiveAttachmentDrop(&owner.binding, reservation, &owner.lease);
        }
    };
    inline for (.{
        Harness.Scenario.reserve_rollback,
        Harness.Scenario.lease_rollback,
        Harness.Scenario.response_epoch_exhausted,
        Harness.Scenario.pending_ambiguity,
        Harness.Scenario.request_hard_failure,
    }) |scenario| try Harness.run(scenario);
}

test "B3-3 private product wrapper writes exact request then terminal-settles both authorities" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var wire_fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &wire_fds),
    );
    var source = fixtureClient(allocator, 0xB33A0);
    source.fd = wire_fds[0];
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB33A0);
    defer slot.deinit();

    const Owner = struct {
        transport_marker: u8 = 0,
        storage: client_mod.PreparedBlockingRpcStorage = .{},
        response: RpcExecutedResponse = .{},
        binding: contract.PreparedAttachmentBinding = .{},
        lease: lease_mod.ConnectionLease = .{},
    };
    var owner: Owner = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(
        &owner.binding,
        &owner.lease,
        0xB33A1,
    );
    const identity = reservation.identity;
    const attach_receipt = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 0xB33A2,
        .request_id = 0xB33A3,
        .request_digest = 0xB33A4,
    }).?;
    try owner.binding.pairRequest(attach_receipt);
    try owner.binding.beginExecute(attach_receipt);
    const attach_executed = contract.ExecutedCallReceipt.fromPrepared(attach_receipt).?;
    const attach_accepted = contract.CorrelatedExecutedCall.init(
        attach_executed,
        attach_receipt.request_id,
    ).?;
    try slot.commitAttachmentBinding(
        &owner.binding,
        reservation,
        attach_accepted,
        77,
        &owner.lease,
    );

    const transport_incarnation: u64 = 0xB33A5;
    const transport_owner_seal = try slot.transportOwnerSeal(reservation);
    try contract.TransportOwnerSeal.initInPlace(
        transport_owner_seal,
        transport_incarnation,
        @intFromPtr(&owner),
        @sizeOf(Owner),
        @intFromPtr(&owner.transport_marker),
        @intFromPtr(&owner.storage),
    );
    const prepared = try prepareGenerationRequest(.{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .owner_addr = @intFromPtr(&owner),
        .owner_size = @sizeOf(Owner),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .bound_stream_id = 77,
        .reservation = reservation,
        .request = contract.RuntimeRequest.observation(),
    });
    const request: GenerationRequestAbort = .{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .reservation = reservation,
        .receipt = prepared.receipt,
    };

    const frame_alias: *RpcExecutedResponse = @ptrFromInt(prepared.canonical.descriptor.frame_addr);
    try std.testing.expectError(
        error.InvalidOwner,
        executePreparedRpcTerminalSink(request, 77, frame_alias, .none),
    );
    try std.testing.expect(!client_mod.Client.preparedBlockingRpcStorageSettled(&owner.storage));
    try std.testing.expectEqual(
        prepared_request_authority.SettlementReadiness.busy,
        try slot.current.cleanup_registry.preparedRequestSettlementReadiness(
            reservation.cleanup,
            identity,
        ),
    );

    const Peer = struct {
        fn run(fd: c.fd_t, expected: usize, observed: *usize) void {
            var buffer: [256]u8 = undefined;
            while (observed.* < expected) {
                const want = @min(buffer.len, expected - observed.*);
                const rc = c.read(fd, &buffer, want);
                if (rc < 0 and std.posix.errno(rc) == .INTR) continue;
                if (rc <= 0) break;
                observed.* += @intCast(rc);
            }
            _ = c.close(fd);
        }
    };
    var observed: usize = 0;
    const peer = try std.Thread.spawn(
        .{},
        Peer.run,
        .{ wire_fds[1], prepared.canonical.descriptor.frame_len, &observed },
    );
    try executePreparedRpcTerminalSink(request, 77, &owner.response, .none);
    peer.join();
    try std.testing.expectEqual(prepared.canonical.descriptor.frame_len, observed);
    try std.testing.expect(owner.response.terminalExact());
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(&owner.storage));
    try std.testing.expectEqual(
        prepared_request_authority.SettlementReadiness.settled,
        try slot.current.cleanup_registry.preparedRequestSettlementReadiness(
            reservation.cleanup,
            identity,
        ),
    );

    try slot.beginAttachmentDrop(&owner.binding, reservation, &owner.lease);
    try transport_owner_seal.terminalize(transport_incarnation);
    slot.finishActiveAttachmentDrop(&owner.binding, reservation, &owner.lease);
}

fn runB345RpcProduct(drift_kind: u8) !void {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var wire_fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &wire_fds),
    );
    var source = fixtureClient(allocator, 0xB3450);
    source.fd = wire_fds[0];
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB3450);
    defer slot.deinit();

    const Owner = struct {
        transport_marker: u8 = 0,
        storage: client_mod.PreparedBlockingRpcStorage = .{},
        response: RpcExecutedResponse = .{},
        terminal_response: RpcExecutedResponse = .{},
        binding: contract.PreparedAttachmentBinding = .{},
        lease: lease_mod.ConnectionLease = .{},
    };
    var owner: Owner = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(
        &owner.binding,
        &owner.lease,
        0xB3451,
    );
    const identity = reservation.identity;
    const attach_receipt = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 0xB3452,
        .request_id = 0xB3453,
        .request_digest = 0xB3454,
    }).?;
    try owner.binding.pairRequest(attach_receipt);
    try owner.binding.beginExecute(attach_receipt);
    try slot.commitAttachmentBinding(
        &owner.binding,
        reservation,
        contract.CorrelatedExecutedCall.init(
            contract.ExecutedCallReceipt.fromPrepared(attach_receipt).?,
            attach_receipt.request_id,
        ).?,
        91,
        &owner.lease,
    );
    const transport_incarnation: u64 = 0xB3455;
    const transport_owner_seal = try slot.transportOwnerSeal(reservation);
    try contract.TransportOwnerSeal.initWithRpcResponseInPlace(
        transport_owner_seal,
        transport_incarnation,
        @intFromPtr(&owner),
        @sizeOf(Owner),
        @intFromPtr(&owner.transport_marker),
        @intFromPtr(&owner.storage),
        @intFromPtr(&owner.response),
    );
    const prepared = try prepareGenerationRequest(.{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .owner_addr = @intFromPtr(&owner),
        .owner_size = @sizeOf(Owner),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .bound_stream_id = 91,
        .reservation = reservation,
        .request = contract.RuntimeRequest.observation(),
    });
    const request: GenerationRequestAbort = .{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .reservation = reservation,
        .receipt = prepared.receipt,
    };
    var foreign_source = fixtureClient(allocator, 0xB3460);
    var foreign_slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&foreign_slot, allocator, &foreign_source, 0xB3460);
    defer foreign_slot.deinit();
    const ForeignOwner = struct {
        transport_marker: u8 = 0,
        storage: client_mod.PreparedBlockingRpcStorage = .{},
        binding: contract.PreparedAttachmentBinding = .{},
        lease: lease_mod.ConnectionLease = .{},
    };
    var foreign_owner: ForeignOwner = .{};
    const foreign_reservation = try foreign_slot.reserveAttachmentBindingForTest(
        &foreign_owner.binding,
        &foreign_owner.lease,
        0xB3461,
    );
    const foreign_identity = foreign_reservation.identity;
    const foreign_attach_receipt = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 0xB3462,
        .request_id = 0xB3463,
        .request_digest = 0xB3464,
    }).?;
    try foreign_owner.binding.pairRequest(foreign_attach_receipt);
    try foreign_owner.binding.beginExecute(foreign_attach_receipt);
    try foreign_slot.commitAttachmentBinding(
        &foreign_owner.binding,
        foreign_reservation,
        contract.CorrelatedExecutedCall.init(
            contract.ExecutedCallReceipt.fromPrepared(foreign_attach_receipt).?,
            foreign_attach_receipt.request_id,
        ).?,
        92,
        &foreign_owner.lease,
    );
    const foreign_transport_incarnation: u64 = 0xB3465;
    const foreign_transport_seal = try foreign_slot.transportOwnerSeal(foreign_reservation);
    try contract.TransportOwnerSeal.initInPlace(
        foreign_transport_seal,
        foreign_transport_incarnation,
        @intFromPtr(&foreign_owner),
        @sizeOf(ForeignOwner),
        @intFromPtr(&foreign_owner.transport_marker),
        @intFromPtr(&foreign_owner.storage),
    );
    const foreign_prepared = try prepareGenerationRequest(.{
        .slot_addr = @intFromPtr(&foreign_slot),
        .slot_incarnation = foreign_identity.slot_incarnation,
        .node_incarnation = foreign_identity.node_incarnation,
        .host_id = foreign_identity.host_id,
        .pid = foreign_identity.pid,
        .process_nonce = foreign_identity.process_nonce,
        .transport_addr = @intFromPtr(&foreign_owner.transport_marker),
        .owner_addr = @intFromPtr(&foreign_owner),
        .owner_size = @sizeOf(ForeignOwner),
        .transport_incarnation = foreign_transport_incarnation,
        .owner_seal_addr = @intFromPtr(foreign_transport_seal),
        .prepared_storage_addr = @intFromPtr(&foreign_owner.storage),
        .bound_stream_id = 92,
        .reservation = foreign_reservation,
        .request = contract.RuntimeRequest.observation(),
    });
    const foreign_request: GenerationRequestAbort = .{
        .slot_addr = @intFromPtr(&foreign_slot),
        .slot_incarnation = foreign_identity.slot_incarnation,
        .node_incarnation = foreign_identity.node_incarnation,
        .host_id = foreign_identity.host_id,
        .pid = foreign_identity.pid,
        .process_nonce = foreign_identity.process_nonce,
        .transport_addr = @intFromPtr(&foreign_owner.transport_marker),
        .transport_incarnation = foreign_transport_incarnation,
        .owner_seal_addr = @intFromPtr(foreign_transport_seal),
        .prepared_storage_addr = @intFromPtr(&foreign_owner.storage),
        .reservation = foreign_reservation,
        .receipt = foreign_prepared.receipt,
    };
    const Peer = struct {
        fn readExact(fd: c.fd_t, bytes: []u8) bool {
            var offset: usize = 0;
            while (offset < bytes.len) {
                const rc = c.read(fd, bytes.ptr + offset, bytes.len - offset);
                if (rc < 0 and std.posix.errno(rc) == .INTR) continue;
                if (rc <= 0) return false;
                offset += @intCast(rc);
            }
            return true;
        }

        fn run(fd: c.fd_t, ok: *bool) void {
            defer _ = c.close(fd);
            var iteration: usize = 0;
            while (iteration < 65) : (iteration += 1) {
                var raw_header: [protocol.header_size]u8 = undefined;
                if (!readExact(fd, &raw_header)) return;
                const header = protocol.Header.decode(&raw_header) catch return;
                if (header.kind != .request or header.request_id == 0 or
                    header.payload_len > protocol.max_control_json) return;
                const payload = std.heap.page_allocator.alloc(u8, header.payload_len) catch return;
                defer std.heap.page_allocator.free(payload);
                if (!readExact(fd, payload)) return;
                const response = framing.encodeFrame(
                    std.heap.page_allocator,
                    .{ .kind = .response, .request_id = header.request_id },
                    "{\"result\":true}",
                ) catch return;
                defer std.heap.page_allocator.free(response);
                socket_server.writeAll(fd, response) catch return;
            }
            ok.* = true;
        }
    };
    var peer_ok = false;
    const peer = try std.Thread.spawn(.{}, Peer.run, .{ wire_fds[1], &peer_ok });
    const rpc_busy_evidence = rpcFreeEvidenceFixture(0xB3456);
    try std.testing.expect(slot.current.rpc_free_evidence.commitFreeCall(1, rpc_busy_evidence));
    try std.testing.expectError(error.Busy, beginGenerationRequestOwner(request, false));
    try std.testing.expect(slot.current.rpc_free_evidence.retireFreeCall(1, rpc_busy_evidence));
    slot.current.guarded_allocator.request_free_test_observer.rpc_publication_drift_kind = drift_kind;
    try executePreparedRpcCorrelatedResponseForTest(request, 91, &owner.response);
    try std.testing.expectEqual(rpc_executed_response.ByteSettlement.live, owner.response.settlement);
    try std.testing.expectError(
        error.AdminBusy,
        slot.beginAttachmentDrop(&owner.binding, reservation, &owner.lease),
    );
    const RpcFreeReentryProbe = struct {
        slot: *ClientSlot,
        same_request: GenerationRequestAbort,
        foreign_request: GenerationRequestAbort,
        binding: *contract.PreparedAttachmentBinding,
        reservation: AttachmentBindingReservation,
        lease: *lease_mod.ConnectionLease,
        same_busy: bool = false,
        foreign_busy: bool = false,
        drop_busy: bool = false,
        deinit_busy: bool = false,

        fn run(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (beginGenerationRequestOwner(self.same_request, false)) |owner_result| {
                endRegisteredNodeOperation(owner_result.operation);
            } else |err| {
                self.same_busy = err == error.Busy;
            }
            if (beginGenerationRequestOwner(self.foreign_request, false)) |owner_result| {
                endRegisteredNodeOperation(owner_result.operation);
            } else |err| {
                self.foreign_busy = err == error.Busy;
            }
            self.slot.beginAttachmentDrop(
                self.binding,
                self.reservation,
                self.lease,
            ) catch |err| {
                self.drop_busy = err == error.AdminBusy;
            };
            self.deinit_busy = self.slot.tryDeinit() == .busy;
        }
    };
    var reentry_probe: RpcFreeReentryProbe = .{
        .slot = &slot,
        .same_request = request,
        .foreign_request = foreign_request,
        .binding = &owner.binding,
        .reservation = reservation,
        .lease = &owner.lease,
    };
    const free_observer = &slot.current.guarded_allocator.request_free_test_observer;
    free_observer.target_addr = owner.response.payload_addr;
    free_observer.target_len = owner.response.payload_len;
    free_observer.descriptor_allocator_ptr = @intFromPtr(&slot.current.guarded_allocator);
    free_observer.descriptor_allocator_vtable = @intFromPtr(&GenerationGuardedAllocator.allocator_vtable);
    free_observer.rpc_free_reentry_context = &reentry_probe;
    free_observer.rpc_free_reentry_fn = RpcFreeReentryProbe.run;
    var borrow: rpc_executed_response.RpcResponseBorrow = .{};
    try beginRpcResponseBorrow(request, &owner.response, &borrow);
    try std.testing.expectError(
        error.AdminBusy,
        slot.beginAttachmentDrop(&owner.binding, reservation, &owner.lease),
    );
    try finishRpcResponseOwned(request, &owner.response, &borrow, .reusable);
    try std.testing.expect(free_observer.rpc_free_reentry_fired);
    try std.testing.expectEqual(@as(usize, 1), free_observer.entry_count);
    try std.testing.expect(free_observer.descriptor_exact);
    try std.testing.expect(reentry_probe.same_busy);
    try std.testing.expect(reentry_probe.foreign_busy);
    try std.testing.expect(reentry_probe.drop_busy);
    try std.testing.expect(reentry_probe.deinit_busy);
    free_observer.rpc_free_reentry_context = null;
    free_observer.rpc_free_reentry_fn = null;
    free_observer.target_addr = 0;
    free_observer.target_len = 0;
    try abortGenerationRequest(foreign_request);
    try foreign_slot.beginAttachmentDrop(
        &foreign_owner.binding,
        foreign_reservation,
        &foreign_owner.lease,
    );
    try foreign_transport_seal.terminalize(foreign_transport_incarnation);
    foreign_slot.finishActiveAttachmentDrop(
        &foreign_owner.binding,
        foreign_reservation,
        &foreign_owner.lease,
    );
    try std.testing.expect(owner.response.pristineExact());
    try std.testing.expect(slot.current.rpc_free_evidence.emptyExact());
    var repeated_index: usize = 0;
    while (repeated_index < 63) : (repeated_index += 1) {
        const repeated_prepared = try prepareGenerationRequest(.{
            .slot_addr = @intFromPtr(&slot),
            .slot_incarnation = identity.slot_incarnation,
            .node_incarnation = identity.node_incarnation,
            .host_id = identity.host_id,
            .pid = identity.pid,
            .process_nonce = identity.process_nonce,
            .transport_addr = @intFromPtr(&owner.transport_marker),
            .owner_addr = @intFromPtr(&owner),
            .owner_size = @sizeOf(Owner),
            .transport_incarnation = transport_incarnation,
            .owner_seal_addr = @intFromPtr(transport_owner_seal),
            .prepared_storage_addr = @intFromPtr(&owner.storage),
            .bound_stream_id = 91,
            .reservation = reservation,
            .request = contract.RuntimeRequest.observation(),
        });
        const repeated_request: GenerationRequestAbort = .{
            .slot_addr = @intFromPtr(&slot),
            .slot_incarnation = identity.slot_incarnation,
            .node_incarnation = identity.node_incarnation,
            .host_id = identity.host_id,
            .pid = identity.pid,
            .process_nonce = identity.process_nonce,
            .transport_addr = @intFromPtr(&owner.transport_marker),
            .transport_incarnation = transport_incarnation,
            .owner_seal_addr = @intFromPtr(transport_owner_seal),
            .prepared_storage_addr = @intFromPtr(&owner.storage),
            .reservation = reservation,
            .receipt = repeated_prepared.receipt,
        };
        try executeGenerationRpcSubstrate(.{
            .request = repeated_request,
            .bound_stream_id = 91,
        });
        try std.testing.expect(owner.response.pristineExact());
        try std.testing.expect(slot.current.rpc_free_evidence.emptyExact());
    }
    const terminal_prepared = try prepareGenerationRequest(.{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .owner_addr = @intFromPtr(&owner),
        .owner_size = @sizeOf(Owner),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .bound_stream_id = 91,
        .reservation = reservation,
        .request = contract.RuntimeRequest.observation(),
    });
    const terminal_request: GenerationRequestAbort = .{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .reservation = reservation,
        .receipt = terminal_prepared.receipt,
    };
    try executePreparedRpcCorrelatedResponseForTest(
        terminal_request,
        91,
        &owner.terminal_response,
    );
    var terminal_borrow: rpc_executed_response.RpcResponseBorrow = .{};
    try beginRpcResponseBorrow(
        terminal_request,
        &owner.terminal_response,
        &terminal_borrow,
    );
    try finishRpcResponseOwned(
        terminal_request,
        &owner.terminal_response,
        &terminal_borrow,
        .protocol_failure,
    );
    try std.testing.expect(owner.terminal_response.terminalExact());
    try std.testing.expect(slot.current.client.firstPoisonReason() != null);
    peer.join();
    try std.testing.expect(peer_ok);
    try std.testing.expectEqual(
        rpc_response_authority.SettlementReadiness.settled,
        try slot.current.cleanup_registry.rpcResponseSettlementReadiness(
            reservation.cleanup,
            identity,
        ),
    );
    const drop_busy_evidence = rpcFreeEvidenceFixture(0xB3457);
    try std.testing.expect(slot.current.rpc_free_evidence.commitFreeCall(2, drop_busy_evidence));
    try std.testing.expectError(
        error.AdminBusy,
        slot.beginAttachmentDrop(&owner.binding, reservation, &owner.lease),
    );
    try std.testing.expect(slot.current.rpc_free_evidence.retireFreeCall(2, drop_busy_evidence));
    try slot.beginAttachmentDrop(&owner.binding, reservation, &owner.lease);
    try transport_owner_seal.terminalize(transport_incarnation);
    slot.finishActiveAttachmentDrop(&owner.binding, reservation, &owner.lease);
}

test "B3-4/5 product publishes borrows and finishes 64 sequential correlated RPC responses" {
    try runB345RpcProduct(0);
}

test "B3-3 private product wrapper rejects pending callback response occupation" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var wire_fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &wire_fds),
    );
    defer _ = c.close(wire_fds[1]);
    var callback_allocator = B33DestinationOccupyingAllocator{ .parent = allocator };
    var source = fixtureClient(callback_allocator.allocator(), 0xB33B0);
    source.fd = wire_fds[0];
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB33B0);
    defer slot.deinit();

    const Owner = struct {
        transport_marker: u8 = 0,
        storage: client_mod.PreparedBlockingRpcStorage = .{},
        response: RpcExecutedResponse = .{},
        binding: contract.PreparedAttachmentBinding = .{},
        lease: lease_mod.ConnectionLease = .{},
    };
    var owner: Owner = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(
        &owner.binding,
        &owner.lease,
        0xB33B1,
    );
    const identity = reservation.identity;
    const attach_receipt = contract.PreparedCallReceipt.init(.{
        .transport_incarnation = 0xB33B2,
        .request_id = 0xB33B3,
        .request_digest = 0xB33B4,
    }).?;
    try owner.binding.pairRequest(attach_receipt);
    try owner.binding.beginExecute(attach_receipt);
    const attach_executed = contract.ExecutedCallReceipt.fromPrepared(attach_receipt).?;
    try slot.commitAttachmentBinding(
        &owner.binding,
        reservation,
        contract.CorrelatedExecutedCall.init(attach_executed, attach_receipt.request_id).?,
        78,
        &owner.lease,
    );

    const transport_incarnation: u64 = 0xB33B5;
    const transport_owner_seal = try slot.transportOwnerSeal(reservation);
    try contract.TransportOwnerSeal.initInPlace(
        transport_owner_seal,
        transport_incarnation,
        @intFromPtr(&owner),
        @sizeOf(Owner),
        @intFromPtr(&owner.transport_marker),
        @intFromPtr(&owner.storage),
    );
    const prepared = try prepareGenerationRequest(.{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .owner_addr = @intFromPtr(&owner),
        .owner_size = @sizeOf(Owner),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .bound_stream_id = 78,
        .reservation = reservation,
        .request = contract.RuntimeRequest.observation(),
    });
    const request: GenerationRequestAbort = .{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .reservation = reservation,
        .receipt = prepared.receipt,
    };

    const pending = try slot.current.client.allocator.dupe(u8, "older-frame");
    slot.current.client.pending_outbound = .{ .frame = pending, .stream_id = 78 };
    callback_allocator.target_addr = @intFromPtr(pending.ptr);
    callback_allocator.target_len = pending.len;
    callback_allocator.destination = &owner.response;
    callback_allocator.armed = true;
    try std.testing.expectError(
        error.InvalidOwner,
        executePreparedRpcTerminalSink(request, 78, &owner.response, .none),
    );
    callback_allocator.armed = false;
    try std.testing.expect(callback_allocator.fired);
    try std.testing.expectEqual(@as(u64, 0xA5), owner.response.owner_incarnation);
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(&owner.storage));
    try std.testing.expectEqual(
        prepared_request_authority.SettlementReadiness.settled,
        try slot.current.cleanup_registry.preparedRequestSettlementReadiness(
            reservation.cleanup,
            identity,
        ),
    );

    try slot.beginAttachmentDrop(&owner.binding, reservation, &owner.lease);
    try transport_owner_seal.terminalize(transport_incarnation);
    slot.finishActiveAttachmentDrop(&owner.binding, reservation, &owner.lease);
}

test "B3-2 product prepare rejects spawn before request publication" {
    try ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xB350);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xB350);
    defer slot.deinit();

    const Owner = struct {
        transport_marker: u8 = 0,
        storage: client_mod.PreparedBlockingRpcStorage = .{},
        binding: contract.PreparedAttachmentBinding = .{},
        lease: lease_mod.ConnectionLease = .{},
    };
    var owner: Owner = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(
        &owner.binding,
        &owner.lease,
        0xB351,
    );
    const transport_incarnation: u64 = 0xB352;
    const transport_owner_seal = try slot.transportOwnerSeal(reservation);
    try contract.TransportOwnerSeal.initInPlace(
        transport_owner_seal,
        transport_incarnation,
        @intFromPtr(&owner),
        @sizeOf(Owner),
        @intFromPtr(&owner.transport_marker),
        @intFromPtr(&owner.storage),
    );
    const before_request_id = slot.current.client.next_request_id;
    try std.testing.expect(slot.current.client.pending_outbound == null);
    try std.testing.expectError(error.Unauthorized, prepareGenerationRequest(.{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = reservation.identity.slot_incarnation,
        .node_incarnation = reservation.identity.node_incarnation,
        .host_id = reservation.identity.host_id,
        .pid = reservation.identity.pid,
        .process_nonce = reservation.identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .owner_addr = @intFromPtr(&owner),
        .owner_size = @sizeOf(Owner),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .bound_stream_id = 0,
        .reservation = reservation,
        .request = contract.RuntimeRequest.spawnFull(),
    }));
    try std.testing.expectEqual(before_request_id, slot.current.client.next_request_id);
    try std.testing.expect(slot.current.client.pending_outbound == null);
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(&owner.storage));
    try std.testing.expectEqual(
        prepared_request_authority.SettlementReadiness.settled,
        try slot.current.cleanup_registry.preparedRequestSettlementReadiness(
            reservation.cleanup,
            reservation.identity,
        ),
    );
    try transport_owner_seal.terminalize(transport_incarnation);
    try slot.abortAttachmentBinding(&owner.binding, reservation);
}

test "B3-0.4 guarded allocator rejects exact partial and overflow execution authority aliases" {
    try ClientSlot.initializeProcessRuntime();
    const Authority = enum { transaction, cleanup, expected_stage, completion };
    const Shape = enum { exact, left_partial, right_partial, overflow };
    inline for (std.enums.values(Authority)) |authority| {
        inline for (std.enums.values(Shape)) |shape| {
            const allocator = std.testing.allocator;
            const case_id: u128 = @as(u128, @intFromEnum(authority)) * 4 + @intFromEnum(shape);
            var source = fixtureClient(allocator, 0x2C3BD8 + case_id);
            var slot: ClientSlot = undefined;
            try ClientSlot.initInPlace(&slot, allocator, &source, 0x2C3BD8 + case_id);
            defer slot.deinit();

            var txn: PreparedExecutionTxn = .{};
            var cleanup: PreparedExecutionCleanup = undefined;
            var expected_stage: PreparedExecutionCleanup.CleanupStage = .guard;
            var completion: u8 = 0;
            const base, const size = switch (authority) {
                .transaction => .{ @intFromPtr(&txn), @sizeOf(PreparedExecutionTxn) },
                .cleanup => .{ @intFromPtr(&cleanup), @sizeOf(PreparedExecutionCleanup) },
                .expected_stage => .{ @intFromPtr(&expected_stage), @sizeOf(@TypeOf(expected_stage)) },
                .completion => .{ @intFromPtr(&completion), @sizeOf(@TypeOf(completion)) },
            };
            const target_addr, const target_len = switch (shape) {
                .exact => .{ base, size },
                .left_partial => .{ base - 1, 2 },
                .right_partial => .{ base + size - 1, 2 },
                .overflow => .{ std.math.maxInt(usize), 1 },
            };
            const allocation_len: usize = switch (shape) {
                .left_partial, .right_partial => 2,
                .exact, .overflow => 1,
            };
            const target: [*]u8 = @ptrFromInt(target_addr);
            var hostile = SnapshotOwnerAliasAllocator{ .target = target[0..target_len] };
            const guard = &slot.current.guarded_allocator;
            guard.parent = hostile.allocator();
            try std.testing.expect(guard.beginOperationGuard(&.{
                .{ .start = @intFromPtr(&txn), .len = @sizeOf(PreparedExecutionTxn) },
                .{ .start = @intFromPtr(&cleanup), .len = @sizeOf(PreparedExecutionCleanup) },
                .{ .start = @intFromPtr(&expected_stage), .len = @sizeOf(@TypeOf(expected_stage)) },
                .{ .start = @intFromPtr(&completion), .len = @sizeOf(@TypeOf(completion)) },
            }));
            defer guard.endOperationGuard();

            const result = guard.allocator().alloc(u8, allocation_len);
            try std.testing.expectError(error.OutOfMemory, result);
            try std.testing.expect(guard.operation_alias_rejected);
            try std.testing.expectEqual(@as(usize, 1), hostile.alloc_calls);
            try std.testing.expectEqual(@as(usize, 0), hostile.free_calls);
        }
    }
}

test "B3-0.3 forged cleanup completion states cannot skip canonical guard cleanup" {
    try ClientSlot.initializeProcessRuntime();
    inline for ([_]PreparedExecutionCleanup.CleanupLifecycle{ .settled, .finishing }) |forged| {
        const allocator = std.testing.allocator;
        var source = fixtureClient(allocator, 0x2C3BDC + @as(u128, @intFromEnum(forged)));
        var slot: ClientSlot = undefined;
        try ClientSlot.initInPlace(
            &slot,
            allocator,
            &source,
            0x2C3BDC + @as(u128, @intFromEnum(forged)),
        );
        defer slot.deinit();

        var protected_byte: u8 = 0;
        const guard = &slot.current.guarded_allocator;
        try std.testing.expect(guard.beginOperationGuard(&.{.{
            .start = @intFromPtr(&protected_byte),
            .len = @sizeOf(u8),
        }}));
        var cleanup: PreparedExecutionCleanup = undefined;
        cleanup.init();
        cleanup.lifecycle = forged;
        var scope: client_mod.Client.GenerationAllocatorScope = .{};
        var ledger: response_payload_allocation.Ledger = .{};
        const outcome = cleanup.finish(.guard, &slot.current.client, guard, &scope, &ledger);
        switch (outcome) {
            .fail_stop => |reason| try std.testing.expectEqual(
                PreparedExecutionCleanup.CleanupFailure.descriptor_drift,
                reason,
            ),
            .clean, .deferred_reentry => return error.TestUnexpectedResult,
        }
        try std.testing.expect(!guard.operation_guard_active);
        try std.testing.expectEqual(
            PreparedExecutionCleanup.CleanupLifecycle.fail_stop,
            cleanup.lifecycle,
        );
    }
}

test "B3-0.1 pre-wire issuer exhaustion settles request terminal with exact first poison" {
    const b3_issuer_oracle = @import("b3_issuer_oracle.zig");
    const Case = enum {
        allocator_scope,
        response_incarnation,
        allocator_scope_with_content_drift,
        response_incarnation_with_content_drift,
    };
    const PreparedRequestFreeProbe = struct {
        parent: std.mem.Allocator,
        slot: ?*ClientSlot = null,
        reservation: ?AttachmentBindingReservation = null,
        canonical: ?prepared_request_authority.Prepared = null,
        target_addr: usize = 0,
        target_len: usize = 0,
        exact_free_count: usize = 0,
        authority_was_executing: bool = false,
        guard_was_closed_before_backing_free: bool = false,
        allocated_bytes: usize = 0,
        freed_bytes: usize = 0,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            } };
        }
        fn arm(self: *@This(), slot: *ClientSlot, reservation: AttachmentBindingReservation, canonical: prepared_request_authority.Prepared) void {
            self.slot = slot;
            self.reservation = reservation;
            self.canonical = canonical;
            self.target_addr = canonical.descriptor.frame_addr;
            self.target_len = canonical.descriptor.frame_len;
            slot.current.guarded_allocator.request_free_test_observer = .{
                .target_addr = canonical.descriptor.frame_addr,
                .target_len = canonical.descriptor.frame_len,
                .descriptor_allocator_ptr = canonical.descriptor.allocator_ptr,
                .descriptor_allocator_vtable = canonical.descriptor.allocator_vtable,
            };
        }
        fn expectExactOnceBeforeAuthoritySettlement(self: *const @This()) !void {
            try std.testing.expectEqual(@as(usize, 1), self.exact_free_count);
            try std.testing.expect(self.authority_was_executing);
            try std.testing.expect(self.guard_was_closed_before_backing_free);
            try std.testing.expectEqual(
                @as(usize, 1),
                self.slot.?.current.guarded_allocator.request_free_test_observer.entry_count,
            );
            try std.testing.expect(
                self.slot.?.current.guarded_allocator.request_free_test_observer.descriptor_exact,
            );
        }
        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const result = self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr) orelse
                return null;
            self.allocated_bytes += len;
            return result;
        }
        fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr))
                return false;
            if (new_len >= memory.len)
                self.allocated_bytes += new_len - memory.len
            else
                self.freed_bytes += memory.len - new_len;
            return true;
        }
        fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const result = self.parent.vtable.remap(
                self.parent.ptr,
                memory,
                alignment,
                new_len,
                ret_addr,
            ) orelse return null;
            if (new_len >= memory.len)
                self.allocated_bytes += new_len - memory.len
            else
                self.freed_bytes += memory.len - new_len;
            return result;
        }
        fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (@intFromPtr(memory.ptr) == self.target_addr and memory.len == self.target_len) {
                self.exact_free_count += 1;
                const reservation = self.reservation.?;
                self.authority_was_executing = self.slot.?.current.cleanup_registry.executingRequestMatches(
                    reservation.cleanup,
                    reservation.identity,
                    self.canonical.?,
                ) catch false;
                self.guard_was_closed_before_backing_free =
                    !self.slot.?.current.guarded_allocator.operation_guard_active;
            }
            self.freed_bytes += memory.len;
            self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
        }
    };
    inline for (std.enums.values(Case)) |case| {
        try ClientSlot.initializeProcessRuntime();
        const allocator = std.testing.allocator;
        var request_free = PreparedRequestFreeProbe{ .parent = allocator };
        const case_offset: u128 = @intFromEnum(case);
        var wire_fds: [2]c.fd_t = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &wire_fds),
        );
        defer _ = c.close(wire_fds[1]);
        var source = fixtureClient(request_free.allocator(), 0x2C3BE0 + case_offset);
        source.fd = wire_fds[0];
        var slot: ClientSlot = undefined;
        try ClientSlot.initInPlace(
            &slot,
            allocator,
            &source,
            0x2C3BE0 + case_offset,
        );
        var slot_live = true;
        defer if (slot_live) slot.deinit();

        const Owner = struct {
            transport_marker: u8 = 0,
            storage: client_mod.PreparedBlockingRpcStorage = .{},
            response: executed_response_mod.ExecutedResponse = .{},
            binding: contract.PreparedAttachmentBinding = .{},
            lease: lease_mod.ConnectionLease = .{},
        };
        var owner: Owner = .{};
        const reservation = try slot.reserveAttachmentBindingForTest(
            &owner.binding,
            &owner.lease,
            0x2C3BF0 + case_offset,
        );
        const transport_incarnation: u64 = 0x2C3B10 + @as(u64, @intCast(case_offset));
        const transport_owner_seal = try slot.transportOwnerSeal(reservation);
        try contract.TransportOwnerSeal.initInPlace(
            transport_owner_seal,
            transport_incarnation,
            @intFromPtr(&owner),
            @sizeOf(Owner),
            @intFromPtr(&owner.transport_marker),
            @intFromPtr(&owner.storage),
        );
        const identity = reservation.identity;
        const prepared = try prepareGenerationRequest(.{
            .slot_addr = @intFromPtr(&slot),
            .slot_incarnation = identity.slot_incarnation,
            .node_incarnation = identity.node_incarnation,
            .host_id = identity.host_id,
            .pid = identity.pid,
            .process_nonce = identity.process_nonce,
            .transport_addr = @intFromPtr(&owner.transport_marker),
            .owner_addr = @intFromPtr(&owner),
            .owner_size = @sizeOf(Owner),
            .transport_incarnation = transport_incarnation,
            .owner_seal_addr = @intFromPtr(transport_owner_seal),
            .prepared_storage_addr = @intFromPtr(&owner.storage),
            .bound_stream_id = 0,
            .reservation = reservation,
            .request = contract.RuntimeRequest.attachController(),
        });
        request_free.arm(&slot, reservation, prepared.canonical);
        try owner.binding.pairRequest(prepared.receipt);
        try owner.binding.beginExecute(prepared.receipt);

        const saved_response_issuer = generation_response_incarnation_issuer.load(.monotonic);
        defer generation_response_incarnation_issuer.store(saved_response_issuer, .monotonic);
        switch (case) {
            .allocator_scope, .allocator_scope_with_content_drift => slot.current.client.generation_allocator_scope_epoch =
                std.math.maxInt(u64),
            .response_incarnation, .response_incarnation_with_content_drift => generation_response_incarnation_issuer.store(
                std.math.maxInt(u64),
                .monotonic,
            ),
        }
        const content_drifted = case == .allocator_scope_with_content_drift or
            case == .response_incarnation_with_content_drift;
        if (content_drifted) {
            const frame: [*]u8 = @ptrFromInt(prepared.canonical.descriptor.frame_addr);
            frame[prepared.canonical.descriptor.frame_len - 1] ^= 1;
        }
        var actual_error: ?GenerationExecuteError = null;
        if (executeGenerationRequest(.{
            .request = .{
                .slot_addr = @intFromPtr(&slot),
                .slot_incarnation = identity.slot_incarnation,
                .node_incarnation = identity.node_incarnation,
                .host_id = identity.host_id,
                .pid = identity.pid,
                .process_nonce = identity.process_nonce,
                .transport_addr = @intFromPtr(&owner.transport_marker),
                .transport_incarnation = transport_incarnation,
                .owner_seal_addr = @intFromPtr(transport_owner_seal),
                .prepared_storage_addr = @intFromPtr(&owner.storage),
                .reservation = reservation,
                .receipt = prepared.receipt,
            },
            .response_out_addr = @intFromPtr(&owner.response),
            .owner_addr = @intFromPtr(&owner),
            .owner_size = @sizeOf(Owner),
        })) |_| return error.TestUnexpectedResult else |err| actual_error = err;
        const expected_error: GenerationExecuteError = if (content_drifted)
            error.ProtocolError
        else
            error.IdentityExhausted;
        try std.testing.expect(actual_error.? == expected_error);
        var unexpected_wire: [1]u8 = undefined;
        const wire_read = c.recv(
            wire_fds[1],
            &unexpected_wire,
            unexpected_wire.len,
            std.posix.MSG.DONTWAIT,
        );
        const wire_empty = wire_read == 0 or
            (wire_read == -1 and std.posix.errno(wire_read) == .AGAIN);
        try std.testing.expect(wire_empty);
        try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(&owner.storage));
        try std.testing.expectEqual(
            prepared_request_authority.SettlementReadiness.settled,
            try slot.current.cleanup_registry.preparedRequestSettlementReadiness(
                reservation.cleanup,
                identity,
            ),
        );
        const authority_terminal = if (slot.current.cleanup_registry.publishPreparedRequest(
            reservation.cleanup,
            identity,
            prepared.canonical,
        )) false else |err| err == error.InvalidState;
        try std.testing.expect(authority_terminal);
        try std.testing.expect(slot.current.client.unusable);
        try std.testing.expectEqual(
            @import("client_poison.zig").ConnectionReason.local_invariant_violation,
            slot.current.client.firstPoisonReason().?,
        );
        try request_free.expectExactOnceBeforeAuthoritySettlement();
        try transport_owner_seal.terminalize(transport_incarnation);
        try slot.abortExecutedAttachmentBinding(
            &owner.binding,
            reservation,
            contract.ExecutedCallReceipt.fromPrepared(prepared.receipt).?,
        );
        const observer = slot.current.guarded_allocator.request_free_test_observer;
        var operation_receipts_exact = observer.registered_operation_begin_count != 0 and
            observer.registered_operation_begin_count == observer.registered_operation_end_count and
            observer.registered_operation_begin_count <= observer.registered_operation_begin_receipts.len and
            observer.registered_operation_active_receipt == 0 and
            !observer.registered_operation_receipt_drift;
        if (operation_receipts_exact) {
            for (0..observer.registered_operation_begin_count) |index| {
                if (observer.registered_operation_begin_receipts[index] == 0 or
                    observer.registered_operation_begin_receipts[index] !=
                        observer.registered_operation_end_receipts[index])
                {
                    operation_receipts_exact = false;
                    break;
                }
            }
        }
        const connection_local_invariant = slot.current.client.unusable;
        const first_poison_local_invariant = slot.current.client.firstPoisonReason() ==
            .local_invariant_violation;
        const allocator_scope_final = observer.allocator_scope_restored or
            case == .allocator_scope or case == .allocator_scope_with_content_drift;
        slot.deinit();
        slot_live = false;
        try std.testing.expectEqual(@as(usize, 1), observer.cleanup_count);
        try std.testing.expect(observer.guard_inactive);
        try std.testing.expect(allocator_scope_final);
        try std.testing.expect(observer.client_scope_restored);
        try std.testing.expect(observer.ledger_ended);
        try std.testing.expect(observer.cleanup_settled);
        try std.testing.expect(operation_receipts_exact);
        try std.testing.expectEqual(request_free.allocated_bytes, request_free.freed_bytes);
        const scenario: b3_issuer_oracle.Scenario = if (content_drifted)
            .cleanup_drift
        else
            .clean;
        try std.testing.expectEqualDeep(
            b3_issuer_oracle.expected(scenario),
            b3_issuer_oracle.Observation{
                .scenario = scenario,
                .request_prepared_only = wire_empty,
                .storage_settled = client_mod.Client.preparedBlockingRpcStorageSettled(&owner.storage),
                .authority_terminal = authority_terminal,
                .connection_local_invariant = connection_local_invariant,
                .public_error = if (actual_error.? == error.IdentityExhausted)
                    .identity_exhausted
                else
                    .protocol_error,
                .first_poison_local_invariant = first_poison_local_invariant,
                .response_pristine = owner.response.pristine(),
                .request_free_exact_once = request_free.exact_free_count == 1,
                .payload_never_observed = observer.response_payload_addr == 0 and
                    observer.response_payload_len == 0,
                .final_zero = observer.cleanup_count == 1 and observer.guard_inactive and
                    allocator_scope_final and observer.client_scope_restored and
                    observer.ledger_ended and observer.cleanup_settled and
                    operation_receipts_exact and request_free.allocated_bytes == request_free.freed_bytes,
            },
        );
    }
}

test "B3-0.2 prepared execution transaction is final-address linear and rolls back once" {
    try ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0x2C3B20);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0x2C3B20);
    defer slot.deinit();

    const Owner = struct {
        transport_marker: u8 = 0,
        storage: client_mod.PreparedBlockingRpcStorage = .{},
        binding: contract.PreparedAttachmentBinding = .{},
        lease: lease_mod.ConnectionLease = .{},
    };
    var owner: Owner = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(
        &owner.binding,
        &owner.lease,
        0x2C3B21,
    );
    const transport_incarnation: u64 = 0x2C3B22;
    const transport_owner_seal = try slot.transportOwnerSeal(reservation);
    try contract.TransportOwnerSeal.initInPlace(
        transport_owner_seal,
        transport_incarnation,
        @intFromPtr(&owner),
        @sizeOf(Owner),
        @intFromPtr(&owner.transport_marker),
        @intFromPtr(&owner.storage),
    );
    const identity = reservation.identity;
    const prepared = try prepareGenerationRequest(.{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .owner_addr = @intFromPtr(&owner),
        .owner_size = @sizeOf(Owner),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .bound_stream_id = 0,
        .reservation = reservation,
        .request = contract.RuntimeRequest.attachController(),
    });
    const request: GenerationRequestAbort = .{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .reservation = reservation,
        .receipt = prepared.receipt,
    };

    const stale_admission = try beginGenerationRequestOwner(request, false);
    var stale_txn: PreparedExecutionTxn = .{};
    try stale_txn.initBeforeBeginExecute(
        stale_admission.operation,
        request,
        identity,
        prepared.canonical,
    );
    endRegisteredNodeOperation(stale_admission.operation);
    try std.testing.expectError(
        error.InvalidOwner,
        stale_txn.revalidatePreWire(stale_admission.operation),
    );
    try std.testing.expect(std.meta.eql(
        prepared.canonical,
        (try slot.current.cleanup_registry.preparedRequestForReceipt(
            reservation.cleanup,
            identity,
            request.transport_addr,
            request.transport_incarnation,
            request.receipt,
        )).?,
    ));

    const admission = try beginGenerationRequestOwner(request, false);
    defer endRegisteredNodeOperation(admission.operation);
    const operation = admission.operation;

    var occupied_phase: PreparedExecutionTxn = .{};
    occupied_phase.phase = .settled;
    try std.testing.expectError(
        error.InvalidOwner,
        occupied_phase.initBeforeBeginExecute(operation, request, identity, prepared.canonical),
    );
    var occupied_settlement: PreparedExecutionTxn = .{};
    occupied_settlement.settlement = PreparedExecutionSettlement.reusable();
    try std.testing.expectError(
        error.InvalidOwner,
        occupied_settlement.initBeforeBeginExecute(operation, request, identity, prepared.canonical),
    );
    var raw_value: u16 = @intFromEnum(PreparedExecutionPhase.settled) + 1;
    while (raw_value <= std.math.maxInt(u8)) : (raw_value += 1) {
        var invalid_phase: PreparedExecutionTxn = .{};
        @as(*u8, @ptrCast(&invalid_phase.phase)).* = @intCast(raw_value);
        try std.testing.expectError(
            error.InvalidOwner,
            invalid_phase.initBeforeBeginExecute(operation, request, identity, prepared.canonical),
        );
    }
    raw_value = @intFromEnum(PreparedExecutionSettlementTag.fail_stop_required) + 1;
    while (raw_value <= std.math.maxInt(u8)) : (raw_value += 1) {
        var invalid_settlement: PreparedExecutionTxn = .{};
        @as(*u8, @ptrCast(&invalid_settlement.settlement.tag)).* = @intCast(raw_value);
        try std.testing.expectError(
            error.InvalidOwner,
            invalid_settlement.initBeforeBeginExecute(operation, request, identity, prepared.canonical),
        );
    }
    inline for (.{ PreparedExecutionSettlementTag.pending, .reusable }) |tag| {
        var reason: u16 = 1;
        while (reason <= std.math.maxInt(u8)) : (reason += 1) {
            var invalid_reason: PreparedExecutionTxn = .{};
            invalid_reason.settlement = .{ .tag = tag, .reason_raw = @intCast(reason) };
            try std.testing.expectError(
                error.InvalidOwner,
                invalid_reason.initBeforeBeginExecute(operation, request, identity, prepared.canonical),
            );
        }
    }
    inline for (.{
        .{ PreparedExecutionSettlementTag.terminal, std.meta.fields(client_poison.ConnectionReason).len },
        .{ PreparedExecutionSettlementTag.fail_stop_required, std.meta.fields(FailStopReason).len },
    }) |case| {
        var reason: u16 = case[1];
        while (reason <= std.math.maxInt(u8)) : (reason += 1) {
            var invalid_reason: PreparedExecutionTxn = .{};
            invalid_reason.settlement = .{ .tag = case[0], .reason_raw = @intCast(reason) };
            try std.testing.expectError(
                error.InvalidOwner,
                invalid_reason.initBeforeBeginExecute(operation, request, identity, prepared.canonical),
            );
        }
    }
    var txn: PreparedExecutionTxn = .{};
    try txn.initBeforeBeginExecute(operation, request, identity, prepared.canonical);
    var copied = txn;
    try std.testing.expectError(error.InvalidOwner, copied.revalidatePreWire(operation));
    var foreign_operation = operation;
    foreign_operation.operation_id +%= 1;
    try std.testing.expectError(error.InvalidOwner, txn.revalidatePreWire(foreign_operation));
    txn.commitBeginExecute(operation);
    if (builtin.os.tag == .macos) {
        const child = std.c.fork();
        if (child < 0) return error.TestUnexpectedResult;
        if (child == 0) {
            _ = std.c.close(2);
            var corrupt = txn;
            corrupt.self_addr = 0;
            corrupt.ensureSettledOrFailStop(operation);
            std.c._exit(3);
        }
        var child_status: c_int = 0;
        while (true) {
            const waited = std.c.waitpid(child, &child_status, 0);
            if (waited == child) break;
            if (waited < 0 and std.posix.errno(waited) == .INTR) continue;
            return error.TestUnexpectedResult;
        }
        const wait_status: u32 = @bitCast(child_status);
        try std.testing.expect(std.c.W.IFSIGNALED(wait_status));
    }
    try std.testing.expectError(error.ProtocolError, copied.rollbackPreWire(operation));
    try std.testing.expectEqual(
        SettlementOutcome.reusable,
        try txn.rollbackPreWire(operation),
    );
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(&owner.storage));
    try std.testing.expectError(error.ProtocolError, txn.rollbackPreWire(operation));
    txn.ensureSettledOrFailStop(operation);

    try transport_owner_seal.terminalize(transport_incarnation);
    try slot.abortAttachmentBinding(&owner.binding, reservation);
}

test "B3-0.2 registered node operation registry bounds capacity and normalizes permanent identity exhaustion before publication" {
    try ClientSlot.initializeProcessRuntime();
    const saved_next = next_registered_node_operation_id;
    defer next_registered_node_operation_id = saved_next;
    const lookup: RegisteredNodeLookup = .{
        .slot_addr = 1,
        .slot_incarnation = 1,
        .node = .{ .address = 1 },
    };
    var reservations: [max_registered_node_operations]RegisteredNodeOperationReservation = undefined;
    var reserved_count: usize = 0;
    defer while (reserved_count > 0) {
        reserved_count -= 1;
        abortRegisteredNodeOperationReservation(reservations[reserved_count]);
    };
    for (&reservations) |*reservation| {
        reservation.* = try reserveRegisteredNodeOperation(lookup);
        reserved_count += 1;
    }
    try std.testing.expectError(error.Busy, reserveRegisteredNodeOperation(lookup));
    while (reserved_count > 0) {
        reserved_count -= 1;
        abortRegisteredNodeOperationReservation(reservations[reserved_count]);
    }

    next_registered_node_operation_id = std.math.maxInt(u64);
    try std.testing.expectError(error.Busy, reserveRegisteredNodeOperation(lookup));
    for (registered_node_operations) |entry|
        try std.testing.expectEqual(RegisteredNodeOperationEntry.State.empty, entry.state);
}

test "B3-0.2 fork child rejects an inherited operation receipt before the inherited mutex" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try ClientSlot.initializeProcessRuntime();
    const inherited: RegisteredNodeOperation = .{
        .node = @ptrFromInt(@alignOf(ClientNode)),
        .registry_index = 0,
        .operation_id = 1,
        .pid = currentPid(),
    };
    const Case = enum { begin, resolve, end };
    inline for (std.enums.values(Case)) |case| {
        while (!registered_node_operation_mutex.tryLock()) std.atomic.spinLoopHint();
        const child = std.c.fork();
        if (child < 0) {
            registered_node_operation_mutex.unlock();
            return error.TestUnexpectedResult;
        }
        if (child == 0) switch (case) {
            .begin => {
                _ = beginRegisteredNodeOperation(.{
                    .slot_addr = 1,
                    .slot_incarnation = 1,
                    .node = .{ .address = @alignOf(ClientNode) },
                }) catch |err| std.c._exit(if (err == error.InvalidOwner) 0 else 2);
                std.c._exit(3);
            },
            .resolve => std.c._exit(if (resolveRegisteredNodeOperation(inherited) == null) 0 else 2),
            .end => {
                _ = std.c.close(2);
                endRegisteredNodeOperation(inherited);
                std.c._exit(3);
            },
        };
        registered_node_operation_mutex.unlock();

        var status: c_int = 0;
        var attempts: usize = 0;
        var reaped = false;
        while (attempts < 2000) : (attempts += 1) {
            const waited = std.c.waitpid(child, &status, std.c.W.NOHANG);
            if (waited == child) {
                reaped = true;
                break;
            }
            if (waited < 0 and std.posix.errno(waited) != .INTR)
                return error.TestUnexpectedResult;
            var delay_fd = std.c.pollfd{ .fd = -1, .events = 0, .revents = 0 };
            _ = std.c.poll(@ptrCast(&delay_fd), 0, 1);
        }
        if (!reaped) {
            _ = std.c.kill(child, std.c.SIG.KILL);
            _ = std.c.waitpid(child, &status, 0);
            return error.TestUnexpectedResult;
        }
        const wait_status: u32 = @bitCast(status);
        switch (case) {
            .begin, .resolve => {
                try std.testing.expect(std.c.W.IFEXITED(wait_status));
                try std.testing.expectEqual(@as(u8, 0), std.c.W.EXITSTATUS(wait_status));
            },
            .end => try std.testing.expect(std.c.W.IFSIGNALED(wait_status)),
        }
    }
}

test "B3-0.2 registered operations contend across slots while sibling teardown converges" {
    try ClientSlot.initializeProcessRuntime();
    var failed: std.atomic.Value(bool) = .init(false);
    var live_receipt_held: std.atomic.Value(bool) = .init(false);
    var sibling_teardown_done: std.atomic.Value(bool) = .init(false);
    var teardown_observed_live_receipt: std.atomic.Value(bool) = .init(false);
    const Worker = struct {
        fn waitFor(
            condition: *std.atomic.Value(bool),
            failure: *std.atomic.Value(bool),
        ) bool {
            var attempts: usize = 0;
            while (!condition.load(.acquire) and !failure.load(.acquire) and attempts < 2000) : (attempts += 1) {
                var delay_fd = std.c.pollfd{ .fd = -1, .events = 0, .revents = 0 };
                _ = std.c.poll(@ptrCast(&delay_fd), 0, 1);
            }
            if (!condition.load(.acquire)) {
                failure.store(true, .release);
                return false;
            }
            return true;
        }

        fn run(
            index: usize,
            failure: *std.atomic.Value(bool),
            live_receipt: *std.atomic.Value(bool),
            teardown_done: *std.atomic.Value(bool),
            teardown_observed_live: *std.atomic.Value(bool),
        ) void {
            var source = fixtureClient(std.testing.allocator, 0x2C3C00 + index);
            var slot: ClientSlot = undefined;
            ClientSlot.initInPlace(
                &slot,
                std.testing.allocator,
                &source,
                0x2C3C00 + index,
            ) catch {
                failure.store(true, .release);
                return;
            };
            var slot_live = true;
            defer if (slot_live) slot.deinit();

            if (index == 0) {
                const operation = slot.beginRegisteredClientOperation() catch {
                    failure.store(true, .release);
                    return;
                };
                const receipt: RegisteredNodeOperation = .{
                    .node = operation.node,
                    .registry_index = operation.registry_index,
                    .operation_id = operation.operation_id,
                    .pid = operation.pid,
                };
                live_receipt.store(true, .release);
                if (!waitFor(teardown_done, failure)) {
                    slot.endRegisteredClientOperation(operation);
                    live_receipt.store(false, .release);
                    return;
                }
                if (resolveRegisteredNodeOperation(receipt) != operation.node)
                    failure.store(true, .release);
                slot.endRegisteredClientOperation(operation);
                live_receipt.store(false, .release);
                return;
            }

            if (index == 1) {
                if (!waitFor(live_receipt, failure)) return;
                slot.deinit();
                slot_live = false;
                teardown_observed_live.store(live_receipt.load(.acquire), .release);
                teardown_done.store(true, .release);
                return;
            }

            for (0..64) |_| {
                const operation = slot.beginRegisteredClientOperation() catch {
                    failure.store(true, .release);
                    return;
                };
                const receipt: RegisteredNodeOperation = .{
                    .node = operation.node,
                    .registry_index = operation.registry_index,
                    .operation_id = operation.operation_id,
                    .pid = operation.pid,
                };
                if (resolveRegisteredNodeOperation(receipt) != operation.node) {
                    failure.store(true, .release);
                    slot.endRegisteredClientOperation(operation);
                    return;
                }
                slot.endRegisteredClientOperation(operation);
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index|
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{
            index,
            &failed,
            &live_receipt_held,
            &sibling_teardown_done,
            &teardown_observed_live_receipt,
        });
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expect(sibling_teardown_done.load(.acquire));
    try std.testing.expect(teardown_observed_live_receipt.load(.acquire));
    try std.testing.expect(!live_receipt_held.load(.acquire));
}

test "B3-0.2 callback cannot redirect prepared execution cleanup through a spliced descriptor" {
    const MutatingAllocator = struct {
        const vtable: std.mem.Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };

        parent: std.mem.Allocator,
        txn_addr: usize = 0,
        target_addr: usize = 0,
        target_len: usize = 0,
        exact_free_count: usize = 0,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
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
            if (@intFromPtr(memory.ptr) == self.target_addr and memory.len == self.target_len) {
                self.exact_free_count += 1;
                const txn: *PreparedExecutionTxn = @ptrFromInt(self.txn_addr);
                txn.canonical_prepared.descriptor.storage_addr = 0x1000;
                txn.prepared_identity.descriptor.storage_addr = 0x1000;
            }
            self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
        }
    };

    try ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var mutating_allocator = MutatingAllocator{ .parent = allocator };
    var source = fixtureClient(mutating_allocator.allocator(), 0x2C3B28);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0x2C3B28);
    defer slot.deinit();

    const Owner = struct {
        transport_marker: u8 = 0,
        storage: client_mod.PreparedBlockingRpcStorage = .{},
        binding: contract.PreparedAttachmentBinding = .{},
        lease: lease_mod.ConnectionLease = .{},
    };
    var owner: Owner = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(
        &owner.binding,
        &owner.lease,
        0x2C3B29,
    );
    const transport_incarnation: u64 = 0x2C3B2A;
    const transport_owner_seal = try slot.transportOwnerSeal(reservation);
    try contract.TransportOwnerSeal.initInPlace(
        transport_owner_seal,
        transport_incarnation,
        @intFromPtr(&owner),
        @sizeOf(Owner),
        @intFromPtr(&owner.transport_marker),
        @intFromPtr(&owner.storage),
    );
    const identity = reservation.identity;
    const prepared = try prepareGenerationRequest(.{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .owner_addr = @intFromPtr(&owner),
        .owner_size = @sizeOf(Owner),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .bound_stream_id = 0,
        .reservation = reservation,
        .request = contract.RuntimeRequest.attachController(),
    });
    const request: GenerationRequestAbort = .{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .reservation = reservation,
        .receipt = prepared.receipt,
    };
    const admission = try beginGenerationRequestOwner(request, false);
    defer endRegisteredNodeOperation(admission.operation);
    var txn: PreparedExecutionTxn = .{};
    try txn.initBeforeBeginExecute(admission.operation, request, identity, prepared.canonical);
    txn.commitBeginExecute(admission.operation);
    mutating_allocator.txn_addr = @intFromPtr(&txn);
    mutating_allocator.target_addr = prepared.canonical.descriptor.frame_addr;
    mutating_allocator.target_len = prepared.canonical.descriptor.frame_len;

    try std.testing.expectError(error.ProtocolError, txn.rollbackPreWire(admission.operation));
    try std.testing.expectEqual(@as(usize, 1), mutating_allocator.exact_free_count);
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(&owner.storage));
    try std.testing.expectEqual(
        prepared_request_authority.SettlementReadiness.settled,
        try slot.current.cleanup_registry.preparedRequestSettlementReadiness(
            reservation.cleanup,
            identity,
        ),
    );
    try std.testing.expectEqual(PreparedExecutionPhase.settled, txn.phase);
    try std.testing.expectEqual(
        FailStopReason.authority_drift,
        txn.settlement.failStopReason() orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqual(
        client_poison.ConnectionReason.local_invariant_violation,
        slot.current.client.firstPoisonReason().?,
    );

    try transport_owner_seal.terminalize(transport_incarnation);
    try slot.abortAttachmentBinding(&owner.binding, reservation);
}

test "B3-0.2 terminal settlement preserves the canonical first poison" {
    try ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0x2C3B30);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0x2C3B30);
    defer slot.deinit();

    const Owner = struct {
        transport_marker: u8 = 0,
        storage: client_mod.PreparedBlockingRpcStorage = .{},
        binding: contract.PreparedAttachmentBinding = .{},
        lease: lease_mod.ConnectionLease = .{},
    };
    var owner: Owner = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(
        &owner.binding,
        &owner.lease,
        0x2C3B31,
    );
    const transport_incarnation: u64 = 0x2C3B32;
    const transport_owner_seal = try slot.transportOwnerSeal(reservation);
    try contract.TransportOwnerSeal.initInPlace(
        transport_owner_seal,
        transport_incarnation,
        @intFromPtr(&owner),
        @sizeOf(Owner),
        @intFromPtr(&owner.transport_marker),
        @intFromPtr(&owner.storage),
    );
    const identity = reservation.identity;
    const prepared = try prepareGenerationRequest(.{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .owner_addr = @intFromPtr(&owner),
        .owner_size = @sizeOf(Owner),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .bound_stream_id = 0,
        .reservation = reservation,
        .request = contract.RuntimeRequest.attachController(),
    });
    const request: GenerationRequestAbort = .{
        .slot_addr = @intFromPtr(&slot),
        .slot_incarnation = identity.slot_incarnation,
        .node_incarnation = identity.node_incarnation,
        .host_id = identity.host_id,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .transport_addr = @intFromPtr(&owner.transport_marker),
        .transport_incarnation = transport_incarnation,
        .owner_seal_addr = @intFromPtr(transport_owner_seal),
        .prepared_storage_addr = @intFromPtr(&owner.storage),
        .reservation = reservation,
        .receipt = prepared.receipt,
    };

    const admission = try beginGenerationRequestOwner(request, false);
    defer endRegisteredNodeOperation(admission.operation);
    const operation = admission.operation;
    var txn: PreparedExecutionTxn = .{};
    try txn.initBeforeBeginExecute(operation, request, identity, prepared.canonical);
    txn.commitBeginExecute(operation);
    slot.current.client.poison(.outbound_write_ambiguous);
    try std.testing.expectEqual(
        client_mod.Client.CanonicalPreparedAbortOutcome.reusable,
        try slot.current.client.abortPreparedBlockingRpcStorageCanonical(
            &owner.storage,
            identityFromCanonical(prepared.canonical),
        ),
    );
    const outcome = try txn.settlePostExecuteTerminal(
        operation,
        .transport_read_failure,
    );
    switch (outcome) {
        .terminal => |reason| try std.testing.expectEqual(
            client_poison.ConnectionReason.outbound_write_ambiguous,
            reason,
        ),
        else => return error.TestUnexpectedResult,
    }
    txn.finishOrFailStop(operation, outcome);
    try std.testing.expectError(error.ProtocolError, txn.settlePostExecuteReusable(operation));
    try std.testing.expectError(
        error.InvalidState,
        slot.current.cleanup_registry.publishPreparedRequest(
            reservation.cleanup,
            identity,
            prepared.canonical,
        ),
    );

    try transport_owner_seal.terminalize(transport_incarnation);
    try slot.abortAttachmentBinding(&owner.binding, reservation);
}

test "B3-0.2 every explicit settlement method closes one exact lifecycle" {
    const Case = enum { unbegun_guard, post_execute_reusable, issuer_terminal };
    inline for (std.enums.values(Case)) |case| {
        try ClientSlot.initializeProcessRuntime();
        const allocator = std.testing.allocator;
        const offset: u128 = @intFromEnum(case);
        var source = fixtureClient(allocator, 0x2C3B40 + offset);
        var slot: ClientSlot = undefined;
        try ClientSlot.initInPlace(&slot, allocator, &source, 0x2C3B40 + offset);
        defer slot.deinit();

        const Owner = struct {
            transport_marker: u8 = 0,
            storage: client_mod.PreparedBlockingRpcStorage = .{},
            binding: contract.PreparedAttachmentBinding = .{},
            lease: lease_mod.ConnectionLease = .{},
        };
        var owner: Owner = .{};
        const reservation = try slot.reserveAttachmentBindingForTest(
            &owner.binding,
            &owner.lease,
            0x2C3B50 + offset,
        );
        const transport_incarnation: u64 = 0x2C3B60 + @as(u64, @intCast(offset));
        const transport_owner_seal = try slot.transportOwnerSeal(reservation);
        try contract.TransportOwnerSeal.initInPlace(
            transport_owner_seal,
            transport_incarnation,
            @intFromPtr(&owner),
            @sizeOf(Owner),
            @intFromPtr(&owner.transport_marker),
            @intFromPtr(&owner.storage),
        );
        const identity = reservation.identity;
        const prepared = try prepareGenerationRequest(.{
            .slot_addr = @intFromPtr(&slot),
            .slot_incarnation = identity.slot_incarnation,
            .node_incarnation = identity.node_incarnation,
            .host_id = identity.host_id,
            .pid = identity.pid,
            .process_nonce = identity.process_nonce,
            .transport_addr = @intFromPtr(&owner.transport_marker),
            .owner_addr = @intFromPtr(&owner),
            .owner_size = @sizeOf(Owner),
            .transport_incarnation = transport_incarnation,
            .owner_seal_addr = @intFromPtr(transport_owner_seal),
            .prepared_storage_addr = @intFromPtr(&owner.storage),
            .bound_stream_id = 0,
            .reservation = reservation,
            .request = contract.RuntimeRequest.attachController(),
        });
        const request: GenerationRequestAbort = .{
            .slot_addr = @intFromPtr(&slot),
            .slot_incarnation = identity.slot_incarnation,
            .node_incarnation = identity.node_incarnation,
            .host_id = identity.host_id,
            .pid = identity.pid,
            .process_nonce = identity.process_nonce,
            .transport_addr = @intFromPtr(&owner.transport_marker),
            .transport_incarnation = transport_incarnation,
            .owner_seal_addr = @intFromPtr(transport_owner_seal),
            .prepared_storage_addr = @intFromPtr(&owner.storage),
            .reservation = reservation,
            .receipt = prepared.receipt,
        };
        const admission = try beginGenerationRequestOwner(request, false);
        defer endRegisteredNodeOperation(admission.operation);
        const operation = admission.operation;
        var txn: PreparedExecutionTxn = .{};
        try txn.initBeforeBeginExecute(operation, request, identity, prepared.canonical);

        switch (case) {
            .unbegun_guard => {
                txn.ensureSettledOrFailStop(operation);
                txn.finishOrFailStop(operation, .reusable);
                try std.testing.expect((try slot.current.cleanup_registry.preparedRequestForReceipt(
                    reservation.cleanup,
                    identity,
                    request.transport_addr,
                    request.transport_incarnation,
                    request.receipt,
                )) != null);
                try abortGenerationRequest(request);
            },
            .post_execute_reusable => {
                txn.commitBeginExecute(operation);
                try std.testing.expectEqual(
                    client_mod.Client.CanonicalPreparedAbortOutcome.reusable,
                    try slot.current.client.abortPreparedBlockingRpcStorageCanonical(
                        &owner.storage,
                        identityFromCanonical(prepared.canonical),
                    ),
                );
                const outcome = try txn.settlePostExecuteReusable(operation);
                try std.testing.expect(outcome == .reusable);
                txn.finishOrFailStop(operation, outcome);
                try slot.current.cleanup_registry.publishPreparedRequest(
                    reservation.cleanup,
                    identity,
                    prepared.canonical,
                );
                try slot.current.cleanup_registry.settlePreparedRequest(
                    reservation.cleanup,
                    identity,
                    prepared.canonical,
                    false,
                );
            },
            .issuer_terminal => {
                txn.commitBeginExecute(operation);
                const outcome = try txn.retireIssuerExhausted(operation);
                switch (outcome) {
                    .terminal => |reason| try std.testing.expectEqual(
                        client_poison.ConnectionReason.local_invariant_violation,
                        reason,
                    ),
                    else => return error.TestUnexpectedResult,
                }
                txn.finishOrFailStop(operation, outcome);
                try std.testing.expectError(
                    error.InvalidState,
                    slot.current.cleanup_registry.publishPreparedRequest(
                        reservation.cleanup,
                        identity,
                        prepared.canonical,
                    ),
                );
            },
        }

        try transport_owner_seal.terminalize(transport_incarnation);
        try slot.abortAttachmentBinding(&owner.binding, reservation);
    }
}

test "CR3a-2c2b2 Client owned backing aliases reject before permit generation" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xFD);
    try source.parser.buf.appendSlice(allocator, &([_]u8{0} ** 64));
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xFD);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x4D);
    try slot.current.cleanup_registry.bindStream(reservation.cleanup, reservation.identity, 9);
    defer {
        slot.current.cleanup_registry.beginBoundDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("owned backing alias cleanup registry drifted");
        slot.current.cleanup_registry.completeActiveDrop(
            reservation.cleanup,
            reservation.identity,
            9,
        ) catch @panic("owned backing alias cleanup registry completion drifted");
        slot.current.pin_owner.cleanup_pin_count -= 1;
        binding.lifecycle = .terminal;
    }
    const scratch_addr = std.mem.alignForward(
        usize,
        @intFromPtr(slot.current.client.parser.buf.items.ptr),
        @alignOf(client_mod.EndedPurgeScratch),
    );
    const aliased_scratch: *client_mod.EndedPurgeScratch = @ptrFromInt(scratch_addr);
    var prepared: EndedPurgePreparation = .{};
    const generation_before = slot.current.next_operation_generation;
    try std.testing.expectError(error.InvalidOwner, slot.prepareEndedPurge(
        11,
        reservation,
        9,
        .{ .event_index = 0 },
        aliased_scratch,
        &prepared,
    ));
    try std.testing.expectEqual(generation_before, slot.current.next_operation_generation);
    try std.testing.expect(slot.streamOperationPermitIdle());
    try std.testing.expect(slot.current.client.firstPoisonReason() == null);
}

test "CR3a-2c2b2 ClientSlot registry enforces exact cap and address ABA reuse" {
    comptime {
        if (@typeInfo(@TypeOf(client_slot_registry)).array.len != max_live_client_slots)
            @compileError("ClientSlot registry storage drifted from max_live_client_slots");
    }
    defer {
        while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
        defer client_slot_registry_mutex.unlock();
        client_slot_registry = [_]ClientSlotRegistryEntry{.{}} ** max_live_client_slots;
    }

    for (0..max_live_client_slots) |index| try registerClientSlot(.{
        .live = true,
        .slot_addr = index + 1,
        .node_addr = max_live_client_slots + index + 1,
        .slot_incarnation = index + 1,
        .node_incarnation = index + 1,
        .owner_thread_incarnation = 1,
    });
    try std.testing.expectError(error.IdentityExhausted, registerClientSlot(.{
        .live = true,
        .slot_addr = max_live_client_slots + 1,
        .node_addr = max_live_client_slots * 2 + 1,
        .slot_incarnation = max_live_client_slots + 1,
        .node_incarnation = max_live_client_slots + 1,
        .owner_thread_incarnation = 1,
    }));

    const old = ClientSlotRegistryEntry{
        .live = true,
        .slot_addr = 1,
        .node_addr = max_live_client_slots + 1,
        .slot_incarnation = 1,
        .node_incarnation = 1,
        .owner_thread_incarnation = 1,
    };
    try std.testing.expect(unregisterClientSlot(old));
    const replacement = ClientSlotRegistryEntry{
        .live = true,
        .slot_addr = old.slot_addr,
        .node_addr = old.node_addr + max_live_client_slots,
        .slot_incarnation = old.slot_incarnation + max_live_client_slots,
        .node_incarnation = old.node_incarnation + max_live_client_slots,
        .owner_thread_incarnation = 2,
    };
    try registerClientSlot(replacement);
    try std.testing.expect(!unregisterClientSlot(old));
    try std.testing.expect(clientSlotRegistryEntry(replacement.slot_addr) == null);
    publishClientSlot(replacement);
    var published = replacement;
    published.ready = true;
    try std.testing.expect(std.meta.eql(
        published,
        clientSlotRegistryEntry(replacement.slot_addr).?,
    ));
    try std.testing.expect(unregisterClientSlot(published));
}

test "CR3a-2c2b2 ClientSlot registry serializes bounded concurrent reuse" {
    defer {
        while (!client_slot_registry_mutex.tryLock()) std.atomic.spinLoopHint();
        defer client_slot_registry_mutex.unlock();
        client_slot_registry = [_]ClientSlotRegistryEntry{.{}} ** max_live_client_slots;
    }
    var failed: std.atomic.Value(bool) = .init(false);
    const Worker = struct {
        fn run(worker: usize, failure: *std.atomic.Value(bool)) void {
            for (0..64) |generation| {
                const incarnation = generation + 1;
                const reserved = ClientSlotRegistryEntry{
                    .live = true,
                    .slot_addr = worker + 1,
                    .node_addr = 1024 + worker,
                    .slot_incarnation = incarnation,
                    .node_incarnation = incarnation,
                    .owner_thread_incarnation = worker + 1,
                };
                registerClientSlot(reserved) catch {
                    failure.store(true, .release);
                    return;
                };
                publishClientSlot(reserved);
                var published = reserved;
                published.ready = true;
                const observed = clientSlotRegistryEntry(reserved.slot_addr) orelse {
                    failure.store(true, .release);
                    return;
                };
                if (!std.meta.eql(observed, published) or !unregisterClientSlot(published)) {
                    failure.store(true, .release);
                    return;
                }
                if (clientSlotRegistryEntry(reserved.slot_addr) != null) {
                    failure.store(true, .release);
                    return;
                }
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index|
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ index, &failed });
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
}

test "CR3a-2c2 stale stream operation permit rejects before deinitialized node access" {
    const allocator = std.testing.allocator;
    var source = fixtureClient(allocator, 0xF6);
    var slot: ClientSlot = undefined;
    try ClientSlot.initInPlace(&slot, allocator, &source, 0xF6);
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: lease_mod.ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x46);
    const permit = try slot.prepareStreamOperationPermit(
        .ended_purge,
        0x4000,
        11,
        reservation.identity,
    );
    try slot.consumeStreamOperationPermit(permit);
    try slot.abortAttachmentBinding(&binding, reservation);
    slot.deinit();

    try std.testing.expectError(
        error.InvalidStreamOperationPermit,
        slot.abortStreamOperationPermit(permit),
    );
    try std.testing.expectError(
        error.InvalidStreamOperationPermit,
        slot.consumeStreamOperationPermit(permit),
    );
}
