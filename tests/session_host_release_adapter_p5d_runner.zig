//! The P5d parent owns bounded execution and scratch cleanup on every terminal path.

const std = @import("std");
const runner = @import("release_adapter_p5d_runner");

const Fixture = struct {
    tmp: std.testing.TmpDir,
    workspace_storage: [std.fs.max_path_bytes:0]u8 = undefined,
    script_storage: [std.fs.max_path_bytes:0]u8 = undefined,
    workspace_len: usize = 0,
    script_len: usize = 0,

    fn init(script_bytes: []const u8) !Fixture {
        var result: Fixture = .{ .tmp = std.testing.tmpDir(.{}) };
        try result.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "child.sh", .data = script_bytes });
        var base: [std.fs.max_path_bytes]u8 = undefined;
        const len = try result.tmp.dir.realPath(std.testing.io, &base);
        result.workspace_len = (try std.fmt.bufPrintZ(&result.workspace_storage, "{s}/p5d", .{base[0..len]})).len;
        result.script_len = (try std.fmt.bufPrintZ(&result.script_storage, "{s}/child.sh", .{base[0..len]})).len;
        return result;
    }
    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }
    fn workspace(self: *Fixture) [:0]const u8 {
        return self.workspace_storage[0..self.workspace_len :0];
    }
    fn script(self: *Fixture) [:0]const u8 {
        return self.script_storage[0..self.script_len :0];
    }
};

fn inputs(fixture: *Fixture, budget_ns: i128) runner.Inputs {
    return .{ .workspace_path = fixture.workspace(), .harness = fixture.script(), .candidate_cli = "/usr/bin/true", .candidate_app_bundle = "/Applications/Maru.app", .attach_product_test = "/usr/bin/true", .upload_product_test = "/usr/bin/true", .require_developer_id = true, .budget_ns = budget_ns };
}

test "command plan has one absolute shell argv and closed environment" {
    var fixture = try Fixture.init("exit 0\n");
    defer fixture.deinit();
    var storage: runner.CommandStorage = .{};
    const plan = try runner.commandPlanForTest(inputs(&fixture, std.time.ns_per_s), &storage);
    try std.testing.expectEqualStrings("/bin/sh", plan.executable);
    try std.testing.expectEqual(@as(usize, 6), plan.args.len);
    try std.testing.expectEqualStrings(fixture.script(), plan.args[1]);
    try std.testing.expectEqualStrings("/Applications/Maru.app", plan.args[3]);
    try std.testing.expectEqual(@as(usize, 3), plan.environment.len);
    try std.testing.expectEqualStrings("PATH=/usr/bin:/bin", plan.environment[0]);
    try std.testing.expectEqualStrings("MARU_P5D_REQUIRE_DEVELOPER_ID=1", plan.environment[1]);
    try std.testing.expect(std.mem.startsWith(u8, plan.environment[2], "MARU_P5D_WORKSPACE=/"));
}

test "successful child output is removed before success returns" {
    var fixture = try Fixture.init("set -eu\nmkdir \"$MARU_P5D_WORKSPACE/output\"\nprintf passed\n");
    defer fixture.deinit();
    var output: [128]u8 = undefined;
    var execution: runner.Execution = .{};
    const captured = try runner.run(std.testing.io, &execution, inputs(&fixture, std.time.ns_per_s), &output);
    try std.testing.expectEqualStrings("passed", captured);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, fixture.workspace(), .{}));
}

test "failed child is reaped and workspace is removed" {
    var fixture = try Fixture.init("set -eu\ntouch \"$MARU_P5D_WORKSPACE/failed\"\nexit 7\n");
    defer fixture.deinit();
    var output: [128]u8 = undefined;
    var execution: runner.Execution = .{};
    try std.testing.expectError(error.ChildFailed, runner.run(std.testing.io, &execution, inputs(&fixture, std.time.ns_per_s), &output));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, fixture.workspace(), .{}));
}

test "timeout terminates process group before workspace removal" {
    var fixture = try Fixture.init("set -eu\n(trap '' TERM; while :; do /bin/sleep 1; done) &\nprintf child > \"$MARU_P5D_WORKSPACE/started\"\nwait\n");
    defer fixture.deinit();
    var output: [128]u8 = undefined;
    var execution: runner.Execution = .{};
    try std.testing.expectError(error.TimedOut, runner.run(std.testing.io, &execution, inputs(&fixture, 50 * std.time.ns_per_ms), &output));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, fixture.workspace(), .{}));
}

test "occupied workspace rejects before child execution" {
    var fixture = try Fixture.init("touch \"$MARU_P5D_WORKSPACE/ran\"\n");
    defer fixture.deinit();
    try std.Io.Dir.createDirAbsolute(std.testing.io, fixture.workspace(), .default_dir);
    var output: [128]u8 = undefined;
    var execution: runner.Execution = .{};
    try std.testing.expectError(error.DestinationExists, runner.run(std.testing.io, &execution, inputs(&fixture, std.time.ns_per_s), &output));
    const ran = try std.fmt.allocPrint(std.testing.allocator, "{s}/ran", .{fixture.workspace()});
    defer std.testing.allocator.free(ran);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, ran, .{}));
    try std.Io.Dir.deleteDirAbsolute(std.testing.io, fixture.workspace());
}

test "cleanup failure preserves exact retry owner and foreign replacement" {
    var fixture = try Fixture.init("set -eu\nmv \"$MARU_P5D_WORKSPACE\" \"$MARU_P5D_WORKSPACE.moved\"\nmkdir \"$MARU_P5D_WORKSPACE\"\nprintf foreign > \"$MARU_P5D_WORKSPACE/foreign\"\n");
    defer fixture.deinit();
    var output: [128]u8 = undefined;
    var execution: runner.Execution = .{};
    try std.testing.expectError(error.CleanupFailed, runner.run(std.testing.io, &execution, inputs(&fixture, std.time.ns_per_s), &output));
    try std.testing.expect(execution.owner == &execution);
    const foreign = try std.fmt.allocPrint(std.testing.allocator, "{s}/foreign", .{fixture.workspace()});
    defer std.testing.allocator.free(foreign);
    try std.Io.Dir.cwd().access(std.testing.io, foreign, .{});
    try std.Io.Dir.cwd().deleteTree(std.testing.io, fixture.workspace());
    const moved = try std.fmt.allocPrint(std.testing.allocator, "{s}.moved", .{fixture.workspace()});
    defer std.testing.allocator.free(moved);
    try std.Io.Dir.renameAbsolute(moved, fixture.workspace(), std.testing.io);
    try execution.cleanup(std.testing.io);
}
