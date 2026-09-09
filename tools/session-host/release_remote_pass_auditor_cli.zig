//! Zero-output entrypoint for one same-run remote pass artifact audit.

const std = @import("std");
const environment = @import("release_adapter_environment");
const artifact = @import("release_adapter_remote_release_pass_artifact");
const cli_authority = @import("release_adapter_github_cli_authority");
const auditor = @import("release_adapter_remote_release_pass_auditor");

pub fn main(init: std.process.Init) void {
    mainFallible(init) catch std.process.exit(1);
}

fn mainFallible(init: std.process.Init) !void {
    var values: [4][]const u8 = undefined;
    var count: usize = 0;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |value| {
        if (count == values.len) return error.TooManyArguments;
        values[count] = value;
        count += 1;
    }
    const command = try auditor.parse(values[0..count]);
    const trusted = try environment.readCurrent();
    const runner = try cli_authority.readCurrentRunner(trusted.source_commit);
    const raw_token = std.c.getenv("GH_TOKEN") orelse return error.MissingToken;
    const token = std.mem.span(raw_token);
    if (token.len == 0 or token.len > auditor.max_token_bytes) return error.InvalidToken;
    var token_storage: [auditor.max_token_bytes]u8 = undefined;
    defer @memset(&token_storage, 0);
    @memcpy(token_storage[0..token.len], token);
    var metadata_buffer: [artifact.response_cap]u8 = undefined;
    try auditor.audit(init.io, init.gpa, trusted, runner, command, token_storage[0..token.len], &metadata_buffer, 5 * std.time.ns_per_min);
}
