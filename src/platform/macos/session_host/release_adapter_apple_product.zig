//! Semantic boundary for Apple product observations used by the release adapter.
//!
//! The executable adapter owns command execution. This module consumes only bounded captures and
//! explicit success receipts, then derives the manifest `Signing` value instead of trusting one
//! assembled by workflow shell.

const std = @import("std");
const release_manifest = @import("release_manifest");
const product_identity = @import("product_identity");

pub const max_capture_bytes: usize = 16 * 1024;
pub const product_bundle_id = product_identity.bundle_id;
pub const product_bundle_version = product_identity.bundle_version;
const required_architectures = [_][]const u8{ "arm64", "x86_64" };

pub const Captures = struct {
    executable_sha256: []const u8,
    plist_json: []const u8,
    codesign_detail: []const u8,
    designated_requirement: []const u8,
    architectures: []const u8,
    strict_signature_verified: bool,
    app_staple_verified: bool,
    dmg_staple_verified: bool,
    dmg_gatekeeper_verified: bool,
};

pub const Error = error{
    CaptureTooLarge,
    InvalidDigest,
    InvalidPlist,
    InvalidCodesignDetail,
    InvalidRequirement,
    InvalidArchitectures,
    InvalidScalar,
    IdentityMismatch,
    VersionMismatch,
    UnverifiedProduct,
} || std.mem.Allocator.Error;

const WirePlist = struct {
    CFBundleIdentifier: []const u8,
    CFBundleShortVersionString: []const u8,
    CFBundleVersion: []const u8,
};

pub const Observed = struct {
    executable_sha256: [64]u8,
    bundle_id: []u8,
    bundle_short_version: []u8,
    bundle_version: []u8,
    team_id: []u8,
    requirement_sha256: [64]u8,

    pub fn deinit(self: *Observed, allocator: std.mem.Allocator) void {
        allocator.free(self.bundle_id);
        allocator.free(self.bundle_short_version);
        allocator.free(self.bundle_version);
        allocator.free(self.team_id);
        self.* = undefined;
    }

    pub fn executableSha256(self: *const Observed) []const u8 {
        return &self.executable_sha256;
    }

    pub fn signing(self: *const Observed) release_manifest.Signing {
        return .{
            .bundle_id = self.bundle_id,
            .bundle_short_version = self.bundle_short_version,
            .bundle_version = self.bundle_version,
            .team_id = self.team_id,
            .designated_requirement_sha256 = &self.requirement_sha256,
            .architectures = &required_architectures,
            .notarization = "accepted",
            .stapled = true,
        };
    }
};

pub fn parseAndBind(
    allocator: std.mem.Allocator,
    captures: Captures,
    expected_version: []const u8,
) Error!Observed {
    try validateCaps(captures);
    if (!lowerHex(captures.executable_sha256, 64)) return error.InvalidDigest;
    try scalar(expected_version);
    if (!captures.strict_signature_verified or !captures.app_staple_verified or
        !captures.dmg_staple_verified or !captures.dmg_gatekeeper_verified)
        return error.UnverifiedProduct;

    var parsed = std.json.parseFromSlice(WirePlist, allocator, captures.plist_json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPlist,
    };
    defer parsed.deinit();
    const plist = parsed.value;
    scalar(plist.CFBundleIdentifier) catch return error.InvalidPlist;
    scalar(plist.CFBundleShortVersionString) catch return error.InvalidPlist;
    scalar(plist.CFBundleVersion) catch return error.InvalidPlist;

    const identifier = detailValue(captures.codesign_detail, "Identifier=") catch
        return error.InvalidCodesignDetail;
    const team = detailValue(captures.codesign_detail, "TeamIdentifier=") catch
        return error.InvalidCodesignDetail;
    if (!validTeam(team)) return error.InvalidCodesignDetail;
    if (!std.mem.eql(u8, plist.CFBundleIdentifier, product_identity.bundle_id)) return error.IdentityMismatch;
    if (!std.mem.eql(u8, identifier, plist.CFBundleIdentifier)) return error.IdentityMismatch;
    if (!std.mem.eql(u8, plist.CFBundleShortVersionString, expected_version))
        return error.VersionMismatch;
    if (!std.mem.eql(u8, plist.CFBundleVersion, product_identity.bundle_version))
        return error.VersionMismatch;

    const requirement = requirementLine(captures.designated_requirement) catch
        return error.InvalidRequirement;
    try bindRequirement(requirement, identifier, team);
    try validateArchitectures(captures.architectures);

    var observed: Observed = undefined;
    @memcpy(&observed.executable_sha256, captures.executable_sha256);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(requirement, &digest, .{});
    observed.requirement_sha256 = std.fmt.bytesToHex(digest, .lower);
    observed.bundle_id = try allocator.dupe(u8, plist.CFBundleIdentifier);
    errdefer allocator.free(observed.bundle_id);
    observed.bundle_short_version = try allocator.dupe(u8, plist.CFBundleShortVersionString);
    errdefer allocator.free(observed.bundle_short_version);
    observed.bundle_version = try allocator.dupe(u8, plist.CFBundleVersion);
    errdefer allocator.free(observed.bundle_version);
    observed.team_id = try allocator.dupe(u8, team);
    return observed;
}

/// Public only so the standard allocation-failure harness can exercise and deinitialize success.
pub fn parseAndBindForTest(
    allocator: std.mem.Allocator,
    captures: Captures,
    expected_version: []const u8,
) !void {
    var observed = try parseAndBind(allocator, captures, expected_version);
    observed.deinit(allocator);
}

fn validateCaps(captures: Captures) Error!void {
    const values = [_][]const u8{
        captures.plist_json,
        captures.codesign_detail,
        captures.designated_requirement,
        captures.architectures,
    };
    for (values) |value| if (value.len == 0 or value.len > max_capture_bytes)
        return error.CaptureTooLarge;
}

fn detailValue(bytes: []const u8, prefix: []const u8) Error![]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        if (found != null) return error.InvalidCodesignDetail;
        const value = line[prefix.len..];
        scalar(value) catch return error.InvalidCodesignDetail;
        if (std.mem.eql(u8, value, "not set")) return error.InvalidCodesignDetail;
        found = value;
    }
    return found orelse error.InvalidCodesignDetail;
}

fn requirementLine(bytes: []const u8) Error![]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "designated =>")) continue;
        if (found != null) return error.InvalidRequirement;
        scalar(line) catch return error.InvalidRequirement;
        found = line;
    }
    return found orelse error.InvalidRequirement;
}

fn bindRequirement(line: []const u8, identifier: []const u8, team: []const u8) Error!void {
    if (!balancedQuotes(line)) return error.InvalidRequirement;
    if (indexPolicyToken(line, "or", 0, true) != null or
        indexPolicyToken(line, "not", 0, true) != null or
        indexOutsideQuotes(line, "!", 0) != null)
        return error.InvalidRequirement;
    if (indexPolicyToken(line, "anchor apple generic", 0, true) == null)
        return error.InvalidRequirement;
    const identifier_prefix = "identifier \"";
    const identifier_start = indexPolicyToken(line, identifier_prefix, 0, false) orelse
        return error.InvalidRequirement;
    if (indexPolicyToken(line, identifier_prefix, identifier_start + identifier_prefix.len, false) != null)
        return error.InvalidRequirement;
    const identifier_tail = line[identifier_start + identifier_prefix.len ..];
    const identifier_end = std.mem.indexOfScalar(u8, identifier_tail, '"') orelse
        return error.InvalidRequirement;
    if (!std.mem.eql(u8, identifier_tail[0..identifier_end], identifier))
        return error.IdentityMismatch;

    const team_prefix = "certificate leaf[subject.OU] = \"";
    const team_start = indexPolicyToken(line, team_prefix, 0, false) orelse
        return error.InvalidRequirement;
    if (indexPolicyToken(line, team_prefix, team_start + team_prefix.len, false) != null)
        return error.InvalidRequirement;
    const team_tail = line[team_start + team_prefix.len ..];
    const team_end = std.mem.indexOfScalar(u8, team_tail, '"') orelse
        return error.InvalidRequirement;
    if (!std.mem.eql(u8, team_tail[0..team_end], team)) return error.IdentityMismatch;
}

/// codesign requirement literals may themselves contain policy-looking words. Only an occurrence
/// in the requirement expression, never one inside a quoted literal, can satisfy a policy token.
fn indexOutsideQuotes(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0 or start > haystack.len) return null;
    var quoted = false;
    var escaped = false;
    var index: usize = 0;
    while (index < haystack.len) : (index += 1) {
        const byte = haystack[index];
        if (quoted and escaped) {
            escaped = false;
            continue;
        }
        if (quoted and byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '"') {
            quoted = !quoted;
            continue;
        }
        if (!quoted and index >= start and std.mem.startsWith(u8, haystack[index..], needle))
            return index;
    }
    return null;
}

fn indexPolicyToken(
    haystack: []const u8,
    needle: []const u8,
    start: usize,
    require_right_boundary: bool,
) ?usize {
    var cursor = start;
    while (indexOutsideQuotes(haystack, needle, cursor)) |index| {
        const left_ok = index == 0 or std.ascii.isWhitespace(haystack[index - 1]);
        const end = index + needle.len;
        const right_ok = !require_right_boundary or end == haystack.len or
            std.ascii.isWhitespace(haystack[end]);
        if (left_ok and right_ok) return index;
        cursor = index + 1;
    }
    return null;
}

fn balancedQuotes(value: []const u8) bool {
    var quoted = false;
    var escaped = false;
    for (value) |byte| {
        if (quoted and escaped) {
            escaped = false;
        } else if (quoted and byte == '\\') {
            escaped = true;
        } else if (byte == '"') {
            quoted = !quoted;
        }
    }
    return !quoted and !escaped;
}

fn validateArchitectures(bytes: []const u8) Error!void {
    var tokens = std.mem.tokenizeAny(u8, bytes, " \t\r\n");
    for (required_architectures) |expected| {
        const actual = tokens.next() orelse return error.InvalidArchitectures;
        if (!std.mem.eql(u8, actual, expected)) return error.InvalidArchitectures;
    }
    if (tokens.next() != null) return error.InvalidArchitectures;
}

fn validTeam(value: []const u8) bool {
    if (value.len != 10) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'A' and byte <= 'Z')) return false;
    return true;
}

fn scalar(value: []const u8) Error!void {
    if (value.len == 0 or value.len > release_manifest.max_scalar_string_bytes)
        return error.InvalidScalar;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidScalar;
}

fn lowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
