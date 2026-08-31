//! P4 E3c ReleaseFast GUI client-side idle-pump product artifact.

const std = @import("std");
const maru = @import("maru");
const session_host = @import("session_host");
const mac = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/resource.h");
});

const c = std.c;
const posix = std.posix;
const runtime_counts = [_]u32{ 1, 10, 15, 100 };
const idle_frame_count: u32 = 60;
const frame_interval_us: c_uint = 16_667;
/// 마커 왕복을 몇 번 재는가. **p95 가 뜻을 가지려면 표본이 그만큼 있어야 한다** — 40 이면
/// nearest-rank p95 가 index 37 이라 가장 나쁜 둘을 버린다(`session_host_slow_observer_validator`
/// 가 같은 근거로 40 을 쓴다). 한 번만 재던 옛 판은 공유 러너의 스케줄링 한 번에 빨개졌다.
const marker_sample_count: usize = 40;
const artifact_path = "tests/artifacts/perf/session-host-client-idle-pump-macos.json";

extern "c" fn usleep(usec: c_uint) c_int;

const CpuSample = struct {
    monotonic_ns: u64,
    user_time_ns: u64,
    system_time_ns: u64,
};

const ScaleSample = struct {
    runtime_count: u32,
    frame_count: u32,
    observation_ns: u64,
    cpu_user_delta_ns: u64,
    cpu_system_delta_ns: u64,
    cpu_total_delta_ns: u64,
    selected_owner_count: u64,
    pump_delta_count: u64,
    timestamp_seal_count: u64,
    client_slot_registry_visit_count: u64,
    socket_read_attempt_count: u64,
    metadata_event_count: u64,
    screen_event_count: u64,
    ended_event_count: u64,
};

const Artifact = struct {
    schema: []const u8,
    scenario: []const u8,
    build_mode: []const u8,
    sample_api: []const u8,
    uses_generation_attachment: bool,
    max_owners_per_frame: u32,
    idle_frame_count: u32,
    scale_samples: []const ScaleSample,
    marker_runtime_count: u32,
    marker_target_output_events: u64,
    marker_sibling_output_events: u64,
    marker_sample_count: u32,
    marker_latency_samples_ns: []const u64,
    /// 회차마다 마커를 보기까지 돈 **프레임 턴 수**. 벽시계와 달리 **기계 속도와 무관**하다 —
    /// 러너가 느리면 턴 하나가 길어질 뿐 턴 수는 그대로다. 전달이 폴링으로 떨어지는 회귀는
    /// 여기서 턴 수가 뛴다.
    marker_frame_samples: []const u32,
    marker_readable_wake_count: u32,
    marker_timer_timeout_count: u32,
    marker_frame_count: u32,
    marker_max_frame_elapsed_ns: u64,
    marker_selected_owner_count: u64,
    marker_pump_delta_count: u64,
    marker_timestamp_seal_count: u64,
    host_reaped: bool,
    client_fds_closed: bool,
    socket_removed: bool,
    directory_removed: bool,
};

fn monotonicNow(io: std.Io) u64 {
    const value = std.Io.Clock.awake.now(io).nanoseconds;
    return if (value <= 0) 0 else @intCast(value);
}

fn cpuSample(io: std.Io) !CpuSample {
    var info: mac.rusage_info_v4 = undefined;
    if (mac.proc_pid_rusage(c.getpid(), mac.RUSAGE_INFO_V4, @ptrCast(&info)) != 0)
        return error.CpuSampleFailed;
    return .{
        .monotonic_ns = monotonicNow(io),
        .user_time_ns = info.ri_user_time,
        .system_time_ns = info.ri_system_time,
    };
}

fn waitReadableWake(fd: c.fd_t) !bool {
    var descriptor = [_]c.pollfd{.{
        .fd = fd,
        .events = c.POLL.IN | c.POLL.HUP | c.POLL.ERR,
        .revents = 0,
    }};
    while (true) {
        const result = c.poll(&descriptor, descriptor.len, 17);
        if (result > 0) return true;
        if (result == 0) return false;
        if (posix.errno(result) != .INTR) return error.MarkerWakePollFailed;
    }
}

fn runFrame(
    backend: *session_host.remote_term_backend.RemoteTermBackend,
    pumps: []maru.app.RuntimeEventPump,
) !struct { target: u64, siblings: u64, total: u64 } {
    backend.maintenanceEventTick();
    var target: u64 = 0;
    var siblings: u64 = 0;
    for (pumps, 0..) |*pump, index| {
        const summary = try pump.drainAvailable();
        if (summary.ended != null) return error.RuntimeEndedDuringEvidence;
        if (index == 0) target += summary.output_events else siblings += summary.output_events;
    }
    return .{ .target = target, .siblings = siblings, .total = target + siblings };
}

fn settle(
    owner: *session_host.client_idle_pump_evidence.Owner,
    backend: *session_host.remote_term_backend.RemoteTermBackend,
    pumps: []maru.app.RuntimeEventPump,
) !void {
    var consecutive: u32 = 0;
    var attempts: u32 = 0;
    while (attempts < 600 and consecutive < 30) : (attempts += 1) {
        try owner.reset();
        const frame = try runFrame(backend, pumps);
        const counters = try owner.snapshot();
        if (frame.total == 0 and counters.metadata_events == 0 and counters.ended_events == 0)
            consecutive += 1
        else
            consecutive = 0;
        _ = usleep(frame_interval_us);
    }
    if (consecutive != 30) return error.SettleDeadlineExceeded;
    try owner.reset();
}

fn writeArtifact(allocator: std.mem.Allocator, io: std.Io, artifact: Artifact) !void {
    try std.Io.Dir.cwd().createDirPath(io, "tests/artifacts/perf");
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{
        .writer = &output.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.write(artifact);
    try output.writer.writeByte('\n');
    const temp = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}.tmp.{d}",
        .{ artifact_path, c.getpid() },
        0,
    );
    defer allocator.free(temp);
    defer _ = c.unlink(temp.ptr);
    const fd = c.open(temp.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.ArtifactCreateFailed;
    var open = true;
    defer {
        if (open) _ = c.close(fd);
    }
    var offset: usize = 0;
    while (offset < output.written().len) {
        const written = c.write(fd, output.written()[offset..].ptr, output.written().len - offset);
        if (written < 0 and posix.errno(written) == .INTR) continue;
        if (written <= 0) return error.ArtifactWriteFailed;
        offset += @intCast(written);
    }
    if (c.close(fd) != 0) return error.ArtifactWriteFailed;
    open = false;
    const destination = try allocator.dupeZ(u8, artifact_path);
    defer allocator.free(destination);
    if (c.rename(temp.ptr, destination.ptr) != 0) return error.ArtifactRenameFailed;
}

test "P4 E3c actual generation-backed GUI client idle pump emits strict scale evidence" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.heap.smp_allocator;
    const io = std.testing.io;
    const RemoteTermBackend = session_host.remote_term_backend.RemoteTermBackend;
    const BackendTesting = RemoteTermBackend.testing_api;
    const HostAdapter = session_host.host_adapter.HostAdapter;

    try HostAdapter.initializeProcessRuntime();
    const fixture_lock_fd = c.open(
        "/tmp/maru-session-host-actual-fixture.lock",
        .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true },
        @as(c.mode_t, 0o600),
    );
    if (fixture_lock_fd < 0) return error.FixtureLockFailed;
    defer _ = c.close(fixture_lock_fd);
    if (c.flock(fixture_lock_fd, posix.LOCK.EX) != 0) return error.FixtureLockFailed;

    var dir_buffer: [256]u8 = undefined;
    const dir_path = try std.fmt.bufPrintZ(&dir_buffer, "/tmp/maru-sh-e3c-{d}", .{c.getpid()});
    var socket_buffer: [320]u8 = undefined;
    const socket_path = try std.fmt.bufPrintZ(&socket_buffer, "{s}/control.sock", .{dir_path});

    const host_pid = c.fork();
    if (host_pid < 0) return error.HostForkFailed;
    if (host_pid == 0) {
        _ = c.close(fixture_lock_fd);
        _ = c.setsid();
        const devnull = c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (devnull >= 0) {
            _ = c.dup2(devnull, 0);
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
            if (devnull > 2) _ = c.close(devnull);
        }
        var inherited_fd: c_int = 3;
        while (inherited_fd < 4096) : (inherited_fd += 1) _ = c.close(inherited_fd);
        session_host.daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        c._exit(0);
    }
    var host_reaped = false;
    defer if (!host_reaped) {
        _ = c.kill(host_pid, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(host_pid, &status, 0);
        _ = c.unlink(socket_path.ptr);
        std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    };

    var client_value: session_host.client.Client = connection: {
        var attempts: usize = 0;
        while (attempts < 250) : (attempts += 1) {
            if (session_host.client.Client.connect(allocator, socket_path, .gui)) |client|
                break :connection client
            else |_|
                _ = usleep(20_000);
        }
        return error.HostConnectDeadlineExceeded;
    };
    var pool = BackendTesting.EvidenceAdapterPool.init(allocator);
    const client_fd = client_value.fd;
    const host_id = try BackendTesting.evidenceAddOwnedClient(&pool, allocator, &client_value);
    try pool.setSpawnHost(host_id);

    const process_identity = HostAdapter.publicationProcessIdentity() orelse return error.ProcessIdentityUnavailable;
    const incident_dir_fd = c.open(dir_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true });
    if (incident_dir_fd < 0) return error.IncidentDirectoryUnavailable;
    defer _ = c.close(incident_dir_fd);
    var app_nonce_bytes: [16]u8 = undefined;
    c.arc4random_buf(&app_nonce_bytes, app_nonce_bytes.len);
    var app_nonce = std.mem.readInt(u128, &app_nonce_bytes, .little);
    if (app_nonce == 0) app_nonce = 1;
    var incident_owner: session_host.app_process_incident_owner.AppProcessIncidentOwner = .{};
    try incident_owner.ensureReady(allocator, incident_dir_fd, process_identity.process_nonce, app_nonce);
    try session_host.app_process_incident_owner.installPublicationPort(&incident_owner);

    var surface_runtime = maru.app.SurfaceRuntime.init(allocator);
    var backend = try RemoteTermBackend.initWithPool(allocator, io, &pool, &surface_runtime);
    const backend_api = backend.backend();
    var pumps: [100]maru.app.RuntimeEventPump = undefined;
    var samples: [runtime_counts.len]ScaleSample = undefined;
    var runtime_count: usize = 0;
    var generation_backed = true;
    var evidence_owner: session_host.client_idle_pump_evidence.Owner = undefined;
    evidence_owner.initInPlace();
    try session_host.client_idle_pump_evidence.install(&evidence_owner);

    for (runtime_counts, 0..) |target_count_u32, sample_index| {
        const target_count: usize = @intCast(target_count_u32);
        while (runtime_count < target_count) : (runtime_count += 1) {
            const handle: u64 = runtime_count + 1;
            _ = try backend_api.spawn(.{
                .handle = handle,
                .request = .{ .command = "/bin/cat", .size = .{ .cols = 40, .rows = 10 } },
                .size = .{ .cols = 40, .rows = 10 },
                .queue_capacity = 16,
            });
            _ = try backend_api.attach(handle, true);
            pumps[runtime_count] = try backend_api.pump(handle);
            generation_backed = generation_backed and BackendTesting.runtimeUsesGenerationAttachment(&backend, handle);
        }
        try settle(&evidence_owner, &backend, pumps[0..target_count]);
        const before = try cpuSample(io);
        var frame: u32 = 0;
        while (frame < idle_frame_count) : (frame += 1) {
            const result = try runFrame(&backend, pumps[0..target_count]);
            if (result.total != 0) return error.IdleScreenEventObserved;
            _ = usleep(frame_interval_us);
        }
        const after = try cpuSample(io);
        const counters = try evidence_owner.snapshot();
        samples[sample_index] = .{
            .runtime_count = target_count_u32,
            .frame_count = idle_frame_count,
            .observation_ns = after.monotonic_ns - before.monotonic_ns,
            .cpu_user_delta_ns = after.user_time_ns - before.user_time_ns,
            .cpu_system_delta_ns = after.system_time_ns - before.system_time_ns,
            .cpu_total_delta_ns = (after.user_time_ns - before.user_time_ns) +
                (after.system_time_ns - before.system_time_ns),
            .selected_owner_count = counters.selected_owners,
            .pump_delta_count = counters.pump_delta_entries,
            .timestamp_seal_count = counters.timestamp_seals,
            .client_slot_registry_visit_count = counters.client_slot_registry_visits,
            .socket_read_attempt_count = counters.socket_read_attempts,
            .metadata_event_count = counters.metadata_events,
            .screen_event_count = counters.screen_events,
            .ended_event_count = counters.ended_events,
        };
        try evidence_owner.reset();
    }

    try settle(&evidence_owner, &backend, &pumps);
    var wake_sources: [4]RemoteTermBackend.WakeSource = undefined;
    if (backend.wakeSources(&wake_sources) != 1) return error.InvalidWakeSourceInventory;
    const wake_fd = wake_sources[0].fd;
    if (wake_fd < 0) return error.InvalidWakeSourceInventory;
    // **마커 왕복을 여러 번 잰다.** 한 번만 재면 그 값 하나가 상한과 직접 대결하고, 공유 러너의
    // 스케줄링이 한 번 튀는 것과 제품이 느려진 것을 구별할 수 없다. 회차마다 `settle` 로 조용한
    // 상태에서 시작하고, 회차별 계수는 누적한다 — 아래 회계식은 그 누적에서도 성립한다
    // (회차마다 「마지막 프레임 빼고 한 번씩 기다렸다」이므로 합은 `frames - 회차 수`다).
    var marker_latencies: [marker_sample_count]u64 = undefined;
    var marker_frame_turns: [marker_sample_count]u32 = undefined;
    var marker_target: u64 = 0;
    var marker_siblings: u64 = 0;
    var marker_frames: u32 = 0;
    var marker_readable_wakes: u32 = 0;
    var marker_timer_timeouts: u32 = 0;
    var marker_max_frame_elapsed_ns: u64 = 0;
    var marker_selected_owners: u64 = 0;
    var marker_pump_deltas: u64 = 0;
    var marker_seals: u64 = 0;
    for (&marker_latencies, &marker_frame_turns) |*latency, *turns| {
        try settle(&evidence_owner, &backend, &pumps);
        const round_started = monotonicNow(io);
        try surface_runtime.writeInput(1, .{ .bytes = "MARU_E3C_MARKER\n" });
        var round_target: u64 = 0;
        var round_finished: u64 = 0;
        var round_frames: u32 = 0;
        while (round_frames < 120 and round_target == 0) : (round_frames += 1) {
            const frame_started = monotonicNow(io);
            const result = try runFrame(&backend, &pumps);
            marker_max_frame_elapsed_ns = @max(
                marker_max_frame_elapsed_ns,
                monotonicNow(io) - frame_started,
            );
            round_target += result.target;
            marker_siblings += result.siblings;
            if (round_target != 0) {
                round_finished = monotonicNow(io);
            } else if (try waitReadableWake(wake_fd)) {
                marker_readable_wakes += 1;
            } else {
                marker_timer_timeouts += 1;
            }
        }
        if (round_target == 0) return error.MarkerDeadlineExceeded;
        latency.* = round_finished - round_started;
        turns.* = round_frames;
        marker_target += round_target;
        marker_frames += round_frames;
        const round_counters = try evidence_owner.snapshot();
        marker_selected_owners += round_counters.selected_owners;
        marker_pump_deltas += round_counters.pump_delta_entries;
        marker_seals += round_counters.timestamp_seals;
    }

    try session_host.client_idle_pump_evidence.uninstall(&evidence_owner);
    backend.deinit();
    surface_runtime.deinit();
    pool.deinit();
    const client_fd_result = c.fcntl(client_fd, c.F.GETFD, @as(c_int, 0));
    const client_fds_closed = client_fd_result < 0 and posix.errno(client_fd_result) == .BADF;
    if (!client_fds_closed) return error.ClientFdCleanupFailed;
    try session_host.app_process_incident_owner.revokePublicationPort(&incident_owner);
    _ = try incident_owner.shutdown();

    _ = c.kill(host_pid, posix.SIG.TERM);
    var host_status: c_int = undefined;
    host_reaped = c.waitpid(host_pid, &host_status, 0) == host_pid;
    const unlink_result = c.unlink(socket_path.ptr);
    const socket_removed = unlink_result == 0 or posix.errno(unlink_result) == .NOENT;
    std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    const directory_removed = std.Io.Dir.cwd().access(io, dir_path, .{}) == error.FileNotFound;

    // Do not publish a stronger product-path claim than the runtime graph actually proved.
    if (!generation_backed) return error.LegacyAttachmentObserved;

    try writeArtifact(allocator, io, .{
        .schema = "maru.session-host-client-idle-pump-macos.v4",
        .scenario = "generation-backed-gui-client-idle-pump",
        .build_mode = "ReleaseFast",
        .sample_api = "proc_pid_rusage:RUSAGE_INFO_V4",
        .uses_generation_attachment = true,
        .max_owners_per_frame = 16,
        .idle_frame_count = idle_frame_count,
        .scale_samples = &samples,
        .marker_runtime_count = 100,
        .marker_target_output_events = marker_target,
        .marker_sibling_output_events = marker_siblings,
        .marker_sample_count = marker_latencies.len,
        .marker_latency_samples_ns = &marker_latencies,
        .marker_frame_samples = &marker_frame_turns,
        .marker_readable_wake_count = marker_readable_wakes,
        .marker_timer_timeout_count = marker_timer_timeouts,
        .marker_frame_count = marker_frames,
        .marker_max_frame_elapsed_ns = marker_max_frame_elapsed_ns,
        .marker_selected_owner_count = marker_selected_owners,
        .marker_pump_delta_count = marker_pump_deltas,
        .marker_timestamp_seal_count = marker_seals,
        .host_reaped = host_reaped,
        .client_fds_closed = client_fds_closed,
        .socket_removed = socket_removed,
        .directory_removed = directory_removed,
    });
}
