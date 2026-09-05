//! Artifact attestation이 verified certificate의 exact release run과 subject에 결속되는지 검증한다.
//!
//! 이 gate는 GitHub CLI pathname pin이나 workflow 배선을 주장하지 않는다. 고정 argv, clean child
//! environment, bounded capture와 certificate/statement 의미만 닫는다.

const std = @import("std");
const c = std.c;
const attestation = @import("release_adapter_github_attestation");

const source_sha = "0123456789abcdef0123456789abcdef01234567";
const subject_sha = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
const subject_name = "Maru-1.2.3-universal.dmg";

fn expected() attestation.Expected {
    return .{
        .context = .{
            .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
            .tag = "v1.2.3",
            .source_commit = source_sha,
            .build = .{
                .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
                .run_id = 333,
                .run_attempt = 2,
            },
            .protected_tag = true,
        },
        .subject_name = subject_name,
        .subject_sha256 = subject_sha,
    };
}

const valid_json =
    \\[{"attestation":{},"verificationResult":{"signature":{"certificate":{
    \\"subjectAlternativeName":"https://github.com/ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
    \\"issuer":"https://token.actions.githubusercontent.com","githubWorkflowTrigger":"push",
    \\"githubWorkflowSHA":"0123456789abcdef0123456789abcdef01234567","githubWorkflowRepository":"ohah/maru",
    \\"githubWorkflowRef":"refs/tags/v1.2.3","buildSignerURI":"https://github.com/ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
    \\"buildSignerDigest":"0123456789abcdef0123456789abcdef01234567","runnerEnvironment":"github-hosted",
    \\"sourceRepositoryURI":"https://github.com/ohah/maru","sourceRepositoryDigest":"0123456789abcdef0123456789abcdef01234567",
    \\"sourceRepositoryRef":"refs/tags/v1.2.3","sourceRepositoryIdentifier":"12345",
    \\"sourceRepositoryOwnerURI":"https://github.com/ohah","buildConfigURI":"https://github.com/ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
    \\"buildConfigDigest":"0123456789abcdef0123456789abcdef01234567","buildTrigger":"push",
    \\"runInvocationURI":"https://github.com/ohah/maru/actions/runs/333/attempts/2","sourceRepositoryVisibilityAtSigning":"public"}},
    \\"statement":{"_type":"https://in-toto.io/Statement/v1","subject":[{"name":"Maru-1.2.3-universal.dmg",
    \\"digest":{"sha256":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}}],
    \\"predicateType":"https://slsa.dev/provenance/v1","predicate":{"buildDefinition":{"buildType":"https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1",
    \\"externalParameters":{"workflow":{"path":".github/workflows/release.yml","ref":"refs/tags/v1.2.3","repository":"https://github.com/ohah/maru"}},
    \\"internalParameters":{"github":{"event_name":"push","repository_id":"12345"}},
    \\"resolvedDependencies":[{"uri":"git+https://github.com/ohah/maru@refs/tags/v1.2.3","digest":{"gitCommit":"0123456789abcdef0123456789abcdef01234567"}}]},
    \\"runDetails":{"builder":{"id":"https://github.com/actions/runner/github-hosted"},"metadata":{"invocationId":"https://github.com/ohah/maru/actions/runs/333/attempts/2"}}}},
    \\"verifiedTimestamps":[{"type":"TimestampAuthority","uri":"timestamp.githubapp.com","timestamp":"2026-08-31T00:00:00Z"}]}}]
;

test "artifact attestation argv is closed and token-free" {
    var storage: attestation.ArgsStorage = undefined;
    const plan = try attestation.plan(&storage, "/tmp/Maru.dmg", expected());
    const want = [_][]const u8{
        "attestation",                    "verify",                                  "/tmp/Maru.dmg",    "--repo",                     "ohah/maru",
        "--signer-workflow",              "ohah/maru/.github/workflows/release.yml", "--signer-digest",  source_sha,                   "--source-digest",
        source_sha,                       "--source-ref",                            "refs/tags/v1.2.3", "--deny-self-hosted-runners", "--predicate-type",
        "https://slsa.dev/provenance/v1", "--format",                                "json",
    };
    try std.testing.expectEqual(want.len, plan.args.len);
    for (want, plan.args) |left, right| try std.testing.expectEqualStrings(left, right);
    for (plan.args) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "secret-token") == null);
    try std.testing.expectError(error.InvalidPath, attestation.plan(&storage, "relative.dmg", expected()));
    var invented_historical = expected();
    invented_historical.tag_protection = .historical_unavailable;
    try std.testing.expectError(error.InvalidExpected, attestation.plan(&storage, "/tmp/Maru.dmg", invented_historical));
}

test "held-directory artifact argv accepts only exact dot slash basename" {
    var storage: attestation.ArgsStorage = undefined;
    const request = try attestation.planDirectory(&storage, "./Maru-1.2.3-universal.dmg", expected());
    try std.testing.expectEqualStrings("./Maru-1.2.3-universal.dmg", request.args[2]);
    try std.testing.expectError(error.InvalidPath, attestation.planDirectory(&storage, "Maru-1.2.3-universal.dmg", expected()));
    try std.testing.expectError(error.InvalidPath, attestation.planDirectory(&storage, "./nested/asset", expected()));
    try std.testing.expectError(error.InvalidPath, attestation.planDirectory(&storage, "/tmp/asset", expected()));
    try std.testing.expectError(error.InvalidPath, attestation.planDirectory(&storage, "./.", expected()));
    try std.testing.expectError(error.InvalidPath, attestation.planDirectory(&storage, "./..", expected()));
}

test "same-run bundle argv is closed and distinct from API lookup" {
    var storage: attestation.ArgsStorage = undefined;
    const request = try attestation.planBundle(
        &storage,
        "/tmp/Maru.dmg",
        "/tmp/Maru.dmg.attestation.json",
        expected(),
    );
    const want = [_][]const u8{
        "attestation",                             "verify",                         "/tmp/Maru.dmg",    "--bundle",
        "/tmp/Maru.dmg.attestation.json",          "--repo",                         "ohah/maru",        "--signer-workflow",
        "ohah/maru/.github/workflows/release.yml", "--signer-digest",                source_sha,         "--source-digest",
        source_sha,                                "--source-ref",                   "refs/tags/v1.2.3", "--deny-self-hosted-runners",
        "--predicate-type",                        "https://slsa.dev/provenance/v1", "--format",         "json",
    };
    try std.testing.expectEqual(want.len, request.args.len);
    for (want, request.args) |left, right| try std.testing.expectEqualStrings(left, right);
    for (request.args) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "GH_TOKEN") == null);
}

test "same-run bundle rejects ambiguous pathname authority" {
    var storage: attestation.ArgsStorage = undefined;
    try std.testing.expectError(error.InvalidPath, attestation.planBundle(&storage, "/tmp/Maru.dmg", "relative.json", expected()));
    try std.testing.expectError(error.InvalidPath, attestation.planBundle(&storage, "/tmp/Maru.dmg", "/tmp/Maru.dmg", expected()));
    try std.testing.expectError(error.InvalidPath, attestation.planBundle(&storage, "/tmp/Maru.dmg", "/tmp/../bundle.json", expected()));
    try std.testing.expectError(error.InvalidPath, attestation.planBundle(&storage, "/tmp/Maru.dmg", "/tmp//bundle.json", expected()));
    try std.testing.expectError(error.InvalidPath, attestation.planBundle(&storage, "/tmp/Maru.dmg", "/tmp/bundle.json/", expected()));
    try std.testing.expectError(error.InvalidPath, attestation.planBundle(&storage, "/tmp/Maru.dmg", "/tmp/bad\nbundle.json", expected()));

    const Never = struct {
        pub fn capture(_: *@This(), _: []const u8, _: []const []const u8, _: []const []const u8, _: []u8, _: i128) ![]const u8 {
            return error.UnexpectedChild;
        }
    };
    var never = Never{};
    var shared: [attestation.max_response_bytes]u8 = undefined;
    const artifact_path = "/tmp/Maru.dmg";
    @memcpy(shared[0..artifact_path.len], artifact_path);
    try std.testing.expectError(error.InvalidPath, attestation.verifyBundleWith(
        &never,
        std.testing.allocator,
        "/opt/trusted/gh",
        shared[0..artifact_path.len],
        "/tmp/bundle.json",
        expected(),
        &shared,
        std.time.ns_per_s,
    ));

    var aliased_expected = expected();
    @memcpy(shared[0..aliased_expected.context.tag.len], aliased_expected.context.tag);
    aliased_expected.context.tag = shared[0..aliased_expected.context.tag.len];
    try std.testing.expectError(error.InvalidPath, attestation.verifyBundleWith(
        &never,
        std.testing.allocator,
        "/opt/trusted/gh",
        "/tmp/Maru.dmg",
        "/tmp/bundle.json",
        aliased_expected,
        &shared,
        std.time.ns_per_s,
    ));
}

test "same-run bundle execution is token-free and uses supplied capture" {
    const Fake = struct {
        pub fn capture(_: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) ![]const u8 {
            try std.testing.expectEqualStrings("/opt/trusted/gh", executable);
            try std.testing.expectEqual(@as(usize, 20), args.len);
            try std.testing.expectEqualStrings("--bundle", args[3]);
            try std.testing.expectEqualStrings("/tmp/Maru.dmg.attestation.json", args[4]);
            try std.testing.expectEqual(@as(usize, 1), environment.len);
            try std.testing.expectEqualStrings("GH_PROMPT_DISABLED=1", environment[0]);
            try std.testing.expect(budget_ns > 0);
            @memcpy(output[0..valid_json.len], valid_json);
            return output[0..valid_json.len];
        }
    };
    var fake = Fake{};
    var output: [attestation.max_response_bytes]u8 = undefined;
    var observed = try attestation.verifyBundleWith(
        &fake,
        std.testing.allocator,
        "/opt/trusted/gh",
        "/tmp/Maru.dmg",
        "/tmp/Maru.dmg.attestation.json",
        expected(),
        &output,
        std.time.ns_per_s,
    );
    defer observed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 333), observed.run_id);
}

test "same-run bundle uses exact absolute paths in a real token-free child" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "artifact.dmg", .data = "asset" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bundle.json", .data = "signed bundle fixture" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response.json", .data = valid_json });
    const script =
        \\#!/bin/sh
        \\test "$1" = attestation || exit 31
        \\test "$2" = verify || exit 32
        \\test -f "$3" || exit 33
        \\test "$4" = --bundle || exit 34
        \\test -f "$5" || exit 35
        \\test "$6" = --repo || exit 36
        \\test "$7" = ohah/maru || exit 37
        \\test "$GH_PROMPT_DISABLED" = 1 || exit 38
        \\test -z "${GH_TOKEN+x}" || exit 39
        \\root=$(/usr/bin/dirname "$0")
        \\/bin/cat "$root/response.json"
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gh", .data = script });
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    var script_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const script_path = try std.fmt.bufPrintZ(&script_storage, "{s}/gh", .{root[0..root_len]});
    if (c.chmod(script_path.ptr, 0o755) != 0) return error.FixtureFailed;
    var artifact_storage: [std.fs.max_path_bytes]u8 = undefined;
    const artifact_path = try std.fmt.bufPrint(&artifact_storage, "{s}/artifact.dmg", .{root[0..root_len]});
    var bundle_storage: [std.fs.max_path_bytes]u8 = undefined;
    const bundle_path = try std.fmt.bufPrint(&bundle_storage, "{s}/bundle.json", .{root[0..root_len]});
    var output: [attestation.max_response_bytes]u8 = undefined;
    var observed = try attestation.verifyBundle(
        std.testing.io,
        std.testing.allocator,
        script_path,
        artifact_path,
        bundle_path,
        expected(),
        &output,
        std.time.ns_per_s,
    );
    defer observed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(subject_name, observed.subject_name);
}

test "artifact attestation binds exact verified certificate and SLSA subject" {
    var observed = try attestation.parseAndBind(std.testing.allocator, valid_json, expected());
    defer observed.deinit(std.testing.allocator);
    try std.testing.expect(observed.verified);
    try std.testing.expectEqual(@as(u64, 333), observed.run_id);
    try std.testing.expectEqual(@as(u64, 2), observed.run_attempt);
    try std.testing.expectEqualStrings(subject_name, observed.subject_name);
    try std.testing.expectEqualStrings(subject_sha, observed.subject_sha256);
}

fn expectMutation(old: []const u8, replacement: []const u8) !void {
    const mutated = try std.mem.replaceOwned(u8, std.testing.allocator, valid_json, old, replacement);
    defer std.testing.allocator.free(mutated);
    try std.testing.expectError(error.AttestationMismatch, attestation.parseAndBind(
        std.testing.allocator,
        mutated,
        expected(),
    ));
}

test "artifact attestation rejects every certificate authority drift" {
    const mutations = [_]struct { old: []const u8, new: []const u8 }{
        .{ .old = "token.actions.githubusercontent.com", .new = "issuer.example.com" },
        .{ .old = "githubWorkflowTrigger\":\"push", .new = "githubWorkflowTrigger\":\"workflow_dispatch" },
        .{ .old = "githubWorkflowRepository\":\"ohah/maru", .new = "githubWorkflowRepository\":\"fork/maru" },
        .{ .old = "runnerEnvironment\":\"github-hosted", .new = "runnerEnvironment\":\"self-hosted" },
        .{ .old = "sourceRepositoryIdentifier\":\"12345", .new = "sourceRepositoryIdentifier\":\"54321" },
        .{ .old = "runs/333/attempts/2", .new = "runs/333/attempts/3" },
        .{ .old = "sourceRepositoryVisibilityAtSigning\":\"public", .new = "sourceRepositoryVisibilityAtSigning\":\"private" },
    };
    for (mutations) |mutation| try expectMutation(mutation.old, mutation.new);
}

test "artifact attestation rejects statement and subject substitution" {
    try expectMutation(subject_name, "Maru-9.9.9-universal.dmg");
    try expectMutation(subject_sha, "0000000000000000000000000000000000000000000000000000000000000000");
    try expectMutation("https://slsa.dev/provenance/v1", "https://example.com/predicate");
    try expectMutation("actions/runner/github-hosted", "actions/runner/self-hosted");
    try expectMutation("gitCommit\":\"" ++ source_sha, "gitCommit\":\"ffffffffffffffffffffffffffffffffffffffff");
}

test "artifact attestation rejects result cardinality malformed JSON and caps" {
    try std.testing.expectError(error.AttestationMismatch, attestation.parseAndBind(std.testing.allocator, "[]", expected()));
    const doubled = try std.fmt.allocPrint(std.testing.allocator, "[{s},{s}]", .{ valid_json[1 .. valid_json.len - 1], valid_json[1 .. valid_json.len - 1] });
    defer std.testing.allocator.free(doubled);
    try std.testing.expectError(error.AttestationMismatch, attestation.parseAndBind(std.testing.allocator, doubled, expected()));
    try std.testing.expectError(error.InvalidJson, attestation.parseAndBind(std.testing.allocator, "{}{}", expected()));
    var oversized: [attestation.max_response_bytes + 1]u8 = @splat(' ');
    try std.testing.expectError(error.ResponseTooLarge, attestation.parseAndBind(std.testing.allocator, &oversized, expected()));
}

test "artifact attestation execution uses only clean token environment and supplied capture" {
    const Fake = struct {
        pub fn capture(_: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) ![]const u8 {
            try std.testing.expectEqualStrings("/opt/trusted/gh", executable);
            try std.testing.expect(args.len > 0 and budget_ns > 0);
            try std.testing.expectEqual(@as(usize, 2), environment.len);
            try std.testing.expectEqualStrings("GH_TOKEN=secret-token", environment[0]);
            try std.testing.expectEqualStrings("GH_PROMPT_DISABLED=1", environment[1]);
            @memcpy(output[0..valid_json.len], valid_json);
            return output[0..valid_json.len];
        }
    };
    var fake = Fake{};
    var output: [attestation.max_response_bytes]u8 = undefined;
    var observed = try attestation.verifyWith(&fake, std.testing.allocator, "/opt/trusted/gh", "secret-token", "/tmp/Maru.dmg", expected(), &output, std.time.ns_per_s);
    defer observed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 333), observed.run_id);
}

test "held-directory artifact verification uses the exact directory vnode in a real child" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = subject_name, .data = "asset" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "response.json", .data = valid_json });
    const script =
        \\#!/bin/sh
        \\test "$1" = attestation || exit 31
        \\test "$2" = verify || exit 32
        \\test "$3" = ./Maru-1.2.3-universal.dmg || exit 33
        \\test -f "$3" || exit 34
        \\cat ./response.json
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gh", .data = script });
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    var script_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const script_path = try std.fmt.bufPrintZ(&script_storage, "{s}/gh", .{root[0..root_len]});
    if (c.chmod(script_path.ptr, 0o755) != 0) return error.FixtureFailed;
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root_path = try std.fmt.bufPrintZ(&root_storage, "{s}", .{root[0..root_len]});
    const directory_fd = c.open(root_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true }, @as(c.mode_t, 0));
    if (directory_fd < 0) return error.FixtureFailed;
    defer _ = c.close(directory_fd);
    var executor = attestation.BoundedExecutor{ .io = std.testing.io };
    var output: [attestation.max_response_bytes]u8 = undefined;
    var observed = try attestation.verifyDirectoryWith(&executor, std.testing.allocator, script_path, "secret-token", directory_fd, "./" ++ subject_name, expected(), &output, std.time.ns_per_s);
    defer observed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(subject_name, observed.subject_name);
}

test "artifact attestation rejects token budget and foreign capture" {
    const Foreign = struct {
        pub fn capture(_: *@This(), _: []const u8, _: []const []const u8, _: []const []const u8, _: []u8, _: i128) ![]const u8 {
            return valid_json;
        }
    };
    var foreign = Foreign{};
    var output: [attestation.max_response_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidCapture, attestation.verifyWith(&foreign, std.testing.allocator, "/opt/trusted/gh", "secret-token", "/tmp/Maru.dmg", expected(), &output, std.time.ns_per_s));
    try std.testing.expectError(error.InvalidToken, attestation.verifyWith(&foreign, std.testing.allocator, "/opt/trusted/gh", "bad\ntoken", "/tmp/Maru.dmg", expected(), &output, std.time.ns_per_s));
    try std.testing.expectError(error.InvalidBudget, attestation.verifyWith(&foreign, std.testing.allocator, "/opt/trusted/gh", "secret-token", "/tmp/Maru.dmg", expected(), &output, 0));
}

test "artifact attestation product execution fails closed on child failure" {
    var output: [attestation.max_response_bytes]u8 = undefined;
    try std.testing.expectError(error.ChildFailed, attestation.verify(std.testing.io, std.testing.allocator, "/usr/bin/false", "secret-token", "/tmp/Maru.dmg", expected(), &output, std.time.ns_per_s));
}

test "artifact attestation successful parse unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseForAllocationTest, .{});
}

fn parseForAllocationTest(allocator: std.mem.Allocator) !void {
    var observed = try attestation.parseAndBind(allocator, valid_json, expected());
    observed.deinit(allocator);
}
