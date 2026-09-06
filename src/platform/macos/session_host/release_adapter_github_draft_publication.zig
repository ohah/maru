//! Closed single-mutation boundary that publishes one fully validated GitHub draft.
//!
//! A child invocation may have changed remote state even when no response arrives. The result
//! therefore becomes terminal before exec and never offers an automatic retry path afterward.

const std = @import("std");
const builtin = @import("builtin");
const process = @import("bounded_process");
const attachment = @import("release_adapter_github_draft_asset_attachment");
const redownload = @import("release_adapter_github_draft_asset_redownload");
const deadline_mod = @import("release_adapter_deadline");
const transport = @import("release_adapter_github_transport");

pub const asset_count = attachment.asset_count;
pub const max_name_bytes = attachment.max_asset_name_bytes;
pub const max_tag_bytes = 128;

pub const Asset = struct { id: u64, name: []const u8, size: u64, sha256: [64]u8 };
pub const Snapshot = struct {
    release_id: u64,
    tag: []const u8,
    source_commit: []const u8,
    cli_sha256: [64]u8,
    assets: [asset_count]Asset,
};
pub const ObservedAsset = struct { id: u64, size: u64, sha256: [64]u8 };
pub const ObservedRelease = struct { release_id: u64, assets: [asset_count]ObservedAsset };
pub const State = enum { empty, remote_state_unknown, cleanup_required, ready };
pub const View = struct { release_id: u64, tag: []const u8, source_commit: []const u8, asset_ids: [asset_count]u64 };

pub const PublishedRelease = struct {
    owner: ?*PublishedRelease = null,
    status: State = .empty,
    release_id: u64 = 0,
    tag: [max_tag_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    asset_ids: [asset_count]u64 = @splat(0),

    pub fn state(self: *const @This()) State {
        return self.status;
    }
    pub fn cleanupId(self: *const @This()) ?u64 {
        return if (self.status == .cleanup_required and self.release_id != 0) self.release_id else null;
    }
    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or self.status != .ready or self.release_id == 0 or self.tag_len == 0) return null;
        return .{ .release_id = self.release_id, .tag = self.tag[0..self.tag_len], .source_commit = &self.source_commit, .asset_ids = self.asset_ids };
    }
    fn recordKnown(self: *@This(), snapshot: *const FrozenSnapshot) void {
        self.release_id = snapshot.release_id;
        self.tag_len = snapshot.tag_len;
        @memcpy(self.tag[0..self.tag_len], snapshot.tag[0..snapshot.tag_len]);
        self.source_commit = snapshot.source_commit;
        self.asset_ids = snapshot.ids;
        self.status = .cleanup_required;
    }
    fn publish(self: *@This()) !void {
        if (self.owner != null or self.status != .cleanup_required or self.release_id == 0 or self.tag_len == 0) return error.InvalidOwner;
        self.status = .ready;
        self.owner = self;
    }
    pub fn deinit(self: *@This()) !void {
        if (self.owner != self or self.status != .ready) return error.InvalidOwner;
        self.* = .{};
    }
};

const FrozenSnapshot = struct {
    release_id: u64,
    tag: [max_tag_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8,
    cli_sha256: [64]u8,
    ids: [asset_count]u64,
    names: [asset_count][max_name_bytes]u8 = @splat(@splat(0)),
    name_lens: [asset_count]usize = @splat(0),
    sizes: [asset_count]u64,
    sha256: [asset_count][64]u8,

    fn snapshot(self: *const @This()) Snapshot {
        var assets: [asset_count]Asset = undefined;
        for (&assets, 0..) |*asset, index| asset.* = .{ .id = self.ids[index], .name = self.names[index][0..self.name_lens[index]], .size = self.sizes[index], .sha256 = self.sha256[index] };
        return .{ .release_id = self.release_id, .tag = self.tag[0..self.tag_len], .source_commit = &self.source_commit, .cli_sha256 = self.cli_sha256, .assets = assets };
    }
};

const ProductionAuthority = struct {
    input: attachment.AuthorityInput,
    attached: *const attachment.DraftAssets,
    validated: *const redownload.RedownloadValidation,

    pub fn snapshot(self: *@This()) !Snapshot {
        const source = try redownload.snapshotValidated(self.input, self.attached, self.validated);
        const draft = self.input.draft.value() orelse return error.InvalidDraft;
        var assets: [asset_count]Asset = undefined;
        for (&assets, 0..) |*asset, index| asset.* = .{ .id = source.assets[index].id, .name = source.assets[index].name, .size = source.assets[index].size, .sha256 = source.assets[index].sha256 };
        return .{ .release_id = source.release_id, .tag = draft.tag, .source_commit = draft.source_commit, .cli_sha256 = source.cli_sha256, .assets = assets };
    }
};

const ProductionMutator = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: [:0]const u8,
    token: []const u8,
    output: []u8,

    pub fn publish(self: *@This(), expected: Snapshot, budget: i128) !ObservedRelease {
        try transport.validateToken(self.token);
        var endpoint_storage: [128:0]u8 = undefined;
        const endpoint = std.fmt.bufPrintZ(&endpoint_storage, "repos/ohah/maru/releases/{d}", .{expected.release_id}) catch return error.InvalidRequest;
        var token_storage: ["GH_TOKEN=".len + transport.max_token_bytes + 1]u8 = undefined;
        defer @memset(&token_storage, 0);
        const token_entry = std.fmt.bufPrintZ(&token_storage, "GH_TOKEN={s}", .{self.token}) catch return error.InvalidToken;
        const argv = [_:null]?[*:0]const u8{ self.executable.ptr, "api", "--method", "PATCH", "--hostname", "github.com", "--header", "Accept: application/vnd.github+json", "--header", "X-GitHub-Api-Version: 2022-11-28", endpoint.ptr, "-F", "draft=false", "-F", "prerelease=false" };
        const environment = [_:null]?[*:0]const u8{ token_entry.ptr, "GH_PROMPT_DISABLED=1" };
        const captured = try process.runCaptureEnvironmentStdout(self.io, self.executable, &argv, &environment, self.output, budget);
        return parseResponse(self.allocator, captured, expected);
    }
};

pub fn publishUntil(
    io: std.Io,
    authority_input: attachment.AuthorityInput,
    attached: *const attachment.DraftAssets,
    validated: *const redownload.RedownloadValidation,
    token: []const u8,
    output: []u8,
    deadline: *deadline_mod.Deadline,
    result: *PublishedRelease,
) !void {
    try transport.validateToken(token);
    if (output.len == 0 or output.len > transport.max_response_bytes) return error.InvalidOutput;
    const result_bytes = std.mem.asBytes(result);
    inline for (.{ std.mem.asBytes(attached), std.mem.asBytes(validated), std.mem.asBytes(authority_input.draft), std.mem.asBytes(authority_input.candidate), std.mem.asBytes(authority_input.authored), std.mem.asBytes(authority_input.evidence), std.mem.asBytes(authority_input.manifest), std.mem.asBytes(authority_input.cli.pinned), std.mem.asBytes(deadline), authority_input.paths.dmg, authority_input.paths.frozen_executable, authority_input.paths.evidence, authority_input.paths.manifest, authority_input.cli.path, token, output }) |value|
        if (overlaps(result_bytes, value)) return error.InvalidOwner;
    inline for (.{ std.mem.asBytes(attached), std.mem.asBytes(validated), std.mem.asBytes(authority_input.draft), std.mem.asBytes(authority_input.candidate), std.mem.asBytes(authority_input.authored), std.mem.asBytes(authority_input.evidence), std.mem.asBytes(authority_input.manifest), std.mem.asBytes(authority_input.cli.pinned), std.mem.asBytes(deadline), authority_input.paths.dmg, authority_input.paths.frozen_executable, authority_input.paths.evidence, authority_input.paths.manifest, authority_input.cli.path, token }) |value|
        if (overlaps(output, value)) return error.InvalidOutput;
    var authority = ProductionAuthority{ .input = authority_input, .attached = attached, .validated = validated };
    var mutator = ProductionMutator{ .io = io, .allocator = authority_input.allocator, .executable = authority_input.cli.path, .token = token, .output = output };
    try publishCore(&authority, &mutator, deadline, result);
}

pub fn publishSnapshotUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    source: anytype,
    token: []const u8,
    output: []u8,
    deadline: *deadline_mod.Deadline,
    result: *PublishedRelease,
) !void {
    if (!pristine(result)) return error.InvalidOwner;
    try transport.validateToken(token);
    if (output.len == 0 or output.len > transport.max_response_bytes) return error.InvalidOutput;
    const result_bytes = std.mem.asBytes(result);
    const source_bytes = std.mem.asBytes(source);
    inline for (.{ source_bytes, std.mem.asBytes(deadline), token, output }) |value|
        if (overlaps(result_bytes, value)) return error.InvalidOwner;
    inline for (.{ source_bytes, std.mem.asBytes(deadline), token }) |value|
        if (overlaps(output, value)) return error.InvalidOutput;
    const executable = try source.executablePath();
    inline for (.{ result_bytes, source_bytes, std.mem.asBytes(deadline), token, output }) |value|
        if (overlaps(executable, value)) return error.InvalidOwner;
    var mutator = ProductionMutator{ .io = io, .allocator = allocator, .executable = executable, .token = token, .output = output };
    try publishCore(source, &mutator, deadline, result);
}

pub const testing_api = if (builtin.is_test) struct {
    pub fn publish(authority: anytype, mutator: anytype, deadline: anytype, result: *PublishedRelease) !void {
        try publishCore(authority, mutator, deadline, result);
    }
    pub fn observe(expected: Snapshot) ObservedRelease {
        return observeExpected(expected);
    }
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, expected: Snapshot) !ObservedRelease {
        return parseResponse(allocator, bytes, expected);
    }
    pub fn checkCommand(io: std.Io, executable: [:0]const u8, token: []const u8, release_id: u64, budget: i128) !void {
        var output: [64]u8 = undefined;
        var mutator = ProductionMutator{ .io = io, .allocator = std.testing.allocator, .executable = executable, .token = token, .output = &output };
        const expected = testSnapshot(release_id);
        _ = mutator.publish(expected, budget) catch |err| {
            if (err == error.InvalidResponse) return;
            return err;
        };
        return error.InvalidResponse;
    }
} else struct {};

pub fn assertProductionBoundary() void {
    _ = &publishUntil;
    _ = &publishSnapshotUntil;
}

fn publishCore(authority: anytype, mutator: anytype, deadline: anytype, result: *PublishedRelease) !void {
    if (!pristine(result)) return error.InvalidOwner;
    _ = try deadline.remaining();
    const initial = try authority.snapshot();
    try validateSnapshot(initial);
    var fixed: FrozenSnapshot = undefined;
    freeze(&fixed, initial);
    const before = try authority.snapshot();
    if (!same(&fixed, before)) return error.AuthorityChanged;
    const budget = try deadline.remaining();
    result.status = .remote_state_unknown;
    const observed = try mutator.publish(fixed.snapshot(), budget);
    if (!sameObserved(&fixed, observed)) return error.InvalidResponse;
    result.recordKnown(&fixed);
    const after = try authority.snapshot();
    if (!same(&fixed, after)) return error.AuthorityChanged;
    _ = try deadline.remaining();
    try result.publish();
}

fn validateSnapshot(snapshot: Snapshot) !void {
    if (snapshot.release_id == 0 or snapshot.tag.len == 0 or snapshot.tag.len > max_tag_bytes or snapshot.source_commit.len != 40 or !lowerHex(snapshot.source_commit) or !lowerHex(&snapshot.cli_sha256)) return error.InvalidAuthority;
    for (snapshot.assets, 0..) |asset, index| {
        if (asset.id == 0 or asset.name.len == 0 or asset.name.len > max_name_bytes or asset.size == 0 or !lowerHex(&asset.sha256)) return error.InvalidAuthority;
        for (snapshot.assets[0..index]) |prior| if (asset.id == prior.id or std.mem.eql(u8, asset.name, prior.name)) return error.AssetAlias;
    }
}
fn freeze(result: *FrozenSnapshot, source: Snapshot) void {
    result.* = .{ .release_id = source.release_id, .source_commit = undefined, .cli_sha256 = source.cli_sha256, .ids = undefined, .sizes = undefined, .sha256 = undefined };
    result.tag_len = source.tag.len;
    @memcpy(result.tag[0..source.tag.len], source.tag);
    @memcpy(&result.source_commit, source.source_commit);
    for (source.assets, 0..) |asset, index| {
        result.ids[index] = asset.id;
        result.name_lens[index] = asset.name.len;
        @memcpy(result.names[index][0..asset.name.len], asset.name);
        result.sizes[index] = asset.size;
        result.sha256[index] = asset.sha256;
    }
}
fn same(fixed: *const FrozenSnapshot, observed: Snapshot) bool {
    if (fixed.release_id != observed.release_id or !std.mem.eql(u8, fixed.tag[0..fixed.tag_len], observed.tag) or !std.mem.eql(u8, &fixed.source_commit, observed.source_commit) or !std.mem.eql(u8, &fixed.cli_sha256, &observed.cli_sha256)) return false;
    for (observed.assets, 0..) |asset, index| {
        if (fixed.ids[index] != asset.id or fixed.sizes[index] != asset.size or !std.mem.eql(u8, fixed.names[index][0..fixed.name_lens[index]], asset.name) or !std.mem.eql(u8, &fixed.sha256[index], &asset.sha256)) return false;
    }
    return true;
}
fn sameObserved(fixed: *const FrozenSnapshot, observed: ObservedRelease) bool {
    if (fixed.release_id != observed.release_id) return false;
    for (observed.assets, 0..) |asset, index| if (fixed.ids[index] != asset.id or fixed.sizes[index] != asset.size or !std.mem.eql(u8, &fixed.sha256[index], &asset.sha256)) return false;
    return true;
}

const StrictU64 = struct {
    value: u64,
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !StrictU64 {
        if (try source.peekNextTokenType() != .number) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse(u64, allocator, source, options) };
    }
};
const ApiAsset = struct { id: StrictU64, name: []const u8, size: StrictU64, state: []const u8, digest: []const u8, content_type: []const u8 };
const ApiRelease = struct { id: StrictU64, tag_name: []const u8, target_commitish: []const u8, draft: bool, prerelease: bool, immutable: bool, assets: []ApiAsset };

fn parseResponse(allocator: std.mem.Allocator, bytes: []const u8, expected: Snapshot) !ObservedRelease {
    if (bytes.len == 0 or bytes.len > transport.max_response_bytes) return error.InvalidResponse;
    var parsed = std.json.parseFromSlice(ApiRelease, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true, .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    const value = parsed.value;
    if (value.id.value != expected.release_id or !std.mem.eql(u8, value.tag_name, expected.tag) or !std.mem.eql(u8, value.target_commitish, expected.source_commit) or value.draft or value.prerelease or !value.immutable or value.assets.len != asset_count) return error.InvalidResponse;
    var seen: [asset_count]bool = @splat(false);
    var result = ObservedRelease{ .release_id = value.id.value, .assets = undefined };
    for (value.assets) |asset| {
        var matched: ?usize = null;
        for (expected.assets, 0..) |candidate, index| if (candidate.id == asset.id.value) {
            matched = index;
            break;
        };
        const index = matched orelse return error.InvalidResponse;
        if (seen[index] or asset.size.value != expected.assets[index].size or !std.mem.eql(u8, asset.name, expected.assets[index].name) or !std.mem.eql(u8, asset.state, "uploaded") or !std.mem.eql(u8, asset.content_type, "application/octet-stream")) return error.InvalidResponse;
        var digest_storage: ["sha256:".len + 64]u8 = undefined;
        const digest = std.fmt.bufPrint(&digest_storage, "sha256:{s}", .{expected.assets[index].sha256}) catch unreachable;
        if (!std.mem.eql(u8, asset.digest, digest)) return error.InvalidResponse;
        seen[index] = true;
        result.assets[index] = .{ .id = asset.id.value, .size = asset.size.value, .sha256 = expected.assets[index].sha256 };
    }
    for (seen) |present| if (!present) return error.InvalidResponse;
    return result;
}

fn observeExpected(expected: Snapshot) ObservedRelease {
    var result = ObservedRelease{ .release_id = expected.release_id, .assets = undefined };
    for (&result.assets, 0..) |*asset, index| asset.* = .{ .id = expected.assets[index].id, .size = expected.assets[index].size, .sha256 = expected.assets[index].sha256 };
    return result;
}
fn testSnapshot(release_id: u64) Snapshot {
    const empty_asset = Asset{ .id = 1, .name = "x", .size = 1, .sha256 = [_]u8{'a'} ** 64 };
    return .{ .release_id = release_id, .tag = "v1.2.3", .source_commit = "0123456789abcdef0123456789abcdef01234567", .cli_sha256 = [_]u8{'f'} ** 64, .assets = @splat(empty_asset) };
}
fn pristine(result: *const PublishedRelease) bool {
    return result.owner == null and result.status == .empty and result.release_id == 0 and result.tag_len == 0 and std.mem.allEqual(u8, &result.tag, 0) and std.mem.allEqual(u8, &result.source_commit, 0) and std.mem.allEqual(u64, &result.asset_ids, 0);
}
fn lowerHex(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
