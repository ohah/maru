const std = @import("std");
const verifier = @import("release_adapter_remote_release_verifier");

const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "closed command accepts two distinct absolute workspaces" {
    const command = try verifier.parse(&.{ "verify", "/opt/gh", sha, "/tmp/timing", "/tmp/release" });
    try std.testing.expectEqualStrings("/opt/gh", command.cli_path);
    try std.testing.expectEqualStrings("/tmp/timing", command.timing_workspace);
    try std.testing.expectEqualStrings("/tmp/release", command.release_workspace);
}

test "command vocabulary and arity are closed" {
    try std.testing.expectError(error.InvalidCommand, verifier.parse(&.{ "publish", "/opt/gh", sha, "/tmp/timing", "/tmp/release" }));
    try std.testing.expectError(error.InvalidArguments, verifier.parse(&.{ "verify", "/opt/gh", sha, "/tmp/timing" }));
}

test "paths and sha are canonical" {
    try std.testing.expectError(error.InvalidPath, verifier.parse(&.{ "verify", "gh", sha, "/tmp/timing", "/tmp/release" }));
    try std.testing.expectError(error.InvalidSha256, verifier.parse(&.{ "verify", "/opt/gh", "AA", "/tmp/timing", "/tmp/release" }));
    try std.testing.expectError(error.InvalidPath, verifier.parse(&.{ "verify", "/opt/gh", sha, "relative", "/tmp/release" }));
}

test "workspace aliases are rejected" {
    try std.testing.expectError(error.AliasedWorkspace, verifier.parse(&.{ "verify", "/opt/gh", sha, "/tmp/shared", "/tmp/shared" }));
    try std.testing.expectError(error.AliasedWorkspace, verifier.parse(&.{ "verify", "/opt/gh", sha, "/tmp/timing", "/var/tmp/release" }));
    try std.testing.expectError(error.AliasedWorkspace, verifier.parse(&.{ "verify", "/opt/gh", sha, "/tmp/timing", "/tmp/timing/release" }));
}

const Fake = struct {
    events: [16]u8 = @splat(0),
    len: usize = 0,
    fail_at: u8 = 0,
    cleanup_error: bool = false,

    fn step(self: *@This(), value: u8) !void {
        self.events[self.len] = value;
        self.len += 1;
        if (self.fail_at == value) return error.InjectedFailure;
    }
    pub fn fetchTiming(self: *@This()) !void {
        try self.step(1);
    }
    pub fn beginRelease(self: *@This()) !void {
        try self.step(2);
    }
    pub fn downloadAssets(self: *@This()) !void {
        try self.step(3);
    }
    pub fn observeRelease(self: *@This()) !void {
        try self.step(4);
    }
    pub fn bindVerdict(self: *@This()) !void {
        try self.step(5);
    }
    pub fn revalidateVerdict(self: *@This()) !void {
        try self.step(6);
    }
    pub fn cleanup(self: *@This(), completed: u8) !void {
        self.events[self.len] = 10 + completed;
        self.len += 1;
        if (self.cleanup_error) return error.CleanupFailed;
    }
};

test "product composition runs the closed order and cleans after final revalidation" {
    var fake = Fake{};
    try verifier.composeWith(&fake);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 16 }, fake.events[0..fake.len]);
}

test "every stage failure stops later calls and cleans only completed owners" {
    for (1..7) |fail_at| {
        var fake = Fake{ .fail_at = @intCast(fail_at) };
        try std.testing.expectError(error.InjectedFailure, verifier.composeWith(&fake));
        try std.testing.expectEqual(@as(usize, fail_at + 1), fake.len);
        try std.testing.expectEqual(@as(u8, @intCast(10 + fail_at - 1)), fake.events[fake.len - 1]);
        for (fake.events[0 .. fake.len - 1], 0..) |event, index| try std.testing.expectEqual(@as(u8, @intCast(index + 1)), event);
    }
}

test "cleanup failure prevents a successful verdict" {
    var fake = Fake{ .cleanup_error = true };
    try std.testing.expectError(error.CleanupFailed, verifier.composeWith(&fake));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 16 }, fake.events[0..fake.len]);
}
