//! CR5d-1 host reconnect Window transaction prerequisite.
//!
//! This owner does not mutate AppSession topology or send takeover/terminate wire. It seals the
//! exact CR5 terminal summary, canonical runtime rows, two-Window binding projection, and one
//! user action so CR5d-2 can consume a single final-address authority instead of re-reading a
//! moving Window graph after a click.

const std = @import("std");
const ledger = @import("host_reconnect_runtime_ledger.zig");
const process_seal = @import("process_seal_service.zig");

pub const max_bindings = ledger.max_runtime_rows;

pub const ActionKind = enum(u8) {
    take_control = 1,
    close = 2,
};

pub const WindowBinding = struct {
    window_addr: u64,
    app_session_generation: u64,
    graph_generation: u64,
    runtime_handle: u64,
    runtime_generation: u64,
    surface_id: u64,

    fn valid(self: WindowBinding) bool {
        return self.window_addr != 0 and self.app_session_generation != 0 and
            self.graph_generation != 0 and self.runtime_handle != 0 and
            self.runtime_generation != 0 and self.surface_id != 0;
    }
};

pub const ActionRequest = struct {
    kind_raw: u8,
    target_window_addr: u64,
    target_runtime_handle: u64,
    target_surface_id: u64,
    action_generation: u64,
    expires_at_ns: u64,
};

pub const Lifecycle = enum(u8) { pristine = 0, prepared = 1, consumed = 2 };
const OwnerLifecycle = enum(u8) { pristine = 0, ready = 1 };

pub const Owner = struct {
    self_addr: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    owner_generation: u64 = 0,
    next_transaction_generation: u64 = 0,
    active_transaction_addr: u64 = 0,
    active_action_generation: u64 = 0,
    spent_action_generation: u64 = 0,
    spent_action_digest: process_seal.CleanupSeal = [_]u8{0} ** 32,
    lifecycle_raw: u8 = @intFromEnum(OwnerLifecycle.pristine),
    seal: process_seal.CleanupSeal = [_]u8{0} ** 32,

    pub fn initInPlace(self: *Owner, owner_generation: u64) !void {
        if (!std.meta.eql(self.*, Owner{}) or owner_generation == 0) return error.InvalidAuthority;
        const ready = try process_seal.currentReadyIdentity();
        var next: Owner = .{
            .self_addr = @intFromPtr(self),
            .pid = ready.pid,
            .process_nonce = ready.process_nonce,
            .thread_id = @intCast(std.Thread.getCurrentId()),
            .owner_generation = owner_generation,
            .lifecycle_raw = @intFromEnum(OwnerLifecycle.ready),
        };
        next.seal = try ownerSeal(&next, @intFromPtr(self));
        self.* = next;
    }
};

pub const Transaction = struct {
    self_addr: u64 = 0,
    owner_addr: u64 = 0,
    owner_generation: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    transaction_generation: u64 = 0,
    job: ledger.HostJobIdentity = .{
        .job_generation = 0,
        .host_id = 0,
        .pool_membership_generation = 0,
        .expected_connection_generation = 0,
    },
    summary_digest: process_seal.CleanupSeal = [_]u8{0} ** 32,
    rows_digest: process_seal.CleanupSeal = [_]u8{0} ** 32,
    bindings_digest: process_seal.CleanupSeal = [_]u8{0} ** 32,
    binding_count: u32 = 0,
    action: ActionRequest = .{
        .kind_raw = 0,
        .target_window_addr = 0,
        .target_runtime_handle = 0,
        .target_surface_id = 0,
        .action_generation = 0,
        .expires_at_ns = 0,
    },
    lifecycle_raw: u8 = @intFromEnum(Lifecycle.pristine),
    seal: process_seal.CleanupSeal = [_]u8{0} ** 32,
};

pub const Error = error{
    InvalidAuthority,
    InvalidBindingSet,
    Expired,
};

pub fn prepare(
    owner: *Owner,
    out: *Transaction,
    summary: ledger.TerminalSummary,
    rows: []const ledger.RuntimeRow,
    bindings: []const WindowBinding,
    action: ActionRequest,
    now_ns: u64,
) !void {
    if (!validOwner(owner) or !std.meta.eql(out.*, Transaction{}) or
        !canonical(summary, rows, bindings, action) or action.expires_at_ns <= now_ns)
        return error.InvalidAuthority;
    if (owner.active_transaction_addr != 0) return error.Busy;
    if (std.mem.eql(u8, &owner.spent_action_digest, &actionIdentityDigest(action)))
        return error.InvalidAuthority;
    const transaction_generation = std.math.add(u64, owner.next_transaction_generation, 1) catch
        return error.InvalidAuthority;
    const ready = try process_seal.currentReadyIdentity();
    var next_transaction: Transaction = .{
        .self_addr = @intFromPtr(out),
        .owner_addr = @intFromPtr(owner),
        .owner_generation = owner.owner_generation,
        .pid = ready.pid,
        .process_nonce = ready.process_nonce,
        .thread_id = @intCast(std.Thread.getCurrentId()),
        .transaction_generation = transaction_generation,
        .job = rows[0].identity.job,
        .summary_digest = summaryDigest(summary),
        .rows_digest = rowsDigest(rows),
        .bindings_digest = bindingsDigest(bindings),
        .binding_count = @intCast(bindings.len),
        .action = action,
        .lifecycle_raw = @intFromEnum(Lifecycle.prepared),
    };
    next_transaction.seal = try transactionSeal(&next_transaction, @intFromPtr(out));
    var next_owner = owner.*;
    next_owner.next_transaction_generation = transaction_generation;
    next_owner.active_transaction_addr = @intFromPtr(out);
    next_owner.active_action_generation = action.action_generation;
    next_owner.seal = try ownerSeal(&next_owner, @intFromPtr(owner));
    out.* = next_transaction;
    owner.* = next_owner;
}

pub fn validate(
    owner: *const Owner,
    transaction: *const Transaction,
    summary: ledger.TerminalSummary,
    rows: []const ledger.RuntimeRow,
    bindings: []const WindowBinding,
    now_ns: u64,
) bool {
    if (!validOwner(owner) or transaction.lifecycle_raw != @intFromEnum(Lifecycle.prepared) or
        transaction.self_addr != @intFromPtr(transaction) or transaction.pid != process_seal.currentProcessId() or
        transaction.owner_addr != @intFromPtr(owner) or transaction.owner_generation != owner.owner_generation or
        owner.active_transaction_addr != @intFromPtr(transaction) or
        owner.active_action_generation != transaction.action.action_generation or
        owner.next_transaction_generation != transaction.transaction_generation or
        transaction.thread_id != @as(u64, @intCast(std.Thread.getCurrentId())) or
        transaction.transaction_generation == 0 or transaction.action.expires_at_ns <= now_ns or
        !canonical(summary, rows, bindings, transaction.action) or
        !std.meta.eql(transaction.job, rows[0].identity.job) or transaction.binding_count != bindings.len or
        !std.mem.eql(u8, &transaction.summary_digest, &summaryDigest(summary)) or
        !std.mem.eql(u8, &transaction.rows_digest, &rowsDigest(rows)) or
        !std.mem.eql(u8, &transaction.bindings_digest, &bindingsDigest(bindings))) return false;
    const expected = transactionSeal(transaction, @intFromPtr(transaction)) catch return false;
    return std.crypto.timing_safe.eql(process_seal.CleanupSeal, expected, transaction.seal);
}

pub fn consume(
    owner: *Owner,
    transaction: *Transaction,
    summary: ledger.TerminalSummary,
    rows: []const ledger.RuntimeRow,
    bindings: []const WindowBinding,
    now_ns: u64,
) Error!void {
    if (transaction.action.expires_at_ns == 0) return error.InvalidAuthority;
    if (transaction.action.expires_at_ns <= now_ns) {
        if (!validate(owner, transaction, summary, rows, bindings, transaction.action.expires_at_ns - 1))
            return error.InvalidAuthority;
        consumeNoFail(owner, transaction);
        return error.Expired;
    }
    if (!validate(owner, transaction, summary, rows, bindings, now_ns)) return error.InvalidAuthority;
    consumeNoFail(owner, transaction);
}

/// Reuses the backend-owned storage only after the prior one-shot transaction is provably spent.
/// The owner retains the spent action digest/generation, so recycling storage cannot re-arm the
/// same gesture.
pub fn recycleConsumed(owner: *Owner, transaction: *Transaction) Error!void {
    if (!consumedExact(owner, transaction)) return error.InvalidAuthority;
    transaction.* = .{};
}

pub fn consumedExact(owner: *const Owner, transaction: *const Transaction) bool {
    const digest = actionIdentityDigest(transaction.action);
    return validOwner(owner) and owner.active_transaction_addr == 0 and owner.active_action_generation == 0 and
        transaction.self_addr == @intFromPtr(transaction) and transaction.owner_addr == @intFromPtr(owner) and
        transaction.owner_generation == owner.owner_generation and transaction.pid == owner.pid and
        transaction.process_nonce == owner.process_nonce and transaction.thread_id == owner.thread_id and
        transaction.lifecycle_raw == @intFromEnum(Lifecycle.consumed) and
        transaction.action.action_generation == owner.spent_action_generation and
        std.mem.eql(u8, &digest, &owner.spent_action_digest) and
        std.mem.eql(u8, &transaction.seal, &([_]u8{0} ** 32));
}

/// Retires an exact prepared gesture after its external Window/job projection became stale.  It
/// intentionally does not validate those moving projections; the internal final-address owner and
/// transaction seal are sufficient to prove which one-shot action is being revoked.
pub fn revokeStale(owner: *Owner, transaction: *Transaction) Error!void {
    if (!validOwner(owner) or transaction.lifecycle_raw != @intFromEnum(Lifecycle.prepared) or
        transaction.self_addr != @intFromPtr(transaction) or transaction.owner_addr != @intFromPtr(owner) or
        transaction.owner_generation != owner.owner_generation or transaction.pid != owner.pid or
        transaction.process_nonce != owner.process_nonce or transaction.thread_id != owner.thread_id or
        owner.active_transaction_addr != @intFromPtr(transaction) or
        owner.active_action_generation != transaction.action.action_generation)
        return error.InvalidAuthority;
    const expected = transactionSeal(transaction, @intFromPtr(transaction)) catch return error.InvalidAuthority;
    if (!std.crypto.timing_safe.eql(process_seal.CleanupSeal, expected, transaction.seal))
        return error.InvalidAuthority;
    consumeNoFail(owner, transaction);
}

fn consumeNoFail(owner: *Owner, transaction: *Transaction) void {
    var next_owner = owner.*;
    next_owner.active_transaction_addr = 0;
    next_owner.active_action_generation = 0;
    next_owner.spent_action_generation = transaction.action.action_generation;
    next_owner.spent_action_digest = actionIdentityDigest(transaction.action);
    next_owner.seal = ownerSeal(&next_owner, @intFromPtr(owner)) catch
        process_seal.fatalIntegrity(.proof_loss);
    transaction.lifecycle_raw = @intFromEnum(Lifecycle.consumed);
    transaction.seal = [_]u8{0} ** 32;
    owner.* = next_owner;
}

fn canonical(
    summary: ledger.TerminalSummary,
    rows: []const ledger.RuntimeRow,
    bindings: []const WindowBinding,
    action: ActionRequest,
) bool {
    if (rows.len < 2 or bindings.len != rows.len or bindings.len > max_bindings or
        !ledger.validateCanonicalRows(rows[0].identity.job, rows)) return false;
    const expected = ledger.summarizeTerminalRows(rows[0].identity.job, rows) catch return false;
    if (!std.meta.eql(expected, summary) or !summary.valid() or summary.published_new != 0 or
        summary.frozen_unavailable != summary.total or summary.retry_reserved != summary.total or
        summary.ended != 0 or std.enums.fromInt(ActionKind, action.kind_raw) == null or action.action_generation == 0 or
        action.target_window_addr == 0 or action.target_runtime_handle == 0 or action.target_surface_id == 0)
        return false;
    var first_window: u64 = 0;
    var second_window: u64 = 0;
    var target_found = false;
    for (bindings, 0..) |binding, index| {
        if (!binding.valid() or binding.runtime_handle != rows[index].identity.runtime_handle or
            binding.runtime_generation != rows[index].identity.runtime_generation) return false;
        if (index != 0 and bindings[index - 1].runtime_handle >= binding.runtime_handle) return false;
        for (bindings[0..index]) |prior| if (prior.window_addr == binding.window_addr and
            (prior.app_session_generation != binding.app_session_generation or
                prior.graph_generation != binding.graph_generation)) return false;
        if (first_window == 0) first_window = binding.window_addr else if (binding.window_addr != first_window) {
            if (second_window == 0) second_window = binding.window_addr else if (binding.window_addr != second_window) return false;
        }
        for (bindings[0..index]) |prior| if (prior.surface_id == binding.surface_id) return false;
        if (binding.window_addr == action.target_window_addr and
            binding.runtime_handle == action.target_runtime_handle and binding.surface_id == action.target_surface_id)
            target_found = true;
    }
    return second_window != 0 and target_found;
}

fn transactionSeal(transaction: *const Transaction, self_addr: u64) process_seal.ReadyError!process_seal.CleanupSeal {
    return process_seal.hostReconnectWindowTransactionSeal(transaction.pid, transaction.process_nonce, .{
        .self_addr = self_addr,
        .owner_addr = transaction.owner_addr,
        .owner_generation = transaction.owner_generation,
        .thread_id = transaction.thread_id,
        .transaction_generation = transaction.transaction_generation,
        .job_generation = transaction.job.job_generation,
        .host_id = transaction.job.host_id,
        .pool_membership_generation = transaction.job.pool_membership_generation,
        .expected_connection_generation = transaction.job.expected_connection_generation,
        .summary_digest = transaction.summary_digest,
        .rows_digest = transaction.rows_digest,
        .bindings_digest = transaction.bindings_digest,
        .binding_count = transaction.binding_count,
        .target_window_addr = transaction.action.target_window_addr,
        .target_runtime_handle = transaction.action.target_runtime_handle,
        .target_surface_id = transaction.action.target_surface_id,
        .action_generation = transaction.action.action_generation,
        .expires_at_ns = transaction.action.expires_at_ns,
        .action_kind_raw = transaction.action.kind_raw,
        .lifecycle_raw = transaction.lifecycle_raw,
    });
}

fn validOwner(owner: *const Owner) bool {
    const empty_digest = [_]u8{0} ** 32;
    if (owner.lifecycle_raw != @intFromEnum(OwnerLifecycle.ready) or owner.self_addr != @intFromPtr(owner) or
        owner.pid != process_seal.currentProcessId() or owner.thread_id != @as(u64, @intCast(std.Thread.getCurrentId())) or
        owner.owner_generation == 0 or
        ((owner.active_transaction_addr == 0) != (owner.active_action_generation == 0)) or
        ((owner.spent_action_generation == 0) != std.mem.eql(u8, &owner.spent_action_digest, &empty_digest))) return false;
    const expected = ownerSeal(owner, @intFromPtr(owner)) catch return false;
    return std.crypto.timing_safe.eql(process_seal.CleanupSeal, expected, owner.seal);
}

fn ownerSeal(owner: *const Owner, self_addr: u64) process_seal.ReadyError!process_seal.CleanupSeal {
    return process_seal.hostReconnectWindowOwnerSeal(owner.pid, owner.process_nonce, .{
        .self_addr = self_addr,
        .thread_id = owner.thread_id,
        .owner_generation = owner.owner_generation,
        .next_transaction_generation = owner.next_transaction_generation,
        .active_transaction_addr = owner.active_transaction_addr,
        .active_action_generation = owner.active_action_generation,
        .spent_action_generation = owner.spent_action_generation,
        .spent_action_digest = owner.spent_action_digest,
        .lifecycle_raw = owner.lifecycle_raw,
    });
}

fn hashInt(hasher: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
    var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

fn summaryDigest(summary: ledger.TerminalSummary) process_seal.CleanupSeal {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashInt(&hasher, u64, summary.job_generation);
    hashInt(&hasher, u128, summary.host_id);
    hashInt(&hasher, u64, summary.pool_membership_generation);
    hashInt(&hasher, u64, summary.expected_connection_generation);
    hashInt(&hasher, u32, summary.total);
    hashInt(&hasher, u32, summary.published_old);
    hashInt(&hasher, u32, summary.published_new);
    hashInt(&hasher, u32, summary.frozen_unavailable);
    hashInt(&hasher, u32, summary.ended);
    hashInt(&hasher, u32, summary.retry_reserved);
    return hasher.finalResult();
}

fn bindingsDigest(bindings: []const WindowBinding) process_seal.CleanupSeal {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashInt(&hasher, u32, @intCast(bindings.len));
    for (bindings) |binding| {
        hashInt(&hasher, u64, binding.window_addr);
        hashInt(&hasher, u64, binding.app_session_generation);
        hashInt(&hasher, u64, binding.graph_generation);
        hashInt(&hasher, u64, binding.runtime_handle);
        hashInt(&hasher, u64, binding.runtime_generation);
        hashInt(&hasher, u64, binding.surface_id);
    }
    return hasher.finalResult();
}

fn rowsDigest(rows: []const ledger.RuntimeRow) process_seal.CleanupSeal {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashInt(&hasher, u32, @intCast(rows.len));
    for (rows) |row| {
        hashInt(&hasher, u64, row.identity.job.job_generation);
        hashInt(&hasher, u128, row.identity.job.host_id);
        hashInt(&hasher, u64, row.identity.job.pool_membership_generation);
        hashInt(&hasher, u64, row.identity.job.expected_connection_generation);
        hashInt(&hasher, u64, row.identity.runtime_handle);
        hashInt(&hasher, usize, row.identity.runtime_addr);
        hashInt(&hasher, u64, row.identity.runtime_generation);
        hashInt(&hasher, u128, row.identity.runtime_id);
        hashInt(&hasher, u64, row.identity.shell_generation);
        hashInt(&hasher, u8, row.ledger_raw);
        hashInt(&hasher, u8, row.local_raw);
        hashInt(&hasher, u8, row.mutation_raw);
    }
    return hasher.finalResult();
}

fn actionIdentityDigest(action: ActionRequest) process_seal.CleanupSeal {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashInt(&hasher, u8, action.kind_raw);
    hashInt(&hasher, u64, action.target_window_addr);
    hashInt(&hasher, u64, action.target_runtime_handle);
    hashInt(&hasher, u64, action.target_surface_id);
    hashInt(&hasher, u64, action.action_generation);
    return hasher.finalResult();
}

fn testJob() ledger.HostJobIdentity {
    return .{ .job_generation = 7, .host_id = 8, .pool_membership_generation = 9, .expected_connection_generation = 10 };
}

fn testRows() [2]ledger.RuntimeRow {
    return .{
        ledger.RuntimeRow.init(.{ .job = testJob(), .runtime_handle = 1, .runtime_addr = 101, .runtime_generation = 11, .runtime_id = 21, .shell_generation = 31 }, .new_controller_evidenced, .frozen_unavailable, .closed),
        ledger.RuntimeRow.init(.{ .job = testJob(), .runtime_handle = 2, .runtime_addr = 102, .runtime_generation = 12, .runtime_id = 22, .shell_generation = 32 }, .old_valid, .frozen_unavailable, .closed),
    };
}

fn testBindings() [2]WindowBinding {
    return .{
        .{ .window_addr = 1001, .app_session_generation = 41, .graph_generation = 51, .runtime_handle = 1, .runtime_generation = 11, .surface_id = 61 },
        .{ .window_addr = 1002, .app_session_generation = 42, .graph_generation = 52, .runtime_handle = 2, .runtime_generation = 12, .surface_id = 62 },
    };
}

fn testAction() ActionRequest {
    return .{ .kind_raw = @intFromEnum(ActionKind.take_control), .target_window_addr = 1001, .target_runtime_handle = 1, .target_surface_id = 61, .action_generation = 71, .expires_at_ns = 100 };
}

fn ensureReady() !void {
    if (process_seal.currentReadyIdentity()) |_| return else |err| switch (err) {
        error.NotReady => try @import("host_adapter.zig").HostAdapter.initializeProcessRuntime(),
        else => return err,
    }
}

test "CR5d-1 Window transaction은 terminal summary와 two-window binding을 exact 봉인한다" {
    try ensureReady();
    const rows = testRows();
    const summary = try ledger.summarizeTerminalRows(testJob(), &rows);
    const bindings = testBindings();
    var owner: Owner = .{};
    try owner.initInPlace(80);
    var transaction: Transaction = .{};
    try prepare(&owner, &transaction, summary, &rows, &bindings, testAction(), 99);
    var duplicate: Transaction = .{};
    try std.testing.expectError(error.Busy, prepare(&owner, &duplicate, summary, &rows, &bindings, testAction(), 99));
    try std.testing.expect(validate(&owner, &transaction, summary, &rows, &bindings, 99));
    try consume(&owner, &transaction, summary, &rows, &bindings, 99);
    try std.testing.expect(consumedExact(&owner, &transaction));
    var consumed_copy = transaction;
    try std.testing.expect(!consumedExact(&owner, &consumed_copy));
    inline for (.{ "target_window_addr", "target_runtime_handle", "target_surface_id", "action_generation" }) |field| {
        var hostile = transaction;
        @field(hostile.action, field) += 1;
        try std.testing.expect(!consumedExact(&owner, &hostile));
    }
    try std.testing.expectError(error.InvalidAuthority, consume(&owner, &transaction, summary, &rows, &bindings, 99));
    try std.testing.expectError(error.InvalidAuthority, prepare(&owner, &duplicate, summary, &rows, &bindings, testAction(), 99));
    const sibling_action: ActionRequest = .{
        .kind_raw = @intFromEnum(ActionKind.close),
        .target_window_addr = 1002,
        .target_runtime_handle = 2,
        .target_surface_id = 62,
        .action_generation = 1,
        .expires_at_ns = 200,
    };
    try prepare(&owner, &duplicate, summary, &rows, &bindings, sibling_action, 100);
    try consume(&owner, &duplicate, summary, &rows, &bindings, 100);
}

test "CR5d-1 Window transaction은 copy와 binding summary action drift를 mutation 0으로 거부한다" {
    try ensureReady();
    const rows = testRows();
    const summary = try ledger.summarizeTerminalRows(testJob(), &rows);
    const bindings = testBindings();
    var owner: Owner = .{};
    try owner.initInPlace(81);
    var transaction: Transaction = .{};
    try prepare(&owner, &transaction, summary, &rows, &bindings, testAction(), 1);
    const owner_before = owner;
    const before = transaction;
    var copied_owner = owner;
    try std.testing.expect(!validate(&copied_owner, &transaction, summary, &rows, &bindings, 1));
    inline for (.{ "owner_generation", "next_transaction_generation", "active_transaction_addr", "active_action_generation" }) |field| {
        var hostile_owner = owner;
        @field(hostile_owner, field) += 1;
        try std.testing.expect(!validate(&hostile_owner, &transaction, summary, &rows, &bindings, 1));
        try std.testing.expectEqualDeep(owner_before, owner);
    }
    for (0..256) |raw| {
        if (raw == @intFromEnum(OwnerLifecycle.ready)) continue;
        var hostile_owner = owner;
        hostile_owner.lifecycle_raw = @intCast(raw);
        try std.testing.expect(!validate(&hostile_owner, &transaction, summary, &rows, &bindings, 1));
    }
    var copied = transaction;
    try std.testing.expect(!validate(&owner, &copied, summary, &rows, &bindings, 1));
    inline for (.{ "window_addr", "app_session_generation", "graph_generation", "runtime_generation", "surface_id" }) |field| {
        var hostile = bindings;
        @field(hostile[0], field) += 1;
        try std.testing.expect(!validate(&owner, &transaction, summary, &rows, &hostile, 1));
        try std.testing.expectEqualDeep(before, transaction);
    }
    var hostile_summary = summary;
    hostile_summary.retry_reserved -= 1;
    try std.testing.expect(!validate(&owner, &transaction, hostile_summary, &rows, &bindings, 1));
    inline for (.{ "runtime_addr", "runtime_id", "shell_generation" }) |field| {
        var hostile_rows = rows;
        @field(hostile_rows[0].identity, field) += 1;
        try std.testing.expect(!validate(&owner, &transaction, summary, &hostile_rows, &bindings, 1));
        try std.testing.expectEqualDeep(before, transaction);
    }
    inline for (.{ "job_generation", "host_id", "pool_membership_generation", "expected_connection_generation" }) |field| {
        var hostile_transaction = transaction;
        @field(hostile_transaction.job, field) += 1;
        try std.testing.expect(!validate(&owner, &hostile_transaction, summary, &rows, &bindings, 1));
    }
    inline for (.{ "owner_generation", "transaction_generation", "pid", "process_nonce", "thread_id" }) |field| {
        var hostile_transaction = transaction;
        @field(hostile_transaction, field) += 1;
        try std.testing.expect(!validate(&owner, &hostile_transaction, summary, &rows, &bindings, 1));
    }
    var hostile_action = transaction;
    inline for (.{ "target_window_addr", "target_runtime_handle", "target_surface_id", "action_generation", "expires_at_ns" }) |field| {
        hostile_action = transaction;
        @field(hostile_action.action, field) += 1;
        try std.testing.expect(!validate(&owner, &hostile_action, summary, &rows, &bindings, 1));
    }
    for (0..256) |raw| {
        if (raw == @intFromEnum(ActionKind.take_control) or raw == @intFromEnum(ActionKind.close)) continue;
        hostile_action = transaction;
        hostile_action.action.kind_raw = @intCast(raw);
        try std.testing.expect(!validate(&owner, &hostile_action, summary, &rows, &bindings, 1));
    }
    for (3..256) |raw| {
        var corrupt = transaction;
        corrupt.lifecycle_raw = @intCast(raw);
        try std.testing.expect(!validate(&owner, &corrupt, summary, &rows, &bindings, 1));
    }
    try std.testing.expectEqualDeep(owner_before, owner);
    try std.testing.expectEqualDeep(before, transaction);
}

test "CR5d-1 Window transaction은 deadline exact와 double consume을 닫는다" {
    try ensureReady();
    const rows = testRows();
    const summary = try ledger.summarizeTerminalRows(testJob(), &rows);
    const bindings = testBindings();
    inline for (.{ @as(u64, 100), @as(u64, 101) }) |now_ns| {
        var owner: Owner = .{};
        try owner.initInPlace(82 + now_ns);
        var transaction: Transaction = .{};
        try std.testing.expectError(error.InvalidAuthority, prepare(&owner, &transaction, summary, &rows, &bindings, testAction(), now_ns));
        try std.testing.expectEqualDeep(Transaction{}, transaction);
    }
    inline for (.{ @as(u64, 100), @as(u64, 101) }) |now_ns| {
        var owner: Owner = .{};
        try owner.initInPlace(184 + now_ns);
        var transaction: Transaction = .{};
        try prepare(&owner, &transaction, summary, &rows, &bindings, testAction(), 99);
        try std.testing.expectError(error.Expired, consume(&owner, &transaction, summary, &rows, &bindings, now_ns));
        try std.testing.expectEqual(@intFromEnum(Lifecycle.consumed), transaction.lifecycle_raw);
        try std.testing.expectEqual(@as(u64, 71), owner.spent_action_generation);
    }
}
