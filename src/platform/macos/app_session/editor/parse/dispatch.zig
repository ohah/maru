//! 앱 메인 소유 파싱 runtime. 종료 전에 전역 소유자를 먼저 내리므로 늦은 OS 전달도 안전하다.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const syntax = @import("syntax");
pub const runtime = @import("runtime.zig");
pub const worker = @import("worker.zig");
pub const view = @import("view.zig");
pub const wake = @import("wake.zig");
pub const registry = maru.session.editor.document_registry;
pub const request = maru.session.editor.syntax.request;
var active: ?runtime.Runtime = null;
var completed: ?*const fn () void = null;

/// 도착 시 살아 있는 창을 다시 조회하는 정적 함수만 등록한다. 창 포인터를 보관하지 않는다.
pub fn onCompleted(callback: ?*const fn () void) void {
    completed = callback;
}

fn allocator() std.mem.Allocator {
    return if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator;
}
/// 명시적 재분석 요청이다. 일반 입력의 동일 요청 재사용은 ensure가 담당한다.
pub fn submit(source: registry.Lease, grammar: request.Grammar, language: syntax.Language) !request.Request {
    _ = try runtime.Runtime.automaticDisabled(source, grammar, language);
    const owner = getOrStart() catch |err| {
        runtime.Runtime.preparationFailed(source, grammar, language, err);
        return err;
    };
    return owner.submit(source, grammar, language) catch |err| {
        if (owner.entries.items.len == 0) shutdown();
        return err;
    };
}
fn getOrStart() !*runtime.Runtime {
    if (!builtin.is_test and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    if (active == null) active = try runtime.Runtime.init(allocator(), .{ .notify = wake.request });
    return &active.?;
}
/// 같은 문서 판을 보는 뷰는 새 작업을 게시하지 않는다. 강제 재시도는 submit으로 분리한다.
pub fn ensure(source: registry.Lease, grammar: request.Grammar, language: syntax.Language) !runtime.Submission {
    const disabled = try runtime.Runtime.automaticDisabled(source, grammar, language);
    // 비어 종료된 runtime을 타이핑마다 다시 만들지 않는다. 살아 있는 완료 조회는 기존 owner가 맡는다.
    if (active == null and disabled) return error.AnalysisDisabled;
    const owner = getOrStart() catch |err| {
        runtime.Runtime.preparationFailed(source, grammar, language, err);
        return err;
    };
    return owner.ensure(source, grammar, language) catch |err| {
        if (owner.entries.items.len == 0) shutdown();
        return err;
    };
}
pub fn ready(identity: registry.DocumentIdentity, grammar: request.Grammar, language: syntax.Language) ?*const worker.Completion {
    if (active) |*owner| return owner.ready(identity, grammar, language);
    return null;
}
/// 현재 결과를 보유한 소비자는 종료 전에 release해야 한다. 내부 트리 포인터를 저장하지 않는다.
pub fn acquire(identity: registry.DocumentIdentity, grammar: request.Grammar, language: syntax.Language) error{ReferenceOverflow}!?worker.Completion {
    if (active) |*owner| return owner.acquire(identity, grammar, language);
    return null;
}
/// 알림·재시도는 호출자의 정책이다. 현재 요청의 게시·완료 사실만 조회한다.
pub fn observe(identity: registry.DocumentIdentity, grammar: request.Grammar, language: syntax.Language) runtime.Observation {
    if (active) |*owner| return owner.observe(identity, grammar, language);
    return .none;
}
/// 기존 상태를 건드리기 전에 보유 참조와 독립 native 복사를 준비한다.
pub fn prepareView(view_allocator: std.mem.Allocator, identity: registry.DocumentIdentity, grammar: request.Grammar, language: syntax.Language) error{ ReferenceOverflow, NativeCopyFailed }!?view.Prepared {
    if (active) |*owner| return view.prepare(view_allocator, owner, identity, grammar, language);
    return null;
}
/// 호출자가 준비 후 입력·언어·뷰를 바꿀 수 있으므로 설치 직전에 다시 검증한다.
pub fn installView(prepared: *view.Prepared, target: *view.State, lease: registry.Lease, grammar: request.Grammar, language: syntax.Language) error{LegacyProvider}!bool {
    if (active) |*owner| return prepared.install(owner, target, lease, grammar, language);
    return false;
}
pub fn poll() void {
    if (active) |*owner| {
        owner.poll();
        // 문서가 모두 회수됐다면 native 작업도 없다. 닫기에서 실행 중 worker를 동기 대기하지 않는다.
        if (owner.entries.items.len == 0) shutdown();
    }
    if (completed) |callback| callback();
}
pub fn invalidate(source: registry.Lease) void {
    if (source.owner.syntaxRecovery(source)) |recovery| recovery.disabled = null;
    if (active) |*owner| {
        owner.invalidate(source);
        if (owner.entries.items.len == 0) shutdown();
    }
}
pub fn viewsChanged() void {
    if (active) |*owner| {
        owner.sweep();
        if (owner.entries.items.len == 0) shutdown();
    }
}
/// 소비자가 결과를 보유하면 소유자를 그대로 남겨 반환 후 종료할 수 있게 한다.
pub fn tryShutdown() error{ResultsHeld}!void {
    if (active == null) return;
    try active.?.canDeinit();
    var owner = active.?;
    active = null;
    owner.deinit() catch unreachable;
}
/// 기존 앱 종료 경로는 모든 소비자의 반환을 먼저 끝내야 한다.
pub fn shutdown() void {
    tryShutdown() catch unreachable;
}
/// 제품 Service를 그대로 쓰고 테스트에서만 평탄화 allocator를 교체한다.
pub fn startForTest(options: worker.Options) !void {
    if (!builtin.is_test) @compileError("test-only parse service configuration");
    try tryShutdown();
    var configured = options;
    configured.notify = wake.request;
    active = try runtime.Runtime.init(std.testing.allocator, configured);
}
pub fn lastPollThread() ?std.Thread.Id {
    return if (active) |owner| owner.last_poll_thread else null;
}
