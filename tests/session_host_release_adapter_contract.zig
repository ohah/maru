//! Release provenance adapter의 승인된 CLI·asset 이름 계약을 고정한다.
//!
//! 이 gate는 GitHub/codesign을 흉내 내지 않는다. 외부 관측을 시작하기 전에 command와 로컬
//! artifact authority가 닫혀 있어야 shell workflow가 별도 입력 포맷이나 우회 command를 만들 수 없다.

const std = @import("std");
const adapter = @import("release_adapter");

test "release adapter manifest asset name is version-bound and canonical" {
    var buf: [adapter.max_manifest_asset_name_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Maru-1.2.3-session-host-release.json",
        try adapter.manifestAssetName(&buf, "1.2.3"),
    );
    try std.testing.expectError(error.InvalidVersion, adapter.manifestAssetName(&buf, "v1.2.3"));
    try std.testing.expectError(error.InvalidVersion, adapter.manifestAssetName(&buf, "01.2.3"));
    try std.testing.expectError(error.InvalidVersion, adapter.manifestAssetName(&buf, "1.2"));
    try std.testing.expectError(error.InvalidVersion, adapter.manifestAssetName(&buf, "1.2.3-beta"));
}

test "release adapter parses exact pre-publish command independent of option order" {
    const parsed = try adapter.parseArgs(&.{
        "pre-publish",
        "--summary-out",
        "out.json",
        "--tag",
        "v1.2.3",
        "--github-cli",
        "/opt/homebrew/bin/gh",
        "--github-cli-sha256",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "--dmg",
        "Maru-1.2.3-universal.dmg",
        "--manifest",
        "Maru-1.2.3-session-host-release.json",
        "--repo",
        "ohah/maru",
        "--frozen-executable",
        "maru",
        "--evidence",
        "evidence.json",
        "--work-dir",
        "/tmp/pre-publish-work",
    });
    try std.testing.expectEqualStrings("v1.2.3", parsed.pre_publish.tag);
    try std.testing.expectEqualStrings("/tmp/pre-publish-work", parsed.pre_publish.work_dir);
    try std.testing.expectEqualStrings("out.json", parsed.pre_publish.summary_out);
}

test "release adapter parses exact predecessor command" {
    const parsed = try adapter.parseArgs(&.{
        "verify-predecessor",
        "--repo",
        "ohah/maru",
        "--tag",
        "v1.2.3",
        "--github-cli",
        "/opt/homebrew/bin/gh",
        "--github-cli-sha256",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "--manifest",
        "Maru-1.2.3-session-host-release.json",
        "--work-dir",
        "/tmp/download",
        "--summary-out",
        "audit.json",
    });
    try std.testing.expectEqualStrings("/tmp/download", parsed.verify_predecessor.work_dir);
}

fn candidateArgs() [37][]const u8 {
    return .{
        "publish-candidate",                        "--repo",                               "ohah/maru",                                             "--tag",                                   "v1.2.3",                                      "--github-cli",                                                     "/usr/local/bin/gh",                                "--github-cli-sha256",                   "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "--test-uuid",                              "123e4567-e89b-42d3-a456-426614174000", "--dmg",                                                 "/tmp/candidate/Maru-1.2.3-universal.dmg", "--frozen-executable",                         "/tmp/candidate/maru-session-host-1.2.3",                           "--dmg-work",                                       "/tmp/dmg-work",                         "--baseline-workspace",
        "/tmp/baseline-work",                       "--app-main-executable",                "/tmp/candidate/Maru.app/Contents/MacOS/maru-macos-app", "--app-cli-executable",                    "/tmp/candidate/Maru.app/Contents/MacOS/maru", "--manifest",                                                       "/tmp/output/Maru-1.2.3-session-host-release.json", "--source-root",                         "/tmp/candidate",
        "--zig",                                    "/usr/local/bin/zig",                   "--zig-size",                                            "123456",                                  "--zig-sha256",                                "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", "--candidate-dmg-bundle",                           "/tmp/attest/candidate-dmg.bundle.json", "--candidate-frozen-bundle",
        "/tmp/attest/candidate-frozen.bundle.json",
    };
}

fn prepareAggregateArgs() [21][]const u8 {
    return .{
        "prepare-candidate-aggregate",      "--repo",                           "ohah/maru",                      "--tag",                                                            "v1.2.3",
        "--github-cli",                     "/usr/local/bin/gh",                "--github-cli-sha256",            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "--evidence",
        "/tmp/source/evidence.json",        "--candidate-dmg-bundle",           "/tmp/source/candidate-dmg.json", "--candidate-frozen-bundle",                                        "/tmp/source/candidate-frozen.json",
        "--evidence-bundle",                "/tmp/source/evidence-bundle.json", "--manifest-bundle",              "/tmp/source/manifest-bundle.json",                                 "--aggregate",
        "/tmp/handoff/candidate-aggregate",
    };
}

fn finalizeAggregateArgs() [17][]const u8 {
    return .{
        "finalize-candidate-aggregate",     "--repo",                                              "ohah/maru",               "--tag",                                                            "v1.2.3",
        "--github-cli",                     "/usr/local/bin/gh",                                   "--github-cli-sha256",     "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "--aggregate",
        "/tmp/handoff/candidate-aggregate", "--dmg",                                               "/tmp/artifacts/Maru.dmg", "--frozen-executable",                                              "/tmp/artifacts/maru-session-host",
        "--manifest",                       "/tmp/artifacts/Maru-1.2.3-session-host-release.json",
    };
}

fn resumePublicationArgs() [17][]const u8 {
    return .{
        "resume-candidate-publication", "--repo",                      "ohah/maru",              "--tag",                                                            "v1.2.3",
        "--github-cli",                 "/usr/local/bin/gh",           "--github-cli-sha256",    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "--preparation",
        "/tmp/handoff/preparation",     "--aggregate",                 "/tmp/handoff/aggregate", "--dmg",                                                            "/tmp/artifacts/Maru.dmg",
        "--frozen-executable",          "/tmp/artifacts/session-host",
    };
}

fn cleanupAggregateArgs() [17][]const u8 {
    return .{
        "cleanup-candidate-aggregate", "--repo",                                              "ohah/maru",               "--tag",                                                            "v1.2.3",
        "--github-cli",                "/usr/local/bin/gh",                                   "--github-cli-sha256",     "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "--aggregate",
        "/tmp/handoff/aggregate",      "--dmg",                                               "/tmp/artifacts/Maru.dmg", "--frozen-executable",                                              "/tmp/artifacts/session-host",
        "--manifest",                  "/tmp/artifacts/Maru-1.2.3-session-host-release.json",
    };
}

test "release adapter parses exact published aggregate cleanup command" {
    const parsed = try adapter.parseArgs(&cleanupAggregateArgs());
    try std.testing.expectEqualStrings("ohah/maru", parsed.cleanup_candidate_aggregate.repo);
    try std.testing.expectEqualStrings("v1.2.3", parsed.cleanup_candidate_aggregate.tag);
    try std.testing.expectEqualStrings("/tmp/handoff/aggregate", parsed.cleanup_candidate_aggregate.aggregate);

    var foreign = cleanupAggregateArgs();
    foreign[15] = "--release-id";
    try std.testing.expectError(error.UnknownOption, adapter.parseArgs(&foreign));
    var relative = cleanupAggregateArgs();
    relative[10] = "relative/aggregate";
    try std.testing.expectError(error.InvalidCandidatePath, adapter.parseArgs(&relative));
    const missing = cleanupAggregateArgs();
    try std.testing.expectError(error.MissingOption, adapter.parseArgs(missing[0 .. missing.len - 2]));
}

test "release adapter parses exact resumed publication command" {
    const parsed = try adapter.parseArgs(&resumePublicationArgs());
    try std.testing.expectEqualStrings("/tmp/handoff/preparation", parsed.resume_candidate_publication.preparation);
    try std.testing.expectEqualStrings("/tmp/handoff/aggregate", parsed.resume_candidate_publication.aggregate);
    try std.testing.expectEqualStrings("/tmp/artifacts/Maru.dmg", parsed.resume_candidate_publication.dmg);
}

test "resumed publication vocabulary and path graph are closed" {
    var args = resumePublicationArgs();
    args[9] = "--manifest";
    try std.testing.expectError(error.UnknownOption, adapter.parseArgs(&args));
    args = resumePublicationArgs();
    args[12] = "/tmp/handoff/preparation/aggregate";
    try std.testing.expectError(error.PathAlias, adapter.parseArgs(&args));
    args = resumePublicationArgs();
    args[16] = "relative/session-host";
    try std.testing.expectError(error.InvalidCandidatePath, adapter.parseArgs(&args));
    args = resumePublicationArgs();
    args[10] = "/tmp/handoff/preparation/";
    try std.testing.expectError(error.InvalidCandidatePath, adapter.parseArgs(&args));
    const missing = resumePublicationArgs();
    try std.testing.expectError(error.MissingOption, adapter.parseArgs(missing[0 .. missing.len - 2]));
}

test "release adapter parses exact aggregate prepare and finalize commands" {
    const prepare = try adapter.parseArgs(&prepareAggregateArgs());
    try std.testing.expectEqualStrings("/tmp/source/evidence.json", prepare.prepare_candidate_aggregate.evidence);
    try std.testing.expectEqualStrings("/tmp/handoff/candidate-aggregate", prepare.prepare_candidate_aggregate.aggregate);
    const finalize = try adapter.parseArgs(&finalizeAggregateArgs());
    try std.testing.expectEqualStrings("/tmp/handoff/candidate-aggregate", finalize.finalize_candidate_aggregate.aggregate);
    try std.testing.expectEqualStrings("/tmp/artifacts/maru-session-host", finalize.finalize_candidate_aggregate.frozen_executable);
}

test "release adapter closes aggregate command option and path authority" {
    var prepare = prepareAggregateArgs();
    prepare[19] = "--dmg";
    try std.testing.expectError(error.UnknownOption, adapter.parseArgs(&prepare));
    prepare = prepareAggregateArgs();
    prepare[20] = "/tmp/source/evidence.json";
    try std.testing.expectError(error.PathAlias, adapter.parseArgs(&prepare));
    prepare = prepareAggregateArgs();
    prepare[12] = "relative/candidate-dmg.json";
    try std.testing.expectError(error.InvalidCandidatePath, adapter.parseArgs(&prepare));
    prepare = prepareAggregateArgs();
    prepare[20] = "/tmp/handoff/candidate-aggregate/";
    try std.testing.expectError(error.InvalidCandidatePath, adapter.parseArgs(&prepare));
    prepare = prepareAggregateArgs();
    prepare[20] = "/tmp/handoff/bad\naggregate";
    try std.testing.expectError(error.InvalidCandidatePath, adapter.parseArgs(&prepare));
    prepare = prepareAggregateArgs();
    prepare[19] = "--evidence";
    try std.testing.expectError(error.DuplicateOption, adapter.parseArgs(&prepare));

    var finalize = finalizeAggregateArgs();
    finalize[11] = "--evidence";
    try std.testing.expectError(error.UnknownOption, adapter.parseArgs(&finalize));
    finalize = finalizeAggregateArgs();
    finalize[11] = "--candidate-dmg-bundle";
    try std.testing.expectError(error.UnknownOption, adapter.parseArgs(&finalize));
    finalize = finalizeAggregateArgs();
    finalize[10] = "/tmp/artifacts/Maru-1.2.3-session-host-release.json";
    try std.testing.expectError(error.PathAlias, adapter.parseArgs(&finalize));
    finalize = finalizeAggregateArgs();
    finalize[16] = "/tmp/artifacts/with=equals.json";
    try std.testing.expectError(error.InvalidCandidatePath, adapter.parseArgs(&finalize));
    const missing = finalizeAggregateArgs();
    try std.testing.expectError(error.MissingOption, adapter.parseArgs(missing[0 .. missing.len - 2]));
}

test "release adapter parses exact publish-candidate command and permits source ancestry" {
    var args = candidateArgs();
    const first_option = args[1];
    const first_value = args[2];
    args[1] = args[31];
    args[2] = args[32];
    args[31] = first_option;
    args[32] = first_value;
    const parsed = try adapter.parseArgs(&args);
    try std.testing.expectEqualStrings("123e4567-e89b-42d3-a456-426614174000", parsed.publish_candidate.test_uuid);
    try std.testing.expectEqualStrings("/tmp/candidate", parsed.publish_candidate.source_root);
    try std.testing.expectEqual(@as(u64, 123456), parsed.publish_candidate.zig_size);
    try std.testing.expectEqualStrings("/tmp/output/Maru-1.2.3-session-host-release.json", parsed.publish_candidate.manifest);
    try std.testing.expectEqualStrings("/tmp/attest/candidate-dmg.bundle.json", parsed.publish_candidate.candidate_dmg_bundle);
    try std.testing.expectEqualStrings("/tmp/attest/candidate-frozen.bundle.json", parsed.publish_candidate.candidate_frozen_bundle);
}

test "release adapter rejects malformed candidate UUID Zig authority and local paths" {
    var args = candidateArgs();
    args[10] = "123e4567-e89b-12d3-a456-426614174000";
    try std.testing.expectError(error.InvalidTestUuid, adapter.parseArgs(&args));
    args = candidateArgs();
    args[30] = "0123";
    try std.testing.expectError(error.InvalidZigSize, adapter.parseArgs(&args));
    args = candidateArgs();
    args[30] = "01";
    try std.testing.expectError(error.InvalidZigSize, adapter.parseArgs(&args));
    args = candidateArgs();
    args[32] = "ABC";
    try std.testing.expectError(error.InvalidZigSha256, adapter.parseArgs(&args));
    args = candidateArgs();
    args[20] = "relative/maru";
    try std.testing.expectError(error.InvalidCandidatePath, adapter.parseArgs(&args));
    args = candidateArgs();
    args[24] = "Maru-1.2.3-session-host-release.json";
    try std.testing.expectError(error.InvalidCandidatePath, adapter.parseArgs(&args));
    args = candidateArgs();
    args[16] = "/tmp/candidate/Maru.app";
    try std.testing.expectError(error.PathAlias, adapter.parseArgs(&args));
    const missing_zig_digest = candidateArgs();
    try std.testing.expectError(error.MissingOption, adapter.parseArgs(missing_zig_digest[0..31]));
    var legacy_output = candidateArgs();
    legacy_output[31] = "--summary-out";
    try std.testing.expectError(error.UnknownOption, adapter.parseArgs(&legacy_output));
    const missing_bundle = candidateArgs();
    try std.testing.expectError(error.MissingOption, adapter.parseArgs(missing_bundle[0..35]));
    var noncanonical_bundle = candidateArgs();
    noncanonical_bundle[34] = "/tmp/attest/../candidate-dmg.bundle.json";
    try std.testing.expectError(error.InvalidCandidatePath, adapter.parseArgs(&noncanonical_bundle));
}

test "release adapter requires canonical GitHub CLI authority in both phases" {
    try std.testing.expectError(error.MissingOption, adapter.parseArgs(&.{
        "verify-predecessor",                   "--repo",     "ohah/maru",     "--tag",         "v1.2.3",     "--manifest",
        "Maru-1.2.3-session-host-release.json", "--work-dir", "/tmp/download", "--summary-out", "audit.json",
    }));
    try std.testing.expectError(error.InvalidGithubCliPath, adapter.parseArgs(&.{
        "verify-predecessor",  "--repo",                                                           "ohah/maru",  "--tag",                                "v1.2.3",     "--github-cli",  "gh",
        "--github-cli-sha256", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "--manifest", "Maru-1.2.3-session-host-release.json", "--work-dir", "/tmp/download", "--summary-out",
        "audit.json",
    }));
    try std.testing.expectError(error.InvalidGithubCliSha256, adapter.parseArgs(&.{
        "verify-predecessor",  "--repo", "ohah/maru",  "--tag",                                "v1.2.3",     "--github-cli",  "/usr/bin/gh",
        "--github-cli-sha256", "ABC",    "--manifest", "Maru-1.2.3-session-host-release.json", "--work-dir", "/tmp/download", "--summary-out",
        "audit.json",
    }));
    try std.testing.expectError(error.PathAlias, adapter.parseArgs(&.{
        "verify-predecessor",                        "--repo",              "ohah/maru",                                                        "--tag",      "v1.2.3",                                    "--github-cli",
        "/tmp/Maru-1.2.3-session-host-release.json", "--github-cli-sha256", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "--manifest", "/tmp/Maru-1.2.3-session-host-release.json", "--work-dir",
        "/tmp/download",                             "--summary-out",       "audit.json",
    }));
}

test "release adapter rejects unknown missing duplicate and positional arguments" {
    try std.testing.expectError(error.MissingCommand, adapter.parseArgs(&.{}));
    try std.testing.expectError(error.UnknownCommand, adapter.parseArgs(&.{"publish"}));
    try std.testing.expectError(error.MissingValue, adapter.parseArgs(&.{ "verify-predecessor", "--repo" }));
    try std.testing.expectError(error.UnknownOption, adapter.parseArgs(&.{ "verify-predecessor", "--wat", "x" }));
    try std.testing.expectError(error.MissingOption, adapter.parseArgs(&.{ "verify-predecessor", "--repo", "ohah/maru" }));
    try std.testing.expectError(error.DuplicateOption, adapter.parseArgs(&.{
        "verify-predecessor", "--repo",        "ohah/maru",  "--repo",                               "ohah/maru",
        "--tag",              "v1.2.3",        "--manifest", "Maru-1.2.3-session-host-release.json", "--work-dir",
        "download",           "--summary-out", "audit.json",
    }));
    try std.testing.expectError(error.UnexpectedArgument, adapter.parseArgs(&.{
        "verify-predecessor", "extra",                                "--repo",     "ohah/maru", "--tag",         "v1.2.3",
        "--manifest",         "Maru-1.2.3-session-host-release.json", "--work-dir", "download",  "--summary-out", "audit.json",
    }));
}

test "release adapter rejects foreign repository and noncanonical tag" {
    try std.testing.expectError(error.InvalidRepository, adapter.parseArgs(&.{
        "verify-predecessor", "--repo",                               "other/maru", "--tag",    "v1.2.3",
        "--manifest",         "Maru-1.2.3-session-host-release.json", "--work-dir", "download", "--summary-out",
        "audit.json",
    }));
    try std.testing.expectError(error.InvalidTag, adapter.parseArgs(&.{
        "verify-predecessor", "--repo",                               "ohah/maru",  "--tag",    "v01.2.3",
        "--manifest",         "Maru-1.2.3-session-host-release.json", "--work-dir", "download", "--summary-out",
        "audit.json",
    }));
    try std.testing.expectError(error.InvalidManifestAssetName, adapter.parseArgs(&.{
        "verify-predecessor", "--repo",        "ohah/maru",  "--tag",    "v1.2.3",
        "--manifest",         "manifest.json", "--work-dir", "download", "--summary-out",
        "audit.json",
    }));
}

test "release adapter rejects empty oversized and aliased path authorities" {
    try std.testing.expectError(error.EmptyValue, adapter.parseArgs(&.{
        "verify-predecessor", "--repo", "ohah/maru",  "--tag",    "v1.2.3",
        "--manifest",         "",       "--work-dir", "download", "--summary-out",
        "audit.json",
    }));
    try std.testing.expectError(error.PathAlias, adapter.parseArgs(&.{
        "verify-predecessor",                        "--repo",               "ohah/maru",                                 "--tag",                                                            "v1.2.3",
        "--github-cli",                              "/opt/homebrew/bin/gh", "--github-cli-sha256",                       "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "--manifest",
        "/tmp/Maru-1.2.3-session-host-release.json", "--work-dir",           "/tmp/Maru-1.2.3-session-host-release.json", "--summary-out",                                                    "audit.json",
    }));
    const too_long = "x" ** (adapter.max_cli_value_bytes + 1);
    try std.testing.expectError(error.ValueTooLong, adapter.parseArgs(&.{
        "verify-predecessor", "--repo", "ohah/maru",  "--tag",    "v1.2.3",
        "--manifest",         too_long, "--work-dir", "download", "--summary-out",
        "audit.json",
    }));
}

test "release adapter requires an absolute caller-owned work directory in both phases" {
    try std.testing.expectError(error.UnknownOption, adapter.parseArgs(&.{
        "verify-predecessor", "--repo",                               "ohah/maru",  "--tag",         "v1.2.3",
        "--manifest",         "Maru-1.2.3-session-host-release.json", "--evidence", "evidence.json", "--work-dir",
        "download",           "--summary-out",                        "audit.json",
    }));
    try std.testing.expectError(error.InvalidWorkDirPath, adapter.parseArgs(&.{
        "pre-publish",   "--repo",                               "ohah/maru",  "--tag",         "v1.2.3",
        "--manifest",    "Maru-1.2.3-session-host-release.json", "--evidence", "evidence.json", "--dmg",
        "dmg",           "--frozen-executable",                  "maru",       "--work-dir",    "download",
        "--summary-out", "audit.json",
    }));
    try std.testing.expectError(error.InvalidWorkDirPath, adapter.parseArgs(&.{
        "verify-predecessor",                   "--repo",      "ohah/maru",           "--tag",                                                            "v1.2.3",
        "--github-cli",                         "/usr/bin/gh", "--github-cli-sha256", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "--manifest",
        "Maru-1.2.3-session-host-release.json", "--work-dir",  "download",            "--summary-out",                                                    "audit.json",
    }));
    for ([_][]const u8{ "/", "/tmp/../work", "/tmp/./work", "/tmp//work", "/tmp/work/" }) |work_dir| {
        try std.testing.expectError(error.InvalidWorkDirPath, adapter.parseArgs(&.{
            "verify-predecessor",                   "--repo",      "ohah/maru",           "--tag",                                                            "v1.2.3",
            "--github-cli",                         "/usr/bin/gh", "--github-cli-sha256", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "--manifest",
            "Maru-1.2.3-session-host-release.json", "--work-dir",  work_dir,              "--summary-out",                                                    "audit.json",
        }));
    }
    try std.testing.expectError(error.PathAlias, adapter.parseArgs(&.{
        "verify-predecessor",                   "--repo",      "ohah/maru",           "--tag",                                                            "v1.2.3",
        "--github-cli",                         "/usr/bin/gh", "--github-cli-sha256", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "--manifest",
        "Maru-1.2.3-session-host-release.json", "--work-dir",  "/tmp/work",           "--summary-out",                                                    "/tmp/work/audit.json",
    }));
    try std.testing.expectError(error.PathAlias, adapter.parseArgs(&.{
        "pre-publish",                                    "--repo",      "ohah/maru",           "--tag",                                                            "v1.2.3",
        "--github-cli",                                   "/usr/bin/gh", "--github-cli-sha256", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "--manifest",
        "/tmp/work/Maru-1.2.3-session-host-release.json", "--evidence",  "/tmp/evidence.json",  "--dmg",                                                            "/tmp/Maru.dmg",
        "--frozen-executable",                            "/tmp/maru",   "--work-dir",          "/tmp/work",                                                        "--summary-out",
        "/tmp/audit.json",
    }));
    const sibling = try adapter.parseArgs(&.{
        "verify-predecessor",                   "--repo",      "ohah/maru",           "--tag",                                                            "v1.2.3",
        "--github-cli",                         "/usr/bin/gh", "--github-cli-sha256", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "--manifest",
        "Maru-1.2.3-session-host-release.json", "--work-dir",  "/tmp/work",           "--summary-out",                                                    "/tmp/worker/audit.json",
    });
    try std.testing.expectEqualStrings("/tmp/work", sibling.verify_predecessor.work_dir);
}

test "release adapter freezes audit schema and protected environment" {
    try std.testing.expectEqualStrings("maru.session-host-release-validation.v1", adapter.summary_schema);
    try std.testing.expectEqualStrings("release", adapter.protected_environment_name);
    try std.testing.expect(!adapter.accepts_observation_json_input);
}
