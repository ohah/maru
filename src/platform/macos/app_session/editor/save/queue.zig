//! 한 actor의 저장 요청을 순서대로 실행한다. UI·문서 수명 판정은 호출자가 담당한다.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const ops = maru.session.editor.save_ops;
const local = @import("../local_save.zig");
const editor = @import("../mod.zig");
const worker = @import("worker.zig");
const host = @import("../../../app_session.zig");
pub const Limits = struct { requests: usize, bytes: usize };
pub const Admission = struct { id: u64, joined: bool };
const Request = struct {
    id: u64,
    epoch: u64,
    prepared: local.Prepared,
    fn target(self: *const Request) ops.Target {
        return targetOf(&self.prepared, self.epoch);
    }
};
// worker가 소유한 불변 bytes/path만 빌린다. worker의 written/finished는 읽지 않는다.
const Running = struct { id: u64, target: ops.Target, raw: []const u8, before: ?u64, cost: usize };
pub const Outcome = struct { id: u64, epoch: u64, prepared: local.Prepared, failure: ?anyerror, applied: bool = false };
pub fn targetOf(prepared: *const local.Prepared, epoch: u64) ops.Target {
    return .{ .token = .{ .document = prepared.document, .identity = prepared.identity, .path = prepared.path }, .epoch = epoch };
}
pub const Queue = struct {
    a: std.mem.Allocator,
    limits: Limits,
    service: worker.Service,
    waiting: std.ArrayList(Request) = .empty,
    running: ?Running = null,
    outcome: ?Outcome = null,
    charged_bytes: usize = 0,
    next_id: u64 = 1,
    pub fn init(a: std.mem.Allocator, limits: Limits) Queue {
        return .{ .a = a, .limits = limits, .service = worker.Service.init(a) };
    }
    /// 사용자 저장은 임의의 큐 상한 대신 동적 배열을 쓴다. 파일별 저장 한도는 Prepared가 검사한다.
    /// 할당 실패와 산술 범위 초과는 enqueue의 실패로 남으며 caller 자료를 소비하지 않는다.
    pub fn initDynamic(a: std.mem.Allocator) Queue {
        return init(a, .{ .requests = std.math.maxInt(usize), .bytes = std.math.maxInt(usize) });
    }
    pub fn requestCount(self: *const Queue) usize {
        return self.waiting.items.len + @intFromBool(self.running != null);
    }
    fn duplicate(self: *const Queue, prepared: *const local.Prepared, epoch: u64) ?u64 {
        const target = targetOf(prepared, epoch);
        var i = self.waiting.items.len;
        while (i > 0) {
            i -= 1;
            const entry = &self.waiting.items[i];
            if (ops.sameDocument(target.token, entry.target().token)) {
                // A→B→A는 마지막 A를 첫 A에 합치면 안 된다. 같은 대상의 가장 최근 요청만 본다.
                return if (ops.sameRequest(target, prepared.bytes, prepared.expected_disk, entry.target(), entry.prepared.bytes, entry.prepared.expected_disk)) entry.id else null;
            }
        }
        if (self.running) |running| if (ops.sameRequest(target, prepared.bytes, prepared.expected_disk, running.target, running.raw, running.before)) return running.id;
        return null;
    }
    /// 성공(합류 포함) 때만 자료를 소비한다. 한도/OOM/ID 실패에서는 caller가 그대로 소유한다.
    /// 자료는 이 큐와 같은 allocator로 준비한다. 한도 값은 상위 actor가 정하며 제품 기본값은 없다.
    pub fn enqueue(self: *Queue, prepared: *local.Prepared, epoch: u64) !Admission {
        if (!ops.writable(prepared.written, prepared.finished)) return error.InvalidPhase;
        if (prepared.identity == null) return error.MissingIdentity;
        if (prepared.expected_disk == null) return error.MissingBaseline;
        if (self.duplicate(prepared, epoch)) |id| {
            prepared.deinit(self.a);
            return .{ .id = id, .joined = true };
        }
        const cost = std.math.add(usize, prepared.bytes.len, prepared.path.len) catch return error.TooLarge;
        if (self.requestCount() >= self.limits.requests) return error.QueueFull;
        if (cost > self.limits.bytes -| self.charged_bytes) return error.TooLarge;
        if (self.next_id == std.math.maxInt(u64)) return error.IdExhausted;
        try self.waiting.ensureUnusedCapacity(self.a, 1);
        const id = self.next_id;
        self.waiting.appendAssumeCapacity(.{ .id = id, .epoch = epoch, .prepared = prepared.* });
        prepared.* = undefined;
        self.next_id += 1;
        self.charged_bytes += cost;
        return .{ .id = id, .joined = false };
    }
    pub fn nextTarget(self: *const Queue) ?ops.Target {
        if (self.waiting.items.len == 0) return null;
        return self.waiting.items[0].target();
    }
    fn descriptor(entry: *const Request) Running {
        return .{ .id = entry.id, .target = entry.target(), .raw = entry.prepared.bytes, .before = entry.prepared.expected_disk, .cost = entry.prepared.bytes.len + entry.prepared.path.len };
    }
    /// actor가 현재의 살아 있는 대상/epoch를 구해 넘긴다. 신원 없는 경로만으로 쓰기를 시작하지 않는다.
    pub fn startNext(self: *Queue, live: ops.Target) !void {
        try self.startImpl(live, if (builtin.is_test) null else {});
    }
    fn startImpl(self: *Queue, live: ops.Target, gate: if (builtin.is_test) ?*worker.TestGate else void) !void {
        if (self.running != null) return error.Busy;
        if (self.waiting.items.len == 0) return error.Empty;
        const first = &self.waiting.items[0];
        if (!first.target().matches(live)) return error.StaleTarget;
        const running = descriptor(first);
        if (builtin.is_test) {
            if (gate) |g| try self.service.startBlockedForTest(&first.prepared, g) else try self.service.start(&first.prepared);
        } else try self.service.start(&first.prepared);
        _ = self.waiting.orderedRemove(0);
        self.running = running;
    }
    pub fn startBlockedForTest(self: *Queue, live: ops.Target, gate: *worker.TestGate) !void {
        if (!builtin.is_test) @compileError("test-only queue gate");
        try self.startImpl(live, gate);
    }
    /// actor가 사라진 대상을 확인했을 때, 쓰지 않은 실패 결과로 올려 같은 완료 통로에서 소비한다.
    pub fn rejectNext(self: *Queue) !void {
        try self.failNext(error.StaleTarget);
    }
    /// worker 시작의 할당 실패도 완료 통로에서 한 번 정산한다. 매 tick 재시도로 안내를 반복하지 않는다.
    /// 이미 시작된 쓰기는 이 함수로 취소하지 않는다.
    pub fn failNext(self: *Queue, failure: anyerror) !void {
        if (self.running != null) return error.Busy;
        if (self.waiting.items.len == 0) return error.Empty;
        const first = self.waiting.orderedRemove(0);
        self.running = descriptor(&first);
        self.outcome = .{ .id = first.id, .epoch = first.epoch, .prepared = first.prepared, .failure = failure };
    }
    /// 결과는 ack까지 큐가 소유한다. 결과가 main으로 넘어와도 예산과 실행 자리를 먼저 풀지 않는다.
    pub fn poll(self: *Queue) ?*Outcome {
        if (self.outcome) |*outcome| return outcome;
        const running = self.running orelse return null;
        const result = self.service.take() orelse return null;
        self.outcome = .{ .id = running.id, .epoch = running.target.epoch, .prepared = result.prepared, .failure = result.failure };
        return &self.outcome.?;
    }
    /// 완료 시점에 대상 세대를 다시 본다. start 때 맞았다는 이유만으로 늦은 결과를 반영하지 않는다.
    pub fn apply(self: *Queue, session: *host.AppSession, term: *host.Term, live: ops.Target) bool {
        return self.applyWithNotice(session, term, live, false);
    }
    pub fn applyWithNotice(self: *Queue, session: *host.AppSession, term: *host.Term, live: ops.Target, late: bool) bool {
        const outcome = if (self.outcome) |*value| value else return false;
        if (outcome.applied or outcome.failure != null) return false;
        const running = self.running orelse return false;
        if (!running.target.matches(live)) return false;
        outcome.applied = outcome.prepared.finishWithNotice(session, term, late);
        return outcome.applied;
    }
    /// 요청 lease의 모델과 현재 epoch를 모두 확인한다. 닫힌 뷰의 Term 주소는 사용하지 않는다.
    pub fn applyRetained(self: *Queue, lease: maru.session.editor.document_registry.Lease, live: ops.Target) bool {
        const outcome = if (self.outcome) |*value| value else return false;
        if (outcome.applied or outcome.failure != null) return false;
        const running = self.running orelse return false;
        if (!running.target.matches(live)) return false;
        outcome.applied = outcome.prepared.finishRetained(lease);
        return outcome.applied;
    }
    /// 성공 완료를 현재 문서에 반영한 actor만 accepted=true로 승인한다. rejected/오류는 기준을 인계하지 않는다.
    pub fn ack(self: *Queue, accepted: bool) !void {
        const outcome = if (self.outcome) |*value| value else return error.NotReady;
        const running = self.running.?;
        if (accepted and (outcome.failure != null or !outcome.applied)) return error.UnappliedCompletion;
        if (accepted and outcome.failure == null) {
            const written = editor.contentHash(outcome.prepared.bytes);
            for (self.waiting.items) |*entry| if (entry.target().matches(running.target)) {
                entry.prepared.expected_disk = ops.successorBaseline(running.before, entry.prepared.expected_disk, written);
            };
        }
        self.outcome.?.prepared.deinit(self.a);
        self.outcome = null;
        self.running = null;
        self.charged_bytes -= running.cost;
    }
    /// 최종 자원 정리다. 제품의 종료 UX를 구현하지 않으며 이미 시작한 디스크 쓰기를 취소하지 않는다.
    pub fn deinit(self: *Queue) void {
        self.service.deinit(self.a);
        if (self.outcome) |*outcome| outcome.prepared.deinit(self.a);
        for (self.waiting.items) |*entry| entry.prepared.deinit(self.a);
        self.waiting.deinit(self.a);
        self.* = undefined;
    }
};
