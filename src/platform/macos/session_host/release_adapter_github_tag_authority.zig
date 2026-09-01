//! Resolves one bounded GitHub release tag to its exact manifest source commit.

const std = @import("std");
const manifest = @import("release_manifest");
const git = @import("release_adapter_github_git");
const resolver = @import("release_adapter_git_resolver");
const transport_macos = @import("release_adapter_github_transport_macos");

pub const max_annotated_tags: usize = 8;

const OwnedRef = struct {
    tag: [manifest.max_scalar_string_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    kind: git.ObjectKind = .commit,
    sha: [40]u8 = @splat(0),
    fn observation(self: *const OwnedRef) git.RefObservation {
        return .{ .tag = self.tag[0..self.tag_len], .target = .{ .kind = self.kind, .sha = &self.sha } };
    }
};

const OwnedTag = struct {
    tag: [manifest.max_scalar_string_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    object_sha: [40]u8 = @splat(0),
    kind: git.ObjectKind = .commit,
    target_sha: [40]u8 = @splat(0),
    fn observation(self: *const OwnedTag) git.TagObservation {
        return .{ .tag = self.tag[0..self.tag_len], .object_sha = &self.object_sha, .target = .{ .kind = self.kind, .sha = &self.target_sha } };
    }
};

pub const View = struct { ref: git.RefObservation, tags: []const git.TagObservation };

pub const TagAuthority = struct {
    owner: ?*TagAuthority = null,
    owned_ref: OwnedRef = .{},
    owned_tags: [max_annotated_tags]OwnedTag = @splat(.{}),
    observations: [max_annotated_tags]git.TagObservation = undefined,
    count: usize = 0,

    pub fn value(self: *const TagAuthority) ?View {
        if (self.owner != self) return null;
        return .{ .ref = self.owned_ref.observation(), .tags = self.observations[0..self.count] };
    }
    pub fn deinit(self: *TagAuthority) !void {
        if (self.owner != self) return error.InvalidOwner;
        self.* = .{};
    }
};

pub fn resolveWith(authority: anytype, executor: anytype, allocator: std.mem.Allocator, expected_tag: []const u8, expected_commit: []const u8, executable: [:0]const u8, token: []const u8, response: []u8, budget_ns: i128, result: *TagAuthority) !void {
    var fixed = FixedBudget{ .value = budget_ns };
    return resolveUntilWith(authority, executor, &fixed, allocator, expected_tag, expected_commit, executable, token, response, result);
}

pub fn resolveUntilWith(authority: anytype, executor: anytype, deadline: anytype, allocator: std.mem.Allocator, expected_tag: []const u8, expected_commit: []const u8, executable: [:0]const u8, token: []const u8, response: []u8, result: *TagAuthority) !void {
    if (result.owner != null) return error.InvalidOwner;
    const ref_bytes = try fetchUntil(authority, executor, deadline, allocator, executable, token, .{ .tag_ref = expected_tag }, response);
    var parsed_ref = try git.parseRef(allocator, ref_bytes, expected_tag);
    defer parsed_ref.deinit();
    const owned_ref = try ownRef(parsed_ref.observation().*);

    var owned_tags: [max_annotated_tags]OwnedTag = @splat(.{});
    var transient: [max_annotated_tags]git.TagObservation = undefined;
    var visited: [max_annotated_tags]resolver.Sha = undefined;
    var backing: resolver.Backing = undefined;
    try backing.init(&visited);
    var chain: resolver.Resolver = undefined;
    try chain.init(expected_commit, &backing);
    try chain.acceptRef(owned_ref.observation(), expected_tag);
    var count: usize = 0;
    while (true) {
        const next = chain.nextTag() catch |err| switch (err) {
            error.InvalidState => break,
            else => return err,
        };
        if (count == max_annotated_tags) return error.DepthExceeded;
        const tag_bytes = try fetchUntil(authority, executor, deadline, allocator, executable, token, .{ .annotated_tag = next.objectSha() }, response);
        var parsed_tag = try git.parseTag(allocator, tag_bytes, .{ .tag = if (count == 0) expected_tag else null, .object_sha = next.objectSha() });
        defer parsed_tag.deinit();
        owned_tags[count] = try ownTag(parsed_tag.observation().*);
        transient[count] = owned_tags[count].observation();
        try chain.acceptTag(transient[count]);
        count += 1;
    }
    _ = try chain.result();

    result.owned_ref = owned_ref;
    result.owned_tags = owned_tags;
    result.count = count;
    for (0..count) |index| result.observations[index] = result.owned_tags[index].observation();
    result.owner = result;
}

const FixedBudget = struct {
    value: i128,
    pub fn remaining(self: *@This()) !i128 {
        if (self.value <= 0) return error.TimedOut;
        return self.value;
    }
};

fn fetchUntil(authority: anytype, executor: anytype, deadline: anytype, allocator: std.mem.Allocator, executable: [:0]const u8, token: []const u8, request: transport_macos.Request, response: []u8) ![]const u8 {
    _ = try deadline.remaining();
    try authority.revalidate(allocator, executable);
    return transport_macos.fetchWith(executor, allocator, executable, token, request, response, try deadline.remaining());
}

fn ownRef(value: git.RefObservation) !OwnedRef {
    var out: OwnedRef = .{ .tag_len = value.tag.len, .kind = value.target.kind };
    if (value.tag.len > out.tag.len or value.target.sha.len != out.sha.len) return error.InvalidObservation;
    @memcpy(out.tag[0..value.tag.len], value.tag);
    @memcpy(&out.sha, value.target.sha);
    return out;
}

fn ownTag(value: git.TagObservation) !OwnedTag {
    var out: OwnedTag = .{ .tag_len = value.tag.len, .kind = value.target.kind };
    if (value.tag.len > out.tag.len or value.object_sha.len != out.object_sha.len or value.target.sha.len != out.target_sha.len) return error.InvalidObservation;
    @memcpy(out.tag[0..value.tag.len], value.tag);
    @memcpy(&out.object_sha, value.object_sha);
    @memcpy(&out.target_sha, value.target.sha);
    return out;
}
