//! Closed command grammar for the fresh-process authored-attestation final fence.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const profile_mod = @import("release_adapter_profile_endorsement");
const selector = @import("release_adapter_profile_authored_attestation_selector");
const fence_mod = @import("release_adapter_profile_authored_attestation_fence");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");
const attestation = @import("release_adapter_github_attestation");

pub const option_count: usize = 17;
pub const argument_count: usize = 1 + option_count * 2;
pub const budget_ns: i128 = 120 * std.time.ns_per_s;
pub const max_output_bytes: usize = 5 * std.fs.max_path_bytes + 128;

pub const Execution = struct {
    owner: ?*@This() = null,
    fence: fence_mod.Fence = .{},
    deadline: deadline_mod.Deadline = .{},
    response: [attestation.max_response_bytes]u8 = undefined,
    encoded: [max_output_bytes]u8 = @splat(0),
    encoded_len: usize = 0,
    seal: [32]u8 = @splat(0),

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and self.fence.isPristineForComposition() and self.deadline.isPristineForComposition() and
            self.encoded_len == 0 and allZero(&self.encoded) and allZero(&self.seal);
    }

    pub fn output(self: *const @This()) ?[]const u8 {
        if (self.owner != self or self.encoded_len == 0 or self.encoded_len > self.encoded.len or
            !self.fence.isPristineForComposition() or !self.deadline.isPristineForComposition() or
            !std.mem.eql(u8, &self.seal, &executionSeal(self))) return null;
        return self.encoded[0..self.encoded_len];
    }

    pub fn deinit(self: *@This()) !void {
        if (self.output() == null) return error.InvalidOwner;
        self.* = .{};
    }
};

pub const Paths = struct {
    preparation: []const u8,
    baseline_evidence: []const u8,
    upgrade_evidence: []const u8,
    manifest: []const u8,
    timing: []const u8,
};

pub const Projection = struct {
    evidence_path: []const u8,
    evidence_name: []const u8,
    manifest_path: []const u8,
    manifest_name: []const u8,
    timing_required: bool,
    timing_path: []const u8,
    timing_name: []const u8,
};

pub const Bundles = struct { evidence: []const u8, manifest: []const u8, timing: []const u8 };
pub const Parsed = struct {
    paths: Paths,
    projection: Projection,
    bundles: Bundles,
    github_cli: []const u8,
    github_cli_sha256: []const u8,
};

const options = [_][]const u8{
    "--preparation",
    "--baseline-evidence",
    "--upgrade-evidence",
    "--manifest",
    "--timing",
    "--evidence-path",
    "--evidence-name",
    "--manifest-path",
    "--manifest-name",
    "--timing-required",
    "--timing-path",
    "--timing-name",
    "--evidence-bundle",
    "--manifest-bundle",
    "--timing-bundle",
    "--github-cli",
    "--github-cli-sha256",
};

pub fn parse(args: []const []const u8) !Parsed {
    if (args.len != argument_count) return error.InvalidArguments;
    if (!std.mem.eql(u8, args[0], "fence")) return error.InvalidCommand;
    var values: [option_count]?[]const u8 = @splat(null);
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        const option = args[index];
        const value = args[index + 1];
        if (hasControl(option) or hasControl(value) or value.len >= std.fs.max_path_bytes) return error.InvalidArguments;
        var found: ?usize = null;
        for (options, 0..) |candidate, candidate_index| if (std.mem.eql(u8, option, candidate)) {
            found = candidate_index;
            break;
        };
        const option_index = found orelse return error.InvalidArguments;
        if (values[option_index] != null) return error.InvalidArguments;
        if (value.len == 0 and option_index != 10 and option_index != 11 and option_index != 14) return error.InvalidArguments;
        values[option_index] = value;
    }
    for (&values) |value| if (value == null) return error.InvalidArguments;
    const v = values;
    const timing_required = if (std.mem.eql(u8, v[9].?, "true")) true else if (std.mem.eql(u8, v[9].?, "false")) false else return error.InvalidProfileTuple;
    const paths: Paths = .{ .preparation = v[0].?, .baseline_evidence = v[1].?, .upgrade_evidence = v[2].?, .manifest = v[3].?, .timing = v[4].? };
    const projection: Projection = .{
        .evidence_path = v[5].?,
        .evidence_name = v[6].?,
        .manifest_path = v[7].?,
        .manifest_name = v[8].?,
        .timing_required = timing_required,
        .timing_path = v[10].?,
        .timing_name = v[11].?,
    };
    const bundles: Bundles = .{ .evidence = v[12].?, .manifest = v[13].?, .timing = v[14].? };
    inline for (.{ paths.preparation, paths.baseline_evidence, paths.upgrade_evidence, paths.manifest, paths.timing, projection.evidence_path, projection.manifest_path, bundles.evidence, bundles.manifest, v[15].? }) |path|
        if (!canonicalAbsolute(path)) return error.InvalidArguments;
    if (!std.mem.eql(u8, projection.manifest_path, paths.manifest) or
        !std.mem.eql(u8, std.fs.path.basename(projection.evidence_path), projection.evidence_name) or
        !std.mem.eql(u8, std.fs.path.basename(projection.manifest_path), projection.manifest_name)) return error.InvalidProfileTuple;
    const upgrade = std.mem.eql(u8, projection.evidence_path, paths.upgrade_evidence);
    if ((!upgrade and !std.mem.eql(u8, projection.evidence_path, paths.baseline_evidence)) or upgrade != timing_required) return error.InvalidProfileTuple;
    if (timing_required) {
        if (!canonicalAbsolute(projection.timing_path) or !canonicalAbsolute(bundles.timing) or
            !std.mem.eql(u8, projection.timing_path, paths.timing) or
            !std.mem.eql(u8, std.fs.path.basename(projection.timing_path), projection.timing_name)) return error.InvalidProfileTuple;
    } else if (projection.timing_path.len != 0 or projection.timing_name.len != 0 or bundles.timing.len != 0) return error.InvalidProfileTuple;
    if (!lowerHex(v[16].?, 64)) return error.InvalidArguments;
    return .{ .paths = paths, .projection = projection, .bundles = bundles, .github_cli = v[15].?, .github_cli_sha256 = v[16].? };
}

pub fn compose(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    environment: profile_mod.Environment,
    args: []const []const u8,
    result: *Execution,
) ![]const u8 {
    if (!result.isPristineForComposition()) return error.InvalidOwner;
    const result_bytes = std.mem.asBytes(result);
    for (args) |arg| if (overlaps(arg, result_bytes)) return error.InvalidOwner;
    for ([_][]const u8{ context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref }) |scalar|
        if (overlaps(scalar, result_bytes)) return error.InvalidOwner;
    const parsed = try parse(args);

    var storage: [option_count][std.fs.max_path_bytes:0]u8 = @splat(@splat(0));
    var lengths: [option_count]usize = @splat(0);
    const ordered = [_][]const u8{
        parsed.paths.preparation,
        parsed.paths.baseline_evidence,
        parsed.paths.upgrade_evidence,
        parsed.paths.manifest,
        parsed.paths.timing,
        parsed.projection.evidence_path,
        parsed.projection.evidence_name,
        parsed.projection.manifest_path,
        parsed.projection.manifest_name,
        if (parsed.projection.timing_required) "true" else "false",
        parsed.projection.timing_path,
        parsed.projection.timing_name,
        parsed.bundles.evidence,
        parsed.bundles.manifest,
        parsed.bundles.timing,
        parsed.github_cli,
        parsed.github_cli_sha256,
    };
    for (ordered, 0..) |value, index| {
        if (value.len >= storage[index].len) return error.InvalidArguments;
        @memcpy(storage[index][0..value.len], value);
        lengths[index] = value.len;
    }
    const paths: selector.Paths = .{
        .preparation = zValue(&storage, &lengths, 0),
        .baseline_evidence = zValue(&storage, &lengths, 1),
        .upgrade_evidence = zValue(&storage, &lengths, 2),
        .manifest = zValue(&storage, &lengths, 3),
        .timing = zValue(&storage, &lengths, 4),
    };
    const projection: selector.Projection = .{
        .evidence_path = zValue(&storage, &lengths, 5),
        .evidence_name = storage[6][0..lengths[6]],
        .manifest_path = zValue(&storage, &lengths, 7),
        .manifest_name = storage[8][0..lengths[8]],
        .timing_required = parsed.projection.timing_required,
        .timing_path = storage[10][0..lengths[10]],
        .timing_name = storage[11][0..lengths[11]],
    };
    const bundles: fence_mod.BundlePaths = .{
        .evidence = zValue(&storage, &lengths, 12),
        .manifest = zValue(&storage, &lengths, 13),
        .timing = zValue(&storage, &lengths, 14),
    };
    const cli_path = zValue(&storage, &lengths, 15);
    const pinned = try cli_authority.pin(allocator, cli_path, storage[16][0..lengths[16]]);
    errdefer settleFailure(result);
    try deadline_mod.start(budget_ns, &result.deadline);
    try fence_mod.composeBundlesUntil(io, allocator, context, environment, paths, projection, bundles, .{ .path = cli_path, .pinned = &pinned }, &result.response, &result.deadline, &result.fence);
    const view = try result.fence.revalidate(allocator, context, environment);
    result.encoded_len = try encode(&result.encoded, view);
    _ = try result.deadline.remaining();
    try result.fence.deinit();
    try result.deadline.deinit();
    @memset(&result.response, 0);
    result.owner = result;
    result.seal = executionSeal(result);
    return result.output() orelse error.InvalidOwner;
}

fn zValue(storage: *const [option_count][std.fs.max_path_bytes:0]u8, lengths: *const [option_count]usize, index: usize) [:0]const u8 {
    return storage[index][0..lengths[index] :0];
}

fn encode(output: []u8, value: fence_mod.View) !usize {
    inline for (.{ value.projection.evidence_path, value.projection.timing_path, value.evidence_bundle, value.manifest_bundle, value.timing_bundle }) |path|
        if (hasControl(path)) return error.InvalidOutput;
    const written = std.fmt.bufPrint(output, "evidence-path={s}\ntiming-path={s}\nevidence-bundle-path={s}\nmanifest-bundle-path={s}\ntiming-bundle-path={s}\n", .{ value.projection.evidence_path, value.projection.timing_path, value.evidence_bundle, value.manifest_bundle, value.timing_bundle }) catch return error.OutputTooLarge;
    return written.len;
}

fn settleFailure(result: *Execution) void {
    if (result.fence.owner == &result.fence) result.fence.deinit() catch {};
    if (result.deadline.owner == &result.deadline) result.deadline.deinit() catch {};
    result.* = .{};
}

fn executionSeal(value: *const Execution) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update(std.mem.asBytes(&value.encoded_len));
    hash.update(value.encoded[0..value.encoded_len]);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn canonicalAbsolute(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/' or path[path.len - 1] == '/' or hasControl(path)) return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn lowerHex(value: []const u8, expected: usize) bool {
    if (value.len != expected) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn hasControl(value: []const u8) bool {
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return true;
    return false;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const a = @intFromPtr(left.ptr);
    const b = @intFromPtr(right.ptr);
    const a_end = std.math.add(usize, a, left.len) catch return true;
    const b_end = std.math.add(usize, b, right.len) catch return true;
    return a < b_end and b < a_end;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
