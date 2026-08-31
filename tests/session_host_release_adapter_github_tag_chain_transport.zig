//! GitHub tag transport owns an eight-hop chain and one deadline through downstream authentication.

const std = @import("std");
const manifest = @import("release_manifest");
const composition = @import("release_adapter_github_tag_chain_transport");

const commit = "0123456789abcdef0123456789abcdef01234567";
const shas = [_][]const u8{
    "1000000000000000000000000000000000000001", "2000000000000000000000000000000000000002",
    "3000000000000000000000000000000000000003", "4000000000000000000000000000000000000004",
    "5000000000000000000000000000000000000005", "6000000000000000000000000000000000000006",
    "7000000000000000000000000000000000000007", "8000000000000000000000000000000000000008",
    "9000000000000000000000000000000000000009",
};

fn candidate() manifest.Manifest {
    return .{ .schema = manifest.schema, .role = .a, .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" }, .release = .{ .id = 77, .tag = "v1.2.3", .version = "1.2.3" }, .source = .{ .commit = commit, .tree = "1111111111111111111111111111111111111111" }, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 }, .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 }, .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "TEAMID1234", .designated_requirement_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true }, .assets = &.{ .{ .role = .universal_dmg, .name = "a", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .size = 1 }, .{ .role = .frozen_product_executable, .name = "b", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .size = 1 }, .{ .role = .evidence_summary, .name = "c", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .size = 1 } }, .evidence = .{ .test_uuid = "123e4567-e89b-12d3-a456-426614174000", .summary_name = "c", .summary_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .result = "passed" } };
}

const Authenticated = struct {
    value_storage: manifest.Manifest,
    pub fn value(self: *const @This()) ?*const manifest.Manifest {
        return &self.value_storage;
    }
};
const Clock = struct {
    now_value: i128 = 100,
    step: i128 = 1,
    pub fn now(self: *@This()) !i128 {
        const value = self.now_value;
        self.now_value += self.step;
        return value;
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
    depth: usize,
    cycle: bool = false,
    calls: usize = 0,
    budgets: [composition.max_total_commands]i128 = @splat(0),
    pub fn capture(self: *@This(), _: []const u8, args: []const []const u8, _: []const []const u8, output: []u8, budget: i128) ![]const u8 {
        self.budgets[self.calls] = budget;
        self.calls += 1;
        if (std.mem.eql(u8, args[0], "sink")) return output[0..0];
        const endpoint = args[args.len - 1];
        var writer = std.Io.Writer.fixed(output);
        if (std.mem.indexOf(u8, endpoint, "/git/ref/tags/") != null) {
            const kind = if (self.depth == 0) "commit" else "tag";
            const sha = if (self.depth == 0) commit else shas[0];
            try writer.print("{{\"ref\":\"refs/tags/v1.2.3\",\"object\":{{\"type\":\"{s}\",\"sha\":\"{s}\"}}}}", .{ kind, sha });
        } else {
            var index: usize = 0;
            while (index < shas.len and std.mem.indexOf(u8, endpoint, shas[index]) == null) : (index += 1) {}
            if (index == shas.len) return error.UnexpectedEndpoint;
            const last = index + 1 == self.depth;
            const kind = if (self.cycle and index == 0) "tag" else if (last) "commit" else "tag";
            const next = if (self.cycle and index == 0) shas[0] else if (last) commit else shas[index + 1];
            try writer.print("{{\"tag\":\"{s}\",\"sha\":\"{s}\",\"object\":{{\"type\":\"{s}\",\"sha\":\"{s}\"}}}}", .{ if (index == 0) "v1.2.3" else "nested", shas[index], kind, next });
        }
        return writer.buffered();
    }
};

const Sink = struct {
    calls: usize = 0,
    expected_depth: usize,
    pub fn preflight(_: *@This(), result: *const usize) !void {
        if (result.* != 0) return error.InvalidOwner;
    }
    pub fn authenticate(self: *@This(), authority: anytype, executor: anytype, allocator: std.mem.Allocator, _: anytype, ref: anytype, tags: anytype, executable: [:0]const u8, _: []const u8, _: [:0]const u8, output: []u8, budget: i128, result: *usize) !void {
        self.calls += 1;
        try std.testing.expectEqual(self.expected_depth, tags.len);
        try std.testing.expectEqualStrings("v1.2.3", ref.tag);
        if (tags.len != 0) try std.testing.expectEqualStrings(shas[tags.len - 1], tags[tags.len - 1].object_sha);
        for (0..2) |_| {
            try authority.revalidate(allocator, executable);
            _ = try executor.capture(executable, &.{"sink"}, &.{}, output, budget);
        }
        result.* = tags.len + 1;
    }
};

fn run(depth: usize) !void {
    var auth = Authenticated{ .value_storage = candidate() };
    var authority = Authority{};
    var executor = Executor{ .depth = depth };
    var clock = Clock{};
    var sink = Sink{ .expected_depth = depth };
    var response: [65536]u8 = undefined;
    var result: usize = 0;
    try composition.authenticateWith(&authority, &executor, &clock, &sink, std.testing.allocator, &auth, "/opt/trusted/gh", "token", "/tmp/assets", &response, 1000, &result);
    try std.testing.expectEqual(depth + 1, result);
    try std.testing.expectEqual(depth + 3, authority.calls);
    try std.testing.expectEqual(depth + 3, executor.calls);
    for (executor.budgets[1..executor.calls], executor.budgets[0 .. executor.calls - 1]) |later, earlier| try std.testing.expect(later < earlier);
}

test "lightweight one-hop and eight-hop chains reach downstream exactly once" {
    try run(0);
    try run(1);
    try run(8);
}

test "ninth annotated object is rejected before its request and downstream" {
    var auth = Authenticated{ .value_storage = candidate() };
    var authority = Authority{};
    var executor = Executor{ .depth = 9 };
    var clock = Clock{};
    var sink = Sink{ .expected_depth = 9 };
    var response: [65536]u8 = undefined;
    var result: usize = 0;
    try std.testing.expectError(error.DepthExceeded, composition.authenticateWith(&authority, &executor, &clock, &sink, std.testing.allocator, &auth, "/opt/trusted/gh", "token", "/tmp/assets", &response, 1000, &result));
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    try std.testing.expectEqual(@as(usize, 9), executor.calls);
}

test "pre-owned result is rejected before authority or transport access" {
    var auth = Authenticated{ .value_storage = candidate() };
    var response: [65536]u8 = undefined;
    var result: usize = 1;
    var authority = Authority{};
    var executor = Executor{ .depth = 0 };
    var clock = Clock{};
    var sink = Sink{ .expected_depth = 0 };
    try std.testing.expectError(error.InvalidOwner, composition.authenticateWith(&authority, &executor, &clock, &sink, std.testing.allocator, &auth, "/opt/trusted/gh", "token", "/tmp/assets", &response, 1000, &result));
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
}

test "cycle and CLI replacement publish nothing" {
    var auth = Authenticated{ .value_storage = candidate() };
    var response: [65536]u8 = undefined;
    var result: usize = 0;
    var authority = Authority{};
    var executor = Executor{ .depth = 1, .cycle = true };
    var clock = Clock{};
    var sink = Sink{ .expected_depth = 1 };
    try std.testing.expectError(error.Cycle, composition.authenticateWith(&authority, &executor, &clock, &sink, std.testing.allocator, &auth, "/opt/trusted/gh", "token", "/tmp/assets", &response, 1000, &result));
    authority = .{ .fail_at = 1 };
    executor = .{ .depth = 0 };
    clock = .{};
    try std.testing.expectError(error.ExecutableChanged, composition.authenticateWith(&authority, &executor, &clock, &sink, std.testing.allocator, &auth, "/opt/trusted/gh", "token", "/tmp/assets", &response, 1000, &result));
}

test "single absolute deadline expires without starting a late child" {
    var auth = Authenticated{ .value_storage = candidate() };
    var authority = Authority{};
    var executor = Executor{ .depth = 1 };
    var clock = Clock{ .step = 60 };
    var sink = Sink{ .expected_depth = 1 };
    var response: [65536]u8 = undefined;
    var result: usize = 0;
    try std.testing.expectError(error.TimedOut, composition.authenticateWith(&authority, &executor, &clock, &sink, std.testing.allocator, &auth, "/opt/trusted/gh", "token", "/tmp/assets", &response, 100, &result));
    try std.testing.expectEqual(@as(usize, 1), executor.calls);
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    var absent: @import("release_adapter_github_manifest_attestation").AuthenticatedManifest = .{};
    var pinned: composition.PinnedExecutable = undefined;
    var product_result: composition.Result = .{};
    try std.testing.expectError(error.InvalidManifest, composition.authenticate(std.testing.io, std.testing.allocator, &absent, .{ .path = "/opt/trusted/gh", .pinned = &pinned }, "token", "/tmp/assets", &response, 100, &product_result));
}

test "allocation and manifest commit mismatch never reach downstream" {
    var auth = Authenticated{ .value_storage = candidate() };
    var authority = Authority{};
    var executor = Executor{ .depth = 0 };
    var clock = Clock{};
    var sink = Sink{ .expected_depth = 0 };
    var response: [65536]u8 = undefined;
    var result: usize = 0;
    var bytes: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&bytes);
    try std.testing.expectError(error.OutOfMemory, composition.authenticateWith(&authority, &executor, &clock, &sink, fixed.allocator(), &auth, "/opt/trusted/gh", "token", "/tmp/assets", &response, 1000, &result));
    try std.testing.expectEqual(@as(usize, 0), sink.calls);

    auth.value_storage.source.commit = "ffffffffffffffffffffffffffffffffffffffff";
    authority = .{};
    executor = .{ .depth = 0 };
    clock = .{};
    try std.testing.expectError(error.IdentityMismatch, composition.authenticateWith(&authority, &executor, &clock, &sink, std.testing.allocator, &auth, "/opt/trusted/gh", "token", "/tmp/assets", &response, 1000, &result));
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
}
