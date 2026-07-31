//! Bounded external-pump TX admission transaction.
//!
//! This module owns wire admission mechanics only. The nested external-mode state remains the
//! queue/counter/allocator owner, while `ExternalPumpStorage` remains the request-ID owner. The
//! caller serializes this transaction with the same whole-operation lease used by the pump.

const std = @import("std");
const builtin = @import("builtin");
const client_external_mode = @import("client_external_mode.zig");
const client_pump = @import("client_pump.zig");
const external_owner_seal = @import("external_owner_seal.zig");
const protocol = @import("protocol.zig");

pub const max_resident_bytes: usize =
    protocol.max_binary_chunk + protocol.header_size;

pub const RequestPolicy = enum {
    zero,
    reserve,
};

pub const AdmissionSpec = struct {
    kind: protocol.Kind,
    stream_id: u64,
    flags: u32 = 0,
    payload: []const u8,
    request_policy: RequestPolicy,
};

pub const OwnerBinding = struct {
    purpose: OwnerPurpose,
    storage_addr: usize,
    storage_len: usize,
    client_addr: usize,
    client_len: usize,
    lease_addr: usize,
    lease_len: usize,
    scratch_addr: usize,
    scratch_len: usize,
    write_scratch_addr: usize,
    write_scratch_len: usize,
    allocator_ptr_addr: usize,
    allocator_context_len: usize,
    allocator_vtable_addr: usize,
    owner_incarnation: u64,
    operation_generation: u64,
};

pub const OwnerPurpose = enum {
    admission,
    write_turn,
    cancel_turn,
};

pub const OwnerValidator = *const fn (
    context: *const anyopaque,
    binding: OwnerBinding,
) bool;

pub const Admitted = struct {
    request_id: u64,
    wire_len: usize,
};

pub const AdmissionResult = union(enum) {
    admitted: Admitted,
    backpressure,
    busy,
    terminal: client_pump.TerminalReason,
};

pub const max_turn_write_bytes: usize = protocol.max_binary_chunk;
pub const absolute_timeout_ns: i128 = 30 * std.time.ns_per_s;
pub const progress_timeout_ns: i128 = 10 * std.time.ns_per_s;

pub const WriteOutcome = union(enum) {
    written: usize,
    would_block,
    interrupted,
    zero,
    socket_error,
};

pub const WriteOps = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, bytes: []const u8) WriteOutcome,
};

pub const TxCompletion = struct {
    kind: protocol.Kind,
    stream_id: u64,
    request_id: u64,
    wire_len: usize,
};

pub const CompletionSink = struct {
    context: *anyopaque,
    consume: *const fn (
        context: *anyopaque,
        completions: []const TxCompletion,
        semantic_allowed: bool,
    ) bool,
};

const CompletionLifecycle = enum {
    empty,
    collecting,
    consuming,
    spent,
    terminal_tombstone,
};

const CompletionStorage = struct {
    saved_self_addr: usize = 0,
    owner_incarnation: u64 = 0,
    operation_generation: u64 = 0,
    lifecycle: CompletionLifecycle = .empty,
    count: usize = 0,
    completions: [client_external_mode.max_tx_frames]TxCompletion = undefined,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const PreparedTxWrite = struct {
    bytes: [@sizeOf(CompletionStorage)]u8 align(@alignOf(CompletionStorage)) =
        [_]u8{0} ** @sizeOf(CompletionStorage),

    fn storage(self: *PreparedTxWrite) *CompletionStorage {
        return @ptrCast(@alignCast(&self.bytes));
    }
};

pub const WriteResult = struct {
    terminal: ?client_pump.TerminalReason = null,
    accepted_bytes: usize = 0,
    completed_frames: usize = 0,
    would_block: bool = false,
    immediate_tx: bool = false,
};

pub const TxPollHint = struct {
    deadline_ns: ?i128 = null,
    immediate: bool = false,
    valid: bool = true,
};

pub const RequestFrameProgress = enum {
    queued,
    partial,
    missing,
    invalid,
};

/// Reads only a sealed live queue descriptor. Completion remains owned by the retirement sink;
/// this projection distinguishes offset zero from a partially accepted control frame for f3.
pub fn requestFrameProgress(
    state: *const client_external_mode.State,
    request_id: u64,
    wire_len: usize,
) RequestFrameProgress {
    if (request_id == 0 or wire_len == 0 or queueDigest(state) == null)
        return .invalid;
    var match: ?RequestFrameProgress = null;
    for (state.external_tx.items) |frame| {
        if (frame.request_id != request_id) continue;
        if (match != null or frame.kind != .request or frame.stream_id != 0 or
            frame.bytes.len != wire_len or frame.offset >= frame.bytes.len)
            return .invalid;
        match = if (frame.offset == 0) .queued else .partial;
    }
    return match orelse .missing;
}

pub const CancellationControl = struct {
    request_id: u64,
    wire_len: usize,
};

pub const CancellationSpec = struct {
    stream_id: u64,
    control: ?CancellationControl = null,
};

pub const CancellationPrepareResult = enum {
    prepared,
    uncancellable,
    invalid,
};

const CancellationLifecycle = enum { empty, prepared, armed, committed, tombstone };

const CancellationSnapshot = struct {
    saved_self_addr: usize = 0,
    state_addr: usize = 0,
    permit_addr: usize = 0,
    cleanup_addr: usize = 0,
    binding: OwnerBinding = undefined,
    spec: CancellationSpec = .{ .stream_id = 0 },
    queue_generation: u64 = 0,
    queue_address: usize = 0,
    queue_capacity: usize = 0,
    queue_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    queue_len: usize = 0,
    queued_bytes: usize = 0,
    cancelled_bytes: usize = 0,
    cancelled_count: usize = 0,
    projected_queue_generation: u64 = 0,
    projected_queued_bytes: usize = 0,
    projected_head_progress_ns: ?i128 = null,
    projected_immediate_pending: bool = false,
    projected_queue_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    cancel_mask: [client_external_mode.max_tx_frames]bool =
        [_]bool{false} ** client_external_mode.max_tx_frames,
    frames: [client_external_mode.max_tx_frames]FrameScalarSnapshot = undefined,
    lifecycle: CancellationLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const PreparedTxCancellation = struct {
    bytes: [@sizeOf(CancellationSnapshot)]u8 align(@alignOf(CancellationSnapshot)) =
        [_]u8{0} ** @sizeOf(CancellationSnapshot),

    fn storage(self: *PreparedTxCancellation) *CancellationSnapshot {
        return @ptrCast(@alignCast(&self.bytes));
    }
};

const CancellationPermitStorage = struct {
    saved_self_addr: usize = 0,
    prepared_addr: usize = 0,
    cleanup_addr: usize = 0,
    state_addr: usize = 0,
    queue_generation: u64 = 0,
    owner_incarnation: u64 = 0,
    operation_generation: u64 = 0,
    lifecycle: enum { empty, armed, consumed, aborted } = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const TxCancellationCommitPermit = struct {
    bytes: [@sizeOf(CancellationPermitStorage)]u8 align(@alignOf(CancellationPermitStorage)) =
        [_]u8{0} ** @sizeOf(CancellationPermitStorage),

    fn storage(self: *TxCancellationCommitPermit) *CancellationPermitStorage {
        return @ptrCast(@alignCast(&self.bytes));
    }
};

const CancellationCleanupStorage = struct {
    saved_self_addr: usize = 0,
    state_addr: usize = 0,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    binding: OwnerBinding = undefined,
    binding_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    count: usize = 0,
    total_bytes: usize = 0,
    post_queue_generation: u64 = 0,
    post_queued_bytes: usize = 0,
    post_queue_digest: external_owner_seal.Digest = [_]u8{0} ** 32,
    frames: [client_external_mode.max_tx_frames]client_external_mode.ExternalTxFrame = undefined,
    lifecycle: enum { empty, owned, cleaned, quarantined } = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const FrozenTxCancellationCleanup = struct {
    bytes: [@sizeOf(CancellationCleanupStorage)]u8 align(@alignOf(CancellationCleanupStorage)) =
        [_]u8{0} ** @sizeOf(CancellationCleanupStorage),

    fn storage(self: *FrozenTxCancellationCleanup) *CancellationCleanupStorage {
        return @ptrCast(@alignCast(&self.bytes));
    }
};

const WriteSnapshot = struct {
    queue_address: usize,
    queue_len: usize,
    queue_capacity: usize,
    queue_generation: u64,
    queue_digest: external_owner_seal.Digest,
    queued_bytes: usize,
    retiring_bytes: usize,
    head_progress_ns: ?i128,
    immediate_pending: bool,
    frame_scalars: [client_external_mode.max_tx_frames]FrameScalarSnapshot,
    frame_scalar_count: usize,
};

const FrameScalarSnapshot = struct {
    bytes_addr: usize,
    bytes_len: usize,
    offset: usize,
    kind: protocol.Kind,
    stream_id: u64,
    request_id: u64,
    activated_at_ns: i128,
    wire_digest: external_owner_seal.Digest,
    descriptor_digest: external_owner_seal.Digest,
};

const Range = struct {
    address: usize,
    len: usize,
};

const CancellationRanges = struct {
    storage: Range,
    client: Range,
    lease: Range,
    scratch: Range,
    write_scratch: Range,
    allocator_context: Range,
    allocator_vtable: Range,
    queue_backing: Range,
    prepared: Range,
    permit: Range,
    cleanup: Range,
};

const AdmissionSnapshot = struct {
    queue_address: usize,
    queue_len: usize,
    queue_capacity: usize,
    queue_generation: u64,
    queue_digest: external_owner_seal.Digest,
    queued_bytes: usize,
    retiring_bytes: usize,
    quarantined_bytes: usize,
    head_progress_ns: ?i128,
    last_observed_ns: ?i128,
    immediate_pending: bool,
    request_state: client_pump.RequestIdState,
    payload_address: usize,
    payload_len: usize,
    payload_digest: external_owner_seal.Digest,
    binding: OwnerBinding,
    frame_ranges: [client_external_mode.max_tx_frames]Range,
    frame_range_count: usize,
};

const PreparedLifecycle = enum { empty, prepared, cleanup_tombstone, committed };

const PreparedStorage = struct {
    lifecycle: PreparedLifecycle = .empty,
    snapshot: ?AdmissionSnapshot = null,
};

pub const PreparedTxAdmission = struct {
    bytes: [@sizeOf(PreparedStorage)]u8 align(@alignOf(PreparedStorage)) =
        [_]u8{0} ** @sizeOf(PreparedStorage),

    fn storage(self: *PreparedTxAdmission) *PreparedStorage {
        return @ptrCast(@alignCast(&self.bytes));
    }
};

fn bytesDigest(domain: []const u8, bytes: []const u8) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init(domain);
    writer.writeBytes(bytes);
    return writer.finish();
}

threadlocal var offered_digest_bytes_for_test: usize = 0;
threadlocal var queue_digest_bytes_for_test: usize = 0;
threadlocal var admission_copy_bytes_for_test: usize = 0;

fn offeredBytesDigest(bytes: []const u8) external_owner_seal.Digest {
    if (builtin.is_test)
        offered_digest_bytes_for_test = std.math.add(
            usize,
            offered_digest_bytes_for_test,
            bytes.len,
        ) catch @panic("test offered digest byte counter exhausted");
    return bytesDigest("MARUTXO1", bytes);
}

fn frameDescriptorDigest(
    frame: client_external_mode.ExternalTxFrame,
) external_owner_seal.Digest {
    return client_external_mode.txFrameDescriptorDigest(frame);
}

fn queueDigest(
    state: *const client_external_mode.State,
) ?external_owner_seal.Digest {
    if (state.tx_lifecycle != .live or
        state.tx_queue_backing_addr == 0 or
        state.tx_queue_backing_capacity != client_external_mode.max_tx_frames or
        state.external_tx.capacity != state.tx_queue_backing_capacity or
        @intFromPtr(state.external_tx.items.ptr) !=
            state.tx_queue_backing_addr or
        state.external_tx.items.len > state.external_tx.capacity or
        state.external_tx.capacity != client_external_mode.max_tx_frames or
        state.external_tx_retiring_bytes != 0 or
        state.external_tx_quarantined_bytes != 0 or
        state.tx_queue_generation == 0 or
        state.tx_queue_generation == std.math.maxInt(u64))
        return null;
    if ((state.external_tx.items.len == 0) !=
        (state.tx_head_progress_baseline_ns == null))
        return null;

    var total: usize = 0;
    var writer = external_owner_seal.Writer.init("MARUTXQ1");
    writer.writeUsize(if (state.external_tx.capacity == 0)
        0
    else
        @intFromPtr(state.external_tx.items.ptr));
    writer.writeUsize(state.external_tx.items.len);
    writer.writeUsize(state.external_tx.capacity);
    writer.writeU64(state.tx_queue_generation);
    for (state.external_tx.items) |frame| {
        if (frame.bytes.len < protocol.header_size or
            frame.bytes.len > max_resident_bytes or
            frame.offset > frame.bytes.len or
            !std.mem.eql(
                u8,
                &frame.wire_digest,
                &bytesDigest("MARUTXW1", frame.bytes),
            ) or
            !std.mem.eql(
                u8,
                &frame.descriptor_digest,
                &frameDescriptorDigest(frame),
            ))
            return null;
        if (builtin.is_test)
            queue_digest_bytes_for_test = std.math.add(
                usize,
                queue_digest_bytes_for_test,
                frame.bytes.len,
            ) catch @panic("test queue digest byte counter exhausted");
        total = std.math.add(usize, total, frame.bytes.len) catch return null;
        writer.writeBytes(&frame.descriptor_digest);
    }
    if (total != state.external_tx_bytes or total > max_resident_bytes)
        return null;
    writer.writeUsize(total);
    return writer.finish();
}

/// Callback-bound queue seal. The turn-entry `queueDigest` validates every immutable wire byte
/// once; subsequent syscall boundaries seal descriptor scalars and hash only the slice actually
/// exposed to that callback, avoiding an O(queue bytes × short writes) rehash.
fn queueDescriptorDigest(
    state: *const client_external_mode.State,
) ?external_owner_seal.Digest {
    if (state.tx_lifecycle != .live or
        state.tx_queue_backing_addr == 0 or
        state.tx_queue_backing_capacity != client_external_mode.max_tx_frames or
        state.external_tx.capacity != state.tx_queue_backing_capacity or
        @intFromPtr(state.external_tx.items.ptr) !=
            state.tx_queue_backing_addr or
        state.external_tx.items.len > state.external_tx.capacity or
        state.external_tx_retiring_bytes != 0 or
        state.external_tx_quarantined_bytes != 0 or
        state.tx_queue_generation == 0 or
        state.tx_queue_generation == std.math.maxInt(u64))
        return null;
    var total: usize = 0;
    var writer = external_owner_seal.Writer.init("MARUTQD1");
    writer.writeUsize(@intFromPtr(state.external_tx.items.ptr));
    writer.writeUsize(state.external_tx.items.len);
    writer.writeUsize(state.external_tx.capacity);
    writer.writeU64(state.tx_queue_generation);
    for (state.external_tx.items) |frame| {
        if (frame.bytes.len < protocol.header_size or
            frame.bytes.len > max_resident_bytes or
            frame.offset > frame.bytes.len or
            !std.mem.eql(
                u8,
                &frame.descriptor_digest,
                &frameDescriptorDigest(frame),
            ))
            return null;
        total = std.math.add(usize, total, frame.bytes.len) catch return null;
        writer.writeBytes(&frame.wire_digest);
        writer.writeBytes(&frame.descriptor_digest);
    }
    if (total != state.external_tx_bytes or total > max_resident_bytes)
        return null;
    writer.writeUsize(total);
    return writer.finish();
}

fn addressRange(address: usize, len: usize) ?Range {
    if (address == 0 or len == 0) return null;
    _ = std.math.add(usize, address, len) catch return null;
    return .{ .address = address, .len = len };
}

fn sliceRange(bytes: []const u8) ?Range {
    if (bytes.len == 0) return null;
    return addressRange(@intFromPtr(bytes.ptr), bytes.len);
}

fn rangesOverlap(a: Range, b: Range) bool {
    const a_end = a.address + a.len;
    const b_end = b.address + b.len;
    return a.address < b_end and b.address < a_end;
}

fn checkedCancellationRanges(
    state: *const client_external_mode.State,
    binding: OwnerBinding,
    prepared_addr: usize,
    permit_addr: usize,
    cleanup_addr: usize,
) ?CancellationRanges {
    const queue_bytes = std.math.mul(
        usize,
        state.external_tx.capacity,
        @sizeOf(client_external_mode.ExternalTxFrame),
    ) catch return null;
    return .{
        .storage = addressRange(binding.storage_addr, binding.storage_len) orelse return null,
        .client = addressRange(binding.client_addr, binding.client_len) orelse return null,
        .lease = addressRange(binding.lease_addr, binding.lease_len) orelse return null,
        .scratch = addressRange(binding.scratch_addr, binding.scratch_len) orelse return null,
        .write_scratch = addressRange(binding.write_scratch_addr, binding.write_scratch_len) orelse return null,
        .allocator_context = addressRange(binding.allocator_ptr_addr, binding.allocator_context_len) orelse return null,
        .allocator_vtable = addressRange(binding.allocator_vtable_addr, @sizeOf(std.mem.Allocator.VTable)) orelse return null,
        .queue_backing = addressRange(@intFromPtr(state.external_tx.items.ptr), queue_bytes) orelse return null,
        .prepared = addressRange(prepared_addr, @sizeOf(PreparedTxCancellation)) orelse return null,
        .permit = addressRange(permit_addr, @sizeOf(TxCancellationCommitPermit)) orelse return null,
        .cleanup = addressRange(cleanup_addr, @sizeOf(FrozenTxCancellationCleanup)) orelse return null,
    };
}

fn cancellationSnapshotDigest(snapshot: *const CancellationSnapshot) ?external_owner_seal.Digest {
    if (snapshot.queue_len > client_external_mode.max_tx_frames or
        snapshot.cancelled_count > snapshot.queue_len or
        snapshot.queued_bytes > max_resident_bytes or
        snapshot.cancelled_bytes > snapshot.queued_bytes or
        snapshot.projected_queued_bytes > snapshot.queued_bytes)
        return null;
    var writer = external_owner_seal.Writer.init("MARUTXK1");
    writer.writeUsize(snapshot.saved_self_addr);
    writer.writeUsize(snapshot.state_addr);
    writer.writeUsize(snapshot.permit_addr);
    writer.writeUsize(snapshot.cleanup_addr);
    writer.writeU64(snapshot.binding.owner_incarnation);
    writer.writeU64(snapshot.binding.operation_generation);
    writer.writeU64(snapshot.spec.stream_id);
    if (snapshot.spec.control) |control| {
        writer.writeU8(1);
        writer.writeU64(control.request_id);
        writer.writeUsize(control.wire_len);
    } else writer.writeU8(0);
    writer.writeU64(snapshot.queue_generation);
    writer.writeUsize(snapshot.queue_address);
    writer.writeUsize(snapshot.queue_capacity);
    writer.writeBytes(&snapshot.queue_digest);
    writer.writeUsize(snapshot.queue_len);
    writer.writeUsize(snapshot.queued_bytes);
    writer.writeUsize(snapshot.cancelled_bytes);
    writer.writeUsize(snapshot.cancelled_count);
    writer.writeU64(snapshot.projected_queue_generation);
    writer.writeUsize(snapshot.projected_queued_bytes);
    writer.writeU128(@bitCast(snapshot.projected_head_progress_ns orelse std.math.minInt(i128)));
    writer.writeU8(@intFromBool(snapshot.projected_immediate_pending));
    writer.writeBytes(&snapshot.projected_queue_digest);
    writer.writeU8(@intFromEnum(snapshot.lifecycle));
    for (0..snapshot.queue_len) |index| {
        writer.writeU8(@intFromBool(snapshot.cancel_mask[index]));
        const frame = snapshot.frames[index];
        writer.writeUsize(frame.bytes_addr);
        writer.writeUsize(frame.bytes_len);
        writer.writeUsize(frame.offset);
        writer.writeU16(@intFromEnum(frame.kind));
        writer.writeU64(frame.stream_id);
        writer.writeU64(frame.request_id);
        writer.writeU128(@bitCast(frame.activated_at_ns));
        writer.writeBytes(&frame.wire_digest);
        writer.writeBytes(&frame.descriptor_digest);
    }
    return writer.finish();
}

fn cancellationPermitDigest(permit: *const CancellationPermitStorage) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUTXKP");
    writer.writeUsize(permit.saved_self_addr);
    writer.writeUsize(permit.prepared_addr);
    writer.writeUsize(permit.cleanup_addr);
    writer.writeUsize(permit.state_addr);
    writer.writeU64(permit.queue_generation);
    writer.writeU64(permit.owner_incarnation);
    writer.writeU64(permit.operation_generation);
    writer.writeU8(@intFromEnum(permit.lifecycle));
    return writer.finish();
}

fn cancellationCleanupDigest(cleanup: *const CancellationCleanupStorage) ?external_owner_seal.Digest {
    if (cleanup.count > client_external_mode.max_tx_frames or
        cleanup.total_bytes > max_resident_bytes or
        cleanup.post_queued_bytes > max_resident_bytes)
        return null;
    var writer = external_owner_seal.Writer.init("MARUTXKC");
    writer.writeUsize(cleanup.saved_self_addr);
    writer.writeUsize(cleanup.state_addr);
    writer.writeUsize(cleanup.allocator_ptr_addr);
    writer.writeUsize(cleanup.allocator_vtable_addr);
    writer.writeBytes(&cleanup.binding_digest);
    writer.writeUsize(cleanup.count);
    writer.writeUsize(cleanup.total_bytes);
    writer.writeU64(cleanup.post_queue_generation);
    writer.writeUsize(cleanup.post_queued_bytes);
    writer.writeBytes(&cleanup.post_queue_digest);
    writer.writeU8(@intFromEnum(cleanup.lifecycle));
    for (cleanup.frames[0..cleanup.count]) |frame|
        writer.writeBytes(&frame.descriptor_digest);
    return writer.finish();
}

fn ownerBindingDigest(binding: OwnerBinding) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUTXOB");
    writer.writeU8(@intFromEnum(binding.purpose));
    writer.writeUsize(binding.storage_addr);
    writer.writeUsize(binding.storage_len);
    writer.writeUsize(binding.client_addr);
    writer.writeUsize(binding.client_len);
    writer.writeUsize(binding.lease_addr);
    writer.writeUsize(binding.lease_len);
    writer.writeUsize(binding.scratch_addr);
    writer.writeUsize(binding.scratch_len);
    writer.writeUsize(binding.write_scratch_addr);
    writer.writeUsize(binding.write_scratch_len);
    writer.writeUsize(binding.allocator_ptr_addr);
    writer.writeUsize(binding.allocator_context_len);
    writer.writeUsize(binding.allocator_vtable_addr);
    writer.writeU64(binding.owner_incarnation);
    writer.writeU64(binding.operation_generation);
    return writer.finish();
}

fn cancellationSpecCanonical(spec: CancellationSpec) bool {
    if (spec.stream_id == 0) return false;
    if (spec.control) |control|
        return control.request_id != 0 and control.wire_len >= protocol.header_size and
            control.wire_len <= max_resident_bytes;
    return true;
}

fn projectedCancellationQueueDigest(
    snapshot: *const CancellationSnapshot,
) ?external_owner_seal.Digest {
    if (snapshot.queue_len > client_external_mode.max_tx_frames or
        snapshot.cancelled_count > snapshot.queue_len or
        snapshot.projected_queued_bytes > max_resident_bytes)
        return null;
    var total: usize = 0;
    var actual = external_owner_seal.Writer.init("MARUTXQ1");
    actual.writeUsize(snapshot.queue_address);
    actual.writeUsize(snapshot.queue_len - snapshot.cancelled_count);
    actual.writeUsize(snapshot.queue_capacity);
    actual.writeU64(snapshot.projected_queue_generation);
    for (snapshot.frames[0..snapshot.queue_len], 0..) |frame, index| {
        if (snapshot.cancel_mask[index]) continue;
        total = std.math.add(usize, total, frame.bytes_len) catch return null;
        actual.writeBytes(&frame.descriptor_digest);
    }
    if (total != snapshot.projected_queued_bytes or total > max_resident_bytes) return null;
    actual.writeUsize(total);
    return actual.finish();
}

fn frameMatchesScalar(frame: client_external_mode.ExternalTxFrame, scalar: FrameScalarSnapshot) bool {
    return scalar.bytes_addr == @intFromPtr(frame.bytes.ptr) and
        scalar.bytes_len == frame.bytes.len and scalar.offset == frame.offset and
        scalar.kind == frame.kind and scalar.stream_id == frame.stream_id and
        scalar.request_id == frame.request_id and
        scalar.activated_at_ns == frame.activated_at_ns and
        std.mem.eql(u8, &scalar.wire_digest, &frame.wire_digest) and
        std.mem.eql(u8, &scalar.descriptor_digest, &frame.descriptor_digest);
}

fn cancellationFrameWireHeaderMatches(
    frame: client_external_mode.ExternalTxFrame,
) bool {
    if (frame.bytes.len < protocol.header_size or frame.bytes.len > max_resident_bytes)
        return false;
    const header_bytes: *const [protocol.header_size]u8 = @ptrCast(frame.bytes.ptr);
    const header = protocol.Header.decode(header_bytes) catch return false;
    const expected_wire_len = std.math.add(
        usize,
        protocol.header_size,
        @as(usize, header.payload_len),
    ) catch return false;
    return header.major == protocol.version_major and
        header.kind == frame.kind and
        header.flags == 0 and
        header.request_id == frame.request_id and
        header.stream_id == frame.stream_id and
        expected_wire_len == frame.bytes.len and
        header.payload_len <= protocol.maxPayloadForKind(header.kind);
}

fn cancellationQueueAliasesProtected(
    state: *const client_external_mode.State,
    binding: OwnerBinding,
    prepared: *const PreparedTxCancellation,
    permit: *const TxCancellationCommitPermit,
    cleanup: *const FrozenTxCancellationCleanup,
) bool {
    const ranges = checkedCancellationRanges(
        state,
        binding,
        @intFromPtr(prepared),
        @intFromPtr(permit),
        @intFromPtr(cleanup),
    ) orelse return true;
    if (rangesOverlap(ranges.prepared, ranges.permit) or
        rangesOverlap(ranges.prepared, ranges.cleanup) or
        rangesOverlap(ranges.permit, ranges.cleanup)) return true;
    const scratch_ranges = [_]Range{ ranges.prepared, ranges.permit, ranges.cleanup };
    const owner_protected = [_]Range{
        ranges.storage,
        ranges.client,
        ranges.lease,
        ranges.allocator_context,
        ranges.allocator_vtable,
        ranges.queue_backing,
    };
    for (scratch_ranges) |scratch_range|
        for (owner_protected) |item|
            if (rangesOverlap(scratch_range, item)) return true;
    const protected = [_]Range{
        ranges.storage,
        ranges.client,
        ranges.lease,
        ranges.scratch,
        ranges.write_scratch,
        ranges.allocator_context,
        ranges.allocator_vtable,
        ranges.prepared,
        ranges.permit,
        ranges.cleanup,
        ranges.queue_backing,
    };
    for (state.external_tx.items, 0..) |frame, index| {
        const range = sliceRange(frame.bytes) orelse return true;
        for (protected) |item|
            if (rangesOverlap(range, item)) return true;
        for (state.external_tx.items[0..index]) |prior| {
            const prior_range = sliceRange(prior.bytes) orelse return true;
            if (rangesOverlap(range, prior_range)) return true;
        }
    }
    return false;
}

fn candidateAliasesProtected(
    candidate: []u8,
    snapshot: AdmissionSnapshot,
    binding: OwnerBinding,
) bool {
    const candidate_range = sliceRange(candidate) orelse return true;
    const protected = [_]?Range{
        addressRange(binding.storage_addr, binding.storage_len),
        addressRange(binding.client_addr, binding.client_len),
        addressRange(binding.lease_addr, binding.lease_len),
        addressRange(binding.scratch_addr, binding.scratch_len),
        addressRange(binding.write_scratch_addr, binding.write_scratch_len),
        addressRange(
            binding.allocator_ptr_addr,
            binding.allocator_context_len,
        ),
        addressRange(
            binding.allocator_vtable_addr,
            @sizeOf(std.mem.Allocator.VTable),
        ),
        addressRange(
            snapshot.queue_address,
            snapshot.queue_capacity *
                @sizeOf(client_external_mode.ExternalTxFrame),
        ),
        addressRange(snapshot.payload_address, snapshot.payload_len),
    };
    for (protected) |maybe_range| {
        const protected_range = maybe_range orelse continue;
        if (rangesOverlap(candidate_range, protected_range)) return true;
    }
    for (snapshot.frame_ranges[0..snapshot.frame_range_count]) |frame_range|
        if (rangesOverlap(candidate_range, frame_range)) return true;
    return false;
}

fn specCanonical(spec: AdmissionSpec) bool {
    if (spec.flags != 0 or protocol.Flags.hasUnknownBits(spec.flags) or
        !spec.kind.isKnown() or
        spec.payload.len > protocol.maxPayloadForKind(spec.kind))
        return false;
    if (spec.kind.isControlJson() and
        !std.unicode.utf8ValidateSlice(spec.payload))
        return false;
    return switch (spec.request_policy) {
        .zero => spec.stream_id != 0 and switch (spec.kind) {
            .input_bytes, .stream_ack, .scroll_to_bottom, .core_command => true,
            else => false,
        },
        .reserve => spec.kind == .request and spec.stream_id == 0,
    };
}

fn captureSnapshot(
    state: *const client_external_mode.State,
    request_ids: client_pump.RequestIdState,
    spec: AdmissionSpec,
    binding: OwnerBinding,
) ?AdmissionSnapshot {
    const digest = queueDigest(state) orelse return null;
    var result = AdmissionSnapshot{
        .queue_address = if (state.external_tx.capacity == 0)
            0
        else
            @intFromPtr(state.external_tx.items.ptr),
        .queue_len = state.external_tx.items.len,
        .queue_capacity = state.external_tx.capacity,
        .queue_generation = state.tx_queue_generation,
        .queue_digest = digest,
        .queued_bytes = state.external_tx_bytes,
        .retiring_bytes = state.external_tx_retiring_bytes,
        .quarantined_bytes = state.external_tx_quarantined_bytes,
        .head_progress_ns = state.tx_head_progress_baseline_ns,
        .last_observed_ns = state.tx_last_observed_now_ns,
        .immediate_pending = state.tx_immediate_pending,
        .request_state = request_ids,
        .payload_address = if (spec.payload.len == 0)
            0
        else
            @intFromPtr(spec.payload.ptr),
        .payload_len = spec.payload.len,
        .payload_digest = bytesDigest("MARUTXP1", spec.payload),
        .binding = binding,
        .frame_ranges = undefined,
        .frame_range_count = state.external_tx.items.len,
    };
    for (state.external_tx.items, 0..) |frame, index|
        result.frame_ranges[index] = sliceRange(frame.bytes) orelse return null;
    return result;
}

fn snapshotScalarsMatch(
    snapshot: AdmissionSnapshot,
    state: *const client_external_mode.State,
    request_ids: client_pump.RequestIdState,
    spec: AdmissionSpec,
) bool {
    return snapshot.queue_address == (if (state.external_tx.capacity == 0)
        0
    else
        @intFromPtr(state.external_tx.items.ptr)) and
        snapshot.queue_len == state.external_tx.items.len and
        snapshot.queue_capacity == state.external_tx.capacity and
        snapshot.queue_generation == state.tx_queue_generation and
        snapshot.queued_bytes == state.external_tx_bytes and
        snapshot.retiring_bytes == state.external_tx_retiring_bytes and
        snapshot.quarantined_bytes == state.external_tx_quarantined_bytes and
        snapshot.head_progress_ns == state.tx_head_progress_baseline_ns and
        snapshot.last_observed_ns == state.tx_last_observed_now_ns and
        snapshot.immediate_pending == state.tx_immediate_pending and
        std.meta.eql(snapshot.request_state, request_ids) and
        snapshot.payload_address == (if (spec.payload.len == 0)
            0
        else
            @intFromPtr(spec.payload.ptr)) and
        snapshot.payload_len == spec.payload.len;
}

fn snapshotPointersMatch(
    snapshot: AdmissionSnapshot,
    state: *const client_external_mode.State,
    spec: AdmissionSpec,
) bool {
    return snapshot.queue_address == (if (state.external_tx.capacity == 0)
        0
    else
        @intFromPtr(state.external_tx.items.ptr)) and
        snapshot.queue_len == state.external_tx.items.len and
        snapshot.queue_capacity == state.external_tx.capacity and
        snapshot.payload_address == (if (spec.payload.len == 0)
            0
        else
            @intFromPtr(spec.payload.ptr)) and
        snapshot.payload_len == spec.payload.len and
        snapshot.binding.allocator_ptr_addr != 0 and
        snapshot.binding.allocator_vtable_addr != 0;
}

fn snapshotContentMatches(
    snapshot: AdmissionSnapshot,
    state: *const client_external_mode.State,
    spec: AdmissionSpec,
) bool {
    const current_digest = queueDigest(state) orelse return false;
    return std.mem.eql(u8, &snapshot.queue_digest, &current_digest) and
        std.mem.eql(
            u8,
            &snapshot.payload_digest,
            &bytesDigest("MARUTXP1", spec.payload),
        );
}

fn snapshotMatches(
    snapshot: AdmissionSnapshot,
    state: *const client_external_mode.State,
    request_ids: client_pump.RequestIdState,
    spec: AdmissionSpec,
) bool {
    return snapshotScalarsMatch(snapshot, state, request_ids, spec) and
        snapshotContentMatches(snapshot, state, spec);
}

fn bindingCanonical(binding: OwnerBinding) bool {
    return binding.owner_incarnation != 0 and
        binding.operation_generation != 0 and
        addressRange(binding.lease_addr, binding.lease_len) != null and
        addressRange(binding.scratch_addr, binding.scratch_len) != null and
        addressRange(
            binding.write_scratch_addr,
            binding.write_scratch_len,
        ) != null and
        addressRange(binding.allocator_ptr_addr, binding.allocator_context_len) != null and
        addressRange(binding.allocator_vtable_addr, @sizeOf(std.mem.Allocator.VTable)) != null and
        addressRange(binding.storage_addr, binding.storage_len) != null and
        addressRange(binding.client_addr, binding.client_len) != null;
}

fn quarantineCandidate(
    state: *client_external_mode.State,
    wire_len: usize,
) void {
    if (wire_len > max_resident_bytes)
        @panic("external TX quarantine charge exceeded bounded candidate");
    client_external_mode.chargeTxQuarantine(state, wire_len);
}

fn quarantineLiveQueue(
    state: *client_external_mode.State,
    queued_bytes: usize,
) void {
    if (queued_bytes != 0) quarantineCandidate(state, queued_bytes);
    // No descriptor is trusted after callback drift. Publish the nonnumeric tombstone and detach
    // the queue without dereferencing or freeing any candidate; State.deinit may still reclaim the
    // separately mirrored ArrayList backing, but the uncertain frame allocations remain bounded.
    state.tx_lifecycle = .terminal_tombstone;
    state.external_tx.items.len = 0;
    state.external_tx_bytes = 0;
    state.external_tx_retiring_bytes = 0;
    state.tx_head_progress_baseline_ns = null;
    state.tx_immediate_pending = false;
}

fn cleanupSnapshotMatches(
    snapshot: AdmissionSnapshot,
    state: *const client_external_mode.State,
    request_ids: client_pump.RequestIdState,
    spec: AdmissionSpec,
) bool {
    return snapshotPointersMatch(snapshot, state, spec) and
        snapshot.queue_generation == state.tx_queue_generation and
        snapshot.queued_bytes == state.external_tx_bytes and
        snapshot.retiring_bytes == state.external_tx_retiring_bytes and
        snapshot.quarantined_bytes == state.external_tx_quarantined_bytes and
        snapshot.head_progress_ns == state.tx_head_progress_baseline_ns and
        snapshot.last_observed_ns == state.tx_last_observed_now_ns and
        snapshot.immediate_pending == state.tx_immediate_pending and
        std.meta.eql(snapshot.request_state, request_ids) and
        snapshotContentMatches(snapshot, state, spec);
}

fn discardCandidateAfterDrift(
    allocator: std.mem.Allocator,
    candidate: []u8,
    state: *client_external_mode.State,
    request_ids: *client_pump.RequestIdState,
    binding: OwnerBinding,
    spec: AdmissionSpec,
    original: AdmissionSnapshot,
) void {
    // A scalar mismatch can make any live queue pointer untrusted. In that case the candidate is
    // bounded and quarantined without dereference or free.
    if (!snapshotPointersMatch(original, state, spec)) {
        quarantineCandidate(state, candidate.len);
        return;
    }
    // Freeze the post-callback owner graph before the cleanup callback. The candidate descriptor
    // is already local and no live queue references it.
    const cleanup_snapshot = captureSnapshot(
        state,
        request_ids.*,
        spec,
        binding,
    ) orelse {
        quarantineCandidate(state, candidate.len);
        return;
    };
    allocator.rawFree(candidate, .@"1", @returnAddress());
    if (!cleanupSnapshotMatches(cleanup_snapshot, state, request_ids.*, spec)) {
        const uncertain = std.math.add(
            usize,
            candidate.len,
            cleanup_snapshot.queued_bytes,
        ) catch @panic("external TX cleanup quarantine overflow");
        quarantineCandidate(state, uncertain);
    }
}

pub fn admitFromExternalPump(
    comptime validate_owner: OwnerValidator,
    owner_context: *const anyopaque,
    prepared: *PreparedTxAdmission,
    allocator: std.mem.Allocator,
    state: *client_external_mode.State,
    request_ids: *client_pump.RequestIdState,
    binding: OwnerBinding,
    spec: AdmissionSpec,
    now_ns: i128,
) AdmissionResult {
    const prepared_storage = prepared.storage();
    if (prepared_storage.lifecycle != .empty or
        binding.purpose != .admission or
        binding.scratch_addr != @intFromPtr(prepared) or
        binding.scratch_len != @sizeOf(PreparedTxAdmission) or
        binding.write_scratch_addr != @intFromPtr(prepared) or
        binding.write_scratch_len != @sizeOf(PreparedTxAdmission) or
        !validate_owner(owner_context, binding))
        return .{ .terminal = .invariant_failure };
    if (!bindingCanonical(binding) or
        binding.allocator_ptr_addr != @intFromPtr(allocator.ptr) or
        binding.allocator_vtable_addr != @intFromPtr(allocator.vtable) or
        binding.allocator_ptr_addr != @intFromPtr(state.tx_allocator.ptr) or
        binding.allocator_vtable_addr !=
            @intFromPtr(state.tx_allocator.vtable) or
        binding.allocator_context_len != state.tx_allocator_context_len or
        !specCanonical(spec))
        return .{ .terminal = .protocol_error };
    const queue_before_clock = queueDigest(state) orelse
        return .{ .terminal = .invariant_failure };
    _ = queue_before_clock;
    if (state.tx_last_observed_now_ns) |last| {
        if (now_ns < last) return .{ .terminal = .deadline_exceeded };
    }
    state.tx_last_observed_now_ns = now_ns;

    const wire_len = std.math.add(
        usize,
        protocol.header_size,
        spec.payload.len,
    ) catch return .{ .terminal = .protocol_error };
    const resident = std.math.add(
        usize,
        state.external_tx_bytes,
        state.external_tx_retiring_bytes,
    ) catch return .{ .terminal = .invariant_failure };
    if (state.external_tx.items.len == client_external_mode.max_tx_frames or
        wire_len > max_resident_bytes - resident)
        return .backpressure;
    if (state.external_tx.items.len >= state.external_tx.capacity or
        state.tx_queue_generation == std.math.maxInt(u64))
        return .{ .terminal = .invariant_failure };

    const prepared_request = switch (spec.request_policy) {
        .zero => null,
        .reserve => request_ids.prepare() catch |err| return .{
            .terminal = switch (err) {
                error.Exhausted => .request_id_exhausted,
                error.InvalidState => .invariant_failure,
            },
        },
    };
    const request_id = if (prepared_request) |request| request.id else 0;
    const snapshot = captureSnapshot(state, request_ids.*, spec, binding) orelse
        return .{ .terminal = .invariant_failure };
    prepared_storage.* = .{
        .lifecycle = .prepared,
        .snapshot = snapshot,
    };
    // `Allocator.alloc` poisons the returned memory in safety builds before it returns to this
    // boundary. Use the raw callback so an adversarial allocator cannot make an owner alias
    // observable as modified before the range check below.
    const candidate_ptr = allocator.rawAlloc(
        wire_len,
        .@"1",
        @returnAddress(),
    ) orelse return .{ .terminal = .resource_exhausted };
    const candidate = candidate_ptr[0..wire_len];
    if (candidateAliasesProtected(
        candidate,
        snapshot,
        binding,
    )) {
        prepared_storage.lifecycle = .cleanup_tombstone;
        quarantineCandidate(state, wire_len);
        return .{ .terminal = .invariant_failure };
    }
    if (!validate_owner(owner_context, binding) or
        !snapshotScalarsMatch(snapshot, state, request_ids.*, spec))
    {
        prepared_storage.lifecycle = .cleanup_tombstone;
        discardCandidateAfterDrift(
            allocator,
            candidate,
            state,
            request_ids,
            binding,
            spec,
            snapshot,
        );
        return .{ .terminal = .invariant_failure };
    }
    if (!snapshotContentMatches(snapshot, state, spec)) {
        prepared_storage.lifecycle = .cleanup_tombstone;
        discardCandidateAfterDrift(
            allocator,
            candidate,
            state,
            request_ids,
            binding,
            spec,
            snapshot,
        );
        return .{ .terminal = .invariant_failure };
    }

    const header = (protocol.Header{
        .kind = spec.kind,
        .flags = spec.flags,
        .request_id = request_id,
        .stream_id = spec.stream_id,
        .payload_len = @intCast(spec.payload.len),
    }).encode();
    @memcpy(candidate[0..protocol.header_size], &header);
    @memcpy(candidate[protocol.header_size..], spec.payload);
    if (builtin.is_test)
        admission_copy_bytes_for_test = std.math.add(
            usize,
            admission_copy_bytes_for_test,
            candidate.len,
        ) catch @panic("test admission copy byte counter exhausted");
    if (!validate_owner(owner_context, binding) or
        !snapshotScalarsMatch(snapshot, state, request_ids.*, spec))
    {
        prepared_storage.lifecycle = .cleanup_tombstone;
        discardCandidateAfterDrift(
            allocator,
            candidate,
            state,
            request_ids,
            binding,
            spec,
            snapshot,
        );
        return .{ .terminal = .invariant_failure };
    }
    if (!snapshotContentMatches(snapshot, state, spec)) {
        prepared_storage.lifecycle = .cleanup_tombstone;
        discardCandidateAfterDrift(
            allocator,
            candidate,
            state,
            request_ids,
            binding,
            spec,
            snapshot,
        );
        return .{ .terminal = .invariant_failure };
    }

    const wire_digest = bytesDigest("MARUTXW1", candidate);
    var frame = client_external_mode.ExternalTxFrame{
        .bytes = candidate,
        .kind = spec.kind,
        .stream_id = spec.stream_id,
        .request_id = request_id,
        .activated_at_ns = now_ns,
        .wire_digest = wire_digest,
        .descriptor_digest = undefined,
    };
    frame.descriptor_digest = frameDescriptorDigest(frame);

    // No callback or fallible operation may appear below this point. The queue capacity, checked
    // resident sum, request transition, and generation were all revalidated above.
    const was_empty = state.external_tx.items.len == 0;
    state.external_tx.appendAssumeCapacity(frame);
    state.external_tx_bytes += wire_len;
    state.tx_queue_generation += 1;
    if (was_empty) state.tx_head_progress_baseline_ns = now_ns;
    if (prepared_request) |request| request_ids.* = request.next;
    prepared_storage.lifecycle = .committed;
    return .{ .admitted = .{
        .request_id = request_id,
        .wire_len = wire_len,
    } };
}

fn cancellationSnapshotCurrent(
    snapshot: *const CancellationSnapshot,
    prepared: *const PreparedTxCancellation,
    state: *const client_external_mode.State,
    binding: OwnerBinding,
    lifecycle: CancellationLifecycle,
) bool {
    if (snapshot.saved_self_addr != @intFromPtr(prepared) or
        snapshot.state_addr != @intFromPtr(state) or
        snapshot.lifecycle != lifecycle or
        !std.meta.eql(snapshot.binding, binding) or
        snapshot.queue_len != state.external_tx.items.len or
        snapshot.queue_address != @intFromPtr(state.external_tx.items.ptr) or
        snapshot.queue_capacity != state.external_tx.capacity or
        snapshot.queued_bytes != state.external_tx_bytes or
        snapshot.queue_generation != state.tx_queue_generation or
        !std.mem.eql(u8, &snapshot.digest, &(cancellationSnapshotDigest(snapshot) orelse return false)) or
        !std.mem.eql(u8, &snapshot.queue_digest, &(queueDigest(state) orelse return false)))
        return false;
    for (state.external_tx.items, 0..) |frame, index|
        if (!frameMatchesScalar(frame, snapshot.frames[index])) return false;
    return true;
}

pub fn prepareCancellationFromExternalPump(
    comptime validate_owner: OwnerValidator,
    owner_context: *const anyopaque,
    prepared: *PreparedTxCancellation,
    permit: *TxCancellationCommitPermit,
    cleanup: *FrozenTxCancellationCleanup,
    state: *client_external_mode.State,
    binding: OwnerBinding,
    spec: CancellationSpec,
    now_ns: i128,
) CancellationPrepareResult {
    const snapshot = prepared.storage();
    if (!std.mem.allEqual(u8, &prepared.bytes, 0) or
        !std.mem.allEqual(u8, &permit.bytes, 0) or
        !std.mem.allEqual(u8, &cleanup.bytes, 0) or
        binding.purpose != .cancel_turn or
        binding.write_scratch_addr != @intFromPtr(prepared) or
        binding.write_scratch_len != @sizeOf(PreparedTxCancellation) or
        !bindingCanonical(binding) or !validate_owner(owner_context, binding) or
        !cancellationSpecCanonical(spec))
        return .invalid;
    if (state.tx_allocator_context_len != binding.allocator_context_len or
        @intFromPtr(state.tx_allocator.ptr) != binding.allocator_ptr_addr or
        @intFromPtr(state.tx_allocator.vtable) != binding.allocator_vtable_addr or
        cancellationQueueAliasesProtected(state, binding, prepared, permit, cleanup))
        return .invalid;
    const digest = queueDigest(state) orelse return .invalid;
    if (state.tx_last_observed_now_ns) |last|
        if (now_ns < last) return .invalid;
    var candidate = CancellationSnapshot{
        .saved_self_addr = @intFromPtr(prepared),
        .state_addr = @intFromPtr(state),
        .permit_addr = @intFromPtr(permit),
        .cleanup_addr = @intFromPtr(cleanup),
        .binding = binding,
        .spec = spec,
        .queue_generation = state.tx_queue_generation,
        .queue_address = @intFromPtr(state.external_tx.items.ptr),
        .queue_capacity = state.external_tx.capacity,
        .queue_digest = digest,
        .queue_len = state.external_tx.items.len,
        .queued_bytes = state.external_tx_bytes,
        .lifecycle = .prepared,
    };
    var control_matches: usize = 0;
    for (state.external_tx.items, 0..) |frame, index| {
        if (!cancellationFrameWireHeaderMatches(frame)) return .invalid;
        candidate.frames[index] = .{
            .bytes_addr = @intFromPtr(frame.bytes.ptr),
            .bytes_len = frame.bytes.len,
            .offset = frame.offset,
            .kind = frame.kind,
            .stream_id = frame.stream_id,
            .request_id = frame.request_id,
            .activated_at_ns = frame.activated_at_ns,
            .wire_digest = frame.wire_digest,
            .descriptor_digest = frame.descriptor_digest,
        };
        const input_match = frame.kind == .input_bytes and frame.stream_id == spec.stream_id and
            frame.request_id == 0;
        const same_control_id = if (spec.control) |control|
            frame.request_id == control.request_id
        else
            false;
        const control_match = if (spec.control) |control|
            frame.kind == .request and frame.stream_id == 0 and
                frame.request_id == control.request_id and frame.bytes.len == control.wire_len
        else
            false;
        const request_descriptor = frame.kind == .request or frame.request_id != 0;
        if ((same_control_id and !control_match) or
            (request_descriptor and !control_match)) return .uncancellable;
        if (control_match) control_matches += 1;
        if (input_match or control_match) {
            if (frame.offset != 0) return .uncancellable;
            candidate.cancel_mask[index] = true;
            candidate.cancelled_count += 1;
            candidate.cancelled_bytes = std.math.add(
                usize,
                candidate.cancelled_bytes,
                frame.bytes.len,
            ) catch return .invalid;
        }
    }
    if (spec.control != null and control_matches != 1) return .uncancellable;
    if (candidate.cancelled_count != 0 and
        candidate.queue_generation >= std.math.maxInt(u64) - 1) return .invalid;
    candidate.projected_queue_generation = if (candidate.cancelled_count == 0)
        candidate.queue_generation
    else
        std.math.add(u64, candidate.queue_generation, 1) catch return .invalid;
    candidate.projected_queued_bytes = candidate.queued_bytes - candidate.cancelled_bytes;
    var first_survivor: ?FrameScalarSnapshot = null;
    for (candidate.frames[0..candidate.queue_len], 0..) |frame, index|
        if (!candidate.cancel_mask[index]) {
            first_survivor = frame;
            break;
        };
    candidate.projected_head_progress_ns = if (first_survivor == null)
        null
    else if (!candidate.cancel_mask[0])
        state.tx_head_progress_baseline_ns
    else
        now_ns;
    candidate.projected_immediate_pending = first_survivor != null and
        state.tx_immediate_pending;
    candidate.projected_queue_digest = projectedCancellationQueueDigest(&candidate) orelse
        return .invalid;
    candidate.digest = cancellationSnapshotDigest(&candidate) orelse return .invalid;
    snapshot.* = candidate;
    return .prepared;
}

pub fn validatePreparedCancellation(
    comptime validate_owner: OwnerValidator,
    owner_context: *const anyopaque,
    prepared: *PreparedTxCancellation,
    permit: *TxCancellationCommitPermit,
    state: *client_external_mode.State,
    binding: OwnerBinding,
) bool {
    const snapshot = prepared.storage();
    const permit_storage = permit.storage();
    if (!std.meta.eql(permit_storage.*, CancellationPermitStorage{}) or
        !validate_owner(owner_context, binding) or
        !cancellationSnapshotCurrent(snapshot, prepared, state, binding, .prepared))
        return false;
    snapshot.lifecycle = .armed;
    snapshot.digest = cancellationSnapshotDigest(snapshot) orelse return false;
    permit_storage.* = .{
        .saved_self_addr = @intFromPtr(permit),
        .prepared_addr = @intFromPtr(prepared),
        .cleanup_addr = snapshot.cleanup_addr,
        .state_addr = @intFromPtr(state),
        .queue_generation = state.tx_queue_generation,
        .owner_incarnation = binding.owner_incarnation,
        .operation_generation = binding.operation_generation,
        .lifecycle = .armed,
    };
    permit_storage.digest = cancellationPermitDigest(permit_storage);
    return true;
}

pub fn abortPreparedCancellation(
    comptime validate_owner: OwnerValidator,
    owner_context: *const anyopaque,
    prepared: *PreparedTxCancellation,
    permit: *TxCancellationCommitPermit,
    state: *client_external_mode.State,
    binding: OwnerBinding,
) bool {
    const snapshot = prepared.storage();
    const permit_storage = permit.storage();
    const armed = snapshot.lifecycle == .armed;
    if (!validate_owner(owner_context, binding) or
        !cancellationSnapshotCurrent(
            snapshot,
            prepared,
            state,
            binding,
            if (armed) .armed else .prepared,
        )) return false;
    if (armed) {
        if (permit_storage.saved_self_addr != @intFromPtr(permit) or
            permit_storage.prepared_addr != @intFromPtr(prepared) or
            permit_storage.cleanup_addr != snapshot.cleanup_addr or
            permit_storage.state_addr != @intFromPtr(state) or
            permit_storage.lifecycle != .armed or
            !std.mem.eql(u8, &permit_storage.digest, &cancellationPermitDigest(permit_storage)))
            return false;
        permit_storage.lifecycle = .aborted;
        permit_storage.digest = cancellationPermitDigest(permit_storage);
    } else if (!std.mem.allEqual(u8, &permit.bytes, 0)) return false;
    snapshot.lifecycle = .tombstone;
    snapshot.cancelled_count = 0;
    snapshot.cancelled_bytes = 0;
    snapshot.digest = cancellationSnapshotDigest(snapshot) orelse return false;
    return true;
}

fn cancellationCommitReady(
    comptime validate_owner: OwnerValidator,
    owner_context: *const anyopaque,
    prepared: *PreparedTxCancellation,
    permit: *TxCancellationCommitPermit,
    cleanup: *FrozenTxCancellationCleanup,
    state: *client_external_mode.State,
    binding: OwnerBinding,
) bool {
    const snapshot = prepared.storage();
    const permit_storage = permit.storage();
    return std.mem.allEqual(u8, &cleanup.bytes, 0) and
        validate_owner(owner_context, binding) and
        cancellationSnapshotCurrent(snapshot, prepared, state, binding, .armed) and
        snapshot.permit_addr == @intFromPtr(permit) and
        snapshot.cleanup_addr == @intFromPtr(cleanup) and
        permit_storage.saved_self_addr == @intFromPtr(permit) and
        permit_storage.prepared_addr == @intFromPtr(prepared) and
        permit_storage.cleanup_addr == @intFromPtr(cleanup) and
        permit_storage.state_addr == @intFromPtr(state) and
        permit_storage.queue_generation == state.tx_queue_generation and
        permit_storage.owner_incarnation == binding.owner_incarnation and
        permit_storage.operation_generation == binding.operation_generation and
        permit_storage.lifecycle == .armed and
        std.mem.eql(u8, &permit_storage.digest, &cancellationPermitDigest(permit_storage));
}

fn commitValidatedCancellation(
    prepared: *PreparedTxCancellation,
    permit: *TxCancellationCommitPermit,
    cleanup: *FrozenTxCancellationCleanup,
    state: *client_external_mode.State,
) void {
    const snapshot = prepared.storage();
    const permit_storage = permit.storage();
    const cleanup_storage = cleanup.storage();

    cleanup_storage.* = .{
        .saved_self_addr = @intFromPtr(cleanup),
        .state_addr = @intFromPtr(state),
        .allocator = state.tx_allocator,
        .allocator_ptr_addr = @intFromPtr(state.tx_allocator.ptr),
        .allocator_vtable_addr = @intFromPtr(state.tx_allocator.vtable),
        .binding = snapshot.binding,
        .binding_digest = ownerBindingDigest(snapshot.binding),
        .count = snapshot.cancelled_count,
        .total_bytes = snapshot.cancelled_bytes,
        .lifecycle = .owned,
    };
    var survivor_count: usize = 0;
    var cancelled_count: usize = 0;
    const old_len = state.external_tx.items.len;
    for (state.external_tx.items, 0..) |frame, index| {
        if (snapshot.cancel_mask[index]) {
            cleanup_storage.frames[cancelled_count] = frame;
            cancelled_count += 1;
        } else {
            state.external_tx.items[survivor_count] = frame;
            survivor_count += 1;
        }
    }
    // The ArrayList length is not an ownership boundary: stale descriptors in the inactive tail
    // remain readable through the fixed backing allocation. Erase every removed slot before
    // publishing the shorter length so no cancelled allocation identity survives there.
    @memset(std.mem.sliceAsBytes(state.external_tx.items.ptr[survivor_count..old_len]), 0);
    state.external_tx.items.len = survivor_count;
    state.external_tx_bytes = snapshot.projected_queued_bytes;
    state.tx_queue_generation = snapshot.projected_queue_generation;
    state.tx_head_progress_baseline_ns = snapshot.projected_head_progress_ns;
    state.tx_immediate_pending = snapshot.projected_immediate_pending;
    cleanup_storage.post_queue_generation = snapshot.projected_queue_generation;
    cleanup_storage.post_queued_bytes = snapshot.projected_queued_bytes;
    cleanup_storage.post_queue_digest = snapshot.projected_queue_digest;
    state.external_tx_retiring_bytes = snapshot.cancelled_bytes;
    cleanup_storage.digest = cancellationCleanupDigest(cleanup_storage) orelse
        @panic("validated cancellation cleanup seal became invalid");
    snapshot.lifecycle = .committed;
    snapshot.digest = cancellationSnapshotDigest(snapshot) orelse
        @panic("validated cancellation snapshot seal became invalid");
    permit_storage.lifecycle = .consumed;
    permit_storage.digest = cancellationPermitDigest(permit_storage);
}

pub fn consumePreparedCancellationUnderHeldLease(
    comptime validate_owner: OwnerValidator,
    owner_context: *const anyopaque,
    prepared: *PreparedTxCancellation,
    permit: *TxCancellationCommitPermit,
    cleanup: *FrozenTxCancellationCleanup,
    state: *client_external_mode.State,
    binding: OwnerBinding,
) bool {
    if (!cancellationCommitReady(
        validate_owner,
        owner_context,
        prepared,
        permit,
        cleanup,
        state,
        binding,
    )) return false;
    commitValidatedCancellation(prepared, permit, cleanup, state);
    return true;
}

pub const CancellationCleanupResult = enum { cleaned, invalid, quarantined };

fn tombstoneCorruptCancellationCleanup(
    frozen: *CancellationCleanupStorage,
    state: *client_external_mode.State,
) CancellationCleanupResult {
    const retiring = state.external_tx_retiring_bytes;
    if (retiring > max_resident_bytes) @panic("unbounded cancellation retirement charge");
    if (retiring != 0) client_external_mode.chargeTxQuarantine(state, retiring);
    state.tx_lifecycle = .terminal_tombstone;
    state.external_tx_retiring_bytes = 0;
    frozen.lifecycle = .quarantined;
    frozen.count = 0;
    frozen.total_bytes = 0;
    frozen.digest = cancellationCleanupDigest(frozen) orelse
        @panic("bounded cancellation quarantine seal became invalid");
    return .quarantined;
}

fn cancellationCleanupDescriptorsValid(
    frozen: *const CancellationCleanupStorage,
    state: *const client_external_mode.State,
    binding: OwnerBinding,
    prepared: *const PreparedTxCancellation,
    permit: *const TxCancellationCommitPermit,
    cleanup: *const FrozenTxCancellationCleanup,
) bool {
    var total: usize = 0;
    const ranges = checkedCancellationRanges(
        state,
        binding,
        @intFromPtr(prepared),
        @intFromPtr(permit),
        @intFromPtr(cleanup),
    ) orelse return false;
    for (frozen.frames[0..frozen.count], 0..) |frame, index| {
        if (frame.bytes.len < protocol.header_size or frame.bytes.len > max_resident_bytes or
            frame.offset != 0 or
            !std.mem.eql(u8, &frame.descriptor_digest, &frameDescriptorDigest(frame)))
            return false;
        const frame_range = sliceRange(frame.bytes) orelse return false;
        const protected = [_]Range{
            ranges.storage,
            ranges.client,
            ranges.lease,
            ranges.scratch,
            ranges.write_scratch,
            ranges.allocator_context,
            ranges.allocator_vtable,
            ranges.queue_backing,
            ranges.prepared,
            ranges.permit,
            ranges.cleanup,
        };
        for (protected) |item|
            if (rangesOverlap(frame_range, item)) return false;
        for (frozen.frames[0..index]) |prior| {
            const prior_range = sliceRange(prior.bytes) orelse return false;
            if (rangesOverlap(frame_range, prior_range)) return false;
        }
        total = std.math.add(usize, total, frame.bytes.len) catch return false;
    }
    return total == frozen.total_bytes and total <= max_resident_bytes;
}

const CancellationCleanupAuthority = enum { foreign, original_corrupt, valid };

fn cancellationCleanupAuthority(
    prepared: *PreparedTxCancellation,
    permit: *TxCancellationCommitPermit,
    cleanup: *const FrozenTxCancellationCleanup,
    state: *const client_external_mode.State,
    binding: OwnerBinding,
) CancellationCleanupAuthority {
    const snapshot = prepared.storage();
    const permit_storage = permit.storage();
    if (snapshot.saved_self_addr != @intFromPtr(prepared) or
        snapshot.state_addr != @intFromPtr(state) or
        snapshot.permit_addr != @intFromPtr(permit) or
        snapshot.cleanup_addr != @intFromPtr(cleanup) or
        permit_storage.saved_self_addr != @intFromPtr(permit))
        return .foreign;
    if (permit_storage.prepared_addr != @intFromPtr(prepared) or
        permit_storage.cleanup_addr != @intFromPtr(cleanup) or
        permit_storage.state_addr != @intFromPtr(state) or
        permit_storage.owner_incarnation != binding.owner_incarnation or
        permit_storage.operation_generation != binding.operation_generation or
        permit_storage.lifecycle != .consumed or
        !std.mem.eql(u8, &permit_storage.digest, &cancellationPermitDigest(permit_storage)))
        return .foreign;
    if (snapshot.lifecycle != .committed or
        !std.meta.eql(snapshot.binding, binding) or
        !std.mem.eql(u8, &snapshot.digest, &(cancellationSnapshotDigest(snapshot) orelse
            return .original_corrupt)))
        return .original_corrupt;
    return .valid;
}

fn cancellationCleanupDigestValid(frozen: *const CancellationCleanupStorage) bool {
    return frozen.count <= client_external_mode.max_tx_frames and
        std.mem.eql(u8, &frozen.digest, &(cancellationCleanupDigest(frozen) orelse return false));
}

pub fn finishCancellationCleanup(
    comptime validate_owner: OwnerValidator,
    owner_context: *const anyopaque,
    prepared: *PreparedTxCancellation,
    permit: *TxCancellationCommitPermit,
    cleanup: *FrozenTxCancellationCleanup,
    state: *client_external_mode.State,
    binding: OwnerBinding,
) CancellationCleanupResult {
    const frozen = cleanup.storage();
    switch (cancellationCleanupAuthority(prepared, permit, cleanup, state, binding)) {
        .foreign => return .invalid,
        .original_corrupt => return tombstoneCorruptCancellationCleanup(frozen, state),
        .valid => {},
    }
    const header_digest_valid = cancellationCleanupDigestValid(frozen);
    if ((frozen.lifecycle == .cleaned or frozen.lifecycle == .quarantined) and
        frozen.saved_self_addr == @intFromPtr(cleanup) and
        frozen.state_addr == @intFromPtr(state) and
        std.meta.eql(frozen.binding, binding) and
        std.mem.eql(u8, &frozen.binding_digest, &ownerBindingDigest(binding)) and
        header_digest_valid)
        return .invalid;
    if (frozen.saved_self_addr != @intFromPtr(cleanup) or
        frozen.state_addr != @intFromPtr(state) or frozen.lifecycle != .owned or
        !std.meta.eql(frozen.binding, binding) or
        !std.mem.eql(u8, &frozen.binding_digest, &ownerBindingDigest(binding)) or
        !header_digest_valid or
        frozen.count > client_external_mode.max_tx_frames or
        frozen.total_bytes != state.external_tx_retiring_bytes or
        frozen.allocator_ptr_addr != @intFromPtr(frozen.allocator.ptr) or
        frozen.allocator_vtable_addr != @intFromPtr(frozen.allocator.vtable) or
        !cancellationCleanupDescriptorsValid(frozen, state, binding, prepared, permit, cleanup) or
        !validate_owner(owner_context, binding))
        return tombstoneCorruptCancellationCleanup(frozen, state);
    state.tx_lifecycle = .completion_callback;
    var remaining = frozen.total_bytes;
    for (frozen.frames[0..frozen.count], 0..) |frame, index| {
        frozen.allocator.rawFree(frame.bytes, .@"1", @returnAddress());
        remaining -= frame.bytes.len;
        const stable = state.tx_lifecycle == .completion_callback and
            state.tx_queue_generation == frozen.post_queue_generation and
            state.external_tx_bytes == frozen.post_queued_bytes and
            state.external_tx_retiring_bytes == frozen.total_bytes and
            validate_owner(owner_context, binding);
        if (!stable) {
            client_external_mode.chargeTxQuarantine(state, remaining);
            state.tx_lifecycle = .terminal_tombstone;
            state.external_tx_retiring_bytes = 0;
            frozen.lifecycle = .quarantined;
            frozen.count = 0;
            frozen.total_bytes = 0;
            frozen.digest = cancellationCleanupDigest(frozen) orelse
                @panic("bounded cancellation callback quarantine seal became invalid");
            _ = index;
            return .quarantined;
        }
    }
    state.tx_lifecycle = .live;
    state.external_tx_retiring_bytes = 0;
    const actual_post_digest = queueDigest(state) orelse {
        quarantineLiveQueue(state, frozen.post_queued_bytes);
        frozen.lifecycle = .quarantined;
        frozen.count = 0;
        frozen.total_bytes = 0;
        frozen.digest = cancellationCleanupDigest(frozen) orelse
            @panic("bounded cancellation live-queue quarantine seal became invalid");
        return .quarantined;
    };
    if (!std.mem.eql(u8, &frozen.post_queue_digest, &actual_post_digest)) {
        quarantineLiveQueue(state, frozen.post_queued_bytes);
        frozen.lifecycle = .quarantined;
        frozen.count = 0;
        frozen.total_bytes = 0;
        frozen.digest = cancellationCleanupDigest(frozen) orelse
            @panic("bounded cancellation digest quarantine seal became invalid");
        return .quarantined;
    }
    frozen.lifecycle = .cleaned;
    frozen.count = 0;
    frozen.total_bytes = 0;
    frozen.digest = cancellationCleanupDigest(frozen) orelse
        @panic("bounded cancellation cleaned seal became invalid");
    return .cleaned;
}

fn captureWriteSnapshot(
    state: *const client_external_mode.State,
) ?WriteSnapshot {
    const digest = queueDescriptorDigest(state) orelse return null;
    var result: WriteSnapshot = .{
        .queue_address = if (state.external_tx.capacity == 0)
            0
        else
            @intFromPtr(state.external_tx.items.ptr),
        .queue_len = state.external_tx.items.len,
        .queue_capacity = state.external_tx.capacity,
        .queue_generation = state.tx_queue_generation,
        .queue_digest = digest,
        .queued_bytes = state.external_tx_bytes,
        .retiring_bytes = state.external_tx_retiring_bytes,
        .head_progress_ns = state.tx_head_progress_baseline_ns,
        .immediate_pending = state.tx_immediate_pending,
        .frame_scalars = undefined,
        .frame_scalar_count = state.external_tx.items.len,
    };
    for (state.external_tx.items, 0..) |frame, index|
        result.frame_scalars[index] = .{
            .bytes_addr = @intFromPtr(frame.bytes.ptr),
            .bytes_len = frame.bytes.len,
            .offset = frame.offset,
            .kind = frame.kind,
            .stream_id = frame.stream_id,
            .request_id = frame.request_id,
            .activated_at_ns = frame.activated_at_ns,
            .wire_digest = frame.wire_digest,
            .descriptor_digest = frame.descriptor_digest,
        };
    return result;
}

fn writeSnapshotScalarsMatch(
    snapshot: WriteSnapshot,
    state: *const client_external_mode.State,
) bool {
    if (!(state.tx_lifecycle == .live and
        snapshot.queue_address == (if (state.external_tx.capacity == 0)
            0
        else
            @intFromPtr(state.external_tx.items.ptr)) and
        snapshot.queue_len == state.external_tx.items.len and
        snapshot.queue_capacity == state.external_tx.capacity and
        snapshot.queue_generation == state.tx_queue_generation and
        snapshot.queued_bytes == state.external_tx_bytes and
        snapshot.retiring_bytes == state.external_tx_retiring_bytes and
        snapshot.head_progress_ns == state.tx_head_progress_baseline_ns and
        snapshot.immediate_pending == state.tx_immediate_pending and
        snapshot.frame_scalar_count == state.external_tx.items.len))
        return false;
    // The queue backing pointer and bounds were compared above. Only now is it safe to inspect
    // descriptors, and backing bytes remain untouched until every pointer/length scalar matches.
    for (state.external_tx.items, 0..) |frame, index| {
        const frozen = snapshot.frame_scalars[index];
        if (frozen.bytes_addr != @intFromPtr(frame.bytes.ptr) or
            frozen.bytes_len != frame.bytes.len or
            frozen.offset != frame.offset or
            frozen.kind != frame.kind or
            frozen.stream_id != frame.stream_id or
            frozen.request_id != frame.request_id or
            frozen.activated_at_ns != frame.activated_at_ns or
            !std.mem.eql(u8, &frozen.wire_digest, &frame.wire_digest) or
            !std.mem.eql(
                u8,
                &frozen.descriptor_digest,
                &frame.descriptor_digest,
            ))
            return false;
    }
    return true;
}

fn writeSnapshotMatches(
    snapshot: WriteSnapshot,
    state: *const client_external_mode.State,
) bool {
    return writeSnapshotScalarsMatch(snapshot, state) and
        std.mem.eql(
            u8,
            &snapshot.queue_digest,
            &(queueDescriptorDigest(state) orelse return false),
        );
}

fn checkedDeadline(start_ns: i128, duration_ns: i128) ?i128 {
    return std.math.add(i128, start_ns, duration_ns) catch null;
}

pub fn pollHint(state: *const client_external_mode.State) TxPollHint {
    if (queueDigest(state) == null)
        return .{ .immediate = true, .valid = false };
    var deadline: ?i128 = null;
    for (state.external_tx.items) |frame| {
        const candidate = checkedDeadline(
            frame.activated_at_ns,
            absolute_timeout_ns,
        ) orelse return .{ .immediate = true, .valid = false };
        deadline = if (deadline) |current|
            @min(current, candidate)
        else
            candidate;
    }
    if (state.external_tx.items.len != 0) {
        const baseline = state.tx_head_progress_baseline_ns orelse
            return .{ .immediate = true, .valid = false };
        const progress = checkedDeadline(
            baseline,
            progress_timeout_ns,
        ) orelse return .{ .immediate = true, .valid = false };
        deadline = if (deadline) |current| @min(current, progress) else progress;
    }
    return .{
        .deadline_ns = deadline,
        .immediate = state.tx_immediate_pending,
    };
}

fn deadlinesValid(
    state: *const client_external_mode.State,
    now_ns: i128,
) ?client_pump.TerminalReason {
    for (state.external_tx.items) |frame| {
        const deadline = checkedDeadline(
            frame.activated_at_ns,
            absolute_timeout_ns,
        ) orelse return .invariant_failure;
        if (now_ns >= deadline) return .deadline_exceeded;
    }
    if (state.external_tx.items.len != 0) {
        const baseline = state.tx_head_progress_baseline_ns orelse
            return .invariant_failure;
        const deadline = checkedDeadline(
            baseline,
            progress_timeout_ns,
        ) orelse return .invariant_failure;
        if (now_ns >= deadline) return .deadline_exceeded;
    }
    return null;
}

fn completionDigest(storage: *const CompletionStorage) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARUTXC1");
    writer.writeUsize(storage.saved_self_addr);
    writer.writeU64(storage.owner_incarnation);
    writer.writeU64(storage.operation_generation);
    writer.writeU64(@intFromEnum(storage.lifecycle));
    writer.writeUsize(storage.count);
    for (storage.completions[0..storage.count]) |completion| {
        writer.writeU16(@intFromEnum(completion.kind));
        writer.writeU64(completion.stream_id);
        writer.writeU64(completion.request_id);
        writer.writeUsize(completion.wire_len);
    }
    return writer.finish();
}

fn completionStorageValid(
    storage: *const CompletionStorage,
    prepared: *const PreparedTxWrite,
    binding: OwnerBinding,
    lifecycle: CompletionLifecycle,
) bool {
    return storage.saved_self_addr == @intFromPtr(prepared) and
        binding.write_scratch_addr == @intFromPtr(prepared) and
        binding.write_scratch_len == @sizeOf(PreparedTxWrite) and
        storage.owner_incarnation == binding.owner_incarnation and
        storage.operation_generation == binding.operation_generation and
        storage.lifecycle == lifecycle and
        storage.count <= client_external_mode.max_tx_frames and
        std.mem.eql(
            u8,
            &storage.digest,
            &completionDigest(storage),
        );
}

fn initCompletionStorage(
    prepared: *PreparedTxWrite,
    binding: OwnerBinding,
) bool {
    const storage = prepared.storage();
    if (!std.meta.eql(storage.*, CompletionStorage{}) or
        binding.write_scratch_addr != @intFromPtr(prepared) or
        binding.write_scratch_len != @sizeOf(PreparedTxWrite))
        return false;
    storage.saved_self_addr = @intFromPtr(prepared);
    storage.owner_incarnation = binding.owner_incarnation;
    storage.operation_generation = binding.operation_generation;
    storage.lifecycle = .collecting;
    storage.count = 0;
    storage.digest = completionDigest(storage);
    return true;
}

fn appendCompletion(
    prepared: *PreparedTxWrite,
    binding: OwnerBinding,
    completion: TxCompletion,
) bool {
    const storage = prepared.storage();
    if (!completionStorageValid(storage, prepared, binding, .collecting) or
        storage.count == client_external_mode.max_tx_frames)
        return false;
    storage.completions[storage.count] = completion;
    storage.count += 1;
    storage.digest = completionDigest(storage);
    return true;
}

fn tombstoneCompletionStorage(
    prepared: *PreparedTxWrite,
    binding: OwnerBinding,
) void {
    const storage = prepared.storage();
    storage.* = .{
        .saved_self_addr = @intFromPtr(prepared),
        .owner_incarnation = binding.owner_incarnation,
        .operation_generation = binding.operation_generation,
        .lifecycle = .terminal_tombstone,
        .count = 0,
        .completions = undefined,
        .digest = undefined,
    };
    storage.digest = completionDigest(storage);
}

/// The sole completion lifecycle seam. f1 supplies a discard sink; f2/e extend that same sink
/// rather than reading the opaque scratch or retaining transport evidence across turns.
pub fn consumeTxCompletionsUnderHeldLease(
    comptime validate_owner: OwnerValidator,
    owner_context: *const anyopaque,
    prepared: *PreparedTxWrite,
    state: *client_external_mode.State,
    binding: OwnerBinding,
    sink: CompletionSink,
    semantic_allowed: bool,
) bool {
    const storage = prepared.storage();
    if (!validate_owner(owner_context, binding) or
        !completionStorageValid(storage, prepared, binding, .collecting))
    {
        tombstoneCompletionStorage(prepared, binding);
        return false;
    }
    const queue_snapshot = captureWriteSnapshot(state) orelse {
        tombstoneCompletionStorage(prepared, binding);
        return false;
    };
    var frozen: [client_external_mode.max_tx_frames]TxCompletion = undefined;
    if (storage.count != 0)
        @memcpy(frozen[0..storage.count], storage.completions[0..storage.count]);
    const count = storage.count;
    storage.lifecycle = .consuming;
    storage.digest = completionDigest(storage);
    state.tx_lifecycle = .completion_callback;
    const accepted = sink.consume(
        sink.context,
        frozen[0..count],
        semantic_allowed,
    );
    const lifecycle_valid = state.tx_lifecycle == .completion_callback;
    if (lifecycle_valid) state.tx_lifecycle = .live;
    const queue_valid = lifecycle_valid and
        writeSnapshotScalarsMatch(queue_snapshot, state) and
        writeSnapshotMatches(queue_snapshot, state);
    if (!queue_valid)
        quarantineLiveQueue(state, queue_snapshot.queued_bytes);
    if (!accepted or !queue_valid or
        !validate_owner(owner_context, binding) or
        !completionStorageValid(storage, prepared, binding, .consuming))
    {
        tombstoneCompletionStorage(prepared, binding);
        return false;
    }
    storage.lifecycle = .spent;
    storage.digest = completionDigest(storage);
    return true;
}

pub fn observeClock(
    state: *client_external_mode.State,
    now_ns: i128,
) ?client_pump.TerminalReason {
    _ = queueDigest(state) orelse return .invariant_failure;
    if (state.tx_last_observed_now_ns) |last|
        if (now_ns < last) return .deadline_exceeded;
    if (deadlinesValid(state, now_ns)) |reason| return reason;
    state.tx_last_observed_now_ns = now_ns;
    state.tx_immediate_pending = false;
    return null;
}

fn queueDigestDuringRetire(
    state: *const client_external_mode.State,
    expected_retiring: usize,
) ?external_owner_seal.Digest {
    if (state.tx_lifecycle != .live or
        state.external_tx_retiring_bytes != expected_retiring or
        state.external_tx_quarantined_bytes != 0 or
        state.tx_queue_backing_addr == 0 or
        state.tx_queue_backing_capacity != client_external_mode.max_tx_frames or
        state.external_tx.capacity != state.tx_queue_backing_capacity or
        @intFromPtr(state.external_tx.items.ptr) !=
            state.tx_queue_backing_addr or
        state.external_tx.items.len > state.external_tx.capacity or
        state.tx_queue_generation == 0)
        return null;
    var total: usize = 0;
    var writer = external_owner_seal.Writer.init("MARUTXRT");
    writer.writeUsize(@intFromPtr(state.external_tx.items.ptr));
    writer.writeUsize(state.external_tx.items.len);
    writer.writeU64(state.tx_queue_generation);
    for (state.external_tx.items) |frame| {
        if (frame.bytes.len < protocol.header_size or
            frame.offset > frame.bytes.len or
            !std.mem.eql(
                u8,
                &frame.wire_digest,
                &bytesDigest("MARUTXW1", frame.bytes),
            ) or
            !std.mem.eql(
                u8,
                &frame.descriptor_digest,
                &frameDescriptorDigest(frame),
            ))
            return null;
        total = std.math.add(usize, total, frame.bytes.len) catch return null;
        writer.writeBytes(&frame.descriptor_digest);
    }
    if (total != state.external_tx_bytes) return null;
    writer.writeUsize(total);
    writer.writeUsize(expected_retiring);
    return writer.finish();
}

const RetireSnapshot = struct {
    queue_address: usize,
    queue_len: usize,
    queue_capacity: usize,
    queue_generation: u64,
    queued_bytes: usize,
    retiring_bytes: usize,
    head_progress_ns: ?i128,
    immediate_pending: bool,
    digest: external_owner_seal.Digest,
    frame_scalars: [client_external_mode.max_tx_frames]FrameScalarSnapshot,
    frame_scalar_count: usize,
};

fn captureRetireSnapshot(
    state: *const client_external_mode.State,
    expected_retiring: usize,
) ?RetireSnapshot {
    const digest = queueDigestDuringRetire(state, expected_retiring) orelse
        return null;
    var result: RetireSnapshot = .{
        .queue_address = @intFromPtr(state.external_tx.items.ptr),
        .queue_len = state.external_tx.items.len,
        .queue_capacity = state.external_tx.capacity,
        .queue_generation = state.tx_queue_generation,
        .queued_bytes = state.external_tx_bytes,
        .retiring_bytes = state.external_tx_retiring_bytes,
        .head_progress_ns = state.tx_head_progress_baseline_ns,
        .immediate_pending = state.tx_immediate_pending,
        .digest = digest,
        .frame_scalars = undefined,
        .frame_scalar_count = state.external_tx.items.len,
    };
    for (state.external_tx.items, 0..) |frame, index|
        result.frame_scalars[index] = .{
            .bytes_addr = @intFromPtr(frame.bytes.ptr),
            .bytes_len = frame.bytes.len,
            .offset = frame.offset,
            .kind = frame.kind,
            .stream_id = frame.stream_id,
            .request_id = frame.request_id,
            .activated_at_ns = frame.activated_at_ns,
            .wire_digest = frame.wire_digest,
            .descriptor_digest = frame.descriptor_digest,
        };
    return result;
}

fn retireSnapshotScalarsMatch(
    snapshot: RetireSnapshot,
    state: *const client_external_mode.State,
) bool {
    if (!(state.tx_lifecycle == .live and
        snapshot.queue_address == @intFromPtr(state.external_tx.items.ptr) and
        snapshot.queue_len == state.external_tx.items.len and
        snapshot.queue_capacity == state.external_tx.capacity and
        snapshot.queue_generation == state.tx_queue_generation and
        snapshot.queued_bytes == state.external_tx_bytes and
        snapshot.retiring_bytes == state.external_tx_retiring_bytes and
        snapshot.head_progress_ns == state.tx_head_progress_baseline_ns and
        snapshot.immediate_pending == state.tx_immediate_pending and
        snapshot.frame_scalar_count == state.external_tx.items.len))
        return false;
    for (state.external_tx.items, 0..) |frame, index| {
        const frozen = snapshot.frame_scalars[index];
        if (frozen.bytes_addr != @intFromPtr(frame.bytes.ptr) or
            frozen.bytes_len != frame.bytes.len or
            frozen.offset != frame.offset or
            frozen.kind != frame.kind or
            frozen.stream_id != frame.stream_id or
            frozen.request_id != frame.request_id or
            frozen.activated_at_ns != frame.activated_at_ns or
            !std.mem.eql(u8, &frozen.wire_digest, &frame.wire_digest) or
            !std.mem.eql(
                u8,
                &frozen.descriptor_digest,
                &frame.descriptor_digest,
            ))
            return false;
    }
    return true;
}

fn retireHead(
    comptime validate_owner: OwnerValidator,
    owner_context: *const anyopaque,
    allocator: std.mem.Allocator,
    state: *client_external_mode.State,
    binding: OwnerBinding,
    completion: *TxCompletion,
    now_ns: i128,
) ?client_pump.TerminalReason {
    if (state.external_tx.items.len == 0) return .invariant_failure;
    const frozen = state.external_tx.items[0];
    if (frozen.offset != frozen.bytes.len or
        state.tx_queue_generation == std.math.maxInt(u64))
        return .invariant_failure;
    completion.* = .{
        .kind = frozen.kind,
        .stream_id = frozen.stream_id,
        .request_id = frozen.request_id,
        .wire_len = frozen.bytes.len,
    };
    const remaining = state.external_tx.items.len - 1;
    if (remaining != 0)
        std.mem.copyForwards(
            client_external_mode.ExternalTxFrame,
            state.external_tx.items[0..remaining],
            state.external_tx.items[1..],
        );
    state.external_tx.items.len = remaining;
    state.external_tx_bytes -= frozen.bytes.len;
    state.external_tx_retiring_bytes += frozen.bytes.len;
    state.tx_queue_generation += 1;
    state.tx_head_progress_baseline_ns = if (remaining == 0) null else now_ns;
    if (remaining == 0) state.tx_immediate_pending = false;
    const post = captureRetireSnapshot(
        state,
        frozen.bytes.len,
    ) orelse return .invariant_failure;
    const retire_quarantine_charge = std.math.add(
        usize,
        frozen.bytes.len,
        post.queued_bytes,
    ) catch return .invariant_failure;
    allocator.rawFree(frozen.bytes, .@"1", @returnAddress());
    if (!validate_owner(owner_context, binding) or
        state.external_tx_retiring_bytes != frozen.bytes.len or
        !retireSnapshotScalarsMatch(post, state))
    {
        quarantineLiveQueue(state, retire_quarantine_charge);
        return .invariant_failure;
    }
    const current_digest = queueDigestDuringRetire(
        state,
        frozen.bytes.len,
    ) orelse {
        quarantineLiveQueue(state, retire_quarantine_charge);
        return .invariant_failure;
    };
    if (!std.mem.eql(u8, &post.digest, &current_digest)) {
        quarantineLiveQueue(state, retire_quarantine_charge);
        return .invariant_failure;
    }
    state.external_tx_retiring_bytes = 0;
    return null;
}

pub fn writeTurnPreparedFromExternalPump(
    comptime validate_owner: OwnerValidator,
    owner_context: *const anyopaque,
    prepared: *PreparedTxWrite,
    completion_sink: CompletionSink,
    allocator: std.mem.Allocator,
    state: *client_external_mode.State,
    binding: OwnerBinding,
    ops: WriteOps,
    now_ns: i128,
) WriteResult {
    var result: WriteResult = .{};
    if (!bindingCanonical(binding) or
        binding.purpose != .write_turn or
        @intFromPtr(allocator.ptr) != binding.allocator_ptr_addr or
        @intFromPtr(allocator.vtable) != binding.allocator_vtable_addr or
        @intFromPtr(state.tx_allocator.ptr) != binding.allocator_ptr_addr or
        @intFromPtr(state.tx_allocator.vtable) != binding.allocator_vtable_addr or
        state.tx_allocator_context_len != binding.allocator_context_len or
        !validate_owner(owner_context, binding))
    {
        result.terminal = .invariant_failure;
        return result;
    }
    if (!initCompletionStorage(prepared, binding)) {
        result.terminal = .invariant_failure;
        return result;
    }
    if (observeClock(state, now_ns)) |reason| {
        result.terminal = reason;
        _ = consumeTxCompletionsUnderHeldLease(
            validate_owner,
            owner_context,
            prepared,
            state,
            binding,
            completion_sink,
            false,
        );
        return result;
    }

    var interrupted_count: usize = 0;
    var adaptive_offer_cap: ?usize = null;
    while (state.external_tx.items.len != 0 and
        result.accepted_bytes < max_turn_write_bytes and
        result.completed_frames < client_external_mode.max_tx_frames)
    {
        const snapshot = captureWriteSnapshot(state) orelse {
            result.terminal = .invariant_failure;
            break;
        };
        const head = state.external_tx.items[0];
        const remaining = head.bytes.len - head.offset;
        const turn_remaining = max_turn_write_bytes - result.accepted_bytes;
        const offered_len = @min(
            @min(remaining, turn_remaining),
            adaptive_offer_cap orelse std.math.maxInt(usize),
        );
        if (offered_len == 0) break;
        const offered = head.bytes[head.offset..][0..offered_len];
        const offered_digest = offeredBytesDigest(offered);
        const outcome = ops.write(
            ops.context,
            offered,
        );
        if (!validate_owner(owner_context, binding) or
            !writeSnapshotScalarsMatch(snapshot, state))
        {
            quarantineLiveQueue(state, snapshot.queued_bytes);
            result.terminal = .invariant_failure;
            break;
        }
        if (!writeSnapshotMatches(snapshot, state)) {
            quarantineLiveQueue(state, snapshot.queued_bytes);
            result.terminal = .invariant_failure;
            break;
        }
        if (!std.mem.eql(
            u8,
            &offered_digest,
            &offeredBytesDigest(offered),
        )) {
            quarantineLiveQueue(state, snapshot.queued_bytes);
            result.terminal = .invariant_failure;
            break;
        }
        switch (outcome) {
            .would_block => {
                result.would_block = true;
                break;
            },
            .interrupted => {
                interrupted_count += 1;
                if (interrupted_count > 8) {
                    result.terminal = .invariant_failure;
                    break;
                }
                continue;
            },
            .zero, .socket_error => {
                result.terminal = .socket_error;
                break;
            },
            .written => |accepted| {
                if (accepted == 0 or accepted > offered_len or
                    state.tx_queue_generation == std.math.maxInt(u64))
                {
                    result.terminal = .invariant_failure;
                    break;
                }
                interrupted_count = 0;
                if (accepted < offered_len) adaptive_offer_cap = accepted;
                result.accepted_bytes += accepted;
                state.external_tx.items[0].offset += accepted;
                state.tx_head_progress_baseline_ns = now_ns;
                state.tx_queue_generation += 1;
                state.external_tx.items[0].descriptor_digest =
                    frameDescriptorDigest(state.external_tx.items[0]);
                if (state.external_tx.items[0].offset ==
                    state.external_tx.items[0].bytes.len)
                {
                    // Retire is part of the same positive-write transition, so undo the provisional
                    // generation increment and let the retire suffix publish the single aggregate +1.
                    state.tx_queue_generation -= 1;
                    var completion: TxCompletion = undefined;
                    if (retireHead(
                        validate_owner,
                        owner_context,
                        allocator,
                        state,
                        binding,
                        &completion,
                        now_ns,
                    )) |reason| {
                        result.terminal = reason;
                        break;
                    }
                    if (!appendCompletion(prepared, binding, completion)) {
                        result.terminal = .invariant_failure;
                        break;
                    }
                    result.completed_frames += 1;
                    adaptive_offer_cap = null;
                }
            },
        }
    }
    if (result.terminal != null) {
        state.tx_immediate_pending = false;
        result.immediate_tx = false;
        _ = consumeTxCompletionsUnderHeldLease(
            validate_owner,
            owner_context,
            prepared,
            state,
            binding,
            completion_sink,
            false,
        );
        return result;
    }
    if (state.external_tx.items.len != 0 and
        (result.accepted_bytes == max_turn_write_bytes or
            result.completed_frames == client_external_mode.max_tx_frames))
    {
        state.tx_immediate_pending = true;
        result.immediate_tx = true;
    }
    if (!consumeTxCompletionsUnderHeldLease(
        validate_owner,
        owner_context,
        prepared,
        state,
        binding,
        completion_sink,
        true,
    )) {
        result.terminal = .invariant_failure;
        state.tx_immediate_pending = false;
        result.immediate_tx = false;
    }
    return result;
}

fn discardCompletions(
    _: *anyopaque,
    completions: []const TxCompletion,
    _: bool,
) bool {
    for (completions) |completion| std.mem.doNotOptimizeAway(completion);
    return true;
}

/// Test-facing convenience wrapper. Product code owns the final-address scratch explicitly and
/// enters `writeTurnPreparedFromExternalPump`; this wrapper keeps leaf mechanics fixtures terse.
fn writeTurnFromExternalPump(
    comptime validate_owner: OwnerValidator,
    owner_context: *const anyopaque,
    allocator: std.mem.Allocator,
    state: *client_external_mode.State,
    original_binding: OwnerBinding,
    ops: WriteOps,
    now_ns: i128,
) WriteResult {
    var prepared: PreparedTxWrite = .{};
    var binding = original_binding;
    binding.purpose = .write_turn;
    binding.write_scratch_addr = @intFromPtr(&prepared);
    binding.write_scratch_len = @sizeOf(PreparedTxWrite);
    var discard_context: u8 = 0;
    return writeTurnPreparedFromExternalPump(
        validate_owner,
        owner_context,
        &prepared,
        .{
            .context = &discard_context,
            .consume = discardCompletions,
        },
        allocator,
        state,
        binding,
        ops,
        now_ns,
    );
}

fn testOwnerValid(_: *const anyopaque, binding: OwnerBinding) bool {
    return binding.owner_incarnation == test_owner_incarnation and
        binding.operation_generation == test_operation_generation and
        !test_reentry_latched and
        std.mem.allEqual(u8, &test_lease_digest, 0x11) and
        std.mem.allEqual(u8, &test_owner_digest, 0x22);
}

fn admit(
    allocator: std.mem.Allocator,
    state: *client_external_mode.State,
    request_ids: *client_pump.RequestIdState,
    original_binding: OwnerBinding,
    spec: AdmissionSpec,
    now_ns: i128,
) AdmissionResult {
    var prepared: PreparedTxAdmission = .{};
    var binding = original_binding;
    binding.scratch_addr = @intFromPtr(&prepared);
    binding.scratch_len = @sizeOf(PreparedTxAdmission);
    binding.write_scratch_addr = @intFromPtr(&prepared);
    binding.write_scratch_len = @sizeOf(PreparedTxAdmission);
    return admitFromExternalPump(
        testOwnerValid,
        @ptrCast(state),
        &prepared,
        allocator,
        state,
        request_ids,
        binding,
        spec,
        now_ns,
    );
}

fn initState() !client_external_mode.State {
    var state = client_external_mode.State{ .saved_flags = 0 };
    try state.external_tx.ensureTotalCapacityPrecise(
        std.testing.allocator,
        client_external_mode.max_tx_frames,
    );
    state.tx_queue_backing_addr = @intFromPtr(state.external_tx.items.ptr);
    state.tx_queue_backing_capacity = state.external_tx.capacity;
    state.tx_allocator = std.testing.allocator;
    state.tx_allocator_context_len = 1;
    return state;
}

var test_owner_incarnation: u64 = 7;
var test_operation_generation: u64 = 11;
var test_reentry_latched: bool = false;
var test_lease_digest: external_owner_seal.Digest = [_]u8{0x11} ** 32;
var test_owner_digest: external_owner_seal.Digest = [_]u8{0x22} ** 32;

fn testBinding(
    storage: *[64]u8,
    client: *[64]u8,
) OwnerBinding {
    test_owner_incarnation = 7;
    test_operation_generation = 11;
    test_reentry_latched = false;
    test_lease_digest = [_]u8{0x11} ** 32;
    test_owner_digest = [_]u8{0x22} ** 32;
    return .{
        .purpose = .admission,
        .storage_addr = @intFromPtr(storage),
        .storage_len = storage.len,
        .client_addr = @intFromPtr(client),
        .client_len = client.len,
        .lease_addr = @intFromPtr(storage) + 1,
        .lease_len = 1,
        .scratch_addr = @intFromPtr(storage) + 2,
        .scratch_len = 1,
        .write_scratch_addr = @intFromPtr(storage) + 3,
        .write_scratch_len = 1,
        .allocator_ptr_addr = @intFromPtr(std.testing.allocator.ptr),
        .allocator_context_len = 1,
        .allocator_vtable_addr = @intFromPtr(std.testing.allocator.vtable),
        .owner_incarnation = 7,
        .operation_generation = 11,
    };
}

test "f1a zero-policy admission commits one immutable wire without request mutation" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 41 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;

    const result = admit(
        std.testing.allocator,
        &state,
        &request_ids,
        testBinding(&storage, &client),
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "abc",
            .request_policy = .zero,
        },
        100,
    );
    const admitted = switch (result) {
        .admitted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, 0), admitted.request_id);
    try std.testing.expectEqual(protocol.header_size + 3, admitted.wire_len);
    try std.testing.expectEqual(@as(usize, 1), state.external_tx.items.len);
    try std.testing.expectEqual(admitted.wire_len, state.external_tx_bytes);
    try std.testing.expectEqual(@as(u64, 2), state.tx_queue_generation);
    try std.testing.expectEqual(@as(?i128, 100), state.tx_head_progress_baseline_ns);
    try std.testing.expectEqual(@as(?i128, 100), state.tx_last_observed_now_ns);
    try std.testing.expect(std.meta.eql(
        request_ids,
        client_pump.RequestIdState{ .available = 41 },
    ));

    const frame = state.external_tx.items[0];
    try std.testing.expectEqual(@as(usize, 0), frame.offset);
    try std.testing.expectEqual(protocol.Kind.input_bytes, frame.kind);
    try std.testing.expectEqual(@as(u64, 7), frame.stream_id);
    try std.testing.expectEqual(@as(u64, 0), frame.request_id);
    try std.testing.expectEqual(@as(i128, 100), frame.activated_at_ns);
    const header: *const [protocol.header_size]u8 =
        @ptrCast(frame.bytes[0..protocol.header_size]);
    const decoded = try protocol.Header.decode(header);
    try std.testing.expectEqual(protocol.Kind.input_bytes, decoded.kind);
    try std.testing.expectEqual(@as(u64, 0), decoded.request_id);
    try std.testing.expectEqual(@as(u64, 7), decoded.stream_id);
    try std.testing.expectEqualSlices(u8, "abc", frame.bytes[protocol.header_size..]);
}

test "f1a reserve admission emits max once and exhaustion is wire zero" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids: client_pump.RequestIdState = .last_available;
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);

    const first = admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .request,
            .stream_id = 0,
            .payload = "{}",
            .request_policy = .reserve,
        },
        100,
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        first.admitted.request_id,
    );
    try std.testing.expect(request_ids == .max_consumed);
    const before_len = state.external_tx.items.len;
    const before_bytes = state.external_tx_bytes;
    const before_generation = state.tx_queue_generation;
    const second = admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .request,
            .stream_id = 0,
            .payload = "{}",
            .request_policy = .reserve,
        },
        101,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.request_id_exhausted,
        second.terminal,
    );
    try std.testing.expectEqual(before_len, state.external_tx.items.len);
    try std.testing.expectEqual(before_bytes, state.external_tx_bytes);
    try std.testing.expectEqual(before_generation, state.tx_queue_generation);
}

test "f1a rejects backwards clock and policy mismatch before allocation" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    state.tx_last_observed_now_ns = 100;
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);

    const backwards = admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .zero,
        },
        99,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.deadline_exceeded,
        backwards.terminal,
    );
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_bytes);

    const mismatch = admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .reserve,
        },
        100,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.protocol_error,
        mismatch.terminal,
    );
    try std.testing.expect(std.meta.eql(
        request_ids,
        client_pump.RequestIdState{ .available = 1 },
    ));
}

test "f1a exact resident and frame caps backpressure without partial mutation" {
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);

    var byte_state = try initState();
    defer byte_state.deinit(std.testing.allocator);
    var byte_requests = client_pump.RequestIdState{ .available = 1 };
    const payload = try std.testing.allocator.alloc(
        u8,
        protocol.max_binary_chunk,
    );
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x5a);
    const exact = admit(
        std.testing.allocator,
        &byte_state,
        &byte_requests,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = payload,
            .request_policy = .zero,
        },
        1,
    );
    try std.testing.expectEqual(max_resident_bytes, exact.admitted.wire_len);
    const before_generation = byte_state.tx_queue_generation;
    const over_bytes = admit(
        std.testing.allocator,
        &byte_state,
        &byte_requests,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "",
            .request_policy = .zero,
        },
        2,
    );
    try std.testing.expect(over_bytes == .backpressure);
    try std.testing.expectEqual(
        max_resident_bytes,
        byte_state.external_tx_bytes,
    );
    try std.testing.expectEqual(
        before_generation,
        byte_state.tx_queue_generation,
    );

    var frame_state = try initState();
    defer frame_state.deinit(std.testing.allocator);
    var frame_requests = client_pump.RequestIdState{ .available = 1 };
    for (0..client_external_mode.max_tx_frames) |index| {
        const admitted = admit(
            std.testing.allocator,
            &frame_state,
            &frame_requests,
            binding,
            .{
                .kind = .input_bytes,
                .stream_id = 7,
                .payload = "",
                .request_policy = .zero,
            },
            @intCast(index + 1),
        );
        try std.testing.expect(admitted == .admitted);
    }
    const frame_generation = frame_state.tx_queue_generation;
    const over_frames = admit(
        std.testing.allocator,
        &frame_state,
        &frame_requests,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "",
            .request_policy = .zero,
        },
        65,
    );
    try std.testing.expect(over_frames == .backpressure);
    try std.testing.expectEqual(
        client_external_mode.max_tx_frames,
        frame_state.external_tx.items.len,
    );
    try std.testing.expectEqual(
        frame_generation,
        frame_state.tx_queue_generation,
    );
}

test "f1a allocation failure preserves queue resident and reserved request state" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids: client_pump.RequestIdState = .last_available;
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    const failing_allocator = failing.allocator();
    state.tx_allocator = failing_allocator;
    state.tx_allocator_context_len = 1;
    var binding = testBinding(&storage, &client);
    binding.allocator_ptr_addr = @intFromPtr(failing_allocator.ptr);
    binding.allocator_context_len = 1;
    binding.allocator_vtable_addr = @intFromPtr(failing_allocator.vtable);
    const result = admit(
        failing_allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .request,
            .stream_id = 0,
            .payload = "{}",
            .request_policy = .reserve,
        },
        100,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.resource_exhausted,
        result.terminal,
    );
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_bytes);
    try std.testing.expectEqual(@as(u64, 1), state.tx_queue_generation);
    try std.testing.expect(std.meta.eql(
        request_ids,
        client_pump.RequestIdState.last_available,
    ));
    state.tx_allocator = std.testing.allocator;
    state.tx_allocator_context_len = 1;
    binding.allocator_ptr_addr = @intFromPtr(std.testing.allocator.ptr);
    binding.allocator_context_len = 1;
    binding.allocator_vtable_addr =
        @intFromPtr(std.testing.allocator.vtable);
    const reused = admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .request,
            .stream_id = 0,
            .payload = "{}",
            .request_policy = .reserve,
        },
        101,
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        reused.admitted.request_id,
    );
    try std.testing.expect(request_ids == .max_consumed);
}

test "f1a allocator callback request and payload drift publish no admission mutation" {
    inline for (.{ DriftMode.request_state, DriftMode.payload_bytes }) |mode| {
        var state = try initState();
        defer state.deinit(std.testing.allocator);
        var request_ids = client_pump.RequestIdState{ .available = 7 };
        const request_before = request_ids;
        var payload = [_]u8{ 0x41, 0x42, 0x43 };
        const payload_before = payload;
        var storage: [64]u8 = undefined;
        var client: [64]u8 = undefined;
        var drift = DriftAllocator{
            .parent = std.testing.allocator,
            .state = &state,
            .request_ids = &request_ids,
            .payload = &payload,
            .mode = mode,
        };
        const allocator = drift.allocator();
        state.tx_allocator = allocator;
        state.tx_allocator_context_len = @sizeOf(DriftAllocator);
        var binding = testBinding(&storage, &client);
        binding.allocator_ptr_addr = @intFromPtr(allocator.ptr);
        binding.allocator_context_len = @sizeOf(DriftAllocator);
        binding.allocator_vtable_addr = @intFromPtr(allocator.vtable);
        const result = admit(
            allocator,
            &state,
            &request_ids,
            binding,
            .{
                .kind = if (mode == .request_state)
                    .request
                else
                    .input_bytes,
                .stream_id = if (mode == .request_state) 0 else 7,
                .payload = &payload,
                .request_policy = if (mode == .request_state)
                    .reserve
                else
                    .zero,
            },
            100,
        );
        try std.testing.expectEqual(
            client_pump.TerminalReason.invariant_failure,
            result.terminal,
        );
        try std.testing.expectEqual(@as(usize, 1), drift.alloc_calls);
        try std.testing.expectEqual(@as(usize, 1), drift.free_calls);
        try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
        try std.testing.expectEqual(@as(usize, 0), state.external_tx_bytes);
        try std.testing.expectEqual(@as(u64, 1), state.tx_queue_generation);
        if (mode == .request_state) {
            try std.testing.expect(request_ids == .max_consumed);
            try std.testing.expectEqualSlices(u8, &payload_before, &payload);
        } else {
            try std.testing.expect(std.meta.eql(request_before, request_ids));
            try std.testing.expect(payload[0] != payload_before[0]);
            try std.testing.expectEqualSlices(
                u8,
                payload_before[1..],
                payload[1..],
            );
        }
    }
}

test "f1a exhausted queue generation rejects admission without wrap" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    state.tx_queue_generation = std.math.maxInt(u64);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const result = admit(
        std.testing.allocator,
        &state,
        &request_ids,
        testBinding(&storage, &client),
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .zero,
        },
        100,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        result.terminal,
    );
    try std.testing.expectEqual(std.math.maxInt(u64), state.tx_queue_generation);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
}

test "f1a committed prepared replay is allocation zero regardless of address reuse" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    var allocator_probe = DriftAllocator{
        .parent = std.testing.allocator,
        .state = &state,
        .mode = .none,
    };
    const allocator = allocator_probe.allocator();
    state.tx_allocator = allocator;
    state.tx_allocator_context_len = @sizeOf(DriftAllocator);
    var prepared: PreparedTxAdmission = .{};
    var binding = testBinding(&storage, &client);
    binding.scratch_addr = @intFromPtr(&prepared);
    binding.scratch_len = @sizeOf(PreparedTxAdmission);
    binding.write_scratch_addr = @intFromPtr(&prepared);
    binding.write_scratch_len = @sizeOf(PreparedTxAdmission);
    binding.allocator_ptr_addr = @intFromPtr(allocator.ptr);
    binding.allocator_context_len = @sizeOf(DriftAllocator);
    binding.allocator_vtable_addr = @intFromPtr(allocator.vtable);
    const first = admitFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        &prepared,
        allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .zero,
        },
        100,
    );
    try std.testing.expect(first == .admitted);
    try std.testing.expectEqual(@as(usize, 1), allocator_probe.alloc_calls);
    const generation = state.tx_queue_generation;
    const replay = admitFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        &prepared,
        allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "y",
            .request_policy = .zero,
        },
        101,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        replay.terminal,
    );
    try std.testing.expectEqual(@as(usize, 1), allocator_probe.alloc_calls);
    try std.testing.expectEqual(@as(usize, 1), state.external_tx.items.len);
    try std.testing.expectEqual(generation, state.tx_queue_generation);
}

const AliasAllocator = struct {
    address: [*]u8,
    available: usize,
    parent_for_free: ?std.mem.Allocator = null,
    alloc_calls: usize = 0,
    free_calls: usize = 0,

    fn allocator(self: *AliasAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        raw: *anyopaque,
        len: usize,
        _: std.mem.Alignment,
        _: usize,
    ) ?[*]u8 {
        const self: *AliasAllocator = @ptrCast(@alignCast(raw));
        self.alloc_calls += 1;
        if (len > self.available) return null;
        return self.address;
    }

    fn resize(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) bool {
        return false;
    }

    fn remap(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) ?[*]u8 {
        return null;
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *AliasAllocator = @ptrCast(@alignCast(raw));
        self.free_calls += 1;
        if (self.parent_for_free) |parent|
            parent.rawFree(memory, alignment, ret_addr);
    }
};

const DriftMode = enum {
    none,
    forged_queue_pointer,
    owner_digest,
    request_state,
    payload_bytes,
    cleanup_free_drift,
    cancellation_cleanup_drift,
};

const DriftAllocator = struct {
    parent: std.mem.Allocator,
    state: *client_external_mode.State,
    request_ids: ?*client_pump.RequestIdState = null,
    payload: ?[]u8 = null,
    mode: DriftMode,
    backing: [max_resident_bytes]u8 = undefined,
    alloc_calls: usize = 0,
    free_calls: usize = 0,

    fn allocator(self: *DriftAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *DriftAllocator = @ptrCast(@alignCast(raw));
        self.alloc_calls += 1;
        switch (self.mode) {
            .none => return self.parent.rawAlloc(len, alignment, ret_addr),
            .forged_queue_pointer => {
                self.state.external_tx.items = @as(
                    [*]client_external_mode.ExternalTxFrame,
                    @ptrFromInt(@alignOf(client_external_mode.ExternalTxFrame)),
                )[0..1];
            },
            .request_state => {
                const request_ids = self.request_ids orelse return null;
                request_ids.* = .max_consumed;
                return self.parent.rawAlloc(len, alignment, ret_addr);
            },
            .payload_bytes => {
                const payload = self.payload orelse return null;
                if (payload.len != 0) payload[0] ^= 0xff;
                return self.parent.rawAlloc(len, alignment, ret_addr);
            },
            .owner_digest, .cleanup_free_drift => {
                test_owner_digest[0] ^= 0xff;
                return self.parent.rawAlloc(len, alignment, ret_addr);
            },
            .cancellation_cleanup_drift => return self.parent.rawAlloc(len, alignment, ret_addr),
        }
        if (len > self.backing.len) return null;
        return &self.backing;
    }

    fn resize(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) bool {
        return false;
    }

    fn remap(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) ?[*]u8 {
        return null;
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *DriftAllocator = @ptrCast(@alignCast(raw));
        self.free_calls += 1;
        if (self.mode == .none or
            self.mode == .owner_digest or
            self.mode == .request_state or
            self.mode == .payload_bytes or
            self.mode == .cleanup_free_drift or
            self.mode == .cancellation_cleanup_drift)
        {
            self.parent.rawFree(memory, alignment, ret_addr);
        }
        if (self.mode == .cleanup_free_drift)
            self.state.tx_queue_generation += 1;
        if (self.mode == .cancellation_cleanup_drift)
            self.state.tx_queue_generation += 1;
    }
};

test "f1a allocator alias is never written or freed and charges quarantine once" {
    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = [_]u8{0xa5} ** 64;
    const storage_before = storage;
    var client: [64]u8 = undefined;
    var alias = AliasAllocator{
        .address = &storage,
        .available = storage.len,
    };
    const alias_allocator = alias.allocator();
    state.tx_allocator = alias_allocator;
    state.tx_allocator_context_len = @sizeOf(AliasAllocator);
    var binding = testBinding(&storage, &client);
    binding.allocator_ptr_addr = @intFromPtr(alias_allocator.ptr);
    binding.allocator_context_len = @sizeOf(AliasAllocator);
    binding.allocator_vtable_addr = @intFromPtr(alias_allocator.vtable);
    const result = admit(
        alias_allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .zero,
        },
        100,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        result.terminal,
    );
    try std.testing.expectEqual(@as(usize, 1), alias.alloc_calls);
    try std.testing.expectEqual(@as(usize, 0), alias.free_calls);
    try std.testing.expectEqualSlices(u8, &storage_before, &storage);
    try std.testing.expectEqual(
        protocol.header_size + 1,
        state.external_tx_quarantined_bytes,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        client_external_mode.txQuarantineEventsForTest(),
    );
    try std.testing.expectEqual(
        protocol.header_size + 1,
        client_external_mode.txQuarantineBytesForTest(),
    );
}

test "f1a allocator partial alias is rejected before write and free" {
    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [128]u8 = [_]u8{0xa5} ** 128;
    const storage_before = storage;
    var client: [64]u8 = undefined;
    var alias = AliasAllocator{
        .address = storage[16..].ptr,
        .available = storage.len - 16,
    };
    const alias_allocator = alias.allocator();
    state.tx_allocator = alias_allocator;
    state.tx_allocator_context_len = @sizeOf(AliasAllocator);
    var binding = testBinding(
        @ptrCast(storage[0..64]),
        &client,
    );
    binding.storage_addr = @intFromPtr(&storage);
    binding.storage_len = storage.len;
    binding.allocator_ptr_addr = @intFromPtr(alias_allocator.ptr);
    binding.allocator_context_len = @sizeOf(AliasAllocator);
    binding.allocator_vtable_addr = @intFromPtr(alias_allocator.vtable);
    const result = admit(
        alias_allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .zero,
        },
        100,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        result.terminal,
    );
    try std.testing.expectEqual(@as(usize, 1), alias.alloc_calls);
    try std.testing.expectEqual(@as(usize, 0), alias.free_calls);
    try std.testing.expectEqualSlices(u8, &storage_before, &storage);
    try std.testing.expectEqual(
        protocol.header_size + 1,
        state.external_tx_quarantined_bytes,
    );
}

test "f1a allocator near-max range overflow is rejected before dereference or free" {
    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const wire_len = protocol.header_size + 1;
    const overflowing_address =
        std.math.maxInt(usize) - wire_len / 2;
    var alias = AliasAllocator{
        .address = @ptrFromInt(overflowing_address),
        .available = std.math.maxInt(usize),
    };
    const alias_allocator = alias.allocator();
    state.tx_allocator = alias_allocator;
    state.tx_allocator_context_len = @sizeOf(AliasAllocator);
    var binding = testBinding(&storage, &client);
    binding.allocator_ptr_addr = @intFromPtr(alias_allocator.ptr);
    binding.allocator_context_len = @sizeOf(AliasAllocator);
    binding.allocator_vtable_addr = @intFromPtr(alias_allocator.vtable);
    const result = admit(
        alias_allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .zero,
        },
        100,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        result.terminal,
    );
    try std.testing.expectEqual(@as(usize, 1), alias.alloc_calls);
    try std.testing.expectEqual(@as(usize, 0), alias.free_calls);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_bytes);
    try std.testing.expectEqual(@as(u64, 1), state.tx_queue_generation);
    try std.testing.expectEqual(
        wire_len,
        state.external_tx_quarantined_bytes,
    );
}

test "f1a callback forged queue pointer is rejected before dereference or free" {
    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    const saved_items = state.external_tx.items;
    const saved_capacity = state.external_tx.capacity;
    defer {
        state.external_tx.items = saved_items;
        state.external_tx.capacity = saved_capacity;
        state.deinit(std.testing.allocator);
    }
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    var drift = DriftAllocator{
        .parent = std.testing.allocator,
        .state = &state,
        .mode = .forged_queue_pointer,
    };
    const allocator = drift.allocator();
    state.tx_allocator = allocator;
    state.tx_allocator_context_len = @sizeOf(DriftAllocator);
    var binding = testBinding(&storage, &client);
    binding.allocator_ptr_addr = @intFromPtr(allocator.ptr);
    binding.allocator_context_len = @sizeOf(DriftAllocator);
    binding.allocator_vtable_addr = @intFromPtr(allocator.vtable);

    const result = admit(
        allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .zero,
        },
        100,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        result.terminal,
    );
    try std.testing.expectEqual(@as(usize, 1), drift.alloc_calls);
    try std.testing.expectEqual(@as(usize, 0), drift.free_calls);
    try std.testing.expectEqual(
        protocol.header_size + 1,
        state.external_tx_quarantined_bytes,
    );
    try std.testing.expect(std.meta.eql(
        request_ids,
        client_pump.RequestIdState{ .available = 1 },
    ));
}

test "f1a owner seal drift rolls max-minus-one request back for exact reuse" {
    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{
        .available = std.math.maxInt(u64) - 1,
    };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    var drift = DriftAllocator{
        .parent = std.testing.allocator,
        .state = &state,
        .mode = .owner_digest,
    };
    const allocator = drift.allocator();
    state.tx_allocator = allocator;
    state.tx_allocator_context_len = @sizeOf(DriftAllocator);
    var binding = testBinding(&storage, &client);
    binding.allocator_ptr_addr = @intFromPtr(allocator.ptr);
    binding.allocator_context_len = @sizeOf(DriftAllocator);
    binding.allocator_vtable_addr = @intFromPtr(allocator.vtable);

    const result = admit(
        allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .request,
            .stream_id = 0,
            .payload = "{}",
            .request_policy = .reserve,
        },
        100,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        result.terminal,
    );
    try std.testing.expectEqual(@as(usize, 1), drift.alloc_calls);
    try std.testing.expectEqual(@as(usize, 1), drift.free_calls);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_bytes);
    try std.testing.expect(std.meta.eql(
        request_ids,
        client_pump.RequestIdState{
            .available = std.math.maxInt(u64) - 1,
        },
    ));
    state.tx_allocator = std.testing.allocator;
    state.tx_allocator_context_len = 1;
    binding = testBinding(&storage, &client);
    binding.allocator_ptr_addr = @intFromPtr(std.testing.allocator.ptr);
    binding.allocator_context_len = 1;
    binding.allocator_vtable_addr =
        @intFromPtr(std.testing.allocator.vtable);
    const reused = admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .request,
            .stream_id = 0,
            .payload = "{}",
            .request_policy = .reserve,
        },
        101,
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64) - 1,
        reused.admitted.request_id,
    );
    try std.testing.expect(request_ids == .last_available);
}

test "f1a cleanup free callback drift quarantines once and replay allocates zero" {
    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 9 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    var drift = DriftAllocator{
        .parent = std.testing.allocator,
        .state = &state,
        .mode = .cleanup_free_drift,
    };
    const allocator = drift.allocator();
    state.tx_allocator = allocator;
    state.tx_allocator_context_len = @sizeOf(DriftAllocator);
    var binding = testBinding(&storage, &client);
    binding.allocator_ptr_addr = @intFromPtr(allocator.ptr);
    binding.allocator_context_len = @sizeOf(DriftAllocator);
    binding.allocator_vtable_addr = @intFromPtr(allocator.vtable);
    const result = admit(
        allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .request,
            .stream_id = 0,
            .payload = "{}",
            .request_policy = .reserve,
        },
        100,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        result.terminal,
    );
    try std.testing.expectEqual(@as(usize, 1), drift.alloc_calls);
    try std.testing.expectEqual(@as(usize, 1), drift.free_calls);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
    try std.testing.expect(std.meta.eql(
        request_ids,
        client_pump.RequestIdState{ .available = 9 },
    ));
    const wire_len = protocol.header_size + 2;
    try std.testing.expectEqual(
        wire_len,
        state.external_tx_quarantined_bytes,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        client_external_mode.txQuarantineEventsForTest(),
    );
    binding = testBinding(&storage, &client);
    binding.allocator_ptr_addr = @intFromPtr(allocator.ptr);
    binding.allocator_context_len = @sizeOf(DriftAllocator);
    binding.allocator_vtable_addr = @intFromPtr(allocator.vtable);
    const replay = admit(
        allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .request,
            .stream_id = 0,
            .payload = "{}",
            .request_policy = .reserve,
        },
        101,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        replay.terminal,
    );
    try std.testing.expectEqual(@as(usize, 1), drift.alloc_calls);
    try std.testing.expectEqual(@as(usize, 1), drift.free_calls);
    try std.testing.expectEqual(
        @as(u64, 1),
        client_external_mode.txQuarantineEventsForTest(),
    );
}

test "f1a allocator cannot alias an immutable queued frame backing" {
    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const first = admit(
        std.testing.allocator,
        &state,
        &request_ids,
        testBinding(&storage, &client),
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = &([_]u8{0x5a} ** 64),
            .request_policy = .zero,
        },
        100,
    );
    try std.testing.expect(first == .admitted);
    const before = state.external_tx.items[0].bytes[0..64].*;

    var alias = AliasAllocator{
        .address = state.external_tx.items[0].bytes.ptr,
        .available = state.external_tx.items[0].bytes.len,
        .parent_for_free = std.testing.allocator,
    };
    const allocator = alias.allocator();
    state.tx_allocator = allocator;
    state.tx_allocator_context_len = @sizeOf(AliasAllocator);
    var prepared: PreparedTxAdmission = .{};
    var binding = testBinding(&storage, &client);
    binding.scratch_addr = @intFromPtr(&prepared);
    binding.scratch_len = @sizeOf(PreparedTxAdmission);
    binding.write_scratch_addr = @intFromPtr(&prepared);
    binding.write_scratch_len = @sizeOf(PreparedTxAdmission);
    binding.allocator_ptr_addr = @intFromPtr(allocator.ptr);
    binding.allocator_context_len = @sizeOf(AliasAllocator);
    binding.allocator_vtable_addr = @intFromPtr(allocator.vtable);
    const second = admitFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        &prepared,
        allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "",
            .request_policy = .zero,
        },
        101,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        second.terminal,
    );
    try std.testing.expectEqual(@as(usize, 1), alias.alloc_calls);
    try std.testing.expectEqual(@as(usize, 0), alias.free_calls);
    try std.testing.expectEqualSlices(
        u8,
        &before,
        state.external_tx.items[0].bytes[0..64],
    );
    try std.testing.expectEqual(@as(usize, 1), state.external_tx.items.len);
    try std.testing.expectEqual(protocol.header_size, state.external_tx_quarantined_bytes);
}

const WriteProbe = struct {
    outcomes: [128]WriteOutcome = [_]WriteOutcome{.would_block} ** 128,
    outcome_count: usize = 0,
    next: usize = 0,
    calls: usize = 0,
    offered: [128]usize = [_]usize{0} ** 128,

    fn ops(self: *WriteProbe) WriteOps {
        return .{ .context = self, .write = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) WriteOutcome {
        const self: *WriteProbe = @ptrCast(@alignCast(context));
        const index = self.calls;
        self.calls += 1;
        self.offered[index] = bytes.len;
        if (self.next >= self.outcome_count) return .would_block;
        const outcome = self.outcomes[self.next];
        self.next += 1;
        return outcome;
    }
};

const RetireFreeDriftAllocator = struct {
    parent: std.mem.Allocator,
    state: *client_external_mode.State,
    free_calls: usize = 0,
    drift_once: bool = true,
    mutate_generation_when_empty: bool = false,

    fn allocator(self: *RetireFreeDriftAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *RetireFreeDriftAllocator = @ptrCast(@alignCast(raw));
        return self.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) bool {
        return false;
    }

    fn remap(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) ?[*]u8 {
        return null;
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *RetireFreeDriftAllocator = @ptrCast(@alignCast(raw));
        self.free_calls += 1;
        self.parent.rawFree(memory, alignment, ret_addr);
        if (self.drift_once) {
            self.drift_once = false;
            if (self.state.external_tx.items.len != 0) {
                self.state.external_tx.items[0].bytes.ptr =
                    @ptrFromInt(@alignOf(u8));
            } else if (self.mutate_generation_when_empty) {
                self.state.tx_queue_generation += 1;
            }
        }
    }
};

test "f1b partial write preserves resident then full write retires exactly once" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);
    const admitted = admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "abc",
            .request_policy = .zero,
        },
        100,
    );
    const wire_len = admitted.admitted.wire_len;
    var first_probe = WriteProbe{ .outcome_count = 2 };
    first_probe.outcomes[0] = .{ .written = 5 };
    const first = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        first_probe.ops(),
        101,
    );
    try std.testing.expectEqual(@as(?client_pump.TerminalReason, null), first.terminal);
    try std.testing.expectEqual(@as(usize, 5), first.accepted_bytes);
    try std.testing.expect(first.would_block);
    try std.testing.expectEqual(@as(usize, 1), state.external_tx.items.len);
    try std.testing.expectEqual(wire_len, state.external_tx_bytes);
    try std.testing.expectEqual(@as(usize, 5), state.external_tx.items[0].offset);

    var second_probe = WriteProbe{ .outcome_count = 1 };
    second_probe.outcomes[0] = .{ .written = wire_len - 5 };
    const second = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        second_probe.ops(),
        102,
    );
    try std.testing.expectEqual(@as(?client_pump.TerminalReason, null), second.terminal);
    try std.testing.expectEqual(wire_len - 5, second.accepted_bytes);
    try std.testing.expectEqual(@as(usize, 1), second.completed_frames);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_bytes);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_retiring_bytes);
    try std.testing.expectEqual(@as(?i128, null), state.tx_head_progress_baseline_ns);
}

test "f2 request progress projects exact offset zero partial and retired states" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 41 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);
    const admitted = admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .request,
            .stream_id = 0,
            .payload = "control",
            .request_policy = .reserve,
        },
        100,
    ).admitted;
    try std.testing.expectEqual(
        RequestFrameProgress.queued,
        requestFrameProgress(&state, admitted.request_id, admitted.wire_len),
    );
    var first_probe = WriteProbe{ .outcome_count = 2 };
    first_probe.outcomes[0] = .{ .written = 5 };
    const first = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        first_probe.ops(),
        101,
    );
    try std.testing.expect(first.terminal == null);
    try std.testing.expectEqual(
        RequestFrameProgress.partial,
        requestFrameProgress(&state, admitted.request_id, admitted.wire_len),
    );
    var second_probe = WriteProbe{ .outcome_count = 1 };
    second_probe.outcomes[0] = .{ .written = admitted.wire_len - 5 };
    const second = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        second_probe.ops(),
        102,
    );
    try std.testing.expect(second.terminal == null);
    try std.testing.expectEqual(
        RequestFrameProgress.missing,
        requestFrameProgress(&state, admitted.request_id, admitted.wire_len),
    );
}

test "f1b deadline is checked before write and EINTR ninth attempt terminalizes" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);
    try std.testing.expect(admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .zero,
        },
        100,
    ) == .admitted);
    var deadline_probe: WriteProbe = .{};
    const expired = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        deadline_probe.ops(),
        100 + progress_timeout_ns,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.deadline_exceeded,
        expired.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 0), deadline_probe.calls);

    state.tx_last_observed_now_ns = 100;
    state.tx_head_progress_baseline_ns = 100;
    var interrupted_probe = WriteProbe{
        .outcomes = [_]WriteOutcome{.interrupted} ** 128,
        .outcome_count = 128,
    };
    const interrupted = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        interrupted_probe.ops(),
        101,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        interrupted.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 9), interrupted_probe.calls);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items[0].offset);
}

test "f1b deadline boundaries and queued-head promotion are deadline first" {
    inline for (.{ progress_timeout_ns - 1, progress_timeout_ns, progress_timeout_ns + 1 }) |elapsed| {
        var state = try initState();
        defer state.deinit(std.testing.allocator);
        var request_ids = client_pump.RequestIdState{ .available = 1 };
        var storage: [64]u8 = undefined;
        var client: [64]u8 = undefined;
        const binding = testBinding(&storage, &client);
        try std.testing.expect(admit(
            std.testing.allocator,
            &state,
            &request_ids,
            binding,
            .{
                .kind = .input_bytes,
                .stream_id = 7,
                .payload = "x",
                .request_policy = .zero,
            },
            0,
        ) == .admitted);
        var probe = WriteProbe{ .outcome_count = 1 };
        probe.outcomes[0] = .would_block;
        const result = writeTurnFromExternalPump(
            testOwnerValid,
            @ptrCast(&state),
            std.testing.allocator,
            &state,
            binding,
            probe.ops(),
            elapsed,
        );
        if (elapsed < progress_timeout_ns) {
            try std.testing.expectEqual(
                @as(?client_pump.TerminalReason, null),
                result.terminal,
            );
            try std.testing.expectEqual(@as(usize, 1), probe.calls);
        } else {
            try std.testing.expectEqual(
                client_pump.TerminalReason.deadline_exceeded,
                result.terminal.?,
            );
            try std.testing.expectEqual(@as(usize, 0), probe.calls);
        }
    }

    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);
    const first = admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "first",
            .request_policy = .zero,
        },
        0,
    );
    try std.testing.expect(first == .admitted);
    try std.testing.expect(admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 8,
            .payload = "second",
            .request_policy = .zero,
        },
        std.time.ns_per_s,
    ) == .admitted);
    state.tx_head_progress_baseline_ns = 29 * std.time.ns_per_s;
    state.tx_last_observed_now_ns = 29 * std.time.ns_per_s;
    var retire_probe = WriteProbe{ .outcome_count = 2 };
    retire_probe.outcomes[0] = .{ .written = first.admitted.wire_len };
    retire_probe.outcomes[1] = .would_block;
    const promoted = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        retire_probe.ops(),
        29 * std.time.ns_per_s,
    );
    try std.testing.expectEqual(
        @as(?client_pump.TerminalReason, null),
        promoted.terminal,
    );
    try std.testing.expectEqual(@as(usize, 1), promoted.completed_frames);
    var expired_probe: WriteProbe = .{};
    const expired = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        expired_probe.ops(),
        31 * std.time.ns_per_s,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.deadline_exceeded,
        expired.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 0), expired_probe.calls);
}

test "f1b absolute deadline boundaries overflow and backwards clock are write zero" {
    inline for (.{ absolute_timeout_ns - 1, absolute_timeout_ns, absolute_timeout_ns + 1 }) |now_ns| {
        var state = try initState();
        defer state.deinit(std.testing.allocator);
        var request_ids = client_pump.RequestIdState{ .available = 1 };
        var storage: [64]u8 = undefined;
        var client: [64]u8 = undefined;
        const binding = testBinding(&storage, &client);
        try std.testing.expect(admit(
            std.testing.allocator,
            &state,
            &request_ids,
            binding,
            .{
                .kind = .input_bytes,
                .stream_id = 7,
                .payload = "x",
                .request_policy = .zero,
            },
            0,
        ) == .admitted);
        state.tx_head_progress_baseline_ns = absolute_timeout_ns - 1;
        state.tx_last_observed_now_ns = absolute_timeout_ns - 1;
        var probe = WriteProbe{ .outcome_count = 1 };
        probe.outcomes[0] = .would_block;
        const result = writeTurnFromExternalPump(
            testOwnerValid,
            @ptrCast(&state),
            std.testing.allocator,
            &state,
            binding,
            probe.ops(),
            now_ns,
        );
        if (now_ns < absolute_timeout_ns) {
            try std.testing.expectEqual(
                @as(?client_pump.TerminalReason, null),
                result.terminal,
            );
            try std.testing.expectEqual(@as(usize, 1), probe.calls);
        } else {
            try std.testing.expectEqual(
                client_pump.TerminalReason.deadline_exceeded,
                result.terminal.?,
            );
            try std.testing.expectEqual(@as(usize, 0), probe.calls);
        }
    }

    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);
    try std.testing.expect(admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .zero,
        },
        100,
    ) == .admitted);
    state.external_tx.items[0].activated_at_ns = std.math.maxInt(i128);
    state.external_tx.items[0].descriptor_digest =
        frameDescriptorDigest(state.external_tx.items[0]);
    var overflow_probe: WriteProbe = .{};
    const overflow = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        overflow_probe.ops(),
        101,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        overflow.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 0), overflow_probe.calls);

    state.external_tx.items[0].activated_at_ns = 100;
    state.external_tx.items[0].descriptor_digest =
        frameDescriptorDigest(state.external_tx.items[0]);
    state.tx_last_observed_now_ns = 100;
    var backwards_probe: WriteProbe = .{};
    const backwards = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        backwards_probe.ops(),
        99,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.deadline_exceeded,
        backwards.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 0), backwards_probe.calls);
}

test "f1b queue generation reaches max once then forbids another syscall" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);
    try std.testing.expect(admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .zero,
        },
        100,
    ) == .admitted);
    state.tx_queue_generation = std.math.maxInt(u64) - 1;
    var first_probe = WriteProbe{ .outcome_count = 1 };
    first_probe.outcomes[0] = .{ .written = 1 };
    const first = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        first_probe.ops(),
        101,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        first.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 1), first_probe.calls);
    try std.testing.expectEqual(std.math.maxInt(u64), state.tx_queue_generation);
    var replay_probe: WriteProbe = .{};
    const replay = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        replay_probe.ops(),
        102,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        replay.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 0), replay_probe.calls);
}

test "f1b poll hint takes bounded minimum and projects immediate latch" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);
    try std.testing.expect(admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .zero,
        },
        100,
    ) == .admitted);
    try std.testing.expect(admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "y",
            .request_policy = .zero,
        },
        200,
    ) == .admitted);
    state.tx_immediate_pending = true;
    const hint = pollHint(&state);
    try std.testing.expect(hint.valid);
    try std.testing.expect(hint.immediate);
    try std.testing.expectEqual(
        @as(?i128, 100 + progress_timeout_ns),
        hint.deadline_ns,
    );
    state.tx_queue_generation = std.math.maxInt(u64);
    const invalid = pollHint(&state);
    try std.testing.expect(!invalid.valid);
    try std.testing.expect(invalid.immediate);
}

test "f1b would-block consumes the immediate latch once without queue mutation" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);
    try std.testing.expect(admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "queued",
            .request_policy = .zero,
        },
        100,
    ) == .admitted);
    state.tx_immediate_pending = true;
    const generation = state.tx_queue_generation;
    const baseline = state.tx_head_progress_baseline_ns;
    var probe = WriteProbe{ .outcome_count = 1 };
    probe.outcomes[0] = .would_block;
    const result = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        probe.ops(),
        101,
    );
    try std.testing.expectEqual(@as(?client_pump.TerminalReason, null), result.terminal);
    try std.testing.expect(result.would_block);
    try std.testing.expect(!result.immediate_tx);
    try std.testing.expect(!state.tx_immediate_pending);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(generation, state.tx_queue_generation);
    try std.testing.expectEqual(baseline, state.tx_head_progress_baseline_ns);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items[0].offset);
}

test "f1b zero socket error and write over-report fail closed without progress" {
    const outcomes = [_]WriteOutcome{
        .zero,
        .socket_error,
        .{ .written = protocol.header_size + 2 },
    };
    const expected = [_]client_pump.TerminalReason{
        .socket_error,
        .socket_error,
        .invariant_failure,
    };
    for (outcomes, expected) |outcome, reason| {
        var state = try initState();
        defer state.deinit(std.testing.allocator);
        var request_ids = client_pump.RequestIdState{ .available = 1 };
        var storage: [64]u8 = undefined;
        var client: [64]u8 = undefined;
        const binding = testBinding(&storage, &client);
        try std.testing.expect(admit(
            std.testing.allocator,
            &state,
            &request_ids,
            binding,
            .{
                .kind = .input_bytes,
                .stream_id = 7,
                .payload = "x",
                .request_policy = .zero,
            },
            100,
        ) == .admitted);
        const generation = state.tx_queue_generation;
        var probe = WriteProbe{ .outcome_count = 1 };
        probe.outcomes[0] = outcome;
        const result = writeTurnFromExternalPump(
            testOwnerValid,
            @ptrCast(&state),
            std.testing.allocator,
            &state,
            binding,
            probe.ops(),
            101,
        );
        try std.testing.expectEqual(reason, result.terminal.?);
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try std.testing.expectEqual(@as(usize, 0), result.accepted_bytes);
        try std.testing.expectEqual(@as(usize, 0), state.external_tx.items[0].offset);
        try std.testing.expectEqual(generation, state.tx_queue_generation);
        try std.testing.expect(!state.tx_immediate_pending);
    }
}

test "f1b callback forged head backing is rejected before content dereference" {
    const ForgingWrite = struct {
        state: *client_external_mode.State,
        calls: usize = 0,

        fn write(raw: *anyopaque, _: []const u8) WriteOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.state.external_tx.items[0].bytes.ptr =
                @ptrFromInt(@alignOf(u8));
            return .would_block;
        }
    };

    var state = try initState();
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);
    try std.testing.expect(admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .zero,
        },
        100,
    ) == .admitted);
    const saved_bytes = state.external_tx.items[0].bytes;
    const saved_frame = state.external_tx.items[0];
    defer {
        state.external_tx.items.len = 1;
        state.external_tx.items[0] = saved_frame;
        state.external_tx.items[0].bytes = saved_bytes;
        state.external_tx_bytes = saved_bytes.len;
        state.external_tx_retiring_bytes = 0;
        state.external_tx_quarantined_bytes = 0;
        state.tx_lifecycle = .live;
        state.tx_head_progress_baseline_ns = 100;
        state.deinit(std.testing.allocator);
    }
    var probe = ForgingWrite{ .state = &state };
    const result = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        .{ .context = &probe, .write = ForgingWrite.write },
        101,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        result.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), result.accepted_bytes);
}

test "f1b callback mutation of the offered wire slice terminalizes before progress" {
    const MutatingWrite = struct {
        calls: usize = 0,

        fn write(raw: *anyopaque, bytes: []const u8) WriteOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            const mutable: []u8 = @constCast(bytes);
            mutable[0] ^= 0xff;
            return .{ .written = 1 };
        }
    };

    var state = try initState();
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);
    try std.testing.expect(admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "x",
            .request_policy = .zero,
        },
        100,
    ) == .admitted);
    const saved_bytes = state.external_tx.items[0].bytes;
    const saved_frame = state.external_tx.items[0];
    const saved_first = saved_bytes[0];
    defer {
        saved_bytes[0] = saved_first;
        state.external_tx.items.len = 1;
        state.external_tx.items[0] = saved_frame;
        state.external_tx_bytes = saved_bytes.len;
        state.external_tx_retiring_bytes = 0;
        state.external_tx_quarantined_bytes = 0;
        state.tx_lifecycle = .live;
        state.tx_head_progress_baseline_ns = 100;
        state.deinit(std.testing.allocator);
    }
    var probe = MutatingWrite{};
    const result = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        .{ .context = &probe, .write = MutatingWrite.write },
        101,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        result.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), result.accepted_bytes);
}

test "f1b one-byte short write adapts subsequent offers without rehash amplification" {
    offered_digest_bytes_for_test = 0;
    queue_digest_bytes_for_test = 0;
    admission_copy_bytes_for_test = 0;
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);
    const payload = try std.testing.allocator.alloc(
        u8,
        protocol.max_binary_chunk,
    );
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x5a);
    try std.testing.expect(admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = payload,
            .request_policy = .zero,
        },
        100,
    ) == .admitted);
    var probe = WriteProbe{ .outcome_count = 128 };
    for (probe.outcomes[0..127]) |*outcome|
        outcome.* = .{ .written = 1 };
    probe.outcomes[127] = .would_block;
    const result = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        probe.ops(),
        101,
    );
    try std.testing.expectEqual(@as(?client_pump.TerminalReason, null), result.terminal);
    try std.testing.expect(result.would_block);
    try std.testing.expectEqual(@as(usize, 128), probe.calls);
    try std.testing.expectEqual(max_turn_write_bytes, probe.offered[0]);
    try std.testing.expectEqual(@as(usize, 1), probe.offered[1]);
    try std.testing.expectEqual(@as(usize, 1), probe.offered[127]);
    try std.testing.expectEqual(@as(usize, 127), result.accepted_bytes);
    try std.testing.expectEqual(
        2 * (max_turn_write_bytes + 127),
        offered_digest_bytes_for_test,
    );
    try std.testing.expectEqual(
        max_resident_bytes,
        queue_digest_bytes_for_test,
    );
    try std.testing.expectEqual(
        max_resident_bytes,
        admission_copy_bytes_for_test,
    );
    try std.testing.expectEqual(
        4 * max_turn_write_bytes + 2 * protocol.header_size + 254,
        queue_digest_bytes_for_test +
            admission_copy_bytes_for_test +
            offered_digest_bytes_for_test,
    );
}

test "f1b retire free callback forged next backing is rejected before dereference" {
    var state = try initState();
    var drift = RetireFreeDriftAllocator{
        .parent = std.testing.allocator,
        .state = &state,
    };
    const allocator = drift.allocator();
    state.tx_allocator = allocator;
    state.tx_allocator_context_len = @sizeOf(RetireFreeDriftAllocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    var binding = testBinding(&storage, &client);
    binding.allocator_ptr_addr = @intFromPtr(allocator.ptr);
    binding.allocator_context_len = @sizeOf(RetireFreeDriftAllocator);
    binding.allocator_vtable_addr = @intFromPtr(allocator.vtable);
    try std.testing.expect(admit(
        allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "first",
            .request_policy = .zero,
        },
        100,
    ) == .admitted);
    try std.testing.expect(admit(
        allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "second",
            .request_policy = .zero,
        },
        101,
    ) == .admitted);
    const first_len = state.external_tx.items[0].bytes.len;
    const saved_second = state.external_tx.items[1];
    defer {
        state.external_tx.items.len = 1;
        state.external_tx.items[0] = saved_second;
        state.external_tx_bytes = saved_second.bytes.len;
        state.external_tx_retiring_bytes = 0;
        state.external_tx_quarantined_bytes = 0;
        state.tx_lifecycle = .live;
        state.tx_head_progress_baseline_ns = 102;
        state.deinit(allocator);
    }
    var probe = WriteProbe{ .outcome_count = 1 };
    probe.outcomes[0] = .{ .written = first_len };
    const result = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        allocator,
        &state,
        binding,
        probe.ops(),
        102,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        result.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), drift.free_calls);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
    try std.testing.expectEqual(
        client_external_mode.TxLifecycle.terminal_tombstone,
        state.tx_lifecycle,
    );
    try std.testing.expectEqual(
        first_len + saved_second.bytes.len,
        state.external_tx_quarantined_bytes,
    );
}

test "f1b sole-frame retire callback drift charges the full frozen frame once" {
    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var drift = RetireFreeDriftAllocator{
        .parent = std.testing.allocator,
        .state = &state,
        .mutate_generation_when_empty = true,
    };
    const allocator = drift.allocator();
    state.tx_allocator = allocator;
    state.tx_allocator_context_len = @sizeOf(RetireFreeDriftAllocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    var binding = testBinding(&storage, &client);
    binding.allocator_ptr_addr = @intFromPtr(allocator.ptr);
    binding.allocator_context_len = @sizeOf(RetireFreeDriftAllocator);
    binding.allocator_vtable_addr = @intFromPtr(allocator.vtable);
    const admitted = admit(
        allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "only",
            .request_policy = .zero,
        },
        100,
    );
    const wire_len = admitted.admitted.wire_len;
    var probe = WriteProbe{ .outcome_count = 1 };
    probe.outcomes[0] = .{ .written = wire_len };
    const result = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        allocator,
        &state,
        binding,
        probe.ops(),
        101,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        result.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 1), drift.free_calls);
    try std.testing.expectEqual(wire_len, state.external_tx_quarantined_bytes);
    try std.testing.expectEqual(
        @as(u64, 1),
        client_external_mode.txQuarantineEventsForTest(),
    );
    try std.testing.expectEqual(
        wire_len,
        client_external_mode.txQuarantineBytesForTest(),
    );
}

test "f1b exact byte budget sets durable immediate and cap plus one makes no syscall" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);
    const payload = try std.testing.allocator.alloc(u8, protocol.max_binary_chunk);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x5a);
    try std.testing.expect(admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = payload,
            .request_policy = .zero,
        },
        100,
    ) == .admitted);
    var first_probe = WriteProbe{ .outcome_count = 2 };
    first_probe.outcomes[0] = .{ .written = max_turn_write_bytes };
    first_probe.outcomes[1] = .{ .written = 1 };
    const first = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        first_probe.ops(),
        101,
    );
    try std.testing.expectEqual(max_turn_write_bytes, first.accepted_bytes);
    try std.testing.expectEqual(@as(usize, 1), first_probe.calls);
    try std.testing.expect(first.immediate_tx);
    try std.testing.expect(state.tx_immediate_pending);
    try std.testing.expectEqual(max_turn_write_bytes, state.external_tx.items[0].offset);

    var second_probe = WriteProbe{ .outcome_count = 1 };
    second_probe.outcomes[0] = .{ .written = protocol.header_size };
    const second = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        second_probe.ops(),
        102,
    );
    try std.testing.expectEqual(protocol.header_size, second.accepted_bytes);
    try std.testing.expectEqual(@as(usize, 1), second.completed_frames);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
    try std.testing.expect(!state.tx_immediate_pending);
}

test "f1b sixty four completed frames preserve FIFO and stop before a sixty fifth call" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    const binding = testBinding(&storage, &client);
    for (0..client_external_mode.max_tx_frames) |index| {
        try std.testing.expect(admit(
            std.testing.allocator,
            &state,
            &request_ids,
            binding,
            .{
                .kind = .input_bytes,
                .stream_id = @intCast(index + 1),
                .payload = "",
                .request_policy = .zero,
            },
            @intCast(index + 1),
        ) == .admitted);
    }
    var probe = WriteProbe{ .outcome_count = 65 };
    for (0..65) |index|
        probe.outcomes[index] = .{ .written = protocol.header_size };
    const result = writeTurnFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        std.testing.allocator,
        &state,
        binding,
        probe.ops(),
        100,
    );
    try std.testing.expectEqual(@as(?client_pump.TerminalReason, null), result.terminal);
    try std.testing.expectEqual(
        client_external_mode.max_tx_frames,
        result.completed_frames,
    );
    try std.testing.expectEqual(
        client_external_mode.max_tx_frames,
        probe.calls,
    );
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_bytes);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_retiring_bytes);
    try std.testing.expect(!result.immediate_tx);
}

test "f1b sealed completion sink preserves FIFO and replay is spent" {
    const Recorder = struct {
        calls: usize = 0,
        semantic_allowed: bool = false,
        count: usize = 0,
        values: [2]TxCompletion = undefined,

        fn consume(
            raw: *anyopaque,
            completions: []const TxCompletion,
            allowed: bool,
        ) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.semantic_allowed = allowed;
            self.count = completions.len;
            if (completions.len > self.values.len) return false;
            @memcpy(self.values[0..completions.len], completions);
            return true;
        }
    };

    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    var binding = testBinding(&storage, &client);
    for ([_]u64{ 7, 8 }) |stream_id|
        try std.testing.expect(admit(
            std.testing.allocator,
            &state,
            &request_ids,
            binding,
            .{
                .kind = .input_bytes,
                .stream_id = stream_id,
                .payload = "",
                .request_policy = .zero,
            },
            @intCast(stream_id),
        ) == .admitted);
    var prepared: PreparedTxWrite = .{};
    binding.purpose = .write_turn;
    binding.write_scratch_addr = @intFromPtr(&prepared);
    binding.write_scratch_len = @sizeOf(PreparedTxWrite);
    var recorder = Recorder{};
    var probe = WriteProbe{ .outcome_count = 2 };
    probe.outcomes[0] = .{ .written = protocol.header_size };
    probe.outcomes[1] = .{ .written = protocol.header_size };
    const sink = CompletionSink{
        .context = &recorder,
        .consume = Recorder.consume,
    };
    const result = writeTurnPreparedFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        &prepared,
        sink,
        std.testing.allocator,
        &state,
        binding,
        probe.ops(),
        100,
    );
    try std.testing.expectEqual(@as(?client_pump.TerminalReason, null), result.terminal);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expect(recorder.semantic_allowed);
    try std.testing.expectEqual(@as(usize, 2), recorder.count);
    try std.testing.expectEqual(@as(u64, 7), recorder.values[0].stream_id);
    try std.testing.expectEqual(@as(u64, 8), recorder.values[1].stream_id);
    try std.testing.expectEqual(CompletionLifecycle.spent, prepared.storage().lifecycle);
    try std.testing.expect(!consumeTxCompletionsUnderHeldLease(
        testOwnerValid,
        @ptrCast(&state),
        &prepared,
        &state,
        binding,
        sink,
        true,
    ));
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
}

test "f1b rejecting completion sink tombstones evidence and replay is callback zero" {
    const RejectingSink = struct {
        calls: usize = 0,

        fn consume(
            raw: *anyopaque,
            _: []const TxCompletion,
            _: bool,
        ) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return false;
        }
    };

    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    var binding = testBinding(&storage, &client);
    try std.testing.expect(admit(
        std.testing.allocator,
        &state,
        &request_ids,
        binding,
        .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = "",
            .request_policy = .zero,
        },
        100,
    ) == .admitted);
    var prepared: PreparedTxWrite = .{};
    binding.purpose = .write_turn;
    binding.write_scratch_addr = @intFromPtr(&prepared);
    binding.write_scratch_len = @sizeOf(PreparedTxWrite);
    var rejecting = RejectingSink{};
    const sink = CompletionSink{
        .context = &rejecting,
        .consume = RejectingSink.consume,
    };
    var probe = WriteProbe{ .outcome_count = 1 };
    probe.outcomes[0] = .{ .written = protocol.header_size };
    const result = writeTurnPreparedFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        &prepared,
        sink,
        std.testing.allocator,
        &state,
        binding,
        probe.ops(),
        101,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        result.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 1), rejecting.calls);
    try std.testing.expectEqual(
        CompletionLifecycle.terminal_tombstone,
        prepared.storage().lifecycle,
    );
    try std.testing.expect(!consumeTxCompletionsUnderHeldLease(
        testOwnerValid,
        @ptrCast(&state),
        &prepared,
        &state,
        binding,
        sink,
        false,
    ));
    try std.testing.expectEqual(@as(usize, 1), rejecting.calls);
}

test "f1b completion sink queue forgery and teardown reentry quarantine before reuse" {
    const ForgingSink = struct {
        state: *client_external_mode.State,
        calls: usize = 0,

        fn consume(
            raw: *anyopaque,
            _: []const TxCompletion,
            _: bool,
        ) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.state.external_tx.items[0].bytes.ptr =
                @ptrFromInt(@alignOf(u8));
            self.state.external_tx.items[0].descriptor_digest =
                client_external_mode.txFrameDescriptorDigest(
                    self.state.external_tx.items[0],
                );
            std.debug.assert(
                self.state.tryDeinit(std.testing.allocator) == .busy,
            );
            return true;
        }
    };

    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    var binding = testBinding(&storage, &client);
    for ([_]u64{ 7, 8 }) |stream_id|
        try std.testing.expect(admit(
            std.testing.allocator,
            &state,
            &request_ids,
            binding,
            .{
                .kind = .input_bytes,
                .stream_id = stream_id,
                .payload = "",
                .request_policy = .zero,
            },
            @intCast(stream_id),
        ) == .admitted);
    const saved_remaining = state.external_tx.items[1];
    defer {
        state.external_tx.items.len = 1;
        state.external_tx.items[0] = saved_remaining;
        state.external_tx_bytes = saved_remaining.bytes.len;
        state.external_tx_retiring_bytes = 0;
        state.external_tx_quarantined_bytes = 0;
        state.tx_lifecycle = .live;
        state.tx_head_progress_baseline_ns = 9;
        state.deinit(std.testing.allocator);
    }
    var prepared: PreparedTxWrite = .{};
    binding.purpose = .write_turn;
    binding.write_scratch_addr = @intFromPtr(&prepared);
    binding.write_scratch_len = @sizeOf(PreparedTxWrite);
    var sink_context = ForgingSink{ .state = &state };
    var probe = WriteProbe{ .outcome_count = 2 };
    probe.outcomes[0] = .{ .written = protocol.header_size };
    probe.outcomes[1] = .would_block;
    const result = writeTurnPreparedFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        &prepared,
        .{ .context = &sink_context, .consume = ForgingSink.consume },
        std.testing.allocator,
        &state,
        binding,
        probe.ops(),
        9,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        result.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 1), sink_context.calls);
    try std.testing.expectEqual(
        client_external_mode.TxLifecycle.terminal_tombstone,
        state.tx_lifecycle,
    );
    try std.testing.expectEqual(
        saved_remaining.bytes.len,
        state.external_tx_quarantined_bytes,
    );
    try std.testing.expectEqual(
        CompletionLifecycle.terminal_tombstone,
        prepared.storage().lifecycle,
    );
}

test "f1b terminal after one completion consumes discard-only evidence" {
    const Recorder = struct {
        calls: usize = 0,
        semantic_allowed: bool = true,
        count: usize = 0,

        fn consume(
            raw: *anyopaque,
            completions: []const TxCompletion,
            allowed: bool,
        ) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.semantic_allowed = allowed;
            self.count = completions.len;
            return true;
        }
    };

    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var storage: [64]u8 = undefined;
    var client: [64]u8 = undefined;
    var binding = testBinding(&storage, &client);
    for ([_]u64{ 7, 8 }) |stream_id|
        try std.testing.expect(admit(
            std.testing.allocator,
            &state,
            &request_ids,
            binding,
            .{
                .kind = .input_bytes,
                .stream_id = stream_id,
                .payload = "",
                .request_policy = .zero,
            },
            @intCast(stream_id),
        ) == .admitted);
    var prepared: PreparedTxWrite = .{};
    binding.purpose = .write_turn;
    binding.write_scratch_addr = @intFromPtr(&prepared);
    binding.write_scratch_len = @sizeOf(PreparedTxWrite);
    var recorder = Recorder{};
    var probe = WriteProbe{ .outcome_count = 2 };
    probe.outcomes[0] = .{ .written = protocol.header_size };
    probe.outcomes[1] = .socket_error;
    const result = writeTurnPreparedFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        &prepared,
        .{ .context = &recorder, .consume = Recorder.consume },
        std.testing.allocator,
        &state,
        binding,
        probe.ops(),
        100,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.socket_error,
        result.terminal.?,
    );
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expect(!recorder.semantic_allowed);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(CompletionLifecycle.spent, prepared.storage().lifecycle);
}

fn cancellationBinding(original: OwnerBinding, prepared: *PreparedTxCancellation) OwnerBinding {
    var binding = original;
    binding.purpose = .cancel_turn;
    binding.write_scratch_addr = @intFromPtr(prepared);
    binding.write_scratch_len = @sizeOf(PreparedTxCancellation);
    return binding;
}

test "f3b validated cancel moves exact input and request while preserving survivor FIFO" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 41 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    try std.testing.expect(admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .input_bytes,
        .stream_id = 7,
        .payload = "input",
        .request_policy = .zero,
    }, 1) == .admitted);
    try std.testing.expect(admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .stream_ack,
        .stream_id = 7,
        .payload = "ack",
        .request_policy = .zero,
    }, 2) == .admitted);
    const request = switch (admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .request,
        .stream_id = 0,
        .payload = "{}",
        .request_policy = .reserve,
    }, 3)) {
        .admitted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const survivor_before = state.external_tx.items[1];
    var prepared: PreparedTxCancellation = .{};
    var permit: TxCancellationCommitPermit = .{};
    var cleanup: FrozenTxCancellationCleanup = .{};
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(CancellationPrepareResult.prepared, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{
        .stream_id = 7,
        .control = .{ .request_id = request.request_id, .wire_len = request.wire_len },
    }, 10));
    var copied_prepared = prepared;
    try std.testing.expect(!validatePreparedCancellation(testOwnerValid, @ptrCast(&state), &copied_prepared, &permit, &state, binding));
    try std.testing.expectEqual(@as(usize, 3), state.external_tx.items.len);
    try std.testing.expect(validatePreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    var copied_permit = permit;
    try std.testing.expect(!consumePreparedCancellationUnderHeldLease(testOwnerValid, @ptrCast(&state), &prepared, &copied_permit, &cleanup, &state, binding));
    try std.testing.expectEqual(@as(usize, 3), state.external_tx.items.len);
    try std.testing.expect(consumePreparedCancellationUnderHeldLease(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    try std.testing.expectEqual(@as(usize, 1), state.external_tx.items.len);
    try std.testing.expectEqual(@intFromPtr(survivor_before.bytes.ptr), @intFromPtr(state.external_tx.items[0].bytes.ptr));
    for (state.external_tx.items.ptr[1..3]) |tail_frame|
        try std.testing.expect(std.mem.allEqual(
            u8,
            std.mem.asBytes(&tail_frame),
            0,
        ));
    try std.testing.expectEqual(CancellationCleanupResult.cleaned, finishCancellationCleanup(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_retiring_bytes);
    try std.testing.expect(queueDigest(&state) != null);
}

test "f3b cancel rejects partial request without queue mutation" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 50 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    const request = switch (admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .request,
        .stream_id = 0,
        .payload = "{}",
        .request_policy = .reserve,
    }, 1)) {
        .admitted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    state.external_tx.items[0].offset = 1;
    state.external_tx.items[0].descriptor_digest = frameDescriptorDigest(state.external_tx.items[0]);
    const generation = state.tx_queue_generation;
    var prepared: PreparedTxCancellation = .{};
    var permit: TxCancellationCommitPermit = .{};
    var cleanup: FrozenTxCancellationCleanup = .{};
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(CancellationPrepareResult.uncancellable, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{
        .stream_id = 7,
        .control = .{ .request_id = request.request_id, .wire_len = request.wire_len },
    }, 10));
    try std.testing.expectEqual(generation, state.tx_queue_generation);
    try std.testing.expectEqual(@as(usize, 1), state.external_tx.items.len);
}

test "f3b cancellation rejects duplicate request identity and cross-state permit" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 60 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    const first = switch (admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .request,
        .stream_id = 0,
        .payload = "{}",
        .request_policy = .reserve,
    }, 1)) {
        .admitted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .request,
        .stream_id = 0,
        .payload = "{}",
        .request_policy = .reserve,
    }, 2);
    state.external_tx.items[1].request_id = first.request_id;
    var duplicate_header = try protocol.Header.decode(@ptrCast(state.external_tx.items[1].bytes.ptr));
    duplicate_header.request_id = first.request_id;
    const duplicate_header_bytes = duplicate_header.encode();
    @memcpy(state.external_tx.items[1].bytes[0..protocol.header_size], &duplicate_header_bytes);
    state.external_tx.items[1].wire_digest = bytesDigest("MARUTXW1", state.external_tx.items[1].bytes);
    state.external_tx.items[1].descriptor_digest = frameDescriptorDigest(state.external_tx.items[1]);
    var prepared: PreparedTxCancellation = .{};
    var permit: TxCancellationCommitPermit = .{};
    var cleanup: FrozenTxCancellationCleanup = .{};
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(CancellationPrepareResult.uncancellable, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{
        .stream_id = 7,
        .control = .{ .request_id = first.request_id, .wire_len = first.wire_len },
    }, 10));

    // A fresh authority-only revoke has a real prepared/permit lifecycle even with no TX target.
    var empty_state = try initState();
    defer empty_state.deinit(std.testing.allocator);
    var empty_prepared: PreparedTxCancellation = .{};
    var empty_permit: TxCancellationCommitPermit = .{};
    var empty_cleanup: FrozenTxCancellationCleanup = .{};
    const empty_binding = cancellationBinding(base, &empty_prepared);
    try std.testing.expectEqual(CancellationPrepareResult.prepared, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&empty_state), &empty_prepared, &empty_permit, &empty_cleanup, &empty_state, empty_binding, .{ .stream_id = 7 }, 10));
    try std.testing.expect(validatePreparedCancellation(testOwnerValid, @ptrCast(&empty_state), &empty_prepared, &empty_permit, &empty_state, empty_binding));
    try std.testing.expect(!consumePreparedCancellationUnderHeldLease(testOwnerValid, @ptrCast(&empty_state), &empty_prepared, &empty_permit, &empty_cleanup, &state, empty_binding));
    const generation = empty_state.tx_queue_generation;
    try std.testing.expect(consumePreparedCancellationUnderHeldLease(testOwnerValid, @ptrCast(&empty_state), &empty_prepared, &empty_permit, &empty_cleanup, &empty_state, empty_binding));
    try std.testing.expectEqual(generation, empty_state.tx_queue_generation);
    try std.testing.expectEqual(CancellationCleanupResult.cleaned, finishCancellationCleanup(testOwnerValid, @ptrCast(&empty_state), &empty_prepared, &empty_permit, &empty_cleanup, &empty_state, empty_binding));
}

test "f3b cancellation cleanup quarantines remaining backing after allocator drift" {
    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    defer {
        test_owner_digest = [_]u8{0x22} ** 32;
        state.external_tx_quarantined_bytes = 0;
        state.external_tx_retiring_bytes = 0;
        state.tx_lifecycle = .live;
        state.deinit(std.testing.allocator);
    }
    var drift = DriftAllocator{
        .parent = std.heap.page_allocator,
        .state = &state,
        .mode = .cancellation_cleanup_drift,
    };
    const allocator = drift.allocator();
    state.tx_allocator = allocator;
    state.tx_allocator_context_len = @sizeOf(DriftAllocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    var base = testBinding(&owner_storage, &owner_client);
    base.allocator_ptr_addr = @intFromPtr(allocator.ptr);
    base.allocator_context_len = @sizeOf(DriftAllocator);
    base.allocator_vtable_addr = @intFromPtr(allocator.vtable);
    for ([_][]const u8{ "one", "two" }) |payload|
        try std.testing.expect(admit(allocator, &state, &request_ids, base, .{
            .kind = .input_bytes,
            .stream_id = 7,
            .payload = payload,
            .request_policy = .zero,
        }, 1) == .admitted);
    var prepared: PreparedTxCancellation = .{};
    var permit: TxCancellationCommitPermit = .{};
    var cleanup: FrozenTxCancellationCleanup = .{};
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(CancellationPrepareResult.prepared, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{ .stream_id = 7 }, 10));
    try std.testing.expect(validatePreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    try std.testing.expect(consumePreparedCancellationUnderHeldLease(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    try std.testing.expectEqual(CancellationCleanupResult.quarantined, finishCancellationCleanup(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    try std.testing.expectEqual(client_external_mode.TxLifecycle.terminal_tombstone, state.tx_lifecycle);
    try std.testing.expect(state.external_tx_quarantined_bytes != 0);
}

test "f3b cancellation snapshots full queue and preserves all survivor order" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    for (0..client_external_mode.max_tx_frames) |index|
        try std.testing.expect(admit(std.testing.allocator, &state, &request_ids, base, .{
            .kind = .input_bytes,
            .stream_id = if (index % 2 == 0) 7 else 8,
            .payload = "",
            .request_policy = .zero,
        }, @intCast(index + 1)) == .admitted);
    var survivor_addresses: [client_external_mode.max_tx_frames / 2]usize = undefined;
    for (0..survivor_addresses.len) |index|
        survivor_addresses[index] = @intFromPtr(state.external_tx.items[index * 2 + 1].bytes.ptr);
    var prepared: PreparedTxCancellation = .{};
    var permit: TxCancellationCommitPermit = .{};
    var cleanup: FrozenTxCancellationCleanup = .{};
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(CancellationPrepareResult.prepared, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{ .stream_id = 7 }, 100));
    try std.testing.expect(validatePreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    try std.testing.expect(consumePreparedCancellationUnderHeldLease(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    try std.testing.expectEqual(survivor_addresses.len, state.external_tx.items.len);
    for (state.external_tx.items, survivor_addresses) |frame, address|
        try std.testing.expectEqual(address, @intFromPtr(frame.bytes.ptr));
    try std.testing.expectEqual(CancellationCleanupResult.cleaned, finishCancellationCleanup(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
}

test "f3b cancellation rejects payload alias with protected owner range" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    try std.testing.expect(admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .input_bytes,
        .stream_id = 7,
        .payload = "x",
        .request_policy = .zero,
    }, 1) == .admitted);
    const saved = state.external_tx.items[0];
    @memcpy(owner_storage[0..saved.bytes.len], saved.bytes);
    state.external_tx.items[0].bytes = owner_storage[0..saved.bytes.len];
    state.external_tx.items[0].wire_digest = bytesDigest("MARUTXW1", state.external_tx.items[0].bytes);
    state.external_tx.items[0].descriptor_digest = frameDescriptorDigest(state.external_tx.items[0]);
    defer state.external_tx.items[0] = saved;
    var prepared: PreparedTxCancellation = .{};
    var permit: TxCancellationCommitPermit = .{};
    var cleanup: FrozenTxCancellationCleanup = .{};
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(CancellationPrepareResult.invalid, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{ .stream_id = 7 }, 10));
    try std.testing.expect(std.mem.allEqual(u8, &prepared.bytes, 0));
}

test "f3b cancellation rejects max generation and backwards clock without mutation" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    try std.testing.expect(admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .input_bytes,
        .stream_id = 7,
        .payload = "x",
        .request_policy = .zero,
    }, 100) == .admitted);
    state.tx_queue_generation = std.math.maxInt(u64) - 1;
    const saved_len = state.external_tx.items.len;
    const saved_bytes = state.external_tx_bytes;
    const saved_generation = state.tx_queue_generation;
    const saved_frame = state.external_tx.items[0];
    var prepared: PreparedTxCancellation = .{};
    var permit: TxCancellationCommitPermit = .{};
    var cleanup: FrozenTxCancellationCleanup = .{};
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(.invalid, prepareCancellationFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        &prepared,
        &permit,
        &cleanup,
        &state,
        binding,
        .{ .stream_id = 7 },
        100,
    ));
    try std.testing.expectEqual(saved_generation, state.tx_queue_generation);
    try std.testing.expectEqual(saved_len, state.external_tx.items.len);
    try std.testing.expectEqual(saved_bytes, state.external_tx_bytes);
    try std.testing.expect(frameMatchesScalar(saved_frame, .{
        .bytes_addr = @intFromPtr(state.external_tx.items[0].bytes.ptr),
        .bytes_len = state.external_tx.items[0].bytes.len,
        .offset = state.external_tx.items[0].offset,
        .kind = state.external_tx.items[0].kind,
        .stream_id = state.external_tx.items[0].stream_id,
        .request_id = state.external_tx.items[0].request_id,
        .activated_at_ns = state.external_tx.items[0].activated_at_ns,
        .wire_digest = state.external_tx.items[0].wire_digest,
        .descriptor_digest = state.external_tx.items[0].descriptor_digest,
    }));
    try std.testing.expect(std.mem.allEqual(u8, &prepared.bytes, 0));

    state.tx_queue_generation = saved_generation - 1;
    try std.testing.expectEqual(.invalid, prepareCancellationFromExternalPump(
        testOwnerValid,
        @ptrCast(&state),
        &prepared,
        &permit,
        &cleanup,
        &state,
        binding,
        .{ .stream_id = 7 },
        99,
    ));
    try std.testing.expectEqual(saved_generation - 1, state.tx_queue_generation);
    try std.testing.expect(std.mem.allEqual(u8, &prepared.bytes, 0));
}

test "f3b cancellation preserves or replaces head clock from survivor identity" {
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);

    var surviving_head = try initState();
    defer surviving_head.deinit(std.testing.allocator);
    var surviving_ids = client_pump.RequestIdState{ .available = 1 };
    for ([_]u64{ 8, 7 }, 0..) |stream_id, index|
        try std.testing.expect(admit(std.testing.allocator, &surviving_head, &surviving_ids, base, .{
            .kind = .input_bytes,
            .stream_id = stream_id,
            .payload = "x",
            .request_policy = .zero,
        }, @intCast(index + 1)) == .admitted);
    surviving_head.tx_head_progress_baseline_ns = 55;
    var prepared_a: PreparedTxCancellation = .{};
    var permit_a: TxCancellationCommitPermit = .{};
    var cleanup_a: FrozenTxCancellationCleanup = .{};
    const binding_a = cancellationBinding(base, &prepared_a);
    try std.testing.expectEqual(.prepared, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&surviving_head), &prepared_a, &permit_a, &cleanup_a, &surviving_head, binding_a, .{ .stream_id = 7 }, 99));
    try std.testing.expectEqual(@as(?i128, 55), prepared_a.storage().projected_head_progress_ns);
    try std.testing.expect(abortPreparedCancellation(testOwnerValid, @ptrCast(&surviving_head), &prepared_a, &permit_a, &surviving_head, binding_a));

    var replaced_head = try initState();
    defer replaced_head.deinit(std.testing.allocator);
    var replaced_ids = client_pump.RequestIdState{ .available = 1 };
    for ([_]u64{ 7, 8 }, 0..) |stream_id, index|
        try std.testing.expect(admit(std.testing.allocator, &replaced_head, &replaced_ids, base, .{
            .kind = .input_bytes,
            .stream_id = stream_id,
            .payload = "x",
            .request_policy = .zero,
        }, @intCast(index + 1)) == .admitted);
    replaced_head.tx_head_progress_baseline_ns = 55;
    var prepared_b: PreparedTxCancellation = .{};
    var permit_b: TxCancellationCommitPermit = .{};
    var cleanup_b: FrozenTxCancellationCleanup = .{};
    const binding_b = cancellationBinding(base, &prepared_b);
    try std.testing.expectEqual(.prepared, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&replaced_head), &prepared_b, &permit_b, &cleanup_b, &replaced_head, binding_b, .{ .stream_id = 7 }, 99));
    try std.testing.expectEqual(@as(?i128, 99), prepared_b.storage().projected_head_progress_ns);
    try std.testing.expect(abortPreparedCancellation(testOwnerValid, @ptrCast(&replaced_head), &prepared_b, &permit_b, &replaced_head, binding_b));
}

test "f3b cancellation abort replay and copied cleanup are fail closed" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    try std.testing.expect(admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .input_bytes,
        .stream_id = 7,
        .payload = "x",
        .request_policy = .zero,
    }, 1) == .admitted);
    var prepared: PreparedTxCancellation = .{};
    var permit: TxCancellationCommitPermit = .{};
    var cleanup: FrozenTxCancellationCleanup = .{};
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(.prepared, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{ .stream_id = 7 }, 2));
    test_owner_digest[0] ^= 0xff;
    try std.testing.expect(!abortPreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    try std.testing.expectEqual(CancellationLifecycle.prepared, prepared.storage().lifecycle);
    try std.testing.expect(std.mem.allEqual(u8, &permit.bytes, 0));
    test_owner_digest[0] ^= 0xff;
    try std.testing.expect(abortPreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    try std.testing.expect(!abortPreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    try std.testing.expectEqual(@as(usize, 1), state.external_tx.items.len);

    prepared = .{};
    permit = .{};
    try std.testing.expectEqual(.prepared, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{ .stream_id = 7 }, 2));
    try std.testing.expect(validatePreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    try std.testing.expect(abortPreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    try std.testing.expect(!abortPreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    try std.testing.expectEqual(@as(usize, 1), state.external_tx.items.len);
}

test "f3b copied cleanup wrong operation and double finish never mutate live owner" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    try std.testing.expect(admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .input_bytes,
        .stream_id = 7,
        .payload = "x",
        .request_policy = .zero,
    }, 1) == .admitted);
    var prepared: PreparedTxCancellation = .{};
    var permit: TxCancellationCommitPermit = .{};
    var cleanup: FrozenTxCancellationCleanup = .{};
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(.prepared, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{ .stream_id = 7 }, 2));
    try std.testing.expectEqual(@as(?i128, null), prepared.storage().projected_head_progress_ns);
    try std.testing.expect(validatePreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    test_owner_digest[0] ^= 0xff;
    try std.testing.expect(!consumePreparedCancellationUnderHeldLease(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    try std.testing.expectEqual(@as(usize, 1), state.external_tx.items.len);
    test_owner_digest[0] ^= 0xff;
    try std.testing.expect(consumePreparedCancellationUnderHeldLease(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    try std.testing.expect(!consumePreparedCancellationUnderHeldLease(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));

    var copied_cleanup = cleanup;
    const retiring = state.external_tx_retiring_bytes;
    const lifecycle = state.tx_lifecycle;
    try std.testing.expectEqual(.invalid, finishCancellationCleanup(testOwnerValid, @ptrCast(&state), &prepared, &permit, &copied_cleanup, &state, binding));
    try std.testing.expectEqual(retiring, state.external_tx_retiring_bytes);
    try std.testing.expectEqual(lifecycle, state.tx_lifecycle);

    var wrong_binding = binding;
    wrong_binding.operation_generation += 1;
    try std.testing.expectEqual(.invalid, finishCancellationCleanup(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, wrong_binding));
    try std.testing.expectEqual(retiring, state.external_tx_retiring_bytes);
    try std.testing.expectEqual(lifecycle, state.tx_lifecycle);

    try std.testing.expectEqual(.cleaned, finishCancellationCleanup(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    try std.testing.expectEqual(.invalid, finishCancellationCleanup(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_retiring_bytes);
    try std.testing.expectEqual(client_external_mode.TxLifecycle.live, state.tx_lifecycle);
}

test "f3b original cleanup descriptor corruption quarantines without allocator callback" {
    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    defer {
        state.external_tx_quarantined_bytes = 0;
        state.external_tx_retiring_bytes = 0;
        state.deinit(std.testing.allocator);
    }
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    try std.testing.expect(admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .input_bytes,
        .stream_id = 7,
        .payload = "x",
        .request_policy = .zero,
    }, 1) == .admitted);
    var prepared: PreparedTxCancellation = .{};
    var permit: TxCancellationCommitPermit = .{};
    var cleanup: FrozenTxCancellationCleanup = .{};
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(.prepared, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{ .stream_id = 7 }, 2));
    try std.testing.expect(validatePreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    try std.testing.expect(consumePreparedCancellationUnderHeldLease(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    const owned_frame = cleanup.storage().frames[0];
    cleanup.storage().frames[0].descriptor_digest[0] ^= 0xff;
    const quarantined = state.external_tx_retiring_bytes;
    try std.testing.expectEqual(.quarantined, finishCancellationCleanup(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    try std.testing.expectEqual(quarantined, state.external_tx_quarantined_bytes);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_retiring_bytes);
    try std.testing.expectEqual(client_external_mode.TxLifecycle.terminal_tombstone, state.tx_lifecycle);
    // The corrupt descriptor path deliberately never called its allocator. Test ownership can
    // reclaim the saved, known-good allocation after observing the terminal state.
    std.testing.allocator.rawFree(owned_frame.bytes, .@"1", @returnAddress());
}

test "f3b original cleanup saved self corruption quarantines through external authority" {
    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    defer {
        state.external_tx_quarantined_bytes = 0;
        state.external_tx_retiring_bytes = 0;
        state.deinit(std.testing.allocator);
    }
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    try std.testing.expect(admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .input_bytes,
        .stream_id = 7,
        .payload = "x",
        .request_policy = .zero,
    }, 1) == .admitted);
    var prepared: PreparedTxCancellation = .{};
    var permit: TxCancellationCommitPermit = .{};
    var cleanup: FrozenTxCancellationCleanup = .{};
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(.prepared, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{ .stream_id = 7 }, 2));
    try std.testing.expect(validatePreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    try std.testing.expect(consumePreparedCancellationUnderHeldLease(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    const owned_frame = cleanup.storage().frames[0];
    cleanup.storage().saved_self_addr +%= 1;
    const quarantined = state.external_tx_retiring_bytes;
    try std.testing.expectEqual(.quarantined, finishCancellationCleanup(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    try std.testing.expectEqual(quarantined, state.external_tx_quarantined_bytes);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_retiring_bytes);
    try std.testing.expectEqual(client_external_mode.TxLifecycle.terminal_tombstone, state.tx_lifecycle);
    std.testing.allocator.rawFree(owned_frame.bytes, .@"1", @returnAddress());
}

test "f3b cleanup queue backing overflow quarantines without trap or free" {
    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    defer {
        state.external_tx_quarantined_bytes = 0;
        state.external_tx_retiring_bytes = 0;
        state.deinit(std.testing.allocator);
    }
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    try std.testing.expect(admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .input_bytes,
        .stream_id = 7,
        .payload = "x",
        .request_policy = .zero,
    }, 1) == .admitted);
    var prepared: PreparedTxCancellation = .{};
    var permit: TxCancellationCommitPermit = .{};
    var cleanup: FrozenTxCancellationCleanup = .{};
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(.prepared, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{ .stream_id = 7 }, 2));
    try std.testing.expect(validatePreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    try std.testing.expect(consumePreparedCancellationUnderHeldLease(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    const owned_frame = cleanup.storage().frames[0];
    const saved_capacity = state.external_tx.capacity;
    state.external_tx.capacity = std.math.maxInt(usize);
    try std.testing.expectEqual(.quarantined, finishCancellationCleanup(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    state.external_tx.capacity = saved_capacity;
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_retiring_bytes);
    try std.testing.expectEqual(client_external_mode.TxLifecycle.terminal_tombstone, state.tx_lifecycle);
    std.testing.allocator.rawFree(owned_frame.bytes, .@"1", @returnAddress());
}

test "f3b corrupt committed snapshot length quarantines without digest bounds trap" {
    client_external_mode.resetTxQuarantineForTest();
    var state = try initState();
    defer {
        state.external_tx_quarantined_bytes = 0;
        state.external_tx_retiring_bytes = 0;
        state.deinit(std.testing.allocator);
    }
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    try std.testing.expect(admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .input_bytes,
        .stream_id = 7,
        .payload = "x",
        .request_policy = .zero,
    }, 1) == .admitted);
    var prepared: PreparedTxCancellation = .{};
    var permit: TxCancellationCommitPermit = .{};
    var cleanup: FrozenTxCancellationCleanup = .{};
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(.prepared, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{ .stream_id = 7 }, 2));
    try std.testing.expect(validatePreparedCancellation(testOwnerValid, @ptrCast(&state), &prepared, &permit, &state, binding));
    try std.testing.expect(consumePreparedCancellationUnderHeldLease(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    const owned_frame = cleanup.storage().frames[0];
    prepared.storage().queue_len = client_external_mode.max_tx_frames + 1;
    try std.testing.expectEqual(.quarantined, finishCancellationCleanup(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding));
    try std.testing.expectEqual(@as(usize, 0), state.external_tx_retiring_bytes);
    try std.testing.expectEqual(client_external_mode.TxLifecycle.terminal_tombstone, state.tx_lifecycle);
    std.testing.allocator.rawFree(owned_frame.bytes, .@"1", @returnAddress());
}

test "f3b cancellation rejects resealed wire header semantic drift" {
    const HeaderDrift = enum { kind, stream_id, request_id, payload_len, flags, major };
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var request_ids = client_pump.RequestIdState{ .available = 1 };
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    try std.testing.expect(admit(std.testing.allocator, &state, &request_ids, base, .{
        .kind = .input_bytes,
        .stream_id = 7,
        .payload = "x",
        .request_policy = .zero,
    }, 1) == .admitted);
    const original_header = try protocol.Header.decode(@ptrCast(state.external_tx.items[0].bytes.ptr));
    const original_header_bytes = original_header.encode();
    const generation = state.tx_queue_generation;
    const queued_bytes = state.external_tx_bytes;
    for ([_]HeaderDrift{ .kind, .stream_id, .request_id, .payload_len, .flags, .major }) |drift| {
        var header = original_header;
        switch (drift) {
            .kind => header.kind = .stream_ack,
            .stream_id => header.stream_id += 1,
            .request_id => header.request_id = 1,
            .payload_len => header.payload_len += 1,
            .flags => header.flags = protocol.Flags.end_stream,
            .major => header.major += 1,
        }
        const encoded = header.encode();
        @memcpy(state.external_tx.items[0].bytes[0..protocol.header_size], &encoded);
        state.external_tx.items[0].wire_digest = bytesDigest("MARUTXW1", state.external_tx.items[0].bytes);
        state.external_tx.items[0].descriptor_digest = frameDescriptorDigest(state.external_tx.items[0]);
        var prepared: PreparedTxCancellation = .{};
        var permit: TxCancellationCommitPermit = .{};
        var cleanup: FrozenTxCancellationCleanup = .{};
        const binding = cancellationBinding(base, &prepared);
        try std.testing.expectEqual(.invalid, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &permit, &cleanup, &state, binding, .{ .stream_id = 7 }, 2));
        try std.testing.expectEqual(generation, state.tx_queue_generation);
        try std.testing.expectEqual(queued_bytes, state.external_tx_bytes);
        try std.testing.expect(std.mem.allEqual(u8, &prepared.bytes, 0));
        try std.testing.expect(std.mem.allEqual(u8, &permit.bytes, 0));
        try std.testing.expect(std.mem.allEqual(u8, &cleanup.bytes, 0));
        @memcpy(state.external_tx.items[0].bytes[0..protocol.header_size], &original_header_bytes);
        state.external_tx.items[0].wire_digest = bytesDigest("MARUTXW1", state.external_tx.items[0].bytes);
        state.external_tx.items[0].descriptor_digest = frameDescriptorDigest(state.external_tx.items[0]);
    }
}

test "f3b cancellation scratch ranges are pairwise disjoint and protected" {
    var state = try initState();
    defer state.deinit(std.testing.allocator);
    var owner_storage: [64]u8 = undefined;
    var owner_client: [64]u8 = undefined;
    const base = testBinding(&owner_storage, &owner_client);
    var prepared: PreparedTxCancellation = .{};
    var shared: [@sizeOf(FrozenTxCancellationCleanup)]u8 align(@alignOf(FrozenTxCancellationCleanup)) =
        [_]u8{0} ** @sizeOf(FrozenTxCancellationCleanup);
    const permit: *TxCancellationCommitPermit = @ptrCast(@alignCast(&shared));
    const cleanup: *FrozenTxCancellationCleanup = @ptrCast(@alignCast(&shared));
    const binding = cancellationBinding(base, &prepared);
    try std.testing.expectEqual(.invalid, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, permit, cleanup, &state, binding, .{ .stream_id = 7 }, 1));
    try std.testing.expect(std.mem.allEqual(u8, &prepared.bytes, 0));
    try std.testing.expect(std.mem.allEqual(u8, &shared, 0));

    var separate_permit: TxCancellationCommitPermit = .{};
    var separate_cleanup: FrozenTxCancellationCleanup = .{};
    var protected_binding = binding;
    protected_binding.storage_addr = @intFromPtr(&separate_permit);
    protected_binding.storage_len = @sizeOf(TxCancellationCommitPermit);
    try std.testing.expectEqual(.invalid, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &separate_permit, &separate_cleanup, &state, protected_binding, .{ .stream_id = 7 }, 1));
    try std.testing.expect(std.mem.allEqual(u8, &prepared.bytes, 0));
    try std.testing.expect(std.mem.allEqual(u8, &separate_permit.bytes, 0));
    try std.testing.expect(std.mem.allEqual(u8, &separate_cleanup.bytes, 0));

    const saved_context_len = state.tx_allocator_context_len;
    state.tx_allocator_context_len = std.math.maxInt(usize);
    var overflow_binding = binding;
    overflow_binding.allocator_context_len = std.math.maxInt(usize);
    try std.testing.expectEqual(.invalid, prepareCancellationFromExternalPump(testOwnerValid, @ptrCast(&state), &prepared, &separate_permit, &separate_cleanup, &state, overflow_binding, .{ .stream_id = 7 }, 1));
    state.tx_allocator_context_len = saved_context_len;
    try std.testing.expect(std.mem.allEqual(u8, &prepared.bytes, 0));
    try std.testing.expect(std.mem.allEqual(u8, &separate_permit.bytes, 0));
    try std.testing.expect(std.mem.allEqual(u8, &separate_cleanup.bytes, 0));
}
