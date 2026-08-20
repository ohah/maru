//! CR5b-2c pointer-free cursor and terminal-row transition contract.
//!
//! The backend-owned `HostReconnectJob` remains the product owner. This leaf defines only the
//! allocation-free row updates that happen after the shared Client replacement is published, so
//! the product integration cannot invent a second ledger or roll an earlier success backward.

const std = @import("std");
const ledger = @import("host_reconnect_runtime_ledger.zig");

pub const FailureDisposition = enum(u8) {
    retry_old_valid,
    authority_conflict,
    takeover_sent_unknown,
    ended,
};

pub const Cursor = struct {
    job: ledger.HostJobIdentity = .{
        .job_generation = 0,
        .host_id = 0,
        .pool_membership_generation = 0,
        .expected_connection_generation = 0,
    },
    next_index: u32 = 0,
    terminal_count: u32 = 0,
    failed_raw: u8 = 0,

    fn failed(self: Cursor) ?bool {
        return switch (self.failed_raw) {
            0 => false,
            1 => true,
            else => null,
        };
    }

    pub fn pristine(self: Cursor) bool {
        return self.job.job_generation == 0 and self.job.host_id == 0 and
            self.job.pool_membership_generation == 0 and
            self.job.expected_connection_generation == 0 and self.next_index == 0 and
            self.terminal_count == 0 and self.failed_raw == 0;
    }

    pub fn initial(job: ledger.HostJobIdentity, rows: []const ledger.RuntimeRow) !Cursor {
        if (!ledger.validateCanonicalRows(job, rows)) return error.InvalidRuntimeSet;
        for (rows) |row| if (row.ledger_raw != @intFromEnum(ledger.RuntimeLedger.old_valid) or
            row.local_raw != @intFromEnum(ledger.LocalState.published_old) or
            row.mutation_raw != @intFromEnum(ledger.MutationState.open))
            return error.InvalidRuntimeSet;
        return .{ .job = job, .next_index = 0, .terminal_count = 0, .failed_raw = 0 };
    }

    pub fn valid(self: Cursor, rows: []const ledger.RuntimeRow) bool {
        const is_failed = self.failed() orelse return false;
        if (!ledger.validateCanonicalRows(self.job, rows) or self.next_index > rows.len or
            self.terminal_count != self.next_index or (is_failed and self.next_index != rows.len))
            return false;
        for (rows, 0..) |row, index| {
            if (index < self.next_index) {
                if (row.local_raw == @intFromEnum(ledger.LocalState.published_old)) return false;
            } else if (row.ledger_raw != @intFromEnum(ledger.RuntimeLedger.old_valid) or
                row.local_raw != @intFromEnum(ledger.LocalState.published_old) or
                row.mutation_raw != @intFromEnum(ledger.MutationState.open)) return false;
        }
        return true;
    }

    pub fn activeRow(self: Cursor, rows: []const ledger.RuntimeRow) ?ledger.RuntimeIdentity {
        if (!self.valid(rows) or self.failed().? or self.next_index == rows.len) return null;
        return rows[self.next_index].identity;
    }

    pub fn commitPublishedNew(self: *Cursor, rows: []ledger.RuntimeRow) !void {
        if (!self.valid(rows) or self.failed().? or self.next_index == rows.len)
            return error.InvalidRuntimeSet;
        const index: usize = self.next_index;
        rows[index] = ledger.RuntimeRow.init(
            rows[index].identity,
            .new_controller_evidenced,
            .published_new,
            .open,
        );
        self.next_index += 1;
        self.terminal_count += 1;
    }

    /// A post-publication failure is forward-only. The active row keeps its exact provenance;
    /// every untouched suffix row becomes retryable without issuing status/takeover/resize wire.
    pub fn failAndResolveRemaining(
        self: *Cursor,
        rows: []ledger.RuntimeRow,
        disposition: FailureDisposition,
    ) !ledger.TerminalSummary {
        if (!self.valid(rows) or self.failed().? or self.next_index == rows.len)
            return error.InvalidRuntimeSet;
        const current: usize = self.next_index;
        rows[current] = switch (disposition) {
            .retry_old_valid => ledger.RuntimeRow.init(
                rows[current].identity,
                .old_valid,
                .frozen_unavailable,
                .closed,
            ),
            .authority_conflict => ledger.RuntimeRow.init(
                rows[current].identity,
                .authority_conflict,
                .frozen_unavailable,
                .closed,
            ),
            .takeover_sent_unknown => ledger.RuntimeRow.init(
                rows[current].identity,
                .takeover_sent_unknown,
                .frozen_unavailable,
                .closed,
            ),
            .ended => ledger.RuntimeRow.init(
                rows[current].identity,
                .gone_positive,
                .ended,
                .closed,
            ),
        };
        for (rows[current + 1 ..]) |*row| row.* = ledger.RuntimeRow.init(
            row.identity,
            .old_valid,
            .frozen_unavailable,
            .closed,
        );
        self.next_index = @intCast(rows.len);
        self.terminal_count = @intCast(rows.len);
        self.failed_raw = 1;
        return ledger.summarizeTerminalRows(self.job, rows);
    }

    pub fn finishSuccess(self: Cursor, rows: []const ledger.RuntimeRow) !ledger.TerminalSummary {
        if (!self.valid(rows) or self.failed().? or self.next_index != rows.len)
            return error.InvalidRuntimeSet;
        return ledger.summarizeTerminalRows(self.job, rows);
    }
};

fn testJob() ledger.HostJobIdentity {
    return .{
        .job_generation = 51,
        .host_id = 52,
        .pool_membership_generation = 53,
        .expected_connection_generation = 54,
    };
}

fn testRows() [3]ledger.RuntimeRow {
    var rows: [3]ledger.RuntimeRow = undefined;
    for (&rows, 0..) |*row, index| row.* = ledger.RuntimeRow.init(.{
        .job = testJob(),
        .runtime_handle = index + 1,
        .runtime_addr = 0x1000 + index * 0x100,
        .runtime_generation = 61 + index,
        .runtime_id = 71 + index,
        .shell_generation = 81 + index,
    }, .old_valid, .published_old, .open);
    return rows;
}

test "CR5b-2c cursor는 three-runtime success를 handle 순서와 terminal summary로 닫는다" {
    var rows = testRows();
    var cursor = try Cursor.initial(testJob(), &rows);
    for (0..rows.len) |index| {
        try std.testing.expectEqual(rows[index].identity, cursor.activeRow(&rows).?);
        try cursor.commitPublishedNew(&rows);
        try std.testing.expect(cursor.valid(&rows));
    }
    const summary = try cursor.finishSuccess(&rows);
    try std.testing.expectEqual(@as(u32, 3), summary.published_new);
    try std.testing.expectEqual(@as(u32, 0), summary.published_old);
    try std.testing.expectEqual(@as(u32, 0), summary.frozen_unavailable);
}

test "CR5b-2c cursor는 kth failure에서 앞선 success를 보존하고 suffix를 finite resolve한다" {
    inline for (0..3) |failure_index| {
        var rows = testRows();
        var cursor = try Cursor.initial(testJob(), &rows);
        for (0..failure_index) |_| try cursor.commitPublishedNew(&rows);
        const before_success = rows;
        const summary = try cursor.failAndResolveRemaining(&rows, .authority_conflict);
        try std.testing.expectEqual(@as(u32, failure_index), summary.published_new);
        try std.testing.expectEqual(@as(u32, 3 - failure_index), summary.frozen_unavailable);
        try std.testing.expectEqual(@as(u32, 0), summary.published_old);
        for (0..failure_index) |index| try std.testing.expectEqual(before_success[index], rows[index]);
        try std.testing.expect(cursor.valid(&rows));
    }
}

test "CR5b-2c cursor는 copy order drift replay와 nonterminal finish를 거부한다" {
    var rows = testRows();
    var cursor = try Cursor.initial(testJob(), &rows);
    var copied = cursor;
    copied.next_index = 1;
    try std.testing.expect(!copied.valid(&rows));
    var reordered = rows;
    std.mem.swap(ledger.RuntimeRow, &reordered[0], &reordered[1]);
    try std.testing.expect(!cursor.valid(&reordered));
    const cursor_before_raw_sweep = cursor;
    for (2..256) |raw| {
        var corrupt = cursor;
        corrupt.failed_raw = @intCast(raw);
        try std.testing.expect(!corrupt.valid(&rows));
        try std.testing.expectEqual(cursor_before_raw_sweep, cursor);
    }
    try std.testing.expectError(error.InvalidRuntimeSet, cursor.finishSuccess(&rows));
    try cursor.commitPublishedNew(&rows);
    const summary = try cursor.failAndResolveRemaining(&rows, .takeover_sent_unknown);
    try std.testing.expect(summary.valid());
    try std.testing.expectError(
        error.InvalidRuntimeSet,
        cursor.failAndResolveRemaining(&rows, .retry_old_valid),
    );
}
