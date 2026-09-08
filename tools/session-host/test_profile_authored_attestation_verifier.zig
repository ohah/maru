//! Synthetic, token-free `gh attestation verify --bundle` process for the final-fence E2E.

const std = @import("std");
const c = std.c;

const source_sha = "1111111111111111111111111111111111111111";

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const expected = [_][]const u8{
        "attestation",       "verify",                                  "",                 "--bundle",                       "",                "--repo",   "ohah/maru",
        "--signer-workflow", "ohah/maru/.github/workflows/release.yml", "--signer-digest",  source_sha,                       "--source-digest", source_sha, "--source-ref",
        "refs/tags/v1.2.3",  "--deny-self-hosted-runners",              "--predicate-type", "https://slsa.dev/provenance/v1", "--format",        "json",
    };
    var observed: [expected.len][]const u8 = undefined;
    for (&observed) |*value| value.* = args.next() orelse return error.MissingArgument;
    if (args.next() != null) return error.TooManyArguments;
    for (expected, observed, 0..) |want, got, index| {
        if ((index == 2 or index == 4)) {
            if (!canonicalAbsolute(got)) return error.InvalidPath;
        } else if (!std.mem.eql(u8, want, got)) return error.InvalidArgument;
    }
    if (std.mem.eql(u8, observed[2], observed[4])) return error.InvalidPath;
    if (!std.mem.eql(u8, std.mem.span(c.getenv("GH_PROMPT_DISABLED") orelse return error.InvalidEnvironment), "1"))
        return error.InvalidEnvironment;
    if (c.getenv("GH_TOKEN") != null) return error.AmbientCredential;

    const artifact = try std.Io.Dir.cwd().readFileAlloc(init.io, observed[2], init.gpa, .limited(8 * 1024 * 1024));
    defer init.gpa.free(artifact);
    const bundle = try std.Io.Dir.cwd().readFileAlloc(init.io, observed[4], init.gpa, .limited(8 * 1024 * 1024));
    defer init.gpa.free(bundle);
    if (bundle.len == 0) return error.InvalidBundle;
    var marker_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const marker = try std.fmt.bufPrintZ(&marker_storage, "{s}.verified", .{observed[4]});
    const marker_fd = c.open(marker.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
    if (marker_fd < 0) return error.DuplicateVerification;
    if (c.close(marker_fd) != 0) return error.MarkerCloseFailed;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(artifact, &digest, .{});
    const sha = std.fmt.bytesToHex(digest, .lower);
    const name = std.fs.path.basename(observed[2]);
    if (!validScalar(name)) return error.InvalidPath;

    var buffer: [16 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &file_writer.interface;
    try out.print(
        "[{{\"attestation\":{{}},\"verificationResult\":{{\"signature\":{{\"certificate\":{{" ++
            "\"subjectAlternativeName\":\"https://github.com/ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3\"," ++
            "\"issuer\":\"https://token.actions.githubusercontent.com\",\"githubWorkflowTrigger\":\"push\"," ++
            "\"githubWorkflowSHA\":\"{s}\",\"githubWorkflowRepository\":\"ohah/maru\",\"githubWorkflowRef\":\"refs/tags/v1.2.3\"," ++
            "\"buildSignerURI\":\"https://github.com/ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3\",\"buildSignerDigest\":\"{s}\"," ++
            "\"runnerEnvironment\":\"github-hosted\",\"sourceRepositoryURI\":\"https://github.com/ohah/maru\"," ++
            "\"sourceRepositoryDigest\":\"{s}\",\"sourceRepositoryRef\":\"refs/tags/v1.2.3\",\"sourceRepositoryIdentifier\":\"123\"," ++
            "\"sourceRepositoryOwnerURI\":\"https://github.com/ohah\",\"buildConfigURI\":\"https://github.com/ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3\"," ++
            "\"buildConfigDigest\":\"{s}\",\"buildTrigger\":\"push\",\"runInvocationURI\":\"https://github.com/ohah/maru/actions/runs/789/attempts/2\"," ++
            "\"sourceRepositoryVisibilityAtSigning\":\"public\"}}}},\"statement\":{{\"_type\":\"https://in-toto.io/Statement/v1\"," ++
            "\"subject\":[{{\"name\":\"{s}\",\"digest\":{{\"sha256\":\"{s}\"}}}}],\"predicateType\":\"https://slsa.dev/provenance/v1\"," ++
            "\"predicate\":{{\"buildDefinition\":{{\"buildType\":\"https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1\"," ++
            "\"externalParameters\":{{\"workflow\":{{\"path\":\".github/workflows/release.yml\",\"ref\":\"refs/tags/v1.2.3\",\"repository\":\"https://github.com/ohah/maru\"}}}}," ++
            "\"internalParameters\":{{\"github\":{{\"event_name\":\"push\",\"repository_id\":\"123\"}}}}," ++
            "\"resolvedDependencies\":[{{\"uri\":\"git+https://github.com/ohah/maru@refs/tags/v1.2.3\",\"digest\":{{\"gitCommit\":\"{s}\"}}}}]}}," ++
            "\"runDetails\":{{\"builder\":{{\"id\":\"https://github.com/actions/runner/github-hosted\"}},\"metadata\":{{\"invocationId\":\"https://github.com/ohah/maru/actions/runs/789/attempts/2\"}}}}}}}}," ++
            "\"verifiedTimestamps\":[{{\"type\":\"TimestampAuthority\",\"uri\":\"timestamp.githubapp.com\",\"timestamp\":\"2026-09-09T00:00:00Z\"}}]}}}}]\n",
        .{ source_sha, source_sha, source_sha, source_sha, name, &sha, source_sha },
    );
    try out.flush();
}

fn canonicalAbsolute(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/' or path[path.len - 1] == '/' or !validScalar(path)) return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn validScalar(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f or byte == '\\' or byte == '"') return false;
    return true;
}
