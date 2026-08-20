//! CR5 host reconnect runtime-set contract.
//!
//! The CR2e reducer remains the single owner of per-runtime state tags. This module only adds
//! canonical multi-runtime identity, terminal aggregation, and the input-admission conjunction
//! that a later `HostReconnectJob` owner consumes. Keeping this leaf pointer-free makes copied,
//! reordered, duplicated, and corrupt rows rejectable before the product owner mutates a graph.

const std = @import("std");
const reconnect_reducer = @import("reconnect_reducer.zig");
const protocol = @import("protocol.zig");

pub const RuntimeLedger = reconnect_reducer.RuntimeLedger;
pub const LocalState = reconnect_reducer.LocalState;
pub const MutationState = reconnect_reducer.MutationState;
pub const max_runtime_rows: usize = protocol.max_inventory_runtimes;

pub const HostJobIdentity = struct {
    job_generation: u64,
    host_id: u128,
    pool_membership_generation: u64,
    expected_connection_generation: u64,

    fn valid(self: HostJobIdentity) bool {
        return self.job_generation != 0 and self.host_id != 0 and
            self.pool_membership_generation != 0 and self.expected_connection_generation != 0;
    }
};

pub const RuntimeIdentity = struct {
    job: HostJobIdentity,
    runtime_handle: u64,
    runtime_addr: u64,
    runtime_generation: u64,
    runtime_id: u128,
    shell_generation: u64,

    fn valid(self: RuntimeIdentity) bool {
        return self.job.valid() and self.runtime_handle != 0 and self.runtime_addr != 0 and
            self.runtime_generation != 0 and self.runtime_id != 0 and self.shell_generation != 0;
    }
};

pub const RuntimeRow = struct {
    identity: RuntimeIdentity,
    ledger_raw: u8,
    local_raw: u8,
    mutation_raw: u8,

    pub fn init(
        identity: RuntimeIdentity,
        ledger_value: RuntimeLedger,
        local_value: LocalState,
        mutation_value: MutationState,
    ) RuntimeRow {
        return .{
            .identity = identity,
            .ledger_raw = @intFromEnum(ledger_value),
            .local_raw = @intFromEnum(local_value),
            .mutation_raw = @intFromEnum(mutation_value),
        };
    }

    fn ledger(self: RuntimeRow) ?RuntimeLedger {
        return std.enums.fromInt(RuntimeLedger, self.ledger_raw);
    }

    fn local(self: RuntimeRow) ?LocalState {
        return std.enums.fromInt(LocalState, self.local_raw);
    }

    fn mutation(self: RuntimeRow) ?MutationState {
        return std.enums.fromInt(MutationState, self.mutation_raw);
    }
};

pub const TerminalSummary = struct {
    job_generation: u64,
    host_id: u128,
    pool_membership_generation: u64,
    expected_connection_generation: u64,
    total: u32,
    published_old: u32,
    published_new: u32,
    frozen_unavailable: u32,
    ended: u32,
    retry_reserved: u32,

    pub fn valid(self: TerminalSummary) bool {
        if (!(HostJobIdentity{
            .job_generation = self.job_generation,
            .host_id = self.host_id,
            .pool_membership_generation = self.pool_membership_generation,
            .expected_connection_generation = self.expected_connection_generation,
        }).valid() or self.total == 0 or self.published_old != 0 or
            self.retry_reserved != self.frozen_unavailable) return false;
        const live = std.math.add(u32, self.published_new, self.frozen_unavailable) catch return false;
        const total = std.math.add(u32, live, self.ended) catch return false;
        return total == self.total;
    }
};

pub const Error = error{
    InvalidRuntimeSet,
    NonTerminalRuntime,
};

/// Validates only canonical identity/raw-tag structure. Phase-specific transition legality remains
/// in `ReconnectReducer`; this function deliberately cannot invent a second state machine.
pub fn validateCanonicalRows(job: HostJobIdentity, rows: []const RuntimeRow) bool {
    if (!job.valid() or rows.len == 0 or rows.len > max_runtime_rows) return false;
    for (rows, 0..) |row, index| {
        if (!row.identity.valid() or !std.meta.eql(row.identity.job, job) or
            row.ledger() == null or row.local() == null or row.mutation() == null) return false;
        if (index != 0 and rows[index - 1].identity.runtime_handle >= row.identity.runtime_handle)
            return false;
        for (rows[0..index]) |prior| {
            if (prior.identity.runtime_addr == row.identity.runtime_addr or
                prior.identity.runtime_id == row.identity.runtime_id) return false;
        }
    }
    return true;
}

/// Produces the only summary allowed to close a host-wide reconnect job. A remaining
/// `published_old` row is intentionally not a terminal success, even if every other row converged.
pub fn summarizeTerminalRows(job: HostJobIdentity, rows: []const RuntimeRow) Error!TerminalSummary {
    if (!validateCanonicalRows(job, rows)) return error.InvalidRuntimeSet;
    var result: TerminalSummary = .{
        .job_generation = job.job_generation,
        .host_id = job.host_id,
        .pool_membership_generation = job.pool_membership_generation,
        .expected_connection_generation = job.expected_connection_generation,
        .total = std.math.cast(u32, rows.len) orelse return error.InvalidRuntimeSet,
        .published_old = 0,
        .published_new = 0,
        .frozen_unavailable = 0,
        .ended = 0,
        .retry_reserved = 0,
    };
    for (rows) |row| switch (row.local().?) {
        .published_old => return error.NonTerminalRuntime,
        .published_new => {
            if (row.ledger().? != .new_controller_evidenced or row.mutation().? != .open)
                return error.NonTerminalRuntime;
            result.published_new = std.math.add(u32, result.published_new, 1) catch
                return error.InvalidRuntimeSet;
        },
        .frozen_unavailable => {
            const ledger = row.ledger().?;
            if ((ledger != .old_valid and ledger != .takeover_sent_unknown and
                ledger != .authority_conflict) or row.mutation().? != .closed)
                return error.NonTerminalRuntime;
            result.frozen_unavailable = std.math.add(u32, result.frozen_unavailable, 1) catch
                return error.InvalidRuntimeSet;
            result.retry_reserved = std.math.add(u32, result.retry_reserved, 1) catch
                return error.InvalidRuntimeSet;
        },
        .ended => {
            if (row.ledger().? != .gone_positive or row.mutation().? != .closed)
                return error.NonTerminalRuntime;
            result.ended = std.math.add(u32, result.ended, 1) catch
                return error.InvalidRuntimeSet;
        },
    };
    if (!result.valid()) return error.InvalidRuntimeSet;
    return result;
}

/// Runtime input does not depend on a broad job phase. It opens only for the exact local terminal
/// state whose controller evidence and mutation epoch are both current.
pub fn inputAllowed(job: HostJobIdentity, row: RuntimeRow) bool {
    return job.valid() and row.identity.valid() and std.meta.eql(row.identity.job, job) and
        row.ledger() == .new_controller_evidenced and
        row.local() == .published_new and row.mutation() == .open;
}

fn testIdentity(handle: u64, runtime_id: u128) RuntimeIdentity {
    return .{
        .job = testJob(),
        .runtime_handle = handle,
        .runtime_addr = 0x1000 + handle * 0x100,
        .runtime_generation = 20 + handle,
        .runtime_id = runtime_id,
        .shell_generation = 30 + handle,
    };
}

fn testJob() HostJobIdentity {
    return .{
        .job_generation = 7,
        .host_id = 70,
        .pool_membership_generation = 71,
        .expected_connection_generation = 72,
    };
}

test "CR5a runtime ledger는 three-runtime mixed terminal summary를 exact 산출한다" {
    const rows = [_]RuntimeRow{
        RuntimeRow.init(testIdentity(1, 101), .new_controller_evidenced, .published_new, .open),
        RuntimeRow.init(testIdentity(2, 102), .authority_conflict, .frozen_unavailable, .closed),
        RuntimeRow.init(testIdentity(3, 103), .gone_positive, .ended, .closed),
    };
    const summary = try summarizeTerminalRows(testJob(), &rows);
    try std.testing.expect(summary.valid());
    try std.testing.expectEqualDeep(TerminalSummary{
        .job_generation = 7,
        .host_id = 70,
        .pool_membership_generation = 71,
        .expected_connection_generation = 72,
        .total = 3,
        .published_old = 0,
        .published_new = 1,
        .frozen_unavailable = 1,
        .ended = 1,
        .retry_reserved = 1,
    }, summary);
}

test "CR5a runtime ledger는 order duplicate zero identity를 mutation 전에 거부한다" {
    const baseline = [_]RuntimeRow{
        RuntimeRow.init(testIdentity(1, 101), .new_controller_evidenced, .published_new, .open),
        RuntimeRow.init(testIdentity(2, 102), .gone_positive, .ended, .closed),
    };
    try std.testing.expect(validateCanonicalRows(testJob(), &baseline));
    var hostile = baseline;
    hostile[1].identity.runtime_handle = 1;
    try std.testing.expect(!validateCanonicalRows(testJob(), &hostile));
    hostile = baseline;
    hostile[1].identity.runtime_addr = baseline[0].identity.runtime_addr;
    try std.testing.expect(!validateCanonicalRows(testJob(), &hostile));
    hostile = baseline;
    hostile[1].identity.runtime_id = 101;
    try std.testing.expect(!validateCanonicalRows(testJob(), &hostile));
    hostile = baseline;
    hostile[0].identity.runtime_addr = 0;
    try std.testing.expect(!validateCanonicalRows(testJob(), &hostile));
    inline for (.{ "job_generation", "host_id", "pool_membership_generation", "expected_connection_generation" }) |field| {
        var wrong_job = testJob();
        @field(wrong_job, field) += 1;
        try std.testing.expect(!validateCanonicalRows(wrong_job, &baseline));

        var invalid_job = testJob();
        @field(invalid_job, field) = 0;
        try std.testing.expect(!validateCanonicalRows(invalid_job, &baseline));

        hostile = baseline;
        @field(hostile[0].identity.job, field) += 1;
        try std.testing.expect(!validateCanonicalRows(testJob(), &hostile));

        hostile = baseline;
        @field(hostile[0].identity.job, field) = 0;
        try std.testing.expect(!validateCanonicalRows(testJob(), &hostile));
    }

    const over_cap = try std.testing.allocator.alloc(RuntimeRow, max_runtime_rows + 1);
    defer std.testing.allocator.free(over_cap);
    for (over_cap, 0..) |*row, index| row.* = RuntimeRow.init(
        testIdentity(@intCast(index + 1), @intCast(index + 1001)),
        .new_controller_evidenced,
        .published_new,
        .open,
    );
    try std.testing.expect(!validateCanonicalRows(testJob(), over_cap));
}

test "CR5a runtime ledger는 raw enum과 illegal terminal pair를 fail close한다" {
    var row = RuntimeRow.init(testIdentity(1, 101), .new_controller_evidenced, .published_new, .open);
    const baseline = [_]RuntimeRow{row};
    try std.testing.expect((try summarizeTerminalRows(testJob(), &baseline)).valid());
    inline for (.{ "ledger_raw", "local_raw", "mutation_raw" }) |field| {
        var hostile = row;
        @field(hostile, field) = 0xff;
        try std.testing.expect(!validateCanonicalRows(testJob(), &[_]RuntimeRow{hostile}));
    }
    row.ledger_raw = @intFromEnum(RuntimeLedger.authority_conflict);
    try std.testing.expectError(error.NonTerminalRuntime, summarizeTerminalRows(testJob(), &[_]RuntimeRow{row}));
    row = RuntimeRow.init(testIdentity(1, 101), .old_valid, .frozen_unavailable, .open);
    try std.testing.expectError(error.NonTerminalRuntime, summarizeTerminalRows(testJob(), &[_]RuntimeRow{row}));
    row = RuntimeRow.init(testIdentity(1, 101), .gone_positive, .ended, .sealed_clean);
    try std.testing.expectError(error.NonTerminalRuntime, summarizeTerminalRows(testJob(), &[_]RuntimeRow{row}));
}

test "CR5a runtime ledger는 input을 new evidenced published open conjunction에만 연다" {
    const allowed = RuntimeRow.init(testIdentity(1, 101), .new_controller_evidenced, .published_new, .open);
    try std.testing.expect(inputAllowed(testJob(), allowed));
    var foreign_job = testJob();
    foreign_job.host_id += 1;
    try std.testing.expect(!inputAllowed(foreign_job, allowed));
    inline for (.{
        RuntimeRow.init(testIdentity(1, 101), .staged_observer, .published_new, .open),
        RuntimeRow.init(testIdentity(1, 101), .new_controller_evidenced, .published_old, .open),
        RuntimeRow.init(testIdentity(1, 101), .new_controller_evidenced, .published_new, .sealed_clean),
        RuntimeRow.init(testIdentity(1, 101), .authority_conflict, .frozen_unavailable, .closed),
        RuntimeRow.init(testIdentity(1, 101), .gone_positive, .ended, .closed),
    }) |row| try std.testing.expect(!inputAllowed(testJob(), row));
}
