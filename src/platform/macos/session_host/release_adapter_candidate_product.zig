//! Manifest-independent Apple product authority for a pinned release candidate.

const std = @import("std");
const apple = @import("release_adapter_apple_product");
const apple_transport = @import("release_adapter_apple_transport");
const candidate_files = @import("release_adapter_candidate_files");
const dmg_authority = @import("release_adapter_dmg_authority");

pub const DmgExpected = dmg_authority.ExpectedDmg;
pub const Paths = struct { dmg: [:0]const u8, frozen_executable: [:0]const u8, dmg_work: [:0]const u8 };
pub const View = struct {
    release_id: u64,
    tag: []const u8,
    source_commit: []const u8,
    build: candidate_files.BuildView,
    dmg_sha256: []const u8,
    frozen_sha256: []const u8,
    apple: *const apple.Observed,
};

pub const CandidateProduct = struct {
    owner: ?*CandidateProduct = null,
    release_id: u64 = 0,
    tag: [candidate_files.max_tag_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    workflow_ref: [candidate_files.max_tag_bytes]u8 = @splat(0),
    workflow_ref_len: usize = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,
    dmg_sha256: [64]u8 = @splat(0),
    frozen_sha256: [64]u8 = @splat(0),
    observed: ?apple.Observed = null,

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or self.release_id == 0) return null;
        const product = if (self.observed) |*observed_value| observed_value else return null;
        if (self.workflow_ref_len == 0 or self.run_id == 0 or self.run_attempt == 0) return null;
        return .{ .release_id = self.release_id, .tag = self.tag[0..self.tag_len], .source_commit = &self.source_commit, .build = .{ .workflow_ref = self.workflow_ref[0..self.workflow_ref_len], .run_id = self.run_id, .run_attempt = self.run_attempt }, .dmg_sha256 = &self.dmg_sha256, .frozen_sha256 = &self.frozen_sha256, .apple = product };
    }

    pub fn revalidate(self: *const @This(), candidate: *const candidate_files.CandidateFiles, paths: Paths) !View {
        const current = self.value() orelse return error.InvalidOwner;
        const files = candidate.revalidate(filePaths(paths)) catch return error.CandidateChanged;
        if (files.release_id != current.release_id or !std.mem.eql(u8, files.tag, current.tag) or
            !std.mem.eql(u8, files.source_commit, current.source_commit) or
            !std.mem.eql(u8, files.build.workflow_ref, current.build.workflow_ref) or files.build.run_id != current.build.run_id or files.build.run_attempt != current.build.run_attempt or
            !std.mem.eql(u8, &files.dmg.sha256, current.dmg_sha256) or
            !std.mem.eql(u8, &files.frozen.sha256, current.frozen_sha256) or
            !std.mem.eql(u8, current.apple.executableSha256(), current.frozen_sha256)) return error.ProductMismatch;
        return current;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) !void {
        if (self.owner != self or self.observed == null) return error.InvalidOwner;
        self.observed.?.deinit(allocator);
        self.* = .{};
    }
};

pub const RealObserver = struct {
    storage: *apple_transport.Storage,
    pub fn observeUntil(self: *@This(), allocator: std.mem.Allocator, io: std.Io, paths: Paths, expected: DmgExpected, version: []const u8, deadline: anytype) !apple.Observed {
        return dmg_authority.observeUntil(allocator, io, paths.dmg, paths.dmg_work, expected, version, self.storage, deadline);
    }
};

pub fn observe(allocator: std.mem.Allocator, io: std.Io, candidate: *const candidate_files.CandidateFiles, paths: Paths, storage: *apple_transport.Storage, deadline: anytype, result: *CandidateProduct) !void {
    var observer = RealObserver{ .storage = storage };
    return observeWith(&observer, deadline, allocator, io, candidate, paths, result);
}

pub fn observeWith(observer: anytype, deadline: anytype, allocator: std.mem.Allocator, io: std.Io, candidate: *const candidate_files.CandidateFiles, paths: Paths, result: *CandidateProduct) !void {
    if (!pristine(result)) return error.InvalidOwner;
    try validatePaths(paths);
    _ = try deadline.remaining();
    const before = candidate.revalidate(filePaths(paths)) catch return error.InvalidCandidate;
    if (before.tag.len < 2 or before.tag[0] != 'v') return error.InvalidCandidate;
    var expected_sha: [64]u8 = undefined;
    @memcpy(&expected_sha, &before.dmg.sha256);
    _ = try deadline.remaining();
    var observed = try observer.observeUntil(allocator, io, paths, .{ .size = before.dmg.size, .sha256 = expected_sha }, before.tag[1..], deadline);
    var observed_owned = true;
    defer if (observed_owned) observed.deinit(allocator);
    _ = try deadline.remaining();
    const after = candidate.revalidate(filePaths(paths)) catch return error.CandidateChanged;
    if (after.release_id != before.release_id or !std.mem.eql(u8, after.tag, before.tag) or
        !std.mem.eql(u8, after.source_commit, before.source_commit) or
        !std.mem.eql(u8, after.build.workflow_ref, before.build.workflow_ref) or after.build.run_id != before.build.run_id or after.build.run_attempt != before.build.run_attempt or
        !std.mem.eql(u8, &after.dmg.sha256, &before.dmg.sha256) or
        !std.mem.eql(u8, &after.frozen.sha256, &before.frozen.sha256) or
        !std.mem.eql(u8, observed.executableSha256(), &after.frozen.sha256)) return error.ProductMismatch;
    result.release_id = before.release_id;
    result.tag_len = before.tag.len;
    @memcpy(result.tag[0..result.tag_len], before.tag);
    @memcpy(&result.source_commit, before.source_commit);
    result.workflow_ref_len = before.build.workflow_ref.len;
    @memcpy(result.workflow_ref[0..result.workflow_ref_len], before.build.workflow_ref);
    result.run_id = before.build.run_id;
    result.run_attempt = before.build.run_attempt;
    @memcpy(&result.dmg_sha256, &before.dmg.sha256);
    @memcpy(&result.frozen_sha256, &before.frozen.sha256);
    result.observed = observed;
    result.owner = result;
    observed_owned = false;
}

fn pristine(result: *const CandidateProduct) bool {
    return result.owner == null and result.release_id == 0 and result.tag_len == 0 and result.workflow_ref_len == 0 and
        result.run_id == 0 and result.run_attempt == 0 and result.observed == null and allZero(&result.tag) and
        allZero(&result.source_commit) and allZero(&result.workflow_ref) and allZero(&result.dmg_sha256) and allZero(&result.frozen_sha256);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn filePaths(paths: Paths) candidate_files.Paths {
    return .{ .dmg = paths.dmg, .frozen_executable = paths.frozen_executable };
}

fn validatePaths(paths: Paths) !void {
    const values = [_][]const u8{ paths.dmg, paths.frozen_executable, paths.dmg_work };
    for (values) |path| if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    for (values, 0..) |left, index| for (values[index + 1 ..]) |right| if (std.mem.eql(u8, left, right)) return error.InvalidPath;
    const dmg_parent = std.fs.path.dirname(paths.dmg) orelse return error.InvalidPath;
    const frozen_parent = std.fs.path.dirname(paths.frozen_executable) orelse return error.InvalidPath;
    const work_parent = std.fs.path.dirname(paths.dmg_work) orelse return error.InvalidPath;
    if (std.mem.eql(u8, work_parent, dmg_parent) or std.mem.eql(u8, work_parent, frozen_parent)) return error.InvalidPath;
    var existing: std.posix.Stat = undefined;
    if (std.c.fstatat(std.posix.AT.FDCWD, paths.dmg_work.ptr, &existing, std.posix.AT.SYMLINK_NOFOLLOW) == 0 or
        std.posix.errno(-1) != .NOENT) return error.InvalidPath;
}
