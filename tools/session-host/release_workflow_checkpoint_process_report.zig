//! Canonical diagnostics for the actual-process workflow checkpoint harness.

const std = @import("std");

pub const schema = "maru.session-host-release-workflow-checkpoint-process-perf.v1";
pub const max_iterations: u64 = 20;
pub const Times = struct { median: u64, p95: u64, max: u64 };
pub const Report = struct {
    schema: []const u8,
    iterations: u64,
    successful_runs: u64,
    distinct_pid_runs: u64,
    init_ns: Times,
    stages_ns: Times,
    total_ns: Times,
    failures: u64,
    parent_fd_delta: u64,
    leaf_residue: u64,
    root_residue: u64,
};

pub fn render(buffer: []u8, value: Report) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{{\"schema\":\"{s}\",\"iterations\":{d},\"successful_runs\":{d},\"distinct_pid_runs\":{d}," ++
        "\"init_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}},\"stages_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}}," ++
        "\"total_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}},\"failures\":{d},\"parent_fd_delta\":{d}," ++
        "\"leaf_residue\":{d},\"root_residue\":{d}}}", .{
        value.schema,         value.iterations,    value.successful_runs, value.distinct_pid_runs,
        value.init_ns.median, value.init_ns.p95,   value.init_ns.max,     value.stages_ns.median,
        value.stages_ns.p95,  value.stages_ns.max, value.total_ns.median, value.total_ns.p95,
        value.total_ns.max,   value.failures,      value.parent_fd_delta, value.leaf_residue,
        value.root_residue,
    });
}

pub fn parseCanonical(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Report) {
    if (bytes.len == 0 or bytes[bytes.len - 1] == '\n' or bytes[bytes.len - 1] == ' ') return error.NonCanonical;
    var parsed = std.json.parseFromSlice(Report, allocator, bytes, .{ .duplicate_field_behavior = .@"error", .ignore_unknown_fields = false }) catch return error.InvalidReport;
    errdefer parsed.deinit();
    const value = parsed.value;
    const accounted = std.math.add(u64, value.successful_runs, value.failures) catch return error.InvalidReport;
    if (!std.mem.eql(u8, value.schema, schema) or value.iterations == 0 or value.iterations > max_iterations or
        accounted != value.iterations or value.distinct_pid_runs > value.successful_runs or
        !measured(value.init_ns) or !measured(value.stages_ns) or !measured(value.total_ns) or
        !dominates(value.total_ns, value.init_ns) or !dominates(value.total_ns, value.stages_ns)) return error.InvalidReport;
    var storage: [2048]u8 = undefined;
    if (!std.mem.eql(u8, try render(&storage, value), bytes)) return error.NonCanonical;
    return parsed;
}

fn measured(value: Times) bool {
    return value.median != 0 and value.median <= value.p95 and value.p95 <= value.max;
}

fn dominates(total: Times, part: Times) bool {
    return total.median >= part.median and total.p95 >= part.p95 and total.max >= part.max;
}
