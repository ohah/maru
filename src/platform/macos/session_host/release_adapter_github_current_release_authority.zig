//! Authenticates the current workflow, mutable draft release and exact release tag source together.

const std = @import("std");
const c = std.c;
const manifest = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const current_authority = @import("release_adapter_github_current_authority");
const release = @import("release_adapter_github_release");
const tag_authority = @import("release_adapter_github_tag_authority");
const transport_macos = @import("release_adapter_github_transport_macos");
const cli_authority = @import("release_adapter_github_cli_authority");

pub const max_total_commands = current_authority.max_total_commands + 2 + tag_authority.max_annotated_tags;
pub const PinnedExecutable = cli_authority.PinnedExecutable;

pub const View = struct {
    repository_id: u64,
    run_id: u64,
    run_attempt: u64,
    source_commit: []const u8,
    job_id: u64,
    deployment_id: u64,
    environment_id: u64,
    protected_environment: bool,
    release_id: u64,
    tag: []const u8,
};

pub const CurrentReleaseAuthority = struct {
    owner: ?*CurrentReleaseAuthority = null,
    repository_id: u64 = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,
    source_commit: [40]u8 = @splat(0),
    job_id: u64 = 0,
    deployment_id: u64 = 0,
    environment_id: u64 = 0,
    protected_environment: bool = false,
    release_id: u64 = 0,
    tag: [manifest.max_scalar_string_bytes]u8 = @splat(0),
    tag_len: usize = 0,

    pub fn value(self: *const CurrentReleaseAuthority) ?View {
        if (self.owner != self) return null;
        return .{ .repository_id = self.repository_id, .run_id = self.run_id, .run_attempt = self.run_attempt, .source_commit = &self.source_commit, .job_id = self.job_id, .deployment_id = self.deployment_id, .environment_id = self.environment_id, .protected_environment = self.protected_environment, .release_id = self.release_id, .tag = self.tag[0..self.tag_len] };
    }
    pub fn deinit(self: *CurrentReleaseAuthority) !void {
        if (self.owner != self) return error.InvalidOwner;
        self.* = .{};
    }
};

pub const Cli = struct { path: [:0]const u8, pinned: *const PinnedExecutable };

const RealClock = struct {
    pub fn now(_: *@This()) !i128 {
        var ts: c.timespec = undefined;
        if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return error.ClockFailed;
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
};
const RealAuthority = struct {
    pinned: *const PinnedExecutable,
    pub fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};
const RealCurrentSource = struct {
    pub fn authenticate(_: *@This(), authority: anytype, executor: anytype, clock: anytype, allocator: std.mem.Allocator, expected: context_mod.Context, executable: [:0]const u8, token: []const u8, response: []u8, budget_ns: i128, result: *current_authority.CurrentGitHubAuthority) !void {
        try current_authority.authenticateWith(authority, executor, clock, allocator, expected, executable, token, response, budget_ns, result);
    }
};

pub fn authenticate(io: std.Io, allocator: std.mem.Allocator, expected: context_mod.Context, candidate: manifest.Manifest, cli: Cli, token: []const u8, response: []u8, budget_ns: i128, result: *CurrentReleaseAuthority) !void {
    var source = RealCurrentSource{};
    var authority = RealAuthority{ .pinned = cli.pinned };
    var executor = transport_macos.BoundedExecutor{ .io = io };
    var clock = RealClock{};
    return authenticateWith(&source, &authority, &executor, &clock, allocator, expected, candidate, cli.path, token, response, budget_ns, result);
}

pub fn authenticateWith(source: anytype, authority: anytype, executor: anytype, clock: anytype, allocator: std.mem.Allocator, expected: context_mod.Context, candidate: manifest.Manifest, executable: [:0]const u8, token: []const u8, response: []u8, budget_ns: i128, result: *CurrentReleaseAuthority) !void {
    if (result.owner != null) return error.InvalidOwner;
    try context_mod.bindManifest(expected, candidate);
    if (budget_ns <= 0) return error.TimedOut;
    const started = try clock.now();
    const deadline = std.math.add(i128, started, budget_ns) catch return error.TimedOut;
    var bounded = DeadlineExecutor(@TypeOf(executor), @TypeOf(clock)){ .executor = executor, .clock = clock, .deadline = deadline };

    var current: current_authority.CurrentGitHubAuthority = .{};
    try source.authenticate(authority, &bounded, clock, allocator, expected, executable, token, response, try bounded.remaining(), &current);
    defer current.deinit() catch {};
    const current_view = current.value() orelse return error.CurrentAuthorityMismatch;
    if (current_view.repository_id != candidate.repository.id or current_view.run_id != candidate.build.run_id or
        current_view.run_attempt != candidate.build.run_attempt or !std.mem.eql(u8, current_view.source_commit, candidate.source.commit) or
        !current_view.protected_environment) return error.CurrentAuthorityMismatch;

    try authority.revalidate(allocator, executable);
    const release_bytes = try transport_macos.fetchWith(&bounded, allocator, executable, token, .draft_releases, response, try bounded.remaining());
    var parsed_release = try release.parseDraftCollectionAndBind(allocator, release_bytes, .{ .id = candidate.release.id, .tag = candidate.release.tag, .publication = .draft });
    defer parsed_release.deinit();

    var resolved: tag_authority.TagAuthority = .{};
    try tag_authority.resolveWith(authority, &bounded, allocator, candidate.release.tag, candidate.source.commit, executable, token, response, try bounded.remaining(), &resolved);
    defer resolved.deinit() catch {};
    _ = resolved.value() orelse return error.InvalidOwner;

    if (candidate.release.tag.len > result.tag.len) return error.InvalidObservation;
    result.repository_id = current_view.repository_id;
    result.run_id = current_view.run_id;
    result.run_attempt = current_view.run_attempt;
    @memcpy(&result.source_commit, current_view.source_commit);
    result.job_id = current_view.job_id;
    result.deployment_id = current_view.deployment_id;
    result.environment_id = current_view.environment_id;
    result.protected_environment = true;
    result.release_id = parsed_release.observation().id;
    result.tag_len = candidate.release.tag.len;
    @memcpy(result.tag[0..result.tag_len], candidate.release.tag);
    result.owner = result;
}

fn DeadlineExecutor(comptime Executor: type, comptime Clock: type) type {
    return struct {
        executor: Executor,
        clock: Clock,
        deadline: i128,
        fn remaining(self: *@This()) !i128 {
            const now = try self.clock.now();
            if (now >= self.deadline) return error.TimedOut;
            return self.deadline - now;
        }
        pub fn capture(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, _: i128) ![]const u8 {
            return self.executor.capture(executable, args, environment, output, try self.remaining());
        }
    };
}
