//! Session default G1 config provenance source boundary.
//!
//! G1 owns parsing and G2 is the only product consumer of its provenance fields. This gate keeps
//! the parser singular and pins the deliberately opened G2 inventory rather than preserving the
//! obsolete pre-G2 assumption that provenance never leaves the config layer.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

test "Session default G1 provenance boundary keeps one parser and the exact G2 consumer inventory" {
    const allocator = std.testing.allocator;
    const loader = try readSource(allocator, "src/config/loader.zig");
    defer allocator.free(loader);
    const schema = try readSource(allocator, "src/config/schema.zig");
    defer allocator.free(schema);
    const barrel = try readSource(allocator, "src/config.zig");
    defer allocator.free(barrel);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const persistent = try readSource(allocator, "docs/persistent-session-host.md");
    defer allocator.free(persistent);
    const plan = try readSource(allocator, "docs/implementation-plan.md");
    defer allocator.free(plan);
    const verification = try readSource(allocator, "docs/verification-matrix.md");
    defer allocator.free(verification);
    const commands = try readSource(allocator, "docs/development-commands.md");
    defer allocator.free(commands);

    try expectOne(schema, "pub fn parseBool(value: []const u8) ?bool");
    try expectOne(loader, "schema.parseBool(value)");
    try expectOne(loader, "pub const SessionKeepAliveProvenance = union(enum)");
    try expectOne(loader, "pub const FileProvenance = enum");
    try expectOne(barrel, "pub const SessionKeepAliveProvenance = loader.SessionKeepAliveProvenance;");
    try expectOne(barrel, "pub const ConfigFileProvenance = loader.FileProvenance;");
    try expectOne(build, "\"test-session-host-config-provenance\"");
    try std.testing.expect(std.mem.indexOf(u8, persistent, "G1 loader provenance 계약") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "G1 config loader provenance") != null);
    try std.testing.expect(std.mem.indexOf(u8, verification, "Session default G1 config provenance") != null);
    try expectOne(commands, "`zig build test-session-host-config-provenance`");

    // G2 deliberately opens these projections in app_session/settings, plus the read-only v181
    // release baseline classifier. Exact counts include same-file tests; another product reader
    // must update this SSOT boundary rather than silently becoming another policy owner.
    try std.testing.expectEqual(@as(usize, 7), try countOutsideConfig(allocator, "session_keep_alive_provenance"));
    try std.testing.expectEqual(@as(usize, 20), try countOutsideConfig(allocator, "file_provenance"));
}

fn countOutsideConfig(allocator: std.mem.Allocator, needle: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .sym_link) return error.TestUnexpectedResult;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "config.zig") or std.mem.startsWith(u8, entry.path, "config/")) continue;
        const source = try dir.readFileAlloc(std.testing.io, entry.path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}

fn expectOne(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), count(haystack, needle));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        result += 1;
        start = index + needle.len;
    }
    return result;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
}
