//! P5b2b2 ReleaseFast process driver.
//! 독립 fixture host, 실제 forkpty child, 3개 MRSH client, PID RSS와 private probe를
//! 한 run에서 묶고 성공 cleanup 뒤 exact JSON artifact를 쓴다.

const std = @import("std");
const session_host = @import("session_host");
const probe_wire = @import("slow_observer_probe");
const mac = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/proc_info.h");
});

const c = std.c;
const posix = std.posix;

extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn getdtablesize() c_int;
extern "c" fn arc4random_buf(buffer: *anyopaque, length: usize) void;
extern "c" fn usleep(usec: c_uint) c_int;

const schema_name = "maru.session-host-slow-observer-macos.v4";
const scenario_name = "slow-observer-real-pty-rss";
const build_mode = "ReleaseFast";
const sample_api = "proc_pid_rusage:RUSAGE_INFO_V4";
const mib: u64 = 1024 * 1024;
const workload_bytes_per_iteration: usize = 64 * 1024;
const workload_iterations_max: usize = 8;
const baseline_sample_count = 10;
const pressure_sample_count_min = 20;
const post_sample_count = 10;
const wake_sample_count = 7;
const idle_wake_observation_ms: u64 = 1_000;
const target_interval_us: c_uint = 20_000;
const deadline_ms: u64 = 30_000;
const sol_local: c_int = 0;
const local_peerpid: c_int = 2;

const RawSample = struct {
    monotonic_ns: u64,
    pid: u32,
    uid: u32,
    start_tvsec: u64,
    start_tvusec: u32,
    ri_resident_size: u64,
    ri_phys_footprint: u64,
    ri_proc_start_abstime: u64,
};

const WakeSample = struct {
    input_at_ns: u64,
    input_accepted_at_ns: u64,
    marker_at_ns: u64,
    end_to_end_latency_ns: u64,
    delivery_latency_ns: u64,
};

const IdleCpuSample = struct {
    monotonic_ns: u64,
    user_time_ns: u64,
    system_time_ns: u64,
};

const ScreenIdleScaleSample = struct {
    runtime_count: u32,
    observation_ns: u64,
    cpu_total_delta_ns: u64,
    snapshot_call_delta: u64,
    delta_call_delta: u64,
    owned_allocation_delta: u64,
    core_lock_acquisition_delta: u64,
    metadata_producer_visit_delta: u64,
    metadata_materialization_delta: u64,
    metadata_core_lock_acquisition_delta: u64,
};

const ProcessIdentity = struct {
    pid: c.pid_t,
    uid: u32,
    ppid: c.pid_t,
    start_tvsec: u64,
    start_tvusec: u32,
    start_abstime: u64 = 0,
};

const Artifact = struct {
    schema: []const u8,
    scenario: []const u8,
    build_mode: []const u8,
    sample_api: []const u8,
    run_nonce_hex: []const u8,
    host_pid: u32,
    host_uid: u32,
    host_start_tvsec: u64,
    host_start_tvusec: u32,
    host_ri_proc_start_abstime: u64,
    local_peer_pid: u32,
    waitpid_pid: u32,
    pty_child_pid: u32,
    pty_child_uid: u32,
    pty_child_start_tvsec: u64,
    pty_child_start_tvusec: u32,
    pty_child_ppid: u32,
    pty_child_identity_rechecked: bool,
    pty_probe_fds_closed: bool,
    controller_clients: u32,
    slow_observer_clients: u32,
    healthy_observer_clients: u32,
    total_admitted: u32,
    stale_admission_count: u32,
    slow_connection_id: u64,
    first_stall_connection_id: u64,
    effective_host_send_buffer_bytes: u64,
    effective_slow_receive_buffer_bytes: u64,
    workload_iterations: u64,
    workload_bytes_per_iteration: u64,
    pressure_generated_bytes: u64,
    marker_input_bytes: u64,
    baseline_pty_output_bytes: u64,
    final_pty_output_bytes: u64,
    pty_produced_bytes: u64,
    healthy_drained_bytes: u64,
    slow_eagain_count: u64,
    slow_pollout_absent_count: u64,
    stall_at_ns: u64,
    wake_sample_count: u64,
    wake_latency_min_ns: u64,
    wake_latency_median_ns: u64,
    wake_latency_max_ns: u64,
    wake_samples: []const WakeSample,
    idle_wake_observation_ns: u64,
    idle_wake_notify_delta: u64,
    idle_wake_published_delta: u64,
    idle_wake_coalesced_delta: u64,
    idle_wake_drain_delta: u64,
    idle_cpu_before: IdleCpuSample,
    idle_cpu_after: IdleCpuSample,
    idle_cpu_total_delta_ns: u64,
    observation_materializations: u64,
    observation_core_lock_acquisitions: u64,
    observation_core_lock_hold_total_ns: u64,
    observation_core_lock_hold_max_ns: u64,
    idle_observation_materialization_delta: u64,
    idle_observation_core_lock_acquisition_delta: u64,
    idle_observation_core_lock_hold_delta_ns: u64,
    metadata_sampler_visits: u64,
    metadata_sampler_changes: u64,
    metadata_sampler_failures: u64,
    metadata_producer_visits: u64,
    idle_metadata_producer_visit_delta: u64,
    screen_snapshot_calls: u64,
    screen_delta_calls: u64,
    screen_owned_allocations: u64,
    screen_core_lock_acquisitions: u64,
    idle_screen_snapshot_call_delta: u64,
    idle_screen_delta_call_delta: u64,
    idle_screen_owned_allocation_delta: u64,
    idle_screen_core_lock_acquisition_delta: u64,
    screen_idle_scale_samples: []const ScreenIdleScaleSample,
    metadata_change_runtime_count: u32,
    metadata_change_target_stream_count: u32,
    metadata_change_sampler_delta: u64,
    metadata_change_producer_visit_delta: u64,
    metadata_change_materialization_delta: u64,
    metadata_change_core_lock_acquisition_delta: u64,
    active_wake_notify_delta: u64,
    active_wake_published_delta: u64,
    active_wake_coalesced_delta: u64,
    active_wake_drain_delta: u64,
    controller_input_at_ns: u64,
    healthy_marker_at_ns: u64,
    healthy_progress_batches_before: u64,
    healthy_progress_batches_after: u64,
    baseline_reset_ack: bool,
    healthy_marker_matches_nonce: bool,
    sample_target_interval_ms: u64,
    pressure_sample_gap_max_ms: u64,
    settle_sample_gap_max_ms: u64,
    baseline_samples: []const RawSample,
    pressure_samples: []const RawSample,
    post_drain_samples: []const RawSample,
    baseline_rss_bytes: u64,
    peak_rss_bytes: u64,
    run_peak_rss_bytes: u64,
    post_drain_rss_bytes: u64,
    peak_delta_bytes: u64,
    run_peak_delta_bytes: u64,
    post_drain_delta_bytes: u64,
    baseline_ledger_resident_bytes: u64,
    global_ledger_cap_bytes: u64,
    projection_transient_cap_bytes: u64,
    allocator_slack_bytes: u64,
    analytic_cap_bytes: u64,
    peak_ledger_resident_bytes: u64,
    peak_ledger_shared_bytes: u64,
    peak_ledger_prepared_base_bytes: u64,
    peak_ledger_prepared_reclaim_bytes: u64,
    peak_ledger_slot_queue_bytes: u64,
    peak_ledger_slot_base_bytes: u64,
    peak_ledger_slot_control_bytes: u64,
    peak_ledger_slot_total_bytes: u64,
    final_ledger_resident_bytes: u64,
    final_ledger_shared_bytes: u64,
    final_ledger_prepared_base_bytes: u64,
    final_ledger_prepared_reclaim_bytes: u64,
    deadline_ms: u64,
    elapsed_ms: u64,
    child_reaped: bool,
    child_exit_status: i32,
    client_fds_closed: u32,
    final_active_clients: u32,
    host_graceful_stop: bool,
    host_reaped: bool,
    host_exit_status: i32,
    socket_removed: bool,
    directory_removed: bool,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var stage: []const u8 = "arguments";
    errdefer |err| std.debug.print(
        "session-host slow-observer stage '{s}' failed: {s}\n",
        .{ stage, @errorName(err) },
    );
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const host_exe_raw = args.next() orelse return error.MissingHostExecutable;
    const artifact_path = args.next() orelse return error.MissingArtifactPath;
    if (args.next() != null) return error.UnexpectedArgument;
    try invalidateArtifact(allocator, artifact_path);

    const started_ns = monotonicNow(init.io);
    const deadline_ns = started_ns + deadline_ms * std.time.ns_per_ms;
    var nonce_bytes: [16]u8 = undefined;
    arc4random_buf(&nonce_bytes, nonce_bytes.len);
    const nonce_hex = std.fmt.bytesToHex(nonce_bytes, .lower);
    var dir_buf: [160]u8 = undefined;
    const session_dir = try std.fmt.bufPrintZ(
        &dir_buf,
        "/tmp/maru-slow-observer-{d}-{s}",
        .{ c.getpid(), nonce_hex[0..12] },
    );
    if (c.mkdir(session_dir.ptr, 0o700) != 0) return error.SessionDirectoryCreateFailed;
    var socket_buf: [220]u8 = undefined;
    const socket_path = try std.fmt.bufPrintZ(&socket_buf, "{s}/host.sock", .{session_dir});
    var directory_exists = true;
    defer {
        if (directory_exists) cleanupSessionDirectory(session_dir, socket_path);
    }
    const host_exe = try allocator.dupeZ(u8, host_exe_raw);
    defer allocator.free(host_exe);

    var command_pair: [2]c.fd_t = undefined;
    var report_pair: [2]c.fd_t = undefined;
    if (c.socketpair(posix.AF.UNIX, posix.SOCK.DGRAM, 0, &command_pair) != 0)
        return error.ProbeSocketFailed;
    var command_pair_open = [2]bool{ true, true };
    errdefer {
        for (command_pair, 0..) |fd, index| {
            if (command_pair_open[index]) _ = c.close(fd);
        }
    }
    if (c.socketpair(posix.AF.UNIX, posix.SOCK.DGRAM, 0, &report_pair) != 0)
        return error.ProbeSocketFailed;
    var report_pair_open = [2]bool{ true, true };
    errdefer {
        for (report_pair, 0..) |fd, index| {
            if (report_pair_open[index]) _ = c.close(fd);
        }
    }
    const host_pid = try spawnFixtureHost(
        host_exe,
        session_dir,
        socket_path,
        command_pair[1],
        report_pair[1],
    );
    _ = c.close(command_pair[1]);
    command_pair_open[1] = false;
    _ = c.close(report_pair[1]);
    report_pair_open[1] = false;
    defer {
        if (command_pair_open[0]) {
            _ = c.close(command_pair[0]);
            command_pair_open[0] = false;
        }
    }
    defer {
        if (report_pair_open[0]) {
            _ = c.close(report_pair[0]);
            report_pair_open[0] = false;
        }
    }
    var host_reaped = false;
    defer {
        if (!host_reaped) stopAndReap(host_pid);
    }

    stage = "controller connect";
    var controller = try connectRetry(allocator, socket_path, deadline_ns, init.io);
    var controller_open = true;
    defer {
        if (controller_open) controller.deinit();
    }
    const peer_pid = try peerPid(controller.fd);
    if (peer_pid != host_pid) return error.UnexpectedHostProcess;
    const host_identity = try processIdentity(host_pid, true);
    var sequence: u64 = 1;

    stage = "runtime spawn";
    const spawn_response = try controller.call("runtime.spawn",
        \\{"argv":["/bin/sh","-c","if [ -e /dev/fd/3 ] || [ -e /dev/fd/4 ]; then exit 97; fi; /bin/stty -echo -onlcr -icrnl; printf 'MARU_PROBE_FDS_CLOSED\\nMARU_SLOW_OBSERVER_READY\\n'; exec /bin/cat"],"cols":80,"rows":24}
    );
    defer allocator.free(spawn_response);
    const runtime_id = session_host.client.extractRuntimeId(spawn_response) orelse
        return error.RuntimeSpawnFailed;
    const spawn_report = try probe(
        command_pair[0],
        report_pair[0],
        &sequence,
        .snapshot,
        deadline_ns,
        init.io,
    );
    if (spawn_report.live_child_pid <= 0) return error.RuntimePidUnavailable;
    const pty_pid: c.pid_t = spawn_report.live_child_pid;
    const pty_identity = try processIdentity(pty_pid, false);
    if (pty_identity.ppid != host_pid or pty_identity.uid != host_identity.uid)
        return error.PtyChildIdentityMismatch;

    stage = "controller attach";
    const controller_fd = controller.fd;
    const controller_stream = try attachRuntime(
        allocator,
        &controller,
        &runtime_id,
        "controller",
    );
    var controller_screen = session_host.screen_assembler.ScreenAssembler.initForCodec(
        allocator,
        controller.screen_codec_version,
    );
    defer controller_screen.deinit();
    stage = "controller snapshot";
    const controller_initial = try controller.readSnapshot(controller_stream);
    defer allocator.free(controller_initial);
    try controller_screen.applySnapshot(controller_initial);
    var controller_drained: u64 = controller_initial.len;

    stage = "slow connect";
    var slow = try connectRetry(allocator, socket_path, deadline_ns, init.io);
    var slow_open = true;
    defer {
        if (slow_open) slow.deinit();
    }
    const requested_receive: c_int = 4096;
    if (c.setsockopt(
        slow.fd,
        posix.SOL.SOCKET,
        posix.SO.RCVBUF,
        &requested_receive,
        @sizeOf(c_int),
    ) != 0) return error.SocketBufferConfigurationFailed;
    const effective_slow_receive = try socketBuffer(slow.fd, posix.SO.RCVBUF);
    const slow_fd = slow.fd;
    stage = "slow attach";
    const slow_stream = try attachRuntime(allocator, &slow, &runtime_id, "observer");
    stage = "slow snapshot";
    const slow_initial = try slow.readSnapshot(slow_stream);
    allocator.free(slow_initial);

    stage = "healthy connect";
    var healthy = try connectRetry(allocator, socket_path, deadline_ns, init.io);
    var healthy_open = true;
    const healthy_fd = healthy.fd;
    defer {
        if (healthy_open) healthy.deinit();
    }
    stage = "healthy attach";
    const healthy_stream = try attachRuntime(allocator, &healthy, &runtime_id, "observer");
    var healthy_screen = session_host.screen_assembler.ScreenAssembler.initForCodec(
        allocator,
        healthy.screen_codec_version,
    );
    defer healthy_screen.deinit();
    stage = "healthy snapshot";
    const healthy_initial = try healthy.readSnapshot(healthy_stream);
    defer allocator.free(healthy_initial);
    try healthy_screen.applySnapshot(healthy_initial);
    var healthy_drained: u64 = healthy_initial.len;
    stage = "ready marker";
    try waitForMarker(
        &healthy,
        healthy_stream,
        &healthy_screen,
        "MARU_SLOW_OBSERVER_READY",
        &healthy_drained,
        deadline_ns,
        init.io,
    );
    const pty_probe_fds_closed = screenContains(
        &healthy_screen,
        "MARU_PROBE_FDS_CLOSED",
    );
    if (!pty_probe_fds_closed) return error.ProbeFdLeakEvidenceMissing;

    stage = "output wake source settle";
    while (try pumpHealthy(
        &controller,
        controller_stream,
        &controller_screen,
        &controller_drained,
    )) {}
    while (try pumpHealthy(
        &healthy,
        healthy_stream,
        &healthy_screen,
        &healthy_drained,
    )) {}
    while (try slow.readStreamBatch(slow_stream)) |batch| batch.deinit();
    var settle_before = try probe(
        command_pair[0],
        report_pair[0],
        &sequence,
        .snapshot,
        deadline_ns,
        init.io,
    );
    var settled = false;
    var settle_attempts: usize = 0;
    while (settle_attempts < 4) : (settle_attempts += 1) {
        _ = usleep(600 * std.time.us_per_ms);
        while (try pumpHealthy(
            &controller,
            controller_stream,
            &controller_screen,
            &controller_drained,
        )) {}
        while (try pumpHealthy(
            &healthy,
            healthy_stream,
            &healthy_screen,
            &healthy_drained,
        )) {}
        while (try slow.readStreamBatch(slow_stream)) |batch| batch.deinit();
        const settle_after = try probe(
            command_pair[0],
            report_pair[0],
            &sequence,
            .snapshot,
            deadline_ns,
            init.io,
        );
        if (settle_after.observation_materializations == settle_before.observation_materializations and
            settle_after.metadata_producer_visits == settle_before.metadata_producer_visits and
            settle_after.observation_core_lock_acquisitions == settle_before.observation_core_lock_acquisitions and
            settle_after.observation_core_lock_hold_total_ns == settle_before.observation_core_lock_hold_total_ns and
            settle_after.output_wake_notify_attempts == settle_before.output_wake_notify_attempts and
            settle_after.output_wake_published_writes == settle_before.output_wake_published_writes and
            settle_after.output_wake_coalesced_writes == settle_before.output_wake_coalesced_writes and
            settle_after.output_wake_drain_turns == settle_before.output_wake_drain_turns and
            settle_after.screen_snapshot_calls == settle_before.screen_snapshot_calls and
            settle_after.screen_delta_calls == settle_before.screen_delta_calls and
            settle_after.screen_owned_allocations == settle_before.screen_owned_allocations and
            settle_after.screen_core_lock_acquisitions == settle_before.screen_core_lock_acquisitions)
        {
            settle_before = settle_after;
            settled = true;
            break;
        }
        settle_before = settle_after;
    }
    if (!settled) return error.ObservationSourceDidNotSettle;

    stage = "output wake idle observation";
    const idle_cpu_before = try takeIdleCpuSample(host_identity, init.io);
    const idle_wake_before = settle_before;
    const idle_wake_started_at = monotonicNow(init.io);
    _ = usleep(@intCast(idle_wake_observation_ms * std.time.us_per_ms));
    const idle_wake_after = try probe(
        command_pair[0],
        report_pair[0],
        &sequence,
        .snapshot,
        deadline_ns,
        init.io,
    );
    const idle_cpu_after = try takeIdleCpuSample(host_identity, init.io);
    const idle_wake_ended_at = monotonicNow(init.io);
    if (idle_wake_after.output_wake_notify_attempts != idle_wake_before.output_wake_notify_attempts or
        idle_wake_after.output_wake_published_writes != idle_wake_before.output_wake_published_writes or
        idle_wake_after.output_wake_coalesced_writes != idle_wake_before.output_wake_coalesced_writes or
        idle_wake_after.output_wake_drain_turns != idle_wake_before.output_wake_drain_turns)
        return error.IdleOutputWakeStorm;

    var scale_samples: [3]ScreenIdleScaleSample = undefined;
    scale_samples[0] = .{
        .runtime_count = 1,
        .observation_ns = idle_wake_ended_at - idle_wake_started_at,
        .cpu_total_delta_ns = (idle_cpu_after.user_time_ns - idle_cpu_before.user_time_ns) +
            (idle_cpu_after.system_time_ns - idle_cpu_before.system_time_ns),
        .snapshot_call_delta = idle_wake_after.screen_snapshot_calls - idle_wake_before.screen_snapshot_calls,
        .delta_call_delta = idle_wake_after.screen_delta_calls - idle_wake_before.screen_delta_calls,
        .owned_allocation_delta = idle_wake_after.screen_owned_allocations - idle_wake_before.screen_owned_allocations,
        .core_lock_acquisition_delta = idle_wake_after.screen_core_lock_acquisitions - idle_wake_before.screen_core_lock_acquisitions,
        .metadata_producer_visit_delta = idle_wake_after.metadata_producer_visits - idle_wake_before.metadata_producer_visits,
        .metadata_materialization_delta = idle_wake_after.observation_materializations - idle_wake_before.observation_materializations,
        .metadata_core_lock_acquisition_delta = idle_wake_after.observation_core_lock_acquisitions - idle_wake_before.observation_core_lock_acquisitions,
    };

    // Scale the same product host to 10 and 100 actual PTYs. Each runtime has one controller and
    // one observer stream; initial snapshots are consumed before the one-second steady window.
    var scale_runtime_ids: [100][32]u8 = undefined;
    scale_runtime_ids[0] = runtime_id;
    var scale_runtime_count: usize = 1;
    var scale_sample_index: usize = 1;
    while (scale_runtime_count < scale_runtime_ids.len) : (scale_runtime_count += 1) {
        stage = "screen idle scale spawn";
        const extra_spawn = try controller.call("runtime.spawn",
            \\{"argv":["/bin/cat"],"cols":80,"rows":24}
        );
        scale_runtime_ids[scale_runtime_count] = session_host.client.extractRuntimeId(extra_spawn) orelse
            return error.RuntimeSpawnFailed;
        allocator.free(extra_spawn);

        const extra_controller_stream = try attachRuntime(
            allocator,
            &controller,
            &scale_runtime_ids[scale_runtime_count],
            "controller",
        );
        const extra_controller_snapshot = try controller.readSnapshot(extra_controller_stream);
        allocator.free(extra_controller_snapshot);
        const extra_observer_stream = try attachRuntime(
            allocator,
            &healthy,
            &scale_runtime_ids[scale_runtime_count],
            "observer",
        );
        const extra_observer_snapshot = try healthy.readSnapshot(extra_observer_stream);
        allocator.free(extra_observer_snapshot);

        const reached_count = scale_runtime_count + 1;
        if (reached_count == 10 or reached_count == 100) {
            stage = if (reached_count == 10)
                "screen idle scale 10"
            else
                "screen idle scale 100";
            _ = usleep(600 * std.time.us_per_ms);
            const before = try probe(
                command_pair[0],
                report_pair[0],
                &sequence,
                .snapshot,
                deadline_ns,
                init.io,
            );
            const cpu_before = try takeIdleCpuSample(host_identity, init.io);
            const started_at = monotonicNow(init.io);
            _ = usleep(@intCast(idle_wake_observation_ms * std.time.us_per_ms));
            const after = try probe(
                command_pair[0],
                report_pair[0],
                &sequence,
                .snapshot,
                deadline_ns,
                init.io,
            );
            const cpu_after = try takeIdleCpuSample(host_identity, init.io);
            const ended_at = monotonicNow(init.io);
            scale_samples[scale_sample_index] = .{
                .runtime_count = @intCast(reached_count),
                .observation_ns = ended_at - started_at,
                .cpu_total_delta_ns = (cpu_after.user_time_ns - cpu_before.user_time_ns) +
                    (cpu_after.system_time_ns - cpu_before.system_time_ns),
                .snapshot_call_delta = after.screen_snapshot_calls - before.screen_snapshot_calls,
                .delta_call_delta = after.screen_delta_calls - before.screen_delta_calls,
                .owned_allocation_delta = after.screen_owned_allocations - before.screen_owned_allocations,
                .core_lock_acquisition_delta = after.screen_core_lock_acquisitions - before.screen_core_lock_acquisitions,
                .metadata_producer_visit_delta = after.metadata_producer_visits - before.metadata_producer_visits,
                .metadata_materialization_delta = after.observation_materializations - before.observation_materializations,
                .metadata_core_lock_acquisition_delta = after.observation_core_lock_acquisitions - before.observation_core_lock_acquisitions,
            };
            scale_sample_index += 1;
        }
    }
    if (scale_sample_index != scale_samples.len) return error.MissingScaleEvidence;

    stage = "metadata change scale 100";
    const metadata_change_before = try probe(
        command_pair[0],
        report_pair[0],
        &sequence,
        .snapshot,
        deadline_ns,
        init.io,
    );
    try sendInputBeforeDeadline(
        &controller,
        controller_stream,
        "MARU_E3B_METADATA_SCALE\n",
        deadline_ns,
        init.io,
    );
    var metadata_change_after = metadata_change_before;
    while (metadata_change_after.metadata_producer_visits < metadata_change_before.metadata_producer_visits + 3 or
        metadata_change_after.observation_materializations < metadata_change_before.observation_materializations + 1)
    {
        _ = try pumpHealthy(&controller, controller_stream, &controller_screen, &controller_drained);
        _ = try pumpHealthy(&healthy, healthy_stream, &healthy_screen, &healthy_drained);
        while (try slow.readStreamBatch(slow_stream)) |batch| batch.deinit();
        _ = usleep(2_000);
        metadata_change_after = try probe(
            command_pair[0],
            report_pair[0],
            &sequence,
            .snapshot,
            deadline_ns,
            init.io,
        );
        if (monotonicNow(init.io) >= deadline_ns) return error.MetadataChangeTimeout;
    }
    _ = usleep(50_000);
    metadata_change_after = try probe(
        command_pair[0],
        report_pair[0],
        &sequence,
        .snapshot,
        deadline_ns,
        init.io,
    );

    stage = "screen idle scale cleanup";
    var cleanup_index: usize = scale_runtime_ids.len;
    while (cleanup_index > 1) {
        cleanup_index -= 1;
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"runtime_id\":\"{s}\"}}",
            .{&scale_runtime_ids[cleanup_index]},
        );
        const response = try controller.call("runtime.terminate", params);
        allocator.free(params);
        allocator.free(response);
    }

    stage = "output wake latency";
    var wake_samples: [wake_sample_count]WakeSample = undefined;
    const wake_stages = [_][]const u8{
        "output wake latency 1/7",
        "output wake latency 2/7",
        "output wake latency 3/7",
        "output wake latency 4/7",
        "output wake latency 5/7",
        "output wake latency 6/7",
        "output wake latency 7/7",
    };
    for (&wake_samples, 0..) |*sample, sample_index| {
        stage = wake_stages[sample_index];
        var wake_marker_buf: [96]u8 = undefined;
        const wake_marker = try std.fmt.bufPrint(
            &wake_marker_buf,
            "\rMARU_CR6F_WAKE_{d}_{d}\n",
            .{ c.getpid(), sample_index },
        );
        const input_at = monotonicNow(init.io);
        try sendInputBeforeDeadline(
            &controller,
            controller_stream,
            wake_marker,
            deadline_ns,
            init.io,
        );
        const input_accepted_at = monotonicNow(init.io);
        try waitForMarker(
            &healthy,
            healthy_stream,
            &healthy_screen,
            wake_marker[1 .. wake_marker.len - 1],
            &healthy_drained,
            deadline_ns,
            init.io,
        );
        const marker_at = monotonicNow(init.io);
        sample.* = .{
            .input_at_ns = input_at,
            .input_accepted_at_ns = input_accepted_at,
            .marker_at_ns = marker_at,
            .end_to_end_latency_ns = marker_at - input_at,
            .delivery_latency_ns = marker_at - input_accepted_at,
        };
        while (try pumpHealthy(
            &controller,
            controller_stream,
            &controller_screen,
            &controller_drained,
        )) {}
        while (try slow.readStreamBatch(slow_stream)) |batch| batch.deinit();
    }
    const active_wake_after = try probe(
        command_pair[0],
        report_pair[0],
        &sequence,
        .snapshot,
        deadline_ns,
        init.io,
    );
    if (active_wake_after.output_wake_notify_attempts < idle_wake_after.output_wake_notify_attempts + wake_sample_count or
        active_wake_after.output_wake_published_writes < idle_wake_after.output_wake_published_writes + 1 or
        active_wake_after.output_wake_drain_turns < idle_wake_after.output_wake_drain_turns + 1)
        return error.OutputWakeEvidenceMissing;
    var wake_latencies: [wake_sample_count]u64 = undefined;
    for (wake_samples, 0..) |sample, index|
        wake_latencies[index] = sample.delivery_latency_ns;
    std.mem.sort(u64, &wake_latencies, {}, std.sort.asc(u64));

    stage = "pressure geometry resize";
    var resize_buf: [128]u8 = undefined;
    const resize_params = try std.fmt.bufPrint(
        &resize_buf,
        "{{\"stream_id\":{d},\"cols\":512,\"rows\":256,\"client_sequence\":1}}",
        .{controller_stream},
    );
    const resize_response = try controller.call("runtime.resize", resize_params);
    defer allocator.free(resize_response);
    if (std.mem.indexOf(u8, resize_response, "\"changed\":true") == null)
        return error.ResizeFailed;
    while (controller_screen.cols != 512 or controller_screen.rows_count != 256 or
        healthy_screen.cols != 512 or healthy_screen.rows_count != 256)
    {
        _ = try pumpHealthy(
            &controller,
            controller_stream,
            &controller_screen,
            &controller_drained,
        );
        _ = try pumpHealthy(
            &healthy,
            healthy_stream,
            &healthy_screen,
            &healthy_drained,
        );
        while (try slow.readStreamBatch(slow_stream)) |batch| batch.deinit();
        if (monotonicNow(init.io) >= deadline_ns) return error.ResizeTimeout;
        _ = usleep(2_000);
    }

    var baseline_samples: [baseline_sample_count]RawSample = undefined;
    for (&baseline_samples) |*sample| {
        sample.* = try takeSample(host_identity, init.io);
        // Resize/full-snapshot producer work is setup, not pressure. Keep every observer draining
        // throughout the RSS baseline so no residual write queue owns the later stall identity.
        _ = try pumpHealthy(
            &controller,
            controller_stream,
            &controller_screen,
            &controller_drained,
        );
        _ = try pumpHealthy(
            &healthy,
            healthy_stream,
            &healthy_screen,
            &healthy_drained,
        );
        while (try slow.readStreamBatch(slow_stream)) |batch| batch.deinit();
        _ = usleep(target_interval_us);
    }

    stage = "pressure reset";
    const reset_report = try probe(command_pair[0], report_pair[0], &sequence, .reset_stall, deadline_ns, init.io);
    if (@as(probe_wire.ReportKind, @enumFromInt(reset_report.kind)) != .reset_ack)
        return error.ProbeProtocolError;
    const baseline_pty_output = reset_report.pty_output_bytes;
    const baseline_ledger = reset_report.resident_bytes;
    // Resize/full snapshot/READY delivery is setup evidence. The post-baseline reset ACK is the
    // phase barrier, so only workload delivery can own pressure progress or first-stall telemetry.
    healthy_drained = 0;

    var pressure_samples: std.ArrayListUnmanaged(RawSample) = .empty;
    defer pressure_samples.deinit(allocator);
    try pressure_samples.append(allocator, try takeSample(host_identity, init.io));

    const healthy_progress_batches_before: u64 = 0;
    var healthy_progress_batches: u64 = 0;
    var generated_bytes: u64 = 0;
    var iterations: u64 = 0;
    var stall_report: ?probe_wire.Report = null;
    const payload = try allocator.alloc(u8, workload_bytes_per_iteration);
    defer allocator.free(payload);
    fillPayload(payload, nonce_bytes);
    stage = "pressure";
    while (iterations < workload_iterations_max and stall_report == null) {
        if (monotonicNow(init.io) >= deadline_ns) return error.DeadlineExceeded;
        stage = "pressure input";
        try sendInputBeforeDeadline(
            &controller,
            controller_stream,
            payload,
            deadline_ns,
            init.io,
        );
        generated_bytes += payload.len;
        iterations += 1;
        const before_progress = healthy_progress_batches;
        while (healthy_progress_batches == before_progress) {
            _ = try pumpHealthy(
                &controller,
                controller_stream,
                &controller_screen,
                &controller_drained,
            );
            stage = "pressure healthy drain";
            if (try pumpHealthy(
                &healthy,
                healthy_stream,
                &healthy_screen,
                &healthy_drained,
            )) healthy_progress_batches += 1;
            try maybeSample(allocator, &pressure_samples, host_identity, init.io);
            if (monotonicNow(init.io) >= deadline_ns) return error.DeadlineExceeded;
            _ = usleep(2_000);
        }
        stage = "pressure probe";
        const report = try probe(command_pair[0], report_pair[0], &sequence, .snapshot, deadline_ns, init.io);
        if (report.first_stall_ns != 0 and report.pollout_absent_count != 0)
            stall_report = report;
        try maybeSample(allocator, &pressure_samples, host_identity, init.io);
    }
    const stalled = stall_report orelse return error.SlowObserverDidNotStall;

    stage = "marker progress";
    const controller_input_at = monotonicNow(init.io);
    const marker = nonce_hex ++ "\n";
    try sendInputBeforeDeadline(
        &controller,
        controller_stream,
        marker,
        deadline_ns,
        init.io,
    );
    // marker를 읽기 전에 반드시 한 샘플을 남겨 strict-between 증거를 고정한다.
    try pressure_samples.append(allocator, try takeSample(host_identity, init.io));
    var marker_seen = false;
    var marker_at: u64 = 0;
    while (!marker_seen) {
        _ = try pumpHealthy(
            &controller,
            controller_stream,
            &controller_screen,
            &controller_drained,
        );
        if (try pumpHealthy(
            &healthy,
            healthy_stream,
            &healthy_screen,
            &healthy_drained,
        )) healthy_progress_batches += 1;
        marker_seen = screenContains(&healthy_screen, nonce_hex[0..]);
        if (marker_seen) {
            marker_at = monotonicNow(init.io);
            break;
        }
        try maybeSample(allocator, &pressure_samples, host_identity, init.io);
        if (monotonicNow(init.io) >= deadline_ns) return error.MarkerTimeout;
        _ = usleep(2_000);
    }
    while (pressure_samples.items.len < pressure_sample_count_min) {
        _ = pumpHealthy(
            &controller,
            controller_stream,
            &controller_screen,
            &controller_drained,
        ) catch {};
        _ = pumpHealthy(
            &healthy,
            healthy_stream,
            &healthy_screen,
            &healthy_drained,
        ) catch {};
        try maybeSample(allocator, &pressure_samples, host_identity, init.io);
        _ = usleep(target_interval_us);
    }
    if (pressure_samples.items[pressure_samples.items.len - 1].monotonic_ns < marker_at)
        try pressure_samples.append(allocator, try takeSample(host_identity, init.io));

    const marker_report = try probe(command_pair[0], report_pair[0], &sequence, .snapshot, deadline_ns, init.io);
    const final_pty_output = marker_report.pty_output_bytes;
    if (final_pty_output -| baseline_pty_output != generated_bytes + marker.len)
        return error.PtyByteAccountingMismatch;

    // reap 뒤 PID 숫자만 재검사하면 이미 identity를 잃는다. EOT 직전의 살아 있는
    // process instance를 다시 pin한 뒤 동일 PID의 실제 child-exit evidence를 기다린다.
    const pty_identity_rechecked = sameProcessIdentity(
        pty_identity,
        try processIdentity(pty_pid, false),
    );
    if (!pty_identity_rechecked) return error.PtyChildIdentityMismatch;
    // canonical-mode cat의 빈 입력 줄에서 Ctrl-D를 보내 정상 종료시킨다.
    try sendInputBeforeDeadline(
        &controller,
        controller_stream,
        "\x04",
        deadline_ns,
        init.io,
    );
    var child_report = marker_report;
    while (child_report.reaped_children == 0) {
        _ = pumpHealthy(
            &controller,
            controller_stream,
            &controller_screen,
            &controller_drained,
        ) catch {};
        _ = pumpHealthy(
            &healthy,
            healthy_stream,
            &healthy_screen,
            &healthy_drained,
        ) catch {};
        child_report = try probe(
            command_pair[0],
            report_pair[0],
            &sequence,
            .snapshot,
            deadline_ns,
            init.io,
        );
        if (monotonicNow(init.io) >= deadline_ns) return error.ChildReapTimeout;
        _ = usleep(2_000);
    }
    controller.deinit();
    controller_open = false;
    slow.deinit();
    slow_open = false;
    healthy.deinit();
    healthy_open = false;
    const client_fds_closed = countClosedFds(&.{ controller_fd, slow_fd, healthy_fd });
    if (client_fds_closed != 3) return error.ClientFdCleanupFailed;

    var final_report = child_report;
    while (final_report.active_clients != 0 or final_report.resident_bytes != 0 or
        final_report.shared_bytes != 0 or final_report.prepared_base_bytes != 0 or
        final_report.prepared_reclaim_bytes != 0)
    {
        final_report = try probe(
            command_pair[0],
            report_pair[0],
            &sequence,
            .snapshot,
            deadline_ns,
            init.io,
        );
        if (monotonicNow(init.io) >= deadline_ns) return error.LedgerDrainTimeout;
        _ = usleep(2_000);
    }

    var post_samples: [post_sample_count]RawSample = undefined;
    for (&post_samples) |*sample| {
        sample.* = try takeSample(host_identity, init.io);
        _ = usleep(target_interval_us);
    }

    const stop_report = try probe(command_pair[0], report_pair[0], &sequence, .stop, deadline_ns, init.io);
    if (@as(probe_wire.ReportKind, @enumFromInt(stop_report.kind)) != .stop_ack)
        return error.ProbeProtocolError;
    _ = c.close(command_pair[0]);
    command_pair_open[0] = false;
    _ = c.close(report_pair[0]);
    report_pair_open[0] = false;

    var host_status: c_int = undefined;
    const waited = waitExact(host_pid, &host_status, deadline_ns, init.io);
    if (waited != host_pid) return error.HostReapFailed;
    host_reaped = true;
    const host_exit_status = exitStatus(host_status);
    const socket_access = c.access(socket_path.ptr, c.F_OK);
    const socket_removed = socket_access != 0 and posix.errno(socket_access) == .NOENT;
    if (!socket_removed) return error.SocketCleanupFailed;
    stage = "directory cleanup";
    try unlinkSessionLeaf(session_dir, "owner-v2.lock");
    try removeSessionDirectoryLeaf(session_dir, "incidents");
    if (!removeDirectoryRetry(session_dir, 100)) return error.SessionDirectoryCleanupFailed;
    directory_exists = false;

    const baseline_rss = medianRss(&baseline_samples);
    const pressure_peak = maxRss(pressure_samples.items);
    const post_rss = medianRss(&post_samples);
    const run_peak = @max(pressure_peak, @max(maxRss(&baseline_samples), maxRss(&post_samples)));
    const projection_transient: u64 =
        2 * session_host.connection_slot.base_update_max_bytes;
    const allocator_slack: u64 = 64 * mib;
    const ledger_delta = marker_report.peak_resident_bytes -| baseline_ledger;
    const analytic_cap = ledger_delta + projection_transient + allocator_slack;
    const elapsed_ms = (monotonicNow(init.io) - started_ns) / std.time.ns_per_ms;
    const artifact: Artifact = .{
        .schema = schema_name,
        .scenario = scenario_name,
        .build_mode = build_mode,
        .sample_api = sample_api,
        .run_nonce_hex = nonce_hex[0..],
        .host_pid = @intCast(host_pid),
        .host_uid = host_identity.uid,
        .host_start_tvsec = host_identity.start_tvsec,
        .host_start_tvusec = host_identity.start_tvusec,
        .host_ri_proc_start_abstime = host_identity.start_abstime,
        .local_peer_pid = @intCast(peer_pid),
        .waitpid_pid = @intCast(waited),
        .pty_child_pid = @intCast(pty_pid),
        .pty_child_uid = pty_identity.uid,
        .pty_child_start_tvsec = pty_identity.start_tvsec,
        .pty_child_start_tvusec = pty_identity.start_tvusec,
        .pty_child_ppid = @intCast(pty_identity.ppid),
        .pty_child_identity_rechecked = pty_identity_rechecked,
        .pty_probe_fds_closed = pty_probe_fds_closed,
        .controller_clients = 1,
        .slow_observer_clients = 1,
        .healthy_observer_clients = 1,
        .total_admitted = @intCast(stalled.total_admitted),
        .stale_admission_count = @intCast(stalled.stale_client_observations),
        .slow_connection_id = 2,
        .first_stall_connection_id = stalled.first_stall_connection_id,
        .effective_host_send_buffer_bytes = stalled.first_stall_send_buffer_bytes,
        .effective_slow_receive_buffer_bytes = @intCast(effective_slow_receive),
        .workload_iterations = iterations,
        .workload_bytes_per_iteration = workload_bytes_per_iteration,
        .pressure_generated_bytes = generated_bytes,
        .marker_input_bytes = marker.len,
        .baseline_pty_output_bytes = baseline_pty_output,
        .final_pty_output_bytes = final_pty_output,
        .pty_produced_bytes = final_pty_output - baseline_pty_output,
        .healthy_drained_bytes = healthy_drained,
        .slow_eagain_count = 0,
        .slow_pollout_absent_count = stalled.pollout_absent_count,
        .stall_at_ns = stalled.first_stall_ns,
        .wake_sample_count = wake_sample_count,
        .wake_latency_min_ns = wake_latencies[0],
        .wake_latency_median_ns = wake_latencies[wake_sample_count / 2],
        .wake_latency_max_ns = wake_latencies[wake_sample_count - 1],
        .wake_samples = &wake_samples,
        .idle_wake_observation_ns = idle_wake_ended_at - idle_wake_started_at,
        .idle_wake_notify_delta = idle_wake_after.output_wake_notify_attempts - idle_wake_before.output_wake_notify_attempts,
        .idle_wake_published_delta = idle_wake_after.output_wake_published_writes - idle_wake_before.output_wake_published_writes,
        .idle_wake_coalesced_delta = idle_wake_after.output_wake_coalesced_writes - idle_wake_before.output_wake_coalesced_writes,
        .idle_wake_drain_delta = idle_wake_after.output_wake_drain_turns - idle_wake_before.output_wake_drain_turns,
        .idle_cpu_before = idle_cpu_before,
        .idle_cpu_after = idle_cpu_after,
        .idle_cpu_total_delta_ns = (idle_cpu_after.user_time_ns - idle_cpu_before.user_time_ns) +
            (idle_cpu_after.system_time_ns - idle_cpu_before.system_time_ns),
        .observation_materializations = final_report.observation_materializations,
        .observation_core_lock_acquisitions = final_report.observation_core_lock_acquisitions,
        .observation_core_lock_hold_total_ns = final_report.observation_core_lock_hold_total_ns,
        .observation_core_lock_hold_max_ns = final_report.observation_core_lock_hold_max_ns,
        .idle_observation_materialization_delta = idle_wake_after.observation_materializations - idle_wake_before.observation_materializations,
        .idle_observation_core_lock_acquisition_delta = idle_wake_after.observation_core_lock_acquisitions - idle_wake_before.observation_core_lock_acquisitions,
        .idle_observation_core_lock_hold_delta_ns = idle_wake_after.observation_core_lock_hold_total_ns - idle_wake_before.observation_core_lock_hold_total_ns,
        .metadata_sampler_visits = final_report.metadata_sampler_visits,
        .metadata_sampler_changes = final_report.metadata_sampler_changes,
        .metadata_sampler_failures = final_report.metadata_sampler_failures,
        .metadata_producer_visits = final_report.metadata_producer_visits,
        .idle_metadata_producer_visit_delta = idle_wake_after.metadata_producer_visits - idle_wake_before.metadata_producer_visits,
        .screen_snapshot_calls = final_report.screen_snapshot_calls,
        .screen_delta_calls = final_report.screen_delta_calls,
        .screen_owned_allocations = final_report.screen_owned_allocations,
        .screen_core_lock_acquisitions = final_report.screen_core_lock_acquisitions,
        .idle_screen_snapshot_call_delta = idle_wake_after.screen_snapshot_calls - idle_wake_before.screen_snapshot_calls,
        .idle_screen_delta_call_delta = idle_wake_after.screen_delta_calls - idle_wake_before.screen_delta_calls,
        .idle_screen_owned_allocation_delta = idle_wake_after.screen_owned_allocations - idle_wake_before.screen_owned_allocations,
        .idle_screen_core_lock_acquisition_delta = idle_wake_after.screen_core_lock_acquisitions - idle_wake_before.screen_core_lock_acquisitions,
        .screen_idle_scale_samples = &scale_samples,
        .metadata_change_runtime_count = 100,
        .metadata_change_target_stream_count = 3,
        .metadata_change_sampler_delta = metadata_change_after.metadata_sampler_changes - metadata_change_before.metadata_sampler_changes,
        .metadata_change_producer_visit_delta = metadata_change_after.metadata_producer_visits - metadata_change_before.metadata_producer_visits,
        .metadata_change_materialization_delta = metadata_change_after.observation_materializations - metadata_change_before.observation_materializations,
        .metadata_change_core_lock_acquisition_delta = metadata_change_after.observation_core_lock_acquisitions - metadata_change_before.observation_core_lock_acquisitions,
        .active_wake_notify_delta = active_wake_after.output_wake_notify_attempts - idle_wake_after.output_wake_notify_attempts,
        .active_wake_published_delta = active_wake_after.output_wake_published_writes - idle_wake_after.output_wake_published_writes,
        .active_wake_coalesced_delta = active_wake_after.output_wake_coalesced_writes - idle_wake_after.output_wake_coalesced_writes,
        .active_wake_drain_delta = active_wake_after.output_wake_drain_turns - idle_wake_after.output_wake_drain_turns,
        .controller_input_at_ns = controller_input_at,
        .healthy_marker_at_ns = marker_at,
        .healthy_progress_batches_before = healthy_progress_batches_before,
        .healthy_progress_batches_after = healthy_progress_batches,
        .baseline_reset_ack = true,
        .healthy_marker_matches_nonce = marker_seen,
        .sample_target_interval_ms = 20,
        .pressure_sample_gap_max_ms = 125,
        .settle_sample_gap_max_ms = 250,
        .baseline_samples = &baseline_samples,
        .pressure_samples = pressure_samples.items,
        .post_drain_samples = &post_samples,
        .baseline_rss_bytes = baseline_rss,
        .peak_rss_bytes = pressure_peak,
        .run_peak_rss_bytes = run_peak,
        .post_drain_rss_bytes = post_rss,
        .peak_delta_bytes = pressure_peak -| baseline_rss,
        .run_peak_delta_bytes = run_peak -| baseline_rss,
        .post_drain_delta_bytes = post_rss -| baseline_rss,
        .baseline_ledger_resident_bytes = baseline_ledger,
        .global_ledger_cap_bytes = session_host.connection_slot.global_bytes,
        .projection_transient_cap_bytes = projection_transient,
        .allocator_slack_bytes = allocator_slack,
        .analytic_cap_bytes = analytic_cap,
        .peak_ledger_resident_bytes = marker_report.peak_resident_bytes,
        .peak_ledger_shared_bytes = marker_report.peak_shared_bytes,
        .peak_ledger_prepared_base_bytes = marker_report.peak_prepared_base_bytes,
        .peak_ledger_prepared_reclaim_bytes = marker_report.peak_prepared_reclaim_bytes,
        .peak_ledger_slot_queue_bytes = marker_report.peak_slot_queue_bytes,
        .peak_ledger_slot_base_bytes = marker_report.peak_slot_base_bytes,
        .peak_ledger_slot_control_bytes = marker_report.peak_slot_control_bytes,
        .peak_ledger_slot_total_bytes = marker_report.peak_slot_total_bytes,
        .final_ledger_resident_bytes = final_report.resident_bytes,
        .final_ledger_shared_bytes = final_report.shared_bytes,
        .final_ledger_prepared_base_bytes = final_report.prepared_base_bytes,
        .final_ledger_prepared_reclaim_bytes = final_report.prepared_reclaim_bytes,
        .deadline_ms = deadline_ms,
        .elapsed_ms = elapsed_ms,
        .child_reaped = child_report.reaped_children != 0,
        .child_exit_status = child_report.last_child_exit_status,
        .client_fds_closed = client_fds_closed,
        .final_active_clients = @intCast(final_report.active_clients),
        .host_graceful_stop = true,
        .host_reaped = host_reaped,
        .host_exit_status = host_exit_status,
        .socket_removed = socket_removed,
        .directory_removed = !directory_exists,
    };
    stage = "artifact write";
    try writeArtifactAtomic(allocator, init.io, artifact_path, artifact);
}

fn monotonicNow(io: std.Io) u64 {
    const ns = std.Io.Clock.awake.now(io).nanoseconds;
    return if (ns <= 0) 0 else @intCast(ns);
}

fn spawnFixtureHost(
    exe: [:0]const u8,
    dir: [:0]const u8,
    socket: [:0]const u8,
    command_source: c.fd_t,
    report_source: c.fd_t,
) !c.pid_t {
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid != 0) return pid;
    _ = c.setsid();
    const command_copy = c.fcntl(command_source, c.F.DUPFD, @as(c_int, 10));
    const report_copy = c.fcntl(report_source, c.F.DUPFD, @as(c_int, 10));
    if (command_copy < 0 or report_copy < 0) c._exit(126);
    if (c.dup2(command_copy, probe_wire.command_fd) < 0 or
        c.dup2(report_copy, probe_wire.report_fd) < 0) c._exit(126);
    const max_fd = getdtablesize();
    var fd: c_int = 5;
    while (fd < max_fd) : (fd += 1) _ = c.close(fd);
    const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDWR }, @as(c.mode_t, 0));
    if (null_fd >= 0) {
        _ = c.dup2(null_fd, 0);
        _ = c.dup2(null_fd, 1);
        _ = c.dup2(null_fd, 2);
        if (null_fd > 4) _ = c.close(null_fd);
    }
    const argv = [_:null]?[*:0]const u8{ exe.ptr, dir.ptr, socket.ptr, null };
    _ = execv(exe.ptr, @ptrCast(&argv));
    c._exit(127);
}

fn connectRetry(
    allocator: std.mem.Allocator,
    socket: [:0]const u8,
    deadline_ns: u64,
    io: std.Io,
) !session_host.client.Client {
    while (monotonicNow(io) < deadline_ns) {
        return session_host.client.Client.connect(allocator, socket, .gui) catch |err| switch (err) {
            error.EndpointAbsent, error.ConnectionClosed, error.EndpointTransient => {
                _ = usleep(2_000);
                continue;
            },
            else => return err,
        };
    }
    return error.HostConnectTimeout;
}

fn attachRuntime(
    allocator: std.mem.Allocator,
    client: *session_host.client.Client,
    runtime_id: *const [32]u8,
    mode: []const u8,
) !u64 {
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"runtime_id\":\"{s}\",\"mode\":\"{s}\"}}",
        .{ runtime_id, mode },
    );
    defer allocator.free(params);
    const response = try client.call("runtime.attach", params);
    defer allocator.free(response);
    return session_host.client.extractU64Field(response, "\"stream_id\":") orelse
        error.RuntimeAttachFailed;
}

fn pumpHealthy(
    client: *session_host.client.Client,
    stream_id: u64,
    assembler: *session_host.screen_assembler.ScreenAssembler,
    drained_bytes: *u64,
) !bool {
    const batch = (try client.readStreamBatch(stream_id)) orelse return false;
    defer batch.deinit();
    drained_bytes.* += batch.bytes.len;
    if (batch.is_snapshot)
        try assembler.applySnapshot(batch.bytes)
    else
        try assembler.applyDelta(batch.bytes);
    return true;
}

fn waitForMarker(
    client: *session_host.client.Client,
    stream_id: u64,
    assembler: *session_host.screen_assembler.ScreenAssembler,
    marker: []const u8,
    drained_bytes: *u64,
    deadline_ns: u64,
    io: std.Io,
) !void {
    while (monotonicNow(io) < deadline_ns) {
        if (screenContains(assembler, marker)) return;
        const progressed = try pumpHealthy(client, stream_id, assembler, drained_bytes);
        // Timestamp success in the same observation turn that applied the marker. Sleeping after
        // progress adds a deterministic 2 ms harness delay to the product latency measurement.
        if (screenContains(assembler, marker)) return;
        if (!progressed) {
            // Wait on the product socket itself instead of a periodic userspace sleep. Hosted
            // macOS runners can resume a 2 ms usleep near the daemon's 20 ms fallback cadence,
            // which attributes observer scheduling delay to the output-wake product path. A
            // blocking poll is armed before the next frame arrives and therefore timestamps the
            // same kernel-readiness edge that makes the valid delta observable.
            const now_ns = monotonicNow(io);
            if (now_ns >= deadline_ns) break;
            const remaining_ns = deadline_ns - now_ns;
            const remaining_ms = @max(
                @as(u64, 1),
                (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms,
            );
            var readable = c.pollfd{
                .fd = client.fd,
                .events = c.POLL.IN,
                .revents = 0,
            };
            const rc = c.poll(
                @ptrCast(&readable),
                1,
                std.math.cast(c_int, remaining_ms) orelse std.math.maxInt(c_int),
            );
            if (rc < 0 and posix.errno(rc) != .INTR) return error.ClientPollFailed;
        }
    }
    return error.MarkerTimeout;
}

fn sendInputBeforeDeadline(
    client: *session_host.client.Client,
    stream_id: u64,
    bytes: []const u8,
    deadline_ns: u64,
    io: std.Io,
) !void {
    var accepted: usize = 0;
    while (accepted < bytes.len) {
        if (monotonicNow(io) >= deadline_ns) return error.InputWriteTimeout;
        const n = try client.sendInputNonBlocking(stream_id, bytes[accepted..]);
        accepted += n;
        if (n == 0) _ = usleep(1_000);
    }
    while (!(try client.pumpPendingOutput())) {
        if (monotonicNow(io) >= deadline_ns) return error.InputWriteTimeout;
        _ = usleep(1_000);
    }
}

fn screenContains(
    assembler: *const session_host.screen_assembler.ScreenAssembler,
    marker: []const u8,
) bool {
    var row: u16 = 0;
    while (row < assembler.rows_count) : (row += 1) {
        var bytes: [4096]u8 = undefined;
        var used: usize = 0;
        for (assembler.rowRuns(row)) |cell_run| {
            var repeat: u32 = 0;
            while (repeat < cell_run.count) : (repeat += 1) {
                if (cell_run.grapheme.len > bytes.len - used) break;
                @memcpy(bytes[used..][0..cell_run.grapheme.len], cell_run.grapheme);
                used += cell_run.grapheme.len;
            }
        }
        if (std.mem.indexOf(u8, bytes[0..used], marker) != null) return true;
    }
    return false;
}

fn probe(
    command_fd: c.fd_t,
    report_fd: c.fd_t,
    sequence: *u64,
    command: probe_wire.Command,
    deadline_ns: u64,
    io: std.Io,
) !probe_wire.Report {
    const wanted = sequence.*;
    sequence.* += 1;
    const packet = probe_wire.CommandPacket.init(wanted, command);
    while (true) {
        const sent = c.send(
            command_fd,
            std.mem.asBytes(&packet).ptr,
            @sizeOf(@TypeOf(packet)),
            posix.MSG.DONTWAIT,
        );
        if (sent == @sizeOf(@TypeOf(packet))) break;
        if (sent < 0 and (posix.errno(sent) == .AGAIN or
            posix.errno(sent) == .INTR))
        {
            if (monotonicNow(io) >= deadline_ns) return error.ProbeTimeout;
            _ = usleep(1_000);
            continue;
        }
        return error.ProbeWriteFailed;
    }
    while (monotonicNow(io) < deadline_ns) {
        var packet_bytes: [@sizeOf(probe_wire.Report) + 1]u8 = undefined;
        const received = c.recv(
            report_fd,
            &packet_bytes,
            packet_bytes.len,
            posix.MSG.DONTWAIT | posix.MSG.TRUNC,
        );
        if (received == @sizeOf(probe_wire.Report)) {
            const report = probe_wire.decodeReportDatagram(
                packet_bytes[0..@intCast(received)],
            ) orelse return error.ProbeProtocolError;
            if (!report.valid() or report.sequence != wanted)
                return error.ProbeProtocolError;
            const expected: probe_wire.ReportKind = switch (command) {
                .snapshot => .snapshot,
                .reset_stall => .reset_ack,
                .stop => .stop_ack,
            };
            if (report.kind != @intFromEnum(expected)) return error.ProbeProtocolError;
            return report;
        }
        if (received < 0 and (posix.errno(received) == .AGAIN or
            posix.errno(received) == .INTR))
        {
            _ = usleep(1_000);
            continue;
        }
        return error.ProbeReadFailed;
    }
    return error.ProbeTimeout;
}

fn processIdentity(pid: c.pid_t, include_rusage: bool) !ProcessIdentity {
    var info: mac.struct_proc_bsdinfo = std.mem.zeroes(mac.struct_proc_bsdinfo);
    const count = mac.proc_pidinfo(
        pid,
        mac.PROC_PIDTBSDINFO,
        0,
        &info,
        @sizeOf(mac.struct_proc_bsdinfo),
    );
    if (count != @sizeOf(mac.struct_proc_bsdinfo) or info.pbi_pid != @as(u32, @intCast(pid)))
        return error.ProcessIdentityUnavailable;
    var identity: ProcessIdentity = .{
        .pid = pid,
        .uid = info.pbi_uid,
        .ppid = @intCast(info.pbi_ppid),
        .start_tvsec = info.pbi_start_tvsec,
        .start_tvusec = @intCast(info.pbi_start_tvusec),
    };
    if (include_rusage) {
        var usage: mac.struct_rusage_info_v4 = std.mem.zeroes(mac.struct_rusage_info_v4);
        if (mac.proc_pid_rusage(pid, mac.RUSAGE_INFO_V4, @ptrCast(&usage)) != 0)
            return error.RusageUnavailable;
        identity.start_abstime = usage.ri_proc_start_abstime;
    }
    if (identity.start_tvsec == 0 or identity.start_tvusec >= std.time.us_per_s)
        return error.ProcessIdentityUnavailable;
    return identity;
}

fn sameProcessIdentity(a: ProcessIdentity, b: ProcessIdentity) bool {
    return a.pid == b.pid and a.uid == b.uid and a.ppid == b.ppid and
        a.start_tvsec == b.start_tvsec and a.start_tvusec == b.start_tvusec;
}

fn takeSample(identity: ProcessIdentity, io: std.Io) !RawSample {
    const pinned = try processIdentity(identity.pid, true);
    if (!sameProcessIdentity(identity, pinned) or
        pinned.start_abstime != identity.start_abstime)
        return error.HostIdentityChanged;
    var usage: mac.struct_rusage_info_v4 = std.mem.zeroes(mac.struct_rusage_info_v4);
    if (mac.proc_pid_rusage(identity.pid, mac.RUSAGE_INFO_V4, @ptrCast(&usage)) != 0)
        return error.RusageUnavailable;
    if (usage.ri_resident_size == 0 or usage.ri_phys_footprint == 0 or
        usage.ri_proc_start_abstime != identity.start_abstime)
        return error.InvalidRusage;
    return .{
        .monotonic_ns = monotonicNow(io),
        .pid = @intCast(identity.pid),
        .uid = identity.uid,
        .start_tvsec = identity.start_tvsec,
        .start_tvusec = identity.start_tvusec,
        .ri_resident_size = usage.ri_resident_size,
        .ri_phys_footprint = usage.ri_phys_footprint,
        .ri_proc_start_abstime = usage.ri_proc_start_abstime,
    };
}

fn takeIdleCpuSample(identity: ProcessIdentity, io: std.Io) !IdleCpuSample {
    const pinned = try processIdentity(identity.pid, true);
    if (!sameProcessIdentity(identity, pinned) or
        pinned.start_abstime != identity.start_abstime)
        return error.HostIdentityChanged;
    var usage: mac.struct_rusage_info_v4 = std.mem.zeroes(mac.struct_rusage_info_v4);
    if (mac.proc_pid_rusage(identity.pid, mac.RUSAGE_INFO_V4, @ptrCast(&usage)) != 0)
        return error.RusageUnavailable;
    return .{
        .monotonic_ns = monotonicNow(io),
        .user_time_ns = usage.ri_user_time,
        .system_time_ns = usage.ri_system_time,
    };
}

fn maybeSample(
    allocator: std.mem.Allocator,
    samples: *std.ArrayListUnmanaged(RawSample),
    identity: ProcessIdentity,
    io: std.Io,
) !void {
    const now = monotonicNow(io);
    if (samples.items.len == 0 or
        now - samples.items[samples.items.len - 1].monotonic_ns >= 10 * std.time.ns_per_ms)
    {
        try samples.append(allocator, try takeSample(identity, io));
    }
}

fn listChildren(parent: c.pid_t, buffer: *[64]c.pid_t) usize {
    @memset(buffer, 0);
    // macOS libproc의 이 API는 헤더 주변 문구와 달리 child PID 개수를 돌려준다.
    const count = mac.proc_listchildpids(parent, buffer, @sizeOf(@TypeOf(buffer.*)));
    if (count <= 0) return 0;
    return @min(buffer.len, @as(usize, @intCast(count)));
}

fn waitForNewChild(
    parent: c.pid_t,
    before: []const c.pid_t,
    deadline_ns: u64,
    io: std.Io,
) !c.pid_t {
    while (monotonicNow(io) < deadline_ns) {
        var current: [64]c.pid_t = undefined;
        const count = listChildren(parent, &current);
        for (current[0..count]) |pid| {
            if (pid > 0 and std.mem.indexOfScalar(c.pid_t, before, pid) == null) return pid;
        }
        _ = usleep(2_000);
    }
    return error.RuntimePidUnavailable;
}

fn peerPid(fd: c.fd_t) !c.pid_t {
    var pid: c.pid_t = 0;
    var len: c.socklen_t = @sizeOf(c.pid_t);
    if (c.getsockopt(fd, sol_local, local_peerpid, &pid, &len) != 0 or
        len != @sizeOf(c.pid_t) or pid <= 0)
        return error.PeerPidUnavailable;
    return pid;
}

fn socketBuffer(fd: c.fd_t, option: u32) !c_int {
    var value: c_int = 0;
    var len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, posix.SOL.SOCKET, option, &value, &len) != 0 or
        len != @sizeOf(c_int) or value <= 0)
        return error.SocketBufferUnavailable;
    return value;
}

fn fillPayload(payload: []u8, nonce: [16]u8) void {
    var state = std.mem.readInt(u64, nonce[0..8], .little) ^
        std.mem.readInt(u64, nonce[8..16], .little);
    if (state == 0) state = 0x9e3779b97f4a7c15;
    for (payload, 0..) |*byte, index| {
        if (index % 512 == 511) {
            byte.* = '\n';
        } else {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            byte.* = @intCast(33 + state % 94);
        }
    }
}

fn medianRss(samples: []const RawSample) u64 {
    var values: [baseline_sample_count]u64 = undefined;
    std.debug.assert(samples.len == values.len);
    for (samples, &values) |sample, *value| value.* = sample.ri_resident_size;
    std.mem.sort(u64, &values, {}, std.sort.asc(u64));
    return values[4] + (values[5] - values[4]) / 2;
}

fn maxRss(samples: []const RawSample) u64 {
    var result: u64 = 0;
    for (samples) |sample| result = @max(result, sample.ri_resident_size);
    return result;
}

fn waitExact(pid: c.pid_t, status: *c_int, deadline_ns: u64, io: std.Io) c.pid_t {
    while (monotonicNow(io) < deadline_ns) {
        const waited = c.waitpid(pid, status, c.W.NOHANG);
        if (waited != 0) return waited;
        _ = usleep(2_000);
    }
    return 0;
}

fn exitStatus(status: c_int) i32 {
    if ((status & 0x7f) != 0) return -1;
    return @intCast((status >> 8) & 0xff);
}

fn stopAndReap(pid: c.pid_t) void {
    _ = c.kill(pid, posix.SIG.TERM);
    var status: c_int = undefined;
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        const waited = c.waitpid(pid, &status, c.W.NOHANG);
        if (waited == pid or (waited < 0 and posix.errno(waited) == .CHILD)) return;
        _ = usleep(10_000);
    }
    _ = c.kill(pid, posix.SIG.KILL);
    while (true) {
        const waited = c.waitpid(pid, &status, 0);
        if (waited == pid or (waited < 0 and posix.errno(waited) == .CHILD)) return;
        if (waited < 0 and posix.errno(waited) == .INTR) continue;
        return;
    }
}

fn removeDirectoryRetry(path: [:0]const u8, attempts: usize) bool {
    var attempt: usize = 0;
    while (attempt < attempts) : (attempt += 1) {
        if (c.rmdir(path.ptr) == 0) return true;
        const err = posix.errno(-1);
        if (err == .NOENT) return true;
        if (err != .INTR and err != .BUSY and err != .NOTEMPTY) {
            std.debug.print("rmdir '{s}' failed: {s}\n", .{ path, @tagName(err) });
            return false;
        }
        _ = usleep(2_000);
    }
    std.debug.print("rmdir '{s}' remained non-empty after {d} attempts\n", .{ path, attempts });
    return false;
}

fn unlinkSessionLeaf(session_dir: [:0]const u8, leaf: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ session_dir, leaf });
    const rc = c.unlink(path.ptr);
    if (rc != 0 and posix.errno(rc) != .NOENT)
        return error.SessionDirectoryCleanupFailed;
}

fn removeSessionDirectoryLeaf(session_dir: [:0]const u8, leaf: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ session_dir, leaf });
    if (!removeDirectoryRetry(path, 10)) return error.SessionDirectoryCleanupFailed;
}

fn countClosedFds(fds: []const c.fd_t) u8 {
    var closed: u8 = 0;
    for (fds) |fd| {
        const rc = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
        if (rc < 0 and posix.errno(rc) == .BADF) closed += 1;
    }
    return closed;
}

/// 오류 unwind에서도 supervised host reap 뒤 이 fixture가 만든 exact leaf만
/// 제거한다. 임의 directory traversal이나 재귀 삭제는 하지 않는다.
fn cleanupSessionDirectory(
    session_dir: [:0]const u8,
    socket_path: [:0]const u8,
) void {
    const socket_rc = c.unlink(socket_path.ptr);
    if (socket_rc != 0 and posix.errno(socket_rc) != .NOENT) return;
    unlinkSessionLeaf(session_dir, "owner-v2.lock") catch return;
    removeSessionDirectoryLeaf(session_dir, "incidents") catch return;
    _ = removeDirectoryRetry(session_dir, 100);
}

fn invalidateArtifact(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const rc = c.unlink(path_z.ptr);
    if (rc != 0 and posix.errno(rc) != .NOENT) return error.ArtifactInvalidationFailed;
}

fn writeArtifactAtomic(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    artifact: Artifact,
) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (!std.fs.path.isAbsolute(parent))
            try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.write(artifact);
    try out.writer.writeByte('\n');
    const temp = try std.fmt.allocPrint(
        allocator,
        "{s}.tmp.{d}.{s}",
        .{ path, c.getpid(), artifact.run_nonce_hex[0..12] },
    );
    defer allocator.free(temp);
    const temp_z = try allocator.dupeZ(u8, temp);
    defer allocator.free(temp_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    defer _ = c.unlink(temp_z.ptr);
    const fd = c.open(temp_z.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.ArtifactCreateFailed;
    var fd_open = true;
    defer {
        if (fd_open) _ = c.close(fd);
    }
    var offset: usize = 0;
    while (offset < out.written().len) {
        const written = c.write(
            fd,
            out.written()[offset..].ptr,
            out.written().len - offset,
        );
        if (written < 0 and posix.errno(written) == .INTR) continue;
        if (written <= 0) return error.ArtifactWriteFailed;
        offset += @intCast(written);
    }
    if (c.close(fd) != 0) return error.ArtifactWriteFailed;
    fd_open = false;
    if (c.rename(temp_z.ptr, path_z.ptr) != 0) return error.ArtifactRenameFailed;
}

test "failure cleanup removes only the fixture socket lock and directory" {
    var nonce: [8]u8 = undefined;
    arc4random_buf(&nonce, nonce.len);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    var dir_buf: [192]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(
        &dir_buf,
        "/tmp/maru-slow-observer-cleanup-test-{d}-{s}",
        .{ c.getpid(), nonce_hex[0..] },
    );
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(dir.ptr, 0o700));
    var socket_buf: [256]u8 = undefined;
    const socket = try std.fmt.bufPrintZ(&socket_buf, "{s}/host.sock", .{dir});
    var lock_buf: [256]u8 = undefined;
    const lock = try std.fmt.bufPrintZ(&lock_buf, "{s}/owner-v2.lock", .{dir});
    for ([_][*:0]const u8{ socket.ptr, lock.ptr }) |path| {
        const fd = c.open(path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, @as(c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        try std.testing.expectEqual(@as(c_int, 0), c.close(fd));
    }

    cleanupSessionDirectory(dir, socket);
    const rc = c.access(dir.ptr, c.F_OK);
    try std.testing.expect(rc != 0 and posix.errno(rc) == .NOENT);
}
