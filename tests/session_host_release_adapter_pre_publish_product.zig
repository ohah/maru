//! Production pre-publish ownership is exercised before any network or Apple child is required.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const bootstrap_mod = @import("release_adapter_executable_bootstrap");
const apple_transport = @import("release_adapter_apple_transport");
const workspace = @import("release_adapter_pre_publish_workspace");
const product = @import("release_adapter_pre_publish_product");

const commit = "0123456789abcdef0123456789abcdef01234567";

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..len], leaf });
}

fn context() context_mod.Context {
    return .{
        .repository = .{ .owner = "ohah", .name = "maru", .id = 1 },
        .tag = "v1.2.3",
        .source_commit = commit,
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 2, .run_attempt = 1 },
        .protected_tag = true,
    };
}

test "invalid bootstrap and copied execution reach no phase owner" {
    var bootstrap: bootstrap_mod.Bootstrap = .{};
    var storage: apple_transport.Storage = undefined;
    var execution: product.Execution = .{};
    try std.testing.expectError(error.InvalidBootstrap, product.run(std.testing.io, std.testing.allocator, &bootstrap, "token", 100, .{}, &storage, &execution));
    try std.testing.expect(execution.owner == null);

    var original: product.Execution = .{};
    original.owner = &original;
    var copied = original;
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, &bootstrap, "token", 100, .{}, &storage, &copied));

    bootstrap.command = .{ .publish_candidate = candidateCommand() };
    bootstrap.context = context();
    bootstrap.owner = &bootstrap;
    try std.testing.expectError(error.InvalidCommand, product.run(std.testing.io, std.testing.allocator, &bootstrap, "token", 100, .{}, &storage, &execution));
    try std.testing.expect(execution.owner == null);
}

fn candidateCommand() bootstrap_mod.PublishCandidate {
    return .{ .repo = "ohah/maru", .tag = "v1.2.3", .test_uuid = "123e4567-e89b-42d3-a456-426614174000", .dmg = "/tmp/dmg", .frozen_executable = "/tmp/exe", .dmg_work = "/tmp/dmg-work", .baseline_workspace = "/tmp/baseline", .app_main_executable = "/tmp/app-main", .app_cli_executable = "/tmp/app-cli", .manifest = "/tmp/Maru-1.2.3-session-host-release.json", .source_root = "/tmp/source", .zig = "/tmp/zig", .zig_size = 123, .zig_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" };
}

test "local candidate failure removes deadline and workspace before return" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var work_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const work = try absolute(&tmp, "phase", &work_storage);
    var bootstrap: bootstrap_mod.Bootstrap = .{};
    bootstrap.command = .{ .pre_publish = .{
        .repo = "ohah/maru",
        .tag = "v1.2.3",
        .manifest = "/tmp/Maru-1.2.3-session-host-release.json",
        .evidence = "/tmp/evidence.json",
        .dmg = "/tmp/Maru.dmg",
        .frozen_executable = "/tmp/maru",
        .work_dir = work,
        .summary_out = "/tmp/summary.json",
    } };
    bootstrap.context = context();
    bootstrap.owner = &bootstrap;
    var apple_storage: apple_transport.Storage = undefined;
    var execution: product.Execution = .{};
    try std.testing.expectError(error.InvalidToken, product.run(std.testing.io, std.testing.allocator, &bootstrap, "bad\ntoken", std.time.ns_per_s, .{}, &apple_storage, &execution));
    try std.testing.expect(execution.owner == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, work, .{}));
    const execution_bytes = std.mem.asBytes(&execution);
    try std.testing.expectError(error.InvalidBuffer, product.run(std.testing.io, std.testing.allocator, &bootstrap, "token", std.time.ns_per_s, .{ .github_response = execution_bytes[0..16] }, &apple_storage, &execution));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, work, .{}));
    const overlapping_apple: *apple_transport.Storage = @ptrCast(@alignCast(&execution));
    try std.testing.expectError(error.InvalidBuffer, product.run(std.testing.io, std.testing.allocator, &bootstrap, "token", std.time.ns_per_s, .{}, overlapping_apple, &execution));
    const aliased_token = execution.workspace.path_storage[0..5];
    @memcpy(aliased_token, "token");
    try std.testing.expectError(error.InvalidBuffer, product.run(std.testing.io, std.testing.allocator, &bootstrap, aliased_token, std.time.ns_per_s, .{}, &apple_storage, &execution));
    try std.testing.expectError(error.InvalidManifestInput, product.run(std.testing.io, std.testing.allocator, &bootstrap, "token", std.time.ns_per_s, .{}, &apple_storage, &execution));
    try std.testing.expect(execution.owner == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, work, .{}));
}

test "cleanup failure preserves caller-owned execution for retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var work_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var child_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const work = try absolute(&tmp, "phase", &work_storage);
    var execution: product.Execution = .{};
    execution.owner = &execution;
    execution.token = "must-not-survive";
    try workspace.prepare(&execution.workspace, work);
    const child = try execution.workspace.childPath(.current_manifest, &child_storage);
    try std.Io.Dir.createDirAbsolute(std.testing.io, child, .default_dir);
    try std.testing.expectError(error.CleanupFailed, execution.retryCleanup());
    try std.testing.expect(execution.owner == &execution);
    try std.testing.expectEqual(@as(usize, 0), execution.token.len);
    try std.testing.expect(execution.bootstrap == null);
    try std.testing.expect(execution.apple_storage == null);
    try std.Io.Dir.deleteDirAbsolute(std.testing.io, child);
    try execution.retryCleanup();
    try std.testing.expect(execution.owner == null);
}

test "final publication validation rejects an expired or foreign deadline" {
    var execution: product.Execution = .{};
    execution.deadline = .{ .started_ns = 1, .expires_ns = 2 };
    execution.deadline.owner = &execution.deadline;
    try std.testing.expectError(error.TimedOut, execution.validatePublication(&execution.deadline));

    var foreign = execution.deadline;
    foreign.owner = &foreign;
    try std.testing.expectError(error.InvalidOwner, execution.validatePublication(&foreign));
}
