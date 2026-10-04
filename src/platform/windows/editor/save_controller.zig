//! Main-thread ownership of one experimental Windows save. A failed native
//! reply retains its image/handles until KTM proves commit or abort; dropping a
//! callback is never rollback. Ordinary GUI capability/crash wiring is separate.
const std = @import("std");
const builtin = @import("builtin");
const editor = @import("maru").session.editor;
const grants = @import("document_grant.zig");
const transaction = @import("transaction.zig");

pub const Status = enum { idle, prepared, uncertain, closed };
pub const Decision = enum { committed, aborted };
pub const Receipt = struct {
    decision: Decision,
    revision: u64,
    sequence: u64,
    acknowledgment_error: ?anyerror = null,
    cleanup_error: ?anyerror = null,
};
const Pending = struct {
    request: editor.save_request.Request,
    attempt: grants.Attempt,
    uncertainty_error: ?anyerror = null,
};

// Compile-time native boundary: faults in tests still operate on actual files
// and KTM transactions. No runtime fault switch is installed in the product.
const Native = struct {
    fn write(attempt: *grants.Attempt, io: std.Io, request: *const editor.save_request.Request) !void {
        try attempt.transaction.writeDocument(io, request);
    }
    fn commit(grant: *const grants.Grant, io: std.Io, attempt: *grants.Attempt, request: *const editor.save_request.Request) !void {
        try grant.commit(io, attempt, request);
    }
    fn reconcile(attempt: *grants.Attempt) !transaction.Outcome {
        return attempt.transaction.reconcile();
    }
    fn rollback(attempt: *grants.Attempt) !void {
        try attempt.transaction.rollback();
    }
};

pub const Controller = struct {
    grant: grants.Grant,
    pending: ?Pending = null,
    last_receipt: ?Receipt = null,
    closed: bool = false,

    /// Move the grant; the caller's view lease stays independent. No reference
    /// points into this struct, so moving an idle or pending controller is safe.
    pub fn take(grant: *grants.Grant) Controller {
        const result: Controller = .{ .grant = grant.* };
        grant.* = undefined;
        return result;
    }

    pub fn status(self: *const Controller) Status {
        if (self.closed) return .closed;
        const pending = self.pending orelse return .idle;
        return if (pending.attempt.transaction.phase == .uncertain) .uncertain else .prepared;
    }

    pub fn prepare(self: *Controller, io: std.Io, source: editor.document_registry.Lease, limit: usize) !void {
        try self.prepareWith(io, source, limit, Native);
    }
    fn prepareWith(self: *Controller, io: std.Io, source: editor.document_registry.Lease, limit: usize, comptime Driver: type) !void {
        if (self.closed) return error.ControllerClosed;
        if (self.pending != null) return error.SaveBusy;
        var request = try editor.save_request.Request.begin(self.grant.allocator, self.grant.registry, source, limit);
        var transferred = false;
        defer if (!transferred) request.deinit();
        const attempt = try self.grant.beginExperimental(io, &request, limit);
        self.pending = .{ .request = request, .attempt = attempt };
        transferred = true;
        self.last_receipt = null;
        Driver.write(&self.pending.?.attempt, io, &self.pending.?.request) catch |failure| {
            // Partial writes have no committed image. Roll back or retain the
            // complete pending ownership if rollback cannot be confirmed.
            _ = self.abortWith(io, Driver) catch {};
            return failure;
        };
    }

    pub fn commit(self: *Controller, io: std.Io) !Receipt {
        return self.commitWith(io, Native);
    }
    fn commitWith(self: *Controller, io: std.Io, comptime Driver: type) !Receipt {
        if (self.closed) return error.ControllerClosed;
        const pending = if (self.pending) |*value| value else return error.NoPendingSave;
        if (pending.attempt.transaction.phase != .prepared) return error.SaveUncertain;
        Driver.commit(&self.grant, io, &pending.attempt, &pending.request) catch |failure| {
            if (pending.attempt.transaction.phase == .uncertain) {
                self.markUncertain();
            } else {
                _ = self.abortWith(io, Driver) catch {};
            }
            return failure;
        };
        return self.settle(io, .committed);
    }

    fn markUncertain(self: *Controller) void {
        const pending = &self.pending.?;
        pending.request.complete(.uncertain) catch |err| {
            // A replaced document lifetime may refuse the L2 marker. The
            // controller still owns and blocks its old native attempt.
            if (err != error.SaveNotCommitted) pending.uncertainty_error = err;
        };
    }

    pub fn reconcile(self: *Controller, io: std.Io) !Receipt {
        return self.reconcileWith(io, Native);
    }
    fn reconcileWith(self: *Controller, io: std.Io, comptime Driver: type) !Receipt {
        if (self.closed) return error.ControllerClosed;
        const pending = if (self.pending) |*value| value else return error.NoPendingSave;
        if (pending.attempt.transaction.phase != .uncertain) return error.InvalidState;
        const outcome = try Driver.reconcile(&pending.attempt);
        if (outcome == .undetermined) return error.SaveUncertain;
        return self.settle(io, if (outcome == .committed) .committed else .aborted);
    }

    pub fn abort(self: *Controller, io: std.Io) !Receipt {
        return self.abortWith(io, Native);
    }
    fn abortWith(self: *Controller, io: std.Io, comptime Driver: type) !Receipt {
        if (self.closed) return error.ControllerClosed;
        const pending = if (self.pending) |*value| value else return error.NoPendingSave;
        Driver.rollback(&pending.attempt) catch |failure| {
            // Rollback itself queries an uncertain transaction. A lost commit
            // reply may already have committed; never label it as discarded.
            if (pending.attempt.transaction.phase == .committed) return self.settle(io, .committed);
            if (pending.attempt.transaction.phase == .uncertain) self.markUncertain();
            return failure;
        };
        return self.settle(io, .aborted);
    }

    fn settle(self: *Controller, io: std.Io, decision: Decision) Receipt {
        const pending = &self.pending.?;
        var receipt: Receipt = .{ .decision = decision, .revision = pending.request.revision, .sequence = pending.request.sequence };
        if (decision == .committed) {
            pending.attempt.transaction.acknowledgeDocument(&pending.request) catch |err| {
                receipt.acknowledgment_error = err;
            };
        } else {
            // A partial write may never have bound a complete native image.
            // Confirmed rollback still aborts the controller's owned request.
            pending.request.complete(.aborted) catch |err| {
                if (err != error.SaveNotCommitted) receipt.acknowledgment_error = err;
            };
        }
        // The grant still pins this state after the image lease is released.
        // Rearm using remaining images, not this already settled image.
        const state = pending.request.registry.get(pending.request.lease).?;
        pending.attempt.close(io) catch |err| {
            receipt.cleanup_error = err;
        };
        pending.request.deinit();
        if (receipt.acknowledgment_error == null)
            @import("backup_store.zig").noteDecision(state, std.Io.Clock.awake.now(io).nanoseconds);
        self.pending = null;
        self.last_receipt = receipt;
        return receipt;
    }

    /// Explicit shutdown aborts a prepared save, but refuses to drop an unknown
    /// native result. On refusal every handle/image/grant remains owned for retry.
    pub fn deinit(self: *Controller, io: std.Io) !void {
        if (self.closed) return error.ControllerClosed;
        if (self.pending) |pending| {
            if (pending.attempt.transaction.phase == .uncertain) {
                _ = try self.reconcile(io);
            } else {
                _ = try self.abort(io);
            }
        }
        self.grant.deinit(io);
        self.closed = true;
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    registry: *editor.document_registry.Registry,
    view: editor.document_registry.Lease,
    controller: Controller,

    fn init() !Fixture {
        const a = std.testing.allocator;
        const registry = try a.create(editor.document_registry.Registry);
        registry.* = .{ .allocator = a };
        errdefer a.destroy(registry);
        errdefer registry.deinit() catch unreachable;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(std.testing.io, "nested", .default_dir);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/file.txt", .data = "\xef\xbb\xbfbase\r\n" });
        var opened = try grants.Grant.openExperimental(a, std.testing.io, tmp.dir, "nested/file.txt", registry, 128);
        return .{ .tmp = tmp, .registry = registry, .view = opened.view, .controller = Controller.take(&opened.grant) };
    }
    fn state(self: *Fixture) *editor.document_state.State {
        return self.registry.get(self.controller.grant.lease).?;
    }
    fn edit(self: *Fixture, text: []const u8) !void {
        var nav: editor.view_navigation.View = .{};
        defer nav.deinit(std.testing.allocator);
        const views = [_]editor.edit_commands.Participant{.{ .view = &nav, .id = self.view.id }};
        _ = try editor.edit_commands.run(std.testing.allocator, self.state(), &views, 0, .{ .insert = text }, .{ .now_ms = 100 });
    }
    fn expectDisk(self: *Fixture, text: []const u8) !void {
        const bytes = try self.tmp.dir.readFileAlloc(std.testing.io, "nested/file.txt", std.testing.allocator, .limited(128));
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(text, bytes);
    }
    fn deinit(self: *Fixture) void {
        if (!self.controller.closed) self.controller.deinit(std.testing.io) catch @panic("fixture has unresolved save");
        _ = self.registry.release(self.view) catch unreachable;
        self.registry.deinit() catch unreachable;
        std.testing.allocator.destroy(self.registry);
        self.tmp.cleanup();
    }
};

const LostReply = struct {
    const rollback = Native.rollback;
    fn commit(grant: *const grants.Grant, io: std.Io, attempt: *grants.Attempt, request: *const editor.save_request.Request) !void {
        try grant.commit(io, attempt, request);
        attempt.transaction.phase = .uncertain;
        return error.CommitUncertain;
    }
};
const PendingReply = struct {
    const rollback = Native.rollback;
    fn commit(_: *const grants.Grant, io: std.Io, attempt: *grants.Attempt, _: *const editor.save_request.Request) !void {
        attempt.transaction.file.close(io);
        attempt.transaction.file_open = false;
        attempt.transaction.phase = .uncertain;
        return error.CommitUncertain;
    }
};

fn backupUndoOutcome(comptime Driver: type, decision: Decision, prepared: bool) !void {
    const backups = @import("backup_store.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init();
    defer f.deinit();
    // Resolve the real pending transaction even if an assertion fails. An
    // undetermined KTM outcome is not safe for Fixture.deinit to discard.
    defer if (f.controller.pending != null) {
        _ = f.controller.abort(io) catch @panic("fixture native abort failed");
    };
    var store = try backups.Store.open(a, f.tmp.dir, "backups", 128);
    defer store.deinit(io);
    try f.edit("X");
    const doc = backups.identity(f.state()).?;
    try store.write(io, doc, f.state().opened.?.file.content);
    f.state().notifications.backup_on_disk = true;
    try f.controller.prepare(io, f.view, 128);
    if (!prepared) try std.testing.expectError(error.CommitUncertain, f.controller.commitWith(io, Driver));
    const sequence = f.state().persistence.uncertain_sequence;
    var nav: editor.view_navigation.View = .{};
    defer nav.deinit(a);
    const views = [_]editor.edit_commands.Participant{.{ .view = &nav, .id = f.view.id }};
    _ = try editor.edit_commands.run(a, f.state(), &views, 0, .undo, .{ .now_ms = 101 });
    try std.testing.expect(!f.state().opened.?.isDirty());
    backups.noteEdit(f.state(), 0);
    const states = [_]*editor.document_state.State{f.state()};
    const uncertain = backups.maintain(&store, io, &states, 1, true);
    try std.testing.expectEqual(@as(usize, 0), uncertain.failed);
    try std.testing.expectEqual(sequence, f.state().persistence.uncertain_sequence);
    {
        var record = (try store.read(io, doc)) orelse return error.MissingUncertainUndoBackup;
        defer record.deinit();
        try std.testing.expectEqualStrings("base\r\n", record.parsed.content);
        try std.testing.expectEqual(doc.path.disk_hash, record.parsed.doc.path.disk_hash);
    }
    const receipt = if (decision == .aborted) try f.controller.abort(io) else if (prepared) try f.controller.commit(io) else try f.controller.reconcile(io);
    try std.testing.expectEqual(decision, receipt.decision);
    try std.testing.expect(receipt.acknowledgment_error == null);
    try std.testing.expect(f.state().persistence.uncertain_sequence == null);
    try std.testing.expect(f.state().notifications.backup_dirty);
    const settled = backups.maintain(&store, io, &states, 2, true);
    try std.testing.expectEqual(@as(usize, 0), settled.failed);
    if (decision == .committed) {
        try std.testing.expect(f.state().opened.?.isDirty());
        var record = (try store.read(io, doc)) orelse return error.MissingConfirmedUndoBackup;
        defer record.deinit();
        try std.testing.expectEqualStrings("base\r\n", record.parsed.content);
        try std.testing.expectEqual(f.state().opened.?.disk_hash, record.parsed.doc.path.disk_hash);
        try f.expectDisk("\xef\xbb\xbfXbase\r\n");
    } else {
        try std.testing.expect(!f.state().opened.?.isDirty());
        var record = try store.read(io, doc);
        defer if (record) |*value| value.deinit();
        try std.testing.expect(record == null);
        try f.expectDisk("\xef\xbb\xbfbase\r\n");
    }
}

test "Windows editor backup preserves clean-looking undo after actual committed save loses its reply" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try backupUndoOutcome(LostReply, .committed, false);
}

test "Windows editor backup preserves clean-looking undo until actual undetermined save rolls back" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try backupUndoOutcome(PendingReply, .aborted, false);
}
test "Windows editor backup preserves post-prepare undo before native commit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try backupUndoOutcome(Native, .committed, true);
}
test "Windows editor backup drops post-prepare undo only after native abort" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try backupUndoOutcome(Native, .aborted, true);
}
const PartialWrite = struct {
    fn write(attempt: *grants.Attempt, io: std.Io, _: *const editor.save_request.Request) !void {
        attempt.transaction.phase = .poisoned;
        try attempt.transaction.file.writePositionalAll(io, "partial", 0);
        return error.DiskFull;
    }
    const rollback = Native.rollback;
};

test "Windows save controller owns the image and keeps edits after preparation dirty" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepare(std.testing.io, f.view, 128);
    const issued = f.state().persistence.issued;
    try std.testing.expectError(error.SaveBusy, f.controller.prepare(std.testing.io, f.view, 128));
    try std.testing.expectEqual(issued, f.state().persistence.issued);
    try f.edit("Y");
    const receipt = try f.controller.commit(std.testing.io);
    try std.testing.expectEqual(Decision.committed, receipt.decision);
    try std.testing.expect(receipt.acknowledgment_error == null and receipt.cleanup_error == null);
    try std.testing.expect(f.state().opened.?.isDirty());
    try std.testing.expectEqual(@as(?u64, 1), f.state().persistence.persisted_revision);
    try std.testing.expectEqual(Status.idle, f.controller.status());
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save controller aborts a revoked final permission and permits a later retry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepare(std.testing.io, f.view, 128);
    f.state().opened.?.file.read_only = true;
    try std.testing.expectError(error.ReadOnly, f.controller.commit(std.testing.io));
    try std.testing.expectEqual(Status.idle, f.controller.status());
    try std.testing.expectEqual(Decision.aborted, f.controller.last_receipt.?.decision);
    try std.testing.expect(f.state().opened.?.isDirty());
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
    f.state().opened.?.file.read_only = false;
    try f.controller.prepare(std.testing.io, f.view, 128);
    _ = try f.controller.commit(std.testing.io);
    try std.testing.expect(!f.state().opened.?.isDirty());
}

test "Windows save controller rolls back actual partial writes without a bound complete image" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try std.testing.expectError(error.DiskFull, f.controller.prepareWith(std.testing.io, f.view, 128, PartialWrite));
    try std.testing.expectEqual(Status.idle, f.controller.status());
    try std.testing.expectEqual(Decision.aborted, f.controller.last_receipt.?.decision);
    try std.testing.expect(f.controller.last_receipt.?.acknowledgment_error == null);
    try std.testing.expect(f.state().opened.?.isDirty());
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
}

fn expectSaveBlocked(f: *Fixture) !void {
    if (editor.save_request.Request.begin(std.testing.allocator, f.registry, f.view, 128)) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.SaveUncertain, err);
}

test "Windows save controller reconciles an actual committed transaction after reply loss" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepare(std.testing.io, f.view, 128);
    try std.testing.expectError(error.CommitUncertain, f.controller.commitWith(std.testing.io, LostReply));
    try std.testing.expectEqual(Status.uncertain, f.controller.status());
    try std.testing.expect(f.state().opened.?.isDirty());
    try expectSaveBlocked(&f);
    try f.edit("Y");
    const receipt = try f.controller.reconcile(std.testing.io);
    try std.testing.expectEqual(Decision.committed, receipt.decision);
    try std.testing.expect(receipt.acknowledgment_error == null);
    try std.testing.expect(f.state().persistence.uncertain_sequence == null);
    try std.testing.expect(f.state().opened.?.isDirty());
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save controller reports native commit separately from a stale document acknowledgment" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepare(std.testing.io, f.view, 128);
    try std.testing.expectError(error.CommitUncertain, f.controller.commitWith(std.testing.io, LostReply));
    const path = try std.testing.allocator.dupe(u8, "new-name.txt");
    std.testing.allocator.free(f.state().path.?);
    f.state().path = path;
    const receipt = try f.controller.reconcile(std.testing.io);
    try std.testing.expectEqual(Decision.committed, receipt.decision);
    try std.testing.expectEqual(error.StaleDocument, receipt.acknowledgment_error.?);
    try std.testing.expect(f.state().persistence.uncertain_sequence == null);
    try std.testing.expect(f.state().opened.?.isDirty());
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save controller refuses shutdown while KTM is actually undetermined" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepare(std.testing.io, f.view, 128);
    try std.testing.expectError(error.CommitUncertain, f.controller.commitWith(std.testing.io, PendingReply));
    try std.testing.expectEqual(transaction.Outcome.undetermined, try f.controller.pending.?.attempt.transaction.queryOutcome());
    try std.testing.expectError(error.SaveUncertain, f.controller.deinit(std.testing.io));
    try std.testing.expectEqual(Status.uncertain, f.controller.status());
    try expectSaveBlocked(&f);
    const receipt = try f.controller.abort(std.testing.io);
    try std.testing.expectEqual(Decision.aborted, receipt.decision);
    try std.testing.expect(f.state().persistence.uncertain_sequence == null);
    try std.testing.expect(f.state().opened.?.isDirty());
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
}

test "Windows save controller observes a lost commit before deciding an abort" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepare(std.testing.io, f.view, 128);
    try std.testing.expectError(error.CommitUncertain, f.controller.commitWith(std.testing.io, LostReply));
    const receipt = try f.controller.abort(std.testing.io);
    try std.testing.expectEqual(Decision.committed, receipt.decision);
    try std.testing.expect(!f.state().opened.?.isDirty());
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}

const FailedRollback = struct {
    fn rollback(attempt: *grants.Attempt) !void {
        attempt.transaction.phase = .uncertain;
        return error.RollbackUncertain;
    }
};
test "Windows save controller retains a failed rollback until a later native decision" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepare(std.testing.io, f.view, 128);
    try std.testing.expectError(error.RollbackUncertain, f.controller.abortWith(std.testing.io, FailedRollback));
    try std.testing.expectEqual(Status.uncertain, f.controller.status());
    try expectSaveBlocked(&f);
    const receipt = try f.controller.abort(std.testing.io);
    try std.testing.expectEqual(Decision.aborted, receipt.decision);
    try std.testing.expect(f.state().persistence.uncertain_sequence == null);
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
}

fn allocationPrefix(a: std.mem.Allocator) !void {
    var f = try Fixture.init();
    defer f.deinit();
    f.controller.grant.allocator = a;
    defer f.controller.grant.allocator = std.testing.allocator;
    f.controller.prepare(std.testing.io, f.view, 128) catch |err| {
        if (err == error.OutOfMemory) {
            try std.testing.expectEqual(Status.idle, f.controller.status());
            try std.testing.expect(f.state().persistence.uncertain_sequence == null);
            try f.tmp.dir.rename("nested", f.tmp.dir, "moved", std.testing.io);
            try f.tmp.dir.rename("moved", f.tmp.dir, "nested", std.testing.io);
        }
        return err;
    };
    _ = try f.controller.abort(std.testing.io);
}
test "Windows save controller preparation allocation prefixes release every image lease and native fence" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPrefix, .{});
}

test "Windows save controller can settle after its last view closes and refuses reuse after shutdown" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    // Release the fixture view explicitly and perform the remaining cleanup here.
    defer f.tmp.cleanup();
    defer std.testing.allocator.destroy(f.registry);
    defer f.registry.deinit() catch unreachable;
    try f.edit("X");
    try f.controller.prepare(std.testing.io, f.view, 128);
    try std.testing.expect(!try f.registry.release(f.view));
    const receipt = try f.controller.commit(std.testing.io);
    try std.testing.expectEqual(Decision.committed, receipt.decision);
    try std.testing.expectEqual(@as(usize, 0), f.registry.viewCount(f.controller.grant.lease).?);
    try f.controller.deinit(std.testing.io);
    try std.testing.expectEqual(Status.closed, f.controller.status());
    try std.testing.expectError(error.ControllerClosed, f.controller.deinit(std.testing.io));
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}

const LostQuery = struct {
    fn reconcile(attempt: *grants.Attempt) !transaction.Outcome {
        // The actual transaction has committed, but this observation's reply
        // is unavailable. Query without publishing a local phase decision.
        try std.testing.expectEqual(transaction.Outcome.committed, try attempt.transaction.queryOutcome());
        return error.OutcomeQueryFailed;
    }
};
test "Windows save controller retains image and handles after a lost outcome query" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepare(std.testing.io, f.view, 128);
    try std.testing.expectError(error.CommitUncertain, f.controller.commitWith(std.testing.io, LostReply));
    const lease = f.controller.pending.?.request.lease;
    try std.testing.expectError(error.OutcomeQueryFailed, f.controller.reconcileWith(std.testing.io, LostQuery));
    try std.testing.expectEqual(Status.uncertain, f.controller.status());
    try std.testing.expect(f.registry.get(lease) != null);
    try expectSaveBlocked(&f);
    const receipt = try f.controller.reconcile(std.testing.io);
    try std.testing.expectEqual(Decision.committed, receipt.decision);
    try std.testing.expect(f.registry.get(lease) == null);
    try std.testing.expect(!f.state().opened.?.isDirty());
}

fn commitAllocationPrefix(a: std.mem.Allocator) !void {
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepare(std.testing.io, f.view, 128);
    f.controller.grant.allocator = a;
    defer f.controller.grant.allocator = std.testing.allocator;
    _ = f.controller.commit(std.testing.io) catch |err| {
        if (err == error.OutOfMemory) {
            try std.testing.expectEqual(Status.idle, f.controller.status());
            try std.testing.expectEqual(Decision.aborted, f.controller.last_receipt.?.decision);
            try std.testing.expect(f.state().opened.?.isDirty());
            try f.expectDisk("\xef\xbb\xbfbase\r\n");
            try f.tmp.dir.rename("nested", f.tmp.dir, "moved", std.testing.io);
            try f.tmp.dir.rename("moved", f.tmp.dir, "nested", std.testing.io);
        }
        return err;
    };
    try std.testing.expect(!f.state().opened.?.isDirty());
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}
test "Windows save controller commit allocation failures roll back a prepared native image" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, commitAllocationPrefix, .{});
}

test "Windows save controller pending ownership survives moving the controller" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepare(std.testing.io, f.view, 128);
    var moved = f.controller;
    f.controller = undefined;
    defer f.controller = moved;
    const receipt = try moved.commit(std.testing.io);
    try std.testing.expectEqual(Decision.committed, receipt.decision);
    try std.testing.expectEqual(Status.idle, moved.status());
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}
