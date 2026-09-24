//! CR2e-c heap-pinned generation slot focused TDD.

const std = @import("std");
const builtin = @import("builtin");
const generation_slot = @import("reconnect_generation_slot");

const Payload = struct {
    connection_generation: u64,
    screen_id: u64,
    attachment_id: u64,
    observation_revision: u64,
};
const Slot = generation_slot.GenerationSlot(Payload);

fn payload(generation: u64) Payload {
    return .{
        .connection_generation = generation,
        .screen_id = 100 + generation,
        .attachment_id = 200 + generation,
        .observation_revision = 300 + generation,
    };
}

fn readSlotFromForeignThread(slot: *const Slot, rejected: *std.atomic.Value(bool)) void {
    _ = slot.currentGeneration() catch |err| {
        rejected.store(err == error.InvalidAuthority, .release);
        return;
    };
}

fn initializePayload(out: *Payload, value: Payload) !void {
    out.* = value;
}

fn rejectPayloadInitialization(_: *Payload, _: Payload) !void {
    return error.InjectedFailure;
}

fn buildCandidate(slot: *Slot, value: Payload, out: *Slot.PreparedCandidate) !void {
    try slot.beginCandidate(out);
    try slot.initializeCandidate(out, value, initializePayload);
}

fn initSlot(slot: *Slot, allocator: std.mem.Allocator, generation: u64, value: Payload) !void {
    try slot.initInPlace(allocator, generation, value, initializePayload);
}

test "CR2e-c generation slot은 inline 최초 세대와 heap 후보 payload parity를 보존한다" {
    var slot: Slot = .{};
    try initSlot(&slot, std.testing.allocator, 1, payload(1));
    try std.testing.expectEqual(@as(u64, 1), try slot.currentGeneration());
    try std.testing.expectEqual(payload(1), (try slot.currentPayload()).*);
    try std.testing.expectEqual(@intFromPtr(&slot.inline_node), @intFromPtr(slot.current.?));

    var candidate: Slot.PreparedCandidate = .{};
    try buildCandidate(&slot, payload(2), &candidate);
    const heap_addr = candidate.node_addr;
    try slot.publishCandidate(&candidate);
    try std.testing.expectEqual(@as(u64, 2), try slot.currentGeneration());
    try std.testing.expectEqual(payload(2), (try slot.currentPayload()).*);
    try std.testing.expectEqual(heap_addr, @intFromPtr(slot.current.?));
    try std.testing.expect(try slot.hasRetiring());

    var retired: Slot.PayloadSource = .{};
    try slot.reclaimRetiring(&retired);
    try std.testing.expectEqual(payload(1), retired.value);
    try std.testing.expectEqual(generation_slot.NodeLifecycle.tombstone, slot.inline_node.lifecycle);
    var final: Slot.PayloadSource = .{};
    try slot.deinit(&final);
    try std.testing.expectEqual(payload(2), final.value);
}

test "CR2e-c generation slot은 retiring 하나만 허용하고 회수 뒤 다음 heap 세대를 게시한다" {
    var slot: Slot = .{};
    try initSlot(&slot, std.testing.allocator, 7, payload(7));
    var candidate: Slot.PreparedCandidate = .{};
    try buildCandidate(&slot, payload(8), &candidate);
    try slot.publishCandidate(&candidate);

    var blocked: Slot.PreparedCandidate = .{};
    try std.testing.expectError(error.RetiringBusy, slot.beginCandidate(&blocked));
    try std.testing.expectEqual(Slot.PreparedCandidate{}, blocked);
    try std.testing.expectEqual(@as(u64, 8), try slot.currentGeneration());

    var retired_inline: Slot.PayloadSource = .{};
    try slot.reclaimRetiring(&retired_inline);
    try buildCandidate(&slot, payload(9), &blocked);
    const third_addr = blocked.node_addr;
    try slot.publishCandidate(&blocked);
    var retired_heap: Slot.PayloadSource = .{};
    try slot.reclaimRetiring(&retired_heap);
    try std.testing.expectEqual(payload(8), retired_heap.value);
    try std.testing.expectEqual(@as(u64, 9), try slot.currentGeneration());
    try std.testing.expectEqual(third_addr, @intFromPtr(slot.current.?));
    var final: Slot.PayloadSource = .{};
    try slot.deinit(&final);
}

test "CR2e-c generation slot은 allocator 실패와 abort에서 destination과 current를 보존한다" {
    var init_failed: Slot = .{};
    try std.testing.expectError(
        error.InjectedFailure,
        init_failed.initInPlace(std.testing.allocator, 2, payload(2), rejectPayloadInitialization),
    );
    try initSlot(&init_failed, std.testing.allocator, 2, payload(2));
    var init_failed_out: Slot.PayloadSource = .{};
    try init_failed.deinit(&init_failed_out);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var slot: Slot = .{};
    try initSlot(&slot, failing.allocator(), 3, payload(3));
    var candidate: Slot.PreparedCandidate = .{};
    try std.testing.expectError(error.OutOfMemory, slot.beginCandidate(&candidate));
    try std.testing.expectEqual(Slot.PreparedCandidate{}, candidate);
    try std.testing.expectEqual(@as(u64, 3), try slot.currentGeneration());

    slot.allocator = std.testing.allocator;
    try slot.beginCandidate(&candidate);
    try std.testing.expectError(
        error.InjectedFailure,
        slot.initializeCandidate(&candidate, payload(40), rejectPayloadInitialization),
    );
    try slot.abortEmptyCandidate(&candidate);
    try std.testing.expectEqual(@as(u64, 3), try slot.currentGeneration());
    try buildCandidate(&slot, payload(4), &candidate);
    var aborted: Slot.PayloadSource = .{};
    try slot.abortCandidate(&candidate, &aborted);
    try std.testing.expectEqual(payload(4), aborted.value);
    try std.testing.expectEqual(@as(u64, 3), try slot.currentGeneration());
    var final: Slot.PayloadSource = .{};
    try slot.deinit(&final);

    var terminal: Slot = .{};
    try initSlot(&terminal, std.testing.allocator, std.math.maxInt(u64) - 1, payload(90));
    var exhausted: Slot.PreparedCandidate = .{};
    try std.testing.expectError(error.Exhausted, terminal.beginCandidate(&exhausted));
    try std.testing.expectEqual(Slot.PreparedCandidate{}, exhausted);
    var terminal_out: Slot.PayloadSource = .{};
    try terminal.deinit(&terminal_out);
}

test "CR2e-c generation slot은 copied stale cross-slot authority와 inline 재사용을 거부한다" {
    var slot_a: Slot = .{};
    try initSlot(&slot_a, std.testing.allocator, 10, payload(10));
    var copied_slot = slot_a;
    try std.testing.expectError(error.InvalidAuthority, copied_slot.currentGeneration());
    var foreign_rejected = std.atomic.Value(bool).init(false);
    const foreign = try std.Thread.spawn(.{}, readSlotFromForeignThread, .{ &slot_a, &foreign_rejected });
    foreign.join();
    try std.testing.expect(foreign_rejected.load(.acquire));
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        const child = std.c.fork();
        if (child < 0) return error.TestUnexpectedResult;
        if (child == 0) {
            _ = slot_a.currentGeneration() catch std.c._exit(86);
            std.c._exit(75);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        const unsigned: u32 = @bitCast(status);
        try std.testing.expect(std.c.W.IFEXITED(unsigned));
        try std.testing.expectEqual(@as(u8, 86), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned))));
    }

    const slot_before_alias = slot_a;
    const alias_candidate: *Slot.PreparedCandidate = @ptrCast(@alignCast(&slot_a.inline_node));
    try std.testing.expectError(error.InvalidAuthority, slot_a.beginCandidate(alias_candidate));
    try std.testing.expectEqualDeep(slot_before_alias, slot_a);

    var slot_b: Slot = .{};
    try initSlot(&slot_b, std.testing.allocator, 20, payload(20));
    var candidate: Slot.PreparedCandidate = .{};
    try buildCandidate(&slot_a, payload(11), &candidate);
    var copied_candidate = candidate;
    try std.testing.expectError(error.InvalidAuthority, slot_a.publishCandidate(&copied_candidate));
    try std.testing.expectError(error.InvalidAuthority, slot_b.publishCandidate(&candidate));
    const canonical_generation = candidate.generation;
    candidate.generation += 1;
    try std.testing.expectError(error.InvalidAuthority, slot_a.publishCandidate(&candidate));
    candidate.generation = canonical_generation;
    try slot_a.publishCandidate(&candidate);
    try std.testing.expectError(error.InvalidAuthority, slot_a.publishCandidate(&candidate));
    var retired: Slot.PayloadSource = .{};
    try slot_a.reclaimRetiring(&retired);
    try std.testing.expectEqual(generation_slot.NodeLifecycle.tombstone, slot_a.inline_node.lifecycle);
    retired.present = false;
    try std.testing.expectError(error.NoRetiringGeneration, slot_a.reclaimRetiring(&retired));

    var out_a: Slot.PayloadSource = .{};
    try slot_a.deinit(&out_a);
    try std.testing.expectError(
        error.InvalidAuthority,
        slot_a.initInPlace(std.testing.allocator, 30, payload(30), initializePayload),
    );
    var out_b: Slot.PayloadSource = .{};
    try slot_b.deinit(&out_b);
}
