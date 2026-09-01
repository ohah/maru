//! Product-side owner boundary for the external session pump.
//!
//! d2c owns the sole product POSIX RX adapter. Higher layers supply only semantic buffered
//! callbacks; they cannot replace the transport callback or bypass the pump transaction.

const client_external_pump = @import("client_external_pump.zig");
const client_external_rx_read = @import("client_external_rx_read.zig");
const client_pump = @import("client_pump.zig");
const external_recovery_types = @import("external_recovery_types.zig");
const runtime_event_types = @import("runtime_event_types.zig");
const client_idle_pump_evidence = @import("client_idle_pump_evidence.zig");
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn openpty(
    amaster: *c.fd_t,
    aslave: *c.fd_t,
    name: ?[*]u8,
    termp: ?*const posix.termios,
    winp: ?*const posix.winsize,
) c_int;
const darwin_tiocswinsz: c_int = @bitCast(@as(u32, 0x80087467));

const ProductRxOrderEvent = if (builtin.is_test) enum {
    recv_bytes,
    recv_would_block,
    recv_eof,
    recv_interrupted,
    recv_error,
    apply_live_screen,
} else void;

const ProductRxOrderRecorder = if (builtin.is_test) struct {
    events: [8]ProductRxOrderEvent = undefined,
    len: usize = 0,
    overflow: bool = false,

    fn record(self: *ProductRxOrderRecorder, event: ProductRxOrderEvent) void {
        if (self.len == self.events.len) {
            self.overflow = true;
            return;
        }
        self.events[self.len] = event;
        self.len += 1;
    }

    fn reset(self: *ProductRxOrderRecorder) void {
        self.len = 0;
        self.overflow = false;
    }

    fn expect(
        self: *const ProductRxOrderRecorder,
        expected: []const ProductRxOrderEvent,
    ) !void {
        try std.testing.expect(!self.overflow);
        try std.testing.expectEqualSlices(
            ProductRxOrderEvent,
            expected,
            self.events[0..self.len],
        );
    }
} else void;

const PosixRxContext = struct {
    marker: u8 = 0x52,
    test_calls: if (builtin.is_test) ?*usize else void =
        if (builtin.is_test) null else {},
    test_order: if (builtin.is_test) ?*ProductRxOrderRecorder else void =
        if (builtin.is_test) null else {},
};

fn mapPosixReadResult(
    result: isize,
    read_errno: ?posix.E,
) client_external_rx_read.RxReadOutcome {
    if (result > 0) return .{ .bytes = @intCast(result) };
    if (result == 0) return .eof;
    return switch (read_errno orelse return .socket_error) {
        .AGAIN => .would_block,
        .INTR => .interrupted,
        else => .socket_error,
    };
}

fn readPosix(
    raw: *anyopaque,
    fd: posix.fd_t,
    destination: []u8,
) client_external_rx_read.RxReadOutcome {
    const context: *const PosixRxContext = @ptrCast(@alignCast(raw));
    if (context.marker != 0x52 or destination.len == 0) return .socket_error;
    if (builtin.is_test) {
        if (context.test_calls) |calls| calls.* += 1;
    }
    // Per-call nonblocking is mandatory even though external-mode adoption also sets O_NONBLOCK:
    // another descriptor for the same open-file-description can change that shared flag.
    client_idle_pump_evidence.recordSocketRead();
    const result = c.recv(
        fd,
        destination.ptr,
        destination.len,
        posix.MSG.DONTWAIT,
    );
    const outcome = mapPosixReadResult(
        result,
        if (result < 0) posix.errno(result) else null,
    );
    if (builtin.is_test) {
        if (context.test_order) |order| order.record(switch (outcome) {
            .bytes => .recv_bytes,
            .would_block => .recv_would_block,
            .eof => .recv_eof,
            .interrupted => .recv_interrupted,
            .socket_error => .recv_error,
        });
    }
    return outcome;
}

/// Runs one bounded RX turn through the product owner boundary.
///
/// `buffered.apply_live_screen` receives a synchronous immutable borrow. The callback must not
/// retain the view or any pointer derived from it after returning.
fn pumpRxWithContext(
    storage: *client_external_pump.ExternalPumpStorage,
    turn: client_pump.TurnInput,
    buffered: *const client_external_pump.BufferedRxOps,
    scratch: *client_external_pump.ExternalRxTurnScratch,
    context: *PosixRxContext,
) client_pump.TurnResult {
    const ops = client_external_pump.RxTurnOps{
        .buffered = buffered.*,
        .transport = .{
            .context = context,
            .context_len = @sizeOf(PosixRxContext),
            .read = readPosix,
        },
    };
    return storage.pumpRxTurn(turn, &ops, scratch);
}

pub fn pumpRx(
    storage: *client_external_pump.ExternalPumpStorage,
    turn: client_pump.TurnInput,
    buffered: *const client_external_pump.BufferedRxOps,
    scratch: *client_external_pump.ExternalRxTurnScratch,
) client_pump.TurnResult {
    var context = PosixRxContext{};
    return pumpRxWithContext(storage, turn, buffered, scratch, &context);
}

const client_mod = @import("client.zig");
const compatibility = @import("compatibility.zig");
const external_attach = @import("external_attach.zig");
const external_attach_evidence = @import("external_attach_evidence.zig");
const external_ansi = @import("external_ansi.zig");
const external_rx_intent = @import("external_rx_intent.zig");
const external_tty = @import("external_tty.zig");
const external_tty_output = @import("external_tty_output.zig");
const framing = @import("framing.zig");
const maru = @import("maru");
const protocol = @import("protocol.zig");
const remote_attachment = @import("remote_attachment.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");
const screen_stream = @import("maru").session.screen_stream;

const OwnerLifecycle = enum(u8) {
    empty,
    constructing,
    live,
    tearing_down,
    dead,
};

pub const InitError = error{
    DestinationNotEmpty,
    InvalidAlias,
    InvalidPrepared,
    OutOfMemory,
    StorageRejected,
    AdoptionRejected,
};

pub const TeardownResult = enum {
    cleaned,
    cleaned_with_invariant,
    already_dead,
    moved,
    busy,
    quarantined,
};

pub const PollHintResult = union(enum) {
    hint: client_pump.PollHint,
    moved_or_stale,
};

pub const LiveScreenPayloadView = client_external_pump.LiveScreenPayloadView;
pub const LiveScreenApplyResult = client_external_pump.LiveScreenApplyResult;
pub const LiveScreenApplyFn = *const fn (
    context: *anyopaque,
    view: LiveScreenPayloadView,
) LiveScreenApplyResult;
pub const CleanupWireAuthority = client_external_pump.ExternalPumpStorage.CleanupWireAuthority;
pub const CleanupWireProjection = client_external_pump.ExternalPumpStorage.CleanupWireProjection;
pub const CleanupCancelResult = client_external_pump.ExternalPumpStorage.CleanupCancelResult;
pub const CliOwnerProjectionResult = client_external_pump.CliOwnerProjectionResult;

pub const CommittedScreenPumpResult = union(enum) {
    idle,
    applied: maru.session.surface.ScreenSource,
    retry,
    terminal: client_pump.TerminalReason,
};

/// Stable callback object embedded in `ExternalPumpOwner`.
///
/// The callback context never points at a movable `Client` or ledger. Every callback first proves
/// the adapter and owner final addresses, then borrows only the owner's single storage member.
const ExternalAttachmentAdapter = struct {
    saved_self_addr: usize = 0,
    owner_addr: usize = 0,

    fn valid(self: *const ExternalAttachmentAdapter) bool {
        if (self.saved_self_addr != @intFromPtr(self) or self.owner_addr == 0)
            return false;
        const owner: *const ExternalPumpOwner = @ptrFromInt(self.owner_addr);
        return owner.addressValid() and
            (owner.lifecycle == .live or owner.lifecycle == .tearing_down) and
            @intFromPtr(&owner.adapter) == @intFromPtr(self);
    }

    fn readBatch(
        raw: *anyopaque,
        stream_id: u64,
    ) client_mod.ClientError!?remote_attachment.AttachmentBatchLease {
        const self: *ExternalAttachmentAdapter = @ptrCast(@alignCast(raw));
        if (!self.valid()) return error.ConnectionClosed;
        const owner: *ExternalPumpOwner = @ptrFromInt(self.owner_addr);
        return if (try owner.storage.nextAttachmentBatch(stream_id)) |token|
            .{ .charged = token }
        else
            null;
    }

    fn borrowCharged(
        raw: *anyopaque,
        token: client_external_pump.AttachmentToken,
    ) client_external_pump.AttachmentInvariantError!remote_attachment.AttachmentBatchView {
        const self: *ExternalAttachmentAdapter = @ptrCast(@alignCast(raw));
        if (!self.valid()) return error.InvariantFailure;
        const owner: *ExternalPumpOwner = @ptrFromInt(self.owner_addr);
        const view = try owner.storage.borrowAttachmentBatch(token);
        return .{
            .is_snapshot = view.is_snapshot,
            .stream_id = view.stream_id,
            .recovery_key = view.recovery_key,
            .bytes = view.bytes,
        };
    }

    fn releaseCharged(
        raw: *anyopaque,
        token: client_external_pump.AttachmentToken,
    ) client_external_pump.AttachmentInvariantError!void {
        const self: *ExternalAttachmentAdapter = @ptrCast(@alignCast(raw));
        if (!self.valid()) return error.InvariantFailure;
        const owner: *ExternalPumpOwner = @ptrFromInt(self.owner_addr);
        try owner.storage.releaseAttachmentBatch(token);
    }

    fn preflightBatchAuthority(
        raw: *anyopaque,
        stream_id: u64,
        is_snapshot: bool,
        key: ?external_recovery_types.Key,
    ) external_recovery_types.BatchAuthority {
        const self: *ExternalAttachmentAdapter = @ptrCast(@alignCast(raw));
        if (!self.valid()) return .stale_invariant;
        const owner: *ExternalPumpOwner = @ptrFromInt(self.owner_addr);
        return owner.storage.preflightBatchAuthority(stream_id, is_snapshot, key);
    }

    fn markResyncApplied(
        raw: *anyopaque,
        stream_id: u64,
        key: external_recovery_types.Key,
    ) remote_attachment.MarkResyncAppliedResult {
        const self: *ExternalAttachmentAdapter = @ptrCast(@alignCast(raw));
        if (!self.valid()) return .stale_invariant;
        const owner: *ExternalPumpOwner = @ptrFromInt(self.owner_addr);
        return owner.storage.markResyncApplied(stream_id, key);
    }

    fn dropStream(raw: *anyopaque, stream_id: u64) void {
        const self: *ExternalAttachmentAdapter = @ptrCast(@alignCast(raw));
        if (!self.valid()) return;
        const owner: *ExternalPumpOwner = @ptrFromInt(self.owner_addr);
        owner.storage.dropAttachmentStream(stream_id);
    }

    fn failClosed(raw: *anyopaque, reason: @import("client_poison.zig").ConnectionReason) void {
        const self: *ExternalAttachmentAdapter = @ptrCast(@alignCast(raw));
        if (!self.valid()) return;
        const owner: *ExternalPumpOwner = @ptrFromInt(self.owner_addr);
        owner.storage.failAttachment(reason);
    }

    fn interface(self: *ExternalAttachmentAdapter) remote_attachment.AttachmentTransport {
        return .{
            .context = self,
            .read_batch = readBatch,
            .borrow_charged = borrowCharged,
            .release_charged = releaseCharged,
            .preflight_batch_authority = preflightBatchAuthority,
            .mark_resync_applied = markResyncApplied,
            .drop_stream = dropStream,
            .fail_closed = failClosed,
        };
    }
};

/// Non-movable product owner that consumes exactly one `external_attach.Prepared` in place.
///
/// Keeping storage, attachment, transport context and cleanup scratch in this one final-address
/// object removes the pointer-recovery window that existed between the completed 2b2 scaffold and
/// the later raw TTY loop. Public methods reject copied or moved owners in ReleaseFast as well.
pub const ExternalPumpOwner = struct {
    saved_self_addr: usize = 0,
    lifecycle: OwnerLifecycle = .empty,
    storage: client_external_pump.ExternalPumpStorage = .{},
    attachment: remote_attachment.RemoteAttachment = undefined,
    adapter: ExternalAttachmentAdapter = .{},
    cleanup_scratch: client_external_pump.ExternalPumpCleanupScratch = .{},
    rx_scratch: client_external_pump.ExternalRxTurnScratch = .{},

    fn addressValid(self: *const ExternalPumpOwner) bool {
        const owner_addr = @intFromPtr(self);
        const owner_end = std.math.add(
            usize,
            owner_addr,
            @sizeOf(ExternalPumpOwner),
        ) catch return false;
        const storage_addr = @intFromPtr(&self.storage);
        const attachment_addr = @intFromPtr(&self.attachment);
        const adapter_addr = @intFromPtr(&self.adapter);
        const cleanup_addr = @intFromPtr(&self.cleanup_scratch);
        const rx_addr = @intFromPtr(&self.rx_scratch);
        return self.saved_self_addr == owner_addr and
            storage_addr == owner_addr + @offsetOf(ExternalPumpOwner, "storage") and
            attachment_addr == owner_addr + @offsetOf(ExternalPumpOwner, "attachment") and
            adapter_addr == owner_addr + @offsetOf(ExternalPumpOwner, "adapter") and
            cleanup_addr == owner_addr + @offsetOf(ExternalPumpOwner, "cleanup_scratch") and
            rx_addr == owner_addr + @offsetOf(ExternalPumpOwner, "rx_scratch") and
            cleanup_addr + @sizeOf(client_external_pump.ExternalPumpCleanupScratch) <= owner_end and
            rx_addr + @sizeOf(client_external_pump.ExternalRxTurnScratch) <= owner_end and
            !rangesOverlap(
                cleanup_addr,
                @sizeOf(client_external_pump.ExternalPumpCleanupScratch),
                storage_addr,
                @sizeOf(client_external_pump.ExternalPumpStorage),
            ) and
            !rangesOverlap(
                cleanup_addr,
                @sizeOf(client_external_pump.ExternalPumpCleanupScratch),
                attachment_addr,
                @sizeOf(remote_attachment.RemoteAttachment),
            ) and
            !rangesOverlap(
                cleanup_addr,
                @sizeOf(client_external_pump.ExternalPumpCleanupScratch),
                adapter_addr,
                @sizeOf(ExternalAttachmentAdapter),
            ) and
            self.storage.saved_self_addr == storage_addr and
            self.cleanup_scratch.saved_self_addr == cleanup_addr and
            self.rx_scratch.saved_self_addr == rx_addr and
            self.adapter.saved_self_addr == @intFromPtr(&self.adapter) and
            self.adapter.owner_addr == @intFromPtr(self);
    }

    pub fn initInPlace(
        out: *ExternalPumpOwner,
        prepared: *external_attach.Prepared,
    ) InitError!void {
        if (rangesOverlap(
            @intFromPtr(out),
            @sizeOf(ExternalPumpOwner),
            @intFromPtr(prepared),
            @sizeOf(external_attach.Prepared),
        )) return error.InvalidAlias;
        if (out.saved_self_addr != 0 or out.lifecycle != .empty)
            return error.DestinationNotEmpty;
        if (prepared.attach_instance_id == 0 or
            prepared.client.attach_instance_id != prepared.attach_instance_id or
            !preparedAttachmentCanonical(&prepared.attachment))
            return error.InvalidPrepared;

        const attachment_allocator = prepared.attachment.allocator;
        const attachment_state = prepared.attachment.state;

        out.saved_self_addr = @intFromPtr(out);
        out.lifecycle = .constructing;
        out.adapter = .{
            .saved_self_addr = @intFromPtr(&out.adapter),
            .owner_addr = @intFromPtr(out),
        };
        if (!client_external_pump.ExternalPumpCleanupScratch.initInPlace(
            &out.cleanup_scratch,
        ) or !client_external_pump.ExternalRxTurnScratch.initInPlace(&out.rx_scratch)) {
            out.* = .{};
            return error.InvalidPrepared;
        }

        var evidence: client_external_pump.PreparedAdoptionEvidence = .{};
        var evidence_owned = true;
        defer if (evidence_owned) evidence.deinit();
        external_attach_evidence.prepareInPlace(&evidence, prepared) catch |err| {
            out.* = .{};
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidAlias => error.InvalidAlias,
                error.InvalidEvidence => error.InvalidPrepared,
            };
        };
        switch (client_external_pump.ExternalPumpStorage.initInPlace(
            &out.storage,
            &prepared.client,
            &evidence,
        )) {
            .initialized => evidence_owned = false,
            .failed => |failure| {
                out.* = .{};
                return if (failure.reason == .out_of_memory)
                    error.OutOfMemory
                else
                    error.StorageRejected;
            },
        }
        switch (out.storage.prepareAdoption(1, &out.cleanup_scratch)) {
            .prepared_adopted => {},
            .retryable_preserved => |reason| {
                _ = out.storage.teardown(&out.cleanup_scratch);
                out.lifecycle = .dead;
                return switch (reason) {
                    .out_of_memory => error.OutOfMemory,
                    .transaction_busy => error.AdoptionRejected,
                };
            },
            .recovery_committed, .terminal_latched => {
                _ = out.storage.teardown(&out.cleanup_scratch);
                out.lifecycle = .dead;
                return error.AdoptionRejected;
            },
        }
        if (out.storage.commitAdoption() != .adopted) {
            _ = out.storage.teardown(&out.cleanup_scratch);
            out.lifecycle = .dead;
            return error.AdoptionRejected;
        }

        // Allocation callbacks ran while adopting the Client. Revalidate the still-source-owned
        // attachment immediately before its no-fail move/bind suffix so a callback cannot turn
        // the initial transport-null check into an `AlreadyBound` unreachable or smuggle mutable
        // attachment ownership into the final owner.
        if (!preparedAttachmentMatches(
            &prepared.attachment,
            attachment_allocator,
            attachment_state,
        )) {
            _ = out.storage.teardown(&out.cleanup_scratch);
            out.lifecycle = .dead;
            return error.AdoptionRejected;
        }
        out.attachment = prepared.attachment;
        out.lifecycle = .live;
        out.attachment.bindTransport(out.adapter.interface()) catch unreachable;
        // Keep the consumed source deterministically rejectable and safe to deinit. The Client
        // move already published its own tombstone; reconstruct only an empty, non-owning
        // attachment shell instead of leaving caller-visible undefined bytes.
        prepared.attach_instance_id = 0;
        prepared.attachment = remote_attachment.RemoteAttachment.init(
            attachment_allocator,
            attachment_state,
        );
        prepared.initial_metadata = .unavailable;
        if (!out.storage.commitBoundInitialAttachment(out.attachment.streamId())) {
            _ = out.teardown();
            return error.AdoptionRejected;
        }
    }

    pub fn pump(
        self: *ExternalPumpOwner,
        turn: client_pump.TurnInput,
        buffered: *const client_external_pump.BufferedRxOps,
    ) client_pump.TurnResult {
        if (!self.addressValid() or self.lifecycle != .live) {
            return .{ .terminal = .{
                .reason = .invariant_failure,
                .fd_disposition = .owner_cleanup,
            } };
        }
        const hint = self.storage.pollHint();
        if (hint.next_deadline_ns) |deadline| {
            if (turn.now_ns >= deadline) {
                self.storage.failAttachment(.read_timeout);
                return .{ .terminal = .{
                    .reason = .deadline_exceeded,
                    .fd_disposition = .owner_cleanup,
                } };
            }
        }
        return pumpRx(
            &self.storage,
            turn,
            buffered,
            &self.rx_scratch,
        );
    }

    /// Typed screen-apply facade for the integrated loop. The mechanics module and its buffered
    /// operation DTO stay private to this final owner boundary.
    pub fn pumpApplying(
        self: *ExternalPumpOwner,
        turn: client_pump.TurnInput,
        context: *anyopaque,
        context_len: usize,
        apply: LiveScreenApplyFn,
    ) client_pump.TurnResult {
        const buffered = client_external_pump.BufferedRxOps{
            .context = context,
            .context_len = context_len,
            .apply_live_screen = apply,
        };
        return self.pump(turn, &buffered);
    }

    /// Raw CLI does not surface title/cwd/process metadata, but it must retire those validated
    /// owner events so they cannot remain a permanent inherited pump blocker.
    pub fn consumeCliOwnerProjection(self: *ExternalPumpOwner) CliOwnerProjectionResult {
        if (!self.addressValid() or self.lifecycle != .live) return .terminal;
        switch (self.storage.cliOwnerProjectionReadiness()) {
            .none => return .none,
            .retry => return .retry,
            .terminal => return .terminal,
            .pending => {},
        }
        if (!self.storage.settleRxTurnForSiblingOperation(&self.rx_scratch)) return .terminal;
        return self.storage.consumeCliOwnerProjection(&self.cleanup_scratch);
    }

    /// Drains exactly one charged screen batch through the existing `RemoteAttachment` lease and
    /// returns a synchronous source borrow for the outer ANSI projector. The caller must consume
    /// the source before invoking any other owner operation.
    pub fn pumpCommittedScreen(
        self: *ExternalPumpOwner,
        io: std.Io,
    ) CommittedScreenPumpResult {
        if (!self.addressValid() or self.lifecycle != .live)
            return .{ .terminal = .invariant_failure };
        const outcome = self.attachment.pumpScreen(io) catch |err| {
            const reason: client_pump.TerminalReason = switch (err) {
                error.OutOfMemory => .resource_exhausted,
                error.ConnectionClosed => .eof,
                else => .protocol_error,
            };
            self.storage.failAttachment(switch (reason) {
                .resource_exhausted => .local_resource_exhausted,
                .eof => .connection_eof,
                else => .frame_malformed,
            });
            return .{ .terminal = reason };
        };
        return switch (outcome) {
            .idle => .idle,
            .recovery_commit_pending => .retry,
            .terminal => .{ .terminal = .protocol_error },
            .applied => blk: {
                const screen = if (self.attachment.screen) |*value| value else return .{ .terminal = .invariant_failure };
                break :blk .{ .applied = screen.screenSource() };
            },
        };
    }

    pub fn admitControl(
        self: *ExternalPumpOwner,
        spec: client_external_pump.ControlAdmissionSpec,
        now_ns: i128,
    ) client_external_pump.ControlAdmissionResult {
        if (!self.addressValid() or self.lifecycle != .live)
            return .{ .terminal = .invariant_failure };
        if (!self.storage.settleRxTurnForSiblingOperation(&self.rx_scratch))
            return .{ .terminal = .invariant_failure };
        return self.storage.admitControl(spec, now_ns);
    }

    /// Narrow TX admission used by the 3b loop after its chord/role reducer has authorized bytes.
    /// Raw Client and queue storage remain inaccessible to the orchestration layer.
    pub fn admitTx(
        self: *ExternalPumpOwner,
        spec: client_external_pump.TxAdmissionSpec,
        now_ns: i128,
    ) client_external_pump.TxAdmissionResult {
        if (!self.addressValid() or self.lifecycle != .live)
            return .{ .terminal = .invariant_failure };
        if (!self.storage.settleRxTurnForSiblingOperation(&self.rx_scratch))
            return .{ .terminal = .invariant_failure };
        return self.storage.admitTx(spec, now_ns);
    }

    /// Admits the one best-effort terminal detach request used by the 3b cleanup state machine.
    /// The public loop supplies no JSON and cannot accidentally invent a second detach vocabulary.
    pub fn admitDetach(
        self: *ExternalPumpOwner,
        now_ns: i128,
    ) client_external_pump.ControlAdmissionResult {
        if (!self.addressValid() or self.lifecycle != .live)
            return .{ .terminal = .invariant_failure };
        if (!self.storage.settleRxTurnForSiblingOperation(&self.rx_scratch))
            return .{ .terminal = .invariant_failure };
        return self.storage.admitControl(.{
            .request = .{ .detach = .{
                .stream_id = self.attachment.state.stream_id,
            } },
            .expected_controller_generation = self.attachment.state.controller_generation,
        }, now_ns);
    }

    /// observer 가 자기 뷰포트를 알린다(S11-6). `admitDetach` 와 같은 자리를 쓴다 — 공개 루프가
    /// stream_id·generation 을 스스로 지어내지 못하게 owner 가 채운다.
    pub fn admitDeclareViewport(
        self: *ExternalPumpOwner,
        cols: u16,
        rows: u16,
        now_ns: i128,
    ) client_external_pump.ControlAdmissionResult {
        if (!self.addressValid() or self.lifecycle != .live)
            return .{ .terminal = .invariant_failure };
        if (!self.storage.settleRxTurnForSiblingOperation(&self.rx_scratch))
            return .{ .terminal = .invariant_failure };
        return self.storage.admitControl(.{
            .request = .{ .declare_viewport = .{
                .stream_id = self.attachment.state.stream_id,
                .cols = cols,
                .rows = rows,
            } },
            .expected_controller_generation = self.attachment.state.controller_generation,
        }, now_ns);
    }

    pub fn pollHint(self: *const ExternalPumpOwner) PollHintResult {
        if (!self.addressValid() or self.lifecycle != .live)
            return .moved_or_stale;
        return .{ .hint = self.storage.pollHint() };
    }

    pub fn projectCleanupWireAuthority(
        self: *ExternalPumpOwner,
    ) CleanupWireProjection {
        if (!self.addressValid() or self.lifecycle != .live) return .invalid;
        if (!self.storage.settleRxTurnForSiblingOperation(&self.rx_scratch))
            return .invalid;
        return self.storage.projectCleanupWireAuthority();
    }

    pub fn cancelOffsetZeroInputForCleanup(
        self: *ExternalPumpOwner,
        now_ns: i128,
    ) CleanupCancelResult {
        if (!self.addressValid() or self.lifecycle != .live) return .invalid;
        if (!self.storage.settleRxTurnForSiblingOperation(&self.rx_scratch))
            return .invalid;
        return self.storage.cancelOffsetZeroInputForCleanup(&self.rx_scratch, now_ns);
    }

    /// Latches a terminal connection result after an outer synchronous apply callback returns.
    /// Calling this from inside the callback would violate the whole-turn lease, so 3b invokes it
    /// only after `pump` has released that lease.
    pub fn latchAttachmentFailure(
        self: *ExternalPumpOwner,
        reason: @import("client_poison.zig").ConnectionReason,
    ) void {
        if (!self.addressValid() or self.lifecycle != .live) return;
        self.storage.failAttachment(reason);
    }

    /// host 소켓의 poll fd. `--stream` 은 raw TTY 스택 없이 이 pump 만 돌리므로(§8) 자기 poll
    /// 루프를 짤 자리가 필요하다 — 그리는 쪽 루프는 stdin·wake fd 까지 묶은 4-fd 집합을 쓰지만
    /// 그 모드는 stdin 을 안 읽는다.
    pub fn socketPollFd(self: *const ExternalPumpOwner) ?c.fd_t {
        if (!self.addressValid() or self.lifecycle != .live) return null;
        return self.storage.pollSocketFd();
    }

    pub fn teardown(self: *ExternalPumpOwner) TeardownResult {
        if (self.saved_self_addr == 0 and self.lifecycle == .empty)
            return .already_dead;
        if (!self.addressValid()) return .moved;
        if (self.lifecycle == .dead) return .already_dead;
        if (self.lifecycle == .live) {
            self.lifecycle = .tearing_down;
            // RemoteAttachment releases every held charged lease and drops its stream before the
            // storage begins ledger final-zero and Client committed cleanup. A retry after
            // transaction_busy must not deinit the attachment a second time.
            self.attachment.deinit();
        } else if (self.lifecycle != .tearing_down) return .busy;
        const result = self.storage.teardown(&self.cleanup_scratch);
        return switch (result) {
            .cleaned => result: {
                self.lifecycle = .dead;
                break :result .cleaned;
            },
            .cleaned_with_invariant => result: {
                self.lifecycle = .dead;
                break :result .cleaned_with_invariant;
            },
            .already_dead => result: {
                self.lifecycle = .dead;
                break :result .already_dead;
            },
            .moved_storage => .moved,
            .transaction_busy => .busy,
            .quarantined => result: {
                self.lifecycle = .dead;
                break :result .quarantined;
            },
        };
    }
};

const PreRawLifecycle = enum(u8) {
    empty,
    preparing,
    prepared,
    committing,
    live,
    tearing_down,
    dead,
};

pub const PreRawPrepareError = error{
    DestinationNotEmpty,
    InvalidAlias,
    InvalidPrepared,
    TtyInspectionFailed,
    OutputRejected,
    PumpRejected,
    MissingScreen,
    RepaintRejected,
    InvalidPollSet,
};

pub const PreRawCommitError = error{
    Moved,
    InvalidLifecycle,
    TerminalChanged,
    RawEnterFailed,
    EnterWriteFailed,
    RestoreFailed,
};

pub const PreRawTeardownResult = enum {
    cleaned,
    cleaned_with_invariant,
    already_dead,
    moved,
    busy,
    restore_failed,
    pump_busy,
    pump_quarantined,
};

/// P5c3c-3a2 final-address owner. Preparation is mutation-free with respect to termios, signal
/// dispositions, and ANSI output. Only `commit` may enter raw mode and publish the enter sequence.
pub const PreRawOwner = struct {
    saved_self_addr: usize = 0,
    lifecycle: PreRawLifecycle = .empty,
    inspection: external_tty.Inspection = undefined,
    output: external_tty_output.DedicatedOutput = .{},
    pump: ExternalPumpOwner = .{},
    repaint: external_ansi.RepaintQueue = undefined,
    repaint_initialized: bool = false,
    pump_initialized: bool = false,
    output_initialized: bool = false,
    raw: ?external_tty.RawTty = null,
    enter_reserve: [64]u8 = undefined,
    enter_len: u7 = 0,
    leave_reserve: [64]u8 = undefined,
    leave_len: u7 = 0,
    poll_fds: [4]posix.pollfd = undefined,
    next_projection_sequence: u64 = 1,

    pub fn prepareInPlace(
        self: *PreRawOwner,
        prepared: *external_attach.Prepared,
        allocator: std.mem.Allocator,
        io: std.Io,
        stdin_fd: c.fd_t,
        stdout_fd: c.fd_t,
    ) PreRawPrepareError!void {
        if (self.saved_self_addr != 0 or self.lifecycle != .empty)
            return error.DestinationNotEmpty;
        if (rangesOverlap(
            @intFromPtr(self),
            @sizeOf(PreRawOwner),
            @intFromPtr(prepared),
            @sizeOf(external_attach.Prepared),
        )) return error.InvalidAlias;

        self.saved_self_addr = @intFromPtr(self);
        self.lifecycle = .preparing;
        errdefer self.abortPreparation();
        self.inspection = external_tty.RawTty.inspect(stdin_fd) catch
            return error.TtyInspectionFailed;
        self.output.initInPlace(stdout_fd) catch return error.OutputRejected;
        self.output_initialized = true;
        self.pump.initInPlace(prepared) catch return error.PumpRejected;
        self.pump_initialized = true;
        const screen = if (self.pump.attachment.screen) |*value| value else return error.MissingScreen;
        self.repaint = external_ansi.RepaintQueue.init(allocator);
        self.repaint_initialized = true;
        self.repaint.replaceLatest(
            screen.screenSource(),
            .{
                .cols = self.inspection.initial_size.cols,
                .rows = self.inspection.initial_size.rows,
            },
            io,
            self.next_projection_sequence,
        ) catch return error.RepaintRejected;
        self.next_projection_sequence += 1;

        @memcpy(self.enter_reserve[0..external_ansi.enter_bytes.len], external_ansi.enter_bytes);
        self.enter_len = @intCast(external_ansi.enter_bytes.len);
        @memcpy(self.leave_reserve[0..external_ansi.leave_bytes.len], external_ansi.leave_bytes);
        self.leave_len = @intCast(external_ansi.leave_bytes.len);
        const socket_fd = self.pump.socketPollFd() orelse return error.InvalidPollSet;
        const output_fd = self.output.pollFd() catch return error.InvalidPollSet;
        self.poll_fds = .{
            .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = socket_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = output_fd, .events = posix.POLL.OUT, .revents = 0 },
            .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 },
        };
        if (!self.addressValid()) return error.InvalidPollSet;
        self.lifecycle = .prepared;
    }

    pub fn commit(self: *PreRawOwner) PreRawCommitError!void {
        var context = PosixWriteContext{};
        return self.commitWithWriter(&context, posixWrite);
    }

    fn commitWithWriter(
        self: *PreRawOwner,
        write_context: *anyopaque,
        write_fn: WriteFn,
    ) PreRawCommitError!void {
        if (!self.addressValid()) return error.Moved;
        if (self.lifecycle != .prepared) return error.InvalidLifecycle;
        // Resolve every fallible owner/output invariant before mutating termios. Once raw mode is
        // entered, every remaining failure path must pass through leave+restore.
        const output_fd = self.output.pollFd() catch return error.Moved;
        self.lifecycle = .committing;
        self.raw = external_tty.RawTty.enterPrepared(self.inspection) catch |err| {
            self.lifecycle = .prepared;
            return if (err == error.TerminalChanged)
                error.TerminalChanged
            else
                error.RawEnterFailed;
        };
        self.poll_fds[3].fd = self.raw.?.wake_read_fd;
        writeExactWith(
            write_context,
            write_fn,
            output_fd,
            self.enter_reserve[0..self.enter_len],
        ) catch {
            self.bestEffortLeaveWith(write_context, write_fn);
            self.closeOutputBeforeRestore();
            self.raw.?.restore() catch {
                self.lifecycle = .tearing_down;
                return error.RestoreFailed;
            };
            self.raw = null;
            self.poll_fds[3].fd = -1;
            // A partial enter sequence is not replay-safe. Retain the aggregate cleanup
            // authority, but never admit a second commit after any enter-write failure.
            self.lifecycle = .tearing_down;
            return error.EnterWriteFailed;
        };
        self.lifecycle = .live;
    }

    pub fn pollSet(self: *PreRawOwner) PreRawCommitError!*[4]posix.pollfd {
        if (!self.addressValid()) return error.Moved;
        if (self.lifecycle != .live) return error.InvalidLifecycle;
        return &self.poll_fds;
    }

    pub fn teardown(self: *PreRawOwner) PreRawTeardownResult {
        return self.teardownInternal(null);
    }

    /// Uses the ordinary ownership cleanup graph, then replays the termination signal only after
    /// the original dispositions and mask are restored and every local owner is closed.
    pub fn teardownAndForwardSignal(
        self: *PreRawOwner,
        signal: posix.SIG,
    ) PreRawTeardownResult {
        return self.teardownInternal(signal);
    }

    fn teardownInternal(
        self: *PreRawOwner,
        forward_signal: ?posix.SIG,
    ) PreRawTeardownResult {
        if (self.saved_self_addr == 0 and self.lifecycle == .empty) return .already_dead;
        if (!self.addressValid()) return .moved;
        if (self.lifecycle == .dead) return .already_dead;
        // `prepareInPlace` invokes the caller's allocator while repaint storage is being built.
        // A reentrant teardown must not free that storage, the pump, or the output underneath the
        // active allocation callback. Commit has the same closed transaction rule even though its
        // product writer is POSIX-only; both transitions retain sole cleanup authority here.
        if (self.lifecycle == .preparing or self.lifecycle == .committing) return .busy;
        self.lifecycle = .tearing_down;
        var terminal_result: PreRawTeardownResult = .cleaned;
        if (self.raw) |*raw| {
            self.bestEffortLeave();
            // End this owner's dedicated output reference before TCSAFLUSH. On Darwin PTYs an
            // already-consumed leave sequence can still leave tcsetattr waiting while another
            // writer for the same slave remains open. Cleanup never writes ANSI after leave, so
            // closing this independently-owned fd here is both the ownership boundary and the
            // ordering required before termios restore.
            self.closeOutputBeforeRestore();
            raw.restore() catch return .restore_failed;
            self.raw = null;
            self.poll_fds[3].fd = -1;
        }
        if (self.repaint_initialized) {
            self.repaint.deinit();
            self.repaint_initialized = false;
        }
        if (self.pump_initialized) {
            switch (self.pump.teardown()) {
                .cleaned, .already_dead => self.pump_initialized = false,
                .cleaned_with_invariant => {
                    self.pump_initialized = false;
                    terminal_result = .cleaned_with_invariant;
                },
                .busy => return .pump_busy,
                .quarantined => {
                    self.pump_initialized = false;
                    terminal_result = .pump_quarantined;
                },
                .moved => return .moved,
            }
        }
        if (self.output_initialized) {
            self.output.deinit();
            self.output_initialized = false;
        }
        self.lifecycle = .dead;
        if (forward_signal) |signal| _ = c.kill(c.getpid(), signal);
        return terminal_result;
    }

    fn addressValid(self: *const PreRawOwner) bool {
        if (self.saved_self_addr != @intFromPtr(self)) return false;
        if (self.output_initialized) {
            const fd = self.output.pollFd() catch return false;
            if (fd < 0) return false;
        }
        if (self.pump_initialized and !self.pump.addressValid()) return false;
        return self.enter_len <= self.enter_reserve.len and
            self.leave_len <= self.leave_reserve.len;
    }

    fn abortPreparation(self: *PreRawOwner) void {
        if (self.repaint_initialized) {
            self.repaint.deinit();
            self.repaint_initialized = false;
        }
        if (self.pump_initialized) {
            switch (self.pump.teardown()) {
                .cleaned, .cleaned_with_invariant, .already_dead, .quarantined => self.pump_initialized = false,
                // Retain the cleanup authority and a retryable lifecycle. Never hide a live
                // pump behind a dead pre-raw owner merely because preparation failed later.
                .busy, .moved => {
                    self.lifecycle = .tearing_down;
                    return;
                },
            }
        }
        if (self.output_initialized) {
            self.output.deinit();
            self.output_initialized = false;
        }
        self.lifecycle = .dead;
    }

    fn bestEffortLeave(self: *PreRawOwner) void {
        var context = PosixWriteContext{};
        self.bestEffortLeaveWith(&context, posixWrite);
    }

    fn closeOutputBeforeRestore(self: *PreRawOwner) void {
        if (!self.output_initialized) return;
        self.output.deinit();
        self.output_initialized = false;
        self.poll_fds[2].fd = -1;
    }

    fn bestEffortLeaveWith(
        self: *PreRawOwner,
        write_context: *anyopaque,
        write_fn: WriteFn,
    ) void {
        const fd = self.output.pollFd() catch return;
        writeExactWith(
            write_context,
            write_fn,
            fd,
            self.leave_reserve[0..self.leave_len],
        ) catch {};
    }
};

const WriteOutcome = union(enum) {
    bytes: usize,
    interrupted,
    failed,
};

const WriteFn = *const fn (*anyopaque, c.fd_t, []const u8) WriteOutcome;
const PosixWriteContext = struct {};

fn posixWrite(_: *anyopaque, fd: c.fd_t, bytes: []const u8) WriteOutcome {
    const written = c.write(fd, bytes.ptr, bytes.len);
    if (written > 0) return .{ .bytes = @intCast(written) };
    if (written < 0 and posix.errno(written) == .INTR) return .interrupted;
    return .failed;
}

fn writeExactWith(
    context: *anyopaque,
    write_fn: WriteFn,
    fd: c.fd_t,
    bytes: []const u8,
) error{WriteFailed}!void {
    var offset: usize = 0;
    var attempts: u8 = 0;
    while (offset < bytes.len) {
        attempts = std.math.add(u8, attempts, 1) catch return error.WriteFailed;
        if (attempts > 128) return error.WriteFailed;
        switch (write_fn(context, fd, bytes[offset..])) {
            .bytes => |written| {
                if (written == 0 or written > bytes.len - offset)
                    return error.WriteFailed;
                offset += written;
            },
            .interrupted => continue,
            .failed => return error.WriteFailed,
        }
    }
}

fn preparedAttachmentCanonical(attachment: *const remote_attachment.RemoteAttachment) bool {
    // A real attach already owns its initial screen. Binding is the only attachment field this
    // composition step creates, so null transport is the exact precondition here; screen/queue
    // ownership remains with the source until the final no-fail move.
    return attachment.transport == null;
}

fn preparedAttachmentMatches(
    attachment: *const remote_attachment.RemoteAttachment,
    allocator: std.mem.Allocator,
    state: remote_attachment.State,
) bool {
    return preparedAttachmentCanonical(attachment) and
        attachment.allocator.ptr == allocator.ptr and
        attachment.allocator.vtable == allocator.vtable and
        std.meta.eql(attachment.state, state);
}

fn rangesOverlap(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_end = @addWithOverflow(a_start, a_len);
    const b_end = @addWithOverflow(b_start, b_len);
    if (a_end[1] != 0 or b_end[1] != 0) return true;
    return a_start < b_end[0] and b_start < a_end[0];
}

test "p5c3c-2b3 owner rejects a moved final-address copy in every build mode" {
    var owner: ExternalPumpOwner = .{};
    owner.saved_self_addr = @intFromPtr(&owner);
    owner.lifecycle = .live;
    owner.adapter = .{
        .saved_self_addr = @intFromPtr(&owner.adapter),
        .owner_addr = @intFromPtr(&owner),
    };

    var moved = owner;
    const result = moved.pump(.{
        .readable = false,
        .writable = false,
        .now_ns = 1,
    }, &.{
        .context = undefined,
        .context_len = 0,
        .apply_live_screen = struct {
            fn call(
                _: *anyopaque,
                _: client_external_pump.LiveScreenPayloadView,
            ) client_external_pump.LiveScreenApplyResult {
                return .applied;
            }
        }.call,
    });
    try std.testing.expectEqual(client_pump.TerminalReason.invariant_failure, result.terminal.?.reason);
    try std.testing.expectEqual(TeardownResult.moved, moved.teardown());
}

const P5c3c2b3PreparedFixture = struct {
    prepared: external_attach.Prepared,
    peer_fd: c.fd_t,

    fn init(instance_id: u64) !P5c3c2b3PreparedFixture {
        return initWithAllocator(instance_id, std.testing.allocator);
    }

    fn initWithAllocator(
        instance_id: u64,
        allocator: std.mem.Allocator,
    ) !P5c3c2b3PreparedFixture {
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
            .attach_instance_id = instance_id,
            .connection_profile = .cli_attach,
            .compatibility_profile = compatibility.profileForMajor(protocol.version_major).?,
            .attachment_capabilities = .{
                .peer_attach_generation = true,
                .negotiated_controller_transfer = true,
            },
        };
        errdefer {
            client.deinit();
            _ = c.close(fds[1]);
        }
        try client.enterExternalMode();
        return .{
            .prepared = .{
                .attach_instance_id = instance_id,
                .client = client,
                .attachment = remote_attachment.RemoteAttachment.init(
                    allocator,
                    .{
                        .runtime_id = 0xaa,
                        .stream_id = 7,
                        .role = .controller,
                        .controller_generation = 3,
                    },
                ),
                .initial_metadata = runtime_metadata_wire.InitialMetadataSeed.unsupported,
            },
            .peer_fd = fds[1],
        };
    }

    fn initWithBatch(instance_id: u64, bytes: []const u8) !P5c3c2b3PreparedFixture {
        return initWithBatchAllocator(
            instance_id,
            bytes,
            false,
            std.testing.allocator,
        );
    }

    fn initWithBatchAllocator(
        instance_id: u64,
        bytes: []const u8,
        is_snapshot: bool,
        allocator: std.mem.Allocator,
    ) !P5c3c2b3PreparedFixture {
        var fixture = try initWithAllocator(instance_id, allocator);
        errdefer fixture.deinit();
        const owned = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned);
        try fixture.prepared.client.screen_inbox.pending_batches.append(
            allocator,
            .{
                .is_snapshot = is_snapshot,
                .stream_id = fixture.prepared.attachment.state.stream_id,
                .bytes = owned,
                .allocator = allocator,
            },
        );
        fixture.prepared.client.screen_inbox.pending_batch_bytes = owned.len;
        return fixture;
    }

    fn deinit(self: *P5c3c2b3PreparedFixture) void {
        self.prepared.deinit();
        if (self.peer_fd >= 0) _ = c.close(self.peer_fd);
        self.peer_fd = -1;
    }
};

fn p5c3c3a2PreparedFixture(instance_id: u64) !P5c3c2b3PreparedFixture {
    var fixture = try P5c3c2b3PreparedFixture.init(instance_id);
    errdefer fixture.deinit();
    try fixture.prepared.attachment.initScreen(screen_stream.codec_version);
    return fixture;
}

/// Test-only constructor shared with the 3b aggregate's actual-PTY composition tests. Product
/// builds expose an empty namespace and therefore cannot construct synthetic prepared authority.
pub const testing = if (builtin.is_test) struct {
    pub const PreparedFixture = P5c3c2b3PreparedFixture;
    pub const AuthorityEvent = client_external_pump.testing.AuthorityEvent;

    pub fn preparedFixture(instance_id: u64) !PreparedFixture {
        return p5c3c3a2PreparedFixture(instance_id);
    }

    pub fn deinitPreparedFixture(fixture: *PreparedFixture) void {
        fixture.deinit();
    }

    pub fn clearInitialFence(owner: *ExternalPumpOwner) bool {
        return client_external_pump.testing.clearInitialFence(&owner.storage);
    }
} else struct {};

fn readExactPty(fd: c.fd_t, destination: []u8) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        var poll_fds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        if (try posix.poll(&poll_fds, 5_000) != 1) return error.TestTimedOut;
        const count = c.read(fd, destination.ptr + offset, destination.len - offset);
        if (count > 0) {
            offset += @intCast(count);
            continue;
        }
        if (count < 0 and posix.errno(count) == .INTR) continue;
        return error.TestUnexpectedResult;
    }
}

fn readExactPtyThread(fd: c.fd_t, destination: []u8) void {
    readExactPty(fd, destination) catch @panic("PTY output reader failed");
}

fn waitP5c3c3a2ChildDeadline(pid: c.pid_t, timeout_ms: i64) !u32 {
    var status: c_int = 0;
    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    while (started.untilNow(std.testing.io, .awake).toMilliseconds() < timeout_ms) {
        const result = c.waitpid(pid, &status, c.W.NOHANG);
        if (result == pid) return @bitCast(status);
        if (result < 0 and posix.errno(result) == .INTR) continue;
        if (result < 0) return error.TestUnexpectedResult;
        _ = usleep(10_000);
    }
    return error.TestTimedOut;
}

fn killP5c3c3a2ChildAndReap(pid: c.pid_t) void {
    _ = c.kill(pid, posix.SIG.KILL);
    _ = waitP5c3c3a2ChildDeadline(pid, 5_000) catch {};
}

test "p5c3c-3a2 pre-raw owner mutates no TTY or ANSI state before commit" {
    const initial = std.mem.zeroes(posix.termios);
    const window: posix.winsize = .{ .row = 37, .col = 113, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(
        &master,
        &slave,
        null,
        &initial,
        &window,
    ));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);
    var fixture = try p5c3c3a2PreparedFixture(0x3a20);
    defer fixture.deinit();
    var owner: PreRawOwner = .{};
    try owner.prepareInPlace(
        &fixture.prepared,
        std.testing.allocator,
        std.testing.io,
        slave,
        slave,
    );
    const after_prepare = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&before),
        std.mem.asBytes(&after_prepare),
    );
    var readable = [_]posix.pollfd{.{ .fd = master, .events = posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&readable, 0));
    try std.testing.expectEqual(PreRawLifecycle.prepared, owner.lifecycle);
    try std.testing.expect(owner.repaint.current != null);
    try std.testing.expectEqual(@as(u64, 0), fixture.prepared.attach_instance_id);
    try std.testing.expectEqual(PreRawTeardownResult.cleaned, owner.teardown());
}

test "p5c3c-3a2 raw commit publishes exact enter and teardown restores with exact leave" {
    const window: posix.winsize = .{ .row = 41, .col = 119, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(
        &master,
        &slave,
        null,
        null,
        &window,
    ));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);
    try std.testing.expect(before.lflag.ECHO and before.lflag.ICANON);

    var ready: [2]c.fd_t = undefined;
    var proceed: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&ready));
    defer {
        if (ready[0] >= 0) _ = c.close(ready[0]);
        if (ready[1] >= 0) _ = c.close(ready[1]);
    }
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&proceed));
    defer {
        if (proceed[0] >= 0) _ = c.close(proceed[0]);
        if (proceed[1] >= 0) _ = c.close(proceed[1]);
    }

    const child = c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    var child_reaped = false;
    errdefer if (!child_reaped) killP5c3c3a2ChildAndReap(child);
    if (child == 0) {
        _ = c.close(master);
        _ = c.close(ready[0]);
        _ = c.close(proceed[1]);
        var fixture = p5c3c3a2PreparedFixture(0x3a21) catch c._exit(120);
        var owner: PreRawOwner = .{};
        owner.prepareInPlace(
            &fixture.prepared,
            std.heap.page_allocator,
            std.testing.io,
            slave,
            slave,
        ) catch c._exit(121);
        owner.commit() catch c._exit(122);
        const poll_set = owner.pollSet() catch c._exit(123);
        if (poll_set[0].fd != slave or poll_set[1].fd < 0 or
            poll_set[2].fd < 0 or poll_set[3].fd < 0)
            c._exit(124);
        const marker = [1]u8{1};
        if (c.write(ready[1], &marker, marker.len) != marker.len) c._exit(125);
        var acknowledgement: [1]u8 = undefined;
        while (true) {
            const count = c.read(proceed[0], &acknowledgement, acknowledgement.len);
            if (count == 1) break;
            if (count < 0 and posix.errno(count) == .INTR) continue;
            c._exit(126);
        }
        if (owner.teardown() != .cleaned) c._exit(127);
        c._exit(0);
    }

    _ = c.close(ready[1]);
    ready[1] = -1;
    _ = c.close(proceed[0]);
    proceed[0] = -1;
    var ready_poll = [_]posix.pollfd{.{
        .fd = ready[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    if (try posix.poll(&ready_poll, 5_000) != 1) return error.TestTimedOut;
    var marker: [1]u8 = undefined;
    if (c.read(ready[0], &marker, marker.len) != marker.len) return error.TestUnexpectedResult;
    const during = try posix.tcgetattr(slave);
    try std.testing.expect(!during.lflag.ECHO and !during.lflag.ICANON);
    if (c.write(proceed[1], &marker, marker.len) != marker.len)
        return error.TestUnexpectedResult;

    var tty_bytes: [external_ansi.enter_bytes.len + external_ansi.leave_bytes.len]u8 = undefined;
    try readExactPty(master, &tty_bytes);
    const status = try waitP5c3c3a2ChildDeadline(child, 5_000);
    child_reaped = true;
    try std.testing.expect(c.W.IFEXITED(status));
    try std.testing.expectEqual(@as(c_int, 0), c.W.EXITSTATUS(status));
    try std.testing.expectEqualSlices(
        u8,
        external_ansi.enter_bytes,
        tty_bytes[0..external_ansi.enter_bytes.len],
    );
    try std.testing.expectEqualSlices(
        u8,
        external_ansi.leave_bytes,
        tty_bytes[external_ansi.enter_bytes.len..],
    );
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
}

test "p5c3c-3a2 commit rejects TTY drift before raw mutation and remains cleanable" {
    const initial = std.mem.zeroes(posix.termios);
    const window: posix.winsize = .{ .row = 37, .col = 113, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(
        &master,
        &slave,
        null,
        &initial,
        &window,
    ));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);
    var fixture = try p5c3c3a2PreparedFixture(0x3a22);
    defer fixture.deinit();
    var owner: PreRawOwner = .{};
    try owner.prepareInPlace(
        &fixture.prepared,
        std.testing.allocator,
        std.testing.io,
        slave,
        slave,
    );
    var drifted: posix.winsize = .{ .row = 38, .col = 114, .xpixel = 0, .ypixel = 0 };
    try std.testing.expectEqual(@as(c_int, 0), c.ioctl(master, darwin_tiocswinsz, &drifted));
    try std.testing.expectError(error.TerminalChanged, owner.commit());
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
    try std.testing.expectEqual(PreRawLifecycle.prepared, owner.lifecycle);
    try std.testing.expectEqual(PreRawTeardownResult.cleaned, owner.teardown());
}

const P5c3c3a2PartialEnterWriter = struct {
    calls: usize = 0,
    saw_leave: bool = false,

    fn write(raw: *anyopaque, _: c.fd_t, bytes: []const u8) WriteOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return switch (self.calls) {
            1 => .interrupted,
            2 => .{ .bytes = 1 },
            3 => .failed,
            4 => result: {
                self.saw_leave = std.mem.eql(u8, bytes, external_ansi.leave_bytes);
                break :result .{ .bytes = bytes.len };
            },
            else => .failed,
        };
    }
};

test "p5c3c-3a2 partial enter write restores TTY and keeps terminal cleanup authority" {
    const window: posix.winsize = .{ .row = 42, .col = 120, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(
        &master,
        &slave,
        null,
        null,
        &window,
    ));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);
    var fixture = try p5c3c3a2PreparedFixture(0x3a23);
    defer fixture.deinit();
    var owner: PreRawOwner = .{};
    try owner.prepareInPlace(
        &fixture.prepared,
        std.testing.allocator,
        std.testing.io,
        slave,
        slave,
    );
    var writer = P5c3c3a2PartialEnterWriter{};
    try std.testing.expectError(
        error.EnterWriteFailed,
        owner.commitWithWriter(&writer, P5c3c3a2PartialEnterWriter.write),
    );
    try std.testing.expectEqual(@as(usize, 4), writer.calls);
    try std.testing.expect(writer.saw_leave);
    try std.testing.expectEqual(PreRawLifecycle.tearing_down, owner.lifecycle);
    try std.testing.expect(!owner.output_initialized);
    try std.testing.expectEqual(@as(c.fd_t, -1), owner.poll_fds[2].fd);
    try std.testing.expectError(error.InvalidLifecycle, owner.commit());
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
    try std.testing.expectEqual(PreRawTeardownResult.cleaned, owner.teardown());
}

test "p5c3c-3a2 repaint allocation failure consumes or cleans every owner without raw mutation" {
    const window: posix.winsize = .{ .row = 43, .col = 121, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(
        &master,
        &slave,
        null,
        null,
        &window,
    ));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);
    var fixture = try p5c3c3a2PreparedFixture(0x3a24);
    defer fixture.deinit();
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var owner: PreRawOwner = .{};
    try std.testing.expectError(error.RepaintRejected, owner.prepareInPlace(
        &fixture.prepared,
        failing.allocator(),
        std.testing.io,
        slave,
        slave,
    ));
    try std.testing.expectEqual(@as(u64, 0), fixture.prepared.attach_instance_id);
    try std.testing.expectEqual(PreRawLifecycle.dead, owner.lifecycle);
    try std.testing.expectEqual(PreRawTeardownResult.already_dead, owner.teardown());
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
    var readable = [_]posix.pollfd{.{ .fd = master, .events = posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&readable, 0));
}

const P5c3c3a2ReentrantAllocator = struct {
    parent: std.mem.Allocator,
    owner: ?*PreRawOwner = null,
    teardown_result: ?PreRawTeardownResult = null,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.teardown_result == null)
            self.teardown_result = self.owner.?.teardown();
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }

    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

test "p5c3c-3a2 repaint allocator teardown reentry is busy and preserves the final owner" {
    const window: posix.winsize = .{ .row = 44, .col = 122, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(
        &master,
        &slave,
        null,
        null,
        &window,
    ));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);
    var fixture = try p5c3c3a2PreparedFixture(0x3a25);
    defer fixture.deinit();
    var owner: PreRawOwner = .{};
    var reentrant = P5c3c3a2ReentrantAllocator{
        .parent = std.testing.allocator,
        .owner = &owner,
    };
    try owner.prepareInPlace(
        &fixture.prepared,
        reentrant.allocator(),
        std.testing.io,
        slave,
        slave,
    );
    try std.testing.expectEqual(PreRawTeardownResult.busy, reentrant.teardown_result.?);
    try std.testing.expectEqual(PreRawLifecycle.prepared, owner.lifecycle);
    try std.testing.expectEqual(PreRawTeardownResult.cleaned, owner.teardown());
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
}

const P5c3c3a2CommitReentrantWriter = struct {
    owner: *PreRawOwner,
    teardown_result: ?PreRawTeardownResult = null,

    fn write(raw: *anyopaque, fd: c.fd_t, bytes: []const u8) WriteOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.teardown_result == null)
            self.teardown_result = self.owner.teardown();
        return posixWrite(raw, fd, bytes);
    }
};

test "p5c3c-3a2 enter writer teardown reentry is busy until commit publishes live" {
    const window: posix.winsize = .{ .row = 45, .col = 123, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(
        &master,
        &slave,
        null,
        null,
        &window,
    ));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);
    var fixture = try p5c3c3a2PreparedFixture(0x3a26);
    defer fixture.deinit();
    var owner: PreRawOwner = .{};
    try owner.prepareInPlace(
        &fixture.prepared,
        std.testing.allocator,
        std.testing.io,
        slave,
        slave,
    );
    var writer = P5c3c3a2CommitReentrantWriter{ .owner = &owner };
    try owner.commitWithWriter(&writer, P5c3c3a2CommitReentrantWriter.write);
    try std.testing.expectEqual(PreRawTeardownResult.busy, writer.teardown_result.?);
    try std.testing.expectEqual(PreRawLifecycle.live, owner.lifecycle);
    var enter: [external_ansi.enter_bytes.len]u8 = undefined;
    try readExactPty(master, &enter);
    try std.testing.expectEqualSlices(u8, external_ansi.enter_bytes, &enter);

    var leave: [external_ansi.leave_bytes.len]u8 = undefined;
    const leave_reader = try std.Thread.spawn(.{}, readExactPtyThread, .{ master, &leave });
    const teardown_result = owner.teardown();
    leave_reader.join();
    try std.testing.expectEqual(PreRawTeardownResult.cleaned, teardown_result);
    try std.testing.expectEqualSlices(u8, external_ansi.leave_bytes, &leave);
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
}

const P5c3c2b3BindDriftAllocator = struct {
    parent: std.mem.Allocator,
    target: ?*remote_attachment.RemoteAttachment = null,
    replacement: ?remote_attachment.AttachmentTransport = null,
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

    fn alloc(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.armed and !self.fired) {
            self.fired = true;
            self.target.?.transport = self.replacement.?;
        }
        return self.parent.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.parent.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.parent.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.parent.rawFree(memory, alignment, return_address);
    }
};

test "p5c3c-2b3 final owner consumes prepared once and binds only its stable adapter" {
    var fixture = try P5c3c2b3PreparedFixture.init(0x2b3);
    defer fixture.deinit();
    var owner: ExternalPumpOwner = .{};

    fixture.prepared.attachment.transport = owner.adapter.interface();
    try std.testing.expectError(
        error.InvalidPrepared,
        owner.initInPlace(&fixture.prepared),
    );
    try std.testing.expectEqual(OwnerLifecycle.empty, owner.lifecycle);
    fixture.prepared.attachment.transport = null;

    try owner.initInPlace(&fixture.prepared);
    try std.testing.expectEqual(@as(u64, 0), fixture.prepared.attach_instance_id);
    try std.testing.expectEqual(@intFromPtr(&owner.adapter), @intFromPtr(
        owner.attachment.transport.?.context,
    ));
    try std.testing.expect(owner.addressValid());

    var second: ExternalPumpOwner = .{};
    try std.testing.expectError(
        error.InvalidPrepared,
        second.initInPlace(&fixture.prepared),
    );
    try std.testing.expectEqual(TeardownResult.cleaned, owner.teardown());
    try std.testing.expectEqual(TeardownResult.already_dead, owner.teardown());

    var drift_allocator = P5c3c2b3BindDriftAllocator{
        .parent = std.testing.allocator,
    };
    var drift_fixture = try P5c3c2b3PreparedFixture.initWithAllocator(
        0x2b31,
        drift_allocator.allocator(),
    );
    defer drift_fixture.deinit();
    var drift_owner: ExternalPumpOwner = .{};
    drift_allocator.target = &drift_fixture.prepared.attachment;
    drift_allocator.replacement = drift_owner.adapter.interface();
    drift_allocator.armed = true;
    try std.testing.expectError(
        error.AdoptionRejected,
        drift_owner.initInPlace(&drift_fixture.prepared),
    );
    try std.testing.expect(drift_allocator.fired);
    drift_fixture.prepared.attachment.transport = null;
    try std.testing.expectEqual(TeardownResult.already_dead, drift_owner.teardown());
}

test "p5c3c-2b3 attachment-held charged lease blocks storage teardown until release" {
    var fixture = try P5c3c2b3PreparedFixture.initWithBatch(0x2b4, "batch");
    defer fixture.deinit();
    var owner: ExternalPumpOwner = .{};
    try owner.initInPlace(&fixture.prepared);
    defer _ = owner.teardown();

    const transport = owner.attachment.transport.?;
    const lease = (try transport.read_batch(transport.context, 7)).?;
    const token = switch (lease) {
        .charged => |charged| charged,
        else => return error.TestUnexpectedResult,
    };
    const borrow = transport.borrow_charged.?;
    const view = try borrow(transport.context, token);
    try std.testing.expectEqualStrings("batch", view.bytes);
    try std.testing.expectEqual(
        client_external_pump.TeardownResult.transaction_busy,
        owner.storage.teardown(&owner.cleanup_scratch),
    );
    try transport.release_charged.?(transport.context, token);
    try std.testing.expectEqual(TeardownResult.cleaned, owner.teardown());
}

test "p5c3c-2b3 poison preserves Client and ledger until attachment-first cleanup" {
    var fixture = try P5c3c2b3PreparedFixture.initWithBatch(0x2b5, "poisoned-batch");
    defer fixture.deinit();
    var owner: ExternalPumpOwner = .{};
    try owner.initInPlace(&fixture.prepared);
    defer _ = owner.teardown();

    const transport = owner.attachment.transport.?;
    const lease = (try transport.read_batch(transport.context, 7)).?;
    try owner.attachment.pending_batches.append(std.testing.allocator, lease);
    transport.fail_closed(transport.context, .transport_read_failure);
    try std.testing.expect(client_external_pump.testing.hasClientObject(&owner.storage));
    try std.testing.expect(client_external_pump.testing.attachmentLeaseHeld(&owner.storage));
    try std.testing.expectEqual(
        client_external_pump.TeardownResult.transaction_busy,
        owner.storage.teardown(&owner.cleanup_scratch),
    );
    try std.testing.expectEqual(TeardownResult.cleaned, owner.teardown());
}

test "p5c3c-2b3 actual external attach prepare drives one owner pump control and teardown" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const daemon = @import("daemon.zig");
    const discovery = @import("discovery.zig");
    const host_connect = @import("host_connect.zig");
    const host_manifest = @import("host_manifest.zig");
    const short_endpoint = @import("short_endpoint.zig");
    const allocator = std.testing.allocator;
    const host_id = (@as(u128, @intCast(c.getpid())) << 64) | 0x2b3;
    var base_buf: [192]u8 = undefined;
    const base = try std.fmt.bufPrintZ(
        &base_buf,
        "/tmp/maru-external-owner-2b3-{d}",
        .{c.getpid()},
    );
    std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
    _ = c.mkdir(base.ptr, 0o700);
    var session_buf: [256]u8 = undefined;
    const session_dir = try discovery.sessionHostDirPath(&session_buf, base);
    try short_endpoint.prepareCurrentUserNamespace();
    var endpoint_buf: [128]u8 = undefined;
    const endpoint = try short_endpoint.currentSocketPathIn(&endpoint_buf, host_id);

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        daemon.runSessionHostWithIdentity(
            std.heap.page_allocator,
            std.testing.io,
            session_dir,
            endpoint,
            host_id,
        ) catch {};
        c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        host_manifest.removeEmptyHostDirectories(session_dir, host_id);
        std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
    }

    var admin = blk: {
        var attempt: usize = 0;
        // `mise run check` intentionally runs several process-heavy suites in parallel. Host
        // startup is test orchestration rather than a product attach phase, so give the child a
        // bounded 15-second readiness window while the product calls below retain their own exact
        // five-second phase deadlines.
        while (attempt < 750) : (attempt += 1) {
            switch (host_connect.connectExistingHost(allocator, base, host_id)) {
                .connected => |client| break :blk client,
                .failed => {},
            }
            _ = usleep(20_000);
        }
        return error.TestUnexpectedResult;
    };
    defer admin.deinit();
    const spawn = try admin.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/cat\"],\"cols\":40,\"rows\":10}",
    );
    defer allocator.free(spawn);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, spawn, .{});
    defer parsed.deinit();
    const runtime_id = try std.fmt.parseInt(
        u128,
        parsed.value.object.get("result").?.object.get("runtime_id").?.string,
        16,
    );

    const prepared_result = external_attach.prepare(
        allocator,
        std.testing.io,
        base,
        .{ .runtime_id = runtime_id, .intent = .default_controller },
    );
    var prepared = switch (prepared_result) {
        .prepared => |value| value,
        .failed => |f| {
            std.debug.print("2b3 prepare failed: code={s} stage={s}\n", .{ @tagName(f.code), @tagName(f.stage) });
            return error.TestUnexpectedResult;
        },
    };
    defer prepared.deinit();
    var owner: ExternalPumpOwner = .{};
    try owner.initInPlace(&prepared);
    defer _ = owner.teardown();

    const Apply = struct {
        fn call(
            _: *anyopaque,
            _: client_external_pump.LiveScreenPayloadView,
        ) client_external_pump.LiveScreenApplyResult {
            return .applied;
        }
    };
    var marker: u8 = 0;
    const turn = owner.pump(.{
        .readable = false,
        .writable = false,
        .now_ns = 10,
    }, &.{
        .context = &marker,
        .context_len = @sizeOf(u8),
        .apply_live_screen = Apply.call,
    });
    try std.testing.expect(turn.terminal == null);
    const admitted = owner.admitControl(.{
        .request = .{ .resize = .{
            .stream_id = owner.attachment.state.stream_id,
            .cols = 40,
            .rows = 10,
            .client_sequence = 1,
        } },
        .expected_controller_generation = owner.attachment.state.controller_generation,
    }, 20);
    try std.testing.expect(admitted == .admitted);
    try std.testing.expectEqual(TeardownResult.cleaned, owner.teardown());
}

test "p5c3c-2b3 parser request id and capability state survive owner transition byte exact" {
    var fixture = try P5c3c2b3PreparedFixture.init(0x2b6);
    defer fixture.deinit();
    const partial = [_]u8{ 0x4d, 0x52, 0x53, 0x48, 0x00, 0x01, 0x02 };
    try fixture.prepared.client.parser.push(&partial);
    fixture.prepared.client.next_request_id = 91;
    const capabilities = fixture.prepared.client.attachment_capabilities;

    var owner: ExternalPumpOwner = .{};
    try owner.initInPlace(&fixture.prepared);
    defer _ = owner.teardown();
    try std.testing.expect(client_external_pump.testing.parserBytesEqual(
        &owner.storage,
        &partial,
    ));
    try std.testing.expect(client_external_pump.testing.attachmentCapabilitiesEqual(
        &owner.storage,
        capabilities,
    ));
    try std.testing.expectEqual(
        client_pump.RequestIdState{ .available = 91 },
        client_external_pump.testing.requestIdState(&owner.storage).?,
    );
    try std.testing.expectEqual(TeardownResult.cleaned, owner.teardown());
}

fn checkP5c3c2b3OwnerAllocationFailure(allocator: std.mem.Allocator) !void {
    var fixture = try P5c3c2b3PreparedFixture.initWithAllocator(0x2b7, allocator);
    defer fixture.deinit();
    var owner: ExternalPumpOwner = .{};
    owner.initInPlace(&fixture.prepared) catch |err| {
        _ = owner.teardown();
        return err;
    };
    try std.testing.expectEqual(TeardownResult.cleaned, owner.teardown());
}

test "p5c3c-2b3 allocation fail index cleans exactly source or final owner" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkP5c3c2b3OwnerAllocationFailure,
        .{},
    );
}

test "p5c3c-2b3 owner pump fail-closes revoke and control timeout" {
    const Apply = struct {
        fn call(
            _: *anyopaque,
            _: client_external_pump.LiveScreenPayloadView,
        ) client_external_pump.LiveScreenApplyResult {
            return .applied;
        }
    };
    var marker: u8 = 0;
    const buffered = client_external_pump.BufferedRxOps{
        .context = &marker,
        .context_len = @sizeOf(u8),
        .apply_live_screen = Apply.call,
    };

    {
        var fixture = try P5c3c2b3PreparedFixture.init(0x2b8);
        defer fixture.deinit();
        var owner: ExternalPumpOwner = .{};
        try owner.initInPlace(&fixture.prepared);
        defer _ = owner.teardown();
        const revoke = try framing.encodeFrame(
            std.testing.allocator,
            .{ .kind = .event, .stream_id = 7 },
            "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
        );
        defer std.testing.allocator.free(revoke);
        try writeAllFd(fixture.peer_fd, revoke);
        const result = owner.pump(.{
            .readable = true,
            .writable = false,
            .now_ns = 1,
        }, &buffered);
        try std.testing.expectEqual(client_pump.TerminalReason.revoked, result.terminal.?.reason);
        try std.testing.expectEqual(TeardownResult.cleaned, owner.teardown());
    }

    {
        var fixture = try P5c3c2b3PreparedFixture.init(0x2b9);
        defer fixture.deinit();
        var owner: ExternalPumpOwner = .{};
        try owner.initInPlace(&fixture.prepared);
        defer _ = owner.teardown();
        const admitted = owner.admitControl(.{
            .request = .{ .resize = .{
                .stream_id = 7,
                .cols = 80,
                .rows = 24,
                .client_sequence = 1,
            } },
            .expected_controller_generation = 3,
        }, 1);
        try std.testing.expect(admitted == .admitted);
        const first = owner.pump(.{
            .readable = false,
            .writable = false,
            .now_ns = 2,
        }, &buffered);
        try std.testing.expect(first.terminal == null);
        const deadline = switch (owner.pollHint()) {
            .hint => |hint| hint.next_deadline_ns orelse return error.TestUnexpectedResult,
            .moved_or_stale => return error.TestUnexpectedResult,
        };
        const expired = owner.pump(.{
            .readable = false,
            .writable = true,
            .now_ns = deadline + 1,
        }, &buffered);
        try std.testing.expectEqual(
            client_pump.TerminalReason.deadline_exceeded,
            expired.terminal.?.reason,
        );
        try std.testing.expectEqual(TeardownResult.cleaned, owner.teardown());
    }
}

fn writeAllFd(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = c.send(fd, bytes[offset..].ptr, bytes.len - offset, 0);
        if (written < 0) return error.TestUnexpectedResult;
        if (written == 0) return error.TestUnexpectedResult;
        offset += @intCast(written);
    }
}

fn p5c3c2b3Snapshot(allocator: std.mem.Allocator) ![]u8 {
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

test "p5c3c-2b3 attachment append and apply OOM release stable charged owner" {
    inline for (.{ false, true }) |fail_apply| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        const snapshot = try p5c3c2b3Snapshot(allocator);
        defer allocator.free(snapshot);
        var fixture = try P5c3c2b3PreparedFixture.initWithBatchAllocator(
            if (fail_apply) 0x2bb else 0x2ba,
            snapshot,
            true,
            allocator,
        );
        defer fixture.deinit();
        var owner: ExternalPumpOwner = .{};
        try owner.initInPlace(&fixture.prepared);
        defer _ = owner.teardown();
        try owner.attachment.initScreen(screen_stream.codec_version);
        if (fail_apply)
            try owner.attachment.pending_batches.ensureTotalCapacityPrecise(allocator, 1);
        failing.fail_index = failing.alloc_index;
        try std.testing.expectError(
            error.OutOfMemory,
            owner.attachment.pumpScreen(std.testing.io),
        );
        try std.testing.expect(owner.storage.attachment_lease == null);
        try std.testing.expectEqual(TeardownResult.cleaned, owner.teardown());
    }
}

fn createRxScratchForTest() !*client_external_pump.ExternalRxTurnScratch {
    const scratch =
        try std.testing.allocator.create(client_external_pump.ExternalRxTurnScratch);
    scratch.* = .{};
    if (!client_external_pump.ExternalRxTurnScratch.initInPlace(scratch)) {
        std.testing.allocator.destroy(scratch);
        return error.TestUnexpectedResult;
    }
    return scratch;
}

const D3RevokePrefix = enum { screen, optional_unknown };
const D3TerminalEvent = enum { revoked, runtime_ended };

fn exerciseD3SocketpairRevokePosition(
    position: usize,
    prefix_kind: D3RevokePrefix,
    terminal_event: D3TerminalEvent,
) !void {
    if (position == 0 or position > external_rx_intent.max_intents + 1)
        return error.TestUnexpectedResult;

    const Apply = struct {
        calls: usize = 0,
        order: ?*ProductRxOrderRecorder = null,

        fn run(
            raw: *anyopaque,
            _: client_external_pump.LiveScreenPayloadView,
        ) client_external_pump.LiveScreenApplyResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.order) |order| order.record(.apply_live_screen);
            self.calls += 1;
            return .applied;
        }
    };

    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var peer_open = true;
    defer {
        if (peer_open) _ = c.close(fds[1]);
    }

    const attach_instance_id: u64 = 7100 + @as(u64, @intCast(position));
    var source = client_mod.Client{
        .allocator = std.testing.allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(std.testing.allocator),
        .attach_instance_id = attach_instance_id,
        .connection_profile = .cli_attach,
        .compatibility_profile = compatibility.profileForMajor(protocol.version_major).?,
        .attachment_capabilities = .{
            .peer_attach_generation = true,
            .negotiated_controller_transfer = true,
        },
    };
    var source_owned = true;
    defer if (source_owned) source.deinit();
    try source.enterExternalMode();
    const screen = try framing.encodeFrame(
        std.testing.allocator,
        .{
            .kind = .delta_chunk,
            .stream_id = 7,
            .flags = protocol.Flags.end_stream,
        },
        "x",
    );
    defer std.testing.allocator.free(screen);
    const optional_unknown = try framing.encodeFrame(
        std.testing.allocator,
        .{
            .kind = @enumFromInt(55001),
            .flags = protocol.Flags.optional,
        },
        "ignored",
    );
    defer std.testing.allocator.free(optional_unknown);

    var prepared = external_attach.Prepared{
        .attach_instance_id = attach_instance_id,
        .client = source,
        .attachment = remote_attachment.RemoteAttachment.init(
            std.testing.allocator,
            .{
                .runtime_id = 0xaa,
                .stream_id = 7,
                .role = .controller,
                .controller_generation = 3,
            },
        ),
        .initial_metadata = runtime_metadata_wire.InitialMetadataSeed.unsupported,
    };
    source_owned = false;
    var prepared_client_owned = true;
    defer if (prepared_client_owned) prepared.client.deinit();
    defer prepared.attachment.deinit();
    defer prepared.initial_metadata.deinit();
    var evidence: client_external_pump.PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try external_attach_evidence.prepareInPlace(&evidence, &prepared);
    var cleanup: client_external_pump.ExternalPumpCleanupScratch = .{};
    try std.testing.expect(
        client_external_pump.ExternalPumpCleanupScratch.initInPlace(&cleanup),
    );
    var storage: client_external_pump.ExternalPumpStorage = .{};
    var storage_open = false;
    var scratch_to_destroy: ?*client_external_pump.ExternalRxTurnScratch = null;
    defer {
        if (storage_open) _ = storage.teardown(&cleanup);
        if (scratch_to_destroy) |owned_scratch|
            std.testing.allocator.destroy(owned_scratch);
    }
    switch (client_external_pump.ExternalPumpStorage.initInPlace(
        &storage,
        &prepared.client,
        &evidence,
    )) {
        .initialized => {
            prepared_client_owned = false;
            storage_open = true;
        },
        .failed => return error.TestUnexpectedResult,
    }
    try std.testing.expect(
        storage.prepareAdoption(1, &cleanup) == .prepared_adopted,
    );
    try std.testing.expect(storage.commitAdoption() == .adopted);
    try std.testing.expect(
        client_external_pump.testing.clearInitialFence(&storage),
    );
    const lower_before =
        client_external_pump.testing.lowerPublicationSnapshot(&storage) orelse
        return error.TestUnexpectedResult;

    const terminal_payload = switch (terminal_event) {
        .revoked => "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
        .runtime_ended => "{\"event\":\"runtime.ended\"}",
    };
    const terminal_wire = try framing.encodeFrame(
        std.testing.allocator,
        .{
            .kind = .event,
            .stream_id = 7,
        },
        terminal_payload,
    );
    defer std.testing.allocator.free(terminal_wire);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    const prefix = switch (prefix_kind) {
        .screen => screen,
        .optional_unknown => optional_unknown,
    };
    for (1..position) |_| try wire.appendSlice(std.testing.allocator, prefix);
    try wire.appendSlice(std.testing.allocator, terminal_wire);
    const expected_terminal: client_pump.TerminalReason = switch (terminal_event) {
        .revoked => .revoked,
        .runtime_ended => .runtime_ended,
    };

    const scratch = try createRxScratchForTest();
    scratch_to_destroy = scratch;
    var authority_receipt =
        client_external_pump.testing.AuthorityReceipt{};
    try std.testing.expect(
        client_external_pump.testing.beginAuthorityReceipt(
            &authority_receipt,
        ),
    );
    var authority_receipt_active = true;
    defer {
        if (authority_receipt_active)
            _ = client_external_pump.testing.endAuthorityReceipt(
                &authority_receipt,
            );
    }
    var apply = Apply{};
    const buffered = client_external_pump.BufferedRxOps{
        .context = &apply,
        .context_len = @sizeOf(Apply),
        .apply_live_screen = Apply.run,
    };
    var order = ProductRxOrderRecorder{};
    var read_calls: usize = 0;
    var context = PosixRxContext{
        .test_calls = &read_calls,
        .test_order = &order,
    };
    try std.testing.expectEqual(
        @as(isize, @intCast(wire.items.len)),
        c.send(fds[1], wire.items.ptr, wire.items.len, 0),
    );
    order.reset();
    read_calls = 0;
    const first_generation = scratch.turn_generation;
    const first = pumpRxWithContext(
        &storage,
        .{ .readable = true, .writable = true, .now_ns = 1 },
        &buffered,
        scratch,
        &context,
    );
    try std.testing.expect(!first.authority_clear);
    try std.testing.expect(!first.write_interest);
    try std.testing.expect(!first.control_ready);
    try std.testing.expectEqual(@as(usize, 0), first.tx_bytes);
    try std.testing.expectEqual(@as(usize, 0), first.tx_frames);
    try std.testing.expectEqual(@as(usize, 2), read_calls);
    try order.expect(&.{ .recv_bytes, .recv_would_block });

    if (position <= external_rx_intent.max_intents) {
        try std.testing.expectEqual(
            expected_terminal,
            first.terminal.?.reason,
        );
        try std.testing.expectEqual(first_generation, scratch.turn_generation);
        try std.testing.expectEqual(@as(usize, 0), apply.calls);
        try std.testing.expect(
            client_external_pump.testing.authorityDestinationsPristine(scratch),
        );
    } else {
        try std.testing.expect(first.terminal == null);
        try std.testing.expectEqual(
            prefix_kind == .optional_unknown,
            first.immediate_rx,
        );
        try std.testing.expectEqual(
            prefix_kind == .screen,
            first.inherited_work_ready,
        );
        try std.testing.expect(!first.read_interest);
        try std.testing.expectEqual(
            external_rx_intent.max_intents,
            first.rx_frames,
        );
        try std.testing.expectEqual(
            if (prefix_kind == .screen)
                @as(u8, @intCast(external_rx_intent.max_intents))
            else
                @as(u8, 0),
            storage.live_screen.len,
        );
        try std.testing.expect(
            client_external_pump.testing.bufferedParserBytes(&storage) ==
                terminal_wire.len,
        );
        try std.testing.expectEqual(
            first_generation + 1,
            scratch.turn_generation,
        );
        try std.testing.expect(
            client_external_pump.testing.authorityDestinationsPristine(scratch),
        );

        var inbound_sentinel: [1]u8 = .{'z'};
        const expect_inbound_sentinel =
            prefix_kind == .screen;
        if (expect_inbound_sentinel) {
            try std.testing.expectEqual(
                @as(isize, 1),
                c.send(
                    fds[1],
                    &inbound_sentinel,
                    inbound_sentinel.len,
                    0,
                ),
            );
            var peek: [1]u8 = undefined;
            try std.testing.expectEqual(
                @as(isize, 1),
                c.recv(
                    fds[0],
                    &peek,
                    peek.len,
                    posix.MSG.PEEK | posix.MSG.DONTWAIT,
                ),
            );
            try std.testing.expectEqual(inbound_sentinel[0], peek[0]);
        }

        if (prefix_kind == .screen) {
            for (0..external_rx_intent.max_intents) |_| {
                order.reset();
                apply.order = &order;
                const inherited = pumpRx(
                    &storage,
                    .{
                        .readable = true,
                        .writable = true,
                        .now_ns = 1,
                    },
                    &buffered,
                    scratch,
                );
                apply.order = null;
                try std.testing.expect(inherited.terminal == null);
                try std.testing.expect(inherited.inherited_work_ready);
                try std.testing.expect(!inherited.authority_clear);
                try std.testing.expect(!inherited.write_interest);
                try std.testing.expect(!inherited.control_ready);
                try std.testing.expectEqual(@as(usize, 0), inherited.tx_bytes);
                try std.testing.expectEqual(@as(usize, 0), inherited.tx_frames);
                try order.expect(&.{.apply_live_screen});
                try std.testing.expectEqual(
                    terminal_wire.len,
                    client_external_pump.testing.bufferedParserBytes(&storage).?,
                );
            }
            try std.testing.expectEqual(
                external_rx_intent.max_intents,
                apply.calls,
            );
            try std.testing.expectEqual(@as(u8, 0), storage.live_screen.len);
        } else {
            try std.testing.expectEqual(@as(usize, 0), apply.calls);
        }

        order.reset();
        read_calls = 0;
        const apply_calls_before_terminal = apply.calls;
        const terminal = pumpRxWithContext(
            &storage,
            .{
                .readable = true,
                .writable = true,
                .now_ns = 1,
            },
            &buffered,
            scratch,
            &context,
        );
        try std.testing.expectEqual(
            expected_terminal,
            terminal.terminal.?.reason,
        );
        try std.testing.expect(!terminal.authority_clear);
        try std.testing.expect(!terminal.write_interest);
        try std.testing.expect(!terminal.control_ready);
        try std.testing.expectEqual(@as(usize, 0), terminal.tx_bytes);
        try std.testing.expectEqual(@as(usize, 0), terminal.tx_frames);
        try std.testing.expectEqual(@as(usize, 0), read_calls);
        try order.expect(&.{});
        try std.testing.expectEqual(apply_calls_before_terminal, apply.calls);
        try std.testing.expect(
            client_external_pump.testing.authorityDestinationsPristine(scratch),
        );
        if (expect_inbound_sentinel) {
            var peek: [1]u8 = undefined;
            try std.testing.expectEqual(
                @as(isize, 1),
                c.recv(
                    fds[0],
                    &peek,
                    peek.len,
                    posix.MSG.PEEK | posix.MSG.DONTWAIT,
                ),
            );
            try std.testing.expectEqual(inbound_sentinel[0], peek[0]);
        }
    }

    if (position <= external_rx_intent.max_intents or
        prefix_kind == .optional_unknown)
    {
        const lower_after =
            client_external_pump.testing.lowerPublicationSnapshot(&storage) orelse
            return error.TestUnexpectedResult;
        if (expected_terminal == .revoked) {
            const authority = client_external_pump.testing.ownerAuthorityView(&storage) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(runtime_event_types.Role.observer, authority.role);
            if (prefix_kind == .screen)
                try std.testing.expectEqual(
                    @as(u8, @intCast(@min(position - 1, external_rx_intent.max_intents))),
                    lower_after.live_screen_len,
                );
        } else try std.testing.expectEqual(lower_before, lower_after);
    }
    try std.testing.expect(
        client_external_pump.testing.endAuthorityReceipt(
            &authority_receipt,
        ),
    );
    authority_receipt_active = false;
    try std.testing.expectEqual(@as(u8, 0), authority_receipt.len);
    var peer_byte: [1]u8 = undefined;
    const peer_read = c.recv(
        fds[1],
        &peer_byte,
        peer_byte.len,
        posix.MSG.DONTWAIT,
    );
    try std.testing.expectEqual(@as(isize, -1), peer_read);
    try std.testing.expectEqual(posix.E.AGAIN, posix.errno(peer_read));
    try std.testing.expectEqual(
        client_external_pump.TeardownResult.cleaned,
        storage.teardown(&cleanup),
    );
    storage_open = false;
    std.testing.allocator.destroy(scratch);
    scratch_to_destroy = null;
    _ = c.close(fds[1]);
    peer_open = false;
}

test "d2c POSIX RX adapter maps nonblocking bytes would-block EOF and hard error" {
    try std.testing.expect(
        mapPosixReadResult(-1, .INTR) == .interrupted,
    );
    try std.testing.expect(
        mapPosixReadResult(-1, .AGAIN) == .would_block,
    );
    try std.testing.expect(
        mapPosixReadResult(-1, .BADF) == .socket_error,
    );
    try std.testing.expect(
        mapPosixReadResult(-1, null) == .socket_error,
    );
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var first_open = true;
    defer {
        if (first_open) _ = c.close(fds[0]);
    }
    defer _ = c.close(fds[1]);
    const saved_flags = c.fcntl(fds[0], c.F.GETFL);
    try std.testing.expect(saved_flags >= 0);
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.fcntl(fds[0], c.F.SETFL, saved_flags | nonblocking),
    );

    var context = PosixRxContext{};
    var destination: [8]u8 = undefined;
    try std.testing.expect(
        readPosix(&context, fds[0], &destination) == .would_block,
    );
    try std.testing.expectEqual(
        @as(isize, 1),
        c.send(fds[1], "x", 1, 0),
    );
    const positive = readPosix(&context, fds[0], &destination);
    try std.testing.expect(positive == .bytes);
    try std.testing.expectEqual(@as(usize, 1), positive.bytes);
    try std.testing.expectEqual(@as(u8, 'x'), destination[0]);

    try std.testing.expectEqual(@as(c_int, 0), c.shutdown(fds[1], c.SHUT.WR));
    try std.testing.expect(readPosix(&context, fds[0], &destination) == .eof);
    _ = c.close(fds[0]);
    first_open = false;
    try std.testing.expect(
        readPosix(&context, fds[0], &destination) == .socket_error,
    );
    try std.testing.expect(
        readPosix(&context, -1, destination[0..0]) == .socket_error,
    );
}

test "D3 product socketpair revoke commits observer authority at frame 1 64 and 65" {
    inline for (.{ @as(usize, 1), 64, 65 }) |position|
        try exerciseD3SocketpairRevokePosition(position, .screen, .revoked);
    try exerciseD3SocketpairRevokePosition(
        65,
        .optional_unknown,
        .revoked,
    );
}

test "D3 product socketpair runtime ended terminalizes before lower authority" {
    try exerciseD3SocketpairRevokePosition(1, .screen, .runtime_ended);
}

test "d2c product owner maps readiness to POSIX RX before any writable work" {
    const Apply = struct {
        calls: usize = 0,
        bytes: [5]u8 = [_]u8{0} ** 5,
        order: ?*ProductRxOrderRecorder = null,

        fn run(
            raw: *anyopaque,
            view: client_external_pump.LiveScreenPayloadView,
        ) client_external_pump.LiveScreenApplyResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.order) |order| order.record(.apply_live_screen);
            self.calls += 1;
            if (view.bytes.len != self.bytes.len) return .retry;
            @memcpy(&self.bytes, view.bytes);
            return .applied;
        }
    };
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var peer_open = true;
    defer {
        if (peer_open) _ = c.close(fds[1]);
    }
    var source = client_mod.Client{
        .allocator = std.testing.allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(std.testing.allocator),
        .attach_instance_id = 7001,
        .connection_profile = .cli_attach,
        .compatibility_profile = compatibility.profileForMajor(protocol.version_major).?,
        .attachment_capabilities = .{
            .peer_attach_generation = true,
            .negotiated_controller_transfer = true,
        },
    };
    var source_owned = true;
    defer if (source_owned) source.deinit();
    try source.enterExternalMode();
    const wire = try framing.encodeFrame(
        std.testing.allocator,
        .{
            .kind = .delta_chunk,
            .stream_id = 7,
            .flags = protocol.Flags.end_stream,
        },
        "owner",
    );
    defer std.testing.allocator.free(wire);
    try source.parser.push(wire);

    var prepared = external_attach.Prepared{
        .attach_instance_id = 7001,
        .client = source,
        .attachment = remote_attachment.RemoteAttachment.init(
            std.testing.allocator,
            .{
                .runtime_id = 0xaa,
                .stream_id = 7,
                .role = .controller,
                .controller_generation = 3,
            },
        ),
        .initial_metadata = runtime_metadata_wire.InitialMetadataSeed.unsupported,
    };
    source_owned = false;
    var prepared_client_owned = true;
    defer if (prepared_client_owned) prepared.client.deinit();
    defer prepared.attachment.deinit();
    defer prepared.initial_metadata.deinit();
    var evidence: client_external_pump.PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try external_attach_evidence.prepareInPlace(&evidence, &prepared);
    var cleanup: client_external_pump.ExternalPumpCleanupScratch = .{};
    try std.testing.expect(
        client_external_pump.ExternalPumpCleanupScratch.initInPlace(&cleanup),
    );
    var storage: client_external_pump.ExternalPumpStorage = .{};
    var storage_open = false;
    var scratch_to_destroy: ?*client_external_pump.ExternalRxTurnScratch = null;
    defer {
        if (storage_open) _ = storage.teardown(&cleanup);
        if (scratch_to_destroy) |owned_scratch|
            std.testing.allocator.destroy(owned_scratch);
    }
    switch (client_external_pump.ExternalPumpStorage.initInPlace(
        &storage,
        &prepared.client,
        &evidence,
    )) {
        .initialized => {
            prepared_client_owned = false;
            storage_open = true;
        },
        .failed => return error.TestUnexpectedResult,
    }
    try std.testing.expect(
        storage.prepareAdoption(1, &cleanup) == .prepared_adopted,
    );
    try std.testing.expect(storage.commitAdoption() == .adopted);
    try std.testing.expect(
        client_external_pump.testing.clearInitialFence(&storage),
    );
    storage.semantic_state = .{ .active = .{ .host_recovery = .{
        .snapshot_in_flight = .{
            .context = .{ .epoch = 5, .deadline_ns = 30 },
            .recovery_barrier_absolute = 1,
            .expected_token_generation = 9,
        },
    } } };
    const recovery_key = client_pump.RecoveryKey{
        .owner_incarnation = storage.owner_incarnation,
        .origin = .host,
        .recovery_epoch = 5,
        .expected_token_generation = 9,
    };
    try std.testing.expectEqual(
        external_recovery_types.BatchAuthority.recovery_exact,
        storage.preflightBatchAuthority(7, true, recovery_key),
    );
    try std.testing.expectEqual(
        client_pump.RecoveryMarkResult.commit_pending,
        storage.markResyncApplied(7, recovery_key),
    );
    try std.testing.expect(storage.pollHint().immediate);
    const scratch = try createRxScratchForTest();
    scratch_to_destroy = scratch;
    var probe = Apply{};
    const ops = client_external_pump.BufferedRxOps{
        .context = &probe,
        .context_len = @sizeOf(Apply),
        .apply_live_screen = Apply.run,
    };
    const first = pumpRx(
        &storage,
        .{ .readable = true, .writable = false, .now_ns = 2 },
        &ops,
        scratch,
    );
    try std.testing.expectEqual(
        @as(?client_pump.ExternalPumpTerminal, null),
        first.terminal,
    );
    try std.testing.expect(storage.semantic_state.active == .valid);
    try std.testing.expect(!storage.pollHint().immediate);
    try std.testing.expectEqual(@as(usize, 1), first.rx_frames);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    const second = pumpRx(
        &storage,
        .{ .readable = false, .writable = false, .now_ns = 3 },
        &ops,
        scratch,
    );
    try std.testing.expect(second.terminal == null);
    try std.testing.expect(second.inherited_work_ready);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqualStrings("owner", &probe.bytes);

    const host_flags = c.fcntl(fds[0], c.F.GETFL);
    try std.testing.expect(host_flags >= 0);
    const host_nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.fcntl(fds[0], c.F.SETFL, host_flags & ~host_nonblocking),
    );
    var order = ProductRxOrderRecorder{};
    var drained_calls: usize = 0;
    var drained_context = PosixRxContext{
        .test_calls = &drained_calls,
        .test_order = &order,
    };
    var drained_authority =
        client_external_pump.testing.AuthorityReceipt{};
    try std.testing.expect(
        client_external_pump.testing.beginAuthorityReceipt(
            &drained_authority,
        ),
    );
    var drained_authority_active = true;
    defer {
        if (drained_authority_active)
            _ = client_external_pump.testing.endAuthorityReceipt(
                &drained_authority,
            );
    }
    const drained_generation = scratch.turn_generation;
    const drained = pumpRxWithContext(
        &storage,
        .{ .readable = true, .writable = true, .now_ns = 4 },
        &ops,
        scratch,
        &drained_context,
    );
    try std.testing.expect(
        client_external_pump.testing.endAuthorityReceipt(
            &drained_authority,
        ),
    );
    drained_authority_active = false;
    try std.testing.expect(drained.terminal == null);
    try std.testing.expect(drained.authority_clear);
    try std.testing.expect(!drained.immediate_rx);
    try std.testing.expect(drained.read_interest);
    try std.testing.expect(!drained.write_interest);
    try std.testing.expect(!drained.control_ready);
    try std.testing.expectEqual(@as(usize, 0), drained.tx_bytes);
    try std.testing.expectEqual(@as(usize, 0), drained.tx_frames);
    try std.testing.expectEqual(@as(usize, 0), drained.rx_read_bytes);
    try std.testing.expectEqual(@as(usize, 1), drained_calls);
    try order.expect(&.{.recv_would_block});
    try std.testing.expectEqual(
        @as(u8, 4),
        drained_authority.len,
    );
    try std.testing.expectEqual(
        [_]client_external_pump.testing.AuthorityEvent{
            .prepared,
            .validated,
            .aborted,
            .reset,
        },
        drained_authority.events[0..4].*,
    );
    try std.testing.expectEqual(drained_generation + 1, scratch.turn_generation);
    try std.testing.expect(
        client_external_pump.testing.authorityDestinationsPristine(scratch),
    );
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.fcntl(fds[0], c.F.GETFL) & host_nonblocking,
    );
    var peer_after_drained: [1]u8 = undefined;
    const peer_after_drained_count = c.recv(
        fds[1],
        &peer_after_drained,
        peer_after_drained.len,
        posix.MSG.DONTWAIT,
    );
    try std.testing.expectEqual(@as(isize, -1), peer_after_drained_count);
    try std.testing.expectEqual(
        posix.E.AGAIN,
        posix.errno(peer_after_drained_count),
    );

    const second_wire = try framing.encodeFrame(
        std.testing.allocator,
        .{
            .kind = .delta_chunk,
            .stream_id = 7,
            .flags = protocol.Flags.end_stream,
        },
        "again",
    );
    defer std.testing.allocator.free(second_wire);
    try std.testing.expectEqual(
        @as(isize, @intCast(second_wire.len)),
        c.send(fds[1], second_wire.ptr, second_wire.len, 0),
    );
    const no_read = pumpRx(
        &storage,
        .{ .readable = false, .writable = true, .now_ns = 5 },
        &ops,
        scratch,
    );
    try std.testing.expect(no_read.terminal == null);
    try std.testing.expectEqual(@as(usize, 0), no_read.rx_read_bytes);
    try std.testing.expectEqual(@as(usize, 0), no_read.rx_frames);
    var positive_calls: usize = 0;
    order.reset();
    var positive_context = PosixRxContext{
        .test_calls = &positive_calls,
        .test_order = &order,
    };
    var positive_authority =
        client_external_pump.testing.AuthorityReceipt{};
    try std.testing.expect(
        client_external_pump.testing.beginAuthorityReceipt(
            &positive_authority,
        ),
    );
    var positive_authority_active = true;
    defer {
        if (positive_authority_active)
            _ = client_external_pump.testing.endAuthorityReceipt(
                &positive_authority,
            );
    }
    const positive_generation = scratch.turn_generation;
    const read_first = pumpRxWithContext(
        &storage,
        .{ .readable = true, .writable = true, .now_ns = 6 },
        &ops,
        scratch,
        &positive_context,
    );
    try std.testing.expect(
        client_external_pump.testing.endAuthorityReceipt(
            &positive_authority,
        ),
    );
    positive_authority_active = false;
    try std.testing.expect(read_first.terminal == null);
    try std.testing.expectEqual(second_wire.len, read_first.rx_read_bytes);
    try std.testing.expectEqual(@as(usize, 1), read_first.rx_frames);
    try std.testing.expect(!read_first.authority_clear);
    try std.testing.expect(!read_first.write_interest);
    try std.testing.expect(!read_first.control_ready);
    try std.testing.expectEqual(@as(usize, 0), read_first.tx_bytes);
    try std.testing.expectEqual(@as(usize, 0), read_first.tx_frames);
    try std.testing.expectEqual(@as(usize, 2), positive_calls);
    try order.expect(&.{ .recv_bytes, .recv_would_block });
    try std.testing.expectEqual(
        @as(u8, 0),
        positive_authority.len,
    );
    try std.testing.expectEqual(positive_generation + 1, scratch.turn_generation);
    try std.testing.expect(
        client_external_pump.testing.authorityDestinationsPristine(scratch),
    );
    var inbound_probe: [1]u8 = undefined;
    const inbound_after_turn = c.recv(
        fds[0],
        &inbound_probe,
        inbound_probe.len,
        posix.MSG.DONTWAIT,
    );
    try std.testing.expectEqual(@as(isize, -1), inbound_after_turn);
    try std.testing.expectEqual(posix.E.AGAIN, posix.errno(inbound_after_turn));

    const peer_flags = c.fcntl(fds[1], c.F.GETFL);
    try std.testing.expect(peer_flags >= 0);
    const peer_nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.fcntl(fds[1], c.F.SETFL, peer_flags | peer_nonblocking),
    );
    var peer_byte: [1]u8 = undefined;
    const peer_read = c.read(fds[1], &peer_byte, peer_byte.len);
    try std.testing.expectEqual(@as(isize, -1), peer_read);
    try std.testing.expectEqual(posix.E.AGAIN, posix.errno(peer_read));

    order.reset();
    probe.order = &order;
    const consume_second = pumpRx(
        &storage,
        .{ .readable = false, .writable = false, .now_ns = 7 },
        &ops,
        scratch,
    );
    probe.order = null;
    try std.testing.expect(consume_second.terminal == null);
    try std.testing.expect(consume_second.inherited_work_ready);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqualStrings("again", &probe.bytes);
    try order.expect(&.{.apply_live_screen});

    try std.testing.expectEqual(
        @as(isize, 1),
        c.send(fds[1], second_wire.ptr, 1, 0),
    );
    order.reset();
    var partial_calls: usize = 0;
    var partial_context = PosixRxContext{
        .test_calls = &partial_calls,
        .test_order = &order,
    };
    var partial_authority =
        client_external_pump.testing.AuthorityReceipt{};
    try std.testing.expect(
        client_external_pump.testing.beginAuthorityReceipt(
            &partial_authority,
        ),
    );
    var partial_authority_active = true;
    defer {
        if (partial_authority_active)
            _ = client_external_pump.testing.endAuthorityReceipt(
                &partial_authority,
            );
    }
    const partial_generation = scratch.turn_generation;
    const partial = pumpRxWithContext(
        &storage,
        .{ .readable = true, .writable = true, .now_ns = 8 },
        &ops,
        scratch,
        &partial_context,
    );
    try std.testing.expect(partial.terminal == null);
    try std.testing.expect(!partial.authority_clear);
    try std.testing.expect(partial.read_interest);
    try std.testing.expect(!partial.write_interest);
    try std.testing.expect(!partial.control_ready);
    try std.testing.expectEqual(@as(usize, 1), partial.rx_read_bytes);
    try std.testing.expectEqual(@as(usize, 0), partial.rx_frames);
    try std.testing.expectEqual(@as(usize, 0), partial.tx_bytes);
    try std.testing.expectEqual(@as(usize, 0), partial.tx_frames);
    try std.testing.expectEqual(@as(usize, 2), partial_calls);
    try order.expect(&.{ .recv_bytes, .recv_would_block });
    try std.testing.expectEqual(partial_generation + 1, scratch.turn_generation);
    try std.testing.expect(
        client_external_pump.testing.authorityDestinationsPristine(scratch),
    );
    const peer_after_partial = c.recv(
        fds[1],
        &peer_byte,
        peer_byte.len,
        posix.MSG.DONTWAIT,
    );
    try std.testing.expectEqual(@as(isize, -1), peer_after_partial);
    try std.testing.expectEqual(posix.E.AGAIN, posix.errno(peer_after_partial));

    try std.testing.expectEqual(@as(c_int, 0), c.shutdown(fds[1], c.SHUT.WR));
    order.reset();
    var eof_calls: usize = 0;
    var eof_context = PosixRxContext{
        .test_calls = &eof_calls,
        .test_order = &order,
    };
    const eof = pumpRxWithContext(
        &storage,
        .{ .readable = true, .writable = true, .now_ns = 9 },
        &ops,
        scratch,
        &eof_context,
    );
    try std.testing.expectEqual(client_pump.TerminalReason.eof, eof.terminal.?.reason);
    try std.testing.expectEqual(@as(usize, 0), eof.rx_read_bytes);
    try std.testing.expectEqual(@as(usize, 0), eof.rx_frames);
    try std.testing.expect(!eof.authority_clear);
    try std.testing.expect(!eof.write_interest);
    try std.testing.expect(!eof.control_ready);
    try std.testing.expectEqual(@as(usize, 0), eof.tx_bytes);
    try std.testing.expectEqual(@as(usize, 0), eof.tx_frames);
    try std.testing.expectEqual(@as(usize, 1), eof_calls);
    try order.expect(&.{.recv_eof});
    try std.testing.expect(
        client_external_pump.testing.endAuthorityReceipt(
            &partial_authority,
        ),
    );
    partial_authority_active = false;
    try std.testing.expectEqual(@as(u8, 0), partial_authority.len);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqual(
        client_external_pump.TeardownResult.cleaned,
        storage.teardown(&cleanup),
    );
    storage_open = false;
    std.testing.allocator.destroy(scratch);
    scratch_to_destroy = null;
    _ = c.close(fds[1]);
    peer_open = false;
}

test "d2c product owner terminalizes a non-socket descriptor and replays without recv" {
    const Apply = struct {
        calls: usize = 0,

        fn run(
            raw: *anyopaque,
            _: client_external_pump.LiveScreenPayloadView,
        ) client_external_pump.LiveScreenApplyResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .applied;
        }
    };

    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.pipe(&fds),
    );
    defer _ = c.close(fds[1]);
    var source = client_mod.Client{
        .allocator = std.testing.allocator,
        .fd = fds[0],
        .host_id = 2,
        .parser = framing.FrameParser.init(std.testing.allocator),
        .attach_instance_id = 7002,
        .connection_profile = .cli_attach,
        .compatibility_profile = compatibility.profileForMajor(protocol.version_major).?,
        .attachment_capabilities = .{
            .peer_attach_generation = true,
            .negotiated_controller_transfer = true,
        },
    };
    var source_owned = true;
    defer if (source_owned) source.deinit();
    try source.enterExternalMode();

    var prepared = external_attach.Prepared{
        .attach_instance_id = 7002,
        .client = source,
        .attachment = remote_attachment.RemoteAttachment.init(
            std.testing.allocator,
            .{
                .runtime_id = 0xbb,
                .stream_id = 8,
                .role = .controller,
                .controller_generation = 4,
            },
        ),
        .initial_metadata = runtime_metadata_wire.InitialMetadataSeed.unsupported,
    };
    source_owned = false;
    defer prepared.attachment.deinit();
    defer prepared.initial_metadata.deinit();
    var evidence: client_external_pump.PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try external_attach_evidence.prepareInPlace(&evidence, &prepared);
    var storage: client_external_pump.ExternalPumpStorage = .{};
    switch (client_external_pump.ExternalPumpStorage.initInPlace(
        &storage,
        &prepared.client,
        &evidence,
    )) {
        .initialized => {},
        .failed => return error.TestUnexpectedResult,
    }
    var cleanup: client_external_pump.ExternalPumpCleanupScratch = .{};
    try std.testing.expect(
        client_external_pump.ExternalPumpCleanupScratch.initInPlace(&cleanup),
    );
    defer _ = storage.teardown(&cleanup);
    try std.testing.expect(
        storage.prepareAdoption(1, &cleanup) == .prepared_adopted,
    );
    try std.testing.expect(storage.commitAdoption() == .adopted);
    const scratch = try createRxScratchForTest();
    defer std.testing.allocator.destroy(scratch);
    var apply = Apply{};
    const buffered = client_external_pump.BufferedRxOps{
        .context = &apply,
        .context_len = @sizeOf(Apply),
        .apply_live_screen = Apply.run,
    };

    var recv_calls: usize = 0;
    var context = PosixRxContext{ .test_calls = &recv_calls };
    const terminal = pumpRxWithContext(
        &storage,
        .{ .readable = true, .writable = true, .now_ns = 1 },
        &buffered,
        scratch,
        &context,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.socket_error,
        terminal.terminal.?.reason,
    );
    try std.testing.expectEqual(@as(usize, 1), recv_calls);
    try std.testing.expectEqual(@as(usize, 0), terminal.rx_read_bytes);
    try std.testing.expectEqual(@as(usize, 0), terminal.rx_frames);
    try std.testing.expectEqual(@as(usize, 0), apply.calls);
    try std.testing.expect(!terminal.authority_clear);

    const replay = pumpRxWithContext(
        &storage,
        .{ .readable = true, .writable = true, .now_ns = 2 },
        &buffered,
        scratch,
        &context,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        replay.terminal.?.reason,
    );
    try std.testing.expectEqual(@as(usize, 1), recv_calls);
    try std.testing.expectEqual(@as(usize, 0), apply.calls);
    try std.testing.expectEqual(
        client_external_pump.TeardownResult.cleaned,
        storage.teardown(&cleanup),
    );
}
