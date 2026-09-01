//! Owns the caller pathname read, private manifest leaf, and current manifest authentication.
//!
//! The original pathname is intentionally consumed only by `readInputAlloc`. Attestation receives
//! the descriptor-owned private leaf, so replacing the caller path after the read cannot swap the
//! bytes that the external verifier observes.

const std = @import("std");
const manifest = @import("release_manifest");
const files = @import("release_adapter_files");
const context_mod = @import("release_adapter_context");
const current_mod = @import("release_adapter_github_current_release_authority");
const file_mod = @import("release_adapter_github_manifest_file");
const authenticated_mod = @import("release_adapter_github_current_manifest_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const candidate_mod = @import("release_adapter_github_current_manifest_candidate");
const deadline_mod = @import("release_adapter_deadline");

pub const Error = error{
    InvalidOwner,
    InvalidCurrent,
    InvalidManifestPath,
    InvalidManifestInput,
    CleanupFailed,
};

pub const Cli = struct {
    path: [:0]const u8,
    pinned: *const cli_authority.PinnedExecutable,
};

pub const CurrentManifestInput = struct {
    owner: ?*CurrentManifestInput = null,
    input: ?files.Input = null,
    file: file_mod.ManifestFile = .{},
    authenticated: authenticated_mod.AuthenticatedCurrentManifest = .{},

    pub fn value(self: *const @This()) ?authenticated_mod.View {
        if (self.owner != self) return null;
        return self.authenticated.value();
    }

    pub fn bytes(self: *const @This()) ?[]const u8 {
        if (self.owner != self) return null;
        return if (self.input) |input| input.bytes else null;
    }

    /// Revalidates the descriptor-owned attested leaf and its owned canonical byte copy.
    pub fn revalidate(self: *const @This()) Error!void {
        if (self.owner != self) return error.InvalidOwner;
        try validatePrepared(self);
    }

    fn validatePrepared(self: *const @This()) Error!void {
        if (self.authenticated.value() == null) return error.InvalidOwner;
        const input = self.input orelse return error.InvalidOwner;
        const observed = self.file.revalidate() catch return error.InvalidManifestInput;
        if (input.bytes.len != input.size or observed.size != input.size or
            !std.mem.eql(u8, observed.sha256, &input.sha256)) return error.InvalidManifestInput;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(input.bytes, &digest, .{});
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &digest_hex, &input.sha256)) return error.InvalidManifestInput;
    }

    /// Cleanup can be retried when filesystem removal fails. Owned input bytes and parsed
    /// attestation state are released once; the descriptor owner remains live until its directory
    /// has actually disappeared.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) Error!void {
        if (self.owner != self) return error.InvalidOwner;
        if (self.authenticated.owner != null)
            self.authenticated.deinit(allocator) catch return error.InvalidOwner;
        if (self.file.owner != null) {
            self.file.cleanup() catch return error.CleanupFailed;
        }
        if (self.input) |*input| {
            input.deinit(allocator);
            self.input = null;
        }
        self.* = .{};
    }
};

pub fn authenticatePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    current: *const current_mod.CurrentReleaseAuthority,
    manifest_path: [:0]const u8,
    workdir: [:0]const u8,
    cli: Cli,
    token: []const u8,
    output: []u8,
    budget_ns: i128,
    result: *CurrentManifestInput,
) !void {
    try prepare(allocator, context, current, manifest_path, workdir, result);
    authenticated_mod.authenticate(io, allocator, context, current, result.input.?.bytes, &result.file, .{ .path = cli.path, .pinned = cli.pinned }, token, output, budget_ns, &result.authenticated) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    result.owner = result;
}

pub fn authenticatePathWith(
    attestor: anytype,
    authority: anytype,
    executor: anytype,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    current: *const current_mod.CurrentReleaseAuthority,
    manifest_path: [:0]const u8,
    workdir: [:0]const u8,
    executable: [:0]const u8,
    token: []const u8,
    output: []u8,
    budget_ns: i128,
    result: *CurrentManifestInput,
) !void {
    try prepare(allocator, context, current, manifest_path, workdir, result);
    authenticated_mod.authenticateWith(attestor, authority, executor, allocator, context, current, result.input.?.bytes, &result.file, executable, token, output, budget_ns, &result.authenticated) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    result.owner = result;
}

pub fn authenticateCandidate(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    current: *const current_mod.CurrentReleaseAuthority,
    candidate: *candidate_mod.CurrentManifestCandidate,
    workdir: [:0]const u8,
    cli: Cli,
    token: []const u8,
    output: []u8,
    budget_ns: i128,
    result: *CurrentManifestInput,
) !void {
    try prepareCandidate(allocator, context, current, candidate, workdir, result);
    authenticated_mod.authenticate(io, allocator, context, current, result.input.?.bytes, &result.file, .{ .path = cli.path, .pinned = cli.pinned }, token, output, budget_ns, &result.authenticated) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    result.owner = result;
}

pub fn authenticateCandidateWith(
    attestor: anytype,
    authority: anytype,
    executor: anytype,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    current: *const current_mod.CurrentReleaseAuthority,
    candidate: *candidate_mod.CurrentManifestCandidate,
    workdir: [:0]const u8,
    executable: [:0]const u8,
    token: []const u8,
    output: []u8,
    budget_ns: i128,
    result: *CurrentManifestInput,
) !void {
    try prepareCandidate(allocator, context, current, candidate, workdir, result);
    authenticated_mod.authenticateWith(attestor, authority, executor, allocator, context, current, result.input.?.bytes, &result.file, executable, token, output, budget_ns, &result.authenticated) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    result.owner = result;
}

pub fn authenticateCandidateUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    current: *const current_mod.CurrentReleaseAuthority,
    candidate: *candidate_mod.CurrentManifestCandidate,
    workdir: [:0]const u8,
    cli: Cli,
    token: []const u8,
    output: []u8,
    deadline: *deadline_mod.Deadline,
    result: *CurrentManifestInput,
) !void {
    try prepareCandidate(allocator, context, current, candidate, workdir, result);
    authenticated_mod.authenticateUntil(io, allocator, context, current, result.input.?.bytes, &result.file, .{ .path = cli.path, .pinned = cli.pinned }, token, output, deadline, &result.authenticated) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    try publishUntil(deadline, result, allocator);
}

pub fn authenticateCandidateUntilWith(
    attestor: anytype,
    authority: anytype,
    executor: anytype,
    deadline: anytype,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    current: *const current_mod.CurrentReleaseAuthority,
    candidate: *candidate_mod.CurrentManifestCandidate,
    workdir: [:0]const u8,
    executable: [:0]const u8,
    token: []const u8,
    output: []u8,
    result: *CurrentManifestInput,
) !void {
    try prepareCandidate(allocator, context, current, candidate, workdir, result);
    authenticated_mod.authenticateUntilWith(attestor, authority, executor, deadline, allocator, context, current, result.input.?.bytes, &result.file, executable, token, output, &result.authenticated) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    try publishUntil(deadline, result, allocator);
}

fn publishUntil(deadline: anytype, result: *CurrentManifestInput, allocator: std.mem.Allocator) !void {
    _ = deadline.remaining() catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    result.validatePrepared() catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    _ = deadline.remaining() catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
    result.owner = result;
}

fn prepareCandidate(
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    current: *const current_mod.CurrentReleaseAuthority,
    candidate: *candidate_mod.CurrentManifestCandidate,
    workdir: [:0]const u8,
    result: *CurrentManifestInput,
) !void {
    if (result.owner != null or result.input != null or result.file.owner != null or
        result.authenticated.owner != null or result.authenticated.parsed != null or
        result.authenticated.observed != null) return error.InvalidOwner;
    const parsed = candidate.value() orelse return error.InvalidManifestInput;
    context_mod.bindManifest(context, parsed.*) catch return error.InvalidManifestInput;
    current.bindManifest(parsed.*) catch return error.InvalidCurrent;

    var name_storage: [manifest.max_asset_name_bytes]u8 = undefined;
    const name = canonicalName(context.tag, &name_storage) catch return error.InvalidManifestInput;
    result.input = candidate.takeInput() catch return error.InvalidManifestInput;
    file_mod.materialize(&result.file, workdir, .{
        .name = name,
        .sha256 = &result.input.?.sha256,
        .bytes = result.input.?.bytes,
    }) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
}

fn prepare(
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    current: *const current_mod.CurrentReleaseAuthority,
    manifest_path: [:0]const u8,
    workdir: [:0]const u8,
    result: *CurrentManifestInput,
) !void {
    if (result.owner != null or result.input != null or result.file.owner != null or
        result.authenticated.owner != null or result.authenticated.parsed != null or
        result.authenticated.observed != null) return error.InvalidOwner;
    if (current.value() == null) return error.InvalidCurrent;

    var name_storage: [manifest.max_asset_name_bytes]u8 = undefined;
    const name = canonicalName(context.tag, &name_storage) catch return error.InvalidManifestPath;
    if (!std.fs.path.isAbsolute(manifest_path) or
        !std.mem.eql(u8, std.fs.path.basename(manifest_path), name))
        return error.InvalidManifestPath;

    result.input = try files.readInputAlloc(allocator, manifest_path, manifest.max_manifest_bytes);
    if (result.input.?.bytes.len == 0) {
        abort(result, allocator) catch return error.CleanupFailed;
        return error.InvalidManifestInput;
    }
    file_mod.materialize(&result.file, workdir, .{
        .name = name,
        .sha256 = &result.input.?.sha256,
        .bytes = result.input.?.bytes,
    }) catch |err| {
        abort(result, allocator) catch return error.CleanupFailed;
        return err;
    };
}

fn canonicalName(tag: []const u8, storage: *[manifest.max_asset_name_bytes]u8) ![]const u8 {
    if (tag.len < 2 or tag[0] != 'v') return error.InvalidManifestPath;
    return std.fmt.bufPrint(storage, "Maru-{s}-session-host-release.json", .{tag[1..]}) catch
        return error.InvalidManifestPath;
}

fn abort(result: *CurrentManifestInput, allocator: std.mem.Allocator) Error!void {
    if (result.authenticated.owner != null)
        result.authenticated.deinit(allocator) catch return error.CleanupFailed;
    if (result.file.owner != null) {
        result.file.cleanup() catch {
            // Authentication did not publish, but the caller still needs an address-bound handle
            // to retry removal. `value` remains null because the nested authentication is empty.
            result.owner = result;
            return error.CleanupFailed;
        };
    }
    if (result.input) |*input| input.deinit(allocator);
    result.* = .{};
}
