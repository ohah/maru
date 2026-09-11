//! 20개의 actual-AppKit CR6e-c3c v2 결과를 한 환경 지문 아래 묶는 collector.
//!
//! 제품 실행은 build graph가 순차화한다. collector는 각 raw artifact를 기존 validator로 다시
//! 판정한 뒤에만 aggregate를 쓰며, executable이 수집 중 바뀌면 결과를 발행하지 않는다.

const std = @import("std");
const sample_set = @import("sample_set_validator");
const c3c = sample_set.c3c;
const measurement_fingerprint = @import("measurement_fingerprint");

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
    rows: [sample_set.sample_count]Row,
};

const CapturedFingerprint = struct {
    schema: []const u8,
    os_release: []const u8,
    machine_model: []const u8,
    logical_cpu_count: u32,
    app_executable_sha256: []const u8,
    product_executable_sha256: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const output_path = args.next() orelse return error.MissingOutputPath;
    const fingerprint_path = args.next() orelse return error.MissingFingerprintPath;
    const app_path_raw = args.next() orelse return error.MissingAppExecutable;
    const product_path_raw = args.next() orelse return error.MissingProductExecutable;
    const app_path = try allocator.dupeZ(u8, app_path_raw);
    defer allocator.free(app_path);
    const product_path = try allocator.dupeZ(u8, product_path_raw);
    defer allocator.free(product_path);
    if (!std.fs.path.isAbsolute(app_path) or !std.fs.path.isAbsolute(product_path))
        return error.InvalidExecutablePath;

    const fingerprint_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        fingerprint_path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(fingerprint_bytes);
    var parsed_fingerprint = std.json.parseFromSlice(CapturedFingerprint, allocator, fingerprint_bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch return error.InvalidFingerprint;
    defer parsed_fingerprint.deinit();
    const fingerprint = parsed_fingerprint.value;
    if (!std.mem.eql(u8, fingerprint.schema, "maru.session-host-cr6e-c3c-sample-set-fingerprint.v1"))
        return error.InvalidFingerprint;

    var parsed_rows: [sample_set.sample_count]?std.json.Parsed(c3c.Artifact) =
        @splat(null);
    defer for (&parsed_rows) |*entry| if (entry.*) |*parsed| parsed.deinit();
    var rows: [sample_set.sample_count]Row = undefined;
    for (0..sample_set.sample_count) |index| {
        const path = args.next() orelse return error.MissingRawArtifact;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(bytes);
        try c3c.validateBytes(allocator, bytes);
        parsed_rows[index] = std.json.parseFromSlice(c3c.Artifact, allocator, bytes, .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
        }) catch return error.InvalidRawArtifact;
        const raw = parsed_rows[index].?.value;
        rows[index] = .{
            .index = @intCast(index),
            .latency_ns = raw.input_frame.latency_ns,
            .raw = raw,
        };
    }
    if (args.next() != null) return error.TooManyArguments;

    const app_hex_after = std.fmt.bytesToHex(try measurement_fingerprint.sha256File(app_path.ptr), .lower);
    const product_hex_after = std.fmt.bytesToHex(try measurement_fingerprint.sha256File(product_path.ptr), .lower);
    if (!std.mem.eql(u8, fingerprint.app_executable_sha256, &app_hex_after) or
        !std.mem.eql(u8, fingerprint.product_executable_sha256, &product_hex_after))
        return error.ExecutableChanged;
    var environment_after = try measurement_fingerprint.Environment.capture(allocator);
    defer environment_after.deinit(allocator);
    if (!std.mem.eql(u8, fingerprint.os_release, environment_after.os_release) or
        !std.mem.eql(u8, fingerprint.machine_model, environment_after.machine_model) or
        fingerprint.logical_cpu_count != environment_after.logical_cpu_count)
        return error.EnvironmentChanged;

    const artifact: Artifact = .{
        .schema = "maru.session-host-cr6e-c3c-sample-set.v1",
        .build_mode = "ReleaseFast",
        .os_release = fingerprint.os_release,
        .machine_model = fingerprint.machine_model,
        .logical_cpu_count = fingerprint.logical_cpu_count,
        .app_executable_sha256 = fingerprint.app_executable_sha256,
        .product_executable_sha256 = fingerprint.product_executable_sha256,
        .rows = rows,
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try json.write(artifact);
    try out.writer.writeByte('\n');
    try sample_set.validateBytes(allocator, out.written());
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = out.written() });
}
