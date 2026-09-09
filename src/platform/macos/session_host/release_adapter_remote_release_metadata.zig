//! Credential-free value owner for one current immutable GitHub Release snapshot.
//!
//! The evidence filename selects bytes to authenticate later; it deliberately does not publish a
//! release profile. Only authenticated evidence semantics may make that decision.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const identity = @import("release_adapter_identity");
const github_json = @import("release_adapter_github_json");

pub const asset_count: usize = 4;
pub const max_name_bytes: usize = 255;
pub const Role = enum { dmg, frozen_host, evidence_candidate, manifest };

pub const Asset = struct { id: u64, name: []const u8, size: u64, sha256: []const u8 };
pub const View = struct { release_id: u64, tag: []const u8, source_commit: []const u8, assets: [asset_count]Asset };

pub const Owner = struct {
    owner: ?*@This() = null,
    release_id: u64 = 0,
    tag: [context_mod.max_value_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    ids: [asset_count]u64 = @splat(0),
    names: [asset_count][max_name_bytes]u8 = @splat(@splat(0)),
    name_lens: [asset_count]usize = @splat(0),
    sizes: [asset_count]u64 = @splat(0),
    sha256: [asset_count][64]u8 = @splat(@splat(0)),
    seal: [32]u8 = @splat(0),

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or !std.crypto.timing_safe.eql([32]u8, self.seal, ownerSeal(self))) return null;
        if (self.release_id == 0 or self.tag_len == 0 or self.tag_len > self.tag.len or
            !identity.canonicalTag(self.tag[0..self.tag_len]) or !identity.lowerHex(&self.source_commit, 40)) return null;
        var assets: [asset_count]Asset = undefined;
        for (&assets, 0..) |*asset, index| {
            if (self.ids[index] == 0 or self.name_lens[index] == 0 or self.name_lens[index] > max_name_bytes or
                self.sizes[index] == 0 or !identity.lowerHex(&self.sha256[index], 64)) return null;
            asset.* = .{ .id = self.ids[index], .name = self.names[index][0..self.name_lens[index]], .size = self.sizes[index], .sha256 = &self.sha256[index] };
        }
        return .{ .release_id = self.release_id, .tag = self.tag[0..self.tag_len], .source_commit = &self.source_commit, .assets = assets };
    }

    pub fn deinit(self: *@This()) !void {
        _ = self.value() orelse return error.InvalidOwner;
        self.* = .{};
    }
};

const StrictU64 = struct {
    value: u64,
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        if (try source.peekNextTokenType() != .number) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse(u64, allocator, source, options) };
    }
};

const ApiAsset = struct {
    id: StrictU64,
    name: []const u8,
    size: StrictU64,
    state: []const u8,
    digest: []const u8,
    content_type: []const u8,
    url: []const u8,
};

const ApiRelease = struct {
    id: StrictU64,
    tag_name: []const u8,
    target_commitish: []const u8,
    draft: bool,
    prerelease: bool,
    immutable: bool,
    assets: []ApiAsset,
};

pub fn bind(allocator: std.mem.Allocator, bytes: []const u8, context: context_mod.Context, result: *Owner) !void {
    if (!pristine(result) or overlaps(bytes, std.mem.asBytes(result)) or contextOverlaps(context, std.mem.asBytes(result)))
        return error.InvalidOwner;
    try context_mod.validateTrusted(context);
    if (bytes.len == 0 or bytes.len > github_json.max_response_bytes) return error.InvalidResponse;
    github_json.validateCompleteResponse(bytes) catch return error.InvalidResponse;
    var parsed = std.json.parseFromSlice(ApiRelease, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    const release = parsed.value;
    if (release.id.value == 0 or !std.mem.eql(u8, release.tag_name, context.tag) or
        !std.mem.eql(u8, release.target_commitish, context.source_commit) or release.draft or release.prerelease or
        !release.immutable or release.assets.len != asset_count) return error.InvalidResponse;

    var expected_storage: [asset_count][max_name_bytes]u8 = @splat(@splat(0));
    var expected: [asset_count][]const u8 = undefined;
    const version = context.tag[1..];
    expected[@intFromEnum(Role.dmg)] = std.fmt.bufPrint(&expected_storage[@intFromEnum(Role.dmg)], "Maru-{s}-universal.dmg", .{version}) catch return error.InvalidResponse;
    expected[@intFromEnum(Role.frozen_host)] = std.fmt.bufPrint(&expected_storage[@intFromEnum(Role.frozen_host)], "maru-session-host-{s}", .{version}) catch return error.InvalidResponse;
    expected[@intFromEnum(Role.manifest)] = std.fmt.bufPrint(&expected_storage[@intFromEnum(Role.manifest)], "Maru-{s}-session-host-release.json", .{version}) catch return error.InvalidResponse;
    expected[@intFromEnum(Role.evidence_candidate)] = "";

    var staged: Owner = .{};
    staged.release_id = release.id.value;
    staged.tag_len = context.tag.len;
    @memcpy(staged.tag[0..staged.tag_len], context.tag);
    @memcpy(&staged.source_commit, context.source_commit);
    var seen: [asset_count]bool = @splat(false);
    for (release.assets) |asset| {
        const role = roleForName(asset.name, expected) orelse return error.InvalidResponse;
        const index = @intFromEnum(role);
        if (seen[index] or asset.id.value == 0 or asset.size.value == 0 or asset.size.value > identity.max_release_asset_bytes or asset.name.len > max_name_bytes or
            !std.mem.eql(u8, asset.state, "uploaded") or !std.mem.eql(u8, asset.content_type, "application/octet-stream") or
            asset.digest.len != "sha256:".len + 64 or !std.mem.startsWith(u8, asset.digest, "sha256:") or
            !identity.lowerHex(asset.digest["sha256:".len..], 64)) return error.InvalidResponse;
        var expected_url_storage: [160]u8 = undefined;
        const expected_url = std.fmt.bufPrint(&expected_url_storage, "https://api.github.com/repos/ohah/maru/releases/assets/{d}", .{asset.id.value}) catch return error.InvalidResponse;
        if (!std.mem.eql(u8, asset.url, expected_url)) return error.InvalidResponse;
        for (staged.ids) |prior| if (prior == asset.id.value) return error.InvalidResponse;
        seen[index] = true;
        staged.ids[index] = asset.id.value;
        staged.name_lens[index] = asset.name.len;
        @memcpy(staged.names[index][0..asset.name.len], asset.name);
        staged.sizes[index] = asset.size.value;
        @memcpy(&staged.sha256[index], asset.digest["sha256:".len..]);
    }
    for (seen) |present| if (!present) return error.InvalidResponse;
    if (!pristine(result) or overlaps(bytes, std.mem.asBytes(result)) or contextOverlaps(context, std.mem.asBytes(result)))
        return error.InvalidOwner;
    result.* = staged;
    result.owner = result;
    result.seal = ownerSeal(result);
}

fn roleForName(name: []const u8, expected: [asset_count][]const u8) ?Role {
    if (std.mem.eql(u8, name, expected[@intFromEnum(Role.dmg)])) return .dmg;
    if (std.mem.eql(u8, name, expected[@intFromEnum(Role.frozen_host)])) return .frozen_host;
    if (std.mem.eql(u8, name, "baseline-evidence.json") or std.mem.eql(u8, name, "upgrade-evidence.json")) return .evidence_candidate;
    if (std.mem.eql(u8, name, expected[@intFromEnum(Role.manifest)])) return .manifest;
    return null;
}

fn pristine(value: *const Owner) bool {
    return value.owner == null and value.release_id == 0 and value.tag_len == 0 and std.mem.allEqual(u8, &value.tag, 0) and
        std.mem.allEqual(u8, &value.source_commit, 0) and std.mem.allEqual(u64, &value.ids, 0) and
        std.mem.allEqual(u8, std.mem.asBytes(&value.names), 0) and std.mem.allEqual(usize, &value.name_lens, 0) and
        std.mem.allEqual(u64, &value.sizes, 0) and std.mem.allEqual(u8, std.mem.asBytes(&value.sha256), 0) and
        std.mem.allEqual(u8, &value.seal, 0);
}

fn ownerSeal(value: *const Owner) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host.remote-release-metadata.v1");
    const address = @intFromPtr(value);
    hash.update(std.mem.asBytes(&address));
    hash.update(std.mem.asBytes(&value.release_id));
    hash.update(std.mem.asBytes(&value.tag_len));
    if (value.tag_len <= value.tag.len) hash.update(value.tag[0..value.tag_len]);
    hash.update(&value.source_commit);
    hash.update(std.mem.asBytes(&value.ids));
    hash.update(std.mem.asBytes(&value.name_lens));
    for (value.names, value.name_lens) |name, len| if (len <= name.len) hash.update(name[0..len]);
    hash.update(std.mem.asBytes(&value.sizes));
    hash.update(std.mem.asBytes(&value.sha256));
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn contextOverlaps(context: context_mod.Context, bytes: []const u8) bool {
    inline for (.{ context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref }) |value|
        if (overlaps(value, bytes)) return true;
    return false;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
