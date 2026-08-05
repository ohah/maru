//! Detached CoreText worker for Session Dock rich text.
//!
//! This boundary owns an immutable request/result queue only.  It deliberately cannot import
//! AppSession, Metal, RenderFrame, or FontIdentityRegistry: CoreText creates scalar glyph facts
//! off the render tick and the main actor performs the small registry conversion after polling.

const std = @import("std");
const system_text = @import("system_text.zig");

pub const Result = struct {
    fingerprint: u64,
    /// 이 artifact의 placement가 구워진 **submit 시점** 스크롤 원점. host가 캐시를 다른 스크롤 위치에서
    /// 재사용할 때 이 값을 기준으로 평행이동한다. poll 시점 원점을 대신 쓰면, worker가 도는 동안 사용자가
    /// 스크롤한 만큼(관성 스크롤이면 수십 px) 모든 글자가 어긋난 채 고정된다 — 그 오차는 다음 프레임에도
    /// 사라지지 않는다(delta는 항상 이 잘못된 기준에서 재계산되므로).
    scroll_origin_y_px: i32,
    artifact: system_text.UnresolvedArtifact,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.artifact.deinit(allocator);
        self.* = undefined;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    refs: std.atomic.Value(usize) = .init(1),
    result: ?Result = null,
    inflight: bool = false,
    shutting_down: bool = false,
    // This narrow test seam proves the render-side submit/poll contract without making normal
    // product shaping wait.  It is never armed by configuration or the archive scanner.
    test_gate_enabled: std.atomic.Value(bool) = .init(false),
    test_gate_reached: std.atomic.Value(bool) = .init(false),
    test_gate_released: std.atomic.Value(bool) = .init(true),

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(!self.inflight);
        if (self.result) |*result| result.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const Job = struct {
    state: *State,
    request: system_text.Request,
    scale_milli: u32,
    scroll_origin_y_px: i32,
};

pub const Backend = struct {
    state: ?*State,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Backend {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .io = io };
        return .{ .state = state };
    }

    /// Caller retains `request` on false; the detached worker owns it on true.  One in-flight
    /// request and one completed-but-unpolled DTO are the entire bounded queue: do not start a
    /// redundant second shape between worker completion and the next main-actor poll.
    pub fn submit(self: *Backend, request: system_text.Request, scale_milli: u32, scroll_origin_y_px: i32) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.inflight or state.result != null) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.inflight = true;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);
        const job = state.allocator.create(Job) catch {
            finishWithoutResult(state);
            return false;
        };
        job.* = .{ .state = state, .request = request, .scale_milli = scale_milli, .scroll_origin_y_px = scroll_origin_y_px };
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            state.allocator.destroy(job);
            finishWithoutResult(state);
            return false;
        };
        thread.detach();
        return true;
    }

    pub fn takeResult(self: *Backend) ?Result {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        const result = state.result orelse return null;
        state.result = null;
        return result;
    }

    pub fn isInflight(self: *const Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        return state.inflight;
    }

    /// A result may arrive between two render ticks.  The host uses this to request one more
    /// frame so a completed scalar DTO is actually polled and connected to the atlas.
    pub fn needsPoll(self: *const Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        return state.inflight or state.result != null;
    }

    pub fn setTestGate(self: *Backend, blocked: bool) void {
        const state = self.state orelse return;
        state.test_gate_reached.store(false, .release);
        state.test_gate_released.store(!blocked, .release);
        state.test_gate_enabled.store(blocked, .release);
    }

    pub fn testGateReached(self: *const Backend) bool {
        const state = self.state orelse return false;
        return state.test_gate_reached.load(.acquire);
    }

    pub fn deinit(self: *Backend) void {
        const state = self.state orelse return;
        self.state = null;
        state.mutex.lockUncancelable(state.io);
        state.shutting_down = true;
        if (state.result) |*result| result.deinit(state.allocator);
        state.result = null;
        state.mutex.unlock(state.io);
        state.release();
    }
};

fn finishWithoutResult(state: *State) void {
    state.mutex.lockUncancelable(state.io);
    state.inflight = false;
    state.mutex.unlock(state.io);
    state.release();
}

fn worker(job: *Job) void {
    const state = job.state;
    waitForTestGate(state);
    const artifact = system_text.shapeRequest(state.allocator, &job.request, job.scale_milli) catch {
        job.request.deinit(state.allocator);
        state.allocator.destroy(job);
        finishWithoutResult(state);
        return;
    };
    var result = Result{
        .fingerprint = job.request.fingerprint,
        .scroll_origin_y_px = job.scroll_origin_y_px,
        .artifact = artifact,
    };
    job.request.deinit(state.allocator);
    state.allocator.destroy(job);

    state.mutex.lockUncancelable(state.io);
    if (state.shutting_down) {
        state.mutex.unlock(state.io);
        result.deinit(state.allocator);
    } else {
        if (state.result) |*old| old.deinit(state.allocator);
        state.result = result;
        state.mutex.unlock(state.io);
    }
    state.mutex.lockUncancelable(state.io);
    state.inflight = false;
    state.mutex.unlock(state.io);
    state.release();
}

fn waitForTestGate(state: *State) void {
    if (!state.test_gate_enabled.load(.acquire)) return;
    state.test_gate_reached.store(true, .release);
    while (!state.test_gate_released.load(.acquire)) {
        state.mutex.lockUncancelable(state.io);
        const shutting_down = state.shutting_down;
        state.mutex.unlock(state.io);
        if (shutting_down) break;
        std.Io.sleep(state.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    state.test_gate_reached.store(false, .release);
}

test "text shaping worker publishes only after a detached gate releases" {
    var backend = try Backend.init(std.testing.allocator, std.testing.io);
    defer backend.deinit();
    backend.setTestGate(true);
    var request = system_text.Request{ .fingerprint = 77, .runs = try std.testing.allocator.alloc(system_text.Request.Run, 0) };
    try std.testing.expect(backend.submit(request, 1000, 0));
    request = undefined; // worker owns the request after successful submit.
    var attempts: usize = 0;
    while (!backend.testGateReached() and attempts < 1000) : (attempts += 1) {
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(backend.testGateReached());
    try std.testing.expect(backend.isInflight());
    try std.testing.expect(backend.takeResult() == null);
    backend.setTestGate(false);
    attempts = 0;
    while (attempts < 1000) : (attempts += 1) {
        if (backend.takeResult()) |result| {
            var owned = result;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(u64, 77), owned.fingerprint);
            return;
        }
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    return error.TestExpectedResult;
}

// 코드리뷰 회귀: host가 결과를 poll하는 시점의 스크롤 원점을 artifact의 기준으로 저장했다. artifact의
// placement는 **submit 시점** 좌표로 구워지므로, worker가 도는 동안 사용자가 스크롤하면 그 차이만큼 모든
// 글자가 어긋난 채 고정된다(이후 delta가 계속 잘못된 기준에서 계산되므로 다음 프레임에도 안 없어진다).
// 그래서 기준은 결과 자신이 실어 와야 한다 — poll 시점에는 그 값을 복원할 방법이 없다.
test "shaping result carries the scroll origin it was shaped at" {
    var backend = try Backend.init(std.testing.allocator, std.testing.io);
    defer backend.deinit();
    var request = system_text.Request{ .fingerprint = 91, .runs = try std.testing.allocator.alloc(system_text.Request.Run, 0) };
    try std.testing.expect(backend.submit(request, 1000, -137));
    request = undefined; // worker owns the request after successful submit.
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        if (backend.takeResult()) |result| {
            var owned = result;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(u64, 91), owned.fingerprint);
            try std.testing.expectEqual(@as(i32, -137), owned.scroll_origin_y_px);
            return;
        }
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    return error.TestExpectedResult;
}

test "queued completion prevents a redundant second shaping request" {
    var backend = try Backend.init(std.testing.allocator, std.testing.io);
    defer backend.deinit();
    var first = system_text.Request{ .fingerprint = 11, .runs = try std.testing.allocator.alloc(system_text.Request.Run, 0) };
    try std.testing.expect(backend.submit(first, 1000, 0));
    first = undefined; // worker owns the request after successful submit.
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        if (backend.needsPoll() and !backend.isInflight()) break;
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(!backend.isInflight());
    var second = system_text.Request{ .fingerprint = 12, .runs = try std.testing.allocator.alloc(system_text.Request.Run, 0) };
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!backend.submit(second, 1000, 0));
    var result = backend.takeResult() orelse return error.TestExpectedResult;
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 11), result.fingerprint);
}
