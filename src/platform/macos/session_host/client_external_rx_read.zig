//! Sealed storage and closed DTOs for one injected external-session RX read turn.
//!
//! C3 adds the injected collector to C1's final-address scratch without importing a pump, parser
//! traversal, ledger, or syscall adapter. Product transport remains reserved for C4/C5.

const std = @import("std");
const builtin = @import("builtin");
const client_external_mode = @import("client_external_mode.zig");
const external_owner_seal = @import("external_owner_seal.zig");

pub const max_rx_read_bytes_per_turn: usize = 1024 * 1024;
pub const max_rx_read_attempts_per_turn: usize = 64;
pub const max_rx_staged_prefix_validation_bytes_per_turn: usize =
    max_rx_read_attempts_per_turn * max_rx_read_bytes_per_turn;
pub const max_external_rx_read_metadata_bytes: usize = 256 * 1024;
pub const max_external_rx_read_scratch_bytes: usize =
    max_rx_read_bytes_per_turn + max_external_rx_read_metadata_bytes;

pub const RxReadOutcome = union(enum) {
    bytes: usize,
    would_block,
    interrupted,
    eof,
    socket_error,
};

pub const RxReadOps = struct {
    context: *anyopaque,
    context_len: usize,
    read: *const fn (
        context: *anyopaque,
        fd: std.posix.fd_t,
        destination: []u8,
    ) RxReadOutcome,
};

pub const RxReadableAllowance = client_external_mode.ReadableAllowance;

pub const FinalParserState = enum {
    empty,
    incomplete,
};

pub const AcceptedAllowanceStop = enum {
    continue_collecting,
    counter_terminal,
    resident_incomplete_terminal,
    immediate,
    invalid,
};

pub fn classifyAcceptedAllowanceStop(
    allowance: RxReadableAllowance,
    accepted_bytes: usize,
    final_parser: FinalParserState,
) AcceptedAllowanceStop {
    if (allowance.bytes == 0 or accepted_bytes > allowance.bytes or
        (!allowance.resident_limited and
            !allowance.turn_limited and
            !allowance.counter_limited))
        return .invalid;
    if (accepted_bytes < allowance.bytes) return .continue_collecting;
    if (allowance.counter_limited) return .counter_terminal;
    if (allowance.resident_limited and final_parser == .incomplete)
        return .resident_incomplete_terminal;
    if (allowance.turn_limited or allowance.resident_limited)
        return .immediate;
    return .invalid;
}

pub const RxReadAuthorityView = struct {
    storage_addr: usize,
    lease_addr: usize,
    scratch_addr: usize,
    scratch_generation: u64,
    client_addr: usize,
    fd: std.posix.fd_t,
    parser_addr: usize,
    parser_seal: client_external_mode.ParserAuthoritySeal,
    owner_snapshot_digest: external_owner_seal.Digest,
    protected_range_count: u8,
    protected_ranges: [max_rx_read_protected_ranges]ProtectedRange,
    view_digest: external_owner_seal.Digest,
};

pub const RxReadAuthorityOps = struct {
    context: *anyopaque,
    context_len: usize,
    current: *const fn (context: *anyopaque) ?RxReadAuthorityView,
};

pub const ProtectedRange = struct {
    addr: usize = 0,
    len: usize = 0,
};

pub const max_rx_read_protected_ranges: usize = 16;
pub const max_consecutive_rx_read_interrupts: u8 = 8;
pub const max_rx_read_authority_callbacks_per_turn: usize =
    2 * max_rx_read_attempts_per_turn;

const Lifecycle = enum {
    empty,
    ready,
    collecting,
    spent,
    borrowed,
    terminal,
    closed,
};

pub const CollectInput = struct {
    allowance: RxReadableAllowance,
    read_ops: *const RxReadOps,
    authority_ops: *const RxReadAuthorityOps,
};

pub const CollectStop = enum {
    would_block,
    allowance_reached,
    attempt_budget_exhausted,
    eof_after_prefix,
    socket_error_after_prefix,
};

pub const CollectReceipt = struct {
    scratch_addr: usize,
    scratch_generation: u64,
    allowance: RxReadableAllowance,
    accepted_bytes: usize,
    attempts: u8,
    stop: CollectStop,
    digest: external_owner_seal.Digest,
};

pub const CollectRejectReason = enum {
    stale_or_moved,
    busy_or_spent,
};

pub const CollectTerminalReason = enum {
    invalid_preflight,
    generation_exhausted,
    authority_missing,
    authority_drift,
    invalid_destination,
    invalid_callback_result,
    staged_prefix_drift,
    interrupt_limit,
    eof,
    socket_error,
    scratch_corruption,
};

pub const CollectTerminalReceipt = struct {
    reason: CollectTerminalReason,
    attempts: u8,
};

pub const CollectResult = union(enum) {
    rejected: CollectRejectReason,
    stopped: CollectReceipt,
    terminal: CollectTerminalReceipt,
};

const BorrowLifecycle = enum { empty, borrowed, settled, aborted };

const BorrowUseLifecycle = enum { empty, active, released, aborted };
const WouldBlockSeedLifecycle = enum { empty, prepared, consumed, aborted };
const PermitSeedLifecycle = enum { unminted, prepared, consumed, aborted };
const PreparedAdmitUseLifecycle = enum { empty, active, finished, aborted };

pub const StoppedBorrow = struct {
    saved_self_addr: usize = 0,
    scratch_addr: usize = 0,
    scratch_generation: u64 = 0,
    receipt_addr: usize = 0,
    receipt_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    bytes_addr: usize = 0,
    bytes_len: usize = 0,
    lifecycle: BorrowLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const BorrowUseGuardOps = struct {
    context: *anyopaque,
    context_len: usize,
    current: *const fn (context: *anyopaque, scratch_addr: usize) ?bool,
};

pub const WouldBlockSeed = struct {
    saved_self_addr: usize = 0,
    scratch_addr: usize = 0,
    scratch_generation: u64 = 0,
    receipt_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    borrow_addr: usize = 0,
    attempt_generation: u64 = 0,
    lifecycle: WouldBlockSeedLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const BorrowUsePermit = struct {
    saved_self_addr: usize = 0,
    scratch_addr: usize = 0,
    scratch_generation: u64 = 0,
    receipt_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    borrow_addr: usize = 0,
    authorized_seed_addr: usize = 0,
    authorized_seed_len: usize = 0,
    guard_context: *anyopaque = undefined,
    guard_context_len: usize = 0,
    guard_current: *const fn (
        context: *anyopaque,
        scratch_addr: usize,
    ) ?bool = undefined,
    seed_lifecycle: PermitSeedLifecycle = .unminted,
    seed_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: BorrowUseLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const PreparedAdmitUsePermit = struct {
    saved_self_addr: usize = 0,
    scratch_addr: usize = 0,
    scratch_generation: u64 = 0,
    receipt_addr: usize = 0,
    borrow_addr: usize = 0,
    use_permit_addr: usize = 0,
    seed_addr: usize = 0,
    frozen_outer_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    frozen_receipt: CollectReceipt = undefined,
    frozen_borrow: StoppedBorrow = .{},
    frozen_use_permit: BorrowUsePermit = .{},
    frozen_seed: WouldBlockSeed = .{},
    lifecycle: PreparedAdmitUseLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const StoppedDisposition = struct {
    staged: enum { consumed, discarded },
    would_block: enum { not_present, consumed, aborted },
};

pub const ReadScratchTeardownResult = enum {
    closed,
    already_closed,
    busy,
    needs_outer_cleanup,
    stale_or_moved,
};

pub const StoppedGraphTerminalizeResult = enum {
    closed,
    already_closed,
    unrecoverable,
};

const ChunkSeal = struct {
    start: usize = 0,
    len: usize = 0,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

const AttemptLifecycle = enum {
    empty,
    callback_active,
    returned,
    consumed,
    aborted,
};

const ReadAttemptPermit = struct {
    saved_self_addr: usize = 0,
    attempt_generation: u64 = 0,
    destination_addr: usize = 0,
    destination_len: usize = 0,
    authority: RxReadAuthorityView = undefined,
    ops_addr: usize = 0,
    frozen_context: *anyopaque = undefined,
    frozen_read: *const fn (
        context: *anyopaque,
        fd: std.posix.fd_t,
        destination: []u8,
    ) RxReadOutcome = undefined,
    lifecycle: AttemptLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

const RawWouldBlockObservation = struct {
    attempt_generation: u64 = 0,
    lifecycle: enum { empty, observed, consumed, aborted } = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const ExternalRxReadScratch = struct {
    saved_self_addr: usize = 0,
    generation: u64 = 0,
    lifecycle: Lifecycle = .empty,
    staged_len: usize = 0,
    attempt_count: u8 = 0,
    chunk_count: u8 = 0,
    consecutive_interrupts: u8 = 0,
    chunks: [max_rx_read_attempts_per_turn]ChunkSeal =
        [_]ChunkSeal{.{}} ** max_rx_read_attempts_per_turn,
    prepared_admit: client_external_mode.PreparedRxAppend = .{},
    attempt: ReadAttemptPermit = .{},
    would_block: RawWouldBlockObservation = .{},
    spent_receipt_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    active_borrow_addr: usize = 0,
    active_borrow_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    active_use_permit_addr: usize = 0,
    active_use_permit_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    active_prepared_use_permit_addr: usize = 0,
    active_prepared_use_permit_digest: external_owner_seal.Digest =
        [_]u8{0} ** 32,
    validation_bytes_checked: usize = 0,
    backing: [max_rx_read_bytes_per_turn]u8 = undefined,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,

    pub fn initInPlace(out: *ExternalRxReadScratch) bool {
        if (out.saved_self_addr != 0 or out.generation != 0 or
            out.lifecycle != .empty)
            return false;
        out.saved_self_addr = @intFromPtr(out);
        out.generation = 1;
        out.lifecycle = .ready;
        out.staged_len = 0;
        out.attempt_count = 0;
        out.chunk_count = 0;
        out.consecutive_interrupts = 0;
        out.chunks = [_]ChunkSeal{.{}} ** max_rx_read_attempts_per_turn;
        out.prepared_admit = .{};
        out.attempt = .{};
        out.would_block = .{};
        out.spent_receipt_digest = [_]u8{0} ** 32;
        out.active_borrow_addr = 0;
        out.active_borrow_digest = [_]u8{0} ** 32;
        out.active_use_permit_addr = 0;
        out.active_use_permit_digest = [_]u8{0} ** 32;
        out.active_prepared_use_permit_addr = 0;
        out.active_prepared_use_permit_digest = [_]u8{0} ** 32;
        out.validation_bytes_checked = 0;
        out.digest = scratchDigest(out);
        return true;
    }

    pub fn isReady(self: *const ExternalRxReadScratch) bool {
        if (self.saved_self_addr != @intFromPtr(self) or
            self.generation == 0 or
            self.lifecycle != .ready or
            self.staged_len != 0 or
            self.attempt_count != 0 or
            self.chunk_count != 0 or
            self.consecutive_interrupts != 0 or
            !client_external_mode.preparedRxAppendPristine(
                &self.prepared_admit,
            ) or
            self.attempt.saved_self_addr != 0 or
            self.attempt.attempt_generation != 0 or
            self.attempt.destination_addr != 0 or
            self.attempt.destination_len != 0 or
            self.attempt.ops_addr != 0 or
            self.attempt.lifecycle != .empty or
            !std.mem.allEqual(u8, &self.attempt.digest, 0) or
            self.would_block.attempt_generation != 0 or
            self.would_block.lifecycle != .empty or
            !std.mem.allEqual(u8, &self.would_block.digest, 0) or
            !std.mem.allEqual(u8, &self.spent_receipt_digest, 0) or
            self.active_borrow_addr != 0 or
            !std.mem.allEqual(u8, &self.active_borrow_digest, 0) or
            self.active_use_permit_addr != 0 or
            !std.mem.allEqual(u8, &self.active_use_permit_digest, 0) or
            self.active_prepared_use_permit_addr != 0 or
            !std.mem.allEqual(
                u8,
                &self.active_prepared_use_permit_digest,
                0,
            ) or
            self.validation_bytes_checked != 0 or
            !std.mem.eql(u8, &self.digest, &scratchDigest(self)))
            return false;
        for (self.chunks) |chunk| {
            if (chunk.start != 0 or chunk.len != 0 or
                !std.mem.allEqual(u8, &chunk.digest, 0))
                return false;
        }
        return true;
    }
};

fn scratchDigest(
    scratch: *const ExternalRxReadScratch,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARURDS1");
    writer.writeUsize(scratch.saved_self_addr);
    writer.writeU64(scratch.generation);
    writer.writeU8(@intFromEnum(scratch.lifecycle));
    writer.writeUsize(@intFromPtr(&scratch.backing));
    writer.writeUsize(scratch.backing.len);
    writer.writeUsize(scratch.staged_len);
    writer.writeU8(scratch.attempt_count);
    writer.writeU8(scratch.chunk_count);
    writer.writeU8(scratch.consecutive_interrupts);
    for (scratch.chunks) |chunk| {
        writer.writeUsize(chunk.start);
        writer.writeUsize(chunk.len);
        writer.writeBytes(&chunk.digest);
    }
    writer.writeUsize(scratch.prepared_admit.saved_self_addr);
    writer.writeUsize(scratch.prepared_admit.state_addr);
    writer.writeUsize(scratch.prepared_admit.parser_addr);
    writer.writeU8(@intFromEnum(scratch.prepared_admit.lifecycle));
    writer.writeUsize(scratch.attempt.saved_self_addr);
    writer.writeU64(scratch.attempt.attempt_generation);
    writer.writeUsize(scratch.attempt.destination_addr);
    writer.writeUsize(scratch.attempt.destination_len);
    writer.writeUsize(scratch.attempt.ops_addr);
    writer.writeU8(@intFromEnum(scratch.attempt.lifecycle));
    writer.writeBytes(&scratch.attempt.digest);
    writer.writeU64(scratch.would_block.attempt_generation);
    writer.writeU8(@intFromEnum(scratch.would_block.lifecycle));
    writer.writeBytes(&scratch.would_block.digest);
    writer.writeBytes(&scratch.spent_receipt_digest);
    writer.writeUsize(scratch.active_borrow_addr);
    writer.writeBytes(&scratch.active_borrow_digest);
    writer.writeUsize(scratch.active_use_permit_addr);
    writer.writeBytes(&scratch.active_use_permit_digest);
    writer.writeUsize(scratch.active_prepared_use_permit_addr);
    writer.writeBytes(&scratch.active_prepared_use_permit_digest);
    writer.writeUsize(scratch.validation_bytes_checked);
    return writer.finish();
}

fn receiptDigest(receipt: *const CollectReceipt) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARURCR1");
    writer.writeUsize(receipt.scratch_addr);
    writer.writeU64(receipt.scratch_generation);
    writer.writeUsize(receipt.allowance.bytes);
    writer.writeBool(receipt.allowance.resident_limited);
    writer.writeBool(receipt.allowance.turn_limited);
    writer.writeBool(receipt.allowance.counter_limited);
    writer.writeUsize(receipt.accepted_bytes);
    writer.writeU8(receipt.attempts);
    writer.writeU8(@intFromEnum(receipt.stop));
    return writer.finish();
}

fn borrowDigest(borrow: *const StoppedBorrow) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARURBR1");
    writer.writeUsize(borrow.saved_self_addr);
    writer.writeUsize(borrow.scratch_addr);
    writer.writeU64(borrow.scratch_generation);
    writer.writeUsize(borrow.receipt_addr);
    writer.writeBytes(&borrow.receipt_digest);
    writer.writeUsize(borrow.bytes_addr);
    writer.writeUsize(borrow.bytes_len);
    writer.writeU8(@intFromEnum(borrow.lifecycle));
    return writer.finish();
}

fn wouldBlockSeedDigest(
    seed: *const WouldBlockSeed,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARURWS1");
    writer.writeUsize(seed.saved_self_addr);
    writer.writeUsize(seed.scratch_addr);
    writer.writeU64(seed.scratch_generation);
    writer.writeBytes(&seed.receipt_digest);
    writer.writeUsize(seed.borrow_addr);
    writer.writeU64(seed.attempt_generation);
    writer.writeU8(@intFromEnum(seed.lifecycle));
    return writer.finish();
}

fn borrowUsePermitDigest(
    permit: *const BorrowUsePermit,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARURUP1");
    writer.writeUsize(permit.saved_self_addr);
    writer.writeUsize(permit.scratch_addr);
    writer.writeU64(permit.scratch_generation);
    writer.writeBytes(&permit.receipt_digest);
    writer.writeUsize(permit.borrow_addr);
    writer.writeUsize(permit.authorized_seed_addr);
    writer.writeUsize(permit.authorized_seed_len);
    writer.writeUsize(@intFromPtr(permit.guard_context));
    writer.writeUsize(permit.guard_context_len);
    writer.writeUsize(@intFromPtr(permit.guard_current));
    writer.writeU8(@intFromEnum(permit.seed_lifecycle));
    writer.writeBytes(&permit.seed_digest);
    writer.writeU8(@intFromEnum(permit.lifecycle));
    return writer.finish();
}

fn scratchPreparedOuterDigest(
    scratch: *const ExternalRxReadScratch,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARURPO1");
    writer.writeUsize(scratch.saved_self_addr);
    writer.writeU64(scratch.generation);
    writer.writeU8(@intFromEnum(scratch.lifecycle));
    writer.writeUsize(@intFromPtr(&scratch.backing));
    writer.writeUsize(scratch.backing.len);
    writer.writeUsize(scratch.staged_len);
    writer.writeU8(scratch.attempt_count);
    writer.writeU8(scratch.chunk_count);
    writer.writeU8(scratch.consecutive_interrupts);
    for (scratch.chunks) |chunk| {
        writer.writeUsize(chunk.start);
        writer.writeUsize(chunk.len);
        writer.writeBytes(&chunk.digest);
    }
    writer.writeUsize(scratch.attempt.saved_self_addr);
    writer.writeU64(scratch.attempt.attempt_generation);
    writer.writeUsize(scratch.attempt.destination_addr);
    writer.writeUsize(scratch.attempt.destination_len);
    writer.writeUsize(scratch.attempt.ops_addr);
    writer.writeU8(@intFromEnum(scratch.attempt.lifecycle));
    writer.writeBytes(&scratch.attempt.digest);
    writer.writeU64(scratch.would_block.attempt_generation);
    writer.writeU8(@intFromEnum(scratch.would_block.lifecycle));
    writer.writeBytes(&scratch.would_block.digest);
    writer.writeBytes(&scratch.spent_receipt_digest);
    writer.writeUsize(scratch.active_borrow_addr);
    writer.writeBytes(&scratch.active_borrow_digest);
    writer.writeUsize(scratch.active_use_permit_addr);
    writer.writeBytes(&scratch.active_use_permit_digest);
    writer.writeUsize(scratch.validation_bytes_checked);
    return writer.finish();
}

fn preparedAdmitUsePermitDigest(
    permit: *const PreparedAdmitUsePermit,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARURPU1");
    writer.writeUsize(permit.saved_self_addr);
    writer.writeUsize(permit.scratch_addr);
    writer.writeU64(permit.scratch_generation);
    writer.writeUsize(permit.receipt_addr);
    writer.writeUsize(permit.borrow_addr);
    writer.writeUsize(permit.use_permit_addr);
    writer.writeUsize(permit.seed_addr);
    writer.writeBytes(&permit.frozen_outer_digest);
    writer.writeBytes(&receiptDigest(&permit.frozen_receipt));
    writer.writeBytes(&borrowDigest(&permit.frozen_borrow));
    writer.writeBytes(&borrowUsePermitDigest(&permit.frozen_use_permit));
    writer.writeBytes(&wouldBlockSeedDigest(&permit.frozen_seed));
    writer.writeU8(@intFromEnum(permit.lifecycle));
    return writer.finish();
}

fn rangeEnd(addr: usize, len: usize) ?usize {
    if (addr == 0 or len == 0) return null;
    return std.math.add(usize, addr, len) catch null;
}

fn rangesOverlap(
    left_addr: usize,
    left_len: usize,
    right_addr: usize,
    right_len: usize,
) bool {
    const left_end = rangeEnd(left_addr, left_len) orelse return true;
    const right_end = rangeEnd(right_addr, right_len) orelse return true;
    return left_addr < right_end and right_addr < left_end;
}

fn stoppedGraphRangesDisjoint(
    scratch: *const ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *const StoppedBorrow,
    use_permit: *const BorrowUsePermit,
    seed: *const WouldBlockSeed,
    prepared_use: *const PreparedAdmitUsePermit,
) bool {
    const ranges = [_]ProtectedRange{
        .{ .addr = @intFromPtr(scratch), .len = @sizeOf(ExternalRxReadScratch) },
        .{ .addr = @intFromPtr(receipt), .len = @sizeOf(CollectReceipt) },
        .{ .addr = @intFromPtr(borrow), .len = @sizeOf(StoppedBorrow) },
        .{ .addr = @intFromPtr(use_permit), .len = @sizeOf(BorrowUsePermit) },
        .{ .addr = @intFromPtr(seed), .len = @sizeOf(WouldBlockSeed) },
        .{
            .addr = @intFromPtr(prepared_use),
            .len = @sizeOf(PreparedAdmitUsePermit),
        },
    };
    for (ranges, 0..) |left, index| {
        if (rangeEnd(left.addr, left.len) == null) return false;
        for (ranges[index + 1 ..]) |right|
            if (rangesOverlap(left.addr, left.len, right.addr, right.len))
                return false;
    }
    return true;
}

pub fn writeParserSeal(
    writer: *external_owner_seal.Writer,
    seal: *const client_external_mode.ParserAuthoritySeal,
) void {
    writer.writeBytes(&seal.domain);
    writer.writeU16(seal.version);
    writer.writeUsize(seal.seal_addr);
    writer.writeUsize(seal.parser_addr);
    writer.writeU64(seal.identity.attach_instance_id);
    writer.writeUsize(seal.identity.destination_slot_addr);
    writer.writeUsize(seal.destination_slot_len);
    writer.writeUsize(seal.allocator_ptr_addr);
    writer.writeUsize(seal.allocator_vtable_addr);
    writer.writeU16(seal.expected_major);
    writer.writeUsize(seal.backing_addr);
    writer.writeUsize(seal.items_len);
    writer.writeUsize(seal.capacity);
    writer.writeUsize(seal.head);
    writer.writeU64(seal.buffer_start_absolute);
    writer.writeU64(seal.rx_absolute_next);
    writer.writeUsize(seal.resident_cap);
    writer.writeU64(seal.generation);
    writer.writeBytes(&seal.digest);
}

/// Seals the value-only projection produced by C4 or the dedicated hostile fixture.
///
/// The digest is only a compact corruption detector. `collectInjected` still compares every
/// semantic field and protected range before treating the projection as authority.
pub fn sealAuthorityView(
    view: *RxReadAuthorityView,
) void {
    var writer = external_owner_seal.Writer.init("MARURAV1");
    writer.writeUsize(view.storage_addr);
    writer.writeUsize(view.lease_addr);
    writer.writeUsize(view.scratch_addr);
    writer.writeU64(view.scratch_generation);
    writer.writeUsize(view.client_addr);
    writer.writeU64(@as(u32, @bitCast(view.fd)));
    writer.writeUsize(view.parser_addr);
    writeParserSeal(&writer, &view.parser_seal);
    writer.writeBytes(&view.owner_snapshot_digest);
    writer.writeU8(view.protected_range_count);
    for (view.protected_ranges) |protected| {
        writer.writeUsize(protected.addr);
        writer.writeUsize(protected.len);
    }
    view.view_digest = writer.finish();
}

fn authorityViewValid(
    view: *const RxReadAuthorityView,
    scratch: *const ExternalRxReadScratch,
    read_context_addr: usize,
    read_context_len: usize,
    authority_context_addr: usize,
    authority_context_len: usize,
) bool {
    if (view.storage_addr == 0 or view.lease_addr == 0 or
        view.client_addr == 0 or view.parser_addr == 0 or
        view.scratch_addr != @intFromPtr(scratch) or
        view.scratch_generation != scratch.generation or
        view.parser_seal.parser_addr != view.parser_addr or
        !client_external_mode.parserAuthoritySealStructurallyValid(
            &view.parser_seal,
        ) or
        view.protected_range_count == 0 or
        view.protected_range_count > max_rx_read_protected_ranges)
        return false;

    var expected = view.*;
    sealAuthorityView(&expected);
    if (!std.mem.eql(u8, &view.view_digest, &expected.view_digest))
        return false;

    const backing_addr = @intFromPtr(&scratch.backing);
    var read_context_matches: u8 = 0;
    var authority_context_matches: u8 = 0;
    var parser_backing_matches: u8 = 0;
    var previous_end: usize = 0;
    for (view.protected_ranges, 0..) |protected, index| {
        if (index >= view.protected_range_count) {
            if (protected.addr != 0 or protected.len != 0) return false;
            continue;
        }
        const end = rangeEnd(protected.addr, protected.len) orelse return false;
        if (index != 0 and protected.addr < previous_end) return false;
        previous_end = end;
        if (rangesOverlap(
            protected.addr,
            protected.len,
            backing_addr,
            scratch.backing.len,
        )) return false;
        if (protected.addr == read_context_addr and
            protected.len == read_context_len)
            read_context_matches += 1;
        if (protected.addr == authority_context_addr and
            protected.len == authority_context_len)
            authority_context_matches += 1;
        if (protected.addr == view.parser_seal.backing_addr and
            protected.len == view.parser_seal.capacity)
            parser_backing_matches += 1;
    }
    return read_context_matches == 1 and
        authority_context_matches == 1 and
        parser_backing_matches ==
            @intFromBool(view.parser_seal.capacity != 0);
}

fn descriptorsValid(
    scratch: *const ExternalRxReadScratch,
    read_ops: *const RxReadOps,
    authority_ops: *const RxReadAuthorityOps,
) bool {
    const scratch_addr = @intFromPtr(scratch);
    const read_ops_addr = @intFromPtr(read_ops);
    const authority_ops_addr = @intFromPtr(authority_ops);
    const read_context_addr = @intFromPtr(read_ops.context);
    const authority_context_addr = @intFromPtr(authority_ops.context);
    if (rangeEnd(read_context_addr, read_ops.context_len) == null or
        rangeEnd(authority_context_addr, authority_ops.context_len) == null)
        return false;
    const ranges = [_]ProtectedRange{
        .{ .addr = scratch_addr, .len = @sizeOf(ExternalRxReadScratch) },
        .{ .addr = read_ops_addr, .len = @sizeOf(RxReadOps) },
        .{ .addr = authority_ops_addr, .len = @sizeOf(RxReadAuthorityOps) },
        .{ .addr = read_context_addr, .len = read_ops.context_len },
        .{ .addr = authority_context_addr, .len = authority_ops.context_len },
    };
    for (ranges, 0..) |left, left_index| {
        if (rangeEnd(left.addr, left.len) == null) return false;
        for (ranges[left_index + 1 ..]) |right| {
            if (rangesOverlap(left.addr, left.len, right.addr, right.len))
                return false;
        }
    }
    return true;
}

fn descriptorsUnchanged(
    read_ops: *const RxReadOps,
    authority_ops: *const RxReadAuthorityOps,
    frozen_read_context: *anyopaque,
    frozen_read_context_len: usize,
    frozen_read: *const fn (
        context: *anyopaque,
        fd: std.posix.fd_t,
        destination: []u8,
    ) RxReadOutcome,
    frozen_authority_context: *anyopaque,
    frozen_authority_context_len: usize,
    frozen_current: *const fn (context: *anyopaque) ?RxReadAuthorityView,
) bool {
    return read_ops.context == frozen_read_context and
        read_ops.context_len == frozen_read_context_len and
        read_ops.read == frozen_read and
        authority_ops.context == frozen_authority_context and
        authority_ops.context_len == frozen_authority_context_len and
        authority_ops.current == frozen_current;
}

fn chunkDigest(bytes: []const u8) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARURCK1");
    writer.writeBytes(bytes);
    return writer.finish();
}

fn attemptDigest(attempt: *const ReadAttemptPermit) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARURAP1");
    writer.writeUsize(attempt.saved_self_addr);
    writer.writeU64(attempt.attempt_generation);
    writer.writeUsize(attempt.destination_addr);
    writer.writeUsize(attempt.destination_len);
    writer.writeUsize(attempt.ops_addr);
    writer.writeUsize(@intFromPtr(attempt.frozen_context));
    writer.writeUsize(@intFromPtr(attempt.frozen_read));
    var authority = attempt.authority;
    sealAuthorityView(&authority);
    writer.writeBytes(&authority.view_digest);
    writer.writeU8(@intFromEnum(attempt.lifecycle));
    return writer.finish();
}

fn attemptMatches(
    attempt: *const ReadAttemptPermit,
    expected_authority: RxReadAuthorityView,
    generation: u64,
    destination_addr: usize,
    destination_len: usize,
    ops_addr: usize,
    context: *anyopaque,
    read_fn: *const fn (
        context: *anyopaque,
        fd: std.posix.fd_t,
        destination: []u8,
    ) RxReadOutcome,
    lifecycle: AttemptLifecycle,
) bool {
    return attempt.saved_self_addr == @intFromPtr(attempt) and
        attempt.attempt_generation == generation and
        attempt.destination_addr == destination_addr and
        attempt.destination_len == destination_len and
        std.meta.eql(attempt.authority, expected_authority) and
        attempt.ops_addr == ops_addr and
        attempt.frozen_context == context and attempt.frozen_read == read_fn and
        attempt.lifecycle == lifecycle and
        std.mem.eql(u8, &attempt.digest, &attemptDigest(attempt));
}

fn wouldBlockDigest(
    observation: *const RawWouldBlockObservation,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARURWB1");
    writer.writeU64(observation.attempt_generation);
    writer.writeU8(@intFromEnum(observation.lifecycle));
    return writer.finish();
}

fn scratchCollectingValid(
    scratch: *const ExternalRxReadScratch,
    generation: u64,
) bool {
    return scratch.saved_self_addr == @intFromPtr(scratch) and
        scratch.generation == generation and
        scratch.lifecycle == .collecting and
        scratch.staged_len <= max_rx_read_bytes_per_turn and
        scratch.attempt_count <= max_rx_read_attempts_per_turn and
        scratch.chunk_count <= scratch.attempt_count and
        client_external_mode.preparedRxAppendPristine(
            &scratch.prepared_admit,
        ) and
        std.mem.eql(u8, &scratch.digest, &scratchDigest(scratch));
}

fn validateStagedPrefix(
    scratch: *ExternalRxReadScratch,
    additional: usize,
) bool {
    const total = std.math.add(
        usize,
        scratch.staged_len,
        additional,
    ) catch return false;
    if (total > scratch.backing.len) return false;
    const next_checked = std.math.add(
        usize,
        scratch.validation_bytes_checked,
        total,
    ) catch return false;
    if (next_checked > max_rx_staged_prefix_validation_bytes_per_turn)
        return false;

    var cursor: usize = 0;
    for (0..scratch.chunk_count) |index| {
        const chunk = &scratch.chunks[index];
        if (chunk.start != cursor or chunk.len == 0 or
            chunk.len > scratch.staged_len - cursor)
            return false;
        const end = cursor + chunk.len;
        if (!std.mem.eql(
            u8,
            &chunk.digest,
            &chunkDigest(scratch.backing[cursor..end]),
        )) return false;
        cursor = end;
    }
    if (cursor != scratch.staged_len) return false;
    scratch.validation_bytes_checked = next_checked;
    return true;
}

fn stagedPrefixIntact(scratch: *const ExternalRxReadScratch) bool {
    if (scratch.staged_len > scratch.backing.len or
        scratch.chunk_count > scratch.attempt_count)
        return false;
    var cursor: usize = 0;
    for (scratch.chunks, 0..) |chunk, index| {
        if (index >= scratch.chunk_count) {
            if (chunk.start != 0 or chunk.len != 0 or
                !std.mem.allEqual(u8, &chunk.digest, 0))
                return false;
            continue;
        }
        if (chunk.start != cursor or chunk.len == 0 or
            chunk.len > scratch.staged_len - cursor)
            return false;
        const end = cursor + chunk.len;
        if (!std.mem.eql(
            u8,
            &chunk.digest,
            &chunkDigest(scratch.backing[cursor..end]),
        )) return false;
        cursor = end;
    }
    return cursor == scratch.staged_len;
}

fn rawObservationMatchesReceipt(
    scratch: *const ExternalRxReadScratch,
    receipt: *const CollectReceipt,
) bool {
    if (receipt.stop == .would_block) {
        return scratch.would_block.lifecycle == .observed and
            scratch.would_block.attempt_generation == receipt.attempts and
            std.mem.eql(
                u8,
                &scratch.would_block.digest,
                &wouldBlockDigest(&scratch.would_block),
            );
    }
    return scratch.would_block.attempt_generation == 0 and
        scratch.would_block.lifecycle == .empty and
        std.mem.allEqual(u8, &scratch.would_block.digest, 0);
}

fn finishTerminal(
    scratch: *ExternalRxReadScratch,
    reason: CollectTerminalReason,
    generation: u64,
) CollectResult {
    const attempts = scratch.attempt_count;
    const prepared_admit = scratch.prepared_admit;
    scratch.* = .{
        .saved_self_addr = @intFromPtr(scratch),
        .generation = generation,
        .lifecycle = .terminal,
        .prepared_admit = prepared_admit,
    };
    scratch.digest = scratchDigest(scratch);
    return .{ .terminal = .{ .reason = reason, .attempts = attempts } };
}

fn finishStopped(
    scratch: *ExternalRxReadScratch,
    allowance: RxReadableAllowance,
    stop: CollectStop,
) CollectResult {
    scratch.lifecycle = .spent;
    var receipt = CollectReceipt{
        .scratch_addr = @intFromPtr(scratch),
        .scratch_generation = scratch.generation,
        .allowance = allowance,
        .accepted_bytes = scratch.staged_len,
        .attempts = scratch.attempt_count,
        .stop = stop,
        .digest = undefined,
    };
    receipt.digest = receiptDigest(&receipt);
    scratch.spent_receipt_digest = receipt.digest;
    scratch.digest = scratchDigest(scratch);
    return .{ .stopped = receipt };
}

pub fn collectInjected(
    scratch: *ExternalRxReadScratch,
    input: CollectInput,
) CollectResult {
    if (scratch.saved_self_addr != @intFromPtr(scratch))
        return .{ .rejected = .stale_or_moved };
    if (scratch.lifecycle != .ready)
        return .{ .rejected = .busy_or_spent };
    if (!scratch.isReady() or input.allowance.bytes == 0 or
        input.allowance.bytes > max_rx_read_bytes_per_turn or
        (!input.allowance.resident_limited and
            !input.allowance.turn_limited and
            !input.allowance.counter_limited) or
        !descriptorsValid(scratch, input.read_ops, input.authority_ops))
    {
        return finishTerminal(scratch, .invalid_preflight, scratch.generation);
    }
    if (scratch.generation == std.math.maxInt(u64)) {
        return finishTerminal(scratch, .generation_exhausted, scratch.generation);
    }

    const generation = scratch.generation;
    const read_ops = input.read_ops;
    const authority_ops = input.authority_ops;
    const frozen_read_context = read_ops.context;
    const frozen_read_context_len = read_ops.context_len;
    const frozen_read = read_ops.read;
    const frozen_authority_context = authority_ops.context;
    const frozen_authority_context_len = authority_ops.context_len;
    const frozen_current = authority_ops.current;
    scratch.lifecycle = .collecting;
    scratch.digest = scratchDigest(scratch);

    while (scratch.attempt_count < max_rx_read_attempts_per_turn) {
        const pre = frozen_current(frozen_authority_context) orelse
            return finishTerminal(scratch, .authority_missing, generation);
        if (!descriptorsUnchanged(
            read_ops,
            authority_ops,
            frozen_read_context,
            frozen_read_context_len,
            frozen_read,
            frozen_authority_context,
            frozen_authority_context_len,
            frozen_current,
        ) or !scratchCollectingValid(scratch, generation) or
            !authorityViewValid(
                &pre,
                scratch,
                @intFromPtr(frozen_read_context),
                frozen_read_context_len,
                @intFromPtr(frozen_authority_context),
                frozen_authority_context_len,
            ))
            return finishTerminal(scratch, .authority_drift, generation);

        const remaining = input.allowance.bytes - scratch.staged_len;
        if (remaining == 0)
            return finishStopped(scratch, input.allowance, .allowance_reached);
        const destination_addr = std.math.add(
            usize,
            @intFromPtr(&scratch.backing),
            scratch.staged_len,
        ) catch return finishTerminal(scratch, .invalid_destination, generation);
        const destination_len = @min(
            remaining,
            scratch.backing.len - scratch.staged_len,
        );
        if (destination_len == 0 or
            rangesOverlap(
                destination_addr,
                destination_len,
                @intFromPtr(scratch),
                @offsetOf(ExternalRxReadScratch, "backing"),
            ))
            return finishTerminal(scratch, .invalid_destination, generation);
        for (pre.protected_ranges[0..pre.protected_range_count]) |protected| {
            if (rangesOverlap(
                destination_addr,
                destination_len,
                protected.addr,
                protected.len,
            )) return finishTerminal(
                scratch,
                .invalid_destination,
                generation,
            );
        }

        const attempt_generation: u64 = @as(u64, scratch.attempt_count) + 1;
        scratch.attempt = .{
            .saved_self_addr = @intFromPtr(&scratch.attempt),
            .attempt_generation = attempt_generation,
            .destination_addr = destination_addr,
            .destination_len = destination_len,
            .authority = pre,
            .ops_addr = @intFromPtr(read_ops),
            .frozen_context = frozen_read_context,
            .frozen_read = frozen_read,
            .lifecycle = .callback_active,
        };
        scratch.attempt.digest = attemptDigest(&scratch.attempt);
        scratch.digest = scratchDigest(scratch);
        const callback_active_digest = scratch.digest;
        const frozen_attempt_count = scratch.attempt_count;

        const result = frozen_read(
            frozen_read_context,
            pre.fd,
            scratch.backing[scratch.staged_len .. scratch.staged_len + destination_len],
        );
        const read_state_valid = scratchCollectingValid(
            scratch,
            generation,
        ) and std.mem.eql(
            u8,
            &scratch.digest,
            &callback_active_digest,
        ) and attemptMatches(
            &scratch.attempt,
            pre,
            attempt_generation,
            destination_addr,
            destination_len,
            @intFromPtr(read_ops),
            frozen_read_context,
            frozen_read,
            .callback_active,
        );
        scratch.attempt = .{
            .saved_self_addr = @intFromPtr(&scratch.attempt),
            .attempt_generation = attempt_generation,
            .destination_addr = destination_addr,
            .destination_len = destination_len,
            .authority = pre,
            .ops_addr = @intFromPtr(read_ops),
            .frozen_context = frozen_read_context,
            .frozen_read = frozen_read,
            .lifecycle = .returned,
        };
        scratch.attempt.digest = attemptDigest(&scratch.attempt);
        scratch.attempt_count = frozen_attempt_count + 1;
        if (!read_state_valid) {
            scratch.attempt.lifecycle = .aborted;
            scratch.attempt.digest = attemptDigest(&scratch.attempt);
            scratch.digest = scratchDigest(scratch);
            return finishTerminal(scratch, .authority_drift, generation);
        }
        scratch.digest = scratchDigest(scratch);
        const returned_digest = scratch.digest;

        const post = frozen_current(frozen_authority_context) orelse {
            scratch.attempt.lifecycle = .aborted;
            scratch.attempt.digest = attemptDigest(&scratch.attempt);
            scratch.digest = scratchDigest(scratch);
            return finishTerminal(scratch, .authority_missing, generation);
        };
        const authority_ok = std.meta.eql(pre, post) and
            descriptorsUnchanged(
                read_ops,
                authority_ops,
                frozen_read_context,
                frozen_read_context_len,
                frozen_read,
                frozen_authority_context,
                frozen_authority_context_len,
                frozen_current,
            ) and
            scratchCollectingValid(scratch, generation) and
            std.mem.eql(u8, &scratch.digest, &returned_digest) and
            attemptMatches(
                &scratch.attempt,
                pre,
                attempt_generation,
                destination_addr,
                destination_len,
                @intFromPtr(read_ops),
                frozen_read_context,
                frozen_read,
                .returned,
            ) and
            authorityViewValid(
                &post,
                scratch,
                @intFromPtr(frozen_read_context),
                frozen_read_context_len,
                @intFromPtr(frozen_authority_context),
                frozen_authority_context_len,
            );
        scratch.attempt = .{
            .saved_self_addr = @intFromPtr(&scratch.attempt),
            .attempt_generation = attempt_generation,
            .destination_addr = destination_addr,
            .destination_len = destination_len,
            .authority = pre,
            .ops_addr = @intFromPtr(read_ops),
            .frozen_context = frozen_read_context,
            .frozen_read = frozen_read,
            .lifecycle = if (authority_ok) .consumed else .aborted,
        };
        scratch.attempt.digest = attemptDigest(&scratch.attempt);
        scratch.digest = scratchDigest(scratch);
        if (!authority_ok)
            return finishTerminal(scratch, .authority_drift, generation);

        const additional: usize = switch (result) {
            .bytes => |count| blk: {
                if (count == 0 or count > destination_len)
                    return finishTerminal(
                        scratch,
                        .invalid_callback_result,
                        generation,
                    );
                break :blk count;
            },
            else => 0,
        };
        if (!validateStagedPrefix(scratch, additional))
            return finishTerminal(scratch, .staged_prefix_drift, generation);

        switch (result) {
            .bytes => |count| {
                const old_staged = scratch.staged_len;
                scratch.chunks[scratch.chunk_count] = .{
                    .start = old_staged,
                    .len = count,
                    .digest = chunkDigest(
                        scratch.backing[old_staged .. old_staged + count],
                    ),
                };
                scratch.chunk_count += 1;
                scratch.staged_len += count;
                scratch.consecutive_interrupts = 0;
                scratch.digest = scratchDigest(scratch);
                if (scratch.staged_len == input.allowance.bytes)
                    return finishStopped(
                        scratch,
                        input.allowance,
                        .allowance_reached,
                    );
            },
            .would_block => {
                scratch.would_block = .{
                    .attempt_generation = attempt_generation,
                    .lifecycle = .observed,
                };
                scratch.would_block.digest =
                    wouldBlockDigest(&scratch.would_block);
                scratch.digest = scratchDigest(scratch);
                return finishStopped(
                    scratch,
                    input.allowance,
                    .would_block,
                );
            },
            .interrupted => {
                scratch.consecutive_interrupts += 1;
                scratch.digest = scratchDigest(scratch);
                if (scratch.consecutive_interrupts >
                    max_consecutive_rx_read_interrupts)
                    return finishTerminal(scratch, .interrupt_limit, generation);
            },
            .eof => return if (scratch.staged_len == 0)
                finishTerminal(scratch, .eof, generation)
            else
                finishStopped(scratch, input.allowance, .eof_after_prefix),
            .socket_error => return if (scratch.staged_len == 0)
                finishTerminal(scratch, .socket_error, generation)
            else
                finishStopped(
                    scratch,
                    input.allowance,
                    .socket_error_after_prefix,
                ),
        }
    }
    return finishStopped(
        scratch,
        input.allowance,
        .attempt_budget_exhausted,
    );
}

fn receiptMatchesScratch(
    scratch: *const ExternalRxReadScratch,
    receipt: *const CollectReceipt,
) bool {
    return receipt.scratch_addr == @intFromPtr(scratch) and
        receipt.scratch_generation == scratch.generation and
        receipt.accepted_bytes == scratch.staged_len and
        receipt.accepted_bytes <= receipt.allowance.bytes and
        receipt.allowance.bytes != 0 and
        (receipt.allowance.resident_limited or
            receipt.allowance.turn_limited or
            receipt.allowance.counter_limited) and
        receipt.attempts == scratch.attempt_count and
        stagedPrefixIntact(scratch) and
        rawObservationMatchesReceipt(scratch, receipt) and
        std.mem.eql(u8, &receipt.digest, &receiptDigest(receipt)) and
        std.mem.eql(
            u8,
            &scratch.spent_receipt_digest,
            &receipt.digest,
        ) and
        std.mem.eql(u8, &scratch.digest, &scratchDigest(scratch));
}

pub fn borrowStopped(
    scratch: *ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    out: *StoppedBorrow,
) bool {
    if (rangesOverlap(
        @intFromPtr(receipt),
        @sizeOf(CollectReceipt),
        @intFromPtr(scratch),
        @sizeOf(ExternalRxReadScratch),
    ) or rangesOverlap(
        @intFromPtr(receipt),
        @sizeOf(CollectReceipt),
        @intFromPtr(out),
        @sizeOf(StoppedBorrow),
    ) or rangesOverlap(
        @intFromPtr(out),
        @sizeOf(StoppedBorrow),
        @intFromPtr(scratch),
        @sizeOf(ExternalRxReadScratch),
    ) or rangesOverlap(
        @intFromPtr(out),
        @sizeOf(StoppedBorrow),
        @intFromPtr(receipt),
        @sizeOf(CollectReceipt),
    ) or
        scratch.saved_self_addr != @intFromPtr(scratch) or
        scratch.lifecycle != .spent or
        !receiptMatchesScratch(scratch, receipt) or
        out.saved_self_addr != 0 or out.lifecycle != .empty)
        return false;
    const bytes_addr = @intFromPtr(&scratch.backing);
    scratch.lifecycle = .borrowed;
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .scratch_addr = @intFromPtr(scratch),
        .scratch_generation = scratch.generation,
        .receipt_addr = @intFromPtr(receipt),
        .receipt_digest = receipt.digest,
        .bytes_addr = bytes_addr,
        .bytes_len = scratch.staged_len,
        .lifecycle = .borrowed,
    };
    out.digest = borrowDigest(out);
    scratch.active_borrow_addr = @intFromPtr(out);
    scratch.active_borrow_digest = out.digest;
    scratch.digest = scratchDigest(scratch);
    return true;
}

pub fn stoppedBytes(
    scratch: *const ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *const StoppedBorrow,
) ?[]const u8 {
    if (rangesOverlap(
        @intFromPtr(receipt),
        @sizeOf(CollectReceipt),
        @intFromPtr(scratch),
        @sizeOf(ExternalRxReadScratch),
    ) or rangesOverlap(
        @intFromPtr(receipt),
        @sizeOf(CollectReceipt),
        @intFromPtr(borrow),
        @sizeOf(StoppedBorrow),
    ) or rangesOverlap(
        @intFromPtr(borrow),
        @sizeOf(StoppedBorrow),
        @intFromPtr(scratch),
        @sizeOf(ExternalRxReadScratch),
    ) or rangesOverlap(
        @intFromPtr(borrow),
        @sizeOf(StoppedBorrow),
        @intFromPtr(receipt),
        @sizeOf(CollectReceipt),
    ) or
        scratch.saved_self_addr != @intFromPtr(scratch) or
        scratch.lifecycle != .borrowed or
        !receiptMatchesScratch(scratch, receipt) or
        borrow.saved_self_addr != @intFromPtr(borrow) or
        borrow.scratch_addr != @intFromPtr(scratch) or
        borrow.scratch_generation != scratch.generation or
        borrow.receipt_addr != @intFromPtr(receipt) or
        borrow.bytes_addr != @intFromPtr(&scratch.backing) or
        borrow.bytes_len != scratch.staged_len or
        borrow.lifecycle != .borrowed or
        !std.mem.eql(u8, &borrow.digest, &borrowDigest(borrow)) or
        scratch.active_borrow_addr != @intFromPtr(borrow) or
        !std.mem.eql(
            u8,
            &scratch.active_borrow_digest,
            &borrow.digest,
        ) or
        !std.mem.eql(u8, &scratch.digest, &scratchDigest(scratch)))
        return null;
    return scratch.backing[0..scratch.staged_len];
}

fn permitMatchesScratch(
    scratch: *const ExternalRxReadScratch,
    permit: *const BorrowUsePermit,
) bool {
    return permit.saved_self_addr == @intFromPtr(permit) and
        permit.scratch_addr == @intFromPtr(scratch) and
        permit.scratch_generation == scratch.generation and
        permit.authorized_seed_len == @sizeOf(WouldBlockSeed) and
        rangeEnd(permit.authorized_seed_addr, permit.authorized_seed_len) !=
            null and
        permit.guard_context_len != 0 and
        rangeEnd(
            @intFromPtr(permit.guard_context),
            permit.guard_context_len,
        ) != null and
        permit.lifecycle == .active and
        std.mem.eql(u8, &permit.digest, &borrowUsePermitDigest(permit)) and
        scratch.active_use_permit_addr == @intFromPtr(permit) and
        std.mem.eql(
            u8,
            &scratch.active_use_permit_digest,
            &permit.digest,
        ) and
        std.mem.eql(u8, &scratch.digest, &scratchDigest(scratch));
}

fn permitMatchesBorrow(
    scratch: *const ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *const StoppedBorrow,
    permit: *const BorrowUsePermit,
) bool {
    return stoppedBytes(scratch, receipt, borrow) != null and
        permitMatchesScratch(scratch, permit) and
        std.mem.eql(u8, &permit.receipt_digest, &receipt.digest) and
        permit.borrow_addr == @intFromPtr(borrow);
}

fn guardInactiveForOperation(
    scratch: *ExternalRxReadScratch,
    permit: *BorrowUsePermit,
    receipt: ?*const CollectReceipt,
    borrow: ?*const StoppedBorrow,
    seed: ?*const WouldBlockSeed,
) bool {
    if (!permitMatchesScratch(scratch, permit)) return false;
    const before_scratch = scratch.digest;
    const before_permit = permit.digest;
    const before_receipt = if (receipt) |value| value.* else null;
    const before_borrow = if (borrow) |value| value.* else null;
    const before_seed = if (seed) |value| value.* else null;
    const state = permit.guard_current(
        permit.guard_context,
        @intFromPtr(scratch),
    );
    return state != null and !state.? and
        std.mem.eql(u8, &before_scratch, &scratch.digest) and
        std.mem.eql(u8, &before_permit, &permit.digest) and
        (if (receipt) |value|
            std.meta.eql(before_receipt.?, value.*)
        else
            true) and
        (if (borrow) |value|
            std.meta.eql(before_borrow.?, value.*)
        else
            true) and
        (if (seed) |value|
            std.meta.eql(before_seed.?, value.*)
        else
            true) and
        permitMatchesScratch(scratch, permit);
}

pub fn beginStoppedUse(
    scratch: *ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *const StoppedBorrow,
    guard: *const BorrowUseGuardOps,
    authorized_seed_out: *WouldBlockSeed,
    out: *BorrowUsePermit,
) bool {
    const ranges = [_]ProtectedRange{
        .{ .addr = @intFromPtr(scratch), .len = @sizeOf(ExternalRxReadScratch) },
        .{ .addr = @intFromPtr(receipt), .len = @sizeOf(CollectReceipt) },
        .{ .addr = @intFromPtr(borrow), .len = @sizeOf(StoppedBorrow) },
        .{ .addr = @intFromPtr(guard), .len = @sizeOf(BorrowUseGuardOps) },
        .{ .addr = @intFromPtr(guard.context), .len = guard.context_len },
        .{ .addr = @intFromPtr(authorized_seed_out), .len = @sizeOf(WouldBlockSeed) },
        .{ .addr = @intFromPtr(out), .len = @sizeOf(BorrowUsePermit) },
    };
    for (ranges, 0..) |left, index| {
        if (rangeEnd(left.addr, left.len) == null) return false;
        for (ranges[index + 1 ..]) |right|
            if (rangesOverlap(left.addr, left.len, right.addr, right.len))
                return false;
    }
    if (scratch.active_use_permit_addr != 0 or
        !std.mem.allEqual(u8, &scratch.active_use_permit_digest, 0) or
        stoppedBytes(scratch, receipt, borrow) == null or
        authorized_seed_out.saved_self_addr != 0 or
        authorized_seed_out.lifecycle != .empty or
        out.saved_self_addr != 0 or out.lifecycle != .empty)
        return false;

    const frozen_context = guard.context;
    const frozen_context_len = guard.context_len;
    const frozen_current = guard.current;
    const before_scratch = scratch.digest;
    const before_borrow = borrow.digest;
    const before_receipt = receipt.digest;
    const current = frozen_current(
        frozen_context,
        @intFromPtr(scratch),
    ) orelse return false;
    if (current or guard.context != frozen_context or
        guard.context_len != frozen_context_len or
        guard.current != frozen_current or
        !std.mem.eql(u8, &before_scratch, &scratch.digest) or
        !std.mem.eql(u8, &before_borrow, &borrow.digest) or
        !std.mem.eql(u8, &before_receipt, &receipt.digest) or
        stoppedBytes(scratch, receipt, borrow) == null or
        authorized_seed_out.saved_self_addr != 0 or
        authorized_seed_out.lifecycle != .empty or
        out.saved_self_addr != 0 or out.lifecycle != .empty)
        return false;

    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .scratch_addr = @intFromPtr(scratch),
        .scratch_generation = scratch.generation,
        .receipt_digest = receipt.digest,
        .borrow_addr = @intFromPtr(borrow),
        .authorized_seed_addr = @intFromPtr(authorized_seed_out),
        .authorized_seed_len = @sizeOf(WouldBlockSeed),
        .guard_context = frozen_context,
        .guard_context_len = frozen_context_len,
        .guard_current = frozen_current,
        .seed_lifecycle = .unminted,
        .lifecycle = .active,
    };
    out.digest = borrowUsePermitDigest(out);
    scratch.active_use_permit_addr = @intFromPtr(out);
    scratch.active_use_permit_digest = out.digest;
    scratch.digest = scratchDigest(scratch);
    return true;
}

fn preparedAdmitUsePermitMatches(
    scratch: *const ExternalRxReadScratch,
    permit: *const PreparedAdmitUsePermit,
) bool {
    return permit.saved_self_addr == @intFromPtr(permit) and
        permit.scratch_addr == @intFromPtr(scratch) and
        permit.scratch_generation == scratch.generation and
        permit.lifecycle == .active and
        std.mem.eql(
            u8,
            &permit.digest,
            &preparedAdmitUsePermitDigest(permit),
        ) and
        scratch.active_prepared_use_permit_addr == @intFromPtr(permit) and
        std.mem.eql(
            u8,
            &scratch.active_prepared_use_permit_digest,
            &permit.digest,
        );
}

fn preparedAdmitFrozenStateMatches(
    scratch: *const ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *const StoppedBorrow,
    use_permit: *const BorrowUsePermit,
    seed: *const WouldBlockSeed,
    permit: *const PreparedAdmitUsePermit,
) bool {
    return preparedAdmitUsePermitMatches(scratch, permit) and
        permit.receipt_addr == @intFromPtr(receipt) and
        permit.borrow_addr == @intFromPtr(borrow) and
        permit.use_permit_addr == @intFromPtr(use_permit) and
        permit.seed_addr == @intFromPtr(seed) and
        std.mem.eql(
            u8,
            &permit.frozen_outer_digest,
            &scratchPreparedOuterDigest(scratch),
        ) and
        std.meta.eql(permit.frozen_receipt, receipt.*) and
        std.meta.eql(permit.frozen_borrow, borrow.*) and
        std.meta.eql(permit.frozen_use_permit, use_permit.*) and
        std.meta.eql(permit.frozen_seed, seed.*);
}

pub fn beginPreparedAdmitUse(
    scratch: *ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *const StoppedBorrow,
    use_permit: *BorrowUsePermit,
    authorized_seed: *const WouldBlockSeed,
    out: *PreparedAdmitUsePermit,
) bool {
    const ranges = [_]ProtectedRange{
        .{ .addr = @intFromPtr(scratch), .len = @sizeOf(ExternalRxReadScratch) },
        .{ .addr = @intFromPtr(receipt), .len = @sizeOf(CollectReceipt) },
        .{ .addr = @intFromPtr(borrow), .len = @sizeOf(StoppedBorrow) },
        .{ .addr = @intFromPtr(use_permit), .len = @sizeOf(BorrowUsePermit) },
        .{ .addr = @intFromPtr(authorized_seed), .len = @sizeOf(WouldBlockSeed) },
        .{ .addr = @intFromPtr(out), .len = @sizeOf(PreparedAdmitUsePermit) },
    };
    for (ranges, 0..) |left, index| {
        if (rangeEnd(left.addr, left.len) == null) return false;
        for (ranges[index + 1 ..]) |right|
            if (rangesOverlap(left.addr, left.len, right.addr, right.len))
                return false;
    }
    if (scratch.active_prepared_use_permit_addr != 0 or
        !std.mem.allEqual(
            u8,
            &scratch.active_prepared_use_permit_digest,
            0,
        ) or
        !client_external_mode.preparedRxAppendPristine(
            &scratch.prepared_admit,
        ) or
        !permitMatchesBorrow(scratch, receipt, borrow, use_permit) or
        !authorizedSeedMatchesPermit(scratch, use_permit) or
        out.saved_self_addr != 0 or out.lifecycle != .empty or
        !guardInactiveForOperation(
            scratch,
            use_permit,
            receipt,
            borrow,
            authorized_seed,
        ))
        return false;
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .scratch_addr = @intFromPtr(scratch),
        .scratch_generation = scratch.generation,
        .receipt_addr = @intFromPtr(receipt),
        .borrow_addr = @intFromPtr(borrow),
        .use_permit_addr = @intFromPtr(use_permit),
        .seed_addr = @intFromPtr(authorized_seed),
        .frozen_outer_digest = scratchPreparedOuterDigest(scratch),
        .frozen_receipt = receipt.*,
        .frozen_borrow = borrow.*,
        .frozen_use_permit = use_permit.*,
        .frozen_seed = authorized_seed.*,
        .lifecycle = .active,
    };
    out.digest = preparedAdmitUsePermitDigest(out);
    scratch.active_prepared_use_permit_addr = @intFromPtr(out);
    scratch.active_prepared_use_permit_digest = out.digest;
    scratch.digest = scratchDigest(scratch);
    return true;
}

pub fn finishPreparedAdmitUse(
    scratch: *ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *const StoppedBorrow,
    use_permit: *BorrowUsePermit,
    authorized_seed: *const WouldBlockSeed,
    permit: *PreparedAdmitUsePermit,
) bool {
    if (!preparedAdmitFrozenStateMatches(
        scratch,
        receipt,
        borrow,
        use_permit,
        authorized_seed,
        permit,
    ) or !client_external_mode.preparedRxAppendPristine(
        &scratch.prepared_admit,
    ))
        return false;
    const frozen_token = permit.*;
    const frozen_prepared = scratch.prepared_admit;
    if (!guardInactiveForOperation(
        scratch,
        use_permit,
        receipt,
        borrow,
        authorized_seed,
    ) or !std.meta.eql(frozen_token, permit.*) or
        !std.meta.eql(frozen_prepared, scratch.prepared_admit) or
        !preparedAdmitFrozenStateMatches(
            scratch,
            receipt,
            borrow,
            use_permit,
            authorized_seed,
            permit,
        ) or !client_external_mode.preparedRxAppendPristine(
        &scratch.prepared_admit,
    ))
        return false;
    permit.lifecycle = .finished;
    permit.digest = preparedAdmitUsePermitDigest(permit);
    scratch.active_prepared_use_permit_addr = 0;
    scratch.active_prepared_use_permit_digest = [_]u8{0} ** 32;
    scratch.digest = scratchDigest(scratch);
    return true;
}

pub fn resetFinishedPreparedAdmitUse(
    scratch: *ExternalRxReadScratch,
    permit: *PreparedAdmitUsePermit,
) bool {
    if (rangeEnd(
        @intFromPtr(scratch),
        @sizeOf(ExternalRxReadScratch),
    ) == null or rangeEnd(
        @intFromPtr(permit),
        @sizeOf(PreparedAdmitUsePermit),
    ) == null or rangesOverlap(
        @intFromPtr(scratch),
        @sizeOf(ExternalRxReadScratch),
        @intFromPtr(permit),
        @sizeOf(PreparedAdmitUsePermit),
    ) or
        scratch.saved_self_addr != @intFromPtr(scratch) or
        scratch.generation == 0 or
        scratch.active_prepared_use_permit_addr != 0 or
        !std.mem.allEqual(
            u8,
            &scratch.active_prepared_use_permit_digest,
            0,
        ) or
        !client_external_mode.preparedRxAppendPristine(
            &scratch.prepared_admit,
        ) or
        !std.mem.eql(u8, &scratch.digest, &scratchDigest(scratch)) or
        permit.saved_self_addr != @intFromPtr(permit) or
        permit.scratch_addr != @intFromPtr(scratch) or
        permit.scratch_generation != scratch.generation or
        permit.lifecycle != .finished or
        !std.mem.eql(
            u8,
            &permit.digest,
            &preparedAdmitUsePermitDigest(permit),
        ))
        return false;
    permit.* = .{};
    return true;
}

pub fn terminalizeStoppedGraphNoCallback(
    scratch: *ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *StoppedBorrow,
    use_permit: *BorrowUsePermit,
    seed: *WouldBlockSeed,
    prepared_use: *PreparedAdmitUsePermit,
) StoppedGraphTerminalizeResult {
    if (!stoppedGraphRangesDisjoint(
        scratch,
        receipt,
        borrow,
        use_permit,
        seed,
        prepared_use,
    ))
        return .unrecoverable;
    if (settledStoppedGraphClosed(
        scratch,
        receipt,
        borrow,
        use_permit,
        seed,
        prepared_use,
    )) {
        scratch.lifecycle = .terminal;
        scratch.digest = scratchDigest(scratch);
        return .closed;
    }
    if (scratch.lifecycle == .terminal) {
        const borrow_closed = switch (borrow.lifecycle) {
            .empty => borrow.saved_self_addr == 0,
            .settled, .aborted => borrow.saved_self_addr == @intFromPtr(borrow) and
                borrow.scratch_addr == @intFromPtr(scratch) and
                borrow.scratch_generation == scratch.generation and
                std.mem.eql(u8, &borrow.digest, &borrowDigest(borrow)),
            .borrowed => false,
        };
        const seed_closed = switch (seed.lifecycle) {
            .empty => seed.saved_self_addr == 0,
            .consumed, .aborted => seed.saved_self_addr == @intFromPtr(seed) and
                seed.scratch_addr == @intFromPtr(scratch) and
                seed.scratch_generation == scratch.generation and
                (borrow.lifecycle == .empty or
                    seed.borrow_addr == @intFromPtr(borrow)) and
                std.mem.eql(u8, &seed.digest, &wouldBlockSeedDigest(seed)),
            .prepared => false,
        };
        const use_closed = switch (use_permit.lifecycle) {
            .empty => use_permit.saved_self_addr == 0,
            .released, .aborted => use_permit.saved_self_addr ==
                @intFromPtr(use_permit) and
                use_permit.scratch_addr == @intFromPtr(scratch) and
                use_permit.scratch_generation == scratch.generation and
                (borrow.lifecycle == .empty or
                    use_permit.borrow_addr == @intFromPtr(borrow)) and
                (seed.lifecycle == .empty or
                    (use_permit.authorized_seed_addr == @intFromPtr(seed) and
                        use_permit.seed_lifecycle ==
                            @as(PermitSeedLifecycle, switch (seed.lifecycle) {
                                .empty => .unminted,
                                .prepared => .prepared,
                                .consumed => .consumed,
                                .aborted => .aborted,
                            }) and
                        std.mem.eql(
                            u8,
                            &use_permit.seed_digest,
                            &seed.digest,
                        ))) and
                std.mem.eql(
                    u8,
                    &use_permit.digest,
                    &borrowUsePermitDigest(use_permit),
                ),
            .active => false,
        };
        const prepared_closed = switch (prepared_use.lifecycle) {
            .empty => prepared_use.saved_self_addr == 0,
            .finished, .aborted => prepared_use.saved_self_addr ==
                @intFromPtr(prepared_use) and
                prepared_use.scratch_addr == @intFromPtr(scratch) and
                prepared_use.scratch_generation == scratch.generation and
                prepared_use.receipt_addr == @intFromPtr(receipt) and
                (borrow.lifecycle == .empty or
                    prepared_use.borrow_addr == @intFromPtr(borrow)) and
                (use_permit.lifecycle == .empty or
                    prepared_use.use_permit_addr ==
                        @intFromPtr(use_permit)) and
                (seed.lifecycle == .empty or
                    prepared_use.seed_addr == @intFromPtr(seed)) and
                std.mem.eql(
                    u8,
                    &prepared_use.digest,
                    &preparedAdmitUsePermitDigest(prepared_use),
                ),
            .active => false,
        };
        if (scratch.saved_self_addr != @intFromPtr(scratch) or
            scratch.generation == 0 or
            scratch.active_borrow_addr != 0 or
            !std.mem.allEqual(u8, &scratch.active_borrow_digest, 0) or
            scratch.active_use_permit_addr != 0 or
            !std.mem.allEqual(u8, &scratch.active_use_permit_digest, 0) or
            scratch.active_prepared_use_permit_addr != 0 or
            !std.mem.allEqual(
                u8,
                &scratch.active_prepared_use_permit_digest,
                0,
            ) or
            !client_external_mode.preparedRxAppendPristine(
                &scratch.prepared_admit,
            ) or
            !std.mem.eql(u8, &scratch.digest, &scratchDigest(scratch)) or
            receipt.scratch_addr != @intFromPtr(scratch) or
            receipt.scratch_generation != scratch.generation or
            !std.mem.eql(u8, &receipt.digest, &receiptDigest(receipt)) or
            !borrow_closed or !seed_closed or !use_closed or !prepared_closed)
            return .unrecoverable;
        return .already_closed;
    }
    const seed_active_valid = switch (use_permit.seed_lifecycle) {
        .unminted => seed.saved_self_addr == 0 and
            seed.lifecycle == .empty and
            std.mem.allEqual(u8, std.mem.asBytes(seed), 0),
        .prepared => seedMatchesPermit(scratch, use_permit, seed, .prepared),
        .consumed => seedMatchesPermit(scratch, use_permit, seed, .consumed),
        .aborted => seedMatchesPermit(scratch, use_permit, seed, .aborted),
    };
    const prepared_active_valid = switch (prepared_use.lifecycle) {
        .empty => prepared_use.saved_self_addr == 0 and
            prepared_use.scratch_addr == 0 and
            prepared_use.scratch_generation == 0 and
            prepared_use.receipt_addr == 0 and
            prepared_use.borrow_addr == 0 and
            prepared_use.use_permit_addr == 0 and
            prepared_use.seed_addr == 0 and
            std.mem.allEqual(u8, &prepared_use.frozen_outer_digest, 0) and
            prepared_use.frozen_borrow.saved_self_addr == 0 and
            prepared_use.frozen_use_permit.saved_self_addr == 0 and
            prepared_use.frozen_seed.saved_self_addr == 0 and
            std.mem.allEqual(u8, &prepared_use.digest, 0) and
            scratch.active_prepared_use_permit_addr == 0 and
            std.mem.allEqual(
                u8,
                &scratch.active_prepared_use_permit_digest,
                0,
            ),
        .active => preparedAdmitFrozenStateMatches(
            scratch,
            receipt,
            borrow,
            use_permit,
            seed,
            prepared_use,
        ),
        .finished => prepared_use.saved_self_addr ==
            @intFromPtr(prepared_use) and
            prepared_use.scratch_addr == @intFromPtr(scratch) and
            prepared_use.scratch_generation == scratch.generation and
            prepared_use.receipt_addr == @intFromPtr(receipt) and
            prepared_use.borrow_addr == @intFromPtr(borrow) and
            prepared_use.use_permit_addr == @intFromPtr(use_permit) and
            prepared_use.seed_addr == @intFromPtr(seed) and
            std.mem.eql(
                u8,
                &prepared_use.digest,
                &preparedAdmitUsePermitDigest(prepared_use),
            ) and
            scratch.active_prepared_use_permit_addr == 0 and
            std.mem.allEqual(
                u8,
                &scratch.active_prepared_use_permit_digest,
                0,
            ),
        .aborted => false,
    };
    if (!client_external_mode.preparedRxAppendPristine(
        &scratch.prepared_admit,
    ) or !permitMatchesBorrow(
        scratch,
        receipt,
        borrow,
        use_permit,
    ) or !seed_active_valid or !prepared_active_valid)
        return .unrecoverable;

    if (prepared_use.lifecycle == .active) {
        prepared_use.lifecycle = .aborted;
        prepared_use.digest = preparedAdmitUsePermitDigest(prepared_use);
        scratch.active_prepared_use_permit_addr = 0;
        scratch.active_prepared_use_permit_digest = [_]u8{0} ** 32;
    }

    if (seed.lifecycle == .prepared) {
        seed.lifecycle = .aborted;
        seed.digest = wouldBlockSeedDigest(seed);
        use_permit.seed_lifecycle = .aborted;
        use_permit.seed_digest = seed.digest;
        use_permit.digest = borrowUsePermitDigest(use_permit);
        scratch.active_use_permit_digest = use_permit.digest;
    }

    use_permit.lifecycle = .aborted;
    use_permit.digest = borrowUsePermitDigest(use_permit);
    scratch.active_use_permit_addr = 0;
    scratch.active_use_permit_digest = [_]u8{0} ** 32;

    borrow.lifecycle = .aborted;
    borrow.digest = borrowDigest(borrow);
    scratch.active_borrow_addr = 0;
    scratch.active_borrow_digest = [_]u8{0} ** 32;

    scratch.lifecycle = .terminal;
    scratch.digest = scratchDigest(scratch);
    return .closed;
}

fn settledStoppedGraphClosed(
    scratch: *const ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *const StoppedBorrow,
    use_permit: *const BorrowUsePermit,
    seed: *const WouldBlockSeed,
    prepared_use: *const PreparedAdmitUsePermit,
) bool {
    if (!scratch.isReady() or
        receipt.scratch_addr != @intFromPtr(scratch) or
        receipt.scratch_generation == 0 or
        receipt.scratch_generation == std.math.maxInt(u64) or
        scratch.generation != receipt.scratch_generation + 1 or
        !std.mem.eql(u8, &receipt.digest, &receiptDigest(receipt)) or
        borrow.saved_self_addr != @intFromPtr(borrow) or
        borrow.scratch_addr != @intFromPtr(scratch) or
        borrow.scratch_generation != receipt.scratch_generation or
        borrow.receipt_addr != @intFromPtr(receipt) or
        !std.mem.eql(u8, &borrow.receipt_digest, &receipt.digest) or
        (borrow.lifecycle != .settled and borrow.lifecycle != .aborted) or
        !std.mem.eql(u8, &borrow.digest, &borrowDigest(borrow)) or
        use_permit.saved_self_addr != @intFromPtr(use_permit) or
        use_permit.scratch_addr != @intFromPtr(scratch) or
        use_permit.scratch_generation != receipt.scratch_generation or
        !std.mem.eql(u8, &use_permit.receipt_digest, &receipt.digest) or
        use_permit.borrow_addr != @intFromPtr(borrow) or
        (use_permit.lifecycle != .released and
            use_permit.lifecycle != .aborted) or
        !std.mem.eql(
            u8,
            &use_permit.digest,
            &borrowUsePermitDigest(use_permit),
        ))
        return false;

    const seed_closed = switch (seed.lifecycle) {
        .empty => receipt.stop != .would_block and
            seed.saved_self_addr == 0 and
            seed.scratch_addr == 0 and
            seed.scratch_generation == 0 and
            std.mem.allEqual(u8, &seed.receipt_digest, 0) and
            seed.borrow_addr == 0 and
            seed.attempt_generation == 0 and
            std.mem.allEqual(u8, &seed.digest, 0) and
            use_permit.seed_lifecycle == .unminted and
            std.mem.allEqual(u8, &use_permit.seed_digest, 0),
        .consumed, .aborted => receipt.stop == .would_block and
            seed.saved_self_addr == @intFromPtr(seed) and
            seed.scratch_addr == @intFromPtr(scratch) and
            seed.scratch_generation == receipt.scratch_generation and
            std.mem.eql(u8, &seed.receipt_digest, &receipt.digest) and
            seed.borrow_addr == @intFromPtr(borrow) and
            std.mem.eql(u8, &seed.digest, &wouldBlockSeedDigest(seed)) and
            use_permit.authorized_seed_addr == @intFromPtr(seed) and
            use_permit.authorized_seed_len == @sizeOf(WouldBlockSeed) and
            use_permit.seed_lifecycle ==
                @as(PermitSeedLifecycle, switch (seed.lifecycle) {
                    .consumed => .consumed,
                    .aborted => .aborted,
                    else => unreachable,
                }) and
            std.mem.eql(u8, &use_permit.seed_digest, &seed.digest),
        .prepared => false,
    };
    if (!seed_closed) return false;

    return switch (prepared_use.lifecycle) {
        .empty => prepared_use.saved_self_addr == 0 and
            prepared_use.scratch_addr == 0 and
            prepared_use.scratch_generation == 0 and
            prepared_use.receipt_addr == 0 and
            prepared_use.borrow_addr == 0 and
            prepared_use.use_permit_addr == 0 and
            prepared_use.seed_addr == 0 and
            std.mem.allEqual(u8, &prepared_use.frozen_outer_digest, 0) and
            prepared_use.frozen_borrow.saved_self_addr == 0 and
            prepared_use.frozen_use_permit.saved_self_addr == 0 and
            prepared_use.frozen_seed.saved_self_addr == 0 and
            std.mem.allEqual(u8, &prepared_use.digest, 0),
        .finished, .aborted => prepared_use.saved_self_addr ==
            @intFromPtr(prepared_use) and
            prepared_use.scratch_addr == @intFromPtr(scratch) and
            prepared_use.scratch_generation == receipt.scratch_generation and
            prepared_use.receipt_addr == @intFromPtr(receipt) and
            prepared_use.borrow_addr == @intFromPtr(borrow) and
            prepared_use.use_permit_addr == @intFromPtr(use_permit) and
            prepared_use.seed_addr == @intFromPtr(seed) and
            std.mem.eql(
                u8,
                &prepared_use.digest,
                &preparedAdmitUsePermitDigest(prepared_use),
            ),
        .active => false,
    };
}

/// Authenticates the complete settled graph before erasing its scalar tombstones for reuse.
/// `CollectReceipt` has no empty value, so it is deliberately made undefined only after every
/// address, generation, digest, and lifecycle edge has been validated.
pub fn resetSettledStoppedGraphForNextTurn(
    scratch: *ExternalRxReadScratch,
    receipt: *CollectReceipt,
    borrow: *StoppedBorrow,
    use_permit: *BorrowUsePermit,
    seed: *WouldBlockSeed,
    prepared_use: *PreparedAdmitUsePermit,
) bool {
    if (!stoppedGraphRangesDisjoint(
        scratch,
        receipt,
        borrow,
        use_permit,
        seed,
        prepared_use,
    ) or !settledStoppedGraphClosed(
        scratch,
        receipt,
        borrow,
        use_permit,
        seed,
        prepared_use,
    ))
        return false;
    borrow.* = .{};
    use_permit.* = .{};
    seed.* = .{};
    prepared_use.* = .{};
    receipt.* = undefined;
    return true;
}

pub fn settledStoppedGraphValid(
    scratch: *const ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *const StoppedBorrow,
    use_permit: *const BorrowUsePermit,
    seed: *const WouldBlockSeed,
    prepared_use: *const PreparedAdmitUsePermit,
) bool {
    return stoppedGraphRangesDisjoint(
        scratch,
        receipt,
        borrow,
        use_permit,
        seed,
        prepared_use,
    ) and settledStoppedGraphClosed(
        scratch,
        receipt,
        borrow,
        use_permit,
        seed,
        prepared_use,
    );
}

pub fn stoppedGraphPristine(
    borrow: *const StoppedBorrow,
    use_permit: *const BorrowUsePermit,
    seed: *const WouldBlockSeed,
    prepared_use: *const PreparedAdmitUsePermit,
) bool {
    return borrow.saved_self_addr == 0 and borrow.scratch_addr == 0 and
        borrow.scratch_generation == 0 and borrow.receipt_addr == 0 and
        std.mem.allEqual(u8, &borrow.receipt_digest, 0) and
        borrow.bytes_addr == 0 and borrow.bytes_len == 0 and
        borrow.lifecycle == .empty and std.mem.allEqual(u8, &borrow.digest, 0) and
        use_permit.saved_self_addr == 0 and use_permit.scratch_addr == 0 and
        use_permit.scratch_generation == 0 and
        std.mem.allEqual(u8, &use_permit.receipt_digest, 0) and
        use_permit.borrow_addr == 0 and use_permit.authorized_seed_addr == 0 and
        use_permit.authorized_seed_len == 0 and
        use_permit.guard_context_len == 0 and
        use_permit.seed_lifecycle == .unminted and
        std.mem.allEqual(u8, &use_permit.seed_digest, 0) and
        use_permit.lifecycle == .empty and
        std.mem.allEqual(u8, &use_permit.digest, 0) and
        seed.saved_self_addr == 0 and seed.scratch_addr == 0 and
        seed.scratch_generation == 0 and
        std.mem.allEqual(u8, &seed.receipt_digest, 0) and
        seed.borrow_addr == 0 and seed.attempt_generation == 0 and
        seed.lifecycle == .empty and std.mem.allEqual(u8, &seed.digest, 0) and
        prepared_use.saved_self_addr == 0 and
        prepared_use.scratch_addr == 0 and
        prepared_use.scratch_generation == 0 and
        prepared_use.receipt_addr == 0 and prepared_use.borrow_addr == 0 and
        prepared_use.use_permit_addr == 0 and prepared_use.seed_addr == 0 and
        std.mem.allEqual(u8, &prepared_use.frozen_outer_digest, 0) and
        prepared_use.frozen_borrow.saved_self_addr == 0 and
        prepared_use.frozen_use_permit.saved_self_addr == 0 and
        prepared_use.frozen_seed.saved_self_addr == 0 and
        prepared_use.lifecycle == .empty and
        std.mem.allEqual(u8, &prepared_use.digest, 0);
}

fn seedMatchesPermit(
    scratch: *const ExternalRxReadScratch,
    permit: *const BorrowUsePermit,
    seed: *const WouldBlockSeed,
    lifecycle: WouldBlockSeedLifecycle,
) bool {
    const permit_lifecycle: PermitSeedLifecycle = switch (lifecycle) {
        .empty => .unminted,
        .prepared => .prepared,
        .consumed => .consumed,
        .aborted => .aborted,
    };
    return permitMatchesScratch(scratch, permit) and
        @intFromPtr(seed) == permit.authorized_seed_addr and
        seed.saved_self_addr == @intFromPtr(seed) and
        seed.scratch_addr == @intFromPtr(scratch) and
        seed.scratch_generation == scratch.generation and
        std.mem.eql(u8, &seed.receipt_digest, &permit.receipt_digest) and
        seed.borrow_addr == permit.borrow_addr and
        seed.lifecycle == lifecycle and
        permit.seed_lifecycle == permit_lifecycle and
        std.mem.eql(u8, &seed.digest, &wouldBlockSeedDigest(seed)) and
        std.mem.eql(u8, &permit.seed_digest, &seed.digest);
}

pub fn mintBorrowedWouldBlockSeed(
    scratch: *ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *const StoppedBorrow,
    permit: *BorrowUsePermit,
    out: *WouldBlockSeed,
) bool {
    if (scratch.active_prepared_use_permit_addr != 0 or
        !std.mem.allEqual(
            u8,
            &scratch.active_prepared_use_permit_digest,
            0,
        ) or
        @intFromPtr(out) != permit.authorized_seed_addr or
        rangesOverlap(
            @intFromPtr(out),
            @sizeOf(WouldBlockSeed),
            @intFromPtr(permit),
            @sizeOf(BorrowUsePermit),
        ) or
        !permitMatchesBorrow(scratch, receipt, borrow, permit) or
        permit.seed_lifecycle != .unminted or
        out.saved_self_addr != 0 or out.lifecycle != .empty or
        receipt.stop != .would_block or
        scratch.would_block.lifecycle != .observed or
        !std.mem.eql(
            u8,
            &scratch.would_block.digest,
            &wouldBlockDigest(&scratch.would_block),
        ) or !guardInactiveForOperation(
        scratch,
        permit,
        receipt,
        borrow,
        out,
    ))
        return false;
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .scratch_addr = @intFromPtr(scratch),
        .scratch_generation = scratch.generation,
        .receipt_digest = receipt.digest,
        .borrow_addr = @intFromPtr(borrow),
        .attempt_generation = scratch.would_block.attempt_generation,
        .lifecycle = .prepared,
    };
    out.digest = wouldBlockSeedDigest(out);
    permit.seed_lifecycle = .prepared;
    permit.seed_digest = out.digest;
    permit.digest = borrowUsePermitDigest(permit);
    scratch.active_use_permit_digest = permit.digest;
    scratch.digest = scratchDigest(scratch);
    return true;
}

fn accountWouldBlockSeed(
    scratch: *ExternalRxReadScratch,
    permit: *BorrowUsePermit,
    seed: *WouldBlockSeed,
    lifecycle: WouldBlockSeedLifecycle,
) ?u64 {
    if (scratch.active_prepared_use_permit_addr != 0 or
        !std.mem.allEqual(
            u8,
            &scratch.active_prepared_use_permit_digest,
            0,
        ) or !seedMatchesPermit(scratch, permit, seed, .prepared))
        return null;
    const generation = seed.attempt_generation;
    if (!guardInactiveForOperation(
        scratch,
        permit,
        null,
        null,
        seed,
    ) or !seedMatchesPermit(scratch, permit, seed, .prepared) or
        seed.attempt_generation != generation)
        return null;
    seed.lifecycle = lifecycle;
    seed.digest = wouldBlockSeedDigest(seed);
    permit.seed_lifecycle = switch (lifecycle) {
        .empty => .unminted,
        .prepared => .prepared,
        .consumed => .consumed,
        .aborted => .aborted,
    };
    permit.seed_digest = seed.digest;
    permit.digest = borrowUsePermitDigest(permit);
    scratch.active_use_permit_digest = permit.digest;
    scratch.digest = scratchDigest(scratch);
    return generation;
}

pub fn consumeWouldBlockSeed(
    scratch: *ExternalRxReadScratch,
    permit: *BorrowUsePermit,
    seed: *WouldBlockSeed,
) ?u64 {
    return accountWouldBlockSeed(scratch, permit, seed, .consumed);
}

pub const DrainSeedAuthorityPhase = enum { prepared, consumed };

pub const DrainSeedAuthorityProjection = struct {
    phase: DrainSeedAuthorityPhase,
    scratch_addr: usize,
    scratch_generation: u64,
    receipt_addr: usize,
    borrow_addr: usize,
    permit_addr: usize,
    seed_addr: usize,
    attempt_generation: u64,
    continuity_digest: external_owner_seal.Digest,
    digest: external_owner_seal.Digest,
};

fn drainSeedGraphDisjoint(
    scratch: *const ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *const StoppedBorrow,
    permit: *const BorrowUsePermit,
    seed: *const WouldBlockSeed,
) bool {
    const ranges = [_]struct { addr: usize, len: usize }{
        .{ .addr = @intFromPtr(scratch), .len = @sizeOf(ExternalRxReadScratch) },
        .{ .addr = @intFromPtr(receipt), .len = @sizeOf(CollectReceipt) },
        .{ .addr = @intFromPtr(borrow), .len = @sizeOf(StoppedBorrow) },
        .{ .addr = @intFromPtr(permit), .len = @sizeOf(BorrowUsePermit) },
        .{ .addr = @intFromPtr(seed), .len = @sizeOf(WouldBlockSeed) },
    };
    for (ranges, 0..) |left, left_index| {
        _ = std.math.add(usize, left.addr, left.len) catch return false;
        for (ranges[left_index + 1 ..]) |right|
            if (rangesOverlap(left.addr, left.len, right.addr, right.len))
                return false;
    }
    return true;
}

pub fn snapshotDrainSeedAuthority(
    scratch: *const ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *const StoppedBorrow,
    permit: *const BorrowUsePermit,
    seed: *const WouldBlockSeed,
    phase: DrainSeedAuthorityPhase,
) ?DrainSeedAuthorityProjection {
    if (!drainSeedGraphDisjoint(
        scratch,
        receipt,
        borrow,
        permit,
        seed,
    ) or !permitMatchesBorrow(scratch, receipt, borrow, permit))
        return null;
    const lifecycle: WouldBlockSeedLifecycle = switch (phase) {
        .prepared => .prepared,
        .consumed => .consumed,
    };
    if (!seedMatchesPermit(scratch, permit, seed, lifecycle))
        return null;
    var continuity_writer = external_owner_seal.Writer.init("MARUDSC1");
    continuity_writer.writeUsize(@intFromPtr(scratch));
    continuity_writer.writeU64(scratch.generation);
    continuity_writer.writeUsize(@intFromPtr(receipt));
    continuity_writer.writeUsize(@intFromPtr(borrow));
    continuity_writer.writeUsize(@intFromPtr(permit));
    continuity_writer.writeUsize(@intFromPtr(seed));
    continuity_writer.writeU64(seed.attempt_generation);
    const continuity = continuity_writer.finish();
    var digest_writer = external_owner_seal.Writer.init("MARUDSP1");
    digest_writer.writeU8(@intFromEnum(phase));
    digest_writer.writeBytes(&continuity);
    digest_writer.writeBytes(&receipt.digest);
    digest_writer.writeBytes(&borrow.digest);
    digest_writer.writeBytes(&permit.digest);
    digest_writer.writeBytes(&seed.digest);
    const result = DrainSeedAuthorityProjection{
        .phase = phase,
        .scratch_addr = @intFromPtr(scratch),
        .scratch_generation = scratch.generation,
        .receipt_addr = @intFromPtr(receipt),
        .borrow_addr = @intFromPtr(borrow),
        .permit_addr = @intFromPtr(permit),
        .seed_addr = @intFromPtr(seed),
        .attempt_generation = seed.attempt_generation,
        .continuity_digest = continuity,
        .digest = digest_writer.finish(),
    };
    return result;
}

pub fn abortWouldBlockSeed(
    scratch: *ExternalRxReadScratch,
    permit: *BorrowUsePermit,
    seed: *WouldBlockSeed,
) bool {
    return accountWouldBlockSeed(scratch, permit, seed, .aborted) != null;
}

fn authorizedSeedMatchesPermit(
    scratch: *const ExternalRxReadScratch,
    permit: *const BorrowUsePermit,
) bool {
    if (!permitMatchesScratch(scratch, permit)) return false;
    const seed: *const WouldBlockSeed =
        @ptrFromInt(permit.authorized_seed_addr);
    return switch (permit.seed_lifecycle) {
        .unminted => std.meta.eql(seed.*, WouldBlockSeed{}),
        .prepared => false,
        .consumed => seedMatchesPermit(
            scratch,
            permit,
            seed,
            .consumed,
        ),
        .aborted => seedMatchesPermit(
            scratch,
            permit,
            seed,
            .aborted,
        ),
    };
}

pub fn endStoppedUse(
    scratch: *ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *const StoppedBorrow,
    permit: *BorrowUsePermit,
) bool {
    if (scratch.active_prepared_use_permit_addr != 0 or
        !std.mem.allEqual(
            u8,
            &scratch.active_prepared_use_permit_digest,
            0,
        ) or !permitMatchesBorrow(scratch, receipt, borrow, permit) or
        permit.seed_lifecycle == .prepared or
        !authorizedSeedMatchesPermit(scratch, permit) or
        !guardInactiveForOperation(
            scratch,
            permit,
            receipt,
            borrow,
            @ptrFromInt(permit.authorized_seed_addr),
        ) or
        !permitMatchesBorrow(scratch, receipt, borrow, permit) or
        !authorizedSeedMatchesPermit(scratch, permit))
        return false;
    permit.lifecycle = .released;
    permit.digest = borrowUsePermitDigest(permit);
    scratch.active_use_permit_addr = 0;
    scratch.active_use_permit_digest = [_]u8{0} ** 32;
    scratch.digest = scratchDigest(scratch);
    return true;
}

pub fn settleStopped(
    scratch: *ExternalRxReadScratch,
    receipt: *const CollectReceipt,
    borrow: *StoppedBorrow,
    disposition: StoppedDisposition,
) bool {
    if (scratch.active_use_permit_addr != 0 or
        !std.mem.allEqual(u8, &scratch.active_use_permit_digest, 0) or
        scratch.active_prepared_use_permit_addr != 0 or
        !std.mem.allEqual(
            u8,
            &scratch.active_prepared_use_permit_digest,
            0,
        ) or
        stoppedBytes(scratch, receipt, borrow) == null or
        !client_external_mode.preparedRxAppendPristine(
            &scratch.prepared_admit,
        ))
        return false;
    const has_would_block = receipt.stop == .would_block;
    if ((has_would_block and disposition.would_block == .not_present) or
        (!has_would_block and disposition.would_block != .not_present))
        return false;
    borrow.lifecycle = if (disposition.staged == .consumed) .settled else .aborted;
    borrow.digest = borrowDigest(borrow);
    if (scratch.generation == std.math.maxInt(u64)) return false;
    const next_generation = scratch.generation + 1;
    scratch.* = .{
        .saved_self_addr = @intFromPtr(scratch),
        .generation = next_generation,
        .lifecycle = .ready,
    };
    scratch.digest = scratchDigest(scratch);
    return true;
}

pub fn teardown(
    scratch: *ExternalRxReadScratch,
) ReadScratchTeardownResult {
    if (scratch.saved_self_addr != @intFromPtr(scratch))
        return .stale_or_moved;
    if (scratch.lifecycle == .collecting) return .busy;
    if (scratch.active_use_permit_addr != 0 or
        !std.mem.allEqual(u8, &scratch.active_use_permit_digest, 0))
        return .busy;
    if (scratch.active_prepared_use_permit_addr != 0 or
        !std.mem.allEqual(
            u8,
            &scratch.active_prepared_use_permit_digest,
            0,
        ))
        return .busy;
    if (!client_external_mode.preparedRxAppendPristine(
        &scratch.prepared_admit,
    ))
        return .needs_outer_cleanup;
    if (scratch.lifecycle == .closed) {
        const canonical = scratch.staged_len == 0 and
            scratch.attempt_count == 0 and
            scratch.chunk_count == 0 and
            scratch.consecutive_interrupts == 0 and
            scratch.attempt.saved_self_addr == 0 and
            scratch.would_block.attempt_generation == 0 and
            std.mem.allEqual(u8, &scratch.spent_receipt_digest, 0) and
            scratch.active_borrow_addr == 0 and
            std.mem.allEqual(u8, &scratch.active_borrow_digest, 0) and
            scratch.active_use_permit_addr == 0 and
            std.mem.allEqual(u8, &scratch.active_use_permit_digest, 0) and
            scratch.active_prepared_use_permit_addr == 0 and
            std.mem.allEqual(
                u8,
                &scratch.active_prepared_use_permit_digest,
                0,
            ) and
            scratch.validation_bytes_checked == 0 and
            stagedPrefixIntact(scratch) and
            std.mem.eql(u8, &scratch.digest, &scratchDigest(scratch));
        return if (canonical) .already_closed else .stale_or_moved;
    }
    const seal_valid =
        scratch.generation != 0 and
        std.mem.eql(u8, &scratch.digest, &scratchDigest(scratch));
    const lifecycle_valid = switch (scratch.lifecycle) {
        .ready => scratch.isReady(),
        .spent => seal_valid and
            !std.mem.allEqual(u8, &scratch.spent_receipt_digest, 0) and
            scratch.active_borrow_addr == 0 and
            stagedPrefixIntact(scratch),
        .borrowed => seal_valid and
            !std.mem.allEqual(u8, &scratch.spent_receipt_digest, 0) and
            scratch.active_borrow_addr != 0 and
            !std.mem.allEqual(u8, &scratch.active_borrow_digest, 0) and
            stagedPrefixIntact(scratch),
        .terminal => seal_valid and scratch.staged_len == 0 and
            scratch.attempt_count == 0 and scratch.chunk_count == 0 and
            scratch.consecutive_interrupts == 0 and
            scratch.attempt.saved_self_addr == 0 and
            scratch.would_block.attempt_generation == 0 and
            std.mem.allEqual(u8, &scratch.spent_receipt_digest, 0) and
            scratch.active_borrow_addr == 0 and
            std.mem.allEqual(u8, &scratch.active_borrow_digest, 0) and
            scratch.active_use_permit_addr == 0 and
            std.mem.allEqual(u8, &scratch.active_use_permit_digest, 0) and
            scratch.active_prepared_use_permit_addr == 0 and
            std.mem.allEqual(
                u8,
                &scratch.active_prepared_use_permit_digest,
                0,
            ) and
            scratch.validation_bytes_checked == 0 and
            stagedPrefixIntact(scratch),
        else => false,
    };
    if (!lifecycle_valid) return .stale_or_moved;
    scratch.* = .{
        .saved_self_addr = @intFromPtr(scratch),
        .generation = scratch.generation,
        .lifecycle = .closed,
    };
    scratch.digest = scratchDigest(scratch);
    return .closed;
}

pub const testing = if (builtin.is_test) struct {
    pub const AttemptMutation = enum {
        authority,
        destination,
        ops,
        lifecycle,
        digest,
    };

    pub fn mutateLiveAttempt(
        scratch: *ExternalRxReadScratch,
        mutation: AttemptMutation,
    ) void {
        switch (mutation) {
            .authority => scratch.attempt.authority.fd += 1,
            .destination => scratch.attempt.destination_len += 1,
            .ops => scratch.attempt.ops_addr += 1,
            .lifecycle => scratch.attempt.lifecycle = .aborted,
            .digest => scratch.attempt.digest[0] +%= 1,
        }
    }

    pub fn forceReadyGeneration(
        scratch: *ExternalRxReadScratch,
        generation: u64,
    ) bool {
        if (!scratch.isReady() or generation == 0) return false;
        scratch.generation = generation;
        scratch.digest = scratchDigest(scratch);
        return scratch.isReady();
    }
} else struct {};

comptime {
    if (@sizeOf(ExternalRxReadScratch) > max_external_rx_read_scratch_bytes)
        @compileError("external RX read scratch exceeds 1.25 MiB");
    if (@sizeOf(ExternalRxReadScratch) - max_rx_read_bytes_per_turn >
        max_external_rx_read_metadata_bytes)
        @compileError("external RX read metadata exceeds 256 KiB");
}

test "C1 read scratch is final-address sealed within its analytic budget" {
    const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    scratch.saved_self_addr = 0;
    scratch.generation = 0;
    scratch.lifecycle = .empty;
    try std.testing.expect(ExternalRxReadScratch.initInPlace(scratch));
    if (!scratch.isReady()) {
        std.debug.print("C1 read scratch initial ready seal mismatch\n", .{});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(!ExternalRxReadScratch.initInPlace(scratch));
    const copied = try std.testing.allocator.create(ExternalRxReadScratch);
    defer std.testing.allocator.destroy(copied);
    copied.saved_self_addr = 0;
    copied.generation = 0;
    copied.lifecycle = .empty;
    try std.testing.expect(ExternalRxReadScratch.initInPlace(copied));
    copied.saved_self_addr = scratch.saved_self_addr;
    copied.digest = scratch.digest;
    if (copied.isReady()) {
        std.debug.print("C1 read scratch copied address was accepted\n", .{});
        return error.TestUnexpectedResult;
    }
    scratch.chunks[0].len = 1;
    try std.testing.expect(!scratch.isReady());
    scratch.chunks[0] = .{};
    scratch.attempt.destination_len = 1;
    try std.testing.expect(!scratch.isReady());
    scratch.attempt.destination_len = 0;
    scratch.would_block.attempt_generation = 1;
    try std.testing.expect(!scratch.isReady());
    scratch.would_block.attempt_generation = 0;
    scratch.prepared_admit.allocator = std.testing.allocator;
    try std.testing.expect(!scratch.isReady());
    try std.testing.expect(
        @sizeOf(ExternalRxReadScratch) <= max_external_rx_read_scratch_bytes,
    );
    try std.testing.expectEqual(
        max_rx_staged_prefix_validation_bytes_per_turn,
        64 * 1024 * 1024,
    );
}

test "C1 accepted allowance stop table fixes every limit tie precedence" {
    const Limit = struct {
        resident: bool,
        turn: bool,
        counter: bool,
        empty: AcceptedAllowanceStop,
        incomplete: AcceptedAllowanceStop,
    };
    const limits = [_]Limit{
        .{
            .resident = true,
            .turn = false,
            .counter = false,
            .empty = .immediate,
            .incomplete = .resident_incomplete_terminal,
        },
        .{
            .resident = false,
            .turn = true,
            .counter = false,
            .empty = .immediate,
            .incomplete = .immediate,
        },
        .{
            .resident = false,
            .turn = false,
            .counter = true,
            .empty = .counter_terminal,
            .incomplete = .counter_terminal,
        },
        .{
            .resident = true,
            .turn = true,
            .counter = false,
            .empty = .immediate,
            .incomplete = .resident_incomplete_terminal,
        },
        .{
            .resident = true,
            .turn = false,
            .counter = true,
            .empty = .counter_terminal,
            .incomplete = .counter_terminal,
        },
        .{
            .resident = false,
            .turn = true,
            .counter = true,
            .empty = .counter_terminal,
            .incomplete = .counter_terminal,
        },
        .{
            .resident = true,
            .turn = true,
            .counter = true,
            .empty = .counter_terminal,
            .incomplete = .counter_terminal,
        },
    };
    for (limits) |limit| {
        const allowance = RxReadableAllowance{
            .bytes = 1,
            .resident_limited = limit.resident,
            .turn_limited = limit.turn,
            .counter_limited = limit.counter,
        };
        try std.testing.expectEqual(
            AcceptedAllowanceStop.continue_collecting,
            classifyAcceptedAllowanceStop(allowance, 0, .empty),
        );
        try std.testing.expectEqual(
            limit.empty,
            classifyAcceptedAllowanceStop(allowance, 1, .empty),
        );
        try std.testing.expectEqual(
            limit.incomplete,
            classifyAcceptedAllowanceStop(allowance, 1, .incomplete),
        );
        try std.testing.expectEqual(
            AcceptedAllowanceStop.invalid,
            classifyAcceptedAllowanceStop(allowance, 2, .empty),
        );
    }
    try std.testing.expectEqual(
        AcceptedAllowanceStop.invalid,
        classifyAcceptedAllowanceStop(.{
            .bytes = 1,
            .resident_limited = false,
            .turn_limited = false,
            .counter_limited = false,
        }, 1, .empty),
    );
    try std.testing.expectEqual(
        AcceptedAllowanceStop.invalid,
        classifyAcceptedAllowanceStop(.{
            .bytes = 0,
            .resident_limited = true,
            .turn_limited = false,
            .counter_limited = false,
        }, 0, .empty),
    );
}

const BorrowUseSeedMutation = enum {
    saved_self_addr,
    scratch_addr,
    scratch_generation,
    receipt_digest,
    borrow_addr,
    attempt_generation,
    lifecycle,
    digest,
};

const PreparedUseGuardMutation = enum {
    scratch,
    receipt,
    borrow,
    use_permit,
    seed,
    token,
    prepared,
};

const BorrowUseGuardProbe = struct {
    state: ?bool = false,
    callback_calls: usize = 0,
    seed: ?*WouldBlockSeed = null,
    seed_mutation: ?BorrowUseSeedMutation = null,
    receipt: ?*CollectReceipt = null,
    mutate_receipt: bool = false,
    borrow: ?*StoppedBorrow = null,
    mutate_borrow: bool = false,
    scratch: ?*ExternalRxReadScratch = null,
    use_permit: ?*BorrowUsePermit = null,
    prepared_token: ?*PreparedAdmitUsePermit = null,
    prepared_mutation: ?PreparedUseGuardMutation = null,

    fn current(context: *anyopaque, _: usize) ?bool {
        const self: *BorrowUseGuardProbe = @ptrCast(@alignCast(context));
        self.callback_calls += 1;
        if (self.seed_mutation) |mutation| {
            const seed = self.seed.?;
            switch (mutation) {
                .saved_self_addr => seed.saved_self_addr +%= 1,
                .scratch_addr => seed.scratch_addr +%= 1,
                .scratch_generation => seed.scratch_generation +%= 1,
                .receipt_digest => seed.receipt_digest[0] +%= 1,
                .borrow_addr => seed.borrow_addr +%= 1,
                .attempt_generation => seed.attempt_generation +%= 1,
                .lifecycle => seed.lifecycle = .aborted,
                .digest => seed.digest[0] +%= 1,
            }
        }
        if (self.mutate_receipt)
            self.receipt.?.attempts +%= 1;
        if (self.mutate_borrow)
            self.borrow.?.bytes_len +%= 1;
        if (self.prepared_mutation) |mutation| switch (mutation) {
            .scratch => self.scratch.?.staged_len +%= 1,
            .receipt => self.receipt.?.attempts +%= 1,
            .borrow => self.borrow.?.bytes_len +%= 1,
            .use_permit => self.use_permit.?.digest[0] +%= 1,
            .seed => self.seed.?.digest[0] +%= 1,
            .token => self.prepared_token.?.digest[0] +%= 1,
            .prepared => self.scratch.?.prepared_admit.expected_start = 1,
        };
        return self.state;
    }
};

fn makeStoppedWouldBlockFixture(
    scratch: *ExternalRxReadScratch,
    receipt: *CollectReceipt,
    borrow: *StoppedBorrow,
) !void {
    scratch.* = .{};
    try std.testing.expect(ExternalRxReadScratch.initInPlace(scratch));
    scratch.lifecycle = .spent;
    scratch.attempt_count = 1;
    scratch.would_block = .{
        .attempt_generation = 1,
        .lifecycle = .observed,
    };
    scratch.would_block.digest = wouldBlockDigest(&scratch.would_block);
    receipt.* = .{
        .scratch_addr = @intFromPtr(scratch),
        .scratch_generation = scratch.generation,
        .allowance = .{
            .bytes = 1,
            .resident_limited = true,
            .turn_limited = false,
            .counter_limited = false,
        },
        .accepted_bytes = 0,
        .attempts = 1,
        .stop = .would_block,
        .digest = undefined,
    };
    receipt.digest = receiptDigest(receipt);
    scratch.spent_receipt_digest = receipt.digest;
    scratch.digest = scratchDigest(scratch);
    borrow.* = .{};
    try std.testing.expect(borrowStopped(scratch, receipt, borrow));
}

fn makeSettledWouldBlockFixture(
    scratch: *ExternalRxReadScratch,
    receipt: *CollectReceipt,
    borrow: *StoppedBorrow,
    guard_probe: *BorrowUseGuardProbe,
    seed: *WouldBlockSeed,
    use_permit: *BorrowUsePermit,
) !void {
    try makeStoppedWouldBlockFixture(scratch, receipt, borrow);
    guard_probe.* = .{};
    const guard = BorrowUseGuardOps{
        .context = guard_probe,
        .context_len = @sizeOf(BorrowUseGuardProbe),
        .current = BorrowUseGuardProbe.current,
    };
    seed.* = .{};
    use_permit.* = .{};
    try std.testing.expect(beginStoppedUse(
        scratch,
        receipt,
        borrow,
        &guard,
        seed,
        use_permit,
    ));
    try std.testing.expect(mintBorrowedWouldBlockSeed(
        scratch,
        receipt,
        borrow,
        use_permit,
        seed,
    ));
    try std.testing.expect(consumeWouldBlockSeed(
        scratch,
        use_permit,
        seed,
    ) != null);
    try std.testing.expect(endStoppedUse(
        scratch,
        receipt,
        borrow,
        use_permit,
    ));
    try std.testing.expect(settleStopped(
        scratch,
        receipt,
        borrow,
        .{
            .staged = .discarded,
            .would_block = .consumed,
        },
    ));
}

fn makeActivePreparedUseFixture(
    scratch: *ExternalRxReadScratch,
    receipt: *CollectReceipt,
    borrow: *StoppedBorrow,
    guard_probe: *BorrowUseGuardProbe,
    seed: *WouldBlockSeed,
    use_permit: *BorrowUsePermit,
    prepared_permit: *PreparedAdmitUsePermit,
) !void {
    try makeStoppedWouldBlockFixture(scratch, receipt, borrow);
    guard_probe.* = .{};
    const guard = BorrowUseGuardOps{
        .context = guard_probe,
        .context_len = @sizeOf(BorrowUseGuardProbe),
        .current = BorrowUseGuardProbe.current,
    };
    seed.* = .{};
    use_permit.* = .{};
    try std.testing.expect(beginStoppedUse(
        scratch,
        receipt,
        borrow,
        &guard,
        seed,
        use_permit,
    ));
    prepared_permit.* = .{};
    try std.testing.expect(beginPreparedAdmitUse(
        scratch,
        receipt,
        borrow,
        use_permit,
        seed,
        prepared_permit,
    ));
    seed.* = .{
        .saved_self_addr = @intFromPtr(seed),
        .scratch_addr = @intFromPtr(scratch),
        .scratch_generation = scratch.generation,
        .receipt_digest = receipt.digest,
        .borrow_addr = @intFromPtr(borrow),
        .attempt_generation = scratch.would_block.attempt_generation,
        .lifecycle = .prepared,
    };
    seed.digest = wouldBlockSeedDigest(seed);
    use_permit.seed_lifecycle = .prepared;
    use_permit.seed_digest = seed.digest;
    use_permit.digest = borrowUsePermitDigest(use_permit);
    scratch.active_use_permit_digest = use_permit.digest;
    scratch.digest = scratchDigest(scratch);
    prepared_permit.frozen_outer_digest = scratchPreparedOuterDigest(scratch);
    prepared_permit.frozen_receipt = receipt.*;
    prepared_permit.frozen_borrow = borrow.*;
    prepared_permit.frozen_use_permit = use_permit.*;
    prepared_permit.frozen_seed = seed.*;
    prepared_permit.digest = preparedAdmitUsePermitDigest(prepared_permit);
    scratch.active_prepared_use_permit_digest = prepared_permit.digest;
    scratch.digest = scratchDigest(scratch);
}

fn makeFinishedPreparedUseFixture(
    scratch: *ExternalRxReadScratch,
    receipt: *CollectReceipt,
    borrow: *StoppedBorrow,
    guard_probe: *BorrowUseGuardProbe,
    seed: *WouldBlockSeed,
    use_permit: *BorrowUsePermit,
    prepared_permit: *PreparedAdmitUsePermit,
) !void {
    try makeStoppedWouldBlockFixture(scratch, receipt, borrow);
    guard_probe.* = .{};
    const guard = BorrowUseGuardOps{
        .context = guard_probe,
        .context_len = @sizeOf(BorrowUseGuardProbe),
        .current = BorrowUseGuardProbe.current,
    };
    seed.* = .{};
    use_permit.* = .{};
    try std.testing.expect(beginStoppedUse(
        scratch,
        receipt,
        borrow,
        &guard,
        seed,
        use_permit,
    ));
    prepared_permit.* = .{};
    try std.testing.expect(beginPreparedAdmitUse(
        scratch,
        receipt,
        borrow,
        use_permit,
        seed,
        prepared_permit,
    ));
    try std.testing.expect(finishPreparedAdmitUse(
        scratch,
        receipt,
        borrow,
        use_permit,
        seed,
        prepared_permit,
    ));
}

test "settled stopped graph terminalization authenticates every tombstone" {
    const Mutation = enum {
        none,
        scratch,
        receipt,
        borrow,
        use_permit,
        seed,
        prepared_use,
        would_block_seed_absent,
        non_would_block_seed_present,
        permit_seed_mismatch,
    };
    for (std.enums.values(Mutation)) |mutation| {
        const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var receipt: CollectReceipt = undefined;
        var borrow: StoppedBorrow = .{};
        var guard_probe: BorrowUseGuardProbe = .{};
        var seed: WouldBlockSeed = .{};
        var use_permit: BorrowUsePermit = .{};
        var prepared_use: PreparedAdmitUsePermit = .{};
        try makeSettledWouldBlockFixture(
            scratch,
            &receipt,
            &borrow,
            &guard_probe,
            &seed,
            &use_permit,
        );
        switch (mutation) {
            .none => {},
            .scratch => scratch.digest[0] +%= 1,
            .receipt => receipt.digest[0] +%= 1,
            .borrow => borrow.digest[0] +%= 1,
            .use_permit => use_permit.digest[0] +%= 1,
            .seed => seed.digest[0] +%= 1,
            .prepared_use => prepared_use.saved_self_addr =
                @intFromPtr(&prepared_use),
            .would_block_seed_absent => {
                seed = .{};
                use_permit.seed_lifecycle = .unminted;
                use_permit.seed_digest = [_]u8{0} ** 32;
                use_permit.digest = borrowUsePermitDigest(&use_permit);
            },
            .non_would_block_seed_present => {
                receipt.stop = .allowance_reached;
                receipt.digest = receiptDigest(&receipt);
                borrow.receipt_digest = receipt.digest;
                borrow.digest = borrowDigest(&borrow);
                use_permit.receipt_digest = receipt.digest;
                seed.receipt_digest = receipt.digest;
                seed.digest = wouldBlockSeedDigest(&seed);
                use_permit.seed_digest = seed.digest;
                use_permit.digest = borrowUsePermitDigest(&use_permit);
            },
            .permit_seed_mismatch => {
                use_permit.seed_lifecycle = .aborted;
                use_permit.digest = borrowUsePermitDigest(&use_permit);
            },
        }
        const scratch_before = std.mem.asBytes(scratch).*;
        const receipt_before = std.mem.asBytes(&receipt).*;
        const borrow_before = std.mem.asBytes(&borrow).*;
        const use_permit_before = std.mem.asBytes(&use_permit).*;
        const seed_before = std.mem.asBytes(&seed).*;
        const prepared_use_before = std.mem.asBytes(&prepared_use).*;
        const callback_calls_before = guard_probe.callback_calls;
        const expected: StoppedGraphTerminalizeResult =
            if (mutation == .none) .closed else .unrecoverable;
        try std.testing.expectEqual(
            expected,
            terminalizeStoppedGraphNoCallback(
                scratch,
                &receipt,
                &borrow,
                &use_permit,
                &seed,
                &prepared_use,
            ),
        );
        if (mutation == .none)
            try std.testing.expectEqual(Lifecycle.terminal, scratch.lifecycle)
        else {
            try std.testing.expectEqual(Lifecycle.ready, scratch.lifecycle);
            try std.testing.expectEqualSlices(
                u8,
                &scratch_before,
                std.mem.asBytes(scratch),
            );
            try std.testing.expectEqualSlices(
                u8,
                &receipt_before,
                std.mem.asBytes(&receipt),
            );
            try std.testing.expectEqualSlices(
                u8,
                &borrow_before,
                std.mem.asBytes(&borrow),
            );
            try std.testing.expectEqualSlices(
                u8,
                &use_permit_before,
                std.mem.asBytes(&use_permit),
            );
            try std.testing.expectEqualSlices(
                u8,
                &seed_before,
                std.mem.asBytes(&seed),
            );
            try std.testing.expectEqualSlices(
                u8,
                &prepared_use_before,
                std.mem.asBytes(&prepared_use),
            );
        }
        try std.testing.expectEqual(
            callback_calls_before,
            guard_probe.callback_calls,
        );
    }
}

test "C4c no-callback stopped graph terminalizer closes active graph and replays" {
    const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var receipt: CollectReceipt = undefined;
    var borrow: StoppedBorrow = .{};
    var guard_probe: BorrowUseGuardProbe = .{};
    var seed: WouldBlockSeed = .{};
    var use_permit: BorrowUsePermit = .{};
    var prepared_permit: PreparedAdmitUsePermit = .{};
    try makeActivePreparedUseFixture(
        scratch,
        &receipt,
        &borrow,
        &guard_probe,
        &seed,
        &use_permit,
        &prepared_permit,
    );
    const callback_calls = guard_probe.callback_calls;
    try std.testing.expectEqual(
        StoppedGraphTerminalizeResult.closed,
        terminalizeStoppedGraphNoCallback(
            scratch,
            &receipt,
            &borrow,
            &use_permit,
            &seed,
            &prepared_permit,
        ),
    );
    try std.testing.expectEqual(callback_calls, guard_probe.callback_calls);
    try std.testing.expectEqual(Lifecycle.terminal, scratch.lifecycle);
    try std.testing.expectEqual(BorrowLifecycle.aborted, borrow.lifecycle);
    try std.testing.expectEqual(BorrowUseLifecycle.aborted, use_permit.lifecycle);
    try std.testing.expectEqual(WouldBlockSeedLifecycle.aborted, seed.lifecycle);
    try std.testing.expectEqual(
        PreparedAdmitUseLifecycle.aborted,
        prepared_permit.lifecycle,
    );
    try std.testing.expectEqual(
        StoppedGraphTerminalizeResult.already_closed,
        terminalizeStoppedGraphNoCallback(
            scratch,
            &receipt,
            &borrow,
            &use_permit,
            &seed,
            &prepared_permit,
        ),
    );
    try std.testing.expectEqual(callback_calls, guard_probe.callback_calls);
}

test "C4c no-callback stopped graph terminalizer rejects drift without mutation" {
    const Field = enum {
        scratch,
        receipt,
        borrow,
        use_permit,
        seed,
        prepared_permit,
    };
    inline for (std.meta.tags(Field)) |field| {
        const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var receipt: CollectReceipt = undefined;
        var borrow: StoppedBorrow = .{};
        var guard_probe: BorrowUseGuardProbe = .{};
        var seed: WouldBlockSeed = .{};
        var use_permit: BorrowUsePermit = .{};
        var prepared_permit: PreparedAdmitUsePermit = .{};
        try makeActivePreparedUseFixture(
            scratch,
            &receipt,
            &borrow,
            &guard_probe,
            &seed,
            &use_permit,
            &prepared_permit,
        );
        switch (field) {
            .scratch => scratch.digest[0] +%= 1,
            .receipt => receipt.digest[0] +%= 1,
            .borrow => borrow.digest[0] +%= 1,
            .use_permit => use_permit.digest[0] +%= 1,
            .seed => seed.digest[0] +%= 1,
            .prepared_permit => prepared_permit.digest[0] +%= 1,
        }
        const before_scratch = scratch.*;
        const before_receipt = receipt;
        const before_borrow = borrow;
        const before_use = use_permit;
        const before_seed = seed;
        const before_prepared = prepared_permit;
        const callback_calls = guard_probe.callback_calls;
        try std.testing.expectEqual(
            StoppedGraphTerminalizeResult.unrecoverable,
            terminalizeStoppedGraphNoCallback(
                scratch,
                &receipt,
                &borrow,
                &use_permit,
                &seed,
                &prepared_permit,
            ),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&before_scratch),
            std.mem.asBytes(scratch),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&before_receipt),
            std.mem.asBytes(&receipt),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&before_borrow),
            std.mem.asBytes(&borrow),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&before_use),
            std.mem.asBytes(&use_permit),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&before_seed),
            std.mem.asBytes(&seed),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&before_prepared),
            std.mem.asBytes(&prepared_permit),
        );
        try std.testing.expectEqual(callback_calls, guard_probe.callback_calls);
    }
}

test "C4c no-callback stopped graph terminalizer rejects alias copy and overflow" {
    const Case = enum { alias, moved_copy, overflow };
    inline for (std.meta.tags(Case)) |case| {
        const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var receipt: CollectReceipt = undefined;
        var borrow: StoppedBorrow = .{};
        var guard_probe: BorrowUseGuardProbe = .{};
        var seed: WouldBlockSeed = .{};
        var use_permit: BorrowUsePermit = .{};
        var prepared_permit: PreparedAdmitUsePermit = .{};
        try makeActivePreparedUseFixture(
            scratch,
            &receipt,
            &borrow,
            &guard_probe,
            &seed,
            &use_permit,
            &prepared_permit,
        );
        var moved = prepared_permit;
        const candidate: *PreparedAdmitUsePermit = switch (case) {
            .alias => @ptrCast(@alignCast(&use_permit)),
            .moved_copy => &moved,
            .overflow => @ptrFromInt(
                std.math.maxInt(usize) &
                    ~(@as(usize, @alignOf(PreparedAdmitUsePermit)) - 1),
            ),
        };
        const before_scratch = scratch.*;
        const before_borrow = borrow;
        const before_use = use_permit;
        const before_seed = seed;
        const callback_calls = guard_probe.callback_calls;
        try std.testing.expectEqual(
            StoppedGraphTerminalizeResult.unrecoverable,
            terminalizeStoppedGraphNoCallback(
                scratch,
                &receipt,
                &borrow,
                &use_permit,
                &seed,
                candidate,
            ),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&before_scratch),
            std.mem.asBytes(scratch),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&before_borrow),
            std.mem.asBytes(&borrow),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&before_use),
            std.mem.asBytes(&use_permit),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&before_seed),
            std.mem.asBytes(&seed),
        );
        try std.testing.expectEqual(callback_calls, guard_probe.callback_calls);
    }
}

test "C4c no-callback stopped graph terminalizer accepts sealed closed lifecycle variants" {
    const Variant = enum {
        prepared_finished,
        prepared_empty,
        seed_consumed,
        seed_empty,
        use_released,
        use_empty,
        borrow_settled,
        borrow_empty,
    };
    inline for (std.meta.tags(Variant)) |variant| {
        const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var receipt: CollectReceipt = undefined;
        var borrow: StoppedBorrow = .{};
        var guard_probe: BorrowUseGuardProbe = .{};
        var seed: WouldBlockSeed = .{};
        var use_permit: BorrowUsePermit = .{};
        var prepared_permit: PreparedAdmitUsePermit = .{};
        try makeActivePreparedUseFixture(
            scratch,
            &receipt,
            &borrow,
            &guard_probe,
            &seed,
            &use_permit,
            &prepared_permit,
        );
        try std.testing.expectEqual(
            StoppedGraphTerminalizeResult.closed,
            terminalizeStoppedGraphNoCallback(
                scratch,
                &receipt,
                &borrow,
                &use_permit,
                &seed,
                &prepared_permit,
            ),
        );
        switch (variant) {
            .prepared_finished => {
                prepared_permit.lifecycle = .finished;
                prepared_permit.digest =
                    preparedAdmitUsePermitDigest(&prepared_permit);
            },
            .prepared_empty => prepared_permit = .{},
            .seed_consumed => {
                seed.lifecycle = .consumed;
                seed.digest = wouldBlockSeedDigest(&seed);
                use_permit.seed_lifecycle = .consumed;
                use_permit.seed_digest = seed.digest;
                use_permit.digest = borrowUsePermitDigest(&use_permit);
            },
            .seed_empty => {
                seed = .{};
                use_permit.seed_lifecycle = .unminted;
                use_permit.seed_digest = [_]u8{0} ** 32;
                use_permit.digest = borrowUsePermitDigest(&use_permit);
            },
            .use_released => {
                use_permit.lifecycle = .released;
                use_permit.digest = borrowUsePermitDigest(&use_permit);
            },
            .use_empty => use_permit = .{},
            .borrow_settled => {
                borrow.lifecycle = .settled;
                borrow.digest = borrowDigest(&borrow);
            },
            .borrow_empty => borrow = .{},
        }
        const callback_calls = guard_probe.callback_calls;
        try std.testing.expectEqual(
            StoppedGraphTerminalizeResult.already_closed,
            terminalizeStoppedGraphNoCallback(
                scratch,
                &receipt,
                &borrow,
                &use_permit,
                &seed,
                &prepared_permit,
            ),
        );
        try std.testing.expectEqual(callback_calls, guard_probe.callback_calls);
    }
}

test "C4c no-callback stopped graph terminalizer closes every reachable active boundary" {
    const Boundary = enum {
        stopped_use_unminted,
        prepared_active_unminted,
        prepared_finished_unminted,
        prepared_reset_unminted,
        seed_consumed,
        seed_aborted,
    };
    inline for (std.meta.tags(Boundary)) |boundary| {
        const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var receipt: CollectReceipt = undefined;
        var borrow: StoppedBorrow = .{};
        var guard_probe: BorrowUseGuardProbe = .{};
        var seed: WouldBlockSeed = .{};
        var use_permit: BorrowUsePermit = .{};
        var prepared_permit: PreparedAdmitUsePermit = .{};
        try makeStoppedWouldBlockFixture(scratch, &receipt, &borrow);
        const guard = BorrowUseGuardOps{
            .context = &guard_probe,
            .context_len = @sizeOf(BorrowUseGuardProbe),
            .current = BorrowUseGuardProbe.current,
        };
        try std.testing.expect(beginStoppedUse(
            scratch,
            &receipt,
            &borrow,
            &guard,
            &seed,
            &use_permit,
        ));
        switch (boundary) {
            .stopped_use_unminted => {},
            .prepared_active_unminted,
            .prepared_finished_unminted,
            .prepared_reset_unminted,
            => {
                try std.testing.expect(beginPreparedAdmitUse(
                    scratch,
                    &receipt,
                    &borrow,
                    &use_permit,
                    &seed,
                    &prepared_permit,
                ));
                if (boundary != .prepared_active_unminted) {
                    try std.testing.expect(finishPreparedAdmitUse(
                        scratch,
                        &receipt,
                        &borrow,
                        &use_permit,
                        &seed,
                        &prepared_permit,
                    ));
                    if (boundary == .prepared_reset_unminted)
                        try std.testing.expect(resetFinishedPreparedAdmitUse(
                            scratch,
                            &prepared_permit,
                        ));
                }
            },
            .seed_consumed, .seed_aborted => {
                try std.testing.expect(mintBorrowedWouldBlockSeed(
                    scratch,
                    &receipt,
                    &borrow,
                    &use_permit,
                    &seed,
                ));
                if (boundary == .seed_consumed)
                    try std.testing.expect(
                        consumeWouldBlockSeed(
                            scratch,
                            &use_permit,
                            &seed,
                        ) != null,
                    )
                else
                    try std.testing.expect(abortWouldBlockSeed(
                        scratch,
                        &use_permit,
                        &seed,
                    ));
            },
        }
        scratch.digest[0] +%= 1;
        const drifted_scratch = scratch.*;
        const drifted_borrow = borrow;
        const drifted_use = use_permit;
        const drifted_seed = seed;
        const drifted_prepared = prepared_permit;
        const drift_callback_calls = guard_probe.callback_calls;
        try std.testing.expectEqual(
            StoppedGraphTerminalizeResult.unrecoverable,
            terminalizeStoppedGraphNoCallback(
                scratch,
                &receipt,
                &borrow,
                &use_permit,
                &seed,
                &prepared_permit,
            ),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&drifted_scratch),
            std.mem.asBytes(scratch),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&drifted_borrow),
            std.mem.asBytes(&borrow),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&drifted_use),
            std.mem.asBytes(&use_permit),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&drifted_seed),
            std.mem.asBytes(&seed),
        );
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&drifted_prepared),
            std.mem.asBytes(&prepared_permit),
        );
        try std.testing.expectEqual(
            drift_callback_calls,
            guard_probe.callback_calls,
        );
        scratch.digest[0] -%= 1;
        const seed_before = seed.lifecycle;
        const prepared_before = prepared_permit.lifecycle;
        const callback_calls = guard_probe.callback_calls;
        try std.testing.expectEqual(
            StoppedGraphTerminalizeResult.closed,
            terminalizeStoppedGraphNoCallback(
                scratch,
                &receipt,
                &borrow,
                &use_permit,
                &seed,
                &prepared_permit,
            ),
        );
        try std.testing.expectEqual(callback_calls, guard_probe.callback_calls);
        try std.testing.expectEqual(BorrowLifecycle.aborted, borrow.lifecycle);
        try std.testing.expectEqual(BorrowUseLifecycle.aborted, use_permit.lifecycle);
        if (seed_before == .consumed or seed_before == .aborted)
            try std.testing.expectEqual(seed_before, seed.lifecycle);
        if (prepared_before == .finished)
            try std.testing.expectEqual(
                PreparedAdmitUseLifecycle.finished,
                prepared_permit.lifecycle,
            );
    }
}

test "C4c active stopped use accounts would-block seed before settlement" {
    const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var receipt: CollectReceipt = undefined;
    var borrow: StoppedBorrow = .{};
    try makeStoppedWouldBlockFixture(scratch, &receipt, &borrow);

    var guard_probe: BorrowUseGuardProbe = .{};
    var guard = BorrowUseGuardOps{
        .context = &guard_probe,
        .context_len = @sizeOf(BorrowUseGuardProbe),
        .current = BorrowUseGuardProbe.current,
    };
    var seed: WouldBlockSeed = .{};
    var permit: BorrowUsePermit = .{};
    try std.testing.expect(beginStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &guard,
        &seed,
        &permit,
    ));
    try std.testing.expect(!settleStopped(
        scratch,
        &receipt,
        &borrow,
        .{
            .staged = .consumed,
            .would_block = .consumed,
        },
    ));
    try std.testing.expectEqual(
        ReadScratchTeardownResult.busy,
        teardown(scratch),
    );
    try std.testing.expect(mintBorrowedWouldBlockSeed(
        scratch,
        &receipt,
        &borrow,
        &permit,
        &seed,
    ));
    try std.testing.expect(!endStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &permit,
    ));

    var copied_seed = seed;
    try std.testing.expect(
        consumeWouldBlockSeed(scratch, &permit, &copied_seed) == null,
    );
    try std.testing.expectEqual(
        @as(?u64, 1),
        consumeWouldBlockSeed(scratch, &permit, &seed),
    );
    var copied_permit = permit;
    try std.testing.expect(!endStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &copied_permit,
    ));
    guard_probe.state = true;
    try std.testing.expect(!endStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &permit,
    ));
    try std.testing.expectEqual(
        ReadScratchTeardownResult.busy,
        teardown(scratch),
    );
    guard_probe.state = null;
    try std.testing.expect(!endStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &permit,
    ));
    guard_probe.state = false;
    try std.testing.expect(endStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &permit,
    ));
    try std.testing.expect(!endStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &permit,
    ));
    try std.testing.expect(settleStopped(
        scratch,
        &receipt,
        &borrow,
        .{
            .staged = .consumed,
            .would_block = .consumed,
        },
    ));
    try std.testing.expectEqual(ReadScratchTeardownResult.closed, teardown(scratch));
}

test "S3-D drain seed projection preserves continuity across its linear phase" {
    const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var receipt: CollectReceipt = undefined;
    var borrow: StoppedBorrow = .{};
    try makeStoppedWouldBlockFixture(scratch, &receipt, &borrow);
    var guard_probe: BorrowUseGuardProbe = .{};
    var guard = BorrowUseGuardOps{
        .context = &guard_probe,
        .context_len = @sizeOf(BorrowUseGuardProbe),
        .current = BorrowUseGuardProbe.current,
    };
    var seed: WouldBlockSeed = .{};
    var permit: BorrowUsePermit = .{};
    try std.testing.expect(beginStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &guard,
        &seed,
        &permit,
    ));
    try std.testing.expect(mintBorrowedWouldBlockSeed(
        scratch,
        &receipt,
        &borrow,
        &permit,
        &seed,
    ));
    const callback_calls_before_snapshot = guard_probe.callback_calls;
    const prepared = snapshotDrainSeedAuthority(
        scratch,
        &receipt,
        &borrow,
        &permit,
        &seed,
        .prepared,
    ).?;
    try std.testing.expectEqual(
        callback_calls_before_snapshot,
        guard_probe.callback_calls,
    );
    try std.testing.expectEqual(
        @as(?u64, prepared.attempt_generation),
        consumeWouldBlockSeed(scratch, &permit, &seed),
    );
    const callback_calls_before_consumed_snapshot = guard_probe.callback_calls;
    const consumed = snapshotDrainSeedAuthority(
        scratch,
        &receipt,
        &borrow,
        &permit,
        &seed,
        .consumed,
    ).?;
    try std.testing.expectEqual(
        callback_calls_before_consumed_snapshot,
        guard_probe.callback_calls,
    );
    try std.testing.expectEqual(DrainSeedAuthorityPhase.prepared, prepared.phase);
    try std.testing.expectEqual(DrainSeedAuthorityPhase.consumed, consumed.phase);
    try std.testing.expect(std.mem.eql(
        u8,
        &prepared.continuity_digest,
        &consumed.continuity_digest,
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        &prepared.digest,
        &consumed.digest,
    ));
    try std.testing.expectEqual(prepared.scratch_addr, consumed.scratch_addr);
    try std.testing.expectEqual(prepared.receipt_addr, consumed.receipt_addr);
    try std.testing.expectEqual(prepared.borrow_addr, consumed.borrow_addr);
    try std.testing.expectEqual(prepared.permit_addr, consumed.permit_addr);
    try std.testing.expectEqual(prepared.seed_addr, consumed.seed_addr);
}

test "S3-D drain seed projection rejects copied and drifted authority without mutation" {
    const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var receipt: CollectReceipt = undefined;
    var borrow: StoppedBorrow = .{};
    try makeStoppedWouldBlockFixture(scratch, &receipt, &borrow);
    var guard_probe: BorrowUseGuardProbe = .{};
    var guard = BorrowUseGuardOps{
        .context = &guard_probe,
        .context_len = @sizeOf(BorrowUseGuardProbe),
        .current = BorrowUseGuardProbe.current,
    };
    var seed: WouldBlockSeed = .{};
    var permit: BorrowUsePermit = .{};
    try std.testing.expect(beginStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &guard,
        &seed,
        &permit,
    ));
    try std.testing.expect(mintBorrowedWouldBlockSeed(
        scratch,
        &receipt,
        &borrow,
        &permit,
        &seed,
    ));

    var copied_receipt = receipt;
    var copied_borrow = borrow;
    var copied_permit = permit;
    var copied_seed = seed;
    const callback_calls_before_snapshot = guard_probe.callback_calls;
    inline for (.{
        .{ &copied_receipt, &borrow, &permit, &seed },
        .{ &receipt, &copied_borrow, &permit, &seed },
        .{ &receipt, &borrow, &copied_permit, &seed },
        .{ &receipt, &borrow, &permit, &copied_seed },
    }) |graph| {
        const before_scratch = scratch.*;
        const before_receipt = receipt;
        const before_borrow = borrow;
        const before_permit = permit;
        const before_seed = seed;
        try std.testing.expect(snapshotDrainSeedAuthority(
            scratch,
            graph[0],
            graph[1],
            graph[2],
            graph[3],
            .prepared,
        ) == null);
        try std.testing.expect(std.mem.eql(
            u8,
            std.mem.asBytes(&before_scratch),
            std.mem.asBytes(scratch),
        ));
        try std.testing.expect(std.mem.eql(
            u8,
            std.mem.asBytes(&before_receipt),
            std.mem.asBytes(&receipt),
        ));
        try std.testing.expect(std.mem.eql(
            u8,
            std.mem.asBytes(&before_borrow),
            std.mem.asBytes(&borrow),
        ));
        try std.testing.expect(std.mem.eql(
            u8,
            std.mem.asBytes(&before_permit),
            std.mem.asBytes(&permit),
        ));
        try std.testing.expect(std.mem.eql(
            u8,
            std.mem.asBytes(&before_seed),
            std.mem.asBytes(&seed),
        ));
        try std.testing.expectEqual(
            callback_calls_before_snapshot,
            guard_probe.callback_calls,
        );
    }

    const original_receipt = receipt;
    const original_borrow = borrow;
    const original_permit = permit;
    const original_seed = seed;
    inline for ([_]u8{ 0, 1, 2, 3 }) |field| {
        switch (field) {
            0 => receipt.attempts +%= 1,
            1 => borrow.digest[0] ^= 1,
            2 => permit.digest[0] ^= 1,
            3 => seed.digest[0] ^= 1,
            else => unreachable,
        }
        try std.testing.expect(snapshotDrainSeedAuthority(
            scratch,
            &receipt,
            &borrow,
            &permit,
            &seed,
            .prepared,
        ) == null);
        receipt = original_receipt;
        borrow = original_borrow;
        permit = original_permit;
        seed = original_seed;
    }
    try std.testing.expectEqual(
        callback_calls_before_snapshot,
        guard_probe.callback_calls,
    );
}

test "S3-D drain seed graph preflight rejects overlap and overflow and permits adjacency" {
    const Graph = struct {
        fn valid(addresses: [5]usize) bool {
            return drainSeedGraphDisjoint(
                @ptrFromInt(addresses[0]),
                @ptrFromInt(addresses[1]),
                @ptrFromInt(addresses[2]),
                @ptrFromInt(addresses[3]),
                @ptrFromInt(addresses[4]),
            );
        }
    };
    const alignment = comptime @max(
        @alignOf(ExternalRxReadScratch),
        @alignOf(CollectReceipt),
        @alignOf(StoppedBorrow),
        @alignOf(BorrowUsePermit),
        @alignOf(WouldBlockSeed),
    );
    const sizes = [_]usize{
        @sizeOf(ExternalRxReadScratch),
        @sizeOf(CollectReceipt),
        @sizeOf(StoppedBorrow),
        @sizeOf(BorrowUsePermit),
        @sizeOf(WouldBlockSeed),
    };
    var addresses: [5]usize = undefined;
    addresses[0] = 0x10000000;
    for (1..addresses.len) |index| {
        addresses[index] = std.mem.alignForward(
            usize,
            addresses[index - 1] + sizes[index - 1],
            alignment,
        );
    }
    try std.testing.expect(Graph.valid(addresses));

    var isolated: [5]usize = undefined;
    for (0..isolated.len) |index|
        isolated[index] = 0x20000000 + index * 0x400000;
    inline for (0..5) |left| {
        inline for (left + 1..5) |right| {
            var overlapped = isolated;
            overlapped[right] = overlapped[left];
            try std.testing.expect(!Graph.valid(overlapped));

            var partially_overlapped = isolated;
            partially_overlapped[right] =
                partially_overlapped[left] + alignment;
            try std.testing.expect(!Graph.valid(partially_overlapped));

            var adjacent = isolated;
            adjacent[right] = adjacent[left] + sizes[left];
            try std.testing.expect(Graph.valid(adjacent));
        }
    }

    inline for (0..5) |index| {
        var overflowed = addresses;
        const type_alignment = comptime switch (index) {
            0 => @alignOf(ExternalRxReadScratch),
            1 => @alignOf(CollectReceipt),
            2 => @alignOf(StoppedBorrow),
            3 => @alignOf(BorrowUsePermit),
            4 => @alignOf(WouldBlockSeed),
            else => unreachable,
        };
        overflowed[index] =
            std.math.maxInt(usize) - type_alignment + 1;
        try std.testing.expect(!Graph.valid(overflowed));
    }
}

test "C4c stopped use rejects seed output alias and supports abort" {
    const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var receipt: CollectReceipt = undefined;
    var borrow: StoppedBorrow = .{};
    try makeStoppedWouldBlockFixture(scratch, &receipt, &borrow);
    var guard_probe: BorrowUseGuardProbe = .{};
    const guard = BorrowUseGuardOps{
        .context = &guard_probe,
        .context_len = @sizeOf(BorrowUseGuardProbe),
        .current = BorrowUseGuardProbe.current,
    };
    var permit: BorrowUsePermit = .{};
    const alias_seed: *WouldBlockSeed = @ptrCast(@alignCast(&permit));
    try std.testing.expect(!beginStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &guard,
        alias_seed,
        &permit,
    ));
    try std.testing.expectEqual(@as(usize, 0), permit.saved_self_addr);

    var seed: WouldBlockSeed = .{};
    try std.testing.expect(beginStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &guard,
        &seed,
        &permit,
    ));
    const partial_seed: *WouldBlockSeed =
        @ptrFromInt(@intFromPtr(&seed) + @alignOf(WouldBlockSeed));
    const one_past_seed: *WouldBlockSeed =
        @ptrFromInt(@intFromPtr(&seed) + @sizeOf(WouldBlockSeed));
    const overflow_addr =
        std.math.maxInt(usize) & ~(@as(usize, @alignOf(WouldBlockSeed)) - 1);
    const overflow_seed: *WouldBlockSeed = @ptrFromInt(overflow_addr);
    try std.testing.expect(!mintBorrowedWouldBlockSeed(
        scratch,
        &receipt,
        &borrow,
        &permit,
        partial_seed,
    ));
    try std.testing.expect(!mintBorrowedWouldBlockSeed(
        scratch,
        &receipt,
        &borrow,
        &permit,
        one_past_seed,
    ));
    try std.testing.expect(!mintBorrowedWouldBlockSeed(
        scratch,
        &receipt,
        &borrow,
        &permit,
        overflow_seed,
    ));
    try std.testing.expect(mintBorrowedWouldBlockSeed(
        scratch,
        &receipt,
        &borrow,
        &permit,
        &seed,
    ));
    try std.testing.expect(abortWouldBlockSeed(scratch, &permit, &seed));
    try std.testing.expect(!abortWouldBlockSeed(scratch, &permit, &seed));
    try std.testing.expect(endStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &permit,
    ));
}

test "C4c guard cannot bless any callback-mutated seed field" {
    inline for (std.meta.tags(BorrowUseSeedMutation)) |mutation| {
        const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var receipt: CollectReceipt = undefined;
        var borrow: StoppedBorrow = .{};
        try makeStoppedWouldBlockFixture(scratch, &receipt, &borrow);
        var guard_probe: BorrowUseGuardProbe = .{};
        const guard = BorrowUseGuardOps{
            .context = &guard_probe,
            .context_len = @sizeOf(BorrowUseGuardProbe),
            .current = BorrowUseGuardProbe.current,
        };
        var seed: WouldBlockSeed = .{};
        var permit: BorrowUsePermit = .{};
        try std.testing.expect(beginStoppedUse(
            scratch,
            &receipt,
            &borrow,
            &guard,
            &seed,
            &permit,
        ));
        try std.testing.expect(mintBorrowedWouldBlockSeed(
            scratch,
            &receipt,
            &borrow,
            &permit,
            &seed,
        ));
        const canonical_seed = seed;
        const scratch_digest = scratch.digest;
        const permit_digest = permit.digest;
        guard_probe.seed = &seed;
        guard_probe.seed_mutation = mutation;
        try std.testing.expect(
            consumeWouldBlockSeed(scratch, &permit, &seed) == null,
        );
        try std.testing.expectEqual(
            BorrowUseLifecycle.active,
            permit.lifecycle,
        );
        try std.testing.expectEqualSlices(
            u8,
            &scratch_digest,
            &scratch.digest,
        );
        try std.testing.expectEqualSlices(
            u8,
            &permit_digest,
            &permit.digest,
        );
        try std.testing.expectEqual(
            ReadScratchTeardownResult.busy,
            teardown(scratch),
        );

        // Detected callback corruption is never blessed. The caller-owned hostile fixture restores
        // its credential from the frozen pre-callback value before the ordinary abort cleanup.
        seed = canonical_seed;
        guard_probe.seed_mutation = null;
        try std.testing.expect(abortWouldBlockSeed(
            scratch,
            &permit,
            &seed,
        ));
        try std.testing.expect(endStoppedUse(
            scratch,
            &receipt,
            &borrow,
            &permit,
        ));
    }
}

test "C4c end revalidates receipt borrow and authorized seed after guard callback" {
    inline for (.{ "receipt", "borrow" }) |target| {
        const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var receipt: CollectReceipt = undefined;
        var borrow: StoppedBorrow = .{};
        try makeStoppedWouldBlockFixture(scratch, &receipt, &borrow);
        var guard_probe: BorrowUseGuardProbe = .{};
        const guard = BorrowUseGuardOps{
            .context = &guard_probe,
            .context_len = @sizeOf(BorrowUseGuardProbe),
            .current = BorrowUseGuardProbe.current,
        };
        var seed: WouldBlockSeed = .{};
        var permit: BorrowUsePermit = .{};
        try std.testing.expect(beginStoppedUse(
            scratch,
            &receipt,
            &borrow,
            &guard,
            &seed,
            &permit,
        ));
        try std.testing.expect(mintBorrowedWouldBlockSeed(
            scratch,
            &receipt,
            &borrow,
            &permit,
            &seed,
        ));
        try std.testing.expect(
            consumeWouldBlockSeed(scratch, &permit, &seed) != null,
        );
        const canonical_receipt = receipt;
        const canonical_borrow = borrow;
        const scratch_digest = scratch.digest;
        const permit_digest = permit.digest;
        guard_probe.receipt = &receipt;
        guard_probe.borrow = &borrow;
        if (std.mem.eql(u8, target, "receipt"))
            guard_probe.mutate_receipt = true
        else
            guard_probe.mutate_borrow = true;
        try std.testing.expect(!endStoppedUse(
            scratch,
            &receipt,
            &borrow,
            &permit,
        ));
        try std.testing.expectEqualSlices(
            u8,
            &scratch_digest,
            &scratch.digest,
        );
        try std.testing.expectEqualSlices(
            u8,
            &permit_digest,
            &permit.digest,
        );
        try std.testing.expectEqual(
            ReadScratchTeardownResult.busy,
            teardown(scratch),
        );

        receipt = canonical_receipt;
        borrow = canonical_borrow;
        guard_probe.mutate_receipt = false;
        guard_probe.mutate_borrow = false;
        try std.testing.expect(endStoppedUse(
            scratch,
            &receipt,
            &borrow,
            &permit,
        ));
    }
}

test "C4d prepared admit permit blocks stopped-use authority until pristine finish" {
    const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var receipt: CollectReceipt = undefined;
    var borrow: StoppedBorrow = .{};
    try makeStoppedWouldBlockFixture(scratch, &receipt, &borrow);
    var guard_probe: BorrowUseGuardProbe = .{};
    const guard = BorrowUseGuardOps{
        .context = &guard_probe,
        .context_len = @sizeOf(BorrowUseGuardProbe),
        .current = BorrowUseGuardProbe.current,
    };
    var seed: WouldBlockSeed = .{};
    var use_permit: BorrowUsePermit = .{};
    try std.testing.expect(beginStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &guard,
        &seed,
        &use_permit,
    ));
    var prepared_permit: PreparedAdmitUsePermit = .{};
    try std.testing.expect(beginPreparedAdmitUse(
        scratch,
        &receipt,
        &borrow,
        &use_permit,
        &seed,
        &prepared_permit,
    ));
    try std.testing.expect(!mintBorrowedWouldBlockSeed(
        scratch,
        &receipt,
        &borrow,
        &use_permit,
        &seed,
    ));
    try std.testing.expect(!endStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &use_permit,
    ));
    try std.testing.expect(!settleStopped(
        scratch,
        &receipt,
        &borrow,
        .{ .staged = .consumed, .would_block = .consumed },
    ));
    try std.testing.expectEqual(
        ReadScratchTeardownResult.busy,
        teardown(scratch),
    );
    scratch.prepared_admit.expected_start = 1;
    try std.testing.expect(!finishPreparedAdmitUse(
        scratch,
        &receipt,
        &borrow,
        &use_permit,
        &seed,
        &prepared_permit,
    ));
    scratch.prepared_admit = .{};
    try std.testing.expect(finishPreparedAdmitUse(
        scratch,
        &receipt,
        &borrow,
        &use_permit,
        &seed,
        &prepared_permit,
    ));
    try std.testing.expect(!finishPreparedAdmitUse(
        scratch,
        &receipt,
        &borrow,
        &use_permit,
        &seed,
        &prepared_permit,
    ));
    try std.testing.expect(mintBorrowedWouldBlockSeed(
        scratch,
        &receipt,
        &borrow,
        &use_permit,
        &seed,
    ));
}

test "C4d prepared admit finish rejects every callback-visible authority drift" {
    inline for (std.meta.tags(PreparedUseGuardMutation)) |mutation| {
        const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var receipt: CollectReceipt = undefined;
        var borrow: StoppedBorrow = .{};
        try makeStoppedWouldBlockFixture(scratch, &receipt, &borrow);
        var guard_probe: BorrowUseGuardProbe = .{};
        const guard = BorrowUseGuardOps{
            .context = &guard_probe,
            .context_len = @sizeOf(BorrowUseGuardProbe),
            .current = BorrowUseGuardProbe.current,
        };
        var seed: WouldBlockSeed = .{};
        var use_permit: BorrowUsePermit = .{};
        try std.testing.expect(beginStoppedUse(
            scratch,
            &receipt,
            &borrow,
            &guard,
            &seed,
            &use_permit,
        ));
        var prepared_permit: PreparedAdmitUsePermit = .{};
        try std.testing.expect(beginPreparedAdmitUse(
            scratch,
            &receipt,
            &borrow,
            &use_permit,
            &seed,
            &prepared_permit,
        ));
        const frozen_receipt = receipt;
        const frozen_borrow = borrow;
        const frozen_use_permit = use_permit;
        const frozen_seed = seed;
        const frozen_token = prepared_permit;
        const frozen_staged_len = scratch.staged_len;
        guard_probe.scratch = scratch;
        guard_probe.receipt = &receipt;
        guard_probe.borrow = &borrow;
        guard_probe.use_permit = &use_permit;
        guard_probe.seed = &seed;
        guard_probe.prepared_token = &prepared_permit;
        guard_probe.prepared_mutation = mutation;
        try std.testing.expect(!finishPreparedAdmitUse(
            scratch,
            &receipt,
            &borrow,
            &use_permit,
            &seed,
            &prepared_permit,
        ));
        try std.testing.expectEqual(
            ReadScratchTeardownResult.busy,
            teardown(scratch),
        );

        receipt = frozen_receipt;
        borrow = frozen_borrow;
        use_permit = frozen_use_permit;
        seed = frozen_seed;
        prepared_permit = frozen_token;
        scratch.staged_len = frozen_staged_len;
        scratch.prepared_admit = .{};
        guard_probe.prepared_mutation = null;
        try std.testing.expect(finishPreparedAdmitUse(
            scratch,
            &receipt,
            &borrow,
            &use_permit,
            &seed,
            &prepared_permit,
        ));
    }
}

test "C4d prepared admit permit rejects alias overflow copy and stale credentials" {
    const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var receipt: CollectReceipt = undefined;
    var borrow: StoppedBorrow = .{};
    try makeStoppedWouldBlockFixture(scratch, &receipt, &borrow);
    var guard_probe: BorrowUseGuardProbe = .{};
    const guard = BorrowUseGuardOps{
        .context = &guard_probe,
        .context_len = @sizeOf(BorrowUseGuardProbe),
        .current = BorrowUseGuardProbe.current,
    };
    var seed: WouldBlockSeed = .{};
    var use_permit: BorrowUsePermit = .{};
    try std.testing.expect(beginStoppedUse(
        scratch,
        &receipt,
        &borrow,
        &guard,
        &seed,
        &use_permit,
    ));
    const alias: *PreparedAdmitUsePermit = @ptrCast(@alignCast(&use_permit));
    try std.testing.expect(!beginPreparedAdmitUse(
        scratch,
        &receipt,
        &borrow,
        &use_permit,
        &seed,
        alias,
    ));
    const overflow_addr = std.math.maxInt(usize) &
        ~(@as(usize, @alignOf(PreparedAdmitUsePermit)) - 1);
    const overflow: *PreparedAdmitUsePermit = @ptrFromInt(overflow_addr);
    try std.testing.expect(!beginPreparedAdmitUse(
        scratch,
        &receipt,
        &borrow,
        &use_permit,
        &seed,
        overflow,
    ));
    var prepared_permit: PreparedAdmitUsePermit = .{};
    try std.testing.expect(beginPreparedAdmitUse(
        scratch,
        &receipt,
        &borrow,
        &use_permit,
        &seed,
        &prepared_permit,
    ));
    var copied = prepared_permit;
    try std.testing.expect(!finishPreparedAdmitUse(
        scratch,
        &receipt,
        &borrow,
        &use_permit,
        &seed,
        &copied,
    ));
    const canonical = prepared_permit;
    prepared_permit.scratch_generation +%= 1;
    try std.testing.expect(!finishPreparedAdmitUse(
        scratch,
        &receipt,
        &borrow,
        &use_permit,
        &seed,
        &prepared_permit,
    ));
    prepared_permit = canonical;
    try std.testing.expect(finishPreparedAdmitUse(
        scratch,
        &receipt,
        &borrow,
        &use_permit,
        &seed,
        &prepared_permit,
    ));
}

test "C4d finished prepared admit reset rejects every noncanonical authority" {
    const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var receipt: CollectReceipt = undefined;
    var borrow: StoppedBorrow = .{};
    var guard_probe: BorrowUseGuardProbe = .{};
    var seed: WouldBlockSeed = .{};
    var use_permit: BorrowUsePermit = .{};
    var prepared_permit: PreparedAdmitUsePermit = .{};
    try makeFinishedPreparedUseFixture(
        scratch,
        &receipt,
        &borrow,
        &guard_probe,
        &seed,
        &use_permit,
        &prepared_permit,
    );
    const canonical_permit = prepared_permit;
    const canonical_scratch = scratch.*;

    var copied = prepared_permit;
    try std.testing.expect(!resetFinishedPreparedAdmitUse(
        scratch,
        &copied,
    ));
    prepared_permit.digest[0] +%= 1;
    try std.testing.expect(!resetFinishedPreparedAdmitUse(
        scratch,
        &prepared_permit,
    ));
    prepared_permit = canonical_permit;
    prepared_permit.scratch_generation +%= 1;
    prepared_permit.digest = preparedAdmitUsePermitDigest(&prepared_permit);
    try std.testing.expect(!resetFinishedPreparedAdmitUse(
        scratch,
        &prepared_permit,
    ));
    prepared_permit = canonical_permit;

    scratch.active_prepared_use_permit_addr = @intFromPtr(&prepared_permit);
    scratch.active_prepared_use_permit_digest = prepared_permit.digest;
    scratch.digest = scratchDigest(scratch);
    try std.testing.expect(!resetFinishedPreparedAdmitUse(
        scratch,
        &prepared_permit,
    ));
    scratch.* = canonical_scratch;
    scratch.prepared_admit.expected_start = 1;
    scratch.digest = scratchDigest(scratch);
    try std.testing.expect(!resetFinishedPreparedAdmitUse(
        scratch,
        &prepared_permit,
    ));
    scratch.* = canonical_scratch;

    const other = try std.testing.allocator.create(ExternalRxReadScratch);
    defer std.testing.allocator.destroy(other);
    other.* = .{};
    try std.testing.expect(ExternalRxReadScratch.initInPlace(other));
    try std.testing.expect(!resetFinishedPreparedAdmitUse(
        other,
        &prepared_permit,
    ));
    const alias: *PreparedAdmitUsePermit = @ptrCast(@alignCast(scratch));
    try std.testing.expect(!resetFinishedPreparedAdmitUse(scratch, alias));
    const overflow_addr = std.math.maxInt(usize) &
        ~(@as(usize, @alignOf(PreparedAdmitUsePermit)) - 1);
    const overflow: *PreparedAdmitUsePermit = @ptrFromInt(overflow_addr);
    try std.testing.expect(!resetFinishedPreparedAdmitUse(
        scratch,
        overflow,
    ));

    try std.testing.expect(resetFinishedPreparedAdmitUse(
        scratch,
        &prepared_permit,
    ));
    try std.testing.expectEqual(@as(usize, 0), prepared_permit.saved_self_addr);
    try std.testing.expectEqual(
        PreparedAdmitUseLifecycle.empty,
        prepared_permit.lifecycle,
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        &prepared_permit.digest,
        0,
    ));
    try std.testing.expect(!resetFinishedPreparedAdmitUse(
        scratch,
        &prepared_permit,
    ));
}
