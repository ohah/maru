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
    var values: [3 + 41 + 1][]const u8 = @splat("x");
    values[0] = "run";
    values[1] = "/private/tmp/checkpoint";
    values[2] = root_token;
    _ = try cli.parse(values[0 .. values.len - 1]);
    try std.testing.expectError(error.TooManyArguments, cli.parse(&values));
}

test "profiled stage3 argv validates the superset and projects exact closed commands" {
    var args = profiledArgs();
    var parsed = try cli.parseProfiled(&args);
    const baseline = parsed.validatorArgs(.baseline_a);
    const upgrade = parsed.validatorArgs(.upgrade_b);
    try std.testing.expectEqual(@as(usize, 41), baseline.len);
    try std.testing.expectEqual(@as(usize, 41), upgrade.len);
    try std.testing.expectEqualStrings("prepare-candidate", baseline[0]);
    try std.testing.expectEqualStrings("prepare-profile-candidate", upgrade[0]);
    try std.testing.expectEqual(@as(usize, 0), countArg(baseline, "--predecessor-workspace"));
    try std.testing.expectEqual(@as(usize, 0), countArg(upgrade, "--baseline-workspace"));

    const last_option = args[args.len - 2];
    const last_value = args[args.len - 1];
    args[args.len - 2] = args[3];
    args[args.len - 1] = args[4];
    args[3] = last_option;
    args[4] = last_value;
    parsed = try cli.parseProfiled(&args);
    try std.testing.expectEqualStrings("ohah/maru", parsed.validatorArgs(.baseline_a)[2]);
}

test "profiled stage3 argv rejects missing duplicate unknown and cross-profile aliases" {
    const args = profiledArgs();
    try std.testing.expectError(error.InvalidArguments, cli.parseProfiled(args[0 .. args.len - 2]));
    var duplicate = args;
    duplicate[duplicate.len - 2] = "--repo";
    try std.testing.expectError(error.InvalidArguments, cli.parseProfiled(&duplicate));
    var unknown = args;
    unknown[3] = "--profile";
    try std.testing.expectError(error.InvalidArguments, cli.parseProfiled(&unknown));
    var alias = args;
    alias[alias.len - 1] = "/tmp/baseline";
    try std.testing.expectError(error.PathAlias, cli.parseProfiled(&alias));
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

fn countArg(args: []const []const u8, needle: []const u8) usize {
    var count: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) count += 1;
    }
    return count;
}

fn profiledArgs() [cli.max_arguments][]const u8 {
    return .{
        "run-profiled-stage3",                              "/private/tmp/checkpoint",                                          root_token,
        "--repo",                                           "ohah/maru",                                                        "--tag",
        "v1.2.3",                                           "--github-cli",                                                     "/usr/bin/gh",
        "--github-cli-sha256",                              "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "--test-uuid",
        "123e4567-e89b-42d3-a456-426614174000",             "--dmg",                                                            "/tmp/candidate/Maru-1.2.3-universal.dmg",
        "--frozen-executable",                              "/tmp/candidate/maru-session-host-1.2.3",                           "--candidate-dmg-bundle",
        "/tmp/attest/dmg.json",                             "--candidate-frozen-bundle",                                        "/tmp/attest/frozen.json",
        "--dmg-work",                                       "/tmp/dmg-work",                                                    "--baseline-workspace",
        "/tmp/baseline",                                    "--app-main-executable",                                            "/tmp/candidate/Maru.app/Contents/MacOS/maru-macos-app",
        "--app-cli-executable",                             "/tmp/candidate/Maru.app/Contents/MacOS/maru",                      "--manifest",
        "/tmp/output/Maru-1.2.3-session-host-release.json", "--source-root",                                                    "/tmp/source",
        "--zig",                                            "/usr/bin/zig",                                                     "--zig-size",
        "123456",                                           "--zig-sha256",                                                     "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        "--durable-preparation",                            "/tmp/preparation",                                                 "--predecessor-workspace",
        "/tmp/predecessor",                                 "--upgrade-workspace",                                              "/tmp/upgrade",
        "--timing-output",                                  "/tmp/timing/profile-upgrade.json",                                 "--signed-cli-ssh",
        "/tmp/p5d/signed-cli-ssh.json",
    };
}

const root_token = "maru-root-v1-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
