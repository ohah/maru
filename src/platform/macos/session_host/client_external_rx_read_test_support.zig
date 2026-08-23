//! Hostile synthetic-authority fixture root for the C3 cumulative RX collector.
//!
//! Product code never imports this module. Every fixture passes through `exerciseCollector`, so
//! boundary tests can keep the injected transport and all four handoff operations test-only.

const std = @import("std");
const read = @import("client_external_rx_read.zig");
const mode = @import("client_external_mode.zig");
const pump = @import("client_external_pump.zig");

fn invokeCollector(
    scratch: *read.ExternalRxReadScratch,
    input: read.CollectInput,
) read.CollectResult {
    return read.collectInjected(scratch, input);
}

fn borrowCollected(
    scratch: *read.ExternalRxReadScratch,
    receipt: *const read.CollectReceipt,
    out: *read.StoppedBorrow,
) bool {
    return read.borrowStopped(scratch, receipt, out);
}

fn viewCollected(
    scratch: *const read.ExternalRxReadScratch,
    receipt: *const read.CollectReceipt,
    borrow: *const read.StoppedBorrow,
) ?[]const u8 {
    return read.stoppedBytes(scratch, receipt, borrow);
}

fn settleCollected(
    scratch: *read.ExternalRxReadScratch,
    receipt: *const read.CollectReceipt,
    borrow: *read.StoppedBorrow,
    disposition: read.StoppedDisposition,
) bool {
    return read.settleStopped(scratch, receipt, borrow, disposition);
}

fn closeCollector(
    scratch: *read.ExternalRxReadScratch,
) read.ReadScratchTeardownResult {
    return read.teardown(scratch);
}

const CompletionExercise = struct {
    ordinary_reset: bool,
    accounted: bool,
    finalized: bool,
};

fn resetCompletion(prepared: *mode.PreparedRxAppend) bool {
    return mode.resetFinishedPreparedAdmit(prepared);
}

fn accountCompletion(
    prepared: *mode.PreparedRxAppend,
    outcome_tag: mode.GuardedQuarantineOutcomeTag,
    quarantine: mode.GuardedAdmitQuarantine,
    receipt: *mode.GuardedQuarantineAccountingReceipt,
) bool {
    return pump.accountGuardedAdmitQuarantine(
        prepared,
        outcome_tag,
        quarantine,
        receipt,
    );
}

fn finalizeCompletion(
    prepared: *mode.PreparedRxAppend,
    outcome_tag: mode.GuardedQuarantineOutcomeTag,
    quarantine: mode.GuardedAdmitQuarantine,
    receipt: *mode.GuardedQuarantineAccountingReceipt,
) bool {
    return mode.finalizeQuarantinedPreparedAdmit(
        prepared,
        outcome_tag,
        quarantine,
        receipt,
    );
}

fn exerciseCompletion(
    ordinary: *mode.PreparedRxAppend,
    quarantined: *mode.PreparedRxAppend,
    outcome_tag: mode.GuardedQuarantineOutcomeTag,
    quarantine: mode.GuardedAdmitQuarantine,
    receipt: *mode.GuardedQuarantineAccountingReceipt,
) CompletionExercise {
    const ordinary_reset = resetCompletion(ordinary);
    const accounted = accountCompletion(
        quarantined,
        outcome_tag,
        quarantine,
        receipt,
    );
    const finalized = finalizeCompletion(
        quarantined,
        outcome_tag,
        quarantine,
        receipt,
    );
    return .{
        .ordinary_reset = ordinary_reset,
        .accounted = accounted,
        .finalized = finalized,
    };
}

const ReadProbe = struct {
    scratch: *read.ExternalRxReadScratch,
    outcomes: [read.max_rx_read_attempts_per_turn]read.RxReadOutcome =
        [_]read.RxReadOutcome{.would_block} **
        read.max_rx_read_attempts_per_turn,
    outcome_count: usize = 1,
    calls: usize = 0,
    byte: u8 = 'x',
    mutate_prefix_on_call: ?usize = null,
    nested_input: ?read.CollectInput = null,
    nested_result: ?read.CollectResult = null,
    ops_to_mutate: ?*read.RxReadOps = null,
    mutate_ops_on_call: ?usize = null,
    mutate_attempt_on_call: ?usize = null,
    attempt_mutation: read.testing.AttemptMutation = .authority,
    teardown_on_call: ?usize = null,
    teardown_result: ?read.ReadScratchTeardownResult = null,

    fn invoke(
        context: *anyopaque,
        _: std.posix.fd_t,
        destination: []u8,
    ) read.RxReadOutcome {
        const self: *ReadProbe = @ptrCast(@alignCast(context));
        if (self.nested_input) |input| {
            self.nested_input = null;
            self.nested_result = invokeCollector(self.scratch, input);
        }
        if (self.mutate_prefix_on_call == self.calls and
            self.scratch.staged_len != 0)
            self.scratch.backing[0] +%= 1;
        if (self.mutate_ops_on_call == self.calls)
            self.ops_to_mutate.?.context_len += 1;
        if (self.mutate_attempt_on_call == self.calls)
            read.testing.mutateLiveAttempt(
                self.scratch,
                self.attempt_mutation,
            );
        if (self.teardown_on_call == self.calls)
            self.teardown_result = closeCollector(self.scratch);
        const outcome = if (self.calls < self.outcome_count)
            self.outcomes[self.calls]
        else
            read.RxReadOutcome.would_block;
        self.calls += 1;
        switch (outcome) {
            .bytes => |count| {
                if (count <= destination.len)
                    @memset(destination[0..count], self.byte);
            },
            else => {},
        }
        return outcome;
    }
};

const AuthorityProbe = struct {
    view: read.RxReadAuthorityView,
    scratch: *read.ExternalRxReadScratch,
    calls: usize = 0,
    return_null_on_call: ?usize = null,
    drift_fd_on_call: ?usize = null,
    mutate_scratch_on_call: ?usize = null,
    mutate_attempt_on_call: ?usize = null,
    attempt_mutation: read.testing.AttemptMutation = .authority,
    parser_backing: [16]u8 = undefined,

    fn current(context: *anyopaque) ?read.RxReadAuthorityView {
        const self: *AuthorityProbe = @ptrCast(@alignCast(context));
        const call = self.calls;
        self.calls += 1;
        if (self.mutate_scratch_on_call == call)
            self.scratch.staged_len = 1;
        if (self.mutate_attempt_on_call == call)
            read.testing.mutateLiveAttempt(
                self.scratch,
                self.attempt_mutation,
            );
        if (self.return_null_on_call == call) return null;
        var view = self.view;
        if (self.drift_fd_on_call == call) view.fd += 1;
        if (self.drift_fd_on_call == call) read.sealAuthorityView(&view);
        return view;
    }
};

const ExerciseResult = struct {
    collected: read.CollectResult,
    borrowed: bool,
    bytes_equal: bool,
    settled: bool,
    teardown_result: read.ReadScratchTeardownResult,
    validation_bytes: usize,
};

fn exerciseCollector(
    scratch: *read.ExternalRxReadScratch,
    input: read.CollectInput,
    expected: []const u8,
    mutate_stopped_prefix: bool,
) ExerciseResult {
    const collected = invokeCollector(scratch, input);
    var receipt: read.CollectReceipt = .{
        .scratch_addr = 0,
        .scratch_generation = 0,
        .allowance = .{
            .bytes = 1,
            .resident_limited = true,
            .turn_limited = false,
            .counter_limited = false,
        },
        .accepted_bytes = 0,
        .attempts = 0,
        .stop = .would_block,
        .digest = [_]u8{0} ** 32,
    };
    switch (collected) {
        .stopped => |stopped| receipt = stopped,
        else => {},
    }
    if (mutate_stopped_prefix and receipt.accepted_bytes != 0)
        scratch.backing[0] +%= 1;
    var borrow: read.StoppedBorrow = .{};
    const borrowed = borrowCollected(scratch, &receipt, &borrow);
    const bytes = viewCollected(scratch, &receipt, &borrow);
    const bytes_equal = if (bytes) |value|
        std.mem.eql(u8, value, expected)
    else
        false;
    const would_block = receipt.stop == .would_block;
    const validation_bytes = scratch.validation_bytes_checked;
    const settled = settleCollected(
        scratch,
        &receipt,
        &borrow,
        .{
            .staged = .consumed,
            .would_block = if (would_block) .consumed else .not_present,
        },
    );
    const teardown_result = closeCollector(scratch);
    return .{
        .collected = collected,
        .borrowed = borrowed,
        .bytes_equal = bytes_equal,
        .settled = settled,
        .teardown_result = teardown_result,
        .validation_bytes = validation_bytes,
    };
}

fn initializeFixture(
    scratch: *read.ExternalRxReadScratch,
    read_probe: *ReadProbe,
    authority_probe: *AuthorityProbe,
    read_ops: *read.RxReadOps,
    authority_ops: *read.RxReadAuthorityOps,
) void {
    scratch.* = .{};
    std.debug.assert(read.ExternalRxReadScratch.initInPlace(scratch));
    read_probe.* = .{ .scratch = scratch };
    read_ops.* = .{
        .context = read_probe,
        .context_len = @sizeOf(ReadProbe),
        .read = ReadProbe.invoke,
    };
    authority_ops.* = .{
        .context = authority_probe,
        .context_len = @offsetOf(AuthorityProbe, "parser_backing"),
        .current = AuthorityProbe.current,
    };
    authority_probe.* = .{
        .view = .{
            .storage_addr = 0x1000,
            .lease_addr = 0x2000,
            .scratch_addr = @intFromPtr(scratch),
            .scratch_generation = scratch.generation,
            .client_addr = 0x3000,
            .fd = 7,
            .parser_addr = 0x4000,
            .parser_seal = .{
                .seal_addr = @intFromPtr(
                    &authority_probe.view.parser_seal,
                ),
                .parser_addr = 0x4000,
                .identity = .{
                    .attach_instance_id = 1,
                    .destination_slot_addr = 0x5000,
                },
                .destination_slot_len = 8,
                .allocator_ptr_addr = 0x6000,
                .allocator_vtable_addr = 0x7000,
                .expected_major = 1,
                .backing_addr = @intFromPtr(&authority_probe.parser_backing),
                .capacity = authority_probe.parser_backing.len,
                .resident_cap = authority_probe.parser_backing.len,
                .generation = 1,
            },
            .owner_snapshot_digest = [_]u8{1} ** 32,
            .protected_range_count = 3,
            .protected_ranges = [_]read.ProtectedRange{.{}} **
                read.max_rx_read_protected_ranges,
            .view_digest = undefined,
        },
        .scratch = scratch,
    };
    const read_range = read.ProtectedRange{
        .addr = @intFromPtr(read_probe),
        .len = @sizeOf(ReadProbe),
    };
    const authority_range = read.ProtectedRange{
        .addr = @intFromPtr(authority_probe),
        .len = @offsetOf(AuthorityProbe, "parser_backing"),
    };
    const parser_range = read.ProtectedRange{
        .addr = @intFromPtr(&authority_probe.parser_backing),
        .len = authority_probe.parser_backing.len,
    };
    var ranges = [_]read.ProtectedRange{
        read_range,
        authority_range,
        parser_range,
    };
    for (1..ranges.len) |index| {
        var cursor = index;
        while (cursor != 0 and ranges[cursor].addr < ranges[cursor - 1].addr) {
            std.mem.swap(
                read.ProtectedRange,
                &ranges[cursor],
                &ranges[cursor - 1],
            );
            cursor -= 1;
        }
    }
    @memcpy(authority_probe.view.protected_ranges[0..ranges.len], &ranges);
    mode.testing.sealParserAuthorityProjection(
        &authority_probe.view.parser_seal,
    );
    read.sealAuthorityView(&authority_probe.view);
}

fn allowance(bytes: usize) read.RxReadableAllowance {
    return .{
        .bytes = bytes,
        .resident_limited = false,
        .turn_limited = true,
        .counter_limited = false,
    };
}

fn removeProtectedRange(
    view: *read.RxReadAuthorityView,
    addr: usize,
    len: usize,
) bool {
    for (view.protected_ranges[0..view.protected_range_count], 0..) |range, index| {
        if (range.addr != addr or range.len != len) continue;
        const count: usize = view.protected_range_count;
        for (index..count - 1) |cursor|
            view.protected_ranges[cursor] =
                view.protected_ranges[cursor + 1];
        view.protected_ranges[count - 1] = .{};
        view.protected_range_count -= 1;
        return true;
    }
    return false;
}

const AccountingRace = struct {
    prepared: *mode.PreparedRxAppend,
    quarantine: mode.GuardedAdmitQuarantine,
    receipt: *mode.GuardedQuarantineAccountingReceipt,
    ready: *std.atomic.Value(u8),
    start: *std.atomic.Value(bool),
    result: *bool,

    fn run(self: *@This()) void {
        _ = self.ready.fetchAdd(1, .acq_rel);
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        self.result.* = accountCompletion(
            self.prepared,
            .allocation_quarantined,
            self.quarantine,
            self.receipt,
        );
    }
};

test "C3 collector accumulates bytes across EINTR and hands a would-block prefix off once" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    read_probe.outcomes[0] = .interrupted;
    read_probe.outcomes[1] = .{ .bytes = 3 };
    read_probe.outcomes[2] = .would_block;
    read_probe.outcome_count = 3;
    read_probe.byte = 'a';

    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(8),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "aaa",
        false,
    );
    const stopped = result.collected.stopped;
    try std.testing.expectEqual(read.CollectStop.would_block, stopped.stop);
    try std.testing.expectEqual(@as(usize, 3), stopped.accepted_bytes);
    try std.testing.expectEqual(@as(u8, 3), stopped.attempts);
    try std.testing.expect(result.borrowed);
    try std.testing.expect(result.bytes_equal);
    try std.testing.expect(result.settled);
    try std.testing.expectEqual(
        read.ReadScratchTeardownResult.closed,
        result.teardown_result,
    );
    try std.testing.expectEqual(@as(usize, 3), read_probe.calls);
    try std.testing.expectEqual(@as(usize, 6), authority_probe.calls);
}

test "C3 collector discards a staged prefix when a later valid outcome exposes mutation" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    read_probe.outcomes[0] = .{ .bytes = 1 };
    read_probe.outcomes[1] = .would_block;
    read_probe.outcome_count = 2;
    read_probe.mutate_prefix_on_call = 1;

    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(8),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "",
        false,
    );
    try std.testing.expectEqual(
        read.CollectTerminalReason.staged_prefix_drift,
        result.collected.terminal.reason,
    );
    try std.testing.expect(!result.borrowed);
    try std.testing.expect(!result.settled);
    try std.testing.expectEqual(
        read.ReadScratchTeardownResult.closed,
        result.teardown_result,
    );
}

test "C3 collector rejects byte zero without treating the destination as input" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    read_probe.outcomes[0] = .{ .bytes = 0 };

    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(8),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "",
        false,
    );
    try std.testing.expectEqual(
        read.CollectTerminalReason.invalid_callback_result,
        result.collected.terminal.reason,
    );
    try std.testing.expectEqual(@as(usize, 1), read_probe.calls);
    try std.testing.expectEqual(@as(usize, 2), authority_probe.calls);
}

test "C3 collector gives the ninth consecutive interrupt precedence over attempt stop" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    for (read_probe.outcomes[0..9]) |*outcome| outcome.* = .interrupted;
    read_probe.outcome_count = 9;

    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(64),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "",
        false,
    );
    try std.testing.expectEqual(
        read.CollectTerminalReason.interrupt_limit,
        result.collected.terminal.reason,
    );
    try std.testing.expectEqual(@as(u8, 9), result.collected.terminal.attempts);
    try std.testing.expectEqual(@as(usize, 9), read_probe.calls);
    try std.testing.expectEqual(@as(usize, 18), authority_probe.calls);
}

test "C3 bytes reset an eight-interrupt streak and ninth EINTR wins on attempt 64" {
    inline for (.{ false, true }) |tie_at_64| {
        const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var read_probe: ReadProbe = undefined;
        var authority_probe: AuthorityProbe = undefined;
        var read_ops: read.RxReadOps = undefined;
        var authority_ops: read.RxReadAuthorityOps = undefined;
        initializeFixture(
            scratch,
            &read_probe,
            &authority_probe,
            &read_ops,
            &authority_ops,
        );
        if (tie_at_64) {
            for (read_probe.outcomes[0..55]) |*outcome|
                outcome.* = .{ .bytes = 1 };
            for (read_probe.outcomes[55..64]) |*outcome|
                outcome.* = .interrupted;
            read_probe.outcome_count = 64;
        } else {
            for (read_probe.outcomes[0..8]) |*outcome|
                outcome.* = .interrupted;
            read_probe.outcomes[8] = .{ .bytes = 1 };
            for (read_probe.outcomes[9..17]) |*outcome|
                outcome.* = .interrupted;
            read_probe.outcomes[17] = .{ .bytes = 1 };
            read_probe.outcome_count = 18;
        }
        const result = exerciseCollector(
            scratch,
            .{
                .allowance = allowance(if (tie_at_64) 64 else 2),
                .read_ops = &read_ops,
                .authority_ops = &authority_ops,
            },
            if (tie_at_64) "" else "xx",
            false,
        );
        if (tie_at_64) {
            try std.testing.expectEqual(
                read.CollectTerminalReason.interrupt_limit,
                result.collected.terminal.reason,
            );
            try std.testing.expectEqual(
                @as(u8, 64),
                result.collected.terminal.attempts,
            );
            try std.testing.expectEqual(@as(usize, 64), read_probe.calls);
            try std.testing.expectEqual(
                @as(usize, 128),
                authority_probe.calls,
            );
        } else {
            try std.testing.expectEqual(
                read.CollectStop.allowance_reached,
                result.collected.stopped.stop,
            );
            try std.testing.expect(result.bytes_equal);
            try std.testing.expect(result.settled);
        }
    }
}

test "C3 collector fails closed when post-read authority changes" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    read_probe.outcomes[0] = .{ .bytes = 1 };
    authority_probe.drift_fd_on_call = 1;

    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(8),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "",
        false,
    );
    try std.testing.expectEqual(
        read.CollectTerminalReason.authority_drift,
        result.collected.terminal.reason,
    );
    try std.testing.expectEqual(@as(usize, 1), read_probe.calls);
}

test "C3 collector distinguishes missing pre and post authority without extra reads" {
    inline for (.{ @as(usize, 0), @as(usize, 1) }) |missing_call| {
        const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var read_probe: ReadProbe = undefined;
        var authority_probe: AuthorityProbe = undefined;
        var read_ops: read.RxReadOps = undefined;
        var authority_ops: read.RxReadAuthorityOps = undefined;
        initializeFixture(
            scratch,
            &read_probe,
            &authority_probe,
            &read_ops,
            &authority_ops,
        );
        read_probe.outcomes[0] = .{ .bytes = 1 };
        authority_probe.return_null_on_call = missing_call;
        const result = exerciseCollector(
            scratch,
            .{
                .allowance = allowance(8),
                .read_ops = &read_ops,
                .authority_ops = &authority_ops,
            },
            "",
            false,
        );
        try std.testing.expectEqual(
            read.CollectTerminalReason.authority_missing,
            result.collected.terminal.reason,
        );
        try std.testing.expectEqual(
            missing_call,
            read_probe.calls,
        );
        try std.testing.expectEqual(
            @as(u8, @intCast(missing_call)),
            result.collected.terminal.attempts,
        );
    }
}

test "C3 collector publishes collecting before a reentrant read callback" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    const input = read.CollectInput{
        .allowance = allowance(1),
        .read_ops = &read_ops,
        .authority_ops = &authority_ops,
    };
    read_probe.outcomes[0] = .{ .bytes = 1 };
    read_probe.nested_input = input;

    const result = exerciseCollector(scratch, input, "x", false);
    try std.testing.expectEqual(
        read.CollectRejectReason.busy_or_spent,
        read_probe.nested_result.?.rejected,
    );
    try std.testing.expect(result.borrowed);
    try std.testing.expect(result.settled);
}

test "C3 handoff rejects a prefix changed after the collector stopped" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    read_probe.outcomes[0] = .{ .bytes = 1 };
    read_probe.outcomes[1] = .would_block;
    read_probe.outcome_count = 2;

    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(8),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "x",
        true,
    );
    try std.testing.expectEqual(
        read.CollectStop.would_block,
        result.collected.stopped.stop,
    );
    try std.testing.expect(!result.borrowed);
    try std.testing.expect(!result.bytes_equal);
    try std.testing.expect(!result.settled);
    try std.testing.expectEqual(
        read.ReadScratchTeardownResult.stale_or_moved,
        result.teardown_result,
    );
}

test "C3 collector stops after exactly 64 reads without a 65th callback" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    for (&read_probe.outcomes) |*outcome| outcome.* = .{ .bytes = 1 };
    read_probe.outcome_count = read_probe.outcomes.len;
    const expected: [read.max_rx_read_attempts_per_turn]u8 =
        [_]u8{'x'} ** read.max_rx_read_attempts_per_turn;

    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(65),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        &expected,
        false,
    );
    try std.testing.expectEqual(
        read.CollectStop.attempt_budget_exhausted,
        result.collected.stopped.stop,
    );
    try std.testing.expectEqual(
        @as(u8, read.max_rx_read_attempts_per_turn),
        result.collected.stopped.attempts,
    );
    try std.testing.expectEqual(
        read.max_rx_read_attempts_per_turn,
        read_probe.calls,
    );
    try std.testing.expectEqual(
        read.max_rx_read_authority_callbacks_per_turn,
        authority_probe.calls,
    );
    try std.testing.expectEqual(@as(usize, 2080), result.validation_bytes);
    try std.testing.expect(
        result.validation_bytes <=
            read.max_rx_staged_prefix_validation_bytes_per_turn,
    );
    try std.testing.expect(result.bytes_equal);
    try std.testing.expect(result.settled);
}

test "C3 authority preflight requires the exact parser backing leaf" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    authority_probe.view.parser_seal.capacity -= 1;
    read.sealAuthorityView(&authority_probe.view);

    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(1),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "",
        false,
    );
    try std.testing.expectEqual(
        read.CollectTerminalReason.authority_drift,
        result.collected.terminal.reason,
    );
    try std.testing.expectEqual(@as(usize, 0), read_probe.calls);
    try std.testing.expectEqual(@as(usize, 1), authority_probe.calls);
}

test "C3 authority accepts a structurally sealed zero-capacity parser" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    const backing_addr = authority_probe.view.parser_seal.backing_addr;
    const backing_len = authority_probe.view.parser_seal.capacity;
    try std.testing.expect(removeProtectedRange(
        &authority_probe.view,
        backing_addr,
        backing_len,
    ));
    authority_probe.view.parser_seal.backing_addr = 0;
    authority_probe.view.parser_seal.capacity = 0;
    authority_probe.view.parser_seal.resident_cap = 16;
    mode.testing.sealParserAuthorityProjection(
        &authority_probe.view.parser_seal,
    );
    read.sealAuthorityView(&authority_probe.view);

    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(1),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "",
        false,
    );
    try std.testing.expectEqual(
        read.CollectStop.would_block,
        result.collected.stopped.stop,
    );
    try std.testing.expect(result.borrowed);
    try std.testing.expect(result.settled);
}

test "C3 authority rejects a stable view carrying a forged parser seal" {
    inline for (.{ @as(u8, 0), @as(u8, 1), @as(u8, 2) }) |field| {
        const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var read_probe: ReadProbe = undefined;
        var authority_probe: AuthorityProbe = undefined;
        var read_ops: read.RxReadOps = undefined;
        var authority_ops: read.RxReadAuthorityOps = undefined;
        initializeFixture(
            scratch,
            &read_probe,
            &authority_probe,
            &read_ops,
            &authority_ops,
        );
        switch (field) {
            0 => authority_probe.view.parser_seal.domain[0] +%= 1,
            1 => authority_probe.view.parser_seal.generation = 0,
            2 => authority_probe.view.parser_seal.digest[0] +%= 1,
            else => unreachable,
        }
        read.sealAuthorityView(&authority_probe.view);

        const result = exerciseCollector(
            scratch,
            .{
                .allowance = allowance(1),
                .read_ops = &read_ops,
                .authority_ops = &authority_ops,
            },
            "",
            false,
        );
        try std.testing.expectEqual(
            read.CollectTerminalReason.authority_drift,
            result.collected.terminal.reason,
        );
        try std.testing.expectEqual(@as(usize, 0), read_probe.calls);
    }
}

test "C3 completion resets ordinary tokens and accounts quarantine exactly once" {
    pump.quarantine_testing.reset();
    defer pump.quarantine_testing.reset();
    var ordinary: mode.PreparedRxAppend = .{};
    try std.testing.expect(
        try mode.testing.finishOrdinaryGuardedCommitForTest(&ordinary),
    );
    var quarantined: mode.PreparedRxAppend = .{};
    const quarantine =
        (try mode.testing.finishQuarantinedGuardedCommitForTest(&quarantined)) orelse
        return error.TestUnexpectedResult;
    var receipt: mode.GuardedQuarantineAccountingReceipt = .{};
    const first = exerciseCompletion(
        &ordinary,
        &quarantined,
        .allocation_quarantined,
        quarantine,
        &receipt,
    );
    try std.testing.expect(first.ordinary_reset);
    try std.testing.expect(first.accounted);
    try std.testing.expect(first.finalized);
    try std.testing.expect(mode.preparedRxAppendPristine(&ordinary));
    try std.testing.expect(mode.preparedRxAppendPristine(&quarantined));
    const status = pump.crossOwnerQuarantineStatus();
    try std.testing.expect(status.latched);
    try std.testing.expectEqual(@as(u64, 1), status.event_count);

    const replay = exerciseCompletion(
        &ordinary,
        &quarantined,
        .allocation_quarantined,
        quarantine,
        &receipt,
    );
    try std.testing.expect(!replay.ordinary_reset);
    try std.testing.expect(!replay.accounted);
    try std.testing.expect(!replay.finalized);
    try std.testing.expectEqual(
        status.event_count,
        pump.crossOwnerQuarantineStatus().event_count,
    );
}

test "C3 concurrent accounting of one token commits one event without panic" {
    pump.quarantine_testing.reset();
    defer pump.quarantine_testing.reset();
    var prepared: mode.PreparedRxAppend = .{};
    const quarantine = mode.GuardedAdmitQuarantine{
        .phase = .abort_cleanup,
        .quarantined_bytes_upper_bound = 9,
    };
    try std.testing.expect(
        mode.testing.seedQuarantinePendingPreparedAdmit(
            &prepared,
            .allocation_quarantined,
            quarantine,
        ),
    );
    var receipts = [_]mode.GuardedQuarantineAccountingReceipt{ .{}, .{} };
    var results = [_]bool{ false, false };
    var ready: std.atomic.Value(u8) = .init(0);
    var start: std.atomic.Value(bool) = .init(false);
    var races = [_]AccountingRace{
        .{
            .prepared = &prepared,
            .quarantine = quarantine,
            .receipt = &receipts[0],
            .ready = &ready,
            .start = &start,
            .result = &results[0],
        },
        .{
            .prepared = &prepared,
            .quarantine = quarantine,
            .receipt = &receipts[1],
            .ready = &ready,
            .start = &start,
            .result = &results[1],
        },
    };
    const first = try std.Thread.spawn(.{}, AccountingRace.run, .{&races[0]});
    const second = try std.Thread.spawn(.{}, AccountingRace.run, .{&races[1]});
    while (ready.load(.acquire) != 2) std.atomic.spinLoopHint();
    start.store(true, .release);
    first.join();
    second.join();

    try std.testing.expect(results[0] != results[1]);
    try std.testing.expectEqual(
        @as(u64, 1),
        pump.crossOwnerQuarantineStatus().event_count,
    );
    const winner = if (results[0]) &receipts[0] else &receipts[1];
    try std.testing.expect(finalizeCompletion(
        &prepared,
        .allocation_quarantined,
        quarantine,
        winner,
    ));
}

test "C3 collector reaches allowance exactly and preserves the accepted prefix" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    read_probe.outcomes[0] = .{ .bytes = 4 };

    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(4),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "xxxx",
        false,
    );
    try std.testing.expectEqual(
        read.CollectStop.allowance_reached,
        result.collected.stopped.stop,
    );
    try std.testing.expect(result.bytes_equal);
    try std.testing.expect(result.settled);
    try std.testing.expectEqual(@as(usize, 4), result.validation_bytes);
}

test "C3 collector preserves a positive prefix before EOF and socket error" {
    inline for (.{ read.RxReadOutcome.eof, read.RxReadOutcome.socket_error }) |last| {
        const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var read_probe: ReadProbe = undefined;
        var authority_probe: AuthorityProbe = undefined;
        var read_ops: read.RxReadOps = undefined;
        var authority_ops: read.RxReadAuthorityOps = undefined;
        initializeFixture(
            scratch,
            &read_probe,
            &authority_probe,
            &read_ops,
            &authority_ops,
        );
        read_probe.outcomes[0] = .{ .bytes = 1 };
        read_probe.outcomes[1] = last;
        read_probe.outcome_count = 2;

        const result = exerciseCollector(
            scratch,
            .{
                .allowance = allowance(8),
                .read_ops = &read_ops,
                .authority_ops = &authority_ops,
            },
            "x",
            false,
        );
        const expected: read.CollectStop =
            if (last == .eof) .eof_after_prefix else .socket_error_after_prefix;
        try std.testing.expectEqual(expected, result.collected.stopped.stop);
        try std.testing.expectEqual(
            @as(usize, 1),
            result.collected.stopped.accepted_bytes,
        );
        try std.testing.expect(result.borrowed);
        try std.testing.expect(result.bytes_equal);
        try std.testing.expect(result.settled);
        try std.testing.expectEqual(
            read.ReadScratchTeardownResult.closed,
            result.teardown_result,
        );
    }
}

test "C3 collector counts a read whose callback corrupts its descriptor" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    read_probe.outcomes[0] = .{ .bytes = 1 };
    read_probe.ops_to_mutate = &read_ops;
    read_probe.mutate_ops_on_call = 0;

    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(8),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "",
        false,
    );
    try std.testing.expectEqual(
        read.CollectTerminalReason.authority_drift,
        result.collected.terminal.reason,
    );
    try std.testing.expectEqual(@as(u8, 1), result.collected.terminal.attempts);
    try std.testing.expectEqual(@as(usize, 1), read_probe.calls);
}

test "C3 collector rejects every live attempt field changed by hostile callbacks" {
    inline for (std.meta.tags(read.testing.AttemptMutation)) |mutation| {
        inline for (.{ false, true }) |post_current| {
            const scratch = try std.testing.allocator.create(
                read.ExternalRxReadScratch,
            );
            defer std.testing.allocator.destroy(scratch);
            var read_probe: ReadProbe = undefined;
            var authority_probe: AuthorityProbe = undefined;
            var read_ops: read.RxReadOps = undefined;
            var authority_ops: read.RxReadAuthorityOps = undefined;
            initializeFixture(
                scratch,
                &read_probe,
                &authority_probe,
                &read_ops,
                &authority_ops,
            );
            read_probe.outcomes[0] = .{ .bytes = 1 };
            if (post_current) {
                authority_probe.mutate_attempt_on_call = 1;
                authority_probe.attempt_mutation = mutation;
            } else {
                read_probe.mutate_attempt_on_call = 0;
                read_probe.attempt_mutation = mutation;
            }

            const result = exerciseCollector(
                scratch,
                .{
                    .allowance = allowance(8),
                    .read_ops = &read_ops,
                    .authority_ops = &authority_ops,
                },
                "",
                false,
            );
            try std.testing.expectEqual(
                read.CollectTerminalReason.authority_drift,
                result.collected.terminal.reason,
            );
            try std.testing.expectEqual(
                @as(u8, 1),
                result.collected.terminal.attempts,
            );
            try std.testing.expectEqual(
                read.ReadScratchTeardownResult.closed,
                result.teardown_result,
            );
        }
    }
}

test "C3 collector rejects pre-authority scratch mutation before reading" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    authority_probe.mutate_scratch_on_call = 0;

    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(8),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "",
        false,
    );
    try std.testing.expectEqual(
        read.CollectTerminalReason.authority_drift,
        result.collected.terminal.reason,
    );
    try std.testing.expectEqual(@as(usize, 0), read_probe.calls);
    try std.testing.expectEqual(@as(u8, 0), result.collected.terminal.attempts);
}

test "C3 collector rejects requested plus one without scanning the destination" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    read_probe.outcomes[0] = .{ .bytes = 9 };

    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(8),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "",
        false,
    );
    try std.testing.expectEqual(
        read.CollectTerminalReason.invalid_callback_result,
        result.collected.terminal.reason,
    );
    try std.testing.expectEqual(@as(usize, 0), result.validation_bytes);
}

test "C3 protected range validation rejects unsorted and noncanonical tails" {
    inline for (.{ false, true }) |tail_case| {
        const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var read_probe: ReadProbe = undefined;
        var authority_probe: AuthorityProbe = undefined;
        var read_ops: read.RxReadOps = undefined;
        var authority_ops: read.RxReadAuthorityOps = undefined;
        initializeFixture(
            scratch,
            &read_probe,
            &authority_probe,
            &read_ops,
            &authority_ops,
        );
        if (tail_case) {
            authority_probe.view.protected_ranges[3] = .{
                .addr = 0x9000,
                .len = 1,
            };
        } else {
            std.mem.swap(
                read.ProtectedRange,
                &authority_probe.view.protected_ranges[0],
                &authority_probe.view.protected_ranges[1],
            );
        }
        read.sealAuthorityView(&authority_probe.view);

        const result = exerciseCollector(
            scratch,
            .{
                .allowance = allowance(1),
                .read_ops = &read_ops,
                .authority_ops = &authority_ops,
            },
            "",
            false,
        );
        try std.testing.expectEqual(
            read.CollectTerminalReason.authority_drift,
            result.collected.terminal.reason,
        );
        try std.testing.expectEqual(@as(usize, 0), read_probe.calls);
    }
}

test "C3 protected range validation rejects count overlap overflow and partial leaves" {
    inline for (.{ @as(u8, 0), @as(u8, 1), @as(u8, 2), @as(u8, 3), @as(u8, 4), @as(u8, 5) }) |case| {
        const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
        defer std.testing.allocator.destroy(scratch);
        var read_probe: ReadProbe = undefined;
        var authority_probe: AuthorityProbe = undefined;
        var read_ops: read.RxReadOps = undefined;
        var authority_ops: read.RxReadAuthorityOps = undefined;
        initializeFixture(
            scratch,
            &read_probe,
            &authority_probe,
            &read_ops,
            &authority_ops,
        );
        switch (case) {
            0 => authority_probe.view.protected_range_count = 0,
            1 => authority_probe.view.protected_range_count =
                @intCast(read.max_rx_read_protected_ranges + 1),
            2 => authority_probe.view.protected_ranges[1] =
                authority_probe.view.protected_ranges[0],
            3 => {
                authority_probe.view.protected_ranges[1].addr =
                    authority_probe.view.protected_ranges[0].addr + 1;
                authority_probe.view.protected_ranges[1].len =
                    authority_probe.view.protected_ranges[0].len;
            },
            4 => {
                authority_probe.view.protected_ranges[0].addr =
                    std.math.maxInt(usize);
                authority_probe.view.protected_ranges[0].len = 2;
            },
            5 => {
                for (authority_probe.view.protected_ranges[0..authority_probe.view.protected_range_count]) |*range| {
                    if (range.addr ==
                        authority_probe.view.parser_seal.backing_addr)
                    {
                        range.len -= 1;
                        break;
                    }
                }
            },
            else => unreachable,
        }
        read.sealAuthorityView(&authority_probe.view);
        const result = exerciseCollector(
            scratch,
            .{
                .allowance = allowance(1),
                .read_ops = &read_ops,
                .authority_ops = &authority_ops,
            },
            "",
            false,
        );
        try std.testing.expectEqual(
            read.CollectTerminalReason.authority_drift,
            result.collected.terminal.reason,
        );
        try std.testing.expectEqual(@as(usize, 0), read_probe.calls);
    }
}

test "C3 closed teardown is idempotent only while its canonical seal remains intact" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(1),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "",
        false,
    );
    try std.testing.expectEqual(
        read.ReadScratchTeardownResult.closed,
        result.teardown_result,
    );
    try std.testing.expectEqual(
        read.ReadScratchTeardownResult.already_closed,
        closeCollector(scratch),
    );
    scratch.validation_bytes_checked = 1;
    try std.testing.expectEqual(
        read.ReadScratchTeardownResult.stale_or_moved,
        closeCollector(scratch),
    );
}

test "C3 quarantine accounting rejects cap overflow and generation exhaustion without events" {
    pump.quarantine_testing.reset();
    defer pump.quarantine_testing.reset();
    inline for (.{ false, true }) |generation_case| {
        var ordinary: mode.PreparedRxAppend = .{};
        try std.testing.expect(
            mode.testing.seedOrdinaryFinishedPreparedAdmit(&ordinary, false),
        );
        var quarantined: mode.PreparedRxAppend = .{};
        const quarantine = mode.GuardedAdmitQuarantine{
            .phase = .allocation,
            .quarantined_bytes_upper_bound = if (generation_case)
                1
            else
                pump.max_guarded_admit_quarantine_bytes + 1,
        };
        try std.testing.expect(
            mode.testing.seedQuarantinePendingPreparedAdmit(
                &quarantined,
                .allocation_quarantined,
                quarantine,
            ),
        );
        if (generation_case)
            pump.quarantine_testing.forceEventGeneration(
                std.math.maxInt(u64),
            );
        var receipt: mode.GuardedQuarantineAccountingReceipt = .{};
        const before = pump.crossOwnerQuarantineStatus();
        const result = exerciseCompletion(
            &ordinary,
            &quarantined,
            .allocation_quarantined,
            quarantine,
            &receipt,
        );
        try std.testing.expect(result.ordinary_reset);
        try std.testing.expect(!result.accounted);
        try std.testing.expect(!result.finalized);
        const after = pump.crossOwnerQuarantineStatus();
        try std.testing.expectEqual(before.event_count, after.event_count);
        try std.testing.expect(!mode.preparedRxAppendPristine(&quarantined));
        pump.quarantine_testing.reset();
    }
}

test "C3 quarantine accounting binds tag phase bound address and receipt identity" {
    pump.quarantine_testing.reset();
    defer pump.quarantine_testing.reset();
    const canonical = mode.GuardedAdmitQuarantine{
        .phase = .commit_cleanup,
        .quarantined_bytes_upper_bound = 21,
    };
    inline for (.{ @as(u8, 0), @as(u8, 1), @as(u8, 2) }) |mismatch| {
        var prepared: mode.PreparedRxAppend = .{};
        try std.testing.expect(
            mode.testing.seedQuarantinePendingPreparedAdmit(
                &prepared,
                .post_commit_quarantined,
                canonical,
            ),
        );
        const supplied_tag: mode.GuardedQuarantineOutcomeTag =
            if (mismatch == 0)
                .allocation_quarantined
            else
                .post_commit_quarantined;
        const supplied = mode.GuardedAdmitQuarantine{
            .phase = if (mismatch == 1)
                .abort_cleanup
            else
                canonical.phase,
            .quarantined_bytes_upper_bound = if (mismatch == 2)
                canonical.quarantined_bytes_upper_bound + 1
            else
                canonical.quarantined_bytes_upper_bound,
        };
        var receipt: mode.GuardedQuarantineAccountingReceipt = .{};
        const before = pump.crossOwnerQuarantineStatus().event_count;
        try std.testing.expect(!accountCompletion(
            &prepared,
            supplied_tag,
            supplied,
            &receipt,
        ));
        try std.testing.expectEqual(
            before,
            pump.crossOwnerQuarantineStatus().event_count,
        );
        try std.testing.expect(!finalizeCompletion(
            &prepared,
            supplied_tag,
            supplied,
            &receipt,
        ));
    }

    var prepared: mode.PreparedRxAppend = .{};
    try std.testing.expect(
        mode.testing.seedQuarantinePendingPreparedAdmit(
            &prepared,
            .post_commit_quarantined,
            canonical,
        ),
    );
    var receipt: mode.GuardedQuarantineAccountingReceipt = .{};
    try std.testing.expect(accountCompletion(
        &prepared,
        .post_commit_quarantined,
        canonical,
        &receipt,
    ));
    var copied_receipt = receipt;
    try std.testing.expect(!finalizeCompletion(
        &prepared,
        .post_commit_quarantined,
        canonical,
        &copied_receipt,
    ));
    try std.testing.expect(finalizeCompletion(
        &prepared,
        .post_commit_quarantined,
        canonical,
        &receipt,
    ));
    try std.testing.expect(!finalizeCompletion(
        &prepared,
        .post_commit_quarantined,
        canonical,
        &receipt,
    ));
}

test "C3 ordinary and quarantine finalizers cannot cross their token classes" {
    var ordinary: mode.PreparedRxAppend = .{};
    try std.testing.expect(
        mode.testing.seedOrdinaryFinishedPreparedAdmit(&ordinary, true),
    );
    var empty_receipt: mode.GuardedQuarantineAccountingReceipt = .{};
    const quarantine = mode.GuardedAdmitQuarantine{
        .phase = .allocation,
        .quarantined_bytes_upper_bound = 1,
    };
    try std.testing.expect(!finalizeCompletion(
        &ordinary,
        .allocation_quarantined,
        quarantine,
        &empty_receipt,
    ));
    try std.testing.expect(resetCompletion(&ordinary));

    var pending: mode.PreparedRxAppend = .{};
    try std.testing.expect(
        mode.testing.seedQuarantinePendingPreparedAdmit(
            &pending,
            .allocation_quarantined,
            quarantine,
        ),
    );
    try std.testing.expect(!resetCompletion(&pending));
    try std.testing.expect(!finalizeCompletion(
        &pending,
        .allocation_quarantined,
        quarantine,
        &empty_receipt,
    ));
}

test "C3 accounting rejects an aliased receipt before global mutation" {
    pump.quarantine_testing.reset();
    defer pump.quarantine_testing.reset();
    var prepared: mode.PreparedRxAppend = .{};
    const quarantine = mode.GuardedAdmitQuarantine{
        .phase = .allocation,
        .quarantined_bytes_upper_bound = 1,
    };
    try std.testing.expect(
        mode.testing.seedQuarantinePendingPreparedAdmit(
            &prepared,
            .allocation_quarantined,
            quarantine,
        ),
    );
    const aliased: *mode.GuardedQuarantineAccountingReceipt =
        @ptrCast(@alignCast(&prepared));
    try std.testing.expect(!accountCompletion(
        &prepared,
        .allocation_quarantined,
        quarantine,
        aliased,
    ));
    try std.testing.expectEqual(
        @as(u64, 0),
        pump.crossOwnerQuarantineStatus().event_count,
    );
}

test "C3 invalid ready metadata becomes one canonical teardown-only terminal" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    scratch.validation_bytes_checked = 1;
    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(1),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "",
        false,
    );
    try std.testing.expectEqual(
        read.CollectTerminalReason.invalid_preflight,
        result.collected.terminal.reason,
    );
    try std.testing.expectEqual(
        read.ReadScratchTeardownResult.closed,
        result.teardown_result,
    );
}

test "C3 terminal preserves a non-pristine admit token for outer cleanup" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    scratch.prepared_admit.allocator = std.testing.allocator;
    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(1),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "",
        false,
    );
    try std.testing.expectEqual(
        read.CollectTerminalReason.invalid_preflight,
        result.collected.terminal.reason,
    );
    try std.testing.expectEqual(
        read.ReadScratchTeardownResult.needs_outer_cleanup,
        result.teardown_result,
    );
}

test "C3 generation exhaustion is terminal before the first authority callback" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    try std.testing.expect(read.testing.forceReadyGeneration(
        scratch,
        std.math.maxInt(u64),
    ));
    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(1),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "",
        false,
    );
    try std.testing.expectEqual(
        read.CollectTerminalReason.generation_exhausted,
        result.collected.terminal.reason,
    );
    try std.testing.expectEqual(@as(usize, 0), authority_probe.calls);
    try std.testing.expectEqual(@as(usize, 0), read_probe.calls);
    try std.testing.expectEqual(
        read.ReadScratchTeardownResult.closed,
        result.teardown_result,
    );
}

test "C3 stopped handoff rejects alias, replay, and mismatched disposition" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    read_probe.outcomes[0] = .{ .bytes = 1 };
    read_probe.outcomes[1] = .would_block;
    read_probe.outcome_count = 2;
    const collected = invokeCollector(scratch, .{
        .allowance = allowance(8),
        .read_ops = &read_ops,
        .authority_ops = &authority_ops,
    });
    var receipt = collected.stopped;
    var borrow: read.StoppedBorrow = .{};
    const aliased_receipt: *const read.CollectReceipt =
        @ptrCast(@alignCast(scratch));
    try std.testing.expect(!borrowCollected(
        scratch,
        aliased_receipt,
        &borrow,
    ));
    const aliased_borrow: *read.StoppedBorrow =
        @ptrCast(@alignCast(scratch));
    try std.testing.expect(!borrowCollected(
        scratch,
        &receipt,
        aliased_borrow,
    ));
    try std.testing.expect(borrowCollected(scratch, &receipt, &borrow));
    var replay: read.StoppedBorrow = .{};
    try std.testing.expect(!borrowCollected(scratch, &receipt, &replay));
    try std.testing.expect(viewCollected(scratch, &receipt, &borrow) != null);
    try std.testing.expect(!settleCollected(
        scratch,
        &receipt,
        &borrow,
        .{ .staged = .consumed, .would_block = .not_present },
    ));
    try std.testing.expect(settleCollected(
        scratch,
        &receipt,
        &borrow,
        .{ .staged = .consumed, .would_block = .consumed },
    ));
    try std.testing.expect(viewCollected(scratch, &receipt, &borrow) == null);
    try std.testing.expect(!settleCollected(
        scratch,
        &receipt,
        &borrow,
        .{ .staged = .consumed, .would_block = .consumed },
    ));
    try std.testing.expectEqual(
        read.ReadScratchTeardownResult.closed,
        closeCollector(scratch),
    );
}

test "C3 teardown closes spent and borrowed owners while invalidating old credentials" {
    inline for (.{ false, true }) |borrow_first| {
        const scratch = try std.testing.allocator.create(
            read.ExternalRxReadScratch,
        );
        defer std.testing.allocator.destroy(scratch);
        var read_probe: ReadProbe = undefined;
        var authority_probe: AuthorityProbe = undefined;
        var read_ops: read.RxReadOps = undefined;
        var authority_ops: read.RxReadAuthorityOps = undefined;
        initializeFixture(
            scratch,
            &read_probe,
            &authority_probe,
            &read_ops,
            &authority_ops,
        );
        const collected = invokeCollector(scratch, .{
            .allowance = allowance(1),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        });
        var receipt = collected.stopped;
        var borrow: read.StoppedBorrow = .{};
        if (borrow_first)
            try std.testing.expect(
                borrowCollected(scratch, &receipt, &borrow),
            );
        try std.testing.expectEqual(
            read.ReadScratchTeardownResult.closed,
            closeCollector(scratch),
        );
        try std.testing.expect(
            viewCollected(scratch, &receipt, &borrow) == null,
        );
    }
}

test "C3 teardown reports busy during the hostile read callback" {
    const scratch = try std.testing.allocator.create(read.ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    var read_probe: ReadProbe = undefined;
    var authority_probe: AuthorityProbe = undefined;
    var read_ops: read.RxReadOps = undefined;
    var authority_ops: read.RxReadAuthorityOps = undefined;
    initializeFixture(
        scratch,
        &read_probe,
        &authority_probe,
        &read_ops,
        &authority_ops,
    );
    read_probe.outcomes[0] = .{ .bytes = 1 };
    read_probe.teardown_on_call = 0;
    const result = exerciseCollector(
        scratch,
        .{
            .allowance = allowance(1),
            .read_ops = &read_ops,
            .authority_ops = &authority_ops,
        },
        "x",
        false,
    );
    try std.testing.expectEqual(
        read.ReadScratchTeardownResult.busy,
        read_probe.teardown_result.?,
    );
    try std.testing.expect(result.settled);
    try std.testing.expectEqual(
        read.ReadScratchTeardownResult.closed,
        result.teardown_result,
    );
}
