//! Product composition for the two release-validator aggregate process phases.
//!
//! The only durable handoff between invocations is the aggregate pathname. Prepare owns and closes
//! every source and aggregate descriptor before returning; finalize reopens that pathname and closes
//! every verified descriptor before returning. Neither phase accepts or observes a GitHub token.

const std = @import("std");
const evidence = @import("release_evidence");
const files = @import("release_adapter_files");
const bootstrap_mod = @import("release_adapter_executable_bootstrap");
const attestation = @import("release_adapter_github_attestation");
const handoff = @import("release_adapter_candidate_aggregate_handoff");
const reopen = @import("release_adapter_candidate_aggregate_reopen");

pub const Storage = struct {
    sources: [handoff.role_count]files.PinnedReleaseFile = @splat(.{}),
    aggregate: handoff.DurableAggregate = .{},
    reopened: reopen.ReopenedAggregate = .{},
    output: [attestation.max_response_bytes]u8 = undefined,
};

pub fn prepare(
    allocator: std.mem.Allocator,
    bootstrap: *bootstrap_mod.Bootstrap,
    storage: *Storage,
) !void {
    const view = bootstrap.value() orelse return error.InvalidBootstrap;
    const command = switch (view.command) {
        .prepare_candidate_aggregate => |value| value,
        else => return error.InvalidCommand,
    };
    if (storage.aggregate.owner != null or storage.reopened.owner != null) return error.InvalidOwner;
    for (&storage.sources) |*source| if (source.owner != null) return error.InvalidOwner;

    const paths = [_][]const u8{
        command.evidence,
        command.candidate_dmg_bundle,
        command.candidate_frozen_bundle,
        command.evidence_bundle,
        command.manifest_bundle,
    };
    var path_storage: [handoff.role_count][std.fs.max_path_bytes:0]u8 = @splat(@splat(0));
    var root_storage: [handoff.role_count][std.fs.max_path_bytes:0]u8 = @splat(@splat(0));
    var destination_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    var source_values: [handoff.role_count]handoff.Source = undefined;
    var pinned: usize = 0;
    defer {
        for (storage.sources[0..pinned]) |*source| source.deinit() catch {};
    }
    for (paths, 0..) |path, index| {
        const path_z = try copyPathZ(&path_storage[index], path);
        const root = std.fs.path.dirname(path) orelse return error.InvalidPath;
        const root_z = try copyPathZ(&root_storage[index], root);
        const cap: u64 = if (index == 0) evidence.max_evidence_bytes else handoff.max_attestation_bundle_bytes;
        try files.pinReleaseFileObserved(&storage.sources[index], path_z, false, cap);
        pinned += 1;
        source_values[index] = .{ .file = &storage.sources[index], .root = root_z, .path = path_z };
    }
    const destination = try copyPathZ(&destination_storage, command.aggregate);
    try handoff.promote(allocator, .{
        .evidence = source_values[0],
        .candidate_dmg_bundle = source_values[1],
        .candidate_frozen_bundle = source_values[2],
        .evidence_bundle = source_values[3],
        .manifest_bundle = source_values[4],
    }, destination, &storage.aggregate);
    try storage.aggregate.closeRetaining();
}

pub fn finalize(
    io: std.Io,
    allocator: std.mem.Allocator,
    bootstrap: *bootstrap_mod.Bootstrap,
    budget_ns: i128,
    storage: *Storage,
) !void {
    const view = bootstrap.value() orelse return error.InvalidBootstrap;
    const command = switch (view.command) {
        .finalize_candidate_aggregate => |value| value,
        else => return error.InvalidCommand,
    };
    if (storage.aggregate.owner != null or storage.reopened.owner != null) return error.InvalidOwner;
    for (&storage.sources) |*source| if (source.owner != null) return error.InvalidOwner;

    var paths: [4][std.fs.max_path_bytes:0]u8 = @splat(@splat(0));
    const directory = try copyPathZ(&paths[0], command.aggregate);
    const dmg = try copyPathZ(&paths[1], command.dmg);
    const frozen = try copyPathZ(&paths[2], command.frozen_executable);
    const manifest = try copyPathZ(&paths[3], command.manifest);
    try reopen.openAndVerify(io, allocator, view.context, .{
        .directory = directory,
        .dmg = dmg,
        .frozen_executable = frozen,
        .manifest = manifest,
    }, .{
        .path = view.github_cli,
        .pinned = &bootstrap.cli,
    }, &storage.output, budget_ns, &storage.reopened);
    try storage.reopened.close();
}

fn copyPathZ(storage: *[std.fs.max_path_bytes:0]u8, value: []const u8) ![:0]const u8 {
    if (value.len == 0 or value.len >= storage.len) return error.InvalidPath;
    @memset(storage, 0);
    @memcpy(storage[0..value.len], value);
    return storage[0..value.len :0];
}
