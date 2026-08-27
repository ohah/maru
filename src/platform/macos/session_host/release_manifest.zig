//! Canonical release provenance manifest for persistent session-host upgrades.
//!
//! This module deliberately owns both syntax and intrinsic policy. Release tooling may supply
//! observed GitHub, signing, and artifact facts later, but it must not grow a second JSON parser.

const std = @import("std");

pub const max_manifest_bytes: usize = 64 * 1024;
pub const max_evidence_bytes: usize = 1024 * 1024;
pub const max_scalar_string_bytes: usize = 4 * 1024;
pub const max_asset_name_bytes: usize = 255;

pub const schema = "maru.session-host-release.v1";

pub const Role = enum { a, b };

pub const Repository = struct {
    id: u64,
    owner: []const u8,
    name: []const u8,
};

pub const Release = struct {
    id: u64,
    tag: []const u8,
    version: []const u8,
};

pub const Source = struct {
    commit: []const u8,
    tree: []const u8,
};

pub const Build = struct {
    workflow_ref: []const u8,
    run_id: u64,
    run_attempt: u64,
};

pub const Compatibility = struct {
    mrsh_major: u64,
    screen_codec: u64,
    handoff_reader_min: u64,
    handoff_reader_max: u64,
    app_host_abi: u64,
};

pub const Signing = struct {
    bundle_id: []const u8,
    bundle_short_version: []const u8,
    bundle_version: []const u8,
    team_id: []const u8,
    designated_requirement_sha256: []const u8,
    architectures: []const []const u8,
    notarization: []const u8,
    stapled: bool,
};

pub const AssetRole = enum {
    universal_dmg,
    frozen_product_executable,
    evidence_summary,
};

pub const Asset = struct {
    role: AssetRole,
    name: []const u8,
    sha256: []const u8,
    size: u64,
};

pub const Evidence = struct {
    test_uuid: []const u8,
    summary_name: []const u8,
    summary_sha256: []const u8,
    result: []const u8,
};

pub const Predecessor = struct {
    release_id: u64,
    tag: []const u8,
    commit: []const u8,
    manifest_sha256: []const u8,
};

pub const Manifest = struct {
    schema: []const u8,
    role: Role,
    repository: Repository,
    release: Release,
    source: Source,
    build: Build,
    compatibility: Compatibility,
    signing: Signing,
    assets: []const Asset,
    evidence: Evidence,
    predecessor: ?Predecessor = null,
};

pub const Parsed = struct {
    inner: std.json.Parsed(Manifest),

    pub fn deinit(self: *Parsed) void {
        self.inner.deinit();
    }

    pub fn value(self: *const Parsed) *const Manifest {
        return &self.inner.value;
    }
};

pub const ParseError = error{
    ManifestTooLarge,
    InvalidJson,
    NonCanonical,
    InvalidSchema,
    InvalidRolePolicy,
    InvalidRepository,
    InvalidRelease,
    InvalidSource,
    InvalidBuild,
    InvalidCompatibility,
    InvalidSigning,
    InvalidAsset,
    InvalidEvidence,
} || std.mem.Allocator.Error;

/// Parses only the writer's exact byte representation. This turns key order, whitespace, number
/// spelling, escaping, and the final LF into one closed format instead of several equivalent JSONs.
pub fn parseCanonical(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Parsed {
    if (bytes.len > max_manifest_bytes) return error.ManifestTooLarge;
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.NonCanonical;
    try preflight(bytes);

    var inner = std.json.parseFromSlice(Manifest, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer inner.deinit();
    try validateIntrinsic(inner.value);

    const canonical = try writeCanonical(allocator, inner.value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical)) return error.NonCanonical;
    return .{ .inner = inner };
}

pub fn writeCanonical(allocator: std.mem.Allocator, manifest: Manifest) ParseError![]u8 {
    try validateIntrinsic(manifest);
    var count_buffer: [1024]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&count_buffer);
    var counter: std.json.Stringify = .{ .writer = &discarding.writer, .options = .{} };
    writeValue(&counter, manifest) catch return error.OutOfMemory;
    discarding.writer.writeByte('\n') catch return error.OutOfMemory;
    if (discarding.fullCount() > max_manifest_bytes) return error.ManifestTooLarge;

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    writeValue(&json, manifest) catch return error.OutOfMemory;
    output.writer.writeByte('\n') catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn writeValue(json: *std.json.Stringify, manifest: Manifest) error{WriteFailed}!void {
    switch (manifest.role) {
        .a => try json.write(.{
            .schema = manifest.schema,
            .role = manifest.role,
            .repository = manifest.repository,
            .release = manifest.release,
            .source = manifest.source,
            .build = manifest.build,
            .compatibility = manifest.compatibility,
            .signing = manifest.signing,
            .assets = manifest.assets,
            .evidence = manifest.evidence,
        }),
        .b => try json.write(.{
            .schema = manifest.schema,
            .role = manifest.role,
            .repository = manifest.repository,
            .release = manifest.release,
            .source = manifest.source,
            .build = manifest.build,
            .compatibility = manifest.compatibility,
            .signing = manifest.signing,
            .assets = manifest.assets,
            .evidence = manifest.evidence,
            .predecessor = manifest.predecessor.?,
        }),
    }
}

pub fn validateIntrinsic(manifest: Manifest) ParseError!void {
    if (!std.mem.eql(u8, manifest.schema, schema)) return error.InvalidSchema;
    switch (manifest.role) {
        .a => if (manifest.predecessor != null) return error.InvalidRolePolicy,
        .b => if (manifest.predecessor == null) return error.InvalidRolePolicy,
    }
    try scalar(manifest.repository.owner);
    try scalar(manifest.repository.name);
    if (manifest.repository.id == 0 or
        !std.mem.eql(u8, manifest.repository.owner, "ohah") or
        !std.mem.eql(u8, manifest.repository.name, "maru")) return error.InvalidRepository;

    try scalar(manifest.release.tag);
    try scalar(manifest.release.version);
    if (manifest.release.id == 0 or manifest.release.version.len == 0 or
        manifest.release.tag.len != manifest.release.version.len + 1 or
        manifest.release.tag[0] != 'v' or
        !std.mem.eql(u8, manifest.release.tag[1..], manifest.release.version))
        return error.InvalidRelease;

    if (!lowerHex(manifest.source.commit, 40) or !lowerHex(manifest.source.tree, 40))
        return error.InvalidSource;
    try scalar(manifest.build.workflow_ref);
    if (manifest.build.workflow_ref.len == 0 or manifest.build.run_id == 0 or manifest.build.run_attempt == 0)
        return error.InvalidBuild;
    if (manifest.compatibility.mrsh_major == 0 or manifest.compatibility.screen_codec == 0 or
        manifest.compatibility.handoff_reader_min == 0 or
        manifest.compatibility.handoff_reader_min > manifest.compatibility.handoff_reader_max or
        manifest.compatibility.app_host_abi == 0) return error.InvalidCompatibility;

    try validateSigning(manifest.signing);
    if (!std.mem.eql(u8, manifest.signing.bundle_short_version, manifest.release.version))
        return error.InvalidSigning;
    try validateAssets(manifest.assets);
    try validateEvidence(manifest.evidence);
    for (manifest.assets) |asset| {
        if (asset.role == .evidence_summary and
            (!std.mem.eql(u8, asset.name, manifest.evidence.summary_name) or
                !std.mem.eql(u8, asset.sha256, manifest.evidence.summary_sha256) or
                asset.size > max_evidence_bytes)) return error.InvalidEvidence;
    }
    if (manifest.predecessor) |predecessor| {
        if (predecessor.release_id == 0 or predecessor.tag.len < 2 or predecessor.tag[0] != 'v' or
            !lowerHex(predecessor.commit, 40) or !lowerHex(predecessor.manifest_sha256, 64))
            return error.InvalidRolePolicy;
        try scalar(predecessor.tag);
    }
}

fn validateSigning(signing: Signing) ParseError!void {
    try scalar(signing.bundle_id);
    try scalar(signing.bundle_short_version);
    try scalar(signing.bundle_version);
    try scalar(signing.team_id);
    if (signing.bundle_id.len == 0 or signing.bundle_short_version.len == 0 or
        signing.bundle_version.len == 0 or signing.team_id.len == 0 or
        !lowerHex(signing.designated_requirement_sha256, 64) or
        !std.mem.eql(u8, signing.notarization, "accepted") or !signing.stapled or
        signing.architectures.len == 0) return error.InvalidSigning;
    var previous: ?[]const u8 = null;
    for (signing.architectures) |architecture| {
        try scalar(architecture);
        if (architecture.len == 0) return error.InvalidSigning;
        if (previous) |value| if (std.mem.order(u8, value, architecture) != .lt)
            return error.InvalidSigning;
        previous = architecture;
    }
}

fn validateAssets(assets: []const Asset) ParseError!void {
    var counts = [_]u8{0} ** @typeInfo(AssetRole).@"enum".fields.len;
    var total: u64 = 0;
    for (assets, 0..) |asset, asset_index| {
        const index = @intFromEnum(asset.role);
        counts[index] = std.math.add(u8, counts[index], 1) catch return error.InvalidAsset;
        if (asset.size == 0 or !lowerHex(asset.sha256, 64) or !basename(asset.name))
            return error.InvalidAsset;
        total = std.math.add(u64, total, asset.size) catch return error.InvalidAsset;
        for (assets[0..asset_index]) |previous| {
            if (std.mem.eql(u8, previous.name, asset.name)) return error.InvalidAsset;
        }
    }
    if (total == 0) return error.InvalidAsset;
    for (counts) |count| if (count != 1) return error.InvalidAsset;
}

fn validateEvidence(evidence: Evidence) ParseError!void {
    try scalar(evidence.test_uuid);
    if (evidence.test_uuid.len == 0 or !basename(evidence.summary_name) or
        !lowerHex(evidence.summary_sha256, 64) or
        !std.mem.eql(u8, evidence.result, "passed")) return error.InvalidEvidence;
}

fn preflight(bytes: []const u8) ParseError!void {
    // Scanner unescaping uses only this fixed scratch. Attacker-controlled strings therefore hit
    // the scalar cap before the caller's arena is allowed to allocate the typed object graph.
    var scratch: [max_manifest_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), bytes);
    defer scanner.deinit();
    while (true) {
        const token = scanner.nextAllocMax(
            fixed.allocator(),
            .alloc_if_needed,
            max_scalar_string_bytes,
        ) catch return error.InvalidJson;
        if (token == .end_of_document) return;
    }
}

fn scalar(value: []const u8) ParseError!void {
    if (value.len > max_scalar_string_bytes) return error.InvalidJson;
}

fn basename(value: []const u8) bool {
    return value.len != 0 and value.len <= max_asset_name_bytes and
        !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..") and
        std.fs.path.basename(value).len == value.len and
        std.mem.indexOfScalar(u8, value, '\\') == null and
        std.mem.indexOfScalar(u8, value, 0) == null;
}

fn lowerHex(value: []const u8, exact_len: usize) bool {
    if (value.len != exact_len) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn validManifest(role: Role) Manifest {
    const assets = struct {
        const value = [_]Asset{
            .{ .role = .universal_dmg, .name = "Maru.dmg", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .size = 10 },
            .{ .role = .frozen_product_executable, .name = "maru", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .size = 20 },
            .{ .role = .evidence_summary, .name = "summary.json", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .size = 30 },
        };
    }.value;
    const architectures = struct {
        const value = [_][]const u8{ "arm64", "x86_64" };
    }.value;
    return .{
        .schema = schema,
        .role = role,
        .repository = .{ .id = 1, .owner = "ohah", .name = "maru" },
        .release = .{ .id = 2, .tag = "v0.1.0", .version = "0.1.0" },
        .source = .{ .commit = "1111111111111111111111111111111111111111", .tree = "2222222222222222222222222222222222222222" },
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v0.1.0", .run_id = 3, .run_attempt = 1 },
        .compatibility = .{ .mrsh_major = 2, .screen_codec = 2, .handoff_reader_min = 1, .handoff_reader_max = 2, .app_host_abi = 91 },
        .signing = .{
            .bundle_id = "dev.maru.app",
            .bundle_short_version = "0.1.0",
            .bundle_version = "1",
            .team_id = "ABCDE12345",
            .designated_requirement_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            .architectures = &architectures,
            .notarization = "accepted",
            .stapled = true,
        },
        .assets = &assets,
        .evidence = .{
            .test_uuid = "00000000-0000-4000-8000-000000000000",
            .summary_name = "summary.json",
            .summary_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            .result = "passed",
        },
        .predecessor = if (role == .b) .{
            .release_id = 1,
            .tag = "v0.0.9",
            .commit = "3333333333333333333333333333333333333333",
            .manifest_sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        } else null,
    };
}

test "release manifest canonical A and B round trip" {
    for ([_]Role{ .a, .b }) |role| {
        const bytes = try writeCanonical(std.testing.allocator, validManifest(role));
        defer std.testing.allocator.free(bytes);
        var parsed = try parseCanonical(std.testing.allocator, bytes);
        defer parsed.deinit();
        try std.testing.expectEqual(role, parsed.value().role);
    }
}

test "release manifest rejects noncanonical duplicate unknown and trailing input" {
    const bytes = try writeCanonical(std.testing.allocator, validManifest(.a));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.NonCanonical, parseCanonical(std.testing.allocator, bytes[0 .. bytes.len - 1]));
    const duplicate = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "{\"schema\":", "{\"schema\":\"maru.session-host-release.v1\",\"schema\":");
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(error.InvalidJson, parseCanonical(std.testing.allocator, duplicate));
    const unknown = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "{\"schema\":", "{\"unknown\":1,\"schema\":");
    defer std.testing.allocator.free(unknown);
    try std.testing.expectError(error.InvalidJson, parseCanonical(std.testing.allocator, unknown));
    const trailing = try std.mem.concat(std.testing.allocator, u8, &.{ bytes[0 .. bytes.len - 1], "{}\n" });
    defer std.testing.allocator.free(trailing);
    try std.testing.expectError(error.InvalidJson, parseCanonical(std.testing.allocator, trailing));
}

test "release manifest intrinsic policy fails closed" {
    var manifest = validManifest(.a);
    manifest.predecessor = validManifest(.b).predecessor;
    try std.testing.expectError(error.InvalidRolePolicy, validateIntrinsic(manifest));
    manifest = validManifest(.a);
    manifest.release.tag = "v9.9.9";
    try std.testing.expectError(error.InvalidRelease, validateIntrinsic(manifest));
    manifest = validManifest(.a);
    manifest.source.commit = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    try std.testing.expectError(error.InvalidSource, validateIntrinsic(manifest));
    manifest = validManifest(.a);
    manifest.compatibility.handoff_reader_min = 3;
    try std.testing.expectError(error.InvalidCompatibility, validateIntrinsic(manifest));
}

test "release manifest asset roles names hashes and signing arrays are closed" {
    var manifest = validManifest(.a);
    var assets: [3]Asset = undefined;
    @memcpy(&assets, manifest.assets);
    assets[2].role = .universal_dmg;
    manifest.assets = &assets;
    try std.testing.expectError(error.InvalidAsset, validateIntrinsic(manifest));
    manifest = validManifest(.a);
    @memcpy(&assets, manifest.assets);
    assets[0].name = "../Maru.dmg";
    manifest.assets = &assets;
    try std.testing.expectError(error.InvalidAsset, validateIntrinsic(manifest));
    manifest = validManifest(.a);
    var architectures: [2][]const u8 = undefined;
    @memcpy(&architectures, manifest.signing.architectures);
    std.mem.swap([]const u8, &architectures[0], &architectures[1]);
    manifest.signing.architectures = &architectures;
    try std.testing.expectError(error.InvalidSigning, validateIntrinsic(manifest));
}

fn parseAllocationFailureCase(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parsed = try parseCanonical(allocator, bytes);
    defer parsed.deinit();
}

test "release manifest caps strings binds evidence and unwinds every allocation failure" {
    var manifest = validManifest(.a);
    var assets: [3]Asset = undefined;
    @memcpy(&assets, manifest.assets);
    assets[1].name = assets[0].name;
    manifest.assets = &assets;
    try std.testing.expectError(error.InvalidAsset, validateIntrinsic(manifest));

    manifest = validManifest(.a);
    manifest.evidence.summary_sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    try std.testing.expectError(error.InvalidEvidence, validateIntrinsic(manifest));

    var architecture_storage: [16][max_scalar_string_bytes]u8 = undefined;
    var many_architectures: [architecture_storage.len][]const u8 = undefined;
    for (&architecture_storage, 0..) |*storage, index| {
        @memset(storage, @as(u8, 'a') + @as(u8, @intCast(index)));
        many_architectures[index] = storage;
    }
    manifest = validManifest(.a);
    manifest.signing.architectures = &many_architectures;
    var fail_first = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.ManifestTooLarge,
        writeCanonical(fail_first.allocator(), manifest),
    );
    try std.testing.expectEqual(@as(usize, 0), fail_first.alloc_index);

    const bytes = try writeCanonical(std.testing.allocator, validManifest(.b));
    defer std.testing.allocator.free(bytes);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseAllocationFailureCase,
        .{bytes},
    );
}
