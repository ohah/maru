const std = @import("std");

pub const max_actions: usize = 8;
pub const max_payload_bytes: usize = 32 * 1024 * 1024;
pub const max_paths_per_action: usize = 256;
pub const max_path_block_bytes: usize = 64 * 1024;
pub const action_deadline_ms: u64 = 5_000;

pub const Admission = enum {
    accepted,
    action_limit,
    payload_limit,
    path_count_limit,
    path_block_limit,
    duplicate_id,
    closed,
};

pub const Next = enum { empty, busy, expired, ready };
pub const Active = enum { idle, pending, expired };
pub const Completion = enum { apply, stale_target, wrong_action, closed };

pub const TargetIdentity = struct {
    surface_id: u64 = 0,
    runtime_handle: u64 = 0,
    host_id: u128 = 0,
    runtime_id: [32]u8 = [_]u8{0} ** 32,
    runtime_generation: u64 = 0,
};

pub const Descriptor = struct {
    id: u64,
    admitted_ms: u64,
    payload_bytes: usize = 0,
    path_count: usize = 0,
    path_block_bytes: usize = 0,
    target: TargetIdentity = .{},
};

/// Allocation-free admission ledger. Payload ownership stays with AppSession, but it may only
/// allocate/copy after this ledger accepts the exact byte and item charge.
pub const Queue = struct {
    items: [max_actions]Descriptor = undefined,
    len: usize = 0,
    resident_bytes: usize = 0,
    active_id: ?u64 = null,
    active_admitted_ms: u64 = 0,
    active_payload_bytes: usize = 0,
    active_target: TargetIdentity = .{},
    last_terminal_id: u64 = 0,
    closed: bool = false,

    pub fn admit(self: *Queue, descriptor: Descriptor) Admission {
        if (self.closed) return .closed;
        if (descriptor.path_count > max_paths_per_action) return .path_count_limit;
        if (descriptor.path_block_bytes > max_path_block_bytes) return .path_block_limit;
        if (self.len + @intFromBool(self.active_id != null) == max_actions) return .action_limit;
        const next_bytes = std.math.add(usize, self.resident_bytes, descriptor.payload_bytes) catch
            return .payload_limit;
        if (next_bytes > max_payload_bytes) return .payload_limit;
        if (self.active_id == descriptor.id) return .duplicate_id;
        for (self.items[0..self.len]) |item| {
            if (item.id == descriptor.id) return .duplicate_id;
        }
        self.items[self.len] = descriptor;
        self.len += 1;
        self.resident_bytes = next_bytes;
        return .accepted;
    }

    pub fn takeNext(self: *Queue, now_ms: u64) Next {
        if (self.active_id != null) return .busy;
        if (self.len == 0) return .empty;
        const item = self.items[0];
        self.removeHead();
        if (now_ms -| item.admitted_ms >= action_deadline_ms) {
            self.resident_bytes -= item.payload_bytes;
            self.last_terminal_id = item.id;
            return .expired;
        }
        self.active_id = item.id;
        self.active_admitted_ms = item.admitted_ms;
        self.active_payload_bytes = item.payload_bytes;
        self.active_target = item.target;
        return .ready;
    }

    /// Rolls back the most recently admitted descriptor when payload ownership could not be
    /// established. Admission and payload copy run consecutively on AppSession's main thread, so
    /// accepting only the exact tail prevents an allocation failure from removing another action.
    pub fn rollbackTail(self: *Queue, id: u64) bool {
        if (self.len == 0 or self.items[self.len - 1].id != id) return false;
        self.len -= 1;
        self.resident_bytes -= self.items[self.len].payload_bytes;
        return true;
    }

    pub fn finishActive(self: *Queue, id: u64) bool {
        if (self.active_id != id) return false;
        self.active_id = null;
        self.active_admitted_ms = 0;
        self.resident_bytes -= self.active_payload_bytes;
        self.active_payload_bytes = 0;
        self.active_target = .{};
        self.last_terminal_id = id;
        return true;
    }

    pub fn pollActive(self: *Queue, now_ms: u64) Active {
        const id = self.active_id orelse return .idle;
        // Preserve the admission clock separately so execution never restarts the deadline.
        const admitted_ms = self.active_admitted_ms;
        if (now_ms -| admitted_ms < action_deadline_ms) return .pending;
        std.debug.assert(self.finishActive(id));
        return .expired;
    }

    pub fn complete(self: *Queue, id: u64, current_target: TargetIdentity) Completion {
        if (self.active_id != id) return .wrong_action;
        const result: Completion = if (self.closed)
            .closed
        else if (std.meta.eql(self.active_target, current_target))
            .apply
        else
            .stale_target;
        std.debug.assert(self.finishActive(id));
        return result;
    }

    /// Closing cannot synchronously cancel transport work on the GUI thread. Queued payloads are
    /// released now; the active payload remains charged until its late terminal result is drained.
    pub fn close(self: *Queue) void {
        if (self.closed) return;
        self.closed = true;
        self.len = 0;
        self.resident_bytes = self.active_payload_bytes;
    }

    fn removeHead(self: *Queue) void {
        if (self.len > 1) std.mem.copyForwards(Descriptor, self.items[0 .. self.len - 1], self.items[1..self.len]);
        self.len -= 1;
    }
};

// SSH drop/image actions cross a blocking host observation boundary. These tests pin the
// admission and lifetime accounting before async request or AppSession integration exists.
test "user action queue admits exact caps and rejects growth without mutation" {
    var queue: Queue = .{};
    try std.testing.expectEqual(Admission.accepted, queue.admit(.{
        .id = 1,
        .admitted_ms = 10,
        .payload_bytes = max_payload_bytes,
        .path_count = max_paths_per_action,
        .path_block_bytes = max_path_block_bytes,
    }));
    try std.testing.expectEqual(@as(usize, 1), queue.len);
    try std.testing.expectEqual(max_payload_bytes, queue.resident_bytes);

    const before = queue;
    try std.testing.expectEqual(Admission.payload_limit, queue.admit(.{
        .id = 2,
        .admitted_ms = 10,
        .payload_bytes = 1,
    }));
    try std.testing.expectEqualDeep(before, queue);
}

test "user action queue bounds action and file manifests before ownership" {
    var queue: Queue = .{};
    var id: u64 = 1;
    while (id <= max_actions) : (id += 1) {
        try std.testing.expectEqual(Admission.accepted, queue.admit(.{ .id = id, .admitted_ms = 0 }));
    }
    const full = queue;
    try std.testing.expectEqual(Admission.action_limit, queue.admit(.{ .id = 9, .admitted_ms = 0 }));
    try std.testing.expectEqualDeep(full, queue);

    var paths: Queue = .{};
    try std.testing.expectEqual(Admission.path_count_limit, paths.admit(.{
        .id = 1,
        .admitted_ms = 0,
        .path_count = max_paths_per_action + 1,
    }));
    try std.testing.expectEqual(Admission.path_block_limit, paths.admit(.{
        .id = 2,
        .admitted_ms = 0,
        .path_block_bytes = max_path_block_bytes + 1,
    }));
    try std.testing.expectEqual(@as(usize, 0), paths.len);
}

test "payload ownership failure rolls back only the exact admitted tail" {
    var queue: Queue = .{};
    try std.testing.expectEqual(Admission.accepted, queue.admit(.{ .id = 1, .admitted_ms = 0, .payload_bytes = 7 }));
    try std.testing.expectEqual(Admission.accepted, queue.admit(.{ .id = 2, .admitted_ms = 0, .payload_bytes = 9 }));
    try std.testing.expect(!queue.rollbackTail(1));
    try std.testing.expectEqual(@as(usize, 2), queue.len);
    try std.testing.expectEqual(@as(usize, 16), queue.resident_bytes);
    try std.testing.expect(queue.rollbackTail(2));
    try std.testing.expectEqual(@as(usize, 1), queue.len);
    try std.testing.expectEqual(@as(usize, 7), queue.resident_bytes);
}

test "user action deadline starts at admission and expired head never starts probe" {
    var queue: Queue = .{};
    try std.testing.expectEqual(Admission.accepted, queue.admit(.{ .id = 41, .admitted_ms = 100 }));
    try std.testing.expectEqual(Admission.accepted, queue.admit(.{ .id = 42, .admitted_ms = 4_999 }));

    try std.testing.expectEqual(Next.expired, queue.takeNext(5_101));
    try std.testing.expectEqual(@as(u64, 41), queue.last_terminal_id);
    try std.testing.expectEqual(Next.ready, queue.takeNext(5_101));
    try std.testing.expectEqual(@as(u64, 42), queue.active_id.?);
}

test "active action remains charged until exact terminal completion" {
    var queue: Queue = .{};
    try std.testing.expectEqual(Admission.accepted, queue.admit(.{
        .id = 7,
        .admitted_ms = 0,
        .payload_bytes = max_payload_bytes,
    }));
    try std.testing.expectEqual(Next.ready, queue.takeNext(1));
    try std.testing.expectEqual(max_payload_bytes, queue.resident_bytes);
    try std.testing.expectEqual(Admission.payload_limit, queue.admit(.{ .id = 8, .admitted_ms = 1, .payload_bytes = 1 }));
    try std.testing.expect(!queue.finishActive(8));
    try std.testing.expectEqual(max_payload_bytes, queue.resident_bytes);
    try std.testing.expect(queue.finishActive(7));
    try std.testing.expectEqual(@as(usize, 0), queue.resident_bytes);
}

test "active action timeout remains anchored to admission" {
    var queue: Queue = .{};
    try std.testing.expectEqual(Admission.accepted, queue.admit(.{
        .id = 17,
        .admitted_ms = 100,
        .payload_bytes = 7,
    }));
    try std.testing.expectEqual(Next.ready, queue.takeNext(4_000));
    try std.testing.expectEqual(Active.pending, queue.pollActive(5_099));
    try std.testing.expectEqual(Active.expired, queue.pollActive(5_100));
    try std.testing.expectEqual(@as(?u64, null), queue.active_id);
    try std.testing.expectEqual(@as(usize, 0), queue.resident_bytes);
}

test "completion applies only to the exact original target identity" {
    const target = TargetIdentity{
        .surface_id = 3,
        .runtime_handle = 9,
        .host_id = 11,
        .runtime_id = [_]u8{'a'} ** 32,
        .runtime_generation = 4,
    };
    var queue: Queue = .{};
    try std.testing.expectEqual(Admission.accepted, queue.admit(.{
        .id = 1,
        .admitted_ms = 0,
        .target = target,
    }));
    try std.testing.expectEqual(Next.ready, queue.takeNext(1));
    var changed = target;
    changed.runtime_generation += 1;
    try std.testing.expectEqual(Completion.stale_target, queue.complete(1, changed));
    try std.testing.expectEqual(@as(?u64, null), queue.active_id);

    try std.testing.expectEqual(Admission.accepted, queue.admit(.{
        .id = 2,
        .admitted_ms = 2,
        .target = target,
    }));
    try std.testing.expectEqual(Next.ready, queue.takeNext(3));
    try std.testing.expectEqual(Completion.apply, queue.complete(2, target));
}

test "close drops queued ownership and late active result only releases bytes" {
    var queue: Queue = .{};
    try std.testing.expectEqual(Admission.accepted, queue.admit(.{ .id = 1, .admitted_ms = 0, .payload_bytes = 7 }));
    try std.testing.expectEqual(Next.ready, queue.takeNext(1));
    try std.testing.expectEqual(Admission.accepted, queue.admit(.{ .id = 2, .admitted_ms = 1, .payload_bytes = 9 }));
    queue.close();
    try std.testing.expectEqual(@as(usize, 0), queue.len);
    try std.testing.expectEqual(@as(usize, 7), queue.resident_bytes);
    try std.testing.expectEqual(Admission.closed, queue.admit(.{ .id = 3, .admitted_ms = 2 }));
    try std.testing.expectEqual(Completion.closed, queue.complete(1, .{}));
    try std.testing.expectEqual(@as(usize, 0), queue.resident_bytes);
}
