//! 앱 owner와 detached worker 사이의 유한 결과 수명. UI는 tryLock으로 batch만 가져간다.
//! 실행 중 교체는 먼저 cancel하고 끝난 뒤 시작한다. 대기 query 한 개는 호출자 debounce 상태가 소유한다.
const std = @import("std");
const search = @import("maru").session.editor.search;
const scope_module = @import("scope.zig");
const process = @import("process.zig");
pub const model = @import("model.zig");
pub const Batch = struct {
    identity: search.request.Identity,
    status: search.request.Status,
    rows: std.ArrayList(search.request.Row),
    matches: usize,
    excluded: usize,
    pub fn deinit(self: *Batch, a: std.mem.Allocator) void {
        for (self.rows.items) |*row| row.match.deinit(a);
        self.rows.deinit(a);
    }
};
pub const Completion = struct {
    identity: search.request.Identity,
    status: search.request.Status,
    excluded: usize,
    failure: ?anyerror,
};
pub const Budget = struct { timing: process.Timing, snapshot_bytes: usize, preview_bytes: usize };
const Job = struct {
    a: std.mem.Allocator,
    io: std.Io,
    refs: std.atomic.Value(usize) = .init(2),
    mutex: std.atomic.Mutex = .unlocked,
    done: std.atomic.Value(bool) = .init(false),
    control: process.Control = .{},
    args: search.query.Args,
    root: []u8,
    query: []u8,
    opts: search.query.Options,
    state: search.request.State,
    models: std.ArrayList(model.Captured),
    budget: Budget,
    stats: process.Stats = .{},
    failure: ?anyerror = null,
    summary_seen: bool = false,
    disk_matches: usize = 0,
    fn lock(self: *@This()) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn release(self: *@This()) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.state.deinit(self.a);
        self.a.destroy(self);
    }
    fn finish(self: *@This(), status: search.request.Status) void {
        self.lock();
        defer self.mutex.unlock();
        self.state.finish(status);
    }
    fn accept(self: *@This(), source: search.request.Source, match: search.event.Match) !bool {
        if (self.control.cancelled.load(.acquire)) return error.Cancelled;
        self.lock();
        defer self.mutex.unlock();
        const accepted = try self.state.append(self.a, self.state.identity, source, match);
        if (!accepted and self.state.status == .partial) return error.ResultBudget;
        return accepted;
    }
    fn acceptDisk(self: *@This(), json: []const u8) !void {
        if (self.summary_seen) return error.EventAfterSummary;
        var event = try search.event.parse(self.a, json);
        if (event == .summary) {
            if (event.summary != self.disk_matches) return error.SummaryMismatch;
            self.summary_seen = true;
        }
        if (event == .match) {
            var transferred = false;
            defer if (!transferred) event.match.deinit(self.a);
            self.disk_matches = try std.math.add(usize, self.disk_matches, event.match.ranges.len);
            transferred = try self.accept(.disk, event.match);
        }
    }
    fn execute(self: *@This()) void {
        defer self.release();
        defer self.done.store(true, .release);
        defer {
            for (self.models.items) |*captured| captured.deinit(self.a);
            self.models.deinit(self.a);
            self.args.deinit(self.a);
            self.a.free(self.root);
            self.a.free(self.query);
        }
        var root = process.openRoot(self.a, self.io, self.root) catch |err| {
            self.failure = err;
            self.finish(.failed);
            return;
        };
        defer root.deinit(self.a, self.io);
        var scope = scope_module.Scope.fromArgs(self.a, self.args.items.items, self.opts.ignore_glob_case) catch |err| {
            self.failure = err;
            self.finish(.failed);
            return;
        };
        defer scope.deinit(self.a);
        for (self.models.items) |*captured| {
            const selected = scope.accepts(captured.path) catch |err| {
                self.failure = err;
                self.finish(.failed);
                return;
            };
            if (!selected) continue;
            model.run(self.a, captured, self.query, self.opts, &self.control, self.budget.snapshot_bytes, self.budget.preview_bytes, self, accept) catch |err| {
                if (err == error.Cancelled) {
                    self.finish(.cancelled);
                    return;
                }
                if (err == error.ResultBudget) return;
                self.lock();
                self.state.excluded += 1;
                self.mutex.unlock();
            };
        }
        const outcome = process.run(self.a, self.io, self.args.items.items, &root, &self.control, self.budget.timing, self.state.limits.event_bytes, self, acceptDisk, &self.stats) catch |err| {
            self.failure = err;
            self.finish(if (err == error.Cancelled) .cancelled else if (err == error.ResultBudget or err == error.EventTooLarge) .partial else .failed);
            return;
        };
        if (outcome == .complete and !self.summary_seen) {
            self.failure = error.IncompleteOutput;
            self.finish(.failed);
            return;
        }
        self.finish(switch (outcome) {
            .complete => if (self.state.excluded > 0) .partial else .complete,
            .cancelled => .cancelled,
            .partial => .partial,
        });
    }
};
pub const Backend = struct {
    a: std.mem.Allocator,
    io: std.Io,
    active: ?*Job = null,
    closed: bool = false,
    /// 제품 호출 경로는 고정 앱 번들 helper만 사용한다.
    pub fn startBundled(self: *Backend, root: []const u8, query: []const u8, opts: search.query.Options, state: *search.request.State, models: *std.ArrayList(model.Captured), budget: Budget) !void {
        const helper = try @import("helper.zig").locate(self.a, self.io);
        defer self.a.free(helper);
        return self.start(helper, root, query, opts, state, models, budget);
    }
    /// 성공 시 state와 models 소유권이 이동한다. 공유 allocator는 스레드 안전해야 한다.
    pub fn start(self: *Backend, helper: []const u8, root: []const u8, query: []const u8, opts: search.query.Options, state: *search.request.State, models: *std.ArrayList(model.Captured), budget: Budget) !void {
        if (self.closed) return error.Closed;
        if (self.active != null) return error.Busy;
        const job = try self.a.create(Job);
        errdefer self.a.destroy(job);
        var args = try search.query.build(self.a, helper, query, opts);
        errdefer args.deinit(self.a);
        const owned_root = try self.a.dupe(u8, root);
        errdefer self.a.free(owned_root);
        const owned_query = try self.a.dupe(u8, query);
        errdefer self.a.free(owned_query);
        // glob 문자열은 argv가 소유한다. 모델 matcher는 boolean 값만 읽는다.
        var owned_opts = opts;
        owned_opts.includes = &.{};
        owned_opts.excludes = &.{};
        job.* = .{ .a = self.a, .io = self.io, .args = args, .root = owned_root, .query = owned_query, .opts = owned_opts, .state = state.*, .models = models.*, .budget = budget };
        const thread = try std.Thread.spawn(.{}, Job.execute, .{job});
        thread.detach();
        models.* = .empty;
        state.* = .{ .identity = state.identity, .limits = state.limits };
        self.active = job;
    }
    pub fn cancel(self: *Backend) void {
        if (self.active) |job| job.control.cancelled.store(true, .release);
    }
    /// root·문서·IME·watcher 세대가 바뀌면 오래된 batch를 전달하지 않고 먼저 취소한다.
    pub fn take(self: *Backend, identity: search.request.Identity) ?Batch {
        const job = self.active orelse return null;
        if (!std.meta.eql(job.state.identity, identity)) {
            self.cancel();
            return null;
        }
        if (job.control.cancelled.load(.acquire) or !job.mutex.tryLock()) return null;
        defer job.mutex.unlock();
        const rows = job.state.rows;
        job.state.rows = .empty;
        return .{ .identity = identity, .status = job.state.status, .rows = rows, .matches = job.state.matches, .excluded = job.state.excluded };
    }
    pub fn done(self: *const Backend) bool {
        return if (self.active) |job| job.done.load(.acquire) else true;
    }
    /// terminal 정보는 행 queue와 무관하다. 취소한 owner도 수거 완료를 읽을 수 있다.
    pub fn completion(self: *const Backend) ?Completion {
        const job = self.active orelse return null;
        if (!job.done.load(.acquire)) return null;
        return .{ .identity = job.state.identity, .status = if (job.control.cancelled.load(.acquire)) .cancelled else job.state.status, .excluded = job.state.excluded, .failure = job.failure };
    }
    pub fn stats(self: *const Backend) ?process.Stats {
        const job = self.active orelse return null;
        if (!job.done.load(.acquire)) return null;
        return job.stats;
    }
    pub fn failure(self: *const Backend) ?anyerror {
        const job = self.active orelse return null;
        if (!job.done.load(.acquire)) return null;
        return job.failure;
    }
    /// done 이후 교체할 수 있다. 실행 중 owner 폐기는 deinit이 취소 후 worker에 해제를 맡긴다.
    pub fn reset(self: *Backend) bool {
        if (!self.done()) return false;
        if (self.active) |job| job.release();
        self.active = null;
        return true;
    }
    pub fn deinit(self: *Backend) void {
        self.closed = true;
        self.cancel();
        if (self.active) |job| job.release();
        self.active = null;
    }
};
