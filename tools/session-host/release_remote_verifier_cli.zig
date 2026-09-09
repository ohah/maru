//! Zero-output product entrypoint for one protected-run remote Release verdict.

const std = @import("std");
const environment = @import("release_adapter_environment");
const timing_artifact = @import("release_adapter_live_timing_artifact");
const attestation = @import("release_adapter_github_attestation");
const transport = @import("release_adapter_github_transport");
const cli_authority = @import("release_adapter_github_cli_authority");
const verifier = @import("release_adapter_remote_release_verifier");

pub fn main(init: std.process.Init) void {
    mainFallible(init) catch std.process.exit(1);
}

fn mainFallible(init: std.process.Init) !void {
    var values: [5][]const u8 = undefined;
    var count: usize = 0;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |value| {
        if (count == values.len) return error.TooManyArguments;
        values[count] = value;
        count += 1;
    }
    const command = try verifier.parse(values[0..count]);
    const trusted = try environment.readCurrent();
    const runner = try cli_authority.readCurrentRunner(trusted.source_commit);
    const raw_token = std.c.getenv("GH_TOKEN") orelse return error.MissingToken;
    const token = std.mem.span(raw_token);
    if (token.len == 0 or token.len > verifier.max_token_bytes) return error.InvalidToken;
    var token_storage: [verifier.max_token_bytes]u8 = undefined;
    defer @memset(&token_storage, 0);
    @memcpy(token_storage[0..token.len], token);
    var timing_metadata: [timing_artifact.response_cap]u8 = undefined;
    var release_metadata: [transport.max_response_bytes]u8 = undefined;
    var attestation_output: [attestation.max_response_bytes]u8 = undefined;
    try verifier.verify(init.io, init.gpa, &trusted, runner, command, token_storage[0..token.len], &timing_metadata, &release_metadata, &attestation_output, 20 * std.time.ns_per_min);
}
