//! Generation attach stack의 단일 initial snapshot owner.
//!
//! Snapshot은 장기 batch registry에 들어가지 않는다. 이 final-address owner가 실제
//! allocator와 generation/binding stream identity를 봉인하고 apply 성공·실패 뒤 exact once 해제한다.

const std = @import("std");
const builtin = @import("builtin");
const client_slot_mod = @import("client_slot.zig");
const contract = @import("generation_attachment_contract.zig");
const process_identity = @import("process_identity.zig");

const Lifecycle = enum(u8) { pristine, live, terminal };

const AuthorityLifecycle = enum(u8) { pristine, idle, reserved, live, terminal };

pub const MintReceipt = struct {
    authority_addr: usize,
    owner_addr: usize,
    generation: u64,
    transport_incarnation: u64,
};

pub const Authority = struct {
    self_addr: usize = 0,
    lifecycle: AuthorityLifecycle = .pristine,
    next_generation: u64 = 1,
    active_generation: u64 = 0,
    owner_addr: usize = 0,
    transport_incarnation: u64 = 0,
    owner_thread_id: std.Thread.Id = 0,

    pub fn initInPlace(out: *Authority, transport_incarnation: u64) error{InvalidAuthority}!void {
        if (out.self_addr != 0 or out.lifecycle != .pristine or transport_incarnation == 0)
            return error.InvalidAuthority;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .lifecycle = .idle,
            .transport_incarnation = transport_incarnation,
            .owner_thread_id = std.Thread.getCurrentId(),
        };
    }

    pub fn prepare(
        self: *Authority,
        owner_addr: usize,
        transport_incarnation: u64,
    ) error{ InvalidAuthority, IdentityExhausted }!MintReceipt {
        if (!self.valid(.idle, transport_incarnation) or owner_addr == 0)
            return error.InvalidAuthority;
        const generation = self.next_generation;
        self.next_generation = std.math.add(u64, generation, 1) catch
            return error.IdentityExhausted;
        self.active_generation = generation;
        self.owner_addr = owner_addr;
        self.lifecycle = .reserved;
        return .{
            .authority_addr = @intFromPtr(self),
            .owner_addr = owner_addr,
            .generation = generation,
            .transport_incarnation = transport_incarnation,
        };
    }

    pub fn publish(self: *Authority, receipt: MintReceipt) error{InvalidAuthority}!void {
        if (!self.matches(.reserved, receipt)) return error.InvalidAuthority;
        self.lifecycle = .live;
    }

    pub fn abort(self: *Authority, receipt: MintReceipt) error{InvalidAuthority}!void {
        if (!self.matches(.reserved, receipt)) return error.InvalidAuthority;
        self.finish();
    }

    pub fn consume(self: *Authority, receipt: MintReceipt) error{InvalidAuthority}!void {
        if (!self.matches(.live, receipt)) return error.InvalidAuthority;
        self.finish();
    }

    pub fn receiptLive(self: *const Authority, receipt: MintReceipt) bool {
        return self.matches(.live, receipt);
    }

    pub fn terminalize(self: *Authority, transport_incarnation: u64) error{InvalidAuthority}!void {
        if (!self.valid(.idle, transport_incarnation)) return error.InvalidAuthority;
        self.lifecycle = .terminal;
        self.owner_addr = 0;
        self.active_generation = 0;
    }

    pub fn canTerminalize(self: *const Authority, transport_incarnation: u64) bool {
        return self.valid(.idle, transport_incarnation);
    }

    fn finish(self: *Authority) void {
        self.lifecycle = .idle;
        self.owner_addr = 0;
        self.active_generation = 0;
    }

    fn valid(
        self: *const Authority,
        expected: AuthorityLifecycle,
        transport_incarnation: u64,
    ) bool {
        return self.self_addr == @intFromPtr(self) and self.lifecycle == expected and
            self.transport_incarnation == transport_incarnation and transport_incarnation != 0 and
            self.owner_thread_id == std.Thread.getCurrentId();
    }

    fn matches(self: *const Authority, expected: AuthorityLifecycle, receipt: MintReceipt) bool {
        return self.valid(expected, receipt.transport_incarnation) and
            receipt.authority_addr == @intFromPtr(self) and receipt.owner_addr == self.owner_addr and
            receipt.generation != 0 and receipt.generation == self.active_generation;
    }
};

pub const Identity = struct {
    transport_incarnation: u64,
    slot_incarnation: u64,
    node_incarnation: u64,
    host_id: u128,
    connection_generation: u64,
    pid: u32,
    process_nonce: u64,
    owner_thread_id: std.Thread.Id,
    stream_id: u64,
    binding_incarnation: u64,
    binding_storage_addr: usize,
    binding_destination_addr: usize,
    binding_reservation_id: u64,
    runtime_id: u128,
    role: contract.AttachmentRole,
};

pub const InitialSnapshotOwner = struct {
    self_addr: usize = 0,
    lifecycle: Lifecycle = .pristine,
    actual_allocator: std.mem.Allocator = undefined,
    bytes: ?[]u8 = null,
    transport_incarnation: u64 = 0,
    slot_incarnation: u64 = 0,
    node_incarnation: u64 = 0,
    host_id: u128 = 0,
    connection_generation: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread_id: std.Thread.Id = 0,
    stream_id: u64 = 0,
    binding_incarnation: u64 = 0,
    binding_storage_addr: usize = 0,
    binding_destination_addr: usize = 0,
    binding_reservation_id: u64 = 0,
    runtime_id: u128 = 0,
    role: contract.AttachmentRole = .observer,
    mint_receipt: MintReceipt = undefined,
    canonical_permit: client_slot_mod.InitialSnapshotPermit = undefined,

    pub fn canInitialize(self: *const InitialSnapshotOwner) bool {
        return self.self_addr == 0 and self.lifecycle == .pristine and self.bytes == null;
    }

    pub fn initInPlace(
        out: *InitialSnapshotOwner,
        allocator: std.mem.Allocator,
        owned_bytes: []u8,
        identity: Identity,
        authority: *Authority,
        receipt: MintReceipt,
        canonical_permit: client_slot_mod.InitialSnapshotPermit,
    ) error{InvalidOwner}!void {
        if (out.self_addr != 0 or out.lifecycle != .pristine or out.bytes != null or
            identity.transport_incarnation == 0 or identity.slot_incarnation == 0 or
            identity.node_incarnation == 0 or identity.host_id == 0 or
            identity.connection_generation == 0 or identity.pid == 0 or
            identity.process_nonce == 0 or identity.owner_thread_id != std.Thread.getCurrentId() or
            identity.stream_id == 0 or identity.binding_incarnation == 0 or
            identity.binding_storage_addr == 0 or identity.binding_reservation_id == 0 or
            identity.binding_destination_addr == 0 or
            identity.runtime_id == 0 or receipt.owner_addr != @intFromPtr(out) or
            canonical_permit.owner_addr != @intFromPtr(out) or
            canonical_permit.transport_incarnation != identity.transport_incarnation or
            !std.meta.eql(canonical_permit.binding, .{
                .binding_incarnation = identity.binding_incarnation,
                .binding_storage_addr = identity.binding_storage_addr,
                .destination_addr = identity.binding_destination_addr,
                .binding_reservation_id = identity.binding_reservation_id,
                .slot_incarnation = identity.slot_incarnation,
                .node_incarnation = identity.node_incarnation,
                .host_id = identity.host_id,
                .connection_generation = identity.connection_generation,
                .runtime_id = identity.runtime_id,
                .role = identity.role,
                .pid = identity.pid,
                .process_nonce = identity.process_nonce,
            }) or !canonicalPermitLive(canonical_permit) or
            !authority.matches(.reserved, receipt))
            return error.InvalidOwner;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .lifecycle = .live,
            .actual_allocator = allocator,
            .bytes = owned_bytes,
            .transport_incarnation = identity.transport_incarnation,
            .slot_incarnation = identity.slot_incarnation,
            .node_incarnation = identity.node_incarnation,
            .host_id = identity.host_id,
            .connection_generation = identity.connection_generation,
            .pid = identity.pid,
            .process_nonce = identity.process_nonce,
            .owner_thread_id = identity.owner_thread_id,
            .stream_id = identity.stream_id,
            .binding_incarnation = identity.binding_incarnation,
            .binding_storage_addr = identity.binding_storage_addr,
            .binding_destination_addr = identity.binding_destination_addr,
            .binding_reservation_id = identity.binding_reservation_id,
            .runtime_id = identity.runtime_id,
            .role = identity.role,
            .mint_receipt = receipt,
            .canonical_permit = canonical_permit,
        };
        authority.publish(receipt) catch {
            out.* = .{};
            return error.InvalidOwner;
        };
    }

    pub fn borrow(self: *const InitialSnapshotOwner) error{MovedOrCopied}![]const u8 {
        if (!self.valid()) return error.MovedOrCopied;
        return self.bytes.?;
    }

    pub fn deinit(self: *InitialSnapshotOwner) error{MovedOrCopied}!void {
        if (!self.valid()) return error.MovedOrCopied;
        const owned_bytes = self.bytes.?;
        const allocator = self.actual_allocator;
        const authority: *Authority = @ptrFromInt(self.mint_receipt.authority_addr);
        const permit = self.canonical_permit;
        // Tombstone first so allocator callbacks cannot replay this owner. Keep both the
        // transport-local and node-canonical permits live across free so attachment/slot teardown
        // observes busy until the callback has returned.
        self.lifecycle = .terminal;
        self.bytes = null;
        self.transport_incarnation = 0;
        self.stream_id = 0;
        allocator.free(owned_bytes);
        consumeCanonicalPermit(permit) catch
            @panic("initial snapshot canonical permit drifted after payload free");
        authority.consume(self.mint_receipt) catch
            @panic("initial snapshot transport authority drifted after payload free");
    }

    fn valid(self: *const InitialSnapshotOwner) bool {
        return self.self_addr == @intFromPtr(self) and self.lifecycle == .live and
            self.bytes != null and self.transport_incarnation != 0 and
            self.slot_incarnation != 0 and self.node_incarnation != 0 and self.host_id != 0 and
            self.connection_generation != 0 and self.pid != 0 and self.pid == currentPid() and
            self.process_nonce != 0 and self.owner_thread_id == std.Thread.getCurrentId() and
            self.stream_id != 0 and self.binding_incarnation != 0 and
            self.binding_storage_addr != 0 and self.binding_reservation_id != 0 and
            self.binding_destination_addr != 0 and
            self.runtime_id != 0 and self.mint_receipt.owner_addr == @intFromPtr(self) and
            canonicalPermitLive(self.canonical_permit) and
            @as(*const Authority, @ptrFromInt(self.mint_receipt.authority_addr)).receiptLive(
                self.mint_receipt,
            );
    }
};

fn canonicalPermitLive(permit: client_slot_mod.InitialSnapshotPermit) bool {
    return permit.slot.initialSnapshotPermitLive(permit);
}

fn consumeCanonicalPermit(
    permit: client_slot_mod.InitialSnapshotPermit,
) error{InvalidSnapshotPermit}!void {
    return permit.slot.consumeInitialSnapshotPermit(permit);
}

fn currentPid() u32 {
    return process_identity.currentProcessId();
}
