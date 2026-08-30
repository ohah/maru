//! P5b2b2 독립 session-host PTY/RSS artifact의 fail-closed validator.
//!
//! 이 도구가 raw sample부터 요약과 분석 상한을 다시 계산하는 이유는 producer가 같은 잘못된 값을
//! summary와 pass boolean에 함께 기록하는 false-green을 막기 위해서다. Typed JSON decode의 기본
//! duplicate/unknown/missing-field 거부를 유지해 artifact schema 자체도 완료 gate로 고정한다.

const std = @import("std");
const connection_slot = @import("connection_slot");

const schema_name = "maru.session-host-slow-observer-macos.v4";
const scenario_name = "slow-observer-real-pty-rss";
const build_mode = "ReleaseFast";
const sample_api = "proc_pid_rusage:RUSAGE_INFO_V4";

const mib: u64 = 1024 * 1024;
const workload_bytes_per_iteration: u64 = 2 * mib;
const workload_iterations_max: u64 = 8;
const marker_input_bytes: u64 = 33; // 128-bit nonce의 lowercase hex 32 byte + LF.
/// 깨우기 지연 표본 수. **7 이었다** — 그때는 꼬리를 `max` 로 쟀고, 공유 러너에서 스케줄링이 한 번
/// 튀면 그대로 게이트가 빨개졌다(2026-08-30 실측: 실패 회차 28.3 ms vs 재실행 8.3 ms, median 은 둘 다
/// 1 ms 아래로 상한의 열 배 여유였다 — 즉 회귀가 아니라 **통계 선택**의 문제였다).
///
/// p95 가 뜻을 가지려면 표본이 그만큼 있어야 한다. 40 이면 p95 가 index 37 이라 **가장 나쁜 둘을
/// 뺀다** — 러너 딸꾹질 한두 번은 흡수하고 그 이상은 그대로 잡는다.
const wake_sample_count: usize = 40;

/// nearest-rank p95 의 0-based index. `ceil(0.95 n) - 1`.
pub fn p95Index(n: usize) usize {
    std.debug.assert(n > 0);
    const rank = (n * 95 + 99) / 100; // ceil(0.95 n)
    return @min(n, @max(1, rank)) - 1;
}
const idle_wake_observation_min_ns: u64 = 1_000 * std.time.ns_per_ms;
const screen_idle_cpu_total_cap_ns: u64 = 100 * std.time.ns_per_ms;
pub const idle_cpu_total_cap_ns: u64 = 25 * std.time.ns_per_ms;
pub const output_wake_median_cap_ns: u64 = 10 * std.time.ns_per_ms;
/// **꼬리 성능 계약** — p95 에 건다(옛날에는 `max` 에 걸었다, 위 `wake_sample_count` 주석).
pub const output_wake_tail_cap_ns: u64 = 20 * std.time.ns_per_ms;

/// **최댓값은 성능이 아니라 살아 있음을 잰다.** p95 로 옮기면서 `max` 를 아예 안 보면 진짜 멈춤
/// (몇 초짜리)이 지나간다. 그래서 훨씬 느슨한 상한 하나를 남긴다 — 이 값을 넘으면 스케줄링
/// 딸꾹질이 아니라 무언가 막힌 것이다.
pub const output_wake_hang_cap_ns: u64 = 200 * std.time.ns_per_ms;
pub const observation_core_lock_hold_cap_ns: u64 = 25 * std.time.ns_per_ms;
const baseline_sample_count: usize = 10;
const pressure_sample_count_min: usize = 20;
const pressure_sample_count_max: usize = 4096;
const post_drain_sample_count: usize = 10;
const sample_target_interval_ms: u64 = 20;
const pressure_sample_gap_max_ms: u64 = 125;
const settle_sample_gap_max_ms: u64 = 250;
const pressure_sample_gap_max_ns: u64 =
    pressure_sample_gap_max_ms * std.time.ns_per_ms;
const settle_sample_gap_max_ns: u64 =
    settle_sample_gap_max_ms * std.time.ns_per_ms;
const deadline_ms: u64 = 30_000;

const base_update_max_bytes: u64 = connection_slot.base_update_max_bytes;
const projection_transient_cap_bytes: u64 = 2 * base_update_max_bytes;
const allocator_slack_bytes: u64 = 64 * mib;
const global_ledger_cap_bytes: u64 = connection_slot.global_bytes;
const shared_ledger_cap_bytes: u64 = connection_slot.shared_hard_bytes;
const per_slot_bytes: u64 = connection_slot.per_slot_bytes;
const base_per_slot_bytes: u64 = connection_slot.base_per_slot_bytes;
const total_per_slot_bytes: u64 = connection_slot.total_per_slot_bytes;

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

/// Flat top-level fields make the artifact easy to inspect in CI while RawSample remains a typed
/// nested object. No field has a default: absent fields fail parsing, as do duplicate/unknown keys.
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
    wake_latency_p95_ns: u64,
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

const ValidationError = error{
    InvalidJsonSchema,
    InvalidIdentity,
    InvalidNonce,
    InvalidRoleCount,
    InvalidSocketBuffer,
    InvalidWorkload,
    MissingStallEvidence,
    InvalidProgress,
    InvalidSampleCount,
    InvalidSampleInterval,
    InvalidSample,
    IdentityChanged,
    TimestampOrder,
    SummaryMismatch,
    LedgerCapExceeded,
    LedgerFormulaMismatch,
    RssCapExceeded,
    FinalLedgerNotZero,
    DeadlineExceeded,
    CleanupIncomplete,
};

fn checkedAdd(a: u64, b: u64) ValidationError!u64 {
    return std.math.add(u64, a, b) catch error.LedgerFormulaMismatch;
}

fn checkedMul(a: u64, b: u64) ValidationError!u64 {
    return std.math.mul(u64, a, b) catch error.InvalidWorkload;
}

fn isLowerHex128(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |ch| {
        if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
    }
    return true;
}

fn sameIdentity(sample: RawSample, artifact: Artifact) bool {
    return sample.pid == artifact.host_pid and
        sample.uid == artifact.host_uid and
        sample.start_tvsec == artifact.host_start_tvsec and
        sample.start_tvusec == artifact.host_start_tvusec and
        sample.ri_proc_start_abstime == artifact.host_ri_proc_start_abstime;
}

fn validateSamples(
    artifact: Artifact,
    samples: []const RawSample,
    max_interval_ns: ?u64,
) ValidationError!void {
    var previous_ns: ?u64 = null;
    for (samples) |sample| {
        if (sample.monotonic_ns == 0 or sample.pid == 0 or sample.start_tvsec == 0 or
            sample.start_tvusec >= std.time.us_per_s or
            sample.ri_resident_size == 0 or sample.ri_phys_footprint == 0 or
            sample.ri_proc_start_abstime == 0)
        {
            return error.InvalidSample;
        }
        if (!sameIdentity(sample, artifact)) return error.IdentityChanged;
        if (previous_ns) |previous| {
            if (sample.monotonic_ns <= previous) return error.TimestampOrder;
            if (max_interval_ns) |limit| {
                if (sample.monotonic_ns - previous > limit) return error.InvalidSampleInterval;
            }
        }
        previous_ns = sample.monotonic_ns;
    }
}

fn rssMedian(allocator: std.mem.Allocator, samples: []const RawSample) !u64 {
    const values = try allocator.alloc(u64, samples.len);
    defer allocator.free(values);
    for (samples, values) |sample, *value| value.* = sample.ri_resident_size;
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    const upper = values[values.len / 2];
    if (values.len % 2 == 1) return upper;
    const lower = values[values.len / 2 - 1];
    // Difference-first average avoids overflow while keeping the integer artifact deterministic.
    return lower + (upper - lower) / 2;
}

fn rssMax(samples: []const RawSample) u64 {
    var result: u64 = 0;
    for (samples) |sample| result = @max(result, sample.ri_resident_size);
    return result;
}

fn validateArtifact(allocator: std.mem.Allocator, artifact: Artifact) !void {
    if (!std.mem.eql(u8, artifact.schema, schema_name) or
        !std.mem.eql(u8, artifact.scenario, scenario_name) or
        !std.mem.eql(u8, artifact.build_mode, build_mode) or
        !std.mem.eql(u8, artifact.sample_api, sample_api))
    {
        return error.InvalidIdentity;
    }
    if (!isLowerHex128(artifact.run_nonce_hex)) return error.InvalidNonce;
    if (artifact.host_pid == 0 or artifact.local_peer_pid != artifact.host_pid or
        artifact.waitpid_pid != artifact.host_pid or artifact.pty_child_pid == 0 or
        artifact.host_pid == artifact.pty_child_pid or artifact.host_start_tvsec == 0 or
        artifact.host_start_tvusec >= std.time.us_per_s or
        artifact.host_ri_proc_start_abstime == 0)
    {
        return error.InvalidIdentity;
    }
    if (artifact.pty_child_uid != artifact.host_uid or
        artifact.pty_child_start_tvsec == 0 or
        artifact.pty_child_start_tvusec >= std.time.us_per_s or
        artifact.pty_child_ppid != artifact.host_pid or
        !artifact.pty_child_identity_rechecked or
        !artifact.pty_probe_fds_closed)
    {
        return error.InvalidIdentity;
    }
    if (artifact.controller_clients != 1 or artifact.slow_observer_clients != 1 or
        artifact.healthy_observer_clients != 1 or artifact.total_admitted != 3 or
        artifact.stale_admission_count != 0)
    {
        return error.InvalidRoleCount;
    }
    if (artifact.observation_materializations == 0 or
        artifact.observation_core_lock_acquisitions !=
            try checkedMul(artifact.observation_materializations, 3) or
        artifact.observation_core_lock_hold_total_ns <
            artifact.observation_core_lock_hold_max_ns or
        artifact.observation_core_lock_hold_max_ns >
            observation_core_lock_hold_cap_ns or
        artifact.idle_observation_materialization_delta != 0 or
        artifact.idle_observation_core_lock_acquisition_delta != 0 or
        artifact.idle_observation_core_lock_hold_delta_ns != 0 or
        artifact.metadata_sampler_visits == 0 or
        artifact.metadata_sampler_failures != 0 or
        artifact.idle_metadata_producer_visit_delta != 0)
    {
        return error.InvalidObservationEvidence;
    }
    if (artifact.screen_snapshot_calls == 0 or artifact.screen_delta_calls == 0 or
        artifact.screen_owned_allocations <
            artifact.screen_snapshot_calls + artifact.screen_delta_calls or
        artifact.screen_core_lock_acquisitions !=
            artifact.screen_snapshot_calls + artifact.screen_delta_calls or
        artifact.idle_screen_snapshot_call_delta != 0 or
        artifact.idle_screen_delta_call_delta != 0 or
        artifact.idle_screen_owned_allocation_delta != 0 or
        artifact.idle_screen_core_lock_acquisition_delta != 0)
    {
        return error.InvalidScreenEvidence;
    }
    const expected_runtime_counts = [_]u32{ 1, 10, 100 };
    if (artifact.screen_idle_scale_samples.len != expected_runtime_counts.len)
        return error.InvalidScreenScaleEvidence;
    for (artifact.screen_idle_scale_samples, expected_runtime_counts) |sample, expected_count| {
        if (sample.runtime_count != expected_count or
            sample.observation_ns < idle_wake_observation_min_ns or
            sample.cpu_total_delta_ns > screen_idle_cpu_total_cap_ns or
            sample.snapshot_call_delta != 0 or sample.delta_call_delta != 0 or
            sample.owned_allocation_delta != 0 or
            sample.core_lock_acquisition_delta != 0 or
            sample.metadata_producer_visit_delta != 0 or
            sample.metadata_materialization_delta != 0 or
            sample.metadata_core_lock_acquisition_delta != 0)
        {
            return error.InvalidScreenScaleEvidence;
        }
    }
    if (artifact.metadata_change_runtime_count != 100 or
        artifact.metadata_change_target_stream_count != 3 or
        artifact.metadata_change_sampler_delta != 1 or
        artifact.metadata_change_producer_visit_delta != 3 or
        artifact.metadata_change_materialization_delta != 1 or
        artifact.metadata_change_core_lock_acquisition_delta != 3)
    {
        return error.InvalidMetadataChangeScaleEvidence;
    }
    if (artifact.slow_connection_id == 0 or
        artifact.slow_connection_id != artifact.first_stall_connection_id)
    {
        return error.MissingStallEvidence;
    }
    if (artifact.effective_host_send_buffer_bytes == 0 or
        artifact.effective_slow_receive_buffer_bytes == 0)
    {
        return error.InvalidSocketBuffer;
    }

    if (artifact.workload_iterations == 0 or
        artifact.workload_iterations > workload_iterations_max or
        artifact.workload_bytes_per_iteration == 0 or
        artifact.workload_bytes_per_iteration > workload_bytes_per_iteration)
    {
        return error.InvalidWorkload;
    }
    const payload_bytes = try checkedMul(
        artifact.workload_iterations,
        artifact.workload_bytes_per_iteration,
    );
    if (artifact.pressure_generated_bytes != payload_bytes or
        artifact.marker_input_bytes != marker_input_bytes)
    {
        return error.InvalidWorkload;
    }
    const total_generated = std.math.add(
        u64,
        artifact.pressure_generated_bytes,
        artifact.marker_input_bytes,
    ) catch return error.InvalidWorkload;
    if (artifact.final_pty_output_bytes < artifact.baseline_pty_output_bytes or
        artifact.pty_produced_bytes !=
            artifact.final_pty_output_bytes - artifact.baseline_pty_output_bytes or
        artifact.pty_produced_bytes != total_generated or
        artifact.healthy_drained_bytes == 0)
    {
        return error.InvalidWorkload;
    }
    const stall_evidence_count = std.math.add(
        u64,
        artifact.slow_eagain_count,
        artifact.slow_pollout_absent_count,
    ) catch return error.MissingStallEvidence;
    if (stall_evidence_count == 0) return error.MissingStallEvidence;
    if (!(artifact.stall_at_ns < artifact.controller_input_at_ns and
        artifact.controller_input_at_ns < artifact.healthy_marker_at_ns) or
        artifact.healthy_progress_batches_after <=
            artifact.healthy_progress_batches_before or
        !artifact.baseline_reset_ack or !artifact.healthy_marker_matches_nonce)
    {
        return error.InvalidProgress;
    }
    if (artifact.wake_sample_count != wake_sample_count or
        artifact.wake_samples.len != wake_sample_count)
        return error.InvalidSampleCount;
    var wake_latencies: [wake_sample_count]u64 = undefined;
    var previous_marker_ns: u64 = 0;
    for (artifact.wake_samples, 0..) |sample, index| {
        if (sample.input_at_ns <= previous_marker_ns or
            sample.input_accepted_at_ns < sample.input_at_ns or
            sample.marker_at_ns <= sample.input_accepted_at_ns or
            sample.end_to_end_latency_ns != sample.marker_at_ns - sample.input_at_ns or
            sample.delivery_latency_ns != sample.marker_at_ns - sample.input_accepted_at_ns)
            return error.InvalidProgress;
        wake_latencies[index] = sample.delivery_latency_ns;
        previous_marker_ns = sample.marker_at_ns;
    }
    std.mem.sort(u64, &wake_latencies, {}, std.sort.asc(u64));
    if (artifact.wake_latency_min_ns != wake_latencies[0] or
        artifact.wake_latency_median_ns != wake_latencies[wake_sample_count / 2] or
        artifact.wake_latency_p95_ns != wake_latencies[p95Index(wake_sample_count)] or
        artifact.wake_latency_max_ns != wake_latencies[wake_sample_count - 1] or
        artifact.wake_latency_median_ns > output_wake_median_cap_ns or
        // **꼬리는 p95 다.** `max` 는 아래에서 훨씬 느슨한 상한으로 따로 본다 — 그 둘은 재는 것이
        // 다르다(하나는 성능 계약, 하나는 멈춤 감지).
        artifact.wake_latency_p95_ns > output_wake_tail_cap_ns or
        artifact.wake_latency_max_ns > output_wake_hang_cap_ns)
        return error.InvalidProgress;
    if (artifact.idle_wake_observation_ns < idle_wake_observation_min_ns or
        artifact.idle_wake_notify_delta != 0 or
        artifact.idle_wake_published_delta != 0 or
        artifact.idle_wake_coalesced_delta != 0 or
        artifact.idle_wake_drain_delta != 0)
        return error.InvalidProgress;
    if (artifact.idle_cpu_after.monotonic_ns <= artifact.idle_cpu_before.monotonic_ns or
        artifact.idle_cpu_after.user_time_ns < artifact.idle_cpu_before.user_time_ns or
        artifact.idle_cpu_after.system_time_ns < artifact.idle_cpu_before.system_time_ns or
        artifact.idle_cpu_after.monotonic_ns - artifact.idle_cpu_before.monotonic_ns <
            idle_wake_observation_min_ns)
        return error.InvalidProgress;
    const idle_cpu_delta = std.math.add(
        u64,
        artifact.idle_cpu_after.user_time_ns - artifact.idle_cpu_before.user_time_ns,
        artifact.idle_cpu_after.system_time_ns - artifact.idle_cpu_before.system_time_ns,
    ) catch return error.InvalidProgress;
    if (artifact.idle_cpu_total_delta_ns != idle_cpu_delta or
        idle_cpu_delta > idle_cpu_total_cap_ns)
        return error.InvalidProgress;
    const active_accounted_writes = std.math.add(
        u64,
        artifact.active_wake_published_delta,
        artifact.active_wake_coalesced_delta,
    ) catch return error.InvalidProgress;
    if (artifact.active_wake_notify_delta < wake_sample_count or
        artifact.active_wake_published_delta == 0 or
        artifact.active_wake_drain_delta == 0 or
        active_accounted_writes > artifact.active_wake_notify_delta)
        return error.InvalidProgress;

    if (artifact.sample_target_interval_ms != sample_target_interval_ms or
        artifact.pressure_sample_gap_max_ms != pressure_sample_gap_max_ms or
        artifact.settle_sample_gap_max_ms != settle_sample_gap_max_ms)
    {
        return error.InvalidSampleInterval;
    }
    if (artifact.baseline_samples.len != baseline_sample_count or
        artifact.pressure_samples.len < pressure_sample_count_min or
        artifact.pressure_samples.len > pressure_sample_count_max or
        artifact.post_drain_samples.len != post_drain_sample_count)
    {
        return error.InvalidSampleCount;
    }
    try validateSamples(
        artifact,
        artifact.baseline_samples,
        settle_sample_gap_max_ns,
    );
    try validateSamples(
        artifact,
        artifact.pressure_samples,
        pressure_sample_gap_max_ns,
    );
    try validateSamples(
        artifact,
        artifact.post_drain_samples,
        settle_sample_gap_max_ns,
    );

    const baseline_last = artifact.baseline_samples[artifact.baseline_samples.len - 1].monotonic_ns;
    const pressure_first = artifact.pressure_samples[0].monotonic_ns;
    const pressure_last = artifact.pressure_samples[artifact.pressure_samples.len - 1].monotonic_ns;
    const post_first = artifact.post_drain_samples[0].monotonic_ns;
    if (!(baseline_last < pressure_first and pressure_last < post_first and
        pressure_first <= artifact.stall_at_ns and
        artifact.healthy_marker_at_ns <= pressure_last and
        artifact.healthy_marker_at_ns < post_first))
    {
        return error.TimestampOrder;
    }
    var sampled_between_stall_and_marker = false;
    for (artifact.pressure_samples) |sample| {
        if (artifact.stall_at_ns < sample.monotonic_ns and
            sample.monotonic_ns < artifact.healthy_marker_at_ns)
        {
            sampled_between_stall_and_marker = true;
            break;
        }
    }
    if (!sampled_between_stall_and_marker) return error.InvalidSampleCount;

    const baseline = try rssMedian(allocator, artifact.baseline_samples);
    const peak = rssMax(artifact.pressure_samples);
    const post_drain = try rssMedian(allocator, artifact.post_drain_samples);
    const run_peak = @max(peak, @max(
        rssMax(artifact.baseline_samples),
        rssMax(artifact.post_drain_samples),
    ));
    const peak_delta = peak -| baseline;
    const run_peak_delta = run_peak -| baseline;
    const post_drain_delta = post_drain -| baseline;
    if (artifact.baseline_rss_bytes != baseline or artifact.peak_rss_bytes != peak or
        artifact.run_peak_rss_bytes != run_peak or
        artifact.post_drain_rss_bytes != post_drain or
        artifact.peak_delta_bytes != peak_delta or
        artifact.run_peak_delta_bytes != run_peak_delta or
        artifact.post_drain_delta_bytes != post_drain_delta)
    {
        return error.SummaryMismatch;
    }

    if (artifact.global_ledger_cap_bytes != global_ledger_cap_bytes or
        artifact.projection_transient_cap_bytes != projection_transient_cap_bytes or
        artifact.allocator_slack_bytes != allocator_slack_bytes)
    {
        return error.LedgerCapExceeded;
    }
    if (artifact.baseline_ledger_resident_bytes > artifact.peak_ledger_resident_bytes)
        return error.LedgerFormulaMismatch;
    const ledger_delta =
        artifact.peak_ledger_resident_bytes - artifact.baseline_ledger_resident_bytes;
    const expected_cap = try checkedAdd(
        try checkedAdd(ledger_delta, projection_transient_cap_bytes),
        allocator_slack_bytes,
    );
    if (artifact.analytic_cap_bytes != expected_cap) return error.LedgerFormulaMismatch;

    if (artifact.peak_ledger_resident_bytes > global_ledger_cap_bytes or
        artifact.peak_ledger_shared_bytes > shared_ledger_cap_bytes or
        artifact.peak_ledger_prepared_base_bytes > base_update_max_bytes or
        artifact.peak_ledger_prepared_reclaim_bytes > shared_ledger_cap_bytes or
        artifact.peak_ledger_slot_queue_bytes > per_slot_bytes or
        artifact.peak_ledger_slot_base_bytes > base_per_slot_bytes or
        // 512 KiB is a guaranteed control reserve, not the control queue's hard ceiling.
        artifact.peak_ledger_slot_control_bytes > per_slot_bytes or
        artifact.peak_ledger_slot_total_bytes > total_per_slot_bytes or
        artifact.peak_ledger_shared_bytes > artifact.peak_ledger_resident_bytes or
        artifact.peak_ledger_prepared_base_bytes > artifact.peak_ledger_shared_bytes or
        artifact.peak_ledger_prepared_reclaim_bytes > artifact.peak_ledger_shared_bytes or
        artifact.peak_ledger_slot_control_bytes > artifact.peak_ledger_slot_queue_bytes or
        artifact.peak_ledger_slot_total_bytes < artifact.peak_ledger_slot_queue_bytes or
        artifact.peak_ledger_slot_total_bytes < artifact.peak_ledger_slot_base_bytes or
        artifact.peak_ledger_slot_total_bytes >
            try checkedAdd(
                artifact.peak_ledger_slot_queue_bytes,
                artifact.peak_ledger_slot_base_bytes,
            ))
    {
        return error.LedgerCapExceeded;
    }
    if (run_peak_delta > artifact.analytic_cap_bytes or
        post_drain_delta > artifact.analytic_cap_bytes)
    {
        return error.RssCapExceeded;
    }

    if (artifact.final_ledger_resident_bytes != 0 or
        artifact.final_ledger_shared_bytes != 0 or
        artifact.final_ledger_prepared_base_bytes != 0 or
        artifact.final_ledger_prepared_reclaim_bytes != 0)
    {
        return error.FinalLedgerNotZero;
    }
    if (artifact.deadline_ms != deadline_ms or
        artifact.elapsed_ms == 0 or artifact.elapsed_ms > deadline_ms)
        return error.DeadlineExceeded;
    if (!artifact.child_reaped or artifact.child_exit_status != 0 or
        artifact.client_fds_closed != 3 or artifact.final_active_clients != 0 or
        !artifact.host_graceful_stop or
        !artifact.host_reaped or artifact.host_exit_status != 0 or
        !artifact.socket_removed or !artifact.directory_removed)
    {
        return error.CleanupIncomplete;
    }
}

fn validateBytes(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parsed = std.json.parseFromSlice(Artifact, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch return error.InvalidJsonSchema;
    defer parsed.deinit();
    try validateArtifact(allocator, parsed.value);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return usage(stderr);
    if (args.next() != null) return usage(stderr);

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| {
        try stderr.print("artifact 읽기 실패 '{s}' ({s})\n", .{ path, @errorName(err) });
        try stderr.flush();
        std.process.exit(1);
    };
    defer allocator.free(bytes);

    validateBytes(allocator, bytes) catch |err| {
        try stderr.print(
            "session-host slow-observer artifact 검증 실패 '{s}': {s}\n",
            .{ path, @errorName(err) },
        );
        try stderr.flush();
        std.process.exit(1);
    };
}

fn usage(stderr: *std.Io.Writer) !void {
    try stderr.writeAll(
        "usage: session-host-slow-observer-validator <session-host-slow-observer-macos.json>\n",
    );
    try stderr.flush();
    std.process.exit(2);
}

// ---- TDD fixtures: producer summary를 신뢰하지 않고 raw/identity/formula를 각각 깨뜨린다. ----

const testing = std.testing;

fn sampleSeries(
    comptime count: usize,
    start_ns: u64,
    interval_ns: u64,
    resident: u64,
) [count]RawSample {
    var result: [count]RawSample = undefined;
    for (&result, 0..) |*sample, index| {
        sample.* = .{
            .monotonic_ns = start_ns + index * interval_ns,
            .pid = 100,
            .uid = 501,
            .start_tvsec = 1234,
            .start_tvusec = 5678,
            .ri_resident_size = resident,
            .ri_phys_footprint = resident - 1024,
            .ri_proc_start_abstime = 999,
        };
    }
    return result;
}

const baseline_fixture = sampleSeries(10, 1_000_000_000, 20_000_000, 100_000_000);
const pressure_fixture = sampleSeries(20, 1_200_000_000, 10_000_000, 120_000_000);
const post_fixture = sampleSeries(10, 1_500_000_000, 20_000_000, 110_000_000);
/// 정상 픽스처. **손으로 마흔 줄을 적지 않는다** — 표본 수가 바뀔 때마다 낡고, 낡으면 그 배열이
/// 계약이 아니라 상수 더미가 된다.
///
/// 지연은 0.2 ms 씩 늘려 min·median·p95·max 가 **전부 다른 값**이 되게 한다(같으면 어느 통계를
/// 재는지 판정자가 못 가른다). 간격이 이 값인 이유는 상한이다 — 1 ms 씩 늘리면 median 이
/// 21 ms 가 되어 정상 픽스처가 `output_wake_median_cap_ns`(10 ms)에 걸린다(처음에 그렇게 썼다가
/// 정상 케이스가 빨개졌다).
const wake_fixture = blk: {
    var out: [wake_sample_count]WakeSample = undefined;
    for (&out, 0..) |*sample, index| {
        const delivery: u64 = (index + 1) * 200 * std.time.ns_per_us;
        const input: u64 = 900_000_000 + index * 30_000_000;
        sample.* = .{
            .input_at_ns = input,
            .input_accepted_at_ns = input + 1_000_000,
            .marker_at_ns = input + 1_000_000 + delivery,
            .end_to_end_latency_ns = 1_000_000 + delivery,
            .delivery_latency_ns = delivery,
        };
    }
    break :blk out;
};
const screen_idle_scale_fixture = [_]ScreenIdleScaleSample{
    .{ .runtime_count = 1, .observation_ns = std.time.ns_per_s, .cpu_total_delta_ns = 1_000_000, .snapshot_call_delta = 0, .delta_call_delta = 0, .owned_allocation_delta = 0, .core_lock_acquisition_delta = 0, .metadata_producer_visit_delta = 0, .metadata_materialization_delta = 0, .metadata_core_lock_acquisition_delta = 0 },
    .{ .runtime_count = 10, .observation_ns = std.time.ns_per_s, .cpu_total_delta_ns = 10_000_000, .snapshot_call_delta = 0, .delta_call_delta = 0, .owned_allocation_delta = 0, .core_lock_acquisition_delta = 0, .metadata_producer_visit_delta = 0, .metadata_materialization_delta = 0, .metadata_core_lock_acquisition_delta = 0 },
    .{ .runtime_count = 100, .observation_ns = std.time.ns_per_s, .cpu_total_delta_ns = 50_000_000, .snapshot_call_delta = 0, .delta_call_delta = 0, .owned_allocation_delta = 0, .core_lock_acquisition_delta = 0, .metadata_producer_visit_delta = 0, .metadata_materialization_delta = 0, .metadata_core_lock_acquisition_delta = 0 },
};

fn goodArtifact() Artifact {
    return .{
        .schema = schema_name,
        .scenario = scenario_name,
        .build_mode = build_mode,
        .sample_api = sample_api,
        .run_nonce_hex = "0123456789abcdef0123456789abcdef",
        .host_pid = 100,
        .host_uid = 501,
        .host_start_tvsec = 1234,
        .host_start_tvusec = 5678,
        .host_ri_proc_start_abstime = 999,
        .local_peer_pid = 100,
        .waitpid_pid = 100,
        .pty_child_pid = 101,
        .pty_child_uid = 501,
        .pty_child_start_tvsec = 1235,
        .pty_child_start_tvusec = 6789,
        .pty_child_ppid = 100,
        .pty_child_identity_rechecked = true,
        .pty_probe_fds_closed = true,
        .controller_clients = 1,
        .slow_observer_clients = 1,
        .healthy_observer_clients = 1,
        .total_admitted = 3,
        .stale_admission_count = 0,
        .slow_connection_id = 22,
        .first_stall_connection_id = 22,
        .effective_host_send_buffer_bytes = 131_072,
        .effective_slow_receive_buffer_bytes = 131_072,
        .workload_iterations = 1,
        .workload_bytes_per_iteration = workload_bytes_per_iteration,
        .pressure_generated_bytes = workload_bytes_per_iteration,
        .marker_input_bytes = marker_input_bytes,
        .baseline_pty_output_bytes = 4096,
        .final_pty_output_bytes = 4096 + workload_bytes_per_iteration + marker_input_bytes,
        .pty_produced_bytes = workload_bytes_per_iteration + marker_input_bytes,
        .healthy_drained_bytes = 4096,
        .slow_eagain_count = 1,
        .slow_pollout_absent_count = 0,
        .stall_at_ns = 1_250_000_000,
        .wake_sample_count = wake_sample_count,
        .wake_latency_min_ns = wake_fixture[0].delivery_latency_ns,
        .wake_latency_median_ns = wake_fixture[wake_sample_count / 2].delivery_latency_ns,
        .wake_latency_p95_ns = wake_fixture[p95Index(wake_sample_count)].delivery_latency_ns,
        .wake_latency_max_ns = wake_fixture[wake_sample_count - 1].delivery_latency_ns,
        .wake_samples = &wake_fixture,
        .idle_wake_observation_ns = idle_wake_observation_min_ns,
        .idle_wake_notify_delta = 0,
        .idle_wake_published_delta = 0,
        .idle_wake_coalesced_delta = 0,
        .idle_wake_drain_delta = 0,
        .idle_cpu_before = .{
            .monotonic_ns = 700_000_000,
            .user_time_ns = 100_000_000,
            .system_time_ns = 50_000_000,
        },
        .idle_cpu_after = .{
            .monotonic_ns = 1_700_000_000,
            .user_time_ns = 105_000_000,
            .system_time_ns = 52_000_000,
        },
        .idle_cpu_total_delta_ns = 7_000_000,
        .observation_materializations = 4,
        .observation_core_lock_acquisitions = 12,
        .observation_core_lock_hold_total_ns = 800_000,
        .observation_core_lock_hold_max_ns = 300_000,
        .idle_observation_materialization_delta = 0,
        .idle_observation_core_lock_acquisition_delta = 0,
        .idle_observation_core_lock_hold_delta_ns = 0,
        .metadata_sampler_visits = 100,
        .metadata_sampler_changes = 1,
        .metadata_sampler_failures = 0,
        .metadata_producer_visits = 4,
        .idle_metadata_producer_visit_delta = 0,
        .screen_snapshot_calls = 3,
        .screen_delta_calls = 7,
        .screen_owned_allocations = 17,
        .screen_core_lock_acquisitions = 10,
        .idle_screen_snapshot_call_delta = 0,
        .idle_screen_delta_call_delta = 0,
        .idle_screen_owned_allocation_delta = 0,
        .idle_screen_core_lock_acquisition_delta = 0,
        .screen_idle_scale_samples = &screen_idle_scale_fixture,
        .metadata_change_runtime_count = 100,
        .metadata_change_target_stream_count = 3,
        .metadata_change_sampler_delta = 1,
        .metadata_change_producer_visit_delta = 3,
        .metadata_change_materialization_delta = 1,
        .metadata_change_core_lock_acquisition_delta = 3,
        .active_wake_notify_delta = wake_sample_count,
        .active_wake_published_delta = wake_sample_count,
        .active_wake_coalesced_delta = 0,
        .active_wake_drain_delta = wake_sample_count,
        .controller_input_at_ns = 1_260_000_000,
        .healthy_marker_at_ns = 1_270_000_000,
        .healthy_progress_batches_before = 10,
        .healthy_progress_batches_after = 11,
        .baseline_reset_ack = true,
        .healthy_marker_matches_nonce = true,
        .sample_target_interval_ms = 20,
        .pressure_sample_gap_max_ms = 125,
        .settle_sample_gap_max_ms = 250,
        .baseline_samples = &baseline_fixture,
        .pressure_samples = &pressure_fixture,
        .post_drain_samples = &post_fixture,
        .baseline_rss_bytes = 100_000_000,
        .peak_rss_bytes = 120_000_000,
        .run_peak_rss_bytes = 120_000_000,
        .post_drain_rss_bytes = 110_000_000,
        .peak_delta_bytes = 20_000_000,
        .run_peak_delta_bytes = 20_000_000,
        .post_drain_delta_bytes = 10_000_000,
        .baseline_ledger_resident_bytes = 10_000_000,
        .global_ledger_cap_bytes = global_ledger_cap_bytes,
        .projection_transient_cap_bytes = projection_transient_cap_bytes,
        .allocator_slack_bytes = allocator_slack_bytes,
        .analytic_cap_bytes = 20_000_000 +
            projection_transient_cap_bytes +
            allocator_slack_bytes,
        .peak_ledger_resident_bytes = 30_000_000,
        .peak_ledger_shared_bytes = 25_000_000,
        .peak_ledger_prepared_base_bytes = 1_000_000,
        .peak_ledger_prepared_reclaim_bytes = 1_000_000,
        .peak_ledger_slot_queue_bytes = 8_000_000,
        .peak_ledger_slot_base_bytes = 2_000_000,
        .peak_ledger_slot_control_bytes = 1024,
        .peak_ledger_slot_total_bytes = 10_000_000,
        .final_ledger_resident_bytes = 0,
        .final_ledger_shared_bytes = 0,
        .final_ledger_prepared_base_bytes = 0,
        .final_ledger_prepared_reclaim_bytes = 0,
        .deadline_ms = 30_000,
        .elapsed_ms = 1000,
        .child_reaped = true,
        .child_exit_status = 0,
        .client_fds_closed = 3,
        .final_active_clients = 0,
        .host_graceful_stop = true,
        .host_reaped = true,
        .host_exit_status = 0,
        .socket_removed = true,
        .directory_removed = true,
    };
}

fn stringifyArtifact(allocator: std.mem.Allocator, artifact: Artifact) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    try json.write(artifact);
    return output.toOwnedSlice();
}

test "valid typed artifact passes after raw RSS recomputation" {
    const bytes = try stringifyArtifact(testing.allocator, goodArtifact());
    defer testing.allocator.free(bytes);
    try validateBytes(testing.allocator, bytes);
}

test "observation evidence fails closed on absent materialization and lock mismatch" {
    var artifact = goodArtifact();
    artifact.observation_materializations = 0;
    try testing.expectError(
        error.InvalidObservationEvidence,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.observation_core_lock_acquisitions -= 1;
    try testing.expectError(
        error.InvalidObservationEvidence,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.observation_core_lock_hold_total_ns =
        artifact.observation_core_lock_hold_max_ns - 1;
    try testing.expectError(
        error.InvalidObservationEvidence,
        validateArtifact(testing.allocator, artifact),
    );
}

test "idle observation evidence rejects every product-owned work delta" {
    var artifact = goodArtifact();
    artifact.idle_observation_materialization_delta = 1;
    try testing.expectError(
        error.InvalidObservationEvidence,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.idle_observation_core_lock_acquisition_delta = 1;
    try testing.expectError(
        error.InvalidObservationEvidence,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.idle_observation_core_lock_hold_delta_ns = 1;
    try testing.expectError(
        error.InvalidObservationEvidence,
        validateArtifact(testing.allocator, artifact),
    );
}

test "idle screen evidence rejects every projector-owned work delta" {
    inline for (.{
        "idle_screen_snapshot_call_delta",
        "idle_screen_delta_call_delta",
        "idle_screen_owned_allocation_delta",
        "idle_screen_core_lock_acquisition_delta",
    }) |field_name| {
        var artifact = goodArtifact();
        @field(artifact, field_name) = 1;
        try testing.expectError(
            error.InvalidScreenEvidence,
            validateArtifact(testing.allocator, artifact),
        );
    }
}

test "screen scale evidence pins actual 1 10 100 runtime rows and hard budgets" {
    var rows = screen_idle_scale_fixture;
    var artifact = goodArtifact();
    artifact.screen_idle_scale_samples = rows[0..2];
    try testing.expectError(
        error.InvalidScreenScaleEvidence,
        validateArtifact(testing.allocator, artifact),
    );

    inline for (.{
        "snapshot_call_delta",
        "delta_call_delta",
        "owned_allocation_delta",
        "core_lock_acquisition_delta",
    }) |field_name| {
        rows = screen_idle_scale_fixture;
        @field(rows[2], field_name) = 1;
        artifact = goodArtifact();
        artifact.screen_idle_scale_samples = &rows;
        try testing.expectError(
            error.InvalidScreenScaleEvidence,
            validateArtifact(testing.allocator, artifact),
        );
    }

    rows = screen_idle_scale_fixture;
    rows[1].runtime_count = 11;
    artifact = goodArtifact();
    artifact.screen_idle_scale_samples = &rows;
    try testing.expectError(
        error.InvalidScreenScaleEvidence,
        validateArtifact(testing.allocator, artifact),
    );

    rows = screen_idle_scale_fixture;
    rows[2].cpu_total_delta_ns = screen_idle_cpu_total_cap_ns + 1;
    artifact = goodArtifact();
    artifact.screen_idle_scale_samples = &rows;
    try testing.expectError(
        error.InvalidScreenScaleEvidence,
        validateArtifact(testing.allocator, artifact),
    );
}

test "observation core lock hold hard cap rejects cap plus one" {
    var artifact = goodArtifact();
    artifact.observation_core_lock_hold_max_ns =
        observation_core_lock_hold_cap_ns + 1;
    artifact.observation_core_lock_hold_total_ns =
        artifact.observation_core_lock_hold_max_ns;
    try testing.expectError(
        error.InvalidObservationEvidence,
        validateArtifact(testing.allocator, artifact),
    );
}

test "unknown duplicate and missing keys fail exact schema parsing" {
    const bytes = try stringifyArtifact(testing.allocator, goodArtifact());
    defer testing.allocator.free(bytes);

    const extra = try std.mem.concat(
        testing.allocator,
        u8,
        &.{ bytes[0 .. bytes.len - 1], ",\"unexpected\":1}" },
    );
    defer testing.allocator.free(extra);
    try testing.expectError(error.InvalidJsonSchema, validateBytes(testing.allocator, extra));

    const duplicate = try std.mem.concat(
        testing.allocator,
        u8,
        &.{ bytes[0 .. bytes.len - 1], ",\"schema\":\"duplicate\"}" },
    );
    defer testing.allocator.free(duplicate);
    try testing.expectError(error.InvalidJsonSchema, validateBytes(testing.allocator, duplicate));

    const missing =
        \\{"schema":"maru.session-host-slow-observer-macos.v2"}
    ;
    try testing.expectError(error.InvalidJsonSchema, validateBytes(testing.allocator, missing));
}

test "negative and overflowing unsigned fields fail typed parsing" {
    const bytes = try stringifyArtifact(testing.allocator, goodArtifact());
    defer testing.allocator.free(bytes);
    const negative = try std.mem.replaceOwned(
        u8,
        testing.allocator,
        bytes,
        "\"host_pid\":100",
        "\"host_pid\":-1",
    );
    defer testing.allocator.free(negative);
    try testing.expectError(error.InvalidJsonSchema, validateBytes(testing.allocator, negative));

    const overflow = try std.mem.replaceOwned(
        u8,
        testing.allocator,
        bytes,
        "\"host_pid\":100",
        "\"host_pid\":4294967296",
    );
    defer testing.allocator.free(overflow);
    try testing.expectError(error.InvalidJsonSchema, validateBytes(testing.allocator, overflow));
}

test "raw summary mismatch and changed process identity fail" {
    var artifact = goodArtifact();
    artifact.peak_rss_bytes += 1;
    try testing.expectError(
        error.SummaryMismatch,
        validateArtifact(testing.allocator, artifact),
    );

    var changed_samples = pressure_fixture;
    changed_samples[5].ri_proc_start_abstime += 1;
    artifact = goodArtifact();
    artifact.pressure_samples = &changed_samples;
    try testing.expectError(
        error.IdentityChanged,
        validateArtifact(testing.allocator, artifact),
    );
}

test "run peak includes post-drain and post delta saturates below baseline" {
    var high_post = post_fixture;
    for (&high_post) |*sample| {
        sample.ri_resident_size = 130_000_000;
        sample.ri_phys_footprint = 129_000_000;
    }
    var artifact = goodArtifact();
    artifact.post_drain_samples = &high_post;
    artifact.post_drain_rss_bytes = 130_000_000;
    artifact.run_peak_rss_bytes = 130_000_000;
    artifact.post_drain_delta_bytes = 30_000_000;
    artifact.run_peak_delta_bytes = 30_000_000;
    try validateArtifact(testing.allocator, artifact);

    var low_post = post_fixture;
    for (&low_post) |*sample| {
        sample.ri_resident_size = 90_000_000;
        sample.ri_phys_footprint = 89_000_000;
    }
    artifact = goodArtifact();
    artifact.post_drain_samples = &low_post;
    artifact.post_drain_rss_bytes = 90_000_000;
    artifact.post_drain_delta_bytes = 0;
    try validateArtifact(testing.allocator, artifact);
}

test "timestamp reversal and pressure gap allow runner jitter to 125ms" {
    var reversed = pressure_fixture;
    reversed[5].monotonic_ns = reversed[4].monotonic_ns;
    var artifact = goodArtifact();
    artifact.pressure_samples = &reversed;
    try testing.expectError(
        error.TimestampOrder,
        validateArtifact(testing.allocator, artifact),
    );

    var delayed = pressure_fixture;
    for (delayed[5..]) |*sample| sample.monotonic_ns += 115_000_000;
    try validateSamples(
        goodArtifact(),
        &delayed,
        pressure_sample_gap_max_ns,
    );

    var too_delayed = pressure_fixture;
    for (too_delayed[5..]) |*sample| sample.monotonic_ns += 116_000_000;
    try testing.expectError(
        error.InvalidSampleInterval,
        validateSamples(
            goodArtifact(),
            &too_delayed,
            pressure_sample_gap_max_ns,
        ),
    );

    artifact = goodArtifact();
    artifact.stall_at_ns = 1_251_000_000;
    artifact.controller_input_at_ns = 1_253_000_000;
    artifact.healthy_marker_at_ns = 1_259_000_000;
    try testing.expectError(
        error.InvalidSampleCount,
        validateArtifact(testing.allocator, artifact),
    );

    // median 이 상한을 넘으면 거절한다 — 절반 넘게 느린 것은 딸꾹질이 아니다.
    artifact = goodArtifact();
    var wake_median = wake_fixture;
    for (&wake_median, 0..) |*sample, index| {
        sample.input_at_ns = 900_000_000 + index * 30_000_000;
        sample.input_accepted_at_ns = sample.input_at_ns + 1_000_000;
        sample.delivery_latency_ns = if (index < 3)
            5_000_000
        else
            output_wake_median_cap_ns + 1;
        sample.marker_at_ns = sample.input_accepted_at_ns + sample.delivery_latency_ns;
        sample.end_to_end_latency_ns = sample.marker_at_ns - sample.input_at_ns;
    }
    artifact.wake_samples = &wake_median;
    artifact.wake_latency_min_ns = 5_000_000;
    artifact.wake_latency_median_ns = output_wake_median_cap_ns + 1;
    artifact.wake_latency_p95_ns = output_wake_median_cap_ns + 1;
    artifact.wake_latency_max_ns = output_wake_median_cap_ns + 1;
    try testing.expectError(
        error.InvalidProgress,
        validateArtifact(testing.allocator, artifact),
    );

    // **딸꾹질 하나는 통과한다** — 이 회차가 고치는 자리다. 가장 나쁜 표본 하나가 옛 꼬리 상한을
    // 넘어도 p95 가 그것을 빼므로 게이트는 초록이다(실측: 28.3 ms 한 번에 게이트가 빨갰다).
    artifact = goodArtifact();
    var wake_hiccup = wake_fixture;
    {
        const last = &wake_hiccup[wake_hiccup.len - 1];
        last.delivery_latency_ns = output_wake_tail_cap_ns + 8 * std.time.ns_per_ms;
        last.marker_at_ns = last.input_accepted_at_ns + last.delivery_latency_ns;
        last.end_to_end_latency_ns = last.marker_at_ns - last.input_at_ns;
    }
    artifact.wake_samples = &wake_hiccup;
    artifact.wake_latency_max_ns = wake_hiccup[wake_hiccup.len - 1].delivery_latency_ns;
    try validateArtifact(testing.allocator, artifact);

    // **꼬리가 진짜로 느리면 거절한다.** 딸꾹질 하나가 아니라 상위 구간이 통째로 느려야 p95 가
    // 움직인다 — 위 `wake_hiccup` 과 짝을 이루는 대조군이다(하나는 통과, 여럿은 거절).
    artifact = goodArtifact();
    var wake_tail = wake_fixture;
    for (wake_tail[p95Index(wake_sample_count)..]) |*sample| {
        sample.delivery_latency_ns = output_wake_tail_cap_ns + 1;
        sample.marker_at_ns = sample.input_accepted_at_ns + sample.delivery_latency_ns;
        sample.end_to_end_latency_ns = sample.marker_at_ns - sample.input_at_ns;
    }
    artifact.wake_samples = &wake_tail;
    artifact.wake_latency_p95_ns = output_wake_tail_cap_ns + 1;
    artifact.wake_latency_max_ns = output_wake_tail_cap_ns + 1;
    try testing.expectError(
        error.InvalidProgress,
        validateArtifact(testing.allocator, artifact),
    );

    // **멈춤은 p95 가 아니라 max 가 잡는다.** 표본 하나가 몇 백 ms 면 딸꾹질이 아니다.
    artifact = goodArtifact();
    var wake_hang = wake_fixture;
    {
        const last = &wake_hang[wake_hang.len - 1];
        last.delivery_latency_ns = output_wake_hang_cap_ns + 1;
        last.marker_at_ns = last.input_accepted_at_ns + last.delivery_latency_ns;
        last.end_to_end_latency_ns = last.marker_at_ns - last.input_at_ns;
    }
    artifact.wake_samples = &wake_hang;
    artifact.wake_latency_max_ns = output_wake_hang_cap_ns + 1;
    try testing.expectError(
        error.InvalidProgress,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.idle_wake_drain_delta = 1;
    try testing.expectError(
        error.InvalidProgress,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.idle_cpu_after.user_time_ns =
        artifact.idle_cpu_before.user_time_ns + idle_cpu_total_cap_ns + 1;
    artifact.idle_cpu_total_delta_ns = idle_cpu_total_cap_ns + 1 +
        (artifact.idle_cpu_after.system_time_ns - artifact.idle_cpu_before.system_time_ns);
    try testing.expectError(
        error.InvalidProgress,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.active_wake_notify_delta = wake_sample_count - 1;
    try testing.expectError(
        error.InvalidProgress,
        validateArtifact(testing.allocator, artifact),
    );
}

test "settle samples allow runner scheduling to 250ms but reject larger gaps" {
    var runner_delayed = baseline_fixture;
    for (runner_delayed[5..]) |*sample| sample.monotonic_ns += 160_000_000;
    try validateSamples(
        goodArtifact(),
        &runner_delayed,
        settle_sample_gap_max_ns,
    );

    var too_delayed = baseline_fixture;
    for (too_delayed[5..]) |*sample| sample.monotonic_ns += 231_000_000;
    try testing.expectError(
        error.InvalidSampleInterval,
        validateSamples(
            goodArtifact(),
            &too_delayed,
            settle_sample_gap_max_ns,
        ),
    );
}

test "missing stall and marker ordering regressions fail" {
    var artifact = goodArtifact();
    artifact.slow_eagain_count = 0;
    artifact.slow_pollout_absent_count = 0;
    try testing.expectError(
        error.MissingStallEvidence,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.controller_input_at_ns = artifact.stall_at_ns;
    try testing.expectError(
        error.InvalidProgress,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.first_stall_connection_id += 1;
    try testing.expectError(
        error.MissingStallEvidence,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.healthy_marker_matches_nonce = false;
    try testing.expectError(
        error.InvalidProgress,
        validateArtifact(testing.allocator, artifact),
    );
}

test "peer waitpid admission and split workload evidence regressions fail" {
    var artifact = goodArtifact();
    artifact.local_peer_pid += 1;
    try testing.expectError(
        error.InvalidIdentity,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.waitpid_pid += 1;
    try testing.expectError(
        error.InvalidIdentity,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.pty_child_ppid += 1;
    try testing.expectError(
        error.InvalidIdentity,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.pty_child_uid += 1;
    try testing.expectError(
        error.InvalidIdentity,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.pty_child_start_tvusec = std.time.us_per_s;
    try testing.expectError(
        error.InvalidIdentity,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.pty_child_identity_rechecked = false;
    try testing.expectError(
        error.InvalidIdentity,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.pty_probe_fds_closed = false;
    try testing.expectError(
        error.InvalidIdentity,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.stale_admission_count = 1;
    try testing.expectError(
        error.InvalidRoleCount,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.pressure_generated_bytes -= 1;
    try testing.expectError(
        error.InvalidWorkload,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.marker_input_bytes = 32;
    try testing.expectError(
        error.InvalidWorkload,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.baseline_pty_output_bytes -= 1;
    try testing.expectError(
        error.InvalidWorkload,
        validateArtifact(testing.allocator, artifact),
    );
}

test "analytic formula cap and final ledger regressions fail" {
    var artifact = goodArtifact();
    artifact.analytic_cap_bytes += 1;
    try testing.expectError(
        error.LedgerFormulaMismatch,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.peak_ledger_slot_queue_bytes = per_slot_bytes + 1;
    try testing.expectError(
        error.LedgerCapExceeded,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.final_ledger_resident_bytes = 1;
    try testing.expectError(
        error.FinalLedgerNotZero,
        validateArtifact(testing.allocator, artifact),
    );
}

test "RSS cap deadline and cleanup regressions fail" {
    var high_pressure = pressure_fixture;
    for (&high_pressure) |*sample| sample.ri_resident_size = 230_000_000;
    var artifact = goodArtifact();
    artifact.pressure_samples = &high_pressure;
    artifact.peak_rss_bytes = 230_000_000;
    artifact.run_peak_rss_bytes = 230_000_000;
    artifact.peak_delta_bytes = 130_000_000;
    artifact.run_peak_delta_bytes = 130_000_000;
    try testing.expectError(
        error.RssCapExceeded,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.elapsed_ms = deadline_ms + 1;
    try testing.expectError(
        error.DeadlineExceeded,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.host_reaped = false;
    try testing.expectError(
        error.CleanupIncomplete,
        validateArtifact(testing.allocator, artifact),
    );

    artifact = goodArtifact();
    artifact.final_active_clients = 1;
    try testing.expectError(
        error.CleanupIncomplete,
        validateArtifact(testing.allocator, artifact),
    );
}
