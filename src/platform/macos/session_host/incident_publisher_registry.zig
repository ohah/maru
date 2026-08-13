//! CR0b incident publisher의 process-global final-address registry.
//!
//! 이 owner는 runtime 구현을 import하거나 service를 호출하지 않는다. process adapter가 scalar projection을
//! 등록하고 poison operation은 exact lease로 backing 수명만 pin한다.

const std = @import("std");
const process_seal = @import("process_seal_service.zig");

const PublisherTestChannel = if (@import("builtin").is_test) struct {
    extern var maru_cr0b_publisher_child_path: [1024]u8;
    extern var maru_cr0b_publisher_child_path_len: usize;
} else struct {};

pub const Error = error{ InvalidOwner, Busy, Closing };
pub const Lifecycle = enum(u8) { pristine = 0, ready = 1, closing = 2, detached = 3 };
const max_active_leases: usize = 64;

const ActiveLease = struct {
    lease_addr: u64 = 0,
    lease_generation: u64 = 0,
};

pub const RuntimeProjection = struct {
    runtime_addr: u64,
    runtime_generation: u64,
    service_addr: u64,
    service_generation: u64,
    service_process_nonce: u64,
    app_instance_nonce: u128,
};

pub const IncidentPublisherAuthority = struct {
    self_addr: u64 = 0,
    registry_addr: u64 = 0,
    registry_generation: u64 = 0,
    runtime_addr: u64 = 0,
    runtime_generation: u64 = 0,
    service_addr: u64 = 0,
    service_generation: u64 = 0,
    pid: u32 = 0,
    client_process_nonce: u64 = 0,
    service_process_nonce: u64 = 0,
    owner_thread: u64 = 0,
    app_instance_nonce: u128 = 0,
    lifecycle_raw: u8 = 0,
    seal: [32]u8 = [_]u8{0} ** 32,
};

pub const IncidentPublisherLease = struct {
    self_addr: u64 = 0,
    registry_addr: u64 = 0,
    registry_generation: u64 = 0,
    authority_addr: u64 = 0,
    runtime_addr: u64 = 0,
    runtime_generation: u64 = 0,
    service_addr: u64 = 0,
    service_generation: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread: u64 = 0,
    lease_generation: u64 = 0,
    consumed_raw: u8 = 0,
    seal: [32]u8 = [_]u8{0} ** 32,
};

pub const Registry = struct {
    mutex: std.atomic.Mutex = .unlocked,
    self_addr: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread: u64 = 0,
    next_registry_generation: u64 = 1,
    next_lease_generation: u64 = 1,
    active_lease_count: u64 = 0,
    active_leases: [max_active_leases]ActiveLease = [_]ActiveLease{.{}} ** max_active_leases,
    lifecycle_raw: u8 = 0,
    authority: IncidentPublisherAuthority = .{},

    pub fn initInPlace(self: *Registry, process_nonce: u64) Error!void {
        const pid = process_seal.currentProcessId();
        if (!std.meta.eql(self.*, Registry{}) or pid == 0 or process_nonce == 0) return error.InvalidOwner;
        process_seal.validateReady(pid, process_nonce) catch return error.InvalidOwner;
        self.self_addr = @intFromPtr(self);
        self.pid = pid;
        self.process_nonce = process_nonce;
        self.owner_thread = @intCast(std.Thread.getCurrentId());
    }

    pub fn install(self: *Registry, projection: RuntimeProjection) Error!void {
        try self.validateBeforeLock();
        if (!validProjection(projection)) return error.InvalidOwner;
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (!self.validOwner()) return error.InvalidOwner;
        if (self.lifecycle_raw == @intFromEnum(Lifecycle.ready)) {
            if (projectionMatches(self.authority, projection)) return;
            return error.Busy;
        }
        if (self.lifecycle_raw != @intFromEnum(Lifecycle.pristine)) return error.Closing;
        const generation = self.next_registry_generation;
        if (generation == 0 or generation == std.math.maxInt(u64))
            process_seal.fatalIntegrity(.counter_exhausted);
        var authority: IncidentPublisherAuthority = .{
            .self_addr = @intFromPtr(&self.authority),
            .registry_addr = self.self_addr,
            .registry_generation = generation,
            .runtime_addr = projection.runtime_addr,
            .runtime_generation = projection.runtime_generation,
            .service_addr = projection.service_addr,
            .service_generation = projection.service_generation,
            .pid = self.pid,
            .client_process_nonce = self.process_nonce,
            .service_process_nonce = projection.service_process_nonce,
            .owner_thread = self.owner_thread,
            .app_instance_nonce = projection.app_instance_nonce,
            .lifecycle_raw = @intFromEnum(Lifecycle.ready),
        };
        authority.seal = process_seal.incidentPublisherAuthoritySeal(self.pid, self.process_nonce, authoritySealInput(authority)) catch
            return error.InvalidOwner;
        self.authority = authority;
        self.next_registry_generation = generation + 1;
        self.lifecycle_raw = @intFromEnum(Lifecycle.ready);
    }

    pub fn acquire(self: *Registry, out: *IncidentPublisherLease) Error!void {
        try self.validateBeforeLock();
        if (objectsOverlap(out, self) or !std.meta.eql(out.*, IncidentPublisherLease{})) return error.InvalidOwner;
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (!self.validOwner() or !self.validAuthority()) return error.InvalidOwner;
        if (self.lifecycle_raw != @intFromEnum(Lifecycle.ready)) return error.Closing;
        const generation = self.next_lease_generation;
        if (generation == 0 or generation == std.math.maxInt(u64))
            process_seal.fatalIntegrity(.counter_exhausted);
        var active_slot: ?*ActiveLease = null;
        for (&self.active_leases) |*row| {
            if (row.lease_addr == @intFromPtr(out)) return error.Busy;
            if (row.lease_generation == 0 and active_slot == null) active_slot = row;
        }
        const publish_slot = active_slot orelse return error.Busy;
        var candidate: IncidentPublisherLease = .{
            .self_addr = @intFromPtr(out),
            .registry_addr = self.self_addr,
            .registry_generation = self.authority.registry_generation,
            .authority_addr = @intFromPtr(&self.authority),
            .runtime_addr = self.authority.runtime_addr,
            .runtime_generation = self.authority.runtime_generation,
            .service_addr = self.authority.service_addr,
            .service_generation = self.authority.service_generation,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
            .owner_thread = self.owner_thread,
            .lease_generation = generation,
        };
        candidate.seal = process_seal.incidentPublisherLeaseSeal(self.pid, self.process_nonce, leaseSealInput(candidate)) catch
            return error.InvalidOwner;
        self.next_lease_generation = generation + 1;
        publish_slot.* = .{ .lease_addr = @intFromPtr(out), .lease_generation = generation };
        self.active_lease_count += 1;
        out.* = candidate;
    }

    pub fn release(self: *Registry, lease: *IncidentPublisherLease) Error!void {
        try self.validateBeforeLock();
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (!self.validOwner() or !validLease(self, lease) or self.active_lease_count == 0)
            return error.InvalidOwner;
        const active_slot = findActiveLease(self, lease.*) orelse return error.InvalidOwner;
        var consumed = lease.*;
        consumed.consumed_raw = 1;
        consumed.seal = process_seal.incidentPublisherLeaseSeal(self.pid, self.process_nonce, leaseSealInput(consumed)) catch
            return error.InvalidOwner;
        active_slot.* = .{};
        self.active_lease_count -= 1;
        lease.* = consumed;
    }

    pub fn beginClosing(self: *Registry) Error!bool {
        try self.validateBeforeLock();
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (!self.validOwner() or !self.validAuthority()) return error.InvalidOwner;
        if (self.lifecycle_raw == @intFromEnum(Lifecycle.closing)) return self.active_lease_count == 0;
        if (self.lifecycle_raw != @intFromEnum(Lifecycle.ready)) return error.InvalidOwner;
        var closing_authority = self.authority;
        closing_authority.lifecycle_raw = @intFromEnum(Lifecycle.closing);
        closing_authority.seal = process_seal.incidentPublisherAuthoritySeal(
            self.pid,
            self.process_nonce,
            authoritySealInput(closing_authority),
        ) catch return error.InvalidOwner;
        self.authority = closing_authority;
        self.lifecycle_raw = @intFromEnum(Lifecycle.closing);
        return self.active_lease_count == 0;
    }

    fn validateBeforeLock(self: *const Registry) Error!void {
        const pid = process_seal.currentProcessId();
        if (pid == 0 or pid != self.pid or @intFromPtr(self) != self.self_addr or
            @as(u64, @intCast(std.Thread.getCurrentId())) != self.owner_thread)
            return error.InvalidOwner;
    }

    fn validOwner(self: *const Registry) bool {
        return self.self_addr == @intFromPtr(self) and self.pid == process_seal.currentProcessId() and
            self.process_nonce != 0 and self.owner_thread == @as(u64, @intCast(std.Thread.getCurrentId()));
    }

    fn validAuthority(self: *const Registry) bool {
        const authority = self.authority;
        if (authority.self_addr != @intFromPtr(&self.authority) or authority.registry_addr != self.self_addr or
            authority.pid != self.pid or authority.client_process_nonce != self.process_nonce or
            authority.owner_thread != self.owner_thread) return false;
        const expected = process_seal.incidentPublisherAuthoritySeal(
            self.pid,
            self.process_nonce,
            authoritySealInput(authority),
        ) catch return false;
        return std.mem.eql(u8, &expected, &authority.seal);
    }
};

fn objectsOverlap(a: anytype, b: anytype) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    const a_end = std.math.add(usize, a_start, @sizeOf(@typeInfo(@TypeOf(a)).pointer.child)) catch return true;
    const b_end = std.math.add(usize, b_start, @sizeOf(@typeInfo(@TypeOf(b)).pointer.child)) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn validProjection(value: RuntimeProjection) bool {
    return value.runtime_addr != 0 and value.runtime_generation != 0 and value.service_addr != 0 and
        value.service_generation != 0 and value.service_process_nonce != 0 and value.app_instance_nonce != 0;
}

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn projectionMatches(authority: IncidentPublisherAuthority, value: RuntimeProjection) bool {
    return authority.runtime_addr == value.runtime_addr and authority.runtime_generation == value.runtime_generation and
        authority.service_addr == value.service_addr and authority.service_generation == value.service_generation and
        authority.service_process_nonce == value.service_process_nonce and authority.app_instance_nonce == value.app_instance_nonce;
}

fn authoritySealInput(value: IncidentPublisherAuthority) process_seal.IncidentPublisherAuthoritySealInput {
    return .{
        .self_addr = value.self_addr,
        .registry_addr = value.registry_addr,
        .registry_generation = value.registry_generation,
        .runtime_addr = value.runtime_addr,
        .runtime_generation = value.runtime_generation,
        .service_addr = value.service_addr,
        .service_generation = value.service_generation,
        .service_process_nonce = value.service_process_nonce,
        .owner_thread = value.owner_thread,
        .app_instance_nonce = value.app_instance_nonce,
        .lifecycle_raw = value.lifecycle_raw,
    };
}

fn leaseSealInput(value: IncidentPublisherLease) process_seal.IncidentPublisherLeaseSealInput {
    return .{
        .self_addr = value.self_addr,
        .registry_addr = value.registry_addr,
        .registry_generation = value.registry_generation,
        .authority_addr = value.authority_addr,
        .runtime_addr = value.runtime_addr,
        .runtime_generation = value.runtime_generation,
        .service_addr = value.service_addr,
        .service_generation = value.service_generation,
        .owner_thread = value.owner_thread,
        .lease_generation = value.lease_generation,
        .consumed_raw = value.consumed_raw,
    };
}

fn validLease(registry: *const Registry, lease: *const IncidentPublisherLease) bool {
    const value = lease.*;
    if (value.self_addr != @intFromPtr(lease) or value.registry_addr != registry.self_addr or
        value.registry_generation != registry.authority.registry_generation or
        value.authority_addr != @intFromPtr(&registry.authority) or value.pid != registry.pid or
        value.process_nonce != registry.process_nonce or value.owner_thread != registry.owner_thread or value.consumed_raw != 0)
        return false;
    const expected = process_seal.incidentPublisherLeaseSeal(registry.pid, registry.process_nonce, leaseSealInput(value)) catch return false;
    return std.mem.eql(u8, &expected, &value.seal);
}

fn findActiveLease(registry: *Registry, value: IncidentPublisherLease) ?*ActiveLease {
    for (&registry.active_leases) |*row| {
        if (row.lease_addr == value.self_addr and row.lease_generation == value.lease_generation) return row;
    }
    return null;
}

fn ensureProcessSealForTest() !u64 {
    if (process_seal.currentReadyIdentity()) |identity| return identity.process_nonce else |_| {}
    const pid = process_seal.currentProcessId();
    const nonce = try process_seal.generateProcessNonce();
    const receipt = try process_seal.prepare(pid, nonce);
    process_seal.commitReady(receipt);
    return nonce;
}

fn fixtureProjection() RuntimeProjection {
    return .{
        .runtime_addr = 0x1000,
        .runtime_generation = 1,
        .service_addr = 0x2000,
        .service_generation = 1,
        .service_process_nonce = 0x3000,
        .app_instance_nonce = 0x4000,
    };
}

test "CR0b publisher authority는 final address에 등록하고 lease를 조회한다" {
    var registry: Registry = .{};
    try registry.initInPlace(try ensureProcessSealForTest());
    try registry.install(fixtureProjection());
    var lease: IncidentPublisherLease = .{};
    try registry.acquire(&lease);
    try std.testing.expectEqual(@as(u64, 1), registry.active_lease_count);
    try std.testing.expectEqual(fixtureProjection().service_addr, lease.service_addr);
    const duplicate_address = lease;
    lease = .{};
    try std.testing.expectError(error.Busy, registry.acquire(&lease));
    try std.testing.expectEqual(IncidentPublisherLease{}, lease);
    lease = duplicate_address;
    var sibling: IncidentPublisherLease = .{};
    try registry.acquire(&sibling);
    try registry.release(&lease);
    const sibling_live = sibling;
    const count_before_hole_attack = registry.active_lease_count;
    sibling = .{};
    try std.testing.expectError(error.Busy, registry.acquire(&sibling));
    try std.testing.expectEqual(IncidentPublisherLease{}, sibling);
    try std.testing.expectEqual(@as(u64, count_before_hole_attack), registry.active_lease_count);
    sibling = sibling_live;
    try registry.release(&sibling);
    lease = .{};
    try registry.acquire(&lease);
    try std.testing.expect(!(try registry.beginClosing()));
    var rejected: IncidentPublisherLease = .{};
    try std.testing.expectError(error.Closing, registry.acquire(&rejected));
    try std.testing.expectEqual(IncidentPublisherLease{}, rejected);
    try registry.release(&lease);
    try std.testing.expectEqual(@as(u64, 0), registry.active_lease_count);
    try std.testing.expect(try registry.beginClosing());
}

test "CR0b publisher authority는 copied moved owner를 mutation 없이 거부한다" {
    var registry: Registry = .{};
    try registry.initInPlace(try ensureProcessSealForTest());
    try registry.install(fixtureProjection());
    const before = registry;
    var executed: usize = 0;
    var copied = registry;
    var copied_lease: IncidentPublisherLease = .{};
    try std.testing.expectError(error.InvalidOwner, copied.acquire(&copied_lease));
    try std.testing.expectEqual(IncidentPublisherLease{}, copied_lease);
    executed += 1;
    var moved: Registry = .{};
    moved = registry;
    var moved_lease: IncidentPublisherLease = .{};
    try std.testing.expectError(error.InvalidOwner, moved.acquire(&moved_lease));
    try std.testing.expectEqual(IncidentPublisherLease{}, moved_lease);
    executed += 1;
    try std.testing.expectEqual(@as(usize, 2), executed);
    try std.testing.expectEqualDeep(before, registry);
    try std.testing.expectEqual(@as(u64, 0), registry.active_lease_count);
    const registry_bytes: *[@sizeOf(Registry)]u8 = @ptrCast(&registry);
    const overlapped: *IncidentPublisherLease = @ptrCast(@alignCast(registry_bytes[@offsetOf(Registry, "active_leases")..].ptr));
    try std.testing.expectError(error.InvalidOwner, registry.acquire(overlapped));
    try std.testing.expectEqualDeep(before, registry);
}

test "CR0b publisher authority는 fork PID를 lock 전에 거부한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var registry: Registry = .{};
    try registry.initInPlace(try ensureProcessSealForTest());
    try registry.install(fixtureProjection());
    lock(&registry.mutex);
    defer registry.mutex.unlock();
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        var lease: IncidentPublisherLease = .{};
        registry.acquire(&lease) catch |err| std.c._exit(if (err == error.InvalidOwner) 73 else 74);
        std.c._exit(75);
    }
    var status: u32 = 0;
    var attempts: usize = 0;
    while (attempts < 2000) : (attempts += 1) {
        const waited = std.c.waitpid(child, @ptrCast(&status), std.c.W.NOHANG);
        if (waited == child) break;
        if (waited < 0) {
            _ = std.c.kill(child, std.c.SIG.KILL);
            _ = std.c.waitpid(child, @ptrCast(&status), 0);
            return error.TestUnexpectedResult;
        }
        var delay = [_]std.c.pollfd{};
        _ = std.c.poll(&delay, 0, 1);
    } else {
        _ = std.c.kill(child, std.c.SIG.KILL);
        _ = std.c.waitpid(child, @ptrCast(&status), 0);
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(std.c.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u8, 73), std.c.W.EXITSTATUS(status));
    try std.testing.expectEqual(@as(u64, 0), registry.active_lease_count);
}

test "CR0b publisher authority는 runtime service address와 generation splice를 거부한다" {
    var registry: Registry = .{};
    try registry.initInPlace(try ensureProcessSealForTest());
    try registry.install(fixtureProjection());
    const baseline = registry;
    var executed: usize = 0;
    inline for (.{ "runtime_addr", "service_addr", "runtime_generation", "service_generation" }) |field| {
        @field(registry.authority, field) +%= 1;
        var lease: IncidentPublisherLease = .{};
        try std.testing.expectError(error.InvalidOwner, registry.acquire(&lease));
        registry = baseline;
        executed += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), executed);
}

test "CR0b publisher lease는 replay와 double release를 거부한다" {
    var registry: Registry = .{};
    try registry.initInPlace(try ensureProcessSealForTest());
    try registry.install(fixtureProjection());
    var lease: IncidentPublisherLease = .{};
    try registry.acquire(&lease);
    var executed: usize = 0;
    var copied = lease;
    try std.testing.expectError(error.InvalidOwner, registry.release(&copied));
    executed += 1;
    try registry.release(&lease);
    try std.testing.expectError(error.InvalidOwner, registry.release(&lease));
    executed += 1;
    try std.testing.expectEqual(@as(u64, 0), registry.active_lease_count);

    var reused: IncidentPublisherLease = .{};
    try registry.acquire(&reused);
    const old_bytes = reused;
    try registry.release(&reused);
    reused = .{};
    try registry.acquire(&reused);
    const current = reused;
    reused = old_bytes;
    try std.testing.expectError(error.InvalidOwner, registry.release(&reused));
    executed += 1;
    try std.testing.expectEqual(@as(u64, 1), registry.active_lease_count);
    reused = current;
    try registry.release(&reused);
    try std.testing.expectEqual(@as(u64, 0), registry.active_lease_count);
    try std.testing.expectEqual(@as(usize, 3), executed);
}

test "CR0b publisher registry는 canonical owner를 재사용하고 second owner 교체를 거부한다" {
    var registry: Registry = .{};
    try registry.initInPlace(try ensureProcessSealForTest());
    const projection = fixtureProjection();
    var executed: usize = 0;
    try registry.install(projection);
    try registry.install(projection);
    executed += 1;
    var other = projection;
    other.runtime_addr += 8;
    try std.testing.expectError(error.Busy, registry.install(other));
    executed += 1;
    other = projection;
    other.runtime_generation += 1;
    try std.testing.expectError(error.Busy, registry.install(other));
    executed += 1;
    try std.testing.expectEqual(@as(usize, 3), executed);
}

test "CR0b publisher authority generation exhaustion은 publication 전에 fail-stop한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var registry: Registry = .{};
    try registry.initInPlace(try ensureProcessSealForTest());
    registry.next_registry_generation = std.math.maxInt(u64);
    const before = registry;
    if (PublisherTestChannel.maru_cr0b_publisher_child_path_len == 0) return error.TestUnexpectedResult;
    const executable = PublisherTestChannel.maru_cr0b_publisher_child_path[0..PublisherTestChannel.maru_cr0b_publisher_child_path_len :0];
    var marker_pipe: [2]c_int = undefined;
    if (std.c.pipe(&marker_pipe) != 0) return error.TestUnexpectedResult;
    const child = std.c.fork();
    if (child < 0) {
        _ = std.c.close(marker_pipe[0]);
        _ = std.c.close(marker_pipe[1]);
        return error.TestUnexpectedResult;
    }
    if (child == 0) {
        _ = std.c.close(marker_pipe[0]);
        if (std.c.dup2(marker_pipe[1], 198) != 198) std.c._exit(126);
        _ = std.c.close(marker_pipe[1]);
        const argv = [_:null]?[*:0]const u8{executable.ptr};
        const env = [_:null]?[*:0]const u8{"MARU_CR0B_PUBLISHER_MARKER_FD=198"};
        _ = std.c.execve(executable.ptr, &argv, &env);
        std.c._exit(127);
    }
    _ = std.c.close(marker_pipe[1]);
    var status: u32 = 0;
    var attempts: usize = 0;
    while (attempts < 2000) : (attempts += 1) {
        const waited = std.c.waitpid(child, @ptrCast(&status), std.c.W.NOHANG);
        if (waited == child) break;
        if (waited < 0) {
            _ = std.c.kill(child, std.c.SIG.KILL);
            _ = std.c.waitpid(child, @ptrCast(&status), 0);
            _ = std.c.close(marker_pipe[0]);
            return error.TestUnexpectedResult;
        }
        var delay = [_]std.c.pollfd{};
        _ = std.c.poll(&delay, 0, 1);
    } else {
        _ = std.c.kill(child, std.c.SIG.KILL);
        _ = std.c.waitpid(child, @ptrCast(&status), 0);
        _ = std.c.close(marker_pipe[0]);
        return error.TestUnexpectedResult;
    }
    var marker: [2]u8 = undefined;
    const marker_count = std.c.read(marker_pipe[0], &marker, marker.len);
    _ = std.c.close(marker_pipe[0]);
    try std.testing.expectEqual(@as(isize, 1), marker_count);
    try std.testing.expectEqual(@as(u8, 0x51), marker[0]);
    try std.testing.expect(std.c.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u8, 86), std.c.W.EXITSTATUS(status));
    try std.testing.expectEqualDeep(before, registry);
}

test "CR0b authority exhaustion child는 실제 counter owner에서 fail-stop한다" {
    var registry: Registry = .{};
    try registry.initInPlace(try ensureProcessSealForTest());
    registry.next_registry_generation = std.math.maxInt(u64);
    const marker_text = std.c.getenv("MARU_CR0B_PUBLISHER_MARKER_FD") orelse std.c._exit(126);
    if (!std.mem.eql(u8, std.mem.span(marker_text), "198") or
        std.c.write(198, &[_]u8{0x51}, 1) != 1)
        std.c._exit(126);
    registry.install(fixtureProjection()) catch std.c._exit(74);
    std.c._exit(75);
}
