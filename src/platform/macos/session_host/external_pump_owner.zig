//! Product-side owner boundary for the external session pump.
//!
//! d2c owns the sole product POSIX RX adapter. Higher layers supply only semantic buffered
//! callbacks; they cannot replace the transport callback or bypass the pump transaction.

const client_external_pump = @import("client_external_pump.zig");
const client_external_rx_read = @import("client_external_rx_read.zig");
const client_pump = @import("client_pump.zig");
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

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
const external_inbox_ledger = @import("external_inbox_ledger.zig");
const external_rx_intent = @import("external_rx_intent.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const remote_attachment = @import("remote_attachment.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");

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
            _: external_inbox_ledger.PayloadView,
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
        try std.testing.expectEqual(lower_before, lower_after);
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

test "D3 product socketpair revoke at frame 1 64 and 65 never reaches lower authority" {
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
            view: external_inbox_ledger.PayloadView,
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
        drained_authority.events,
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
            _: external_inbox_ledger.PayloadView,
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
