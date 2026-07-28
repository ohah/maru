//! Final-address bridge from one published external attach result to paired pump evidence.
//!
//! This adapter is deliberately narrower than the future 2b3 pump owner: it consumes only the
//! metadata seed into an address-bound evidence token. Client and RemoteAttachment stay in the
//! caller's `external_attach.Prepared` until the paired storage transaction and later binding.

const external_attach = @import("external_attach.zig");
const client_external_pump = @import("client_external_pump.zig");

pub const PrepareError = error{
    InvalidAlias,
    InvalidEvidence,
    OutOfMemory,
};

pub fn prepareInPlace(
    out: *client_external_pump.PreparedAdoptionEvidence,
    source: *external_attach.Prepared,
) PrepareError!void {
    if (rangesOverlap(
        @intFromPtr(out),
        @sizeOf(client_external_pump.PreparedAdoptionEvidence),
        @intFromPtr(source),
        @sizeOf(external_attach.Prepared),
    )) return error.InvalidAlias;
    const state = source.attachment.state;
    try client_external_pump.PreparedAdoptionEvidence.initFromAttachPartsInPlace(
        out,
        source.attach_instance_id,
        &source.client,
        .{
            .runtime_id = state.runtime_id,
            .stream_id = state.stream_id,
            .initial_role = switch (state.role) {
                .observer => .observer,
                .controller => .controller,
            },
            .initial_controller_generation = state.controller_generation,
        },
        &source.initial_metadata,
    );
    // One-shot latch. `InitialMetadataSeed.take` leaves `.unavailable`, which a metadata-supporting
    // Client accepts as a legitimate value, so the emptied seed alone cannot mark this `Prepared`
    // consumed. Clearing the consumable token makes a second extraction fail the id cross-check
    // instead of silently minting evidence whose metadata was already moved away.
    source.attach_instance_id = 0;
}

fn rangesOverlap(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_end = @addWithOverflow(a_start, a_len);
    const b_end = @addWithOverflow(b_start, b_len);
    if (a_end[1] != 0 or b_end[1] != 0) return true;
    return a_start < b_end[0] and b_start < a_end[0];
}

const std = @import("std");
const c = std.c;
const posix = std.posix;
const client_mod = @import("client.zig");
const compatibility = @import("compatibility.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const remote_attachment = @import("remote_attachment.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");

const TestPrepared = struct {
    value: external_attach.Prepared,
    peer_fd: c.fd_t,

    fn init(instance_id: u64) !TestPrepared {
        var fds: [2]c.fd_t = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
        );
        var client: client_mod.Client = .{
            .allocator = std.testing.allocator,
            .fd = fds[0],
            .host_id = 1,
            .parser = framing.FrameParser.init(std.testing.allocator),
            // `external_attach.prepare` seals this on both halves; fixtures must do the same or the
            // evidence cross-check rejects them.
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
            .value = .{
                .attach_instance_id = instance_id,
                .client = client,
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
            },
            .peer_fd = fds[1],
        };
    }

    fn deinit(self: *TestPrepared) void {
        self.value.deinit();
        if (self.peer_fd >= 0) _ = c.close(self.peer_fd);
        self.peer_fd = -1;
    }
};

test "external attach evidence bridge rejects same-semantic cross-attach swap" {
    var first = try TestPrepared.init(100);
    defer first.deinit();
    var second = try TestPrepared.init(101);
    defer second.deinit();
    const overlapping: *client_external_pump.PreparedAdoptionEvidence =
        @ptrCast(@alignCast(&first.value.attachment));
    try std.testing.expectError(
        error.InvalidAlias,
        prepareInPlace(overlapping, &first.value),
    );
    try std.testing.expectEqual(@as(u128, 0xaa), first.value.attachment.state.runtime_id);
    try std.testing.expect(first.value.client.fd >= 0);
    var first_evidence: client_external_pump.PreparedAdoptionEvidence = .{};
    defer first_evidence.deinit();
    var second_evidence: client_external_pump.PreparedAdoptionEvidence = .{};
    defer second_evidence.deinit();
    try prepareInPlace(&first_evidence, &first.value);
    try prepareInPlace(&second_evidence, &second.value);
    try std.testing.expect(first.value.initial_metadata == .unavailable);
    try std.testing.expect(second.value.initial_metadata == .unavailable);

    try std.testing.expect(!second_evidence.validate(&first.value.client));
    try std.testing.expect(first.value.client.fd >= 0);
    try std.testing.expect(second_evidence.validate(&second.value.client));
    try std.testing.expect(first_evidence.validate(&first.value.client));
}

test "external attach evidence binds the attach instance id, not just the client address" {
    // The realistic swap is address reuse: one `Prepared` is dropped and the next attach lands in
    // the same slot with semantically identical runtime/stream/role/profile. Address equality alone
    // cannot tell those apart, so deleting the instance id must make this test fail.
    var attach = try TestPrepared.init(100);
    defer attach.deinit();
    var evidence: client_external_pump.PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    try prepareInPlace(&evidence, &attach.value);
    try std.testing.expect(evidence.validate(&attach.value.client));

    // Same address, same semantics, different attach.
    attach.value.client.attach_instance_id = 101;
    try std.testing.expect(!evidence.validate(&attach.value.client));
    attach.value.client.attach_instance_id = 100;
    try std.testing.expect(evidence.validate(&attach.value.client));
}

test "external attach evidence extraction is one-shot" {
    // `take()` leaves `.unavailable`, which a metadata-supporting Client accepts as a real value.
    // Without an explicit latch a retry would mint a second, silently metadata-less evidence.
    var attach = try TestPrepared.init(100);
    defer attach.deinit();
    attach.value.client.metadata_support = .supported;
    attach.value.initial_metadata = .unavailable;

    var first_evidence: client_external_pump.PreparedAdoptionEvidence = .{};
    defer first_evidence.deinit();
    try prepareInPlace(&first_evidence, &attach.value);
    try std.testing.expectEqual(@as(u64, 0), attach.value.attach_instance_id);

    var second_evidence: client_external_pump.PreparedAdoptionEvidence = .{};
    defer second_evidence.deinit();
    try std.testing.expectError(
        error.InvalidEvidence,
        prepareInPlace(&second_evidence, &attach.value),
    );
    // The rejected attempt left the first owner and the Client untouched.
    try std.testing.expect(first_evidence.validate(&attach.value.client));
    try std.testing.expect(attach.value.client.fd >= 0);
}

test "external attach evidence rejects a seed aliasing the source client" {
    // The mechanics leaf proves four alias pairs; this is the one that guards `seed.take()` from
    // writing a union tag over the Client's own owning descriptors.
    var attach = try TestPrepared.init(100);
    defer attach.deinit();
    var evidence: client_external_pump.PreparedAdoptionEvidence = .{};
    defer evidence.deinit();
    const aliased: *runtime_metadata_wire.InitialMetadataSeed =
        @ptrCast(@alignCast(&attach.value.client));
    try std.testing.expectError(
        error.InvalidAlias,
        client_external_pump.PreparedAdoptionEvidence.initFromAttachPartsInPlace(
            &evidence,
            attach.value.attach_instance_id,
            &attach.value.client,
            .{
                .runtime_id = 0xaa,
                .stream_id = 7,
                .initial_role = .controller,
                .initial_controller_generation = 3,
            },
            aliased,
        ),
    );
    try std.testing.expect(attach.value.client.fd >= 0);
    try std.testing.expectEqual(@as(u64, 100), attach.value.client.attach_instance_id);
}
