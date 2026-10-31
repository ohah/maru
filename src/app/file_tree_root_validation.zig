//! Shared two-round root validation protocol. No filesystem mutation or UI ownership.
const std = @import("std");
const tree = @import("../session/file_tree.zig");
const backend = @import("file_tree_backend.zig");
const i18n = @import("../i18n.zig");
pub const Operation = enum(u32) { none = 0, replace = 1, add = 2 };
pub const Outcome = enum(u8) {
    none,
    picker_requested,
    picker_canceled,
    busy,
    invalid_path,
    request_id_exhausted,
    allocation_failed,
    backend_busy,
    validation_failed,
    stale_generation,
    identity_missing,
    identity_changed,
    model_stage_failed,
    watcher_stage_failed,
    row_stage_failed,
    root_missing,
    committed_replace,
    committed_add,
    committed_remove,
};
pub const Pending = struct {
    request_id: u64,
    expected_root_generation: u64,
    operation: Operation,
    round: u8 = 0,
    identity: ?tree.Identity = null,
    /// 사용자가 고른 것이 아니라 **활성 터미널을 따라가느라** 자동으로 건 전환인가(file-explorer.md §1).
    /// 자동 전환은 사용자 조작보다 항상 아래다 — 사용자가 폴더를 고르려 하면 이건 버려지고 자리를 내준다.
    auto: bool = false,
};

pub const Reply = struct {
    is_root_validation: bool = true,
    was_remote: bool = false,
    request_id: u64,
    expected_root_generation: u64,
    operation: u32,
    round: u8,
    ok: bool,
    identity: ?tree.ScanIdentity = null,
    has_capability: bool = false,
    pub fn fromBackend(result: *const backend.Result) Reply {
        return .{
            .is_root_validation = result.kind == .root_validation,
            .was_remote = result.was_remote,
            .request_id = result.request_id,
            .expected_root_generation = result.expected_root_generation,
            .operation = result.root_operation,
            .round = result.root_validation_round,
            .ok = result.ok,
            .identity = result.identity,
            .has_capability = result.validated_dir != null,
        };
    }
};
pub const Failure = struct { outcome: Outcome, notice: i18n.Key };
pub const Decision = union(enum) { ignore, revalidate: tree.Identity, ready, failed: Failure };
fn failed(outcome: Outcome, notice: i18n.Key) Decision {
    return .{ .failed = .{ .outcome = outcome, .notice = notice } };
}
pub fn evaluate(pending: Pending, reply: Reply, current_generation: u64) Decision {
    if (!reply.is_root_validation or reply.was_remote or
        pending.request_id != reply.request_id or
        pending.expected_root_generation != reply.expected_root_generation or
        @backingInt(pending.operation) != reply.operation or pending.round != reply.round) return .ignore;
    if (current_generation != pending.expected_root_generation)
        return failed(.stale_generation, .fp_root_stale_generation);
    if (!reply.ok) return failed(.validation_failed, .fp_root_open_failed);
    if (pending.round == 0) {
        const identity = reply.identity orelse return failed(.identity_missing, .fp_root_identity_unknown);
        return .{ .revalidate = identity.value };
    }
    if (pending.round != 1) return failed(.validation_failed, .fp_root_revalidate_invalid);
    const expected = pending.identity orelse return failed(.identity_missing, .fp_root_revalidate_invalid);
    const actual = reply.identity orelse return failed(.identity_missing, .fp_root_identity_gone);
    if (!reply.has_capability) return failed(.identity_missing, .fp_root_capability_gone);
    if (!expected.eql(actual.value)) return failed(.identity_changed, .fp_root_identity_changed);
    return .ready;
}

const fixture_identity: tree.Identity = .{ .device = 1, .inode = 2, .kind = 2 };
fn samplePending(round: u8) Pending {
    return .{ .request_id = 7, .expected_root_generation = 9, .operation = .replace, .round = round, .identity = fixture_identity };
}
fn sampleReply(round: u8) Reply {
    return .{ .request_id = 7, .expected_root_generation = 9, .operation = 1, .round = round, .ok = true, .identity = .{ .value = fixture_identity }, .has_capability = true };
}
fn failureOf(decision: Decision) !Failure {
    try std.testing.expect(decision == .failed);
    return decision.failed;
}
fn revalidationOf(decision: Decision) !tree.Identity {
    try std.testing.expect(decision == .revalidate);
    return decision.revalidate;
}

test "root validation protocol isolates reply routing fields" {
    const p = samplePending(1);
    var replies: [7]Reply = undefined;
    @memset(&replies, sampleReply(1));
    replies[0].request_id += 1;
    replies[1].expected_root_generation += 1;
    replies[2].operation = 2;
    replies[3].round = 0;
    replies[4].is_root_validation = false;
    replies[5].was_remote = true;
    replies[6].round = 2;
    for (replies) |r| try std.testing.expect(evaluate(p, r, 9) == .ignore);
}
test "root validation protocol rejects stale current generation" {
    const decision = evaluate(samplePending(1), sampleReply(1), 10);
    try std.testing.expectEqual(Outcome.stale_generation, (try failureOf(decision)).outcome);
}
test "root validation protocol failure never stages a root" {
    var r = sampleReply(0);
    r.ok = false;
    try std.testing.expectEqual(i18n.Key.fp_root_open_failed, (try failureOf(evaluate(samplePending(0), r, 9))).notice);
    r.ok = true;
    r.identity = null;
    try std.testing.expectEqual(i18n.Key.fp_root_identity_unknown, (try failureOf(evaluate(samplePending(0), r, 9))).notice);
}
test "root validation protocol first round always requests identity revalidation" {
    var r = sampleReply(0);
    r.has_capability = false;
    try std.testing.expect(fixture_identity.eql((try revalidationOf(evaluate(samplePending(0), r, 9)))));
}
test "root validation protocol final round requires the validated capability" {
    try std.testing.expect(evaluate(samplePending(1), sampleReply(1), 9) == .ready);
    var r = sampleReply(1);
    r.has_capability = false;
    try std.testing.expectEqual(i18n.Key.fp_root_capability_gone, (try failureOf(evaluate(samplePending(1), r, 9))).notice);
}
test "root validation protocol compares both rounds on the scan identity axis" {
    var r = sampleReply(1);
    r.identity.?.value.inode += 1;
    try std.testing.expectEqual(Outcome.identity_changed, (try failureOf(evaluate(samplePending(1), r, 9))).outcome);
    r.identity = null;
    try std.testing.expectEqual(i18n.Key.fp_root_identity_gone, (try failureOf(evaluate(samplePending(1), r, 9))).notice);
    var p = samplePending(1);
    p.identity = null;
    try std.testing.expectEqual(i18n.Key.fp_root_revalidate_invalid, (try failureOf(evaluate(p, sampleReply(1), 9))).notice);
}
test "root validation protocol rejects unknown phases" {
    try std.testing.expectEqual(i18n.Key.fp_root_revalidate_invalid, (try failureOf(evaluate(samplePending(2), sampleReply(2), 9))).notice);
}
test "root validation protocol backend adapter borrows metadata without owning the result" {
    const result: backend.Result = .{ .path = @constCast("C:/fixture"), .kind = .root_validation, .request_id = 7, .expected_root_generation = 9, .root_operation = 1, .root_validation_round = 0, .ok = true, .identity = .{ .value = fixture_identity } };
    const reply = Reply.fromBackend(&result);
    try std.testing.expect(!reply.has_capability and reply.is_root_validation);
    try std.testing.expect(fixture_identity.eql((try revalidationOf(evaluate(samplePending(0), reply, 9)))));
}
