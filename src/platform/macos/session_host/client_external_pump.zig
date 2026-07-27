//! Stable, address-bound storage for the public attach external pump.
//!
//! The storage is initialized only in its caller-owned final address. It keeps the raw Client and
//! inbox ledger behind one lifecycle boundary so later token-bearing slices never need to recover
//! from a moved owner.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const client_mod = @import("client.zig");
const client_external_mode = @import("client_external_mode.zig");
const client_pump = @import("client_pump.zig");
const external_inbox_ledger = @import("external_inbox_ledger.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");

pub const AttachmentRole = enum {
    observer,
    controller,
};

/// Immutable evidence captured at attach publication. Live authority is adopted in 2b2c and must
/// not be inferred by mutating this snapshot.
pub const AttachmentEvidence = struct {
    runtime_id: u128,
    stream_id: u64,
    initial_role: AttachmentRole,
    initial_controller_generation: u64,
};

pub const SourceDisposition = enum {
    preserved,
    consumed_and_closed,
};

pub const InitFailureReason = enum {
    destination_not_empty,
    overlapping_storage,
    invalid_evidence,
    connection_closed,
    source_not_external,
    source_already_bound,
    resident_too_large,
    malformed_parser,
    out_of_memory,
    invariant_failure,
};

pub const InitFailure = struct {
    reason: InitFailureReason,
    source_disposition: SourceDisposition,
};

pub const InitResult = union(enum) {
    initialized,
    failed: InitFailure,
};

pub const StorageLifecycle = enum {
    empty,
    constructing,
    adopting,
    live,
    tearing_down,
    dead,
};

pub const TeardownResult = enum {
    cleaned,
    already_dead,
    moved_storage,
    ledger_not_zero,
};

pub const AccessError = error{
    Empty,
    NotActive,
    Terminal,
    MovedStorage,
};

const InitOptions = struct {
    failpoint: enum {
        none,
        after_client_move,
    } = .none,
    resident_cap: usize = protocol.max_binary_chunk + protocol.header_size,
};

pub const max_fixed_inline_storage_bytes: usize = 512 * 1024;

pub const ExternalPumpStorage = struct {
    lifecycle: StorageLifecycle = .empty,
    saved_self_addr: usize = 0,
    semantic_state: client_pump.ExternalPumpState = .constructing,
    evidence_snapshot: AttachmentEvidence = .{
        .runtime_id = 0,
        .stream_id = 0,
        .initial_role = .observer,
        .initial_controller_generation = 0,
    },
    owned_client: ?client_mod.Client = null,
    inbox_ledger: external_inbox_ledger.ExternalInboxLedger = .{},

    pub fn initInPlace(
        out: *ExternalPumpStorage,
        source: *client_mod.Client,
        evidence: AttachmentEvidence,
    ) InitResult {
        return initInPlaceWithOptions(out, source, evidence, .{});
    }

    fn initInPlaceWithOptions(
        out: *ExternalPumpStorage,
        source: *client_mod.Client,
        evidence: AttachmentEvidence,
        options: InitOptions,
    ) InitResult {
        // Pointer arithmetic and overlap rejection happen before interpreting destination fields:
        // a malicious alias must not let an `out.* = ...` overwrite the source Client.
        if (rangesOverlap(
            @intFromPtr(out),
            @sizeOf(ExternalPumpStorage),
            @intFromPtr(source),
            @sizeOf(client_mod.Client),
        )) {
            return failed(.overlapping_storage, .preserved);
        }
        if (out.lifecycle != .empty)
            return failed(.destination_not_empty, .preserved);
        if (evidence.runtime_id == 0 or evidence.stream_id == 0)
            return failed(.invalid_evidence, .preserved);

        out.* = .{
            .lifecycle = .constructing,
            .saved_self_addr = @intFromPtr(out),
            .semantic_state = .constructing,
            .evidence_snapshot = evidence,
        };

        source.transferToExternalPump(
            &out.owned_client,
            options.resident_cap,
        ) catch |err| {
            out.* = .{};
            return switch (err) {
                error.ConnectionClosed => failed(.connection_closed, .preserved),
                error.NotExternal => failed(.source_not_external, .preserved),
                error.DestinationOccupied => failed(.destination_not_empty, .preserved),
                error.AlreadyBound => failed(.source_already_bound, .preserved),
                error.ResidentTooLarge => failed(.resident_too_large, .preserved),
                error.MalformedParser => failed(.malformed_parser, .preserved),
                error.OutOfMemory => failed(.out_of_memory, .preserved),
            };
        };

        // transferToExternalPump has no fallible operation after parser normalization. At this
        // point the source is a deinit-safe tombstone and this exact address is the sole owner.
        out.lifecycle = .adopting;
        out.semantic_state = .adopting;
        if (options.failpoint == .after_client_move) {
            _ = out.closeOwned(.invariant_failure);
            return failed(.invariant_failure, .consumed_and_closed);
        }
        return .initialized;
    }

    /// 2b2b never reaches active; this gate prevents a caller from treating successful storage
    /// construction as authority adoption.
    pub fn requireActive(self: *ExternalPumpStorage) AccessError!void {
        try self.requireAddress();
        return switch (self.lifecycle) {
            .empty => error.Empty,
            .adopting, .constructing => error.NotActive,
            .live => switch (self.semantic_state) {
                .active => {},
                .terminal => error.Terminal,
                else => error.NotActive,
            },
            .tearing_down, .dead => error.Terminal,
        };
    }

    pub fn teardown(self: *ExternalPumpStorage) TeardownResult {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self))
            return .moved_storage;
        return switch (self.lifecycle) {
            .empty, .dead, .tearing_down => .already_dead,
            .constructing, .adopting, .live => self.closeOwned(.invariant_failure),
        };
    }

    fn requireAddress(self: *const ExternalPumpStorage) AccessError!void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self))
            return error.MovedStorage;
    }

    fn closeOwned(
        self: *ExternalPumpStorage,
        reason: client_pump.TerminalReason,
    ) TeardownResult {
        self.lifecycle = .tearing_down;
        self.semantic_state = .{ .terminal = .{
            .reason = reason,
            .fd_disposition = .owner_cleanup,
        } };
        if (self.owned_client) |*owned| owned.deinit();
        self.owned_client = null;
        const drain_report = self.inbox_ledger.drainAll();
        const ledger_result = self.inbox_ledger.finish();
        self.lifecycle = .dead;
        if (drain_report.drained_active_count != 0 or
            drain_report.had_sticky_invariant)
            return .ledger_not_zero;
        return if (ledger_result) |_| .cleaned else |_| .ledger_not_zero;
    }
};

pub const StorageFootprint = struct {
    pointer_bits: usize,
    fixed_inline_storage_bytes: usize,
    ledger_inline_bytes: usize,
    preallocated_transport_descriptor_bytes: usize,
};

pub const storage_footprint: StorageFootprint = .{
    .pointer_bits = @bitSizeOf(usize),
    .fixed_inline_storage_bytes = @sizeOf(ExternalPumpStorage),
    .ledger_inline_bytes = @sizeOf(external_inbox_ledger.ExternalInboxLedger),
    .preallocated_transport_descriptor_bytes = client_external_mode.max_tx_frames * @sizeOf(client_external_mode.ExternalTxFrame),
};

comptime {
    if (@bitSizeOf(usize) == 64 and
        storage_footprint.fixed_inline_storage_bytes > max_fixed_inline_storage_bytes)
        @compileError("ExternalPumpStorage exceeds the 64-bit fixed inline storage budget");
}

fn failed(reason: InitFailureReason, disposition: SourceDisposition) InitResult {
    return .{ .failed = .{
        .reason = reason,
        .source_disposition = disposition,
    } };
}

fn rangesOverlap(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

const TestClient = struct {
    client: client_mod.Client,
    peer_fd: c.fd_t,

    fn init() !TestClient {
        return initWithAllocator(std.testing.allocator);
    }

    fn initWithAllocator(allocator: std.mem.Allocator) !TestClient {
        var fds: [2]c.fd_t = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
        );
        var client: client_mod.Client = .{
            .allocator = allocator,
            .fd = fds[0],
            .host_id = 1,
            .parser = framing.FrameParser.init(allocator),
        };
        errdefer {
            client.deinit();
            _ = c.close(fds[1]);
        }
        try client.enterExternalMode();
        return .{ .client = client, .peer_fd = fds[1] };
    }

    fn deinitPeer(self: *TestClient) void {
        if (self.peer_fd >= 0) _ = c.close(self.peer_fd);
        self.peer_fd = -1;
    }
};

const valid_evidence: AttachmentEvidence = .{
    .runtime_id = 0xaa,
    .stream_id = 7,
    .initial_role = .controller,
    .initial_controller_generation = 3,
};

test "external pump storage initializes only at its stable address and remains inactive" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const owned_fd = fixture.client.fd;
    var storage: ExternalPumpStorage = .{};

    try std.testing.expect(
        ExternalPumpStorage.initInPlace(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);
    try std.testing.expectError(error.NotActive, storage.requireActive());
    try std.testing.expectEqual(@as(c.fd_t, -1), fixture.client.fd);
    fixture.client.deinit(); // moved-from cleanup must not close/free the destination owner.
    fixture.client.deinit(); // the tombstone itself is an idempotent no-op.
    try std.testing.expect(c.fcntl(owned_fd, c.F.GETFD, @as(c_int, 0)) >= 0);
    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
    try std.testing.expect(c.fcntl(owned_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(TeardownResult.already_dead, storage.teardown());
}

test "external pump storage rejects transfer of its already-bound Client" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        ExternalPumpStorage.initInPlace(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    const owned_fd = storage.owned_client.?.fd;
    var second_slot: ?client_mod.Client = null;
    try std.testing.expectError(
        error.AlreadyBound,
        storage.owned_client.?.transferToExternalPump(
            &second_slot,
            protocol.max_binary_chunk + protocol.header_size,
        ),
    );
    try std.testing.expect(second_slot == null);
    try std.testing.expectEqual(owned_fd, storage.owned_client.?.fd);
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);

    var second_storage: ExternalPumpStorage = .{};
    const failure = ExternalPumpStorage.initInPlace(
        &second_storage,
        &storage.owned_client.?,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.source_already_bound, failure.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, failure.source_disposition);
    try std.testing.expectEqual(StorageLifecycle.empty, second_storage.lifecycle);
    try std.testing.expectEqual(owned_fd, storage.owned_client.?.fd);
    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
}

test "external pump storage preflight failures preserve source and leave destination empty" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    const fd = fixture.client.fd;
    var storage: ExternalPumpStorage = .{};

    const invalid = ExternalPumpStorage.initInPlace(
        &storage,
        &fixture.client,
        .{
            .runtime_id = 0,
            .stream_id = 7,
            .initial_role = .observer,
            .initial_controller_generation = 0,
        },
    ).failed;
    try std.testing.expectEqual(InitFailureReason.invalid_evidence, invalid.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, invalid.source_disposition);
    try std.testing.expectEqual(fd, fixture.client.fd);
    try std.testing.expectEqual(StorageLifecycle.empty, storage.lifecycle);

    storage.lifecycle = .adopting;
    const occupied = ExternalPumpStorage.initInPlace(
        &storage,
        &fixture.client,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.destination_not_empty, occupied.reason);
    try std.testing.expectEqual(fd, fixture.client.fd);
    storage = .{};
}

test "external pump storage rejects blocking and closed sources without ownership mutation" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = c.close(fds[1]);
    var blocking: client_mod.Client = .{
        .allocator = std.testing.allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(std.testing.allocator),
    };
    defer blocking.deinit();
    var storage: ExternalPumpStorage = .{};
    const blocking_failure = ExternalPumpStorage.initInPlace(
        &storage,
        &blocking,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.source_not_external, blocking_failure.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, blocking_failure.source_disposition);
    try std.testing.expectEqual(fds[0], blocking.fd);
    try std.testing.expectEqual(StorageLifecycle.empty, storage.lifecycle);

    var closed = try TestClient.init();
    defer closed.deinitPeer();
    defer closed.client.deinit();
    closed.client.failClosed();
    const closed_failure = ExternalPumpStorage.initInPlace(
        &storage,
        &closed.client,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.connection_closed, closed_failure.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, closed_failure.source_disposition);
    try std.testing.expectEqual(StorageLifecycle.empty, storage.lifecycle);
}

test "external pump storage live reinit preserves both existing and candidate owners" {
    var first = try TestClient.init();
    defer first.deinitPeer();
    var second = try TestClient.init();
    defer second.deinitPeer();
    defer second.client.deinit();
    const second_fd = second.client.fd;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        ExternalPumpStorage.initInPlace(&storage, &first.client, valid_evidence) ==
            .initialized,
    );

    const failure = ExternalPumpStorage.initInPlace(
        &storage,
        &second.client,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.destination_not_empty, failure.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, failure.source_disposition);
    try std.testing.expectEqual(second_fd, second.client.fd);
    try std.testing.expectEqual(StorageLifecycle.adopting, storage.lifecycle);
    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
}

test "external pump storage normalize failures preserve every observable source owner" {
    const Scenario = enum { cap, oom, malformed };
    inline for (std.meta.tags(Scenario)) |scenario| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var fixture = try TestClient.initWithAllocator(failing.allocator());
        defer fixture.deinitPeer();
        defer {
            if (scenario == .malformed) fixture.client.parser.head = 0;
            fixture.client.deinit();
        }
        try fixture.client.parser.push("unread");
        if (scenario == .malformed)
            fixture.client.parser.head = fixture.client.parser.buf.items.len + 1;

        const fd = fixture.client.fd;
        const ptr = fixture.client.parser.buf.items.ptr;
        const len = fixture.client.parser.buf.items.len;
        const cap = fixture.client.parser.buf.capacity;
        const head = fixture.client.parser.head;
        const request_id = fixture.client.next_request_id;
        const stream_ptr = fixture.client.pending_stream.items.ptr;
        var storage: ExternalPumpStorage = .{};
        if (scenario == .oom) failing.fail_index = failing.alloc_index;
        const resident_cap = if (scenario == .cap) cap - 1 else cap;
        const failure = ExternalPumpStorage.initInPlaceWithOptions(
            &storage,
            &fixture.client,
            valid_evidence,
            .{ .resident_cap = resident_cap },
        ).failed;

        try std.testing.expectEqual(SourceDisposition.preserved, failure.source_disposition);
        try std.testing.expectEqual(
            switch (scenario) {
                .cap => InitFailureReason.resident_too_large,
                .oom => InitFailureReason.out_of_memory,
                .malformed => InitFailureReason.malformed_parser,
            },
            failure.reason,
        );
        try std.testing.expectEqual(fd, fixture.client.fd);
        try std.testing.expectEqual(ptr, fixture.client.parser.buf.items.ptr);
        try std.testing.expectEqual(len, fixture.client.parser.buf.items.len);
        try std.testing.expectEqual(cap, fixture.client.parser.buf.capacity);
        try std.testing.expectEqual(head, fixture.client.parser.head);
        try std.testing.expectEqual(request_id, fixture.client.next_request_id);
        try std.testing.expectEqual(stream_ptr, fixture.client.pending_stream.items.ptr);
        try std.testing.expectEqual(StorageLifecycle.empty, storage.lifecycle);
    }
}

test "external pump storage rejects source overlap before reading destination state" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    defer fixture.client.deinit();
    const fd = fixture.client.fd;
    const overlapping: *ExternalPumpStorage = @ptrCast(@alignCast(&fixture.client));
    const failure = ExternalPumpStorage.initInPlace(
        overlapping,
        &fixture.client,
        valid_evidence,
    ).failed;
    try std.testing.expectEqual(InitFailureReason.overlapping_storage, failure.reason);
    try std.testing.expectEqual(SourceDisposition.preserved, failure.source_disposition);
    try std.testing.expectEqual(fd, fixture.client.fd);
}

test "external pump storage post-move failure closes destination and tombstones source" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const owned_fd = fixture.client.fd;
    var storage: ExternalPumpStorage = .{};

    const result = ExternalPumpStorage.initInPlaceWithOptions(
        &storage,
        &fixture.client,
        valid_evidence,
        .{ .failpoint = .after_client_move },
    ).failed;
    try std.testing.expectEqual(InitFailureReason.invariant_failure, result.reason);
    try std.testing.expectEqual(SourceDisposition.consumed_and_closed, result.source_disposition);
    try std.testing.expectEqual(StorageLifecycle.dead, storage.lifecycle);
    try std.testing.expect(c.fcntl(owned_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    fixture.client.deinit();
    fixture.client.deinit();
    try std.testing.expectEqual(TeardownResult.already_dead, storage.teardown());
}

test "external pump storage teardown reports impossible 2b2b ledger charge after client cleanup" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const owned_fd = fixture.client.fd;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        ExternalPumpStorage.initInPlace(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    var allocation = try std.testing.allocator.dupe(u8, "x");
    var payload = external_inbox_ledger.OwnedPayload.takeOwned(
        std.testing.allocator,
        &allocation,
    );
    _ = try storage.inbox_ledger.reserveLease(.{
        .stream_id = 1,
        .is_snapshot = false,
    }, &payload);
    try std.testing.expectEqual(TeardownResult.ledger_not_zero, storage.teardown());
    try std.testing.expect(c.fcntl(owned_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(TeardownResult.already_dead, storage.teardown());
}

test "external pump storage teardown reentry cannot close a reused descriptor number" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    const old_fd = fixture.client.fd;
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        ExternalPumpStorage.initInPlace(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
    try std.testing.expect(c.fcntl(old_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(old_fd, c.dup2(fixture.peer_fd, old_fd));
    defer _ = c.close(old_fd);
    try std.testing.expectEqual(TeardownResult.already_dead, storage.teardown());
    try std.testing.expect(c.fcntl(old_fd, c.F.GETFD, @as(c_int, 0)) >= 0);
}

test "external pump storage forged value copy cannot clean the original owner" {
    var fixture = try TestClient.init();
    defer fixture.deinitPeer();
    var storage: ExternalPumpStorage = .{};
    try std.testing.expect(
        ExternalPumpStorage.initInPlace(&storage, &fixture.client, valid_evidence) ==
            .initialized,
    );
    var forged = storage;
    try std.testing.expectError(error.MovedStorage, forged.requireActive());
    try std.testing.expectEqual(TeardownResult.moved_storage, forged.teardown());
    try std.testing.expectEqual(TeardownResult.cleaned, storage.teardown());
}

test "external pump storage footprint is exact and bounded on 64-bit targets" {
    try std.testing.expectEqual(
        @sizeOf(ExternalPumpStorage),
        storage_footprint.fixed_inline_storage_bytes,
    );
    try std.testing.expectEqual(
        @sizeOf(external_inbox_ledger.ExternalInboxLedger),
        storage_footprint.ledger_inline_bytes,
    );
    if (@bitSizeOf(usize) == 64)
        try std.testing.expect(
            storage_footprint.fixed_inline_storage_bytes <= max_fixed_inline_storage_bytes,
        );
}

test "external pump storage overlap arithmetic covers partial and adjacent ranges" {
    try std.testing.expect(rangesOverlap(100, 20, 90, 11));
    try std.testing.expect(rangesOverlap(100, 20, 119, 20));
    try std.testing.expect(!rangesOverlap(100, 20, 80, 20));
    try std.testing.expect(!rangesOverlap(100, 20, 120, 20));
    try std.testing.expect(rangesOverlap(std.math.maxInt(usize) - 1, 4, 0, 1));
}
