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
        if (sample.runtime_count != expected_runtime_count or sample.frame_count != idle_frame_count or
            sample.observation_ns < idle_observation_min_ns or
            sample.observation_ns > idle_observation_max_ns or
            sample.cpu_total_delta_ns != sample.cpu_user_delta_ns + sample.cpu_system_delta_ns or
            sample.cpu_total_delta_ns > idle_client_cpu_cap_ns)
            return error.InvalidScaleRow;
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
    if (artifact.marker_runtime_count != 100 or artifact.marker_target_output_events == 0 or
        artifact.marker_sibling_output_events != 0 or artifact.marker_latency_ns == 0 or
        artifact.marker_frame_count == 0 or
        artifact.marker_max_frame_elapsed_ns == 0 or
        artifact.marker_readable_wake_count + artifact.marker_timer_timeout_count !=
            artifact.marker_frame_count - 1 or
        artifact.marker_pump_delta_count < artifact.marker_selected_owner_count or
        artifact.marker_pump_delta_count > artifact.marker_selected_owner_count + artifact.marker_frame_count or
        artifact.marker_pump_delta_count != artifact.marker_timestamp_seal_count or
        artifact.marker_latency_ns > marker_latency_cap_ns)
        return error.InvalidMarker;
    if (!artifact.host_reaped or !artifact.client_fds_closed or
        !artifact.socket_removed or !artifact.directory_removed)
        return error.CleanupIncomplete;
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
    artifact.marker_latency_ns = marker_latency_cap_ns + 1;
    try std.testing.expectError(error.InvalidMarker, validateArtifact(artifact));
    artifact.marker_latency_ns = std.time.ns_per_ms;
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
    try std.testing.expectError(error.InvalidScaleRow, validateArtifact(artifact));
    drifted_rows[2] = rows[2];
    drifted_rows[2].observation_ns = idle_observation_max_ns + 1;
    try std.testing.expectError(error.InvalidScaleRow, validateArtifact(artifact));
}
