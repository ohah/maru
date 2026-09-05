const std = @import("std");
const product = @import("release_adapter_candidate_prerequisite_product");

fn inputs(cli: *const product.PinnedCli) product.Inputs {
    return .{
        .context = .{
            .repository = .{ .owner = "ohah", .name = "maru", .id = 1 },
            .tag = "v1.2.3",
            .source_commit = "0123456789abcdef0123456789abcdef01234567",
            .build = .{
                .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
                .run_id = 2,
                .run_attempt = 1,
            },
            .protected_tag = true,
        },
        .test_uuid = "01234567-89ab-4def-8123-456789abcdef",
        .paths = .{
            .dmg = "/tmp/Maru-1.2.3-universal.dmg",
            .frozen_executable = "/tmp/maru-session-host-1.2.3",
            .dmg_work = "/private/tmp/maru-dmg-work-1.2.3",
        },
        .bundles = .{
            .dmg_bundle = "/tmp/attest/candidate-dmg.bundle.json",
            .frozen_bundle = "/tmp/attest/candidate-frozen.bundle.json",
        },
        .cli = .{ .path = "/usr/bin/gh", .pinned = cli },
    };
}

test "candidate prerequisite product exposes one closed production owner" {
    std.testing.refAllDecls(product);
    var execution: product.Execution = .{};
    try std.testing.expect(execution.isPristineForComposition());
    try std.testing.expect(!execution.ownsCompletePrerequisites());
    try std.testing.expect(!execution.needsAudit());
    try std.testing.expectError(error.InvalidOwner, execution.cleanup());
    try std.testing.expectError(error.InvalidOwner, execution.retryCleanup());
}

test "production source has exactly one callsite for every prerequisite leaf" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_prerequisite_product.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);
    inline for (.{
        "candidate_attestation.composeBundlesUntil(",
        "draft_creation.create(",
        "candidate_files.observe(",
        "candidate_product.observe(",
        "source_tree.observe(",
        "candidate_identity.compose(",
        "compatibility_mod.composeUntil(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, needle));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "candidate_attestation.composeUntil("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "filePaths(i.paths), i.bundles,"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "deadline_mod.start("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "pub fn runBorrowingDeadline("));
}

test "borrowed prerequisite rejects an unstarted deadline without publishing borrows" {
    var cli: product.PinnedCli = undefined;
    var execution: product.Execution = .{};
    var deadline: product.Deadline = .{};
    var scratch: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidOwner, product.runBorrowingDeadline(
        std.testing.io,
        std.testing.allocator,
        inputs(&cli),
        "token",
        &scratch,
        &deadline,
        &execution,
    ));
    try std.testing.expect(execution.isPristineForComposition());
    try std.testing.expectEqual(product.Deadline{}, deadline);
}

test "borrowed prerequisite authority failure preserves a live caller deadline" {
    var cli: product.PinnedCli = std.mem.zeroes(product.PinnedCli);
    var execution: product.Execution = .{};
    var deadline: product.Deadline = .{ .started_ns = 0, .expires_ns = std.math.maxInt(i128) };
    deadline.owner = &deadline;
    var scratch: [4096]u8 = undefined;
    const failed = failed: {
        product.runBorrowingDeadline(std.testing.io, std.testing.allocator, inputs(&cli), "token", &scratch, &deadline, &execution) catch break :failed true;
        break :failed false;
    };
    try std.testing.expect(failed);
    try std.testing.expect(deadline.owner == &deadline);
    try std.testing.expectEqual(@as(i128, 0), deadline.started_ns);
    try std.testing.expectEqual(std.math.maxInt(i128), deadline.expires_ns);
    try std.testing.expect(execution.isPristineForComposition());
}

test "pre-owned and copied execution are rejected before production work" {
    var cli: product.PinnedCli = undefined;
    var execution: product.Execution = .{};
    execution.owner = &execution;
    var copied = execution;
    var scratch: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, inputs(&cli), "token", &scratch, std.time.ns_per_s, &execution));
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, inputs(&cli), "token", &scratch, std.time.ns_per_s, &copied));
}

test "dirty nested state is rejected without erasing it" {
    var cli: product.PinnedCli = undefined;
    var execution: product.Execution = .{};
    execution.draft.id = 123456;
    var scratch: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, inputs(&cli), "token", &scratch, std.time.ns_per_s, &execution));
    try std.testing.expectEqual(@as(u64, 123456), execution.draft.id);
}

test "ownerless dirty nested backing is rejected without erasing it" {
    var cli: product.PinnedCli = undefined;
    var execution: product.Execution = .{};
    execution.attestation.tag[0] = 'x';
    execution.identity.dmg_sha256[63] = 'f';
    var scratch: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, inputs(&cli), "token", &scratch, std.time.ns_per_s, &execution));
    try std.testing.expectEqual(@as(u8, 'x'), execution.attestation.tag[0]);
    try std.testing.expectEqual(@as(u8, 'f'), execution.identity.dmg_sha256[63]);
}

test "execution-backed token and scratch aliases fail before authority access" {
    var cli: product.PinnedCli = undefined;
    var execution: product.Execution = .{};
    const bytes = std.mem.asBytes(&execution);
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, inputs(&cli), bytes[0..5], bytes[64..128], std.time.ns_per_s, &execution));
    try std.testing.expect(execution.isPristineForComposition());
}

test "token and scratch overlap is rejected before authority access" {
    var cli: product.PinnedCli = undefined;
    var execution: product.Execution = .{};
    var scratch: [4096]u8 = undefined;
    @memcpy(scratch[0..5], "token");
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, inputs(&cli), scratch[0..5], &scratch, std.time.ns_per_s, &execution));
    try std.testing.expect(execution.isPristineForComposition());
}

test "non-positive budget is rejected without publishing borrows" {
    var cli: product.PinnedCli = undefined;
    var execution: product.Execution = .{};
    var scratch: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidBudget, product.run(std.testing.io, std.testing.allocator, inputs(&cli), "token", &scratch, 0, &execution));
    try std.testing.expect(execution.isPristineForComposition());
}

test "noncanonical tag and UUID fail before CLI or release access" {
    var cli: product.PinnedCli = undefined;
    var scratch: [4096]u8 = undefined;
    var execution: product.Execution = .{};
    var value = inputs(&cli);
    value.context.tag = "v01.2.3";
    try std.testing.expectError(error.AuthorityMismatch, product.run(std.testing.io, std.testing.allocator, value, "token", &scratch, std.time.ns_per_s, &execution));
    value = inputs(&cli);
    value.test_uuid = "01234567-89ab-0def-0123-456789abcdef";
    try std.testing.expectError(error.AuthorityMismatch, product.run(std.testing.io, std.testing.allocator, value, "token", &scratch, std.time.ns_per_s, &execution));
    try std.testing.expect(execution.isPristineForComposition());
}

test "bundle paths are canonical distinct inputs before deadline or authority access" {
    var cli: product.PinnedCli = undefined;
    var scratch: [4096]u8 = undefined;
    var execution: product.Execution = .{};
    var value = inputs(&cli);
    value.bundles.dmg_bundle = "/tmp/attest/../candidate-dmg.bundle.json";
    try std.testing.expectError(error.InvalidPath, product.run(std.testing.io, std.testing.allocator, value, "token", &scratch, std.time.ns_per_s, &execution));
    try std.testing.expect(execution.isPristineForComposition());

    value = inputs(&cli);
    var duplicate_storage: [128:0]u8 = @splat(0);
    value.bundles.dmg_bundle = try std.fmt.bufPrintZ(&duplicate_storage, "{s}", .{value.paths.dmg});
    try std.testing.expectError(error.InvalidPath, product.run(std.testing.io, std.testing.allocator, value, "token", &scratch, std.time.ns_per_s, &execution));
    try std.testing.expect(execution.isPristineForComposition());
}
