//! Product bootstrap CLI contract for one protected live workflow checkpoint root.

const std = @import("std");
const c = std.c;
const bootstrap = @import("release_workflow_bootstrap_cli");
const checkpoint = @import("release_adapter_live_workflow_checkpoint");
const context = @import("release_adapter_context");

test "argv admits only initialize with one canonical absolute root" {
    try std.testing.expectEqualStrings("/private/tmp/root", (try bootstrap.parse(&.{ "initialize", "/private/tmp/root" })).root_path);
    try std.testing.expectError(error.InvalidCommand, bootstrap.parse(&.{ "recover", "/private/tmp/root" }));
    try std.testing.expectError(error.InvalidPath, bootstrap.parse(&.{ "initialize", "relative" }));
    try std.testing.expectError(error.InvalidPath, bootstrap.parse(&.{ "initialize", "/private/tmp/../root" }));
    try std.testing.expectError(error.InvalidPath, bootstrap.parse(&.{ "initialize", "/private//root" }));
    try std.testing.expectError(error.InvalidPath, bootstrap.parse(&.{ "initialize", "/private/tmp/root/" }));
    try std.testing.expectError(error.InvalidPath, bootstrap.parse(&.{ "initialize", "/private/tmp\x00/root" }));
    try std.testing.expectError(error.InvalidArguments, bootstrap.parse(&.{"initialize"}));
    try std.testing.expectError(error.InvalidArguments, bootstrap.parse(&.{ "initialize", "/private/tmp/root", "extra" }));
}

test "fresh initialize and exact initial recovery return the same canonical identity" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var first: [checkpoint.max_root_identity_token_bytes:0]u8 = undefined;
    var second: [checkpoint.max_root_identity_token_bytes:0]u8 = undefined;
    const first_token = try bootstrap.execute(std.testing.allocator, &.{ "initialize", fixture.path() }, workflowContext(), &first);
    const second_token = try bootstrap.execute(std.testing.allocator, &.{ "initialize", fixture.path() }, workflowContext(), &second);
    try std.testing.expectEqualStrings(first_token, second_token);
    _ = try checkpoint.decodeRootIdentity(first_token);
    try std.testing.expectEqual(@as(usize, 1), try fixture.entryCount());
    var root: checkpoint.Root = .{};
    try checkpoint.openRootExpected(&root, fixture.path(), try checkpoint.decodeRootIdentity(first_token));
    defer root.deinit() catch {};
    const state = try checkpoint.reopen(std.testing.allocator, &root, 0, workflowContext());
    try std.testing.expectEqual(@as(?@import("release_adapter_live_workflow_phase").Stage, .candidate_pinning), state.expectedStage());
}

test "context drift and any later leaf suppress identity recovery" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var token_storage: [checkpoint.max_root_identity_token_bytes:0]u8 = undefined;
    const token = try bootstrap.execute(std.testing.allocator, &.{ "initialize", fixture.path() }, workflowContext(), &token_storage);
    var foreign = workflowContext();
    foreign.build.run_attempt += 1;
    var output: [checkpoint.max_root_identity_token_bytes:0]u8 = undefined;
    try std.testing.expectError(error.ContextMismatch, bootstrap.execute(std.testing.allocator, &.{ "initialize", fixture.path() }, foreign, &output));
    var root: checkpoint.Root = .{};
    try checkpoint.openRootExpected(&root, fixture.path(), try checkpoint.decodeRootIdentity(token));
    _ = try checkpoint.advance(std.testing.allocator, &root, .candidate_pinning, .succeeded, workflowContext());
    try root.deinit();
    try std.testing.expectError(error.InvalidInitialInventory, bootstrap.execute(std.testing.allocator, &.{ "initialize", fixture.path() }, workflowContext(), &output));
}

test "root mode and foreign inventory publish no token" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var output: [checkpoint.max_root_identity_token_bytes:0]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(fixture.path().ptr, 0o755));
    try std.testing.expectError(error.UnsafeRoot, bootstrap.execute(std.testing.allocator, &.{ "initialize", fixture.path() }, workflowContext(), &output));
    try std.testing.expectEqual(@as(usize, 0), try fixture.entryCount());
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(fixture.path().ptr, 0o700));
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "root/foreign", .data = "foreign\n" });
    try std.testing.expectError(error.InvalidInitialInventory, bootstrap.execute(std.testing.allocator, &.{ "initialize", fixture.path() }, workflowContext(), &output));
    try std.testing.expectEqual(@as(usize, 1), try fixture.entryCount());
}

test "product source reads closed environment and delegates checkpoint ownership" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tools/session-host/release_workflow_bootstrap_cli.zig", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "environment.readCurrent()"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "GITHUB_OUTPUT"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "GH_TOKEN"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "@import(\"release_adapter_live_workflow_checkpoint\")"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "owner.bootstrapProcess("));
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path_storage: [std.fs.max_path_bytes:0]u8,
    path_len: usize,

    fn init() !Fixture {
        var result: Fixture = undefined;
        result.tmp = std.testing.tmpDir(.{});
        try result.tmp.dir.createDir(std.testing.io, "root", .default_dir);
        var parent: [std.fs.max_path_bytes]u8 = undefined;
        const len = try result.tmp.dir.realPath(std.testing.io, &parent);
        const root_path = try std.fmt.bufPrintZ(&result.path_storage, "{s}/root", .{parent[0..len]});
        result.path_len = root_path.len;
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(root_path.ptr, 0o700));
        return result;
    }
    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }
    fn path(self: *Fixture) [:0]const u8 {
        return self.path_storage[0..self.path_len :0];
    }
    fn entryCount(self: *Fixture) !usize {
        var dir = try self.tmp.dir.openDir(std.testing.io, "root", .{ .iterate = true });
        defer dir.close(std.testing.io);
        var iterator = dir.iterate();
        var count: usize = 0;
        while (try iterator.next(std.testing.io)) |_| count += 1;
        return count;
    }
};

fn workflowContext() context.Context {
    return .{
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = "0123456789abcdef0123456789abcdef01234567",
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
        .protected_tag = true,
    };
}
