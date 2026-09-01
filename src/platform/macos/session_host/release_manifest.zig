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

/// Returns whether caller-controlled mutable storage overlaps the manifest value or any backing
/// allocation referenced by it. The schema owns this exhaustive inventory so compositions cannot
/// drift when a field is added.
pub fn aliasesStorage(value: *const Manifest, candidate: []const u8) bool {
    if (rangesOverlap(candidate, std.mem.asBytes(value))) return true;
    inline for (.{
        value.schema,
        value.repository.owner,
        value.repository.name,
        value.release.tag,
        value.release.version,
        value.source.commit,
        value.source.tree,
        value.build.workflow_ref,
        value.signing.bundle_id,
        value.signing.bundle_short_version,
        value.signing.bundle_version,
        value.signing.team_id,
        value.signing.designated_requirement_sha256,
        value.signing.notarization,
        value.evidence.test_uuid,
        value.evidence.summary_name,
        value.evidence.summary_sha256,
        value.evidence.result,
    }) |bytes| if (rangesOverlap(candidate, bytes)) return true;
    if (rangesOverlap(candidate, std.mem.sliceAsBytes(value.signing.architectures)) or
        rangesOverlap(candidate, std.mem.sliceAsBytes(value.assets))) return true;
    for (value.signing.architectures) |architecture|
        if (rangesOverlap(candidate, architecture)) return true;
    for (value.assets) |asset|
        if (rangesOverlap(candidate, asset.name) or rangesOverlap(candidate, asset.sha256)) return true;
    if (value.predecessor) |predecessor| {
        inline for (.{ predecessor.tag, predecessor.commit, predecessor.manifest_sha256 }) |bytes|
            if (rangesOverlap(candidate, bytes)) return true;
    }
    return false;
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

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

pub const Attestation = struct {
    verified: bool,
    repository: Repository,
    source_commit: []const u8,
    workflow_ref: []const u8,
    run_id: u64,
    run_attempt: u64,
    subject_name: []const u8,
    subject_sha256: []const u8,
};

pub const ReleaseAttestation = struct {
    verified: bool,
    repository: Repository,
    release_id: u64,
    release_tag: []const u8,
    source_commit: []const u8,
    manifest_sha256: []const u8,
    assets: []const Asset,
};

pub const AssetObservation = struct {
    asset: Asset,
    regular_file: bool,
    no_follow: bool,
    attestation: Attestation,
};

pub const EvidenceObservation = struct {
    summary_sha256: []const u8,
    test_uuid: []const u8,
    result: []const u8,
    candidate_executable_sha256: []const u8,
};

pub const PredecessorObservation = struct {
    manifest_bytes: []const u8,
    manifest_sha256: []const u8,
    published: bool,
    immutable: bool,
    manifest_asset_count: u64,
    release_attestation: ReleaseAttestation,
};

pub const Observation = struct {
    repository: Repository,
    release: Release,
    source: Source,
    build: Build,
    /// Compatibility and signing must come from this exact frozen executable, not another build.
    executable_sha256: []const u8,
    compatibility: Compatibility,
    executable_compatibility_verified: bool,
    signing: Signing,
    strict_signature_verified: bool,
    notarization_verified: bool,
    staple_verified: bool,
    assets: []const AssetObservation,
    dmg_product_executable_sha256: []const u8,
    dmg_extraction_no_follow: bool,
    evidence: EvidenceObservation,
    evidence_schema_verified: bool,
    manifest_sha256: []const u8,
    manifest_attestation: Attestation,
    predecessor: ?PredecessorObservation = null,
};

pub const PublicationStep = enum {
    candidate_attested,
    draft_created,
    evidence_verified,
    manifest_created,
    manifest_attested,
    assets_attached,
    draft_redownload_validated,
    published,
    release_attestation_verified,
};

/// Facts observed by the release adapter. Keeping the ordered transcript here prevents shell and
/// workflow implementations from each inventing a slightly different publication policy.
pub const PublicationObservation = struct {
    repository: Repository,
    source_commit: []const u8,
    build: Build,
    manifest_sha256: []const u8,
    trusted_tag_push: bool,
    protected_tag: bool,
    protected_environment: bool,
    fork_pr: bool,
    pull_request_target: bool,
    arbitrary_ref: bool,
    third_party_actions_pinned: bool,
    clobber_used: bool,
    predecessor_published: bool,
    predecessor_immutable: bool,
    manifest_asset_count: u64,
    attached_assets: []const Asset,
    release_attested_assets: []const Asset,
    post_publish_mutation: bool,
    steps: []const PublicationStep,
};

pub const EvidenceError = error{
    RepositoryMismatch,
    ReleaseMismatch,
    SourceMismatch,
    BuildMismatch,
    CompatibilityMismatch,
    SigningMismatch,
    AssetMismatch,
    DmgExecutableMismatch,
    EvidenceMismatch,
    AttestationMismatch,
    PredecessorMismatch,
    ManifestDigestMismatch,
    PublicationMismatch,
};

const required_publication_steps = [_]PublicationStep{
    .candidate_attested,
    .draft_created,
    .evidence_verified,
    .manifest_created,
    .manifest_attested,
    .assets_attached,
    .draft_redownload_validated,
    .published,
    .release_attestation_verified,
};

fn validatePublication(
    manifest: Manifest,
    manifest_sha256: []const u8,
    observed: PublicationObservation,
) EvidenceError!void {
    if (!equalRepository(manifest.repository, observed.repository) or
        !std.mem.eql(u8, manifest.source.commit, observed.source_commit) or
        !equalBuild(manifest.build, observed.build) or
        !std.mem.eql(u8, manifest_sha256, observed.manifest_sha256))
        return error.PublicationMismatch;
    if (!observed.trusted_tag_push or !observed.protected_tag or
        !observed.protected_environment or observed.fork_pr or
        observed.pull_request_target or observed.arbitrary_ref or
        !observed.third_party_actions_pinned or observed.clobber_used or
        observed.post_publish_mutation or observed.manifest_asset_count != 1)
        return error.PublicationMismatch;
    switch (manifest.role) {
        .a => if (observed.predecessor_published or observed.predecessor_immutable)
            return error.PublicationMismatch,
        .b => if (!observed.predecessor_published or !observed.predecessor_immutable)
            return error.PublicationMismatch,
    }
    if (!equalAssetSet(manifest.assets, observed.attached_assets) or
        !equalAssetSet(manifest.assets, observed.release_attested_assets) or
        !std.mem.eql(PublicationStep, &required_publication_steps, observed.steps))
        return error.PublicationMismatch;
}

/// Final release audit entrypoint: content evidence and publication ordering must describe the
/// same canonical manifest bytes. Callers cannot accidentally run one half of the policy only.
pub fn parseAndValidatePublication(
    allocator: std.mem.Allocator,
    canonical_bytes: []const u8,
    evidence: Observation,
    publication: PublicationObservation,
) (ParseError || EvidenceError)!Parsed {
    var parsed = try parseAndValidateObservation(allocator, canonical_bytes, evidence);
    errdefer parsed.deinit();
    try validatePublication(parsed.value().*, evidence.manifest_sha256, publication);
    return parsed;
}

/// Parses only the writer's exact byte representation. This turns key order, whitespace, number
/// spelling, escaping, and the final LF into one closed format instead of several equivalent JSONs.
pub fn parseCanonical(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Parsed {
    if (bytes.len > max_manifest_bytes) return error.ManifestTooLarge;
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.NonCanonical;
    try preflight(bytes);

    var inner = std.json.parseFromSlice(Manifest, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
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

/// Cross-checks already observed external facts. The release adapter owns filesystem and service
/// calls, but this function remains the only place allowed to decide whether those typed facts are
/// sufficient. No pathname, command output, or JSON syntax reaches this policy boundary.
pub fn parseAndValidateObservation(
    allocator: std.mem.Allocator,
    canonical_bytes: []const u8,
    observed: Observation,
) (ParseError || EvidenceError)!Parsed {
    var parsed = try parseCanonical(allocator, canonical_bytes);
    errdefer parsed.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_bytes, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &digest_hex, observed.manifest_sha256))
        return error.ManifestDigestMismatch;

    var predecessor_parsed: ?Parsed = null;
    defer if (predecessor_parsed) |*value| value.deinit();
    if (observed.predecessor) |predecessor| {
        predecessor_parsed = try parseCanonical(allocator, predecessor.manifest_bytes);
        var predecessor_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(predecessor.manifest_bytes, &predecessor_digest, .{});
        const predecessor_digest_hex = std.fmt.bytesToHex(predecessor_digest, .lower);
        if (!std.mem.eql(u8, &predecessor_digest_hex, predecessor.manifest_sha256))
            return error.PredecessorMismatch;
    }
    try validateObservation(
        parsed.value().*,
        observed,
        if (predecessor_parsed) |*value| value.value().* else null,
    );
    return parsed;
}

fn validateObservation(
    manifest: Manifest,
    observed: Observation,
    predecessor_manifest: ?Manifest,
) EvidenceError!void {
    if (!equalRepository(manifest.repository, observed.repository))
        return error.RepositoryMismatch;
    if (!equalRelease(manifest.release, observed.release)) return error.ReleaseMismatch;
    if (!equalSource(manifest.source, observed.source)) return error.SourceMismatch;
    if (!equalBuild(manifest.build, observed.build)) return error.BuildMismatch;
    if (observed.assets.len != manifest.assets.len) return error.AssetMismatch;
    var frozen_sha: ?[]const u8 = null;
    for (manifest.assets) |expected| {
        const actual = observationForRole(observed.assets, expected.role) orelse
            return error.AssetMismatch;
        if (!equalAsset(expected, actual.asset) or !actual.regular_file or !actual.no_follow)
            return error.AssetMismatch;
        try validateAttestation(manifest, actual.attestation, expected.name, expected.sha256);
        if (expected.role == .frozen_product_executable) frozen_sha = expected.sha256;
    }
    const executable_sha = frozen_sha orelse return error.AssetMismatch;
    if (!std.mem.eql(u8, executable_sha, observed.executable_sha256) or
        !observed.executable_compatibility_verified or
        !equalCompatibility(manifest.compatibility, observed.compatibility))
        return error.CompatibilityMismatch;
    if (!observed.strict_signature_verified or !observed.notarization_verified or
        !observed.staple_verified or !equalSigning(manifest.signing, observed.signing))
        return error.SigningMismatch;
    if (!observed.dmg_extraction_no_follow or
        !std.mem.eql(u8, executable_sha, observed.dmg_product_executable_sha256))
        return error.DmgExecutableMismatch;

    if (!observed.evidence_schema_verified or
        !std.mem.eql(u8, manifest.evidence.summary_sha256, observed.evidence.summary_sha256) or
        !std.mem.eql(u8, manifest.evidence.test_uuid, observed.evidence.test_uuid) or
        !std.mem.eql(u8, manifest.evidence.result, observed.evidence.result) or
        !std.mem.eql(u8, executable_sha, observed.evidence.candidate_executable_sha256))
        return error.EvidenceMismatch;
    if (!lowerHex(observed.manifest_sha256, 64)) return error.AttestationMismatch;
    try validateAttestation(manifest, observed.manifest_attestation, null, observed.manifest_sha256);

    switch (manifest.role) {
        .a => if (observed.predecessor != null) return error.PredecessorMismatch,
        .b => {
            const expected = manifest.predecessor orelse return error.PredecessorMismatch;
            const actual = observed.predecessor orelse return error.PredecessorMismatch;
            const predecessor = predecessor_manifest orelse return error.PredecessorMismatch;
            if (!actual.published or !actual.immutable or actual.manifest_asset_count != 1 or
                predecessor.role != .a or predecessor.predecessor != null or
                expected.release_id != predecessor.release.id or
                !std.mem.eql(u8, expected.tag, predecessor.release.tag) or
                !std.mem.eql(u8, expected.commit, predecessor.source.commit) or
                !std.mem.eql(u8, expected.manifest_sha256, actual.manifest_sha256))
                return error.PredecessorMismatch;
            if (!actual.release_attestation.verified or
                !equalRepository(predecessor.repository, actual.release_attestation.repository) or
                predecessor.release.id != actual.release_attestation.release_id or
                !std.mem.eql(u8, predecessor.release.tag, actual.release_attestation.release_tag) or
                !std.mem.eql(u8, predecessor.source.commit, actual.release_attestation.source_commit) or
                !std.mem.eql(u8, actual.manifest_sha256, actual.release_attestation.manifest_sha256) or
                !equalAssetSet(predecessor.assets, actual.release_attestation.assets))
                return error.PredecessorMismatch;
        },
    }
}

fn validateAttestation(
    manifest: Manifest,
    attestation: Attestation,
    subject_name: ?[]const u8,
    subject_sha256: []const u8,
) EvidenceError!void {
    if (!attestation.verified or
        !equalRepository(manifest.repository, attestation.repository) or
        !std.mem.eql(u8, manifest.source.commit, attestation.source_commit) or
        !std.mem.eql(u8, manifest.build.workflow_ref, attestation.workflow_ref) or
        manifest.build.run_id != attestation.run_id or
        manifest.build.run_attempt != attestation.run_attempt or
        !basename(attestation.subject_name) or
        (subject_name != null and !std.mem.eql(u8, subject_name.?, attestation.subject_name)) or
        !std.mem.eql(u8, subject_sha256, attestation.subject_sha256))
        return error.AttestationMismatch;
}

fn observationForRole(observed: []const AssetObservation, role: AssetRole) ?AssetObservation {
    var result: ?AssetObservation = null;
    for (observed) |candidate| {
        if (candidate.asset.role != role) continue;
        if (result != null) return null;
        result = candidate;
    }
    return result;
}

fn equalRepository(a: Repository, b: Repository) bool {
    return a.id == b.id and std.mem.eql(u8, a.owner, b.owner) and std.mem.eql(u8, a.name, b.name);
}

fn equalRelease(a: Release, b: Release) bool {
    return a.id == b.id and std.mem.eql(u8, a.tag, b.tag) and std.mem.eql(u8, a.version, b.version);
}

fn equalSource(a: Source, b: Source) bool {
    return std.mem.eql(u8, a.commit, b.commit) and std.mem.eql(u8, a.tree, b.tree);
}

fn equalBuild(a: Build, b: Build) bool {
    return a.run_id == b.run_id and a.run_attempt == b.run_attempt and
        std.mem.eql(u8, a.workflow_ref, b.workflow_ref);
}

pub fn equalCompatibility(a: Compatibility, b: Compatibility) bool {
    return a.mrsh_major == b.mrsh_major and a.screen_codec == b.screen_codec and
        a.handoff_reader_min == b.handoff_reader_min and
        a.handoff_reader_max == b.handoff_reader_max and a.app_host_abi == b.app_host_abi;
}

pub fn equalSigning(a: Signing, b: Signing) bool {
    if (!std.mem.eql(u8, a.bundle_id, b.bundle_id) or
        !std.mem.eql(u8, a.bundle_short_version, b.bundle_short_version) or
        !std.mem.eql(u8, a.bundle_version, b.bundle_version) or
        !std.mem.eql(u8, a.team_id, b.team_id) or
        !std.mem.eql(u8, a.designated_requirement_sha256, b.designated_requirement_sha256) or
        !std.mem.eql(u8, a.notarization, b.notarization) or a.stapled != b.stapled or
        a.architectures.len != b.architectures.len) return false;
    for (a.architectures, b.architectures) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn equalAsset(a: Asset, b: Asset) bool {
    return a.role == b.role and a.size == b.size and std.mem.eql(u8, a.name, b.name) and
        std.mem.eql(u8, a.sha256, b.sha256);
}

fn equalAssetSet(expected: []const Asset, actual: []const Asset) bool {
    if (expected.len != actual.len) return false;
    for (expected) |asset| {
        var matches: usize = 0;
        for (actual) |candidate| {
            if (equalAsset(asset, candidate)) matches += 1;
        }
        if (matches != 1) return false;
    }
    return true;
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

fn validAttestation(manifest: Manifest, subject_name: []const u8, subject_sha256: []const u8) Attestation {
    return .{
        .verified = true,
        .repository = manifest.repository,
        .source_commit = manifest.source.commit,
        .workflow_ref = manifest.build.workflow_ref,
        .run_id = manifest.build.run_id,
        .run_attempt = manifest.build.run_attempt,
        .subject_name = subject_name,
        .subject_sha256 = subject_sha256,
    };
}

fn validReleaseAttestation(manifest: Manifest, manifest_sha256: []const u8) ReleaseAttestation {
    return .{
        .verified = true,
        .repository = manifest.repository,
        .release_id = manifest.release.id,
        .release_tag = manifest.release.tag,
        .source_commit = manifest.source.commit,
        .manifest_sha256 = manifest_sha256,
        .assets = manifest.assets,
    };
}

fn fillAssetObservations(manifest: Manifest, out: *[3]AssetObservation) void {
    for (manifest.assets, 0..) |asset, index| {
        out[index] = .{
            .asset = asset,
            .regular_file = true,
            .no_follow = true,
            .attestation = validAttestation(manifest, asset.name, asset.sha256),
        };
    }
}

fn validObservation(
    manifest: *const Manifest,
    assets: []const AssetObservation,
    predecessor: ?PredecessorObservation,
) Observation {
    const executable = for (manifest.assets) |asset| {
        if (asset.role == .frozen_product_executable) break asset.sha256;
    } else unreachable;
    const manifest_sha = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    return .{
        .repository = manifest.repository,
        .release = manifest.release,
        .source = manifest.source,
        .build = manifest.build,
        .executable_sha256 = executable,
        .compatibility = manifest.compatibility,
        .executable_compatibility_verified = true,
        .signing = manifest.signing,
        .strict_signature_verified = true,
        .notarization_verified = true,
        .staple_verified = true,
        .assets = assets,
        .dmg_product_executable_sha256 = executable,
        .dmg_extraction_no_follow = true,
        .evidence = .{
            .summary_sha256 = manifest.evidence.summary_sha256,
            .test_uuid = manifest.evidence.test_uuid,
            .result = manifest.evidence.result,
            .candidate_executable_sha256 = executable,
        },
        .evidence_schema_verified = true,
        .manifest_sha256 = manifest_sha,
        .manifest_attestation = validAttestation(manifest.*, "release-manifest.json", manifest_sha),
        .predecessor = predecessor,
    };
}

fn validPredecessorManifest(successor: Manifest) Manifest {
    var predecessor = validManifest(.a);
    predecessor.release.id = successor.predecessor.?.release_id;
    predecessor.release.tag = successor.predecessor.?.tag;
    predecessor.release.version = successor.predecessor.?.tag[1..];
    predecessor.signing.bundle_short_version = predecessor.release.version;
    predecessor.source.commit = successor.predecessor.?.commit;
    return predecessor;
}

test "release manifest canonical A and B round trip" {
    for ([_]Role{ .a, .b }) |role| {
        const bytes = try writeCanonical(std.testing.allocator, validManifest(role));
        defer std.testing.allocator.free(bytes);
        var parsed = try parseCanonical(std.testing.allocator, bytes);
        defer parsed.deinit();
        try std.testing.expectEqual(role, parsed.value().role);
        @memset(bytes, 0xaa);
        try std.testing.expectEqualStrings("ohah", parsed.value().repository.owner);
        try std.testing.expectEqualStrings("arm64", parsed.value().signing.architectures[0]);
        try std.testing.expectEqualStrings("Maru.dmg", parsed.value().assets[0].name);
        if (role == .b) try std.testing.expectEqualStrings("v0.0.9", parsed.value().predecessor.?.tag);
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

fn observationAllocationFailureCase(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    observed: Observation,
) !void {
    var parsed = try parseAndValidateObservation(allocator, bytes, observed);
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

test "release manifest typed observations accept exact A and immutable predecessor B" {
    var b = validManifest(.b);
    const a = validPredecessorManifest(b);
    const a_bytes = try writeCanonical(std.testing.allocator, a);
    defer std.testing.allocator.free(a_bytes);
    var a_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(a_bytes, &a_digest, .{});
    const a_digest_hex = std.fmt.bytesToHex(a_digest, .lower);

    var a_assets: [3]AssetObservation = undefined;
    fillAssetObservations(a, &a_assets);
    var a_observed = validObservation(&a, &a_assets, null);
    a_observed.manifest_sha256 = &a_digest_hex;
    a_observed.manifest_attestation.subject_sha256 = &a_digest_hex;
    var validated_a = try parseAndValidateObservation(std.testing.allocator, a_bytes, a_observed);
    validated_a.deinit();

    b.predecessor.?.manifest_sha256 = &a_digest_hex;
    const b_bytes = try writeCanonical(std.testing.allocator, b);
    defer std.testing.allocator.free(b_bytes);
    var b_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(b_bytes, &b_digest, .{});
    const b_digest_hex = std.fmt.bytesToHex(b_digest, .lower);

    var b_assets: [3]AssetObservation = undefined;
    fillAssetObservations(b, &b_assets);
    const predecessor = PredecessorObservation{
        .manifest_bytes = a_bytes,
        .manifest_sha256 = &a_digest_hex,
        .published = true,
        .immutable = true,
        .manifest_asset_count = 1,
        .release_attestation = validReleaseAttestation(a, &a_digest_hex),
    };
    var b_observed = validObservation(&b, &b_assets, predecessor);
    b_observed.manifest_sha256 = &b_digest_hex;
    b_observed.manifest_attestation.subject_sha256 = &b_digest_hex;
    var validated_b = try parseAndValidateObservation(std.testing.allocator, b_bytes, b_observed);
    validated_b.deinit();

    var changed_a = try std.testing.allocator.dupe(u8, a_bytes);
    defer std.testing.allocator.free(changed_a);
    const predecessor_hash_start = std.mem.indexOf(u8, changed_a, "aaaaaaaaaaaaaaaa") orelse unreachable;
    changed_a[predecessor_hash_start] = 'f';
    b_observed.predecessor.?.manifest_bytes = changed_a;
    try std.testing.expectError(
        error.PredecessorMismatch,
        parseAndValidateObservation(std.testing.allocator, b_bytes, b_observed),
    );
}

test "release manifest typed observations reject identity signature and asset drift" {
    var manifest = validManifest(.a);
    var assets: [3]AssetObservation = undefined;
    fillAssetObservations(manifest, &assets);
    var observed = validObservation(&manifest, &assets, null);

    observed.repository.id += 1;
    try std.testing.expectError(error.RepositoryMismatch, validateObservation(manifest, observed, null));
    observed = validObservation(&manifest, &assets, null);
    observed.compatibility.screen_codec += 1;
    try std.testing.expectError(error.CompatibilityMismatch, validateObservation(manifest, observed, null));
    observed = validObservation(&manifest, &assets, null);
    observed.signing.team_id = "OTHERTEAM";
    try std.testing.expectError(error.SigningMismatch, validateObservation(manifest, observed, null));
    observed = validObservation(&manifest, &assets, null);
    observed.strict_signature_verified = false;
    try std.testing.expectError(error.SigningMismatch, validateObservation(manifest, observed, null));
    observed = validObservation(&manifest, &assets, null);
    assets[0].no_follow = false;
    try std.testing.expectError(error.AssetMismatch, validateObservation(manifest, observed, null));
    fillAssetObservations(manifest, &assets);
    observed = validObservation(&manifest, &assets, null);
    observed.dmg_extraction_no_follow = false;
    try std.testing.expectError(error.DmgExecutableMismatch, validateObservation(manifest, observed, null));
}

test "release manifest typed observations reject attestation evidence and predecessor substitution" {
    var b = validManifest(.b);
    var a = validPredecessorManifest(b);
    var assets: [3]AssetObservation = undefined;
    fillAssetObservations(b, &assets);
    var predecessor = PredecessorObservation{
        .manifest_bytes = "unused by the internal policy test",
        .manifest_sha256 = b.predecessor.?.manifest_sha256,
        .published = true,
        .immutable = true,
        .manifest_asset_count = 1,
        .release_attestation = validReleaseAttestation(a, b.predecessor.?.manifest_sha256),
    };
    var observed = validObservation(&b, &assets, predecessor);
    observed.manifest_attestation.source_commit = a.source.commit;
    try std.testing.expectError(error.AttestationMismatch, validateObservation(b, observed, a));

    observed = validObservation(&b, &assets, predecessor);
    assets[0].attestation.subject_name = assets[1].asset.name;
    try std.testing.expectError(error.AttestationMismatch, validateObservation(b, observed, a));
    fillAssetObservations(b, &assets);

    observed = validObservation(&b, &assets, predecessor);
    observed.evidence.candidate_executable_sha256 = a.source.commit;
    try std.testing.expectError(error.EvidenceMismatch, validateObservation(b, observed, a));

    predecessor.immutable = false;
    observed = validObservation(&b, &assets, predecessor);
    try std.testing.expectError(error.PredecessorMismatch, validateObservation(b, observed, a));
    predecessor.immutable = true;
    a.release.id += 1;
    observed = validObservation(&b, &assets, predecessor);
    try std.testing.expectError(error.PredecessorMismatch, validateObservation(b, observed, a));
}

test "release manifest observations reject cross artifact substitution" {
    const manifest = validManifest(.a);
    var assets: [3]AssetObservation = undefined;
    fillAssetObservations(manifest, &assets);

    var observed = validObservation(&manifest, &assets, null);
    observed.executable_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.CompatibilityMismatch, validateObservation(manifest, observed, null));

    observed = validObservation(&manifest, &assets, null);
    observed.evidence.summary_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.EvidenceMismatch, validateObservation(manifest, observed, null));
}

test "release publication policy rejects unsafe trigger order and asset substitution" {
    const manifest = validManifest(.b);
    const exact_steps = [_]PublicationStep{
        .candidate_attested,
        .draft_created,
        .evidence_verified,
        .manifest_created,
        .manifest_attested,
        .assets_attached,
        .draft_redownload_validated,
        .published,
        .release_attestation_verified,
    };
    var observed = PublicationObservation{
        .repository = manifest.repository,
        .source_commit = manifest.source.commit,
        .build = manifest.build,
        .manifest_sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        .trusted_tag_push = true,
        .protected_tag = true,
        .protected_environment = true,
        .fork_pr = false,
        .pull_request_target = false,
        .arbitrary_ref = false,
        .third_party_actions_pinned = true,
        .clobber_used = false,
        .predecessor_published = true,
        .predecessor_immutable = true,
        .manifest_asset_count = 1,
        .attached_assets = manifest.assets,
        .release_attested_assets = manifest.assets,
        .post_publish_mutation = false,
        .steps = &exact_steps,
    };
    try validatePublication(manifest, observed.manifest_sha256, observed);

    observed.trusted_tag_push = false;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.trusted_tag_push = true;
    observed.protected_tag = false;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.protected_tag = true;
    observed.protected_environment = false;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.protected_environment = true;
    observed.fork_pr = true;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.fork_pr = false;
    observed.pull_request_target = true;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.pull_request_target = false;
    observed.third_party_actions_pinned = false;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.third_party_actions_pinned = true;
    observed.clobber_used = true;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.clobber_used = false;
    observed.predecessor_immutable = false;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.predecessor_immutable = true;
    observed.manifest_asset_count = 0;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.manifest_asset_count = 1;

    const substituted_assets = manifest.assets[0 .. manifest.assets.len - 1];
    observed.attached_assets = substituted_assets;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.attached_assets = manifest.assets;

    observed.release_attested_assets = substituted_assets;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.release_attested_assets = manifest.assets;
    observed.post_publish_mutation = true;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.post_publish_mutation = false;

    observed.steps = exact_steps[0 .. exact_steps.len - 1];
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));

    var reordered_steps = exact_steps;
    std.mem.swap(PublicationStep, &reordered_steps[6], &reordered_steps[7]);
    observed.steps = &reordered_steps;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.steps = &exact_steps;
    observed.arbitrary_ref = true;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));
    observed.arbitrary_ref = false;
    observed.build.run_attempt += 1;
    try std.testing.expectError(error.PublicationMismatch, validatePublication(manifest, observed.manifest_sha256, observed));

    const a = validManifest(.a);
    const a_bytes = try writeCanonical(std.testing.allocator, a);
    defer std.testing.allocator.free(a_bytes);
    var a_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(a_bytes, &a_digest, .{});
    const a_digest_hex = std.fmt.bytesToHex(a_digest, .lower);
    var a_assets: [3]AssetObservation = undefined;
    fillAssetObservations(a, &a_assets);
    var a_evidence = validObservation(&a, &a_assets, null);
    a_evidence.manifest_sha256 = &a_digest_hex;
    a_evidence.manifest_attestation.subject_sha256 = &a_digest_hex;
    var a_publication = PublicationObservation{
        .repository = a.repository,
        .source_commit = a.source.commit,
        .build = a.build,
        .manifest_sha256 = &a_digest_hex,
        .trusted_tag_push = true,
        .protected_tag = true,
        .protected_environment = true,
        .fork_pr = false,
        .pull_request_target = false,
        .arbitrary_ref = false,
        .third_party_actions_pinned = true,
        .clobber_used = false,
        .predecessor_published = false,
        .predecessor_immutable = false,
        .manifest_asset_count = 1,
        .attached_assets = a.assets,
        .release_attested_assets = a.assets,
        .post_publish_mutation = false,
        .steps = &exact_steps,
    };
    var validated = try parseAndValidatePublication(
        std.testing.allocator,
        a_bytes,
        a_evidence,
        a_publication,
    );
    validated.deinit();
    a_publication.manifest_sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    try std.testing.expectError(
        error.PublicationMismatch,
        parseAndValidatePublication(std.testing.allocator, a_bytes, a_evidence, a_publication),
    );
}

test "release manifest observation binds attestation to exact canonical bytes" {
    var manifest = validManifest(.a);
    const bytes = try writeCanonical(std.testing.allocator, manifest);
    defer std.testing.allocator.free(bytes);

    var assets: [3]AssetObservation = undefined;
    fillAssetObservations(manifest, &assets);
    var observed = validObservation(&manifest, &assets, null);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    observed.manifest_sha256 = &digest_hex;
    observed.manifest_attestation.subject_sha256 = &digest_hex;
    var validated = try parseAndValidateObservation(std.testing.allocator, bytes, observed);
    validated.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        observationAllocationFailureCase,
        .{ bytes, observed },
    );

    var changed = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(changed);
    const hash_start = std.mem.indexOf(u8, changed, "aaaaaaaaaaaaaaaa") orelse unreachable;
    changed[hash_start] = 'f';
    try std.testing.expectError(
        error.ManifestDigestMismatch,
        parseAndValidateObservation(std.testing.allocator, changed, observed),
    );
}
