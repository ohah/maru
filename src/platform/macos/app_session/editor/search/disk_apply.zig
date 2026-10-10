//! 디스크 적용의 재검증은 worker에서 끝낸다. 취소 후에도 worker가 자기 경로 사본을 소유한다.
const std = @import("std");
const maru = @import("maru");
const verify = @import("verify.zig");
const process = @import("process.zig");
pub const Target = struct {
    root: []u8,
    path: []u8,
    absolute: []u8,
    identity: maru.session.file_tree.Identity,
    hash: ?[32]u8 = null,
    pub fn init(a: std.mem.Allocator, root: []const u8, path: []const u8, identity: maru.session.file_tree.Identity) !Target {
        const r = try a.dupe(u8, root);
        errdefer a.free(r);
        const p = try a.dupe(u8, path);
        errdefer a.free(p);
        return .{ .root = r, .path = p, .absolute = try std.fs.path.resolve(a, &.{ root, path }), .identity = identity };
    }
    pub fn deinit(self: *Target, a: std.mem.Allocator) void {
        a.free(self.root);
        a.free(self.path);
        a.free(self.absolute);
    }
};
var workers = std.atomic.Value(usize).init(0);
pub fn outstandingWorkers() usize {
    return workers.load(.acquire);
}
pub const Check = struct {
    a: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    control: process.Control = .{},
    target: Target,
    max_bytes: usize,
    failure: ?anyerror = null,
    pub fn start(a: std.mem.Allocator, target: Target, max_bytes: usize) !*Check {
        const job = try a.create(Check);
        errdefer a.destroy(job);
        var copy = try Target.init(a, target.root, target.path, target.identity);
        copy.hash = target.hash;
        errdefer copy.deinit(a);
        job.* = .{ .a = a, .target = copy, .max_bytes = max_bytes };
        _ = workers.fetchAdd(1, .acq_rel);
        const thread = std.Thread.spawn(.{}, execute, .{job}) catch |err| {
            _ = workers.fetchSub(1, .acq_rel);
            return err;
        };
        thread.detach();
        return job;
    }
    fn release(self: *Check) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.target.deinit(self.a);
            self.a.destroy(self);
        }
    }
    pub fn deinit(self: *Check) void {
        self.control.cancelled.store(true, .release);
        self.release();
    }
    fn execute(self: *Check) void {
        defer _ = workers.fetchSub(1, .acq_rel);
        defer self.release();
        defer self.done.store(true, .release);
        var threaded = std.Io.Threaded.init(self.a, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
        defer threaded.deinit();
        const hash = verify.disk(self.a, threaded.io(), self.target.root, self.target.path, &self.control, self.max_bytes, self.target.identity) catch |err| {
            self.failure = err;
            return;
        };
        if (self.target.hash == null or !std.mem.eql(u8, &hash, &self.target.hash.?)) self.failure = error.FileChanged;
    }
};

/// 취소 뒤 worker의 마지막 해제까지 테스트 allocator 결산을 미룬다. 제품 종료는 기다리지 않는다.
pub fn quietForTest(io: std.Io) void {
    const timeout = @import("../../../detached_worker_wait.zig").timeout_ns;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + timeout;
    while (outstandingWorkers() != 0) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return;
        std.Thread.yield() catch {};
    }
}
