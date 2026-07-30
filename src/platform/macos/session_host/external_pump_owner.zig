//! Product-side owner boundary for the external session pump.
//!
//! d2c owns the sole product POSIX RX adapter. Higher layers supply only semantic buffered
//! callbacks; they cannot replace the transport callback or bypass the pump transaction.

const client_external_pump = @import("client_external_pump.zig");
const client_external_rx_read = @import("client_external_rx_read.zig");
const client_pump = @import("client_pump.zig");
const std = @import("std");
const c = std.c;
const posix = std.posix;

const PosixRxContext = struct {
    marker: u8 = 0x52,
    test_calls: ?*usize = null,
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
    if (context.test_calls) |calls| calls.* += 1;
    // Per-call nonblocking is mandatory even though external-mode adoption also sets O_NONBLOCK:
    // another descriptor for the same open-file-description can change that shared flag.
    const result = c.recv(
        fd,
        destination.ptr,
        destination.len,
        posix.MSG.DONTWAIT,
    );
    return mapPosixReadResult(
        result,
        if (result < 0) posix.errno(result) else null,
    );
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

test "d2c product owner maps readiness to POSIX RX before any writable work" {
    const Apply = struct {
        calls: usize = 0,
        bytes: [5]u8 = [_]u8{0} ** 5,

        fn run(
            raw: *anyopaque,
            view: external_inbox_ledger.PayloadView,
        ) client_external_pump.LiveScreenApplyResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
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
        .initialized => source_owned = false,
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
    const drained = pumpRx(
        &storage,
        .{ .readable = true, .writable = true, .now_ns = 4 },
        &ops,
        scratch,
    );
    try std.testing.expect(drained.terminal == null);
    try std.testing.expect(drained.authority_clear);
    try std.testing.expectEqual(@as(usize, 0), drained.rx_read_bytes);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.fcntl(fds[0], c.F.GETFL) & host_nonblocking,
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
    var positive_context = PosixRxContext{ .test_calls = &positive_calls };
    const read_first = pumpRxWithContext(
        &storage,
        .{ .readable = true, .writable = true, .now_ns = 6 },
        &ops,
        scratch,
        &positive_context,
    );
    try std.testing.expect(read_first.terminal == null);
    try std.testing.expectEqual(second_wire.len, read_first.rx_read_bytes);
    try std.testing.expectEqual(@as(usize, 1), read_first.rx_frames);
    try std.testing.expect(!read_first.authority_clear);
    try std.testing.expectEqual(@as(usize, 2), positive_calls);
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

    const consume_second = pumpRx(
        &storage,
        .{ .readable = false, .writable = false, .now_ns = 7 },
        &ops,
        scratch,
    );
    try std.testing.expect(consume_second.terminal == null);
    try std.testing.expect(consume_second.inherited_work_ready);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqualStrings("again", &probe.bytes);

    try std.testing.expectEqual(
        @as(isize, 1),
        c.send(fds[1], second_wire.ptr, 1, 0),
    );
    try std.testing.expectEqual(@as(c_int, 0), c.shutdown(fds[1], c.SHUT.WR));
    const eof = pumpRx(
        &storage,
        .{ .readable = true, .writable = true, .now_ns = 8 },
        &ops,
        scratch,
    );
    try std.testing.expectEqual(client_pump.TerminalReason.eof, eof.terminal.?.reason);
    try std.testing.expectEqual(@as(usize, 0), eof.rx_read_bytes);
    try std.testing.expectEqual(@as(usize, 0), eof.rx_frames);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqual(
        client_external_pump.TeardownResult.cleaned,
        storage.teardown(&cleanup),
    );
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
