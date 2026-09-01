//! Owns predecessor manifest download, private materialization, authentication, and cleanup.
//!
//! The current role-B manifest is the endorsement authority. Historical tag protection is not
//! reconstructed from today's repository settings; the role-A artifact attestation proves the
//! exact canonical bytes and build identity endorsed by B.

const std = @import("std");
const manifest = @import("release_manifest");
const download_mod = @import("release_adapter_github_manifest_download");
const file_mod = @import("release_adapter_github_manifest_file");
const authenticated_mod = @import("release_adapter_github_manifest_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");
const workspace_mod = @import("release_adapter_pre_publish_workspace");

pub const Downloaded = download_mod.Observed;

pub const Error = error{
    InvalidOwner,
    InvalidCurrent,
    InvalidWorkspace,
    InvalidPredecessor,
    CleanupFailed,
};

pub const Cli = struct {
    path: [:0]const u8,
    pinned: *const cli_authority.PinnedExecutable,
};

/// Narrow adapter for an authenticated current-manifest owner. It keeps the orchestration entry
/// point concrete while letting the current owner retain all storage and cleanup responsibility.
pub const Current = struct {
    pointer: *anyopaque,
    value_fn: *const fn (*anyopaque) ?*const manifest.Manifest,
    revalidate_fn: *const fn (*anyopaque) bool,
    storage_fn: *const fn (*anyopaque) []const u8,

    pub fn from(source: anytype) Current {
        const Pointer = @TypeOf(source);
        const Adapter = struct {
            fn value(raw: *anyopaque) ?*const manifest.Manifest {
                const typed: Pointer = @ptrCast(@alignCast(raw));
                const view = typed.value() orelse return null;
                return view.manifest;
            }
            fn revalidate(raw: *anyopaque) bool {
                const typed: Pointer = @ptrCast(@alignCast(raw));
                typed.revalidate() catch return false;
                return true;
            }
            fn storage(raw: *anyopaque) []const u8 {
                const typed: Pointer = @ptrCast(@alignCast(raw));
                return std.mem.asBytes(typed);
            }
        };
        return .{ .pointer = @ptrCast(source), .value_fn = Adapter.value, .revalidate_fn = Adapter.revalidate, .storage_fn = Adapter.storage };
    }

    fn value(self: Current) ?*const manifest.Manifest {
        return self.value_fn(self.pointer);
    }

    fn revalidate(self: Current) bool {
        return self.revalidate_fn(self.pointer);
    }

    fn storage(self: Current) []const u8 {
        return self.storage_fn(self.pointer);
    }
};

pub const PredecessorManifestInput = struct {
    owner: ?*PredecessorManifestInput = null,
    file: file_mod.ManifestFile = .{},
    authenticated: authenticated_mod.AuthenticatedManifest = .{},

    pub fn value(self: *const @This()) ?*const manifest.Manifest {
        if (self.owner != self) return null;
        return self.authenticated.value();
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) Error!void {
        if (self.owner != self) return error.InvalidOwner;
        if (self.authenticated.owner != null)
            self.authenticated.deinit(allocator) catch return error.InvalidOwner;
        if (self.file.owner != null)
            self.file.cleanup() catch return error.CleanupFailed;
        self.* = .{};
    }
};

const RealDownloader = struct {
    io: std.Io,
    cli: Cli,
    storage: download_mod.PlanStorage = undefined,

    fn fetch(self: *@This(), deadline: *deadline_mod.Deadline, allocator: std.mem.Allocator, executable: [:0]const u8, token: []const u8, expected: download_mod.Expected, output: []u8) !Downloaded {
        if (!std.mem.eql(u8, executable, self.cli.path)) return error.InvalidExecutable;
        return download_mod.fetchUntil(self.io, allocator, &self.storage, .{ .path = self.cli.path, .pinned = self.cli.pinned }, token, expected, output, deadline);
    }
};

const RealAuthenticator = struct {
    io: std.Io,
    cli: Cli,

    fn authenticate(self: *@This(), deadline: *deadline_mod.Deadline, allocator: std.mem.Allocator, predecessor: manifest.Predecessor, bytes: []const u8, file: *const file_mod.ManifestFile, executable: [:0]const u8, token: []const u8, output: []u8, result: *authenticated_mod.AuthenticatedManifest) !void {
        if (!std.mem.eql(u8, executable, self.cli.path)) return error.InvalidExecutable;
        return authenticated_mod.authenticateUntil(self.io, allocator, predecessor, bytes, file, .{ .path = self.cli.path, .pinned = self.cli.pinned }, token, output, deadline, result);
    }
};

pub fn authenticateUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    current: Current,
    workspace: *workspace_mod.Workspace,
    cli: Cli,
    token: []const u8,
    download_output: []u8,
    attestation_output: []u8,
    deadline: *deadline_mod.Deadline,
    result: *PredecessorManifestInput,
) !void {
    const pinned = std.mem.asBytes(cli.pinned);
    const mutable = [_][]const u8{ current.storage(), std.mem.asBytes(workspace), download_output, attestation_output, std.mem.asBytes(deadline), std.mem.asBytes(result) };
    for (mutable) |candidate| if (rangesOverlap(pinned, candidate)) return error.InvalidOwner;
    var downloader = RealDownloader{ .io = io, .cli = cli };
    var authenticator = RealAuthenticator{ .io = io, .cli = cli };
    return authenticateUntilWith(&downloader, &authenticator, deadline, allocator, current, workspace, cli.path, token, download_output, attestation_output, result);
}

pub fn authenticateUntilWith(
    downloader: anytype,
    authenticator: anytype,
    deadline: anytype,
    allocator: std.mem.Allocator,
    current: Current,
    workspace: *workspace_mod.Workspace,
    executable: [:0]const u8,
    token: []const u8,
    download_output: []u8,
    attestation_output: []u8,
    result: *PredecessorManifestInput,
) !void {
    const regions = [_][]const u8{
        current.storage(),
        std.mem.asBytes(workspace),
        executable,
        token,
        download_output,
        attestation_output,
        std.mem.asBytes(deadline),
        std.mem.asBytes(result),
    };
    for (regions, 0..) |left, index| {
        for (regions[index + 1 ..]) |right| if (rangesOverlap(left, right)) return error.InvalidOwner;
    }
    if (result.owner != null or result.file.owner != null or result.authenticated.owner != null or
        result.authenticated.parsed != null or result.authenticated.observed != null)
        return error.InvalidOwner;
    const current_view = current.value() orelse return error.InvalidCurrent;
    const mutable = [_][]const u8{ std.mem.asBytes(workspace), download_output, attestation_output, std.mem.asBytes(deadline), std.mem.asBytes(result) };
    for (mutable) |candidate| if (manifest.aliasesStorage(current_view, candidate)) return error.InvalidOwner;
    if (current_view.role != .b) return error.InvalidCurrent;
    const predecessor = current_view.predecessor orelse return error.InvalidCurrent;
    if (!current.revalidate()) return error.InvalidCurrent;

    var child_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const workdir = workspace.childPath(.predecessor_manifest, &child_storage) catch
        return error.InvalidWorkspace;
    const downloaded = try downloader.fetch(deadline, allocator, executable, token, .{
        .tag = predecessor.tag,
        .sha256 = predecessor.manifest_sha256,
    }, download_output);
    file_mod.materialize(&result.file, workdir, .{
        .name = downloaded.name,
        .sha256 = downloaded.sha256,
        .bytes = downloaded.bytes,
    }) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    authenticator.authenticate(deadline, allocator, predecessor, downloaded.bytes, &result.file, executable, token, attestation_output, &result.authenticated) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    if (!current.revalidate()) {
        abort(result, allocator) catch return error.CleanupFailed;
        return error.InvalidCurrent;
    }
    result.owner = result;
}

fn abort(result: *PredecessorManifestInput, allocator: std.mem.Allocator) Error!void {
    if (result.authenticated.owner != null)
        result.authenticated.deinit(allocator) catch return error.CleanupFailed;
    if (result.file.owner != null) {
        result.file.cleanup() catch {
            result.owner = result;
            return error.CleanupFailed;
        };
    }
    result.* = .{};
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
