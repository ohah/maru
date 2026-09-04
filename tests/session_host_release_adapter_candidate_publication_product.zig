const std = @import("std");
const product = @import("release_adapter_candidate_publication_product");

fn inputs(
    files: *const product.CandidateFiles,
    candidate: *const product.CandidateProduct,
    identity: *const product.CandidateEvidenceIdentity,
    source: *const product.SourceTreeAuthority,
    compatibility: *const product.CandidateCompatibility,
    evidence: *const product.PinnedReleaseFile,
    draft: *const product.DraftAuthority,
    attestation: *const product.CandidateAttestation,
    cli: *const product.PinnedCli,
) product.Inputs {
    return .{
        .context = .{ .repository = .{ .owner = "ohah", .name = "maru", .id = 1 }, .tag = "v1.2.3", .source_commit = "0123456789abcdef0123456789abcdef01234567", .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 2, .run_attempt = 1 }, .protected_tag = true },
        .identity = identity,
        .files = files,
        .product = candidate,
        .product_paths = .{ .dmg = "/tmp/Maru-1.2.3-universal.dmg", .frozen_executable = "/tmp/maru-session-host-1.2.3", .dmg_work = "/tmp/dmg-work" },
        .source = source,
        .compatibility = compatibility,
        .evidence = evidence,
        .draft = draft,
        .candidate_attestation = attestation,
        .cli = .{ .path = "/usr/bin/gh", .pinned = cli },
        .paths = .{ .dmg = "/tmp/Maru-1.2.3-universal.dmg", .frozen_executable = "/tmp/maru-session-host-1.2.3", .evidence = "/tmp/evidence.json", .manifest = "/tmp/Maru-1.2.3-session-host-release.json" },
    };
}

test "candidate publication product exposes one closed production owner" {
    std.testing.refAllDecls(product);
    var execution: product.Execution = .{};
    try std.testing.expect(execution.isPristineForComposition());
    try std.testing.expectError(error.InvalidOwner, execution.cleanup());
    try std.testing.expectError(error.InvalidOwner, execution.retryCleanup());
}

test "production source has exactly one callsite for every publication leaf" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_publication_product.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);
    inline for (.{ "candidate_manifest.author(", "candidate_authored.composeUntil(", "draft_attachment.attachUntil(", "draft_redownload.validateUntil(", "draft_publication.publishUntil(", "post_publish.verifyUntil(" }) |needle|
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, needle));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "deadline_mod.start("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "pub fn runBorrowingDeadline("));
}

test "borrowed publication rejects an unstarted deadline without publishing borrows" {
    var files: product.CandidateFiles = .{};
    var candidate: product.CandidateProduct = .{};
    var identity: product.CandidateEvidenceIdentity = .{};
    var source: product.SourceTreeAuthority = .{};
    var compatibility: product.CandidateCompatibility = .{};
    var evidence: product.PinnedReleaseFile = .{};
    var draft: product.DraftAuthority = .{};
    var attestation: product.CandidateAttestation = .{};
    var cli: product.PinnedCli = undefined;
    var execution: product.Execution = .{};
    var deadline: product.Deadline = .{};
    var response: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidOwner, product.runBorrowingDeadline(
        std.testing.io,
        std.testing.allocator,
        inputs(&files, &candidate, &identity, &source, &compatibility, &evidence, &draft, &attestation, &cli),
        "token",
        &response,
        &deadline,
        &execution,
    ));
    try std.testing.expect(execution.isPristineForComposition());
    try std.testing.expectEqual(product.Deadline{}, deadline);
}

test "pre-owned and copied execution are rejected before production work" {
    var files: product.CandidateFiles = .{};
    var candidate: product.CandidateProduct = .{};
    var identity: product.CandidateEvidenceIdentity = .{};
    var source: product.SourceTreeAuthority = .{};
    var compatibility: product.CandidateCompatibility = .{};
    var evidence: product.PinnedReleaseFile = .{};
    var draft: product.DraftAuthority = .{};
    var attestation: product.CandidateAttestation = .{};
    var cli: product.PinnedCli = undefined;
    const value = inputs(&files, &candidate, &identity, &source, &compatibility, &evidence, &draft, &attestation, &cli);
    var original: product.Execution = .{};
    original.owner = &original;
    var copied = original;
    var response: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, value, "token", &response, std.time.ns_per_s, &original));
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, value, "token", &response, std.time.ns_per_s, &copied));
}

test "dirty nested publication state is rejected without erasing it" {
    var files: product.CandidateFiles = .{};
    var candidate: product.CandidateProduct = .{};
    var identity: product.CandidateEvidenceIdentity = .{};
    var source: product.SourceTreeAuthority = .{};
    var compatibility: product.CandidateCompatibility = .{};
    var evidence: product.PinnedReleaseFile = .{};
    var draft: product.DraftAuthority = .{};
    var attestation: product.CandidateAttestation = .{};
    var cli: product.PinnedCli = undefined;
    var execution: product.Execution = .{};
    execution.manifest.fd = 123456;
    var response: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, inputs(&files, &candidate, &identity, &source, &compatibility, &evidence, &draft, &attestation, &cli), "token", &response, std.time.ns_per_s, &execution));
    try std.testing.expectEqual(@as(std.c.fd_t, 123456), execution.manifest.fd);
}

test "execution-backed token and response aliases fail before authority access" {
    var files: product.CandidateFiles = .{};
    var candidate: product.CandidateProduct = .{};
    var identity: product.CandidateEvidenceIdentity = .{};
    var source: product.SourceTreeAuthority = .{};
    var compatibility: product.CandidateCompatibility = .{};
    var evidence: product.PinnedReleaseFile = .{};
    var draft: product.DraftAuthority = .{};
    var attestation: product.CandidateAttestation = .{};
    var cli: product.PinnedCli = undefined;
    var execution: product.Execution = .{};
    const bytes = std.mem.asBytes(&execution);
    const value = inputs(&files, &candidate, &identity, &source, &compatibility, &evidence, &draft, &attestation, &cli);
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, value, bytes[0..5], bytes[64..128], std.time.ns_per_s, &execution));
    try std.testing.expect(execution.isPristineForComposition());
}
