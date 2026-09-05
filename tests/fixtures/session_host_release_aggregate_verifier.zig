//! Test-owned executable that emulates only `gh attestation verify --bundle` for process E2E.

const std = @import("std");
extern "c" fn usleep(usec: c_uint) c_int;

const fixture_subject = "Maru-1.2.3-universal.dmg";
const fixture_digest = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
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
    \\"verifiedTimestamps":[{"type":"TimestampAuthority","uri":"timestamp.githubapp.com","timestamp":"2026-09-05T00:00:00Z"}]}}]
;

pub fn main(init: std.process.Init) !void {
    if (std.c.getenv("GH_TOKEN") != null or std.c.getenv("GITHUB_TOKEN") != null) return error.TokenLeaked;
    var environment_count: usize = 0;
    while (std.c.environ[environment_count]) |entry| : (environment_count += 1) {
        if (!std.mem.eql(u8, std.mem.span(entry), "GH_PROMPT_DISABLED=1")) return error.ForeignEnvironment;
    }
    if (environment_count != 1) return error.ForeignEnvironment;
    var fd: c_int = 3;
    while (fd < 1024) : (fd += 1) if (std.c.fcntl(fd, std.c.F.GETFD, @as(c_int, 0)) >= 0)
        return error.InheritedDescriptor;
    const prompt = std.c.getenv("GH_PROMPT_DISABLED") orelse return error.MissingPromptDisable;
    if (!std.mem.eql(u8, std.mem.span(prompt), "1")) return error.InvalidPromptDisable;

    var iterator = try init.minimal.args.iterateAllocator(init.gpa);
    defer iterator.deinit();
    _ = iterator.next();
    const command = iterator.next() orelse return error.MissingArgument;
    const verb = iterator.next() orelse return error.MissingArgument;
    const artifact = iterator.next() orelse return error.MissingArgument;
    const bundle_option = iterator.next() orelse return error.MissingArgument;
    const bundle = iterator.next() orelse return error.MissingArgument;
    if (!std.mem.eql(u8, command, "attestation") or !std.mem.eql(u8, verb, "verify") or
        !std.mem.eql(u8, bundle_option, "--bundle")) return error.InvalidArguments;
    const tail = [_][]const u8{
        "--repo",
        "ohah/maru",
        "--signer-workflow",
        "ohah/maru/.github/workflows/release.yml",
        "--signer-digest",
        "0123456789abcdef0123456789abcdef01234567",
        "--source-digest",
        "0123456789abcdef0123456789abcdef01234567",
        "--source-ref",
        "refs/tags/v1.2.3",
        "--deny-self-hosted-runners",
        "--predicate-type",
        "https://slsa.dev/provenance/v1",
        "--format",
        "json",
    };
    for (tail) |expected| {
        const actual = iterator.next() orelse return error.MissingArgument;
        if (!std.mem.eql(u8, actual, expected)) return error.InvalidArguments;
    }
    if (iterator.next() != null) return error.TooManyArguments;
    const artifact_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, artifact, init.gpa, .limited(16 * 1024 * 1024));
    defer init.gpa.free(artifact_bytes);
    const bundle_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, bundle, init.gpa, .limited(16 * 1024 * 1024));
    defer init.gpa.free(bundle_bytes);
    if (bundle_bytes.len == 0) return error.EmptyBundle;
    if (std.mem.eql(u8, bundle_bytes, "FAIL\n")) return error.InjectedFailure;
    if (std.mem.eql(u8, bundle_bytes, "HANG\n")) _ = usleep(3_000_000);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(artifact_bytes, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const subject = std.fs.path.basename(artifact);
    const aggregate_dir = std.fs.path.dirname(bundle) orelse return error.InvalidArguments;
    const durable_dir = std.fs.path.dirname(aggregate_dir) orelse return error.InvalidArguments;
    var order_path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const order_path = try std.fmt.bufPrintZ(&order_path_storage, "{s}/verify-order", .{durable_dir});
    const order_fd = std.c.open(order_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (order_fd < 0) return error.OrderLogFailed;
    defer _ = std.c.close(order_fd);
    var order_line_storage: [128]u8 = undefined;
    const order_line = try std.fmt.bufPrint(&order_line_storage, "{s}\n", .{subject});
    if (std.c.write(order_fd, order_line.ptr, order_line.len) != order_line.len) return error.OrderLogFailed;
    if (std.mem.eql(u8, bundle_bytes, "MUTATE\n")) {
        var artifact_path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
        const artifact_path = try std.fmt.bufPrintZ(&artifact_path_storage, "{s}", .{artifact});
        const artifact_fd = std.c.open(artifact_path.ptr, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true });
        if (artifact_fd < 0) return error.ArtifactMutationFailed;
        defer _ = std.c.close(artifact_fd);
        if (std.c.write(artifact_fd, "x", 1) != 1) return error.ArtifactMutationFailed;
    }
    const named = try std.mem.replaceOwned(u8, init.gpa, valid_json, fixture_subject, subject);
    defer init.gpa.free(named);
    const rendered = try std.mem.replaceOwned(u8, init.gpa, named, fixture_digest, &digest_hex);
    defer init.gpa.free(rendered);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(rendered);
    try stdout.flush();
}
