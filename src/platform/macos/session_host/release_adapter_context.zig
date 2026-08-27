//! Closed GitHub Actions identity context for the session-host release adapter.
//!
//! The executable leaf will fetch these named values from its own environment. Keeping parsing
//! here OS-neutral makes the trust decision deterministic and prevents workflow shell code from
//! separately interpreting repository, ref, source, or build identity.

const std = @import("std");
const release_manifest = @import("release_manifest");

pub const max_value_bytes: usize = release_manifest.max_scalar_string_bytes;

pub const Entry = struct {
    name: []const u8,
    value: []const u8,
};

pub const Context = struct {
    repository: release_manifest.Repository,
    tag: []const u8,
    source_commit: []const u8,
    build: release_manifest.Build,
    protected_tag: bool,
};

pub const Error = error{
    MissingKey,
    DuplicateKey,
    UnknownKey,
    EmptyValue,
    ValueTooLong,
    InvalidScalar,
    InvalidRepository,
    InvalidRef,
    InvalidSource,
    InvalidWorkflow,
    InvalidBuild,
    UntrustedTrigger,
    UnprotectedRef,
    ManifestMismatch,
};

const Key = enum {
    repository,
    repository_id,
    ref,
    ref_type,
    ref_name,
    sha,
    workflow_ref,
    run_id,
    run_attempt,
    event_name,
    ref_protected,
};

const key_count = @typeInfo(Key).@"enum".fields.len;

pub fn parse(entries: []const Entry) Error!Context {
    if (entries.len < key_count) return error.MissingKey;
    if (entries.len > key_count) return error.UnknownKey;

    var values: [key_count]?[]const u8 = @splat(null);
    for (entries) |entry| {
        const key = keyForName(entry.name) orelse return error.UnknownKey;
        const slot = &values[@intFromEnum(key)];
        if (slot.* != null) return error.DuplicateKey;
        try validateScalar(entry.value);
        slot.* = entry.value;
    }
    for (values) |value| if (value == null) return error.MissingKey;

    const repository = values[@intFromEnum(Key.repository)].?;
    if (!std.mem.eql(u8, repository, "ohah/maru")) return error.InvalidRepository;
    const repository_id = parseCanonicalU64(
        values[@intFromEnum(Key.repository_id)].?,
        error.InvalidRepository,
    ) catch return error.InvalidRepository;

    const tag = values[@intFromEnum(Key.ref_name)].?;
    const ref = values[@intFromEnum(Key.ref)].?;
    if (!std.mem.eql(u8, values[@intFromEnum(Key.ref_type)].?, "tag") or
        !canonicalTag(tag) or
        ref.len != "refs/tags/".len + tag.len or
        !std.mem.startsWith(u8, ref, "refs/tags/") or
        !std.mem.eql(u8, ref["refs/tags/".len..], tag)) return error.InvalidRef;

    if (!std.mem.eql(u8, values[@intFromEnum(Key.event_name)].?, "push"))
        return error.UntrustedTrigger;
    if (!std.mem.eql(u8, values[@intFromEnum(Key.ref_protected)].?, "true"))
        return error.UnprotectedRef;

    const source_commit = values[@intFromEnum(Key.sha)].?;
    if (!lowerHex(source_commit, 40)) return error.InvalidSource;

    const workflow_ref = values[@intFromEnum(Key.workflow_ref)].?;
    var expected_workflow: [max_value_bytes]u8 = undefined;
    const expected = std.fmt.bufPrint(
        &expected_workflow,
        "ohah/maru/.github/workflows/release.yml@refs/tags/{s}",
        .{tag},
    ) catch return error.InvalidWorkflow;
    if (!std.mem.eql(u8, workflow_ref, expected)) return error.InvalidWorkflow;

    const run_id = parseCanonicalU64(
        values[@intFromEnum(Key.run_id)].?,
        error.InvalidBuild,
    ) catch return error.InvalidBuild;
    const run_attempt = parseCanonicalU64(
        values[@intFromEnum(Key.run_attempt)].?,
        error.InvalidBuild,
    ) catch return error.InvalidBuild;

    return .{
        .repository = .{ .id = repository_id, .owner = "ohah", .name = "maru" },
        .tag = tag,
        .source_commit = source_commit,
        .build = .{ .workflow_ref = workflow_ref, .run_id = run_id, .run_attempt = run_attempt },
        .protected_tag = true,
    };
}

pub fn bindManifest(context: Context, manifest: release_manifest.Manifest) Error!void {
    if (manifest.repository.id != context.repository.id or
        !std.mem.eql(u8, manifest.repository.owner, context.repository.owner) or
        !std.mem.eql(u8, manifest.repository.name, context.repository.name) or
        !std.mem.eql(u8, manifest.release.tag, context.tag) or
        !std.mem.eql(u8, manifest.source.commit, context.source_commit) or
        manifest.build.run_id != context.build.run_id or
        manifest.build.run_attempt != context.build.run_attempt or
        !std.mem.eql(u8, manifest.build.workflow_ref, context.build.workflow_ref))
        return error.ManifestMismatch;
}

fn keyForName(name: []const u8) ?Key {
    const names = [_][]const u8{
        "GITHUB_REPOSITORY",
        "GITHUB_REPOSITORY_ID",
        "GITHUB_REF",
        "GITHUB_REF_TYPE",
        "GITHUB_REF_NAME",
        "GITHUB_SHA",
        "GITHUB_WORKFLOW_REF",
        "GITHUB_RUN_ID",
        "GITHUB_RUN_ATTEMPT",
        "GITHUB_EVENT_NAME",
        "GITHUB_REF_PROTECTED",
    };
    for (names, 0..) |candidate, index| {
        if (std.mem.eql(u8, name, candidate)) return @enumFromInt(index);
    }
    return null;
}

fn validateScalar(value: []const u8) Error!void {
    if (value.len == 0) return error.EmptyValue;
    if (value.len > max_value_bytes) return error.ValueTooLong;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidScalar;
    }
}

fn parseCanonicalU64(value: []const u8, comptime invalid: Error) Error!u64 {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return invalid;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return invalid;
    const parsed = std.fmt.parseInt(u64, value, 10) catch return invalid;
    if (parsed == 0) return invalid;
    return parsed;
}

fn lowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn canonicalTag(tag: []const u8) bool {
    if (tag.len < 2 or tag[0] != 'v') return false;
    const version = tag[1..];
    var components: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= version.len) : (index += 1) {
        if (index != version.len and version[index] != '.') continue;
        const component = version[start..index];
        if (component.len == 0 or (component.len > 1 and component[0] == '0')) return false;
        for (component) |byte| if (!std.ascii.isDigit(byte)) return false;
        components += 1;
        start = index + 1;
    }
    return components == 3;
}
