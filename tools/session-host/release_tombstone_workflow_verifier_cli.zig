//! Protected-run verifier for one self-hosted durable-tombstone artifact.

const std = @import("std");
const environment = @import("release_adapter_environment");
const cli_authority = @import("release_adapter_github_cli_authority");
const verifier = @import("release_adapter_tombstone_workflow_verifier");

pub fn main(init: std.process.Init) void {
    mainFallible(init) catch std.process.exit(1);
}
fn mainFallible(init: std.process.Init) !void {
    var values: [6][]const u8 = undefined;
    var count: usize = 0;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |value| {
        if (count == values.len) return error.TooManyArguments;
        values[count] = value;
        count += 1;
    }
    if (count != values.len or !std.mem.eql(u8, values[0], "verify")) return error.InvalidArguments;
    const trusted = try environment.readCurrent();
    _ = try cli_authority.readCurrentRunner(trusted.source_commit);
    const raw_token = std.c.getenv("GH_TOKEN") orelse return error.MissingToken;
    const token = std.mem.span(raw_token);
    if (token.len == 0 or token.len > 16 * 1024) return error.InvalidToken;
    var token_copy: [16 * 1024]u8 = undefined;
    defer @memset(&token_copy, 0);
    @memcpy(token_copy[0..token.len], token);
    var paths: [4][std.fs.max_path_bytes:0]u8 = undefined;
    try verifier.verify(init.io, init.gpa, trusted, .{
        .cli_path = try std.fmt.bufPrintZ(&paths[0], "{s}", .{values[1]}),
        .cli_sha256 = values[2],
        .evidence_path = try std.fmt.bufPrintZ(&paths[1], "{s}", .{values[3]}),
        .bundle_path = try std.fmt.bufPrintZ(&paths[2], "{s}", .{values[4]}),
        .output_path = try std.fmt.bufPrintZ(&paths[3], "{s}", .{values[5]}),
    }, token_copy[0..token.len], 5 * std.time.ns_per_min);
}
