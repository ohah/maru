//! Single-thread daemon poll owner for one listener and at most 32 readiness clients.
//!
//! Kernel fd readiness and synthetic 20 ms producer work enter the same `ReactorCore.nextReady`
//! round-robin selector. One iteration services at most one client turn, so a readable flood,
//! blocked writer, or many attached streams cannot monopolize the host owner.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const connection_slot = @import("connection_slot.zig");
const connection_turn = @import("connection_turn.zig");
const socket_server = @import("socket_server.zig");

pub const max_clients: usize = connection_slot.max_connections;
pub const cadence_ns: u64 = @as(u64, @intCast(socket_server.SocketServer.delta_tick_ms)) *
    std.time.ns_per_ms;

pub const Outcome = enum {
    idle,
    progress,
    listener_broken,
    upgrade_ready,
};

pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *socket_server.SocketServer,
    reactor: *connection_slot.ReactorCore,
    clients: [max_clients]?*connection_turn.Client = [_]?*connection_turn.Client{null} ** max_clients,
    producer_remaining: [max_clients]usize = [_]usize{0} ** max_clients,
    next_cadence_ns: u64,
    next_overflow_accept_ns: u64 = 0,
    armed_upgrade: ?connection_turn.ArmedUpgrade = null,
    total_admitted: usize = 0,
    overflow_rejected: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        server: *socket_server.SocketServer,
    ) error{OutOfMemory}!Owner {
        const reactor = try connection_slot.ReactorCore.create(allocator);
        const now_ns = monotonicNow(io);
        return .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .reactor = reactor,
            .next_cadence_ns = now_ns +| cadence_ns,
        };
    }

    pub fn deinit(self: *Owner) void {
        self.destroyAll();
        self.reactor.destroy();
        self.* = undefined;
    }

    pub fn activeCount(self: *const Owner) usize {
        return self.reactor.activeCount();
    }

    pub fn takeArmedUpgrade(self: *Owner) ?connection_turn.ArmedUpgrade {
        const marker = self.armed_upgrade;
        self.armed_upgrade = null;
        return marker;
    }

    /// Polls the listener and all current clients once. The timeout is capped by the next producer
    /// cadence; pending synthetic work forces a zero-time poll so the cursor sweep finishes without
    /// another 20 ms delay.
    pub fn pollOnce(self: *Owner, outer_timeout_ms: i32) error{OutOfMemory}!Outcome {
        if (self.armed_upgrade != null) return .upgrade_ready;
        const before_poll_ns = monotonicNow(self.io);
        self.scheduleCadence(before_poll_ns);

        var poll_fds: [max_clients + 1]c.pollfd = undefined;
        var poll_slots: [max_clients]?usize = [_]?usize{null} ** max_clients;
        // Once an upgrade closes admission, the listener must leave the readiness set. Accepting
        // and immediately rejecting peers would still consume fd/client budgets while the upgrade
        // reply is draining.
        const gate_open = if (self.server.admission_gate) |gate| gate.snapshot().open else true;
        const admission_open = gate_open and
            (self.reactor.activeCount() < max_clients or
                before_poll_ns >= self.next_overflow_accept_ns);
        poll_fds[0] = .{
            .fd = if (admission_open) self.server.listen_fd else -1,
            .events = if (admission_open) c.POLL.IN else 0,
            .revents = 0,
        };
        var poll_count: usize = 1;
        for (self.clients, 0..) |maybe_client, slot_index| {
            const client = maybe_client orelse continue;
            var events: c_short = c.POLL.IN;
            if (client.wantsWrite()) events |= c.POLL.OUT;
            poll_fds[poll_count] = .{ .fd = client.fd, .events = events, .revents = 0 };
            poll_slots[poll_count - 1] = slot_index;
            poll_count += 1;
        }
        const timeout_ms = self.pollTimeout(before_poll_ns, outer_timeout_ms);
        const rc = c.poll(&poll_fds, @intCast(poll_count), timeout_ms);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) return .idle;
            return .listener_broken;
        }
        const now_ns = monotonicNow(self.io);
        self.scheduleCadence(now_ns);

        var progressed = false;
        if (poll_fds[0].revents & c.POLL.IN != 0) {
            try self.acceptOne(now_ns);
            progressed = true;
        } else if (poll_fds[0].revents != 0) {
            return .listener_broken;
        }

        var ready: [max_clients]bool = [_]bool{false} ** max_clients;
        var read_ready: [max_clients]bool = [_]bool{false} ** max_clients;
        var write_ready: [max_clients]bool = [_]bool{false} ** max_clients;
        var poll_index: usize = 1;
        while (poll_index < poll_count) : (poll_index += 1) {
            const slot_index = poll_slots[poll_index - 1].?;
            const revents = poll_fds[poll_index].revents;
            if (revents & c.POLL.IN != 0) read_ready[slot_index] = true;
            if (revents & c.POLL.OUT != 0) write_ready[slot_index] = true;
            if (revents & (c.POLL.ERR | c.POLL.HUP | c.POLL.NVAL) != 0 and
                !read_ready[slot_index] and !write_ready[slot_index])
                read_ready[slot_index] = true;
            ready[slot_index] = read_ready[slot_index] or
                write_ready[slot_index] or self.producer_remaining[slot_index] != 0;
        }
        // Newly accepted clients are not in this poll snapshot, but cadence work for existing
        // clients must remain schedulable even when no kernel fd was ready.
        for (self.clients, 0..) |maybe_client, slot_index| {
            const client = maybe_client orelse continue;
            if (client.hasBufferedReadWork()) {
                read_ready[slot_index] = true;
                ready[slot_index] = true;
            }
            if (self.producer_remaining[slot_index] != 0) ready[slot_index] = true;
        }

        const admission = self.reactor.nextReady(&ready) orelse
            return if (progressed) .progress else .idle;
        const slot_index = admission.index;
        const client = self.clients[slot_index] orelse return .listener_broken;
        if (read_ready[slot_index]) client.readReady(now_ns);
        if (!client.isClosing() and write_ready[slot_index]) client.writeReady(now_ns);
        if (!client.isClosing() and self.producer_remaining[slot_index] != 0) {
            self.producer_remaining[slot_index] -= 1;
            client.tick(now_ns);
        }
        progressed = true;
        if (client.isClosing()) {
            const marker = client.takeArmedUpgrade();
            self.destroyClient(slot_index);
            if (marker) |armed| {
                self.destroyAll();
                std.debug.assert(self.server.subscriptions.count() == 0);
                std.debug.assert(self.server.registry.attachmentCount() == 0);
                self.armed_upgrade = armed;
                return .upgrade_ready;
            }
        }
        return if (progressed) .progress else .idle;
    }

    fn acceptOne(self: *Owner, now_ns: u64) error{OutOfMemory}!void {
        const fd = self.server.acceptOne() orelse return;
        const client = connection_turn.Client.create(
            self.allocator,
            fd,
            self.reactor,
            self.server.host_id,
            self.server.registry,
            &self.server.subscriptions,
            .{
                .runtime_ops = self.server.runtime_ops,
                .upgrade_ops = self.server.upgrade_ops,
                .admission_gate = self.server.admission_gate,
                .host_status = self.server.host_status,
                .live_host_status = &self.server.host_status,
                .now_ns = now_ns,
            },
        ) catch |err| switch (err) {
            // Admission is a sibling-isolated boundary: allocation pressure rejects only this fd;
            // the owner and every already admitted PTY/client remain live.
            error.Full => {
                self.overflow_rejected += 1;
                self.next_overflow_accept_ns = now_ns +| cadence_ns;
                return;
            },
            error.Exhausted, error.SocketSetupFailed, error.OutOfMemory => return,
        };
        const index = client.admission.index;
        std.debug.assert(self.clients[index] == null);
        self.clients[index] = client;
        self.total_admitted += 1;
    }

    fn destroyClient(self: *Owner, index: usize) void {
        const client = self.clients[index] orelse return;
        self.clients[index] = null;
        self.producer_remaining[index] = 0;
        client.destroy();
    }

    fn destroyAll(self: *Owner) void {
        for (0..max_clients) |index| self.destroyClient(index);
    }

    fn scheduleCadence(self: *Owner, now_ns: u64) void {
        if (now_ns < self.next_cadence_ns) return;
        self.next_cadence_ns = now_ns +| cadence_ns;
        for (self.clients, 0..) |maybe_client, index| {
            const client = maybe_client orelse continue;
            // A large sweep may span the next cadence. Resetting it to the full tracker count on
            // every timer edge would keep it permanently nonzero and revisit the same prefix.
            if (self.producer_remaining[index] == 0)
                self.producer_remaining[index] = client.beginProducerSweep(now_ns);
        }
    }

    fn pollTimeout(self: *const Owner, now_ns: u64, outer_timeout_ms: i32) i32 {
        // Parser-resident complete frames have no corresponding kernel POLLIN edge.
        for (self.clients) |maybe_client|
            if (maybe_client) |client| if (client.hasBufferedReadWork()) return 0;
        for (self.producer_remaining) |remaining| if (remaining != 0) return 0;
        // Preserve the daemon's outer idle/oneshot accounting when no producer exists.
        if (self.reactor.activeCount() == 0) return outer_timeout_ms;
        if (self.reactor.activeCount() == max_clients and now_ns < self.next_overflow_accept_ns) {
            const until_ns = self.next_overflow_accept_ns - now_ns;
            const until_ms = @max(
                @as(u64, 1),
                (until_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms,
            );
            return @min(
                outer_timeout_ms,
                std.math.cast(i32, until_ms) orelse std.math.maxInt(i32),
            );
        }
        if (now_ns >= self.next_cadence_ns) return 0;
        const until_ns = self.next_cadence_ns - now_ns;
        const until_ms = @max(@as(u64, 1), (until_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
        return @min(outer_timeout_ms, std.math.cast(i32, until_ms) orelse std.math.maxInt(i32));
    }
};

fn monotonicNow(io: std.Io) u64 {
    const ns = std.Io.Clock.awake.now(io).nanoseconds;
    return if (ns <= 0) 0 else std.math.cast(u64, ns) orelse std.math.maxInt(u64);
}

const testing = std.testing;
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const upgrade = @import("upgrade_coordinator.zig");
const upgrade_wire = @import("upgrade_wire.zig");

fn connectTestClient(path: [:0]const u8) !c.fd_t {
    const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.TestUnexpectedResult;
    errdefer _ = c.close(fd);
    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0)
        return error.TestUnexpectedResult;
    return fd;
}

fn sendTestRequest(fd: c.fd_t, kind: protocol.Kind, request_id: u64, payload: []const u8) !void {
    const bytes = try framing.encodeFrame(testing.allocator, .{
        .kind = kind,
        .request_id = request_id,
    }, payload);
    defer testing.allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.send(fd, bytes.ptr + offset, bytes.len - offset, 0);
        if (rc <= 0) return error.TestUnexpectedResult;
        offset += @intCast(rc);
    }
}

fn pumpUntilResponse(owner: *Owner, fd: c.fd_t, needle: []const u8) !void {
    var parser = framing.FrameParser.init(testing.allocator);
    defer parser.deinit();
    var buf: [4096]u8 = undefined;
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        _ = try owner.pollOnce(5);
        const rc = c.recv(fd, &buf, buf.len, posix.MSG.DONTWAIT);
        if (rc < 0) {
            if (posix.errno(rc) == .AGAIN) continue;
            return error.TestUnexpectedResult;
        }
        if (rc == 0) return error.TestUnexpectedResult;
        try parser.push(buf[0..@intCast(rc)]);
        while (try parser.next()) |frame| {
            defer frame.deinit(testing.allocator);
            if (std.mem.indexOf(u8, frame.payload, needle) != null) return;
        }
    }
    return error.TestUnexpectedResult;
}

fn pumpResponseCount(owner: *Owner, fd: c.fd_t, first_request_id: u64, expected: usize) !void {
    var parser = framing.FrameParser.init(testing.allocator);
    defer parser.deinit();
    var buf: [16 * 1024]u8 = undefined;
    var count: usize = 0;
    var attempts: usize = 0;
    while (count < expected and attempts < 4000) : (attempts += 1) {
        _ = try owner.pollOnce(2);
        const rc = c.recv(fd, &buf, buf.len, posix.MSG.DONTWAIT);
        if (rc < 0) {
            if (posix.errno(rc) == .AGAIN) continue;
            return error.TestUnexpectedResult;
        }
        if (rc == 0) return error.TestUnexpectedResult;
        try parser.push(buf[0..@intCast(rc)]);
        while (try parser.next()) |frame| {
            defer frame.deinit(testing.allocator);
            if (frame.header.request_id >= first_request_id) count += 1;
        }
    }
    try testing.expectEqual(expected, count);
}

test "poll owner keeps canonical GUI connection while ephemeral inventory completes" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/owner.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xAA,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true };
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();
    const idle_now = monotonicNow(testing.io);
    try testing.expectEqual(@as(i32, 200), owner.pollTimeout(idle_now, 200));

    const gui_fd = try connectTestClient(socket_path);
    defer _ = c.close(gui_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(gui_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, gui_fd, "host_id");
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

    var inventory_fd = try connectTestClient(socket_path);
    defer {
        if (inventory_fd >= 0) _ = c.close(inventory_fd);
    }
    _ = try owner.pollOnce(5);
    try sendTestRequest(inventory_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"cli\"}");
    try pumpUntilResponse(&owner, inventory_fd, "host_id");
    try sendTestRequest(
        inventory_fd,
        .request,
        2,
        "{\"method\":\"runtime.inventory\",\"params\":{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}}",
    );
    try pumpUntilResponse(&owner, inventory_fd, "runtime_ids");
    _ = c.close(inventory_fd);
    inventory_fd = -1;
    var attempts: usize = 0;
    while (owner.activeCount() != 1 and attempts < 100) : (attempts += 1)
        _ = try owner.pollOnce(5);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

    try sendTestRequest(gui_fd, .request, 3, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, gui_fd, "runtime_count");
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const rejected_fd = try connectTestClient(socket_path);
    defer _ = c.close(rejected_fd);
    owner.allocator = failing.allocator();
    _ = try owner.pollOnce(5);
    owner.allocator = testing.allocator;
    var byte: [1]u8 = undefined;
    var rejected_closed = false;
    for (0..100) |_| {
        const rc = c.recv(rejected_fd, &byte, byte.len, posix.MSG.DONTWAIT);
        if (rc == 0) {
            rejected_closed = true;
            break;
        }
        if (rc < 0 and posix.errno(rc) != .AGAIN) return error.TestUnexpectedResult;
        _ = try owner.pollOnce(1);
    }
    try testing.expect(rejected_closed);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());
    try sendTestRequest(gui_fd, .request, 4, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, gui_fd, "runtime_count");
}

test "poll owner drains parser-resident frames past one 64-frame read turn" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/buffered.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xAB,
        &runtime_registry,
    );
    defer server.deinit();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    const fd = try connectTestClient(socket_path);
    defer _ = c.close(fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, fd, "host_id");
    for (0..65) |index|
        try sendTestRequest(fd, .request, 100 + index, "{\"method\":\"host.info\"}");
    // No further client write occurs. The second owner turn must be driven solely by parser state.
    try pumpResponseCount(&owner, fd, 100, 65);
}

test "partial sibling cannot block a ready metadata request" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/partial.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xAC,
        &runtime_registry,
    );
    defer server.deinit();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    const partial_fd = try connectTestClient(socket_path);
    defer _ = c.close(partial_fd);
    _ = try owner.pollOnce(5);
    const one_byte = [_]u8{'M'};
    try testing.expectEqual(@as(isize, 1), c.send(partial_fd, &one_byte, 1, 0));

    const healthy_fd = try connectTestClient(socket_path);
    defer _ = c.close(healthy_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(
        healthy_fd,
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}",
    );
    try pumpUntilResponse(&owner, healthy_fd, "host_id");
    try sendTestRequest(healthy_fd, .request, 2, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, healthy_fd, "runtime_count");
    try testing.expectEqual(@as(usize, 2), owner.activeCount());

    var partial_slot: ?usize = null;
    for (owner.clients, 0..) |maybe_client, index|
        if (maybe_client) |client| if (!client.connection.handshakeComplete()) {
            partial_slot = index;
            break;
        };
    const stale_index = partial_slot orelse return error.TestUnexpectedResult;
    owner.producer_remaining[stale_index] = 3;
    owner.next_cadence_ns = 0;
    const now_ns = monotonicNow(testing.io);
    owner.scheduleCadence(now_ns);
    // Crossing another cadence cannot refill an unfinished epoch.
    try testing.expectEqual(@as(usize, 3), owner.producer_remaining[stale_index]);

    owner.clients[stale_index].?.created_ns = now_ns - connection_turn.handshake_deadline_ns;
    owner.next_cadence_ns = 0;
    var deadline_attempts: usize = 0;
    while (owner.activeCount() != 1 and deadline_attempts < 100) : (deadline_attempts += 1)
        _ = try owner.pollOnce(0);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

    // Reuse the middle admission hole and prove compact pollfd indices still route to the new slot.
    const replacement_fd = try connectTestClient(socket_path);
    defer _ = c.close(replacement_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(
        replacement_fd,
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"cli\"}",
    );
    try pumpUntilResponse(&owner, replacement_fd, "host_id");
    try sendTestRequest(replacement_fd, .request, 2, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, replacement_fd, "runtime_count");

    var occupied_before_slow: [max_clients]bool = undefined;
    for (owner.clients, 0..) |maybe_client, index|
        occupied_before_slow[index] = maybe_client != null;
    const slow_fd = try connectTestClient(socket_path);
    defer _ = c.close(slow_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(
        slow_fd,
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"cli\"}",
    );
    try pumpUntilResponse(&owner, slow_fd, "host_id");
    var slow_slot: ?usize = null;
    for (owner.clients, 0..) |maybe_client, index| {
        if (!occupied_before_slow[index] and maybe_client != null) {
            slow_slot = index;
            break;
        }
    }
    const slow_index = slow_slot orelse return error.TestUnexpectedResult;
    const tiny_send_buffer: c_int = 1024;
    try testing.expectEqual(
        @as(c_int, 0),
        c.setsockopt(
            owner.clients[slow_index].?.fd,
            posix.SOL.SOCKET,
            posix.SO.SNDBUF,
            @ptrCast(&tiny_send_buffer),
            @sizeOf(c_int),
        ),
    );
    var blocked = false;
    var slow_request_id: u64 = 100;
    for (0..32) |_| {
        for (0..64) |_| {
            try sendTestRequest(slow_fd, .request, slow_request_id, "{\"method\":\"host.info\"}");
            slow_request_id += 1;
        }
        for (0..128) |_| _ = try owner.pollOnce(0);
        if (owner.clients[slow_index]) |slow_client| {
            if (slow_client.wantsWrite()) {
                blocked = true;
                break;
            }
        } else break;
    }
    try testing.expect(blocked);

    try sendTestRequest(healthy_fd, .request, 3, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, healthy_fd, "runtime_count");
}

test "poll owner closes cap plus one without disturbing 32 admitted clients" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/cap.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xBB,
        &runtime_registry,
    );
    defer server.deinit();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    var client_fds: [max_clients]c.fd_t = undefined;
    var count: usize = 0;
    defer {
        for (client_fds[0..count]) |fd| _ = c.close(fd);
    }
    while (count < max_clients) : (count += 1) {
        client_fds[count] = try connectTestClient(socket_path);
        var attempts: usize = 0;
        while (owner.activeCount() != count + 1 and attempts < 100) : (attempts += 1)
            _ = try owner.pollOnce(5);
        try testing.expectEqual(count + 1, owner.activeCount());
    }
    const rejected_fd = try connectTestClient(socket_path);
    defer _ = c.close(rejected_fd);
    _ = try owner.pollOnce(5);
    try testing.expectEqual(max_clients, owner.activeCount());
    try testing.expectEqual(@as(usize, 1), owner.overflow_rejected);

    var flood_fds: [8]c.fd_t = undefined;
    var flood_count: usize = 0;
    defer {
        for (flood_fds[0..flood_count]) |fd| _ = c.close(fd);
    }
    while (flood_count < flood_fds.len) : (flood_count += 1)
        flood_fds[flood_count] = try connectTestClient(socket_path);
    const rejected_before_flood = owner.overflow_rejected;
    const flood_start_ns = monotonicNow(testing.io);
    for (0..100) |_| _ = try owner.pollOnce(0);
    const flood_elapsed_ns = monotonicNow(testing.io) - flood_start_ns;
    const max_rejections = flood_elapsed_ns / cadence_ns + 1;
    try testing.expect(
        owner.overflow_rejected - rejected_before_flood <= max_rejections,
    );
    try testing.expectEqual(max_clients, owner.activeCount());

    var byte: [1]u8 = undefined;
    var closed = false;
    var attempts: usize = 0;
    while (!closed and attempts < 100) : (attempts += 1) {
        const rc = c.recv(rejected_fd, &byte, byte.len, posix.MSG.DONTWAIT);
        if (rc == 0) closed = true else if (rc < 0 and posix.errno(rc) != .AGAIN)
            return error.TestUnexpectedResult;
        if (!closed) _ = try owner.pollOnce(1);
    }
    try testing.expect(closed);

    try sendTestRequest(client_fds[0], .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, client_fds[0], "host_id");
    try testing.expectEqual(max_clients, owner.activeCount());
}

const TestUpgradeOwner = struct {
    attempt_id: u128 = 0,
    staged: usize = 0,
    armed: usize = 0,
    canceled: usize = 0,

    fn stage(ctx: *anyopaque, request: upgrade_wire.PrepareRequest) upgrade_wire.PrepareDecision {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.attempt_id = request.attempt_id;
        self.staged += 1;
        return .accepted;
    }
    fn cancel(ctx: *anyopaque, attempt_id: u128) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.attempt_id == attempt_id) self.canceled += 1;
    }
    fn arm(ctx: *anyopaque, attempt_id: u128) upgrade_wire.ArmDecision {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.attempt_id != attempt_id) return .conflict;
        self.armed += 1;
        return .armed;
    }
    fn status(ctx: *anyopaque, attempt_id: u128) ?upgrade_wire.AttemptReport {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.attempt_id != attempt_id) return null;
        return .{ .status = .pending };
    }
    fn ops(self: *@This()) upgrade_wire.Ops {
        return .{
            .ctx = self,
            .stage_pending = stage,
            .cancel_unaccepted = cancel,
            .arm_accepted = arm,
            .status = status,
        };
    }
};

test "poll owner drains every client before publishing typed preclosed upgrade marker" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir_raw = dir_buf[0..dir_len];
    const dir_path = try testing.allocator.dupeZ(u8, dir_raw);
    defer testing.allocator.free(dir_path);
    const socket_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/upgrade.sock",
        .{dir_raw},
        0,
    );
    defer testing.allocator.free(socket_path);
    var runtime_registry = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer runtime_registry.deinit();
    var server = try socket_server.SocketServer.bind(
        testing.allocator,
        dir_path,
        socket_path,
        0xCC,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true, .upgrade_capable = true };
    var gate = upgrade.AdmissionGate.init(testing.io);
    server.admission_gate = &gate;
    var upgrade_owner: TestUpgradeOwner = .{};
    server.upgrade_ops = upgrade_owner.ops();
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    const upgrade_fd = try connectTestClient(socket_path);
    defer _ = c.close(upgrade_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(upgrade_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, upgrade_fd, "host_id");
    const sibling_fd = try connectTestClient(socket_path);
    defer _ = c.close(sibling_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(sibling_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"cli\"}");
    try pumpUntilResponse(&owner, sibling_fd, "host_id");
    try testing.expectEqual(@as(usize, 2), owner.activeCount());

    try sendTestRequest(
        upgrade_fd,
        .request,
        2,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000aabb\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    // The prepare dispatch closes admission before its accepted reply is fully drained. A peer
    // arriving in that window must remain in the listener backlog, not become a host client.
    var gate_attempts: usize = 0;
    while (gate.snapshot().open and gate_attempts < 100) : (gate_attempts += 1)
        _ = try owner.pollOnce(1);
    try testing.expect(!gate.snapshot().open);
    const late_fd = try connectTestClient(socket_path);
    defer _ = c.close(late_fd);
    const admitted_before_close = owner.total_admitted;
    for (0..5) |_| _ = try owner.pollOnce(1);
    try testing.expectEqual(admitted_before_close, owner.total_admitted);

    var outcome: Outcome = .idle;
    var attempts: usize = 0;
    while (outcome != .upgrade_ready and attempts < 1000) : (attempts += 1)
        outcome = try owner.pollOnce(5);
    try testing.expectEqual(Outcome.upgrade_ready, outcome);
    try testing.expectEqual(@as(usize, 0), owner.activeCount());
    try testing.expectEqual(@as(usize, 0), server.subscriptions.count());
    try testing.expectEqual(@as(usize, 1), upgrade_owner.staged);
    try testing.expectEqual(@as(usize, 1), upgrade_owner.armed);
    try testing.expectEqual(@as(usize, 0), upgrade_owner.canceled);
    try testing.expect(!gate.snapshot().open);
    const marker = owner.takeArmedUpgrade().?;
    try testing.expectEqual(@as(u128, 0xAABB), marker.attempt_id);
    try testing.expect(marker.gate_preclosed);
    try testing.expect(owner.takeArmedUpgrade() == null);
}
