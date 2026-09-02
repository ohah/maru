//! Terminal state and exact-order authority for attaching one candidate asset set to one draft.
//!
//! The production authority supplies already-held descriptors. The uploader must stream those
//! descriptors; this core never accepts a pathname or a caller-provided success scalar.

const std = @import("std");
const builtin = @import("builtin");
const process = @import("bounded_process");
const manifest_mod = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const files_mod = @import("release_adapter_files");
const draft_mod = @import("release_adapter_github_draft_creation");
const candidate_attestation_mod = @import("release_adapter_candidate_attestation");
const authored_attestation_mod = @import("release_adapter_candidate_authored_attestation");
const cli_authority_mod = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");
const transport = @import("release_adapter_github_transport");

pub const asset_count: usize = 4;
pub const max_asset_name_bytes: usize = 255;

pub const State = enum { empty, remote_state_unknown, cleanup_required, ready };
pub const UploadState = enum { uploaded };

pub const ExpectedAsset = struct {
    name: []const u8,
    size: u64,
    sha256: [64]u8,
    device: u64,
    inode: u64,
    fd: std.c.fd_t,
};

pub const Snapshot = struct {
    release_id: u64,
    cli_sha256: [64]u8,
    assets: [asset_count]ExpectedAsset,
};

pub const ObservedAsset = struct {
    id: u64,
    name: []const u8,
    size: u64,
    state: UploadState,
};

pub const AssetView = struct { id: u64, name: []const u8, size: u64 };
pub const View = struct { release_id: u64, assets: []const AssetView };

const FrozenSnapshot = struct {
    release_id: u64,
    cli_sha256: [64]u8,
    names: [asset_count][max_asset_name_bytes]u8 = @splat(@splat(0)),
    name_lens: [asset_count]usize = @splat(0),
    sizes: [asset_count]u64,
    sha256: [asset_count][64]u8,
    devices: [asset_count]u64,
    inodes: [asset_count]u64,
    fds: [asset_count]std.c.fd_t,

    fn asset(self: *const @This(), index: usize) ExpectedAsset {
        return .{
            .name = self.names[index][0..self.name_lens[index]],
            .size = self.sizes[index],
            .sha256 = self.sha256[index],
            .device = self.devices[index],
            .inode = self.inodes[index],
            .fd = self.fds[index],
        };
    }
};

pub const DraftAssets = struct {
    owner: ?*DraftAssets = null,
    status: State = .empty,
    release_id: u64 = 0,
    known_count: usize = 0,
    ids: [asset_count]u64 = @splat(0),
    sizes: [asset_count]u64 = @splat(0),
    names: [asset_count][max_asset_name_bytes]u8 = @splat(@splat(0)),
    name_lens: [asset_count]usize = @splat(0),
    views: [asset_count]AssetView = undefined,

    pub fn state(self: *const @This()) State {
        return self.status;
    }

    pub fn knownAssetIds(self: *const @This()) []const u64 {
        if (self.known_count > self.ids.len) return self.ids[0..0];
        return self.ids[0..self.known_count];
    }

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or self.status != .ready or self.release_id == 0 or self.known_count != asset_count)
            return null;
        return .{ .release_id = self.release_id, .assets = &self.views };
    }

    fn publish(self: *@This()) !void {
        if (self.owner != null or self.status != .cleanup_required or self.release_id == 0 or self.known_count != asset_count)
            return error.InvalidOwner;
        for (0..asset_count) |index| {
            if (self.ids[index] == 0 or self.name_lens[index] == 0 or self.name_lens[index] > max_asset_name_bytes)
                return error.InvalidOwner;
            self.views[index] = .{
                .id = self.ids[index],
                .name = self.names[index][0..self.name_lens[index]],
                .size = self.sizes[index],
            };
        }
        self.status = .ready;
        self.owner = self;
    }

    pub fn deinit(self: *@This()) !void {
        if (self.owner != self or self.status != .ready) return error.InvalidOwner;
        self.* = .{};
    }
};

pub const Paths = struct {
    dmg: [:0]const u8,
    frozen_executable: [:0]const u8,
    evidence: [:0]const u8,
    manifest: [:0]const u8,
};
pub const Cli = struct { path: [:0]const u8, pinned: *const cli_authority_mod.PinnedExecutable };

const ProductionAuthority = struct {
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    draft: *const draft_mod.DraftAuthority,
    candidate: *const candidate_attestation_mod.CandidateAttestation,
    authored: *const authored_attestation_mod.AuthoredAttestation,
    evidence: *const files_mod.PinnedReleaseFile,
    manifest: *const files_mod.PinnedReleaseFile,
    paths: Paths,
    cli: Cli,

    pub fn snapshot(self: *@This()) !Snapshot {
        try validatePaths(self.paths, self.cli.path);
        const draft = self.draft.value() orelse return error.InvalidDraft;
        if (draft.id == 0 or !std.mem.eql(u8, draft.tag, self.context.tag) or
            !std.mem.eql(u8, draft.source_commit, self.context.source_commit)) return error.AuthorityMismatch;
        const candidate = self.candidate.revalidate(.{ .dmg = self.paths.dmg, .frozen_executable = self.paths.frozen_executable }) catch return error.CandidateChanged;
        const authored = self.authored.revalidate(self.context, draft.id, self.evidence, self.manifest, .{ .evidence = self.paths.evidence, .manifest = self.paths.manifest }) catch return error.AuthoredChanged;
        try cli_authority_mod.revalidate(self.allocator, self.cli.path, self.cli.pinned);
        const evidence = self.evidence.revalidate(self.paths.evidence) catch return error.FileChanged;
        const manifest_observation = self.manifest.revalidate(self.paths.manifest) catch return error.FileChanged;
        if (!sameObservation(authored.evidence, evidence) or !sameObservation(authored.manifest, manifest_observation))
            return error.AuthoredChanged;
        try files_mod.requireDistinct(&.{ candidate.dmg.identity, candidate.frozen.identity, evidence.identity, manifest_observation.identity });

        var input = try self.manifest.readHeldAlloc(self.allocator, self.paths.manifest, manifest_mod.max_manifest_bytes);
        defer input.deinit(self.allocator);
        var parsed = try manifest_mod.parseCanonical(self.allocator, input.bytes);
        defer parsed.deinit();
        const value = parsed.value();
        try context_mod.bindManifest(self.context, value.*);
        if (value.release.id != draft.id or value.assets.len != 3) return error.ManifestMismatch;
        const observations = [_]files_mod.ExecutableObservation{ candidate.dmg, candidate.frozen, evidence };
        const paths = [_][]const u8{ self.paths.dmg, self.paths.frozen_executable, self.paths.evidence };
        const roles = [_]manifest_mod.AssetRole{ .universal_dmg, .frozen_product_executable, .evidence_summary };
        for (value.assets, 0..) |asset, index| {
            if (asset.role != roles[index] or !std.mem.eql(u8, asset.name, std.fs.path.basename(paths[index])) or
                asset.size != observations[index].size or !std.mem.eql(u8, asset.sha256, &observations[index].sha256))
                return error.ManifestMismatch;
        }
        return .{
            .release_id = draft.id,
            .cli_sha256 = self.cli.pinned.sha256,
            .assets = .{
                expectedAsset(self.paths.dmg, candidate.dmg, try self.candidate.dmg.heldDescriptor()),
                expectedAsset(self.paths.frozen_executable, candidate.frozen, try self.candidate.frozen.heldDescriptor()),
                expectedAsset(self.paths.evidence, evidence, try self.evidence.heldDescriptor()),
                expectedAsset(self.paths.manifest, manifest_observation, try self.manifest.heldDescriptor()),
            },
        };
    }
};

const ProductionUploader = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: [:0]const u8,
    token: []const u8,
    output: []u8,

    pub fn upload(self: *@This(), release_id: u64, expected: ExpectedAsset, budget: i128) !ObservedAsset {
        try transport.validateToken(self.token);
        var encoded_storage: [max_asset_name_bytes * 3]u8 = undefined;
        const encoded = try percentEncode(&encoded_storage, expected.name);
        var endpoint_storage: [max_asset_name_bytes * 3 + 128:0]u8 = undefined;
        const endpoint = std.fmt.bufPrintZ(&endpoint_storage, "repos/ohah/maru/releases/{d}/assets?name={s}", .{ release_id, encoded }) catch return error.InvalidRequest;
        var token_storage: ["GH_TOKEN=".len + transport.max_token_bytes + 1]u8 = undefined;
        defer @memset(&token_storage, 0);
        const token_entry = std.fmt.bufPrintZ(&token_storage, "GH_TOKEN={s}", .{self.token}) catch return error.InvalidToken;
        const argv = [_:null]?[*:0]const u8{
            self.executable.ptr,
            "api",
            "--method",
            "POST",
            "--hostname",
            "uploads.github.com",
            "--header",
            "Accept: application/vnd.github+json",
            "--header",
            "X-GitHub-Api-Version: 2022-11-28",
            "--header",
            "Content-Type: application/octet-stream",
            "--input",
            "-",
            endpoint.ptr,
        };
        const environment = [_:null]?[*:0]const u8{ token_entry.ptr, "GH_PROMPT_DISABLED=1" };
        const captured = try process.runCaptureEnvironmentStdoutInputFd(self.io, self.executable, &argv, &environment, expected.fd, self.output, budget);
        return parseResponse(self.allocator, captured, expected);
    }
};

const ProductionPublisher = struct {
    pub fn publish(_: *@This(), result: *DraftAssets) !void {
        try result.publish();
    }
};

pub fn attachUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    draft: *const draft_mod.DraftAuthority,
    candidate: *const candidate_attestation_mod.CandidateAttestation,
    authored: *const authored_attestation_mod.AuthoredAttestation,
    evidence: *const files_mod.PinnedReleaseFile,
    manifest: *const files_mod.PinnedReleaseFile,
    paths: Paths,
    cli: Cli,
    token: []const u8,
    output: []u8,
    deadline: *deadline_mod.Deadline,
    result: *DraftAssets,
) !void {
    try transport.validateToken(token);
    if (output.len == 0 or output.len > transport.max_response_bytes) return error.InvalidOutput;
    const result_bytes = std.mem.asBytes(result);
    inline for (.{ std.mem.asBytes(draft), std.mem.asBytes(candidate), std.mem.asBytes(authored), std.mem.asBytes(evidence), std.mem.asBytes(manifest), std.mem.asBytes(cli.pinned), std.mem.asBytes(deadline), paths.dmg, paths.frozen_executable, paths.evidence, paths.manifest, cli.path, token, output }) |value|
        if (overlaps(result_bytes, value)) return error.InvalidOwner;
    inline for (.{ std.mem.asBytes(draft), std.mem.asBytes(candidate), std.mem.asBytes(authored), std.mem.asBytes(evidence), std.mem.asBytes(manifest), std.mem.asBytes(cli.pinned), std.mem.asBytes(deadline), paths.dmg, paths.frozen_executable, paths.evidence, paths.manifest, cli.path, token }) |value|
        if (overlaps(output, value)) return error.InvalidOwner;
    var authority = ProductionAuthority{ .allocator = allocator, .context = context, .draft = draft, .candidate = candidate, .authored = authored, .evidence = evidence, .manifest = manifest, .paths = paths, .cli = cli };
    var uploader = ProductionUploader{ .io = io, .allocator = allocator, .executable = cli.path, .token = token, .output = output };
    var publisher = ProductionPublisher{};
    try attachCore(&authority, &uploader, &publisher, deadline, result);
}

pub fn assertProductionBoundary() void {
    _ = &attachUntil;
}

pub const testing_api = if (builtin.is_test) struct {
    pub fn attach(authority: anytype, uploader: anytype, publisher: anytype, deadline: anytype, result: *DraftAssets) !void {
        try attachCore(authority, uploader, publisher, deadline, result);
    }
    pub fn publish(result: *DraftAssets) !void {
        try result.publish();
    }
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, expected: ExpectedAsset) !ObservedAsset {
        return parseResponse(allocator, bytes, expected);
    }
    pub fn encode(storage: []u8, value: []const u8) ![]const u8 {
        return percentEncode(storage, value);
    }
    pub fn upload(io: std.Io, allocator: std.mem.Allocator, executable: [:0]const u8, token: []const u8, output: []u8, expected: ExpectedAsset, budget: i128) !ObservedAsset {
        var uploader = ProductionUploader{ .io = io, .allocator = allocator, .executable = executable, .token = token, .output = output };
        return uploader.upload(88, expected, budget);
    }
} else struct {};

fn expectedAsset(path: []const u8, observation: files_mod.ExecutableObservation, fd: std.c.fd_t) ExpectedAsset {
    return .{ .name = std.fs.path.basename(path), .size = observation.size, .sha256 = observation.sha256, .device = observation.identity.device, .inode = observation.identity.inode, .fd = fd };
}

fn sameObservation(left: files_mod.ExecutableObservation, right: files_mod.ExecutableObservation) bool {
    return left.identity.device == right.identity.device and left.identity.inode == right.identity.inode and
        left.size == right.size and left.mode == right.mode and std.mem.eql(u8, &left.sha256, &right.sha256);
}

fn validatePaths(paths: Paths, executable: []const u8) !void {
    const values = [_][]const u8{ paths.dmg, paths.frozen_executable, paths.evidence, paths.manifest };
    for (values, 0..) |value, index| {
        if (!std.fs.path.isAbsolute(value) or !validName(std.fs.path.basename(value))) return error.InvalidPath;
        for (values[0..index]) |prior| if (std.mem.eql(u8, value, prior)) return error.AssetAlias;
    }
    if (!std.fs.path.isAbsolute(executable) or !validScalar(executable)) return error.InvalidPath;
}

fn percentEncode(storage: []u8, value: []const u8) ![]const u8 {
    if (!validName(value)) return error.InvalidRequest;
    const hex = "0123456789ABCDEF";
    var used: usize = 0;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            if (used == storage.len) return error.InvalidRequest;
            storage[used] = byte;
            used += 1;
        } else {
            if (storage.len - used < 3) return error.InvalidRequest;
            storage[used] = '%';
            storage[used + 1] = hex[byte >> 4];
            storage[used + 2] = hex[byte & 0x0f];
            used += 3;
        }
    }
    return storage[0..used];
}

fn parseResponse(allocator: std.mem.Allocator, bytes: []const u8, expected: ExpectedAsset) !ObservedAsset {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const id_value = parsed.value.object.get("id") orelse return error.InvalidResponse;
    const name_value = parsed.value.object.get("name") orelse return error.InvalidResponse;
    const size_value = parsed.value.object.get("size") orelse return error.InvalidResponse;
    const state_value = parsed.value.object.get("state") orelse return error.InvalidResponse;
    const digest_value = parsed.value.object.get("digest") orelse return error.InvalidResponse;
    const content_type_value = parsed.value.object.get("content_type") orelse return error.InvalidResponse;
    if (id_value != .integer or id_value.integer <= 0 or name_value != .string or size_value != .integer or size_value.integer < 0 or
        state_value != .string or digest_value != .string or content_type_value != .string) return error.InvalidResponse;
    var digest_storage: ["sha256:".len + 64]u8 = undefined;
    const digest = std.fmt.bufPrint(&digest_storage, "sha256:{s}", .{expected.sha256}) catch unreachable;
    if (!std.mem.eql(u8, name_value.string, expected.name) or @as(u64, @intCast(size_value.integer)) != expected.size or
        !std.mem.eql(u8, state_value.string, "uploaded") or !std.mem.eql(u8, digest_value.string, digest) or
        !std.mem.eql(u8, content_type_value.string, "application/octet-stream")) return error.InvalidResponse;
    return .{ .id = @intCast(id_value.integer), .name = expected.name, .size = expected.size, .state = .uploaded };
}

fn validScalar(value: []const u8) bool {
    if (value.len == 0 or value.len > transport.max_token_bytes) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn attachCore(authority: anytype, uploader: anytype, publisher: anytype, deadline: anytype, result: *DraftAssets) !void {
    if (!pristine(result)) return error.InvalidOwner;
    _ = try deadline.remaining();
    const initial = try authority.snapshot();
    try validateSnapshot(initial);
    var fixed: FrozenSnapshot = undefined;
    freezeSnapshot(&fixed, initial);

    for (0..asset_count) |index| {
        const before = authority.snapshot() catch return terminalKnown(result, error.AuthorityChanged);
        if (!sameSnapshot(&fixed, before)) return terminalKnown(result, error.AuthorityChanged);
        const budget = try deadline.remaining();

        // Once the child is invoked a remote mutation may have happened even when no usable
        // response returns. This transition deliberately occurs before `upload`.
        result.release_id = fixed.release_id;
        result.status = .remote_state_unknown;
        const expected = fixed.asset(index);
        const observed = uploader.upload(fixed.release_id, expected, budget) catch |err| return err;
        if (!validObserved(expected, observed) or containsId(result.knownAssetIds(), observed.id))
            return error.InvalidResponse;
        storeKnown(result, index, observed) catch return error.InvalidResponse;
        result.status = .cleanup_required;

        const after = authority.snapshot() catch return error.AuthorityChanged;
        if (!sameSnapshot(&fixed, after)) return error.AuthorityChanged;
    }

    _ = try deadline.remaining();
    publisher.publish(result) catch |err| return err;
}

fn terminalKnown(result: *DraftAssets, err: anyerror) anyerror {
    if (result.known_count != 0) result.status = .cleanup_required;
    return err;
}

fn validateSnapshot(snapshot: Snapshot) !void {
    if (snapshot.release_id == 0 or !lowerHex(&snapshot.cli_sha256)) return error.InvalidAuthority;
    for (snapshot.assets, 0..) |asset, index| {
        if (!validName(asset.name) or asset.size == 0 or asset.fd < 0 or !lowerHex(&asset.sha256))
            return error.InvalidAuthority;
        for (snapshot.assets[0..index]) |prior| {
            if ((asset.device == prior.device and asset.inode == prior.inode) or asset.fd == prior.fd or std.mem.eql(u8, asset.name, prior.name))
                return error.AssetAlias;
        }
    }
}

fn freezeSnapshot(result: *FrozenSnapshot, source: Snapshot) void {
    result.* = .{
        .release_id = source.release_id,
        .cli_sha256 = source.cli_sha256,
        .sizes = undefined,
        .sha256 = undefined,
        .devices = undefined,
        .inodes = undefined,
        .fds = undefined,
    };
    for (source.assets, 0..) |asset, index| {
        result.name_lens[index] = asset.name.len;
        @memcpy(result.names[index][0..asset.name.len], asset.name);
        result.sizes[index] = asset.size;
        result.sha256[index] = asset.sha256;
        result.devices[index] = asset.device;
        result.inodes[index] = asset.inode;
        result.fds[index] = asset.fd;
    }
}

fn sameSnapshot(left: *const FrozenSnapshot, right: Snapshot) bool {
    if (left.release_id != right.release_id or !std.mem.eql(u8, &left.cli_sha256, &right.cli_sha256)) return false;
    for (right.assets, 0..) |b, index| {
        const a = left.asset(index);
        if (a.size != b.size or a.device != b.device or a.inode != b.inode or a.fd != b.fd or
            !std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, &a.sha256, &b.sha256)) return false;
    }
    return true;
}

fn validObserved(expected: ExpectedAsset, observed: ObservedAsset) bool {
    return observed.id != 0 and observed.state == .uploaded and observed.size == expected.size and
        std.mem.eql(u8, observed.name, expected.name);
}

fn storeKnown(result: *DraftAssets, index: usize, observed: ObservedAsset) !void {
    if (index != result.known_count or observed.name.len > max_asset_name_bytes) return error.InvalidResponse;
    result.ids[index] = observed.id;
    result.sizes[index] = observed.size;
    result.name_lens[index] = observed.name.len;
    @memcpy(result.names[index][0..observed.name.len], observed.name);
    result.known_count += 1;
}

fn containsId(values: []const u64, value: u64) bool {
    for (values) |candidate| if (candidate == value) return true;
    return false;
}

fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > max_asset_name_bytes or std.mem.eql(u8, value, ".") or
        std.mem.eql(u8, value, "..") or std.mem.indexOfScalar(u8, value, '/') != null) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn lowerHex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn pristine(result: *const DraftAssets) bool {
    if (result.owner != null or result.status != .empty or result.release_id != 0 or result.known_count != 0 or
        !std.mem.allEqual(u64, &result.ids, 0) or !std.mem.allEqual(u64, &result.sizes, 0) or
        !std.mem.allEqual(usize, &result.name_lens, 0)) return false;
    for (&result.names) |*name| if (!std.mem.allEqual(u8, name, 0)) return false;
    return true;
}
