//! Reauthenticates current immutable release asset IDs before retained aggregate cleanup.

const std = @import("std");
const builtin = @import("builtin");
const manifest_mod = @import("release_manifest");
const identity = @import("release_adapter_identity");
const context_mod = @import("release_adapter_context");
const reopen = @import("release_adapter_candidate_aggregate_reopen");
const post = @import("release_adapter_github_post_publish_attestation");
const cli_mod = @import("release_adapter_github_cli_authority");
const transport = @import("release_adapter_github_transport");
const transport_macos = @import("release_adapter_github_transport_macos");
const deadline_mod = @import("release_adapter_deadline");

pub const asset_count = post.artifact_count;
pub const ExpectedAsset = struct { path: []const u8, name: []const u8, size: u64, sha256: [64]u8 };
pub const Expected = struct {
    context: context_mod.Context,
    release_id: u64,
    cli_sha256: [64]u8,
    assets: [asset_count]ExpectedAsset,
};
pub const ObservedPublished = struct { release_id: u64, asset_ids: [asset_count]u64 };
pub const Cli = struct { path: [:0]const u8, pinned: *const cli_mod.PinnedExecutable };

const StoredContext = struct {
    repository_id: u64 = 0,
    owner: [context_mod.max_value_bytes]u8 = @splat(0),
    owner_len: usize = 0,
    name: [context_mod.max_value_bytes]u8 = @splat(0),
    name_len: usize = 0,
    tag: [context_mod.max_value_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    workflow_ref: [context_mod.max_value_bytes]u8 = @splat(0),
    workflow_ref_len: usize = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,

    fn value(self: *const @This()) context_mod.Context {
        return .{
            .repository = .{ .id = self.repository_id, .owner = self.owner[0..self.owner_len], .name = self.name[0..self.name_len] },
            .tag = self.tag[0..self.tag_len],
            .source_commit = &self.source_commit,
            .build = .{ .workflow_ref = self.workflow_ref[0..self.workflow_ref_len], .run_id = self.run_id, .run_attempt = self.run_attempt },
            .protected_tag = true,
        };
    }
};

const Frozen = struct {
    context: StoredContext = .{},
    release_id: u64 = 0,
    cli_sha256: [64]u8 = @splat(0),
    paths: [asset_count][std.fs.max_path_bytes]u8 = @splat(@splat(0)),
    path_lens: [asset_count]usize = @splat(0),
    names: [asset_count][manifest_mod.max_scalar_string_bytes]u8 = @splat(@splat(0)),
    name_lens: [asset_count]usize = @splat(0),
    sizes: [asset_count]u64 = @splat(0),
    sha256: [asset_count][64]u8 = @splat(@splat(0)),

    fn expected(self: *const @This()) Expected {
        var assets: [asset_count]ExpectedAsset = undefined;
        for (&assets, 0..) |*asset, index| asset.* = .{
            .path = self.paths[index][0..self.path_lens[index]],
            .name = self.names[index][0..self.name_lens[index]],
            .size = self.sizes[index],
            .sha256 = self.sha256[index],
        };
        return .{ .context = self.context.value(), .release_id = self.release_id, .cli_sha256 = self.cli_sha256, .assets = assets };
    }
};

fn BoundAuthority(comptime Source: type) type {
    return struct {
        owner: ?*@This() = null,
        source: Source,
        source_address: usize,
        frozen: *const Frozen,
        ids: [asset_count]u64,
        seal: [32]u8 = @splat(0),

        pub fn snapshot(self: *@This()) !post.Snapshot {
            try self.validateOwner();
            const current = try self.source.snapshot();
            if (!sameExpected(self.frozen, current)) return error.AuthorityChanged;
            const expected = self.frozen.expected();
            var artifacts: [asset_count]post.Artifact = undefined;
            for (&artifacts, 0..) |*artifact, index| artifact.* = .{
                .id = self.ids[index],
                .path = expected.assets[index].path,
                .name = expected.assets[index].name,
                .size = expected.assets[index].size,
                .sha256 = expected.assets[index].sha256,
            };
            return .{
                .release_id = expected.release_id,
                .tag = expected.context.tag,
                .source_commit = expected.context.source_commit,
                .cli_sha256 = expected.cli_sha256,
                .artifacts = artifacts,
            };
        }

        pub fn executablePath(self: *@This()) ![:0]const u8 {
            try self.validateOwner();
            return self.source.executablePath();
        }

        pub fn releaseContext(self: *@This()) !context_mod.Context {
            _ = try self.snapshot();
            return self.frozen.context.value();
        }

        pub fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
            try self.validateOwner();
            try self.source.revalidate(allocator, path);
            _ = try self.snapshot();
        }

        fn validateOwner(self: *@This()) !void {
            if (self.owner != self or @intFromPtr(self.source) != self.source_address or
                !std.crypto.timing_safe.eql([32]u8, self.seal, self.metadataSeal())) return error.InvalidOwner;
        }

        fn metadataSeal(self: *const @This()) [32]u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("maru.session-host.published-cleanup-authority.v1");
            const address = @intFromPtr(self);
            const frozen_address = @intFromPtr(self.frozen);
            hasher.update(std.mem.asBytes(&address));
            hasher.update(std.mem.asBytes(&self.source_address));
            hasher.update(std.mem.asBytes(&frozen_address));
            hasher.update(std.mem.asBytes(&self.ids));
            var result: [32]u8 = undefined;
            hasher.final(&result);
            return result;
        }
    };
}

fn authenticateCore(source: anytype, remote: anytype, verifier: anytype, deadline: anytype, result: *post.VerifiedRelease) !void {
    if (!pristine(result)) return error.InvalidOwner;
    var published = false;
    defer if (!published and result.value() != null) result.deinit() catch unreachable;

    _ = try deadline.remaining();
    const initial = try source.snapshot();
    try validateExpected(initial);
    var frozen: Frozen = undefined;
    try freeze(&frozen, initial);
    const before_first = try source.snapshot();
    if (!sameExpected(&frozen, before_first)) return error.AuthorityChanged;
    const first = try remote.fetch(frozen.expected(), try deadline.remaining());
    try validateObserved(&frozen, first);

    var authority = BoundAuthority(@TypeOf(source)){
        .source = source,
        .source_address = @intFromPtr(source),
        .frozen = &frozen,
        .ids = first.asset_ids,
    };
    authority.owner = &authority;
    authority.seal = authority.metadataSeal();
    try verifier.verify(&authority, deadline, result);
    const receipt = result.value() orelse return error.InvalidVerified;
    if (!matchesReceipt(&frozen, first, receipt)) return error.InvalidVerified;

    _ = try authority.snapshot();
    const final = try remote.fetch(frozen.expected(), try deadline.remaining());
    try validateObserved(&frozen, final);
    if (!std.meta.eql(first, final)) return error.PublishedChanged;
    _ = try authority.snapshot();
    _ = try deadline.remaining();
    published = true;
}

const AggregateSource = struct {
    allocator: std.mem.Allocator,
    aggregate: *reopen.ReopenedAggregate,
    cli: Cli,

    pub fn snapshot(self: *@This()) !Expected {
        try cli_mod.revalidate(self.allocator, self.cli.path, self.cli.pinned);
        const view = try self.aggregate.fence();
        const manifest_path = aggregateArtifactPath(self.aggregate, 2) orelse return error.InvalidAggregate;
        var held = try self.aggregate.artifacts[2].readHeldAlloc(self.allocator, manifest_path, manifest_mod.max_manifest_bytes);
        defer held.deinit(self.allocator);
        var parsed = try manifest_mod.parseCanonical(self.allocator, held.bytes);
        defer parsed.deinit();
        const candidate = parsed.value();
        try bindManifest(candidate, view);

        const observations = [_]@TypeOf(view.artifacts[0]){ view.artifacts[0], view.artifacts[1], view.entries[0], view.artifacts[2] };
        const paths = [_][]const u8{
            aggregateArtifactPath(self.aggregate, 0).?,
            aggregateArtifactPath(self.aggregate, 1).?,
            aggregateEntryPath(self.aggregate, 0).?,
            manifest_path,
        };
        var assets: [asset_count]ExpectedAsset = undefined;
        for (&assets, 0..) |*asset, index| asset.* = .{
            .path = paths[index],
            .name = std.fs.path.basename(paths[index]),
            .size = observations[index].size,
            .sha256 = observations[index].sha256,
        };
        return .{ .context = view.context, .release_id = candidate.release.id, .cli_sha256 = self.cli.pinned.sha256, .assets = assets };
    }

    pub fn executablePath(self: *@This()) ![:0]const u8 {
        try cli_mod.revalidate(self.allocator, self.cli.path, self.cli.pinned);
        return self.cli.path;
    }

    pub fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        if (!std.meta.eql(allocator, self.allocator) or !std.mem.eql(u8, path, self.cli.path)) return error.InvalidOwner;
        try cli_mod.revalidate(allocator, path, self.cli.pinned);
    }
};

const ProductionRemote = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    source: *AggregateSource,
    token: []const u8,
    response: []u8,

    pub fn fetch(self: *@This(), expected: Expected, budget: i128) !ObservedPublished {
        try self.source.revalidate(self.allocator, self.source.cli.path);
        const bytes = try transport_macos.fetch(self.io, self.allocator, self.source.cli.path, self.token, .{ .published_release = expected.context.tag }, self.response, budget);
        return parseResponse(self.allocator, bytes, expected);
    }
};

const ProductionVerifier = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    token: []const u8,
    response: []u8,

    pub fn verify(self: *@This(), authority: anytype, deadline: *deadline_mod.Deadline, result: *post.VerifiedRelease) !void {
        try post.verifySnapshotUntil(self.io, self.allocator, authority, self.token, self.response, deadline, result);
    }
};

pub fn authenticateUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    aggregate: *reopen.ReopenedAggregate,
    cli: Cli,
    token: []const u8,
    response: []u8,
    deadline: *deadline_mod.Deadline,
    result: *post.VerifiedRelease,
) !void {
    try transport.validateToken(token);
    if (response.len == 0 or response.len > transport.max_response_bytes or !pristine(result)) return error.InvalidOwner;
    const result_bytes = std.mem.asBytes(result);
    const regions = [_][]const u8{ std.mem.asBytes(aggregate), std.mem.asBytes(cli.pinned), std.mem.asBytes(deadline), cli.path, token, response };
    for (regions, 0..) |region, index| {
        if (overlaps(result_bytes, region)) return error.InvalidOwner;
        for (regions[0..index]) |prior| if (overlaps(region, prior)) return error.InvalidOwner;
    }
    var source = AggregateSource{ .allocator = allocator, .aggregate = aggregate, .cli = cli };
    var remote = ProductionRemote{ .io = io, .allocator = allocator, .source = &source, .token = token, .response = response };
    var verifier = ProductionVerifier{ .io = io, .allocator = allocator, .token = token, .response = response };
    try authenticateCore(&source, &remote, &verifier, deadline, result);
}

pub fn assertProductionBoundary() void {
    _ = &authenticateUntil;
}

fn bindManifest(candidate: *const manifest_mod.Manifest, aggregate: reopen.View) !void {
    if (candidate.role != .a or candidate.predecessor != null or candidate.assets.len != 3 or
        candidate.repository.id != aggregate.context.repository.id or
        !std.mem.eql(u8, candidate.repository.owner, aggregate.context.repository.owner) or
        !std.mem.eql(u8, candidate.repository.name, aggregate.context.repository.name) or
        !std.mem.eql(u8, candidate.release.tag, aggregate.context.tag) or
        !std.mem.eql(u8, candidate.source.commit, aggregate.context.source_commit) or
        !std.mem.eql(u8, candidate.build.workflow_ref, aggregate.context.build.workflow_ref) or
        candidate.build.run_id != aggregate.context.build.run_id or candidate.build.run_attempt != aggregate.context.build.run_attempt or
        !aggregate.context.protected_tag) return error.InvalidAggregate;
    const observations = [_]@TypeOf(aggregate.artifacts[0]){ aggregate.artifacts[0], aggregate.artifacts[1], aggregate.entries[0] };
    const names = [_][]const u8{ aggregate.artifact_names[0], aggregate.artifact_names[1], aggregate.evidence_name };
    const roles = [_]manifest_mod.AssetRole{ .universal_dmg, .frozen_product_executable, .evidence_summary };
    for (roles, 0..) |role, index| {
        const asset = assetForRole(candidate.assets, role) orelse return error.InvalidAggregate;
        if (asset.size != observations[index].size or !std.mem.eql(u8, asset.name, names[index]) or
            !std.mem.eql(u8, asset.sha256, &observations[index].sha256)) return error.InvalidAggregate;
    }
}

fn assetForRole(assets: []const manifest_mod.Asset, role: manifest_mod.AssetRole) ?manifest_mod.Asset {
    var result: ?manifest_mod.Asset = null;
    for (assets) |asset| if (asset.role == role) {
        if (result != null) return null;
        result = asset;
    };
    return result;
}

fn validateExpected(value: Expected) !void {
    const context = value.context;
    if (!context.protected_tag or context.repository.id == 0 or !std.mem.eql(u8, context.repository.owner, "ohah") or
        !std.mem.eql(u8, context.repository.name, "maru") or !identity.canonicalTag(context.tag) or
        context.source_commit.len != 40 or !identity.lowerHex(context.source_commit, 40) or context.build.workflow_ref.len == 0 or
        context.build.workflow_ref.len > context_mod.max_value_bytes or context.build.run_id == 0 or context.build.run_attempt == 0 or
        value.release_id == 0 or !identity.lowerHex(&value.cli_sha256, 64)) return error.InvalidExpected;
    for (value.assets, 0..) |asset, index| {
        if (!std.fs.path.isAbsolute(asset.path) or asset.path.len >= std.fs.max_path_bytes or asset.name.len == 0 or
            asset.name.len > manifest_mod.max_scalar_string_bytes or !std.mem.eql(u8, asset.name, std.fs.path.basename(asset.path)) or
            asset.size == 0 or !identity.lowerHex(&asset.sha256, 64)) return error.InvalidExpected;
        for (value.assets[0..index]) |prior| if (std.mem.eql(u8, asset.path, prior.path) or std.mem.eql(u8, asset.name, prior.name)) return error.InvalidExpected;
    }
}

fn validateObserved(expected: *const Frozen, observed: ObservedPublished) !void {
    if (observed.release_id != expected.release_id) return error.InvalidPublished;
    for (observed.asset_ids, 0..) |id, index| {
        if (id == 0) return error.InvalidPublished;
        for (observed.asset_ids[0..index]) |prior| if (id == prior) return error.InvalidPublished;
    }
}

fn freeze(out: *Frozen, value: Expected) !void {
    out.* = .{ .release_id = value.release_id, .cli_sha256 = value.cli_sha256 };
    const context = value.context;
    out.context.repository_id = context.repository.id;
    out.context.owner_len = try copy(&out.context.owner, context.repository.owner);
    out.context.name_len = try copy(&out.context.name, context.repository.name);
    out.context.tag_len = try copy(&out.context.tag, context.tag);
    if (context.source_commit.len != out.context.source_commit.len) return error.InvalidExpected;
    @memcpy(&out.context.source_commit, context.source_commit);
    out.context.workflow_ref_len = try copy(&out.context.workflow_ref, context.build.workflow_ref);
    out.context.run_id = context.build.run_id;
    out.context.run_attempt = context.build.run_attempt;
    for (value.assets, 0..) |asset, index| {
        out.path_lens[index] = try copy(&out.paths[index], asset.path);
        out.name_lens[index] = try copy(&out.names[index], asset.name);
        out.sizes[index] = asset.size;
        out.sha256[index] = asset.sha256;
    }
}

fn copy(out: []u8, value: []const u8) !usize {
    if (value.len == 0 or value.len > out.len) return error.InvalidExpected;
    @memcpy(out[0..value.len], value);
    return value.len;
}

fn sameExpected(fixed: *const Frozen, current: Expected) bool {
    validateExpected(current) catch return false;
    const expected = fixed.expected();
    if (expected.release_id != current.release_id or !sameContext(expected.context, current.context) or
        !std.mem.eql(u8, &expected.cli_sha256, &current.cli_sha256)) return false;
    for (expected.assets, current.assets) |left, right| if (left.size != right.size or !std.mem.eql(u8, left.path, right.path) or
        !std.mem.eql(u8, left.name, right.name) or !std.mem.eql(u8, &left.sha256, &right.sha256)) return false;
    return true;
}

fn sameContext(left: context_mod.Context, right: context_mod.Context) bool {
    return left.protected_tag == right.protected_tag and left.repository.id == right.repository.id and
        std.mem.eql(u8, left.repository.owner, right.repository.owner) and std.mem.eql(u8, left.repository.name, right.repository.name) and
        std.mem.eql(u8, left.tag, right.tag) and std.mem.eql(u8, left.source_commit, right.source_commit) and
        std.mem.eql(u8, left.build.workflow_ref, right.build.workflow_ref) and left.build.run_id == right.build.run_id and
        left.build.run_attempt == right.build.run_attempt;
}

fn matchesReceipt(expected: *const Frozen, observed: ObservedPublished, receipt: post.View) bool {
    const value = expected.expected();
    if (receipt.release_id != value.release_id or !std.mem.eql(u8, receipt.tag, value.context.tag) or
        !std.mem.eql(u8, receipt.source_commit, value.context.source_commit) or !std.mem.eql(u64, &receipt.artifact_ids, &observed.asset_ids)) return false;
    for (receipt.artifact_sha256, value.assets) |digest, asset| if (!std.mem.eql(u8, &digest, &asset.sha256)) return false;
    return true;
}

const StrictU64 = struct {
    value: u64,
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !StrictU64 {
        if (try source.peekNextTokenType() != .number) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse(u64, allocator, source, options) };
    }
};
const ApiAsset = struct { id: StrictU64, name: []const u8, size: StrictU64, state: []const u8, digest: []const u8, content_type: []const u8 };
const ApiRelease = struct { id: StrictU64, tag_name: []const u8, target_commitish: []const u8, draft: bool, prerelease: bool, immutable: bool, assets: []ApiAsset };

fn parseResponse(allocator: std.mem.Allocator, bytes: []const u8, expected: Expected) !ObservedPublished {
    try validateExpected(expected);
    if (bytes.len == 0 or bytes.len > transport.max_response_bytes) return error.InvalidResponse;
    var parsed = std.json.parseFromSlice(ApiRelease, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true, .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    const value = parsed.value;
    if (value.id.value != expected.release_id or !std.mem.eql(u8, value.tag_name, expected.context.tag) or
        !std.mem.eql(u8, value.target_commitish, expected.context.source_commit) or value.draft or value.prerelease or !value.immutable or
        value.assets.len != asset_count) return error.InvalidResponse;
    var result = ObservedPublished{ .release_id = value.id.value, .asset_ids = @splat(0) };
    var seen: [asset_count]bool = @splat(false);
    for (value.assets) |asset| {
        var matched: ?usize = null;
        for (expected.assets, 0..) |candidate, index| if (std.mem.eql(u8, asset.name, candidate.name)) {
            matched = index;
            break;
        };
        const index = matched orelse return error.InvalidResponse;
        if (seen[index] or asset.id.value == 0 or asset.size.value != expected.assets[index].size or
            !std.mem.eql(u8, asset.state, "uploaded") or !std.mem.eql(u8, asset.content_type, "application/octet-stream")) return error.InvalidResponse;
        var digest: ["sha256:".len + 64]u8 = undefined;
        _ = std.fmt.bufPrint(&digest, "sha256:{s}", .{expected.assets[index].sha256}) catch unreachable;
        if (!std.mem.eql(u8, asset.digest, &digest)) return error.InvalidResponse;
        for (result.asset_ids[0..index]) |prior| if (prior == asset.id.value) return error.InvalidResponse;
        // IDs arrive in arbitrary asset order, so compare against every already accepted slot.
        for (result.asset_ids) |prior| if (prior != 0 and prior == asset.id.value) return error.InvalidResponse;
        result.asset_ids[index] = asset.id.value;
        seen[index] = true;
    }
    for (seen) |present| if (!present) return error.InvalidResponse;
    return result;
}

fn aggregateArtifactPath(aggregate: *const reopen.ReopenedAggregate, index: usize) ?[:0]const u8 {
    if (index >= aggregate.artifact_paths.len) return null;
    const len = aggregate.artifact_path_lens[index];
    if (len == 0 or len >= aggregate.artifact_paths[index].len or aggregate.artifact_paths[index][len] != 0) return null;
    return aggregate.artifact_paths[index][0..len :0];
}

fn aggregateEntryPath(aggregate: *const reopen.ReopenedAggregate, index: usize) ?[:0]const u8 {
    if (index >= aggregate.paths.len) return null;
    const len = aggregate.path_lens[index];
    if (len == 0 or len >= aggregate.paths[index].len or aggregate.paths[index][len] != 0) return null;
    return aggregate.paths[index][0..len :0];
}

fn pristine(result: *const post.VerifiedRelease) bool {
    return result.owner == null and result.release_id == 0 and result.tag_len == 0 and std.mem.allEqual(u8, &result.tag, 0) and
        std.mem.allEqual(u8, &result.source_commit, 0) and std.mem.allEqual(u8, &result.tag_ref_sha, 0) and
        std.mem.allEqual(u64, &result.artifact_ids, 0) and std.mem.allEqual(u8, std.mem.asBytes(&result.artifact_sha256), 0) and
        std.mem.allEqual(u8, &result.seal, 0);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

pub const testing_api = if (builtin.is_test) struct {
    pub fn authenticate(source: anytype, remote: anytype, verifier: anytype, deadline: anytype, result: *post.VerifiedRelease) !void {
        try authenticateCore(source, remote, verifier, deadline, result);
    }
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, expected: Expected) !ObservedPublished {
        return parseResponse(allocator, bytes, expected);
    }
} else struct {};
