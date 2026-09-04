const std = @import("std");
const product = @import("release_adapter_candidate_baseline_preparation_product");

const commit = "0123456789abcdef0123456789abcdef01234567";

fn context() product.Context {
    return .{
        .repository = .{ .owner = "ohah", .name = "maru", .id = 1 },
        .tag = "v1.2.3",
        .source_commit = commit,
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 2, .run_attempt = 1 },
        .protected_tag = true,
    };
}

fn inputs(
    files: *const product.CandidateFiles,
    candidate: *const product.CandidateProduct,
    identity: *const product.CandidateEvidenceIdentity,
    source: *const product.SourceTreeAuthority,
    toolchain: *const product.ZigToolchainAuthority,
) product.Inputs {
    return .{
        .context = context(),
        .identity = identity,
        .files = files,
        .product = candidate,
        .product_paths = .{ .dmg = "/tmp/Maru.dmg", .frozen_executable = "/tmp/maru", .dmg_work = "/tmp/dmg-work" },
        .source = source,
        .app_paths = .{
            .main_executable = "/tmp/candidate/Maru.app/Contents/MacOS/maru-macos-app",
            .cli_executable = "/tmp/candidate/Maru.app/Contents/MacOS/maru",
        },
        .toolchain = toolchain,
        .source_directory_fd = 0,
    };
}

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..len], leaf });
}

test "invalid candidate cleans the prepared workspace and scrubs every borrow" {
    std.testing.refAllDecls(product);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "baseline", &root_storage);
    var files: product.CandidateFiles = .{};
    var candidate: product.CandidateProduct = .{};
    var identity: product.CandidateEvidenceIdentity = .{};
    var source: product.SourceTreeAuthority = .{};
    var toolchain: product.ZigToolchainAuthority = .{};
    var execution: product.Execution = .{};
    try std.testing.expectError(error.InvalidOwner, product.run(
        std.testing.io,
        std.testing.allocator,
        inputs(&files, &candidate, &identity, &source, &toolchain),
        root,
        std.time.ns_per_s,
        &execution,
    ));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, root, .{}));
    try std.testing.expect(!execution.hasBorrowedInputs());
    try std.testing.expect(execution.owner == null);
}

test "pre-owned and copied product execution reach no filesystem" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "baseline", &root_storage);
    var files: product.CandidateFiles = .{};
    var candidate: product.CandidateProduct = .{};
    var identity: product.CandidateEvidenceIdentity = .{};
    var source: product.SourceTreeAuthority = .{};
    var toolchain: product.ZigToolchainAuthority = .{};
    const value = inputs(&files, &candidate, &identity, &source, &toolchain);
    var original: product.Execution = .{};
    original.owner = &original;
    var copied = original;
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, value, root, std.time.ns_per_s, &original));
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, value, root, std.time.ns_per_s, &copied));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, root, .{}));
}

test "product preflight rejects execution-backed root storage" {
    var files: product.CandidateFiles = .{};
    var candidate: product.CandidateProduct = .{};
    var identity: product.CandidateEvidenceIdentity = .{};
    var source: product.SourceTreeAuthority = .{};
    var toolchain: product.ZigToolchainAuthority = .{};
    var execution: product.Execution = .{};
    execution.workspace.root.path_storage[0] = '/';
    execution.workspace.root.path_storage[1] = 'x';
    execution.workspace.root.path_storage[2] = 0;
    const aliased_root = execution.workspace.root.path_storage[0..2 :0];
    try std.testing.expectError(error.InvalidOwner, product.run(
        std.testing.io,
        std.testing.allocator,
        inputs(&files, &candidate, &identity, &source, &toolchain),
        aliased_root,
        std.time.ns_per_s,
        &execution,
    ));
    try std.testing.expect(execution.owner == null);
}

test "product preflight rejects execution-backed context storage" {
    var files: product.CandidateFiles = .{};
    var candidate: product.CandidateProduct = .{};
    var identity: product.CandidateEvidenceIdentity = .{};
    var source: product.SourceTreeAuthority = .{};
    var toolchain: product.ZigToolchainAuthority = .{};
    var execution: product.Execution = .{};
    execution.workspace.root.path_storage[0] = 'v';
    execution.workspace.root.path_storage[1] = '1';
    execution.workspace.root.path_storage[2] = 0;
    var value = inputs(&files, &candidate, &identity, &source, &toolchain);
    value.context.tag = execution.workspace.root.path_storage[0..2];
    try std.testing.expectError(error.InvalidOwner, product.run(
        std.testing.io,
        std.testing.allocator,
        value,
        "/tmp/baseline",
        std.time.ns_per_s,
        &execution,
    ));
    try std.testing.expect(execution.owner == null);
}

test "product preflight rejects dirty nested app state" {
    var files: product.CandidateFiles = .{};
    var candidate: product.CandidateProduct = .{};
    var identity: product.CandidateEvidenceIdentity = .{};
    var source: product.SourceTreeAuthority = .{};
    var toolchain: product.ZigToolchainAuthority = .{};
    var execution: product.Execution = .{};
    execution.app.main.fd = 123456;
    try std.testing.expectError(error.InvalidOwner, product.run(
        std.testing.io,
        std.testing.allocator,
        inputs(&files, &candidate, &identity, &source, &toolchain),
        "/tmp/baseline",
        std.time.ns_per_s,
        &execution,
    ));
    try std.testing.expect(execution.owner == null);
    try std.testing.expectEqual(@as(std.c.fd_t, 123456), execution.app.main.fd);

    execution = .{};
    execution.workspace.root.parent_fd = 123456;
    try std.testing.expectError(error.InvalidOwner, product.run(
        std.testing.io,
        std.testing.allocator,
        inputs(&files, &candidate, &identity, &source, &toolchain),
        "/tmp/baseline",
        std.time.ns_per_s,
        &execution,
    ));
    try std.testing.expect(execution.owner == null);
    try std.testing.expectEqual(@as(std.c.fd_t, 123456), execution.workspace.root.parent_fd);
}

test "production source has one borrowed runner call and no owned runner call" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/release_adapter_candidate_baseline_preparation_product.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "runner.runBorrowingDeadline("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "runner.run("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "deadline_mod.start("));
}

test "workspace cleanup failure retains only production retry state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "baseline", &root_storage);
    var execution: product.Execution = .{};
    execution.owner = &execution;
    execution.io = std.testing.io;
    execution.transaction.owner = &execution.transaction;
    execution.transaction.workspace_attempted = true;
    try product.prepareWorkspaceForTest(&execution.workspace, root);
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, root, .{});
    defer dir.close(std.testing.io);
    try dir.writeFile(std.testing.io, .{ .sub_path = "foreign", .data = "keep" });
    try std.testing.expectError(error.CleanupFailed, execution.retryCleanup());
    try std.testing.expect(execution.owner == &execution);
    try std.testing.expect(!execution.hasBorrowedInputs());
    try dir.deleteFile(std.testing.io, "foreign");
    try execution.retryCleanup();
    try std.testing.expect(execution.owner == null);
}

test "runner cleanup failure retains its workspace dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try absolute(&tmp, "baseline", &root_storage);
    var execution: product.Execution = .{};
    execution.owner = &execution;
    execution.io = std.testing.io;
    execution.transaction.owner = &execution.transaction;
    execution.transaction.runner_attempted = true;
    execution.transaction.workspace_attempted = true;
    try product.prepareWorkspaceForTest(&execution.workspace, root);
    execution.runner.owner = &execution.runner;
    execution.runner.cleanup_workspace = &execution.workspace;
    execution.runner.borrowed_deadline = true;
    execution.runner.product_execution.owner = &execution.runner.product_execution;
    execution.runner.product_execution.evidence_attempted = true;
    execution.runner.evidence.owner = &execution.runner.evidence;
    try std.testing.expectError(error.CleanupFailed, execution.retryCleanup());
    try std.testing.expect(execution.transaction.runner_attempted);
    try std.testing.expect(execution.transaction.workspace_attempted);
    try std.testing.expect(execution.workspace.owner == &execution.workspace);

    execution.runner = .{};
    execution.transaction.runner_attempted = false;
    try execution.retryCleanup();
    try std.testing.expect(execution.owner == null);
}

test "foreign deadline owner remains retryable and cannot be discarded" {
    var execution: product.Execution = .{};
    execution.owner = &execution;
    execution.transaction.owner = &execution.transaction;
    execution.transaction.deadline_started = true;
    var foreign: product.Deadline = .{ .started_ns = 1, .expires_ns = 2 };
    foreign.owner = &foreign;
    execution.deadline = .{ .owner = &foreign, .started_ns = 1, .expires_ns = 2 };
    try std.testing.expectError(error.CleanupFailed, execution.retryCleanup());
    try std.testing.expect(execution.transaction.deadline_started);
    execution.deadline.owner = &execution.deadline;
    try execution.retryCleanup();
    try std.testing.expect(execution.owner == null);
}
