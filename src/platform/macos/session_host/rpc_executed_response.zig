//! Final-address byte owner for one correlated blocking RPC response.
//!
//! Protocol lifecycle remains in `rpc_response_authority.zig`. This leaf owns only immutable
//! response identity, allocation provenance, lexical borrow evidence, and exact-once byte
//! settlement. It deliberately has no dependency on the registry, ledger, Client, or decoder.

const std = @import("std");
const contract = @import("generation_attachment_contract.zig");
const owner_seal = @import("external_owner_seal.zig");
const builtin = @import("builtin");
const c = std.c;

const DecoderProofLossHook = struct {
    const record_size: usize = 11;

    armed: bool = false,
    nonce: u64 = 0,
    stage_fd: c.fd_t = -1,

    fn writeStage(self: *const @This(), stage: u8) void {
        if (!self.armed) return;
        var bytes: [record_size]u8 = undefined;
        bytes[0] = 1;
        bytes[1] = 6;
        std.mem.writeInt(u64, bytes[2..10], self.nonce, .little);
        bytes[10] = stage;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const written = c.write(self.stage_fd, bytes[offset..].ptr, bytes.len - offset);
            if (written < 0 and std.posix.errno(written) == .INTR) continue;
            if (written <= 0) @panic("decoder proof-loss marker write failed");
            offset += @intCast(written);
        }
    }
};

threadlocal var decoder_proof_loss_hook: if (builtin.is_test) DecoderProofLossHook else void =
    if (builtin.is_test) .{} else {};

pub const testing = if (builtin.is_test) struct {
    pub fn armBorrowSealDriftAfterCallback(nonce: u64, stage_fd: c.fd_t) void {
        if (decoder_proof_loss_hook.armed or nonce == 0 or stage_fd < 3)
            @panic("invalid decoder proof-loss hook authority");
        decoder_proof_loss_hook = .{ .armed = true, .nonce = nonce, .stage_fd = stage_fd };
    }
} else struct {};

pub const max_owned_response_bytes: usize = 256 * 1024;

pub const ByteSettlement = enum(u8) {
    pristine,
    live,
    free_committed,
    terminal_clean,
    terminal_no_free,
};

pub const AllocationProvenance = struct {
    ledger_addr: usize,
    guard_addr: usize,
    node_addr: usize,
    operation_incarnation: u64,
    index: u16,
    generation: u64,

    pub fn valid(self: @This()) bool {
        return self.ledger_addr != 0 and self.guard_addr != 0 and self.node_addr != 0 and
            self.operation_incarnation != 0 and self.generation != 0;
    }
};

/// Scalar copy of the RPC authority canonical. It is evidence only: no authority pointer is
/// dereferenced by this module.
pub const Identity = struct {
    authority_addr: usize,
    registry_incarnation: u64,
    binding: contract.BindingIdentity,
    transport_addr: usize,
    transport_incarnation: u64,
    family: contract.RequestFamily,
    tag: contract.RuntimeRequestTag,
    request_id: u64,
    request_digest: u64,
    response_epoch: u64,
    destination_addr: usize,

    pub fn valid(self: @This()) bool {
        return self.authority_addr != 0 and self.registry_incarnation != 0 and self.binding.valid() and
            self.transport_addr != 0 and self.transport_incarnation != 0 and
            contract.requestFamilyRawValid(&self.family) and
            contract.runtimeRequestTagRawValid(&self.tag) and
            contract.requestFamilyAllowed(self.tag, self.family) and self.request_id != 0 and
            self.request_digest != 0 and self.response_epoch != 0 and self.destination_addr != 0;
    }
};

pub const RpcExecutedResponse = struct {
    self_addr: usize = 0,
    owner_incarnation: u64 = 0,
    identity: Identity = std.mem.zeroes(Identity),
    provenance: AllocationProvenance = std.mem.zeroes(AllocationProvenance),
    allocator_present: u8 = 0,
    allocator_ptr: usize = 0,
    allocator_vtable: usize = 0,
    payload_addr: usize = 0,
    payload_len: usize = 0,
    payload_digest: owner_seal.Digest = [_]u8{0} ** 32,
    settlement: ByteSettlement = .pristine,
    terminal_evidence: owner_seal.Digest = [_]u8{0} ** 32,
    seal: owner_seal.Digest = [_]u8{0} ** 32,

    pub const Error = error{
        DestinationOccupied,
        InvalidIdentity,
        InvalidPayload,
        InvalidOwner,
        InvalidReceipt,
        InvalidTransaction,
        AliasedStorage,
    };

    pub fn pristineExact(self: *const @This()) bool {
        return std.mem.eql(u8, std.mem.asBytes(self), std.mem.asBytes(&RpcExecutedResponse{}));
    }

    pub fn liveScalarIdentityExact(self: *const @This(), identity: Identity) bool {
        return self.liveScalarExact(identity);
    }

    pub fn initLiveInPlace(
        out: *RpcExecutedResponse,
        identity: Identity,
        allocator: std.mem.Allocator,
        payload: []u8,
        provenance: AllocationProvenance,
    ) Error!void {
        if (!out.pristineExact()) return error.DestinationOccupied;
        if (!identity.valid() or identity.destination_addr != @intFromPtr(out) or
            identity.response_epoch == std.math.maxInt(u64))
            return error.InvalidIdentity;
        if (!provenance.valid() or payload.len == 0 or payload.len > max_owned_response_bytes)
            return error.InvalidPayload;
        const payload_range = byteRange(@intFromPtr(payload.ptr), payload.len) orelse
            return error.InvalidPayload;
        const owner_range = byteRange(@intFromPtr(out), @sizeOf(RpcExecutedResponse)).?;
        if (rangesOverlap(payload_range, owner_range)) return error.AliasedStorage;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .owner_incarnation = identity.response_epoch,
            .identity = identity,
            .provenance = provenance,
            .allocator_present = 1,
            .allocator_ptr = @intFromPtr(allocator.ptr),
            .allocator_vtable = @intFromPtr(allocator.vtable),
            .payload_addr = @intFromPtr(payload.ptr),
            .payload_len = payload.len,
            .payload_digest = digestBytes("maru.rpc-response-payload.v1", payload),
            .settlement = .live,
        };
        out.seal = responseSeal(out);
    }

    pub fn prepareBorrowInit(
        self: *const RpcExecutedResponse,
        identity: Identity,
        out: *RpcResponseBorrow,
        permit: *PreparedBorrowInit,
    ) Error!void {
        if (!out.pristineExact() or !permit.pristineExact()) return error.InvalidReceipt;
        if (!self.liveExact(identity)) return error.InvalidOwner;
        const payload_range = byteRange(self.payload_addr, self.payload_len).?;
        inline for (.{
            byteRange(@intFromPtr(out), @sizeOf(RpcResponseBorrow)).?,
            byteRange(@intFromPtr(permit), @sizeOf(PreparedBorrowInit)).?,
        }) |range| if (rangesOverlap(payload_range, range)) return error.AliasedStorage;
        permit.* = .{
            .self_addr = @intFromPtr(permit),
            .response_addr = @intFromPtr(self),
            .borrow_addr = @intFromPtr(out),
            .identity = identity,
            .payload_digest = self.payload_digest,
        };
        permit.seal = preparedBorrowSeal(permit);
    }

    pub fn commitBorrowReceiptNoFail(
        self: *const RpcExecutedResponse,
        identity: Identity,
        out: *RpcResponseBorrow,
        permit: *PreparedBorrowInit,
    ) void {
        if (!self.liveExact(identity) or !out.pristineExact() or
            !permit.exactFor(self, identity, out))
            @panic("RPC response borrow receipt commit mismatch");
        out.* = .{
            .self_addr = @intFromPtr(out),
            .response_addr = @intFromPtr(self),
            .registry_incarnation = identity.registry_incarnation,
            .binding = identity.binding,
            .transport_addr = identity.transport_addr,
            .transport_incarnation = identity.transport_incarnation,
            .request_id = identity.request_id,
            .request_digest = identity.request_digest,
            .response_epoch = identity.response_epoch,
            .payload_digest = self.payload_digest,
            .live = 1,
        };
        out.seal = borrowSeal(out);
        permit.* = .{};
    }

    pub fn prepareFinish(
        self: *const RpcExecutedResponse,
        identity: Identity,
        borrow: *const RpcResponseBorrow,
        out: *RpcResponseFinishTxn,
    ) Error!void {
        if (!out.pristineExact()) return error.InvalidTransaction;
        if (!self.liveExact(identity) or !borrow.exactFor(self, identity))
            return error.InvalidReceipt;
        const payload_range = byteRange(self.payload_addr, self.payload_len).?;
        inline for (.{
            byteRange(@intFromPtr(borrow), @sizeOf(RpcResponseBorrow)).?,
            byteRange(@intFromPtr(out), @sizeOf(RpcResponseFinishTxn)).?,
        }) |range| if (rangesOverlap(payload_range, range)) return error.AliasedStorage;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .response_addr = @intFromPtr(self),
            .response_epoch = identity.response_epoch,
            .allocator_present = 1,
            .allocator_ptr = self.allocator_ptr,
            .allocator_vtable = self.allocator_vtable,
            .payload_addr = self.payload_addr,
            .payload_len = self.payload_len,
            .payload_digest = self.payload_digest,
            .provenance = self.provenance,
            .stage = .prepared,
        };
        out.seal = finishSeal(out);
    }

    /// Moves the only cleanup capability into the final-address finish transaction. No callback
    /// occurs here; callers may publish external free evidence before invoking `freeCaptured`.
    pub fn commitFreeNoFail(
        self: *RpcExecutedResponse,
        identity: Identity,
        borrow: *RpcResponseBorrow,
        txn: *RpcResponseFinishTxn,
    ) void {
        if (!self.liveExact(identity) or !borrow.exactFor(self, identity) or
            !txn.preparedExactFor(self, identity))
            @panic("RPC response free commit authority mismatch");
        self.allocator_present = 0;
        self.allocator_ptr = 0;
        self.allocator_vtable = 0;
        self.payload_addr = 0;
        self.payload_len = 0;
        self.provenance = std.mem.zeroes(AllocationProvenance);
        self.settlement = .free_committed;
        self.seal = responseSeal(self);
        borrow.live = 0;
        borrow.seal = borrowSeal(borrow);
        txn.stage = .free_committed;
        txn.seal = finishSeal(txn);
    }

    pub fn finishCleanNoFail(self: *RpcExecutedResponse, txn: *RpcResponseFinishTxn) void {
        if (!self.freeCommittedExact(txn.response_epoch) or !txn.freedOnceExactFor(self))
            @panic("RPC response clean finish authority mismatch");
        self.terminal_evidence = txn.terminal_evidence;
        self.settlement = .terminal_clean;
        self.seal = responseSeal(self);
        txn.stage = .consumed;
        txn.seal = finishSeal(txn);
    }

    pub fn prepareReusableRearm(
        self: *const RpcExecutedResponse,
        txn: *const RpcResponseFinishTxn,
        out: *PreparedReusableRearmPermit,
    ) Error!void {
        if (!out.pristineExact()) return error.InvalidTransaction;
        if (!self.freeCommittedExact(txn.response_epoch) or !txn.freedOnceExactFor(self))
            return error.InvalidTransaction;
        var projected_response = self.*;
        var projected_txn = txn.*;
        projected_response.terminal_evidence = projected_txn.terminal_evidence;
        projected_response.settlement = .terminal_clean;
        projected_response.seal = responseSeal(&projected_response);
        projected_txn.stage = .consumed;
        projected_txn.seal = finishSeal(&projected_txn);
        out.* = .{
            .self_addr = @intFromPtr(out),
            .response_addr = @intFromPtr(self),
            .old_identity = self.identity,
            .old_epoch = self.owner_incarnation,
            .expected_terminal_clean_owner_seal = projected_response.seal,
            .expected_consumed_finish_digest = projected_txn.seal,
        };
    }

    pub fn commitReusableRearmNoFail(
        self: *RpcExecutedResponse,
        txn: *const RpcResponseFinishTxn,
        permit: *PreparedReusableRearmPermit,
    ) void {
        if (!permit.exactFor(self, txn))
            @panic("RPC response reusable rearm permit mismatch");
        permit.consumed_raw = 1;
        self.* = .{};
    }

    pub fn reusableRearmReady(
        self: *const RpcExecutedResponse,
        txn: *const RpcResponseFinishTxn,
        permit: *const PreparedReusableRearmPermit,
    ) bool {
        return permit.exactFor(self, txn);
    }

    /// Closes a live owner without dereferencing or freeing its payload when lexical alias
    /// preflight cannot prove that the captured allocation is safe to call back into.
    pub fn abandonLiveNoFree(
        self: *RpcExecutedResponse,
        identity: Identity,
    ) Error!void {
        if (!self.liveScalarExact(identity)) return error.InvalidOwner;
        const evidence = digestBytes("maru.rpc-response-terminal-no-free.v1", &self.seal);
        self.allocator_present = 0;
        self.allocator_ptr = 0;
        self.allocator_vtable = 0;
        self.payload_addr = 0;
        self.payload_len = 0;
        self.provenance = std.mem.zeroes(AllocationProvenance);
        self.settlement = .terminal_no_free;
        self.terminal_evidence = evidence;
        self.seal = responseSeal(self);
    }

    pub fn terminalNoFreeInPlace(
        out: *RpcExecutedResponse,
        identity: Identity,
        evidence: owner_seal.Digest,
    ) Error!void {
        if (!out.pristineExact()) return error.DestinationOccupied;
        if (!identity.valid() or identity.destination_addr != @intFromPtr(out) or
            std.mem.allEqual(u8, &evidence, 0))
            return error.InvalidIdentity;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .owner_incarnation = identity.response_epoch,
            .identity = identity,
            .settlement = .terminal_no_free,
            .terminal_evidence = evidence,
        };
        out.seal = responseSeal(out);
    }

    /// Publishes a pointer-free terminal owner only after an external final-address cleanup
    /// transaction has proved that its allocator callback returned coherently.
    pub fn terminalCleanAfterPublicationFailureInPlace(
        out: *RpcExecutedResponse,
        identity: Identity,
        evidence: owner_seal.Digest,
    ) Error!void {
        if (!out.pristineExact()) return error.DestinationOccupied;
        if (!identity.valid() or identity.destination_addr != @intFromPtr(out) or
            std.mem.allEqual(u8, &evidence, 0))
            return error.InvalidIdentity;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .owner_incarnation = identity.response_epoch,
            .identity = identity,
            .settlement = .terminal_clean,
            .terminal_evidence = evidence,
        };
        out.seal = responseSeal(out);
    }

    pub fn terminalExact(self: *const @This()) bool {
        return byteSettlementRawValid(&self.settlement) and self.finalAddressExact() and
            (self.settlement == .terminal_clean or self.settlement == .terminal_no_free) and
            self.allocator_present == 0 and self.allocator_ptr == 0 and
            self.allocator_vtable == 0 and self.payload_addr == 0 and self.payload_len == 0 and
            !std.mem.allEqual(u8, &self.terminal_evidence, 0) and
            std.mem.eql(u8, &self.seal, &responseSeal(self));
    }

    fn finalAddressExact(self: *const @This()) bool {
        return self.self_addr == @intFromPtr(self) and self.owner_incarnation != 0 and
            self.owner_incarnation == self.identity.response_epoch and self.identity.valid();
    }

    fn liveExact(self: *const @This(), identity: Identity) bool {
        if (!self.liveScalarExact(identity)) return false;
        const payload = payloadSlice(self.payload_addr, self.payload_len) orelse return false;
        return std.mem.eql(u8, &self.payload_digest, &digestBytes("maru.rpc-response-payload.v1", payload));
    }

    fn liveScalarExact(self: *const @This(), identity: Identity) bool {
        return byteSettlementRawValid(&self.settlement) and self.finalAddressExact() and
            std.meta.eql(self.identity, identity) and self.settlement == .live and
            self.allocator_present == 1 and self.allocator_ptr != 0 and
            self.allocator_vtable != 0 and self.payload_addr != 0 and
            self.payload_len != 0 and self.payload_len <= max_owned_response_bytes and
            self.provenance.valid() and !std.mem.allEqual(u8, &self.payload_digest, 0) and
            std.mem.allEqual(u8, &self.terminal_evidence, 0) and
            std.mem.eql(u8, &self.seal, &responseSeal(self));
    }

    fn freeCommittedExact(self: *const @This(), epoch: u64) bool {
        return byteSettlementRawValid(&self.settlement) and self.finalAddressExact() and
            self.owner_incarnation == epoch and
            self.settlement == .free_committed and self.allocator_present == 0 and
            self.allocator_ptr == 0 and self.allocator_vtable == 0 and
            self.payload_addr == 0 and self.payload_len == 0 and
            !std.mem.allEqual(u8, &self.payload_digest, 0) and
            std.mem.eql(u8, &self.seal, &responseSeal(self));
    }
};

pub const PreparedReusableRearmPermit = struct {
    self_addr: usize = 0,
    response_addr: usize = 0,
    old_identity: Identity = std.mem.zeroes(Identity),
    old_epoch: u64 = 0,
    expected_terminal_clean_owner_seal: owner_seal.Digest = [_]u8{0} ** 32,
    expected_consumed_finish_digest: owner_seal.Digest = [_]u8{0} ** 32,
    consumed_raw: u8 = 0,

    pub fn pristineExact(self: *const @This()) bool {
        return std.mem.eql(u8, std.mem.asBytes(self), std.mem.asBytes(&PreparedReusableRearmPermit{}));
    }

    fn exactFor(
        self: *const @This(),
        response: *const RpcExecutedResponse,
        txn: *const RpcResponseFinishTxn,
    ) bool {
        return self.self_addr == @intFromPtr(self) and self.response_addr == @intFromPtr(response) and
            self.old_epoch != 0 and self.old_epoch == response.owner_incarnation and
            std.meta.eql(self.old_identity, response.identity) and self.consumed_raw == 0 and
            response.settlement == .terminal_clean and txn.stage == .consumed and
            std.mem.eql(u8, &self.expected_terminal_clean_owner_seal, &response.seal) and
            std.mem.eql(u8, &self.expected_consumed_finish_digest, &txn.seal) and
            std.mem.eql(u8, &response.seal, &responseSeal(response)) and
            std.mem.eql(u8, &txn.seal, &finishSeal(txn));
    }
};

pub fn triggerReusableRearmCommitForTest(hostile_case: u8) noreturn {
    if (!@import("builtin").is_test) @compileError("test-only reusable rearm trigger");
    const bytes = std.testing.allocator.dupe(u8, "response") catch @panic("test allocation failed");
    var response: RpcExecutedResponse = .{};
    const identity = fixtureIdentity(@intFromPtr(&response), 0xEE);
    response.initLiveInPlace(identity, std.testing.allocator, bytes, fixtureProvenance()) catch
        @panic("test response init failed");
    var borrow: RpcResponseBorrow = .{};
    beginBorrowForTest(&response, identity, &borrow) catch @panic("test borrow failed");
    var finish: RpcResponseFinishTxn = .{};
    response.prepareFinish(identity, &borrow, &finish) catch @panic("test finish prepare failed");
    response.commitFreeNoFail(identity, &borrow, &finish);
    if (!finish.freeCaptured()) @panic("test captured free failed");
    var permit: PreparedReusableRearmPermit = .{};
    response.prepareReusableRearm(&finish, &permit) catch @panic("test rearm prepare failed");
    switch (hostile_case) {
        0 => response.commitReusableRearmNoFail(&finish, &permit),
        1 => {
            response.finishCleanNoFail(&finish);
            var copied = permit;
            response.commitReusableRearmNoFail(&finish, &copied);
        },
        2 => {
            response.finishCleanNoFail(&finish);
            var moved = permit;
            permit = .{};
            response.commitReusableRearmNoFail(&finish, &moved);
        },
        3 => {
            response.finishCleanNoFail(&finish);
            response.commitReusableRearmNoFail(&finish, &permit);
            response.commitReusableRearmNoFail(&finish, &permit);
        },
        else => @panic("invalid reusable rearm hostile case"),
    }
    @panic("hostile reusable rearm commit unexpectedly returned");
}

pub const PreparedBorrowInit = struct {
    self_addr: usize = 0,
    response_addr: usize = 0,
    borrow_addr: usize = 0,
    identity: Identity = std.mem.zeroes(Identity),
    payload_digest: owner_seal.Digest = [_]u8{0} ** 32,
    seal: owner_seal.Digest = [_]u8{0} ** 32,

    pub fn pristineExact(self: *const @This()) bool {
        return std.mem.eql(u8, std.mem.asBytes(self), std.mem.asBytes(&PreparedBorrowInit{}));
    }

    fn exactFor(
        self: *const @This(),
        response: *const RpcExecutedResponse,
        identity: Identity,
        borrow: *const RpcResponseBorrow,
    ) bool {
        return self.self_addr == @intFromPtr(self) and
            self.response_addr == @intFromPtr(response) and
            self.borrow_addr == @intFromPtr(borrow) and
            std.meta.eql(self.identity, identity) and
            std.mem.eql(u8, &self.payload_digest, &response.payload_digest) and
            std.mem.eql(u8, &self.seal, &preparedBorrowSeal(self));
    }
};

pub const RpcResponseBorrow = struct {
    self_addr: usize = 0,
    response_addr: usize = 0,
    registry_incarnation: u64 = 0,
    binding: contract.BindingIdentity = std.mem.zeroes(contract.BindingIdentity),
    transport_addr: usize = 0,
    transport_incarnation: u64 = 0,
    request_id: u64 = 0,
    request_digest: u64 = 0,
    response_epoch: u64 = 0,
    payload_digest: owner_seal.Digest = [_]u8{0} ** 32,
    live: u8 = 0,
    seal: owner_seal.Digest = [_]u8{0} ** 32,

    pub fn pristineExact(self: *const @This()) bool {
        return std.mem.eql(u8, std.mem.asBytes(self), std.mem.asBytes(&RpcResponseBorrow{}));
    }

    fn exactFor(self: *const @This(), response: *const RpcExecutedResponse, identity: Identity) bool {
        return self.self_addr == @intFromPtr(self) and self.response_addr == @intFromPtr(response) and
            self.registry_incarnation == identity.registry_incarnation and
            std.meta.eql(self.binding, identity.binding) and self.transport_addr == identity.transport_addr and
            self.transport_incarnation == identity.transport_incarnation and
            self.request_id == identity.request_id and self.request_digest == identity.request_digest and
            self.response_epoch == identity.response_epoch and self.live == 1 and
            std.mem.eql(u8, &self.payload_digest, &response.payload_digest) and
            std.mem.eql(u8, &self.seal, &borrowSeal(self));
    }
};

const FinishStage = enum(u8) { pristine, prepared, free_committed, terminal_freed_once, consumed };

pub const RpcResponseFinishTxn = struct {
    self_addr: usize = 0,
    response_addr: usize = 0,
    response_epoch: u64 = 0,
    allocator_present: u8 = 0,
    allocator_ptr: usize = 0,
    allocator_vtable: usize = 0,
    payload_addr: usize = 0,
    payload_len: usize = 0,
    payload_digest: owner_seal.Digest = [_]u8{0} ** 32,
    provenance: AllocationProvenance = std.mem.zeroes(AllocationProvenance),
    stage: FinishStage = .pristine,
    terminal_evidence: owner_seal.Digest = [_]u8{0} ** 32,
    seal: owner_seal.Digest = [_]u8{0} ** 32,

    pub fn pristineExact(self: *const @This()) bool {
        return std.mem.eql(u8, std.mem.asBytes(self), std.mem.asBytes(&RpcResponseFinishTxn{}));
    }

    pub fn freeCaptured(self: *RpcResponseFinishTxn) bool {
        if (!self.freeCommittedExact()) return false;
        const allocator = std.mem.Allocator{
            .ptr = @ptrFromInt(self.allocator_ptr),
            .vtable = @ptrFromInt(self.allocator_vtable),
        };
        const payload = payloadSliceMut(self.payload_addr, self.payload_len) orelse return false;
        const evidence = finishEvidence(self);
        self.allocator_present = 0;
        self.allocator_ptr = 0;
        self.allocator_vtable = 0;
        self.payload_addr = 0;
        self.payload_len = 0;
        self.provenance = std.mem.zeroes(AllocationProvenance);
        self.stage = .terminal_freed_once;
        self.terminal_evidence = evidence;
        self.seal = finishSeal(self);
        allocator.free(payload);
        return self.freedOnceRawExact();
    }

    pub fn freeEvidenceDigest(self: *const RpcResponseFinishTxn) ?owner_seal.Digest {
        if (!self.freeCommittedExact()) return null;
        return finishEvidence(self);
    }

    fn preparedExactFor(self: *const @This(), response: *const RpcExecutedResponse, identity: Identity) bool {
        return finishStageRawValid(&self.stage) and self.self_addr == @intFromPtr(self) and
            self.response_addr == @intFromPtr(response) and
            self.response_epoch == identity.response_epoch and self.allocator_present == 1 and
            self.allocator_ptr == response.allocator_ptr and self.allocator_vtable == response.allocator_vtable and
            self.payload_addr == response.payload_addr and self.payload_len == response.payload_len and
            std.mem.eql(u8, &self.payload_digest, &response.payload_digest) and self.stage == .prepared and
            std.meta.eql(self.provenance, response.provenance) and self.provenance.valid() and
            std.mem.allEqual(u8, &self.terminal_evidence, 0) and
            std.mem.eql(u8, &self.seal, &finishSeal(self));
    }

    fn freeCommittedExact(self: *const @This()) bool {
        return finishStageRawValid(&self.stage) and self.self_addr == @intFromPtr(self) and
            self.response_addr != 0 and
            self.response_epoch != 0 and self.allocator_present == 1 and self.allocator_ptr != 0 and
            self.allocator_vtable != 0 and self.payload_addr != 0 and self.payload_len != 0 and
            self.provenance.valid() and
            self.stage == .free_committed and std.mem.allEqual(u8, &self.terminal_evidence, 0) and
            std.mem.eql(u8, &self.seal, &finishSeal(self));
    }

    fn freedOnceRawExact(self: *const @This()) bool {
        return finishStageRawValid(&self.stage) and self.self_addr == @intFromPtr(self) and
            self.response_addr != 0 and
            self.response_epoch != 0 and self.allocator_present == 0 and self.allocator_ptr == 0 and
            self.allocator_vtable == 0 and self.payload_addr == 0 and self.payload_len == 0 and
            std.meta.eql(self.provenance, std.mem.zeroes(AllocationProvenance)) and
            self.stage == .terminal_freed_once and
            !std.mem.allEqual(u8, &self.terminal_evidence, 0) and
            std.mem.eql(u8, &self.seal, &finishSeal(self));
    }

    fn freedOnceExactFor(self: *const @This(), response: *const RpcExecutedResponse) bool {
        return self.response_addr == @intFromPtr(response) and
            self.response_epoch == response.owner_incarnation and self.freedOnceRawExact();
    }
};

fn byteSettlementRawValid(value: *const ByteSettlement) bool {
    return @as(*const u8, @ptrCast(value)).* <= @intFromEnum(ByteSettlement.terminal_no_free);
}

fn finishStageRawValid(value: *const FinishStage) bool {
    return @as(*const u8, @ptrCast(value)).* <= @intFromEnum(FinishStage.consumed);
}

/// 응답 payload는 이 호출 동안에만 빌려 준다. callback 복귀 뒤 owner와 borrow를 다시
/// 검증하므로 decoder가 source authority를 건드리면 cleanup을 추측하지 않고 상위 proof-loss로 닫힌다.
pub fn decodeBorrowedRpcResponse(
    response: *const RpcExecutedResponse,
    borrow: *const RpcResponseBorrow,
    context: *anyopaque,
    callback: contract.RpcDecoder,
) RpcExecutedResponse.Error!contract.RpcDecodeDisposition {
    if (!response.liveExact(response.identity) or !borrow.exactFor(response, response.identity))
        return error.InvalidReceipt;
    const disposition = callback(
        context,
        response.identity.tag,
        payloadSlice(response.payload_addr, response.payload_len).?,
    );
    if (builtin.is_test and decoder_proof_loss_hook.armed) {
        decoder_proof_loss_hook.writeStage(12);
        @constCast(borrow).seal[0] ^= 1;
        decoder_proof_loss_hook.writeStage(11);
        decoder_proof_loss_hook.armed = false;
    }
    if (!response.liveExact(response.identity) or !borrow.exactFor(response, response.identity))
        return error.InvalidReceipt;
    if (!contract.rpcDecodeDispositionRawValid(&disposition)) return error.InvalidReceipt;
    return disposition;
}

pub fn withBorrowedRpcResponseBytesForTest(
    response: *const RpcExecutedResponse,
    borrow: *const RpcResponseBorrow,
    context: *anyopaque,
    callback: *const fn (*anyopaque, []const u8) void,
) RpcExecutedResponse.Error!void {
    if (!@import("builtin").is_test) @compileError("test-only RPC response byte bridge");
    const Adapter = struct {
        callback: *const fn (*anyopaque, []const u8) void,
        context: *anyopaque,

        fn invoke(raw: *anyopaque, _: contract.RuntimeRequestTag, bytes: []const u8) contract.RpcDecodeDisposition {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.callback(self.context, bytes);
            return .reusable;
        }
    };
    var adapter = Adapter{ .callback = callback, .context = context };
    _ = try decodeBorrowedRpcResponse(response, borrow, &adapter, Adapter.invoke);
}

fn responseSeal(response: *const RpcExecutedResponse) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.rpc-executed-response.v1");
    writer.writeUsize(response.self_addr);
    writer.writeU64(response.owner_incarnation);
    writeIdentity(&writer, response.identity);
    writer.writeUsize(response.provenance.ledger_addr);
    writer.writeUsize(response.provenance.guard_addr);
    writer.writeUsize(response.provenance.node_addr);
    writer.writeU64(response.provenance.operation_incarnation);
    writer.writeU16(response.provenance.index);
    writer.writeU64(response.provenance.generation);
    writer.writeU8(response.allocator_present);
    writer.writeUsize(response.allocator_ptr);
    writer.writeUsize(response.allocator_vtable);
    writer.writeUsize(response.payload_addr);
    writer.writeUsize(response.payload_len);
    writer.writeBytes(&response.payload_digest);
    writer.writeU8(@intFromEnum(response.settlement));
    writer.writeBytes(&response.terminal_evidence);
    return writer.finish();
}

fn borrowSeal(borrow: *const RpcResponseBorrow) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.rpc-response-borrow.v1");
    writer.writeUsize(borrow.self_addr);
    writer.writeUsize(borrow.response_addr);
    writer.writeU64(borrow.registry_incarnation);
    writeBinding(&writer, borrow.binding);
    writer.writeUsize(borrow.transport_addr);
    writer.writeU64(borrow.transport_incarnation);
    writer.writeU64(borrow.request_id);
    writer.writeU64(borrow.request_digest);
    writer.writeU64(borrow.response_epoch);
    writer.writeBytes(&borrow.payload_digest);
    writer.writeU8(borrow.live);
    return writer.finish();
}

fn preparedBorrowSeal(permit: *const PreparedBorrowInit) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.rpc-response-prepared-borrow.v1");
    writer.writeUsize(permit.self_addr);
    writer.writeUsize(permit.response_addr);
    writer.writeUsize(permit.borrow_addr);
    writeIdentity(&writer, permit.identity);
    writer.writeBytes(&permit.payload_digest);
    return writer.finish();
}

fn finishSeal(txn: *const RpcResponseFinishTxn) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.rpc-response-finish.v1");
    writer.writeUsize(txn.self_addr);
    writer.writeUsize(txn.response_addr);
    writer.writeU64(txn.response_epoch);
    writer.writeU8(txn.allocator_present);
    writer.writeUsize(txn.allocator_ptr);
    writer.writeUsize(txn.allocator_vtable);
    writer.writeUsize(txn.payload_addr);
    writer.writeUsize(txn.payload_len);
    writer.writeBytes(&txn.payload_digest);
    writer.writeUsize(txn.provenance.ledger_addr);
    writer.writeUsize(txn.provenance.guard_addr);
    writer.writeUsize(txn.provenance.node_addr);
    writer.writeU64(txn.provenance.operation_incarnation);
    writer.writeU16(txn.provenance.index);
    writer.writeU64(txn.provenance.generation);
    writer.writeU8(@intFromEnum(txn.stage));
    writer.writeBytes(&txn.terminal_evidence);
    return writer.finish();
}

fn finishEvidence(txn: *const RpcResponseFinishTxn) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.rpc-response-free-evidence.v1");
    writer.writeUsize(txn.response_addr);
    writer.writeU64(txn.response_epoch);
    writer.writeUsize(txn.payload_addr);
    writer.writeUsize(txn.payload_len);
    writer.writeBytes(&txn.payload_digest);
    writer.writeUsize(txn.provenance.ledger_addr);
    writer.writeUsize(txn.provenance.guard_addr);
    writer.writeUsize(txn.provenance.node_addr);
    writer.writeU64(txn.provenance.operation_incarnation);
    writer.writeU16(txn.provenance.index);
    writer.writeU64(txn.provenance.generation);
    return writer.finish();
}

fn writeIdentity(writer: *owner_seal.Writer, identity: Identity) void {
    writer.writeUsize(identity.authority_addr);
    writer.writeU64(identity.registry_incarnation);
    writeBinding(writer, identity.binding);
    writer.writeUsize(identity.transport_addr);
    writer.writeU64(identity.transport_incarnation);
    writer.writeU8(@intFromEnum(identity.family));
    writer.writeU8(@intFromEnum(identity.tag));
    writer.writeU64(identity.request_id);
    writer.writeU64(identity.request_digest);
    writer.writeU64(identity.response_epoch);
    writer.writeUsize(identity.destination_addr);
}

fn writeBinding(writer: *owner_seal.Writer, binding: contract.BindingIdentity) void {
    writer.writeU64(binding.binding_incarnation);
    writer.writeUsize(binding.binding_storage_addr);
    writer.writeUsize(binding.destination_addr);
    writer.writeU64(binding.binding_reservation_id);
    writer.writeU64(binding.slot_incarnation);
    writer.writeU64(binding.node_incarnation);
    writer.writeU128(binding.host_id);
    writer.writeU64(binding.connection_generation);
    writer.writeU128(binding.runtime_id);
    writer.writeU8(@intFromEnum(binding.role));
    writer.writeU64(binding.pid);
    writer.writeU64(binding.process_nonce);
}

const Range = struct { start: usize, end: usize };

fn byteRange(start: usize, len: usize) ?Range {
    if (start == 0 or len == 0) return null;
    return .{ .start = start, .end = std.math.add(usize, start, len) catch return null };
}

fn rangesOverlap(a: Range, b: Range) bool {
    return a.start < b.end and b.start < a.end;
}

fn payloadSlice(addr: usize, len: usize) ?[]const u8 {
    _ = byteRange(addr, len) orelse return null;
    return @as([*]const u8, @ptrFromInt(addr))[0..len];
}

fn payloadSliceMut(addr: usize, len: usize) ?[]u8 {
    _ = byteRange(addr, len) orelse return null;
    return @as([*]u8, @ptrFromInt(addr))[0..len];
}

fn digestBytes(domain: []const u8, bytes: []const u8) owner_seal.Digest {
    var writer = owner_seal.Writer.init(domain);
    writer.writeBytes(bytes);
    return writer.finish();
}

fn fixtureBinding(destination_addr: usize) contract.BindingIdentity {
    return contract.BindingIdentity.init(.{
        .binding_incarnation = 3,
        .binding_storage_addr = 0x1000,
        .destination_addr = destination_addr,
        .binding_reservation_id = 5,
        .slot_incarnation = 7,
        .node_incarnation = 11,
        .host_id = 13,
        .connection_generation = 1,
        .runtime_id = 17,
        .role = .controller,
        .pid = 19,
        .process_nonce = 23,
    }).?;
}

fn fixtureIdentity(destination_addr: usize, epoch: u64) Identity {
    return .{
        .authority_addr = 0x2F00,
        .registry_incarnation = 29,
        .binding = fixtureBinding(destination_addr),
        .transport_addr = 0x3000,
        .transport_incarnation = 31,
        .family = .bound_observation,
        .tag = .observation,
        .request_id = 37,
        .request_digest = 41,
        .response_epoch = epoch,
        .destination_addr = destination_addr,
    };
}

fn fixtureProvenance() AllocationProvenance {
    return .{
        .ledger_addr = 0x4000,
        .guard_addr = 0x5000,
        .node_addr = 0x6000,
        .operation_incarnation = 43,
        .index = 2,
        .generation = 47,
    };
}

const ByteProbe = struct {
    expected: []const u8,
    called: bool = false,

    fn inspect(context: *anyopaque, bytes: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.called = std.mem.eql(u8, self.expected, bytes);
    }
};

const DecodeProbe = struct {
    expected: []const u8,
    expected_tag: contract.RuntimeRequestTag,
    disposition: contract.RpcDecodeDisposition,
    calls: usize = 0,

    fn inspect(
        context: *anyopaque,
        tag: contract.RuntimeRequestTag,
        bytes: []const u8,
    ) contract.RpcDecodeDisposition {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (tag == self.expected_tag and std.mem.eql(u8, self.expected, bytes)) self.calls += 1;
        return self.disposition;
    }
};

fn fixtureLiveBorrow(
    response: *RpcExecutedResponse,
    borrow: *RpcResponseBorrow,
    payload: []u8,
) !void {
    const identity = fixtureIdentity(@intFromPtr(response), 53);
    try RpcExecutedResponse.initLiveInPlace(
        response,
        identity,
        std.testing.allocator,
        payload,
        fixtureProvenance(),
    );
    var permit: PreparedBorrowInit = .{};
    try response.prepareBorrowInit(identity, borrow, &permit);
    response.commitBorrowReceiptNoFail(identity, borrow, &permit);
}

test "2c3e C1 scoped owner는 accepted bytes를 decoder에 exact 한 번 빌려 준다" {
    const payload = try std.testing.allocator.dupe(u8, "{\"result\":{}}");
    defer std.testing.allocator.free(payload);
    var response: RpcExecutedResponse = .{};
    var borrow: RpcResponseBorrow = .{};
    try fixtureLiveBorrow(&response, &borrow, payload);
    var probe = DecodeProbe{
        .expected = payload,
        .expected_tag = .observation,
        .disposition = .reusable,
    };
    try std.testing.expectEqual(
        contract.RpcDecodeDisposition.reusable,
        try decodeBorrowedRpcResponse(&response, &borrow, &probe, DecodeProbe.inspect),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "2c3e C1 scoped owner는 protocol failure disposition을 그대로 보존한다" {
    const payload = try std.testing.allocator.dupe(u8, "malformed");
    defer std.testing.allocator.free(payload);
    var response: RpcExecutedResponse = .{};
    var borrow: RpcResponseBorrow = .{};
    try fixtureLiveBorrow(&response, &borrow, payload);
    var probe = DecodeProbe{
        .expected = payload,
        .expected_tag = .observation,
        .disposition = .protocol_failure,
    };
    try std.testing.expectEqual(
        contract.RpcDecodeDisposition.protocol_failure,
        try decodeBorrowedRpcResponse(&response, &borrow, &probe, DecodeProbe.inspect),
    );
}

test "2c3e C1 scoped owner는 copied borrow를 callback 전에 거부한다" {
    const payload = try std.testing.allocator.dupe(u8, "{}");
    defer std.testing.allocator.free(payload);
    var response: RpcExecutedResponse = .{};
    var borrow: RpcResponseBorrow = .{};
    try fixtureLiveBorrow(&response, &borrow, payload);
    var copied = borrow;
    var probe = DecodeProbe{
        .expected = payload,
        .expected_tag = .observation,
        .disposition = .reusable,
    };
    try std.testing.expectError(
        error.InvalidReceipt,
        decodeBorrowedRpcResponse(&response, &copied, &probe, DecodeProbe.inspect),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "2c3e C1 scoped owner는 callback의 response seal drift를 복귀 직후 거부한다" {
    const payload = try std.testing.allocator.dupe(u8, "{}");
    defer std.testing.allocator.free(payload);
    var response: RpcExecutedResponse = .{};
    var borrow: RpcResponseBorrow = .{};
    try fixtureLiveBorrow(&response, &borrow, payload);
    const Drift = struct {
        response: *RpcExecutedResponse,

        fn inspect(
            context: *anyopaque,
            _: contract.RuntimeRequestTag,
            _: []const u8,
        ) contract.RpcDecodeDisposition {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.response.seal[0] ^= 1;
            return .reusable;
        }
    };
    var drift = Drift{ .response = &response };
    try std.testing.expectError(
        error.InvalidReceipt,
        decodeBorrowedRpcResponse(&response, &borrow, &drift, Drift.inspect),
    );
}

test "2c3e C1 scoped owner는 callback의 borrow seal drift를 복귀 직후 거부한다" {
    const payload = try std.testing.allocator.dupe(u8, "{}");
    defer std.testing.allocator.free(payload);
    var response: RpcExecutedResponse = .{};
    var borrow: RpcResponseBorrow = .{};
    try fixtureLiveBorrow(&response, &borrow, payload);
    const Drift = struct {
        borrow: *RpcResponseBorrow,

        fn inspect(
            context: *anyopaque,
            _: contract.RuntimeRequestTag,
            _: []const u8,
        ) contract.RpcDecodeDisposition {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.borrow.seal[0] ^= 1;
            return .reusable;
        }
    };
    var drift = Drift{ .borrow = &borrow };
    try std.testing.expectError(
        error.InvalidReceipt,
        decodeBorrowedRpcResponse(&response, &borrow, &drift, Drift.inspect),
    );
}

test "2c3e C1 scoped owner는 callback의 payload byte drift를 복귀 직후 거부한다" {
    const payload = try std.testing.allocator.dupe(u8, "{}");
    defer std.testing.allocator.free(payload);
    var response: RpcExecutedResponse = .{};
    var borrow: RpcResponseBorrow = .{};
    try fixtureLiveBorrow(&response, &borrow, payload);
    const Drift = struct {
        payload: []u8,

        fn inspect(
            context: *anyopaque,
            _: contract.RuntimeRequestTag,
            _: []const u8,
        ) contract.RpcDecodeDisposition {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.payload[0] ^= 1;
            return .reusable;
        }
    };
    var drift = Drift{ .payload = payload };
    try std.testing.expectError(
        error.InvalidReceipt,
        decodeBorrowedRpcResponse(&response, &borrow, &drift, Drift.inspect),
    );
}

test "2c3e C1 scoped owner는 copied response address를 callback 전에 거부한다" {
    const payload = try std.testing.allocator.dupe(u8, "{}");
    defer std.testing.allocator.free(payload);
    var response: RpcExecutedResponse = .{};
    var borrow: RpcResponseBorrow = .{};
    try fixtureLiveBorrow(&response, &borrow, payload);
    var copied_response = response;
    var probe = DecodeProbe{
        .expected = payload,
        .expected_tag = .observation,
        .disposition = .reusable,
    };
    try std.testing.expectError(
        error.InvalidReceipt,
        decodeBorrowedRpcResponse(&copied_response, &borrow, &probe, DecodeProbe.inspect),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "2c3e C1 scoped owner는 callback 뒤 cleanup 전까지 같은 live source를 보존한다" {
    const payload = try std.testing.allocator.dupe(u8, "{}");
    defer std.testing.allocator.free(payload);
    var response: RpcExecutedResponse = .{};
    var borrow: RpcResponseBorrow = .{};
    try fixtureLiveBorrow(&response, &borrow, payload);
    const identity = response.identity;
    var probe = DecodeProbe{
        .expected = payload,
        .expected_tag = .observation,
        .disposition = .reusable,
    };
    _ = try decodeBorrowedRpcResponse(&response, &borrow, &probe, DecodeProbe.inspect);
    try std.testing.expect(response.liveScalarIdentityExact(identity));
    try std.testing.expect(borrow.exactFor(&response, identity));
}

fn beginBorrowForTest(
    response: *const RpcExecutedResponse,
    identity: Identity,
    borrow: *RpcResponseBorrow,
) RpcExecutedResponse.Error!void {
    var permit: PreparedBorrowInit = .{};
    try response.prepareBorrowInit(identity, borrow, &permit);
    response.commitBorrowReceiptNoFail(identity, borrow, &permit);
}

test "B3-4/5 RPC owner publishes borrows and frees exact once" {
    const bytes = try std.testing.allocator.dupe(u8, "response");
    var response: RpcExecutedResponse = .{};
    const identity = fixtureIdentity(@intFromPtr(&response), 1);
    try response.initLiveInPlace(identity, std.testing.allocator, bytes, fixtureProvenance());
    var borrow: RpcResponseBorrow = .{};
    try beginBorrowForTest(&response, identity, &borrow);
    var probe: ByteProbe = .{ .expected = "response" };
    try withBorrowedRpcResponseBytesForTest(&response, &borrow, &probe, ByteProbe.inspect);
    try std.testing.expect(probe.called);
    var finish: RpcResponseFinishTxn = .{};
    try response.prepareFinish(identity, &borrow, &finish);
    response.commitFreeNoFail(identity, &borrow, &finish);
    try std.testing.expect(finish.freeCaptured());
    response.finishCleanNoFail(&finish);
    try std.testing.expect(response.terminalExact());
    try std.testing.expect(!finish.freeCaptured());
}

test "B3-4/5 RPC owner reusable rearm permit consumes clean finish into pristine" {
    const bytes = try std.testing.allocator.dupe(u8, "response");
    var response: RpcExecutedResponse = .{};
    const identity = fixtureIdentity(@intFromPtr(&response), 7);
    try response.initLiveInPlace(identity, std.testing.allocator, bytes, fixtureProvenance());
    var borrow: RpcResponseBorrow = .{};
    try beginBorrowForTest(&response, identity, &borrow);
    var finish: RpcResponseFinishTxn = .{};
    try response.prepareFinish(identity, &borrow, &finish);
    response.commitFreeNoFail(identity, &borrow, &finish);
    try std.testing.expect(finish.freeCaptured());
    var permit: PreparedReusableRearmPermit = .{};
    try response.prepareReusableRearm(&finish, &permit);
    response.finishCleanNoFail(&finish);
    response.commitReusableRearmNoFail(&finish, &permit);
    try std.testing.expect(response.pristineExact());
    try std.testing.expectEqual(@as(u8, 1), permit.consumed_raw);
}

test "CR3a-2c3b reusable response correction rearm permit rejects wrong-order copy move and replay" {
    const bytes = try std.testing.allocator.dupe(u8, "response");
    var response: RpcExecutedResponse = .{};
    const identity = fixtureIdentity(@intFromPtr(&response), 8);
    try response.initLiveInPlace(identity, std.testing.allocator, bytes, fixtureProvenance());
    var borrow: RpcResponseBorrow = .{};
    try beginBorrowForTest(&response, identity, &borrow);
    var finish: RpcResponseFinishTxn = .{};
    try response.prepareFinish(identity, &borrow, &finish);
    response.commitFreeNoFail(identity, &borrow, &finish);
    try std.testing.expect(finish.freeCaptured());
    var permit: PreparedReusableRearmPermit = .{};
    try response.prepareReusableRearm(&finish, &permit);
    try std.testing.expect(!permit.exactFor(&response, &finish));
    response.finishCleanNoFail(&finish);
    var copied = permit;
    const before = response;
    try std.testing.expect(!copied.exactFor(&response, &finish));
    try std.testing.expectEqualDeep(before, response);
    response.commitReusableRearmNoFail(&finish, &permit);
    try std.testing.expect(!permit.exactFor(&response, &finish));
}

test "B3-4/5 RPC owner reusable rearm permit rejects identity epoch finish and owner seal drift mutation zero" {
    const bytes = try std.testing.allocator.dupe(u8, "response");
    var response: RpcExecutedResponse = .{};
    const identity = fixtureIdentity(@intFromPtr(&response), 9);
    try response.initLiveInPlace(identity, std.testing.allocator, bytes, fixtureProvenance());
    var borrow: RpcResponseBorrow = .{};
    try beginBorrowForTest(&response, identity, &borrow);
    var finish: RpcResponseFinishTxn = .{};
    try response.prepareFinish(identity, &borrow, &finish);
    response.commitFreeNoFail(identity, &borrow, &finish);
    try std.testing.expect(finish.freeCaptured());
    var permit: PreparedReusableRearmPermit = .{};
    try response.prepareReusableRearm(&finish, &permit);
    response.finishCleanNoFail(&finish);
    const before = response;
    permit.old_epoch +%= 1;
    try std.testing.expect(!permit.exactFor(&response, &finish));
    try std.testing.expectEqualDeep(before, response);
}

test "B3-4/5 RPC owner reusable rearm permit rejects permanent and publication terminal owners mutation zero" {
    var response: RpcExecutedResponse = .{};
    const identity = fixtureIdentity(@intFromPtr(&response), 10);
    const evidence = digestBytes("test.permanent", "evidence");
    try response.terminalCleanAfterPublicationFailureInPlace(identity, evidence);
    var finish: RpcResponseFinishTxn = .{};
    var permit: PreparedReusableRearmPermit = .{};
    const before = response;
    try std.testing.expectError(
        error.InvalidTransaction,
        response.prepareReusableRearm(&finish, &permit),
    );
    try std.testing.expectEqualDeep(before, response);
    try std.testing.expect(permit.pristineExact());
}

test "B3-4/5 RPC owner rejects occupied destination and invalid payload bounds mutation zero" {
    var response: RpcExecutedResponse = .{};
    const identity = fixtureIdentity(@intFromPtr(&response), 1);
    const before = response;
    var empty: [0]u8 = .{};
    try std.testing.expectError(
        error.InvalidPayload,
        response.initLiveInPlace(identity, std.testing.allocator, &empty, fixtureProvenance()),
    );
    try std.testing.expectEqualDeep(before, response);
    response.self_addr = 1;
    var byte: [1]u8 = .{1};
    try std.testing.expectError(
        error.DestinationOccupied,
        response.initLiveInPlace(identity, std.testing.allocator, &byte, fixtureProvenance()),
    );
}

test "B3-4/5 RPC owner rejects copied borrow and finish receipts" {
    const bytes = try std.testing.allocator.dupe(u8, "response");
    defer std.testing.allocator.free(bytes);
    var response: RpcExecutedResponse = .{};
    const identity = fixtureIdentity(@intFromPtr(&response), 1);
    try response.initLiveInPlace(identity, std.testing.allocator, bytes, fixtureProvenance());
    var borrow: RpcResponseBorrow = .{};
    try beginBorrowForTest(&response, identity, &borrow);
    var copied_borrow = borrow;
    var finish: RpcResponseFinishTxn = .{};
    try std.testing.expectError(error.InvalidReceipt, response.prepareFinish(identity, &copied_borrow, &finish));
    try response.prepareFinish(identity, &borrow, &finish);
    var copied_finish = finish;
    try std.testing.expect(!copied_finish.freeCaptured());
}

test "B3-4/5 RPC owner detects payload drift before lexical borrow" {
    const bytes = try std.testing.allocator.dupe(u8, "response");
    defer std.testing.allocator.free(bytes);
    var response: RpcExecutedResponse = .{};
    const identity = fixtureIdentity(@intFromPtr(&response), 1);
    try response.initLiveInPlace(identity, std.testing.allocator, bytes, fixtureProvenance());
    var borrow: RpcResponseBorrow = .{};
    try beginBorrowForTest(&response, identity, &borrow);
    bytes[0] = 'R';
    var probe: ByteProbe = .{ .expected = "Response" };
    try std.testing.expectError(
        error.InvalidReceipt,
        withBorrowedRpcResponseBytesForTest(&response, &borrow, &probe, ByteProbe.inspect),
    );
    try std.testing.expect(!probe.called);
}

test "B3-4/5 RPC owner terminal no-free keeps pointer-free absorbing evidence" {
    var response: RpcExecutedResponse = .{};
    const identity = fixtureIdentity(@intFromPtr(&response), 1);
    const evidence = digestBytes("test.ambiguous", "evidence");
    try response.terminalNoFreeInPlace(identity, evidence);
    try std.testing.expect(response.terminalExact());
    var borrow: RpcResponseBorrow = .{};
    var permit: PreparedBorrowInit = .{};
    try std.testing.expectError(
        error.InvalidOwner,
        response.prepareBorrowInit(identity, &borrow, &permit),
    );
}

test "B3-4/5 RPC owner terminal clean accepts only pristine external-free destination" {
    var response: RpcExecutedResponse = .{};
    const identity = fixtureIdentity(@intFromPtr(&response), 3);
    const evidence = digestBytes("test.external-free", "evidence");
    try response.terminalCleanAfterPublicationFailureInPlace(identity, evidence);
    try std.testing.expect(response.terminalExact());
    try std.testing.expectEqual(ByteSettlement.terminal_clean, response.settlement);
    try std.testing.expectError(
        error.DestinationOccupied,
        response.terminalCleanAfterPublicationFailureInPlace(identity, evidence),
    );
}

test "B3-4/5 RPC owner abandons live allocation without payload read or free" {
    const bytes = try std.testing.allocator.dupe(u8, "response");
    defer std.testing.allocator.free(bytes);
    var response: RpcExecutedResponse = .{};
    const identity = fixtureIdentity(@intFromPtr(&response), 2);
    try response.initLiveInPlace(identity, std.testing.allocator, bytes, fixtureProvenance());
    try response.abandonLiveNoFree(identity);
    try std.testing.expect(response.terminalExact());
    try std.testing.expectEqual(@as(usize, 0), response.payload_addr);
    try std.testing.expectEqual(@as(u8, 0), response.allocator_present);
    try std.testing.expectError(error.InvalidOwner, response.abandonLiveNoFree(identity));
}

test "B3-4/5 RPC owner rejects same-address epoch replay" {
    const bytes = try std.testing.allocator.dupe(u8, "response");
    defer std.testing.allocator.free(bytes);
    var response: RpcExecutedResponse = .{};
    const identity = fixtureIdentity(@intFromPtr(&response), 1);
    try response.initLiveInPlace(identity, std.testing.allocator, bytes, fixtureProvenance());
    var borrow: RpcResponseBorrow = .{};
    var permit: PreparedBorrowInit = .{};
    try std.testing.expectError(
        error.InvalidOwner,
        response.prepareBorrowInit(
            fixtureIdentity(@intFromPtr(&response), 2),
            &borrow,
            &permit,
        ),
    );
    const settlement_raw: *u8 = @ptrCast(&response.settlement);
    var raw: u16 = @intFromEnum(ByteSettlement.terminal_no_free) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        settlement_raw.* = @intCast(raw);
        try std.testing.expectError(
            error.InvalidOwner,
            response.prepareBorrowInit(identity, &borrow, &permit),
        );
    }
}
