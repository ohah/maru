//! Proves that release identity comes from one closed GitHub Actions context and is bound to the
//! canonical manifest. This is a component seam: it does not claim GitHub API or attestation E2E.

const std = @import("std");
const context = @import("release_adapter_context");
const manifest = @import("release_manifest");

const good_entries = [_]context.Entry{
    .{ .name = "GITHUB_REPOSITORY", .value = "ohah/maru" },
    .{ .name = "GITHUB_REPOSITORY_ID", .value = "123456" },
    .{ .name = "GITHUB_REF", .value = "refs/tags/v1.2.3" },
    .{ .name = "GITHUB_REF_TYPE", .value = "tag" },
    .{ .name = "GITHUB_REF_NAME", .value = "v1.2.3" },
    .{ .name = "GITHUB_SHA", .value = "0123456789abcdef0123456789abcdef01234567" },
    .{ .name = "GITHUB_WORKFLOW_REF", .value = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3" },
    .{ .name = "GITHUB_RUN_ID", .value = "987654" },
    .{ .name = "GITHUB_RUN_ATTEMPT", .value = "2" },
    .{ .name = "GITHUB_EVENT_NAME", .value = "push" },
    .{ .name = "GITHUB_REF_PROTECTED", .value = "true" },
};

fn sampleManifest() manifest.Manifest {
    return .{
        .schema = manifest.schema,
        .role = .a,
        .repository = .{ .id = 123456, .owner = "ohah", .name = "maru" },
        .release = .{ .id = 7, .tag = "v1.2.3", .version = "1.2.3" },
        .source = .{ .commit = good_entries[5].value, .tree = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .build = .{ .workflow_ref = good_entries[6].value, .run_id = 987654, .run_attempt = 2 },
        .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
        .signing = .{ .bundle_id = "com.example.Maru", .bundle_short_version = "1.2.3", .bundle_version = "1", .team_id = "ABCDEFGHIJ", .designated_requirement_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
        .assets = &.{},
        .evidence = .{ .test_uuid = "00000000-0000-4000-8000-000000000000", .summary_name = "evidence.json", .summary_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .result = "pass" },
    };
}

test "trusted tag context yields manifest identity and binds exactly" {
    const parsed = try context.parse(&good_entries);
    try context.bindManifest(parsed, sampleManifest());
    try std.testing.expectEqual(@as(u64, 123456), parsed.repository.id);
    try std.testing.expect(parsed.protected_tag);
}

test "missing duplicate and unknown captured keys fail closed" {
    try std.testing.expectError(error.MissingKey, context.parse(good_entries[0 .. good_entries.len - 1]));
    var duplicate = good_entries;
    duplicate[10] = duplicate[0];
    try std.testing.expectError(error.DuplicateKey, context.parse(&duplicate));
    var unknown = good_entries;
    unknown[10].name = "GITHUB_ACTOR";
    try std.testing.expectError(error.UnknownKey, context.parse(&unknown));
}

test "noncanonical numeric and oversized scalar values are rejected" {
    var entries = good_entries;
    entries[1].value = "0123456";
    try std.testing.expectError(error.InvalidRepository, context.parse(&entries));
    entries = good_entries;
    entries[8].value = "0";
    try std.testing.expectError(error.InvalidBuild, context.parse(&entries));
    entries = good_entries;
    entries[0].value = "x" ** (context.max_value_bytes + 1);
    try std.testing.expectError(error.ValueTooLong, context.parse(&entries));
}

test "non-tag push and inconsistent tag identity are rejected" {
    var entries = good_entries;
    entries[9].value = "workflow_dispatch";
    try std.testing.expectError(error.UntrustedTrigger, context.parse(&entries));
    entries = good_entries;
    entries[2].value = "refs/heads/main";
    try std.testing.expectError(error.InvalidRef, context.parse(&entries));
    entries = good_entries;
    entries[4].value = "v1.02.3";
    try std.testing.expectError(error.InvalidRef, context.parse(&entries));
    entries = good_entries;
    entries[10].value = "false";
    try std.testing.expectError(error.UnprotectedRef, context.parse(&entries));
}

test "foreign workflow and each context-owned manifest identity field are rejected" {
    var entries = good_entries;
    entries[6].value = "evil/fork/.github/workflows/release.yml@refs/tags/v1.2.3";
    try std.testing.expectError(error.InvalidWorkflow, context.parse(&entries));

    const parsed = try context.parse(&good_entries);
    var candidate = sampleManifest();
    candidate.repository.id += 1;
    try std.testing.expectError(error.ManifestMismatch, context.bindManifest(parsed, candidate));
    candidate = sampleManifest();
    candidate.repository.owner = "attacker";
    try std.testing.expectError(error.ManifestMismatch, context.bindManifest(parsed, candidate));
    candidate = sampleManifest();
    candidate.repository.name = "fork";
    try std.testing.expectError(error.ManifestMismatch, context.bindManifest(parsed, candidate));
    candidate = sampleManifest();
    candidate.source.commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.ManifestMismatch, context.bindManifest(parsed, candidate));
    candidate = sampleManifest();
    candidate.build.workflow_ref = "ohah/maru/.github/workflows/other.yml@refs/tags/v1.2.3";
    try std.testing.expectError(error.ManifestMismatch, context.bindManifest(parsed, candidate));
    candidate = sampleManifest();
    candidate.build.run_id += 1;
    try std.testing.expectError(error.ManifestMismatch, context.bindManifest(parsed, candidate));
    candidate = sampleManifest();
    candidate.build.run_attempt += 1;
    try std.testing.expectError(error.ManifestMismatch, context.bindManifest(parsed, candidate));
    candidate = sampleManifest();
    candidate.release.tag = "v1.2.4";
    try std.testing.expectError(error.ManifestMismatch, context.bindManifest(parsed, candidate));
}
