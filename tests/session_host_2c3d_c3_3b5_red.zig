const std = @import("std");
const maru = @import("maru");
const close_contract = @import("close_contract");
const pending_owner = @import("pending_owner");

fn red() !void {
    return error.C3B5NotImplemented;
}

test "C3-3b5 중립 계약 CloseProgress는 complete와 event_pending만 허용한다" {
    const Progress = maru.app.term_runtime_backend.CloseProgress;
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Progress.complete));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Progress.event_pending));
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(Progress).@"enum".fields.len);
}
test "C3-3b5 중립 계약 RemoveProgress는 removed와 event_pending과 invalid만 허용한다" {
    const Progress = maru.app.term_runtime_backend.RemoveProgress;
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Progress.removed));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Progress.event_pending));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Progress.invalid));
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(Progress).@"enum".fields.len);
}
test "C3-3b5 중립 계약 CloseScanReceipt는 재귀 pointer-free exact schema다" {
    const fields = @typeInfo(close_contract.CloseScanReceipt).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqualStrings("handle", fields[0].name);
    try std.testing.expectEqualStrings("runtime_generation", fields[1].name);
    try std.testing.expectEqualStrings("close_request_generation", fields[2].name);
    try std.testing.expectEqualStrings("close_schedule_ticket", fields[3].name);
    try std.testing.expect(close_contract.recursivelyPointerFree(close_contract.CloseScanReceipt));
}
test "C3-3b5 중립 계약 CloseSweep active shape는 max ticket과 cursor만 봉인한다" {
    const active_fields = @typeInfo(close_contract.CloseSweep.Active).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), active_fields.len);
    try std.testing.expectEqualStrings("max_ticket", active_fields[0].name);
    try std.testing.expectEqualStrings("cursor_after_ticket", active_fields[1].name);
    try std.testing.expect(close_contract.recursivelyPointerFree(close_contract.CloseSweep));
}
test "C3-3b5 중립 계약 close ticket은 1과 max를 허용하고 0과 exhaustion을 거부한다" {
    try std.testing.expect(!close_contract.validCloseScheduleTicket(0));
    try std.testing.expect(close_contract.validCloseScheduleTicket(1));
    try std.testing.expect(close_contract.validCloseScheduleTicket(std.math.maxInt(u64)));
    var issuer: close_contract.CloseTicketIssuer = .{ .last_issued = std.math.maxInt(u64) - 1 };
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), issuer.issue());
    try std.testing.expect(issuer.issue() == null);
}
test "C3-3b5 중립 계약 VTable은 field 순서를 유지하고 close 반환형만 바꾼다" {
    try red();
}

test "C3-3b5 close readiness idle은 complete다" {
    try std.testing.expectEqual(maru.app.term_runtime_backend.CloseProgress.complete, pending_owner.closeReadinessRaw(@intFromEnum(pending_owner.PendingLifecycle.idle)));
}
test "C3-3b5 close readiness preparing은 event_pending이다" {
    try std.testing.expectEqual(maru.app.term_runtime_backend.CloseProgress.event_pending, pending_owner.closeReadinessRaw(@intFromEnum(pending_owner.PendingLifecycle.preparing)));
}
test "C3-3b5 close readiness prepared는 event_pending이다" {
    try std.testing.expectEqual(maru.app.term_runtime_backend.CloseProgress.event_pending, pending_owner.closeReadinessRaw(@intFromEnum(pending_owner.PendingLifecycle.prepared)));
}
test "C3-3b5 close readiness settling은 event_pending이다" {
    try std.testing.expectEqual(maru.app.term_runtime_backend.CloseProgress.event_pending, pending_owner.closeReadinessRaw(@intFromEnum(pending_owner.PendingLifecycle.settling)));
}
test "C3-3b5 close readiness committed_cleanup은 event_pending이다" {
    try std.testing.expectEqual(maru.app.term_runtime_backend.CloseProgress.event_pending, pending_owner.closeReadinessRaw(@intFromEnum(pending_owner.PendingLifecycle.committed_cleanup)));
}
test "C3-3b5 close readiness invalid raw는 전용 fatal leaf로 닫힌다" {
    const child = std.c.fork();
    try std.testing.expect(child >= 0);
    if (child == 0) {
        _ = pending_owner.closeReadinessRaw(0xff);
        std.c._exit(0);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
    const unsigned_status: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(unsigned_status));
    try std.testing.expectEqual(@as(u32, 86), std.c.W.EXITSTATUS(unsigned_status));
}

test "C3-3b5 close authority는 final address copy와 move를 거부한다" {
    try red();
}
test "C3-3b5 close authority는 old request generation과 replay를 mutation 0으로 거부한다" {
    try red();
}
test "C3-3b5 close authority는 request kind와 disposition 조합만 허용한다" {
    try red();
}
test "C3-3b5 close authority는 ticket 0과 exhaustion을 publication 전에 거부한다" {
    try red();
}
test "C3-3b5 close authority는 routing을 먼저 tombstone하고 callback 재진입을 보류한다" {
    try red();
}
test "C3-3b5 close authority operation pin은 same target과 cross target 재진입을 보류하고 exact once 해제된다" {
    try red();
}
test "C3-3b5 close authority는 pending readiness와 shutdown outcome 뒤에만 ready_remove가 된다" {
    try red();
}
test "C3-3b5 close authority receipt는 backend absence를 증명하며 exact once 소비된다" {
    try red();
}

test "C3-3b5 close sweep은 empty와 closing 0에서 inactive다" {
    var sweep: close_contract.CloseSweep = .inactive;
    var out: [16]close_contract.CloseScanReceipt = undefined;
    try std.testing.expectEqual(@as(usize, 0), close_contract.selectCloseSweep(&sweep, &.{}, &out));
    try std.testing.expect(sweep == .inactive);
}
test "C3-3b5 close sweep은 owner 1개를 exact once 방문한다" {
    var sweep: close_contract.CloseSweep = .inactive;
    var out: [16]close_contract.CloseScanReceipt = undefined;
    const receipts = [_]close_contract.CloseScanReceipt{receipt(7, 1)};
    try std.testing.expectEqual(@as(usize, 1), close_contract.selectCloseSweep(&sweep, &receipts, &out));
    try std.testing.expectEqual(@as(u64, 7), out[0].handle);
    try std.testing.expect(sweep == .inactive);
}
test "C3-3b5 close sweep은 owner 16개를 같은 tick에 한 번씩 방문한다" {
    var receipts: [16]close_contract.CloseScanReceipt = undefined;
    for (&receipts, 0..) |*item, i| item.* = receipt(@intCast(16 - i), @intCast(16 - i));
    var sweep: close_contract.CloseSweep = .inactive;
    var out: [16]close_contract.CloseScanReceipt = undefined;
    try std.testing.expectEqual(@as(usize, 16), close_contract.selectCloseSweep(&sweep, &receipts, &out));
    for (out, 1..) |item, ticket| try std.testing.expectEqual(@as(u64, @intCast(ticket)), item.close_schedule_ticket);
    try std.testing.expect(sweep == .inactive);
}
test "C3-3b5 close sweep은 owner 17개를 두 tick에 16과 1로 방문한다" {
    var receipts: [17]close_contract.CloseScanReceipt = undefined;
    for (&receipts, 0..) |*item, i| item.* = receipt(@intCast(i + 1), @intCast(i + 1));
    var sweep: close_contract.CloseSweep = .inactive;
    var out: [16]close_contract.CloseScanReceipt = undefined;
    try std.testing.expectEqual(@as(usize, 16), close_contract.selectCloseSweep(&sweep, &receipts, &out));
    try std.testing.expectEqual(@as(usize, 1), close_contract.selectCloseSweep(&sweep, &receipts, &out));
    try std.testing.expectEqual(@as(u64, 17), out[0].close_schedule_ticket);
    try std.testing.expect(sweep == .inactive);
}
test "C3-3b5 close sweep은 owner 4096개를 256 tick 안에 한 번씩 방문한다" {
    var receipts: [4096]close_contract.CloseScanReceipt = undefined;
    for (&receipts, 0..) |*item, i| item.* = receipt(@intCast(i + 1), @intCast(i + 1));
    var visited = [_]bool{false} ** 4096;
    var sweep: close_contract.CloseSweep = .inactive;
    var out: [16]close_contract.CloseScanReceipt = undefined;
    for (0..256) |_| {
        try std.testing.expectEqual(@as(usize, 16), close_contract.selectCloseSweep(&sweep, &receipts, &out));
        for (out) |item| {
            const index: usize = @intCast(item.close_schedule_ticket - 1);
            try std.testing.expect(!visited[index]);
            visited[index] = true;
        }
    }
    try std.testing.expect(sweep == .inactive);
    for (visited) |value| try std.testing.expect(value);
}
test "C3-3b5 close sweep은 시작 뒤 발급된 ticket을 다음 sweep까지 동결한다" {
    var receipts: [18]close_contract.CloseScanReceipt = undefined;
    for (receipts[0..17], 0..) |*item, i| item.* = receipt(@intCast(i + 1), @intCast(i + 1));
    var sweep: close_contract.CloseSweep = .inactive;
    var out: [16]close_contract.CloseScanReceipt = undefined;
    try std.testing.expectEqual(@as(usize, 16), close_contract.selectCloseSweep(&sweep, receipts[0..17], &out));
    receipts[17] = receipt(18, 18);
    try std.testing.expectEqual(@as(usize, 1), close_contract.selectCloseSweep(&sweep, &receipts, &out));
    try std.testing.expectEqual(@as(u64, 17), out[0].close_schedule_ticket);
    try std.testing.expect(sweep == .inactive);
    try std.testing.expectEqual(@as(usize, 16), close_contract.selectCloseSweep(&sweep, &receipts, &out));
}
test "C3-3b5 close sweep은 무한 신규 churn에서도 기존 frozen set을 끝낸다" {
    var receipts: [64]close_contract.CloseScanReceipt = undefined;
    for (receipts[0..32], 0..) |*item, i| item.* = receipt(@intCast(i + 1), @intCast(i + 1));
    var len: usize = 32;
    var sweep: close_contract.CloseSweep = .inactive;
    var out: [16]close_contract.CloseScanReceipt = undefined;
    var original_seen = [_]bool{false} ** 32;
    for (0..2) |_| {
        const count = close_contract.selectCloseSweep(&sweep, receipts[0..len], &out);
        try std.testing.expectEqual(@as(usize, 16), count);
        for (out[0..count]) |item| original_seen[@intCast(item.close_schedule_ticket - 1)] = true;
        receipts[len] = receipt(@intCast(len + 1), @intCast(len + 1));
        len += 1;
    }
    try std.testing.expect(sweep == .inactive);
    for (original_seen) |value| try std.testing.expect(value);
}
test "C3-3b5 close sweep은 stale replacement receipt를 거부하고 새 generation receipt만 인정한다" {
    const captured = receiptWithGeneration(9, 3, 1);
    const replacement = receiptWithGeneration(9, 4, 2);
    try std.testing.expect(!close_contract.sameCloseScanReceipt(captured, replacement));
    try std.testing.expect(close_contract.sameCloseScanReceipt(replacement, replacement));
}

fn receipt(handle: u64, ticket: u64) close_contract.CloseScanReceipt {
    return receiptWithGeneration(handle, 1, ticket);
}

fn receiptWithGeneration(handle: u64, generation: u64, ticket: u64) close_contract.CloseScanReceipt {
    return .{
        .handle = handle,
        .runtime_generation = generation,
        .close_request_generation = generation,
        .close_schedule_ticket = ticket,
    };
}

test "C3-3b5 remote backend는 두 host 합계 runtime 4096개만 허용한다" {
    try red();
}
test "C3-3b5 remote backend는 4097번째를 allocator와 host RPC 전에 거부한다" {
    try red();
}
test "C3-3b5 remote backend는 spawn 실패 reservation을 회수해 capacity를 재사용한다" {
    try red();
}
test "C3-3b5 remote backend는 attach와 restore 실패 reservation을 회수해 capacity를 재사용한다" {
    try red();
}
test "C3-3b5 remote backend scan scratch는 256 KiB 이하이고 callback allocation이 없다" {
    try red();
}
test "C3-3b5 remote backend는 iterator를 닫은 뒤에만 relookup과 callback을 수행한다" {
    try red();
}
test "C3-3b5 remote backend는 active pin 제거를 보류하고 다음 tick에 exact once 회수한다" {
    try red();
}

test "C3-3b5 AppSession은 in-process multi-Term complete 뒤에만 topology를 갱신한다" {
    try red();
}
test "C3-3b5 AppSession은 remote pending window를 보류하고 graph 완료 뒤 close intent를 한 번 발행한다" {
    try red();
}
test "C3-3b5 AppSession은 termination finish와 remove가 끝난 뒤에만 cascade한다" {
    try red();
}
test "C3-3b5 AppSession은 stale remove와 backend absence를 구분해 dangling layout을 만들지 않는다" {
    try red();
}
