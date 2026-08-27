//! Strict semantic parsers for GitHub Git ref and annotated-tag REST responses.
//!
//! These leaves preserve whether each object points to a commit or another tag. They do not choose
//! a traversal depth or claim that captured bytes came from GitHub; orchestration and transport are
//! separate release-adapter responsibilities.

const std = @import("std");
const github_json = @import("release_adapter_github_json");
const identity = @import("release_adapter_identity");

pub const max_response_bytes = github_json.max_response_bytes;

pub const ObjectKind = enum {
    commit,
    tag,
};

pub const Object = struct {
    kind: ObjectKind,
    sha: []const u8,
};

pub const RefObservation = struct {
    tag: []const u8,
    target: Object,
};

pub const ExpectedTag = struct {
    tag: ?[]const u8,
    object_sha: []const u8,
};

pub const TagObservation = struct {
    tag: []const u8,
    object_sha: []const u8,
    target: Object,
};

const ApiObject = struct {
    type: []const u8,
    sha: []const u8,
};

const ApiRef = struct {
    ref: []const u8,
    object: ApiObject,
};

const ApiTag = struct {
    tag: []const u8,
    sha: []const u8,
    object: ApiObject,
};

pub const Error = error{
    ResponseTooLarge,
    InvalidJson,
    IdentityMismatch,
} || std.mem.Allocator.Error;

pub const ParsedRef = struct {
    inner: std.json.Parsed(ApiRef),
    bound_observation: RefObservation,

    pub fn deinit(self: *ParsedRef) void {
        self.inner.deinit();
    }

    pub fn observation(self: *const ParsedRef) *const RefObservation {
        return &self.bound_observation;
    }
};

pub const ParsedTag = struct {
    inner: std.json.Parsed(ApiTag),
    bound_observation: TagObservation,

    pub fn deinit(self: *ParsedTag) void {
        self.inner.deinit();
    }

    pub fn observation(self: *const ParsedTag) *const TagObservation {
        return &self.bound_observation;
    }
};

/// Parses the exact `refs/tags/<tag>` object. The returned target may be a lightweight commit or
/// an annotated tag object and remains owned until `ParsedRef.deinit`.
pub fn parseRef(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected_tag: []const u8,
) Error!ParsedRef {
    github_json.validateCompleteResponse(bytes) catch |err| return err;
    if (!validTag(expected_tag)) return error.IdentityMismatch;

    var inner = try parse(ApiRef, allocator, bytes);
    errdefer inner.deinit();

    var expected_ref: [github_json.max_scalar_string_bytes]u8 = undefined;
    const ref = std.fmt.bufPrint(&expected_ref, "refs/tags/{s}", .{expected_tag}) catch
        return error.IdentityMismatch;
    const target = validateObject(inner.value.object) orelse return error.IdentityMismatch;
    if (!std.mem.eql(u8, inner.value.ref, ref)) return error.IdentityMismatch;

    return .{
        .inner = inner,
        .bound_observation = .{ .tag = inner.value.ref["refs/tags/".len..], .target = target },
    };
}

/// Parses one annotated-tag object and binds both its tag name and its own Git object SHA. The
/// target remains typed so a caller cannot silently collapse a nested tag into a commit.
pub fn parseTag(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: ExpectedTag,
) Error!ParsedTag {
    github_json.validateCompleteResponse(bytes) catch |err| return err;
    if ((expected.tag != null and !validTag(expected.tag.?)) or
        !identity.lowerHex(expected.object_sha, 40))
        return error.IdentityMismatch;

    var inner = try parse(ApiTag, allocator, bytes);
    errdefer inner.deinit();

    const target = validateObject(inner.value.object) orelse return error.IdentityMismatch;
    if (inner.value.tag.len == 0 or inner.value.tag.len > github_json.max_scalar_string_bytes or
        (expected.tag != null and !std.mem.eql(u8, inner.value.tag, expected.tag.?)) or
        !std.mem.eql(u8, inner.value.sha, expected.object_sha))
        return error.IdentityMismatch;

    return .{
        .inner = inner,
        .bound_observation = .{
            .tag = inner.value.tag,
            .object_sha = inner.value.sha,
            .target = target,
        },
    };
}

fn parse(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) Error!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
}

fn validTag(tag: []const u8) bool {
    return tag.len <= github_json.max_scalar_string_bytes and identity.canonicalTag(tag);
}

fn validateObject(object: ApiObject) ?Object {
    if (!identity.lowerHex(object.sha, 40)) return null;
    const kind: ObjectKind = if (std.mem.eql(u8, object.type, "commit"))
        .commit
    else if (std.mem.eql(u8, object.type, "tag"))
        .tag
    else
        return null;
    return .{ .kind = kind, .sha = object.sha };
}

pub fn parseRefForTest(allocator: std.mem.Allocator, bytes: []const u8, tag: []const u8) !void {
    var parsed = try parseRef(allocator, bytes, tag);
    parsed.deinit();
}

pub fn parseTagForTest(allocator: std.mem.Allocator, bytes: []const u8, expected: ExpectedTag) !void {
    var parsed = try parseTag(allocator, bytes, expected);
    parsed.deinit();
}
