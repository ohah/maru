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
    finished: struct { tag: request.Request, outcome: worker.Outcome },
};
const Entry = struct {
    lease: registry.Lease,
    identity: registry.DocumentIdentity,
    gate: *request.Gate,
    language: syntax.Language,
    current: ?worker.Completion = null,
    latest: ?request.Request = null,
    outcome: ?worker.Outcome = null,
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
    /// 내부 준비 실패는 caller로 반환한다. 본문/Undo를 수정하거나 동기 파싱으로 우회하지 않는다.
    pub fn submit(self: *Runtime, source: registry.Lease, grammar: request.Grammar, language: syntax.Language) !request.Request {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread);
        const owner = @constCast(source.owner);
        const state = owner.get(source) orelse return error.StaleReference;
        const opened = state.opened orelse return error.NotOpened;
        if (owner.viewCount(source).? == 0) return error.NoViews;
        const identity = owner.identity(source).?;
        const revision = opened.file.revision;
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
        var snapshot = opened.file.snapshot();
        errdefer snapshot.deinit();
        const input: request.Input = .{ .document = identity, .revision = revision, .grammar = grammar };
        const tag = if (value.current) |*previous|
            try self.service.submitFrom(value.gate, input, &snapshot, language, previous)
        else
            try self.service.submit(value.gate, input, &snapshot, language);
        value.latest = tag;
        return tag;
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
    /// 완료가 없는 것과 실패 완료를 구분한다. 실패 결과도 본문·언어·요청 판이 맞을 때만 공개한다.
    /// 준비 오류는 submit의 오류 반환으로만 전달하며 작업이 게시되지 않았으므로 none이다.
    pub fn observe(self: *Runtime, identity: registry.DocumentIdentity, grammar: request.Grammar, language: syntax.Language) Observation {
        const entry = self.find(identity) orelse return .none;
        const tag = entry.latest orelse return .none;
        if (!matches(entry, tag) or entry.language != language or !std.meta.eql(tag.input.grammar, grammar)) return .none;
        if (entry.outcome) |outcome| return .{ .finished = .{ .tag = tag, .outcome = outcome } };
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
                if (entry.gate.abandon(value.tag())) entry.outcome = value.outcome();
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
        }
        self.sweep();
    }
    /// 마지막 view 닫기는 취소 요청으로 끝나지 않는다. Snapshot 반환까지 request 참조를 유지한다.
    pub fn sweep(self: *Runtime) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread);
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            if (entry.lease.owner.viewCount(entry.lease).? != 0) {
                i += 1;
                continue;
            }
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
    pub fn deinit(self: *Runtime) void {
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
