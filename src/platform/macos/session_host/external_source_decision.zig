//! Allocation-free macOS validation adapter and outer decision for one sealed external Client
//! source fold.
//!
//! The public entry re-folds the live Client before the private pure derivation chooses one
//! exhaustive branch. This module does not own metadata backing, a screen plan, ledger mutation,
//! recovery deadline, or pump lifecycle.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const client_mod = @import("client.zig");
const compatibility = @import("compatibility.zig");
const limits = @import("external_inbox_limits.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const request_id_state = @import("request_id_state.zig");
const runtime_event_reducer = @import("runtime_event_reducer.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");

pub const TerminalReason = union(enum) {
    fold: runtime_event_reducer.TerminalReason,
    request_id_zero,
    inconsistent_fold,
};

pub const MetadataWinner = union(enum) {
    unsupported,
    unavailable,
    initial: runtime_event_reducer.MetadataCandidate,
    event: runtime_event_reducer.MetadataCandidate,
};

pub const LiveState = struct {
    authority: client_mod.FoldAuthority,
    metadata: MetadataWinner,
    resize: ?runtime_event_reducer.ResizeCandidate,
};

pub const Verdict = union(enum) {
    terminal: TerminalReason,
    ended,
    revoked: LiveState,
    host_recovery,
    client_recovery,
    adopted: LiveState,
};

pub const PreparedSourceDecision = struct {
    fold: client_mod.ExternalAdoptionFoldResult,
    raw_next_request_id: u64,
    request_state: ?request_id_state.State,
    verdict: Verdict,
};

pub fn decide(
    client: *const client_mod.Client,
    input: client_mod.ExternalAdoptionFoldInput,
    fold: client_mod.ExternalAdoptionFoldResult,
    scratch: *client_mod.ExternalSourceOwnerRangeScratch,
) PreparedSourceDecision {
    if (!client.externalAdoptionFoldResultMatches(input, fold, scratch))
        return inconsistentDecision(fold);
    return decideValidated(fold);
}

pub fn decisionMatches(
    client: *const client_mod.Client,
    input: client_mod.ExternalAdoptionFoldInput,
    decision: PreparedSourceDecision,
    scratch: *client_mod.ExternalSourceOwnerRangeScratch,
) bool {
    if (!client.externalAdoptionFoldResultMatches(
        input,
        decision.fold,
        scratch,
    )) return false;
    return decisionDerivedEql(decision, decideValidated(decision.fold));
}

fn inconsistentDecision(
    fold: client_mod.ExternalAdoptionFoldResult,
) PreparedSourceDecision {
    return .{
        .fold = fold,
        .raw_next_request_id = fold.source_seal.raw_next_request_id,
        .request_state = request_id_state.State.fromNext(
            fold.source_seal.raw_next_request_id,
        ) catch null,
        .verdict = .{ .terminal = .inconsistent_fold },
    };
}

fn decideValidated(
    fold: client_mod.ExternalAdoptionFoldResult,
) PreparedSourceDecision {
    var decision = PreparedSourceDecision{
        .fold = fold,
        .raw_next_request_id = fold.source_seal.raw_next_request_id,
        .request_state = null,
        .verdict = .{ .terminal = .inconsistent_fold },
    };
    decision.request_state = request_id_state.State.fromNext(
        decision.raw_next_request_id,
    ) catch null;
    switch (fold.outcome) {
        .terminal => |reason| {
            decision.verdict = .{ .terminal = .{ .fold = reason } };
            return decision;
        },
        else => {},
    }
    if (decision.request_state == null) {
        decision.verdict = .{ .terminal = .request_id_zero };
        return decision;
    }
    switch (fold.outcome) {
        .terminal => unreachable,
        .ended => decision.verdict = .ended,
        .revoked => |state| decision.verdict = if (liveState(fold, state)) |live|
            .{ .revoked = live }
        else
            .{ .terminal = .inconsistent_fold },
        .invalidated => decision.verdict = .host_recovery,
        .adopted => |state| {
            if (fold.source_seal.screen_source_count > limits.max_items or
                fold.source_seal.screen_payload_bytes > limits.max_bytes)
            {
                decision.verdict = .client_recovery;
                return decision;
            }
            decision.verdict = if (liveState(fold, state)) |live|
                .{ .adopted = live }
            else
                .{ .terminal = .inconsistent_fold };
        },
    }
    return decision;
}

fn liveState(
    fold: client_mod.ExternalAdoptionFoldResult,
    state: runtime_event_reducer.ReducedState,
) ?LiveState {
    if (fold.outcome == .revoked) {
        if (state.authority.role != .observer) return null;
        const generation = switch (state.authority.generation) {
            .untracked => return null,
            .tracked => |generation| generation,
        };
        if (generation == 0) return null;
    }
    return .{
        .authority = state.authority,
        .metadata = metadataWinner(fold, state.metadata) orelse return null,
        .resize = if (state.resize) |candidate| blk: {
            if (candidate.ordinal >= fold.source_seal.event_count or
                !runtime_event_reducer.resizeCandidateIsCoherent(candidate))
                return null;
            break :blk candidate;
        } else null,
    };
}

fn decisionDerivedEql(
    a: PreparedSourceDecision,
    b: PreparedSourceDecision,
) bool {
    if (a.raw_next_request_id != b.raw_next_request_id or
        !std.meta.eql(a.request_state, b.request_state) or
        std.meta.activeTag(a.verdict) != std.meta.activeTag(b.verdict))
        return false;
    return switch (a.verdict) {
        .terminal => |reason| std.meta.eql(reason, b.verdict.terminal),
        .ended, .host_recovery, .client_recovery => true,
        .revoked => |state| liveStateEql(state, b.verdict.revoked),
        .adopted => |state| liveStateEql(state, b.verdict.adopted),
    };
}

fn liveStateEql(a: LiveState, b: LiveState) bool {
    if (!std.meta.eql(a.authority, b.authority) or
        !metadataWinnerEql(a.metadata, b.metadata) or
        ((a.resize == null) != (b.resize == null)))
        return false;
    if (a.resize) |candidate|
        return runtime_event_reducer.resizeCandidateEql(candidate, b.resize.?);
    return true;
}

fn metadataWinnerEql(a: MetadataWinner, b: MetadataWinner) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .unsupported, .unavailable => true,
        .initial => |candidate| runtime_event_reducer.metadataCandidateEql(
            candidate,
            b.initial,
        ),
        .event => |candidate| runtime_event_reducer.metadataCandidateEql(
            candidate,
            b.event,
        ),
    };
}

fn metadataWinner(
    fold: client_mod.ExternalAdoptionFoldResult,
    candidate: ?runtime_event_reducer.MetadataCandidate,
) ?MetadataWinner {
    const binding = fold.binding_seal.initial_metadata;
    const value = candidate orelse return switch (binding) {
        .unsupported => .unsupported,
        .unavailable => .unavailable,
        .current => null,
    };
    return switch (value.origin) {
        .initial => {
            const current = switch (binding) {
                .current => |current| current,
                .unsupported, .unavailable => return null,
            };
            if (current.seed_address != current.seal.seed_addr or
                current.seal.tag != .current)
                return null;
            const revision = switch (value.proof) {
                .initial => |proof| proof.revision,
                .event => return null,
            };
            const semantic_digest = switch (value.semantic_digest) {
                .initial_seed => |digest| digest,
                .event => return null,
            };
            if (revision != current.seal.revision or
                !std.mem.eql(u8, &value.raw_digest, &current.seal.raw_digest) or
                !std.mem.eql(
                    u8,
                    &semantic_digest,
                    &current.seal.semantic_digest,
                ))
                return null;
            return .{ .initial = value };
        },
        .event => |ordinal| {
            if (ordinal >= fold.source_seal.event_count) return null;
            switch (binding) {
                .unsupported => return null,
                .unavailable, .current => {},
            }
            const preflight = switch (value.proof) {
                .initial => return null,
                .event => |preflight| preflight,
            };
            const metadata = switch (preflight.event) {
                .metadata => |metadata| metadata,
                else => return null,
            };
            const semantic_digest = switch (value.semantic_digest) {
                .initial_seed => return null,
                .event => |digest| digest,
            };
            if (!std.mem.eql(u8, &value.raw_digest, &preflight.raw_digest) or
                !std.mem.eql(
                    u8,
                    &semantic_digest,
                    &metadata.semantic_digest,
                ))
                return null;
            return .{ .event = value };
        },
    };
}

fn testFold(
    outcome: runtime_event_reducer.Outcome,
    next_request_id: u64,
    screen_count: usize,
    screen_bytes: usize,
) client_mod.ExternalAdoptionFoldResult {
    return .{
        .binding_seal = .{
            .client_address = 1,
            .attach_instance_id = 2,
            .identity = .{ .runtime_id = 3, .stream_id = 4 },
            .initial_authority = .{
                .role = .observer,
                .generation = .untracked,
            },
            .initial_metadata = .unsupported,
        },
        .source_seal = .{
            .client_address = 1,
            .target_stream = 4,
            .attach_instance_id = 2,
            .raw_next_request_id = next_request_id,
            .raw_last_success_request_id = 0,
            .screen_source_count = screen_count,
            .screen_payload_bytes = screen_bytes,
            .event_count = 0,
            .event_payload_bytes = 0,
            .digest = [_]u8{0} ** @sizeOf(runtime_event_wire.Digest),
        },
        .outcome = outcome,
    };
}

fn testState() runtime_event_reducer.ReducedState {
    return .{
        .authority = .{ .role = .observer, .generation = .untracked },
    };
}

fn testRevokedState() runtime_event_reducer.ReducedState {
    return .{
        .authority = .{
            .role = .observer,
            .generation = .{ .tracked = 1 },
        },
    };
}

test "decision precedence is fold terminal then request zero then actions and screen cap" {
    const malformed = runtime_event_reducer.TerminalReason{
        .source = .malformed,
    };
    const terminal_zero = decideValidated(testFold(
        .{ .terminal = malformed },
        0,
        limits.max_items + 1,
        limits.max_bytes + 1,
    ));
    try std.testing.expect(terminal_zero.verdict == .terminal);
    try std.testing.expect(terminal_zero.verdict.terminal == .fold);
    try std.testing.expect(terminal_zero.verdict.terminal.fold == .source);
    try std.testing.expect(terminal_zero.request_state == null);
    const terminal_nonzero = decideValidated(testFold(
        .{ .terminal = malformed },
        9,
        0,
        0,
    ));
    try std.testing.expect(terminal_nonzero.verdict == .terminal);
    try std.testing.expect(std.meta.eql(
        terminal_nonzero.request_state.?,
        request_id_state.State{ .available = 9 },
    ));

    inline for (.{
        runtime_event_reducer.Outcome.ended,
        runtime_event_reducer.Outcome{ .revoked = testState() },
        runtime_event_reducer.Outcome{ .invalidated = testState() },
        runtime_event_reducer.Outcome{ .adopted = testState() },
    }) |outcome| {
        const zero = decideValidated(testFold(outcome, 0, 0, 0));
        try std.testing.expect(zero.verdict == .terminal);
        try std.testing.expect(zero.verdict.terminal == .request_id_zero);
    }

    const ended = decideValidated(testFold(.ended, 1, limits.max_items + 1, 0));
    try std.testing.expect(ended.verdict == .ended);
    const revoked = decideValidated(testFold(
        .{ .revoked = testRevokedState() },
        1,
        limits.max_items + 1,
        0,
    ));
    try std.testing.expect(revoked.verdict == .revoked);
    const invalidated = decideValidated(testFold(
        .{ .invalidated = testState() },
        1,
        limits.max_items + 1,
        limits.max_bytes + 1,
    ));
    try std.testing.expect(invalidated.verdict == .host_recovery);
    const client_recovery = decideValidated(testFold(
        .{ .adopted = testState() },
        1,
        limits.max_items + 1,
        0,
    ));
    try std.testing.expect(client_recovery.verdict == .client_recovery);
}

test "decision preserves exact request and tagged authority boundaries" {
    const ordinary = decideValidated(testFold(
        .{ .adopted = testState() },
        1,
        limits.max_items,
        limits.max_bytes,
    ));
    try std.testing.expect(ordinary.verdict == .adopted);
    try std.testing.expect(std.meta.eql(
        ordinary.request_state.?,
        request_id_state.State{ .available = 1 },
    ));
    try std.testing.expect(ordinary.verdict.adopted.metadata == .unsupported);

    var tracked = testState();
    tracked.authority = .{
        .role = .observer,
        .generation = .{ .tracked = 9 },
    };
    const maximum = decideValidated(testFold(
        .{ .revoked = tracked },
        std.math.maxInt(u64),
        0,
        0,
    ));
    try std.testing.expect(maximum.verdict == .revoked);
    try std.testing.expect(maximum.request_state.? == .last_available);
    try std.testing.expect(std.meta.eql(
        maximum.verdict.revoked.authority,
        tracked.authority,
    ));

    var impossible_revoke = tracked;
    impossible_revoke.authority.role = .controller;
    const impossible = decideValidated(testFold(
        .{ .revoked = impossible_revoke },
        1,
        0,
        0,
    ));
    try std.testing.expect(impossible.verdict == .terminal);
    try std.testing.expect(impossible.verdict.terminal == .inconsistent_fold);

    const bytes_over = decideValidated(testFold(
        .{ .adopted = testState() },
        1,
        limits.max_items,
        limits.max_bytes + 1,
    ));
    try std.testing.expect(bytes_over.verdict == .client_recovery);
}

test "decision rejects forged metadata binding and leaves input unchanged" {
    var fold = testFold(.{ .adopted = testState() }, 7, 0, 0);
    fold.binding_seal.initial_metadata = .unavailable;
    const snapshot = fold;
    const decision = decideValidated(fold);
    try std.testing.expect(decision.verdict == .adopted);
    try std.testing.expect(decision.verdict.adopted.metadata == .unavailable);
    try std.testing.expect(std.meta.eql(fold, snapshot));

    var forged_state = testState();
    forged_state.metadata = .{
        .origin = .initial,
        .raw_digest = [_]u8{0} ** @sizeOf(runtime_event_wire.Digest),
        .semantic_digest = .{
            .initial_seed = [_]u8{0} ** @sizeOf(runtime_event_wire.Digest),
        },
        .proof = .{ .initial = .{ .revision = 1 } },
    };
    fold.outcome = .{ .adopted = forged_state };
    const forged = decideValidated(fold);
    try std.testing.expect(forged.verdict == .terminal);
    try std.testing.expect(forged.verdict.terminal == .inconsistent_fold);
}

test "decision derives initial and event metadata winners only from sealed fold evidence" {
    const initial_raw = [_]u8{0x11} ** @sizeOf(runtime_event_wire.Digest);
    const initial_semantic = [_]u8{0x22} ** @sizeOf(runtime_event_wire.Digest);
    var initial_state = testState();
    initial_state.metadata = .{
        .origin = .initial,
        .raw_digest = initial_raw,
        .semantic_digest = .{ .initial_seed = initial_semantic },
        .proof = .{ .initial = .{ .revision = 5 } },
    };
    var initial_fold = testFold(.{ .adopted = initial_state }, 1, 0, 0);
    initial_fold.binding_seal.initial_metadata = .{ .current = .{
        .seed_address = 9,
        .seal = .{
            .seed_addr = 9,
            .tag = .current,
            .dto_addr = 10,
            .allocator_ptr_addr = 11,
            .allocator_vtable_addr = 12,
            .backing_present = true,
            .backing_addr = 13,
            .backing_len = 14,
            .revision = 5,
            .raw_digest = initial_raw,
            .semantic_digest = initial_semantic,
        },
    } };
    initial_fold.source_seal.event_count = 1;
    const initial = decideValidated(initial_fold);
    try std.testing.expect(initial.verdict == .adopted);
    try std.testing.expect(initial.verdict.adopted.metadata == .initial);
    var forged_initial = initial_fold;
    forged_initial.binding_seal.initial_metadata.current.seal.tag = .unsupported;
    try std.testing.expect(
        decideValidated(forged_initial).verdict.terminal ==
            .inconsistent_fold,
    );
    forged_initial = initial_fold;
    forged_initial.binding_seal.initial_metadata.current.seed_address += 1;
    try std.testing.expect(
        decideValidated(forged_initial).verdict.terminal ==
            .inconsistent_fold,
    );

    const payload =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":false,\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}";
    const accepted = switch (runtime_event_wire.preflightEvent(payload, .{})) {
        .accepted => |accepted| accepted,
        else => return error.TestUnexpectedResult,
    };
    const metadata = switch (accepted.event) {
        .metadata => |metadata| metadata,
        else => return error.TestUnexpectedResult,
    };
    var event_state = testState();
    event_state.metadata = .{
        .origin = .{ .event = 3 },
        .raw_digest = accepted.raw_digest,
        .semantic_digest = .{ .event = metadata.semantic_digest },
        .proof = .{ .event = accepted },
    };
    var event_fold = testFold(.{ .adopted = event_state }, 1, 0, 0);
    event_fold.binding_seal.initial_metadata = .unavailable;
    event_fold.source_seal.event_count = 4;
    const event = decideValidated(event_fold);
    try std.testing.expect(event.verdict == .adopted);
    try std.testing.expect(event.verdict.adopted.metadata == .event);

    var equivalent = event_fold;
    equivalent.outcome.adopted.metadata.?.proof.event.event.metadata
        .processes[runtime_event_wire.max_process_entries - 1].pid = 999;
    try std.testing.expect(runtime_event_reducer.outcomeEql(
        event_fold.outcome,
        equivalent.outcome,
    ));

    var ordinal_forged = event_fold;
    ordinal_forged.outcome.adopted.metadata.?.origin = .{ .event = 4 };
    const invalid_ordinal = decideValidated(ordinal_forged);
    try std.testing.expect(invalid_ordinal.verdict == .terminal);
    try std.testing.expect(
        invalid_ordinal.verdict.terminal == .inconsistent_fold,
    );

    event_state.metadata.?.semantic_digest.event[0] ^= 1;
    event_fold.outcome = .{ .adopted = event_state };
    const forged_event = decideValidated(event_fold);
    try std.testing.expect(forged_event.verdict == .terminal);
    try std.testing.expect(forged_event.verdict.terminal == .inconsistent_fold);

    var mutated_decision = event;
    mutated_decision.verdict.adopted.authority = .{
        .role = .controller,
        .generation = .{ .tracked = 99 },
    };
    try std.testing.expect(!decisionDerivedEql(
        mutated_decision,
        decideValidated(event.fold),
    ));
}

test "public decision rejects cross-swapped fold fields before branch selection" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = c.close(fds[1]);
    var client = client_mod.Client{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .wire_major = protocol.version_major,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    try client.enterExternalMode();
    client.ownership = .external_pump;
    client.connection_profile = .cli_attach;
    client.compatibility_profile =
        compatibility.profileForMajor(protocol.version_major).?;
    client.attach_instance_id = 77;

    const input = client_mod.ExternalAdoptionFoldInput{
        .identity = .{ .runtime_id = 0xaa, .stream_id = 7 },
        .authority = .{ .role = .observer, .generation = .untracked },
        .initial_metadata = .unsupported,
    };
    var scratch: client_mod.ExternalSourceOwnerRangeScratch = .{};
    const fold = try client.foldExternalAdoptionSource(input, &scratch);
    const valid = decide(&client, input, fold, &scratch);
    try std.testing.expect(valid.verdict == .adopted);
    try std.testing.expect(decisionMatches(
        &client,
        input,
        valid,
        &scratch,
    ));

    var outcome_swap = fold;
    outcome_swap.outcome = .ended;
    const rejected_outcome = decide(
        &client,
        input,
        outcome_swap,
        &scratch,
    );
    try std.testing.expect(rejected_outcome.verdict == .terminal);
    try std.testing.expect(
        rejected_outcome.verdict.terminal == .inconsistent_fold,
    );

    var source_swap = fold;
    source_swap.source_seal.attach_instance_id += 1;
    const rejected_source = decide(
        &client,
        input,
        source_swap,
        &scratch,
    );
    try std.testing.expect(rejected_source.verdict == .terminal);
    try std.testing.expect(
        rejected_source.verdict.terminal == .inconsistent_fold,
    );

    var mutated_decision = valid;
    mutated_decision.verdict = .ended;
    try std.testing.expect(!decisionMatches(
        &client,
        input,
        mutated_decision,
        &scratch,
    ));
}
