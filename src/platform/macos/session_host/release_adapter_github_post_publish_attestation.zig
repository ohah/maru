//! Binds one just-published release to its tag chain and every held release artifact.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("release_manifest");
const attachment = @import("release_adapter_github_draft_asset_attachment");
const redownload = @import("release_adapter_github_draft_asset_redownload");
const publication = @import("release_adapter_github_draft_publication");
const release_attestation = @import("release_adapter_github_release_attestation");
const tag_authority = @import("release_adapter_github_tag_authority");
const cli_authority = @import("release_adapter_github_cli_authority");
const transport_macos = @import("release_adapter_github_transport_macos");
const deadline_mod = @import("release_adapter_deadline");
const context_mod = @import("release_adapter_context");

pub const artifact_count = attachment.asset_count;
pub const Artifact = struct { id: u64, path: []const u8, name: []const u8, size: u64, sha256: [64]u8 };
pub const Snapshot = struct { release_id: u64, tag: []const u8, source_commit: []const u8, cli_sha256: [64]u8, artifacts: [artifact_count]Artifact };
pub const ResolvedTag = struct { tag_ref_sha: [40]u8, source_commit: [40]u8 };
pub const Observation = struct { release_id: u64, tag_ref_sha: [40]u8, artifact_index: ?usize };
pub const View = struct { release_id: u64, tag: []const u8, source_commit: []const u8, tag_ref_sha: []const u8, artifact_ids: [artifact_count]u64, artifact_sha256: [artifact_count][64]u8 };

pub const VerifiedRelease = struct {
    owner: ?*VerifiedRelease = null,
    release_id: u64 = 0,
    tag: [128]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    tag_ref_sha: [40]u8 = @splat(0),
    artifact_ids: [artifact_count]u64 = @splat(0),
    artifact_sha256: [artifact_count][64]u8 = @splat(@splat(0)),

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or self.release_id == 0 or self.tag_len == 0 or self.tag_len > self.tag.len or !lowerHex(&self.source_commit, 40) or !lowerHex(&self.tag_ref_sha, 40)) return null;
        for (self.artifact_ids, 0..) |id, index| {
            if (id == 0 or !lowerHex(&self.artifact_sha256[index], 64)) return null;
            for (self.artifact_ids[0..index]) |prior| if (id == prior) return null;
        }
        return .{ .release_id = self.release_id, .tag = self.tag[0..self.tag_len], .source_commit = &self.source_commit, .tag_ref_sha = &self.tag_ref_sha, .artifact_ids = self.artifact_ids, .artifact_sha256 = self.artifact_sha256 };
    }
    pub fn deinit(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        self.* = .{};
    }
};

const Frozen = struct {
    release_id: u64,
    tag: [128]u8 = @splat(0),
    tag_len: usize,
    source_commit: [40]u8,
    cli_sha256: [64]u8,
    ids: [artifact_count]u64,
    paths: [artifact_count][std.fs.max_path_bytes]u8 = @splat(@splat(0)),
    path_lens: [artifact_count]usize,
    names: [artifact_count][attachment.max_asset_name_bytes]u8 = @splat(@splat(0)),
    name_lens: [artifact_count]usize,
    sizes: [artifact_count]u64,
    sha256: [artifact_count][64]u8,
    fn view(self: *const @This()) Snapshot {
        var artifacts: [artifact_count]Artifact = undefined;
        for (&artifacts, 0..) |*a, i| a.* = .{ .id = self.ids[i], .path = self.paths[i][0..self.path_lens[i]], .name = self.names[i][0..self.name_lens[i]], .size = self.sizes[i], .sha256 = self.sha256[i] };
        return .{ .release_id = self.release_id, .tag = self.tag[0..self.tag_len], .source_commit = &self.source_commit, .cli_sha256 = self.cli_sha256, .artifacts = artifacts };
    }
};

fn verifyCore(authority: anytype, driver: anytype, deadline: anytype, result: *VerifiedRelease) !void {
    if (!pristine(result)) return error.InvalidOwner;
    _ = try deadline.remaining();
    const first = try authority.snapshot();
    try validate(first);
    var fixed: Frozen = undefined;
    freeze(&fixed, first);
    const resolved = try driver.resolve(fixed.view(), try deadline.remaining());
    if (!std.mem.eql(u8, &resolved.source_commit, fixed.view().source_commit) or !lowerHex(&resolved.tag_ref_sha, 40)) return error.SourceMismatch;
    try fence(authority, &fixed);
    const release_observed = try driver.verify(fixed.view(), resolved, null, try deadline.remaining());
    try bindObservation(fixed.view(), resolved, null, release_observed);
    try fence(authority, &fixed);
    for (0..artifact_count) |index| {
        const observed = try driver.verify(fixed.view(), resolved, index, try deadline.remaining());
        try bindObservation(fixed.view(), resolved, index, observed);
        try fence(authority, &fixed);
    }
    _ = try deadline.remaining();
    result.release_id = fixed.release_id;
    result.tag_len = fixed.tag_len;
    @memcpy(result.tag[0..fixed.tag_len], fixed.tag[0..fixed.tag_len]);
    result.source_commit = fixed.source_commit;
    result.tag_ref_sha = resolved.tag_ref_sha;
    result.artifact_ids = fixed.ids;
    result.artifact_sha256 = fixed.sha256;
    result.owner = result;
}

fn fence(authority: anytype, fixed: *const Frozen) !void {
    const current = try authority.snapshot();
    if (!same(fixed, current)) return error.AuthorityChanged;
}
fn bindObservation(expected: Snapshot, resolved: ResolvedTag, index: ?usize, observed: Observation) !void {
    if (observed.release_id != expected.release_id or observed.artifact_index != index or !std.mem.eql(u8, &observed.tag_ref_sha, &resolved.tag_ref_sha)) return error.AttestationMismatch;
}
fn validate(value: Snapshot) !void {
    if (value.release_id == 0 or value.tag.len == 0 or value.tag.len > 128 or !lowerHex(value.source_commit, 40) or !lowerHex(&value.cli_sha256, 64)) return error.InvalidAuthority;
    for (value.artifacts, 0..) |a, i| {
        if (a.id == 0 or a.path.len == 0 or a.path.len > std.fs.max_path_bytes or !std.fs.path.isAbsolute(a.path) or a.name.len == 0 or a.name.len > attachment.max_asset_name_bytes or !std.mem.eql(u8, a.name, std.fs.path.basename(a.path)) or a.size == 0 or !lowerHex(&a.sha256, 64)) return error.InvalidAuthority;
        for (value.artifacts[0..i]) |prior| if (a.id == prior.id or std.mem.eql(u8, a.path, prior.path) or std.mem.eql(u8, a.name, prior.name)) return error.AssetAlias;
    }
}
fn freeze(out: *Frozen, value: Snapshot) void {
    out.* = .{ .release_id = value.release_id, .tag_len = value.tag.len, .source_commit = undefined, .cli_sha256 = value.cli_sha256, .ids = undefined, .path_lens = undefined, .name_lens = undefined, .sizes = undefined, .sha256 = undefined };
    @memcpy(out.tag[0..value.tag.len], value.tag);
    @memcpy(&out.source_commit, value.source_commit);
    for (value.artifacts, 0..) |a, i| {
        out.ids[i] = a.id;
        out.path_lens[i] = a.path.len;
        @memcpy(out.paths[i][0..a.path.len], a.path);
        out.name_lens[i] = a.name.len;
        @memcpy(out.names[i][0..a.name.len], a.name);
        out.sizes[i] = a.size;
        out.sha256[i] = a.sha256;
    }
}
fn same(fixed: *const Frozen, value: Snapshot) bool {
    if (fixed.release_id != value.release_id or !std.mem.eql(u8, fixed.tag[0..fixed.tag_len], value.tag) or !std.mem.eql(u8, &fixed.source_commit, value.source_commit) or !std.mem.eql(u8, &fixed.cli_sha256, &value.cli_sha256)) return false;
    for (value.artifacts, 0..) |a, i| if (fixed.ids[i] != a.id or fixed.sizes[i] != a.size or !std.mem.eql(u8, fixed.paths[i][0..fixed.path_lens[i]], a.path) or !std.mem.eql(u8, fixed.names[i][0..fixed.name_lens[i]], a.name) or !std.mem.eql(u8, &fixed.sha256[i], &a.sha256)) return false;
    return true;
}
fn pristine(value: *const VerifiedRelease) bool {
    return value.owner == null and value.release_id == 0 and value.tag_len == 0 and std.mem.allEqual(u8, &value.tag, 0) and std.mem.allEqual(u8, &value.source_commit, 0) and std.mem.allEqual(u8, &value.tag_ref_sha, 0) and std.mem.allEqual(u64, &value.artifact_ids, 0) and std.mem.allEqual(u8, std.mem.asBytes(&value.artifact_sha256), 0);
}
fn lowerHex(value: []const u8, len: usize) bool {
    if (value.len != len) return false;
    for (value) |b| if (!std.ascii.isDigit(b) and !(b >= 'a' and b <= 'f')) return false;
    return true;
}

const ProductionAuthority = struct {
    input: attachment.AuthorityInput,
    attached: *const attachment.DraftAssets,
    validated: *const redownload.RedownloadValidation,
    published: *const publication.PublishedRelease,
    pub fn snapshot(self: *@This()) !Snapshot {
        const source = try redownload.snapshotValidated(self.input, self.attached, self.validated);
        const published = self.published.value() orelse return error.InvalidPublished;
        if (published.release_id != source.release_id or !std.mem.eql(u8, published.tag, self.input.context.tag) or !std.mem.eql(u8, published.source_commit, self.input.context.source_commit)) return error.AuthorityChanged;
        var artifacts: [artifact_count]Artifact = undefined;
        const paths = [_][]const u8{ self.input.paths.dmg, self.input.paths.frozen_executable, self.input.paths.evidence, self.input.paths.manifest };
        for (&artifacts, 0..) |*a, i| {
            if (published.asset_ids[i] != source.assets[i].id) return error.AuthorityChanged;
            a.* = .{ .id = source.assets[i].id, .path = paths[i], .name = source.assets[i].name, .size = source.assets[i].size, .sha256 = source.assets[i].sha256 };
        }
        return .{ .release_id = source.release_id, .tag = self.input.context.tag, .source_commit = self.input.context.source_commit, .cli_sha256 = source.cli_sha256, .artifacts = artifacts };
    }
};

const PinnedCliSource = struct {
    pinned: *const cli_authority.PinnedExecutable,
    pub fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};

pub fn verifyUntil(io: std.Io, input: attachment.AuthorityInput, attached: *const attachment.DraftAssets, validated: *const redownload.RedownloadValidation, published: *const publication.PublishedRelease, token: []const u8, response: []u8, deadline: *deadline_mod.Deadline, result: *VerifiedRelease) !void {
    if (!pristine(result)) return error.InvalidOwner;
    if (response.len == 0 or response.len > release_attestation.max_response_bytes) return error.InvalidBuffer;
    const result_bytes = std.mem.asBytes(result);
    const owned = [_][]const u8{ std.mem.asBytes(attached), std.mem.asBytes(validated), std.mem.asBytes(published), std.mem.asBytes(deadline), std.mem.asBytes(input.draft), std.mem.asBytes(input.candidate), std.mem.asBytes(input.authored), std.mem.asBytes(input.evidence), std.mem.asBytes(input.manifest), std.mem.asBytes(input.cli.pinned) };
    const borrowed = [_][]const u8{ token, input.paths.dmg, input.paths.frozen_executable, input.paths.evidence, input.paths.manifest, input.cli.path, input.context.repository.owner, input.context.repository.name, input.context.tag, input.context.source_commit, input.context.build.workflow_ref };
    if (rangesOverlap(result_bytes, response)) return error.InvalidOwner;
    for (owned) |value| if (rangesOverlap(result_bytes, value) or rangesOverlap(response, value)) return error.InvalidOwner;
    for (borrowed) |value| if (rangesOverlap(result_bytes, value) or rangesOverlap(response, value)) return error.InvalidOwner;
    var authority = ProductionAuthority{ .input = input, .attached = attached, .validated = validated, .published = published };
    var cli_source = PinnedCliSource{ .pinned = input.cli.pinned };
    var driver = ProductionDriver(*PinnedCliSource){
        .io = io,
        .allocator = input.allocator,
        .cli_source = &cli_source,
        .context = input.context,
        .executable = input.cli.path,
        .token = token,
        .response = response,
        .deadline = deadline,
    };
    try verifyCore(&authority, &driver, deadline, result);
}

pub fn verifySnapshotUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    source: anytype,
    token: []const u8,
    response: []u8,
    deadline: *deadline_mod.Deadline,
    result: *VerifiedRelease,
) !void {
    if (!pristine(result)) return error.InvalidOwner;
    if (response.len == 0 or response.len > release_attestation.max_response_bytes) return error.InvalidBuffer;
    const result_bytes = std.mem.asBytes(result);
    const source_bytes = std.mem.asBytes(source);
    inline for (.{ source_bytes, std.mem.asBytes(deadline), token, response }) |value|
        if (rangesOverlap(result_bytes, value)) return error.InvalidOwner;
    inline for (.{ source_bytes, std.mem.asBytes(deadline), token }) |value|
        if (rangesOverlap(response, value)) return error.InvalidOwner;
    const executable = try source.executablePath();
    inline for (.{ result_bytes, source_bytes, std.mem.asBytes(deadline), token, response }) |value|
        if (rangesOverlap(executable, value)) return error.InvalidOwner;
    const context = try source.releaseContext();
    inline for (.{
        context.repository.owner,
        context.repository.name,
        context.tag,
        context.source_commit,
        context.build.workflow_ref,
    }) |value| inline for (.{ result_bytes, source_bytes, std.mem.asBytes(deadline), executable, token, response }) |owner|
        if (rangesOverlap(value, owner)) return error.InvalidOwner;
    var driver = ProductionDriver(@TypeOf(source)){
        .io = io,
        .allocator = allocator,
        .cli_source = source,
        .context = context,
        .executable = executable,
        .token = token,
        .response = response,
        .deadline = deadline,
    };
    try verifyCore(source, &driver, deadline, result);
}

fn ProductionDriver(comptime CliSource: type) type {
    return struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        cli_source: CliSource,
        context: context_mod.Context,
        executable: [:0]const u8,
        token: []const u8,
        response: []u8,
        deadline: *deadline_mod.Deadline,

        pub fn resolve(self: *@This(), expected: Snapshot, _: i128) !ResolvedTag {
            var executor = transport_macos.BoundedExecutor{ .io = self.io };
            var resolved: tag_authority.TagAuthority = .{};
            defer if (resolved.owner != null) resolved.deinit() catch {};
            var cli_fence = CliFence(CliSource){ .source = self.cli_source };
            try tag_authority.resolveUntilWith(&cli_fence, &executor, self.deadline, self.allocator, expected.tag, expected.source_commit, self.executable, self.token, self.response, &resolved);
            const value = resolved.value() orelse return error.SourceMismatch;
            var result: ResolvedTag = undefined;
            @memcpy(&result.tag_ref_sha, value.ref.target.sha);
            @memcpy(&result.source_commit, expected.source_commit);
            return result;
        }

        pub fn verify(self: *@This(), expected: Snapshot, tag: ResolvedTag, index: ?usize, budget: i128) !Observation {
            var assets: [3]manifest.Asset = undefined;
            const roles = [_]manifest.AssetRole{ .universal_dmg, .frozen_product_executable, .evidence_summary };
            for (&assets, 0..) |*a, i| a.* = .{ .role = roles[i], .name = expected.artifacts[i].name, .sha256 = &expected.artifacts[i].sha256, .size = expected.artifacts[i].size };
            const exp: release_attestation.Expected = .{ .repository = self.context.repository, .release_id = expected.release_id, .tag = expected.tag, .tag_ref_sha = &tag.tag_ref_sha, .assets = &assets, .manifest = .{ .name = expected.artifacts[3].name, .sha256 = &expected.artifacts[3].sha256 } };
            const command: release_attestation.Command = if (index) |i| if (i < 3) .{ .asset = .{ .path = expected.artifacts[i].path, .expected = assets[i] } } else .{ .manifest_asset = .{ .path = expected.artifacts[3].path } } else .release;
            var observed = try release_attestation.verify(self.io, self.allocator, self.executable, self.token, command, exp, self.response, budget);
            defer observed.deinit();
            return .{ .release_id = observed.release_id, .tag_ref_sha = tag.tag_ref_sha, .artifact_index = index };
        }
    };
}

fn CliFence(comptime CliSource: type) type {
    return struct {
        source: CliSource,
        pub fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
            try self.source.revalidate(allocator, path);
        }
    };
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

pub const testing_api = if (builtin.is_test) struct {
    pub fn verify(authority: anytype, driver: anytype, deadline: anytype, result: *VerifiedRelease) !void {
        try verifyCore(authority, driver, deadline, result);
    }
    pub fn observe(expected: Snapshot, tag: ResolvedTag, index: ?usize) Observation {
        return .{ .release_id = expected.release_id, .tag_ref_sha = tag.tag_ref_sha, .artifact_index = index };
    }
} else struct {};
