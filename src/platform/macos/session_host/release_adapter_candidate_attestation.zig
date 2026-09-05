//! Pre-draft provenance authority for the exact release candidate bytes.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const attestation = @import("release_adapter_github_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");
const identity = @import("release_adapter_identity");
const bundle_contract = @import("release_adapter_attestation_bundle_contract");

pub const Paths = struct { dmg: [:0]const u8, frozen_executable: [:0]const u8 };
pub const BundlePaths = struct { dmg_bundle: [:0]const u8, frozen_bundle: [:0]const u8 };
pub const Cli = struct { path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable };
pub const max_local_bundle_bytes: u64 = bundle_contract.max_bytes;

pub const View = struct {
    tag: []const u8,
    source_commit: []const u8,
    build: struct { workflow_ref: []const u8, run_id: u64, run_attempt: u64 },
    dmg: files.ExecutableObservation,
    frozen: files.ExecutableObservation,
    dmg_attested: bool,
    frozen_attested: bool,
};

pub const CandidateAttestation = struct {
    owner: ?*CandidateAttestation = null,
    tag: [context_mod.max_value_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    workflow_ref: [context_mod.max_value_bytes]u8 = @splat(0),
    workflow_ref_len: usize = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,
    dmg: files.PinnedReleaseFile = .{},
    frozen: files.PinnedReleaseFile = .{},
    dmg_attested: bool = false,
    frozen_attested: bool = false,

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or !self.dmg_attested or !self.frozen_attested) return null;
        return .{ .tag = self.tag[0..self.tag_len], .source_commit = &self.source_commit, .build = .{ .workflow_ref = self.workflow_ref[0..self.workflow_ref_len], .run_id = self.run_id, .run_attempt = self.run_attempt }, .dmg = self.dmg.value() orelse return null, .frozen = self.frozen.value() orelse return null, .dmg_attested = true, .frozen_attested = true };
    }

    pub fn revalidate(self: *const @This(), paths: Paths) !View {
        const current = self.value() orelse return error.InvalidOwner;
        const dmg = self.dmg.revalidate(paths.dmg) catch return error.FileChanged;
        const frozen = self.frozen.revalidate(paths.frozen_executable) catch return error.FileChanged;
        return .{ .tag = current.tag, .source_commit = current.source_commit, .build = current.build, .dmg = dmg, .frozen = frozen, .dmg_attested = true, .frozen_attested = true };
    }

    pub fn deinit(self: *@This()) !void {
        if (self.owner != self or self.dmg.value() == null or self.frozen.value() == null) return error.InvalidOwner;
        try self.frozen.deinit();
        try self.dmg.deinit();
        self.* = .{};
    }
};

const RealAuthority = struct {
    pinned: *const cli_authority.PinnedExecutable,
    fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};
const RealVerifier = struct {
    fn verifyWith(_: *@This(), executor: anytype, allocator: std.mem.Allocator, executable: []const u8, token: []const u8, path: []const u8, expected: attestation.Expected, output: []u8, budget: i128) !attestation.Observed {
        return attestation.verifyWith(executor, allocator, executable, token, path, expected, output, budget);
    }
};
const RealBundleVerifier = struct {
    fn verifyBundleWith(_: *@This(), executor: anytype, allocator: std.mem.Allocator, executable: []const u8, path: []const u8, bundle_path: []const u8, expected: attestation.Expected, output: []u8, budget: i128) !attestation.Observed {
        return attestation.verifyBundleWith(executor, allocator, executable, path, bundle_path, expected, output, budget);
    }
};
pub fn composeUntil(io: std.Io, allocator: std.mem.Allocator, context: context_mod.Context, paths: Paths, cli: Cli, token: []const u8, output: []u8, deadline: *deadline_mod.Deadline, result: *CandidateAttestation) !void {
    var authority = RealAuthority{ .pinned = cli.pinned };
    var verifier = RealVerifier{};
    var executor = attestation.BoundedExecutor{ .io = io };
    return composeUntilWith(&authority, &verifier, &executor, deadline, allocator, context, paths, cli.path, token, output, result);
}

pub fn composeBundlesUntil(io: std.Io, allocator: std.mem.Allocator, context: context_mod.Context, paths: Paths, bundles: BundlePaths, cli: Cli, output: []u8, deadline: *deadline_mod.Deadline, result: *CandidateAttestation) !void {
    var authority = RealAuthority{ .pinned = cli.pinned };
    var verifier = RealBundleVerifier{};
    var executor = attestation.BoundedExecutor{ .io = io };
    return composeBundlesUntilWith(&authority, &verifier, &executor, deadline, allocator, context, paths, bundles, cli.path, output, result);
}

pub fn composeBundlesUntilWith(authority: anytype, verifier: anytype, executor: anytype, deadline: anytype, allocator: std.mem.Allocator, context: context_mod.Context, paths: Paths, bundles: BundlePaths, executable: [:0]const u8, output: []u8, result: *CandidateAttestation) !void {
    if (result.owner != null or result.dmg.owner != null or result.frozen.owner != null) return error.InvalidOwner;
    try validateBundleInputs(context, paths, bundles, executable, output, result);
    var published = false;
    defer {
        if (!published) result.* = .{};
    }

    try files.pinReleaseFileObserved(&result.dmg, paths.dmg, false, files.max_release_asset_bytes);
    var dmg_owned = true;
    defer if (dmg_owned) result.dmg.deinit() catch {};
    try files.pinReleaseFileObserved(&result.frozen, paths.frozen_executable, true, files.max_release_asset_bytes);
    var frozen_owned = true;
    defer if (frozen_owned) result.frozen.deinit() catch {};

    var bundle_owners = [_]files.PinnedReleaseFile{ .{}, .{} };
    defer {
        for (&bundle_owners) |*bundle| if (bundle.owner == bundle) bundle.deinit() catch {};
    }
    try files.pinReleaseFileObserved(&bundle_owners[0], bundles.dmg_bundle, false, max_local_bundle_bytes);
    try files.pinReleaseFileObserved(&bundle_owners[1], bundles.frozen_bundle, false, max_local_bundle_bytes);

    const role_paths = [_][:0]const u8{ paths.dmg, paths.frozen_executable };
    const bundle_paths = [_][:0]const u8{ bundles.dmg_bundle, bundles.frozen_bundle };
    const names = [_][]const u8{ std.fs.path.basename(paths.dmg), std.fs.path.basename(paths.frozen_executable) };
    var observations = try revalidateBundleGraph(result, paths, &bundle_owners, bundles);
    for (role_paths, 0..) |path, index| {
        _ = try deadline.remaining();
        try authority.revalidate(allocator, executable);
        observations = try revalidateBundleGraph(result, paths, &bundle_owners, bundles);
        const budget = try deadline.remaining();
        var observed = try verifier.verifyBundleWith(
            executor,
            allocator,
            executable,
            path,
            bundle_paths[index],
            .{ .context = context, .subject_name = names[index], .subject_sha256 = if (index == 0) &observations[0].sha256 else &observations[1].sha256 },
            output,
            budget,
        );
        defer observed.deinit(allocator);
        if (!observed.verified or observed.run_id != context.build.run_id or observed.run_attempt != context.build.run_attempt or
            !std.mem.eql(u8, observed.subject_name, names[index]) or
            !std.mem.eql(u8, observed.subject_sha256, if (index == 0) &observations[0].sha256 else &observations[1].sha256))
            return error.AttestationMismatch;
        try authority.revalidate(allocator, executable);
        _ = try revalidateBundleGraph(result, paths, &bundle_owners, bundles);
        if (index == 0) result.dmg_attested = true else result.frozen_attested = true;
    }
    _ = try revalidateBundleGraph(result, paths, &bundle_owners, bundles);
    try authority.revalidate(allocator, executable);
    _ = try deadline.remaining();
    try publishContext(context, result);
    for (&bundle_owners) |*bundle| try bundle.deinit();
    dmg_owned = false;
    frozen_owned = false;
    published = true;
}

pub fn composeUntilWith(authority: anytype, verifier: anytype, executor: anytype, deadline: anytype, allocator: std.mem.Allocator, context: context_mod.Context, paths: Paths, executable: [:0]const u8, token: []const u8, output: []u8, result: *CandidateAttestation) !void {
    if (result.owner != null or result.dmg.owner != null or result.frozen.owner != null) return error.InvalidOwner;
    try validateInputs(context, paths, executable, token, output, result);
    var published = false;
    defer {
        if (!published) result.* = .{};
    }
    try files.pinReleaseFileObserved(&result.dmg, paths.dmg, false, files.max_release_asset_bytes);
    var dmg_owned = true;
    defer if (dmg_owned) result.dmg.deinit() catch {};
    try files.pinReleaseFileObserved(&result.frozen, paths.frozen_executable, true, files.max_release_asset_bytes);
    var frozen_owned = true;
    defer if (frozen_owned) result.frozen.deinit() catch {};
    var dmg = try result.dmg.revalidate(paths.dmg);
    var frozen = try result.frozen.revalidate(paths.frozen_executable);
    try files.requireDistinct(&.{ dmg.identity, frozen.identity });
    const role_paths = [_][:0]const u8{ paths.dmg, paths.frozen_executable };
    const names = [_][]const u8{ std.fs.path.basename(paths.dmg), std.fs.path.basename(paths.frozen_executable) };
    const digests = [_][]const u8{ &dmg.sha256, &frozen.sha256 };
    for (role_paths, 0..) |path, index| {
        _ = try deadline.remaining();
        try authority.revalidate(allocator, executable);
        if (index == 0) dmg = try result.dmg.revalidate(paths.dmg) else frozen = try result.frozen.revalidate(paths.frozen_executable);
        const budget = try deadline.remaining();
        var observed = try verifier.verifyWith(executor, allocator, executable, token, path, .{ .context = context, .subject_name = names[index], .subject_sha256 = digests[index] }, output, budget);
        defer observed.deinit(allocator);
        if (!observed.verified or observed.run_id != context.build.run_id or observed.run_attempt != context.build.run_attempt or
            !std.mem.eql(u8, observed.subject_name, names[index]) or !std.mem.eql(u8, observed.subject_sha256, digests[index])) return error.AttestationMismatch;
        try authority.revalidate(allocator, executable);
        if (index == 0) {
            _ = try result.dmg.revalidate(paths.dmg);
            result.dmg_attested = true;
        } else {
            _ = try result.frozen.revalidate(paths.frozen_executable);
            result.frozen_attested = true;
        }
    }
    dmg = try result.dmg.revalidate(paths.dmg);
    frozen = try result.frozen.revalidate(paths.frozen_executable);
    try files.requireDistinct(&.{ dmg.identity, frozen.identity });
    _ = try deadline.remaining();
    try publishContext(context, result);
    dmg_owned = false;
    frozen_owned = false;
    published = true;
}

fn validateInputs(context: context_mod.Context, paths: Paths, executable: []const u8, token: []const u8, output: []u8, result: *CandidateAttestation) !void {
    try validateCommonInputs(context, paths, executable, output, result);
    if (!validScalar(token)) return error.InvalidInput;
    if (overlaps(output, token)) return error.InvalidInput;
}

fn validateBundleInputs(context: context_mod.Context, paths: Paths, bundles: BundlePaths, executable: []const u8, output: []u8, result: *CandidateAttestation) !void {
    try validateCommonInputs(context, paths, executable, output, result);
    const values = [_][]const u8{ paths.dmg, paths.frozen_executable, bundles.dmg_bundle, bundles.frozen_bundle, executable };
    for (values, 0..) |left, index| {
        if (!canonicalAbsolutePath(left)) return error.InvalidInput;
        if (overlaps(output, left) or overlaps(std.mem.asBytes(result), left)) return error.InvalidInput;
        for (values[index + 1 ..]) |right| if (std.mem.eql(u8, left, right)) return error.InvalidInput;
    }
}

fn validateCommonInputs(context: context_mod.Context, paths: Paths, executable: []const u8, output: []u8, result: *CandidateAttestation) !void {
    if (!context.protected_tag or context.repository.id == 0 or !std.mem.eql(u8, context.repository.owner, "ohah") or !std.mem.eql(u8, context.repository.name, "maru") or
        !identity.canonicalTag(context.tag) or !identity.lowerHex(context.source_commit, 40) or context.build.run_id == 0 or context.build.run_attempt == 0 or
        context.build.workflow_ref.len == 0 or context.build.workflow_ref.len > context_mod.max_value_bytes) return error.AuthorityMismatch;
    var workflow_storage: [context_mod.max_value_bytes]u8 = undefined;
    const workflow = std.fmt.bufPrint(&workflow_storage, "ohah/maru/.github/workflows/release.yml@refs/tags/{s}", .{context.tag}) catch return error.AuthorityMismatch;
    if (!std.mem.eql(u8, context.build.workflow_ref, workflow)) return error.AuthorityMismatch;
    var dmg_storage: [context_mod.max_value_bytes]u8 = undefined;
    var frozen_storage: [context_mod.max_value_bytes]u8 = undefined;
    const version = context.tag[1..];
    const dmg_name = std.fmt.bufPrint(&dmg_storage, "Maru-{s}-universal.dmg", .{version}) catch return error.InvalidPath;
    const frozen_name = std.fmt.bufPrint(&frozen_storage, "maru-session-host-{s}", .{version}) catch return error.InvalidPath;
    if (!std.fs.path.isAbsolute(paths.dmg) or !std.fs.path.isAbsolute(paths.frozen_executable) or !std.mem.eql(u8, std.fs.path.basename(paths.dmg), dmg_name) or
        !std.mem.eql(u8, std.fs.path.basename(paths.frozen_executable), frozen_name) or std.mem.eql(u8, paths.dmg, paths.frozen_executable)) return error.InvalidPath;
    if (!std.fs.path.isAbsolute(executable) or !validScalar(executable) or output.len == 0 or output.len > attestation.max_response_bytes) return error.InvalidInput;
    const result_bytes = std.mem.asBytes(result);
    for ([_][]const u8{ result_bytes, context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref, paths.dmg, paths.frozen_executable, executable }) |authority_bytes| {
        if (overlaps(output, authority_bytes)) return error.InvalidInput;
    }
}

fn revalidateBundleGraph(result: *const CandidateAttestation, paths: Paths, bundles: *const [2]files.PinnedReleaseFile, bundle_paths: BundlePaths) ![4]files.ExecutableObservation {
    const values = [4]files.ExecutableObservation{
        try result.dmg.revalidate(paths.dmg),
        try result.frozen.revalidate(paths.frozen_executable),
        try bundles[0].revalidate(bundle_paths.dmg_bundle),
        try bundles[1].revalidate(bundle_paths.frozen_bundle),
    };
    try files.requireDistinct(&.{ values[0].identity, values[1].identity, values[2].identity, values[3].identity });
    return values;
}

fn publishContext(context: context_mod.Context, result: *CandidateAttestation) !void {
    if (!result.dmg_attested or !result.frozen_attested) return error.AttestationMismatch;
    result.tag_len = context.tag.len;
    @memcpy(result.tag[0..result.tag_len], context.tag);
    @memcpy(&result.source_commit, context.source_commit);
    result.workflow_ref_len = context.build.workflow_ref.len;
    @memcpy(result.workflow_ref[0..result.workflow_ref_len], context.build.workflow_ref);
    result.run_id = context.build.run_id;
    result.run_attempt = context.build.run_attempt;
    result.owner = result;
}

fn canonicalAbsolutePath(value: []const u8) bool {
    if (!std.fs.path.isAbsolute(value) or value.len < 2 or value.len >= std.fs.max_path_bytes or
        value[value.len - 1] == '/' or std.mem.indexOfScalar(u8, value, 0) != null) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn validScalar(value: []const u8) bool {
    if (value.len == 0 or value.len > attestation.max_token_bytes) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}
