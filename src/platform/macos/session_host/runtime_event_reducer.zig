//! Allocation-free FIFO reduction for runtime events.
//!
//! This leaf owns no Client, allocator, ledger, or pump lifecycle. It classifies each exact frame
//! with the authority advanced by the preceding FIFO item, issues ordinals itself, and returns no
//! borrowed payload. Same-revision metadata equality temporarily resolves the earlier source by
//! ordinal during `step`; the resolver result never escapes the call.

const std = @import("std");
const runtime_event_types = @import("runtime_event_types.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");
const resize_wire = @import("resize_wire.zig");

pub const Authority = runtime_event_types.EventAuthorityView;

pub const MetadataOrigin = union(enum) {
    initial,
    event: u32,
};

pub const MetadataProof = union(enum) {
    initial: struct { revision: u64 },
    event: runtime_event_wire.EventPreflight,
};

pub const MetadataSemanticDigest = union(enum) {
    initial_seed: runtime_event_wire.Digest,
    event: runtime_event_wire.Digest,
};

pub const MetadataCandidate = struct {
    origin: MetadataOrigin,
    raw_digest: runtime_event_wire.Digest,
    semantic_digest: MetadataSemanticDigest,
    proof: MetadataProof,

    fn revision(self: MetadataCandidate) ?u64 {
        return switch (self.proof) {
            .initial => |value| value.revision,
            .event => |preflight| switch (preflight.event) {
                .metadata => |value| value.revision,
                else => null,
            },
        };
    }
};

pub const ResizeCandidate = struct {
    ordinal: u32,
    raw_digest: runtime_event_wire.Digest,
    semantic_digest: runtime_event_wire.Digest,
    preflight: runtime_event_wire.EventPreflight,
    event: resize_wire.Event,
};

pub const TerminalReason = union(enum) {
    source: runtime_event_types.Violation,
    transport: TransportViolation,
    metadata_equivocation,
    resize_equivocation,
    stale_metadata_candidate,
    ordinal_exhausted,
    ordinal_mismatch,
    moved_accumulator,
};

pub const TransportViolation = enum {
    screen_structure,
    event_cache_contamination,
    event_counter_mismatch,
};

pub const ReducedState = struct {
    authority: Authority,
    metadata: ?MetadataCandidate = null,
    resize: ?ResizeCandidate = null,
};

pub const Outcome = union(enum) {
    terminal: TerminalReason,
    ended,
    revoked: ReducedState,
    invalidated: ReducedState,
    adopted: ReducedState,
};

pub const InitialMetadataSeed = struct {
    revision: u64,
    raw_digest: runtime_event_wire.Digest,
    semantic_digest: runtime_event_wire.Digest,

    pub fn candidate(self: InitialMetadataSeed) MetadataCandidate {
        return .{
            .origin = .initial,
            .raw_digest = self.raw_digest,
            .semantic_digest = .{ .initial_seed = self.semantic_digest },
            .proof = .{ .initial = .{ .revision = self.revision } },
        };
    }
};

pub const MetadataComparison = enum {
    equal,
    different,
    stale,
};

pub const FrameInput = struct {
    identity: runtime_event_types.EventIdentity,
    preflight: runtime_event_types.EventPreflightView,
    frame: runtime_event_types.EventFrameView,
};

pub const Accumulator = struct {
    saved_self_addr: usize = 0,
    state: ReducedState = .{
        .authority = .{ .role = .observer, .generation = .untracked },
    },
    first_terminal: ?TerminalReason = null,
    next_ordinal: u32 = 0,
    saw_ended: bool = false,
    saw_revoked: bool = false,
    saw_invalidated: bool = false,

    pub fn initInPlace(
        out: *Accumulator,
        authority: Authority,
    ) void {
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .state = .{
                .authority = authority,
            },
        };
    }

    pub fn initWithMetadataInPlace(
        out: *Accumulator,
        authority: Authority,
        initial_metadata: InitialMetadataSeed,
        context: anytype,
        comptime validate_initial: fn (
            @TypeOf(context),
            InitialMetadataSeed,
        ) bool,
    ) void {
        initInPlace(out, authority);
        if (!validate_initial(context, initial_metadata)) {
            out.recordTerminal(.stale_metadata_candidate);
            return;
        }
        out.state.metadata = initial_metadata.candidate();
    }

    /// Classifies and records one FIFO item. `compare_metadata` must rebind the current candidate
    /// to the sealed initial DTO or exact event ordinal and borrows source bytes only during the
    /// callback.
    pub fn stepAt(
        self: *Accumulator,
        context: anytype,
        comptime compare_metadata: fn (
            @TypeOf(context),
            MetadataCandidate,
            []const u8,
            runtime_event_wire.EventPreflight,
        ) MetadataComparison,
        expected_ordinal: u32,
        input: FrameInput,
    ) void {
        if (self.saved_self_addr != @intFromPtr(self)) {
            self.recordTerminal(.moved_accumulator);
            return;
        }
        const ordinal = self.next_ordinal;
        if (expected_ordinal != ordinal) {
            self.recordTerminal(.ordinal_mismatch);
            return;
        }
        self.next_ordinal = std.math.add(u32, ordinal, 1) catch {
            self.recordTerminal(.ordinal_exhausted);
            return;
        };
        const classification = runtime_event_types.classifyEventView(
            input.identity,
            self.state.authority,
            input.preflight,
            input.frame,
        );
        switch (classification) {
            .violation => |value| self.recordTerminal(.{ .source = value }),
            .accepted => |event| switch (event) {
                .ended => self.saw_ended = true,
                .invalidated => self.saw_invalidated = true,
                .revoked => |generation| {
                    self.saw_revoked = true;
                    self.state.authority = .{
                        .role = .observer,
                        .generation = .{ .tracked = generation },
                    };
                },
                .resized => |value| self.reduceResize(
                    input.preflight,
                    value,
                    ordinal,
                ),
                .metadata => |validated| self.reduceMetadata(
                    context,
                    compare_metadata,
                    input.frame.payload,
                    validated.preflight(),
                    ordinal,
                ),
            },
        }
    }

    /// Applies precedence only after the complete FIFO has been visited.
    pub fn finalize(self: *const Accumulator) Outcome {
        if (self.saved_self_addr != @intFromPtr(self))
            return .{ .terminal = .moved_accumulator };
        if (self.first_terminal) |reason| return .{ .terminal = reason };
        if (self.saw_ended) return .ended;
        if (self.saw_revoked) return .{ .revoked = self.state };
        if (self.saw_invalidated) return .{ .invalidated = self.state };
        return .{ .adopted = self.state };
    }

    pub fn recordTransportViolation(
        self: *Accumulator,
        violation: TransportViolation,
    ) void {
        if (self.saved_self_addr != @intFromPtr(self)) {
            self.recordTerminal(.moved_accumulator);
            return;
        }
        self.recordTerminal(.{ .transport = violation });
    }

    fn recordTerminal(self: *Accumulator, reason: TerminalReason) void {
        if (self.first_terminal) |current| {
            if (terminalRank(reason) < terminalRank(current))
                self.first_terminal = reason;
            return;
        }
        self.first_terminal = reason;
    }

    fn reduceResize(
        self: *Accumulator,
        preflight: runtime_event_types.EventPreflightView,
        value: resize_wire.Event,
        ordinal: u32,
    ) void {
        const accepted = switch (preflight.verdict) {
            .accepted => |event| event,
            else => {
                self.recordTerminal(.{ .source = .stale_preflight });
                return;
            },
        };
        const current = self.state.resize orelse {
            self.state.resize = resizeCandidate(ordinal, accepted, value);
            return;
        };
        if (value.resize_generation < current.event.resize_generation) return;
        if (value.resize_generation == current.event.resize_generation) {
            if (!std.meta.eql(value, current.event))
                self.recordTerminal(.resize_equivocation);
            return;
        }
        self.state.resize = resizeCandidate(ordinal, accepted, value);
    }

    fn reduceMetadata(
        self: *Accumulator,
        context: anytype,
        comptime compare_metadata: fn (
            @TypeOf(context),
            MetadataCandidate,
            []const u8,
            runtime_event_wire.EventPreflight,
        ) MetadataComparison,
        payload: []const u8,
        preflight: runtime_event_wire.EventPreflight,
        ordinal: u32,
    ) void {
        const value = switch (preflight.event) {
            .metadata => |metadata| metadata,
            else => {
                self.recordTerminal(.{ .source = .stale_preflight });
                return;
            },
        };
        const next = MetadataCandidate{
            .origin = .{ .event = ordinal },
            .raw_digest = preflight.raw_digest,
            .semantic_digest = .{ .event = value.semantic_digest },
            .proof = .{ .event = preflight },
        };
        const current = self.state.metadata orelse {
            self.state.metadata = next;
            return;
        };
        const current_revision = current.revision() orelse {
            self.recordTerminal(.stale_metadata_candidate);
            return;
        };
        if (value.revision < current_revision) return;
        if (value.revision == current_revision) {
            switch (compare_metadata(context, current, payload, preflight)) {
                .equal => {},
                .different => self.recordTerminal(.metadata_equivocation),
                .stale => self.recordTerminal(.stale_metadata_candidate),
            }
            return;
        }
        self.state.metadata = next;
    }
};

fn terminalRank(reason: TerminalReason) u8 {
    return switch (reason) {
        .transport => |value| switch (value) {
            .screen_structure => 1,
            .event_cache_contamination, .event_counter_mismatch => 0,
        },
        .source,
        .metadata_equivocation,
        .resize_equivocation,
        .stale_metadata_candidate,
        .ordinal_exhausted,
        .ordinal_mismatch,
        .moved_accumulator,
        => 0,
    };
}

fn resizeCandidate(
    ordinal: u32,
    preflight: runtime_event_wire.EventPreflight,
    event: resize_wire.Event,
) ResizeCandidate {
    return .{
        .ordinal = ordinal,
        .raw_digest = preflight.raw_digest,
        .semantic_digest = resizeSemanticDigest(event),
        .preflight = preflight,
        .event = event,
    };
}

fn resizeSemanticDigest(event: resize_wire.Event) runtime_event_wire.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("maru.session-host.resize-semantic.v1\x00");
    inline for (.{
        event.runtime_id,
        event.cols,
        event.rows,
        event.resize_generation,
    }) |value| {
        var bytes: [@sizeOf(@TypeOf(value))]u8 = undefined;
        std.mem.writeInt(@TypeOf(value), &bytes, value, .little);
        hasher.update(&bytes);
    }
    var digest: runtime_event_wire.Digest = undefined;
    hasher.final(&digest);
    return digest;
}

const test_major: u16 = 7;
const test_identity: runtime_event_types.EventIdentity = .{
    .runtime_id = 0xaa,
    .stream_id = 7,
};

const TestSources = struct {
    payloads: []const []const u8,
    initial: ?[]const u8 = null,
    initial_view: ?runtime_event_wire.MetadataView = null,

    fn compare(
        self: *const TestSources,
        current: MetadataCandidate,
        next_payload: []const u8,
        next_preflight: runtime_event_wire.EventPreflight,
    ) MetadataComparison {
        const current_payload = switch (current.origin) {
            .initial => self.initial orelse return .stale,
            .event => |ordinal| if (ordinal < self.payloads.len)
                self.payloads[ordinal]
            else
                return .stale,
        };
        if (!std.mem.eql(
            u8,
            &runtime_event_wire.payloadDigest(current_payload),
            &current.raw_digest,
        )) return .stale;
        const current_view = switch (current.proof) {
            .initial => self.initial_view orelse return .stale,
            .event => |preflight| switch (preflight.event) {
                .metadata => |value| value,
                else => return .stale,
            },
        };
        const next = switch (next_preflight.event) {
            .metadata => |value| value,
            else => return .stale,
        };
        return if (runtime_event_wire.metadataSemanticEqlExact(
            current_payload,
            &current_view,
            next_payload,
            &next,
        )) .equal else .different;
    }

    fn validateInitial(
        self: *const TestSources,
        seed: InitialMetadataSeed,
    ) bool {
        const payload = self.initial orelse return false;
        const view = self.initial_view orelse return false;
        return seed.revision == view.revision and
            std.mem.eql(
                u8,
                &seed.raw_digest,
                &runtime_event_wire.payloadDigest(payload),
            ) and
            std.mem.eql(
                u8,
                &seed.semantic_digest,
                &view.semantic_digest,
            );
    }
};

fn testInput(payload: []const u8) FrameInput {
    return .{
        .identity = test_identity,
        .preflight = .{
            .expected_major = test_major,
            .metadata_support = .supported,
            .verdict = runtime_event_wire.preflightEvent(payload, .{}),
        },
        .frame = .{
            .major = test_major,
            .kind = .event,
            .stream_id = test_identity.stream_id,
            .request_id = 0,
            .flags = 0,
            .payload_len = @intCast(payload.len),
            .payload = payload,
        },
    };
}

fn metadataPayload(
    comptime revision: u64,
    comptime cwd: []const u8,
) []const u8 {
    return std.fmt.comptimePrint(
        "{{\"event\":\"runtime.metadata\",\"metadata_revision\":{d},\"metadata\":{{" ++
            "\"cwd\":\"{s}\",\"window_title\":\"work\",\"ssh_remote_dest\":null," ++
            "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
            "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2," ++
            "\"cols\":80,\"rows\":24,\"foreground_available\":false," ++
            "\"foreground_pgid\":null,\"processes\":[]}}}}",
        .{ revision, cwd },
    );
}

fn reduce(payloads: []const []const u8, authority: Authority) Outcome {
    var reducer: Accumulator = .{};
    Accumulator.initInPlace(&reducer, authority);
    const sources = TestSources{ .payloads = payloads };
    for (payloads, 0..) |payload, ordinal|
        reducer.stepAt(&sources, TestSources.compare, @intCast(ordinal), testInput(payload));
    return reducer.finalize();
}

test "reducer inspects the whole FIFO before terminal precedence" {
    const authority: Authority = .{ .role = .controller, .generation = .{ .tracked = 3 } };
    const ended = "{\"event\":\"runtime.ended\"}";
    const invalidated = "{\"event\":\"snapshot.invalidated\"}";
    const malformed = "{\"event\":";

    const forward = [_][]const u8{ ended, invalidated, malformed };
    const reverse = [_][]const u8{ malformed, ended, invalidated };
    for ([_][]const []const u8{ &forward, &reverse }) |order| {
        const reason = switch (reduce(order, authority)) {
            .terminal => |value| value,
            else => return error.TestUnexpectedResult,
        };
        switch (reason) {
            .source => |source| try std.testing.expect(source == .malformed),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "reducer keeps the first exact top-priority violation after a full scan" {
    const authority: Authority = .{ .role = .observer, .generation = .untracked };
    const malformed = "{\"event\":";
    const unknown = "{\"event\":\"future.event\"}";
    const resource = "{\"event\":\"runtime.metadata\",\"metadata_revision\":1,\"metadata\":";

    const orders = [_][2][]const u8{
        .{ malformed, unknown },
        .{ unknown, malformed },
        .{ resource, malformed },
    };
    const expected = [_]std.meta.Tag(runtime_event_types.Violation){
        .malformed,
        .unknown_event,
        .malformed,
    };
    for (orders, expected) |order, expected_tag| {
        const reason = switch (reduce(&order, authority)) {
            .terminal => |value| value,
            else => return error.TestUnexpectedResult,
        };
        switch (reason) {
            .source => |source| try std.testing.expectEqual(
                expected_tag,
                std.meta.activeTag(source),
            ),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "reducer binds metadata candidates without exposing payloads" {
    const authority: Authority = .{ .role = .observer, .generation = .{ .tracked = 3 } };
    const revision_n = metadataPayload(7, "/one");
    const revision_n_same = metadataPayload(7, "/one");
    const revision_n_other = metadataPayload(7, "/two");
    const revision_next = metadataPayload(8, "/new");

    const duplicate_payloads = [_][]const u8{ revision_n, revision_n_same };
    const duplicate_state = switch (reduce(&duplicate_payloads, authority)) {
        .adopted => |state| state,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        MetadataOrigin{ .event = 0 },
        duplicate_state.metadata.?.origin,
    );

    const equivocation_payloads = [_][]const u8{ revision_n, revision_n_other };
    try std.testing.expect(reduce(&equivocation_payloads, authority) == .terminal);

    const newer_then_older = [_][]const u8{ revision_next, revision_n_other };
    const latest = switch (reduce(&newer_then_older, authority)) {
        .adopted => |state| state,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        MetadataOrigin{ .event = 0 },
        latest.metadata.?.origin,
    );
}

test "reducer compares an initial metadata seed with FIFO events" {
    const initial_payload = metadataPayload(7, "/one");
    const same = metadataPayload(7, "/one");
    const different = metadataPayload(7, "/two");
    const initial_preflight = switch (runtime_event_wire.preflightEvent(
        initial_payload,
        .{},
    )) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const initial_metadata = switch (initial_preflight.event) {
        .metadata => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const seed = InitialMetadataSeed{
        .revision = initial_metadata.revision,
        .raw_digest = runtime_event_wire.payloadDigest(initial_payload),
        .semantic_digest = initial_metadata.semantic_digest,
    };

    for ([_]struct { payload: []const u8, terminal: bool }{
        .{ .payload = same, .terminal = false },
        .{ .payload = different, .terminal = true },
    }) |case| {
        var reducer: Accumulator = .{};
        const payloads = [_][]const u8{case.payload};
        const sources = TestSources{
            .payloads = &payloads,
            .initial = initial_payload,
            .initial_view = initial_metadata,
        };
        Accumulator.initWithMetadataInPlace(
            &reducer,
            .{ .role = .observer, .generation = .untracked },
            seed,
            &sources,
            TestSources.validateInitial,
        );
        reducer.stepAt(&sources, TestSources.compare, 0, testInput(case.payload));
        try std.testing.expectEqual(case.terminal, reducer.finalize() == .terminal);
    }
}

test "reducer validates initial metadata before no-event older and newer branches" {
    const initial_payload = metadataPayload(7, "/initial");
    const older = metadataPayload(6, "/older");
    const newer = metadataPayload(8, "/newer");
    const initial_preflight = switch (runtime_event_wire.preflightEvent(
        initial_payload,
        .{},
    )) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const initial_metadata = switch (initial_preflight.event) {
        .metadata => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const seed = InitialMetadataSeed{
        .revision = initial_metadata.revision,
        .raw_digest = runtime_event_wire.payloadDigest(initial_payload),
        .semantic_digest = initial_metadata.semantic_digest,
    };

    const cases = [_]struct {
        payloads: []const []const u8,
        expected_origin: MetadataOrigin,
    }{
        .{ .payloads = &.{}, .expected_origin = .initial },
        .{ .payloads = &.{older}, .expected_origin = .initial },
        .{ .payloads = &.{newer}, .expected_origin = .{ .event = 0 } },
    };
    for (cases) |case| {
        const sources = TestSources{
            .payloads = case.payloads,
            .initial = initial_payload,
            .initial_view = initial_metadata,
        };
        var reducer: Accumulator = .{};
        Accumulator.initWithMetadataInPlace(
            &reducer,
            .{ .role = .observer, .generation = .untracked },
            seed,
            &sources,
            TestSources.validateInitial,
        );
        for (case.payloads, 0..) |payload, ordinal|
            reducer.stepAt(
                &sources,
                TestSources.compare,
                @intCast(ordinal),
                testInput(payload),
            );
        const state = switch (reducer.finalize()) {
            .adopted => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(case.expected_origin, state.metadata.?.origin);
    }

    const invalid_sources = TestSources{
        .payloads = &.{},
        .initial = metadataPayload(7, "/different"),
        .initial_view = initial_metadata,
    };
    var invalid: Accumulator = .{};
    Accumulator.initWithMetadataInPlace(
        &invalid,
        .{ .role = .observer, .generation = .untracked },
        seed,
        &invalid_sources,
        TestSources.validateInitial,
    );
    try std.testing.expect(invalid.finalize() == .terminal);
}

test "reducer rejects stale resolved metadata and moved accumulator" {
    const first = metadataPayload(7, "/one");
    const same = metadataPayload(7, "/one");
    const different = metadataPayload(7, "/two");
    const payloads = [_][]const u8{ first, same };
    var reducer: Accumulator = .{};
    Accumulator.initInPlace(
        &reducer,
        .{ .role = .observer, .generation = .{ .tracked = 3 } },
    );
    var sources = TestSources{ .payloads = &payloads };
    reducer.stepAt(&sources, TestSources.compare, 0, testInput(first));
    sources.payloads = &.{different};
    reducer.stepAt(&sources, TestSources.compare, 1, testInput(same));
    try std.testing.expect(reducer.finalize() == .terminal);

    const moved = reducer;
    const moved_reason = switch (moved.finalize()) {
        .terminal => |reason| reason,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(moved_reason == .moved_accumulator);
}

test "reducer applies resize generation and revoke FIFO authority" {
    const resize_n =
        "{\"event\":\"runtime.resized\",\"data\":{\"runtime_id\":" ++
        "\"000000000000000000000000000000aa\",\"cols\":120,\"rows\":40," ++
        "\"resize_generation\":9,\"reason\":\"controller\"}}";
    const resize_n_other =
        "{\"event\":\"runtime.resized\",\"data\":{\"runtime_id\":" ++
        "\"000000000000000000000000000000aa\",\"cols\":121,\"rows\":40," ++
        "\"resize_generation\":9,\"reason\":\"controller\"}}";
    const resize_payloads = [_][]const u8{ resize_n, resize_n_other };
    try std.testing.expect(reduce(
        &resize_payloads,
        .{ .role = .observer, .generation = .{ .tracked = 3 } },
    ) == .terminal);

    const revoked =
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":" ++
        "\"000000000000000000000000000000aa\",\"stream_id\":7," ++
        "\"controller_generation\":4,\"reason\":\"takeover\"}}";
    const revoke_payloads = [_][]const u8{ revoked, revoked };
    const reason = switch (reduce(
        &revoke_payloads,
        .{ .role = .controller, .generation = .{ .tracked = 3 } },
    )) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    switch (reason) {
        .source => |source| switch (source) {
            .authority => |value| try std.testing.expectEqual(
                runtime_event_types.AuthorityViolation.revoked_observer,
                value,
            ),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "reducer keeps exact resize duplicates and latest full state" {
    const resize_9 =
        "{\"event\":\"runtime.resized\",\"data\":{\"runtime_id\":" ++
        "\"000000000000000000000000000000aa\",\"cols\":120,\"rows\":40," ++
        "\"resize_generation\":9,\"reason\":\"controller\"}}";
    const resize_10 =
        "{\"event\":\"runtime.resized\",\"data\":{\"runtime_id\":" ++
        "\"000000000000000000000000000000aa\",\"cols\":130,\"rows\":50," ++
        "\"resize_generation\":10,\"reason\":\"controller\"}}";
    const payloads = [_][]const u8{ resize_9, resize_9, resize_10, resize_9 };
    const state = switch (reduce(
        &payloads,
        .{ .role = .observer, .generation = .untracked },
    )) {
        .adopted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, 10), state.resize.?.event.resize_generation);
    try std.testing.expectEqual(@as(u16, 130), state.resize.?.event.cols);
    try std.testing.expectEqual(@as(u32, 2), state.resize.?.ordinal);
}

test "reducer classifies frame request IDs with its current authority" {
    const ended = "{\"event\":\"runtime.ended\"}";
    var frame = testInput(ended);
    frame.frame.request_id = 1;
    const payloads = [_][]const u8{ended};
    const sources = TestSources{ .payloads = &payloads };
    var reducer: Accumulator = .{};
    Accumulator.initInPlace(&reducer, .{ .role = .observer, .generation = .untracked });
    reducer.stepAt(&sources, TestSources.compare, 0, frame);
    const reason = switch (reducer.finalize()) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    switch (reason) {
        .source => |source| switch (source) {
            .frame => |violation| try std.testing.expectEqual(
                runtime_event_types.FrameViolation.request_id_nonzero,
                violation,
            ),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "reducer ordinal issuance is address-bound and checked" {
    var reducer: Accumulator = .{};
    Accumulator.initInPlace(&reducer, .{ .role = .observer, .generation = .untracked });
    reducer.next_ordinal = std.math.maxInt(u32);
    const ended = "{\"event\":\"runtime.ended\"}";
    const payloads = [_][]const u8{ended};
    const sources = TestSources{ .payloads = &payloads };
    reducer.stepAt(&sources, TestSources.compare, std.math.maxInt(u32), testInput(ended));
    const reason = switch (reducer.finalize()) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(reason == .ordinal_exhausted);
}

test "reducer rejects a caller ordinal that is not its exact next item" {
    var reducer: Accumulator = .{};
    Accumulator.initInPlace(
        &reducer,
        .{ .role = .observer, .generation = .untracked },
    );
    const payload = "{\"event\":\"runtime.ended\"}";
    const sources = TestSources{ .payloads = &.{payload} };
    reducer.stepAt(&sources, TestSources.compare, 1, testInput(payload));
    const reason = switch (reducer.finalize()) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(reason == .ordinal_mismatch);
}
