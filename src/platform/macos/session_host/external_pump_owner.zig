//! Product-side owner boundary for the external session pump.
//!
//! d2b3d intentionally exposes only buffered RX. d2c extends this boundary with injected socket
//! reads, and 2b3 replaces the borrowed storage parameter with the final-address
//! `ExternalPumpOwner`. Keeping the sole non-test call here prevents UI, CLI, and transport code
//! from bypassing the pump transaction.

const client_external_pump = @import("client_external_pump.zig");
const client_pump = @import("client_pump.zig");

/// Runs one bounded buffered-only turn through the product owner boundary.
///
/// `ops.apply_live_screen` receives a synchronous immutable borrow. The callback must not retain
/// the view or any pointer derived from it after returning.
pub fn pumpBufferedRx(
    storage: *client_external_pump.ExternalPumpStorage,
    turn: client_pump.TurnInput,
    ops: *const client_external_pump.BufferedRxOps,
    scratch: *client_external_pump.ExternalRxTurnScratch,
) client_pump.TurnResult {
    return storage.pumpRxTurn(turn, ops, scratch);
}

const std = @import("std");
const c = std.c;
const posix = std.posix;
const client_mod = @import("client.zig");
const compatibility = @import("compatibility.zig");
const external_attach = @import("external_attach.zig");
const external_attach_evidence = @import("external_attach_evidence.zig");
const external_inbox_ledger = @import("external_inbox_ledger.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const remote_attachment = @import("remote_attachment.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");

test "d2b3d product owner drives adopted Client parser and live FIFO" {
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
    try std.testing.expect(
        storage.prepareAdoption(1, &cleanup) == .prepared_adopted,
    );
    try std.testing.expect(storage.commitAdoption() == .adopted);
    const scratch =
        try std.testing.allocator.create(client_external_pump.ExternalRxTurnScratch);
    defer std.testing.allocator.destroy(scratch);
    scratch.* = .{};
    try std.testing.expect(
        client_external_pump.ExternalRxTurnScratch.initInPlace(scratch),
    );
    var probe = Apply{};
    const ops = client_external_pump.BufferedRxOps{
        .context = &probe,
        .apply_live_screen = Apply.run,
    };
    const first = pumpBufferedRx(
        &storage,
        .{ .readable = true, .writable = false, .now_ns = 2 },
        &ops,
        scratch,
    );
    try std.testing.expect(first.terminal == null);
    try std.testing.expectEqual(@as(usize, 1), first.rx_frames);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    const second = pumpBufferedRx(
        &storage,
        .{ .readable = false, .writable = false, .now_ns = 3 },
        &ops,
        scratch,
    );
    try std.testing.expect(second.terminal == null);
    try std.testing.expect(second.inherited_work_ready);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqualStrings("owner", &probe.bytes);
    try std.testing.expectEqual(
        client_external_pump.TeardownResult.cleaned,
        storage.teardown(&cleanup),
    );
    _ = c.close(fds[1]);
    peer_open = false;
}
