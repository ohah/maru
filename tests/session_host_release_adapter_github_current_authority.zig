//! Current GitHub authority binds closed REST transport to repository, run, environment and deployment facts.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const composition = @import("release_adapter_github_current_authority");

const source = "0123456789abcdef0123456789abcdef01234567";
const expected: context_mod.Context = .{
    .repository = .{ .id = 1_257_870_483, .owner = "ohah", .name = "maru" },
    .tag = "v1.2.3",
    .source_commit = source,
    .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 33_335_653_781, .run_attempt = 2 },
    .protected_tag = true,
};

const repository = "{\"id\":1257870483,\"name\":\"maru\",\"full_name\":\"ohah/maru\",\"owner\":{\"login\":\"ohah\"}}";
const run = "{\"id\":33335653781,\"run_attempt\":2,\"event\":\"push\",\"head_sha\":\"" ++ source ++ "\",\"path\":\".github/workflows/release.yml\",\"status\":\"in_progress\",\"conclusion\":null,\"pull_requests\":[],\"repository\":{\"id\":1257870483,\"name\":\"maru\",\"full_name\":\"ohah/maru\",\"owner\":{\"login\":\"ohah\"}},\"head_repository\":{\"id\":1257870483,\"name\":\"maru\",\"full_name\":\"ohah/maru\",\"owner\":{\"login\":\"ohah\"}}}";
const environment = "{\"id\":161088068,\"name\":\"release\",\"can_admins_bypass\":false,\"protection_rules\":[{\"id\":1,\"type\":\"required_reviewers\",\"prevent_self_review\":true,\"reviewers\":[{\"type\":\"User\",\"reviewer\":{\"id\":7}}]}],\"deployment_branch_policy\":null}";
const jobs = "{\"total_count\":1,\"jobs\":[{\"id\":90618357140,\"run_id\":33335653781,\"run_attempt\":2,\"head_sha\":\"" ++ source ++ "\",\"status\":\"in_progress\",\"conclusion\":null,\"name\":\"universal dmg (signed + notarized)\",\"workflow_name\":\"Release\",\"html_url\":\"https://github.com/ohah/maru/actions/runs/33335653781/job/90618357140\"}]}";
const slurped_jobs = "[" ++ jobs ++ "]";

const Clock = struct {
    value: i128 = 100,
    step: i128 = 1,
    pub fn now(self: *@This()) !i128 {
        const out = self.value;
        self.value += self.step;
        return out;
    }
};
const SharedDeadline = struct {
    calls: usize = 0,
    fail_at: usize = 0,
    pub fn remaining(self: *@This()) !i128 {
        self.calls += 1;
        if (self.calls == self.fail_at) return error.TimedOut;
        return 10_000 - @as(i128, @intCast(self.calls * 100));
    }
};
const Authority = struct {
    calls: usize = 0,
    fail_at: usize = 0,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, _: [:0]const u8) !void {
        self.calls += 1;
        if (self.calls == self.fail_at) return error.ExecutableChanged;
    }
};
const Executor = struct {
    deployments: usize,
    winner: usize = 0,
    calls: usize = 0,
    budgets: [composition.max_total_commands]i128 = @splat(0),
    pub fn capture(self: *@This(), _: []const u8, args: []const []const u8, _: []const []const u8, output: []u8, budget: i128) ![]const u8 {
        const call_index = self.calls;
        self.budgets[call_index] = budget;
        self.calls += 1;
        const endpoint = args[args.len - 1];
        if (std.mem.eql(u8, endpoint, "repos/ohah/maru")) {
            try std.testing.expectEqual(@as(usize, 0), call_index);
            return copy(output, repository);
        }
        if (std.mem.indexOf(u8, endpoint, "/actions/runs/") != null and std.mem.indexOf(u8, endpoint, "/jobs") == null) {
            try std.testing.expectEqual(@as(usize, 1), call_index);
            return copy(output, run);
        }
        if (std.mem.endsWith(u8, endpoint, "/environments/release")) {
            try std.testing.expectEqual(@as(usize, 2), call_index);
            return copy(output, environment);
        }
        if (std.mem.indexOf(u8, endpoint, "/jobs?") != null) {
            try std.testing.expectEqual(@as(usize, 3), call_index);
            return copy(output, slurped_jobs);
        }
        var writer = std.Io.Writer.fixed(output);
        if (std.mem.indexOf(u8, endpoint, "/deployments?") != null) {
            try std.testing.expectEqual(@as(usize, 4), call_index);
            try writer.writeAll("[[");
            for (0..self.deployments) |index| {
                if (index != 0) try writer.writeByte(',');
                const id = 5_659_920_000 + index;
                try writer.print("{{\"id\":{d},\"sha\":\"{s}\",\"ref\":\"v1.2.3\",\"task\":\"deploy\",\"environment\":\"release\",\"original_environment\":\"release\",\"statuses_url\":\"https://api.github.com/repos/ohah/maru/deployments/{d}/statuses\",\"repository_url\":\"https://api.github.com/repos/ohah/maru\",\"performed_via_github_app\":{{\"id\":15368,\"slug\":\"github-actions\",\"owner\":{{\"login\":\"github\"}}}}}}", .{ id, source, id });
            }
            try writer.writeAll("]]\n");
            return writer.buffered();
        }
        for (0..self.deployments) |index| {
            const id = 5_659_920_000 + index;
            var needle: [64]u8 = undefined;
            const match = try std.fmt.bufPrint(&needle, "/deployments/{d}/statuses", .{id});
            if (std.mem.indexOf(u8, endpoint, match) != null) {
                try std.testing.expectEqual(5 + index, call_index);
                const job = "https://github.com/ohah/maru/actions/runs/33335653781/job/90618357140";
                try writer.print("[[{{\"id\":1,\"state\":\"pending\",\"environment\":\"release\",\"log_url\":\"{s}\",\"target_url\":\"{s}\",\"url\":\"https://api.github.com/repos/ohah/maru/deployments/{d}/statuses/1\",\"deployment_url\":\"https://api.github.com/repos/ohah/maru/deployments/{d}\",\"repository_url\":\"https://api.github.com/repos/ohah/maru\"}}", .{ job, job, id, id });
                if (index == self.winner) try writer.print(",{{\"id\":2,\"state\":\"in_progress\",\"environment\":\"release\",\"log_url\":\"{s}\",\"target_url\":\"{s}\",\"url\":\"https://api.github.com/repos/ohah/maru/deployments/{d}/statuses/2\",\"deployment_url\":\"https://api.github.com/repos/ohah/maru/deployments/{d}\",\"repository_url\":\"https://api.github.com/repos/ohah/maru\"}}", .{ job, job, id, id });
                try writer.writeAll("]]\n");
                return writer.buffered();
            }
        }
        return error.UnexpectedEndpoint;
    }
};

fn copy(output: []u8, bytes: []const u8) ![]const u8 {
    if (bytes.len > output.len) return error.ShortBuffer;
    @memcpy(output[0..bytes.len], bytes);
    return output[0..bytes.len];
}

fn authenticate(count: usize, result: *composition.CurrentGitHubAuthority) !void {
    var authority = Authority{};
    var executor = Executor{ .deployments = count, .winner = count - 1 };
    var clock = Clock{};
    var response: [65536]u8 = undefined;
    try composition.authenticateWith(&authority, &executor, &clock, std.testing.allocator, expected, "/opt/trusted/gh", "token", &response, 10_000, result);
    try std.testing.expectEqual(count + 5, executor.calls);
    try std.testing.expectEqual(executor.calls, authority.calls);
    for (executor.budgets[1..executor.calls], executor.budgets[0 .. executor.calls - 1]) |later, earlier| try std.testing.expect(later < earlier);
}

fn allocationHarness(allocator: std.mem.Allocator) !void {
    var authority = Authority{};
    var executor = Executor{ .deployments = 1 };
    var clock = Clock{};
    var response: [65536]u8 = undefined;
    var result: composition.CurrentGitHubAuthority = .{};
    try composition.authenticateWith(&authority, &executor, &clock, allocator, expected, "/opt/trusted/gh", "token", &response, 10_000, &result);
    result.owner = &result;
    try result.deinit();
}

test "one and one hundred deployment candidates publish exact current authority" {
    for ([_]usize{ 1, 100 }) |count| {
        var result: composition.CurrentGitHubAuthority = .{};
        try authenticate(count, &result);
        defer result.deinit() catch {};
        const value = result.value().?;
        try std.testing.expect(value.protected_environment);
        try std.testing.expectEqual(@as(u64, 90_618_357_140), value.job_id);
        try std.testing.expectEqual(@as(u64, 5_659_920_000 + count - 1), value.deployment_id);
    }
}

test "zero candidates and pre-owned output publish nothing without authority drift" {
    var authority = Authority{};
    var executor = Executor{ .deployments = 0 };
    var clock = Clock{};
    var response: [65536]u8 = undefined;
    var result: composition.CurrentGitHubAuthority = .{};
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, composition.authenticateWith(&authority, &executor, &clock, std.testing.allocator, expected, "/opt/trusted/gh", "token", &response, 1000, &result));
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
    result.owner = null;
    try std.testing.expectError(error.DeploymentMismatch, composition.authenticateWith(&authority, &executor, &clock, std.testing.allocator, expected, "/opt/trusted/gh", "token", &response, 1000, &result));
    try std.testing.expect(result.value() == null);
}

test "CLI replacement deadline and allocation failure publish nothing" {
    var response: [65536]u8 = undefined;
    var result: composition.CurrentGitHubAuthority = .{};
    var clock = Clock{};
    var executor = Executor{ .deployments = 1 };
    var authority = Authority{};
    for (1..7) |fail_at| {
        authority = .{ .fail_at = fail_at };
        executor = .{ .deployments = 1 };
        clock = .{};
        try std.testing.expectError(error.ExecutableChanged, composition.authenticateWith(&authority, &executor, &clock, std.testing.allocator, expected, "/opt/trusted/gh", "token", &response, 1000, &result));
        try std.testing.expectEqual(fail_at - 1, executor.calls);
        try std.testing.expect(result.value() == null);
    }
    authority = .{};
    executor = .{ .deployments = 1 };
    clock = .{ .step = 600 };
    try std.testing.expectError(error.TimedOut, composition.authenticateWith(&authority, &executor, &clock, std.testing.allocator, expected, "/opt/trusted/gh", "token", &response, 1000, &result));
    try std.testing.expect(result.value() == null);
    authority = .{};
    executor = .{ .deployments = 1 };
    clock = .{ .step = -1 };
    try std.testing.expectError(error.ClockFailed, composition.authenticateWith(&authority, &executor, &clock, std.testing.allocator, expected, "/opt/trusted/gh", "token", &response, 1000, &result));
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
    try std.testing.expect(result.value() == null);
    var bytes: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&bytes);
    authority = .{};
    executor = .{ .deployments = 1 };
    clock = .{};
    try std.testing.expectError(error.OutOfMemory, composition.authenticateWith(&authority, &executor, &clock, fixed.allocator(), expected, "/opt/trusted/gh", "token", &response, 1000, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationHarness, .{});
    var pinned: composition.PinnedExecutable = undefined;
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, composition.authenticate(std.testing.io, std.testing.allocator, expected, .{ .path = "/opt/trusted/gh", .pinned = &pinned }, "token", &response, 1000, &result));
}

test "copied result never exposes authority" {
    var result: composition.CurrentGitHubAuthority = .{};
    try authenticate(1, &result);
    defer result.deinit() catch {};
    var copied = result;
    try std.testing.expect(copied.value() == null);
}

test "shared absolute deadline is consumed once before every request without restart" {
    var authority = Authority{};
    var executor = Executor{ .deployments = 1 };
    var deadline = SharedDeadline{};
    var response: [65536]u8 = undefined;
    var result: composition.CurrentGitHubAuthority = .{};
    try composition.authenticateUntilWith(&authority, &executor, &deadline, std.testing.allocator, expected, "/opt/trusted/gh", "token", &response, &result);
    try std.testing.expectEqual(@as(usize, 12), deadline.calls);
    try std.testing.expectEqual(deadline.calls / 2, executor.calls);
    for (executor.budgets[0..executor.calls], 1..) |budget, index|
        try std.testing.expectEqual(10_000 - @as(i128, @intCast(index * 200)), budget);

    try result.deinit();
    result = .{};
    authority = .{};
    executor = .{ .deployments = 1 };
    deadline = .{ .fail_at = 6 };
    try std.testing.expectError(error.TimedOut, composition.authenticateUntilWith(&authority, &executor, &deadline, std.testing.allocator, expected, "/opt/trusted/gh", "token", &response, &result));
    try std.testing.expectEqual(@as(usize, 2), executor.calls);
    try std.testing.expectEqual(executor.calls + 1, authority.calls);
    try std.testing.expect(result.value() == null);

    authority = .{};
    executor = .{ .deployments = 1 };
    deadline = .{ .fail_at = 5 };
    try std.testing.expectError(error.TimedOut, composition.authenticateUntilWith(&authority, &executor, &deadline, std.testing.allocator, expected, "/opt/trusted/gh", "token", &response, &result));
    try std.testing.expectEqual(@as(usize, 2), authority.calls);
    try std.testing.expectEqual(@as(usize, 2), executor.calls);
    try std.testing.expect(result.value() == null);
}
