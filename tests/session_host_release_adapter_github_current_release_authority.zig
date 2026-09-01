//! Current release authority publishes workflow, protected deployment, mutable draft and tag source together.

const std = @import("std");
const manifest = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const composition = @import("release_adapter_github_current_release_authority");

const commit = "0123456789abcdef0123456789abcdef01234567";
const tag_shas = [_][]const u8{
    "1000000000000000000000000000000000000001", "2000000000000000000000000000000000000002",
    "3000000000000000000000000000000000000003", "4000000000000000000000000000000000000004",
    "5000000000000000000000000000000000000005", "6000000000000000000000000000000000000006",
    "7000000000000000000000000000000000000007", "8000000000000000000000000000000000000008",
    "9000000000000000000000000000000000000009",
};

const expected: context_mod.Context = .{
    .repository = .{ .id = 1_257_870_483, .owner = "ohah", .name = "maru" },
    .tag = "v1.2.3",
    .source_commit = commit,
    .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 33_335_653_781, .run_attempt = 2 },
    .protected_tag = true,
};

fn candidate() manifest.Manifest {
    return .{
        .schema = manifest.schema,
        .role = .a,
        .repository = expected.repository,
        .release = .{ .id = 77, .tag = expected.tag, .version = "1.2.3" },
        .source = .{ .commit = commit, .tree = "1111111111111111111111111111111111111111" },
        .build = expected.build,
        .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
        .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "TEAMID1234", .designated_requirement_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
        .assets = &.{
            .{ .role = .universal_dmg, .name = "Maru.dmg", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .size = 1 },
            .{ .role = .frozen_product_executable, .name = "maru-macos-app", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .size = 1 },
            .{ .role = .evidence_summary, .name = "evidence.json", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .size = 1 },
        },
        .evidence = .{ .test_uuid = "123e4567-e89b-12d3-a456-426614174000", .summary_name = "evidence.json", .summary_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .result = "passed" },
    };
}

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
        return 20_000 - @as(i128, @intCast(self.calls * 100));
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

const CurrentSource = struct {
    const Mutation = enum { none, repository, run, attempt, source, unprotected };

    calls: usize = 0,
    fail: bool = false,
    mutation: Mutation = .none,
    pub fn authenticate(self: *@This(), authority: anytype, executor: anytype, _: anytype, allocator: std.mem.Allocator, _: context_mod.Context, executable: [:0]const u8, _: []const u8, response: []u8, budget: i128, out: anytype) !void {
        self.calls += 1;
        if (self.fail) return error.CurrentRejected;
        try authority.revalidate(allocator, executable);
        _ = try executor.capture(executable, &.{"current-authority"}, &.{}, response, budget);
        out.repository_id = expected.repository.id;
        out.run_id = expected.build.run_id;
        out.run_attempt = expected.build.run_attempt;
        @memcpy(&out.source_commit, commit);
        out.job_id = 90_618_357_140;
        out.deployment_id = 5_659_920_000;
        out.environment_id = 161_088_068;
        out.protected_environment = true;
        switch (self.mutation) {
            .none => {},
            .repository => out.repository_id += 1,
            .run => out.run_id += 1,
            .attempt => out.run_attempt += 1,
            .source => out.source_commit[0] = 'f',
            .unprotected => out.protected_environment = false,
        }
        out.owner = out;
    }

    pub fn authenticateUntil(self: *@This(), authority: anytype, executor: anytype, deadline: anytype, allocator: std.mem.Allocator, _: context_mod.Context, executable: [:0]const u8, _: []const u8, response: []u8, out: anytype) !void {
        self.calls += 1;
        if (self.fail) return error.CurrentRejected;
        _ = try deadline.remaining();
        try authority.revalidate(allocator, executable);
        const budget = try deadline.remaining();
        _ = try executor.capture(executable, &.{"current-authority"}, &.{}, response, budget);
        out.repository_id = expected.repository.id;
        out.run_id = expected.build.run_id;
        out.run_attempt = expected.build.run_attempt;
        @memcpy(&out.source_commit, commit);
        out.job_id = 90_618_357_140;
        out.deployment_id = 5_659_920_000;
        out.environment_id = 161_088_068;
        out.protected_environment = true;
        out.owner = out;
    }
};

const Executor = struct {
    depth: usize,
    cycle: bool = false,
    mutable_draft: bool = true,
    calls: usize = 0,
    budgets: [composition.max_total_commands]i128 = @splat(0),
    pub fn capture(self: *@This(), _: []const u8, args: []const []const u8, _: []const []const u8, output: []u8, budget: i128) ![]const u8 {
        self.budgets[self.calls] = budget;
        const call_index = self.calls;
        self.calls += 1;
        if (std.mem.eql(u8, args[0], "current-authority")) {
            try std.testing.expectEqual(@as(usize, 0), call_index);
            return output[0..0];
        }
        const endpoint = args[args.len - 1];
        var writer = std.Io.Writer.fixed(output);
        if (std.mem.indexOf(u8, endpoint, "/releases?per_page=100") != null) {
            try std.testing.expectEqual(@as(usize, 1), call_index);
            try writer.print("[[{{\"id\":76,\"tag_name\":\"v1.2.2\",\"draft\":false,\"prerelease\":false,\"immutable\":true}},{{\"id\":77,\"tag_name\":\"v1.2.3\",\"draft\":{s},\"prerelease\":false,\"immutable\":false}}]]", .{if (self.mutable_draft) "true" else "false"});
        } else if (std.mem.indexOf(u8, endpoint, "/git/ref/tags/") != null) {
            try std.testing.expectEqual(@as(usize, 2), call_index);
            try writer.print("{{\"ref\":\"refs/tags/v1.2.3\",\"object\":{{\"type\":\"{s}\",\"sha\":\"{s}\"}}}}", .{ if (self.depth == 0) "commit" else "tag", if (self.depth == 0) commit else tag_shas[0] });
        } else {
            var index: usize = 0;
            while (index < tag_shas.len and std.mem.indexOf(u8, endpoint, tag_shas[index]) == null) : (index += 1) {}
            if (index == tag_shas.len) return error.UnexpectedEndpoint;
            try std.testing.expectEqual(3 + index, call_index);
            const last = index + 1 == self.depth;
            const kind = if (self.cycle and index == 0) "tag" else if (last) "commit" else "tag";
            const next = if (self.cycle and index == 0) tag_shas[0] else if (last) commit else tag_shas[index + 1];
            try writer.print("{{\"tag\":\"{s}\",\"sha\":\"{s}\",\"object\":{{\"type\":\"{s}\",\"sha\":\"{s}\"}}}}", .{ if (index == 0) "v1.2.3" else "nested", tag_shas[index], kind, next });
        }
        return writer.buffered();
    }
};

fn run(allocator: std.mem.Allocator, depth: usize, result: *composition.CurrentReleaseAuthority) !void {
    var source = CurrentSource{};
    var authority = Authority{};
    var executor = Executor{ .depth = depth };
    var clock = Clock{};
    var response: [65536]u8 = undefined;
    try composition.authenticateWith(&source, &authority, &executor, &clock, allocator, expected, candidate(), "/opt/trusted/gh", "token", &response, 10_000, result);
    try std.testing.expectEqual(@as(usize, 1), source.calls);
    try std.testing.expectEqual(depth + 3, executor.calls);
    try std.testing.expectEqual(executor.calls, authority.calls);
    for (executor.budgets[1..executor.calls], executor.budgets[0 .. executor.calls - 1]) |later, earlier| try std.testing.expect(later < earlier);
}

fn allocationHarness(allocator: std.mem.Allocator) !void {
    var result: composition.CurrentReleaseAuthority = .{};
    try run(allocator, 8, &result);
    try result.deinit();
}

test "lightweight one-hop and eight-hop chains publish one exact current release authority" {
    for ([_]usize{ 0, 1, 8 }) |depth| {
        var result: composition.CurrentReleaseAuthority = .{};
        try run(std.testing.allocator, depth, &result);
        defer result.deinit() catch {};
        const value = result.value().?;
        try std.testing.expectEqual(@as(u64, 77), value.release_id);
        try std.testing.expectEqualStrings("v1.2.3", value.tag);
        try std.testing.expectEqualStrings(commit, value.source_commit);
        try std.testing.expect(value.protected_environment);
    }
}

test "context draft depth and cycle mismatch never publish partial current authority" {
    var source = CurrentSource{};
    var authority = Authority{};
    var executor = Executor{ .depth = 0, .mutable_draft = false };
    var clock = Clock{};
    var response: [65536]u8 = undefined;
    var result: composition.CurrentReleaseAuthority = .{};
    try std.testing.expectError(error.ReleaseMismatch, composition.authenticateWith(&source, &authority, &executor, &clock, std.testing.allocator, expected, candidate(), "/opt/trusted/gh", "token", &response, 1000, &result));
    try std.testing.expect(result.value() == null);
    source = .{ .fail = true };
    authority = .{};
    executor = .{ .depth = 0 };
    clock = .{};
    try std.testing.expectError(error.CurrentRejected, composition.authenticateWith(&source, &authority, &executor, &clock, std.testing.allocator, expected, candidate(), "/opt/trusted/gh", "token", &response, 1000, &result));
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
    executor = .{ .depth = 9 };
    authority = .{};
    source = .{};
    clock = .{};
    try std.testing.expectError(error.DepthExceeded, composition.authenticateWith(&source, &authority, &executor, &clock, std.testing.allocator, expected, candidate(), "/opt/trusted/gh", "token", &response, 1000, &result));
    try std.testing.expectEqual(@as(usize, 11), executor.calls);
    executor = .{ .depth = 1, .cycle = true };
    authority = .{};
    source = .{};
    clock = .{};
    try std.testing.expectError(error.Cycle, composition.authenticateWith(&source, &authority, &executor, &clock, std.testing.allocator, expected, candidate(), "/opt/trusted/gh", "token", &response, 1000, &result));
    var foreign = candidate();
    foreign.source.commit = "ffffffffffffffffffffffffffffffffffffffff";
    executor = .{ .depth = 0 };
    authority = .{};
    source = .{};
    clock = .{};
    try std.testing.expectError(error.ManifestMismatch, composition.authenticateWith(&source, &authority, &executor, &clock, std.testing.allocator, expected, foreign, "/opt/trusted/gh", "token", &response, 1000, &result));
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
}

test "every current authority identity and protection mismatch publishes nothing" {
    var authority = Authority{};
    var executor = Executor{ .depth = 0 };
    var clock = Clock{};
    var response: [65536]u8 = undefined;
    var result: composition.CurrentReleaseAuthority = .{};
    for ([_]CurrentSource.Mutation{ .repository, .run, .attempt, .source, .unprotected }) |mutation| {
        var source = CurrentSource{ .mutation = mutation };
        authority = .{};
        executor = .{ .depth = 0 };
        clock = .{};
        try std.testing.expectError(error.CurrentAuthorityMismatch, composition.authenticateWith(&source, &authority, &executor, &clock, std.testing.allocator, expected, candidate(), "/opt/trusted/gh", "token", &response, 1000, &result));
        try std.testing.expectEqual(@as(usize, 1), executor.calls);
        try std.testing.expect(result.value() == null);
    }
}

test "pre-owned copy CLI replacement and deadline publish nothing" {
    var response: [65536]u8 = undefined;
    var result: composition.CurrentReleaseAuthority = .{};
    result.owner = &result;
    var source = CurrentSource{};
    var authority = Authority{};
    var executor = Executor{ .depth = 0 };
    var clock = Clock{};
    try std.testing.expectError(error.InvalidOwner, composition.authenticateWith(&source, &authority, &executor, &clock, std.testing.allocator, expected, candidate(), "/opt/trusted/gh", "token", &response, 1000, &result));
    try std.testing.expectEqual(@as(usize, 0), source.calls);
    result = .{};
    for (1..12) |fail_at| {
        source = .{};
        authority = .{ .fail_at = fail_at };
        executor = .{ .depth = 8 };
        clock = .{};
        try std.testing.expectError(error.ExecutableChanged, composition.authenticateWith(&source, &authority, &executor, &clock, std.testing.allocator, expected, candidate(), "/opt/trusted/gh", "token", &response, 1000, &result));
        try std.testing.expectEqual(fail_at - 1, executor.calls);
        try std.testing.expect(result.value() == null);
    }
    source = .{};
    authority = .{};
    executor = .{ .depth = 1 };
    clock = .{ .step = 400 };
    try std.testing.expectError(error.TimedOut, composition.authenticateWith(&source, &authority, &executor, &clock, std.testing.allocator, expected, candidate(), "/opt/trusted/gh", "token", &response, 1000, &result));
    try std.testing.expect(result.value() == null);
    try run(std.testing.allocator, 0, &result);
    defer result.deinit() catch {};
    var copied = result;
    try std.testing.expect(copied.value() == null);
    var pinned: composition.PinnedExecutable = undefined;
    var occupied: composition.CurrentReleaseAuthority = .{ .owner = undefined };
    occupied.owner = &occupied;
    try std.testing.expectError(error.InvalidOwner, composition.authenticate(std.testing.io, std.testing.allocator, expected, candidate(), .{ .path = "/opt/trusted/gh", .pinned = &pinned }, "token", &response, 1000, &occupied));
}

test "every successful allocation failure unwinds without publication" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationHarness, .{});
}

test "current authority draft and tag chain share one absolute deadline" {
    var response: [65536]u8 = undefined;
    for ([_]usize{ 0, 1, 8 }) |depth| {
        var source = CurrentSource{};
        var authority = Authority{};
        var executor = Executor{ .depth = depth };
        var deadline = SharedDeadline{};
        var result: composition.CurrentReleaseAuthority = .{};
        try composition.authenticateUntilWith(&source, &authority, &executor, &deadline, std.testing.allocator, expected, candidate(), "/opt/trusted/gh", "token", &response, &result);
        try std.testing.expectEqual((depth + 3) * 2 + 1, deadline.calls);
        try std.testing.expectEqual(depth + 3, executor.calls);
        for (executor.budgets[0..executor.calls], 1..) |budget, index|
            try std.testing.expectEqual(20_000 - @as(i128, @intCast(index * 200)), budget);
        try result.deinit();
    }

    var source = CurrentSource{};
    var authority = Authority{};
    var executor = Executor{ .depth = 1 };
    var deadline = SharedDeadline{ .fail_at = 6 };
    var result: composition.CurrentReleaseAuthority = .{};
    try std.testing.expectError(error.TimedOut, composition.authenticateUntilWith(&source, &authority, &executor, &deadline, std.testing.allocator, expected, candidate(), "/opt/trusted/gh", "token", &response, &result));
    try std.testing.expectEqual(@as(usize, 2), executor.calls);
    try std.testing.expectEqual(@as(usize, 3), authority.calls);
    try std.testing.expect(result.value() == null);

    source = .{};
    authority = .{};
    executor = .{ .depth = 1 };
    deadline = .{ .fail_at = 5 };
    try std.testing.expectError(error.TimedOut, composition.authenticateUntilWith(&source, &authority, &executor, &deadline, std.testing.allocator, expected, candidate(), "/opt/trusted/gh", "token", &response, &result));
    try std.testing.expectEqual(@as(usize, 2), executor.calls);
    try std.testing.expectEqual(@as(usize, 2), authority.calls);
    try std.testing.expect(result.value() == null);

    source = .{};
    authority = .{};
    executor = .{ .depth = 1 };
    deadline = .{ .fail_at = 9 };
    try std.testing.expectError(error.TimedOut, composition.authenticateUntilWith(&source, &authority, &executor, &deadline, std.testing.allocator, expected, candidate(), "/opt/trusted/gh", "token", &response, &result));
    try std.testing.expectEqual(@as(usize, 4), executor.calls);
    try std.testing.expectEqual(@as(usize, 4), authority.calls);
    try std.testing.expect(result.value() == null);
}
