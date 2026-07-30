//! Test-only product-independent harness for buffered RX traversal.
//!
//! The fixture owns only a sealed parser, a synthetic leaf authority, and an intent handle. It
//! deliberately cannot construct pump storage, ledger tokens, or aggregate commit capability.

const std = @import("std");
const builtin = @import("builtin");
const client_external_mode = @import("client_external_mode.zig");
const client_external_rx_turn = @import("client_external_rx_turn.zig");
const external_rx_demux = @import("external_rx_demux.zig");
const external_rx_intent = @import("external_rx_intent.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");

comptime {
    if (!builtin.is_test)
        @compileError("client_external_rx_turn_test_support is test-only");
}

const Authority = struct {
    storage_marker: u8 = 0,
    operation_generation: u64 = 1,
    reservation_handle_addr: usize = 0,
    reservation_generation: u64 = 0,
    state: *client_external_mode.State,
    parser: *framing.FrameParser,

    fn current(raw: *anyopaque) ?external_rx_intent.AuthorityView {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const provenance = self.state.rx_provenance;
        return .{
            .storage_addr = @intFromPtr(&self.storage_marker),
            .storage_len = 1,
            .operation_generation = self.operation_generation,
            .parser_generation = provenance.parser_seal.generation,
            .buffer_start_absolute = provenance.buffer_start_absolute,
            .identity = provenance.identity orelse return null,
            .allocator = self.parser.allocator,
            .reservation_handle_addr = self.reservation_handle_addr,
            .reservation_generation = self.reservation_generation,
        };
    }

    fn ops(self: *@This()) external_rx_intent.AuthorityOps {
        return .{ .context = self, .current = current };
    }
};

const AcceptGuard = struct {
    fn check(_: *anyopaque, _: usize, _: usize) client_external_mode.PayloadAllocationVerdict {
        return .accepted;
    }

    fn ops(self: *@This()) client_external_mode.PayloadAllocationGuard {
        return .{ .context = self, .check = check };
    }
};

const Harness = struct {
    parser: framing.FrameParser,
    state: client_external_mode.State = .{ .saved_flags = 7 },
    destination_slot: usize = 0,
    scratch: client_external_rx_turn.Scratch = .{},
    authority: Authority,

    fn initInPlace(out: *Harness, wire: []const u8) !void {
        return initWithAllocator(out, wire, std.testing.allocator);
    }

    fn initWithAllocator(
        out: *Harness,
        wire: []const u8,
        allocator: std.mem.Allocator,
    ) !void {
        out.* = .{
            .parser = framing.FrameParser.init(allocator),
            .state = .{ .saved_flags = 7 },
            .authority = undefined,
        };
        errdefer out.parser.deinit();
        errdefer out.state.deinit(std.testing.allocator);
        out.authority = .{
            .state = &out.state,
            .parser = &out.parser,
        };
        try std.testing.expect(
            client_external_rx_turn.Scratch.initInPlace(&out.scratch),
        );
        try out.parser.push(wire);
        var normalized: framing.PreparedNormalizeExact = .{};
        defer normalized.deinit();
        try out.parser.prepareNormalizeExact(
            &normalized,
            out.parser.residentBytes(),
        );
        var prepared: client_external_mode.PreparedRxBind = .{};
        defer prepared.deinit();
        try client_external_mode.prepareRxBind(
            &out.state,
            77,
            &normalized,
            @intFromPtr(&out.destination_slot),
            @sizeOf(usize),
            &prepared,
        );
        try std.testing.expectEqual(
            framing.NormalizeCommitOutcome.committed,
            out.parser.commitPreparedNormalizeExact(&normalized),
        );
        client_external_mode.commitPreparedRxBind(
            &out.state,
            &out.parser,
            &prepared,
            @intFromPtr(&out.destination_slot),
            @sizeOf(usize),
        );
        try std.testing.expectEqual(
            external_rx_intent.CreateResult.allocated,
            external_rx_intent.allocate(
                &out.scratch.intent,
                allocator,
                out.authority.ops(),
            ),
        );
        out.authority.reservation_handle_addr =
            @intFromPtr(&out.scratch.intent);
        out.authority.reservation_generation = 1;
        try std.testing.expectEqual(
            external_rx_intent.BindResult.bound,
            external_rx_intent.bindReservation(
                &out.scratch.intent,
                Authority.current(&out.authority).?,
            ),
        );
    }

    fn deinit(self: *Harness) void {
        _ = external_rx_intent.abortAll(&self.scratch.intent);
        self.authority.operation_generation += 1;
        _ = external_rx_intent.resetForNextTurn(
            &self.scratch.intent,
            self.authority.ops(),
        );
        _ = client_external_rx_turn.Scratch.resetForNextTurn(&self.scratch);
        var prepared: external_rx_intent.PreparedDestroy = .{};
        if (external_rx_intent.prepareDestroy(
            &self.scratch.intent,
            @intFromPtr(&self.authority.storage_marker),
            1,
            &prepared,
        )) {
            const frozen = external_rx_intent.commitPreparedDestroy(
                &self.scratch.intent,
                &prepared,
            );
            self.authority.reservation_handle_addr = 0;
            self.authority.reservation_generation = 0;
            external_rx_intent.finishFrozenDestroy(frozen);
        }
        self.state.deinit(self.parser.allocator);
        self.parser.deinit();
    }

    fn traverse(
        self: *Harness,
        partial: ?external_rx_demux.ValidatedPartialView,
    ) client_external_rx_turn.Result {
        var guard = AcceptGuard{};
        const guard_ops = guard.ops();
        return self.traverseWithGuard(partial, &guard_ops);
    }

    fn traverseWithGuard(
        self: *Harness,
        partial: ?external_rx_demux.ValidatedPartialView,
        guard: *const client_external_mode.PayloadAllocationGuard,
    ) client_external_rx_turn.Result {
        return client_external_rx_turn.traverseBuffered(.{
            .state = &self.state,
            .parser = &self.parser,
            .scratch = &self.scratch,
            .authority = self.authority.ops(),
            .payload_guard = guard,
            .target_stream_id = 7,
            .partial = partial,
        });
    }

    fn resetTurn(self: *Harness) bool {
        self.authority.operation_generation =
            std.math.add(
                u64,
                self.authority.operation_generation,
                1,
            ) catch return false;
        if (external_rx_intent.resetForNextTurn(
            &self.scratch.intent,
            self.authority.ops(),
        ) != .ready)
            return false;
        return client_external_rx_turn.Scratch.resetForNextTurn(
            &self.scratch,
        );
    }
};

const ReentryGuard = struct {
    harness: *Harness,
    calls: usize = 0,
    inner_rejected: bool = false,

    fn check(
        raw: *anyopaque,
        _: usize,
        _: usize,
    ) client_external_mode.PayloadAllocationVerdict {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        const own_ops = self.ops();
        const inner = self.harness.traverseWithGuard(null, &own_ops);
        self.inner_rejected = switch (inner) {
            .terminal => |failure| failure.reason == .invariant_failure and
                failure.rx_bytes == 0 and failure.rx_frames == 0,
            else => false,
        };
        return .accepted;
    }

    fn ops(self: *@This()) client_external_mode.PayloadAllocationGuard {
        return .{ .context = self, .check = check };
    }
};

const MutatingDescriptorGuard = struct {
    descriptor: *client_external_mode.PayloadAllocationGuard,
    calls: usize = 0,

    fn check(
        raw: *anyopaque,
        _: usize,
        _: usize,
    ) client_external_mode.PayloadAllocationVerdict {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.descriptor.context = @ptrCast(self.descriptor);
        return .accepted;
    }
};

const PayloadAliasAllocator = struct {
    parent: std.mem.Allocator,
    target: ?[*]u8 = null,
    target_len: usize = 0,
    armed: bool = false,
    returned_target: bool = false,
    freed_target: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.armed and !self.returned_target and self.target != null and
            len == self.target_len)
        {
            self.returned_target = true;
            return self.target.?;
        }
        return self.parent.vtable.alloc(
            self.parent.ptr,
            len,
            alignment,
            ret_addr,
        );
    }

    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.target != null and memory.ptr == self.target.?) return false;
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.target != null and memory.ptr == self.target.?) return null;
        return self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.target != null and memory.ptr == self.target.?) {
            self.freed_target += 1;
            return;
        }
        self.parent.vtable.free(
            self.parent.ptr,
            memory,
            alignment,
            ret_addr,
        );
    }
};

fn appendFrame(
    bytes: *std.ArrayList(u8),
    header: protocol.Header,
    payload: []const u8,
) !void {
    const wire = try framing.encodeFrame(std.testing.allocator, header, payload);
    defer std.testing.allocator.free(wire);
    try bytes.appendSlice(std.testing.allocator, wire);
}

test "d2c pre-entry traversal seals partial and leaves the 65th frame buffered" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    for (0..65) |index| {
        try appendFrame(
            &bytes,
            .{
                .kind = if (index == 0) .snapshot_chunk else .event,
                .stream_id = 7,
                .flags = if (index == 0) protocol.Flags.end_stream else 0,
            },
            "x",
        );
    }
    const harness = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(harness);
    try Harness.initInPlace(harness, bytes.items);
    defer harness.deinit();
    const first = harness.traverse(null);
    const summary = switch (first) {
        .staged => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 64), summary.rx_frames);
    try std.testing.expectEqual(@as(u8, 64), summary.classified_count);
    try std.testing.expect(summary.budget_exhausted);
    try std.testing.expect(summary.partial == null);
    try std.testing.expectEqual(
        client_external_mode.RxParserReadiness.complete_or_error,
        summary.final_readiness,
    );
}

test "d2c pre-entry traversal returns classifier-owned partial after view" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendFrame(
        &bytes,
        .{
            .kind = .delta_chunk,
            .stream_id = 7,
            .flags = 0,
        },
        "partial",
    );
    const harness = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(harness);
    try Harness.initInPlace(harness, bytes.items);
    defer harness.deinit();
    const result = harness.traverse(null);
    const summary = switch (result) {
        .staged => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const partial = summary.partial orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), partial.chunk_count);
    try std.testing.expectEqual(@as(u64, 7), partial.stream_id);
    try std.testing.expect(!partial.is_snapshot);
}

test "d2c pre-entry traversal consumes one sealed partial continuation and end" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendFrame(
        &bytes,
        .{ .kind = .delta_chunk, .stream_id = 7 },
        "first",
    );
    try appendFrame(
        &bytes,
        .{
            .kind = .delta_chunk,
            .stream_id = 7,
            .flags = protocol.Flags.end_stream,
        },
        "last",
    );
    const harness = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(harness);
    try Harness.initInPlace(harness, bytes.items);
    defer harness.deinit();
    const summary = switch (harness.traverse(null)) {
        .staged => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), summary.rx_frames);
    try std.testing.expectEqual(@as(u8, 2), summary.classified_count);
    try std.testing.expect(summary.partial == null);
}

test "d2c pre-entry traversal preserves incomplete header and payload tails" {
    const wire = try framing.encodeFrame(
        std.testing.allocator,
        .{
            .kind = .delta_chunk,
            .stream_id = 7,
            .flags = protocol.Flags.end_stream,
        },
        "tail",
    );
    defer std.testing.allocator.free(wire);
    const lengths = [_]usize{
        1,
        protocol.header_size - 1,
        protocol.header_size,
        wire.len - 1,
    };
    inline for (lengths) |len| {
        const harness = try std.testing.allocator.create(Harness);
        defer std.testing.allocator.destroy(harness);
        try Harness.initInPlace(harness, wire[0..len]);
        defer harness.deinit();
        const result = harness.traverse(null);
        const summary = switch (result) {
            .no_intents => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(usize, 0), summary.rx_frames);
        try std.testing.expectEqual(
            client_external_mode.RxParserReadiness.incomplete,
            summary.final_readiness,
        );
        try std.testing.expectEqual(len, harness.parser.bufferedBytes());
    }
}

test "d2c pre-entry traversal charges optional skip before an incomplete tail" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendFrame(
        &bytes,
        .{
            .kind = @enumFromInt(55001),
            .flags = protocol.Flags.optional,
        },
        "ignored",
    );
    const tail = try framing.encodeFrame(
        std.testing.allocator,
        .{ .kind = .event, .stream_id = 7 },
        "tail",
    );
    defer std.testing.allocator.free(tail);
    try bytes.appendSlice(
        std.testing.allocator,
        tail[0 .. protocol.header_size - 1],
    );
    const harness = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(harness);
    try Harness.initInPlace(harness, bytes.items);
    defer harness.deinit();
    const result = harness.traverse(null);
    const summary = switch (result) {
        .no_intents => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), summary.rx_frames);
    try std.testing.expectEqual(@as(u8, 0), summary.classified_count);
    try std.testing.expectEqual(
        client_external_mode.RxParserReadiness.incomplete,
        summary.final_readiness,
    );
}

test "d2c pre-entry no-intents budget can reset and consume the remaining frame" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    for (0..65) |_| {
        try appendFrame(
            &bytes,
            .{
                .kind = @enumFromInt(55001),
                .flags = protocol.Flags.optional,
            },
            "ignored",
        );
    }
    const harness = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(harness);
    try Harness.initInPlace(harness, bytes.items);
    defer harness.deinit();
    const first = switch (harness.traverse(null)) {
        .no_intents => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 64), first.rx_frames);
    try std.testing.expectEqual(@as(u8, 0), first.classified_count);
    try std.testing.expect(first.budget_exhausted);
    try std.testing.expect(harness.resetTurn());
    const second = switch (harness.traverse(null)) {
        .no_intents => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), second.rx_frames);
    try std.testing.expectEqual(@as(u8, 0), second.classified_count);
    try std.testing.expect(!second.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 0), harness.parser.bufferedBytes());
}

test "d2c pre-entry traversal aborts an accepted prefix on a late terminal" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendFrame(
        &bytes,
        .{
            .kind = .snapshot_chunk,
            .stream_id = 7,
            .flags = protocol.Flags.end_stream,
        },
        "accepted",
    );
    try appendFrame(&bytes, .{ .kind = .ping }, "");
    try appendFrame(
        &bytes,
        .{ .kind = .event, .stream_id = 7 },
        "next",
    );
    const harness = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(harness);
    try Harness.initInPlace(harness, bytes.items);
    defer harness.deinit();
    const result = harness.traverse(null);
    const failure = switch (result) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        client_external_rx_turn.FailureReason.protocol_error,
        failure.reason,
    );
    try std.testing.expectEqual(@as(usize, 2), failure.rx_frames);
    try std.testing.expect(harness.resetTurn());
    try std.testing.expect(switch (harness.traverse(null)) {
        .staged => |summary| summary.rx_frames == 1 and
            summary.classified_count == 1,
        else => false,
    });
}

test "d2c pre-entry partial mismatch and cap plus one stay terminal" {
    var mismatch_bytes: std.ArrayList(u8) = .empty;
    defer mismatch_bytes.deinit(std.testing.allocator);
    try appendFrame(
        &mismatch_bytes,
        .{ .kind = .snapshot_chunk, .stream_id = 7 },
        "first",
    );
    try appendFrame(
        &mismatch_bytes,
        .{ .kind = .delta_chunk, .stream_id = 7 },
        "mismatch",
    );
    const mismatch = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(mismatch);
    try Harness.initInPlace(mismatch, mismatch_bytes.items);
    defer mismatch.deinit();
    const mismatch_failure = switch (mismatch.traverse(null)) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        client_external_rx_turn.FailureReason.protocol_error,
        mismatch_failure.reason,
    );
    try std.testing.expectEqual(@as(usize, 2), mismatch_failure.rx_frames);

    var cap_bytes: std.ArrayList(u8) = .empty;
    defer cap_bytes.deinit(std.testing.allocator);
    for (0..protocol.max_screen_batch_chunks + 1) |_| {
        try appendFrame(
            &cap_bytes,
            .{ .kind = .snapshot_chunk, .stream_id = 7 },
            "chunk",
        );
    }
    const capped = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(capped);
    try Harness.initInPlace(capped, cap_bytes.items);
    defer capped.deinit();
    const cap_failure = switch (capped.traverse(null)) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        client_external_rx_turn.FailureReason.protocol_error,
        cap_failure.reason,
    );
    try std.testing.expectEqual(
        protocol.max_screen_batch_chunks + 1,
        cap_failure.rx_frames,
    );
}

test "d2c pre-entry mandatory guard rejects payload alias into traversal scratch" {
    var allocator = PayloadAliasAllocator{
        .parent = std.testing.allocator,
    };
    const wire = try framing.encodeFrame(
        std.testing.allocator,
        .{
            .kind = .delta_chunk,
            .stream_id = 7,
            .flags = protocol.Flags.end_stream,
        },
        "x",
    );
    defer std.testing.allocator.free(wire);
    const harness = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(harness);
    try Harness.initWithAllocator(harness, wire, allocator.allocator());
    defer harness.deinit();
    var before_parse: [@sizeOf(client_external_mode.RxParseScratch)]u8 =
        undefined;
    @memcpy(&before_parse, std.mem.asBytes(&harness.scratch.parse));
    allocator.target = @ptrCast(&harness.scratch.parse);
    allocator.target_len = 1;
    allocator.armed = true;
    const result = harness.traverse(null);
    const failure = switch (result) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        client_external_rx_turn.FailureReason.allocation_quarantined,
        failure.reason,
    );
    try std.testing.expectEqual(@as(usize, 0), failure.rx_frames);
    try std.testing.expectEqual(@as(usize, 0), allocator.freed_target);
    try std.testing.expectEqualSlices(
        u8,
        &before_parse,
        std.mem.asBytes(&harness.scratch.parse),
    );
}

test "d2c pre-entry mandatory guard rejects payload alias into delegate descriptor" {
    var allocator = PayloadAliasAllocator{
        .parent = std.testing.allocator,
    };
    const wire = try framing.encodeFrame(
        std.testing.allocator,
        .{ .kind = .event, .stream_id = 7 },
        "x",
    );
    defer std.testing.allocator.free(wire);
    const harness = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(harness);
    try Harness.initWithAllocator(harness, wire, allocator.allocator());
    defer harness.deinit();
    var guard = AcceptGuard{};
    var guard_ops = guard.ops();
    var before: [@sizeOf(client_external_mode.PayloadAllocationGuard)]u8 =
        undefined;
    @memcpy(&before, std.mem.asBytes(&guard_ops));
    allocator.target = @ptrCast(&guard_ops);
    allocator.target_len = 1;
    allocator.armed = true;
    const buffered_before = harness.parser.bufferedBytes();
    const failure = switch (harness.traverseWithGuard(null, &guard_ops)) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        client_external_rx_turn.FailureReason.allocation_quarantined,
        failure.reason,
    );
    try std.testing.expectEqual(@as(usize, 0), failure.rx_frames);
    try std.testing.expectEqual(buffered_before, harness.parser.bufferedBytes());
    try std.testing.expectEqual(@as(usize, 0), allocator.freed_target);
    try std.testing.expectEqualSlices(
        u8,
        &before,
        std.mem.asBytes(&guard_ops),
    );
}

test "d2c pre-entry mandatory guard rejects delegate descriptor mutation" {
    const wire = try framing.encodeFrame(
        std.testing.allocator,
        .{ .kind = .event, .stream_id = 7 },
        "event",
    );
    defer std.testing.allocator.free(wire);
    const harness = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(harness);
    const backing = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing);
    try Harness.initWithAllocator(harness, wire, fixed.allocator());
    defer harness.deinit();
    var guard_ops: client_external_mode.PayloadAllocationGuard = undefined;
    var guard = MutatingDescriptorGuard{ .descriptor = &guard_ops };
    guard_ops = .{
        .context = &guard,
        .check = MutatingDescriptorGuard.check,
    };
    const buffered_before = harness.parser.bufferedBytes();
    const failure = switch (harness.traverseWithGuard(null, &guard_ops)) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), guard.calls);
    try std.testing.expectEqual(
        client_external_rx_turn.FailureReason.allocation_quarantined,
        failure.reason,
    );
    try std.testing.expectEqual(@as(usize, 0), failure.rx_frames);
    try std.testing.expectEqual(buffered_before, harness.parser.bufferedBytes());
}

test "d2c pre-entry parser payload allocation fail index closes the intent" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    const wire = try framing.encodeFrame(
        std.testing.allocator,
        .{ .kind = .event, .stream_id = 7 },
        "event",
    );
    defer std.testing.allocator.free(wire);
    const harness = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(harness);
    try Harness.initWithAllocator(harness, wire, failing.allocator());
    defer harness.deinit();
    failing.fail_index = failing.alloc_index;
    const before = harness.parser.bufferedBytes();
    const failure = switch (harness.traverse(null)) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        client_external_rx_turn.FailureReason.resource_exhausted,
        failure.reason,
    );
    try std.testing.expectEqual(@as(usize, 0), failure.rx_frames);
    try std.testing.expectEqual(before, harness.parser.bufferedBytes());
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(harness.resetTurn());
    try std.testing.expect(switch (harness.traverse(null)) {
        .staged => |summary| summary.rx_frames == 1 and
            summary.classified_count == 1,
        else => false,
    });
}

test "d2c pre-entry copied scratch is rejected before parser consume" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendFrame(
        &bytes,
        .{ .kind = .event, .stream_id = 7 },
        "event",
    );
    const harness = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(harness);
    try Harness.initInPlace(harness, bytes.items);
    defer harness.deinit();
    var copied = harness.scratch;
    var guard = AcceptGuard{};
    const guard_ops = guard.ops();
    const before = harness.parser.bufferedBytes();
    const rejected = client_external_rx_turn.traverseBuffered(.{
        .state = &harness.state,
        .parser = &harness.parser,
        .scratch = &copied,
        .authority = harness.authority.ops(),
        .payload_guard = &guard_ops,
        .target_stream_id = 7,
        .partial = null,
    });
    try std.testing.expect(switch (rejected) {
        .terminal => |failure| failure.reason == .invariant_failure,
        else => false,
    });
    try std.testing.expectEqual(before, harness.parser.bufferedBytes());
    try std.testing.expect(switch (harness.traverse(null)) {
        .staged => true,
        else => false,
    });
}

test "d2c pre-entry allocation callback reentry is rejected" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendFrame(
        &bytes,
        .{ .kind = .event, .stream_id = 7 },
        "event",
    );
    const harness = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(harness);
    try Harness.initInPlace(harness, bytes.items);
    defer harness.deinit();
    var guard = ReentryGuard{ .harness = harness };
    const guard_ops = guard.ops();
    try std.testing.expect(switch (harness.traverseWithGuard(null, &guard_ops)) {
        .staged => true,
        else => false,
    });
    try std.testing.expectEqual(@as(usize, 1), guard.calls);
    try std.testing.expect(guard.inner_rejected);
}
