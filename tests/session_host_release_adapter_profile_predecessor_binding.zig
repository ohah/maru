//! Protected profile selection and authenticated predecessor identity become one capability.

const std = @import("std");
const manifest = @import("release_manifest");
const evidence = @import("release_evidence");
const profile = @import("release_adapter_profile_endorsement");
const binding = @import("release_adapter_profile_predecessor_binding");

const tag = "v1.2.3";
const commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const manifest_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const dmg_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const executable_sha = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const document_sha: [32]u8 = @splat(0x5a);

const ProfileAuthority = struct {
    selected: profile.Profile = .upgrade_b,
    release_id: u64 = 41,
    tag_value: []const u8 = tag,
    commit_value: []const u8 = commit,
    manifest_sha_value: []const u8 = manifest_sha,
    digest: [32]u8 = document_sha,
    valid: bool = true,
    calls: usize = 0,

    pub fn revalidate(self: *@This()) !profile.Value {
        self.calls += 1;
        if (!self.valid) return error.AuthorityChanged;
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
        return std.mem.asBytes(self);
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

    pub fn revalidate(self: *@This()) !evidence.Predecessor {
        self.calls += 1;
        if (!self.valid) return error.FileChanged;
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
    try std.testing.expectEqual(@as(usize, 2), selected.calls);
    try std.testing.expectEqual(@as(usize, 2), authenticated.calls);
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
    selected.tag_value = std.mem.asBytes(&result)[0..tag.len];
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
