//! Structural and event-semantic classifiers for fresh external-session RX frames.
//!
//! `classifyExternalRx` borrows one parser-produced, sealed frame/range pair and performs no
//! allocation, decoding, ownership transfer, ledger mutation, or socket I/O.
//! `classifyEventCandidate` alone runs the common event decoder and semantic classifier.
//! Response correlation remains in its future owner.

const std = @import("std");
const client_external_mode = @import("client_external_mode.zig");
const external_rx_types = @import("external_rx_types.zig");
const protocol = @import("protocol.zig");
const runtime_event_types = @import("runtime_event_types.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");

pub const ScreenCandidate = struct {
    header: protocol.Header,
    range: external_rx_types.RxRange,
    pair_seal: client_external_mode.ExternalRxFrameSeal,
};

pub const EventCandidate = struct {
    header: protocol.Header,
    range: external_rx_types.RxRange,
    pair_seal: client_external_mode.ExternalRxFrameSeal,
};

pub const ResponseCandidate = struct {
    request_id: u64,
    header: protocol.Header,
    range: external_rx_types.RxRange,
    pair_seal: client_external_mode.ExternalRxFrameSeal,
};

pub const ExternalWireClass = union(enum) {
    screen_candidate: ScreenCandidate,
    event_candidate: EventCandidate,
    response_candidate: ResponseCandidate,
    protocol_terminal,
};

pub const ExternalEventClass = union(enum) {
    accepted: runtime_event_types.ValidatedEventView,
    protocol_terminal,
};

/// Minimal value view created only after the d2b owner validates its storage seal and ledger slot.
pub const ValidatedPartialView = struct {
    stream_id: u64,
    is_snapshot: bool,
    identity: external_rx_types.RxIdentity,
    start_absolute: u64,
    end_absolute: u64,
    chunk_count: u8,
};

pub fn classifyExternalRx(
    paired: *const client_external_mode.ExternalRxFrame,
    expected_identity: external_rx_types.RxIdentity,
    target_stream_id: u64,
    partial: ?ValidatedPartialView,
) ExternalWireClass {
    if (!client_external_mode.validateExternalRxFrame(paired) or
        !std.meta.eql(paired.range.identity, expected_identity) or
        target_stream_id == 0)
        return .protocol_terminal;
    const frame = &paired.frame;
    const range = paired.range;

    return switch (frame.header.kind) {
        .snapshot_chunk, .delta_chunk => classifyScreen(
            frame.header,
            range,
            paired.pair_seal,
            target_stream_id,
            partial,
        ),
        .event => if (partial != null or
            frame.header.stream_id != target_stream_id or
            frame.header.request_id != 0 or
            frame.header.flags != 0)
            .protocol_terminal
        else
            .{ .event_candidate = .{
                .header = frame.header,
                .range = range,
                .pair_seal = paired.pair_seal,
            } },
        .response => if (partial != null or
            frame.header.stream_id != 0 or
            frame.header.request_id == 0 or
            frame.header.flags != 0)
            .protocol_terminal
        else
            .{ .response_candidate = .{
                .request_id = frame.header.request_id,
                .header = frame.header,
                .range = range,
                .pair_seal = paired.pair_seal,
            } },
        else => .protocol_terminal,
    };
}

/// Runs the common event lexical preflight and semantic classifier exactly once each.
pub fn classifyEventCandidate(
    identity: runtime_event_types.EventIdentity,
    authority: runtime_event_types.EventAuthorityView,
    expected_major: u16,
    metadata_support: runtime_event_types.MetadataSupport,
    paired: *const client_external_mode.ExternalRxFrame,
    candidate: EventCandidate,
    observer: ?runtime_event_wire.ParseObserver,
) ExternalEventClass {
    if (!client_external_mode.validateExternalRxFrame(paired) or
        !std.meta.eql(paired.frame.header, candidate.header) or
        !std.meta.eql(paired.range, candidate.range) or
        !std.mem.eql(u8, &paired.pair_seal, &candidate.pair_seal))
        return .protocol_terminal;
    const frame_value = &paired.frame;
    const preflight = runtime_event_wire.preflightEventObserved(
        frame_value.payload,
        .{ .runtime_id = identity.runtime_id, .stream_id = identity.stream_id },
        observer,
    );
    return switch (runtime_event_types.classifyEventView(
        identity,
        authority,
        .{
            .expected_major = expected_major,
            .metadata_support = metadata_support,
            .verdict = preflight,
        },
        .{
            .major = frame_value.header.major,
            .kind = frame_value.header.kind,
            .stream_id = frame_value.header.stream_id,
            .request_id = frame_value.header.request_id,
            .flags = frame_value.header.flags,
            .payload_len = frame_value.header.payload_len,
            .payload = frame_value.payload,
        },
    )) {
        .accepted => |event| .{ .accepted = event },
        .violation => .protocol_terminal,
    };
}

fn classifyScreen(
    header: protocol.Header,
    range: external_rx_types.RxRange,
    pair_seal: client_external_mode.ExternalRxFrameSeal,
    target_stream_id: u64,
    partial: ?ValidatedPartialView,
) ExternalWireClass {
    if (header.stream_id != target_stream_id or
        header.request_id != 0 or
        protocol.Flags.hasUnknownBits(header.flags) or
        protocol.Flags.isOptional(header.flags) or
        header.flags & ~protocol.Flags.end_stream != 0)
        return .protocol_terminal;

    if (partial) |existing| {
        if (existing.stream_id != target_stream_id or
            existing.stream_id != header.stream_id or
            existing.is_snapshot != (header.kind == .snapshot_chunk) or
            existing.chunk_count == 0 or
            existing.chunk_count >= protocol.max_screen_batch_chunks or
            !std.meta.eql(existing.identity, range.identity) or
            existing.start_absolute >= existing.end_absolute or
            existing.end_absolute != range.start_absolute)
            return .protocol_terminal;
    }

    return .{ .screen_candidate = .{
        .header = header,
        .range = range,
        .pair_seal = pair_seal,
    } };
}

fn testIdentity() external_rx_types.RxIdentity {
    return .{ .attach_instance_id = 7, .destination_slot_addr = 0x1000 };
}

fn makeFrame(header: protocol.Header, payload: []u8) client_external_mode.ExternalRxFrame {
    var normalized = header;
    normalized.payload_len = @intCast(payload.len);
    var result = client_external_mode.ExternalRxFrame{
        .frame = .{ .header = normalized, .payload = payload },
        .range = rangeFor(payload.len),
        .pair_seal = undefined,
    };
    client_external_mode.testing.sealExternalRxFrame(&result);
    return result;
}

fn rangeFor(payload_len: usize) external_rx_types.RxRange {
    return .{
        .identity = testIdentity(),
        .start_absolute = 100,
        .end_absolute = 100 + protocol.header_size + payload_len,
    };
}

test "external RX demux classifies own screen event and structural response candidates" {
    var payload = [_]u8{ 1, 2, 3 };
    const screen = makeFrame(.{
        .kind = .snapshot_chunk,
        .stream_id = 9,
        .flags = protocol.Flags.end_stream,
    }, &payload);
    try std.testing.expect(classifyExternalRx(&screen, testIdentity(), 9, null) ==
        .screen_candidate);

    const event = makeFrame(.{ .kind = .event, .stream_id = 9 }, &payload);
    try std.testing.expect(classifyExternalRx(&event, testIdentity(), 9, null) ==
        .event_candidate);

    const response = makeFrame(.{ .kind = .response, .request_id = 4 }, &payload);
    const classified = classifyExternalRx(&response, testIdentity(), 9, null);
    try std.testing.expect(classified == .response_candidate);
    try std.testing.expectEqual(@as(u64, 4), classified.response_candidate.request_id);
}

test "external RX demux rejects foreign and structurally invalid frames" {
    var payload = [_]u8{1};
    const headers = [_]protocol.Header{
        .{ .kind = .snapshot_chunk, .stream_id = 8 },
        .{ .kind = .snapshot_chunk, .stream_id = 9, .request_id = 1 },
        .{ .kind = .snapshot_chunk, .stream_id = 9, .flags = protocol.Flags.optional },
        .{ .kind = .snapshot_chunk, .stream_id = 9, .flags = 0x4 },
        .{ .kind = .event, .stream_id = 8 },
        .{ .kind = .event, .stream_id = 9, .request_id = 1 },
        .{ .kind = .event, .stream_id = 9, .flags = protocol.Flags.end_stream },
        .{ .kind = .response, .stream_id = 9, .request_id = 1 },
        .{ .kind = .response, .request_id = 0 },
        .{ .kind = .response, .request_id = 1, .flags = protocol.Flags.end_stream },
        .{ .kind = .request, .request_id = 1 },
        .{ .kind = .input_bytes, .stream_id = 9 },
        .{ .kind = @enumFromInt(60000), .stream_id = 9 },
    };
    for (headers) |header| {
        const candidate = makeFrame(header, &payload);
        try std.testing.expect(classifyExternalRx(
            &candidate,
            testIdentity(),
            9,
            null,
        ) == .protocol_terminal);
    }

    const own = makeFrame(.{ .kind = .delta_chunk, .stream_id = 9 }, &payload);
    try std.testing.expect(classifyExternalRx(&own, testIdentity(), 0, null) ==
        .protocol_terminal);
}

test "external RX demux rejects malformed or substituted sealed frame range bindings" {
    var payload = [_]u8{ 1, 2 };
    var candidate = makeFrame(.{ .kind = .delta_chunk, .stream_id = 9 }, &payload);
    candidate.frame.header.payload_len += 1;
    try std.testing.expect(classifyExternalRx(&candidate, testIdentity(), 9, null) ==
        .protocol_terminal);
    candidate = makeFrame(.{ .kind = .delta_chunk, .stream_id = 9 }, &payload);
    candidate.range.end_absolute -= 1;
    try std.testing.expect(classifyExternalRx(&candidate, testIdentity(), 9, null) ==
        .protocol_terminal);

    candidate = makeFrame(.{ .kind = .delta_chunk, .stream_id = 9 }, &payload);
    candidate.range.identity.attach_instance_id += 1;
    try std.testing.expect(classifyExternalRx(&candidate, testIdentity(), 9, null) ==
        .protocol_terminal);

    candidate = makeFrame(.{ .kind = .delta_chunk, .stream_id = 9 }, &payload);
    candidate.range.start_absolute += 17;
    candidate.range.end_absolute += 17;
    try std.testing.expect(classifyExternalRx(&candidate, testIdentity(), 9, null) ==
        .protocol_terminal);

    const other_identity = external_rx_types.RxIdentity{
        .attach_instance_id = testIdentity().attach_instance_id + 1,
        .destination_slot_addr = testIdentity().destination_slot_addr + 0x100,
    };
    candidate = makeFrame(.{ .kind = .delta_chunk, .stream_id = 9 }, &payload);
    try std.testing.expect(classifyExternalRx(&candidate, other_identity, 9, null) ==
        .protocol_terminal);
}

test "external RX demux enforces partial stream kind contiguity and interleave rejection" {
    var payload = [_]u8{1};
    const current_range = rangeFor(payload.len);
    const partial = ValidatedPartialView{
        .stream_id = 9,
        .is_snapshot = true,
        .identity = testIdentity(),
        .start_absolute = 10,
        .end_absolute = current_range.start_absolute,
        .chunk_count = 1,
    };
    const continuation = makeFrame(.{ .kind = .snapshot_chunk, .stream_id = 9 }, &payload);
    try std.testing.expect(classifyExternalRx(
        &continuation,
        testIdentity(),
        9,
        partial,
    ) == .screen_candidate);
    const ending = makeFrame(.{
        .kind = .snapshot_chunk,
        .stream_id = 9,
        .flags = protocol.Flags.end_stream,
    }, &payload);
    try std.testing.expect(classifyExternalRx(
        &ending,
        testIdentity(),
        9,
        partial,
    ) == .screen_candidate);

    var delta_partial = partial;
    delta_partial.is_snapshot = false;
    const delta = makeFrame(.{ .kind = .delta_chunk, .stream_id = 9 }, &payload);
    try std.testing.expect(classifyExternalRx(
        &delta,
        testIdentity(),
        9,
        delta_partial,
    ) == .screen_candidate);

    const interleaved = [_]protocol.Header{
        .{ .kind = .delta_chunk, .stream_id = 9 },
        .{ .kind = .snapshot_chunk, .stream_id = 8 },
        .{ .kind = .event, .stream_id = 9 },
        .{ .kind = .response, .request_id = 1 },
    };
    for (interleaved) |header| {
        const candidate = makeFrame(header, &payload);
        try std.testing.expect(classifyExternalRx(
            &candidate,
            testIdentity(),
            9,
            partial,
        ) == .protocol_terminal);
    }

    var gapped = partial;
    gapped.end_absolute -= 1;
    try std.testing.expect(classifyExternalRx(
        &continuation,
        testIdentity(),
        9,
        gapped,
    ) == .protocol_terminal);
    var exhausted = partial;
    exhausted.chunk_count = protocol.max_screen_batch_chunks;
    try std.testing.expect(classifyExternalRx(
        &continuation,
        testIdentity(),
        9,
        exhausted,
    ) == .protocol_terminal);

    var last_allowed = partial;
    last_allowed.chunk_count = protocol.max_screen_batch_chunks - 1;
    try std.testing.expect(classifyExternalRx(
        &continuation,
        testIdentity(),
        9,
        last_allowed,
    ) == .screen_candidate);
    var empty_partial = partial;
    empty_partial.chunk_count = 0;
    try std.testing.expect(classifyExternalRx(
        &continuation,
        testIdentity(),
        9,
        empty_partial,
    ) == .protocol_terminal);
    var reversed = partial;
    reversed.start_absolute = reversed.end_absolute;
    try std.testing.expect(classifyExternalRx(
        &continuation,
        testIdentity(),
        9,
        reversed,
    ) == .protocol_terminal);
    var foreign_identity = partial;
    foreign_identity.identity.attach_instance_id += 1;
    try std.testing.expect(classifyExternalRx(
        &continuation,
        testIdentity(),
        9,
        foreign_identity,
    ) == .protocol_terminal);
}

test "external RX demux is mutation-free across accepted and terminal classifications" {
    var payload = [_]u8{ 7, 8, 9 };
    const candidate = makeFrame(.{ .kind = .event, .stream_id = 9 }, &payload);
    const observed_range = rangeFor(payload.len);
    const candidate_before = candidate;
    const header_before = candidate.frame.header;
    const payload_before = payload;
    const range_before = observed_range;

    try std.testing.expect(classifyExternalRx(
        &candidate,
        testIdentity(),
        9,
        null,
    ) == .event_candidate);
    try std.testing.expectEqualDeep(candidate_before.frame.header, candidate.frame.header);
    try std.testing.expectEqualDeep(header_before, candidate.frame.header);
    try std.testing.expectEqualSlices(u8, &payload_before, &payload);
    try std.testing.expectEqualDeep(range_before, observed_range);

    try std.testing.expect(classifyExternalRx(
        &candidate,
        testIdentity(),
        8,
        null,
    ) == .protocol_terminal);
    try std.testing.expectEqualDeep(candidate_before.frame.header, candidate.frame.header);
    try std.testing.expectEqualSlices(u8, &payload_before, &payload);
}

test "external RX event candidate uses the common decoder exactly once" {
    var payload =
        "{\"event\":\"snapshot.invalidated\"}".*;
    const event_frame = makeFrame(.{ .kind = .event, .stream_id = 7 }, &payload);
    const wire = classifyExternalRx(&event_frame, testIdentity(), 7, null);
    try std.testing.expect(wire == .event_candidate);

    const Observer = struct {
        fn count(context: *anyopaque) void {
            const value: *usize = @ptrCast(@alignCast(context));
            value.* += 1;
        }
    };
    var parse_count: usize = 0;
    const semantic = classifyEventCandidate(
        .{ .runtime_id = 0xaa, .stream_id = 7 },
        .{ .role = .controller, .generation = .{ .tracked = 4 } },
        protocol.version_major,
        .supported,
        &event_frame,
        wire.event_candidate,
        .{ .context = &parse_count, .on_parse = Observer.count },
    );
    try std.testing.expect(semantic == .accepted);
    try std.testing.expect(semantic.accepted == .invalidated);
    try std.testing.expectEqual(@as(usize, 1), parse_count);

    var forged = wire.event_candidate;
    forged.range.end_absolute -= 1;
    try std.testing.expect(classifyEventCandidate(
        .{ .runtime_id = 0xaa, .stream_id = 7 },
        .{ .role = .controller, .generation = .{ .tracked = 4 } },
        protocol.version_major,
        .supported,
        &event_frame,
        forged,
        .{ .context = &parse_count, .on_parse = Observer.count },
    ) == .protocol_terminal);
    try std.testing.expectEqual(@as(usize, 1), parse_count);

    forged = wire.event_candidate;
    forged.range.start_absolute += 17;
    forged.range.end_absolute += 17;
    try std.testing.expect(classifyEventCandidate(
        .{ .runtime_id = 0xaa, .stream_id = 7 },
        .{ .role = .controller, .generation = .{ .tracked = 4 } },
        protocol.version_major,
        .supported,
        &event_frame,
        forged,
        .{ .context = &parse_count, .on_parse = Observer.count },
    ) == .protocol_terminal);
    try std.testing.expectEqual(@as(usize, 1), parse_count);

    var other_payload =
        "{\"event\":\"snapshot.invalidated\"}".*;
    other_payload[other_payload.len - 2] = 'X';
    const other_frame = makeFrame(.{ .kind = .event, .stream_id = 7 }, &other_payload);
    const other_wire = classifyExternalRx(&other_frame, testIdentity(), 7, null);
    try std.testing.expect(other_wire == .event_candidate);
    try std.testing.expect(classifyEventCandidate(
        .{ .runtime_id = 0xaa, .stream_id = 7 },
        .{ .role = .controller, .generation = .{ .tracked = 4 } },
        protocol.version_major,
        .supported,
        &event_frame,
        other_wire.event_candidate,
        .{ .context = &parse_count, .on_parse = Observer.count },
    ) == .protocol_terminal);
    try std.testing.expectEqual(@as(usize, 1), parse_count);
}
