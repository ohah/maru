//! C3-3b2b2 compatibility characterization.
//!
//! These tests keep the existing owning event facade honest while its metadata path moves to the
//! allocation-free recipe/fill leaf.  In particular, a peer violation must remain different from
//! local source drift observed after classification or an allocator callback.

const std = @import("std");
const protocol = @import("protocol");
const metadata_wire = @import("runtime_metadata_wire");
const event_types = @import("runtime_event_types");
const event_wire = @import("runtime_event_wire");

const identity: event_types.EventIdentity = .{ .runtime_id = 0xaa, .stream_id = 7 };
const controller: event_types.EventAuthorityView = .{
    .role = .controller,
    .generation = .{ .tracked = 3 },
};

const metadata_payload =
    \\{"event":"runtime.metadata","metadata_revision":9,"metadata":{"cwd":"/repo/src",
    \\"window_title":"work","ssh_remote_dest":"host:22","semantic_state":2,
    \\"alt_active":true,"app_cursor_keys":true,"app_keypad":true,"kitty_flags":3,
    \\"alternate_scroll":false,"mouse_tracking":true,"mouse_tracking_mode":2,
    \\"bracketed_paste":true,"bell_count":4,"clipboard_write_seq":5,
    \\"clipboard_read_seq":6,"clipboard_read_target":"c",
    \\"observer_generation":7,"title_generation":8,"cols":120,"rows":40,
    \\"foreground_available":true,"foreground_pgid":77,
    \\"processes":[{"pid":77,"name":"codex"}]}}
;

const empty_metadata_payload =
    \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"",
    \\"window_title":"","ssh_remote_dest":null,"semantic_state":0,
    \\"alt_active":false,"app_cursor_keys":false,"app_keypad":false,"kitty_flags":0,
    \\"alternate_scroll":true,"mouse_tracking":false,"mouse_tracking_mode":0,
    \\"bracketed_paste":false,"bell_count":0,"clipboard_write_seq":0,
    \\"clipboard_read_seq":0,"clipboard_read_target":"",
    \\"observer_generation":1,"title_generation":1,"cols":80,"rows":24,
    \\"foreground_available":false,"foreground_pgid":null,"processes":[]}}
;

fn frame(payload: []const u8) event_types.EventFrameView {
    return .{
        .major = protocol.version_major,
        .kind = .event,
        .stream_id = identity.stream_id,
        .request_id = 0,
        .flags = 0,
        .payload_len = @intCast(payload.len),
        .payload = payload,
    };
}

fn preflight(payload: []const u8) event_types.EventPreflightView {
    return .{
        .expected_major = protocol.version_major,
        .metadata_support = .supported,
        .verdict = event_wire.preflightEvent(payload, .{}),
    };
}

fn materialize(
    allocator: std.mem.Allocator,
    payload: []const u8,
) metadata_wire.EventMaterializationError!metadata_wire.OwnedEventClassification {
    return metadata_wire.classifyAndMaterializeEvent(
        allocator,
        identity,
        controller,
        preflight(payload),
        frame(payload),
    );
}

const CountingAllocator = struct {
    parent: std.mem.Allocator,
    allocation_calls: usize = 0,
    free_calls: usize = 0,
    fail_next: bool = false,
    mutate_payload: ?[]u8 = null,
    mutate_index: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.allocation_calls += 1;
        if (self.mutate_payload) |payload| payload[self.mutate_index] ^= 1;
        if (self.fail_next) {
            self.fail_next = false;
            return null;
        }
        return self.parent.vtable.alloc(
            self.parent.ptr,
            len,
            alignment,
            return_address,
        );
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.free_calls += 1;
        self.parent.vtable.free(
            self.parent.ptr,
            memory,
            alignment,
            return_address,
        );
    }
};

fn deinitClassification(value: *metadata_wire.OwnedEventClassification) void {
    switch (value.*) {
        .accepted => |*accepted| switch (accepted.*) {
            .metadata => |*dto| dto.deinit(),
            else => {},
        },
        .violation => {},
    }
}

test "compatibility keeps all non-metadata accepted and violation results allocation-free" {
    const payloads = [_][]const u8{
        "{\"event\":\"snapshot.invalidated\"}",
        "{\"event\":\"runtime.ended\"}",
        "{\"event\":\"runtime.resized\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"cols\":120,\"rows\":40,\"resize_generation\":9,\"reason\":\"controller\"}}",
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
        "{\"event\":\"future.event\"}",
    };
    var counter: CountingAllocator = .{ .parent = std.testing.allocator };
    for (payloads) |payload| {
        var result = try materialize(counter.allocator(), payload);
        defer deinitClassification(&result);
    }
    try std.testing.expectEqual(@as(usize, 0), counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 0), counter.free_calls);
}

test "compatibility metadata preserves zero or one exact owning allocation and semantics" {
    var counter: CountingAllocator = .{ .parent = std.testing.allocator };
    var empty = try materialize(counter.allocator(), empty_metadata_payload);
    defer deinitClassification(&empty);
    try std.testing.expectEqual(@as(usize, 0), counter.allocation_calls);
    const empty_dto = switch (empty) {
        .accepted => |*accepted| switch (accepted.*) {
            .metadata => |*dto| dto,
            else => return error.TestUnexpectedResult,
        },
        .violation => return error.TestUnexpectedResult,
    };
    try std.testing.expect(empty_dto.backing == null);
    try std.testing.expect(empty_dto.sshRemoteDest() == null);

    var populated = try materialize(counter.allocator(), metadata_payload);
    defer deinitClassification(&populated);
    try std.testing.expectEqual(@as(usize, 1), counter.allocation_calls);
    const dto = switch (populated) {
        .accepted => |*accepted| switch (accepted.*) {
            .metadata => |*value| value,
            else => return error.TestUnexpectedResult,
        },
        .violation => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("/repo/src", dto.cwd());
    try std.testing.expectEqualStrings("work", dto.windowTitle());
    try std.testing.expectEqualStrings("host:22", dto.sshRemoteDest().?);
    try std.testing.expectEqualStrings("c", dto.clipboardReadTarget());
    try std.testing.expectEqual(@as(u8, 1), dto.process_count);
    try std.testing.expectEqualStrings("codex", dto.processes[0].slice());
}

test "compatibility reports OOM only at the one owning allocation and publishes nothing" {
    var counter: CountingAllocator = .{
        .parent = std.testing.allocator,
        .fail_next = true,
    };
    try std.testing.expectError(
        error.OutOfMemory,
        materialize(counter.allocator(), metadata_payload),
    );
    try std.testing.expectEqual(@as(usize, 1), counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 0), counter.free_calls);
}

test "compatibility rejects allocator-callback scalar source drift as a local invariant" {
    var payload = metadata_payload.*;
    const revision = std.mem.indexOf(u8, &payload, "metadata_revision\":9").? +
        "metadata_revision\":".len;
    var counter: CountingAllocator = .{
        .parent = std.testing.allocator,
        .mutate_payload = &payload,
        .mutate_index = revision,
    };
    try std.testing.expectError(
        error.LocalInvariant,
        materialize(counter.allocator(), &payload),
    );
    try std.testing.expectEqual(@as(usize, 1), counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 1), counter.free_calls);
}

test "compatibility rejects allocator-callback retained string drift and frees once" {
    var payload = metadata_payload.*;
    const cwd_byte = std.mem.indexOf(u8, &payload, "/repo/src").? + 1;
    var counter: CountingAllocator = .{
        .parent = std.testing.allocator,
        .mutate_payload = &payload,
        .mutate_index = cwd_byte,
    };
    try std.testing.expectError(
        error.LocalInvariant,
        materialize(counter.allocator(), &payload),
    );
    try std.testing.expectEqual(@as(usize, 1), counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 1), counter.free_calls);
}

test "compatibility separates peer violations from forged accepted local provenance" {
    var counter: CountingAllocator = .{ .parent = std.testing.allocator };
    const malformed = "{\"event\":\"runtime.metadata\",\"metadata\":";
    var peer = try metadata_wire.classifyAndMaterializeEvent(
        counter.allocator(),
        identity,
        controller,
        .{
            .expected_major = protocol.version_major,
            .metadata_support = .supported,
            .verdict = .malformed,
        },
        frame(malformed),
    );
    defer deinitClassification(&peer);
    switch (peer) {
        .violation => |violation| try std.testing.expectEqual(
            .malformed,
            std.meta.activeTag(violation),
        ),
        .accepted => return error.TestUnexpectedResult,
    }

    var forged = preflight(metadata_payload);
    switch (forged.verdict) {
        .accepted => |*accepted| switch (accepted.event) {
            .metadata => |*value| value.revision += 1,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(
        error.LocalInvariant,
        metadata_wire.classifyAndMaterializeEvent(
            counter.allocator(),
            identity,
            controller,
            forged,
            frame(metadata_payload),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 0), counter.free_calls);
}
