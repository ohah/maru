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
pub const PublicationError = Error || host_adapter_mod.ManagedPoisonError || coordinator.Error;

pub const TerminationOutcome = enum(u32) {
    inactive = 0,
    joined = 1,
    detached = 2,
    degraded = 3,
};

const Lifecycle = enum(u8) { pristine = 0, ready = 1, closing = 2, closed = 3 };

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
    pub fn publishManagedPoison(
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

test "CR0b managed public poison prerequisite는 canonical suffix가 first와 repeat를 contextual 선택한다" {
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

    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();
    const adapter = try std.testing.allocator.create(host_adapter_mod.HostAdapter);
    var pool_owns = false;
    errdefer if (!pool_owns) std.testing.allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = std.testing.allocator,
        .fd = -1,
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
    const binding = adapter.slot.logicalClientConst().incident_binding;
    const incident = @import("maru").observability.connection_incident;
    var input: publication.IncidentInput = .{
        .timestamp_ns = 101,
        .host_id = binding.host_id,
        .host_adapter_generation = binding.host_adapter_generation,
        .connection_generation = binding.connection_generation,
        .wire_major = binding.wire_major,
        .reason_raw = @intFromEnum(incident.ConnectionReason.connection_eof),
        .scope_raw = @intFromEnum(incident.Scope.connection),
        .disposition_raw = @intFromEnum(incident.Disposition.reconnect),
        .source_site_raw = @intFromEnum(incident.SourceSite.client_read),
        .host_class_raw = binding.host_class_raw,
        .parser_phase_raw = @intFromEnum(incident.ParserPhase.idle),
        .outbound_phase_raw = @intFromEnum(incident.OutboundPhase.idle),
        .last_success_request_id = 103,
        .pending_request_count = 2,
        .pending_stream_count = 3,
        .pending_event_count = 5,
        .queue_item_count = 7,
        .queue_bytes = 11,
        .controller_generation = 13,
        .upgrade_epoch = 17,
    };
    var first_handoff: publication.PreparedManagedPoison = .{};
    try adapter.prepareManagedPoison(input, &first_handoff);
    const first = try owner.publishManagedPoison(adapter, &first_handoff);
    try std.testing.expect(first.publication.detail_present);
    try std.testing.expectEqual(@intFromEnum(publication.PublicationKind.first), first.kind_raw);
    try std.testing.expect(publication.validManagedPoisonConsumedShape(first_handoff, @intFromPtr(&first_handoff)));
    const first_id = adapter.slot.logicalClientConst().first_incident_id;
    try std.testing.expect(first_id.sequence != 0);
    const client_after_first = host_adapter_mod.HostAdapter.testing.rawClient(adapter);
    try std.testing.expect(client_after_first.unusable);
    try std.testing.expectEqual(@as(c.fd_t, -1), client_after_first.fd);
    try std.testing.expect(client_after_first.pending_outbound == null);
    const admission = (try owner.reconnect_admissions.peek()).?;
    try std.testing.expectEqual(first_id, admission.incident_id);
    try std.testing.expectEqual(input.host_id, admission.host_id);
    try std.testing.expectEqual(input.connection_generation, admission.connection_generation);
    try std.testing.expectEqual(@as(u8, 1), owner.reconnect_admissions.count);

    input.timestamp_ns += 1;
    var repeat_handoff: publication.PreparedManagedPoison = .{};
    try adapter.prepareManagedPoison(input, &repeat_handoff);
    const repeat = try owner.publishManagedPoison(adapter, &repeat_handoff);
    try std.testing.expect(!repeat.publication.detail_present);
    try std.testing.expectEqual(@intFromEnum(publication.PublicationKind.repeat), repeat.kind_raw);
    try std.testing.expectEqual(first_id, repeat.publication.incident_id);
    try std.testing.expectEqual(first.publication.aggregate_generation + 1, repeat.publication.aggregate_generation);
    try std.testing.expectEqual(first_id, adapter.slot.logicalClientConst().first_incident_id);
    try std.testing.expect(publication.validManagedPoisonConsumedShape(repeat_handoff, @intFromPtr(&repeat_handoff)));
    try std.testing.expectEqual(@as(u8, 1), owner.reconnect_admissions.count);
    try owner.reconnect_admissions.consume(admission);
    try std.testing.expect((try owner.reconnect_admissions.peek()) == null);
    try std.testing.expectEqual(runtime_mod.ShutdownResult.joined, try owner.shutdown());
}
