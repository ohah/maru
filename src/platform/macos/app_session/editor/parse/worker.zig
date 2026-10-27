//! 파싱 전용 상주 스레드. AppSession·UI·registry 포인터를 워커에 넘기지 않는다.
//! Service와 Completion은 복사하지 않는다. 원본 snapshot allocator는 reap/deinit까지 살아 있어야 한다.
const std = @import("std");
const builtin = @import("builtin");
const syntax = @import("syntax");
const maru = @import("maru");
const buffer = maru.session.editor.buffer;
const request = maru.session.editor.syntax.request;
const Identity = maru.session.editor.document_registry.DocumentIdentity;

pub const Mode = enum { cold, incremental, reused };
pub const Outcome = enum { ready, cancelled, out_of_memory, unavailable };
pub const TestAudit = struct {
    main_thread: std.Thread.Id,
    created: std.atomic.Value(usize) = .init(0),
    destroyed: std.atomic.Value(usize) = .init(0),
    cancelled_with_tree: std.atomic.Value(usize) = .init(0),
    reclaimed: std.atomic.Value(usize) = .init(0),
    wrong_thread: std.atomic.Value(bool) = .init(false),
};
pub const Options = struct {
    /// 워커에서만 호출한다. allocator의 저장소는 Service 종료까지 유지한다.
    copy_allocator: std.mem.Allocator = std.heap.page_allocator,
    audit: if (builtin.is_test) ?*TestAudit else void = if (builtin.is_test) null else {},
};
const Basis = struct {
    tag: request.Request,
    snapshot: buffer.Snapshot,
    provider: ?syntax.Provider,
};
const Job = struct {
    next: ?*Job = null,
    tag: request.Request,
    snapshot: buffer.Snapshot,
    language: syntax.Language,
    cancellation: syntax.Cancellation = .{},
    outcome: Outcome = .cancelled,
    provider: ?syntax.Provider = null,
    basis: ?Basis = null,
    mode: Mode = .cold,
    fn execute(self: *Job, state: *State) void {
        const allocator = state.options.copy_allocator;
        if (self.cancellation.isRequested()) return;
        if (self.snapshot.byteLen() > syntax.max_parse_bytes) {
            self.outcome = .unavailable;
            return;
        }
        const bytes = self.snapshot.copyRange(allocator, 0, self.snapshot.byteLen()) catch {
            self.outcome = .out_of_memory;
            return;
        };
        defer allocator.free(bytes);
        var complete = false;
        var parsed: syntax.Provider = undefined;
        if (self.basis) |*base| {
            const old_bytes = base.snapshot.copyRange(allocator, 0, base.snapshot.byteLen()) catch {
                self.outcome = .out_of_memory;
                return;
            };
            defer allocator.free(old_bytes);
            parsed = base.provider.?;
            base.provider = null;
            if (std.mem.eql(u8, old_bytes, bytes)) {
                self.mode = .reused;
                complete = true;
            } else {
                self.mode = .incremental;
                const span = maru.session.editor.edit_ops.reloadChange(old_bytes, bytes);
                const edit: syntax.Edit = .{
                    .start_byte = @intCast(span.start),
                    .old_end_byte = @intCast(span.end),
                    .new_end_byte = @intCast(span.start + span.text.len),
                    .start_point = syntax.pointAt(old_bytes, span.start),
                    .old_end_point = syntax.pointAt(old_bytes, span.end),
                    .new_end_point = syntax.pointAt(bytes, span.start + span.text.len),
                };
                complete = parsed.onEditCancellable(bytes, edit, &self.cancellation) == .done;
            }
        } else {
            parsed = syntax.Provider.initCancellable(bytes, self.language, &self.cancellation) orelse {
                self.outcome = if (self.cancellation.isRequested()) .cancelled else .unavailable;
                return;
            };
            state.recordNative(true);
            complete = bytes.len == 0 or parsed.tree != null;
        }
        if (builtin.is_test) if (state.options.audit) |audit| {
            if (self.cancellation.isRequested() and parsed.tree != null)
                _ = audit.cancelled_with_tree.fetchAdd(1, .monotonic);
        };
        if (self.cancellation.isRequested() or !complete) {
            self.outcome = if (self.cancellation.isRequested()) .cancelled else .unavailable;
            parsed.deinit();
            state.recordNative(false);
            return;
        }
        self.provider = parsed;
        self.outcome = .ready;
    }
};
const List = struct {
    first: ?*Job = null,
    last: ?*Job = null,
    fn push(self: *List, job: *Job) void {
        job.next = null;
        if (self.last) |last| last.next = job else self.first = job;
        self.last = job;
    }
    fn pop(self: *List) ?*Job {
        const job = self.first orelse return null;
        self.first = job.next;
        if (self.first == null) self.last = null;
        job.next = null;
        return job;
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    options: Options,
    threaded: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    waiting: List = .{},
    completed: List = .{},
    retiring: List = .{},
    returned: List = .{},
    active: ?*Job = null,
    held: usize = 0,
    stopping: bool = false,

    fn recordNative(self: *State, created: bool) void {
        if (builtin.is_test) if (self.options.audit) |audit| {
            if (created) _ = audit.created.fetchAdd(1, .monotonic) else _ = audit.destroyed.fetchAdd(1, .monotonic);
            if (!created and std.Thread.getCurrentId() == audit.main_thread) audit.wrong_thread.store(true, .release);
        };
    }
    fn io(self: *State) std.Io {
        return self.threaded.io();
    }
    fn cancelLocked(self: *State, document: Identity) void {
        if (self.active) |job| if (std.meta.eql(job.tag.input.document, document)) {
            job.cancellation.request();
        };
        // native 기준 핸들이 있는 대기는 워커에서 먼저 해제하고, 나머지만 바로 메인으로 반환한다.
        var kept: List = .{};
        while (self.waiting.pop()) |job| {
            if (std.meta.eql(job.tag.input.document, document)) {
                if (job.basis != null) self.retiring.push(job) else self.returned.push(job);
            } else kept.push(job);
        }
        self.waiting = kept;
        var item = self.completed.first;
        while (item) |job| : (item = job.next) {
            if (std.meta.eql(job.tag.input.document, document)) {
                job.cancellation.request();
                job.outcome = .cancelled;
            }
        }
    }
    fn run(self: *State) void {
        const io_value = self.io();
        self.mutex.lockUncancelable(io_value);
        defer self.mutex.unlock(io_value);
        while (true) {
            if (self.retiring.pop()) |job| {
                self.mutex.unlock(io_value);
                if (job.provider) |*provider| {
                    provider.deinit();
                    self.recordNative(false);
                }
                job.provider = null;
                if (job.basis) |*base| if (base.provider) |*provider| {
                    provider.deinit();
                    self.recordNative(false);
                    base.provider = null;
                };
                self.mutex.lockUncancelable(io_value);
                self.returned.push(job);
                self.changed.broadcast(io_value);
                continue;
            }
            if (self.stopping) break;
            if (self.waiting.pop()) |job| {
                self.active = job;
                self.mutex.unlock(io_value);
                job.execute(self);
                self.mutex.lockUncancelable(io_value);
                self.active = null;
                if (job.cancellation.isRequested()) job.outcome = .cancelled;
                if (self.stopping) self.retiring.push(job) else self.completed.push(job);
                self.changed.broadcast(io_value);
                continue;
            }
            self.changed.waitUncancelable(io_value, &self.mutex);
        }
    }
};

/// 메인 소유 결과. provider는 release 전까지만 빌리며, 복사한 핸들의 수명은 caller 책임이다.
/// release 후에는 이 값과 빌린 포인터를 사용하지 않는다.
pub const Completion = struct {
    state: *State,
    job: *Job,
    pub fn tag(self: Completion) request.Request {
        return self.job.tag;
    }
    /// 증분 범위는 이 기준 요청과 같은 표시 판에서만 부분 재사용할 수 있다.
    pub fn basis(self: Completion) ?request.Request {
        return if (self.job.basis) |base| base.tag else null;
    }
    pub fn mode(self: Completion) Mode {
        return self.job.mode;
    }
    pub fn outcome(self: Completion) Outcome {
        return self.job.outcome;
    }
    pub fn provider(self: Completion) ?*const syntax.Provider {
        if (self.job.outcome != .ready) return null;
        return if (self.job.provider) |*value| value else null;
    }
    pub fn accept(self: Completion, gate: *request.Gate) bool {
        if (self.job.outcome != .ready) {
            _ = gate.abandon(self.job.tag);
            return false;
        }
        return gate.accept(self.job.tag);
    }
    pub fn release(self: *Completion) void {
        const state = self.state;
        const io_value = state.io();
        state.mutex.lockUncancelable(io_value);
        state.held -= 1;
        state.retiring.push(self.job);
        state.changed.signal(io_value);
        state.mutex.unlock(io_value);
        self.* = undefined;
    }
};

/// 메인 스레드에서만 호출한다. worker는 내부 State를 안정된 주소로 붙든다.
pub const Service = struct {
    state: *State,
    pub fn init(allocator: std.mem.Allocator, options: Options) !Service {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .options = options, .threaded = .init(std.heap.page_allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing }) };
        errdefer state.threaded.deinit();
        state.thread = try std.Thread.spawn(.{}, State.run, .{state});
        return .{ .state = state };
    }
    /// 성공 때만 snapshot을 이동한다. 실패 시 caller가 snapshot을 계속 소유한다.
    pub fn submit(self: *Service, gate: *request.Gate, input: request.Input, snapshot: *buffer.Snapshot, language: syntax.Language) !request.Request {
        return self.submitImpl(gate, input, snapshot, language, null, if (builtin.is_test) null else {});
    }
    /// 기준 Completion은 이 호출 동안만 빌린다. 서로 다른 native 핸들과 Snapshot 참조를 만든다.
    /// 기준이 없거나 문서/문법이 다르면 기존 cold parse 경로를 사용한다.
    pub fn submitFrom(self: *Service, gate: *request.Gate, input: request.Input, snapshot: *buffer.Snapshot, language: syntax.Language, base: *const Completion) !request.Request {
        return self.submitImpl(gate, input, snapshot, language, base, if (builtin.is_test) null else {});
    }
    fn submitImpl(self: *Service, gate: *request.Gate, input: request.Input, snapshot: *buffer.Snapshot, language: syntax.Language, base: ?*const Completion, test_gate: if (builtin.is_test) ?*syntax.Cancellation.TestGate else void) !request.Request {
        const tag = gate.begin(input) catch |err| {
            self.cancelDocument(input.document);
            return err;
        };
        self.cancelDocument(input.document);
        // 새 요청이 선언되면 아직 빌려 가지 않은 이전 완료도 더는 적용할 수 없다.
        const state_for_retire = self.state;
        const retire_io = state_for_retire.io();
        state_for_retire.mutex.lockUncancelable(retire_io);
        var kept: List = .{};
        while (state_for_retire.completed.pop()) |old| {
            if (std.meta.eql(old.tag.input.document, input.document)) state_for_retire.retiring.push(old) else kept.push(old);
        }
        state_for_retire.completed = kept;
        state_for_retire.changed.signal(retire_io);
        state_for_retire.mutex.unlock(retire_io);
        const job = self.state.allocator.create(Job) catch |err| {
            _ = gate.abandon(tag);
            return err;
        };
        errdefer self.state.allocator.destroy(job);
        job.* = .{ .tag = tag, .snapshot = snapshot.*, .language = language };
        if (builtin.is_test) job.cancellation.gate = test_gate;
        if (!gate.publish(tag)) return error.StaleRequest;
        if (base) |previous| {
            if (previous.outcome() == .ready and previous.job.language == language and
                std.meta.eql(previous.tag().input.document, input.document) and
                std.meta.eql(previous.tag().input.grammar, input.grammar) and snapshot.byteLen() <= syntax.max_parse_bytes)
            {
                if (previous.provider()) |original| if (original.copyReady(language)) |copy| {
                    self.state.recordNative(true);
                    job.basis = .{ .tag = previous.tag(), .snapshot = previous.job.snapshot.clone(), .provider = copy };
                };
            }
        }
        const state = self.state;
        const io_value = state.io();
        state.mutex.lockUncancelable(io_value);
        state.waiting.push(job);
        snapshot.* = undefined;
        state.changed.signal(io_value);
        state.mutex.unlock(io_value);
        return tag;
    }
    /// Gate의 입력 무효화는 caller가 먼저 한다. 이 메서드는 자원 회수의 완료를 뜻하지 않는다.
    pub fn cancelDocument(self: *Service, document: Identity) void {
        const state = self.state;
        const io_value = state.io();
        state.mutex.lockUncancelable(io_value);
        state.cancelLocked(document);
        state.changed.signal(io_value);
        state.mutex.unlock(io_value);
        self.reap();
    }
    pub fn take(self: *Service) ?Completion {
        const state = self.state;
        const io_value = state.io();
        state.mutex.lockUncancelable(io_value);
        defer state.mutex.unlock(io_value);
        const job = state.completed.pop() orelse return null;
        state.held += 1;
        return .{ .state = state, .job = job };
    }
    /// 네이티브 자원은 이미 워커가 해제했다. 원본 allocator와 노드는 메인에서만 회수한다.
    pub fn reap(self: *Service) void {
        const state = self.state;
        const io_value = state.io();
        state.mutex.lockUncancelable(io_value);
        var returned = state.returned;
        state.returned = .{};
        state.mutex.unlock(io_value);
        while (returned.pop()) |job| {
            std.debug.assert(job.provider == null);
            if (builtin.is_test) if (state.options.audit) |audit| {
                _ = audit.reclaimed.fetchAdd(1, .monotonic);
                if (std.Thread.getCurrentId() != audit.main_thread) audit.wrong_thread.store(true, .release);
            };
            job.snapshot.deinit();
            if (job.basis) |*base| {
                std.debug.assert(base.provider == null);
                base.snapshot.deinit();
            }
            state.allocator.destroy(job);
        }
    }
    /// 빌려 간 결과가 남으면 서비스는 그대로 살아 있고 caller가 release 후 다시 시도한다.
    pub fn deinit(self: *Service) error{ResultsHeld}!void {
        const state = self.state;
        const io_value = state.io();
        state.mutex.lockUncancelable(io_value);
        if (state.held != 0) {
            state.mutex.unlock(io_value);
            return error.ResultsHeld;
        }
        state.stopping = true;
        if (state.active) |job| job.cancellation.request();
        while (state.waiting.pop()) |job| state.retiring.push(job);
        while (state.completed.pop()) |job| state.retiring.push(job);
        state.changed.signal(io_value);
        state.mutex.unlock(io_value);
        state.thread.?.join();
        self.reap();
        const allocator = state.allocator;
        state.threaded.deinit();
        allocator.destroy(state);
        self.* = undefined;
    }
};

const test_input: request.Input = .{ .document = .{ .owner = 1, .slot = 2, .generation = 3 }, .revision = 1, .grammar = .{ .identity = @backingInt(syntax.Language.zig), .generation = 0 } };
fn testQueue(service: *Service, gate: *request.Gate, input: request.Input, source: buffer.Buffer, pause: ?*syntax.Cancellation.TestGate) !request.Request {
    var snapshot = source.snapshot();
    errdefer snapshot.deinit();
    return service.submitImpl(gate, input, &snapshot, .zig, null, pause);
}
fn waitReady(service: *Service) void {
    const state = service.state;
    const io_value = state.io();
    state.mutex.lockUncancelable(io_value);
    defer state.mutex.unlock(io_value);
    while (state.completed.first == null) state.changed.waitUncancelable(io_value, &state.mutex);
}
fn testTake(service: *Service) Completion {
    waitReady(service);
    return service.take().?;
}
fn waitEntered(pause: *syntax.Cancellation.TestGate) !void {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 10_000_000_000;
    while (!pause.entered.load(.acquire)) {
        if (std.Io.Clock.awake.now(std.testing.io).nanoseconds > deadline) return error.CallbackNotEntered;
        std.Thread.yield() catch {};
    }
}
fn largeTestBuffer(a: std.mem.Allocator) !buffer.Buffer {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    for (0..3000) |_| try text.appendSlice(a, "const item = 1;\n");
    return buffer.Buffer.init(a, text.items);
}

test "parse worker 최신 대기만 유지하고 실행 중인 이전 요청은 C 반환까지 보존한다" {
    const a = std.testing.allocator;
    var first = try largeTestBuffer(a);
    defer first.deinit();
    var second = try buffer.Buffer.init(a, "const second = 2;\n");
    defer second.deinit();
    var latest = try buffer.Buffer.init(a, "const latest = 3;\n");
    defer latest.deinit();
    var audit: TestAudit = .{ .main_thread = std.Thread.getCurrentId() };
    var copies = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
    {
        var service = try Service.init(a, .{ .audit = &audit, .copy_allocator = copies.allocator() });
        defer service.deinit() catch unreachable;
        var pause: syntax.Cancellation.TestGate = .{};
        defer pause.release();
        var gate: request.Gate = .{};
        _ = try testQueue(&service, &gate, test_input, first, &pause);
        try waitEntered(&pause);
        var input = test_input;
        input.revision += 1;
        _ = try testQueue(&service, &gate, input, second, null);
        input.revision += 1;
        const tag = try testQueue(&service, &gate, input, latest, null);
        service.reap(); // 교체된 미실행 노드의 snapshot은 메인에서 회수한다.
        pause.release();
        var old = testTake(&service);
        defer old.release();
        try std.testing.expectEqual(Outcome.cancelled, old.outcome());
        try std.testing.expect(!old.accept(&gate));
        var current = testTake(&service);
        defer current.release();
        try std.testing.expectEqual(tag, current.tag());
        try std.testing.expectEqual(Outcome.ready, current.outcome());
        try std.testing.expect(current.accept(&gate));
        try std.testing.expect(!current.accept(&gate));
        try std.testing.expect(current.provider().?.tree != null);
        const bytes = try current.job.snapshot.copyRange(a, 0, current.job.snapshot.byteLen());
        defer a.free(bytes);
        try std.testing.expectEqualStrings("const latest = 3;\n", bytes);
        try std.testing.expect(service.take() == null);
    }
    try std.testing.expectEqual(@as(usize, 0), audit.cancelled_with_tree.load(.acquire));
    try std.testing.expectEqual(audit.created.load(.acquire), audit.destroyed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), audit.reclaimed.load(.acquire));
    try std.testing.expect(!audit.wrong_thread.load(.acquire));
    try std.testing.expectEqual(copies.allocated_bytes, copies.freed_bytes);
}

test "parse worker 한 문서 취소는 다른 문서 대기를 지우지 않는다" {
    const a = std.testing.allocator;
    var first = try largeTestBuffer(a);
    defer first.deinit();
    var other = try buffer.Buffer.init(a, "const other = 7;\n");
    defer other.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var pause: syntax.Cancellation.TestGate = .{};
    defer pause.release();
    var gate_a: request.Gate = .{};
    var gate_b: request.Gate = .{};
    _ = try testQueue(&service, &gate_a, test_input, first, &pause);
    try waitEntered(&pause);
    var input = test_input;
    input.document.owner += 1;
    _ = try testQueue(&service, &gate_b, input, other, null);
    gate_a.invalidate();
    service.cancelDocument(test_input.document);
    pause.release();
    var cancelled = testTake(&service);
    defer cancelled.release();
    try std.testing.expectEqual(Outcome.cancelled, cancelled.outcome());
    var ready = testTake(&service);
    defer ready.release();
    try std.testing.expect(ready.accept(&gate_b));
    try std.testing.expectEqual(input.document, ready.tag().input.document);
}

test "parse worker 준비 할당 실패는 snapshot을 가져가지 않고 이전 수락을 지운다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "const saved = 1;");
    defer source.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{});
    var service = try Service.init(failing.allocator(), .{});
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    const old_tag = try testQueue(&service, &gate, test_input, source, null);
    var old = testTake(&service);
    defer old.release();
    try std.testing.expect(old.accept(&gate));
    var input = test_input;
    input.revision += 1;
    var snapshot = source.snapshot();
    var owns_snapshot = true;
    defer if (owns_snapshot) snapshot.deinit();
    failing.fail_index = failing.alloc_index;
    if (service.submit(&gate, input, &snapshot, .zig)) |_| {
        owns_snapshot = false;
        return error.ExpectedAllocationFailure;
    } else |err| try std.testing.expect(err == error.OutOfMemory);
    try std.testing.expect(!gate.isCurrent(old_tag));
    try std.testing.expectEqual(source.byteLen(), snapshot.byteLen());
}

test "parse worker 본문 복사 OOM은 실패 결과로 반환하고 원본 snapshot을 회수한다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "const n = 1;");
    defer source.deinit();
    var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = 0 });
    var service = try Service.init(a, .{ .copy_allocator = failing.allocator() });
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source, null);
    var result = testTake(&service);
    defer result.release();
    try std.testing.expectEqual(Outcome.out_of_memory, result.outcome());
    try std.testing.expect(!result.accept(&gate));
    try std.testing.expect(result.provider() == null);
}

test "parse worker 결과를 빌린 동안 종료는 거절하고 반환 뒤 종료한다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "const n = 1;");
    defer source.deinit();
    var audit: TestAudit = .{ .main_thread = std.Thread.getCurrentId() };
    var copies = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
    var service = try Service.init(a, .{ .audit = &audit, .copy_allocator = copies.allocator() });
    var service_open = true;
    defer if (service_open) {
        service.deinit() catch unreachable;
    };
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source, null);
    var result = testTake(&service);
    var result_open = true;
    defer if (result_open) result.release();
    try std.testing.expectError(error.ResultsHeld, service.deinit());
    try std.testing.expect(result.provider().?.tree != null);
    result.release();
    result_open = false;
    try service.deinit();
    service_open = false;
    try std.testing.expectEqual(@as(usize, 1), audit.created.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), audit.destroyed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), audit.reclaimed.load(.acquire));
    try std.testing.expect(!audit.wrong_thread.load(.acquire));
    try std.testing.expect(copies.allocated_bytes > 0);
    try std.testing.expectEqual(copies.allocated_bytes, copies.freed_bytes);
}

test "parse worker 실행과 대기가 있어도 종료는 모든 소유 자료를 회수한다" {
    const a = std.testing.allocator;
    var first = try largeTestBuffer(a);
    var first_open = true;
    defer if (first_open) first.deinit();
    var other = try buffer.Buffer.init(a, "const other = 7;");
    defer other.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var pause: syntax.Cancellation.TestGate = .{};
    defer pause.release();
    var gate_a: request.Gate = .{};
    var gate_b: request.Gate = .{};
    _ = try testQueue(&service, &gate_a, test_input, first, &pause);
    try waitEntered(&pause);
    first.deinit();
    first_open = false;
    var input = test_input;
    input.document.slot += 1;
    _ = try testQueue(&service, &gate_b, input, other, null);
    pause.release();
}

test "parse worker 빈 입력과 미지원 언어를 구분한다" {
    const a = std.testing.allocator;
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    for ([_]syntax.Language{ .zig, .other }) |language| {
        var source = try buffer.Buffer.init(a, if (language == .zig) "" else "text");
        defer source.deinit();
        var snapshot = source.snapshot();
        var input = test_input;
        input.grammar.identity = @backingInt(language);
        _ = service.submit(&gate, input, &snapshot, language) catch |err| {
            snapshot.deinit();
            return err;
        };
        var result = testTake(&service);
        defer result.release();
        try std.testing.expectEqual(if (language == .zig) Outcome.ready else Outcome.unavailable, result.outcome());
        try std.testing.expectEqual(language == .zig, result.accept(&gate));
    }
}

test "parse worker 완료 후에도 take 전 취소된 결과를 수락하지 않는다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "const n = 1;");
    defer source.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source, null);
    waitReady(&service);
    gate.invalidate();
    service.cancelDocument(test_input.document);
    var result = service.take().?;
    defer result.release();
    try std.testing.expectEqual(Outcome.cancelled, result.outcome());
    try std.testing.expect(!result.accept(&gate));
    try std.testing.expect(result.provider() == null);
}

test "parse worker 새 입력은 아직 빌리지 않은 이전 완료도 퇴역시킨다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "const n = 1;");
    defer source.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    const old = try testQueue(&service, &gate, test_input, source, null);
    waitReady(&service);
    var input = test_input;
    input.revision += 1;
    const latest = try testQueue(&service, &gate, input, source, null);
    var result = testTake(&service);
    defer result.release();
    try std.testing.expect(old.serial != result.tag().serial);
    try std.testing.expectEqual(latest, result.tag());
    try std.testing.expect(result.accept(&gate));
    try std.testing.expect(service.take() == null);
}

fn testQueueFrom(service: *Service, gate: *request.Gate, input: request.Input, source: buffer.Buffer, base: *const Completion, pause: ?*syntax.Cancellation.TestGate) !request.Request {
    var snapshot = source.snapshot();
    errdefer snapshot.deinit();
    return service.submitImpl(gate, input, &snapshot, .zig, base, pause);
}
fn expectTree(result: *const Completion, source: []const u8, language: syntax.Language) !void {
    var cold = syntax.Provider.init(source, language, 0) orelse return error.NoProvider;
    defer cold.deinit();
    try std.testing.expect(syntax.testing.equal(cold.tree.?, result.provider().?.tree.?) != null);
}

test "parse worker 증분과 같은 본문 재사용은 cold 전체 노드와 같고 원본은 불변이다" {
    // 넓은 재파싱은 잘못된 편집 point를 덮을 수 있으므로 입력 좌표 계약도 따로 대조한다.
    try std.testing.expectEqual(syntax.Point{ .row = 1, .column = 7 }, syntax.pointAt("a\r\n가😀", 10));
    try std.testing.expectEqual(syntax.Point{ .row = 0, .column = 2 }, syntax.pointAt("a\r\n가😀", 2));
    const a = std.testing.allocator;
    const before = "// 가 😀\r\npub fn first() void {\r\n const s = \"가\"; _ = s;\r\n}\r\n";
    const after = "// 가 😁\r\npub fn second() void {\r\n const s = \"각\"; _ = s;\r\n}\r\npub fn tail() void {}\r\n";
    var source_a = try buffer.Buffer.init(a, before);
    defer source_a.deinit();
    var source_b = try buffer.Buffer.init(a, after);
    defer source_b.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    const tag_a = try testQueue(&service, &gate, test_input, source_a, null);
    var first = testTake(&service);
    defer first.release();
    try std.testing.expect(first.accept(&gate));
    var input = test_input;
    input.revision += 1;
    const tag_b = try testQueueFrom(&service, &gate, input, source_b, &first, null);
    var next = testTake(&service);
    defer next.release();
    try std.testing.expectEqual(Mode.incremental, next.mode());
    try std.testing.expectEqual(tag_a, next.basis().?);
    try std.testing.expect(next.accept(&gate));
    try expectTree(&next, after, .zig);
    try expectTree(&first, before, .zig);
    input.revision += 1;
    _ = try testQueueFrom(&service, &gate, input, source_b, &next, null);
    var same = testTake(&service);
    defer same.release();
    try std.testing.expectEqual(Mode.reused, same.mode());
    try std.testing.expectEqual(tag_b, same.basis().?);
    try std.testing.expect(same.accept(&gate));
    try expectTree(&same, after, .zig);
    var empty = try buffer.Buffer.init(a, "");
    defer empty.deinit();
    input.revision += 1;
    _ = try testQueueFrom(&service, &gate, input, empty, &same, null);
    var cleared = testTake(&service);
    defer cleared.release();
    try std.testing.expectEqual(Mode.incremental, cleared.mode());
    try std.testing.expect(cleared.accept(&gate));
    try std.testing.expect(cleared.provider().?.tree == null);
    input.revision += 1;
    _ = try testQueueFrom(&service, &gate, input, source_b, &cleared, null);
    var restored = testTake(&service);
    defer restored.release();
    try std.testing.expectEqual(Mode.cold, restored.mode());
    try std.testing.expect(restored.basis() == null);
    try std.testing.expect(restored.accept(&gate));
    try expectTree(&restored, after, .zig);
}

test "parse worker 증분 native 중단은 남은 이전 트리를 성공으로 공개하지 않는다" {
    const a = std.testing.allocator;
    const before = "pub fn first() void {}\n";
    var source_a = try buffer.Buffer.init(a, before);
    defer source_a.deinit();
    var source_b = try largeTestBuffer(a);
    defer source_b.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var pause: syntax.Cancellation.TestGate = .{ .abort = true };
    defer pause.release();
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source_a, null);
    var first = testTake(&service);
    defer first.release();
    var input = test_input;
    input.revision += 1;
    _ = try testQueueFrom(&service, &gate, input, source_b, &first, &pause);
    try waitEntered(&pause);
    try expectTree(&first, before, .zig); // 다른 핸들의 ts_tree_edit 뒤, C가 아직 반환하지 않은 시점이다.
    pause.release();
    var stopped = testTake(&service);
    defer stopped.release();
    try std.testing.expectEqual(Outcome.unavailable, stopped.outcome());
    try std.testing.expect(!stopped.accept(&gate));
    try std.testing.expect(stopped.provider() == null);
}

test "parse worker 문서와 문법 판 및 언어가 다른 기준은 cold로 처리한다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "pub fn first() void {}\n");
    defer source.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source, null);
    var first = testTake(&service);
    defer first.release();
    for (0..3) |kind| {
        var input = test_input;
        var language: syntax.Language = .zig;
        if (kind == 0) input.document.generation += 1;
        if (kind == 1) input.grammar.generation += 1;
        if (kind == 2) {
            language = .json;
            input.grammar.identity = @backingInt(language);
        }
        var snapshot = source.snapshot();
        _ = service.submitFrom(&gate, input, &snapshot, language, &first) catch |err| {
            snapshot.deinit();
            return err;
        };
        var result = testTake(&service);
        defer result.release();
        try std.testing.expectEqual(Mode.cold, result.mode());
        try std.testing.expect(result.basis() == null);
        try std.testing.expect(result.accept(&gate));
    }
}

test "parse worker 증분 대기 교체와 기준 반환 뒤에도 복사 핸들을 워커가 회수한다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "pub fn first() void {}\n");
    defer source.deinit();
    var next_source = try buffer.Buffer.init(a, "pub fn last() void { const x = 2; _ = x; }\n");
    defer next_source.deinit();
    var blocker = try largeTestBuffer(a);
    defer blocker.deinit();
    var audit: TestAudit = .{ .main_thread = std.Thread.getCurrentId() };
    var copies = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
    {
        var service = try Service.init(a, .{ .audit = &audit, .copy_allocator = copies.allocator() });
        defer service.deinit() catch unreachable;
        var pause: syntax.Cancellation.TestGate = .{};
        defer pause.release();
        var gate: request.Gate = .{};
        _ = try testQueue(&service, &gate, test_input, source, null);
        var first = testTake(&service);
        var first_open = true;
        defer if (first_open) first.release();
        var other_gate: request.Gate = .{};
        var other_input = test_input;
        other_input.document.owner += 1;
        _ = try testQueue(&service, &other_gate, other_input, blocker, &pause);
        try waitEntered(&pause);
        var input = test_input;
        input.revision += 1;
        _ = try testQueueFrom(&service, &gate, input, next_source, &first, null);
        input.revision += 1;
        const latest = try testQueueFrom(&service, &gate, input, next_source, &first, null);
        first.release();
        first_open = false;
        pause.release();
        var other = testTake(&service);
        defer other.release();
        try std.testing.expect(other.accept(&other_gate));
        var result = testTake(&service);
        defer result.release();
        try std.testing.expectEqual(latest, result.tag());
        try std.testing.expectEqual(Mode.incremental, result.mode());
        try std.testing.expect(result.accept(&gate));
        try expectTree(&result, "pub fn last() void { const x = 2; _ = x; }\n", .zig);
    }
    try std.testing.expectEqual(audit.created.load(.acquire), audit.destroyed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 4), audit.reclaimed.load(.acquire));
    try std.testing.expect(!audit.wrong_thread.load(.acquire));
    try std.testing.expectEqual(copies.allocated_bytes, copies.freed_bytes);
}

test "parse worker 기준 원문 복사 OOM도 원본과 native 핸들을 보존해 회수한다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "pub fn first() void {}\n");
    defer source.deinit();
    var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
    var service = try Service.init(a, .{ .copy_allocator = failing.allocator() });
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source, null);
    var first = testTake(&service);
    defer first.release();
    failing.fail_index = failing.alloc_index + 1;
    var input = test_input;
    input.revision += 1;
    _ = try testQueueFrom(&service, &gate, input, source, &first, null);
    var failed = testTake(&service);
    defer failed.release();
    try std.testing.expectEqual(Outcome.out_of_memory, failed.outcome());
    try std.testing.expect(!failed.accept(&gate));
    try expectTree(&first, "pub fn first() void {}\n", .zig);
}
