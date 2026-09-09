//! Publishes one frozen remote pass record through the shared no-follow Release file boundary.

const std = @import("std");
const record = @import("release_adapter_remote_release_pass_record");
const files = @import("release_adapter_files");

pub const final_name = "session-host-release-remote-pass.json";

pub fn publish(
    allocator: std.mem.Allocator,
    frozen: *const record.Frozen,
    path: [:0]const u8,
    result: *files.PinnedReleaseFile,
) !void {
    const output = std.mem.asBytes(result);
    if (!exactFinalPath(path) or overlaps(std.mem.asBytes(frozen), output) or overlaps(path, output) or
        (frozen.bytes != null and overlaps(frozen.bytes.?, output))) return error.InvalidPath;
    const bytes = frozen.value() orelse return error.InvalidRecord;
    // Finish every allocating validation before rename. A later OOM must never turn a durable
    // final leaf into the residue of a failed command.
    var parsed = try record.parseCanonical(allocator, bytes);
    parsed.deinit();
    if (frozen.value() == null) return error.InvalidRecord;
    try files.publishSummaryOwnedExclusiveMode(result, path, bytes, 0o400);
    const observed = result.value() orelse unreachable;
    std.debug.assert(observed.mode & 0o777 == 0o400);
    std.debug.assert(observed.size == bytes.len);
    std.debug.assert(std.crypto.timing_safe.eql([64]u8, observed.sha256, frozen.sha256));
}

fn exactFinalPath(path: []const u8) bool {
    if (path.len <= final_name.len + 1 or path[0] != '/') return false;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return false;
    if (!std.mem.eql(u8, path[slash + 1 ..], final_name)) return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return @intFromPtr(a.ptr) < @intFromPtr(b.ptr) + b.len and @intFromPtr(b.ptr) < @intFromPtr(a.ptr) + a.len;
}
