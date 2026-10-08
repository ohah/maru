//! 앱 owner와 detached worker 사이의 유한 결과 수명. UI는 tryLock으로 batch만 가져간다.
//! 실행 중 교체는 먼저 cancel하고 끝난 뒤 시작한다. 대기 query 한 개는 호출자 debounce 상태가 소유한다.
const std = @import("std");
const search = @import("maru").session.editor.search;
const scope_module = @import("scope.zig");
const process = @import("process.zig");
pub const coordinator = @import("coordinator.zig");
pub const model = @import("model.zig");
pub const path = @import("path.zig");
// 창 owner를 놓은 뒤에도 마지막 앱 종료는 worker의 최종 참조 해제를 관측한다.
var workers = std.atomic.Value(usize).init(0);
pub fn outstandingWorkers() usize {
    return workers.load(.acquire);
}
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
pub const Budget = struct { timing: process.Timing, snapshot_bytes: usize, preview_bytes: usize, expected_root: ?@import("maru").session.file_tree.Identity = null, selection_bytes: usize = 0 };
const Job = struct {
    a: std.mem.Allocator,
    io: std.Io,
    refs: std.atomic.Value(usize) = .init(2),
    mutex: std.atomic.Mutex = .unlocked,
    done: std.atomic.Value(bool) = .init(false),
    control: process.Control = .{},
    args: search.query.Args,
    environment: std.process.Environ.Map,
    root: []u8,
    query: []u8,
    opts: search.query.Options,
    state: search.request.State,
    models: std.ArrayList(model.Captured),
    budget: Budget,
    stats: process.Stats = .{},
    failure: ?anyerror = null,
    summary_seen: bool = false,
    roots: ?[]coordinator.Input = null,
    root_index: usize = 0,
    selected: ?*const std.StringHashMapUnmanaged(usize) = null,
    logical_root: []const u8 = "",
    batch_paths: ?[]const []const u8 = null,
    disk_matches: usize = 0,
    fn lock(self: *@This()) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn release(self: *@This()) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.state.deinit(self.a);
        self.a.destroy(self);
    }
    pub fn finish(self: *@This(), status: search.request.Status) void {
        self.lock();
        defer self.mutex.unlock();
        self.state.finish(status);
    }
    pub fn accept(self: *@This(), source: search.request.Source, match: search.event.Match) !bool {
        if (self.control.cancelled.load(.acquire)) return error.Cancelled;
        self.lock();
        defer self.mutex.unlock();
        const accepted = if (self.roots != null) try self.state.appendSelected(self.a, self.state.identity, source, match) else try self.state.append(self.a, self.state.identity, source, match);
        if (accepted) self.state.rows.items[self.state.rows.items.len - 1].root_index = self.root_index;
        if (!accepted and self.state.status == .partial) return error.ResultBudget;
        return accepted;
    }
    pub fn exclude(self: *@This()) void {
        self.lock();
        defer self.mutex.unlock();
        self.state.excluded += 1;
    }
    pub fn acceptDisk(self: *@This(), json: []const u8) !void {
        if (self.summary_seen) return error.EventAfterSummary;
        var event = try search.event.parse(self.a, json);
        if (event == .summary) {
            if (event.summary != self.disk_matches) return error.SummaryMismatch;
            self.summary_seen = true;
        }
        if (event == .match) {
            var transferred = false;
            defer if (!transferred) event.match.deinit(self.a);
            if (self.selected) |selected| {
                const name = try search.request.relativePath(event.match.path);
                if (self.batch_paths) |paths| {
                    var in_batch = false;
                    for (paths) |candidate| if (std.mem.eql(u8, name, candidate)) {
                        in_batch = true;
                        break;
                    };
                    if (!in_batch) return error.UnselectedPath;
                }

                const full = try std.fmt.allocPrint(self.a, "{s}{s}{s}", .{ self.logical_root, if (self.logical_root.len == 0) "" else "/", name });
                defer self.a.free(full);
                const owner = selected.get(full) orelse return error.UnselectedPath;
                if (owner != self.root_index) return error.UnselectedPath;
            }

            self.disk_matches = try std.math.add(usize, self.disk_matches, event.match.ranges.len);
            transferred = try self.accept(.disk, event.match);
        }
    }
    fn execute(self: *@This()) void {
        defer {
            self.release();
            _ = workers.fetchSub(1, .acq_rel);
        }
        defer self.done.store(true, .release);
        // 앱의 global_single_threaded I/O는 프로세스 실행용 allocator가 없다.
        // worker가 실행 I/O를 소유하고 최종 완료 게시 전에 정리한다.
        var threaded = std.Io.Threaded.init(self.a, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
        defer threaded.deinit();
        self.io = threaded.io();
        defer {
            for (self.models.items) |*captured| captured.deinit(self.a);
            self.models.deinit(self.a);
            self.args.deinit(self.a);
            self.environment.deinit();
            self.a.free(self.root);
            self.a.free(self.query);
            if (self.roots) |roots| coordinator.freeInputs(self.a, roots);
        }
        if (self.roots != null) {
            coordinator.execute(self) catch |err| {
                if (err != error.Cancelled and err != error.ResultBudget and err != error.SelectionBudget and err != error.ExecutionBudget) self.failure = err;
                self.finish(if (err == error.Cancelled) .cancelled else if (err == error.ResultBudget or err == error.SelectionBudget or err == error.EventTooLarge or err == error.ExecutionBudget) .partial else .failed);
            };
            return;
        }
        var root = process.openRoot(self.a, self.io, self.root) catch |err| {
            self.failure = err;
            self.finish(.failed);
            return;
        };
        defer root.deinit(self.a, self.io);
        if (self.budget.expected_root) |expected| {
            const device: std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(root.device))) = @bitCast(root.device);
            if (root.stat.inode != expected.inode or @as(u64, device) != expected.device or expected.kind != 2) {
                self.failure = error.RootChanged;
                self.finish(.failed);
                return;
            }
        }
        // root 검증 후 worker에서만 이름을 해소한다. 점유와 glob을 디스크의 논리 경로 표기에 맞춘다.
        path.prepare(self.a, root.canonical, &self.state, &self.models, &self.control) catch |err| {
            if (err == error.Cancelled) {
                self.finish(.cancelled);
            } else {
                self.failure = err;
                self.finish(.failed);
            }
            return;
        };
        process.validateRoot(self.io, &root) catch |err| {
            self.failure = err;
            self.finish(.failed);
            return;
        };
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
        const outcome = process.run(self.a, self.io, self.args.items.items, &self.environment, &root, &self.control, self.budget.timing, self.state.limits.event_bytes, self, acceptDisk, &self.stats) catch |err| {
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
        // 닫힌 요청과 재사용 대기는 번들 조회·할당보다 먼저 같은 상태 오류를 반환한다.
        if (self.closed) return error.Closed;
        if (self.active != null) return error.Busy;
        const helper = try @import("helper.zig").locate(self.a, self.io);
        defer self.a.free(helper);
        return self.start(helper, root, query, opts, state, models, budget);
    }
    /// 성공 시 state와 models 소유권이 이동한다. 공유 allocator는 스레드 안전해야 한다.
    pub fn start(self: *Backend, helper: []const u8, root: []const u8, query: []const u8, opts: search.query.Options, state: *search.request.State, models: *std.ArrayList(model.Captured), budget: Budget) !void {
        return self.startInternal(helper, root, query, opts, state, models, budget, null);
    }
    /// 요청 전체가 한 worker와 결과 예산을 소유한다. root 사본은 성공 전까지 caller 소유다.
    pub fn startRoots(self: *Backend, helper: []const u8, roots: []const coordinator.Input, query: []const u8, opts: search.query.Options, state: *search.request.State, models: *std.ArrayList(model.Captured), budget: Budget) !void {
        if (self.closed) return error.Closed;
        if (self.active != null) return error.Busy;
        if (budget.timing.execution_ms <= 0 or budget.timing.reap_ms <= 0) return error.InvalidTiming;
        if (roots.len == 0 or budget.selection_bytes == 0) return error.InvalidSelectionBudget;
        return self.startInternal(helper, "/", query, opts, state, models, budget, roots);
    }
    pub fn startBundledRoots(self: *Backend, roots: []const coordinator.Input, query: []const u8, opts: search.query.Options, state: *search.request.State, models: *std.ArrayList(model.Captured), budget: Budget) !void {
        if (self.closed) return error.Closed;
        if (self.active != null) return error.Busy;
        const helper = try @import("helper.zig").locate(self.a, self.io);
        defer self.a.free(helper);
        return self.startRoots(helper, roots, query, opts, state, models, budget);
    }
    fn startInternal(self: *Backend, helper: []const u8, root: []const u8, query: []const u8, opts: search.query.Options, state: *search.request.State, models: *std.ArrayList(model.Captured), budget: Budget, inputs: ?[]const coordinator.Input) !void {
        if (self.closed) return error.Closed;
        if (self.active != null) return error.Busy;
        const roots = if (inputs) |items| try coordinator.copyInputs(self.a, items) else null;
        errdefer if (roots) |items| coordinator.freeInputs(self.a, items);
        const job = try self.a.create(Job);
        errdefer self.a.destroy(job);
        var args = try search.query.build(self.a, helper, query, opts);
        errdefer args.deinit(self.a);
        const owned_root = try self.a.dupe(u8, root);
        errdefer self.a.free(owned_root);
        const owned_query = try self.a.dupe(u8, query);
        errdefer self.a.free(owned_query);
        // main actor에서 환경을 소유한 사본으로 잡는다. worker가 getenv 포인터를 오래 빌리지 않는다.
        const inherited: std.process.Environ = .{ .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) } };
        var environment = try inherited.createMap(self.a);
        errdefer environment.deinit();
        // glob 문자열은 argv가 소유한다. 모델 matcher는 boolean 값만 읽는다.
        var owned_opts = opts;
        owned_opts.includes = &.{};
        owned_opts.excludes = &.{};
        job.* = .{ .a = self.a, .io = self.io, .args = args, .environment = environment, .root = owned_root, .query = owned_query, .opts = owned_opts, .state = state.*, .models = models.*, .budget = budget, .roots = roots };
        _ = workers.fetchAdd(1, .acq_rel);
        const thread = std.Thread.spawn(.{}, Job.execute, .{job}) catch |err| {
            _ = workers.fetchSub(1, .acq_rel);
            return err;
        };
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
