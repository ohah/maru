//! Closed command-line contract for the release provenance adapter.
//!
//! This is deliberately allocation-free and OS-neutral. The later executable adapter may observe
//! GitHub, codesign, and DMG facts, but it cannot invent another command, manifest name, repository,
//! environment, or observation JSON input without changing this reviewed boundary first.

const std = @import("std");

pub const summary_schema = "maru.session-host-release-validation.v1";
pub const protected_environment_name = "release";
pub const accepts_observation_json_input = false;
pub const repository_name = "ohah/maru";
pub const max_cli_value_bytes: usize = 4 * 1024;
pub const max_manifest_asset_name_bytes: usize = 255;

pub const PrePublish = struct {
    repo: []const u8,
    tag: []const u8,
    manifest: []const u8,
    evidence: []const u8,
    dmg: []const u8,
    frozen_executable: []const u8,
    summary_out: []const u8,
};

pub const VerifyPredecessor = struct {
    repo: []const u8,
    tag: []const u8,
    manifest: []const u8,
    work_dir: []const u8,
    summary_out: []const u8,
};

pub const Command = union(enum) {
    pre_publish: PrePublish,
    verify_predecessor: VerifyPredecessor,
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
    PathAlias,
    ManifestAssetNameTooLong,
};

const Values = struct {
    repo: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    manifest: ?[]const u8 = null,
    evidence: ?[]const u8 = null,
    dmg: ?[]const u8 = null,
    frozen_executable: ?[]const u8 = null,
    work_dir: ?[]const u8 = null,
    summary_out: ?[]const u8 = null,
};

const Phase = enum {
    pre_publish,
    verify_predecessor,
};

pub fn parseArgs(args: []const []const u8) Error!Command {
    if (args.len == 0) return error.MissingCommand;
    const phase: Phase = if (std.mem.eql(u8, args[0], "pre-publish"))
        .pre_publish
    else if (std.mem.eql(u8, args[0], "verify-predecessor"))
        .verify_predecessor
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
    const manifest = values.manifest orelse return error.MissingOption;
    const summary_out = values.summary_out orelse return error.MissingOption;
    if (!std.mem.eql(u8, repo, repository_name)) return error.InvalidRepository;
    try validateTag(tag);
    try validateManifestAssetPath(manifest, tag[1..]);

    return switch (phase) {
        .pre_publish => blk: {
            const evidence = values.evidence orelse return error.MissingOption;
            const dmg = values.dmg orelse return error.MissingOption;
            const frozen_executable = values.frozen_executable orelse return error.MissingOption;
            try disjointPaths(&.{ manifest, evidence, dmg, frozen_executable, summary_out });
            break :blk .{ .pre_publish = .{
                .repo = repo,
                .tag = tag,
                .manifest = manifest,
                .evidence = evidence,
                .dmg = dmg,
                .frozen_executable = frozen_executable,
                .summary_out = summary_out,
            } };
        },
        .verify_predecessor => blk: {
            const work_dir = values.work_dir orelse return error.MissingOption;
            try disjointPaths(&.{ manifest, work_dir, summary_out });
            break :blk .{ .verify_predecessor = .{
                .repo = repo,
                .tag = tag,
                .manifest = manifest,
                .work_dir = work_dir,
                .summary_out = summary_out,
            } };
        },
    };
}

fn optionDestination(
    phase: Phase,
    values: *Values,
    option: []const u8,
) ?*?[]const u8 {
    if (std.mem.eql(u8, option, "--repo")) return &values.repo;
    if (std.mem.eql(u8, option, "--tag")) return &values.tag;
    if (std.mem.eql(u8, option, "--manifest")) return &values.manifest;
    if (std.mem.eql(u8, option, "--summary-out")) return &values.summary_out;
    return switch (phase) {
        .pre_publish => if (std.mem.eql(u8, option, "--evidence"))
            &values.evidence
        else if (std.mem.eql(u8, option, "--dmg"))
            &values.dmg
        else if (std.mem.eql(u8, option, "--frozen-executable"))
            &values.frozen_executable
        else
            null,
        .verify_predecessor => if (std.mem.eql(u8, option, "--work-dir"))
            &values.work_dir
        else
            null,
    };
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
            if (std.mem.eql(u8, path, other)) return error.PathAlias;
        }
    }
}
