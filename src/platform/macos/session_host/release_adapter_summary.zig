//! Canonical audit output for successful release validation owners.
//!
//! The summary is an audit artifact, never an authority input. Identity, phase, digest, size, and
//! success are derived from authenticated owners and canonical manifest bytes.

const std = @import("std");
const manifest_mod = @import("release_manifest");
const contract = @import("release_adapter_contract");
const current_observation = @import("release_adapter_github_current_observation");
const authenticated_manifest = @import("release_adapter_github_manifest_attestation");
const predecessor_assets = @import("release_adapter_github_predecessor_assets");

pub const max_summary_bytes: usize = manifest_mod.max_manifest_bytes;

pub const Phase = enum {
    pre_publish,
    verify_predecessor,
};

pub const Result = enum {
    passed,
};

pub const Summary = struct {
    schema: []const u8,
    phase: Phase,
    result: Result,
    manifest_sha256: []const u8,
    manifest_size: u64,
    manifest: manifest_mod.Manifest,
};

pub const Parsed = struct {
    inner: std.json.Parsed(Summary),

    pub fn value(self: *const @This()) *const Summary {
        return &self.inner.value;
    }

    pub fn deinit(self: *@This()) void {
        self.inner.deinit();
        self.* = undefined;
    }
};

pub const PredecessorAssetsView = struct {
    source_commit: []const u8,
};

pub const Error = error{
    InvalidOwner,
    InvalidPhase,
    InvalidSummary,
    InvalidDigest,
    InvalidSize,
    InvalidJson,
    NonCanonical,
    SummaryTooLarge,
} || std.mem.Allocator.Error || manifest_mod.ParseError;

pub fn encodePrePublish(
    allocator: std.mem.Allocator,
    current: *const current_observation.CurrentObservation,
) Error![]u8 {
    return encodePrePublishWith(allocator, current);
}

pub fn encodePrePublishWith(allocator: std.mem.Allocator, current: anytype) Error![]u8 {
    const candidate = current.value() orelse return error.InvalidOwner;
    if (candidate.role != .b or candidate.predecessor == null) return error.InvalidPhase;
    const result = try encodeManifest(allocator, .pre_publish, candidate.*);
    errdefer allocator.free(result);
    const final = current.value() orelse return error.InvalidOwner;
    try matchesEncodedManifest(allocator, result, final.*);
    return result;
}

pub fn encodePredecessor(
    allocator: std.mem.Allocator,
    authenticated: *const authenticated_manifest.AuthenticatedManifest,
    assets: *predecessor_assets.AuthenticatedPredecessorAssets,
) Error![]u8 {
    const candidate = authenticated.value() orelse return error.InvalidOwner;
    const observed = authenticated.observed orelse return error.InvalidOwner;
    if (!observed.verified) return error.InvalidOwner;
    const before = assets.value() orelse return error.InvalidOwner;
    assets.downloads.revalidate() catch return error.InvalidOwner;
    if (candidate.role != .a or candidate.predecessor != null or
        !std.mem.eql(u8, candidate.source.commit, before.source_commit)) return error.InvalidOwner;
    const result = try encodeManifest(allocator, .verify_predecessor, candidate.*);
    errdefer allocator.free(result);
    assets.downloads.revalidate() catch return error.InvalidOwner;
    const after = assets.value() orelse return error.InvalidOwner;
    if (!std.mem.eql(u8, before.source_commit, after.source_commit) or
        !std.mem.eql(u8, candidate.source.commit, after.source_commit) or
        authenticated.value() == null or authenticated.observed == null or
        !authenticated.observed.?.verified) return error.InvalidOwner;
    try matchesEncodedManifest(allocator, result, authenticated.value().?.*);
    return result;
}

pub fn encodePredecessorWith(
    allocator: std.mem.Allocator,
    authenticated: anytype,
    assets: anytype,
) Error![]u8 {
    const candidate = authenticated.value() orelse return error.InvalidOwner;
    const observed = authenticated.observed orelse return error.InvalidOwner;
    if (!observed.verified) return error.InvalidOwner;
    const before = assets.revalidateSummary() catch return error.InvalidOwner;
    if (candidate.role != .a or candidate.predecessor != null or
        !std.mem.eql(u8, candidate.source.commit, before.source_commit)) return error.InvalidOwner;
    const result = try encodeManifest(allocator, .verify_predecessor, candidate.*);
    errdefer allocator.free(result);
    const after = assets.revalidateSummary() catch return error.InvalidOwner;
    if (!std.mem.eql(u8, before.source_commit, after.source_commit) or
        !std.mem.eql(u8, candidate.source.commit, after.source_commit) or
        authenticated.value() == null or authenticated.observed == null or
        !authenticated.observed.?.verified) return error.InvalidOwner;
    try matchesEncodedManifest(allocator, result, authenticated.value().?.*);
    return result;
}

pub fn parseCanonical(allocator: std.mem.Allocator, bytes: []const u8) Error!Parsed {
    if (bytes.len > max_summary_bytes) return error.SummaryTooLarge;
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.NonCanonical;
    var inner = std.json.parseFromSlice(Summary, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer inner.deinit();
    try validate(allocator, inner.value);
    const canonical = try writeSummary(allocator, inner.value.phase, inner.value.manifest);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, bytes)) return error.NonCanonical;
    return .{ .inner = inner };
}

fn encodeManifest(
    allocator: std.mem.Allocator,
    phase: Phase,
    candidate: manifest_mod.Manifest,
) Error![]u8 {
    try phaseRole(phase, candidate);
    const bytes = try writeSummary(allocator, phase, candidate);
    errdefer allocator.free(bytes);
    var parsed = try parseCanonical(allocator, bytes);
    parsed.deinit();
    return bytes;
}

fn writeSummary(
    allocator: std.mem.Allocator,
    phase: Phase,
    candidate: manifest_mod.Manifest,
) Error![]u8 {
    try phaseRole(phase, candidate);
    const manifest_bytes = try manifest_mod.writeCanonical(allocator, candidate);
    defer allocator.free(manifest_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(manifest_bytes, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    output.writer.print(
        "{{\"schema\":\"{s}\",\"phase\":\"{s}\",\"result\":\"passed\",\"manifest_sha256\":\"{s}\",\"manifest_size\":{d},\"manifest\":",
        .{ contract.summary_schema, @tagName(phase), digest_hex, manifest_bytes.len },
    ) catch return error.OutOfMemory;
    output.writer.writeAll(manifest_bytes[0 .. manifest_bytes.len - 1]) catch return error.OutOfMemory;
    output.writer.writeAll("}\n") catch return error.OutOfMemory;
    if (output.writer.end > max_summary_bytes) return error.SummaryTooLarge;
    return output.toOwnedSlice();
}

fn validate(allocator: std.mem.Allocator, summary: Summary) Error!void {
    if (!std.mem.eql(u8, summary.schema, contract.summary_schema) or summary.result != .passed)
        return error.InvalidSummary;
    try phaseRole(summary.phase, summary.manifest);
    const manifest_bytes = try manifest_mod.writeCanonical(allocator, summary.manifest);
    defer allocator.free(manifest_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(manifest_bytes, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, summary.manifest_sha256, &digest_hex)) return error.InvalidDigest;
    if (summary.manifest_size != manifest_bytes.len) return error.InvalidSize;
}

fn phaseRole(phase: Phase, candidate: manifest_mod.Manifest) Error!void {
    try manifest_mod.validateIntrinsic(candidate);
    switch (phase) {
        .pre_publish => if (candidate.role != .b or candidate.predecessor == null)
            return error.InvalidPhase,
        .verify_predecessor => if (candidate.role != .a or candidate.predecessor != null)
            return error.InvalidPhase,
    }
}

fn matchesEncodedManifest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    candidate: manifest_mod.Manifest,
) Error!void {
    var parsed = try parseCanonical(allocator, bytes);
    defer parsed.deinit();
    const encoded = try manifest_mod.writeCanonical(allocator, parsed.value().manifest);
    defer allocator.free(encoded);
    const current = try manifest_mod.writeCanonical(allocator, candidate);
    defer allocator.free(current);
    if (!std.mem.eql(u8, encoded, current)) return error.InvalidOwner;
}
