//! Binds current private assets to three GitHub artifact attestations under one deadline.

const std = @import("std");
const c = std.c;
const manifest = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const attestation = @import("release_adapter_github_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const current_input = @import("release_adapter_github_current_manifest_input");
const asset_files = @import("release_adapter_github_current_asset_files");

const role_order = [_]manifest.AssetRole{ .universal_dmg, .frozen_product_executable, .evidence_summary };

pub const Error = error{ InvalidOwner, InvalidCurrent, InvalidAssets, ClockFailed, TimedOut };

pub const ContextView = struct {
    repository_id: u64,
    release_id: u64,
    run_id: u64,
    run_attempt: u64,
    tag: []const u8,
    source_commit: []const u8,
    workflow_ref: []const u8,
};

pub const View = struct {
    owner: *const CurrentAssetAttestations,
    context: ContextView,

    pub fn asset(self: @This(), role: manifest.AssetRole) ?*const attestation.Observed {
        for (role_order, 0..) |candidate, index| if (candidate == role)
            return if (self.owner.observed[index]) |*value| value else null;
        return null;
    }
};

pub const CurrentAssetAttestations = struct {
    owner: ?*CurrentAssetAttestations = null,
    observed: [role_order.len]?attestation.Observed = @splat(null),
    repository_id: u64 = 0,
    release_id: u64 = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,
    tag: [manifest.max_scalar_string_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    workflow_ref: [manifest.max_scalar_string_bytes]u8 = @splat(0),
    workflow_ref_len: usize = 0,

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self) return null;
        for (self.observed) |observation| if (observation == null) return null;
        if (self.repository_id == 0 or self.release_id == 0 or self.run_id == 0 or self.run_attempt == 0 or
            self.tag_len == 0 or self.tag_len > self.tag.len or self.workflow_ref_len == 0 or
            self.workflow_ref_len > self.workflow_ref.len) return null;
        return .{ .owner = self, .context = .{
            .repository_id = self.repository_id,
            .release_id = self.release_id,
            .run_id = self.run_id,
            .run_attempt = self.run_attempt,
            .tag = self.tag[0..self.tag_len],
            .source_commit = &self.source_commit,
            .workflow_ref = self.workflow_ref[0..self.workflow_ref_len],
        } };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) Error!void {
        if (self.owner != self) return error.InvalidOwner;
        cleanup(self, allocator);
    }
};

pub const Cli = struct { path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable };

const RealAuthority = struct {
    pinned: *const cli_authority.PinnedExecutable,
    fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};

const RealVerifier = struct {
    fn verify(_: *@This(), executor: anytype, allocator: std.mem.Allocator, executable: []const u8, token: []const u8, directory_fd: c.fd_t, artifact_path: []const u8, expected: attestation.Expected, output: []u8, budget_ns: i128) !attestation.Observed {
        return attestation.verifyDirectoryWith(executor, allocator, executable, token, directory_fd, artifact_path, expected, output, budget_ns);
    }
};

const RealClock = struct {
    fn now(_: *@This()) !i128 {
        var ts: c.timespec = undefined;
        if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return error.ClockFailed;
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
};

pub fn compose(io: std.Io, allocator: std.mem.Allocator, current: *const current_input.CurrentManifestInput, private: *asset_files.CurrentAssetFiles, cli: Cli, token: []const u8, output: []u8, budget_ns: i128, result: *CurrentAssetAttestations) !void {
    var authority = RealAuthority{ .pinned = cli.pinned };
    var verifier = RealVerifier{};
    var executor = attestation.BoundedExecutor{ .io = io };
    var clock = RealClock{};
    return composeWith(&authority, &verifier, &executor, &clock, allocator, current, private, cli.path, token, output, budget_ns, result);
}

pub fn composeWith(authority: anytype, verifier: anytype, executor: anytype, clock: anytype, allocator: std.mem.Allocator, current: anytype, private: anytype, executable: [:0]const u8, token: []const u8, output: []u8, budget_ns: i128, result: *CurrentAssetAttestations) !void {
    if (!pristine(result) or rangesOverlap(std.mem.asBytes(result), output) or
        rangesOverlap(std.mem.asBytes(current), output) or
        rangesOverlap(std.mem.asBytes(private), output) or
        rangesOverlap(executable, output) or rangesOverlap(token, output)) return error.InvalidOwner;
    const current_view = current.value() orelse return error.InvalidCurrent;
    const candidate = current_view.manifest;
    if (!validCurrent(candidate, current_view.authority)) return error.InvalidCurrent;
    if (budget_ns <= 0) return error.TimedOut;
    const started = clock.now() catch return error.ClockFailed;
    const deadline = std.math.add(i128, started, budget_ns) catch return error.TimedOut;
    var published = false;
    defer if (!published) cleanup(result, allocator);
    const context: context_mod.Context = .{
        .repository = candidate.repository,
        .tag = candidate.release.tag,
        .source_commit = candidate.source.commit,
        .build = candidate.build,
        .protected_tag = true,
    };

    for (role_order, 0..) |role, index| {
        const before = private.revalidate() catch return error.InvalidAssets;
        const expected_asset = assetForRole(candidate.assets, role) orelse return error.InvalidCurrent;
        const before_asset = before.asset(role) orelse return error.InvalidAssets;
        if (!validAsset(before_asset, expected_asset)) return error.InvalidAssets;
        try authority.revalidate(allocator, executable);
        const now = clock.now() catch return error.ClockFailed;
        if (now >= deadline) return error.TimedOut;
        var relative_storage: [std.fs.max_name_bytes + 3]u8 = undefined;
        const relative = std.fmt.bufPrint(&relative_storage, "./{s}", .{expected_asset.name}) catch return error.InvalidAssets;
        var observed = try verifier.verify(executor, allocator, executable, token, before.directory_fd, relative, .{
            .context = context,
            .subject_name = expected_asset.name,
            .subject_sha256 = expected_asset.sha256,
        }, output, deadline - now);
        errdefer observed.deinit(allocator);
        const after = private.revalidate() catch return error.InvalidAssets;
        const after_asset = after.asset(role) orelse return error.InvalidAssets;
        if (after.directory_fd != before.directory_fd or !validAsset(after_asset, expected_asset)) return error.InvalidAssets;
        result.observed[index] = observed;
    }
    if (candidate.release.tag.len > result.tag.len or candidate.source.commit.len != result.source_commit.len or
        candidate.build.workflow_ref.len > result.workflow_ref.len)
        return error.InvalidCurrent;
    result.repository_id = candidate.repository.id;
    result.release_id = candidate.release.id;
    result.run_id = candidate.build.run_id;
    result.run_attempt = candidate.build.run_attempt;
    result.tag_len = candidate.release.tag.len;
    @memcpy(result.tag[0..result.tag_len], candidate.release.tag);
    @memcpy(&result.source_commit, candidate.source.commit);
    result.workflow_ref_len = candidate.build.workflow_ref.len;
    @memcpy(result.workflow_ref[0..result.workflow_ref_len], candidate.build.workflow_ref);
    result.owner = result;
    published = true;
}

fn pristine(result: *const CurrentAssetAttestations) bool {
    if (result.owner != null or result.repository_id != 0 or result.release_id != 0 or result.run_id != 0 or
        result.run_attempt != 0 or result.tag_len != 0 or result.workflow_ref_len != 0) return false;
    for (result.observed) |value| if (value != null) return false;
    return true;
}

fn cleanup(result: *CurrentAssetAttestations, allocator: std.mem.Allocator) void {
    var index = result.observed.len;
    while (index > 0) {
        index -= 1;
        if (result.observed[index]) |*value| value.deinit(allocator);
        result.observed[index] = null;
    }
    result.* = .{};
}

fn validCurrent(candidate: *const manifest.Manifest, authority: anytype) bool {
    return candidate.role == .b and candidate.predecessor != null and candidate.assets.len == role_order.len and authority.protected_environment and
        authority.repository_id == candidate.repository.id and authority.run_id == candidate.build.run_id and
        authority.run_attempt == candidate.build.run_attempt and authority.release_id == candidate.release.id and
        std.mem.eql(u8, authority.source_commit, candidate.source.commit) and std.mem.eql(u8, authority.tag, candidate.release.tag);
}

fn assetForRole(values: []const manifest.Asset, role: manifest.AssetRole) ?manifest.Asset {
    var found: ?manifest.Asset = null;
    for (values) |value| if (value.role == role) {
        if (found != null) return null;
        found = value;
    };
    return found;
}

fn validAsset(observed: anytype, expected: manifest.Asset) bool {
    return observed.role == expected.role and observed.mode & 0o170777 == 0o100400 and observed.link_count == 1 and
        observed.size == expected.size and std.mem.eql(u8, observed.name, expected.name) and
        std.mem.eql(u8, observed.sha256, expected.sha256);
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
