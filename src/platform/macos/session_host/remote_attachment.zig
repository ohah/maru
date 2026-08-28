//! GUI `RemoteRuntime`과 public attach가 공유할 stream role/authority wire boundary.
//! Connection transport와 GUI Surface를 소유하지 않으며 strict host result/event를 attachment-local state로 접는다.

const std = @import("std");
const protocol = @import("protocol.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");
const client_mod = @import("client.zig");
const client_poison = @import("client_poison.zig");
const external_recovery_types = @import("external_recovery_types.zig");
const external_inbox_ledger = @import("external_inbox_ledger.zig");
const generation_batch_registry = @import("generation_batch_registry.zig");
const terminal_contract = @import("terminal_cleanup_handoff_contract.zig");
const remote_screen = @import("remote_screen.zig");
const screen_assembler = @import("maru").session.screen_assembler;
const screen_stream = @import("maru").session.screen_stream;
const catchup_stage_contract = @import("catchup_stage_contract.zig");

pub const AttachmentBatchLease = union(enum) {
    untracked: client_mod.StreamBatch,
    charged: external_inbox_ledger.Token,
    generation: generation_batch_registry.Token,

    fn borrow(
        self: AttachmentBatchLease,
        transport: AttachmentTransport,
    ) LeaseError!AttachmentBatchView {
        return switch (self) {
            .untracked => |batch| .{
                .is_snapshot = batch.is_snapshot,
                .stream_id = batch.stream_id,
                .recovery_key = null,
                .bytes = batch.bytes,
            },
            .charged => |token| {
                const borrow_charged = transport.borrow_charged orelse
                    return error.LedgerInvariant;
                return borrow_charged(transport.context, token) catch
                    return error.LedgerInvariant;
            },
            .generation => |token| {
                const borrow_generation = transport.borrow_generation orelse
                    return error.LedgerInvariant;
                return borrow_generation(transport.context, token) catch
                    return error.LedgerInvariant;
            },
        };
    }

    fn release(
        self: AttachmentBatchLease,
        transport: AttachmentTransport,
    ) enum { completed, retryable_preserved, indeterminate_or_partial, invariant_failure } {
        switch (self) {
            .untracked => |batch| {
                batch.deinit();
                return .completed;
            },
            .charged => |token| {
                const release_charged = transport.release_charged orelse
                    return .invariant_failure;
                release_charged(transport.context, token) catch
                    return .retryable_preserved;
                return .completed;
            },
            .generation => |token| {
                const release_generation = transport.release_generation orelse
                    return .invariant_failure;
                return switch (release_generation(transport.context, token) catch
                    return .invariant_failure) {
                    .completed => .completed,
                    .retryable_preserved => .retryable_preserved,
                    .indeterminate_or_partial => .indeterminate_or_partial,
                };
            },
        }
    }
};

pub const LeaseError = error{LedgerInvariant};
pub const GenerationReleaseResult = generation_batch_registry.GenerationReleaseResult;

/// Attachment consumer가 공유하는 transport-neutral batch view. External ledger의 저장
/// provenance는 transport 내부에 남기고 consumer에는 recovery key만 투영한다.
pub const AttachmentBatchView = struct {
    is_snapshot: bool,
    stream_id: u64,
    recovery_key: ?external_recovery_types.Key,
    bytes: []const u8,
};

pub const MarkResyncAppliedResult = external_recovery_types.MarkResult;

pub const PumpScreenResult = enum {
    idle,
    applied,
    recovery_commit_pending,
    terminal,
};

pub const TerminalCleanupView = struct {
    failed: ?AttachmentBatchLease,
    pending: []const AttachmentBatchLease,
    token_count: u32,
};

pub const TerminalCleanupViewError = error{InvalidTerminalCleanup};

const ReleaseDisposition = enum { completed, retained_retry, terminal_handoff, corrupt };

const FailedReleaseState = enum(u8) {
    none,
    retryable,
    indeterminate,
};

pub const PayloadDeinitOutcome = enum { cleaned, terminal_handoff, corrupt };

fn terminalTestTransport() AttachmentTransport {
    const Fixture = struct {
        fn read(_: *anyopaque, _: u64) client_mod.ClientError!?AttachmentBatchLease {
            return null;
        }
        fn drop(_: *anyopaque, _: u64) void {}
        fn failClosed(_: *anyopaque, _: client_poison.ConnectionReason) void {}
    };
    return .{
        .context = @ptrFromInt(@alignOf(usize)),
        .read_batch = Fixture.read,
        .drop_stream = Fixture.drop,
        .fail_closed = Fixture.failClosed,
    };
}

pub const AttachmentTransport = struct {
    context: *anyopaque,
    read_batch: *const fn (
        context: *anyopaque,
        stream_id: u64,
    ) client_mod.ClientError!?AttachmentBatchLease,
    borrow_charged: ?*const fn (
        context: *anyopaque,
        token: external_inbox_ledger.Token,
    ) external_inbox_ledger.InvariantError!AttachmentBatchView = null,
    release_charged: ?*const fn (
        context: *anyopaque,
        token: external_inbox_ledger.Token,
    ) external_inbox_ledger.InvariantError!void = null,
    borrow_generation: ?*const fn (
        context: *anyopaque,
        token: generation_batch_registry.Token,
    ) LeaseError!AttachmentBatchView = null,
    release_generation: ?*const fn (
        context: *anyopaque,
        token: generation_batch_registry.Token,
    ) LeaseError!GenerationReleaseResult = null,
    preflight_batch_authority: ?*const fn (
        context: *anyopaque,
        stream_id: u64,
        is_snapshot: bool,
        key: ?external_recovery_types.Key,
    ) external_recovery_types.BatchAuthority = null,
    mark_resync_applied: ?*const fn (
        context: *anyopaque,
        stream_id: u64,
        key: external_recovery_types.Key,
    ) MarkResyncAppliedResult = null,
    drop_stream: *const fn (context: *anyopaque, stream_id: u64) void,
    fail_closed: *const fn (context: *anyopaque, reason: client_poison.ConnectionReason) void,
};

pub const Role = enum { observer, controller };
pub const Mode = enum { observer, controller };

pub const State = struct {
    runtime_id: u128,
    stream_id: u64,
    role: Role,
    failed_release_state: FailedReleaseState = .none,
    controller_generation: u64,
};

/// Attachment-local authority SSOT shared by GUI and the external adapter. It borrows the single
/// connection transport while owning its stream-local queue and screen; callers use the same
/// object for every mutation gate so a busy demotion cannot act like a controller.
pub const RemoteAttachment = struct {
    allocator: std.mem.Allocator,
    state: State,
    transport: ?AttachmentTransport = null,
    screen: ?remote_screen.RemoteScreen = null,
    pending_batches: std.ArrayListUnmanaged(AttachmentBatchLease) = .empty,
    pending_batch_head: usize = 0,
    failed_release: ?AttachmentBatchLease = null,

    pub fn init(allocator: std.mem.Allocator, state: State) RemoteAttachment {
        return .{ .allocator = allocator, .state = state };
    }

    pub fn streamId(self: *const RemoteAttachment) u64 {
        return self.state.stream_id;
    }

    pub fn allowsMutation(self: *const RemoteAttachment) bool {
        return self.state.role == .controller;
    }

    pub fn bindTransport(self: *RemoteAttachment, transport: AttachmentTransport) error{AlreadyBound}!void {
        if (self.transport != null) return error.AlreadyBound;
        self.transport = transport;
    }

    pub fn initScreen(self: *RemoteAttachment, codec: u16) anyerror!void {
        if (self.screen != null) return;
        self.screen = try remote_screen.RemoteScreen.initForCodec(self.allocator, codec);
    }

    pub fn deinit(self: *RemoteAttachment) void {
        if (self.deinitWithDropPolicy(true) != .cleaned)
            @panic("remote attachment teardown requires a terminal cleanup owner");
    }

    /// GUI generation-bound owner settles the canonical node-local stream drop itself, but still
    /// needs this payload to release pending batch leases and screen storage. External movable
    /// attachments keep using `deinit`, which retains the legacy transport-owned drop.
    pub fn deinitPayloadOnly(self: *RemoteAttachment) PayloadDeinitOutcome {
        return self.deinitWithDropPolicy(false);
    }

    pub const PayloadDeinitReadiness = enum { ready, busy, corrupt };

    /// Host-wide reconnect may only enter its no-fail suffix after every sibling attachment can
    /// release without publishing a terminal handoff. Pending generation leases are drained by
    /// their ordinary owner turns before this preparation; guessing through `deinitPayloadOnly`
    /// would otherwise allow the kth runtime to fail after earlier runtimes were destroyed.
    pub fn preflightPayloadOnlyDeinit(self: *const RemoteAttachment) PayloadDeinitReadiness {
        if (self.transport == null) return .corrupt;
        if (self.failed_release != null) return .busy;
        if (self.pending_batch_head > self.pending_batches.items.len) return .corrupt;
        if (self.pending_batch_head != self.pending_batches.items.len) return .busy;
        if (!failedReleaseStateRawValid(&self.state.failed_release_state)) return .corrupt;
        if (self.state.failed_release_state != .none) return .corrupt;
        return .ready;
    }

    fn deinitWithDropPolicy(self: *RemoteAttachment, drop_stream: bool) PayloadDeinitOutcome {
        if (self.transport) |transport| {
            if (self.failed_release) |lease| {
                const generation_owned = switch (lease) {
                    .generation => true,
                    .untracked, .charged => false,
                };
                if (generation_owned and self.state.failed_release_state == .indeterminate)
                    return .terminal_handoff;
                if (generation_owned and self.state.failed_release_state != .retryable)
                    return .corrupt;
                switch (lease.release(transport)) {
                    .completed => {
                        self.failed_release = null;
                        self.state.failed_release_state = .none;
                    },
                    .retryable_preserved, .indeterminate_or_partial => {
                        if (generation_owned) {
                            self.state.failed_release_state = .indeterminate;
                            return .terminal_handoff;
                        }
                        transport.fail_closed(transport.context, .attachment_cleanup_failed);
                        self.failed_release = null;
                        self.state.failed_release_state = .none;
                    },
                    .invariant_failure => {
                        if (generation_owned) return .corrupt;
                        transport.fail_closed(transport.context, .attachment_cleanup_failed);
                        self.failed_release = null;
                        self.state.failed_release_state = .none;
                    },
                }
            }
            while (self.pending_batch_head < self.pending_batches.items.len) {
                const lease = self.pending_batches.items[self.pending_batch_head];
                const release_result = lease.release(transport);
                switch (release_result) {
                    .completed => self.pending_batch_head += 1,
                    .retryable_preserved, .indeterminate_or_partial => {
                        self.failed_release = lease;
                        self.state.failed_release_state = if (release_result == .retryable_preserved)
                            .retryable
                        else
                            .indeterminate;
                        self.pending_batch_head += 1;
                        return .terminal_handoff;
                    },
                    .invariant_failure => switch (lease) {
                        .generation => return .corrupt,
                        .untracked, .charged => {
                            transport.fail_closed(transport.context, .attachment_cleanup_failed);
                            self.pending_batch_head += 1;
                        },
                    },
                }
            }
            if (drop_stream) transport.drop_stream(transport.context, self.state.stream_id);
        } else {
            if (self.failed_release) |lease| switch (lease) {
                .untracked => |batch| batch.deinit(),
                .charged => {},
                .generation => @panic("generation batch lost its node-bound release authority"),
            };
            for (self.pending_batches.items[self.pending_batch_head..]) |lease| switch (lease) {
                .untracked => |batch| batch.deinit(),
                .charged => {},
                .generation => @panic("generation batch lost its node-bound release authority"),
            };
        }
        self.pending_batches.deinit(self.allocator);
        if (self.screen) |*screen| screen.deinit();
        self.* = undefined;
        return .cleaned;
    }

    /// 실패한 lease와 아직 시도하지 않은 suffix만 내보내야 같은 token을 두 번 봉인하지 않는다.
    /// 이 view는 소유권을 빌려줄 뿐이며 terminal handoff가 게시되기 전에는 source를 지우지 않는다.
    pub fn terminalCleanupView(self: *const RemoteAttachment) TerminalCleanupViewError!TerminalCleanupView {
        if (self.transport == null or self.failed_release == null)
            return error.InvalidTerminalCleanup;
        const pending = self.pending_batches.items[self.pending_batch_head..];
        var count: usize = pending.len;
        if (self.failed_release != null) count = std.math.add(usize, count, 1) catch
            return error.InvalidTerminalCleanup;
        if (count == 0 or count > std.math.maxInt(u32)) return error.InvalidTerminalCleanup;
        if (self.failed_release) |lease| switch (lease) {
            .generation => {},
            .untracked, .charged => return error.InvalidTerminalCleanup,
        };
        for (pending) |lease| switch (lease) {
            .generation => {},
            .untracked, .charged => return error.InvalidTerminalCleanup,
        };
        return .{
            .failed = self.failed_release,
            .pending = pending,
            .token_count = @intCast(count),
        };
    }

    /// Node-final handoff가 게시된 뒤에만 이동 가능한 attachment의 복제 source를 지운다.
    /// 배열 저장소는 payload 최종 정리가 회수하므로 여기서는 token 가시성만 원자적으로 닫는다.
    pub fn consumeTerminalCleanupSourcesNoFail(
        self: *RemoteAttachment,
        expected_token_count: u32,
    ) void {
        const view = self.terminalCleanupView() catch
            @panic("terminal cleanup source proof was lost");
        if (view.token_count != expected_token_count)
            @panic("terminal cleanup source count drifted");
        self.failed_release = null;
        self.state.failed_release_state = .none;
        self.pending_batch_head = self.pending_batches.items.len;
        self.compactConsumedBatches();
    }

    /// Pull one stream-local batch from the borrowed connection into attachment-owned storage,
    /// then apply it to the attachment-owned screen. The queue owns bytes across any future split
    /// between transport and render turns.
    pub fn pumpScreen(
        self: *RemoteAttachment,
        io: std.Io,
    ) (client_mod.ClientError || screen_assembler.ApplyError || LeaseError)!PumpScreenResult {
        return self.pumpScreenInternal(io, null) catch |err| switch (err) {
            error.BatchLimitExceeded,
            error.ByteLimitExceeded,
            error.Busy,
            error.CellLimitExceeded,
            error.InvalidAuthority,
            error.DestinationOccupied,
            => unreachable,
            else => |typed| typed,
        };
    }

    /// A Client inbox overflow invalidates every not-yet-applied lease already transferred to
    /// this stream owner. Release them before admitting resync so stale deltas cannot cross the
    /// recovery boundary and their resident accounting returns to the shared connection budget.
    pub fn discardPendingScreen(self: *RemoteAttachment) LeaseError!void {
        const transport = self.transport orelse return error.LedgerInvariant;
        if (self.failed_release != null) {
            transport.fail_closed(transport.context, .attachment_cleanup_failed);
            return error.LedgerInvariant;
        }
        while (self.pending_batch_head < self.pending_batches.items.len) {
            const lease = self.pending_batches.items[self.pending_batch_head];
            self.pending_batch_head += 1;
            if (self.releaseOrRetain(lease, transport) != .completed) {
                self.compactConsumedBatches();
                transport.fail_closed(transport.context, .attachment_cleanup_failed);
                return error.LedgerInvariant;
            }
        }
        self.compactConsumedBatches();
    }

    pub fn pumpCatchupScreen(
        self: *RemoteAttachment,
        io: std.Io,
        accounting: *catchup_stage_contract.Accounting,
    ) (client_mod.ClientError || screen_assembler.ApplyError || LeaseError || catchup_stage_contract.Error)!PumpScreenResult {
        return self.pumpScreenInternal(io, accounting);
    }

    /// Applies the synchronous immutable live-batch borrow produced by `ExternalPumpStorage`.
    /// The pump remains the lease/retirement owner; this method owns only the already-validated
    /// screen mutation, avoiding a second transport read or a duplicate demux path.
    pub fn applyExternalLiveScreen(
        self: *RemoteAttachment,
        view: external_inbox_ledger.PayloadView,
        io: std.Io,
    ) (screen_assembler.ApplyError || error{ OutOfMemory, InvalidAuthority })!void {
        if (view.phase != .completed) return error.InvalidAuthority;
        const completed = switch (view.semantic) {
            .completed => |value| value,
            else => return error.InvalidAuthority,
        };
        if (completed.stream_id != self.state.stream_id) return error.InvalidAuthority;
        switch (completed.recovery_intent) {
            .none => {},
            .host, .client => return error.InvalidAuthority,
        }
        const screen = &(self.screen orelse return error.InvalidAuthority);
        if (completed.is_snapshot) {
            try screen.applySnapshot(view.bytes, io);
        } else {
            try screen.applyDelta(view.bytes, io);
        }
    }

    fn pumpScreenInternal(
        self: *RemoteAttachment,
        io: std.Io,
        catchup_accounting: ?*catchup_stage_contract.Accounting,
    ) (client_mod.ClientError || screen_assembler.ApplyError || LeaseError || catchup_stage_contract.Error)!PumpScreenResult {
        const transport = self.transport orelse return error.ConnectionClosed;
        // A failed release is already a terminal ownership invariant. Never consume another
        // transport batch and risk needing a second allocation-free recovery slot.
        if (self.failed_release != null) {
            transport.fail_closed(transport.context, .attachment_cleanup_failed);
            return error.LedgerInvariant;
        }
        if (try transport.read_batch(transport.context, self.state.stream_id)) |lease| {
            self.pending_batches.append(self.allocator, lease) catch {
                transport.fail_closed(transport.context, .local_resource_exhausted);
                const released = self.releaseOrRetain(lease, transport);
                if (released != .completed)
                    transport.fail_closed(transport.context, .attachment_cleanup_failed);
                if (released != .completed) return error.LedgerInvariant;
                return error.OutOfMemory;
            };
        }
        if (self.pending_batch_head == self.pending_batches.items.len) return .idle;
        const lease = self.pending_batches.items[self.pending_batch_head];
        self.pending_batch_head += 1;
        const batch = lease.borrow(transport) catch {
            transport.fail_closed(transport.context, .local_invariant_violation);
            if (self.releaseOrRetain(lease, transport) != .completed)
                transport.fail_closed(transport.context, .attachment_cleanup_failed);
            self.compactConsumedBatches();
            return error.LedgerInvariant;
        };
        // The view and payload cease to exist at release. Copy the pointer-free key before any
        // apply or cleanup callback so the post-release mark cannot dereference retired storage.
        const recovery_key = batch.recovery_key;
        if (batch.stream_id != self.state.stream_id) {
            transport.fail_closed(transport.context, .local_invariant_violation);
            const released = self.releaseOrRetain(lease, transport);
            self.compactConsumedBatches();
            if (released != .completed)
                transport.fail_closed(transport.context, .attachment_cleanup_failed);
            if (released != .completed) return error.LedgerInvariant;
            return error.LedgerInvariant;
        }
        const batch_authority = if (transport.preflight_batch_authority) |preflight|
            preflight(
                transport.context,
                self.state.stream_id,
                batch.is_snapshot,
                recovery_key,
            )
        else if (recovery_key == null)
            external_recovery_types.BatchAuthority.ordinary
        else
            .stale_invariant;
        const authority_valid = switch (batch_authority) {
            .ordinary => recovery_key == null,
            .recovery_exact => recovery_key != null and batch.is_snapshot,
            .stale_invariant => false,
        };
        if (!authority_valid) {
            transport.fail_closed(transport.context, .local_invariant_violation);
            const released = self.releaseOrRetain(lease, transport);
            self.compactConsumedBatches();
            if (released != .completed)
                transport.fail_closed(transport.context, .attachment_cleanup_failed);
            if (released != .completed) return error.LedgerInvariant;
            return .terminal;
        }
        const screen = &(self.screen orelse {
            transport.fail_closed(transport.context, .local_invariant_violation);
            const released = self.releaseOrRetain(lease, transport);
            self.compactConsumedBatches();
            if (released != .completed)
                transport.fail_closed(transport.context, .attachment_cleanup_failed);
            if (released != .completed) return error.LedgerInvariant;
            return error.ProtocolError;
        });
        const next_catchup_accounting = if (catchup_accounting) |accounting| blk: {
            const decoded_cells = screen_stream.decodedCellCount(
                batch.bytes,
                screen.assembler.expected_codec_version,
            ) catch |err| {
                transport.fail_closed(transport.context, .frame_malformed);
                const released = self.releaseOrRetain(lease, transport);
                self.compactConsumedBatches();
                if (released != .completed)
                    transport.fail_closed(transport.context, .attachment_cleanup_failed);
                if (released != .completed) return error.LedgerInvariant;
                return err;
            };
            break :blk accounting.admit(batch.bytes.len, decoded_cells) catch |err| {
                transport.fail_closed(transport.context, .event_queue_overflow);
                const released = self.releaseOrRetain(lease, transport);
                self.compactConsumedBatches();
                if (released != .completed)
                    transport.fail_closed(transport.context, .attachment_cleanup_failed);
                if (released != .completed) return error.LedgerInvariant;
                return err;
            };
        } else null;
        if (batch_authority == .recovery_exact) {
            const key = recovery_key orelse unreachable;
            // Recovery snapshots are assembled off-screen. A callback may invalidate transport
            // authority after preflight; the visible screen is published only after release and
            // the exact post-release mark both succeed.
            var prepared_screen = remote_screen.RemoteScreen.initForCodec(
                self.allocator,
                screen.assembler.expected_codec_version,
            ) catch |err| {
                transport.fail_closed(transport.context, if (err == error.OutOfMemory)
                    .local_resource_exhausted
                else
                    .peer_contract_violation);
                const released = self.releaseOrRetain(lease, transport);
                self.compactConsumedBatches();
                if (released != .completed)
                    transport.fail_closed(transport.context, .attachment_cleanup_failed);
                if (released != .completed) return error.LedgerInvariant;
                return err;
            };
            var prepared_screen_live = true;
            defer if (prepared_screen_live) prepared_screen.deinit();
            prepared_screen.prepareRecoveryFrontierFrom(screen);
            prepared_screen.applySnapshot(batch.bytes, io) catch |err| {
                transport.fail_closed(transport.context, if (err == error.OutOfMemory)
                    .local_resource_exhausted
                else
                    .frame_malformed);
                const released = self.releaseOrRetain(lease, transport);
                self.compactConsumedBatches();
                if (released != .completed)
                    transport.fail_closed(transport.context, .attachment_cleanup_failed);
                if (released != .completed) return error.LedgerInvariant;
                return err;
            };
            if (self.releaseOrRetain(lease, transport) != .completed) {
                self.compactConsumedBatches();
                transport.fail_closed(transport.context, .attachment_cleanup_failed);
                return error.LedgerInvariant;
            }
            self.compactConsumedBatches();
            const mark = transport.mark_resync_applied orelse {
                transport.fail_closed(transport.context, .local_invariant_violation);
                return .terminal;
            };
            switch (mark(transport.context, self.state.stream_id, key)) {
                .commit_pending => {
                    screen.publishPreparedSnapshot(&prepared_screen, io);
                    // `prepared_screen` now owns the replaced screen image.
                    prepared_screen.deinit();
                    prepared_screen_live = false;
                    if (catchup_accounting) |accounting|
                        accounting.* = next_catchup_accounting.?;
                    return .recovery_commit_pending;
                },
                .stale_invariant => {
                    // The charged token is already released, but the shadow screen was never
                    // published. Retrying either object would create a second authority.
                    transport.fail_closed(transport.context, .local_invariant_violation);
                    return .terminal;
                },
            }
        }
        if (batch.is_snapshot) {
            screen.applySnapshot(batch.bytes, io) catch |err| {
                transport.fail_closed(transport.context, if (err == error.OutOfMemory)
                    .local_resource_exhausted
                else
                    .frame_malformed);
                const released = self.releaseOrRetain(lease, transport);
                self.compactConsumedBatches();
                if (released != .completed)
                    transport.fail_closed(transport.context, .attachment_cleanup_failed);
                if (released != .completed) return error.LedgerInvariant;
                return err;
            };
        } else {
            screen.applyDelta(batch.bytes, io) catch |err| {
                transport.fail_closed(transport.context, if (err == error.OutOfMemory)
                    .local_resource_exhausted
                else
                    .frame_malformed);
                const released = self.releaseOrRetain(lease, transport);
                self.compactConsumedBatches();
                if (released != .completed)
                    transport.fail_closed(transport.context, .attachment_cleanup_failed);
                if (released != .completed) return error.LedgerInvariant;
                return err;
            };
        }
        if (self.releaseOrRetain(lease, transport) != .completed) {
            self.compactConsumedBatches();
            transport.fail_closed(transport.context, .attachment_cleanup_failed);
            return error.LedgerInvariant;
        }
        self.compactConsumedBatches();
        if (catchup_accounting) |accounting| accounting.* = next_catchup_accounting.?;
        return .applied;
    }

    /// A callback invariant can fail after the transport already handed ownership to us. Keep the
    /// one terminal lease in allocation-free storage so teardown can retry instead of losing the
    /// only token capable of releasing the stable ledger slot.
    fn releaseOrRetain(
        self: *RemoteAttachment,
        lease: AttachmentBatchLease,
        transport: AttachmentTransport,
    ) ReleaseDisposition {
        return switch (lease.release(transport)) {
            .completed => .completed,
            .retryable_preserved => blk: {
                if (self.failed_release == null) {
                    self.failed_release = lease;
                    self.state.failed_release_state = .retryable;
                }
                break :blk .retained_retry;
            },
            .indeterminate_or_partial => blk: {
                if (self.failed_release == null) {
                    self.failed_release = lease;
                    self.state.failed_release_state = .indeterminate;
                }
                break :blk .terminal_handoff;
            },
            .invariant_failure => .corrupt,
        };
    }

    /// Preserve FIFO without `orderedRemove(0)`'s quadratic drain. Consumed prefix copies carry no
    /// ownership; compaction is amortized and only moves still-live leases.
    fn compactConsumedBatches(self: *RemoteAttachment) void {
        const len = self.pending_batches.items.len;
        if (self.pending_batch_head == len) {
            self.pending_batches.clearRetainingCapacity();
            self.pending_batch_head = 0;
            return;
        }
        if (self.pending_batch_head < len / 2) return;
        const remaining = len - self.pending_batch_head;
        std.mem.copyForwards(
            AttachmentBatchLease,
            self.pending_batches.items[0..remaining],
            self.pending_batches.items[self.pending_batch_head..],
        );
        self.pending_batches.items.len = remaining;
        self.pending_batch_head = 0;
    }

    /// Applies a revoke already bound to this attachment by `runtime_event_types`.
    pub fn applyValidatedRevoked(
        self: *RemoteAttachment,
        successor_generation: u64,
    ) error{InvalidAuthority}!void {
        if (self.state.role != .controller) return error.InvalidAuthority;
        const expected = std.math.add(u64, self.state.controller_generation, 1) catch
            return error.InvalidAuthority;
        if (successor_generation != expected) return error.InvalidAuthority;
        self.state.role = .observer;
        self.state.controller_generation = successor_generation;
    }
};

fn failedReleaseStateRawValid(state: *const FailedReleaseState) bool {
    const raw = @as(*const u8, @ptrCast(state)).*;
    return raw <= @intFromEnum(FailedReleaseState.indeterminate);
}

fn exactOwnerSchema(comptime Actual: type, comptime Expected: type) bool {
    const actual = std.meta.fields(Actual);
    const expected = std.meta.fields(Expected);
    if (actual.len != expected.len) return false;
    inline for (actual, expected) |a, e| {
        if (!std.mem.eql(u8, a.name, e.name) or a.type != e.type) return false;
    }
    return true;
}

comptime {
    const Expected = struct {
        allocator: std.mem.Allocator,
        state: State,
        transport: ?AttachmentTransport,
        screen: ?remote_screen.RemoteScreen,
        pending_batches: std.ArrayListUnmanaged(AttachmentBatchLease),
        pending_batch_head: usize,
        failed_release: ?AttachmentBatchLease,
    };
    if (!exactOwnerSchema(RemoteAttachment, Expected))
        @compileError("CR3a movable RemoteAttachment schema changed; update SSOT before implementation");
}

pub const AttachResult = struct {
    state: State,
    controller_busy: bool,
    initial_metadata: runtime_metadata_wire.InitialMetadataSeed = .unsupported,

    pub fn deinit(self: *AttachResult) void {
        self.initial_metadata.deinit();
        self.* = undefined;
    }
};

pub const AttachDecodeProfile = runtime_metadata_wire.AttachDecodeProfile;
pub const AttachDecodeError = runtime_metadata_wire.DecodeError;

pub const AttachResponse = union(enum) {
    wire_error: protocol.ErrorCode,
    accepted: AttachResult,

    pub fn deinit(self: *AttachResponse) void {
        switch (self.*) {
            .accepted => |*accepted| accepted.deinit(),
            .wire_error => {},
        }
        self.* = undefined;
    }
};

pub const Status = struct {
    stream_id: u64,
    controller_generation: u64,
    controller: bool,
};

pub const DecodeError = error{ OutOfMemory, Malformed };

pub fn decodeAttachResponse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    runtime_id: u128,
    requested: Mode,
    profile: AttachDecodeProfile,
) AttachDecodeError!AttachResponse {
    var envelope = try runtime_metadata_wire.decodeAttachEnvelope(allocator, bytes, profile);
    defer envelope.deinit();
    return switch (envelope) {
        .wire_error => |code| .{ .wire_error = code },
        .accepted => |*accepted| blk: {
            const role: Role = if (accepted.input) .controller else .observer;
            if (profile.generation_schema == .granted_with_generation and
                accepted.controller_generation == 0 and
                (role == .controller or accepted.controller_busy))
                return error.Malformed;
            switch (requested) {
                .observer => if (role != .observer or accepted.controller_busy)
                    return error.Malformed,
                .controller => switch (role) {
                    .controller => if (accepted.controller_busy) return error.Malformed,
                    .observer => if (!accepted.controller_busy) return error.Malformed,
                },
            }
            break :blk .{ .accepted = .{
                .state = .{
                    .runtime_id = runtime_id,
                    .stream_id = accepted.stream_id,
                    .role = role,
                    .controller_generation = accepted.controller_generation,
                },
                .controller_busy = accepted.controller_busy,
                .initial_metadata = accepted.initial_metadata.take(),
            } };
        },
    };
}

/// Strict one-field response-envelope classification shared by attach/status/takeover consumers.
/// `null` means an exact `result` envelope; unknown error names and extra fields are protocol
/// malformed instead of silently collapsing into a retryable class.
pub fn decodeWireError(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) DecodeError!?protocol.ErrorCode {
    var parsed = try parseObject(allocator, bytes);
    defer parsed.deinit();
    const root = parsed.value.object;
    if (root.count() != 1) return error.Malformed;
    if (root.get("result") != null) return null;
    const value = root.get("error") orelse return error.Malformed;
    const name = switch (value) {
        .string => |text| text,
        else => return error.Malformed,
    };
    const code = protocol.ErrorCode.fromWireName(name) orelse return error.Malformed;
    return switch (code) {
        .invalid_generation,
        .resource_exhausted,
        .unauthorized,
        .runtime_not_found,
        .invalid_request,
        .internal,
        => code,
        else => error.Malformed,
    };
}

test "remote attachment error envelope is exact and closed" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(
        protocol.ErrorCode.invalid_generation,
        (try decodeWireError(allocator, "{\"error\":\"invalid_generation\"}")).?,
    );
    try std.testing.expect((try decodeWireError(allocator, "{\"result\":{}}")) == null);
    try std.testing.expectError(
        error.Malformed,
        decodeWireError(allocator, "{\"error\":\"unknown\"}"),
    );
    try std.testing.expectError(
        error.Malformed,
        decodeWireError(allocator, "{\"error\":\"host_shutting_down\"}"),
    );
    try std.testing.expectError(
        error.Malformed,
        decodeWireError(allocator, "{\"error\":\"unauthorized\",\"extra\":1}"),
    );
}

pub fn attachParams(
    allocator: std.mem.Allocator,
    runtime_id: u128,
    mode: Mode,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const runtime_text = runtimeIdText(runtime_id);
    out.writer.print(
        "{{\"runtime_id\":\"{s}\",\"mode\":\"{s}\"}}",
        .{ &runtime_text, @tagName(mode) },
    ) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written());
}

pub fn statusParams(
    allocator: std.mem.Allocator,
    stream_id: u64,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    json.write(.{ .stream_id = stream_id }) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written());
}

pub fn takeoverParams(
    allocator: std.mem.Allocator,
    stream_id: u64,
    expected_controller_generation: u64,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    json.write(.{
        .stream_id = stream_id,
        .expected_controller_generation = expected_controller_generation,
    }) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written());
}

fn runtimeIdText(runtime_id: u128) [32]u8 {
    var text: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&text, "{x:0>32}", .{runtime_id}) catch unreachable;
    return text;
}

pub fn decodeStatus(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    state: *State,
) DecodeError!Status {
    const status = try decodeStatusProjection(allocator, bytes, state);
    if (status.controller != (state.role == .controller)) return error.Malformed;
    return status;
}

/// Reconnect transfer owns the role mismatch as an authority-conflict outcome rather than
/// laundering a valid foreign-controller observation into a malformed transport failure.
pub fn decodeStatusForTransfer(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    state: *State,
) DecodeError!Status {
    if (state.role != .observer) return error.Malformed;
    return decodeStatusProjection(allocator, bytes, state);
}

fn decodeStatusProjection(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    state: *State,
) DecodeError!Status {
    var parsed = try parseObject(allocator, bytes);
    defer parsed.deinit();
    const root = parsed.value.object;
    if (root.count() != 1) return error.Malformed;
    const result = objectField(root, "result") orelse return error.Malformed;
    if (result.count() != 3) return error.Malformed;
    const status = Status{
        .stream_id = u64Field(result, "stream_id") orelse return error.Malformed,
        .controller_generation = u64Field(result, "controller_generation") orelse
            return error.Malformed,
        .controller = boolField(result, "controller") orelse return error.Malformed,
    };
    if (status.stream_id != state.stream_id or
        status.controller_generation < state.controller_generation)
        return error.Malformed;
    state.controller_generation = status.controller_generation;
    return status;
}

pub fn decodeTakeover(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    state: *State,
    expected_generation: u64,
) DecodeError!void {
    if (state.role != .observer or expected_generation != state.controller_generation)
        return error.Malformed;
    var parsed = try parseObject(allocator, bytes);
    defer parsed.deinit();
    const root = parsed.value.object;
    if (root.count() != 1) return error.Malformed;
    const result = objectField(root, "result") orelse return error.Malformed;
    if (result.count() != 5) return error.Malformed;
    const runtime_id = runtimeIdField(result, "runtime_id") orelse return error.Malformed;
    const stream_id = u64Field(result, "stream_id") orelse return error.Malformed;
    const generation = u64Field(result, "controller_generation") orelse return error.Malformed;
    const reason = stringField(result, "reason") orelse return error.Malformed;
    const granted = objectField(result, "granted") orelse return error.Malformed;
    const successor = std.math.add(u64, expected_generation, 1) catch return error.Malformed;
    if (runtime_id != state.runtime_id or stream_id != state.stream_id or
        generation != successor or !std.mem.eql(u8, reason, "takeover") or
        granted.count() != 3 or boolField(granted, "observe") != true or
        boolField(granted, "input") != true or boolField(granted, "resize") != true)
        return error.Malformed;
    state.role = .controller;
    state.controller_generation = generation;
}

const ParsedObject = std.json.Parsed(std.json.Value);

fn parseObject(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!ParsedObject {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        // Dynamic Value's default integer is i64. Wire generations are u64, so preserve the
        // lexical number and parse it below instead of rejecting the valid upper half.
        .parse_numbers = false,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Malformed,
    };
    if (parsed.value != .object) {
        var owned = parsed;
        owned.deinit();
        return error.Malformed;
    }
    return parsed;
}

fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .object => |result| result,
        else => null,
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn u64Field(object: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .number_string => |text| parseCanonicalU64(text),
        else => null,
    };
}

fn parseCanonicalU64(text: []const u8) ?u64 {
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return null;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

fn runtimeIdField(object: std.json.ObjectMap, name: []const u8) ?u128 {
    const text = stringField(object, name) orelse return null;
    if (text.len != 32) return null;
    for (text) |byte|
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
    const value = std.fmt.parseInt(u128, text, 16) catch return null;
    return if (value == 0) null else value;
}

const observer_attach =
    "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true,\"metadata_revision\":0,\"metadata\":null}}";

fn decodeAcceptedAttachForTest(
    bytes: []const u8,
    runtime_id: u128,
    requested: Mode,
    profile: AttachDecodeProfile,
) AttachDecodeError!AttachResult {
    var decoded = try decodeAttachResponse(
        std.testing.allocator,
        bytes,
        runtime_id,
        requested,
        profile,
    );
    defer decoded.deinit();
    return switch (decoded) {
        .wire_error => error.Malformed,
        .accepted => |*accepted| .{
            .state = accepted.state,
            .controller_busy = accepted.controller_busy,
            .initial_metadata = accepted.initial_metadata.take(),
        },
    };
}

fn decodeCurrentAttachForTest(
    bytes: []const u8,
    runtime_id: u128,
    requested: Mode,
) AttachDecodeError!AttachResult {
    return decodeAcceptedAttachForTest(bytes, runtime_id, requested, .{
        .generation_schema = .granted_with_generation,
        .metadata_support = .supported,
    });
}

test "remote attachment strictly decodes controller grant and busy demotion" {
    var controller = try decodeCurrentAttachForTest(
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        0xaa,
        .controller,
    );
    defer controller.deinit();
    try std.testing.expectEqual(Role.controller, controller.state.role);
    var observer = try decodeCurrentAttachForTest(observer_attach, 0xaa, .controller);
    defer observer.deinit();
    try std.testing.expectEqual(Role.observer, observer.state.role);
    try std.testing.expect(observer.controller_busy);
    try std.testing.expectError(
        error.Malformed,
        decodeCurrentAttachForTest(observer_attach, 0xaa, .observer),
    );
    var no_controller = try decodeCurrentAttachForTest(
        "{\"result\":{\"stream_id\":8,\"controller_generation\":0,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        0xaa,
        .observer,
    );
    defer no_controller.deinit();
    try std.testing.expectEqual(@as(u64, 0), no_controller.state.controller_generation);
}

test "remote attachment accepts exact pre-transfer same-major attach without inventing generation" {
    const legacy =
        "{\"result\":{\"stream_id\":7,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}";
    var accepted = try decodeAcceptedAttachForTest(
        legacy,
        0xaa,
        .observer,
        .{
            .generation_schema = .granted_without_generation,
            .metadata_support = .supported,
        },
    );
    defer accepted.deinit();
    try std.testing.expectEqual(Role.observer, accepted.state.role);
    try std.testing.expectEqual(@as(u64, 0), accepted.state.controller_generation);
    try std.testing.expectError(
        error.Malformed,
        decodeCurrentAttachForTest(legacy, 0xaa, .observer),
    );
}

test "remote attachment frozen v1 controller schema is isolated from current schema" {
    var accepted = try decodeAcceptedAttachForTest(
        "{\"stream_id\":9}",
        0xaa,
        .controller,
        .{
            .generation_schema = .frozen_controller_only,
            .metadata_support = .unsupported,
        },
    );
    defer accepted.deinit();
    try std.testing.expectEqual(Role.controller, accepted.state.role);
    try std.testing.expectEqual(@as(u64, 9), accepted.state.stream_id);
    try std.testing.expectError(
        error.Malformed,
        decodeAcceptedAttachForTest(
            "{\"stream_id\":9,\"granted\":{}}",
            0xaa,
            .controller,
            .{
                .generation_schema = .frozen_controller_only,
                .metadata_support = .unsupported,
            },
        ),
    );
}

test "remote attachment request builders are canonical and bounded" {
    const attach = try attachParams(std.testing.allocator, 0xaa, .observer);
    defer std.testing.allocator.free(attach);
    try std.testing.expectEqualStrings(
        "{\"runtime_id\":\"000000000000000000000000000000aa\",\"mode\":\"observer\"}",
        attach,
    );
    const status = try statusParams(std.testing.allocator, 7);
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("{\"stream_id\":7}", status);
    const takeover = try takeoverParams(std.testing.allocator, 7, 3);
    defer std.testing.allocator.free(takeover);
    try std.testing.expectEqualStrings(
        "{\"stream_id\":7,\"expected_controller_generation\":3}",
        takeover,
    );
}

test "remote attachment rejects malformed or authority-inconsistent grants" {
    const invalid = [_][]const u8{
        "{\"result\":{\"stream_id\":0,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":0,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true,\"metadata_revision\":0,\"metadata\":null}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":false},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true,\"extra\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null,\"extra\":1}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":\"wrong\"}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":1,\"metadata\":null}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":{}}}",
    };
    for (invalid) |bytes| try std.testing.expectError(
        error.Malformed,
        decodeCurrentAttachForTest(bytes, 0xaa, .controller),
    );
}

test "remote attachment status takeover and revoke are generation fenced" {
    var accepted = try decodeCurrentAttachForTest(observer_attach, 0xaa, .controller);
    defer accepted.deinit();
    var state = accepted.state;
    const status = try decodeStatus(
        std.testing.allocator,
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"controller\":false}}",
        &state,
    );
    try std.testing.expectEqual(@as(u64, 3), status.controller_generation);
    try decodeTakeover(
        std.testing.allocator,
        "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\",\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
        &state,
        3,
    );
    try std.testing.expectEqual(Role.controller, state.role);
    try std.testing.expectEqual(@as(u64, 4), state.controller_generation);
    var attachment = RemoteAttachment.init(std.testing.allocator, state);
    try attachment.applyValidatedRevoked(5);
    try std.testing.expectEqual(@as(u64, 5), attachment.state.controller_generation);
    try std.testing.expectEqual(Role.observer, attachment.state.role);
}

test "remote attachment rejects foreign and stale status transitions without mutation" {
    var state = State{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 3,
    };
    try std.testing.expectError(
        error.Malformed,
        decodeStatus(
            std.testing.allocator,
            "{\"result\":{\"stream_id\":8,\"controller_generation\":3,\"controller\":false}}",
            &state,
        ),
    );
    try std.testing.expectError(
        error.Malformed,
        decodeTakeover(
            std.testing.allocator,
            "{\"result\":{\"runtime_id\":\"000000000000000000000000000000bb\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\",\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
            &state,
            3,
        ),
    );
    try std.testing.expectEqual(Role.observer, state.role);
    try std.testing.expectEqual(@as(u64, 3), state.controller_generation);
}

test "remote attachment status advances the CAS token before takeover" {
    var state = State{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 3,
    };
    _ = try decodeStatus(
        std.testing.allocator,
        "{\"result\":{\"stream_id\":7,\"controller_generation\":4,\"controller\":false}}",
        &state,
    );
    try std.testing.expectEqual(@as(u64, 4), state.controller_generation);
    try decodeTakeover(
        std.testing.allocator,
        "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":5,\"reason\":\"takeover\",\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
        &state,
        4,
    );
    try std.testing.expectEqual(Role.controller, state.role);
    try std.testing.expectEqual(@as(u64, 5), state.controller_generation);
}

test "remote attachment preserves the full u64 controller generation domain" {
    var state = State{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = std.math.maxInt(i64),
    };
    _ = try decodeStatus(
        std.testing.allocator,
        "{\"result\":{\"stream_id\":7,\"controller_generation\":18446744073709551614,\"controller\":false}}",
        &state,
    );
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, state.controller_generation);
    try decodeTakeover(
        std.testing.allocator,
        "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":18446744073709551615,\"reason\":\"takeover\",\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
        &state,
        std.math.maxInt(u64) - 1,
    );
    try std.testing.expectEqual(std.math.maxInt(u64), state.controller_generation);
    var exhausted = State{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = std.math.maxInt(u64),
    };
    try std.testing.expectError(
        error.Malformed,
        decodeTakeover(
            std.testing.allocator,
            "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":18446744073709551615,\"reason\":\"takeover\",\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
            &exhausted,
            std.math.maxInt(u64),
        ),
    );
}

test "remote attachment rejects generation gaps for takeover and revoke" {
    var observer = State{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 3,
    };
    try std.testing.expectError(
        error.Malformed,
        decodeTakeover(
            std.testing.allocator,
            "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":5,\"reason\":\"takeover\",\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
            &observer,
            3,
        ),
    );
    const controller = State{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    };
    var controller_attachment = RemoteAttachment.init(std.testing.allocator, controller);
    try std.testing.expectError(
        error.InvalidAuthority,
        controller_attachment.applyValidatedRevoked(5),
    );
}

test "remote attachment authority rejects mutation after busy demotion or revoke" {
    var busy_result = try decodeCurrentAttachForTest(
        observer_attach,
        0xaa,
        .controller,
    );
    defer busy_result.deinit();
    var busy = RemoteAttachment.init(std.testing.allocator, busy_result.state);
    try std.testing.expect(!busy.allowsMutation());

    var controller_result = try decodeCurrentAttachForTest(
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        0xaa,
        .controller,
    );
    defer controller_result.deinit();
    var controller = RemoteAttachment.init(std.testing.allocator, controller_result.state);
    try std.testing.expect(controller.allowsMutation());
    try controller.applyValidatedRevoked(4);
    try std.testing.expect(!controller.allowsMutation());
}

const TestTransport = struct {
    batch: ?AttachmentBatchLease,
    fail_closed_calls: usize = 0,
    first_fail_reason: ?client_poison.ConnectionReason = null,
    drop_calls: usize = 0,

    fn read(
        context: *anyopaque,
        _: u64,
    ) client_mod.ClientError!?AttachmentBatchLease {
        const self: *TestTransport = @ptrCast(@alignCast(context));
        const batch = self.batch;
        self.batch = null;
        return batch;
    }

    fn drop(context: *anyopaque, _: u64) void {
        const self: *TestTransport = @ptrCast(@alignCast(context));
        self.drop_calls += 1;
    }

    fn failClosed(context: *anyopaque, reason: client_poison.ConnectionReason) void {
        const self: *TestTransport = @ptrCast(@alignCast(context));
        if (self.first_fail_reason == null) self.first_fail_reason = reason;
        self.fail_closed_calls += 1;
    }

    fn interface(self: *TestTransport) AttachmentTransport {
        return .{
            .context = self,
            .read_batch = read,
            .drop_stream = drop,
            .fail_closed = failClosed,
        };
    }
};

test "CR3a-2a GUI payload-only teardown leaves stream drop to generation owner" {
    var transport = TestTransport{ .batch = null };
    var attachment = RemoteAttachment.init(std.testing.allocator, .{
        .runtime_id = 1,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 1,
    });
    try attachment.bindTransport(transport.interface());
    try std.testing.expectEqual(PayloadDeinitOutcome.cleaned, attachment.deinitPayloadOnly());
    try std.testing.expectEqual(@as(usize, 0), transport.drop_calls);

    var external = RemoteAttachment.init(std.testing.allocator, .{
        .runtime_id = 2,
        .stream_id = 8,
        .role = .controller,
        .controller_generation = 1,
    });
    try external.bindTransport(transport.interface());
    external.deinit();
    try std.testing.expectEqual(@as(usize, 1), transport.drop_calls);
}

const ChargedTestTransport = struct {
    ledger: *external_inbox_ledger.ExternalInboxLedger,
    batch: ?AttachmentBatchLease,
    release_fails: bool = false,
    drop_observed_zero: bool = false,
    fail_closed_calls: usize = 0,
    first_fail_reason: ?client_poison.ConnectionReason = null,
    drop_calls: usize = 0,
    release_calls: usize = 0,

    fn read(
        context: *anyopaque,
        _: u64,
    ) client_mod.ClientError!?AttachmentBatchLease {
        const self: *ChargedTestTransport = @ptrCast(@alignCast(context));
        const batch = self.batch;
        self.batch = null;
        return batch;
    }

    fn borrow(
        context: *anyopaque,
        token: external_inbox_ledger.Token,
    ) external_inbox_ledger.InvariantError!AttachmentBatchView {
        const self: *ChargedTestTransport = @ptrCast(@alignCast(context));
        const view = try self.ledger.borrowLease(token);
        return .{
            .is_snapshot = view.is_snapshot,
            .stream_id = view.stream_id,
            .recovery_key = view.recovery_key,
            .bytes = view.bytes,
        };
    }

    fn release(
        context: *anyopaque,
        token: external_inbox_ledger.Token,
    ) external_inbox_ledger.InvariantError!void {
        const self: *ChargedTestTransport = @ptrCast(@alignCast(context));
        self.release_calls += 1;
        if (self.release_fails) return error.InvariantFailure;
        return self.ledger.releaseLease(token);
    }

    fn drop(context: *anyopaque, _: u64) void {
        const self: *ChargedTestTransport = @ptrCast(@alignCast(context));
        self.drop_observed_zero =
            self.ledger.charged_bytes == 0 and self.ledger.charged_items == 0;
        self.drop_calls += 1;
    }

    fn failClosed(context: *anyopaque, reason: client_poison.ConnectionReason) void {
        const self: *ChargedTestTransport = @ptrCast(@alignCast(context));
        if (self.first_fail_reason == null) self.first_fail_reason = reason;
        self.fail_closed_calls += 1;
    }

    fn interface(self: *ChargedTestTransport) AttachmentTransport {
        return .{
            .context = self,
            .read_batch = read,
            .borrow_charged = borrow,
            .release_charged = release,
            .drop_stream = drop,
            .fail_closed = failClosed,
        };
    }
};

const RecoveryTestTransport = struct {
    view: AttachmentBatchView,
    batch_available: bool = true,
    release_fails: bool = false,
    preflight_result: external_recovery_types.BatchAuthority = .recovery_exact,
    mark_result: MarkResyncAppliedResult = .commit_pending,
    fail_closed_calls: usize = 0,
    first_fail_reason: ?client_poison.ConnectionReason = null,
    preflight_calls: usize = 0,
    release_calls: usize = 0,
    mark_calls: usize = 0,
    release_before_mark: bool = false,
    marked_key: ?external_recovery_types.Key = null,

    fn read(
        context: *anyopaque,
        _: u64,
    ) client_mod.ClientError!?AttachmentBatchLease {
        const self: *RecoveryTestTransport = @ptrCast(@alignCast(context));
        if (!self.batch_available) return null;
        self.batch_available = false;
        return .{ .charged = .{ .slot = 1, .generation = 9 } };
    }

    fn borrow(
        context: *anyopaque,
        _: external_inbox_ledger.Token,
    ) external_inbox_ledger.InvariantError!AttachmentBatchView {
        const self: *RecoveryTestTransport = @ptrCast(@alignCast(context));
        return self.view;
    }

    fn release(
        context: *anyopaque,
        _: external_inbox_ledger.Token,
    ) external_inbox_ledger.InvariantError!void {
        const self: *RecoveryTestTransport = @ptrCast(@alignCast(context));
        self.release_calls += 1;
        if (self.release_fails) return error.InvariantFailure;
    }

    fn mark(
        context: *anyopaque,
        _: u64,
        key: external_recovery_types.Key,
    ) MarkResyncAppliedResult {
        const self: *RecoveryTestTransport = @ptrCast(@alignCast(context));
        self.mark_calls += 1;
        self.release_before_mark = self.release_calls == 1;
        self.marked_key = key;
        return self.mark_result;
    }

    fn preflight(
        context: *anyopaque,
        _: u64,
        _: bool,
        _: ?external_recovery_types.Key,
    ) external_recovery_types.BatchAuthority {
        const self: *RecoveryTestTransport = @ptrCast(@alignCast(context));
        self.preflight_calls += 1;
        return self.preflight_result;
    }

    fn drop(_: *anyopaque, _: u64) void {}

    fn failClosed(context: *anyopaque, reason: client_poison.ConnectionReason) void {
        const self: *RecoveryTestTransport = @ptrCast(@alignCast(context));
        if (self.first_fail_reason == null) self.first_fail_reason = reason;
        self.fail_closed_calls += 1;
    }

    fn interface(self: *RecoveryTestTransport) AttachmentTransport {
        return .{
            .context = self,
            .read_batch = read,
            .borrow_charged = borrow,
            .release_charged = release,
            .preflight_batch_authority = preflight,
            .mark_resync_applied = mark,
            .drop_stream = drop,
            .fail_closed = failClosed,
        };
    }
};

fn reserveChargedBatch(
    ledger: *external_inbox_ledger.ExternalInboxLedger,
    allocator: std.mem.Allocator,
    is_snapshot: bool,
    stream_id: u64,
    bytes: []u8,
) !external_inbox_ledger.Token {
    var owned_bytes = bytes;
    var payload = external_inbox_ledger.OwnedPayload.takeOwned(allocator, &owned_bytes);
    errdefer payload.deinit();
    return ledger.reserveLease(.{
        .stream_id = stream_id,
        .is_snapshot = is_snapshot,
    }, &payload);
}

fn testSnapshot(allocator: std.mem.Allocator) ![]u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);
    const meta = try screen_stream.encodeScreenMeta(
        allocator,
        .{ .kind = .screen_meta, .generation = 1 },
        .{ .cols = 1, .rows = 1 },
    );
    defer allocator.free(meta);
    try screen_stream.appendRecord(&bytes, allocator, meta);
    var runs = [_]screen_stream.Run{.{ .grapheme = " ", .width = 1, .count = 1 }};
    const row = try screen_stream.encodeRow(
        allocator,
        .{ .kind = .row, .generation = 1 },
        .{ .row_index = 0, .runs = &runs },
    );
    defer allocator.free(row);
    try screen_stream.appendRecord(&bytes, allocator, row);
    return bytes.toOwnedSlice(allocator);
}

test "p5c3c-3b external live screen borrow applies through the attachment screen owner" {
    const allocator = std.testing.allocator;
    const snapshot = try testSnapshot(allocator);
    defer allocator.free(snapshot);
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    });
    defer attachment.deinit();
    try attachment.initScreen(screen_stream.codec_version);
    try attachment.applyExternalLiveScreen(.{
        .phase = .completed,
        .semantic = .{ .completed = .{
            .stream_id = 7,
            .is_snapshot = true,
        } },
        .bytes = snapshot,
    }, std.testing.io);
    try std.testing.expectEqual(@as(u64, 1), attachment.screen.?.assembler.generation);
}

test "CR4a catchup apply leaf는 byte cap 마지막 batch를 화면 apply 전에 회수한다" {
    const allocator = std.testing.allocator;
    const bytes = try testSnapshot(allocator);
    var transport = TestTransport{
        .batch = .{ .untracked = .{
            .is_snapshot = true,
            .stream_id = 7,
            .bytes = bytes,
            .allocator = allocator,
        } },
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    defer attachment.deinit();
    try attachment.bindTransport(transport.interface());
    try attachment.initScreen(screen_stream.codec_version);
    var accounting: catchup_stage_contract.Accounting = .{
        .encoded_bytes = catchup_stage_contract.max_encoded_bytes,
    };
    const before = accounting;
    try std.testing.expectError(
        error.ByteLimitExceeded,
        attachment.pumpCatchupScreen(std.testing.io, &accounting),
    );
    try std.testing.expectEqualDeep(before, accounting);
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(
        client_poison.ConnectionReason.event_queue_overflow,
        transport.first_fail_reason.?,
    );
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
}

test "CR4a catchup apply leaf는 queue append OOM에서 accounting과 batch를 회수한다" {
    var transport = TestTransport{
        .batch = .{ .untracked = .{
            .is_snapshot = true,
            .stream_id = 7,
            .bytes = @constCast(&[_]u8{}),
            .allocator = std.testing.allocator,
        } },
    };
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var attachment = RemoteAttachment.init(failing.allocator(), .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    defer attachment.deinit();
    try attachment.bindTransport(transport.interface());
    var accounting: catchup_stage_contract.Accounting = .{};
    const before = accounting;
    try std.testing.expectError(
        error.OutOfMemory,
        attachment.pumpCatchupScreen(std.testing.io, &accounting),
    );
    try std.testing.expectEqualDeep(before, accounting);
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(
        client_poison.ConnectionReason.local_resource_exhausted,
        transport.first_fail_reason.?,
    );
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
}

test "remote attachment fail-closes when a consumed batch has no screen owner" {
    var transport = TestTransport{
        .batch = .{ .untracked = .{
            .is_snapshot = true,
            .stream_id = 7,
            .bytes = try std.testing.allocator.dupe(u8, "consumed"),
            .allocator = std.testing.allocator,
        } },
    };
    var attachment = RemoteAttachment.init(std.testing.allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try std.testing.expectError(
        error.ProtocolError,
        attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(
        client_poison.ConnectionReason.local_invariant_violation,
        transport.first_fail_reason.?,
    );
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
    attachment.deinit();
    try std.testing.expectEqual(@as(usize, 1), transport.drop_calls);
}

test "remote attachment fail-closes when consumed batch queue admission runs out of memory" {
    var transport = TestTransport{
        // Queue admission is the only allocation in this path. A zero-length payload keeps the
        // matching cleanup in the same failing allocator domain without adding setup allocation.
        .batch = .{ .untracked = .{
            .is_snapshot = true,
            .stream_id = 7,
            .bytes = @constCast(&[_]u8{}),
            .allocator = std.testing.allocator,
        } },
    };
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var attachment = RemoteAttachment.init(failing.allocator(), .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try std.testing.expectError(
        error.OutOfMemory,
        attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
    attachment.deinit();
    try std.testing.expectEqual(@as(usize, 1), transport.drop_calls);
}

test "remote attachment fail-closes malformed consumed screen bytes" {
    var transport = TestTransport{
        .batch = .{ .untracked = .{
            .is_snapshot = true,
            .stream_id = 7,
            .bytes = try std.testing.allocator.dupe(u8, "not-a-screen-frame"),
            .allocator = std.testing.allocator,
        } },
    };
    var attachment = RemoteAttachment.init(std.testing.allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try attachment.initScreen(2);
    defer attachment.deinit();
    try std.testing.expectError(
        error.Truncated,
        attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
}

test "remote attachment releases a charged batch after apply failure" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    const token = try reserveChargedBatch(
        &ledger,
        allocator,
        true,
        7,
        try allocator.dupe(u8, "not-a-screen-frame"),
    );
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = .{ .charged = token },
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try attachment.initScreen(2);
    try std.testing.expectError(error.Truncated, attachment.pumpScreen(std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_bytes);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
    attachment.deinit();
    try std.testing.expectEqual(@as(usize, 1), transport.drop_calls);
    try ledger.finish();
}

test "remote attachment applies and releases a charged snapshot with an empty queue" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    const snapshot = try testSnapshot(allocator);
    const token = try reserveChargedBatch(&ledger, allocator, true, 7, snapshot);
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = .{ .charged = token },
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try attachment.initScreen(2);
    try std.testing.expectEqual(
        PumpScreenResult.applied,
        try attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 0), transport.fail_closed_calls);
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
    attachment.deinit();
    try ledger.finish();
}

test "remote attachment copies recovery key then releases before exact mark" {
    const allocator = std.testing.allocator;
    const snapshot = try testSnapshot(allocator);
    defer allocator.free(snapshot);
    const key = external_recovery_types.Key{
        .owner_incarnation = 41,
        .origin = .host,
        .recovery_epoch = 7,
        .expected_token_generation = 9,
    };
    var transport = RecoveryTestTransport{ .view = .{
        .is_snapshot = true,
        .stream_id = 7,
        .recovery_key = key,
        .bytes = snapshot,
    } };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try attachment.initScreen(2);
    defer attachment.deinit();
    try std.testing.expectEqual(
        @as(u64, 0),
        attachment.screen.?.assembler.generation,
    );

    try std.testing.expectEqual(
        PumpScreenResult.recovery_commit_pending,
        try attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        attachment.screen.?.assembler.generation,
    );
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.mark_calls);
    try std.testing.expect(transport.release_before_mark);
    try std.testing.expect(std.meta.eql(key, transport.marked_key.?));
    try std.testing.expectEqual(@as(usize, 0), transport.fail_closed_calls);
}

test "remote attachment never marks failed apply or failed release" {
    const allocator = std.testing.allocator;
    const key = external_recovery_types.Key{
        .owner_incarnation = 41,
        .origin = .client,
        .recovery_epoch = 7,
        .expected_token_generation = 9,
    };
    var apply_failure = RecoveryTestTransport{ .view = .{
        .is_snapshot = true,
        .stream_id = 7,
        .recovery_key = key,
        .bytes = "not-a-screen",
    } };
    var first = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try first.bindTransport(apply_failure.interface());
    try first.initScreen(2);
    try std.testing.expectEqual(
        @as(u64, 0),
        first.screen.?.assembler.generation,
    );
    try std.testing.expectError(error.Truncated, first.pumpScreen(std.testing.io));
    try std.testing.expectEqual(
        @as(u64, 0),
        first.screen.?.assembler.generation,
    );
    try std.testing.expectEqual(@as(usize, 1), apply_failure.release_calls);
    try std.testing.expectEqual(@as(usize, 0), apply_failure.mark_calls);
    try std.testing.expectEqual(
        client_poison.ConnectionReason.frame_malformed,
        apply_failure.first_fail_reason.?,
    );
    first.deinit();

    var combined_failure = RecoveryTestTransport{
        .view = .{
            .is_snapshot = true,
            .stream_id = 7,
            .recovery_key = key,
            .bytes = "not-a-screen",
        },
        .release_fails = true,
    };
    var combined = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try combined.bindTransport(combined_failure.interface());
    try combined.initScreen(2);
    try std.testing.expectError(
        error.LedgerInvariant,
        combined.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(
        client_poison.ConnectionReason.frame_malformed,
        combined_failure.first_fail_reason.?,
    );
    try std.testing.expectEqual(@as(usize, 2), combined_failure.fail_closed_calls);
    combined_failure.release_fails = false;
    combined.deinit();

    const snapshot = try testSnapshot(allocator);
    defer allocator.free(snapshot);
    var release_failure = RecoveryTestTransport{
        .view = .{
            .is_snapshot = true,
            .stream_id = 7,
            .recovery_key = key,
            .bytes = snapshot,
        },
        .release_fails = true,
    };
    var second = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try second.bindTransport(release_failure.interface());
    try second.initScreen(2);
    try std.testing.expectEqual(
        @as(u64, 0),
        second.screen.?.assembler.generation,
    );
    try std.testing.expectError(
        error.LedgerInvariant,
        second.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        second.screen.?.assembler.generation,
    );
    try std.testing.expectEqual(@as(usize, 1), release_failure.release_calls);
    try std.testing.expectEqual(@as(usize, 0), release_failure.mark_calls);
    try std.testing.expectEqual(
        client_poison.ConnectionReason.attachment_cleanup_failed,
        release_failure.first_fail_reason.?,
    );
    release_failure.release_fails = false;
    second.deinit();
    try std.testing.expectEqual(@as(usize, 2), release_failure.release_calls);
    try std.testing.expectEqual(@as(usize, 0), release_failure.mark_calls);
}

test "remote attachment stale mark terminalizes without retaining released token" {
    const allocator = std.testing.allocator;
    const snapshot = try testSnapshot(allocator);
    defer allocator.free(snapshot);
    var transport = RecoveryTestTransport{
        .view = .{
            .is_snapshot = true,
            .stream_id = 7,
            .recovery_key = .{
                .owner_incarnation = 41,
                .origin = .host,
                .recovery_epoch = 7,
                .expected_token_generation = 9,
            },
            .bytes = snapshot,
        },
        .mark_result = .stale_invariant,
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try attachment.initScreen(2);
    try std.testing.expectEqual(
        @as(u64, 0),
        attachment.screen.?.assembler.generation,
    );
    try std.testing.expectEqual(
        PumpScreenResult.terminal,
        try attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        attachment.screen.?.assembler.generation,
    );
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.mark_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(
        client_poison.ConnectionReason.local_invariant_violation,
        transport.first_fail_reason.?,
    );
    try std.testing.expectEqual(@as(?AttachmentBatchLease, null), attachment.failed_release);
    attachment.deinit();
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
}

test "CR3a-2d2 RemoteAttachment terminal view는 failed 뒤 pending suffix 순서를 보존한다" {
    var attachment = RemoteAttachment.init(std.testing.allocator, .{
        .runtime_id = 1,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 1,
    });
    attachment.transport = terminalTestTransport();
    attachment.failed_release = .{ .generation = .{
        .registry_incarnation = 11,
        .entry_slot = 1,
        .entry_generation = 21,
        .stream_id = 7,
    } };
    try attachment.pending_batches.append(std.testing.allocator, .{ .generation = .{
        .registry_incarnation = 11,
        .entry_slot = 2,
        .entry_generation = 22,
        .stream_id = 7,
    } });
    try attachment.pending_batches.append(std.testing.allocator, .{ .generation = .{
        .registry_incarnation = 11,
        .entry_slot = 3,
        .entry_generation = 23,
        .stream_id = 7,
    } });
    attachment.pending_batch_head = 1;

    const view = try attachment.terminalCleanupView();
    try std.testing.expectEqual(@as(u32, 2), view.token_count);
    try std.testing.expectEqual(@as(u16, 1), view.failed.?.generation.entry_slot);
    try std.testing.expectEqual(@as(usize, 1), view.pending.len);
    try std.testing.expectEqual(@as(u16, 3), view.pending[0].generation.entry_slot);
    attachment.consumeTerminalCleanupSourcesNoFail(2);
    attachment.pending_batches.deinit(std.testing.allocator);
}

test "CR3a-2d2 RemoteAttachment terminal view는 external lease 혼입을 mutation 없이 거부한다" {
    var attachment = RemoteAttachment.init(std.testing.allocator, .{
        .runtime_id = 1,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 1,
    });
    defer attachment.pending_batches.deinit(std.testing.allocator);
    attachment.transport = terminalTestTransport();
    attachment.failed_release = .{ .charged = .{ .slot = 1, .generation = 9 } };
    const before = attachment.failed_release;
    try std.testing.expectError(error.InvalidTerminalCleanup, attachment.terminalCleanupView());
    try std.testing.expectEqualDeep(before, attachment.failed_release);
}

test "CR3a-2d2 RemoteAttachment terminal source는 handoff 뒤 exact once tombstone된다" {
    var attachment = RemoteAttachment.init(std.testing.allocator, .{
        .runtime_id = 1,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 1,
    });
    attachment.transport = terminalTestTransport();
    attachment.failed_release = .{ .generation = .{
        .registry_incarnation = 11,
        .entry_slot = 1,
        .entry_generation = 21,
        .stream_id = 7,
    } };
    attachment.consumeTerminalCleanupSourcesNoFail(1);
    try std.testing.expectEqual(@as(?AttachmentBatchLease, null), attachment.failed_release);
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
    try std.testing.expectError(error.InvalidTerminalCleanup, attachment.terminalCleanupView());
    attachment.pending_batches.deinit(std.testing.allocator);
}

test "remote attachment rejects wrong recovery stream before screen apply or mark" {
    const allocator = std.testing.allocator;
    const snapshot = try testSnapshot(allocator);
    defer allocator.free(snapshot);
    var transport = RecoveryTestTransport{ .view = .{
        .is_snapshot = true,
        .stream_id = 8,
        .recovery_key = .{
            .owner_incarnation = 41,
            .origin = .host,
            .recovery_epoch = 7,
            .expected_token_generation = 9,
        },
        .bytes = snapshot,
    } };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try attachment.initScreen(2);
    try std.testing.expectError(
        error.LedgerInvariant,
        attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        attachment.screen.?.assembler.generation,
    );
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 0), transport.mark_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    attachment.deinit();
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
}

test "remote attachment rejects stale recovery authority before screen apply" {
    const allocator = std.testing.allocator;
    const snapshot = try testSnapshot(allocator);
    defer allocator.free(snapshot);
    var transport = RecoveryTestTransport{
        .view = .{
            .is_snapshot = true,
            .stream_id = 7,
            .recovery_key = .{
                .owner_incarnation = 41,
                .origin = .host,
                .recovery_epoch = 7,
                .expected_token_generation = 9,
            },
            .bytes = snapshot,
        },
        .preflight_result = .stale_invariant,
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try attachment.initScreen(2);
    try std.testing.expectEqual(
        @as(u64, 0),
        attachment.screen.?.assembler.generation,
    );
    try std.testing.expectEqual(
        PumpScreenResult.terminal,
        try attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        attachment.screen.?.assembler.generation,
    );
    try std.testing.expectEqual(@as(usize, 1), transport.preflight_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 0), transport.mark_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    attachment.deinit();
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
}

test "remote attachment reports ledger invariant when failure cleanup cannot release" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    const token = try reserveChargedBatch(
        &ledger,
        allocator,
        true,
        7,
        try allocator.alloc(u8, 0),
    );
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = .{ .charged = token },
        .release_fails = true,
    };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var attachment = RemoteAttachment.init(failing.allocator(), .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try std.testing.expectError(
        error.LedgerInvariant,
        attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 2), transport.fail_closed_calls);
    try std.testing.expectEqual(
        client_poison.ConnectionReason.local_resource_exhausted,
        transport.first_fail_reason.?,
    );
    transport.release_fails = false;
    attachment.deinit();
    try ledger.finish();
}

test "remote attachment rejects a charged batch demuxed to a sibling stream" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    const token = try reserveChargedBatch(
        &ledger,
        allocator,
        true,
        8,
        try allocator.alloc(u8, 0),
    );
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = .{ .charged = token },
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try std.testing.expectError(
        error.LedgerInvariant,
        attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
    attachment.deinit();
    try ledger.finish();
}

test "remote attachment charged queue admission OOM releases through stable ledger" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    const token = try reserveChargedBatch(
        &ledger,
        allocator,
        true,
        7,
        try allocator.alloc(u8, 0),
    );
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = .{ .charged = token },
    };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var attachment = RemoteAttachment.init(failing.allocator(), .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try std.testing.expectError(error.OutOfMemory, attachment.pumpScreen(std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    attachment.deinit();
    try ledger.finish();
}

test "remote attachment stale charged lease latches invariant without double release" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    const token = try reserveChargedBatch(
        &ledger,
        allocator,
        true,
        7,
        try allocator.alloc(u8, 0),
    );
    try ledger.releaseLease(token);
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = .{ .charged = token },
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try std.testing.expectError(error.LedgerInvariant, attachment.pumpScreen(std.testing.io));
    try std.testing.expectEqual(@as(usize, 2), transport.fail_closed_calls);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
    attachment.deinit();
    try std.testing.expectError(error.InvariantFailure, ledger.finish());
}

test "remote attachment deinit releases every queued charged lease before dropping stream" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = null,
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    for (0..3) |i| {
        const bytes = try std.fmt.allocPrint(allocator, "batch-{d}", .{i});
        const token = try reserveChargedBatch(&ledger, allocator, i == 0, 7, bytes);
        try attachment.pending_batches.append(allocator, .{ .charged = token });
    }
    attachment.deinit();
    try std.testing.expectEqual(@as(usize, 3), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.drop_calls);
    try std.testing.expect(transport.drop_observed_zero);
    try std.testing.expectEqual(@as(usize, 0), transport.fail_closed_calls);
    try ledger.finish();
}

test "R3 recovery discards every transferred lease before a fresh snapshot" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = null,
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    for (0..3) |i| {
        const bytes = try std.fmt.allocPrint(allocator, "stale-{d}", .{i});
        const token = try reserveChargedBatch(&ledger, allocator, false, 7, bytes);
        try attachment.pending_batches.append(allocator, .{ .charged = token });
    }

    try attachment.discardPendingScreen();
    try std.testing.expectEqual(@as(usize, 3), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batch_head);

    attachment.deinit();
    try std.testing.expectEqual(@as(usize, 1), transport.drop_calls);
    try std.testing.expectEqual(@as(usize, 0), transport.fail_closed_calls);
    try ledger.finish();
}
