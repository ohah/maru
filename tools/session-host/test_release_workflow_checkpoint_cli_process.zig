//! Actual-process smoke for the product action-stage checkpoint bridge.

const std = @import("std");
const c = std.c;
const checkpoint = @import("release_adapter_live_workflow_checkpoint");
const context = @import("release_adapter_context");
const phase = @import("release_adapter_live_workflow_phase");
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const executable_input = args.next() orelse return error.MissingExecutable;
    if (args.next() != null) return error.TooManyArguments;
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(init.io, executable_input, init.gpa);
    defer init.gpa.free(executable);
    var environment = try trustedEnvironment(init.gpa);
    defer environment.deinit();
    try runScenario(init.io, init.gpa, executable, &environment, .succeeded);
    try runScenario(init.io, init.gpa, executable, &environment, .failed);
}

fn runScenario(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: []const u8,
    environment: *const std.process.Environ.Map,
    result: phase.Result,
) !void {
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const template = try std.fmt.bufPrintZ(&root_storage, "/private/tmp/maru-workflow-checkpoint-cli-{s}.XXXXXX", .{@tagName(result)});
    const root_path: [:0]const u8 = std.mem.span(mkdtemp(template.ptr) orelse return error.TempRootFailed);
    defer std.Io.Dir.cwd().deleteTree(io, root_path) catch {};
    if (c.chmod(root_path.ptr, 0o700) != 0) return error.PrivateRootFailed;
    var root: checkpoint.Root = .{};
    try checkpoint.openRoot(&root, root_path);
    const identity = try root.value();
    var token_storage: [checkpoint.max_root_identity_token_bytes:0]u8 = undefined;
    const token = try checkpoint.encodeRootIdentity(&token_storage, identity);
    try checkpoint.initialize(&root, workflowContext());
    _ = try checkpoint.advance(allocator, &root, .candidate_pinning, .succeeded, workflowContext());
    try root.deinit();

    try expectSilentSuccess(allocator, io, &.{ executable, "admit", root_path, token, "candidate_attestation" }, environment);
    try expectSilentSuccess(allocator, io, &.{ executable, "commit", root_path, token, "candidate_attestation", @tagName(result) }, environment);

    var final_root: checkpoint.Root = .{};
    try checkpoint.openRoot(&final_root, root_path);
    defer final_root.deinit() catch {};
    const state = try checkpoint.reopen(allocator, &final_root, 2, workflowContext());
    if (result == .succeeded) {
        if (state.outcome != .active or state.expectedStage() != .draft_authoring)
            return error.InvalidFinalState;
    } else if (state.outcome != .local_failure) return error.InvalidFinalState;
}

fn expectSilentSuccess(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    environment: *const std.process.Environ.Map,
) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = environment,
        .stdout_limit = .limited(1),
        .stderr_limit = .limited(1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildFailed,
    }
    if (result.stdout.len != 0 or result.stderr.len != 0) return error.UnexpectedOutput;
}

fn trustedEnvironment(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    const values = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "GITHUB_REPOSITORY", .value = "ohah/maru" },
        .{ .key = "GITHUB_REPOSITORY_ID", .value = "12345" },
        .{ .key = "GITHUB_REF", .value = "refs/tags/v1.2.3" },
        .{ .key = "GITHUB_REF_TYPE", .value = "tag" },
        .{ .key = "GITHUB_REF_NAME", .value = "v1.2.3" },
        .{ .key = "GITHUB_SHA", .value = "0123456789abcdef0123456789abcdef01234567" },
        .{ .key = "GITHUB_WORKFLOW_REF", .value = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3" },
        .{ .key = "GITHUB_RUN_ID", .value = "333" },
        .{ .key = "GITHUB_RUN_ATTEMPT", .value = "2" },
        .{ .key = "GITHUB_EVENT_NAME", .value = "push" },
        .{ .key = "GITHUB_REF_PROTECTED", .value = "true" },
    };
    for (values) |entry| try map.put(entry.key, entry.value);
    return map;
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
