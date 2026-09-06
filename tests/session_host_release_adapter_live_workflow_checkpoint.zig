//! Fixed live-workflow checkpoint inventory and descriptor-bound transition contract.

const std = @import("std");
const checkpoint = @import("release_adapter_live_workflow_checkpoint");
const context = @import("release_adapter_context");
const phase = @import("release_adapter_live_workflow_phase");

const stages = [_]phase.Stage{
    .candidate_pinning,
    .candidate_attestation,
    .draft_authoring,
    .authored_attestation,
    .aggregate_prepare,
    .aggregate_finalize,
    .publication,
    .aggregate_cleanup,
};

test "checkpoint inventory is the exact initial plus eight stage results" {
    const expected = [_][]const u8{
        "00-initial.state",
        "01-candidate-pinning.state",
        "02-candidate-attestation.state",
        "03-draft-authoring.state",
        "04-authored-attestation.state",
        "05-aggregate-prepare.state",
        "06-aggregate-finalize.state",
        "07-publication.state",
        "08-aggregate-cleanup.state",
    };
    try std.testing.expectEqual(expected.len, checkpoint.leaf_count);
    for (expected, 0..) |name, index|
        try std.testing.expectEqualStrings(name, try checkpoint.leafName(@intCast(index)));
    try std.testing.expectError(error.InvalidCheckpoint, checkpoint.leafName(expected.len));
}

test "success chain reopens each fixed input and exclusively publishes the next state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root_path = try rootPath(&tmp, &root_path_storage);
    try privateMode(root_path);
    const current = workflowContext();
    try withRoot(root_path, struct {
        fn run(root: *checkpoint.Root, workflow: context.Context) !void {
            try checkpoint.initialize(root, workflow);
        }
    }.run, current);
    for (stages) |stage| {
        try withRootEvent(root_path, stage, .succeeded, current);
    }
    try withRoot(root_path, struct {
        fn run(root: *checkpoint.Root, workflow: context.Context) !void {
            const state = try checkpoint.reopen(std.testing.allocator, root, 8, workflow);
            try std.testing.expectEqual(phase.Outcome.succeeded, state.outcome);
        }
    }.run, current);
    try std.testing.expectEqual(@as(usize, checkpoint.leaf_count), try entryCount(&tmp));
}

test "every stage terminal result is published once and cannot advance" {
    for (stages, 0..) |failed_stage, failed_index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const root_path = try rootPath(&tmp, &root_path_storage);
        try privateMode(root_path);
        const current = workflowContext();
        try withRoot(root_path, struct {
            fn run(root: *checkpoint.Root, workflow: context.Context) !void {
                try checkpoint.initialize(root, workflow);
            }
        }.run, current);
        for (stages[0..failed_index]) |stage| try withRootEvent(root_path, stage, .succeeded, current);
        try withRootEvent(root_path, failed_stage, .failed, current);
        var root: checkpoint.Root = .{};
        try checkpoint.openRoot(&root, root_path);
        defer root.deinit() catch {};
        const terminal = try checkpoint.reopen(std.testing.allocator, &root, @intCast(failed_index + 1), current);
        try std.testing.expect(terminal.outcome != .active);
        try std.testing.expectError(error.DestinationExists, checkpoint.advance(std.testing.allocator, &root, failed_stage, .failed, current));
        if (failed_index + 1 < stages.len)
            try std.testing.expectError(error.TerminalState, checkpoint.advance(std.testing.allocator, &root, stages[failed_index + 1], .succeeded, current));
    }
}

test "skip reverse and caller-selected checkpoint paths cannot mutate inventory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root_path = try rootPath(&tmp, &root_path_storage);
    try privateMode(root_path);
    const current = workflowContext();
    var root: checkpoint.Root = .{};
    try checkpoint.openRoot(&root, root_path);
    defer root.deinit() catch {};
    try checkpoint.initialize(&root, current);
    try std.testing.expectError(error.UnexpectedStage, checkpoint.advance(std.testing.allocator, &root, .draft_authoring, .succeeded, current));
    try std.testing.expectEqual(@as(usize, 1), try entryCount(&tmp));
    _ = try checkpoint.advance(std.testing.allocator, &root, .candidate_pinning, .succeeded, current);
    try std.testing.expectError(error.DestinationExists, checkpoint.advance(std.testing.allocator, &root, .candidate_pinning, .succeeded, current));
    try std.testing.expectEqual(@as(usize, 2), try entryCount(&tmp));
}

test "foreign context and state content mode symlink or hardlink drift are rejected" {
    inline for (.{ "context", "content", "mode", "symlink", "hardlink" }) |scenario| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const root_path = try rootPath(&tmp, &root_path_storage);
        try privateMode(root_path);
        const current = workflowContext();
        var root: checkpoint.Root = .{};
        try checkpoint.openRoot(&root, root_path);
        defer root.deinit() catch {};
        try checkpoint.initialize(&root, current);
        if (std.mem.eql(u8, scenario, "context")) {
            var foreign = current;
            foreign.build.run_attempt += 1;
            try std.testing.expectError(error.ContextMismatch, checkpoint.advance(std.testing.allocator, &root, .candidate_pinning, .succeeded, foreign));
        } else if (std.mem.eql(u8, scenario, "content")) {
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "root/00-initial.state", .data = "foreign\n" });
            try std.testing.expectError(error.InvalidDocument, checkpoint.advance(std.testing.allocator, &root, .candidate_pinning, .succeeded, current));
        } else if (std.mem.eql(u8, scenario, "mode")) {
            var leaf_storage: [std.fs.max_path_bytes:0]u8 = undefined;
            const leaf = try std.fmt.bufPrintZ(&leaf_storage, "{s}/00-initial.state", .{root_path});
            try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(leaf.ptr, 0o644));
            try std.testing.expectError(error.UnsafeMode, checkpoint.advance(std.testing.allocator, &root, .candidate_pinning, .succeeded, current));
        } else if (std.mem.eql(u8, scenario, "symlink")) {
            try tmp.dir.deleteFile(std.testing.io, "root/00-initial.state");
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "root/target", .data = "foreign\n" });
            try tmp.dir.symLink(std.testing.io, "target", "root/00-initial.state", .{});
            try std.testing.expectError(error.UnsafePath, checkpoint.advance(std.testing.allocator, &root, .candidate_pinning, .succeeded, current));
        } else {
            try tmp.dir.hardLink("root/00-initial.state", tmp.dir, "root/alias", std.testing.io, .{});
            try std.testing.expectError(error.PathAlias, checkpoint.advance(std.testing.allocator, &root, .candidate_pinning, .succeeded, current));
        }
        try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, scenario, "symlink") or std.mem.eql(u8, scenario, "hardlink")) 2 else 1), try entryCount(&tmp));
    }
}

test "root must be private owned canonical and no-follow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root_path = try rootPath(&tmp, &root_path_storage);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(root_path.ptr, 0o755));
    var root: checkpoint.Root = .{};
    try std.testing.expectError(error.UnsafeRoot, checkpoint.openRoot(&root, root_path));
    try privateMode(root_path);
    var trusted: checkpoint.Root = .{};
    try checkpoint.openRoot(&trusted, root_path);
    const identity = try trusted.value();
    try trusted.deinit();
    var token_storage: [checkpoint.max_root_identity_token_bytes:0]u8 = undefined;
    const token = try checkpoint.encodeRootIdentity(&token_storage, identity);
    try std.testing.expectEqualDeep(identity, try checkpoint.decodeRootIdentity(token));
    try std.testing.expectError(error.UnsafeRoot, checkpoint.decodeRootIdentity(token[0 .. token.len - 1]));
    var changed = identity;
    changed.device +%= 1;
    try std.testing.expectError(error.RootChanged, checkpoint.openRootExpected(&root, root_path, changed));
    changed = identity;
    changed.inode +%= 1;
    try std.testing.expectError(error.RootChanged, checkpoint.openRootExpected(&root, root_path, changed));
    changed = identity;
    changed.uid +%= 1;
    try std.testing.expectError(error.RootChanged, checkpoint.openRootExpected(&root, root_path, changed));
    changed = identity;
    changed.mode ^= 1;
    try std.testing.expectError(error.RootChanged, checkpoint.openRootExpected(&root, root_path, changed));
    var alias_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const alias = try std.fmt.bufPrintZ(&alias_storage, "{s}/root-link", .{root_path[0..std.mem.lastIndexOfScalar(u8, root_path, '/').?]});
    try std.Io.Dir.cwd().symLink(std.testing.io, root_path, alias, .{});
    try std.testing.expectError(error.UnsafeRoot, checkpoint.openRoot(&root, alias));
    try std.testing.expectError(error.UnsafeRoot, checkpoint.openRoot(&root, "/private/tmp/../tmp"));
}

test "held root rejects pathname replacement before either leaf is selected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root_path = try rootPath(&tmp, &root_path_storage);
    try privateMode(root_path);
    const current = workflowContext();
    var root: checkpoint.Root = .{};
    try checkpoint.openRoot(&root, root_path);
    defer root.deinit() catch {};
    const expected = try root.value();
    try checkpoint.initialize(&root, current);
    try tmp.dir.rename("root", tmp.dir, "old-root", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "root", .default_dir);
    try privateMode(root_path);
    var replacement: checkpoint.Root = .{};
    try std.testing.expectError(error.RootChanged, checkpoint.openRootExpected(&replacement, root_path, expected));
    try std.testing.expectError(error.RootChanged, checkpoint.advance(std.testing.allocator, &root, .candidate_pinning, .succeeded, current));
    try std.testing.expectEqual(@as(usize, 0), try namedEntryCount(&tmp, "root"));
    try std.testing.expectEqual(@as(usize, 1), try namedEntryCount(&tmp, "old-root"));
}

test "every transition allocation failure leaves destination absent" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationHarness, .{});
}

fn allocationHarness(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root_path = try rootPath(&tmp, &root_path_storage);
    try privateMode(root_path);
    const current = workflowContext();
    var root: checkpoint.Root = .{};
    try checkpoint.openRoot(&root, root_path);
    defer root.deinit() catch {};
    try checkpoint.initialize(&root, current);
    _ = checkpoint.advance(allocator, &root, .candidate_pinning, .succeeded, current) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), try entryCount(&tmp));
        return err;
    };
}

fn withRoot(path: [:0]const u8, run: *const fn (*checkpoint.Root, context.Context) anyerror!void, workflow: context.Context) !void {
    var root: checkpoint.Root = .{};
    try checkpoint.openRoot(&root, path);
    defer root.deinit() catch {};
    try run(&root, workflow);
}

fn withRootEvent(path: [:0]const u8, stage: phase.Stage, result: phase.Result, workflow: context.Context) !void {
    var root: checkpoint.Root = .{};
    try checkpoint.openRoot(&root, path);
    defer root.deinit() catch {};
    _ = try checkpoint.advance(std.testing.allocator, &root, stage, result, workflow);
}

fn rootPath(tmp: *std.testing.TmpDir, output: *[std.fs.max_path_bytes:0]u8) ![:0]const u8 {
    try tmp.dir.createDir(std.testing.io, "root", .default_dir);
    var parent: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &parent);
    return std.fmt.bufPrintZ(output, "{s}/root", .{parent[0..len]});
}

fn privateMode(path: [:0]const u8) !void {
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path.ptr, 0o700));
}

fn entryCount(tmp: *std.testing.TmpDir) !usize {
    return namedEntryCount(tmp, "root");
}

fn namedEntryCount(tmp: *std.testing.TmpDir, name: []const u8) !usize {
    var dir = try tmp.dir.openDir(std.testing.io, name, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}

fn workflowContext() context.Context {
    return .{
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = "0123456789abcdef0123456789abcdef01234567",
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
        .protected_tag = true,
    };
}
