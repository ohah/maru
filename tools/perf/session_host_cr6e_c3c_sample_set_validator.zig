//! CR6e-c3c actual-AppKit 반복 sample-set의 strict validator.
//!
//! 단일 run의 의미는 기존 v2 validator가 소유한다. 이 파일은 같은 환경·바이너리에서 얻은
//! 정확히 20개 run의 순서와 지문만 추가로 결속하며, 아직 성능 hard cap을 만들지 않는다.

const std = @import("std");
pub const c3c = @import("session_host_cr6e_c3c_validator.zig");

pub const sample_count: usize = 20;
pub const sample_set_p95_cap_ns: u64 = 30 * std.time.ns_per_ms;
pub const sample_set_hang_cap_ns: u64 = 100 * std.time.ns_per_ms;
const sample_set_p95_index = (sample_count * 95 + 99) / 100 - 1;

const Row = struct {
    index: u32,
    latency_ns: u64,
    raw: c3c.Artifact,
};

const Artifact = struct {
    schema: []const u8,
    build_mode: []const u8,
    os_release: []const u8,
    machine_model: []const u8,
    logical_cpu_count: u32,
    app_executable_sha256: []const u8,
    product_executable_sha256: []const u8,
    rows: [sample_count]Row,
};

fn canonicalSha256(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn validateArtifact(artifact: Artifact) !void {
    if (!std.mem.eql(u8, artifact.schema, "maru.session-host-cr6e-c3c-sample-set.v1") or
        !std.mem.eql(u8, artifact.build_mode, "ReleaseFast") or
        artifact.os_release.len == 0 or artifact.machine_model.len == 0 or
        artifact.logical_cpu_count == 0 or
        !canonicalSha256(artifact.app_executable_sha256) or
        !canonicalSha256(artifact.product_executable_sha256))
        return error.InvalidEnvelope;
    var latencies: [sample_count]u64 = undefined;
    for (artifact.rows, 0..) |row, index| {
        if (row.index != index) return error.InvalidRowIndex;
        try c3c.validateArtifact(row.raw);
        if (row.latency_ns == 0 or row.latency_ns != row.raw.input_frame.latency_ns)
            return error.InvalidLatencyProjection;
        if (row.latency_ns > sample_set_hang_cap_ns)
            return error.SampleHangBudgetExceeded;
        latencies[index] = row.latency_ns;
    }
    std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));
    if (latencies[sample_set_p95_index] > sample_set_p95_cap_ns)
        return error.SampleSetP95BudgetExceeded;
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
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(bytes);
    try validateBytes(allocator, bytes);
}

test "CR6e-c3c sample-set accepts twenty ordered strict raw rows" {
    var artifact = goodArtifact();
    try validateArtifact(artifact);
    artifact.rows[7].index = 8;
    try std.testing.expectError(error.InvalidRowIndex, validateArtifact(artifact));
}

test "CR6e-c3c sample-set rejects environment fingerprint and raw projection drift" {
    var artifact = goodArtifact();
    artifact.logical_cpu_count = 0;
    try std.testing.expectError(error.InvalidEnvelope, validateArtifact(artifact));
    artifact = goodArtifact();
    artifact.rows[9].latency_ns += 1;
    try std.testing.expectError(error.InvalidLatencyProjection, validateArtifact(artifact));
    artifact = goodArtifact();
    artifact.rows[11].raw.cleanup.clients = 1;
    try std.testing.expectError(error.CleanupIncomplete, validateArtifact(artifact));
}

test "CR6e-c3c sample-set rejects sustained p95 regression and one hung frame" {
    var artifact = goodArtifact();
    setLatency(&artifact.rows[19], sample_set_p95_cap_ns + 1);
    try validateArtifact(artifact);

    artifact = goodArtifact();
    setLatency(&artifact.rows[18], sample_set_p95_cap_ns);
    setLatency(&artifact.rows[19], sample_set_p95_cap_ns);
    try validateArtifact(artifact);

    artifact = goodArtifact();
    setLatency(&artifact.rows[18], sample_set_p95_cap_ns + 1);
    setLatency(&artifact.rows[19], sample_set_p95_cap_ns + 1);
    try std.testing.expectError(error.SampleSetP95BudgetExceeded, validateArtifact(artifact));

    artifact = goodArtifact();
    setLatency(&artifact.rows[19], sample_set_hang_cap_ns);
    try validateArtifact(artifact);

    artifact = goodArtifact();
    setLatency(&artifact.rows[19], sample_set_hang_cap_ns + 1);
    try std.testing.expectError(error.SampleHangBudgetExceeded, validateArtifact(artifact));
}

test "CR6e-c3c sample-set JSON rejects unknown duplicate and missing fields" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.write(goodArtifact());
    const valid = out.written();
    try validateBytes(std.testing.allocator, valid);

    const unknown = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid,
        "\"build_mode\":",
        "\"unknown\":0,\"build_mode\":",
    );
    defer std.testing.allocator.free(unknown);
    try std.testing.expectError(error.InvalidJsonSchema, validateBytes(std.testing.allocator, unknown));

    const duplicate = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid,
        "\"schema\":",
        "\"schema\":\"maru.session-host-cr6e-c3c-sample-set.v1\",\"schema\":",
    );
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(error.InvalidJsonSchema, validateBytes(std.testing.allocator, duplicate));

    const missing = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid,
        "\"logical_cpu_count\":16,",
        "",
    );
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.InvalidJsonSchema, validateBytes(std.testing.allocator, missing));
}

fn goodArtifact() Artifact {
    var rows: [sample_count]Row = undefined;
    for (&rows, 0..) |*row, index| {
        var raw = c3c.validFixture();
        raw.input_frame.dispatch_ns += index;
        raw.input_frame.submit_ns += index;
        row.* = .{ .index = @intCast(index), .latency_ns = raw.input_frame.latency_ns, .raw = raw };
    }
    return .{
        .schema = "maru.session-host-cr6e-c3c-sample-set.v1",
        .build_mode = "ReleaseFast",
        .os_release = "25.5.0",
        .machine_model = "Mac16,9",
        .logical_cpu_count = 16,
        .app_executable_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .product_executable_sha256 = "1111111111111111111111111111111111111111111111111111111111111111",
        .rows = rows,
    };
}

fn setLatency(row: *Row, latency_ns: u64) void {
    row.latency_ns = latency_ns;
    row.raw.input_frame.submit_ns = row.raw.input_frame.dispatch_ns + latency_ns;
    row.raw.input_frame.latency_ns = latency_ns;
}
