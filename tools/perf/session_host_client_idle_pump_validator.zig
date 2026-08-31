//! P4 E3c generation-backed GUI client idle-pump artifact validator.

const std = @import("std");

const schema_name = "maru.session-host-client-idle-pump-macos.v4";
const scenario_name = "generation-backed-gui-client-idle-pump";
const build_mode = "ReleaseFast";
const sample_api = "proc_pid_rusage:RUSAGE_INFO_V4";
const expected_runtime_counts = [_]u32{ 1, 10, 15, 100 };
const idle_frame_count: u32 = 60;
const max_owners_per_frame: u32 = 16;
const idle_observation_min_ns: u64 = 900 * std.time.ns_per_ms;
// `usleep` is a lower bound, not a frame-clock guarantee. The macos-15 shared runner stretched
// sixty nominal 16.7ms waits to 5.55s while the measured process CPU stayed below 3ms. Keep a
// generous liveness ceiling here; the actual work budget remains the independent 25ms CPU cap.
const idle_observation_max_ns: u64 = 10 * std.time.ns_per_s;
// The first ReleaseFast RED peaked at 4.926ms across the four scale rows. Five times that
// observed cost leaves machine noise headroom while still rejecting a client that burns more
// than 2.5% of one core during the nominal one-second idle window.
const idle_client_cpu_cap_ns: u64 = 25 * std.time.ns_per_ms;
/// 마커 왕복을 몇 번 재는가. 생산자의 `marker_sample_count` 와 **같은 수**여야 한다 — 여기서
/// 고정해 두면 생산자가 표본을 줄이는 변경이 조용히 통과하지 못한다.
const marker_sample_count: usize = 40;

/// nearest-rank p95 의 0-based index — `ceil(0.95 n) - 1`. 40 이면 37 이라 **가장 나쁜 둘을 버린다**.
fn p95Index(n: usize) usize {
    return (n * 95 + 99) / 100 - 1;
}

/// **주 판정은 벽시계가 아니라 프레임 턴 수다.** `docs/performance-budget.md` 의 규율 —
/// 「선은 실측 두 값 사이에 둔다: 지금 값과, 그것이 잡겠다는 회귀의 값. 둘이 겹치면(회귀가 실측의
/// 5배 안쪽이면) 벽시계 대신 **기계 속도와 무관한 값**을 쓴다」 — 이 게이트가 정확히 그 경우다.
///
/// - **지금 값**: 로컬 실측 40회에서 턴이 1(7회)·2(22회)·3(11회), p95 = 3, max = 3.
/// - **잡겠다는 회귀**: 비동기 wake 가 안 걸려 전달이 폴링으로 떨어지는 것. 그러면 마커는 idle
///   cadence 의 주기적 훑기에서만 보이므로 턴이 **수십**으로 뛴다.
///
/// 6 은 실측 max 의 두 배이고 회귀 값보다 한참 아래다. **러너가 느려도 이 수는 안 변한다** —
/// 턴 하나가 길어질 뿐이다.
const marker_frame_turns_p95_cap: u32 = 6;

// E3b's 20ms cap starts after host input acceptance. E3c starts at the GUI enqueue boundary and
// therefore composes one input turn, host delivery, one apply turn, and bounded dispatch margin.
//
/// **벽시계는 이제 재앙 감지선이다.** 옛 판은 왕복을 **한 번만** 재서 그 값이 60ms 선과 직접
/// 대결했고, 로컬 실측 p95 가 이미 27~43ms 라 **1.4배** 여유였다 — `docs/performance-budget.md` 가
/// 「감지선이 아니라 동전 던지기」라고 부르는 상태다. 같은 날(2026-09-01) 기록된 선례가 같은
/// 모양이었다: `wake_apply_latency_budget_ns` 가 60ms 선에 CI 정상 36~42ms 라 **무관한 PR 다섯을
/// 막았고**, 실측의 4.8배인 200ms 로 옮겼다. 여기도 같은 배율을 쓴다(로컬 p95 27~43ms 의 4.6~7배).
///
/// 성능 계약 자체는 위 `marker_frame_turns_p95_cap` 이 진다.
const marker_latency_p95_cap_ns: u64 = 200 * std.time.ns_per_ms;

/// **최댓값은 성능이 아니라 살아 있음을 잰다.** p95 로 옮기면서 `max` 를 아예 안 보면 한 회차가
/// 통째로 멎어도 나머지 서른아홉이 그것을 가린다. 실측 max 43ms 의 열 배 남짓으로 두되 **비워
/// 두지는 않는다**(`session_host_slow_observer_validator` 의 `output_wake_hang_cap_ns` 와 같은 방침).
const marker_latency_hang_cap_ns: u64 = 500 * std.time.ns_per_ms;

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
    metadata_event_count: u64 = 0,
    screen_event_count: u64 = 0,
    ended_event_count: u64 = 0,
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

fn validateArtifact(artifact: Artifact) !void {
    if (!std.mem.eql(u8, artifact.schema, schema_name) or
        !std.mem.eql(u8, artifact.scenario, scenario_name) or
        !std.mem.eql(u8, artifact.build_mode, build_mode) or
        !std.mem.eql(u8, artifact.sample_api, sample_api) or
        !artifact.uses_generation_attachment or
        artifact.max_owners_per_frame != max_owners_per_frame or
        artifact.idle_frame_count != idle_frame_count)
        return error.InvalidIdentity;
    if (artifact.scale_samples.len != expected_runtime_counts.len) return error.InvalidScaleRows;
    for (artifact.scale_samples, expected_runtime_counts) |sample, expected_runtime_count| {
        // **여기도 모양과 시간이 섞여 있었다.** `error.InvalidScaleRow` 하나 뒤에 다섯 조건이
        // 묶여 있어서, 빨간 런이 「이 행이 틀렸다」까지만 말하고 **행이 잘못 만들어진 것**과
        // **러너가 느려 창이 늘어난 것**을 못 갈랐다. 마커와 같은 병이라 같이 가른다.
        if (sample.runtime_count != expected_runtime_count) return error.ScaleRowRuntimeCountMismatch;
        if (sample.frame_count != idle_frame_count) return error.ScaleRowFrameCountMismatch;
        // 산술 항등식 — 어느 기계에서나 성립한다.
        if (sample.cpu_total_delta_ns != sample.cpu_user_delta_ns + sample.cpu_system_delta_ns)
            return error.ScaleRowCpuSplitMismatch;
        // **여기부터가 측정값이다.** 관측 창은 `usleep` 하한이라 러너가 늘일 수 있고(공유 러너에서
        // 60번의 16.7ms 대기가 5.55s 로 늘어난 적이 있다), CPU 상한은 실제 일의 예산이다. 셋을
        // 갈라 두어야 빨간 런에서 「늘어졌다」와 「일을 너무 했다」가 구별된다.
        if (sample.observation_ns < idle_observation_min_ns) return error.ScaleRowObservationTooShort;
        if (sample.observation_ns > idle_observation_max_ns) return error.ScaleRowObservationTooLong;
        if (sample.cpu_total_delta_ns > idle_client_cpu_cap_ns) return error.ScaleRowCpuOverCap;
        const expected_selected_owner_count: u64 =
            @as(u64, @min(expected_runtime_count, max_owners_per_frame)) * idle_frame_count;
        if (sample.selected_owner_count != expected_selected_owner_count or
            sample.pump_delta_count != expected_selected_owner_count or
            sample.timestamp_seal_count != sample.pump_delta_count or
            sample.metadata_event_count != 0 or sample.screen_event_count != 0 or
            sample.ended_event_count != 0)
            return error.InvalidIdleCounters;
        // The first RED artifact disproved both suspected idle paths. Keep that finding as a
        // fail-closed product invariant instead of allowing a 4,096-slot scan to regress green.
        if (sample.client_slot_registry_visit_count != 0 or sample.socket_read_attempt_count != 0)
            return error.UnexpectedIdleWork;
    }
    try validateMarker(artifact);
    if (!artifact.host_reaped or !artifact.client_fds_closed or
        !artifact.socket_removed or !artifact.directory_removed)
        return error.CleanupIncomplete;
}

/// The marker round: one enqueue at the GUI boundary, pumped until the target runtime sees it.
///
/// **Each condition gets its own error.** They used to be eleven `or` terms behind a single
/// `error.InvalidMarker`, so a red run said only "the marker is wrong" — it could not say whether
/// the run was mis-shaped (no frames, sibling leakage, seal drift) or merely *slow*. Those need
/// opposite responses: the first is a product defect, the second is a timing cap that a shared CI
/// runner can breach without anything being broken. Telling them apart is the whole point.
///
/// **Order is load-bearing.** `marker_frame_count == 0` must be rejected before the wake
/// accounting below, which subtracts one from it — the old single `if` was safe only because `or`
/// short-circuits. Splitting the terms without keeping this first would turn an empty run into a
/// `u32` underflow instead of a diagnosis.
fn validateMarker(artifact: Artifact) !void {
    // Identity of the marker scenario: it runs against the largest scale row.
    if (artifact.marker_runtime_count != 100) return error.MarkerRuntimeCountMismatch;

    // The marker must actually arrive, and only at its target.
    if (artifact.marker_target_output_events == 0) return error.MarkerTargetSawNoOutput;
    if (artifact.marker_sibling_output_events != 0) return error.MarkerSiblingSawOutput;

    // 표본 수는 여기서 고정한다 — 생산자가 줄이면 p95 의 뜻이 달라진다.
    if (artifact.marker_sample_count != marker_sample_count) return error.MarkerSampleCountMismatch;
    if (artifact.marker_latency_samples_ns.len != marker_sample_count)
        return error.MarkerSampleCountMismatch;
    if (artifact.marker_frame_samples.len != marker_sample_count)
        return error.MarkerSampleCountMismatch;

    // Shape of the run. Zero here means the measurement never happened — a missing number, not a
    // fast one, and it must never read as "well under the cap".
    // **회차마다 프레임이 최소 하나다.** 그래서 총 프레임은 회차 수보다 작을 수 없고, 이 갈래가
    // 아래 회계식(`frame_count - 회차 수`)보다 **먼저** 서야 한다 — 표본이 하나였을 때는 `== 0`
    // 이면 충분했지만, 여러 회차로 일반화하면서 그 전제가 커졌다(안 고치면 u32 underflow 다).
    if (artifact.marker_frame_count < marker_sample_count) return error.MarkerFrameCountBelowRounds;
    for (artifact.marker_latency_samples_ns) |sample| {
        if (sample == 0) return error.MarkerLatencyMissing;
    }
    if (artifact.marker_max_frame_elapsed_ns == 0) return error.MarkerFrameElapsedMissing;

    // 회차마다 「마지막 프레임 빼고 한 번씩 기다렸다」이므로, 누적하면 회차 수만큼 빠진다.
    if (artifact.marker_readable_wake_count + artifact.marker_timer_timeout_count !=
        artifact.marker_frame_count - @as(u32, @intCast(marker_sample_count)))
        return error.MarkerWakeAccountingMismatch;

    // Pump deltas track selected owners, with at most one extra entry per frame.
    if (artifact.marker_pump_delta_count < artifact.marker_selected_owner_count)
        return error.MarkerPumpDeltaBelowOwners;
    if (artifact.marker_pump_delta_count >
        artifact.marker_selected_owner_count + artifact.marker_frame_count)
        return error.MarkerPumpDeltaAboveOwners;
    if (artifact.marker_pump_delta_count != artifact.marker_timestamp_seal_count)
        return error.MarkerSealCountMismatch;

    // **여기부터가 측정값이다.** 위는 전부 어느 기계에서나 성립하는 모양 불변식이고, 아래 둘만
    // 느린 러너가 혼자 밟을 수 있다. 이름이 갈려 있어야 빨간 런을 아티팩트 안 열고도 읽는다.
    // **성능 계약은 프레임 턴이 진다** — 기계 속도와 무관한 값이라 러너가 붐벼도 안 흔들린다.
    var turns: [marker_sample_count]u32 = undefined;
    @memcpy(&turns, artifact.marker_frame_samples);
    std.mem.sort(u32, &turns, {}, std.sort.asc(u32));
    for (turns) |turn| {
        // 회차마다 프레임이 최소 하나 돈다 — 0 이면 그 회차는 아예 안 잰 것이다.
        if (turn == 0) return error.MarkerFrameTurnsMissing;
    }
    if (turns[p95Index(marker_sample_count)] > marker_frame_turns_p95_cap)
        return error.MarkerFrameTurnsP95OverCap;

    // 벽시계는 재앙 감지선이다(위 상수 주석 참조).
    var sorted: [marker_sample_count]u64 = undefined;
    @memcpy(&sorted, artifact.marker_latency_samples_ns);
    std.mem.sort(u64, &sorted, {}, std.sort.asc(u64));
    if (sorted[p95Index(marker_sample_count)] > marker_latency_p95_cap_ns)
        return error.MarkerLatencyP95OverCap;
    // 꼬리가 아니라 **멈춤**을 본다 — 한 회차가 통째로 멎으면 나머지가 그것을 가린다.
    if (sorted[marker_sample_count - 1] > marker_latency_hang_cap_ns) return error.MarkerLatencyHang;
}

fn validateBytes(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parsed = std.json.parseFromSlice(Artifact, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch return error.InvalidJsonSchema;
    defer parsed.deinit();
    try validateArtifact(parsed.value);
}

fn usage(stderr: *std.Io.Writer) !void {
    try stderr.writeAll("usage: session-host-client-idle-pump-validator <artifact.json>\n");
    try stderr.flush();
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return usage(stderr);
    if (args.next() != null) return usage(stderr);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    validateBytes(allocator, bytes) catch |err| {
        try stderr.print("E3c artifact validation failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
}

test "P4 E3c validator rejects inferred counter, latency, and cleanup drift" {
    const rows = [_]ScaleSample{
        .{ .runtime_count = 1, .frame_count = 60, .observation_ns = std.time.ns_per_s, .cpu_user_delta_ns = 1, .cpu_system_delta_ns = 2, .cpu_total_delta_ns = 3, .selected_owner_count = 60, .pump_delta_count = 60, .timestamp_seal_count = 60, .client_slot_registry_visit_count = 0, .socket_read_attempt_count = 0 },
        .{ .runtime_count = 10, .frame_count = 60, .observation_ns = std.time.ns_per_s, .cpu_user_delta_ns = 2, .cpu_system_delta_ns = 3, .cpu_total_delta_ns = 5, .selected_owner_count = 600, .pump_delta_count = 600, .timestamp_seal_count = 600, .client_slot_registry_visit_count = 0, .socket_read_attempt_count = 0 },
        .{ .runtime_count = 15, .frame_count = 60, .observation_ns = std.time.ns_per_s, .cpu_user_delta_ns = 3, .cpu_system_delta_ns = 4, .cpu_total_delta_ns = 7, .selected_owner_count = 900, .pump_delta_count = 900, .timestamp_seal_count = 900, .client_slot_registry_visit_count = 0, .socket_read_attempt_count = 0 },
        .{ .runtime_count = 100, .frame_count = 60, .observation_ns = std.time.ns_per_s, .cpu_user_delta_ns = 4, .cpu_system_delta_ns = 5, .cpu_total_delta_ns = 9, .selected_owner_count = 960, .pump_delta_count = 960, .timestamp_seal_count = 960, .client_slot_registry_visit_count = 0, .socket_read_attempt_count = 0 },
    };
    // 전부 1ms — p95 도 max 도 상한 아래다.
    var latency_samples = [_]u64{std.time.ns_per_ms} ** marker_sample_count;
    // 회차마다 프레임 하나 — 아래 회계식(`frames - 회차 수`)과 맞는다.
    var frame_samples = [_]u32{1} ** marker_sample_count;
    var artifact = Artifact{
        .schema = schema_name,
        .scenario = scenario_name,
        .build_mode = build_mode,
        .sample_api = sample_api,
        .uses_generation_attachment = true,
        .max_owners_per_frame = 16,
        .idle_frame_count = 60,
        .scale_samples = &rows,
        .marker_runtime_count = 100,
        .marker_target_output_events = 1,
        .marker_sibling_output_events = 0,
        .marker_sample_count = marker_sample_count,
        .marker_latency_samples_ns = &latency_samples,
        .marker_frame_samples = &frame_samples,
        .marker_readable_wake_count = 0,
        .marker_timer_timeout_count = 0,
        // 회차마다 프레임 하나로 끝난 셈이라 기다린 횟수는 0 이다(`frames - 회차 수`).
        .marker_frame_count = marker_sample_count,
        .marker_max_frame_elapsed_ns = 1,
        .marker_selected_owner_count = 16,
        .marker_pump_delta_count = 16,
        .marker_timestamp_seal_count = 16,
        .host_reaped = true,
        .client_fds_closed = true,
        .socket_removed = true,
        .directory_removed = true,
    };
    try validateArtifact(artifact);
    // **조건마다 자기 오류를 낸다.** 열한 개가 `or` 하나에 묶여 있던 동안에는 빨간 런이
    // 「마커가 틀렸다」까지만 말했고, **모양이 깨진 것**과 **느린 것**을 못 갈랐다. 아래가 그
    // 구분을 고정한다 — 둘을 다시 합치면 여기서 깨진다.
    const Case = struct {
        name: []const u8,
        want: anyerror,
        apply: *const fn (*Artifact) void,
    };
    const cases = [_]Case{
        .{ .name = "runtime count", .want = error.MarkerRuntimeCountMismatch, .apply = struct {
            fn f(a: *Artifact) void {
                a.marker_runtime_count = 99;
            }
        }.f },
        .{ .name = "target saw nothing", .want = error.MarkerTargetSawNoOutput, .apply = struct {
            fn f(a: *Artifact) void {
                a.marker_target_output_events = 0;
            }
        }.f },
        .{ .name = "sibling saw output", .want = error.MarkerSiblingSawOutput, .apply = struct {
            fn f(a: *Artifact) void {
                a.marker_sibling_output_events = 1;
            }
        }.f },
        // **빈 런은 underflow 가 아니라 진단이 되어야 한다.** 회차마다 프레임이 하나씩은 도므로
        // 하나만 모자라도 그 런은 성립하지 않는다.
        .{ .name = "frame count below rounds", .want = error.MarkerFrameCountBelowRounds, .apply = struct {
            fn f(a: *Artifact) void {
                a.marker_frame_count = marker_sample_count - 1;
            }
        }.f },
        .{ .name = "frame elapsed missing", .want = error.MarkerFrameElapsedMissing, .apply = struct {
            fn f(a: *Artifact) void {
                a.marker_max_frame_elapsed_ns = 0;
            }
        }.f },
        .{
            .name = "wake accounting",
            .want = error.MarkerWakeAccountingMismatch,
            .apply = struct {
                fn f(a: *Artifact) void {
                    // 회차 수보다 하나 많으면 한 번은 기다렸어야 하는데 0 으로 적혀 있다.
                    a.marker_frame_count = marker_sample_count + 1;
                }
            }.f,
        },
        .{ .name = "pump delta below owners", .want = error.MarkerPumpDeltaBelowOwners, .apply = struct {
            fn f(a: *Artifact) void {
                a.marker_pump_delta_count = a.marker_selected_owner_count - 1;
            }
        }.f },
        .{ .name = "pump delta above owners", .want = error.MarkerPumpDeltaAboveOwners, .apply = struct {
            fn f(a: *Artifact) void {
                a.marker_pump_delta_count = a.marker_selected_owner_count + a.marker_frame_count + 1;
            }
        }.f },
        .{ .name = "seal count", .want = error.MarkerSealCountMismatch, .apply = struct {
            fn f(a: *Artifact) void {
                a.marker_timestamp_seal_count = a.marker_pump_delta_count + 1;
            }
        }.f },
        .{ .name = "sample count", .want = error.MarkerSampleCountMismatch, .apply = struct {
            fn f(a: *Artifact) void {
                a.marker_sample_count = marker_sample_count - 1;
            }
        }.f },
    };
    for (cases) |case| {
        var drifted = artifact;
        case.apply(&drifted);
        std.testing.expectError(case.want, validateArtifact(drifted)) catch |err| {
            std.debug.print("marker 조건 «{s}» 가 자기 오류를 안 냈다\n", .{case.name});
            return err;
        };
    }

    // **측정값 두 갈래는 표본 배열을 흔들어 본다.** p95 와 max 가 갈려 있다는 것이 이 판정자의
    // 요점이다 — 하나로 합치면 「꼬리가 느리다」와 「한 회차가 멎었다」가 같은 이름이 된다.
    {
        // 상한을 넘는 표본을 **셋** 둔다. 40 표본의 p95 는 index 37 이라 둘까지는 버려진다 —
        // 셋이라야 p95 가 실제로 넘는다. (둘만 두면 이 판정자가 조용히 통과한다.)
        var drifted = artifact;
        var slow = [_]u64{std.time.ns_per_ms} ** marker_sample_count;
        slow[0] = marker_latency_p95_cap_ns + 1;
        slow[1] = marker_latency_p95_cap_ns + 1;
        slow[2] = marker_latency_p95_cap_ns + 1;
        drifted.marker_latency_samples_ns = &slow;
        try std.testing.expectError(error.MarkerLatencyP95OverCap, validateArtifact(drifted));

        // 둘만 넘으면 p95 는 통과한다 — 그것이 「가장 나쁜 둘을 버린다」의 뜻이다.
        var tolerated = [_]u64{std.time.ns_per_ms} ** marker_sample_count;
        tolerated[0] = marker_latency_p95_cap_ns + 1;
        tolerated[1] = marker_latency_p95_cap_ns + 1;
        drifted.marker_latency_samples_ns = &tolerated;
        try validateArtifact(drifted);

        // 그러나 **멈춤**은 하나만으로도 잡는다.
        var hung = [_]u64{std.time.ns_per_ms} ** marker_sample_count;
        hung[7] = marker_latency_hang_cap_ns + 1;
        drifted.marker_latency_samples_ns = &hung;
        try std.testing.expectError(error.MarkerLatencyHang, validateArtifact(drifted));

        // 값이 아예 없는 표본은 「빠르다」가 아니라 **안 쟀다**이다.
        var missing = [_]u64{std.time.ns_per_ms} ** marker_sample_count;
        missing[19] = 0;
        drifted.marker_latency_samples_ns = &missing;
        try std.testing.expectError(error.MarkerLatencyMissing, validateArtifact(drifted));
    }

    // **프레임 턴이 주 판정이다.** 벽시계가 전부 상한 아래여도 턴이 뛰면 잡아야 한다 — 전달이
    // 폴링으로 떨어지는 회귀가 정확히 그 모양이다(지연은 러너에 묻히고 턴만 뛴다).
    {
        var drifted = artifact;
        var slow_turns = [_]u32{1} ** marker_sample_count;
        // 셋을 넘겨야 p95(index 37)가 실제로 넘는다 — 둘까지는 버려진다.
        slow_turns[0] = marker_frame_turns_p95_cap + 1;
        slow_turns[1] = marker_frame_turns_p95_cap + 1;
        slow_turns[2] = marker_frame_turns_p95_cap + 1;
        drifted.marker_frame_samples = &slow_turns;
        // 회계식이 프레임 총합을 보므로 함께 맞춘다.
        drifted.marker_frame_count = 0;
        for (slow_turns) |t| drifted.marker_frame_count += t;
        drifted.marker_readable_wake_count = drifted.marker_frame_count - @as(u32, @intCast(marker_sample_count));
        drifted.marker_pump_delta_count = drifted.marker_selected_owner_count;
        drifted.marker_timestamp_seal_count = drifted.marker_pump_delta_count;
        try std.testing.expectError(error.MarkerFrameTurnsP95OverCap, validateArtifact(drifted));

        // 턴 0 은 「빠르다」가 아니라 그 회차를 안 잰 것이다.
        var no_turn = [_]u32{1} ** marker_sample_count;
        no_turn[5] = 0;
        drifted.marker_frame_samples = &no_turn;
        drifted.marker_frame_count = marker_sample_count;
        drifted.marker_readable_wake_count = 0;
        try std.testing.expectError(error.MarkerFrameTurnsMissing, validateArtifact(drifted));
    }

    artifact.client_fds_closed = false;
    try std.testing.expectError(error.CleanupIncomplete, validateArtifact(artifact));
    artifact.client_fds_closed = true;
    var drifted_rows = rows;
    drifted_rows[2].client_slot_registry_visit_count = 1;
    artifact.scale_samples = &drifted_rows;
    try std.testing.expectError(error.UnexpectedIdleWork, validateArtifact(artifact));
    drifted_rows[2].client_slot_registry_visit_count = 0;
    drifted_rows[2].cpu_total_delta_ns = idle_client_cpu_cap_ns + 1;
    drifted_rows[2].cpu_user_delta_ns = drifted_rows[2].cpu_total_delta_ns;
    drifted_rows[2].cpu_system_delta_ns = 0;
    try std.testing.expectError(error.ScaleRowCpuOverCap, validateArtifact(artifact));
    drifted_rows[2] = rows[2];
    drifted_rows[2].observation_ns = idle_observation_max_ns + 1;
    try std.testing.expectError(error.ScaleRowObservationTooLong, validateArtifact(artifact));
    drifted_rows[2].observation_ns = idle_observation_min_ns - 1;
    try std.testing.expectError(error.ScaleRowObservationTooShort, validateArtifact(artifact));
    drifted_rows[2] = rows[2];
    drifted_rows[2].runtime_count = 999;
    try std.testing.expectError(error.ScaleRowRuntimeCountMismatch, validateArtifact(artifact));
    drifted_rows[2] = rows[2];
    drifted_rows[2].frame_count = idle_frame_count + 1;
    try std.testing.expectError(error.ScaleRowFrameCountMismatch, validateArtifact(artifact));
    drifted_rows[2] = rows[2];
    drifted_rows[2].cpu_system_delta_ns += 1; // 합이 안 맞는다
    try std.testing.expectError(error.ScaleRowCpuSplitMismatch, validateArtifact(artifact));
}
