//! Final-address owner for the single metadata winner chosen by an external Client source fold.
//!
//! The fold and outer decision remain the semantic SSOT. This module only turns an adopted
//! metadata winner into prepared ownership: scalar/initial winners allocate nothing, while an
//! event winner owns exactly one DTO until the later c3c paired commit consumes it.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const client_mod = @import("client.zig");
const compatibility = @import("compatibility.zig");
const decision_mod = @import("external_source_decision.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const runtime_event_reducer = @import("runtime_event_reducer.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");

const Lifecycle = enum {
    empty,
    prepared,
    committed_tombstone,
    aborted_tombstone,
};

pub const PreparedMetadataFootprint = struct {
    resident_delta: usize,
    prepare_peak_delta: usize,
};

pub const PreparedOwnedMetadata = struct {
    saved_self_addr: usize = 0,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    backing_present: bool = false,
    backing_addr: usize = 0,
    backing_len: usize = 0,
    candidate: ?runtime_event_reducer.MetadataCandidate = null,
    logical: ?runtime_metadata_wire.OwnedMetadataDto = null,
    cleanup: ?runtime_metadata_wire.OwnedMetadataDto = null,
    logical_seal: ?runtime_metadata_wire.OwnedMetadataSeal = null,
    cleanup_seal: ?runtime_metadata_wire.OwnedMetadataSeal = null,
    footprint: PreparedMetadataFootprint = .{
        .resident_delta = 0,
        .prepare_peak_delta = 0,
    },
    lifecycle: Lifecycle = .empty,

    fn initInPlace(
        out: *PreparedOwnedMetadata,
        dto: *runtime_metadata_wire.OwnedMetadataDto,
        candidate: runtime_event_reducer.MetadataCandidate,
        footprint: PreparedMetadataFootprint,
    ) bool {
        if (!std.meta.eql(out.*, PreparedOwnedMetadata{}) or
            footprint.resident_delta == 0 or
            footprint.prepare_peak_delta < footprint.resident_delta)
            return false;
        const taken = dto.take();
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .allocator_ptr_addr = @intFromPtr(taken.allocator.ptr),
            .allocator_vtable_addr = @intFromPtr(taken.allocator.vtable),
            .backing_present = taken.backing != null,
            .backing_addr = if (taken.backing) |bytes| @intFromPtr(bytes.ptr) else 0,
            .backing_len = if (taken.backing) |bytes| bytes.len else 0,
            .candidate = candidate,
            .logical = taken,
            .cleanup = taken,
            .footprint = footprint,
            .lifecycle = .prepared,
        };
        out.logical_seal = runtime_metadata_wire.sealOwnedMetadataDto(
            &out.logical.?,
        ) catch {
            out.deinit();
            return false;
        };
        out.cleanup_seal = runtime_metadata_wire.sealOwnedMetadataDto(
            &out.cleanup.?,
        ) catch {
            out.deinit();
            return false;
        };
        return true;
    }

    fn validate(self: *const PreparedOwnedMetadata) bool {
        return self.lifecycle == .prepared and
            self.saved_self_addr == @intFromPtr(self) and
            self.logical != null and self.cleanup != null and
            self.candidate != null and
            self.allocator_ptr_addr == @intFromPtr(self.logical.?.allocator.ptr) and
            self.allocator_vtable_addr == @intFromPtr(self.logical.?.allocator.vtable) and
            canonicalDescriptorMatches(
                self,
                self.logical_seal,
                &self.logical.?,
            ) and
            canonicalDescriptorMatches(
                self,
                self.cleanup_seal,
                &self.cleanup.?,
            ) and
            runtime_metadata_wire.validateOwnedMetadataSeal(
                self.logical_seal orelse return false,
                &self.logical.?,
            ) and
            runtime_metadata_wire.validateOwnedMetadataSeal(
                self.cleanup_seal orelse return false,
                &self.cleanup.?,
            ) and
            self.footprint.resident_delta ==
                eventResidentBytes(&self.logical.?) and
            self.footprint.prepare_peak_delta >= self.footprint.resident_delta;
    }

    fn deinit(self: *PreparedOwnedMetadata) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self))
            return;
        if (self.lifecycle == .prepared) {
            if (self.cleanup) |*cleanup| {
                if (canonicalDescriptorMatches(self, self.cleanup_seal, cleanup)) {
                    cleanup.deinit();
                } else if (self.logical) |*logical| {
                    if (canonicalDescriptorMatches(self, self.logical_seal, logical))
                        logical.deinit();
                }
            } else if (self.logical) |*logical| {
                if (canonicalDescriptorMatches(self, self.logical_seal, logical))
                    logical.deinit();
            }
        }
        self.logical = null;
        self.cleanup = null;
        self.logical_seal = null;
        self.cleanup_seal = null;
        self.candidate = null;
        self.lifecycle = .aborted_tombstone;
    }
};

pub const PreparedMetadata = union(enum) {
    unsupported,
    unavailable,
    initial: client_mod.InitialMetadataBindingSeal,
    event: PreparedOwnedMetadata,
};

/// The wrapper, rather than the union payload alone, is the final-address capability. This keeps
/// copying a prepared union from silently rebinding its nested event owner.
pub const Prepared = struct {
    saved_self_addr: usize = 0,
    metadata: PreparedMetadata = .unavailable,
    prepared_footprint: PreparedMetadataFootprint = .{
        .resident_delta = 0,
        .prepare_peak_delta = 0,
    },
    lifecycle: Lifecycle = .empty,

    pub fn validate(
        self: *const Prepared,
        client: *const client_mod.Client,
        input: client_mod.ExternalAdoptionFoldInput,
        decision: decision_mod.PreparedSourceDecision,
        scratch: *client_mod.ExternalSourceOwnerRangeScratch,
    ) bool {
        if (self.lifecycle != .prepared or
            self.saved_self_addr != @intFromPtr(self) or
            !decision_mod.decisionMatches(client, input, decision, scratch))
            return false;
        const live = switch (decision.verdict) {
            .adopted => |live| live,
            else => return false,
        };
        return switch (live.metadata) {
            .unsupported => self.metadata == .unsupported and
                footprintIsZero(self.prepared_footprint),
            .unavailable => self.metadata == .unavailable and
                footprintIsZero(self.prepared_footprint),
            .initial => switch (self.metadata) {
                .initial => |binding| std.meta.eql(
                    binding,
                    decision.fold.binding_seal.initial_metadata,
                ) and std.meta.eql(
                    self.prepared_footprint,
                    initialResidentFootprint(binding) orelse return false,
                ),
                else => false,
            },
            .event => switch (self.metadata) {
                .event => |*owned| owned.validate() and
                    runtime_event_reducer.metadataCandidateEql(
                        owned.candidate orelse return false,
                        live.metadata.event,
                    ) and
                    client.externalMetadataDtoMatchesEventCandidate(
                        input,
                        decision.fold,
                        live.metadata.event,
                        &owned.logical.?,
                        scratch,
                    ) and std.meta.eql(
                    self.prepared_footprint,
                    eventFootprint(
                        decision.fold.binding_seal.initial_metadata,
                        &owned.logical.?,
                    ) orelse return false,
                ) and std.meta.eql(
                    owned.footprint,
                    self.prepared_footprint,
                ),
                else => false,
            },
        };
    }

    pub fn footprint(
        self: *const Prepared,
        client: *const client_mod.Client,
        input: client_mod.ExternalAdoptionFoldInput,
        decision: decision_mod.PreparedSourceDecision,
        scratch: *client_mod.ExternalSourceOwnerRangeScratch,
    ) ?PreparedMetadataFootprint {
        if (!self.validate(client, input, decision, scratch)) return null;
        return self.prepared_footprint;
    }

    pub fn deinit(self: *Prepared) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self))
            return;
        if (self.lifecycle == .prepared) switch (self.metadata) {
            .event => |*owned| owned.deinit(),
            .unsupported, .unavailable, .initial => {},
        };
        self.metadata = .unavailable;
        self.prepared_footprint = .{
            .resident_delta = 0,
            .prepare_peak_delta = 0,
        };
        self.lifecycle = .aborted_tombstone;
    }
};

pub const RetryableReason = enum { out_of_memory };
pub const TerminalReason = enum {
    inconsistent_source,
    resource_exhausted,
    internal_invariant,
};

pub const PrepareResult = union(enum) {
    prepared: PreparedMetadataFootprint,
    retryable_preserved: RetryableReason,
    terminal: TerminalReason,
};

pub fn prepareInPlace(
    out: *Prepared,
    allocator: std.mem.Allocator,
    client: *const client_mod.Client,
    input: client_mod.ExternalAdoptionFoldInput,
    decision: decision_mod.PreparedSourceDecision,
    scratch: *client_mod.ExternalSourceOwnerRangeScratch,
) PrepareResult {
    if (rangesOverlap(
        @intFromPtr(out),
        @sizeOf(Prepared),
        @intFromPtr(client),
        @sizeOf(client_mod.Client),
    ) or rangesOverlap(
        @intFromPtr(out),
        @sizeOf(Prepared),
        @intFromPtr(scratch),
        @sizeOf(client_mod.ExternalSourceOwnerRangeScratch),
    ))
        return .{ .terminal = .internal_invariant };
    client.preflightExternalAdoptionDestinationWithScratch(
        out,
        @sizeOf(Prepared),
        scratch,
    ) catch return .{ .terminal = .internal_invariant };
    if (!std.meta.eql(out.*, Prepared{}) or
        !std.meta.eql(allocator, client.allocator))
        return .{ .terminal = .internal_invariant };
    if (!decision_mod.decisionMatches(client, input, decision, scratch))
        return .{ .terminal = .inconsistent_source };
    const live = switch (decision.verdict) {
        .adopted => |live| live,
        else => return .{ .terminal = .inconsistent_source },
    };

    out.saved_self_addr = @intFromPtr(out);
    out.lifecycle = .prepared;
    switch (live.metadata) {
        .unsupported => {
            out.metadata = .unsupported;
            out.prepared_footprint = .{
                .resident_delta = 0,
                .prepare_peak_delta = 0,
            };
        },
        .unavailable => {
            out.metadata = .unavailable;
            out.prepared_footprint = .{
                .resident_delta = 0,
                .prepare_peak_delta = 0,
            };
        },
        .initial => {
            const binding = decision.fold.binding_seal.initial_metadata;
            const footprint = initialResidentFootprint(binding) orelse {
                out.deinit();
                return .{ .terminal = .inconsistent_source };
            };
            out.metadata = .{ .initial = binding };
            out.prepared_footprint = footprint;
        },
        .event => |candidate| {
            var dto = client.materializeExternalMetadataEvent(
                allocator,
                input,
                decision.fold,
                candidate,
                scratch,
            ) catch |err| {
                out.deinit();
                return switch (err) {
                    error.OutOfMemory => if (decision_mod.decisionMatches(
                        client,
                        input,
                        decision,
                        scratch,
                    ))
                        .{ .retryable_preserved = .out_of_memory }
                    else
                        .{ .terminal = .inconsistent_source },
                    error.ResourceExhausted => .{ .terminal = .resource_exhausted },
                    else => .{ .terminal = .inconsistent_source },
                };
            };
            defer dto.deinit();
            const footprint = eventFootprint(
                decision.fold.binding_seal.initial_metadata,
                &dto,
            ) orelse {
                out.deinit();
                return .{ .terminal = .resource_exhausted };
            };
            out.metadata = .{ .event = .{} };
            if (!out.metadata.event.initInPlace(&dto, candidate, footprint)) {
                out.deinit();
                return .{ .terminal = .internal_invariant };
            }
            out.prepared_footprint = footprint;
        },
    }
    if (!decision_mod.decisionMatches(client, input, decision, scratch) or
        !out.validate(client, input, decision, scratch))
    {
        out.deinit();
        return .{ .terminal = .inconsistent_source };
    }
    return .{ .prepared = out.footprint(
        client,
        input,
        decision,
        scratch,
    ) orelse {
        out.deinit();
        return .{ .terminal = .internal_invariant };
    } };
}

fn rangesOverlap(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_end = @addWithOverflow(a_start, a_len);
    const b_end = @addWithOverflow(b_start, b_len);
    if (a_end[1] != 0 or b_end[1] != 0) return true;
    return a_start < b_end[0] and b_start < a_end[0];
}

fn canonicalDescriptorMatches(
    owner: *const PreparedOwnedMetadata,
    seal: ?runtime_metadata_wire.OwnedMetadataSeal,
    dto: *const runtime_metadata_wire.OwnedMetadataDto,
) bool {
    const value = seal orelse return false;
    return owner.allocator_ptr_addr == value.allocator_ptr_addr and
        owner.allocator_vtable_addr == value.allocator_vtable_addr and
        owner.backing_present == value.backing_present and
        owner.backing_addr == value.backing_addr and
        owner.backing_len == value.backing_len and
        runtime_metadata_wire.validateOwnedMetadataDescriptor(value, dto);
}

fn eventResidentBytes(
    dto: *const runtime_metadata_wire.OwnedMetadataDto,
) usize {
    return std.math.add(
        usize,
        @sizeOf(runtime_metadata_wire.OwnedMetadataDto),
        if (dto.backing) |bytes| bytes.len else 0,
    ) catch std.math.maxInt(usize);
}

fn footprintIsZero(footprint: PreparedMetadataFootprint) bool {
    return footprint.resident_delta == 0 and
        footprint.prepare_peak_delta == 0;
}

fn initialResidentFootprint(
    binding: client_mod.InitialMetadataBindingSeal,
) ?PreparedMetadataFootprint {
    return switch (binding) {
        .current => |current| blk: {
            if (current.seal.tag != .current or
                current.seed_address != current.seal.seed_addr)
                return null;
            const resident = std.math.add(
                usize,
                @sizeOf(runtime_metadata_wire.OwnedMetadataDto),
                current.seal.backing_len,
            ) catch return null;
            break :blk .{
                .resident_delta = resident,
                .prepare_peak_delta = resident,
            };
        },
        .unsupported, .unavailable => null,
    };
}

fn eventFootprint(
    binding: client_mod.InitialMetadataBindingSeal,
    dto: *const runtime_metadata_wire.OwnedMetadataDto,
) ?PreparedMetadataFootprint {
    const event_resident = eventResidentBytes(dto);
    if (event_resident == std.math.maxInt(usize)) return null;
    const initial_resident = switch (binding) {
        .unsupported, .unavailable => 0,
        .current => |current| blk: {
            if (current.seal.tag != .current or
                current.seed_address != current.seal.seed_addr)
                return null;
            break :blk std.math.add(
                usize,
                @sizeOf(runtime_metadata_wire.OwnedMetadataDto),
                current.seal.backing_len,
            ) catch return null;
        },
    };
    return .{
        .resident_delta = event_resident,
        .prepare_peak_delta = std.math.add(
            usize,
            initial_resident,
            event_resident,
        ) catch return null,
    };
}

const TestClient = struct {
    client: client_mod.Client,
    peer_fd: c.fd_t,

    fn init(allocator: std.mem.Allocator) !TestClient {
        var fds: [2]c.fd_t = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
        );
        var client = client_mod.Client{
            .allocator = allocator,
            .fd = fds[0],
            .host_id = 1,
            .wire_major = protocol.version_major,
            .parser = framing.FrameParser.init(allocator),
        };
        errdefer {
            client.deinit();
            _ = c.close(fds[1]);
        }
        try client.enterExternalMode();
        client.ownership = .external_pump;
        client.connection_profile = .cli_attach;
        client.compatibility_profile =
            compatibility.profileForMajor(protocol.version_major).?;
        client.attach_instance_id = 77;
        return .{ .client = client, .peer_fd = fds[1] };
    }

    fn deinit(self: *TestClient) void {
        self.client.deinit();
        if (self.peer_fd >= 0) _ = c.close(self.peer_fd);
        self.peer_fd = -1;
    }
};

const MutatingFailAllocator = struct {
    parent: std.mem.Allocator,
    source: *client_mod.Client,
    fired: bool = false,

    fn allocator(self: *MutatingFailAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        context: *anyopaque,
        _: usize,
        _: std.mem.Alignment,
        _: usize,
    ) ?[*]u8 {
        const self: *MutatingFailAllocator = @ptrCast(@alignCast(context));
        if (!self.fired) {
            self.fired = true;
            self.source.pending_events.items[0].payload[0] ^= 1;
        }
        return null;
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
        context: *anyopaque,
        bytes: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *MutatingFailAllocator = @ptrCast(@alignCast(context));
        self.parent.vtable.free(
            self.parent.ptr,
            bytes,
            alignment,
            return_address,
        );
    }
};

test "prepared metadata scalar winners allocate nothing and stay address bound" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var fixture = try TestClient.init(counting.allocator());
    defer fixture.deinit();
    const input = client_mod.ExternalAdoptionFoldInput{
        .identity = .{ .runtime_id = 0xaa, .stream_id = 7 },
        .authority = .{ .role = .observer, .generation = .untracked },
        .initial_metadata = .unsupported,
    };
    var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
    const fold = try fixture.client.foldExternalAdoptionSource(input, &scratch);
    const decision = decision_mod.decide(
        &fixture.client,
        input,
        fold,
        &scratch,
    );
    const allocations_before = counting.allocations;
    var prepared: Prepared = .{};
    defer prepared.deinit();
    const result = prepareInPlace(
        &prepared,
        counting.allocator(),
        &fixture.client,
        input,
        decision,
        &scratch,
    );
    try std.testing.expect(result == .prepared);
    try std.testing.expectEqual(@as(usize, 0), result.prepared.resident_delta);
    try std.testing.expectEqual(allocations_before, counting.allocations);
    try std.testing.expect(prepared.metadata == .unsupported);

    var moved = prepared;
    moved.deinit();
    try std.testing.expect(prepared.validate(
        &fixture.client,
        input,
        decision,
        &scratch,
    ));
}

test "prepare rejects a destination nested inside Client-owned payload before writing it" {
    const allocator = std.testing.allocator;
    var fixture = try TestClient.init(allocator);
    defer fixture.deinit();
    const input = client_mod.ExternalAdoptionFoldInput{
        .identity = .{ .runtime_id = 0xaa, .stream_id = 7 },
        .authority = .{ .role = .observer, .generation = .untracked },
        .initial_metadata = .unsupported,
    };
    var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
    const fold = try fixture.client.foldExternalAdoptionSource(input, &scratch);
    const decision = decision_mod.decide(
        &fixture.client,
        input,
        fold,
        &scratch,
    );
    const allocation = try allocator.alloc(
        u8,
        @sizeOf(Prepared) + @alignOf(Prepared),
    );
    const aligned_addr = std.mem.alignForward(
        usize,
        @intFromPtr(allocation.ptr),
        @alignOf(Prepared),
    );
    const out: *Prepared = @ptrFromInt(aligned_addr);
    out.* = .{};
    try fixture.client.pending_events.append(allocator, .{
        .header = .{
            .kind = .event,
            .stream_id = input.identity.stream_id,
            .payload_len = @intCast(allocation.len),
        },
        .payload = allocation,
    });
    fixture.client.pending_event_bytes = allocation.len;
    const before = try allocator.dupe(u8, allocation);
    defer allocator.free(before);
    const result = prepareInPlace(
        out,
        allocator,
        &fixture.client,
        input,
        decision,
        &scratch,
    );
    try std.testing.expect(result == .terminal);
    try std.testing.expect(result.terminal == .internal_invariant);
    try std.testing.expectEqualSlices(u8, before, allocation);
}

test "prepared metadata owns only the exact event winner and rejects stale decisions" {
    const allocator = std.testing.allocator;
    var fixture = try TestClient.init(allocator);
    defer fixture.deinit();
    fixture.client.metadata_support = .supported;
    const input = client_mod.ExternalAdoptionFoldInput{
        .identity = .{ .runtime_id = 0xaa, .stream_id = 7 },
        .authority = .{ .role = .observer, .generation = .untracked },
        .initial_metadata = .unavailable,
    };
    const payload_text =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":\"host\",\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":7,\"processes\":[{\"pid\":7,\"name\":\"zsh\"}]}}";
    const payload = try allocator.dupe(u8, payload_text);
    try fixture.client.pending_events.append(allocator, .{
        .header = .{
            .kind = .event,
            .stream_id = input.identity.stream_id,
            .payload_len = @intCast(payload.len),
        },
        .payload = payload,
    });
    fixture.client.pending_event_bytes = payload.len;
    var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
    const fold = try fixture.client.foldExternalAdoptionSource(input, &scratch);
    const decision = decision_mod.decide(
        &fixture.client,
        input,
        fold,
        &scratch,
    );
    try std.testing.expect(decision.verdict == .adopted);
    try std.testing.expect(decision.verdict.adopted.metadata == .event);

    var prepared: Prepared = .{};
    defer prepared.deinit();
    const result = prepareInPlace(
        &prepared,
        allocator,
        &fixture.client,
        input,
        decision,
        &scratch,
    );
    try std.testing.expect(result == .prepared);
    try std.testing.expect(result.prepared.resident_delta >=
        @sizeOf(runtime_metadata_wire.OwnedMetadataDto));
    try std.testing.expectEqual(
        result.prepared.resident_delta,
        result.prepared.prepare_peak_delta,
    );
    try std.testing.expectEqualStrings(
        "/repo",
        prepared.metadata.event.logical.?.cwd(),
    );
    try std.testing.expect(prepared.validate(
        &fixture.client,
        input,
        decision,
        &scratch,
    ));
    prepared.prepared_footprint.resident_delta -= 1;
    try std.testing.expect(!prepared.validate(
        &fixture.client,
        input,
        decision,
        &scratch,
    ));
    try std.testing.expect(prepared.footprint(
        &fixture.client,
        input,
        decision,
        &scratch,
    ) == null);
    prepared.prepared_footprint.resident_delta += 1;

    // A self-consistent replacement DTO and matching mutable mirror seals are still rejected
    // because validation rebinds the owner to the exact live decision candidate.
    prepared.metadata.event.cleanup.?.deinit();
    var alternate_seed = try runtime_metadata_wire.testingCurrentSeed(allocator);
    alternate_seed.current.backing.?[0] = 'X';
    var alternate = alternate_seed.current.take();
    alternate_seed.deinit();
    defer alternate.deinit();
    const replacement = alternate.take();
    prepared.metadata.event.logical = replacement;
    prepared.metadata.event.cleanup = replacement;
    prepared.metadata.event.allocator_ptr_addr =
        @intFromPtr(replacement.allocator.ptr);
    prepared.metadata.event.allocator_vtable_addr =
        @intFromPtr(replacement.allocator.vtable);
    prepared.metadata.event.backing_present = replacement.backing != null;
    prepared.metadata.event.backing_addr =
        if (replacement.backing) |bytes| @intFromPtr(bytes.ptr) else 0;
    prepared.metadata.event.backing_len =
        if (replacement.backing) |bytes| bytes.len else 0;
    prepared.metadata.event.logical_seal =
        try runtime_metadata_wire.sealOwnedMetadataDto(
            &prepared.metadata.event.logical.?,
        );
    prepared.metadata.event.cleanup_seal =
        try runtime_metadata_wire.sealOwnedMetadataDto(
            &prepared.metadata.event.cleanup.?,
        );
    const replacement_footprint = eventFootprint(
        decision.fold.binding_seal.initial_metadata,
        &prepared.metadata.event.logical.?,
    ).?;
    prepared.metadata.event.footprint = replacement_footprint;
    prepared.prepared_footprint = replacement_footprint;
    try std.testing.expect(!prepared.validate(
        &fixture.client,
        input,
        decision,
        &scratch,
    ));

    fixture.client.pending_events.items[0].payload[
        std.mem.indexOf(u8, payload, "/repo").? + 1
    ] = 'R';
    try std.testing.expect(!prepared.validate(
        &fixture.client,
        input,
        decision,
        &scratch,
    ));
}

test "event materialization reports unchanged allocation failure as retryable" {
    const allocator = std.testing.allocator;
    var fixture = try TestClient.init(allocator);
    defer fixture.deinit();
    fixture.client.metadata_support = .supported;
    const input = client_mod.ExternalAdoptionFoldInput{
        .identity = .{ .runtime_id = 0xaa, .stream_id = 7 },
        .authority = .{ .role = .observer, .generation = .untracked },
        .initial_metadata = .unavailable,
    };
    const payload_text =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":false,\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}";
    const payload = try allocator.dupe(u8, payload_text);
    try fixture.client.pending_events.append(allocator, .{
        .header = .{
            .kind = .event,
            .stream_id = input.identity.stream_id,
            .payload_len = @intCast(payload.len),
        },
        .payload = payload,
    });
    fixture.client.pending_event_bytes = payload.len;
    var failing = std.testing.FailingAllocator.init(
        allocator,
        .{ .fail_index = 0 },
    );
    const saved_allocator = fixture.client.allocator;
    const saved_parser_allocator = fixture.client.parser.allocator;
    fixture.client.allocator = failing.allocator();
    fixture.client.parser.allocator = failing.allocator();
    var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
    const fold = try fixture.client.foldExternalAdoptionSource(input, &scratch);
    const decision = decision_mod.decide(
        &fixture.client,
        input,
        fold,
        &scratch,
    );
    var prepared: Prepared = .{};
    const result = prepareInPlace(
        &prepared,
        failing.allocator(),
        &fixture.client,
        input,
        decision,
        &scratch,
    );
    fixture.client.allocator = saved_allocator;
    fixture.client.parser.allocator = saved_parser_allocator;
    try std.testing.expect(result == .retryable_preserved);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(prepared.lifecycle == .aborted_tombstone);
    try std.testing.expect(prepared.metadata == .unavailable);
}

test "allocation failure after source mutation is terminal rather than retryable" {
    const allocator = std.testing.allocator;
    var fixture = try TestClient.init(allocator);
    defer fixture.deinit();
    fixture.client.metadata_support = .supported;
    const input = client_mod.ExternalAdoptionFoldInput{
        .identity = .{ .runtime_id = 0xaa, .stream_id = 7 },
        .authority = .{ .role = .observer, .generation = .untracked },
        .initial_metadata = .unavailable,
    };
    const payload_text =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":false,\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}";
    const payload = try allocator.dupe(u8, payload_text);
    try fixture.client.pending_events.append(allocator, .{
        .header = .{
            .kind = .event,
            .stream_id = input.identity.stream_id,
            .payload_len = @intCast(payload.len),
        },
        .payload = payload,
    });
    fixture.client.pending_event_bytes = payload.len;
    var probe = MutatingFailAllocator{
        .parent = allocator,
        .source = &fixture.client,
    };
    const saved_allocator = fixture.client.allocator;
    const saved_parser_allocator = fixture.client.parser.allocator;
    fixture.client.allocator = probe.allocator();
    fixture.client.parser.allocator = probe.allocator();
    var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
    const fold = try fixture.client.foldExternalAdoptionSource(input, &scratch);
    const decision = decision_mod.decide(
        &fixture.client,
        input,
        fold,
        &scratch,
    );
    var prepared: Prepared = .{};
    const result = prepareInPlace(
        &prepared,
        probe.allocator(),
        &fixture.client,
        input,
        decision,
        &scratch,
    );
    fixture.client.allocator = saved_allocator;
    fixture.client.parser.allocator = saved_parser_allocator;
    try std.testing.expect(probe.fired);
    try std.testing.expect(result == .terminal);
    try std.testing.expect(result.terminal == .inconsistent_source);
    try std.testing.expect(prepared.lifecycle == .aborted_tombstone);
}

test "prepared event cleanup falls back to the sealed mirror exactly once" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var seed = try runtime_metadata_wire.testingCurrentSeed(counting.allocator());
    var dto = seed.current.take();
    seed.deinit();
    defer dto.deinit();
    const resident = @sizeOf(runtime_metadata_wire.OwnedMetadataDto) +
        (if (dto.backing) |bytes| bytes.len else 0);
    var owned: PreparedOwnedMetadata = .{};
    try std.testing.expect(owned.initInPlace(
        &dto,
        try testMetadataCandidate(),
        .{
            .resident_delta = resident,
            .prepare_peak_delta = resident,
        },
    ));
    owned.logical.?.revision += 1;
    const frees_before = counting.deallocations;
    owned.deinit();
    owned.deinit();
    try std.testing.expectEqual(frees_before + 1, counting.deallocations);
    try std.testing.expect(owned.lifecycle == .aborted_tombstone);
    try std.testing.expect(owned.logical == null);
    try std.testing.expect(owned.cleanup == null);
}

test "prepared event cleanup never follows a poisoned canonical allocator seal" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var seed = try runtime_metadata_wire.testingCurrentSeed(counting.allocator());
    var dto = seed.current.take();
    seed.deinit();
    defer dto.deinit();
    const resident = eventResidentBytes(&dto);
    var owned: PreparedOwnedMetadata = .{};
    try std.testing.expect(owned.initInPlace(
        &dto,
        try testMetadataCandidate(),
        .{
            .resident_delta = resident,
            .prepare_peak_delta = resident,
        },
    ));
    var recovery = owned.logical.?;
    owned.allocator_ptr_addr +%= 1;
    const frees_before = counting.deallocations;
    owned.deinit();
    try std.testing.expectEqual(frees_before, counting.deallocations);
    recovery.deinit();
    try std.testing.expectEqual(frees_before + 1, counting.deallocations);
}

test "event prepare peak is exact initial baseline plus staged winner" {
    const allocator = std.testing.allocator;
    var initial = try runtime_metadata_wire.testingCurrentSeed(allocator);
    defer initial.deinit();
    var initial_seal = try runtime_metadata_wire.sealMetadataSeed(&initial);
    initial_seal.backing_len = 4096;
    const binding = client_mod.InitialMetadataBindingSeal{ .current = .{
        .seed_address = @intFromPtr(&initial),
        .seal = initial_seal,
    } };

    var event = try runtime_metadata_wire.testingCurrentSeed(allocator);
    defer event.deinit();
    const event_resident = eventResidentBytes(&event.current);
    const initial_resident = @sizeOf(runtime_metadata_wire.OwnedMetadataDto) +
        initial_seal.backing_len;
    const footprint = eventFootprint(binding, &event.current).?;
    try std.testing.expectEqual(event_resident, footprint.resident_delta);
    try std.testing.expectEqual(
        initial_resident + event_resident,
        footprint.prepare_peak_delta,
    );
    try std.testing.expect(footprint.prepare_peak_delta >
        footprint.resident_delta * 2);
}

fn testMetadataCandidate() !runtime_event_reducer.MetadataCandidate {
    const payload =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":false,\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}";
    const accepted = switch (runtime_event_wire.preflightEvent(payload, .{})) {
        .accepted => |accepted| accepted,
        else => return error.TestUnexpectedResult,
    };
    const metadata = switch (accepted.event) {
        .metadata => |metadata| metadata,
        else => return error.TestUnexpectedResult,
    };
    return .{
        .origin = .{ .event = 0 },
        .raw_digest = accepted.raw_digest,
        .semantic_digest = .{ .event = metadata.semantic_digest },
        .proof = .{ .event = accepted },
    };
}
