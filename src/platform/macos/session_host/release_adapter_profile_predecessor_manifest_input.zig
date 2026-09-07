//! Authenticates the predecessor manifest selected by a protected pre-publish profile.

const std = @import("std");
const manifest = @import("release_manifest");
const identity = @import("release_adapter_identity");
const context_mod = @import("release_adapter_context");
const profile_mod = @import("release_adapter_profile_endorsement");
const download_mod = @import("release_adapter_github_manifest_download");
const file_mod = @import("release_adapter_github_manifest_file");
const authenticated_mod = @import("release_adapter_github_manifest_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");
const workspace_mod = @import("release_adapter_pre_publish_workspace");
const predecessor_input = @import("release_adapter_github_predecessor_manifest_input");

pub const Downloaded = download_mod.Observed;
pub const ProfileManifestInput = struct {
    owner: ?*@This() = null,
    input: predecessor_input.PredecessorManifestInput = .{},

    pub const View = struct {
        manifest: *const manifest.Manifest,
        authenticated: *const authenticated_mod.AuthenticatedManifest,
        file: *const file_mod.ManifestFile,
    };

    pub fn view(self: *const @This()) ?View {
        if (self.owner != self) return null;
        const parsed_manifest = self.input.value() orelse return null;
        return .{ .manifest = parsed_manifest, .authenticated = &self.input.authenticated, .file = &self.input.file };
    }

    pub fn value(self: *const @This()) ?*const manifest.Manifest {
        const current = self.view() orelse return null;
        return current.manifest;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) !void {
        if (self.owner != self) return error.InvalidOwner;
        self.input.deinit(allocator) catch return error.CleanupFailed;
        self.* = .{};
    }

    fn pristine(self: *const @This()) bool {
        return self.owner == null and self.input.owner == null and self.input.file.owner == null and
            self.input.authenticated.owner == null and self.input.authenticated.parsed == null and
            self.input.authenticated.observed == null;
    }
};
pub const Cli = struct { path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable };

const Snapshot = struct {
    release_id: u64,
    tag: [manifest.max_scalar_string_bytes]u8 = @splat(0),
    tag_len: usize,
    commit: [40]u8,
    manifest_sha256: [64]u8,

    fn init(predecessor: manifest.Predecessor) !Snapshot {
        if (predecessor.release_id == 0 or predecessor.tag.len > manifest.max_scalar_string_bytes or
            !identity.canonicalTag(predecessor.tag) or !identity.lowerHex(predecessor.commit, 40) or
            !identity.lowerHex(predecessor.manifest_sha256, 64)) return error.ProfileMismatch;
        var result: Snapshot = .{
            .release_id = predecessor.release_id,
            .tag_len = predecessor.tag.len,
            .commit = undefined,
            .manifest_sha256 = undefined,
        };
        @memcpy(result.tag[0..result.tag_len], predecessor.tag);
        @memcpy(&result.commit, predecessor.commit);
        @memcpy(&result.manifest_sha256, predecessor.manifest_sha256);
        return result;
    }

    fn value(self: *const Snapshot) manifest.Predecessor {
        return .{ .release_id = self.release_id, .tag = self.tag[0..self.tag_len], .commit = &self.commit, .manifest_sha256 = &self.manifest_sha256 };
    }

    fn equal(self: *const Snapshot, predecessor: manifest.Predecessor) bool {
        return self.release_id == predecessor.release_id and std.mem.eql(u8, self.tag[0..self.tag_len], predecessor.tag) and
            std.mem.eql(u8, &self.commit, predecessor.commit) and std.mem.eql(u8, &self.manifest_sha256, predecessor.manifest_sha256);
    }
};

const ProductionProfile = struct {
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    environment: profile_mod.Environment,
    owner: *const profile_mod.Owner,

    pub fn predecessor(self: *@This()) !manifest.Predecessor {
        const selected = try self.owner.revalidateEnvironment(self.allocator, self.context, self.environment);
        return selected.predecessor() orelse error.ProfileMismatch;
    }

    pub fn storage(self: *@This()) []const u8 {
        return std.mem.asBytes(self.owner);
    }
};

const RealDownloader = struct {
    io: std.Io,
    cli: Cli,
    storage: download_mod.PlanStorage = undefined,

    pub fn fetch(self: *@This(), deadline: *deadline_mod.Deadline, allocator: std.mem.Allocator, executable: [:0]const u8, token: []const u8, expected: download_mod.Expected, output: []u8) !Downloaded {
        if (!std.mem.eql(u8, executable, self.cli.path)) return error.InvalidExecutable;
        return download_mod.fetchUntil(self.io, allocator, &self.storage, .{ .path = self.cli.path, .pinned = self.cli.pinned }, token, expected, output, deadline);
    }
};

const RealAuthenticator = struct {
    io: std.Io,
    cli: Cli,

    pub fn authenticate(self: *@This(), deadline: *deadline_mod.Deadline, allocator: std.mem.Allocator, predecessor: manifest.Predecessor, bytes: []const u8, file: *const file_mod.ManifestFile, executable: [:0]const u8, token: []const u8, output: []u8, result: *authenticated_mod.AuthenticatedManifest) !void {
        if (!std.mem.eql(u8, executable, self.cli.path)) return error.InvalidExecutable;
        return authenticated_mod.authenticateUntil(self.io, allocator, predecessor, bytes, file, .{ .path = self.cli.path, .pinned = self.cli.pinned }, token, output, deadline, result);
    }
};

pub fn authenticateUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    environment: profile_mod.Environment,
    profile: *const profile_mod.Owner,
    workspace: *workspace_mod.Workspace,
    cli: Cli,
    token: []const u8,
    download_output: []u8,
    attestation_output: []u8,
    deadline: *deadline_mod.Deadline,
    result: *ProfileManifestInput,
) !void {
    const regions = [_][]const u8{
        std.mem.asBytes(profile),   std.mem.asBytes(workspace), std.mem.asBytes(cli.pinned), std.mem.asBytes(deadline),
        context.repository.owner,   context.repository.name,    context.tag,                 context.source_commit,
        context.build.workflow_ref, cli.path,                   token,                       download_output,
        attestation_output,         std.mem.asBytes(result),
    };
    for (regions, 0..) |left, index| for (regions[index + 1 ..]) |right| if (overlaps(left, right)) return error.InvalidOwner;
    const environment_pointer = @intFromPtr(environment.context);
    for (regions) |region| {
        const start = @intFromPtr(region.ptr);
        const end = std.math.add(usize, start, region.len) catch return error.InvalidOwner;
        if (environment_pointer >= start and environment_pointer < end) return error.InvalidOwner;
    }
    var selected = ProductionProfile{ .allocator = allocator, .context = context, .environment = environment, .owner = profile };
    var downloader = RealDownloader{ .io = io, .cli = cli };
    var authenticator = RealAuthenticator{ .io = io, .cli = cli };
    return authenticateUntilWith(&downloader, &authenticator, deadline, allocator, &selected, workspace, cli.path, token, download_output, attestation_output, result);
}

pub fn authenticateUntilWith(
    downloader: anytype,
    authenticator: anytype,
    deadline: anytype,
    allocator: std.mem.Allocator,
    profile: anytype,
    workspace: *workspace_mod.Workspace,
    executable: [:0]const u8,
    token: []const u8,
    download_output: []u8,
    attestation_output: []u8,
    result: *ProfileManifestInput,
) !void {
    try validateDisjoint(profile, workspace, executable, token, download_output, attestation_output, deadline, result);
    if (!result.pristine()) return error.InvalidOwner;
    const initial = try profile.predecessor();
    var snapshot = try Snapshot.init(initial);
    if (overlaps(std.mem.asBytes(&snapshot), profile.storage()) or overlaps(std.mem.asBytes(&snapshot), download_output) or
        overlaps(std.mem.asBytes(&snapshot), attestation_output) or overlaps(std.mem.asBytes(&snapshot), std.mem.asBytes(result)))
        return error.InvalidOwner;
    try fence(profile, &snapshot);

    var child_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const workdir = workspace.childPath(.predecessor_manifest, &child_storage) catch return error.InvalidWorkspace;
    const downloaded = try downloader.fetch(deadline, allocator, executable, token, .{
        .tag = snapshot.tag[0..snapshot.tag_len],
        .sha256 = &snapshot.manifest_sha256,
    }, download_output);
    if (downloaded.bytes.ptr != download_output.ptr or downloaded.bytes.len == 0 or downloaded.bytes.len > download_output.len or
        !std.mem.eql(u8, downloaded.sha256, &snapshot.manifest_sha256)) return error.InvalidDownload;
    try fence(profile, &snapshot);
    file_mod.materialize(&result.input.file, workdir, .{ .name = downloaded.name, .sha256 = downloaded.sha256, .bytes = downloaded.bytes }) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    fence(profile, &snapshot) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    authenticator.authenticate(deadline, allocator, snapshot.value(), downloaded.bytes, &result.input.file, executable, token, attestation_output, &result.input.authenticated) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    fence(profile, &snapshot) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    _ = deadline.remaining() catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    result.input.owner = &result.input;
    result.owner = result;
}

fn fence(profile: anytype, snapshot: *const Snapshot) !void {
    const current = profile.predecessor() catch return error.AuthorityChanged;
    if (!snapshot.equal(current)) return error.AuthorityChanged;
}

fn abort(result: *ProfileManifestInput, allocator: std.mem.Allocator) !void {
    if (result.input.authenticated.owner != null) result.input.authenticated.deinit(allocator) catch {
        result.owner = result;
        result.input.owner = &result.input;
        return error.CleanupFailed;
    };
    if (result.input.file.owner != null) {
        result.input.file.cleanup() catch {
            result.owner = result;
            result.input.owner = &result.input;
            return error.CleanupFailed;
        };
    }
    result.* = .{};
}

fn validateDisjoint(profile: anytype, workspace: *workspace_mod.Workspace, executable: []const u8, token: []const u8, download_output: []const u8, attestation_output: []const u8, deadline: anytype, result: *const ProfileManifestInput) !void {
    const regions = [_][]const u8{ profile.storage(), std.mem.asBytes(workspace), executable, token, download_output, attestation_output, std.mem.asBytes(deadline), std.mem.asBytes(result) };
    for (regions, 0..) |left, index| for (regions[index + 1 ..]) |right| if (overlaps(left, right)) return error.InvalidOwner;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
