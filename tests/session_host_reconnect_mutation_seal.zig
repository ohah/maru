//! CR2e-b mutation sealing과 PausedPaste secure owner의 focused TDD.

const std = @import("std");
const mutation = @import("reconnect_mutation_seal");

fn readResendFromForeignThread(resend: *const mutation.PreparedResend, rejected: *std.atomic.Value(bool)) void {
    _ = resend.bytesView() catch |err| {
        rejected.store(err == error.InvalidAuthority, .release);
        return;
    };
}

test "CR2e-b mutation gate는 sealing 게시 뒤 active lease를 기다리고 신규 admission을 거부한다" {
    var owner: mutation.MutationOwner = .{};
    try owner.initInPlace(7, 11);
    try std.testing.expectError(error.InvalidAuthority, owner.initInPlace(7, 11));
    var copied_owner = owner;
    var copied_owner_lease: mutation.MutationLease = .{};
    try std.testing.expectError(error.InvalidAuthority, copied_owner.beginMutation(7, 11, &copied_owner_lease));
    var first: mutation.MutationLease = .{};
    try owner.beginMutation(7, 11, &first);
    var copied = first;
    try std.testing.expectEqual(mutation.SealProgress.waiting_for_leases, try owner.beginSeal(7, 11));
    var blocked: mutation.MutationLease = .{};
    try std.testing.expectError(error.ReconnectBusy, owner.beginMutation(7, 11, &blocked));
    try std.testing.expectError(error.Busy, owner.finishSeal(.clean));
    try owner.finishMutation(&first);
    try std.testing.expectError(error.InvalidAuthority, owner.finishMutation(&copied));
    try std.testing.expectEqual(mutation.SealResult.sealed_clean, try owner.finishSeal(.clean));
    try std.testing.expectError(error.ReconnectBusy, owner.beginMutation(7, 11, &blocked));

    var capped: mutation.MutationOwner = .{};
    try capped.initInPlace(8, 12);
    var leases: [mutation.max_mutation_leases]mutation.MutationLease = @splat(.{});
    for (&leases) |*lease| try capped.beginMutation(8, 12, lease);
    var over_cap: mutation.MutationLease = .{};
    try std.testing.expectError(error.Busy, capped.beginMutation(8, 12, &over_cap));
    try std.testing.expectEqual(@as(u32, mutation.max_mutation_leases), capped.active_leases);
    for (&leases) |*lease| try capped.finishMutation(lease);
    try std.testing.expectEqual(@as(u32, 0), capped.active_leases);
}

test "CR2e-b seal은 일반 입력을 지우고 완전한 paste 하나만 quarantine한다" {
    const allocator = std.testing.allocator;
    var budget: mutation.GlobalPasteBudget = .{};
    try budget.initInPlace();
    try std.testing.expectError(error.InvalidAuthority, budget.initInPlace());
    var store: mutation.PausedPasteStore = .{};
    try store.initInPlace(allocator, &budget, .{1} ** 16, 7, 11);
    try std.testing.expectError(error.InvalidAuthority, store.initInPlace(allocator, &budget, .{1} ** 16, 7, 11));
    var copied_store = store;
    try std.testing.expectError(error.InvalidAuthority, copied_store.projection());
    defer store.deinit();

    var key = [_]u8{ 1, 2, 3 };
    var ime = [_]u8{ 4, 5, 6, 7 };
    var paste_queue = [_]u8{ 8, 9 };
    var paste_original = [_]u8{ 8, 9, 10, 11, 12 };
    const entries = [_]mutation.SealEntry{
        .{ .kind = .key_bytes, .sequence = 1, .queued_payload = &key },
        .{ .kind = .ime_commit, .sequence = 2, .queued_payload = &ime },
        .{ .kind = .paste, .sequence = 3, .queued_payload = &paste_queue, .complete_original = &paste_original },
    };
    const summary = try store.sealEntries(&entries, 100, std.testing.io);
    try std.testing.expectEqual([_]u8{1} ** 16, summary.runtime_id);
    try std.testing.expectEqual(@as(u64, 7), summary.shell_generation);
    try std.testing.expectEqual(@as(u64, 11), summary.input_epoch);
    try std.testing.expectEqual(@as(u64, 1), summary.first_sequence);
    try std.testing.expectEqual(@as(u64, 3), summary.last_sequence);
    try std.testing.expectEqual(@as(u32, 3), summary.total_count);
    try std.testing.expectEqual(@as(u64, 9), summary.total_bytes);
    try std.testing.expectEqual(@as(u32, 1), summary.kinds[@intFromEnum(mutation.SealKind.key_bytes)].count);
    try std.testing.expectEqual(@as(u64, 3), summary.kinds[@intFromEnum(mutation.SealKind.key_bytes)].bytes);
    try std.testing.expectEqual(@as(u64, 3), summary.kinds[@intFromEnum(mutation.SealKind.paste)].first_sequence);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** key.len, &key);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** ime.len, &ime);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** paste_queue.len, &paste_queue);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** paste_original.len, &paste_original);
    try std.testing.expect(store.hasPausedPaste());
    const projection = (try store.projection()).?;
    try std.testing.expectEqual(@as(u64, 100), projection.id);
    try std.testing.expectEqual(@as(u64, 5), projection.full_length);
    try std.testing.expect(!std.mem.allEqual(u8, &projection.hash, 0));
    try std.testing.expectEqual(@as(usize, 5), budget.reservedBytes());
    try store.prepareResend(7, 12, std.testing.io);
    var resend: mutation.PreparedResend = .{};
    try store.consumeResend(&resend);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 8, 9, 10, 11, 12 }, try resend.bytesView());
    var copied_resend = resend;
    try std.testing.expectError(error.InvalidAuthority, copied_resend.bytesView());
    var foreign_rejected = std.atomic.Value(bool).init(false);
    const foreign = try std.Thread.spawn(.{}, readResendFromForeignThread, .{ &resend, &foreign_rejected });
    foreign.join();
    try std.testing.expect(foreign_rejected.load(.acquire));
    mutation.testing_api.corruptResendByte(&resend, 0);
    try std.testing.expectError(error.InvalidAuthority, resend.bytesView());
    mutation.testing_api.corruptResendByte(&resend, 0);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 8, 9, 10, 11, 12 }, try resend.bytesView());
    resend.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.reservedBytes());

    var staging_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    var staging_oom: mutation.PausedPasteStore = .{};
    try staging_oom.initInPlace(staging_failing.allocator(), &budget, .{8} ** 16, 7, 11);
    defer staging_oom.deinit();
    var staging_source = [_]u8{ 7, 8, 9 };
    try staging_oom.capturePaste(&staging_source, 31, std.testing.io);
    try std.testing.expectEqual(@as(usize, 3), budget.reservedBytes());
    try std.testing.expectError(error.OutOfMemory, staging_oom.prepareResend(7, 12, std.testing.io));
    try std.testing.expect(staging_oom.hasPausedPaste());
    try std.testing.expectEqual(@as(usize, 3), budget.reservedBytes());
    try staging_oom.discard();
    try std.testing.expectEqual(@as(usize, 0), budget.reservedBytes());
}

test "CR2e-b PausedPaste cap과 OOM은 source와 budget을 mutation 없이 보존한다" {
    const allocator = std.testing.allocator;
    var budget: mutation.GlobalPasteBudget = .{};
    try budget.initInPlace();
    var store: mutation.PausedPasteStore = .{};
    try store.initInPlace(allocator, &budget, .{2} ** 16, 7, 11);
    defer store.deinit();

    var copied_budget = budget;
    var rejected_store: mutation.PausedPasteStore = .{};
    try std.testing.expectError(
        error.InvalidAuthority,
        rejected_store.initInPlace(allocator, &copied_budget, .{6} ** 16, 7, 11),
    );
    const owner_bytes = std.mem.asBytes(&store);
    try std.testing.expectError(error.InvalidAuthority, store.capturePaste(owner_bytes[0..4], 9, std.testing.io));

    var aliased = [_]u8{ 1, 2, 3, 4 };
    const overlapping = [_]mutation.SealEntry{
        .{ .kind = .key_bytes, .sequence = 1, .queued_payload = aliased[0..3] },
        .{ .kind = .ime_commit, .sequence = 2, .queued_payload = aliased[2..4] },
    };
    try std.testing.expectError(error.InvalidAuthority, store.sealEntries(&overlapping, 8, std.testing.io));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, &aliased);

    var oversized = [_]u8{0xA5} ** (mutation.max_paste_bytes + 1);
    const before = oversized;
    try std.testing.expectError(error.PasteTooLarge, store.capturePaste(&oversized, 1, std.testing.io));
    try std.testing.expectEqualSlices(u8, &before, &oversized);
    try std.testing.expectEqual(@as(usize, 0), budget.reservedBytes());

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var oom_store: mutation.PausedPasteStore = .{};
    try oom_store.initInPlace(failing.allocator(), &budget, .{5} ** 16, 7, 11);
    defer oom_store.deinit();
    var payload = [_]u8{ 3, 4, 5, 6 };
    try std.testing.expectError(error.OutOfMemory, oom_store.capturePaste(&payload, 2, std.testing.io));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 3, 4, 5, 6 }, &payload);
    try std.testing.expectEqual(@as(usize, 0), budget.reservedBytes());

    var peak_stores: [4]mutation.PausedPasteStore = @splat(.{});
    var initialized: usize = 0;
    defer for (peak_stores[0..initialized]) |*peak_store| peak_store.deinit();
    const exact_payload = try allocator.alloc(u8, mutation.max_paste_bytes);
    defer allocator.free(exact_payload);
    for (&peak_stores, 0..) |*peak_store, index| {
        try peak_store.initInPlace(allocator, &budget, @splat(@as(u8, @intCast(20 + index))), 7, 11);
        initialized += 1;
        @memset(exact_payload, @intCast(index + 1));
        try peak_store.capturePaste(exact_payload, @intCast(20 + index), std.testing.io);
    }
    try std.testing.expectEqual(@as(usize, 4 * mutation.max_paste_bytes), budget.reservedBytes());
    for (&peak_stores) |*peak_store| try peak_store.prepareResend(7, 12, std.testing.io);
    try std.testing.expectEqual(mutation.max_global_bytes, budget.reservedBytes());
    var overflow_store: mutation.PausedPasteStore = .{};
    try overflow_store.initInPlace(allocator, &budget, .{30} ** 16, 7, 11);
    defer overflow_store.deinit();
    var one = [_]u8{0xAA};
    try std.testing.expectError(error.GlobalPasteLimit, overflow_store.capturePaste(&one, 30, std.testing.io));
    try std.testing.expectEqualSlices(u8, &[_]u8{0xAA}, &one);
}

test "CR2e-b PausedPaste는 boot-clock TTL과 send discard에서 payload와 staging을 지운다" {
    const allocator = std.testing.allocator;
    var budget: mutation.GlobalPasteBudget = .{};
    try budget.initInPlace();
    var trace = mutation.testing_api.WipeTrace{};
    mutation.testing_api.armWipeTrace(&trace);
    defer mutation.testing_api.disarmWipeTrace();

    var store: mutation.PausedPasteStore = .{};
    try store.initInPlace(allocator, &budget, .{3} ** 16, 7, 11);
    defer store.deinit();
    var payload = [_]u8{ 9, 8, 7, 6 };
    try store.capturePaste(&payload, 3, std.testing.io);
    try store.prepareResend(7, 12, std.testing.io);
    try std.testing.expectEqual(@as(usize, 8), budget.reservedBytes());
    var resend: mutation.PreparedResend = .{};
    try store.consumeResend(&resend);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 8, 7, 6 }, try resend.bytesView());
    try std.testing.expectEqual(@as(usize, 4), budget.reservedBytes());
    resend.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.reservedBytes());
    try std.testing.expectEqual(@as(usize, 3), trace.calls);
    try std.testing.expectEqual(@as(usize, 12), trace.bytes);

    var expiring: mutation.PausedPasteStore = .{};
    try expiring.initInPlace(allocator, &budget, .{4} ** 16, 7, 11);
    defer expiring.deinit();
    var later = [_]u8{ 1, 1, 2, 3 };
    try expiring.capturePasteAt(&later, 4, 100);
    try std.testing.expect(!try expiring.expireAt(100 + mutation.ttl_ns - 1));
    try std.testing.expect(try expiring.expireAt(100 + mutation.ttl_ns));
    try std.testing.expectEqual(@as(usize, 0), budget.reservedBytes());

    var corrupted: mutation.PausedPasteStore = .{};
    try corrupted.initInPlace(allocator, &budget, .{7} ** 16, 7, 11);
    defer corrupted.deinit();
    var corrupt_payload = [_]u8{ 4, 3, 2, 1 };
    try corrupted.capturePaste(&corrupt_payload, 5, std.testing.io);
    mutation.testing_api.corruptPasteByte(&corrupted, 0);
    try std.testing.expectError(error.InvalidAuthority, corrupted.prepareResend(7, 12, std.testing.io));
    try corrupted.discard();
    try std.testing.expectEqual(@as(usize, 0), budget.reservedBytes());
}
