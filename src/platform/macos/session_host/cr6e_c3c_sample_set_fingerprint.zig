//! CR6e-c3c sample-set 실행 전에 환경과 두 executable을 봉인한다.

const std = @import("std");
const measurement_fingerprint = @import("measurement_fingerprint");

const Artifact = struct {
    schema: []const u8 = "maru.session-host-cr6e-c3c-sample-set-fingerprint.v1",
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
    const app_path = try allocator.dupeZ(u8, args.next() orelse return error.MissingAppExecutable);
    defer allocator.free(app_path);
    const product_path = try allocator.dupeZ(u8, args.next() orelse return error.MissingProductExecutable);
    defer allocator.free(product_path);
    if (args.next() != null) return error.TooManyArguments;
    if (!std.fs.path.isAbsolute(app_path) or !std.fs.path.isAbsolute(product_path))
        return error.InvalidExecutablePath;
    var environment = try measurement_fingerprint.Environment.capture(allocator);
    defer environment.deinit(allocator);
    const app_hex = std.fmt.bytesToHex(try measurement_fingerprint.sha256File(app_path.ptr), .lower);
    const product_hex = std.fmt.bytesToHex(try measurement_fingerprint.sha256File(product_path.ptr), .lower);
    const artifact: Artifact = .{
        .os_release = environment.os_release,
        .machine_model = environment.machine_model,
        .logical_cpu_count = environment.logical_cpu_count,
        .app_executable_sha256 = &app_hex,
        .product_executable_sha256 = &product_hex,
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try json.write(artifact);
    try out.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = out.written() });
}
