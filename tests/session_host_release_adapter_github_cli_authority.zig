//! Official Release CI의 runner identity와 checkout 전 고정한 gh executable을 결속한다.
//! 로컬 upgrade를 검증하는 gate가 아니며 workflow wiring 자체도 증명하지 않는다.

const std = @import("std");
const authority = @import("release_adapter_github_cli_authority");

const sha = "0123456789abcdef0123456789abcdef01234567";

const RunnerLookup = struct {
    values: [4][]const u8 = .{ sha, "github-hosted", "macOS", "ARM64" },
    calls: [4][]const u8 = @splat(""),
    count: usize = 0,
    missing: ?usize = null,

    pub fn get(self: *@This(), name: [:0]const u8) ?[]const u8 {
        const index = self.count;
        self.calls[index] = name;
        self.count += 1;
        if (self.missing == index) return null;
        return self.values[index];
    }
};

test "accepts exact GitHub-hosted macOS ARM64 workflow authority" {
    var lookup = RunnerLookup{};
    const observed = try authority.readRunner(&lookup, sha);
    try std.testing.expectEqualStrings(sha, &observed.workflow_sha);
    try std.testing.expectEqual(authority.required_runner_names.len, lookup.count);
    for (authority.required_runner_names, lookup.calls) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual);
}

test "rejects foreign workflow and non GitHub-hosted runner" {
    try std.testing.expectError(error.ForeignWorkflow, authority.validateRunner(.{
        .workflow_sha = "1123456789abcdef0123456789abcdef01234567",
        .runner_environment = "github-hosted",
        .runner_os = "macOS",
        .runner_arch = "ARM64",
    }, sha));
    try std.testing.expectError(error.UntrustedRunner, authority.validateRunner(.{
        .workflow_sha = sha,
        .runner_environment = "self-hosted",
        .runner_os = "macOS",
        .runner_arch = "ARM64",
    }, sha));
}

test "rejects wrong runner platform and malformed source sha" {
    try std.testing.expectError(error.UntrustedRunner, authority.validateRunner(.{
        .workflow_sha = sha,
        .runner_environment = "github-hosted",
        .runner_os = "Linux",
        .runner_arch = "ARM64",
    }, sha));
    try std.testing.expectError(error.InvalidSha, authority.validateRunner(.{
        .workflow_sha = "bad",
        .runner_environment = "github-hosted",
        .runner_os = "macOS",
        .runner_arch = "ARM64",
    }, "bad"));
    var missing = RunnerLookup{ .missing = 2 };
    try std.testing.expectError(error.MissingKey, authority.readRunner(&missing, sha));
    var control = RunnerLookup{};
    control.values[1] = "github-hosted\n";
    try std.testing.expectError(error.InvalidScalar, authority.readRunner(&control, sha));
    _ = authority.readCurrentRunner(sha) catch {};
}

test "pins executable bytes and accepts unchanged revalidation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gh", .data = "trusted-gh" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "gh", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path.ptr, 0o700));
    const pinned = try authority.pin(std.testing.allocator, path, "f6d97bdb40d0d71bd1f0424dedfbae0927373c93ba3fb18f67300d8fc41e7176");
    try authority.revalidate(std.testing.allocator, path, &pinned);
}

test "rejects executable mutation and symlink capture" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gh", .data = "trusted-gh" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "gh", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.NotExecutable, authority.pin(
        std.testing.allocator,
        path,
        "f6d97bdb40d0d71bd1f0424dedfbae0927373c93ba3fb18f67300d8fc41e7176",
    ));
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path.ptr, 0o700));
    const pinned = try authority.pin(std.testing.allocator, path, "f6d97bdb40d0d71bd1f0424dedfbae0927373c93ba3fb18f67300d8fc41e7176");
    try tmp.dir.hardLink("gh", tmp.dir, "hardlink", std.testing.io, .{});
    const hardlink = try tmp.dir.realPathFileAlloc(std.testing.io, "hardlink", std.testing.allocator);
    defer std.testing.allocator.free(hardlink);
    try std.testing.expectError(error.ExecutableChanged, authority.revalidate(std.testing.allocator, hardlink, &pinned));
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path.ptr, 0o600));
    try std.testing.expectError(error.NotExecutable, authority.revalidate(std.testing.allocator, path, &pinned));
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path.ptr, 0o700));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gh", .data = "changed-gh" });
    try std.testing.expectError(error.ExecutableChanged, authority.revalidate(std.testing.allocator, path, &pinned));
    try tmp.dir.symLink(std.testing.io, "gh", "alias", .{});
    const alias = try std.fs.path.joinZ(std.testing.allocator, &.{ std.fs.path.dirname(path).?, "alias" });
    defer std.testing.allocator.free(alias);
    try std.testing.expectError(error.UnsafePath, authority.pin(
        std.testing.allocator,
        alias,
        "f6d97bdb40d0d71bd1f0424dedfbae0927373c93ba3fb18f67300d8fc41e7176",
    ));
}
