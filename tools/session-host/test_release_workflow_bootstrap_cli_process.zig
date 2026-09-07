//! Actual-process smoke for canonical bootstrap token publication and recovery.

const std = @import("std");
const c = std.c;
const checkpoint = @import("release_adapter_live_workflow_checkpoint");
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
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const template = try std.fmt.bufPrintZ(&root_storage, "/private/tmp/maru-workflow-bootstrap.XXXXXX", .{});
    const root: [:0]const u8 = std.mem.span(mkdtemp(template.ptr) orelse return error.TempRootFailed);
    defer std.Io.Dir.cwd().deleteTree(init.io, root) catch {};
    if (c.chmod(root.ptr, 0o700) != 0) return error.PrivateRootFailed;

    const first = try run(init.io, init.gpa, executable, root, &environment);
    defer init.gpa.free(first);
    const second = try run(init.io, init.gpa, executable, root, &environment);
    defer init.gpa.free(second);
    if (!std.mem.eql(u8, first, second) or first.len < 2 or first[first.len - 1] != '\n' or
        std.mem.count(u8, first, "\n") != 1) return error.InvalidOutput;
    _ = try checkpoint.decodeRootIdentity(first[0 .. first.len - 1]);
    var child_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try childPath(&child_storage, root, "foreign"), .data = "foreign\n" });
    try expectSilentFailure(init.io, init.gpa, executable, root, &environment);
}

fn run(io: std.Io, allocator: std.mem.Allocator, executable: []const u8, root: []const u8, environment: *const std.process.Environ.Map) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ executable, "initialize", root },
        .environ_map = environment,
        .stdout_limit = .limited(checkpoint.max_root_identity_token_bytes + 2),
        .stderr_limit = .limited(1),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildFailed,
    }
    if (result.stderr.len != 0) return error.UnexpectedStderr;
    return result.stdout;
}

fn expectSilentFailure(io: std.Io, allocator: std.mem.Allocator, executable: []const u8, root: []const u8, environment: *const std.process.Environ.Map) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ executable, "initialize", root },
        .environ_map = environment,
        .stdout_limit = .limited(1),
        .stderr_limit = .limited(1),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return error.ChildSucceeded,
        else => {},
    }
    if (result.stdout.len != 0 or result.stderr.len != 0) return error.UnexpectedOutput;
}

fn childPath(storage: *[std.fs.max_path_bytes:0]u8, root: []const u8, leaf: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root, leaf });
}

fn trustedEnvironment(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    const values = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "GITHUB_REPOSITORY", .value = "ohah/maru" },                                                  .{ .key = "GITHUB_REPOSITORY_ID", .value = "12345" },
        .{ .key = "GITHUB_REF", .value = "refs/tags/v1.2.3" },                                                  .{ .key = "GITHUB_REF_TYPE", .value = "tag" },
        .{ .key = "GITHUB_REF_NAME", .value = "v1.2.3" },                                                       .{ .key = "GITHUB_SHA", .value = "0123456789abcdef0123456789abcdef01234567" },
        .{ .key = "GITHUB_WORKFLOW_REF", .value = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3" }, .{ .key = "GITHUB_RUN_ID", .value = "333" },
        .{ .key = "GITHUB_RUN_ATTEMPT", .value = "2" },                                                         .{ .key = "GITHUB_EVENT_NAME", .value = "push" },
        .{ .key = "GITHUB_REF_PROTECTED", .value = "true" },
    };
    for (values) |entry| try map.put(entry.key, entry.value);
    return map;
}
