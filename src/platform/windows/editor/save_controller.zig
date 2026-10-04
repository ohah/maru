//! Main-thread ownership of one experimental Windows save. A failed native
//! reply retains its image/handles until KTM proves commit or abort; dropping a
//! callback is never rollback. Ordinary GUI capability/crash wiring is separate.
const std = @import("std");
const builtin = @import("builtin");
const editor = @import("maru").session.editor;
const grants = @import("document_grant.zig");
const transaction = @import("transaction.zig");
const preparation = @import("save_prepare_worker.zig");
const settlement = @import("save_settle_worker.zig");
const cleanup = @import("save_cleanup_worker.zig");

pub const Status = enum { idle, preparing, settling, cleaning, finishing, prepared, uncertain, closed };
pub const PreparationReady = enum { prepared, settling, cancelled };
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
    preparation_error: ?anyerror = null,
    native_image: ?struct { allocator: std.mem.Allocator, bytes: []const u8 } = null,
};
const Preparation = struct {
    allocator: std.mem.Allocator,
    worker: preparation.Worker,
    request: editor.save_request.Request,
    cancelled: bool = false,
};
const Settlement = struct {
    allocator: std.mem.Allocator,
    worker: settlement.Worker,
};
const Cleaning = struct {
    allocator: std.mem.Allocator,
    worker: cleanup.Worker,
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
    preparing: ?*Preparation = null,
    settling: ?*Settlement = null,
    cleaning: ?*Cleaning = null,
    settlement_retry_after_ns: i128 = 0,
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
        if (self.preparing != null) return .preparing;
        if (self.settling != null) return .settling;
        if (self.cleaning != null) return .cleaning;
        const pending = self.pending orelse return .idle;
        if (pending.attempt.transaction.phase == .committed or pending.attempt.transaction.phase == .rolled_back) return .finishing;
        return if (pending.attempt.transaction.phase == .uncertain) .uncertain else .prepared;
    }

    pub fn prepare(self: *Controller, io: std.Io, source: editor.document_registry.Lease, limit: usize) !void {
        try self.prepareWith(io, source, limit, Native);
    }

    pub fn prepareOverwrite(self: *Controller, io: std.Io, source: editor.document_registry.Lease, limit: usize, observed_hash: u64) !void {
        try self.prepareImage(io, source, limit, observed_hash, Native);
    }

    pub fn prepareAsync(self: *Controller, source: editor.document_registry.Lease, limit: usize) !void {
        try self.startPreparation(source, limit, null, std.heap.smp_allocator);
    }

    pub fn prepareOverwriteAsync(self: *Controller, source: editor.document_registry.Lease, limit: usize, observed_hash: u64) !void {
        try self.startPreparation(source, limit, observed_hash, std.heap.smp_allocator);
    }

    fn startPreparation(self: *Controller, source: editor.document_registry.Lease, limit: usize, observed_hash: ?u64, worker_allocator: std.mem.Allocator) !void {
        if (self.closed) return error.ControllerClosed;
        if (self.pending != null or self.preparing != null or self.settling != null or self.cleaning != null) return error.SaveBusy;
        var request = if (observed_hash) |hash|
            try editor.save_request.Request.beginOverwrite(self.grant.allocator, self.grant.registry, source, limit, hash)
        else
            try editor.save_request.Request.begin(self.grant.allocator, self.grant.registry, source, limit);
        errdefer request.deinit();
        // The book may grow/move its controller array while this job runs. Keep
        // the worker's stable address in a separately owned allocation.
        const waiting = try worker_allocator.create(Preparation);
        errdefer worker_allocator.destroy(waiting);
        waiting.* = .{ .allocator = worker_allocator, .worker = .{ .allocator = worker_allocator }, .request = request };
        try waiting.worker.submit(&self.grant, &waiting.request, limit);
        self.preparing = waiting;
        self.last_receipt = null;
    }

    pub fn cancelPreparation(self: *Controller) !void {
        if (self.closed) return error.ControllerClosed;
        const waiting = self.preparing orelse return error.NoPendingPreparation;
        // Keep the request and slot until native ownership returns. A cancel
        // request is neither rollback proof nor permission for a second save.
        waiting.cancelled = true;
    }

    pub fn abortAsync(self: *Controller) !void {
        try self.startSettlement(.rollback, std.heap.smp_allocator);
    }

    pub fn reconcileAsync(self: *Controller) !void {
        try self.startSettlement(.reconcile, std.heap.smp_allocator);
    }

    /// Native ownership moves, but the live Request stays on its owner thread.
    /// Failed admission leaves the complete terminal attempt available to retry.
    pub fn cleanupAsync(self: *Controller) !void {
        try self.startCleanup(std.heap.smp_allocator);
    }

    fn startCleanup(self: *Controller, allocator: std.mem.Allocator) !void {
        if (self.closed) return error.ControllerClosed;
        if (self.preparing != null or self.settling != null or self.cleaning != null) return error.SaveBusy;
        const pending = if (self.pending) |*value| value else return error.NoPendingSave;
        const native_image = pending.native_image orelse return error.NonWorkerOwnedAttempt;
        const waiting = try allocator.create(Cleaning);
        errdefer allocator.destroy(waiting);
        waiting.* = .{ .allocator = allocator, .worker = .{ .allocator = allocator } };
        var image = pending.request.image();
        image.bytes = native_image.bytes;
        var prepared: preparation.Prepared = .{ .allocator = native_image.allocator, .attempt = pending.attempt, .image = image, .thread_id = 0 };
        try waiting.worker.submit(&prepared);
        pending.attempt = undefined;
        pending.native_image = null;
        self.cleaning = waiting;
    }

    pub fn pollCleanup(self: *Controller, io: std.Io) !?Receipt {
        if (self.closed) return error.ControllerClosed;
        const waiting = self.cleaning orelse return null;
        var result = (try waiting.worker.takeResult()) orelse return null;
        waiting.worker.deinit() catch unreachable;
        waiting.allocator.destroy(waiting);
        self.cleaning = null;
        const pending = &self.pending.?;
        switch (result) {
            .retained => |value| {
                pending.attempt = value.prepared.attempt;
                pending.native_image = .{ .allocator = value.prepared.allocator, .bytes = value.prepared.image.bytes };
                if (pending.attempt.transaction.phase == .uncertain) self.markUncertain();
                self.settlement_retry_after_ns = std.Io.Clock.awake.now(io).nanoseconds + 200 * std.time.ns_per_ms;
                return value.failure;
            },
            .released => |*value| {
                defer value.deinit();
                const decision: Decision = if (value.outcome == .committed) .committed else .aborted;
                var receipt: Receipt = .{ .decision = decision, .revision = pending.request.revision, .sequence = pending.request.sequence, .cleanup_error = value.cleanup_error };
                // Closed handles cannot be queried again. The worker proved KTM
                // outcome and image binding; compare that image with our still
                // owned Request before changing document persistence on main.
                if (decision == .committed) {
                    if (!value.image.sameRequest(pending.request.image()) or value.image.expected_source_hash != pending.request.expectedSourceHash()) {
                        receipt.acknowledgment_error = error.WrongSaveRequest;
                    } else {
                        pending.request.complete(.committed) catch |failure| {
                            receipt.acknowledgment_error = failure;
                        };
                    }
                } else {
                    pending.request.complete(.aborted) catch |failure| {
                        if (failure != error.SaveNotCommitted) receipt.acknowledgment_error = failure;
                    };
                }
                const state = pending.request.registry.get(pending.request.lease).?;
                pending.request.deinit();
                if (receipt.acknowledgment_error == null)
                    @import("backup_store.zig").noteDecision(state, std.Io.Clock.awake.now(io).nanoseconds);
                self.pending = null;
                self.settlement_retry_after_ns = 0;
                self.last_receipt = receipt;
                return receipt;
            },
        }
    }

    fn startSettlement(self: *Controller, action: settlement.Action, allocator: std.mem.Allocator) !void {
        if (self.closed) return error.ControllerClosed;
        if (self.preparing != null or self.settling != null or self.cleaning != null) return error.SaveBusy;
        const pending = if (self.pending) |*value| value else return error.NoPendingSave;
        const waiting = try allocator.create(Settlement);
        errdefer allocator.destroy(waiting);
        waiting.* = .{ .allocator = allocator, .worker = .{ .allocator = allocator } };
        // Preparation workers already own an independent native image. Legacy
        // synchronous attempts get a copy before admission; Request stays main.
        const image_allocator = if (pending.native_image) |image| image.allocator else std.heap.smp_allocator;
        const bytes = if (pending.native_image) |image| image.bytes else try image_allocator.dupe(u8, pending.request.bytes);
        errdefer if (pending.native_image == null) image_allocator.free(bytes);
        var image = pending.request.image();
        image.bytes = bytes;
        var prepared: preparation.Prepared = .{ .allocator = image_allocator, .attempt = pending.attempt, .image = image, .thread_id = 0, .preparation_error = pending.preparation_error };
        try waiting.worker.submit(&prepared, action);
        // All native ownership moved. Access to pending.attempt/image is gated
        // by settling until takeResult returns it; the document Request remains.
        pending.attempt = undefined;
        pending.native_image = null;
        self.settling = waiting;
    }

    pub fn pollSettlement(self: *Controller, io: std.Io) !?Receipt {
        return self.pollSettlementUsing(io, false);
    }

    pub fn pollSettlementForApp(self: *Controller, io: std.Io) !?Receipt {
        return self.pollSettlementUsing(io, true);
    }

    fn pollSettlementUsing(self: *Controller, io: std.Io, comptime async_cleanup: bool) !?Receipt {
        if (self.closed) return error.ControllerClosed;
        const waiting = self.settling orelse return null;
        const result = (try waiting.worker.takeResult()) orelse return null;
        const pending = &self.pending.?;
        pending.attempt = result.prepared.attempt;
        pending.native_image = .{ .allocator = result.prepared.allocator, .bytes = result.prepared.image.bytes };
        waiting.worker.deinit() catch unreachable;
        waiting.allocator.destroy(waiting);
        self.settling = null;
        if (result.outcome == .undetermined) {
            if (pending.attempt.transaction.phase == .uncertain) self.markUncertain();
            self.settlement_retry_after_ns = std.Io.Clock.awake.now(io).nanoseconds + 200 * std.time.ns_per_ms;
            return result.failure orelse error.SaveUncertain;
        }
        self.settlement_retry_after_ns = 0;
        if (async_cleanup) {
            try self.cleanupAsync();
            return null;
        }
        return self.settle(io, if (result.outcome == .committed) .committed else .aborted);
    }

    pub fn pollPreparation(self: *Controller, io: std.Io) !?PreparationReady {
        return self.pollPreparationWith(io, Native);
    }

    pub fn pollPreparationForApp(self: *Controller, io: std.Io) !?PreparationReady {
        return self.pollPreparationUsing(io, Native, true);
    }

    fn finishPreparation(self: *Controller, waiting: *Preparation, moved_request: bool) void {
        std.debug.assert(waiting.worker.job == null);
        if (!moved_request) waiting.request.deinit();
        waiting.allocator.destroy(waiting);
        self.preparing = null;
    }

    fn pollPreparationWith(self: *Controller, io: std.Io, comptime Driver: type) !?PreparationReady {
        return self.pollPreparationUsing(io, Driver, false);
    }

    fn pollPreparationUsing(self: *Controller, io: std.Io, comptime Driver: type, comptime async_abort: bool) !?PreparationReady {
        if (self.closed) return error.ControllerClosed;
        const waiting = self.preparing orelse return null;
        const result = (try waiting.worker.takeResult()) orelse return null;
        const cancelled = waiting.cancelled;
        switch (result) {
            .failure => |failure| {
                self.finishPreparation(waiting, false);
                if (cancelled) return .cancelled;
                return failure;
            },
            .prepared => |value| {
                // Move both independent image allocations and native handles.
                // Even failed preparation stays owned until confirmed rollback.
                self.pending = .{ .request = waiting.request, .attempt = value.attempt, .native_image = .{ .allocator = value.allocator, .bytes = value.image.bytes }, .preparation_error = if (cancelled) error.SaveCancelled else value.preparation_error };
                self.finishPreparation(waiting, true);
                if (cancelled) {
                    if (async_abort) {
                        try self.abortAsync();
                        return .settling;
                    }
                    _ = try self.abortWith(io, Driver);
                    return .cancelled;
                }
                const pending = &self.pending.?;
                if (!value.image.sameRequest(pending.request.image())) pending.preparation_error = error.WrongSaveRequest;
                if (pending.preparation_error == null) self.grant.validate(&pending.request) catch |failure| {
                    pending.preparation_error = failure;
                };
                if (pending.preparation_error) |failure| {
                    if (async_abort) {
                        try self.abortAsync();
                        return .settling;
                    }
                    _ = self.abortWith(io, Driver) catch {};
                    return failure;
                }
                return .prepared;
            },
        }
    }

    fn prepareWith(self: *Controller, io: std.Io, source: editor.document_registry.Lease, limit: usize, comptime Driver: type) !void {
        return self.prepareImage(io, source, limit, null, Driver);
    }

    fn prepareImage(self: *Controller, io: std.Io, source: editor.document_registry.Lease, limit: usize, observed_hash: ?u64, comptime Driver: type) !void {
        if (self.closed) return error.ControllerClosed;
        if (self.pending != null or self.preparing != null or self.settling != null or self.cleaning != null) return error.SaveBusy;
        var request = if (observed_hash) |hash|
            try editor.save_request.Request.beginOverwrite(self.grant.allocator, self.grant.registry, source, limit, hash)
        else
            try editor.save_request.Request.begin(self.grant.allocator, self.grant.registry, source, limit);
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

    /// Commit still runs on main until the approval handshake is connected;
    /// failed authority checks roll back asynchronously and terminal cleanup
    /// always keeps the owned Request until the worker result is consumed.
    pub fn commitForApp(self: *Controller, io: std.Io) !?Receipt {
        if (self.closed) return error.ControllerClosed;
        if (self.preparing != null or self.settling != null or self.cleaning != null) return error.SaveBusy;
        const pending = if (self.pending) |*value| value else return error.NoPendingSave;
        if (pending.preparation_error) |failure| return failure;
        if (pending.attempt.transaction.phase != .prepared) return error.SaveUncertain;
        Native.commit(&self.grant, io, &pending.attempt, &pending.request) catch |failure| {
            if (pending.attempt.transaction.phase == .uncertain) {
                self.markUncertain();
                return failure;
            }
            pending.preparation_error = failure;
            try self.abortAsync();
            return null;
        };
        try self.cleanupAsync();
        return null;
    }
    fn commitWith(self: *Controller, io: std.Io, comptime Driver: type) !Receipt {
        if (self.closed) return error.ControllerClosed;
        if (self.preparing != null or self.settling != null or self.cleaning != null) return error.SaveBusy;
        const pending = if (self.pending) |*value| value else return error.NoPendingSave;
        if (pending.preparation_error) |failure| return failure;
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
        if (self.preparing != null or self.settling != null or self.cleaning != null) return error.SaveBusy;
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
        if (self.preparing != null or self.settling != null or self.cleaning != null) return error.SaveBusy;
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
        if (pending.native_image) |image| image.allocator.free(image.bytes);
        pending.request.deinit();
        if (receipt.acknowledgment_error == null)
            @import("backup_store.zig").noteDecision(state, std.Io.Clock.awake.now(io).nanoseconds);
        self.pending = null;
        self.settlement_retry_after_ns = 0;
        self.last_receipt = receipt;
        return receipt;
    }

    /// Explicit shutdown aborts a prepared save, but refuses to drop an unknown
    /// native result. On refusal every handle/image/grant remains owned for retry.
    pub fn deinit(self: *Controller, io: std.Io) !void {
        if (self.closed) return error.ControllerClosed;
        if (self.preparing != null or self.settling != null or self.cleaning != null) return error.SaveBusy;
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
        if (self.controller.preparing != null) {
            self.controller.cancelPreparation() catch unreachable;
            _ = awaitPreparation(&self.controller) catch {};
        }
        if (self.controller.settling != null) _ = awaitSettlement(&self.controller) catch {};
        if (self.controller.pending != null and self.controller.status() == .uncertain) _ = self.controller.abort(std.testing.io) catch {};
        if (!self.controller.closed) self.controller.deinit(std.testing.io) catch @panic("fixture has unresolved save");
        _ = self.registry.release(self.view) catch unreachable;
        self.registry.deinit() catch unreachable;
        std.testing.allocator.destroy(self.registry);
        self.tmp.cleanup();
    }
};

fn awaitSettlement(controller: *Controller) !Receipt {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline) {
        if (try controller.pollSettlement(std.testing.io)) |receipt| return receipt;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.SettlementDidNotComplete;
}

test "Windows save controller async rollback retains its document while native ownership moves" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepare(std.testing.io, f.view, 128);
    try f.controller.abortAsync();
    try std.testing.expectEqual(Status.settling, f.controller.status());
    try std.testing.expectEqual(@as(u64, 1), f.state().persistence.live_save_images);
    try std.testing.expectError(error.SaveBusy, f.controller.commit(std.testing.io));
    try std.testing.expectError(error.SaveBusy, f.controller.abort(std.testing.io));
    try std.testing.expectError(error.SaveBusy, f.controller.reconcile(std.testing.io));
    try std.testing.expectError(error.SaveBusy, f.controller.deinit(std.testing.io));
    try std.testing.expectError(error.SaveBusy, f.controller.abortAsync());
    try std.testing.expectError(error.SaveBusy, f.controller.prepareAsync(f.view, 128));
    const receipt = try awaitSettlement(&f.controller);
    try std.testing.expectEqual(Decision.aborted, receipt.decision);
    try std.testing.expect(receipt.acknowledgment_error == null);
    try std.testing.expectEqual(Status.idle, f.controller.status());
    try std.testing.expectEqual(@as(u64, 0), f.state().persistence.live_save_images);
    try std.testing.expect(f.state().opened.?.isDirty());
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
}

test "Windows save controller async settlement survives moving the controller" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepareAsync(f.view, 128);
    _ = try awaitPreparation(&f.controller);
    try f.controller.abortAsync();
    const moved = try std.testing.allocator.create(Controller);
    moved.* = f.controller;
    f.controller = undefined;
    defer {
        f.controller = moved.*;
        std.testing.allocator.destroy(moved);
    }
    try std.testing.expectEqual(Status.settling, moved.status());
    const receipt = try awaitSettlement(moved);
    try std.testing.expectEqual(Decision.aborted, receipt.decision);
    try std.testing.expectEqual(Status.idle, moved.status());
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
}

test "Windows save controller async unknown reconciliation retains images for actual rollback retry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepareAsync(f.view, 128);
    _ = try awaitPreparation(&f.controller);
    f.controller.pending.?.attempt.transaction.phase = .uncertain;
    try f.controller.reconcileAsync();
    try std.testing.expectError(error.SaveUncertain, awaitSettlement(&f.controller));
    try std.testing.expectEqual(Status.uncertain, f.controller.status());
    try std.testing.expect(f.controller.pending != null);
    try std.testing.expect(f.controller.pending.?.native_image != null);
    try std.testing.expectEqual(@as(u64, 1), f.state().persistence.live_save_images);
    try std.testing.expect(f.state().persistence.uncertain_sequence != null);
    try std.testing.expectError(error.SaveBusy, f.controller.prepareAsync(f.view, 128));
    try f.controller.abortAsync();
    const receipt = try awaitSettlement(&f.controller);
    try std.testing.expectEqual(Decision.aborted, receipt.decision);
    try std.testing.expect(f.state().persistence.uncertain_sequence == null);
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
}

test "Windows save controller async native committed query acknowledges an actual lost reply" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.prepareAsync(f.view, 128);
    _ = try awaitPreparation(&f.controller);
    const pending = &f.controller.pending.?;
    try f.controller.grant.commit(std.testing.io, &pending.attempt, &pending.request);
    pending.attempt.transaction.phase = .uncertain;
    try f.controller.reconcileAsync();
    const receipt = try awaitSettlement(&f.controller);
    try std.testing.expectEqual(Decision.committed, receipt.decision);
    try std.testing.expect(receipt.acknowledgment_error == null);
    try std.testing.expect(!f.state().opened.?.isDirty());
    try std.testing.expectEqual(@as(u64, 0), f.state().persistence.live_save_images);
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save controller async settlement allocation prefixes preserve pending ownership" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for (0..3) |index| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.edit("X");
        try f.controller.prepareAsync(f.view, 128);
        _ = try awaitPreparation(&f.controller);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        if (index < 2) {
            try std.testing.expectError(error.OutOfMemory, f.controller.startSettlement(.rollback, failing.allocator()));
            try std.testing.expectEqual(Status.prepared, f.controller.status());
            try std.testing.expect(f.controller.pending.?.native_image != null);
            try std.testing.expectEqual(@as(u64, 1), f.state().persistence.live_save_images);
            try f.controller.abortAsync();
        } else try f.controller.startSettlement(.rollback, failing.allocator());
        const receipt = try awaitSettlement(&f.controller);
        try std.testing.expectEqual(Decision.aborted, receipt.decision);
        try std.testing.expectEqual(@as(u64, 0), f.state().persistence.live_save_images);
        try f.expectDisk("\xef\xbb\xbfbase\r\n");
    }
}

fn awaitPreparation(controller: *Controller) !PreparationReady {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(io).nanoseconds < deadline) {
        if (try controller.pollPreparation(io)) |ready| return ready;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.PreparationDidNotComplete;
}

fn awaitNativePreparation(controller: *Controller) !void {
    const io = std.testing.io;
    const job = controller.preparing.?.worker.job.?;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (!job.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.PreparationDidNotComplete;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "Windows save controller asynchronous preparation survives controller relocation and keeps later edits dirty" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.startPreparation(f.view, 128, null, a);
    try std.testing.expectEqual(Status.preparing, f.controller.status());
    try std.testing.expectError(error.SaveBusy, f.controller.prepare(io, f.view, 128));
    try std.testing.expectError(error.SaveBusy, f.controller.prepareAsync(f.view, 128));
    try std.testing.expectError(error.SaveBusy, f.controller.commit(io));
    try std.testing.expectError(error.SaveBusy, f.controller.abort(io));
    try std.testing.expectError(error.SaveBusy, f.controller.deinit(io));
    try std.testing.expect(!f.controller.closed);
    try f.edit("Y");
    const state = f.state();
    const moved = try a.create(Controller);
    moved.* = f.controller;
    f.controller = undefined;
    defer {
        f.controller = moved.*;
        a.destroy(moved);
    }
    try std.testing.expectEqual(PreparationReady.prepared, try awaitPreparation(moved));
    try std.testing.expect(moved.pending.?.native_image != null);
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
    const receipt = try moved.commit(io);
    try std.testing.expectEqual(Decision.committed, receipt.decision);
    try std.testing.expectEqual(@as(?anyerror, null), receipt.acknowledgment_error);
    try std.testing.expect(state.opened.?.isDirty());
    try std.testing.expectEqualStrings("YXbase\r\n", state.opened.?.file.content);
    try std.testing.expectEqual(@as(u64, 0), state.persistence.live_save_images);
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save controller asynchronous cancellation drains native ownership before releasing its image" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    const saved = f.state().opened.?.saved_hash;
    try f.controller.prepareAsync(f.view, 128);
    try f.controller.cancelPreparation();
    try std.testing.expectEqual(Status.preparing, f.controller.status());
    try std.testing.expectEqual(@as(u64, 1), f.state().persistence.live_save_images);
    try std.testing.expectError(error.SaveBusy, f.controller.prepareAsync(f.view, 128));
    try std.testing.expectEqual(PreparationReady.cancelled, try awaitPreparation(&f.controller));
    try std.testing.expectEqual(Status.idle, f.controller.status());
    try std.testing.expectEqual(Decision.aborted, f.controller.last_receipt.?.decision);
    try std.testing.expectEqual(@as(u64, 0), f.state().persistence.live_save_images);
    try std.testing.expectEqual(saved, f.state().opened.?.saved_hash);
    try std.testing.expect(f.state().opened.?.isDirty());
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
}

test "Windows save controller asynchronous source failure preserves state and allows a fresh retry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    const saved = f.state().opened.?.saved_hash;
    const disk = f.state().opened.?.disk_hash;
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/file.txt", .data = "outside" });
    try f.controller.startPreparation(f.view, 128, null, std.testing.allocator);
    try std.testing.expectError(error.SourceChanged, awaitPreparation(&f.controller));
    try std.testing.expectEqual(Status.idle, f.controller.status());
    try std.testing.expectEqual(@as(u64, 0), f.state().persistence.live_save_images);
    try std.testing.expectEqual(saved, f.state().opened.?.saved_hash);
    try std.testing.expectEqual(disk, f.state().opened.?.disk_hash);
    try f.expectDisk("outside");
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/file.txt", .data = "\xef\xbb\xbfbase\r\n" });
    try f.controller.startPreparation(f.view, 128, null, std.testing.allocator);
    try std.testing.expectEqual(PreparationReady.prepared, try awaitPreparation(&f.controller));
    _ = try f.controller.commit(std.testing.io);
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save controller asynchronous ready image revalidates a revoked document permission" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.startPreparation(f.view, 128, null, std.testing.allocator);
    f.state().opened.?.file.read_only = true;
    try std.testing.expectError(error.ReadOnly, awaitPreparation(&f.controller));
    try std.testing.expectEqual(Status.idle, f.controller.status());
    try std.testing.expectEqual(@as(u64, 0), f.state().persistence.live_save_images);
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
    f.state().opened.?.file.read_only = false;
}

test "Windows save controller asynchronous failure retains its native image when rollback is unconfirmed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const RefuseRollback = struct {
        fn rollback(_: *grants.Attempt) !void {
            return error.RollbackUncertain;
        }
    };
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.startPreparation(f.view, 128, null, std.testing.allocator);
    try awaitNativePreparation(&f.controller);
    const reply = &f.controller.preparing.?.worker.job.?.result.?.prepared;
    reply.preparation_error = error.InjectedPreparationFailure;
    reply.attempt.transaction.phase = .poisoned;
    try std.testing.expectError(error.InjectedPreparationFailure, f.controller.pollPreparationWith(std.testing.io, RefuseRollback));
    try std.testing.expectEqual(Status.prepared, f.controller.status());
    try std.testing.expect(f.controller.pending.?.native_image != null);
    try std.testing.expectEqual(@as(u64, 1), f.state().persistence.live_save_images);
    try std.testing.expectEqual(transaction.Outcome.undetermined, try f.controller.pending.?.attempt.transaction.queryOutcome());
    try std.testing.expectError(error.InjectedPreparationFailure, f.controller.commit(std.testing.io));
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
    const receipt = try f.controller.abort(std.testing.io);
    try std.testing.expectEqual(Decision.aborted, receipt.decision);
    try std.testing.expectEqual(@as(u64, 0), f.state().persistence.live_save_images);
}

test "Windows save controller asynchronous cancelled image cannot commit after failed rollback" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const RefuseRollback = struct {
        fn rollback(_: *grants.Attempt) !void {
            return error.RollbackUncertain;
        }
    };
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    try f.controller.startPreparation(f.view, 128, null, std.testing.allocator);
    try awaitNativePreparation(&f.controller);
    try f.controller.cancelPreparation();
    try std.testing.expectError(error.RollbackUncertain, f.controller.pollPreparationWith(std.testing.io, RefuseRollback));
    try std.testing.expectEqual(Status.prepared, f.controller.status());
    try std.testing.expectError(error.SaveCancelled, f.controller.commit(std.testing.io));
    try std.testing.expectEqual(@as(u64, 1), f.state().persistence.live_save_images);
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
    _ = try f.controller.abort(std.testing.io);
    try std.testing.expectEqual(@as(u64, 0), f.state().persistence.live_save_images);
}

test "Windows save controller asynchronous admission unwinds all allocation prefixes without publishing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    for (0..4) |prefix| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = prefix });
        try std.testing.expectError(error.OutOfMemory, f.controller.startPreparation(f.view, 128, null, failing.allocator()));
        try std.testing.expectEqual(Status.idle, f.controller.status());
        try std.testing.expectEqual(@as(u64, 0), f.state().persistence.live_save_images);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
}

test "Windows save controller asynchronous overwrite keeps document CAS separate from fresh native source" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.edit("X");
    const saved = f.state().opened.?.saved_hash;
    const disk = f.state().opened.?.disk_hash;
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/file.txt", .data = "newer" });
    try f.controller.prepareOverwriteAsync(f.view, 128, editor.document_state.contentHash("outside"));
    try std.testing.expectError(error.SourceChanged, awaitPreparation(&f.controller));
    try std.testing.expectEqual(saved, f.state().opened.?.saved_hash);
    try std.testing.expectEqual(disk, f.state().opened.?.disk_hash);
    try std.testing.expectEqual(@as(u64, 0), f.state().persistence.live_save_images);
    try f.expectDisk("newer");
    try f.controller.prepareOverwriteAsync(f.view, 128, editor.document_state.contentHash("newer"));
    try std.testing.expectEqual(PreparationReady.prepared, try awaitPreparation(&f.controller));
    try std.testing.expectEqual(disk, f.state().opened.?.disk_hash);
    try std.testing.expectEqual(saved, f.state().opened.?.saved_hash);
    _ = try f.controller.commit(std.testing.io);
    try std.testing.expect(!f.state().opened.?.isDirty());
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}

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

fn awaitCleanup(controller: *Controller) !Receipt {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline) {
        if (try controller.pollCleanup(std.testing.io)) |receipt| return receipt;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.CleanupDidNotComplete;
}
fn drainCleanup(controller: *Controller) void {
    if (controller.cleaning != null) _ = awaitCleanup(controller) catch {};
    std.debug.assert(controller.cleaning == null);
}
fn prepareCleanupFixture(f: *Fixture, committed: bool) !void {
    try f.edit("X");
    try f.controller.prepareAsync(f.view, 128);
    try std.testing.expectEqual(PreparationReady.prepared, try awaitPreparation(&f.controller));
    if (committed) {
        try Native.commit(&f.controller.grant, std.testing.io, &f.controller.pending.?.attempt, &f.controller.pending.?.request);
    } else {
        try f.controller.pending.?.attempt.transaction.rollback();
    }
}

test "Windows save controller native cleanup retains request until confirmed committed receipt" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    defer drainCleanup(&f.controller);
    try prepareCleanupFixture(&f, true);
    try f.controller.cleanupAsync();
    try std.testing.expectEqual(Status.cleaning, f.controller.status());
    try std.testing.expect(f.state().opened.?.isDirty());
    try std.testing.expectEqual(@as(u64, 1), f.state().persistence.live_save_images);
    try std.testing.expectError(error.SaveBusy, f.controller.deinit(std.testing.io));
    try std.testing.expectError(error.SaveBusy, f.controller.abort(std.testing.io));
    try std.testing.expectError(error.SaveBusy, f.controller.commit(std.testing.io));
    const receipt = try awaitCleanup(&f.controller);
    try std.testing.expectEqual(Decision.committed, receipt.decision);
    try std.testing.expect(receipt.acknowledgment_error == null);
    try std.testing.expect(!f.state().opened.?.isDirty());
    try std.testing.expectEqual(@as(u64, 0), f.state().persistence.live_save_images);
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save controller native rollback cleanup never acknowledges dirty contents" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    defer drainCleanup(&f.controller);
    try prepareCleanupFixture(&f, false);
    try f.controller.cleanupAsync();
    const receipt = try awaitCleanup(&f.controller);
    try std.testing.expectEqual(Decision.aborted, receipt.decision);
    try std.testing.expect(f.state().opened.?.isDirty());
    try std.testing.expectEqual(@as(u64, 0), f.state().persistence.acknowledged);
    try std.testing.expectEqual(@as(u64, 0), f.state().persistence.live_save_images);
    try f.expectDisk("\xef\xbb\xbfbase\r\n");
}

test "Windows save controller cleanup acknowledges committed image despite later permission and body edits" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    defer drainCleanup(&f.controller);
    try prepareCleanupFixture(&f, true);
    try f.edit("Y");
    f.state().opened.?.file.read_only = true;
    try f.controller.cleanupAsync();
    const receipt = try awaitCleanup(&f.controller);
    try std.testing.expectEqual(Decision.committed, receipt.decision);
    try std.testing.expect(receipt.acknowledgment_error == null);
    try std.testing.expect(f.state().opened.?.isDirty());
    try std.testing.expectEqual(receipt.sequence, f.state().persistence.acknowledged);
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save controller cleanup keeps native commit separate from stale disk acknowledgment" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    defer drainCleanup(&f.controller);
    try prepareCleanupFixture(&f, true);
    const saved = f.state().opened.?.saved_hash;
    f.state().opened.?.disk_hash = editor.document_state.contentHash("new-observation");
    try f.controller.cleanupAsync();
    const receipt = try awaitCleanup(&f.controller);
    try std.testing.expectEqual(Decision.committed, receipt.decision);
    try std.testing.expect(receipt.acknowledgment_error != null);
    try std.testing.expectEqual(saved, f.state().opened.?.saved_hash);
    try std.testing.expectEqual(@as(u64, 0), f.state().persistence.live_save_images);
    try std.testing.expectEqual(Status.idle, f.controller.status());
    try f.expectDisk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save controller cleanup admission failure preserves terminal ownership for retry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    defer drainCleanup(&f.controller);
    try prepareCleanupFixture(&f, true);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, f.controller.startCleanup(failing.allocator()));
    try std.testing.expect(f.controller.cleaning == null);
    try std.testing.expect(f.controller.pending.?.native_image != null);
    try std.testing.expectEqual(transaction.Outcome.committed, try f.controller.pending.?.attempt.transaction.queryOutcome());
    try std.testing.expectEqual(@as(u64, 1), f.state().persistence.live_save_images);
    try f.controller.cleanupAsync();
    try std.testing.expectEqual(Decision.committed, (try awaitCleanup(&f.controller)).decision);
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
