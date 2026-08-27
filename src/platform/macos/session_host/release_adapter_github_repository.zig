//! Strict semantic parser for the GitHub repository REST response used by the release adapter.
//!
//! The API may add fields, so unknown fields are ignored. The four identity fields we consume are
//! still required, typed, duplicate-free, internally consistent, and bound to the trusted Actions
//! context. This module validates already-captured bytes; it does not authenticate their transport.

const std = @import("std");
const release_manifest = @import("release_manifest");

pub const max_response_bytes: usize = 64 * 1024;

const ApiOwner = struct {
    login: []const u8,
};

const StrictU64 = struct {
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

const ApiRepository = struct {
    id: StrictU64,
    name: []const u8,
    full_name: []const u8,
    owner: ApiOwner,
};

pub const Error = error{
    ResponseTooLarge,
    InvalidJson,
    RepositoryMismatch,
} || std.mem.Allocator.Error;

pub const Parsed = struct {
    inner: std.json.Parsed(ApiRepository),
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
    if (bytes.len > max_response_bytes) return error.ResponseTooLarge;
    try preflight(bytes);

    var inner = std.json.parseFromSlice(ApiRepository, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer inner.deinit();

    const value = inner.value;
    if (value.id.value == 0 or expected.id == 0 or
        value.id.value != expected.id or
        !std.mem.eql(u8, value.owner.login, expected.owner) or
        !std.mem.eql(u8, value.name, expected.name) or
        !fullNameMatches(value.full_name, value.owner.login, value.name))
        return error.RepositoryMismatch;

    return .{
        .inner = inner,
        .bound_repository = .{
            .id = value.id.value,
            .owner = value.owner.login,
            .name = value.name,
        },
    };
}

fn fullNameMatches(full_name: []const u8, owner: []const u8, name: []const u8) bool {
    if (owner.len == 0 or name.len == 0) return false;
    if (full_name.len != owner.len + 1 + name.len) return false;
    return std.mem.eql(u8, full_name[0..owner.len], owner) and
        full_name[owner.len] == '/' and
        std.mem.eql(u8, full_name[owner.len + 1 ..], name);
}

fn preflight(bytes: []const u8) Error!void {
    // The typed parser stops after its first root value. Fully draining a complete-input scanner
    // first rejects a second root/trailing garbage and bounds nesting scratch independently of the
    // caller allocator. Scalar allocation is capped by the manifest scalar SSOT.
    var scratch: [max_response_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), bytes);
    defer scanner.deinit();
    while (true) {
        const token = scanner.nextAllocMax(
            fixed.allocator(),
            .alloc_if_needed,
            release_manifest.max_scalar_string_bytes,
        ) catch return error.InvalidJson;
        if (token == .end_of_document) {
            // Scanner reports the first complete root as end-of-document without promising that
            // the complete-input slice was exhausted, so bind the verdict to the final byte too.
            if (scanner.cursor != bytes.len) return error.InvalidJson;
            return;
        }
    }
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
