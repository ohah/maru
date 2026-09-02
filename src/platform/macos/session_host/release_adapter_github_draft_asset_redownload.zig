//! Exact-ID redownload validation for one already-attached GitHub draft.
//!
//! The response body is hashed while it crosses a bounded pipe. It is never accepted from a
//! pathname, retained in heap storage, or reduced to a caller-provided success predicate.

const std = @import("std");
const builtin = @import("builtin");
const process = @import("bounded_process");
const attachment = @import("release_adapter_github_draft_asset_attachment");
const deadline_mod = @import("release_adapter_deadline");
const transport = @import("release_adapter_github_transport");

pub const asset_count = attachment.asset_count;
pub const max_asset_name_bytes = attachment.max_asset_name_bytes;

pub const ExpectedAsset = struct {
    id: u64,
    name: []const u8,
    size: u64,
    sha256: [64]u8,
    device: u64,
    inode: u64,
    fd: std.c.fd_t,
};
pub const Snapshot = struct { release_id: u64, cli_sha256: [64]u8, assets: [asset_count]ExpectedAsset };
pub const ObservedAsset = struct { id: u64, size: u64, sha256: [64]u8 };
pub const State = enum { empty, ready };
pub const View = struct { release_id: u64, asset_ids: [asset_count]u64 };

pub const RedownloadValidation = struct {
    owner: ?*RedownloadValidation = null,
    status: State = .empty,
    release_id: u64 = 0,
    asset_ids: [asset_count]u64 = @splat(0),

    pub fn state(self: *const @This()) State {
        return self.status;
    }
    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or self.status != .ready or self.release_id == 0) return null;
        return .{ .release_id = self.release_id, .asset_ids = self.asset_ids };
    }
    fn publish(self: *@This(), release_id: u64, asset_ids: [asset_count]u64) !void {
        if (!pristine(self)) return error.InvalidOwner;
        if (release_id == 0) return error.InvalidOwner;
        self.release_id = release_id;
        self.asset_ids = asset_ids;
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
    cli_sha256: [64]u8,
    ids: [asset_count]u64,
    names: [asset_count][max_asset_name_bytes]u8 = @splat(@splat(0)),
    name_lens: [asset_count]usize = @splat(0),
    sizes: [asset_count]u64,
    sha256: [asset_count][64]u8,
    devices: [asset_count]u64,
    inodes: [asset_count]u64,
    fds: [asset_count]std.c.fd_t,

    fn asset(self: *const @This(), index: usize) ExpectedAsset {
        return .{ .id = self.ids[index], .name = self.names[index][0..self.name_lens[index]], .size = self.sizes[index], .sha256 = self.sha256[index], .device = self.devices[index], .inode = self.inodes[index], .fd = self.fds[index] };
    }
};

const ProductionAuthority = struct {
    input: attachment.AuthorityInput,
    attached: *const attachment.DraftAssets,

    pub fn snapshot(self: *@This()) !Snapshot {
        const base = try attachment.snapshotAuthority(self.input);
        const attached = self.attached.value() orelse return error.InvalidAttachment;
        if (attached.release_id != base.release_id or attached.assets.len != asset_count) return error.AuthorityMismatch;
        var assets: [asset_count]ExpectedAsset = undefined;
        for (attached.assets, 0..) |remote, index| {
            const local = base.assets[index];
            if (remote.id == 0 or remote.size != local.size or !std.mem.eql(u8, remote.name, local.name)) return error.AuthorityMismatch;
            assets[index] = .{ .id = remote.id, .name = local.name, .size = local.size, .sha256 = local.sha256, .device = local.device, .inode = local.inode, .fd = local.fd };
        }
        return .{ .release_id = base.release_id, .cli_sha256 = base.cli_sha256, .assets = assets };
    }
};

const ProductionDownloader = struct {
    io: std.Io,
    executable: [:0]const u8,
    token: []const u8,

    pub fn download(self: *@This(), expected: ExpectedAsset, budget: i128) !ObservedAsset {
        try transport.validateToken(self.token);
        var endpoint_storage: [128:0]u8 = undefined;
        const endpoint = std.fmt.bufPrintZ(&endpoint_storage, "repos/ohah/maru/releases/assets/{d}", .{expected.id}) catch return error.InvalidRequest;
        var token_storage: ["GH_TOKEN=".len + transport.max_token_bytes + 1]u8 = undefined;
        defer @memset(&token_storage, 0);
        const token_entry = std.fmt.bufPrintZ(&token_storage, "GH_TOKEN={s}", .{self.token}) catch return error.InvalidToken;
        const argv = [_:null]?[*:0]const u8{ self.executable.ptr, "api", "--method", "GET", "--hostname", "github.com", "--header", "Accept: application/octet-stream", endpoint.ptr };
        const environment = [_:null]?[*:0]const u8{ token_entry.ptr, "GH_PROMPT_DISABLED=1" };
        const digest = try process.runDigestEnvironmentStdout(self.io, self.executable, &argv, &environment, expected.size, budget);
        if (digest.size != expected.size or !std.mem.eql(u8, &digest.sha256, &expected.sha256)) return error.ContentMismatch;
        return .{ .id = expected.id, .size = digest.size, .sha256 = digest.sha256 };
    }
};

pub fn validateUntil(
    io: std.Io,
    authority_input: attachment.AuthorityInput,
    attached: *const attachment.DraftAssets,
    token: []const u8,
    deadline: *deadline_mod.Deadline,
    result: *RedownloadValidation,
) !void {
    try transport.validateToken(token);
    const result_bytes = std.mem.asBytes(result);
    inline for (.{ std.mem.asBytes(attached), std.mem.asBytes(authority_input.draft), std.mem.asBytes(authority_input.candidate), std.mem.asBytes(authority_input.authored), std.mem.asBytes(authority_input.evidence), std.mem.asBytes(authority_input.manifest), std.mem.asBytes(authority_input.cli.pinned), std.mem.asBytes(deadline), authority_input.paths.dmg, authority_input.paths.frozen_executable, authority_input.paths.evidence, authority_input.paths.manifest, authority_input.cli.path, token }) |value|
        if (overlaps(result_bytes, value)) return error.InvalidOwner;
    var authority = ProductionAuthority{ .input = authority_input, .attached = attached };
    var downloader = ProductionDownloader{ .io = io, .executable = authority_input.cli.path, .token = token };
    try validateCore(&authority, &downloader, deadline, result);
}

pub fn assertProductionBoundary() void {
    _ = &validateUntil;
}

pub const testing_api = if (builtin.is_test) struct {
    pub fn validate(authority: anytype, downloader: anytype, deadline: anytype, result: *RedownloadValidation) !void {
        try validateCore(authority, downloader, deadline, result);
    }
    pub fn download(io: std.Io, executable: [:0]const u8, token: []const u8, expected: ExpectedAsset, budget: i128) !ObservedAsset {
        var downloader = ProductionDownloader{ .io = io, .executable = executable, .token = token };
        return downloader.download(expected, budget);
    }
} else struct {};

fn validateCore(authority: anytype, downloader: anytype, deadline: anytype, result: *RedownloadValidation) !void {
    if (!pristine(result)) return error.InvalidOwner;
    _ = try deadline.remaining();
    const initial = try authority.snapshot();
    try validateSnapshot(initial);
    var fixed: FrozenSnapshot = undefined;
    freeze(&fixed, initial);
    for (0..asset_count) |index| {
        const before = try authority.snapshot();
        if (!same(&fixed, before)) return error.AuthorityChanged;
        const expected = fixed.asset(index);
        const observed = try downloader.download(expected, try deadline.remaining());
        if (!sameObserved(expected, observed)) return error.ContentMismatch;
        const after = try authority.snapshot();
        if (!same(&fixed, after)) return error.AuthorityChanged;
    }
    _ = try deadline.remaining();
    const final = try authority.snapshot();
    if (!same(&fixed, final)) return error.AuthorityChanged;
    try result.publish(fixed.release_id, fixed.ids);
    const published = result.value() orelse return error.InvalidOwner;
    if (published.release_id != fixed.release_id or !std.mem.eql(u64, &published.asset_ids, &fixed.ids)) return error.InvalidOwner;
}

fn validateSnapshot(snapshot: Snapshot) !void {
    if (snapshot.release_id == 0 or !lowerHex(&snapshot.cli_sha256)) return error.InvalidAuthority;
    for (snapshot.assets, 0..) |asset, index| {
        if (asset.id == 0 or !validName(asset.name) or asset.size == 0 or asset.fd < 0 or !lowerHex(&asset.sha256)) return error.InvalidAuthority;
        for (snapshot.assets[0..index]) |prior| if (asset.id == prior.id or asset.fd == prior.fd or
            (asset.device == prior.device and asset.inode == prior.inode) or std.mem.eql(u8, asset.name, prior.name)) return error.AssetAlias;
    }
}

fn freeze(result: *FrozenSnapshot, source: Snapshot) void {
    result.* = .{ .release_id = source.release_id, .cli_sha256 = source.cli_sha256, .ids = undefined, .sizes = undefined, .sha256 = undefined, .devices = undefined, .inodes = undefined, .fds = undefined };
    for (source.assets, 0..) |asset, index| {
        result.ids[index] = asset.id;
        result.name_lens[index] = asset.name.len;
        @memcpy(result.names[index][0..asset.name.len], asset.name);
        result.sizes[index] = asset.size;
        result.sha256[index] = asset.sha256;
        result.devices[index] = asset.device;
        result.inodes[index] = asset.inode;
        result.fds[index] = asset.fd;
    }
}

fn same(fixed: *const FrozenSnapshot, observed: Snapshot) bool {
    if (fixed.release_id != observed.release_id or !std.mem.eql(u8, &fixed.cli_sha256, &observed.cli_sha256)) return false;
    for (observed.assets, 0..) |asset, index| {
        const expected = fixed.asset(index);
        if (expected.id != asset.id or expected.size != asset.size or expected.device != asset.device or expected.inode != asset.inode or expected.fd != asset.fd or
            !std.mem.eql(u8, expected.name, asset.name) or !std.mem.eql(u8, &expected.sha256, &asset.sha256)) return false;
    }
    return true;
}

fn sameObserved(expected: ExpectedAsset, observed: ObservedAsset) bool {
    return expected.id == observed.id and expected.size == observed.size and std.mem.eql(u8, &expected.sha256, &observed.sha256);
}
fn pristine(result: *const RedownloadValidation) bool {
    return result.owner == null and result.status == .empty and result.release_id == 0 and std.mem.allEqual(u64, &result.asset_ids, 0);
}
fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > max_asset_name_bytes or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..") or std.mem.indexOfScalar(u8, value, '/') != null) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
fn lowerHex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
