//! Canonical diagnostic schema for signed candidate input actual-process measurements.

const std = @import("std");

pub const schema = "maru.session-host-release-workflow-candidate-inputs-process-perf.v1";
pub const max_iterations: u64 = 20;
pub const Times = struct { median: u64, p95: u64, max: u64 };
pub const Report = struct {
    schema: []const u8,
    iterations: u64,
    successful_runs: u64,
    dmg_bytes: u64,
    executable_bytes: u64,
    stage_ns: Times,
    failures: u64,
    parent_fd_delta: u64,
    checkpoint_residue: u64,
    candidate_residue: u64,
};

pub fn render(buffer: []u8, value: Report) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{{\"schema\":\"{s}\",\"iterations\":{d},\"successful_runs\":{d},\"dmg_bytes\":{d},\"executable_bytes\":{d}," ++
        "\"stage_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}},\"failures\":{d},\"parent_fd_delta\":{d}," ++
        "\"checkpoint_residue\":{d},\"candidate_residue\":{d}}}", .{
        value.schema,             value.iterations,        value.successful_runs, value.dmg_bytes, value.executable_bytes,
        value.stage_ns.median,    value.stage_ns.p95,      value.stage_ns.max,    value.failures,  value.parent_fd_delta,
        value.checkpoint_residue, value.candidate_residue,
    });
}

pub fn parseCanonical(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Report) {
    if (bytes.len == 0 or bytes[bytes.len - 1] == '\n' or bytes[bytes.len - 1] == ' ') return error.NonCanonical;
    var parsed = std.json.parseFromSlice(Report, allocator, bytes, .{ .duplicate_field_behavior = .@"error", .ignore_unknown_fields = false }) catch return error.InvalidReport;
    errdefer parsed.deinit();
    const value = parsed.value;
    const accounted = std.math.add(u64, value.successful_runs, value.failures) catch return error.InvalidReport;
    if (!std.mem.eql(u8, value.schema, schema) or value.iterations == 0 or value.iterations > max_iterations or
        accounted != value.iterations or value.dmg_bytes == 0 or value.executable_bytes == 0 or
        value.stage_ns.median == 0 or value.stage_ns.median > value.stage_ns.p95 or value.stage_ns.p95 > value.stage_ns.max)
        return error.InvalidReport;
    var storage: [2048]u8 = undefined;
    if (!std.mem.eql(u8, try render(&storage, value), bytes)) return error.NonCanonical;
    return parsed;
}
