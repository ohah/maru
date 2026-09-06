//! Final-address projection of one resumed candidate authority into the four publication leaves.
//!
//! This adapter owns no files and performs no remote work. Every projection first asks the
//! resumed execution to re-fence its retained descriptor graph, then checks that graph against a
//! sealed copy before it binds any downstream receipt.

const std = @import("std");
const builtin = @import("builtin");
const context_mod = @import("release_adapter_context");
const resume_product = @import("release_adapter_candidate_resume_authority_product");
const attachment = @import("release_adapter_github_draft_asset_attachment");
const redownload = @import("release_adapter_github_draft_asset_redownload");
const publication = @import("release_adapter_github_draft_publication");
const post_publish = @import("release_adapter_github_post_publish_attestation");
const cli_mod = @import("release_adapter_github_cli_authority");

const SourceFn = *const fn (
    *anyopaque,
    std.mem.Allocator,
    resume_product.PublicationContext,
    [:0]const u8,
    *const cli_mod.PinnedExecutable,
) anyerror!resume_product.PublicationView;

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

    fn init(input: resume_product.PublicationContext) !@This() {
        if (!input.protected_tag or input.repository.id == 0 or input.repository.owner.len == 0 or
            input.repository.owner.len > context_mod.max_value_bytes or input.repository.name.len == 0 or
            input.repository.name.len > context_mod.max_value_bytes or input.tag.len == 0 or
            input.tag.len > context_mod.max_value_bytes or input.source_commit.len != 40 or
            input.build.workflow_ref.len == 0 or input.build.workflow_ref.len > context_mod.max_value_bytes or
            input.build.run_id == 0 or input.build.run_attempt == 0) return error.InvalidGraph;
        var result: @This() = .{
            .repository_id = input.repository.id,
            .owner_len = input.repository.owner.len,
            .name_len = input.repository.name.len,
            .tag_len = input.tag.len,
            .workflow_ref_len = input.build.workflow_ref.len,
            .run_id = input.build.run_id,
            .run_attempt = input.build.run_attempt,
        };
        @memcpy(result.owner[0..result.owner_len], input.repository.owner);
        @memcpy(result.name[0..result.name_len], input.repository.name);
        @memcpy(result.tag[0..result.tag_len], input.tag);
        @memcpy(&result.source_commit, input.source_commit);
        @memcpy(result.workflow_ref[0..result.workflow_ref_len], input.build.workflow_ref);
        return result;
    }

    fn value(self: *const @This()) resume_product.PublicationContext {
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
    release_id: u64 = 0,
    tag: [context_mod.max_value_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    cli_sha256: [64]u8 = @splat(0),
    paths: [resume_product.publication_asset_count][std.fs.max_path_bytes]u8 = @splat(@splat(0)),
    path_lens: [resume_product.publication_asset_count]usize = @splat(0),
    observations: [resume_product.publication_asset_count]resume_product.PublicationObservation = undefined,
    fds: [resume_product.publication_asset_count]std.c.fd_t = @splat(-1),
};

pub const Authority = struct {
    owner: ?*Authority = null,
    source: ?*anyopaque = null,
    source_address: usize = 0,
    source_fn: ?SourceFn = null,
    cli: ?*const cli_mod.PinnedExecutable = null,
    cli_address: usize = 0,
    allocator: std.mem.Allocator = undefined,
    context: StoredContext = .{},
    cli_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    cli_path_len: usize = 0,
    frozen: Frozen = .{},
    seal: [32]u8 = @splat(0),

    pub fn snapshotAttachment(self: *@This()) !attachment.Snapshot {
        try self.fence();
        var assets: [attachment.asset_count]attachment.ExpectedAsset = undefined;
        for (&assets, 0..) |*asset, index| asset.* = .{
            .name = std.fs.path.basename(self.path(index)),
            .size = self.frozen.observations[index].size,
            .sha256 = self.frozen.observations[index].sha256,
            .device = self.frozen.observations[index].identity.device,
            .inode = self.frozen.observations[index].identity.inode,
            .fd = self.frozen.fds[index],
        };
        return .{ .release_id = self.frozen.release_id, .cli_sha256 = self.frozen.cli_sha256, .assets = assets };
    }

    pub fn snapshotRedownload(self: *@This(), attached: *const attachment.DraftAssets) !redownload.Snapshot {
        try self.fence();
        const ids = try self.requireAttached(attached);
        var assets: [redownload.asset_count]redownload.ExpectedAsset = undefined;
        for (&assets, 0..) |*asset, index| asset.* = .{
            .id = ids[index],
            .name = std.fs.path.basename(self.path(index)),
            .size = self.frozen.observations[index].size,
            .sha256 = self.frozen.observations[index].sha256,
            .device = self.frozen.observations[index].identity.device,
            .inode = self.frozen.observations[index].identity.inode,
            .fd = self.frozen.fds[index],
        };
        return .{ .release_id = self.frozen.release_id, .cli_sha256 = self.frozen.cli_sha256, .assets = assets };
    }

    pub fn snapshotPublication(
        self: *@This(),
        attached: *const attachment.DraftAssets,
        validated: *const redownload.RedownloadValidation,
    ) !publication.Snapshot {
        try self.fence();
        const ids = try self.requireReceipts(attached, validated);
        var assets: [publication.asset_count]publication.Asset = undefined;
        for (&assets, 0..) |*asset, index| asset.* = .{
            .id = ids[index],
            .name = std.fs.path.basename(self.path(index)),
            .size = self.frozen.observations[index].size,
            .sha256 = self.frozen.observations[index].sha256,
        };
        return .{
            .release_id = self.frozen.release_id,
            .tag = self.frozen.tag[0..self.frozen.tag_len],
            .source_commit = &self.frozen.source_commit,
            .cli_sha256 = self.frozen.cli_sha256,
            .assets = assets,
        };
    }

    pub fn snapshotPostPublish(
        self: *@This(),
        attached: *const attachment.DraftAssets,
        validated: *const redownload.RedownloadValidation,
        published: *const publication.PublishedRelease,
    ) !post_publish.Snapshot {
        try self.fence();
        const ids = try self.requireReceipts(attached, validated);
        if (published.tag_len == 0 or published.tag_len > published.tag.len) return error.ReceiptMismatch;
        const remote = published.value() orelse return error.ReceiptMismatch;
        if (remote.release_id != self.frozen.release_id or !std.mem.eql(u8, remote.tag, self.frozen.tag[0..self.frozen.tag_len]) or
            !std.mem.eql(u8, remote.source_commit, &self.frozen.source_commit) or !std.mem.eql(u64, &remote.asset_ids, &ids))
            return error.ReceiptMismatch;
        var artifacts: [post_publish.artifact_count]post_publish.Artifact = undefined;
        for (&artifacts, 0..) |*artifact, index| artifact.* = .{
            .id = ids[index],
            .path = self.path(index),
            .name = std.fs.path.basename(self.path(index)),
            .size = self.frozen.observations[index].size,
            .sha256 = self.frozen.observations[index].sha256,
        };
        return .{
            .release_id = self.frozen.release_id,
            .tag = self.frozen.tag[0..self.frozen.tag_len],
            .source_commit = &self.frozen.source_commit,
            .cli_sha256 = self.frozen.cli_sha256,
            .artifacts = artifacts,
        };
    }

    pub fn deinit(self: *@This()) !void {
        try self.validateOwner();
        self.* = .{};
    }

    fn fence(self: *@This()) !void {
        try self.validateOwner();
        const source = self.source orelse return error.InvalidOwner;
        const callback = self.source_fn orelse return error.InvalidOwner;
        const cli = self.cli orelse return error.InvalidOwner;
        const current = try callback(source, self.allocator, self.context.value(), self.cliPath(), cli);
        if (!matches(self, current)) return error.AuthorityChanged;
    }

    fn validateOwner(self: *const @This()) !void {
        if (self.owner != self or self.source == null or self.source_address == 0 or
            @intFromPtr(self.source.?) != self.source_address or self.source_fn == null or self.cli == null or
            self.cli_address == 0 or @intFromPtr(self.cli.?) != self.cli_address or self.cli_path_len == 0 or
            !validStorage(self) or !std.mem.eql(u8, &self.seal, &metadataSeal(self))) return error.InvalidOwner;
    }

    fn requireAttached(self: *const @This(), attached: *const attachment.DraftAssets) ![attachment.asset_count]u64 {
        const remote = attached.value() orelse return error.ReceiptMismatch;
        if (remote.release_id != self.frozen.release_id or remote.assets.len != attachment.asset_count)
            return error.ReceiptMismatch;
        var ids: [attachment.asset_count]u64 = undefined;
        for (remote.assets, 0..) |asset, index| {
            if (attached.name_lens[index] == 0 or attached.name_lens[index] > attached.names[index].len or
                attached.ids[index] != asset.id or attached.sizes[index] != asset.size or
                attached.name_lens[index] != asset.name.len or
                !std.mem.eql(u8, attached.names[index][0..attached.name_lens[index]], asset.name) or
                asset.id == 0 or asset.size != self.frozen.observations[index].size or
                !std.mem.eql(u8, asset.name, std.fs.path.basename(self.path(index)))) return error.ReceiptMismatch;
            for (ids[0..index]) |prior| if (prior == asset.id) return error.ReceiptMismatch;
            ids[index] = asset.id;
        }
        return ids;
    }

    fn requireReceipts(self: *const @This(), attached: *const attachment.DraftAssets, validated: *const redownload.RedownloadValidation) ![attachment.asset_count]u64 {
        const ids = try self.requireAttached(attached);
        const checked = validated.value() orelse return error.ReceiptMismatch;
        if (checked.release_id != self.frozen.release_id or !std.mem.eql(u64, &checked.asset_ids, &ids))
            return error.ReceiptMismatch;
        return ids;
    }

    fn path(self: *const @This(), index: usize) []const u8 {
        return self.frozen.paths[index][0..self.frozen.path_lens[index]];
    }

    fn cliPath(self: *const @This()) [:0]const u8 {
        return self.cli_path[0..self.cli_path_len :0];
    }
};

fn validStorage(authority: *const Authority) bool {
    if (authority.cli_path_len == 0 or authority.cli_path_len >= authority.cli_path.len or
        authority.context.owner_len == 0 or authority.context.owner_len > authority.context.owner.len or
        authority.context.name_len == 0 or authority.context.name_len > authority.context.name.len or
        authority.context.tag_len == 0 or authority.context.tag_len > authority.context.tag.len or
        authority.context.workflow_ref_len == 0 or authority.context.workflow_ref_len > authority.context.workflow_ref.len or
        authority.frozen.tag_len == 0 or authority.frozen.tag_len > authority.frozen.tag.len) return false;
    for (authority.frozen.path_lens) |len| if (len == 0 or len >= std.fs.max_path_bytes) return false;
    return true;
}

pub fn bind(
    source: *resume_product.Execution,
    allocator: std.mem.Allocator,
    context: resume_product.PublicationContext,
    cli_path: [:0]const u8,
    cli: *const cli_mod.PinnedExecutable,
    authority: *Authority,
) !void {
    return bindCore(source, std.mem.asBytes(source), productionView, allocator, context, cli_path, cli, authority);
}

fn productionView(
    source_context: *anyopaque,
    allocator: std.mem.Allocator,
    context: resume_product.PublicationContext,
    cli_path: [:0]const u8,
    cli: *const cli_mod.PinnedExecutable,
) !resume_product.PublicationView {
    const source: *resume_product.Execution = @ptrCast(@alignCast(source_context));
    return source.publicationView(allocator, context, cli_path, cli);
}

fn bindCore(
    source: *anyopaque,
    source_bytes: []const u8,
    callback: SourceFn,
    allocator: std.mem.Allocator,
    context: resume_product.PublicationContext,
    cli_path: [:0]const u8,
    cli: *const cli_mod.PinnedExecutable,
    authority: *Authority,
) !void {
    if (!pristine(authority)) return error.InvalidOwner;
    if (!canonicalAbsolute(cli_path)) return error.InvalidGraph;
    const authority_bytes = std.mem.asBytes(authority);
    const cli_bytes = std.mem.asBytes(cli);
    const context_values = [_][]const u8{
        context.repository.owner,
        context.repository.name,
        context.tag,
        context.source_commit,
        context.build.workflow_ref,
    };
    if (rangesOverlap(authority_bytes, source_bytes) or rangesOverlap(authority_bytes, cli_bytes) or
        rangesOverlap(authority_bytes, cli_path) or rangesOverlap(source_bytes, cli_bytes) or
        rangesOverlap(source_bytes, cli_path) or rangesOverlap(cli_bytes, cli_path)) return error.StorageAlias;
    for (context_values) |value| {
        if (rangesOverlap(authority_bytes, value) or rangesOverlap(source_bytes, value) or
            rangesOverlap(cli_bytes, value) or rangesOverlap(cli_path, value)) return error.StorageAlias;
    }
    for (context_values, 0..) |left, index| for (context_values[index + 1 ..]) |right|
        if (rangesOverlap(left, right)) return error.StorageAlias;
    var stored_context = try StoredContext.init(context);
    const initial = try callback(source, allocator, stored_context.value(), cli_path, cli);
    const frozen = try freeze(stored_context.value(), cli, initial);
    if (cli_path.len >= authority.cli_path.len) return error.InvalidGraph;
    authority.* = .{
        .owner = authority,
        .source = source,
        .source_address = @intFromPtr(source),
        .source_fn = callback,
        .cli = cli,
        .cli_address = @intFromPtr(cli),
        .allocator = allocator,
        .context = stored_context,
        .cli_path_len = cli_path.len,
        .frozen = frozen,
    };
    @memcpy(authority.cli_path[0..cli_path.len], cli_path);
    authority.seal = metadataSeal(authority);
}

fn freeze(expected: resume_product.PublicationContext, cli: *const cli_mod.PinnedExecutable, view: resume_product.PublicationView) !Frozen {
    if (!sameContext(expected, view.context) or view.release_id == 0 or !std.mem.eql(u8, view.tag, expected.tag) or
        !std.mem.eql(u8, view.source_commit, expected.source_commit) or !std.mem.eql(u8, &view.cli_sha256, &cli.sha256))
        return error.InvalidGraph;
    var result: Frozen = .{ .release_id = view.release_id, .tag_len = view.tag.len };
    if (view.tag.len > result.tag.len) return error.InvalidGraph;
    @memcpy(result.tag[0..view.tag.len], view.tag);
    @memcpy(&result.source_commit, view.source_commit);
    result.cli_sha256 = view.cli_sha256;
    for (view.assets, 0..) |asset, index| {
        if (!canonicalAbsolute(asset.path) or asset.path.len >= result.paths[index].len or asset.fd < 0 or
            asset.observation.identity.device == 0 or asset.observation.identity.inode == 0 or asset.observation.size == 0 or
            !lowerHex(&asset.observation.sha256)) return error.InvalidGraph;
        const name = std.fs.path.basename(asset.path);
        if (name.len == 0 or name.len > attachment.max_asset_name_bytes) return error.InvalidGraph;
        for (view.assets[0..index]) |prior| if (std.mem.eql(u8, prior.path, asset.path) or
            std.mem.eql(u8, std.fs.path.basename(prior.path), name) or prior.fd == asset.fd or
            sameIdentity(prior.observation.identity, asset.observation.identity)) return error.InvalidGraph;
        result.path_lens[index] = asset.path.len;
        @memcpy(result.paths[index][0..asset.path.len], asset.path);
        result.observations[index] = asset.observation;
        result.fds[index] = asset.fd;
    }
    return result;
}

fn matches(authority: *const Authority, view: resume_product.PublicationView) bool {
    if (!sameContext(authority.context.value(), view.context) or view.release_id != authority.frozen.release_id or
        !std.mem.eql(u8, view.tag, authority.frozen.tag[0..authority.frozen.tag_len]) or
        !std.mem.eql(u8, view.source_commit, &authority.frozen.source_commit) or
        !std.mem.eql(u8, &view.cli_sha256, &authority.frozen.cli_sha256)) return false;
    for (view.assets, 0..) |asset, index| if (!std.mem.eql(u8, asset.path, authority.path(index)) or
        asset.fd != authority.frozen.fds[index] or !std.meta.eql(asset.observation, authority.frozen.observations[index])) return false;
    return true;
}

fn pristine(authority: *const Authority) bool {
    return authority.owner == null and authority.source == null and authority.source_address == 0 and authority.source_fn == null and
        authority.cli == null and authority.cli_address == 0 and authority.cli_path_len == 0 and allZero(&authority.cli_path) and
        allZero(&authority.seal);
}

fn sameContext(left: resume_product.PublicationContext, right: resume_product.PublicationContext) bool {
    return left.repository.id == right.repository.id and std.mem.eql(u8, left.repository.owner, right.repository.owner) and
        std.mem.eql(u8, left.repository.name, right.repository.name) and std.mem.eql(u8, left.tag, right.tag) and
        std.mem.eql(u8, left.source_commit, right.source_commit) and std.mem.eql(u8, left.build.workflow_ref, right.build.workflow_ref) and
        left.build.run_id == right.build.run_id and left.build.run_attempt == right.build.run_attempt and
        left.protected_tag == right.protected_tag;
}

fn sameIdentity(left: anytype, right: @TypeOf(left)) bool {
    return left.device == right.device and left.inode == right.inode;
}

fn canonicalAbsolute(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or path.len < 2 or path.len >= std.fs.max_path_bytes or path[path.len - 1] == '/' or
        std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn lowerHex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn metadataSeal(authority: *const Authority) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.session-host.resume-asset-graph.v1\x00");
    hasher.update(std.mem.asBytes(&authority.source_address));
    const source_fn_address = @intFromPtr(authority.source_fn.?);
    hasher.update(std.mem.asBytes(&source_fn_address));
    hasher.update(std.mem.asBytes(&authority.cli_address));
    const allocator_ptr = @intFromPtr(authority.allocator.ptr);
    const allocator_vtable = @intFromPtr(authority.allocator.vtable);
    hasher.update(std.mem.asBytes(&allocator_ptr));
    hasher.update(std.mem.asBytes(&allocator_vtable));
    hasher.update(std.mem.asBytes(&authority.cli_path_len));
    hasher.update(authority.cli_path[0..authority.cli_path_len]);
    hasher.update(std.mem.asBytes(&authority.context.repository_id));
    hasher.update(std.mem.asBytes(&authority.context.owner_len));
    hasher.update(authority.context.owner[0..authority.context.owner_len]);
    hasher.update(std.mem.asBytes(&authority.context.name_len));
    hasher.update(authority.context.name[0..authority.context.name_len]);
    hasher.update(std.mem.asBytes(&authority.context.tag_len));
    hasher.update(authority.context.tag[0..authority.context.tag_len]);
    hasher.update(&authority.context.source_commit);
    hasher.update(std.mem.asBytes(&authority.context.workflow_ref_len));
    hasher.update(authority.context.workflow_ref[0..authority.context.workflow_ref_len]);
    hasher.update(std.mem.asBytes(&authority.context.run_id));
    hasher.update(std.mem.asBytes(&authority.context.run_attempt));
    hasher.update(std.mem.asBytes(&authority.frozen.release_id));
    hasher.update(std.mem.asBytes(&authority.frozen.tag_len));
    hasher.update(authority.frozen.tag[0..authority.frozen.tag_len]);
    hasher.update(&authority.frozen.source_commit);
    hasher.update(&authority.frozen.cli_sha256);
    for (0..resume_product.publication_asset_count) |index| {
        hasher.update(std.mem.asBytes(&index));
        hasher.update(std.mem.asBytes(&authority.frozen.path_lens[index]));
        hasher.update(authority.path(index));
        const observation = authority.frozen.observations[index];
        hasher.update(std.mem.asBytes(&observation.identity.device));
        hasher.update(std.mem.asBytes(&observation.identity.inode));
        hasher.update(std.mem.asBytes(&observation.size));
        hasher.update(std.mem.asBytes(&observation.mode));
        hasher.update(&observation.sha256);
        hasher.update(std.mem.asBytes(&authority.frozen.fds[index]));
    }
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

pub const testing_api = if (builtin.is_test) struct {
    pub fn bindWith(
        source: anytype,
        allocator: std.mem.Allocator,
        context: resume_product.PublicationContext,
        cli_path: [:0]const u8,
        cli: *const cli_mod.PinnedExecutable,
        authority: *Authority,
    ) !void {
        const Source = @TypeOf(source.*);
        const Adapter = struct {
            fn call(source_context: *anyopaque, a: std.mem.Allocator, c: resume_product.PublicationContext, p: [:0]const u8, executable: *const cli_mod.PinnedExecutable) !resume_product.PublicationView {
                const typed: *Source = @ptrCast(@alignCast(source_context));
                return typed.publicationView(a, c, p, executable);
            }
        };
        return bindCore(source, std.mem.asBytes(source), Adapter.call, allocator, context, cli_path, cli, authority);
    }

    pub fn replaceSource(authority: *Authority, source: anytype) void {
        authority.source = source;
    }

    pub fn replaceCli(authority: *Authority, cli: *const cli_mod.PinnedExecutable) void {
        authority.cli = cli;
    }

    pub fn toggleStoredContext(authority: *Authority) void {
        authority.context.run_attempt ^= 1;
    }

    pub fn toggleStoredCliPath(authority: *Authority) void {
        authority.cli_path[1] ^= 1;
    }

    pub fn setFirstPathLength(authority: *Authority, len: usize) void {
        authority.frozen.path_lens[0] = len;
    }

    pub fn replaceAllocator(authority: *Authority, allocator: std.mem.Allocator) void {
        authority.allocator = allocator;
    }
} else struct {};
