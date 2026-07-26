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
const server_mod = @import("server.zig");
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
    accept_retry_after_ns: u64 = 0,
    admin_admission: server_mod.AdminAdmission = .{},
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

    fn syncClientCount(self: *Owner) void {
        self.server.host_status.client_count = self.activeCount();
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
        const admission_open = acceptAllowed(
            gate_open,
            self.reactor.activeCount(),
            before_poll_ns,
            self.accept_retry_after_ns,
            self.next_overflow_accept_ns,
        );
        poll_fds[0] = .{
            .fd = if (admission_open) self.server.listen_fd else -1,
            .events = if (admission_open) c.POLL.IN else 0,
            .revents = 0,
        };
        var poll_count: usize = 1;
        for (self.clients, 0..) |maybe_client, slot_index| {
            const client = maybe_client orelse continue;
            if (!gate_open and !client.isUpgradeDraining()) continue;
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
        var peer_broken: [max_clients]bool = [_]bool{false} ** max_clients;
        var poll_index: usize = 1;
        while (poll_index < poll_count) : (poll_index += 1) {
            const slot_index = poll_slots[poll_index - 1].?;
            const revents = poll_fds[poll_index].revents;
            if (revents & c.POLL.IN != 0) read_ready[slot_index] = true;
            if (revents & c.POLL.OUT != 0) write_ready[slot_index] = true;
            peer_broken[slot_index] =
                revents & (c.POLL.ERR | c.POLL.HUP | c.POLL.NVAL) != 0;
            if (peer_broken[slot_index] and
                self.clients[slot_index].?.wantsWrite())
                write_ready[slot_index] = true;
            if (peer_broken[slot_index] and
                !read_ready[slot_index] and !write_ready[slot_index])
                read_ready[slot_index] = true;
            ready[slot_index] = read_ready[slot_index] or
                write_ready[slot_index] or self.producer_remaining[slot_index] != 0;
        }
        // Newly accepted clients are not in this poll snapshot, but cadence work for existing
        // clients must remain schedulable even when no kernel fd was ready.
        for (self.clients, 0..) |maybe_client, slot_index| {
            const client = maybe_client orelse continue;
            if (!gate_open and !client.isUpgradeDraining()) continue;
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
        if (!client.isClosing() and peer_broken[slot_index] and !client.wantsWrite())
            client.peerBroken();
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
                if (!self.upgradeTeardownDrained()) return .listener_broken;
                self.armed_upgrade = armed;
                return .upgrade_ready;
            }
        }
        return if (progressed) .progress else .idle;
    }

    fn acceptOne(self: *Owner, now_ns: u64) error{OutOfMemory}!void {
        const fd = switch (self.server.acceptOneResult()) {
            .accepted => |fd| fd,
            .fd_exhausted => {
                self.accept_retry_after_ns = now_ns +| cadence_ns;
                return;
            },
            .would_block, .denied, .failed => return,
        };
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
                .admin_admission = &self.admin_admission,
                .upgrade_preflight = .{
                    .ctx = self,
                    .check = upgradePreflight,
                },
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
        self.syncClientCount();
    }

    fn destroyClient(self: *Owner, index: usize) void {
        const client = self.clients[index] orelse return;
        self.clients[index] = null;
        self.producer_remaining[index] = 0;
        client.destroy();
        self.syncClientCount();
    }

    fn destroyAll(self: *Owner) void {
        for (0..max_clients) |index| self.destroyClient(index);
    }

    fn upgradeTeardownDrained(self: *const Owner) bool {
        if (!self.reactor.drainedForUpgrade() or
            self.server.subscriptions.count() != 0 or
            self.server.registry.attachmentCount() != 0 or
            self.admin_admission.active) return false;
        for (self.clients, self.producer_remaining) |maybe_client, remaining|
            if (maybe_client != null or remaining != 0) return false;
        return true;
    }

    fn scheduleCadence(self: *Owner, now_ns: u64) void {
        if (now_ns < self.next_cadence_ns) return;
        self.next_cadence_ns = now_ns +| cadence_ns;
        const gate_open = if (self.server.admission_gate) |gate| gate.snapshot().open else true;
        for (self.clients, 0..) |maybe_client, index| {
            const client = maybe_client orelse continue;
            if (!gate_open and !client.isUpgradeDraining()) continue;
            // A large sweep may span the next cadence. Resetting it to the full tracker count on
            // every timer edge would keep it permanently nonzero and revisit the same prefix.
            if (self.producer_remaining[index] == 0)
                self.producer_remaining[index] = client.beginProducerSweep(now_ns);
        }
    }

    fn upgradePreflight(ctx: *anyopaque, requester: *connection_turn.Client) bool {
        const self: *Owner = @ptrCast(@alignCast(ctx));
        if (self.server.subscriptions.count() != 0 or
            self.server.registry.attachmentCount() != 0) return false;
        var requester_membership: usize = 0;
        for (self.clients) |maybe_client| {
            const client = maybe_client orelse continue;
            if (client == requester) {
                requester_membership += 1;
                if (!client.requesterReadyForUpgrade() or
                    !client.socketQuiescentForUpgrade()) return false;
                continue;
            }
            if (!client.idleForUpgrade() or
                !client.socketQuiescentForUpgrade()) return false;
        }
        return requester_membership == 1;
    }

    fn pollTimeout(self: *const Owner, now_ns: u64, outer_timeout_ms: i32) i32 {
        const gate_open = if (self.server.admission_gate) |gate| gate.snapshot().open else true;
        // Parser-resident complete frames have no corresponding kernel POLLIN edge.
        for (self.clients) |maybe_client|
            if (maybe_client) |client|
                if ((gate_open or client.isUpgradeDraining()) and client.hasBufferedReadWork())
                    return 0;
        for (self.clients, self.producer_remaining) |maybe_client, remaining| {
            const client = maybe_client orelse continue;
            if ((gate_open or client.isUpgradeDraining()) and remaining != 0) return 0;
        }
        var timeout_ms = outer_timeout_ms;
        if (now_ns < self.accept_retry_after_ns)
            timeout_ms = capTimeoutAt(now_ns, self.accept_retry_after_ns, timeout_ms);
        // Preserve the daemon's outer idle/oneshot accounting when no producer exists.
        if (self.reactor.activeCount() == 0) return timeout_ms;
        if (self.reactor.activeCount() == max_clients and now_ns < self.next_overflow_accept_ns) {
            timeout_ms = capTimeoutAt(now_ns, self.next_overflow_accept_ns, timeout_ms);
        }
        if (now_ns >= self.next_cadence_ns) return 0;
        const until_ns = self.next_cadence_ns - now_ns;
        const until_ms = @max(@as(u64, 1), (until_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
        return @min(timeout_ms, std.math.cast(i32, until_ms) orelse std.math.maxInt(i32));
    }
};

fn capTimeoutAt(now_ns: u64, deadline_ns: u64, outer_timeout_ms: i32) i32 {
    if (now_ns >= deadline_ns) return 0;
    const until_ns = deadline_ns - now_ns;
    const until_ms = @max(
        @as(u64, 1),
        (until_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms,
    );
    return @min(
        outer_timeout_ms,
        std.math.cast(i32, until_ms) orelse std.math.maxInt(i32),
    );
}

fn acceptAllowed(
    gate_open: bool,
    active_count: usize,
    now_ns: u64,
    retry_after_ns: u64,
    overflow_after_ns: u64,
) bool {
    return gate_open and now_ns >= retry_after_ns and
        (active_count < max_clients or now_ns >= overflow_after_ns);
}

fn monotonicNow(io: std.Io) u64 {
    const ns = std.Io.Clock.awake.now(io).nanoseconds;
    return if (ns <= 0) 0 else std.math.cast(u64, ns) orelse std.math.maxInt(u64);
}

test "poll owner: fd-pressure retry deadline caps an otherwise idle outer poll" {
    try std.testing.expectEqual(@as(i32, 20), capTimeoutAt(100, 20 * std.time.ns_per_ms, 1_000));
    try std.testing.expectEqual(@as(i32, 0), capTimeoutAt(20 * std.time.ns_per_ms, 20 * std.time.ns_per_ms, 1_000));
    const retry_capped = capTimeoutAt(0, 20 * std.time.ns_per_ms, 1_000);
    const cadence_capped = capTimeoutAt(0, 1 * std.time.ns_per_ms, retry_capped);
    try std.testing.expectEqual(@as(i32, 1), cadence_capped);
    try std.testing.expect(!acceptAllowed(true, 0, 10, 20, 0));
    try std.testing.expect(acceptAllowed(true, 0, 20, 20, 0));
    try std.testing.expect(!acceptAllowed(true, max_clients, 20, 20, 21));
    try std.testing.expect(!acceptAllowed(false, 0, 20, 20, 0));
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

fn pumpUntilClosed(owner: *Owner, fd: c.fd_t) !void {
    var byte: [1]u8 = undefined;
    for (0..1000) |_| {
        _ = try owner.pollOnce(2);
        const rc = c.recv(fd, &byte, byte.len, posix.MSG.DONTWAIT);
        if (rc == 0) return;
        if (rc < 0 and posix.errno(rc) != .AGAIN) return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
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

test "poll owner admits one one-shot admin without displacing canonical GUI" {
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
        "{s}/admin.sock",
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
        0xAD,
        &runtime_registry,
    );
    defer server.deinit();
    server.host_status = .{ .manifest_capable = true };
    var owner = try Owner.init(testing.allocator, testing.io, &server);
    defer owner.deinit();

    const gui_fd = try connectTestClient(socket_path);
    defer _ = c.close(gui_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(gui_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, gui_fd, "host_id");

    const first_admin_fd = try connectTestClient(socket_path);
    defer _ = c.close(first_admin_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(first_admin_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, first_admin_fd, "host_id");
    try testing.expect(owner.admin_admission.active);

    const second_admin_fd = try connectTestClient(socket_path);
    defer _ = c.close(second_admin_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(second_admin_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, second_admin_fd, "resource_exhausted");
    try pumpUntilClosed(&owner, second_admin_fd);
    try testing.expect(owner.admin_admission.active);

    try sendTestRequest(first_admin_fd, .request, 2, "{\"method\":\"runtime.list\",\"params\":{}}");
    try pumpUntilResponse(&owner, first_admin_fd, "runtimes");
    try pumpUntilClosed(&owner, first_admin_fd);
    try testing.expect(!owner.admin_admission.active);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

    try sendTestRequest(gui_fd, .request, 2, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, gui_fd, "runtime_count");
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

    const replacement_admin_fd = try connectTestClient(socket_path);
    defer _ = c.close(replacement_admin_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(replacement_admin_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, replacement_admin_fd, "host_id");
    try sendTestRequest(replacement_admin_fd, .request, 2, "{\"method\":\"runtime.terminate\",\"params\":{\"runtime_id\":\"1\"}}");
    try pumpUntilResponse(&owner, replacement_admin_fd, "unauthorized");
    try pumpUntilClosed(&owner, replacement_admin_fd);
    try testing.expect(!owner.admin_admission.active);

    try sendTestRequest(gui_fd, .request, 3, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, gui_fd, "runtime_count");

    const idle_admin_fd = try connectTestClient(socket_path);
    defer _ = c.close(idle_admin_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(idle_admin_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, idle_admin_fd, "host_id");
    const now_ns = monotonicNow(testing.io);
    for (owner.clients) |maybe_client| {
        const client = maybe_client orelse continue;
        if (client.connection.isAdmin())
            client.tick(now_ns +| connection_turn.admin_request_deadline_ns);
    }
    owner.next_cadence_ns = 0;
    try pumpUntilClosed(&owner, idle_admin_fd);
    try testing.expect(!owner.admin_admission.active);
    try sendTestRequest(gui_fd, .request, 4, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, gui_fd, "runtime_count");

    const eof_admin_fd = try connectTestClient(socket_path);
    _ = try owner.pollOnce(5);
    try sendTestRequest(eof_admin_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, eof_admin_fd, "host_id");
    _ = c.close(eof_admin_fd);
    var eof_attempts: usize = 0;
    while (owner.activeCount() != 1 and eof_attempts < 1000) : (eof_attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());
    try testing.expect(!owner.admin_admission.active);

    const half_close_fd = try connectTestClient(socket_path);
    defer _ = c.close(half_close_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(half_close_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, half_close_fd, "host_id");
    try sendTestRequest(half_close_fd, .request, 2, "{\"method\":\"runtime.list\",\"params\":{}}");
    try testing.expectEqual(@as(c_int, 0), c.shutdown(half_close_fd, c.SHUT.WR));
    try pumpUntilResponse(&owner, half_close_fd, "runtimes");
    try pumpUntilClosed(&owner, half_close_fd);
    try testing.expect(!owner.admin_admission.active);

    const peer_close_fd = try connectTestClient(socket_path);
    _ = try owner.pollOnce(5);
    try sendTestRequest(peer_close_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}");
    try pumpUntilResponse(&owner, peer_close_fd, "host_id");
    try sendTestRequest(peer_close_fd, .request, 2, "{\"method\":\"runtime.list\",\"params\":{}}");
    _ = c.close(peer_close_fd);
    var close_attempts: usize = 0;
    while (owner.activeCount() != 1 and close_attempts < 1000) : (close_attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());
    try testing.expect(!owner.admin_admission.active);
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
    reject_next: bool = false,

    fn stage(ctx: *anyopaque, request: upgrade_wire.PrepareRequest) upgrade_wire.PrepareDecision {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.reject_next) {
            self.reject_next = false;
            return .busy;
        }
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
    var fake_runtime: server_mod.FakeRuntimeOps = .{};
    server.runtime_ops = fake_runtime.ops();
    _ = try runtime_registry.register(0xAA, 80, 24);
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

    const partial = [_]u8{'M'};
    try testing.expectEqual(@as(isize, 1), c.send(sibling_fd, &partial, partial.len, 0));
    for (0..4) |_| _ = try owner.pollOnce(1);
    try sendTestRequest(
        upgrade_fd,
        .request,
        20,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000aa01\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    try pumpUntilResponse(&owner, upgrade_fd, "upgrade_busy");
    try testing.expectEqual(@as(usize, 0), upgrade_owner.staged);
    try testing.expect(gate.snapshot().open);
    try testing.expectEqual(@as(usize, 2), owner.activeCount());
    _ = c.shutdown(sibling_fd, c.SHUT.RDWR);
    var sibling_close_attempts: usize = 0;
    while (owner.activeCount() != 1 and sibling_close_attempts < 1000) : (sibling_close_attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());
    try sendTestRequest(upgrade_fd, .request, 21, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, upgrade_fd, "runtime_count");

    const pipelined_prepare = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .request, .request_id = 30 },
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000aa02\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    defer testing.allocator.free(pipelined_prepare);
    const pipelined_info = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .request, .request_id = 31 },
        "{\"method\":\"host.info\"}",
    );
    defer testing.allocator.free(pipelined_info);
    const pipelined = try testing.allocator.alloc(
        u8,
        pipelined_prepare.len + pipelined_info.len,
    );
    defer testing.allocator.free(pipelined);
    @memcpy(pipelined[0..pipelined_prepare.len], pipelined_prepare);
    @memcpy(pipelined[pipelined_prepare.len..], pipelined_info);
    var pipeline_offset: usize = 0;
    while (pipeline_offset < pipelined.len) {
        const rc = c.send(
            upgrade_fd,
            pipelined.ptr + pipeline_offset,
            pipelined.len - pipeline_offset,
            0,
        );
        if (rc <= 0) return error.TestUnexpectedResult;
        pipeline_offset += @intCast(rc);
    }
    try pumpResponseCount(&owner, upgrade_fd, 30, 2);
    try testing.expectEqual(@as(usize, 0), upgrade_owner.staged);
    try testing.expect(gate.snapshot().open);

    var requester: ?*connection_turn.Client = null;
    for (owner.clients) |maybe_client| {
        if (maybe_client) |client| requester = client;
    }
    const queued_fd = try connectTestClient(socket_path);
    defer _ = c.close(queued_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(queued_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"cli\"}");
    try pumpUntilResponse(&owner, queued_fd, "host_id");
    var queued: ?*connection_turn.Client = null;
    for (owner.clients) |maybe_client| {
        const client = maybe_client orelse continue;
        if (client != requester.?) queued = client;
    }
    // A real prepare dispatch must close admission before peeking the sibling kernel queue, reject
    // the upgrade, reopen admission, and leave the sibling request untouched.
    try sendTestRequest(queued_fd, .request, 2, "{\"method\":\"host.info\"}");
    try sendTestRequest(
        upgrade_fd,
        .request,
        32,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000aa03\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    try pumpUntilResponse(&owner, upgrade_fd, "upgrade_busy");
    try testing.expectEqual(@as(usize, 0), upgrade_owner.staged);
    try testing.expect(gate.snapshot().open);
    try pumpUntilResponse(&owner, queued_fd, "runtime_count");

    const requester_slot = try owner.reactor.get(requester.?.admission);
    upgrade_owner.reject_next = true;
    try sendTestRequest(
        upgrade_fd,
        .request,
        33,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000aa04\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    try pumpUntilResponse(&owner, upgrade_fd, "upgrade_busy");
    try testing.expectEqual(@as(usize, 0), upgrade_owner.staged);
    try testing.expect(gate.snapshot().open);
    try sendTestRequest(queued_fd, .request, 3, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, queued_fd, "runtime_count");

    try sendTestRequest(
        queued_fd,
        .request,
        4,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    try pumpUntilResponse(&owner, queued_fd, "\"observe\":true");
    try testing.expectEqual(@as(usize, 1), server.registry.attachmentCount());
    try testing.expectEqual(@as(usize, 1), server.subscriptions.count());
    try sendTestRequest(
        upgrade_fd,
        .request,
        34,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000aa05\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    try pumpUntilResponse(&owner, upgrade_fd, "upgrade_busy");
    try testing.expectEqual(@as(usize, 0), upgrade_owner.staged);
    try testing.expect(gate.snapshot().open);

    const queued_bytes = try testing.allocator.dupe(u8, "queued-reply");
    try (try owner.reactor.get(queued.?.admission)).enqueueOwnedControl(queued_bytes);
    try requester_slot.beginDispatch();
    try testing.expect(!Owner.upgradePreflight(&owner, requester.?));
    try requester_slot.endDispatch();
    _ = c.shutdown(queued_fd, c.SHUT.RDWR);
    var queued_close_attempts: usize = 0;
    while (owner.activeCount() != 1 and queued_close_attempts < 1000) : (queued_close_attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());

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

test "failed accepted upgrade reopens admission and preserves frozen sibling input" {
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
        "{s}/upgrade-rollback.sock",
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
        0xCD,
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

    var requester_fd = try connectTestClient(socket_path);
    defer {
        if (requester_fd >= 0) _ = c.close(requester_fd);
    }
    _ = try owner.pollOnce(5);
    try sendTestRequest(requester_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, requester_fd, "host_id");
    const sibling_fd = try connectTestClient(socket_path);
    defer _ = c.close(sibling_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(sibling_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"cli\"}");
    try pumpUntilResponse(&owner, sibling_fd, "host_id");

    var requester: ?*connection_turn.Client = null;
    for (owner.clients) |maybe_client| {
        const client = maybe_client orelse continue;
        if (requester == null) requester = client;
    }
    var filler: [64 * 1024]u8 = [_]u8{0xA5} ** (64 * 1024);
    while (true) {
        const rc = c.send(requester.?.fd, &filler, filler.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) break;
        if (rc <= 0) return error.TestUnexpectedResult;
    }
    try sendTestRequest(
        requester_fd,
        .request,
        2,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000bbcc\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    var stage_attempts: usize = 0;
    while (upgrade_owner.staged == 0 and stage_attempts < 100) : (stage_attempts += 1)
        _ = try owner.pollOnce(1);
    try testing.expectEqual(@as(usize, 1), upgrade_owner.staged);
    try testing.expect(!gate.snapshot().open);

    var sibling_index: ?usize = null;
    for (owner.clients, 0..) |maybe_client, index| {
        const client = maybe_client orelse continue;
        if (client != requester.?) sibling_index = index;
    }
    owner.producer_remaining[sibling_index.?] = 3;
    try sendTestRequest(sibling_fd, .request, 2, "{\"method\":\"host.info\"}");
    for (0..5) |_| _ = try owner.pollOnce(1);
    try testing.expectEqual(@as(usize, 3), owner.producer_remaining[sibling_index.?]);
    _ = c.close(requester_fd);
    requester_fd = -1;
    var rollback_attempts: usize = 0;
    while ((!gate.snapshot().open or owner.activeCount() != 1) and
        rollback_attempts < 1000) : (rollback_attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expect(gate.snapshot().open);
    try testing.expectEqual(@as(usize, 1), owner.activeCount());
    try testing.expectEqual(@as(usize, 1), upgrade_owner.canceled);
    try testing.expectEqual(@as(usize, 0), upgrade_owner.armed);
    try testing.expect(owner.takeArmedUpgrade() == null);
    try pumpUntilResponse(&owner, sibling_fd, "runtime_count");
    try testing.expect(owner.producer_remaining[sibling_index.?] < 3);

    const admission_fail_fd = try connectTestClient(socket_path);
    defer _ = c.close(admission_fail_fd);
    _ = try owner.pollOnce(5);
    try sendTestRequest(admission_fail_fd, .hello, 1, "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}");
    try pumpUntilResponse(&owner, admission_fail_fd, "host_id");
    var admission_fail_client: ?*connection_turn.Client = null;
    for (owner.clients) |maybe_client| {
        const client = maybe_client orelse continue;
        if (client.admission.index != sibling_index.?) admission_fail_client = client;
    }
    admission_fail_client.?.control_admission_fail_once = true;
    try sendTestRequest(
        admission_fail_fd,
        .request,
        2,
        "{\"method\":\"host.upgrade.prepare\",\"params\":{\"attempt_id\":\"0000000000000000000000000000bbdd\",\"target_path\":\"/Applications/Maru.app/Contents/MacOS/maru\",\"target_build_id\":\"sha256:build\",\"target_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"handoff_reader_min\":1,\"handoff_reader_max\":1}}",
    );
    var admission_fail_attempts: usize = 0;
    while ((owner.activeCount() != 1 or upgrade_owner.canceled != 2) and
        admission_fail_attempts < 1000) : (admission_fail_attempts += 1)
        _ = try owner.pollOnce(2);
    try testing.expect(gate.snapshot().open);
    try testing.expectEqual(@as(usize, 2), upgrade_owner.staged);
    try testing.expectEqual(@as(usize, 2), upgrade_owner.canceled);
    try testing.expectEqual(@as(usize, 0), upgrade_owner.armed);
    try testing.expect(owner.takeArmedUpgrade() == null);
    try sendTestRequest(sibling_fd, .request, 3, "{\"method\":\"host.info\"}");
    try pumpUntilResponse(&owner, sibling_fd, "runtime_count");
}
