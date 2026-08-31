//! Fetches a bounded GitHub tag chain and hands owned observations to predecessor authentication.

const std = @import("std");
const c = std.c;
const manifest = @import("release_manifest");
const git = @import("release_adapter_github_git");
const resolver = @import("release_adapter_git_resolver");
const transport_macos = @import("release_adapter_github_transport_macos");
const predecessor_assets = @import("release_adapter_github_predecessor_assets");
const manifest_attestation = @import("release_adapter_github_manifest_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");

pub const max_annotated_tags: usize = 8;
pub const max_total_commands: usize = 1 + max_annotated_tags + 7;
pub const Result = predecessor_assets.AuthenticatedPredecessorAssets;
pub const PinnedExecutable = cli_authority.PinnedExecutable;
pub const Error = error{ InvalidManifest, DepthExceeded, ClockFailed, TimedOut, InvalidObservation };

const OwnedRef = struct {
    tag: [manifest.max_scalar_string_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    kind: git.ObjectKind = .commit,
    sha: [40]u8 = @splat(0),
    fn observation(self: *const @This()) git.RefObservation {
        return .{ .tag = self.tag[0..self.tag_len], .target = .{ .kind = self.kind, .sha = &self.sha } };
    }
};
const OwnedTag = struct {
    tag: [manifest.max_scalar_string_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    object_sha: [40]u8 = @splat(0),
    kind: git.ObjectKind = .commit,
    target_sha: [40]u8 = @splat(0),
    fn observation(self: *const @This()) git.TagObservation {
        return .{ .tag = self.tag[0..self.tag_len], .object_sha = &self.object_sha, .target = .{ .kind = self.kind, .sha = &self.target_sha } };
    }
};

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

    try authority.revalidate(allocator, executable);
    const ref_bytes = try transport_macos.fetchWith(&bounded, allocator, executable, token, .{ .tag_ref = candidate.release.tag }, response, budget_ns);
    var parsed_ref = try git.parseRef(allocator, ref_bytes, candidate.release.tag);
    defer parsed_ref.deinit();
    var owned_ref = try ownRef(parsed_ref.observation().*);

    var owned_tags: [max_annotated_tags]OwnedTag = @splat(.{});
    var observations: [max_annotated_tags]git.TagObservation = undefined;
    var count: usize = 0;
    var visited: [max_annotated_tags]resolver.Sha = undefined;
    var backing: resolver.Backing = undefined;
    try backing.init(&visited);
    var chain: resolver.Resolver = undefined;
    try chain.init(candidate.source.commit, &backing);
    try chain.acceptRef(owned_ref.observation(), candidate.release.tag);
    while (true) {
        const next = chain.nextTag() catch |err| switch (err) {
            error.InvalidState => break,
            else => return err,
        };
        if (count == max_annotated_tags) return error.DepthExceeded;
        try authority.revalidate(allocator, executable);
        const tag_bytes = try transport_macos.fetchWith(&bounded, allocator, executable, token, .{ .annotated_tag = next.objectSha() }, response, budget_ns);
        var parsed_tag = try git.parseTag(allocator, tag_bytes, .{ .tag = if (count == 0) candidate.release.tag else null, .object_sha = next.objectSha() });
        defer parsed_tag.deinit();
        owned_tags[count] = try ownTag(parsed_tag.observation().*);
        observations[count] = owned_tags[count].observation();
        try chain.acceptTag(observations[count]);
        count += 1;
    }
    _ = try chain.result();
    const remaining = try bounded.remaining();
    try sink.authenticate(authority, &bounded, allocator, authenticated, owned_ref.observation(), observations[0..count], executable, token, workdir, response, remaining, result);
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

fn ownRef(value: git.RefObservation) !OwnedRef {
    var out: OwnedRef = .{ .tag_len = value.tag.len, .kind = value.target.kind };
    if (value.tag.len > out.tag.len or value.target.sha.len != 40) return error.InvalidObservation;
    @memcpy(out.tag[0..value.tag.len], value.tag);
    @memcpy(&out.sha, value.target.sha);
    return out;
}
fn ownTag(value: git.TagObservation) !OwnedTag {
    var out: OwnedTag = .{ .tag_len = value.tag.len, .kind = value.target.kind };
    if (value.tag.len > out.tag.len or value.object_sha.len != 40 or value.target.sha.len != 40) return error.InvalidObservation;
    @memcpy(out.tag[0..value.tag.len], value.tag);
    @memcpy(&out.object_sha, value.object_sha);
    @memcpy(&out.target_sha, value.target.sha);
    return out;
}
