//! Canonical diagnostic JSON contract for the aggregate process harness.

const std = @import("std");

pub const schema = "maru.session-host-release-aggregate-process-perf.v1";
pub const max_iterations: u64 = 20;
pub const Times = struct { median: u64, p95: u64, max: u64 };
pub const Report = struct {
    schema: []const u8,
    iterations: u64,
    successful_pairs: u64,
    distinct_pid_pairs: u64,
    prepare_ns: Times,
    handoff_gap_ns: Times,
    finalize_ns: Times,
    total_ns: Times,
    failures: u64,
    parent_fd_delta: u64,
    aggregate_residue: u64,
    staging_residue: u64,
};

pub fn render(buffer: []u8, value: Report) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{{\"schema\":\"{s}\",\"iterations\":{d},\"successful_pairs\":{d},\"distinct_pid_pairs\":{d}," ++
        "\"prepare_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}},\"handoff_gap_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}}," ++
        "\"finalize_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}},\"total_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}}," ++
        "\"failures\":{d},\"parent_fd_delta\":{d},\"aggregate_residue\":{d},\"staging_residue\":{d}}}", .{
        value.schema,             value.iterations,         value.successful_pairs,   value.distinct_pid_pairs,
        value.prepare_ns.median,  value.prepare_ns.p95,     value.prepare_ns.max,     value.handoff_gap_ns.median,
        value.handoff_gap_ns.p95, value.handoff_gap_ns.max, value.finalize_ns.median, value.finalize_ns.p95,
        value.finalize_ns.max,    value.total_ns.median,    value.total_ns.p95,       value.total_ns.max,
        value.failures,           value.parent_fd_delta,    value.aggregate_residue,  value.staging_residue,
    });
}

pub fn parseCanonical(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Report) {
    if (bytes.len == 0 or bytes[bytes.len - 1] == '\n' or bytes[bytes.len - 1] == ' ') return error.NonCanonical;
    var parsed = std.json.parseFromSlice(Report, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch return error.InvalidReport;
    errdefer parsed.deinit();
    const value = parsed.value;
    const accounted = std.math.add(u64, value.successful_pairs, value.failures) catch return error.InvalidReport;
    if (!std.mem.eql(u8, value.schema, schema) or value.iterations == 0 or value.iterations > max_iterations or
        accounted != value.iterations or
        value.distinct_pid_pairs > value.successful_pairs or
        value.prepare_ns.median > value.prepare_ns.p95 or value.prepare_ns.p95 > value.prepare_ns.max or
        value.handoff_gap_ns.median > value.handoff_gap_ns.p95 or value.handoff_gap_ns.p95 > value.handoff_gap_ns.max or
        value.finalize_ns.median > value.finalize_ns.p95 or value.finalize_ns.p95 > value.finalize_ns.max or
        value.total_ns.median > value.total_ns.p95 or value.total_ns.p95 > value.total_ns.max) return error.InvalidReport;
    var canonical_storage: [2048]u8 = undefined;
    const canonical = try render(&canonical_storage, value);
    if (!std.mem.eql(u8, canonical, bytes)) return error.NonCanonical;
    return parsed;
}
