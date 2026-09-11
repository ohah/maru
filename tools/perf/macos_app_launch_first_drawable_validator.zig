//! Strict validator for the actual-AppKit launch-to-first-drawable baseline.

const std = @import("std");

pub const sample_count = 5;

const Row = struct {
    index: u32,
    pre_fork_ns: u64,
    swift_start_ns: u64,
    submit_ns: u64,
    latency_ns: u64,
    metal_frames_drawn: u32,
    smoke_mode: bool,
};

const Artifact = struct {
    schema: []const u8,
    build_mode: []const u8,
    os_release: []const u8,
    machine_model: []const u8,
    logical_cpu_count: u32,
    executable_sha256: []const u8,
    rows: []const Row,
};

fn validateArtifact(artifact: Artifact) !void {
    if (!std.mem.eql(u8, artifact.schema, "maru.macos-app-launch-first-drawable.v1") or
        !std.mem.eql(u8, artifact.build_mode, "ReleaseFast") or artifact.os_release.len == 0 or
        artifact.machine_model.len == 0 or artifact.logical_cpu_count == 0 or
        !canonicalSha256(artifact.executable_sha256))
        return error.InvalidEnvelope;
    if (artifact.rows.len != sample_count) return error.InvalidSampleCount;
    for (artifact.rows, 0..) |row, index| {
        if (row.index != index or row.pre_fork_ns == 0 or
            row.swift_start_ns != row.pre_fork_ns or row.submit_ns <= row.swift_start_ns or
            row.latency_ns != row.submit_ns - row.swift_start_ns or
            row.metal_frames_drawn != 1 or row.smoke_mode)
            return error.InvalidSample;
    }
}

fn canonicalSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
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
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingArtifactPath;
    if (args.next() != null) return error.TooManyArguments;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    try validateBytes(allocator, bytes);
}

test "launch validator rejects timing identity subtraction frame and smoke drift" {
    var rows = validRows();
    try validateArtifact(validArtifact(&rows));
    var envelope = validArtifact(&rows);
    envelope.machine_model = "";
    try std.testing.expectError(error.InvalidEnvelope, validateArtifact(envelope));
    envelope = validArtifact(&rows);
    envelope.logical_cpu_count = 0;
    try std.testing.expectError(error.InvalidEnvelope, validateArtifact(envelope));
    envelope = validArtifact(&rows);
    envelope.executable_sha256 = "ABC";
    try std.testing.expectError(error.InvalidEnvelope, validateArtifact(envelope));
    rows[0].swift_start_ns += 1;
    try std.testing.expectError(error.InvalidSample, validateArtifact(validArtifact(&rows)));
    rows = validRows();
    rows[0].index = 1;
    try std.testing.expectError(error.InvalidSample, validateArtifact(validArtifact(&rows)));
    rows = validRows();
    rows[0].submit_ns = rows[0].swift_start_ns;
    try std.testing.expectError(error.InvalidSample, validateArtifact(validArtifact(&rows)));
    rows = validRows();
    rows[1].latency_ns += 1;
    try std.testing.expectError(error.InvalidSample, validateArtifact(validArtifact(&rows)));
    rows = validRows();
    rows[2].metal_frames_drawn = 2;
    try std.testing.expectError(error.InvalidSample, validateArtifact(validArtifact(&rows)));
    rows = validRows();
    rows[3].smoke_mode = true;
    try std.testing.expectError(error.InvalidSample, validateArtifact(validArtifact(&rows)));
}

test "launch validator rejects unknown duplicate missing and short JSON" {
    const fixture_without_digest =
        \\{"schema":"maru.macos-app-launch-first-drawable.v1","build_mode":"ReleaseFast","os_release":"25.5.0","machine_model":"Mac16,9","logical_cpu_count":16,"rows":[{"index":0,"pre_fork_ns":10,"swift_start_ns":10,"submit_ns":20,"latency_ns":10,"metal_frames_drawn":1,"smoke_mode":false},{"index":1,"pre_fork_ns":20,"swift_start_ns":20,"submit_ns":30,"latency_ns":10,"metal_frames_drawn":1,"smoke_mode":false},{"index":2,"pre_fork_ns":30,"swift_start_ns":30,"submit_ns":40,"latency_ns":10,"metal_frames_drawn":1,"smoke_mode":false},{"index":3,"pre_fork_ns":40,"swift_start_ns":40,"submit_ns":50,"latency_ns":10,"metal_frames_drawn":1,"smoke_mode":false},{"index":4,"pre_fork_ns":50,"swift_start_ns":50,"submit_ns":60,"latency_ns":10,"metal_frames_drawn":1,"smoke_mode":false}]}
    ;
    const valid = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        fixture_without_digest,
        "\"rows\":",
        "\"executable_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"rows\":",
    );
    defer std.testing.allocator.free(valid);
    try validateBytes(std.testing.allocator, valid);
    const unknown = try std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"build_mode\":", "\"unknown\":0,\"build_mode\":");
    defer std.testing.allocator.free(unknown);
    try std.testing.expectError(error.InvalidJsonSchema, validateBytes(std.testing.allocator, unknown));
    const duplicate = try std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"schema\":", "\"schema\":\"maru.macos-app-launch-first-drawable.v1\",\"schema\":");
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(error.InvalidJsonSchema, validateBytes(std.testing.allocator, duplicate));
    const missing = try std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"smoke_mode\":false", "");
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.InvalidJsonSchema, validateBytes(std.testing.allocator, missing));
    try std.testing.expectError(error.InvalidSampleCount, validateBytes(std.testing.allocator, "{\"schema\":\"maru.macos-app-launch-first-drawable.v1\",\"build_mode\":\"ReleaseFast\",\"os_release\":\"x\",\"machine_model\":\"y\",\"logical_cpu_count\":1,\"executable_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"rows\":[]}"));
}

fn validArtifact(rows: []const Row) Artifact {
    return .{
        .schema = "maru.macos-app-launch-first-drawable.v1",
        .build_mode = "ReleaseFast",
        .os_release = "25.5.0",
        .machine_model = "Mac16,9",
        .logical_cpu_count = 16,
        .executable_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .rows = rows,
    };
}

fn validRows() [sample_count]Row {
    var rows: [sample_count]Row = undefined;
    for (&rows, 0..) |*row, index| row.* = .{
        .index = @intCast(index),
        .pre_fork_ns = 10 + index * 10,
        .swift_start_ns = 10 + index * 10,
        .submit_ns = 20 + index * 10,
        .latency_ns = 10,
        .metal_frames_drawn = 1,
        .smoke_mode = false,
    };
    return rows;
}
