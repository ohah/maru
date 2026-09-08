//! Closed selection and observation contract for the five live validator child stages.

const std = @import("std");
const command = @import("release_adapter_live_workflow_command");
const phase = @import("release_adapter_live_workflow_phase");

test "validator argv selects the five stages and preserves both stage three profiles" {
    try std.testing.expectEqual(command.Selection.draft_authoring, try command.select(&prepareArgs()));
    try std.testing.expectEqual(command.Selection.profile_draft_authoring, try command.select(&profileStage3Args()));
    try std.testing.expectEqual(command.Selection.aggregate_prepare, try command.select(&prepareAggregateArgs()));
    try std.testing.expectEqual(command.Selection.aggregate_finalize, try command.select(&finalizeAggregateArgs()));
    try std.testing.expectEqual(command.Selection.publication, try command.select(&publicationArgs()));
    try std.testing.expectEqual(command.Selection.aggregate_cleanup, try command.select(&cleanupArgs()));

    var forbidden = prepareArgs();
    forbidden[0] = "publish-candidate";
    try std.testing.expectError(error.InvalidCommand, command.select(forbidden[0..37]));
    var malformed = prepareArgs();
    malformed[1] = "--tag";
    try std.testing.expectError(error.InvalidArguments, command.select(&malformed));
}

test "selection derives stage identity and minimum environment" {
    try std.testing.expectEqual(phase.Stage.draft_authoring, command.stage(.draft_authoring));
    try std.testing.expectEqual(phase.Stage.draft_authoring, command.stage(.profile_draft_authoring));
    try std.testing.expectEqual(phase.Stage.aggregate_prepare, command.stage(.aggregate_prepare));
    try std.testing.expectEqual(phase.Stage.aggregate_finalize, command.stage(.aggregate_finalize));
    try std.testing.expectEqual(phase.Stage.publication, command.stage(.publication));
    try std.testing.expectEqual(phase.Stage.aggregate_cleanup, command.stage(.aggregate_cleanup));
    try std.testing.expect(command.requiresToken(.draft_authoring));
    try std.testing.expect(command.requiresToken(.profile_draft_authoring));
    try std.testing.expect(!command.requiresToken(.aggregate_prepare));
    try std.testing.expect(!command.requiresToken(.aggregate_finalize));
    try std.testing.expect(command.requiresToken(.publication));
    try std.testing.expect(command.requiresToken(.aggregate_cleanup));
    try std.testing.expect(command.requiresWorkspace(.draft_authoring));
    try std.testing.expect(command.requiresWorkspace(.profile_draft_authoring));
    try std.testing.expect(!command.requiresWorkspace(.publication));
    try std.testing.expect(!command.requiresProfileEnvironment(.draft_authoring));
    try std.testing.expect(command.requiresProfileEnvironment(.profile_draft_authoring));
    try std.testing.expectEqualStrings("prepare-candidate", command.commandName(.draft_authoring));
    try std.testing.expectEqualStrings("prepare-profile-candidate", command.commandName(.profile_draft_authoring));
    try std.testing.expect(command.matchesCheckpointIdentity(.draft_authoring, .draft_authoring, "prepare-candidate"));
    try std.testing.expect(command.matchesCheckpointIdentity(.profile_draft_authoring, .draft_authoring, "prepare-candidate"));
    try std.testing.expect(!command.matchesCheckpointIdentity(.profile_draft_authoring, .draft_authoring, "prepare-profile-candidate"));
    try std.testing.expect(!command.matchesCheckpointIdentity(.profile_draft_authoring, .aggregate_prepare, "prepare-candidate"));
    try std.testing.expect(command.matchesCheckpointIdentity(.aggregate_prepare, .aggregate_prepare, "prepare-candidate-aggregate"));
}

test "stage three maps only exact local failure to pristine failure" {
    inline for (.{ command.Selection.draft_authoring, command.Selection.profile_draft_authoring }) |selection| {
        try expectResult(.failed_before_remote_mutation, selection, 20, "local_failure\n");
        try expectResult(.succeeded, selection, 0, "success\n");
        try expectResult(.failed, selection, 21, "audit_required\n");
        try expectResult(.cleanup_failed, selection, 22, "cleanup_failed\n");
        try expectResult(.cleanup_failed, selection, 20, "success\n");
    }
}

test "aggregate commands preserve only their closed child outcomes" {
    inline for (.{ command.Selection.aggregate_prepare, command.Selection.aggregate_finalize }) |selection| {
        try expectResult(.succeeded, selection, 0, "success\n");
        try expectResult(.failed, selection, 21, "audit_required\n");
        try expectResult(.cleanup_failed, selection, 22, "cleanup_failed\n");
        try expectResult(.cleanup_failed, selection, 0, "audit_required\n");
    }
}

test "publication and cleanup map conservative terminal outcomes" {
    try expectResult(.succeeded, .publication, 0, "success\n");
    try expectResult(.failed, .publication, 21, "audit_required\n");
    try expectResult(.cleanup_failed, .publication, 22, "cleanup_failed\n");
    try expectResult(.succeeded, .aggregate_cleanup, 0, "success\n");
    try expectResult(.failed, .aggregate_cleanup, 21, "audit_required\n");
    try expectResult(.cleanup_failed, .aggregate_cleanup, 22, "cleanup_required\n");
    try expectResult(.cleanup_failed, .aggregate_cleanup, 23, "descriptor_close_failed\n");
}

test "incomplete unknown and noisy observations always require cleanup" {
    const base = command.Observation{
        .termination = .{ .exited = 0 },
        .stdout = .{ .bytes = "", .complete = true },
        .stderr = .{ .bytes = "success\n", .complete = true },
    };
    var value = base;
    value.stdout.complete = false;
    try std.testing.expectEqual(phase.Result.cleanup_failed, command.classify(.publication, value));
    value = base;
    value.stderr.complete = false;
    try std.testing.expectEqual(phase.Result.cleanup_failed, command.classify(.publication, value));
    value = base;
    value.stdout.bytes = "noise";
    try std.testing.expectEqual(phase.Result.cleanup_failed, command.classify(.publication, value));
    value = base;
    value.termination = .{ .signal = 9 };
    try std.testing.expectEqual(phase.Result.cleanup_failed, command.classify(.publication, value));
    value = base;
    value.termination = .{ .unknown = 0 };
    try std.testing.expectEqual(phase.Result.cleanup_failed, command.classify(.publication, value));
}

fn expectResult(expected: phase.Result, selection: command.Selection, code: u8, stderr: []const u8) !void {
    try std.testing.expectEqual(expected, command.classify(selection, .{
        .termination = .{ .exited = code },
        .stdout = .{ .bytes = "", .complete = true },
        .stderr = .{ .bytes = stderr, .complete = true },
    }));
}

fn prepareArgs() [39][]const u8 {
    return .{
        "prepare-candidate",       "--repo",                               "ohah/maru",                                             "--tag",                                   "v1.2.3",                                      "--github-cli",                           "/usr/bin/gh",                                      "--github-cli-sha256",  hex64,
        "--test-uuid",             "123e4567-e89b-42d3-a456-426614174000", "--dmg",                                                 "/tmp/candidate/Maru-1.2.3-universal.dmg", "--frozen-executable",                         "/tmp/candidate/maru-session-host-1.2.3", "--dmg-work",                                       "/tmp/dmg-work",        "--baseline-workspace",
        "/tmp/baseline",           "--app-main-executable",                "/tmp/candidate/Maru.app/Contents/MacOS/maru-macos-app", "--app-cli-executable",                    "/tmp/candidate/Maru.app/Contents/MacOS/maru", "--manifest",                             "/tmp/output/Maru-1.2.3-session-host-release.json", "--source-root",        "/tmp/source",
        "--zig",                   "/usr/bin/zig",                         "--zig-size",                                            "123456",                                  "--zig-sha256",                                hex64,                                    "--candidate-dmg-bundle",                           "/tmp/attest/dmg.json", "--candidate-frozen-bundle",
        "/tmp/attest/frozen.json", "--durable-preparation",                "/tmp/preparation",
    };
}

fn profileStage3Args() [39][]const u8 {
    return .{
        "prepare-profile-candidate",                "--repo",                               "ohah/maru",                        "--tag",                                   "v1.2.3",                                           "--github-cli",                           "/usr/bin/gh",            "--github-cli-sha256",                   hex64,
        "--test-uuid",                              "123e4567-e89b-42d3-a456-426614174000", "--dmg",                            "/tmp/candidate/Maru-1.2.3-universal.dmg", "--frozen-executable",                              "/tmp/candidate/maru-session-host-1.2.3", "--candidate-dmg-bundle", "/tmp/attest/candidate-dmg.bundle.json", "--candidate-frozen-bundle",
        "/tmp/attest/candidate-frozen.bundle.json", "--dmg-work",                           "/tmp/dmg-work",                    "--manifest",                              "/tmp/output/Maru-1.2.3-session-host-release.json", "--source-root",                          "/tmp/source",            "--zig",                                 "/usr/bin/zig",
        "--zig-size",                               "123456",                               "--zig-sha256",                     hex64,                                     "--predecessor-workspace",                          "/tmp/predecessor-work",                  "--upgrade-workspace",    "/tmp/upgrade-work",                     "--durable-preparation",
        "/tmp/handoff/profile-stage3",              "--timing-output",                      "/tmp/timing/profile-upgrade.json",
    };
}

fn prepareAggregateArgs() [21][]const u8 {
    return .{
        "prepare-candidate-aggregate", "--repo",             "ohah/maru",              "--tag",                   "v1.2.3",                    "--github-cli",               "/usr/bin/gh",       "--github-cli-sha256",       hex64,
        "--evidence",                  "/tmp/evidence.json", "--candidate-dmg-bundle", "/tmp/candidate-dmg.json", "--candidate-frozen-bundle", "/tmp/candidate-frozen.json", "--evidence-bundle", "/tmp/evidence-bundle.json", "--manifest-bundle",
        "/tmp/manifest-bundle.json",   "--aggregate",        "/tmp/aggregate",
    };
}

fn finalizeAggregateArgs() [17][]const u8 {
    return .{
        "finalize-candidate-aggregate", "--repo",         "ohah/maru", "--tag",                         "v1.2.3",              "--github-cli",                 "/usr/bin/gh", "--github-cli-sha256",                       hex64,
        "--aggregate",                  "/tmp/aggregate", "--dmg",     "/tmp/Maru-1.2.3-universal.dmg", "--frozen-executable", "/tmp/maru-session-host-1.2.3", "--manifest",  "/tmp/Maru-1.2.3-session-host-release.json",
    };
}

fn publicationArgs() [17][]const u8 {
    return .{
        "resume-candidate-publication", "--repo",           "ohah/maru",   "--tag",          "v1.2.3", "--github-cli",                  "/usr/bin/gh",         "--github-cli-sha256",          hex64,
        "--preparation",                "/tmp/preparation", "--aggregate", "/tmp/aggregate", "--dmg",  "/tmp/Maru-1.2.3-universal.dmg", "--frozen-executable", "/tmp/maru-session-host-1.2.3",
    };
}

fn cleanupArgs() [17][]const u8 {
    return .{
        "cleanup-candidate-aggregate", "--repo",         "ohah/maru", "--tag",                         "v1.2.3",              "--github-cli",                 "/usr/bin/gh", "--github-cli-sha256",                       hex64,
        "--aggregate",                 "/tmp/aggregate", "--dmg",     "/tmp/Maru-1.2.3-universal.dmg", "--frozen-executable", "/tmp/maru-session-host-1.2.3", "--manifest",  "/tmp/Maru-1.2.3-session-host-release.json",
    };
}

const hex64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
