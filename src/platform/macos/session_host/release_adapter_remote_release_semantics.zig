//! Credential-free semantic binding for downloaded immutable Release bytes.

const std = @import("std");
const manifest = @import("release_manifest");
const evidence = @import("release_evidence");
const context_mod = @import("release_adapter_context");
const metadata = @import("release_adapter_remote_release_metadata");

pub const View = struct {
    profile: evidence.Profile,
    release_id: u64,
    manifest_bytes: []const u8,
    evidence_bytes: []const u8,
};

pub const Owner = struct {
    owner: ?*@This() = null,
    parsed_manifest: ?manifest.Parsed = null,
    parsed_evidence: ?evidence.Parsed = null,
    manifest_bytes: ?[]u8 = null,
    evidence_bytes: ?[]u8 = null,
    remote_owner: ?*const metadata.Owner = null,
    profile: ?evidence.Profile = null,
    release_id: u64 = 0,
    manifest_sha256: [64]u8 = @splat(0),
    evidence_sha256: [64]u8 = @splat(0),
    remote_snapshot_seal: [32]u8 = @splat(0),
    seal: [32]u8 = @splat(0),

    pub fn isPristineForComposition(self: *const @This()) bool {
        return pristine(self);
    }

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or !std.crypto.timing_safe.eql([32]u8, self.seal, ownerSeal(self))) return null;
        const manifest_bytes = self.manifest_bytes orelse return null;
        const evidence_bytes = self.evidence_bytes orelse return null;
        const profile = self.profile orelse return null;
        const remote_owner = self.remote_owner orelse return null;
        const remote = remote_owner.value() orelse return null;
        if (!std.crypto.timing_safe.eql([32]u8, self.remote_snapshot_seal, remoteSeal(remote)) or
            self.release_id == 0 or self.parsed_manifest == null or self.parsed_evidence == null or
            self.parsed_evidence.?.profile() != profile) return null;
        var manifest_sha: [64]u8 = undefined;
        var evidence_sha: [64]u8 = undefined;
        hashHex(manifest_bytes, &manifest_sha);
        hashHex(evidence_bytes, &evidence_sha);
        if (!std.crypto.timing_safe.eql([64]u8, manifest_sha, self.manifest_sha256) or
            !std.crypto.timing_safe.eql([64]u8, evidence_sha, self.evidence_sha256)) return null;
        return .{ .profile = profile, .release_id = self.release_id, .manifest_bytes = manifest_bytes, .evidence_bytes = evidence_bytes };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) !void {
        if (self.owner != self or !std.crypto.timing_safe.eql([32]u8, self.seal, ownerSeal(self))) return error.InvalidOwner;
        cleanup(self, allocator);
    }
};

pub fn bind(allocator: std.mem.Allocator, context: context_mod.Context, remote_owner: *const metadata.Owner, manifest_input: []const u8, evidence_input: []const u8, result: *Owner) !void {
    const remote = remote_owner.value() orelse return error.InvalidMetadata;
    const initial_remote_seal = remoteSeal(remote);
    const initial_context_seal = contextSeal(context);
    if (!pristine(result) or aliases(result, context, remote_owner, remote, manifest_input, evidence_input)) return error.InvalidOwner;
    try context_mod.validateTrusted(context);
    if (remote.release_id == 0 or !std.mem.eql(u8, remote.tag, context.tag) or !std.mem.eql(u8, remote.source_commit, context.source_commit))
        return error.MetadataMismatch;
    try bindBytes(remote.assets[@intFromEnum(metadata.Role.manifest)], manifest_input, manifest.max_manifest_bytes);
    try bindBytes(remote.assets[@intFromEnum(metadata.Role.evidence_candidate)], evidence_input, evidence.max_evidence_bytes);

    var staged: Owner = .{};
    errdefer cleanup(&staged, allocator);
    staged.manifest_bytes = try allocator.dupe(u8, manifest_input);
    staged.evidence_bytes = try allocator.dupe(u8, evidence_input);
    try bindBytes(remote.assets[@intFromEnum(metadata.Role.manifest)], staged.manifest_bytes.?, manifest.max_manifest_bytes);
    try bindBytes(remote.assets[@intFromEnum(metadata.Role.evidence_candidate)], staged.evidence_bytes.?, evidence.max_evidence_bytes);
    staged.parsed_manifest = try manifest.parseCanonical(allocator, staged.manifest_bytes.?);
    staged.parsed_evidence = try evidence.parseCanonical(allocator, staged.evidence_bytes.?);
    const parsed_manifest = staged.parsed_manifest.?.value();
    const parsed_evidence = &staged.parsed_evidence.?;
    try bindSemantic(context, remote, parsed_manifest, parsed_evidence);

    staged.release_id = remote.release_id;
    staged.remote_owner = remote_owner;
    staged.profile = staged.parsed_evidence.?.profile();
    staged.remote_snapshot_seal = initial_remote_seal;
    hashHex(staged.manifest_bytes.?, &staged.manifest_sha256);
    hashHex(staged.evidence_bytes.?, &staged.evidence_sha256);
    const final_remote = remote_owner.value() orelse return error.InvalidMetadata;
    if (!std.crypto.timing_safe.eql([32]u8, initial_remote_seal, remoteSeal(final_remote)) or
        !std.crypto.timing_safe.eql([32]u8, initial_context_seal, contextSeal(context))) return error.MetadataMismatch;
    if (!pristine(result) or aliases(result, context, remote_owner, final_remote, manifest_input, evidence_input)) return error.InvalidOwner;
    result.* = staged;
    staged = .{};
    result.owner = result;
    result.seal = ownerSeal(result);
}

fn bindBytes(asset: metadata.Asset, bytes: []const u8, cap: usize) !void {
    if (bytes.len == 0 or bytes.len > cap or asset.size != bytes.len) return error.ContentMismatch;
    var actual: [64]u8 = undefined;
    hashHex(bytes, &actual);
    if (!std.mem.eql(u8, &actual, asset.sha256)) return error.ContentMismatch;
}

fn bindSemantic(context: context_mod.Context, remote: metadata.View, m: *const manifest.Manifest, parsed: *const evidence.Parsed) !void {
    try context_mod.bindManifest(context, m.*);
    if (m.release.id != remote.release_id or m.assets.len != 3 or !std.mem.eql(u8, m.evidence.result, "passed"))
        return error.BindingMismatch;
    const remote_roles = [_]metadata.Role{ .dmg, .frozen_host, .evidence_candidate };
    const manifest_roles = [_]manifest.AssetRole{ .universal_dmg, .frozen_product_executable, .evidence_summary };
    for (remote_roles, manifest_roles, m.assets) |remote_role, manifest_role, local| {
        const asset = remote.assets[@intFromEnum(remote_role)];
        if (local.role != manifest_role or local.size != asset.size or !std.mem.eql(u8, local.name, asset.name) or
            !std.mem.eql(u8, local.sha256, asset.sha256)) return error.BindingMismatch;
    }
    const evidence_asset = remote.assets[@intFromEnum(metadata.Role.evidence_candidate)];
    if (!std.mem.eql(u8, m.evidence.summary_name, evidence_asset.name) or
        !std.mem.eql(u8, m.evidence.summary_sha256, evidence_asset.sha256)) return error.BindingMismatch;

    const common = commonFor(m.*);
    switch (parsed.value()) {
        .baseline_a => {
            if (m.role != .a or m.predecessor != null or !std.mem.eql(u8, evidence_asset.name, "baseline-evidence.json")) return error.BindingMismatch;
            try evidence.bind(parsed.value(), .{ .baseline_a = common });
        },
        .upgrade_b => |root| {
            const predecessor = m.predecessor orelse return error.BindingMismatch;
            if (m.role != .b or !std.mem.eql(u8, evidence_asset.name, "upgrade-evidence.json") or
                predecessor.release_id != root.predecessor.release_id or !std.mem.eql(u8, predecessor.tag, root.predecessor.tag) or
                !std.mem.eql(u8, predecessor.commit, root.predecessor.commit) or
                !std.mem.eql(u8, predecessor.manifest_sha256, root.predecessor.manifest_sha256)) return error.BindingMismatch;
            try evidence.bind(parsed.value(), .{ .upgrade_b = .{
                .common = common,
                .predecessor = root.predecessor,
                .designated_requirement_sha256 = m.signing.designated_requirement_sha256,
            } });
        },
    }
}

fn commonFor(m: manifest.Manifest) evidence.Common {
    return .{
        .test_uuid = m.evidence.test_uuid,
        .repository = .{ .id = m.repository.id, .owner = m.repository.owner, .name = m.repository.name },
        .release = .{ .id = m.release.id, .tag = m.release.tag, .version = m.release.version },
        .source = .{ .commit = m.source.commit, .tree = m.source.tree },
        .build = .{ .workflow_ref = m.build.workflow_ref, .run_id = m.build.run_id, .run_attempt = m.build.run_attempt },
        .candidate = .{ .dmg_sha256 = m.assets[0].sha256, .executable_sha256 = m.assets[1].sha256 },
    };
}

fn cleanup(result: *Owner, allocator: std.mem.Allocator) void {
    if (result.parsed_evidence) |*value| value.deinit();
    if (result.parsed_manifest) |*value| value.deinit();
    if (result.evidence_bytes) |bytes| allocator.free(bytes);
    if (result.manifest_bytes) |bytes| allocator.free(bytes);
    result.* = .{};
}

fn pristine(value: *const Owner) bool {
    return value.owner == null and value.parsed_manifest == null and value.parsed_evidence == null and
        value.manifest_bytes == null and value.evidence_bytes == null and value.remote_owner == null and value.profile == null and value.release_id == 0 and
        std.mem.allEqual(u8, &value.manifest_sha256, 0) and std.mem.allEqual(u8, &value.evidence_sha256, 0) and
        std.mem.allEqual(u8, &value.remote_snapshot_seal, 0) and
        std.mem.allEqual(u8, &value.seal, 0);
}

fn aliases(result: *const Owner, context: context_mod.Context, remote_owner: *const metadata.Owner, remote: metadata.View, manifest_input: []const u8, evidence_input: []const u8) bool {
    const out = std.mem.asBytes(result);
    const inputs = [_][]const u8{ std.mem.asBytes(remote_owner), context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref, manifest_input, evidence_input };
    for (inputs, 0..) |input, index| for (inputs[0..index]) |prior| if (overlaps(input, prior)) return true;
    inline for (inputs) |bytes|
        if (overlaps(out, bytes)) return true;
    for (remote.assets) |asset| {
        if (overlaps(out, asset.name) or overlaps(out, asset.sha256)) return true;
    }
    return false;
}

fn ownerSeal(value: *const Owner) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host.remote-release-semantics.v1");
    const address = @intFromPtr(value);
    hash.update(std.mem.asBytes(&address));
    hash.update(std.mem.asBytes(&value.release_id));
    const remote_address = if (value.remote_owner) |owner| @intFromPtr(owner) else 0;
    hash.update(std.mem.asBytes(&remote_address));
    const manifest_address = if (value.manifest_bytes) |bytes| @intFromPtr(bytes.ptr) else 0;
    const manifest_len = if (value.manifest_bytes) |bytes| bytes.len else 0;
    const evidence_address = if (value.evidence_bytes) |bytes| @intFromPtr(bytes.ptr) else 0;
    const evidence_len = if (value.evidence_bytes) |bytes| bytes.len else 0;
    hash.update(std.mem.asBytes(&manifest_address));
    hash.update(std.mem.asBytes(&manifest_len));
    hash.update(std.mem.asBytes(&evidence_address));
    hash.update(std.mem.asBytes(&evidence_len));
    hash.update(&value.manifest_sha256);
    hash.update(&value.evidence_sha256);
    hash.update(&value.remote_snapshot_seal);
    if (value.profile) |stored_profile| {
        const profile: u8 = @intFromEnum(stored_profile);
        hash.update(std.mem.asBytes(&profile));
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn remoteSeal(remote: metadata.View) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host.remote-release-semantics.snapshot.v1");
    hash.update(std.mem.asBytes(&remote.release_id));
    hashPart(&hash, remote.tag);
    hashPart(&hash, remote.source_commit);
    for (remote.assets) |asset| {
        hash.update(std.mem.asBytes(&asset.id));
        hashPart(&hash, asset.name);
        hash.update(std.mem.asBytes(&asset.size));
        hashPart(&hash, asset.sha256);
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn contextSeal(context: context_mod.Context) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host.remote-release-semantics.context.v1");
    hash.update(std.mem.asBytes(&context.repository.id));
    hashPart(&hash, context.repository.owner);
    hashPart(&hash, context.repository.name);
    hashPart(&hash, context.tag);
    hashPart(&hash, context.source_commit);
    hashPart(&hash, context.build.workflow_ref);
    hash.update(std.mem.asBytes(&context.build.run_id));
    hash.update(std.mem.asBytes(&context.build.run_attempt));
    hash.update(std.mem.asBytes(&context.protected_tag));
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn hashPart(hash: *std.crypto.hash.Blake3, bytes: []const u8) void {
    hash.update(std.mem.asBytes(&bytes.len));
    hash.update(bytes);
}

fn hashHex(bytes: []const u8, output: *[64]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    output.* = std.fmt.bytesToHex(digest, .lower);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
