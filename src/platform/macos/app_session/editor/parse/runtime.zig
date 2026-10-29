//! 파싱 서비스의 메인 소유자. 문서 참조는 여기에만 남고 워커에는 전달하지 않는다.
const std = @import("std");
const maru = @import("maru");
const syntax = @import("syntax");
const worker = @import("worker.zig");
const registry = maru.session.editor.document_registry;
const request = maru.session.editor.syntax.request;
/// 표시·재시도 정책을 정하지 않고 현재 요청의 사실만 돌려준다.
pub const Observation = union(enum) {
    none,
    pending: request.Request,
    finished: struct { tag: request.Request, outcome: worker.Outcome, unavailable_reason: ?worker.UnavailableReason },
};
/// published는 이번 호출이 새 작업을 게시했는지다. tag 자체는 자원을 보유하지 않는다.
pub const Submission = struct { tag: request.Request, published: bool };
const Entry = struct {
    lease: registry.Lease,
    identity: registry.DocumentIdentity,
    gate: *request.Gate,
    language: syntax.Language,
    current: ?worker.Completion = null,
    latest: ?request.Request = null,
    outcome: ?worker.Outcome = null,
    unavailable_reason: ?worker.UnavailableReason = null,
};
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    service: worker.Service,
    entries: std.ArrayList(Entry) = .empty,
    last_poll_thread: ?std.Thread.Id = null,
    main_thread: std.Thread.Id,

    pub fn init(a: std.mem.Allocator, options: worker.Options) !Runtime {
        return .{ .allocator = a, .service = try worker.Service.init(a, options), .main_thread = std.Thread.getCurrentId() };
    }
    fn find(self: *Runtime, identity: registry.DocumentIdentity) ?*Entry {
        for (self.entries.items) |*entry| if (std.meta.eql(entry.identity, identity)) return entry;
        return null;
    }
    fn currentInput(source: registry.Lease, grammar: request.Grammar) !request.Input {
        const state = source.owner.get(source) orelse return error.StaleReference;
        const opened = state.opened orelse return error.NotOpened;
        if (source.owner.viewCount(source).? == 0) return error.NoViews;
        return .{ .document = source.owner.identity(source).?, .revision = opened.file.revision, .grammar = grammar };
    }
    fn recoveryKey(grammar: request.Grammar, language: syntax.Language) registry.SyntaxRecovery.Key {
        return .{ .grammar = grammar, .native_language = @backingInt(language) };
    }
    /// 현재 편집 판이 달라도 같은 문법 초기화 실패는 유지한다. 조회는 새 시도를 만들지 않는다.
    pub fn automaticDisabled(source: registry.Lease, grammar: request.Grammar, language: syntax.Language) !bool {
        _ = try currentInput(source, grammar);
        return source.owner.syntaxRecovery(source).?.blocks(recoveryKey(grammar, language));
    }
    /// worker 자체를 세우지 못한 경우도 이미 열린 문서의 무할당 기록으로 남긴다.
    pub fn preparationFailed(source: registry.Lease, grammar: request.Grammar, language: syntax.Language, err: anyerror) void {
        const recovery = source.owner.syntaxRecovery(source) orelse return;
        recovery.disabled = recoveryKey(grammar, language);
        std.log.scoped(.editor_parse).warn("syntax preparation disabled: {s}", .{@errorName(err)});
    }
    fn shareable(entry: *const Entry, tag: request.Request) bool {
        if (entry.gate.wanted) |wanted| return std.meta.eql(wanted, tag) and
            (entry.gate.phase == .awaiting or entry.gate.phase == .consumed);
        // 실패도 게시된 시도의 완료다. 같은 입력의 자동 재시도로 실패를 지우지 않는다.
        return entry.outcome != null and entry.outcome.? != .ready;
    }
    /// 공유 뷰의 같은 입력은 이미 게시한 요청을 재사용한다. 강제 재시도는 기존 submit을 쓴다.
    /// 실패한 문법은 편집 판이 바뀌어도 재초기화하지 않는다. 명시적 재시도는 submit을 쓴다.
    pub fn ensure(self: *Runtime, source: registry.Lease, grammar: request.Grammar, language: syntax.Language) !Submission {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread);
        const input = try currentInput(source, grammar);
        if (self.find(input.document)) |entry| if (entry.latest) |tag| {
            if (std.meta.eql(tag.input, input) and entry.language == language and shareable(entry, tag)) {
                return .{ .tag = tag, .published = false };
            }
        };
        if (source.owner.syntaxRecovery(source).?.blocks(recoveryKey(grammar, language))) return error.AnalysisDisabled;
        return .{ .tag = try self.submit(source, grammar, language), .published = true };
    }
    /// 내부 준비 실패는 caller로 반환한다. 본문/Undo를 수정하거나 동기 파싱으로 우회하지 않는다.
    pub fn submit(self: *Runtime, source: registry.Lease, grammar: request.Grammar, language: syntax.Language) !request.Request {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread);
        const input = try currentInput(source, grammar);
        const recovery = source.owner.syntaxRecovery(source).?;
        // submit은 명시적 초기화 계기다. Entry/Gate 준비부터 실패해도 문서에 기록을 남긴다.
        recovery.disabled = null;
        return self.submitPrepared(source, language, input) catch |err| {
            preparationFailed(source, grammar, language, err);
            return err;
        };
    }
    fn submitPrepared(self: *Runtime, source: registry.Lease, language: syntax.Language, input: request.Input) !request.Request {
        const owner = @constCast(source.owner);
        const opened = owner.get(source).?.opened.?;
        const identity = input.document;
        var entry = self.find(identity);
        const added = entry == null;
        if (added) {
            try self.entries.ensureUnusedCapacity(self.allocator, 1);
            const keeper = try owner.retain(source, .request);
            errdefer _ = owner.release(keeper) catch unreachable;
            const gate = try owner.syntaxRequestGate(keeper);
            self.entries.appendAssumeCapacity(.{ .lease = keeper, .identity = identity, .language = language, .gate = gate });
            entry = &self.entries.items[self.entries.items.len - 1];
        }
        errdefer if (added and !self.service.hasJobs(identity)) {
            const held = self.entries.items[self.entries.items.len - 1].lease;
            self.entries.items.len -= 1;
            _ = owner.release(held) catch unreachable;
        };
        const value = entry.?;
        value.language = language;
        // 같은 본문 재시도도 새 시도다. 준비 실패에 이전 완료 상태를 다시 공개하지 않는다.
        value.latest = null;
        value.outcome = null;
        value.unavailable_reason = null;
        var snapshot = opened.file.snapshot();
        errdefer snapshot.deinit();
        const tag = if (value.current) |*previous|
            try self.service.submitFrom(value.gate, input, &snapshot, language, previous)
        else
            try self.service.submit(value.gate, input, &snapshot, language);
        value.latest = tag;
        return tag;
    }
    /// 미지원 언어로의 명시적 전환은 새 파싱 없이 옛 작업과 결과를 무효화한다.
    pub fn invalidate(self: *Runtime, source: registry.Lease) void {
        const identity = source.owner.identity(source) orelse return;
        const entry = self.find(identity) orelse return;
        entry.gate.invalidate();
        entry.latest = null;
        entry.outcome = null;
        entry.unavailable_reason = null;
        self.service.cancelDocument(identity);
        if (entry.current) |*current| current.release();
        entry.current = null;
        self.sweep();
    }
    fn matches(entry: *const Entry, tag: request.Request) bool {
        const state = entry.lease.owner.get(entry.lease) orelse return false;
        const opened = state.opened orelse return false;
        return entry.lease.owner.viewCount(entry.lease).? != 0 and opened.file.revision == tag.input.revision;
    }
    /// 다음 poll/submit/close/shutdown 전까지만 빌린다. 장기 저장하는 포인터가 아니다.
    /// 호출자가 현재 grammar/language를 명시해 이전 offset이 공개되지 않도록 한다.
    pub fn ready(self: *Runtime, identity: registry.DocumentIdentity, grammar: request.Grammar, language: syntax.Language) ?*const worker.Completion {
        const entry = self.find(identity) orelse return null;
        const current = if (entry.current) |*value| value else return null;
        if (!entry.gate.isCurrent(current.tag()) or !matches(entry, current.tag()) or entry.language != language or
            !std.meta.eql(current.tag().input.grammar, grammar)) return null;
        return current;
    }
    /// 현재 결과를 보유한다. 이후 새 결과로 교체돼도 이 핸들의 자원은 release까지 살아 있다.
    /// 사용 시점의 본문 판 검증은 소비자의 책임이며, 종료 전에 반드시 반환해야 한다.
    pub fn acquire(self: *Runtime, identity: registry.DocumentIdentity, grammar: request.Grammar, language: syntax.Language) error{ReferenceOverflow}!?worker.Completion {
        const current = self.ready(identity, grammar, language) orelse return null;
        return try current.retain();
    }
    /// 완료가 없는 것과 실패 완료를 구분한다. 실패 결과도 본문·언어·요청 판이 맞을 때만 공개한다.
    /// 준비 오류는 submit의 오류 반환으로만 전달하며 작업이 게시되지 않았으므로 none이다.
    pub fn observe(self: *Runtime, identity: registry.DocumentIdentity, grammar: request.Grammar, language: syntax.Language) Observation {
        const entry = self.find(identity) orelse return .none;
        const tag = entry.latest orelse return .none;
        if (!matches(entry, tag) or entry.language != language or !std.meta.eql(tag.input.grammar, grammar)) return .none;
        if (entry.outcome) |outcome| return .{ .finished = .{ .tag = tag, .outcome = outcome, .unavailable_reason = entry.unavailable_reason } };
        return .{ .pending = tag };
    }
    pub fn poll(self: *Runtime) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread);
        self.last_poll_thread = std.Thread.getCurrentId();
        _ = self.service.beginDrain();
        self.service.reap();
        while (self.service.take()) |completion| {
            var value = completion;
            const entry = self.find(value.tag().input.document) orelse {
                value.release();
                continue;
            };
            if (!matches(entry, value.tag())) {
                _ = entry.gate.abandon(value.tag());
                value.release();
                continue;
            }
            if (value.outcome() != .ready) {
                // 낡은 실패가 새 요청의 대기를 소비하거나 원인을 덮어쓰면 안 된다.
                if (entry.gate.abandon(value.tag())) {
                    entry.outcome = value.outcome();
                    entry.unavailable_reason = value.unavailableReason();
                    if (value.outcome() == .out_of_memory or value.unavailableReason() == .native_initialization or value.unavailableReason() == .native_parse) {
                        entry.lease.owner.syntaxRecovery(entry.lease).?.disabled = recoveryKey(value.tag().input.grammar, entry.language);
                        std.log.scoped(.editor_parse).warn("syntax analysis disabled for document {d}: {s}/{s}", .{ entry.identity.slot, @tagName(value.outcome()), if (value.unavailableReason()) |reason| @tagName(reason) else "none" });
                    }
                }
                value.release();
                continue;
            }
            if (!value.accept(entry.gate)) {
                value.release();
                continue;
            }
            if (entry.current) |*old| old.release();
            entry.current = value;
            entry.outcome = .ready;
            entry.unavailable_reason = null;
        }
        self.sweep();
    }
    /// 마지막 view 닫기는 취소 요청으로 끝나지 않는다. Snapshot 반환까지 request 참조를 유지한다.
    pub fn sweep(self: *Runtime) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread);
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            if (entry.lease.owner.viewCount(entry.lease).? != 0 and (entry.latest != null or entry.current != null)) {
                i += 1;
                continue;
            }
            // 같은 문서를 read lease로 다시 열어도 닫힌 시도의 완료/실패를 새 뷰에 재사용하지 않는다.
            entry.latest = null;
            entry.outcome = null;
            entry.unavailable_reason = null;
            entry.gate.invalidate();
            self.service.cancelDocument(entry.identity);
            if (entry.current) |*current| current.release();
            entry.current = null;
            if (self.service.hasJobs(entry.identity)) {
                i += 1;
                continue;
            }
            const removed = self.entries.orderedRemove(i);
            _ = @constCast(removed.lease.owner).release(removed.lease) catch unreachable;
        }
    }
    /// 거절할 때 Gate·현재 결과·문서 lease를 바꾸지 않는다. UI 대기나 강제 회수로 우회하지 않는다.
    pub fn canDeinit(self: *const Runtime) error{ResultsHeld}!void {
        var owned: usize = 0;
        for (self.entries.items) |entry| if (entry.current != null) {
            owned += 1;
        };
        if (self.service.heldCount() != owned) return error.ResultsHeld;
    }
    pub fn deinit(self: *Runtime) error{ResultsHeld}!void {
        try self.canDeinit();
        for (self.entries.items) |*entry| {
            entry.gate.invalidate();
            if (entry.current) |*current| current.release();
            entry.current = null;
        }
        // 원본 allocator를 지키는 lease를 놓기 전에 worker join과 두 Snapshot의 메인 회수를 끝낸다.
        self.service.deinit() catch unreachable;
        for (self.entries.items) |entry| _ = @constCast(entry.lease.owner).release(entry.lease) catch unreachable;
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
};
