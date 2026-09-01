//! Fetches a bounded GitHub tag chain and hands owned observations to predecessor authentication.

const std = @import("std");
const c = std.c;
const git = @import("release_adapter_github_git");
const tag_authority = @import("release_adapter_github_tag_authority");
const transport_macos = @import("release_adapter_github_transport_macos");
const predecessor_assets = @import("release_adapter_github_predecessor_assets");
const manifest_attestation = @import("release_adapter_github_manifest_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");

pub const max_annotated_tags = tag_authority.max_annotated_tags;
pub const max_total_commands: usize = 1 + max_annotated_tags + 7;
pub const Result = predecessor_assets.AuthenticatedPredecessorAssets;
pub const PinnedExecutable = cli_authority.PinnedExecutable;
pub const Error = error{ InvalidManifest, DepthExceeded, ClockFailed, TimedOut, InvalidObservation };

const RealClock = struct {
    fn now(_: *@This()) !i128 {
        var ts: c.timespec = undefined;
        if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return error.ClockFailed;
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
};
const RealAuthority = struct {
    pinned: *const cli_authority.PinnedExecutable,
    pub fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};
const ProductSink = struct {
    pub fn preflight(_: *@This(), result: *const predecessor_assets.AuthenticatedPredecessorAssets) !void {
        if (result.owner != null or result.downloads.owner != null) return error.InvalidOwner;
    }
    fn authenticate(_: *@This(), authority: anytype, executor: anytype, allocator: std.mem.Allocator, authenticated: anytype, ref: git.RefObservation, tags: []const git.TagObservation, executable: [:0]const u8, token: []const u8, workdir: [:0]const u8, output: []u8, budget_ns: i128, result: *predecessor_assets.AuthenticatedPredecessorAssets) !void {
        try predecessor_assets.composeWith(authority, executor, allocator, authenticated, ref, tags, executable, token, workdir, output, budget_ns, result);
    }
};

pub const Cli = struct { path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable };

pub fn authenticate(io: std.Io, allocator: std.mem.Allocator, authenticated: *const manifest_attestation.AuthenticatedManifest, cli: Cli, token: []const u8, workdir: [:0]const u8, response: []u8, budget_ns: i128, result: *Result) !void {
    var authority = RealAuthority{ .pinned = cli.pinned };
    var executor = transport_macos.BoundedExecutor{ .io = io };
    var clock = RealClock{};
    var sink = ProductSink{};
    return authenticateWith(&authority, &executor, &clock, &sink, allocator, authenticated, cli.path, token, workdir, response, budget_ns, result);
}

pub fn authenticateWith(authority: anytype, executor: anytype, clock: anytype, sink: anytype, allocator: std.mem.Allocator, authenticated: anytype, executable: [:0]const u8, token: []const u8, workdir: [:0]const u8, response: []u8, budget_ns: i128, result: anytype) !void {
    try sink.preflight(result);
    const candidate = authenticated.value() orelse return error.InvalidManifest;
    if (budget_ns <= 0) return error.TimedOut;
    const started = try clock.now();
    const deadline = std.math.add(i128, started, budget_ns) catch return error.TimedOut;
    var bounded = DeadlineExecutor(@TypeOf(executor), @TypeOf(clock)){ .executor = executor, .clock = clock, .deadline = deadline };

    var resolved: tag_authority.TagAuthority = .{};
    try tag_authority.resolveWith(authority, &bounded, allocator, candidate.release.tag, candidate.source.commit, executable, token, response, budget_ns, &resolved);
    defer resolved.deinit() catch {};
    const resolved_view = resolved.value() orelse return error.InvalidObservation;
    const remaining = try bounded.remaining();
    try sink.authenticate(authority, &bounded, allocator, authenticated, resolved_view.ref, resolved_view.tags, executable, token, workdir, response, remaining, result);
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
