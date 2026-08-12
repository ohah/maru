//! Generation GUI attachment의 final-address batch capability.
//!
//! Raw Client와 HostAdapter는 이 leaf 밖으로 나오지 않는다. Adapter는 exact ClientSlot identity와
//! committed stream만 봉인하고, RemoteAttachment에는 pointer-free registry token만 전달한다.

const std = @import("std");
const client_mod = @import("client.zig");
const client_poison = @import("client_poison.zig");
const client_slot_mod = @import("client_slot.zig");
const generation_batch_registry = @import("generation_batch_registry.zig");
const terminal_contract = @import("terminal_cleanup_handoff_contract.zig");
const remote_attachment = @import("remote_attachment.zig");

const Lifecycle = enum(u8) { pristine, prepared, live, draining, terminal };

pub const Error = error{
    DestinationOccupied,
    InvalidAdapter,
    InvalidState,
    MovedOrCopied,
};

pub const GenerationBatchAdapter = struct {
    self_addr: usize = 0,
    owner_addr: usize = 0,
    owner_size: usize = 0,
    slot_addr: usize = 0,
    identity: client_slot_mod.ClientSlot.GenerationBatchAdapterIdentity = undefined,
    stream_id: u64 = 0,
    owner_thread_id: std.Thread.Id = 0,
    lifecycle: Lifecycle = .pristine,

    pub fn initPreparedInPlace(
        out: *GenerationBatchAdapter,
        slot: *client_slot_mod.ClientSlot,
        owner_addr: usize,
        owner_size: usize,
        stream_id: u64,
    ) Error!void {
        if (out.self_addr != 0 or out.lifecycle != .pristine)
            return error.DestinationOccupied;
        if (owner_addr == 0 or owner_size == 0 or stream_id == 0)
            return error.InvalidAdapter;
        const owner_end = std.math.add(usize, owner_addr, owner_size) catch
            return error.InvalidAdapter;
        const out_addr = @intFromPtr(out);
        const out_end = std.math.add(usize, out_addr, @sizeOf(GenerationBatchAdapter)) catch
            return error.InvalidAdapter;
        if (out_addr < owner_addr or out_end > owner_end)
            return error.InvalidAdapter;
        const identity = slot.generationBatchAdapterIdentity() catch
            return error.MovedOrCopied;
        out.* = .{
            .self_addr = out_addr,
            .owner_addr = owner_addr,
            .owner_size = owner_size,
            .slot_addr = @intFromPtr(slot),
            .identity = identity,
            .stream_id = stream_id,
            .owner_thread_id = std.Thread.getCurrentId(),
            .lifecycle = .prepared,
        };
    }

    /// Attachment binding commit 뒤 호출되는 무실패 publication suffix다.
    pub fn activateCommitted(self: *GenerationBatchAdapter) Error!void {
        if (self.borrowSlot(.prepared) == null)
            return error.MovedOrCopied;
        self.lifecycle = .live;
    }

    pub fn abortPrepared(self: *GenerationBatchAdapter) void {
        if (self.borrowSlot(.prepared) == null)
            @panic("invalid prepared generation batch adapter rollback");
        self.terminalizeUnchecked();
    }

    pub fn preflightDraining(self: *GenerationBatchAdapter) Error!void {
        if (self.borrowSlot(.live) == null) return error.MovedOrCopied;
    }

    /// Canonical attachment drop이 preflight를 마친 직후 실행하는 callback-free publication이다.
    pub fn commitDraining(self: *GenerationBatchAdapter) void {
        if (self.borrowSlot(.live) == null)
            @panic("generation batch adapter changed after drain preflight");
        self.lifecycle = .draining;
    }

    pub fn finishDraining(self: *GenerationBatchAdapter) void {
        if (self.borrowSlot(.draining) == null)
            @panic("invalid generation batch adapter drain completion");
        self.terminalizeUnchecked();
    }

    /// 이동 가능한 payload의 ordered view를 pointer-free scratch로 바꾼 뒤 canonical registry가
    /// 모든 row를 다시 검증하게 한다. 실패 전에는 adapter와 attachment source를 바꾸지 않는다.
    pub fn preflightTerminalCleanup(
        self: *GenerationBatchAdapter,
        view: remote_attachment.TerminalCleanupView,
        out: *generation_batch_registry.TerminalCleanupHandoff,
    ) Error!void {
        const slot = self.borrowSlot(.draining) orelse return error.MovedOrCopied;
        if (view.token_count == 0 or view.token_count > generation_batch_registry.max_entries)
            return error.InvalidState;
        var ordered = terminal_contract.OrderedTokenHasher.init(view.token_count);
        var surviving: u32 = 0;
        var quarantined: u32 = 0;
        var accounting_bytes: u64 = 0;
        var index: u32 = 0;
        if (view.failed) |lease| {
            const token = switch (lease) {
                .generation => |token| token,
                .untracked, .charged => return error.InvalidState,
            };
            const summary = slot.preflightTerminalAttachmentBatch(token) catch return error.InvalidState;
            ordered.add(summary.projection) catch return error.InvalidState;
            switch (summary.kind) {
                .surviving_descriptor => surviving += 1,
                .quarantined_no_free => quarantined += 1,
            }
            accounting_bytes = std.math.add(u64, accounting_bytes, summary.accounting_bytes) catch
                return error.InvalidState;
            index += 1;
        }
        for (view.pending) |lease| {
            const token = switch (lease) {
                .generation => |token| token,
                .untracked, .charged => return error.InvalidState,
            };
            const summary = slot.preflightTerminalAttachmentBatch(token) catch return error.InvalidState;
            ordered.add(summary.projection) catch return error.InvalidState;
            switch (summary.kind) {
                .surviving_descriptor => surviving += 1,
                .quarantined_no_free => quarantined += 1,
            }
            accounting_bytes = std.math.add(u64, accounting_bytes, summary.accounting_bytes) catch
                return error.InvalidState;
            index += 1;
        }
        if (index != view.token_count) return error.InvalidState;
        const digest = ordered.finish(view.token_count) catch return error.InvalidState;
        slot.prepareTerminalCleanupSummary(
            view.token_count,
            digest,
            surviving,
            quarantined,
            accounting_bytes,
            out,
        ) catch return error.InvalidState;
    }

    pub fn commitTerminalCleanupNoFail(
        self: *GenerationBatchAdapter,
        view: remote_attachment.TerminalCleanupView,
        prepared: *generation_batch_registry.TerminalCleanupHandoff,
    ) void {
        const slot = self.borrowSlot(.draining) orelse
            @panic("terminal cleanup adapter proof was lost");
        slot.beginTerminalCleanupPublicationNoFail(prepared, self.stream_id);
        var index: u32 = 0;
        if (view.failed) |lease| {
            const token = switch (lease) {
                .generation => |token| token,
                .untracked, .charged => @panic("external lease entered generation terminal cleanup"),
            };
            const kind = slot.terminalAttachmentBatchKind(token) catch
                @panic("terminal cleanup row kind drifted");
            slot.publishTerminalAttachmentBatchNoFail(token, kind);
            index += 1;
        }
        for (view.pending) |lease| {
            const token = switch (lease) {
                .generation => |token| token,
                .untracked, .charged => @panic("external lease entered generation terminal cleanup"),
            };
            const kind = slot.terminalAttachmentBatchKind(token) catch
                @panic("terminal cleanup row kind drifted");
            slot.publishTerminalAttachmentBatchNoFail(token, kind);
            index += 1;
        }
        if (index != view.token_count) @panic("terminal cleanup ordered view drifted");
    }

    pub fn poisonTerminalCleanupNoFail(self: *GenerationBatchAdapter) void {
        const slot = self.borrowSlot(.draining) orelse
            @panic("terminal cleanup poison lost its canonical adapter");
        slot.poisonAttachmentConnection(.attachment_cleanup_failed) catch
            @panic("terminal cleanup poison lost its ClientSlot");
    }

    pub fn interface(self: *GenerationBatchAdapter) remote_attachment.AttachmentTransport {
        if (self.borrowSlot(.live) == null)
            @panic("invalid generation batch adapter interface");
        return .{
            .context = self,
            .read_batch = readBatch,
            .borrow_generation = borrowGeneration,
            .release_generation = releaseGeneration,
            .drop_stream = rejectPayloadDrop,
            .fail_closed = failClosed,
        };
    }

    fn borrowSlot(self: *GenerationBatchAdapter, expected: Lifecycle) ?*client_slot_mod.ClientSlot {
        if (self.self_addr != @intFromPtr(self) or self.lifecycle != expected or
            self.owner_addr == 0 or self.owner_size == 0 or self.slot_addr == 0 or
            self.stream_id == 0 or self.owner_thread_id != std.Thread.getCurrentId())
            return null;
        const owner_end = std.math.add(usize, self.owner_addr, self.owner_size) catch return null;
        const self_end = std.math.add(usize, @intFromPtr(self), @sizeOf(GenerationBatchAdapter)) catch
            return null;
        if (@intFromPtr(self) < self.owner_addr or self_end > owner_end) return null;
        const slot: *client_slot_mod.ClientSlot = @ptrFromInt(self.slot_addr);
        if (!slot.matchesGenerationBatchAdapterIdentity(self.identity)) return null;
        return slot;
    }

    fn borrowLiveOrDraining(self: *GenerationBatchAdapter) ?*client_slot_mod.ClientSlot {
        return self.borrowSlot(.live) orelse self.borrowSlot(.draining);
    }

    fn terminalizeUnchecked(self: *GenerationBatchAdapter) void {
        self.lifecycle = .terminal;
        self.slot_addr = 0;
        self.owner_addr = 0;
        self.owner_size = 0;
    }

    fn readBatch(
        context: *anyopaque,
        stream_id: u64,
    ) client_mod.ClientError!?remote_attachment.AttachmentBatchLease {
        const self: *GenerationBatchAdapter = @ptrCast(@alignCast(context));
        const slot = self.borrowSlot(.live) orelse return error.ProtocolError;
        if (stream_id != self.stream_id) {
            slot.poisonAttachmentConnection(.local_invariant_violation) catch {};
            return error.ProtocolError;
        }
        const result = slot.readAttachmentBatch(stream_id) catch |err| switch (err) {
            error.CapacityExhausted => return error.OutOfMemory,
            error.AdminBusy => return error.AdminBusy,
            error.OutOfMemory => return error.OutOfMemory,
            error.ConnectionClosed => return error.ConnectionClosed,
            error.ProtocolError => return error.ProtocolError,
            else => {
                slot.poisonAttachmentConnection(.local_invariant_violation) catch {};
                return error.ProtocolError;
            },
        };
        return switch (result) {
            .idle => null,
            .terminal => error.ConnectionClosed,
            .committed => |token| .{ .generation = token },
        };
    }

    fn borrowGeneration(
        context: *anyopaque,
        token: generation_batch_registry.Token,
    ) remote_attachment.LeaseError!remote_attachment.AttachmentBatchView {
        const self: *GenerationBatchAdapter = @ptrCast(@alignCast(context));
        const slot = self.borrowLiveOrDraining() orelse return error.LedgerInvariant;
        if (token.stream_id != self.stream_id) return error.LedgerInvariant;
        const view = slot.borrowAttachmentBatch(token) catch return error.LedgerInvariant;
        return .{
            .is_snapshot = view.is_snapshot,
            .stream_id = view.stream_id,
            .recovery_key = null,
            .bytes = view.bytes,
        };
    }

    fn releaseGeneration(
        context: *anyopaque,
        token: generation_batch_registry.Token,
    ) remote_attachment.LeaseError!remote_attachment.GenerationReleaseResult {
        const self: *GenerationBatchAdapter = @ptrCast(@alignCast(context));
        const slot = self.borrowLiveOrDraining() orelse
            @panic("generation batch release lost its canonical adapter");
        if (token.stream_id != self.stream_id)
            @panic("generation batch release crossed attachment streams");
        return slot.releaseAttachmentBatchResult(token) catch
            @panic("generation batch strict release failed");
    }

    fn failClosed(context: *anyopaque, reason: client_poison.ConnectionReason) void {
        const self: *GenerationBatchAdapter = @ptrCast(@alignCast(context));
        const slot = self.borrowLiveOrDraining() orelse return;
        slot.poisonAttachmentConnection(reason) catch {};
    }

    fn rejectPayloadDrop(_: *anyopaque, _: u64) void {
        @panic("generation payload attempted to bypass canonical attachment drop");
    }
};

comptime {
    if (@typeInfo(generation_batch_registry.Token).@"struct".fields.len == 0)
        @compileError("generation batch token unexpectedly lost its sealed identity");
}

test "CR3a-2b2 batch adapter rejects copy foreign slot and wrong thread before mutation" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    const framing = @import("framing.zig");
    const Owner = struct {
        adapter: GenerationBatchAdapter = .{},
    };
    var first_client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xA201,
        .parser = framing.FrameParser.init(allocator),
    };
    var first_slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&first_slot, allocator, &first_client, 0xA201);
    defer first_slot.deinit();
    var second_client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xA202,
        .parser = framing.FrameParser.init(allocator),
    };
    var second_slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&second_slot, allocator, &second_client, 0xA202);
    defer second_slot.deinit();

    var owner: Owner = .{};
    try GenerationBatchAdapter.initPreparedInPlace(
        &owner.adapter,
        &first_slot,
        @intFromPtr(&owner),
        @sizeOf(Owner),
        7,
    );
    try owner.adapter.activateCommitted();

    var copied = owner.adapter;
    try std.testing.expectError(error.MovedOrCopied, copied.preflightDraining());
    const original_slot_addr = owner.adapter.slot_addr;
    owner.adapter.slot_addr = @intFromPtr(&second_slot);
    try std.testing.expectError(error.MovedOrCopied, owner.adapter.preflightDraining());
    owner.adapter.slot_addr = original_slot_addr;

    const ThreadProbe = struct {
        fn run(target: *GenerationBatchAdapter, rejected: *bool) void {
            target.preflightDraining() catch {
                rejected.* = true;
                return;
            };
        }
    };
    var wrong_thread_rejected = false;
    const thread = try std.Thread.spawn(.{}, ThreadProbe.run, .{ &owner.adapter, &wrong_thread_rejected });
    thread.join();
    try std.testing.expect(wrong_thread_rejected);
    try owner.adapter.preflightDraining();
    owner.adapter.commitDraining();
    owner.adapter.finishDraining();
}
