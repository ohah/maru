//! Move-only authority joining one protected profile with one authenticated predecessor identity.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("release_manifest");
const evidence = @import("release_evidence");
const context_mod = @import("release_adapter_context");
const release_identity = @import("release_adapter_identity");
const profile_mod = @import("release_adapter_profile_endorsement");
const identity_mod = @import("release_adapter_predecessor_evidence_identity");
const authenticated_mod = @import("release_adapter_github_manifest_attestation");
const file_mod = @import("release_adapter_github_manifest_file");
const assets_mod = @import("release_adapter_github_predecessor_assets");

pub const Error = error{ InvalidOwner, ProfileMismatch, BindingMismatch, AuthorityChanged };

pub const BoundPredecessor = struct {
    owner: ?*@This() = null,
    release_id: u64 = 0,
    tag: [manifest.max_scalar_string_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    commit: [40]u8 = @splat(0),
    manifest_sha256: [64]u8 = @splat(0),
    dmg_sha256: [64]u8 = @splat(0),
    executable_sha256: [64]u8 = @splat(0),
    document_sha256: [32]u8 = @splat(0),
    seal: [32]u8 = @splat(0),

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and self.release_id == 0 and self.tag_len == 0 and allZero(&self.tag) and
            allZero(&self.commit) and allZero(&self.manifest_sha256) and allZero(&self.dmg_sha256) and
            allZero(&self.executable_sha256) and allZero(&self.document_sha256) and allZero(&self.seal);
    }

    pub fn revalidate(
        self: *const @This(),
        allocator: std.mem.Allocator,
        context: context_mod.Context,
        environment: profile_mod.Environment,
        profile: *const profile_mod.Owner,
        authenticated: *const authenticated_mod.AuthenticatedManifest,
        file: *const file_mod.ManifestFile,
        assets: *const assets_mod.AuthenticatedPredecessorAssets,
        identity: *const identity_mod.PredecessorEvidenceIdentity,
    ) Error!evidence.Predecessor {
        if (aliasesProduction(std.mem.asBytes(self), context, environment, profile, authenticated, file, assets, identity))
            return error.InvalidOwner;
        var profile_authority = ProductionProfile{ .allocator = allocator, .context = context, .environment = environment, .owner = profile };
        var identity_authority = ProductionIdentity{ .authenticated = authenticated, .file = file, .assets = assets, .owner = identity };
        return self.revalidateOwned(&profile_authority, &identity_authority);
    }

    pub fn revalidateWith(self: *const @This(), profile: anytype, identity: anytype) Error!evidence.Predecessor {
        if (!builtin.is_test) @compileError("revalidateWith is test-only");
        return self.revalidateOwned(profile, identity);
    }

    fn revalidateOwned(self: *const @This(), profile: anytype, identity: anytype) Error!evidence.Predecessor {
        if (!self.validSeal() or
            aliasesAuthorities(std.mem.asBytes(self), profile, identity)) return error.InvalidOwner;
        const document_sha256 = profile.documentSha256() orelse return error.AuthorityChanged;
        const selected = profile.revalidate() catch return error.AuthorityChanged;
        const endorsed = selected.predecessor() orelse return error.AuthorityChanged;
        const authenticated = identity.revalidate() catch return error.AuthorityChanged;
        if (!std.mem.eql(u8, &document_sha256, &self.document_sha256) or
            !matchesEndorsement(endorsed, authenticated) or !equal(self.storedValue(), authenticated))
            return error.AuthorityChanged;
        return self.storedValue();
    }

    pub fn deinit(self: *@This()) Error!void {
        if (!self.validSeal()) return error.InvalidOwner;
        self.* = .{};
    }

    fn validSeal(self: *const @This()) bool {
        return self.owner == self and self.release_id != 0 and self.tag_len != 0 and self.tag_len <= self.tag.len and
            std.mem.eql(u8, &self.seal, &ownerSeal(self));
    }

    fn storedValue(self: *const @This()) evidence.Predecessor {
        return .{
            .release_id = self.release_id,
            .tag = self.tag[0..self.tag_len],
            .commit = &self.commit,
            .manifest_sha256 = &self.manifest_sha256,
            .dmg_sha256 = &self.dmg_sha256,
            .executable_sha256 = &self.executable_sha256,
        };
    }
};

pub fn bind(
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    environment: profile_mod.Environment,
    profile: *const profile_mod.Owner,
    authenticated: *const authenticated_mod.AuthenticatedManifest,
    file: *const file_mod.ManifestFile,
    assets: *const assets_mod.AuthenticatedPredecessorAssets,
    identity: *const identity_mod.PredecessorEvidenceIdentity,
    result: *BoundPredecessor,
) Error!void {
    if (aliasesProduction(std.mem.asBytes(result), context, environment, profile, authenticated, file, assets, identity))
        return error.InvalidOwner;
    var profile_authority = ProductionProfile{ .allocator = allocator, .context = context, .environment = environment, .owner = profile };
    var identity_authority = ProductionIdentity{ .authenticated = authenticated, .file = file, .assets = assets, .owner = identity };
    return bindOwned(&profile_authority, &identity_authority, result);
}

pub fn bindWith(profile: anytype, identity: anytype, result: *BoundPredecessor) Error!void {
    if (!builtin.is_test) @compileError("bindWith is test-only");
    return bindOwned(profile, identity, result);
}

fn bindOwned(profile: anytype, identity: anytype, result: *BoundPredecessor) Error!void {
    if (!result.isPristineForComposition() or aliasesAuthorities(std.mem.asBytes(result), profile, identity))
        return error.InvalidOwner;
    const document_sha256 = profile.documentSha256() orelse return error.InvalidOwner;
    const selected = profile.revalidate() catch return error.AuthorityChanged;
    const endorsed = selected.predecessor() orelse return error.ProfileMismatch;
    const authenticated = identity.revalidate() catch return error.AuthorityChanged;
    if (!validAuthenticated(authenticated) or !matchesEndorsement(endorsed, authenticated)) return error.BindingMismatch;
    if (!result.isPristineForComposition() or aliasesAuthorities(std.mem.asBytes(result), profile, identity) or
        aliasesValue(std.mem.asBytes(result), authenticated)) return error.InvalidOwner;
    const final_document_sha256 = profile.documentSha256() orelse return error.AuthorityChanged;
    const final_selected = profile.revalidate() catch return error.AuthorityChanged;
    const final_endorsed = final_selected.predecessor() orelse return error.AuthorityChanged;
    const final_authenticated = identity.revalidate() catch return error.AuthorityChanged;
    if (!std.mem.eql(u8, &document_sha256, &final_document_sha256) or
        !matchesEndorsement(final_endorsed, final_authenticated) or !equal(authenticated, final_authenticated))
        return error.AuthorityChanged;
    if (!result.isPristineForComposition() or aliasesAuthorities(std.mem.asBytes(result), profile, identity) or
        aliasesValue(std.mem.asBytes(result), final_authenticated)) return error.InvalidOwner;
    result.release_id = authenticated.release_id;
    result.tag_len = authenticated.tag.len;
    @memcpy(result.tag[0..result.tag_len], authenticated.tag);
    @memcpy(&result.commit, authenticated.commit);
    @memcpy(&result.manifest_sha256, authenticated.manifest_sha256);
    @memcpy(&result.dmg_sha256, authenticated.dmg_sha256);
    @memcpy(&result.executable_sha256, authenticated.executable_sha256);
    result.document_sha256 = document_sha256;
    result.owner = result;
    result.seal = ownerSeal(result);
}

const ProductionProfile = struct {
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    environment: profile_mod.Environment,
    owner: *const profile_mod.Owner,

    fn revalidate(self: *@This()) !profile_mod.Value {
        return self.owner.revalidateEnvironment(self.allocator, self.context, self.environment);
    }
    fn documentSha256(self: *const @This()) ?[32]u8 {
        return self.owner.documentSha256();
    }
    fn storage(self: *const @This()) []const u8 {
        return std.mem.asBytes(self.owner);
    }
};

const ProductionIdentity = struct {
    authenticated: *const authenticated_mod.AuthenticatedManifest,
    file: *const file_mod.ManifestFile,
    assets: *const assets_mod.AuthenticatedPredecessorAssets,
    owner: *const identity_mod.PredecessorEvidenceIdentity,

    fn revalidate(self: *@This()) !evidence.Predecessor {
        return self.owner.revalidate(self.authenticated, self.file, self.assets);
    }
    fn storage(self: *const @This()) []const u8 {
        return std.mem.asBytes(self.owner);
    }
};

fn matchesEndorsement(endorsed: manifest.Predecessor, authenticated: evidence.Predecessor) bool {
    return endorsed.release_id == authenticated.release_id and std.mem.eql(u8, endorsed.tag, authenticated.tag) and
        std.mem.eql(u8, endorsed.commit, authenticated.commit) and
        std.mem.eql(u8, endorsed.manifest_sha256, authenticated.manifest_sha256);
}

fn validAuthenticated(value: evidence.Predecessor) bool {
    return value.release_id != 0 and value.tag.len <= manifest.max_scalar_string_bytes and
        release_identity.canonicalTag(value.tag) and release_identity.lowerHex(value.commit, 40) and
        release_identity.lowerHex(value.manifest_sha256, 64) and release_identity.lowerHex(value.dmg_sha256, 64) and
        release_identity.lowerHex(value.executable_sha256, 64);
}

fn equal(left: evidence.Predecessor, right: evidence.Predecessor) bool {
    return left.release_id == right.release_id and std.mem.eql(u8, left.tag, right.tag) and
        std.mem.eql(u8, left.commit, right.commit) and std.mem.eql(u8, left.manifest_sha256, right.manifest_sha256) and
        std.mem.eql(u8, left.dmg_sha256, right.dmg_sha256) and std.mem.eql(u8, left.executable_sha256, right.executable_sha256);
}

fn aliasesAuthorities(candidate: []const u8, profile: anytype, identity: anytype) bool {
    const profile_storage = profile.storage();
    const identity_storage = identity.storage();
    return overlaps(candidate, profile_storage) or overlaps(candidate, identity_storage) or
        overlaps(profile_storage, identity_storage);
}

fn aliasesValue(candidate: []const u8, value: evidence.Predecessor) bool {
    return overlaps(candidate, value.tag) or overlaps(candidate, value.commit) or
        overlaps(candidate, value.manifest_sha256) or overlaps(candidate, value.dmg_sha256) or
        overlaps(candidate, value.executable_sha256);
}

fn aliasesProduction(
    candidate: []const u8,
    context: context_mod.Context,
    environment: profile_mod.Environment,
    profile: *const profile_mod.Owner,
    authenticated: *const authenticated_mod.AuthenticatedManifest,
    file: *const file_mod.ManifestFile,
    assets: *const assets_mod.AuthenticatedPredecessorAssets,
    identity: *const identity_mod.PredecessorEvidenceIdentity,
) bool {
    inline for (.{ std.mem.asBytes(profile), std.mem.asBytes(authenticated), std.mem.asBytes(file), std.mem.asBytes(assets), std.mem.asBytes(identity) }) |storage|
        if (overlaps(candidate, storage)) return true;
    inline for (.{ context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref }) |scalar|
        if (overlaps(candidate, scalar)) return true;
    const environment_pointer = @intFromPtr(environment.context);
    const candidate_start = @intFromPtr(candidate.ptr);
    const candidate_end = std.math.add(usize, candidate_start, candidate.len) catch return true;
    return environment_pointer >= candidate_start and environment_pointer < candidate_end;
}

fn ownerSeal(value: *const BoundPredecessor) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashInteger(&hash, @intFromPtr(value));
    hashInteger(&hash, value.release_id);
    hashScalar(&hash, value.tag[0..value.tag_len]);
    hashScalar(&hash, &value.commit);
    hashScalar(&hash, &value.manifest_sha256);
    hashScalar(&hash, &value.dmg_sha256);
    hashScalar(&hash, &value.executable_sha256);
    hashScalar(&hash, &value.document_sha256);
    return hash.finalResult();
}

fn hashInteger(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var bytes: [@sizeOf(@TypeOf(value))]u8 = undefined;
    std.mem.writeInt(@TypeOf(value), &bytes, value, .big);
    hash.update(&bytes);
}

fn hashScalar(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hashInteger(hash, value.len);
    hash.update(value);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn allZero(bytes: []const u8) bool {
    return std.mem.allEqual(u8, bytes, 0);
}
