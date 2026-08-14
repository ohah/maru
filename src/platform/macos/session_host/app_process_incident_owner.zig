//! GUI 프로세스가 창보다 오래 소유하는 CR0b incident runtime과 publisher registry.
//!
//! AppSession은 이 owner를 만들거나 옮기지 않고 app-global final address에서 `ensureReady`만 호출한다.
//! 개별 창 teardown은 owner를 정산하지 않으며 AppHost 종료 ABI가 후속 슬라이스에서 `shutdown`을 호출한다.

const std = @import("std");
const runtime_mod = @import("incident_runtime.zig");
const registry_mod = @import("incident_publisher_registry.zig");
const process_seal = @import("process_seal_service.zig");
const host_adapter_mod = @import("host_adapter.zig");
const coordinator = @import("incident_publication_coordinator.zig");
const reconnect_owner_mod = @import("reconnect_admission_owner.zig");
const publication = @import("maru").observability.incident_publication_contract;

const c = std.c;
extern "c" fn usleep(usec: c_uint) c_int;

pub const Error = runtime_mod.Error || registry_mod.Error || reconnect_owner_mod.Error || error{ InvalidOwner, AlreadyClosed };
pub const PublicationError = Error || host_adapter_mod.ManagedPoisonError || coordinator.Error || error{ClockFailed};

pub const TerminationOutcome = enum(u32) {
    inactive = 0,
    joined = 1,
    detached = 2,
    degraded = 3,
};

const Lifecycle = enum(u8) { pristine = 0, ready = 1, closing = 2, closed = 3 };

const PublicationPort = struct {
    mutex: std.atomic.Mutex = .unlocked,
    owner_addr: u64 = 0,
    owner_thread: u64 = 0,
    registry_addr: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    app_instance_nonce: u128 = 0,
    owner_lifecycle_raw: u8 = 0,
    seal: process_seal.CleanupSeal = [_]u8{0} ** 32,
};

var publication_port: PublicationPort = .{};

const PreparedPublicationSnapshot = struct {
    observed: bool = false,
    first_reason_present: bool = false,
    client_was_usable: bool = false,
    fd: c.fd_t = -1,
    pending_outbound_present: bool = false,
    incident_count: u8 = 0,
    pending_slots: u128 = 0,
    reconnect_count: u8 = 0,
};

const PublicationPortTestState = if (@import("builtin").is_test) struct {
    threadlocal var snapshot: ?*PreparedPublicationSnapshot = null;
} else struct {};

pub const PublicationTimestampReceipt = struct {
    owner_addr: u64 = 0,
    owner_thread: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    app_instance_nonce: u128 = 0,
    timestamp_ns: i128 = -1,
    seal: process_seal.CleanupSeal = [_]u8{0} ** 32,
};

fn lockPublicationPort() void {
    while (!publication_port.mutex.tryLock()) std.atomic.spinLoopHint();
}

fn clearPublicationPortLocked() void {
    publication_port.owner_addr = 0;
    publication_port.owner_thread = 0;
    publication_port.registry_addr = 0;
    publication_port.pid = 0;
    publication_port.process_nonce = 0;
    publication_port.app_instance_nonce = 0;
    publication_port.owner_lifecycle_raw = 0;
    publication_port.seal = [_]u8{0} ** 32;
}

fn publicationPortSeal(port: *const PublicationPort) process_seal.CleanupSeal {
    return process_seal.incidentPublicationPortSeal(port.pid, port.process_nonce, .{
        .owner_addr = port.owner_addr,
        .owner_thread = port.owner_thread,
        .registry_addr = port.registry_addr,
        .pid = port.pid,
        .process_nonce = port.process_nonce,
        .app_instance_nonce = port.app_instance_nonce,
        .owner_lifecycle_raw = port.owner_lifecycle_raw,
    }) catch process_seal.fatalIntegrity(.incident_authority);
}

fn publicationTimestampSeal(receipt: PublicationTimestampReceipt) process_seal.CleanupSeal {
    return process_seal.incidentPublicationTimestampSeal(receipt.pid, receipt.process_nonce, .{
        .owner_addr = receipt.owner_addr,
        .owner_thread = receipt.owner_thread,
        .pid = receipt.pid,
        .process_nonce = receipt.process_nonce,
        .app_instance_nonce = receipt.app_instance_nonce,
        .timestamp_ns = receipt.timestamp_ns,
    }) catch process_seal.fatalIntegrity(.incident_authority);
}

fn publicationTimestampReceiptValid(receipt: PublicationTimestampReceipt) bool {
    lockPublicationPort();
    defer publication_port.mutex.unlock();
    if (publication_port.owner_addr == 0 or
        publication_port.owner_thread != @as(u64, @intCast(std.Thread.getCurrentId()))) return false;
    const owner: *AppProcessIncidentOwner = @ptrFromInt(publication_port.owner_addr);
    return owner.validReady() and publicationPortMatchesOwner(&publication_port, owner) and
        receipt.owner_addr == publication_port.owner_addr and
        receipt.owner_thread == publication_port.owner_thread and
        receipt.pid == publication_port.pid and receipt.process_nonce == publication_port.process_nonce and
        receipt.app_instance_nonce == publication_port.app_instance_nonce and receipt.timestamp_ns >= 0 and
        std.crypto.timing_safe.eql(process_seal.CleanupSeal, receipt.seal, publicationTimestampSeal(receipt));
}

fn publicationPortMatchesOwner(port: *const PublicationPort, owner: *const AppProcessIncidentOwner) bool {
    return port.owner_addr == @intFromPtr(owner) and
        port.owner_thread == owner.owner_thread and
        port.registry_addr == @intFromPtr(&owner.registry) and
        port.pid == owner.pid and port.process_nonce == owner.process_nonce and
        port.app_instance_nonce == owner.app_instance_nonce and
        port.owner_lifecycle_raw == owner.lifecycle_raw and
        std.crypto.timing_safe.eql(process_seal.CleanupSeal, port.seal, publicationPortSeal(port));
}

fn resolvePublicationPortOwner() ?*AppProcessIncidentOwner {
    lockPublicationPort();
    defer publication_port.mutex.unlock();
    if (publication_port.owner_addr == 0 or publication_port.owner_thread != @as(u64, @intCast(std.Thread.getCurrentId())))
        return null;
    const owner: *AppProcessIncidentOwner = @ptrFromInt(publication_port.owner_addr);
    if (!owner.validReady() or !publicationPortMatchesOwner(&publication_port, owner)) return null;
    return owner;
}

/// Installs only the final app-process owner address. Registry/runtime pointers remain private to
/// the owner and are revalidated on every later publication-port lookup.
pub fn installPublicationPort(owner: *AppProcessIncidentOwner) Error!void {
    if (!owner.validReady()) return error.InvalidOwner;
    lockPublicationPort();
    defer publication_port.mutex.unlock();
    if (publication_port.owner_addr != 0) {
        if (publicationPortMatchesOwner(&publication_port, owner)) return;
        return error.InvalidOwner;
    }
    publication_port.owner_addr = @intFromPtr(owner);
    publication_port.owner_thread = owner.owner_thread;
    publication_port.registry_addr = @intFromPtr(&owner.registry);
    publication_port.pid = owner.pid;
    publication_port.process_nonce = owner.process_nonce;
    publication_port.app_instance_nonce = owner.app_instance_nonce;
    publication_port.owner_lifecycle_raw = owner.lifecycle_raw;
    publication_port.seal = publicationPortSeal(&publication_port);
}

/// Revocation precedes shutdown admission, so no failure-site can borrow a closing publisher.
pub fn revokePublicationPort(owner: *AppProcessIncidentOwner) Error!void {
    lockPublicationPort();
    defer publication_port.mutex.unlock();
    if (!publicationPortMatchesOwner(&publication_port, owner)) return error.InvalidOwner;
    clearPublicationPortLocked();
}

pub fn revokePublicationPortNoFail(owner: *AppProcessIncidentOwner) void {
    revokePublicationPort(owner) catch process_seal.fatalIntegrity(.incident_authority);
}

/// Failure-site callers use this facade after releasing their registered Client operation. The
/// facade resolves the sealed owner internally and never returns a raw publisher pointer.
pub fn publishPreparedManagedPoison(
    adapter: *host_adapter_mod.HostAdapter,
    prepared: *publication.PreparedManagedPoison,
    timestamp: PublicationTimestampReceipt,
) PublicationError!publication.IncidentCommitResult {
    if (!publicationTimestampReceiptValid(timestamp) or prepared.input.timestamp_ns != timestamp.timestamp_ns)
        return error.InvalidOwner;
    const owner = resolvePublicationPortOwner() orelse return error.InvalidOwner;
    if (@import("builtin").is_test) {
        if (PublicationPortTestState.snapshot) |snapshot| {
            const client = host_adapter_mod.HostAdapter.testing.rawClient(adapter);
            snapshot.* = .{
                .observed = true,
                .first_reason_present = client.first_poison_reason != null,
                .client_was_usable = !client.unusable,
                .fd = client.fd,
                .pending_outbound_present = client.pending_outbound != null,
                .incident_count = owner.runtime.?.service.ring.incident_count,
                .pending_slots = owner.runtime.?.service.pending_slots,
                .reconnect_count = owner.reconnect_admissions.count,
            };
        }
    }
    return owner.publishPreparedManagedPoison(adapter, prepared);
}

pub fn publicationTimestampReceipt() PublicationError!PublicationTimestampReceipt {
    const owner = resolvePublicationPortOwner() orelse return error.InvalidOwner;
    var receipt: PublicationTimestampReceipt = .{
        .owner_addr = @intFromPtr(owner),
        .owner_thread = owner.owner_thread,
        .pid = owner.pid,
        .process_nonce = owner.process_nonce,
        .app_instance_nonce = owner.app_instance_nonce,
        .timestamp_ns = monotonicNs() orelse return error.ClockFailed,
    };
    receipt.seal = publicationTimestampSeal(receipt);
    return receipt;
}

pub const publication_port_testing_api = if (@import("builtin").is_test) struct {
    pub const PrePublicationSnapshot = PreparedPublicationSnapshot;

    pub fn armPrePublicationSnapshot(snapshot: *PrePublicationSnapshot) void {
        if (PublicationPortTestState.snapshot != null or !std.meta.eql(snapshot.*, PrePublicationSnapshot{}))
            @panic("prepared publication snapshot is already armed");
        PublicationPortTestState.snapshot = snapshot;
    }

    pub fn disarmPrePublicationSnapshot() void {
        PublicationPortTestState.snapshot = null;
    }

    pub fn install(owner: *AppProcessIncidentOwner) Error!void {
        try installPublicationPort(owner);
    }

    pub fn driftSeal() void {
        lockPublicationPort();
        defer publication_port.mutex.unlock();
        publication_port.seal[0] ^= 1;
    }

    pub fn timestampReceiptValid(receipt: PublicationTimestampReceipt) bool {
        return publicationTimestampReceiptValid(receipt);
    }

    /// AppSession tests share one process-global owner across thousands of cases. A fixture may
    /// reset that owner storage only after its own cleanup; clear the test-only lookup token too.
    pub fn reset() void {
        lockPublicationPort();
        defer publication_port.mutex.unlock();
        clearPublicationPortLocked();
    }
} else struct {};

pub const AppProcessIncidentOwner = struct {
    self_addr: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    app_instance_nonce: u128 = 0,
    owner_thread: u64 = 0,
    lifecycle_raw: u8 = 0,
    runtime: ?*runtime_mod.ConnectionIncidentRuntime = null,
    registry: registry_mod.Registry = .{},
    reconnect_admissions: reconnect_owner_mod.Owner = .{},

    pub fn ensureReady(
        self: *AppProcessIncidentOwner,
        allocator: std.mem.Allocator,
        dir_fd: c.fd_t,
        process_nonce: u64,
        app_instance_nonce: u128,
    ) Error!void {
        const pid = process_seal.currentProcessId();
        if (pid == 0 or process_nonce == 0 or app_instance_nonce == 0)
            return error.InvalidOwner;
        if (self.lifecycle_raw == @intFromEnum(Lifecycle.ready)) {
            if (!self.validReady() or self.process_nonce != process_nonce or
                self.app_instance_nonce != app_instance_nonce)
                return error.InvalidOwner;
            return;
        }
        if (dir_fd < 0) return error.InvalidOwner;
        if (!std.meta.eql(self.*, AppProcessIncidentOwner{})) return error.AlreadyClosed;
        process_seal.validateReady(pid, process_nonce) catch return error.InvalidOwner;

        self.self_addr = @intFromPtr(self);
        self.pid = pid;
        self.process_nonce = process_nonce;
        self.app_instance_nonce = app_instance_nonce;
        self.owner_thread = @intCast(std.Thread.getCurrentId());
        errdefer self.* = .{};

        const runtime = try runtime_mod.ConnectionIncidentRuntime.create(
            allocator,
            pid,
            process_nonce,
            app_instance_nonce,
            dir_fd,
        );
        errdefer _ = runtime.abortUnpublished() catch
            process_seal.fatalIntegrity(.incident_authority);
        try self.registry.initInPlace(process_nonce);
        try self.reconnect_admissions.initInPlace(process_nonce);
        try runtime.installPublisherRegistry(&self.registry);
        self.runtime = runtime;
        self.lifecycle_raw = @intFromEnum(Lifecycle.ready);
    }

    pub fn publisher(self: *AppProcessIncidentOwner) ?struct {
        registry: *registry_mod.Registry,
        runtime: *runtime_mod.ConnectionIncidentRuntime,
    } {
        if (!self.validOwned() or self.lifecycle_raw != @intFromEnum(Lifecycle.ready) or
            self.registry.lifecycle_raw != @intFromEnum(registry_mod.Lifecycle.ready)) return null;
        return .{ .registry = &self.registry, .runtime = self.runtime.? };
    }

    /// Sole product composition point: adapter authority yields the query and this owner supplies
    /// the ephemeral publisher borrow. Neither raw pointer is stored in the prepared handoff.
    /// Managed public poison entrypoint. Caller는 failure-site identity만 제출하며 timestamp와
    /// Client-owned diagnostic projection은 final owners가 publication 전에 한 번 만든다.
    pub fn publishManagedPoison(
        self: *AppProcessIncidentOwner,
        adapter: *host_adapter_mod.HostAdapter,
        request: publication.ManagedPoisonRequest,
    ) PublicationError!publication.IncidentCommitResult {
        const timestamp_ns = monotonicNs() orelse return error.ClockFailed;
        var prepared: publication.PreparedManagedPoison = .{};
        try adapter.prepareManagedPoisonRequest(timestamp_ns, request, &prepared);
        return self.publishPreparedManagedPoison(adapter, &prepared);
    }

    fn publishPreparedManagedPoison(
        self: *AppProcessIncidentOwner,
        adapter: *host_adapter_mod.HostAdapter,
        prepared: *publication.PreparedManagedPoison,
    ) PublicationError!publication.IncidentCommitResult {
        const publisher_view = self.publisher() orelse return error.InvalidOwner;
        const query = try adapter.managedPoisonQuery(prepared);
        const wants_reconnect = prepared.input.disposition_raw == @intFromEnum(@import("maru").observability.connection_incident.Disposition.reconnect);
        const will_publish_first = try adapter.managedPoisonWillPublishFirst(prepared);
        if (wants_reconnect and will_publish_first) try self.reconnect_admissions.preflight(prepared.input);
        const result = try coordinator.publishCanonical(
            publisher_view.registry,
            publisher_view.runtime,
            query,
            prepared.input,
        );
        const terminal_fd = if (result.kind_raw == @intFromEnum(publication.PublicationKind.first))
            adapter.terminalizeManagedPoisonNoFail(prepared, result)
        else
            null;
        adapter.consumeManagedPoison(prepared) catch
            process_seal.fatalIntegrity(.incident_authority);
        if (terminal_fd) |fd| _ = c.close(fd);
        if (result.kind_raw == @intFromEnum(publication.PublicationKind.first) and wants_reconnect)
            self.reconnect_admissions.admitAfterPreflightNoFail(result, prepared.input);
        return result;
    }

    pub const testing_api = if (@import("builtin").is_test) struct {
        pub fn markWriterFailed(self: *AppProcessIncidentOwner) Error!void {
            if (!self.validReady()) return error.InvalidOwner;
            runtime_mod.ConnectionIncidentRuntime.testing_api.markWriterFailed(self.runtime.?);
        }
    } else struct {};

    pub fn shutdown(self: *AppProcessIncidentOwner) Error!runtime_mod.ShutdownResult {
        if (!self.validOwned() or (self.lifecycle_raw != @intFromEnum(Lifecycle.ready) and
            self.lifecycle_raw != @intFromEnum(Lifecycle.closing))) return error.InvalidOwner;
        const runtime = self.runtime.?;
        self.lifecycle_raw = @intFromEnum(Lifecycle.closing);
        const result = try runtime.shutdownPublished(&self.registry);
        self.runtime = null;
        self.lifecycle_raw = @intFromEnum(Lifecycle.closed);
        return result;
    }

    /// AppHost termination은 재시도할 이벤트 루프가 없으므로 active lease를 짧게 bounded drain한다. deadline에도 남은
    /// lease는 runtime/registry backing을 해제하지 않은 채 process-exit 수명으로 보존한다.
    pub fn shutdownForTermination(self: *AppProcessIncidentOwner) TerminationOutcome {
        if (std.meta.eql(self.*, AppProcessIncidentOwner{})) return .inactive;
        const started = monotonicMs() orelse process_seal.fatalIntegrity(.incident_authority);
        while (true) {
            const result = self.shutdown() catch |err| switch (err) {
                error.InvalidAuthority => {
                    if (!self.validOwned() or self.lifecycle_raw != @intFromEnum(Lifecycle.closing))
                        process_seal.fatalIntegrity(.incident_authority);
                    const now = monotonicMs() orelse process_seal.fatalIntegrity(.incident_authority);
                    if (now -| started >= 200) return .detached;
                    _ = usleep(1_000);
                    continue;
                },
                else => return .degraded,
            };
            return switch (result) {
                .joined => .joined,
                .detached => .detached,
                .degraded_joined, .degraded_detached => .degraded,
            };
        }
    }

    fn validReady(self: *const AppProcessIncidentOwner) bool {
        return self.validOwned() and self.lifecycle_raw == @intFromEnum(Lifecycle.ready);
    }

    fn validOwned(self: *const AppProcessIncidentOwner) bool {
        const runtime = self.runtime orelse return false;
        return self.self_addr == @intFromPtr(self) and self.pid == process_seal.currentProcessId() and
            self.pid != 0 and self.process_nonce != 0 and self.app_instance_nonce != 0 and
            self.owner_thread == @as(u64, @intCast(std.Thread.getCurrentId())) and
            self.registry.self_addr == @intFromPtr(&self.registry) and
            self.reconnect_admissions.ownedBy(self.pid, self.process_nonce, self.owner_thread) and
            runtime.publisher_registry_addr == @intFromPtr(&self.registry);
    }
};

fn monotonicMs() ?u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return null;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn monotonicNs() ?i128 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return null;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn testDirectory() !struct { dir: std.testing.TmpDir, fd: c.fd_t } {
    var tmp = std.testing.tmpDir(.{});
    try std.testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    const fd = c.dup(tmp.dir.handle);
    if (fd < 0) {
        tmp.cleanup();
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)));
    return .{ .dir = tmp, .fd = fd };
}

test "CR0b GUI incident owner prerequisite는 final address에 runtime과 registry를 한 번 설치한다" {
    const client_slot = @import("client_slot.zig");
    try client_slot.ClientSlot.initializeProcessRuntime();
    const identity = client_slot.ClientSlot.publicationProcessIdentity() orelse return error.TestUnexpectedResult;
    var directory = try testDirectory();
    defer directory.dir.cleanup();
    defer _ = c.close(directory.fd);
    var owner: AppProcessIncidentOwner = .{};
    try owner.ensureReady(std.testing.allocator, directory.fd, identity.process_nonce, 0xA001);
    try std.testing.expect(owner.publisher() != null);
    try std.testing.expectEqual(@intFromPtr(&owner), owner.self_addr);
    try std.testing.expectEqual(@intFromPtr(&owner.registry), owner.registry.self_addr);
    try std.testing.expectEqual(runtime_mod.ShutdownResult.joined, try owner.shutdown());
}

test "CR0b GUI incident owner prerequisite는 current restore 호출이 같은 owner를 재사용한다" {
    const client_slot = @import("client_slot.zig");
    try client_slot.ClientSlot.initializeProcessRuntime();
    const identity = client_slot.ClientSlot.publicationProcessIdentity() orelse return error.TestUnexpectedResult;
    var directory = try testDirectory();
    defer directory.dir.cleanup();
    defer _ = c.close(directory.fd);
    var owner: AppProcessIncidentOwner = .{};
    try owner.ensureReady(std.testing.allocator, directory.fd, identity.process_nonce, 0xA002);
    const first = owner.publisher() orelse return error.TestUnexpectedResult;
    try owner.ensureReady(std.testing.allocator, directory.fd, identity.process_nonce, 0xA002);
    const second = owner.publisher() orelse return error.TestUnexpectedResult;
    try std.testing.expect(first.runtime == second.runtime);
    try std.testing.expect(first.registry == second.registry);
    var lease: registry_mod.IncidentPublisherLease = .{};
    try owner.registry.acquire(&lease);
    try std.testing.expectError(error.InvalidAuthority, owner.shutdown());
    try std.testing.expect(owner.runtime != null);
    try std.testing.expectEqual(@intFromEnum(Lifecycle.closing), owner.lifecycle_raw);
    try owner.registry.release(&lease);
    try std.testing.expectEqual(runtime_mod.ShutdownResult.joined, try owner.shutdown());
}

test "CR0b GUI incident owner prerequisite는 active lease deadline에 backing을 보존한다" {
    const client_slot = @import("client_slot.zig");
    try client_slot.ClientSlot.initializeProcessRuntime();
    const identity = client_slot.ClientSlot.publicationProcessIdentity() orelse return error.TestUnexpectedResult;
    var directory = try testDirectory();
    defer directory.dir.cleanup();
    defer _ = c.close(directory.fd);
    var owner: AppProcessIncidentOwner = .{};
    try owner.ensureReady(std.testing.allocator, directory.fd, identity.process_nonce, 0xA005);
    const runtime = owner.runtime.?;
    var lease: registry_mod.IncidentPublisherLease = .{};
    try owner.registry.acquire(&lease);
    const started = monotonicMs() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(TerminationOutcome.detached, owner.shutdownForTermination());
    const elapsed = (monotonicMs() orelse return error.TestUnexpectedResult) -| started;
    try std.testing.expect(elapsed >= 200 and elapsed < 2_000);
    try std.testing.expect(owner.runtime == runtime);
    try std.testing.expectEqual(@intFromEnum(Lifecycle.closing), owner.lifecycle_raw);
    try std.testing.expectEqual(@as(u16, 1), owner.registry.active_lease_count);
    try owner.registry.release(&lease);
    try std.testing.expectEqual(TerminationOutcome.joined, owner.shutdownForTermination());
}

test "CR0b GUI incident owner prerequisite는 copied owner와 다른 nonce 교체를 거부한다" {
    const client_slot = @import("client_slot.zig");
    try client_slot.ClientSlot.initializeProcessRuntime();
    const identity = client_slot.ClientSlot.publicationProcessIdentity() orelse return error.TestUnexpectedResult;
    var directory = try testDirectory();
    defer directory.dir.cleanup();
    defer _ = c.close(directory.fd);
    var owner: AppProcessIncidentOwner = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        owner.ensureReady(failing.allocator(), directory.fd, identity.process_nonce, 0xA003),
    );
    try std.testing.expect(std.meta.eql(owner, AppProcessIncidentOwner{}));
    try owner.ensureReady(std.testing.allocator, directory.fd, identity.process_nonce, 0xA003);
    var copied = owner;
    try std.testing.expect(copied.publisher() == null);
    try std.testing.expectError(
        error.InvalidOwner,
        copied.ensureReady(std.testing.allocator, directory.fd, identity.process_nonce, 0xA003),
    );
    try std.testing.expectError(error.InvalidOwner, copied.shutdown());
    try std.testing.expectError(
        error.InvalidOwner,
        owner.ensureReady(std.testing.allocator, directory.fd, identity.process_nonce + 1, 0xA003),
    );
    try std.testing.expectError(
        error.InvalidOwner,
        owner.ensureReady(std.testing.allocator, directory.fd, identity.process_nonce, 0xA004),
    );
    try std.testing.expect(owner.publisher() != null);
    try std.testing.expectEqual(runtime_mod.ShutdownResult.joined, try owner.shutdown());
}

test "CR0b managed public poison은 canonical suffix만 호출한다" {
    const client_mod = @import("client.zig");
    const protocol = @import("protocol.zig");
    const screen_stream = @import("screen_stream.zig");
    const Pool = @import("host_pool.zig").HostPool(host_adapter_mod.HostAdapter);
    try host_adapter_mod.HostAdapter.initializeProcessRuntime();
    const identity = host_adapter_mod.HostAdapter.publicationProcessIdentity() orelse
        return error.TestUnexpectedResult;
    var directory = try testDirectory();
    defer directory.dir.cleanup();
    defer _ = c.close(directory.fd);
    var owner: AppProcessIncidentOwner = .{};
    try owner.ensureReady(std.testing.allocator, directory.fd, identity.process_nonce, 0xA101);
    var owner_settled = false;
    defer if (!owner_settled) {
        _ = owner.shutdown() catch {};
    };

    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    const adapter = try std.testing.allocator.create(host_adapter_mod.HostAdapter);
    var pool_owns = false;
    errdefer if (!pool_owns) std.testing.allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = std.testing.allocator,
        .fd = fds[0],
        .host_id = 0xA102,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .parser = @import("framing.zig").FrameParser.init(std.testing.allocator),
    };
    var permit: @import("maru").observability.incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(source.host_id, adapter, &permit);
    try host_adapter_mod.HostAdapter.initManagedInPlace(adapter, std.testing.allocator, &source, &permit);
    pool.commitOwnedPublication(adapter, &permit);
    pool_owns = true;
    const incident = @import("maru").observability.connection_incident;
    const binding = adapter.slot.logicalClientConst().incident_binding;
    const request: publication.ManagedPoisonRequest = .{
        .reason_raw = @intFromEnum(incident.ConnectionReason.connection_eof),
        .source_site_raw = @intFromEnum(incident.SourceSite.client_read),
        .controller_generation = 13,
    };
    var invalid_request = request;
    invalid_request.source_site_raw = 0;
    try std.testing.expectError(error.InvalidInput, owner.publishManagedPoison(adapter, invalid_request));
    try std.testing.expectEqual(fds[0], adapter.slot.logicalClientConst().fd);
    try std.testing.expect(adapter.slot.logicalClientConst().first_poison_reason == null);
    try std.testing.expectEqual(@as(u8, 0), owner.reconnect_admissions.count);
    const first = try owner.publishManagedPoison(adapter, request);
    try std.testing.expect(first.publication.detail_present);
    try std.testing.expectEqual(@intFromEnum(publication.PublicationKind.first), first.kind_raw);
    const first_id = adapter.slot.logicalClientConst().first_incident_id;
    try std.testing.expect(first_id.sequence != 0);
    const client_after_first = host_adapter_mod.HostAdapter.testing.rawClient(adapter);
    try std.testing.expect(client_after_first.unusable);
    try std.testing.expectEqual(@as(c.fd_t, -1), client_after_first.fd);
    try std.testing.expect(client_after_first.pending_outbound == null);
    var closed_byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(fds[1], &closed_byte, closed_byte.len));
    const admission = (try owner.reconnect_admissions.peek()).?;
    try std.testing.expectEqual(first_id, admission.incident_id);
    try std.testing.expectEqual(binding.host_id, admission.host_id);
    try std.testing.expectEqual(binding.connection_generation, admission.connection_generation);
    try std.testing.expectEqual(@as(u8, 1), owner.reconnect_admissions.count);

    const repeat = try owner.publishManagedPoison(adapter, request);
    try std.testing.expect(!repeat.publication.detail_present);
    try std.testing.expectEqual(@intFromEnum(publication.PublicationKind.repeat), repeat.kind_raw);
    try std.testing.expectEqual(first_id, repeat.publication.incident_id);
    try std.testing.expectEqual(first.publication.aggregate_generation + 1, repeat.publication.aggregate_generation);
    try std.testing.expectEqual(first_id, adapter.slot.logicalClientConst().first_incident_id);
    try std.testing.expectEqual(@as(u8, 1), owner.reconnect_admissions.count);
    try owner.reconnect_admissions.consume(admission);
    try std.testing.expect((try owner.reconnect_admissions.peek()) == null);
    const shutdown_outcome = try owner.shutdown();
    owner_settled = true;
    try std.testing.expectEqual(runtime_mod.ShutdownResult.joined, shutdown_outcome);
}
