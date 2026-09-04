//! Fixed predecessor identity derived only from authenticated manifest and held artifact owners.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("release_manifest");
const evidence = @import("release_evidence");
const manifest_file = @import("release_adapter_github_manifest_file");
const authenticated_manifest = @import("release_adapter_github_manifest_attestation");
const predecessor_assets = @import("release_adapter_github_predecessor_assets");

pub const ManifestView = authenticated_manifest.AuthenticatedManifest.EvidenceView;
pub const FileObservation = manifest_file.Observation;
pub const AssetObservation = struct { role: manifest.AssetRole, path: []const u8, device: u64, inode: u64, size: u64, sha256: []const u8 };
pub const AssetsView = struct { source_commit: []const u8, assets: [3]AssetObservation };

pub const PredecessorEvidenceIdentity = struct {
    owner: ?*@This() = null,
    release_id: u64 = 0,
    tag: [manifest.max_scalar_string_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    commit: [40]u8 = @splat(0),
    manifest_sha256: [64]u8 = @splat(0),
    dmg_sha256: [64]u8 = @splat(0),
    executable_sha256: [64]u8 = @splat(0),

    pub fn revalidate(self: *const @This(), authenticated: *const authenticated_manifest.AuthenticatedManifest, file: *const manifest_file.ManifestFile, assets: *const predecessor_assets.AuthenticatedPredecessorAssets) !evidence.Predecessor {
        return self.revalidateOwned(authenticated, file, assets);
    }
    pub fn revalidateWith(self: *const @This(), authenticated: anytype, file: anytype, assets: anytype) !evidence.Predecessor {
        if (!builtin.is_test) @compileError("revalidateWith is test-only");
        return self.revalidateOwned(authenticated, file, assets);
    }
    fn revalidateOwned(self: *const @This(), authenticated: anytype, file: anytype, assets: anytype) !evidence.Predecessor {
        if (self.owner != self) return error.InvalidOwner;
        const derived = try derive(authenticated, file, assets, null);
        const stored = self.value();
        if (!equal(stored, derived)) return error.BindingMismatch;
        return stored;
    }
    pub fn deinit(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        self.* = .{};
    }
    fn value(self: *const @This()) evidence.Predecessor {
        return .{ .release_id = self.release_id, .tag = self.tag[0..self.tag_len], .commit = &self.commit, .manifest_sha256 = &self.manifest_sha256, .dmg_sha256 = &self.dmg_sha256, .executable_sha256 = &self.executable_sha256 };
    }
};

pub fn compose(authenticated: *const authenticated_manifest.AuthenticatedManifest, file: *const manifest_file.ManifestFile, assets: *const predecessor_assets.AuthenticatedPredecessorAssets, result: *PredecessorEvidenceIdentity) !void {
    return composeOwned(authenticated, file, assets, result);
}

pub fn composeWith(authenticated: anytype, file: anytype, assets: anytype, result: *PredecessorEvidenceIdentity) !void {
    if (!builtin.is_test) @compileError("composeWith is test-only");
    return composeOwned(authenticated, file, assets, result);
}

fn composeOwned(authenticated: anytype, file: anytype, assets: anytype, result: *PredecessorEvidenceIdentity) !void {
    if (!pristine(result) or overlaps(std.mem.asBytes(result), std.mem.asBytes(authenticated)) or overlaps(std.mem.asBytes(result), std.mem.asBytes(file)) or overlaps(std.mem.asBytes(result), std.mem.asBytes(assets))) return error.InvalidOwner;
    const value = try derive(authenticated, file, assets, std.mem.asBytes(result));
    inline for (.{ value.tag, value.commit, value.manifest_sha256, value.dmg_sha256, value.executable_sha256 }) |bytes|
        if (overlaps(std.mem.asBytes(result), bytes)) return error.InvalidOwner;
    if (value.tag.len > result.tag.len) return error.BindingMismatch;
    result.release_id = value.release_id;
    result.tag_len = value.tag.len;
    @memcpy(result.tag[0..result.tag_len], value.tag);
    @memcpy(&result.commit, value.commit);
    @memcpy(&result.manifest_sha256, value.manifest_sha256);
    @memcpy(&result.dmg_sha256, value.dmg_sha256);
    @memcpy(&result.executable_sha256, value.executable_sha256);
    result.owner = result;
}

fn derive(authenticated: anytype, file: anytype, assets_owner: anytype, forbidden: ?[]const u8) !evidence.Predecessor {
    const authenticated_view = authenticated.evidenceView() orelse return error.InvalidOwner;
    const candidate = authenticated_view.value;
    if (forbidden) |bytes| {
        if (manifest.aliasesStorage(candidate, bytes) or overlaps(bytes, authenticated_view.subject_name) or
            overlaps(bytes, authenticated_view.subject_sha256)) return error.InvalidOwner;
    }
    manifest.validateIntrinsic(candidate.*) catch return error.BindingMismatch;
    if (candidate.role != .a or candidate.predecessor != null or authenticated_view.run_id != candidate.build.run_id or authenticated_view.run_attempt != candidate.build.run_attempt) return error.BindingMismatch;
    const held_file = try file.revalidate();
    var expected_name_storage: [manifest.max_asset_name_bytes]u8 = undefined;
    const expected_name = std.fmt.bufPrint(&expected_name_storage, "Maru-{s}-session-host-release.json", .{candidate.release.version}) catch return error.BindingMismatch;
    if (!std.mem.eql(u8, authenticated_view.subject_name, expected_name) or !std.mem.eql(u8, std.fs.path.basename(held_file.path), expected_name) or !std.mem.eql(u8, authenticated_view.subject_sha256, held_file.sha256)) return error.BindingMismatch;
    const held = try assets_owner.revalidateEvidence();
    if (forbidden) |bytes| {
        if (overlaps(bytes, held.source_commit)) return error.InvalidOwner;
        for (held.assets) |observed| {
            if (overlaps(bytes, observed.path) or overlaps(bytes, observed.sha256)) return error.InvalidOwner;
        }
    }
    if (!std.mem.eql(u8, held.source_commit, candidate.source.commit)) return error.BindingMismatch;
    var dmg: ?[]const u8 = null;
    var executable: ?[]const u8 = null;
    for (candidate.assets) |expected| {
        var found: ?AssetObservation = null;
        for (held.assets) |observed| if (observed.role == expected.role) {
            found = .{ .role = observed.role, .path = observed.path, .device = observed.device, .inode = observed.inode, .size = observed.size, .sha256 = observed.sha256 };
            break;
        };
        const observed = found orelse return error.BindingMismatch;
        if (!std.mem.eql(u8, std.fs.path.basename(observed.path), expected.name) or observed.size != expected.size or !std.mem.eql(u8, observed.sha256, expected.sha256)) return error.BindingMismatch;
        switch (expected.role) {
            .universal_dmg => dmg = observed.sha256,
            .frozen_product_executable => executable = observed.sha256,
            .evidence_summary => {},
        }
    }
    return .{ .release_id = candidate.release.id, .tag = candidate.release.tag, .commit = candidate.source.commit, .manifest_sha256 = held_file.sha256, .dmg_sha256 = dmg orelse return error.BindingMismatch, .executable_sha256 = executable orelse return error.BindingMismatch };
}
fn equal(a: evidence.Predecessor, b: evidence.Predecessor) bool {
    return a.release_id == b.release_id and std.mem.eql(u8, a.tag, b.tag) and std.mem.eql(u8, a.commit, b.commit) and std.mem.eql(u8, a.manifest_sha256, b.manifest_sha256) and std.mem.eql(u8, a.dmg_sha256, b.dmg_sha256) and std.mem.eql(u8, a.executable_sha256, b.executable_sha256);
}
fn pristine(result: *const PredecessorEvidenceIdentity) bool {
    return result.owner == null and result.release_id == 0 and result.tag_len == 0 and std.mem.allEqual(u8, &result.commit, 0) and std.mem.allEqual(u8, &result.manifest_sha256, 0) and std.mem.allEqual(u8, &result.dmg_sha256, 0) and std.mem.allEqual(u8, &result.executable_sha256, 0);
}
fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const le = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const re = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < re and @intFromPtr(right.ptr) < le;
}
