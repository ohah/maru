//! Fence the original native name off main, wait for a final main-thread vote,
//! then commit without Registry access. Every reply returns native ownership.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const preparation = @import("save_prepare_worker.zig");
const grants = @import("document_grant.zig");
const Identity = @import("identity.zig").Identity;
const editor = maru.session.editor;
const relative = maru.win32_relative_file;
const w = std.os.windows;
extern "kernel32" fn DuplicateHandle(w.HANDLE, w.HANDLE, w.HANDLE, *w.HANDLE, u32, w.BOOL, u32) callconv(maru.win32_abi.winapi) w.BOOL;

const Vote = enum(u8) { waiting, approved, cancelled, claimed };
var next_scope: std.atomic.Value(u64) = .init(1);
fn reserveScope(counter: *std.atomic.Value(u64)) !u64 {
    var current = counter.load(.monotonic);
    while (true) {
        if (current == 0 or current == std.math.maxInt(u64)) return error.CommitScopeExhausted;
        current = counter.cmpxchgStrong(current, current + 1, .monotonic, .monotonic) orelse return current;
    }
}
pub const Result = struct {
    prepared: preparation.Prepared,
    failure: ?anyerror,
    thread_id: std.Thread.Id,
};
const Native = struct {
    fn commit(prepared: *preparation.Prepared, io: std.Io, scope: u64, approval: *editor.save_request.CommitApproval) !void {
        try prepared.attempt.transaction.commitApproved(io, prepared.image, scope, approval);
    }
};
const Job = struct {
    prepared: preparation.Prepared,
    root: std.Io.Dir,
    name: []u8,
    identity: Identity,
    scope: u64,
    owner_thread: std.Thread.Id,
    approval: editor.save_request.CommitApproval = .{},
    vote: std.atomic.Value(Vote) = .init(.waiting),
    ready: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    signal: std.Io.Semaphore = .{},
    // This provider is pinned with the job until main consumes its reply. Both
    // semaphore post and native I/O can use it; a worker cannot destroy it while
    // the publishing main-thread call still has a provider reference on stack.
    threaded: std.Io.Threaded,
    result: ?Result = null,

    fn execute(self: *Job, io: std.Io, comptime Driver: type) !void {
        if (self.vote.load(.acquire) == .cancelled) return error.SaveCancelled;
        var current = try relative.open(std.heap.smp_allocator, self.root, self.name);
        defer current.deinit(io);
        if (!self.identity.eql(try Identity.capture(current.original.handle))) return error.IdentityChanged;
        const tx = &self.prepared.attempt.transaction;
        if (!self.identity.eql(tx.identity)) return error.WrongGrantFile;
        const bound = tx.request_image orelse return error.DocumentRequestRequired;
        if (!bound.sameRequest(self.prepared.image) or bound.expected_source_hash != self.prepared.image.expected_source_hash) return error.WrongSaveRequest;
        try self.prepared.image.validate(tx.source_hash);
        // The fresh root-relative fence stays alive while main checks live
        // authority and through the native decision. No later bytes are read.
        self.ready.store(true, .release);
        self.signal.waitUncancelable(io);
        if (self.vote.cmpxchgStrong(.approved, .claimed, .acq_rel, .acquire) != null) return error.SaveCancelled;
        try Driver.commit(&self.prepared, io, self.scope, &self.approval);
    }
    fn run(self: *Job, comptime Driver: type) void {
        const io = self.threaded.io();
        const failure: ?anyerror = blk: {
            self.execute(io, Driver) catch |err| break :blk err;
            break :blk null;
        };
        self.root.close(io);
        std.heap.smp_allocator.free(self.name);
        self.result = .{ .prepared = self.prepared, .failure = failure, .thread_id = std.Thread.getCurrentId() };
        self.done.store(true, .release);
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator = std.heap.smp_allocator,
    job: ?*Job = null,
    address: ?*Worker = null,

    pub fn submit(self: *Worker, grant: *const grants.Grant, prepared: *preparation.Prepared) !void {
        try self.submitWith(grant, prepared, Native);
    }
    fn submitWith(self: *Worker, grant: *const grants.Grant, prepared: *preparation.Prepared, comptime Driver: type) !void {
        if (self.address != null and self.address != self) return error.CopiedCommitWorker;
        if (self.job != null) return error.SaveBusy;
        if (prepared.preparation_error) |failure| return failure;
        if (prepared.attempt.transaction.phase != .prepared) return error.InvalidState;
        if (prepared.allocator.vtable != std.heap.smp_allocator.vtable or prepared.attempt.pinned.allocator.vtable != std.heap.smp_allocator.vtable) return error.NonWorkerOwnedAttempt;
        const scope = try reserveScope(&next_scope);
        const name = try std.heap.smp_allocator.dupe(u8, grant.relative_path);
        errdefer std.heap.smp_allocator.free(name);
        var handle: w.HANDLE = undefined;
        if (!DuplicateHandle(w.GetCurrentProcess(), grant.root.handle, w.GetCurrentProcess(), &handle, 0, .FALSE, 2).toBool()) return error.HandleDuplicateFailed;
        errdefer _ = w.ntdll.NtClose(handle);
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .prepared = prepared.*, .root = .{ .handle = handle }, .name = name, .identity = grant.identity, .scope = scope, .owner_thread = std.Thread.getCurrentId(), .threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{}) };
        errdefer job.threaded.deinit();
        const Runner = struct {
            fn run(value: *Job) void {
                value.run(Driver);
            }
        };
        const thread = try std.Thread.spawn(.{}, Runner.run, .{job});
        thread.detach();
        prepared.* = undefined;
        self.job = job;
        self.address = self;
    }
    fn ownedJob(self: *Worker) !*Job {
        if (self.address != null and self.address != self) return error.CopiedCommitWorker;
        const job = self.job orelse return error.NoPendingSave;
        if (job.owner_thread != std.Thread.getCurrentId()) return error.WrongCommitThread;
        return job;
    }
    pub fn needsApproval(self: *Worker) !bool {
        const job = try self.ownedJob();
        return !job.done.load(.acquire) and job.ready.load(.acquire) and job.vote.load(.acquire) == .waiting;
    }
    pub fn approve(self: *Worker, grant: *const grants.Grant, request: *const editor.save_request.Request) !void {
        const job = try self.ownedJob();
        if (job.vote.load(.acquire) != .waiting) return error.CommitAlreadyDecided;
        if (job.done.load(.acquire) or !job.ready.load(.acquire)) return error.CommitNotReady;
        try grant.validate(request);
        if (!grant.identity.eql(job.identity)) return error.WrongGrantFile;
        if (!job.prepared.image.sameRequest(request.image()) or job.prepared.image.expected_source_hash != request.expectedSourceHash()) return error.WrongSaveRequest;
        try request.approveCommit(job.scope, job.prepared.attempt.transaction.source_hash, &job.approval);
        if (job.vote.cmpxchgStrong(.waiting, .approved, .release, .monotonic) != null) return error.CommitAlreadyDecided;
        job.signal.post(job.threaded.io());
    }
    /// False means native execution already claimed the vote. Keep ownership
    /// and report the real outcome rather than calling that late request abort.
    pub fn cancel(self: *Worker) !bool {
        const job = try self.ownedJob();
        var vote = job.vote.load(.acquire);
        while (true) {
            if (vote == .claimed) return false;
            if (vote == .cancelled) return true;
            vote = job.vote.cmpxchgStrong(vote, .cancelled, .acq_rel, .acquire) orelse {
                job.signal.post(job.threaded.io());
                return true;
            };
        }
    }
    pub fn takeResult(self: *Worker) !?Result {
        if (self.address != null and self.address != self) return error.CopiedCommitWorker;
        if (self.job == null) return null;
        const job = try self.ownedJob();
        if (!job.done.load(.acquire)) return null;
        const result = job.result.?;
        job.threaded.deinit();
        self.allocator.destroy(job);
        self.job = null;
        return result;
    }
    pub fn deinit(self: *Worker) !void {
        if (self.address != null and self.address != self) return error.CopiedCommitWorker;
        if (self.job != null) return error.SaveBusy;
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    registry: *editor.document_registry.Registry,
    opened: grants.Opened,
    request: editor.save_request.Request,
    request_owned: bool = true,
    fn init() !Fixture {
        const a = std.testing.allocator;
        const registry = try a.create(editor.document_registry.Registry);
        registry.* = .{ .allocator = a };
        errdefer a.destroy(registry);
        errdefer registry.deinit() catch unreachable;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "\xef\xbb\xbfbase\r\n" });
        var opened = try grants.Grant.openExperimental(a, std.testing.io, tmp.dir, "file.txt", registry, 128);
        errdefer opened.grant.deinit(std.testing.io);
        errdefer _ = registry.release(opened.view) catch unreachable;
        const state = registry.get(opened.view).?;
        var selection: editor.selection.Selections = .{ .items = &.{}, .primary = 0 };
        const changes = [_]editor.delta.Change{.{ .start = 0, .end = 0, .text = "X" }};
        var inverse = try state.opened.?.file.apply(.{ .changes = &changes }, &selection);
        inverse.deinit();
        const request = try editor.save_request.Request.begin(a, registry, opened.view, 128);
        return .{ .tmp = tmp, .registry = registry, .opened = opened, .request = request };
    }
    fn prepared(self: *Fixture) !preparation.Prepared {
        return self.preparedWithAllocator(std.heap.smp_allocator);
    }
    fn preparedWithAllocator(self: *Fixture, a: std.mem.Allocator) !preparation.Prepared {
        var worker: preparation.Worker = .{ .allocator = a };
        defer worker.deinit(std.testing.io) catch unreachable;
        try worker.submit(&self.opened.grant, &self.request, 128);
        const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
        while (std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline) {
            if (try worker.takeResult()) |result| return switch (result) {
                .prepared => |value| value,
                .failure => |err| err,
            };
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.PreparationDidNotComplete;
    }
    fn disk(self: *Fixture, expected: []const u8) !void {
        const bytes = try self.tmp.dir.readFileAlloc(std.testing.io, "file.txt", std.testing.allocator, .limited(128));
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(expected, bytes);
    }
    fn deinit(self: *Fixture) void {
        if (self.request_owned) self.request.deinit();
        self.opened.grant.deinit(std.testing.io);
        _ = self.registry.release(self.opened.view) catch unreachable;
        self.registry.deinit() catch unreachable;
        std.testing.allocator.destroy(self.registry);
        self.tmp.cleanup();
    }
};

fn awaitReady(worker: *Worker) !void {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline) {
        if (try worker.needsApproval()) return;
        if (worker.job.?.done.load(.acquire)) return error.CommitBindingFailed;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.CommitBindingTimeout;
}
fn awaitResult(worker: *Worker) !Result {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline) {
        if (try worker.takeResult()) |result| return result;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.CommitDidNotComplete;
}
fn drain(worker: *Worker) void {
    if (worker.job != null) {
        _ = worker.cancel() catch unreachable;
        var result = awaitResult(worker) catch @panic("commit fixture did not drain");
        result.prepared.close(std.testing.io) catch unreachable;
    }
    worker.deinit() catch unreachable;
}

test "Windows save commit worker requires live main approval before actual native commit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.submit(&f.opened.grant, &prepared);
    try awaitReady(&worker);
    try f.disk("\xef\xbb\xbfbase\r\n");
    try std.testing.expect((try worker.takeResult()) == null);
    try worker.approve(&f.opened.grant, &f.request);
    var result = try awaitResult(&worker);
    defer result.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expect(result.failure == null);
    try std.testing.expect(result.thread_id != std.Thread.getCurrentId());
    try std.testing.expectEqual(@import("transaction.zig").Outcome.committed, try result.prepared.attempt.transaction.queryOutcome());
    try std.testing.expectEqual(@as(u64, 0), f.registry.get(f.opened.view).?.persistence.acknowledged);
    try std.testing.expect(f.registry.get(f.opened.view).?.opened.?.isDirty());
    try f.disk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save commit worker refuses final permission revocation without publishing vote" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.submit(&f.opened.grant, &prepared);
    try awaitReady(&worker);
    f.registry.get(f.opened.view).?.opened.?.file.read_only = true;
    try std.testing.expectError(error.ReadOnly, worker.approve(&f.opened.grant, &f.request));
    try std.testing.expectEqual(Vote.waiting, worker.job.?.vote.load(.acquire));
    try std.testing.expect(worker.job.?.approval.owner == null);
    try std.testing.expect(try worker.cancel());
    var result = try awaitResult(&worker);
    defer result.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expectEqual(@as(?anyerror, error.SaveCancelled), result.failure);
    try f.disk("\xef\xbb\xbfbase\r\n");
}

test "Windows save commit worker cancelled vote retains prepared ownership and rejects copied busy owner" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.submit(&f.opened.grant, &prepared);
    try std.testing.expectError(error.SaveBusy, worker.deinit());
    var copy = worker;
    try std.testing.expectError(error.CopiedCommitWorker, copy.cancel());
    try std.testing.expectError(error.CopiedCommitWorker, copy.takeResult());
    try std.testing.expect(try worker.cancel());
    try std.testing.expectError(error.CommitAlreadyDecided, worker.approve(&f.opened.grant, &f.request));
    var result = try awaitResult(&worker);
    defer result.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expectEqual(@as(?anyerror, error.SaveCancelled), result.failure);
    try std.testing.expectEqual(@import("transaction.zig").Phase.prepared, result.prepared.attempt.transaction.phase);
    try f.disk("\xef\xbb\xbfbase\r\n");
}

test "Windows save commit worker native entry refuses wrong scope and scope counter never wraps" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var counter: std.atomic.Value(u64) = .init(std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, try reserveScope(&counter));
    try std.testing.expectError(error.CommitScopeExhausted, reserveScope(&counter));
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.submit(&f.opened.grant, &prepared);
    try awaitReady(&worker);
    const job = worker.job.?;
    try f.request.approveCommit(job.scope + 1, job.prepared.attempt.transaction.source_hash, &job.approval);
    job.vote.store(.approved, .release);
    job.signal.post(job.threaded.io());
    var result = try awaitResult(&worker);
    defer result.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expectEqual(@as(?anyerror, error.WrongApprovalScope), result.failure);
    try f.disk("\xef\xbb\xbfbase\r\n");
}

test "Windows save commit worker late cancellation cannot replace claimed native decision" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Held = struct {
        var entered: std.atomic.Value(bool) = .init(false);
        var release: std.atomic.Value(bool) = .init(false);
        fn commit(prepared: *preparation.Prepared, io: std.Io, scope: u64, approval: *editor.save_request.CommitApproval) !void {
            entered.store(true, .release);
            while (!release.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
            try Native.commit(prepared, io, scope, approval);
        }
    };
    Held.entered.store(false, .release);
    Held.release.store(false, .release);
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    // Release a paused worker before draining even when a negative assertion
    // fails, so no fixture or provider can be freed under the native call.
    defer Held.release.store(true, .release);
    try worker.submitWith(&f.opened.grant, &prepared, Held);
    try awaitReady(&worker);
    try worker.approve(&f.opened.grant, &f.request);
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
    while (!Held.entered.load(.acquire)) {
        if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline) return error.ClaimTimeout;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(!try worker.cancel());
    Held.release.store(true, .release);
    var result = try awaitResult(&worker);
    defer result.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expect(result.failure == null);
    try std.testing.expectEqual(@import("transaction.zig").Outcome.committed, try result.prepared.attempt.transaction.queryOutcome());
    try f.disk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save commit worker fences original name against a second equal-byte native file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other.txt", .data = "\xef\xbb\xbfbase\r\n" });
    var prepared = try f.prepared();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    var wrong_name = f.opened.grant;
    wrong_name.relative_path = @constCast("other.txt");
    try worker.submit(&wrong_name, &prepared);
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
    while (!worker.job.?.done.load(.acquire) and !try worker.needsApproval()) {
        if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline) return error.BindingTimeout;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    // If a broken native fence publishes readiness, finish the real handshake
    // and inspect its actual decision; do not count a parked worker as proof.
    if (try worker.needsApproval()) try worker.approve(&wrong_name, &f.request);
    var result = try awaitResult(&worker);
    defer result.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expectEqual(@as(?anyerror, error.IdentityChanged), result.failure);
    try f.disk("\xef\xbb\xbfbase\r\n");
}

test "Windows save commit worker lost reply retains actual committed transaction without ack" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const LostReply = struct {
        fn commit(prepared: *preparation.Prepared, io: std.Io, scope: u64, approval: *editor.save_request.CommitApproval) !void {
            try Native.commit(prepared, io, scope, approval);
            prepared.attempt.transaction.phase = .uncertain;
            return error.CommitUncertain;
        }
    };
    var f = try Fixture.init();
    defer f.deinit();
    var prepared = try f.prepared();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.submitWith(&f.opened.grant, &prepared, LostReply);
    try awaitReady(&worker);
    try worker.approve(&f.opened.grant, &f.request);
    var result = try awaitResult(&worker);
    defer result.prepared.close(std.testing.io) catch unreachable;
    try std.testing.expectEqual(@as(?anyerror, error.CommitUncertain), result.failure);
    try std.testing.expectEqual(@import("transaction.zig").Phase.uncertain, result.prepared.attempt.transaction.phase);
    try std.testing.expectEqual(@import("transaction.zig").Outcome.committed, try result.prepared.attempt.transaction.queryOutcome());
    try std.testing.expectEqual(@as(u64, 0), f.registry.get(f.opened.view).?.persistence.acknowledged);
    try f.disk("\xef\xbb\xbfXbase\r\n");
}
