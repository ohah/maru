//! Selects the closed authored-attestation subject set without opening credentials.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const context_mod = @import("release_adapter_context");
const manifest_mod = @import("release_manifest");
const handoff = @import("release_adapter_candidate_preparation_handoff");
const reopen_mod = @import("release_adapter_candidate_preparation_reopen");
const profile_mod = @import("release_adapter_profile_endorsement");
const timing_mod = @import("release_adapter_profile_upgrade_timing_artifact");

pub const Paths = struct {
    preparation: [:0]const u8,
    baseline_evidence: [:0]const u8,
    upgrade_evidence: [:0]const u8,
    manifest: [:0]const u8,
    timing: [:0]const u8,
};

pub const Projection = struct {
    evidence_path: []const u8,
    evidence_name: []const u8,
    manifest_path: []const u8,
    manifest_name: []const u8,
    timing_required: bool,
    timing_path: []const u8,
    timing_name: []const u8,
};

pub const Plan = struct {
    owner: ?*@This() = null,
    selected: profile_mod.Profile = .baseline_a,
    profile: profile_mod.Owner = .{},
    preparation: reopen_mod.ReopenedPreparation = .{},
    timing: timing_mod.Artifact = .{},
    paths: [5][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    path_lens: [5]usize = @splat(0),
    seal: [32]u8 = @splat(0),

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and self.selected == .baseline_a and self.profile.isPristineForComposition() and
            self.preparation.owner == null and self.timing.isPristineForComposition() and
            std.mem.allEqual(usize, &self.path_lens, 0) and allZero(std.mem.asBytes(&self.paths)) and allZero(&self.seal);
    }

    pub fn value(self: *const @This()) ?Projection {
        if (self.owner != self or !std.mem.eql(u8, &self.seal, &planSeal(self))) return null;
        const prepared = self.preparation.value() orelse return null;
        const evidence_path = prepared.entries[0].path;
        const manifest_path = prepared.entries[1].path;
        return switch (self.selected) {
            .baseline_a => if (!self.timing.isPristineForComposition()) null else .{
                .evidence_path = evidence_path,
                .evidence_name = std.fs.path.basename(evidence_path),
                .manifest_path = manifest_path,
                .manifest_name = std.fs.path.basename(manifest_path),
                .timing_required = false,
                .timing_path = "",
                .timing_name = "",
            },
            .upgrade_b => blk: {
                const timing = self.timing.value() orelse return null;
                break :blk .{
                    .evidence_path = evidence_path,
                    .evidence_name = std.fs.path.basename(evidence_path),
                    .manifest_path = manifest_path,
                    .manifest_name = std.fs.path.basename(manifest_path),
                    .timing_required = true,
                    .timing_path = timing.path,
                    .timing_name = std.fs.path.basename(timing.path),
                };
            },
        };
    }

    pub fn fence(self: *const @This(), allocator: std.mem.Allocator, context: context_mod.Context, environment: profile_mod.Environment) !Projection {
        const initial = self.value() orelse return error.InvalidOwner;
        const selected = try self.profile.revalidateEnvironment(allocator, context, environment);
        if (selected.profile() != self.selected) return error.AuthorityChanged;
        const prepared = try self.preparation.fence(allocator);
        if (!sameObservation(initial.evidence_path, initial.manifest_path, prepared)) return error.FileChanged;
        try bindProfileManifest(allocator, selected, &self.preparation);
        if (self.selected == .upgrade_b) {
            const current = try self.timing.revalidate();
            if (!std.mem.eql(u8, initial.timing_path, current.path)) return error.FileChanged;
        }
        return self.value() orelse error.InvalidOwner;
    }

    pub fn deinit(self: *@This()) !void {
        if (self.owner != self or !std.mem.eql(u8, &self.seal, &planSeal(self))) return error.InvalidOwner;
        var first_error: ?anyerror = null;
        if (self.selected == .upgrade_b) self.timing.closeRetaining() catch |err| {
            first_error = err;
        };
        self.preparation.deinit() catch |err| {
            if (first_error == null) first_error = err;
        };
        self.profile.deinit() catch |err| {
            if (first_error == null) first_error = err;
        };
        self.* = .{};
        if (first_error) |err| return err;
    }
};

pub fn select(allocator: std.mem.Allocator, context: context_mod.Context, environment: profile_mod.Environment, paths: Paths, result: *Plan) !void {
    if (!result.isPristineForComposition() or pathsAliasOwner(paths, result)) return error.InvalidOwner;
    try validatePaths(paths);
    errdefer closeWorking(result);
    try copyPaths(result, paths);
    const owned_paths = pathView(result);
    try profile_mod.bindFromEnvironment(allocator, context, environment, &result.profile);
    const selected = try result.profile.revalidateEnvironment(allocator, context, environment);
    result.selected = selected.profile();
    try reopen_mod.open(allocator, context, owned_paths.preparation, &result.preparation);
    const prepared = result.preparation.value() orelse return error.InvalidOwner;
    const expected_evidence = if (result.selected == .baseline_a) owned_paths.baseline_evidence else owned_paths.upgrade_evidence;
    if (!std.mem.eql(u8, prepared.entries[0].path, expected_evidence) or
        !std.mem.eql(u8, prepared.entries[1].path, owned_paths.manifest)) return error.ProfileMismatch;
    try bindProfileManifest(allocator, selected, &result.preparation);
    if (result.selected == .baseline_a) {
        try requireAbsent(owned_paths.timing);
    } else {
        try timing_mod.reopen(allocator, owned_paths.timing, context, &result.timing);
        const timing = result.timing.value() orelse return error.InvalidOwner;
        if (sameIdentity(timing.observation.identity, prepared.entries[0].observation.identity) or
            sameIdentity(timing.observation.identity, prepared.entries[1].observation.identity)) return error.PathAlias;
    }
    result.owner = result;
    result.seal = planSeal(result);
    _ = result.value() orelse return error.InvalidOwner;
}

fn pathView(self: *const Plan) Paths {
    return .{
        .preparation = self.paths[0][0..self.path_lens[0] :0],
        .baseline_evidence = self.paths[1][0..self.path_lens[1] :0],
        .upgrade_evidence = self.paths[2][0..self.path_lens[2] :0],
        .manifest = self.paths[3][0..self.path_lens[3] :0],
        .timing = self.paths[4][0..self.path_lens[4] :0],
    };
}

fn copyPaths(result: *Plan, paths: Paths) !void {
    inline for (.{ paths.preparation, paths.baseline_evidence, paths.upgrade_evidence, paths.manifest, paths.timing }, 0..) |path, index| {
        if (path.len >= result.paths[index].len) return error.InvalidPath;
        @memcpy(result.paths[index][0..path.len], path);
        result.path_lens[index] = path.len;
    }
}

fn bindProfileManifest(allocator: std.mem.Allocator, selected: profile_mod.Value, preparation: *const reopen_mod.ReopenedPreparation) !void {
    _ = preparation.value() orelse return error.InvalidOwner;
    const manifest_path: [:0]const u8 = preparation.paths[1][0..preparation.path_lens[1] :0];
    var input = try preparation.entries[1].readHeldAlloc(allocator, manifest_path, manifest_mod.max_manifest_bytes);
    defer input.deinit(allocator);
    var parsed = try manifest_mod.parseCanonical(allocator, input.bytes);
    defer parsed.deinit();
    const authored = parsed.value();
    switch (selected) {
        .baseline_a => if (authored.role != .a or authored.predecessor != null) return error.ProfileMismatch,
        .upgrade_b => |expected| {
            const actual = authored.predecessor orelse return error.ProfileMismatch;
            if (authored.role != .b or actual.release_id != expected.release_id or
                !std.mem.eql(u8, actual.tag, expected.tag) or !std.mem.eql(u8, actual.commit, expected.commit) or
                !std.mem.eql(u8, actual.manifest_sha256, expected.manifest_sha256)) return error.ProfileMismatch;
        },
    }
}

fn planSeal(value: *const Plan) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update(std.mem.asBytes(&value.selected));
    hash.update(std.mem.asBytes(&value.path_lens));
    hash.update(std.mem.asBytes(&value.paths));
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn validatePaths(paths: Paths) !void {
    inline for (.{ paths.preparation, paths.baseline_evidence, paths.upgrade_evidence, paths.manifest, paths.timing }) |path|
        if (!canonicalAbsolute(path)) return error.InvalidPath;
    if (!directChild(paths.preparation, paths.baseline_evidence) or !directChild(paths.preparation, paths.upgrade_evidence) or
        !directChild(paths.preparation, paths.manifest)) return error.InvalidPath;
    const preparation_parent = std.fs.path.dirname(paths.preparation) orelse return error.InvalidPath;
    const timing_parent = std.fs.path.dirname(paths.timing) orelse return error.InvalidPath;
    if (!std.mem.eql(u8, preparation_parent, timing_parent)) return error.InvalidPath;
    if (!std.mem.eql(u8, std.fs.path.basename(paths.baseline_evidence), handoff.baseline_evidence_name) or
        !std.mem.eql(u8, std.fs.path.basename(paths.upgrade_evidence), handoff.upgrade_evidence_name) or
        !std.mem.eql(u8, std.fs.path.basename(paths.timing), "profile-upgrade-timing.json") or
        !std.mem.startsWith(u8, std.fs.path.basename(paths.manifest), "Maru-") or
        !std.mem.endsWith(u8, std.fs.path.basename(paths.manifest), "-session-host-release.json")) return error.InvalidPath;
    const values = [_][]const u8{ paths.preparation, paths.baseline_evidence, paths.upgrade_evidence, paths.manifest, paths.timing };
    for (values, 0..) |left, i| for (values[i + 1 ..], 0..) |right, offset| {
        const j = i + 1 + offset;
        if (i == 0 and j <= 3 and directChild(left, right)) continue;
        if (related(left, right)) return error.PathAlias;
    };
}

fn requireAbsent(path: [:0]const u8) !void {
    var stat: posix.Stat = undefined;
    const rc = c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW);
    if (rc == 0 or posix.errno(rc) != .NOENT) return error.UnexpectedTiming;
}

fn directChild(parent: []const u8, child: []const u8) bool {
    const directory = std.fs.path.dirname(child) orelse return false;
    return std.mem.eql(u8, parent, directory);
}

fn related(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return true;
    return descendant(left, right) or descendant(right, left);
}

fn descendant(parent: []const u8, child: []const u8) bool {
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/';
}

fn canonicalAbsolute(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/' or path[path.len - 1] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |component| if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn pathsAliasOwner(paths: Paths, owner: *const Plan) bool {
    const bytes = std.mem.asBytes(owner);
    inline for (.{ paths.preparation, paths.baseline_evidence, paths.upgrade_evidence, paths.manifest, paths.timing }) |path|
        if (overlaps(path, bytes)) return true;
    return false;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const a = @intFromPtr(left.ptr);
    const b = @intFromPtr(right.ptr);
    return a < b + right.len and b < a + left.len;
}

fn sameObservation(evidence_path: []const u8, manifest_path: []const u8, prepared: reopen_mod.View) bool {
    return std.mem.eql(u8, evidence_path, prepared.entries[0].path) and std.mem.eql(u8, manifest_path, prepared.entries[1].path);
}

fn sameIdentity(left: anytype, right: @TypeOf(left)) bool {
    return left.device == right.device and left.inode == right.inode;
}

fn closeWorking(working: *Plan) void {
    if (working.timing.owner == &working.timing) working.timing.closeRetaining() catch {};
    if (working.preparation.owner == &working.preparation) working.preparation.deinit() catch {};
    if (working.profile.owner == &working.profile) working.profile.deinit() catch {};
    working.* = .{};
}
