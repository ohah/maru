//! Synthetic validator child: validates the bridge environment and emits one closed tuple.

const std = @import("std");
const c = std.c;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const command = args.next() orelse return error.MissingCommand;
    const marker_option = if (std.mem.eql(u8, command, "prepare-candidate"))
        "--durable-preparation"
    else if (std.mem.eql(u8, command, "prepare-candidate-aggregate"))
        "--aggregate"
    else if (std.mem.eql(u8, command, "finalize-candidate-aggregate"))
        "--manifest"
    else if (std.mem.eql(u8, command, "resume-candidate-publication"))
        "--preparation"
    else if (std.mem.eql(u8, command, "cleanup-candidate-aggregate"))
        "--manifest"
    else
        return error.InvalidCommand;
    const network = !std.mem.eql(u8, command, "prepare-candidate-aggregate") and !std.mem.eql(u8, command, "finalize-candidate-aggregate");
    if ((c.getenv("GH_TOKEN") != null) != network) return error.InvalidEnvironment;
    if ((c.getenv("GITHUB_WORKSPACE") != null) != std.mem.eql(u8, command, "prepare-candidate")) return error.InvalidEnvironment;
    inline for (.{ "PATH", "HOME", "GITHUB_OUTPUT", "APPLE_ID", "APPLE_TEAM_ID", "APPLE_APP_SPECIFIC_PASSWORD" }) |name|
        if (c.getenv(name) != null) return error.AmbientEnvironment;

    var marker: ?[]const u8 = null;
    var previous: ?[]const u8 = null;
    while (args.next()) |value| {
        if (previous) |option| {
            if (std.mem.eql(u8, option, marker_option)) marker = value;
        }
        previous = value;
    }
    const path = marker orelse return error.MissingMarker;
    var storage: [64]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&storage, "{d}\n", .{c.getpid()});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = bytes });
    if (std.mem.endsWith(u8, path, "local-failure")) {
        std.debug.print("local_failure\n", .{});
        std.process.exit(20);
    }
    if (std.mem.endsWith(u8, path, "unknown")) {
        std.debug.print("unexpected\n", .{});
        return;
    }
    std.debug.print("success\n", .{});
}
