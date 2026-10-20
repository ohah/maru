//! 준비한 저장을 별도 스레드에서 쓰고, 완료 자료는 한 소유자에게만 넘긴다.
//! 이 기반은 아직 사용자 저장 경로에 연결하지 않는다. 서비스의 소유자가 종료 전에 join 한다.
const std = @import("std");
const builtin = @import("builtin");
const save_ops = @import("maru").session.editor.save_ops;
const local = @import("../local_save.zig");
const editor = @import("../mod.zig");

// 테스트의 순서를 OS 스케줄링 속도에 맡기지 않는다. 제품 Job에는 이 필드가 없다.
pub const TestGate = struct {
    entered: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    pub fn set(self: *TestGate) void {
        self.released.store(true, .release);
    }
    fn wait(self: *TestGate) void {
        self.entered.store(true, .release);
        while (!self.released.load(.acquire)) std.Thread.yield() catch {};
    }
};

pub const Completion = struct {
    prepared: local.Prepared,
    failure: ?editor.SaveError,
    pub fn deinit(self: *Completion, a: std.mem.Allocator) void {
        self.prepared.deinit(a);
        self.* = undefined;
    }
};

// 실행 중인 writer의 결과 슬롯까지 먼저 할당한다. 결과 보관에는 새 할당이 없고 통지는 OS가 소유한다.
const Job = struct {
    prepared: local.Prepared,
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    failure: ?editor.SaveError = null,
    gate: if (builtin.is_test) ?*TestGate else void = if (builtin.is_test) null else {},
    fn execute(self: *Job) void {
        if (builtin.is_test) if (self.gate) |gate| gate.wait();
        // AppSession의 I/O executor를 빌리지 않는다. worker가 자기 executor를 닫은 뒤 완료를 게시한다.
        {
            var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
            defer threaded.deinit();
            self.prepared.write(threaded.io()) catch |err| {
                self.failure = err;
            };
        }
        self.done.store(true, .release);
        @import("wake.zig").request();
    }
};

/// actor 하나가 소유하는 단일 실행 자리다. 큐·동시성·재요청 UX는 상위 coordinator가 정한다.
/// 준비 자료의 allocator는 take/deinit까지 살아 있어야 한다. worker는 그 allocator를 사용하지 않는다.
pub const Service = struct {
    a: std.mem.Allocator,
    job: ?*Job = null,
    pub fn init(a: std.mem.Allocator) Service {
        return .{ .a = a };
    }
    /// 실패 시 준비 자료는 caller가 그대로 소유하며, 성공 때만 넘긴다.
    pub fn start(self: *Service, prepared: *local.Prepared) !void {
        try self.startImpl(prepared, if (builtin.is_test) null else {});
    }
    fn startImpl(self: *Service, prepared: *local.Prepared, gate: if (builtin.is_test) ?*TestGate else void) !void {
        if (self.job != null) return error.Busy;
        if (!save_ops.writable(prepared.written, prepared.finished)) return error.InvalidPhase;
        const job = try self.a.create(Job);
        errdefer self.a.destroy(job);
        job.* = .{ .prepared = prepared.*, .gate = gate };
        job.thread = try std.Thread.spawn(.{}, Job.execute, .{job});
        self.job = job;
        prepared.* = undefined;
    }
    /// main actor만 호출한다. acquire 전에는 worker가 쓰는 prepared/failure를 읽지 않는다.
    pub fn ready(self: *const Service) bool {
        const job = self.job orelse return false;
        return job.done.load(.acquire);
    }
    pub fn take(self: *Service) ?Completion {
        const job = self.job orelse return null;
        if (!job.done.load(.acquire)) return null;
        return self.collect(job);
    }
    fn collect(self: *Service, job: *Job) Completion {
        job.thread.?.join();
        const result: Completion = .{ .prepared = job.prepared, .failure = job.failure };
        self.a.destroy(job);
        self.job = null;
        return result;
    }
    /// 취소/rollback은 아니다. 시작된 쓰기를 마친 뒤 해제하므로 borrowed executor·detach 수명 구멍이 없다.
    /// 제품의 닫기/종료는 먼저 완료를 소비해야 한다. 이 함수는 결과를 버리는 최종 자원 정리다.
    pub fn deinit(self: *Service, prepared_allocator: std.mem.Allocator) void {
        if (self.job) |job| {
            var completion = self.collect(job);
            completion.deinit(prepared_allocator);
        }
    }
    pub fn startBlockedForTest(self: *Service, prepared: *local.Prepared, gate: *TestGate) !void {
        if (!builtin.is_test) @compileError("test-only worker gate");
        try self.startImpl(prepared, gate);
        while (!gate.entered.load(.acquire)) std.Thread.yield() catch {};
    }
};
