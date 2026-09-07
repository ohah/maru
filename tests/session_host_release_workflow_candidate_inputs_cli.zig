//! Product contract for fresh-process signed candidate input pinning.

const std = @import("std");
const c = std.c;
const cli = @import("release_workflow_candidate_inputs_cli");
const checkpoint = @import("release_adapter_live_workflow_checkpoint");
const context = @import("release_adapter_context");

test "argv accepts only one canonical candidate pin target" {
    const parsed = try cli.parse(&.{ "pin", "/private/tmp/checkpoint", "maru-root-v1-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "/private/tmp/session-host-candidate-1.2.3" });
    try std.testing.expectEqualStrings("/private/tmp/session-host-candidate-1.2.3", parsed.candidate_directory);
    try std.testing.expectError(error.InvalidCommand, cli.parse(&.{ "scan", "/private/tmp/checkpoint", "token", "/private/tmp/session-host-candidate-1.2.3" }));
    try std.testing.expectError(error.InvalidPath, cli.parse(&.{ "pin", "/private/tmp/checkpoint", "token", "/private/tmp/../candidate" }));
    try std.testing.expectError(error.InvalidArguments, cli.parse(&.{ "pin", "/private/tmp/checkpoint", "token" }));
}

test "fresh candidate pins exact inventory and advances one success leaf" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const token = try fixture.bootstrap();
    try cli.execute(std.testing.allocator, &.{ "pin", fixture.checkpointPath(), token, fixture.candidatePath() }, workflowContext());
    try std.testing.expectEqual(@as(usize, 2), try fixture.checkpointEntries());
    try std.testing.expectEqual(@as(usize, 3), try fixture.candidateEntries());
    var root: checkpoint.Root = .{};
    try checkpoint.openRootExpected(&root, fixture.checkpointPath(), try checkpoint.decodeRootIdentity(token));
    defer root.deinit() catch {};
    const state = try checkpoint.reopen(std.testing.allocator, &root, 1, workflowContext());
    try std.testing.expectEqual(@import("release_adapter_live_workflow_phase").Outcome.active, state.outcome);
    try std.testing.expectEqual(@as(?@import("release_adapter_live_workflow_phase").Stage, .candidate_attestation), state.expectedStage());
}

test "foreign inventory settles terminal failure without altering candidate" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const token = try fixture.bootstrap();
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "session-host-candidate-1.2.3/foreign", .data = "foreign" });
    try std.testing.expectError(error.InvalidCandidate, cli.execute(std.testing.allocator, &.{ "pin", fixture.checkpointPath(), token, fixture.candidatePath() }, workflowContext()));
    try std.testing.expectEqual(@as(usize, 2), try fixture.checkpointEntries());
    try std.testing.expectEqual(@as(usize, 4), try fixture.candidateEntries());
}

test "unsafe files and context drift fail closed" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const token = try fixture.bootstrap();
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(fixture.frozenPath().ptr, 0o644));
    try std.testing.expectError(error.InvalidCandidate, cli.execute(std.testing.allocator, &.{ "pin", fixture.checkpointPath(), token, fixture.candidatePath() }, workflowContext()));

    var second = try Fixture.init();
    defer second.deinit();
    const second_token = try second.bootstrap();
    var foreign = workflowContext();
    foreign.build.run_attempt += 1;
    try std.testing.expectError(error.ContextMismatch, cli.execute(std.testing.allocator, &.{ "pin", second.checkpointPath(), second_token, second.candidatePath() }, foreign));
    try std.testing.expectEqual(@as(usize, 1), try second.checkpointEntries());

    var third = try Fixture.init();
    defer third.deinit();
    const third_token = try third.bootstrap();
    try third.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "session-host-candidate-1.2.3/Maru.app/Contents/MacOS/maru-macos-app", .data = "different app bytes" });
    try std.testing.expectError(error.InvalidCandidate, cli.execute(std.testing.allocator, &.{ "pin", third.checkpointPath(), third_token, third.candidatePath() }, workflowContext()));
}

test "product source owns no credential or checkpoint primitive" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tools/session-host/release_workflow_candidate_inputs_cli.zig", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "environment.readCurrent()"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "GITHUB_OUTPUT"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "GH_TOKEN"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "@import(\"release_adapter_live_workflow_checkpoint\")"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "owner.candidateInputsProcess("));
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    checkpoint_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    checkpoint_len: usize = 0,
    candidate_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    candidate_len: usize = 0,
    frozen_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    frozen_len: usize = 0,
    token_storage: [checkpoint.max_root_identity_token_bytes:0]u8 = @splat(0),
    token_len: usize = 0,

    fn init() !Fixture {
        var result = Fixture{ .tmp = std.testing.tmpDir(.{}) };
        try result.tmp.dir.createDir(std.testing.io, "checkpoint", .default_dir);
        try result.tmp.dir.createDir(std.testing.io, "session-host-candidate-1.2.3", .default_dir);
        try result.tmp.dir.createDir(std.testing.io, "session-host-candidate-1.2.3/Maru.app", .default_dir);
        try result.tmp.dir.createDir(std.testing.io, "session-host-candidate-1.2.3/Maru.app/Contents", .default_dir);
        try result.tmp.dir.createDir(std.testing.io, "session-host-candidate-1.2.3/Maru.app/Contents/MacOS", .default_dir);
        try result.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "session-host-candidate-1.2.3/Maru-1.2.3-universal.dmg", .data = "signed dmg bytes" });
        try result.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "session-host-candidate-1.2.3/maru-session-host-1.2.3", .data = "signed frozen bytes" });
        try result.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "session-host-candidate-1.2.3/Maru.app/Contents/MacOS/maru-macos-app", .data = "signed frozen bytes" });
        var root: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try result.tmp.dir.realPath(std.testing.io, &root);
        const checkpoint_path = try std.fmt.bufPrintZ(&result.checkpoint_path, "{s}/checkpoint", .{root[0..root_len]});
        result.checkpoint_len = checkpoint_path.len;
        const candidate_path = try std.fmt.bufPrintZ(&result.candidate_path, "{s}/session-host-candidate-1.2.3", .{root[0..root_len]});
        result.candidate_len = candidate_path.len;
        const frozen_path = try std.fmt.bufPrintZ(&result.frozen_path, "{s}/maru-session-host-1.2.3", .{candidate_path});
        result.frozen_len = frozen_path.len;
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(checkpoint_path.ptr, 0o700));
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(candidate_path.ptr, 0o700));
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(frozen_path.ptr, 0o755));
        var app_main_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const app_main = try std.fmt.bufPrintZ(&app_main_storage, "{s}/Maru.app/Contents/MacOS/maru-macos-app", .{candidate_path});
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(app_main.ptr, 0o755));
        return result;
    }
    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }
    fn checkpointPath(self: *Fixture) [:0]const u8 {
        return self.checkpoint_path[0..self.checkpoint_len :0];
    }
    fn candidatePath(self: *Fixture) [:0]const u8 {
        return self.candidate_path[0..self.candidate_len :0];
    }
    fn frozenPath(self: *Fixture) [:0]const u8 {
        return self.frozen_path[0..self.frozen_len :0];
    }
    fn bootstrap(self: *Fixture) ![:0]const u8 {
        var root: checkpoint.Root = .{};
        try checkpoint.openRoot(&root, self.checkpointPath());
        defer root.deinit() catch {};
        const identity = try checkpoint.initializeOrRecoverInitial(std.testing.allocator, &root, workflowContext());
        const token = try checkpoint.encodeRootIdentity(&self.token_storage, identity);
        self.token_len = token.len;
        return self.token_storage[0..self.token_len :0];
    }
    fn checkpointEntries(self: *Fixture) !usize {
        return countEntries(self.tmp.dir, "checkpoint");
    }
    fn candidateEntries(self: *Fixture) !usize {
        return countEntries(self.tmp.dir, "session-host-candidate-1.2.3");
    }
};

fn countEntries(root: std.Io.Dir, path: []const u8) !usize {
    var dir = try root.openDir(std.testing.io, path, .{ .iterate = true });
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
