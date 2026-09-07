//! Complete pre-publish predecessor authority rooted in the protected release profile.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("release_manifest");
const evidence = @import("release_evidence");
const context_mod = @import("release_adapter_context");
const profile_mod = @import("release_adapter_profile_endorsement");
const manifest_input_mod = @import("release_adapter_profile_predecessor_manifest_input");
const assets_mod = @import("release_adapter_github_predecessor_assets");
const tag_chain = @import("release_adapter_github_tag_chain_transport");
const identity_mod = @import("release_adapter_predecessor_evidence_identity");
const binding_mod = @import("release_adapter_profile_predecessor_binding");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");
const workspace_mod = @import("release_adapter_pre_publish_workspace");

pub const Error = error{
    InvalidOwner,
    AuthorityChanged,
    CleanupFailed,
};

pub const Cli = struct {
    path: [:0]const u8,
    pinned: *const cli_authority.PinnedExecutable,
};

pub const AuthenticatedPredecessor = struct {
    owner: ?*@This() = null,
    assets: assets_mod.AuthenticatedPredecessorAssets = .{},
    identity: identity_mod.PredecessorEvidenceIdentity = .{},
    binding: binding_mod.BoundPredecessor = .{},

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and std.meta.eql(self.assets, assets_mod.AuthenticatedPredecessorAssets{}) and
            std.meta.eql(self.identity, identity_mod.PredecessorEvidenceIdentity{}) and
            self.binding.isPristineForComposition();
    }

    pub fn revalidate(
        self: *const @This(),
        allocator: std.mem.Allocator,
        context: context_mod.Context,
        environment: profile_mod.Environment,
        profile: *const profile_mod.Owner,
        manifest_input: *const manifest_input_mod.ProfileManifestInput,
        deadline: *deadline_mod.Deadline,
    ) !evidence.Predecessor {
        if (self.owner != self or aliasesInputs(std.mem.asBytes(self), context, environment, profile, manifest_input, "", "", &.{}) or
            overlaps(std.mem.asBytes(self), std.mem.asBytes(deadline)))
            return error.InvalidOwner;
        const view = try releaseFence(allocator, context, environment, profile, manifest_input);
        _ = try self.assets.revalidateEvidence();
        _ = try self.identity.revalidate(view.authenticated, view.file, &self.assets);
        const fixed = try self.binding.revalidate(allocator, context, environment, profile, view.authenticated, view.file, &self.assets, &self.identity);
        _ = try deadline.remaining();
        return fixed;
    }

    pub fn retryCleanup(self: *@This()) Error!void {
        if (self.owner != self) return error.InvalidOwner;
        return cleanup(self);
    }

    pub fn retryCleanupWith(self: *@This(), operations: anytype) Error!void {
        if (!builtin.is_test) @compileError("retryCleanupWith is test-only");
        if (self.owner != self) return error.InvalidOwner;
        return cleanupWith(operations, self);
    }
};

pub fn authenticateUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    environment: profile_mod.Environment,
    profile: *const profile_mod.Owner,
    manifest_input: *const manifest_input_mod.ProfileManifestInput,
    workspace: *workspace_mod.Workspace,
    cli: Cli,
    token: []const u8,
    response: []u8,
    deadline: *deadline_mod.Deadline,
    result: *AuthenticatedPredecessor,
) !void {
    var product = Product{
        .io = io,
        .allocator = allocator,
        .context = context,
        .environment = environment,
        .profile = profile,
        .manifest_input = manifest_input,
        .workspace = workspace,
        .cli = cli,
        .token = token,
        .response = response,
    };
    return authenticateOwned(&product, deadline, result);
}

pub fn authenticateUntilWith(operations: anytype, deadline: anytype, result: *AuthenticatedPredecessor) !void {
    if (!builtin.is_test) @compileError("authenticateUntilWith is test-only");
    return authenticateOwned(operations, deadline, result);
}

fn authenticateOwned(operations: anytype, deadline: anytype, result: *AuthenticatedPredecessor) !void {
    try operations.preflight(deadline, result);
    try operations.fence();
    var workdir_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const workdir = try operations.childPath(&workdir_storage);
    operations.authenticateAssets(deadline, workdir, &result.assets) catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    operations.fence() catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    operations.composeIdentity(&result.assets, &result.identity) catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    operations.bind(&result.assets, &result.identity, &result.binding) catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    operations.fence() catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    operations.revalidate(&result.assets, &result.identity, &result.binding) catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    _ = deadline.remaining() catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    if (!ready(result)) {
        abortWith(operations, result) catch return error.CleanupFailed;
        return error.InvalidOwner;
    }
    result.owner = result;
}

const Product = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    environment: profile_mod.Environment,
    profile: *const profile_mod.Owner,
    manifest_input: *const manifest_input_mod.ProfileManifestInput,
    workspace: *workspace_mod.Workspace,
    cli: Cli,
    token: []const u8,
    response: []u8,
    current: ?manifest_input_mod.ProfileManifestInput.View = null,

    fn preflight(self: *@This(), deadline: *deadline_mod.Deadline, result: *AuthenticatedPredecessor) !void {
        if (!result.isPristineForComposition()) return error.InvalidOwner;
        const inputs = [_][]const u8{
            std.mem.asBytes(result),
            std.mem.asBytes(self.profile),
            std.mem.asBytes(self.manifest_input),
            std.mem.asBytes(self.workspace),
            std.mem.asBytes(self.cli.pinned),
            std.mem.asBytes(deadline),
            self.cli.path,
            self.token,
            self.response,
            self.context.repository.owner,
            self.context.repository.name,
            self.context.tag,
            self.context.source_commit,
            self.context.build.workflow_ref,
        };
        if (anyPairOverlaps(&inputs)) return error.InvalidOwner;
        const environment_pointer = @intFromPtr(self.environment.context);
        for (inputs) |input| {
            const start = @intFromPtr(input.ptr);
            const end = std.math.add(usize, start, input.len) catch return error.InvalidOwner;
            if (environment_pointer >= start and environment_pointer < end) return error.InvalidOwner;
        }
    }
    fn fence(self: *@This()) !void {
        self.current = try releaseFence(self.allocator, self.context, self.environment, self.profile, self.manifest_input);
    }
    fn childPath(self: *@This(), storage: *[std.fs.max_path_bytes:0]u8) ![:0]const u8 {
        return self.workspace.childPath(.predecessor_assets, storage);
    }
    fn authenticateAssets(self: *@This(), deadline: *deadline_mod.Deadline, workdir: [:0]const u8, result: *assets_mod.AuthenticatedPredecessorAssets) !void {
        const current = self.current orelse return error.AuthorityChanged;
        return tag_chain.authenticateUntil(self.io, self.allocator, current.authenticated, .{ .path = self.cli.path, .pinned = self.cli.pinned }, self.token, workdir, self.response, deadline, result);
    }
    fn composeIdentity(self: *@This(), assets: *const assets_mod.AuthenticatedPredecessorAssets, result: *identity_mod.PredecessorEvidenceIdentity) !void {
        const current = self.current orelse return error.AuthorityChanged;
        return identity_mod.compose(current.authenticated, current.file, assets, result);
    }
    fn bind(self: *@This(), assets: *const assets_mod.AuthenticatedPredecessorAssets, identity: *const identity_mod.PredecessorEvidenceIdentity, result: *binding_mod.BoundPredecessor) !void {
        const current = self.current orelse return error.AuthorityChanged;
        return binding_mod.bind(self.allocator, self.context, self.environment, self.profile, current.authenticated, current.file, assets, identity, result);
    }
    fn revalidate(self: *@This(), assets: *const assets_mod.AuthenticatedPredecessorAssets, identity: *const identity_mod.PredecessorEvidenceIdentity, binding: *const binding_mod.BoundPredecessor) !void {
        const current = self.current orelse return error.AuthorityChanged;
        _ = try binding.revalidate(self.allocator, self.context, self.environment, self.profile, current.authenticated, current.file, assets, identity);
    }
    fn cleanupBinding(_: *@This(), value: *binding_mod.BoundPredecessor) !void {
        return value.deinit();
    }
    fn cleanupIdentity(_: *@This(), value: *identity_mod.PredecessorEvidenceIdentity) !void {
        return value.deinit();
    }
    fn cleanupAssets(_: *@This(), value: *assets_mod.AuthenticatedPredecessorAssets) !void {
        if (value.owner != null) return value.cleanup();
        if (value.downloads.owner != null) {
            value.downloads.cleanup() catch return error.CleanupFailed;
            value.source_commit = @splat(0);
            return;
        }
        return error.InvalidOwner;
    }
};

fn releaseFence(
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    environment: profile_mod.Environment,
    profile: *const profile_mod.Owner,
    manifest_input: *const manifest_input_mod.ProfileManifestInput,
) !manifest_input_mod.ProfileManifestInput.View {
    const selected = try profile.revalidateEnvironment(allocator, context, environment);
    const endorsed = selected.predecessor() orelse return error.AuthorityChanged;
    const view = manifest_input.view() orelse return error.InvalidOwner;
    const candidate = view.manifest;
    const authenticated = view.authenticated.evidenceView() orelse return error.InvalidOwner;
    const held = view.file.revalidate() catch return error.AuthorityChanged;
    if (candidate.role != .a or candidate.predecessor != null or candidate.release.id != endorsed.release_id or
        !std.mem.eql(u8, candidate.release.tag, endorsed.tag) or
        !std.mem.eql(u8, candidate.source.commit, endorsed.commit) or
        !std.mem.eql(u8, held.sha256, endorsed.manifest_sha256) or
        !std.mem.eql(u8, authenticated.subject_sha256, endorsed.manifest_sha256)) return error.AuthorityChanged;
    return view;
}

fn abortWith(operations: anytype, result: *AuthenticatedPredecessor) Error!void {
    result.owner = result;
    return cleanupWith(operations, result);
}

fn cleanupWith(operations: anytype, result: *AuthenticatedPredecessor) Error!void {
    var failed = false;
    if (result.binding.owner != null) operations.cleanupBinding(&result.binding) catch {
        failed = true;
    };
    if (result.identity.owner != null) operations.cleanupIdentity(&result.identity) catch {
        failed = true;
    };
    if (result.assets.owner != null or result.assets.downloads.owner != null) operations.cleanupAssets(&result.assets) catch {
        failed = true;
    };
    if (failed or result.binding.owner != null or result.identity.owner != null or result.assets.owner != null or result.assets.downloads.owner != null)
        return error.CleanupFailed;
    result.* = .{};
}

fn cleanup(result: *AuthenticatedPredecessor) Error!void {
    var failed = false;
    if (result.binding.owner != null) result.binding.deinit() catch {
        failed = true;
    };
    if (result.identity.owner != null) result.identity.deinit() catch {
        failed = true;
    };
    if (result.assets.owner != null) {
        result.assets.cleanup() catch {
            failed = true;
        };
    } else if (result.assets.downloads.owner != null) {
        result.assets.downloads.cleanup() catch {
            failed = true;
        };
        if (!failed) result.assets.source_commit = @splat(0);
    }
    if (failed or result.binding.owner != null or result.identity.owner != null or result.assets.owner != null or result.assets.downloads.owner != null) {
        result.owner = result;
        return error.CleanupFailed;
    }
    result.* = .{};
}

fn ready(result: *const AuthenticatedPredecessor) bool {
    return result.owner == null and result.assets.owner == &result.assets and
        result.assets.downloads.owner == &result.assets.downloads and
        result.identity.owner == &result.identity and result.binding.owner == &result.binding;
}

fn anyPairOverlaps(inputs: []const []const u8) bool {
    for (inputs, 0..) |left, index| for (inputs[index + 1 ..]) |right|
        if (overlaps(left, right)) return true;
    return false;
}

fn aliasesInputs(candidate: []const u8, context: context_mod.Context, environment: profile_mod.Environment, profile: *const profile_mod.Owner, manifest_input: *const manifest_input_mod.ProfileManifestInput, executable: []const u8, token: []const u8, response: []const u8) bool {
    inline for (.{ std.mem.asBytes(profile), std.mem.asBytes(manifest_input), executable, token, response, context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref }) |storage|
        if (overlaps(candidate, storage)) return true;
    const pointer = @intFromPtr(environment.context);
    const start = @intFromPtr(candidate.ptr);
    const end = std.math.add(usize, start, candidate.len) catch return true;
    return pointer >= start and pointer < end;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
