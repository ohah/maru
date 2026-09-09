//! Contract tests for the read-only current Release before/after fence.

const std = @import("std");
const fence = @import("release_adapter_remote_release_fence");
const context_mod = @import("release_adapter_context");
const deadline_mod = @import("release_adapter_deadline");

const sha = "0123456789abcdef0123456789abcdef01234567";

test "same immutable Release before and after publishes one completed fence" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.begin();
    try std.testing.expect(fixture.result.candidate() != null);
    try std.testing.expect(fixture.result.value() == null);
    try fixture.verify();
    try std.testing.expectEqual(@as(u64, 88), fixture.result.value().?.release_id);
    try std.testing.expectEqual(@as(usize, 4), fixture.ops.revalidations);
    try std.testing.expectEqual(@as(usize, 2), fixture.ops.captures);
    try std.testing.expect(fixture.ops.shape_ok);
}

test "asset response order may change across the fence" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.ops.second = reordered();
    try fixture.begin();
    try fixture.verify();
    try std.testing.expect(fixture.result.value() != null);
}

test "release and every canonical asset field drift fail closed" {
    inline for (.{
        .{ "\"id\":88", "\"id\":89", false },
        .{ "1002", "1092", false },
        .{ "\"size\":102", "\"size\":103", false },
        .{ "baseline-evidence.json", "upgrade-evidence.json", false },
        .{ "cccccccc", "cecccccc", false },
    }) |change| {
        const changed = replace(baseline(), change[0], change[1]);
        defer std.testing.allocator.free(changed);
        var fixture: Fixture = .{};
        try fixture.init();
        defer fixture.deinit();
        fixture.ops.second = changed;
        try fixture.begin();
        if (change[2])
            try std.testing.expectError(error.InvalidResponse, fixture.verify())
        else
            try std.testing.expectError(error.AuthorityChanged, fixture.verify());
        try std.testing.expect(fixture.result.value() == null);
        try std.testing.expect(fixture.result.candidate() != null);
    }
}

test "malformed first or second response and timeout publish no completion" {
    var first: Fixture = .{};
    try first.init();
    defer first.deinit();
    first.ops.first = "{}";
    try std.testing.expectError(error.InvalidResponse, first.begin());
    try std.testing.expect(first.result.candidate() == null);

    var second: Fixture = .{};
    try second.init();
    defer second.deinit();
    second.ops.second = "{}";
    try second.begin();
    try std.testing.expectError(error.InvalidResponse, second.verify());
    try std.testing.expect(second.result.value() == null);

    inline for (.{
        .{ "\"tag_name\":\"v1.2.3\"", "\"tag_name\":\"v1.2.4\"" },
        .{ sha, "1123456789abcdef0123456789abcdef01234567" },
        .{ "\"draft\":false", "\"draft\":true" },
        .{ "\"prerelease\":false", "\"prerelease\":true" },
        .{ "\"immutable\":true", "\"immutable\":false" },
        .{ "\"state\":\"uploaded\"", "\"state\":\"open\"" },
        .{ "application/octet-stream", "text/plain" },
        .{ "https://api.github.com/repos/ohah/maru/", "https://api.github.com/repos/foreign/maru/" },
    }) |change| {
        const changed = replace(baseline(), change[0], change[1]);
        defer std.testing.allocator.free(changed);
        var invalid: Fixture = .{};
        try invalid.init();
        defer invalid.deinit();
        invalid.ops.second = changed;
        try invalid.begin();
        try std.testing.expectError(error.InvalidResponse, invalid.verify());
        try std.testing.expect(invalid.result.value() == null);
        try std.testing.expect(invalid.result.candidate() != null);
    }

    var expired: Fixture = .{};
    try expired.init();
    defer expired.deinit();
    expired.deadline.expires_ns = expired.deadline.started_ns;
    try std.testing.expectError(error.InvalidOwner, expired.begin());
    try std.testing.expectEqual(@as(usize, 0), expired.ops.revalidations);
    try std.testing.expectEqual(@as(usize, 0), expired.ops.captures);
}

test "CLI drift at all four fences prevents begin or completion" {
    for (1..5) |failure| {
        var fixture: Fixture = .{};
        try fixture.init();
        defer fixture.deinit();
        fixture.ops.fail_revalidate_at = failure;
        if (failure <= 2) {
            try std.testing.expectError(error.ExecutableChanged, fixture.begin());
            try std.testing.expect(fixture.result.candidate() == null);
        } else {
            try fixture.begin();
            try std.testing.expectError(error.ExecutableChanged, fixture.verify());
            try std.testing.expect(fixture.result.value() == null);
        }
    }
}

test "context deadline pinned owner and repeated verification cannot be exchanged" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.begin();
    var other_deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(10 * std.time.ns_per_s, &other_deadline);
    defer other_deadline.deinit() catch {};
    try std.testing.expectError(error.AuthorityChanged, fixture.verifyWith(context(), &other_deadline, &fixture.pinned));
    var other_pinned = fixture.pinned;
    try std.testing.expectError(error.AuthorityChanged, fixture.verifyWith(context(), &fixture.deadline, &other_pinned));
    var changed = context();
    changed.build.run_attempt = 3;
    try std.testing.expectError(error.AuthorityChanged, fixture.verifyWith(changed, &fixture.deadline, &fixture.pinned));
    try fixture.verify();
    try std.testing.expectError(error.InvalidOwner, fixture.verify());
}

test "copied mutated preowned aliased and allocation failures publish no alternate fence" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.begin();
    var copied = fixture.result;
    try std.testing.expect(copied.candidate() == null);
    fixture.result.context_seal[0] ^= 1;
    try std.testing.expect(fixture.result.candidate() == null);
    fixture.result.context_seal[0] ^= 1;

    var preowned: fence.Fence = .{ .state = .begun };
    try std.testing.expectError(error.InvalidOwner, fence.beginUntilWith(&fixture.ops, &fixture.ops, &fixture.deadline, std.testing.allocator, context(), "/fake-gh", &fixture.pinned, "token", &fixture.response, &preowned));
    var aliased: fence.Fence = .{};
    try std.testing.expectError(error.InvalidOwner, fence.beginUntilWith(&fixture.ops, &fixture.ops, &fixture.deadline, std.testing.allocator, context(), "/fake-gh", &fixture.pinned, "token", std.mem.asBytes(&aliased), &aliased));
    var deadline_alias_storage: [@sizeOf(fence.Fence)]u8 align(@alignOf(deadline_mod.Deadline)) = @splat(0);
    const deadline_alias: *fence.Fence = @ptrCast(&deadline_alias_storage);
    const aliased_deadline: *deadline_mod.Deadline = @ptrCast(&deadline_alias_storage);
    try std.testing.expectError(error.InvalidOwner, fence.beginUntilWith(&fixture.ops, &fixture.ops, aliased_deadline, std.testing.allocator, context(), "/fake-gh", &fixture.pinned, "token", &fixture.response, deadline_alias));
    var pinned_alias: fence.Fence = .{};
    const aliased_pinned: *const fence.PinnedExecutable = @ptrCast(&pinned_alias);
    try std.testing.expectError(error.InvalidOwner, fence.beginUntilWith(&fixture.ops, &fixture.ops, &fixture.deadline, std.testing.allocator, context(), "/fake-gh", aliased_pinned, "token", &fixture.response, &pinned_alias));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPath, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationVerifyPath, .{});
}

fn allocationPath(allocator: std.mem.Allocator) !void {
    var ops: Ops = .{};
    var deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(10 * std.time.ns_per_s, &deadline);
    defer deadline.deinit() catch {};
    var pinned: fence.PinnedExecutable = undefined;
    @memset(std.mem.asBytes(&pinned), 0);
    var response: [64 * 1024]u8 = undefined;
    var result: fence.Fence = .{};
    try fence.beginUntilWith(&ops, &ops, &deadline, allocator, context(), "/fake-gh", &pinned, "token", &response, &result);
    try result.deinit();
}

fn allocationVerifyPath(allocator: std.mem.Allocator) !void {
    var ops: Ops = .{};
    var deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(10 * std.time.ns_per_s, &deadline);
    defer deadline.deinit() catch {};
    var pinned: fence.PinnedExecutable = undefined;
    @memset(std.mem.asBytes(&pinned), 0);
    var response: [64 * 1024]u8 = undefined;
    var result: fence.Fence = .{};
    defer if (result.candidate() != null or result.value() != null) result.deinit() catch {};
    try fence.beginUntilWith(&ops, &ops, &deadline, allocator, context(), "/fake-gh", &pinned, "token", &response, &result);
    try fence.verifyAfterUntilWith(&ops, &ops, &deadline, allocator, context(), "/fake-gh", &pinned, "token", &response, &result);
}

const Fixture = struct {
    ops: Ops = .{},
    deadline: deadline_mod.Deadline = .{},
    pinned: fence.PinnedExecutable = undefined,
    response: [64 * 1024]u8 = undefined,
    result: fence.Fence = .{},

    fn init(self: *@This()) !void {
        if (self.deadline.owner != null) return error.InvalidOwner;
        @memset(std.mem.asBytes(&self.pinned), 0);
        try deadline_mod.start(10 * std.time.ns_per_s, &self.deadline);
    }
    fn begin(self: *@This()) !void {
        try fence.beginUntilWith(&self.ops, &self.ops, &self.deadline, std.testing.allocator, context(), "/fake-gh", &self.pinned, "token", &self.response, &self.result);
    }
    fn verify(self: *@This()) !void {
        try self.verifyWith(context(), &self.deadline, &self.pinned);
    }
    fn verifyWith(self: *@This(), ctx: context_mod.Context, deadline: *deadline_mod.Deadline, pinned: *const fence.PinnedExecutable) !void {
        try fence.verifyAfterUntilWith(&self.ops, &self.ops, deadline, std.testing.allocator, ctx, "/fake-gh", pinned, "token", &self.response, &self.result);
    }
    fn deinit(self: *@This()) void {
        if (self.result.candidate() != null or self.result.value() != null) self.result.deinit() catch {};
        if (self.deadline.owner == &self.deadline) self.deadline.deinit() catch {};
    }
};

const Ops = struct {
    first: []const u8 = baseline(),
    second: []const u8 = baseline(),
    revalidations: usize = 0,
    captures: usize = 0,
    fail_revalidate_at: usize = 0,
    shape_ok: bool = true,

    pub fn revalidate(self: *@This(), _: std.mem.Allocator, _: [:0]const u8, _: *const fence.PinnedExecutable) !void {
        self.revalidations += 1;
        if (self.revalidations == self.fail_revalidate_at) return error.ExecutableChanged;
    }
    pub fn capture(self: *@This(), _: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, _: i128) ![]const u8 {
        self.captures += 1;
        const expected_args = [_][]const u8{
            "api",
            "--method",
            "GET",
            "--hostname",
            "github.com",
            "--header",
            "Accept: application/vnd.github+json",
            "--header",
            "X-GitHub-Api-Version: 2022-11-28",
            "repos/ohah/maru/releases/tags/v1.2.3",
        };
        self.shape_ok = self.shape_ok and exactStrings(args, &expected_args) and environment.len == 2 and
            std.mem.eql(u8, environment[0], "GH_TOKEN=token") and std.mem.eql(u8, environment[1], "GH_PROMPT_DISABLED=1");
        const source = if (self.captures == 1) self.first else self.second;
        @memcpy(output[0..source.len], source);
        return output[0..source.len];
    }
};

fn exactStrings(actual: []const []const u8, expected: []const []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

fn context() context_mod.Context {
    return .{ .repository = .{ .id = 1257870483, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = sha, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 }, .protected_tag = true };
}

fn replace(source: []const u8, needle: []const u8, replacement: []const u8) []u8 {
    return std.mem.replaceOwned(u8, std.testing.allocator, source, needle, replacement) catch unreachable;
}

fn baseline() []const u8 {
    return "{\"id\":88,\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":false,\"prerelease\":false,\"immutable\":true,\"assets\":[" ++
        dmg ++ "," ++ host ++ "," ++ evidence ++ "," ++ manifest ++ "]}";
}
fn reordered() []const u8 {
    return "{\"id\":88,\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":false,\"prerelease\":false,\"immutable\":true,\"assets\":[" ++
        manifest ++ "," ++ evidence ++ "," ++ host ++ "," ++ dmg ++ "]}";
}
const dmg = "{\"id\":1000,\"name\":\"Maru-1.2.3-universal.dmg\",\"size\":100,\"state\":\"uploaded\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1000\"}";
const host = "{\"id\":1001,\"name\":\"maru-session-host-1.2.3\",\"size\":101,\"state\":\"uploaded\",\"digest\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1001\"}";
const evidence = "{\"id\":1002,\"name\":\"baseline-evidence.json\",\"size\":102,\"state\":\"uploaded\",\"digest\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1002\"}";
const manifest = "{\"id\":1003,\"name\":\"Maru-1.2.3-session-host-release.json\",\"size\":103,\"state\":\"uploaded\",\"digest\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1003\"}";
