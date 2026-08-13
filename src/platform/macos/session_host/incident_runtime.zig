//! CR0b 연결 장애 service와 파일 기록기 스레드의 process-lifetime owner.
//!
//! producer는 ring publication 뒤 nonblocking wake만 수행하고, 파일 I/O와 종료 대기는 이 heap-pinned owner가
//! 맡는다. 종료 deadline을 넘긴 기록기는 backing을 해제하지 않고 detach해 stack UAF와 무기한 join을 함께 피한다.

const std = @import("std");
const builtin = @import("builtin");
const incident = @import("maru").observability.connection_incident;
const artifact = @import("incident_artifact_store.zig");
const process_seal = @import("process_seal_service.zig");
const publisher_registry = @import("incident_publisher_registry.zig");
const publication = @import("maru").observability.incident_publication_contract;

const c = std.c;
const posix = std.posix;

pub const Error = incident.ServiceError || artifact.Error || std.mem.Allocator.Error || error{
    PipeFailed,
    ThreadFailed,
    InvalidAuthority,
    WakeFailed,
    ClockFailed,
};

pub const ShutdownResult = enum(u8) {
    joined = 1,
    detached = 2,
    degraded_joined = 3,
    degraded_detached = 4,
};
const Lifecycle = enum(u8) { pristine = 0, ready = 1, stopping = 2, detached = 3 };
const shutdown_deadline_ms: i32 = 200;
var next_publication_owner_generation = std.atomic.Value(u64).init(1);

pub const ConnectionIncidentRuntime = struct {
    allocator: std.mem.Allocator,
    self_addr: usize = 0,
    pid: u64 = 0,
    process_nonce: u64 = 0,
    runtime_generation: u64 = 0,
    service_generation: u64 = 0,
    publisher_registry_addr: u64 = 0,
    publisher_registry_generation: u64 = 0,
    wake_read_fd: c.fd_t = -1,
    wake_write_fd: c.fd_t = -1,
    completion_read_fd: c.fd_t = -1,
    completion_write_fd: c.fd_t = -1,
    lifecycle: std.atomic.Value(u8) = .init(@intFromEnum(Lifecycle.pristine)),
    writer_started: std.atomic.Value(u8) = .init(0),
    writer_completed: std.atomic.Value(u8) = .init(0),
    writer_failed: std.atomic.Value(u8) = .init(0),
    thread: ?std.Thread = null,
    service: incident.ConnectionIncidentService = .{},
    store: artifact.IncidentArtifactStore = .{},
    testing_block_writer: if (builtin.is_test) std.atomic.Value(u8) else void = if (builtin.is_test) .init(0) else {},
    testing_shutdown_clock_failure: if (builtin.is_test) std.atomic.Value(u8) else void = if (builtin.is_test) .init(0) else {},

    const testing = if (builtin.is_test) struct {
        var fatal_marker_fd: c_int = -1;
        threadlocal var publication_trace: ?*const fn (u8) void = null;
    } else struct {};

    pub const testing_api = if (builtin.is_test) struct {
        pub fn armPublicationTrace(trace: ?*const fn (u8) void) void {
            testing.publication_trace = trace;
        }

        pub fn exhaustServiceSequence(runtime: *ConnectionIncidentRuntime) void {
            runtime.service.last_issued_sequence = std.math.maxInt(u64);
        }

        pub fn restoreServiceSequence(runtime: *ConnectionIncidentRuntime, value: u64) void {
            runtime.service.last_issued_sequence = value;
        }

        pub fn markWriterFailed(runtime: *ConnectionIncidentRuntime) void {
            runtime.writer_failed.store(1, .release);
        }

        pub fn failNextShutdownClock(runtime: *ConnectionIncidentRuntime) void {
            runtime.testing_shutdown_clock_failure.store(1, .release);
        }
    } else struct {};

    fn tracePublication(stage: u8) void {
        if (builtin.is_test) if (testing.publication_trace) |trace| trace(stage);
    }

    pub fn create(
        allocator: std.mem.Allocator,
        pid: u64,
        process_nonce: u64,
        app_instance_nonce: u128,
        dir_fd: c.fd_t,
    ) Error!*ConnectionIncidentRuntime {
        if (pid == 0 or process_nonce == 0 or app_instance_nonce == 0 or pid != @as(u64, @intCast(c.getpid())))
            return error.InvalidAuthority;
        const self = try allocator.create(ConnectionIncidentRuntime);
        errdefer allocator.destroy(self);
        const runtime_generation = issuePublicationOwnerGeneration();
        const service_generation = issuePublicationOwnerGeneration();
        self.* = .{
            .allocator = allocator,
            .pid = pid,
            .process_nonce = process_nonce,
            .runtime_generation = runtime_generation,
            .service_generation = service_generation,
        };
        self.self_addr = @intFromPtr(self);
        try self.service.initInPlaceWithGeneration(pid, process_nonce, app_instance_nonce, service_generation);

        var wake_pipe: [2]c.fd_t = undefined;
        if (c.pipe(&wake_pipe) != 0) return error.PipeFailed;
        errdefer {
            for (wake_pipe) |fd| _ = c.close(fd);
        }
        var completion: [2]c.fd_t = undefined;
        if (c.pipe(&completion) != 0) return error.PipeFailed;
        errdefer {
            for (completion) |fd| _ = c.close(fd);
        }
        for (wake_pipe ++ completion) |fd| {
            if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) != 0) return error.PipeFailed;
        }
        const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
        const wake_flags = c.fcntl(wake_pipe[1], c.F.GETFL, @as(c_int, 0));
        const completion_flags = c.fcntl(completion[0], c.F.GETFL, @as(c_int, 0));
        if (wake_flags < 0 or completion_flags < 0 or
            c.fcntl(wake_pipe[1], c.F.SETFL, wake_flags | nonblocking) != 0 or
            c.fcntl(completion[0], c.F.SETFL, completion_flags | nonblocking) != 0)
            return error.PipeFailed;
        self.wake_read_fd = wake_pipe[0];
        self.wake_write_fd = wake_pipe[1];
        self.completion_read_fd = completion[0];
        self.completion_write_fd = completion[1];
        // caller FD의 성공·실패 소유권을 바꾸지 않는다. 내부 duplicate만 store에 넘겨야 thread spawn 실패와
        // caller rollback이 같은 descriptor를 두 번 닫지 않는다.
        const owned_dir_fd = c.dup(dir_fd);
        if (owned_dir_fd < 0) return error.PipeFailed;
        if (c.fcntl(owned_dir_fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) != 0) {
            _ = c.close(owned_dir_fd);
            return error.PipeFailed;
        }
        self.store.initInPlace(self.pid, self.process_nonce, self.service.self_addr, app_instance_nonce, owned_dir_fd) catch |err| {
            _ = c.close(owned_dir_fd);
            return err;
        };
        errdefer self.store.deinit();
        self.lifecycle.store(@intFromEnum(Lifecycle.ready), .release);
        self.thread = std.Thread.spawn(.{}, writerMain, .{self}) catch return error.ThreadFailed;
        return self;
    }

    fn publish(self: *ConnectionIncidentRuntime, input: incident.ConnectionIncident) Error!incident.PublishResult {
        if (!self.valid(.ready)) return error.InvalidAuthority;
        const result = self.service.publish(self.pid, self.process_nonce, input) catch |err| switch (err) {
            error.CounterExhausted => {
                if (builtin.is_test and testing.fatal_marker_fd >= 0) {
                    const marker = [_]u8{0x52};
                    _ = c.write(testing.fatal_marker_fd, &marker, marker.len);
                }
                process_seal.fatalIntegrity(.counter_exhausted);
            },
            else => return err,
        };
        try self.wake();
        return result;
    }

    /// Registry install projection은 final owner 자신만 발급한다.
    fn publisherProjection(self: *const ConnectionIncidentRuntime) Error!publisher_registry.RuntimeProjection {
        if (!self.valid(.ready) or self.runtime_generation == 0 or self.service_generation == 0 or
            self.service.self_addr != @intFromPtr(&self.service) or
            self.service.service_generation != self.service_generation)
            return error.InvalidAuthority;
        return .{
            .runtime_addr = self.self_addr,
            .runtime_generation = self.runtime_generation,
            .service_addr = self.service.self_addr,
            .service_generation = self.service_generation,
            .service_process_nonce = self.service.process_nonce,
            .app_instance_nonce = self.service.app_instance_nonce,
        };
    }

    /// Runtime 하나는 process-global publisher registry 하나에만 설치된다.
    pub fn installPublisherRegistry(
        self: *ConnectionIncidentRuntime,
        registry: *publisher_registry.Registry,
    ) Error!void {
        if (self.publisher_registry_addr != 0 or self.publisher_registry_generation != 0)
            return error.InvalidAuthority;
        registry.install(try self.publisherProjection()) catch return error.InvalidAuthority;
        if (registry.authority.runtime_addr != self.self_addr or registry.authority.runtime_generation != self.runtime_generation)
            process_seal.fatalIntegrity(.incident_authority);
        // registry publication 뒤에는 fallible/callback suffix가 없다. 두 backlink를 연속 게시해
        // caller rollback이 published runtime을 unpublished로 오인할 수 없게 한다.
        self.publisher_registry_addr = @intFromPtr(registry);
        self.publisher_registry_generation = registry.authority.registry_generation;
    }

    pub fn validatesPublisherLease(
        self: *const ConnectionIncidentRuntime,
        lease: publication.PublisherLeaseProjection,
    ) bool {
        const projection = self.publisherProjection() catch return false;
        return lease.lease_addr != 0 and lease.pid == self.pid and lease.process_nonce == self.process_nonce and
            lease.registry_addr == self.publisher_registry_addr and
            lease.registry_generation == self.publisher_registry_generation and
            lease.owner_thread == @as(u64, @intCast(std.Thread.getCurrentId())) and
            lease.runtime_addr == projection.runtime_addr and lease.runtime_generation == projection.runtime_generation and
            lease.service_addr == projection.service_addr and lease.service_generation == projection.service_generation;
    }

    pub fn prepareFirstPublication(
        self: *ConnectionIncidentRuntime,
        registry: *publisher_registry.Registry,
        lease: *const publisher_registry.IncidentPublisherLease,
        input: incident.ConnectionIncident,
        out: *incident.PreparedServicePublication,
    ) Error!void {
        const projection = registry.projectValidatedLease(lease) catch return error.InvalidAuthority;
        if (!self.validatesPublisherLease(projection)) return error.InvalidAuthority;
        try self.service.prepareFirstPublication(self.pid, self.process_nonce, input, out);
    }

    pub fn prepareRepeatPublication(
        self: *ConnectionIncidentRuntime,
        registry: *publisher_registry.Registry,
        lease: *const publisher_registry.IncidentPublisherLease,
        input: incident.ConnectionIncident,
        out: *incident.PreparedServicePublication,
    ) Error!void {
        const projection = registry.projectValidatedLease(lease) catch return error.InvalidAuthority;
        if (!self.validatesPublisherLease(projection)) return error.InvalidAuthority;
        try self.service.prepareRepeatPublication(self.pid, self.process_nonce, input, out);
    }

    pub fn abortPreparedPublication(
        self: *ConnectionIncidentRuntime,
        registry: *publisher_registry.Registry,
        lease: *const publisher_registry.IncidentPublisherLease,
        prepared: *incident.PreparedServicePublication,
    ) Error!void {
        const projection = registry.projectValidatedLease(lease) catch return error.InvalidAuthority;
        if (!self.validatesPublisherLease(projection)) return error.InvalidAuthority;
        try self.service.abortPreparedPublication(self.pid, self.process_nonce, prepared);
    }

    pub fn commitPreparedEvidenceChecked(
        self: *ConnectionIncidentRuntime,
        registry: *publisher_registry.Registry,
        lease: *const publisher_registry.IncidentPublisherLease,
        prepared: *incident.PreparedServicePublication,
    ) void {
        const projection = registry.projectValidatedLease(lease) catch process_seal.fatalIntegrity(.incident_authority);
        if (!self.validatesPublisherLease(projection)) process_seal.fatalIntegrity(.incident_authority);
        if (!self.service.commitPreparedEvidenceChecked(self.pid, self.process_nonce, prepared))
            process_seal.fatalIntegrity(.incident_authority);
    }

    pub fn commitPreparedRepeatEvidenceChecked(
        self: *ConnectionIncidentRuntime,
        registry: *publisher_registry.Registry,
        lease: *const publisher_registry.IncidentPublisherLease,
        prepared: *incident.PreparedServicePublication,
    ) void {
        const projection = registry.projectValidatedLease(lease) catch process_seal.fatalIntegrity(.incident_authority);
        if (!self.validatesPublisherLease(projection)) process_seal.fatalIntegrity(.incident_authority);
        if (!self.service.commitPreparedRepeatEvidenceChecked(self.pid, self.process_nonce, prepared))
            process_seal.fatalIntegrity(.incident_authority);
    }

    pub fn publishPreparedPendingAndUnlockChecked(
        self: *ConnectionIncidentRuntime,
        registry: *publisher_registry.Registry,
        lease: *const publisher_registry.IncidentPublisherLease,
        prepared: *incident.PreparedServicePublication,
    ) void {
        const projection = registry.projectValidatedLease(lease) catch process_seal.fatalIntegrity(.incident_authority);
        if (!self.validatesPublisherLease(projection)) process_seal.fatalIntegrity(.incident_authority);
        if (!self.service.publishPreparedPendingAndUnlockChecked(self.pid, self.process_nonce, prepared))
            process_seal.fatalIntegrity(.incident_authority);
    }

    pub fn wakeCommittedPublication(
        self: *ConnectionIncidentRuntime,
        registry: *publisher_registry.Registry,
        lease: *const publisher_registry.IncidentPublisherLease,
        prepared: *const publication.PreparedIncidentPublication,
    ) publication.WakeOutcome {
        const projection = registry.projectValidatedLease(lease) catch process_seal.fatalIntegrity(.incident_authority);
        if (!self.validatesPublisherLease(projection) or prepared.self_addr != @intFromPtr(prepared) or
            prepared.lifecycle_raw != @intFromEnum(publication.PublicationLifecycle.wake_ready) or
            !std.meta.eql(prepared.publisher, projection) or !validPreparedCompositeSeal(prepared))
            process_seal.fatalIntegrity(.incident_authority);
        const outcome = self.wakeOutcome();
        tracePublication(1); // committed publication wake observed
        return outcome;
    }

    /// 제품 teardown은 registry가 신규 lease를 닫고 기존 lease가 모두 정산됐음을 먼저 증명한다.
    pub fn shutdownPublished(
        self: *ConnectionIncidentRuntime,
        registry: *publisher_registry.Registry,
    ) Error!ShutdownResult {
        if (@intFromPtr(registry) != self.publisher_registry_addr or
            registry.authority.registry_generation != self.publisher_registry_generation or
            !(registry.beginClosing() catch return error.InvalidAuthority)) return error.InvalidAuthority;
        return self.shutdown();
    }

    /// Registry publication 전 bootstrap 실패만 회수한다. 게시된 runtime의 teardown 우회로는 사용할 수 없다.
    pub fn abortUnpublished(self: *ConnectionIncidentRuntime) Error!ShutdownResult {
        if (self.publisher_registry_addr != 0 or self.publisher_registry_generation != 0)
            return error.InvalidAuthority;
        return self.shutdown();
    }

    fn shutdown(self: *ConnectionIncidentRuntime) Error!ShutdownResult {
        if (!self.valid(.ready)) return error.InvalidAuthority;
        self.lifecycle.store(@intFromEnum(Lifecycle.stopping), .release);
        // wake pipe가 이미 깨졌어도 completion pipe는 writer 종료를 증명할 수 있다. 여기서 일찍 반환하면
        // joinable thread와 backing을 무기한 남기므로 실패를 기록하되 같은 bounded shutdown을 계속한다.
        self.wake() catch self.writer_failed.store(1, .release);
        const started = self.shutdownMonotonicMs() catch {
            self.writer_failed.store(1, .release);
            return self.detachWriter();
        };
        const deadline = std.math.add(u64, started, @intCast(shutdown_deadline_ms)) catch {
            self.writer_failed.store(1, .release);
            return self.detachWriter();
        };
        var poll_fd = c.pollfd{ .fd = self.completion_read_fd, .events = c.POLL.IN, .revents = 0 };
        while (true) {
            const now = self.shutdownMonotonicMs() catch {
                self.writer_failed.store(1, .release);
                return self.detachWriter();
            };
            if (now >= deadline) return self.detachWriter();
            const remaining: c_int = @intCast(deadline - now);
            const rc = c.poll(@ptrCast(&poll_fd), 1, remaining);
            if (rc > 0 and poll_fd.revents & c.POLL.IN != 0) {
                var marker: [1]u8 = undefined;
                const count = c.read(self.completion_read_fd, &marker, 1);
                if (count < 0 and (posix.errno(count) == .INTR or posix.errno(count) == .AGAIN)) continue;
                if (count != 1 or marker[0] != 1) {
                    self.writer_failed.store(1, .release);
                    return self.detachWriter();
                }
                const thread = self.thread orelse process_seal.fatalIntegrity(.incident_authority);
                self.thread = null;
                thread.join();
                const degraded = self.writer_failed.load(.acquire) != 0;
                self.destroyJoined();
                return if (degraded) .degraded_joined else .joined;
            }
            if (rc < 0 and posix.errno(rc) == .INTR) continue;
            if (rc < 0) {
                self.writer_failed.store(1, .release);
                return self.detachWriter();
            }
            if (rc > 0) self.writer_failed.store(1, .release);
            return self.detachWriter();
        }
    }

    fn writerMain(self: *ConnectionIncidentRuntime) void {
        if (@as(u64, @intCast(c.getpid())) != self.pid or self.self_addr != @intFromPtr(self)) return;
        self.writer_started.store(1, .release);
        while (true) {
            var marker: [32]u8 = undefined;
            const count = c.read(self.wake_read_fd, &marker, marker.len);
            if (count < 0 and posix.errno(count) == .INTR) continue;
            if (count <= 0) break;
            if (builtin.is_test) while (self.testing_block_writer.load(.acquire) != 0) {
                var delay = c.pollfd{ .fd = -1, .events = 0, .revents = 0 };
                _ = c.poll(@ptrCast(&delay), 0, 1);
            };
            while (true) {
                var handoff: incident.IncidentWriterHandoff = .{};
                const taken = self.service.takePendingForWriter(self.pid, self.process_nonce, &handoff) catch {
                    self.writer_failed.store(1, .release);
                    break;
                };
                if (taken == .inactive) break;
                const completion: incident.WriterCompletion = if (self.store.persist(self.pid, handoff)) |_| .persisted else |_| .failed;
                self.service.completeWriterHandoff(self.pid, self.process_nonce, handoff, completion) catch {
                    self.writer_failed.store(1, .release);
                    break;
                };
            }
            const state: Lifecycle = @enumFromInt(self.lifecycle.load(.acquire));
            if (state == .stopping or state == .detached) break;
        }
        self.writer_completed.store(1, .release);
        const done = [1]u8{1};
        _ = c.write(self.completion_write_fd, &done, 1);
    }

    fn wake(self: *ConnectionIncidentRuntime) Error!void {
        const marker = [1]u8{1};
        while (true) {
            const count = c.write(self.wake_write_fd, &marker, 1);
            if (count == 1) return;
            if (count < 0 and posix.errno(count) == .INTR) continue;
            if (count < 0 and posix.errno(count) == .AGAIN) return;
            self.writer_failed.store(1, .release);
            return error.WakeFailed;
        }
    }

    fn wakeOutcome(self: *ConnectionIncidentRuntime) publication.WakeOutcome {
        const marker = [1]u8{1};
        while (true) {
            const count = c.write(self.wake_write_fd, &marker, 1);
            if (count == 1) return .queued;
            if (count < 0 and posix.errno(count) == .INTR) continue;
            if (count < 0 and posix.errno(count) == .AGAIN) return .coalesced;
            self.writer_failed.store(1, .release);
            return .degraded;
        }
    }

    fn shutdownMonotonicMs(self: *ConnectionIncidentRuntime) Error!u64 {
        if (builtin.is_test and self.testing_shutdown_clock_failure.swap(0, .acq_rel) != 0)
            return error.ClockFailed;
        return monotonicMs();
    }

    fn valid(self: *const ConnectionIncidentRuntime, expected: Lifecycle) bool {
        return self.self_addr == @intFromPtr(self) and self.pid == @as(u64, @intCast(c.getpid())) and
            self.process_nonce != 0 and self.lifecycle.load(.acquire) == @intFromEnum(expected);
    }

    fn destroyJoined(self: *ConnectionIncidentRuntime) void {
        const allocator = self.allocator;
        self.store.deinit();
        for ([_]c.fd_t{ self.wake_read_fd, self.wake_write_fd, self.completion_read_fd, self.completion_write_fd }) |fd| {
            if (fd >= 0) _ = c.close(fd);
        }
        self.* = undefined;
        allocator.destroy(self);
    }

    fn detachWriter(self: *ConnectionIncidentRuntime) ShutdownResult {
        const thread = self.thread orelse process_seal.fatalIntegrity(.incident_authority);
        self.thread = null;
        self.lifecycle.store(@intFromEnum(Lifecycle.detached), .release);
        thread.detach();
        return if (self.writer_failed.load(.acquire) != 0) .degraded_detached else .detached;
    }
};

fn validPreparedCompositeSeal(value: *const publication.PreparedIncidentPublication) bool {
    const expected = process_seal.preparedIncidentPublicationSeal(value.publisher.pid, value.publisher.process_nonce, .{
        .self_addr = value.self_addr,
        .kind_raw = value.kind_raw,
        .lease_addr = value.publisher.lease_addr,
        .lease_generation = value.publisher.lease_generation,
        .lease_seal = value.publisher.seal,
        .runtime_generation = value.publisher.runtime_generation,
        .service_generation = value.publisher.service_generation,
        .service_token_addr = value.service.self_addr,
        .service_token_seal = value.service.seal,
        .service_lifecycle_raw = value.service.lifecycle_raw,
        .client_token_addr = value.client.self_addr,
        .client_token_seal = value.client.seal,
        .client_lifecycle_raw = value.client.lifecycle_raw,
        .input_digest = value.input_digest,
        .lifecycle_raw = value.lifecycle_raw,
    }) catch return false;
    return std.mem.eql(u8, &expected, &value.seal);
}

fn issuePublicationOwnerGeneration() u64 {
    while (true) {
        const value = next_publication_owner_generation.load(.acquire);
        if (value == 0 or value == std.math.maxInt(u64))
            process_seal.fatalIntegrity(.counter_exhausted);
        if (next_publication_owner_generation.cmpxchgWeak(value, value + 1, .acq_rel, .acquire) == null)
            return value;
    }
}

fn monotonicMs() Error!u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return error.ClockFailed;
    return @as(u64, @intCast(ts.sec)) * 1000 +
        @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn waitAtomic(value: *const std.atomic.Value(u8), expected: u8) !void {
    var attempts: usize = 0;
    while (value.load(.acquire) != expected and attempts < 2_000) : (attempts += 1) {
        var delay = c.pollfd{ .fd = -1, .events = 0, .revents = 0 };
        _ = c.poll(@ptrCast(&delay), 0, 1);
    }
    if (value.load(.acquire) != expected) return error.TestUnexpectedResult;
}

fn fixtureInput() incident.ConnectionIncident {
    return .{
        .flags = 0x05,
        .incident_id = .{ .app_instance_nonce = 0, .sequence = 0 },
        .timestamp_ns = 1,
        .host_id = 1,
        .host_adapter_generation = 1,
        .connection_generation = 1,
        .wire_major = 1,
        .reason_raw = @intFromEnum(incident.ConnectionReason.connection_eof),
        .scope_raw = @intFromEnum(incident.Scope.connection),
        .disposition_raw = @intFromEnum(incident.Disposition.reconnect),
        .source_site_raw = @intFromEnum(incident.SourceSite.client_read),
        .host_class_raw = @intFromEnum(incident.HostClass.current),
        .parser_phase_raw = @intFromEnum(incident.ParserPhase.idle),
        .outbound_phase_raw = @intFromEnum(incident.OutboundPhase.idle),
        .reserved0 = 0,
        .last_success_request_id = 0,
        .pending_request_count = 0,
        .pending_stream_count = 0,
        .pending_event_count = 0,
        .queue_item_count = 0,
        .queue_bytes = 0,
        .outbound_offset = 0,
        .outbound_length = 0,
        .controller_generation = 0,
        .upgrade_epoch = 0,
        .occurrence_count = 1,
        .first_timestamp_ns = 1,
        .last_timestamp_ns = 1,
        .reserved_tail = [_]u8{0} ** 18,
    };
}

test "CR0b 기록기 수명은 정확히 한 스레드가 실제 artifact를 저장하고 정상 join한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    const fd = c.dup(tmp.dir.handle);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)));
    const runtime = try ConnectionIncidentRuntime.create(std.testing.allocator, @intCast(c.getpid()), 9, 11, fd);
    try waitAtomic(&runtime.writer_started, 1);
    _ = try runtime.publish(fixtureInput());
    try std.testing.expectEqual(ShutdownResult.joined, try runtime.shutdown());
    var count: usize = 0;
    var iterator = tmp.dir.iterate();
    while (try iterator.next(std.testing.io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "CR0b 기록기 수명은 writer 실패 뒤 정상 join도 degraded outcome으로 보존한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    const fd = c.dup(tmp.dir.handle);
    try std.testing.expect(fd >= 0);
    const runtime = try ConnectionIncidentRuntime.create(std.testing.allocator, @intCast(c.getpid()), 19, 21, fd);
    try waitAtomic(&runtime.writer_started, 1);
    ConnectionIncidentRuntime.testing_api.markWriterFailed(runtime);
    try std.testing.expectEqual(ShutdownResult.degraded_joined, try runtime.shutdown());
}

test "CR0b 기록기 수명은 stopping clock 실패를 degraded detach로 보존한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    try std.testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    const fd = c.dup(tmp.dir.handle);
    try std.testing.expect(fd >= 0);
    const runtime = try ConnectionIncidentRuntime.create(std.heap.page_allocator, @intCast(c.getpid()), 29, 31, fd);
    runtime.testing_block_writer.store(1, .release);
    ConnectionIncidentRuntime.testing_api.failNextShutdownClock(runtime);
    try std.testing.expectEqual(ShutdownResult.degraded_detached, try runtime.shutdown());
    try std.testing.expectEqual(@intFromEnum(Lifecycle.detached), runtime.lifecycle.load(.acquire));
    runtime.testing_block_writer.store(0, .release);
    try waitAtomic(&runtime.writer_completed, 1);
    tmp.cleanup();
}

test "CR0b 기록기 수명은 completion poll 오류를 degraded detach로 보존한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    try std.testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    const fd = c.dup(tmp.dir.handle);
    try std.testing.expect(fd >= 0);
    const runtime = try ConnectionIncidentRuntime.create(std.heap.page_allocator, @intCast(c.getpid()), 39, 41, fd);
    runtime.testing_block_writer.store(1, .release);
    _ = c.close(runtime.completion_read_fd);
    try std.testing.expectEqual(ShutdownResult.degraded_detached, try runtime.shutdown());
    try std.testing.expectEqual(@intFromEnum(Lifecycle.detached), runtime.lifecycle.load(.acquire));
    runtime.testing_block_writer.store(0, .release);
    try waitAtomic(&runtime.writer_completed, 1);
    tmp.cleanup();
}

test "CR0b 기록기 수명은 막힌 스레드를 200 ms 뒤 detach하고 backing을 보존한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    try std.testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    const fd = c.dup(tmp.dir.handle);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)));
    const runtime = try ConnectionIncidentRuntime.create(std.heap.page_allocator, @intCast(c.getpid()), 9, 11, fd);
    runtime.testing_block_writer.store(1, .release);
    _ = try runtime.publish(fixtureInput());
    try std.testing.expectEqual(ShutdownResult.detached, try runtime.shutdown());
    try std.testing.expectEqual(@intFromEnum(Lifecycle.detached), runtime.lifecycle.load(.acquire));
    runtime.testing_block_writer.store(0, .release);
    try waitAtomic(&runtime.writer_completed, 1);
    tmp.cleanup();
}

test "CR0b 기록기 수명은 fork child를 pipe와 service 접근 전에 거부한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    const fd = c.dup(tmp.dir.handle);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)));
    const runtime = try ConnectionIncidentRuntime.create(std.testing.allocator, @intCast(c.getpid()), 9, 11, fd);
    const pid = c.fork();
    if (pid < 0) return error.SkipZigTest;
    if (pid == 0) {
        _ = runtime.publish(fixtureInput()) catch |err| c._exit(if (err == error.InvalidAuthority) 73 else 74);
        c._exit(75);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(pid, c.waitpid(pid, &status, 0));
    const wait_status: u32 = @bitCast(status);
    try std.testing.expect(c.W.IFEXITED(wait_status));
    try std.testing.expectEqual(@as(u8, 73), c.W.EXITSTATUS(wait_status));
    try std.testing.expectEqual(ShutdownResult.joined, try runtime.shutdown());
}

test "CR0b 기록기 수명은 aggregate exhaustion을 제품 fatal leaf로 닫는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), c.fchmod(tmp.dir.handle, 0o700));
    const fd = c.dup(tmp.dir.handle);
    try std.testing.expect(fd >= 0);
    const runtime = try ConnectionIncidentRuntime.create(std.testing.allocator, @intCast(c.getpid()), 9, 11, fd);
    try waitAtomic(&runtime.writer_started, 1);
    runtime.service.ring.aggregate_generations[0] = std.math.maxInt(u64);
    var marker_pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&marker_pipe));
    ConnectionIncidentRuntime.testing.fatal_marker_fd = marker_pipe[1];
    const child = c.fork();
    if (child < 0) {
        ConnectionIncidentRuntime.testing.fatal_marker_fd = -1;
        _ = c.close(marker_pipe[0]);
        _ = c.close(marker_pipe[1]);
        return error.TestUnexpectedResult;
    }
    if (child == 0) {
        _ = c.close(marker_pipe[0]);
        runtime.pid = @intCast(c.getpid());
        runtime.service.pid = runtime.pid;
        _ = runtime.publish(fixtureInput()) catch c._exit(74);
        c._exit(75);
    }
    ConnectionIncidentRuntime.testing.fatal_marker_fd = -1;
    _ = c.close(marker_pipe[1]);
    var status: c_int = 0;
    var attempts: usize = 0;
    while (attempts < 2000) : (attempts += 1) {
        const waited = c.waitpid(child, &status, c.W.NOHANG);
        if (waited == child) break;
        if (waited < 0) {
            _ = c.kill(child, c.SIG.KILL);
            _ = c.waitpid(child, &status, 0);
            _ = c.close(marker_pipe[0]);
            return error.TestUnexpectedResult;
        }
        var delay = [_]c.pollfd{};
        _ = c.poll(&delay, 0, 1);
    } else {
        _ = c.kill(child, c.SIG.KILL);
        _ = c.waitpid(child, &status, 0);
        _ = c.close(marker_pipe[0]);
        return error.TestUnexpectedResult;
    }
    var marker: [2]u8 = undefined;
    const marker_count = c.read(marker_pipe[0], &marker, marker.len);
    _ = c.close(marker_pipe[0]);
    try std.testing.expectEqual(@as(isize, 1), marker_count);
    try std.testing.expectEqual(@as(u8, 0x52), marker[0]);
    const wait_status: u32 = @bitCast(status);
    try std.testing.expect(c.W.IFEXITED(wait_status));
    try std.testing.expectEqual(@as(u8, 86), c.W.EXITSTATUS(wait_status));
    try std.testing.expectEqual(@as(u64, 0), runtime.service.last_issued_sequence);
    try std.testing.expectEqual(@as(u128, 0), runtime.service.pending_slots);
    try std.testing.expectEqual(ShutdownResult.joined, try runtime.shutdown());
}
