//! Selects one GitHub Actions timing artifact before any archive bytes are trusted.

const std = @import("std");
const timing = @import("release_adapter_live_timing_record");
const github_archive = @import("release_adapter_github_artifact_archive");

pub const response_cap: usize = 256 * 1024;
const repository = "ohah/maru";
const sha_len = 40;
const digest_len = 64;
pub const archive_cap: usize = 64 * 1024;
const entry_name = "session-host-release-live-timing.json";

pub const Expected = struct {
    repository_id: u64,
    run_id: u64,
    run_attempt: u64,
    source_sha: []const u8,
};

pub const Value = struct {
    artifact_id: u64,
    archive_size: u64,
    archive_sha256: [digest_len]u8,
};

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
            self.run_id == 0 or self.run_attempt == 0 or !lowerHex(&self.source_sha) or
            !lowerHex(&self.archive_sha256) or !std.mem.eql(u8, &self.seal, &metadataSeal(self))) return null;
        return .{ .artifact_id = self.artifact_id, .archive_size = self.archive_size, .archive_sha256 = self.archive_sha256 };
    }

    pub fn deinit(self: *@This()) !void {
        if (self.owner != self or self.value() == null) return error.InvalidOwner;
        self.* = .{};
    }
};

pub const ProvenanceValue = struct {
    artifact_id: u64,
    timing: timing.Value,
};

pub const Provenance = struct {
    owner: ?*@This() = null,
    artifact_id: u64 = 0,
    repository_id: u64 = 0,
    archive_sha256: [digest_len]u8 = @splat(0),
    timing_record: timing.Record = .{},
    seal: [32]u8 = @splat(0),

    pub fn isPristineForComposition(self: *const @This()) bool {
        return provenancePristine(self);
    }

    pub fn value(self: *const @This()) ?ProvenanceValue {
        const timing_value = self.timing_record.value() orelse return null;
        if (self.owner != self or self.artifact_id == 0 or self.repository_id == 0 or
            !lowerHex(&self.archive_sha256) or !std.mem.eql(u8, &self.seal, &provenanceSeal(self))) return null;
        return .{ .artifact_id = self.artifact_id, .timing = timing_value };
    }

    pub fn deinit(self: *@This()) !void {
        if (self.owner != self or self.value() == null) return error.InvalidOwner;
        try self.timing_record.deinit();
        self.* = .{};
    }
};

const WorkflowRun = struct {
    id: u64,
    repository_id: u64,
    head_repository_id: u64,
    head_sha: []const u8,
};

const Artifact = struct {
    id: u64,
    name: []const u8,
    size_in_bytes: u64,
    url: []const u8,
    archive_download_url: []const u8,
    expired: bool,
    digest: []const u8,
    workflow_run: ?WorkflowRun,
};

const Response = struct {
    total_count: u64,
    artifacts: []const Artifact,
};

pub fn selectMetadata(allocator: std.mem.Allocator, bytes: []const u8, expected: Expected, result: *Metadata) !void {
    if (!pristine(result) or overlaps(std.mem.asBytes(result), bytes)) return error.InvalidOwner;
    if (!validExpected(expected) or bytes.len == 0 or bytes.len > response_cap) return error.InvalidMetadata;

    var parsed = std.json.parseFromSlice(Response, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMetadata,
    };
    defer parsed.deinit();
    if (parsed.value.total_count != 1 or parsed.value.artifacts.len != 1) return error.InvalidMetadata;
    const artifact = parsed.value.artifacts[0];
    const run = artifact.workflow_run orelse return error.InvalidMetadata;

    var expected_name_storage: [96]u8 = undefined;
    const expected_name = std.fmt.bufPrint(&expected_name_storage, "session-host-release-live-timing-{d}", .{expected.run_attempt}) catch
        return error.InvalidMetadata;
    var expected_url_storage: [160]u8 = undefined;
    const expected_url = std.fmt.bufPrint(&expected_url_storage, "https://api.github.com/repos/{s}/actions/artifacts/{d}", .{ repository, artifact.id }) catch
        return error.InvalidMetadata;
    var expected_download_storage: [168]u8 = undefined;
    const expected_download = std.fmt.bufPrint(&expected_download_storage, "{s}/zip", .{expected_url}) catch
        return error.InvalidMetadata;

    if (artifact.id == 0 or artifact.size_in_bytes == 0 or artifact.expired or
        !std.mem.eql(u8, artifact.name, expected_name) or !std.mem.eql(u8, artifact.url, expected_url) or
        !std.mem.eql(u8, artifact.archive_download_url, expected_download) or run.id != expected.run_id or
        run.repository_id != expected.repository_id or run.head_repository_id != expected.repository_id or
        !std.mem.eql(u8, run.head_sha, expected.source_sha) or artifact.digest.len != "sha256:".len + digest_len or
        !std.mem.startsWith(u8, artifact.digest, "sha256:") or !lowerHex(artifact.digest["sha256:".len..])) return error.InvalidMetadata;

    result.artifact_id = artifact.id;
    result.archive_size = artifact.size_in_bytes;
    @memcpy(&result.archive_sha256, artifact.digest["sha256:".len..]);
    result.repository_id = expected.repository_id;
    result.run_id = expected.run_id;
    result.run_attempt = expected.run_attempt;
    @memcpy(&result.source_sha, expected.source_sha);
    result.owner = result;
    result.seal = metadataSeal(result);
}

pub fn bindArchive(allocator: std.mem.Allocator, metadata: *const Metadata, archive: []const u8, result: *Provenance) !void {
    const selected = metadata.value() orelse return error.InvalidMetadata;
    if (!provenancePristine(result) or overlaps(std.mem.asBytes(result), archive) or overlaps(std.mem.asBytes(result), std.mem.asBytes(metadata)))
        return error.InvalidOwner;
    if (archive.len == 0 or archive.len > archive_cap or archive.len != selected.archive_size) return error.InvalidArchive;
    var archive_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &archive_digest, .{});
    const expected_digest = decodeHex(selected.archive_sha256) catch return error.InvalidMetadata;
    if (!std.mem.eql(u8, &archive_digest, &expected_digest)) return error.InvalidArchive;

    const plain = github_archive.extractAlloc(allocator, archive, entry_name, timing.input_cap) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArchive,
    };
    defer allocator.free(plain);

    timing.parse(allocator, plain, &result.timing_record) catch |err| return err;
    errdefer result.timing_record.deinit() catch {};
    const record = result.timing_record.value() orelse return error.InvalidRecord;
    if (record.run_id != metadata.run_id or record.run_attempt != metadata.run_attempt or
        !std.mem.eql(u8, record.source_sha, &metadata.source_sha)) return error.BindingMismatch;
    result.artifact_id = selected.artifact_id;
    result.repository_id = metadata.repository_id;
    result.archive_sha256 = selected.archive_sha256;
    result.owner = result;
    result.seal = provenanceSeal(result);
}

fn validExpected(expected: Expected) bool {
    return expected.repository_id != 0 and expected.run_id != 0 and expected.run_attempt != 0 and
        expected.source_sha.len == sha_len and lowerHex(expected.source_sha);
}

fn pristine(value: *const Metadata) bool {
    return value.owner == null and value.artifact_id == 0 and value.archive_size == 0 and value.repository_id == 0 and
        value.run_id == 0 and value.run_attempt == 0 and std.mem.allEqual(u8, &value.archive_sha256, 0) and
        std.mem.allEqual(u8, &value.source_sha, 0) and std.mem.allEqual(u8, &value.seal, 0);
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
    return value.owner == null and value.artifact_id == 0 and value.repository_id == 0 and
        std.mem.allEqual(u8, &value.archive_sha256, 0) and std.mem.allEqual(u8, &value.seal, 0) and
        value.timing_record.owner == null and value.timing_record.run_id == 0;
}

fn provenanceSeal(value: *const Provenance) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(std.mem.asBytes(&value.artifact_id));
    hasher.update(std.mem.asBytes(&value.repository_id));
    hasher.update(&value.archive_sha256);
    const record = value.timing_record.value() orelse return @splat(0);
    hasher.update(std.mem.asBytes(&record.run_id));
    hasher.update(std.mem.asBytes(&record.run_attempt));
    hasher.update(record.source_sha);
    hasher.update(record.started_at);
    hasher.update(record.completed_at);
    hasher.update(std.mem.asBytes(&record.duration_ms));
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
