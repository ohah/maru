//! GitHub-generated release attestation verification for a release and its local assets.

const std = @import("std");
const release_manifest = @import("release_manifest");
const identity = @import("release_adapter_identity");
const github_json = @import("release_adapter_github_json");
const process = @import("bounded_process");

pub const max_response_bytes = github_json.max_response_bytes;
pub const max_token_bytes = github_json.max_scalar_string_bytes;
pub const max_args: usize = 8;
const max_arg_bytes = github_json.max_scalar_string_bytes + 1;
const max_assets = @typeInfo(release_manifest.AssetRole).@"enum".fields.len;

pub const Expected = struct {
    repository: release_manifest.Repository,
    release_id: u64,
    tag: []const u8,
    tag_ref_sha: []const u8,
    assets: []const release_manifest.Asset,
};

pub const AssetCommand = struct {
    path: []const u8,
    expected: release_manifest.Asset,
};

pub const Command = union(enum) {
    release,
    asset: AssetCommand,
};

pub const ArgsStorage = [max_args][]const u8;
pub const Plan = struct { args: []const []const u8 };

pub const Observed = struct {
    parsed: std.json.Parsed(std.json.Value),
    verified: bool,
    release_id: u64,
    tag: []const u8,
    tag_ref_sha: []const u8,
    asset_count: usize,

    pub fn deinit(self: *Observed) void {
        self.parsed.deinit();
    }
};

pub const Error = error{
    InvalidExpected,
    InvalidPath,
    AssetMismatch,
    InvalidToken,
    InvalidBudget,
    InvalidCapture,
    ResponseTooLarge,
    InvalidJson,
    AttestationMismatch,
} || std.mem.Allocator.Error || process.Error;

pub fn plan(storage: *ArgsStorage, command: Command, expected: Expected) Error!Plan {
    try validateExpected(expected);
    storage[0] = "release";
    var used: usize = 0;
    switch (command) {
        .release => {
            storage[1] = "verify";
            storage[2] = expected.tag;
            used = 3;
        },
        .asset => |asset| {
            if (!std.fs.path.isAbsolute(asset.path) or !validScalar(asset.path)) return error.InvalidPath;
            if (!std.mem.eql(u8, std.fs.path.basename(asset.path), asset.expected.name)) return error.AssetMismatch;
            if (!containsAsset(expected.assets, asset.expected)) return error.AssetMismatch;
            storage[1] = "verify-asset";
            storage[2] = expected.tag;
            storage[3] = asset.path;
            used = 4;
        },
    }
    const suffix = [_][]const u8{ "--repo", "ohah/maru", "--format", "json" };
    for (suffix, 0..) |value, index| storage[used + index] = value;
    used += suffix.len;
    return .{ .args = storage[0..used] };
}

pub fn parseAndBind(allocator: std.mem.Allocator, bytes: []const u8, expected: Expected) Error!Observed {
    try validateExpected(expected);
    github_json.validateCompleteResponse(bytes) catch |err| switch (err) {
        error.ResponseTooLarge => return error.ResponseTooLarge,
        error.InvalidJson => return error.InvalidJson,
    };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer parsed.deinit();
    const root = try object(parsed.value);
    const result = try objectField(root, "verificationResult");
    const signature = try objectField(result, "signature");
    const certificate = try objectField(signature, "certificate");
    try requireString(certificate, "subjectAlternativeName", "https://dotcom.releases.github.com");

    const statement = try objectField(result, "statement");
    try requireString(statement, "_type", "https://in-toto.io/Statement/v1");
    try requireString(statement, "predicateType", "https://in-toto.io/attestation/release/v0.1");

    var purl_storage: [github_json.max_scalar_string_bytes]u8 = undefined;
    const purl = std.fmt.bufPrint(&purl_storage, "pkg:github/ohah/maru@{s}", .{expected.tag}) catch return error.InvalidExpected;
    var repository_id_storage: [32]u8 = undefined;
    const repository_id = std.fmt.bufPrint(&repository_id_storage, "{d}", .{expected.repository.id}) catch return error.InvalidExpected;
    var release_id_storage: [32]u8 = undefined;
    const release_id = std.fmt.bufPrint(&release_id_storage, "{d}", .{expected.release_id}) catch return error.InvalidExpected;

    const predicate = try objectField(statement, "predicate");
    _ = try parseCanonicalPositiveDecimal(try stringField(predicate, "ownerId"));
    try requireString(predicate, "purl", purl);
    const observed_release_id_text = try stringField(predicate, "releaseId");
    if (!std.mem.eql(u8, observed_release_id_text, release_id)) return error.AttestationMismatch;
    const observed_release_id = try parseCanonicalPositiveDecimal(observed_release_id_text);
    try requireString(predicate, "repository", "ohah/maru");
    try requireString(predicate, "repositoryId", repository_id);
    const observed_tag = try stringField(predicate, "tag");
    if (!std.mem.eql(u8, observed_tag, expected.tag)) return error.AttestationMismatch;

    const subjects = try arrayField(statement, "subject");
    if (subjects.items.len != expected.assets.len + 1) return error.AttestationMismatch;
    var purl_seen = false;
    var seen_assets: [max_assets]bool = @splat(false);
    for (subjects.items) |subject_value| {
        const subject = try object(subject_value);
        if (subject.get("uri")) |uri_value| {
            if (purl_seen or subject.get("name") != null or uri_value != .string or !std.mem.eql(u8, uri_value.string, purl))
                return error.AttestationMismatch;
            const digest = try objectField(subject, "digest");
            if (digest.count() != 1) return error.AttestationMismatch;
            try requireString(digest, "sha1", expected.tag_ref_sha);
            purl_seen = true;
            continue;
        }
        if (subject.get("name") == null or subject.get("uri") != null) return error.AttestationMismatch;
        const name = try stringField(subject, "name");
        const digest = try objectField(subject, "digest");
        if (digest.count() != 1) return error.AttestationMismatch;
        const sha256 = try stringField(digest, "sha256");
        const index = assetIndex(expected.assets, name, sha256) orelse return error.AttestationMismatch;
        if (seen_assets[index]) return error.AttestationMismatch;
        seen_assets[index] = true;
    }
    if (!purl_seen) return error.AttestationMismatch;
    for (seen_assets[0..expected.assets.len]) |seen| if (!seen) return error.AttestationMismatch;

    const timestamps = try arrayField(result, "verifiedTimestamps");
    if (timestamps.items.len == 0) return error.AttestationMismatch;
    for (timestamps.items) |timestamp_value| {
        const timestamp = try object(timestamp_value);
        for ([_][]const u8{ "type", "uri", "timestamp" }) |name| {
            if (!validScalar(try stringField(timestamp, name))) return error.AttestationMismatch;
        }
    }
    return .{
        .parsed = parsed,
        .verified = true,
        .release_id = observed_release_id,
        .tag = observed_tag,
        .tag_ref_sha = try purlDigest(statement),
        .asset_count = expected.assets.len,
    };
}

pub fn verifyWith(executor: anytype, allocator: std.mem.Allocator, executable: []const u8, token: []const u8, command: Command, expected: Expected, output: []u8, budget_ns: i128) !Observed {
    if (!validScalar(token)) return error.InvalidToken;
    if (budget_ns <= 0) return error.InvalidBudget;
    if (output.len == 0 or output.len > max_response_bytes) return error.ResponseTooLarge;
    var args_storage: ArgsStorage = undefined;
    const request = try plan(&args_storage, command, expected);
    var token_storage: ["GH_TOKEN=".len + max_token_bytes]u8 = undefined;
    const token_entry = std.fmt.bufPrint(&token_storage, "GH_TOKEN={s}", .{token}) catch return error.InvalidToken;
    const environment = [_][]const u8{ token_entry, "GH_PROMPT_DISABLED=1" };
    const captured = try executor.capture(executable, request.args, &environment, output, budget_ns);
    if (!borrowedFrom(captured, output)) return error.InvalidCapture;
    return parseAndBind(allocator, captured, expected);
}

pub fn verify(io: std.Io, allocator: std.mem.Allocator, executable: []const u8, token: []const u8, command: Command, expected: Expected, output: []u8, budget_ns: i128) !Observed {
    var executor = BoundedExecutor{ .io = io };
    return verifyWith(&executor, allocator, executable, token, command, expected, output, budget_ns);
}

const BoundedExecutor = struct {
    io: std.Io,
    fn capture(self: *@This(), executable: []const u8, child_args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) Error![]const u8 {
        var executable_storage: [max_token_bytes + 1]u8 = undefined;
        const executable_z = std.fmt.bufPrintZ(&executable_storage, "{s}", .{executable}) catch return error.InvalidPath;
        var argument_storage: [max_args][max_arg_bytes]u8 = undefined;
        var argv: [max_args + 1:null]?[*:0]const u8 = @splat(null);
        argv[0] = executable_z.ptr;
        for (child_args, 0..) |arg, index| argv[index + 1] = (std.fmt.bufPrintZ(&argument_storage[index], "{s}", .{arg}) catch return error.InvalidExpected).ptr;
        var environment_storage: [2]["GH_TOKEN=".len + max_token_bytes + 1]u8 = undefined;
        var envp: [2:null]?[*:0]const u8 = @splat(null);
        for (environment, 0..) |entry, index| envp[index] = (std.fmt.bufPrintZ(&environment_storage[index], "{s}", .{entry}) catch return error.InvalidToken).ptr;
        return process.runCaptureEnvironmentStdout(self.io, executable_z, &argv, &envp, output, budget_ns);
    }
};

fn validateExpected(expected: Expected) Error!void {
    if (expected.repository.id == 0 or !std.mem.eql(u8, expected.repository.owner, "ohah") or !std.mem.eql(u8, expected.repository.name, "maru") or expected.release_id == 0 or !identity.canonicalTag(expected.tag) or !identity.lowerHex(expected.tag_ref_sha, 40) or expected.assets.len != max_assets) return error.InvalidExpected;
    var role_counts: [max_assets]u8 = @splat(0);
    for (expected.assets, 0..) |asset, index| {
        if (!basename(asset.name) or !identity.lowerHex(asset.sha256, 64) or asset.size == 0) return error.InvalidExpected;
        role_counts[@intFromEnum(asset.role)] += 1;
        for (expected.assets[index + 1 ..]) |other| if (std.mem.eql(u8, asset.name, other.name)) return error.InvalidExpected;
    }
    for (role_counts) |count| if (count != 1) return error.InvalidExpected;
}

fn purlDigest(statement: std.json.ObjectMap) Error![]const u8 {
    const subjects = try arrayField(statement, "subject");
    for (subjects.items) |subject_value| {
        const subject = try object(subject_value);
        if (subject.get("uri") != null) return stringField(try objectField(subject, "digest"), "sha1");
    }
    return error.AttestationMismatch;
}

fn assetIndex(assets_value: []const release_manifest.Asset, name: []const u8, sha256: []const u8) ?usize {
    for (assets_value, 0..) |asset, index| if (std.mem.eql(u8, asset.name, name) and std.mem.eql(u8, asset.sha256, sha256)) return index;
    return null;
}

fn containsAsset(assets_value: []const release_manifest.Asset, candidate: release_manifest.Asset) bool {
    for (assets_value) |asset| if (asset.role == candidate.role and asset.size == candidate.size and std.mem.eql(u8, asset.name, candidate.name) and std.mem.eql(u8, asset.sha256, candidate.sha256)) return true;
    return false;
}

fn parseCanonicalPositiveDecimal(value: []const u8) Error!u64 {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return error.AttestationMismatch;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return error.AttestationMismatch;
    const parsed = std.fmt.parseInt(u64, value, 10) catch return error.AttestationMismatch;
    if (parsed == 0) return error.AttestationMismatch;
    return parsed;
}

fn basename(value: []const u8) bool {
    return validScalar(value) and std.mem.eql(u8, value, std.fs.path.basename(value));
}
fn validScalar(value: []const u8) bool {
    if (value.len == 0 or value.len > max_token_bytes) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
fn object(value: std.json.Value) Error!std.json.ObjectMap {
    return if (value == .object) value.object else error.AttestationMismatch;
}
fn objectField(map: std.json.ObjectMap, name: []const u8) Error!std.json.ObjectMap {
    return object(map.get(name) orelse return error.AttestationMismatch);
}
fn arrayField(map: std.json.ObjectMap, name: []const u8) Error!std.json.Array {
    const value = map.get(name) orelse return error.AttestationMismatch;
    return if (value == .array) value.array else error.AttestationMismatch;
}
fn stringField(map: std.json.ObjectMap, name: []const u8) Error![]const u8 {
    const value = map.get(name) orelse return error.AttestationMismatch;
    return if (value == .string) value.string else error.AttestationMismatch;
}
fn requireString(map: std.json.ObjectMap, name: []const u8, expected: []const u8) Error!void {
    if (!std.mem.eql(u8, try stringField(map, name), expected)) return error.AttestationMismatch;
}
fn borrowedFrom(captured: []const u8, supplied: []const u8) bool {
    const start = @intFromPtr(supplied.ptr);
    const end = std.math.add(usize, start, supplied.len) catch return false;
    const captured_start = @intFromPtr(captured.ptr);
    const captured_end = std.math.add(usize, captured_start, captured.len) catch return false;
    return captured_start >= start and captured_end <= end;
}
