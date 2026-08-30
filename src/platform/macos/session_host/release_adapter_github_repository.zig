//! Strict semantic parser for the GitHub repository REST response used by the release adapter.
//!
//! The API may add fields, so unknown fields are ignored. The four identity fields we consume are
//! still required, typed, duplicate-free, internally consistent, and bound to the trusted Actions
//! context. This module validates already-captured bytes; it does not authenticate their transport.

const std = @import("std");
const release_manifest = @import("release_manifest");
const github_json = @import("release_adapter_github_json");

pub const max_response_bytes = github_json.max_response_bytes;

pub const WireOwner = struct {
    login: []const u8,
};

pub const StrictU64 = struct {
    value: u64,

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !StrictU64 {
        // std.json intentionally accepts a quoted integer for a Zig integer. GitHub's REST schema
        // says this field is a JSON number, so preserve that wire-level type distinction here.
        if (try source.peekNextTokenType() != .number) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse(u64, allocator, source, options) };
    }
};

pub const WireRepository = struct {
    id: StrictU64,
    name: []const u8,
    full_name: []const u8,
    owner: WireOwner,
};

pub const Error = error{
    ResponseTooLarge,
    InvalidJson,
    RepositoryMismatch,
} || std.mem.Allocator.Error;

pub const Parsed = struct {
    inner: std.json.Parsed(WireRepository),
    bound_repository: release_manifest.Repository,

    pub fn deinit(self: *Parsed) void {
        self.inner.deinit();
    }

    pub fn repository(self: *const Parsed) *const release_manifest.Repository {
        return &self.bound_repository;
    }
};

/// Parses one bounded response and binds it to the repository identity already captured from the
/// trusted workflow context. Returned string slices remain valid until `Parsed.deinit`.
pub fn parseAndBind(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: release_manifest.Repository,
) Error!Parsed {
    github_json.validateCompleteResponse(bytes) catch |err| return err;

    var inner = std.json.parseFromSlice(WireRepository, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer inner.deinit();

    const value = inner.value;
    if (!matchesWire(value, expected)) return error.RepositoryMismatch;

    return .{
        .inner = inner,
        .bound_repository = .{
            .id = value.id.value,
            .owner = value.owner.login,
            .name = value.name,
        },
    };
}

/// Shared nested repository identity check for endpoint responses that embed the same REST shape.
/// Keeping this here prevents each endpoint from weakening owner/name/full-name consistency.
pub fn matchesWire(value: WireRepository, expected: release_manifest.Repository) bool {
    return value.id.value != 0 and expected.id != 0 and
        value.id.value == expected.id and
        std.mem.eql(u8, value.owner.login, expected.owner) and
        std.mem.eql(u8, value.name, expected.name) and
        fullNameMatches(value.full_name, value.owner.login, value.name);
}

fn fullNameMatches(full_name: []const u8, owner: []const u8, name: []const u8) bool {
    if (owner.len == 0 or name.len == 0) return false;
    if (full_name.len != owner.len + 1 + name.len) return false;
    return std.mem.eql(u8, full_name[0..owner.len], owner) and
        full_name[owner.len] == '/' and
        std.mem.eql(u8, full_name[owner.len + 1 ..], name);
}

/// Public only so std's allocation-failure harness can exercise the complete successful path.
pub fn parseAndBindForTest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: release_manifest.Repository,
) !void {
    var parsed = try parseAndBind(allocator, bytes, expected);
    parsed.deinit();
}
