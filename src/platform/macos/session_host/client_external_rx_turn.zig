//! Transport-independent traversal for already-buffered external-session RX.
//!
//! This leaf owns parser traversal, classified-intent staging, and the partial cursor. It knows
//! neither persistent pump storage nor ledger/socket mechanics. The caller retains the owner
//! transaction and turns this closed scalar result into terminal or aggregate policy.

const std = @import("std");
const builtin = @import("builtin");
const client_external_mode = @import("client_external_mode.zig");
const external_rx_demux = @import("external_rx_demux.zig");
const external_rx_intent = @import("external_rx_intent.zig");
const external_owner_seal = @import("external_owner_seal.zig");
const framing = @import("framing.zig");

const ScratchLifecycle = enum {
    empty,
    ready,
    busy,
    closed,
};

pub const Scratch = struct {
    saved_self_addr: usize = 0,
    generation: u64 = 0,
    lifecycle: ScratchLifecycle = .empty,
    parse: client_external_mode.RxParseScratch = .{},
    intent: external_rx_intent.ExternalRxIntentHandle = .{},
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,

    pub fn initInPlace(out: *Scratch) bool {
        if (out.saved_self_addr != 0 or out.generation != 0 or
            out.lifecycle != .empty)
            return false;
        out.saved_self_addr = @intFromPtr(out);
        out.generation = 1;
        out.lifecycle = .ready;
        out.parse = .{};
        out.intent = .{};
        out.digest = scratchDigest(out);
        return true;
    }

    pub fn resetForNextTurn(out: *Scratch) bool {
        if (!scratchControlValid(out, .closed) or
            out.generation == std.math.maxInt(u64))
            return false;
        out.generation += 1;
        out.lifecycle = .ready;
        out.parse = .{};
        out.digest = scratchDigest(out);
        return true;
    }

    /// An empty intent can mean either the pristine first turn or a prior no-intent turn whose
    /// intent was aborted while this traversal scratch was closed. Normalize both states before
    /// the caller creates the next intent handle so wire batching cannot choose the lifecycle.
    pub fn prepareForIntentCreation(out: *Scratch) bool {
        if (scratchControlValid(out, .ready)) return true;
        return resetForNextTurn(out);
    }

    pub fn closedForOuterTurn(out: *const Scratch) bool {
        const lifecycle_closed =
            scratchControlValid(out, .ready) or
            scratchControlValid(out, .closed);
        return lifecycle_closed and
            client_external_mode.rxParseScratchPristine(&out.parse) and
            external_rx_intent.closedForOuterTurn(&out.intent);
    }

    pub fn retireDestroyedIntent(out: *Scratch) bool {
        if (!scratchControlValid(out, .closed) or
            !external_rx_intent.resetDestroyedForOuterTurn(&out.intent))
            return false;
        out.digest = scratchDigest(out);
        return closedForOuterTurn(out);
    }
};

pub const Input = struct {
    state: *client_external_mode.State,
    parser: *framing.FrameParser,
    scratch: *Scratch,
    authority: external_rx_intent.AuthorityOps,
    payload_guard: *const client_external_mode.PayloadAllocationGuard,
    target_stream_id: u64,
    partial: ?external_rx_demux.ValidatedPartialView,
    parser_progress: ?ParserProgressOps = null,
};

pub const ParserProgressOps = struct {
    context: *anyopaque,
    refresh: *const fn (*anyopaque) bool,
};

pub const Summary = struct {
    rx_bytes: usize = 0,
    rx_frames: usize = 0,
    classified_count: u8 = 0,
    final_readiness: client_external_mode.RxParserReadiness,
    budget_exhausted: bool = false,
    partial: ?external_rx_demux.ValidatedPartialView,
};

pub const FailureReason = enum {
    protocol_error,
    resource_exhausted,
    invariant_failure,
    allocation_quarantined,
};

pub const Failure = struct {
    reason: FailureReason,
    rx_bytes: usize,
    rx_frames: usize,
};

pub const Result = union(enum) {
    no_intents: Summary,
    staged: Summary,
    terminal: Failure,
};

fn scratchDigest(scratch: *const Scratch) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARURXT1");
    writer.writeUsize(scratch.saved_self_addr);
    writer.writeU64(scratch.generation);
    writer.writeU8(@intFromEnum(scratch.lifecycle));
    return writer.finish();
}

fn scratchControlValid(
    scratch: *const Scratch,
    expected: ScratchLifecycle,
) bool {
    return scratch.saved_self_addr == @intFromPtr(scratch) and
        scratch.generation != 0 and
        scratch.lifecycle == expected and
        std.mem.eql(u8, &scratch.digest, &scratchDigest(scratch));
}

fn closeScratch(scratch: *Scratch) bool {
    if (!scratchControlValid(scratch, .busy)) return false;
    scratch.lifecycle = .closed;
    scratch.parse = .{};
    scratch.digest = scratchDigest(scratch);
    return true;
}

fn rangesOverlap(
    left_addr: usize,
    left_len: usize,
    right_addr: usize,
    right_len: usize,
) bool {
    if (left_len == 0 or right_len == 0) return false;
    const left_end = std.math.add(usize, left_addr, left_len) catch return true;
    const right_end = std.math.add(usize, right_addr, right_len) catch return true;
    return left_addr < right_end and right_addr < left_end;
}

const MandatoryPayloadGuard = struct {
    scratch: *Scratch,
    input_addr: usize,
    input_len: usize,
    delegate: *const client_external_mode.PayloadAllocationGuard,
    delegate_context: *anyopaque = undefined,
    delegate_check: *const fn (
        context: *anyopaque,
        allocation_addr: usize,
        allocation_len: usize,
    ) client_external_mode.PayloadAllocationVerdict = undefined,
    ops_descriptor: client_external_mode.PayloadAllocationGuard = undefined,
    saved_self_addr: usize = 0,
    scratch_generation: u64 = 0,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,

    fn seal(self: *MandatoryPayloadGuard) void {
        self.saved_self_addr = @intFromPtr(self);
        self.scratch_generation = self.scratch.generation;
        self.delegate_context = self.delegate.context;
        self.delegate_check = self.delegate.check;
        self.ops_descriptor = .{
            .context = self,
            .check = check,
        };
        self.digest = self.expectedDigest();
    }

    fn expectedDigest(self: *const MandatoryPayloadGuard) external_owner_seal.Digest {
        var writer = external_owner_seal.Writer.init("MARURXG1");
        writer.writeUsize(self.saved_self_addr);
        writer.writeUsize(@intFromPtr(self.scratch));
        writer.writeU64(self.scratch_generation);
        writer.writeUsize(self.input_addr);
        writer.writeUsize(self.input_len);
        writer.writeUsize(@intFromPtr(self.delegate));
        writer.writeUsize(@intFromPtr(self.delegate_context));
        writer.writeUsize(@intFromPtr(self.delegate_check));
        writer.writeUsize(@intFromPtr(&self.ops_descriptor));
        return writer.finish();
    }

    fn valid(self: *const MandatoryPayloadGuard) bool {
        return self.saved_self_addr == @intFromPtr(self) and
            self.scratch_generation == self.scratch.generation and
            self.delegate.context == self.delegate_context and
            self.delegate.check == self.delegate_check and
            @intFromPtr(self.ops_descriptor.context) == @intFromPtr(self) and
            self.ops_descriptor.check == check and
            scratchControlValid(self.scratch, .busy) and
            std.mem.eql(u8, &self.digest, &self.expectedDigest());
    }

    fn check(
        raw: *anyopaque,
        allocation_addr: usize,
        allocation_len: usize,
    ) client_external_mode.PayloadAllocationVerdict {
        const self: *MandatoryPayloadGuard = @ptrCast(@alignCast(raw));
        if (!self.valid() or allocation_addr == 0 or
            rangesOverlap(
                allocation_addr,
                allocation_len,
                @intFromPtr(self.scratch),
                @sizeOf(Scratch),
            ) or rangesOverlap(
            allocation_addr,
            allocation_len,
            @intFromPtr(self),
            @sizeOf(MandatoryPayloadGuard),
        ) or rangesOverlap(
            allocation_addr,
            allocation_len,
            self.input_addr,
            self.input_len,
        ) or rangesOverlap(
            allocation_addr,
            allocation_len,
            @intFromPtr(self.delegate),
            @sizeOf(client_external_mode.PayloadAllocationGuard),
        ))
            return .reject_no_free;
        const verdict = self.delegate_check(
            self.delegate_context,
            allocation_addr,
            allocation_len,
        );
        if (!self.valid()) return .reject_no_free;
        return verdict;
    }

    fn ops(self: *MandatoryPayloadGuard) *const client_external_mode.PayloadAllocationGuard {
        return &self.ops_descriptor;
    }
};

fn closeFailure(
    input: Input,
    reason: FailureReason,
    rx_bytes: usize,
    rx_frames: usize,
) Result {
    const cleaned =
        external_rx_intent.abortAll(&input.scratch.intent) == .cleaned;
    const closed = closeScratch(input.scratch);
    if (!cleaned or !closed)
        return .{ .terminal = .{
            .reason = .invariant_failure,
            .rx_bytes = rx_bytes,
            .rx_frames = rx_frames,
        } };
    return .{ .terminal = .{
        .reason = reason,
        .rx_bytes = rx_bytes,
        .rx_frames = rx_frames,
    } };
}

/// Consumes at most 64 complete buffered frames and never performs socket I/O.
///
/// A terminal return has already closed the intent handle. A staged return leaves the handle as
/// the caller's sole sealed owner for aggregate commit.
pub fn traverseBuffered(input: Input) Result {
    if (!scratchControlValid(input.scratch, .ready)) {
        return .{ .terminal = .{
            .reason = .invariant_failure,
            .rx_bytes = 0,
            .rx_frames = 0,
        } };
    }
    input.scratch.lifecycle = .busy;
    input.scratch.digest = scratchDigest(input.scratch);
    var guard_owner = MandatoryPayloadGuard{
        .scratch = input.scratch,
        .input_addr = @intFromPtr(&input),
        .input_len = @sizeOf(Input),
        .delegate = input.payload_guard,
    };
    guard_owner.seal();
    const mandatory_guard = guard_owner.ops();

    var rx_bytes: usize = 0;
    var rx_frames: usize = 0;
    var classified_count: u8 = 0;
    var budget_exhausted = false;
    var final_readiness: client_external_mode.RxParserReadiness =
        .complete_or_error;
    var partial = input.partial;

    while (rx_frames < external_rx_intent.max_intents) {
        const readiness = client_external_mode.parserReadiness(
            input.state,
            input.parser,
        ) catch {
            return closeFailure(input, .invariant_failure, rx_bytes, rx_frames);
        };
        final_readiness = readiness;
        if (readiness != .complete_or_error) break;
        input.scratch.parse = .{};
        var outcome = client_external_mode.nextOutcomeWithRangeGuarded(
            input.state,
            input.parser,
            &input.scratch.parse,
            mandatory_guard,
        ) catch |err| {
            return closeFailure(input, switch (err) {
                error.Protocol => .protocol_error,
                error.OutOfMemory => .resource_exhausted,
                error.AllocationQuarantined => .allocation_quarantined,
                else => .invariant_failure,
            }, rx_bytes, rx_frames);
        };
        if (input.parser_progress) |progress| {
            if (!progress.refresh(progress.context)) {
                switch (outcome) {
                    .frame => |frame| if (frame.frame.payload.len != 0)
                        input.parser.allocator.free(frame.frame.payload),
                    .incomplete, .skipped => {},
                }
                return closeFailure(
                    input,
                    .invariant_failure,
                    rx_bytes,
                    rx_frames,
                );
            }
        }
        const range = switch (outcome) {
            .incomplete => {
                final_readiness = .incomplete;
                break;
            },
            .skipped => |value| value,
            .frame => |frame| frame.range,
        };
        const span = std.math.sub(
            u64,
            range.end_absolute,
            range.start_absolute,
        ) catch return closeFailure(
            input,
            .invariant_failure,
            rx_bytes,
            rx_frames,
        );
        rx_bytes = std.math.add(
            usize,
            rx_bytes,
            std.math.cast(usize, span) orelse
                return closeFailure(
                    input,
                    .resource_exhausted,
                    rx_bytes,
                    rx_frames,
                ),
        ) catch return closeFailure(
            input,
            .resource_exhausted,
            rx_bytes,
            rx_frames,
        );
        rx_frames += 1;
        switch (outcome) {
            .incomplete, .skipped => {},
            .frame => {
                const intent_index = classified_count;
                const move = external_rx_intent.moveFrame(
                    &input.scratch.intent,
                    &outcome,
                    input.authority,
                    input.target_stream_id,
                    partial,
                );
                input.scratch.parse = .{};
                switch (move) {
                    .classified => {
                        classified_count += 1;
                        switch (external_rx_intent.partialAfterMove(
                            &input.scratch.intent,
                            intent_index,
                        )) {
                            .unchanged => {},
                            .advanced => |after| partial = after,
                            .invalid_state => return closeFailure(
                                input,
                                .invariant_failure,
                                rx_bytes,
                                rx_frames,
                            ),
                        }
                    },
                    // `moveFrame` has already atomically retired every classified payload.
                    .protocol_terminal => {
                        if (!closeScratch(input.scratch))
                            return .{ .terminal = .{
                                .reason = .invariant_failure,
                                .rx_bytes = rx_bytes,
                                .rx_frames = rx_frames,
                            } };
                        return .{ .terminal = .{
                            .reason = .protocol_error,
                            .rx_bytes = rx_bytes,
                            .rx_frames = rx_frames,
                        } };
                    },
                    .capacity => return closeFailure(
                        input,
                        .resource_exhausted,
                        rx_bytes,
                        rx_frames,
                    ),
                    .invalid_source,
                    .authority_drift,
                    .replay,
                    .alias,
                    .poisoned,
                    => return closeFailure(
                        input,
                        .invariant_failure,
                        rx_bytes,
                        rx_frames,
                    ),
                }
            },
        }
    }
    if (rx_frames == external_rx_intent.max_intents) {
        final_readiness = client_external_mode.parserReadiness(
            input.state,
            input.parser,
        ) catch return closeFailure(
            input,
            .invariant_failure,
            rx_bytes,
            rx_frames,
        );
        budget_exhausted = final_readiness == .complete_or_error;
    }
    const summary = Summary{
        .rx_bytes = rx_bytes,
        .rx_frames = rx_frames,
        .classified_count = classified_count,
        .final_readiness = final_readiness,
        .budget_exhausted = budget_exhausted,
        .partial = partial,
    };
    if (classified_count != 0) {
        if (!closeScratch(input.scratch))
            return closeFailure(
                input,
                .invariant_failure,
                rx_bytes,
                rx_frames,
            );
        return .{ .staged = summary };
    }
    const cleaned =
        external_rx_intent.abortAll(&input.scratch.intent) == .cleaned;
    const closed = closeScratch(input.scratch);
    if (!cleaned or !closed)
        return .{ .terminal = .{
            .reason = .invariant_failure,
            .rx_bytes = rx_bytes,
            .rx_frames = rx_frames,
        } };
    return .{ .no_intents = summary };
}

pub const testing = if (builtin.is_test) struct {
    /// Aggregate-only pump tests need a classified intent without opening another product caller.
    pub fn moveFrameForFixture(
        handle: *external_rx_intent.ExternalRxIntentHandle,
        source: *client_external_mode.ExternalRxOutcome,
        authority: external_rx_intent.AuthorityOps,
        target_stream_id: u64,
        partial: ?external_rx_demux.ValidatedPartialView,
    ) external_rx_intent.MoveResult {
        return external_rx_intent.moveFrame(
            handle,
            source,
            authority,
            target_stream_id,
            partial,
        );
    }
} else struct {};

test "p5c3d no-intent closed traversal is reusable before a new intent is created" {
    var scratch: Scratch = .{};
    try std.testing.expect(Scratch.initInPlace(&scratch));
    const first_generation = scratch.generation;

    scratch.lifecycle = .busy;
    scratch.digest = scratchDigest(&scratch);
    try std.testing.expect(closeScratch(&scratch));
    // Allocator's zero-work representation is an implementation detail and differs under
    // ReleaseFast. The public closure predicate owns the exact authority-bearing empty fields.
    try std.testing.expect(external_rx_intent.closedForOuterTurn(&scratch.intent));

    try std.testing.expect(Scratch.prepareForIntentCreation(&scratch));
    try std.testing.expectEqual(first_generation + 1, scratch.generation);
    try std.testing.expect(scratchControlValid(&scratch, .ready));
    try std.testing.expect(Scratch.prepareForIntentCreation(&scratch));
    try std.testing.expectEqual(first_generation + 1, scratch.generation);
}
