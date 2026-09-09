//! Attested semantic transaction for one downloaded immutable GitHub Release.

const std = @import("std");
const c = std.c;
const context_mod = @import("release_adapter_context");
const metadata = @import("release_adapter_remote_release_metadata");
const fence_mod = @import("release_adapter_remote_release_fence");
const assets_mod = @import("release_adapter_remote_release_assets");
const semantics_mod = @import("release_adapter_remote_release_semantics");
const semantic_files = @import("release_adapter_remote_release_semantic_files");
const attestation = @import("release_adapter_github_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const github_transport = @import("release_adapter_github_transport");
const deadline_mod = @import("release_adapter_deadline");

const roles = [_]metadata.Role{ .dmg, .frozen_host, .evidence_candidate, .manifest };

pub const Cli = struct { path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable };

pub const View = struct {
    profile: @import("release_evidence").Profile,
    release_id: u64,
};

pub const Observation = struct {
    owner: ?*@This() = null,
    fence_owner: ?*const fence_mod.Fence = null,
    assets_owner: ?*assets_mod.Assets = null,
    deadline_owner: ?*deadline_mod.Deadline = null,
    pinned_owner: ?*const cli_authority.PinnedExecutable = null,
    semantics: semantics_mod.Owner = .{},
    receipts: [metadata.asset_count]?attestation.Observed = @splat(null),
    seal: [32]u8 = @splat(0),

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or !std.crypto.timing_safe.eql([32]u8, self.seal, ownerSeal(self))) return null;
        const release_fence = self.fence_owner orelse return null;
        const downloaded = self.assets_owner orelse return null;
        const deadline = self.deadline_owner orelse return null;
        const pinned = self.pinned_owner orelse return null;
        const remote = release_fence.value() orelse return null;
        const files = downloaded.revalidateFor(release_fence, deadline, pinned) catch return null;
        const semantic = self.semantics.value() orelse return null;
        const semantic_manifest = if (self.semantics.parsed_manifest) |*parsed| parsed.value() else return null;
        if (semantic.release_id != remote.release_id) return null;
        for (roles, 0..) |role, index| {
            const receipt = if (self.receipts[index]) |*observed| observed else return null;
            const expected = remote.assets[index];
            const file = files.assets[index];
            if (file.role != role or file.id != expected.id or file.size != expected.size or
                !std.mem.eql(u8, file.name, expected.name) or !std.mem.eql(u8, file.sha256, expected.sha256) or
                !validReceipt(receipt, expected, semantic_manifest.build.run_id, semantic_manifest.build.run_attempt)) return null;
        }
        return .{ .profile = semantic.profile, .release_id = semantic.release_id };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) !void {
        if (self.owner != self or !std.crypto.timing_safe.eql([32]u8, self.seal, ownerSeal(self))) return error.InvalidOwner;
        cleanup(self, allocator);
    }
};

const RealAuthority = struct {
    pinned: *const cli_authority.PinnedExecutable,
    fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};

const RealAttestor = struct {
    fn verify(_: *@This(), executor: anytype, allocator: std.mem.Allocator, executable: []const u8, token: []const u8, directory_fd: c.fd_t, artifact_path: []const u8, expected: attestation.Expected, output: []u8, budget_ns: i128) !attestation.Observed {
        return attestation.verifyDirectoryWith(executor, allocator, executable, token, directory_fd, artifact_path, expected, output, budget_ns);
    }
};

const RealSemanticBinder = struct {
    fn bind(_: *@This(), allocator: std.mem.Allocator, context: context_mod.Context, downloaded: anytype, result: *semantics_mod.Owner) !void {
        try semantic_files.bind(allocator, context, downloaded, result);
    }
};

const RealFenceVerifier = struct {
    io: std.Io,
    fn verify(self: *@This(), allocator: std.mem.Allocator, context: context_mod.Context, executable: [:0]const u8, pinned: *const cli_authority.PinnedExecutable, token: []const u8, response: []u8, deadline: *deadline_mod.Deadline, release_fence: *fence_mod.Fence) !void {
        try fence_mod.verifyAfterUntil(self.io, allocator, context, executable, pinned, token, response, deadline, release_fence);
    }
};

pub fn composeUntil(io: std.Io, allocator: std.mem.Allocator, context: context_mod.Context, release_fence: *fence_mod.Fence, downloaded: *assets_mod.Assets, cli: Cli, token: []const u8, metadata_response: []u8, attestation_output: []u8, deadline: *deadline_mod.Deadline, result: *Observation) !void {
    var authority = RealAuthority{ .pinned = cli.pinned };
    var attestor = RealAttestor{};
    var executor = attestation.BoundedExecutor{ .io = io };
    var binder = RealSemanticBinder{};
    var fence_verifier = RealFenceVerifier{ .io = io };
    return composeUntilWith(&authority, &attestor, &executor, &binder, &fence_verifier, allocator, context, release_fence, downloaded, cli.path, cli.pinned, token, metadata_response, attestation_output, deadline, result);
}

pub fn composeUntilWith(authority: anytype, attestor: anytype, executor: anytype, binder: anytype, fence_verifier: anytype, allocator: std.mem.Allocator, context: context_mod.Context, release_fence: *fence_mod.Fence, downloaded: anytype, executable: [:0]const u8, pinned: *const cli_authority.PinnedExecutable, token: []const u8, metadata_response: []u8, attestation_output: []u8, deadline: *deadline_mod.Deadline, result: *Observation) !void {
    if (!pristine(result) or aliasesInputs(context, release_fence, downloaded, executable, pinned, token, metadata_response, attestation_output, deadline, result)) return error.InvalidOwner;
    try context_mod.validateTrusted(context);
    try github_transport.validateToken(token);
    if (metadata_response.len == 0 or metadata_response.len > github_transport.max_response_bytes or
        attestation_output.len == 0 or attestation_output.len > attestation.max_response_bytes) return error.ResponseTooLarge;
    const initial_context_seal = contextSeal(context);
    const initial_remote = release_fence.candidateFor(deadline, pinned) orelse return error.InvalidFence;
    const initial_files = downloaded.revalidateFor(release_fence, deadline, pinned) catch return error.InvalidAssets;
    var published = false;
    defer if (!published) cleanup(result, allocator);

    for (roles, 0..) |_, index| {
        if (!std.crypto.timing_safe.eql([32]u8, initial_context_seal, contextSeal(context))) return error.AuthorityChanged;
        _ = try deadline.remaining();
        const before_remote = release_fence.candidateFor(deadline, pinned) orelse return error.InvalidFence;
        const before_files = downloaded.revalidateFor(release_fence, deadline, pinned) catch return error.InvalidAssets;
        if (!sameRemote(initial_remote, before_remote) or !sameFile(initial_files.assets[index], before_files.assets[index])) return error.AuthorityChanged;
        try authority.revalidate(allocator, executable);
        const directory_fd = downloaded.directoryFdFor(release_fence, deadline, pinned) catch return error.InvalidAssets;
        var relative_storage: [metadata.max_name_bytes + 3]u8 = undefined;
        const relative = std.fmt.bufPrint(&relative_storage, "./{s}", .{initial_remote.assets[index].name}) catch return error.InvalidAssets;
        var receipt = try attestor.verify(executor, allocator, executable, token, directory_fd, relative, .{
            .context = context,
            .subject_name = initial_remote.assets[index].name,
            .subject_sha256 = initial_remote.assets[index].sha256,
        }, attestation_output, try deadline.remaining());
        errdefer receipt.deinit(allocator);
        if (!std.crypto.timing_safe.eql([32]u8, initial_context_seal, contextSeal(context))) return error.AuthorityChanged;
        try authority.revalidate(allocator, executable);
        const after_remote = release_fence.candidateFor(deadline, pinned) orelse return error.InvalidFence;
        const after_files = downloaded.revalidateFor(release_fence, deadline, pinned) catch return error.InvalidAssets;
        if (!sameRemote(initial_remote, after_remote) or !sameFile(initial_files.assets[index], after_files.assets[index]) or
            !validReceipt(&receipt, initial_remote.assets[index], context.build.run_id, context.build.run_attempt)) return error.AuthorityChanged;
        result.receipts[index] = receipt;
    }

    try binder.bind(allocator, context, downloaded, &result.semantics);
    if (result.semantics.value() == null) return error.InvalidSemantics;
    try fence_verifier.verify(allocator, context, executable, pinned, token, metadata_response, deadline, release_fence);
    _ = try deadline.remaining();
    if (release_fence.value() == null) return error.InvalidFence;
    _ = downloaded.revalidateFor(release_fence, deadline, pinned) catch return error.InvalidAssets;
    if (result.semantics.value() == null or !std.crypto.timing_safe.eql([32]u8, initial_context_seal, contextSeal(context))) return error.InvalidSemantics;
    try authority.revalidate(allocator, executable);
    _ = try deadline.remaining();
    result.fence_owner = release_fence;
    result.assets_owner = downloaded;
    result.deadline_owner = deadline;
    result.pinned_owner = pinned;
    result.owner = result;
    result.seal = ownerSeal(result);
    if (result.value() == null) return error.AuthorityChanged;
    published = true;
}

fn validReceipt(receipt: *const attestation.Observed, expected: metadata.Asset, run_id: u64, run_attempt: u64) bool {
    return receipt.verified and receipt.run_id == run_id and receipt.run_attempt == run_attempt and
        std.mem.eql(u8, receipt.subject_name, expected.name) and std.mem.eql(u8, receipt.subject_sha256, expected.sha256);
}

fn sameFile(a: assets_mod.Asset, b: assets_mod.Asset) bool {
    return a.role == b.role and a.id == b.id and a.device == b.device and a.inode == b.inode and a.size == b.size and
        std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.path, b.path) and std.mem.eql(u8, a.sha256, b.sha256);
}

fn sameRemote(a: metadata.View, b: metadata.View) bool {
    if (a.release_id != b.release_id or !std.mem.eql(u8, a.tag, b.tag) or !std.mem.eql(u8, a.source_commit, b.source_commit)) return false;
    for (a.assets, b.assets) |left, right| if (left.id != right.id or left.size != right.size or
        !std.mem.eql(u8, left.name, right.name) or !std.mem.eql(u8, left.sha256, right.sha256)) return false;
    return true;
}

fn cleanup(result: *Observation, allocator: std.mem.Allocator) void {
    if (result.semantics.owner == &result.semantics) result.semantics.deinit(allocator) catch {};
    var index = result.receipts.len;
    while (index > 0) {
        index -= 1;
        if (result.receipts[index]) |*receipt| receipt.deinit(allocator);
        result.receipts[index] = null;
    }
    result.* = .{};
}

fn pristine(result: *const Observation) bool {
    if (result.owner != null or result.fence_owner != null or result.assets_owner != null or result.deadline_owner != null or
        result.pinned_owner != null or !result.semantics.isPristineForComposition() or !std.mem.allEqual(u8, &result.seal, 0)) return false;
    for (result.receipts) |receipt| if (receipt != null) return false;
    return true;
}

fn ownerSeal(result: *const Observation) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host.remote-release-observation.v1");
    const owner_address = @intFromPtr(result);
    const fence_address = if (result.fence_owner) |value| @intFromPtr(value) else 0;
    const assets_address = if (result.assets_owner) |value| @intFromPtr(value) else 0;
    const deadline_address = if (result.deadline_owner) |value| @intFromPtr(value) else 0;
    const pinned_address = if (result.pinned_owner) |value| @intFromPtr(value) else 0;
    hash.update(std.mem.asBytes(&owner_address));
    hash.update(std.mem.asBytes(&fence_address));
    hash.update(std.mem.asBytes(&assets_address));
    hash.update(std.mem.asBytes(&deadline_address));
    hash.update(std.mem.asBytes(&pinned_address));
    for (result.receipts) |receipt| if (receipt) |value| {
        hash.update(std.mem.asBytes(&value.verified));
        hash.update(std.mem.asBytes(&value.run_id));
        hash.update(std.mem.asBytes(&value.run_attempt));
        hashPart(&hash, value.subject_name);
        hashPart(&hash, value.subject_sha256);
    } else hash.update("missing");
    var seal: [32]u8 = undefined;
    hash.final(&seal);
    return seal;
}

fn aliasesInputs(context: context_mod.Context, release_fence: *const fence_mod.Fence, downloaded: anytype, executable: []const u8, pinned: *const cli_authority.PinnedExecutable, token: []const u8, metadata_response: []u8, attestation_output: []u8, deadline: *const deadline_mod.Deadline, result: *const Observation) bool {
    const inputs = [_][]const u8{ std.mem.asBytes(release_fence), std.mem.asBytes(downloaded), std.mem.asBytes(pinned), std.mem.asBytes(deadline), executable, token, metadata_response, attestation_output, context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref };
    const output = std.mem.asBytes(result);
    for (inputs, 0..) |input, index| {
        if (overlaps(output, input)) return true;
        for (inputs[0..index]) |prior| if (overlaps(input, prior)) return true;
    }
    return false;
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return @intFromPtr(a.ptr) < @intFromPtr(b.ptr) + b.len and @intFromPtr(b.ptr) < @intFromPtr(a.ptr) + a.len;
}

fn hashPart(hash: *std.crypto.hash.Blake3, bytes: []const u8) void {
    hash.update(std.mem.asBytes(&bytes.len));
    hash.update(bytes);
}

fn contextSeal(context: context_mod.Context) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host.remote-release-observation.context.v1");
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
