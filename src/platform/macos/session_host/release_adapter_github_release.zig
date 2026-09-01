//! Strict semantic parser for GitHub release REST responses used by the release adapter.
//!
//! GitHub may add response fields, so unknown fields remain compatible. Required trust fields are
//! wire-typed and duplicate-free; optional `immutable` preserves absence as a distinct state. All
//! observed identity is bound to an already validated expectation. This module does not
//! authenticate transport.

const std = @import("std");
const github_json = @import("release_adapter_github_json");
const identity = @import("release_adapter_identity");

pub const max_response_bytes = github_json.max_response_bytes;

pub const Publication = enum {
    draft,
    published_immutable,
};

pub const Expected = struct {
    id: u64,
    tag: []const u8,
    publication: Publication,
};

pub const Observation = struct {
    id: u64,
    tag: []const u8,
    publication: Publication,
};

const StrictU64 = struct {
    value: u64,

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !StrictU64 {
        // Zig's generic JSON integer parser also accepts quoted integers. GitHub's schema does
        // not, and keeping the wire distinction prevents a loose proxy response becoming trust.
        if (try source.peekNextTokenType() != .number) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse(u64, allocator, source, options) };
    }
};

const StrictOptionalBool = struct {
    present: bool = false,
    value: bool = false,

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !StrictOptionalBool {
        const token_type = try source.peekNextTokenType();
        if (token_type != .true and token_type != .false) return error.UnexpectedToken;
        return .{
            .present = true,
            .value = try std.json.innerParse(bool, allocator, source, options),
        };
    }
};

const ApiRelease = struct {
    id: StrictU64,
    tag_name: []const u8,
    target_commitish: ?[]const u8 = null,
    name: ?[]const u8 = null,
    draft: bool,
    prerelease: bool,
    // GitHub's OpenAPI exposes this property but does not list it as required. Absence is harmless
    // for a draft, while an immutable predecessor must carry explicit positive evidence.
    immutable: StrictOptionalBool = .{},
};

pub const CreatedExpected = struct {
    tag: []const u8,
    source_commit: []const u8,
    title: []const u8,
};

pub const CreatedObservation = struct {
    id: u64,
    tag: []const u8,
    source_commit: []const u8,
    title: []const u8,
};

pub const Error = error{
    ResponseTooLarge,
    InvalidJson,
    ReleaseMismatch,
} || std.mem.Allocator.Error;

pub const Parsed = struct {
    inner: std.json.Parsed(ApiRelease),
    bound_observation: Observation,

    pub fn deinit(self: *Parsed) void {
        self.inner.deinit();
    }

    pub fn observation(self: *const Parsed) *const Observation {
        return &self.bound_observation;
    }
};

pub const ParsedDraftCollection = struct {
    inner: std.json.Parsed([]ApiRelease),
    bound_observation: Observation,

    pub fn deinit(self: *ParsedDraftCollection) void {
        self.inner.deinit();
    }

    pub fn observation(self: *const ParsedDraftCollection) *const Observation {
        return &self.bound_observation;
    }
};

pub const ParsedCreatedDraft = struct {
    inner: std.json.Parsed(ApiRelease),
    bound_observation: CreatedObservation,

    pub fn deinit(self: *ParsedCreatedDraft) void {
        self.inner.deinit();
    }

    pub fn observation(self: *const ParsedCreatedDraft) *const CreatedObservation {
        return &self.bound_observation;
    }
};

/// Binds the response of the one permitted draft-creation mutation. Unlike lookup parsing, the
/// release ID is discovered here; every caller-controlled identity still has to match exactly.
pub fn parseCreatedDraft(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: CreatedExpected,
) Error!ParsedCreatedDraft {
    github_json.validateCompleteResponse(bytes) catch |err| return err;
    if (!identity.canonicalTag(expected.tag) or !identity.lowerHex(expected.source_commit, 40) or
        expected.title.len == 0 or expected.title.len > github_json.max_scalar_string_bytes)
        return error.ReleaseMismatch;
    var inner = std.json.parseFromSlice(ApiRelease, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer inner.deinit();
    const value = inner.value;
    const target = value.target_commitish orelse return error.ReleaseMismatch;
    const title = value.name orelse return error.ReleaseMismatch;
    if (value.id.value == 0 or !std.mem.eql(u8, value.tag_name, expected.tag) or
        !std.mem.eql(u8, target, expected.source_commit) or !std.mem.eql(u8, title, expected.title) or
        !publicationMatches(value, .draft)) return error.ReleaseMismatch;
    return .{ .inner = inner, .bound_observation = .{
        .id = value.id.value,
        .tag = value.tag_name,
        .source_commit = target,
        .title = title,
    } };
}

/// Parses one complete bounded response and binds it to the exact release identity and lifecycle
/// expected by the current adapter phase. Returned slices remain valid until `Parsed.deinit`.
pub fn parseAndBind(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: Expected,
) Error!Parsed {
    github_json.validateCompleteResponse(bytes) catch |err| return err;
    if (!validExpected(expected) or expected.publication != .published_immutable) return error.ReleaseMismatch;

    var inner = std.json.parseFromSlice(ApiRelease, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer inner.deinit();

    const value = inner.value;
    if (expected.id == 0 or value.id.value == 0 or value.id.value != expected.id or
        !std.mem.eql(u8, value.tag_name, expected.tag) or
        !publicationMatches(value, expected.publication))
        return error.ReleaseMismatch;

    return .{
        .inner = inner,
        .bound_observation = .{
            .id = value.id.value,
            .tag = value.tag_name,
            .publication = expected.publication,
        },
    };
}

/// Draft releases are not returned by GitHub's release-by-tag endpoint. An authenticated caller
/// with push access must consume the complete paginated release listing and find one exact ID/tag
/// pair; response order and "latest" position are never authority.
pub fn parseDraftCollectionAndBind(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: Expected,
) Error!ParsedDraftCollection {
    github_json.validateCompleteResponse(bytes) catch |err| return err;
    if (!validExpected(expected) or expected.publication != .draft) return error.ReleaseMismatch;

    var inner = std.json.parseFromSlice([]ApiRelease, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer inner.deinit();

    var matched: ?usize = null;
    for (inner.value, 0..) |value, index| {
        if (value.id.value == 0) return error.ReleaseMismatch;
        const same_id = value.id.value == expected.id;
        const same_tag = std.mem.eql(u8, value.tag_name, expected.tag);
        if (same_id != same_tag) return error.ReleaseMismatch;
        if (same_id) {
            if (matched != null or !publicationMatches(value, .draft)) return error.ReleaseMismatch;
            matched = index;
        }
    }
    const index = matched orelse return error.ReleaseMismatch;
    return .{
        .inner = inner,
        .bound_observation = .{
            .id = inner.value[index].id.value,
            .tag = inner.value[index].tag_name,
            .publication = .draft,
        },
    };
}

fn validExpected(expected: Expected) bool {
    return expected.id != 0 and
        expected.tag.len <= github_json.max_scalar_string_bytes and
        identity.canonicalTag(expected.tag);
}

fn publicationMatches(value: ApiRelease, expected: Publication) bool {
    // Maru ships full releases only. A candidate must still be a mutable draft; a predecessor
    // must be published and immutable. No absent/unknown state is weakened into either verdict.
    if (value.prerelease) return false;
    return switch (expected) {
        .draft => value.draft and (!value.immutable.present or !value.immutable.value),
        .published_immutable => !value.draft and value.immutable.present and value.immutable.value,
    };
}

/// Public only so std's allocation-failure harness can cover the complete successful path.
pub fn parseAndBindForTest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: Expected,
) !void {
    var parsed = try parseAndBind(allocator, bytes, expected);
    parsed.deinit();
}

pub fn parseDraftCollectionAndBindForTest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: Expected,
) !void {
    var parsed = try parseDraftCollectionAndBind(allocator, bytes, expected);
    parsed.deinit();
}
