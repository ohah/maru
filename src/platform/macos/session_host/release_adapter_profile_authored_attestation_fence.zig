//! Final credential-free fence for profile-selected authored attestation bundles.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const attestation = @import("release_adapter_github_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");
const bundle_contract = @import("release_adapter_attestation_bundle_contract");
const profile_mod = @import("release_adapter_profile_endorsement");
const selector = @import("release_adapter_profile_authored_attestation_selector");

pub const BundlePaths = struct {
    evidence: [:0]const u8,
    manifest: [:0]const u8,
    timing: [:0]const u8,
};

pub const Cli = struct {
    path: [:0]const u8,
    pinned: *const cli_authority.PinnedExecutable,
};

pub const View = struct {
    projection: selector.Projection,
    evidence_bundle: []const u8,
    manifest_bundle: []const u8,
    timing_bundle: []const u8,
    verified_count: usize,
};

pub const Fence = struct {
    owner: ?*@This() = null,
    plan: selector.Plan = .{},
    bundles: [3]files.PinnedReleaseFile = @splat(.{}),
    bundle_paths: [3][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    bundle_path_lens: [3]usize = @splat(0),
    verified_count: usize = 0,
    seal: [32]u8 = @splat(0),

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and self.plan.isPristineForComposition() and self.verified_count == 0 and
            std.mem.allEqual(usize, &self.bundle_path_lens, 0) and allZero(std.mem.asBytes(&self.bundle_paths)) and
            allZero(&self.seal) and allBundlesPristine(&self.bundles);
    }

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or !std.mem.eql(u8, &self.seal, &fenceSeal(self))) return null;
        const projection = self.plan.value() orelse return null;
        const expected_count: usize = if (projection.timing_required) 3 else 2;
        if (self.verified_count != expected_count) return null;
        for (self.bundles[0..expected_count]) |*bundle| if (bundle.value() == null) return null;
        if (!projection.timing_required and self.bundles[2].value() != null) return null;
        return .{
            .projection = projection,
            .evidence_bundle = self.bundlePath(0),
            .manifest_bundle = self.bundlePath(1),
            .timing_bundle = if (expected_count == 3) self.bundlePath(2) else "",
            .verified_count = expected_count,
        };
    }

    pub fn revalidate(self: *const @This(), allocator: std.mem.Allocator, context: context_mod.Context, environment: profile_mod.Environment) !View {
        const current = self.value() orelse return error.InvalidOwner;
        const projection = try self.plan.fence(allocator, context, environment);
        if (!sameProjection(current.projection, projection)) return error.AuthorityChanged;
        _ = try revalidateGraph(self, projection);
        return self.value() orelse error.InvalidOwner;
    }

    pub fn deinit(self: *@This()) !void {
        const current = self.value() orelse return error.InvalidOwner;
        var first_error: ?anyerror = null;
        var index = current.verified_count;
        while (index > 0) {
            index -= 1;
            self.bundles[index].deinit() catch |err| if (first_error == null) {
                first_error = err;
            };
        }
        self.plan.deinit() catch |err| if (first_error == null) {
            first_error = err;
        };
        self.* = .{};
        if (first_error) |err| return err;
    }

    fn bundlePath(self: *const @This(), index: usize) [:0]const u8 {
        return self.bundle_paths[index][0..self.bundle_path_lens[index] :0];
    }
};

const RealAuthority = struct {
    pinned: *const cli_authority.PinnedExecutable,
    fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};

const RealVerifier = struct {
    fn verifyBundleWith(_: *@This(), executor: anytype, allocator: std.mem.Allocator, executable: []const u8, path: []const u8, bundle_path: []const u8, expected: attestation.Expected, output: []u8, budget: i128) !attestation.Observed {
        return attestation.verifyBundleWith(executor, allocator, executable, path, bundle_path, expected, output, budget);
    }
};

pub fn composeBundlesUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    environment: profile_mod.Environment,
    paths: selector.Paths,
    expected: selector.Projection,
    bundle_paths: BundlePaths,
    cli: Cli,
    output: []u8,
    deadline: *deadline_mod.Deadline,
    result: *Fence,
) !void {
    var authority = RealAuthority{ .pinned = cli.pinned };
    var verifier = RealVerifier{};
    var executor = attestation.BoundedExecutor{ .io = io };
    return composeBundlesUntilWith(&authority, &verifier, &executor, deadline, allocator, context, environment, paths, expected, bundle_paths, cli.path, output, result);
}

pub fn composeBundlesUntilWith(
    authority: anytype,
    verifier: anytype,
    executor: anytype,
    deadline: anytype,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    environment: profile_mod.Environment,
    paths: selector.Paths,
    expected: selector.Projection,
    bundle_paths: BundlePaths,
    executable: [:0]const u8,
    output: []u8,
    result: *Fence,
) !void {
    if (!result.isPristineForComposition()) return error.InvalidOwner;
    try validateInputs(context, paths, expected, bundle_paths, executable, output, result);
    var published = false;
    defer {
        if (!published) result.* = .{};
    }
    errdefer closeWorking(result);

    try selector.select(allocator, context, environment, paths, &result.plan);
    const selected = try result.plan.fence(allocator, context, environment);
    if (!sameProjection(expected, selected)) return error.ProjectionMismatch;
    const count: usize = if (selected.timing_required) 3 else 2;
    try copyBundlePaths(result, bundle_paths, count);
    for (0..count) |index| try files.pinReleaseFileObserved(&result.bundles[index], result.bundlePath(index), false, bundle_contract.max_bytes);
    _ = try revalidateGraph(result, selected);

    const subject_paths = [_][]const u8{ selected.evidence_path, selected.manifest_path, selected.timing_path };
    const subject_names = [_][]const u8{ selected.evidence_name, selected.manifest_name, selected.timing_name };
    for (0..count) |index| {
        _ = try deadline.remaining();
        try authority.revalidate(allocator, executable);
        const current = try result.plan.fence(allocator, context, environment);
        if (!sameProjection(selected, current)) return error.AuthorityChanged;
        const subjects = try revalidateGraph(result, current);
        const budget = try deadline.remaining();
        {
            var observed = try verifier.verifyBundleWith(executor, allocator, executable, subject_paths[index], result.bundlePath(index), .{
                .context = context,
                .subject_name = subject_names[index],
                .subject_sha256 = &subjects[index].sha256,
            }, output, budget);
            defer observed.deinit(allocator);
            if (!observed.verified or observed.run_id != context.build.run_id or observed.run_attempt != context.build.run_attempt or
                !std.mem.eql(u8, observed.subject_name, subject_names[index]) or !std.mem.eql(u8, observed.subject_sha256, &subjects[index].sha256))
                return error.AttestationMismatch;
        }
        try authority.revalidate(allocator, executable);
        const after = try result.plan.fence(allocator, context, environment);
        if (!sameProjection(selected, after)) return error.AuthorityChanged;
        _ = try revalidateGraph(result, after);
        result.verified_count = index + 1;
    }
    const final_projection = try result.plan.fence(allocator, context, environment);
    if (!sameProjection(selected, final_projection)) return error.AuthorityChanged;
    _ = try revalidateGraph(result, final_projection);
    try authority.revalidate(allocator, executable);
    _ = try deadline.remaining();
    result.owner = result;
    result.seal = fenceSeal(result);
    _ = result.value() orelse return error.InvalidOwner;
    published = true;
}

fn validateInputs(context: context_mod.Context, paths: selector.Paths, expected: selector.Projection, bundles: BundlePaths, executable: []const u8, output: []u8, result: *Fence) !void {
    context_mod.validateTrusted(context) catch return error.AuthorityMismatch;
    if (!canonicalAbsolute(executable) or output.len == 0 or output.len > attestation.max_response_bytes) return error.InvalidInput;
    const timing_present = expected.timing_required;
    if (expected.evidence_name.len == 0 or expected.manifest_name.len == 0 or
        !std.mem.eql(u8, std.fs.path.basename(expected.evidence_path), expected.evidence_name) or
        !std.mem.eql(u8, std.fs.path.basename(expected.manifest_path), expected.manifest_name) or
        (timing_present != (expected.timing_path.len != 0 and expected.timing_name.len != 0 and bundles.timing.len != 0)) or
        (!timing_present and (expected.timing_path.len != 0 or expected.timing_name.len != 0 or bundles.timing.len != 0)) or
        (timing_present and !std.mem.eql(u8, std.fs.path.basename(expected.timing_path), expected.timing_name))) return error.InvalidInput;
    const expected_upgrade = std.mem.eql(u8, expected.evidence_path, paths.upgrade_evidence);
    if ((!std.mem.eql(u8, expected.evidence_path, paths.baseline_evidence) and !expected_upgrade) or expected_upgrade != timing_present or
        !std.mem.eql(u8, expected.manifest_path, paths.manifest) or
        (timing_present and !std.mem.eql(u8, expected.timing_path, paths.timing))) return error.ProjectionMismatch;
    const result_bytes = std.mem.asBytes(result);
    if (overlaps(output, result_bytes)) return error.InvalidInput;
    for ([_][]const u8{
        context.repository.owner,
        context.repository.name,
        context.tag,
        context.source_commit,
        context.build.workflow_ref,
        expected.evidence_name,
        expected.manifest_name,
        expected.timing_name,
    }) |scalar| {
        if (overlaps(output, scalar) or overlaps(result_bytes, scalar)) return error.InvalidInput;
    }
    const required = [_][]const u8{ expected.evidence_path, expected.manifest_path, bundles.evidence, bundles.manifest, executable };
    for (required) |value| if (!canonicalAbsolute(value)) return error.InvalidInput;
    if (timing_present and (!canonicalAbsolute(expected.timing_path) or !canonicalAbsolute(bundles.timing))) return error.InvalidInput;
    const borrowed = [_][]const u8{ paths.preparation, paths.baseline_evidence, paths.upgrade_evidence, paths.manifest, paths.timing, executable };
    for (borrowed) |value| if (overlaps(output, value) or overlaps(result_bytes, value)) return error.InvalidInput;
    const bundle_values = [_][]const u8{ bundles.evidence, bundles.manifest, bundles.timing };
    for (bundle_values, 0..) |left, index| {
        if (left.len == 0) continue;
        if (overlaps(output, left) or overlaps(result_bytes, left)) return error.InvalidInput;
        for (bundle_values[index + 1 ..]) |right| {
            if (right.len == 0) continue;
            if (related(left, right)) return error.PathAlias;
        }
        for (borrowed) |other| if (related(left, other)) return error.PathAlias;
    }
}

fn copyBundlePaths(result: *Fence, bundles: BundlePaths, count: usize) !void {
    const values = [_][:0]const u8{ bundles.evidence, bundles.manifest, bundles.timing };
    for (values[0..count], 0..) |path, index| {
        if (path.len >= result.bundle_paths[index].len) return error.InvalidPath;
        @memcpy(result.bundle_paths[index][0..path.len], path);
        result.bundle_path_lens[index] = path.len;
    }
}

fn revalidateGraph(result: *const Fence, projection: selector.Projection) ![3]files.ExecutableObservation {
    const prepared = result.plan.preparation.value() orelse return error.InvalidOwner;
    var subjects: [3]files.ExecutableObservation = undefined;
    subjects[0] = prepared.entries[0].observation;
    subjects[1] = prepared.entries[1].observation;
    if (projection.timing_required) subjects[2] = (result.plan.timing.value() orelse return error.InvalidOwner).observation;
    const count: usize = if (projection.timing_required) 3 else 2;
    var identities: [6]files.Identity = undefined;
    for (0..count) |index| {
        identities[index] = subjects[index].identity;
        identities[count + index] = (try result.bundles[index].revalidate(result.bundlePath(index))).identity;
    }
    try files.requireDistinct(identities[0 .. count * 2]);
    return subjects;
}

fn closeWorking(result: *Fence) void {
    var index: usize = result.bundles.len;
    while (index > 0) {
        index -= 1;
        if (result.bundles[index].value() != null) result.bundles[index].deinit() catch {};
    }
    if (!result.plan.isPristineForComposition()) result.plan.deinit() catch {};
}

fn sameProjection(left: selector.Projection, right: selector.Projection) bool {
    return left.timing_required == right.timing_required and
        std.mem.eql(u8, left.evidence_path, right.evidence_path) and std.mem.eql(u8, left.evidence_name, right.evidence_name) and
        std.mem.eql(u8, left.manifest_path, right.manifest_path) and std.mem.eql(u8, left.manifest_name, right.manifest_name) and
        std.mem.eql(u8, left.timing_path, right.timing_path) and std.mem.eql(u8, left.timing_name, right.timing_name);
}

fn fenceSeal(value: *const Fence) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update(std.mem.asBytes(&value.bundle_path_lens));
    hash.update(std.mem.asBytes(&value.bundle_paths));
    hash.update(std.mem.asBytes(&value.verified_count));
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn canonicalAbsolute(path: []const u8) bool {
    if (path.len < 2 or path.len >= std.fs.max_path_bytes or path[0] != '/' or path[path.len - 1] == '/') return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn related(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right) or descendant(left, right) or descendant(right, left);
}

fn descendant(parent: []const u8, child: []const u8) bool {
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/';
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const a = @intFromPtr(left.ptr);
    const b = @intFromPtr(right.ptr);
    const a_end = std.math.add(usize, a, left.len) catch return true;
    const b_end = std.math.add(usize, b, right.len) catch return true;
    return a < b_end and b < a_end;
}

fn allBundlesPristine(bundles: *const [3]files.PinnedReleaseFile) bool {
    for (bundles) |bundle| if (bundle.owner != null or bundle.fd >= 0 or bundle.parent_fd >= 0) return false;
    return true;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
