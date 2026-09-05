const std = @import("std");
const product = @import("release_adapter_candidate_release_product");

const commit = "0123456789abcdef0123456789abcdef01234567";

fn inputs(cli: *const product.PinnedCli, toolchain: *const product.ZigToolchainAuthority) product.Inputs {
    return .{
        .prerequisite = .{
            .context = .{
                .repository = .{ .owner = "ohah", .name = "maru", .id = 1 },
                .tag = "v1.2.3",
                .source_commit = commit,
                .build = .{
                    .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
                    .run_id = 2,
                    .run_attempt = 1,
                },
                .protected_tag = true,
            },
            .test_uuid = "01234567-89ab-4def-8123-456789abcdef",
            .paths = .{
                .dmg = "/tmp/candidate/Maru-1.2.3-universal.dmg",
                .frozen_executable = "/tmp/candidate/maru-session-host-1.2.3",
                .dmg_work = "/private/tmp/maru-dmg-work-1.2.3",
            },
            .bundles = .{
                .dmg_bundle = "/tmp/attest/candidate-dmg.bundle.json",
                .frozen_bundle = "/tmp/attest/candidate-frozen.bundle.json",
            },
            .cli = .{ .path = "/usr/bin/gh", .pinned = cli },
        },
        .baseline = .{
            .workspace_root = "/tmp/maru-baseline-1.2.3",
            .app_paths = .{
                .main_executable = "/tmp/candidate/Maru.app/Contents/MacOS/maru-macos-app",
                .cli_executable = "/tmp/candidate/Maru.app/Contents/MacOS/maru",
            },
            .toolchain = toolchain,
            .source_directory_fd = 0,
        },
        .publication = .{
            .manifest = "/tmp/release/Maru-1.2.3-session-host-release.json",
        },
    };
}

test "candidate release product exposes one closed production owner" {
    std.testing.refAllDecls(product);
    var execution: product.Execution = .{};
    try std.testing.expect(execution.isPristineForComposition());
    try std.testing.expect(!execution.ownsCompleteRelease());
    try std.testing.expect(!execution.needsAudit());
    try std.testing.expectError(error.InvalidOwner, execution.cleanup());
    try std.testing.expectError(error.InvalidOwner, execution.retryCleanup());
}

test "production source starts one deadline and calls each borrowed product once" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/release_adapter_candidate_release_product.zig",
        std.testing.allocator,
        .limited(256 * 1024),
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "deadline_mod.start("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "prerequisite.runBorrowingDeadline("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "baseline.runBorrowingDeadline("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "publication.runBorrowingDeadline("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "publication.revalidateSuccessfulOutputs("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "prerequisite.run("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "baseline.run("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "publication.run("));
}

test "non-positive budget is rejected without publishing borrows" {
    var cli: product.PinnedCli = undefined;
    var toolchain: product.ZigToolchainAuthority = undefined;
    var execution: product.Execution = .{};
    var scratch: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidBudget, product.run(std.testing.io, std.testing.allocator, inputs(&cli, &toolchain), "token", &scratch, 0, &execution));
    try std.testing.expect(execution.isPristineForComposition());
}

test "pre-owned and copied execution are rejected before production work" {
    var cli: product.PinnedCli = undefined;
    var toolchain: product.ZigToolchainAuthority = undefined;
    var original: product.Execution = .{};
    original.owner = &original;
    var copied = original;
    var scratch: [4096]u8 = undefined;
    const value = inputs(&cli, &toolchain);
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, value, "token", &scratch, std.time.ns_per_s, &original));
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, value, "token", &scratch, std.time.ns_per_s, &copied));
}

test "dirty nested execution is rejected without erasing it" {
    var cli: product.PinnedCli = undefined;
    var toolchain: product.ZigToolchainAuthority = undefined;
    var execution: product.Execution = .{};
    execution.baseline.workspace.root.parent_fd = 123456;
    var scratch: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, inputs(&cli, &toolchain), "token", &scratch, std.time.ns_per_s, &execution));
    try std.testing.expectEqual(@as(std.c.fd_t, 123456), execution.baseline.workspace.root.parent_fd);
}

test "invalid source directory fd fails before deadline or authority access" {
    var cli: product.PinnedCli = undefined;
    var toolchain: product.ZigToolchainAuthority = undefined;
    var execution: product.Execution = .{};
    var scratch: [4096]u8 = undefined;
    var value = inputs(&cli, &toolchain);
    value.baseline.source_directory_fd = -1;
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, value, "token", &scratch, std.time.ns_per_s, &execution));
    try std.testing.expect(execution.isPristineForComposition());
}

test "execution-backed token and scratch aliases fail before authority access" {
    var cli: product.PinnedCli = undefined;
    var toolchain: product.ZigToolchainAuthority = undefined;
    var execution: product.Execution = .{};
    const bytes = std.mem.asBytes(&execution);
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, inputs(&cli, &toolchain), bytes[0..5], bytes[64..256], std.time.ns_per_s, &execution));
    try std.testing.expect(execution.isPristineForComposition());
}

test "publication path alias is rejected before authority access" {
    var cli: product.PinnedCli = undefined;
    var toolchain: product.ZigToolchainAuthority = undefined;
    var execution: product.Execution = .{};
    var scratch: [4096]u8 = undefined;
    var value = inputs(&cli, &toolchain);
    var manifest_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    value.publication.manifest = try std.fmt.bufPrintZ(&manifest_storage, "{s}", .{value.prerequisite.paths.dmg});
    try std.testing.expectError(error.InvalidPath, product.run(std.testing.io, std.testing.allocator, value, "token", &scratch, std.time.ns_per_s, &execution));
    try std.testing.expect(execution.isPristineForComposition());
}
