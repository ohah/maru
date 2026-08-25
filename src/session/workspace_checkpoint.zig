//! Workspace checkpoint의 순수 순서 판정자.
//!
//! 파일 저장, AppKit 종료 응답과 시계 읽기는 caller가 맡는다. 이 모듈이 그 일을 직접 알면
//! background save와 final Quit이 서로 다른 정책을 갖게 되므로, 세대와 effect 순서만 여기서 단일화한다.

const std = @import("std");

pub const Policy = struct {
    debounce_ns: u64,
    retry_initial_ns: u64,
    retry_max_ns: u64,

    fn validate(self: Policy) !void {
        if (self.debounce_ns == 0 or self.retry_initial_ns == 0 or self.retry_max_ns == 0 or
            self.retry_initial_ns > self.retry_max_ns)
        {
            return error.InvalidPolicy;
        }
    }
};

pub const Reason = enum {
    background,
    final_quit,
};

pub const Failure = enum {
    capture_failed,
    write_failed,
};

pub const Request = struct {
    generation: u64,
    reason: Reason,
};

pub const Effect = union(enum) {
    none,
    capture: Request,
    write: Request,
    cancel_quit,
    reply_and_detach,
};

pub const Result = union(enum) {
    committed: u64,
    stale: u64,
    capture_failed,
    write_failed,
};

pub const Completion = struct {
    result: ?Result = null,
    effect: Effect = .none,
    /// 같은 연속 실패 epoch에서는 첫 실패만 notice를 낸다. Quit 효과와 독립이라 둘을 잃지 않는다.
    notice: ?Failure = null,
};

const Operation = union(enum) {
    idle,
    capture: Request,
    write: Request,
};

pub const Coordinator = struct {
    policy: Policy,
    generation: u64 = 0,
    dirty: bool = false,
    due_at_ns: u64 = 0,
    retry_delay_ns: u64,
    notice_emitted: bool = false,
    operation: Operation = .idle,
    quit_pending: bool = false,

    pub fn init(policy: Policy) !Coordinator {
        try policy.validate();
        return .{
            .policy = policy,
            .retry_delay_ns = policy.retry_initial_ns,
        };
    }

    pub fn isDirty(self: *const Coordinator) bool {
        return self.dirty;
    }

    pub fn mutation(self: *Coordinator, now_ns: u64) !void {
        // 두 산술을 모두 먼저 끝내야 overflow가 state 일부만 바꾸지 않는다.
        const next_generation = std.math.add(u64, self.generation, 1) catch return error.Overflow;
        const next_due = std.math.add(u64, now_ns, self.policy.debounce_ns) catch return error.Overflow;
        self.generation = next_generation;
        self.dirty = true;
        self.due_at_ns = next_due;
    }

    pub fn tick(self: *Coordinator, now_ns: u64) !Effect {
        if (self.operation != .idle or self.quit_pending or !self.dirty or now_ns < self.due_at_ns) return .none;
        return self.startCapture(.background);
    }

    pub fn quitRequested(self: *Coordinator, _: u64) !Effect {
        if (self.quit_pending) return error.QuitAlreadyPending;
        self.quit_pending = true;
        if (self.operation == .idle) return self.startCapture(.final_quit);
        return .none;
    }

    pub fn captureCompleted(self: *Coordinator, generation: u64, succeeded: bool, now_ns: u64) !Completion {
        const request = switch (self.operation) {
            .capture => |request| request,
            else => return error.UnexpectedCompletion,
        };
        if (request.generation != generation) return error.UnexpectedCompletion;

        if (succeeded) {
            if (generation != self.generation) {
                self.operation = .idle;
                const effect: Effect = if (self.quit_pending) self.startCapture(.final_quit) else .none;
                return .{ .result = .{ .stale = generation }, .effect = effect };
            }
            self.operation = .{ .write = request };
            return .{ .effect = .{ .write = request } };
        }
        return self.fail(request, .capture_failed, now_ns);
    }

    pub fn writeCompleted(self: *Coordinator, generation: u64, succeeded: bool, now_ns: u64) !Completion {
        const request = switch (self.operation) {
            .write => |request| request,
            else => return error.UnexpectedCompletion,
        };
        if (request.generation != generation) return error.UnexpectedCompletion;
        if (!succeeded) return self.fail(request, .write_failed, now_ns);

        self.operation = .idle;
        const result: Result = if (generation == self.generation)
            .{ .committed = generation }
        else
            .{ .stale = generation };

        if (generation == self.generation) {
            self.dirty = false;
            self.retry_delay_ns = self.policy.retry_initial_ns;
            self.notice_emitted = false;
        }

        if (request.reason == .final_quit) {
            // final capture/write 중 persisted mutation이 생기면 stale bytes로 detach하지 않고 최신 세대를 다시 캡처한다.
            if (generation != self.generation)
                return .{ .result = result, .effect = self.startCapture(.final_quit) };
            self.quit_pending = false;
            return .{ .result = result, .effect = .reply_and_detach };
        }
        if (self.quit_pending) {
            return .{ .result = result, .effect = self.startCapture(.final_quit) };
        }
        return .{ .result = result };
    }

    fn startCapture(self: *Coordinator, reason: Reason) Effect {
        const request: Request = .{ .generation = self.generation, .reason = reason };
        self.operation = .{ .capture = request };
        return .{ .capture = request };
    }

    fn fail(self: *Coordinator, request: Request, failure: Failure, now_ns: u64) !Completion {
        const retry_due = std.math.add(u64, now_ns, self.retry_delay_ns) catch return error.Overflow;
        const doubled = std.math.mul(u64, self.retry_delay_ns, 2) catch return error.Overflow;
        const next_delay = @min(doubled, self.policy.retry_max_ns);

        self.operation = .idle;
        self.dirty = true;
        const notice: ?Failure = if (self.notice_emitted) null else failure;
        self.notice_emitted = true;
        const result: Result = switch (failure) {
            .capture_failed => .capture_failed,
            .write_failed => .write_failed,
        };

        if (request.reason == .final_quit) {
            self.quit_pending = false;
            self.due_at_ns = retry_due;
            self.retry_delay_ns = next_delay;
            return .{ .result = result, .effect = .cancel_quit, .notice = notice };
        }
        if (self.quit_pending) {
            return .{ .result = result, .effect = self.startCapture(.final_quit), .notice = notice };
        }
        self.due_at_ns = retry_due;
        self.retry_delay_ns = next_delay;
        return .{ .result = result, .notice = notice };
    }
};
