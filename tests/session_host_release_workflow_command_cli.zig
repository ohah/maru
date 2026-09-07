//! Product argv and ownership boundary for the fresh-process validator command bridge.

const std = @import("std");
const cli = @import("release_workflow_command_cli");

test "wrapper argv leaves stage selection inside validator argv" {
    const parsed = try cli.parse(&.{ "run", "/private/tmp/checkpoint", root_token, "prepare-candidate", "--repo", "ohah/maru" });
    try std.testing.expectEqualStrings("/private/tmp/checkpoint", parsed.root_path);
    try std.testing.expectEqualStrings("prepare-candidate", parsed.validator_args[0]);
    try std.testing.expectEqual(@as(usize, 3), parsed.validator_args.len);
    try std.testing.expectError(error.InvalidCommand, cli.parse(&.{ "exec", "/private/tmp/checkpoint", root_token, "prepare-candidate" }));
    try std.testing.expectError(error.InvalidArguments, cli.parse(&.{ "run", "/private/tmp/checkpoint", root_token }));
    try std.testing.expectError(error.InvalidPath, cli.parse(&.{ "run", "/private/tmp/../checkpoint", root_token, "prepare-candidate" }));
}

test "wrapper accepts the validator contract bound and rejects one more" {
    var values: [cli.max_arguments + 1][]const u8 = @splat("x");
    values[0] = "run";
    values[1] = "/private/tmp/checkpoint";
    values[2] = root_token;
    _ = try cli.parse(values[0..cli.max_arguments]);
    try std.testing.expectError(error.TooManyArguments, cli.parse(&values));
}

test "product source has one current environment reader and one owner call" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tools/session-host/release_workflow_command_cli.zig", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "environment.readCurrent()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "owner.commandProcess("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "GITHUB_OUTPUT"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "@import(\"release_adapter_live_workflow_checkpoint\")"));

    const process_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_live_workflow_command_process.zig", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(process_source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, process_source, "token_environment.readCurrent()"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, process_source, "appendCurrentEnvironment"));
    try std.testing.expect(std.mem.indexOf(u8, process_source, "copyEnvironment(result, selection, view.context, view.runner") != null);
}

const root_token = "maru-root-v1-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
