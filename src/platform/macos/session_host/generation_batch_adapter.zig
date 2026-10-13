//! Generation GUI attachment의 final-address batch capability.
//!
//! Raw Client와 HostAdapter는 이 leaf 밖으로 나오지 않는다. Adapter는 exact ClientSlot identity와
//! committed stream만 봉인하고, RemoteAttachment에는 pointer-free registry token만 전달한다.

const std = @import("std");
const client_mod = @import("client.zig");
const client_poison = @import("client_poison.zig");
const client_slot_mod = @import("client_slot.zig");
const incident_publication_contract = @import("maru").observability.incident_publication_contract;
const generation_batch_registry = @import("generation_batch_registry.zig");
const terminal_contract = @import("terminal_cleanup_handoff_contract.zig");
const remote_attachment = @import("remote_attachment.zig");
const fork_fd_fence = @import("fork_fd_fence.zig");
const catchup_barrier_contract = @import("catchup_barrier_contract.zig");
const client_deadline = @import("client_deadline.zig");

const Lifecycle = enum(u8) { pristine, prepared, live, draining, terminal };

const ReadPumpPoisonBinding = struct {
    adapter_addr: usize = 0,
    capture_addr: usize = 0,
};

threadlocal var read_pump_poison_binding: ReadPumpPoisonBinding = .{};

fn rangesOverlapTyped(a: anytype, b: anytype) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    const a_end = std.math.add(usize, a_start, @sizeOf(@TypeOf(a.*))) catch return true;
    const b_end = std.math.add(usize, b_start, @sizeOf(@TypeOf(b.*))) catch return true;
    return a_start < b_end and b_start < a_end;
}

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

    pub fn armReadPumpPoisonCapture(
        self: *GenerationBatchAdapter,
        capture: *incident_publication_contract.ReadPumpPoisonCapture,
        timestamp_ns: i128,
        controller_generation: u64,
    ) Error!void {
        const slot = self.borrowSlot(.live) orelse return error.MovedOrCopied;
        if (!std.meta.eql(read_pump_poison_binding, ReadPumpPoisonBinding{}) or
            timestamp_ns < 0 or controller_generation == 0 or
            rangesOverlapTyped(capture, self) or rangesOverlapTyped(capture, slot) or
            rangesOverlapTyped(capture, slot.current) or
            rangesOverlapTyped(capture, &slot.current.client) or
            !std.meta.eql(capture.*, incident_publication_contract.ReadPumpPoisonCapture{}))
            return error.InvalidState;
        capture.* = .{
            .self_addr = @intFromPtr(capture),
            .batch_adapter_addr = @intFromPtr(self),
            .slot_addr = @intFromPtr(slot),
            .client_addr = @intFromPtr(&slot.current.client),
            .timestamp_ns = timestamp_ns,
            .controller_generation = controller_generation,
            .source_site_raw = @intFromEnum(@import("maru").observability.connection_incident.SourceSite.client_read),
            .lifecycle_raw = @intFromEnum(incident_publication_contract.ReadPumpPoisonCaptureLifecycle.armed),
        };
        read_pump_poison_binding = .{
            .adapter_addr = @intFromPtr(self),
            .capture_addr = @intFromPtr(capture),
        };
        if (!slot.beginReadPumpPoisonCapture(capture)) {
            read_pump_poison_binding = .{};
            capture.* = .{};
            return error.InvalidState;
        }
    }

    pub fn disarmReadPumpPoisonCapture(
        self: *GenerationBatchAdapter,
        capture: *incident_publication_contract.ReadPumpPoisonCapture,
    ) void {
        if (read_pump_poison_binding.adapter_addr != @intFromPtr(self) or
            read_pump_poison_binding.capture_addr != @intFromPtr(capture) or
            capture.self_addr != @intFromPtr(capture) or
            capture.batch_adapter_addr != @intFromPtr(self) or
            (capture.lifecycle_raw != @intFromEnum(incident_publication_contract.ReadPumpPoisonCaptureLifecycle.armed) and
                capture.lifecycle_raw != @intFromEnum(incident_publication_contract.ReadPumpPoisonCaptureLifecycle.captured)))
            @panic("read pump poison binding authority drifted");
        const slot = self.borrowLiveOrDraining() orelse
            @panic("read pump poison slot authority lost");
        slot.endReadPumpPoisonCapture(capture);
        read_pump_poison_binding = .{};
        capture.lifecycle_raw = @intFromEnum(incident_publication_contract.ReadPumpPoisonCaptureLifecycle.finalized);
    }

    pub fn initPreparedInPlace(
        out: *GenerationBatchAdapter,
        slot: *client_slot_mod.ClientSlot,
        owner_addr: usize,
        owner_size: usize,
        stream_id: u64,
    ) Error!void {
        if (stream_id == 0) return error.InvalidAdapter;
        try initReservedInPlace(out, slot, owner_addr, owner_size);
        try out.bindPreparedStream(stream_id);
    }

    /// attach RPC 전에 final-address storage와 ClientSlot identity를 먼저 고정한다. stream은 peer 응답에서만
    /// 알 수 있으므로 이 단계에서는 0으로 남기며, wire 이후 새 권위를 할당하지 않게 하는 것이 목적이다.
    pub fn initReservedInPlace(
        out: *GenerationBatchAdapter,
        slot: *client_slot_mod.ClientSlot,
        owner_addr: usize,
        owner_size: usize,
    ) Error!void {
        if (out.self_addr != 0 or out.lifecycle != .pristine)
            return error.DestinationOccupied;
        if (owner_addr == 0 or owner_size == 0)
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
            .stream_id = 0,
            .owner_thread_id = std.Thread.getCurrentId(),
            .lifecycle = .prepared,
        };
    }

    /// accepted attach가 준 exact stream을 prepared storage에 한 번만 결속한다. allocation과 callback은 없다.
    pub fn bindPreparedStream(self: *GenerationBatchAdapter, stream_id: u64) Error!void {
        try self.preflightPreparedStream(stream_id);
        self.bindPreparedStreamNoFail(stream_id);
    }

    /// accepted stream publication 전에 final-address reserved owner를 read-only로 검증한다.
    pub fn preflightPreparedStream(self: *GenerationBatchAdapter, stream_id: u64) Error!void {
        if (self.borrowSlot(.prepared) == null or self.stream_id != 0 or stream_id == 0)
            return error.InvalidState;
    }

    /// binding row와 lease commit이 성공한 뒤 실행하는 store-only suffix다.
    pub fn bindPreparedStreamNoFail(self: *GenerationBatchAdapter, stream_id: u64) void {
        if (self.borrowSlot(.prepared) == null or self.stream_id != 0 or stream_id == 0)
            @panic("prepared generation batch stream changed after preflight");
        self.stream_id = stream_id;
    }

    /// Attachment binding commit 뒤 호출되는 무실패 publication suffix다.
    pub fn activateCommitted(self: *GenerationBatchAdapter) Error!void {
        if (self.borrowSlot(.prepared) == null or self.stream_id == 0)
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

    pub fn readCatchupBarrierPlanUntil(
        self: *GenerationBatchAdapter,
        expected: catchup_barrier_contract.CatchupIdentity,
        deadline: client_deadline.AbsoluteDeadline,
    ) client_mod.DeadlineClientError!client_mod.Client.CatchupBarrierPlan {
        const slot = self.borrowSlot(.live) orelse return error.ProtocolError;
        return slot.readAttachmentCatchupBarrierPlanUntil(self.stream_id, expected, deadline);
    }

    pub fn requestCatchupUntil(
        self: *GenerationBatchAdapter,
        runtime_id: u128,
        request_nonce: u128,
        deadline: client_deadline.AbsoluteDeadline,
    ) client_mod.DeadlineClientError!catchup_barrier_contract.CatchupIdentity {
        const slot = self.borrowSlot(.live) orelse return error.ProtocolError;
        return slot.requestAttachmentCatchupUntil(
            self.stream_id,
            runtime_id,
            request_nonce,
            deadline,
        );
    }

    pub fn callControllerUntil(
        self: *GenerationBatchAdapter,
        method: []const u8,
        params_json: []const u8,
        deadline: client_deadline.AbsoluteDeadline,
    ) client_mod.DeadlineClientError![]u8 {
        const slot = self.borrowSlot(.live) orelse return error.ProtocolError;
        const connection_generation = slot.connectionGeneration();
        return slot.callCurrentUntil(
            connection_generation,
            method,
            params_json,
            deadline,
        );
    }

    pub fn refreshControllerEvidence(self: *GenerationBatchAdapter) client_mod.ClientError!void {
        const slot = self.borrowSlot(.live) orelse return error.ProtocolError;
        const connection_generation = slot.connectionGeneration();
        return slot.ingestCurrentReadableEvidence(connection_generation);
    }

    pub fn terminalConnectionReason(
        self: *GenerationBatchAdapter,
    ) ?client_poison.ConnectionReason {
        const slot = self.borrowSlot(.live) orelse return null;
        return slot.attachmentConnectionFailureReason();
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
            .image_shm_negotiated = imageShmNegotiated,
            .resolve_image = resolveImage,
            .prepare_image_apply = prepareImageApply,
            .open_image_stream = openImageStream,
            .sweep_image_segments = sweepImageSegments,
        };
    }

    fn borrowSlot(self: *GenerationBatchAdapter, expected: Lifecycle) ?*client_slot_mod.ClientSlot {
        if (self.self_addr != @intFromPtr(self) or self.lifecycle != expected or
            self.owner_addr == 0 or self.owner_size == 0 or self.slot_addr == 0 or
            (expected != .prepared and self.stream_id == 0) or
            self.owner_thread_id != std.Thread.getCurrentId())
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

    fn imageShmNegotiated(context: *anyopaque) bool {
        const self: *GenerationBatchAdapter = @ptrCast(@alignCast(context));
        const slot = self.borrowSlot(.live) orelse return false;
        return slot.attachmentImageShmNegotiated();
    }

    /// 적용 중인 배치의 `image_ref` 를 이 adapter 의 stream 으로만 해석한다 — 다른 stream 이면 「세그먼트 없음」.
    fn resolveImage(
        context: *anyopaque,
        stream_id: u64,
        ref: remote_attachment.ImageRef,
    ) error{OutOfMemory}!?[]const u8 {
        const self: *GenerationBatchAdapter = @ptrCast(@alignCast(context));
        const slot = self.borrowSlot(.live) orelse return null;
        if (stream_id != self.stream_id) return null;
        return slot.resolveAttachmentImage(stream_id, ref);
    }

    fn prepareImageApply(context: *anyopaque, wait: fork_fd_fence.ReceiveWait) bool {
        const self: *GenerationBatchAdapter = @ptrCast(@alignCast(context));
        const slot = self.borrowSlot(.live) orelse return false;
        return slot.pumpAttachmentImageChannel(wait);
    }

    /// 자기 stream 만 연다 — live 가 아니거나 다른 stream 이면 아무것도 하지 않는다.
    fn openImageStream(context: *anyopaque, stream_id: u64) void {
        const self: *GenerationBatchAdapter = @ptrCast(@alignCast(context));
        const slot = self.borrowSlot(.live) orelse return;
        if (stream_id != self.stream_id) return;
        slot.openAttachmentImageStream(stream_id);
    }

    fn sweepImageSegments(context: *anyopaque, stream_id: u64, hwm: u64) void {
        const self: *GenerationBatchAdapter = @ptrCast(@alignCast(context));
        const slot = self.borrowSlot(.live) orelse return;
        if (stream_id != self.stream_id) return;
        slot.sweepAttachmentImageSegments(stream_id, hwm);
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

/// slot 안 Client 의 채널 host 끝에 세그먼트 메시지 하나를 공유 메모리 fd 와 함께 보낸다(이미지 채널 §3.3).
fn sendTestSegment(host: std.c.fd_t, segment_id: u64, stream_id: u64, pixels: []const u8) !void {
    const c = std.c;
    const created = (try @import("image_segment.zig").create(pixels)).?;
    defer _ = c.close(created.fd);
    const bytes = try @import("image_channel_wire.zig").encodeSegment(.{
        .segment_id = segment_id,
        .stream_id = stream_id,
        .image_id = 3,
        .generation = 4,
        .byte_len = @intCast(pixels.len),
    });
    var control: [32]u8 align(@alignOf(c.cmsghdr)) = @splat(0);
    const header: c.cmsghdr = .{ .len = @intCast(@sizeOf(c.cmsghdr) + @sizeOf(c.fd_t)), .level = c.SOL.SOCKET, .type = c.SCM.RIGHTS };
    @memcpy(control[0..@sizeOf(c.cmsghdr)], std.mem.asBytes(&header));
    @memcpy(control[@sizeOf(c.cmsghdr)..][0..@sizeOf(c.fd_t)], std.mem.asBytes(&created.fd));
    var iov = [_]std.posix.iovec_const{.{ .base = &bytes, .len = bytes.len }};
    const msg: c.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = @intCast(std.mem.alignForward(usize, @sizeOf(c.cmsghdr) + @sizeOf(c.fd_t), @sizeOf(u32))),
        .flags = 0,
    };
    if (c.sendmsg(host, &msg, 0) != bytes.len) return error.TestUnexpectedResult;
}

test "image channel adapter: the generation adapter reads negotiation and resolves only through its live slot and its own stream" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    const c = std.c;
    const Owner = struct { adapter: GenerationBatchAdapter = .{} };
    var channel: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &channel) != 0) return error.TestUnexpectedResult;
    defer _ = c.close(channel[1]);
    for (channel) |fd| _ = c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x1C3B,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x1C3B);
    defer slot.deinit();
    var owner: Owner = .{};
    try GenerationBatchAdapter.initPreparedInPlace(&owner.adapter, &slot, @intFromPtr(&owner), @sizeOf(Owner), 7);
    try owner.adapter.activateCommitted();
    const transport = owner.adapter.interface();
    const ref: remote_attachment.ImageRef = .{ .image_id = 3, .generation = 4, .width = 1, .height = 1, .bpp = 4, .segment_id = 1, .byte_len = 4 };

    // 협상하지 않은 연결 — 적용 자리는 `.unnegotiated` 를 넘긴다.
    try std.testing.expect(!transport.image_shm_negotiated(transport.context));
    // 채널을 묶고(표는 Client 소멸이 푼다) 세그먼트 하나를 받는다.
    const live = &slot.current.client;
    live.image_channel = .{ .fd = channel[0], .state = .bound };
    const table = try allocator.create(@import("client_image_segments.zig").Table);
    table.* = .{};
    live.image_segments = table;
    try std.testing.expect(transport.image_shm_negotiated(transport.context));
    try sendTestSegment(channel[1], 1, 7, &.{ 9, 8, 7, 6 });
    _ = live.pumpImageChannel(.try_lock);
    try std.testing.expectEqual(@as(usize, 1), table.len);

    // 다른 stream(8)의 실제 항목 — 표 대조와 따로, adapter 가 자기 stream 이 아니면 slot 에 닿지 않는다. 이번에는 유지보수
    // tick 의 길(`currentPumpImageChannel`)로 받는다.
    try sendTestSegment(channel[1], 2, 8, &.{ 1, 1, 1, 1 });
    // tick 의 길은 fork 울타리의 수신 잠금을 기다리지 않는다(§7) — 다른 스레드가 쥔 동안은 비우지 않고 다음 tick 에 받는다.
    const FenceHolder = struct {
        held: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        fn run(holder: *@This()) void {
            fork_fd_fence.lockReceive();
            holder.held.store(true, .release);
            // 기다리는 쪽이 잘못 기다려도 판정자가 멈추지 않게 2 초 상한.
            var waited_ms: usize = 0;
            while (!holder.release.load(.acquire) and waited_ms < 2000) : (waited_ms += 1)
                std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
            fork_fd_fence.unlockReceive();
        }
    };
    var fence_holder: FenceHolder = .{};
    const holder_thread = try std.Thread.spawn(.{}, FenceHolder.run, .{&fence_holder});
    while (!fence_holder.held.load(.acquire)) std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    const pumped_while_held = slot.currentPumpImageChannel(slot.connectionGeneration());
    const len_while_held = table.len;
    fence_holder.release.store(true, .release);
    holder_thread.join();
    try std.testing.expect(!(try pumped_while_held));
    try std.testing.expectEqual(@as(usize, 1), len_while_held);
    try std.testing.expect(try slot.currentPumpImageChannel(slot.connectionGeneration()));
    try std.testing.expectEqual(@as(usize, 2), table.len);
    var other = ref;
    other.segment_id = 2;
    try std.testing.expect((try transport.resolve_image(transport.context, 8, other)) == null);
    try std.testing.expectEqual(@as(usize, 2), table.len);
    // 다른 attachment 연산이 slot 을 쥐고 있으면 해석하지 않는다 — 같은 스레드의 다른 종류도, 다른 스레드의 첫 snapshot 도.
    const own_thread = slot.operation_owner_thread_incarnation;
    const Busy = struct { kind: client_slot_mod.StreamOperationKind, thread: u64 };
    for ([_]Busy{ .{ .kind = .control, .thread = own_thread }, .{ .kind = .initial_snapshot, .thread = own_thread +% 1 } }) |busy_case| {
        slot.current.active_operation_generation = 1;
        slot.current.active_operation_kind = busy_case.kind;
        slot.current.active_operation_owner_thread_incarnation = busy_case.thread;
        const refused_before = @import("maru").image_reconciliation.snapshot();
        const busy_prepare = transport.prepare_image_apply(transport.context, .try_lock);
        const busy = transport.resolve_image(transport.context, 7, ref);
        // 빠진 둘(준비·해석)은 대조 계수의 흐름 칸에 남는다.
        const refused = @import("maru").image_reconciliation.snapshot().delta(refused_before).channel_refused;
        slot.current.active_operation_generation = 0;
        slot.current.active_operation_kind = .none;
        slot.current.active_operation_owner_thread_incarnation = 0;
        try std.testing.expect((try busy) == null);
        try std.testing.expect(!busy_prepare);
        try std.testing.expectEqual(@as(u64, 2), refused);
        try std.testing.expectEqual(@as(usize, 2), table.len);
    }
    // 첫 snapshot 은 그 owner 가 `.initial_snapshot` permit 을 쥔 채 적용된다 — 그 permit 은 해석을 막지 않는다(실제 permit).
    var binding: @import("generation_attachment_contract.zig").PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x44);
    defer slot.abortAttachmentBinding(&binding, reservation) catch
        @panic("image channel adapter binding cleanup drifted");
    const permit = try slot.prepareInitialSnapshotPermit(0x1000, 9, reservation.identity);
    const prepared_during_snapshot = transport.prepare_image_apply(transport.context, .try_lock);
    const during_snapshot = transport.resolve_image(transport.context, 7, ref);
    try slot.abortInitialSnapshotPermit(permit);
    try std.testing.expect(prepared_during_snapshot);
    const pixels = (try during_snapshot) orelse return error.TestUnexpectedResult;
    defer @import("client_image_segments.zig").unmapPixels(pixels);
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 6 }, pixels);
    try std.testing.expectEqual(@as(usize, 1), table.len);

    // stream 열기·hwm 정리도 자기 stream 만 — 다른 stream(8)은 열지도 정리하지도 않는다.
    transport.open_image_stream(transport.context, 8);
    try std.testing.expect(std.mem.indexOfScalar(u64, table.liveStreams(), 8) == null);
    transport.sweep_image_segments(transport.context, 8, 2);
    try std.testing.expectEqual(@as(usize, 1), table.len);
    transport.open_image_stream(transport.context, 7);
    try std.testing.expect(std.mem.indexOfScalar(u64, table.liveStreams(), 7) != null);
    // 다른 연산이 slot 을 쥐면 정리하지 않는다.
    try sendTestSegment(channel[1], 3, 7, &.{ 2, 2, 2, 2 });
    try std.testing.expect(transport.prepare_image_apply(transport.context, .try_lock));
    try std.testing.expectEqual(@as(usize, 2), table.len);
    slot.current.active_operation_generation = 1;
    slot.current.active_operation_kind = .control;
    slot.current.active_operation_owner_thread_incarnation = own_thread;
    transport.sweep_image_segments(transport.context, 7, 3);
    slot.current.active_operation_generation = 0;
    slot.current.active_operation_kind = .none;
    slot.current.active_operation_owner_thread_incarnation = 0;
    try std.testing.expectEqual(@as(usize, 2), table.len);
    transport.sweep_image_segments(transport.context, 7, 3);
    try std.testing.expectEqual(@as(usize, 1), table.len);

    // live 가 아닌 adapter 는 slot 에 닿지 않는다.
    try owner.adapter.preflightDraining();
    owner.adapter.commitDraining();
    try std.testing.expect(!transport.image_shm_negotiated(transport.context));
    try std.testing.expect((try transport.resolve_image(transport.context, 7, ref)) == null);
    owner.adapter.finishDraining();
}

test "CR3a-2e batch adapter는 stream 없이 final-address reserved 상태를 준비한다" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    const Owner = struct { adapter: GenerationBatchAdapter = .{} };
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2E01,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2E01);
    defer slot.deinit();
    var owner: Owner = .{};
    try GenerationBatchAdapter.initReservedInPlace(
        &owner.adapter,
        &slot,
        @intFromPtr(&owner),
        @sizeOf(Owner),
    );
    try std.testing.expectEqual(@as(u64, 0), owner.adapter.stream_id);
    try std.testing.expectError(error.MovedOrCopied, owner.adapter.preflightDraining());
    owner.adapter.abortPrepared();
}

test "CR3a-2e batch adapter는 accepted stream을 한 번만 결속한다" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    const Owner = struct { adapter: GenerationBatchAdapter = .{} };
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2E02,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2E02);
    defer slot.deinit();
    var owner: Owner = .{};
    try GenerationBatchAdapter.initReservedInPlace(
        &owner.adapter,
        &slot,
        @intFromPtr(&owner),
        @sizeOf(Owner),
    );
    try owner.adapter.bindPreparedStream(17);
    try std.testing.expectError(error.InvalidState, owner.adapter.bindPreparedStream(18));
    try owner.adapter.activateCommitted();
    try owner.adapter.preflightDraining();
    owner.adapter.commitDraining();
    owner.adapter.finishDraining();
}

test "CR3a-2e batch adapter는 zero stream 결속을 mutation 없이 거부한다" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    const Owner = struct { adapter: GenerationBatchAdapter = .{} };
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2E03,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2E03);
    defer slot.deinit();
    var owner: Owner = .{};
    try GenerationBatchAdapter.initReservedInPlace(&owner.adapter, &slot, @intFromPtr(&owner), @sizeOf(Owner));
    try std.testing.expectError(error.InvalidState, owner.adapter.bindPreparedStream(0));
    try std.testing.expectEqual(@as(u64, 0), owner.adapter.stream_id);
    owner.adapter.abortPrepared();
}

test "CR3a-2e batch adapter는 copied reserved owner와 abort replay를 거부한다" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    const Owner = struct { adapter: GenerationBatchAdapter = .{} };
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2E04,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2E04);
    defer slot.deinit();
    var owner: Owner = .{};
    try GenerationBatchAdapter.initReservedInPlace(&owner.adapter, &slot, @intFromPtr(&owner), @sizeOf(Owner));
    var copied = owner.adapter;
    try std.testing.expectError(error.InvalidState, copied.bindPreparedStream(9));
    owner.adapter.abortPrepared();
    try std.testing.expectError(error.InvalidState, owner.adapter.bindPreparedStream(9));
}
