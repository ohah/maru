//! P4 E3c generation-backed GUI client idle-pump artifact validator.

const std = @import("std");

const schema_name = "maru.session-host-client-idle-pump-macos.v3";
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
// E3b's 20ms cap starts after host input acceptance. E3c starts at the GUI enqueue boundary and
// therefore composes one input turn, host delivery, one apply turn, and bounded dispatch margin.
const marker_latency_cap_ns: u64 = 60 * std.time.ns_per_ms;

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
    marker_latency_ns: u64,
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

    // Shape of the run. Zero here means the measurement never happened — a missing number, not a
    // fast one, and it must never read as "well under the cap".
    if (artifact.marker_frame_count == 0) return error.MarkerNoFrames;
    if (artifact.marker_latency_ns == 0) return error.MarkerLatencyMissing;
    if (artifact.marker_max_frame_elapsed_ns == 0) return error.MarkerFrameElapsedMissing;

    // Every frame but the last blocked exactly once — on a readable wake or on the timer. The last
    // frame is the one that saw the marker, so it never waited.
    if (artifact.marker_readable_wake_count + artifact.marker_timer_timeout_count !=
        artifact.marker_frame_count - 1)
        return error.MarkerWakeAccountingMismatch;

    // Pump deltas track selected owners, with at most one extra entry per frame.
    if (artifact.marker_pump_delta_count < artifact.marker_selected_owner_count)
        return error.MarkerPumpDeltaBelowOwners;
    if (artifact.marker_pump_delta_count >
        artifact.marker_selected_owner_count + artifact.marker_frame_count)
        return error.MarkerPumpDeltaAboveOwners;
    if (artifact.marker_pump_delta_count != artifact.marker_timestamp_seal_count)
        return error.MarkerSealCountMismatch;

    // **The only timing condition.** Everything above is a shape invariant that holds on any
    // machine; this one is a measurement compared against a cap, so it is the one that a slow
    // shared runner can trip on its own. Keeping it alone under its own name is what lets a red
    // run be read without opening the artifact.
    if (artifact.marker_latency_ns > marker_latency_cap_ns) return error.MarkerLatencyOverCap;
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
        .marker_latency_ns = std.time.ns_per_ms,
        .marker_readable_wake_count = 0,
        .marker_timer_timeout_count = 0,
        .marker_frame_count = 1,
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
        // **빈 런은 underflow 가 아니라 진단이 되어야 한다.** 이 갈래가 아래 wake 회계보다
        // 먼저 서지 않으면 `marker_frame_count - 1` 이 u32 를 넘어간다.
        .{ .name = "no frames", .want = error.MarkerNoFrames, .apply = struct {
            fn f(a: *Artifact) void {
                a.marker_frame_count = 0;
            }
        }.f },
        .{ .name = "latency missing", .want = error.MarkerLatencyMissing, .apply = struct {
            fn f(a: *Artifact) void {
                a.marker_latency_ns = 0;
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
                    a.marker_frame_count = 3; // 두 번 기다렸어야 하는데 0 으로 적혀 있다
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
        // **유일한 시간 조건.** 위 열은 어느 기계에서나 성립하는 모양 불변식이고, 이것만이
        // 느린 러너가 혼자 밟을 수 있는 상한이다.
        .{ .name = "latency over cap", .want = error.MarkerLatencyOverCap, .apply = struct {
            fn f(a: *Artifact) void {
                a.marker_latency_ns = marker_latency_cap_ns + 1;
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
