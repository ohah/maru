//! Canonical pre-publish profile selection bound to one protected release run.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const identity = @import("release_adapter_identity");

pub const schema = "maru.session-host-release-profile.v1";
pub const environment_name = "MARU_SESSION_HOST_RELEASE_PROFILE_V1";
pub const max_document_bytes: usize = 1024;
pub const Profile = enum { baseline_a, upgrade_b };

pub const Environment = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, [:0]const u8) ?[]const u8,

    fn read(self: @This()) ?[]const u8 {
        return self.read_fn(self.context, environment_name);
    }
};

pub const Error = error{
    DocumentTooLarge,
    InvalidDocument,
    InvalidOwner,
    AuthorityChanged,
} || std.mem.Allocator.Error;

const Raw = struct {
    schema: []const u8,
    profile: []const u8,
    predecessor: ?manifest.Predecessor = null,
};

const ParsedValue = struct {
    selected: Profile,
    release_id: u64 = 0,
    tag: [manifest.max_scalar_string_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    commit: [40]u8 = @splat(0),
    manifest_sha256: [64]u8 = @splat(0),

    fn value(self: *const @This()) Value {
        return switch (self.selected) {
            .baseline_a => .{ .baseline_a = {} },
            .upgrade_b => .{ .upgrade_b = .{
                .release_id = self.release_id,
                .tag = self.tag[0..self.tag_len],
                .commit = &self.commit,
                .manifest_sha256 = &self.manifest_sha256,
            } },
        };
    }
};

pub const Value = union(Profile) {
    baseline_a: void,
    upgrade_b: manifest.Predecessor,

    pub fn profile(self: @This()) Profile {
        return std.meta.activeTag(self);
    }

    pub fn predecessor(self: @This()) ?manifest.Predecessor {
        return switch (self) {
            .baseline_a => null,
            .upgrade_b => |value| value,
        };
    }
};

pub const Owner = struct {
    owner: ?*@This() = null,
    selected: Profile = .baseline_a,
    release_id: u64 = 0,
    tag: [manifest.max_scalar_string_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    commit: [40]u8 = @splat(0),
    manifest_sha256: [64]u8 = @splat(0),
    document_sha256: [32]u8 = @splat(0),
    context_sha256: [32]u8 = @splat(0),
    seal: [32]u8 = @splat(0),

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and self.selected == .baseline_a and self.release_id == 0 and self.tag_len == 0 and
            allZero(&self.tag) and allZero(&self.commit) and allZero(&self.manifest_sha256) and
            allZero(&self.document_sha256) and allZero(&self.context_sha256) and allZero(&self.seal);
    }

    pub fn documentSha256(self: *const @This()) ?[32]u8 {
        if (self.owner != self or !std.mem.eql(u8, &self.seal, &ownerSeal(self))) return null;
        return self.document_sha256;
    }

    pub fn revalidateEnvironment(self: *const @This(), allocator: std.mem.Allocator, context: context_mod.Context, environment: Environment) Error!Value {
        const first = environment.read() orelse return error.AuthorityChanged;
        const validated = try self.revalidateDocument(allocator, context, first);
        const second = environment.read() orelse return error.AuthorityChanged;
        if (!std.mem.eql(u8, &self.document_sha256, &digest(second)) or !std.mem.eql(u8, first, second))
            return error.AuthorityChanged;
        return validated;
    }

    pub fn revalidateDocumentForTest(self: *const @This(), allocator: std.mem.Allocator, context: context_mod.Context, document: []const u8) Error!Value {
        if (!builtin.is_test) @compileError("revalidateDocumentForTest is test-only");
        return self.revalidateDocument(allocator, context, document);
    }

    fn revalidateDocument(self: *const @This(), allocator: std.mem.Allocator, context: context_mod.Context, document: []const u8) Error!Value {
        if (self.owner != self or overlaps(document, std.mem.asBytes(self)) or contextAliases(context, std.mem.asBytes(self)) or
            !std.mem.eql(u8, &self.seal, &ownerSeal(self))) return error.InvalidOwner;
        context_mod.validateTrusted(context) catch return error.AuthorityChanged;
        const parsed = parseCanonical(allocator, document) catch return error.AuthorityChanged;
        if (!std.mem.eql(u8, &self.document_sha256, &digest(document)) or
            !std.mem.eql(u8, &self.context_sha256, &contextDigest(context)) or
            !equal(self.value(), parsed.value())) return error.AuthorityChanged;
        return self.value();
    }

    pub fn deinit(self: *@This()) !void {
        if (self.owner != self or !std.mem.eql(u8, &self.seal, &ownerSeal(self))) return error.InvalidOwner;
        self.* = .{};
    }

    fn value(self: *const @This()) Value {
        return switch (self.selected) {
            .baseline_a => .{ .baseline_a = {} },
            .upgrade_b => .{ .upgrade_b = .{
                .release_id = self.release_id,
                .tag = self.tag[0..self.tag_len],
                .commit = &self.commit,
                .manifest_sha256 = &self.manifest_sha256,
            } },
        };
    }
};

pub fn bindFromEnvironment(allocator: std.mem.Allocator, context: context_mod.Context, environment: Environment, result: *Owner) Error!void {
    if (!result.isPristineForComposition() or contextAliases(context, std.mem.asBytes(result))) return error.InvalidOwner;
    const first = environment.read() orelse return error.InvalidDocument;
    var staged: Owner = .{};
    try bindDocument(allocator, context, first, &staged);
    errdefer staged.deinit() catch {};
    const second = environment.read() orelse return error.AuthorityChanged;
    if (!std.mem.eql(u8, &staged.document_sha256, &digest(second)) or !std.mem.eql(u8, first, second))
        return error.AuthorityChanged;
    if (!result.isPristineForComposition() or contextAliases(context, std.mem.asBytes(result)) or
        overlaps(first, std.mem.asBytes(result)) or overlaps(second, std.mem.asBytes(result))) return error.InvalidOwner;
    result.* = staged;
    result.owner = result;
    result.seal = ownerSeal(result);
    staged = .{};
}

pub fn bindDocumentForTest(allocator: std.mem.Allocator, context: context_mod.Context, document: []const u8, result: *Owner) Error!void {
    if (!builtin.is_test) @compileError("bindDocumentForTest is test-only");
    return bindDocument(allocator, context, document, result);
}

fn bindDocument(allocator: std.mem.Allocator, context: context_mod.Context, document: []const u8, result: *Owner) Error!void {
    if (!result.isPristineForComposition() or overlaps(document, std.mem.asBytes(result)) or
        contextAliases(context, std.mem.asBytes(result))) return error.InvalidOwner;
    context_mod.validateTrusted(context) catch return error.InvalidDocument;
    const parsed = try parseCanonical(allocator, document);
    if (parsed.selected == .upgrade_b and std.mem.eql(u8, parsed.tag[0..parsed.tag_len], context.tag))
        return error.InvalidDocument;
    result.selected = parsed.selected;
    result.release_id = parsed.release_id;
    result.tag_len = parsed.tag_len;
    @memcpy(result.tag[0..result.tag_len], parsed.tag[0..parsed.tag_len]);
    @memcpy(&result.commit, &parsed.commit);
    @memcpy(&result.manifest_sha256, &parsed.manifest_sha256);
    result.document_sha256 = digest(document);
    result.context_sha256 = contextDigest(context);
    result.owner = result;
    result.seal = ownerSeal(result);
}

fn parseCanonical(allocator: std.mem.Allocator, bytes: []const u8) Error!ParsedValue {
    if (bytes.len > max_document_bytes) return error.DocumentTooLarge;
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.InvalidDocument;
    var parsed = std.json.parseFromSlice(Raw, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidDocument,
    };
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.schema, schema)) return error.InvalidDocument;
    const value: ParsedValue = if (std.mem.eql(u8, parsed.value.profile, "baseline_a")) blk: {
        if (parsed.value.predecessor != null) return error.InvalidDocument;
        break :blk .{ .selected = .baseline_a };
    } else if (std.mem.eql(u8, parsed.value.profile, "upgrade_b")) blk: {
        const predecessor = parsed.value.predecessor orelse return error.InvalidDocument;
        if (predecessor.release_id == 0 or predecessor.tag.len > manifest.max_scalar_string_bytes or
            !identity.canonicalTag(predecessor.tag) or !identity.lowerHex(predecessor.commit, 40) or
            !identity.lowerHex(predecessor.manifest_sha256, 64)) return error.InvalidDocument;
        var result: ParsedValue = .{ .selected = .upgrade_b, .release_id = predecessor.release_id, .tag_len = predecessor.tag.len };
        @memcpy(result.tag[0..result.tag_len], predecessor.tag);
        @memcpy(&result.commit, predecessor.commit);
        @memcpy(&result.manifest_sha256, predecessor.manifest_sha256);
        break :blk result;
    } else return error.InvalidDocument;

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    switch (value.value()) {
        .baseline_a => json.write(.{ .schema = schema, .profile = "baseline_a" }) catch return error.OutOfMemory,
        .upgrade_b => |predecessor| json.write(.{ .schema = schema, .profile = "upgrade_b", .predecessor = predecessor }) catch return error.OutOfMemory,
    }
    output.writer.writeByte('\n') catch return error.OutOfMemory;
    if (!std.mem.eql(u8, bytes, output.written())) return error.InvalidDocument;
    return value;
}

fn contextDigest(context: context_mod.Context) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashInteger(&hash, context.repository.id);
    hashScalar(&hash, context.repository.owner);
    hashScalar(&hash, context.repository.name);
    hashScalar(&hash, context.tag);
    hashScalar(&hash, context.source_commit);
    hashScalar(&hash, context.build.workflow_ref);
    hashInteger(&hash, context.build.run_id);
    hashInteger(&hash, context.build.run_attempt);
    hashScalar(&hash, if (context.protected_tag) "true" else "false");
    return hash.finalResult();
}

fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn ownerSeal(owner: *const Owner) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update(std.mem.asBytes(&owner.selected));
    hash.update(std.mem.asBytes(&owner.release_id));
    hash.update(std.mem.asBytes(&owner.tag_len));
    hash.update(&owner.tag);
    hash.update(&owner.commit);
    hash.update(&owner.manifest_sha256);
    hash.update(&owner.document_sha256);
    hash.update(&owner.context_sha256);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn hashScalar(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, bytes.len, .big);
    hash.update(&encoded);
    hash.update(bytes);
}

fn hashInteger(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .big);
    hash.update(&encoded);
}

fn contextAliases(context: context_mod.Context, bytes: []const u8) bool {
    inline for (.{ context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref }) |value|
        if (overlaps(value, bytes)) return true;
    return false;
}

fn equal(left: Value, right: Value) bool {
    if (left.profile() != right.profile()) return false;
    const a = left.predecessor();
    const b = right.predecessor();
    if ((a == null) != (b == null)) return false;
    if (a) |av| {
        const bv = b.?;
        return av.release_id == bv.release_id and std.mem.eql(u8, av.tag, bv.tag) and
            std.mem.eql(u8, av.commit, bv.commit) and std.mem.eql(u8, av.manifest_sha256, bv.manifest_sha256);
    }
    return true;
}

fn allZero(bytes: []const u8) bool {
    return std.mem.allEqual(u8, bytes, 0);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
