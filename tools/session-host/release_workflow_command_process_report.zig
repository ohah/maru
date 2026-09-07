//! Canonical diagnostic schema for live validator command actual-process measurements.

const std = @import("std");

pub const schema = "maru.session-host-release-workflow-command-process-perf.v1";
pub const max_iterations: u64 = 20;
pub const Times = struct { median: u64, p95: u64, max: u64 };
pub const Report = struct {
    schema: []const u8,
    iterations: u64,
    successful_runs: u64,
    draft_authoring_ns: Times,
    aggregate_prepare_ns: Times,
    aggregate_finalize_ns: Times,
    publication_ns: Times,
    aggregate_cleanup_ns: Times,
    failures: u64,
    child_pid_collisions: u64,
    parent_fd_delta: u64,
    checkpoint_residue: u64,
};

pub fn render(buffer: []u8, value: Report) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{{\"schema\":\"{s}\",\"iterations\":{d},\"successful_runs\":{d}," ++
        "\"draft_authoring_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}}," ++
        "\"aggregate_prepare_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}}," ++
        "\"aggregate_finalize_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}}," ++
        "\"publication_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}}," ++
        "\"aggregate_cleanup_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}}," ++
        "\"failures\":{d},\"child_pid_collisions\":{d},\"parent_fd_delta\":{d},\"checkpoint_residue\":{d}}}", .{
        value.schema,
        value.iterations,
        value.successful_runs,
        value.draft_authoring_ns.median,
        value.draft_authoring_ns.p95,
        value.draft_authoring_ns.max,
        value.aggregate_prepare_ns.median,
        value.aggregate_prepare_ns.p95,
        value.aggregate_prepare_ns.max,
        value.aggregate_finalize_ns.median,
        value.aggregate_finalize_ns.p95,
        value.aggregate_finalize_ns.max,
        value.publication_ns.median,
        value.publication_ns.p95,
        value.publication_ns.max,
        value.aggregate_cleanup_ns.median,
        value.aggregate_cleanup_ns.p95,
        value.aggregate_cleanup_ns.max,
        value.failures,
        value.child_pid_collisions,
        value.parent_fd_delta,
        value.checkpoint_residue,
    });
}

pub fn parseCanonical(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Report) {
    if (bytes.len == 0 or bytes[bytes.len - 1] == '\n' or bytes[bytes.len - 1] == ' ') return error.NonCanonical;
    var parsed = std.json.parseFromSlice(Report, allocator, bytes, .{ .duplicate_field_behavior = .@"error", .ignore_unknown_fields = false }) catch return error.InvalidReport;
    errdefer parsed.deinit();
    const value = parsed.value;
    const accounted = std.math.add(u64, value.successful_runs, value.failures) catch return error.InvalidReport;
    if (!std.mem.eql(u8, value.schema, schema) or value.iterations == 0 or value.iterations > max_iterations or
        accounted != value.iterations or !validTimes(value.draft_authoring_ns) or !validTimes(value.aggregate_prepare_ns) or
        !validTimes(value.aggregate_finalize_ns) or !validTimes(value.publication_ns) or !validTimes(value.aggregate_cleanup_ns))
        return error.InvalidReport;
    var storage: [4096]u8 = undefined;
    if (!std.mem.eql(u8, try render(&storage, value), bytes)) return error.NonCanonical;
    return parsed;
}

fn validTimes(value: Times) bool {
    return value.median > 0 and value.median <= value.p95 and value.p95 <= value.max;
}
