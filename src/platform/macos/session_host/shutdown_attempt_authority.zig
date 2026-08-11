//! 종료 target의 destructive attempt와 connection receipt를 final-address process seal로 소유한다.

const std = @import("std");
const contract = @import("maru").app.shutdown_wire_contract;
const close_authority = @import("remote_close_authority.zig");
const process_seal = @import("process_seal_service.zig");
const builtin = @import("builtin");

pub const Lifecycle = enum(u8) { pristine, ready, connection_live, terminal };
pub const max_shutdown_terminate_attempts: u64 = 3;

pub const ShutdownAttemptAuthority = struct {
    pid: u32 = 0,
    reserved_pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    close_request_generation: u64 = 0,
    target_digest: contract.Digest = contract.zero_digest,
    attempt_generation: u64 = 0,
    disposition_raw: u8 = 0,
    lifecycle_raw: u8 = 0,
    connection_lease_generation: u64 = 0,
    deadline_ns: u64 = 0,
    outcome_digest: contract.Digest = contract.zero_digest,
    seal: contract.Digest = contract.zero_digest,
};

pub const Error = error{ InvalidOwner, InvalidRequest, AttemptCap, Deadline } || process_seal.ReadyError;

pub const ProofLossStage = enum(u8) { none, attempt_generation_overflow, lease_generation_overflow };

threadlocal var proof_loss_authority_addr: usize = 0;
threadlocal var proof_loss_stage_raw: u8 = 0;

pub fn prepare(
    out: *ShutdownAttemptAuthority,
    close_request_generation: u64,
    target_digest: contract.Digest,
    disposition: close_authority.CloseDisposition,
    deadline_ns: u64,
) Error!void {
    if (!std.meta.eql(out.*, ShutdownAttemptAuthority{})) return error.InvalidOwner;
    if (close_request_generation == 0 or std.mem.allEqual(u8, &target_digest, 0) or deadline_ns == 0)
        return error.InvalidRequest;
    const ready = try process_seal.currentReadyIdentity();
    const thread_id: u64 = @intCast(std.Thread.getCurrentId());
    out.* = .{
        .pid = ready.pid,
        .process_nonce = ready.process_nonce,
        .thread_id = thread_id,
        .close_request_generation = close_request_generation,
        .target_digest = target_digest,
        .disposition_raw = @intFromEnum(disposition),
        .lifecycle_raw = @intFromEnum(Lifecycle.ready),
        .deadline_ns = deadline_ns,
    };
    out.seal = try authoritySeal(out);
}

pub fn valid(authority: *const ShutdownAttemptAuthority) bool {
    if (authority.pid == 0 or authority.process_nonce == 0 or authority.thread_id != @as(u64, @intCast(std.Thread.getCurrentId()))) return false;
    _ = switch (authority.lifecycle_raw) {
        1...3 => @as(Lifecycle, @enumFromInt(authority.lifecycle_raw)),
        else => return false,
    };
    _ = switch (authority.disposition_raw) {
        1...2 => @as(close_authority.CloseDisposition, @enumFromInt(authority.disposition_raw)),
        else => return false,
    };
    const expected = authoritySeal(authority) catch return false;
    return std.crypto.timing_safe.eql(contract.Digest, expected, authority.seal);
}

pub fn issueConnection(
    authority: *ShutdownAttemptAuthority,
    out: *contract.ShutdownConnectionReceipt,
    now_ns: u64,
    connection_identity: u64,
    operation: contract.ShutdownOperation,
    inventory_attempt: contract.InventoryAttempt,
    transcript_digest: contract.Digest,
) Error!void {
    if (!valid(authority) or authority.lifecycle_raw != @intFromEnum(Lifecycle.ready) or
        !std.meta.eql(out.*, contract.ShutdownConnectionReceipt{})) return error.InvalidOwner;
    if (now_ns >= authority.deadline_ns) return error.Deadline;
    if (connection_identity == 0 or std.mem.allEqual(u8, &transcript_digest, 0) or !validOperation(operation, inventory_attempt))
        return error.InvalidRequest;
    if (operation == .terminate and authority.attempt_generation >= max_shutdown_terminate_attempts)
        return error.AttemptCap;
    applyProofLossStage(authority, .attempt_generation_overflow);
    if (operation == .terminate)
        authority.attempt_generation = std.math.add(u64, authority.attempt_generation, 1) catch
            process_seal.fatalIntegrity(.proof_loss);
    applyProofLossStage(authority, .lease_generation_overflow);
    authority.connection_lease_generation = std.math.add(u64, authority.connection_lease_generation, 1) catch
        process_seal.fatalIntegrity(.proof_loss);
    const attempt_key = key(authority);
    out.* = .{
        .self_addr = @intFromPtr(out),
        .pid = authority.pid,
        .process_nonce = authority.process_nonce,
        .thread_id = authority.thread_id,
        .authority_addr = @intFromPtr(authority),
        .attempt_key = attempt_key,
        .connection_identity = connection_identity,
        .lease_generation = authority.connection_lease_generation,
        .operation_raw = @intFromEnum(operation),
        .inventory_attempt_raw = @intFromEnum(inventory_attempt),
        .transcript_digest = transcript_digest,
    };
    out.seal = try receiptSeal(out);
    authority.lifecycle_raw = @intFromEnum(Lifecycle.connection_live);
    authority.seal = try authoritySeal(authority);
}

pub fn validReceipt(authority: *const ShutdownAttemptAuthority, receipt: *const contract.ShutdownConnectionReceipt) bool {
    if (!valid(authority) or authority.lifecycle_raw != @intFromEnum(Lifecycle.connection_live) or
        receipt.self_addr != @intFromPtr(receipt) or receipt.authority_addr != @intFromPtr(authority) or
        receipt.pid != authority.pid or receipt.process_nonce != authority.process_nonce or receipt.thread_id != authority.thread_id or
        receipt.lease_generation != authority.connection_lease_generation or receipt.consumed_raw != 0 or
        !std.meta.eql(receipt.attempt_key, key(authority))) return false;
    const operation: contract.ShutdownOperation = switch (receipt.operation_raw) {
        0...1 => @enumFromInt(receipt.operation_raw),
        else => return false,
    };
    const inventory: contract.InventoryAttempt = switch (receipt.inventory_attempt_raw) {
        0...2 => @enumFromInt(receipt.inventory_attempt_raw),
        else => return false,
    };
    if (!validOperation(operation, inventory)) return false;
    const expected = receiptSeal(receipt) catch return false;
    return std.crypto.timing_safe.eql(contract.Digest, expected, receipt.seal);
}

pub fn consumeConnection(
    authority: *ShutdownAttemptAuthority,
    receipt: *contract.ShutdownConnectionReceipt,
    terminal: bool,
) Error!void {
    if (!validReceipt(authority, receipt)) {
        // 게시된 connection 권위가 살아 있는 동안의 drift는 어느 row도 추측해 회수할 수 없다.
        if (valid(authority) and authority.lifecycle_raw == @intFromEnum(Lifecycle.connection_live))
            process_seal.fatalIntegrity(.proof_loss);
        return error.InvalidOwner;
    }
    receipt.consumed_raw = 1;
    receipt.seal = contract.zero_digest;
    authority.lifecycle_raw = @intFromEnum(if (terminal) Lifecycle.terminal else Lifecycle.ready);
    authority.outcome_digest = receipt.transcript_digest;
    authority.seal = try authoritySeal(authority);
}

pub fn publishOutcome(
    authority: *ShutdownAttemptAuthority,
    attempt_key: contract.ShutdownAttemptKey,
    outcome_digest: contract.Digest,
) Error!void {
    if (!valid(authority) or authority.lifecycle_raw != @intFromEnum(Lifecycle.ready) or
        !std.meta.eql(attempt_key, key(authority)) or std.mem.allEqual(u8, &outcome_digest, 0)) return error.InvalidOwner;
    authority.outcome_digest = outcome_digest;
    authority.lifecycle_raw = @intFromEnum(Lifecycle.terminal);
    authority.seal = try authoritySeal(authority);
}

pub fn key(authority: *const ShutdownAttemptAuthority) contract.ShutdownAttemptKey {
    return .{
        .close_request_generation = authority.close_request_generation,
        .target_digest = authority.target_digest,
        .attempt_generation = authority.attempt_generation,
    };
}

fn validOperation(operation: contract.ShutdownOperation, inventory: contract.InventoryAttempt) bool {
    return switch (operation) {
        .terminate => inventory == .none,
        .inventory => inventory == .initial or inventory == .retry,
    };
}

fn authoritySeal(authority: *const ShutdownAttemptAuthority) process_seal.ReadyError!contract.Digest {
    return process_seal.shutdownAttemptAuthoritySeal(authority.pid, authority.process_nonce, .{
        .self_addr = @intFromPtr(authority),
        .thread_id = authority.thread_id,
        .close_request_generation = authority.close_request_generation,
        .target_digest = authority.target_digest,
        .attempt_generation = authority.attempt_generation,
        .disposition_raw = authority.disposition_raw,
        .lifecycle_raw = authority.lifecycle_raw,
        .connection_lease_generation = authority.connection_lease_generation,
        .deadline_ns = authority.deadline_ns,
        .outcome_digest = authority.outcome_digest,
    });
}

fn receiptSeal(receipt: *const contract.ShutdownConnectionReceipt) process_seal.ReadyError!contract.Digest {
    return process_seal.shutdownConnectionReceiptSeal(receipt.pid, receipt.process_nonce, .{
        .self_addr = @intFromPtr(receipt),
        .authority_addr = receipt.authority_addr,
        .thread_id = receipt.thread_id,
        .close_request_generation = receipt.attempt_key.close_request_generation,
        .target_digest = receipt.attempt_key.target_digest,
        .attempt_generation = receipt.attempt_key.attempt_generation,
        .connection_identity = receipt.connection_identity,
        .lease_generation = receipt.lease_generation,
        .operation_raw = receipt.operation_raw,
        .inventory_attempt_raw = receipt.inventory_attempt_raw,
        .consumed_raw = receipt.consumed_raw,
        .transcript_digest = receipt.transcript_digest,
    });
}

fn applyProofLossStage(authority: *ShutdownAttemptAuthority, stage: ProofLossStage) void {
    if (!builtin.is_test or proof_loss_authority_addr != @intFromPtr(authority) or
        proof_loss_stage_raw != @intFromEnum(stage)) return;
    proof_loss_authority_addr = 0;
    proof_loss_stage_raw = 0;
    switch (stage) {
        .none => unreachable,
        .attempt_generation_overflow => authority.attempt_generation = std.math.maxInt(u64),
        .lease_generation_overflow => authority.connection_lease_generation = std.math.maxInt(u64),
    }
}

fn ensureReady() !void {
    _ = process_seal.currentReadyIdentity() catch |err| switch (err) {
        error.NotReady => {
            const prepared = try process_seal.prepare(process_seal.currentProcessId(), 0x3B36_0001);
            process_seal.commitReady(prepared);
        },
        else => return err,
    };
}

pub const testing = if (@import("builtin").is_test) struct {
    pub fn ensureSealReady() !void {
        try ensureReady();
    }

    pub fn armProofLoss(authority: *ShutdownAttemptAuthority, stage: ProofLossStage) void {
        std.debug.assert(proof_loss_authority_addr == 0 and proof_loss_stage_raw == 0);
        proof_loss_authority_addr = @intFromPtr(authority);
        proof_loss_stage_raw = @intFromEnum(stage);
    }
} else struct {};

fn fixture() !ShutdownAttemptAuthority {
    try ensureReady();
    var authority: ShutdownAttemptAuthority = .{};
    try prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    return authority;
}

test "C3-3b6 attempt 권위는 copied target key를 거부한다" {
    var authority = try fixture();
    try std.testing.expect(!valid(&authority));
}

test "C3-3b6 attempt 권위는 cross-target outcome을 거부한다" {
    var authority: ShutdownAttemptAuthority = .{};
    try prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    var wrong = key(&authority);
    wrong.target_digest[0] ^= 1;
    try std.testing.expectError(error.InvalidOwner, publishOutcome(&authority, wrong, [_]u8{4} ** 32));
}

test "C3-3b6 attempt 권위는 old connection receipt replay를 거부한다" {
    var authority: ShutdownAttemptAuthority = .{};
    try prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    var receipt: contract.ShutdownConnectionReceipt = .{};
    try issueConnection(&authority, &receipt, 1, 9, .terminate, .none, [_]u8{5} ** 32);
    try consumeConnection(&authority, &receipt, false);
    try std.testing.expectError(error.InvalidOwner, consumeConnection(&authority, &receipt, false));
}

test "C3-3b6 attempt 권위는 detach와 terminate disposition 우선순위를 보존한다" {
    var authority: ShutdownAttemptAuthority = .{};
    try prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    try std.testing.expectEqual(@intFromEnum(close_authority.CloseDisposition.terminate_host), authority.disposition_raw);
}

test "C3-3b6 attempt 권위는 inventory operation과 attempt 종류를 exact 결속한다" {
    var authority: ShutdownAttemptAuthority = .{};
    try prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    var receipt: contract.ShutdownConnectionReceipt = .{};
    try std.testing.expectError(error.InvalidRequest, issueConnection(&authority, &receipt, 1, 9, .terminate, .retry, [_]u8{5} ** 32));
    try issueConnection(&authority, &receipt, 1, 9, .inventory, .initial, [_]u8{5} ** 32);
}

test "C3-3b6 attempt 권위는 initial과 retry connection을 exact once 소비한다" {
    var authority: ShutdownAttemptAuthority = .{};
    try prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    inline for (.{ contract.InventoryAttempt.initial, contract.InventoryAttempt.retry }) |attempt| {
        var receipt: contract.ShutdownConnectionReceipt = .{};
        try issueConnection(&authority, &receipt, 1, 9, .inventory, attempt, [_]u8{5} ** 32);
        try consumeConnection(&authority, &receipt, false);
    }
    try std.testing.expectEqual(@as(u64, 2), authority.connection_lease_generation);
}

test "C3-3b6 attempt 권위는 terminate 세 번까지만 destructive request를 허용한다" {
    var authority: ShutdownAttemptAuthority = .{};
    try prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    for (0..3) |_| {
        var receipt: contract.ShutdownConnectionReceipt = .{};
        try issueConnection(&authority, &receipt, 1, 9, .terminate, .none, [_]u8{5} ** 32);
        try consumeConnection(&authority, &receipt, false);
    }
    try std.testing.expectEqual(@as(u64, 3), authority.attempt_generation);
}

test "C3-3b6 attempt 권위는 네 번째 destructive request를 보내지 않는다" {
    var authority: ShutdownAttemptAuthority = .{};
    try prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    for (0..3) |_| {
        var receipt: contract.ShutdownConnectionReceipt = .{};
        try issueConnection(&authority, &receipt, 1, 9, .terminate, .none, [_]u8{5} ** 32);
        try consumeConnection(&authority, &receipt, false);
    }
    var fourth: contract.ShutdownConnectionReceipt = .{};
    try std.testing.expectError(error.AttemptCap, issueConnection(&authority, &fourth, 1, 10, .terminate, .none, [_]u8{6} ** 32));
    try std.testing.expect(std.meta.eql(fourth, contract.ShutdownConnectionReceipt{}));
}

test "C3-3b6 attempt 권위는 global deadline 뒤 sibling을 bounded 결과로 진행한다" {
    var authority: ShutdownAttemptAuthority = .{};
    try prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    var receipt: contract.ShutdownConnectionReceipt = .{};
    try std.testing.expectError(error.Deadline, issueConnection(&authority, &receipt, 100, 9, .terminate, .none, [_]u8{5} ** 32));
    try std.testing.expectEqual(@intFromEnum(Lifecycle.ready), authority.lifecycle_raw);
}

test "C3-3b6 attempt 권위는 max attempt에서 outcome 없이 cap을 반환한다" {
    var authority: ShutdownAttemptAuthority = .{};
    try prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    authority.attempt_generation = std.math.maxInt(u64);
    authority.seal = try authoritySeal(&authority);
    var receipt: contract.ShutdownConnectionReceipt = .{};
    try std.testing.expectError(error.AttemptCap, issueConnection(&authority, &receipt, 1, 9, .terminate, .none, [_]u8{5} ** 32));
    try std.testing.expectEqual(contract.zero_digest, authority.outcome_digest);
}

const ProofLossCase = enum { receipt_seal_drift, attempt_generation_overflow, lease_generation_overflow };

fn runProofLossChild(case: ProofLossCase, marker_fd: std.c.fd_t) noreturn {
    ensureReady() catch std.c._exit(121);
    var authority: ShutdownAttemptAuthority = .{};
    prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100) catch std.c._exit(122);
    var receipt: contract.ShutdownConnectionReceipt = .{};
    switch (case) {
        .receipt_seal_drift => {
            issueConnection(&authority, &receipt, 1, 9, .inventory, .initial, [_]u8{5} ** 32) catch std.c._exit(123);
            receipt.seal[0] ^= 1;
            if (std.c.write(marker_fd, &[_]u8{0x61}, 1) != 1) std.c._exit(125);
            consumeConnection(&authority, &receipt, false) catch std.c._exit(124);
        },
        .attempt_generation_overflow => {
            testing.armProofLoss(&authority, .attempt_generation_overflow);
            if (std.c.write(marker_fd, &[_]u8{0x62}, 1) != 1) std.c._exit(125);
            issueConnection(&authority, &receipt, 1, 9, .terminate, .none, [_]u8{5} ** 32) catch std.c._exit(124);
        },
        .lease_generation_overflow => {
            testing.armProofLoss(&authority, .lease_generation_overflow);
            if (std.c.write(marker_fd, &[_]u8{0x63}, 1) != 1) std.c._exit(125);
            issueConnection(&authority, &receipt, 1, 9, .inventory, .initial, [_]u8{5} ** 32) catch std.c._exit(124);
        },
    }
    std.c._exit(126);
}

fn expectProofLoss(case: ProofLossCase, expected_marker: u8) !void {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const enabled = std.c.getenv("MARU_C3B6_PROOF_LOSS") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(enabled), "fresh-artifact-v1")) return error.SkipZigTest;
    var pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&pipe));
    defer _ = std.c.close(pipe[0]);
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        _ = std.c.close(pipe[0]);
        runProofLossChild(case, pipe[1]);
    }
    _ = std.c.close(pipe[1]);
    var marker: [2]u8 = undefined;
    const marker_count = std.c.read(pipe[0], &marker, marker.len);
    try std.testing.expectEqual(@as(isize, 1), marker_count);
    try std.testing.expectEqual(expected_marker, marker[0]);
    try std.testing.expectEqual(@as(isize, 0), std.c.read(pipe[0], &marker, marker.len));
    var status: c_int = 0;
    try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
    const unsigned: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(unsigned));
    try std.testing.expectEqual(@as(u8, 86), std.c.W.EXITSTATUS(unsigned));
}

test "C3-3b6 proof-loss subprocess는 receipt seal drift를 fail-stop한다" {
    try expectProofLoss(.receipt_seal_drift, 0x61);
}

test "C3-3b6 proof-loss subprocess는 attempt generation overflow를 fail-stop한다" {
    try expectProofLoss(.attempt_generation_overflow, 0x62);
}

test "C3-3b6 proof-loss subprocess는 lease generation overflow를 fail-stop한다" {
    try expectProofLoss(.lease_generation_overflow, 0x63);
}
