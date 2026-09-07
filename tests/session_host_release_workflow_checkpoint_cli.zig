//! Product checkpoint CLI contract for live GitHub action stages.
//!
//! These tests keep stage/result selection closed and exercise the same descriptor-bound state
//! transition that separate composite-action processes use, without touching app session data.

const std = @import("std");
const c = std.c;
const cli = @import("release_workflow_checkpoint_cli");
const checkpoint = @import("release_adapter_live_workflow_checkpoint");
const context = @import("release_adapter_context");
const phase = @import("release_adapter_live_workflow_phase");

test "argv admits only the two closed commands and canonical stage result names" {
    try std.testing.expectEqualStrings("candidate_attestation", @tagName((try cli.parse(&.{ "admit", "/private/tmp/root", root_token, "candidate_attestation" })).admit.invocation));
    const committed = (try cli.parse(&.{ "commit", "/private/tmp/root", root_token, "authored_attestation", "failed" })).commit;
    try std.testing.expectEqualStrings("authored_attestation", @tagName(committed.target.invocation));
    try std.testing.expectEqual(phase.Result.failed, committed.result);
    try std.testing.expectError(error.InvalidCommand, cli.parse(&.{ "advance", "/private/tmp/root", root_token, "candidate_attestation" }));
    try std.testing.expectError(error.InvalidStage, cli.parse(&.{ "admit", "/private/tmp/root", root_token, "Candidate_Attestation" }));
    try std.testing.expectError(error.InvalidResult, cli.parse(&.{ "commit", "/private/tmp/root", root_token, "candidate_attestation", "cleanup_failed" }));
    try std.testing.expectError(error.InvalidArguments, cli.parse(&.{ "admit", "/private/tmp/root", root_token, "candidate_attestation", "extra" }));
}

test "fresh owner admission is read only and success commit publishes exactly the fixed next leaf" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try cli.execute(std.testing.allocator, &.{ "admit", fixture.path(), fixture.token(), "candidate_attestation" }, workflowContext());
    try std.testing.expectEqual(@as(usize, 2), try fixture.entryCount());
    try cli.execute(std.testing.allocator, &.{ "commit", fixture.path(), fixture.token(), "candidate_attestation", "succeeded" }, workflowContext());
    try std.testing.expectEqual(@as(usize, 3), try fixture.entryCount());
    const state = try fixture.reopen(2);
    try std.testing.expectEqual(phase.Stage.draft_authoring, state.expectedStage().?);
}

test "failed action commit is durable terminal state and replay is rejected" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try cli.execute(std.testing.allocator, &.{ "admit", fixture.path(), fixture.token(), "candidate_attestation" }, workflowContext());
    try cli.execute(std.testing.allocator, &.{ "commit", fixture.path(), fixture.token(), "candidate_attestation", "failed" }, workflowContext());
    const state = try fixture.reopen(2);
    try std.testing.expectEqual(phase.Outcome.local_failure, state.outcome);
    try std.testing.expectError(error.DestinationExists, cli.execute(std.testing.allocator, &.{ "commit", fixture.path(), fixture.token(), "candidate_attestation", "failed" }, workflowContext()));
}

test "context root and ordering drift publish no destination" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var foreign = workflowContext();
    foreign.build.run_attempt += 1;
    try std.testing.expectError(error.ContextMismatch, cli.execute(std.testing.allocator, &.{ "admit", fixture.path(), fixture.token(), "candidate_attestation" }, foreign));
    try std.testing.expectError(error.RootChanged, cli.execute(std.testing.allocator, &.{ "admit", fixture.path(), root_token, "candidate_attestation" }, workflowContext()));
    try std.testing.expectError(error.UnexpectedStage, cli.execute(std.testing.allocator, &.{ "commit", fixture.path(), fixture.token(), "authored_attestation", "succeeded" }, workflowContext()));
    try std.testing.expectEqual(@as(usize, 2), try fixture.entryCount());
}

test "product source reads the closed environment and emits no success authority" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tools/session-host/release_workflow_checkpoint_cli.zig", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "environment.readCurrent()"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "GITHUB_OUTPUT"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "stdout"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "GH_TOKEN"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "@import(\"release_adapter_live_workflow_checkpoint\")"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "owner.admitActionProcess("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "owner.commitActionProcess("));
}

const root_token = "maru-root-v1:0000000000000001-0000000000000001-000001f5-000041c0";

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path_storage: [std.fs.max_path_bytes:0]u8,
    token_storage: [checkpoint.max_root_identity_token_bytes:0]u8,
    path_len: usize,
    token_len: usize,

    fn init() !Fixture {
        var result: Fixture = undefined;
        result.tmp = std.testing.tmpDir(.{});
        try result.tmp.dir.createDir(std.testing.io, "root", .default_dir);
        var parent: [std.fs.max_path_bytes]u8 = undefined;
        const len = try result.tmp.dir.realPath(std.testing.io, &parent);
        const path_value = try std.fmt.bufPrintZ(&result.path_storage, "{s}/root", .{parent[0..len]});
        result.path_len = path_value.len;
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(path_value.ptr, 0o700));
        var root: checkpoint.Root = .{};
        try checkpoint.openRoot(&root, path_value);
        const identity = try root.value();
        result.token_len = (try checkpoint.encodeRootIdentity(&result.token_storage, identity)).len;
        try checkpoint.initialize(&root, workflowContext());
        _ = try checkpoint.advance(std.testing.allocator, &root, .candidate_pinning, .succeeded, workflowContext());
        try root.deinit();
        return result;
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn path(self: *Fixture) [:0]const u8 {
        return self.path_storage[0..self.path_len :0];
    }

    fn token(self: *Fixture) [:0]const u8 {
        return self.token_storage[0..self.token_len :0];
    }

    fn entryCount(self: *Fixture) !usize {
        var dir = try self.tmp.dir.openDir(std.testing.io, "root", .{ .iterate = true });
        defer dir.close(std.testing.io);
        var iterator = dir.iterate();
        var count: usize = 0;
        while (try iterator.next(std.testing.io)) |_| count += 1;
        return count;
    }

    fn reopen(self: *Fixture, index: usize) !phase.State {
        var root: checkpoint.Root = .{};
        try checkpoint.openRoot(&root, self.path());
        defer root.deinit() catch {};
        return checkpoint.reopen(std.testing.allocator, &root, index, workflowContext());
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
