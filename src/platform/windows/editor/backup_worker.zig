//! One immutable recovery operation at a time. Only the app touches Registry;
//! native private-store I/O uses independent bytes and an explicitly pinned root.
const std = @import("std");
const maru = @import("maru");
const editor = maru.session.editor;
const backups = @import("backup_store.zig");
const Registry = editor.document_registry.Registry;
const Lease = editor.document_registry.Lease;
const State = editor.document_state.State;
const Mode = enum { write, drop, paused };
pub const Outcome = enum { wrote, dropped, paused, stale, failed };

const Packet = struct {
    allocator: std.mem.Allocator,
    lease: Lease,
    doc: editor.backup.Doc,
    body: []u8,
    mode: Mode,
    epoch: u64,
    revision: u64,
    saved_hash: u64,
    disk_hash: ?u64,
    issued: u64,
    uncertain: ?u64,
    live_images: u64,
    due_ns: i128,
    on_disk: bool,

    fn capture(a: std.mem.Allocator, state: *const State, lease: Lease, limit: usize) !Packet {
        const identity = backups.identity(state) orelse return error.MissingDocument;
        const doc = switch (identity) {
            .path => |path| editor.backup.Doc{ .path = .{ .path = try a.dupe(u8, path.path), .disk_hash = path.disk_hash } },
            .untitled => |id| editor.backup.Doc{ .untitled = id },
            .remote => |remote| blk: {
                const dest = try a.dupe(u8, remote.dest);
                errdefer a.free(dest);
                break :blk editor.backup.Doc{ .remote = .{ .dest = dest, .path = try a.dupe(u8, remote.path) } };
            },
        };
        errdefer freeDoc(a, doc);
        const opened = &state.opened.?;
        const clean = !opened.isDirty() and state.persistence.uncertain_sequence == null and state.persistence.live_save_images == 0;
        const mode: Mode = if (clean) .drop else if (opened.file.content.len > limit) .paused else .write;
        const body = if (mode == .write) try a.dupe(u8, opened.file.content) else try a.dupe(u8, "");
        return .{ .allocator = a, .lease = lease, .doc = doc, .body = body, .mode = mode, .epoch = state.persistence.epoch, .revision = opened.file.revision, .saved_hash = opened.saved_hash, .disk_hash = opened.disk_hash, .issued = state.persistence.issued, .uncertain = state.persistence.uncertain_sequence, .live_images = state.persistence.live_save_images, .due_ns = state.notifications.backup_due_ns, .on_disk = state.notifications.backup_on_disk };
    }
    fn freeDoc(a: std.mem.Allocator, doc: editor.backup.Doc) void {
        switch (doc) {
            .path => |value| a.free(value.path),
            .remote => |value| {
                a.free(value.dest);
                a.free(value.path);
            },
            .untitled => {},
        }
    }
    fn sameKey(self: *const Packet, state: *const State) bool {
        const current = backups.identity(state) orelse return false;
        if (std.meta.activeTag(current) != std.meta.activeTag(self.doc)) return false;
        return switch (self.doc) {
            .path => |value| std.mem.eql(u8, value.path, current.path.path),
            .untitled => |value| value == current.untitled,
            .remote => |value| std.mem.eql(u8, value.dest, current.remote.dest) and std.mem.eql(u8, value.path, current.remote.path),
        };
    }
    fn matches(self: *const Packet, state: *const State) bool {
        const opened = state.opened orelse return false;
        return self.sameKey(state) and self.epoch == state.persistence.epoch and
            self.revision == opened.file.revision and self.saved_hash == opened.saved_hash and
            self.disk_hash == opened.disk_hash and self.issued == state.persistence.issued and
            self.uncertain == state.persistence.uncertain_sequence and self.live_images == state.persistence.live_save_images and
            self.due_ns == state.notifications.backup_due_ns and self.on_disk == state.notifications.backup_on_disk;
    }
    fn deinit(self: *Packet) void {
        self.allocator.free(self.body);
        freeDoc(self.allocator, self.doc);
        self.* = undefined;
    }
};
const Native = struct {
    fn write(store: *backups.Store, io: std.Io, doc: editor.backup.Doc, body: []const u8) !void {
        try store.write(io, doc, body);
    }
    fn drop(store: *backups.Store, io: std.Io, doc: editor.backup.Doc) !void {
        try store.drop(io, doc);
    }
};
const Result = struct { outcome: Outcome, failure: ?anyerror = null, owner: ?backups.LocalData = null, thread_id: std.Thread.Id, cleanup_thread_id: ?std.Thread.Id = null };
const Job = struct {
    packet: Packet,
    io: std.Io,
    store: ?backups.Store,
    localappdata: ?[]u8,
    limit: usize,
    ready_drop: std.atomic.Value(bool) = .init(false),
    drop_vote: std.atomic.Value(u8) = .init(0), // pending / approve / reject
    done: std.atomic.Value(bool) = .init(false),
    result: ?Result = null,
    cleanup_retry_at: ?i128 = null,

    // Created roots use the SMP allocator. This second stage retains the job
    // and registry lease while closing the redundant native owner off-frame.
    fn cleanup(self: *Job) void {
        self.result.?.cleanup_thread_id = std.Thread.getCurrentId();
        self.result.?.owner.?.deinit(self.io);
        self.result.?.owner = null;
        self.done.store(true, .release);
    }

    fn run(self: *Job, comptime Driver: type) void {
        const a = std.heap.smp_allocator;
        var result: Result = .{ .outcome = .failed, .thread_id = std.Thread.getCurrentId() };
        defer {
            self.result = result;
            self.done.store(true, .release);
        }
        if (self.packet.mode == .paused) {
            result.outcome = .paused;
            return;
        }
        if (self.packet.mode == .drop) {
            // An edit/new save can invalidate clean cleanup after capture. Wait
            // for the app's latest vote; no timeout invents a deletion decision.
            self.ready_drop.store(true, .release);
            while (self.drop_vote.load(.acquire) == 0) self.io.sleep(.fromMilliseconds(1), .awake) catch {};
            if (self.drop_vote.load(.acquire) != 1) {
                result.outcome = .stale;
                return;
            }
            if (!self.packet.on_disk) {
                result.outcome = .dropped;
                return;
            }
        }
        var store = self.store;
        if (store == null) {
            const environment = if (self.localappdata == null) maru.os_env.allocValue(a, "LOCALAPPDATA") else null;
            defer if (environment) |value| a.free(value);
            result.owner = backups.LocalData.open(a, self.io, self.localappdata orelse environment, self.limit) catch |failure| {
                result.failure = failure;
                return;
            };
            store = result.owner.?.store;
        }
        switch (self.packet.mode) {
            .write => Driver.write(&store.?, self.io, self.packet.doc, self.packet.body) catch |failure| {
                result.failure = failure;
                return;
            },
            .drop => Driver.drop(&store.?, self.io, self.packet.doc) catch |failure| {
                result.failure = failure;
                return;
            },
            .paused => unreachable,
        }
        result.outcome = if (self.packet.mode == .write) .wrote else .dropped;
    }
};
pub const Completion = struct { report: backups.Maintenance, outcome: Outcome, thread_id: std.Thread.Id, cleanup_thread_id: ?std.Thread.Id = null };
pub const Worker = struct {
    allocator: std.mem.Allocator,
    registry: *Registry,
    job: ?*Job = null,
    address: ?*Worker = null,
    owner_thread: ?std.Thread.Id = null,

    pub fn init(a: std.mem.Allocator, registry: *Registry) Worker {
        return .{ .allocator = a, .registry = registry };
    }
    pub fn isBusy(self: *const Worker) bool {
        return self.job != null;
    }
    fn check(self: *const Worker) !void {
        if (self.address) |owner| if (owner != self) return error.CopiedBackupWorker;
        if (self.owner_thread) |owner| if (owner != std.Thread.getCurrentId()) return error.WrongBackupThread;
    }
    /// Borrowed store handles must remain open until finish. Only immutable
    /// policy/handle values are copied; worker allocations use SMP, not its GPA.
    pub fn start(self: *Worker, io: std.Io, view: Lease, borrowed: ?*backups.Store, localappdata: ?[]const u8, limit: usize) !void {
        try self.startWith(io, view, borrowed, localappdata, limit, Native);
    }
    fn startWith(self: *Worker, io: std.Io, view: Lease, borrowed: ?*backups.Store, localappdata: ?[]const u8, limit: usize, comptime Driver: type) !void {
        try self.check();
        if (self.isBusy()) return error.BackupBusy;
        const a = std.heap.smp_allocator;
        const lease = try self.registry.retain(view, .request);
        errdefer _ = self.registry.release(lease) catch unreachable;
        const state = self.registry.get(lease) orelse return error.StaleDocument;
        const effective_limit = if (borrowed) |store| store.limit else @min(limit, editor.backup.pause_bytes);
        var packet = try Packet.capture(a, state, lease, effective_limit);
        errdefer packet.deinit();
        if (localappdata) |root| if (root.len > std.fs.max_path_bytes or std.mem.indexOfScalar(u8, root, 0) != null) return error.InvalidPath;
        const local = if (localappdata) |root| try a.dupe(u8, root) else null;
        errdefer if (local) |root| a.free(root);
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        var store: ?backups.Store = if (borrowed) |value| value.* else null;
        if (store) |*value| value.allocator = a;
        job.* = .{ .packet = packet, .io = io, .store = store, .localappdata = local, .limit = effective_limit };
        const thread = try std.Thread.spawn(.{}, Job.run, .{ job, Driver });
        thread.detach();
        self.job = job;
        self.address = self;
        self.owner_thread = std.Thread.getCurrentId();
    }
    /// Call after queued edits/save outcomes, before deciding a close. This
    /// publishes a single decision; a later frame cannot reverse a consumed vote.
    pub fn voteDrop(self: *Worker) !void {
        try self.check();
        const job = self.job orelse return;
        if (!job.ready_drop.load(.acquire)) return;
        if (job.drop_vote.load(.acquire) != 0) return;
        const state = self.registry.get(job.packet.lease);
        const approved = if (state) |value| job.packet.matches(value) and value.notifications.backup_dirty and
            value.persistence.uncertain_sequence == null and value.persistence.live_save_images == 0 else false;
        _ = job.drop_vote.cmpxchgStrong(0, if (approved) 1 else 2, .acq_rel, .acquire);
    }
    /// Teardown rejects an unvoted drop but drains real writes/deletes to their
    /// terminal result before releasing the model lease or borrowed root.
    pub fn rejectDrop(self: *Worker) !void {
        try self.check();
        if (self.job) |job| _ = job.drop_vote.cmpxchgStrong(0, 2, .acq_rel, .acquire);
    }
    const CleanupSpawner = struct {
        fn spawn(job: *Job) !std.Thread {
            return std.Thread.spawn(.{}, Job.cleanup, .{job});
        }
    };
    pub fn finish(self: *Worker, owner: *?backups.LocalData, now_ns: i128) !?Completion {
        return self.finishWith(owner, now_ns, CleanupSpawner);
    }
    fn finishWith(self: *Worker, owner: *?backups.LocalData, now_ns: i128, comptime Spawner: type) !?Completion {
        try self.check();
        const job = self.job orelse return null;
        if (!job.done.load(.acquire)) return null;
        if (job.result.?.owner != null and owner.* != null) {
            // No synchronous native fallback. On spawn failure the receipt and
            // its owner remain intact, so a later finish can retry safely.
            const cleanup_now = std.Io.Clock.awake.now(job.io).nanoseconds;
            if (job.cleanup_retry_at) |due| if (cleanup_now < due) return null;
            job.done.store(false, .release);
            const thread = Spawner.spawn(job) catch |failure| {
                job.cleanup_retry_at = cleanup_now + 200 * std.time.ns_per_ms;
                job.done.store(true, .release);
                return failure;
            };
            thread.detach();
            return null;
        }
        var result = job.result.?;
        if (result.owner) |created| {
            owner.* = created;
            result.owner = null;
        }
        var report: backups.Maintenance = .{ .attempted = 1 };
        if (self.registry.get(job.packet.lease)) |state| {
            const current = job.packet.matches(state);
            // A stale receipt still describes actual storage at the same key.
            // Preserve it for close cleanup, but never settle a newer revision.
            if (job.packet.sameKey(state)) switch (result.outcome) {
                .wrote => state.notifications.backup_on_disk = true,
                .dropped => state.notifications.backup_on_disk = false,
                else => {},
            };
            if (current and result.outcome != .failed and result.outcome != .stale) {
                state.notifications.backup_dirty = false;
                state.notifications.backup_paused = result.outcome == .paused;
            } else {
                state.notifications.backup_dirty = true;
                if (result.outcome == .failed) state.notifications.backup_due_ns = now_ns +| editor.backup.debounce_ns;
            }
        } else {
            report.failed = 1;
            report.first_error = error.StaleDocument;
        }
        if (result.failure) |failure| {
            report.failed += 1;
            report.first_error = failure;
        }
        _ = self.registry.release(job.packet.lease) catch unreachable;
        job.packet.deinit();
        if (job.localappdata) |root| std.heap.smp_allocator.free(root);
        self.allocator.destroy(job);
        self.job = null;
        return .{ .report = report, .outcome = result.outcome, .thread_id = result.thread_id, .cleanup_thread_id = result.cleanup_thread_id };
    }
    pub fn deinit(self: *Worker) !void {
        try self.check();
        if (self.isBusy()) return error.BackupBusy;
        self.address = null;
        self.owner_thread = null;
    }
};

const TestModel = struct {
    registry: Registry,
    view: Lease,
    fn init(body: []const u8, clean: bool) !*TestModel {
        const a = std.testing.allocator;
        const self = try a.create(TestModel);
        errdefer a.destroy(self);
        self.registry = .{ .allocator = a };
        errdefer self.registry.deinit() catch unreachable;
        var prepared: State = .{};
        errdefer prepared.clear(a);
        prepared.path = try a.dupe(u8, "C:/worker/document.txt");
        prepared.opened = .{ .file = try editor.edit_doc.EditableFile.init(a, body, false), .saved_hash = editor.document_state.contentHash(if (clean) body else "base"), .disk_hash = 0x1234 };
        prepared.notifications.backup_dirty = true;
        self.view = try self.registry.create(&prepared, a);
        return self;
    }
    fn state(self: *TestModel) *State {
        return self.registry.get(self.view).?;
    }
    fn deinit(self: *TestModel) void {
        _ = self.registry.release(self.view) catch unreachable;
        self.registry.deinit() catch unreachable;
        std.testing.allocator.destroy(self);
    }
};
fn awaitCompletion(worker: *Worker, owner: *?backups.LocalData) !Completion {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(io).nanoseconds < deadline) {
        try worker.voteDrop();
        if (try worker.finish(owner, 10)) |completed| return completed;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.BackupCompletionMissing;
}
fn drain(worker: *Worker, owner: *?backups.LocalData) void {
    worker.rejectDrop() catch unreachable;
    while (worker.isBusy()) {
        _ = worker.finish(owner, 10) catch unreachable;
        if (worker.isBusy()) std.testing.io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
    }
    worker.deinit() catch unreachable;
}
fn expectBody(store: *backups.Store, doc: editor.backup.Doc, body: []const u8) !void {
    var record = (try store.read(std.testing.io, doc)) orelse return error.BackupRecordMissing;
    defer record.deinit();
    try std.testing.expectEqualStrings(body, record.parsed.content);
}

test "Windows recovery backup worker freezes bytes and writes off the owner thread" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const f = try TestModel.init("changed", false);
    defer f.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try backups.Store.open(std.testing.allocator, tmp.dir, "backups", 128);
    defer store.deinit(std.testing.io);
    var owner: ?backups.LocalData = null;
    var worker = Worker.init(std.testing.allocator, &f.registry);
    defer drain(&worker, &owner);
    try worker.start(std.testing.io, f.view, &store, null, 128);
    const state = f.state();
    var newer = try editor.edit_doc.EditableFile.init(std.testing.allocator, "later", false);
    newer.revision = state.opened.?.file.revision + 1;
    state.opened.?.file.deinit();
    state.opened.?.file = newer;
    const completed = try awaitCompletion(&worker, &owner);
    try std.testing.expectEqual(Outcome.wrote, completed.outcome);
    try std.testing.expect(completed.thread_id != std.Thread.getCurrentId());
    try expectBody(&store, backups.identity(state).?, "changed");
    try std.testing.expect(state.notifications.backup_dirty and state.notifications.backup_on_disk);
}

test "Windows recovery backup worker never settles a changed epoch revision or disk CAS" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    for (0..3) |axis| {
        const f = try TestModel.init("changed", false);
        defer f.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var store = try backups.Store.open(std.testing.allocator, tmp.dir, "backups", 128);
        defer store.deinit(std.testing.io);
        var owner: ?backups.LocalData = null;
        var worker = Worker.init(std.testing.allocator, &f.registry);
        defer drain(&worker, &owner);
        try worker.start(std.testing.io, f.view, &store, null, 128);
        const state = f.state();
        switch (axis) {
            0 => state.persistence.epoch += 1,
            1 => state.opened.?.file.revision += 1,
            2 => state.opened.?.disk_hash = 0x5678,
            else => unreachable,
        }
        const completed = try awaitCompletion(&worker, &owner);
        try std.testing.expectEqual(Outcome.wrote, completed.outcome);
        try std.testing.expect(state.notifications.backup_dirty and state.notifications.backup_on_disk);
        var record = (try store.read(std.testing.io, backups.identity(state).?)).?;
        defer record.deinit();
        try std.testing.expectEqual(@as(?u64, 0x1234), record.parsed.doc.path.disk_hash);
    }
}
const FailWrite = struct {
    fn write(_: *backups.Store, _: std.Io, _: editor.backup.Doc, _: []const u8) !void {
        return error.InjectedBackupFailure;
    }
    fn drop(store: *backups.Store, io: std.Io, doc: editor.backup.Doc) !void {
        try Native.drop(store, io, doc);
    }
};
test "Windows recovery backup worker failure preserves pending protection and bounded retry" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const f = try TestModel.init("changed", false);
    defer f.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try backups.Store.open(std.testing.allocator, tmp.dir, "backups", 128);
    defer store.deinit(std.testing.io);
    var owner: ?backups.LocalData = null;
    var worker = Worker.init(std.testing.allocator, &f.registry);
    defer drain(&worker, &owner);
    try worker.startWith(std.testing.io, f.view, &store, null, 128, FailWrite);
    const completed = try awaitCompletion(&worker, &owner);
    try std.testing.expectEqual(Outcome.failed, completed.outcome);
    try std.testing.expectEqual(@as(usize, 1), completed.report.failed);
    try std.testing.expect(completed.report.first_error.? == error.InjectedBackupFailure);
    try std.testing.expect(f.state().notifications.backup_dirty and !f.state().notifications.backup_on_disk);
    try std.testing.expectEqual(@as(i128, 10 + editor.backup.debounce_ns), f.state().notifications.backup_due_ns);
    try std.testing.expect(try store.read(std.testing.io, backups.identity(f.state()).?) == null);
}

test "Windows recovery backup worker preserves clean undo while a save image or outcome is live" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    for (0..2) |axis| {
        const f = try TestModel.init("base", true);
        defer f.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var store = try backups.Store.open(std.testing.allocator, tmp.dir, "backups", 128);
        defer store.deinit(std.testing.io);
        const state = f.state();
        try store.write(std.testing.io, backups.identity(state).?, "previous dirty body");
        state.notifications.backup_on_disk = true;
        if (axis == 0) state.persistence.uncertain_sequence = 7 else state.persistence.live_save_images = 1;
        var owner: ?backups.LocalData = null;
        var worker = Worker.init(std.testing.allocator, &f.registry);
        defer drain(&worker, &owner);
        try worker.start(std.testing.io, f.view, &store, null, 128);
        const completed = try awaitCompletion(&worker, &owner);
        try std.testing.expectEqual(Outcome.wrote, completed.outcome);
        try expectBody(&store, backups.identity(state).?, "base");
        try std.testing.expect(state.notifications.backup_on_disk and !state.notifications.backup_dirty);
    }
}

test "Windows recovery backup worker waits for current drop approval and preserves a stale record" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const f = try TestModel.init("base", true);
    defer f.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try backups.Store.open(std.testing.allocator, tmp.dir, "backups", 128);
    defer store.deinit(std.testing.io);
    try store.write(std.testing.io, backups.identity(f.state()).?, "previous");
    f.state().notifications.backup_on_disk = true;
    var owner: ?backups.LocalData = null;
    var worker = Worker.init(std.testing.allocator, &f.registry);
    defer drain(&worker, &owner);
    try worker.start(std.testing.io, f.view, &store, null, 128);
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
    while (!worker.job.?.ready_drop.load(.acquire)) {
        if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline) return error.DropVoteMissing;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(!worker.job.?.done.load(.acquire));
    try expectBody(&store, backups.identity(f.state()).?, "previous");
    f.state().opened.?.file.revision += 1;
    const completed = try awaitCompletion(&worker, &owner);
    try std.testing.expectEqual(Outcome.stale, completed.outcome);
    try expectBody(&store, backups.identity(f.state()).?, "previous");
    try std.testing.expect(f.state().notifications.backup_dirty);
}

test "Windows recovery backup worker applies confirmed native deletion before acknowledging clean" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const f = try TestModel.init("base", true);
    defer f.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try backups.Store.open(std.testing.allocator, tmp.dir, "backups", 128);
    defer store.deinit(std.testing.io);
    try store.write(std.testing.io, backups.identity(f.state()).?, "previous");
    f.state().notifications.backup_on_disk = true;
    var owner: ?backups.LocalData = null;
    var worker = Worker.init(std.testing.allocator, &f.registry);
    defer drain(&worker, &owner);
    try worker.start(std.testing.io, f.view, &store, null, 128);
    const completed = try awaitCompletion(&worker, &owner);
    try std.testing.expectEqual(Outcome.dropped, completed.outcome);
    try std.testing.expect(completed.thread_id != std.Thread.getCurrentId());
    try std.testing.expect(try store.read(std.testing.io, backups.identity(f.state()).?) == null);
    try std.testing.expect(!f.state().notifications.backup_dirty and !f.state().notifications.backup_on_disk);
}

test "Windows recovery backup worker creates and hands over the private root on its own thread" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const f = try TestModel.init("changed", false);
    defer f.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var owner: ?backups.LocalData = null;
    defer if (owner) |*value| value.deinit(std.testing.io);
    var worker = Worker.init(std.testing.allocator, &f.registry);
    defer drain(&worker, &owner);
    try worker.start(std.testing.io, f.view, null, root, 128);
    const completed = try awaitCompletion(&worker, &owner);
    try std.testing.expectEqual(Outcome.wrote, completed.outcome);
    try std.testing.expect(completed.thread_id != std.Thread.getCurrentId());
    try std.testing.expect(owner != null);
    try expectBody(&owner.?.store, backups.identity(f.state()).?, "changed");
}

test "Windows recovery backup worker pauses above the effective store limit without losing a record" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const f = try TestModel.init("changed", false);
    defer f.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try backups.Store.open(std.testing.allocator, tmp.dir, "backups", 3);
    defer store.deinit(std.testing.io);
    try store.write(std.testing.io, backups.identity(f.state()).?, "old");
    f.state().notifications.backup_on_disk = true;
    var owner: ?backups.LocalData = null;
    var worker = Worker.init(std.testing.allocator, &f.registry);
    defer drain(&worker, &owner);
    try worker.start(std.testing.io, f.view, &store, null, 128);
    const completed = try awaitCompletion(&worker, &owner);
    try std.testing.expectEqual(Outcome.paused, completed.outcome);
    try expectBody(&store, backups.identity(f.state()).?, "old");
    try std.testing.expect(f.state().notifications.backup_paused and !f.state().notifications.backup_dirty);
}

test "Windows recovery backup worker rejects copied owners busy start and premature teardown" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const f = try TestModel.init("changed", false);
    defer f.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try backups.Store.open(std.testing.allocator, tmp.dir, "backups", 128);
    defer store.deinit(std.testing.io);
    var owner: ?backups.LocalData = null;
    var worker = Worker.init(std.testing.allocator, &f.registry);
    defer drain(&worker, &owner);
    try worker.start(std.testing.io, f.view, &store, null, 128);
    var copy = worker;
    try std.testing.expectError(error.CopiedBackupWorker, copy.finish(&owner, 10));
    try std.testing.expectError(error.BackupBusy, worker.start(std.testing.io, f.view, &store, null, 128));
    try std.testing.expectError(error.BackupBusy, worker.deinit());
    _ = try awaitCompletion(&worker, &owner);
}
fn capturePrefix(a: std.mem.Allocator, state: *const State, lease: Lease) !void {
    var packet = try Packet.capture(a, state, lease, 128);
    packet.deinit();
}
test "Windows recovery backup worker packet allocation prefixes preserve borrowed model ownership" {
    const f = try TestModel.init("changed", false);
    defer f.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, capturePrefix, .{ f.state(), f.view });
    try std.testing.expectEqualStrings("changed", f.state().opened.?.file.content);
}

test "Windows recovery backup worker extra root cleanup retains lease and rechecks revision" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const f = try TestModel.init("changed", false);
    defer f.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var owner: ?backups.LocalData = null;
    defer if (owner) |*value| value.deinit(io);
    var worker = Worker.init(a, &f.registry);
    defer drain(&worker, &owner);
    try worker.start(io, f.view, null, root, 128);
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (!worker.job.?.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.BackupCompletionMissing;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    const extra_handle = worker.job.?.result.?.owner.?.store.dir.handle;
    owner = try backups.LocalData.open(a, io, root, 128);
    const retained_handle = owner.?.store.dir.handle;
    try std.testing.expect((try worker.finish(&owner, 10)) == null);
    try std.testing.expect(worker.isBusy());
    try std.testing.expect(f.state().notifications.backup_dirty);
    f.state().opened.?.file.revision += 1;
    const completed = try awaitCompletion(&worker, &owner);
    try std.testing.expect(completed.cleanup_thread_id != null);
    try std.testing.expect(completed.cleanup_thread_id.? != std.Thread.getCurrentId());
    try std.testing.expect(owner.?.store.dir.handle == retained_handle);
    try std.testing.expect(!worker.isBusy());
    try std.testing.expect(f.state().notifications.backup_dirty and f.state().notifications.backup_on_disk);
    const w = std.os.windows;
    var status: w.IO_STATUS_BLOCK = undefined;
    var tag: w.FILE.ATTRIBUTE_TAG_INFO = undefined;
    try std.testing.expectEqual(w.NTSTATUS.INVALID_HANDLE, w.ntdll.NtQueryInformationFile(extra_handle, &status, &tag, @sizeOf(@TypeOf(tag)), .AttributeTag));
    try expectBody(&owner.?.store, backups.identity(f.state()).?, "changed");
}

test "Windows recovery backup worker cleanup spawn failure preserves root and backs off" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const f = try TestModel.init("changed", false);
    defer f.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var owner: ?backups.LocalData = null;
    defer if (owner) |*value| value.deinit(io);
    var worker = Worker.init(a, &f.registry);
    defer drain(&worker, &owner);
    try worker.start(io, f.view, null, root, 128);
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (!worker.job.?.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.BackupCompletionMissing;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    owner = try backups.LocalData.open(a, io, root, 128);
    const extra_handle = worker.job.?.result.?.owner.?.store.dir.handle;
    const FailSpawn = struct {
        fn spawn(_: *Job) !std.Thread {
            return error.SystemResources;
        }
    };
    try std.testing.expectError(error.SystemResources, worker.finishWith(&owner, 10, FailSpawn));
    try std.testing.expect(worker.isBusy() and worker.job.?.done.load(.acquire));
    try std.testing.expect(f.registry.get(worker.job.?.packet.lease) != null);
    try std.testing.expect(f.state().notifications.backup_dirty);
    try std.testing.expect(worker.job.?.result.?.owner.?.store.dir.handle == extra_handle);
    try std.testing.expect((try worker.finishWith(&owner, 10, FailSpawn)) == null);
    const w = std.os.windows;
    var status: w.IO_STATUS_BLOCK = undefined;
    var tag: w.FILE.ATTRIBUTE_TAG_INFO = undefined;
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, w.ntdll.NtQueryInformationFile(extra_handle, &status, &tag, @sizeOf(@TypeOf(tag)), .AttributeTag));
    const completed = try awaitCompletion(&worker, &owner);
    try std.testing.expectEqual(Outcome.wrote, completed.outcome);
    try std.testing.expect(!worker.isBusy());
    try std.testing.expectEqual(w.NTSTATUS.INVALID_HANDLE, w.ntdll.NtQueryInformationFile(extra_handle, &status, &tag, @sizeOf(@TypeOf(tag)), .AttributeTag));
    try expectBody(&owner.?.store, backups.identity(f.state()).?, "changed");
}
