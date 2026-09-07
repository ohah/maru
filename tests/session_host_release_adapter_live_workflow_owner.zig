//! Closed eight-invocation owner for the durable live release workflow.

const std = @import("std");
const checkpoint = @import("release_adapter_live_workflow_checkpoint");
const context = @import("release_adapter_context");
const owner = @import("release_adapter_live_workflow_owner");
const phase = @import("release_adapter_live_workflow_phase");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const invocations = [_]owner.Invocation{
    .{ .candidate_pinning = {} },
    .{ .candidate_attestation = {} },
    .{ .draft_authoring = {} },
    .{ .authored_attestation = {} },
    .{ .aggregate_prepare = {} },
    .{ .aggregate_finalize = {} },
    .{ .publication = {} },
    .{ .aggregate_cleanup = {} },
};

test "invocation inventory binds exact stage kind and identity" {
    const expected_stages = [_]phase.Stage{ .candidate_pinning, .candidate_attestation, .draft_authoring, .authored_attestation, .aggregate_prepare, .aggregate_finalize, .publication, .aggregate_cleanup };
    const expected_kinds = [_]owner.Kind{ .product, .action, .command, .action, .command, .command, .command, .command };
    const expected_names = [_][]const u8{
        "signed-candidate-inputs",
        ".github/actions/session-host-release-live-candidate-attestation/action.yml",
        "prepare-candidate",
        ".github/actions/session-host-release-live-authored-attestation/action.yml",
        "prepare-candidate-aggregate",
        "finalize-candidate-aggregate",
        "resume-candidate-publication",
        "cleanup-candidate-aggregate",
    };
    for (invocations, 0..) |invocation, index| {
        const identity = owner.identity(invocation);
        try std.testing.expectEqual(expected_stages[index], identity.stage);
        try std.testing.expectEqual(expected_kinds[index], identity.kind);
        try std.testing.expectEqualStrings(expected_names[index], identity.name);
    }
}

test "success chain calls each sealed executor once and publishes terminal success" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.open();
    const workflow = fixture.currentContext();
    var calls: usize = 0;
    var executor: owner.Executor = .{};
    try executor.init(&calls, success);
    for (invocations) |invocation| _ = try owner.run(std.testing.allocator, &fixture.root, workflow, invocation, &executor);
    try std.testing.expectEqual(invocations.len, calls);
    const final = try checkpoint.reopen(std.testing.allocator, &fixture.root, invocations.len, workflow);
    try std.testing.expectEqual(phase.Outcome.succeeded, final.outcome);
}

test "every stage publishes each allowed terminal result exactly once" {
    for (invocations, 0..) |failed_invocation, failed_index| {
        inline for (.{ phase.Result.failed, phase.Result.cleanup_failed }) |result| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            try fixture.open();
            const workflow = fixture.currentContext();
            var success_calls: usize = 0;
            var success_executor: owner.Executor = .{};
            try success_executor.init(&success_calls, success);
            for (invocations[0..failed_index]) |invocation| _ = try owner.run(std.testing.allocator, &fixture.root, workflow, invocation, &success_executor);
            var failed_calls: usize = 0;
            var result_ctx: ResultCtx = .{ .calls = &failed_calls, .result = result };
            var failed_executor: owner.Executor = .{};
            try failed_executor.init(&result_ctx, fixedResult);
            const terminal = try owner.run(std.testing.allocator, &fixture.root, workflow, failed_invocation, &failed_executor);
            try std.testing.expect(terminal.outcome != .active);
            try std.testing.expectEqual(@as(usize, 1), failed_calls);
            try std.testing.expectError(error.DestinationExists, owner.run(std.testing.allocator, &fixture.root, workflow, failed_invocation, &failed_executor));
            try std.testing.expectEqual(@as(usize, 1), failed_calls);
        }
    }
}

test "pristine failure is exclusive to prepare candidate" {
    for (invocations, 0..) |invocation, index| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.open();
        const workflow = fixture.currentContext();
        var calls: usize = 0;
        var success_executor: owner.Executor = .{};
        try success_executor.init(&calls, success);
        for (invocations[0..index]) |prefix| _ = try owner.run(std.testing.allocator, &fixture.root, workflow, prefix, &success_executor);
        var pristine_calls: usize = 0;
        var result_ctx: ResultCtx = .{ .calls = &pristine_calls, .result = .failed_before_remote_mutation };
        var executor: owner.Executor = .{};
        try executor.init(&result_ctx, fixedResult);
        if (index == @intFromEnum(phase.Stage.draft_authoring)) {
            const terminal = try owner.run(std.testing.allocator, &fixture.root, workflow, invocation, &executor);
            try std.testing.expectEqual(phase.Outcome.local_failure, terminal.outcome);
        } else {
            const terminal = try owner.run(std.testing.allocator, &fixture.root, workflow, invocation, &executor);
            try std.testing.expect(terminal.outcome == .cleanup_required or terminal.outcome == .audit_required);
            const reopened = try checkpoint.reopen(std.testing.allocator, &fixture.root, index + 1, workflow);
            try std.testing.expectEqual(terminal, reopened);
        }
    }
}

test "skip reverse and terminal attempts never call executor" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.open();
    const workflow = fixture.currentContext();
    var calls: usize = 0;
    var executor: owner.Executor = .{};
    try executor.init(&calls, success);
    try std.testing.expectError(error.UnexpectedStage, owner.run(std.testing.allocator, &fixture.root, workflow, invocations[2], &executor));
    try std.testing.expectEqual(@as(usize, 0), calls);
    _ = try owner.run(std.testing.allocator, &fixture.root, workflow, invocations[0], &executor);
    try std.testing.expectError(error.DestinationExists, owner.run(std.testing.allocator, &fixture.root, workflow, invocations[0], &executor));
    try std.testing.expectEqual(@as(usize, 1), calls);
    var result_ctx: ResultCtx = .{ .calls = &calls, .result = .failed };
    var failed_executor: owner.Executor = .{};
    try failed_executor.init(&result_ctx, fixedResult);
    _ = try owner.run(std.testing.allocator, &fixture.root, workflow, invocations[1], &failed_executor);
    try std.testing.expectError(error.TerminalState, owner.run(std.testing.allocator, &fixture.root, workflow, invocations[2], &failed_executor));
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "executor reentry is rejected before a nested call" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.open();
    var pristine: owner.Executor = .{};
    try std.testing.expectError(error.InvalidExecutor, owner.run(std.testing.allocator, &fixture.root, fixture.currentContext(), invocations[0], &pristine));
    var executor: owner.Executor = .{};
    var reentry: ReentryCtx = .{ .root = &fixture.root, .workflow = fixture.currentContext(), .executor = undefined };
    try executor.init(&reentry, reenter);
    reentry.executor = &executor;
    var copied = executor;
    try std.testing.expectError(error.InvalidExecutor, owner.run(std.testing.allocator, &fixture.root, fixture.currentContext(), invocations[0], &copied));
    try std.testing.expectEqual(@as(usize, 0), reentry.calls);
    _ = try owner.run(std.testing.allocator, &fixture.root, fixture.currentContext(), invocations[0], &executor);
    try std.testing.expectEqual(@as(usize, 1), reentry.calls);
    try std.testing.expectEqual(error.ExecutorBusy, reentry.nested_error.?);

    var alternate_fixture = try Fixture.init();
    defer alternate_fixture.deinit();
    try alternate_fixture.open();
    var outer: owner.Executor = .{};
    var alternate: owner.Executor = .{};
    var alternate_reentry: ReentryCtx = .{ .root = &alternate_fixture.root, .workflow = alternate_fixture.currentContext(), .executor = &alternate };
    try alternate.init(&alternate_reentry, successReentry);
    try outer.init(&alternate_reentry, reenter);
    _ = try owner.run(std.testing.allocator, &alternate_fixture.root, alternate_fixture.currentContext(), invocations[0], &outer);
    try std.testing.expectEqual(@as(usize, 1), alternate_reentry.calls);
    try std.testing.expectEqual(error.InvocationBusy, alternate_reentry.nested_error.?);
}

test "executor cannot tear down the checkpoint root during invocation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.open();
    const workflow = fixture.currentContext();
    var teardown: TeardownCtx = .{ .root = &fixture.root };
    var executor: owner.Executor = .{};
    try executor.init(&teardown, teardownRoot);
    const state = try owner.run(std.testing.allocator, &fixture.root, workflow, invocations[0], &executor);
    try std.testing.expectEqual(error.InvocationBusy, teardown.observed_error.?);
    try std.testing.expectEqual(phase.Stage.candidate_attestation, state.expectedStage());
    _ = try fixture.root.value();
}

test "executor authority drift during invocation publishes no checkpoint" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.open();
    const workflow = fixture.currentContext();
    var executor: owner.Executor = .{};
    try executor.init(&executor, driftExecutor);
    try std.testing.expectError(error.InvalidExecutor, owner.run(std.testing.allocator, &fixture.root, workflow, invocations[0], &executor));
    try std.testing.expectError(error.UnsafePath, checkpoint.reopen(std.testing.allocator, &fixture.root, 1, workflow));
}

test "checkpoint invocation primitives have one production composition owner" {
    var src = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer src.close(std.testing.io);
    var walker = try posixWalk(src, std.testing.allocator);
    defer walker.deinit();
    var imports: usize = 0;
    var admits: usize = 0;
    var invokes: usize = 0;
    var advances: usize = 0;
    var bootstraps: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .sym_link) return error.TestUnexpectedResult;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const source = try src.readFileAlloc(std.testing.io, entry.path, std.testing.allocator, .limited(16 * 1024 * 1024));
        defer std.testing.allocator.free(source);
        const import_count = std.mem.count(u8, source, "@import(\"release_adapter_live_workflow_checkpoint\")");
        if (import_count != 0) try std.testing.expectEqualStrings(
            "platform/macos/session_host/release_adapter_live_workflow_owner.zig",
            entry.path,
        );
        imports += import_count;
        admits += std.mem.count(u8, source, "checkpoint.admit(");
        invokes += std.mem.count(u8, source, "checkpoint.invoke(");
        advances += std.mem.count(u8, source, "checkpoint.advance(");
        bootstraps += std.mem.count(u8, source, "checkpoint.initializeOrRecoverInitial(");
    }
    try std.testing.expectEqual(@as(usize, 1), imports);
    try std.testing.expectEqual(@as(usize, 2), admits);
    try std.testing.expectEqual(@as(usize, 1), invokes);
    try std.testing.expectEqual(@as(usize, 2), advances);
    try std.testing.expectEqual(@as(usize, 1), bootstraps);
}

test "fresh-process action bridge rejects non-action invocations and non-action results" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.open();
    const identity = try fixture.root.value();
    var token_storage: [checkpoint.max_root_identity_token_bytes:0]u8 = undefined;
    const token = try checkpoint.encodeRootIdentity(&token_storage, identity);
    try fixture.root.deinit();
    fixture.root = .{};
    try std.testing.expectError(error.InvalidExternalAction, owner.admitActionProcess(
        std.testing.allocator,
        fixture.path(),
        token,
        fixture.currentContext(),
        .{ .candidate_pinning = {} },
    ));
    try std.testing.expectError(error.InvalidActionResult, owner.commitActionProcess(
        std.testing.allocator,
        fixture.path(),
        token,
        fixture.currentContext(),
        .{ .candidate_attestation = {} },
        .cleanup_failed,
    ));
}

test "root or context drift during execution publishes no next checkpoint" {
    inline for (.{ "root", "context" }) |scenario| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.open();
        var drift: DriftCtx = .{ .path = fixture.path(), .tag = &fixture.tag, .scenario = scenario };
        var executor: owner.Executor = .{};
        try executor.init(&drift, driftCall);
        const expected_error = if (scenario[0] == 'r') error.RootChanged else error.InvalidContext;
        try std.testing.expectError(expected_error, owner.run(std.testing.allocator, &fixture.root, fixture.currentContext(), invocations[0], &executor));
        if (scenario[0] == 'r') try privateMode(fixture.path());
        if (scenario[0] == 'c') fixture.tag[5] = '3';
        try std.testing.expectError(error.UnsafePath, checkpoint.reopen(std.testing.allocator, &fixture.root, 1, workflowContext(&fixture.tag)));
    }
}

const ResultCtx = struct { calls: *usize, result: phase.Result };
fn fixedResult(raw: *anyopaque, _: owner.Identity) phase.Result {
    const ctx: *ResultCtx = @ptrCast(@alignCast(raw));
    ctx.calls.* += 1;
    return ctx.result;
}
fn success(raw: *anyopaque, _: owner.Identity) phase.Result {
    const calls: *usize = @ptrCast(@alignCast(raw));
    calls.* += 1;
    return .succeeded;
}
const ReentryCtx = struct {
    root: *checkpoint.Root,
    workflow: context.Context,
    executor: *owner.Executor,
    calls: usize = 0,
    nested_error: ?anyerror = null,
};
fn reenter(raw: *anyopaque, _: owner.Identity) phase.Result {
    const ctx: *ReentryCtx = @ptrCast(@alignCast(raw));
    ctx.calls += 1;
    _ = owner.run(std.testing.allocator, ctx.root, ctx.workflow, invocations[0], ctx.executor) catch |err| {
        ctx.nested_error = err;
        return .succeeded;
    };
    return .failed;
}

fn successReentry(_: *anyopaque, _: owner.Identity) phase.Result {
    return .succeeded;
}

const TeardownCtx = struct { root: *checkpoint.Root, observed_error: ?anyerror = null };
fn teardownRoot(raw: *anyopaque, _: owner.Identity) phase.Result {
    const ctx: *TeardownCtx = @ptrCast(@alignCast(raw));
    ctx.root.deinit() catch |err| {
        ctx.observed_error = err;
        return .succeeded;
    };
    return .failed;
}

fn driftExecutor(raw: *anyopaque, _: owner.Identity) phase.Result {
    const executor: *owner.Executor = @ptrCast(@alignCast(raw));
    executor.owner = null;
    return .succeeded;
}

const DriftCtx = struct { path: [:0]const u8, tag: *[6]u8, scenario: []const u8 };
fn driftCall(raw: *anyopaque, _: owner.Identity) phase.Result {
    const ctx: *DriftCtx = @ptrCast(@alignCast(raw));
    if (ctx.scenario[0] == 'r') {
        _ = std.c.chmod(ctx.path.ptr, 0o755);
    } else {
        ctx.tag[5] = '4';
    }
    return .succeeded;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: checkpoint.Root,
    path_storage: [std.fs.max_path_bytes:0]u8,
    path_len: usize,
    tag: [6]u8,

    fn init() !Fixture {
        var result: Fixture = undefined;
        result.tmp = std.testing.tmpDir(.{});
        try result.tmp.dir.createDir(std.testing.io, "root", .default_dir);
        var parent: [std.fs.max_path_bytes]u8 = undefined;
        const len = try result.tmp.dir.realPath(std.testing.io, &parent);
        result.path_len = (try std.fmt.bufPrintZ(&result.path_storage, "{s}/root", .{parent[0..len]})).len;
        try privateMode(result.path_storage[0..result.path_len :0]);
        result.root = .{};
        result.tag = "v1.2.3".*;
        return result;
    }

    fn path(self: *Fixture) [:0]const u8 {
        return self.path_storage[0..self.path_len :0];
    }

    fn currentContext(self: *Fixture) context.Context {
        return workflowContext(&self.tag);
    }

    fn open(self: *Fixture) !void {
        try checkpoint.openRoot(&self.root, self.path());
        try checkpoint.initialize(&self.root, self.currentContext());
    }

    fn deinit(self: *Fixture) void {
        if (self.root.owner == &self.root) self.root.deinit() catch {};
        self.tmp.cleanup();
    }
};

fn privateMode(path: [:0]const u8) !void {
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path.ptr, 0o700));
}

fn workflowContext(tag: *[6]u8) context.Context {
    return .{
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .tag = tag,
        .source_commit = "0123456789abcdef0123456789abcdef01234567",
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
        .protected_tag = true,
    };
}
