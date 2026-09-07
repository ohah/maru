//! Protected profile selection and authenticated predecessor identity become one capability.

const std = @import("std");
const manifest = @import("release_manifest");
const evidence = @import("release_evidence");
const context_mod = @import("release_adapter_context");
const profile = @import("release_adapter_profile_endorsement");
const binding = @import("release_adapter_profile_predecessor_binding");

const tag = "v1.2.3";
const commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const manifest_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const dmg_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const executable_sha = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const document_sha: [32]u8 = @splat(0x5a);
const upgrade_document = "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"upgrade_b\",\"predecessor\":{\"release_id\":41,\"tag\":\"v1.2.3\",\"commit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"manifest_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}}\n";
const baseline_document = "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"baseline_a\"}\n";

const ProfileAuthority = struct {
    selected: profile.Profile = .upgrade_b,
    release_id: u64 = 41,
    tag_value: []const u8 = tag,
    commit_value: []const u8 = commit,
    manifest_sha_value: []const u8 = manifest_sha,
    digest: [32]u8 = document_sha,
    valid: bool = true,
    calls: usize = 0,
    storage_override: ?[]const u8 = null,
    drift_on_second: bool = false,

    pub fn revalidate(self: *@This()) !profile.Value {
        self.calls += 1;
        if (!self.valid) return error.AuthorityChanged;
        if (self.drift_on_second and self.calls == 2) self.release_id += 1;
        return switch (self.selected) {
            .baseline_a => .{ .baseline_a = {} },
            .upgrade_b => .{ .upgrade_b = .{
                .release_id = self.release_id,
                .tag = self.tag_value,
                .commit = self.commit_value,
                .manifest_sha256 = self.manifest_sha_value,
            } },
        };
    }

    pub fn documentSha256(self: *const @This()) ?[32]u8 {
        return if (self.valid) self.digest else null;
    }

    pub fn storage(self: *@This()) []const u8 {
        return self.storage_override orelse std.mem.asBytes(self);
    }
};

const IdentityAuthority = struct {
    release_id: u64 = 41,
    tag_value: []const u8 = tag,
    commit_value: []const u8 = commit,
    manifest_sha_value: []const u8 = manifest_sha,
    dmg_sha_value: []const u8 = dmg_sha,
    executable_sha_value: []const u8 = executable_sha,
    valid: bool = true,
    calls: usize = 0,
    drift_on_second: bool = false,

    pub fn revalidate(self: *@This()) !evidence.Predecessor {
        self.calls += 1;
        if (!self.valid) return error.FileChanged;
        if (self.drift_on_second and self.calls == 2) self.dmg_sha_value = "1111111111111111111111111111111111111111111111111111111111111111";
        return .{
            .release_id = self.release_id,
            .tag = self.tag_value,
            .commit = self.commit_value,
            .manifest_sha256 = self.manifest_sha_value,
            .dmg_sha256 = self.dmg_sha_value,
            .executable_sha256 = self.executable_sha_value,
        };
    }

    pub fn storage(self: *@This()) []const u8 {
        return std.mem.asBytes(self);
    }
};

const ChangingEnvironment = struct {
    calls: usize = 0,

    fn interface(self: *@This()) profile.Environment {
        return .{ .context = self, .read_fn = read };
    }

    fn read(raw: *anyopaque, name: [:0]const u8) ?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, name, profile.environment_name)) return null;
        defer self.calls += 1;
        return if (self.calls < 2) upgrade_document else baseline_document;
    }
};

const LiveProfileAuthority = struct {
    owner: *const profile.Owner,
    environment: profile.Environment,

    pub fn revalidate(self: *@This()) !profile.Value {
        return self.owner.revalidateEnvironment(std.testing.allocator, context(), self.environment);
    }

    pub fn documentSha256(self: *const @This()) ?[32]u8 {
        return self.owner.documentSha256();
    }

    pub fn storage(self: *@This()) []const u8 {
        return std.mem.asBytes(self.owner);
    }
};

test "upgrade endorsement and authenticated identity bind every predecessor field" {
    var selected = ProfileAuthority{};
    var authenticated = IdentityAuthority{};
    var result: binding.BoundPredecessor = .{};
    try binding.bindWith(&selected, &authenticated, &result);
    defer result.deinit() catch unreachable;
    const value = try result.revalidateWith(&selected, &authenticated);
    try std.testing.expectEqual(@as(u64, 41), value.release_id);
    try std.testing.expectEqualStrings(tag, value.tag);
    try std.testing.expectEqualStrings(commit, value.commit);
    try std.testing.expectEqualStrings(manifest_sha, value.manifest_sha256);
    try std.testing.expectEqualStrings(dmg_sha, value.dmg_sha256);
    try std.testing.expectEqualStrings(executable_sha, value.executable_sha256);
    try std.testing.expectEqual(@as(usize, 3), selected.calls);
    try std.testing.expectEqual(@as(usize, 3), authenticated.calls);
}

test "baseline and each partial predecessor mismatch publish nothing" {
    var selected = ProfileAuthority{ .selected = .baseline_a };
    var authenticated = IdentityAuthority{};
    var result: binding.BoundPredecessor = .{};
    try std.testing.expectError(error.ProfileMismatch, binding.bindWith(&selected, &authenticated, &result));
    try std.testing.expect(result.isPristineForComposition());
    try std.testing.expectEqual(@as(usize, 0), authenticated.calls);

    const Axis = enum { release_id, tag, commit, manifest_sha };
    inline for (std.meta.tags(Axis)) |axis| {
        selected = .{};
        authenticated = .{};
        switch (axis) {
            .release_id => authenticated.release_id += 1,
            .tag => authenticated.tag_value = "v1.2.2",
            .commit => authenticated.commit_value = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            .manifest_sha => authenticated.manifest_sha_value = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        }
        result = .{};
        try std.testing.expectError(error.BindingMismatch, binding.bindWith(&selected, &authenticated, &result));
        try std.testing.expect(result.isPristineForComposition());
    }
}

test "malformed authenticated identities cannot mint a sealed result" {
    const Axis = enum { zero_release, invalid_tag, short_commit, invalid_asset_sha };
    inline for (std.meta.tags(Axis)) |axis| {
        var selected = ProfileAuthority{};
        var authenticated = IdentityAuthority{};
        switch (axis) {
            .zero_release => {
                selected.release_id = 0;
                authenticated.release_id = 0;
            },
            .invalid_tag => {
                selected.tag_value = "release-1";
                authenticated.tag_value = "release-1";
            },
            .short_commit => {
                selected.commit_value = "aa";
                authenticated.commit_value = "aa";
            },
            .invalid_asset_sha => authenticated.dmg_sha_value = "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",
        }
        var result: binding.BoundPredecessor = .{};
        try std.testing.expectError(error.BindingMismatch, binding.bindWith(&selected, &authenticated, &result));
        try std.testing.expect(result.isPristineForComposition());
    }
}

test "profile and authenticated identity drift invalidate the bound capability" {
    var selected = ProfileAuthority{};
    var authenticated = IdentityAuthority{};
    var result: binding.BoundPredecessor = .{};
    try binding.bindWith(&selected, &authenticated, &result);
    defer result.deinit() catch unreachable;

    selected.digest[0] ^= 1;
    try std.testing.expectError(error.AuthorityChanged, result.revalidateWith(&selected, &authenticated));
    selected.digest = document_sha;
    authenticated.valid = false;
    try std.testing.expectError(error.AuthorityChanged, result.revalidateWith(&selected, &authenticated));
}

test "authority drift between initial and final observation publishes nothing" {
    var selected = ProfileAuthority{ .drift_on_second = true };
    var authenticated = IdentityAuthority{};
    var result: binding.BoundPredecessor = .{};
    try std.testing.expectError(error.AuthorityChanged, binding.bindWith(&selected, &authenticated, &result));
    try std.testing.expect(result.isPristineForComposition());

    selected = .{};
    authenticated = .{ .drift_on_second = true };
    try std.testing.expectError(error.AuthorityChanged, binding.bindWith(&selected, &authenticated, &result));
    try std.testing.expect(result.isPristineForComposition());
}

test "real profile owner rejects environment drift between binding fences" {
    var profile_owner: profile.Owner = .{};
    try profile.bindDocumentForTest(std.testing.allocator, context(), upgrade_document, &profile_owner);
    defer profile_owner.deinit() catch unreachable;
    var environment = ChangingEnvironment{};
    var selected = LiveProfileAuthority{ .owner = &profile_owner, .environment = environment.interface() };
    var authenticated = IdentityAuthority{};
    var result: binding.BoundPredecessor = .{};
    try std.testing.expectError(error.AuthorityChanged, binding.bindWith(&selected, &authenticated, &result));
    try std.testing.expect(result.isPristineForComposition());
    try std.testing.expectEqual(@as(usize, 3), environment.calls);
}

test "every authenticated identity component and corrupt stored length fail closed" {
    const Axis = enum { release_id, tag, commit, manifest_sha, dmg_sha, executable_sha };
    inline for (std.meta.tags(Axis)) |axis| {
        var selected = ProfileAuthority{};
        var authenticated = IdentityAuthority{};
        var result: binding.BoundPredecessor = .{};
        try binding.bindWith(&selected, &authenticated, &result);
        switch (axis) {
            .release_id => authenticated.release_id += 1,
            .tag => authenticated.tag_value = "v1.2.2",
            .commit => authenticated.commit_value = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            .manifest_sha => authenticated.manifest_sha_value = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            .dmg_sha => authenticated.dmg_sha_value = "1111111111111111111111111111111111111111111111111111111111111111",
            .executable_sha => authenticated.executable_sha_value = "2222222222222222222222222222222222222222222222222222222222222222",
        }
        try std.testing.expectError(error.AuthorityChanged, result.revalidateWith(&selected, &authenticated));
        try result.deinit();
    }

    var selected = ProfileAuthority{};
    var authenticated = IdentityAuthority{};
    var corrupt: binding.BoundPredecessor = .{};
    try binding.bindWith(&selected, &authenticated, &corrupt);
    corrupt.tag_len = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidOwner, corrupt.revalidateWith(&selected, &authenticated));
    try std.testing.expectError(error.InvalidOwner, corrupt.deinit());
}

test "copied preowned and aliased storage fail before authority callbacks" {
    var selected = ProfileAuthority{};
    var authenticated = IdentityAuthority{};
    var result: binding.BoundPredecessor = .{};
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, binding.bindWith(&selected, &authenticated, &result));
    try std.testing.expectEqual(@as(usize, 0), selected.calls);
    try std.testing.expectEqual(@as(usize, 0), authenticated.calls);

    result = .{};
    selected = .{};
    selected.storage_override = std.mem.asBytes(&result);
    try std.testing.expectError(error.InvalidOwner, binding.bindWith(&selected, &authenticated, &result));
    try std.testing.expectEqual(@as(usize, 0), selected.calls);
    try std.testing.expectEqual(@as(usize, 0), authenticated.calls);

    selected = .{};
    try binding.bindWith(&selected, &authenticated, &result);
    var copied = result;
    try std.testing.expectError(error.InvalidOwner, copied.revalidateWith(&selected, &authenticated));
    try result.deinit();
}

test "production binding surface is concrete" {
    _ = binding.bind;
    _ = manifest.Predecessor;
}

fn context() context_mod.Context {
    return .{
        .repository = .{ .id = 77, .owner = "ohah", .name = "maru" },
        .tag = "v2.0.0",
        .source_commit = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v2.0.0", .run_id = 91, .run_attempt = 2 },
        .protected_tag = true,
    };
}
