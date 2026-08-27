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
    });
    try std.testing.expectEqualStrings("v1.2.3", parsed.pre_publish.tag);
    try std.testing.expectEqualStrings("out.json", parsed.pre_publish.summary_out);
}

test "release adapter parses exact predecessor command" {
    const parsed = try adapter.parseArgs(&.{
        "verify-predecessor",
        "--repo",
        "ohah/maru",
        "--tag",
        "v1.2.3",
        "--manifest",
        "Maru-1.2.3-session-host-release.json",
        "--work-dir",
        "download",
        "--summary-out",
        "audit.json",
    });
    try std.testing.expectEqualStrings("download", parsed.verify_predecessor.work_dir);
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
        "verify-predecessor", "--repo",                               "ohah/maru",  "--tag",                                "v1.2.3",
        "--manifest",         "Maru-1.2.3-session-host-release.json", "--work-dir", "Maru-1.2.3-session-host-release.json", "--summary-out",
        "audit.json",
    }));
    const too_long = "x" ** (adapter.max_cli_value_bytes + 1);
    try std.testing.expectError(error.ValueTooLong, adapter.parseArgs(&.{
        "verify-predecessor", "--repo", "ohah/maru",  "--tag",    "v1.2.3",
        "--manifest",         too_long, "--work-dir", "download", "--summary-out",
        "audit.json",
    }));
}

test "release adapter command surfaces remain phase-separated" {
    try std.testing.expectError(error.UnknownOption, adapter.parseArgs(&.{
        "verify-predecessor", "--repo",                               "ohah/maru",  "--tag",         "v1.2.3",
        "--manifest",         "Maru-1.2.3-session-host-release.json", "--evidence", "evidence.json", "--work-dir",
        "download",           "--summary-out",                        "audit.json",
    }));
    try std.testing.expectError(error.UnknownOption, adapter.parseArgs(&.{
        "pre-publish",   "--repo",                               "ohah/maru",  "--tag",         "v1.2.3",
        "--manifest",    "Maru-1.2.3-session-host-release.json", "--evidence", "evidence.json", "--dmg",
        "dmg",           "--frozen-executable",                  "maru",       "--work-dir",    "download",
        "--summary-out", "audit.json",
    }));
}

test "release adapter freezes audit schema and protected environment" {
    try std.testing.expectEqualStrings("maru.session-host-release-validation.v1", adapter.summary_schema);
    try std.testing.expectEqualStrings("release", adapter.protected_environment_name);
    try std.testing.expect(!adapter.accepts_observation_json_input);
}
