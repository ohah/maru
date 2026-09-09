//! Canonical, credential-free record of one protected-run remote Release verdict.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const verdict_mod = @import("release_adapter_remote_release_verdict");
const evidence = @import("release_evidence");

pub const schema = "maru.session-host-release-remote-pass.v1";
pub const max_record_bytes: usize = 4 * 1024;

pub const Result = enum { passed };

pub const Repository = struct { id: u64, owner: []const u8, name: []const u8 };
pub const Release = struct { id: u64, tag: []const u8 };

pub const Record = struct {
    schema: []const u8,
    profile: evidence.Profile,
    result: Result,
    repository: Repository,
    release: Release,
    source_sha: []const u8,
    workflow_ref: []const u8,
    run_id: u64,
    run_attempt: u64,
    timing_artifact_id: u64,
    duration_ms: u64,
};

pub const Parsed = struct {
    inner: std.json.Parsed(Record),

    pub fn value(self: *const @This()) *const Record {
        return &self.inner.value;
    }

    pub fn deinit(self: *@This()) void {
        self.inner.deinit();
        self.* = undefined;
    }
};

pub const Owner = struct {
    owner: ?*@This() = null,
    context_owner: ?*const context_mod.Context = null,
    verdict_owner: ?*const verdict_mod.Verdict = null,
    bytes: ?[]u8 = null,
    parsed: ?Parsed = null,
    seal: [32]u8 = @splat(0),

    pub fn value(self: *const @This()) ?[]const u8 {
        if (self.owner != self or !std.crypto.timing_safe.eql([32]u8, self.seal, ownerSeal(self))) return null;
        const context = self.context_owner orelse return null;
        const verdict = self.verdict_owner orelse return null;
        const bytes = self.bytes orelse return null;
        const parsed = if (self.parsed) |*record_value| record_value else return null;
        const verdict_value = verdict.value() orelse return null;
        context_mod.validateTrusted(context.*) catch return null;
        bindRecord(context.*, verdict_value, parsed.value().*) catch return null;
        if (bytes.len == 0 or bytes.len > max_record_bytes) return null;
        return bytes;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) !void {
        if (self.owner != self or !std.crypto.timing_safe.eql([32]u8, self.seal, ownerSeal(self))) return error.InvalidOwner;
        cleanup(self, allocator);
    }
};

/// Immutable handoff between verdict validation and post-cleanup filesystem publication.
pub const Frozen = struct {
    owner: ?*@This() = null,
    bytes: ?[]u8 = null,
    parsed: ?Parsed = null,
    sha256: [64]u8 = @splat(0),
    seal: [32]u8 = @splat(0),

    pub fn value(self: *const @This()) ?[]const u8 {
        if (self.owner != self or !std.crypto.timing_safe.eql([32]u8, self.seal, frozenSeal(self))) return null;
        const bytes = self.bytes orelse return null;
        const parsed = if (self.parsed) |*record_value| record_value else return null;
        validateIntrinsic(parsed.value().*) catch return null;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.crypto.timing_safe.eql([64]u8, digest_hex, self.sha256)) return null;
        return bytes;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) !void {
        if (self.owner != self or !std.crypto.timing_safe.eql([32]u8, self.seal, frozenSeal(self))) return error.InvalidOwner;
        frozenCleanup(self, allocator);
    }
};

pub fn encode(allocator: std.mem.Allocator, context: *const context_mod.Context, verdict: *const verdict_mod.Verdict, result: *Owner) !void {
    if (!pristine(result) or aliases(context, verdict, result)) return error.InvalidOwner;
    try context_mod.validateTrusted(context.*);
    const verdict_value = verdict.value() orelse return error.InvalidVerdict;
    const record = fromVerdict(context.*, verdict_value);
    try validateIntrinsic(record);

    var staged: Owner = .{};
    errdefer cleanup(&staged, allocator);
    staged.bytes = try writeCanonical(allocator, record);
    staged.parsed = try parseCanonical(allocator, staged.bytes.?);
    try bindRecord(context.*, verdict_value, staged.parsed.?.value().*);
    if (!pristine(result) or aliases(context, verdict, result)) return error.InvalidOwner;
    result.* = staged;
    staged = .{};
    result.context_owner = context;
    result.verdict_owner = verdict;
    result.owner = result;
    result.seal = ownerSeal(result);
    if (result.value() == null) {
        cleanup(result, allocator);
        return error.BindingMismatch;
    }
}

pub fn freeze(allocator: std.mem.Allocator, source: *const Owner, result: *Frozen) !void {
    if (!frozenPristine(result) or frozenAliases(source, result)) return error.InvalidOwner;
    const source_bytes = source.value() orelse return error.InvalidRecord;
    var staged: Frozen = .{};
    errdefer frozenCleanup(&staged, allocator);
    staged.bytes = try allocator.dupe(u8, source_bytes);
    staged.parsed = try parseCanonical(allocator, staged.bytes.?);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(staged.bytes.?, &digest, .{});
    staged.sha256 = std.fmt.bytesToHex(digest, .lower);
    const final_source = source.value() orelse return error.InvalidRecord;
    if (!std.mem.eql(u8, staged.bytes.?, final_source)) return error.InvalidRecord;
    if (!frozenPristine(result) or frozenAliases(source, result)) return error.InvalidOwner;
    result.* = staged;
    staged = .{};
    result.owner = result;
    result.seal = frozenSeal(result);
    if (result.value() == null) {
        frozenCleanup(result, allocator);
        return error.InvalidRecord;
    }
}

pub fn parseCanonical(allocator: std.mem.Allocator, bytes: []const u8) !Parsed {
    if (bytes.len == 0 or bytes.len > max_record_bytes or bytes[bytes.len - 1] != '\n') return error.NonCanonical;
    var inner = std.json.parseFromSlice(Record, allocator, bytes, .{
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

pub fn writeCanonical(allocator: std.mem.Allocator, record: Record) ![]u8 {
    try validateIntrinsic(record);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    json.write(.{
        .schema = record.schema,
        .profile = record.profile,
        .result = record.result,
        .repository = record.repository,
        .release = record.release,
        .source_sha = record.source_sha,
        .workflow_ref = record.workflow_ref,
        .run_id = record.run_id,
        .run_attempt = record.run_attempt,
        .timing_artifact_id = record.timing_artifact_id,
        .duration_ms = record.duration_ms,
    }) catch return error.OutOfMemory;
    output.writer.writeByte('\n') catch return error.OutOfMemory;
    if (output.writer.end > max_record_bytes) return error.RecordTooLarge;
    return output.toOwnedSlice();
}

fn fromVerdict(context: context_mod.Context, value: verdict_mod.View) Record {
    return .{
        .schema = schema,
        .profile = value.profile,
        .result = .passed,
        .repository = .{ .id = context.repository.id, .owner = context.repository.owner, .name = context.repository.name },
        .release = .{ .id = value.release_id, .tag = context.tag },
        .source_sha = value.source_commit,
        .workflow_ref = context.build.workflow_ref,
        .run_id = value.run_id,
        .run_attempt = value.run_attempt,
        .timing_artifact_id = value.timing_artifact_id,
        .duration_ms = value.duration_ms,
    };
}

fn validateIntrinsic(record: Record) !void {
    if (!std.mem.eql(u8, record.schema, schema)) return error.InvalidSchema;
    if (record.repository.id == 0 or !std.mem.eql(u8, record.repository.owner, "ohah") or !std.mem.eql(u8, record.repository.name, "maru")) return error.InvalidRepository;
    if (record.release.id == 0 or record.release.tag.len < 2 or record.release.tag[0] != 'v') return error.InvalidRelease;
    if (!lowerHex(record.source_sha, 40) or record.workflow_ref.len == 0 or record.run_id == 0 or record.run_attempt == 0 or
        record.timing_artifact_id == 0 or record.duration_ms == 0) return error.InvalidIdentity;
    for ([_][]const u8{ record.release.tag, record.workflow_ref }) |value| try scalar(value);
}

fn bindRecord(context: context_mod.Context, verdict: verdict_mod.View, record: Record) !void {
    try validateIntrinsic(record);
    if (record.profile != verdict.profile or record.repository.id != context.repository.id or
        !std.mem.eql(u8, record.repository.owner, context.repository.owner) or !std.mem.eql(u8, record.repository.name, context.repository.name) or
        record.release.id != verdict.release_id or !std.mem.eql(u8, record.release.tag, context.tag) or
        !std.mem.eql(u8, record.source_sha, context.source_commit) or !std.mem.eql(u8, record.source_sha, verdict.source_commit) or
        !std.mem.eql(u8, record.workflow_ref, context.build.workflow_ref) or record.run_id != context.build.run_id or
        record.run_id != verdict.run_id or record.run_attempt != context.build.run_attempt or record.run_attempt != verdict.run_attempt or
        record.timing_artifact_id != verdict.timing_artifact_id or record.duration_ms != verdict.duration_ms) return error.BindingMismatch;
}

fn scalar(value: []const u8) !void {
    if (value.len == 0 or value.len > context_mod.max_value_bytes) return error.InvalidScalar;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidScalar;
}

fn lowerHex(value: []const u8, len: usize) bool {
    if (value.len != len) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn pristine(result: *const Owner) bool {
    return result.owner == null and result.context_owner == null and result.verdict_owner == null and result.bytes == null and
        result.parsed == null and std.mem.allEqual(u8, &result.seal, 0);
}

fn cleanup(result: *Owner, allocator: std.mem.Allocator) void {
    if (result.parsed) |*parsed| parsed.deinit();
    if (result.bytes) |bytes| allocator.free(bytes);
    result.* = .{};
}

fn frozenPristine(result: *const Frozen) bool {
    return result.owner == null and result.bytes == null and result.parsed == null and std.mem.allEqual(u8, &result.sha256, 0) and
        std.mem.allEqual(u8, &result.seal, 0);
}

fn frozenCleanup(result: *Frozen, allocator: std.mem.Allocator) void {
    if (result.parsed) |*parsed| parsed.deinit();
    if (result.bytes) |bytes| allocator.free(bytes);
    result.* = .{};
}

fn frozenAliases(source: *const Owner, result: *const Frozen) bool {
    const output = std.mem.asBytes(result);
    return overlaps(std.mem.asBytes(source), output) or (source.bytes != null and overlaps(source.bytes.?, output));
}

fn aliases(context: *const context_mod.Context, verdict: *const verdict_mod.Verdict, result: *const Owner) bool {
    const output = std.mem.asBytes(result);
    const inputs = [_][]const u8{
        std.mem.asBytes(context), std.mem.asBytes(verdict), context.repository.owner,   context.repository.name,
        context.tag,              context.source_commit,    context.build.workflow_ref,
    };
    for (inputs, 0..) |input, index| {
        if (overlaps(output, input)) return true;
        for (inputs[0..index]) |prior| if (overlaps(input, prior)) return true;
    }
    return false;
}

fn ownerSeal(result: *const Owner) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host.remote-release-pass-record.owner.v1");
    const addresses = [_]usize{
        @intFromPtr(result),
        if (result.context_owner) |value| @intFromPtr(value) else 0,
        if (result.verdict_owner) |value| @intFromPtr(value) else 0,
        if (result.bytes) |value| @intFromPtr(value.ptr) else 0,
    };
    hash.update(std.mem.asBytes(&addresses));
    if (result.bytes) |bytes| {
        hash.update(std.mem.asBytes(&bytes.len));
        hash.update(bytes);
    }
    var seal: [32]u8 = undefined;
    hash.final(&seal);
    return seal;
}

fn frozenSeal(result: *const Frozen) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update("maru.session-host.remote-release-pass-record.frozen.v1");
    const addresses = [_]usize{ @intFromPtr(result), if (result.bytes) |value| @intFromPtr(value.ptr) else 0 };
    hash.update(std.mem.asBytes(&addresses));
    hash.update(&result.sha256);
    if (result.bytes) |bytes| {
        hash.update(std.mem.asBytes(&bytes.len));
        hash.update(bytes);
    }
    var seal: [32]u8 = undefined;
    hash.final(&seal);
    return seal;
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return @intFromPtr(a.ptr) < @intFromPtr(b.ptr) + b.len and @intFromPtr(b.ptr) < @intFromPtr(a.ptr) + a.len;
}
