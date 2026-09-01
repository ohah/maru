//! Proves that draft creation is one closed mutation and that ambiguous remote success never turns
//! into an automatic retry. No test contacts GitHub or reads the user's session-host namespace.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const draft = @import("release_adapter_github_draft_creation");

const response =
    \\{"id":8123,"tag_name":"v1.2.3","target_commitish":"0123456789abcdef0123456789abcdef01234567","name":"v1.2.3","draft":true,"prerelease":false,"immutable":false}
;

fn context() context_mod.Context {
    return .{
        .repository = .{ .id = 55, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = "0123456789abcdef0123456789abcdef01234567",
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 7, .run_attempt = 1 },
        .protected_tag = true,
    };
}

const Deadline = struct {
    calls: usize = 0,
    remaining_ns: i128 = 900,
    pub fn remaining(self: *@This()) !i128 {
        self.calls += 1;
        if (self.remaining_ns <= 0) return error.TimedOut;
        return self.remaining_ns;
    }
};

const Authority = struct {
    calls: usize = 0,
    fail_on: usize = 0,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, path: [:0]const u8) !void {
        try std.testing.expectEqualStrings("/usr/local/bin/gh", path);
        self.calls += 1;
        if (self.calls == self.fail_on) return error.ExecutableChanged;
    }
};

const Executor = struct {
    calls: usize = 0,
    reply: []const u8 = response,
    pub fn capture(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) ![]const u8 {
        self.calls += 1;
        try std.testing.expectEqualStrings("/usr/local/bin/gh", executable);
        const expected = [_][]const u8{ "api", "--method", "POST", "--hostname", "github.com", "--header", "Accept: application/vnd.github+json", "--header", "X-GitHub-Api-Version: 2022-11-28", "repos/ohah/maru/releases", "-f", "tag_name=v1.2.3", "-f", "target_commitish=0123456789abcdef0123456789abcdef01234567", "-f", "name=v1.2.3", "-F", "draft=true", "-F", "prerelease=false", "-F", "generate_release_notes=true" };
        try std.testing.expectEqual(expected.len, args.len);
        for (expected, args) |wanted, actual| try std.testing.expectEqualStrings(wanted, actual);
        try std.testing.expectEqual(@as(usize, 2), environment.len);
        try std.testing.expectEqualStrings("GH_TOKEN=secret", environment[0]);
        try std.testing.expectEqualStrings("GH_PROMPT_DISABLED=1", environment[1]);
        try std.testing.expectEqual(@as(i128, 900), budget_ns);
        @memcpy(output[0..self.reply.len], self.reply);
        return output[0..self.reply.len];
    }
};

const Publisher = struct {
    fail: bool = false,
    pub fn publish(self: *@This(), result: *draft.DraftAuthority) !void {
        if (self.fail) return error.LocalPublicationFailed;
        try result.publish();
    }
};

test "closed mutation publishes exact bound draft authority" {
    var authority = Authority{};
    var executor = Executor{};
    var deadline = Deadline{};
    var publisher = Publisher{};
    var output: [4096]u8 = undefined;
    var result: draft.DraftAuthority = .{};
    try draft.createWith(&authority, &executor, &publisher, &deadline, std.testing.allocator, context(), "/usr/local/bin/gh", "secret", &output, &result);
    const value = result.value().?;
    try std.testing.expectEqual(@as(u64, 8123), value.id);
    try std.testing.expectEqualStrings("v1.2.3", value.tag);
    try std.testing.expectEqualStrings(context().source_commit, value.source_commit);
    try std.testing.expectEqual(@as(usize, 1), executor.calls);
    try std.testing.expectEqual(@as(usize, 2), authority.calls);
    try result.deinit();
}

test "malformed successful response becomes remote state unknown without retry" {
    var authority = Authority{};
    var executor = Executor{ .reply = "{}" };
    var deadline = Deadline{};
    var publisher = Publisher{};
    var output: [4096]u8 = undefined;
    var result: draft.DraftAuthority = .{};
    try std.testing.expectError(error.InvalidJson, draft.createWith(&authority, &executor, &publisher, &deadline, std.testing.allocator, context(), "/usr/local/bin/gh", "secret", &output, &result));
    try std.testing.expectEqual(draft.State.remote_state_unknown, result.state());
    try std.testing.expectEqual(@as(usize, 1), executor.calls);
    try std.testing.expectError(error.InvalidOwner, result.deinit());
}

test "local publication failure preserves cleanup id without retry" {
    var authority = Authority{};
    var executor = Executor{};
    var deadline = Deadline{};
    var publisher = Publisher{ .fail = true };
    var output: [4096]u8 = undefined;
    var result: draft.DraftAuthority = .{};
    try std.testing.expectError(error.LocalPublicationFailed, draft.createWith(&authority, &executor, &publisher, &deadline, std.testing.allocator, context(), "/usr/local/bin/gh", "secret", &output, &result));
    try std.testing.expectEqual(draft.State.cleanup_required, result.state());
    try std.testing.expectEqual(@as(u64, 8123), result.cleanupId().?);
    try std.testing.expectEqual(@as(usize, 1), executor.calls);
    try std.testing.expectError(error.InvalidOwner, result.deinit());
}

test "post-child cli drift leaves remote state unknown" {
    var authority = Authority{ .fail_on = 2 };
    var executor = Executor{};
    var deadline = Deadline{};
    var publisher = Publisher{};
    var output: [4096]u8 = undefined;
    var result: draft.DraftAuthority = .{};
    try std.testing.expectError(error.ExecutableChanged, draft.createWith(&authority, &executor, &publisher, &deadline, std.testing.allocator, context(), "/usr/local/bin/gh", "secret", &output, &result));
    try std.testing.expectEqual(draft.State.remote_state_unknown, result.state());
    try std.testing.expectEqual(@as(usize, 1), executor.calls);
    try std.testing.expectError(error.InvalidOwner, result.deinit());
}

test "preowned result and expired deadline perform no mutation" {
    var authority = Authority{};
    var executor = Executor{};
    var deadline = Deadline{ .remaining_ns = 0 };
    var publisher = Publisher{};
    var output: [4096]u8 = undefined;
    var result: draft.DraftAuthority = .{};
    try std.testing.expectError(error.TimedOut, draft.createWith(&authority, &executor, &publisher, &deadline, std.testing.allocator, context(), "/usr/local/bin/gh", "secret", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
    result = .{ .owner = &result, .status = .ready };
    try std.testing.expectError(error.InvalidOwner, draft.createWith(&authority, &executor, &publisher, &deadline, std.testing.allocator, context(), "/usr/local/bin/gh", "secret", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
}

test "allocation failures after remote success remain terminal and never retry" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailurePath, .{});
}

test "production draft creation surface compiles" {
    std.testing.refAllDecls(draft);
}

test "successful child with foreign capture remains remote state unknown" {
    const AlienExecutor = struct {
        calls: usize = 0,
        pub fn capture(self: *@This(), _: []const u8, _: []const []const u8, _: []const []const u8, _: []u8, _: i128) ![]const u8 {
            self.calls += 1;
            return response;
        }
    };
    var authority = Authority{};
    var executor = AlienExecutor{};
    var deadline = Deadline{};
    var publisher = Publisher{};
    var output: [4096]u8 = undefined;
    var result: draft.DraftAuthority = .{};
    try std.testing.expectError(error.InvalidCapture, draft.createWith(&authority, &executor, &publisher, &deadline, std.testing.allocator, context(), "/usr/local/bin/gh", "secret", &output, &result));
    try std.testing.expectEqual(draft.State.remote_state_unknown, result.state());
    try std.testing.expectEqual(@as(usize, 1), executor.calls);
    try std.testing.expectError(error.InvalidOwner, result.deinit());
}

fn allocationFailurePath(allocator: std.mem.Allocator) !void {
    var authority = Authority{};
    var executor = Executor{};
    var deadline = Deadline{};
    var publisher = Publisher{};
    var output: [4096]u8 = undefined;
    var result: draft.DraftAuthority = .{};
    draft.createWith(&authority, &executor, &publisher, &deadline, allocator, context(), "/usr/local/bin/gh", "secret", &output, &result) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(draft.State.remote_state_unknown, result.state());
        try std.testing.expectEqual(@as(usize, 1), executor.calls);
        try std.testing.expectError(error.InvalidOwner, result.deinit());
        return error.OutOfMemory;
    };
    try result.deinit();
}
