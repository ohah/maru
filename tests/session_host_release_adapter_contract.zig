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
