//! Neutral, callback-safe substrate for immutable pending-event preparation.
//!
//! Product routing is intentionally absent in this slice.  This module owns the one stack frame,
//! canonical protected-range union, immutable queue evidence, bounded allocation schedule, and
//! reverse cleanup needed before a later adapter may publish into PendingEventOwner.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const cleanup = @import("event_cleanup_seal.zig");
const event_preparation = @import("runtime_event_preparation.zig");
const prepared_types = @import("runtime_event_prepared_types.zig");
const event_types = @import("runtime_event_types.zig");
const lifetime = @import("runtime_lifetime_owner.zig");
const pending_owner = @import("pending_event_owner.zig");
const pending_control = @import("runtime_pending_control.zig");
const process_seal = @import("process_seal_service.zig");
const generation_event = @import("generation_event_contract.zig");
const client_slot = @import("client_slot.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");
const observation_digest = @import("runtime_observation_digest.zig");

pub const RuntimeObservation = maru.app.RuntimeObservation;
pub const max_protected_inputs = 21;
pub const allocation_role_count = 8;

pub const ProtectedRole = enum(u8) {
    remote_runtime,
    source_payload,
    direct_input_backing,
    pending_controls_backing,
    old_cwd,
    old_cwd_host,
    old_window_title,
    old_ssh_remote_dest,
    old_clipboard_read_target,
    old_foreground_processes,
    old_agent_progress,
    preparation_frame,
    allocator_vtable,
    dto_backing,
    next_cwd,
    next_cwd_host,
    next_window_title,
    next_ssh_remote_dest,
    next_clipboard_read_target,
    next_foreground_processes,
    next_agent_progress,
};

pub const ProtectedRange = struct {
    role_raw: u8 = 0,
    reserved: [7]u8 = [_]u8{0} ** 7,
    start: u64 = 0,
    end_exclusive: u64 = 0,
};

pub const RangeError = error{ InvalidRole, DuplicateRole, Overflow, Capacity, InvalidAlignment };

pub const ProtectedRangeBuilder = struct {
    inputs: [max_protected_inputs]ProtectedRange = [_]ProtectedRange{.{}} ** max_protected_inputs,
    input_count: u8 = 0,
    segments: [max_protected_inputs]ProtectedRange = [_]ProtectedRange{.{}} ** max_protected_inputs,
    segment_count: u8 = 0,

    pub fn add(self: *ProtectedRangeBuilder, role: ProtectedRole, start: u64, len: u64) RangeError!void {
        if (len == 0) return;
        if (start == 0) return error.Overflow;
        const end = std.math.add(u64, start, len) catch return error.Overflow;
        if (end == 0) return error.Overflow;
        for (self.inputs[0..self.input_count]) |value|
            if (value.role_raw == @intFromEnum(role)) return error.DuplicateRole;
        if (self.input_count == max_protected_inputs) return error.Capacity;
        self.inputs[self.input_count] = .{
            .role_raw = @intFromEnum(role),
            .start = start,
            .end_exclusive = end,
        };
        self.input_count += 1;
    }

    pub fn canonicalize(self: *ProtectedRangeBuilder) void {
        self.segments = [_]ProtectedRange{.{}} ** max_protected_inputs;
        self.segment_count = 0;
        var ordered = self.inputs;
        std.mem.sort(ProtectedRange, ordered[0..self.input_count], {}, lessRange);
        for (ordered[0..self.input_count]) |value| {
            if (self.segment_count == 0) {
                self.segments[0] = value;
                self.segment_count = 1;
                continue;
            }
            const tail = &self.segments[self.segment_count - 1];
            if (value.start <= tail.end_exclusive) {
                tail.end_exclusive = @max(tail.end_exclusive, value.end_exclusive);
            } else {
                self.segments[self.segment_count] = value;
                self.segment_count += 1;
            }
        }
    }

    pub fn candidateAllowed(self: *const ProtectedRangeBuilder, start: u64, len: u64, alignment_log2: u8) bool {
        if (start == 0 or len == 0 or alignment_log2 > 63) return false;
        const alignment = @as(u64, 1) << @intCast(alignment_log2);
        if (start & (alignment - 1) != 0) return false;
        const end = std.math.add(u64, start, len) catch return false;
        for (self.segments[0..self.segment_count]) |segment|
            if (start < segment.end_exclusive and end > segment.start) return false;
        return true;
    }
};

fn lessRange(_: void, left: ProtectedRange, right: ProtectedRange) bool {
    return left.start < right.start or
        (left.start == right.start and left.end_exclusive < right.end_exclusive);
}

pub const BufferSnapshot = struct {
    address: u64,
    length_bytes: u64,
    capacity_bytes: u64,
    content_digest: cleanup.Digest,
};

pub const RuntimeSemanticSnapshot = struct {
    runtime_addr: u64,
    observation_addr: u64,
    runtime_incarnation: u64,
    allocator_ptr: u64,
    allocator_vtable: u64,
    observation: cleanup.ObservationCleanupDigestInput,
    direct_input: BufferSnapshot,
    direct_input_offset: u64,
    pending_controls: BufferSnapshot,
    blocking_flush_active_raw: u8,
    resize_generation: u64,
    resize_baseline_present_raw: u8,
    operation_identity: cleanup.RuntimeOperationIdentity,
    source_identity: cleanup.PendingEventIdentity,
};

pub const SnapshotError = error{ InvalidDescriptor, InvalidControl, InvalidScalar };

pub fn snapshotBytes(list: anytype) SnapshotError!BufferSnapshot {
    const T = @TypeOf(list.*.items[0]);
    const len = std.math.mul(u64, list.items.len, @sizeOf(T)) catch return error.InvalidDescriptor;
    const capacity = std.math.mul(u64, list.capacity, @sizeOf(T)) catch return error.InvalidDescriptor;
    if (list.items.len > list.capacity)
        return error.InvalidDescriptor;
    var digest: cleanup.Digest = [_]u8{0} ** 32;
    if (len != 0) std.crypto.hash.Blake3.hash(std.mem.sliceAsBytes(list.items), &digest, .{});
    return .{
        .address = if (capacity == 0) 0 else @intFromPtr(list.items.ptr),
        .length_bytes = len,
        .capacity_bytes = capacity,
        .content_digest = digest,
    };
}

pub fn pendingControlsDigest(values: []const pending_control.RawQueuedRuntimeControl) SnapshotError!cleanup.Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.pending-controls.snapshot.v1");
    for (values) |*raw| {
        const decoded = pending_control.decode(raw) orelse return error.InvalidControl;
        var barrier: [8]u8 = undefined;
        std.mem.writeInt(u64, &barrier, decoded.barrier, .little);
        hasher.update(&barrier);
        const canonical = switch (decoded.control) {
            .scroll_to_bottom => pending_control.RawQueuedRuntimeControl.scrollToBottom(@intCast(decoded.barrier)).?,
            .core_command => |command| pending_control.RawQueuedRuntimeControl.coreCommand(
                @intCast(decoded.barrier),
                pending_control.toCoreCommand(command),
            ).?,
            .observation_probe => |nonce| pending_control.RawQueuedRuntimeControl.observationProbe(
                @intCast(decoded.barrier),
                nonce,
            ).?,
        };
        hasher.update(std.mem.asBytes(&canonical.control));
    }
    var result: cleanup.Digest = undefined;
    hasher.final(&result);
    return result;
}

fn snapshotListDescriptor(list: anytype, allocator: std.mem.Allocator) SnapshotError!cleanup.CleanupDescriptor {
    const T = std.meta.Child(@TypeOf(list.items));
    if (list.items.len != list.capacity) return error.InvalidDescriptor;
    const bytes = std.math.mul(u64, list.items.len, @sizeOf(T)) catch return error.InvalidDescriptor;
    if (bytes == 0) return .{};
    return .{
        .present = 1,
        .address = @intFromPtr(list.items.ptr),
        .length_bytes = bytes,
        .capacity_bytes = bytes,
        .alignment_log2 = std.math.log2_int(usize, @alignOf(T)),
        .allocator_ptr = @intFromPtr(allocator.ptr),
        .allocator_vtable = @intFromPtr(allocator.vtable),
    };
}

fn snapshotObservation(observation: *const RuntimeObservation, allocator: std.mem.Allocator) SnapshotError!cleanup.ObservationCleanupDigestInput {
    const graph: cleanup.ObservationCleanupGraph = .{
        .cwd = try snapshotListDescriptor(observation.cwd, allocator),
        .cwd_host = try snapshotListDescriptor(observation.cwd_host, allocator),
        .window_title = try snapshotListDescriptor(observation.window_title, allocator),
        .ssh_remote_dest = try snapshotListDescriptor(observation.ssh_remote_dest, allocator),
        .clipboard_read_target = try snapshotListDescriptor(observation.clipboard_read_target, allocator),
        .foreground_processes = try snapshotListDescriptor(observation.foreground_processes, allocator),
        .agent_progress = try snapshotListDescriptor(observation.agent_progress, allocator),
    };
    return observation_digest.input(observation, graph) catch error.InvalidScalar;
}

pub fn snapshotRuntimeContext(
    context: RuntimePreparationContext,
    runtime_incarnation: u64,
    operation_identity: cleanup.RuntimeOperationIdentity,
    source_identity: cleanup.PendingEventIdentity,
) SnapshotError!RuntimeSemanticSnapshot {
    if (context.runtime_addr == 0 or runtime_incarnation == 0 or
        context.direct_input_offset.* > context.direct_input.items.len)
        return error.InvalidScalar;
    var controls = try snapshotBytes(context.pending_controls);
    controls.content_digest = try pendingControlsDigest(context.pending_controls.items);
    return .{
        .runtime_addr = context.runtime_addr,
        .observation_addr = @intFromPtr(context.observation),
        .runtime_incarnation = runtime_incarnation,
        .allocator_ptr = @intFromPtr(context.allocator.ptr),
        .allocator_vtable = @intFromPtr(context.allocator.vtable),
        .observation = try snapshotObservation(context.observation, context.allocator),
        .direct_input = try snapshotBytes(context.direct_input),
        .direct_input_offset = context.direct_input_offset.*,
        .pending_controls = controls,
        .blocking_flush_active_raw = @intFromBool(context.blocking_flush_active.*),
        .resize_generation = context.resize_generation.*,
        .resize_baseline_present_raw = @intFromBool(context.resize_baseline_present.*),
        .operation_identity = operation_identity,
        .source_identity = source_identity,
    };
}

fn classificationFromSourceView(view: generation_event.PreparationEventView) event_types.Classification {
    return switch (view.event.admission) {
        .unknown => .{ .violation = .unknown_event },
        .accepted => |preflight| .{ .accepted = switch (preflight.event) {
            .revoked => |value| .{ .revoked = value.controller_generation },
            .invalidated => .invalidated,
            .resized => |value| .{ .resized = value },
            .metadata => .{ .metadata = .{ .classifier_preflight = preflight } },
            .ended => .ended,
        } },
    };
}

pub fn recipeFromSourceView(view: generation_event.PreparationEventView) event_preparation.RecipeError!event_preparation.EventPreparationRecipe {
    return event_preparation.buildEventPreparationRecipe(
        classificationFromSourceView(view),
        view.event.payload,
    );
}

pub const PreparationScratch = struct {
    dto_backing: std.ArrayListUnmanaged(u8) = .empty,
    next_observation: RuntimeObservation = .{},
    descriptors: [allocation_role_count]cleanup.CleanupDescriptor = [_]cleanup.CleanupDescriptor{.{}} ** allocation_role_count,
    live_mask: u8 = 0,
    tombstone_mask: u8 = 0,

    pub fn cleanupReverse(self: *PreparationScratch, allocator: std.mem.Allocator) void {
        var role: usize = allocation_role_count;
        while (role != 0) {
            role -= 1;
            if (self.live_mask & (@as(u8, 1) << @intCast(role)) == 0) continue;
            freeRole(self, allocator, role);
            self.live_mask &= ~(@as(u8, 1) << @intCast(role));
            self.tombstone_mask |= @as(u8, 1) << @intCast(role);
            self.descriptors[role] = .{};
        }
    }
};

pub const AllocationError = error{OutOfMemory};

pub fn allocateSchedule(self: *PreparationScratch, allocator: std.mem.Allocator, counts: [allocation_role_count]usize) AllocationError!void {
    errdefer self.cleanupReverse(allocator);
    for (counts, 0..) |count, role| {
        if (count == 0) continue;
        try allocateRole(self, allocator, role, count);
        self.descriptors[role] = descriptorForRole(self, allocator, role);
        self.live_mask |= @as(u8, 1) << @intCast(role);
    }
}

fn allocateRole(self: *PreparationScratch, allocator: std.mem.Allocator, role: usize, count: usize) !void {
    switch (role) {
        0 => try self.dto_backing.ensureTotalCapacityPrecise(allocator, count),
        1 => try self.next_observation.cwd.ensureTotalCapacityPrecise(allocator, count),
        2 => try self.next_observation.cwd_host.ensureTotalCapacityPrecise(allocator, count),
        3 => try self.next_observation.window_title.ensureTotalCapacityPrecise(allocator, count),
        4 => try self.next_observation.ssh_remote_dest.ensureTotalCapacityPrecise(allocator, count),
        5 => try self.next_observation.clipboard_read_target.ensureTotalCapacityPrecise(allocator, count),
        6 => try self.next_observation.foreground_processes.ensureTotalCapacityPrecise(allocator, count),
        7 => try self.next_observation.agent_progress.ensureTotalCapacityPrecise(allocator, count),
        else => unreachable,
    }
}

fn descriptorForRole(self: *PreparationScratch, allocator: std.mem.Allocator, role: usize) cleanup.CleanupDescriptor {
    const values = switch (role) {
        0 => std.mem.sliceAsBytes(self.dto_backing.items.ptr[0..self.dto_backing.capacity]),
        1 => std.mem.sliceAsBytes(self.next_observation.cwd.items.ptr[0..self.next_observation.cwd.capacity]),
        2 => std.mem.sliceAsBytes(self.next_observation.cwd_host.items.ptr[0..self.next_observation.cwd_host.capacity]),
        3 => std.mem.sliceAsBytes(self.next_observation.window_title.items.ptr[0..self.next_observation.window_title.capacity]),
        4 => std.mem.sliceAsBytes(self.next_observation.ssh_remote_dest.items.ptr[0..self.next_observation.ssh_remote_dest.capacity]),
        5 => std.mem.sliceAsBytes(self.next_observation.clipboard_read_target.items.ptr[0..self.next_observation.clipboard_read_target.capacity]),
        6 => std.mem.sliceAsBytes(self.next_observation.foreground_processes.items.ptr[0..self.next_observation.foreground_processes.capacity]),
        7 => std.mem.sliceAsBytes(self.next_observation.agent_progress.items.ptr[0..self.next_observation.agent_progress.capacity]),
        else => unreachable,
    };
    return .{
        .present = 1,
        .address = @intFromPtr(values.ptr),
        .length_bytes = values.len,
        .capacity_bytes = values.len,
        .alignment_log2 = switch (role) {
            6 => std.math.log2_int(usize, @alignOf(@TypeOf(self.next_observation.foreground_processes.items[0]))),
            else => 0,
        },
        .allocator_ptr = @intFromPtr(allocator.ptr),
        .allocator_vtable = @intFromPtr(allocator.vtable),
    };
}

fn freeRole(self: *PreparationScratch, allocator: std.mem.Allocator, role: usize) void {
    switch (role) {
        0 => self.dto_backing.deinit(allocator),
        1 => self.next_observation.cwd.deinit(allocator),
        2 => self.next_observation.cwd_host.deinit(allocator),
        3 => self.next_observation.window_title.deinit(allocator),
        4 => self.next_observation.ssh_remote_dest.deinit(allocator),
        5 => self.next_observation.clipboard_read_target.deinit(allocator),
        6 => self.next_observation.foreground_processes.deinit(allocator),
        7 => self.next_observation.agent_progress.deinit(allocator),
        else => unreachable,
    }
}

pub const PreparationAllocatorContext = struct {
    self_addr: u64 = 0,
    allocator: std.mem.Allocator,
    expected_role_raw: u8 = 0,
    callback_active_raw: u8 = 0,
    reserved: [6]u8 = [_]u8{0} ** 6,
    requested_len: u64 = 0,
    alignment_log2: u8 = 0,
    callback_ordinal: u8 = 0,
    reserved_tail: [6]u8 = [_]u8{0} ** 6,

    fn guardedAllocator(self: *PreparationAllocatorContext) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &guarded_allocator_vtable };
    }
};

const guarded_allocator_vtable: std.mem.Allocator.VTable = .{
    .alloc = guardedAlloc,
    .resize = guardedResize,
    .remap = guardedRemap,
    .free = guardedFree,
};

fn allocatorFrame(context: *anyopaque) *PreparationFrame {
    const allocator_context: *PreparationAllocatorContext = @ptrCast(@alignCast(context));
    const frame_addr = @intFromPtr(allocator_context) - @offsetOf(PreparationFrame, "allocator_context");
    return @ptrFromInt(frame_addr);
}

fn guardedAlloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
    const allocator_context: *PreparationAllocatorContext = @ptrCast(@alignCast(context));
    const frame = allocatorFrame(context);
    frame.validateOrFatal();
    if (allocator_context.callback_active_raw != 1 or
        allocator_context.requested_len != len or
        allocator_context.alignment_log2 != @intFromEnum(alignment))
        process_seal.fatalIntegrity(.callback_drift);
    const candidate_or_null = allocator_context.allocator.rawAlloc(len, alignment, return_address);
    // The allocator is hostile: re-establish the sealed frame before reading any callback-visible
    // range, owner, or source field. A protected alias is intentionally not freed on fatal proof loss.
    frame.validateOrFatal();
    const candidate = candidate_or_null orelse return null;
    if (!frame.protected_ranges.candidateAllowed(
        @intFromPtr(candidate),
        len,
        @intFromEnum(alignment),
    )) process_seal.fatalIntegrity(.callback_drift);
    const external_allowed = generation_event.preparationCandidateAllowed(
        frame.context.source_owner,
        @intFromPtr(candidate),
        len,
    ) catch process_seal.fatalIntegrity(.invalid_source_authority);
    if (!external_allowed) process_seal.fatalIntegrity(.callback_drift);
    frame.validateOrFatal();
    return candidate;
}

fn guardedResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn guardedRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

fn guardedFree(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
    const allocator_context: *PreparationAllocatorContext = @ptrCast(@alignCast(context));
    const frame = allocatorFrame(context);
    frame.validateOrFatal();
    if (allocator_context.callback_active_raw != 1 or allocator_context.expected_role_raw >= allocation_role_count or
        allocator_context.requested_len != memory.len or allocator_context.alignment_log2 != @intFromEnum(alignment))
        process_seal.fatalIntegrity(.callback_drift);
    const descriptor = frame.scratch.descriptors[allocator_context.expected_role_raw];
    if (descriptor.present != 1 or descriptor.address != @intFromPtr(memory.ptr) or
        descriptor.capacity_bytes != memory.len or descriptor.alignment_log2 != @intFromEnum(alignment) or
        descriptor.allocator_ptr != @intFromPtr(allocator_context.allocator.ptr) or
        descriptor.allocator_vtable != @intFromPtr(allocator_context.allocator.vtable))
        process_seal.fatalIntegrity(.callback_drift);
    allocator_context.allocator.rawFree(memory, alignment, return_address);
    if (@import("builtin").is_test and mutate_observation_content_on_dto_free and
        allocator_context.expected_role_raw == 0 and frame.scratch.next_observation.cwd.items.len != 0)
        frame.scratch.next_observation.cwd.items[0] ^= 1;
    frame.validateOrFatal();
}

pub const RuntimePreparationContext = struct {
    runtime_addr: u64,
    allocator: std.mem.Allocator,
    lifetime_owner: *lifetime.RuntimeLifetimeOwner,
    pending_owner: *pending_owner.PendingEventOwner,
    observation: *const RuntimeObservation,
    direct_input: *const std.ArrayListUnmanaged(u8),
    direct_input_offset: *const usize,
    pending_controls: *const std.ArrayListUnmanaged(pending_control.RawQueuedRuntimeControl),
    blocking_flush_active: *const bool,
    resize_generation: *const u64,
    resize_baseline_present: *const bool,
    source_owner: *const generation_event.EventOwner,
    source_view: generation_event.PreparationEventView,
    correlation: client_slot.EventCorrelation,
};

pub const PendingEventSourceReceipt = pending_owner.PendingEventSourceReceipt;
pub const PendingEventSourceLease = pending_owner.PendingEventSourceLease;

pub const SourceError = error{InvalidOwner};

pub fn sourceIdentityFromView(view: generation_event.PreparationEventView) SourceError!cleanup.PendingEventIdentity {
    const trusted = view.trusted;
    const identity: cleanup.PendingEventIdentity = .{
        .expected_major = trusted.expected_major,
        .metadata_support_raw = trusted.metadata_support_raw,
        .correlation_binding_digest = trusted.correlation_binding_digest,
        .payload_digest = trusted.payload_digest,
        .admission_projection_digest = trusted.admission_projection_digest,
        .wire_major = trusted.wire_major,
        .admission_tag = trusted.admission_tag,
        .registry_incarnation = trusted.registry_incarnation,
        .binding_reservation_id = trusted.binding_reservation_id,
        .event_node_incarnation = trusted.event_node_incarnation,
        .stream_id = trusted.stream_id,
        .event_generation = trusted.event_generation,
        .event_owner_addr = trusted.event_owner_addr,
        .slot_incarnation = trusted.slot_incarnation,
        .owner_node_incarnation = trusted.owner_node_incarnation,
        .transport_incarnation = trusted.transport_incarnation,
        .host_id = trusted.host_id,
        .runtime_id = trusted.runtime_id,
        .connection_generation = trusted.connection_generation,
        .pid = trusted.pid,
        .process_nonce = trusted.process_nonce,
    };
    const payload_digest = runtime_event_wire.payloadDigest(view.event.payload);
    if (view.event.wire_major != trusted.wire_major or
        @intFromBool(std.meta.activeTag(view.event.admission) == .accepted) != trusted.admission_tag or
        !std.crypto.timing_safe.eql(cleanup.Digest, payload_digest, trusted.payload_digest))
        return error.InvalidOwner;
    return identity;
}

pub fn preflightSource(
    context: RuntimePreparationContext,
    view: generation_event.PreparationEventView,
    operation_preflight: cleanup.RuntimeOperationPreflight,
) SourceError!PendingEventSourceReceipt {
    if (!std.meta.eql(context.source_view, view) or
        operation_preflight.runtime_addr != context.runtime_addr or
        operation_preflight.pending_owner_addr != @intFromPtr(context.pending_owner) or
        operation_preflight.lifetime_owner_addr != @intFromPtr(context.lifetime_owner) or
        operation_preflight.pid != process_seal.currentProcessId() or operation_preflight.reserved_pid != 0 or
        operation_preflight.thread_id != @as(u64, @intCast(std.Thread.getCurrentId())))
        return error.InvalidOwner;
    const canonical_view = generation_event.preparationEventView(
        context.source_owner,
        context.correlation,
    ) catch return error.InvalidOwner;
    if (!std.meta.eql(canonical_view, view)) return error.InvalidOwner;
    const source_identity = try sourceIdentityFromView(view);
    if (source_identity.pid != operation_preflight.pid or
        source_identity.process_nonce != operation_preflight.process_nonce)
        return error.InvalidOwner;
    const source_incarnation = context.pending_owner.nextSourceLeaseIncarnation() catch return error.InvalidOwner;
    return preflightPendingEventSource(context.pending_owner, .{
        .event_identity = source_identity,
        .runtime_addr = context.runtime_addr,
        .pending_owner_addr = @intFromPtr(context.pending_owner),
        .payload_addr = @intFromPtr(view.event.payload.ptr),
        .payload_len = view.event.payload.len,
        .runtime_incarnation = operation_preflight.owner_incarnation,
        .pending_owner_incarnation = context.pending_owner.owner_incarnation,
        .source_lease_incarnation = source_incarnation,
        .pid = operation_preflight.pid,
        .process_nonce = operation_preflight.process_nonce,
        .thread_id = operation_preflight.thread_id,
    }, view.event.payload);
}

fn sourceReceiptCanonical(input: cleanup.PendingSourceReceiptSealInput) bool {
    const identity = input.event_identity;
    return input.runtime_addr != 0 and input.pending_owner_addr != 0 and
        input.payload_addr != 0 and input.payload_len != 0 and input.runtime_incarnation != 0 and
        input.pending_owner_incarnation != 0 and input.source_lease_incarnation != 0 and
        input.pid == process_seal.currentProcessId() and input.process_nonce != 0 and
        input.thread_id == @as(u64, @intCast(std.Thread.getCurrentId())) and
        identity.host_id != 0 and identity.runtime_id != 0 and identity.stream_id != 0 and
        identity.event_generation != 0 and identity.event_owner_addr != 0 and
        identity.pid == input.pid and identity.process_nonce == input.process_nonce and
        !std.mem.allEqual(u8, &identity.payload_digest, 0) and
        ((identity.admission_tag == 0 and std.mem.allEqual(u8, &identity.admission_projection_digest, 0)) or
            (identity.admission_tag == 1 and !std.mem.allEqual(u8, &identity.admission_projection_digest, 0))) and
        identity.metadata_support_raw <= 1 and identity.admission_tag <= 1;
}

pub fn preflightPendingEventSource(
    owner: *const pending_owner.PendingEventOwner,
    input: cleanup.PendingSourceReceiptSealInput,
    payload: []const u8,
) SourceError!PendingEventSourceReceipt {
    const expected_incarnation = owner.nextSourceLeaseIncarnation() catch return error.InvalidOwner;
    if (@intFromPtr(owner) != input.pending_owner_addr or
        input.source_lease_incarnation != expected_incarnation or
        !sourceReceiptCanonical(input) or !payloadMatches(input, payload)) return error.InvalidOwner;
    return .{
        .event_identity = pendingIdentity(input.event_identity),
        .runtime_addr = input.runtime_addr,
        .pending_owner_addr = input.pending_owner_addr,
        .payload_addr = input.payload_addr,
        .payload_len = input.payload_len,
        .runtime_incarnation = input.runtime_incarnation,
        .pending_owner_incarnation = input.pending_owner_incarnation,
        .source_lease_incarnation = input.source_lease_incarnation,
        .pid = input.pid,
        .process_nonce = input.process_nonce,
        .thread_id = input.thread_id,
        .receipt_seal = process_seal.pendingSourceReceiptSeal(
            input.pid,
            input.process_nonce,
            input,
        ) catch return error.InvalidOwner,
    };
}

pub fn mintSourceLease(receipt: PendingEventSourceReceipt, attempt: u64) SourceError!PendingEventSourceLease {
    if (attempt == 0 or !validateSourceReceiptSeal(receipt)) return error.InvalidOwner;
    var result: PendingEventSourceLease = .{
        .receipt = receipt,
        .state_raw = 1,
        .reserved = [_]u8{0} ** 7,
        .attempt = attempt,
        .lease_seal = [_]u8{0} ** 32,
    };
    result.lease_seal = process_seal.pendingSourceLeaseSeal(
        receipt.pid,
        receipt.process_nonce,
        sourceLeaseInput(result),
    ) catch return error.InvalidOwner;
    return result;
}

fn validateSourceReceiptSeal(receipt: PendingEventSourceReceipt) bool {
    const input = receiptInput(receipt);
    if (!sourceReceiptCanonical(input)) return false;
    const expected = process_seal.pendingSourceReceiptSeal(
        receipt.pid,
        receipt.process_nonce,
        input,
    ) catch return false;
    return std.crypto.timing_safe.eql(cleanup.CleanupSeal, expected, receipt.receipt_seal);
}

pub fn validateSourceReceipt(receipt: PendingEventSourceReceipt, payload: []const u8) bool {
    return validateSourceReceiptSeal(receipt) and payloadMatches(receiptInput(receipt), payload);
}

pub fn validateSourceLease(lease: PendingEventSourceLease) bool {
    if (lease.state_raw < 1 or lease.state_raw > 3 or lease.attempt == 0 or
        !std.mem.allEqual(u8, &lease.reserved, 0) or !validateSourceReceiptSeal(lease.receipt)) return false;
    const expected = process_seal.pendingSourceLeaseSeal(
        lease.receipt.pid,
        lease.receipt.process_nonce,
        sourceLeaseInput(lease),
    ) catch return false;
    return std.crypto.timing_safe.eql(cleanup.CleanupSeal, expected, lease.lease_seal);
}

fn sourceLeaseFrameValid(lease: PendingEventSourceLease) bool {
    return (lease.state_raw == 0 and lease.attempt == 0 and
        std.mem.allEqual(u8, std.mem.asBytes(&lease.receipt), 0) and
        std.mem.allEqual(u8, &lease.reserved, 0) and
        std.mem.allEqual(u8, &lease.lease_seal, 0)) or validateSourceLease(lease);
}

pub fn validateSourceAfterCallback(lease: PendingEventSourceLease, payload: []const u8) bool {
    return validateSourceLease(lease) and validateSourceReceipt(lease.receipt, payload);
}

fn payloadMatches(input: cleanup.PendingSourceReceiptSealInput, payload: []const u8) bool {
    if (payload.len != input.payload_len or @intFromPtr(payload.ptr) != input.payload_addr) return false;
    const digest = runtime_event_wire.payloadDigest(payload);
    return std.crypto.timing_safe.eql(cleanup.Digest, digest, input.event_identity.payload_digest);
}

pub fn settleSourceLease(lease: *PendingEventSourceLease, consumed: bool) void {
    if (!validateSourceLease(lease.*) or lease.state_raw != 1)
        process_seal.fatalIntegrity(.invalid_source_authority);
    lease.state_raw = if (consumed) 2 else 3;
    lease.lease_seal = process_seal.pendingSourceLeaseSeal(
        lease.receipt.pid,
        lease.receipt.process_nonce,
        sourceLeaseInput(lease.*),
    ) catch process_seal.fatalIntegrity(.invalid_source_authority);
}

fn sourceLeaseInput(lease: PendingEventSourceLease) cleanup.PendingSourceLeaseSealInput {
    return .{
        .receipt = receiptInput(lease.receipt),
        .state_raw = lease.state_raw,
        .reserved = lease.reserved,
        .attempt = lease.attempt,
    };
}

fn receiptInput(receipt: PendingEventSourceReceipt) cleanup.PendingSourceReceiptSealInput {
    return .{
        .event_identity = cleanupIdentity(receipt.event_identity),
        .runtime_addr = receipt.runtime_addr,
        .pending_owner_addr = receipt.pending_owner_addr,
        .payload_addr = receipt.payload_addr,
        .payload_len = receipt.payload_len,
        .runtime_incarnation = receipt.runtime_incarnation,
        .pending_owner_incarnation = receipt.pending_owner_incarnation,
        .source_lease_incarnation = receipt.source_lease_incarnation,
        .pid = receipt.pid,
        .process_nonce = receipt.process_nonce,
        .thread_id = receipt.thread_id,
    };
}

fn pendingIdentity(value: cleanup.PendingEventIdentity) pending_owner.PendingEventIdentity {
    var result: pending_owner.PendingEventIdentity = .{};
    inline for (std.meta.fields(cleanup.PendingEventIdentity)) |field|
        @field(result, field.name) = @field(value, field.name);
    return result;
}

fn cleanupIdentity(value: pending_owner.PendingEventIdentity) cleanup.PendingEventIdentity {
    var result: cleanup.PendingEventIdentity = std.mem.zeroes(cleanup.PendingEventIdentity);
    inline for (std.meta.fields(cleanup.PendingEventIdentity)) |field|
        @field(result, field.name) = @field(value, field.name);
    return result;
}

pub const PreparationFrame = struct {
    self_addr: u64,
    context: RuntimePreparationContext,
    operation_preflight: cleanup.RuntimeOperationPreflight,
    operation_lease: lifetime.RuntimeOperationLease,
    source_receipt: PendingEventSourceReceipt,
    source_lease_mirror: PendingEventSourceLease,
    snapshot: RuntimeSemanticSnapshot,
    recipe: event_preparation.EventPreparationRecipe,
    scratch: PreparationScratch,
    dto_content_digest: cleanup.Digest,
    transfer_projection_mask: u8,
    transfer_observation_digest: cleanup.Digest,
    transcript_mirror: cleanup.Digest,
    progress_mirror: cleanup.Digest,
    cleanup_descriptor: cleanup.CleanupDescriptor,
    protected_ranges: ProtectedRangeBuilder,
    allocator_context: PreparationAllocatorContext,
    frame_seal: cleanup.CleanupSeal,

    pub fn seal(self: *PreparationFrame) void {
        if (self.self_addr != @intFromPtr(self) or
            self.allocator_context.self_addr != @intFromPtr(&self.allocator_context) or
            !sourceLeaseFrameValid(self.source_lease_mirror))
            process_seal.fatalIntegrity(.invalid_preparation_frame);
        self.frame_seal = process_seal.pendingPreparationFrameSeal(
            self.source_receipt.pid,
            self.source_receipt.process_nonce,
            self.sealInput(),
        ) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    }

    pub fn validate(self: *const PreparationFrame) bool {
        // PID is checked before inherited frame or process-keyed seal material is trusted.
        if (process_seal.currentProcessId() != self.source_receipt.pid) return false;
        if (self.self_addr != @intFromPtr(self) or
            self.allocator_context.self_addr != @intFromPtr(&self.allocator_context) or
            !sourceLeaseFrameValid(self.source_lease_mirror)) return false;
        const expected = process_seal.pendingPreparationFrameSeal(
            self.source_receipt.pid,
            self.source_receipt.process_nonce,
            self.sealInput(),
        ) catch return false;
        return std.crypto.timing_safe.eql(cleanup.CleanupSeal, expected, self.frame_seal);
    }

    pub fn validateOrFatal(self: *const PreparationFrame) void {
        if (!self.validate()) process_seal.fatalIntegrity(.invalid_preparation_frame);
    }

    fn sealInput(self: *const PreparationFrame) cleanup.PendingPreparationFrameSealInput {
        return .{
            .frame_addr = self.self_addr,
            .runtime_addr = self.context.runtime_addr,
            .lifetime_owner_addr = @intFromPtr(self.context.lifetime_owner),
            .pending_owner_addr = @intFromPtr(self.context.pending_owner),
            .observation_addr = @intFromPtr(self.context.observation),
            .direct_input_addr = @intFromPtr(self.context.direct_input),
            .pending_controls_addr = @intFromPtr(self.context.pending_controls),
            .source_owner_addr = @intFromPtr(self.context.source_owner),
            .operation_preflight = self.operation_preflight,
            .operation_identity = self.operation_lease.identity(),
            .source_receipt = receiptInput(self.source_receipt),
            .source_lease = sourceLeaseInput(self.source_lease_mirror),
            .snapshot_digest = rawDigest("maru.pending-frame.snapshot.v1", std.mem.asBytes(&self.snapshot)),
            .recipe_digest = rawDigest("maru.pending-frame.recipe.v1", std.mem.asBytes(&self.recipe)),
            .scratch_graph_digest = rawDigest("maru.pending-frame.scratch.v1", std.mem.asBytes(&self.scratch)),
            .dto_content_digest = self.dto_content_digest,
            .transfer_projection_mask = self.transfer_projection_mask,
            .transfer_observation_digest = self.transfer_observation_digest,
            .transcript_mirror = self.transcript_mirror,
            .progress_mirror = self.progress_mirror,
            .cleanup_descriptor = self.cleanup_descriptor,
            .protected_ranges_digest = rawDigest("maru.pending-frame.ranges.v1", std.mem.asBytes(&self.protected_ranges)),
            .allocator_context_addr = @intFromPtr(&self.allocator_context),
            .allocator_context_projection_digest = rawDigest("maru.pending-frame.allocator-context.v1", std.mem.asBytes(&self.allocator_context)),
        };
    }

    fn runtimeExtent(self: *const PreparationFrame) ?u64 {
        if (self.protected_ranges.input_count == 0) return null;
        const range = self.protected_ranges.inputs[0];
        if (range.role_raw != @intFromEnum(ProtectedRole.remote_runtime) or
            range.start != self.context.runtime_addr or range.end_exclusive <= range.start) return null;
        return range.end_exclusive - range.start;
    }
};

pub const FrameInitInput = struct {
    context: RuntimePreparationContext,
    operation_preflight: cleanup.RuntimeOperationPreflight,
    source_receipt: PendingEventSourceReceipt,
    snapshot: RuntimeSemanticSnapshot,
    recipe: event_preparation.EventPreparationRecipe,
};

pub const PrepareError = error{ Busy, InvalidOwner };

pub fn initFrameInPlace(frame: *PreparationFrame, input: FrameInitInput, runtime_extent: u64) void {
    // Zeroing the complete final storage makes raw projection hashing independent of padding.
    @memset(std.mem.asBytes(frame), 0);
    frame.self_addr = @intFromPtr(frame);
    frame.context = input.context;
    frame.operation_preflight = input.operation_preflight;
    frame.operation_lease = .{};
    frame.source_receipt = input.source_receipt;
    frame.source_lease_mirror = .{};
    frame.snapshot = input.snapshot;
    frame.recipe = input.recipe;
    frame.scratch = .{};
    frame.dto_content_digest = [_]u8{0} ** 32;
    frame.transfer_projection_mask = 0;
    frame.transfer_observation_digest = [_]u8{0} ** 32;
    frame.transcript_mirror = [_]u8{0} ** 32;
    frame.progress_mirror = [_]u8{0} ** 32;
    frame.cleanup_descriptor = .{};
    frame.protected_ranges = .{};
    frame.protected_ranges.add(.remote_runtime, input.context.runtime_addr, runtime_extent) catch
        process_seal.fatalIntegrity(.invalid_preparation_frame);
    frame.protected_ranges.canonicalize();
    frame.allocator_context = .{
        .self_addr = @intFromPtr(&frame.allocator_context),
        .allocator = input.context.allocator,
    };
    frame.frame_seal = [_]u8{0} ** 32;
    frame.seal();
}

fn addSliceRange(builder: *ProtectedRangeBuilder, role: ProtectedRole, values: anytype) RangeError!void {
    const bytes = std.mem.sliceAsBytes(values);
    try builder.add(role, if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr), bytes.len);
}

/// Rebuilds the exact base-13 graph immediately before the first allocator callback. The runtime
/// extent was admitted transiently by `initFrameInPlace`; every other range is derived from the
/// live const views captured in the sealed frame.
fn rebuildBaseProtectedRanges(frame: *PreparationFrame) void {
    const runtime_extent = frame.runtimeExtent() orelse
        process_seal.fatalIntegrity(.invalid_preparation_frame);
    var ranges: ProtectedRangeBuilder = .{};
    ranges.add(.remote_runtime, frame.context.runtime_addr, runtime_extent) catch
        process_seal.fatalIntegrity(.invalid_preparation_frame);
    ranges.add(.source_payload, @intFromPtr(frame.context.source_view.event.payload.ptr), frame.context.source_view.event.payload.len) catch
        process_seal.fatalIntegrity(.invalid_preparation_frame);
    addSliceRange(&ranges, .direct_input_backing, frame.context.direct_input.items.ptr[0..frame.context.direct_input.capacity]) catch
        process_seal.fatalIntegrity(.invalid_preparation_frame);
    addSliceRange(&ranges, .pending_controls_backing, frame.context.pending_controls.items.ptr[0..frame.context.pending_controls.capacity]) catch
        process_seal.fatalIntegrity(.invalid_preparation_frame);
    const observation = frame.context.observation;
    addSliceRange(&ranges, .old_cwd, observation.cwd.items.ptr[0..observation.cwd.capacity]) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    addSliceRange(&ranges, .old_cwd_host, observation.cwd_host.items.ptr[0..observation.cwd_host.capacity]) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    addSliceRange(&ranges, .old_window_title, observation.window_title.items.ptr[0..observation.window_title.capacity]) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    addSliceRange(&ranges, .old_ssh_remote_dest, observation.ssh_remote_dest.items.ptr[0..observation.ssh_remote_dest.capacity]) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    addSliceRange(&ranges, .old_clipboard_read_target, observation.clipboard_read_target.items.ptr[0..observation.clipboard_read_target.capacity]) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    addSliceRange(&ranges, .old_foreground_processes, observation.foreground_processes.items.ptr[0..observation.foreground_processes.capacity]) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    addSliceRange(&ranges, .old_agent_progress, observation.agent_progress.items.ptr[0..observation.agent_progress.capacity]) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    ranges.add(.preparation_frame, @intFromPtr(frame), @sizeOf(PreparationFrame)) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    ranges.add(.allocator_vtable, @intFromPtr(frame.context.allocator.vtable), @sizeOf(std.mem.Allocator.VTable)) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    for (frame.scratch.descriptors, 0..) |descriptor, role| {
        if (frame.scratch.live_mask & (@as(u8, 1) << @intCast(role)) == 0) continue;
        if (descriptor.present != 1) process_seal.fatalIntegrity(.invalid_preparation_frame);
        ranges.add(scratchProtectedRole(role), descriptor.address, descriptor.capacity_bytes) catch
            process_seal.fatalIntegrity(.invalid_preparation_frame);
    }
    ranges.canonicalize();
    frame.protected_ranges = ranges;
    if (frame.source_lease_mirror.attempt == 0)
        frame.seal()
    else
        refreshCleanupEvidence(frame);
}

fn validateCallbackAuthorities(frame: *PreparationFrame) void {
    frame.validateOrFatal();
    if (!frame.context.lifetime_owner.validateAfterCallback(&frame.operation_lease) or
        !validateSourceAfterCallback(frame.source_lease_mirror, frame.context.source_view.event.payload))
        process_seal.fatalIntegrity(.callback_drift);
    validateCanonicalSourceView(frame);
    validateRuntimeSnapshot(frame);
    validateDtoContent(frame);
    validateTransferProjection(frame);
    validateCleanupEvidence(frame);
}

fn validateDtoContent(frame: *const PreparationFrame) void {
    if (std.mem.allEqual(u8, &frame.dto_content_digest, 0)) return;
    const descriptor = frame.scratch.descriptors[0];
    const empty = frame.scratch.dto_backing.items.len == 0;
    if (empty) {
        if (frame.scratch.dto_backing.capacity != 0 or
            !std.meta.eql(descriptor, cleanup.CleanupDescriptor{}) or
            frame.scratch.live_mask & 1 != 0 or
            frame.scratch.tombstone_mask & 1 != 0)
            process_seal.fatalIntegrity(.callback_drift);
    } else if (descriptor.present != 1 or
        frame.scratch.live_mask & 1 == 0 or
        frame.scratch.tombstone_mask & 1 != 0 or
        descriptor.address != @intFromPtr(frame.scratch.dto_backing.items.ptr) or
        descriptor.length_bytes != frame.scratch.dto_backing.items.len)
        process_seal.fatalIntegrity(.callback_drift);
    const current = rawDigest(
        "maru.pending-frame.dto-content.v1",
        frame.scratch.dto_backing.items,
    );
    if (!std.crypto.timing_safe.eql(cleanup.Digest, current, frame.dto_content_digest))
        process_seal.fatalIntegrity(.callback_drift);
}

fn observationDigestOrFatal(observation: *const RuntimeObservation, allocator: std.mem.Allocator) cleanup.Digest {
    const snapshot = snapshotObservation(observation, allocator) catch
        process_seal.fatalIntegrity(.callback_drift);
    return cleanup.observationCleanupDigest(snapshot);
}

fn validateTransferProjection(frame: *const PreparationFrame) void {
    if (frame.transfer_projection_mask == 0) {
        if (!std.mem.allEqual(u8, &frame.transfer_observation_digest, 0))
            process_seal.fatalIntegrity(.callback_drift);
        return;
    }
    if (frame.transfer_projection_mask != 0xfe or
        std.mem.allEqual(u8, &frame.transfer_observation_digest, 0))
        process_seal.fatalIntegrity(.callback_drift);
    var allocated_observation_mask: u8 = 0;
    inline for (1..allocation_role_count) |role| {
        if (frame.scratch.descriptors[role].present == 1)
            allocated_observation_mask |= @as(u8, 1) << @intCast(role);
    }
    if (frame.scratch.live_mask & allocated_observation_mask != allocated_observation_mask or
        frame.scratch.tombstone_mask & allocated_observation_mask != 0)
        process_seal.fatalIntegrity(.callback_drift);
    const current = observationDigestOrFatal(&frame.scratch.next_observation, frame.context.allocator);
    if (!std.crypto.timing_safe.eql(cleanup.Digest, current, frame.transfer_observation_digest))
        process_seal.fatalIntegrity(.callback_drift);
}

fn validateRuntimeSnapshot(frame: *const PreparationFrame) void {
    if (!runtimeSnapshotMatches(frame)) process_seal.fatalIntegrity(.callback_drift);
}

fn runtimeSnapshotMatches(frame: *const PreparationFrame) bool {
    const current = snapshotRuntimeContext(
        frame.context,
        frame.snapshot.runtime_incarnation,
        frame.operation_lease.identity(),
        cleanupIdentity(frame.source_receipt.event_identity),
    ) catch return false;
    return std.meta.eql(current, frame.snapshot);
}

fn preparationGraph(frame: *const PreparationFrame) cleanup.ObservationCleanupGraph {
    return .{
        .cwd = frame.scratch.descriptors[1],
        .cwd_host = frame.scratch.descriptors[2],
        .window_title = frame.scratch.descriptors[3],
        .ssh_remote_dest = frame.scratch.descriptors[4],
        .clipboard_read_target = frame.scratch.descriptors[5],
        .foreground_processes = frame.scratch.descriptors[6],
        .agent_progress = frame.scratch.descriptors[7],
    };
}

fn cleanupTranscriptInput(frame: *const PreparationFrame) cleanup.CleanupTranscriptInput {
    const identity = frame.source_receipt.event_identity;
    return .{
        .host_id = identity.host_id,
        .runtime_id = identity.runtime_id,
        .connection_generation = identity.connection_generation,
        .slot_incarnation = identity.slot_incarnation,
        .owner_node_incarnation = identity.owner_node_incarnation,
        .transport_incarnation = identity.transport_incarnation,
        .registry_incarnation = identity.registry_incarnation,
        .binding_reservation_id = identity.binding_reservation_id,
        .event_node_incarnation = identity.event_node_incarnation,
        .stream_id = identity.stream_id,
        .event_generation = identity.event_generation,
        .event_owner_addr = identity.event_owner_addr,
        .wire_major = identity.wire_major,
        .expected_major = identity.expected_major,
        .metadata_support_raw = identity.metadata_support_raw,
        .admission_tag = identity.admission_tag,
        .correlation_binding_digest = identity.correlation_binding_digest,
        .payload_digest = identity.payload_digest,
        .admission_projection_digest = identity.admission_projection_digest,
        .pending_owner_addr = @intFromPtr(frame.context.pending_owner),
        .pending_owner_incarnation = frame.source_receipt.pending_owner_incarnation,
        .cleanup_plan_addr = @intFromPtr(&frame.cleanup_descriptor),
        .runtime_addr = frame.context.runtime_addr,
        .observation_addr = @intFromPtr(frame.context.observation),
        .observation_revision = frame.snapshot.observation.revision,
        .observer_generation = frame.snapshot.observation.observer_generation,
        .title_generation = frame.snapshot.observation.title_generation,
        .observation_digest = cleanup.observationCleanupDigest(frame.snapshot.observation),
        .preparation_attempt = frame.source_lease_mirror.attempt,
        .pending_lifecycle = .preparing,
        .plan = .{ .preparation = .{
            .dto_backing = frame.scratch.descriptors[0],
            .next_observation = preparationGraph(frame),
        } },
    };
}

fn cleanupProgressInput(frame: *const PreparationFrame, transcript: cleanup.CleanupTranscriptInput) cleanup.CleanupProgressInput {
    var state = cleanup.initialProgress(transcript.plan);
    const completed = state.completed_mask | frame.scratch.tombstone_mask | frame.transfer_projection_mask;
    var next_role: cleanup.CleanupRole = .none;
    var role: usize = allocation_role_count;
    while (role != 0) {
        role -= 1;
        if (frame.scratch.descriptors[role].present == 1 and
            completed & (@as(u8, 1) << @intCast(role)) == 0)
        {
            next_role = @enumFromInt(role + 1);
            break;
        }
    }
    if (next_role == .none) {
        state.step = .finished;
        state.next_role = .none;
        state.completed_mask = 0xff;
    } else {
        const callback_role = frame.allocator_context.expected_role_raw;
        const freeing = frame.allocator_context.callback_active_raw == 1 and
            callback_role < allocation_role_count and
            frame.scratch.descriptors[callback_role].present == 1 and
            frame.scratch.live_mask & (@as(u8, 1) << @intCast(callback_role)) != 0;
        state.step = if (freeing)
            .freeing
        else if (frame.scratch.tombstone_mask != 0)
            .freed
        else
            .ready;
        state.next_role = next_role;
        state.completed_mask = completed;
    }
    return .{
        .transcript_input = transcript,
        .transcript_seal = frame.transcript_mirror,
        .phase = state.phase,
        .step = state.step,
        .next_role = state.next_role,
        .completed_mask = state.completed_mask,
        .retained_observation_digest = frame.transfer_observation_digest,
    };
}

fn refreshCleanupEvidence(frame: *PreparationFrame) void {
    frame.cleanup_descriptor = frame.scratch.descriptors[0];
    const transcript = cleanupTranscriptInput(frame);
    frame.transcript_mirror = process_seal.cleanupTranscriptSeal(
        frame.source_receipt.pid,
        frame.source_receipt.process_nonce,
        transcript,
    ) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    frame.progress_mirror = process_seal.cleanupProgressSeal(
        frame.source_receipt.pid,
        frame.source_receipt.process_nonce,
        cleanupProgressInput(frame, transcript),
    ) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    frame.seal();
}

fn validateCleanupEvidence(frame: *const PreparationFrame) void {
    if (frame.source_lease_mirror.attempt == 0) {
        if (!std.mem.allEqual(u8, &frame.transcript_mirror, 0) or
            !std.mem.allEqual(u8, &frame.progress_mirror, 0))
            process_seal.fatalIntegrity(.invalid_preparation_frame);
        return;
    }
    const transcript = cleanupTranscriptInput(frame);
    const expected_transcript = process_seal.cleanupTranscriptSeal(
        frame.source_receipt.pid,
        frame.source_receipt.process_nonce,
        transcript,
    ) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    if (!std.crypto.timing_safe.eql(cleanup.CleanupSeal, expected_transcript, frame.transcript_mirror))
        process_seal.fatalIntegrity(.callback_drift);
    const expected_progress = process_seal.cleanupProgressSeal(
        frame.source_receipt.pid,
        frame.source_receipt.process_nonce,
        cleanupProgressInput(frame, transcript),
    ) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    if (!std.crypto.timing_safe.eql(cleanup.CleanupSeal, expected_progress, frame.progress_mirror))
        process_seal.fatalIntegrity(.callback_drift);
}

fn validateCanonicalSourceView(frame: *const PreparationFrame) void {
    const current = generation_event.preparationEventView(
        frame.context.source_owner,
        frame.context.correlation,
    ) catch process_seal.fatalIntegrity(.invalid_source_authority);
    const stored = frame.context.source_view;
    if (current.event.wire_major != stored.event.wire_major or
        @intFromPtr(current.event.payload.ptr) != @intFromPtr(stored.event.payload.ptr) or
        current.event.payload.len != stored.event.payload.len or
        !std.meta.eql(current.event.admission, stored.event.admission) or
        !std.meta.eql(current.trusted, stored.trusted))
        process_seal.fatalIntegrity(.invalid_source_authority);
}

fn roleElementSize(role: usize) usize {
    const Process = std.meta.Child(@TypeOf(@as(RuntimeObservation, .{}).foreground_processes.items));
    return switch (role) {
        0...5, 7 => 1,
        6 => @sizeOf(Process),
        else => unreachable,
    };
}

fn roleAlignment(role: usize) std.mem.Alignment {
    const Process = std.meta.Child(@TypeOf(@as(RuntimeObservation, .{}).foreground_processes.items));
    return switch (role) {
        0...5, 7 => .fromByteUnits(@alignOf(u8)),
        6 => .fromByteUnits(@alignOf(Process)),
        else => unreachable,
    };
}

fn scratchProtectedRole(role: usize) ProtectedRole {
    return @enumFromInt(@intFromEnum(ProtectedRole.dto_backing) + role);
}

fn allocateFrameRole(frame: *PreparationFrame, role: usize, count: usize) AllocationError!void {
    if (count == 0) return;
    const bytes = std.math.mul(usize, count, roleElementSize(role)) catch return error.OutOfMemory;
    const alignment = roleAlignment(role);
    frame.allocator_context.expected_role_raw = @intCast(role);
    frame.allocator_context.callback_active_raw = 1;
    frame.allocator_context.requested_len = bytes;
    frame.allocator_context.alignment_log2 = @intFromEnum(alignment);
    frame.allocator_context.callback_ordinal = std.math.add(u8, frame.allocator_context.callback_ordinal, 1) catch
        process_seal.fatalIntegrity(.counter_exhausted);
    refreshCleanupEvidence(frame);
    validateCallbackAuthorities(frame);
    allocateRole(&frame.scratch, frame.allocator_context.guardedAllocator(), role, count) catch |err| {
        validateCallbackAuthorities(frame);
        frame.allocator_context.callback_active_raw = 0;
        frame.seal();
        return err;
    };
    const descriptor = descriptorForRole(&frame.scratch, frame.context.allocator, role);
    if (descriptor.capacity_bytes != bytes or descriptor.alignment_log2 != @intFromEnum(alignment) or
        !frame.protected_ranges.candidateAllowed(descriptor.address, descriptor.capacity_bytes, descriptor.alignment_log2))
        process_seal.fatalIntegrity(.callback_drift);
    const external_allowed = generation_event.preparationCandidateAllowed(
        frame.context.source_owner,
        @intCast(descriptor.address),
        @intCast(descriptor.capacity_bytes),
    ) catch process_seal.fatalIntegrity(.invalid_source_authority);
    if (!external_allowed) process_seal.fatalIntegrity(.callback_drift);
    frame.scratch.descriptors[role] = descriptor;
    frame.scratch.live_mask |= @as(u8, 1) << @intCast(role);
    frame.protected_ranges.add(scratchProtectedRole(role), descriptor.address, descriptor.capacity_bytes) catch
        process_seal.fatalIntegrity(.invalid_preparation_frame);
    frame.protected_ranges.canonicalize();
    frame.allocator_context.callback_active_raw = 0;
    refreshCleanupEvidence(frame);
    validateCallbackAuthorities(frame);
}

fn freeFrameRole(frame: *PreparationFrame, role: usize) void {
    // Role 0 is a decode-only DTO. Once reverse cleanup reaches it, no later semantic read may
    // depend on its bytes; drop the content seal even when the canonical empty DTO did not allocate
    // a role. For an allocated DTO this must still happen before ArrayList.deinit mutates its slice
    // fields inside the allocator callback. Its descriptor and allocator authority remain sealed.
    const live = frame.scratch.live_mask & (@as(u8, 1) << @intCast(role)) != 0;
    if (role == 0 and !std.mem.allEqual(u8, &frame.dto_content_digest, 0)) {
        frame.dto_content_digest = [_]u8{0} ** 32;
        // The empty DTO has no allocator callback below, so publish the changed content-seal state
        // here. Allocated role 0 is resealed by the normal callback evidence refresh.
        if (!live) {
            refreshCleanupEvidence(frame);
            return;
        }
    }
    if (!live) return;
    const descriptor = frame.scratch.descriptors[role];
    frame.allocator_context.expected_role_raw = @intCast(role);
    frame.allocator_context.callback_active_raw = 1;
    frame.allocator_context.requested_len = descriptor.capacity_bytes;
    frame.allocator_context.alignment_log2 = descriptor.alignment_log2;
    frame.allocator_context.callback_ordinal = std.math.add(u8, frame.allocator_context.callback_ordinal, 1) catch
        process_seal.fatalIntegrity(.counter_exhausted);
    refreshCleanupEvidence(frame);
    validateCallbackAuthorities(frame);
    freeRole(&frame.scratch, frame.allocator_context.guardedAllocator(), role);
    frame.allocator_context.callback_active_raw = 0;
    frame.scratch.live_mask &= ~(@as(u8, 1) << @intCast(role));
    frame.scratch.tombstone_mask |= @as(u8, 1) << @intCast(role);
    rebuildBaseProtectedRanges(frame);
    validateCallbackAuthorities(frame);
}

fn cleanupFrameScratchReverse(frame: *PreparationFrame) void {
    var role: usize = allocation_role_count;
    while (role != 0) {
        role -= 1;
        freeFrameRole(frame, role);
    }
}

fn noAllocationDecision(frame: *const PreparationFrame) ?prepared_types.PreparedDecision {
    return switch (frame.recipe) {
        .violation => prepared_types.decide(.violation),
        .accepted => |accepted| switch (accepted) {
            .ended => prepared_types.decide(.ended),
            .invalidated => prepared_types.decide(.invalidated),
            .revoked => |fence| prepared_types.decide(.{ .revoked = .{
                .successor_fence = fence,
                .successor_fence_valid = fence != 0,
            } }),
            .resized => |resize| prepared_types.decide(.{ .resize = .{
                .baseline_present = frame.snapshot.resize_baseline_present_raw == 1,
                .current_generation = frame.snapshot.resize_generation,
                .current_size = .{
                    .cols = frame.snapshot.observation.cols,
                    .rows = frame.snapshot.observation.rows,
                },
                .incoming_generation = resize.resize_generation,
                .incoming_size = .{ .cols = resize.cols, .rows = resize.rows },
            } }),
            .metadata => null,
        },
    };
}

fn bindDecisionToProgress(
    progress: *cleanup.CleanupProgressInput,
    decision: prepared_types.PreparedDecision,
) void {
    progress.decision = prepared_types.sealProjection(decision);
}

fn finishPublished(frame: *PreparationFrame, attempt: u64, decision: prepared_types.PreparedDecision, next: ?*RuntimeObservation) PrepareError!void {
    validateCallbackAuthorities(frame);
    const transcript = cleanupTranscriptInput(frame);
    const retains_observation = std.meta.activeTag(decision.projection) == .metadata_commit;
    var progress = cleanupProgressInput(frame, transcript);
    // A metadata publication transfers roles 1..7 and has already freed role 0. Seal that projected
    // post-publication state before the no-fail owner write; the live frame mirror must continue to
    // describe pre-publication scratch until the move actually occurs.
    if (retains_observation) {
        progress.step = .finished;
        progress.next_role = .none;
        progress.completed_mask = 0xff;
    }
    bindDecisionToProgress(&progress, decision);
    const publication_progress_seal = process_seal.cleanupProgressSeal(
        frame.source_receipt.pid,
        frame.source_receipt.process_nonce,
        progress,
    ) catch process_seal.fatalIntegrity(.invalid_preparation_frame);
    const evidence: pending_owner.PublicationEvidence = .{
        // The transcript preserves the historical allocation plan after reverse cleanup. Only a
        // metadata commit transfers live observation backing into PendingEventOwner; every other
        // result publishes a canonical-zero live cleanup graph with finished sealed progress.
        .cleanup_graph = if (retains_observation) preparationGraph(frame) else .{},
        .transcript_input = transcript,
        .progress_input = progress,
        .transcript_seal = frame.transcript_mirror,
        .progress_seal = publication_progress_seal,
    };
    frame.context.pending_owner.publishPrepared(attempt, decision, next, evidence) catch
        process_seal.fatalIntegrity(.invalid_source_authority);
    if (next != null) {
        inline for (1..allocation_role_count) |role| {
            frame.scratch.live_mask &= ~(@as(u8, 1) << @intCast(role));
            frame.scratch.tombstone_mask |= @as(u8, 1) << @intCast(role);
            frame.scratch.descriptors[role] = .{};
        }
        frame.transfer_projection_mask = 0;
        frame.transfer_observation_digest = [_]u8{0} ** 32;
    }
    settleSourceLease(&frame.source_lease_mirror, true);
    frame.context.lifetime_owner.consume(&frame.operation_lease);
}

fn publishFailure(frame: *PreparationFrame, attempt: u64, failure: prepared_types.PreparationFailure) PrepareError!void {
    cleanupFrameScratchReverse(frame);
    try finishPublished(frame, attempt, prepared_types.decide(switch (failure) {
        .out_of_memory => .out_of_memory,
        .local_resource_exhausted => .local_resource_exhausted,
        .protocol_error => .violation,
        .connection_closed => .connection_closed,
    }), null);
}

fn filledBytes(backing: []const u8, range: event_preparation.FilledRange) []const u8 {
    return backing[range.start..][0..range.len];
}

fn metadataEqualsCurrent(
    metadata: event_preparation.MetadataPreparationRecipe,
    fill: event_preparation.MetadataFillProjection,
    backing: []const u8,
    processes: *const [event_preparation.max_process_entries]event_preparation.FilledProcess,
    current: *const RuntimeObservation,
) bool {
    if (current.availability != .current or current.revision != metadata.revision or
        current.observer_generation != metadata.observer_generation or current.title_generation != metadata.title_generation or
        current.size.cols != metadata.cols or current.size.rows != metadata.rows or
        current.ssh_remote_dest_present != (metadata.ssh_remote_dest_present_raw == 1) or
        @intFromEnum(current.semantic_state) != metadata.semantic_state_raw or
        current.alt_active != (metadata.alt_active_raw == 1) or current.app_cursor_keys != (metadata.app_cursor_keys_raw == 1) or
        current.app_keypad != (metadata.app_keypad_raw == 1) or @as(u8, current.kitty_flags) != metadata.kitty_flags_raw or
        current.alternate_scroll != (metadata.alternate_scroll_raw == 1) or current.mouse_tracking != (metadata.mouse_tracking_raw == 1) or
        current.mouse_tracking_mode != metadata.mouse_tracking_mode or current.bracketed_paste != (metadata.bracketed_paste_raw == 1) or
        current.bell_count != metadata.bell_count or current.clipboard_write_seq != metadata.clipboard_write_seq or
        current.clipboard_read_seq != metadata.clipboard_read_seq or current.foreground_available != (metadata.foreground_available_raw == 1) or
        (current.foreground_pgid != null) != (metadata.foreground_pgid_present_raw == 1) or
        (current.foreground_pgid orelse 0) != metadata.foreground_pgid or current.cwd_host.items.len != 0 or
        current.agent_progress.items.len != 0 or current.foreground_processes.items.len != fill.process_count)
        return false;
    if (!std.mem.eql(u8, current.cwd.items, filledBytes(backing, fill.cwd)) or
        !std.mem.eql(u8, current.window_title.items, filledBytes(backing, fill.window_title)) or
        !std.mem.eql(u8, current.ssh_remote_dest.items, filledBytes(backing, fill.ssh_remote_dest)) or
        !std.mem.eql(u8, current.clipboard_read_target.items, filledBytes(backing, fill.clipboard_read_target))) return false;
    for (current.foreground_processes.items, processes[0..fill.process_count]) |left, right|
        if (left.pid != right.pid or !std.mem.eql(u8, left.slice(), right.slice())) return false;
    return true;
}

fn prepareMetadata(frame: *PreparationFrame, attempt: u64, metadata: event_preparation.MetadataPreparationRecipe) PrepareError!void {
    const current = frame.context.observation;
    const old_exact = current.cwd.capacity == current.cwd.items.len and
        current.cwd_host.capacity == current.cwd_host.items.len and
        current.window_title.capacity == current.window_title.items.len and
        current.ssh_remote_dest.capacity == current.ssh_remote_dest.items.len and
        current.clipboard_read_target.capacity == current.clipboard_read_target.items.len and
        current.foreground_processes.capacity == current.foreground_processes.items.len and
        current.agent_progress.capacity == current.agent_progress.items.len;
    const next_capacity = [_]u64{
        metadata.cwd.decoded_len,
        0,
        metadata.window_title.decoded_len,
        metadata.ssh_remote_dest.decoded_len,
        metadata.clipboard_read_target.decoded_len,
        std.math.mul(u64, metadata.process_count, roleElementSize(6)) catch
            return publishFailure(frame, attempt, .local_resource_exhausted),
        0,
    };
    const old_capacity = [_]u64{
        current.cwd.capacity,
        current.cwd_host.capacity,
        current.window_title.capacity,
        current.ssh_remote_dest.capacity,
        current.clipboard_read_target.capacity,
        std.math.mul(u64, current.foreground_processes.capacity, roleElementSize(6)) catch
            return publishFailure(frame, attempt, .local_resource_exhausted),
        current.agent_progress.capacity,
    };
    _ = prepared_types.checkBudget(.{
        .payload_len = frame.context.source_view.event.payload.len,
        .dto_capacity = metadata.backing_bytes,
        .next_capacity = next_capacity,
        .old_capacity = old_capacity,
        .old_owner_exact = old_exact,
    }) catch return publishFailure(frame, attempt, .local_resource_exhausted);
    allocateFrameRole(frame, 0, metadata.backing_bytes) catch return publishFailure(frame, attempt, .out_of_memory);
    frame.scratch.dto_backing.items.len = metadata.backing_bytes;
    @memset(frame.scratch.dto_backing.items, 0);
    frame.seal();
    var processes: [event_preparation.max_process_entries]event_preparation.FilledProcess =
        [_]event_preparation.FilledProcess{.{}} ** event_preparation.max_process_entries;
    const classification = classificationFromSourceView(frame.context.source_view);
    const fill = event_preparation.fillMetadataRecipe(
        &metadata,
        classification,
        frame.context.source_view.event.payload,
        frame.scratch.dto_backing.items,
        &processes,
    ) catch process_seal.fatalIntegrity(.invalid_source_authority);
    frame.dto_content_digest = rawDigest(
        "maru.pending-frame.dto-content.v1",
        frame.scratch.dto_backing.items,
    );
    frame.seal();
    validateCallbackAuthorities(frame);

    var decision = prepared_types.decide(.{ .metadata = .{
        .current_revision = frame.snapshot.observation.revision,
        .incoming_revision = metadata.revision,
        .semantic_equal = metadataEqualsCurrent(metadata, fill, frame.scratch.dto_backing.items, &processes, frame.context.observation),
        .content_equal = metadataEqualsCurrent(metadata, fill, frame.scratch.dto_backing.items, &processes, frame.context.observation),
    } });
    if (metadata.observation_probe_nonce != 0 and
        std.meta.activeTag(decision.projection) == .ignored)
    {
        decision = prepared_types.decide(.violation);
    } else {
        decision.observation_probe_nonce = metadata.observation_probe_nonce;
    }
    if (std.meta.activeTag(decision.projection) != .metadata_commit) {
        cleanupFrameScratchReverse(frame);
        return finishPublished(frame, attempt, decision, null);
    }

    const counts = [_]usize{
        0,
        fill.cwd.len,
        0,
        fill.window_title.len,
        fill.ssh_remote_dest.len,
        fill.clipboard_read_target.len,
        fill.process_count,
        0,
    };
    for (counts, 0..) |count, role|
        allocateFrameRole(frame, role, count) catch return publishFailure(frame, attempt, .out_of_memory);

    var next = &frame.scratch.next_observation;
    next.availability = .current;
    next.revision = metadata.revision;
    next.observer_generation = metadata.observer_generation;
    next.title_generation = metadata.title_generation;
    next.size = .{ .cols = metadata.cols, .rows = metadata.rows };
    next.ssh_remote_dest_present = metadata.ssh_remote_dest_present_raw == 1;
    next.semantic_state = @enumFromInt(metadata.semantic_state_raw);
    next.alt_active = metadata.alt_active_raw == 1;
    next.app_cursor_keys = metadata.app_cursor_keys_raw == 1;
    next.app_keypad = metadata.app_keypad_raw == 1;
    next.kitty_flags = @intCast(metadata.kitty_flags_raw);
    next.alternate_scroll = metadata.alternate_scroll_raw == 1;
    next.mouse_tracking = metadata.mouse_tracking_raw == 1;
    next.mouse_tracking_mode = metadata.mouse_tracking_mode;
    next.bracketed_paste = metadata.bracketed_paste_raw == 1;
    next.bell_count = metadata.bell_count;
    next.clipboard_write_seq = metadata.clipboard_write_seq;
    next.clipboard_read_seq = metadata.clipboard_read_seq;
    next.foreground_available = metadata.foreground_available_raw == 1;
    next.foreground_pgid = if (metadata.foreground_pgid_present_raw == 1) metadata.foreground_pgid else null;
    next.cwd.appendSliceAssumeCapacity(filledBytes(frame.scratch.dto_backing.items, fill.cwd));
    next.window_title.appendSliceAssumeCapacity(filledBytes(frame.scratch.dto_backing.items, fill.window_title));
    next.ssh_remote_dest.appendSliceAssumeCapacity(filledBytes(frame.scratch.dto_backing.items, fill.ssh_remote_dest));
    next.clipboard_read_target.appendSliceAssumeCapacity(filledBytes(frame.scratch.dto_backing.items, fill.clipboard_read_target));
    for (processes[0..fill.process_count]) |process| {
        var value = std.mem.zeroes(@TypeOf(next.foreground_processes.items[0]));
        value.pid = process.pid;
        value.len = process.len;
        @memcpy(value.bytes[0..process.len], process.bytes[0..process.len]);
        next.foreground_processes.appendAssumeCapacity(value);
    }
    frame.seal();
    validateCallbackAuthorities(frame);
    // Project reverse-cleanup completion without changing physical ownership. Observation roles
    // stay live and protected until PendingEventOwner has completed the no-fail move.
    frame.transfer_projection_mask = 0xfe;
    frame.transfer_observation_digest = observationDigestOrFatal(next, frame.context.allocator);
    refreshCleanupEvidence(frame);
    validateCallbackAuthorities(frame);
    // The DTO is no longer an input after this point. The generic role-0 free drops its content
    // seal, while the transferred observation digest remains live and catches output drift.
    freeFrameRole(frame, 0);
    validateTransferProjection(frame);
    return finishPublished(frame, attempt, decision, next);
}

/// Executes immutable pending-event preparation. This is still a dormant b2b3 entry: it publishes
/// only into the final-address PendingEventOwner and never mutates the live Runtime observation.
pub fn prepare(frame: *PreparationFrame) PrepareError!void {
    frame.validateOrFatal();
    if (!validateSourceReceipt(frame.source_receipt, frame.context.source_view.event.payload))
        return error.InvalidOwner;
    rebuildBaseProtectedRanges(frame);
    const attempt = try beginPrepareAndMintSourceLease(frame);

    if (noAllocationDecision(frame)) |decision|
        return finishPublished(frame, attempt, decision, null);

    const metadata = switch (frame.recipe.accepted) {
        .metadata => |value| value,
        else => unreachable,
    };
    return prepareMetadata(frame, attempt, metadata);
}

fn beginPrepareAndMintSourceLease(frame: *PreparationFrame) PrepareError!u64 {
    frame.validateOrFatal();
    if (!validateSourceReceipt(frame.source_receipt, frame.context.source_view.event.payload))
        return error.InvalidOwner;
    validateCanonicalSourceView(frame);
    const current_operation = frame.context.lifetime_owner.preflightPreparation() catch |err| return switch (err) {
        error.Busy => error.Busy,
        else => error.InvalidOwner,
    };
    const source_incarnation = frame.context.pending_owner.nextSourceLeaseIncarnation() catch |err| return switch (err) {
        error.Busy => error.Busy,
        else => error.InvalidOwner,
    };
    if (!std.meta.eql(current_operation, frame.operation_preflight) or
        source_incarnation != frame.source_receipt.source_lease_incarnation)
        return error.InvalidOwner;
    if (!runtimeSnapshotMatches(frame)) return error.InvalidOwner;

    // This registered lifecycle transition is the first mutation and linearizes against ordinary
    // release, attachment teardown, and ended purge.  From here onward every failure is an
    // integrity stop: a recoverable return would strand the canonical ordering blocker.
    generation_event.beginPreparationPending(frame.context.source_owner) catch |err| return switch (err) {
        error.Busy => error.Busy,
        else => error.InvalidOwner,
    };
    const operation = frame.context.lifetime_owner.acquirePreparationNoFail(frame.operation_preflight);
    const attempt = frame.context.pending_owner.beginPrepare(frame.source_receipt.event_identity) catch
        process_seal.fatalIntegrity(.invalid_source_authority);
    const source = mintSourceLease(frame.source_receipt, attempt) catch
        process_seal.fatalIntegrity(.invalid_source_authority);
    frame.context.pending_owner.bindSourceLease(attempt, source) catch
        process_seal.fatalIntegrity(.invalid_source_authority);
    frame.operation_lease = operation;
    frame.source_lease_mirror = source;
    frame.snapshot.operation_identity = operation.identity();
    refreshCleanupEvidence(frame);
    validateCallbackAuthorities(frame);
    return attempt;
}

pub const Callback = *const fn (*PreparationAllocatorContext) void;

/// Executes one callback under the frame seal.  No owner publication is attempted in this neutral
/// prerequisite; a later adapter must call this before adopting any allocator candidate.
pub fn runSealedCallback(frame: *PreparationFrame, callback: Callback) void {
    frame.validateOrFatal();
    frame.allocator_context.callback_active_raw = 1;
    frame.seal();
    callback(&frame.allocator_context);
    frame.validateOrFatal();
    frame.allocator_context.callback_active_raw = 0;
    frame.seal();
}

fn rawDigest(domain: []const u8, bytes: []const u8) cleanup.Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(domain);
    hasher.update(bytes);
    var result: cleanup.Digest = undefined;
    hasher.final(&result);
    return result;
}

pub const hostile_drift_rows = 48;
pub const reachable_alias_rows = 528;
pub const standalone_alias_rows = 84;
pub const source_lease_rows = 12;
pub const admission_rows = 23;

fn baseBuilder(base_count: usize) !ProtectedRangeBuilder {
    var builder: ProtectedRangeBuilder = .{};
    for (0..base_count) |index|
        try builder.add(@enumFromInt(index), 0x1000 + index * 0x100, 0x40);
    builder.canonicalize();
    return builder;
}

test "C3-3b2b3 preparation range union sorts and merges overlap" {
    var b: ProtectedRangeBuilder = .{};
    try b.add(.remote_runtime, 0x2000, 0x20);
    try b.add(.source_payload, 0x2010, 0x20);
    try b.add(.direct_input_backing, 0x2030, 0x10);
    b.canonicalize();
    try std.testing.expectEqual(@as(u8, 1), b.segment_count);
    try std.testing.expectEqual(@as(u64, 0x2040), b.segments[0].end_exclusive);
}

test "C3-3b2b3 preparation range rejects duplicate cap and overflow" {
    var b: ProtectedRangeBuilder = .{};
    try b.add(.remote_runtime, 0x1000, 1);
    try std.testing.expectError(error.DuplicateRole, b.add(.remote_runtime, 0x2000, 1));
    try std.testing.expectError(error.Overflow, b.add(.source_payload, std.math.maxInt(u64), 2));
}

test "C3-3b2b3 preparation candidate alignment and adjacency are exact" {
    var b = try baseBuilder(1);
    try std.testing.expect(!b.candidateAllowed(0x1000, 1, 0));
    try std.testing.expect(b.candidateAllowed(0x1040, 0x10, 4));
    try std.testing.expect(!b.candidateAllowed(0x1041, 0x10, 4));
}

test "C3-3b2b3 preparation byte snapshot binds descriptor and content" {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.appendSlice(std.testing.allocator, "abc");
    const first = try snapshotBytes(&list);
    list.items[0] = 'z';
    const second = try snapshotBytes(&list);
    try std.testing.expect(!std.mem.eql(u8, &first.content_digest, &second.content_digest));

    // A metadata DTO with no decoded strings or processes has no allocation descriptor, but the
    // BLAKE3 digest of its canonical empty content is still nonzero. This is a valid sealed state,
    // not evidence that role 0 must be live.
    var empty_frame: PreparationFrame = undefined;
    empty_frame.scratch = .{};
    empty_frame.dto_content_digest = rawDigest("maru.pending-frame.dto-content.v1", "");
    try std.testing.expect(!std.mem.allEqual(u8, &empty_frame.dto_content_digest, 0));
    validateDtoContent(&empty_frame);
}

test "C3-3b2b3 preparation pending control digest uses semantic canonical bytes" {
    const values = [_]pending_control.RawQueuedRuntimeControl{
        pending_control.RawQueuedRuntimeControl.scrollToBottom(1).?,
        pending_control.RawQueuedRuntimeControl.coreCommand(2, .{ .report_focus = true }).?,
    };
    const first = try pendingControlsDigest(&values);
    const replay = try pendingControlsDigest(&values);
    try std.testing.expectEqualSlices(u8, &first, &replay);
}

test "C3-3b2b3 preparation allocation schedule visits all ordinals" {
    var scratch: PreparationScratch = .{};
    try allocateSchedule(&scratch, std.testing.allocator, [_]usize{1} ** 8);
    try std.testing.expectEqual(@as(u8, 0xff), scratch.live_mask);
    scratch.cleanupReverse(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0xff), scratch.tombstone_mask);
}

test "C3-3b2b3 preparation every allocation ordinal OOM rolls back" {
    for (0..allocation_role_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var scratch: PreparationScratch = .{};
        try std.testing.expectError(error.OutOfMemory, allocateSchedule(&scratch, failing.allocator(), [_]usize{1} ** 8));
        try std.testing.expectEqual(@as(u8, 0), scratch.live_mask);
    }
}

test "C3-3b2b3 preparation reverse cleanup is idempotent after empty" {
    var scratch: PreparationScratch = .{};
    try allocateSchedule(&scratch, std.testing.allocator, [_]usize{1} ** 8);
    scratch.cleanupReverse(std.testing.allocator);
    scratch.cleanupReverse(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), scratch.live_mask);
}

test "C3-3b2b3 preparation frame owns exact protected substrate" {
    try std.testing.expectEqual(
        @as(usize, 21),
        @typeInfo(@typeInfo(ProtectedRangeBuilder).@"struct".fields[0].type).array.len,
    );
    try std.testing.expect(@sizeOf(PreparationFrame) > @sizeOf(PreparationScratch));
    const expected_snapshot_fields = .{
        "runtime_addr",       "observation_addr",          "runtime_incarnation", "allocator_ptr",
        "allocator_vtable",   "observation",               "direct_input",        "direct_input_offset",
        "pending_controls",   "blocking_flush_active_raw", "resize_generation",   "resize_baseline_present_raw",
        "operation_identity", "source_identity",
    };
    const actual_snapshot_fields = std.meta.fields(RuntimeSemanticSnapshot);
    try std.testing.expectEqual(expected_snapshot_fields.len, actual_snapshot_fields.len);
    inline for (expected_snapshot_fields, 0..) |name, index|
        try std.testing.expectEqualStrings(name, actual_snapshot_fields[index].name);
    const expected_context_fields = .{
        "runtime_addr",            "allocator",           "lifetime_owner",   "pending_owner",         "observation",
        "direct_input",            "direct_input_offset", "pending_controls", "blocking_flush_active", "resize_generation",
        "resize_baseline_present", "source_owner",        "source_view",      "correlation",
    };
    const actual_context_fields = std.meta.fields(RuntimePreparationContext);
    try std.testing.expectEqual(expected_context_fields.len, actual_context_fields.len);
    inline for (expected_context_fields, 0..) |name, index|
        try std.testing.expectEqualStrings(name, actual_context_fields[index].name);
    try std.testing.expectEqual(*const generation_event.EventOwner, actual_context_fields[11].type);
    try std.testing.expectEqual(generation_event.PreparationEventView, actual_context_fields[12].type);
    try std.testing.expectEqual(client_slot.EventCorrelation, actual_context_fields[13].type);

    var observation: RuntimeObservation = .{};
    var direct: std.ArrayListUnmanaged(u8) = .empty;
    var controls: std.ArrayListUnmanaged(pending_control.RawQueuedRuntimeControl) = .empty;
    var direct_offset: usize = 0;
    var blocking = false;
    var resize_generation: u64 = 1;
    var baseline_present = false;
    var life: lifetime.RuntimeLifetimeOwner = .{};
    var owner: pending_owner.PendingEventOwner = .{};
    var source_owner: generation_event.EventOwner = .{};
    const context: RuntimePreparationContext = .{
        .runtime_addr = 0x1000,
        .allocator = std.testing.allocator,
        .lifetime_owner = &life,
        .pending_owner = &owner,
        .observation = &observation,
        .direct_input = &direct,
        .direct_input_offset = &direct_offset,
        .pending_controls = &controls,
        .blocking_flush_active = &blocking,
        .resize_generation = &resize_generation,
        .resize_baseline_present = &baseline_present,
        .source_owner = &source_owner,
        .source_view = .{ .event = .{ .wire_major = 1, .payload = "x", .admission = .unknown }, .trusted = std.mem.zeroes(client_slot.GenerationEventPreparationProjection) },
        .correlation = .{},
    };
    const canonical = try snapshotRuntimeContext(
        context,
        1,
        std.mem.zeroes(cleanup.RuntimeOperationIdentity),
        std.mem.zeroes(cleanup.PendingEventIdentity),
    );
    inline for (std.meta.fields(RuntimeSemanticSnapshot)) |field| {
        var changed = canonical;
        std.mem.asBytes(&@field(changed, field.name))[0] ^= 1;
        try std.testing.expect(!std.meta.eql(canonical, changed));
    }
    blocking = true;
    try std.testing.expect(!std.meta.eql(canonical, try snapshotRuntimeContext(context, 1, .{
        .lifetime_owner_addr = 0,
        .runtime_addr = 0,
        .pending_owner_addr = 0,
        .pid = 0,
        .reserved_pid = 0,
        .process_nonce = 0,
        .thread_id = 0,
        .owner_incarnation = 0,
        .operation_incarnation = 0,
        .operation_kind_raw = 0,
        .operation_seal = [_]u8{0} ** 32,
    }, std.mem.zeroes(cleanup.PendingEventIdentity))));
    var identity_view = context.source_view;
    identity_view.trusted.wire_major = identity_view.event.wire_major;
    identity_view.trusted.admission_tag = 0;
    identity_view.trusted.payload_digest = runtime_event_wire.payloadDigest(identity_view.event.payload);
    const projected_identity = try sourceIdentityFromView(identity_view);
    try std.testing.expectEqual(identity_view.trusted.wire_major, projected_identity.wire_major);
    try std.testing.expectEqualSlices(u8, &identity_view.trusted.payload_digest, &projected_identity.payload_digest);
}

test "C3-3b2b3 preparation budget delegates four and three part limits" {
    const prepared = @import("runtime_event_prepared_types.zig");
    const result = try prepared.checkBudget(.{
        .payload_len = 1,
        .dto_capacity = 1,
        .next_capacity = [_]u64{0} ** 7,
        .old_capacity = [_]u64{0} ** 7,
        .old_owner_exact = true,
    });
    try std.testing.expectEqual(@as(u64, 2), result.prepare_peak);

    const decisions = [_]prepared_types.PreparedDecision{
        prepared_types.decide(.ended),
        prepared_types.decide(.invalidated),
        prepared_types.decide(.{ .resize = .{
            .baseline_present = false,
            .current_generation = 0,
            .current_size = .{ .cols = 0, .rows = 0 },
            .incoming_generation = 1,
            .incoming_size = .{ .cols = 80, .rows = 24 },
        } }),
        prepared_types.decide(.{ .resize = .{
            .baseline_present = true,
            .current_generation = 2,
            .current_size = .{ .cols = 80, .rows = 24 },
            .incoming_generation = 1,
            .incoming_size = .{ .cols = 90, .rows = 30 },
        } }),
        prepared_types.decide(.{ .metadata = .{
            .current_revision = 2,
            .incoming_revision = 1,
            .semantic_equal = false,
            .content_equal = false,
        } }),
        prepared_types.decide(.{ .metadata = .{
            .current_revision = 2,
            .incoming_revision = 2,
            .semantic_equal = true,
            .content_equal = true,
        } }),
        prepared_types.decide(.{ .metadata = .{
            .current_revision = 2,
            .incoming_revision = 3,
            .semantic_equal = false,
            .content_equal = false,
        } }),
        prepared_types.decide(.{ .revoked = .{
            .successor_fence = 7,
            .successor_fence_valid = true,
        } }),
        prepared_types.decide(.violation),
        prepared_types.decide(.connection_closed),
        prepared_types.decide(.out_of_memory),
        prepared_types.decide(.local_resource_exhausted),
    };
    for (decisions) |decision| {
        var progress: cleanup.CleanupProgressInput = undefined;
        progress.retained_observation_digest = [_]u8{0} ** 32;
        progress.decision = .{};
        if (std.meta.activeTag(decision.projection) == .metadata_commit)
            progress.retained_observation_digest[0] = 1;
        bindDecisionToProgress(&progress, decision);
        try std.testing.expect(cleanup.testing.decisionProjectionCanonical(progress));
    }
}

test "C3-3b2b3 hostile reachable alias matrix has exact 528 rows" {
    var rows: usize = 0;
    for (0..8) |ordinal| {
        const builder = try baseBuilder(13 + ordinal);
        for (builder.inputs[0..builder.input_count]) |range| {
            const candidates = [_][2]u64{
                .{ range.start, range.end_exclusive - range.start },
                .{ range.start - 8, 16 },
                .{ range.end_exclusive - 8, 16 },
                .{ range.start + 8, 8 },
            };
            for (candidates) |candidate| {
                try std.testing.expect(!builder.candidateAllowed(candidate[0], candidate[1], 0));
                rows += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, reachable_alias_rows), rows);
}

test "C3-3b2b3 hostile standalone max graph has exact 84 rows" {
    const b = try baseBuilder(21);
    try std.testing.expectEqual(@as(u8, 21), b.input_count);
    var rows: usize = 0;
    for (b.inputs[0..b.input_count]) |range| {
        for ([_][2]u64{
            .{ range.start, range.end_exclusive - range.start },
            .{ range.start - 8, 16 },
            .{ range.end_exclusive - 8, 16 },
            .{ range.start + 8, 8 },
        }) |candidate| {
            try std.testing.expect(!b.candidateAllowed(candidate[0], candidate[1], 0));
            rows += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, standalone_alias_rows), rows);
}

fn readyIdentityForInvariantTest() !process_seal.ReadyIdentity {
    return process_seal.currentReadyIdentity() catch |err| switch (err) {
        error.NotReady => blk: {
            const pid = process_seal.currentProcessId();
            const prepared = try process_seal.prepare(pid, 0x3344_7788);
            process_seal.commitReady(prepared);
            break :blk try process_seal.currentReadyIdentity();
        },
        else => return err,
    };
}

test "C3-3b2b3 hostile callback drift table executes all 48 seal mutations" {
    const Mutation = enum { owner, operation, source, progress, snapshot, allocator };
    const identity = try readyIdentityForInvariantTest();
    var rows: usize = 0;
    for (0..8) |role| {
        var baseline: cleanup.PendingPreparationFrameSealInput = std.mem.zeroes(cleanup.PendingPreparationFrameSealInput);
        baseline.frame_addr = 0x1000;
        baseline.runtime_addr = 0x2000;
        baseline.cleanup_descriptor.present = 1;
        baseline.cleanup_descriptor.address = 0x10_0000 + role * 0x100;
        baseline.cleanup_descriptor.length_bytes = role + 1;
        baseline.cleanup_descriptor.capacity_bytes = role + 1;
        const baseline_seal = try process_seal.pendingPreparationFrameSeal(identity.pid, identity.process_nonce, baseline);
        inline for (std.meta.tags(Mutation)) |mutation| {
            var attacked = baseline;
            switch (mutation) {
                .owner => attacked.pending_owner_addr = 0x3000 + role,
                .operation => attacked.operation_identity.operation_incarnation = role + 1,
                .source => attacked.source_lease.attempt = role + 1,
                .progress => attacked.progress_mirror[role] = 1,
                .snapshot => attacked.snapshot_digest[role] = 1,
                .allocator => attacked.allocator_context_projection_digest[role] = 1,
            }
            const attacked_seal = try process_seal.pendingPreparationFrameSeal(identity.pid, identity.process_nonce, attacked);
            try std.testing.expect(!std.crypto.timing_safe.eql(cleanup.CleanupSeal, baseline_seal, attacked_seal));
            rows += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, hostile_drift_rows), rows);
}

test "C3-3b2b3 hostile source lease table executes all 12 authority attacks" {
    const State = enum { pristine, active, consumed, aborted };
    const Attack = enum { copy, aba, wrong_thread };
    const identity = try readyIdentityForInvariantTest();
    var pending: pending_owner.PendingEventOwner = .{};
    try pending.initInPlace(41);
    var payload = [_]u8{ 1, 2, 3, 4 };
    const event_identity: cleanup.PendingEventIdentity = .{
        .expected_major = 2,
        .metadata_support_raw = 1,
        .correlation_binding_digest = [_]u8{1} ** 32,
        .payload_digest = runtime_event_wire.payloadDigest(&payload),
        .admission_projection_digest = [_]u8{2} ** 32,
        .wire_major = 2,
        .admission_tag = 1,
        .registry_incarnation = 1,
        .binding_reservation_id = 2,
        .event_node_incarnation = 3,
        .stream_id = 4,
        .event_generation = 5,
        .event_owner_addr = 6,
        .slot_incarnation = 7,
        .owner_node_incarnation = 8,
        .transport_incarnation = 9,
        .host_id = 10,
        .runtime_id = 11,
        .connection_generation = 12,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
    };
    const receipt = try preflightPendingEventSource(&pending, .{
        .event_identity = event_identity,
        .runtime_addr = 0x1000,
        .pending_owner_addr = @intFromPtr(&pending),
        .payload_addr = @intFromPtr(&payload),
        .payload_len = payload.len,
        .runtime_incarnation = 1,
        .pending_owner_incarnation = pending.owner_incarnation,
        .source_lease_incarnation = 1,
        .pid = identity.pid,
        .process_nonce = identity.process_nonce,
        .thread_id = @intCast(std.Thread.getCurrentId()),
    }, &payload);
    const active = try mintSourceLease(receipt, 1);
    var rows: usize = 0;
    inline for (std.meta.tags(State)) |state| {
        const canonical: PendingEventSourceLease = switch (state) {
            .pristine => .{},
            .active => active,
            .consumed => blk: {
                var value = active;
                settleSourceLease(&value, true);
                break :blk value;
            },
            .aborted => blk: {
                var value = active;
                settleSourceLease(&value, false);
                break :blk value;
            },
        };
        try std.testing.expect(sourceLeaseFrameValid(canonical));
        inline for (std.meta.tags(Attack)) |attack| {
            var attacked = canonical;
            switch (attack) {
                .copy => attacked.reserved[0] = 1,
                .aba => attacked.receipt.source_lease_incarnation +%= 1,
                .wrong_thread => attacked.receipt.thread_id +%= 1,
            }
            try std.testing.expect(!sourceLeaseFrameValid(attacked));
            rows += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, source_lease_rows), rows);
}

test "C3-3b2b3 hostile runtime admission table executes all 23 owner decisions" {
    const identity = try readyIdentityForInvariantTest();
    var pending: pending_owner.PendingEventOwner = .{};
    try pending.initInPlace(51);
    var owner: lifetime.RuntimeLifetimeOwner = .{};
    try owner.initInPlace(0x1000, @intFromPtr(&pending), identity.process_nonce, 51);
    var rows: usize = 0;
    for (0..3) |_| {
        const before = std.mem.asBytes(&owner).*;
        _ = try owner.preflightPreparation();
        try std.testing.expectEqualSlices(u8, &before, std.mem.asBytes(&owner));
        rows += 1;
    }
    const preflight = try owner.preflightPreparation();
    var lease = try owner.acquirePreparation(preflight);
    for (0..16) |_| {
        const before = std.mem.asBytes(&owner).*;
        try std.testing.expectError(error.Busy, owner.preflightPreparation());
        try std.testing.expectEqualSlices(u8, &before, std.mem.asBytes(&owner));
        rows += 1;
    }
    owner.abort(&lease);
    for (0..4) |index| {
        var copied = owner;
        switch (index) {
            0 => copied.self_addr +%= 1,
            1 => copied.owner_incarnation +%= 1,
            2 => copied.thread_id +%= 1,
            3 => copied.operation_seal[0] ^= 1,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidOwner, copied.preflightPreparation());
        rows += 1;
    }
    try std.testing.expectEqual(@as(usize, admission_rows), rows);
}

const CallbackMutation = enum(u8) { owner, operation, source, progress, snapshot, allocator };
var callback_mutation: CallbackMutation = .owner;
var mutate_observation_content_on_dto_free = false;

pub const testing = if (builtin.is_test) struct {
    /// 외부 allocator 호출 순서에 기대지 않고 preparation이 봉인한 DTO role의 실제 free
    /// callback에서 semantic backing을 한 번만 변조한다.
    pub fn armObservationContentDriftOnDtoFree() void {
        if (mutate_observation_content_on_dto_free)
            @panic("DTO free proof-loss hook이 이미 활성 상태다");
        mutate_observation_content_on_dto_free = true;
    }
} else struct {};

fn mutatePreparationDuringCallback(context: *PreparationAllocatorContext) void {
    const frame = allocatorFrame(context);
    switch (callback_mutation) {
        .owner => frame.context.pending_owner = @ptrFromInt(
            @intFromPtr(frame.context.pending_owner) + @alignOf(pending_owner.PendingEventOwner),
        ),
        .operation => frame.operation_lease.operation_incarnation +%= 1,
        .source => frame.source_lease_mirror.attempt +%= 1,
        .progress => frame.progress_mirror[0] ^= 1,
        .snapshot => frame.snapshot.runtime_incarnation +%= 1,
        .allocator => frame.allocator_context.expected_role_raw +%= 1,
    }
}

fn childFrameFailStop(
    case_id: enum { inherited_fork, proof_loss, abort_prepare, callback_drift, callback_content_drift },
    mutation: CallbackMutation,
) noreturn {
    const pid = process_seal.currentProcessId();
    const nonce: u64 = 0x3344_5566;
    const ready = process_seal.prepare(pid, nonce) catch std.c._exit(125);
    process_seal.commitReady(ready);

    var pending: pending_owner.PendingEventOwner = .{};
    pending.initInPlace(9) catch std.c._exit(125);
    var life: lifetime.RuntimeLifetimeOwner = .{};
    life.initInPlace(0x1000, @intFromPtr(&pending), nonce, 10) catch std.c._exit(125);
    const operation_preflight = life.preflightPreparation() catch std.c._exit(125);
    const operation_lease = life.acquirePreparation(operation_preflight) catch std.c._exit(125);

    var payload = [_]u8{ 1, 2, 3, 4 };
    const payload_digest = runtime_event_wire.payloadDigest(&payload);
    const identity: cleanup.PendingEventIdentity = .{
        .expected_major = 2,
        .metadata_support_raw = 1,
        .correlation_binding_digest = [_]u8{1} ** 32,
        .payload_digest = payload_digest,
        .admission_projection_digest = [_]u8{2} ** 32,
        .wire_major = 2,
        .admission_tag = 1,
        .registry_incarnation = 1,
        .binding_reservation_id = 2,
        .event_node_incarnation = 3,
        .stream_id = 4,
        .event_generation = 5,
        .event_owner_addr = 0x3000,
        .slot_incarnation = 6,
        .owner_node_incarnation = 7,
        .transport_incarnation = 8,
        .host_id = 9,
        .runtime_id = 10,
        .connection_generation = 11,
        .pid = pid,
        .process_nonce = nonce,
    };
    const receipt = preflightPendingEventSource(&pending, .{
        .event_identity = identity,
        .runtime_addr = 0x1000,
        .pending_owner_addr = @intFromPtr(&pending),
        .payload_addr = @intFromPtr(&payload),
        .payload_len = payload.len,
        .runtime_incarnation = 10,
        .pending_owner_incarnation = 9,
        .source_lease_incarnation = 1,
        .pid = pid,
        .process_nonce = nonce,
        .thread_id = @intCast(std.Thread.getCurrentId()),
    }, &payload) catch std.c._exit(125);
    const source_lease = mintSourceLease(receipt, 1) catch std.c._exit(125);
    if (!validateSourceReceipt(receipt, &payload) or
        !validateSourceAfterCallback(source_lease, &payload)) std.c._exit(125);
    var consumed_copy = source_lease;
    settleSourceLease(&consumed_copy, true);
    if (consumed_copy.state_raw != 2 or !validateSourceLease(consumed_copy)) std.c._exit(125);
    var aborted_copy = source_lease;
    settleSourceLease(&aborted_copy, false);
    if (aborted_copy.state_raw != 3 or !validateSourceLease(aborted_copy)) std.c._exit(125);

    var observation: RuntimeObservation = .{};
    var direct_input: std.ArrayListUnmanaged(u8) = .empty;
    var controls: std.ArrayListUnmanaged(pending_control.RawQueuedRuntimeControl) = .empty;
    var direct_offset: usize = 0;
    var blocking = false;
    var resize_generation: u64 = 1;
    var baseline = false;
    var source_owner: generation_event.EventOwner = .{};
    var frame: PreparationFrame = undefined;
    initFrameInPlace(&frame, .{
        .context = .{
            .runtime_addr = 0x1000,
            .allocator = std.heap.page_allocator,
            .lifetime_owner = &life,
            .pending_owner = &pending,
            .observation = &observation,
            .direct_input = &direct_input,
            .direct_input_offset = &direct_offset,
            .pending_controls = &controls,
            .blocking_flush_active = &blocking,
            .resize_generation = &resize_generation,
            .resize_baseline_present = &baseline,
            .source_owner = &source_owner,
            .source_view = .{
                .event = .{ .wire_major = 2, .payload = &payload, .admission = .unknown },
                .trusted = std.mem.zeroes(client_slot.GenerationEventPreparationProjection),
            },
            .correlation = .{},
        },
        .operation_preflight = operation_preflight,
        .source_receipt = receipt,
        .snapshot = .{
            .runtime_addr = 0x1000,
            .observation_addr = @intFromPtr(&observation),
            .runtime_incarnation = 10,
            .allocator_ptr = @intFromPtr(std.heap.page_allocator.ptr),
            .allocator_vtable = @intFromPtr(std.heap.page_allocator.vtable),
            .observation = std.mem.zeroes(cleanup.ObservationCleanupDigestInput),
            .direct_input = snapshotBytes(&direct_input) catch std.c._exit(125),
            .direct_input_offset = 0,
            .pending_controls = snapshotBytes(&controls) catch std.c._exit(125),
            .blocking_flush_active_raw = 0,
            .resize_generation = 1,
            .resize_baseline_present_raw = 0,
            .operation_identity = std.mem.zeroes(cleanup.RuntimeOperationIdentity),
            .source_identity = identity,
        },
        .recipe = .{ .violation = .stale_preflight },
    }, 0x100);
    if (frame.protected_ranges.input_count != 1 or
        frame.protected_ranges.inputs[0].role_raw != @intFromEnum(ProtectedRole.remote_runtime) or
        frame.protected_ranges.inputs[0].start != 0x1000 or
        frame.protected_ranges.inputs[0].end_exclusive != 0x1100) std.c._exit(125);
    rebuildBaseProtectedRanges(&frame);
    if (frame.protected_ranges.input_count < 4 or
        frame.protected_ranges.inputs[0].role_raw != @intFromEnum(ProtectedRole.remote_runtime)) std.c._exit(125);
    // Non-test topology sentinel: analyze the complete dormant orchestration without consuming the
    // authority used by the fork/proof-loss subprocess cases below.
    if (@intFromPtr(&frame) == 0) prepare(&frame) catch std.c._exit(125);
    frame.operation_lease = operation_lease;
    frame.source_lease_mirror = source_lease;
    frame.snapshot.operation_identity = operation_lease.identity();
    frame.seal();
    frame.validateOrFatal();

    switch (case_id) {
        .callback_content_drift => {
            frame.context.allocator = std.testing.allocator;
            allocateRole(&frame.scratch, std.testing.allocator, 0, 4) catch std.c._exit(125);
            frame.scratch.descriptors[0] = descriptorForRole(&frame.scratch, std.testing.allocator, 0);
            frame.scratch.live_mask |= 1;
            allocateRole(&frame.scratch, std.testing.allocator, 1, 4) catch std.c._exit(125);
            frame.scratch.descriptors[1] = descriptorForRole(&frame.scratch, std.testing.allocator, 1);
            frame.scratch.live_mask |= 2;
            frame.scratch.next_observation.availability = .current;
            frame.scratch.next_observation.revision = 1;
            frame.scratch.next_observation.cwd.appendSliceAssumeCapacity("safe");
            frame.transfer_projection_mask = 0xfe;
            frame.transfer_observation_digest = observationDigestOrFatal(
                &frame.scratch.next_observation,
                std.testing.allocator,
            );
            frame.allocator_context.expected_role_raw = 0;
            frame.allocator_context.allocator = std.testing.allocator;
            frame.allocator_context.callback_active_raw = 1;
            frame.allocator_context.requested_len = frame.scratch.descriptors[0].capacity_bytes;
            frame.allocator_context.alignment_log2 = frame.scratch.descriptors[0].alignment_log2;
            frame.seal();
            mutate_observation_content_on_dto_free = true;
            guardedFree(
                &frame.allocator_context,
                frame.scratch.dto_backing.items.ptr[0..frame.scratch.dto_backing.capacity],
                .fromByteUnits(1),
                @returnAddress(),
            );
            validateTransferProjection(&frame);
            std.c._exit(124);
        },
        .callback_drift => {
            callback_mutation = mutation;
            runSealedCallback(&frame, mutatePreparationDuringCallback);
            std.c._exit(124);
        },
        .abort_prepare => {
            const attempt = pending.beginPrepare(pendingIdentity(identity)) catch std.c._exit(125);
            if (attempt != 1) std.c._exit(125);
            pending.bindSourceLease(attempt, source_lease) catch std.c._exit(125);
            pending_owner.testing.retainAbortEvidenceForFixture(&pending, attempt);
            if (pending.lifecycle_raw != @intFromEnum(pending_owner.PendingLifecycle.preparing) or
                pending.source_lease.state_raw != @intFromEnum(pending_owner.PendingSourceLeaseState.aborted) or
                !validateSourceLease(pending.source_lease))
                std.c._exit(125);
            if (pending.beginPrepare(pendingIdentity(identity))) |_| {
                std.c._exit(125);
            } else |err| if (err != error.Busy) std.c._exit(125);
            pending.abortPrepare(attempt);
        },
        .proof_loss => {
            frame.snapshot.runtime_incarnation += 1;
            frame.validateOrFatal();
        },
        .inherited_fork => {
            const grandchild = std.c.fork();
            if (grandchild < 0) std.c._exit(125);
            if (grandchild == 0) {
                frame.validateOrFatal();
                std.c._exit(124);
            }
            var status: c_int = 0;
            if (std.c.waitpid(grandchild, &status, 0) != grandchild) std.c._exit(125);
            const unsigned: u32 = @bitCast(status);
            if (!std.c.W.IFEXITED(unsigned) or std.c.W.EXITSTATUS(unsigned) != 86) std.c._exit(125);
            life.abort(&frame.operation_lease);
            std.c._exit(0);
        },
    }
    std.c._exit(124);
}

fn processSealAlreadyOwnedByAggregate() !bool {
    _ = process_seal.currentReadyIdentity() catch |err| switch (err) {
        error.NotReady => return false,
        else => return err,
    };
    return true;
}

test "C3-3b2b3 subprocess rejects inherited preparation frame before seal use" {
    if (@import("builtin").os.tag != .macos and @import("builtin").os.tag != .linux)
        return error.SkipZigTest;
    // This death test needs a fresh process-global seal so its first child can construct canonical
    // authority before the grandchild proves inherited-PID rejection. The focused b2b3 gate owns
    // that fresh topology; an aggregate test process may already have initialized the singleton.
    if (try processSealAlreadyOwnedByAggregate()) return error.SkipZigTest;
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) childFrameFailStop(.inherited_fork, .owner);
    var status: c_int = 0;
    try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
    const unsigned: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(unsigned));
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned))));
}

test "C3-3b2b3 subprocess fail-stops a drifted preparation frame after proof loss" {
    if (@import("builtin").os.tag != .macos and @import("builtin").os.tag != .linux)
        return error.SkipZigTest;
    // As above, the focused gate supplies the fresh singleton required to reach proof-loss itself
    // instead of failing earlier on an aggregate process's inherited PID-bound seal.
    if (try processSealAlreadyOwnedByAggregate()) return error.SkipZigTest;
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) childFrameFailStop(.proof_loss, .owner);
    var status: c_int = 0;
    try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
    const unsigned: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(unsigned));
    try std.testing.expectEqual(@as(u8, 86), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned))));
}

test "C3-3b2b3 subprocess abort preparation retains evidence and fail-stops" {
    if (@import("builtin").os.tag != .macos and @import("builtin").os.tag != .linux)
        return error.SkipZigTest;
    if (try processSealAlreadyOwnedByAggregate()) return error.SkipZigTest;
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) childFrameFailStop(.abort_prepare, .owner);
    var status: c_int = 0;
    try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
    const unsigned: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(unsigned));
    try std.testing.expectEqual(@as(u8, 86), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned))));
}

test "C3-3b2b3 callback subprocess fail-stops every authority mutation class" {
    if (@import("builtin").os.tag != .macos and @import("builtin").os.tag != .linux)
        return error.SkipZigTest;
    if (try processSealAlreadyOwnedByAggregate()) return error.SkipZigTest;
    inline for (std.meta.tags(CallbackMutation)) |mutation| {
        const child = std.c.fork();
        if (child < 0) return error.TestUnexpectedResult;
        if (child == 0) childFrameFailStop(.callback_drift, mutation);
        var status: c_int = 0;
        try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        const unsigned: u32 = @bitCast(status);
        try std.testing.expect(std.c.W.IFEXITED(unsigned));
        try std.testing.expectEqual(@as(u8, 86), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned))));
    }
    const content_child = std.c.fork();
    if (content_child < 0) return error.TestUnexpectedResult;
    if (content_child == 0) childFrameFailStop(.callback_content_drift, .owner);
    var content_status: c_int = 0;
    try std.testing.expectEqual(content_child, std.c.waitpid(content_child, &content_status, 0));
    const content_unsigned: u32 = @bitCast(content_status);
    try std.testing.expect(std.c.W.IFEXITED(content_unsigned));
    try std.testing.expectEqual(@as(u8, 86), @as(u8, @intCast(std.c.W.EXITSTATUS(content_unsigned))));
}
