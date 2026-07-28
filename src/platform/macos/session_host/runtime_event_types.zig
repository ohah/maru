//! Primitive-only validation boundary for runtime event frames.
//!
//! `runtime_event_wire` proves the payload schema. This leaf binds that proof to the exact frame
//! header and to immutable attachment identity/authority evidence. Keeping the classifier free of
//! Client, parser, pump, and ownership types lets fresh RX and inherited FIFO adoption share one
//! fail-closed decision without creating a second product decoder.

const std = @import("std");
const protocol = @import("protocol.zig");
const resize_wire = @import("resize_wire.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Role = enum {
    observer,
    controller,
};

pub const EventGeneration = union(enum) {
    untracked,
    tracked: u64,
};

/// Immutable stream-to-runtime evidence established by a successful attach.
pub const EventIdentity = struct {
    runtime_id: u128,
    stream_id: u64,
};

/// Attachment-local authority at the event's classification point.
pub const EventAuthorityView = struct {
    role: Role,
    generation: EventGeneration,
};

/// Exact header plus borrowed payload. `payload_len` is retained separately so a caller cannot
/// silently normalize a corrupt header before classification.
pub const EventFrameView = struct {
    major: u16,
    kind: protocol.Kind,
    stream_id: u64,
    request_id: u64,
    flags: u32,
    payload_len: u32,
    payload: []const u8,
};

pub const MetadataSupport = runtime_event_wire.MetadataSupport;

/// Classifier-produced pairing of the borrowed semantic view and the digest of the exact payload
/// it was validated against. Owning consumers take this one token instead of independently
/// accepting a view and digest that could come from different frames.
pub const ValidatedMetadataView = struct {
    classifier_preflight: runtime_event_wire.EventPreflight,

    pub fn preflight(self: ValidatedMetadataView) runtime_event_wire.EventPreflight {
        return self.classifier_preflight;
    }
};

/// The payload verdict is sealed together with the negotiated major and compatibility profile.
/// This keeps `classifyEventView` at four arguments while still accepting a negotiated frozen
/// major instead of incorrectly hard-coding the current binary's protocol major.
pub const EventPreflightView = struct {
    expected_major: u16,
    metadata_support: MetadataSupport,
    verdict: runtime_event_wire.Verdict,
};

pub const ValidatedEventView = union(enum) {
    revoked: u64,
    invalidated,
    resized: resize_wire.Event,
    metadata: ValidatedMetadataView,
    ended,
};

pub const FrameViolation = enum {
    invalid_expected_major,
    major_mismatch,
    kind_mismatch,
    stream_mismatch,
    request_id_nonzero,
    flags_nonzero,
    payload_length_mismatch,
    payload_too_large,
};

pub const IdentityViolation = enum {
    zero_runtime,
    zero_stream,
    revoked_runtime,
    revoked_stream,
    resized_runtime,
};

pub const AuthorityViolation = enum {
    revoked_observer,
    revoked_generation,
};

pub const CapabilityViolation = enum {
    metadata_unsupported,
};

/// Closed failure vocabulary consumed by the later reducer/product boundary. Unknown event names
/// and unsupported-profile metadata remain distinguishable from malformed wire.
pub const Violation = union(enum) {
    frame: FrameViolation,
    identity: IdentityViolation,
    authority: AuthorityViolation,
    capability: CapabilityViolation,
    stale_preflight,
    unknown_event,
    foreign: runtime_event_wire.ForeignKind,
    malformed,
    resource_exhausted,
};

pub const Classification = union(enum) {
    accepted: ValidatedEventView,
    violation: Violation,
};

/// Binds a payload preflight to one exact runtime event frame and attachment.
///
/// The digest comparison is deliberately repeated at this boundary: inherited FIFO storage may
/// outlive the first preflight, so accepting its decoded spans without rebinding the raw bytes
/// would let stale or mutated storage cross the ownership transfer.
pub fn classifyEventView(
    identity: EventIdentity,
    authority: EventAuthorityView,
    preflight: EventPreflightView,
    frame: EventFrameView,
) Classification {
    if (identity.runtime_id == 0)
        return violation(.{ .identity = .zero_runtime });
    if (identity.stream_id == 0)
        return violation(.{ .identity = .zero_stream });

    if (preflight.expected_major == 0)
        return violation(.{ .frame = .invalid_expected_major });
    if (frame.major != preflight.expected_major)
        return violation(.{ .frame = .major_mismatch });
    if (frame.kind != .event)
        return violation(.{ .frame = .kind_mismatch });
    if (frame.stream_id != identity.stream_id)
        return violation(.{ .frame = .stream_mismatch });
    if (frame.request_id != 0)
        return violation(.{ .frame = .request_id_nonzero });
    if (frame.flags != 0)
        return violation(.{ .frame = .flags_nonzero });
    if (frame.payload.len > std.math.maxInt(u32) or
        frame.payload_len != @as(u32, @intCast(frame.payload.len)))
        return violation(.{ .frame = .payload_length_mismatch });
    if (frame.payload.len > protocol.max_control_json)
        return violation(.{ .frame = .payload_too_large });

    const accepted = switch (preflight.verdict) {
        .accepted => |value| value,
        .unknown => return violation(.unknown_event),
        .foreign => |kind| return violation(.{ .foreign = kind }),
        .malformed => return violation(.malformed),
        .resource_exhausted => return violation(.resource_exhausted),
    };
    if (!std.mem.eql(u8, &accepted.raw_digest, &sha(frame.payload)))
        return violation(.stale_preflight);

    return switch (accepted.event) {
        .revoked => |event| classifyRevoked(identity, authority, event),
        .invalidated => .{ .accepted = .invalidated },
        .resized => |event| if (event.runtime_id != identity.runtime_id)
            violation(.{ .identity = .resized_runtime })
        else
            .{ .accepted = .{ .resized = event } },
        .metadata => if (preflight.metadata_support == .unsupported)
            violation(.{ .capability = .metadata_unsupported })
        else
            .{ .accepted = .{ .metadata = .{ .classifier_preflight = accepted } } },
        .ended => .{ .accepted = .ended },
    };
}

fn classifyRevoked(
    identity: EventIdentity,
    authority: EventAuthorityView,
    event: runtime_event_wire.Revoked,
) Classification {
    if (event.runtime_id != identity.runtime_id)
        return violation(.{ .identity = .revoked_runtime });
    if (event.stream_id != identity.stream_id)
        return violation(.{ .identity = .revoked_stream });
    if (authority.role != .controller)
        return violation(.{ .authority = .revoked_observer });

    const current = switch (authority.generation) {
        .untracked => return violation(.{ .authority = .revoked_generation }),
        .tracked => |value| value,
    };
    const successor = std.math.add(u64, current, 1) catch
        return violation(.{ .authority = .revoked_generation });
    if (event.controller_generation != successor)
        return violation(.{ .authority = .revoked_generation });
    return .{ .accepted = .{ .revoked = successor } };
}

fn violation(value: Violation) Classification {
    return .{ .violation = value };
}

fn sha(bytes: []const u8) runtime_event_wire.Digest {
    var digest: runtime_event_wire.Digest = undefined;
    Sha256.hash(bytes, &digest, .{});
    return digest;
}

const test_identity: EventIdentity = .{
    .runtime_id = 0xaa,
    .stream_id = 7,
};
const test_authority: EventAuthorityView = .{
    .role = .controller,
    .generation = .{ .tracked = 3 },
};

fn testFrame(payload: []const u8) EventFrameView {
    return .{
        .major = protocol.version_major,
        .kind = .event,
        .stream_id = test_identity.stream_id,
        .request_id = 0,
        .flags = 0,
        .payload_len = @intCast(payload.len),
        .payload = payload,
    };
}

fn testPreflight(
    payload: []const u8,
    metadata_support: MetadataSupport,
) EventPreflightView {
    return .{
        .expected_major = protocol.version_major,
        .metadata_support = metadata_support,
        .verdict = runtime_event_wire.preflightEvent(payload, .{}),
    };
}

fn expectAcceptedTag(classification: Classification, comptime expected: std.meta.Tag(ValidatedEventView)) !void {
    const event = switch (classification) {
        .accepted => |value| value,
        .violation => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(expected, std.meta.activeTag(event));
}

fn expectViolation(
    classification: Classification,
    comptime expected: std.meta.Tag(Violation),
) !Violation {
    const value = switch (classification) {
        .accepted => return error.TestUnexpectedResult,
        .violation => |found| found,
    };
    try std.testing.expectEqual(expected, std.meta.activeTag(value));
    return value;
}

test "classifier accepts the common event set and binds revoke authority exactly" {
    const invalidated = "{\"event\":\"snapshot.invalidated\"}";
    const ended = "{\"event\":\"runtime.ended\"}";
    const resized =
        "{\"event\":\"runtime.resized\",\"data\":{\"runtime_id\":" ++
        "\"000000000000000000000000000000aa\",\"cols\":120,\"rows\":40," ++
        "\"resize_generation\":9,\"reason\":\"controller\"}}";
    const revoked =
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":" ++
        "\"000000000000000000000000000000aa\",\"stream_id\":7," ++
        "\"controller_generation\":4,\"reason\":\"takeover\"}}";

    try expectAcceptedTag(
        classifyEventView(test_identity, test_authority, testPreflight(invalidated, .supported), testFrame(invalidated)),
        .invalidated,
    );
    try expectAcceptedTag(
        classifyEventView(test_identity, test_authority, testPreflight(ended, .supported), testFrame(ended)),
        .ended,
    );
    try expectAcceptedTag(
        classifyEventView(test_identity, .{ .role = .observer, .generation = .{ .tracked = 3 } }, testPreflight(resized, .supported), testFrame(resized)),
        .resized,
    );
    const revoked_result = classifyEventView(
        test_identity,
        test_authority,
        testPreflight(revoked, .supported),
        testFrame(revoked),
    );
    const revoked_event = switch (revoked_result) {
        .accepted => |event| switch (event) {
            .revoked => |generation| generation,
            else => return error.TestUnexpectedResult,
        },
        .violation => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, 4), revoked_event);
}

test "classifier rejects every normalized-away frame header difference" {
    const payload = "{\"event\":\"runtime.ended\"}";
    const preflight = testPreflight(payload, .supported);

    var frame = testFrame(payload);
    frame.major -= 1;
    const major = try expectViolation(
        classifyEventView(test_identity, test_authority, preflight, frame),
        .frame,
    );
    try std.testing.expectEqual(FrameViolation.major_mismatch, major.frame);

    frame = testFrame(payload);
    frame.kind = .request;
    const kind = try expectViolation(
        classifyEventView(test_identity, test_authority, preflight, frame),
        .frame,
    );
    try std.testing.expectEqual(FrameViolation.kind_mismatch, kind.frame);

    frame = testFrame(payload);
    frame.stream_id += 1;
    const stream = try expectViolation(
        classifyEventView(test_identity, test_authority, preflight, frame),
        .frame,
    );
    try std.testing.expectEqual(FrameViolation.stream_mismatch, stream.frame);

    frame = testFrame(payload);
    frame.request_id = 1;
    const request = try expectViolation(
        classifyEventView(test_identity, test_authority, preflight, frame),
        .frame,
    );
    try std.testing.expectEqual(FrameViolation.request_id_nonzero, request.frame);

    frame = testFrame(payload);
    frame.flags = protocol.Flags.optional;
    const flags = try expectViolation(
        classifyEventView(test_identity, test_authority, preflight, frame),
        .frame,
    );
    try std.testing.expectEqual(FrameViolation.flags_nonzero, flags.frame);

    frame = testFrame(payload);
    frame.payload_len -= 1;
    const length = try expectViolation(
        classifyEventView(test_identity, test_authority, preflight, frame),
        .frame,
    );
    try std.testing.expectEqual(FrameViolation.payload_length_mismatch, length.frame);
}

test "classifier validates the negotiated major instead of the current binary major" {
    const payload = "{\"event\":\"runtime.ended\"}";
    var frame = testFrame(payload);
    frame.major = 1;
    var preflight = testPreflight(payload, .unsupported);
    preflight.expected_major = 1;
    try expectAcceptedTag(
        classifyEventView(test_identity, test_authority, preflight, frame),
        .ended,
    );

    preflight.expected_major = 0;
    const invalid = try expectViolation(
        classifyEventView(test_identity, test_authority, preflight, frame),
        .frame,
    );
    try std.testing.expectEqual(FrameViolation.invalid_expected_major, invalid.frame);
}

test "classifier rejects payload beyond the control cap before trusting its preflight" {
    const payload = try std.testing.allocator.alloc(u8, protocol.max_control_json + 1);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    const oversized = try expectViolation(
        classifyEventView(
            test_identity,
            test_authority,
            testPreflight(payload, .supported),
            testFrame(payload),
        ),
        .frame,
    );
    try std.testing.expectEqual(FrameViolation.payload_too_large, oversized.frame);
}

test "classifier rebinds preflight digest to immutable payload bytes" {
    const original = "{\"event\":\"runtime.ended\"}";
    const mutated = "{\"event\":\"future.event\"}";
    const preflight = testPreflight(original, .supported);
    const stale = try expectViolation(
        classifyEventView(test_identity, test_authority, preflight, testFrame(mutated)),
        .stale_preflight,
    );
    try std.testing.expect(stale == .stale_preflight);
}

test "classifier verifies event payload identity and revoke authority" {
    const wrong_resize =
        "{\"event\":\"runtime.resized\",\"data\":{\"runtime_id\":" ++
        "\"000000000000000000000000000000bb\",\"cols\":120,\"rows\":40," ++
        "\"resize_generation\":9,\"reason\":\"controller\"}}";
    const resize_identity = try expectViolation(
        classifyEventView(
            test_identity,
            test_authority,
            testPreflight(wrong_resize, .supported),
            testFrame(wrong_resize),
        ),
        .identity,
    );
    try std.testing.expectEqual(IdentityViolation.resized_runtime, resize_identity.identity);

    const wrong_revoke_runtime =
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":" ++
        "\"000000000000000000000000000000bb\",\"stream_id\":7," ++
        "\"controller_generation\":4,\"reason\":\"takeover\"}}";
    const revoke_runtime = try expectViolation(
        classifyEventView(
            test_identity,
            test_authority,
            testPreflight(wrong_revoke_runtime, .supported),
            testFrame(wrong_revoke_runtime),
        ),
        .identity,
    );
    try std.testing.expectEqual(IdentityViolation.revoked_runtime, revoke_runtime.identity);

    const wrong_revoke_stream =
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":" ++
        "\"000000000000000000000000000000aa\",\"stream_id\":8," ++
        "\"controller_generation\":4,\"reason\":\"takeover\"}}";
    const revoke_stream = try expectViolation(
        classifyEventView(
            test_identity,
            test_authority,
            testPreflight(wrong_revoke_stream, .supported),
            testFrame(wrong_revoke_stream),
        ),
        .identity,
    );
    try std.testing.expectEqual(IdentityViolation.revoked_stream, revoke_stream.identity);

    const revoked =
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":" ++
        "\"000000000000000000000000000000aa\",\"stream_id\":7," ++
        "\"controller_generation\":4,\"reason\":\"takeover\"}}";
    const observer = try expectViolation(
        classifyEventView(
            test_identity,
            .{ .role = .observer, .generation = .{ .tracked = 3 } },
            testPreflight(revoked, .supported),
            testFrame(revoked),
        ),
        .authority,
    );
    try std.testing.expectEqual(AuthorityViolation.revoked_observer, observer.authority);

    const generation = try expectViolation(
        classifyEventView(
            test_identity,
            .{ .role = .controller, .generation = .{ .tracked = 2 } },
            testPreflight(revoked, .supported),
            testFrame(revoked),
        ),
        .authority,
    );
    try std.testing.expectEqual(AuthorityViolation.revoked_generation, generation.authority);
}

test "classifier never invents a revoke successor for untracked authority" {
    const payload =
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":" ++
        "\"000000000000000000000000000000aa\",\"stream_id\":7," ++
        "\"controller_generation\":1,\"reason\":\"takeover\"}}";
    const result = try expectViolation(
        classifyEventView(
            test_identity,
            .{ .role = .controller, .generation = .untracked },
            testPreflight(payload, .supported),
            testFrame(payload),
        ),
        .authority,
    );
    try std.testing.expectEqual(
        AuthorityViolation.revoked_generation,
        result.authority,
    );
}

test "classifier preserves wire and capability violations as typed outcomes" {
    const payload = "{\"event\":\"runtime.ended\"}";
    const frame = testFrame(payload);
    const cases = .{
        .{ runtime_event_wire.Verdict.unknown, std.meta.Tag(Violation).unknown_event },
        .{ runtime_event_wire.Verdict.malformed, std.meta.Tag(Violation).malformed },
        .{ runtime_event_wire.Verdict.resource_exhausted, std.meta.Tag(Violation).resource_exhausted },
    };
    inline for (cases) |case| {
        const found = try expectViolation(
            classifyEventView(
                test_identity,
                test_authority,
                .{
                    .expected_major = protocol.version_major,
                    .metadata_support = .supported,
                    .verdict = case[0],
                },
                frame,
            ),
            case[1],
        );
        try std.testing.expectEqual(case[1], std.meta.activeTag(found));
    }

    const foreign = try expectViolation(
        classifyEventView(
            test_identity,
            test_authority,
            .{
                .expected_major = protocol.version_major,
                .metadata_support = .supported,
                .verdict = .{ .foreign = .stream },
            },
            frame,
        ),
        .foreign,
    );
    try std.testing.expectEqual(runtime_event_wire.ForeignKind.stream, foreign.foreign);

    const metadata =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{" ++
        "\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null," ++
        "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
        "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2," ++
        "\"cols\":80,\"rows\":24,\"foreground_available\":false," ++
        "\"foreground_pgid\":null,\"processes\":[]}}";
    const unsupported = try expectViolation(
        classifyEventView(
            test_identity,
            test_authority,
            testPreflight(metadata, .unsupported),
            testFrame(metadata),
        ),
        .capability,
    );
    try std.testing.expectEqual(
        CapabilityViolation.metadata_unsupported,
        unsupported.capability,
    );
}
