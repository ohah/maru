const std = @import("std");
const runner = @import("release_adapter_candidate_baseline_runner");

test "runner preserves successful production outputs in caller execution" {
    std.testing.refAllDecls(runner);
    var steps = Steps{};
    var execution: runner.Execution = .{};
    try runner.executeWith(&steps, &execution);
    try std.testing.expect(execution.product_execution.ownsSuccessfulChildren());
    try std.testing.expect(!execution.ownsSuccessfulOutputs());
    try std.testing.expect(!execution.needsCleanup());
    try std.testing.expectEqualStrings("bind,start,initial,default,after-default,signed,after-signed,evidence,final,deadline", steps.log());
}

test "runner rejects copied and pre-owned execution before callbacks" {
    var steps = Steps{};
    var execution: runner.Execution = .{};
    execution.owner = &execution;
    try std.testing.expectError(error.InvalidOwner, runner.executeWith(&steps, &execution));
    try std.testing.expectEqual(@as(usize, 0), steps.length);
}

test "runner unwinds attempted production outputs in reverse order" {
    var steps = Steps{ .fail_at = .final };
    var execution: runner.Execution = .{};
    try std.testing.expectError(error.Injected, runner.executeWith(&steps, &execution));
    try std.testing.expectEqualStrings("bind,start,initial,default,after-default,signed,after-signed,evidence,final,clean-evidence,clean-signed,clean-default", steps.log());
    try std.testing.expect(!execution.needsCleanup());
}

test "runner preserves exact retry set when cleanup fails" {
    var steps = Steps{ .fail_at = .final, .cleanup_fail = .signed };
    var execution: runner.Execution = .{};
    try std.testing.expectError(error.CleanupFailed, runner.executeWith(&steps, &execution));
    try std.testing.expect(execution.needsCleanup());
    steps.cleanup_fail = .none;
    try runner.retryCleanupWith(&steps, &execution);
    try std.testing.expect(!execution.needsCleanup());
}

test "runner validates final deadline after final candidate fence" {
    var steps = Steps{ .fail_at = .deadline };
    var execution: runner.Execution = .{};
    try std.testing.expectError(error.Injected, runner.executeWith(&steps, &execution));
    try std.testing.expect(std.mem.indexOf(u8, steps.log(), "final,deadline,clean-evidence") != null);
}

test "production retry releases deadline-only cleanup state" {
    var execution: runner.Execution = .{};
    execution.owner = &execution;
    execution.deadline = .{ .owner = &execution.deadline, .started_ns = 1, .expires_ns = 2 };
    try runner.retryCleanup(&execution);
    try std.testing.expect(execution.owner == null);
}

test "workspace cleanup removes only the selected child and leaf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&path_storage, "{s}/baseline", .{root_buf[0..root_len]});
    var workspace: runner.Workspace = .{};
    try runner.prepareWorkspaceForTest(&workspace, root);
    const paths = try workspace.value();
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, root, .{});
    defer dir.close(std.testing.io);
    try dir.createDir(std.testing.io, "default-false", .default_dir);
    try dir.createDir(std.testing.io, "signed-app-quit", .default_dir);
    {
        var home = try dir.openDir(std.testing.io, "default-false", .{});
        defer home.close(std.testing.io);
        try home.writeFile(std.testing.io, .{ .sub_path = "residue", .data = "owned" });
    }
    try dir.writeFile(std.testing.io, .{ .sub_path = "default-false.json", .data = "leaf" });
    try dir.writeFile(std.testing.io, .{ .sub_path = "signed-app-quit.json", .data = "neighbor" });
    try runner.cleanupWorkspaceChildForTest(std.testing.io, &workspace, .default_false);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, paths.default_false_home, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, paths.default_false_leaf, .{}));
    try std.Io.Dir.accessAbsolute(std.testing.io, paths.signed_app_quit_home, .{});
    try std.Io.Dir.accessAbsolute(std.testing.io, paths.signed_app_quit_leaf, .{});
    try runner.cleanupWorkspaceChildForTest(std.testing.io, &workspace, .signed_app_quit);
    try workspace.cleanup();
}

test "successful cleanup remains retryable after a later child fails" {
    var steps = Steps{ .cleanup_fail = .signed };
    var execution: runner.Execution = .{};
    try runner.executeWith(&steps, &execution);
    try std.testing.expectError(error.CleanupFailed, runner.cleanupWith(&steps, &execution));
    try std.testing.expect(execution.product_execution.ownsSuccessfulChildren());
    steps.cleanup_fail = .none;
    try runner.cleanupWith(&steps, &execution);
    try std.testing.expect(execution.owner == null);
}

const Point = enum { none, final, deadline };
const Cleanup = enum { none, signed };

const Steps = struct {
    events: [512]u8 = undefined,
    length: usize = 0,
    fail_at: Point = .none,
    cleanup_fail: Cleanup = .none,

    fn add(self: *@This(), value: []const u8) void {
        if (self.length != 0) {
            self.events[self.length] = ',';
            self.length += 1;
        }
        @memcpy(self.events[self.length..][0..value.len], value);
        self.length += value.len;
    }
    fn log(self: *const @This()) []const u8 {
        return self.events[0..self.length];
    }
    pub fn bindCandidate(self: *@This()) !void {
        self.add("bind");
    }
    pub fn startDeadline(self: *@This()) !*Steps {
        self.add("start");
        return self;
    }
    pub fn validateInitialCandidate(self: *@This(), _: *Steps) !void {
        self.add("initial");
    }
    pub fn runDefaultFalse(self: *@This(), _: *Steps) !void {
        self.add("default");
    }
    pub fn validateCandidateAfterDefault(self: *@This(), _: *Steps) !void {
        self.add("after-default");
    }
    pub fn runSignedAppQuit(self: *@This(), _: *Steps) !void {
        self.add("signed");
    }
    pub fn validateCandidateAfterQuit(self: *@This(), _: *Steps) !void {
        self.add("after-signed");
    }
    pub fn publishEvidence(self: *@This(), _: *Steps) !void {
        self.add("evidence");
    }
    pub fn validateFinalCandidate(self: *@This(), _: *Steps) !void {
        self.add("final");
        if (self.fail_at == .final) return error.Injected;
    }
    pub fn validateFinalDeadline(self: *@This(), _: *Steps) !void {
        self.add("deadline");
        if (self.fail_at == .deadline) return error.Injected;
    }
    pub fn cleanupEvidence(self: *@This()) !void {
        self.add("clean-evidence");
    }
    pub fn cleanupSignedAppQuit(self: *@This()) !void {
        self.add("clean-signed");
        if (self.cleanup_fail == .signed) return error.InjectedCleanup;
    }
    pub fn cleanupDefaultFalse(self: *@This()) !void {
        self.add("clean-default");
    }
};
