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
    draft: bool,
    prerelease: bool,
    // GitHub's OpenAPI exposes this property but does not list it as required. Absence is harmless
    // for a draft, while an immutable predecessor must carry explicit positive evidence.
    immutable: StrictOptionalBool = .{},
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

/// Parses one complete bounded response and binds it to the exact release identity and lifecycle
/// expected by the current adapter phase. Returned slices remain valid until `Parsed.deinit`.
pub fn parseAndBind(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: Expected,
) Error!Parsed {
    github_json.validateCompleteResponse(bytes) catch |err| return err;
    if (!validExpected(expected)) return error.ReleaseMismatch;

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
