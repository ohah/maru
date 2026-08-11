const std = @import("std");
const maru = @import("maru");
const close_authority = @import("close_authority");
const close_contract = close_authority.contract;
const pending_owner = close_authority.pending_owner;

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
    const Backend = maru.app.term_runtime_backend;
    const fields = @typeInfo(Backend.VTable).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 18), fields.len);
    const expected_names = [_][]const u8{
        "spawn",            "attach",                   "pump",        "write_input",              "write_input_nonblocking", "enqueue_core_command",
        "resize",           "close_and_detach",         "close",       "finish_after_termination", "remove",                  "foreground_process_group",
        "resource_samples", "foreground_process_names", "process_cwd", "read_observation",         "refresh_observation",     "dump_recent_text",
    };
    inline for (fields, expected_names, 0..) |field, expected_name, index| {
        _ = index;
        try std.testing.expectEqualStrings(expected_name, field.name);
    }
    inline for (.{ 7, 8, 9 }) |index| {
        const function_info = @typeInfo(@typeInfo(fields[index].type).pointer.child).@"fn";
        try std.testing.expectEqual(Backend.CloseProgress, function_info.return_type.?);
    }
    const remove_info = @typeInfo(@typeInfo(fields[10].type).pointer.child).@"fn";
    try std.testing.expectEqual(Backend.RemoveProgress, remove_info.return_type.?);
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
    var authority: close_authority.CloseAuthority = .{};
    try prepareCloseAuthority(&authority, .close_and_detach, .terminate_host, 1);
    try std.testing.expect(close_authority.valid(&authority));
    var copied = authority;
    try std.testing.expect(!close_authority.valid(&copied));
}
test "C3-3b5 close authority는 old request generation과 replay를 mutation 0으로 거부한다" {
    var authority: close_authority.CloseAuthority = .{};
    try prepareCloseAuthority(&authority, .close_and_detach, .terminate_host, 2);
    const old_state = authority.state_seal;
    try close_authority.advance(&authority, .open, .routing_tombstoned);
    authority.state_seal = old_state;
    try std.testing.expect(!close_authority.valid(&authority));
    var occupied = authority;
    try std.testing.expectError(error.InvalidOwner, prepareCloseAuthority(&occupied, .close_and_detach, .terminate_host, 3));
}
test "C3-3b5 close authority는 request kind와 disposition 조합만 허용한다" {
    var valid_close: close_authority.CloseAuthority = .{};
    try prepareCloseAuthority(&valid_close, .close_and_detach, .terminate_host, 4);
    var invalid_close: close_authority.CloseAuthority = .{};
    try std.testing.expectError(error.InvalidRequest, prepareCloseAuthority(&invalid_close, .close_and_detach, .detach_preserve_host, 5));
    var rollback: close_authority.CloseAuthority = .{};
    try prepareCloseAuthority(&rollback, .close_without_routing, .detach_preserve_host, 6);
    var terminated: close_authority.CloseAuthority = .{};
    try prepareCloseAuthority(&terminated, .finish_after_termination, .terminate_host, 7);
}
test "C3-3b5 close authority는 ticket 0과 exhaustion을 publication 전에 거부한다" {
    var authority: close_authority.CloseAuthority = .{};
    const ready = try close_authority.testing.ensureSealReady();
    try std.testing.expectError(error.InvalidRequest, close_authority.prepare(&authority, ready, closeParams(.close_and_detach, .terminate_host, 8, 0)));
    try std.testing.expectEqual(close_authority.CloseAuthority{}, authority);
    var issuer: close_contract.CloseTicketIssuer = .{ .last_issued = std.math.maxInt(u64) - 1 };
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), issuer.issue());
    try std.testing.expect(issuer.issue() == null);
}
test "C3-3b5 close authority는 routing을 먼저 tombstone하고 callback 재진입을 보류한다" {
    var authority: close_authority.CloseAuthority = .{};
    try prepareCloseAuthority(&authority, .close_and_detach, .terminate_host, 9);
    try close_authority.advance(&authority, .open, .routing_tombstoned);
    var owner: close_authority.CloseOperationOwner = .{};
    var pin: close_authority.CloseOperationPin = .{};
    try close_authority.acquirePin(&owner, &pin, 0xB500, &authority);
    var nested: close_authority.CloseOperationPin = .{};
    try std.testing.expectError(error.Busy, close_authority.acquirePin(&owner, &nested, 0xB500, &authority));
    try std.testing.expectEqual(@intFromEnum(close_authority.Lifecycle.routing_tombstoned), authority.lifecycle_raw);
}
test "C3-3b5 close authority operation pin은 same target과 cross target 재진입을 보류하고 exact once 해제된다" {
    var first: close_authority.CloseAuthority = .{};
    var second: close_authority.CloseAuthority = .{};
    try prepareCloseAuthority(&first, .close_and_detach, .terminate_host, 10);
    try prepareCloseAuthority(&second, .close_and_detach, .terminate_host, 11);
    var owner: close_authority.CloseOperationOwner = .{};
    var pin: close_authority.CloseOperationPin = .{};
    try close_authority.acquirePin(&owner, &pin, 0xB501, &first);
    var same: close_authority.CloseOperationPin = .{};
    var cross: close_authority.CloseOperationPin = .{};
    try std.testing.expectError(error.Busy, close_authority.acquirePin(&owner, &same, 0xB501, &first));
    try std.testing.expectError(error.Busy, close_authority.acquirePin(&owner, &cross, 0xB501, &second));
    try close_authority.consumePin(&owner, &pin, &first);
    try std.testing.expectError(error.InvalidOwner, close_authority.consumePin(&owner, &pin, &first));
}
test "C3-3b5 close authority는 pending readiness와 shutdown outcome 뒤에만 ready_remove가 된다" {
    var authority: close_authority.CloseAuthority = .{};
    try prepareCloseAuthority(&authority, .close_and_detach, .terminate_host, 12);
    try close_authority.advance(&authority, .open, .routing_tombstoned);
    try close_authority.advance(&authority, .routing_tombstoned, .settling);
    try std.testing.expectEqual(maru.app.term_runtime_backend.CloseProgress.event_pending, pending_owner.closeReadinessRaw(@intFromEnum(pending_owner.PendingLifecycle.prepared)));
    try std.testing.expect(!try close_authority.publishReadyRemove(&authority, false));
    try std.testing.expectEqual(@intFromEnum(close_authority.Lifecycle.settling), authority.lifecycle_raw);
    try std.testing.expectEqual(maru.app.term_runtime_backend.CloseProgress.complete, pending_owner.closeReadinessRaw(@intFromEnum(pending_owner.PendingLifecycle.idle)));
    try std.testing.expect(try close_authority.publishReadyRemove(&authority, true));
    try std.testing.expectEqual(@intFromEnum(close_authority.Lifecycle.ready_remove), authority.lifecycle_raw);
}
test "C3-3b5 close authority receipt는 backend absence를 증명하며 exact once 소비된다" {
    const scan = receiptWithGeneration(19, 7, 13);
    var closing: close_contract.ClosingReceipt = .{ .scan = scan };
    try std.testing.expect(!close_contract.consumeClosingReceipt(&closing, scan, true));
    try std.testing.expect(close_contract.consumeClosingReceipt(&closing, scan, false));
    try std.testing.expect(!close_contract.consumeClosingReceipt(&closing, scan, false));
}

fn closeParams(
    kind: close_authority.CloseRequestKind,
    disposition: close_authority.CloseDisposition,
    request_generation: u64,
    ticket: u64,
) close_authority.PrepareParams {
    return .{
        .runtime_addr = 0xCAFE_0000 + request_generation,
        .handle = 100 + request_generation,
        .runtime_generation = 40 + request_generation,
        .host_id = 0xB5,
        .close_request_generation = request_generation,
        .close_schedule_ticket = ticket,
        .request_kind = kind,
        .disposition = disposition,
    };
}

fn prepareCloseAuthority(
    authority: *close_authority.CloseAuthority,
    kind: close_authority.CloseRequestKind,
    disposition: close_authority.CloseDisposition,
    request_generation: u64,
) !void {
    const ready = try close_authority.testing.ensureSealReady();
    return close_authority.prepare(authority, ready, closeParams(kind, disposition, request_generation, request_generation));
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
