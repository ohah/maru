//! Binds one trusted workflow source commit to its GitHub-owned tree without consulting checkout state.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const source_tree = @import("release_adapter_github_source_tree");

const commit = "0123456789abcdef0123456789abcdef01234567";
const tree = "89abcdef0123456789abcdef0123456789abcdef";
const good_response = "{\"sha\":\"" ++ commit ++ "\",\"tree\":{\"sha\":\"" ++ tree ++ "\"}}";

fn context() context_mod.Context {
    return .{
        .repository = .{ .id = 55, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = commit,
        .build = .{
            .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
            .run_id = 7,
            .run_attempt = 1,
        },
        .protected_tag = true,
    };
}

const Deadline = struct {
    calls: usize = 0,
    fail_at: usize = 0,
    pub fn remaining(self: *@This()) !i128 {
        self.calls += 1;
        if (self.calls == self.fail_at) return error.TimedOut;
        return 1_000 - @as(i128, @intCast(self.calls * 100));
    }
};

const Authority = struct {
    calls: usize = 0,
    fail_at: usize = 0,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, executable: [:0]const u8) !void {
        self.calls += 1;
        try std.testing.expectEqualStrings("/opt/trusted/gh", executable);
        if (self.calls == self.fail_at) return error.ExecutableChanged;
    }
};

const Fetcher = struct {
    response: []const u8 = good_response,
    calls: usize = 0,
    foreign: bool = false,
    last_budget: i128 = 0,
    pub fn fetch(self: *@This(), _: std.mem.Allocator, executable: []const u8, token: []const u8, request: anytype, output: []u8, budget: i128) ![]const u8 {
        self.calls += 1;
        self.last_budget = budget;
        try std.testing.expectEqualStrings("/opt/trusted/gh", executable);
        try std.testing.expectEqualStrings("token", token);
        switch (request) {
            .commit => |sha| try std.testing.expectEqualStrings(commit, sha),
            else => return error.WrongRequest,
        }
        if (self.foreign) return self.response;
        if (self.response.len > output.len) return error.ResponseTooLarge;
        @memcpy(output[0..self.response.len], self.response);
        return output[0..self.response.len];
    }
};

test "trusted source publishes exact GitHub commit and tree authority" {
    var authority = Authority{};
    var fetcher = Fetcher{};
    var deadline = Deadline{};
    var output: [8192]u8 = undefined;
    var result: source_tree.SourceTreeAuthority = .{};
    try source_tree.observeWith(&authority, &fetcher, &deadline, std.testing.allocator, context(), "/opt/trusted/gh", "token", &output, &result);
    const view = result.value().?;
    try std.testing.expectEqualStrings(commit, view.commit);
    try std.testing.expectEqualStrings(tree, view.tree);
    try std.testing.expectEqual(@as(usize, 2), authority.calls);
    try std.testing.expectEqual(@as(usize, 1), fetcher.calls);
    try std.testing.expectEqual(@as(usize, 3), deadline.calls);
    try std.testing.expectEqual(@as(i128, 800), fetcher.last_budget);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try std.testing.expectError(error.InvalidOwner, copied.deinit());
    try result.deinit();
}

test "invalid context preowned result and output alias start no authority" {
    var authority = Authority{};
    var fetcher = Fetcher{};
    var deadline = Deadline{};
    var output: [8192]u8 = undefined;
    var result: source_tree.SourceTreeAuthority = .{};
    var invalid = context();
    invalid.build.workflow_ref = "ohah/maru/.github/workflows/foreign.yml@refs/tags/v1.2.3";
    try std.testing.expectError(error.InvalidContext, source_tree.observeWith(&authority, &fetcher, &deadline, std.testing.allocator, invalid, "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), deadline.calls);
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, source_tree.observeWith(&authority, &fetcher, &deadline, std.testing.allocator, context(), "/opt/trusted/gh", "token", &output, &result));
    result = .{};
    const aliased = std.mem.asBytes(&result);
    try std.testing.expectError(error.InvalidInput, source_tree.observeWith(&authority, &fetcher, &deadline, std.testing.allocator, context(), "/opt/trusted/gh", "token", aliased, &result));
    const deadline_alias = std.mem.asBytes(&deadline);
    try std.testing.expectError(error.InvalidInput, source_tree.observeWith(&authority, &fetcher, &deadline, std.testing.allocator, context(), "/opt/trusted/gh", "token", deadline_alias, &result));
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
    try std.testing.expectEqual(@as(usize, 0), fetcher.calls);
}

test "malformed duplicate missing and identity drift publish nothing" {
    const responses = [_][]const u8{
        "{}",
        "{\"sha\":\"" ++ commit ++ "\",\"sha\":\"" ++ commit ++ "\",\"tree\":{\"sha\":\"" ++ tree ++ "\"}}",
        "{\"sha\":7,\"tree\":{\"sha\":\"" ++ tree ++ "\"}}",
        "{\"sha\":\"1123456789abcdef0123456789abcdef01234567\",\"tree\":{\"sha\":\"" ++ tree ++ "\"}}",
        "{\"sha\":\"" ++ commit ++ "\",\"tree\":{\"sha\":\"XYZ\"}}",
    };
    for (responses) |response| {
        var authority = Authority{};
        var fetcher = Fetcher{ .response = response };
        var deadline = Deadline{};
        var output: [8192]u8 = undefined;
        var result: source_tree.SourceTreeAuthority = .{};
        try std.testing.expectError(error.InvalidResponse, source_tree.observeWith(&authority, &fetcher, &deadline, std.testing.allocator, context(), "/opt/trusted/gh", "token", &output, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "deadline CLI and foreign capture failures publish nothing" {
    inline for (1..4) |fail_at| {
        var authority = Authority{};
        var fetcher = Fetcher{};
        var deadline = Deadline{ .fail_at = fail_at };
        var output: [8192]u8 = undefined;
        var result: source_tree.SourceTreeAuthority = .{};
        try std.testing.expectError(error.TimedOut, source_tree.observeWith(&authority, &fetcher, &deadline, std.testing.allocator, context(), "/opt/trusted/gh", "token", &output, &result));
        try std.testing.expect(result.value() == null);
    }
    var authority = Authority{ .fail_at = 2 };
    var fetcher = Fetcher{};
    var deadline = Deadline{};
    var output: [8192]u8 = undefined;
    var result: source_tree.SourceTreeAuthority = .{};
    try std.testing.expectError(error.ExecutableChanged, source_tree.observeWith(&authority, &fetcher, &deadline, std.testing.allocator, context(), "/opt/trusted/gh", "token", &output, &result));
    fetcher = .{ .foreign = true };
    authority = .{};
    deadline = .{};
    try std.testing.expectError(error.InvalidCapture, source_tree.observeWith(&authority, &fetcher, &deadline, std.testing.allocator, context(), "/opt/trusted/gh", "token", &output, &result));
}

test "every successful allocation failure leaves no source tree owner" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var authority = Authority{};
            var fetcher = Fetcher{};
            var deadline = Deadline{};
            var output: [8192]u8 = undefined;
            var result: source_tree.SourceTreeAuthority = .{};
            source_tree.observeWith(&authority, &fetcher, &deadline, allocator, context(), "/opt/trusted/gh", "token", &output, &result) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return err,
            };
            try result.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "production source tree surface compiles" {
    _ = source_tree.observe;
}
