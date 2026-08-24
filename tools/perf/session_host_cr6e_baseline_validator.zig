//! CR6e-a1 raw transport artifact validator. Producer booleans are not trusted as a pass summary.

const std = @import("std");

const schema_name = "maru.session-host-cr6e-baseline-macos.v1";
const deadline_ms: u64 = 250;
const backoff_attempt_limit: u32 = 10;

const RssSample = struct {
    monotonic_ns: u64,
    resident_bytes: u64,
    footprint_bytes: u64,
    cpu_ns: u64,
};

const Scenario = struct {
    name: []const u8,
    start_ns: u64,
    deadline_ns: u64,
    end_ns: u64,
    failure_reason: []const u8,
    attempt_count: u32,
    backoff_wait_count: u32,
    peer_accepted: bool,
    peer_hello_bytes: u32,
    peer_closed: bool,
};

const Artifact = struct {
    schema: []const u8,
    build_mode: []const u8,
    sample_api: []const u8,
    os_release: []const u8,
    machine_model: []const u8,
    logical_cpu_count: u32,
    pid: u32,
    deadline_ms: u64,
    fd_count_before: u32,
    fd_count_after: u32,
    rss_before: RssSample,
    rss_after: RssSample,
    scenarios: [2]Scenario,
    peer_reaped: bool,
    socket_removed: bool,
    manifest_removed: bool,
    host_directory_removed: bool,
};

fn validateArtifact(artifact: Artifact) !void {
    if (!std.mem.eql(u8, artifact.schema, schema_name) or
        !std.mem.eql(u8, artifact.build_mode, "ReleaseFast") or
        !std.mem.eql(u8, artifact.sample_api, "proc_pid_rusage:RUSAGE_INFO_V4") or
        artifact.os_release.len == 0 or artifact.machine_model.len == 0 or
        artifact.logical_cpu_count == 0 or artifact.pid == 0 or artifact.deadline_ms != deadline_ms)
        return error.InvalidIdentity;
    if (artifact.fd_count_before == 0 or artifact.fd_count_after != artifact.fd_count_before)
        return error.FdLeak;
    if (artifact.rss_before.monotonic_ns == 0 or
        artifact.rss_before.monotonic_ns >= artifact.rss_after.monotonic_ns or
        artifact.rss_before.resident_bytes == 0 or artifact.rss_after.resident_bytes == 0 or
        artifact.rss_before.footprint_bytes == 0 or artifact.rss_after.footprint_bytes == 0 or
        artifact.rss_after.cpu_ns < artifact.rss_before.cpu_ns)
        return error.InvalidRssSample;

    const hello = artifact.scenarios[0];
    if (!std.mem.eql(u8, hello.name, "hello_reply_stall") or
        !std.mem.eql(u8, hello.failure_reason, "deadline_exceeded") or
        hello.attempt_count != 1 or hello.backoff_wait_count != 0 or
        !hello.peer_accepted or hello.peer_hello_bytes == 0 or !hello.peer_closed)
        return error.MissingHelloStall;
    try validateTime(hello);
    if (hello.end_ns < hello.deadline_ns) return error.TimeoutBeforeDeadline;

    const backoff = artifact.scenarios[1];
    if (!std.mem.eql(u8, backoff.name, "transient_backoff") or
        backoff.peer_accepted or backoff.peer_hello_bytes != 0 or !backoff.peer_closed)
        return error.InvalidBackoff;
    try validateTime(backoff);
    if (std.mem.eql(u8, backoff.failure_reason, "host_gone")) {
        if (backoff.attempt_count != backoff_attempt_limit or
            backoff.backoff_wait_count != backoff_attempt_limit - 1)
            return error.InvalidBackoff;
        if (backoff.end_ns > backoff.deadline_ns) return error.BackoffExceededDeadline;
    } else if (std.mem.eql(u8, backoff.failure_reason, "deadline_exceeded")) {
        if (backoff.attempt_count == 0 or
            backoff.attempt_count >= backoff_attempt_limit or
            backoff.backoff_wait_count != backoff.attempt_count)
            return error.InvalidBackoff;
        if (backoff.end_ns < backoff.deadline_ns) return error.BackoffBeforeDeadline;
    } else return error.InvalidBackoff;

    if (!artifact.peer_reaped or !artifact.socket_removed or !artifact.manifest_removed or
        !artifact.host_directory_removed)
        return error.CleanupIncomplete;
}

fn validateTime(scenario: Scenario) !void {
    if (scenario.start_ns == 0 or scenario.deadline_ns <= scenario.start_ns or
        scenario.end_ns <= scenario.start_ns)
        return error.TimestampOrder;
    const configured = scenario.deadline_ns - scenario.start_ns;
    if (configured < deadline_ms * std.time.ns_per_ms or
        configured > (deadline_ms + 5) * std.time.ns_per_ms)
        return error.DeadlineDrift;
}

pub fn validateBytes(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parsed = std.json.parseFromSlice(Artifact, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch return error.InvalidJsonSchema;
    defer parsed.deinit();
    try validateArtifact(parsed.value);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingArtifactPath;
    if (args.next() != null) return error.TooManyArguments;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    try validateBytes(allocator, bytes);
}

test "CR6e validator rejects deadline success and cleanup residue" {
    var artifact = validFixture();
    try validateArtifact(artifact);
    artifact.scenarios[0].failure_reason = "connected";
    try std.testing.expectError(error.MissingHelloStall, validateArtifact(artifact));
    artifact = validFixture();
    artifact.socket_removed = false;
    try std.testing.expectError(error.CleanupIncomplete, validateArtifact(artifact));
}

test "CR6e validator accepts backoff that consumes the absolute deadline before the final attempt" {
    var artifact = validFixture();
    artifact.scenarios[1] = .{
        .name = "transient_backoff",
        .start_ns = 1_711_823_035_708,
        .deadline_ns = 1_712_073_036_041,
        .end_ns = 1_712_074_698_625,
        .failure_reason = "deadline_exceeded",
        .attempt_count = 9,
        .backoff_wait_count = 9,
        .peer_accepted = false,
        .peer_hello_bytes = 0,
        .peer_closed = true,
    };
    try validateArtifact(artifact);
}

test "CR6e validator rejects impossible backoff terminal projections" {
    var artifact = validFixture();
    artifact.scenarios[1].attempt_count = backoff_attempt_limit - 1;
    try std.testing.expectError(error.InvalidBackoff, validateArtifact(artifact));

    artifact = validFixture();
    artifact.scenarios[1].failure_reason = "deadline_exceeded";
    artifact.scenarios[1].attempt_count = backoff_attempt_limit - 1;
    artifact.scenarios[1].backoff_wait_count = backoff_attempt_limit - 1;
    artifact.scenarios[1].end_ns = artifact.scenarios[1].deadline_ns - 1;
    try std.testing.expectError(error.BackoffBeforeDeadline, validateArtifact(artifact));

    artifact = validFixture();
    artifact.scenarios[1].failure_reason = "deadline_exceeded";
    artifact.scenarios[1].attempt_count = backoff_attempt_limit - 1;
    artifact.scenarios[1].backoff_wait_count = backoff_attempt_limit - 2;
    artifact.scenarios[1].end_ns = artifact.scenarios[1].deadline_ns;
    try std.testing.expectError(error.InvalidBackoff, validateArtifact(artifact));

    artifact = validFixture();
    artifact.scenarios[1].backoff_wait_count = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidBackoff, validateArtifact(artifact));
}

fn validFixture() Artifact {
    return .{
        .schema = schema_name,
        .build_mode = "ReleaseFast",
        .sample_api = "proc_pid_rusage:RUSAGE_INFO_V4",
        .os_release = "fixture",
        .machine_model = "fixture",
        .logical_cpu_count = 8,
        .pid = 1,
        .deadline_ms = deadline_ms,
        .fd_count_before = 4,
        .fd_count_after = 4,
        .rss_before = .{ .monotonic_ns = 1, .resident_bytes = 1, .footprint_bytes = 1, .cpu_ns = 1 },
        .rss_after = .{ .monotonic_ns = 1_000_000_000, .resident_bytes = 1, .footprint_bytes = 1, .cpu_ns = 2 },
        .scenarios = .{
            .{ .name = "hello_reply_stall", .start_ns = 10, .deadline_ns = 250_000_010, .end_ns = 250_000_011, .failure_reason = "deadline_exceeded", .attempt_count = 1, .backoff_wait_count = 0, .peer_accepted = true, .peer_hello_bytes = 1, .peer_closed = true },
            .{ .name = "transient_backoff", .start_ns = 300_000_000, .deadline_ns = 550_000_000, .end_ns = 480_000_000, .failure_reason = "host_gone", .attempt_count = 10, .backoff_wait_count = 9, .peer_accepted = false, .peer_hello_bytes = 0, .peer_closed = true },
        },
        .peer_reaped = true,
        .socket_removed = true,
        .manifest_removed = true,
        .host_directory_removed = true,
    };
}
