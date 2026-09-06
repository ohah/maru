//! Deletes a retained aggregate only after rebinding one sealed post-publish receipt.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const manifest_mod = @import("release_manifest");
const reopen = @import("release_adapter_candidate_aggregate_reopen");
const post = @import("release_adapter_github_post_publish_attestation");

extern "c" fn renameatx_np(from_dir_fd: c_int, from: [*:0]const u8, to_dir_fd: c_int, to: [*:0]const u8, flags: c_uint) c_int;
const rename_excl: c_uint = 0x00000004;
const role_count: usize = 5;

pub const Outcome = enum { success, audit_required, cleanup_required, descriptor_close_failed };
const State = enum { pristine, cleanup_required, descriptor_close_failed };

pub const Deletion = struct {
    owner: ?*Deletion = null,
    state: State = .pristine,
    remaining_entries: u8 = 0,
    tomb_verified: bool = false,
    directory_synced: bool = false,
    directory_removed: bool = false,
    parent_synced: bool = false,
    tomb: [std.fs.max_name_bytes:0]u8 = @splat(0),
    tomb_len: usize = 0,
    source_address: usize = 0,
    seal: [32]u8 = @splat(0),

    pub fn isPristine(self: *const @This()) bool {
        return pristine(self);
    }

    pub fn retryCleanup(self: *@This(), aggregate: *reopen.ReopenedAggregate) !Outcome {
        var driver = ConcreteDriver{ .aggregate = aggregate, .allocator = undefined };
        return retryCore(&driver, self);
    }

    pub fn testing_api_corruptLedger(self: *@This()) void {
        if (!builtin.is_test) @compileError("retention corruption is test-only");
        self.remaining_entries = role_count + 1;
    }
};

pub fn deleteVerifiedAggregate(
    allocator: std.mem.Allocator,
    aggregate: *reopen.ReopenedAggregate,
    verified: *const post.VerifiedRelease,
    deletion: *Deletion,
) !Outcome {
    if (verified.value() == null or !pristine(deletion)) return error.InvalidOwner;
    const deletion_bytes = std.mem.asBytes(deletion);
    if (overlaps(deletion_bytes, std.mem.asBytes(aggregate)) or overlaps(deletion_bytes, std.mem.asBytes(verified)) or
        overlaps(std.mem.asBytes(aggregate), std.mem.asBytes(verified))) return error.InvalidOwner;
    var driver = ConcreteDriver{ .aggregate = aggregate, .allocator = allocator };
    return executeCore(&driver, verified, deletion);
}

fn executeCore(driver: anytype, verified: *const post.VerifiedRelease, deletion: *Deletion) !Outcome {
    if (!pristine(deletion)) return error.InvalidOwner;
    const receipt = verified.value() orelse return .audit_required;
    driver.validate(receipt) catch return .audit_required;
    driver.fence() catch return .audit_required;

    deletion.* = .{
        .owner = deletion,
        .state = .cleanup_required,
        .remaining_entries = role_count,
        .source_address = driver.sourceAddress(),
    };
    deletion.seal = metadataSeal(deletion);
    driver.renameToTomb(deletion) catch {
        deletion.* = .{};
        return .audit_required;
    };
    deletion.seal = metadataSeal(deletion);
    return continueCleanup(driver, deletion);
}

fn retryCore(driver: anytype, deletion: *Deletion) !Outcome {
    if (deletion.owner != deletion or deletion.state == .descriptor_close_failed) {
        if (deletion.owner == deletion and deletion.state == .descriptor_close_failed and valid(deletion)) return error.NonRetryable;
        return error.InvalidOwner;
    }
    if (!valid(deletion) or deletion.source_address != driver.sourceAddress()) return error.InvalidOwner;
    return continueCleanup(driver, deletion);
}

fn continueCleanup(driver: anytype, deletion: *Deletion) !Outcome {
    if (!valid(deletion) or deletion.state != .cleanup_required) return error.InvalidOwner;
    if (!deletion.tomb_verified) {
        driver.fenceTomb(deletion) catch return .cleanup_required;
        deletion.tomb_verified = true;
        deletion.seal = metadataSeal(deletion);
    }
    while (deletion.remaining_entries != 0) {
        const index: usize = deletion.remaining_entries - 1;
        driver.unlink(deletion, index) catch return .cleanup_required;
        deletion.remaining_entries -= 1;
        deletion.seal = metadataSeal(deletion);
    }
    if (!deletion.directory_synced) {
        driver.syncDirectory(deletion) catch return .cleanup_required;
        deletion.directory_synced = true;
        deletion.seal = metadataSeal(deletion);
    }
    if (!deletion.directory_removed) {
        driver.removeDirectory(deletion) catch return .cleanup_required;
        deletion.directory_removed = true;
        deletion.seal = metadataSeal(deletion);
    }
    if (!deletion.parent_synced) {
        driver.syncParent(deletion) catch return .cleanup_required;
        deletion.parent_synced = true;
        deletion.seal = metadataSeal(deletion);
    }
    driver.closeDescriptors(deletion) catch {
        deletion.state = .descriptor_close_failed;
        deletion.seal = metadataSeal(deletion);
        return .descriptor_close_failed;
    };
    deletion.* = .{};
    return .success;
}

const ConcreteDriver = struct {
    aggregate: *reopen.ReopenedAggregate,
    allocator: std.mem.Allocator,

    pub fn sourceAddress(self: *@This()) usize {
        return @intFromPtr(self.aggregate);
    }

    pub fn validate(self: *@This(), receipt: post.View) !void {
        const aggregate_view = try self.aggregate.fence();
        const manifest_path = artifactPath(self.aggregate, 2) orelse return error.InvalidOwner;
        var held = try self.aggregate.artifacts[2].readHeldAlloc(self.allocator, manifest_path, manifest_mod.max_manifest_bytes);
        defer held.deinit(self.allocator);
        var parsed = try manifest_mod.parseCanonical(self.allocator, held.bytes);
        defer parsed.deinit();
        try bind(parsed.value(), aggregate_view, receipt);
    }

    pub fn fence(self: *@This()) !void {
        _ = try self.aggregate.fence();
    }

    pub fn renameToTomb(self: *@This(), deletion: *Deletion) !void {
        if (deletion.tomb_len != 0 or deletion.source_address != @intFromPtr(self.aggregate)) return error.InvalidOwner;
        var nonce: u64 = undefined;
        c.arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(u64));
        const tomb = std.fmt.bufPrintZ(&deletion.tomb, ".maru-aggregate-cleanup-{x}", .{nonce}) catch return error.CleanupFailed;
        deletion.tomb_len = tomb.len;
        const source = directoryLeaf(self.aggregate) orelse return error.InvalidOwner;
        if (renameatx_np(self.aggregate.parent_fd, source.ptr, self.aggregate.parent_fd, tomb.ptr, rename_excl) != 0) {
            deletion.tomb_len = 0;
            @memset(&deletion.tomb, 0);
            return error.CleanupFailed;
        }
    }

    pub fn fenceTomb(self: *@This(), deletion: *Deletion) !void {
        try self.requireTombIdentity(deletion);
    }

    pub fn unlink(self: *@This(), deletion: *Deletion, index: usize) !void {
        if (index >= role_count) return error.InvalidOwner;
        try self.requireTombIdentity(deletion);
        var held: posix.Stat = undefined;
        var named: posix.Stat = undefined;
        const name = entryName(self.aggregate, index) orelse return error.InvalidOwner;
        if (c.fstat(self.aggregate.entries[index].fd, &held) != 0 or
            c.fstatat(self.aggregate.directory_fd, name.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            held.dev != named.dev or held.ino != named.ino or held.nlink != 1 or
            c.unlinkat(self.aggregate.directory_fd, name.ptr, 0) != 0) return error.CleanupFailed;
    }

    fn requireTombIdentity(self: *@This(), deletion: *const Deletion) !void {
        const tomb = tombName(deletion) orelse return error.InvalidOwner;
        var held: posix.Stat = undefined;
        var named: posix.Stat = undefined;
        if (c.fstat(self.aggregate.directory_fd, &held) != 0 or
            c.fstatat(self.aggregate.parent_fd, tomb.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !posix.S.ISDIR(held.mode) or !posix.S.ISDIR(named.mode) or
            held.uid != c.getuid() or named.uid != c.getuid() or
            held.mode & 0o777 != 0o700 or named.mode & 0o777 != 0o700 or
            held.dev != named.dev or held.ino != named.ino or held.mode != named.mode or held.uid != named.uid or
            @as(u64, @intCast(held.dev)) != self.aggregate.directory_device or
            @as(u64, @intCast(held.ino)) != self.aggregate.directory_inode) return error.AuthorityChanged;
    }

    pub fn syncDirectory(self: *@This(), _: *Deletion) !void {
        if (c.fsync(self.aggregate.directory_fd) != 0) return error.CleanupFailed;
    }

    pub fn removeDirectory(self: *@This(), deletion: *Deletion) !void {
        const tomb = tombName(deletion) orelse return error.InvalidOwner;
        var held: posix.Stat = undefined;
        var named: posix.Stat = undefined;
        if (c.fstat(self.aggregate.directory_fd, &held) != 0 or
            c.fstatat(self.aggregate.parent_fd, tomb.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !posix.S.ISDIR(held.mode) or !posix.S.ISDIR(named.mode) or held.dev != named.dev or held.ino != named.ino or
            c.unlinkat(self.aggregate.parent_fd, tomb.ptr, posix.AT.REMOVEDIR) != 0) return error.CleanupFailed;
    }

    pub fn syncParent(self: *@This(), _: *Deletion) !void {
        if (c.fsync(self.aggregate.parent_fd) != 0) return error.CleanupFailed;
    }

    pub fn closeDescriptors(self: *@This(), _: *Deletion) !void {
        try self.aggregate.deinit();
    }
};

fn bind(manifest: *const manifest_mod.Manifest, aggregate: reopen.View, receipt: post.View) !void {
    if (manifest.role != .a or manifest.predecessor != null or manifest.release.id != receipt.release_id or
        !std.mem.eql(u8, manifest.release.tag, receipt.tag) or !std.mem.eql(u8, manifest.source.commit, receipt.source_commit) or
        manifest.repository.id != aggregate.context.repository.id or
        !std.mem.eql(u8, manifest.repository.owner, aggregate.context.repository.owner) or
        !std.mem.eql(u8, manifest.repository.name, aggregate.context.repository.name) or
        !std.mem.eql(u8, manifest.release.tag, aggregate.context.tag) or
        !std.mem.eql(u8, manifest.source.commit, aggregate.context.source_commit) or
        !std.mem.eql(u8, manifest.build.workflow_ref, aggregate.context.build.workflow_ref) or
        manifest.build.run_id != aggregate.context.build.run_id or
        manifest.build.run_attempt != aggregate.context.build.run_attempt or !aggregate.context.protected_tag or
        manifest.assets.len != 3 or receipt.artifact_ids.len != 4) return error.BindingMismatch;
    const observations = [_]@TypeOf(aggregate.artifacts[0]){
        aggregate.artifacts[0],
        aggregate.artifacts[1],
        aggregate.entries[0],
        aggregate.artifacts[2],
    };
    const roles = [_]?manifest_mod.AssetRole{ .universal_dmg, .frozen_product_executable, .evidence_summary, null };
    for (observations, 0..) |observation, index| {
        if (!std.mem.eql(u8, &observation.sha256, &receipt.artifact_sha256[index])) return error.BindingMismatch;
        if (index < manifest.assets.len) {
            const asset = manifest.assets[index];
            const expected_name = if (index < 2) aggregate.artifact_names[index] else aggregate.evidence_name;
            if (asset.role != roles[index].? or asset.size != observation.size or
                !std.mem.eql(u8, asset.name, expected_name) or
                !std.mem.eql(u8, asset.sha256, &observation.sha256)) return error.BindingMismatch;
        }
    }
}

fn pristine(deletion: *const Deletion) bool {
    return deletion.owner == null and deletion.state == .pristine and deletion.remaining_entries == 0 and
        !deletion.tomb_verified and !deletion.directory_synced and !deletion.directory_removed and !deletion.parent_synced and
        deletion.tomb_len == 0 and deletion.source_address == 0 and std.mem.allEqual(u8, &deletion.tomb, 0) and
        std.mem.allEqual(u8, &deletion.seal, 0);
}

fn valid(deletion: *const Deletion) bool {
    if (deletion.owner != deletion or (deletion.state != .cleanup_required and deletion.state != .descriptor_close_failed) or
        deletion.remaining_entries > role_count or deletion.tomb_len == 0 or deletion.tomb_len >= deletion.tomb.len or
        deletion.tomb[deletion.tomb_len] != 0 or deletion.source_address == 0 or
        !std.mem.startsWith(u8, deletion.tomb[0..deletion.tomb_len], ".maru-aggregate-cleanup-") or
        !std.crypto.timing_safe.eql([32]u8, deletion.seal, metadataSeal(deletion))) return false;
    if (!deletion.tomb_verified and (deletion.remaining_entries != role_count or deletion.directory_synced or
        deletion.directory_removed or deletion.parent_synced)) return false;
    if (deletion.remaining_entries != 0 and (deletion.directory_synced or deletion.directory_removed or deletion.parent_synced)) return false;
    if (!deletion.directory_synced and (deletion.directory_removed or deletion.parent_synced)) return false;
    if (!deletion.directory_removed and deletion.parent_synced) return false;
    if (deletion.state == .descriptor_close_failed and (!deletion.directory_synced or !deletion.directory_removed or !deletion.parent_synced)) return false;
    return true;
}

fn metadataSeal(deletion: *const Deletion) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.session-host.aggregate-retention.v1");
    const address = @intFromPtr(deletion);
    hasher.update(std.mem.asBytes(&address));
    hasher.update(std.mem.asBytes(&deletion.state));
    hasher.update(std.mem.asBytes(&deletion.remaining_entries));
    hasher.update(std.mem.asBytes(&deletion.tomb_verified));
    hasher.update(std.mem.asBytes(&deletion.directory_synced));
    hasher.update(std.mem.asBytes(&deletion.directory_removed));
    hasher.update(std.mem.asBytes(&deletion.parent_synced));
    if (deletion.tomb_len <= deletion.tomb.len) hasher.update(deletion.tomb[0..deletion.tomb_len]);
    hasher.update(std.mem.asBytes(&deletion.source_address));
    var seal: [32]u8 = undefined;
    hasher.final(&seal);
    return seal;
}

fn artifactPath(aggregate: *const reopen.ReopenedAggregate, index: usize) ?[:0]const u8 {
    if (index >= aggregate.artifact_paths.len) return null;
    const len = aggregate.artifact_path_lens[index];
    if (len == 0 or len >= aggregate.artifact_paths[index].len or aggregate.artifact_paths[index][len] != 0) return null;
    return aggregate.artifact_paths[index][0..len :0];
}

fn directoryLeaf(aggregate: *const reopen.ReopenedAggregate) ?[:0]const u8 {
    const len = aggregate.directory_leaf_len;
    if (len == 0 or len >= aggregate.directory_leaf.len or aggregate.directory_leaf[len] != 0) return null;
    return aggregate.directory_leaf[0..len :0];
}

fn entryName(aggregate: *const reopen.ReopenedAggregate, index: usize) ?[:0]const u8 {
    if (index >= aggregate.names.len) return null;
    const len = aggregate.name_lens[index];
    if (len == 0 or len >= aggregate.names[index].len or aggregate.names[index][len] != 0) return null;
    return aggregate.names[index][0..len :0];
}

fn tombName(deletion: *const Deletion) ?[:0]const u8 {
    if (deletion.tomb_len == 0 or deletion.tomb_len >= deletion.tomb.len or deletion.tomb[deletion.tomb_len] != 0) return null;
    return deletion.tomb[0..deletion.tomb_len :0];
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

pub const testing_api = if (builtin.is_test) struct {
    pub fn execute(driver: anytype, verified: *const post.VerifiedRelease, deletion: *Deletion) !Outcome {
        return executeCore(driver, verified, deletion);
    }
    pub fn retry(driver: anytype, deletion: *Deletion) !Outcome {
        return retryCore(driver, deletion);
    }
    pub fn fenceConcreteTomb(aggregate: *reopen.ReopenedAggregate, deletion: *const Deletion) !void {
        var driver = ConcreteDriver{ .aggregate = aggregate, .allocator = undefined };
        try driver.requireTombIdentity(deletion);
    }
} else struct {};
