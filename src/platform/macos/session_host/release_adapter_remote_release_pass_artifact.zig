//! Selects and binds one GitHub-preserved canonical remote pass artifact.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const pass = @import("release_adapter_remote_release_pass_record");
const github_archive = @import("release_adapter_github_artifact_archive");

pub const response_cap: usize = 256 * 1024;
pub const archive_cap: usize = github_archive.archive_cap;
const repository = "ohah/maru";
const sha_len = 40;
const digest_len = 64;
const entry_name = "session-host-release-remote-pass.json";

pub const Expected = struct { repository_id: u64, run_id: u64, run_attempt: u64, source_sha: []const u8 };
pub const Value = struct { artifact_id: u64, archive_size: u64, archive_sha256: [digest_len]u8 };

pub const Metadata = struct {
    owner: ?*@This() = null,
    artifact_id: u64 = 0,
    archive_size: u64 = 0,
    archive_sha256: [digest_len]u8 = @splat(0),
    repository_id: u64 = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,
    source_sha: [sha_len]u8 = @splat(0),
    seal: [32]u8 = @splat(0),

    pub fn value(self: *const @This()) ?Value {
        if (self.owner != self or self.artifact_id == 0 or self.archive_size == 0 or self.repository_id == 0 or
            self.run_id == 0 or self.run_attempt == 0 or !lowerHex(&self.source_sha) or !lowerHex(&self.archive_sha256) or
            !std.crypto.timing_safe.eql([32]u8, self.seal, metadataSeal(self))) return null;
        return .{ .artifact_id = self.artifact_id, .archive_size = self.archive_size, .archive_sha256 = self.archive_sha256 };
    }

    pub fn deinit(self: *@This()) !void {
        if (self.owner != self or self.value() == null) return error.InvalidOwner;
        self.* = .{};
    }
};

pub const ProvenanceValue = struct {
    artifact_id: u64,
    archive_sha256: [digest_len]u8,
    record: pass.Record,
};

pub const Provenance = struct {
    owner: ?*@This() = null,
    context_owner: ?*const context_mod.Context = null,
    artifact_id: u64 = 0,
    archive_sha256: [digest_len]u8 = @splat(0),
    record: ?pass.Parsed = null,
    seal: [32]u8 = @splat(0),
    cleanup_seal: [32]u8 = @splat(0),

    pub fn isPristineForComposition(self: *const @This()) bool {
        return provenancePristine(self);
    }

    pub fn value(self: *const @This()) ?ProvenanceValue {
        if (self.owner != self or self.artifact_id == 0 or !lowerHex(&self.archive_sha256) or
            !std.crypto.timing_safe.eql([32]u8, self.seal, provenanceSeal(self))) return null;
        const context = self.context_owner orelse return null;
        const parsed = if (self.record) |*record_value| record_value else return null;
        pass.validateForContext(context.*, parsed.value().*) catch return null;
        return .{ .artifact_id = self.artifact_id, .archive_sha256 = self.archive_sha256, .record = parsed.value().* };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) !void {
        if (self.owner != self or self.record == null or
            !std.crypto.timing_safe.eql([32]u8, self.cleanup_seal, provenanceCleanupSeal(self))) return error.InvalidOwner;
        cleanupProvenance(self, allocator);
    }
};

const WorkflowRun = struct { id: u64, repository_id: u64, head_repository_id: u64, head_sha: []const u8 };
const Artifact = struct { id: u64, name: []const u8, size_in_bytes: u64, url: []const u8, archive_download_url: []const u8, expired: bool, digest: []const u8, workflow_run: ?WorkflowRun };
const Response = struct { total_count: u64, artifacts: []const Artifact };

pub fn selectMetadata(allocator: std.mem.Allocator, bytes: []const u8, expected: Expected, result: *Metadata) !void {
    if (!pristine(result) or overlaps(std.mem.asBytes(result), bytes)) return error.InvalidOwner;
    if (!validExpected(expected) or bytes.len == 0 or bytes.len > response_cap) return error.InvalidMetadata;
    var parsed = std.json.parseFromSlice(Response, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true, .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMetadata,
    };
    defer parsed.deinit();
    if (parsed.value.total_count == 0 and parsed.value.artifacts.len == 0) return error.NotFound;
    if (parsed.value.total_count != 1 or parsed.value.artifacts.len != 1) return error.InvalidMetadata;
    const item = parsed.value.artifacts[0];
    const run = item.workflow_run orelse return error.InvalidMetadata;
    var name_storage: [96]u8 = undefined;
    const name = std.fmt.bufPrint(&name_storage, "session-host-release-remote-pass-{d}", .{expected.run_attempt}) catch return error.InvalidMetadata;
    var url_storage: [160]u8 = undefined;
    const url = std.fmt.bufPrint(&url_storage, "https://api.github.com/repos/{s}/actions/artifacts/{d}", .{ repository, item.id }) catch return error.InvalidMetadata;
    var download_storage: [168]u8 = undefined;
    const download = std.fmt.bufPrint(&download_storage, "{s}/zip", .{url}) catch return error.InvalidMetadata;
    if (item.id == 0 or item.size_in_bytes == 0 or item.expired or !std.mem.eql(u8, item.name, name) or
        !std.mem.eql(u8, item.url, url) or !std.mem.eql(u8, item.archive_download_url, download) or
        run.id != expected.run_id or run.repository_id != expected.repository_id or run.head_repository_id != expected.repository_id or
        !std.mem.eql(u8, run.head_sha, expected.source_sha) or item.digest.len != "sha256:".len + digest_len or
        !std.mem.startsWith(u8, item.digest, "sha256:") or !lowerHex(item.digest["sha256:".len..])) return error.InvalidMetadata;
    result.artifact_id = item.id;
    result.archive_size = item.size_in_bytes;
    @memcpy(&result.archive_sha256, item.digest["sha256:".len..]);
    result.repository_id = expected.repository_id;
    result.run_id = expected.run_id;
    result.run_attempt = expected.run_attempt;
    @memcpy(&result.source_sha, expected.source_sha);
    result.owner = result;
    result.seal = metadataSeal(result);
}

pub fn bindArchive(allocator: std.mem.Allocator, context: *const context_mod.Context, metadata: *const Metadata, archive: []const u8, result: *Provenance) !void {
    const selected = metadata.value() orelse return error.InvalidMetadata;
    if (!provenancePristine(result) or overlaps(std.mem.asBytes(result), archive) or overlaps(std.mem.asBytes(result), std.mem.asBytes(metadata)) or
        overlaps(std.mem.asBytes(result), std.mem.asBytes(context))) return error.InvalidOwner;
    try context_mod.validateTrusted(context.*);
    if (metadata.repository_id != context.repository.id or metadata.run_id != context.build.run_id or
        metadata.run_attempt != context.build.run_attempt or !std.mem.eql(u8, &metadata.source_sha, context.source_commit)) return error.BindingMismatch;
    if (archive.len == 0 or archive.len > archive_cap or archive.len != selected.archive_size) return error.InvalidArchive;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    const expected_digest = decodeHex(selected.archive_sha256) catch return error.InvalidMetadata;
    if (!std.crypto.timing_safe.eql([32]u8, digest, expected_digest)) return error.InvalidArchive;

    const plain = github_archive.extractAlloc(allocator, archive, entry_name, pass.max_record_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArchive,
    };
    defer allocator.free(plain);
    var staged: Provenance = .{};
    errdefer cleanupProvenance(&staged, allocator);
    staged.record = try pass.parseCanonical(allocator, plain);
    try pass.validateForContext(context.*, staged.record.?.value().*);
    if (!provenancePristine(result)) return error.InvalidOwner;
    result.* = staged;
    staged = .{};
    result.context_owner = context;
    result.artifact_id = selected.artifact_id;
    result.archive_sha256 = selected.archive_sha256;
    result.owner = result;
    result.seal = provenanceSeal(result);
    result.cleanup_seal = provenanceCleanupSeal(result);
    if (result.value() == null) {
        cleanupProvenance(result, allocator);
        return error.BindingMismatch;
    }
}

fn validExpected(value: Expected) bool {
    return value.repository_id != 0 and value.run_id != 0 and value.run_attempt != 0 and value.source_sha.len == sha_len and lowerHex(value.source_sha);
}

fn pristine(value: *const Metadata) bool {
    return value.owner == null and value.artifact_id == 0 and value.archive_size == 0 and value.repository_id == 0 and value.run_id == 0 and
        value.run_attempt == 0 and std.mem.allEqual(u8, &value.archive_sha256, 0) and std.mem.allEqual(u8, &value.source_sha, 0) and std.mem.allEqual(u8, &value.seal, 0);
}

fn metadataSeal(value: *const Metadata) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(std.mem.asBytes(&value.artifact_id));
    hasher.update(std.mem.asBytes(&value.archive_size));
    hasher.update(&value.archive_sha256);
    hasher.update(std.mem.asBytes(&value.repository_id));
    hasher.update(std.mem.asBytes(&value.run_id));
    hasher.update(std.mem.asBytes(&value.run_attempt));
    hasher.update(&value.source_sha);
    var seal: [32]u8 = undefined;
    hasher.final(&seal);
    return seal;
}

fn provenancePristine(value: *const Provenance) bool {
    return value.owner == null and value.context_owner == null and value.artifact_id == 0 and value.record == null and
        std.mem.allEqual(u8, &value.archive_sha256, 0) and std.mem.allEqual(u8, &value.seal, 0) and
        std.mem.allEqual(u8, &value.cleanup_seal, 0);
}

fn cleanupProvenance(value: *Provenance, allocator: std.mem.Allocator) void {
    if (value.record) |*record_value| record_value.deinit();
    _ = allocator;
    value.* = .{};
}

fn provenanceSeal(value: *const Provenance) [32]u8 {
    const context = value.context_owner orelse return @splat(0);
    const parsed = if (value.record) |*record_value| record_value else return @splat(0);
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(std.mem.asBytes(&value.artifact_id));
    hasher.update(&value.archive_sha256);
    hasher.update(std.mem.asBytes(&context.repository.id));
    hasher.update(context.repository.owner);
    hasher.update(context.repository.name);
    hasher.update(context.tag);
    hasher.update(context.source_commit);
    hasher.update(context.build.workflow_ref);
    hasher.update(std.mem.asBytes(&context.build.run_id));
    hasher.update(std.mem.asBytes(&context.build.run_attempt));
    const record_value = parsed.value();
    hasher.update(std.mem.asBytes(&record_value.release.id));
    hasher.update(std.mem.asBytes(&record_value.timing_artifact_id));
    hasher.update(std.mem.asBytes(&record_value.duration_ms));
    hasher.update(@tagName(record_value.profile));
    var seal: [32]u8 = undefined;
    hasher.final(&seal);
    return seal;
}

fn provenanceCleanupSeal(value: *const Provenance) [32]u8 {
    const parsed = if (value.record) |*record_value| record_value else return @splat(0);
    const record_value = parsed.value();
    var hasher = std.crypto.hash.Blake3.init(.{});
    const owner_address = @intFromPtr(value.owner orelse return @splat(0));
    hasher.update(std.mem.asBytes(&owner_address));
    hasher.update(std.mem.asBytes(&value.artifact_id));
    const schema_address = @intFromPtr(record_value.schema.ptr);
    hasher.update(std.mem.asBytes(&schema_address));
    hasher.update(std.mem.asBytes(&record_value.schema.len));
    const source_address = @intFromPtr(record_value.source_sha.ptr);
    hasher.update(std.mem.asBytes(&source_address));
    hasher.update(std.mem.asBytes(&record_value.source_sha.len));
    var seal: [32]u8 = undefined;
    hasher.final(&seal);
    return seal;
}

fn decodeHex(bytes: [digest_len]u8) ![32]u8 {
    var result: [32]u8 = undefined;
    for (&result, 0..) |*byte, index| byte.* = (try nibble(bytes[index * 2])) << 4 | try nibble(bytes[index * 2 + 1]);
    return result;
}

fn nibble(byte: u8) !u8 {
    return if (std.ascii.isDigit(byte)) byte - '0' else if (byte >= 'a' and byte <= 'f') byte - 'a' + 10 else error.InvalidHex;
}

fn lowerHex(bytes: []const u8) bool {
    for (bytes) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return bytes.len != 0;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = @intFromPtr(left.ptr) + left.len;
    const right_end = @intFromPtr(right.ptr) + right.len;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
