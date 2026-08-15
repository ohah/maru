//! CR2e-e3a2 reconnect RSS artifact의 closed typed validator.

const std = @import("std");

const expected_schema = "maru.session-host-reconnect-rss-macos.v2";
const expected_mode = "ReleaseFast";
const expected_api = "proc_pid_rusage:RUSAGE_INFO_V4";
const expected_samples: u32 = 7;
const expected_owners: u64 = 64;
const expected_slack: u64 = 64 * 1024 * 1024;
const expected_entry_bytes: u64 = 16 * 1024 * 1024 + 256 * 1024;
const expected_tracked_bytes: u64 = expected_entry_bytes * expected_owners;

const RssSample = struct {
    resident: u64,
    footprint: u64,
    start_abstime: u64,
};

const Artifact = struct {
    schema: []const u8,
    build_mode: []const u8,
    sample_api: []const u8,
    run_nonce: [16]u8,
    executable_path: []const u8,
    inherited_fd_closed: bool,
    child_pid: u32,
    child_start_abstime: u64,
    sample_count: u32,
    owner_count: u64,
    max_entry_bytes: u64,
    max_tracked_bytes: u64,
    baseline_samples: [expected_samples]RssSample,
    pressure_samples: [expected_samples]RssSample,
    baseline_generation_count: u64,
    pressure_generation_count: u64,
    baseline_logical_bytes: u64,
    pressure_logical_bytes: u64,
    logical_delta_bytes: u64,
    baseline_rss_bytes: u64,
    pressure_rss_bytes: u64,
    rss_delta_bytes: u64,
    baseline_footprint_bytes: u64,
    pressure_footprint_bytes: u64,
    footprint_delta_bytes: u64,
    measurement_tolerance_bytes: u64,
    allowed_delta_bytes: u64,
    final_generation_count: u64,
    final_logical_bytes: u64,
    final_live_allocations: u64,
    child_exit_code: u8,
};

fn sampleMedian(samples: [expected_samples]RssSample, start_abstime: u64) !RssSample {
    var resident: [expected_samples]u64 = undefined;
    var footprint: [expected_samples]u64 = undefined;
    for (samples, 0..) |sample, index| {
        if (sample.resident == 0 or sample.footprint == 0 or sample.start_abstime != start_abstime)
            return error.InvalidSample;
        resident[index] = sample.resident;
        footprint[index] = sample.footprint;
    }
    std.mem.sort(u64, &resident, {}, std.sort.asc(u64));
    std.mem.sort(u64, &footprint, {}, std.sort.asc(u64));
    return .{
        .resident = resident[expected_samples / 2],
        .footprint = footprint[expected_samples / 2],
        .start_abstime = start_abstime,
    };
}

fn validateArtifact(value: Artifact) !void {
    if (!std.mem.eql(u8, value.schema, expected_schema) or
        !std.mem.eql(u8, value.build_mode, expected_mode) or
        !std.mem.eql(u8, value.sample_api, expected_api)) return error.InvalidIdentity;
    if (value.child_pid == 0 or value.child_start_abstime == 0 or
        std.mem.allEqual(u8, &value.run_nonce, 0) or value.executable_path.len == 0 or
        value.executable_path[0] != '/' or !value.inherited_fd_closed or
        value.sample_count != expected_samples or
        value.owner_count != expected_owners or value.max_entry_bytes != expected_entry_bytes or
        value.max_tracked_bytes != expected_tracked_bytes)
        return error.InvalidIdentity;
    if (value.baseline_generation_count != expected_owners or
        value.pressure_generation_count != expected_owners * 2 or
        value.pressure_logical_bytes <= value.baseline_logical_bytes)
        return error.InvalidLogicalState;
    const baseline = try sampleMedian(value.baseline_samples, value.child_start_abstime);
    const pressure = try sampleMedian(value.pressure_samples, value.child_start_abstime);
    if (value.baseline_rss_bytes != baseline.resident or
        value.baseline_footprint_bytes != baseline.footprint or
        value.pressure_rss_bytes != pressure.resident or
        value.pressure_footprint_bytes != pressure.footprint)
        return error.InvalidDerivedValue;
    const logical_delta = value.pressure_logical_bytes - value.baseline_logical_bytes;
    if (value.baseline_logical_bytes > expected_tracked_bytes or
        value.pressure_logical_bytes > expected_tracked_bytes or
        logical_delta > expected_tracked_bytes) return error.LogicalBoundExceeded;
    const rss_delta = value.pressure_rss_bytes -| value.baseline_rss_bytes;
    const footprint_delta = value.pressure_footprint_bytes -| value.baseline_footprint_bytes;
    const allowed = try std.math.add(u64, logical_delta, expected_slack);
    if (value.logical_delta_bytes != logical_delta or value.rss_delta_bytes != rss_delta or
        value.footprint_delta_bytes != footprint_delta or
        value.measurement_tolerance_bytes != expected_slack or value.allowed_delta_bytes != allowed)
        return error.InvalidDerivedValue;
    if (rss_delta > allowed or footprint_delta > allowed) return error.RssCapExceeded;
    if (value.final_generation_count != 0 or value.final_logical_bytes != 0 or
        value.final_live_allocations != 0 or
        value.child_exit_code != 0) return error.CleanupIncomplete;
}

fn validateBytes(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parsed = std.json.parseFromSlice(Artifact, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch return error.InvalidJsonSchema;
    defer parsed.deinit();
    try validateArtifact(parsed.value);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingArtifactPath;
    if (args.next() != null) return error.TooManyArguments;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(bytes);
    try validateBytes(allocator, bytes);
}

test "CR2e-e3a2 RSS validator는 derived delta와 final zero를 독립 재계산한다" {
    try validateArtifact(.{
        .schema = expected_schema,
        .build_mode = expected_mode,
        .sample_api = expected_api,
        .run_nonce = [_]u8{1} ** 16,
        .executable_path = "/tmp/maru-rss-test",
        .inherited_fd_closed = true,
        .child_pid = 7,
        .child_start_abstime = 9,
        .sample_count = expected_samples,
        .owner_count = expected_owners,
        .max_entry_bytes = expected_entry_bytes,
        .max_tracked_bytes = expected_tracked_bytes,
        .baseline_samples = [_]RssSample{.{ .resident = 100, .footprint = 90, .start_abstime = 9 }} ** expected_samples,
        .pressure_samples = [_]RssSample{.{ .resident = 110, .footprint = 105, .start_abstime = 9 }} ** expected_samples,
        .baseline_generation_count = expected_owners,
        .pressure_generation_count = expected_owners * 2,
        .baseline_logical_bytes = 10,
        .pressure_logical_bytes = 30,
        .logical_delta_bytes = 20,
        .baseline_rss_bytes = 100,
        .pressure_rss_bytes = 110,
        .rss_delta_bytes = 10,
        .baseline_footprint_bytes = 90,
        .pressure_footprint_bytes = 105,
        .footprint_delta_bytes = 15,
        .measurement_tolerance_bytes = expected_slack,
        .allowed_delta_bytes = expected_slack + 20,
        .final_generation_count = 0,
        .final_logical_bytes = 0,
        .final_live_allocations = 0,
        .child_exit_code = 0,
    });
}

test "CR2e-e3a2 RSS validator는 unknown missing duplicate와 forged delta를 거부한다" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidJsonSchema, validateBytes(allocator, "{}"));
    try std.testing.expectError(
        error.InvalidJsonSchema,
        validateBytes(allocator, "{\"unknown\":1}"),
    );
    try std.testing.expectError(
        error.InvalidJsonSchema,
        validateBytes(allocator, "{\"schema\":\"a\",\"schema\":\"b\"}"),
    );
    var forged = Artifact{
        .schema = expected_schema,
        .build_mode = expected_mode,
        .sample_api = expected_api,
        .run_nonce = [_]u8{1} ** 16,
        .executable_path = "/tmp/maru-rss-test",
        .inherited_fd_closed = true,
        .child_pid = 7,
        .child_start_abstime = 9,
        .sample_count = expected_samples,
        .owner_count = expected_owners,
        .max_entry_bytes = expected_entry_bytes,
        .max_tracked_bytes = expected_tracked_bytes,
        .baseline_samples = [_]RssSample{.{ .resident = 100, .footprint = 90, .start_abstime = 9 }} ** expected_samples,
        .pressure_samples = [_]RssSample{.{ .resident = 110, .footprint = 105, .start_abstime = 9 }} ** expected_samples,
        .baseline_generation_count = expected_owners,
        .pressure_generation_count = expected_owners * 2,
        .baseline_logical_bytes = 10,
        .pressure_logical_bytes = 30,
        .logical_delta_bytes = 21,
        .baseline_rss_bytes = 100,
        .pressure_rss_bytes = 110,
        .rss_delta_bytes = 10,
        .baseline_footprint_bytes = 90,
        .pressure_footprint_bytes = 105,
        .footprint_delta_bytes = 15,
        .measurement_tolerance_bytes = expected_slack,
        .allowed_delta_bytes = expected_slack + 20,
        .final_generation_count = 0,
        .final_logical_bytes = 0,
        .final_live_allocations = 0,
        .child_exit_code = 0,
    };
    try std.testing.expectError(error.InvalidDerivedValue, validateArtifact(forged));
    forged.logical_delta_bytes = 20;
    forged.baseline_rss_bytes = 99;
    try std.testing.expectError(error.InvalidDerivedValue, validateArtifact(forged));
    forged.baseline_rss_bytes = 100;
    forged.final_logical_bytes = 1;
    try std.testing.expectError(error.CleanupIncomplete, validateArtifact(forged));
    forged.final_logical_bytes = 0;
    forged.pressure_logical_bytes = expected_tracked_bytes + 1;
    forged.logical_delta_bytes = forged.pressure_logical_bytes - forged.baseline_logical_bytes;
    try std.testing.expectError(error.LogicalBoundExceeded, validateArtifact(forged));
    forged.pressure_logical_bytes = 30;
    forged.logical_delta_bytes = 20;
    forged.inherited_fd_closed = false;
    try std.testing.expectError(error.InvalidIdentity, validateArtifact(forged));
    forged.inherited_fd_closed = true;
    forged.run_nonce = [_]u8{0} ** 16;
    try std.testing.expectError(error.InvalidIdentity, validateArtifact(forged));
}
