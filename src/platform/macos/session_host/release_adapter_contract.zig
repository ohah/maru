//! Closed command-line contract for the release provenance adapter.
//!
//! This is deliberately allocation-free and OS-neutral. The later executable adapter may observe
//! GitHub, codesign, and DMG facts, but it cannot invent another command, manifest name, repository,
//! environment, or observation JSON input without changing this reviewed boundary first.

const std = @import("std");

pub const summary_schema = "maru.session-host-release-validation.v1";
pub const protected_environment_name = "release";
pub const release_workflow_name = "Release";
pub const release_signing_job_name = "universal dmg (signed + notarized)";
pub const accepts_observation_json_input = false;
pub const repository_name = "ohah/maru";
pub const max_cli_value_bytes: usize = 4 * 1024;
pub const max_manifest_asset_name_bytes: usize = 255;

pub const PrePublish = struct {
    repo: []const u8,
    tag: []const u8,
    github_cli: []const u8,
    github_cli_sha256: []const u8,
    manifest: []const u8,
    evidence: []const u8,
    dmg: []const u8,
    frozen_executable: []const u8,
    work_dir: []const u8,
    summary_out: []const u8,
};

pub const VerifyPredecessor = struct {
    repo: []const u8,
    tag: []const u8,
    github_cli: []const u8,
    github_cli_sha256: []const u8,
    manifest: []const u8,
    work_dir: []const u8,
    summary_out: []const u8,
};

pub const PublishCandidate = struct {
    repo: []const u8,
    tag: []const u8,
    github_cli: []const u8,
    github_cli_sha256: []const u8,
    test_uuid: []const u8,
    dmg: []const u8,
    frozen_executable: []const u8,
    dmg_work: []const u8,
    baseline_workspace: []const u8,
    app_main_executable: []const u8,
    app_cli_executable: []const u8,
    manifest: []const u8,
    source_root: []const u8,
    zig: []const u8,
    zig_size: u64,
    zig_sha256: []const u8,
};

pub const PrepareCandidateAggregate = struct {
    repo: []const u8,
    tag: []const u8,
    github_cli: []const u8,
    github_cli_sha256: []const u8,
    evidence: []const u8,
    candidate_dmg_bundle: []const u8,
    candidate_frozen_bundle: []const u8,
    evidence_bundle: []const u8,
    manifest_bundle: []const u8,
    aggregate: []const u8,
};

pub const FinalizeCandidateAggregate = struct {
    repo: []const u8,
    tag: []const u8,
    github_cli: []const u8,
    github_cli_sha256: []const u8,
    aggregate: []const u8,
    dmg: []const u8,
    frozen_executable: []const u8,
    manifest: []const u8,
};

pub const Command = union(enum) {
    pre_publish: PrePublish,
    verify_predecessor: VerifyPredecessor,
    publish_candidate: PublishCandidate,
    prepare_candidate_aggregate: PrepareCandidateAggregate,
    finalize_candidate_aggregate: FinalizeCandidateAggregate,
};

pub const Error = error{
    MissingCommand,
    UnknownCommand,
    UnexpectedArgument,
    UnknownOption,
    MissingValue,
    MissingOption,
    DuplicateOption,
    EmptyValue,
    ValueTooLong,
    InvalidRepository,
    InvalidTag,
    InvalidVersion,
    InvalidManifestAssetName,
    InvalidGithubCliPath,
    InvalidGithubCliSha256,
    InvalidTestUuid,
    InvalidZigSize,
    InvalidZigSha256,
    InvalidCandidatePath,
    InvalidWorkDirPath,
    PathAlias,
    ManifestAssetNameTooLong,
};

const Values = struct {
    repo: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    github_cli: ?[]const u8 = null,
    github_cli_sha256: ?[]const u8 = null,
    manifest: ?[]const u8 = null,
    evidence: ?[]const u8 = null,
    dmg: ?[]const u8 = null,
    frozen_executable: ?[]const u8 = null,
    work_dir: ?[]const u8 = null,
    summary_out: ?[]const u8 = null,
    test_uuid: ?[]const u8 = null,
    dmg_work: ?[]const u8 = null,
    baseline_workspace: ?[]const u8 = null,
    app_main_executable: ?[]const u8 = null,
    app_cli_executable: ?[]const u8 = null,
    source_root: ?[]const u8 = null,
    zig: ?[]const u8 = null,
    zig_size: ?[]const u8 = null,
    zig_sha256: ?[]const u8 = null,
    candidate_dmg_bundle: ?[]const u8 = null,
    candidate_frozen_bundle: ?[]const u8 = null,
    evidence_bundle: ?[]const u8 = null,
    manifest_bundle: ?[]const u8 = null,
    aggregate: ?[]const u8 = null,
};

const Phase = enum {
    pre_publish,
    verify_predecessor,
    publish_candidate,
    prepare_candidate_aggregate,
    finalize_candidate_aggregate,
};

pub fn parseArgs(args: []const []const u8) Error!Command {
    if (args.len == 0) return error.MissingCommand;
    const phase: Phase = if (std.mem.eql(u8, args[0], "pre-publish"))
        .pre_publish
    else if (std.mem.eql(u8, args[0], "verify-predecessor"))
        .verify_predecessor
    else if (std.mem.eql(u8, args[0], "publish-candidate"))
        .publish_candidate
    else if (std.mem.eql(u8, args[0], "prepare-candidate-aggregate"))
        .prepare_candidate_aggregate
    else if (std.mem.eql(u8, args[0], "finalize-candidate-aggregate"))
        .finalize_candidate_aggregate
    else
        return error.UnknownCommand;

    var values: Values = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        const option = args[index];
        if (!std.mem.startsWith(u8, option, "--")) return error.UnexpectedArgument;
        if (index + 1 >= args.len or std.mem.startsWith(u8, args[index + 1], "--"))
            return error.MissingValue;
        const value = args[index + 1];
        if (value.len == 0) return error.EmptyValue;
        if (value.len > max_cli_value_bytes) return error.ValueTooLong;

        const destination: *?[]const u8 = optionDestination(phase, &values, option) orelse
            return error.UnknownOption;
        if (destination.* != null) return error.DuplicateOption;
        destination.* = value;
    }

    const repo = values.repo orelse return error.MissingOption;
    const tag = values.tag orelse return error.MissingOption;
    if (!std.mem.eql(u8, repo, repository_name)) return error.InvalidRepository;
    try validateTag(tag);

    return switch (phase) {
        .pre_publish => blk: {
            const manifest = values.manifest orelse return error.MissingOption;
            try validateManifestAssetPath(manifest, tag[1..]);
            const summary_out = values.summary_out orelse return error.MissingOption;
            const evidence = values.evidence orelse return error.MissingOption;
            const dmg = values.dmg orelse return error.MissingOption;
            const frozen_executable = values.frozen_executable orelse return error.MissingOption;
            const work_dir = try workDir(&values);
            const github_cli = try githubCli(&values);
            try disjointPaths(&.{ manifest, evidence, dmg, frozen_executable, work_dir, summary_out, github_cli.path });
            break :blk .{ .pre_publish = .{
                .repo = repo,
                .tag = tag,
                .github_cli = github_cli.path,
                .github_cli_sha256 = github_cli.sha256,
                .manifest = manifest,
                .evidence = evidence,
                .dmg = dmg,
                .frozen_executable = frozen_executable,
                .work_dir = work_dir,
                .summary_out = summary_out,
            } };
        },
        .verify_predecessor => blk: {
            const manifest = values.manifest orelse return error.MissingOption;
            try validateManifestAssetPath(manifest, tag[1..]);
            const summary_out = values.summary_out orelse return error.MissingOption;
            const work_dir = try workDir(&values);
            const github_cli = try githubCli(&values);
            try disjointPaths(&.{ manifest, work_dir, summary_out, github_cli.path });
            break :blk .{ .verify_predecessor = .{
                .repo = repo,
                .tag = tag,
                .github_cli = github_cli.path,
                .github_cli_sha256 = github_cli.sha256,
                .manifest = manifest,
                .work_dir = work_dir,
                .summary_out = summary_out,
            } };
        },
        .publish_candidate => blk: {
            const test_uuid = values.test_uuid orelse return error.MissingOption;
            if (!canonicalReleaseTestUuid(test_uuid)) return error.InvalidTestUuid;
            const dmg = try candidatePath(values.dmg);
            const frozen_executable = try candidatePath(values.frozen_executable);
            const dmg_work = try candidatePath(values.dmg_work);
            const baseline_workspace = try candidatePath(values.baseline_workspace);
            const app_main_executable = try candidatePath(values.app_main_executable);
            const app_cli_executable = try candidatePath(values.app_cli_executable);
            const candidate_manifest = try candidatePath(values.manifest);
            try validateManifestAssetPath(candidate_manifest, tag[1..]);
            const source_root = try candidatePath(values.source_root);
            const zig = try candidatePath(values.zig);
            const zig_size = try positiveDecimal(values.zig_size orelse return error.MissingOption);
            const zig_sha256 = values.zig_sha256 orelse return error.MissingOption;
            if (!lowerHexSha256(zig_sha256)) return error.InvalidZigSha256;
            const github_cli = try githubCli(&values);
            if (!canonicalAbsoluteLeaf(github_cli.path)) return error.InvalidCandidatePath;
            try disjointPaths(&.{ candidate_manifest, dmg, frozen_executable, dmg_work, baseline_workspace, app_main_executable, app_cli_executable, github_cli.path, zig });
            break :blk .{ .publish_candidate = .{
                .repo = repo,
                .tag = tag,
                .github_cli = github_cli.path,
                .github_cli_sha256 = github_cli.sha256,
                .test_uuid = test_uuid,
                .dmg = dmg,
                .frozen_executable = frozen_executable,
                .dmg_work = dmg_work,
                .baseline_workspace = baseline_workspace,
                .app_main_executable = app_main_executable,
                .app_cli_executable = app_cli_executable,
                .manifest = candidate_manifest,
                .source_root = source_root,
                .zig = zig,
                .zig_size = zig_size,
                .zig_sha256 = zig_sha256,
            } };
        },
        .prepare_candidate_aggregate => blk: {
            const evidence = try aggregatePath(values.evidence);
            const candidate_dmg_bundle = try aggregatePath(values.candidate_dmg_bundle);
            const candidate_frozen_bundle = try aggregatePath(values.candidate_frozen_bundle);
            const evidence_bundle = try aggregatePath(values.evidence_bundle);
            const manifest_bundle = try aggregatePath(values.manifest_bundle);
            const aggregate = try aggregatePath(values.aggregate);
            const github_cli = try githubCli(&values);
            if (!canonicalAggregatePath(github_cli.path)) return error.InvalidCandidatePath;
            try disjointPaths(&.{ evidence, candidate_dmg_bundle, candidate_frozen_bundle, evidence_bundle, manifest_bundle, aggregate, github_cli.path });
            break :blk .{ .prepare_candidate_aggregate = .{
                .repo = repo,
                .tag = tag,
                .github_cli = github_cli.path,
                .github_cli_sha256 = github_cli.sha256,
                .evidence = evidence,
                .candidate_dmg_bundle = candidate_dmg_bundle,
                .candidate_frozen_bundle = candidate_frozen_bundle,
                .evidence_bundle = evidence_bundle,
                .manifest_bundle = manifest_bundle,
                .aggregate = aggregate,
            } };
        },
        .finalize_candidate_aggregate => blk: {
            const aggregate = try aggregatePath(values.aggregate);
            const dmg = try aggregatePath(values.dmg);
            const frozen_executable = try aggregatePath(values.frozen_executable);
            const manifest = try aggregatePath(values.manifest);
            try validateManifestAssetPath(manifest, tag[1..]);
            const github_cli = try githubCli(&values);
            if (!canonicalAggregatePath(github_cli.path)) return error.InvalidCandidatePath;
            try disjointPaths(&.{ aggregate, dmg, frozen_executable, manifest, github_cli.path });
            break :blk .{ .finalize_candidate_aggregate = .{
                .repo = repo,
                .tag = tag,
                .github_cli = github_cli.path,
                .github_cli_sha256 = github_cli.sha256,
                .aggregate = aggregate,
                .dmg = dmg,
                .frozen_executable = frozen_executable,
                .manifest = manifest,
            } };
        },
    };
}

fn canonicalReleaseTestUuid(value: []const u8) bool {
    if (value.len != 36 or value[8] != '-' or value[13] != '-' or value[18] != '-' or
        value[23] != '-' or value[14] != '4' or
        (value[19] != '8' and value[19] != '9' and value[19] != 'a' and value[19] != 'b')) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) continue;
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn optionDestination(
    phase: Phase,
    values: *Values,
    option: []const u8,
) ?*?[]const u8 {
    if (std.mem.eql(u8, option, "--repo")) return &values.repo;
    if (std.mem.eql(u8, option, "--tag")) return &values.tag;
    if (std.mem.eql(u8, option, "--github-cli")) return &values.github_cli;
    if (std.mem.eql(u8, option, "--github-cli-sha256")) return &values.github_cli_sha256;
    if (std.mem.eql(u8, option, "--manifest") and phase != .prepare_candidate_aggregate) return &values.manifest;
    if (std.mem.eql(u8, option, "--summary-out") and (phase == .pre_publish or phase == .verify_predecessor)) return &values.summary_out;
    return switch (phase) {
        .pre_publish => if (std.mem.eql(u8, option, "--evidence"))
            &values.evidence
        else if (std.mem.eql(u8, option, "--dmg"))
            &values.dmg
        else if (std.mem.eql(u8, option, "--frozen-executable"))
            &values.frozen_executable
        else if (std.mem.eql(u8, option, "--work-dir"))
            &values.work_dir
        else
            null,
        .verify_predecessor => if (std.mem.eql(u8, option, "--work-dir"))
            &values.work_dir
        else
            null,
        .publish_candidate => if (std.mem.eql(u8, option, "--test-uuid"))
            &values.test_uuid
        else if (std.mem.eql(u8, option, "--dmg"))
            &values.dmg
        else if (std.mem.eql(u8, option, "--frozen-executable"))
            &values.frozen_executable
        else if (std.mem.eql(u8, option, "--dmg-work"))
            &values.dmg_work
        else if (std.mem.eql(u8, option, "--baseline-workspace"))
            &values.baseline_workspace
        else if (std.mem.eql(u8, option, "--app-main-executable"))
            &values.app_main_executable
        else if (std.mem.eql(u8, option, "--app-cli-executable"))
            &values.app_cli_executable
        else if (std.mem.eql(u8, option, "--source-root"))
            &values.source_root
        else if (std.mem.eql(u8, option, "--zig"))
            &values.zig
        else if (std.mem.eql(u8, option, "--zig-size"))
            &values.zig_size
        else if (std.mem.eql(u8, option, "--zig-sha256"))
            &values.zig_sha256
        else
            null,
        .prepare_candidate_aggregate => if (std.mem.eql(u8, option, "--evidence"))
            &values.evidence
        else if (std.mem.eql(u8, option, "--candidate-dmg-bundle"))
            &values.candidate_dmg_bundle
        else if (std.mem.eql(u8, option, "--candidate-frozen-bundle"))
            &values.candidate_frozen_bundle
        else if (std.mem.eql(u8, option, "--evidence-bundle"))
            &values.evidence_bundle
        else if (std.mem.eql(u8, option, "--manifest-bundle"))
            &values.manifest_bundle
        else if (std.mem.eql(u8, option, "--aggregate"))
            &values.aggregate
        else
            null,
        .finalize_candidate_aggregate => if (std.mem.eql(u8, option, "--aggregate"))
            &values.aggregate
        else if (std.mem.eql(u8, option, "--dmg"))
            &values.dmg
        else if (std.mem.eql(u8, option, "--frozen-executable"))
            &values.frozen_executable
        else
            null,
    };
}

fn candidatePath(value: ?[]const u8) Error![]const u8 {
    const path = value orelse return error.MissingOption;
    if (!canonicalAbsoluteLeaf(path)) return error.InvalidCandidatePath;
    return path;
}

fn aggregatePath(value: ?[]const u8) Error![]const u8 {
    const path = value orelse return error.MissingOption;
    if (!canonicalAggregatePath(path)) return error.InvalidCandidatePath;
    return path;
}

fn canonicalAggregatePath(path: []const u8) bool {
    if (!canonicalAbsoluteLeaf(path) or std.mem.indexOfScalar(u8, path, '=') != null) return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn positiveDecimal(value: []const u8) Error!u64 {
    if (value.len == 0 or value[0] == '0') return error.InvalidZigSize;
    var result: u64 = 0;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidZigSize;
        result = std.math.mul(u64, result, 10) catch return error.InvalidZigSize;
        result = std.math.add(u64, result, byte - '0') catch return error.InvalidZigSize;
    }
    return result;
}

fn lowerHexSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn workDir(values: *const Values) Error![]const u8 {
    const path = values.work_dir orelse return error.MissingOption;
    if (!canonicalAbsoluteLeaf(path)) return error.InvalidWorkDirPath;
    return path;
}

fn canonicalAbsoluteLeaf(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or path.len < 2 or path[path.len - 1] == '/' or
        std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, ".."))
            return false;
    }
    return true;
}

fn githubCli(values: *const Values) Error!struct { path: []const u8, sha256: []const u8 } {
    const path = values.github_cli orelse return error.MissingOption;
    const sha256 = values.github_cli_sha256 orelse return error.MissingOption;
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidGithubCliPath;
    if (sha256.len != 64) return error.InvalidGithubCliSha256;
    for (sha256) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f'))
        return error.InvalidGithubCliSha256;
    return .{ .path = path, .sha256 = sha256 };
}

pub fn manifestAssetName(buffer: []u8, version: []const u8) Error![]const u8 {
    try validateVersion(version);
    const result = std.fmt.bufPrint(buffer, "Maru-{s}-session-host-release.json", .{version}) catch
        return error.ManifestAssetNameTooLong;
    if (result.len > max_manifest_asset_name_bytes) return error.ManifestAssetNameTooLong;
    return result;
}

fn validateManifestAssetPath(path: []const u8, version: []const u8) Error!void {
    var buffer: [max_manifest_asset_name_bytes]u8 = undefined;
    const expected = try manifestAssetName(&buffer, version);
    if (!std.mem.eql(u8, std.fs.path.basename(path), expected))
        return error.InvalidManifestAssetName;
}

fn validateTag(tag: []const u8) Error!void {
    if (tag.len < 2 or tag[0] != 'v') return error.InvalidTag;
    validateVersion(tag[1..]) catch return error.InvalidTag;
}

fn validateVersion(version: []const u8) Error!void {
    var component_count: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= version.len) : (index += 1) {
        if (index != version.len and version[index] != '.') continue;
        const component = version[start..index];
        if (component.len == 0 or (component.len > 1 and component[0] == '0'))
            return error.InvalidVersion;
        for (component) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidVersion;
        component_count += 1;
        start = index + 1;
    }
    if (component_count != 3) return error.InvalidVersion;
}

fn disjointPaths(paths: []const []const u8) Error!void {
    for (paths, 0..) |path, left| {
        for (paths[left + 1 ..]) |other| {
            if (pathTreeOverlaps(path, other)) return error.PathAlias;
        }
    }
}

fn pathTreeOverlaps(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return true;
    if (left.len < right.len and std.mem.startsWith(u8, right, left) and right[left.len] == '/')
        return true;
    return right.len < left.len and std.mem.startsWith(u8, left, right) and left[right.len] == '/';
}
