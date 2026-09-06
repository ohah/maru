//! Durable restart boundary for post-publish aggregate cleanup.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const context_mod = @import("release_adapter_context");
const reopen = @import("release_adapter_candidate_aggregate_reopen");
const retention = @import("release_adapter_candidate_aggregate_retention");
const post = @import("release_adapter_github_post_publish_attestation");
const safe_open = @import("safe_open");
const reducer = @import("release_adapter_candidate_aggregate_cleanup_reducer.zig");

extern "c" fn renameatx_np(from_dir_fd: c_int, from: [*:0]const u8, to_dir_fd: c_int, to: [*:0]const u8, flags: c_uint) c_int;
const rename_excl: c_uint = 0x00000004;
const intent_schema = "maru.session-host.aggregate-cleanup.v1";
const completion_schema = "maru.session-host.aggregate-cleanup.done.v1";
const max_record_bytes: usize = 32 * 1024;
const roles = [_][]const u8{ "evidence", "candidate_dmg_bundle", "candidate_frozen_bundle", "evidence_bundle", "manifest_bundle" };

pub const entry_count = reducer.entry_count;
pub const Outcome = reducer.Outcome;
pub const Location = reducer.Location;
pub const CompletionState = reducer.CompletionState;
pub const Inventory = reducer.Inventory;
pub const Recovery = reducer.Recovery;
pub const Plan = enum { initial, recoverable, audit_required };

/// Mutation-free routing probe. This is not deletion authority: begin/recover repeat every
/// identity and record check before any mutation.
pub fn classify(
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    original: [:0]const u8,
) !Plan {
    var driver = try ConcreteDriver.initRecover(allocator, context, original);
    errdefer driver.close() catch {};

    const plan: Plan = blk: {
        const completion = driver.inspectCompletion() catch break :blk .audit_required;
        if (completion != .absent) break :blk .recoverable;

        const intent = existsAt(driver.parent_fd, driver.names.intentValue()) catch break :blk .audit_required;
        const tomb = statOptionalAt(driver.parent_fd, driver.names.tombValue()) catch break :blk .audit_required;
        const original_stat = statOptionalAt(driver.parent_fd, driver.originalLeaf()) catch break :blk .audit_required;
        if (intent) {
            driver.loadIntent() catch break :blk .audit_required;
            const location = driver.locate() catch break :blk .audit_required;
            break :blk switch (location) {
                .original, .tomb, .removed => .recoverable,
                .ambiguous => .audit_required,
            };
        }
        if (tomb != null or original_stat == null or !validOwnedDirectory(original_stat.?)) break :blk .audit_required;
        break :blk .initial;
    };
    try driver.close();
    return plan;
}

/// Product entry point. The concrete filesystem driver is added below the pure restart reducer;
/// callers cannot submit a tomb name, record pathname, progress suffix, or success flag.
pub fn begin(
    allocator: std.mem.Allocator,
    aggregate: *reopen.ReopenedAggregate,
    verified: *const post.VerifiedRelease,
    result: *Recovery,
) !Outcome {
    const result_bytes = std.mem.asBytes(result);
    if (overlaps(result_bytes, std.mem.asBytes(aggregate)) or overlaps(result_bytes, std.mem.asBytes(verified)) or
        overlaps(std.mem.asBytes(aggregate), std.mem.asBytes(verified))) return error.InvalidOwner;
    var driver = try ConcreteDriver.initBegin(allocator, aggregate, verified);
    return reducer.begin(&driver, result);
}

/// Restart derives every durable pathname from protected context and the canonical original path.
pub fn recover(
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    original: [:0]const u8,
    result: *Recovery,
) !Outcome {
    const result_bytes = std.mem.asBytes(result);
    if (overlaps(result_bytes, original) or contextOverlaps(result_bytes, context)) return error.InvalidOwner;
    var driver = try ConcreteDriver.initRecover(allocator, context, original);
    return reducer.recover(&driver, result);
}

pub fn assertProductionBoundary() void {
    _ = &classify;
    _ = &begin;
    _ = &recover;
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn contextOverlaps(bytes: []const u8, context: context_mod.Context) bool {
    return overlaps(bytes, context.repository.owner) or overlaps(bytes, context.repository.name) or
        overlaps(bytes, context.tag) or overlaps(bytes, context.source_commit) or overlaps(bytes, context.build.workflow_ref);
}

const StoredEntry = struct {
    name: [std.fs.max_name_bytes:0]u8 = @splat(0),
    name_len: usize = 0,
    device: u64 = 0,
    inode: u64 = 0,
    size: u64 = 0,
    sha256: [64]u8 = @splat(0),

    fn nameValue(self: *const @This()) [:0]const u8 {
        return self.name[0..self.name_len :0];
    }
};

const StoredRecord = struct {
    repository_id: u64 = 0,
    tag: [context_mod.max_value_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    workflow_ref: [context_mod.max_value_bytes]u8 = @splat(0),
    workflow_ref_len: usize = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,
    release_id: u64 = 0,
    original: [std.fs.max_path_bytes:0]u8 = @splat(0),
    original_len: usize = 0,
    tomb: [std.fs.max_name_bytes:0]u8 = @splat(0),
    tomb_len: usize = 0,
    directory_device: u64 = 0,
    directory_inode: u64 = 0,
    directory_uid: u64 = 0,
    directory_mode: u32 = 0,
    entries: [entry_count]StoredEntry = @splat(.{}),
    payload_sha256: [64]u8 = @splat(0),

    fn originalValue(self: *const @This()) [:0]const u8 {
        return self.original[0..self.original_len :0];
    }
    fn tombValue(self: *const @This()) [:0]const u8 {
        return self.tomb[0..self.tomb_len :0];
    }
};

const WireEntry = struct {
    role: []const u8,
    name: []const u8,
    device: u64,
    inode: u64,
    size: u64,
    sha256: []const u8,
};

const IntentWire = struct {
    schema: []const u8,
    repository_id: u64,
    tag: []const u8,
    source_commit: []const u8,
    workflow_ref: []const u8,
    run_id: u64,
    run_attempt: u64,
    release_id: u64,
    original: []const u8,
    tomb: []const u8,
    directory_device: u64,
    directory_inode: u64,
    directory_uid: u64,
    directory_mode: u32,
    entries: []const WireEntry,
    payload_sha256: []const u8,
};

const CompletionWire = struct {
    schema: []const u8,
    repository_id: u64,
    tag: []const u8,
    source_commit: []const u8,
    workflow_ref: []const u8,
    run_id: u64,
    run_attempt: u64,
    release_id: u64,
    original: []const u8,
    tomb: []const u8,
    directory_device: u64,
    directory_inode: u64,
    directory_uid: u64,
    directory_mode: u32,
    intent_payload_sha256: []const u8,
    payload_sha256: []const u8,
};

const Names = struct {
    intent: [std.fs.max_name_bytes:0]u8 = @splat(0),
    intent_len: usize = 0,
    intent_temp: [std.fs.max_name_bytes:0]u8 = @splat(0),
    intent_temp_len: usize = 0,
    completion: [std.fs.max_name_bytes:0]u8 = @splat(0),
    completion_len: usize = 0,
    completion_temp: [std.fs.max_name_bytes:0]u8 = @splat(0),
    completion_temp_len: usize = 0,
    tomb: [std.fs.max_name_bytes:0]u8 = @splat(0),
    tomb_len: usize = 0,

    fn intentValue(self: *const @This()) [:0]const u8 {
        return self.intent[0..self.intent_len :0];
    }
    fn intentTempValue(self: *const @This()) [:0]const u8 {
        return self.intent_temp[0..self.intent_temp_len :0];
    }
    fn completionValue(self: *const @This()) [:0]const u8 {
        return self.completion[0..self.completion_len :0];
    }
    fn completionTempValue(self: *const @This()) [:0]const u8 {
        return self.completion_temp[0..self.completion_temp_len :0];
    }
    fn tombValue(self: *const @This()) [:0]const u8 {
        return self.tomb[0..self.tomb_len :0];
    }
};

const ConcreteDriver = struct {
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    original_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    original_path_len: usize = 0,
    original_leaf: [std.fs.max_name_bytes:0]u8 = @splat(0),
    original_leaf_len: usize = 0,
    names: Names = .{},
    parent_fd: c.fd_t = -1,
    directory_fd: c.fd_t = -1,
    owns_directory_fd: bool = false,
    aggregate: ?*reopen.ReopenedAggregate = null,
    verified: ?*const post.VerifiedRelease = null,
    record: StoredRecord = .{},
    record_loaded: bool = false,
    crash_after: ?usize = null,
    checkpoint: usize = 0,

    fn initBegin(allocator: std.mem.Allocator, aggregate: *reopen.ReopenedAggregate, verified: *const post.VerifiedRelease) !ConcreteDriver {
        const view = aggregate.value() orelse return error.InvalidOwner;
        var self = try initCommon(allocator, view.context, aggregate.directory[0..aggregate.directory_len :0]);
        self.parent_fd = aggregate.parent_fd;
        self.directory_fd = aggregate.directory_fd;
        self.aggregate = aggregate;
        self.verified = verified;
        return self;
    }

    fn initRecover(allocator: std.mem.Allocator, context: context_mod.Context, original: [:0]const u8) !ConcreteDriver {
        var self = try initCommon(allocator, context, original);
        const parent_path = std.fs.path.dirname(original) orelse return error.InvalidPath;
        var parent_z: [std.fs.max_path_bytes:0]u8 = undefined;
        const path = std.fmt.bufPrintZ(&parent_z, "{s}", .{parent_path}) catch return error.InvalidPath;
        self.parent_fd = safe_open.openAbsoluteNoFollow(path, true) catch return error.InvalidPath;
        return self;
    }

    fn initCommon(allocator: std.mem.Allocator, context: context_mod.Context, original: [:0]const u8) !ConcreteDriver {
        try validateContext(context);
        if (!canonicalAbsolute(original)) return error.InvalidPath;
        var self = ConcreteDriver{ .allocator = allocator, .context = context };
        self.original_path_len = original.len;
        @memcpy(self.original_path[0..original.len], original);
        self.original_path[original.len] = 0;
        const leaf = std.fs.path.basename(original);
        self.original_leaf_len = try storeName(&self.original_leaf, leaf);
        try deriveNames(context, original, &self.names);
        try deriveAttemptTempNames(&self.names);
        return self;
    }

    pub fn validate(self: *@This()) !void {
        const aggregate = self.aggregate orelse return error.InvalidOwner;
        const verified = self.verified orelse return error.InvalidOwner;
        try retention.validateVerifiedAggregate(self.allocator, aggregate, verified);
        const receipt = verified.value() orelse return error.InvalidOwner;
        const view = try aggregate.fence();
        try self.captureRecord(view, receipt);
    }

    pub fn inspectCompletion(self: *@This()) !CompletionState {
        const bytes = readOptionalAt(self.allocator, self.parent_fd, self.names.completionValue(), max_record_bytes, null) catch |err| switch (err) {
            error.FileNotFound => return .absent,
            else => return err,
        };
        defer self.allocator.free(bytes);
        var parsed = try parseCompletion(self.allocator, bytes);
        defer parsed.deinit();
        try validateCompletion(self.allocator, parsed.value, self.context, &self.names, self.original_path[0..self.original_path_len], null);
        const intent_exists = existsAt(self.parent_fd, self.names.intentValue()) catch return error.InvalidRecord;
        if (intent_exists) {
            try self.loadIntent();
            try validateCompletion(self.allocator, parsed.value, self.context, &self.names, self.original_path[0..self.original_path_len], &self.record);
        }
        const original_exists = existsAt(self.parent_fd, self.originalLeaf()) catch return error.InvalidRecord;
        const tomb_exists = existsAt(self.parent_fd, self.names.tombValue()) catch return error.InvalidRecord;
        if (original_exists or tomb_exists) return error.InvalidRecord;
        return if (intent_exists) .durable_with_intent else .durable;
    }

    pub fn publishIntent(self: *@This()) !void {
        if (!self.record_loaded) return error.InvalidOwner;
        if (try existsAt(self.parent_fd, self.names.intentValue())) {
            const existing = try readOptionalAt(self.allocator, self.parent_fd, self.names.intentValue(), max_record_bytes, null);
            defer self.allocator.free(existing);
            var parsed = try parseIntent(self.allocator, existing);
            defer parsed.deinit();
            var stored: StoredRecord = .{};
            try validateIntent(self.allocator, parsed.value, self.context, self.original_path[0..self.original_path_len], &self.names, &stored);
            if (!sameRecord(&self.record, &stored)) return error.InvalidRecord;
            return;
        }
        if (try existsAt(self.parent_fd, self.names.completionValue()) or try existsAt(self.parent_fd, self.names.tombValue())) return error.InvalidRecord;
        const bytes = try writeIntent(self.allocator, &self.record);
        defer self.allocator.free(bytes);
        try publishNoReplace(self.parent_fd, self.names.intentTempValue(), self.names.intentValue(), bytes);
        self.hitCheckpoint();
    }

    pub fn syncParentAfterIntent(self: *@This()) !void {
        try syncFd(self.parent_fd);
        self.hitCheckpoint();
    }

    pub fn locate(self: *@This()) !Location {
        if (!self.record_loaded) try self.loadIntent();
        const original = try statOptionalAt(self.parent_fd, self.originalLeaf());
        const tomb = try statOptionalAt(self.parent_fd, self.names.tombValue());
        if (original != null and tomb != null) return .ambiguous;
        if (original) |stat| {
            if (!sameDirectoryRecord(stat, &self.record)) return error.InvalidRecord;
            return .original;
        }
        if (tomb) |stat| {
            if (!sameDirectoryRecord(stat, &self.record)) return error.InvalidRecord;
            try self.ensureDirectoryOpen();
            return .tomb;
        }
        return .removed;
    }

    pub fn rename(self: *@This()) !void {
        if (!self.record_loaded) return error.InvalidOwner;
        if (renameatx_np(self.parent_fd, self.originalLeaf().ptr, self.parent_fd, self.names.tombValue().ptr, rename_excl) != 0)
            return error.CleanupFailed;
        try self.ensureDirectoryOpen();
        self.hitCheckpoint();
    }
    pub fn syncParentAfterRename(self: *@This()) !void {
        try syncFd(self.parent_fd);
        self.hitCheckpoint();
    }

    pub fn inspectInventory(self: *@This()) !Inventory {
        try self.ensureDirectoryOpen();
        try self.requireTombIdentity();
        var result = Inventory{ .present = @splat(false) };
        var seen: [entry_count]bool = @splat(false);
        const scan_fd = c.openat(self.directory_fd, ".", posix.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
        if (scan_fd < 0) return error.InvalidRecord;
        const directory = c.fdopendir(scan_fd) orelse {
            _ = c.close(scan_fd);
            return error.InvalidRecord;
        };
        var directory_open = true;
        defer if (directory_open) {
            _ = c.closedir(directory);
        };
        c._errno().* = 0;
        while (c.readdir(directory)) |entry| {
            const name = std.mem.sliceTo(entry.name[0..], 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var matched: ?usize = null;
            for (&self.record.entries, 0..) |*expected, index| if (std.mem.eql(u8, name, expected.nameValue())) {
                matched = index;
                break;
            };
            const index = matched orelse {
                result.unexpected = true;
                continue;
            };
            if (seen[index]) {
                result.unexpected = true;
                continue;
            }
            seen[index] = true;
            result.present[index] = true;
            validateEntryAt(self.parent_fd, self.directory_fd, &self.record.entries[index]) catch {
                result.foreign = index;
            };
        }
        if (c._errno().* != 0) return error.InvalidRecord;
        directory_open = false;
        if (c.closedir(directory) != 0) return error.InvalidRecord;
        return result;
    }

    pub fn unlink(self: *@This(), index: usize) !void {
        if (index >= entry_count) return error.InvalidOwner;
        try self.requireTombIdentity();
        try validateEntryAt(self.parent_fd, self.directory_fd, &self.record.entries[index]);
        if (c.unlinkat(self.directory_fd, self.record.entries[index].nameValue().ptr, 0) != 0) return error.CleanupFailed;
        self.hitCheckpoint();
    }
    pub fn syncTomb(self: *@This()) !void {
        try syncFd(self.directory_fd);
        self.hitCheckpoint();
    }
    pub fn removeTomb(self: *@This()) !void {
        try self.requireTombIdentity();
        if (c.unlinkat(self.parent_fd, self.names.tombValue().ptr, posix.AT.REMOVEDIR) != 0) return error.CleanupFailed;
        self.hitCheckpoint();
    }
    pub fn syncParentAfterTomb(self: *@This()) !void {
        try syncFd(self.parent_fd);
        self.hitCheckpoint();
    }

    pub fn publishCompletion(self: *@This()) !void {
        if (!self.record_loaded or try existsAt(self.parent_fd, self.originalLeaf()) or try existsAt(self.parent_fd, self.names.tombValue()))
            return error.InvalidRecord;
        if (try existsAt(self.parent_fd, self.names.completionValue())) {
            const existing = try readOptionalAt(self.allocator, self.parent_fd, self.names.completionValue(), max_record_bytes, null);
            defer self.allocator.free(existing);
            var parsed = try parseCompletion(self.allocator, existing);
            defer parsed.deinit();
            try validateCompletion(self.allocator, parsed.value, self.context, &self.names, self.original_path[0..self.original_path_len], &self.record);
            return;
        }
        const bytes = try writeCompletion(self.allocator, &self.record);
        defer self.allocator.free(bytes);
        try publishNoReplace(self.parent_fd, self.names.completionTempValue(), self.names.completionValue(), bytes);
        self.hitCheckpoint();
    }
    pub fn syncParentAfterCompletion(self: *@This()) !void {
        try syncFd(self.parent_fd);
        self.hitCheckpoint();
    }
    pub fn removeIntent(self: *@This()) !void {
        if (!self.record_loaded) try self.loadIntent();
        var held_identity: posix.Stat = undefined;
        const bytes = try readOptionalAt(self.allocator, self.parent_fd, self.names.intentValue(), max_record_bytes, &held_identity);
        defer self.allocator.free(bytes);
        var parsed = try parseIntent(self.allocator, bytes);
        defer parsed.deinit();
        try validateIntent(self.allocator, parsed.value, self.context, self.original_path[0..self.original_path_len], &self.names, null);
        var named_identity: posix.Stat = undefined;
        if (c.fstatat(self.parent_fd, self.names.intentValue().ptr, &named_identity, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !sameFileIdentity(held_identity, named_identity)) return error.InvalidRecord;
        if (c.unlinkat(self.parent_fd, self.names.intentValue().ptr, 0) != 0) return error.CleanupFailed;
        self.hitCheckpoint();
    }
    pub fn syncParentFinal(self: *@This()) !void {
        try syncFd(self.parent_fd);
        self.hitCheckpoint();
    }

    fn hitCheckpoint(self: *@This()) void {
        self.checkpoint += 1;
        if (self.crash_after) |target| if (target == self.checkpoint) c._exit(91);
    }

    pub fn close(self: *@This()) !void {
        var failed = false;
        if (self.aggregate) |aggregate| {
            aggregate.deinit() catch {
                failed = true;
            };
            self.aggregate = null;
            self.parent_fd = -1;
            self.directory_fd = -1;
        } else {
            if (self.owns_directory_fd and self.directory_fd >= 0 and c.close(self.directory_fd) != 0) failed = true;
            self.directory_fd = -1;
            self.owns_directory_fd = false;
            if (self.parent_fd >= 0 and c.close(self.parent_fd) != 0) failed = true;
            self.parent_fd = -1;
        }
        if (failed) return error.DescriptorCloseFailed;
    }

    fn originalLeaf(self: *const @This()) [:0]const u8 {
        return self.original_leaf[0..self.original_leaf_len :0];
    }

    fn captureRecord(self: *@This(), view: reopen.View, receipt: post.View) !void {
        var stat: posix.Stat = undefined;
        if (c.fstat(self.directory_fd, &stat) != 0 or !validOwnedDirectory(stat)) return error.InvalidRecord;
        self.record = .{
            .repository_id = view.context.repository.id,
            .release_id = receipt.release_id,
            .directory_device = @intCast(stat.dev),
            .directory_inode = @intCast(stat.ino),
            .directory_uid = @intCast(stat.uid),
            .directory_mode = @intCast(stat.mode & 0o777),
        };
        self.record.tag_len = try storeFixed(&self.record.tag, view.context.tag);
        @memcpy(&self.record.source_commit, view.context.source_commit);
        self.record.workflow_ref_len = try storeFixed(&self.record.workflow_ref, view.context.build.workflow_ref);
        self.record.run_id = view.context.build.run_id;
        self.record.run_attempt = view.context.build.run_attempt;
        self.record.original_len = try storePath(&self.record.original, self.original_path[0..self.original_path_len]);
        self.record.tomb_len = try storeName(&self.record.tomb, self.names.tombValue());
        for (&self.record.entries, 0..) |*entry, index| {
            const observed = view.entries[index];
            entry.name_len = try storeName(&entry.name, aggregateName(self.aggregate.?, index));
            entry.device = observed.identity.device;
            entry.inode = observed.identity.inode;
            entry.size = observed.size;
            entry.sha256 = observed.sha256;
        }
        const payload = try writeIntentPayload(self.allocator, &self.record);
        defer self.allocator.free(payload);
        self.record.payload_sha256 = sha256Hex(payload);
        self.record_loaded = true;
    }

    fn loadIntent(self: *@This()) !void {
        const bytes = try readOptionalAt(self.allocator, self.parent_fd, self.names.intentValue(), max_record_bytes, null);
        defer self.allocator.free(bytes);
        var parsed = try parseIntent(self.allocator, bytes);
        defer parsed.deinit();
        try validateIntent(self.allocator, parsed.value, self.context, self.original_path[0..self.original_path_len], &self.names, &self.record);
        self.record_loaded = true;
    }

    fn ensureDirectoryOpen(self: *@This()) !void {
        if (self.directory_fd >= 0) return self.requireTombIdentity();
        self.directory_fd = c.openat(self.parent_fd, self.names.tombValue().ptr, posix.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
        if (self.directory_fd < 0) return error.InvalidRecord;
        self.owns_directory_fd = true;
        try self.requireTombIdentity();
    }

    fn requireTombIdentity(self: *@This()) !void {
        if (!self.record_loaded or self.directory_fd < 0) return error.InvalidOwner;
        var held: posix.Stat = undefined;
        var named: posix.Stat = undefined;
        if (c.fstat(self.directory_fd, &held) != 0 or c.fstatat(self.parent_fd, self.names.tombValue().ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !sameDirectoryRecord(held, &self.record) or !sameDirectoryRecord(named, &self.record)) return error.InvalidRecord;
    }
};

fn deriveNames(context: context_mod.Context, original: []const u8, result: *Names) !void {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.session-host.aggregate-cleanup-path.v1\x00");
    hashU64(&hasher, context.repository.id);
    hashField(&hasher, context.repository.owner);
    hashField(&hasher, context.repository.name);
    hashField(&hasher, context.tag);
    hashField(&hasher, context.source_commit);
    hashField(&hasher, context.build.workflow_ref);
    hashU64(&hasher, context.build.run_id);
    hashU64(&hasher, context.build.run_attempt);
    hashField(&hasher, original);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const key = std.fmt.bytesToHex(digest, .lower);
    result.intent_len = (std.fmt.bufPrintZ(&result.intent, ".maru-aggregate-cleanup-{s}.json", .{&key}) catch return error.InvalidPath).len;
    result.completion_len = (std.fmt.bufPrintZ(&result.completion, ".maru-aggregate-cleanup-{s}.done.json", .{&key}) catch return error.InvalidPath).len;
    result.tomb_len = (std.fmt.bufPrintZ(&result.tomb, ".maru-aggregate-cleanup-{s}.tomb", .{&key}) catch return error.InvalidPath).len;
}

fn hashU64(hasher: *std.crypto.hash.Blake3, value: u64) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .big);
    hasher.update(&encoded);
}

fn hashField(hasher: *std.crypto.hash.Blake3, value: []const u8) void {
    hashU64(hasher, value.len);
    hasher.update(value);
}

fn deriveAttemptTempNames(result: *Names) !void {
    var entropy: [16]u8 = undefined;
    c.arc4random_buf(&entropy, entropy.len);
    const suffix = std.fmt.bytesToHex(entropy, .lower);
    result.intent_temp_len = (std.fmt.bufPrintZ(&result.intent_temp, "{s}.tmp-{s}", .{ result.intentValue(), &suffix }) catch return error.InvalidPath).len;
    result.completion_temp_len = (std.fmt.bufPrintZ(&result.completion_temp, "{s}.tmp-{s}", .{ result.completionValue(), &suffix }) catch return error.InvalidPath).len;
}

fn wireEntries(record: *const StoredRecord) [entry_count]WireEntry {
    var result: [entry_count]WireEntry = undefined;
    for (&result, 0..) |*entry, index| entry.* = .{
        .role = roles[index],
        .name = record.entries[index].nameValue(),
        .device = record.entries[index].device,
        .inode = record.entries[index].inode,
        .size = record.entries[index].size,
        .sha256 = &record.entries[index].sha256,
    };
    return result;
}

fn writeIntentPayload(allocator: std.mem.Allocator, record: *const StoredRecord) ![]u8 {
    const entries = wireEntries(record);
    return writeJson(allocator, .{
        .schema = intent_schema,
        .repository_id = record.repository_id,
        .tag = record.tag[0..record.tag_len],
        .source_commit = &record.source_commit,
        .workflow_ref = record.workflow_ref[0..record.workflow_ref_len],
        .run_id = record.run_id,
        .run_attempt = record.run_attempt,
        .release_id = record.release_id,
        .original = record.originalValue(),
        .tomb = record.tombValue(),
        .directory_device = record.directory_device,
        .directory_inode = record.directory_inode,
        .directory_uid = record.directory_uid,
        .directory_mode = record.directory_mode,
        .entries = &entries,
    });
}

fn writeIntent(allocator: std.mem.Allocator, record: *const StoredRecord) ![]u8 {
    const entries = wireEntries(record);
    return writeJson(allocator, .{
        .schema = intent_schema,
        .repository_id = record.repository_id,
        .tag = record.tag[0..record.tag_len],
        .source_commit = &record.source_commit,
        .workflow_ref = record.workflow_ref[0..record.workflow_ref_len],
        .run_id = record.run_id,
        .run_attempt = record.run_attempt,
        .release_id = record.release_id,
        .original = record.originalValue(),
        .tomb = record.tombValue(),
        .directory_device = record.directory_device,
        .directory_inode = record.directory_inode,
        .directory_uid = record.directory_uid,
        .directory_mode = record.directory_mode,
        .entries = &entries,
        .payload_sha256 = &record.payload_sha256,
    });
}

fn writeCompletion(allocator: std.mem.Allocator, record: *const StoredRecord) ![]u8 {
    const payload = try writeCompletionPayload(allocator, record);
    defer allocator.free(payload);
    const payload_sha256 = sha256Hex(payload);
    return writeJson(allocator, .{
        .schema = completion_schema,
        .repository_id = record.repository_id,
        .tag = record.tag[0..record.tag_len],
        .source_commit = &record.source_commit,
        .workflow_ref = record.workflow_ref[0..record.workflow_ref_len],
        .run_id = record.run_id,
        .run_attempt = record.run_attempt,
        .release_id = record.release_id,
        .original = record.originalValue(),
        .tomb = record.tombValue(),
        .directory_device = record.directory_device,
        .directory_inode = record.directory_inode,
        .directory_uid = record.directory_uid,
        .directory_mode = record.directory_mode,
        .intent_payload_sha256 = &record.payload_sha256,
        .payload_sha256 = &payload_sha256,
    });
}

fn writeCompletionPayload(allocator: std.mem.Allocator, record: *const StoredRecord) ![]u8 {
    return writeJson(allocator, .{
        .schema = completion_schema,
        .repository_id = record.repository_id,
        .tag = record.tag[0..record.tag_len],
        .source_commit = &record.source_commit,
        .workflow_ref = record.workflow_ref[0..record.workflow_ref_len],
        .run_id = record.run_id,
        .run_attempt = record.run_attempt,
        .release_id = record.release_id,
        .original = record.originalValue(),
        .tomb = record.tombValue(),
        .directory_device = record.directory_device,
        .directory_inode = record.directory_inode,
        .directory_uid = record.directory_uid,
        .directory_mode = record.directory_mode,
        .intent_payload_sha256 = &record.payload_sha256,
    });
}

fn writeJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    json.write(value) catch return error.OutOfMemory;
    output.writer.writeByte('\n') catch return error.OutOfMemory;
    if (output.writer.buffered().len > max_record_bytes) return error.RecordTooLarge;
    return output.toOwnedSlice();
}

fn parseIntent(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(IntentWire) {
    if (bytes.len == 0 or bytes.len > max_record_bytes or bytes[bytes.len - 1] != '\n') return error.InvalidRecord;
    var parsed = std.json.parseFromSlice(IntentWire, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false, .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRecord,
    };
    errdefer parsed.deinit();
    const canonical = try writeIntentWire(allocator, parsed.value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical)) return error.InvalidRecord;
    return parsed;
}

fn writeIntentWire(allocator: std.mem.Allocator, value: IntentWire) ![]u8 {
    return writeJson(allocator, .{
        .schema = value.schema,
        .repository_id = value.repository_id,
        .tag = value.tag,
        .source_commit = value.source_commit,
        .workflow_ref = value.workflow_ref,
        .run_id = value.run_id,
        .run_attempt = value.run_attempt,
        .release_id = value.release_id,
        .original = value.original,
        .tomb = value.tomb,
        .directory_device = value.directory_device,
        .directory_inode = value.directory_inode,
        .directory_uid = value.directory_uid,
        .directory_mode = value.directory_mode,
        .entries = value.entries,
        .payload_sha256 = value.payload_sha256,
    });
}

fn writeIntentWirePayload(allocator: std.mem.Allocator, value: IntentWire) ![]u8 {
    return writeJson(allocator, .{
        .schema = value.schema,
        .repository_id = value.repository_id,
        .tag = value.tag,
        .source_commit = value.source_commit,
        .workflow_ref = value.workflow_ref,
        .run_id = value.run_id,
        .run_attempt = value.run_attempt,
        .release_id = value.release_id,
        .original = value.original,
        .tomb = value.tomb,
        .directory_device = value.directory_device,
        .directory_inode = value.directory_inode,
        .directory_uid = value.directory_uid,
        .directory_mode = value.directory_mode,
        .entries = value.entries,
    });
}

fn validateIntent(allocator: std.mem.Allocator, value: IntentWire, context: context_mod.Context, original_path: []const u8, names: *const Names, output: ?*StoredRecord) !void {
    if (!std.mem.eql(u8, value.schema, intent_schema) or value.repository_id != context.repository.id or
        !std.mem.eql(u8, value.tag, context.tag) or !std.mem.eql(u8, value.source_commit, context.source_commit) or
        !std.mem.eql(u8, value.workflow_ref, context.build.workflow_ref) or value.run_id != context.build.run_id or
        value.run_attempt != context.build.run_attempt or value.release_id == 0 or
        !std.mem.eql(u8, value.original, original_path) or !std.mem.eql(u8, value.tomb, names.tombValue()) or
        value.directory_device == 0 or value.directory_inode == 0 or value.directory_uid != @as(u64, @intCast(c.getuid())) or
        value.directory_mode != 0o700 or value.entries.len != entry_count or !lowerHex(value.payload_sha256, 64)) return error.InvalidRecord;
    var seen_device: [entry_count]u64 = @splat(0);
    var seen_inode: [entry_count]u64 = @splat(0);
    for (value.entries, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.role, roles[index]) or !validComponent(entry.name) or entry.device == 0 or
            entry.inode == 0 or entry.size == 0 or !lowerHex(entry.sha256, 64)) return error.InvalidRecord;
        for (seen_inode[0..index], seen_device[0..index]) |prior_inode, prior_device|
            if (prior_inode == entry.inode and prior_device == entry.device) return error.InvalidRecord;
        seen_device[index] = entry.device;
        seen_inode[index] = entry.inode;
    }
    const payload = try writeIntentWirePayload(allocator, value);
    defer allocator.free(payload);
    const digest = sha256Hex(payload);
    if (!std.crypto.timing_safe.eql([64]u8, digest, value.payload_sha256[0..64].*)) return error.InvalidRecord;
    if (output) |record| try storeIntent(value, record);
}

fn storeIntent(value: IntentWire, record: *StoredRecord) !void {
    record.* = .{
        .repository_id = value.repository_id,
        .release_id = value.release_id,
        .directory_device = value.directory_device,
        .directory_inode = value.directory_inode,
        .directory_uid = value.directory_uid,
        .directory_mode = value.directory_mode,
    };
    record.tag_len = try storeFixed(&record.tag, value.tag);
    @memcpy(&record.source_commit, value.source_commit);
    record.workflow_ref_len = try storeFixed(&record.workflow_ref, value.workflow_ref);
    record.run_id = value.run_id;
    record.run_attempt = value.run_attempt;
    record.original_len = try storePath(&record.original, value.original);
    record.tomb_len = try storeName(&record.tomb, value.tomb);
    @memcpy(&record.payload_sha256, value.payload_sha256);
    for (&record.entries, value.entries) |*stored, entry| {
        stored.name_len = try storeName(&stored.name, entry.name);
        stored.device = entry.device;
        stored.inode = entry.inode;
        stored.size = entry.size;
        @memcpy(&stored.sha256, entry.sha256);
    }
}

fn parseCompletion(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(CompletionWire) {
    if (bytes.len == 0 or bytes.len > max_record_bytes or bytes[bytes.len - 1] != '\n') return error.InvalidRecord;
    var parsed = std.json.parseFromSlice(CompletionWire, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false, .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRecord,
    };
    errdefer parsed.deinit();
    const canonical = try writeJson(allocator, parsed.value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical)) return error.InvalidRecord;
    return parsed;
}

fn validateCompletion(allocator: std.mem.Allocator, value: CompletionWire, context: context_mod.Context, names: *const Names, original_path: []const u8, record: ?*const StoredRecord) !void {
    if (!std.mem.eql(u8, value.schema, completion_schema) or value.repository_id != context.repository.id or
        !std.mem.eql(u8, value.tag, context.tag) or !std.mem.eql(u8, value.source_commit, context.source_commit) or
        !std.mem.eql(u8, value.workflow_ref, context.build.workflow_ref) or value.run_id != context.build.run_id or
        value.run_attempt != context.build.run_attempt or value.release_id == 0 or
        !std.mem.eql(u8, value.original, original_path) or !std.mem.eql(u8, value.tomb, names.tombValue()) or
        value.directory_device == 0 or value.directory_inode == 0 or value.directory_uid != @as(u64, @intCast(c.getuid())) or
        value.directory_mode != 0o700 or
        !lowerHex(value.intent_payload_sha256, 64) or !lowerHex(value.payload_sha256, 64)) return error.InvalidRecord;
    const payload = try writeJson(allocator, .{
        .schema = value.schema,
        .repository_id = value.repository_id,
        .tag = value.tag,
        .source_commit = value.source_commit,
        .workflow_ref = value.workflow_ref,
        .run_id = value.run_id,
        .run_attempt = value.run_attempt,
        .release_id = value.release_id,
        .original = value.original,
        .tomb = value.tomb,
        .directory_device = value.directory_device,
        .directory_inode = value.directory_inode,
        .directory_uid = value.directory_uid,
        .directory_mode = value.directory_mode,
        .intent_payload_sha256 = value.intent_payload_sha256,
    });
    defer allocator.free(payload);
    const payload_digest = sha256Hex(payload);
    if (!std.crypto.timing_safe.eql([64]u8, payload_digest, value.payload_sha256[0..64].*)) return error.InvalidRecord;
    if (record) |expected| {
        if (value.release_id != expected.release_id or value.directory_device != expected.directory_device or
            value.directory_inode != expected.directory_inode or value.directory_uid != expected.directory_uid or
            value.directory_mode != expected.directory_mode or
            !std.crypto.timing_safe.eql([64]u8, value.intent_payload_sha256[0..64].*, expected.payload_sha256))
            return error.InvalidRecord;
    }
}

fn publishNoReplace(parent_fd: c.fd_t, temp: [:0]const u8, final: [:0]const u8, bytes: []const u8) !void {
    const fd = c.openat(parent_fd, temp.ptr, posix.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.InvalidRecord;
    var open = true;
    defer if (open) {
        _ = c.close(fd);
    };
    var held: posix.Stat = undefined;
    if (c.fstat(fd, &held) != 0 or !validOwnedFile(held, 0)) return error.CleanupFailed;
    var published = false;
    errdefer if (!published) cleanupOwnedTemp(parent_fd, temp, held);
    try writeAllFd(fd, bytes);
    if (c.fchmod(fd, 0o600) != 0 or c.fsync(fd) != 0 or c.fstat(fd, &held) != 0 or !validOwnedFile(held, bytes.len))
        return error.CleanupFailed;
    if (renameatx_np(parent_fd, temp.ptr, parent_fd, final.ptr, rename_excl) != 0) return error.InvalidRecord;
    published = true;
    var named: posix.Stat = undefined;
    if (c.fstatat(parent_fd, final.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or !sameFileIdentity(held, named))
        return error.CleanupFailed;
    open = false;
    if (c.close(fd) != 0) return error.CleanupFailed;
}

fn cleanupOwnedTemp(parent_fd: c.fd_t, temp: [:0]const u8, held: posix.Stat) void {
    var named: posix.Stat = undefined;
    if (c.fstatat(parent_fd, temp.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) == 0 and sameFileIdentity(held, named)) {
        _ = c.unlinkat(parent_fd, temp.ptr, 0);
        _ = c.fsync(parent_fd);
    }
}

fn sameFileIdentity(a: posix.Stat, b: posix.Stat) bool {
    return a.dev == b.dev and a.ino == b.ino and posix.S.ISREG(a.mode) and posix.S.ISREG(b.mode);
}

fn readOptionalAt(allocator: std.mem.Allocator, parent_fd: c.fd_t, name: [:0]const u8, cap: usize, identity: ?*posix.Stat) ![]u8 {
    const fd = c.openat(parent_fd, name.ptr, posix.O{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) {
        if (c._errno().* == @intFromEnum(posix.E.NOENT)) return error.FileNotFound;
        return error.InvalidRecord;
    }
    var open = true;
    defer if (open) {
        _ = c.close(fd);
    };
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or stat.mode & 0o777 != 0o600 or
        stat.nlink != 1 or stat.size <= 0 or stat.size > cap) return error.InvalidRecord;
    const size: usize = @intCast(stat.size);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < size) {
        const count = c.pread(fd, bytes[offset..].ptr, size - offset, @intCast(offset));
        if (count <= 0) return error.InvalidRecord;
        offset += @intCast(count);
    }
    var after: posix.Stat = undefined;
    if (c.fstat(fd, &after) != 0 or stat.dev != after.dev or stat.ino != after.ino or stat.size != after.size or stat.mode != after.mode or stat.nlink != after.nlink)
        return error.InvalidRecord;
    if (identity) |output| output.* = after;
    open = false;
    if (c.close(fd) != 0) return error.InvalidRecord;
    return bytes;
}

fn writeAllFd(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count <= 0) return error.CleanupFailed;
        offset += @intCast(count);
    }
}

fn statOptionalAt(parent_fd: c.fd_t, name: [:0]const u8) !?posix.Stat {
    var stat: posix.Stat = undefined;
    if (c.fstatat(parent_fd, name.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) == 0) return stat;
    if (c._errno().* == @intFromEnum(posix.E.NOENT)) return null;
    return error.InvalidRecord;
}

fn existsAt(parent_fd: c.fd_t, name: [:0]const u8) !bool {
    return (try statOptionalAt(parent_fd, name)) != null;
}

fn validateEntryAt(_: c.fd_t, directory_fd: c.fd_t, expected: *const StoredEntry) !void {
    var stat: posix.Stat = undefined;
    if (c.fstatat(directory_fd, expected.nameValue().ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or stat.nlink != 1 or stat.size != expected.size or
        @as(u64, @intCast(stat.dev)) != expected.device or @as(u64, @intCast(stat.ino)) != expected.inode) return error.InvalidRecord;
    const fd = c.openat(directory_fd, expected.nameValue().ptr, posix.O{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.InvalidRecord;
    var open = true;
    defer if (open) {
        _ = c.close(fd);
    };
    var held_before: posix.Stat = undefined;
    if (c.fstat(fd, &held_before) != 0 or @as(u64, @intCast(held_before.dev)) != expected.device or
        @as(u64, @intCast(held_before.ino)) != expected.inode or held_before.size != expected.size or held_before.nlink != 1)
        return error.InvalidRecord;
    const digest = try hashFd(fd, expected.size);
    var held_after: posix.Stat = undefined;
    if (c.fstat(fd, &held_after) != 0 or held_before.dev != held_after.dev or held_before.ino != held_after.ino or
        held_before.size != held_after.size or held_before.mode != held_after.mode or held_before.nlink != held_after.nlink)
        return error.InvalidRecord;
    open = false;
    if (c.close(fd) != 0) return error.InvalidRecord;
    if (!std.crypto.timing_safe.eql([64]u8, digest, expected.sha256)) return error.InvalidRecord;
}

fn hashFd(fd: c.fd_t, expected_size: u64) ![64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < expected_size) {
        const wanted: usize = @intCast(@min(expected_size - offset, buffer.len));
        const count = c.pread(fd, &buffer, wanted, @intCast(offset));
        if (count <= 0) return error.InvalidRecord;
        const used: usize = @intCast(count);
        hasher.update(buffer[0..used]);
        offset += used;
    }
    var extra: [1]u8 = undefined;
    if (c.pread(fd, &extra, 1, @intCast(offset)) != 0) return error.InvalidRecord;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn validOwnedDirectory(stat: posix.Stat) bool {
    return posix.S.ISDIR(stat.mode) and stat.uid == c.getuid() and stat.mode & 0o777 == 0o700;
}
fn validOwnedFile(stat: posix.Stat, size: usize) bool {
    return posix.S.ISREG(stat.mode) and stat.uid == c.getuid() and stat.mode & 0o777 == 0o600 and stat.nlink == 1 and stat.size == size;
}
fn sameDirectoryRecord(stat: posix.Stat, record: *const StoredRecord) bool {
    return validOwnedDirectory(stat) and @as(u64, @intCast(stat.dev)) == record.directory_device and
        @as(u64, @intCast(stat.ino)) == record.directory_inode and @as(u64, @intCast(stat.uid)) == record.directory_uid and
        @as(u32, @intCast(stat.mode & 0o777)) == record.directory_mode;
}
fn sameRecord(a: *const StoredRecord, b: *const StoredRecord) bool {
    return std.meta.eql(a.*, b.*);
}
fn syncFd(fd: c.fd_t) !void {
    if (fd < 0 or c.fsync(fd) != 0) return error.CleanupFailed;
}
fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
fn aggregateName(aggregate: *const reopen.ReopenedAggregate, index: usize) []const u8 {
    return aggregate.names[index][0..aggregate.name_lens[index]];
}
fn storeName(storage: *[std.fs.max_name_bytes:0]u8, value: []const u8) !usize {
    if (!validComponent(value) or value.len >= storage.len) return error.InvalidPath;
    @memcpy(storage[0..value.len], value);
    storage[value.len] = 0;
    return value.len;
}
fn storePath(storage: *[std.fs.max_path_bytes:0]u8, value: []const u8) !usize {
    if (!canonicalAbsolute(value) or value.len >= storage.len) return error.InvalidPath;
    @memcpy(storage[0..value.len], value);
    storage[value.len] = 0;
    return value.len;
}
fn storeFixed(storage: anytype, value: []const u8) !usize {
    if (value.len == 0 or value.len > storage.len) return error.InvalidRecord;
    @memcpy(storage[0..value.len], value);
    return value.len;
}
fn validateContext(context: context_mod.Context) !void {
    if (context.repository.id == 0 or !std.mem.eql(u8, context.repository.owner, "ohah") or
        !std.mem.eql(u8, context.repository.name, "maru") or !context.protected_tag or
        context.tag.len == 0 or context.tag.len > context_mod.max_value_bytes or !lowerHex(context.source_commit, 40) or
        context.build.workflow_ref.len == 0 or context.build.workflow_ref.len > context_mod.max_value_bytes or
        context.build.run_id == 0 or context.build.run_attempt == 0) return error.InvalidContext;
}
fn canonicalAbsolute(value: []const u8) bool {
    if (!std.fs.path.isAbsolute(value) or value.len == 0 or value.len >= std.fs.max_path_bytes or std.mem.indexOfScalar(u8, value, 0) != null or
        (value.len > 1 and std.mem.endsWith(u8, value, "/"))) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    var parts = std.mem.splitScalar(u8, value[1..], '/');
    while (parts.next()) |part| if (!validComponent(part)) return false;
    return true;
}
fn validComponent(value: []const u8) bool {
    return value.len != 0 and value.len <= std.fs.max_name_bytes and !std.mem.eql(u8, value, ".") and
        !std.mem.eql(u8, value, "..") and std.mem.indexOfScalar(u8, value, 0) == null;
}
fn lowerHex(value: []const u8, expected: usize) bool {
    if (value.len != expected) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

pub const testing_api = if (builtin.is_test) struct {
    pub fn begin(driver: anytype, result: *Recovery) !Outcome {
        return reducer.begin(driver, result);
    }
    pub fn recover(driver: anytype, result: *Recovery) !Outcome {
        return reducer.recover(driver, result);
    }
    pub fn beginCrashAfter(
        allocator: std.mem.Allocator,
        aggregate: *reopen.ReopenedAggregate,
        verified: *const post.VerifiedRelease,
        checkpoint: usize,
        result: *Recovery,
    ) !Outcome {
        var driver = try ConcreteDriver.initBegin(allocator, aggregate, verified);
        driver.crash_after = checkpoint;
        return reducer.begin(&driver, result);
    }
    pub fn completionPath(context: context_mod.Context, original: [:0]const u8, output: []u8) ![:0]const u8 {
        var names: Names = .{};
        try deriveNames(context, original, &names);
        const parent = std.fs.path.dirname(original) orelse return error.InvalidPath;
        return std.fmt.bufPrintZ(output, "{s}/{s}", .{ parent, names.completionValue() }) catch error.InvalidPath;
    }
} else struct {};
