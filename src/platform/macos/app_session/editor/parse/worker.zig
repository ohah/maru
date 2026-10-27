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
    /// 워커에서 메인 작업을 예약만 한다. 소유자 포인터를 캡처하거나 메인 처리를 기다리지 않는다.
    /// 함수는 join까지 유지하며, 이미 예약된 전달의 저장소는 서비스와 독립적으로 유지한다.
    notify: ?*const fn () void = null,
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
    // 메인만 읽고 고친다. worker의 큐 이동 중에도 실제 Snapshot 반환까지 작업이 살아 있음을 보인다.
    main_prev: ?*Job = null,
    main_next: ?*Job = null,
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
    main_live: ?*Job = null, // 메인 소유 전체 작업 목록. 추가 할당 없이 수명을 추적한다.
    stopping: bool = false,
    notification_pending: std.atomic.Value(bool) = .init(false),

    // 큐 게시 뒤 호출한다. callback을 실행하는 동안 큐 mutex를 잡지 않는다.
    fn notifyMainLocked(self: *State) void {
        if (self.stopping) return;
        const notify = self.options.notify orelse return;
        if (self.notification_pending.swap(true, .acq_rel)) return;
        const io_value = self.io();
        self.mutex.unlock(io_value);
        notify();
        self.mutex.lockUncancelable(io_value);
    }
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
                self.notifyMainLocked();
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
                self.notifyMainLocked();
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
        job.main_next = state.main_live;
        if (state.main_live) |head| head.main_prev = job;
        state.main_live = job;
        const io_value = state.io();
        state.mutex.lockUncancelable(io_value);
        state.waiting.push(job);
        snapshot.* = undefined;
        state.changed.signal(io_value);
        state.mutex.unlock(io_value);
        return tag;
    }
    /// 메인 전용 수명 조회다. 실행/퇴역 중이거나 caller가 보유한 완료도 Snapshot 반환 전까지 포함한다.
    pub fn hasJobs(self: *const Service, document: Identity) bool {
        var next = self.state.main_live;
        while (next) |job| : (next = job.main_next) {
            if (std.meta.eql(job.tag.input.document, document)) return true;
        }
        return false;
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
    /// 메인 drain의 맨 앞에서 호출한 뒤 reap과 take 반복을 수행한다.
    /// 먼저 재무장하므로 drain 도중 생긴 완료/퇴역은 다음 통지를 예약할 수 있다.
    /// 통지는 서비스 포인터를 담지 않으므로 caller는 늦은 통지에서 현재 소유자를 다시 찾는다.
    pub fn beginDrain(self: *Service) bool {
        return self.state.notification_pending.swap(false, .acq_rel);
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
            // 두 Snapshot의 allocator 사용이 모두 끝난 뒤에만 문서 keeper의 해제를 허용한다.
            if (job.main_prev) |previous| previous.main_next = job.main_next else state.main_live = job.main_next;
            if (job.main_next) |next| next.main_prev = job.main_prev;
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
        std.debug.assert(state.main_live == null);
        const allocator = state.allocator;
        state.threaded.deinit();
        allocator.destroy(state);
        self.* = undefined;
    }
};

// 내부 판정자는 별도 root에 있다. 앱에서 import해도 test 집계가 늘지 않는다.
pub const testing = if (builtin.is_test) struct {
    pub const WorkerState = State;
    pub const submit = Service.submitImpl;
    pub const io = State.io;
} else struct {};
