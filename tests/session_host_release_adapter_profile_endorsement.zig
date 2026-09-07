//! Protected release profile endorsement is canonical, context-bound, and move-only.

const std = @import("std");
const manifest = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const endorsement = @import("release_adapter_profile_endorsement");

const baseline = "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"baseline_a\"}\n";
const upgrade = "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"upgrade_b\",\"predecessor\":{\"release_id\":41,\"tag\":\"v1.2.3\",\"commit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"manifest_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}}\n";

test "baseline endorsement binds exact canonical bytes and protected context" {
    var owner: endorsement.Owner = .{};
    try endorsement.bindDocumentForTest(std.testing.allocator, context(), baseline, &owner);
    defer owner.deinit() catch unreachable;
    try std.testing.expectEqual(endorsement.Profile.baseline_a, (try owner.revalidateDocumentForTest(std.testing.allocator, context(), baseline)).profile());
    try std.testing.expect(owner.documentSha256() != null);
}

test "upgrade endorsement exposes the complete exact predecessor tuple" {
    var owner: endorsement.Owner = .{};
    try endorsement.bindDocumentForTest(std.testing.allocator, context(), upgrade, &owner);
    defer owner.deinit() catch unreachable;
    const value = try owner.revalidateDocumentForTest(std.testing.allocator, context(), upgrade);
    const predecessor = value.predecessor() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u64, 41), predecessor.release_id);
    try std.testing.expectEqualStrings("v1.2.3", predecessor.tag);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", predecessor.commit);
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", predecessor.manifest_sha256);
}

test "noncanonical duplicate unknown trailing and oversized documents fail closed" {
    const cases = [_][]const u8{
        "{ \"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"baseline_a\"}\n",
        "{\"schema\":\"maru.session-host-release-profile.v1\",\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"baseline_a\"}\n",
        "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"baseline_a\",\"extra\":1}\n",
        "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"baseline_a\"}\n{}",
    };
    for (cases) |bytes| {
        var owner: endorsement.Owner = .{};
        try std.testing.expectError(error.InvalidDocument, endorsement.bindDocumentForTest(std.testing.allocator, context(), bytes, &owner));
        try std.testing.expect(owner.isPristineForComposition());
    }
    var oversized: [endorsement.max_document_bytes + 1]u8 = @splat('x');
    var owner: endorsement.Owner = .{};
    try std.testing.expectError(error.DocumentTooLarge, endorsement.bindDocumentForTest(std.testing.allocator, context(), &oversized, &owner));
}

test "profile predecessor policy and scalar forms are closed" {
    const cases = [_][]const u8{
        "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"baseline_a\",\"predecessor\":{\"release_id\":41,\"tag\":\"v1.2.3\",\"commit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"manifest_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}}\n",
        "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"upgrade_b\"}\n",
        "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"upgrade_b\",\"predecessor\":{\"release_id\":0,\"tag\":\"v1.2.3\",\"commit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"manifest_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}}\n",
        "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"upgrade_b\",\"predecessor\":{\"release_id\":041,\"tag\":\"v1.2.3\",\"commit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"manifest_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}}\n",
        "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"upgrade_b\",\"predecessor\":{\"release_id\":41,\"tag\":\"v2.0.0\",\"commit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"manifest_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}}\n",
    };
    for (cases) |bytes| {
        var owner: endorsement.Owner = .{};
        try std.testing.expectError(error.InvalidDocument, endorsement.bindDocumentForTest(std.testing.allocator, context(), bytes, &owner));
        try std.testing.expect(owner.isPristineForComposition());
    }
}

test "pre-owned copied and aliased owner storage is rejected" {
    var owner: endorsement.Owner = .{};
    owner.owner = &owner;
    var environment = TestEnvironment{ .first = baseline, .second = baseline };
    try std.testing.expectError(error.InvalidOwner, endorsement.bindFromEnvironment(std.testing.allocator, context(), environment.interface(), &owner));
    try std.testing.expectEqual(@as(usize, 0), environment.calls);
    try std.testing.expectError(error.InvalidOwner, owner.revalidateEnvironment(std.testing.allocator, context(), environment.interface()));
    try std.testing.expectEqual(@as(usize, 0), environment.calls);
    try std.testing.expectError(error.InvalidOwner, endorsement.bindDocumentForTest(std.testing.allocator, context(), baseline, &owner));
    owner = .{};
    var copied = owner;
    copied.owner = &owner;
    try std.testing.expectError(error.InvalidOwner, endorsement.bindDocumentForTest(std.testing.allocator, context(), baseline, &copied));
    const alias = std.mem.asBytes(&owner)[0..baseline.len];
    try std.testing.expectError(error.InvalidOwner, endorsement.bindDocumentForTest(std.testing.allocator, context(), alias, &owner));
    var alias_context = context();
    alias_context.tag = std.mem.asBytes(&owner)[0..6];
    try std.testing.expectError(error.InvalidOwner, endorsement.bindDocumentForTest(std.testing.allocator, alias_context, baseline, &owner));
    var invalid_context = context();
    invalid_context.protected_tag = false;
    try std.testing.expectError(error.InvalidDocument, endorsement.bindFromEnvironment(std.testing.allocator, invalid_context, environment.interface(), &owner));
    try std.testing.expectEqual(@as(usize, 0), environment.calls);
}

test "document and every protected run context component are revalidated" {
    var owner: endorsement.Owner = .{};
    var environment = TestEnvironment{ .first = upgrade, .second = upgrade };
    try endorsement.bindFromEnvironment(std.testing.allocator, context(), environment.interface(), &owner);
    defer owner.deinit() catch unreachable;
    var changes = [_]context_mod.Context{ context(), context(), context(), context(), context(), context(), context(), context(), context() };
    changes[0].repository.id += 1;
    changes[1].repository.owner = "other";
    changes[2].repository.name = "other";
    changes[3].tag = "v2.0.1";
    changes[4].source_commit = "dddddddddddddddddddddddddddddddddddddddd";
    changes[5].build.workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v2.0.1";
    changes[6].build.run_id += 1;
    changes[7].build.run_attempt += 1;
    changes[8].protected_tag = false;
    for (changes) |changed|
        try std.testing.expectError(error.AuthorityChanged, owner.revalidateDocumentForTest(std.testing.allocator, changed, upgrade));
    var bytes: [upgrade.len]u8 = upgrade.*;
    bytes[bytes.len - 5] = if (bytes[bytes.len - 5] == 'b') 'c' else 'b';
    try std.testing.expectError(error.AuthorityChanged, owner.revalidateDocumentForTest(std.testing.allocator, context(), &bytes));
    environment.calls = 0;
    environment.second = baseline;
    try std.testing.expectError(error.AuthorityChanged, owner.revalidateEnvironment(std.testing.allocator, context(), environment.interface()));
    try std.testing.expectEqual(@as(usize, 2), environment.calls);

    var mutable: [upgrade.len]u8 = upgrade.*;
    var mutating = MutatingEnvironment{ .bytes = &mutable };
    var rejected: endorsement.Owner = .{};
    try std.testing.expectError(error.AuthorityChanged, endorsement.bindFromEnvironment(std.testing.allocator, context(), mutating.interface(), &rejected));
    try std.testing.expect(rejected.isPristineForComposition());
}

const TestEnvironment = struct {
    first: []const u8,
    second: []const u8,
    calls: usize = 0,

    fn interface(self: *@This()) endorsement.Environment {
        return .{ .context = self, .read_fn = read };
    }

    fn read(raw: *anyopaque, name: [:0]const u8) ?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, name, endorsement.environment_name)) return null;
        defer self.calls += 1;
        return if (self.calls == 0) self.first else self.second;
    }
};

const MutatingEnvironment = struct {
    bytes: []u8,
    calls: usize = 0,

    fn interface(self: *@This()) endorsement.Environment {
        return .{ .context = self, .read_fn = read };
    }

    fn read(raw: *anyopaque, name: [:0]const u8) ?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, name, endorsement.environment_name)) return null;
        if (self.calls == 1) self.bytes[self.bytes.len - 5] = 'c';
        self.calls += 1;
        return self.bytes;
    }
};

fn context() context_mod.Context {
    return .{
        .repository = .{ .id = 77, .owner = "ohah", .name = "maru" },
        .tag = "v2.0.0",
        .source_commit = "cccccccccccccccccccccccccccccccccccccccc",
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v2.0.0", .run_id = 91, .run_attempt = 2 },
        .protected_tag = true,
    };
}

comptime {
    _ = manifest.Predecessor;
}
