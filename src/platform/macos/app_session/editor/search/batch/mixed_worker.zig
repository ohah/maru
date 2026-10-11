//! actor의 문서 포인터를 빌리지 않고 모델 snapshot과 디스크 Read를 함께 준비한다.
const std = @import("std");
const maru = @import("maru");
const search = maru.session.editor.search;
const actor = @import("../batch.zig");
const disk = @import("disk.zig");
const process = @import("../process.zig");
const coordinator = @import("coordinator.zig");
pub const Model = struct { index: usize, source: search.request.Source, snapshot: maru.session.editor.buffer.Snapshot };
pub const Disk = struct { index: usize, target: disk.Target };
pub const Ready = struct {
    specification: search.batch.Specification,
    prepared: search.batch_plan.Prepared,
    ticket: actor.Ticket,
    closed: []coordinator.Closed,
    pub fn deinit(self: *Ready, a: std.mem.Allocator) void {
        self.prepared.deinit(a);
        self.specification.deinit(a);
        freeClosed(a, self.closed);
        self.* = undefined;
    }
};
fn freeClosed(a: std.mem.Allocator, items: []coordinator.Closed) void {
    for (items) |item| {
        a.free(item.target.root);
        a.free(item.target.path);
        a.free(item.file.bytes);
    }
    a.free(items);
}
var workers = std.atomic.Value(usize).init(0);
pub fn outstandingWorkers() usize {
    return workers.load(.acquire);
}
/// 판정자의 allocator 결산 전에 worker의 마지막 참조 해제까지 끝낸다. 제품 창 닫기는 기다리지 않는다.
pub fn quietForTest(io: std.Io) void {
    const wait = @import("../../../../detached_worker_wait.zig");
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + wait.timeout_ns;
    while (outstandingWorkers() != 0) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return;
        std.Thread.yield() catch {};
    }
}
pub const Job = struct {
    a: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    control: process.Control = .{},
    specification: ?search.batch.Specification,
    models: []Model,
    disks: []Disk,
    occupied: []maru.session.file_tree.Identity,
    ticket: actor.Ticket,
    total_limit: usize,
    file_limit: usize,
    prepared: ?search.batch_plan.Prepared = null,
    closed: ?[]coordinator.Closed = null,
    failure: ?anyerror = null,

    /// 성공할 때만 specification/models를 인계한다. disk 경로와 occupied는 독립 사본을 만든다.
    pub fn start(a: std.mem.Allocator, spec: *search.batch.Specification, models: []Model, disks: []const Disk, occupied: []const maru.session.file_tree.Identity, ticket: actor.Ticket, total_limit: usize, file_limit: usize) !*Job {
        if (!std.meta.eql(spec.identity, ticket.identity) or models.len + disks.len != spec.targets.items.len) return error.StaleTargets;
        const seen = try a.alloc(bool, spec.targets.items.len);
        defer a.free(seen);
        @memset(seen, false);
        var bytes: usize = 0;
        for (models) |model| {
            if (model.index >= seen.len or seen[model.index] or model.source != .model or model.source.model.composition != 0 or !std.meta.eql(spec.targets.items[model.index].source, model.source)) return error.StaleTargets;
            seen[model.index] = true;
            if (model.snapshot.byteLen() > file_limit or model.snapshot.byteLen() > total_limit -| bytes) return error.TooLarge;
            bytes += model.snapshot.byteLen();
        }
        for (disks) |item| {
            if (item.index >= seen.len or seen[item.index] or spec.targets.items[item.index].source != .disk) return error.StaleTargets;
            seen[item.index] = true;
            _ = try search.request.relativePath(item.target.path);
            const absolute = try std.fs.path.resolve(a, &.{ item.target.root, item.target.path });
            defer a.free(absolute);
            if (!std.fs.path.isAbsolute(item.target.root) or !std.mem.eql(u8, absolute, spec.targets.items[item.index].absolute)) return error.StaleTargets;
        }
        const copied = try a.alloc(Disk, disks.len);
        var count: usize = 0;
        errdefer {
            for (copied[0..count]) |item| {
                a.free(item.target.root);
                a.free(item.target.path);
            }
            a.free(copied);
        }
        for (disks, copied) |item, *out| {
            const root = try a.dupe(u8, item.target.root);
            errdefer a.free(root);
            const path = try a.dupe(u8, item.target.path);
            out.* = item;
            out.target.root = root;
            out.target.path = path;
            count += 1;
        }
        const occupied_copy = try a.dupe(maru.session.file_tree.Identity, occupied);
        errdefer a.free(occupied_copy);
        const job = try a.create(Job);
        errdefer a.destroy(job);
        job.* = .{ .a = a, .specification = spec.*, .models = models, .disks = copied, .occupied = occupied_copy, .ticket = ticket, .total_limit = total_limit, .file_limit = file_limit };
        _ = workers.fetchAdd(1, .acq_rel);
        const thread = std.Thread.spawn(.{}, execute, .{job}) catch |err| {
            _ = workers.fetchSub(1, .acq_rel);
            return err;
        };
        thread.detach();
        spec.* = undefined;
        return job;
    }
    pub fn cancel(self: *Job) void {
        self.control.cancelled.store(true, .release);
    }
    pub fn take(self: *Job) !?Ready {
        if (!self.done.load(.acquire)) return null;
        if (self.control.cancelled.load(.acquire)) return error.Cancelled;
        if (self.failure) |err| return err;
        if (self.specification == null or self.prepared == null or self.closed == null) return error.AlreadyTaken;
        const ready: Ready = .{ .specification = self.specification.?, .prepared = self.prepared.?, .ticket = self.ticket, .closed = self.closed.? };
        self.specification = null;
        self.prepared = null;
        self.closed = null;
        return ready;
    }
    pub fn deinit(self: *Job) void {
        self.cancel();
        self.release();
    }
    fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.prepared) |*ready| ready.deinit(self.a);
        if (self.specification) |*spec| spec.deinit(self.a);
        if (self.closed) |items| freeClosed(self.a, items);
        self.a.destroy(self);
    }
    fn execute(self: *Job) void {
        defer _ = workers.fetchSub(1, .acq_rel);
        defer self.release();
        self.prepare() catch |err| {
            self.failure = err;
        };
        for (self.models) |*model| model.snapshot.deinit();
        self.a.free(self.models);
        for (self.disks) |item| {
            self.a.free(item.target.root);
            self.a.free(item.target.path);
        }
        self.a.free(self.disks);
        self.a.free(self.occupied);
        self.done.store(true, .release);
    }
    fn prepare(self: *Job) !void {
        if (self.control.cancelled.load(.acquire)) return error.Cancelled;
        var io = std.Io.Threaded.init(self.a, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
        defer io.deinit();
        const targets = try self.a.alloc(disk.Target, self.disks.len);
        defer self.a.free(targets);
        var model_bytes: usize = 0;
        for (self.models) |model| model_bytes += model.snapshot.byteLen();
        for (self.disks, targets) |item, *target| target.* = item.target;
        var reads = try disk.Prepared.prepare(self.a, io.io(), targets, self.occupied, &self.control, self.total_limit - model_bytes, self.file_limit);
        defer reads.deinit(self.a);
        const bodies = try self.a.alloc(search.batch_plan.Body, self.specification.?.targets.items.len);
        defer self.a.free(bodies);
        var copied: std.ArrayList([]u8) = .empty;
        defer {
            for (copied.items) |text| self.a.free(text);
            copied.deinit(self.a);
        }
        try copied.ensureTotalCapacity(self.a, self.models.len);
        for (self.models) |model| {
            if (self.control.cancelled.load(.acquire)) return error.Cancelled;
            const text = try model.snapshot.copyRange(self.a, 0, model.snapshot.byteLen());
            copied.appendAssumeCapacity(text);
            bodies[model.index] = .{ .absolute = self.specification.?.targets.items[model.index].absolute, .source = model.source, .text = text };
        }
        for (self.disks, reads.files.items) |item, file| bodies[item.index] = .{ .absolute = self.specification.?.targets.items[item.index].absolute, .source = .disk, .text = file.bytes };
        self.prepared = try search.batch_plan.Prepared.prepare(self.a, &self.specification.?, bodies, self.total_limit, self.file_limit, &self.control.cancelled);
        // 전문 재검증까지 성공해야 Read를 actor로 인계한다. 마지막 실패도 전체 결과를 숨긴다.
        try reads.validate(self.a, io.io(), targets, &self.control, self.file_limit);
        const closed = try self.a.alloc(coordinator.Closed, self.disks.len);
        var count: usize = 0;
        errdefer {
            for (closed[0..count]) |item| {
                self.a.free(item.target.root);
                self.a.free(item.target.path);
            }
            self.a.free(closed);
        }
        for (self.disks, reads.files.items, closed) |item, file, *out| {
            const root = try self.a.dupe(u8, item.target.root);
            errdefer self.a.free(root);
            const path = try self.a.dupe(u8, item.target.path);
            out.* = .{ .index = item.index, .target = item.target, .file = file };
            out.target.root = root;
            out.target.path = path;
            count += 1;
        }
        // 배열을 채우는 동안 Read bytes는 reads가 소유한다. 성공한 뒤 한 번만 인계한다.
        reads.files.clearRetainingCapacity();
        self.closed = closed;
    }
};
